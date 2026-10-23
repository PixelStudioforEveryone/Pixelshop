import { taskpool } from '@kit.ArkTS';
import { SpatialEffectSettings } from './SpatialEffects';
import { DenoiseValues } from '../models/DenoiseSettings';
import { denoiseEnabled, denoiseRows } from './NoiseReduction';
import { LocalContrastParams, applyLocalContrast, localContrastIsIdentity } from './LocalContrastCore';
import { OpticsParams, applyOptics, opticsIsIdentity } from './OpticsCore';
import { PointColorSample, pointColorIsIdentity } from './PointColorCore';
import { OkLChParams, oklchIsIdentity } from './OkLChCore';
import { BlackWhiteParams, blackWhiteBuffer, blackWhiteIsIdentity } from './BlackWhiteCore';
import { BokehValues } from '../models/BokehSettings';
import { renderBokeh } from './BokehNative';
import { ProcessBehaviors, processBehaviors, PROCESS_VERSION_LEGACY } from '../models/ProcessVersion';
import {
  WorkerPipeline,
  LayerPassTiming,
  buildMatrix,
  isIdentity,
  hasAdvancedAdjustments,
  renderMask,
  applyLayerBandFull,
  applyGeometryFull,
  applyPreparedLutStack,
  applyOkLChBuffer,
  applyPointColorBuffer,
  currentLutBuildCount,
  prepareLutStack,
  resetLutBuildCount,
} from './WorkerCore';
import { BandJobParams, BandJobResult, processExportBand } from './ExportBands';

export interface WorkerPoint {
  x: number;
  y: number;
  radius: number;
  hardness: number;
}

export interface WorkerStroke {
  mode: number;
  points: WorkerPoint[];
}

export interface WorkerMask {
  type: number;
  invert: boolean;
  feather: number;
  strokes: WorkerStroke[];
  linear: number[]; // [sx, sy, ex, ey, feather]
  radial: number[]; // [cx, cy, r, rx, ry, feather]
}

export interface WorkerAdjustments extends SpatialEffectSettings {
  exposure: number;
  contrast: number;
  brightness: number;
  highlights: number;
  shadows: number;
  whites: number;
  blacks: number;
  vignetteAmount: number;
  vignetteMidpoint: number;
  vignetteRoundness: number;
  vignetteFeather: number;
  vignetteHighlights: number;
  grainAmount: number;
  grainSize: number;
  grainRoughness: number;
  saturation: number;
  vibrance: number;
  temperature: number;
  tint: number;
  hue: number;
  toneCurve: number;
  curveRed: number;
  curveGreen: number;
  curveBlue: number;
  toneCurvePoints: number[][];
  redCurvePoints: number[][];
  greenCurvePoints: number[][];
  blueCurvePoints: number[][];
  parametricHighlights: number;
  parametricLights: number;
  parametricDarks: number;
  parametricShadows: number;
  parametricShadowSplit: number;
  parametricDarkSplit: number;
  parametricLightSplit: number;
  parametricRefineSaturation: number;
  mixHue: number[];
  mixSaturation: number[];
  mixLuminance: number[];
  calibrationRedHue: number;
  calibrationRedSaturation: number;
  calibrationGreenHue: number;
  calibrationGreenSaturation: number;
  calibrationBlueHue: number;
  calibrationBlueSaturation: number;
  colorGradingEnabled: boolean;
  gradingShadowsHue: number;
  gradingShadowsSaturation: number;
  gradingShadowsLuminance: number;
  gradingMidtonesHue: number;
  gradingMidtonesSaturation: number;
  gradingMidtonesLuminance: number;
  gradingHighlightsHue: number;
  gradingHighlightsSaturation: number;
  gradingHighlightsLuminance: number;
  gradingGlobalHue: number;
  gradingGlobalSaturation: number;
  gradingGlobalLuminance: number;
  gradingBlending: number;
  gradingBalance: number;
}

export interface WorkerLayer {
  visible: boolean;
  opacity: number;
  blendMode: number;
  adjustments: WorkerAdjustments;
  maskAdjustments: WorkerAdjustments;
  mask: WorkerMask | null;
  // Structured mask layers are rendered to an alpha buffer on the UI side,
  // then sent with the rest of the pixel job so the expensive colour pass
  // stays in TaskPool instead of blocking the ArkUI thread.
  maskBuffer: ArrayBuffer | null;
}

export interface WorkerLut {
  enabled: boolean;
  intensity: number;
  size: number;
  values: number[];
  domainMin: number[];
  domainMax: number[];
}

export interface ProcessParams {
  denoise?: DenoiseValues;
  /** Global detail stage (texture/clarity/dehaze/sharpen). Omitted or all-zero
   * means the stage is skipped entirely, so older jobs cost nothing. Typed with
   * the engine's own parameter interface so the worker can consume it directly
   * and there is exactly one definition of the stage's parameters. */
  detail?: LocalContrastParams;
  /**
   * 整帧雾色（[r,g,b]，0..1），只在渲染放大瓦片时提供。
   *
   * 去朦胧的雾色是整帧统计量：瓦片里自算会得到不同的值，放大后的效果就和整帧对不上。
   * lightcraft 为此把整帧 airlight 显式带进窗口渲染；这里同样由调用方把整帧算出的
   * 雾色传进来。空数组表示就地估计（全帧渲染的正常情况）。
   */
  detailHaze?: number[];
  /** Lens corrections (distortion/CA/defringe/vignetting). Omitted or all-zero
   * means the stage is skipped entirely. Typed with the engine's own parameter
   * interface so the worker consumes it directly. */
  optics?: OpticsParams;
  /**
   * 大光圈模拟参数。关闭或未提供时整段跳过；深度图与源帧同坐标，
   * 因此必须在本阶段之后才做裁剪/旋转。
   */
  bokeh?: BokehValues;
  bokehDepth?: ArrayBuffer | null;
  bokehDepthWidth?: number;
  bokehDepthHeight?: number;
  /** Point colour samples. Omitted, empty or all-zero means the stage is skipped.
   *  Typed with the engine's own sample interface, which is also what the document
   *  model stores, so no conversion is needed between them. */
  pointColor?: PointColorSample[];
  oklch?: OkLChParams;
  blackWhite?: BlackWhiteParams;
  /** Algorithm generation for this photo; see models/ProcessVersion.ets.
   * Omitted means LEGACY-resolved-by-normalisation, i.e. the conservative
   * choice for any job that predates the field. */
  processVersion?: number;
  viewport?: number[];
  geometry?: number[];
  source: ArrayBuffer;
  width: number;
  height: number;
  /** Source-frame dimensions the manual geometry controls were authored
   * against. The interactive preview renders a bounded downsample, so the
   * perspective term must be rescaled or export would not match the preview. */
  referenceWidth?: number;
  referenceHeight?: number;
  layers: WorkerLayer[];
  luts: WorkerLut[];
  cropLeft: number;
  cropTop: number;
  cropRight: number;
  cropBottom: number;
  rotation: number;
  flipH: boolean;
  flipV: boolean;
  applyGeometry: boolean;
  ignoreCrop: boolean;
  /**
   * 只做手动几何变换，把裁剪/旋转/翻转的整数重映射留给主线程的 native 实现
   * （vivid_pixels.remapGeometry）。ArkTS 版本需要先构造两张 Int32 采样表再
   * 逐像素查表，44MP 实测 33~35 秒；主线程会用同一个 geometryMapForParams
   * 重建 map，因此两条路径的边界与结果完全一致。
   */
  deferRemap?: boolean;
}

export interface ProcessResult {
  buffer: ArrayBuffer;
  width: number;
  height: number;
}

export interface GeometryTaskParams {
  source: ArrayBuffer;
  width: number;
  height: number;
  cropLeft: number;
  cropTop: number;
  cropRight: number;
  cropBottom: number;
  rotation: number;
  flipH: boolean;
  flipV: boolean;
}

/**
 * TaskPool 后台像素管线入口。辅助实现全部来自 WorkerCore 模块
 * （@Concurrent 函数只允许引用 import 变量与自身局部变量）。
 */
@Concurrent
export function processPixels(params: ProcessParams): ProcessResult {
  if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
  const width = params.width;
  const height = params.height;
  // 分阶段计时：这是看清一次 44MP CPU 导出把 30~85 秒花在哪里的唯一窗口，
  // 也是把这些阶段逐块搬进 native 的施工清单。
  let stageClock = Date.now();
  const stages: string[] = [];
  const markStage = (name: string): void => {
    const now = Date.now();
    stages.push(`${name}=${now - stageClock}`);
    stageClock = now;
  };
  let masksProvided = 0;
  let masksRendered = 0;
  // 图层管线分趟计时：带蒙版的局部调整会把整幅图走四遍，每趟都是逐像素循环。
  const passTiming: LayerPassTiming = { adjust: 0, maskAdjust: 0, maskBlend: 0, composite: 0 };
  let result = new Uint8ClampedArray(params.source);
  if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0 ||
    result.length !== width * height * 4) throw new Error('Invalid RGBA worker dimensions');
  if (denoiseEnabled(params.denoise) && params.denoise) {
    const filtered = new Uint8ClampedArray(result.length);
    // Resolved once per job, from the behaviour table rather than from a
    // version number, so this file stays free of generation branching.
    const behaviors: ProcessBehaviors = processBehaviors(params.processVersion ?? PROCESS_VERSION_LEGACY);
    denoiseRows(result, filtered, width, height, params.denoise, 0, height, true,
      behaviors.denoiseFixedRadius);
    result = filtered;
  }
  markStage('denoise');
  const bandBytes = Math.min(result.length, 32768 * 4);
  const scratchBase = new Uint8ClampedArray(bandBytes);
  const scratchAdjusted = new Uint8ClampedArray(bandBytes);
  const scratchMaskAdjusted = new Uint8ClampedArray(bandBytes);

  const pipelines: WorkerPipeline[] = [];
  for (const layer of params.layers) {
    if (!layer.visible || layer.opacity <= 0) continue;
    const matrix = buildMatrix(layer.adjustments);
    const hasMatrix = !isIdentity(matrix);
    const hasAdvanced = hasAdvancedAdjustments(layer.adjustments);
    if (!hasMatrix && !hasAdvanced && !layer.mask) continue;
    let maskBuffer: Uint8ClampedArray | null = null;
    if (layer.maskBuffer) {
      maskBuffer = new Uint8ClampedArray(layer.maskBuffer);
      masksProvided++;
    } else if (layer.mask) {
      // Worker 自己重渲蒙版是慢路径：ArkTS 栅格化约 0.4µs/像素（44MP = 18.9 秒），
      // 全分辨率导出绝不该走到这里，所以单独计数。
      maskBuffer = renderMask(layer.mask, width, height);
      masksRendered++;
    }
    const maskMatrix = buildMatrix(layer.maskAdjustments);
    const hasMaskMatrix = !isIdentity(maskMatrix);
    const hasMaskAdjustments = hasMaskMatrix || hasAdvancedAdjustments(layer.maskAdjustments);
    // One independent scratch triplet is shared by serial bands/layers.
    // Views of result cannot serve as base/adjusted: writes would destroy
    // the original values required by opacity, masks and blend modes.
    const base = scratchBase;
    const adjusted = scratchAdjusted;
    const maskAdjusted = scratchMaskAdjusted;
    pipelines.push({
      adjustments: layer.adjustments,
      matrix: hasMatrix ? matrix : null,
      hasAdvanced: hasAdvanced,
      opacity: layer.opacity,
      blendMode: layer.blendMode,
      mask: maskBuffer,
      base: base,
      adjusted: adjusted,
      maskAdjustments: layer.maskAdjustments,
      maskMatrix: hasMaskMatrix ? maskMatrix : null,
      hasMaskAdjustments: hasMaskAdjustments && maskBuffer !== null,
      maskAdjusted: maskAdjusted,
      width: width,
      height: height,
      viewport: params.viewport,
      bandCache: {},
    });
  }
  markStage('build');

  for (const pipeline of pipelines) {
    for (let start = 0; start < result.length; start += bandBytes) {
      if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
      const end = Math.min(result.length, start + bandBytes);
      const band = result.subarray(start, end);
      pipeline.pixelOffset = start / 4;
      pipeline.base.set(band);
      applyLayerBandFull(band, pipeline, 0, band.length, passTiming);
    }
  }
  markStage('layers');

  // LUTs can dominate a CPU frame too. Check cancellation between bounded
  // bands instead of running an uninterruptible full-image JS loop.
  //
  // The native payload is prepared ONCE, before the band loop. Building it per
  // band was the 2048x1644 regression: 103 bands meant 103 copies of an 862 KB
  // Float64 table (and, when native was refused, 103 ArkTS reference loops).
  resetLutBuildCount();
  const lutStageStart = Date.now();
  const lutBands = Math.ceil(result.length / bandBytes);
  const preparedLuts = prepareLutStack(params.luts);
  const lutBuildMs = Date.now() - lutStageStart;
  for (let start = 0; start < result.length; start += bandBytes) {
    if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
    applyPreparedLutStack(result.subarray(start, Math.min(result.length, start + bandBytes)), preparedLuts);
  }
  // `builds=1` is the target: the native payload is built once for the whole
  // frame. A value equal to `bands` means it was rebuilt for every band, which
  // is exactly the per-band cost this log exists to expose. Only LUT frames are
  // logged: the cpu-stages line already covers every frame, and zooming emits
  // many frames per second.
  if (params.luts.length > 0) {
    console.info(`VIVID_EDIT_PERF stage=lut-build builds=${currentLutBuildCount()} bands=${lutBands}` +
      ` buildMs=${lutBuildMs} ms=${Date.now() - lutStageStart} luts=${preparedLuts.active.length}`);
  }
  markStage('luts');

  // Point colour. A per-pixel colour transform, so it runs after the LUT stack (it
  // grades the graded image, the order Camera Raw uses) and BEFORE the detail
  // stage, so sharpening and structure shape the final colour instead of being
  // re-graded afterwards. Applied in place through the engine's buffer entry point,
  // which reuses one scratch array for the whole frame rather than allocating per
  // pixel. It is a pointwise op, so unlike detail it needs no full-frame
  // neighbourhood and could not show band seams.
  if (params.pointColor && params.pointColor.length > 0 &&
    !pointColorIsIdentity(params.pointColor)) {
    if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
    applyPointColorBuffer(result, width, height, params.pointColor);
  }
  markStage('pointColor');

  // OkLCh grade, after the LUT stack and after point colour, still before detail. It is
  // a global perceptual adjustment, so it sits downstream of the targeted per-colour
  // work: boosting chroma AFTER a targeted hue shift cannot undo that shift, whereas
  // doing it first would move the colours the targeted stage was aiming at. Bypassed, it
  // costs nothing at all.
  if (params.oklch && !oklchIsIdentity(params.oklch)) {
    if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
    applyOkLChBuffer(result, width, height, params.oklch);
  }
  markStage('oklch');

  // Black-and-white conversion is NOT here. It runs LAST, after optics; see below.

  // Global detail stage. It runs on the WHOLE frame at once, deliberately not in
  // bands: every one of its four effects is a neighbourhood operation, so a
  // band-local blur would differ from a full-frame one and make band seams
  // visible in an export. Placed after the LUT stack (so it shapes the graded
  // image) and before geometry (so it acts on real pixels, not on the
  // resampled/cropped result). Omitted or all-zero detail costs nothing.
  if (params.detail) {
    const detail: LocalContrastParams = params.detail;
    if (!localContrastIsIdentity(detail)) {
      if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
      result = applyLocalContrast(result, width, height, detail, Math.max(width, height),
        params.detailHaze ?? []);
    }
  }
  markStage('detail');

  // Global lens corrections, in the same full-frame position and for the same
  // reason as the detail stage. They run AFTER the layer/mask stages on purpose:
  // masks and retouch marks are authored in source space, so the correction has
  // to carry their pixels along with the content rather than be applied beneath
  // them. They run BEFORE geometry, because a lens correction belongs to the
  // capture and the crop/rotate is a framing decision made afterwards.
  if (params.optics) {
    const optics: OpticsParams = params.optics;
    if (!opticsIsIdentity(optics)) {
      if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
      result = applyOptics(result, width, height, optics);
    }
  }
  markStage('optics');

  // Black-and-white conversion, LAST among the colour stages and immediately before
  // geometry.
  //
  // Placed here rather than before detail for two reasons that both come from the same
  // requirement -- that a frame with this stage on is EXACTLY neutral:
  //   * optics runs before it, and chromatic-aberration correction scales the red and
  //     blue channels independently. A conversion placed before optics would hand that
  //     stage a neutral frame and get a TINTED one back, breaking the guarantee.
  //   * the mixer decides how the final colours become grey, so running it last means it
  //     sees the fully graded and corrected colour, which is the colour the user sees.
  // Bypassed, it costs nothing.
  if (params.blackWhite && !blackWhiteIsIdentity(params.blackWhite)) {
    if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
    blackWhiteBuffer(result, width, height, params.blackWhite);
  }
  markStage('bw');

  // 大光圈模拟：在全部颜色/镜头校正之后、几何裁剪之前。
  // 放在这里的原因与光学一致——远景虚化属于成像，裁剪/旋转是之后的取景决定；
  // 深度图也与未裁剪的像素坐标一一对应。
  if (params.bokeh && params.bokeh.enabled) {
    if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
    const bokehSource = result.byteOffset === 0 && result.byteLength === result.buffer.byteLength
      ? result.buffer as ArrayBuffer : result.slice().buffer as ArrayBuffer;
    const bokeh = renderBokeh(bokehSource, width, height,
      params.bokehDepth ?? null, params.bokehDepthWidth ?? 0, params.bokehDepthHeight ?? 0,
      params.bokeh);
    if (bokeh && bokeh.byteLength === result.length) {
      result = new Uint8ClampedArray(bokeh);
    } else {
      // 原生库不可用时保留已经渲染的调色结果，而不是让整帧变黑。
      console.error('VIVID_BOKEH native render returned no buffer');
    }
  }
  markStage('bokeh');

  let output = result;
  let outputWidth = width;
  let outputHeight = height;
  if (params.applyGeometry) {
    if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
    const geometry = applyGeometryFull(result, width, height, params);
    output = geometry.pixels;
    outputWidth = geometry.width;
    outputHeight = geometry.height;
  }
  markStage('geometry');

  // This source buffer belongs to this TaskPool job. Return it directly if
  // geometry produced a complete buffer; avoid one more full-frame copy.
  const outputBytes = outputWidth * outputHeight * 4;
  const buffer = output.byteOffset === 0 && output.byteLength === outputBytes &&
    output.buffer.byteLength === outputBytes ? output.buffer : output.slice(0, outputBytes).buffer;
  console.info(`VIVID_EDIT_PERF stage=cpu-stages ${stages.join(' ')}` +
    ` layers=${params.layers.length} pipelines=${pipelines.length}` +
    ` masks=${masksProvided}+${masksRendered}r bands=${Math.ceil(width * height * 4 / bandBytes)}` +
    ` luts=${params.luts.length} geo=${params.applyGeometry === true}`);
  console.info(`VIVID_EDIT_PERF stage=layer-passes adjust=${passTiming.adjust}` +
    ` maskAdjust=${passTiming.maskAdjust} maskBlend=${passTiming.maskBlend}` +
    ` composite=${passTiming.composite} pipelines=${pipelines.length}`);
  return { buffer: buffer as ArrayBuffer, width: outputWidth, height: outputHeight };
}

/**
 * 导出分带并行的一带。整帧的逐点/邻域工作被切成横带后，每个 TaskPool 任务
 * 跑这个入口；算法本身在 ExportBands.processExportBand（纯函数，可被 Node 对拍）。
 * 只返回该带的目标行，拼接由主线程完成。
 */
@Concurrent
export function processBandPixels(job: BandJobParams): BandJobResult {
  if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
  const result = processExportBand(job);
  console.info(`VIVID_POINTWISE top=${job.targetTop} rows=${job.targetRows}` +
    ` px=${result.targetRows * job.width} total=${result.totalMs}` +
    ` layers=${result.layersMs} matrix=${result.matrixMs} advanced=${result.advancedMs}` +
    ` maskMatrix=${result.maskMatrixMs} maskAdvanced=${result.maskAdvancedMs}` +
    ` maskBlend=${result.maskBlendMs} composite=${result.compositeMs}` +
    ` lut=${result.lutMs} pointColor=${result.pointColorMs} oklch=${result.oklchMs}` +
    ` copy=${result.copyMs}`);
  console.info(`VIVID_EDIT_PERF stage=export-band phase=${job.phase} top=${job.targetTop}` +
    ` rows=${job.targetRows} proc=${job.bandRows} total=${result.totalMs}` +
    ` layers=${result.layersMs} detail=${result.detailMs} optics=${result.opticsMs}` +
    ` adjust=${result.adjustMs} composite=${result.compositeMs}`);
  return result;
}

/**
 * 大光圈阶段单独一个 TaskPool 任务。
 *
 * 分带路径把逐点阶段切成横带，但景深虚化是整帧卷积：它必须在所有带拼接
 * 完成之后、几何裁剪之前执行一次，因此不能塞进 `processExportBand`。
 * 放到 TaskPool 里是因为 24MP 导出的光圈卷积可能持续数百毫秒到数秒，
 * 留在 UI 线程会直接卡住界面。
 */
@Concurrent
export function processBokehPixels(params: BokehJobParams): ProcessResult {
  if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
  if (!params.bokeh || !params.bokeh.enabled) {
    return { buffer: params.source, width: params.width, height: params.height };
  }
  const rendered = renderBokeh(params.source, params.width, params.height,
    params.depth, params.depthWidth, params.depthHeight, params.bokeh);
  return {
    buffer: rendered ?? params.source,
    width: params.width,
    height: params.height,
  };
}

export interface BokehJobParams {
  source: ArrayBuffer;
  width: number;
  height: number;
  depth: ArrayBuffer | null;
  depthWidth: number;
  depthHeight: number;
  bokeh: BokehValues;
}

/**
 * 分带导出的最后一段几何变换。与串行 worker 里的几何阶段是同一个
 * applyGeometryFull（含手动透视 geometry），只是单独成任务，避免原生
 * remapGeometry 不可用时把 44MP 的参考重映射留在 UI 线程。
 */
@Concurrent
export function processGeometryPixels(params: ProcessParams): ProcessResult {  if (taskpool.Task.isCanceled()) throw new Error('CPU_PREVIEW_CANCELLED');
  const geometry = applyGeometryFull(new Uint8ClampedArray(params.source),
    params.width, params.height, params);
  return {
    buffer: geometry.pixels.buffer as ArrayBuffer,
    width: geometry.width,
    height: geometry.height,
  };
}

/**
 * GPU 导出结果的几何后处理：裁剪/旋转/翻转在 TaskPool 内完成，
 * 复用 processPixels 同款 applyGeometryFull 实现。
 */
@Concurrent
export function applyGeometryTask(params: GeometryTaskParams): ProcessResult {
  const full: ProcessParams = {
    source: params.source,
    width: params.width,
    height: params.height,
    layers: [],
    luts: [],
    cropLeft: params.cropLeft,
    cropTop: params.cropTop,
    cropRight: params.cropRight,
    cropBottom: params.cropBottom,
    rotation: params.rotation,
    flipH: params.flipH,
    flipV: params.flipV,
    applyGeometry: true,
    ignoreCrop: false,
  };
  const geometry = applyGeometryFull(new Uint8ClampedArray(params.source),
    params.width, params.height, full);
  return {
    buffer: geometry.pixels.buffer as ArrayBuffer,
    width: geometry.width,
    height: geometry.height,
  };
}
