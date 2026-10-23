import gpuNative from 'libvivid_gpu.so';
import { GpuOutputGeometry, GpuBokehOptions } from 'libvivid_gpu.so';
import { EditSession } from '../models/EditSession';
import { LutTable } from '../models/LutLibrary';
import { BlendMode, Layer } from '../models/Layer';
import { ColorAdjustments, CurveAnchor, smoothCurveY } from '../models/Adjustment';
import { ColorMatrixBuilder } from './ColorMatrixBuilder';
import { buildGeometryMap, displayToFrame } from './GeometryMath';
import { MaskRenderer } from './MaskRenderer';
import { denoiseEnabled } from './NoiseReduction';
import {
  ParametricCurveParams,
  buildParametricLut,
} from './ParametricCurveCore';
import { ImageProcessor } from './ImageProcessor';
import { processBehaviors } from '../models/ProcessVersion';

interface NativeGpuOptions {
  denoise?: number[];
  toneCurveId?: number;
  redCurveId?: number;
  greenCurveId?: number;
  blueCurveId?: number;
  lutId?: number;
  maskId?: number;
  matrix: ArrayBuffer;
  toneCurve: ArrayBuffer;
  redCurve: ArrayBuffer;
  greenCurve: ArrayBuffer;
  blueCurve: ArrayBuffer;
  parametricCurve: ArrayBuffer;
  parametricEnabled?: boolean;
  parametricRefine?: number;
  lut?: ArrayBuffer;
  mask?: ArrayBuffer;
  mixHue: number[];
  mixSaturation: number[];
  mixLuminance: number[];
  tonal: number[];
  whiteBalanceGain: number[];
  exposureGain: number;
  vignette: number[];
  grain: number[];
  lutDomainMin?: number[];
  lutDomainScale?: number[];
  whiteBalanceEnabled: boolean;
  vibrance: number;
  calibrationHue: number[];
  calibrationSaturation: number[];
  mixerEnabled: boolean;
  maskWidth?: number;
  maskHeight?: number;
  lutEnabled?: boolean;
  lutSize?: number;
  maskEnabled?: boolean;
  maskOpacity?: number;
  opacity?: number;
  blendMode?: number;
  lutIntensity?: number;
  gradingShadowsTarget?: number[];
  gradingMidtonesTarget?: number[];
  gradingHighlightsTarget?: number[];
  gradingGlobalTarget?: number[];
  gradingShadowsSaturation?: number;
  gradingShadowsLuminance?: number;
  gradingMidtonesSaturation?: number;
  gradingMidtonesLuminance?: number;
  gradingHighlightsSaturation?: number;
  gradingHighlightsLuminance?: number;
  gradingGlobalSaturation?: number;
  gradingGlobalLuminance?: number;
  gradingBlending?: number;
  gradingBalance?: number;
  gradingEnabled?: boolean;
}


interface DirectSourceState {
  retouchKey: string;
  pixelMap: Object;
  width: number;
  height: number;
  version: number;
}

interface BokehPlate {
  pixels: ArrayBuffer;
  width: number;
  height: number;
}

/** Shared pass builder for on-screen GPU and readback/export verification. */
export class GpuShaderBridge {
  /** 交互预览里蒙版栅格化的最大边长（px）。导出不受此限制。 */
  static readonly MASK_RASTER_MAX_EDGE: number = 256;
  private static serial: number = 0;
  private static keys: Map<number, string> = new Map();
  private static sources: Map<number, DirectSourceState> = new Map();
  private static lutBuffers: Map<LutTable, ArrayBuffer> = new Map();
  private static curveBuffers: Map<string, ArrayBuffer> = new Map();
  private static assetSerial: number = 0;
  private static assetIds: Map<ArrayBuffer, number> = new Map();
  private static validatedTables: Map<LutTable, boolean> = new Map();
  private static gpuFailureCount: number = 0;
  private static gpuDisabledUntil: number = 0;
  private static lastDecline: string = '';
  private static lastDeclineAt: number = 0;

  private static decline(reason: string): null {
    const now = Date.now();
    if (reason !== GpuShaderBridge.lastDecline || now - GpuShaderBridge.lastDeclineAt > 1000) {
      console.info(`VIVID_EDIT_PERF stage=gpu-decline reason=${reason}`);
      GpuShaderBridge.lastDecline = reason;
      GpuShaderBridge.lastDeclineAt = now;
    }
    return null;
  }

  private static canUseGpu(): boolean {
    if (Date.now() >= GpuShaderBridge.gpuDisabledUntil) return true;
    GpuShaderBridge.decline('native-cooldown');
    return false;
  }

  private static recordGpuFailure(error: Object): void {
    GpuShaderBridge.gpuFailureCount++;
    // A missing/unsupported GLES path must not be retried for every slider
    // event. Keep a short cooldown so a surface recreated by ArkUI can still
    // recover, while avoiding a CPU fallback storm on devices without the
    // optional native renderer.
    if (GpuShaderBridge.gpuFailureCount >= 2) GpuShaderBridge.gpuDisabledUntil = Date.now() + 5000;
    console.info('VIVID_GPU fallback: ' + String(error));
  }

  private static recordGpuSuccess(): void {
    GpuShaderBridge.gpuFailureCount = 0;
    GpuShaderBridge.gpuDisabledUntil = 0;
  }
  private static nextKey(session: EditSession): string {
    let key = GpuShaderBridge.keys.get(session.sessionId);
    if (!key) { key = 'editor-' + (++GpuShaderBridge.serial); GpuShaderBridge.keys.set(session.sessionId, key); }
    return key;
  }

  /** Identity geometry for calls that are already in output coordinates. */
  private static identityGeometry(width: number, height: number): GpuOutputGeometry {
    return {
      width: width,
      height: height,
      uvMatrix: new Float32Array([1, 0, 0, 0, 1, 0, 0, 0, 1]).buffer,
    };
  }

  /** Bounded plate size shared by the GPU plate and the export tiling path. */
  private static bokehWorkSize(width: number, height: number): number[] {
    const maxEdge = 1200;
    const scale = Math.min(1, maxEdge / Math.max(width, height));
    return [
      Math.max(1, Math.round(width * scale)),
      Math.max(1, Math.round(height * scale)),
    ];
  }

  private static bokehOptions(session: EditSession, plate: BokehPlate | null = null,
    plateOnly: boolean = false, uvOffset: number[] | null = null,
    uvScale: number[] | null = null): GpuBokehOptions | null {
    if (!session.bokeh.enabled) return null;
    const depth = session.bokehDepth;
    if (!depth || session.bokehDepthWidth <= 0 || session.bokehDepthHeight <= 0) return null;
    // Match the CPU stage: it stretches the model's p1/p99 bytes back to the
    // full 0..255 range before solving CoC. Without this the GPU would use a
    // slightly narrower focus band than the export reference.
    let minimum = 255;
    let maximum = 0;
    for (let index = 0; index < depth.length; index++) {
      const value = depth[index];
      if (value < minimum) minimum = value;
      if (value > maximum) maximum = value;
    }
    const span = Math.max(1, maximum - minimum);
    const normalized = new Uint8Array(depth.length);
    for (let index = 0; index < depth.length; index++) {
      normalized[index] = Math.round(Math.max(0, Math.min(255,
        (depth[index] - minimum) * 255 / span)));
    }
    const options: GpuBokehOptions = {
      enabled: true,
      depth: normalized.buffer as ArrayBuffer,
      depthWidth: session.bokehDepthWidth,
      depthHeight: session.bokehDepthHeight,
      params: [
        session.bokeh.aperture,
        session.bokeh.blurStrength,
        session.bokeh.bokehStrength,
        session.bokeh.shape,
        session.bokeh.density,
        session.bokeh.size,
        session.bokeh.spherical,
        session.bokeh.focus,
      ],
      plateOnly: plateOnly,
    };
    if (plate !== null) {
      options.plate = plate.pixels;
      options.plateWidth = plate.width;
      options.plateHeight = plate.height;
    }
    if (uvOffset !== null) options.uvOffset = uvOffset;
    if (uvScale !== null) options.uvScale = uvScale;
    return options;
  }

  /**
   * 44MP+ exports cannot upload the whole frame as one GPU texture, so the
   * background plate is built once from a bounded downsampled frame. The
   * colour passes are still run on the GPU; only the downsample input is
   * prepared on the CPU, and the plate itself (the expensive bokeh gather) is
   * GPU. Per-tile compositing then samples this single whole-frame plate, so
   * tile edges cannot show a different blur.
   */
  private static async renderBokehPlate(source: ArrayBuffer, width: number,
    height: number, session: EditSession): Promise<BokehPlate | null> {
    if (!session.bokeh.enabled) return null;
    const work = GpuShaderBridge.bokehWorkSize(width, height);
    const plateWidth = work[0];
    const plateHeight = work[1];
    const downsampled = GpuShaderBridge.downsampleForPlate(source, width, height,
      plateWidth, plateHeight);
    const passes = GpuShaderBridge.buildPasses(session, plateWidth, plateHeight, true, true, false);
    if (!passes) return null;
    const bokeh: GpuBokehOptions | null = GpuShaderBridge.bokehOptions(session, null, true);
    if (!bokeh) return null;
    const version = ++GpuShaderBridge.serial;
    try {
      const pixels: ArrayBuffer = await gpuNative.renderStack(
        'vivid-bokeh-plate', '', downsampled, plateWidth, plateHeight, version, passes,
        GpuShaderBridge.identityGeometry(plateWidth, plateHeight), bokeh) as ArrayBuffer;
      GpuShaderBridge.recordGpuSuccess();
      return { pixels: pixels, width: plateWidth, height: plateHeight };
    } catch (error) {
      GpuShaderBridge.recordGpuFailure(error as Object);
      console.warn('VIVID_GPU bokeh plate failed: ' + String(error));
      return null;
    }
  }

  /** Bilinear downsample used only to feed the bounded bokeh plate. */
  private static downsampleForPlate(source: ArrayBuffer, width: number, height: number,
    targetWidth: number, targetHeight: number): ArrayBuffer {
    const input = new Uint8Array(source);
    const output = new Uint8Array(targetWidth * targetHeight * 4);
    const scaleX = width / targetWidth;
    const scaleY = height / targetHeight;
    for (let y = 0; y < targetHeight; y++) {
      const sourceY = Math.min(height - 1, Math.max(0, (y + 0.5) * scaleY - 0.5));
      const y0 = Math.floor(sourceY);
      const y1 = Math.min(height - 1, y0 + 1);
      const fy = sourceY - y0;
      for (let x = 0; x < targetWidth; x++) {
        const sourceX = Math.min(width - 1, Math.max(0, (x + 0.5) * scaleX - 0.5));
        const x0 = Math.floor(sourceX);
        const x1 = Math.min(width - 1, x0 + 1);
        const fx = sourceX - x0;
        const row0 = y0 * width * 4;
        const row1 = y1 * width * 4;
        const offset = (y * targetWidth + x) * 4;
        for (let channel = 0; channel < 4; channel++) {
          const top = input[row0 + x0 * 4 + channel] * (1 - fx) +
            input[row0 + x1 * 4 + channel] * fx;
          const bottom = input[row1 + x0 * 4 + channel] * (1 - fx) +
            input[row1 + x1 * 4 + channel] * fx;
          output[offset + channel] = Math.round(top * (1 - fy) + bottom * fy);
        }
      }
    }
    return output.buffer as ArrayBuffer;
  }

  static release(session: EditSession): void {
    const key = GpuShaderBridge.keys.get(session.sessionId);
    const surface = session.gpuSurfaceId;
    const mustClear = session.gpuSurfaceDirty && surface.length > 0;
    GpuShaderBridge.keys.delete(session.sessionId);
    GpuShaderBridge.sources.delete(session.sessionId);
    if (!key) return;
    // RenderService can keep compositing the last window buffer after ArkUI
    // hides or rebuilds the XComponent. Queue a transparent swap before the
    // native session is destroyed; release still runs when the surface has
    // already gone away. A following image uses a new key, so the old cleanup
    // can never erase the new photo's resident texture.
    const cleared: Promise<void> = mustClear
      ? gpuNative.clearSurface(key, surface).then((): void => {}).catch((_error: Object): void => {})
      : Promise.resolve();
    cleared.finally(() => { gpuNative.releaseSession(key).catch(() => {}); }).catch(() => {});
  }

  /** XComponent was destroyed while the editor session survives (for example
   * a layout/theme rebuild). The native texture may still exist, but the next
   * surface must upload from the authoritative PixelMap instead of assuming a
   * source attached to the previous window is still valid. */
  static surfaceDestroyed(session: EditSession): void {
    GpuShaderBridge.sources.delete(session.sessionId);
  }

  /** Swap one fully transparent frame onto the direct EGL window so the last
   *  presented GPU frame stops covering a ready CPU replacement. GPU
   *  before/after uses the same surface without clearing it. ArkUI opacity cannot hide the native surface layer on every
   *  device; only a transparent eglSwapBuffers reliably uncovers the stack. */
  static async clearDirectSurface(session: EditSession): Promise<void> {
    const key = GpuShaderBridge.keys.get(session.sessionId);
    const surface = session.gpuSurfaceId;
    if (!key || surface.length === 0) return;
    try {
      await gpuNative.clearSurface(key, surface);
      console.info(`VIVID_FRAME t=${Date.now()} event=gpu_surface_clear key=${key}`);
    } catch (error) {
      console.warn('VIVID_GPU surface clear failed: ' + String(error));
    }
  }

  /**
   * Size of the resident direct-preview source texture, or an empty array when
   * there is none. The hold-to-original path presents the ungraded texture and
   * must use the same dimensions so it can reuse that upload instead of
   * uploading a second copy just for the comparison.
   */
  static residentSourceSize(session: EditSession): number[] {
    const state = GpuShaderBridge.sources.get(session.sessionId);
    return state ? [state.width, state.height] : [];
  }

  static needsSource(session: EditSession, source: Object, width: number, height: number,
    snapshot?: EditSession): boolean {
    const state = GpuShaderBridge.sources.get(session.sessionId);
    if (!state || state.pixelMap !== source || state.width !== width || state.height !== height) return true;
    if (state.retouchKey !== JSON.stringify((snapshot ?? session).retouchMarks)) return true;
    // The resident texture is the full source. Crop/rotation only change the
    // final sampling matrix and must not invalidate or upload that texture.
    return false;
  }

  static async present(session: EditSession, snapshot: EditSession, source: Object,
    pixels: ArrayBuffer | null, width: number, height: number, surface: string): Promise<boolean> {
    if (!GpuShaderBridge.canUseGpu()) return false;
    const passes = GpuShaderBridge.buildPasses(snapshot, width, height, true, true);
    if (!passes) return false;
    const key = GpuShaderBridge.nextKey(session);
    const changed = GpuShaderBridge.needsSource(session, source, width, height, snapshot);
    const version = changed ? ++GpuShaderBridge.serial : (GpuShaderBridge.sources.get(session.sessionId)?.version ?? 0);
    const bokeh: GpuBokehOptions | null = GpuShaderBridge.bokehOptions(snapshot);
    try {
      await gpuNative.renderStack(key, surface, changed ? pixels : null, width, height, version, passes,
        GpuShaderBridge.outputGeometry(snapshot, width, height), bokeh ?? undefined);
      if (GpuShaderBridge.keys.get(session.sessionId) !== key) return false;
      GpuShaderBridge.sources.set(session.sessionId, {
        pixelMap: source, width: width, height: height, version: version,
        retouchKey: JSON.stringify(snapshot.retouchMarks),
      });
      GpuShaderBridge.recordGpuSuccess();
      return true;
    } catch (error) {
      GpuShaderBridge.recordGpuFailure(error as Object);
      GpuShaderBridge.sources.delete(session.sessionId);
      return false;
    }
  }

  static async renderPreview(source: ArrayBuffer, width: number, height: number,
    session: EditSession): Promise<ArrayBuffer | null> {
    if (!GpuShaderBridge.canUseGpu()) return null;
    const passes = GpuShaderBridge.buildPasses(session, width, height, true, true);
    if (!passes) return null;
    if (width * height > 16777216 || (width * height > 4194304 &&
      passes.some((pass: NativeGpuOptions): boolean => pass.grain[0] > 0))) {
      return GpuShaderBridge.decline('readback-memory-limit');
    }
    // Persistent readback session: the EGL context, programs and cached pass
    // textures survive across calls. The version increments per call so the
    // source texture is re-uploaded (content changes every render).
    const version = ++GpuShaderBridge.serial;
    const bokeh: GpuBokehOptions | null = GpuShaderBridge.bokehOptions(session);
    try {
      const output: ArrayBuffer = await gpuNative.renderStack(
        'vivid-readback', '', source, width, height, version, passes,
        GpuShaderBridge.outputGeometry(session, width, height), bokeh ?? undefined) as ArrayBuffer;
      GpuShaderBridge.recordGpuSuccess();
      return output;
    } catch (error) {
      GpuShaderBridge.recordGpuFailure(error as Object);
      return null;
    }
  }

  /** Full-resolution export readback. Renders the un-cropped frame with the
   * same native pass list as the preview path; rotation/flip and crop run
   * downstream in TaskPool (applyGeometryTask) or the native remap. A crop is a
   * framing decision on the finished frame, not a reason to drop the whole
   * export to the CPU: the preview already allows it, so declining it here made
   * the same session render on two different backends. */
  static async renderExport(source: ArrayBuffer, width: number, height: number,
    session: EditSession): Promise<ArrayBuffer | null> {
    if (!GpuShaderBridge.canUseGpu()) return null;
    // GPU readback needs source texture, render target and an RGBA readback
    // buffer at once. A 45MP frame exceeded the old 256MP guard long before it
    // reached that value on phone GPUs, causing driver allocation failures.
    // Larger originals remain supported through the TaskPool CPU export path.
    // 纯尺寸上限必须**先于** buildPasses：buildPasses 会按全分辨率栅格化每个
    // 蒙版的 alpha，而注定被拒的大图随后把这份结果整个丢掉（44MP 实测这一步
    // 在十几秒的前置开销里占相当一块）。grain 那一项依赖 passes，留在后面。
    if (width * height <= 24000000) {
      return GpuShaderBridge.renderExportWhole(source, width, height, session);
    }
    // 大图瓦片导出：把整帧切成 ≤16MP 的竖条逐块走 GPU，再拼回完整缓冲。
    // 这是"44MP 被 24MP 上限拒掉、退回 95 秒 CPU 兜底"的出路；实测 44MP 导出
    // 的 105 秒里有 95 秒花在那条 ArkTS 逐像素管线上，GPU 化是唯一的量级收益。
    //
    // 大光圈不能按瓦片各自生成背景板，否则接缝处虚化强度会不同：先从整帧的
    // 有界降采样生成一张全场 plate，再让每块瓦片只做全分辨率合成。
    //
    // 约束（与既有守卫同一哲学：宁可退回 CPU，也不产出与整帧渲染不一致的图）：
    // - 晕影/颗粒按**整帧坐标**计算（shader 里用 uFrameSize），分块后语义改变
    //   → 退回 CPU；
    // - 降噪是**邻域**操作，瓦片边界会切出接缝 → 退回 CPU；
    // - 掩码 UV 归一化，每 pass 的 mask/maskWidth/maskHeight 随瓦片切片即可。
    const passes0 = GpuShaderBridge.buildPasses(session, width, height, true, true);
    if (passes0 === null) return null;
    for (const pass of passes0) {
      if (pass.vignette[0] !== 0 || pass.grain[0] > 0 ||
        (pass.denoise !== undefined && pass.denoise.length > 0)) {
        return GpuShaderBridge.decline('tile-spatial-effect');
      }
    }
    const plate = session.bokeh.enabled
      ? await GpuShaderBridge.renderBokehPlate(source, width, height, session) : null;
    if (session.bokeh.enabled && plate === null) return null;
    return GpuShaderBridge.renderExportTiled(source, width, height, session, passes0, plate);
  }

  /** ≤24MP 整帧导出（原路径，行为不变）。 */
  private static async renderExportWhole(source: ArrayBuffer, width: number, height: number,
    session: EditSession): Promise<ArrayBuffer | null> {
    const passesStart = Date.now();
    const passes = GpuShaderBridge.buildPasses(session, width, height, true, true);
    if (!passes || (passes.length === 0 && !session.bokeh.enabled)) return null;
    const passesMs = Date.now() - passesStart;
    if (width * height > 4194304 &&
      passes.some((pass: NativeGpuOptions): boolean => pass.grain[0] > 0)) {
      console.info(`VIVID_EDIT_PERF stage=export-decline passesMs=${passesMs} size=${width}x${height}`);
      return GpuShaderBridge.decline('export-memory-limit');
    }
    if (passesMs > 300) {
      console.info(`VIVID_EDIT_PERF stage=export-passes ms=${passesMs}` +
        ` size=${width}x${height} passes=${passes.length}`);
    }
    // Dedicated readback session: export-sized pbuffers must not resize the
    // preview readback session's surfaces on every alternation.
    const version = ++GpuShaderBridge.serial;
    const bokeh: GpuBokehOptions | null = GpuShaderBridge.bokehOptions(session);
    try {
      const output: ArrayBuffer = await gpuNative.renderStack(
        'vivid-export', '', source, width, height, version, passes,
        GpuShaderBridge.identityGeometry(width, height), bokeh ?? undefined) as ArrayBuffer;
      GpuShaderBridge.recordGpuSuccess();
      return output;
    } catch (error) {
      GpuShaderBridge.recordGpuFailure(error as Object);
      return null;
    }
  }

  /**
   * 大图瓦片导出。竖条高度 = 整帧高度，宽度按 ≤16MP 分配；竖条（而不是方块）
   * 让每片内部的行连续拷贝保持整行，切片代码简单且缓存友好。
   *
   * 每片独立调用 renderStack（native 端每次调用自建/自毁 EGL 环境，无跨调用
   * 状态），渲染结果直接 memcpy 进输出大缓冲。掩码按同一竖条范围切片。
   */
  private static async renderExportTiled(source: ArrayBuffer, width: number, height: number,
    session: EditSession, wholePasses: NativeGpuOptions[],
    bokehPlate: BokehPlate | null): Promise<ArrayBuffer | null> {
    if (session.bokeh.enabled && bokehPlate === null) return null;
    // 大光圈导出多一张整帧 plate 和每片 bokeh 合成纹理，16MP 竖条在 44MP
    // 原图上会把「源 + 输出 + 切片 + 切片输出」推到 470MB 左右；8MP 竖条把
    // 峰值降约 60MB，代价只是多几次 GPU 调用。没有 bokeh 时维持 16MP。
    const tileMaxPixels = bokehPlate !== null ? 8000000 : 16000000;
    const tileCount = Math.ceil(width * height / tileMaxPixels);
    const tileWidth = Math.ceil(width / tileCount);
    const output = new ArrayBuffer(width * height * 4);
    const out8 = new Uint8Array(output);
    const src8 = new Uint8Array(source);
    const startedAt = Date.now();
    let tilesDone = 0;
    for (let tileIndex = 0; tileIndex < tileCount; tileIndex++) {
      const x0 = tileIndex * tileWidth;
      const x1 = Math.min(width, x0 + tileWidth);
      const tw = x1 - x0;
      if (tw <= 0) break;
      // 源切片：每行 memcpy 整段竖条。
      const tileInput = new ArrayBuffer(tw * height * 4);
      const tile8 = new Uint8Array(tileInput);
      const rowBytes = tw * 4;
      for (let y = 0; y < height; y++) {
        const srcRow = y * width * 4 + x0 * 4;
        tile8.set(src8.subarray(srcRow, srcRow + rowBytes), y * rowBytes);
      }
      // pass 复制 + 掩码切片：掩码 UV 归一化，竖条内的 mask 即该列范围的 alpha。
      const tilePasses: NativeGpuOptions[] = [];
      for (const wholePass of wholePasses) {
        // 整个 pass 逐字段复制。此前这里是手写的 20 字段子集，于是大图瓦片导出
        // 丢掉了 LUT、颜色分级、不透明度、混合模式和 maskEnabled：GPU 报告成功，
        // 画面却与预览不同（局部调整还变成了全局）。copyPass 是唯一的复制入口，
        // 瓦片只覆写掩码几何。
        const tilePass: NativeGpuOptions = GpuShaderBridge.copyPass(wholePass);
        if (wholePass.maskEnabled && wholePass.mask && wholePass.maskWidth === width &&
          wholePass.maskHeight === height) {
          const mask8 = new Uint8Array(wholePass.mask);
          const tileMask = new ArrayBuffer(tw * height);
          const tileMask8 = new Uint8Array(tileMask);
          for (let y = 0; y < height; y++) {
            const srcRow = y * width + x0;
            tileMask8.set(mask8.subarray(srcRow, srcRow + tw), y * tw);
          }
          tilePass.mask = tileMask;
          tilePass.maskWidth = tw;
          tilePass.maskHeight = height;
          // 新缓冲必须换一个 asset ID：native 的纹理缓存按 (ID, 宽, 高) 判等，
          // 沿用整帧掩码的 ID 会让第二块瓦片复用第一块上传的掩码纹理。
          tilePass.maskId = GpuShaderBridge.assetId(tileMask);
        }
        tilePasses.push(tilePass);
      }
      const version = ++GpuShaderBridge.serial;
      const bokeh: GpuBokehOptions | null = session.bokeh.enabled
        ? GpuShaderBridge.bokehOptions(session, bokehPlate, false,
          [x0 / width, 0], [tw / width, 1]) : null;
      try {
        const tileOutput: ArrayBuffer = await gpuNative.renderStack(
          'vivid-export-tile', '', tileInput, tw, height, version, tilePasses,
          GpuShaderBridge.identityGeometry(tw, height), bokeh ?? undefined) as ArrayBuffer;
        GpuShaderBridge.recordGpuSuccess();
        // 拼回：逐行写回该列范围。
        const tileOut8 = new Uint8Array(tileOutput);
        for (let y = 0; y < height; y++) {
          const dstRow = y * width * 4 + x0 * 4;
          out8.set(tileOut8.subarray(y * rowBytes, y * rowBytes + rowBytes), dstRow);
        }
      } catch (error) {
        GpuShaderBridge.recordGpuFailure(error as Object);
        console.warn(`VIVID_EDIT_PERF stage=export-tile-failed tile=${tileIndex}/${tileCount}`);
        return null;
      }
      tilesDone++;
      console.info(`VIVID_EDIT_PERF stage=export-tile done=${tilesDone}/${tileCount} ` +
        `x=${x0}..${x1} ms=${Date.now() - startedAt}`);
    }
    console.info(`VIVID_EDIT_PERF stage=export-tiled tiles=${tilesDone} ` +
      `ms=${Date.now() - startedAt} size=${width}x${height} passes=${wholePasses.length}`);
    return output;
  }

  /**
   * Copy EVERY field of a native pass.
   *
   * This is the single copy point for the tiled export. It exists because the
   * hand-written subset it replaces silently dropped 36 of the 56 fields, and
   * the failure mode was invisible: the native renderer returned success while
   * the LUT, the colour grade, the layer opacity/blend mode and mask enable
   * flag were all missing, so a >24MP export looked nothing like the preview.
   *
   * `tools/check_gpu_tile_passes.cjs` parses `interface NativeGpuOptions` and
   * fails if any declared field is not assigned here, so adding a field to the
   * interface without teaching this function about it is a test failure rather
   * than a silent export regression.
   */
  private static copyPass(pass: NativeGpuOptions): NativeGpuOptions {
    const copy: NativeGpuOptions = {
      matrix: pass.matrix,
      toneCurve: pass.toneCurve,
      redCurve: pass.redCurve,
      greenCurve: pass.greenCurve,
      blueCurve: pass.blueCurve,
      parametricCurve: pass.parametricCurve,
      mixHue: pass.mixHue,
      mixSaturation: pass.mixSaturation,
      mixLuminance: pass.mixLuminance,
      tonal: pass.tonal,
      whiteBalanceGain: pass.whiteBalanceGain,
      exposureGain: pass.exposureGain,
      vignette: pass.vignette,
      grain: pass.grain,
      whiteBalanceEnabled: pass.whiteBalanceEnabled,
      vibrance: pass.vibrance,
      calibrationHue: pass.calibrationHue,
      calibrationSaturation: pass.calibrationSaturation,
      mixerEnabled: pass.mixerEnabled,
    };
    copy.denoise = pass.denoise;
    copy.toneCurveId = pass.toneCurveId;
    copy.redCurveId = pass.redCurveId;
    copy.greenCurveId = pass.greenCurveId;
    copy.blueCurveId = pass.blueCurveId;
    copy.lutId = pass.lutId;
    copy.maskId = pass.maskId;
    copy.parametricEnabled = pass.parametricEnabled;
    copy.parametricRefine = pass.parametricRefine;
    copy.lut = pass.lut;
    copy.mask = pass.mask;
    copy.lutDomainMin = pass.lutDomainMin;
    copy.lutDomainScale = pass.lutDomainScale;
    copy.maskWidth = pass.maskWidth;
    copy.maskHeight = pass.maskHeight;
    copy.lutEnabled = pass.lutEnabled;
    copy.lutSize = pass.lutSize;
    copy.maskEnabled = pass.maskEnabled;
    copy.maskOpacity = pass.maskOpacity;
    copy.opacity = pass.opacity;
    copy.blendMode = pass.blendMode;
    copy.lutIntensity = pass.lutIntensity;
    copy.gradingShadowsTarget = pass.gradingShadowsTarget;
    copy.gradingMidtonesTarget = pass.gradingMidtonesTarget;
    copy.gradingHighlightsTarget = pass.gradingHighlightsTarget;
    copy.gradingGlobalTarget = pass.gradingGlobalTarget;
    copy.gradingShadowsSaturation = pass.gradingShadowsSaturation;
    copy.gradingShadowsLuminance = pass.gradingShadowsLuminance;
    copy.gradingMidtonesSaturation = pass.gradingMidtonesSaturation;
    copy.gradingMidtonesLuminance = pass.gradingMidtonesLuminance;
    copy.gradingHighlightsSaturation = pass.gradingHighlightsSaturation;
    copy.gradingHighlightsLuminance = pass.gradingHighlightsLuminance;
    copy.gradingGlobalSaturation = pass.gradingGlobalSaturation;
    copy.gradingGlobalLuminance = pass.gradingGlobalLuminance;
    copy.gradingBlending = pass.gradingBlending;
    copy.gradingBalance = pass.gradingBalance;
    copy.gradingEnabled = pass.gradingEnabled;
    return copy;
  }

  static async renderLutPreview(source: ArrayBuffer, width: number, height: number,
    table: LutTable): Promise<ArrayBuffer | null> {
    if (!GpuShaderBridge.canUseGpu()) return null;
    if (!GpuShaderBridge.isDisplayLutTable(table)) return null;
    const pass = GpuShaderBridge.optionsFor(new ColorAdjustments());
    pass.lut = GpuShaderBridge.tableBuffer(table); pass.lutSize = table.size;
    pass.lutEnabled = true; pass.lutIntensity = 1;
    GpuShaderBridge.setLutDomain(pass, table);
    const version = ++GpuShaderBridge.serial;
    GpuShaderBridge.identifyAssets(pass);
    try { return await gpuNative.renderStack('vivid-readback', '', source, width, height, version, [pass]); }
    catch (error) { GpuShaderBridge.recordGpuFailure(error as Object); return null; }
  }

  /** Build the native pass list. `allowCrop` marks callers that render the
   * uncropped frame and apply the crop downstream: the on-surface path bakes it
   * into the display matrix, and the export path applies it afterwards with
   * `applyGeometryTask` / the native remap. Both therefore accept a non-neutral
   * crop; only a caller that published the readback buffer verbatim would have
   * to decline it.
   * `allowTransform` marks readback callers that apply rotation/flip on the
   * finished buffer (export geometry post-pass) instead of in the shader. */
  static buildPasses(session: EditSession, width: number, height: number,
    allowCrop: boolean = false, allowTransform: boolean = false,
    includeBokeh: boolean = true): NativeGpuOptions[] | null {
    const rotation = ((session.rotation % 360) + 360) % 360;
    if (rotation !== 0 && rotation !== 90 && rotation !== 180 && rotation !== 270) return GpuShaderBridge.decline('non-quarter-rotation');
    if (!allowTransform && (session.rotation !== 0 || session.flipH || session.flipV)) return GpuShaderBridge.decline('transform');
    if (!allowCrop && (session.cropLeft !== 0 || session.cropTop !== 0 ||
      session.cropRight !== 1 || session.cropBottom !== 1)) return GpuShaderBridge.decline('crop');
    // Texture, clarity, dehaze and sharpening are full-frame neighbourhood
    // operations with no shader implementation. Decline so the CPU path renders
    // them: a GPU frame that silently omitted them would disagree with export.
    if (!session.detail.isBypass()) return GpuShaderBridge.decline('local-contrast');
    // Lens corrections have no shader implementation either: distortion and CA
    // are per-channel radial resamples and defringe is an edge-gated nonlinear
    // stage. Decline so the CPU renders them rather than emit a frame that
    // silently omits the correction.
    if (!session.optics.isBypass()) return GpuShaderBridge.decline('optics');
    // 大光圈在原生 GPU 里是颜色 pass 之后的独立离屏阶段（深度图可用时）。
    // 没有深度图时仍拒绝 GPU，避免用错误的中心对焦近似覆盖用户的导出。
    if (includeBokeh && session.bokeh.enabled && !session.hasBokehDepth()) {
      return GpuShaderBridge.decline('bokeh-depth');
    }
    // Point colour is a per-pixel HSL transform with a weight falloff and no shader
    // implementation. Decline so the CPU grades those pixels rather than emitting a
    // frame that silently omits the correction.
    if (!session.pointColor.isBypass()) return GpuShaderBridge.decline('point-color');
    if (!session.oklch.isBypass()) return GpuShaderBridge.decline('oklch');
    if (!session.blackWhite.isBypass()) return GpuShaderBridge.decline('black-white');
    // The parametric tone curve is implemented in the single-pass shader in
    // vivid_gpu.cpp, but that is NOT the pipeline this process runs. Both the resident
    // preview and the readback export go through the multi-pass stack renderer in
    // vivid_gpu_pipeline.inc, and that file has no parametric support at all -- no
    // uniform, no texture, no sampling. Measured on the real GLES harness, the GPU frame
    // therefore omitted the curve completely and differed from the CPU by up to 14 8-bit
    // levels. Decline rather than publish a frame that silently drops the correction.
    if (!GpuShaderBridge.parametricIsIdentity(session)) {
      return GpuShaderBridge.decline('parametric-curve');
    }
    // The native denoise pass takes four parameters (luminance, colour, detail,
    // colour detail) and derives its spatial radius from the frame size
    // (vivid_gpu.cpp nrRadius -> 2..5 by long edge). It has no uniform for the
    // LEGACY fixed radius, so a photo pinned to process version 1 would be
    // filtered with a different neighbourhood on the GPU than the CPU worker and
    // the main-thread fallback use (all three must agree, or preview and export
    // disagree). Decline so the legacy photo renders on the CPU with its pinned
    // radius; a CURRENT photo resolves to the same frame-relative rule the
    // shader implements.
    if (denoiseEnabled(session.denoise) &&
      processBehaviors(session.processVersion).denoiseFixedRadius > 0) {
      return GpuShaderBridge.decline('denoise-version');
    }
    // Detail-region spatial effects use full-image coordinates on the CPU.
    // Never silently renormalise them to the dimensions of the region.
    // The native denoise uniform carries four of the six noise-reduction parameters.
    // Luminance contrast and colour smoothness are implemented only in the CPU core, so a
    // non-default value for either one declines the GPU: otherwise the GPU preview would
    // show a denoise the CPU export does not reproduce. The cost is honest and visible --
    // moving those two sliders drops the preview to the CPU path.
    if (denoiseEnabled(session.denoise) &&
      (session.denoise.luminanceContrast !== 0 || session.denoise.colorSmoothness !== 0.5)) {
      return GpuShaderBridge.decline('denoise-extras');
    }
    const passes: NativeGpuOptions[] = [];
    if (denoiseEnabled(session.denoise)) {
      const noise = GpuShaderBridge.optionsFor(new ColorAdjustments());
      noise.denoise = [session.denoise.luminance, session.denoise.color,
        session.denoise.detail, session.denoise.colorDetail];
      passes.push(noise);
    }
    for (const layer of session.layers) {
      if (!layer.visible || layer.opacity <= 0) continue;
      layer.migrateMask();
      const pass = GpuShaderBridge.optionsFor(layer.adjustments);
      pass.opacity = layer.opacity; pass.blendMode = layer.blendMode;
      const hasLayerAdjustments = !ColorMatrixBuilder.isIdentity(
        ColorMatrixBuilder.build(layer.adjustments)) || layer.adjustments.hasAdvancedAdjustments();
      if (layer.maskLayers.length === 0 && layer.mask && layer.mask.type !== 0) {
        // Structured migration normally handles this case. Decline legacy
        // local adjustments whose two-stage semantics differ from one pass.
        if (layer.maskAdjustments.hasAdvancedAdjustments() ||
          !ColorMatrixBuilder.isIdentity(ColorMatrixBuilder.build(layer.maskAdjustments))) return GpuShaderBridge.decline('legacy-local-adjustments');
        const key = layer.id + ':legacy:' + width + 'x' + height;
        let mask = session.maskCache.get(key);
        if (!mask) { mask = MaskRenderer.renderMask(layer.mask, width, height); session.maskCache.set(key, mask); }
         pass.mask = mask.buffer as ArrayBuffer; pass.maskWidth = width; pass.maskHeight = height; pass.maskEnabled = true;
      }
      // Match the worker pipeline: a structured-mask layer with no global
      // adjustments contributes only its local mask passes. Emitting an
      // identity pass here would be harmless for NORMAL, but would apply a
      // blend mode twice and make GPU/CPU results diverge for MULTIPLY,
      // SCREEN, or OVERLAY.
      const hasLegacyMask = layer.maskLayers.length === 0 && layer.mask !== null && layer.mask.type !== 0;
      if (hasLayerAdjustments || hasLegacyMask) passes.push(pass);
      for (const local of layer.maskLayers) {
        if (!local.enabled || !local.visible || local.opacity <= 0 || local.components.length === 0) continue;
        const key = layer.id + ':' + local.id + ':' + session.maskRevision + ':' + width + 'x' + height;
        let mask = session.maskCache.get(key);
        if (!mask) {
          // 自动蒙版代理未就绪时 renderMaskLayerSync 返回 null：这一帧用无门限
          // 版本，但绝不写缓存（代理到位后 ImageProcessor 会清缓存重算）。
          const auto = ImageProcessor.renderMaskLayerSync(session, local, width, height);
          mask = auto !== null ? auto
            : MaskRenderer.renderMaskLayerCapped(local, width, height, GpuShaderBridge.MASK_RASTER_MAX_EDGE);
          if (auto !== null) session.maskCache.set(key, mask);
        }
        const masked = GpuShaderBridge.optionsFor(local.adjustments);
        masked.opacity = layer.opacity;
        masked.mask = mask.buffer as ArrayBuffer; masked.maskWidth = width; masked.maskHeight = height; masked.maskEnabled = true;
        passes.push(masked);
      }
    }
    for (const item of session.lutStack) {
      if (!item.enabled || item.intensity <= 0) continue;
      if (!Number.isFinite(item.intensity)) return GpuShaderBridge.decline('lut-intensity');
      const table = item.lut?.table;
      if (!table) return GpuShaderBridge.decline('lut-missing');
      if (!GpuShaderBridge.isDisplayLutTable(table)) return GpuShaderBridge.decline('lut-table-or-range');
      const pass = GpuShaderBridge.optionsFor(new ColorAdjustments());
      pass.lut = GpuShaderBridge.tableBuffer(table); pass.lutSize = table.size; pass.lutEnabled = true;
      pass.lutIntensity = Math.max(0, Math.min(1, item.intensity)); passes.push(pass);
      GpuShaderBridge.setLutDomain(pass, table);
    }
    if (session.renderViewport.length > 0 && passes.some((pass: NativeGpuOptions): boolean =>
      pass.vignette[0] !== 0 || pass.grain[0] > 0)) return GpuShaderBridge.decline('detail-spatial-viewport');
    for (const pass of passes) GpuShaderBridge.identifyAssets(pass);
    return passes.length <= 64 ? passes : GpuShaderBridge.decline('pass-limit');
  }

  /**
   * True when nothing that can reach the frame carries a parametric tone curve.
   *
   * Only the four region amounts matter: moving a split or the refinement slider with every
   * amount at zero still integrates to the identity, exactly as `optionsFor` assumes, so
   * those two must NOT decline the GPU.
   *
   * The traversal must skip exactly what `buildPasses` skips. A hidden layer, a
   * zero-opacity layer and a disabled/hidden/opacity-0/component-less mask layer
   * contribute no pass, so a curve stored on one of them cannot reach a pixel —
   * declining the whole frame for it dropped the entire preview to the CPU for a
   * setting that has no effect.
   */
  private static parametricIsIdentity(session: EditSession): boolean {
    for (const layer of session.layers) {
      if (!layer.visible || layer.opacity <= 0) continue;
      if (GpuShaderBridge.hasParametricCurve(layer.adjustments)) return false;
      for (const local of layer.maskLayers) {
        if (!local.enabled || !local.visible || local.opacity <= 0 ||
          local.components.length === 0) continue;
        if (GpuShaderBridge.hasParametricCurve(local.adjustments)) return false;
      }
    }
    return true;
  }

  private static hasParametricCurve(adj: ColorAdjustments): boolean {
    if (!adj) return false;
    return adj.parametricHighlights !== 0 || adj.parametricLights !== 0 ||
      adj.parametricDarks !== 0 || adj.parametricShadows !== 0;
  }

  private static assetId(buffer: ArrayBuffer): number {
    const cached = GpuShaderBridge.assetIds.get(buffer);
    if (cached !== undefined) return cached;
    // Bounded references; re-identification after eviction only causes a safe
    // cache miss. An ID is never reused for another buffer.
    if (GpuShaderBridge.assetIds.size >= 128) GpuShaderBridge.assetIds.clear();
    const id = ++GpuShaderBridge.assetSerial;
    GpuShaderBridge.assetIds.set(buffer, id);
    return id;
  }

  private static identifyAssets(pass: NativeGpuOptions): void {
    pass.toneCurveId = GpuShaderBridge.assetId(pass.toneCurve);
    pass.redCurveId = GpuShaderBridge.assetId(pass.redCurve);
    pass.greenCurveId = GpuShaderBridge.assetId(pass.greenCurve);
    pass.blueCurveId = GpuShaderBridge.assetId(pass.blueCurve);
    if (pass.lut) pass.lutId = GpuShaderBridge.assetId(pass.lut);
    if (pass.mask) pass.maskId = GpuShaderBridge.assetId(pass.mask);
  }

  /** UV matrix of the final present pass: crop, quarter-turn rotation, flips.
   * The coefficients come from the same GeometryMath map the CPU paths use, so
   * the EGL surface and the readback renderer cannot disagree. */
  static outputGeometry(session: EditSession, width: number, height: number): GpuOutputGeometry {
    const map = buildGeometryMap(session.geometry, width, height, {
      width: width, height: height,
      cropLeft: session.cropLeft, cropTop: session.cropTop,
      cropRight: session.cropRight, cropBottom: session.cropBottom,
      rotation: session.rotation, flipH: session.flipH, flipV: session.flipV,
    }, {
      referenceWidth: Math.max(1, Math.round(session.imageWidth)),
      referenceHeight: Math.max(1, Math.round(session.imageHeight)),
    });
    const remap = (x: number, y: number): number[] => {
      const frame = displayToFrame(map, x, y);
      if (!frame) return [0, 0];
      return [frame[0] / width, frame[1] / height];
    };
    const origin = remap(0, 0);
    const horizontal = remap(1, 0);
    const vertical = remap(0, 1);
    const matrix = new Float32Array([
      horizontal[0] - origin[0], horizontal[1] - origin[1], 0,
      vertical[0] - origin[0], vertical[1] - origin[1], 0,
      origin[0], origin[1], 1,
    ]);
    return { width: map.outputWidth, height: map.outputHeight,
      uvMatrix: matrix.buffer as ArrayBuffer };
  }

  private static tableBuffer(table: LutTable): ArrayBuffer {
    let buffer = GpuShaderBridge.lutBuffers.get(table);
    if (!buffer) {
      buffer = GpuShaderBridge.lutBuffer(table.values);
      if (GpuShaderBridge.lutBuffers.size >= 8) GpuShaderBridge.lutBuffers.clear();
      GpuShaderBridge.lutBuffers.set(table, buffer);
    }
    return buffer;
  }

  private static optionsFor(adj: ColorAdjustments): NativeGpuOptions {
    const matrix = ColorMatrixBuilder.build(adj);
    // Only the region amounts matter; moving a split with every amount at zero
    // still integrates to the identity.
    const parametricActive = adj.parametricHighlights !== 0 || adj.parametricLights !== 0 ||
      adj.parametricDarks !== 0 || adj.parametricShadows !== 0;
    const options: NativeGpuOptions = {
      matrix: GpuShaderBridge.floatBuffer(matrix),
      toneCurve: GpuShaderBridge.curveBuffer(adj.toneCurvePoints, adj.toneCurve, false),
      redCurve: GpuShaderBridge.curveBuffer(adj.redCurvePoints, adj.curveRed, true),
      greenCurve: GpuShaderBridge.curveBuffer(adj.greenCurvePoints, adj.curveGreen, true),
      blueCurve: GpuShaderBridge.curveBuffer(adj.blueCurvePoints, adj.curveBlue, true),
      parametricCurve: GpuShaderBridge.parametricBuffer(adj, parametricActive),
      parametricEnabled: parametricActive,
      parametricRefine: adj.parametricRefineSaturation,
      mixHue: adj.mixHue.slice(),
      mixSaturation: adj.mixSaturation.slice(),
      mixLuminance: adj.mixLuminance.slice(),
      tonal: [adj.shadows, adj.blacks, adj.highlights, adj.whites],
      whiteBalanceGain: GpuShaderBridge.whiteBalanceGain(adj.temperature, adj.tint),
      exposureGain: Math.pow(2, adj.exposure * 2),
      vignette: [adj.vignetteAmount, adj.vignetteMidpoint, adj.vignetteRoundness,
        adj.vignetteFeather, adj.vignetteHighlights],
      grain: [adj.grainAmount, adj.grainSize, adj.grainRoughness],
      whiteBalanceEnabled: adj.temperature !== 0 || adj.tint !== 0,
      vibrance: adj.vibrance,
      calibrationHue: [adj.calibrationRedHue, adj.calibrationGreenHue, adj.calibrationBlueHue],
      calibrationSaturation: [adj.calibrationRedSaturation, adj.calibrationGreenSaturation, adj.calibrationBlueSaturation],
      mixerEnabled: adj.mixHue.some((value: number): boolean => value !== 0) ||
        adj.mixSaturation.some((value: number): boolean => value !== 0) ||
        adj.mixLuminance.some((value: number): boolean => value !== 0),
    };


    const gradingEnabled = adj.colorGradingEnabled && GpuShaderBridge.hasColorGrading(adj);
    options.gradingShadowsTarget = GpuShaderBridge.hslToRgb(adj.gradingShadowsHue,
      adj.gradingShadowsSaturation);
    options.gradingMidtonesTarget = GpuShaderBridge.hslToRgb(adj.gradingMidtonesHue,
      adj.gradingMidtonesSaturation);
    options.gradingHighlightsTarget = GpuShaderBridge.hslToRgb(adj.gradingHighlightsHue,
      adj.gradingHighlightsSaturation);
    options.gradingGlobalTarget = GpuShaderBridge.hslToRgb(adj.gradingGlobalHue,
      adj.gradingGlobalSaturation);
    options.gradingShadowsSaturation = adj.gradingShadowsSaturation;
    options.gradingShadowsLuminance = adj.gradingShadowsLuminance;
    options.gradingMidtonesSaturation = adj.gradingMidtonesSaturation;
    options.gradingMidtonesLuminance = adj.gradingMidtonesLuminance;
    options.gradingHighlightsSaturation = adj.gradingHighlightsSaturation;
    options.gradingHighlightsLuminance = adj.gradingHighlightsLuminance;
    options.gradingGlobalSaturation = adj.gradingGlobalSaturation;
    options.gradingGlobalLuminance = adj.gradingGlobalLuminance;
    options.gradingBlending = adj.gradingBlending;
    options.gradingBalance = adj.gradingBalance;
    options.gradingEnabled = gradingEnabled;


    return options;
  }
  /**
   * Scene-side white balance, shared verbatim with WorkerCore's CPU path.
   *
   * `tint` is the GREEN/MAGENTA axis and its sign must match the slider gradient
   * (DesktopRawSlider: left #D74BB5 magenta, right #42BE68 green). Positive tint
   * therefore lifts green and lowers red+blue. The old formula multiplied the
   * red/blue gains by `tint` (magenta) while the slider showed green on the
   * right, so the direction was inverted, and its coefficients
   * (`tint * 0.12` then another `* 0.12`) made full tint ~16x weaker than full
   * temperature. TINT_SCALE is now 0.24 with red/blue at half the log swing, so
   * full tint moves the neutral axis by roughly the same amount as full
   * temperature (measured in tools/check_tint_direction.cjs).
   */
  private static whiteBalanceGain(temperature: number, tint: number): number[] {
    const warmth = temperature * 0.22;
    const green = tint * 0.24;
    const r = Math.exp(warmth - green * 0.5);
    const g = Math.exp(green);
    const b = Math.exp(-warmth - green * 0.5);
    const normalise = 1 / Math.max(0.00001, r * 0.2126 + g * 0.7152 + b * 0.0722);
    return [r * normalise, g * normalise, b * normalise];
  }

  private static hasColorGrading(adj: ColorAdjustments): boolean {
    return adj.gradingShadowsHue !== 0 || adj.gradingShadowsSaturation !== 0 ||
      adj.gradingShadowsLuminance !== 0 || adj.gradingMidtonesHue !== 0 ||
      adj.gradingMidtonesSaturation !== 0 || adj.gradingMidtonesLuminance !== 0 ||
      adj.gradingHighlightsHue !== 0 || adj.gradingHighlightsSaturation !== 0 ||
      adj.gradingHighlightsLuminance !== 0 || adj.gradingGlobalHue !== 0 ||
      adj.gradingGlobalSaturation !== 0 || adj.gradingGlobalLuminance !== 0 ||
      adj.gradingBlending !== 0 || adj.gradingBalance !== 0;
  }

  private static hslToRgb(hueDegrees: number, saturationValue: number): number[] {
    const hue = ((hueDegrees / 360) % 1 + 1) % 1;
    const saturation = Math.max(0, Math.min(1, saturationValue));
    const c = saturation;
    const hp = hue * 6;
    const x = c * (1 - Math.abs((hp % 2) - 1));
    let r = 0;
    let g = 0;
    let b = 0;
    if (hp < 1) { r = c; g = x; }
    else if (hp < 2) { r = x; g = c; }
    else if (hp < 3) { g = c; b = x; }
    else if (hp < 4) { g = x; b = c; }
    else if (hp < 5) { r = x; b = c; }
    else { r = c; b = x; }
    const m = 0.5 - c * 0.5;
    return [r + m, g + m, b + m];
  }

  private static isDisplayLutTable(table: LutTable): boolean {
    const cached = GpuShaderBridge.validatedTables.get(table);
    if (cached !== undefined) return cached;
    const valid = GpuShaderBridge.validateDisplayLutTable(table);
    if (GpuShaderBridge.validatedTables.size >= 16) GpuShaderBridge.validatedTables.clear();
    GpuShaderBridge.validatedTables.set(table, valid);
    return valid;
  }

  private static validateDisplayLutTable(table: LutTable): boolean {
    // 65 is the largest standard .cube size (65^3). The shader packs the table
    // into a (size*size) x size RGBA16F atlas: 65^3 is 4225 x 65 and 2.2 MB.
    // That width exceeds the 4096 GLES3 floor, so the native stack renderer
    // compares it with the device's actual GL_MAX_TEXTURE_SIZE and rejects with
    // "LUT texture limit exceeded" when it does not fit; a 4096-limit device
    // then falls back to CPU instead of uploading a truncated table.
    if (!Number.isInteger(table.size) || table.size < 2 || table.size > 65 ||
      table.values.length !== table.size * table.size * table.size * 3 ||
      table.domainMin.length !== 3 || table.domainMax.length !== 3) return false;
    for (let c = 0; c < 3; c++) {
      if (!Number.isFinite(table.domainMin[c]) || !Number.isFinite(table.domainMax[c]) ||
        table.domainMax[c] <= table.domainMin[c]) return false;
      const scale = 1 / (table.domainMax[c] - table.domainMin[c]);
      if (!Number.isFinite(scale) || scale > 3.4e38 || Math.abs(table.domainMin[c]) > 3.4e38 ||
        Math.abs(table.domainMax[c]) > 3.4e38) return false;
    }
    // RGBA16F preserves extended-range table output (values outside [0,1]).
    // Only non-finite values still fall back: NaN/Inf cannot be represented
    // meaningfully by either the half-float GPU atlas or the float CPU path.
    for (let index = 0; index < table.values.length; index++) {
      if (!Number.isFinite(table.values[index])) return false;
    }
    return true;
  }

  private static setLutDomain(pass: NativeGpuOptions, table: LutTable): void {
    pass.lutDomainMin = table.domainMin.slice();
    pass.lutDomainScale = table.domainMax.map((high: number, c: number): number =>
      1 / (high - table.domainMin[c]));
  }

  private static floatBuffer(values: Float32Array): ArrayBuffer {
    const buffer = new ArrayBuffer(values.length * 4);
    new Float32Array(buffer).set(values);
    return buffer;
  }

  private static identityCurveBuffer(): ArrayBuffer {
    const curve = new Uint8Array(1025 * 4);
    for (let index = 0; index <= 1024; index++) {
      const value = Math.round(index / 1024 * 65535);
      curve[index * 4] = value >> 8;
      curve[index * 4 + 1] = value & 255;
      curve[index * 4 + 3] = 255;
    }
    return curve.buffer as ArrayBuffer;
  }

  private static halfScratchF: Float32Array = new Float32Array(1);
  private static halfScratchU: Uint32Array = new Uint32Array(GpuShaderBridge.halfScratchF.buffer);

  /** IEEE-754 binary32 -> binary16, truncating the low mantissa bits. The
   *  LUT atlas is GL_RGBA16F, so a 65^3 table is 8 bytes per texel and keeps
   *  extended-range values instead of clipping them like the old RGB8 atlas. */
  private static halfFloat(value: number): number {
    const f = GpuShaderBridge.halfScratchF;
    f[0] = Math.max(-65504, Math.min(65504, value));
    const bits = GpuShaderBridge.halfScratchU[0];
    const sign = (bits >>> 16) & 0x8000;
    let exponent = ((bits >>> 23) & 0xff) - 127 + 15;
    let mantissa = (bits >>> 13) & 0x3ff;
    if (exponent <= 0) {
      if (exponent < -10) return sign;
      mantissa = (mantissa | 0x400) >>> (1 - exponent);
      return sign | mantissa;
    }
    if (exponent >= 31) return sign | 0x7c00;
    return sign | (exponent << 10) | mantissa;
  }

  private static lutBuffer(values: number[]): ArrayBuffer {
    const texels = Math.floor(values.length / 3);
    const buffer = new Uint16Array(texels * 4);
    for (let index = 0, out = 0; index + 2 < values.length; index += 3, out += 4) {
      buffer[out] = GpuShaderBridge.halfFloat(values[index] ?? 0);
      buffer[out + 1] = GpuShaderBridge.halfFloat(values[index + 1] ?? 0);
      buffer[out + 2] = GpuShaderBridge.halfFloat(values[index + 2] ?? 0);
      buffer[out + 3] = 0x3c00; // 1.0, the alpha channel is unused by the shader.
    }
    return buffer.buffer as ArrayBuffer;
  }

  /** Linear interpolation into the 256-entry CPU parametric table, matching
   *  `WorkerCore.sampleTable` exactly so the two paths agree. */
  private static sampleParametricTable(table: Float32Array, value: number): number {
    const size = table.length;
    if (size === 0) return value;
    const clamped = Math.max(0, Math.min(1, value));
    const position = clamped * (size - 1);
    const index = Math.floor(position);
    if (index >= size - 1) return table[size - 1];
    return table[index] + (table[index + 1] - table[index]) * (position - index);
  }

  /**
   * Pack the parametric curve into a 1025x1 RGBA8 ramp using the same 16-bit
   * R+G packing as `curveBuffer`. The CPU table has 256 knots, so it is sampled
   * onto the shader's 1025-knot grid; both sides then interpolate linearly,
   * which is what the CPU/GPU parity test checks. Refinement is not packed here
   * — it needs the pixel's before/after saturation, so the shader measures it.
   */
  private static parametricBuffer(adj: ColorAdjustments, enabled: boolean): ArrayBuffer {
    const lut = new Uint8Array(1025 * 4);
    if (!enabled) {
      // Identity ramp, so the shader can consume the buffer unconditionally.
      for (let value = 0; value <= 1024; value++) {
        const encoded = Math.round((value / 1024) * 65535);
        lut[value * 4] = encoded >> 8;
        lut[value * 4 + 1] = encoded & 255;
        lut[value * 4 + 2] = 255;
        lut[value * 4 + 3] = 255;
      }
      return lut.buffer as ArrayBuffer;
    }
    const settings: ParametricCurveParams = {
      highlights: adj.parametricHighlights,
      lights: adj.parametricLights,
      darks: adj.parametricDarks,
      shadows: adj.parametricShadows,
      shadowSplit: adj.parametricShadowSplit,
      darkSplit: adj.parametricDarkSplit,
      lightSplit: adj.parametricLightSplit,
      refineSaturation: adj.parametricRefineSaturation,
    };
    const table = buildParametricLut(settings);
    for (let value = 0; value <= 1024; value++) {
      const y = GpuShaderBridge.sampleParametricTable(table, value / 1024);
      const encoded = Math.round(Math.max(0, Math.min(1, y)) * 65535);
      lut[value * 4] = encoded >> 8;
      lut[value * 4 + 1] = encoded & 255;
      lut[value * 4 + 2] = 255;
      lut[value * 4 + 3] = 255;
    }
    return lut.buffer as ArrayBuffer;
  }

  private static curveBuffer(points: CurveAnchor[], amount: number, channelCurve: boolean): ArrayBuffer {
    const key = (channelCurve ? 'rgb:' : 'tone:') + amount + ':' +
      (points ?? []).map((point: CurveAnchor): string => point.x + ',' + point.y).join(';');
    const cached = GpuShaderBridge.curveBuffers.get(key);
    if (cached) return cached;
    // Match CPU's 1025 knots; pack 16-bit values into RGBA8 for GLES2.
    // Interpolation is explicit in the shader, including across byte carries.
    const lut = new Uint8Array(1025 * 4);
    const ordered = points && points.length >= 2
      ? points.slice().sort((left: CurveAnchor, right: CurveAnchor): number => left.x - right.x)
      : [new CurveAnchor(0, 0), new CurveAnchor(1, 1)];
    let identity = ordered.length >= 2;
    for (let index = 0; identity && index < ordered.length; index++) {
      identity = Math.abs(ordered[index].x - ordered[index].y) < 0.0005;
    }
    for (let value = 0; value <= 1024; value++) {
      const x = value / 1024;
      let y = GpuShaderBridge.evalCurve(ordered, x);
      if (identity && amount !== 0) {
        if (channelCurve) {
          y = Math.pow(Math.max(0, Math.min(1, x)), Math.pow(2, -amount * 1.25));
        } else if (amount >= 0) {
          const smooth = x * x * (3 - 2 * x);
          y = x + (smooth - x) * amount;
        } else {
          y = x + (0.18 + x * 0.64 - x) * -amount;
        }
      }
      const encoded = Math.round(Math.max(0, Math.min(1, y)) * 65535);
      lut[value * 4] = encoded >> 8;
      lut[value * 4 + 1] = encoded & 255;
      lut[value * 4 + 3] = 255;
    }
    const buffer = lut.buffer as ArrayBuffer;
    if (GpuShaderBridge.curveBuffers.size >= 64) GpuShaderBridge.curveBuffers.clear();
    GpuShaderBridge.curveBuffers.set(key, buffer);
    return buffer;
  }

  private static evalCurve(points: CurveAnchor[], x: number): number {
    if (x <= points[0].x) return points[0].y;
    const last = points[points.length - 1];
    if (x >= last.x) return last.y;
    return Math.max(0, Math.min(1, smoothCurveY(points, x)));
  }
}
