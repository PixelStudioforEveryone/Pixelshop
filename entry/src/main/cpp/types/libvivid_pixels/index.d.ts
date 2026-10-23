/**
 * Native per-pixel mask rasterisation for the editor.
 *
 * The ArkTS twins of these routines (`MaskRasterCore.renderLinear` /
 * `renderRadial`, and the composition loop in `rasterizeStructuredMaskCore`)
 * stay in the code base as the reference implementation and as the fallback
 * when this module cannot be loaded. They must agree byte for byte: every
 * intermediate is a double, evaluated in the same order, with no FMA
 * contraction and the same 0..255 rounding.
 *
 * Contract notes for callers:
 *  - the rotation cosine/sine are computed in ArkTS and passed in, because
 *    `Math.cos`/`Math.sin` are engine-specific while `std::sqrt`, `+`, `-`, `*`
 *    and `/` on doubles are not;
 *  - `invertOpacity` and `composeInto` mutate in place, so they take the
 *    `ArrayBuffer` (`typedArray.buffer`), not the typed-array view;
 *  - `composeInto` requires `dst` and `src` to have the same length.
 */

/** Linear gradient alpha, `width * height` bytes. */
export function rasterizeLinear(width: number, height: number, sx: number, sy: number,
  ex: number, ey: number, feather: number, modern: boolean): ArrayBuffer;

/** Radial gradient alpha, `width * height` bytes. `ca`/`sa` are the precomputed
 * cosine/sine of the rotation; `rx`/`ry` are already clamped to >= 1. */
export function rasterizeRadial(width: number, height: number, cx: number, cy: number,
  rx: number, ry: number, ca: number, sa: number, feather: number, modern: boolean): ArrayBuffer;

/** Whole-component inversion followed by amount, applied in place. */
export function invertOpacity(buffer: ArrayBuffer, inverted: boolean, opacity: number): void;

/** Compose `src` into `dst` in place: 0 = add (max), 1 = subtract, 2 = intersect. */
export function composeInto(dst: ArrayBuffer, src: ArrayBuffer, blendMode: number): void;

/**
 * Crop / quarter-turn / flip remap, mirroring `remapFrameToDisplay` +
 * `buildFrameSampleTable` in GeometryMath.ets. `rotation` must be 0, 90, 180 or
 * 270 and `outputWidth/Height` must be the crop dimensions with the quarter
 * turn applied, as `buildGeometryMap` computes them. Returns a new
 * `outputWidth * outputHeight * 4` byte buffer; pixels whose inverse falls
 * outside the crop window stay zero, like the ArkTS output it replaces.
 */
export function remapGeometry(input: ArrayBuffer, srcWidth: number, left: number, top: number,
  cropWidth: number, cropHeight: number, outputWidth: number, outputHeight: number,
  rotation: number, flipH: boolean, flipV: boolean): ArrayBuffer;

/**
 * Stored-raster (subject / sky / range) resample into `out`, mirroring
 * `renderBitmap` in MaskRasterCore.ets. `out` must hold `width * height` bytes
 * and `bitmap` at least `bitmapWidth * bitmapHeight`; both are written/read in
 * place. `softness` >= 1 is the pure bilinear path and is bit-exact by
 * construction; `softness` < 1 evaluates the reference curve through `pow`, so
 * the caller probes it byte-for-byte before adopting this routine.
 */
export function sampleBitmap(bitmap: ArrayBuffer, bitmapWidth: number, bitmapHeight: number,
  out: ArrayBuffer, width: number, height: number, softness: number): void;

/**
 * Crop `[rectX, rectY, rectW, rectH]` out of a full-frame alpha plane and
 * bilinearly resample it to `dstWidth x dstHeight`, returning a new
 * `dstWidth * dstHeight` byte buffer. Used by the region (zoom tile) renderer
 * to reuse a mask rasterised once at full-frame size. At 1:1 with integer
 * bounds this is an exact byte copy of the crop.
 */
export function cropScaleAlpha(alpha: ArrayBuffer, srcWidth: number, srcHeight: number,
  rectX: number, rectY: number, rectWidth: number, rectHeight: number,
  dstWidth: number, dstHeight: number): ArrayBuffer;
