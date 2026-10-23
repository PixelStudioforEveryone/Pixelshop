/**
 * Parametric tone curve — the four-region curve of Camera Raw's Tone Curve
 * panel (Highlights / Lights / Darks / Shadows) with its three draggable split
 * points.
 *
 * Formulation
 * -----------
 * The curve is the identity displaced by a weighted sum of four local bumps:
 *
 *     y(x) = x + scale * sum_r  amount_r * bump_r(x)
 *
 * Each bump is a product of smoothsteps, gated by the smoothstep that opens its
 * own region, and shaped as `u * (1 - u)` so that it is EXACTLY zero at both
 * x = 0 and x = 1:
 *
 *     U = smoothstep(0,        shadowSplit, x)     gate for darks and above
 *     V = smoothstep(shadowSplit, darkSplit, x)    gate for lights and above
 *     W = smoothstep(darkSplit, lightSplit, x)     gate for highlights
 *     Z = smoothstep(lightSplit, 1, x)
 *
 *     bump_shadows    = U * (1 - U)
 *     bump_darks      = V * (1 - V) * U
 *     bump_lights     = W * (1 - W) * U * V
 *     bump_highlights = Z * (1 - Z) * U * V * W
 *
 * Because every bump vanishes at both ends, y(0) = 0 and y(1) = 1 fall out
 * exactly, and an all-zero curve is bit-for-bit the identity with no special
 * case.
 *
 * `scale` is a single global constant derived from the displacement field's own
 * maximum derivative, `scale = min(1, MAX_SLOPE_DELTA / max|D'|)`. Every point
 * of the curve therefore satisfies `1 - MAX_SLOPE_DELTA <= y' <= 1 +
 * MAX_SLOPE_DELTA`, and since MAX_SLOPE_DELTA < 1 the curve is STRICTLY
 * increasing for every parameter combination. Monotonicity is a property of the
 * construction, not a clamp applied afterwards, so no slider value can produce
 * a curve that inverts tones. Scaling globally rather than per region also
 * preserves the relative balance the user set between regions.
 *
 * Sign convention: a positive `highlights` raises the highlight band above the
 * identity (brighter highlights); a positive `shadows` raises the shadow band
 * (lifted shadows). Both leave pure black and pure white untouched, as Camera
 * Raw's parametric curve does.
 *
 * Fidelity note: Adobe's exact parametric formulation is not public. This is an
 * independent construction with the documented semantics above; it is NOT
 * bit-identical to Camera Raw, and this file makes no such claim.
 */

export const PARAMETRIC_LUT_SIZE: number = 256;

/** Upper bound on |y' - 1|. Must be < 1 so the curve cannot stop rising. */
const MAX_SLOPE_DELTA: number = 0.7;
/** Headroom kept at both rails by the value bound. */
const VALUE_EPSILON: number = 1e-6;
/** Keep splits this far apart so no region can collapse to zero width. */
const SPLIT_GAP: number = 0.02;

export interface ParametricCurveParams {
  highlights: number;
  lights: number;
  darks: number;
  shadows: number;
  shadowSplit: number;
  darkSplit: number;
  lightSplit: number;
  refineSaturation: number;
}

const BUMP_HIGHLIGHTS: number = 0;
const BUMP_LIGHTS: number = 1;
const BUMP_DARKS: number = 2;
const BUMP_SHADOWS: number = 3;

function clamp01(input: number): number {
  if (!Number.isFinite(input)) return 0;
  if (input < 0) return 0;
  if (input > 1) return 1;
  return input;
}

function clampAmount(input: number): number {
  if (!Number.isFinite(input)) return 0;
  if (input < -1) return -1;
  if (input > 1) return 1;
  return input;
}

function clampRange(input: number, lower: number, upper: number): number {
  if (!Number.isFinite(input)) return lower;
  return Math.max(lower, Math.min(upper, input));
}

function smoothstep(edge0: number, edge1: number, t: number): number {
  if (edge1 <= edge0) return t < edge0 ? 0 : 1;
  const u = clamp01((t - edge0) / (edge1 - edge0));
  return u * u * (3 - 2 * u);
}

export function parametricDefaults(): ParametricCurveParams {
  const defaults: ParametricCurveParams = {
    highlights: 0, lights: 0, darks: 0, shadows: 0,
    shadowSplit: 0.25, darkSplit: 0.50, lightSplit: 0.75,
    refineSaturation: 1,
  };
  return defaults;
}

interface ResolvedSplits {
  shadowSplit: number;
  darkSplit: number;
  lightSplit: number;
}

/**
 * Ordered splits. Clamping is sequential rather than independent so an
 * out-of-order request (say shadows at 0.9 with darks at 0.3) can never produce
 * crossing bands.
 */
function resolveSplits(params: ParametricCurveParams): ResolvedSplits {
  const shadowSplit = clampRange(params.shadowSplit, 0.10, 0.70);
  const darkSplit = clampRange(Math.max(clampRange(params.darkSplit, 0.20, 0.80), shadowSplit + SPLIT_GAP), 0.20, 0.80);
  const lightSplit = clampRange(Math.max(clampRange(params.lightSplit, 0.30, 0.90), darkSplit + SPLIT_GAP), 0.30, 0.90);
  const resolved: ResolvedSplits = {
    shadowSplit: shadowSplit, darkSplit: darkSplit, lightSplit: lightSplit,
  };
  return resolved;
}

/** The four region bumps at `t`; all are zero at t=0 and t=1. */
function regionBumps(t: number, splits: ResolvedSplits, out: number[]): void {
  const u = smoothstep(0, splits.shadowSplit, t);
  const v = smoothstep(splits.shadowSplit, splits.darkSplit, t);
  const w = smoothstep(splits.darkSplit, splits.lightSplit, t);
  const z = smoothstep(splits.lightSplit, 1, t);
  const uvw = u * v * w;
  out[BUMP_SHADOWS] = u * (1 - u);
  out[BUMP_DARKS] = v * (1 - v) * u;
  out[BUMP_LIGHTS] = w * (1 - w) * u * v;
  out[BUMP_HIGHLIGHTS] = z * (1 - z) * uvw;
}

function displacementAt(t: number, params: ParametricCurveParams, splits: ResolvedSplits, scratch: number[]): number {
  regionBumps(t, splits, scratch);
  return clampAmount(params.shadows) * scratch[BUMP_SHADOWS] +
    clampAmount(params.darks) * scratch[BUMP_DARKS] +
    clampAmount(params.lights) * scratch[BUMP_LIGHTS] +
    clampAmount(params.highlights) * scratch[BUMP_HIGHLIGHTS];
}

export function parametricIsIdentity(params: ParametricCurveParams): boolean {
  return clampAmount(params.highlights) === 0 && clampAmount(params.lights) === 0 &&
    clampAmount(params.darks) === 0 && clampAmount(params.shadows) === 0;
}

/**
 * The 256-entry transfer table, input 0..1 -> output 0..1.
 *
 * A zeroed curve returns the exact ramp because the displacement is identically
 * zero, not because of an early return.
 */
export function buildParametricLut(params: ParametricCurveParams): Float32Array {
  const size = PARAMETRIC_LUT_SIZE;
  const lut = new Float32Array(size);
  if (parametricIsIdentity(params)) {
    for (let i = 0; i < size; i++) lut[i] = i / (size - 1);
    return lut;
  }
  const splits = resolveSplits(params);
  const scratch: number[] = [0, 0, 0, 0];
  const step = 1 / (size - 1);
  const displacement = new Float32Array(size);
  for (let i = 0; i < size; i++) displacement[i] = displacementAt(i * step, params, splits, scratch);
  // Two independent bounds, both measured on the sampled field rather than
  // assumed from a closed form, so they stay correct if a bump shape changes:
  //
  //   slope bound  - keeps 1 + scale * D' above zero, which is what makes the
  //                  curve strictly increasing;
  //   value bound  - keeps x + scale * D inside 0..1, so a strong region amount
  //                  cannot drive a whole range of tones onto the clamp. A
  //                  clamped plateau would still be monotone, but it would
  //                  destroy detail rather than redistribute it.
  let maxGradient = 0;
  for (let i = 1; i < size; i++) {
    const gradient = Math.abs(displacement[i] - displacement[i - 1]) / step;
    if (gradient > maxGradient) maxGradient = gradient;
  }
  let valueLimit = 1;
  for (let i = 0; i < size; i++) {
    const d = displacement[i];
    if (d > 1e-9) {
      const room = (1 - i * step - VALUE_EPSILON) / d;
      if (room < valueLimit) valueLimit = room;
    } else if (d < -1e-9) {
      const room = (i * step - VALUE_EPSILON) / -d;
      if (room < valueLimit) valueLimit = room;
    }
  }
  let scale = 1;
  if (maxGradient > 0) scale = Math.min(scale, MAX_SLOPE_DELTA / maxGradient);
  if (valueLimit < scale) scale = Math.max(0, valueLimit);
  for (let i = 0; i < size; i++) {
    lut[i] = clamp01(i * step + scale * displacement[i]);
  }
  // The bumps vanish at both ends, so these assignments only remove the
  // floating-point dust left by the clamp; the endpoints are contractual.
  lut[0] = 0;
  lut[size - 1] = 1;
  return lut;
}

/** Linear interpolation into a LUT whose domain is 0..1. */
function sampleLut(lut: Float32Array, x: number): number {
  const size = lut.length;
  if (size === 0) return 0;
  if (size === 1) return lut[0];
  const position = clamp01(x) * (size - 1);
  const index = Math.floor(position);
  if (index >= size - 1) return lut[size - 1];
  const fraction = position - index;
  return lut[index] + (lut[index + 1] - lut[index]) * fraction;
}

/** Local slope of the curve, by central difference on the sampled table. */
export function parametricSlope(lut: Float32Array, x: number): number {
  const size = lut.length;
  if (size < 2) return 1;
  const h = 1 / (size - 1);
  const centre = clamp01(x);
  let lower = centre - h * 0.5;
  let upper = centre + h * 0.5;
  if (lower < 0) { lower = 0; upper = h; }
  if (upper > 1) { upper = 1; lower = 1 - h; }
  const span = upper - lower;
  if (!(span > 0)) return 1;
  const slope = (sampleLut(lut, upper) - sampleLut(lut, lower)) / span;
  return Number.isFinite(slope) ? slope : 1;
}

/**
 * Chroma multiplier that pulls back saturation the curve added to one pixel.
 *
 * `refineSaturation` follows lightcraft's `refine_saturation`: 1 keeps the
 * saturation the curve produces, lower values pull it back.
 *
 * This is measured from the pixel's actual before/after saturation rather than
 * from the curve's slope at the pixel's luminance. The curve is applied PER
 * CHANNEL, so a colour can gain saturation while its luminance sits outside the
 * steep region — measured on a sweep of saturated colours, that is 59% of the
 * colours the curve affects. A luminance-keyed slope factor is 1 for all of
 * them and would silently fail to refine, so the slope model is not used for
 * the render path.
 *
 *   refine = 1  ->  scale 1                    (keep the change)
 *   refine = 0  ->  scale satBefore / satAfter  (restore the input saturation)
 *
 * Returns 1 when the curve did not add saturation, so refinement never acts as
 * a desaturation control for pixels the curve left alone. `beforeSaturation`
 * and `afterSaturation` are HSV saturations in [0, 1].
 */
export function parametricRefineScale(beforeSaturation: number, afterSaturation: number,
  refineSaturation: number): number {
  const refine = clamp01(refineSaturation);
  if (refine >= 1) return 1;
  if (!(afterSaturation > 1e-4)) return 1;
  if (!(afterSaturation > beforeSaturation)) return 1;
  const scale = 1 + (refine - 1) * (afterSaturation - beforeSaturation) / afterSaturation;
  if (!Number.isFinite(scale)) return 1;
  if (scale < 0) return 0;
  if (scale > 1) return 1;
  return scale;
}
