/*
 * Native twin of `applyAdvancedBand` (WorkerCore.ets), general path.
 *
 * Why: on a 44 MP CPU export the advanced band is the whole story. Measured on
 * the 2.8 MP zoom tile: adjust=13.9 s, of which the ArkTS per-pixel loop
 * (HSL mixer + vignette `pow`/noise + grading) is 99.6 %; matrix/mask/composite
 * (already native) total 56 ms. A 44 MP CPU export extrapolates to minutes.
 *
 * Bit-exactness rules, same as vivid_composite_core.cpp:
 *  - every intermediate is a double, in the same evaluation order as the ArkTS
 *    expression; no FMA contraction (`-ffp-contract=off`);
 *  - all LUTs are built in ArkTS and passed in: no curve fitting here;
 *  - `Math.round` on the 0..255 range is floor(x + 0.5);
 *  - the noise hash mirrors `Math.imul` with wrapping 32-bit arithmetic.
 *
 * ## Packed parameter layout (Float64Array, 70 entries)
 *   0 exposureGain                 1..3  wbRed/wbGreen/wbBlue
 *   4 vibrance                     5     parametricRefineSaturation
 *   6 gradingBlending              7     gradingBalance
 *   8..12 vignette amount, midpoint, roundness, feather, highlights
 *   13..15 grain amount, size, roughness
 *   16 width                       17 height
 *   18 pixelOffset                 19 flags (AdvancedFlag)
 *   20..25 calibration R/G/B hue+sat
 *   26..33 mixHue[8]               34..41 mixSaturation[8]
 *   42..49 mixLuminance[8]
 *   50..61 grading targets: shadows RGB, midtones RGB, highlights RGB, global RGB
 *   62..69 grading sat/lum: shadowSat, shadowLum, midSat, midLum,
 *          highlightSat, highlightLum, globalSat, globalLum
 */
#include "vivid_advanced_core.h"

#include <algorithm>
#include <cmath>

namespace vivid {
namespace {

constexpr double kLumR = 0.2126;
constexpr double kLumG = 0.7152;
constexpr double kLumB = 0.0722;
constexpr int kCurveSize = 1025;

inline double clamp01(double value) {
    return std::max(0.0, std::min(1.0, value));
}

inline double wrap01(double value) {
    // ArkTS: ((value % 1) + 1) % 1
    return std::fmod(std::fmod(value, 1.0) + 1.0, 1.0);
}

inline uint8_t clampByte(double value) {
    const double rounded = std::floor(value + 0.5);
    if (!(rounded > 0.0)) return 0;
    if (rounded > 255.0) return 255;
    return static_cast<uint8_t>(rounded);
}

inline double evalCurve(const double* samples, double value) {
    const double safe = clamp01(value);
    const double position = safe * 1024.0;
    const int low = position >= 1024.0 ? 1023 : static_cast<int>(std::floor(position));
    const double frac = position - static_cast<double>(low);
    return clamp01(samples[low] + (samples[low + 1] - samples[low]) * frac);
}

inline double sampleTable(const float* table, int size, double value) {
    const double position = clamp01(value) * static_cast<double>(size - 1);
    const int low = static_cast<int>(std::floor(position));
    if (low >= size - 1) return static_cast<double>(table[size - 1]);
    const double frac = position - static_cast<double>(low);
    return static_cast<double>(table[low]) +
        (static_cast<double>(table[low + 1]) - static_cast<double>(table[low])) * frac;
}

inline double srgbToLinear(double value) {
    const double safe = clamp01(value);
    return safe <= 0.04045 ? safe / 12.92 : std::pow((safe + 0.055) / 1.055, 2.4);
}

inline double linearToSrgb(double value) {
    const double safe = std::max(0.0, value);
    return clamp01(safe <= 0.0031308 ? safe * 12.92 : 1.055 * std::pow(safe, 1.0 / 2.4) - 0.055);
}

inline double smoothStep(double edge0, double edge1, double value) {
    const double t = clamp01((value - edge0) / std::max(0.0001, edge1 - edge0));
    return t * t * (3.0 - 2.0 * t);
}

inline double saturationOf(double red, double green, double blue) {
    const double high = std::max(red, std::max(green, blue));
    const double low = std::min(red, std::min(green, blue));
    return high <= 0.0 ? 0.0 : (high - low) / high;
}

inline double parametricRefineScale(double beforeSaturation, double afterSaturation,
    double refineSaturation) {
    const double refine = clamp01(refineSaturation);
    if (refine >= 1.0) return 1.0;
    if (!(afterSaturation > 1e-4)) return 1.0;
    if (!(afterSaturation > beforeSaturation)) return 1.0;
    const double scale = 1.0 + (refine - 1.0) * (afterSaturation - beforeSaturation) / afterSaturation;
    if (!std::isfinite(scale)) return 1.0;
    if (scale < 0.0) return 0.0;
    if (scale > 1.0) return 1.0;
    return scale;
}

inline void rgbToHsl(double red, double green, double blue, double* hue, double* saturation,
    double* lightness) {
    const double r = clamp01(red);
    const double g = clamp01(green);
    const double b = clamp01(blue);
    const double high = std::max(r, std::max(g, b));
    const double low = std::min(r, std::min(g, b));
    *lightness = (high + low) / 2.0;
    const double delta = high - low;
    if (delta == 0.0) {
        *hue = 0.0;
        *saturation = 0.0;
        return;
    }
    *saturation = delta / (1.0 - std::fabs(2.0 * *lightness - 1.0));
    double h = 0.0;
    if (high == r) h = std::fmod((g - b) / delta, 6.0);
    else if (high == g) h = (b - r) / delta + 2.0;
    else h = (r - g) / delta + 4.0;
    h /= 6.0;
    *hue = wrap01(h);
}

inline void hslToRgb(double hue, double saturation, double lightness, double* red,
    double* green, double* blue) {
    const double c = (1.0 - std::fabs(2.0 * lightness - 1.0)) * saturation;
    const double hp = hue * 6.0;
    const double x = c * (1.0 - std::fabs(std::fmod(hp, 2.0) - 1.0));
    double r1 = 0.0, g1 = 0.0, b1 = 0.0;
    if (hp < 1.0) { r1 = c; g1 = x; }
    else if (hp < 2.0) { r1 = x; g1 = c; }
    else if (hp < 3.0) { g1 = c; b1 = x; }
    else if (hp < 4.0) { g1 = x; b1 = c; }
    else if (hp < 5.0) { r1 = x; b1 = c; }
    else { r1 = c; b1 = x; }
    const double m = lightness - c / 2.0;
    *red = r1 + m;
    *green = g1 + m;
    *blue = b1 + m;
}

inline double blendedMixerValue(const double* values, double hue) {
    const double position = wrap01(hue) * 8.0;
    const int lower = static_cast<int>(std::floor(position));
    const int upper = (lower + 1) % 8;
    return values[lower] + (values[upper] - values[lower]) * (position - static_cast<double>(lower));
}

inline double applyGradeChannel(double value, double target, double saturation,
    double luminance, double weight) {
    if (weight <= 0.0 || (saturation == 0.0 && luminance == 0.0)) return value;
    const double tintAmount = clamp01(std::fabs(saturation) * weight * 0.62);
    const double direction = saturation < 0.0 ? -1.0 : 1.0;
    const double tinted = value + (target - value) * tintAmount * direction;
    const double lift = luminance * weight * 0.28;
    return clamp01(tinted + lift);
}

inline int32_t imul(int32_t left, int32_t right) {
    return static_cast<int32_t>(static_cast<uint32_t>(left) * static_cast<uint32_t>(right));
}

inline double hashNoise(int32_t x, int32_t y) {
    int32_t n = imul(x, 374761393) ^ imul(y, 668265263);
    n = imul(n ^ static_cast<int32_t>(static_cast<uint32_t>(n) >> 13), 1274126177);
    const uint32_t bits = static_cast<uint32_t>(n ^ static_cast<int32_t>(static_cast<uint32_t>(n) >> 16));
    return static_cast<double>(bits) / 4294967295.0 * 2.0 - 1.0;
}

inline double valueNoise(double x, double y) {
    const double ix = std::floor(x);
    const double iy = std::floor(y);
    const double fx = x - ix;
    const double fy = y - iy;
    const double u = fx * fx * (3.0 - 2.0 * fx);
    const double v = fy * fy * (3.0 - 2.0 * fy);
    const int32_t xi = static_cast<int32_t>(ix);
    const int32_t yi = static_cast<int32_t>(iy);
    const double a = hashNoise(xi, yi);
    const double b = hashNoise(xi + 1, yi);
    const double c = hashNoise(xi, yi + 1);
    const double d = hashNoise(xi + 1, yi + 1);
    return (a + (b - a) * u) * (1.0 - v) + (c + (d - c) * u) * v;
}

void applySpatialEffects(uint8_t* input, size_t index, const double* p, double x, double y,
    double width, double height) {
    double r = static_cast<double>(input[index]) / 255.0;
    double g = static_cast<double>(input[index + 1]) / 255.0;
    double b = static_cast<double>(input[index + 2]) / 255.0;
    const double vignetteAmount = p[8];
    if (vignetteAmount != 0.0) {
        const double roundness = std::max(-1.0, std::min(1.0, p[10]));
        const double nx = std::fabs((x + 0.5) / width * 2.0 - 1.0);
        const double ny = std::fabs((y + 0.5) / height * 2.0 - 1.0);
        const double shortSide = std::min(width, height);
        const double sx = nx * (1.0 + std::max(0.0, roundness) * (width / shortSide - 1.0));
        const double sy = ny * (1.0 + std::max(0.0, roundness) * (height / shortSide - 1.0));
        const double power = 2.0 + std::max(0.0, -roundness) * 6.0;
        // Roundness 0 (the default) is a plain ellipse: x^2 + y^2 and sqrt are
        // bit-identical to pow(x, 2) / pow(sum, 0.5) here, and removing three
        // libm calls per pixel is the difference between a 14 s and a ~5 s
        // 44 MP export. Non-zero roundness keeps the general pow path.
        const double radius = power == 2.0
            ? std::sqrt(sx * sx + sy * sy)
            : std::pow(std::pow(sx, power) + std::pow(sy, power), 1.0 / power);
        const double outer = 0.35 + clamp01(p[9]) * 0.95;
        const double inner = outer * (1.0 - 0.98 * clamp01(p[11]));
        const double t = clamp01((radius - inner) / std::max(0.005, outer - inner));
        const double baseStrength = std::min(1.0, std::fabs(vignetteAmount)) * t * t * (3.0 - 2.0 * t);
        const double luminance = clamp01(r * kLumR + g * kLumG + b * kLumB);
        const double highlightProtection = vignetteAmount < 0.0
            ? clamp01(p[12]) * smoothStep(0.52, 0.98, luminance) : 0.0;
        const double strength = baseStrength * (1.0 - highlightProtection);
        if (vignetteAmount < 0.0) {
            const double gain = std::pow(2.0, -3.0 * strength);
            r *= gain; g *= gain; b *= gain;
        } else {
            r += (1.0 - r) * strength;
            g += (1.0 - g) * strength;
            b += (1.0 - b) * strength;
        }
    }
    if (p[13] > 0.0) {
        const double scale = std::max(width, height) / 1600.0;
        const double cell = (0.8 + clamp01(p[14]) * 5.2) * scale;
        const double gx = (x + 0.5) / cell;
        const double gy = (y + 0.5) / cell;
        const double roughness = clamp01(p[15]);
        const double sample = valueNoise(gx, gy) * (1.0 - roughness * 0.45) +
            valueNoise(gx * 2.17 + 31.7, gy * 2.17 + 19.3) * roughness * 0.45;
        const double luminance = clamp01(r * kLumR + g * kLumG + b * kLumB);
        const double amplitude = clamp01(p[13]) * 0.22 *
            (0.3 + 0.7 * std::sqrt(4.0 * luminance * (1.0 - luminance)));
        const double delta = sample * amplitude;
        r += delta; g += delta; b += delta;
    }
    input[index] = clampByte(clamp01(r) * 255.0);
    input[index + 1] = clampByte(clamp01(g) * 255.0);
    input[index + 2] = clampByte(clamp01(b) * 255.0);
}

}  // namespace

bool advancedBand(uint8_t* input, size_t length, size_t start, size_t end,
    const double* params, size_t paramsLength,
    const double* curves, size_t curvesLength,
    const float* tonal, size_t tonalLength,
    const float* parametric, size_t parametricLength,
    const double* viewport, size_t viewportLength) {
    if (input == nullptr || params == nullptr || curves == nullptr) return false;
    if (paramsLength < 70 || curvesLength < static_cast<size_t>(4 * kCurveSize)) return false;
    if (start >= end || end > length || (start & 3u) != 0 || (end & 3u) != 0) return false;
    const int flags = static_cast<int>(params[19]);
    if ((flags & kTonal) != 0 && (tonal == nullptr || tonalLength < 1025)) return false;
    if ((flags & kParametric) != 0 && (parametric == nullptr || parametricLength < 256)) return false;
    const bool hasViewport = viewport != nullptr && viewportLength >= 6;

    const double* tone = curves;
    const double* redCurve = curves + kCurveSize;
    const double* greenCurve = curves + 2 * kCurveSize;
    const double* blueCurve = curves + 3 * kCurveSize;
    const double exposureGain = params[0];
    const bool whiteBalance = (flags & kWhiteBalance) != 0;
    const double wbRed = params[1], wbGreen = params[2], wbBlue = params[3];
    const bool tonalActive = (flags & kTonal) != 0;
    const double vibrance = params[4];
    const bool vibranceActive = (flags & kVibrance) != 0;
    const bool calibration = (flags & kCalibration) != 0;
    const bool mixer = (flags & kMixer) != 0;
    const bool grading = (flags & kGrading) != 0;
    const bool effects = (flags & kEffects) != 0;
    const bool parametricActive = (flags & kParametric) != 0;
    const bool refineActive = (flags & kRefine) != 0;
    const double refineSaturation = params[5];
    const double width = params[16];
    const double height = params[17];
    const size_t pixelOffset = static_cast<size_t>(params[18]);
    const double* mixHue = params + 26;
    const double* mixSaturation = params + 34;
    const double* mixLuminance = params + 42;
    const double* gradingTargets = params + 50;
    const double* gradingValues = params + 62;
    const double gradingBlend = params[6];
    const double gradingBalance = params[7];

    for (size_t index = start; index < end; index += 4) {
        double red = static_cast<double>(input[index]) / 255.0;
        double green = static_cast<double>(input[index + 1]) / 255.0;
        double blue = static_cast<double>(input[index + 2]) / 255.0;

        if (exposureGain != 1.0 || whiteBalance) {
            red = linearToSrgb(srgbToLinear(red) * exposureGain * (whiteBalance ? wbRed : 1.0));
            green = linearToSrgb(srgbToLinear(green) * exposureGain * (whiteBalance ? wbGreen : 1.0));
            blue = linearToSrgb(srgbToLinear(blue) * exposureGain * (whiteBalance ? wbBlue : 1.0));
        }

        if (tonalActive) {
            const double luminance = clamp01(red * kLumR + green * kLumG + blue * kLumB);
            const double position = luminance * 1024.0;
            const int low = std::min(1023, static_cast<int>(std::floor(position)));
            const double target = static_cast<double>(tonal[low]) +
                (static_cast<double>(tonal[low + 1]) - static_cast<double>(tonal[low])) *
                (position - static_cast<double>(low));
            if (luminance > 0.00001) {
                const double gain = target / luminance;
                red = clamp01(red * gain);
                green = clamp01(green * gain);
                blue = clamp01(blue * gain);
            } else if (target > 0.0) {
                red = target;
                green = target;
                blue = target;
            }
        }

        if (vibranceActive) {
            double hue = 0.0, saturation = 0.0, lightness = 0.0;
            rgbToHsl(red, green, blue, &hue, &saturation, &lightness);
            if (vibrance > 0.0) {
                saturation = clamp01(saturation + (1.0 - saturation) * vibrance * 0.80);
            } else {
                saturation = clamp01(saturation * (1.0 + vibrance * 0.70));
            }
            hslToRgb(hue, saturation, lightness, &red, &green, &blue);
        }

        if (calibration) {
            const double sourceRed = red;
            const double sourceGreen = green;
            const double sourceBlue = blue;
            red += params[21] * (sourceRed - (sourceGreen + sourceBlue) * 0.5) * 0.45;
            green += params[23] * (sourceGreen - (sourceRed + sourceBlue) * 0.5) * 0.45;
            blue += params[25] * (sourceBlue - (sourceRed + sourceGreen) * 0.5) * 0.45;
            green += sourceRed * params[20] * 0.14 - sourceBlue * params[24] * 0.07;
            blue -= sourceRed * params[20] * 0.14 - sourceGreen * params[22] * 0.07;
            red += sourceGreen * params[22] * 0.14 - sourceBlue * params[24] * 0.07;
        }

        if (mixer) {
            double hue = 0.0, saturation = 0.0, lightness = 0.0;
            rgbToHsl(red, green, blue, &hue, &saturation, &lightness);
            hue = wrap01(hue + blendedMixerValue(mixHue, hue) * (24.0 / 360.0));
            saturation = clamp01(saturation * (1.0 + blendedMixerValue(mixSaturation, hue)));
            lightness = clamp01(lightness + blendedMixerValue(mixLuminance, hue) * 0.32);
            hslToRgb(hue, saturation, lightness, &red, &green, &blue);
        }

        red = evalCurve(tone, red);
        green = evalCurve(tone, green);
        blue = evalCurve(tone, blue);
        red = evalCurve(redCurve, red);
        green = evalCurve(greenCurve, green);
        blue = evalCurve(blueCurve, blue);

        if (parametricActive) {
            const double beforeRed = red, beforeGreen = green, beforeBlue = blue;
            red = sampleTable(parametric, 256, red);
            green = sampleTable(parametric, 256, green);
            blue = sampleTable(parametric, 256, blue);
            if (refineActive) {
                const double beforeSaturation = saturationOf(beforeRed, beforeGreen, beforeBlue);
                const double afterSaturation = saturationOf(red, green, blue);
                const double scale = parametricRefineScale(beforeSaturation, afterSaturation,
                    refineSaturation);
                if (scale != 1.0) {
                    const double curvedLuminance = clamp01(red * kLumR + green * kLumG + blue * kLumB);
                    red = clamp01(curvedLuminance + (red - curvedLuminance) * scale);
                    green = clamp01(curvedLuminance + (green - curvedLuminance) * scale);
                    blue = clamp01(curvedLuminance + (blue - curvedLuminance) * scale);
                }
            }
        }

        if (grading) {
            const double luminance = clamp01(0.2126 * red + 0.7152 * green + 0.0722 * blue);
            const double shadowWeight = clamp01(1.0 - luminance * 2.0);
            const double highlightWeight = clamp01((luminance - 0.5) * 2.0);
            const double midtoneWeight = clamp01(1.0 - std::fabs(luminance - 0.5) * 2.0);
            const double balance = gradingBalance;
            const double shadowAdjusted = clamp01(shadowWeight *
                (1.0 - std::max(0.0, balance) * 0.65 + std::max(0.0, -balance) * 0.65));
            const double highlightAdjusted = clamp01(highlightWeight *
                (1.0 + std::max(0.0, balance) * 0.65 - std::max(0.0, -balance) * 0.65));
            const double midtoneAdjusted = clamp01(midtoneWeight *
                (0.78 + (1.0 - std::fabs(balance)) * 0.22));
            const double blend = 0.55 + gradingBlend * 0.45;

            double weight = shadowAdjusted * blend;
            red = applyGradeChannel(red, gradingTargets[0], gradingValues[0], gradingValues[1], weight);
            green = applyGradeChannel(green, gradingTargets[1], gradingValues[0], gradingValues[1], weight);
            blue = applyGradeChannel(blue, gradingTargets[2], gradingValues[0], gradingValues[1], weight);
            weight = midtoneAdjusted * blend;
            red = applyGradeChannel(red, gradingTargets[3], gradingValues[2], gradingValues[3], weight);
            green = applyGradeChannel(green, gradingTargets[4], gradingValues[2], gradingValues[3], weight);
            blue = applyGradeChannel(blue, gradingTargets[5], gradingValues[2], gradingValues[3], weight);
            weight = highlightAdjusted * blend;
            red = applyGradeChannel(red, gradingTargets[6], gradingValues[4], gradingValues[5], weight);
            green = applyGradeChannel(green, gradingTargets[7], gradingValues[4], gradingValues[5], weight);
            blue = applyGradeChannel(blue, gradingTargets[8], gradingValues[4], gradingValues[5], weight);
            weight = 0.52 * blend;
            red = applyGradeChannel(red, gradingTargets[9], gradingValues[6], gradingValues[7], weight);
            green = applyGradeChannel(green, gradingTargets[10], gradingValues[6], gradingValues[7], weight);
            blue = applyGradeChannel(blue, gradingTargets[11], gradingValues[6], gradingValues[7], weight);
        }

        input[index] = clampByte(red * 255.0);
        input[index + 1] = clampByte(green * 255.0);
        input[index + 2] = clampByte(blue * 255.0);
        if (effects) {
            const size_t absolutePixel = index / 4 + pixelOffset;
            double x = static_cast<double>(absolutePixel % static_cast<size_t>(width));
            double y = std::floor(static_cast<double>(absolutePixel) / width);
            if (hasViewport) {
                x = viewport[0] + (x + 0.5) * viewport[2] - 0.5;
                y = viewport[1] + (y + 0.5) * viewport[3] - 0.5;
            }
            applySpatialEffects(input, index, params, x, y,
                hasViewport ? viewport[4] : width, hasViewport ? viewport[5] : height);
        }
    }
    return true;
}

}  // namespace vivid
