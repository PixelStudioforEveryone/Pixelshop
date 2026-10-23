/**
 * Luminance / colour "range" selections, computed from the source pixels.
 *
 * This is the Camera Raw range mask: instead of drawing geometry, the user
 * narrows a selection by where a pixel sits in the image's tonal or chromatic
 * distribution. It is deliberately analytic — no model, no training data, no
 * randomness — so it is fully deterministic and can be checked against an
 * independent evaluation of the same equation.
 *
 * Two decisions worth stating explicitly:
 *
 *  - The raster is built at RANGE_MASK_MAX_EDGE rather than at source
 *    resolution. A range selection is a low-frequency mask, so the extra
 *    resolution buys nothing visually while it would multiply the sidecar and
 *    the per-render copy. The shared raster resampler upsamples it with
 *    bilinear interpolation, which is the right filter for a smooth mask.
 *  - Luma is Rec.709 on the display-referred (sRGB-encoded) values. That is
 *    what Camera Raw thresholds its luminance range mask against; thresholding
 *    scene-linear values would move every edge.
 */
import { RangeMaskData } from '../models/Mask';

/** Longest edge of a range raster; see the note above. */
export const RANGE_MASK_MAX_EDGE: number = 192;

/** Rec.709 luma weights, applied to the display-referred values. */
const LUMA_R: number = 0.2126;
const LUMA_G: number = 0.7152;
const LUMA_B: number = 0.0722;

/** An interleaved RGB proxy of the source, already at raster resolution. */
export interface RangeMaskProxy {
  width: number;
  height: number;
  /** width*height*3 bytes, RGB, 0..255. */
  rgb: Uint8Array;
}

/** A luminance window in 0..1 of Rec.709 luma. */
export interface RangeMaskWindow {
  min: number;
  max: number;
}

/** Hermite smoothstep, the standard soft-threshold curve. */
function smoothStep(edge0: number, edge1: number, x: number): number {
  if (edge1 <= edge0) return x < edge0 ? 0 : 1;
  let t = (x - edge0) / (edge1 - edge0);
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  return t * t * (3 - 2 * t);
}

/**
 * Box-average the source RGBA down to a bounded RGB proxy.
 *
 * Box averaging rather than point sampling: a single sample per output pixel
 * would make the mask depend on which pixel happened to be picked, so a noisy
 * or finely textured area would produce a visibly different selection than the
 * same area averaged. Averaging is also what makes the raster stable when the
 * caller feeds a downscaled preview instead of the full-resolution source.
 */
export function buildProxy(rgba: Uint8Array, srcWidth: number, srcHeight: number,
  maxEdge: number = RANGE_MASK_MAX_EDGE): RangeMaskProxy {
  const safeSrcWidth = Math.max(1, Math.floor(srcWidth));
  const safeSrcHeight = Math.max(1, Math.floor(srcHeight));
  const limit = Math.max(1, Math.floor(maxEdge));
  const scale = Math.min(1, limit / Math.max(safeSrcWidth, safeSrcHeight));
  const width = Math.max(1, Math.round(safeSrcWidth * scale));
  const height = Math.max(1, Math.round(safeSrcHeight * scale));
  const rgb = new Uint8Array(width * height * 3);
  const available = rgba.length;
  for (let y = 0; y < height; y++) {
    const y0 = Math.floor(y * safeSrcHeight / height);
    const y1 = Math.max(y0 + 1, Math.floor((y + 1) * safeSrcHeight / height));
    for (let x = 0; x < width; x++) {
      const x0 = Math.floor(x * safeSrcWidth / width);
      const x1 = Math.max(x0 + 1, Math.floor((x + 1) * safeSrcWidth / width));
      let sumR = 0;
      let sumG = 0;
      let sumB = 0;
      let count = 0;
      for (let sy = y0; sy < y1 && sy < safeSrcHeight; sy++) {
        let index = (sy * safeSrcWidth + x0) * 4;
        for (let sx = x0; sx < x1 && sx < safeSrcWidth; sx++) {
          if (index + 2 < available) {
            sumR += rgba[index];
            sumG += rgba[index + 1];
            sumB += rgba[index + 2];
            count++;
          }
          index += 4;
        }
      }
      const target = (y * width + x) * 3;
      if (count > 0) {
        rgb[target] = Math.round(sumR / count);
        rgb[target + 1] = Math.round(sumG / count);
        rgb[target + 2] = Math.round(sumB / count);
      }
    }
  }
  return { width: width, height: height, rgb: rgb };
}

/**
 * A useful starting window for this image: the 5th to 95th luma percentile.
 *
 * Camera Raw leaves the sliders at their full extent and expects the user to
 * narrow them; starting there would make the tool appear to do nothing on
 * first use. A histogram-derived window instead produces a selection that is
 * immediately visible and clearly editable. A degenerate (flat) image widens
 * to a minimum span so the window is never zero-width.
 */
export function luminanceWindow(proxy: RangeMaskProxy): RangeMaskWindow {
  const histogram = new Uint32Array(256);
  let total = 0;
  const count = proxy.width * proxy.height;
  for (let index = 0; index < count; index++) {
    const offset = index * 3;
    const luma = LUMA_R * proxy.rgb[offset] + LUMA_G * proxy.rgb[offset + 1] +
      LUMA_B * proxy.rgb[offset + 2];
    histogram[Math.max(0, Math.min(255, Math.round(luma)))]++;
    total++;
  }
  if (total === 0) return { min: 0, max: 1 };
  const lowTarget = total * 0.05;
  const highTarget = total * 0.95;
  let running = 0;
  let lowBin = 0;
  let highBin = 255;
  let lowFound = false;
  for (let bin = 0; bin < 256; bin++) {
    running += histogram[bin];
    if (!lowFound && running >= lowTarget) {
      lowBin = bin;
      lowFound = true;
    }
    if (running >= highTarget) {
      highBin = bin;
      break;
    }
  }
  let min = lowBin / 255;
  let max = highBin / 255;
  // Never hand back a window so narrow that the mask is a thin tonal slice with
  // no visible content; widen symmetrically around the centre instead.
  const minimumSpan = 0.08;
  if (max - min < minimumSpan) {
    const centre = (min + max) * 0.5;
    min = Math.max(0, centre - minimumSpan * 0.5);
    max = Math.min(1, centre + minimumSpan * 0.5);
  }
  return { min: min, max: max };
}

/**
 * Evaluate the range selection into a bounded soft alpha.
 *
 * The luminance window and the optional colour range are ANDed, matching
 * Camera Raw: a pixel has to be inside the tonal window *and* close enough to
 * the picked colour.
 *
 * Ordering of the luminance edges is not significant — the two slider values
 * are sorted, so a user who drags them past each other still gets a valid band
 * rather than an empty mask.
 */
export function buildRangeAlpha(proxy: RangeMaskProxy, params: RangeMaskData): Uint8Array {
  const width = proxy.width;
  const height = proxy.height;
  const alpha = new Uint8Array(width * height);
  const requestedMin = Math.max(0, Math.min(1, params.min));
  const requestedMax = Math.max(0, Math.min(1, params.max));
  // A window narrower than this is widened symmetrically. The two sliders can
  // meet, and a zero-width window would otherwise match at most a single luma
  // level — with a smooth edge, in fact, nothing at all. Widening keeps the
  // control usable while still selecting only a thin tonal slice.
  const minimumWidth = 0.01;
  let lowerEdge = Math.min(requestedMin, requestedMax);
  let upperEdge = Math.max(requestedMin, requestedMax);
  if (upperEdge - lowerEdge < minimumWidth) {
    const centre = (lowerEdge + upperEdge) * 0.5;
    lowerEdge = Math.max(0, centre - minimumWidth * 0.5);
    upperEdge = Math.min(1, centre + minimumWidth * 0.5);
  }
  const smoothness = Math.max(0, Math.min(1, params.smoothness));
  // A zero smoothness still needs a finite transition band, otherwise the mask
  // would alias into a jagged hard-edged selection.
  const requestedHalf = Math.max(0.0005, smoothness * 0.5);
  // The two transitions must not overlap: their product is what selects the
  // band, and overlapping ramps multiply down towards zero in the middle,
  // turning a narrow window into an empty one instead of a thin slice.
  const half = Math.min(requestedHalf, (upperEdge - lowerEdge) * 0.5);
  const lowerIsOpen = lowerEdge <= 0;
  const upperIsOpen = upperEdge >= 1;

  const targetR = Math.max(0, Math.min(1, params.colorR));
  const targetG = Math.max(0, Math.min(1, params.colorG));
  const targetB = Math.max(0, Math.min(1, params.colorB));
  // Higher amount means a more inclusive colour match, like Camera Raw.
  const radius = 0.04 + Math.max(0, Math.min(1, params.colorAmount)) * 0.6;
  const innerRadius = radius * 0.5;
  const useColor = params.colorEnabled;

  for (let index = 0; index < width * height; index++) {
    const offset = index * 3;
    const r = proxy.rgb[offset] / 255;
    const g = proxy.rgb[offset + 1] / 255;
    const b = proxy.rgb[offset + 2] / 255;
    let weight = 1;
    if (!lowerIsOpen || !upperIsOpen) {
      const luma = LUMA_R * r + LUMA_G * g + LUMA_B * b;
      const lower = lowerIsOpen ? 1 : smoothStep(lowerEdge - half, lowerEdge + half, luma);
      const upper = upperIsOpen ? 1 : 1 - smoothStep(upperEdge - half, upperEdge + half, luma);
      weight = lower * upper;
    }
    if (useColor && weight > 0) {
      const dr = r - targetR;
      const dg = g - targetG;
      const db = b - targetB;
      const distance = Math.sqrt((dr * dr + dg * dg + db * db) / 3);
      weight *= 1 - smoothStep(innerRadius, radius, distance);
    }
    alpha[index] = Math.max(0, Math.min(255, Math.round(weight * 255)));
  }
  return alpha;
}

/**
 * Mean colour of the pixels currently selected, in 0..1 RGB.
 *
 * This is what the "pick colour range" action samples: it narrows the
 * selection to the colour that is already selected, which is the Camera Raw
 * workflow (keep the colour you have, discard the rest) and needs no eyedropper
 * gesture on the canvas. Returns null when nothing is selected, so the caller
 * can report that instead of narrowing to an arbitrary colour.
 */
export function averageSelectedColor(proxy: RangeMaskProxy, alpha: Uint8Array): number[] | null {
  const count = Math.min(alpha.length, proxy.width * proxy.height);
  let sumR = 0;
  let sumG = 0;
  let sumB = 0;
  let total = 0;
  for (let index = 0; index < count; index++) {
    if (alpha[index] < 128) continue;
    const offset = index * 3;
    sumR += proxy.rgb[offset];
    sumG += proxy.rgb[offset + 1];
    sumB += proxy.rgb[offset + 2];
    total++;
  }
  if (total === 0) return null;
  return [sumR / (total * 255), sumG / (total * 255), sumB / (total * 255)];
}

/**
 * A stable signature of the parameters that produced a raster.
 *
 * Recorded as the raster's provenance key, so a raster can be told apart from
 * one made with different settings without storing the settings twice.
 */
export function rangeSignature(params: RangeMaskData): string {
  const round = (value: number): string => (Math.round(value * 1000) / 1000).toString();
  const color = params.colorEnabled
    ? `c${round(params.colorR)},${round(params.colorG)},${round(params.colorB)},${round(params.colorAmount)}`
    : 'c0';
  return `lum${round(params.min)}-${round(params.max)}s${round(params.smoothness)}/${color}`;
}
