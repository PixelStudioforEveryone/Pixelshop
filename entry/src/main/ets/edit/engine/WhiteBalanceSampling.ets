/**
 * Region / point white-balance sampling: a pure core shared by the colour panel
 * UI and by any later command or MCP entry point. No ArkUI import, no session
 * access, nothing asynchronous — the caller owns capturing the target identity.
 *
 * Reference for the algorithm shape (patch statistics, rejecting clipped and
 * non-opaque pixels, solving for the neutralising gains rather than copying a
 * Kelvin table): Lightcraft, a clean-room Lightroom-alike licensed
 * MIT OR Apache-2.0 (tmp/render-audit-20261012/lightcraft-source/lightcraft-main,
 * LICENSE-MIT / LICENSE-APACHE), crates/pipeline/src/auto.rs (auto_wb) and
 * crates/engine/src/cmd/develop.rs (develop.wbPick). Only the shape is taken:
 * Lightcraft's gains run on its Rec2020 linear camera model, while VIVID's
 * `temperature`/`tint` drive the exponential Scene-side gain model below, so
 * its coefficients are NOT used here.
 *
 * The model being inverted (WorkerCore.applyAdvancedBand line ~603 and
 * GpuShaderBridge.whiteBalanceGain line ~529 — identical formulas, and the
 * gains are applied in LINEAR light):
 *
 *   warmth = temperature * 0.22,  green = tint * 0.24
 *   r = exp(+warmth - green * 0.5)
 *   g = exp(+green)
 *   b = exp(-warmth - green * 0.5)
 *   gains = [r, g, b] / luma(r, g, b)
 *
 * The luma normalisation is a scalar, so neutrality is governed by the three
 * ratios alone. Solving R*r = G*g = B*b in log space gives a closed form:
 *
 *   warmth = 0.5 * ln(B / R)
 *   green  = -ln(G^2 / (R * B)) / 3
 *
 * so both parameters are exact inverses of the renderer's own WB stage — no
 * iteration, no Kelvin table, and no drift when a patch is resampled.
 */

/** Averaged patch statistics in linear light, ready to be solved. */
export interface WbPatchStat {
  red: number;
  green: number;
  blue: number;
  /** Pixels that survived the transparency / exposure filters. */
  accepted: number;
  /** Pixels visited inside the patch bounds. */
  visited: number;
}

/** Result of solving the neutral patch for the Scene's own WB parameters. */
export interface WbPickSolution {
  /** Scene `temperature`, already clamped to the slider's [-1, 1]. */
  temperature: number;
  /** Scene `tint`, already clamped to the slider's [-1, 1]. */
  tint: number;
  /** Unclamped values, for diagnostics: what the patch actually asked for. */
  requestedTemperature: number;
  requestedTint: number;
  /** False when the patch needed more correction than the sliders can give. */
  representable: boolean;
  /**
   * Worst remaining linear channel imbalance after applying the clamped
   * solution, as a ratio (1.0 = perfectly neutral).
   */
  residual: number;
  accepted: number;
  visited: number;
}

/** Accepted when at least this many pixels survived the filters. */
export const WB_MIN_SAMPLES: number = 16;
/** Below this linear value a pixel is treated as too dark to judge colour. */
export const WB_DARK_LIMIT: number = 0.004;
/** Above this linear value a pixel is treated as clipped / overexposed. */
export const WB_BRIGHT_LIMIT: number = 0.98;
/** Alpha below this makes a pixel unusable (transparency, partial selections). */
export const WB_ALPHA_LIMIT: number = 250;

const LUMA_R: number = 0.2126;
const LUMA_G: number = 0.7152;
const LUMA_B: number = 0.0722;

const TEMPERATURE_SCALE: number = 0.22;
const TINT_SCALE: number = 0.24;
/** ln(G^2/(R*B)) = 3 * green, so the solve divides by 3 * TINT_SCALE. */
const TINT_DENOMINATOR: number = 3 * TINT_SCALE;

function clamp(value: number, low: number, high: number): number {
  if (!Number.isFinite(value)) return low;
  return Math.max(low, Math.min(high, value));
}

/** sRGB byte to the linear light the renderer applies white balance in. */
export function srgbByteToLinear(byte: number): number {
  const value = clamp(byte / 255, 0, 1);
  return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
}

export function linearToSrgbByte(value: number): number {
  const safe = clamp(value, 0, 1);
  const encoded = safe <= 0.0031308 ? safe * 12.92 : 1.055 * Math.pow(safe, 1 / 2.4) - 0.055;
  return Math.round(clamp(encoded, 0, 1) * 255);
}

/** The renderer's own gains, duplicated here so the solve can measure itself. */
export function whiteBalanceGains(temperature: number, tint: number): number[] {
  const warmth = temperature * TEMPERATURE_SCALE;
  const green = tint * TINT_SCALE;
  const red = Math.exp(warmth - green * 0.5);
  const greenGain = Math.exp(green);
  const blue = Math.exp(-warmth - green * 0.5);
  const normalise = 1 / Math.max(0.00001, red * LUMA_R + greenGain * LUMA_G + blue * LUMA_B);
  return [red * normalise, greenGain * normalise, blue * normalise];
}

/**
 * Average a bounded patch already expressed in source-pixel coordinates.
 *
 * Averaging happens in linear light because that is where the renderer
 * multiplies the gains; averaging gamma bytes would bias every mid-tone patch.
 * Transparent, near-black and clipped pixels are dropped rather than fixed up,
 * so a highlight-only or shadow-only region fails loudly instead of reporting a
 * cast that is really clipping. `visited` counts the pixels inside the bounds
 * so the caller can distinguish "nothing there" from "nothing usable".
 */
export function samplePatch(pixels: Uint8ClampedArray, width: number, height: number,
  left: number, top: number, right: number, bottom: number,
  stride: number = 4): WbPatchStat {
  const stat: WbPatchStat = { red: 0, green: 0, blue: 0, accepted: 0, visited: 0 };
  if (!pixels || width <= 0 || height <= 0 || stride < 4) return stat;
  const x0 = Math.max(0, Math.min(width - 1, Math.floor(left)));
  const x1 = Math.max(0, Math.min(width - 1, Math.ceil(right)));
  const y0 = Math.max(0, Math.min(height - 1, Math.floor(top)));
  const y1 = Math.max(0, Math.min(height - 1, Math.ceil(bottom)));
  // Bound the work: a 1% patch every N pixels keeps a huge region cheap while
  // still covering it, and the count stays proportional to the area.
  const area = Math.max(1, (x1 - x0 + 1) * (y1 - y0 + 1));
  const step = Math.max(1, Math.floor(Math.sqrt(area / 4096)));
  let sumR = 0;
  let sumG = 0;
  let sumB = 0;
  for (let y = y0; y <= y1; y += step) {
    for (let x = x0; x <= x1; x += step) {
      const offset = (y * width + x) * stride;
      const alpha = stride > 3 ? pixels[offset + 3] : 255;
      stat.visited++;
      if (alpha < WB_ALPHA_LIMIT) continue;
      const red = srgbByteToLinear(pixels[offset]);
      const green = srgbByteToLinear(pixels[offset + 1]);
      const blue = srgbByteToLinear(pixels[offset + 2]);
      const peak = Math.max(red, green, blue);
      const low = Math.min(red, green, blue);
      if (peak > WB_BRIGHT_LIMIT || low < WB_DARK_LIMIT) continue;
      sumR += red;
      sumG += green;
      sumB += blue;
      stat.accepted++;
    }
  }
  if (stat.accepted > 0) {
    stat.red = sumR / stat.accepted;
    stat.green = sumG / stat.accepted;
    stat.blue = sumB / stat.accepted;
  }
  return stat;
}

/**
 * Solve a linear-light patch average for Scene `temperature` / `tint`.
 *
 * Returns clamped values plus `representable` and `residual`, so a patch that
 * is outside what the two sliders can express is reported honestly instead of
 * silently producing a wrong pick.
 */
export function solveWhiteBalance(stat: WbPatchStat, currentTemperature: number = 0,
  currentTint: number = 0): WbPickSolution {
  const fallback: WbPickSolution = {
    temperature: currentTemperature, tint: currentTint,
    requestedTemperature: currentTemperature, requestedTint: currentTint,
    representable: true, residual: 1, accepted: stat ? stat.accepted : 0,
    visited: stat ? stat.visited : 0,
  };
  if (!stat || stat.accepted < WB_MIN_SAMPLES) {
    fallback.representable = false;
    fallback.residual = Number.NaN;
    return fallback;
  }
  const red = Math.max(1e-6, stat.red);
  const green = Math.max(1e-6, stat.green);
  const blue = Math.max(1e-6, stat.blue);
  const warmth = 0.5 * Math.log(blue / red);
  const requestedTemperature = warmth / TEMPERATURE_SCALE;
  // ln(G^2/(R*B)) = -3 * green, because a positive green gain raises G and
  // lowers R/B. Negate it so a magenta-cast patch (G below R/B) asks for a
  // positive green tint.
  const requestedTint = -Math.log((green * green) / (red * blue)) / TINT_DENOMINATOR;
  const temperature = clamp(requestedTemperature, -1, 1);
  const tint = clamp(requestedTint, -1, 1);
  const representable = Math.abs(requestedTemperature - temperature) < 1e-6 &&
    Math.abs(requestedTint - tint) < 1e-6;
  // Measure what the CLAMPED answer leaves behind, through the renderer's own
  // gains, so the number means something to the user.
  const gains = whiteBalanceGains(temperature, tint);
  const balanced: number[] = [red * gains[0], green * gains[1], blue * gains[2]];
  const high = Math.max(balanced[0], balanced[1], balanced[2]);
  const low = Math.min(balanced[0], balanced[1], balanced[2]);
  return {
    temperature: temperature,
    tint: tint,
    requestedTemperature: requestedTemperature,
    requestedTint: requestedTint,
    representable: representable,
    residual: low > 0 ? high / low : Number.POSITIVE_INFINITY,
    accepted: stat.accepted,
    visited: stat.visited,
  };
}

/** Sample then solve in one step, the entry point a command would call. */
export function pickWhiteBalance(pixels: Uint8ClampedArray, width: number, height: number,
  left: number, top: number, right: number, bottom: number, stride: number = 4,
  currentTemperature: number = 0, currentTint: number = 0): WbPickSolution {
  const stat = samplePatch(pixels, width, height, left, top, right, bottom, stride);
  return solveWhiteBalance(stat, currentTemperature, currentTint);
}

/**
 * Whether applying (temperature, tint) to this patch leaves any visible cast.
 * Used by the regression tests to prove the solve is invertible rather than
 * merely plausible.
 */
export function patchResidual(stat: WbPatchStat, temperature: number, tint: number): number {
  const gains = whiteBalanceGains(temperature, tint);
  const balanced: number[] = [
    Math.max(1e-6, stat.red) * gains[0],
    Math.max(1e-6, stat.green) * gains[1],
    Math.max(1e-6, stat.blue) * gains[2],
  ];
  const high = Math.max(balanced[0], balanced[1], balanced[2]);
  const low = Math.min(balanced[0], balanced[1], balanced[2]);
  return low > 0 ? high / low : Number.POSITIVE_INFINITY;
}
