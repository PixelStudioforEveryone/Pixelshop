/**
 * Adobe Camera Raw's "Point Color" (Color Mixer > Point Color), as a pure
 * function.
 *
 * The user samples up to MAX_POINT_COLORS colours out of the photo. Every
 * sample carries three *shift* amounts (hue / saturation / luminance) and three
 * *range* widths that say how far away from the sampled colour a shift still
 * reaches before it has faded to nothing.
 *
 * HONEST SCOPE: Adobe has never published the exact Point Color formulation,
 * and this file was written without access to it. What follows is an
 * independent approximation whose semantics are chosen and documented here.
 * It is NOT bit-identical to Camera Raw, it is not claimed to be, and it
 * should not be described as a clone: matching Adobe's look would need
 * measurement against the real product rather than guessing.
 *
 * Documented semantics:
 *
 *  - HSL is the working space. rgbToHsl01 / hsl01ToRgb are the classical
 *    hue-sector conversions with h, s and l all normalised to 0..1 and h
 *    wrapped into [0,1). Hue 0 = red, 1/3 = green, 2/3 = blue, and hue
 *    increases in that order.
 *  - Weight is separable: w = hueAxis * saturationAxis * luminanceAxis.
 *    Each axis contributes a 1-D falloff that is exactly 1 at zero distance and
 *    exactly 0 at (and beyond) that axis's range, with a Hermite smoothstep in
 *    between. Smoothstep has zero slope at both ends, so the selection meets
 *    full strength and the background without a visible ring or hard seam.
 *  - Hue distance is the shortest way around the circle, so a sample at hue
 *    0.98 and a pixel at hue 0.02 are 0.04 apart rather than 0.96. This is the
 *    single most common bug in this feature.
 *  - A grey pixel has no defined hue. If the *sample* is chromatic, the hue
 *    axis contributes 0 for an achromatic pixel, so greys are never captured by
 *    a hue range by accident. If the *sample itself* is achromatic then its own
 *    hue is equally meaningless, so the hue axis does not gate at all (it
 *    contributes 1) and the sample still acts through the saturation and
 *    luminance axes. That is a choice, not a derivation: it keeps "point at a
 *    grey wall and darken it" working while keeping "point at a red wall" from
 *    dragging in the whole greyscale.
 *  - Only the weighted fraction of a shift is applied, so a pixel at the edge
 *    of a range is barely touched. Hue rotates by
 *    hueShift * (30/360) * weight turns, wrapping. Saturation is scaled
 *    relatively and asymptotically, so it can never leave 0..1 and can never
 *    invert (a full negative shift lands on exactly 0, never on a negative
 *    number). Luminance is an additive offset on lightness, clamped to 0..1.
 *  - ORDER MATTERS: multiple samples are applied strictly in order, and each
 *    sample after the first is weighted against the colour *as already modified
 *    by the previous samples*, not against the original pixel. Samples beyond
 *    MAX_POINT_COLORS are ignored, they do not throw.
 *  - An empty list, or a list whose (first MAX_POINT_COLORS) samples all have
 *    three exactly-zero shifts, returns the input untouched - there is no HSL
 *    round trip on that path, so identity is bit-exact rather than merely
 *    close.
 *
 * Pure: no imports, no I/O, no module state. applyPointColor's only allocation
 * is the returned 3-element array, which doubles as scratch space.
 */

/** How many samples are honoured; anything past this index is ignored. */
export const MAX_POINT_COLORS: number = 8;

/** One sampled colour plus the shifts and ranges the user set for it. */
export interface PointColorSample {
  /** Sampled hue, 0..1 (0..360 degrees normalised). */
  hue: number;
  /** Sampled saturation, 0..1. */
  saturation: number;
  /** Sampled luminance, 0..1. */
  luminance: number;
  /** -1..1, becomes +/- 30 degrees of rotation at full strength. */
  hueShift: number;
  /** -1..1, a relative saturation change. */
  saturationShift: number;
  /** -1..1, an additive offset on lightness. */
  luminanceShift: number;
  /** 0..1, the hue half-width of the falloff. Default 30/360. */
  hueRange: number;
  /** 0..1, the saturation half-width of the falloff. Default 0.4. */
  saturationRange: number;
  /** 0..1, the luminance half-width of the falloff. Default 0.4. */
  luminanceRange: number;
}

/** Full-scale hue rotation, in turns, at |hueShift| = 1: 30 degrees. */
const HUE_SHIFT_FULL: number = 30 / 360;
/** Full-scale lightness offset, in 0..1 lightness units, at |luminanceShift| = 1. */
const LUMINANCE_SHIFT_FULL: number = 0.5;
/** Default hue range: 30 degrees, matching Camera Raw's starting width. */
const DEFAULT_HUE_RANGE: number = 30 / 360;
const DEFAULT_SATURATION_RANGE: number = 0.4;
const DEFAULT_LUMINANCE_RANGE: number = 0.4;
/**
 * Below this saturation a colour is treated as achromatic and its hue as
 * undefined. Well above float noise and well below anything visible.
 */
const ACHROMATIC_EPSILON: number = 1e-4;

/** A neutral sample: no shifts, sampled at grey so the caller must fill it in. */
export function pointColorDefaults(): PointColorSample {
  const sample: PointColorSample = {
    hue: 0,
    saturation: 0,
    luminance: 0,
    hueShift: 0,
    saturationShift: 0,
    luminanceShift: 0,
    hueRange: DEFAULT_HUE_RANGE,
    saturationRange: DEFAULT_SATURATION_RANGE,
    luminanceRange: DEFAULT_LUMINANCE_RANGE,
  };
  return sample;
}

/** Finite, clamped into 0..1; a non-finite input degrades to 0. */
function clamp01(input: number): number {
  if (!Number.isFinite(input)) return 0;
  if (input < 0) return 0;
  if (input > 1) return 1;
  return input;
}

/** Finite, clamped into -1..1; a non-finite input degrades to 0 (no shift). */
function clampSigned(input: number): number {
  if (!Number.isFinite(input)) return 0;
  if (input < -1) return -1;
  if (input > 1) return 1;
  return input;
}

/** Wrap any finite number into [0,1); non-finite degrades to 0. */
function wrap01(input: number): number {
  if (!Number.isFinite(input)) return 0;
  let wrapped: number = input - Math.floor(input);
  if (!Number.isFinite(wrapped) || wrapped < 0) return 0;
  if (wrapped >= 1) return 0;
  return wrapped;
}

/**
 * Shortest angular distance between two hues on the unit circle, in 0..0.5.
 *
 * Both inputs are wrapped first, then the signed difference is shifted into
 * (-0.5, 0.5] before the sign is dropped, which is what makes 0.98 vs 0.02 come
 * out as 0.04.
 */
function hueDistance01(first: number, second: number): number {
  const a: number = wrap01(first);
  const b: number = wrap01(second);
  let raw: number = a - b;
  raw = raw - Math.floor(raw + 0.5);
  if (!Number.isFinite(raw)) return 0;
  const distance: number = raw < 0 ? -raw : raw;
  return distance > 0.5 ? 0.5 : distance;
}

/**
 * One axis of the falloff: 1 at zero distance, 0 at and beyond the range, with
 * a Hermite smoothstep in between (zero slope at both ends).
 *
 * range === 0 is a hard match, not a division by zero: only an exact hit is
 * selected. Distance is taken as an absolute value, so a caller may pass a
 * signed difference.
 */
function axisWeight(distance: number, range: number): number {
  const d: number = distance < 0 ? -distance : distance;
  if (!Number.isFinite(d)) return 0;
  if (d <= 0) return 1;
  const r: number = clamp01(range);
  if (r <= 0) return 0;
  if (d >= r) return 0;
  const t: number = d / r;
  const weight: number = 1 - t * t * (3 - 2 * t);
  if (!Number.isFinite(weight) || weight < 0) return 0;
  return weight > 1 ? 1 : weight;
}

/**
 * Relative saturation change by a multiplicative factor around 1.
 *
 * factor > 1 boosts asymptotically towards 1, factor < 1 scales down and lands
 * on exactly 0 at factor 0. Both branches are monotone in the factor, agree
 * exactly at factor 1, and map 0..1 into 0..1 with no clamp anywhere - so an
 * extreme negative shift can flatten colour to grey but can never invert it or
 * overshoot past 1.
 */
function scaleSaturation(current: number, factor: number): number {
  const s: number = clamp01(current);
  if (!Number.isFinite(factor) || factor <= 0) return 0;
  if (factor === 1) return s;
  if (factor > 1) {
    const rest: number = 1 - s;
    if (rest <= 0) return 1;
    const boosted: number = 1 - Math.pow(rest, factor);
    if (!Number.isFinite(boosted) || boosted < 0) return 0;
    return boosted > 1 ? 1 : boosted;
  }
  return clamp01(s * factor);
}

/** How many samples are actually honoured. Never negative, never above the cap. */
function sampleCount(samples: PointColorSample[]): number {
  const total: number = samples.length;
  if (!Number.isFinite(total) || total <= 0) return 0;
  return total < MAX_POINT_COLORS ? total : MAX_POINT_COLORS;
}

/**
 * True when applying the list cannot change any colour: an empty list, or a
 * list whose honoured samples all have three exactly-zero shifts.
 *
 * Deliberately checks only the first MAX_POINT_COLORS entries, because the rest
 * are ignored by applyPointColor; a nonzero shift on sample 9 is not a reason
 * to leave the fast path.
 */
export function pointColorIsIdentity(samples: PointColorSample[]): boolean {
  const count: number = sampleCount(samples);
  for (let i: number = 0; i < count; i++) {
    const sample: PointColorSample = samples[i];
    if (clampSigned(sample.hueShift) !== 0) return false;
    if (clampSigned(sample.saturationShift) !== 0) return false;
    if (clampSigned(sample.luminanceShift) !== 0) return false;
  }
  return true;
}

/**
 * How strongly a colour at (h, s, l) is affected by one sample, 0..1.
 *
 * The product of the three axes, each a smoothstep falloff over that axis's
 * range. Both the sample and the pixel are sanitised here, so a sample holding
 * garbage still yields a finite weight instead of a NaN.
 */
export function pointColorWeight(sample: PointColorSample, h: number, s: number, l: number): number {
  const sampleHue: number = wrap01(sample.hue);
  const sampleSaturation: number = clamp01(sample.saturation);
  const sampleLuminance: number = clamp01(sample.luminance);
  const pixelSaturation: number = clamp01(s);
  const pixelLuminance: number = clamp01(l);

  let hueAxis: number;
  if (sampleSaturation <= ACHROMATIC_EPSILON) {
    // The sample has no hue of its own, so its hue range cannot discriminate.
    hueAxis = 1;
  } else if (pixelSaturation <= ACHROMATIC_EPSILON) {
    // The pixel has no hue of its own: a hue range must not claim it.
    hueAxis = 0;
  } else {
    hueAxis = axisWeight(hueDistance01(h, sampleHue), sample.hueRange);
  }

  const saturationAxis: number = axisWeight(pixelSaturation - sampleSaturation, sample.saturationRange);
  const luminanceAxis: number = axisWeight(pixelLuminance - sampleLuminance, sample.luminanceRange);

  const weight: number = hueAxis * saturationAxis * luminanceAxis;
  if (!Number.isFinite(weight) || weight < 0) return 0;
  return weight > 1 ? 1 : weight;
}

/**
 * Classic hue-sector RGB -> HSL into a caller-supplied array, so the per-pixel
 * path never allocates a scratch triple. Writes [h, s, l], each 0..1.
 */
function rgbToHslInto(r: number, g: number, b: number, out: number[]): void {
  const red: number = clamp01(r);
  const green: number = clamp01(g);
  const blue: number = clamp01(b);
  const high: number = Math.max(red, Math.max(green, blue));
  const low: number = Math.min(red, Math.min(green, blue));
  const lightness: number = (high + low) * 0.5;
  const chroma: number = high - low;
  let hue: number = 0;
  let saturation: number = 0;
  if (chroma > 0) {
    if (lightness > 0.5) {
      saturation = chroma / (2 - high - low);
    } else {
      saturation = chroma / (high + low);
    }
    if (high === red) {
      hue = ((green - blue) / chroma + (green < blue ? 6 : 0)) / 6;
    } else if (high === green) {
      hue = ((blue - red) / chroma + 2) / 6;
    } else {
      hue = ((red - green) / chroma + 4) / 6;
    }
  }
  out[0] = wrap01(hue);
  out[1] = clamp01(saturation);
  out[2] = clamp01(lightness);
}

/** Hue sector of the HSL -> RGB conversion; t is in turns, in or out of 0..1. */
function hueToChannel(p: number, q: number, t: number): number {
  let position: number = t;
  if (position < 0) position += 1;
  if (position > 1) position -= 1;
  if (position < 1 / 6) return p + (q - p) * 6 * position;
  if (position < 1 / 2) return q;
  if (position < 2 / 3) return p + (q - p) * (2 / 3 - position) * 6;
  return p;
}

/** HSL -> RGB into a caller-supplied array. Writes [r, g, b], each 0..1. */
function hslToRgbInto(h: number, s: number, l: number, out: number[]): void {
  const hue: number = wrap01(h);
  const saturation: number = clamp01(s);
  const lightness: number = clamp01(l);
  if (saturation <= 0) {
    out[0] = lightness;
    out[1] = lightness;
    out[2] = lightness;
    return;
  }
  const q: number = lightness <= 0.5
    ? lightness * (1 + saturation)
    : lightness + saturation - lightness * saturation;
  const p: number = 2 * lightness - q;
  out[0] = clamp01(hueToChannel(p, q, hue + 1 / 3));
  out[1] = clamp01(hueToChannel(p, q, hue));
  out[2] = clamp01(hueToChannel(p, q, hue - 1 / 3));
}

/** RGB (each 0..1) to [h, s, l] (each 0..1, h wrapped into [0,1)). */
export function rgbToHsl01(red: number, green: number, blue: number): number[] {
  const out: number[] = [0, 0, 0];
  rgbToHslInto(red, green, blue, out);
  return out;
}

/** HSL (each 0..1) to [r, g, b] (each 0..1). */
export function hsl01ToRgb(h: number, s: number, l: number): number[] {
  const out: number[] = [0, 0, 0];
  hslToRgbInto(h, s, l, out);
  return out;
}

/**
 * Apply the whole sample stack to one colour, writing [r, g, b] into `out`.
 *
 * Inputs are clamped, the stack is applied in order against the running colour
 * (see the header), and samples past MAX_POINT_COLORS are ignored. `out` doubles as
 * the HSL scratch buffer, so this allocates nothing at all — which is what lets the
 * buffer-level entry point below reuse ONE array across a whole frame instead of
 * allocating per pixel.
 */
export function applyPointColorInto(red: number, green: number, blue: number,
  samples: PointColorSample[], out: number[]): void {
  while (out.length < 3) out.push(0);
  const baseRed: number = clamp01(red);
  const baseGreen: number = clamp01(green);
  const baseBlue: number = clamp01(blue);
  const count: number = sampleCount(samples);
  // Identity short-circuits *before* any HSL round trip, so an untouched pixel
  // comes back bit-exact rather than merely close.
  if (count === 0 || pointColorIsIdentity(samples)) {
    out[0] = baseRed;
    out[1] = baseGreen;
    out[2] = baseBlue;
    return;
  }

  rgbToHslInto(baseRed, baseGreen, baseBlue, out);
  let hue: number = out[0];
  let saturation: number = out[1];
  let lightness: number = out[2];

  for (let i: number = 0; i < count; i++) {
    const sample: PointColorSample = samples[i];
    const hueShift: number = clampSigned(sample.hueShift);
    const saturationShift: number = clampSigned(sample.saturationShift);
    const luminanceShift: number = clampSigned(sample.luminanceShift);
    if (hueShift === 0 && saturationShift === 0 && luminanceShift === 0) continue;
    const weight: number = pointColorWeight(sample, hue, saturation, lightness);
    if (!(weight > 0)) continue;
    if (hueShift !== 0) {
      hue = wrap01(hue + hueShift * HUE_SHIFT_FULL * weight);
    }
    if (saturationShift !== 0) {
      saturation = scaleSaturation(saturation, 1 + saturationShift * weight);
    }
    if (luminanceShift !== 0) {
      lightness = clamp01(lightness + luminanceShift * LUMINANCE_SHIFT_FULL * weight);
    }
  }

  hslToRgbInto(hue, saturation, lightness, out);
  out[0] = clamp01(out[0]);
  out[1] = clamp01(out[1]);
  out[2] = clamp01(out[2]);
}

/**
 * Apply the whole sample stack to one colour and return a new [r, g, b].
 *
 * The only allocation is the returned array, which is reused as the HSL scratch
 * buffer.
 */
export function applyPointColor(red: number, green: number, blue: number, samples: PointColorSample[]): number[] {
  const out: number[] = [0, 0, 0];
  applyPointColorInto(red, green, blue, samples, out);
  return out;
}

/**
 * Apply the sample stack across a whole RGBA frame, in place.
 *
 * Reuses ONE scratch array for every pixel: allocating per pixel was the dominant
 * cost of a full-resolution pass. The maths is `applyPointColorInto`, the same
 * function `applyPointColor` calls, so the per-colour suite covers this path too
 * rather than a parallel implementation that could drift from it.
 *
 * Returns the number of pixels it actually changed, so a caller can prove the pass
 * did something instead of assuming it, and so a test can assert the count is zero
 * for a frame the samples should not touch.
 */
export function applyPointColorBuffer(rgba: Uint8ClampedArray, width: number, height: number,
  samples: PointColorSample[]): number {
  if (!rgba || !samples) return 0;
  if (sampleCount(samples) === 0 || pointColorIsIdentity(samples)) return 0;
  const w: number = Math.max(1, Math.floor(width));
  const h: number = Math.max(1, Math.floor(height));
  const pixels: number = Math.min(w * h, Math.floor(rgba.length / 4));
  const scratch: number[] = [0, 0, 0];
  let changed: number = 0;
  for (let i: number = 0; i < pixels; i++) {
    const p: number = i * 4;
    const red: number = rgba[p];
    const green: number = rgba[p + 1];
    const blue: number = rgba[p + 2];
    applyPointColorInto(red / 255, green / 255, blue / 255, samples, scratch);
    const outRed: number = Math.round(clamp01(scratch[0]) * 255);
    const outGreen: number = Math.round(clamp01(scratch[1]) * 255);
    const outBlue: number = Math.round(clamp01(scratch[2]) * 255);
    if (outRed !== red || outGreen !== green || outBlue !== blue) changed++;
    rgba[p] = outRed;
    rgba[p + 1] = outGreen;
    rgba[p + 2] = outBlue;
  }
  return changed;
}
