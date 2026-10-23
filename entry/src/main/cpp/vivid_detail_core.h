/*
 * vivid_detail_core - native twin of the ArkTS detail stage.
 *
 * `entry/src/main/ets/edit/engine/LocalContrastCore.ets` (`applyLocalContrast`)
 * is the reference implementation and stays in the code base as the fallback.
 * The ArkTS version measured 725 ms per 512x341 preview frame on the device
 * (and 2691 ms before the box-blur rewrite): that cost is ArkTS interpreter
 * overhead, not arithmetic, so the only way to interactive speed is to run the
 * same pipeline natively.
 *
 * ## Bit-exactness contract
 *
 * The ArkTS caller may run either implementation, so both must emit identical
 * bytes. Everything below follows these rules:
 *
 *  - every working plane is `float` (ArkTS `Float32Array`); every accumulator,
 *    expression and intermediate that ArkTS holds in a plain number is `double`.
 *    Mixing them up is the single easiest way to lose byte parity, so the type
 *    of every temporary mirrors the ArkTS declaration exactly;
 *  - expressions are written in the same associativity as the ArkTS source, and
 *    the module is compiled with `-ffp-contract=off` so no FMA fuses a multiply
 *    and an add that ArkTS rounds separately;
 *  - `Math.round(x)` for the non-negative values in this pipeline is
 *    `floor(x + 0.5)`; C++ `std::round` rounds half away from zero, which is the
 *    same for positives but is NOT used here so the two sides cannot drift if a
 *    negative ever appears. `lroundf` is avoided for the same reason;
 *  - the box radius solved from sigma uses `std::sqrt` (IEEE-correctly rounded,
 *    identical to `Math.sqrt`);
 *  - two values that ArkTS computes with engine-specific math are precomputed
 *    in ArkTS and passed in: the sharpen box radius comes from
 *    `sharpenRadiusPixels` (which uses `Math.pow`), and `veil` comes from
 *    `0.3 * Math.pow(|dehaze|, 1.3)` in the dehaze stage. `Math.tanh` in the
 *    sharpen stage has no ArkTS-side precomputation, so it is the one
 *    transcendental evaluated here; it is verified byte-for-byte by
 *    tools/check_detail_native_parity.cjs and on-device by the wrapper's
 *    one-shot self check.
 *
 * This header has no NAPI dependency, so the same translation unit is compiled
 * both into libvivid_detail.so and into the host probe the parity test runs.
 */
#ifndef VIVID_DETAIL_CORE_H
#define VIVID_DETAIL_CORE_H

#include <cstddef>
#include <cstdint>

namespace vivid {

/** Everything `applyLocalContrast` derives before it runs a stage. */
struct DetailParams {
    int width = 0;
    int height = 0;
    /** Radius, in pixels, of the texture guided filter (`textureRadius`). */
    int radiusTexture = 1;
    /** Radius, in pixels, of the clarity guided filter (`clarityRadius`). */
    int radiusClarity = 2;
    /** Box sigma of the sharpen low-pass (`sharpenRadiusPixels`). */
    int radiusSharpen = 1;
    /** Slider positions, -1..1 / 0..1, exactly as the caller holds them. */
    double texture = 0.0;
    double clarity = 0.0;
    double dehaze = 0.0;
    /** `0.3 * pow(|dehaze|, 1.3)`, precomputed in ArkTS (see the header comment). */
    double veil = 0.0;
    double sharpenAmount = 0.0;
    double sharpenDetail = 0.0;
    double sharpenMasking = 0.0;
    /**
     * Whole-frame haze colour. When `hasHaze` is set the dehaze stage uses it
     * verbatim instead of estimating one from this frame, which is what keeps a
     * magnified tile identical to the same region of a whole-frame render.
     */
    bool hasHaze = false;
    double hazeRed = 1.0;
    double hazeGreen = 1.0;
    double hazeBlue = 1.0;
};

/**
 * Apply the four spatial stages to a copy of `src`.
 *
 * `dst` must hold `width * height * 4` bytes; it receives the result and may
 * not alias `src`. `src` may be shorter than `width * height * 4`, in which case
 * the missing bytes stay zero - the same transparent-black degradation
 * `applyLocalContrast` documents. `src` is never written to.
 *
 * The alpha byte of every pixel is copied through untouched, exactly like the
 * ArkTS function.
 */
void applyDetail(const uint8_t* src, size_t srcLength, uint8_t* dst, const DetailParams& params);

/**
 * Airlight estimate: alpha-weighted mean RGB of the brightest 1% of pixels by
 * Rec.709 luminance, mirroring `dehazeHazeColor`. Returns false when
 * the frame carries no usable estimate (all transparent), which the caller
 * treats as "leave the frame alone".
 */
bool hazeColor(const uint8_t* rgba, int width, int height, double out[3]);

/** True when every stage is at its no-op value, mirroring `localContrastIsIdentity`. */
bool detailIsIdentity(const DetailParams& params);

}  // namespace vivid

#endif  // VIVID_DETAIL_CORE_H
