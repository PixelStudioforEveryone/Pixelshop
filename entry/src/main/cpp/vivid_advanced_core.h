/*
 * Native twin of WorkerCore.applyAdvancedBand's general path.
 *
 * The ArkTS reference stays in WorkerCore.ets. This core is compiled into
 * libvivid_composite and, on the host, into the parity probe used by
 * tools/check_advanced_native_parity.cjs. Both must produce identical bytes for
 * the same parameters; every intermediate is a double evaluated in the same
 * order, no FMA contraction, and the tables arrive precomputed so no curve
 * fitting happens here.
 */
#ifndef VIVID_ADVANCED_CORE_H
#define VIVID_ADVANCED_CORE_H

#include <cstddef>
#include <cstdint>

namespace vivid {

// Bit flags packed in params[19].
enum AdvancedFlag : int {
    kWhiteBalance = 1 << 0,
    kTonal = 1 << 1,
    kVibrance = 1 << 2,
    kCalibration = 1 << 3,
    kMixer = 1 << 4,
    kGrading = 1 << 5,
    kEffects = 1 << 6,
    kParametric = 1 << 7,
    kRefine = 1 << 8,
};

/**
 * Apply the advanced colour band in place over `[start, end)` bytes of
 * `input`. `params` is the packed Float64 layout documented in
 * vivid_advanced_core.cpp (70 entries); `curves` is 4 x 1025 doubles (master,
 * red, green, blue), `tonal` 1025 floats or null, `parametric` 256 floats or
 * null, and `viewport` 6 doubles or null.
 *
 * Returns false when the arguments do not validate, before touching a pixel.
 */
bool advancedBand(uint8_t* input, size_t length, size_t start, size_t end,
    const double* params, size_t paramsLength,
    const double* curves, size_t curvesLength,
    const float* tonal, size_t tonalLength,
    const float* parametric, size_t parametricLength,
    const double* viewport, size_t viewportLength);

}  // namespace vivid

#endif  // VIVID_ADVANCED_CORE_H
