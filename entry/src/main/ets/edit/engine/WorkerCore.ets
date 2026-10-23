import { rasterizeBrushSegment } from './BrushRasterizer';
import { transformGeometry } from './GeometryTransform';
import {
  GeometryMap,
  buildFrameSampleTable,
  buildGeometryMap,
  remapFrameToDisplay,
} from './GeometryMath';
import { applySpatialEffects } from './SpatialEffects';
import {
  ParametricCurveParams,
  buildParametricLut,
  parametricRefineScale,
} from './ParametricCurveCore';
import {
  ProcessParams,
  WorkerAdjustments,
  WorkerMask,
  WorkerStroke,
  WorkerLut,
} from './ProcessWorker';
import {
  NativeLutPayload,
  nativeAdvancedBand,
  nativeCompositeBand,
  nativeLutStackPrepared,
  nativeMaskBlend,
  nativeMatrixBand,
  nativeOklch,
  nativePointColor,
  nativePointwiseReady,
  packLutsForNative,
  reportLutStackReject,
} from './NativeComposite';
import {
  PointColorSample,
  applyPointColorBuffer as applyPointColorBufferReference,
  pointColorIsIdentity,
} from './PointColorCore';
import {
  OkLChParams,
  applyOkLChBuffer as applyOkLChBufferReference,
  oklchIsIdentity,
} from './OkLChCore';

/**
 * 后台像素管线的算法实现（纯函数，无状态，可被 @Concurrent 函数
 * 以 import 方式引用）。语义与主线程 ImageProcessor 保持一致。
 */

export interface WorkerPipeline {
  viewport?: number[];
  pixelOffset?: number;
  advancedTables?: WorkerAdvancedTables;
  maskAdvancedTables?: WorkerAdvancedTables;
  adjustments: WorkerAdjustments;
  matrix: Float32Array | null;
  hasAdvanced: boolean;
  opacity: number;
  blendMode: number;
  mask: Uint8ClampedArray | null;
  base: Uint8ClampedArray;
  adjusted: Uint8ClampedArray;
  maskAdjustments: WorkerAdjustments;
  maskMatrix: Float32Array | null;
  hasMaskAdjustments: boolean;
  maskAdjusted: Uint8ClampedArray;
  width: number;
  height: number;
  /** Per-pipeline, per-frame cache; see WorkerBandCache. */
  bandCache?: WorkerBandCache;
}

export interface GeometryLocal {
  pixels: Uint8ClampedArray;
  width: number;
  height: number;
}

const LumR = 0.2126;
const LumG = 0.7152;
const LumB = 0.0722;

/**
 * Per-pass timing for the layer pipeline. A masked local adjustment walks the
 * frame four times — adjustments, mask adjustments, mask blend, composite — and
 * every walk is an interpreted per-pixel loop, so this is what tells us which
 * pass to move into native code next. Accumulated across bands by the caller.
 */
export interface LayerPassTiming {
  adjust: number;
  maskAdjust: number;
  maskBlend: number;
  composite: number;
  /** 以下四项是 adjust / maskAdjust 的拆分，用于判断 native 矩阵与
   * native 高级调色各自占比；旧调用方不填也不影响原字段语义。 */
  matrix?: number;
  advanced?: number;
  maskMatrix?: number;
  maskAdvanced?: number;
}

/**
 * Reused per-pipeline answers for things that depend only on the layer, not on
 * the band. `applyLayerBandFull` is called once per band (80 times for a zoom
 * tile), and each of these used to be recomputed on every call:
 *  - `maskAdvancedActive`: walks the mask-adjustment parameter arrays;
 *  - `nativeTables`: the packed Float64/Float32 payloads for the advanced loop;
 *  - `nativeViewport`: the `Float64Array(6)` the native call expects, which was
 *    allocated once per band whenever a viewport was present.
 * None of these change between bands, so the band loop only reads them.
 */
export interface WorkerBandCache {
  maskAdvancedActive?: boolean;
}

export function applyLayerBandFull(
  result: Uint8ClampedArray,
  pipeline: WorkerPipeline,
  start: number,
  end: number,
  timing?: LayerPassTiming,
): void {
  const base = pipeline.base;
  let clock = timing ? Date.now() : 0;
  let subClock = clock;
  if (pipeline.matrix) {
    // Native first; the identical ArkTS loop below runs when it cannot serve the
    // call (no library on the device, an older one, or rejected arguments).
    if (!nativeMatrixBand(base, pipeline.matrix, pipeline.adjusted, start, end)) {
      applyMatrixBand(base, pipeline.matrix, pipeline.adjusted, start, end);
    }
  } else {
    pipeline.adjusted.set(base.subarray(start, end), start);
  }
  if (timing) {
    const now = Date.now();
    timing.matrix = (timing.matrix ?? 0) + (now - subClock);
    subClock = now;
  }
  if (pipeline.hasAdvanced) {
    if (!pipeline.advancedTables) pipeline.advancedTables = prepareAdvancedTables(pipeline.adjustments);
    applyAdvancedBand(pipeline.adjusted, pipeline.adjustments, start, end, pipeline.width, pipeline.height,
      pipeline.viewport, pipeline.pixelOffset ?? 0, pipeline.advancedTables);
  }
  if (timing) {
    const now = Date.now();
    timing.advanced = (timing.advanced ?? 0) + (now - subClock);
    timing.adjust += now - clock;
    clock = now;
    subClock = now;
  }
  if (pipeline.hasMaskAdjustments && pipeline.mask) {
    if (pipeline.maskMatrix) {
      if (!nativeMatrixBand(pipeline.adjusted, pipeline.maskMatrix, pipeline.maskAdjusted, start, end)) {
        applyMatrixBand(pipeline.adjusted, pipeline.maskMatrix, pipeline.maskAdjusted, start, end);
      }
    } else {
      pipeline.maskAdjusted.set(pipeline.adjusted.subarray(start, end), start);
    }
    if (timing) {
      const now = Date.now();
      timing.maskMatrix = (timing.maskMatrix ?? 0) + (now - subClock);
      subClock = now;
    }
    const maskAdvancedActive = pipeline.bandCache?.maskAdvancedActive ??
      hasAdvancedAdjustments(pipeline.maskAdjustments);
    if (pipeline.bandCache) pipeline.bandCache.maskAdvancedActive = maskAdvancedActive;
    if (maskAdvancedActive) {
      if (!pipeline.maskAdvancedTables) pipeline.maskAdvancedTables = prepareAdvancedTables(pipeline.maskAdjustments);
      applyAdvancedBand(pipeline.maskAdjusted, pipeline.maskAdjustments, start, end, pipeline.width, pipeline.height,
        pipeline.viewport, pipeline.pixelOffset ?? 0, pipeline.maskAdvancedTables);
    }
    if (timing) {
      const now = Date.now();
      timing.maskAdvanced = (timing.maskAdvanced ?? 0) + (now - subClock);
      timing.maskAdjust += now - clock;
      clock = now;
      subClock = now;
    }
    const mask = pipeline.mask;
    const adjusted = pipeline.adjusted;
    const maskAdjusted = pipeline.maskAdjusted;
    const pixelOffset = pipeline.pixelOffset ?? 0;
    if (!nativeMaskBlend(adjusted, maskAdjusted, mask, start, end, pixelOffset)) {
      for (let i = start; i < end; i += 4) {
        const maskAlpha = mask[(i >> 2) + pixelOffset] / 255;
        if (maskAlpha <= 0) continue;
        adjusted[i] = clampByte(adjusted[i] + (maskAdjusted[i] - adjusted[i]) * maskAlpha);
        adjusted[i + 1] = clampByte(adjusted[i + 1] + (maskAdjusted[i + 1] - adjusted[i + 1]) * maskAlpha);
        adjusted[i + 2] = clampByte(adjusted[i + 2] + (maskAdjusted[i + 2] - adjusted[i + 2]) * maskAlpha);
      }
    }
    if (timing) {
      const now = Date.now();
      timing.maskBlend += now - clock;
      clock = now;
    }
  }
  // Local adjustments already consumed the mask above. Applying it again
  // during layer composition would square feathered alpha and hide globals.
  const compositeMask = pipeline.hasMaskAdjustments ? null : pipeline.mask;
  if (!nativeCompositeBand(result, base, pipeline.adjusted, compositeMask, pipeline.opacity,
    pipeline.blendMode, start, end, pipeline.pixelOffset ?? 0)) {
    compositeBand(result, base, pipeline.adjusted, compositeMask,
      pipeline.opacity, pipeline.blendMode, start, end, pipeline.pixelOffset ?? 0);
  }
  if (timing) timing.composite += Date.now() - clock;
}

/**
 * Number of times the flattened native LUT payload has been built in this
 * worker since the last `resetLutBuildCount()`. `processPixels` resets it before
 * the band loop and logs the total, so a device log proves whether the table is
 * packed once per frame or once per band.
 */
let lutBuildCount: number = 0;

export function resetLutBuildCount(): void {
  lutBuildCount = 0;
}

export function currentLutBuildCount(): number {
  return lutBuildCount;
}

/**
 * A LUT stack prepared once for a whole frame.
 *
 * The native payload is the expensive part: a 33^3 table is 107811 doubles
 * (~862 KB), and the export/preview workers used to rebuild it for every
 * 32768-pixel band. A 2048x1644 tile has 103 bands, so that was 103 table
 * copies per frame. `prepareLutStack` runs outside the band loop and every band
 * only reads `payload`.
 */
export interface PreparedLutStack {
  active: WorkerLut[];
  payload: NativeLutPayload | null;
  /** Set after the first native refusal, so later bands go straight to ArkTS. */
  rejected: boolean;
}

/** Filter/validate the stack and pack the native payload exactly once. */
export function prepareLutStack(luts: WorkerLut[]): PreparedLutStack {
  if (!luts || luts.length === 0) return { active: [], payload: null, rejected: false };
  const active: WorkerLut[] = [];
  for (const lut of luts) {
    if (!lut.enabled || lut.intensity <= 0) continue;
    validateWorkerLut(lut);
    active.push(lut);
  }
  if (active.length === 0) return { active: active, payload: null, rejected: false };
  let payload: NativeLutPayload | null = null;
  if (nativePointwiseReady()) {
    payload = packLutsForNative(active);
    lutBuildCount++;
  }
  return { active: active, payload: payload, rejected: false };
}

/** Apply a prepared stack in place; falls back to the ArkTS reference. */
export function applyPreparedLutStack(pixels: Uint8ClampedArray, prepared: PreparedLutStack): void {
  if (prepared.active.length === 0) return;
  const payload = prepared.payload;
  if (payload !== null && !prepared.rejected) {
    if (nativeLutStackPrepared(pixels, payload)) return;
    // The rejection is a property of the payload, not of this band, so stop
    // retrying native until the next frame and explain the first refusal.
    prepared.rejected = true;
    reportLutStackReject(payload, prepared.active);
  }
  applyLutStackReference(pixels, prepared.active);
}

/** Apply the ordered LUT stack in-place. Alpha is intentionally untouched. */
export function applyLutStack(pixels: Uint8ClampedArray, luts: WorkerLut[]): void {
  applyPreparedLutStack(pixels, prepareLutStack(luts));
}

/** Pure ArkTS LUT stack: the reference path, also used when native declines. */
export function applyLutStackReference(pixels: Uint8ClampedArray, active: WorkerLut[]): void {
  // One reusable triplet avoids allocating nine small arrays for every pixel
  // and LUT layer while preserving the ordered-stack semantics.
  const mapped: number[] = [0, 0, 0];
  for (let index = 0; index < pixels.length; index += 4) {
    let red = pixels[index] / 255;
    let green = pixels[index + 1] / 255;
    let blue = pixels[index + 2] / 255;
    for (const lut of active) {
      sampleLutInto(lut, red, green, blue, mapped);
      const amount = Math.max(0, Math.min(1, lut.intensity));
      red += (mapped[0] - red) * amount;
      green += (mapped[1] - green) * amount;
      blue += (mapped[2] - blue) * amount;
    }
    pixels[index] = clampByte(red * 255);
    pixels[index + 1] = clampByte(green * 255);
    pixels[index + 2] = clampByte(blue * 255);
  }
}

/**
 * Point-colour stage with native first. The ArkTS reference still lives in
 * PointColorCore; this wrapper only chooses the path and reports the changed
 * count the reference returns (native writes only the three RGB channels, so
 * the count is not needed by callers).
 */
export function applyPointColorBuffer(rgba: Uint8ClampedArray, width: number, height: number,
  samples: PointColorSample[]): number {
  if (!samples || samples.length === 0 || pointColorIsIdentity(samples)) return 0;
  if (nativePointColor(rgba, samples)) return 0;
  return applyPointColorBufferReference(rgba, width, height, samples);
}

/** OkLCh stage with native first; falls back to OkLChCore's reference loop. */
export function applyOkLChBuffer(rgba: Uint8ClampedArray, width: number, height: number,
  params: OkLChParams): number {
  if (oklchIsIdentity(params)) return 0;
  if (nativeOklch(rgba, params)) return 0;
  return applyOkLChBufferReference(rgba, width, height, params);
}

export function validateWorkerLut(lut: WorkerLut): void {
  if (!Number.isInteger(lut.size) || lut.size < 2 || lut.size > 128 ||
    lut.values.length !== lut.size * lut.size * lut.size * 3 || !Number.isFinite(lut.intensity)) {
    throw new Error('LUT table size or intensity is invalid');
  }
  if (lut.domainMin.length !== 3 || lut.domainMax.length !== 3) {
    throw new Error('LUT domain requires three channels');
  }
  for (let c = 0; c < 3; c++) {
    if (!Number.isFinite(lut.domainMin[c]) || !Number.isFinite(lut.domainMax[c]) ||
      lut.domainMax[c] <= lut.domainMin[c]) throw new Error('LUT domain is invalid');
  }
  for (const value of lut.values) {
    if (!Number.isFinite(value)) throw new Error('LUT table contains non-finite samples');
  }
}

function sampleLutInto(lut: WorkerLut, red: number, green: number, blue: number, result: number[]): void {
  const size = lut.size;
  const minR = lut.domainMin.length >= 3 ? lut.domainMin[0] : 0;
  const minG = lut.domainMin.length >= 3 ? lut.domainMin[1] : 0;
  const minB = lut.domainMin.length >= 3 ? lut.domainMin[2] : 0;
  const maxR = lut.domainMax.length >= 3 ? lut.domainMax[0] : 1;
  const maxG = lut.domainMax.length >= 3 ? lut.domainMax[1] : 1;
  const maxB = lut.domainMax.length >= 3 ? lut.domainMax[2] : 1;
  // Active tables have already passed strict increasing-domain validation.
  const rx = clamp01((red - minR) / (maxR - minR)) * (size - 1);
  const gx = clamp01((green - minG) / (maxG - minG)) * (size - 1);
  const bx = clamp01((blue - minB) / (maxB - minB)) * (size - 1);
  const r0 = Math.floor(rx); const g0 = Math.floor(gx); const b0 = Math.floor(bx);
  const r1 = Math.min(size - 1, r0 + 1); const g1 = Math.min(size - 1, g0 + 1); const b1 = Math.min(size - 1, b0 + 1);
  const fr = rx - r0; const fg = gx - g0; const fb = bx - b0;
  const i000 = ((b0 * size + g0) * size + r0) * 3;
  const i100 = ((b0 * size + g0) * size + r1) * 3;
  const i010 = ((b0 * size + g1) * size + r0) * 3;
  const i110 = ((b0 * size + g1) * size + r1) * 3;
  const i001 = ((b1 * size + g0) * size + r0) * 3;
  const i101 = ((b1 * size + g0) * size + r1) * 3;
  const i011 = ((b1 * size + g1) * size + r0) * 3;
  const i111 = ((b1 * size + g1) * size + r1) * 3;
  for (let channel = 0; channel < 3; channel++) {
    const c000 = lut.values[i000 + channel];
    const c100 = lut.values[i100 + channel];
    const c010 = lut.values[i010 + channel];
    const c110 = lut.values[i110 + channel];
    const c001 = lut.values[i001 + channel];
    const c101 = lut.values[i101 + channel];
    const c011 = lut.values[i011 + channel];
    const c111 = lut.values[i111 + channel];
    const c00 = c000 + (c100 - c000) * fr;
    const c10 = c010 + (c110 - c010) * fr;
    const c01 = c001 + (c101 - c001) * fr;
    const c11 = c011 + (c111 - c011) * fr;
    const c0 = c00 + (c10 - c00) * fg;
    const c1 = c01 + (c11 - c01) * fg;
    // CUBE outputs may extend outside the display range. Blend intensity
    // and subsequent LUTs first, clamp only when writing the final pixel.
    result[channel] = c0 + (c1 - c0) * fb;
  }
}

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

function identityMatrix(): Float32Array {
  return new Float32Array([
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ]);
}

function multiplyMatrices(a: Float32Array, b: Float32Array): Float32Array {
  const out = new Float32Array(20);
  for (let row = 0; row < 4; row++) {
    for (let col = 0; col < 5; col++) {
      let sum = 0;
      for (let k = 0; k < 4; k++) {
        sum += a[row * 5 + k] * b[k * 5 + col];
      }
      if (col === 4) sum += a[row * 5 + 4];
      out[row * 5 + col] = sum;
    }
  }
  return out;
}

function diagonalMatrix(s: number, offset: number): Float32Array {
  return new Float32Array([
    s, 0, 0, 0, offset,
    0, s, 0, 0, offset,
    0, 0, s, 0, offset,
    0, 0, 0, 1, 0,
  ]);
}

export function buildMatrix(adj: WorkerAdjustments): Float32Array {
  let m = identityMatrix();
  // Exposure is applied in linear light by applyAdvancedBand, not here.
  if (adj.contrast !== 0) {
    const cf = 1 + adj.contrast * 0.5;
    m = multiplyMatrices(m, diagonalMatrix(cf, (1 - cf) * 127.5));
  }
  if (adj.brightness !== 0) {
    m = multiplyMatrices(m, diagonalMatrix(1, adj.brightness * 64));
  }
  if (adj.saturation !== 0) {
    const s = 1 + adj.saturation;
    m = multiplyMatrices(m, new Float32Array([
      (1 - s) * LumR + s, (1 - s) * LumG, (1 - s) * LumB, 0, 0,
      (1 - s) * LumR, (1 - s) * LumG + s, (1 - s) * LumB, 0, 0,
      (1 - s) * LumR, (1 - s) * LumG, (1 - s) * LumB + s, 0, 0,
      0, 0, 0, 1, 0,
    ]));
  }
  if (adj.hue !== 0) {
    const rad = adj.hue * Math.PI / 180;
    const c = Math.cos(rad);
    const sn = Math.sin(rad);
    const lr = LumR;
    const lg = LumG;
    const lb = LumB;
    // Same luminance-preserving hue rotation as ColorMatrixBuilder.
    const greenSinR = (lr * lr + lb * (1 - lr)) / lg;
    const greenSinG = lr - lb;
    const greenSinB = -(lr * (1 - lb) + lb * lb) / lg;
    m = multiplyMatrices(m, new Float32Array([
      lr + (1 - lr) * c - lr * sn, lg - lg * c - lg * sn, lb - lb * c + (1 - lb) * sn, 0, 0,
      lr - lr * c + greenSinR * sn, lg + (1 - lg) * c + greenSinG * sn, lb - lb * c + greenSinB * sn, 0, 0,
      lr - lr * c - (1 - lr) * sn, lg - lg * c + lg * sn, lb + (1 - lb) * c + lb * sn, 0, 0,
      0, 0, 0, 1, 0,
    ]));
  }
  return m;
}

export function isIdentity(m: Float32Array): boolean {
  const id = identityMatrix();
  for (let i = 0; i < 20; i++) {
    if (Math.abs(m[i] - id[i]) > 0.001) return false;
  }
  return true;
}

function applyMatrixBand(
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
    output[idx] = clampByte(a * R + b * G + c * B + d * A + e);
    output[idx + 1] = clampByte(f * R + g * G + h * B + i * A + j);
    output[idx + 2] = clampByte(k * R + l * G + m * B + n * A + o);
    output[idx + 3] = clampByte(p * R + q * G + r * B + s * A + t);
  }
}

export function hasAdvancedAdjustments(adj: WorkerAdjustments): boolean {
  if (adj.exposure !== 0 || adj.highlights !== 0 || adj.shadows !== 0 || adj.whites !== 0 || adj.blacks !== 0 ||
    adj.vibrance !== 0 || adj.temperature !== 0 || adj.tint !== 0) return true;
  if (adj.toneCurve !== 0 || adj.curveRed !== 0 || adj.curveGreen !== 0 || adj.curveBlue !== 0) return true;
  if (hasParametricCurve(adj)) return true;
  if (!curveIsIdentity(adj.toneCurvePoints) || !curveIsIdentity(adj.redCurvePoints) ||
    !curveIsIdentity(adj.greenCurvePoints) || !curveIsIdentity(adj.blueCurvePoints)) return true;
  if (adj.calibrationRedHue !== 0 || adj.calibrationRedSaturation !== 0 ||
    adj.calibrationGreenHue !== 0 || adj.calibrationGreenSaturation !== 0 ||
    adj.calibrationBlueHue !== 0 || adj.calibrationBlueSaturation !== 0) return true;
  if (adj.vignetteAmount !== 0 || adj.grainAmount !== 0) return true;
  if (adj.colorGradingEnabled && (adj.gradingShadowsHue !== 0 || adj.gradingShadowsSaturation !== 0 ||
    adj.gradingShadowsLuminance !== 0 || adj.gradingMidtonesHue !== 0 ||
    adj.gradingMidtonesSaturation !== 0 || adj.gradingMidtonesLuminance !== 0 ||
    adj.gradingHighlightsHue !== 0 || adj.gradingHighlightsSaturation !== 0 ||
    adj.gradingHighlightsLuminance !== 0 || adj.gradingGlobalHue !== 0 ||
    adj.gradingGlobalSaturation !== 0 || adj.gradingGlobalLuminance !== 0 ||
    adj.gradingBlending !== 0 || adj.gradingBalance !== 0)) return true;
  for (let i = 0; i < 8; i++) {
    if (adj.mixHue[i] !== 0 || adj.mixSaturation[i] !== 0 || adj.mixLuminance[i] !== 0) return true;
  }
  return false;
}

function curveIsIdentity(points: number[][]): boolean {
  if (points.length < 2 || points[0][0] !== 0 || points[points.length - 1][0] !== 1) return false;
  for (let index = 0; index < points.length; index++) {
    if (Math.abs(points[index][0] - points[index][1]) > 0.0005 ||
      (index > 0 && points[index][0] <= points[index - 1][0])) return false;
  }
  return true;
}

function hasMixer(adj: WorkerAdjustments): boolean {
  for (let index = 0; index < 8; index++) {
    if (adj.mixHue[index] !== 0 || adj.mixSaturation[index] !== 0 || adj.mixLuminance[index] !== 0) return true;
  }
  return false;
}

function hasCalibration(adj: WorkerAdjustments): boolean {
  return adj.calibrationRedHue !== 0 || adj.calibrationRedSaturation !== 0 ||
    adj.calibrationGreenHue !== 0 || adj.calibrationGreenSaturation !== 0 ||
    adj.calibrationBlueHue !== 0 || adj.calibrationBlueSaturation !== 0;
}

function hasGrading(adj: WorkerAdjustments): boolean {
  return adj.colorGradingEnabled && (adj.gradingShadowsHue !== 0 || adj.gradingShadowsSaturation !== 0 ||
    adj.gradingShadowsLuminance !== 0 || adj.gradingMidtonesHue !== 0 ||
    adj.gradingMidtonesSaturation !== 0 || adj.gradingMidtonesLuminance !== 0 ||
    adj.gradingHighlightsHue !== 0 || adj.gradingHighlightsSaturation !== 0 ||
    adj.gradingHighlightsLuminance !== 0 || adj.gradingGlobalHue !== 0 ||
    adj.gradingGlobalSaturation !== 0 || adj.gradingGlobalLuminance !== 0 ||
    adj.gradingBlending !== 0 || adj.gradingBalance !== 0);
}

/**
 * True when the parametric curve is not the identity. Only the four region
 * amounts matter: moving a split with every amount at zero still integrates to
 * the identity, as `ParametricCurveCore` documents.
 */
function hasParametricCurve(adj: WorkerAdjustments): boolean {
  return adj.parametricHighlights !== 0 || adj.parametricLights !== 0 ||
    adj.parametricDarks !== 0 || adj.parametricShadows !== 0;
}

function parametricSettings(adj: WorkerAdjustments): ParametricCurveParams {
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
  return settings;
}

/** HSV saturation, the chroma ratio a luminance-preserving scale acts on. */
function saturationOf(red: number, green: number, blue: number): number {
  const high = Math.max(red, Math.max(green, blue));
  const low = Math.min(red, Math.min(green, blue));
  return high <= 0 ? 0 : (high - low) / high;
}

/** Linear interpolation into a 256-entry table whose domain is 0..1. */
function sampleTable(table: Float32Array, value: number): number {
  const size = table.length;
  if (size === 0) return value;
  const position = clamp01(value) * (size - 1);
  const index = Math.floor(position);
  if (index >= size - 1) return table[size - 1];
  return table[index] + (table[index + 1] - table[index]) * (position - index);
}

interface PreparedCurveLocal {
  samples: number[];
  amount: number;
  channelCurve: boolean;
  useScalar: boolean;
}

export interface WorkerAdvancedTables {
  tone: PreparedCurveLocal;
  red: PreparedCurveLocal;
  green: PreparedCurveLocal;
  blue: PreparedCurveLocal;
  tonal: Float32Array | null;
  exposureGain: number;
  fastChannels: Uint8ClampedArray[];
  /** 256-entry parametric tone curve, or null when it is the identity. */
  parametric: Float32Array | null;
  /** Packed Float64 parameters for the native advanced band (70 entries). */
  nativeParams: Float64Array;
  /** 4 x 1025 doubles: master, red, green, blue curves. */
  nativeCurves: Float64Array;
  /**
   * Per-frame answers reused by every band of one pipeline. `generalPath` is
   * the "does this layer need the full advanced loop" bit; without the cache
   * the mixer/calibration/grading/tonal/white-balance scans ran 80 times for a
   * zoom tile. `nativeViewport` is a single Float64Array(6) that is refilled,
   * not reallocated, on each band.
   */
  generalPath?: boolean;
  nativeViewport?: Float64Array | null;
}

/**
 * Pack the scalar part of `WorkerAdjustments` for the native advanced band.
 * Layout is documented in vivid_advanced_core.cpp; width/height/pixelOffset
 * are overwritten per band by `applyAdvancedBand`.
 */
function packAdvancedParams(adj: WorkerAdjustments): Float64Array {
  const p = new Float64Array(70);
  p[0] = Math.pow(2, adj.exposure * 2);
  // 与 applyAdvancedBand 的 white-balance 段同一公式（注释见那里）。
  const warmth = adj.temperature * 0.22;
  const tintGreen = adj.tint * 0.24;
  const rawRedGain = Math.exp(warmth - tintGreen * 0.5);
  const rawGreenGain = Math.exp(tintGreen);
  const rawBlueGain = Math.exp(-warmth - tintGreen * 0.5);
  const normalise = 1 / Math.max(0.00001,
    rawRedGain * LumR + rawGreenGain * LumG + rawBlueGain * LumB);
  p[1] = rawRedGain * normalise;
  p[2] = rawGreenGain * normalise;
  p[3] = rawBlueGain * normalise;
  p[4] = adj.vibrance;
  p[5] = adj.parametricRefineSaturation;
  p[6] = adj.gradingBlending;
  p[7] = adj.gradingBalance;
  p[8] = adj.vignetteAmount;
  p[9] = adj.vignetteMidpoint;
  p[10] = adj.vignetteRoundness;
  p[11] = adj.vignetteFeather;
  p[12] = adj.vignetteHighlights;
  p[13] = adj.grainAmount;
  p[14] = adj.grainSize;
  p[15] = adj.grainRoughness;
  p[20] = adj.calibrationRedHue;
  p[21] = adj.calibrationRedSaturation;
  p[22] = adj.calibrationGreenHue;
  p[23] = adj.calibrationGreenSaturation;
  p[24] = adj.calibrationBlueHue;
  p[25] = adj.calibrationBlueSaturation;
  for (let index = 0; index < 8; index++) {
    p[26 + index] = adj.mixHue[index];
    p[34 + index] = adj.mixSaturation[index];
    p[42 + index] = adj.mixLuminance[index];
  }
  const grading = hasGrading(adj);
  if (grading) {
    const shadows = hslToRgbLocal(wrap01(adj.gradingShadowsHue / 360),
      clamp01(adj.gradingShadowsSaturation), 0.5);
    const midtones = hslToRgbLocal(wrap01(adj.gradingMidtonesHue / 360),
      clamp01(adj.gradingMidtonesSaturation), 0.5);
    const highlights = hslToRgbLocal(wrap01(adj.gradingHighlightsHue / 360),
      clamp01(adj.gradingHighlightsSaturation), 0.5);
    const global = hslToRgbLocal(wrap01(adj.gradingGlobalHue / 360),
      clamp01(adj.gradingGlobalSaturation), 0.5);
    for (let channel = 0; channel < 3; channel++) {
      p[50 + channel] = shadows[channel];
      p[53 + channel] = midtones[channel];
      p[56 + channel] = highlights[channel];
      p[59 + channel] = global[channel];
    }
    p[62] = adj.gradingShadowsSaturation;
    p[63] = adj.gradingShadowsLuminance;
    p[64] = adj.gradingMidtonesSaturation;
    p[65] = adj.gradingMidtonesLuminance;
    p[66] = adj.gradingHighlightsSaturation;
    p[67] = adj.gradingHighlightsLuminance;
    p[68] = adj.gradingGlobalSaturation;
    p[69] = adj.gradingGlobalLuminance;
  }
  let flags = 0;
  if (adj.temperature !== 0 || adj.tint !== 0) flags |= 1;
  if (adj.highlights !== 0 || adj.shadows !== 0 || adj.whites !== 0 ||
    adj.blacks !== 0) flags |= 2;
  if (adj.vibrance !== 0) flags |= 4;
  if (hasCalibration(adj)) flags |= 8;
  if (hasMixer(adj)) flags |= 16;
  if (grading) flags |= 32;
  if (adj.vignetteAmount !== 0 || adj.grainAmount !== 0) flags |= 64;
  if (hasParametricCurve(adj)) flags |= 128;
  if (hasParametricCurve(adj) && adj.parametricRefineSaturation < 1) flags |= 256;
  p[19] = flags;
  return p;
}

/** Immutable, per-pipeline lookup tables; reused by every export band. */
export function prepareAdvancedTables(adj: WorkerAdjustments): WorkerAdvancedTables {
  const tone = prepareCurve(adj.toneCurvePoints, adj.toneCurve, false);
  const red = prepareCurve(adj.redCurvePoints, adj.curveRed, true);
  const green = prepareCurve(adj.greenCurvePoints, adj.curveGreen, true);
  const blue = prepareCurve(adj.blueCurvePoints, adj.curveBlue, true);
  const exposureGain = Math.pow(2, adj.exposure * 2);
  let tonal: Float32Array | null = null;
  if (adj.highlights !== 0 || adj.shadows !== 0 || adj.whites !== 0 || adj.blacks !== 0) {
    tonal = new Float32Array(1025);
    for (let i = 0; i <= 1024; i++) tonal[i] = applyTonalControls(i / 1024, adj);
  }
  const parametric = hasParametricCurve(adj) ? buildParametricLut(parametricSettings(adj)) : null;
  const fastChannels: Uint8ClampedArray[] = [];
  for (const curve of [red, green, blue]) {
    const table = new Uint8ClampedArray(256);
    for (let value = 0; value < 256; value++) {
      const exposed = exposureGain === 1 ? value / 255 : linearToSrgb(srgbToLinear(value / 255) * exposureGain);
      // Fold the parametric curve into the same table so the per-channel fast
      // path stays exact when refinement is off. One final byte rounding,
      // exactly as in the general float path.
      let curved = evalPrepared(curve, evalPrepared(tone, exposed));
      if (parametric) curved = sampleTable(parametric, curved);
      table[value] = clampByte(curved * 255);
    }
    fastChannels.push(table);
  }
  const nativeCurves = new Float64Array(4 * 1025);
  const curves: PreparedCurveLocal[] = [tone, red, green, blue];
  for (let channel = 0; channel < 4; channel++) {
    const samples = curves[channel].samples;
    for (let index = 0; index < 1025; index++) {
      nativeCurves[channel * 1025 + index] = samples[index];
    }
  }
  const nativeParams = packAdvancedParams(adj);
  return { tone: tone, red: red, green: green, blue: blue, tonal: tonal,
    exposureGain: exposureGain, fastChannels: fastChannels, parametric: parametric,
    nativeParams: nativeParams, nativeCurves: nativeCurves };
}

function prepareCurve(points: number[][], amount: number, channelCurve: boolean): PreparedCurveLocal {
  let ordered = points;
  if (!points || points.length < 2) {
    ordered = [[0, 0], [1, 1]];
  }
  let identity = ordered.length >= 2;
  for (let index = 0; identity && index < ordered.length; index++) {
    identity = Math.abs(ordered[index][0] - ordered[index][1]) < 0.0005;
  }
  ordered = ordered.slice().sort((left: number[], right: number[]) => left[0] - right[0]);
  const samples: number[] = new Array<number>(1025);
  for (let index = 0; index <= 1024; index++) {
    const x = index / 1024;
    let y = smoothCurveYLocal(ordered, x);
    if (identity && amount !== 0) {
      if (channelCurve) y = Math.pow(x, Math.pow(2, -amount * 1.25));
      else if (amount >= 0) y = x + (x * x * (3 - 2 * x) - x) * amount;
      else y = x + (0.18 + x * 0.64 - x) * -amount;
    }
    samples[index] = clamp01(y);
  }
  return {
    samples: samples,
    amount: amount,
    channelCurve: channelCurve,
    useScalar: false,
  };
}

function smoothCurveYLocal(points: number[][], x: number): number {
  if (points.length === 0) return clamp01(x);
  if (x <= points[0][0]) return points[0][1];
  const last = points[points.length - 1];
  if (x >= last[0]) return last[1];
  for (let i = 0; i < points.length - 1; i++) {
    const p1 = points[i];
    const p2 = points[i + 1];
    if (x > p2[0]) continue;
    const h = Math.max(0.00001, p2[0] - p1[0]);
    const tangent = (anchor: number): number => {
      if (anchor <= 0) return (points[1][1] - points[0][1]) /
        Math.max(0.00001, points[1][0] - points[0][0]);
      if (anchor >= points.length - 1) return (points[anchor][1] - points[anchor - 1][1]) /
        Math.max(0.00001, points[anchor][0] - points[anchor - 1][0]);
      const left = (points[anchor][1] - points[anchor - 1][1]) /
        Math.max(0.00001, points[anchor][0] - points[anchor - 1][0]);
      const right = (points[anchor + 1][1] - points[anchor][1]) /
        Math.max(0.00001, points[anchor + 1][0] - points[anchor][0]);
      return left * right <= 0 ? 0 : 2 * left * right / (left + right);
    };
    const t = (x - p1[0]) / h;
    const t2 = t * t;
    const t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * p1[1] + (t3 - 2 * t2 + t) * h * tangent(i) +
      (-2 * t3 + 3 * t2) * p2[1] + (t3 - t2) * h * tangent(i + 1);
  }
  return last[1];
}

function evalPrepared(curve: PreparedCurveLocal, value: number): number {
  const safeValue = clamp01(value);
  if (curve.useScalar) {
    if (curve.channelCurve) {
      if (curve.amount === 0) return safeValue;
      const gamma = Math.pow(2, -curve.amount * 1.25);
      return clamp01(Math.pow(safeValue, gamma));
    }
    if (curve.amount >= 0) {
      const smooth = safeValue * safeValue * (3 - 2 * safeValue);
      return clamp01(safeValue + (smooth - safeValue) * curve.amount);
    }
    const flat = 0.18 + safeValue * 0.64;
    return clamp01(safeValue + (flat - safeValue) * -curve.amount);
  }
  const position = safeValue * 1024;
  const low = position >= 1024 ? 1023 : Math.floor(position);
  const frac = position - low;
  return clamp01(curve.samples[low] + (curve.samples[low + 1] - curve.samples[low]) * frac);
}

function rgbToHslLocal(red: number, green: number, blue: number): number[] {
  const r = clamp01(red);
  const g = clamp01(green);
  const b = clamp01(blue);
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
  return [wrap01(hue), saturation, lightness];
}

function hslToRgbLocal(hue: number, saturation: number, lightness: number): number[] {
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

function applyGradeChannelLocal(value: number, target: number, saturation: number,
  luminance: number, weight: number): number {
  if (weight <= 0 || (saturation === 0 && luminance === 0)) return value;
  const tintAmount = clamp01(Math.abs(saturation) * weight * 0.62);
  const direction = saturation < 0 ? -1 : 1;
  const tinted = value + (target - value) * tintAmount * direction;
  const lift = luminance * weight * 0.28;
  return clamp01(tinted + lift);
}

export function applyAdvancedBand(input: Uint8ClampedArray, adj: WorkerAdjustments, start: number, end: number,
  width: number, height: number, viewport?: number[], pixelOffset: number = 0,
  prepared?: WorkerAdvancedTables): void {
  const tables = prepared ?? prepareAdvancedTables(adj);
  // Which stages are active depends only on `adj`, never on the band. The
  // device render calls this once per 32768-pixel band (80 bands on a zoom
  // tile), so the scans and the three `Math.exp` white-balance gains used to
  // run 80 times per pipeline. Cache the decision on the prepared tables.
  let generalPath = tables.generalPath;
  if (generalPath === undefined) {
    generalPath = hasMixer(adj) || hasCalibration(adj) || hasGrading(adj) ||
      adj.vignetteAmount !== 0 || adj.grainAmount !== 0 ||
      adj.highlights !== 0 || adj.shadows !== 0 || adj.whites !== 0 || adj.blacks !== 0 ||
      adj.temperature !== 0 || adj.tint !== 0 || adj.vibrance !== 0 ||
      (hasParametricCurve(adj) && adj.parametricRefineSaturation < 1);
    tables.generalPath = generalPath;
  }
  // The per-channel fast path folds the parametric curve into its tables, but
  // refinement compares the pixel's before/after saturation, which a
  // per-channel table cannot express, so refinement forces the general path.
  if (!generalPath) {
    const redLut = tables.fastChannels[0];
    const greenLut = tables.fastChannels[1];
    const blueLut = tables.fastChannels[2];
    for (let index = start; index < end; index += 4) {
      input[index] = redLut[input[index]];
      input[index + 1] = greenLut[input[index + 1]];
      input[index + 2] = blueLut[input[index + 2]];
    }
    return;
  }

  // Native first. The general path is the measured bottleneck: on a 2.8 MP
  // zoom tile the ArkTS loop took 13.9 s (mixer HSL + vignette pow/noise),
  // while every already-native stage together took 56 ms. The native twin runs
  // the same double arithmetic; tables are built above, not here.
  const nativeParams = tables.nativeParams;
  nativeParams[16] = width;
  nativeParams[17] = height;
  nativeParams[18] = pixelOffset;
  // Refill one cached view instead of allocating a Float64Array per band. The
  // native call is synchronous and does not retain the view.
  let nativeViewport: Float64Array | null = tables.nativeViewport ?? null;
  if (viewport && viewport.length === 6) {
    if (nativeViewport === null) {
      nativeViewport = new Float64Array(6);
      tables.nativeViewport = nativeViewport;
    }
    for (let index = 0; index < 6; index++) nativeViewport[index] = viewport[index];
  }
  if (nativeAdvancedBand(input, start, end, nativeParams, tables.nativeCurves,
    tables.tonal, tables.parametric, nativeViewport)) {
    return;
  }

  // ArkTS fallback only: these gains are already packed into nativeParams.
  const whiteBalance = adj.temperature !== 0 || adj.tint !== 0;
  const vibrance = adj.vibrance !== 0;
  // White-balance gains depend only on the parameters, never on a pixel.
  // tint is the GREEN/MAGENTA axis: positive tint = green, matching the slider
  // gradient. It used to raise red+blue (magenta) and was scaled twice, so the
  // direction disagreed with the UI and the effect was ~16x weaker than
  // temperature. Keep this formula byte-identical to
  // GpuShaderBridge.whiteBalanceGain and to both white-balance picker cores.
  const warmth = adj.temperature * 0.22;
  const tintGreen = adj.tint * 0.24;
  const rawRedGain = Math.exp(warmth - tintGreen * 0.5);
  const rawGreenGain = Math.exp(tintGreen);
  const rawBlueGain = Math.exp(-warmth - tintGreen * 0.5);
  const wbNormalise = 1 / Math.max(0.00001, rawRedGain * LumR + rawGreenGain * LumG + rawBlueGain * LumB);
  const wbRed = rawRedGain * wbNormalise, wbGreen = rawGreenGain * wbNormalise, wbBlue = rawBlueGain * wbNormalise;
  const mixer = hasMixer(adj);
  const calibration = hasCalibration(adj);
  const grading = hasGrading(adj);
  const effects = adj.vignetteAmount !== 0 || adj.grainAmount !== 0;
  const tonal = adj.highlights !== 0 || adj.shadows !== 0 || adj.whites !== 0 || adj.blacks !== 0;
  const refineActive = hasParametricCurve(adj) && adj.parametricRefineSaturation < 1;

  const toneCurve = tables.tone;
  const redCurve = tables.red;
  const greenCurve = tables.green;
  const blueCurve = tables.blue;
  const shadowTarget = grading ?
    hslToRgbLocal(wrap01(adj.gradingShadowsHue / 360), clamp01(adj.gradingShadowsSaturation), 0.5) : [0, 0, 0];
  const midtoneTarget = grading ?
    hslToRgbLocal(wrap01(adj.gradingMidtonesHue / 360), clamp01(adj.gradingMidtonesSaturation), 0.5) : [0, 0, 0];
  const highlightTarget = grading ?
    hslToRgbLocal(wrap01(adj.gradingHighlightsHue / 360), clamp01(adj.gradingHighlightsSaturation), 0.5) : [0, 0, 0];
  const globalTarget = grading ?
    hslToRgbLocal(wrap01(adj.gradingGlobalHue / 360), clamp01(adj.gradingGlobalSaturation), 0.5) : [0, 0, 0];

  for (let index = start; index < end; index += 4) {
    let red = input[index] / 255;
    let green = input[index + 1] / 255;
    let blue = input[index + 2] / 255;

    // Exposure and relative WB share one linear-light step, with no
    // intermediate sRGB clipping between their multiplicative gains.
    if (tables.exposureGain !== 1 || whiteBalance) {
      red = linearToSrgb(srgbToLinear(red) * tables.exposureGain * (whiteBalance ? wbRed : 1));
      green = linearToSrgb(srgbToLinear(green) * tables.exposureGain * (whiteBalance ? wbGreen : 1));
      blue = linearToSrgb(srgbToLinear(blue) * tables.exposureGain * (whiteBalance ? wbBlue : 1));
    }

    // Tone ranges use a smooth luminance mask. Unlike the old affine matrix,
    // highlights cannot lift deep shadows and blacks cannot change the white point.
    if (tonal) {
      const luminance = clamp01(red * LumR + green * LumG + blue * LumB);
      const position = luminance * 1024;
      const low = Math.min(1023, Math.floor(position));
      const tonalTable = tables.tonal;
      const target = tonalTable ? tonalTable[low] +
        (tonalTable[low + 1] - tonalTable[low]) * (position - low) : luminance;
      if (luminance > 0.00001) {
        const gain = target / luminance;
        red = clamp01(red * gain);
        green = clamp01(green * gain);
        blue = clamp01(blue * gain);
      } else if (target > 0) {
        red = target;
        green = target;
        blue = target;
      }
    }

    if (vibrance) {
      const hsl = rgbToHslLocal(red, green, blue);
      if (adj.vibrance > 0) {
        hsl[1] = clamp01(hsl[1] + (1 - hsl[1]) * adj.vibrance * 0.80);
      } else {
        hsl[1] = clamp01(hsl[1] * (1 + adj.vibrance * 0.70));
      }
      const vivid = hslToRgbLocal(hsl[0], hsl[1], hsl[2]);
      red = vivid[0];
      green = vivid[1];
      blue = vivid[2];
    }

    if (calibration) {
      const sourceRed = red;
      const sourceGreen = green;
      const sourceBlue = blue;
      red += adj.calibrationRedSaturation * (sourceRed - (sourceGreen + sourceBlue) * 0.5) * 0.45;
      green += adj.calibrationGreenSaturation * (sourceGreen - (sourceRed + sourceBlue) * 0.5) * 0.45;
      blue += adj.calibrationBlueSaturation * (sourceBlue - (sourceRed + sourceGreen) * 0.5) * 0.45;
      green += sourceRed * adj.calibrationRedHue * 0.14 - sourceBlue * adj.calibrationBlueHue * 0.07;
      blue -= sourceRed * adj.calibrationRedHue * 0.14 - sourceGreen * adj.calibrationGreenHue * 0.07;
      red += sourceGreen * adj.calibrationGreenHue * 0.14 - sourceBlue * adj.calibrationBlueHue * 0.07;
    }

    if (mixer) {
      const hsl = rgbToHslLocal(red, green, blue);
      hsl[0] = wrap01(hsl[0] + blendedMixerValue(adj.mixHue, hsl[0]) * (24 / 360));
      hsl[1] = clamp01(hsl[1] * (1 + blendedMixerValue(adj.mixSaturation, hsl[0])));
      hsl[2] = clamp01(hsl[2] + blendedMixerValue(adj.mixLuminance, hsl[0]) * 0.32);
      const mixed = hslToRgbLocal(hsl[0], hsl[1], hsl[2]);
      red = mixed[0];
      green = mixed[1];
      blue = mixed[2];
    }

    red = evalPrepared(toneCurve, red);
    green = evalPrepared(toneCurve, green);
    blue = evalPrepared(toneCurve, blue);
    red = evalPrepared(redCurve, red);
    green = evalPrepared(greenCurve, green);
    blue = evalPrepared(blueCurve, blue);

    // Parametric curve sits in the same tone-curve stage as Camera Raw's, after
    // the master and per-channel point curves.
    const parametricLut = tables.parametric;
    if (parametricLut) {
      const beforeRed = red, beforeGreen = green, beforeBlue = blue;
      red = sampleTable(parametricLut, red);
      green = sampleTable(parametricLut, green);
      blue = sampleTable(parametricLut, blue);
      // Refinement is measured from THIS pixel's before/after saturation rather
      // than from the curve's slope at the pixel's luminance. The curve is
      // applied per channel, so a colour can gain saturation while its
      // luminance sits outside the steep region; a luminance-indexed factor
      // would be 1 there and silently fail to refine it (measured: 59% of the
      // colours the curve affects). Measuring the actual change is exact.
      const refineAmount = adj.parametricRefineSaturation;
      if (refineAmount < 1) {
        const beforeSaturation = saturationOf(beforeRed, beforeGreen, beforeBlue);
        const afterSaturation = saturationOf(red, green, blue);
        const scale = parametricRefineScale(beforeSaturation, afterSaturation, refineAmount);
        if (scale !== 1) {
          const curvedLuminance = clamp01(red * LumR + green * LumG + blue * LumB);
          red = clamp01(curvedLuminance + (red - curvedLuminance) * scale);
          green = clamp01(curvedLuminance + (green - curvedLuminance) * scale);
          blue = clamp01(curvedLuminance + (blue - curvedLuminance) * scale);
        }
      }
    }

    if (grading) {
      const luminance = clamp01(0.2126 * red + 0.7152 * green + 0.0722 * blue);
      const shadowWeight = clamp01(1 - luminance * 2.0);
      const highlightWeight = clamp01((luminance - 0.5) * 2.0);
      const midtoneWeight = clamp01(1 - Math.abs(luminance - 0.5) * 2.0);
      const balance = adj.gradingBalance;
      const shadowAdjusted = clamp01(shadowWeight *
        (1 - Math.max(0, balance) * 0.65 + Math.max(0, -balance) * 0.65));
      const highlightAdjusted = clamp01(highlightWeight *
        (1 + Math.max(0, balance) * 0.65 - Math.max(0, -balance) * 0.65));
      const midtoneAdjusted = clamp01(midtoneWeight *
        (0.78 + (1 - Math.abs(balance)) * 0.22));
      const blend = 0.55 + adj.gradingBlending * 0.45;

      let weight = shadowAdjusted * blend;
      red = applyGradeChannelLocal(red, shadowTarget[0], adj.gradingShadowsSaturation, adj.gradingShadowsLuminance, weight);
      green = applyGradeChannelLocal(green, shadowTarget[1], adj.gradingShadowsSaturation, adj.gradingShadowsLuminance, weight);
      blue = applyGradeChannelLocal(blue, shadowTarget[2], adj.gradingShadowsSaturation, adj.gradingShadowsLuminance, weight);

      weight = midtoneAdjusted * blend;
      red = applyGradeChannelLocal(red, midtoneTarget[0], adj.gradingMidtonesSaturation, adj.gradingMidtonesLuminance, weight);
      green = applyGradeChannelLocal(green, midtoneTarget[1], adj.gradingMidtonesSaturation, adj.gradingMidtonesLuminance, weight);
      blue = applyGradeChannelLocal(blue, midtoneTarget[2], adj.gradingMidtonesSaturation, adj.gradingMidtonesLuminance, weight);

      weight = highlightAdjusted * blend;
      red = applyGradeChannelLocal(red, highlightTarget[0], adj.gradingHighlightsSaturation, adj.gradingHighlightsLuminance, weight);
      green = applyGradeChannelLocal(green, highlightTarget[1], adj.gradingHighlightsSaturation, adj.gradingHighlightsLuminance, weight);
      blue = applyGradeChannelLocal(blue, highlightTarget[2], adj.gradingHighlightsSaturation, adj.gradingHighlightsLuminance, weight);

      weight = 0.52 * blend;
      red = applyGradeChannelLocal(red, globalTarget[0], adj.gradingGlobalSaturation, adj.gradingGlobalLuminance, weight);
      green = applyGradeChannelLocal(green, globalTarget[1], adj.gradingGlobalSaturation, adj.gradingGlobalLuminance, weight);
      blue = applyGradeChannelLocal(blue, globalTarget[2], adj.gradingGlobalSaturation, adj.gradingGlobalLuminance, weight);
    }

    input[index] = clampByte(red * 255);
    input[index + 1] = clampByte(green * 255);
    input[index + 2] = clampByte(blue * 255);
    if (effects) {
      const absolutePixel = index / 4 + pixelOffset;
      const x = absolutePixel % width, y = Math.floor(absolutePixel / width);
      if (viewport && viewport.length === 6) {
        applySpatialEffects(input, index, adj, viewport[0] + (x + 0.5) * viewport[2] - 0.5,
          viewport[1] + (y + 0.5) * viewport[3] - 0.5, viewport[4], viewport[5]);
      } else applySpatialEffects(input, index, adj, x, y, width, height);
    }
  }
}

/** Apply four Lightroom-style tonal controls with smooth, overlapping ranges. */
function applyTonalControls(luminance: number, adj: WorkerAdjustments): number {
  let value = luminance;
  value = applyTonalRange(value, adj.shadows, 1 - smoothStep(0.16, 0.58, value), 0.62);
  value = applyTonalRange(value, adj.blacks, 1 - smoothStep(0.025, 0.27, value), 0.78);
  value = applyTonalRange(value, adj.highlights, smoothStep(0.42, 0.88, value), 0.62);
  value = applyTonalRange(value, adj.whites, smoothStep(0.72, 0.985, value), 0.78);
  return clamp01(value);
}

function applyTonalRange(value: number, amount: number, weight: number, strength: number): number {
  if (amount === 0 || weight <= 0) return value;
  const delta = amount >= 0 ? (1 - value) * amount : value * amount;
  return clamp01(value + delta * weight * strength);
}

function srgbToLinear(value: number): number {
  const safe = clamp01(value);
  return safe <= 0.04045 ? safe / 12.92 : Math.pow((safe + 0.055) / 1.055, 2.4);
}

function linearToSrgb(value: number): number {
  const safe = Math.max(0, value);
  return clamp01(safe <= 0.0031308 ? safe * 12.92 : 1.055 * Math.pow(safe, 1 / 2.4) - 0.055);
}

/** Blend the nearest two HSL hue controls so the eight bands have no seams. */
function blendedMixerValue(values: number[], hue: number): number {
  const position = wrap01(hue) * 8;
  const lower = Math.floor(position);
  const upper = (lower + 1) % 8;
  return (values[lower] ?? 0) + ((values[upper] ?? 0) - (values[lower] ?? 0)) * (position - lower);
}

function smoothStep(edge0: number, edge1: number, value: number): number {
  const t = clamp01((value - edge0) / Math.max(0.0001, edge1 - edge0));
  return t * t * (3 - 2 * t);
}

// ---------------------------------------------------------------------------
// 蒙版渲染（与 MaskRenderer 语义一致）
// ---------------------------------------------------------------------------

export function renderMask(mask: WorkerMask, width: number, height: number): Uint8ClampedArray {
  let buffer: Uint8ClampedArray;
  if (mask.type === 1) {
    buffer = new Uint8ClampedArray(width * height);
    for (const stroke of mask.strokes) {
      if (stroke.points.length === 0) continue;
      const strokeBuffer = renderStroke(stroke, width, height);
      combineStroke(buffer, strokeBuffer, stroke.mode);
    }
  } else if (mask.type === 2) {
    buffer = renderLinear(mask, width, height);
  } else if (mask.type === 3) {
    buffer = renderRadial(mask, width, height);
  } else {
    buffer = new Uint8ClampedArray(width * height);
    buffer.fill(255);
  }
  if (mask.feather > 0 || mask.invert) {
    postProcess(buffer, width, height, mask.feather, mask.invert);
  }
  return buffer;
}

function renderStroke(stroke: WorkerStroke, width: number, height: number): Uint8ClampedArray {
  const buffer = new Uint8ClampedArray(width * height);
  for (let index = 0; index < stroke.points.length; index++) {
    const a = stroke.points[index];
    const b = stroke.points[Math.min(index + 1, stroke.points.length - 1)];
    rasterizeBrushSegment(buffer, width, height, a.x, a.y, a.radius, a.hardness,
      b.x, b.y, b.radius, b.hardness);
  }
  return buffer;
}

function combineStroke(target: Uint8ClampedArray, stroke: Uint8ClampedArray, mode: number): void {
  const len = target.length;
  if (mode === 1) {
    for (let i = 0; i < len; i++) {
      target[i] = Math.max(0, Math.round(target[i] * (255 - stroke[i]) / 255));
    }
  } else if (mode === 2) {
    for (let i = 0; i < len; i++) {
      target[i] = Math.round(target[i] * stroke[i] / 255);
    }
  } else {
    for (let i = 0; i < len; i++) {
      if (stroke[i] > target[i]) target[i] = stroke[i];
    }
  }
}

function renderLinear(mask: WorkerMask, width: number, height: number): Uint8ClampedArray {
  const buffer = new Uint8ClampedArray(width * height);
  const sx = mask.linear[0] * width;
  const sy = mask.linear[1] * height;
  const ex = mask.linear[2] * width;
  const ey = mask.linear[3] * height;
  // Feather widens the single transition boundary around the midpoint.
  // Keep this in lock-step with MaskRenderer; the old two-branch formula
  // jumped from zero back to full opacity at t=.5.
  const feather = Math.max(0, Math.min(0.5, mask.linear[4]));
  const transitionStart = 0.5 - feather;
  const transitionEnd = 0.5 + feather;
  const dx = ex - sx;
  const dy = ey - sy;
  const len2 = dx * dx + dy * dy;
  if (len2 < 1) {
    buffer.fill(255);
    return buffer;
  }
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const px = x - sx;
      const py = y - sy;
      let t = (px * dx + py * dy) / len2;
      t = Math.max(0, Math.min(1, t));
      let alpha: number;
      if (feather <= 0.0001) {
        alpha = t < 0.5 ? 255 : 0;
      } else if (t <= transitionStart) {
        alpha = 255;
      } else if (t >= transitionEnd) {
        alpha = 0;
      } else {
        alpha = Math.round(255 * (1 - (t - transitionStart) /
          Math.max(0.0001, transitionEnd - transitionStart)));
      }
      buffer[y * width + x] = Math.max(0, Math.min(255, alpha));
    }
  }
  return buffer;
}

function renderRadial(mask: WorkerMask, width: number, height: number): Uint8ClampedArray {
  const buffer = new Uint8ClampedArray(width * height);
  const cx = mask.radial[0] * width;
  const cy = mask.radial[1] * height;
  const rx = (mask.radial[3] > 0 ? mask.radial[3] : mask.radial[2]) * width;
  const ry = (mask.radial[4] > 0 ? mask.radial[4] : mask.radial[2]) * height;
  const feather = Math.max(0, Math.min(1, mask.radial[5]));
  const innerT = 1 - feather;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const nx = (x - cx) / Math.max(1, rx);
      const ny = (y - cy) / Math.max(1, ry);
      const dist = Math.sqrt(nx * nx + ny * ny);
      let alpha: number;
      if (feather <= 0.0001) {
        alpha = dist <= 1 ? 255 : 0;
      } else if (dist <= innerT) {
        alpha = 255;
      } else if (dist >= 1) {
        alpha = 0;
      } else {
        alpha = Math.round(255 * (1 - (dist - innerT) / feather));
      }
      buffer[y * width + x] = alpha;
    }
  }
  return buffer;
}

function postProcess(buffer: Uint8ClampedArray, width: number, height: number,
  feather: number, invert: boolean): void {
  if (feather > 0) {
    const radius = Math.max(1, Math.round(feather * Math.min(width, height) * 0.5));
    const horizontal = new Uint8ClampedArray(buffer.length);
    for (let y = 0; y < height; y++) {
      const row = y * width;
      let sum = 0;
      let count = 0;
      for (let sample = 0; sample <= Math.min(width - 1, radius); sample++) {
        sum += buffer[row + sample];
        count++;
      }
      for (let x = 0; x < width; x++) {
        horizontal[row + x] = Math.round(sum / Math.max(1, count));
        const remove = x - radius;
        const add = x + radius + 1;
        if (remove >= 0) { sum -= buffer[row + remove]; count--; }
        if (add < width) { sum += buffer[row + add]; count++; }
      }
    }
    for (let x = 0; x < width; x++) {
      let sum = 0;
      let count = 0;
      for (let sample = 0; sample <= Math.min(height - 1, radius); sample++) {
        sum += horizontal[sample * width + x];
        count++;
      }
      for (let y = 0; y < height; y++) {
        buffer[y * width + x] = Math.round(sum / Math.max(1, count));
        const remove = y - radius;
        const add = y + radius + 1;
        if (remove >= 0) { sum -= horizontal[remove * width + x]; count--; }
        if (add < height) { sum += horizontal[add * width + x]; count++; }
      }
    }
  }
  if (invert) {
    for (let i = 0; i < buffer.length; i++) {
      buffer[i] = 255 - buffer[i];
    }
  }
}

// ---------------------------------------------------------------------------
// 合成与几何
// ---------------------------------------------------------------------------

function compositeBand(result: Uint8ClampedArray, base: Uint8ClampedArray,
  adjusted: Uint8ClampedArray, mask: Uint8ClampedArray | null, opacity: number,
  blendMode: number, start: number, end: number, pixelOffset: number = 0): void {
  for (let i = start; i < end; i += 4) {
    const maskAlpha = mask ? mask[(i >> 2) + pixelOffset] / 255 : 1.0;
    const effectiveAlpha = maskAlpha * opacity;
    if (effectiveAlpha <= 0) continue;
    const srcR = adjusted[i];
    const srcG = adjusted[i + 1];
    const srcB = adjusted[i + 2];
    const baseR = base[i];
    const baseG = base[i + 1];
    const baseB = base[i + 2];
    let blendedR: number, blendedG: number, blendedB: number;
    if (blendMode === 1) {
      blendedR = (baseR * srcR) / 255;
      blendedG = (baseG * srcG) / 255;
      blendedB = (baseB * srcB) / 255;
    } else if (blendMode === 2) {
      blendedR = 255 - ((255 - baseR) * (255 - srcR)) / 255;
      blendedG = 255 - ((255 - baseG) * (255 - srcG)) / 255;
      blendedB = 255 - ((255 - baseB) * (255 - srcB)) / 255;
    } else if (blendMode === 3) {
      blendedR = baseR < 128 ? (2 * baseR * srcR) / 255 : 255 - (2 * (255 - baseR) * (255 - srcR)) / 255;
      blendedG = baseG < 128 ? (2 * baseG * srcG) / 255 : 255 - (2 * (255 - baseG) * (255 - srcG)) / 255;
      blendedB = baseB < 128 ? (2 * baseB * srcB) / 255 : 255 - (2 * (255 - baseB) * (255 - srcB)) / 255;
    } else {
      blendedR = srcR;
      blendedG = srcG;
      blendedB = srcB;
    }
    if (effectiveAlpha >= 1) {
      result[i] = clampByte(blendedR);
      result[i + 1] = clampByte(blendedG);
      result[i + 2] = clampByte(blendedB);
    } else {
      result[i] = clampByte(result[i] + (blendedR - result[i]) * effectiveAlpha);
      result[i + 1] = clampByte(result[i + 1] + (blendedG - result[i + 1]) * effectiveAlpha);
      result[i + 2] = clampByte(result[i + 2] + (blendedB - result[i + 2]) * effectiveAlpha);
    }
  }
}

export function applyGeometryFull(input: Uint8ClampedArray, width: number, height: number,
  params: ProcessParams): GeometryLocal {
  input = transformGeometry(input, width, height, params.geometry,
    params.referenceWidth ?? 0, params.referenceHeight ?? 0);
  const map = geometryMapForParams(params, width, height);
  if (params.deferRemap) {
    // 主线程会用同一个 geometryMapForParams 重建 map，再走 native 的整数
    // 重映射。这里只返回旋转前的帧，省掉两张 Int32 采样表（44MP 下 354MB
    // 写入）和一次全幅拷贝，宽度/高度保持与缓冲一致。
    return { pixels: input, width: width, height: height };
  }
  const output = new Uint8ClampedArray(map.outputWidth * map.outputHeight * 4);
  // Crop/rotate/flip resampling looks its source pixel up in the same geometry
  // map the overlay and touch input invert, so a mark drawn on the canvas and
  // the pixel it edits can never belong to two different transforms.
  remapFrameToDisplay(input, map, output, buildFrameSampleTable(map));
  return { pixels: output, width: map.outputWidth, height: map.outputHeight };
}

/** Crop/rotate/flip bounds for one job. Shared by the TaskPool geometry stage
 * and by the native remap the main thread runs when the worker defers it, so
 * both derive identical bounds from the same parameters. */
export function geometryMapForParams(params: ProcessParams, width: number, height: number): GeometryMap {
  return buildGeometryMap(params.geometry, width, height, {
    width: width, height: height,
    cropLeft: params.ignoreCrop ? 0 : params.cropLeft,
    cropTop: params.ignoreCrop ? 0 : params.cropTop,
    cropRight: params.ignoreCrop ? 1 : params.cropRight,
    cropBottom: params.ignoreCrop ? 1 : params.cropBottom,
    rotation: params.rotation, flipH: params.flipH, flipV: params.flipV,
  }, {
    referenceWidth: params.referenceWidth ?? width,
    referenceHeight: params.referenceHeight ?? height,
  });
}

function wrap01(value: number): number {
  return ((value % 1) + 1) % 1;
}

function clampByte(v: number): number {
  return Math.max(0, Math.min(255, Math.round(v)));
}
