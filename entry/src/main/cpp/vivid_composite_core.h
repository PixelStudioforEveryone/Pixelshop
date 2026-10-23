/*
 * vivid_composite_core - native twin of the layer composition loops.
 *
 * `WorkerCore.ets` (`applyLayerBandFull`, `compositeBand`, `applyMatrixBand`)
 * walks every visible layer three times per band in interpreted ArkTS: the
 * colour matrix, the mask blend and the blend-mode composite. On the device a
 * 512x341 preview spent ~400 ms there, so the per-pixel loops move here.
 *
 * Only the arithmetic that has no colour-science dependency lives in this file:
 * the matrix pass, the mask-alpha blend and the composite (normal / multiply /
 * screen / overlay). `applyAdvancedBand` (curves, HSL mixer, grading) stays in
 * ArkTS and runs between these calls, so the pass order is untouched:
 *
 *   matrix -> (advanced, ArkTS) -> mask matrix -> (mask advanced, ArkTS)
 *          -> mask blend -> composite
 *
 * ## Bit-exactness contract
 *
 * Same rules as vivid_detail_core: every sample is widened to double before it
 * is combined (ArkTS reads a Uint8ClampedArray element as a double), every
 * expression keeps ArkTS's associativity, the module is compiled with
 * `-ffp-contract=off`, and `clampByte` reproduces
 * `v < 0 ? 0 : v > 255 ? 255 : Math.round(v)`, including `Math.round`'s
 * "anything below 0.5 is 0" rule.
 *
 * `matrix` arrives as the caller's Float32Array (the same 20 floats
 * `buildMatrix` produces); each element is widened to double like
 * `matrix[i]` in ArkTS.
 */
#ifndef VIVID_COMPOSITE_CORE_H
#define VIVID_COMPOSITE_CORE_H

#include <cstddef>
#include <cstdint>

namespace vivid {

/** Blend modes, matching the ArkTS `blendMode` numbering. */
enum CompositeBlendMode : int32_t {
    kBlendNormal = 0,
    kBlendMultiply = 1,
    kBlendScreen = 2,
    kBlendOverlay = 3,
};

/**
 * Colour matrix over `[start, end)` bytes: `output[idx + c] = clampByte(sum)`.
 * Mirrors `applyMatrixBand` in WorkerCore.ets. `matrixLength` must be >= 20.
 */
void matrixBand(const uint8_t* input, const float* matrix, size_t matrixLength, uint8_t* output,
    size_t start, size_t end);

/**
 * Mask-alpha blend of `adjusted` towards `maskAdjusted`, in place, over
 * `[start, end)` bytes. Mirrors the mask-blend loop in `applyLayerBandFull`:
 * `alpha = mask[(i >> 2) + pixelOffset] / 255`, skipped when `alpha <= 0`.
 */
void maskBlend(uint8_t* adjusted, const uint8_t* maskAdjusted, const uint8_t* mask,
    size_t maskLength, size_t start, size_t end, size_t pixelOffset);

/**
 * Blend `adjusted` into `result` over `[start, end)` bytes.
 *
 * `mask` may be null, in which case the layer's alpha is its opacity alone.
 * Mirrors `compositeBand`: alpha <= 0 skips, alpha >= 1 replaces, otherwise a
 * straight lerp of the already-blended colour against the destination.
 */
void composite(uint8_t* result, const uint8_t* base, const uint8_t* adjusted, const uint8_t* mask,
    size_t maskLength, double opacity, int32_t blendMode, size_t start, size_t end,
    size_t pixelOffset);

}  // namespace vivid

#endif  // VIVID_COMPOSITE_CORE_H
