/**
 * Clone stamp and "content-aware" hole filling for the retouch engine.
 *
 * The fill half is a PatchMatch-based independent implementation (Barnes,
 * Shechtman, Finkelstein & Goldman, "PatchMatch: A Randomized Correspondence
 * Algorithm for Structural Image Editing", SIGGRAPH 2007) used in the
 * inpainting form of Wexler, Shechtman & Irani: every hole pixel holds a
 * nearest-neighbour offset into the known part of the frame, that field is
 * refined by propagation followed by an exponentially shrinking random search.
 * Each sweep then re-estimates the hole from the current offsets and the next
 * sweep scores candidates against that estimate, so the interior of a large
 * hole is judged on evidence rather than on nothing. A candidate is only ever
 * read from outside the hole, contributions are voted only among patches that
 * agree with the destination pixel's own match, and the result is smoothed on
 * flat ground only. This is NOT Adobe Content-Aware Fill. It is an independent
 * implementation written from the published method: no Adobe code, model,
 * training data or heuristic is used or reproduced. It operates on
 * already-rendered 8-bit RGBA and knows nothing about raw files, colour
 * management or layers.
 *
 * Exact bounds, applied before any work happens:
 *   - patchRadius  -> rounded, clamped to 1..5 (a 3x3 .. 11x11 patch), then
 *     clamped to floor((min(width, height) - 1) / 2) so the patch fits in the
 *     frame. If that leaves no room the image is returned unchanged.
 *   - iterations   -> rounded, clamped to 1..10 refinement sweeps.
 *   - searchRadius -> clamped to 0..1 of the long edge, floored at 1 pixel.
 *   - seed         -> folded into a non-zero Int32 xorshift32 state. The
 *     module never calls Math.random.
 * Worst-case work is therefore bounded by
 *   holePixels * iterations * (2 propagated + ~log2(searchRadius) + fallback)
 *   candidates * patchArea, plus one voting sweep per iteration and
 *   SMOOTH_PASSES smoothing passes.
 * All offset and distance fields are Int32Array / Float32Array allocated once.
 *
 * Determinism: scan order, PRNG stream and every arithmetic operation are
 * fixed, so identical (rgba, mask, params) give byte-identical output; a
 * different seed may give different bytes.
 *
 * Alpha rules (a choice, so stated explicitly):
 *   - cloneStamp blends alpha toward opaque with the same weight as the
 *     colours: outA += (255 - outA) * weight. An opaque photo is untouched at
 *     255 and a transparent destination picks up the stamp's coverage.
 *   - contentAwareFill never writes alpha at all; a fill changes colour, not
 *     transparency, so hole pixels keep the alpha they arrived with.
 *
 * Pure module: no project imports, no I/O, no ambient state.
 */

/** One clone-stamp dab. Coordinates are normalised 0..1 of the frame; radius
 *  and feather are normalised to the long edge / to the radius. */
export interface CloneMark {
  centreX: number;
  centreY: number;
  radius: number;
  feather: number;
  opacity: number;
  sourceX: number;
  sourceY: number;
  aligned: boolean;
}

/** Bounded PatchMatch settings; see the header for the exact clamps. */
export interface ContentFillParams {
  /** Odd in practice; 3 means a 7x7 patch. */
  patchRadius: number;
  iterations: number;
  /** Normalised to the long edge. */
  searchRadius: number;
  seed: number;
}

const PATCH_RADIUS_MIN: number = 1;
const PATCH_RADIUS_MAX: number = 5;
const ITERATIONS_MIN: number = 1;
const ITERATIONS_MAX: number = 10;
/** Non-zero seed state; a zero state would freeze an xorshift generator. */
const PRNG_NON_ZERO: number = 0x2545F491;
/** Sentinel for "no candidate accepted yet". It overflows the Float32Array
 *  field it is stored in and reads back as +Infinity, which is exactly the
 *  wanted comparison: any evaluated candidate wins, and a candidate rejected
 *  as uncovered (also +Infinity) never does. */
const UNTESTED: number = 1.7976931348623157e308;
/** A contribution votes only when its patch distance is within this fraction
 *  of the best contribution for that pixel. Near-best only: averaging every
 *  overlapping patch is precisely what turns a fill into an expensive blur. */
const VOTE_TOLERANCE: number = 0.05;
const VOTE_SLACK: number = 1e-3;
/** How far a contributor's offset may differ from the destination pixel's own
 *  offset and still vote. This is the smoothness term of the Wexler energy
 *  applied at voting time: patches that disagree about where the data comes
 *  from are dropped instead of being averaged in, which is what keeps texture
 *  amplitude in the fill. */
const OFFSET_AGREEMENT: number = 1;
/** Local luminance variance at or below which a hole pixel counts as flat and
 *  may be smoothed. Above it the pixel is texture and is left untouched, so a
 *  smoothing pass removes seams without removing detail. */
const FLAT_VARIANCE: number = 12;
const SMOOTH_PASSES: number = 2;
/** Fixed neighbour order (left, right, up, down) for the coherence fallback. */
const NEIGHBOUR_X: number[] = [-1, 1, 0, 0];
const NEIGHBOUR_Y: number[] = [0, 0, -1, 1];
/** Eight probe directions, used to find the closest known pixel. */
const RING_X: number[] = [0, 0, -1, 1, -1, 1, -1, 1];
const RING_Y: number[] = [-1, 1, 0, 0, -1, -1, 1, 1];
/** Extra reach, in pixels, tried by the fallback: the smallest push first, then
 *  a Fibonacci-like growth so a deep hole is still bridged in a few tries. */
const PUSH_SCHEDULE: number[] = [1, 1, 2, 3, 5, 8, 13, 21, 34, 55];
const LUMA_R: number = 0.2126;
const LUMA_G: number = 0.7152;
const LUMA_B: number = 0.0722;

/** Own PRNG (xorshift32): deterministic, seeded, and never Math.random. */
class Xorshift32 {
  private state: number;

  constructor(seed: number) {
    let s: number = Math.floor(seed);
    if (!isFinite(s)) {
      s = 0;
    }
    s = s | 0;
    if (s === 0) {
      s = PRNG_NON_ZERO;
    }
    this.state = s;
  }

  /** Uniform in [0, 1). */
  next(): number {
    let s: number = this.state;
    s = s ^ (s << 13);
    s = s ^ (s >>> 17);
    s = s ^ (s << 5);
    this.state = s;
    return (s >>> 0) / 4294967296;
  }
}

function clampUnit(v: number): number {
  if (!(v > 0)) {
    return 0;
  }
  if (v > 1) {
    return 1;
  }
  return v;
}

function clampInt(v: number, lo: number, hi: number): number {
  const n: number = Math.round(v);
  if (!isFinite(n)) {
    return lo;
  }
  if (n < lo) {
    return lo;
  }
  if (n > hi) {
    return hi;
  }
  return n;
}

/** Hermite smoothstep on an already normalised t; 0 at t<=0, 1 at t>=1. */
function smoothStep01(t: number): number {
  if (!(t > 0)) {
    return 0;
  }
  if (t >= 1) {
    return 1;
  }
  return t * t * (3 - 2 * t);
}

function blendByte(base: number, incoming: number, weight: number): number {
  return Math.round(base + (incoming - base) * weight);
}

/** Fresh copy, so every entry point returns a buffer the caller owns. */
function copyBytes(src: Uint8ClampedArray): Uint8ClampedArray {
  const out: Uint8ClampedArray = new Uint8ClampedArray(src.length);
  out.set(src);
  return out;
}

export function contentFillDefaults(): ContentFillParams {
  const defaults: ContentFillParams = {
    patchRadius: 3,
    iterations: 4,
    searchRadius: 0.12,
    seed: 1,
  };
  return defaults;
}

/**
 * Clone stamp.
 *
 * Sources are always read from the buffer as it was handed in, so a mark can
 * never sample another mark's output; destinations accumulate in the returned
 * copy, so overlapping marks combine by the weighted blend below in array
 * order. The source is addressed with an integral nearest-neighbour offset and
 * clamped per pixel to the frame, so there is no wrap and no out-of-bounds
 * read. Destination weight is opacity * falloff, where falloff is 1 inside
 * (1 - feather) * radius and eases to 0 at the radius.
 *
 * `aligned` follows the usual brush semantic: the first aligned mark fixes the
 * source offset and later aligned marks reuse it, so dragging the brush keeps
 * sampling the same area; a non-aligned mark re-anchors on its own source.
 */
export function cloneStamp(rgba: Uint8ClampedArray, width: number, height: number,
  marks: CloneMark[]): Uint8ClampedArray {
  const out: Uint8ClampedArray = copyBytes(rgba);
  const cols: number = Math.floor(width);
  const rows: number = Math.floor(height);
  if (cols <= 0 || rows <= 0 || marks.length === 0) {
    return out;
  }
  const longEdge: number = Math.max(cols, rows);
  const dataEnd: number = Math.min(out.length, cols * rows * 4);
  let alignedDx: number = 0;
  let alignedDy: number = 0;
  let alignedKnown: boolean = false;

  for (let m: number = 0; m < marks.length; m++) {
    const mark: CloneMark = marks[m];
    const opacity: number = clampUnit(mark.opacity);
    const radius: number = clampUnit(mark.radius) * longEdge;
    if (opacity <= 0 || radius <= 0) {
      continue;
    }
    const centreX: number = clampUnit(mark.centreX) * (cols - 1);
    const centreY: number = clampUnit(mark.centreY) * (rows - 1);
    const srcX: number = Math.round(clampUnit(mark.sourceX) * (cols - 1));
    const srcY: number = Math.round(clampUnit(mark.sourceY) * (rows - 1));
    let dx: number = srcX - Math.round(centreX);
    let dy: number = srcY - Math.round(centreY);
    if (mark.aligned) {
      if (alignedKnown) {
        dx = alignedDx;
        dy = alignedDy;
      } else {
        alignedDx = dx;
        alignedDy = dy;
        alignedKnown = true;
      }
    }
    const feather: number = clampUnit(mark.feather);
    const inner: number = 1 - feather;
    const x0: number = Math.max(0, Math.floor(centreX - radius));
    const x1: number = Math.min(cols - 1, Math.ceil(centreX + radius));
    const y0: number = Math.max(0, Math.floor(centreY - radius));
    const y1: number = Math.min(rows - 1, Math.ceil(centreY + radius));

    for (let y: number = y0; y <= y1; y++) {
      const offY: number = y - centreY;
      for (let x: number = x0; x <= x1; x++) {
        const offX: number = x - centreX;
        const distance: number = Math.sqrt(offX * offX + offY * offY);
        if (distance > radius) {
          continue;
        }
        let falloff: number = 1;
        if (feather > 0) {
          // 1 inside (1 - feather) of the radius, easing to 0 at the radius.
          falloff = 1 - smoothStep01((distance / radius - inner) / feather);
          if (falloff <= 0) {
            continue;
          }
        }
        const weight: number = opacity * falloff;
        const dofs: number = (y * cols + x) * 4;
        if (dofs + 3 >= dataEnd) {
          continue;
        }
        const sx: number = Math.min(cols - 1, Math.max(0, x + dx));
        const sy: number = Math.min(rows - 1, Math.max(0, y + dy));
        const sofs: number = (sy * cols + sx) * 4;
        out[dofs] = blendByte(out[dofs], rgba[sofs], weight);
        out[dofs + 1] = blendByte(out[dofs + 1], rgba[sofs + 1], weight);
        out[dofs + 2] = blendByte(out[dofs + 2], rgba[sofs + 2], weight);
        out[dofs + 3] = blendByte(out[dofs + 3], 255, weight);
      }
    }
  }
  return out;
}

/** True when the patch centred on (srcX, srcY) lies fully inside the frame, so
 *  it can be read without any edge clamping. */
function patchFits(srcX: number, srcY: number, cols: number, rows: number, patchRadius: number): boolean {
  if (srcX < patchRadius || srcY < patchRadius) {
    return false;
  }
  if (srcX + patchRadius >= cols || srcY + patchRadius >= rows) {
    return false;
  }
  return true;
}

/**
 * Index of the closest pixel outside the hole, or -1 when the whole frame is
 * hole. Scanning outward by ring radius and, within a radius, in a fixed
 * direction order keeps this deterministic. It is only needed where a hole
 * pixel has no already-resolved neighbour to inherit an offset from, so its
 * cost never dominates.
 */
function nearestKnownPixel(cols: number, rows: number, holeIndexOf: Int32Array,
  px: number, py: number): number {
  const limit: number = Math.max(cols, rows);
  for (let radius: number = 1; radius <= limit; radius++) {
    for (let n: number = 0; n < 8; n++) {
      const x: number = px + RING_X[n] * radius;
      const y: number = py + RING_Y[n] * radius;
      if (x < 0 || y < 0 || x >= cols || y >= rows) {
        continue;
      }
      if (holeIndexOf[y * cols + x] < 0) {
        return y * cols + x;
      }
    }
  }
  return -1;
}

/**
 * Sum of squared RGB differences between the hole patch centred on hole index
 * `h` and the candidate patch centred on (srcX, srcY), read from the working
 * buffer.
 *
 * Admissibility first: the candidate's source patch must lie entirely outside
 * the hole, because a hole pixel is never source data. This is also what makes
 * the sum comparable between candidates 鈥?with a partially unusable source
 * patch, a candidate that happened to compare fewer pixels would score lower
 * for free, and the minimum would drift towards matches that read the hole.
 *
 * The destination side is compared against the *current estimate* of the hole
 * (`useEstimate`), not against the wrecked input: on the first sweep the hole
 * holds no information and those pixels are skipped, which leaves a patch deep
 * inside the hole unconstrained; afterwards they carry the previous sweep's
 * synthesis, so even the interior is judged on real evidence and competing
 * boundary matches are resolved instead of merely colliding.
 */
function patchDistance(work: Uint8ClampedArray, cols: number, rows: number,
  holeIndexOf: Int32Array, holeX: Int32Array, holeY: Int32Array, h: number,
  srcX: number, srcY: number, patchRadius: number, useEstimate: boolean): number {
  const centreX: number = holeX[h];
  const centreY: number = holeY[h];
  let compared: number = 0;
  for (let oy: number = -patchRadius; oy <= patchRadius; oy++) {
    const sy: number = srcY + oy;
    for (let ox: number = -patchRadius; ox <= patchRadius; ox++) {
      if (holeIndexOf[sy * cols + srcX + ox] >= 0) {
        return Infinity;
      }
    }
  }
  let sum: number = 0;
  for (let oy: number = -patchRadius; oy <= patchRadius; oy++) {
    const dy: number = centreY + oy;
    if (dy < 0 || dy >= rows) {
      continue;
    }
    const sy: number = srcY + oy;
    for (let ox: number = -patchRadius; ox <= patchRadius; ox++) {
      const dx: number = centreX + ox;
      if (dx < 0 || dx >= cols) {
        continue;
      }
      if (!useEstimate && holeIndexOf[dy * cols + dx] >= 0) {
        continue;
      }
      const dofs: number = (dy * cols + dx) * 4;
      const sofs: number = (sy * cols + srcX + ox) * 4;
      const dr: number = work[dofs] - work[sofs];
      const dg: number = work[dofs + 1] - work[sofs + 1];
      const db: number = work[dofs + 2] - work[sofs + 2];
      sum += dr * dr + dg * dg + db * db;
      compared++;
    }
  }
  if (compared === 0) {
    return 0;
  }
  return sum;
}

/**
 * Re-estimate the hole from the current offsets: every hole pixel is written
 * from the patches that cover it, restricted to contributions whose distance is
 * near the best one for that pixel and whose offset agrees with that pixel's own
 * offset to within OFFSET_AGREEMENT. Averaging contributions from unrelated
 * offsets is what erases texture, so disagreement is dropped rather than blurred
 * in. Alpha is never written: a fill changes colour, not transparency.
 */
function voteHole(rgba: Uint8ClampedArray, out: Uint8ClampedArray, cols: number, rows: number,
  holeIndexOf: Int32Array, holeX: Int32Array, holeY: Int32Array, holeCount: number,
  nnfX: Int32Array, nnfY: Int32Array, best: Float32Array, patchRadius: number,
  voteMin: Float32Array, sums: Float32Array): void {
  voteMin.fill(Infinity);
  sums.fill(0);
  for (let pass: number = 0; pass < 2; pass++) {
    for (let h: number = 0; h < holeCount; h++) {
      const d: number = best[h];
      if (!isFinite(d)) {
        continue;
      }
      const cx: number = holeX[h];
      const cy: number = holeY[h];
      for (let oy: number = -patchRadius; oy <= patchRadius; oy++) {
        const dy: number = cy + oy;
        if (dy < 0 || dy >= rows) {
          continue;
        }
        const sy: number = nnfY[h] + oy;
        for (let ox: number = -patchRadius; ox <= patchRadius; ox++) {
          const dx: number = cx + ox;
          if (dx < 0 || dx >= cols) {
            continue;
          }
          const sx: number = nnfX[h] + ox;
          const dh: number = holeIndexOf[dy * cols + dx];
          if (dh < 0) {
            continue;
          }
          if (holeIndexOf[sy * cols + sx] >= 0) {
            continue;
          }
          if (Math.abs(nnfX[h] - nnfX[dh]) > OFFSET_AGREEMENT ||
            Math.abs(nnfY[h] - nnfY[dh]) > OFFSET_AGREEMENT) {
            continue;
          }
          if (pass === 0) {
            if (d < voteMin[dh]) {
              voteMin[dh] = d;
            }
            continue;
          }
          if (d > voteMin[dh] * (1 + VOTE_TOLERANCE) + VOTE_SLACK) {
            continue;
          }
          const sofs: number = (sy * cols + sx) * 4;
          sums[dh * 4] += rgba[sofs];
          sums[dh * 4 + 1] += rgba[sofs + 1];
          sums[dh * 4 + 2] += rgba[sofs + 2];
          sums[dh * 4 + 3] += 1;
        }
      }
    }
  }
  for (let h: number = 0; h < holeCount; h++) {
    const weight: number = sums[h * 4 + 3];
    if (!(weight > 0)) {
      // Nothing usable covered this pixel; it keeps its incoming value rather
      // than being filled with an invented one.
      continue;
    }
    const dofs: number = (holeY[h] * cols + holeX[h]) * 4;
    out[dofs] = Math.round(sums[h * 4] / weight);
    out[dofs + 1] = Math.round(sums[h * 4 + 1] / weight);
    out[dofs + 2] = Math.round(sums[h * 4 + 2] / weight);
  }
}

export function contentAwareFill(rgba: Uint8ClampedArray, width: number, height: number,
  holeMask: Uint8Array, p: ContentFillParams): Uint8ClampedArray {
  const out: Uint8ClampedArray = copyBytes(rgba);
  const cols: number = Math.floor(width);
  const rows: number = Math.floor(height);
  if (cols <= 0 || rows <= 0) {
    return out;
  }
  const cells: number = cols * rows;
  // A truncated buffer is returned untouched rather than read out of range.
  if (rgba.length < cells * 4 || out.length < cells * 4) {
    return out;
  }
  const patchLimit: number = Math.floor((Math.min(cols, rows) - 1) / 2);
  if (patchLimit < PATCH_RADIUS_MIN) {
    return out;
  }
  let patchRadius: number = Math.min(clampInt(p.patchRadius, PATCH_RADIUS_MIN, PATCH_RADIUS_MAX), patchLimit);
  const iterations: number = clampInt(p.iterations, ITERATIONS_MIN, ITERATIONS_MAX);
  const longEdge: number = Math.max(cols, rows);
  let searchWindow: number = Math.round(clampUnit(p.searchRadius) * longEdge);
  if (searchWindow < 1) {
    searchWindow = 1;
  }

  // One Int32Array holding both the hole flag and the pixel -> hole index map,
  // so every lookup below is O(1) and nothing is allocated per pixel.
  const holeIndexOf: Int32Array = new Int32Array(cells).fill(-1);
  let holeCount: number = 0;
  const maskLength: number = Math.min(cells, holeMask.length);
  for (let i: number = 0; i < maskLength; i++) {
    if (holeMask[i] !== 0) {
      holeIndexOf[i] = holeCount;
      holeCount++;
    }
  }
  if (holeCount === 0) {
    // No hole: byte-identical, and no work at all.
    return out;
  }
  const holeX: Int32Array = new Int32Array(holeCount);
  const holeY: Int32Array = new Int32Array(holeCount);
  for (let i: number = 0; i < cells; i++) {
    const h: number = holeIndexOf[i];
    if (h >= 0) {
      holeX[h] = i % cols;
      holeY[h] = Math.floor(i / cols);
    }
  }

  const nnfX: Int32Array = new Int32Array(holeCount);
  const nnfY: Int32Array = new Int32Array(holeCount);
  const best: Float32Array = new Float32Array(holeCount);
  const rng: Xorshift32 = new Xorshift32(p.seed);
  for (let h: number = 0; h < holeCount; h++) {
    // Deterministic per-hole-pixel random seed offset.
    nnfX[h] = patchRadius + Math.floor(rng.next() * (cols - 2 * patchRadius));
    nnfY[h] = patchRadius + Math.floor(rng.next() * (rows - 2 * patchRadius));
    best[h] = UNTESTED;
  }

  // Vote scratch, sized once: per hole pixel, four clamped channels of
  // accumulated contribution plus the per-destination best distance.
  const voteMin: Float32Array = new Float32Array(holeCount);
  const sums: Float32Array = new Float32Array(holeCount * 4);

  for (let iter: number = 0; iter < iterations; iter++) {
    const forward: boolean = (iter % 2) === 0;
    const stepX: number = forward ? -1 : 1;
    const stepY: number = forward ? -1 : 1;
    // From the second sweep on, the hole holds the previous sweep's synthesis,
    // so the interior becomes judgeable instead of unconstrained.
    const useEstimate: boolean = iter > 0;
    for (let step: number = 0; step < holeCount; step++) {
      const h: number = forward ? step : holeCount - 1 - step;
      const px: number = holeX[h];
      const py: number = holeY[h];

      // Propagation: an already-processed neighbour's offset, shifted by the
      // single pixel between that neighbour and this one.
      for (let pass: number = 0; pass < 2; pass++) {
        const nx: number = pass === 0 ? px + stepX : px;
        const ny: number = pass === 0 ? py : py + stepY;
        if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) {
          continue;
        }
        const nh: number = holeIndexOf[ny * cols + nx];
        if (nh < 0) {
          continue;
        }
        // The neighbour's match, moved by exactly the vector from that
        // neighbour to this pixel: only the axis actually stepped changes.
        const cx: number = nnfX[nh] + (px - nx);
        const cy: number = nnfY[nh] + (py - ny);
        if (!patchFits(cx, cy, cols, rows, patchRadius)) {
          continue;
        }
        const d: number = patchDistance(out, cols, rows, holeIndexOf, holeX, holeY, h, cx, cy, patchRadius, useEstimate);
        if (d < best[h]) {
          nnfX[h] = cx;
          nnfY[h] = cy;
          best[h] = d;
        }
      }

      // Coherence fallback. A pixel deep inside the hole has no comparable
      // pixel, so no candidate can be told from any other; and a lone one-pixel
      // shift of a neighbour's offset soon stops being admissible, because the
      // deeper the destination sits the further out its source patch has to
      // clear the hole. When nothing has been accepted yet, take an already
      // resolved neighbour's offset, else the direction of the closest known
      // pixel, and push the source out along it until the patch is admissible.
      // Pushing along that direction is what keeps structure aligned: a ramp or
      // a set of stripes is continued by the nearest real data, not spliced
      // from an arbitrary part of the frame.
      if (!isFinite(best[h])) {
        let vecX: number = 0;
        let vecY: number = 0;
        for (let n: number = 0; n < 4; n++) {
          const nx: number = px + NEIGHBOUR_X[n];
          const ny: number = py + NEIGHBOUR_Y[n];
          if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) {
            continue;
          }
          const nh: number = holeIndexOf[ny * cols + nx];
          if (nh < 0 || !isFinite(best[nh])) {
            continue;
          }
          vecX = nnfX[nh] - px;
          vecY = nnfY[nh] - py;
          break;
        }
        if (vecX === 0 && vecY === 0) {
          const target: number = nearestKnownPixel(cols, rows, holeIndexOf, px, py);
          if (target >= 0) {
            vecX = (target % cols) - px;
            vecY = Math.floor(target / cols) - py;
          }
        }
        if (vecX === 0 && vecY === 0) {
          vecX = nnfX[h] - px;
          vecY = nnfY[h] - py;
        }
        const span: number = Math.sqrt(vecX * vecX + vecY * vecY);
        if (span > 0) {
          // Grow from the neighbour's own reach: one step further in, the patch
          // has to clear the hole by at least as much, so the needed reach is
          // never smaller than the one that worked next door.
          for (let s: number = 0; s < PUSH_SCHEDULE.length && !isFinite(best[h]); s++) {
            const reach: number = span + PUSH_SCHEDULE[s];
            const cx: number = px + Math.round(vecX / span * reach);
            const cy: number = py + Math.round(vecY / span * reach);
            if (!patchFits(cx, cy, cols, rows, patchRadius)) {
              continue;
            }
            const d: number = patchDistance(out, cols, rows, holeIndexOf, holeX, holeY, h, cx, cy, patchRadius, useEstimate);
            if (d < best[h]) {
              nnfX[h] = cx;
              nnfY[h] = cy;
              best[h] = d;
            }
          }
        }
      }

      // Random search: exponentially shrinking window around the current best,
      // so early candidates jump far and the final ones only polish.
      let window: number = searchWindow;
      while (window >= 1) {
        const cx: number = nnfX[h] + Math.round((rng.next() * 2 - 1) * window);
        const cy: number = nnfY[h] + Math.round((rng.next() * 2 - 1) * window);
        if (patchFits(cx, cy, cols, rows, patchRadius)) {
          const d: number = patchDistance(out, cols, rows, holeIndexOf, holeX, holeY, h, cx, cy, patchRadius, useEstimate);
          if (d < best[h]) {
            nnfX[h] = cx;
            nnfY[h] = cy;
            best[h] = d;
          }
        }
        window = Math.floor(window / 2);
      }
    }

    // Re-estimate the hole from the offsets just computed, so the next sweep
    // scores candidates against real evidence inside the hole as well.
    voteHole(rgba, out, cols, rows, holeIndexOf, holeX, holeY, holeCount,
      nnfX, nnfY, best, patchRadius, voteMin, sums);
  }

  // Smoothing, hole pixels only, gated on local luminance variance: a flat
  // neighbourhood (a seam, gradient banding, a smooth sky) is averaged, a
  // textured one is left exactly as synthesised. An ungated mean here is what
  // makes a fill look soft, so texture amplitude survives this stage.
  const scratch: Uint8ClampedArray = new Uint8ClampedArray(rgba.length);
  for (let pass: number = 0; pass < SMOOTH_PASSES; pass++) {
    scratch.set(out);
    for (let h: number = 0; h < holeCount; h++) {
      const px: number = holeX[h];
      const py: number = holeY[h];
      let n: number = 0;
      let lumaSum: number = 0;
      let lumaSq: number = 0;
      for (let oy: number = -1; oy <= 1; oy++) {
        const dy: number = py + oy;
        if (dy < 0 || dy >= rows) {
          continue;
        }
        for (let ox: number = -1; ox <= 1; ox++) {
          const dx: number = px + ox;
          if (dx < 0 || dx >= cols) {
            continue;
          }
          const ofs: number = (dy * cols + dx) * 4;
          const luma: number = LUMA_R * out[ofs] + LUMA_G * out[ofs + 1] + LUMA_B * out[ofs + 2];
          lumaSum += luma;
          lumaSq += luma * luma;
          n++;
        }
      }
      if (n === 0) {
        continue;
      }
      const mean: number = lumaSum / n;
      if (lumaSq / n - mean * mean > FLAT_VARIANCE) {
        continue;
      }
      const ofs: number = (py * cols + px) * 4;
      let r: number = 0;
      let g: number = 0;
      let b: number = 0;
      for (let oy: number = -1; oy <= 1; oy++) {
        const dy: number = py + oy;
        if (dy < 0 || dy >= rows) {
          continue;
        }
        for (let ox: number = -1; ox <= 1; ox++) {
          const dx: number = px + ox;
          if (dx < 0 || dx >= cols) {
            continue;
          }
          const nofs: number = (dy * cols + dx) * 4;
          r += out[nofs];
          g += out[nofs + 1];
          b += out[nofs + 2];
        }
      }
      scratch[ofs] = Math.round(r / n);
      scratch[ofs + 1] = Math.round(g / n);
      scratch[ofs + 2] = Math.round(b / n);
    }
    for (let h: number = 0; h < holeCount; h++) {
      const ofs: number = (holeY[h] * cols + holeX[h]) * 4;
      out[ofs] = scratch[ofs];
      out[ofs + 1] = scratch[ofs + 1];
      out[ofs + 2] = scratch[ofs + 2];
    }
  }
  return out;
}
