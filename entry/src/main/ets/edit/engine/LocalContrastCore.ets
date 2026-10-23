/**
 * Camera Raw "Effects" and "Detail" stages that need a neighbourhood.
 *
 * Four spatial stages live here, in the order they are applied:
 *
 *   1. Texture  — mid-frequency local contrast. Algorithm: band-pass local
 *      contrast on luminance. A small-radius low-pass is the local base and the
 *      fine detail `luma - base` is the band that Texture acts on; the amount is
 *      modulated by the detail's *relative* contrast so a dark subject and a
 *      bright one respond the same.
 *   2. Clarity  — low-frequency local contrast. Algorithm: the same two-band
 *      decomposition, but Clarity acts on the band *between* the small radius and
 *      a much wider one, so fine texture has already been removed by the time it
 *      looks. Its amount is additionally weighted down towards black and white so
 *      highlights and shadows do not halo.
 *   3. Dehaze   — atmospheric-scattering inversion. Algorithm: dark-channel
 *      prior (He, Sun & Tang, "Single Image Haze Removal Using Dark Channel
 *      Prior", CVPR 2009). Dark channel over a local window, airlight taken as
 *      the brightest pixels of that channel (a high percentile, so one specular
 *      highlight cannot hijack it), transmission `t = 1 - omega * dark/airlight`
 *      recovered with a floor `t0`, then `J = (I - A) / max(t, t0) + A`. A
 *      negative amount runs the forward atmospheric model instead, which adds
 *      haze rather than removing it.
 *   4. Sharpen  — unsharp mask with `amount`, `radius`, `detail` and `masking`.
 *      `detail` mixes in a fixed 3x3 high-pass so a larger value gives crisper,
 *      thinner edges; `masking` is a Sobel-gradient edge mask that suppresses
 *      sharpening on flat fields, which is what stops noise being amplified.
 *
 * Both band stages are ordinary unsharp masks that have been expressed in terms
 * of the local base and the relative contrast; the two derive from the same
 * decomposition, and the split between them is a difference of two low-passes
 * rather than two independent high-passes.
 *
 * Scope and semantics, stated plainly:
 *
 *  - This is NOT a bit-identical port of Camera Raw; the exact Adobe kernels are
 *    not public. The semantics chosen here are the ones that make the controls
 *    behave as documented above; the blur is a triple box blur (a standard O(1)
 *    Gaussian approximation) rather than a true Gaussian, and the dehaze
 *    transmission map is refined with a local minimum filter rather than with
 *    soft matting or a guided filter.
 *  - Luminance is Rec.709 on the display-referred (sRGB-encoded) values, the
 *    same convention the tone stages and the range mask use.
 *  - Radii are a function of the frame long edge, never of the buffer size, so a
 *    preview and a full-resolution export of the same photo look the same.
 *  - Sampling outside the frame clamps to the edge pixel: no wrapping, no
 *    out-of-bounds reads. A null result is impossible — every output byte is the
 *    result of a bounded expression.
 *  - The module is pure: no imports, no I/O, no randomness, and it never mutates
 *    its input.
 *
 * ## Native fast path
 *
 * `applyLocalContrast` first asks `libvivid_detail.so` (via NativeDetail.ets) to
 * run the same pipeline. Native exists only because this stage measured 725 ms
 * per 512x341 preview frame here but 20-47 ms on Node for identical bytes: the
 * cost is the ArkTS interpreter, not the arithmetic. The implementation below is
 * still the reference and still runs whenever the native module is missing or
 * throws, and the two are required to be byte-identical
 * (tools/check_detail_native_parity.cjs). Nothing else in this file changes:
 * every radius, clamp and stage order is the same on both sides.
 */

import { NativeDetailRequest, nativeDetailApply, nativeDetailHazeColor } from './NativeDetail';

/** Long edge the slider radii are authored against (the preview/export size the
 *  editor targets for a tuned look). */
const LOCAL_CONTRAST_REFERENCE_LONG_EDGE: number = 2048;

/** Hard caps. The texture radius stays genuinely small so it keeps describing
 *  mid-frequency detail; clarity is bounded so a huge export does not turn the
 *  base into a whole-frame average that would flatten the picture. */
const TEXTURE_MAX_RADIUS: number = 24;
const CLARITY_MAX_RADIUS: number = 64;

/** Clarity's band-pass radius is this fraction of the frame long edge, i.e. 3%
 *  at any size once the cap is reached. */
const CLARITY_LONG_EDGE_FRACTION: number = 0.03;

/**
 * 纹理/清晰度：直接对齐 Compositor
 * （`Rendering/AdjustPixels.c` 的 `adjust_camera_raw_effects`，其注释说明半径按
 * 1456 px 宽的样片拟合到 8 px 与 32 px，所以两者都是长边的固定比例）。
 */
const TEXTURE_RADIUS_FRACTION: number = 8 / 1456;
const CLARITY_RADIUS_FRACTION: number = 32 / 1456;
/** 导向滤波的 epsilon（方差单位），与 Compositor 的 `guided_filter_plane` 一致。 */
const GUIDED_EPSILON: number = 0.01;
/** 正负方向的不对称增益：提清晰比降清晰更克制，纹理同理。 */
const TEXTURE_POSITIVE_GAIN: number = 0.6;
const TEXTURE_NEGATIVE_GAIN: number = 0.5;
const CLARITY_POSITIVE_GAIN: number = 0.85;
const CLARITY_NEGATIVE_GAIN: number = 0.5;
/** Sharpen radius spans 1..32 px across the slider. */
const SHARPEN_MAX_PIXELS: number = 32;

/**
 * 核半径到"真实影响半径"的倍数。
 *
 * 可分离模糊串联多趟，k 趟半径 r 的卷积能影响到 k·r 之外；实测每个阶段取 3 倍即可
 * 覆盖（见 tools/check_detail_halo.cjs）。lightcraft 在
 * `crates/ui-egui/src/region.rs` 里用 3σ 而非 σ 推窗口边距，是同一个理由。
 */
const HALO_SUPPORT_MULTIPLE: number = 3;

/** Dark-channel prior constants. */
const DEHAZE_OMEGA: number = 0.95;
const DEHAZE_MIN_TRANSMISSION: number = 0.25;
/** Airlight percentile of the dark channel. 1% keeps a specular highlight from
 *  becoming the estimate — a highlight is far brighter than 1% of a normal frame
 *  — while staying wide enough to be stable on a frame whose dark channel holds
 *  only a few distinct values, which is what a synthetic or very flat picture
 *  looks like. A strict 0.1% would there be a single code value with thousands
 *  of tied pixels, which carries no information about the scene. */
const DEHAZE_AIRLIGHT_PERCENTILE: number = 0.99;
/** Haze added when the amount is negative, as a fraction of the forward model. */
const DEHAZE_ADD_STRENGTH: number = 0.25;
/** Fraction of the long edge used for the dark-channel window, and its clamp. */
const DEHAZE_WINDOW_FRACTION: number = 0.005;
const DEHAZE_MIN_WINDOW: number = 3;
const DEHAZE_MAX_WINDOW: number = 15;

const LUMA_R: number = 0.2126;
const LUMA_G: number = 0.7152;
const LUMA_B: number = 0.0722;

/** Relative local contrast at which a band-pass gain falls to half the slider.
 *  25% is an unusually strong edge in a photograph, so the control stays close
 *  to linear (i.e. a straightforward unsharp mask) over real detail and only
 *  rolls off on the extreme structures that would otherwise halo. */
const LOCAL_CONTRAST_REFERENCE_CONTRAST: number = 0.25;

/** Hard ceiling on the combined band-pass adjustment, in luma units. Kept well
 *  below the point where a highlight would clip, because clipping the positive
 *  half of the adjustment while keeping the negative half biases the mean. */
const LOCAL_CONTRAST_MAX_ADJUSTMENT: number = 0.22;

/** Hard ceiling on the sharpening adjustment, in luma units. */
const SHARPEN_MAX_ADJUSTMENT: number = 0.35;

/** Guards a luminance divisor. Below this the gain is not meaningfully defined
 *  anyway (a pixel that dark carries no usable colour ratio). */
const LUMA_FLOOR: number = 0.0004;

export interface LocalContrastParams {
  /** -1..1, default 0. */
  texture: number;
  /** -1..1, default 0. */
  clarity: number;
  /** -1..1, default 0. */
  dehaze: number;
  /** 0..1, default 0. */
  sharpenAmount: number;
  /** 0..1, default 0. */
  sharpenRadius: number;
  /** 0..1, default 0.25. */
  sharpenDetail: number;
  /** 0..1, default 0. */
  sharpenMasking: number;
}

export function localContrastDefaults(): LocalContrastParams {
  return {
    texture: 0,
    clarity: 0,
    dehaze: 0,
    sharpenAmount: 0,
    sharpenRadius: 0,
    sharpenDetail: 0.25,
    sharpenMasking: 0,
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

/**
 * True when every stage is exactly at its no-op value, so the caller can return
 * a byte-for-byte copy of the input instead of running the pipeline.
 *
 * The tolerances are deliberately not fuzzy: a caller that wants "nothing" must
 * pass 0, and every stage below is written so that a zero amount is exactly
 * identity, not merely close to it.
 */
export function localContrastIsIdentity(p: LocalContrastParams): boolean {
  if (p === null || p === undefined) return true;
  return clampMagnitude(p.texture, 1) === 0 &&
    clampMagnitude(p.clarity, 1) === 0 &&
    clampMagnitude(p.dehaze, 1) === 0 &&
    clampUnit(p.sharpenAmount) === 0;
}

/** Frame long edge, never below 1. Radius formulas are defined on this. */
function longEdgeOf(longEdge: number): number {
  if (!Number.isFinite(longEdge)) return LOCAL_CONTRAST_REFERENCE_LONG_EDGE;
  return Math.max(1, Math.round(longEdge));
}

/**
 * Texture radius in pixels: `clamp(round(longEdge / 1024), 1, 8)`.
 *
 * At the 2048 reference this is 2 px — a mid-frequency band-pass. It grows
 * slowly (one pixel per 1024 px of long edge) and is capped at 8 px, because a
 * wider window would stop discriminating texture from clarity.
 */
export function textureRadius(longEdge: number): number {
  const scaled = Math.round(longEdgeOf(longEdge) * TEXTURE_RADIUS_FRACTION);
  return Math.max(1, Math.min(TEXTURE_MAX_RADIUS, scaled));
}

/**
 * Clarity radius in pixels: `clamp(round(longEdge * 0.03), 2, 64)`.
 *
 * 3% of the long edge is the "large radius" band-pass; at the 2048 reference
 * that is 61 px, comfortably inside the 2-5% window. The floor of 2 px keeps it
 * strictly larger than the texture radius at any frame size, so clarity is
 * always the lower-frequency of the two by construction.
 */
export function clarityRadius(longEdge: number): number {
  const scaled = Math.round(longEdgeOf(longEdge) * CLARITY_RADIUS_FRACTION);
  return Math.max(2, Math.min(CLARITY_MAX_RADIUS, scaled));
}

/**
 * Sharpening blur radius in pixels: `clamp(round(longEdge / 2048 * 32^slider),
 * 1, 32)`.
 *
 * Exponential in the slider (the same convention Camera Raw uses, where a small
 * radius change matters much more at the sharp end) and linear in the frame long
 * edge, so a 1:1 export sharpens at the same scene scale the preview was tuned
 * at. Never 0: a zero-radius unsharp mask would be a no-op.
 */
export function sharpenRadiusPixels(longEdge: number, sharpenRadius: number): number {
  const reference = longEdgeOf(longEdge) / LOCAL_CONTRAST_REFERENCE_LONG_EDGE;
  const slider = clampUnit(sharpenRadius);
  const scaled = Math.round(reference * Math.pow(SHARPEN_MAX_PIXELS, slider));
  return Math.max(1, Math.min(SHARPEN_MAX_PIXELS, scaled));
}

/**
 * 去朦胧暗通道窗口半径（像素）。
 *
 * `applyDehaze` 内部必须调用本函数，而不是各自抄一份公式：高清瓦片的外扩边距
 * 就是按它算的，两处不同步就会在瓦片边界留下接缝。
 */
export function dehazeWindowRadius(longEdge: number): number {
  const edge = Number.isFinite(longEdge) && longEdge > 0 ? longEdge : LOCAL_CONTRAST_REFERENCE_LONG_EDGE;
  return Math.max(DEHAZE_MIN_WINDOW,
    Math.min(DEHAZE_MAX_WINDOW, Math.round(edge * DEHAZE_WINDOW_FRACTION)));
}

/**
 * 本阶段所有**已启用**滤波器的最大核半径（像素），用于放大后高清瓦片的外扩。
 *
 * 参考实现 lightcraft（`crates/ui-egui/src/region.rs`）按各阶段 sigma 的 3σ 推算
 * 窗口边距，并用 `crates/pipeline/src/tests_window.rs` 的
 * `dehaze_at_depth_matches_the_whole_render` / `clarity_at_depth_matches_the_whole_render`
 * 断言"窗口渲染 == 整帧渲染后裁切"。只要 halo 覆盖住最大核半径，这个等价性就成立：
 * halo 内的像素与整帧算得完全一致，裁掉 halo 后正是整帧的同一块。
 *
 * 只统计真的启用的阶段，全默认时返回 0，瓦片不必多读任何像素。
 */
export function localContrastHaloRadius(longEdge: number, params: LocalContrastParams): number {
  let radius = 0;
  if (clampMagnitude(params.texture, 1) !== 0) radius = Math.max(radius, textureRadius(longEdge));
  if (clampMagnitude(params.clarity, 1) !== 0) radius = Math.max(radius, clarityRadius(longEdge));
  if (clampUnit(params.sharpenAmount) > 0) {
    radius = Math.max(radius, sharpenRadiusPixels(longEdge, params.sharpenRadius));
  }
  // 去朦胧已换成 Compositor 的逐像素实现，没有暗通道窗口，因此不需要任何外扩。
  // 核半径不是影响半径：模糊是多趟可分离卷积，一趟半径 r 的三趟串联能影响到 3r 之外。
  // 实测（tools/check_detail_halo.cjs）纹理半径 1 px 的真实影响半径是 3 px——所以这里
  // 按 3 倍取上界，与 lightcraft 用 3σ 而非 σ 推边距是同一个理由。取大一点只会让瓦片
  // 多读几十像素，取小了则会在边界留下接缝。
  return radius * HALO_SUPPORT_MULTIPLE;
}

/** Rec.709 luma of an RGB triple, 0..1. */
function lumaOf(r: number, g: number, b: number): number {
  return r * LUMA_R + g * LUMA_G + b * LUMA_B;
}

/** Clamped sample index: this is the whole border policy. */
function clampedIndex(coordinate: number, extent: number): number {
  if (coordinate < 0) return 0;
  if (coordinate > extent - 1) return extent - 1;
  return coordinate;
}

/**
 * Luminance plane of an RGBA frame, 0..1.
 *
 * The caller reuses the returned buffer across stages, so this allocates once
 * per stage rather than once per pixel.
 *
 * The Rec.709 weights are written out here instead of calling `lumaOf`: on this
 * runtime an out-of-line call per pixel costs several times the three multiplies
 * it performs, and this loop runs twice per local-contrast frame.
 */
function luminancePlane(rgba: Uint8ClampedArray, frameWidth: number, frameHeight: number,
  target: Float32Array): void {
  const count = frameWidth * frameHeight;
  if (count * 4 > rgba.length) {
    // A short input degrades to transparent black rather than reading out of
    // bounds, exactly as the guarded loop below did.
    for (let index = 0; index < count; index++) {
      const offset = index * 4;
      if (offset + 2 < rgba.length) {
        const r = rgba[offset] / 255;
        const g = rgba[offset + 1] / 255;
        const b = rgba[offset + 2] / 255;
        target[index] = r * LUMA_R + g * LUMA_G + b * LUMA_B;
      } else {
        target[index] = 0;
      }
    }
    return;
  }
  for (let index = 0; index < count; index++) {
    const offset = index * 4;
    const r = rgba[offset] / 255;
    const g = rgba[offset + 1] / 255;
    const b = rgba[offset + 2] / 255;
    target[index] = r * LUMA_R + g * LUMA_G + b * LUMA_B;
  }
}

/**
 * Horizontal box pass with edge replication, as a running sum.
 *
 * The row is split into three spans instead of clamping every index: the leading
 * `radius` columns, where the sample leaving the window is pinned to column 0; the
 * interior, where neither end needs a bounds test; and the trailing columns, where
 * the entering sample is pinned to the last column. The interior loop therefore
 * contains no branches and no calls at all, which is what the whole blur's speed
 * rests on: on this runtime a per-pixel call to `clampedIndex` cost roughly forty
 * times a pair of inline compares, and the previous form made two such calls per
 * pixel in every one of the six passes.
 *
 * The border policy is unchanged: a pixel at one edge never borrows from the
 * opposite edge, samples outside the frame clamp to the edge pixel.
 */
function boxBlurRow(source: Float32Array, rowStart: number, frameWidth: number,
  radius: number, span: number, target: Float32Array, targetStart: number): void {
  const last = frameWidth - 1;
  if (last < 0) return;
  // Division by `span`, not multiplication by its reciprocal: the reciprocal is
  // rounded once and that one-ULP difference survives into the float32 plane and
  // flips rounding on a few output pixels at large radii, which is exactly the
  // byte-for-byte parity this rewrite is required to keep.
  // The initial window is columns -radius..radius, clamped: `radius` copies of
  // column 0, columns 0..radius, and (if the frame is narrower than the window)
  // the remainder pinned to the last column.
  let cumulative = source[rowStart] * radius;
  const reach = radius < last ? radius : last;
  for (let column = 0; column <= reach; column++) cumulative += source[rowStart + column];
  if (last < radius) cumulative += source[rowStart + last] * (radius - last);

  const leading = radius < frameWidth ? radius : frameWidth;
  for (let column = 0; column < leading; column++) {
    target[targetStart + column] = cumulative / span;
    let entering = column + radius + 1;
    if (entering > last) entering = last;
    cumulative += source[rowStart + entering] - source[rowStart];
  }
  // Interior: the window is fully inside the row, so both indices are in bounds.
  const interiorEnd = frameWidth - radius - 1;
  for (let column = leading; column < interiorEnd; column++) {
    target[targetStart + column] = cumulative / span;
    cumulative += source[rowStart + column + radius + 1] - source[rowStart + column - radius];
  }
  const trailing = interiorEnd > leading ? interiorEnd : leading;
  for (let column = trailing; column < frameWidth; column++) {
    target[targetStart + column] = cumulative / span;
    cumulative += source[rowStart + last] - source[rowStart + column - radius];
  }
}

/**
 * Vertical box pass with a running column sum, writing one row at a time.
 *
 * `source` never aliases `destination`, so a row can be read while the output row
 * is written and no pass can read a value it has already overwritten. The write
 * and the running-sum update share one pass over the row: the previous form walked
 * the row twice, and that second walk cost as much as the blur arithmetic itself.
 * Only one row of scratch is allocated, which keeps the transient memory of the
 * blur independent of the radius.
 */
function boxBlurPlaneVertical(source: Float32Array, destination: Float32Array,
  frameWidth: number, frameHeight: number, radius: number, span: number): void {
  const last = frameHeight - 1;
  if (last < 0) return;
  const running = new Float32Array(frameWidth);
  // Initial window is rows -radius..radius, clamped to the edge rows.
  const reach = radius < last ? radius : last;
  for (let column = 0; column < frameWidth; column++) {
    let cumulative = source[column] * radius;
    for (let row = 0; row <= reach; row++) cumulative += source[row * frameWidth + column];
    if (last < radius) cumulative += source[last * frameWidth + column] * (radius - last);
    running[column] = cumulative;
  }
  for (let y = 0; y < frameHeight; y++) {
    const rowStart = y * frameWidth;
    let belowRow = y + radius + 1;
    if (belowRow > last) belowRow = last;
    let aboveRow = y - radius;
    if (aboveRow < 0) aboveRow = 0;
    const below = belowRow * frameWidth;
    const above = aboveRow * frameWidth;
    for (let column = 0; column < frameWidth; column++) {
      const index = rowStart + column;
      destination[index] = running[column] / span;
      running[column] = running[column] + source[below + column] - source[above + column];
    }
  }
}

/**
 * Separable triple box blur of a plane, O(1) per pixel in the radius.
 *
 * `sigma` is the intended Gaussian standard deviation in pixels, along BOTH
 * axes. Three box passes run along each axis, and one box of radius r contributes
 * a variance of r*(r+1)/3, so three of them contribute r(r+1) and the radius is
 * solved from `r*(r+1) == sigma^2`. Running the same number of passes on each
 * axis is what makes the low-pass isotropic; a different count per axis would
 * make the local-contrast bands respond differently to horizontal and vertical
 * detail, which shows up as a directional texture in the result. Calibrating the
 * radius this way — rather than treating the requested sigma as the box radius —
 * is what makes the low-pass steep enough that clarity does not leak fine
 * texture into its "low frequency" band.
 *
 * Implementation notes that matter for correctness:
 *  - A pixel at one edge can never borrow a sample from the opposite edge: every
 *    pass replicates the edge pixel at the window's overhang.
 *  - Both axes keep a running sum, so the cost does not grow with the radius even
 *    though clarity's radius reaches 64 px.
 *  - Two planes are live at a time and every pass writes the plane it does not
 *    read, so no pass can consume a value it has already overwritten. The last
 *    vertical pass writes the caller's destination directly instead of producing a
 *    padded result that then had to be copied: the planes are tightly packed, and
 *    the copy was a full extra traversal.
 *  - The two working planes are caller-owned, so a guided filter reuses six planes
 *    for all four of its blurs instead of allocating three fresh ones each time.
 *    On a 2048-pixel frame the old form asked for roughly 270 MB of zeroed
 *    transients per detail frame; the guided filter now asks for six planes in
 *    total and the two bands share them.
 */
function boxBlurInto(source: Float32Array, frameWidth: number, frameHeight: number,
  sigma: number, planeA: Float32Array, planeB: Float32Array,
  destination: Float32Array): void {
  const wanted = Math.max(1, sigma);
  // Three boxes of radius r have variance 3 * r(r+1)/3 = r(r+1) == sigma^2.
  const radius = Math.max(1, Math.round((Math.sqrt(1 + 4 * wanted * wanted) - 1) / 2));
  const span = 2 * radius + 1;
  // Horizontal: source -> A -> B -> A.
  for (let y = 0; y < frameHeight; y++) {
    const rowStart = y * frameWidth;
    boxBlurRow(source, rowStart, frameWidth, radius, span, planeA, rowStart);
  }
  for (let y = 0; y < frameHeight; y++) {
    const rowStart = y * frameWidth;
    boxBlurRow(planeA, rowStart, frameWidth, radius, span, planeB, rowStart);
  }
  for (let y = 0; y < frameHeight; y++) {
    const rowStart = y * frameWidth;
    boxBlurRow(planeB, rowStart, frameWidth, radius, span, planeA, rowStart);
  }
  // Vertical: A -> B -> A -> destination. The destination may alias the source:
  // the first horizontal pass has already consumed every source sample, and the
  // final vertical pass only reads A while it writes.
  boxBlurPlaneVertical(planeA, planeB, frameWidth, frameHeight, radius, span);
  boxBlurPlaneVertical(planeB, planeA, frameWidth, frameHeight, radius, span);
  boxBlurPlaneVertical(planeA, destination, frameWidth, frameHeight, radius, span);
}

/** Blur entry point for callers that do not already own planes. */
function boxBlurPlane(source: Float32Array, frameWidth: number, frameHeight: number,
  sigma: number): Float32Array {
  const count = frameWidth * frameHeight;
  const planeA = new Float32Array(count);
  const planeB = new Float32Array(count);
  const result = new Float32Array(count);
  boxBlurInto(source, frameWidth, frameHeight, sigma, planeA, planeB, result);
  return result;
}

/**
 * Sliding-window minimum over a 1-D buffer of `extent` samples, in place, for a
 * window of `2 * radius + 1` centred on each sample, with both ends clamped.
 *
 * Clamping both ends is just the plain sliding-window problem on an input whose
 * ends have been replicated `radius` times, so that is what this does: the
 * `extent + 2 * radius` virtual samples are materialised once, and a monotonic
 * deque then yields every window minimum in one pass. Each virtual sample enters
 * and leaves the deque at most once, so a window of any width costs the same
 * amortised O(1) per sample — this is the van Herk / Gil-Werman bound, reached
 * through the deque rather than through two prefix-minimum passes.
 *
 * `queue` and `virtual` are caller-owned scratch so the loop allocates nothing.
 */
function slidingWindowMinimum(line: Float32Array, extent: number, radius: number,
  virtual: Float32Array, queue: Int32Array): void {
  const window = 2 * radius + 1;
  const total = extent + window - 1;
  // Materialise the end-replicated input without a clamp call per sample: the
  // leading and trailing `radius` samples are the edge pixel, the middle is the
  // line itself.
  const first = line[0];
  const last = line[extent - 1];
  for (let index = 0; index < radius; index++) virtual[index] = first;
  for (let index = 0; index < extent; index++) virtual[radius + index] = line[index];
  for (let index = 0; index < radius; index++) virtual[radius + extent + index] = last;
  let head = 0;
  let tail = 0;
  for (let index = 0; index < total; index++) {
    const sample = virtual[index];
    while (tail > head && virtual[queue[tail - 1]] >= sample) tail--;
    queue[tail++] = index;
    // A window is only complete once its LAST sample has been pushed, so the
    // output that ends here is `index - window + 1`, not `index - radius` —    // emitting early would report a minimum of a half-filled window.
    const output = index - window + 1;
    if (output < 0) continue;
    while (queue[head] < output) head++;
    line[output] = virtual[queue[head]];
  }
}

/**
 * Dark channel: the minimum of a plane over a `2*radius+1` square window.
 *
 * The minimum is separable — the minimum over a square is the minimum of the
 * per-row minima — so the same 1-D van Herk/deque pass runs along every row and
 * then along every column. The earlier form ran the row pass but then reduced the
 * window's rows element by element, which is O(radius) per pixel; at a 2048-pixel
 * long edge the dark-channel radius is 10, so that was twenty-one comparisons for
 * every pixel of every pass. The column pass streams one column through the same
 * scratch line, so it is O(1) per pixel in the window width and allocates nothing
 * inside a loop.
 */
function minFilterPlane(source: Float32Array, frameWidth: number, frameHeight: number,
  radius: number): Float32Array {
  const count = frameWidth * frameHeight;
  const result = new Float32Array(count);
  const safeRadius = Math.max(0, Math.floor(radius));
  if (safeRadius === 0) {
    result.set(source.subarray(0, count));
    return result;
  }
  const horizontal = new Float32Array(count);
  const extent = frameWidth > frameHeight ? frameWidth : frameHeight;
  const line = new Float32Array(extent);
  // The sliding window stages one line of virtual (end-replicated) samples, so
  // both scratch buffers are wider than any row or column.
  const stage = extent + 2 * safeRadius;
  const virtual = new Float32Array(stage);
  const queue = new Int32Array(stage);
  for (let row = 0; row < frameHeight; row++) {
    const rowStart = row * frameWidth;
    for (let column = 0; column < frameWidth; column++) line[column] = source[rowStart + column];
    slidingWindowMinimum(line, frameWidth, safeRadius, virtual, queue);
    for (let column = 0; column < frameWidth; column++) horizontal[rowStart + column] = line[column];
  }
  for (let column = 0; column < frameWidth; column++) {
    for (let row = 0; row < frameHeight; row++) line[row] = horizontal[row * frameWidth + column];
    slidingWindowMinimum(line, frameHeight, safeRadius, virtual, queue);
    for (let row = 0; row < frameHeight; row++) result[row * frameWidth + column] = line[row];
  }
  return result;
}
/** Weight that tapers the clarity amount to zero at both ends of the tonal
 *  range, so a highlight or a shadow cannot be pushed into a halo. */
function midtoneWeight(luma: number): number {
  const distance = Math.abs(luma * 2 - 1);
  if (distance >= 1) return 0;
  const t = 1 - distance;
  return t * t * (3 - 2 * t);
}

/** Smooth ramp between two luma edges, used only by the sharpening mask. */
function smoothRamp(edgeStart: number, edgeEnd: number, input: number): number {
  if (edgeEnd <= edgeStart) return input < edgeStart ? 0 : 1;
  let t = (input - edgeStart) / (edgeEnd - edgeStart);
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  return t * t * (3 - 2 * t);
}

/**
 * Colour-preserving local-contrast gain for one pixel.
 *
 * The two-band stage below decides how much luminance to add; this turns that
 * one adjustment into a per-channel multiplier, `(luma + adjustment) / luma`, so
 * the correction is applied in proportion to each channel and a coloured edge
 * keeps its colour ratio.
 */
function contrastGain(luma: number, adjustment: number): number {
  const divisor = luma > LUMA_FLOOR ? luma : LUMA_FLOOR;
  return (luma + adjustment) / divisor;
}

/**
 * Band-pass gain for one pixel, in units of the local base.
 *
 * At the call site this is multiplied by the local base, so the adjustment it
 * produces is `detail * gain` — that is, an ordinary unsharp mask with a
 * relative-contrast-dependent amount.
 *
 * Writing the gain in terms of the *signed* relative contrast `detail / base`
 * rather than the absolute one is what makes the slider behave the same on a
 * dark subject and on a bright one. The `1 / (1 + |relative| / reference)` shape
 * then keeps the gain at `amount` for the fine detail that fills a real
 * photograph and rolls it off towards zero as an edge gets stronger, which is
 * what stops a hard boundary from turning into a halo.
 *
 * The sign of `detail` is carried through deliberately. A gain with no sign only
 * ever brightens, so it would raise the frame's mean instead of increasing
 * contrast, and a pixel would be pushed up by both of the two bands it sits
 * between. With the sign, a bright side of an edge goes up and a dark side comes
 * down, which is what leaves the average where it was.
 *
 * A zero or missing base contributes nothing: there is no ratio to preserve
 * against a black pixel.
 */
function bandPassCoefficient(detail: number, base: number, amount: number, weight: number): number {
  if (amount === 0 || weight <= 0) return 0;
  if (base <= LUMA_FLOOR) return 0;
  const relative = detail / base;
  const magnitude = Math.abs(relative);
  return amount * weight * relative / (1 + magnitude / LOCAL_CONTRAST_REFERENCE_CONTRAST);
}

/** Soft saturation of a signed value to +/-limit, so a pathological frame cannot
 *  drive the correction past the ceiling. */
function softLimit(input: number, limit: number): number {
  return limit * Math.tanh(input / limit);
}

/**
 * Texture and clarity: one two-band local-contrast decomposition.
 *
 * `luma` is the luminance plane of `output` as it was on entry. Two low-passes
 * are taken:
 *
 *  - the fine base, at the texture radius, which has had fine texture removed
 *    but still carries broad structure;
 *  - the coarse base, at the clarity radius, which has had almost everything
 *    except the broad structure removed.
 *
 * The two bands are then the *difference of the two scales*, not two independent
 * high-passes:
 *
 *  - `textureDetail = luma - baseFine` is everything finer than the texture
 *    radius. This is what Texture acts on.
 *  - `clarityDetail = baseFine - baseCoarse` is the band between the two radii.
 *    This is what Clarity acts on.
 *
 * That split is what makes the two stages genuinely different frequencies rather
 * than two strengths of one filter. A fine checkerboard lives almost entirely in
 * the texture band: the fine blur removes it, so once it is gone the difference
 * between the two bases is nearly zero and Clarity can hardly see it. A broad
 * gradient is the other way round — the fine blur barely changes it, so it
 * vanishes from the texture band while the two bases still disagree across the
 * clarity radius, which is where Clarity gets its signal. Giving Clarity the
 * plain `luma - baseCoarse` high-pass instead would have handed it the whole
 * fine band as well and made the two sliders nearly the same control.
 *
 * Mean luminance is preserved in two steps. The coefficient carries the sign of
 * the detail (see `bandPassCoefficient`), so the two sides of an edge move in
 * opposite directions, and the residual mean of the whole adjustment plane is
 * then subtracted before it is applied. That second step is what makes the
 * property hold exactly rather than approximately: the coefficient is normalised
 * by a *local* base, which is slightly larger on the bright side of an edge than
 * on the dark side, so a pure sign-symmetric form still leaves a small
 * systematic bias. Removing the DC term of the correction is also the right
 * thing artistically — a local-contrast control should not double as an exposure
 * control.
 *
 * Clarity carries a midtone weight, so the same local contrast is adjusted less
 * near black and near white; that is what stops highlights and shadows from
 * haloing. Texture carries no weight, matching the detail-only character of that
 * control.
 */
/**
 * Guided filter with the image as its own guide — Compositor's `guided_filter_plane`.
 *
 *   mean = box(src, r);  var = box(src², r) − mean²
 *   a = var / (var + eps);  b = mean − a·mean
 *   dst = box(a, r)·src + box(b, r)
 *
 * An edge-aware blur: it preserves edges where the local variance is large and
 * behaves like a plain blur inside flat areas, which is what keeps clarity from
 * haloing across strong borders.
 *
 * The filter needs six whole-frame planes at once (three scratch, mean, mean
 * square, and the result); the scratch halves are owned by the caller so the two
 * bands of one frame share them instead of each allocating its own set. Every
 * plane is released only when the result is returned, and `mean`/`meanSquare` are
 * reused as blur scratch once `a` and `b` have been derived from them — none of
 * the transients outlive the call.
 */
class GuidedScratch {
  tempA: Float32Array = new Float32Array(0);
  tempB: Float32Array = new Float32Array(0);
  spare: Float32Array = new Float32Array(0);
  mean: Float32Array = new Float32Array(0);
  meanSquare: Float32Array = new Float32Array(0);

  ensure(count: number): void {
    if (this.tempA.length === count) return;
    this.tempA = new Float32Array(count);
    this.tempB = new Float32Array(count);
    this.spare = new Float32Array(count);
    this.mean = new Float32Array(count);
    this.meanSquare = new Float32Array(count);
  }
}

function guidedFilterPlane(source: Float32Array, frameWidth: number, frameHeight: number,
  radius: number, epsilon: number, scratch: GuidedScratch): Float32Array {
  const count = frameWidth * frameHeight;
  scratch.ensure(count);
  const tempA = scratch.tempA;
  const tempB = scratch.tempB;
  const spare = scratch.spare;
  const mean = scratch.mean;
  const meanSquare = scratch.meanSquare;
  // mean = box(src)
  boxBlurInto(source, frameWidth, frameHeight, radius, tempA, tempB, mean);
  // spare = src²; meanSquare = box(spare). tempA/tempB are free again.
  for (let index = 0; index < count; index++) spare[index] = source[index] * source[index];
  boxBlurInto(spare, frameWidth, frameHeight, radius, tempA, tempB, meanSquare);
  // a -> tempA, b -> tempB, reusing the two blur scratch planes. `b` reads `a`
  // back out of the plane, not out of the local, so it sees the same float32
  // rounding the original in-place form did.
  for (let index = 0; index < count; index++) {
    const variance = meanSquare[index] - mean[index] * mean[index];
    tempA[index] = variance / (variance + epsilon);
    tempB[index] = mean[index] - tempA[index] * mean[index];
  }
  // box(a) -> spare; box(b) -> tempB in place. mean/meanSquare are dead now and
  // serve as the two blur scratch planes for both passes.
  boxBlurInto(tempA, frameWidth, frameHeight, radius, mean, meanSquare, spare);
  boxBlurInto(tempB, frameWidth, frameHeight, radius, mean, meanSquare, tempB);
  const destination = new Float32Array(count);
  for (let index = 0; index < count; index++) {
    destination[index] = spare[index] * source[index] + tempB[index];
  }
  return destination;
}

/**
 * Texture and clarity, aligned with Compositor's `adjust_camera_raw_effects`:
 *
 *   fine   = guided(tone, textureRadius)
 *   coarse = guided(tone, clarityRadius)
 *   detail = texture·gainT·(tone − fine) + clarity·gainC·(tone − coarse)
 *   target = clamp(tone + detail, 0, 1);  rgb *= target / tone
 *
 * The last step is Compositor's `scale_luminance`: the correction is applied as a
 * per-channel multiplier, so a coloured edge keeps its colour ratio. The gains are
 * asymmetric (positive = 0.6 / 0.85, negative = 0.5) exactly as in the reference.
 */
function applyTextureClarity(output: Uint8ClampedArray, luma: Float32Array,
  frameWidth: number, frameHeight: number, longEdge: number,
  texture: number, clarity: number): void {
  const count = frameWidth * frameHeight;
  // One scratch set is shared by the fine and coarse bands; the results are
  // separate planes because both are needed by the combine loop below.
  const scratch = new GuidedScratch();
  const fine: Float32Array | null = texture !== 0
    ? guidedFilterPlane(luma, frameWidth, frameHeight, textureRadius(longEdge), GUIDED_EPSILON, scratch)
    : null;
  const coarse: Float32Array | null = clarity !== 0
    ? guidedFilterPlane(luma, frameWidth, frameHeight, clarityRadius(longEdge), GUIDED_EPSILON, scratch)
    : null;
  if (fine === null && coarse === null) return;
  const textureGain = texture > 0 ? TEXTURE_POSITIVE_GAIN : TEXTURE_NEGATIVE_GAIN;
  const clarityGain = clarity > 0 ? CLARITY_POSITIVE_GAIN : CLARITY_NEGATIVE_GAIN;
  for (let index = 0; index < count; index++) {
    const tone = luma[index];
    let detail = 0;
    if (fine !== null) detail += texture * textureGain * (tone - fine[index]);
    if (coarse !== null) detail += clarity * clarityGain * (tone - coarse[index]);
    if (detail === 0) continue;
    let target = tone + detail;
    if (target < 0) target = 0;
    if (target > 1) target = 1;
    const divisor = tone > LUMA_FLOOR ? tone : LUMA_FLOOR;
    const gain = target / divisor;
    const offset = index * 4;
    const red = output[offset] * gain;
    const green = output[offset + 1] * gain;
    const blue = output[offset + 2] * gain;
    output[offset] = red < 0 ? 0 : (red > 255 ? 255 : Math.round(red));
    output[offset + 1] = green < 0 ? 0 : (green > 255 ? 255 : Math.round(green));
    output[offset + 2] = blue < 0 ? 0 : (blue > 255 ? 255 : Math.round(blue));
  }
  // No trailing luminancePlane(): every later stage that needs a luminance plane
  // (dehaze, sharpen) builds its own from the post-band pixels, so recomputing it
  // here was a full-frame pass whose result nobody read.
}

function applyTwoBandContrast(output: Uint8ClampedArray, luma: Float32Array,
  frameWidth: number, frameHeight: number, fineSigma: number, coarseSigma: number,
  textureAmount: number, clarityAmount: number): void {
  const count = frameWidth * frameHeight;
  const baseFine = boxBlurPlane(luma, frameWidth, frameHeight, fineSigma);
  const baseCoarse = boxBlurPlane(luma, frameWidth, frameHeight, coarseSigma);
  const adjustment = new Float32Array(count);
  let total = 0;
  for (let index = 0; index < count; index++) {
    const centre = luma[index];
    const fine = baseFine[index];
    const coarse = baseCoarse[index];
    const textureTerm = fine * bandPassCoefficient(centre - fine, fine, textureAmount, 1);
    const clarityTerm = coarse * bandPassCoefficient(fine - coarse, coarse, clarityAmount,
      midtoneWeight(centre));
    const combined = softLimit(textureTerm + clarityTerm, LOCAL_CONTRAST_MAX_ADJUSTMENT);
    adjustment[index] = combined;
    total += combined;
  }
  const bias = total / count;
  for (let index = 0; index < count; index++) {
    const residual = adjustment[index] - bias;
    if (residual === 0) continue;
    const offset = index * 4;
    const gain = contrastGain(luma[index], residual);
    const r = output[offset] * gain;
    const g = output[offset + 1] * gain;
    const b = output[offset + 2] * gain;
    output[offset] = r < 0 ? 0 : (r > 255 ? 255 : Math.round(r));
    output[offset + 1] = g < 0 ? 0 : (g > 255 ? 255 : Math.round(g));
    output[offset + 2] = b < 0 ? 0 : (b > 255 ? 255 : Math.round(b));
  }
  luminancePlane(output, frameWidth, frameHeight, luma);
}

/**
 * Dark-channel prior dehaze.
 *
 * `strength` is `params.dehaze` in -1..1. Positive values run the inversion
 * described in the file header; negative values run the forward atmospheric
 * model `I = J * t + A * (1 - t)` scaled by 0.25, which is what "add haze"
 * means. Zero returns immediately: the frame is left exactly as it was.
 */
function applyDehaze(output: Uint8ClampedArray, frameWidth: number, frameHeight: number,
  strength: number, longEdge: number): void {
  if (strength === 0) return;
  const count = frameWidth * frameHeight;
  const luminance = new Float32Array(count);
  luminancePlane(output, frameWidth, frameHeight, luminance);

  const windowRadius = dehazeWindowRadius(longEdge);
  const darkChannel = minFilterPlane(luminance, frameWidth, frameHeight, windowRadius);

  // Airlight from a high percentile of the dark channel, not from its maximum: a
  // specular highlight is the brightest dark-channel pixel in a clean frame and
  // would otherwise set the airlight for the whole image.
  //
  // The tail is selected by *rank from the top*, over a 256-bin histogram of the
  // channel. That keeps the cost linear in the frame instead of sorting it, and
  // the rank direction is what matters: walking the bins from the bright end and
  // stopping as soon as `tail` pixels have been counted yields the smallest
  // dark-channel code value that the brightest `tail` pixels reach. Counting up
  // from zero instead would land on that same bin and then average almost the
  // whole frame, pinning the airlight to the frame mean.
  //
  // At least one pixel is always kept, and a hard cap on the tail stops a
  // degenerate (very flat) frame from treating half the picture as sky. Note the
  // limit of the method: when the dark channel is nearly constant, the percentile
  // is a tie across a large group, and no estimator based on this channel can
  // recover an airlight the frame does not contain.
  const tail = Math.max(1, Math.min(Math.round(count / 4),
    Math.round((1 - DEHAZE_AIRLIGHT_PERCENTILE) * count)));
  const histogram = new Uint32Array(256);
  for (let index = 0; index < count; index++) {
    let bin = Math.round(darkChannel[index] * 255);
    if (bin < 0) bin = 0;
    if (bin > 255) bin = 255;
    histogram[bin]++;
  }
  let accumulated = 0;
  let thresholdBin = 0;
  for (let bin = 255; bin >= 0; bin--) {
    accumulated += histogram[bin];
    if (accumulated >= tail) {
      thresholdBin = bin;
      break;
    }
  }
  const threshold = thresholdBin / 255;
  let airR = 0;
  let airG = 0;
  let airB = 0;
  let airCount = 0;
  for (let index = 0; index < count; index++) {
    if (darkChannel[index] < threshold) continue;
    const offset = index * 4;
    airR += output[offset];
    airG += output[offset + 1];
    airB += output[offset + 2];
    airCount++;
  }
  // The mean of that tail, not the single brightest pixel, so one specular
  // highlight cannot set the airlight for the whole frame.
  let airlightR = 255;
  let airlightG = 255;
  let airlightB = 255;
  if (airCount > 0) {
    airlightR = airR / airCount;
    airlightG = airG / airCount;
    airlightB = airB / airCount;
  }
  if (!(airlightR >= 1)) airlightR = 1;
  if (!(airlightG >= 1)) airlightG = 1;
  if (!(airlightB >= 1)) airlightB = 1;

  // A minimum-filtered transmission map keeps the transition free of the
  // blockiness a raw per-window estimate produces, without needing soft matting.
  const transmission = minFilterPlane(darkChannel, frameWidth, frameHeight, windowRadius);
  const strengthMagnitude = Math.abs(strength);
  const removeHaze = strength > 0;
  for (let index = 0; index < count; index++) {
    const offset = index * 4;
    let t = 1 - DEHAZE_OMEGA * transmission[index];
    if (t < DEHAZE_MIN_TRANSMISSION) t = DEHAZE_MIN_TRANSMISSION;
    if (t > 1) t = 1;
    const r = output[offset];
    const g = output[offset + 1];
    const b = output[offset + 2];
    let resolvedR = r;
    let resolvedG = g;
    let resolvedB = b;
    if (removeHaze) {
      // Where the estimated transmission is already high the frame needed no
      // correction, and the recovery is algebraically a no-op there. Where it is
      // low the estimate is at its least reliable, and a full division would
      // multiply a dark pixel by up to 1/t0; the transmission weight holds that
      // back smoothly instead of letting a mis-estimated window darken or blow
      // out a shadow. This is the one heuristic in the pipeline, and it is the
      // reason a haze-free frame is very nearly left alone.
      const weight = strengthMagnitude * t * t;
      const recoveredR = (r - airlightR) / t + airlightR;
      const recoveredG = (g - airlightG) / t + airlightG;
      const recoveredB = (b - airlightB) / t + airlightB;
      resolvedR = r + (recoveredR - r) * weight;
      resolvedG = g + (recoveredG - g) * weight;
      resolvedB = b + (recoveredB - b) * weight;
      if (!(resolvedR >= 0)) resolvedR = 0;
      if (resolvedR > 255) resolvedR = 255;
      if (!(resolvedG >= 0)) resolvedG = 0;
      if (resolvedG > 255) resolvedG = 255;
      if (!(resolvedB >= 0)) resolvedB = 0;
      if (resolvedB > 255) resolvedB = 255;
    } else {
      const hazeR = r * t + airlightR * (1 - t);
      const hazeG = g * t + airlightG * (1 - t);
      const hazeB = b * t + airlightB * (1 - t);
      const amount = strengthMagnitude * DEHAZE_ADD_STRENGTH;
      resolvedR = r + (hazeR - r) * amount;
      resolvedG = g + (hazeG - g) * amount;
      resolvedB = b + (hazeB - b) * amount;
    }
    output[offset] = removeHaze ? resolvedR : r + (resolvedR - r) * strengthMagnitude;
    output[offset + 1] = removeHaze ? resolvedG : g + (resolvedG - g) * strengthMagnitude;
    output[offset + 2] = removeHaze ? resolvedB : b + (resolvedB - b) * strengthMagnitude;
  }
}

/**
 * Unsharp mask with a Sobel-gradient edge mask.
 *
 * `result = I + amount * mask * (I - blur(radius) + detail * highPass3x3(I))`.
 *
 * The correction is a luminance delta added to every channel equally, so hue is
 * preserved and the pixel's own brightness never scales the correction away. A
 * gain-based form (`I * (1 + delta)`) would shrink a bright edge's correction
 * below half a code value, where rounding erases it entirely.
 *
 * The `detail` term is a fixed 3x3 high-pass, so a larger detail mixes in more
 * of the highest frequency the frame has and the edge gets crisper and thinner.
 * `masking` blends between an all-ones mask (no protection) and a Sobel edge
 * magnitude, so a flat field — where the gradient is zero — is left alone while
 * an edge still gets the full amount. That is what makes masking a noise
 * control rather than a second strength control.
 */
/**
 * 整帧雾色估计：最亮 1%（按 alpha 加权）像素的 rec709 亮度分位，取其 RGB 均值。
 *
 * 单独导出，是为了让**放大瓦片**能用整帧算出的雾色。lightcraft 正是这么做的：
 * `RenderRequest::window` 把整帧 airlight 带进窗口渲染（`lib.rs` 里 "The whole
 * frame's dehaze airlight, for a windowed render"），否则窗口内自算的 airlight 与
 * 整帧不同，放大后的去朦胧结果和整帧对不上。返回空数组表示无法估计。
 */
export function dehazeHazeColor(output: Uint8ClampedArray, frameWidth: number,
  frameHeight: number): number[] {
  const count = frameWidth * frameHeight;
  // Native first (the same estimator, one pass instead of four interpreted
  // ones). It returns null when it cannot serve the call, e.g. a short buffer,
  // and then the ArkTS estimate below produces exactly the same numbers.
  if (output.length >= count * 4) {
    const native = nativeDetailHazeColor(output, frameWidth, frameHeight);
    if (native !== null) return native;
  }
  const histogram = new Float32Array(256);
  for (let index = 0; index < count; index++) {
    const offset = index * 4;
    const alpha = output[offset + 3];
    if (alpha === 0) continue;
    const red = Math.min(1, output[offset] / alpha);
    const green = Math.min(1, output[offset + 1] / alpha);
    const blue = Math.min(1, output[offset + 2] / alpha);
    // The Rec.709 dot product is written out rather than calling `lumaOf`: this
    // loop and the one below run over the whole frame and a call per pixel was
    // the largest single cost of estimating the haze color.
    let bin = Math.round(255 * (red * LUMA_R + green * LUMA_G + blue * LUMA_B));
    if (bin < 0) bin = 0;
    if (bin > 255) bin = 255;
    histogram[bin] += alpha / 255;
  }
  let total = 0;
  for (let bin = 0; bin < 256; bin++) total += histogram[bin];
  if (total <= 0) return [];
  let threshold = 255;
  let above = 0;
  while (threshold > 0 && above + histogram[threshold] < total * 0.01) {
    above += histogram[threshold];
    threshold--;
  }
  let hazeRed = 0;
  let hazeGreen = 0;
  let hazeBlue = 0;
  let weight = 0;
  for (let index = 0; index < count; index++) {
    const offset = index * 4;
    const alpha = output[offset + 3];
    if (alpha === 0) continue;
    const red = Math.min(1, output[offset] / alpha);
    const green = Math.min(1, output[offset + 1] / alpha);
    const blue = Math.min(1, output[offset + 2] / alpha);
    if (Math.round(255 * (red * LUMA_R + green * LUMA_G + blue * LUMA_B)) < threshold) continue;
    const w = alpha / 255;
    hazeRed += red * w;
    hazeGreen += green * w;
    hazeBlue += blue * w;
    weight += w;
  }
  if (weight <= 0) return [];
  return [hazeRed / weight, hazeGreen / weight, hazeBlue / weight];
}

/** 用给定的雾色执行去朦胧的正/负两支。 */
function applyDehazeWithColor(output: Uint8ClampedArray, frameWidth: number, frameHeight: number,
  strength: number, hazeRed: number, hazeGreen: number, hazeBlue: number): void {
  const count = frameWidth * frameHeight;
  const positive = strength > 0;
  const amount = positive ? strength : -strength;
  const veil = 0.3 * Math.pow(amount, 1.3);
  for (let index = 0; index < count; index++) {
    const offset = index * 4;
    const alpha = output[offset + 3];
    if (alpha === 0) continue;
    let red = Math.min(1, output[offset] / alpha);
    let green = Math.min(1, output[offset + 1] / alpha);
    let blue = Math.min(1, output[offset + 2] / alpha);
    if (positive) {
      let dark = 1;
      const scaleR = red / Math.max(hazeRed, 1e-3);
      const scaleG = green / Math.max(hazeGreen, 1e-3);
      const scaleB = blue / Math.max(hazeBlue, 1e-3);
      if (scaleR < dark) dark = scaleR;
      if (scaleG < dark) dark = scaleG;
      if (scaleB < dark) dark = scaleB;
      let transmission = 1 - 0.7 * amount * dark;
      if (transmission < 0.5) transmission = 0.5;
      red = (red - hazeRed) / transmission + hazeRed;
      green = (green - hazeGreen) / transmission + hazeGreen;
      blue = (blue - hazeBlue) / transmission + hazeBlue;
    } else {
      red = red * (1 - veil) + hazeRed * veil;
      green = green * (1 - veil) + hazeGreen * veil;
      blue = blue * (1 - veil) + hazeBlue * veil;
    }
    output[offset] = Math.round(Math.max(0, Math.min(1, red)) * alpha);
    output[offset + 1] = Math.round(Math.max(0, Math.min(1, green)) * alpha);
    output[offset + 2] = Math.round(Math.max(0, Math.min(1, blue)) * alpha);
  }
}

function applyDehazeCompositor(output: Uint8ClampedArray, frameWidth: number, frameHeight: number,
  strength: number, haze: number[] = []): void {
  if (strength === 0) return;
  // 放大瓦片会把整帧雾色带进来，这里直接用它，保证瓦片与整帧一致。
  if (haze.length === 3) {
    if (haze[0] > 0.999 && haze[1] > 0.999 && haze[2] > 0.999) return;
    applyDehazeWithColor(output, frameWidth, frameHeight, strength, haze[0], haze[1], haze[2]);
    return;
  }
  // 未提供整帧雾色时（全帧渲染）就地估计：最亮 1% 的 alpha 加权 RGB 均值。
  // 估计逻辑与导出的 `dehazeHazeColor` 共用一份，避免两条路径各写一套而在
  // 瓦片/整帧之间漂移；下面两条早退与它返回空数组的含义一一对应。
  const hazeColor = dehazeHazeColor(output, frameWidth, frameHeight);
  if (hazeColor.length !== 3) return;
  // 2) 雾色就是整幅图（单色图全是雾），此时去朦胧应当不动它。
  if (hazeColor[0] > 0.999 && hazeColor[1] > 0.999 && hazeColor[2] > 0.999) return;
  applyDehazeWithColor(output, frameWidth, frameHeight, strength,
    hazeColor[0], hazeColor[1], hazeColor[2]);
}

function applySharpen(output: Uint8ClampedArray, frameWidth: number, frameHeight: number,
  radius: number, amount: number, detail: number, masking: number): void {
  const count = frameWidth * frameHeight;
  const luminance = new Float32Array(count);
  luminancePlane(output, frameWidth, frameHeight, luminance);
  const base = boxBlurPlane(luminance, frameWidth, frameHeight, Math.max(1, radius));
  // The 3x3 high-pass and the Sobel gradient are both read from the resident
  // plane; nothing per-pixel is allocated. The neighbour indices are clamped with
  // inline comparisons and the two per-pixel helpers (`smoothRamp`, `softLimit`)
  // are written out, for the same reason the box pass no longer calls
  // `clampedIndex`: a call per pixel costs many times the arithmetic it wraps.
  const lastColumn = frameWidth - 1;
  const lastRow = frameHeight - 1;
  const edgeSpan = 6 - 0.5;
  for (let row = 0; row < frameHeight; row++) {
    const rowOffset = row * frameWidth;
    const upRow = (row > 0 ? row - 1 : 0) * frameWidth;
    const downRow = (row < lastRow ? row + 1 : lastRow) * frameWidth;
    for (let column = 0; column < frameWidth; column++) {
      const index = rowOffset + column;
      const offset = index * 4;
      const leftIndex = column > 0 ? column - 1 : 0;
      const rightIndex = column < lastColumn ? column + 1 : lastColumn;
      const luma = luminance[index];
      const up = luminance[upRow + column];
      const down = luminance[downRow + column];
      const left = luminance[rowOffset + leftIndex];
      const right = luminance[rowOffset + rightIndex];
      const highPass = luma * 4 - up - down - left - right;
      // True Sobel: the corner terms make the magnitude respond to an oblique
      // edge as strongly as to an axis-aligned one, which a 4-neighbour
      // difference does not.
      const upperLeft = luminance[upRow + leftIndex];
      const upperRight = luminance[upRow + rightIndex];
      const lowerLeft = luminance[downRow + leftIndex];
      const lowerRight = luminance[downRow + rightIndex];
      const gradX = (upperRight + 2 * right + lowerRight) - (upperLeft + 2 * left + lowerLeft);
      const gradY = (lowerLeft + 2 * down + lowerRight) - (upperLeft + 2 * up + upperRight);
      const gradient = Math.sqrt(gradX * gradX + gradY * gradY);
      // A field can be flat in luminance and still carry per-channel noise, so
      // take the stronger of the Sobel magnitude and the channel spread.
      const r = output[offset] / 255;
      const g = output[offset + 1] / 255;
      const b = output[offset + 2] / 255;
      const channelDelta = Math.max(Math.abs(r - luma), Math.abs(g - luma), Math.abs(b - luma));
      const activity = Math.max(gradient, channelDelta * 8);
      let ramp = (activity - 0.5) / edgeSpan;
      if (ramp < 0) ramp = 0;
      if (ramp > 1) ramp = 1;
      const edge = ramp * ramp * (3 - 2 * ramp);
      const mask = 1 - masking * (1 - edge);
      if (mask <= 0) continue;
      const unsharp = luma - base[index];
      const adjustment = SHARPEN_MAX_ADJUSTMENT * Math.tanh(
        amount * mask * (unsharp + highPass * detail) / SHARPEN_MAX_ADJUSTMENT) * 255;
      const rr = output[offset] + adjustment;
      const gg = output[offset + 1] + adjustment;
      const bb = output[offset + 2] + adjustment;
      output[offset] = rr < 0 ? 0 : (rr > 255 ? 255 : Math.round(rr));
      output[offset + 1] = gg < 0 ? 0 : (gg > 255 ? 255 : Math.round(gg));
      output[offset + 2] = bb < 0 ? 0 : (bb > 255 ? 255 : Math.round(bb));
    }
  }
}

/**
 * Byte-for-byte cross-check of the native module against this implementation,
 * logged once per process. Off by default: it costs one extra ArkTS pass.
 *
 * It exists because a Node probe can only prove parity for the fixtures it
 * ships, while this compares the two implementations on the exact frame the
 * device is rendering (real camera data, real parameter values). It was run
 * once with this flag set for the migration's acceptance run; the logged
 * `maxCh=0 over2=0` line is the on-device parity evidence.
 */
const NATIVE_DETAIL_SELF_CHECK: boolean = false;
let nativeDetailSelfChecked: boolean = false;

function selfCheckNativeDetail(rgba: Uint8ClampedArray, frameWidth: number, frameHeight: number,
  params: LocalContrastParams, longEdge: number, haze: number[],
  native: Uint8ClampedArray): void {
  if (nativeDetailSelfChecked) return;
  nativeDetailSelfChecked = true;
  // Time both paths on the same bytes, so the reported numbers are a same-frame
  // comparison rather than two different renders.
  const request = nativeDetailRequest(params, longEdge, haze);
  const nativeStart = Date.now();
  nativeDetailApply(rgba, frameWidth, frameHeight, request);
  const nativeMs = Date.now() - nativeStart;
  const arktsStart = Date.now();
  const reference = applyLocalContrastArkTs(rgba, frameWidth, frameHeight, params, longEdge, haze);
  const arktsMs = Date.now() - arktsStart;
  let maxCh = 0;
  let over2 = 0;
  const length = Math.min(reference.length, native.length);
  for (let index = 0; index < length; index++) {
    const delta = Math.abs(reference[index] - native[index]);
    if (delta > maxCh) maxCh = delta;
    if (delta > 2) over2++;
  }
  const sizeDiffers = reference.length !== native.length ? 1 : 0;
  console.info(`VIVID_NATIVE_DETAIL selfcheck maxCh=${maxCh} over2=${over2} ` +
    `sizeDiffers=${sizeDiffers} bytes=${length} size=${frameWidth}x${frameHeight} ` +
    `nativeMs=${nativeMs} arktsMs=${arktsMs} texture=${params.texture} clarity=${params.clarity} ` +
    `dehaze=${params.dehaze} sharpen=${params.sharpenAmount}`);
}

/**
 * Resolve the clamped parameter values the native entry point expects.
 *
 * The two `Math.pow`-derived inputs are computed here rather than in C++ for the
 * same reason the mask rasteriser passes `ca`/`sa` in: `pow` is engine-specific
 * in the last ulp, and these values must be bit-identical on both sides.
 */
function nativeDetailRequest(params: LocalContrastParams, longEdge: number,
  haze: number[]): NativeDetailRequest {
  const dehaze = clampMagnitude(params.dehaze, 1);
  const request: NativeDetailRequest = {
    radiusTexture: textureRadius(longEdge),
    radiusClarity: clarityRadius(longEdge),
    radiusSharpen: sharpenRadiusPixels(longEdge, params.sharpenRadius),
    texture: params.texture,
    clarity: params.clarity,
    dehaze: params.dehaze,
    veil: 0.3 * Math.pow(Math.abs(dehaze), 1.3),
    sharpenAmount: params.sharpenAmount,
    sharpenDetail: params.sharpenDetail,
    sharpenMasking: params.sharpenMasking,
    hasHaze: haze.length === 3,
    hazeRed: haze.length === 3 ? haze[0] : 1,
    hazeGreen: haze.length === 3 ? haze[1] : 1,
    hazeBlue: haze.length === 3 ? haze[2] : 1,
  };
  return request;
}

/**
 * Apply the four spatial stages to an RGBA frame.
 *
 * Returns a NEW buffer. `rgba` is never written to, and the alpha byte of every
 * pixel is copied through untouched. When the parameters are at their identity
 * values the copy is byte-for-byte identical to the input.
 *
 * Runs on the native module when it is available and falls back to
 * `applyLocalContrastArkTs` below, which is the reference implementation.
 */
export function applyLocalContrast(rgba: Uint8ClampedArray, width: number, height: number,
  params: LocalContrastParams, longEdge: number, haze: number[] = []): Uint8ClampedArray {
  const frameWidth = Math.max(1, Math.floor(width));
  const frameHeight = Math.max(1, Math.floor(height));
  const native = nativeDetailApply(rgba, frameWidth, frameHeight,
    nativeDetailRequest(params, longEdge, haze));
  if (native !== null) {
    if (NATIVE_DETAIL_SELF_CHECK) {
      selfCheckNativeDetail(rgba, frameWidth, frameHeight, params, longEdge, haze, native);
    }
    return native;
  }
  return applyLocalContrastArkTs(rgba, width, height, params, longEdge, haze);
}

/**
 * The reference implementation: pure ArkTS, no native dependency.
 *
 * It is the fallback `applyLocalContrast` runs when the native module is absent
 * or throws, and it is the implementation `vivid_detail_core.cpp` was written to
 * match byte for byte. Do not "optimise" it without re-running
 * tools/check_detail_native_parity.cjs: a change here without the same change in
 * C++ turns the two paths into different renderers.
 */
function applyLocalContrastArkTs(rgba: Uint8ClampedArray, width: number, height: number,
  params: LocalContrastParams, longEdge: number, haze: number[] = []): Uint8ClampedArray {
  const frameWidth = Math.max(1, Math.floor(width));
  const frameHeight = Math.max(1, Math.floor(height));
  const wanted = frameWidth * frameHeight * 4;
  const result = new Uint8ClampedArray(wanted);
  const available = Math.min(rgba.length, wanted);
  for (let index = 0; index < available; index++) result[index] = rgba[index];
  // A short input degrades to transparent black rather than reading out of
  // bounds; the loop above already produced that, so nothing else to do.
  if (localContrastIsIdentity(params)) return result;

  // The band-pass owns one whole-frame float plane, allocated only when a band
  // stage actually runs: a dehaze- or sharpen-only frame never needs it, and a
  // `new Float32Array(count)` is a zero-fill of the whole frame.
  const texture = clampMagnitude(params.texture, 1);
  const clarity = clampMagnitude(params.clarity, 1);
  const luminance = texture !== 0 || clarity !== 0
    ? new Float32Array(frameWidth * frameHeight)
    : new Float32Array(0);

  const dehaze = clampMagnitude(params.dehaze, 1);
  const sharpenAmount = clampUnit(params.sharpenAmount);
  const sharpenDetail = clampUnit(params.sharpenDetail);
  const sharpenMasking = clampUnit(params.sharpenMasking);
  const extent = longEdgeOf(longEdge);

  if (texture !== 0 || clarity !== 0) {
    luminancePlane(result, frameWidth, frameHeight, luminance);
    // Aligned with Compositor: guided-filter fine/coarse bands with asymmetric gains.
    applyTextureClarity(result, luminance, frameWidth, frameHeight, extent, texture, clarity);
  }
  if (dehaze !== 0) {
    applyDehazeCompositor(result, frameWidth, frameHeight, dehaze, haze);
  }
  if (sharpenAmount !== 0) {
    applySharpen(result, frameWidth, frameHeight,
      sharpenRadiusPixels(extent, params.sharpenRadius), sharpenAmount,
      sharpenDetail, sharpenMasking);
  }
  return result;
}
