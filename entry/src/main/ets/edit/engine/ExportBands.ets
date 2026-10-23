/**
 * 导出按行分带并行的纯实现。
 *
 * 背景：44MP 导出的整个 CPU 管线原先跑在**一个** TaskPool 任务里（ProcessWorker 的
 * `processPixels`），`stage=cpu-stages` 实测 layers=11.7s、detail=9.9s，合计 21.6s。
 * 其中 11.7s 的图层/LUT/点颜色/OkLCh 全是**逐点**阶段，按行切带没有任何边界问题，
 * 每带一个 TaskPool 任务即可并行；带只写自己的目标行，蒙版 alpha 按带切片、绝对坐标
 * 由 bandTop 还原。
 *
 * 细节阶段（纹理/清晰度/锐化）是邻域滤波，按行切带需要 halo。但 box blur 的
 * 可分离实现用**运行和**（`boxBlurRow` / `boxBlurPlaneVertical`）：同一列的
 * 浮点累加从带的第 0 行开始时，与从整帧第 0 行开始时走的是不同的加法序列，
 * 结果会在 1 LSB 级别漂移。`tools/check_export_bands_parity.cjs` 实测：即使把
 * halo 加到 90 行（远大于真实影响半径），分带细节与整帧细节仍有零星 maxCh=1；
 * 这不是 halo 不够，而是浮点累加顺序不同，halo 无法修复。因此生产路径把细节
 * 阶段保留为**整帧一次**的 native 调用（`vivid_detail_core.cpp` 内部按行/列
 * 可并行，且每行/每列的加法顺序与串行完全一致，逐字节不变），而不是分带。
 *
 * 光学校正（畸变/色差/去边纹/暗角）是每个输出像素独立的双线性采样，没有运行和，
 * 因此按行分带 + `opticsHaloPadForRect` 的 halo 是**逐字节精确**的；黑白是逐点
 * 阶段。生产路径在细节之后用第二趟分带任务跑光学/黑白，并只写目标行。
 *
 * 本文件只含纯函数：没有 taskpool、没有全局可变状态，既能被 @Concurrent 任务体
 * 调用，也能被 Node 对拍测试直接加载。
 */

import {
  WorkerPipeline,
  LayerPassTiming,
  applyLayerBandFull,
  applyLutStack,
  applyOkLChBuffer,
  applyPointColorBuffer,
  buildMatrix,
  hasAdvancedAdjustments,
  isIdentity,
} from './WorkerCore';
import {
  LocalContrastParams,
  applyLocalContrast,
  localContrastHaloRadius,
  localContrastIsIdentity,
} from './LocalContrastCore';
import {
  OpticsParams,
  applyOptics,
  opticsHaloPadForRect,
  opticsIsIdentity,
} from './OpticsCore';
import { PointColorSample, pointColorIsIdentity } from './PointColorCore';
import { OkLChParams, oklchIsIdentity } from './OkLChCore';
import { BlackWhiteParams, blackWhiteBuffer, blackWhiteIsIdentity } from './BlackWhiteCore';
import { ProcessParams, WorkerLayer, WorkerLut } from './ProcessWorker';

/** 逐点阶段：图层 + LUT + 点颜色 + OkLCh（不需要 halo）。 */
export const BAND_PHASE_POINTWISE: number = 0;
/** 细节之后的阶段：光学 + 黑白（光学需要 halo，黑白是逐点）。 */
export const BAND_PHASE_OPTICS: number = 1;
/** 仅用于对拍/诊断：一趟跑完逐点 + 细节 + 光学 + 黑白。 */
export const BAND_PHASE_ALL: number = 2;

/** 一个横带的计划：目标行、实际处理行（含 halo）与 halo 来源。 */
export interface BandPassPlan {
  index: number;
  targetTop: number;
  targetRows: number;
  procTop: number;
  procRows: number;
  /** 细节阶段的 halo（生产路径不分带细节，固定为 0；诊断路径使用）。 */
  detailHalo: number;
  /** 光学阶段的 halo（畸变/色差位移 + 去边纹固定支撑）。 */
  opticsHalo: number;
  /** 实际用于扩展 procTop/procRows 的 halo 总数。 */
  halo: number;
  phase: number;
}

export interface ExportBandPlan {
  bands: BandPassPlan[];
  bandCount: number;
  phase: number;
}

/** 一带的完整参数，TaskPool 克隆后交给 processExportBand。 */
export interface BandJobParams {
  source: ArrayBuffer;
  width: number;
  height: number;
  /** source 第 0 行在整帧中的行号。蒙版与空间效果都用它换算绝对坐标。 */
  bandTop: number;
  bandRows: number;
  targetTop: number;
  targetRows: number;
  phase: number;
  layers: WorkerLayer[];
  luts: WorkerLut[];
  pointColor?: PointColorSample[];
  oklch?: OkLChParams;
  blackWhite?: BlackWhiteParams;
  /** 本带要执行的细节参数；生产路径为 undefined（细节整帧跑）。 */
  detail?: LocalContrastParams;
  /** 整帧雾色（[r,g,b]）；仅细节阶段使用，为空时就地估计。 */
  detailHaze: number[];
  /** 本带的 OpticsParams，`frame` 已改写成 [0, bandTop, 1, 1, width, height]。 */
  optics?: OpticsParams;
  /**
   * 整帧视口 [x, y, scaleX, scaleY, fullWidth, fullHeight]。空间效果（暗角/颗粒）
   * 用**绝对**输出坐标查表，所以带任务必须拿到整帧视口，不能改成带内坐标；
   * 绝对行号由 pixelOffset 补上。
   */
  viewport?: number[];
}

export interface BandJobResult {
  buffer: ArrayBuffer;
  width: number;
  height: number;
  /** 拼接时使用的目标行号，调用方按它写回整帧。 */
  targetTop: number;
  targetRows: number;
  totalMs: number;
  layersMs: number;
  detailMs: number;
  opticsMs: number;
  adjustMs: number;
  maskAdjustMs: number;
  maskBlendMs: number;
  compositeMs: number;
  /** 逐点阶段拆账：LUT 栈 / 点颜色 / OkLCh / 返回拷贝。 */
  lutMs: number;
  pointColorMs: number;
  oklchMs: number;
  copyMs: number;
  /** adjust 的进一步拆分：native 矩阵 vs native 高级调色。 */
  matrixMs: number;
  advancedMs: number;
  maskMatrixMs: number;
  maskAdvancedMs: number;
}

/** 细节阶段的邻域支撑；恒等时返回 0，切带不多读任何行。 */
export function detailHaloFor(detail: LocalContrastParams | null, width: number, height: number): number {
  if (detail === null || detail === undefined) return 0;
  if (localContrastIsIdentity(detail)) return 0;
  const halo = localContrastHaloRadius(Math.max(width, height), detail);
  return Number.isFinite(halo) && halo > 0 ? Math.ceil(halo) : 0;
}

/**
 * 把 height 行平均切成 bandCount 个横带。返回值是每带的目标行边界，最后一项是
 * height；带数不会超过行数，且每带至少一行。
 */
export function splitBandBounds(height: number, bandCount: number): number[] {
  const rows = Math.max(1, Math.floor(height));
  const count = Math.max(1, Math.min(Math.floor(bandCount), rows));
  const base = Math.floor(rows / count);
  const extra = rows - base * count;
  const bounds: number[] = [];
  let top = 0;
  for (let index = 0; index < count; index++) {
    bounds.push(top);
    top += base + (index < extra ? 1 : 0);
  }
  bounds.push(rows);
  return bounds;
}

/**
 * 规划一趟分带任务。
 *
 * `detailHalo` 由调用方给出：生产路径的逐点/光学趟传 0；只有诊断/对拍需要
 * 分带细节时才用 `detailHaloFor`。`haloOverride >= 0` 仅供对拍把 halo 强制成 0
 * （证伪用），生产调用不传。
 */
export function planExportBands(width: number, height: number, bandCount: number,
  detailHalo: number, optics: OpticsParams | null, phase: number,
  haloOverride: number = -1): ExportBandPlan {
  const bounds = splitBandBounds(height, bandCount);
  const bands: BandPassPlan[] = [];
  const detailPart = phase === BAND_PHASE_POINTWISE ? 0 : Math.max(0, detailHalo);
  const opticsActive = phase !== BAND_PHASE_POINTWISE && optics !== null && optics !== undefined &&
    !opticsIsIdentity(optics);
  for (let index = 0; index < bounds.length - 1; index++) {
    const targetTop = bounds[index];
    const targetRows = bounds[index + 1] - targetTop;
    const targetBottom = targetTop + targetRows;
    const rawOpticsHalo = opticsActive && optics
      ? opticsHaloPadForRect(optics, 0, targetTop, width, targetBottom, width, height)
      : 0;
    const opticsHalo = Number.isFinite(rawOpticsHalo) && rawOpticsHalo > 0 ? Math.ceil(rawOpticsHalo) : 0;
    const computed = detailPart + opticsHalo;
    const halo = haloOverride >= 0 ? Math.max(0, Math.floor(haloOverride)) : computed;
    const procTop = Math.max(0, targetTop - halo);
    const procBottom = Math.min(height, targetBottom + halo);
    bands.push({
      index: index,
      targetTop: targetTop,
      targetRows: targetRows,
      procTop: procTop,
      procRows: procBottom - procTop,
      detailHalo: detailPart,
      opticsHalo: opticsHalo,
      halo: halo,
      phase: phase,
    });
  }
  return { bands: bands, bandCount: bandCount, phase: phase };
}

/** 按带裁蒙版 alpha：只保留该带实际处理行（含 halo），绝对坐标由 bandTop 还原。 */
export function sliceBandLayers(layers: WorkerLayer[], maskStart: number, maskEnd: number): WorkerLayer[] {
  const sliced: WorkerLayer[] = [];
  for (const layer of layers) {
    let maskBuffer: ArrayBuffer | null = null;
    if (layer.maskBuffer !== null) {
      maskBuffer = layer.maskBuffer.slice(maskStart, maskEnd);
    }
    sliced.push({
      visible: layer.visible,
      opacity: layer.opacity,
      blendMode: layer.blendMode,
      adjustments: layer.adjustments,
      maskAdjustments: layer.maskAdjustments,
      mask: layer.mask,
      maskBuffer: maskBuffer,
    });
  }
  return sliced;
}

/** 本带的光学参数：`frame` 指向该带第 0 行在整帧中的位置，径向量仍按整帧算。 */
export function bandOptics(optics: OpticsParams, procTop: number,
  width: number, height: number): OpticsParams {
  return {
    distortion: optics.distortion,
    vignetteAmount: optics.vignetteAmount,
    vignetteMidpoint: optics.vignetteMidpoint,
    chromaticAberration: optics.chromaticAberration,
    defringePurple: optics.defringePurple,
    defringeGreen: optics.defringeGreen,
    frame: [0, procTop, 1, 1, width, height],
  };
}

/**
 * 由整帧参数 + 一个带计划构造该带的任务参数。生产路径（ImageProcessor）与
 * 对拍测试共用这一份构造，避免“测试自己拼参数、把生产的接线错误漏掉”。
 */
export function buildBandJob(params: ProcessParams, plan: BandPassPlan,
  source: Uint8ClampedArray, width: number, height: number, haze: number[]): BandJobParams {
  const rowBytes = width * 4;
  const slice = source.slice(plan.procTop * rowBytes, (plan.procTop + plan.procRows) * rowBytes);
  const phase = plan.phase;
  let optics: OpticsParams | undefined = undefined;
  if (phase !== BAND_PHASE_POINTWISE && params.optics && !opticsIsIdentity(params.optics)) {
    optics = bandOptics(params.optics, plan.procTop, width, height);
  }
  const pointwise = phase === BAND_PHASE_POINTWISE;
  return {
    source: slice.buffer as ArrayBuffer,
    width: width,
    height: height,
    bandTop: plan.procTop,
    bandRows: plan.procRows,
    targetTop: plan.targetTop,
    targetRows: plan.targetRows,
    phase: phase,
    layers: pointwise
      ? sliceBandLayers(params.layers, plan.procTop * width, (plan.procTop + plan.procRows) * width)
      : [],
    luts: pointwise ? params.luts : [],
    pointColor: pointwise ? params.pointColor : undefined,
    oklch: pointwise ? params.oklch : undefined,
    blackWhite: phase === BAND_PHASE_OPTICS || phase === BAND_PHASE_ALL ? params.blackWhite : undefined,
    detail: phase === BAND_PHASE_OPTICS ? undefined : params.detail,
    detailHaze: haze,
    optics: optics,
    viewport: params.viewport,
  };
}

/**
 * 跑一个横带。
 *
 * 关键点：所有逐点阶段（图层/LUT/点颜色/OkLCh/黑白）都用整帧 width/height 和
 * **绝对** pixelOffset，所以带内 halo 行算出的像素与整帧同一行完全一致；光学在
 * 带内多算 halo 行，但只把目标行返回。图层子带仍按 32768 像素切，与串行 worker
 * 的取消粒度一致。
 */
export function processExportBand(job: BandJobParams): BandJobResult {
  const startedAt = Date.now();
  const width = job.width;
  const height = job.height;
  const rows = job.bandRows;
  const targetTop = job.targetTop - job.bandTop;
  if (rows <= 0 || width <= 0 || height <= 0 || targetTop < 0 ||
    targetTop + job.targetRows > rows) {
    throw new Error('Invalid export band geometry');
  }
  let pixels = new Uint8ClampedArray(job.source);
  const expected = width * rows * 4;
  if (pixels.length !== expected) throw new Error('Invalid export band buffer');
  const passTiming: LayerPassTiming = { adjust: 0, maskAdjust: 0, maskBlend: 0, composite: 0 };

  let layersMs = 0;
  let detailMs = 0;
  let opticsMs = 0;
  let lutMs = 0;
  let pointColorMs = 0;
  let oklchMs = 0;
  let copyMs = 0;

  if (job.phase !== BAND_PHASE_OPTICS) {
    const layersStart = Date.now();
    const bandBytes = Math.min(pixels.length, 32768 * 4);
    const scratchBase = new Uint8ClampedArray(bandBytes);
    const scratchAdjusted = new Uint8ClampedArray(bandBytes);
    const scratchMaskAdjusted = new Uint8ClampedArray(bandBytes);
    const pipelines: WorkerPipeline[] = [];
    for (const layer of job.layers) {
      if (!layer.visible || layer.opacity <= 0) continue;
      const matrix = buildMatrix(layer.adjustments);
      const hasMatrix = !isIdentity(matrix);
      const hasAdvanced = hasAdvancedAdjustments(layer.adjustments);
      if (!hasMatrix && !hasAdvanced && !layer.mask) continue;
      let maskBuffer: Uint8ClampedArray | null = null;
      if (layer.maskBuffer) {
        // The caller already sliced the alpha to this band's processed rows.
        maskBuffer = new Uint8ClampedArray(layer.maskBuffer);
      } else if (layer.mask) {
        // The band planner refuses legacy masks: rendering one per band would use
        // band coordinates instead of whole-frame ones. Throwing makes the caller
        // fall back to the serial worker instead of publishing wrong pixels.
        throw new Error('Export band requires a prepared mask buffer');
      }
      const maskMatrix = buildMatrix(layer.maskAdjustments);
      const hasMaskMatrix = !isIdentity(maskMatrix);
      const hasMaskAdjustments = hasMaskMatrix || hasAdvancedAdjustments(layer.maskAdjustments);
      pipelines.push({
        adjustments: layer.adjustments,
        matrix: hasMatrix ? matrix : null,
        hasAdvanced: hasAdvanced,
        opacity: layer.opacity,
        blendMode: layer.blendMode,
        mask: maskBuffer,
        base: scratchBase,
        adjusted: scratchAdjusted,
        maskAdjustments: layer.maskAdjustments,
        maskMatrix: hasMaskMatrix ? maskMatrix : null,
        hasMaskAdjustments: hasMaskAdjustments && maskBuffer !== null,
        maskAdjusted: scratchMaskAdjusted,
        width: width,
        height: height,
        viewport: job.viewport,
        bandCache: {},
      });
    }
    for (const pipeline of pipelines) {
      for (let start = 0; start < pixels.length; start += bandBytes) {
        const end = Math.min(pixels.length, start + bandBytes);
        const band = pixels.subarray(start, end);
        pipeline.pixelOffset = job.bandTop * width + start / 4;
        pipeline.base.set(band);
        applyLayerBandFull(band, pipeline, 0, band.length, passTiming);
      }
    }
    const lutStart = Date.now();
    applyLutStack(pixels, job.luts);
    lutMs = Date.now() - lutStart;
    const samples = job.pointColor;
    if (samples && samples.length > 0 && !pointColorIsIdentity(samples)) {
      const pointColorStart = Date.now();
      applyPointColorBuffer(pixels, width, rows, samples);
      pointColorMs = Date.now() - pointColorStart;
    }
    const oklch = job.oklch;
    if (oklch && !oklchIsIdentity(oklch)) {
      const oklchStart = Date.now();
      applyOkLChBuffer(pixels, width, rows, oklch);
      oklchMs = Date.now() - oklchStart;
    }
    layersMs = Date.now() - layersStart;
  }

  if (job.phase !== BAND_PHASE_POINTWISE) {
    const detail = job.detail;
    if (detail && !localContrastIsIdentity(detail)) {
      const detailStart = Date.now();
      pixels = applyLocalContrast(pixels, width, rows, detail, Math.max(width, height),
        job.detailHaze);
      detailMs = Date.now() - detailStart;
    }
    const optics = job.optics;
    if (optics && !opticsIsIdentity(optics)) {
      const opticsStart = Date.now();
      pixels = applyOptics(pixels, width, rows, optics);
      opticsMs = Date.now() - opticsStart;
    }
    const blackWhite = job.blackWhite;
    if (blackWhite && !blackWhiteIsIdentity(blackWhite)) {
      blackWhiteBuffer(pixels, width, rows, blackWhite);
    }
  }

  const copyStart = Date.now();
  const copyBytes = job.targetRows * width * 4;
  const output = new Uint8ClampedArray(copyBytes);
  const sourceOffset = targetTop * width * 4;
  output.set(pixels.subarray(sourceOffset, sourceOffset + copyBytes));
  copyMs = Date.now() - copyStart;
  return {
    buffer: output.buffer as ArrayBuffer,
    width: width,
    height: job.targetRows,
    targetTop: job.targetTop,
    targetRows: job.targetRows,
    totalMs: Date.now() - startedAt,
    layersMs: layersMs,
    detailMs: detailMs,
    opticsMs: opticsMs,
    adjustMs: passTiming.adjust,
    maskAdjustMs: passTiming.maskAdjust,
    maskBlendMs: passTiming.maskBlend,
    compositeMs: passTiming.composite,
    lutMs: lutMs,
    pointColorMs: pointColorMs,
    oklchMs: oklchMs,
    copyMs: copyMs,
    matrixMs: passTiming.matrix ?? 0,
    advancedMs: passTiming.advanced ?? 0,
    maskMatrixMs: passTiming.maskMatrix ?? 0,
    maskAdvancedMs: passTiming.maskAdvanced ?? 0,
  };
}
