/**
 * Optics: lens corrections.
 *
 *   distortion           radial remap (barrel / pincushion)
 *   chromaticAberration  lateral chromatic aberration: red and blue are resampled
 *                        at slightly different radii, green is not
 *   vignetteAmount       radial gain, controlled by a midpoint
 *   defringePurple       edge-gated purple fringe suppression
 *   defringeGreen        edge-gated green fringe suppression
 *
 * Stage order is distortion, chromatic aberration, defringe, vignetting. The
 * fringe detector runs BEFORE vignetting on purpose: vignetting changes
 * luminance, and a detector fed a vignetted frame would gate differently at the
 * corners than at the centre for the same physical edge.
 *
 * RADIUS CONVENTION: coordinates are normalized to [-1,1] on each axis with the
 * origin at the frame centre, and the radius is divided by sqrt(2) so that r = 1
 * at the FRAME CORNERS. Every falloff and remap below is authored on that scale.
 *
 * DISTORTION SIGN: `rSrc = r * (1 - distortion * (0.35*r^2 - 0.12*r^4))`.
 * Positive samples from a SMALLER source radius at the periphery, which magnifies
 * the periphery and therefore straightens lines that bow OUTWARD, i.e. it
 * corrects barrel distortion. Negative does the opposite and corrects pincushion.
 * Zero is exactly identity.
 *
 * This module is pure: no imports, no I/O, no randomness, and it never mutates
 * its input.
 *
 * WHAT THIS DOES NOT CLAIM: there is no Adobe parity here and none is possible,
 * because Adobe's kernels are not public and depend on per-lens profiles this
 * module has no access to. The distortion model is a two-term radial polynomial,
 * the vignetting falloff is a smoothstep rather than a measured illumination
 * profile, and the fringe detector is a hue-band membership gated by a local
 * luminance gradient rather than a trained classifier.
 */

const SQRT2: number = 1.4142135623730951;

/** Distortion polynomial terms at full slider. Chosen so the corners move by
 *  about 23% of the radius at the extreme, which is a strong but usable
 *  correction and stays monotone (see the tests). */
const DISTORTION_K1: number = 0.35;
const DISTORTION_K2: number = 0.12;

/** Vignetting depth at full slider, as a fraction of unity gain. */
const VIGNETTE_DEPTH: number = 0.7;
/** Half-width of the smoothstep window used for the vignette falloff. */
const VIGNETTE_WINDOW: number = 0.35;
/** Never let the vignette gain reach zero: a fully black corner cannot be
 *  recovered by moving the slider back, which surprises users. */
const VIGNETTE_MIN_GAIN: number = 0.05;

/** Lateral CA scale at full slider, as a fraction of the radius. */
const CA_SCALE: number = 0.006;

/** Local luminance gradient (0..255 per pixel) at which the defringe detector
 *  considers a pixel to be on an edge. Below it the pixel is left alone, which
 *  is what keeps a genuinely purple object from being desaturated. */
const DEFRINGE_EDGE_FLOOR: number = 6;

/** Radius over which the edge gate is dilated. A fringe is usually 2-4 pixels
 *  wide, and the INTERIOR of such a fringe has no immediate luminance gradient of
 *  its own — only its two boundaries do. Gating on the raw gradient therefore
 *  corrects the boundaries and leaves the middle of the fringe untouched, which
 *  measured as exactly half the fringe energy surviving at full strength. Taking
 *  the local maximum over this radius makes the whole width of a real fringe
 *  count as an edge, while a flat region still dilates to exactly zero. */
const DEFRINGE_EDGE_RADIUS: number = 2;
/** Support of the defringe detector: one row/column for the gradient
 *  (`gradientMagnitude`) plus `DEFRINGE_EDGE_RADIUS` for the dilation. */
const DEFRINGE_SUPPORT: number = DEFRINGE_EDGE_RADIUS + 1;

export interface OpticsParams {
  distortion: number;
  vignetteAmount: number;
  vignetteMidpoint: number;
  chromaticAberration: number;
  defringePurple: number;
  defringeGreen: number;
  /**
   * Whole-frame reference for a render that only sees a region.
   *
   * `[x, y, scaleX, scaleY, fullWidth, fullHeight]`: buffer pixel (bx, by)
   * covers frame pixels [x + bx*scaleX, x + (bx+1)*scaleX), and the full frame is
   * fullWidth x fullHeight. Omitted (or malformed) means "the buffer IS the
   * frame", so every existing caller and every previously published render is
   * unchanged.
   *
   * Every radial quantity in this module — the distortion/CA resample centre and
   * the vignette falloff — is defined on the WHOLE frame. A zoom tile is a window
   * into that frame, not a frame of its own: without this reference its own
   * centre and radius are used, which puts the optical centre in the middle of the
   * tile instead of the middle of the photo. This is exactly what
   * `ImageProcessor.regionSnapshot` writes into `session.renderViewport` and what
   * `ImageProcessor.plainOptics` forwards here.
   */
  frame?: number[];
}

/** Whole-frame coordinate system in use for one call. */
interface OpticsFrameView {
  x: number;
  y: number;
  scaleX: number;
  scaleY: number;
  width: number;
  height: number;
}

/**
 * Resolve the frame reference. A missing, incomplete or non-finite reference
 * falls back to the buffer being its own frame, which is the historical
 * behaviour and keeps a malformed sidecar from poisoning the render.
 */
function frameViewFor(params: OpticsParams, width: number, height: number): OpticsFrameView {
  const full: OpticsFrameView = { x: 0, y: 0, scaleX: 1, scaleY: 1, width: width, height: height };
  const frame = params.frame;
  if (!frame || frame.length !== 6) return full;
  const view: OpticsFrameView = {
    x: frame[0], y: frame[1], scaleX: frame[2], scaleY: frame[3],
    width: frame[4], height: frame[5],
  };
  if (!Number.isFinite(view.x) || !Number.isFinite(view.y) ||
    !Number.isFinite(view.scaleX) || !Number.isFinite(view.scaleY) ||
    !Number.isFinite(view.width) || !Number.isFinite(view.height)) return full;
  if (view.scaleX <= 0 || view.scaleY <= 0 || view.width <= 0 || view.height <= 0) return full;
  return view;
}

/** True when the buffer is the whole frame (no reprojection needed). */
function isWholeFrame(view: OpticsFrameView, width: number, height: number): boolean {
  return view.x === 0 && view.y === 0 && view.scaleX === 1 && view.scaleY === 1 &&
    view.width === width && view.height === height;
}

/**
 * Frame-normalised coordinates of a buffer pixel, and the radius derived from
 * them. `[nx, ny, radius]`; the radius is divided by sqrt(2), so it is 1 at the
 * frame corners.
 */
function frameCoordinates(x: number, y: number, view: OpticsFrameView): number[] {
  const fx = view.x + (x + 0.5) * view.scaleX;
  const fy = view.y + (y + 0.5) * view.scaleY;
  const nx = 2 * fx / view.width - 1;
  const ny = 2 * fy / view.height - 1;
  return [nx, ny, Math.sqrt(nx * nx + ny * ny) / SQRT2];
}

export function opticsDefaults(): OpticsParams {
  return {
    distortion: 0,
    vignetteAmount: 0,
    vignetteMidpoint: 0.5,
    chromaticAberration: 0,
    defringePurple: 0,
    defringeGreen: 0,
  };
}

function clampMagnitude(input: number, limit: number): number {
  if (!Number.isFinite(input)) return 0;
  return Math.max(-limit, Math.min(limit, input));
}

function clampUnit(input: number): number {
  if (!Number.isFinite(input)) return 0;
  return Math.max(0, Math.min(1, input));
}

/** True when every stage is at its own no-op value. */
export function opticsIsIdentity(p: OpticsParams): boolean {
  if (p === null || p === undefined) return true;
  return clampMagnitude(p.distortion, 1) === 0 &&
    clampMagnitude(p.vignetteAmount, 1) === 0 &&
    clampMagnitude(p.chromaticAberration, 1) === 0 &&
    clampUnit(p.defringePurple) === 0 &&
    clampUnit(p.defringeGreen) === 0;
}

/**
 * Largest normalized radius (1 at the frame corners) reached by the rectangle
 * [left, top]-[right, bottom], given in whole-frame pixel coordinates.
 *
 * The radius is convex, so its maximum over an axis-aligned rectangle is at one
 * of the four corners. A detail tile uses this to bound its own optics halo: a
 * tile near the frame centre needs a much smaller halo than one at a corner, and
 * using the whole frame's worst case would inflate every tile read.
 */
export function opticsMaxRadius(left: number, top: number, right: number, bottom: number,
  frameWidth: number, frameHeight: number): number {
  const w = Math.max(1, frameWidth);
  const h = Math.max(1, frameHeight);
  const xs: number[] = [left, right];
  const ys: number[] = [top, bottom];
  let best = 0;
  for (const fx of xs) {
    for (const fy of ys) {
      const nx = 2 * fx / w - 1;
      const ny = 2 * fy / h - 1;
      const radius = Math.sqrt(nx * nx + ny * ny) / SQRT2;
      if (radius > best) best = radius;
    }
  }
  return Math.max(0, Math.min(1, best));
}

/**
 * Upper bound, in WHOLE-FRAME PIXELS, on how far the optics stages can move a
 * sample that lies at normalized radius `regionRadiusMax`.
 *
 * Distortion moves a sample by |a| * (K1*r^3 - K2*r^5) in normalized radius, and
 * lateral CA moves red/blue by |a| * CA_SCALE * r^2. Both are monotone in r, so
 * the worst case over a tile is at the tile's own largest radius. The normalized
 * displacement is converted to pixels with D/2 (D = frame diagonal), which is an
 * upper bound on the frame's pixel-per-radius scale in every direction.
 *
 * A missing or malformed `params.frame` means the buffer is its own frame: that
 * is the historical whole-frame call, which samples only within its own buffer
 * and therefore needs no halo. Returning 0 keeps that path byte-for-byte
 * unchanged and makes "both sliders at zero" cost exactly nothing.
 */
export function opticsNeighborhoodRadius(params: OpticsParams, frameWidth: number,
  frameHeight: number, regionRadiusMax: number): number {
  if (params === null || params === undefined) return 0;
  const frame = params.frame;
  if (!frame || frame.length !== 6) return 0;
  const w = Math.max(1, frameWidth);
  const h = Math.max(1, frameHeight);
  const radius = Math.max(0, Math.min(1,
    Number.isFinite(regionRadiusMax) ? regionRadiusMax : 0));
  const r2 = radius * radius;
  const r3 = r2 * radius;
  const r5 = r3 * r2;
  const distortion = Math.abs(clampMagnitude(params.distortion, 1)) *
    (DISTORTION_K1 * r3 - DISTORTION_K2 * r5);
  const chroma = Math.abs(clampMagnitude(params.chromaticAberration, 1)) * CA_SCALE * r2;
  return (distortion + chroma) * Math.sqrt(w * w + h * h) / 2;
}

/**
 * Halo, in WHOLE-FRAME pixels, that a band/tile must read beyond its target
 * rectangle so that `applyOptics` on the expanded buffer is byte-identical to
 * the whole-frame render inside the target rectangle.
 *
 * Distortion and lateral CA are covered by `opticsNeighborhoodRadius`; the
 * defringe detector has a fixed support (`DEFRINGE_SUPPORT`) that the radius
 * bound does not describe, so an active defringe contributes it directly.
 * The distortion/CA bound is evaluated on the expanded rectangle until it
 * stops growing, exactly because the displacement is monotone in radius.
 *
 * `params.frame` is forced to the whole frame here: the rectangle is expressed
 * in whole-frame pixels, so the radius bound must use that coordinate system
 * even when the caller's params came from a region snapshot.
 */
export function opticsHaloPadForRect(params: OpticsParams, left: number, top: number,
  right: number, bottom: number, fullWidth: number, fullHeight: number): number {
  if (params === null || params === undefined) return 0;
  if (opticsIsIdentity(params)) return 0;
  const probe: OpticsParams = {
    distortion: params.distortion,
    vignetteAmount: params.vignetteAmount,
    vignetteMidpoint: params.vignetteMidpoint,
    chromaticAberration: params.chromaticAberration,
    defringePurple: params.defringePurple,
    defringeGreen: params.defringeGreen,
    frame: [0, 0, 1, 1, fullWidth, fullHeight],
  };
  let pad = (clampUnit(probe.defringePurple) > 0 || clampUnit(probe.defringeGreen) > 0)
    ? DEFRINGE_SUPPORT : 0;
  for (let round = 0; round < 3; round++) {
    const radius = opticsMaxRadius(left - pad, top - pad, right + pad, bottom + pad,
      fullWidth, fullHeight);
    const halo = opticsNeighborhoodRadius(probe, fullWidth, fullHeight, radius);
    const next = halo > 0 ? Math.ceil(halo) + 1 : 0;
    if (next <= pad) break;
    pad = next;
  }
  return pad;
}

/** Stage 4: vignetting. The falloff radius is a WHOLE-FRAME radius, so a zoom
 *  tile keeps the photo's illumination profile instead of inventing its own. */
function applyVignette(input: Uint8ClampedArray, width: number, height: number,
  view: OpticsFrameView, amount: number, midpoint: number): Uint8ClampedArray {
  const clamped = clampMagnitude(amount, 1);
  if (clamped === 0) return input;
  const output = new Uint8ClampedArray(input.length);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const p = (y * width + x) * 4;
      const gain = vignetteGain(frameCoordinates(x, y, view)[2], clamped, midpoint);
      output[p] = input[p] * gain;
      output[p + 1] = input[p + 1] * gain;
      output[p + 2] = input[p + 2] * gain;
      output[p + 3] = input[p + 3];
    }
  }
  return output;
}

/**
 * Radial factor applied to the source radius for distortion.
 *
 * Returns 1 exactly when `amount` is 0, so a zero slider is an exact identity
 * and not merely close to one.
 */
export function distortionScale(radius: number, amount: number): number {
  const clamped = clampMagnitude(amount, 1);
  if (clamped === 0) return 1;
  const r2 = radius * radius;
  return 1 - clamped * (DISTORTION_K1 * r2 - DISTORTION_K2 * r2 * r2);
}

/**
 * Vignette gain at a normalized radius.
 *
 * The falloff is a smoothstep whose HALF-STRENGTH point is exactly `midpoint`,
 * so the control genuinely moves where the falloff happens rather than merely
 * scaling its depth. A gain of 1 is returned at the centre regardless of the
 * amount, and at any radius when the amount is 0.
 */
export function vignetteGain(radius: number, amount: number, midpoint: number): number {
  const clamped = clampMagnitude(amount, 1);
  if (clamped === 0) return 1;
  const half = Math.max(0.05, Math.min(0.95, Number.isFinite(midpoint) ? midpoint : 0.5));
  const low = half - VIGNETTE_WINDOW;
  const high = half + VIGNETTE_WINDOW;
  let t = (radius - low) / (high - low);
  t = Math.max(0, Math.min(1, t));
  const falloff = t * t * (3 - 2 * t);
  return Math.max(VIGNETTE_MIN_GAIN, 1 + clamped * VIGNETTE_DEPTH * falloff);
}

/** Bilinear sample of the RGB channels, with clamped edges. */
function sampleRgb(rgba: Uint8ClampedArray, width: number, height: number,
  sx: number, sy: number): number[] {
  const x = Math.max(0, Math.min(width - 1, sx));
  const y = Math.max(0, Math.min(height - 1, sy));
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const x1 = Math.min(width - 1, x0 + 1);
  const y1 = Math.min(height - 1, y0 + 1);
  const fx = x - x0;
  const fy = y - y0;
  const p00 = (y0 * width + x0) * 4;
  const p01 = (y0 * width + x1) * 4;
  const p10 = (y1 * width + x0) * 4;
  const p11 = (y1 * width + x1) * 4;
  const result: number[] = [];
  for (let channel = 0; channel < 3; channel++) {
    const top = rgba[p00 + channel] * (1 - fx) + rgba[p01 + channel] * fx;
    const bottom = rgba[p10 + channel] * (1 - fx) + rgba[p11 + channel] * fx;
    result.push(top * (1 - fy) + bottom * fy);
  }
  return result;
}

/**
 * Resample while scaling the radius of every pixel by `scaleFor(radius)`.
 * Shared by the distortion and chromatic-aberration stages so both use one
 * sampler and one edge convention.
 *
 * `view` defines where this buffer sits in the whole frame. All radial
 * quantities come from frame coordinates, so a zoom tile corrects around the
 * photo's optical centre rather than around the middle of the tile.
 */
function resampleRadial(input: Uint8ClampedArray, width: number, height: number,
  view: OpticsFrameView, scaleFor: (radius: number) => number,
  channels: number[]): Uint8ClampedArray {
  const output = new Uint8ClampedArray(input.length);
  const centreX = view.width / 2;
  const centreY = view.height / 2;
  const reproject = !isWholeFrame(view, width, height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const destination = (y * width + x) * 4;
      const coordinates = frameCoordinates(x, y, view);
      const factor = scaleFor(coordinates[2]);
      // Frame sample position, then back into this buffer's index space.
      let sampleX = (coordinates[0] * factor + 1) * centreX - 0.5;
      let sampleY = (coordinates[1] * factor + 1) * centreY - 0.5;
      if (reproject) {
        sampleX = (sampleX - view.x + 0.5) / view.scaleX - 0.5;
        sampleY = (sampleY - view.y + 0.5) / view.scaleY - 0.5;
      }
      const sample = sampleRgb(input, width, height, sampleX, sampleY);
      for (let channel = 0; channel < 4; channel++) {
        output[destination + channel] = input[destination + channel];
      }
      for (let i = 0; i < channels.length; i++) {
        const channel = channels[i];
        output[destination + channel] = sample[channel];
      }
    }
  }
  return output;
}

/** Stage 1: radial distortion. */
function applyDistortion(input: Uint8ClampedArray, width: number, height: number,
  view: OpticsFrameView, amount: number): Uint8ClampedArray {
  const clamped = clampMagnitude(amount, 1);
  if (clamped === 0) return input;
  return resampleRadial(input, width, height, view, (radius: number): number => {
    return distortionScale(radius, clamped);
  }, [0, 1, 2]);
}

/**
 * Stage 2: lateral chromatic aberration.
 *
 * Red and blue are resampled at radii scaled in OPPOSITE directions, which is
 * what lateral CA is; green is copied through untouched. Positive and negative
 * amounts are mirror images.
 */
function applyChromaticAberration(input: Uint8ClampedArray, width: number, height: number,
  view: OpticsFrameView, amount: number): Uint8ClampedArray {
  const clamped = clampMagnitude(amount, 1);
  if (clamped === 0) return input;
  const red = resampleRadial(input, width, height, view, (radius: number): number => {
    return 1 + clamped * CA_SCALE * radius;
  }, [0]);
  const blue = resampleRadial(input, width, height, view, (radius: number): number => {
    return 1 - clamped * CA_SCALE * radius;
  }, [2]);
  // Green stays exactly as it was; only red and blue are allowed to move.
  for (let i = 0; i < input.length; i += 4) {
    red[i + 2] = blue[i + 2];
    red[i + 1] = input[i + 1];
    red[i + 3] = input[i + 3];
  }
  return red;
}

/** Luminance gradient magnitude, used to gate the fringe detector to edges. */
function gradientMagnitude(input: Uint8ClampedArray, width: number, height: number): Float32Array {
  const luma = new Float32Array(width * height);
  for (let i = 0, p = 0; i < luma.length; i++, p += 4) {
    luma[i] = input[p] * 0.2126 + input[p + 1] * 0.7152 + input[p + 2] * 0.0722;
  }
  const gradient = new Float32Array(width * height);
  for (let y = 0; y < height; y++) {
    const up = y > 0 ? y - 1 : 0;
    const down = y < height - 1 ? y + 1 : height - 1;
    for (let x = 0; x < width; x++) {
      const left = x > 0 ? x - 1 : 0;
      const right = x < width - 1 ? x + 1 : width - 1;
      const gx = luma[y * width + right] - luma[y * width + left];
      const gy = luma[down * width + x] - luma[up * width + x];
      gradient[y * width + x] = Math.sqrt(gx * gx + gy * gy) * 0.5;
    }
  }
  return gradient;
}

/** Separable windowed maximum, used to widen the edge gate. */
function dilateMax(input: Float32Array, width: number, height: number,
  radius: number): Float32Array {
  const horizontal = new Float32Array(input.length);
  for (let y = 0; y < height; y++) {
    const row = y * width;
    for (let x = 0; x < width; x++) {
      let best = 0;
      const from = Math.max(0, x - radius);
      const to = Math.min(width - 1, x + radius);
      for (let k = from; k <= to; k++) {
        const candidate = input[row + k];
        if (candidate > best) best = candidate;
      }
      horizontal[row + x] = best;
    }
  }
  const result = new Float32Array(input.length);
  for (let y = 0; y < height; y++) {
    const from = Math.max(0, y - radius);
    const to = Math.min(height - 1, y + radius);
    for (let x = 0; x < width; x++) {
      let best = 0;
      for (let k = from; k <= to; k++) {
        const candidate = horizontal[k * width + x];
        if (candidate > best) best = candidate;
      }
      result[y * width + x] = best;
    }
  }
  return result;
}

/** How strongly a pixel reads as a purple fringe: red AND blue above green. */
function purpleMembership(r: number, g: number, b: number): number {
  if (r <= g || b <= g) return 0;
  return clampUnit(Math.min(r - g, b - g) / 48);
}

/** How strongly a pixel reads as a green fringe: green above both others. */
function greenMembership(r: number, g: number, b: number): number {
  const other = Math.max(r, b);
  if (g <= other) return 0;
  return clampUnit((g - other) / 48);
}

/**
 * Stage 3: fringe suppression, gated on edges.
 *
 * A fringe is a coloured halo along a high-contrast edge, so the correction is
 * proportional to BOTH the hue membership and the local luminance gradient. The
 * gradient is dilated first, so the whole width of a multi-pixel fringe counts as
 * an edge and not only its two boundaries. In a flat region the gradient is zero
 * and stays zero under the dilation, so a genuinely purple or green object is
 * left EXACTLY untouched — which is the difference between defringing and a hue
 * shift, and is asserted directly by the tests.
 */
function applyDefringe(input: Uint8ClampedArray, width: number, height: number,
  purple: number, green: number): Uint8ClampedArray {
  const purpleAmount = clampUnit(purple);
  const greenAmount = clampUnit(green);
  if (purpleAmount === 0 && greenAmount === 0) return input;
  const output = new Uint8ClampedArray(input.length);
  output.set(input);
  const gradient = dilateMax(gradientMagnitude(input, width, height), width, height,
    DEFRINGE_EDGE_RADIUS);
  for (let i = 0, p = 0; i < gradient.length; i++, p += 4) {
    const edge = clampUnit(gradient[i] / DEFRINGE_EDGE_FLOOR);
    if (edge === 0) continue;
    const r = input[p];
    const g = input[p + 1];
    const b = input[p + 2];
    if (purpleAmount > 0) {
      const membership = purpleMembership(r, g, b);
      if (membership > 0) {
        const suppression = purpleAmount * edge * membership;
        output[p] = r - (r - g) * suppression;
        output[p + 2] = b - (b - g) * suppression;
      }
    }
    if (greenAmount > 0) {
      const membership = greenMembership(r, g, b);
      if (membership > 0) {
        const suppression = greenAmount * edge * membership;
        const target = (r + b) / 2;
        output[p + 1] = g - (g - target) * suppression;
      }
    }
  }
  return output;
}

/**
 * Apply the optics stages in order. Always returns a freshly allocated buffer
 * (never the input), so a caller can publish the result without worrying about
 * aliasing, and the input is never written to.
 */
export function applyOptics(rgba: Uint8ClampedArray, width: number, height: number,
  params: OpticsParams): Uint8ClampedArray {
  const w = Math.max(1, Math.floor(width));
  const h = Math.max(1, Math.floor(height));
  const expected = w * h * 4;
  // A short buffer is a caller bug; copying what is there is byte-exact and
  // cannot read out of bounds, which is what the safety tests require.
  let source: Uint8ClampedArray;
  if (!rgba || rgba.length < expected) {
    const safe = new Uint8ClampedArray(expected);
    if (rgba) {
      for (let i = 0; i < Math.min(rgba.length, expected); i++) safe[i] = rgba[i];
    }
    source = safe;
  } else {
    source = rgba;
  }
  const settings: OpticsParams = params ?? opticsDefaults();
  if (opticsIsIdentity(settings)) {
    return new Uint8ClampedArray(source.subarray(0, expected));
  }
  // Where this buffer sits in the whole frame. Every radial stage below reads
  // the frame reference, so a zoom tile corrects around the photo's optical
  // centre instead of the middle of the tile.
  const view = frameViewFor(settings, w, h);
  let current = source;
  // Each stage returns its input unchanged when its own amount is 0, so an
  // inactive stage costs one comparison rather than a pass.
  current = applyDistortion(current, w, h, view, settings.distortion);
  current = applyChromaticAberration(current, w, h, view, settings.chromaticAberration);
  current = applyDefringe(current, w, h, settings.defringePurple, settings.defringeGreen);
  current = applyVignette(current, w, h, view, settings.vignetteAmount, settings.vignetteMidpoint);
  // Every stage was bypassed, so nothing allocated a buffer: copy rather than
  // hand back the caller's array, which would alias it.
  if (current === source) return new Uint8ClampedArray(source.subarray(0, expected));
  if (current.length !== expected) return new Uint8ClampedArray(current.subarray(0, expected));
  return current;
}
