/**
 * Native detail stage (texture / clarity / dehaze / sharpen) for the editor.
 *
 * The ArkTS twin (`LocalContrastCore.applyLocalContrast`) stays in the code base
 * as the reference implementation and as the fallback when this module cannot be
 * loaded. Both must emit identical bytes; see `vivid_detail_core.h` for the
 * bit-exactness contract and `NativeDetail.ets` for the dispatch.
 *
 * Contract notes for callers:
 *  - `rgba` is the underlying `ArrayBuffer` (`typedArray.buffer`), not the view.
 *    The input is never mutated; the result is a new `width * height * 4` buffer.
 *  - the three radii and `veil` are computed in ArkTS (`textureRadius`,
 *    `clarityRadius`, `sharpenRadiusPixels`, `0.3 * pow(|dehaze|, 1.3)`) and
 *    passed in, because they go through `Math.pow` whose last ulp is
 *    engine-specific while the radii are integers that must match exactly.
 *  - `hasHaze` with `hazeRed/Green/Blue` carries a whole-frame haze colour into
 *    a magnified tile, so the tile and the whole-frame render agree.
 *  - a `null` return means "could not serve this request"; the caller must run
 *    the ArkTS implementation instead.
 */

/** `width * height * 4` RGBA bytes, or null when the request was rejected. */
export function applyDetail(rgba: ArrayBuffer, width: number, height: number,
  radiusTexture: number, radiusClarity: number, radiusSharpen: number,
  texture: number, clarity: number, dehaze: number, veil: number,
  sharpenAmount: number, sharpenDetail: number, sharpenMasking: number,
  hasHaze: boolean, hazeRed: number, hazeGreen: number, hazeBlue: number): ArrayBuffer | null;

/**
 * Whole-frame haze colour `[r, g, b]` in 0..1, or null when the frame carries no
 * usable estimate. Mirrors `LocalContrastCore.dehazeHazeColor`.
 */
export function hazeColor(rgba: ArrayBuffer, width: number, height: number): number[] | null;

/** ABI version of this module; used to log which build is running. */
export function apiVersion(): number;
