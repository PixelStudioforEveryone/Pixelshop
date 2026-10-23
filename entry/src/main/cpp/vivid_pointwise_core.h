/*
 * vivid_pointwise_core - the remaining non-native per-pixel export stages,
 * ported to plain C++ so the exact same translation unit can be compiled into
 * the device library and into the host parity probe.
 *
 * Scope, deliberately narrow:
 *   - LUT stack sampling (ordered stack, trilinear interpolation, intensity
 *     blend, domain remap) from WorkerCore.applyLutStack / sampleLutInto;
 *   - point colour (HSL point shifts) from PointColorCore.applyPointColorBuffer;
 *   - OkLCh grading from OkLChCore.applyOkLChBuffer.
 *
 * Everything here is called with pixel buffers that are already in place: the
 * native side never owns memory and never allocates. The LUT tables themselves
 * are still computed by ArkTS and handed in as a flat double array plus a
 * per-entry metadata array, so C++ only ever samples a table, never rebuilds a
 * curve.
 *
 * Arithmetic contract: doubles, the same operation order as the ArkTS
 * reference, no FMA and no reassociation (the build uses -ffp-contract=off).
 * The reference implementations stay in the ArkTS engine and remain the
 * fallback whenever this module is unavailable.
 */
#ifndef VIVID_POINTWISE_CORE_H
#define VIVID_POINTWISE_CORE_H

#include <cstdint>

namespace vivid {
namespace pointwise {

/* One LUT entry in the flattened metadata array. */
constexpr int32_t kLutMetaStride = 9;
/*
 * Why a flattened LUT stack was refused, as a stable integer so the ArkTS
 * wrapper can log the exact failing field instead of just "nativeRejected".
 * These values are part of the diagnostic contract; tools/check_pointwise_*.cjs
 * asserts them, so do not renumber.
 */
constexpr int32_t kLutStackOk = 0;
constexpr int32_t kLutStackBadLutCount = 2;      /* < 0 or > 64 */
constexpr int32_t kLutStackNullArrays = 3;       /* values/meta pointer missing */
constexpr int32_t kLutStackValuesTooShort = 4;   /* valueCount < lutCount * 3 */
constexpr int32_t kLutStackBadSize = 5;          /* size not an integer in [2, 128] */
constexpr int32_t kLutStackBadIntensity = 6;     /* intensity NaN or negative */
constexpr int32_t kLutStackBadDomain = 7;        /* min/max not finite */
constexpr int32_t kLutStackBadDomainOrder = 8;   /* max <= min on some channel */
constexpr int32_t kLutStackBadOffset = 9;        /* value offset not a non-negative integer */
constexpr int32_t kLutStackTableOutOfRange = 10; /* offset + size^3 * 3 > valueCount */
/* One point-colour sample in the flattened sample array. */
constexpr int32_t kPointColorStride = 9;
/* Floats per OkLCh parameter block. */
constexpr int32_t kOkLChStride = 3;

/*
 * Apply an ordered LUT stack in place.
 *   values     flattened [r,g,b] samples of every active LUT, concatenated
 *   meta       per LUT: size, amount, minR, minG, minB, maxR, maxG, maxB,
 *              valueOffset (index into `values`, in doubles)
 * Returns false (and touches nothing) when the arguments do not validate.
 */
bool lutStack(uint8_t* rgba, int32_t pixelCount, const double* values, int32_t valueCount,
              const double* meta, int32_t lutCount);

/*
 * Validate a flattened stack without touching pixels. Returns one of the
 * kLutStack* codes above, so a rejected call can say which field failed.
 * `lutStack` is exactly `lutStackRejectReason(...) == kLutStackOk` followed by
 * the sampling loop, so this cannot drift from the real validation.
 */
int32_t lutStackRejectReason(const double* values, int32_t valueCount,
                             const double* meta, int32_t lutCount);

/*
 * Apply the point-colour sample stack in place. `samples` holds
 * kPointColorStride doubles per sample:
 *   hue, saturation, luminance, hueShift, saturationShift, luminanceShift,
 *   hueRange, saturationRange, luminanceRange
 * Returns false when the arguments do not validate.
 */
bool pointColor(uint8_t* rgba, int32_t pixelCount, const double* samples, int32_t sampleCount);

/*
 * Apply the OkLCh grade in place. `params` holds [lightness, chroma, hue].
 * Returns false when the arguments do not validate.
 */
bool oklch(uint8_t* rgba, int32_t pixelCount, const double* params);

}  // namespace pointwise
}  // namespace vivid

#endif  // VIVID_POINTWISE_CORE_H
