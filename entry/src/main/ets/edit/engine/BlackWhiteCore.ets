/**
 * Black-and-white conversion with a per-hue-band mixer (Camera Raw's 黑白混色器).
 *
 * WHAT IT IS
 * A plain greyscale conversion throws away the hue information that decides how bright
 * each colour becomes. A mixer keeps it: eight hue bands (red / orange / yellow / green /
 * aqua / blue / purple / magenta) each get a weight, and a pixel's brightness after
 * conversion depends on which band its hue falls in. That is how a red apple and a blue
 * sky, which have similar luminance, can be made clearly different in a black-and-white
 * photograph.
 *
 * THE ALGORITHM
 * 1. `Y` = Rec.709 luma of the pixel, the same coefficients the rest of this project uses
 *    for luminance, so a mixer at zero is exactly the plain conversion.
 * 2. `sat` = HSV saturation. A neutral pixel has no hue to attribute to a band, so the
 *    mixer must not touch it. This is what stops the mixer from tinting or brightening
 *    greys, and it is asserted.
 * 3. Band membership: the eight band centres sit at fixed hues around the wheel, and a
 *    pixel's hue is attributed to its two neighbouring centres by linear interpolation.
 *    The weights therefore SUM TO EXACTLY 1 for every hue -- no normalisation step, and no
 *    hue can fall outside the bands. The wheel wraps between magenta and red.
 * 4. `grey = clamp01(Y * (1 + sat * sum(bandWeight_i * mixer_i)))`, written to all three
 *    channels.
 *
 * WHY THE MULTIPLIER FORM
 * Multiplicative rather than additive means a mixer at zero is the identity, so the
 * neutral state is exactly the plain luma conversion and not merely close to it. Negative
 * mixers darken a band, which is the documented behaviour, and the result can never go
 * negative before clamping because the multiplier is bounded by the clamps below.
 *
 * NO ADOBE PARITY, AND THE BAND CENTRES ARE A CHOICE
 * The band centres below are the conventional evenly-spaced eight-band layout; they are
 * NOT claimed to be Adobe's exact positions, because that is not published. The mixer
 * range is -1..1 and the mapping from a mixer value to a brightness change is this
 * implementation's own. There is no claim of matching any specific application's output;
 * what is asserted is the set of properties above, which are the ones a user can see.
 *
 * Pure module: no project imports, no I/O, no ambient state.
 */

/** Number of mixer bands. Order matches the panel: red, orange, yellow, green, aqua, blue, purple, magenta. */
export const BW_BAND_COUNT: number = 8;
/** Band centre hues in turns (0..1 around the wheel). */
export const BW_BAND_HUES: number[] = [
  0.0, 30 / 360, 60 / 360, 120 / 360, 180 / 360, 240 / 360, 285 / 360, 330 / 360,
];
/** Names, for the UI and for test messages. */
export const BW_BAND_NAMES: string[] = [
  '红', '橙', '黄', '绿', '青', '蓝', '紫', '洋红',
];
/** Rec.709 luma coefficients, matching the project's existing luminance constants. */
export const BW_LUMA_RED: number = 0.2126;
export const BW_LUMA_GREEN: number = 0.7152;
export const BW_LUMA_BLUE: number = 0.0722;

/** One mixer band: a name and a weight in -1..1. */
export interface BWMixerBand {
  name: string;
  weight: number;
}

export interface BlackWhiteParams {
  /** The stage does nothing at all until it is switched on. */
  enabled: boolean;
  /** Eight weights, in BW_BAND_NAMES order. */
  mixers: number[];
}

export function blackWhiteDefaults(): BlackWhiteParams {
  const mixers: number[] = [];
  for (let i = 0; i < BW_BAND_COUNT; i++) mixers.push(0);
  const defaults: BlackWhiteParams = { enabled: false, mixers: mixers };
  return defaults;
}

export function blackWhiteIsIdentity(p: BlackWhiteParams): boolean {
  if (!p) return true;
  return !p.enabled;
}

/** Repairs a restored parameter set: exactly eight finite weights, each clamped to -1..1. */
export function blackWhiteNormalize(p: BlackWhiteParams): BlackWhiteParams {
  const out: number[] = [];
  const source: number[] = p && p.mixers ? p.mixers : [];
  for (let i = 0; i < BW_BAND_COUNT; i++) {
    const raw: number = source.length > i ? source[i] : 0;
    const value: number = Number.isFinite(raw) ? raw : 0;
    out.push(value < -1 ? -1 : (value > 1 ? 1 : value));
  }
  const normalized: BlackWhiteParams = { enabled: !!(p && p.enabled), mixers: out };
  return normalized;
}

/** Plain Rec.709 luma. Inputs are 0..1 and are clamped. */
export function blackWhiteLuma(red: number, green: number, blue: number): number {
  const r: number = red < 0 ? 0 : (red > 1 ? 1 : red);
  const g: number = green < 0 ? 0 : (green > 1 ? 1 : green);
  const b: number = blue < 0 ? 0 : (blue > 1 ? 1 : blue);
  return BW_LUMA_RED * r + BW_LUMA_GREEN * g + BW_LUMA_BLUE * b;
}

/** HSV saturation: 0 for a neutral, 1 for a fully saturated colour. */
export function blackWhiteSaturation(red: number, green: number, blue: number): number {
  const max: number = Math.max(red, Math.max(green, blue));
  const min: number = Math.min(red, Math.min(green, blue));
  if (!(max > 0)) return 0;
  const sat: number = (max - min) / max;
  return sat < 0 ? 0 : (sat > 1 ? 1 : sat);
}

/** Hue in turns, or 0 for a neutral (where hue is undefined). */
export function blackWhiteHue(red: number, green: number, blue: number): number {
  const max: number = Math.max(red, Math.max(green, blue));
  const min: number = Math.min(red, Math.min(green, blue));
  const span: number = max - min;
  if (!(span > 0)) return 0;
  let hue: number;
  if (max === red) hue = ((green - blue) / span) % 6;
  else if (max === green) hue = (blue - red) / span + 2;
  else hue = (red - green) / span + 4;
  hue = hue / 6;
  return hue - Math.floor(hue);
}

/**
 * Band weights for a hue. Two adjacent centres get linearly interpolated weights that sum
 * to exactly 1, with the wheel wrapping between the last and the first band.
 */
export function blackWhiteBandWeights(hue: number, out: number[]): void {
  out.length = 0;
  for (let i = 0; i < BW_BAND_COUNT; i++) out.push(0);
  let h: number = hue - Math.floor(hue);
  // Locate the band whose centre is at or before this hue, wrapping across zero.
  let index: number = BW_BAND_COUNT - 1;
  for (let i = 0; i < BW_BAND_COUNT; i++) {
    if (BW_BAND_HUES[i] <= h) index = i;
  }
  const start: number = BW_BAND_HUES[index];
  const nextIndex: number = (index + 1) % BW_BAND_COUNT;
  let next: number = BW_BAND_HUES[nextIndex];
  if (next <= start) next += 1;
  if (h < start) h += 1;
  const span: number = next - start;
  const t: number = span > 0 ? (h - start) / span : 0;
  out[index] = 1 - t;
  out[nextIndex] = out[nextIndex] + t;
}

/** The combined multiplier for a colour: 1 when the mixers are all zero. */
export function blackWhiteMultiplier(red: number, green: number, blue: number, mixers: number[]): number {
  if (!mixers || mixers.length < BW_BAND_COUNT) return 1;
  const sat: number = blackWhiteSaturation(red, green, blue);
  if (!(sat > 0)) return 1;
  const hue: number = blackWhiteHue(red, green, blue);
  const weights: number[] = [];
  blackWhiteBandWeights(hue, weights);
  let sum: number = 0;
  for (let i = 0; i < BW_BAND_COUNT; i++) {
    const weight: number = Number.isFinite(mixers[i]) ? mixers[i] : 0;
    sum += weights[i] * weight;
  }
  const multiplier: number = 1 + sat * sum;
  return multiplier < 0 ? 0 : multiplier;
}

/** Converts one colour. Returns the grey value, 0..1. */
export function blackWhiteValue(red: number, green: number, blue: number, p: BlackWhiteParams): number {
  const luma: number = blackWhiteLuma(red, green, blue);
  if (!p || !p.enabled) return luma;
  const normalized: BlackWhiteParams = blackWhiteNormalize(p);
  const grey: number = luma * blackWhiteMultiplier(red, green, blue, normalized.mixers);
  return grey < 0 ? 0 : (grey > 1 ? 1 : grey);
}

/** Converts one colour to a neutral triple. */
export function blackWhiteApply(red: number, green: number, blue: number, p: BlackWhiteParams): number[] {
  const grey: number = blackWhiteValue(red, green, blue, p);
  return [grey, grey, grey];
}

/**
 * Whole-frame entry point for the render path.
 *
 * Shares `blackWhiteValue` with the per-colour API, so the per-colour suite covers this
 * path and the two cannot drift. Returns the number of pixels actually changed.
 */
export function blackWhiteBuffer(rgba: Uint8ClampedArray, width: number, height: number,
  p: BlackWhiteParams): number {
  if (blackWhiteIsIdentity(p)) return 0;
  const normalized: BlackWhiteParams = blackWhiteNormalize(p);
  const count: number = width * height;
  let changed: number = 0;
  for (let i = 0; i < count; i++) {
    const o: number = i * 4;
    const grey: number = Math.round(blackWhiteValue(rgba[o] / 255, rgba[o + 1] / 255, rgba[o + 2] / 255,
      normalized) * 255);
    if (grey === rgba[o] && grey === rgba[o + 1] && grey === rgba[o + 2]) continue;
    rgba[o] = grey;
    rgba[o + 1] = grey;
    rgba[o + 2] = grey;
    changed++;
  }
  return changed;
}
