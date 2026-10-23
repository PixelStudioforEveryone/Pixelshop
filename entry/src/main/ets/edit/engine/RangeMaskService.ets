/**
 * Source-pixel access and caching for range masks.
 *
 * A range mask needs to know where each pixel sits in the image's tonal and
 * chromatic distribution, so unlike the geometric components it cannot be
 * evaluated from parameters alone. Reading the source on every slider tick
 * would cost a multi-megabyte read per frame, so the bounded RGB proxy is
 * captured once per source and reused; that is what makes dragging the window
 * sliders interactive.
 *
 * The cache is keyed by session id and source dimensions and is dropped by
 * `ImageProcessor.clearSourceCache`, the same single point where every other
 * source-derived cache in this codebase (denoise, retouch) is invalidated.
 */
import { image } from '@kit.ImageKit';
import {
  RangeMaskProxy, RangeMaskWindow, RANGE_MASK_MAX_EDGE, buildProxy, buildRangeAlpha,
  luminanceWindow, rangeSignature,
} from './RangeMaskCore';
import {
  MaskRaster, RangeMaskData, RASTER_ORIGIN_RANGE,
} from '../models/Mask';
import { EditSession } from '../models/EditSession';

/**
 * 自动蒙版代理的网格上限：门限沿着物体边缘走，网格就是边缘精度的上限。
 * 768 是"边缘可用"与"读一帧 + 采样开销"之间的折中；范围蒙版仍用 192。
 */
export const AUTO_MASK_MAX_EDGE: number = 768;

export class RangeMaskService {
  private static proxies: Map<string, RangeMaskProxy> = new Map<string, RangeMaskProxy>();
  private static order: string[] = [];
  private static capacity: number = 3;
  /** 单次整帧读取的上限：超过就分块读，避免 44MP 一次性 177MB 的分配。 */
  private static readonly READ_LIMIT_BYTES: number = 64 * 1024 * 1024;
  /** 同一源正在读取中的代理请求，避免并发的重复整帧读取。 */
  private static inflight: Map<string, Promise<RangeMaskProxy | null>> =
    new Map<string, Promise<RangeMaskProxy | null>>();

  /** Cache key for one source inside one editing session. */
  static tokenFor(session: EditSession): string {
    return `${session.sessionId}:${session.imageWidth}x${session.imageHeight}`;
  }

  static cachedProxy(token: string): RangeMaskProxy | null {
    const proxy = RangeMaskService.proxies.get(token);
    return proxy !== undefined ? proxy : null;
  }

  /**
   * Capture the bounded RGB proxy, reusing the cached one when possible.
   *
   * Throws nothing: a source that cannot be read returns null, and the caller
   * reports that honestly rather than producing a mask from nothing.
   */
  static async proxyFor(pixelMap: image.PixelMap, token: string): Promise<RangeMaskProxy | null> {
    const cached = RangeMaskService.cachedProxy(token);
    if (cached !== null) return cached;
    return RangeMaskService.capture(pixelMap, token, RANGE_MASK_MAX_EDGE);
  }

  /**
   * 存代理进 LRU。
   *
   * 必须先查重再压栈：旧实现无条件 `push(token)`，同一个 token 被重复压栈后，
   * 淘汰按队头 delete 时会**把刚存进去的活缓存删掉**，于是调用方永远 miss，
   * 每次 miss 又触发一次整帧读图 + 清蒙版缓存 + 通知重算——实测就是叠加层每
   * ~200ms 重跑一次的死循环（涂抹页面卡顿的根因）。
   */
  private static store(token: string, proxy: RangeMaskProxy): void {
    const existing = RangeMaskService.order.indexOf(token);
    if (existing >= 0) RangeMaskService.order.splice(existing, 1);
    RangeMaskService.proxies.set(token, proxy);
    RangeMaskService.order.push(token);
    while (RangeMaskService.order.length > RangeMaskService.capacity) {
      const oldest = RangeMaskService.order.shift();
      // 绝不淘汰刚刚存入的这一条：调用方马上就它用。
      if (oldest !== undefined && oldest !== token) {
        RangeMaskService.proxies.delete(oldest);
      }
    }
  }

  /** Drop every cached proxy. Called when the edited source changes. */
  static forget(sessionId?: number): void {
    if (sessionId === undefined) {
      RangeMaskService.proxies.clear();
      RangeMaskService.order = [];
      RangeMaskService.inflight.clear();
      return;
    }
    const prefix = `${sessionId}:`;
    for (const token of Array.from(RangeMaskService.inflight.keys())) {
      if (token.startsWith(prefix)) RangeMaskService.inflight.delete(token);
    }
    for (let index = RangeMaskService.order.length - 1; index >= 0; index--) {
      const token = RangeMaskService.order[index];
      if (token.startsWith(prefix)) {
        RangeMaskService.proxies.delete(token);
        RangeMaskService.order.splice(index, 1);
      }
    }
  }

  static defaultWindow(proxy: RangeMaskProxy): RangeMaskWindow {
    return luminanceWindow(proxy);
  }

  /**
   * Capture the proxy without the caller having to await, coalescing concurrent
   * requests for the same source.
   *
   * 自动蒙版需要这份代理才能给笔刷加颜色门限，而它可能在任何一次渲染里才
   * 第一次被需要（用户没碰过范围蒙版），所以这里提供一个去重的"确保已缓存"
   * 入口：调用方可以立刻继续渲染，代理到位后再清缓存重算。
   */
  static ensure(pixelMap: image.PixelMap | null | undefined, token: string): Promise<RangeMaskProxy | null> {
    const cached = RangeMaskService.cachedProxy(token);
    if (cached !== null) return Promise.resolve(cached);
    const pending = RangeMaskService.inflight.get(token);
    if (pending !== undefined) return pending;
    if (!pixelMap) return Promise.resolve(null);
    const task = RangeMaskService.proxyFor(pixelMap, token);
    RangeMaskService.inflight.set(token, task);
    task.then((): void => { RangeMaskService.inflight.delete(token); },
      (): void => { RangeMaskService.inflight.delete(token); });
    return task;
  }

  /**
   * 自动蒙版专用的源代理：网格比范围蒙版更密（768 而非 192）。
   *
   * 范围蒙版只按色调窗口切分，192 足够；自动蒙版的门限是**空间上**贴着物体
   * 边缘走的，代理网格就是它能达到的边缘精度上限，192 会让边缘明显发块。
   * 两者分开缓存，避免更密的网格拖慢范围蒙版滑杆的实时重算。
   */
  static autoMaskTokenFor(session: EditSession): string {
    return `${RangeMaskService.tokenFor(session)}:auto`;
  }

  static cachedAutoMaskProxy(session: EditSession): RangeMaskProxy | null {
    return RangeMaskService.cachedProxy(RangeMaskService.autoMaskTokenFor(session));
  }

  /** 确保更密的自动蒙版代理已缓存（带去重）。只用源图，见 capture 的坐标系说明。 */
  static ensureAutoMaskProxy(session: EditSession): Promise<RangeMaskProxy | null> {
    const token = RangeMaskService.autoMaskTokenFor(session);
    const cached = RangeMaskService.proxies.get(token);
    if (cached !== undefined) return Promise.resolve(cached);
    const pending = RangeMaskService.inflight.get(token);
    if (pending !== undefined) return pending;
    const source = session.sourcePixelMap;
    if (!source) return Promise.resolve(null);
    const task = RangeMaskService.capture(source, token, AUTO_MASK_MAX_EDGE);
    RangeMaskService.inflight.set(token, task);
    task.then((): void => { RangeMaskService.inflight.delete(token); },
      (): void => { RangeMaskService.inflight.delete(token); });
    return task;
  }

  /**
   * 读取源图并建立代理，网格上限由调用方决定。
   *
   * **只接受源图坐标系里的图**。蒙版栅格是在源图坐标系里生成的（本会话源图
   * 2048x1364 横置，显示是旋转 270° 后的竖图），代理一旦来自别的坐标系，
   * 门限采样的颜色就取自图片上不相干的位置——表现就是"自动蒙版完全没效果"。
   * 所以这里绝不做跨坐标系的兜底：读不出来就返回 null（这一次不做门限），
   * 由调用方如实降级。
   *
   * 大图（导出时会换成全分辨率）走分块读取：整帧一次性读入 44MP 就是 177MB
   * 缓冲，内存受限的设备会被直接杀掉（实测发生过）。分块把单次分配压到
   * 1MB 级，总 I/O 不变。
   */
  private static async capture(source: image.PixelMap | null | undefined, token: string,
    maxEdge: number): Promise<RangeMaskProxy | null> {
    if (!source) {
      console.warn(`VIVID_PERF t=${Date.now()} event=proxy_capture token=${token} ` +
        `reason=no-source`);
      return null;
    }
    let width = 0;
    let height = 0;
    try {
      const info = await source.getImageInfo();
      width = info.size.width;
      height = info.size.height;
    } catch (_e) {
      console.warn(`VIVID_PERF t=${Date.now()} event=proxy_capture token=${token} ` +
        `reason=info-failed`);
      return null;
    }
    if (width <= 0 || height <= 0) {
      console.warn(`VIVID_PERF t=${Date.now()} event=proxy_capture token=${token} ` +
        `reason=empty-size src=-`);
      return null;
    }
    if (width * height * 4 <= RangeMaskService.READ_LIMIT_BYTES) {
      let buffer: ArrayBuffer;
      try {
        buffer = new ArrayBuffer(width * height * 4);
        await source.readPixelsToBuffer(buffer);
      } catch (_e) {
        console.warn(`VIVID_PERF t=${Date.now()} event=proxy_capture token=${token} ` +
          `src=${width}x${height} reason=read-failed`);
        return null;
      }
      // buildProxy 自己做盒平均降采样到 maxEdge。
      const proxy = buildProxy(new Uint8Array(buffer), width, height, maxEdge);
      RangeMaskService.store(token, proxy);
      console.info(`VIVID_PERF t=${Date.now()} event=proxy_capture token=${token} ` +
        `src=${width}x${height} path=single proxy=${proxy.width}x${proxy.height}`);
      return proxy;
    }
    const proxy = await RangeMaskService.captureTiled(source, width, height, maxEdge);
    if (proxy === null) {
      console.warn(`VIVID_PERF t=${Date.now()} event=proxy_capture token=${token} ` +
        `src=${width}x${height} reason=tiled-failed`);
      return null;
    }
    RangeMaskService.store(token, proxy);
    console.info(`VIVID_PERF t=${Date.now()} event=proxy_capture token=${token} ` +
      `src=${width}x${height} path=tiled proxy=${proxy.width}x${proxy.height}`);
    return proxy;
  }

  /** 大图分块读取：逐块盒平均累加到代理网格，单次分配固定在 1MB 级。 */
  private static async captureTiled(source: image.PixelMap, width: number, height: number,
    maxEdge: number): Promise<RangeMaskProxy | null> {
    const scale = Math.min(1, maxEdge / Math.max(width, height));
    const proxyWidth = Math.max(1, Math.round(width * scale));
    const proxyHeight = Math.max(1, Math.round(height * scale));
    const cells = proxyWidth * proxyHeight;
    const sumR = new Uint32Array(cells);
    const sumG = new Uint32Array(cells);
    const sumB = new Uint32Array(cells);
    const counts = new Uint32Array(cells);
    const tileEdge = 512;
    for (let tileY = 0; tileY < height; tileY += tileEdge) {
      for (let tileX = 0; tileX < width; tileX += tileEdge) {
        const tileWidth = Math.min(tileEdge, width - tileX);
        const tileHeight = Math.min(tileEdge, height - tileY);
        const pixels = new Uint8Array(tileWidth * tileHeight * 4);
        const area: image.PositionArea = {
          pixels: pixels,
          offset: 0,
          stride: tileWidth * 4,
          region: { size: { width: tileWidth, height: tileHeight }, x: tileX, y: tileY },
        };
        try {
          await source.readPixels(area);
        } catch (_e) {
          return null;
        }
        // 全分辨率源（44MP）逐像素累加是主线程上 4400 万次循环，实测把导出
        // 卡死在 20%。按"总样本量 ≤ 800 万"选步长：768 网格每格仍能摊到十余个
        // 样本，均值足够稳，而循环代价与源图大小无关。
        const stride = Math.max(1, Math.ceil(Math.sqrt((width * height) / 8000000)));
        for (let y = 0; y < tileHeight; y += stride) {
          const cellY = Math.min(proxyHeight - 1, Math.floor((tileY + y) * proxyHeight / height));
          const rowStart = cellY * proxyWidth;
          for (let x = 0; x < tileWidth; x += stride) {
            const cellX = Math.min(proxyWidth - 1, Math.floor((tileX + x) * proxyWidth / width));
            const sourceIndex = (y * tileWidth + x) * 4;
            const cell = rowStart + cellX;
            sumR[cell] += pixels[sourceIndex];
            sumG[cell] += pixels[sourceIndex + 1];
            sumB[cell] += pixels[sourceIndex + 2];
            counts[cell]++;
          }
        }
      }
    }
    const rgb = new Uint8Array(cells * 3);
    for (let cell = 0; cell < cells; cell++) {
      const count = counts[cell];
      if (count === 0) continue;
      rgb[cell * 3] = Math.round(sumR[cell] / count);
      rgb[cell * 3 + 1] = Math.round(sumG[cell] / count);
      rgb[cell * 3 + 2] = Math.round(sumB[cell] / count);
    }
    const proxy: RangeMaskProxy = { width: proxyWidth, height: proxyHeight, rgb: rgb };
    return proxy;
  }

  /** Build the soft raster for these parameters. Pure aside from the params. */
  static buildRaster(proxy: RangeMaskProxy, params: RangeMaskData): MaskRaster {
    const alpha = buildRangeAlpha(proxy, params);
    const raster = new MaskRaster();
    raster.origin = RASTER_ORIGIN_RANGE;
    // The provenance key comes from the same function the core uses, so the
    // recorded signature can never drift from the parameters that made it.
    raster.key = rangeSignature(params);
    raster.width = proxy.width;
    raster.height = proxy.height;
    raster.alpha = alpha;
    return raster;
  }

  /**
   * Recompute a range component's raster and attach it.
   *
   * Returns false when the component no longer exists, so a recompute that
   * finishes after the mask was deleted is dropped rather than recreating it.
   */
  static recompute(session: EditSession, componentId: string, params: RangeMaskData,
    proxy: RangeMaskProxy, bump: boolean = true): boolean {
    const raster = RangeMaskService.buildRaster(proxy, params);
    return session.setMaskComponentRaster(componentId, raster.origin, raster.key,
      raster.width, raster.height, raster.alpha, bump);
  }
}
