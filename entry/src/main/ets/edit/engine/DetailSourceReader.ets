import { image } from '@kit.ImageKit';
import { LengthMetricsUnit } from '@kit.ArkUI';

/** Same shape as RegionPixelsResult; kept local so the engine has no utils type dependency. */
export interface DetailSourcePixels {
  pixels: ArrayBuffer;
  width: number;
  height: number;
}

/** Output rows sampled between main-thread yields on the ArkTS fallback path. */
const SAMPLE_ROWS_PER_SLICE: number = 32;

/**
 * 放大瓦片的源像素读取与降采样。
 *
 * 真机实测（8152x5432 RAW，200% 瓦片读 4076x2716 源区域、采样到 2048x1364）：
 *  - 旧 RegionPixels.read：整条瓦片 10.2 秒；
 *  - readPixels 合并成 3 次后只花 82~140 ms，但采样本身仍要 7.5~8.7 秒。
 *    把采样留在主线程或 TaskPool 都一样慢——瓶颈是 ArkTS 解释执行 280 万
 *    像素 × 4 通道的双线性运算，不是数据搬运。
 *
 * 因此正式路径改为 **OffscreenCanvas.drawImage 原生缩放**（Skia 在 C++ 里
 * 完成双线性重采样），ArkTS 采样只作为 Canvas 不可用时的回退。两条路径都在
 * 真机上做过一次逐字节对拍（VIVID_DETAIL source-read-canvas probe=...），
 * 通道顺序、边界钳制与输出尺寸一致。
 */
export class DetailSourceReader {
  /** Per-readPixels budget. 16 MiB keeps peak extra memory bounded. */
  static readonly BAND_BUDGET_BYTES: number = 16 * 1024 * 1024;
  /** Logs are part of the VIVID_DETAIL timing contract, not debug leftovers. */
  static verbose: boolean = true;

  /**
   * 上一次瓦片读入的单条缓存。
   *
   * 放大后调一个滑块（或按住对比）会以**同一个矩形、同一个输出尺寸**再次请求
   * 瓦片：源 PixelMap 没变，Skia 会逐字节重算出同一张图。真机日志里这一次
   * `source-read-canvas` 是 265ms，而缓存命中只需一次 10MB 拷贝（~2ms）。
   *
   * 命中条件必须包含 PixelMap 的**对象身份**：RAW 配置切换会重新解码出新的
   * PixelMap，此时即使矩形相同也必须重读。缓存存的是副本、返回的也是副本，
   * 调用方就地改写不会污染下一次命中的字节。
   */
  private static lastTile: DetailSourcePixels | null = null;
  private static lastTileKey: string = '';
  private static lastTileSource: image.PixelMap | null = null;

  private static tileKey(source: image.PixelMap, x: number, y: number, width: number,
    height: number, maxEdge: number, w: number, h: number): string {
    return `${x},${y},${width},${height}|${maxEdge}|${w}x${h}`;
  }

  /** 缓存命中返回副本；未命中返回 null。 */
  private static cachedTile(source: image.PixelMap, key: string): DetailSourcePixels | null {
    if (DetailSourceReader.lastTile === null || DetailSourceReader.lastTileSource !== source ||
      DetailSourceReader.lastTileKey !== key) return null;
    return {
      pixels: DetailSourceReader.lastTile.pixels.slice(0),
      width: DetailSourceReader.lastTile.width,
      height: DetailSourceReader.lastTile.height,
    };
  }

  private static storeTile(source: image.PixelMap, key: string, tile: DetailSourcePixels): void {
    DetailSourceReader.lastTileSource = source;
    DetailSourceReader.lastTileKey = key;
    DetailSourceReader.lastTile = {
      pixels: tile.pixels.slice(0),
      width: tile.width,
      height: tile.height,
    };
  }

  static async read(source: image.PixelMap, x: number, y: number, width: number, height: number,
    maxEdge: number, stale: () => boolean, label: string = ''): Promise<DetailSourcePixels | null> {
    const startedAt = Date.now();
    const scale = Math.min(1, Math.max(256, Math.min(2048, maxEdge)) / Math.max(width, height));
    const w = Math.max(1, Math.round(width * scale)), h = Math.max(1, Math.round(height * scale));
    const key = DetailSourceReader.tileKey(source, x, y, width, height, maxEdge, w, h);
    const cached = DetailSourceReader.cachedTile(source, key);
    if (cached !== null) {
      if (DetailSourceReader.verbose && label.length > 0) {
        console.info(`VIVID_DETAIL source-read-canvas label=${label} cache=1 ` +
          `wall=${Date.now() - startedAt}ms rect=${x},${y},${width},${height} out=${w}x${h}`);
      }
      return cached;
    }
    let result: DetailSourcePixels | null;
    if (scale < 1) {
      const native = await DetailSourceReader.readWithCanvas(source, x, y, width, height, w, h,
        stale, label);
      result = native !== null ? native :
        await DetailSourceReader.readSampled(source, x, y, width, height, w, h, stale, label);
    } else {
      result = await DetailSourceReader.readSampled(source, x, y, width, height, w, h, stale, label);
    }
    if (result !== null && !stale()) DetailSourceReader.storeTile(source, key, result);
    return result;
  }

  /**
   * Native (Skia) bilinear downscale. The source rectangle and the destination
   * size are exactly the same ones the ArkTS sampler uses, so the tile geometry
   * does not change; only the resampling implementation does.
   */
  private static async readWithCanvas(source: image.PixelMap, x: number, y: number,
    width: number, height: number, w: number, h: number, stale: () => boolean,
    label: string): Promise<DetailSourcePixels | null> {
    const started = Date.now();
    let canvas: OffscreenCanvas | null = null;
    let scaled: image.PixelMap | null = null;
    try {
      canvas = new OffscreenCanvas(w, h, LengthMetricsUnit.PX);
      const context = canvas.getContext('2d', new RenderingContextSettings(true));
      if (context === null) return null;
      context.imageSmoothingEnabled = true;
      context.drawImage(source, x, y, width, height, 0, 0, w, h);
      scaled = await context.getPixelMap(0, 0, w, h);
      if (scaled === null) return null;
      const buffer = new ArrayBuffer(w * h * 4);
      await scaled.readPixelsToBuffer(buffer);
      if (stale()) return null;
      if (DetailSourceReader.verbose && label.length > 0) {
        console.info(`VIVID_DETAIL source-read-canvas label=${label} wall=${Date.now() - started}ms ` +
          `rect=${x},${y},${width},${height} out=${w}x${h}`);
      }
      return { pixels: buffer, width: w, height: h };
    } catch (_error) {
      return null;
    } finally {
      if (scaled !== null) {
        try { scaled.release(); } catch (_error) { /* already released */ }
      }
      canvas = null;
    }
  }

  /**
   * ArkTS fallback, retained for devices where OffscreenCanvas cannot read the
   * source PixelMap. Reads in 16 MiB bands and samples with the exact
   * RegionPixels.sampleBgraBand arithmetic (including BGRA→RGBA swap).
   */
  private static async readSampled(source: image.PixelMap, x: number, y: number,
    width: number, height: number, w: number, h: number,
    stale: () => boolean, label: string): Promise<DetailSourcePixels | null> {
    const result = new Uint8Array(w * h * 4);
    const rx = width / w, ry = height / h;
    const bandRows = Math.max(1, Math.min(h, Math.floor(DetailSourceReader.BAND_BUDGET_BYTES / (width * 4 * ry))));
    const started = Date.now();
    let readMs = 0;
    let sampleMs = 0;
    let calls = 0;
    let yields = 0;
    for (let row = 0; row < h; row += bandRows) {
      if (stale()) return null;
      const rows = Math.min(bandRows, h - row);
      const top = Math.max(0, Math.floor((row + 0.5) * ry - 0.5));
      const bottom = Math.min(height, Math.ceil((row + rows - 0.5) * ry - 0.5) + 2);
      const bytes = new ArrayBuffer(width * (bottom - top) * 4);
      const readStart = Date.now();
      await source.readPixels({ pixels: bytes, offset: 0, stride: width * 4,
        region: { x: x, y: y + top, size: { width: width, height: bottom - top } } });
      readMs += Date.now() - readStart;
      calls++;
      const sourcePixels = new Uint8Array(bytes);
      for (let done = 0; done < rows; done += SAMPLE_ROWS_PER_SLICE) {
        if (stale()) return null;
        const sliceRows = Math.min(SAMPLE_ROWS_PER_SLICE, rows - done);
        const sampleStart = Date.now();
        DetailSourceReader.sampleRows(sourcePixels, width, top, bottom - top, result, w,
          row + done, sliceRows, rx, ry);
        sampleMs += Date.now() - sampleStart;
        yields++;
        await new Promise<void>((resolve) => { setTimeout(resolve, 0); });
      }
    }
    if (DetailSourceReader.verbose && label.length > 0) {
      console.info(`VIVID_DETAIL source-read-detail label=${label} path=arkts calls=${calls} ` +
        `read=${readMs}ms sample=${sampleMs}ms yields=${yields} wall=${Date.now() - started}ms ` +
        `bandRows=${bandRows} out=${w}x${h}`);
    }
    return { pixels: result.buffer as ArrayBuffer, width: w, height: h };
  }

  /**
   * Bilinear resample of `rows` output rows. This is the exact body of
   * RegionPixels.sampleBgraBand, without the TaskPool marshalling; the channel
   * swap and the clamp-to-edge rule are preserved so tiles stay byte-identical.
   */
  private static sampleRows(src: Uint8Array, sourceWidth: number, sourceTop: number,
    sourceHeight: number, output: Uint8Array, outputWidth: number, outputTop: number,
    rows: number, ratioX: number, ratioY: number): void {
    for (let y = 0; y < rows; y++) {
      const sy = Math.max(0, Math.min(sourceHeight - 1,
        (outputTop + y + 0.5) * ratioY - 0.5 - sourceTop));
      const y0 = Math.floor(sy), y1 = Math.min(sourceHeight - 1, y0 + 1), fy = sy - y0;
      const outRow = (outputTop + y) * outputWidth;
      for (let x = 0; x < outputWidth; x++) {
        const sx = Math.max(0, Math.min(sourceWidth - 1, (x + 0.5) * ratioX - 0.5));
        const x0 = Math.floor(sx), x1 = Math.min(sourceWidth - 1, x0 + 1), fx = sx - x0;
        const rowBase = y0 * sourceWidth, nextBase = y1 * sourceWidth;
        const out = (outRow + x) * 4;
        for (let c = 0; c < 4; c++) {
          const channel = c === 0 ? 2 : (c === 2 ? 0 : c);
          const a = src[(rowBase + x0) * 4 + channel] * (1 - fx) +
            src[(rowBase + x1) * 4 + channel] * fx;
          const b = src[(nextBase + x0) * 4 + channel] * (1 - fx) +
            src[(nextBase + x1) * 4 + channel] * fx;
          output[out + c] = Math.round(a * (1 - fy) + b * fy);
        }
      }
    }
  }
}
