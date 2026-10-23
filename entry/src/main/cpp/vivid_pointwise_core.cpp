/*
 * vivid_pointwise_core - see vivid_pointwise_core.h.
 *
 * Bit-exactness notes (why this is not "just close"):
 *  - every intermediate is a double and the expression order follows the ArkTS
 *    reference line by line;
 *  - LUT interpolation never clamps between stacked tables, only when the final
 *    pixel is written, exactly like WorkerCore.applyLutStack;
 *  - point colour pre-computes only the per-sample sanitisation that the
 *    reference recomputes per pixel (same pure functions, same values);
 *  - OkLCh uses the published Oklab matrices verbatim and the same 24-step
 *    gamut bisection, so the native and ArkTS paths ask the same questions in
 *    the same order.
 */
#include "vivid_pointwise_core.h"

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace vivid {
namespace pointwise {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kAchromaticEpsilon = 1e-6;
constexpr int32_t kGamutIterations = 24;
constexpr double kSrgbBreak = 0.0031308;
constexpr double kSrgbSlope = 12.92;
constexpr double kSrgbAlpha = 1.055;
constexpr double kSrgbOffset = 0.055;
constexpr double kSrgbGamma = 2.4;

/** Math.max(0, Math.min(1, v)) with NaN preserved, matching LUT's clamp01. */
inline double clamp01KeepNan(double v) {
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

/** clamp01 where NaN degrades to 0 (PointColorCore / OkLChCore). */
inline double clamp01(double v) {
    if (!(v > 0.0)) return 0.0;
    return v > 1.0 ? 1.0 : v;
}

/** JS Math.round for the non-negative values written into pixels. */
inline double jsRound(double v) {
    return std::floor(v + 0.5);
}

inline uint8_t clampByte(double v) {
    const double rounded = jsRound(v);
    if (!(rounded > 0.0)) return 0;
    if (rounded > 255.0) return 255;
    return static_cast<uint8_t>(rounded);
}

/* ------------------------------ LUT stack ------------------------------ */

struct LutEntry {
    int32_t size;
    double amount;
    double minR, minG, minB;
    double maxR, maxG, maxB;
    int32_t valueOffset;
};

/**
 * The single validator shared by `lutStack` and `lutStackRejectReason`. Returns
 * kLutStackOk and fills `entries` when every entry is usable; otherwise returns
 * the first failing field's code without touching `entries`.
 */
int32_t parseLutEntries(const double* values, int32_t valueCount, const double* meta,
                        int32_t lutCount, LutEntry* entries) {
    if (lutCount < 0 || lutCount > 64) return kLutStackBadLutCount;
    if (lutCount == 0) return kLutStackOk;
    // Check the length before the pointers: an empty table is reported as a
    // short value array (4), not as a missing pointer (3), because that is the
    // field the caller actually got wrong.
    if (valueCount < lutCount * 3) return kLutStackValuesTooShort;
    if (values == nullptr || meta == nullptr) return kLutStackNullArrays;

    for (int32_t index = 0; index < lutCount; index++) {
        const double* raw = meta + index * kLutMetaStride;
        const double sizeValue = raw[0];
        if (!(sizeValue >= 2.0 && sizeValue <= 128.0)) return kLutStackBadSize;
        const int32_t size = static_cast<int32_t>(sizeValue);
        if (static_cast<double>(size) != sizeValue) return kLutStackBadSize;
        if (!(raw[1] >= 0.0)) return kLutStackBadIntensity;  // NaN / negative intensity is invalid
        if (!std::isfinite(raw[2]) || !std::isfinite(raw[3]) || !std::isfinite(raw[4])) {
            return kLutStackBadDomain;
        }
        if (!std::isfinite(raw[5]) || !std::isfinite(raw[6]) || !std::isfinite(raw[7])) {
            return kLutStackBadDomain;
        }
        if (!(raw[5] > raw[2]) || !(raw[6] > raw[3]) || !(raw[7] > raw[4])) {
            return kLutStackBadDomainOrder;
        }
        const double offsetValue = raw[8];
        if (!(offsetValue >= 0.0)) return kLutStackBadOffset;
        const int32_t offset = static_cast<int32_t>(offsetValue);
        if (static_cast<double>(offset) != offsetValue) return kLutStackBadOffset;
        const int64_t needed = static_cast<int64_t>(size) * size * size * 3;
        if (static_cast<int64_t>(offset) + needed > static_cast<int64_t>(valueCount)) {
            return kLutStackTableOutOfRange;
        }
        entries[index] = LutEntry{size, clamp01KeepNan(raw[1]), raw[2], raw[3], raw[4],
                                  raw[5], raw[6], raw[7], offset};
    }
    return kLutStackOk;
}

inline void sampleLut(const LutEntry& lut, const double* values, double red, double green, double blue,
                      double* result) {
    const double rx = clamp01KeepNan((red - lut.minR) / (lut.maxR - lut.minR)) * (lut.size - 1);
    const double gx = clamp01KeepNan((green - lut.minG) / (lut.maxG - lut.minG)) * (lut.size - 1);
    const double bx = clamp01KeepNan((blue - lut.minB) / (lut.maxB - lut.minB)) * (lut.size - 1);
    const int32_t r0 = static_cast<int32_t>(std::floor(rx));
    const int32_t g0 = static_cast<int32_t>(std::floor(gx));
    const int32_t b0 = static_cast<int32_t>(std::floor(bx));
    const int32_t r1 = (r0 + 1 < lut.size) ? r0 + 1 : lut.size - 1;
    const int32_t g1 = (g0 + 1 < lut.size) ? g0 + 1 : lut.size - 1;
    const int32_t b1 = (b0 + 1 < lut.size) ? b0 + 1 : lut.size - 1;
    const double fr = rx - r0;
    const double fg = gx - g0;
    const double fb = bx - b0;
    const int32_t size = lut.size;
    const int32_t i000 = lut.valueOffset + ((b0 * size + g0) * size + r0) * 3;
    const int32_t i100 = lut.valueOffset + ((b0 * size + g0) * size + r1) * 3;
    const int32_t i010 = lut.valueOffset + ((b0 * size + g1) * size + r0) * 3;
    const int32_t i110 = lut.valueOffset + ((b0 * size + g1) * size + r1) * 3;
    const int32_t i001 = lut.valueOffset + ((b1 * size + g0) * size + r0) * 3;
    const int32_t i101 = lut.valueOffset + ((b1 * size + g0) * size + r1) * 3;
    const int32_t i011 = lut.valueOffset + ((b1 * size + g1) * size + r0) * 3;
    const int32_t i111 = lut.valueOffset + ((b1 * size + g1) * size + r1) * 3;
    for (int32_t channel = 0; channel < 3; channel++) {
        const double c000 = values[i000 + channel];
        const double c100 = values[i100 + channel];
        const double c010 = values[i010 + channel];
        const double c110 = values[i110 + channel];
        const double c001 = values[i001 + channel];
        const double c101 = values[i101 + channel];
        const double c011 = values[i011 + channel];
        const double c111 = values[i111 + channel];
        const double c00 = c000 + (c100 - c000) * fr;
        const double c10 = c010 + (c110 - c010) * fr;
        const double c01 = c001 + (c101 - c001) * fr;
        const double c11 = c011 + (c111 - c011) * fr;
        const double c0 = c00 + (c10 - c00) * fg;
        const double c1 = c01 + (c11 - c01) * fg;
        result[channel] = c0 + (c1 - c0) * fb;
    }
}

}  // namespace

int32_t lutStackRejectReason(const double* values, int32_t valueCount,
                             const double* meta, int32_t lutCount) {
    LutEntry entries[64];
    return parseLutEntries(values, valueCount, meta, lutCount, entries);
}

bool lutStack(uint8_t* rgba, int32_t pixelCount, const double* values, int32_t valueCount,
              const double* meta, int32_t lutCount) {
    if (rgba == nullptr) return false;
    if (pixelCount < 0) return false;
    LutEntry entries[64];
    if (parseLutEntries(values, valueCount, meta, lutCount, entries) != kLutStackOk) return false;
    if (lutCount == 0) return true;

    for (int32_t pixel = 0; pixel < pixelCount; pixel++) {
        const int32_t base = pixel * 4;
        double red = rgba[base] / 255.0;
        double green = rgba[base + 1] / 255.0;
        double blue = rgba[base + 2] / 255.0;
        for (int32_t index = 0; index < lutCount; index++) {
            const LutEntry& lut = entries[index];
            double mapped[3];
            sampleLut(lut, values, red, green, blue, mapped);
            const double amount = lut.amount;
            red += (mapped[0] - red) * amount;
            green += (mapped[1] - green) * amount;
            blue += (mapped[2] - blue) * amount;
        }
        rgba[base] = clampByte(red * 255.0);
        rgba[base + 1] = clampByte(green * 255.0);
        rgba[base + 2] = clampByte(blue * 255.0);
    }
    return true;
}

/* ----------------------------- point colour ---------------------------- */

namespace {

struct PointSample {
    double hue;
    double saturation;
    double luminance;
    double hueShift;
    double saturationShift;
    double luminanceShift;
    double hueRange;
    double saturationRange;
    double luminanceRange;
    bool active;
};

inline double pointWrap01(double input) {
    if (!std::isfinite(input)) return 0.0;
    double wrapped = input - std::floor(input);
    if (!std::isfinite(wrapped) || wrapped < 0.0) return 0.0;
    if (wrapped >= 1.0) return 0.0;
    return wrapped;
}

inline double clampSigned(double input) {
    if (!std::isfinite(input)) return 0.0;
    if (input < -1.0) return -1.0;
    if (input > 1.0) return 1.0;
    return input;
}

inline double hueDistance(double first, double second) {
    const double a = pointWrap01(first);
    const double b = pointWrap01(second);
    double raw = a - b;
    raw = raw - std::floor(raw + 0.5);
    if (!std::isfinite(raw)) return 0.0;
    const double distance = raw < 0.0 ? -raw : raw;
    return distance > 0.5 ? 0.5 : distance;
}

inline double axisWeight(double distance, double range) {
    const double d = distance < 0.0 ? -distance : distance;
    if (!std::isfinite(d)) return 0.0;
    if (d <= 0.0) return 1.0;
    const double r = clamp01(range);
    if (r <= 0.0) return 0.0;
    if (d >= r) return 0.0;
    const double t = d / r;
    const double weight = 1.0 - t * t * (3.0 - 2.0 * t);
    if (!std::isfinite(weight) || weight < 0.0) return 0.0;
    return weight > 1.0 ? 1.0 : weight;
}

inline double scaleSaturation(double current, double factor) {
    const double s = clamp01(current);
    if (!std::isfinite(factor) || factor <= 0.0) return 0.0;
    if (factor == 1.0) return s;
    if (factor > 1.0) {
        const double rest = 1.0 - s;
        if (rest <= 0.0) return 1.0;
        const double boosted = 1.0 - std::pow(rest, factor);
        if (!std::isfinite(boosted) || boosted < 0.0) return 0.0;
        return boosted > 1.0 ? 1.0 : boosted;
    }
    return clamp01(s * factor);
}

inline double pointWeight(const PointSample& sample, double h, double s, double l) {
    const double pixelSaturation = clamp01(s);
    const double pixelLuminance = clamp01(l);
    double hueAxis;
    if (sample.saturation <= 1e-4) {
        hueAxis = 1.0;
    } else if (pixelSaturation <= 1e-4) {
        hueAxis = 0.0;
    } else {
        hueAxis = axisWeight(hueDistance(h, sample.hue), sample.hueRange);
    }
    const double saturationAxis = axisWeight(pixelSaturation - sample.saturation, sample.saturationRange);
    const double luminanceAxis = axisWeight(pixelLuminance - sample.luminance, sample.luminanceRange);
    const double weight = hueAxis * saturationAxis * luminanceAxis;
    if (!std::isfinite(weight) || weight < 0.0) return 0.0;
    return weight > 1.0 ? 1.0 : weight;
}

inline void rgbToHsl(double red, double green, double blue, double* out) {
    const double r = clamp01(red);
    const double g = clamp01(green);
    const double b = clamp01(blue);
    const double high = std::max(r, std::max(g, b));
    const double low = std::min(r, std::min(g, b));
    const double lightness = (high + low) * 0.5;
    const double chroma = high - low;
    double hue = 0.0;
    double saturation = 0.0;
    if (chroma > 0.0) {
        if (lightness > 0.5) {
            saturation = chroma / (2.0 - high - low);
        } else {
            saturation = chroma / (high + low);
        }
        if (high == r) {
            hue = ((g - b) / chroma + (g < b ? 6.0 : 0.0)) / 6.0;
        } else if (high == g) {
            hue = ((b - r) / chroma + 2.0) / 6.0;
        } else {
            hue = ((r - g) / chroma + 4.0) / 6.0;
        }
    }
    out[0] = pointWrap01(hue);
    out[1] = clamp01(saturation);
    out[2] = clamp01(lightness);
}

inline double hueToChannel(double p, double q, double t) {
    double position = t;
    if (position < 0.0) position += 1.0;
    if (position > 1.0) position -= 1.0;
    if (position < 1.0 / 6.0) return p + (q - p) * 6.0 * position;
    if (position < 1.0 / 2.0) return q;
    if (position < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - position) * 6.0;
    return p;
}

inline void hslToRgb(double h, double s, double l, double* out) {
    const double hue = pointWrap01(h);
    const double saturation = clamp01(s);
    const double lightness = clamp01(l);
    if (saturation <= 0.0) {
        out[0] = lightness;
        out[1] = lightness;
        out[2] = lightness;
        return;
    }
    const double q = lightness <= 0.5 ? lightness * (1.0 + saturation)
                                      : lightness + saturation - lightness * saturation;
    const double p = 2.0 * lightness - q;
    out[0] = clamp01(hueToChannel(p, q, hue + 1.0 / 3.0));
    out[1] = clamp01(hueToChannel(p, q, hue));
    out[2] = clamp01(hueToChannel(p, q, hue - 1.0 / 3.0));
}

inline void applyPointColor(double red, double green, double blue, const PointSample* samples,
                            int32_t count, double* out) {
    const double baseRed = clamp01(red);
    const double baseGreen = clamp01(green);
    const double baseBlue = clamp01(blue);
    rgbToHsl(baseRed, baseGreen, baseBlue, out);
    double hue = out[0];
    double saturation = out[1];
    double lightness = out[2];
    for (int32_t index = 0; index < count; index++) {
        const PointSample& sample = samples[index];
        if (!sample.active) continue;
        const double weight = pointWeight(sample, hue, saturation, lightness);
        if (!(weight > 0.0)) continue;
        if (sample.hueShift != 0.0) {
            hue = pointWrap01(hue + sample.hueShift * (30.0 / 360.0) * weight);
        }
        if (sample.saturationShift != 0.0) {
            saturation = scaleSaturation(saturation, 1.0 + sample.saturationShift * weight);
        }
        if (sample.luminanceShift != 0.0) {
            lightness = clamp01(lightness + sample.luminanceShift * 0.5 * weight);
        }
    }
    hslToRgb(hue, saturation, lightness, out);
    out[0] = clamp01(out[0]);
    out[1] = clamp01(out[1]);
    out[2] = clamp01(out[2]);
}

}  // namespace

bool pointColor(uint8_t* rgba, int32_t pixelCount, const double* samples, int32_t sampleCount) {
    if (rgba == nullptr) return false;
    if (pixelCount < 0 || sampleCount < 0 || sampleCount > 8) return false;
    if (sampleCount == 0) return true;
    if (samples == nullptr) return false;

    PointSample parsed[8];
    bool anyActive = false;
    for (int32_t index = 0; index < sampleCount; index++) {
        const double* raw = samples + index * kPointColorStride;
        for (int32_t field = 0; field < kPointColorStride; field++) {
            if (!std::isfinite(raw[field])) return false;
        }
        PointSample& sample = parsed[index];
        sample.hue = pointWrap01(raw[0]);
        sample.saturation = clamp01(raw[1]);
        sample.luminance = clamp01(raw[2]);
        sample.hueShift = clampSigned(raw[3]);
        sample.saturationShift = clampSigned(raw[4]);
        sample.luminanceShift = clampSigned(raw[5]);
        sample.hueRange = raw[6];
        sample.saturationRange = raw[7];
        sample.luminanceRange = raw[8];
        sample.active = !(sample.hueShift == 0.0 && sample.saturationShift == 0.0 &&
                          sample.luminanceShift == 0.0);
        anyActive = anyActive || sample.active;
    }
    if (!anyActive) return true;  // identity: pixels untouched, matching the reference

    for (int32_t pixel = 0; pixel < pixelCount; pixel++) {
        const int32_t base = pixel * 4;
        double out[3];
        applyPointColor(rgba[base] / 255.0, rgba[base + 1] / 255.0, rgba[base + 2] / 255.0,
                        parsed, sampleCount, out);
        rgba[base] = clampByte(out[0] * 255.0);
        rgba[base + 1] = clampByte(out[1] * 255.0);
        rgba[base + 2] = clampByte(out[2] * 255.0);
    }
    return true;
}

/* --------------------------------- OkLCh -------------------------------- */

namespace {

inline double finiteOr(double value, double fallback) {
    return std::isfinite(value) ? value : fallback;
}

inline double srgbToLinear(double c) {
    const double v = c < 0.0 ? 0.0 : (c > 1.0 ? 1.0 : c);
    return v <= 0.04045 ? v / kSrgbSlope : std::pow((v + kSrgbOffset) / kSrgbAlpha, kSrgbGamma);
}

inline double linearToSrgb(double c) {
    const double v = c < 0.0 ? 0.0 : (c > 1.0 ? 1.0 : c);
    return v <= kSrgbBreak ? v * kSrgbSlope
                           : kSrgbAlpha * std::pow(v, 1.0 / kSrgbGamma) - kSrgbOffset;
}

inline void linearRgbToOklab(double red, double green, double blue, double* out) {
    const double l = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue;
    const double m = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue;
    const double s = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue;
    const double lc = std::cbrt(l);
    const double mc = std::cbrt(m);
    const double sc = std::cbrt(s);
    out[0] = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc;
    out[1] = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc;
    out[2] = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc;
}

inline void oklabToLinearRgb(double L, double a, double b, double* out) {
    const double lc = L + 0.3963377774 * a + 0.2158037573 * b;
    const double mc = L - 0.1055613458 * a - 0.0638541728 * b;
    const double sc = L - 0.0894841775 * a - 1.2914855480 * b;
    const double l = lc * lc * lc;
    const double m = mc * mc * mc;
    const double s = sc * sc * sc;
    out[0] = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    out[1] = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    out[2] = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
}

inline void oklabToOklch(double L, double a, double b, double* out) {
    const double C = std::sqrt(a * a + b * b);
    double h = std::atan2(b, a) / (kPi * 2.0);
    h = h - std::floor(h);
    out[0] = L;
    out[1] = C;
    out[2] = h;
}

inline void oklchToOklab(double L, double C, double h, double* out) {
    const double angle = h * kPi * 2.0;
    out[0] = L;
    out[1] = std::cos(angle) * C;
    out[2] = std::sin(angle) * C;
}

inline bool oklchInGamut(double L, double C, double h) {
    double lab[3];
    oklchToOklab(L, C, h, lab);
    double rgb[3];
    oklabToLinearRgb(lab[0], lab[1], lab[2], rgb);
    for (int32_t index = 0; index < 3; index++) {
        if (rgb[index] < -kAchromaticEpsilon || rgb[index] > 1.0 + kAchromaticEpsilon) return false;
    }
    return true;
}

inline double gamutChromaLimit(double L, double C, double h) {
    const double target = C < 0.0 ? 0.0 : C;
    if (oklchInGamut(L, target, h)) return target;
    double low = 0.0;
    double high = target;
    for (int32_t index = 0; index < kGamutIterations; index++) {
        const double mid = (low + high) / 2.0;
        if (oklchInGamut(L, mid, h)) low = mid; else high = mid;
    }
    return low;
}

inline void applyOklch(double red, double green, double blue, const double* params, double* out) {
    const double offsetL = finiteOr(params[0], 0.0);
    const double offsetC = finiteOr(params[1], 0.0);
    const double offsetH = finiteOr(params[2], 0.0);
    double lab[3];
    linearRgbToOklab(srgbToLinear(red), srgbToLinear(green), srgbToLinear(blue), lab);
    double lch[3];
    oklabToOklch(lab[0], lab[1], lab[2], lch);
    const double L = clamp01(lch[0] + offsetL);
    if (lch[1] <= kAchromaticEpsilon) {
        const double neutralL = clamp01(std::cbrt(srgbToLinear(red)) + offsetL);
        const double grey = clamp01(linearToSrgb(neutralL * neutralL * neutralL));
        out[0] = grey;
        out[1] = grey;
        out[2] = grey;
        return;
    }
    double hue = lch[2] + offsetH;
    hue = hue - std::floor(hue);
    const double scaled = lch[1] * (1.0 + offsetC);
    const double requested = scaled < 0.0 ? 0.0 : scaled;
    const double C = gamutChromaLimit(L, requested, hue);
    double labOut[3];
    oklchToOklab(L, C, hue, labOut);
    double rgb[3];
    oklabToLinearRgb(labOut[0], labOut[1], labOut[2], rgb);
    out[0] = clamp01(linearToSrgb(rgb[0]));
    out[1] = clamp01(linearToSrgb(rgb[1]));
    out[2] = clamp01(linearToSrgb(rgb[2]));
}

}  // namespace

bool oklch(uint8_t* rgba, int32_t pixelCount, const double* params) {
    if (rgba == nullptr || params == nullptr) return false;
    if (pixelCount < 0) return false;
    for (int32_t field = 0; field < kOkLChStride; field++) {
        if (!std::isfinite(params[field])) return false;
    }
    if (params[0] == 0.0 && params[1] == 0.0 && params[2] == 0.0) return true;

    for (int32_t pixel = 0; pixel < pixelCount; pixel++) {
        const int32_t base = pixel * 4;
        double out[3];
        applyOklch(rgba[base] / 255.0, rgba[base + 1] / 255.0, rgba[base + 2] / 255.0, params, out);
        rgba[base] = clampByte(out[0] * 255.0);
        rgba[base + 1] = clampByte(out[1] * 255.0);
        rgba[base + 2] = clampByte(out[2] * 255.0);
    }
    return true;
}

}  // namespace pointwise
}  // namespace vivid
