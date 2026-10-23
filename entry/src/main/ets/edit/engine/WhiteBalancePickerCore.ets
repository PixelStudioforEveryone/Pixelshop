/**
 * Point / region white-balance picker — pure numeric core.
 *
 * No ArkUI import, no session access, nothing asynchronous: the caller owns
 * capturing the target identity (photo generation, source PixelMap, target
 * adjustments) before any await, and must re-check it afterwards.
 *
 * This core MUST be fed source pixels: the decoded image for the current
 * camera profile, before the UI's own white balance has been applied. Passing
 * an already-balanced preview would let the picker chase its own output and
 * drift on every repeated sample.
 *
 * What is inverted is VIVID's own white-balance stage, copied verbatim from
 * WorkerCore.applyAdvancedBand (~line 603) and GpuShaderBridge.whiteBalanceGain
 * (~line 529); they are the same formula, and the gains multiply the pixel in
 * LINEAR light:
 *
 *   warmth = temperature * 0.22
 *   green  = tint * 0.24
 *   r = exp(+warmth - green * 0.5)
 *   g = exp(+green)
 *   b = exp(-warmth - green * 0.5)
 *   applied = pixel * [r, g, b] / luma(r, g, b)     // luma cancels in the ratios
 *
 * Neutrality means the three corrected channels are equal. Solving in logs,
 * with R/G/B the linear patch averages:
 *
 *   logR + warmth - 0.5*green = logG + green
 *   logB - warmth - 0.5*green = logG + green
 *
 * subtracting gives  warmth = 0.5 * (logB - logR)
 * adding gives       green  = (logR + logB - 2*logG) / 3
 *
 * (positive green tint raises G and lowers R/B, so a magenta-cast patch — G
 * below R/B — asks for a positive tint). Substituting green = tint * 0.24:
 *
 *   temperature = 0.5 * (logB - logR) / 0.22
 *   tint        = (logR + logB - 2*logG) / 0.72
 *
 * (0.72 = 3 * 0.24). Both are closed forms, exact inverses of the renderers'
 * WB stage — no iteration, no Kelvin table, and repeated sampling of the same
 * patch is idempotent instead of accumulating.
 *
 * Algorithm shape referenced from Lightcraft, a clean-room Lightroom-alike
 * (MIT OR Apache-2.0; tmp/render-audit-20261012/lightcraft-source/
 * lightcraft-main, LICENSE-MIT / LICENSE-APACHE): crates/pipeline/src/auto.rs
 * (auto_wb) and crates/engine/src/cmd/develop.rs (develop.wbPick). Only the
 * shape is taken — Lightcraft's coefficients belong to its Rec2020 linear
 * camera model and are NOT usable here, where the sliders drive the
 * exponential model above.
 */

/** Why a pick did not produce usable parameters. */
export enum WbPickReason {
  /** The patch yielded a usable average. */
  OK = 'ok',
  /** Inputs were unusable (no pixels, bad bounds, non-finite parameter). */
  INVALID = 'invalid',
  /** Every pixel was dropped by the transparency / exposure filters. */
  ALL_FILTERED = 'all-filtered',
  /** Fewer than WB_MIN_SAMPLES usable pixels survived. */
  TOO_FEW = 'too-few',
}

export interface WbPickResult {
  /** True only when temperature/tint describe the patch. Callers must not write otherwise. */
  ok: boolean;
  reason: WbPickReason;
  /** Pixels that survived the filters. */
  accepted: number;
  /** Pixels visited inside the patch bounds. */
  visited: number;
  /** Scene `temperature`, clamped to the slider's [-1, 1]. */
  temperature: number;
  /** Scene `tint`, clamped to the slider's [-1, 1]. */
  tint: number;
  /** True when the patch needed more correction than the sliders can express. */
  clipped: boolean;
  /** Unclamped request, retained for diagnostics even when `clipped`. */
  requestedTemperature: number;
  requestedTint: number;
  /**
   * Worst remaining linear channel imbalance after applying the RETURNED
   * clamped parameters, as a high/low ratio: 1.0 is perfectly neutral.
   * NaN when the pick failed.
   */
  residual: number;
}

/** Below this alpha a pixel is transparent or partly selected, so unusable. */
export const WB_ALPHA_LIMIT: number = 250;
/** Linear channel at or below this is too dark to judge colour. */
export const WB_DARK_LIMIT: number = 0.005;
/** Linear channel at or above this is clipped / unusable. */
export const WB_BRIGHT_LIMIT: number = 0.95;
/** Minimum usable pixels before a pick is trusted. */
export const WB_MIN_SAMPLES: number = 16;

const TEMPERATURE_SCALE: number = 0.22;
const TINT_SCALE: number = 0.24;
const TINT_DENOMINATOR: number = 3 * TINT_SCALE;
const LUMA_R: number = 0.2126;
const LUMA_G: number = 0.7152;
const LUMA_B: number = 0.0722;
const CLIP_EPSILON: number = 1e-6;

function failed(reason: WbPickReason, visited: number = 0, accepted: number = 0): WbPickResult {
  return {
    ok: false, reason: reason, accepted: accepted, visited: visited,
    // Callers must never write these: they describe the failure, not a pick.
    temperature: 0, tint: 0, clipped: false,
    requestedTemperature: 0, requestedTint: 0, residual: Number.NaN,
  };
}

/** sRGB byte to the linear light the white-balance gains multiply in. */
export function wbSrgbToLinear(byte: number): number {
  const value = Math.max(0, Math.min(1, byte / 255));
  return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
}

/** Linear to sRGB byte, used by the regression tests and by read-outs. */
export function wbLinearToSrgb(value: number): number {
  const safe = Math.max(0, Math.min(1, value));
  const encoded = safe <= 0.0031308 ? safe * 12.92 : 1.055 * Math.pow(safe, 1 / 2.4) - 0.055;
  return Math.round(Math.max(0, Math.min(1, encoded)) * 255);
}

/**
 * The renderer's own gains, duplicated here so this core can measure what its
 * clamped answer leaves behind. Kept byte-identical to WorkerCore and
 * GpuShaderBridge by tools/check_white_balance_picker.cjs.
 */
export function wbGains(temperature: number, tint: number): number[] {
  const warmth = temperature * TEMPERATURE_SCALE;
  const green = tint * TINT_SCALE;
  const red = Math.exp(warmth - green * 0.5);
  const greenGain = Math.exp(green);
  const blue = Math.exp(-warmth - green * 0.5);
  const normalise = 1 / Math.max(0.00001, red * LUMA_R + greenGain * LUMA_G + blue * LUMA_B);
  return [red * normalise, greenGain * normalise, blue * normalise];
}

/**
 * Solve neutralising parameters for a linear-light patch average.
 *
 * `red`/`green`/`blue` must already be linear averages of SOURCE pixels; this
 * function knows nothing about how they were collected, which is why the caller
 * can average with any weighting it likes without touching this solve.
 */
export function solveNeutralPatch(red: number, green: number, blue: number,
  currentTemperature: number = 0, currentTint: number = 0): WbPickResult {
  if (!Number.isFinite(red) || !Number.isFinite(green) || !Number.isFinite(blue)) {
    return failed(WbPickReason.INVALID);
  }
  const safeTemperature = Number.isFinite(currentTemperature) ? currentTemperature : 0;
  const safeTint = Number.isFinite(currentTint) ? currentTint : 0;
  const low = Math.min(red, green, blue);
  if (low <= WB_DARK_LIMIT) return failed(WbPickReason.ALL_FILTERED);
  const logR = Math.log(Math.max(1e-9, red));
  const logG = Math.log(Math.max(1e-9, green));
  const logB = Math.log(Math.max(1e-9, blue));
  const requestedTemperature = 0.5 * (logB - logR) / TEMPERATURE_SCALE;
  const requestedTint = (logR + logB - 2 * logG) / TINT_DENOMINATOR;
  const temperature = Math.max(-1, Math.min(1, requestedTemperature));
  const tint = Math.max(-1, Math.min(1, requestedTint));
  const clipped = Math.abs(requestedTemperature - temperature) > CLIP_EPSILON ||
    Math.abs(requestedTint - tint) > CLIP_EPSILON;
  const gains = wbGains(temperature, tint);
  const corrected: number[] = [red * gains[0], green * gains[1], blue * gains[2]];
  const high = Math.max(corrected[0], corrected[1], corrected[2]);
  const low2 = Math.min(corrected[0], corrected[1], corrected[2]);
  return {
    ok: true, reason: WbPickReason.OK, accepted: 0, visited: 0,
    temperature: temperature, tint: tint, clipped: clipped,
    requestedTemperature: requestedTemperature, requestedTint: requestedTint,
    residual: low2 > 0 ? high / low2 : Number.POSITIVE_INFINITY,
    // `accepted`/`visited` are filled in by pickRegion, which owns sampling.
  };
}

/**
 * Average a bounded region of RGBA source pixels in linear light and solve it.
 *
 * Bounds are inclusive integer SOURCE-pixel coordinates already mapped from the
 * tap through the existing crop/rotate/zoom geometry — this function never
 * invents its own coordinate space. A pixel is dropped when it is transparent
 * (alpha < WB_ALPHA_LIMIT) or when ANY linear channel is at/below the dark limit
 * or at/above the bright limit, so a highlight-only or shadow-only region fails
 * loudly instead of reporting a cast that is really clipping. Brightness
 * weighting, if wanted later, belongs in the caller: this core only knows how to
 * solve, not what the user is aiming at.
 */
export function pickRegion(pixels: Uint8ClampedArray, width: number, height: number,
  left: number, top: number, right: number, bottom: number, stride: number = 4,
  currentTemperature: number = 0, currentTint: number = 0): WbPickResult {
  if (!pixels || !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    return failed(WbPickReason.INVALID);
  }
  if (stride < 4) return failed(WbPickReason.INVALID);
  if (pixels.length < width * height * stride) return failed(WbPickReason.INVALID);
  const x0 = Math.max(0, Math.min(width - 1, Math.floor(left)));
  const x1 = Math.max(0, Math.min(width - 1, Math.ceil(right)));
  const y0 = Math.max(0, Math.min(height - 1, Math.floor(top)));
  const y1 = Math.max(0, Math.min(height - 1, Math.ceil(bottom)));
  if (x1 < x0 || y1 < y0) return failed(WbPickReason.INVALID);
  // Bounded work: about 4096 samples whatever the region size, so an accidental
  // full-frame drag cannot stall the UI thread.
  const area = Math.max(1, (x1 - x0 + 1) * (y1 - y0 + 1));
  const step = Math.max(1, Math.floor(Math.sqrt(area / 4096)));
  let sumR = 0;
  let sumG = 0;
  let sumB = 0;
  let visited = 0;
  let accepted = 0;
  for (let y = y0; y <= y1; y += step) {
    for (let x = x0; x <= x1; x += step) {
      const offset = (y * width + x) * stride;
      visited++;
      if (pixels[offset + 3] < WB_ALPHA_LIMIT) continue;
      const red = wbSrgbToLinear(pixels[offset]);
      const green = wbSrgbToLinear(pixels[offset + 1]);
      const blue = wbSrgbToLinear(pixels[offset + 2]);
      const channelLow = Math.min(red, green, blue);
      const channelHigh = Math.max(red, green, blue);
      if (channelLow <= WB_DARK_LIMIT || channelHigh >= WB_BRIGHT_LIMIT) continue;
      sumR += red;
      sumG += green;
      sumB += blue;
      accepted++;
    }
  }
  if (accepted === 0) return failed(WbPickReason.ALL_FILTERED, visited, 0);
  if (accepted < WB_MIN_SAMPLES) return failed(WbPickReason.TOO_FEW, visited, accepted);
  const average = solveNeutralPatch(sumR / accepted, sumG / accepted, sumB / accepted,
    currentTemperature, currentTint);
  average.accepted = accepted;
  average.visited = visited;
  return average;
}
