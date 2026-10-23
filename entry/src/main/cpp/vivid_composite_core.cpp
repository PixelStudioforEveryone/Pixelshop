/*
 * vivid_composite_core - see vivid_composite_core.h for the bit-exactness
 * contract. Each function is a line-by-line port of one loop in WorkerCore.ets.
 */
#include "vivid_composite_core.h"

#include <cmath>

namespace vivid {
namespace {

/** `v < 0 ? 0 : v > 255 ? 255 : Math.round(v)` for a Uint8ClampedArray write. */
uint8_t clampByte(double value) {
    if (!(value > 0.0)) return 0;  // also swallows NaN
    if (value > 255.0) return 255;
    // Math.round returns 0 for every 0 < x < 0.5, including the largest double
    // below 0.5; floor(x + 0.5) would round that one up.
    if (value < 0.5) return 0;
    const double rounded = std::floor(value + 0.5);
    if (rounded > 255.0) return 255;
    return static_cast<uint8_t>(rounded);
}

/**
 * A mask sample as ArkTS reads it: out of range yields `undefined`, so
 * `undefined / 255` is NaN and every later comparison behaves like NaN. The
 * native side has to do the same rather than skip the pixel - `clampByte(NaN)`
 * is 0 on both sides, so an out-of-range sample must write 0, not keep the
 * previous value.
 */
double maskSample(const uint8_t* mask, size_t maskLength, size_t index) {
    if (index >= maskLength) return std::nan("");
    return static_cast<double>(mask[index]) / 255.0;
}

/** `blendedR` for one channel, mirroring the blend-mode branch in compositeBand. */
double blendChannel(double baseValue, double sourceValue, int32_t blendMode) {
    if (blendMode == kBlendMultiply) {
        return (baseValue * sourceValue) / 255.0;
    }
    if (blendMode == kBlendScreen) {
        return 255.0 - ((255.0 - baseValue) * (255.0 - sourceValue)) / 255.0;
    }
    if (blendMode == kBlendOverlay) {
        return baseValue < 128.0
            ? (2.0 * baseValue * sourceValue) / 255.0
            : 255.0 - (2.0 * (255.0 - baseValue) * (255.0 - sourceValue)) / 255.0;
    }
    return sourceValue;
}

}  // namespace

void matrixBand(const uint8_t* input, const float* matrix, size_t matrixLength, uint8_t* output,
    size_t start, size_t end) {
    if (matrixLength < 20 || start >= end) return;
    const double a = matrix[0];
    const double b = matrix[1];
    const double c = matrix[2];
    const double d = matrix[3];
    const double e = matrix[4];
    const double f = matrix[5];
    const double g = matrix[6];
    const double h = matrix[7];
    const double i = matrix[8];
    const double j = matrix[9];
    const double k = matrix[10];
    const double l = matrix[11];
    const double m = matrix[12];
    const double n = matrix[13];
    const double o = matrix[14];
    const double p = matrix[15];
    const double q = matrix[16];
    const double r = matrix[17];
    const double s = matrix[18];
    const double t = matrix[19];
    for (size_t index = start; index < end; index += 4) {
        const double red = static_cast<double>(input[index]);
        const double green = static_cast<double>(input[index + 1]);
        const double blue = static_cast<double>(input[index + 2]);
        const double alpha = static_cast<double>(input[index + 3]);
        output[index] = clampByte(a * red + b * green + c * blue + d * alpha + e);
        output[index + 1] = clampByte(f * red + g * green + h * blue + i * alpha + j);
        output[index + 2] = clampByte(k * red + l * green + m * blue + n * alpha + o);
        output[index + 3] = clampByte(p * red + q * green + r * blue + s * alpha + t);
    }
}

void maskBlend(uint8_t* adjusted, const uint8_t* maskAdjusted, const uint8_t* mask,
    size_t maskLength, size_t start, size_t end, size_t pixelOffset) {
    if (start >= end) return;
    for (size_t index = start; index < end; index += 4) {
        const double maskAlpha = maskSample(mask, maskLength, (index >> 2) + pixelOffset);
        if (maskAlpha <= 0.0) continue;
        for (size_t channel = 0; channel < 3; channel++) {
            const double current = static_cast<double>(adjusted[index + channel]);
            const double target = static_cast<double>(maskAdjusted[index + channel]);
            adjusted[index + channel] = clampByte(current + (target - current) * maskAlpha);
        }
    }
}

void composite(uint8_t* result, const uint8_t* base, const uint8_t* adjusted, const uint8_t* mask,
    size_t maskLength, double opacity, int32_t blendMode, size_t start, size_t end,
    size_t pixelOffset) {
    if (start >= end) return;
    for (size_t index = start; index < end; index += 4) {
        double maskAlpha = 1.0;
        if (mask != nullptr) maskAlpha = maskSample(mask, maskLength, (index >> 2) + pixelOffset);
        const double effectiveAlpha = maskAlpha * opacity;
        if (effectiveAlpha <= 0.0) continue;
        const double sourceR = static_cast<double>(adjusted[index]);
        const double sourceG = static_cast<double>(adjusted[index + 1]);
        const double sourceB = static_cast<double>(adjusted[index + 2]);
        const double baseR = static_cast<double>(base[index]);
        const double baseG = static_cast<double>(base[index + 1]);
        const double baseB = static_cast<double>(base[index + 2]);
        const double blendedR = blendChannel(baseR, sourceR, blendMode);
        const double blendedG = blendChannel(baseG, sourceG, blendMode);
        const double blendedB = blendChannel(baseB, sourceB, blendMode);
        if (effectiveAlpha >= 1.0) {
            result[index] = clampByte(blendedR);
            result[index + 1] = clampByte(blendedG);
            result[index + 2] = clampByte(blendedB);
        } else {
            result[index] = clampByte(static_cast<double>(result[index]) +
                (blendedR - static_cast<double>(result[index])) * effectiveAlpha);
            result[index + 1] = clampByte(static_cast<double>(result[index + 1]) +
                (blendedG - static_cast<double>(result[index + 1])) * effectiveAlpha);
            result[index + 2] = clampByte(static_cast<double>(result[index + 2]) +
                (blendedB - static_cast<double>(result[index + 2])) * effectiveAlpha);
        }
    }
}

}  // namespace vivid
