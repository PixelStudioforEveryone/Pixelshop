/**
 * Native layer composition for the background pixel pipeline.
 *
 * The ArkTS twin (`WorkerCore.applyLayerBandFull` and its `compositeBand` /
 * `applyMatrixBand` loops) stays in the code base as the reference and as the
 * fallback. Both must emit identical bytes; see `vivid_composite_core.h` for the
 * bit-exactness contract and `NativeComposite.ets` for the dispatch.
 *
 * Contract notes for callers:
 *  - every pixel argument is a *view* (`Uint8ClampedArray`), not an
 *    `ArrayBuffer`: the layer loops run on band subviews, and N-API's typed
 *    array info already carries the view's own data pointer.
 *  - `start`/`end` are byte offsets inside those views (the same values
 *    `applyLayerBandFull` receives); `pixelOffset` is the band's pixel offset
 *    into the full-frame mask.
 *  - each function returns `false` when the arguments did not validate. The
 *    caller must then run the ArkTS loop for that call; a `false` is never a
 *    partial write, because validation happens before any pixel is touched.
 */

/** `output = clampByte(matrix * input)` over `[start, end)` bytes. */
export function matrixBand(input: Uint8ClampedArray, matrix: Float32Array,
  output: Uint8ClampedArray, start: number, end: number): boolean;

/** Blend `adjusted` towards `maskAdjusted` by the mask alpha, in place. */
export function maskBlend(adjusted: Uint8ClampedArray, maskAdjusted: Uint8ClampedArray,
  mask: Uint8ClampedArray, start: number, end: number, pixelOffset: number): boolean;

/**
 * Blend `adjusted` into `result` (normal / multiply / screen / overlay, alpha
 * from the optional mask times `opacity`).
 */
export function composite(result: Uint8ClampedArray, base: Uint8ClampedArray,
  adjusted: Uint8ClampedArray, mask: Uint8ClampedArray | null, opacity: number,
  blendMode: number, start: number, end: number, pixelOffset: number): boolean;

/**
 * Native twin of `WorkerCore.applyAdvancedBand`'s general path (curves, HSL
 * mixer, calibration, colour grading, vignette, grain). `params` is the packed
 * 70-double layout documented in vivid_advanced_core.cpp, `curves` 4 x 1025
 * doubles (master/red/green/blue), `tonal` 1025 floats (or null), `parametric`
 * 256 floats (or null), `viewport` 6 doubles (or null). Returns false when the
 * arguments do not validate, before touching a pixel; the caller then runs the
 * ArkTS reference for that band.
 */
export function advancedBand(input: Uint8ClampedArray, start: number, end: number,
  params: Float64Array, curves: Float64Array, tonal: Float32Array | null,
  parametric: Float32Array | null, viewport: Float64Array | null): boolean;

/**
 * Ordered LUT stack, in place. `values` is the concatenated RGB tables and
 * `meta` carries nine doubles per LUT: size, intensity, minR, minG, minB,
 * maxR, maxG, maxB, valueOffset. Returns false before touching a pixel when
 * the payload does not validate; the caller then runs the ArkTS reference.
 */
export function lutStack(pixels: Uint8ClampedArray, values: Float64Array,
  meta: Float64Array): boolean;

/**
 * Diagnostic twin of `lutStack`: validates the same payload without touching
 * pixels and returns 0 when `lutStack` would accept it, one of the stable
 * kLutStack* codes when it would not, -1 for unreadable arguments and -2 for a
 * meta array whose length is not a multiple of nine.
 */
export function lutStackReason(values: Float64Array, meta: Float64Array): number;

/** HSL point-colour sample stack, in place (nine doubles per sample). */
export function pointColor(pixels: Uint8ClampedArray, samples: Float64Array): boolean;

/** OkLCh grade, in place (`params` is [lightness, chroma, hue]). */
export function oklch(pixels: Uint8ClampedArray, params: Float64Array): boolean;

/** ABI version of this module; used to log which build is running. */
export function apiVersion(): number;
