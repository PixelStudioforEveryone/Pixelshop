/**
 * OkLCh grading: lightness, chroma and hue adjusted in the Oklab perceptual space.
 *
 * WHY THIS SPACE
 * sRGB is not perceptually uniform and not hue-linear: brightening a saturated red in
 * sRGB shifts its hue and clips it. Oklab was designed so that a constant-hue line
 * looks like a constant hue, and so that equal lightness steps look equal. That is
 * exactly the property a grading stage needs, and it is why lightcraft carries a
 * separate OkLCh stage.
 *
 * THE MATHS IS THE PUBLISHED DEFINITION, NOT AN APPROXIMATION
 * The two matrices below are Bjorn Ottosson's published Oklab constants, used
 * verbatim. `check_oklch_core.cjs` pins them against published values for
 * white / mid grey / the sRGB primaries and against an exact round trip, so a
 * transcription error cannot survive.
 *
 * THE ONE DESIGN DECISION WORTH ARGUING ABOUT: CHROMA GAMUT MAPPING
 * Raising chroma can push a colour outside sRGB. The obvious response -- compute the
 * result and clamp each channel to [0,1] -- is WRONG for a grading tool: per-channel
 * clamping displaces the hue, which is the one thing this space was chosen to
 * preserve. Instead, when the target chroma falls outside the gamut, the chroma is
 * reduced (binary search on the gamut boundary at constant L and h) until the colour
 * fits. Lightness and hue are therefore held exactly, and only saturation gives way.
 * `check_oklch_core.cjs` asserts that hue survives a 3x chroma push on a saturated
 * red, which is precisely where per-channel clamping would visibly fail.
 *
 * NO ADOBE PARITY, AND NO HUE-RANGE SELECTIVITY
 * This is a global three-parameter grade. It has no per-hue-band targeting (unlike
 * the point-colour stage) and no claim of matching any specific application's
 * implementation; the parameters are plain offsets in Oklab units.
 *
 * Pure module: no project imports, no I/O, no ambient state.
 */

/** Adjustments, in Oklab units. All three are offsets around the identity. */
export interface OkLChParams {
  /** Added to Oklab L, whose full range is 0..1. */
  lightness: number;
  /** Scales chroma: -1 is fully grey, 0 is unchanged, +1 doubles it. */
  chroma: number;
  /** Added to the hue angle, in turns (1.0 is a full revolution). */
  hue: number;
}

export function oklchDefaults(): OkLChParams {
  const defaults: OkLChParams = { lightness: 0, chroma: 0, hue: 0 };
  return defaults;
}

export function oklchIsIdentity(p: OkLChParams): boolean {
  if (!p) return true;
  // Two params can cancel, but they only do so in the limiting case where the colour
  // has no chroma at all, so the cheap check is exact rather than approximate: any
  // non-zero chroma or hue offset is a real change for at least some input.
  return p.lightness === 0 && p.chroma === 0 && p.hue === 0;
}

/** Tolerance for the gamut test. Small enough that the search lands on the boundary,
 *  large enough that the matrices' own rounding does not declare white out of gamut. */
const GAMUT_EPSILON = 1e-6;
/**
 * Chroma below which a colour is treated as exactly achromatic.
 *
 * This exists because of a measured defect. The published Oklab constants are not
 * exactly normalised, so a perfect neutral round-trips with a residual chroma of about
 * 2e-8 and a channel spread of about 1.4e-7 in sRGB -- which is invisible EXCEPT when
 * the value lands on a rounding boundary. Mid grey under the IDENTITY parameters came
 * back as 127,128,128 instead of 128,128,128: a one-code-value colour cast on a
 * neutral, with no grade applied at all.
 *
 * Snapping sub-1e-6 chroma to exactly zero makes the three channels bit-identical, so no
 * grade can tint a grey or split it across a code boundary. The threshold cannot affect
 * a visible colour: one code value at mid grey is roughly 1.5e-3 of chroma, so this is
 * about 1500 times smaller than the smallest visible deviation. `check_oklch_core.cjs`
 * asserts both halves of that claim.
 */
const ACHROMATIC_EPSILON = 1e-6;
/** Binary-search depth: 24 halvings of a 0..C interval is far below 8-bit precision. */
const GAMUT_ITERATIONS = 24;
/** Log-scale value below which sRGB is treated as linear; the standard breakpoint. */
const SRGB_BREAK = 0.0031308;
const SRGB_SLOPE = 12.92;
const SRGB_ALPHA = 1.055;
const SRGB_OFFSET = 0.055;
const SRGB_GAMMA = 2.4;

export function srgbToLinear(c: number): number {
  const v = c < 0 ? 0 : (c > 1 ? 1 : c);
  return v <= 0.04045 ? v / SRGB_SLOPE : Math.pow((v + SRGB_OFFSET) / SRGB_ALPHA, SRGB_GAMMA);
}

export function linearToSrgb(c: number): number {
  const v = c < 0 ? 0 : (c > 1 ? 1 : c);
  return v <= SRGB_BREAK ? v * SRGB_SLOPE : SRGB_ALPHA * Math.pow(v, 1 / SRGB_GAMMA) - SRGB_OFFSET;
}

/** Linear sRGB -> Oklab. Returns [L, a, b]. */
export function linearRgbToOklab(red: number, green: number, blue: number): number[] {
  const l = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue;
  const m = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue;
  const s = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue;
  const lc = Math.cbrt(l), mc = Math.cbrt(m), sc = Math.cbrt(s);
  return [
    0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc,
    1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc,
    0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc,
  ];
}

/** Oklab -> linear sRGB. Returns [r, g, b], possibly outside 0..1. */
export function oklabToLinearRgb(L: number, a: number, b: number): number[] {
  const lc = L + 0.3963377774 * a + 0.2158037573 * b;
  const mc = L - 0.1055613458 * a - 0.0638541728 * b;
  const sc = L - 0.0894841775 * a - 1.2914855480 * b;
  const l = lc * lc * lc, m = mc * mc * mc, s = sc * sc * sc;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ];
}

/** Oklab -> [L, C, h] with the hue angle in turns, normalised to [0, 1). */
export function oklabToOklch(L: number, a: number, b: number): number[] {
  const C = Math.sqrt(a * a + b * b);
  let h = Math.atan2(b, a) / (Math.PI * 2);
  h = h - Math.floor(h);
  return [L, C, h];
}

/** [L, C, h] with h in turns -> Oklab [L, a, b]. */
export function oklchToOklab(L: number, C: number, h: number): number[] {
  const angle = h * Math.PI * 2;
  return [L, Math.cos(angle) * C, Math.sin(angle) * C];
}

/** Whether L/C/h lands inside the sRGB cube once converted to linear RGB. */
export function oklchInGamut(L: number, C: number, h: number): boolean {
  const lab = oklchToOklab(L, C, h);
  const rgb = oklabToLinearRgb(lab[0], lab[1], lab[2]);
  for (let i = 0; i < 3; i++) {
    if (rgb[i] < -GAMUT_EPSILON || rgb[i] > 1 + GAMUT_EPSILON) return false;
  }
  return true;
}

/**
 * Largest chroma at this lightness and hue that still fits in sRGB.
 *
 * Fast path first: if the requested chroma already fits, it is returned untouched, so
 * an in-gamut grade is bit-for-bit the arithmetic the caller asked for. Only when it
 * does not fit is the boundary located by bisection, which is monotone here because
 * the gamut is star-shaped about the neutral axis in Oklab.
 */
export function gamutChromaLimit(L: number, C: number, h: number): number {
  const target = C < 0 ? 0 : C;
  if (oklchInGamut(L, target, h)) return target;
  let low = 0, high = target;
  for (let i = 0; i < GAMUT_ITERATIONS; i++) {
    const mid = (low + high) / 2;
    if (oklchInGamut(L, mid, h)) low = mid; else high = mid;
  }
  return low;
}

function clamp01(v: number): number {
  // Deliberately written so that NaN falls to 0. The usual `v < 0 ? 0 : ...` form lets
  // NaN straight through, and `Math.round(NaN)` written into a Uint8ClampedArray becomes
  // 0 -- so one non-finite value would silently blacken the whole frame.
  if (!(v > 0)) return 0;
  return v > 1 ? 1 : v;
}

/** Non-finite parameters are treated as no-ops instead of being allowed to reach pixels. */
function finiteOr(v: number, fallback: number): number {
  return Number.isFinite(v) ? v : fallback;
}

/** Applies the grade to one colour. Inputs and outputs are 0..1 sRGB. Returns [r,g,b]. */
export function applyOkLCh(red: number, green: number, blue: number, p: OkLChParams): number[] {
  const offsetL = p ? finiteOr(p.lightness, 0) : 0;
  const offsetC = p ? finiteOr(p.chroma, 0) : 0;
  const offsetH = p ? finiteOr(p.hue, 0) : 0;
  const lab = linearRgbToOklab(srgbToLinear(red), srgbToLinear(green), srgbToLinear(blue));
  const lch = oklabToOklch(lab[0], lab[1], lab[2]);
  // Clamping L keeps a deliberate over/under-exposure request inside the space the
  // inverse transform is defined on, instead of producing NaN through a negative
  // cube root.
  const L = clamp01(lch[0] + offsetL);
  // Achromatic fast path: see ACHROMATIC_EPSILON. A neutral has no hue to rotate and no
  // chroma to scale, and for a neutral Oklab L is exactly the cube root of the linear
  // value (the RGB rows sum to 1), so the inverse can be written directly. Returning one
  // shared value makes the three channels bit-identical by construction.
  if (lch[1] <= ACHROMATIC_EPSILON) {
    // L is derived from the input's own linear value rather than from the matrix chain.
    // The chain would inherit the published L row's 0.9999999935 normalisation, making
    // the result about 6.5e-9 too dark -- enough to flip the rounding of a neutral whose
    // value lands exactly on a code boundary (mid grey came back 127 instead of 128).
    // cbrt here is the exact inverse of the cube below, so an ungraded neutral returns
    // through the transfer functions and nothing else.
    const neutralL = clamp01(Math.cbrt(srgbToLinear(red)) + offsetL);
    const grey = clamp01(linearToSrgb(neutralL * neutralL * neutralL));
    return [grey, grey, grey];
  }
  let hue = lch[2] + offsetH;
  hue = hue - Math.floor(hue);
  // -1 must mean exactly grey, so the scale is clamped at zero rather than allowed to
  // run negative (which would mirror the hue by 180 degrees).
  const scaled = lch[1] * (1 + offsetC);
  const requested = scaled < 0 ? 0 : scaled;
  // Chroma alone gives way when the request leaves the gamut; L and h are held.
  const C = gamutChromaLimit(L, requested, hue);
  const out = oklchToOklab(L, C, hue);
  const rgb = oklabToLinearRgb(out[0], out[1], out[2]);
  return [clamp01(linearToSrgb(rgb[0])), clamp01(linearToSrgb(rgb[1])), clamp01(linearToSrgb(rgb[2]))];
}

export function applyOkLChInto(red: number, green: number, blue: number, p: OkLChParams, out: number[]): void {
  const rgb = applyOkLCh(red, green, blue, p);
  out[0] = rgb[0]; out[1] = rgb[1]; out[2] = rgb[2];
}

/**
 * Whole-frame entry point for the render path.
 *
 * Shares `applyOkLCh` with the per-pixel API, so the per-colour suite covers this path
 * too and the two can never drift. Returns the number of pixels actually changed, so a
 * caller can prove the stage ran rather than assume it.
 */
export function applyOkLChBuffer(rgba: Uint8ClampedArray, width: number, height: number,
  p: OkLChParams): number {
  if (oklchIsIdentity(p)) return 0;
  const count = width * height;
  const scratch: number[] = [0, 0, 0];
  let changed = 0;
  for (let i = 0; i < count; i++) {
    const o = i * 4;
    const r = rgba[o] / 255, g = rgba[o + 1] / 255, b = rgba[o + 2] / 255;
    applyOkLChInto(r, g, b, p, scratch);
    const nr = Math.round(clamp01(scratch[0]) * 255);
    const ng = Math.round(clamp01(scratch[1]) * 255);
    const nb = Math.round(clamp01(scratch[2]) * 255);
    if (nr === rgba[o] && ng === rgba[o + 1] && nb === rgba[o + 2]) continue;
    rgba[o] = nr; rgba[o + 1] = ng; rgba[o + 2] = nb;
    changed++;
  }
  return changed;
}
