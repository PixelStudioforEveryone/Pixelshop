import { image } from '@kit.ImageKit';
import pixelsNative from 'libvivid_pixels.so';
import { geometryActive, transformGeometry } from './GeometryTransform';
import { buildFrameSampleTable, buildGeometryMap, remapFrameToDisplay } from './GeometryMath';
import { applySpatialEffects } from './SpatialEffects';
import { denoiseEnabled, denoiseRows, denoiseSpatialRadius } from './NoiseReduction';
import { LocalContrastParams, applyLocalContrast, localContrastIsIdentity } from './LocalContrastCore';
import { OpticsParams, applyOptics, opticsIsIdentity, opticsHaloPadForRect } from './OpticsCore';
import { PointColorSample, applyPointColorBuffer, pointColorIsIdentity } from './PointColorCore';
import { applyOkLChBuffer, oklchIsIdentity } from './OkLChCore';
import { blackWhiteBuffer, blackWhiteIsIdentity } from './BlackWhiteCore';
import { denoiseTask, DenoiseTaskParams } from './NoiseReductionTask';
import { retouchTask, RetouchTaskParams } from './RetouchTask';
import { cloneRetouchMarks } from '../models/RetouchSettings';
import { DenoiseSettings } from '../models/DenoiseSettings';
import { DetailSettings } from '../models/DetailSettings';
import { OpticsSettings } from '../models/OpticsSettings';
import { BokehSettings, BokehValues } from '../models/BokehSettings';
import { PointColorSettings } from '../models/PointColorSettings';
import { OkLChSettings } from '../models/OkLChSettings';
import { BlackWhiteSettings } from '../models/BlackWhiteSettings';
import { taskpool } from '@kit.ArkTS';
import { EditSession } from '../models/EditSession';
import { LutStackItem } from '../models/LutLibrary';
import { BlendMode, Layer } from '../models/Layer';
import { ColorMatrixBuilder } from './ColorMatrixBuilder';
import { MaskRenderer, bitmapWorkerData } from './MaskRenderer';
import { RangeMaskService } from './RangeMaskService';
import { RangeMaskProxy } from './RangeMaskCore';
import { ColorAdjustments, CurveAnchor, smoothCurveY } from '../models/Adjustment';
import { MaskState, MaskType, MaskLayer, MaskComponent } from '../models/Mask';
import { MaskBlendMode, MaskComponentType, maskWorkerType, MASK_WORKER_TYPE_LINEAR, MASK_WORKER_TYPE_RADIAL } from '../models/Mask';
import {
  MaskWorkerLayer,
  MaskWorkerComponent,
  MaskWorkerStroke,
  MaskWorkerPoint,
  MaskRasterOutput,
  rasterizeStructuredMask,
  rasterizeStructuredMaskCore,
} from './MaskRasterWorker';
import {
  processPixels,
  processBandPixels,
  processGeometryPixels,
  processBokehPixels,
  BokehJobParams,
  applyGeometryTask,
  GeometryTaskParams,
  ProcessParams,
  ProcessResult,
  WorkerAdjustments,
  WorkerLayer,
  WorkerMask,
  WorkerPoint,
  WorkerStroke,
  WorkerLut,
} from './ProcessWorker';
import { ProcessBehaviors, processBehaviors } from '../models/ProcessVersion';
import { PerfStats } from '../utils/PerfStats';
import { WhiteBalance } from './WhiteBalance';
import { pickRegion, WbPickResult } from './WhiteBalancePickerCore';
import { GpuShaderBridge } from './GpuShaderBridge';
import { applyAdvancedBand as applyWorkerAdvancedBand, applyGeometryFull, applyLutStack,
  geometryMapForParams, prepareAdvancedTables, WorkerAdvancedTables } from './WorkerCore';
import {
  BAND_PHASE_OPTICS,
  BAND_PHASE_POINTWISE,
  BandJobResult,
  BandPassPlan,
  buildBandJob,
  planExportBands,
} from './ExportBands';

interface GeometryResult {
  pixels: Uint8ClampedArray;
  width: number;
  height: number;
}

/**
 * 一块高清瓦片发布时对应的**编辑状态指纹**。
 *
 * 瓦片不是"某一帧预览"的附属物：它是在某个编辑状态下、用整帧统计量
 * （雾色）与整帧蒙版对源图一块矩形做的完整渲染。预览帧的发布（同一次
 * 编辑的 refine、长按看原图的切换）不会改变这个状态，因此不得作废它；
 * 只有这些字段真的变了，瓦片才过期。
 */
/** Bounded RGBA proxy handed to the depth network. */
export interface BokehDepthProxy {
  pixels: ArrayBuffer;
  width: number;
  height: number;
}

export interface DetailTileStamp {  requestVersion: number;
  publicVersion: number;
  maskRevision: number;
  geometryKey: string;
  sourceKey: string;
}

interface DenoiseCacheEntry {
  source: Object;
  buffer: ArrayBuffer;
}

/** State for one visible layer, prepared once per process() run. */
interface LayerPipeline {
  advancedTables?: WorkerAdvancedTables;
  maskAdvancedTables?: WorkerAdvancedTables;
  adjustments: ColorAdjustments;
  /** Plain immutable snapshot reused by every main-thread band. */
  workerAdjustments: WorkerAdjustments;
  matrix: Float32Array | null;
  hasAdvanced: boolean;
  opacity: number;
  blendMode: BlendMode;
  mask: Uint8ClampedArray | null;
  base: Uint8ClampedArray;
  adjusted: Uint8ClampedArray;
  // Mask-scoped colour adjustments (applied inside the masked region).
  maskAdjustments: ColorAdjustments;
  /** Plain immutable snapshot reused by every masked main-thread band. */
  workerMaskAdjustments: WorkerAdjustments;
  maskMatrix: Float32Array | null;
  hasMaskAdjustments: boolean;
  maskAdjusted: Uint8ClampedArray;
  width: number;
  height: number;
}

/** A curve whose anchor points were sorted once, ready for per-pixel evaluation. */
interface PreparedCurve {
  points: CurveAnchor[];
  /** 1025 samples of the smooth curve, index i ↔ x = i/1024. */
  samples: number[];
  amount: number;
  channelCurve: boolean;
  useScalar: boolean;
}

/** RGB targets precomputed once per processing band for colour grading.
 * Keeping these outside the pixel loop avoids temporary arrays on every
 * pixel (which previously caused the grading preview to exhaust memory). */
interface GradePalette {
  shadows: number[];
  midtones: number[];
  highlights: number[];
  global: number[];
}

/** Pixels processed per UI-thread slice. Small enough to keep the main thread
 * responsive on multi-megapixel buffers; the loop yields between slices. */
// Larger preview bands reduce timer/closure overhead while staying below the
// UI watchdog on phone-class devices. Export rendering is unaffected.
const BAND_PIXELS = 32768;
const GEOMETRY_ROWS_PER_SLICE = 128;

/**
 * Reusable working buffers. Every pipeline run used to allocate ~5 full-size
 * buffers (≈70 MB for a 1920px preview), which turned slider drags into GC
 * storms and multi-second pauses. The pool keeps a single set sized to the
 * current image and reuses it across runs (runs are serialised by the
 * coalescing wrapper, so reuse is safe).
 */
interface BufferPool {
  width: number;
  height: number;
  source: ArrayBuffer;
  result: Uint8ClampedArray;
  layerBase: Uint8ClampedArray[];
  layerAdjusted: Uint8ClampedArray[];
  layerMaskAdjusted: Uint8ClampedArray[];
  geometry: Uint8ClampedArray;
}

/**
 * Source pixels cached for the live preview.  PixelMap.readPixelsToBuffer is
 * a synchronous provider/decoder boundary on several devices and was being
 * crossed for every slider event.  Keeping one RGBA copy for the current
 * preview PixelMap removes that repeated read while leaving full-resolution
 * export uncached.
 */
interface SourceBufferCache {
  pixelMap: image.PixelMap;
  width: number;
  height: number;
  buffer: ArrayBuffer;
}

interface ScaledBufferCache extends SourceBufferCache {
  sourceWidth: number;
  sourceHeight: number;
}

interface PreviewRunState {
  running: Promise<void> | null;
  queued: boolean;
  pendingInteractive: boolean;
  pendingAt: number;
  runNumber: number;
  refinementTimer: number;
  current: image.PixelMap | null;
  previous: image.PixelMap | null;
  worker: taskpool.Task | null;
  /**
   * 分带预览当前正在排队/执行的任务（逐点带或光学带）。分带路径的任务不是一个
   * 整任务，`worker` 装不下；取消时必须逐带取消，否则被顶掉的 6 个带任务会排到
   * 新帧前面。
   */
  bandWorkers?: taskpool.Task[];
  refining: boolean;
  workerCancelled: boolean;
}

export class ImageProcessor {
  // ArkUI callers may hold different proxies for one @Observed session.
  // Scheduling must use the session identity, never a proxy's object identity.
  private static runs: Map<number, PreviewRunState> = new Map();
  private static histogramTimers: Map<number, number> = new Map();
  // 每会话最多缓存两个源缓冲：编辑预览（≤1920）与放大细节用的全分辨率源，
  // 否则两条链路会互相顶掉对方缓存，导致每次都重新 readPixels。
  private static sourceBuffers: Map<number, SourceBufferCache[]> = new Map();
  private static interactiveBuffers: Map<number, ScaledBufferCache> = new Map();
  private static denoisedSources: Map<string, DenoiseCacheEntry> = new Map();
  private static retouchedSources: Map<string, DenoiseCacheEntry> = new Map();
  // Frames that left the scheduler while the canvas was still drawing them.
  // They are owned here and released as soon as a replacement is published or
  // the session is destroyed - never before, because `session.previewPixelMap`
  // may still point at one of them.
  private static orphanedFrames: Map<number, image.PixelMap[]> = new Map();
  // True while the ungraded "hold to see the original" frame is the one the
  // direct EGL surface is showing. Release uses it to hand the surface back
  // immediately instead of leaving the original on screen until a queued CPU
  // render finishes.
  private static beforeOnGpu: Map<number, boolean> = new Map();
  // The in-flight dedicated comparison render, if any. Release chains the next
  // graded render after it instead of overlapping two native presents.
  private static beforeTasks: Map<number, Promise<void>> = new Map();
  // —— 区域（放大瓦片）蒙版 alpha 缓存 ——
  // 瓦片只是整帧的一个子矩形，但此前每块瓦片都按自己的缓冲尺寸重新栅格化
  // 一遍所有蒙版（键含 `width x height`，`regionSnapshot` 还会清空 maskCache）。
  // 蒙版 alpha 的几何是整帧归一化坐标，因此按整帧尺寸栅格化一次、再按瓦片
  // 的源矩形裁切+缩放即可，且与"整帧渲染后裁切"一致。键只含会话/源图身份、
  // mask revision 与蒙版几何，不含缓冲尺寸。
  private static regionMaskAlpha: Map<string, Uint8ClampedArray> = new Map();
  private static regionMaskOrder: string[] = [];
  private static regionMaskBytes: number = 0;
  private static regionMaskOwner: string = '';
  private static maskRasterizations: number = 0;
  private static readonly REGION_MASK_BUDGET: number = 96 * 1024 * 1024;

  /** Test/diagnostic hook: number of full-frame (or fallback tile) mask rasters. */
  static maskRasterCount(): number {
    return ImageProcessor.maskRasterizations;
  }

  static resetMaskRasterCount(): void {
    ImageProcessor.maskRasterizations = 0;
  }

  static clearRegionMaskCache(): void {
    ImageProcessor.regionMaskAlpha.clear();
    ImageProcessor.regionMaskOrder = [];
    ImageProcessor.regionMaskBytes = 0;
    ImageProcessor.regionMaskOwner = '';
  }

  /**
   * A published detail tile stays authoritative while its edit stamp still
   * matches the session. Preview publications are frames OF that edit state
   * (interactive frame, refinement, before/after comparison), not newer
   * states, so they must not retire the tile. Only a real parameter/mask/
   * geometry/source change makes the stamp differ.
   *
   * Kept here (rather than in EditorPage) so the truth table is covered by
   * tools/check_detail_tile_priority.cjs and cannot drift from the page.
   */
  static detailTileMatches(tile: DetailTileStamp, current: DetailTileStamp): boolean {
    return tile.requestVersion === current.requestVersion &&
      tile.publicVersion === current.publicVersion &&
      tile.maskRevision === current.maskRevision &&
      tile.geometryKey === current.geometryKey &&
      tile.sourceKey === current.sourceKey;
  }

  static currentPreviewTask(session: EditSession): Promise<void> {
    return ImageProcessor.runs.get(session.sessionId)?.running ?? Promise.resolve();
  }

  /** Drop the cached preview pixels when an editor session is closed or its
   * source image changes. The PixelMap itself remains owned by the page.
   *
   * `disposeFrames` selects what happens to the one or two preview frames the
   * scheduler still owns. The canvas may be drawing the newest of them right
   * now, so the default keeps them alive and reachable: the next published
   * frame (or an explicit `releaseRetainedFrames`) frees them. Passing true is
   * only correct once nothing can display them any more (page destroyed). */
  static clearSourceCache(session: EditSession, disposeFrames: boolean = false): void {
    GpuShaderBridge.release(session);
    session.clearBeforePreview();
    session.gpuPreviewActive = false;
    session.gpuSurfaceDirty = false;
    ImageProcessor.sourceBuffers.delete(session.sessionId);
    ImageProcessor.interactiveBuffers.delete(session.sessionId);
    // 手动白平衡缓存的是源图像素：换图后必须作废，否则新照片会沿用旧字节。
    ImageProcessor.wbPickSource = null;
    ImageProcessor.wbPickPixels = null;
    ImageProcessor.wbPickWidth = 0;
    ImageProcessor.wbPickHeight = 0;
    // 深度图来自刚被丢弃的源像素：换图/换 RAW profile 后必须重算，
    // 否则虚化会沿用上一张照片的景深。
    session.clearBokehDepth();
    AppStorage.setOrCreate('bokehFocusPicking', false);
    ImageProcessor.beforeOnGpu.delete(session.sessionId);
    ImageProcessor.beforeTasks.delete(session.sessionId);
    for (const key of ImageProcessor.denoisedSources.keys()) {
      if (key.startsWith(session.sessionId + ':')) ImageProcessor.denoisedSources.delete(key);
    }
    for (const key of ImageProcessor.retouchedSources.keys()) {
      if (key.startsWith(session.sessionId + ':')) ImageProcessor.retouchedSources.delete(key);
    }
    // Range masks hold a bounded RGB proxy of the source. It is derived from the
    // same pixels as the caches above and must be dropped with them, otherwise a
    // range mask rebuilt after an image switch would be thresholded against the
    // previous photo's tonal distribution.
    RangeMaskService.forget(session.sessionId);
    // 注意：AI 蒙版缓存的清理**不**放在这里。把 AiSegmentationService 引进本文件会把
    // 原生 AI 模块（以及它传递依赖的 libvivid_pixels.so）拉进每一个使用渲染引擎的
    // 模块图里，实测会让大量独立测试在加载期直接崩掉。清理放在 EditorPage 那三处
    // 调用 clearSourceCache 的地方，语义相同（换照片/换源/销毁会话），依赖不外扩。
    const state = ImageProcessor.runs.get(session.sessionId);
    if (state?.worker) ImageProcessor.cancelPreviewWorker(state);
    if (state && state.refinementTimer !== -1) clearTimeout(state.refinementTimer);
    // The two retained frames are owned by this scheduler. Dropping the map
    // entry without releasing them leaked one full preview image per image
    // switch, profile change and page exit. They are still the pixels on
    // screen, so park them: releasing here would hand the canvas a freed
    // PixelMap for the whole time the new source is decoding.
    if (state) ImageProcessor.retainOrphanedFrames(session.sessionId, state);
    ImageProcessor.runs.delete(session.sessionId);
    if (disposeFrames) ImageProcessor.releaseRetainedFrames(session.sessionId);
    const histogramTimer = ImageProcessor.histogramTimers.get(session.sessionId);
    if (histogramTimer !== undefined) clearTimeout(histogramTimer);
    ImageProcessor.histogramTimers.delete(session.sessionId);
  }

  /** Compare on the same serialized renderer and resident source texture.
   * Only colour/mask/LUT passes change; geometry and display bounds stay the
   * same. A view-mode change must not mark the source as a new slider drag. */
  static setBeforePreview(session: EditSession, visible: boolean): Promise<void> {
    if (session.showBefore === visible) return ImageProcessor.currentPreviewTask(session);
    session.showBefore = visible;
    AppStorage.setOrCreate('vividShowBefore', visible);
    // IMPORTANT: a view-mode toggle is not an edit. This used to bump
    // processingRequestVersion, which made every hold/release look like a
    // parameter change: the zoomed full-resolution tile was cancelled and
    // cleared, so releasing the hold showed the bounded preview (A) instead
    // of the tile (C) until another tile finished rendering. Any in-flight
    // graded frame is already rejected by the `before !== session.showBefore`
    // checks in runProcess and by stillBefore() here, so no version bump is
    // needed to keep the comparison correct.
    const state = ImageProcessor.runs.get(session.sessionId);
    if (!visible) {
      if (ImageProcessor.beforeOnGpu.get(session.sessionId) === true) {
        ImageProcessor.beforeOnGpu.delete(session.sessionId);
        // The surface is showing the ungraded original. Stop compositing it now
        // so the last graded preview is visible while the replacement renders.
        session.gpuPreviewActive = false;
        session.gpuSurfaceDirty = false;
        GpuShaderBridge.clearDirectSurface(session).catch((_error: Object): void => {});
      }
      if (state && state.refining) ImageProcessor.cancelPreviewWorker(state);
      // Do not overlap the next graded present with the comparison present that
      // may still be in flight; the native preview session is serialized.
      const pendingBefore = ImageProcessor.beforeTasks.get(session.sessionId);
      if (pendingBefore) {
        return pendingBefore.catch((): void => {}).then((): Promise<void> => {
          const current = ImageProcessor.runs.get(session.sessionId);
          if (current && current.refining) ImageProcessor.cancelPreviewWorker(current);
          return ImageProcessor.process(session);
        });
      }
      return ImageProcessor.process(session);
    }
    // A hold must not queue behind a full-resolution refinement. On device a
    // detail/denoise frame can occupy the single render slot for minutes, and
    // the user releases long before its queue drains (measured: a press at
    // 10:52:33 only started at 11:05:27, queueMs=774351, by which time
    // showBefore was false again, so no before frame was ever rendered). The
    // original needs no grade, so it gets a dedicated render that shares no
    // queue state with the expensive frame.
    if (state && state.refining) ImageProcessor.cancelPreviewWorker(state);
    const task = ImageProcessor.renderBeforePreview(session);
    ImageProcessor.beforeTasks.set(session.sessionId, task);
    return task;
  }

  /**
   * Render the ungraded comparison frame without touching the preview queue.
   *
   * `beforeSnapshot` clears every grade (layers, denoise, detail, optics, point
   * colour, OkLCh, black-and-white, LUTs), so this is a source copy plus
   * geometry: bounded to the interactive dimension it is cheap even when the
   * editor is busy. GPU present is used when a surface exists (native renders
   * the resident texture through the final geometry); otherwise it readbacks a
   * bounded CPU frame into `beforePixelMap`, which is what EditorCanvas shows
   * for a framed (cropped/rotated) photo.
   */
  private static async renderBeforePreview(session: EditSession): Promise<void> {
    const src = session.sourcePixelMap;
    if (!src) return;
    const snapshot = ImageProcessor.beforeSnapshot(session);
    const sourceMax = Math.max(session.imageWidth, session.imageHeight);
    const scale = sourceMax > ImageProcessor.INTERACTIVE_MAX_DIMENSION
      ? ImageProcessor.INTERACTIVE_MAX_DIMENSION / sourceMax : 1;
    const width = Math.max(1, Math.round(session.imageWidth * scale));
    const height = Math.max(1, Math.round(session.imageHeight * scale));
    const surface = session.gpuSurfaceId;
    // Present at the resident texture's size when there is one: the comparison
    // is then a pass over the existing upload, not a second upload at a
    // different resolution (tools/check_editor_scheduler.cjs asserts uploaded=false).
    const resident = GpuShaderBridge.residentSourceSize(session);
    const gpuWidth = resident.length === 2 ? resident[0] : width;
    const gpuHeight = resident.length === 2 ? resident[1] : height;
    const stillBefore = (): boolean => session.sourcePixelMap === src && session.showBefore;
    console.info(`VIVID_FRAME t=${Date.now()} event=before_render_begin before=true sid=${session.sessionId} ` +
      `size=${width}x${height} gpu=${gpuWidth}x${gpuHeight} surface=${surface.length > 0} ` +
      `geometry=${geometryActive(snapshot.geometry) ? 1 : 0}`);
    try {
      if (surface.length > 0 && !geometryActive(snapshot.geometry)) {
        await ImageProcessor.prepareMasks(snapshot, gpuWidth, gpuHeight);
        let upload: ArrayBuffer | null = null;
        if (GpuShaderBridge.needsSource(session, src, gpuWidth, gpuHeight, snapshot)) {
          upload = Math.max(gpuWidth, gpuHeight) < Math.max(session.imageWidth, session.imageHeight)
            ? await ImageProcessor.obtainInteractiveBuffer(src, session.imageWidth,
              session.imageHeight, gpuWidth, gpuHeight, session)
            : await ImageProcessor.obtainSourceBuffer(src, gpuWidth, gpuHeight, session, true);
        }
        if (!stillBefore()) return;
        // beforeSnapshot has no pass left, so the native stack presents the
        // resident source texture through the same output geometry.
        const presented = await GpuShaderBridge.present(session, snapshot, src, upload,
          gpuWidth, gpuHeight, surface);
        console.info(`VIVID_FRAME t=${Date.now()} event=gpu_complete before=true sid=${session.sessionId} ` +
          `ok=${presented} size=${gpuWidth}x${gpuHeight} upload=${upload !== null}`);
        if (presented && stillBefore() && session.gpuSurfaceId === surface) {
          ImageProcessor.beforeOnGpu.set(session.sessionId, true);
          session.gpuPreviewActive = true;
          session.gpuSurfaceDirty = true;
          const output = GpuShaderBridge.outputGeometry(snapshot, gpuWidth, gpuHeight);
          session.previewWidth = output.width;
          session.previewHeight = output.height;
          if (session.onPreviewUpdated) session.onPreviewUpdated();
          return;
        }
      }
      // CPU fallback: exactly the before snapshot, bounded, through the same
      // renderToBuffer entry the normal preview uses.
      console.info(`VIVID_FRAME t=${Date.now()} event=cpu_path_pending before=true ` +
        `sid=${session.sessionId} preview=${session.previewPixelMap !== null}`);
      const geometry = await ImageProcessor.renderToBuffer(src, width, height, session, true,
        (): boolean => !stillBefore(), true, undefined, true, snapshot);
      if (!geometry || !stillBefore()) return;
      const created = await ImageProcessor.createPixelMapFromBuffer(geometry.pixels,
        geometry.width, geometry.height);
      if (!created) return;
      if (!stillBefore()) {
        try { created.release(); } catch (_error) { /* already released */ }
        return;
      }
      const oldBefore = session.beforePixelMap;
      session.beforePixelMap = created;
      session.beforePixelMapSource = src;
      session.beforeGeometryKey = ImageProcessor.beforeGeometryKey(snapshot);
      ImageProcessor.beforeOnGpu.set(session.sessionId, false);
      if (session.gpuPreviewActive) {
        session.gpuPreviewActive = false;
        session.gpuSurfaceDirty = false;
        await GpuShaderBridge.clearDirectSurface(session);
      }
      const beforeVersion = AppStorage.get<number>('beforePreviewVersion') ?? 0;
      AppStorage.setOrCreate('beforePreviewVersion', beforeVersion + 1);
      if (oldBefore && oldBefore !== src) {
        setTimeout(() => {
          try { oldBefore.release(); } catch (_error) { /* already released */ }
        }, 64);
      }
      session.previewWidth = geometry.width;
      session.previewHeight = geometry.height;
      console.info(`VIVID_FRAME t=${Date.now()} event=before_pixelmap_publish before=true sid=${session.sessionId} ` +
        `size=${geometry.width}x${geometry.height}`);
      if (session.onPreviewUpdated) session.onPreviewUpdated();
    } catch (error) {
      console.warn('Before preview failed: ' + JSON.stringify(error));
    }
  }

  private static beforeGeometryKey(session: EditSession): string {
    return [session.imageWidth, session.imageHeight,
      session.cropLeft.toFixed(6), session.cropTop.toFixed(6),
      session.cropRight.toFixed(6), session.cropBottom.toFixed(6),
      session.rotation, session.flipH ? 1 : 0, session.flipV ? 1 : 0,
      session.geometry.join(',')].join('|');
  }

  static isBeforePreviewReady(session: EditSession): boolean {
    return session.beforePixelMap !== null && session.beforePixelMapSource === session.sourcePixelMap &&
      session.beforeGeometryKey === ImageProcessor.beforeGeometryKey(session);
  }

  /**
   * Halo, in whole-frame pixels, that a detail tile must read beyond its output
   * rectangle so that optics resampling sees real neighbours instead of clamping
   * at the tile border.
   *
   * Distortion and lateral CA move a sample outward by more than a pixel well
   * before the corners: at D/2 = 3000 px and a = 0.8 the corner displacement is
   * ~550 px. A tile rendering only its own rectangle therefore pulls its edge
   * pixels from inside itself, and the outermost ring disagrees with the
   * whole-frame render. The bound is evaluated at the TILE's largest normalized
   * radius (not the frame's), then re-evaluated on the expanded rectangle until
   * it stops growing — the displacement is monotone in radius and the expansion
   * is a few pixels, so this converges in two or three rounds.
   *
   * The return value is in whole-frame pixels because it is added to the source
   * read bounds, which are also whole-frame pixels. It is deliberately NOT
   * divided by the sampling scale: a frame-space displacement of Δ px must be
   * covered by Δ px of extra frame-space read, while the buffer-space
   * displacement (Δ * scale) is covered by exactly that read (Δ * scale) once
   * RegionPixels downsamples it.
   */
  static opticsHaloPad(optics: OpticsSettings, left: number, top: number,
    right: number, bottom: number, fullWidth: number, fullHeight: number): number {
    if (optics === null || optics === undefined) return 0;
    const params: OpticsParams = {
      distortion: optics.distortion,
      vignetteAmount: optics.vignetteAmount,
      vignetteMidpoint: optics.vignetteMidpoint,
      chromaticAberration: optics.chromaticAberration,
      defringePurple: optics.defringePurple,
      defringeGreen: optics.defringeGreen,
    };
    return opticsHaloPadForRect(params, left, top, right, bottom, fullWidth, fullHeight);
  }

  /**
   * 区域化细节渲染的安全性判定。管线里不存在任何依赖整图归一化坐标的
   * 操作（蒙版渐变/画笔、暗角、颗粒）时，渲染源图的一个矩形窗口与先
   * 渲染整图再裁剪在数学上完全等价，因此可视区域 tile 可以直接在窗口
   * 内跑管线，把放大首显成本从整图降到窗口大小。
   *
   * 光学校正（畸变/横向色差/暗角）同样按整图坐标计算，但它不再让瓦片
   * 渲染变成"不安全"：`regionSnapshot` 写入的 renderViewport 会经
   * `plainOptics` 进入 OpticsParams.frame，由 OpticsCore 用整帧中心与
   * 半径求解（见 tools/check_optics_region.cjs 的逐像素对拍）。
   */
  static isRegionRenderSafe(session: EditSession): boolean {
    // A crop is an axis-aligned source remap and is handled by EditorPage when
    // it requests the full-resolution source tile. Perspective, rotation and
    // flips still require a transformed full frame and stay on the bounded
    // preview path until the tile renderer gains inverse-transform mapping.
    if (geometryActive(session.geometry) || session.rotation !== 0 || session.flipH || session.flipV) return false;
    // Legacy masks use the old full-image coordinate path. They are migrated
    // lazily by the normal renderer, but the ROI renderer only remaps the
    // structured mask components below; accepting a legacy mask here would
    // place its brush/gradient in the wrong location in a zoom tile.
    for (const layer of session.layers) {
      if (layer.mask && layer.mask.type !== 0 && layer.maskLayers.length === 0) return false;
    }
    return true;
  }

  static regionSnapshot(source: EditSession, x: number, y: number, regionWidth: number,
    regionHeight: number, fullWidth: number, fullHeight: number, width: number, height: number): EditSession {
    const result = ImageProcessor.snapshot(source);
    result.maskCache = new Map();
    result.renderViewport = [x, y, regionWidth / width, regionHeight / height, fullWidth, fullHeight];
    for (const layer of result.layers) {
      layer.migrateMask();
      for (const local of layer.maskLayers) {
        for (const component of local.components) {
          const line = component.linearGradientData;
          if (line) {
            line.startX = (line.startX * fullWidth - x) / regionWidth;
            line.endX = (line.endX * fullWidth - x) / regionWidth;
            line.startY = (line.startY * fullHeight - y) / regionHeight;
            line.endY = (line.endY * fullHeight - y) / regionHeight;
          }
          const radial = component.radialGradientData;
          if (radial) {
            radial.centerX = (radial.centerX * fullWidth - x) / regionWidth;
            radial.centerY = (radial.centerY * fullHeight - y) / regionHeight;
            radial.radiusX *= fullWidth / regionWidth;
            radial.radiusY *= fullHeight / regionHeight;
          }
          if (component.brushData) for (const stroke of component.brushData.strokes) {
            for (const point of stroke.points) {
              point.x = (point.x * fullWidth - x) / regionWidth;
              point.y = (point.y * fullHeight - y) / regionHeight;
              point.radius *= Math.min(fullWidth, fullHeight) / Math.min(regionWidth, regionHeight);
            }
          }
        }
      }
    }
    return result;
  }

  /** 这个蒙版层里有没有需要源像素的自动蒙版笔刷分量。 */
  static layerNeedsAutoMaskProxy(layer: MaskLayer): boolean {
    return layer.components.some((component: MaskComponent): boolean =>
      (component.brushData?.autoMask ?? false) && component.enabled && component.visible);
  }

  /**
   * 把源代理写进扁平分量。
   *
   * `copy` 决定是否复制一份 ArrayBuffer：交给 TaskPool 时**必须**复制（任务会
   * 转移并 detach 缓冲，共享同一份会让第二个分量拿到空缓冲，也会打掉
   * RangeMaskService 里的缓存）；而主线程同步渲染（画笔叠加层、GPU 帧）直接
   * 引用即可——那里每帧复制一份 1MB 级缓冲纯属浪费，正是涂抹卡顿的来源之一。
   */
  private static injectAutoMaskProxy(plain: MaskWorkerLayer, proxy: RangeMaskProxy,
    copy: boolean): void {
    for (const component of plain.components) {
      if (!component.autoMask) continue;
      component.sourceProxyWidth = proxy.width;
      component.sourceProxyHeight = proxy.height;
      component.sourceProxyRgb = copy ? proxy.rgb.slice().buffer as ArrayBuffer
        : proxy.rgb.buffer as ArrayBuffer;
    }
  }

  /**
   * 确保自动蒙版依赖的源 RGB 代理已缓存；代理到位后清掉蒙版缓存并重算一帧。
   *
   * 代理此前只有范围蒙版会读，用户直接从画笔开自动蒙版时它是空的；而缺代理
   * 时若照常渲染并存进 maskCache，就会把"无门限笔刷"永久缓存下来 —— 表现
   * 就是开关点了却毫无效果。所以这里主动预热，并且缺代理时不缓存结果。
   */
  static ensureAutoMaskProxy(session: EditSession): void {
    if (RangeMaskService.cachedAutoMaskProxy(session) !== null) return;
    RangeMaskService.ensureAutoMaskProxy(session)
      .then((proxy: RangeMaskProxy | null): void => {
        if (proxy === null) return;
        session.maskCache.clear();
        session.notifyMaskRevision();
        session.requestProcessing();
        ImageProcessor.process(session);
      }, (): void => {});
  }

  /**
   * 同步渲染一个蒙版层，自动蒙版组件注入源 RGB 代理。
   *
   * 返回 null 表示"这层需要自动蒙版代理而代理还没就绪"：调用方必须退回
   * 无门限渲染当帧顶一下，但**不能**把结果写进 maskCache，否则门限永远
   * 不会生效（代理到位后会清缓存重算）。
   */
  /** 交互预览里蒙版栅格化的最大边长（px）；导出不受限。 */
  static readonly MASK_RASTER_PREVIEW_EDGE: number = 320;

  static renderMaskLayerSync(session: EditSession, layer: MaskLayer,
    width: number, height: number): Uint8ClampedArray | null {
    // 交互预览的栅格化尺寸封顶：画笔蒙版的栅格化成本与像素面积×笔数成正比，
    // 在 1536x2048 的预览通道上画到几十笔就要六秒以上，主线程被系统判为 ANR 直接杀掉。
    // 这里先在封顶尺寸上栅格化，再放大到调用方要求的尺寸；导出路径不经过这里。
    const maxEdge = ImageProcessor.MASK_RASTER_PREVIEW_EDGE;
    const edge = Math.max(width, height);
    if (maxEdge > 0 && edge > maxEdge) {
      const scale = maxEdge / edge;
      const smallW = Math.max(1, Math.round(width * scale));
      const smallH = Math.max(1, Math.round(height * scale));
      const small = ImageProcessor.renderMaskLayerSync(session, layer, smallW, smallH);
      if (small === null) return null;
      const out = new Uint8ClampedArray(width * height);
      for (let y = 0; y < height; y++) {
        const sy = Math.min(smallH - 1, Math.floor(y * smallH / height));
        const srcRow = sy * smallW;
        const dstRow = y * width;
        for (let x = 0; x < width; x++) {
          out[dstRow + x] = small[srcRow + Math.min(smallW - 1, Math.floor(x * smallW / width))];
        }
      }
      return out;
    }
    if (!ImageProcessor.layerNeedsAutoMaskProxy(layer)) {
      return MaskRenderer.renderMaskLayer(layer, width, height);
    }
    const proxy = RangeMaskService.cachedAutoMaskProxy(session);
    if (proxy === null) {
      ImageProcessor.ensureAutoMaskProxy(session);
      return null;
    }
    const plain = ImageProcessor.plainMaskLayer(layer);
    // 主线程同步渲染不走 TaskPool，不需要复制代理缓冲。
    ImageProcessor.injectAutoMaskProxy(plain, proxy, false);
    const rendered = rasterizeStructuredMaskCore(plain, width, height);
    return new Uint8ClampedArray(rendered.alpha);
  }

  /**
   * 渲染一个蒙版层用于当帧显示：代理缺失时退回无门限版本，绝不缓存。
   */
  static renderMaskLayerForDisplay(session: EditSession, layer: MaskLayer,
    width: number, height: number): Uint8ClampedArray {
    const auto = ImageProcessor.renderMaskLayerSync(session, layer, width, height);
    return auto !== null ? auto : MaskRenderer.renderMaskLayer(layer, width, height);
  }

  private static async prepareMasks(session: EditSession, width: number, height: number,
    isStale?: () => boolean): Promise<void> {
    const prepareStart = Date.now();
    let maskHits = 0;
    let maskMisses = 0;
    const pending: Promise<void>[] = [];
    for (const layer of session.layers) {
      // 蒙版栅格化可能很贵（笔刷/存储栅格仍是 ArkTS 逐像素），取消请求必须在
      // 这里就被看到，否则取消后还要等它跑完。
      if (isStale && isStale()) return;
      if (!layer.visible || layer.opacity <= 0) continue;
      layer.migrateMask();
      for (const local of layer.maskLayers) {
        if (!local.visible || !local.enabled || local.components.length === 0) continue;
        // 没有局部调整的蒙版不改变任何像素（buildPipelines/buildWorkerParams 都
        // 跳过它），此前却仍按缓冲尺寸栅格化一遍——白付的成本。区域渲染也按
        // 同一条件缓存，避免"没有效果的蒙版"拖慢每一块瓦片。
        if (!ImageProcessor.maskLayerHasAdjustments(local)) continue;
        const key = layer.id + ':' + local.id + ':' + session.maskRevision + ':' + width + 'x' + height;
        if (session.maskCache.has(key)) { maskHits++; continue; }
        maskMisses++;
        pending.push(ImageProcessor.rasterizeMaskInto(session, local, key, width, height));
      }
    }
    // 多个蒙版此前是逐个 await，等于把各自的栅格化时间相加；并发分发后交给
    // TaskPool 在多核上并行完成，只需等待最慢的那一个。
    if (pending.length > 0) await Promise.all(pending);
    if (session.renderViewport.length === 6) {
      console.info(`VIVID_DETAIL masks wall=${Date.now() - prepareStart}ms ` +
        `hits=${maskHits} misses=${maskMisses} size=${width}x${height}`);
    }
  }

  /**
   * Rasterise one mask layer to a fresh alpha buffer.
   *
   * This is the single rasterisation entry point for both the normal preview /
   * export path (`rasterizeMaskInto`) and the region alpha cache. It owns the
   * native-vs-TaskPool decision but **not** caching, so the region cache can
   * rasterise at full-frame size without polluting `session.maskCache` with a
   * 44 MP entry that no buffer-sized lookup could ever hit.
   */
  private static async rasterizeMaskAlpha(session: EditSession, local: MaskLayer,
    width: number, height: number, isStale?: () => boolean): Promise<Uint8ClampedArray | null> {
    const rasterStart = Date.now();
    if (isStale && isStale()) return null;
    const plain = ImageProcessor.plainMaskLayer(local);
    // 自动蒙版需要源 RGB 代理做颜色门限。代理在这里先读好并注入扁平分量，
    // 之后的栅格化仍然走 TaskPool：44MP 上把这个逐像素门限留在主线程会把
    // 导出拖成几十秒（曾经如此），而 ArrayBuffer 形态的代理可以跨边界。
    if (ImageProcessor.layerNeedsAutoMaskProxy(local)) {
      const proxy = await RangeMaskService.ensureAutoMaskProxy(session);
      if (proxy !== null) {
        ImageProcessor.injectAutoMaskProxy(plain, proxy, true);
      } else {
        // 源图读不出来：不缓存，留待下次重试。
        return null;
      }
    }
    ImageProcessor.maskRasterizations++;
    // 解析型分量（线性/径向渐变）走 native：ArkTS 孪生实现是逐像素解释执行，
    // 44MP 一个渐变实测 18.9 秒。native 跑同一套 double 运算（见
    // vivid_pixels.cpp 的位精确约定），笔刷与存储栅格仍走 TaskPool 路径。
    // 采用前先对拍一次：不一致就整体退回参考实现，绝不产出可疑蒙版。
    if (await ImageProcessor.nativeMaskMatchesReference(plain)) {
      const native = ImageProcessor.rasterizeMaskNative(plain, width, height);
      if (native !== null) {
        if (session.renderViewport.length === 6) {
          console.info(`VIVID_DETAIL mask-raster path=native ms=${Date.now() - rasterStart} ` +
            `size=${width}x${height}`);
        }
        return native;
      }
    }
    try {
      const rendered = await taskpool.execute(new taskpool.Task(
        rasterizeStructuredMask, plain, width, height)) as MaskRasterOutput;
      const alpha = new Uint8ClampedArray(rendered.alpha);
      if (alpha.length !== width * height) throw new Error('Invalid mask buffer length');
      if (rendered.stats.length > 0) {
        console.info(`VIVID_EDIT_PERF stage=mask-raster size=${width}x${height} ${rendered.stats}`);
      }
      if (session.renderViewport.length === 6) {
        console.info(`VIVID_DETAIL mask-raster path=taskpool ms=${Date.now() - rasterStart} ` +
          `size=${width}x${height}`);
      }
      return alpha;
    } catch (_error) {
      if (session.renderViewport.length === 6) {
        console.info(`VIVID_DETAIL mask-raster path=fallback ms=${Date.now() - rasterStart} ` +
          `size=${width}x${height}`);
      }
      return MaskRenderer.renderMaskLayer(local, width, height);
    }
  }

  /** Single masked layer rasterisation, cached under the caller's key. */
  private static async rasterizeMaskInto(session: EditSession, local: MaskLayer, key: string,
    width: number, height: number): Promise<void> {
    const alpha = await ImageProcessor.rasterizeMaskAlpha(session, local, width, height);
    if (alpha !== null) session.maskCache.set(key, alpha);
  }

  // -------------------------------------------------------------------------
  // 区域渲染的整帧蒙版 alpha 缓存
  //
  // 键 = 源图身份 + 会话 + mask revision + 蒙版几何 + 整帧尺寸，**不含缓冲尺寸**。
  // 因此同一会话里连续请求的不同瓦片共享同一份整帧 alpha；换图或任何蒙版
  // 编辑（revision 递增）都会自然失效。内存预算 96 MB（44 MP 一个蒙版约
  // 44 MB，可同时保留两个），超出后按插入顺序淘汰。
  // -------------------------------------------------------------------------

  private static regionMaskOwnerKey(sourceSession: EditSession, sourceKey: string,
    fullWidth: number, fullHeight: number): string {
    return `${sourceKey}|${sourceSession.sessionId}|${sourceSession.processGeneration}|` +
      `${sourceSession.maskRevision}|${fullWidth}x${fullHeight}`;
  }

  private static maskLayerHasAdjustments(maskLayer: MaskLayer): boolean {
    const matrix = ColorMatrixBuilder.build(maskLayer.adjustments);
    return !ColorMatrixBuilder.isIdentity(matrix) || maskLayer.adjustments.hasAdvancedAdjustments();
  }

  /**
   * Geometry identity independent of raster size. `maskRevision` already covers
   * every mask edit; this signature additionally makes accidental revision
   * reuse (restored sidecars, cloned sessions) fall back to a fresh raster
   * instead of serving an alpha built from a different shape.
   */
  private static maskGeometryKey(local: MaskLayer): string {
    let key = `${local.id}:${local.inverted ? 1 : 0}:${local.opacity.toFixed(4)}:` +
      `${local.components.length}`;
    for (const component of local.components) {
      key += `|${component.type},${component.enabled ? 1 : 0},${component.visible ? 1 : 0},` +
        `${component.inverted ? 1 : 0},${component.opacity.toFixed(4)},${component.feather.toFixed(4)}`;
      const line = component.linearGradientData;
      if (line) {
        key += `L${line.startX.toFixed(6)},${line.startY.toFixed(6)},` +
          `${line.endX.toFixed(6)},${line.endY.toFixed(6)}`;
      }
      const radial = component.radialGradientData;
      if (radial) {
        key += `R${radial.centerX.toFixed(6)},${radial.centerY.toFixed(6)},` +
          `${radial.radiusX.toFixed(6)},${radial.radiusY.toFixed(6)},${radial.rotation.toFixed(6)}`;
      }
      const brush = component.brushData;
      if (brush) {
        key += `B${brush.strokes.length}:` +
          brush.strokes.map((stroke): number => stroke.points.length).join('.');
      }
    }
    return key;
  }

  private static storeRegionMask(key: string, alpha: Uint8ClampedArray): void {
    const previous = ImageProcessor.regionMaskAlpha.get(key);
    if (previous) {
      ImageProcessor.regionMaskBytes -= previous.length;
      const at = ImageProcessor.regionMaskOrder.indexOf(key);
      if (at >= 0) ImageProcessor.regionMaskOrder.splice(at, 1);
    }
    ImageProcessor.regionMaskAlpha.set(key, alpha);
    ImageProcessor.regionMaskOrder.push(key);
    ImageProcessor.regionMaskBytes += alpha.length;
    while (ImageProcessor.regionMaskBytes > ImageProcessor.REGION_MASK_BUDGET ||
      ImageProcessor.regionMaskOrder.length > 8) {
      const oldest = ImageProcessor.regionMaskOrder.shift();
      if (oldest === undefined) break;
      const evicted = ImageProcessor.regionMaskAlpha.get(oldest);
      if (evicted) {
        ImageProcessor.regionMaskBytes -= evicted.length;
        ImageProcessor.regionMaskAlpha.delete(oldest);
      }
    }
  }

  /** Pure-ArkTS crop+scale fallback; mirrors `cropScaleAlpha` in vivid_pixels.cpp. */
  private static cropScaleAlphaArkTS(alpha: Uint8ClampedArray, srcWidth: number, srcHeight: number,
    rectX: number, rectY: number, rectWidth: number, rectHeight: number,
    dstWidth: number, dstHeight: number): Uint8ClampedArray {
    const out = new Uint8ClampedArray(dstWidth * dstHeight);
    const scaleX = rectWidth / dstWidth;
    const scaleY = rectHeight / dstHeight;
    const maxX = rectX + rectWidth - 1;
    const maxY = rectY + rectHeight - 1;
    for (let y = 0; y < dstHeight; y++) {
      let sampleY = rectY + (y + 0.5) * scaleY - 0.5;
      if (!(sampleY > rectY)) sampleY = rectY;
      if (sampleY > maxY) sampleY = maxY;
      const y0 = Math.floor(sampleY);
      const y1 = Math.min(maxY, y0 + 1);
      const fy = sampleY - y0;
      const row0 = y0 * srcWidth;
      const row1 = y1 * srcWidth;
      for (let x = 0; x < dstWidth; x++) {
        let sampleX = rectX + (x + 0.5) * scaleX - 0.5;
        if (!(sampleX > rectX)) sampleX = rectX;
        if (sampleX > maxX) sampleX = maxX;
        const x0 = Math.floor(sampleX);
        const x1 = Math.min(maxX, x0 + 1);
        const fx = sampleX - x0;
        const a00 = alpha[row0 + x0];
        const a01 = alpha[row0 + x1];
        const a10 = alpha[row1 + x0];
        const a11 = alpha[row1 + x1];
        const top = a00 + (a01 - a00) * fx;
        const bottom = a10 + (a11 - a10) * fx;
        out[y * dstWidth + x] = Math.round(top + (bottom - top) * fy);
      }
    }
    return out;
  }

  private static cropScaleAlpha(alpha: Uint8ClampedArray, srcWidth: number, srcHeight: number,
    rectX: number, rectY: number, rectWidth: number, rectHeight: number,
    dstWidth: number, dstHeight: number): Uint8ClampedArray {
    try {
      if (typeof pixelsNative.cropScaleAlpha === 'function') {
        const bytes = pixelsNative.cropScaleAlpha(alpha.buffer as ArrayBuffer,
          srcWidth, srcHeight, rectX, rectY, rectWidth, rectHeight,
          dstWidth, dstHeight) as ArrayBuffer;
        if (bytes && bytes.byteLength === dstWidth * dstHeight) {
          return new Uint8ClampedArray(bytes);
        }
      }
    } catch (_error) {
      // 旧版 native 模块没有这个导出：退回同一公式的 ArkTS 版本。
    }
    return ImageProcessor.cropScaleAlphaArkTS(alpha, srcWidth, srcHeight,
      rectX, rectY, rectWidth, rectHeight, dstWidth, dstHeight);
  }

  /**
   * Populate `targetSession.maskCache` with tile-sized alpha cut from a
   * full-frame rasterisation. Must be called with the **unmodified** source
   * session: `regionSnapshot` has already remapped gradient/brush geometry into
   * tile pixels, so rasterising the snapshot would describe the tile, not the
   * frame.
   *
   * Masks with no local adjustment contribute no pixel and are skipped, exactly
   * like `buildPipelines` / `buildWorkerParams` do.
   */
  static async prepareRegionMasks(sourceSession: EditSession, targetSession: EditSession,
    sourceKey: string, fullWidth: number, fullHeight: number,
    tileX: number, tileY: number, tileWidth: number, tileHeight: number,
    width: number, height: number, isStale?: () => boolean): Promise<number> {
    const owner = ImageProcessor.regionMaskOwnerKey(sourceSession, sourceKey, fullWidth, fullHeight);
    if (owner !== ImageProcessor.regionMaskOwner) {
      ImageProcessor.clearRegionMaskCache();
      ImageProcessor.regionMaskOwner = owner;
    }
    const start = Date.now();
    let fullMs = 0;
    let cropMs = 0;
    let cached = 0;
    let rasterized = 0;
    let prepared = 0;
    for (const layer of sourceSession.layers) {
      if (!layer.visible || layer.opacity <= 0) continue;
      layer.migrateMask();
      for (const local of layer.maskLayers) {
        if (!local.visible || !local.enabled || local.components.length === 0) continue;
        if (!ImageProcessor.maskLayerHasAdjustments(local)) continue;
        if (isStale && isStale()) return prepared;
        const key = `${owner}|${layer.id}:${local.id}|${sourceSession.maskRevision}|` +
          `${ImageProcessor.maskGeometryKey(local)}`;
        let full = ImageProcessor.regionMaskAlpha.get(key);
        if (full) {
          cached++;
        } else {
          const rasterStart = Date.now();
          const rastered = await ImageProcessor.rasterizeMaskAlpha(sourceSession, local,
            fullWidth, fullHeight, isStale);
          fullMs += Date.now() - rasterStart;
          if (rastered === null) continue; // auto-mask proxy not ready: leave it to prepareMasks
          full = rastered;
          rasterized++;
          ImageProcessor.storeRegionMask(key, full);
        }
        if (isStale && isStale()) return prepared;
        const cropStart = Date.now();
        const tile = ImageProcessor.cropScaleAlpha(full, fullWidth, fullHeight,
          tileX, tileY, tileWidth, tileHeight, width, height);
        cropMs += Date.now() - cropStart;
        // buildWorkerParams / prepareMasks 使用的键（含目标缓冲尺寸）。
        targetSession.maskCache.set(
          `${layer.id}:${local.id}:${targetSession.maskRevision}:${width}x${height}`, tile);
        prepared++;
      }
    }
    if (targetSession.renderViewport.length === 6) {
      console.info(`VIVID_DETAIL region-mask full=${fullMs}ms crop=${cropMs}ms ` +
        `masks=${prepared} cached=${cached} rasterized=${rasterized} ` +
        `fullSize=${fullWidth}x${fullHeight} tile=${width}x${height}`);
    }
    return prepared;
  }


  /**
   * 对拍：小尺寸下让 native 与 TaskPool 参考实现各栅格化一遍，逐字节比较。
   * 两条路径的公式是同一套 double 运算写成的，理论上必须完全一致；这里用
   * 64x48（毫秒级）把这个前提变成运行时可验证的事实——一旦将来任一侧被改动，
   * native 会自动失效并退回参考实现，而不是悄悄产出不同的蒙版。
   */
  private static async nativeMaskMatchesReference(plain: MaskWorkerLayer): Promise<boolean> {
    const probeWidth = 64, probeHeight = 48;
    const ours = ImageProcessor.rasterizeMaskNative(plain, probeWidth, probeHeight, true);
    if (ours === null) return false;
    try {
      const probe = await taskpool.execute(new taskpool.Task(
        rasterizeStructuredMask, plain, probeWidth, probeHeight)) as MaskRasterOutput;
      const reference = new Uint8ClampedArray(probe.alpha);
      if (reference.length !== ours.length) return false;
      for (let index = 0; index < reference.length; index++) {
        if (reference[index] !== ours[index]) {
          console.error(`VIVID_EDIT_PERF stage=mask-parity diff=${index} ` +
            `native=${ours[index]} reference=${reference[index]}`);
          return false;
        }
      }
      return true;
    } catch (_error) {
      return false;
    }
  }

  /**
   * Native fast path for mask layers whose components are all analytic
   * (linear / radial gradients). Returns null when any visible component needs
   * the TaskPool path — brush strokes and stored subject/sky/range rasters —
   * so the caller falls back to the reference implementation instead of
   * producing a partially rendered mask. `quiet` suppresses the timing line so
   * the parity probe does not spam the export diagnostics.
   */
  private static rasterizeMaskNative(plain: MaskWorkerLayer, width: number,
    height: number, quiet: boolean = false): Uint8ClampedArray | null {
    if (plain.components.length === 0) return null;
    // 没有加载到 native 模块（单元测试、裁剪过的构建、旧设备）时直接退回
    // TaskPool 参考实现，而不是让一次属性访问异常把整条渲染链路打掉。
    if (typeof pixelsNative.rasterizeLinear !== 'function' ||
      typeof pixelsNative.rasterizeRadial !== 'function' ||
      typeof pixelsNative.invertOpacity !== 'function' ||
      typeof pixelsNative.composeInto !== 'function') {
      return null;
    }
    const startedAt = Date.now();
    let result: Uint8ClampedArray | null = null;
    let hasSelection = false;
    let rendered = 0;
    // 分量类型：0 笔刷 / 1 线性 / 2 径向 / 3 主体 / 4 天空 / 5 范围。只有线性
    // 与径向走 native，其余仍在 ArkTS 里逐像素（44MP 约 19 秒），所以这一项
    // 决定了"加蒙版后慢"是不是栅格化本身造成的。
    const types: string[] = [];
    for (const component of plain.components) {
      if (!component.enabled || !component.visible) continue;
      const modern = (component.renderingVersion ?? 1) >= 2;
      types.push(`${component.type}v${component.renderingVersion ?? 1}`);
      let alpha: Uint8ClampedArray;
      if (component.type === MASK_WORKER_TYPE_LINEAR) {
        const sx = component.linear[0] * width, sy = component.linear[1] * height;
        const ex = component.linear[2] * width, ey = component.linear[3] * height;
        alpha = new Uint8ClampedArray(pixelsNative.rasterizeLinear(width, height,
          sx, sy, ex, ey, component.feather, modern));
      } else if (component.type === MASK_WORKER_TYPE_RADIAL) {
        // 旋转的 cos/sin 在 ArkTS 侧算好后传入：Math.cos/Math.sin 是引擎实现，
        // 而 +-*/ 与 sqrt 在 double 上是 IEEE 一致的，这样两条路径才逐字节相同。
        const cx = component.radial[0] * width, cy = component.radial[1] * height;
        const rx = Math.max(1, component.radial[2] * width);
        const ry = Math.max(1, component.radial[3] * height);
        const angle = component.radial[4] * Math.PI / 180;
        alpha = new Uint8ClampedArray(pixelsNative.rasterizeRadial(width, height, cx, cy,
          rx, ry, Math.cos(angle), Math.sin(angle), component.feather, modern));
      } else {
        return null;
      }
      if (alpha.length !== width * height) return null;
      pixelsNative.invertOpacity(alpha.buffer as ArrayBuffer, component.inverted === true,
        component.opacity);
      if (!hasSelection && (modern ? component.blendMode !== 2 : component.blendMode === 2)) {
        result = alpha;
      } else if (result === null) {
        return null;
      } else {
        pixelsNative.composeInto(result.buffer as ArrayBuffer, alpha.buffer as ArrayBuffer,
          component.blendMode);
      }
      hasSelection = true;
      rendered++;
    }
    if (result === null) return null;
    pixelsNative.invertOpacity(result.buffer as ArrayBuffer, plain.inverted === true, plain.opacity);
    if (!quiet) {
      console.info(`VIVID_EDIT_PERF stage=mask-native size=${width}x${height}` +
        ` comps=${rendered} types=${types.join(',')} ms=${Date.now() - startedAt}`);
    }
    return result;
  }

  private static plainMaskLayer(layer: MaskLayer): MaskWorkerLayer {
    const components: MaskWorkerComponent[] = [];
    for (const component of layer.components) {
      const strokes: MaskWorkerStroke[] = [];
      for (const stroke of component.brushData?.strokes ?? []) {
        const points: MaskWorkerPoint[] = stroke.points.map((point): MaskWorkerPoint => ({
          x: point.x, y: point.y, radius: point.radius, hardness: point.hardness,
        }));
        strokes.push({ mode: stroke.mode, points: points, flow: stroke.flow, density: stroke.density });
      }
      const linear = component.linearGradientData ? [
        component.linearGradientData.startX, component.linearGradientData.startY,
        component.linearGradientData.endX, component.linearGradientData.endY,
      ] : [0.5, 0, 0.5, 1];
      const radial = component.radialGradientData ? [
        component.radialGradientData.centerX, component.radialGradientData.centerY,
        component.radialGradientData.radiusX, component.radialGradientData.radiusY,
        component.radialGradientData.rotation,
      ] : [0.5, 0.5, 0.5, 0.5, 0];
      const blendMode = component.blendMode === MaskBlendMode.SUBTRACT ? 1 :
        (component.blendMode === MaskBlendMode.INTERSECT ? 2 : 0);
      // Subject/sky/range components carry a stored raster instead of geometry,
      // and that raster must travel with the layer: without it the worker path
      // and the export would treat a raster selection as an empty brush and
      // silently drop it, while the on-screen overlay still showed it.
      components.push({ type: maskWorkerType(component.type), blendMode: blendMode,
        enabled: component.enabled,
        renderingVersion: component.renderingVersion,
        visible: component.visible, inverted: component.inverted, opacity: component.opacity,
        feather: component.feather, strokes: strokes, linear: linear, radial: radial,
        bitmap: bitmapWorkerData(component),
        autoMask: component.brushData?.autoMask ?? false,
        autoMaskSensitivity: component.brushData?.sensitivity ?? 0.5,
        sourceProxyWidth: 0,
        sourceProxyHeight: 0,
        sourceProxyRgb: null });
    }
    return { enabled: layer.enabled, visible: layer.visible, opacity: layer.opacity,
      inverted: layer.inverted, components: components };
  }

  /**
   * Capture parameters before any await. Parsed LUT tables are immutable assets.
   *
   * EVERY field that `buildWorkerParams` reads must be copied here, and this method has
   * already shipped one bug from getting that wrong: six render inputs -- processVersion,
   * detail, optics, pointColor, oklch and blackWhite -- were missing, so every CPU render
   * path (preview AND export, since both go through a snapshot) silently rendered those
   * stages as bypassed. The sliders moved, the panels claimed the stage was on, and the
   * image did not change. `check_snapshot_stages.cjs` now renders THROUGH this method
   * rather than around it, so a field left out here fails the suite.
   */
  static snapshot(source: EditSession): EditSession {
    const result = new EditSession();
    result.denoise = source.denoise.clone();
    result.retouchMarks = cloneRetouchMarks(source.retouchMarks);
    result.imageWidth = source.imageWidth;
    result.imageHeight = source.imageHeight;
    result.layers = source.layers.map((layer: Layer) => layer.clone());
    result.lutStack = source.lutStack.map((item: LutStackItem) => ({
      id: item.id, lutId: item.lutId, name: item.name, sourceUri: item.sourceUri,
      enabled: item.enabled, intensity: item.intensity, lut: item.lut,
    } as LutStackItem));
    result.geometry = source.geometry.slice();
    result.rotation = source.rotation;
    result.flipH = source.flipH;
    result.flipV = source.flipV;
    result.cropLeft = source.cropLeft;
    result.cropTop = source.cropTop;
    result.cropRight = source.cropRight;
    result.cropBottom = source.cropBottom;
    result.isCropping = source.isCropping;
    // The remaining render inputs, each of which buildWorkerParams reads. Omitting any of
    // them makes that stage a silent no-op in the preview and in the export both.
    result.processVersion = source.processVersion;
    result.detail = source.detail.clone();
    // 整帧雾色也要跟着快照走：放大瓦片靠它复用整帧的去朦胧统计量。
    result.detailHaze = source.detailHaze.slice();
    result.optics = source.optics.clone();
    // 大光圈是整帧文档级阶段；深度图与参数一起进快照，否则预览/导出会把
    // 它当作关闭（与上面六项曾经踩过的坑相同）。
    result.bokeh = source.bokeh.clone();
    result.bokehDepth = source.bokehDepth;
    result.bokehDepthWidth = source.bokehDepthWidth;
    result.bokehDepthHeight = source.bokehDepthHeight;
    result.bokehDepthSourceKey = source.bokehDepthSourceKey;
    result.upright = source.upright.clone();
    result.pointColor = source.pointColor.clone();
    result.oklch = source.oklch.clone();
    result.blackWhite = source.blackWhite.clone();
    // Brush authoring state travels too, so a snapshot is a faithful capture of the
    // session rather than only of the render inputs.
    result.retouchKind = source.retouchKind;
    result.retouchSize = source.retouchSize;
    result.retouchFeather = source.retouchFeather;
    result.retouchAmount = source.retouchAmount;
    result.retouchSource = source.retouchSource.slice();
    // Entries include the mask revision. A late old frame can never replace
    // the entry read by a new mask state; generated alpha survives snapshots.
    if (source.maskCache.size > 24) source.maskCache.clear();
    result.maskCache = source.maskCache;
    result.maskRevision = source.maskRevision;
    result.renderViewport = source.renderViewport.slice();
    return result;
  }

  /**
   * Snapshot for the "hold to see the original" frame.
   *
   * The original is the capture as it was framed: crop, rotation, flips and the
   * manual geometry are framing decisions and stay. Every grade added on top of
   * it must go, including the document-level stages that run outside the layer
   * list — detail (texture/clarity/dehaze/sharpening), point colour, the OkLCh
   * grade, the black-and-white conversion and the lens corrections. Those five
   * used to survive into the before frame, so "original" still showed clarity,
   * black-and-white, point colour and lens correction.
   */
  static beforeSnapshot(source: EditSession): EditSession {
    const result = ImageProcessor.snapshot(source);
    result.layers = [];
    result.denoise = new DenoiseSettings();
    result.detail = new DetailSettings();
    // Haze is a statistic of the detail stage; resetting detail without it would
    // leave a stale airlight value behind for the next dehaze edit.
    result.detailHaze = [];
    result.retouchMarks = [];
    result.lutStack = [];
    result.lutLink = '';
    result.lutPresetName = '';
    result.lutPreset = null;
    result.renderViewport = [];
    result.pointColor = new PointColorSettings();
    result.oklch = new OkLChSettings();
    result.blackWhite = new BlackWhiteSettings();
    result.optics = new OpticsSettings();
    result.bokeh = new BokehSettings();
    result.clearBokehDepth();
    return result;
  }

  /** 把会话状态序列化为 TaskPool worker 的纯数据参数。 */
  static globalLutParams(session: EditSession, source: ArrayBuffer, width: number, height: number): ProcessParams {
    const layers: WorkerLayer[] = session.layers.map((layer: Layer) => ({
      visible: layer.visible, opacity: layer.opacity, blendMode: layer.blendMode,
      adjustments: ImageProcessor.plainLutAdjustments(layer.adjustments),
      maskAdjustments: ImageProcessor.emptyWorkerAdjustments(), mask: null, maskBuffer: null,
    } as WorkerLayer));
    return {
      source: source, width: width, height: height, layers: layers,
      // Saving a LUT captures manual global adjustments only, never the preset LUT stack.
      luts: [],
      cropLeft: 0, cropTop: 0, cropRight: 1, cropBottom: 1,
      rotation: 0, flipH: false, flipV: false, applyGeometry: false, ignoreCrop: true,
    };
  }

  private static buildWorkerParams(
    session: EditSession,
    srcBuffer: ArrayBuffer,
    width: number,
    height: number,
    verbose: boolean = false,
  ): ProcessParams {
    const buildStartedAt = Date.now();
    const layers: WorkerLayer[] = [];
    // 导出诊断计数：蒙版"没生效"和"很慢"是两个方向的问题，但都取决于同一件事
    // ——蒙版层有没有自己的调整项。buildWorkerParams 只在有调整项时才把它送进
    // 管线（无调整项的蒙版本来就不改变像素），这里把计数打出来，日志就能直接
    // 定性，不必再猜。
    let layerAdjustable = 0;
    let maskedLayers = 0;
    let maskLayerCount = 0;
    let maskLayerAdjustable = 0;
    for (const layer of session.layers) {
      layer.migrateMask();
      const matrix = ColorMatrixBuilder.build(layer.adjustments);
      const hasAdjustments = !ColorMatrixBuilder.isIdentity(matrix) ||
        layer.adjustments.hasAdvancedAdjustments();

      // A structured mask is flattened into one worker pipeline per mask
      // layer. Rendering the alpha buffer is cached and lightweight; all
      // colour transforms then run off the UI thread in TaskPool.
      if (layer.maskLayers.length > 0) {
        maskedLayers++;
        if (hasAdjustments) {
          layerAdjustable++;
          layers.push({
            visible: layer.visible,
            opacity: layer.opacity,
            blendMode: layer.blendMode,
            adjustments: ImageProcessor.plainAdjustments(layer.adjustments),
            maskAdjustments: ImageProcessor.emptyWorkerAdjustments(),
            mask: null,
            maskBuffer: null,
          });
        }
        for (const maskLayer of layer.maskLayers) {
          if (!maskLayer.enabled || !maskLayer.visible || maskLayer.components.length === 0) continue;
          maskLayerCount++;
          const localMatrix = ColorMatrixBuilder.build(maskLayer.adjustments);
          const localHasAdjustments = !ColorMatrixBuilder.isIdentity(localMatrix) ||
            maskLayer.adjustments.hasAdvancedAdjustments();
          if (!localHasAdjustments) continue;
          maskLayerAdjustable++;
          const maskKey = layer.id + ':' + maskLayer.id + ':' + session.maskRevision + ':' + width + 'x' + height;
          let maskBuffer = session.maskCache.get(maskKey);
          if (!maskBuffer) {
            // 自动蒙版代理未就绪时 renderMaskLayerSync 返回 null：这一帧先用
            // 无门限版本，但不写缓存，代理到位后会清缓存重算。
            const auto = ImageProcessor.renderMaskLayerSync(session, maskLayer, width, height);
            maskBuffer = auto !== null ? auto
              : MaskRenderer.renderMaskLayerCapped(maskLayer, width, height, 256);
            if (auto !== null) session.maskCache.set(maskKey, maskBuffer);
          }
          layers.push({
            visible: layer.visible,
            opacity: Math.max(0, Math.min(1, layer.opacity)),
            blendMode: BlendMode.NORMAL,
            adjustments: ImageProcessor.plainAdjustments(maskLayer.adjustments),
            maskAdjustments: ImageProcessor.emptyWorkerAdjustments(),
            mask: null,
            // TaskPool 会转移 ArrayBuffer：必须传副本，否则缓存的 alpha
            // 缓冲在第一次任务后被 detach，后续任务蒙版静默失效。
            maskBuffer: maskBuffer.slice().buffer as ArrayBuffer,
          });
        }
        continue;
      }

      layers.push({
        visible: layer.visible,
        opacity: layer.opacity,
        blendMode: layer.blendMode,
        adjustments: ImageProcessor.plainAdjustments(layer.adjustments),
        maskAdjustments: ImageProcessor.plainAdjustments(layer.maskAdjustments),
        mask: ImageProcessor.plainMask(layer.mask),
        maskBuffer: null,
      });
    }
    const hasTransform = session.rotation !== 0 || session.flipH || session.flipV || geometryActive(session.geometry);
    // The crop tool now previews the cropped image directly (the working
    // frame is an overlay), so the pipeline always applies the session crop.
    // Geometry can still be skipped entirely when everything is neutral.
    const hasCrop = session.cropLeft > 0 || session.cropTop > 0 ||
      session.cropRight < 1 || session.cropBottom < 1;
    // 预览每帧都会调用本函数，但 26 次/6 秒的日志里真正有活儿（蒙版栅格化）
    // 的只有缓存未命中的那几次；普通帧只是对象构造，实测 <1ms。所以只在导出
    // （verbose=true）时打这条日志，预览不再刷屏。ms 留在日志里作为证据。
    if (verbose) {
      console.info(`VIVID_EDIT_PERF stage=export-session layers=${session.layers.length}` +
        ` masked=${maskedLayers} maskLayers=${maskLayerCount} maskAdjustable=${maskLayerAdjustable}` +
        ` layerAdjustable=${layerAdjustable} pipelines=${layers.length}` +
        ` geo=${hasTransform} crop=${hasCrop} ms=${Date.now() - buildStartedAt}`);
    }
    return {
      source: srcBuffer,
      // Pins the render to the algorithm generation this photo was edited on.
      processVersion: session.processVersion,
      denoise: { luminance: session.denoise.luminance, color: session.denoise.color,
        detail: session.denoise.detail, colorDetail: session.denoise.colorDetail,
        luminanceContrast: session.denoise.luminanceContrast,
        colorSmoothness: session.denoise.colorSmoothness },
      detail: ImageProcessor.plainDetail(session.detail),
      detailHaze: session.detailHaze.slice(),
      optics: ImageProcessor.plainOptics(session.optics, session.renderViewport),
      bokeh: ImageProcessor.plainBokeh(session.bokeh),
      // TaskPool 转移 ArrayBuffer：必须给副本，否则缓存的深度图会在第一趟
      // 渲染后被 detach，后续拖动滑块时虚化静默退回中心对焦。
      bokehDepth: session.bokeh.enabled && session.bokehDepth !== null
        ? session.bokehDepth.slice().buffer as ArrayBuffer : null,
      bokehDepthWidth: session.bokehDepthWidth,
      bokehDepthHeight: session.bokehDepthHeight,
      pointColor: session.pointColor.samples,
      oklch: session.oklch.params(),
      blackWhite: session.blackWhite.params(),
      viewport: session.renderViewport.slice(),
      width: width,
      height: height,
      // The manual geometry controls are authored against the source frame; a
      // bounded interactive preview must rescale the perspective term.
      referenceWidth: Math.max(1, Math.round(session.imageWidth)),
      referenceHeight: Math.max(1, Math.round(session.imageHeight)),
      layers: layers,
      luts: ImageProcessor.plainLuts(session.lutStack),
      cropLeft: session.cropLeft,
      cropTop: session.cropTop,
      cropRight: session.cropRight,
      cropBottom: session.cropBottom,
      rotation: session.rotation,
      geometry: session.geometry.slice(),
      flipH: session.flipH,
      flipV: session.flipV,
      applyGeometry: hasTransform || hasCrop,
      ignoreCrop: false,
      // 裁剪/旋转/翻转是精确的整数双射（无缩放、无插值），native 版本逐字节
      // 等价，而 ArkTS 版本要构造两张 Int32 采样表再逐像素查表：44MP 实测
      // 33~35 秒，占整次导出的全部剩余开销。探测失败时整条几何阶段留在
      // worker 里，行为与今天完全一致。
      deferRemap: (hasTransform || hasCrop) && ImageProcessor.nativeGeometryOk,
    };
  }

  /**
   * 分带并行是否适用。
   *
   * 三种大帧都走同一条逐点管线：**导出**、**≥2MP 的预览**（RAW 的 fit 预览常见
   * 1365×2048 = 2.8MP）、以及**放大瓦片**。它们此前各自被一道提前返回挡住，
   * 只能单任务串行：RAW 预览 `layers=1069ms`、瓦片 `layers=804ms` 都是这么来的。
   * 分带逐点与串行整帧早已逐字节对拍（见 tools/check_export_bands_parity.cjs，
   * 含非单位缩放视口），带任务按整帧绝对 `pixelOffset` 取坐标，所以对三者等价。
   *
   * 保留串行的五种情况，逐条理由：
   *  - `referenceCpu`（看原图 before 渲染）：它由 before 缓存单独发起，语义是
   *    "绕开当前编辑、直出原始帧"，与预览调度/发布时序绑定；保持原样串行，
   *    避免把 before 的可见时延卷进分带调度。
   *  - 降噪：整帧邻域阶段，分带路径没有降噪阶段（`processExportBand` 不实现它），
   *    分带会静默丢效果。
   *  - 小于 2MP：任务/拷贝开销会盖过分带收益（341×512 一类小预览仍走串行）。
   *  - 旧式（未结构化）蒙版：worker 会按帧尺寸现栅格化，带内无法还原整帧坐标。
   *  - 带 6 元视口且光学非恒等：光学带把 `frame` 改写成带内坐标，而
   *    `opticsHaloPadForRect` 的矩形是整帧坐标；宁可变慢也不改变像素。
   *    光学恒等（真机日志 `optics=0`，最常见）时瓦片可以分带。
   *
   * `previewState` 不再是门槛：它只携带取消/发布状态，管线从不读它；分带路径用
   * 同一个 `isStale` 回调（每 100ms 轮询 + 逐带检查）取消，比串行单任务更细。
   */
  private static exportBandsEligible(params: ProcessParams, width: number, height: number,
    referenceCpu: boolean): boolean {
    if (referenceCpu) return false;
    if (denoiseEnabled(params.denoise)) return false;
    if (width < 2 || height < 64) return false;
    if (width * height < 2 * 1024 * 1024) return false;
    const hasViewport = params.viewport !== undefined && params.viewport.length === 6;
    if (hasViewport && params.optics !== undefined && !opticsIsIdentity(params.optics)) return false;
    for (const layer of params.layers) {
      if (layer.maskBuffer === null && layer.mask !== null) return false;
    }
    return true;
  }

  /**
   * 带数。优先用 TaskPool 实际的工作线程数（它随设备规模变化），再取 min(6, 可用数)；
   * 不写死 8，也不在缺省设备上退回单带。取不到线程数时用 4——比单线程快，
   * 又不会在大内存细节阶段堆出过多并发。
   */
  private static exportBandCount(height: number): number {
    let threads = 0;
    try {
      threads = taskpool.getTaskPoolInfo().threadInfos.length;
    } catch (_error) {
      threads = 0;
    }
    // TaskPool 只报告**已创建**的 worker（本机实测 4 个），但会随排队任务扩容。
    // 多排 2 个带给它扩容机会，上限仍是 6；取不到线程数的设备按 4+2 处理。
    const available = threads > 0 ? threads : 4;
    const wanted = Math.min(6, available + 2);
    const rowCap = Math.max(1, Math.floor(height / 64));
    return Math.max(1, Math.min(wanted, rowCap));
  }

  /** 跑一趟分带任务，并把各带的目标行拼进 target。返回 false 表示已被取消。
   *
   * `onTasks` 让调用方拿到本趟的任务句柄：预览被更新的请求顶掉时，
   * `cancelPreviewWorker` 要能取消**正在排队/执行的每一带**，否则 6 个带任务会
   * 排在下一帧前面，快速连续缩放就堆积了。 */
  private static async executeBandPass(source: Uint8ClampedArray, plans: BandPassPlan[],
    target: Uint8ClampedArray, width: number, height: number, params: ProcessParams,
    haze: number[], isStale: () => boolean,
    onTasks?: (tasks: taskpool.Task[]) => void): Promise<boolean> {
    const rowBytes = width * 4;
    const tasks: taskpool.Task[] = [];
    for (const plan of plans) {
      const job = buildBandJob(params, plan, source, width, height, haze);
      tasks.push(new taskpool.Task(processBandPixels, job));
    }
    if (onTasks) onTasks(tasks);
    const startedAt = Date.now();
    let cancelPoll: number = -1;
    cancelPoll = setInterval((): void => {
      if (!isStale() || cancelPoll === -1) return;
      clearInterval(cancelPoll);
      cancelPoll = -1;
      for (const task of tasks) {
        try {
          taskpool.cancel(task);
        } catch (_error) { /* completion may already have left the TaskPool */ }
      }
      console.info('VIVID_EDIT_PERF stage=cpu-cancel reason=export-band');
    }, 100);
    try {
      const promises: Promise<BandJobResult>[] = [];
      for (const task of tasks) {
        promises.push(taskpool.execute(task) as Promise<BandJobResult>);
      }
      let results: BandJobResult[];
      try {
        results = await Promise.all(promises) as BandJobResult[];
      } catch (error) {
        // 取消会以任务异常的形式返回；这种"被顶掉"不是失败，不要冒泡成错误日志。
        if (isStale()) return false;
        throw new Error(String(error));
      }
      if (isStale()) return false;
      let adjust = 0;
      let maskAdjust = 0;
      let maskBlend = 0;
      let composite = 0;
      let detailMs = 0;
      let opticsMs = 0;
      let lutMs = 0;
      let pointColorMs = 0;
      let oklchMs = 0;
      let copyMs = 0;
      let matrixMs = 0;
      let advancedMs = 0;
      let maskMatrixMs = 0;
      let maskAdvancedMs = 0;
      for (let index = 0; index < results.length; index++) {
        const result = results[index];
        const plan = plans[index];
        if (result.buffer.byteLength !== plan.targetRows * rowBytes) {
          throw new Error('Export band returned an unexpected row count');
        }
        target.set(new Uint8ClampedArray(result.buffer), plan.targetTop * rowBytes);
        adjust += result.adjustMs;
        maskAdjust += result.maskAdjustMs;
        maskBlend += result.maskBlendMs;
        composite += result.compositeMs;
        detailMs += result.detailMs;
        opticsMs += result.opticsMs;
        lutMs += result.lutMs;
        pointColorMs += result.pointColorMs;
        oklchMs += result.oklchMs;
        copyMs += result.copyMs;
        matrixMs += result.matrixMs;
        advancedMs += result.advancedMs;
        maskMatrixMs += result.maskMatrixMs;
        maskAdvancedMs += result.maskAdvancedMs;
      }
      const phase = plans.length > 0 ? plans[0].phase : 0;
      console.info(`VIVID_EDIT_PERF stage=export-band-pass phase=${phase}` +
        ` bands=${plans.length} ms=${Date.now() - startedAt} detail=${detailMs} optics=${opticsMs}` +
        ` adjust=${adjust} matrix=${matrixMs} advanced=${advancedMs}` +
        ` maskAdjust=${maskAdjust} maskMatrix=${maskMatrixMs} maskAdvanced=${maskAdvancedMs}` +
        ` maskBlend=${maskBlend} composite=${composite}` +
        ` lut=${lutMs} pointColor=${pointColorMs} oklch=${oklchMs}` +
        ` copy=${copyMs}`);
      return true;
    } finally {
      if (cancelPoll !== -1) clearInterval(cancelPoll);
    }
  }

  /**
   * 在整帧、几何之前执行一次大光圈渲染。
   *
   * 未启用时原样返回，不复制也不排队。启用时复制一份像素交给 TaskPool：
   * 大光圈是整帧卷积，不能按横带切分，但也不能留在 UI 线程。
   */
  private static async runBokehPass(params: ProcessParams, pixels: Uint8ClampedArray,
    width: number, height: number, isStale: () => boolean,
    previewState?: PreviewRunState): Promise<Uint8ClampedArray | null> {
    if (!params.bokeh || !params.bokeh.enabled) return pixels;
    if (isStale()) return null;
    const startedAt = Date.now();
    const job: BokehJobParams = {
      source: pixels.slice().buffer as ArrayBuffer,
      width: width,
      height: height,
      depth: params.bokehDepth ?? null,
      depthWidth: params.bokehDepthWidth ?? 0,
      depthHeight: params.bokehDepthHeight ?? 0,
      bokeh: params.bokeh,
    };
    const task = new taskpool.Task(processBokehPixels, job);
    if (previewState !== undefined) previewState.worker = task;
    let result: ProcessResult;
    try {
      result = await taskpool.execute(task) as ProcessResult;
    } finally {
      if (previewState !== undefined && previewState.worker === task) previewState.worker = null;
    }
    if (isStale()) return null;
    if (!result || result.buffer.byteLength !== width * height * 4) {
      console.error('VIVID_BOKEH pass returned an unexpected buffer, keeping the graded frame');
      return pixels;
    }
    const rendered = new Uint8ClampedArray(result.buffer);
    // 诊断：确认 native 确实改了像素，而不是把输入原样退回。抽样步长取质数，
    // 避开 RGBA 对齐和整行重复；只在开关打开时跑，成本可忽略。
    let delta = 0;
    let deltaMax = 0;
    let deltaSamples = 0;
    for (let index = 0; index < rendered.length; index += 997) {
      const difference = Math.abs(rendered[index] - pixels[index]);
      delta += difference;
      if (difference > deltaMax) deltaMax = difference;
      deltaSamples++;
    }
    console.info(`VIVID_EDIT_PERF stage=bokeh ms=${Date.now() - startedAt}` +
      ` size=${width}x${height} depth=${params.bokehDepthWidth ?? 0}x${params.bokehDepthHeight ?? 0}` +
      ` aperture=${params.bokeh.aperture.toFixed(1)} shape=${params.bokeh.shape}` +
      ` delta=${(delta / Math.max(1, deltaSamples)).toFixed(2)} max=${deltaMax}`);
    return rendered;
  }

  /**
   * 导出并行主流程：
   *   1. 逐点阶段（图层/LUT/点颜色/OkLCh）按行分带，每带一个 TaskPool 任务；
   *      这些阶段没有邻域依赖，切开是逐字节精确的，而它们正是 11.7s 的大头。
   *   2. 细节阶段整帧一次（native 内部按行/列并行）。box blur 的浮点运行和从
   *      带的第 0 行开始与从整帧第 0 行开始不是同一串加法，halo 再大也只能把
   *      边界接回来，治不了 1 LSB 的漂移；整帧一次 + native 并行才既快又逐字节一致。
   *   3. 光学/黑白按行分带。光学是逐像素的双线性采样，halo 覆盖位移后与整帧精确一致。
   *   4. 几何（如有）沿用原来的 native 重映射/几何任务。
   *
   * 返回 null 表示“放弃并行，交回串行 worker”。
   */
  private static async runExportBands(params: ProcessParams, width: number, height: number,
    callerStale: () => boolean, kind: string = 'export',
    previewState?: PreviewRunState): Promise<GeometryResult | null> {
    // 预览的取消有两个来源：调度器换帧（callerStale）与 `cancelPreviewWorker`
    // 取消任务。分带路径把两者合一，任一成立就当作过期。
    const isStale = (): boolean => callerStale() ||
      (previewState !== undefined && previewState.workerCancelled);
    const registerTasks = (tasks: taskpool.Task[]): void => {
      if (previewState !== undefined) previewState.bandWorkers = tasks;
    };
    const bandCount = ImageProcessor.exportBandCount(height);
    if (bandCount < 2) return null;
    const startedAt = Date.now();
    const rowBytes = width * 4;
    const sourcePixels = new Uint8ClampedArray(params.source);

    // Pass 1: 逐点阶段。没有图层/LUT/点颜色/OkLCh 时没有活儿可干，直接沿用源
    // 缓冲：既省一次整帧带拷贝+拼接（2.6MP 瓦片约 20MB 往返），也省 6 个空任务。
    const pointwiseActive = params.layers.length > 0 || params.luts.length > 0 ||
      (params.pointColor !== undefined && params.pointColor.length > 0) ||
      (params.oklch !== undefined && !oklchIsIdentity(params.oklch));
    let staged: Uint8ClampedArray;
    let detailSource: ArrayBuffer;
    if (pointwiseActive) {
      const full = new Uint8ClampedArray(width * height * 4);
      const pointwise = planExportBands(width, height, bandCount, 0, null, BAND_PHASE_POINTWISE);
      console.info(`VIVID_EDIT_PERF stage=export-bands pass=pointwise kind=${kind}` +
        ` bands=${bandCount} size=${width}x${height} halo=0`);
      const pointwiseDone = await ImageProcessor.executeBandPass(sourcePixels, pointwise.bands,
        full, width, height, params, [], isStale, registerTasks);
      if (previewState !== undefined) previewState.bandWorkers = [];
      if (!pointwiseDone) return null;
      console.info(`VIVID_EDIT_PERF stage=export-bands-stitch pass=pointwise kind=${kind}` +
        ` ms=${Date.now() - startedAt} size=${width}x${height}`);
      staged = full;
      // `full` belongs to this function; transferring it to the detail task is free.
      detailSource = full.buffer as ArrayBuffer;
    } else {
      staged = sourcePixels;
      // `sourcePixels` is a view of params.source, which the serial fallback still
      // needs. Copy once instead of transferring the caller's buffer away.
      detailSource = sourcePixels.slice().buffer as ArrayBuffer;
      console.info(`VIVID_EDIT_PERF stage=export-bands pass=pointwise kind=${kind} skipped=empty` +
        ` size=${width}x${height}`);
    }

    // Pass 2: 细节整帧一次（native 内部并行）。图层的输出已经拼接在 staged 里。
    const detail = params.detail;
    if (detail && !localContrastIsIdentity(detail)) {
      const detailStart = Date.now();
      try {
        const detailTask = new taskpool.Task(processPixels,
          ImageProcessor.detailWorkerParams(params, detailSource, width, height));
        if (previewState !== undefined) previewState.worker = detailTask;
        const detailResult = await taskpool.execute(detailTask) as ProcessResult;
        if (previewState !== undefined && previewState.worker === detailTask) previewState.worker = null;
        if (isStale()) return null;
        if (!detailResult || detailResult.buffer.byteLength !== width * height * 4) {
          console.error('Export detail pass returned an unexpected buffer');
          return null;
        }
        staged = new Uint8ClampedArray(detailResult.buffer);
        console.info(`VIVID_EDIT_PERF stage=export-detail kind=${kind} ms=${Date.now() - detailStart}` +
          ` size=${width}x${height}`);
      } catch (_error) {
        if (previewState !== undefined) previewState.worker = null;
        if (isStale()) return null;
        console.error('Export detail pass failed, falling back to serial worker: ' +
          JSON.stringify(_error));
        return null;
      }
    }

    // Pass 3: 光学 + 黑白（只有启用时才跑；光学带 halo，黑白逐点）。
    const opticsActive = params.optics !== undefined && !opticsIsIdentity(params.optics);
    const bwActive = params.blackWhite !== undefined && !blackWhiteIsIdentity(params.blackWhite);
    if (opticsActive || bwActive) {
      const opticsPlan = planExportBands(width, height, bandCount, 0,
        params.optics ? params.optics : null, BAND_PHASE_OPTICS);
      let opticsHaloMax = 0;
      for (const band of opticsPlan.bands) {
        if (band.opticsHalo > opticsHaloMax) opticsHaloMax = band.opticsHalo;
      }
      console.info(`VIVID_EDIT_PERF stage=export-bands pass=optics kind=${kind} bands=${bandCount}` +
        ` halo=${opticsHaloMax} bw=${bwActive ? 1 : 0}`);
      const opticsStart = Date.now();
      const opticsDone = await ImageProcessor.executeBandPass(staged, opticsPlan.bands, staged,
        width, height, params, [], isStale, registerTasks);
      if (previewState !== undefined) previewState.bandWorkers = [];
      if (!opticsDone) return null;
      console.info(`VIVID_EDIT_PERF stage=export-bands-stitch pass=optics kind=${kind}` +
        ` ms=${Date.now() - opticsStart} halo=${opticsHaloMax}`);
    }

    // 大光圈：整帧一次，必须在几何裁剪之前。分带阶段只覆盖逐点/邻域运算，
    // 所以它作为独立任务在这里执行，不能混进带任务。
    if (params.bokeh && params.bokeh.enabled) {
      const bokehPixels = await ImageProcessor.runBokehPass(
        params, staged, width, height, isStale, previewState);
      if (!bokehPixels) return null;
      staged = bokehPixels;
    }

    if (params.applyGeometry) {
      if (params.deferRemap) {
        return ImageProcessor.remapGeometryDeferred(staged, params, width, height);
      }
      // 原生几何探测失败时的最后一段：仍交给 TaskPool，用与串行 worker 完全相同的
      // applyGeometryFull（含手动透视几何）。传副本，失败时主线程还能补算。
      try {
        const geometryTask = new taskpool.Task(processGeometryPixels,
          ImageProcessor.geometryWorkerParams(params, staged.slice().buffer as ArrayBuffer,
            width, height));
        const geometry = await taskpool.execute(geometryTask) as ProcessResult;
        if (geometry && geometry.buffer.byteLength > 0) {
          return {
            pixels: new Uint8ClampedArray(geometry.buffer),
            width: geometry.width,
            height: geometry.height,
          };
        }
      } catch (_error) {
        console.error('Export band geometry task failed, using reference path: ' +
          JSON.stringify(_error));
      }
      const geometry = applyGeometryFull(staged, width, height, params);
      return { pixels: geometry.pixels, width: geometry.width, height: geometry.height };
    }
    console.info(`VIVID_EDIT_PERF stage=export-bands-total kind=${kind} ms=${Date.now() - startedAt}` +
      ` size=${width}x${height}`);
    return { pixels: staged, width: width, height: height };
  }

  /** 细节整帧任务的纯数据参数：只留 detail/detailHaze，逐点阶段已拼好。 */
  private static detailWorkerParams(params: ProcessParams, source: ArrayBuffer,
    width: number, height: number): ProcessParams {
    return {
      source: source,
      width: width,
      height: height,
      processVersion: params.processVersion,
      detail: params.detail,
      detailHaze: params.detailHaze,
      layers: [],
      luts: [],
      cropLeft: 0,
      cropTop: 0,
      cropRight: 1,
      cropBottom: 1,
      rotation: 0,
      flipH: false,
      flipV: false,
      applyGeometry: false,
      ignoreCrop: true,
    };
  }

  /** TaskPool 几何任务的纯数据参数（图层/阶段结果都不需要，几何只看源与非破坏设置）。 */
  private static geometryWorkerParams(params: ProcessParams, source: ArrayBuffer,
    width: number, height: number): ProcessParams {
    return {
      source: source,
      width: width,
      height: height,
      processVersion: params.processVersion,
      layers: [],
      luts: [],
      cropLeft: params.cropLeft,
      cropTop: params.cropTop,
      cropRight: params.cropRight,
      cropBottom: params.cropBottom,
      rotation: params.rotation,
      geometry: params.geometry,
      flipH: params.flipH,
      flipV: params.flipV,
      applyGeometry: true,
      ignoreCrop: params.ignoreCrop,
      referenceWidth: params.referenceWidth,
      referenceHeight: params.referenceHeight,
      deferRemap: false,
    };
  }

  /**
   * `remapGeometry` 的能力探测。native 模块的可用性由蒙版路径已经证明，
   * 这里再确认这个函数存在且映射方向正确，避免把几何阶段交出去之后再失败。
   * 2x2 的 90° 顺时针旋转：源 (0,0) 应落到输出 (1,0)，即字节 4..7。
   */
  private static nativeGeometryOk: boolean = ImageProcessor.probeNativeGeometry();

  private static probeNativeGeometry(): boolean {
    try {
      const probe = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
      const rotated: Uint8Array = new Uint8Array(pixelsNative.remapGeometry(
        probe.buffer as ArrayBuffer, 2, 0, 0, 2, 2, 2, 2, 90, false, false) as ArrayBuffer);
      return rotated.length === 16 && rotated[4] === 1 && rotated[7] === 4;
    } catch (_error) {
      console.error('native geometry remap unavailable: ' + JSON.stringify(_error));
      return false;
    }
  }

  /**
   * 主线程 native 重映射：worker 只返回旋转前的帧，裁剪/旋转/翻转在这里一次
   * 整数拷贝完成。窗口边界由 geometryMapForParams 重建，与 worker 用的那一份
   * 是同一个函数，所以不会出现两条路径算出不同裁剪框的可能。
   */
  private static remapGeometryDeferred(pixels: Uint8ClampedArray, params: ProcessParams,
    width: number, height: number): GeometryResult {
    const map = geometryMapForParams(params, width, height);
    const startedAt = Date.now();
    try {
      const output: ArrayBuffer = pixelsNative.remapGeometry(pixels.buffer as ArrayBuffer, width,
        map.left, map.top, map.cropWidth, map.cropHeight, map.outputWidth, map.outputHeight,
        map.rotation, map.flipH, map.flipV) as ArrayBuffer;
      console.info(`VIVID_EDIT_PERF stage=geometry-native ${width}x${height} -> ` +
        `${map.outputWidth}x${map.outputHeight} rot=${map.rotation} ms=${Date.now() - startedAt}`);
      return {
        pixels: new Uint8ClampedArray(output),
        width: map.outputWidth,
        height: map.outputHeight,
      };
    } catch (_error) {
      // 兜底：native 不可用时用 ArkTS 参考实现补齐，宁可慢也不能交出未旋转的画面。
      console.error('native geometry remap failed, using reference path: ' + JSON.stringify(_error));
      const output = new Uint8ClampedArray(map.outputWidth * map.outputHeight * 4);
      remapFrameToDisplay(pixels, map, output, buildFrameSampleTable(map));
      console.info(`VIVID_EDIT_PERF stage=geometry-reference ${width}x${height} -> ` +
        `${map.outputWidth}x${map.outputHeight} ms=${Date.now() - startedAt}`);
      return {
        pixels: output,
        width: map.outputWidth,
        height: map.outputHeight,
      };
    }
  }

  /**
   * Adjustment mapping for the LUT bake: global COLOUR stages only.
   *
   * Saving a LUT feeds a 33^3 RGB grid through the pipeline as if it were an
   * image. Vignetting and grain are functions of the pixel POSITION, so applied
   * to grid coordinates they become functions of the colour at that corner of the
   * cube — a "darker at the edges" effect silently turns into "darker blues".
   * Neither is representable as an RGB->RGB table at all, so both are zeroed
   * here. Every other stage (exposure, curves, mixer, grading, calibration, ...)
   * is a colour transform and is baked.
   *
   * `tools/check_lut_bake_spatial.cjs` renders the same session with vignette and
   * grain nonzero and with them zero: the two LUT buffers must be byte-identical.
   */
  private static plainLutAdjustments(adj: ColorAdjustments): WorkerAdjustments {
    const plain = ImageProcessor.plainAdjustments(adj);
    plain.vignetteAmount = 0;
    plain.vignetteMidpoint = 0;
    plain.vignetteRoundness = 0;
    plain.vignetteFeather = 0;
    plain.vignetteHighlights = 0;
    plain.grainAmount = 0;
    plain.grainSize = 0;
    plain.grainRoughness = 0;
    return plain;
  }

  private static plainAdjustments(adj: ColorAdjustments): WorkerAdjustments {
    return {
      exposure: adj.exposure,
      contrast: adj.contrast,
      brightness: adj.brightness,
      highlights: adj.highlights,
      shadows: adj.shadows,
      whites: adj.whites,
      blacks: adj.blacks,
      vignetteAmount: adj.vignetteAmount,
      vignetteMidpoint: adj.vignetteMidpoint,
      vignetteRoundness: adj.vignetteRoundness,
      vignetteFeather: adj.vignetteFeather,
      vignetteHighlights: adj.vignetteHighlights,
      grainAmount: adj.grainAmount,
      grainSize: adj.grainSize,
      grainRoughness: adj.grainRoughness,
      saturation: adj.saturation,
      vibrance: adj.vibrance,
      temperature: adj.temperature,
      tint: adj.tint,
      hue: adj.hue,
      toneCurve: adj.toneCurve,
      curveRed: adj.curveRed,
      curveGreen: adj.curveGreen,
      curveBlue: adj.curveBlue,
      toneCurvePoints: adj.toneCurvePoints.map((point: CurveAnchor) => [point.x, point.y]),
      redCurvePoints: adj.redCurvePoints.map((point: CurveAnchor) => [point.x, point.y]),
      greenCurvePoints: adj.greenCurvePoints.map((point: CurveAnchor) => [point.x, point.y]),
      blueCurvePoints: adj.blueCurvePoints.map((point: CurveAnchor) => [point.x, point.y]),
      parametricHighlights: adj.parametricHighlights,
      parametricLights: adj.parametricLights,
      parametricDarks: adj.parametricDarks,
      parametricShadows: adj.parametricShadows,
      parametricShadowSplit: adj.parametricShadowSplit,
      parametricDarkSplit: adj.parametricDarkSplit,
      parametricLightSplit: adj.parametricLightSplit,
      parametricRefineSaturation: adj.parametricRefineSaturation,
      mixHue: adj.mixHue.slice(),
      mixSaturation: adj.mixSaturation.slice(),
      mixLuminance: adj.mixLuminance.slice(),
      calibrationRedHue: adj.calibrationRedHue,
      calibrationRedSaturation: adj.calibrationRedSaturation,
      calibrationGreenHue: adj.calibrationGreenHue,
      calibrationGreenSaturation: adj.calibrationGreenSaturation,
      calibrationBlueHue: adj.calibrationBlueHue,
      calibrationBlueSaturation: adj.calibrationBlueSaturation,
      colorGradingEnabled: adj.colorGradingEnabled,
      gradingShadowsHue: adj.gradingShadowsHue,
      gradingShadowsSaturation: adj.gradingShadowsSaturation,
      gradingShadowsLuminance: adj.gradingShadowsLuminance,
      gradingMidtonesHue: adj.gradingMidtonesHue,
      gradingMidtonesSaturation: adj.gradingMidtonesSaturation,
      gradingMidtonesLuminance: adj.gradingMidtonesLuminance,
      gradingHighlightsHue: adj.gradingHighlightsHue,
      gradingHighlightsSaturation: adj.gradingHighlightsSaturation,
      gradingHighlightsLuminance: adj.gradingHighlightsLuminance,
      gradingGlobalHue: adj.gradingGlobalHue,
      gradingGlobalSaturation: adj.gradingGlobalSaturation,
      gradingGlobalLuminance: adj.gradingGlobalLuminance,
      gradingBlending: adj.gradingBlending,
      gradingBalance: adj.gradingBalance,
    };
  }

  private static emptyWorkerAdjustments(): WorkerAdjustments {
    return ImageProcessor.plainAdjustments(new ColorAdjustments());
  }

  /**
   * Single mapping from the document setting to the engine parameters, shared by
   * the worker job and the UI-thread fallback so the two paths cannot drift.
   */
  /**
   * Single mapping from the document setting to the engine parameters, shared by
   * the worker job and the UI-thread fallback so the two paths cannot drift.
   */
  private static plainOptics(optics: OpticsSettings, viewport?: number[]): OpticsParams {    const params: OpticsParams = {
      distortion: optics.distortion,
      vignetteAmount: optics.vignetteAmount,
      vignetteMidpoint: optics.vignetteMidpoint,
      chromaticAberration: optics.chromaticAberration,
      defringePurple: optics.defringePurple,
      defringeGreen: optics.defringeGreen,
    };
    // A zoom tile is a window into the full frame, not a frame of its own:
    // distortion/CA/vignetting are radial effects about the FRAME centre, so the
    // region render has to know where its pixels sit. `renderViewport` already
    // carries [x, y, scaleX, scaleY, fullWidth, fullHeight] and is empty for a
    // whole-frame render.
    if (viewport && viewport.length === 6) params.frame = viewport.slice();
    return params;
  }

  /**
   * 纯数据的大光圈参数。
   *
   * 只有启用时才返回对象：旁路时 `buildWorkerParams` 少拷贝一份参数，
   * worker 也走不到 native 调用。数值在这里夹紧，native 侧仍会再夹一次，
   * 因为侧车文件可以被手工编辑。
   */
  private static plainBokeh(bokeh: BokehSettings): BokehValues | undefined {
    if (bokeh === null || bokeh === undefined || !bokeh.enabled) return undefined;
    return {
      enabled: true,
      aperture: bokeh.aperture,
      blurStrength: bokeh.blurStrength,
      bokehStrength: bokeh.bokehStrength,
      shape: bokeh.shape,
      density: bokeh.density,
      size: bokeh.size,
      spherical: bokeh.spherical,
      focus: bokeh.focus,
    };
  }

  private static plainDetail(detail: DetailSettings): LocalContrastParams {
    const params: LocalContrastParams = {
      texture: detail.texture,
      clarity: detail.clarity,
      dehaze: detail.dehaze,
      sharpenAmount: detail.sharpenAmount,
      sharpenRadius: detail.sharpenRadius,
      sharpenDetail: detail.sharpenDetail,
      sharpenMasking: detail.sharpenMasking,
    };
    return params;
  }

  private static plainLuts(stack: LutStackItem[]): WorkerLut[] {
    const result: WorkerLut[] = [];
    for (const item of stack ?? []) {
      const table = item.lut?.table;
      if (!table || table.size <= 1 || table.values.length < 3) continue;
      result.push({
        enabled: item.enabled,
        intensity: Math.max(0, Math.min(1, item.intensity)),
        size: table.size,
        values: table.values.slice(),
        domainMin: table.domainMin.slice(),
        domainMax: table.domainMax.slice(),
      });
    }
    return result;
  }

  private static plainMask(mask: MaskState | null): WorkerMask | null {
    if (!mask || mask.type === MaskType.NONE) return null;
    const strokes: WorkerStroke[] = [];
    for (const stroke of mask.brushStrokes) {
      const points: WorkerPoint[] = [];
      for (const point of stroke.points) {
        points.push({ x: point.x, y: point.y, radius: point.radius, hardness: point.hardness });
      }
      strokes.push({ mode: stroke.mode, points: points });
    }
    return {
      type: mask.type,
      invert: mask.invert,
      feather: mask.feather,
      strokes: strokes,
      linear: [
        mask.linearGradient.startX, mask.linearGradient.startY,
        mask.linearGradient.endX, mask.linearGradient.endY,
        mask.linearGradient.feather,
      ],
      radial: [
        mask.radialGradient.centerX, mask.radialGradient.centerY,
        mask.radialGradient.radius, mask.radialGradient.radiusX,
        mask.radialGradient.radiusY, mask.radialGradient.feather,
      ],
    };
  }

  /** Get (or allocate once) the working-buffer set for the given image size. */
  private static obtainPool(width: number, height: number, _layerCount: number): BufferPool {
    // Fallback runs can overlap export/detail and preview. Buffers belong to
    // this invocation, never to another session or an in-flight export.
    const byteLength = width * height * 4;
    const created: BufferPool = {
      width: width,
      height: height,
      source: new ArrayBuffer(byteLength),
      result: new Uint8ClampedArray(byteLength),
      layerBase: [],
      layerAdjusted: [],
      layerMaskAdjusted: [],
      geometry: new Uint8ClampedArray(byteLength),
    };
    // Pipelines are processed serially for each band.  One working triplet is
    // therefore sufficient; allocating one triplet per mask/layer multiplied
    // peak RAM without enabling any parallel work.
    created.layerBase.push(new Uint8ClampedArray(byteLength));
    created.layerAdjusted.push(new Uint8ClampedArray(byteLength));
    created.layerMaskAdjusted.push(new Uint8ClampedArray(byteLength));
    return created;
  }

  /**
   * Process all layers and update session.previewPixelMap.
   * Concurrent requests coalesce: at most one pipeline runs at a time and a
   * final re-run is queued for the latest state, so slider drags can never
   * pile up overlapping passes.
   */
  /**
   * Hand the scheduler's frames to the orphan list instead of releasing them.
   * Only the newest one can still be on screen, so older frames are dropped
   * immediately: keeping them all would park several full-size previews for
   * no visible benefit.
   */
  private static retainOrphanedFrames(sessionId: number, state: PreviewRunState): void {
    const frames: image.PixelMap[] = ImageProcessor.orphanedFrames.get(sessionId) ?? [];
    if (state.previous && !frames.includes(state.previous)) frames.push(state.previous);
    if (state.current && !frames.includes(state.current)) frames.push(state.current);
    state.previous = null;
    state.current = null;
    if (frames.length === 0) return;
    ImageProcessor.orphanedFrames.set(sessionId, frames);
  }

  static releaseRetainedFrames(sessionId: number): void {
    const parked = ImageProcessor.orphanedFrames.get(sessionId);
    if (!parked) return;
    ImageProcessor.orphanedFrames.delete(sessionId);
    for (const frame of parked) {
      try { frame.release(); } catch (_error) { /* already released */ }
    }
  }

  /** Called once a new frame has actually been published for this session, so
   * the parked one can no longer be referenced by anything that is drawn. */
  private static dropRetainedFrames(sessionId: number): void {
    const frames = ImageProcessor.orphanedFrames.get(sessionId);
    if (!frames) return;
    ImageProcessor.orphanedFrames.delete(sessionId);
    // Assigning the new PixelMap precedes ArkUI's render commit. Keep the
    // previous texture alive through that commit, as with before-preview frames.
    setTimeout(() => {
      for (const frame of frames) {
        try { frame.release(); } catch (_error) { /* already released */ }
      }
    }, 64);
  }

  private static cancelPreviewWorker(state: PreviewRunState): void {
    const bandWorkers = state.bandWorkers;
    if (bandWorkers !== undefined && bandWorkers.length > 0) {
      // 分带预览：逐带取消，并让 runExportBands 的 isStale 立刻为真。
      state.bandWorkers = [];
      state.workerCancelled = true;
      for (const task of bandWorkers) {
        try {
          taskpool.cancel(task);
        } catch (_error) { /* completion may already have left the TaskPool */ }
      }
      console.info('VIVID_EDIT_PERF stage=cpu-cancel reason=newer-preview bands=' +
        `${bandWorkers.length}`);
      return;
    }
    if (!state.worker || state.workerCancelled) return;
    try {
      taskpool.cancel(state.worker);
      state.workerCancelled = true;
      console.info('VIVID_EDIT_PERF stage=cpu-cancel reason=newer-preview');
    } catch (_error) { /* completion may already have left the TaskPool */ }
  }

  static process(session: EditSession, preferInteractive: boolean = false): Promise<void> {
    PerfStats.refreshEnabled();
    let state = ImageProcessor.runs.get(session.sessionId);
    if (!state) {
      state = { running: null, queued: false, pendingInteractive: false, pendingAt: 0,
        runNumber: 0, refinementTimer: -1, current: null, previous: null,
        worker: null, refining: false, workerCancelled: false };
      ImageProcessor.runs.set(session.sessionId, state);
    }
    const runState = state;
    const requestedInteractive = preferInteractive || ImageProcessor.isInteractivePreview(session);
    if (runState.running) {
      if (!runState.queued) runState.pendingAt = Date.now();
      runState.queued = true;
      runState.pendingInteractive = runState.pendingInteractive || requestedInteractive;
      // A settled CPU refinement is expendable when a fresh drag arrives.
      // Keep earlier interactive completions publishable; only interrupt the
      // expensive refinement, otherwise continuous drags could show no frame.
      if (requestedInteractive && runState.refining) ImageProcessor.cancelPreviewWorker(runState);
      PerfStats.recordQueued();
      return runState.running;
    }
    const interactive = requestedInteractive || runState.pendingInteractive;
    const queueMs = runState.pendingAt > 0 ? Date.now() - runState.pendingAt : 0;
    runState.pendingInteractive = false;
    runState.pendingAt = 0;
    if (runState.refinementTimer !== -1) clearTimeout(runState.refinementTimer);
    runState.refinementTimer = -1;
    // Reserve the running promise before entering any observed/native code.
    // A reentrant process() call must merge into this run, not start another.
    const run = Promise.resolve().then(() => ImageProcessor.runProcess(session, runState, interactive, queueMs))
      .catch((error: Error) => {
        // Processing is triggered from gesture callbacks without awaiting the
        // promise. Never let a malformed mask frame become an unhandled
        // rejection that takes down the application.
        console.error('Image processing frame failed: ' + JSON.stringify(error));
      })
      .finally(() => {
      if (ImageProcessor.runs.get(session.sessionId) === runState && runState.running === run) {
        runState.running = null;
        if (runState.queued) {
          runState.queued = false;
          ImageProcessor.process(session);
        }
      }
      PerfStats.tick();
    });
    runState.running = run;
    return run;
  }

  private static async runProcess(session: EditSession, state: PreviewRunState,
    interactive: boolean, queueMs: number): Promise<void> {
    if (ImageProcessor.runs.get(session.sessionId) !== state) return;
    const src = session.sourcePixelMap;
    if (!src) return;
    // Only user/model changes advance the parameter version. Starting a job
    // must not invalidate another job or create a perpetual latest-wins loop.
    const requestVersion = session.processingRequestVersion;
    const runNumber = ++state.runNumber;
    const before = session.showBefore;
    state.refining = !interactive;
    state.workerCancelled = false;
    console.info(`VIVID_FRAME t=${Date.now()} event=render_begin request=${requestVersion} sid=${session.sessionId} run=${runNumber} before=${before} interactive=${interactive} queueMs=${queueMs} gpu=${session.gpuPreviewActive} surface=${session.gpuSurfaceId.length > 0} detail=${session.detailPixelMap !== null} cropping=${session.isCropping} crop=${session.cropLeft.toFixed(3)},${session.cropTop.toFixed(3)},${session.cropRight.toFixed(3)},${session.cropBottom.toFixed(3)} ratio=${session.cropAspectRatio} rot=${session.rotation} geo=${geometryActive(session.geometry) ? session.geometry.join(',') : 'off'}`);
    const snapshot = before ? ImageProcessor.beforeSnapshot(session) : ImageProcessor.snapshot(session);
    const surface = session.gpuSurfaceId;
    // Interaction intent is captured at enqueue, so waiting behind another
    // render cannot silently turn a drag into a full-resolution CPU frame.
    // Colour/masks remain in source coordinates; the final GPU present pass
    // applies crop, quarter-turn rotation and flips to the graded texture.
    if (surface && !geometryActive(snapshot.geometry)) {
      const begin = Date.now();
      // The direct EGL surface must follow the same bounded interactive path
      // as the readback renderer.  Before this guard, attaching XComponent
      // caused every slider event to upload/process the full RAW dimensions,
      // defeating the 512px drag preview and making large images stutter.
      const sourceMax = Math.max(session.imageWidth, session.imageHeight);
      const gpuScale = interactive && sourceMax > ImageProcessor.INTERACTIVE_MAX_DIMENSION
        ? ImageProcessor.INTERACTIVE_MAX_DIMENSION / sourceMax : 1;
      const gpuWidth = Math.max(1, Math.round(session.imageWidth * gpuScale));
      const gpuHeight = Math.max(1, Math.round(session.imageHeight * gpuScale));
      await ImageProcessor.prepareMasks(snapshot, gpuWidth, gpuHeight);
      let upload: ArrayBuffer | null = null;
      if (GpuShaderBridge.needsSource(session, src, gpuWidth, gpuHeight, snapshot)) {
        upload = gpuScale < 1
            ? await ImageProcessor.obtainInteractiveBuffer(src, session.imageWidth, session.imageHeight,
              gpuWidth, gpuHeight, session)
            : await ImageProcessor.obtainSourceBuffer(src, gpuWidth, gpuHeight, session, true);
        if (upload && snapshot.retouchMarks.length > 0) {
          upload = await ImageProcessor.obtainRetouchedSource(session, snapshot, src, upload, gpuWidth, gpuHeight);
        }
      }
      if (session.sourcePixelMap !== src || ImageProcessor.runs.get(session.sessionId) !== state) return;
      const presented = await GpuShaderBridge.present(session, snapshot, src, upload,
        gpuWidth, gpuHeight, surface);
      console.info(`VIVID_FRAME t=${Date.now()} event=gpu_complete request=${requestVersion} sid=${session.sessionId} run=${runNumber} before=${before} ok=${presented} size=${gpuWidth}x${gpuHeight} upload=${upload !== null} elapsed=${Date.now() - begin} layer=${session.gpuPreviewActive ? 'gpu' : 'cpu'}`);
      if (session.sourcePixelMap !== src || ImageProcessor.runs.get(session.sessionId) !== state) return;
      if (presented && session.gpuSurfaceId === surface) {
        if (before !== session.showBefore) {
          // A hold started while this graded frame was presenting. The surface
          // now shows the wrong frame; put the original back immediately.
          ImageProcessor.finishPreview(session, state, src, requestVersion, interactive);
          if (session.showBefore) ImageProcessor.renderBeforePreview(session);
          return;
        }
        ImageProcessor.beforeOnGpu.set(session.sessionId, before);
        session.gpuPreviewActive = true;
        session.gpuSurfaceDirty = true;
        const output = GpuShaderBridge.outputGeometry(snapshot, gpuWidth, gpuHeight);
        session.previewWidth = output.width;
        session.previewHeight = output.height;
        AppStorage.setOrCreate('vividGpuBackend', 'egl-direct');
        PerfStats.recordPhase('gpuPresent', Date.now() - begin);
        if (session.onPreviewUpdated) session.onPreviewUpdated();
        if (!before) ImageProcessor.scheduleHistogram(session);
        ImageProcessor.finishPreview(session, state, src, requestVersion, interactive);
        return;
      }
    }
    // Keep the last valid GPU frame until the CPU replacement is ready.
    // Clearing it before rendering the comparison exposed black/old pixels.
    console.info(`VIVID_FRAME t=${Date.now()} event=cpu_path_pending request=${requestVersion} before=${before} preview=${session.previewPixelMap !== null}`);
    // Slider gestures use a bounded 512px surface while events are arriving.
    // The source PixelMap is never scaled in place; the downsampled RGBA copy
    // is cached per session and reused by the native/TaskPool paths. The
    // interactive flag was captured at render_begin so the GPU attempt above
    // cannot expire the gesture window mid-render.
    const sourceWidth = session.imageWidth;
    const sourceHeight = session.imageHeight;
    const sourceMax = Math.max(sourceWidth, sourceHeight);
    // First CPU frame after open/profile replacement must not spend seconds
    // rendering the full bounded RAW before showing any edited result.
    // Refinement remains full-size, cooperative and cancelable on a new drag.
    const quickCpu = interactive || (!state.current && sourceMax > ImageProcessor.INTERACTIVE_MAX_DIMENSION);
    state.refining = !quickCpu;
    const previewScale = quickCpu && sourceMax > ImageProcessor.INTERACTIVE_MAX_DIMENSION ?
      ImageProcessor.INTERACTIVE_MAX_DIMENSION / sourceMax : 1;
    const renderWidth = Math.max(1, Math.round(sourceWidth * previewScale));
    const renderHeight = Math.max(1, Math.round(sourceHeight * previewScale));
    let sourceBufferOverride: ArrayBuffer | undefined;
    if (previewScale < 1) {
      const interactiveBuffer = await ImageProcessor.obtainInteractiveBuffer(
        src, sourceWidth, sourceHeight, renderWidth, renderHeight, session);
      if (!interactiveBuffer) return;
      sourceBufferOverride = interactiveBuffer;
    }

    const geometry = await ImageProcessor.renderToBuffer(
      src, renderWidth, renderHeight, session, true,
      (): boolean => session.sourcePixelMap !== src || ImageProcessor.runs.get(session.sessionId) !== state,
      true, sourceBufferOverride, false, snapshot, state);
    if (!geometry) return;
    // Validate the buffer contract, not its colours or opacity: an all-black
    // or transparent image may be an intentional edit or a valid PNG.
    if (geometry.width <= 0 || geometry.height <= 0 ||
      geometry.pixels.length !== geometry.width * geometry.height * 4) {
      console.info(`VIVID_FRAME t=${Date.now()} event=invalid_frame_rejected request=${requestVersion} ` +
        `sid=${session.sessionId} run=${runNumber} size=${geometry.width}x${geometry.height}`);
      ImageProcessor.finishPreview(session, state, src, requestVersion, interactive);
      return;
    }

    // 预览发布：每趟后台处理完成后新建 PixelMap 并整体赋值——
    // 某些设备上同引用写入像素不会触发 Image 重新上传，导致预览
    // 需要点击屏幕才更新。这里保证预览自动刷新；旧帧延迟一帧释放，
    // 避免画布切换瞬间引用被释放而闪空。
    const width = geometry.width;
    const height = geometry.height;
    const packingBegin = Date.now();
    const created = await ImageProcessor.createPixelMapFromBuffer(geometry.pixels, width, height);
    console.info(`VIVID_EDIT_PERF stage=cpu-pixelmap ms=${Date.now() - packingBegin} size=${width}x${height}`);
    if (!created) return;
    if (session.sourcePixelMap !== src || ImageProcessor.runs.get(session.sessionId) !== state) {
      try { created.release(); } catch (_error) { /* already released */ }
      return;
    }
    if (before !== session.showBefore) {
      try { created.release(); } catch (_error) { /* already released */ }
      ImageProcessor.finishPreview(session, state, src, requestVersion, interactive);
      return;
    }
    if (before) {
      const oldBefore = session.beforePixelMap;
      session.beforePixelMap = created;
      session.beforePixelMapSource = src;
      session.beforeGeometryKey = ImageProcessor.beforeGeometryKey(snapshot);
      const beforeVersion = AppStorage.get<number>('beforePreviewVersion') ?? 0;
      AppStorage.setOrCreate('beforePreviewVersion', beforeVersion + 1);
      if (oldBefore && oldBefore !== src) {
        setTimeout(() => {
          try { oldBefore.release(); } catch (_error) { /* already released */ }
        }, 64);
      }
    } else {
      if (state.previous) {
        console.info(`VIVID_FRAME t=${Date.now()} event=previous_pixelmap_release request=${requestVersion}`);
        state.previous.release();
        state.previous = null;
      }
      state.previous = state.current;
      state.current = created;
      session.previewPixelMap = created;
      // The canvas now draws `created`, so the frame parked by a previous
      // clearSourceCache is unreachable. Releasing it here instead of at
      // clearSourceCache time is what keeps a profile switch from showing a
      // freed PixelMap while the new RAW preview is still decoding.
      ImageProcessor.dropRetainedFrames(session.sessionId);
    }
    // Center-pixel RGB sample: distinguishes "pixels not graded" (pipeline
    // bug) from "pixels graded but not displayed" (rendering bug) when the
    // user reports that grading stops responding after a crop.
    const cx = Math.min(geometry.pixels.length - 4, ((height >> 1) * width + (width >> 1)) * 4);
    console.info(`VIVID_FRAME t=${Date.now()} event=pixelmap_publish request=${requestVersion} sid=${session.sessionId} run=${runNumber} before=${before} size=${width}x${height} ` +
      `rgb=${geometry.pixels[cx]},${geometry.pixels[cx + 1]},${geometry.pixels[cx + 2]}`);
    session.previewWidth = width;
    session.previewHeight = height;
    session.gpuPreviewActive = false;
    if (session.gpuSurfaceDirty) {
      session.gpuSurfaceDirty = false;
      await GpuShaderBridge.clearDirectSurface(session);
    }
    if (session.sourcePixelMap !== src || ImageProcessor.runs.get(session.sessionId) !== state) return;

    // 窄信号驱动画布重绘，避免整卡重建；直方图独立防抖。
    if (!before) ImageProcessor.scheduleHistogram(session);
    if (session.onPreviewUpdated) {
      session.onPreviewUpdated();
    } else {
      const currentVersion = AppStorage.get<number>('previewVersion') ?? 0;
      AppStorage.setOrCreate('previewVersion', currentVersion + 1);
    }
    ImageProcessor.finishPreview(session, state, src, requestVersion, quickCpu);
  }

  private static finishPreview(session: EditSession, state: PreviewRunState,
    src: image.PixelMap, requestVersion: number, interactive: boolean): void {
    if (requestVersion !== session.processingRequestVersion) {
      PerfStats.recordStalePublish();
      state.queued = true;
      // The merged request keeps the interaction intent captured on enqueue.
      return;
    }
    if (!interactive) return;
    state.refinementTimer = setTimeout(() => {
      state.refinementTimer = -1;
      if (session.sourcePixelMap === src && ImageProcessor.runs.get(session.sessionId) === state &&
        requestVersion === session.processingRequestVersion && !state.running && !state.queued) {
        ImageProcessor.process(session);
      }
    }, Math.max(1, ImageProcessor.INTERACTIVE_QUIET_MS - (Date.now() - session.lastProcessingRequestAt) + 1));
  }

  private static readonly INTERACTIVE_MAX_DIMENSION: number = 512;
  private static readonly INTERACTIVE_QUIET_MS: number = 160;

  private static isInteractivePreview(session: EditSession): boolean {
    return session.lastProcessingRequestAt > 0 &&
      Date.now() - session.lastProcessingRequestAt < ImageProcessor.INTERACTIVE_QUIET_MS;
  }

  /** Return a cached bilinear downsample of the bounded source surface. */
  private static async obtainInteractiveBuffer(
    source: image.PixelMap,
    sourceWidth: number,
    sourceHeight: number,
    targetWidth: number,
    targetHeight: number,
    session: EditSession,
  ): Promise<ArrayBuffer | null> {
    const cached = ImageProcessor.interactiveBuffers.get(session.sessionId);
    if (cached && cached.pixelMap === source && cached.sourceWidth === sourceWidth &&
      cached.sourceHeight === sourceHeight && cached.width === targetWidth && cached.height === targetHeight) {
      return cached.buffer.slice(0);
    }
    const sourceBuffer = await ImageProcessor.obtainSourceBuffer(
      source, sourceWidth, sourceHeight, session, true);
    if (!sourceBuffer) return null;
    const sourcePixels = new Uint8Array(sourceBuffer);
    const scaled = new Uint8Array(targetWidth * targetHeight * 4);
    const xRatio = sourceWidth / targetWidth;
    const yRatio = sourceHeight / targetHeight;
    for (let y = 0; y < targetHeight; y++) {
      const sy = (y + 0.5) * yRatio - 0.5;
      const y0 = Math.max(0, Math.floor(sy));
      const y1 = Math.min(sourceHeight - 1, y0 + 1);
      const fy = Math.max(0, Math.min(1, sy - y0));
      for (let x = 0; x < targetWidth; x++) {
        const sx = (x + 0.5) * xRatio - 0.5;
        const x0 = Math.max(0, Math.floor(sx));
        const x1 = Math.min(sourceWidth - 1, x0 + 1);
        const fx = Math.max(0, Math.min(1, sx - x0));
        const a = (y0 * sourceWidth + x0) * 4;
        const b = (y0 * sourceWidth + x1) * 4;
        const c = (y1 * sourceWidth + x0) * 4;
        const d = (y1 * sourceWidth + x1) * 4;
        const out = (y * targetWidth + x) * 4;
        for (let channel = 0; channel < 4; channel++) {
          const top = sourcePixels[a + channel] + (sourcePixels[b + channel] - sourcePixels[a + channel]) * fx;
          const bottom = sourcePixels[c + channel] + (sourcePixels[d + channel] - sourcePixels[c + channel]) * fx;
          scaled[out + channel] = Math.max(0, Math.min(255, Math.round(top + (bottom - top) * fy)));
        }
      }
    }
    const buffer = scaled.buffer as ArrayBuffer;
    ImageProcessor.interactiveBuffers.set(session.sessionId, {
      pixelMap: source,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      width: targetWidth,
      height: targetHeight,
      buffer: buffer.slice(0),
    });
    return buffer.slice(0);
  }

  /**
   * 给深度网络准备一张有界 RGBA 代理（长边 ≤ 512）。
   *
   * 深度模型只需要画面结构，不需要最终调色；因此用源帧而不是渲染结果，
   * 既避免把 LUT/黑白等效果喂给网络，也保证深度图始终与未裁剪像素对齐。
   * 复用 `obtainSourceBuffer` 的缓存，不会为每次生成重新解码照片。
   */
  static async bokehDepthProxy(session: EditSession): Promise<BokehDepthProxy | null> {
    const source = session.sourcePixelMap;
    if (!source) return null;
    try {
      const info = await source.getImageInfo();
      const sourceWidth = info.size.width;
      const sourceHeight = info.size.height;
      if (sourceWidth <= 0 || sourceHeight <= 0) return null;
      const buffer = await ImageProcessor.obtainSourceBuffer(
        source, sourceWidth, sourceHeight, session, true);
      if (!buffer) return null;
      const scale = Math.min(1, 512 / Math.max(sourceWidth, sourceHeight));
      const width = Math.max(1, Math.round(sourceWidth * scale));
      const height = Math.max(1, Math.round(sourceHeight * scale));
      if (width === sourceWidth && height === sourceHeight) {
        return { pixels: buffer, width: width, height: height };
      }
      const src = new Uint8Array(buffer);
      const scaled = new Uint8Array(width * height * 4);
      const xRatio = sourceWidth / width;
      const yRatio = sourceHeight / height;
      for (let y = 0; y < height; y++) {
        const sy = (y + 0.5) * yRatio - 0.5;
        const y0 = Math.max(0, Math.floor(sy));
        const y1 = Math.min(sourceHeight - 1, y0 + 1);
        const fy = Math.max(0, Math.min(1, sy - y0));
        for (let x = 0; x < width; x++) {
          const sx = (x + 0.5) * xRatio - 0.5;
          const x0 = Math.max(0, Math.floor(sx));
          const x1 = Math.min(sourceWidth - 1, x0 + 1);
          const fx = Math.max(0, Math.min(1, sx - x0));
          const a = (y0 * sourceWidth + x0) * 4;
          const b = (y0 * sourceWidth + x1) * 4;
          const c = (y1 * sourceWidth + x0) * 4;
          const d = (y1 * sourceWidth + x1) * 4;
          const out = (y * width + x) * 4;
          for (let channel = 0; channel < 4; channel++) {
            const top = src[a + channel] + (src[b + channel] - src[a + channel]) * fx;
            const bottom = src[c + channel] + (src[d + channel] - src[c + channel]) * fx;
            scaled[out + channel] = Math.max(0, Math.min(255, Math.round(top + (bottom - top) * fy)));
          }
        }
      }
      return { pixels: scaled.buffer as ArrayBuffer, width: width, height: height };
    } catch (_error) {
      return null;
    }
  }

  /** Bilinear downsample of one crop region of the source, used as the GPU
   * texture while a crop is applied. The full-source read stays cached; only
   * the region sampling repeats when the crop rect changes. */
  private static scheduleHistogram(session: EditSession): void {
    const previous = ImageProcessor.histogramTimers.get(session.sessionId);
    if (previous !== undefined) clearTimeout(previous);
    const timer = setTimeout(async () => {
      ImageProcessor.histogramTimers.delete(session.sessionId);
      try {
        const source = session.sourcePixelMap;
        if (!source) return;
        const version = session.processingRequestVersion;
        const scale = Math.min(1, 256 / Math.max(session.imageWidth, session.imageHeight));
        const w = Math.max(1, Math.round(session.imageWidth * scale));
        const h = Math.max(1, Math.round(session.imageHeight * scale));
        const pixels = await ImageProcessor.obtainInteractiveBuffer(source, session.imageWidth, session.imageHeight, w, h, session);
        if (!pixels || session.sourcePixelMap !== source || session.processingRequestVersion !== version) return;
        const result = await ImageProcessor.renderToBuffer(source, w, h, session, true,
          () => session.sourcePixelMap !== source || session.processingRequestVersion !== version, true, pixels);
        if (!result || session.sourcePixelMap !== source || session.processingRequestVersion !== version) return;
        session.histogramR.fill(0); session.histogramG.fill(0); session.histogramB.fill(0); session.histogramL.fill(0);
        for (let i = 0; i < result.pixels.length; i += 4) {
          const r = result.pixels[i], g = result.pixels[i + 1], b = result.pixels[i + 2];
          session.histogramR[r]++; session.histogramG[g]++; session.histogramB[b]++;
          session.histogramL[Math.round(r * 0.2126 + g * 0.7152 + b * 0.0722)]++;
        }
        session.histogramVersion++;
        const histogramSignal = AppStorage.get<number>('histogramVersion') ?? 0;
        AppStorage.setOrCreate('histogramVersion', histogramSignal + 1);
      } catch (error) {
        console.info('VIVID histogram update skipped: ' + String(error));
      }
    }, 240);
    ImageProcessor.histogramTimers.set(session.sessionId, timer);
  }

  /** Read the source once for a live preview and return a task-owned copy. */
  private static async obtainSourceBuffer(
    source: image.PixelMap,
    width: number,
    height: number,
    session: EditSession,
    cacheSource: boolean,
  ): Promise<ArrayBuffer | null> {
    const cachedEntries = cacheSource ? ImageProcessor.sourceBuffers.get(session.sessionId) : undefined;
    const cached = cachedEntries?.find((entry: SourceBufferCache): boolean =>
      entry.pixelMap === source && entry.width === width && entry.height === height);
    if (cached) {
      // TaskPool implementations differ in whether ArrayBuffer parameters are
      // transferred or cloned.  A copy keeps the cache valid in both cases.
      return cached.buffer.slice(0);
    }
    const buffer = new ArrayBuffer(width * height * 4);
    try {
      const readStart = Date.now();
      await source.readPixelsToBuffer(buffer);
      PerfStats.recordPhase('readPixels', Date.now() - readStart);
    } catch (_error) {
      return null;
    }
    if (cacheSource) {
      let entries = ImageProcessor.sourceBuffers.get(session.sessionId);
      if (!entries) {
        entries = [];
        ImageProcessor.sourceBuffers.set(session.sessionId, entries);
      }
      entries.push({
        pixelMap: source,
        width: width,
        height: height,
        buffer: buffer.slice(0),
      });
      if (entries.length > 2) entries.shift();
    }
    return buffer;
  }

  /**
   * Run the whole pipeline on an arbitrary source at the given resolution and
   * return the finished pixel buffer. Used by the editor preview (1280 max
   * dimension, or 512px during slider interaction) and by
   * full-resolution export. Never touches session.previewPixelMap.
   */
  static async renderToBuffer(
    source: image.PixelMap,
    width: number,
    height: number,
    session: EditSession,
    useMaskCache: boolean,
    isStale: () => boolean,
    cacheSource: boolean = false,
    sourceBufferOverride?: ArrayBuffer,
    referenceCpu: boolean = false,
    preparedSnapshot?: EditSession,
    previewState?: PreviewRunState,
  ): Promise<GeometryResult | null> {
    const sourceSession = session;
    session = preparedSnapshot ?? ImageProcessor.snapshot(session);
    let sourceBuffer: ArrayBuffer | null = sourceBufferOverride ? sourceBufferOverride.slice(0) : null;
    // 优先走 TaskPool 多线程：蒙版 alpha 以副本随任务传输（见
    // buildWorkerParams），蒙版会话同样后台化，不再整卡占用主线程。
    try {
      // 蒙版栅格化与源像素读取**互不依赖**，却一直被顺序等待：44MP 实测两者
      // 合计吃掉十几秒，顺序等待等于把两段独立开销相加。并发发起后前置阶段
      // 变成 max(两者) 而不是 sum —— 不改变任何输出，只是不再串行。
      const prepWallStart = Date.now();
      let prepMasksMs = 0;
      let prepReadMs = 0;
      const masksTask = async (): Promise<void> => {
        const start = Date.now();
        await ImageProcessor.prepareMasks(session, width, height, isStale);
        prepMasksMs = Date.now() - start;
      };
      const readTask = async (): Promise<ArrayBuffer | null> => {
        const start = Date.now();
        const buffer = sourceBuffer !== null ? sourceBuffer
          : await ImageProcessor.obtainSourceBuffer(source, width, height, sourceSession, cacheSource);
        prepReadMs = Date.now() - start;
        return buffer;
      };
      const pendingMasks = masksTask();
      sourceBuffer = await readTask();
      await pendingMasks;
      // 放大瓦片的准备阶段（蒙版栅格化 + 源像素拷贝）此前在真机日志里完全不可见：
      // 它们与 `cpu-stages` 分开发生，只看渲染阶段会误判成"native 细节慢"。
      if (session.renderViewport.length === 6) {
        console.info(`VIVID_DETAIL prep masks=${prepMasksMs}ms read=${prepReadMs}ms ` +
          `wall=${Date.now() - prepWallStart}ms size=${width}x${height}`);
      }
      // 导出路径专用（预览/细节瓦片都带 cacheSource=true）：这一对前置开销在
      // 原尺寸大图上可达十几秒，且发生在导出尺寸判断之前 —— 选多小的导出尺寸
      // 都省不掉，必须能单独量出来才知道该先修哪个。wall 是并发后的实际墙钟。
      if (!cacheSource) {
        console.info(`VIVID_EDIT_PERF stage=export-prep masks=${prepMasksMs}ms read=${prepReadMs}ms` +
          ` wall=${Date.now() - prepWallStart}ms size=${width}x${height}`);
      }
      if (!sourceBuffer) return null;
      if (session.retouchMarks.length > 0) {
        sourceBuffer = await ImageProcessor.obtainRetouchedSource(sourceSession, session, source, sourceBuffer, width, height);
      }
      if (isStale()) {
        PerfStats.recordDiscardedRun();
        return null;
      }
      if (!referenceCpu && cacheSource && !geometryActive(session.geometry)) {
        const gpuStart = Date.now();
        const gpuBuffer = await GpuShaderBridge.renderPreview(sourceBuffer, width, height, session);
        if (gpuBuffer && !isStale()) {
          PerfStats.recordPhase('gpu', Date.now() - gpuStart);
          AppStorage.setOrCreate('vividGpuBackend', 'opengl-es2');
          console.info('VIVID_GPU native shader preview active');
          const output = GpuShaderBridge.outputGeometry(session, width, height);
          return {
            pixels: new Uint8ClampedArray(gpuBuffer),
            width: output.width,
            height: output.height,
          };
        }
      }
      // 导出复用调色的原生 GPU 管线做全像素渲染：先渲染未裁剪整帧，
      // 裁剪/旋转/翻转再由 TaskPool 的 applyGeometryTask 补齐。透视几何、
      // 蒙版视图任务与 shader 不支持的调整项继续走下方 CPU worker 路径。
      if (!referenceCpu && !cacheSource && !geometryActive(session.geometry) &&
        session.renderViewport.length === 0) {
        const gpuStart = Date.now();
        const gpuBuffer = await GpuShaderBridge.renderExport(sourceBuffer, width, height, session);
        if (gpuBuffer && !isStale()) {
          PerfStats.recordPhase('gpu', Date.now() - gpuStart);
          const needsGeometry = session.cropLeft > 0 || session.cropTop > 0 ||
            session.cropRight < 1 || session.cropBottom < 1 ||
            session.rotation !== 0 || session.flipH || session.flipV;
          if (!needsGeometry) {
            AppStorage.setOrCreate('vividGpuExportBackend', 'opengl-es2');
            console.info(`VIVID_GPU native shader export active size=${width}x${height}`);
            return {
              pixels: new Uint8ClampedArray(gpuBuffer),
              width: width,
              height: height,
            };
          }
          // GPU 瓦片输出的裁剪/旋转/翻转不再进 TaskPool 跑 ArkTS 逐像素重映射
          // （44MP 下采样表构建 + 全帧重排实测 10 秒以上，是导出渲染主体的最大
          // 单项）。直接走主线程 native remapGeometry：一次整数拷贝，毫秒级。
          const geoStart = Date.now();
          const geo = ImageProcessor.remapGeometryDeferred(new Uint8ClampedArray(gpuBuffer), {
            geometry: session.geometry,
            cropLeft: session.cropLeft,
            cropTop: session.cropTop,
            cropRight: session.cropRight,
            cropBottom: session.cropBottom,
            rotation: session.rotation,
            flipH: session.flipH,
            flipV: session.flipV,
            ignoreCrop: false,
            deferRemap: false,
            referenceWidth: 0,
            referenceHeight: 0,
          } as ProcessParams, width, height);
          PerfStats.recordPhase('gpuGeometry', Date.now() - geoStart);
          if (geo && geo.pixels.byteLength > 0 && !isStale()) {
            AppStorage.setOrCreate('vividGpuExportBackend', 'opengl-es2');
            console.info(`VIVID_GPU native shader export active size=${geo.width}x${geo.height}`);
            return geo;
          }
          console.warn('VIVID_GPU export geometry task failed, falling back to CPU pipeline');
        }
      }
      // 导出路径直接移交 sourceBuffer（TaskPool 转移后 detach）；预览路径
      // 保留副本，主线程回退仍需要完整源数据。
      const cachedNoise = denoiseEnabled(session.denoise) && width * height <= 4194304
        ? await ImageProcessor.obtainDenoisedSource(sourceSession, session, source, sourceBuffer,
          width, height, previewState) : null;
      if (isStale()) return null;
      const params = ImageProcessor.buildWorkerParams(session,
        cachedNoise ? cachedNoise.slice(0) : (cacheSource ? sourceBuffer.slice(0) : sourceBuffer), width, height,
        previewState === undefined);
      // The retained stage already applied noise reduction; the colour worker
      // must not apply it twice or destroy the transferable cache buffer.
      if (cachedNoise) params.denoise = undefined;
      // 大帧（导出 / ≥2MP 预览 / 放大瓦片）按行分带并行：整帧切成 N 个横带，
      // 每带一个 TaskPool 任务。降噪、旧式蒙版、before 渲染、<2MP 小预览仍走
      // 下面原来的单任务串行路径（见 exportBandsEligible 的逐条例外）。
      if (ImageProcessor.exportBandsEligible(params, width, height, referenceCpu)) {
        const bandStart = Date.now();
        try {
          const banded = await ImageProcessor.runExportBands(params, width, height, isStale,
            previewState !== undefined ? 'preview' : (cacheSource ? 'tile' : 'export'), previewState);
          if (banded) {
            PerfStats.recordPhase('worker', Date.now() - bandStart);
            return banded;
          }
          if (isStale() || (previewState !== undefined && previewState.workerCancelled)) return null;
          console.info('VIVID_EDIT_PERF stage=export-bands skipped reason=no-bands');
        } catch (_error) {
          if (isStale() || (previewState !== undefined && previewState.workerCancelled)) return null;
          console.error('Export band pipeline failed, falling back to serial worker: ' +
            JSON.stringify(_error));
        }
      }
      const task = new taskpool.Task(processPixels, params);
      if (previewState) {
        previewState.worker = task;
        previewState.workerCancelled = false;
      }
      const workerStart = Date.now();
      // 导出路径此前只能等 worker 自己跑完：取消请求只在阶段之间被检查，而带
      // 蒙版的一帧在 worker 里可能跑十几秒（逐像素的蒙版混合与合成），所以点了
      // 取消也结束不了。这里把取消请求转发成 taskpool.cancel，worker 内部逐
      // band 的 isCanceled() 会立刻中断（一个 band 只有 32768 像素）。
      let cancelPoll: number = -1;
      if (!previewState) {
        cancelPoll = setInterval((): void => {
          if (!isStale() || cancelPoll === -1) return;
          clearInterval(cancelPoll);
          cancelPoll = -1;
          try {
            taskpool.cancel(task);
            console.info('VIVID_EDIT_PERF stage=cpu-cancel reason=export-request');
          } catch (_error) { /* completion may already have left the TaskPool */ }
        }, 100);
      }
      let result: ProcessResult;
      try {
        result = await taskpool.execute(task) as ProcessResult;
      } finally {
        if (cancelPoll !== -1) clearInterval(cancelPoll);
        if (previewState?.worker === task) previewState.worker = null;
        console.info(`VIVID_EDIT_PERF stage=cpu-worker ms=${Date.now() - workerStart} size=${width}x${height} cancelled=${previewState?.workerCancelled ?? false}`);
      }
      PerfStats.recordPhase('worker', Date.now() - workerStart);
      if (isStale() || previewState?.workerCancelled) return null;
      if (result && result.buffer.byteLength > 0) {
        if (cacheSource) AppStorage.setOrCreate('vividGpuBackend', 'taskpool-cpu-fallback');
        if (params.deferRemap) {
          // worker 交回的是旋转前的帧，裁剪/旋转/翻转在主线程用 native 完成。
          return ImageProcessor.remapGeometryDeferred(new Uint8ClampedArray(result.buffer),
            params, result.width, result.height);
        }
        return {
          pixels: new Uint8ClampedArray(result.buffer),
          width: result.width,
          height: result.height,
        };
      }
    } catch (_error) {
      // TaskPool cancellation must never relaunch the same slow frame on the
      // UI thread. The scheduler starts the latest queued parameters instead.
      if (isStale() || previewState?.workerCancelled) return null;
      if (session.retouchMarks.length > 0) return null;
      console.error('TaskPool path failed, falling back to main thread: ' + JSON.stringify(_error));
    }

    // TaskPool 会转移并 detach sourceBuffer；主线程回退路径需要时重新读取。
    // 仅导出路径（cacheSource=false）可能发生转移，此时 width/height 与
    // 源 PixelMap 一致，重读语义正确。
    if (!sourceBuffer || sourceBuffer.byteLength === 0) {
      sourceBuffer = await ImageProcessor.obtainSourceBuffer(source, width, height, sourceSession, cacheSource);
      if (!sourceBuffer) return null;
    }

    // Region jobs must retain their global spatial coordinates. A worker
    // failure leaves the bounded preview visible instead of using the legacy
    // fallback, which has no viewport-aware spatial transform.
    if (session.renderViewport.length === 6) return null;

    // 回退：主线程分片路径（缓冲池复用，避免每趟 ~70MB 垃圾触发 GC 长暂停）。
    let pipelineCount = 0;
    for (const layer of session.layers) {
      layer.migrateMask();
      pipelineCount += layer.maskLayers.length > 0 ? layer.maskLayers.length + 1 : 1;
    }
    const pool = ImageProcessor.obtainPool(width, height, Math.max(1, pipelineCount));
    try {
      if (!sourceBuffer) return null;
      new Uint8ClampedArray(pool.source).set(new Uint8ClampedArray(sourceBuffer));
    } catch (_error) {
      return null;
    }
    if (isStale()) return null;

    // Start with base image as result
    pool.result.set(new Uint8ClampedArray(pool.source));
    if (denoiseEnabled(session.denoise)) {
      const original = new Uint8ClampedArray(pool.source);
      // Budget each UI-thread slice by *tap count*, not by row count: the
      // spatial radius is now resolution relative (denoiseSpatialRadius), so a
      // fixed 8192-pixel slice would run up to ~5x longer between yields on a
      // full-resolution fallback. 8192 px at the radius-2 preview budget is the
      // historical slice size, so preview behaviour is unchanged.
      const spatialSpan = 2 * denoiseSpatialRadius(width, height) + 1;
      const rows = Math.max(1, Math.floor(8192 * 25 / Math.max(1, width * spatialSpan * spatialSpan)));
      // The generation's pinned radius, resolved through the same table the
      // TaskPool worker uses. This fallback used to ignore processVersion and
      // always take the frame-relative rule, so a LEGACY photo rendered with a
      // different neighbourhood here than in the worker.
      const fallbackRadius = ImageProcessor.denoiseFallbackRadius(session);
      for (let y = 0; y < height; y += rows) {
        if (isStale()) return null;
        denoiseRows(original, pool.result, width, height, session.denoise, y, Math.min(height, y + rows),
          false, fallbackRadius);
        await new Promise<void>((resolve) => { setTimeout(resolve, 0); });
      }
    }

    // Prepare each visible layer once. The heavy per-pixel work below runs in
    // small bands scheduled as real macrotasks (setTimeout callbacks, not
    // await chains), so the main thread always breathes between bands and the
    // app-freeze watchdog never trips.
    const pipelines: LayerPipeline[] = ImageProcessor.buildPipelines(session, pool, useMaskCache);

    // Process each visible layer from bottom to top, band by band.
    await ImageProcessor.runBandedPipeline(pipelines, pool.result, isStale);
    if (isStale()) return null;

    // Keep the fallback and TaskPool paths identical: LUTs are applied after
    // the existing adjustment/layer composition in their declared order.
    applyLutStack(pool.result, ImageProcessor.plainLuts(session.lutStack));

    // Point colour and the OkLCh grade come FIRST, immediately after the LUTs and before
    // detail and optics, which is the order the TaskPool path uses.
    //
    // This block used to sit AFTER the detail and optics stages, with a comment claiming
    // that put it "before the detail stage so both CPU paths agree on order". The comment
    // was wrong and so was the order: whenever point colour and either of the other two
    // stages were active together, this fallback and the worker published DIFFERENT
    // pixels, which is the one outcome both paths are documented to avoid. Corrected here
    // rather than only in the comment.
    const pointColorSamples = session.pointColor.samples;
    if (pointColorSamples.length > 0 && !pointColorIsIdentity(pointColorSamples)) {
      if (isStale()) return null;
      applyPointColorBuffer(pool.result, width, height, pointColorSamples);
    }

    // OkLCh grade, after point colour for the same reason the worker does it there: a
    // global chroma boost must not be undone by a targeted hue shift applied later.
    const oklchParams = session.oklch.params();
    if (!oklchIsIdentity(oklchParams)) {
      if (isStale()) return null;
      applyOkLChBuffer(pool.result, width, height, oklchParams);
    }

    // Global detail stage. This fallback path must produce the SAME pixels as
    // the worker path, so the stage runs here too, in the same order: after the
    // LUTs and before geometry. It is a single full-frame call rather than a
    // cooperating loop, which is acceptable here precisely because this path
    // only runs after the TaskPool already failed; producing a frame that
    // differs from the worker's would be a worse outcome than a brief stall.
    const detailParams = ImageProcessor.plainDetail(session.detail);
    if (!localContrastIsIdentity(detailParams)) {
      if (isStale()) return null;
      pool.result.set(applyLocalContrast(pool.result, width, height, detailParams,
        Math.max(width, height), session.detailHaze));
    }

    // Lens corrections, in the same position and order as the worker path. Both
    // CPU paths must publish the same pixels, so this runs here too rather than
    // only on the TaskPool. It is one full-frame call per active stage, which is
    // acceptable on a path that only runs after the TaskPool already failed.
    const opticsParams = ImageProcessor.plainOptics(session.optics, session.renderViewport);
    if (!opticsIsIdentity(opticsParams)) {
      if (isStale()) return null;
      pool.result.set(applyOptics(pool.result, width, height, opticsParams));
    }

    // Black-and-white, in the same position the worker uses: LAST among the colour
    // stages, after optics, so the conversion cannot be re-tinted by the chromatic
    // aberration correction and the mixer sees the final colour.
    const blackWhiteParams = session.blackWhite.params();
    if (!blackWhiteIsIdentity(blackWhiteParams)) {
      if (isStale()) return null;
      blackWhiteBuffer(pool.result, width, height, blackWhiteParams);
    }

    // 大光圈，同样在几何之前。这条路径只在 TaskPool 已经失败后才运行，
    // 但输出必须和 worker/分带路径一致，所以这里也走同一个 native 阶段。
    if (session.bokeh.enabled) {
      const bokehParams: ProcessParams = {
        bokeh: ImageProcessor.plainBokeh(session.bokeh),
        bokehDepth: session.bokehDepth !== null
          ? session.bokehDepth.slice().buffer as ArrayBuffer : null,
        bokehDepthWidth: session.bokehDepthWidth,
        bokehDepthHeight: session.bokehDepthHeight,
        source: new ArrayBuffer(0),
        width: width,
        height: height,
        layers: [],
        luts: [],
        cropLeft: 0,
        cropTop: 0,
        cropRight: 1,
        cropBottom: 1,
        rotation: 0,
        flipH: false,
        flipV: false,
        applyGeometry: false,
        ignoreCrop: true,
      };
      const bokehPixels = await ImageProcessor.runBokehPass(
        bokehParams, pool.result, width, height, isStale);
      if (!bokehPixels) return null;
      pool.result.set(bokehPixels);
    }

    // Crop and transform are non-destructive session settings and are always
    // applied to the published buffer; the crop tool's working frame is a
    // canvas overlay that only reaches this pipeline on apply.
    return ImageProcessor.runGeometryCps(pool.result, width, height, session, isStale, pool.geometry);
  }

  /**
   * Spatial radius the main-thread denoise fallback must use for this session.
   *
   * The TaskPool worker (ProcessWorker), the retained denoise task
   * (NoiseReductionTask) and this fallback are the three CPU paths; they must all
   * resolve the radius from the SAME generation table, and the GPU declines a
   * LEGACY session outright (`GpuShaderBridge` reason `denoise-version`) rather
   * than filter with its built-in frame-relative radius.
   */
  static denoiseFallbackRadius(session: EditSession): number {
    const behaviors: ProcessBehaviors = processBehaviors(session.processVersion);
    return behaviors.denoiseFixedRadius;
  }

  private static async obtainDenoisedSource(owner: EditSession, snapshot: EditSession, source: Object,
    pixels: ArrayBuffer, width: number, height: number, previewState?: PreviewRunState): Promise<ArrayBuffer> {
    const settings = snapshot.denoise;
    // Everything the retained stage result depends on is part of the key:
    //   - the source identity and size below/here (the decoded frame),
    //   - all six settings. The key used to carry only four, so moving luminance
    //     contrast or colour smoothness returned the previous cached buffer and the
    //     preview did not change at all;
    //   - the process version, because it selects the denoise radius behaviour and so
    //     two versions with identical settings must not share an entry;
    //   - the retouch marks, because retouch runs *before* this stage,
    //   - the viewport, which records which region of the frame these pixels
    //     are and therefore which neighbourhoods the borders clamp against.
    // The spatial radius is a function of width/height, so no extra term is
    // needed when it changes with the render resolution.
    const key = owner.sessionId + ':' + [width, height, settings.luminance, settings.color,
      settings.detail, settings.colorDetail, settings.luminanceContrast, settings.colorSmoothness,
      snapshot.processVersion, JSON.stringify(snapshot.retouchMarks),
      snapshot.renderViewport.join(',')].join('|');
    const cached = ImageProcessor.denoisedSources.get(key);
    if (cached?.source === source && cached.buffer.byteLength === pixels.byteLength) {
      ImageProcessor.denoisedSources.delete(key); ImageProcessor.denoisedSources.set(key, cached);
      return cached.buffer;
    }
    const params: DenoiseTaskParams = { source: pixels.slice(0), width: width, height: height,
      settings: { luminance: settings.luminance, color: settings.color,
        detail: settings.detail, colorDetail: settings.colorDetail,
        luminanceContrast: settings.luminanceContrast, colorSmoothness: settings.colorSmoothness },
      processVersion: snapshot.processVersion };
    const begin = Date.now();
    const task = new taskpool.Task(denoiseTask, params);
    // The retained stage is the first thing a preview run waits for, so it has
    // to be cancellable like the colour worker: without registering it, a newer
    // slider position would queue behind a stale full-frame filter pass. The
    // worker checks taskpool.Task.isCanceled() every 32 rows.
    if (previewState) previewState.worker = task;
    let buffer: ArrayBuffer | null = null;
    try {
      buffer = await taskpool.execute(task) as ArrayBuffer;
    } finally {
      if (previewState?.worker === task) previewState.worker = null;
    }
    if (!buffer || buffer.byteLength !== width * height * 4) throw new Error('Invalid denoise stage result');
    ImageProcessor.denoisedSources.delete(key);
    // All sessions share a 32 MiB LRU budget. Worker jobs own transferable
    // copies, so eviction and old-session completion cannot corrupt a frame.
    let bytes = buffer.byteLength;
    for (const entry of ImageProcessor.denoisedSources.values()) bytes += entry.buffer.byteLength;
    for (const oldKey of ImageProcessor.denoisedSources.keys()) {
      if (bytes <= 32 * 1024 * 1024) break;
      bytes -= ImageProcessor.denoisedSources.get(oldKey)?.buffer.byteLength ?? 0;
      ImageProcessor.denoisedSources.delete(oldKey);
    }
    ImageProcessor.denoisedSources.set(key, { source: source, buffer: buffer });
    console.info(`VIVID_EDIT_PERF stage=cpu-denoise ms=${Date.now() - begin} size=${width}x${height}`);
    return buffer;
  }

  private static async obtainRetouchedSource(owner: EditSession, snapshot: EditSession, source: Object,
    pixels: ArrayBuffer, width: number, height: number): Promise<ArrayBuffer> {
    const key = owner.sessionId + ':' + width + 'x' + height + ':' +
      JSON.stringify(snapshot.retouchMarks) + ':' + snapshot.renderViewport.join(',');
    const cached = ImageProcessor.retouchedSources.get(key);
    if (cached?.source === source && cached.buffer.byteLength === pixels.byteLength) return cached.buffer;
    const params: RetouchTaskParams = { source: pixels.slice(0), width: width, height: height,
      marks: cloneRetouchMarks(snapshot.retouchMarks), viewport: snapshot.renderViewport.slice() };
    const result = await taskpool.execute(new taskpool.Task(retouchTask, params)) as ArrayBuffer;
    if (result.byteLength !== pixels.byteLength) throw new Error('Invalid retouch result');
    if (result.byteLength <= 16 * 1024 * 1024) {
      let total = result.byteLength;
      for (const entry of ImageProcessor.retouchedSources.values()) total += entry.buffer.byteLength;
      for (const oldKey of ImageProcessor.retouchedSources.keys()) {
        if (total <= 32 * 1024 * 1024) break;
        total -= ImageProcessor.retouchedSources.get(oldKey)?.buffer.byteLength ?? 0;
        ImageProcessor.retouchedSources.delete(oldKey);
      }
      ImageProcessor.retouchedSources.set(key, { source: source, buffer: result });
    }
    return result;
  }

  private static buildPipelines(
    session: EditSession,
    pool: BufferPool,
    useMaskCache: boolean,
  ): LayerPipeline[] {
    const pipelines: LayerPipeline[] = [];
    const result = pool.result;
    for (const layer of session.layers) {
      if (!layer.visible) continue;
      if (layer.opacity <= 0) continue;

      // Check if layer has any adjustments
      const matrix = ColorMatrixBuilder.build(layer.adjustments);
      const hasMatrixAdjustments = !ColorMatrixBuilder.isIdentity(matrix);
      const hasAdvancedAdjustments = layer.adjustments.hasAdvancedAdjustments();
      const hasAdjustments = hasMatrixAdjustments || hasAdvancedAdjustments;

      layer.migrateMask();

      // New mask layers are independent local-adjustment pipelines. A layer's
      // global adjustments are emitted first, followed by each mask layer in
      // stack order, so adding a second mask never overwrites the first.
      if (layer.maskLayers.length > 0) {
        if (hasAdjustments) {
          const base = pool.layerBase[0];
          const adjusted = pool.layerAdjusted[0];
          const maskAdjusted = pool.layerMaskAdjusted[0];
          base.set(result); adjusted.set(result); maskAdjusted.set(result);
          pipelines.push({
            adjustments: layer.adjustments,
            workerAdjustments: ImageProcessor.plainAdjustments(layer.adjustments),
            matrix: hasMatrixAdjustments ? matrix : null,
            hasAdvanced: hasAdvancedAdjustments,
            opacity: layer.opacity,
            blendMode: layer.blendMode,
            mask: null,
            base: base,
            adjusted: adjusted,
            maskAdjustments: new ColorAdjustments(),
            workerMaskAdjustments: ImageProcessor.plainAdjustments(new ColorAdjustments()),
            maskMatrix: null,
            hasMaskAdjustments: false,
            maskAdjusted: maskAdjusted,
            width: pool.width,
            height: pool.height,
          });
        }
        for (const maskLayer of layer.maskLayers) {
          if (!maskLayer.enabled || !maskLayer.visible || maskLayer.components.length === 0) continue;
          const maskKey = layer.id + ':' + maskLayer.id + ':' + session.maskRevision + ':' + pool.width + 'x' + pool.height;
          // 无条件查缓存：renderToBuffer 在进这里之前刚用 prepareMasks 把**同一
          // 尺寸**的蒙版在 TaskPool 里备好（键含尺寸与 revision，不可能撞到预览
          // 的条目）。曾经按 useMaskCache=false 跳过缓存，结果导出在主线程同步
          // 做 44MP 栅格化，进度条卡死在 20%。
          let maskBuffer = session.maskCache.get(maskKey);
          if (!maskBuffer) {
            // 同 buildWorkerParams：代理未就绪时当帧退回无门限版本且不缓存。
            const auto = ImageProcessor.renderMaskLayerSync(session, maskLayer, pool.width, pool.height);
            maskBuffer = auto !== null ? auto : MaskRenderer.renderMaskLayer(maskLayer, pool.width, pool.height);
            if (auto !== null) session.maskCache.set(maskKey, maskBuffer);
          }
          const localMatrix = ColorMatrixBuilder.build(maskLayer.adjustments);
          const localHasMatrix = !ColorMatrixBuilder.isIdentity(localMatrix);
          const localHasAdvanced = maskLayer.adjustments.hasAdvancedAdjustments();
          if (!localHasMatrix && !localHasAdvanced) continue;
          const base = pool.layerBase[0];
          const adjusted = pool.layerAdjusted[0];
          const maskAdjusted = pool.layerMaskAdjusted[0];
          base.set(result); adjusted.set(result); maskAdjusted.set(result);
          pipelines.push({
            adjustments: maskLayer.adjustments,
            workerAdjustments: ImageProcessor.plainAdjustments(maskLayer.adjustments),
            matrix: localHasMatrix ? localMatrix : null,
            hasAdvanced: localHasAdvanced,
            opacity: Math.max(0, Math.min(1, layer.opacity)),
            blendMode: BlendMode.NORMAL,
            mask: maskBuffer,
            base: base,
            adjusted: adjusted,
            maskAdjustments: new ColorAdjustments(),
            workerMaskAdjustments: ImageProcessor.plainAdjustments(new ColorAdjustments()),
            maskMatrix: null,
            hasMaskAdjustments: false,
            maskAdjusted: maskAdjusted,
            width: pool.width,
            height: pool.height,
          });
        }
        continue;
      }

      if (!hasAdjustments && !layer.hasMask()) continue;

      // Get mask buffer. The session cache is keyed to the preview resolution,
      // so full-resolution export renders masks fresh instead.
      let maskBuffer: Uint8ClampedArray | null = null;
      if (layer.hasMask() && layer.mask) {
          const cached = useMaskCache ? session.maskCache.get(layer.id) : undefined;
        if (cached) {
          maskBuffer = cached;
        } else {
          maskBuffer = MaskRenderer.renderMask(layer.mask, pool.width, pool.height);
          if (useMaskCache) {
            session.maskCache.set(layer.id, maskBuffer);
          }
        }
      }

      // Mask-scoped colour adjustments: a second adjustment set that only
      // affects pixels inside the mask of this layer.
      const maskMatrix = ColorMatrixBuilder.build(layer.maskAdjustments);
      const hasMaskMatrix = !ColorMatrixBuilder.isIdentity(maskMatrix);
      const hasMaskAdjustments = hasMaskMatrix || layer.maskAdjustments.hasAdvancedAdjustments();

      // Every adjustment layer starts from the already composited result, so
      // several layers build on one another instead of the top layer replacing
      // every lower adjustment. Working buffers come from the pool.
      const base = pool.layerBase[0];
      const adjusted = pool.layerAdjusted[0];
      const maskAdjusted = pool.layerMaskAdjusted[0];
      base.set(result);
      adjusted.set(result);
      maskAdjusted.set(result);
      pipelines.push({
        adjustments: layer.adjustments,
        workerAdjustments: ImageProcessor.plainAdjustments(layer.adjustments),
        matrix: hasMatrixAdjustments ? matrix : null,
        hasAdvanced: hasAdvancedAdjustments,
        opacity: layer.opacity,
        blendMode: layer.blendMode,
        mask: maskBuffer,
        base: base,
        adjusted: adjusted,
        maskAdjustments: layer.maskAdjustments,
        workerMaskAdjustments: ImageProcessor.plainAdjustments(layer.maskAdjustments),
        maskMatrix: hasMaskMatrix ? maskMatrix : null,
        hasMaskAdjustments: hasMaskAdjustments && maskBuffer !== null,
        maskAdjusted: maskAdjusted,
        width: pool.width,
        height: pool.height,
      });
    }
    return pipelines;
  }

  /** Banded pipeline with true macrotask yields between bands. */
  private static runBandedPipeline(
    pipelines: LayerPipeline[],
    result: Uint8ClampedArray,
    isStale: () => boolean,
  ): Promise<void> {
    return new Promise<void>((resolve) => {
      const bandLength = BAND_PIXELS * 4;
      let start = 0;
      const step = (): void => {
        if (isStale()) {
          resolve();
          return;
        }
        const end = Math.min(result.length, start + bandLength);
        for (const pipeline of pipelines) {
          pipeline.base.set(result.subarray(start, end), start);
          ImageProcessor.applyLayerBand(result, pipeline, start, end);
        }
        start = end;
        if (start >= result.length) {
          resolve();
          return;
        }
        setTimeout(step, 0);
      };
      setTimeout(step, 0);
    });
  }

  /** Geometry pass in row slices, each scheduled as its own macrotask. Both the
   * maps and the sample table come from GeometryMath, which the TaskPool worker
   * also uses, so the fallback cannot publish a differently transformed frame. */
  private static runGeometryCps(
    input: Uint8ClampedArray,
    width: number,
    height: number,
    session: EditSession,
    isStale: () => boolean,
    pooledOutput: Uint8ClampedArray,
  ): Promise<GeometryResult> {
    input = transformGeometry(input, width, height, session.geometry,
      session.imageWidth, session.imageHeight);
    const map = buildGeometryMap(session.geometry, width, height, {
      width: width, height: height,
      cropLeft: session.cropLeft, cropTop: session.cropTop,
      cropRight: session.cropRight, cropBottom: session.cropBottom,
      rotation: session.rotation, flipH: session.flipH, flipV: session.flipV,
    }, {
      referenceWidth: Math.max(1, Math.round(session.imageWidth)),
      referenceHeight: Math.max(1, Math.round(session.imageHeight)),
    });
    const outputWidth = map.outputWidth;
    const outputHeight = map.outputHeight;
    const table = buildFrameSampleTable(map);
    return new Promise<GeometryResult>((resolve) => {
      // 写入池中缓冲（尺寸足够时零分配），交付时复制一份精确长度的结果。
      const needed = outputWidth * outputHeight * 4;
      const output = pooledOutput.length >= needed ? pooledOutput : new Uint8ClampedArray(needed);
      let y = 0;

      const finish = (): void => {
        resolve({
          pixels: new Uint8ClampedArray(output.subarray(0, needed)),
          width: outputWidth,
          height: outputHeight,
        });
      };

      const step = (): void => {
        if (isStale()) {
          finish();
          return;
        }
        const yEnd = Math.min(outputHeight, y + GEOMETRY_ROWS_PER_SLICE);
        for (; y < yEnd; y++) {
          for (let x = 0; x < outputWidth; x++) {
            const cropX = table.x[y * outputWidth + x];
            if (cropX < 0) continue;
            const cropY = table.y[x * outputHeight + y];
            const sourceIndex = ((map.top + cropY) * width + map.left + cropX) * 4;
            const destinationIndex = (y * outputWidth + x) * 4;
            output[destinationIndex] = input[sourceIndex];
            output[destinationIndex + 1] = input[sourceIndex + 1];
            output[destinationIndex + 2] = input[sourceIndex + 2];
            output[destinationIndex + 3] = input[sourceIndex + 3];
          }
        }
        if (y >= outputHeight) {
          finish();
          return;
        }
        setTimeout(step, 0);
      };
      setTimeout(step, 0);
    });
  }

  /** Apply one band of one layer: matrix, advanced adjustments, then composite. */
  private static applyLayerBand(
    result: Uint8ClampedArray,
    pipeline: LayerPipeline,
    start: number,
    end: number,
  ): void {
    const base = pipeline.base;
    if (pipeline.matrix) {
      ImageProcessor.applyMatrixBand(base, pipeline.matrix, pipeline.adjusted, start, end);
    } else {
      pipeline.adjusted.set(base.subarray(start, end), start);
    }
    if (pipeline.hasAdvanced) {
      if (!pipeline.advancedTables) pipeline.advancedTables = prepareAdvancedTables(pipeline.workerAdjustments);
      ImageProcessor.applyAdvancedBand(pipeline.adjusted, pipeline.workerAdjustments, start, end, pipeline.width, pipeline.height,
        pipeline.advancedTables);
    }

    // Mask-scoped adjustments: blend the mask-adjusted pixels into the
    // adjusted buffer where the mask is opaque, before compositing.
    if (pipeline.hasMaskAdjustments && pipeline.mask) {
      if (pipeline.maskMatrix) {
        ImageProcessor.applyMatrixBand(pipeline.adjusted, pipeline.maskMatrix, pipeline.maskAdjusted, start, end);
      } else {
        pipeline.maskAdjusted.set(pipeline.adjusted.subarray(start, end), start);
      }
      if (pipeline.maskAdjustments.hasAdvancedAdjustments()) {
        if (!pipeline.maskAdvancedTables) pipeline.maskAdvancedTables = prepareAdvancedTables(pipeline.workerMaskAdjustments);
        ImageProcessor.applyAdvancedBand(pipeline.maskAdjusted, pipeline.workerMaskAdjustments, start, end, pipeline.width, pipeline.height,
          pipeline.maskAdvancedTables);
      }
      const mask = pipeline.mask;
      const adjusted = pipeline.adjusted;
      const maskAdjusted = pipeline.maskAdjusted;
      for (let i = start; i < end; i += 4) {
        const maskAlpha = mask[i >> 2] / 255;
        if (maskAlpha <= 0) continue;
        adjusted[i] = ImageProcessor.clamp(adjusted[i] + (maskAdjusted[i] - adjusted[i]) * maskAlpha);
        adjusted[i + 1] = ImageProcessor.clamp(adjusted[i + 1] + (maskAdjusted[i + 1] - adjusted[i + 1]) * maskAlpha);
        adjusted[i + 2] = ImageProcessor.clamp(adjusted[i + 2] + (maskAdjusted[i + 2] - adjusted[i + 2]) * maskAlpha);
      }
    }

    // Composite: result = blend(adjusted, result, mask, opacity, blendMode)
    ImageProcessor.compositeBand(result, base, pipeline.adjusted, pipeline.hasMaskAdjustments ? null : pipeline.mask, pipeline.opacity, pipeline.blendMode,
      start, end);
  }

  /** Delegate the fallback to the same pure-worker implementation as TaskPool. */
  private static applyAdvancedBand(
    input: Uint8ClampedArray,
    adj: WorkerAdjustments,
    start: number,
    end: number,
    width: number,
    height: number,
    prepared?: WorkerAdvancedTables,
  ): void {
    applyWorkerAdvancedBand(input, adj, start, end, width, height, undefined, 0, prepared);
  }
  private static hasMixerAdjustments(adj: ColorAdjustments): boolean {
    for (let index = 0; index < 8; index++) {
      if (adj.mixHue[index] !== 0 || adj.mixSaturation[index] !== 0 || adj.mixLuminance[index] !== 0) {
        return true;
      }
    }
    return false;
  }

  private static hasCalibrationAdjustments(adj: ColorAdjustments): boolean {
    return adj.calibrationRedHue !== 0 || adj.calibrationRedSaturation !== 0 ||
      adj.calibrationGreenHue !== 0 || adj.calibrationGreenSaturation !== 0 ||
      adj.calibrationBlueHue !== 0 || adj.calibrationBlueSaturation !== 0;
  }

  private static hasColorGradingAdjustments(adj: ColorAdjustments): boolean {
    return adj.colorGradingEnabled && (adj.gradingShadowsHue !== 0 || adj.gradingShadowsSaturation !== 0 ||
      adj.gradingShadowsLuminance !== 0 || adj.gradingMidtonesHue !== 0 ||
      adj.gradingMidtonesSaturation !== 0 || adj.gradingMidtonesLuminance !== 0 ||
      adj.gradingHighlightsHue !== 0 || adj.gradingHighlightsSaturation !== 0 ||
      adj.gradingHighlightsLuminance !== 0 || adj.gradingGlobalHue !== 0 ||
      adj.gradingGlobalSaturation !== 0 || adj.gradingGlobalLuminance !== 0 ||
      adj.gradingBlending !== 0 || adj.gradingBalance !== 0);
  }

  private static prepareGradingPalette(adj: ColorAdjustments): GradePalette {
    return {
      shadows: ImageProcessor.hslToRgb(ImageProcessor.wrap01(adj.gradingShadowsHue / 360),
        ImageProcessor.clamp01(adj.gradingShadowsSaturation), 0.5),
      midtones: ImageProcessor.hslToRgb(ImageProcessor.wrap01(adj.gradingMidtonesHue / 360),
        ImageProcessor.clamp01(adj.gradingMidtonesSaturation), 0.5),
      highlights: ImageProcessor.hslToRgb(ImageProcessor.wrap01(adj.gradingHighlightsHue / 360),
        ImageProcessor.clamp01(adj.gradingHighlightsSaturation), 0.5),
      global: ImageProcessor.hslToRgb(ImageProcessor.wrap01(adj.gradingGlobalHue / 360),
        ImageProcessor.clamp01(adj.gradingGlobalSaturation), 0.5),
    };
  }

  /** Apply one grading channel without creating an intermediate RGB array. */
  private static applyGradeChannel(value: number, target: number, saturation: number,
    luminance: number, weight: number): number {
    if (weight <= 0 || (saturation === 0 && luminance === 0)) return value;
    const tintAmount = ImageProcessor.clamp01(Math.abs(saturation) * weight * 0.62);
    const direction = saturation < 0 ? -1 : 1;
    const tinted = value + (target - value) * tintAmount * direction;
    const lift = luminance * weight * 0.28;
    return ImageProcessor.clamp01(tinted + lift);
  }

  /** Sort curve anchors once and decide between scalar and smooth evaluation. */
  private static prepareCurve(points: CurveAnchor[], amount: number, channelCurve: boolean): PreparedCurve {
    if (!points || points.length < 2) {
      const ordered = [new CurveAnchor(0, 0), new CurveAnchor(1, 1)];
      return {
        points: ordered,
        samples: ImageProcessor.sampleCurve(ordered),
        amount: amount,
        channelCurve: channelCurve,
        useScalar: true,
      };
    }
    // Identity curves may have two endpoints or additional collinear anchors.
    let identity = points.length >= 2 && points[0].x === 0 && points[points.length - 1].x === 1;
    for (let index = 0; identity && index < points.length; index++) {
      identity = Math.abs(points[index].x - points[index].y) < 0.0005 &&
        (index === 0 || points[index].x > points[index - 1].x);
    }
    const ordered = points.slice().sort((left: CurveAnchor, right: CurveAnchor) => left.x - right.x);
    return {
      points: ordered,
      samples: ImageProcessor.sampleCurve(ordered),
      amount: amount,
      channelCurve: channelCurve,
      useScalar: identity && amount !== 0,
    };
  }

  /** Pre-compute a 1025-entry table of the smooth curve for O(1) evaluation. */
  private static sampleCurve(points: CurveAnchor[]): number[] {
    const samples: number[] = new Array<number>(1025);
    for (let index = 0; index <= 1024; index++) {
      samples[index] = ImageProcessor.clamp01(smoothCurveY(points, index / 1024));
    }
    return samples;
  }

  /** Smooth-curve evaluation over a prepared curve; never allocates. */
  private static evalPreparedCurve(curve: PreparedCurve, value: number): number {
    const safeValue = ImageProcessor.clamp01(value);
    if (curve.useScalar) {
      return curve.channelCurve
        ? ImageProcessor.applyChannelCurve(safeValue, curve.amount)
        : ImageProcessor.applyToneCurve(safeValue, curve.amount);
    }
    const position = safeValue * 1024;
    const low = position >= 1024 ? 1023 : Math.floor(position);
    const frac = position - low;
    return ImageProcessor.clamp01(curve.samples[low] + (curve.samples[low + 1] - curve.samples[low]) * frac);
  }

  /** 256-entry byte→byte lookup table for a curve; exact for byte inputs. */
  private static buildCurveLut(points: CurveAnchor[], amount: number, channelCurve: boolean): Uint8ClampedArray {
    const lut = new Uint8ClampedArray(256);
    const curve = ImageProcessor.prepareCurve(points, amount, channelCurve);
    for (let value = 0; value < 256; value++) {
      lut[value] = ImageProcessor.clamp(ImageProcessor.evalPreparedCurve(curve, value / 255) * 255);
    }
    return lut;
  }

  private static applyToneCurve(value: number, amount: number): number {
    const x = ImageProcessor.clamp01(value);
    if (amount >= 0) {
      const smooth = x * x * (3 - 2 * x);
      return ImageProcessor.clamp01(x + (smooth - x) * amount);
    }
    const flat = 0.18 + x * 0.64;
    return ImageProcessor.clamp01(x + (flat - x) * -amount);
  }

  private static applyChannelCurve(value: number, amount: number): number {
    if (amount === 0) return ImageProcessor.clamp01(value);
    const gamma = Math.pow(2, -amount * 1.25);
    return ImageProcessor.clamp01(Math.pow(ImageProcessor.clamp01(value), gamma));
  }

  private static rgbToHsl(red: number, green: number, blue: number): number[] {
    const r = ImageProcessor.clamp01(red);
    const g = ImageProcessor.clamp01(green);
    const b = ImageProcessor.clamp01(blue);
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const lightness = (max + min) / 2;
    const delta = max - min;
    if (delta === 0) return [0, 0, lightness];
    const saturation = delta / (1 - Math.abs(2 * lightness - 1));
    let hue = 0;
    if (max === r) hue = ((g - b) / delta) % 6;
    else if (max === g) hue = (b - r) / delta + 2;
    else hue = (r - g) / delta + 4;
    hue /= 6;
    return [ImageProcessor.wrap01(hue), saturation, lightness];
  }

  private static hslToRgb(hue: number, saturation: number, lightness: number): number[] {
    const c = (1 - Math.abs(2 * lightness - 1)) * saturation;
    const hp = hue * 6;
    const x = c * (1 - Math.abs((hp % 2) - 1));
    let r1 = 0;
    let g1 = 0;
    let b1 = 0;
    if (hp < 1) { r1 = c; g1 = x; }
    else if (hp < 2) { r1 = x; g1 = c; }
    else if (hp < 3) { g1 = c; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = c; }
    else if (hp < 5) { r1 = x; b1 = c; }
    else { r1 = c; b1 = x; }
    const m = lightness - c / 2;
    return [r1 + m, g1 + m, b1 + m];
  }

  private static clamp01(value: number): number {
    return Math.max(0, Math.min(1, value));
  }

  private static wrap01(value: number): number {
    return ((value % 1) + 1) % 1;
  }

  private static applyMatrixBand(
    input: Uint8ClampedArray,
    matrix: Float32Array,
    output: Uint8ClampedArray,
    start: number,
    end: number,
  ): void {
    const a = matrix[0];
    const b = matrix[1];
    const c = matrix[2];
    const d = matrix[3];
    const e = matrix[4];
    const f = matrix[5];
    const g = matrix[6];
    const h = matrix[7];
    const i = matrix[8];
    const j = matrix[9];
    const k = matrix[10];
    const l = matrix[11];
    const m = matrix[12];
    const n = matrix[13];
    const o = matrix[14];
    const p = matrix[15];
    const q = matrix[16];
    const r = matrix[17];
    const s = matrix[18];
    const t = matrix[19];

    for (let idx = start; idx < end; idx += 4) {
      const R = input[idx];
      const G = input[idx + 1];
      const B = input[idx + 2];
      const A = input[idx + 3];

      output[idx] = ImageProcessor.clamp(a * R + b * G + c * B + d * A + e);
      output[idx + 1] = ImageProcessor.clamp(f * R + g * G + h * B + i * A + j);
      output[idx + 2] = ImageProcessor.clamp(k * R + l * G + m * B + n * A + o);
      output[idx + 3] = ImageProcessor.clamp(p * R + q * G + r * B + s * A + t);
    }
  }

  private static compositeBand(
    result: Uint8ClampedArray,
    base: Uint8ClampedArray,
    adjusted: Uint8ClampedArray,
    mask: Uint8ClampedArray | null,
    opacity: number,
    blendMode: BlendMode,
    start: number,
    end: number,
  ): void {
    for (let i = start; i < end; i += 4) {
      const maskAlpha = mask ? mask[i >> 2] / 255 : 1.0;
      const effectiveAlpha = maskAlpha * opacity;

      if (effectiveAlpha <= 0) continue;

      const srcR = adjusted[i];
      const srcG = adjusted[i + 1];
      const srcB = adjusted[i + 2];
      const baseR = base[i];
      const baseG = base[i + 1];
      const baseB = base[i + 2];

      let blendedR: number, blendedG: number, blendedB: number;

      switch (blendMode) {
        case BlendMode.NORMAL:
          blendedR = srcR;
          blendedG = srcG;
          blendedB = srcB;
          break;
        case BlendMode.MULTIPLY:
          blendedR = (baseR * srcR) / 255;
          blendedG = (baseG * srcG) / 255;
          blendedB = (baseB * srcB) / 255;
          break;
        case BlendMode.SCREEN:
          blendedR = 255 - ((255 - baseR) * (255 - srcR)) / 255;
          blendedG = 255 - ((255 - baseG) * (255 - srcG)) / 255;
          blendedB = 255 - ((255 - baseB) * (255 - srcB)) / 255;
          break;
        case BlendMode.OVERLAY:
          blendedR = ImageProcessor.overlay(baseR, srcR);
          blendedG = ImageProcessor.overlay(baseG, srcG);
          blendedB = ImageProcessor.overlay(baseB, srcB);
          break;
        default:
          blendedR = srcR;
          blendedG = srcG;
          blendedB = srcB;
      }

      if (effectiveAlpha >= 1) {
        result[i] = ImageProcessor.clamp(blendedR);
        result[i + 1] = ImageProcessor.clamp(blendedG);
        result[i + 2] = ImageProcessor.clamp(blendedB);
      } else {
        result[i] = ImageProcessor.clamp(result[i] + (blendedR - result[i]) * effectiveAlpha);
        result[i + 1] = ImageProcessor.clamp(result[i + 1] + (blendedG - result[i + 1]) * effectiveAlpha);
        result[i + 2] = ImageProcessor.clamp(result[i + 2] + (blendedB - result[i + 2]) * effectiveAlpha);
      }
    }
  }

  private static overlay(base: number, blend: number): number {
    if (base < 128) {
      return (2 * base * blend) / 255;
    }
    return 255 - (2 * (255 - base) * (255 - blend)) / 255;
  }

  static clamp(v: number): number {
    return Math.max(0, Math.min(255, Math.round(v)));
  }

  static async readPixelsToBuffer(pixelMap: image.PixelMap): Promise<Uint8ClampedArray | null> {
    try {
      const info = await pixelMap.getImageInfo();
      const bufferSize = info.size.height * info.size.width * 4;
      const buffer = new ArrayBuffer(bufferSize);
      await pixelMap.readPixelsToBuffer(buffer);
      return new Uint8ClampedArray(buffer);
    } catch (_e) {
      return null;
    }
  }

  /**
   * 自动白平衡：按步长把源图抽样成约 512 长边的缩略像素，估计光源色，
   * 换算成色温 / 色调写进整帧调整。返回 false 表示取不到可用的像素。
   *
   * 抽样后统计量与分辨率无关，一次点击的成本固定在几十毫秒量级。
   */
  static async autoWhiteBalance(session: EditSession): Promise<boolean> {
    const source = session.sourcePixelMap;
    if (source === null) return false;
    const info = await source.getImageInfo();
    const width = info.size.width;
    const height = info.size.height;
    if (width <= 0 || height <= 0) return false;
    const pixels = await ImageProcessor.readPixelsToBuffer(source);
    if (pixels === null) return false;
    const step = Math.max(1, Math.ceil(Math.max(width, height) / 512));
    const sampleWidth = Math.max(1, Math.floor(width / step));
    const sampleHeight = Math.max(1, Math.floor(height / step));
    const sample = new Uint8ClampedArray(sampleWidth * sampleHeight * 4);
    for (let y = 0; y < sampleHeight; y++) {
      const rowOffset = y * step * width;
      for (let x = 0; x < sampleWidth; x++) {
        const from = (rowOffset + x * step) * 4;
        const to = (y * sampleWidth + x) * 4;
        sample[to] = pixels[from];
        sample[to + 1] = pixels[from + 1];
        sample[to + 2] = pixels[from + 2];
        sample[to + 3] = 255;
      }
    }
    const light = WhiteBalance.estimateLight(sample, sampleWidth, sampleHeight);
    const pair = WhiteBalance.toTemperatureTint(light);
    const adj = session.adjustmentsForContext(false);
    if (adj === null) return false;
    // 估算成功后才记撤销点，避免失败时留下一个空步。
    session.pushUndo();
    adj.temperature = pair[0];
    adj.tint = pair[1];
    session.invalidateMaskCache();
    session.bumpProcessing();
    console.info(`VIVID_PERF event=auto_wb light=${light.map((v: number): string =>
      Math.round(v).toString()).join(',')} t=${pair[0].toFixed(3)} tint=${pair[1].toFixed(3)}`);
    return true;
  }

  /** 手动白平衡的源图像素缓存：一次拖拽只读一遍源图，换图时失效。 */
  private static wbPickSource: image.PixelMap | null = null;
  private static wbPickWidth: number = 0;
  private static wbPickHeight: number = 0;
  private static wbPickPixels: Uint8ClampedArray | null = null;

  private static async whiteBalancePixels(session: EditSession): Promise<Uint8ClampedArray | null> {
    const source = session.sourcePixelMap;
    if (source === null) return null;
    if (ImageProcessor.wbPickSource === source && ImageProcessor.wbPickPixels !== null) {
      return ImageProcessor.wbPickPixels;
    }
    const info = await source.getImageInfo();
    const width = info.size.width;
    const height = info.size.height;
    if (width <= 0 || height <= 0) return null;
    const buffer = new ArrayBuffer(width * height * 4);
    try {
      await source.readPixelsToBuffer(buffer);
    } catch (_error) {
      return null;
    }
    ImageProcessor.wbPickSource = source;
    ImageProcessor.wbPickWidth = width;
    ImageProcessor.wbPickHeight = height;
    ImageProcessor.wbPickPixels = new Uint8ClampedArray(buffer);
    return ImageProcessor.wbPickPixels;
  }

  /**
   * 手动白平衡取点：在归一化源坐标处取一小块区域（约 0.5% 短边半径），
   * 丢掉剪高光和死黑后做线性光平均，解出 temperature/tint 写入整帧调整。
   *
   * 撤销点由调用方（面板按下「手动」时）记录，拖拽过程中的连续取点不再入栈，
   * 否则一次拖拽会压入上百步撤销。
   */
  static async pickWhiteBalanceAt(session: EditSession,
    sourceX: number, sourceY: number): Promise<boolean> {
    if (!Number.isFinite(sourceX) || !Number.isFinite(sourceY)) return false;
    if (sourceX < 0 || sourceX > 1 || sourceY < 0 || sourceY > 1) return false;
    const pixels = await ImageProcessor.whiteBalancePixels(session);
    if (pixels === null) return false;
    const width = ImageProcessor.wbPickWidth;
    const height = ImageProcessor.wbPickHeight;
    const adj = session.adjustmentsForContext(false);
    if (adj === null) return false;
    const centerX = Math.round(sourceX * width);
    const centerY = Math.round(sourceY * height);
    const radius = Math.max(3, Math.round(Math.min(width, height) * 0.005));
    const picked: WbPickResult = pickRegion(pixels, width, height,
      centerX - radius, centerY - radius, centerX + radius, centerY + radius);
    if (!picked.ok) {
      console.info(`VIVID_PERF event=wb_pick_failed reason=${picked.reason} ` +
        `visited=${picked.visited} accepted=${picked.accepted}`);
      return false;
    }
    adj.temperature = picked.temperature;
    adj.tint = picked.tint;
    session.invalidateMaskCache();
    session.bumpProcessing();
    console.info(`VIVID_PERF event=wb_pick t=${picked.temperature.toFixed(3)} ` +
      `tint=${picked.tint.toFixed(3)} accepted=${picked.accepted} residual=${picked.residual.toFixed(3)}`);
    return true;
  }

  static async createPixelMapFromBuffer(
    buffer: Uint8ClampedArray,
    width: number,
    height: number,
  ): Promise<image.PixelMap | null> {
    try {
      PerfStats.recordPixelMapCreate();
      const opts: image.InitializationOptions = {
        editable: true,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        size: { width, height },
      };
      const colors = new ArrayBuffer(width * height * 4);
      const pm = await image.createPixelMap(colors, opts);
      await pm.writeBufferToPixels(buffer.buffer as ArrayBuffer);
      return pm;
    } catch (_e) {
      return null;
    }
  }
}
