/**
 * Thin ArkTS wrapper around the native layer composition module
 * (`libvivid_composite.so`).
 *
 * Why this exists: `WorkerCore.applyLayerBandFull` walks every visible layer
 * three times per band in interpreted ArkTS (colour matrix, mask-alpha blend,
 * blend-mode composite) and a 512x341 preview spent ~400 ms there. The native
 * module runs the identical arithmetic from `vivid_composite_core.cpp`.
 *
 * Responsibilities, deliberately kept to these:
 *  - load the module and answer `nativeCompositeReady()` once;
 *  - pass the band views straight through (no copies, no offset arithmetic);
 *  - log `VIVID_NATIVE_COMPOSITE fallback reason=...` and return false when the
 *    module is missing, an export is absent, the call throws, or the native side
 *    rejects the arguments. The caller (`WorkerCore`) then runs the ArkTS loop,
 *    so a device without this library still renders correctly.
 *
 * It contains NO algorithm: the reference stays in WorkerCore.ets, the port
 * stays in vivid_composite_core.cpp, and both are compared byte-for-byte by
 * tools/check_composite_native_parity.cjs.
 */
import compositeNative from 'libvivid_composite.so';
import { PointColorSample } from './PointColorCore';
import { OkLChParams } from './OkLChCore';

const REASON_NO_EXPORT: string = 'noExport';
const REASON_REJECTED: string = 'nativeRejected';
const REASON_THREW: string = 'callThrew';

/** Structural LUT view: WorkerLut already has exactly these fields, but keeping
 * the interface local avoids a runtime import cycle
 * WorkerCore -> NativeComposite -> ProcessWorker -> WorkerCore. */
export interface NativeLutInput {
  enabled: boolean;
  intensity: number;
  size: number;
  values: number[];
  domainMin: number[];
  domainMax: number[];
}

/** Flattened LUT stack payload shared by production and the parity probe. */
export interface NativeLutPayload {
  values: Float64Array;
  meta: Float64Array;
}

const reported: string[] = [];
const pointwiseReported: string[] = [];
const lutRejectReported: string[] = [];
let lutServedLogged: boolean = false;
let readyLogged: boolean = false;
let ready: boolean = false;

function moduleUsable(): boolean {
  return typeof compositeNative.matrixBand === 'function' &&
    typeof compositeNative.maskBlend === 'function' &&
    typeof compositeNative.composite === 'function';
}

/**
 * True when the native composition loops can be called. Safe to call repeatedly.
 *
 * The answer was recomputed on **every band** (`moduleUsable()` reads three
 * properties of the N-API module object, i.e. three runtime crossings). An
 * 80-band tile called it three times per band per pipeline. A shared library's
 * export table cannot appear or disappear while the process runs, so the first
 * probe is authoritative; `probed` keeps a missing module from being re-checked
 * on every pixel band as well.
 */
let probed: boolean = false;

export function nativeCompositeReady(): boolean {
  if (probed) return ready;
  probed = true;
  ready = moduleUsable();
  if (ready && !readyLogged) {
    readyLogged = true;
    let version: number = 0;
    try {
      version = compositeNative.apiVersion();
    } catch (error) {
      version = 0;
    }
    console.info(`VIVID_NATIVE_COMPOSITE ready abi=${version}`);
  }
  return ready;
}

/** Log each distinct fallback reason once, so a 30 fps preview cannot flood hilog. */
function reportFallback(reason: string, detail: string = ''): void {
  const key = `${reason}|${detail}`;
  for (const seen of reported) {
    if (seen === key) return;
  }
  reported.push(key);
  console.warn(`VIVID_NATIVE_COMPOSITE fallback reason=${reason}` +
    (detail.length > 0 ? ` detail=${detail}` : ''));
}

/** Same once-per-reason rule, but under the pointwise namespace so the two
 * diagnostics stay distinguishable in hilog. */
function reportPointwiseFallback(reason: string, detail: string = ''): void {
  const key = `${reason}|${detail}`;
  for (const seen of pointwiseReported) {
    if (seen === key) return;
  }
  pointwiseReported.push(key);
  console.warn(`VIVID_NATIVE_POINTWISE fallback reason=${reason}` +
    (detail.length > 0 ? ` detail=${detail}` : ''));
}

/** `output = clampByte(matrix * input)` over `[start, end)`; false means "run ArkTS". */
export function nativeMatrixBand(input: Uint8ClampedArray, matrix: Float32Array,
  output: Uint8ClampedArray, start: number, end: number): boolean {
  if (!nativeCompositeReady()) {
    reportFallback(REASON_NO_EXPORT, 'matrix');
    return false;
  }
  try {
    const done: boolean = compositeNative.matrixBand(input, matrix, output, start, end);
    if (!done) reportFallback(REASON_REJECTED, 'matrix');
    return done;
  } catch (error) {
    reportFallback(REASON_THREW, `matrix:${(error as Error).message ?? error}`);
    return false;
  }
}

/** Mask-alpha blend of `adjusted` towards `maskAdjusted`, in place. */
export function nativeMaskBlend(adjusted: Uint8ClampedArray, maskAdjusted: Uint8ClampedArray,
  mask: Uint8ClampedArray, start: number, end: number, pixelOffset: number): boolean {
  if (!nativeCompositeReady()) {
    reportFallback(REASON_NO_EXPORT, 'maskBlend');
    return false;
  }
  try {
    const done: boolean = compositeNative.maskBlend(adjusted, maskAdjusted, mask, start, end, pixelOffset);
    if (!done) reportFallback(REASON_REJECTED, 'maskBlend');
    return done;
  } catch (error) {
    reportFallback(REASON_THREW, `maskBlend:${(error as Error).message ?? error}`);
    return false;
  }
}

/** Blend `adjusted` into `result` with the layer's mask, opacity and blend mode. */
export function nativeCompositeBand(result: Uint8ClampedArray, base: Uint8ClampedArray,
  adjusted: Uint8ClampedArray, mask: Uint8ClampedArray | null, opacity: number,
  blendMode: number, start: number, end: number, pixelOffset: number): boolean {
  if (!nativeCompositeReady()) {
    reportFallback(REASON_NO_EXPORT, 'composite');
    return false;
  }
  try {
    const done: boolean = compositeNative.composite(result, base, adjusted, mask, opacity, blendMode,
      start, end, pixelOffset);
    if (!done) reportFallback(REASON_REJECTED, 'composite');
    return done;
  } catch (error) {
    reportFallback(REASON_THREW, `composite:${(error as Error).message ?? error}`);
    return false;
  }
}

/**
 * Flatten an ordered, already-validated LUT stack into the two typed arrays the
 * native core consumes. Kept here (not in WorkerCore) so the parity suite can
 * feed the host probe with exactly the bytes production would send.
 *
 * meta layout per LUT: size, intensity, minR, minG, minB, maxR, maxG, maxB,
 * valueOffset (in doubles).
 */
export function packLutsForNative(luts: NativeLutInput[]): NativeLutPayload {
  let totalValues = 0;
  for (const lut of luts) {
    totalValues += lut.size * lut.size * lut.size * 3;
  }
  const values = new Float64Array(totalValues);
  const meta = new Float64Array(luts.length * 9);
  let valueOffset = 0;
  for (let index = 0; index < luts.length; index++) {
    const lut = luts[index];
    const table = lut.values;
    for (let i = 0; i < table.length; i++) values[valueOffset + i] = table[i];
    const metaOffset = index * 9;
    meta[metaOffset] = lut.size;
    meta[metaOffset + 1] = lut.intensity;
    meta[metaOffset + 2] = lut.domainMin[0];
    meta[metaOffset + 3] = lut.domainMin[1];
    meta[metaOffset + 4] = lut.domainMin[2];
    meta[metaOffset + 5] = lut.domainMax[0];
    meta[metaOffset + 6] = lut.domainMax[1];
    meta[metaOffset + 7] = lut.domainMax[2];
    meta[metaOffset + 8] = valueOffset;
    valueOffset += table.length;
  }
  return { values: values, meta: meta };
}

/** Same 9-double layout as vivid::pointwise::kPointColorStride. */
export function packPointColorForNative(samples: PointColorSample[]): Float64Array {
  const count = samples.length < 8 ? samples.length : 8;
  const packed = new Float64Array(count * 9);
  for (let index = 0; index < count; index++) {
    const sample = samples[index];
    const offset = index * 9;
    packed[offset] = sample.hue;
    packed[offset + 1] = sample.saturation;
    packed[offset + 2] = sample.luminance;
    packed[offset + 3] = sample.hueShift;
    packed[offset + 4] = sample.saturationShift;
    packed[offset + 5] = sample.luminanceShift;
    packed[offset + 6] = sample.hueRange;
    packed[offset + 7] = sample.saturationRange;
    packed[offset + 8] = sample.luminanceRange;
  }
  return packed;
}

/** [lightness, chroma, hue], matching vivid::pointwise::kOkLChStride. */
export function packOklchForNative(params: OkLChParams): Float64Array {
  const packed = new Float64Array(3);
  packed[0] = params.lightness;
  packed[1] = params.chroma;
  packed[2] = params.hue;
  return packed;
}

function pointwiseReady(): boolean {
  return typeof compositeNative.lutStack === 'function' &&
    typeof compositeNative.pointColor === 'function' &&
    typeof compositeNative.oklch === 'function';
}

/** True when the native LUT / point-colour / OkLCh entry points are exported. */
export function nativePointwiseReady(): boolean {
  return pointwiseReady();
}

/**
 * Explain a refused LUT payload with the native validator's own reason code.
 * Logged once per distinct reason per worker so a slow frame cannot flood
 * hilog; the fields printed are exactly what the validator looked at.
 */
export function reportLutStackReject(payload: NativeLutPayload, luts: NativeLutInput[]): void {
  let reason: number = -99;
  try {
    if (typeof compositeNative.lutStackReason === 'function') {
      reason = compositeNative.lutStackReason(payload.values, payload.meta);
    }
  } catch (_error) {
    reason = -98;
  }
  const key = `${reason}`;
  for (const seen of lutRejectReported) {
    if (seen === key) return;
  }
  lutRejectReported.push(key);
  const first: NativeLutInput = luts[0];
  const domain: string = first === undefined ? 'none' :
    `${first.domainMin[0]},${first.domainMin[1]},${first.domainMin[2]}` +
    `..${first.domainMax[0]},${first.domainMax[1]},${first.domainMax[2]}`;
  const tail: string = first === undefined ? 'none' :
    `${first.intensity}/${first.size}/${first.values.length}`;
  const valueKind: string = payload.values instanceof Float64Array ? 'float64' : 'other';
  const metaKind: string = payload.meta instanceof Float64Array ? 'float64' : 'other';
  console.warn(`VIVID_NATIVE_POINTWISE reject lutStack reason=${reason}` +
    ` luts=${luts.length} values=${payload.values.length} meta=${payload.meta.length}` +
    ` first=${tail} domain=${domain}` +
    ` valueType=${valueKind} metaType=${metaKind}`);
}

/** Ordered LUT stack from an already-packed payload; false means "run ArkTS". */
export function nativeLutStackPrepared(pixels: Uint8ClampedArray,
  payload: NativeLutPayload): boolean {
  if (!pointwiseReady()) {
    reportPointwiseFallback(REASON_NO_EXPORT, 'lutStack');
    return false;
  }
  try {
    const done: boolean = compositeNative.lutStack(pixels, payload.values, payload.meta);
    if (!done) {
      reportPointwiseFallback(REASON_REJECTED, 'lutStack');
      return false;
    }
    if (!lutServedLogged) {
      lutServedLogged = true;
      console.info(`VIVID_NATIVE_POINTWISE served=1 detail=lutStack` +
        ` values=${payload.values.length} meta=${payload.meta.length} px=${pixels.length >> 2}`);
    }
    return true;
  } catch (error) {
    reportPointwiseFallback(REASON_THREW, `lutStack:${(error as Error).message ?? error}`);
    return false;
  }
}

/** Ordered LUT stack in place; false means "run the ArkTS reference". */
export function nativeLutStack(pixels: Uint8ClampedArray, luts: NativeLutInput[]): boolean {
  if (!pointwiseReady()) {
    reportPointwiseFallback(REASON_NO_EXPORT, 'lutStack');
    return false;
  }
  try {
    const payload = packLutsForNative(luts);
    const done: boolean = nativeLutStackPrepared(pixels, payload);
    if (!done) reportLutStackReject(payload, luts);
    return done;
  } catch (error) {
    reportPointwiseFallback(REASON_THREW, `lutStack:${(error as Error).message ?? error}`);
    return false;
  }
}

/** Point-colour sample stack in place; false means "run the ArkTS reference". */
export function nativePointColor(pixels: Uint8ClampedArray, samples: PointColorSample[]): boolean {
  if (!pointwiseReady()) {
    reportPointwiseFallback(REASON_NO_EXPORT, 'pointColor');
    return false;
  }
  if (samples.length > 8) {
    reportPointwiseFallback(REASON_REJECTED, 'pointColorCount');
    return false;
  }
  try {
    const packed = packPointColorForNative(samples);
    const done: boolean = compositeNative.pointColor(pixels, packed);
    if (!done) reportPointwiseFallback(REASON_REJECTED, 'pointColor');
    return done;
  } catch (error) {
    reportPointwiseFallback(REASON_THREW, `pointColor:${(error as Error).message ?? error}`);
    return false;
  }
}

/** OkLCh grade in place; false means "run the ArkTS reference". */
export function nativeOklch(pixels: Uint8ClampedArray, params: OkLChParams): boolean {
  if (!pointwiseReady()) {
    reportPointwiseFallback(REASON_NO_EXPORT, 'oklch');
    return false;
  }
  try {
    const packed = packOklchForNative(params);
    const done: boolean = compositeNative.oklch(pixels, packed);
    if (!done) reportPointwiseFallback(REASON_REJECTED, 'oklch');
    return done;
  } catch (error) {
    reportPointwiseFallback(REASON_THREW, `oklch:${(error as Error).message ?? error}`);
    return false;
  }
}

/**
 * Native advanced colour band (curves / HSL mixer / calibration / grading /
 * vignette / grain). Deliberately separate from `nativeCompositeReady`: older
 * module builds have the three composition loops but no `advancedBand`, and
 * that must degrade to the ArkTS loop without disabling composition.
 */
export function nativeAdvancedBand(input: Uint8ClampedArray, start: number, end: number,
  params: Float64Array, curves: Float64Array, tonal: Float32Array | null,
  parametric: Float32Array | null, viewport: Float64Array | null): boolean {
  if (typeof compositeNative.advancedBand !== 'function') {
    reportFallback(REASON_NO_EXPORT, 'advancedBand');
    return false;
  }
  try {
    const done: boolean = compositeNative.advancedBand(input, start, end, params, curves,
      tonal, parametric, viewport);
    if (!done) reportFallback(REASON_REJECTED, 'advancedBand');
    return done;
  } catch (error) {
    reportFallback(REASON_THREW, `advancedBand:${(error as Error).message ?? error}`);
    return false;
  }
}
