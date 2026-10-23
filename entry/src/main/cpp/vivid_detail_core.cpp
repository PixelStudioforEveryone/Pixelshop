/*
 * vivid_detail_core - see vivid_detail_core.h for the bit-exactness contract.
 *
 * The structure below is a line-by-line port of LocalContrastCore.ets in the
 * same order, so a reader can diff the two files stage by stage:
 *
 *   applyDetail
 *     -> luminancePlane
 *     -> applyTextureClarity   (guided filter fine/coarse, Compositor's
 *                               adjust_camera_raw_effects)
 *     -> applyDehazeCompositor (hazeColor estimate + positive/negative branches)
 *     -> applySharpen          (unsharp mask + 3x3 high-pass + Sobel mask)
 *
 * Dead ArkTS code (applyTwoBandContrast, applyDehaze, minFilterPlane,
 * slidingWindowMinimum) is deliberately NOT ported: nothing calls it, so porting
 * it would only add an untested second implementation of the same idea.
 */
#include "vivid_detail_core.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <vector>

namespace vivid {
namespace {

// --- constants, copied verbatim from LocalContrastCore.ets -------------------
constexpr double kGuidedEpsilon = 0.01;
constexpr double kTexturePositiveGain = 0.6;
constexpr double kTextureNegativeGain = 0.5;
constexpr double kClarityPositiveGain = 0.85;
constexpr double kClarityNegativeGain = 0.5;
constexpr double kReferenceContrast = 0.25;
constexpr double kMaxAdjustment = 0.22;
constexpr double kSharpenMaxAdjustment = 0.35;
constexpr double kLumaFloor = 0.0004;
constexpr double kLumaR = 0.2126;
constexpr double kLumaG = 0.7152;
constexpr double kLumaB = 0.0722;

/** `clampMagnitude`: non-finite becomes 0, then clamp to +/-limit. */
double clampMagnitude(double input, double limit) {
    if (!std::isfinite(input)) return 0.0;
    return std::max(-limit, std::min(limit, input));
}

/** `clampUnit`: non-finite becomes 0, then clamp to 0..1. */
double clampUnit(double input) {
    if (!std::isfinite(input)) return 0.0;
    return std::max(0.0, std::min(1.0, input));
}

/**
 * `x < 0 ? 0 : (x > 255 ? 255 : Math.round(x))`, the exact write the ArkTS
 * pipeline performs through a Uint8ClampedArray. `Math.round` of a
 * non-negative value is `floor(x + 0.5)`.
 */
uint8_t clampRoundedByte(double value) {
    if (!(value > 0.0)) return 0;  // also swallows NaN
    if (value > 255.0) return 255;
    // `Math.round` returns 0 for every 0 < x < 0.5, including the largest
    // double below 0.5 (0.49999999999999994), where `floor(x + 0.5)` would
    // round the sum up to 1.0. The spec has that exception and V8 implements
    // it, so it is reproduced here rather than left as a latent 1-LSB flip.
    if (value < 0.5) return 0;
    const double rounded = std::floor(value + 0.5);
    if (rounded > 255.0) return 255;
    return static_cast<uint8_t>(rounded);
}

/** `Math.round(x)` for the non-negative arguments used here. */
int roundNonNegative(double value) {
    if (!(value >= 0.5)) return 0;
    const double rounded = std::floor(value + 0.5);
    if (rounded > 2147483647.0) return 2147483647;
    return static_cast<int>(rounded);
}

/**
 * Horizontal box pass with edge replication, a running sum and the three-span
 * split (leading / interior / trailing). Mirrors `boxBlurRow`.
 */
void boxBlurRow(const float* source, size_t rowStart, int frameWidth, int radius, int span,
    float* target, size_t targetStart) {
    const int last = frameWidth - 1;
    if (last < 0) return;
    // Division by `span`, never multiplication by its reciprocal: the rounded
    // reciprocal is one ULP off and that difference survives into the float32
    // plane and flips rounding on a few output pixels at large radii.
    //
    // Every operand below is widened to double before it is combined: ArkTS
    // reads a Float32Array element as a double, so `a - b` on two samples is a
    // double subtraction there, while doing it in `float` here would round the
    // difference first and change the running sum by an ulp (measured: maxCh=1
    // on a clarity-only frame).
    double cumulative = static_cast<double>(source[rowStart]) * radius;
    const int reach = radius < last ? radius : last;
    for (int column = 0; column <= reach; column++) {
        cumulative += static_cast<double>(source[rowStart + column]);
    }
    if (last < radius) {
        cumulative += static_cast<double>(source[rowStart + last]) * (radius - last);
    }
    const int leading = radius < frameWidth ? radius : frameWidth;
    for (int column = 0; column < leading; column++) {
        target[targetStart + column] = static_cast<float>(cumulative / span);
        int entering = column + radius + 1;
        if (entering > last) entering = last;
        cumulative += static_cast<double>(source[rowStart + entering]) -
            static_cast<double>(source[rowStart]);
    }
    const int interiorEnd = frameWidth - radius - 1;
    for (int column = leading; column < interiorEnd; column++) {
        target[targetStart + column] = static_cast<float>(cumulative / span);
        cumulative += static_cast<double>(source[rowStart + column + radius + 1]) -
            static_cast<double>(source[rowStart + column - radius]);
    }
    const int trailing = interiorEnd > leading ? interiorEnd : leading;
    for (int column = trailing; column < frameWidth; column++) {
        target[targetStart + column] = static_cast<float>(cumulative / span);
        cumulative += static_cast<double>(source[rowStart + last]) -
            static_cast<double>(source[rowStart + column - radius]);
    }
}

/**
 * The three horizontal box passes fused per row.
 *
 * Same reasoning as `boxBlurVerticalTriple`: three separate passes write two
 * whole intermediate planes that nothing else ever reads. Each row is an
 * independent running sum from x=0, so the two intermediate rows can live in
 * per-thread scratch rows and the only plane write is the final H3 row.
 *
 * The arithmetic is the serial one: `boxBlurRow` still narrows every running
 * sum step to float32, now into a row buffer instead of a plane, and the next
 * pass reads exactly those float32 values.
 */
void boxBlurHorizontalTriple(const float* source, float* destination, int frameWidth,
    int frameHeight, int radius, int span) {
    #pragma omp parallel if(frameHeight > 8)
    {
        std::vector<float> rowA(static_cast<size_t>(frameWidth));
        std::vector<float> rowB(static_cast<size_t>(frameWidth));
        #pragma omp for schedule(static)
        for (int y = 0; y < frameHeight; y++) {
            const size_t rowStart = static_cast<size_t>(y) * frameWidth;
            boxBlurRow(source, rowStart, frameWidth, radius, span, rowA.data(), 0);
            boxBlurRow(rowA.data(), 0, frameWidth, radius, span, rowB.data(), 0);
            boxBlurRow(rowB.data(), 0, frameWidth, radius, span, destination, rowStart);
        }
    }
}

/**
 * The three vertical box passes fused into one streaming pass.
 *
 * Three separate passes touch a whole float32 plane six times (read+write per
 * pass). At 44 MP a plane is 176.7 MB, so one blur moves ~1.06 GB through
 * memory even though the data never changes shape. The passes are a pipeline:
 * row y of V2 only needs row y of V1, and row y of V3 only needs row y of V2.
 * Producing rows in the order V1(y+radius+1), V2(y+radius+1), V3(y) keeps just
 * the rows the next stage still needs, so neither intermediate plane is ever
 * materialised.
 *
 * Arithmetic is unchanged: every stage keeps the float32 running cell the ArkTS
 * plane holds (so it narrows on every update), uses the same add-then-subtract
 * order, and initialises with edge replication, including the `last < radius`
 * tail term. Columns stay independent, so the column tiles are unchanged and
 * each tile keeps its own cells and row rings.
 */
void boxBlurVerticalTriple(const float* source, float* destination, int frameWidth,
    int frameHeight, int radius, int span) {
    const int last = frameHeight - 1;
    if (last < 0) return;
    const int reach = radius < last ? radius : last;
    // Row y reads its source rows [y-radius, y+radius+1]; the ring only needs to
    // hold that window (plus one slot so the next write never lands on a row
    // that is still needed).
    const int depth = 2 * radius + 2;
    const int tileCount = frameWidth >= 512 ? 8 : 1;
    const int tileWidth = (frameWidth + tileCount - 1) / tileCount;
    #pragma omp parallel for schedule(static) if(tileCount > 1)
    for (int tile = 0; tile < tileCount; tile++) {
        const int firstColumn = tile * tileWidth;
        const int lastColumn = std::min(frameWidth, firstColumn + tileWidth);
        const int width = lastColumn - firstColumn;
        if (width <= 0) continue;
        std::vector<float> ring1(static_cast<size_t>(depth) * width);
        std::vector<float> ring2(static_cast<size_t>(depth) * width);
        std::vector<float> cell1(static_cast<size_t>(width));
        std::vector<float> cell2(static_cast<size_t>(width));
        std::vector<float> cell3(static_cast<size_t>(width));
        int produced1 = 0;
        int produced2 = 0;
        bool started1 = false;
        bool started2 = false;

        const auto ringRow = [&](std::vector<float>& ring, int row) {
            return &ring[static_cast<size_t>(row % depth) * width];
        };

        // Stage 1: source -> V1 rows.
        const auto produce1 = [&](int upTo) {
            while (produced1 <= upTo && produced1 <= last) {
                const int y = produced1;
                if (!started1) {
                    for (int c = 0; c < width; c++) {
                        const int column = firstColumn + c;
                        double cumulative = static_cast<double>(source[column]) * radius;
                        for (int row = 0; row <= reach; row++) {
                            cumulative += source[static_cast<size_t>(row) * frameWidth + column];
                        }
                        if (last < radius) {
                            cumulative += static_cast<double>(
                                source[static_cast<size_t>(last) * frameWidth + column]) * (radius - last);
                        }
                        cell1[c] = static_cast<float>(cumulative);
                    }
                    started1 = true;
                }
                float* row = ringRow(ring1, y);
                for (int c = 0; c < width; c++) {
                    row[c] = static_cast<float>(static_cast<double>(cell1[c]) / span);
                }
                int belowRow = y + radius + 1;
                if (belowRow > last) belowRow = last;
                int aboveRow = y - radius;
                if (aboveRow < 0) aboveRow = 0;
                const float* below = source + static_cast<size_t>(belowRow) * frameWidth + firstColumn;
                const float* above = source + static_cast<size_t>(aboveRow) * frameWidth + firstColumn;
                for (int c = 0; c < width; c++) {
                    cell1[c] = static_cast<float>(static_cast<double>(cell1[c]) + below[c] - above[c]);
                }
                produced1++;
            }
        };

        // Stage 2: V1 rows -> V2 rows.
        const auto produce2 = [&](int upTo) {
            while (produced2 <= upTo && produced2 <= last) {
                const int y = produced2;
                produce1(std::min(y + radius + 1, last));
                if (!started2) {
                    const float* first = ringRow(ring1, 0);
                    for (int c = 0; c < width; c++) {
                        double cumulative = static_cast<double>(first[c]) * radius;
                        for (int row = 0; row <= reach; row++) {
                            cumulative += ringRow(ring1, row)[c];
                        }
                        if (last < radius) {
                            cumulative += static_cast<double>(ringRow(ring1, last)[c]) * (radius - last);
                        }
                        cell2[c] = static_cast<float>(cumulative);
                    }
                    started2 = true;
                }
                float* row = ringRow(ring2, y);
                for (int c = 0; c < width; c++) {
                    row[c] = static_cast<float>(static_cast<double>(cell2[c]) / span);
                }
                int belowRow = y + radius + 1;
                if (belowRow > last) belowRow = last;
                int aboveRow = y - radius;
                if (aboveRow < 0) aboveRow = 0;
                const float* below = ringRow(ring1, belowRow);
                const float* above = ringRow(ring1, aboveRow);
                for (int c = 0; c < width; c++) {
                    cell2[c] = static_cast<float>(static_cast<double>(cell2[c]) + below[c] - above[c]);
                }
                produced2++;
            }
        };

        // Stage 3: V2 rows -> destination, initialised from the V2 head rows.
        for (int y = 0; y <= last; y++) {
            produce2(std::min(y + radius + 1, last));
            if (y == 0) {
                const float* first = ringRow(ring2, 0);
                for (int c = 0; c < width; c++) {
                    double cumulative = static_cast<double>(first[c]) * radius;
                    for (int row = 0; row <= reach; row++) {
                        cumulative += ringRow(ring2, row)[c];
                    }
                    if (last < radius) {
                        cumulative += static_cast<double>(ringRow(ring2, last)[c]) * (radius - last);
                    }
                    cell3[c] = static_cast<float>(cumulative);
                }
            }
            float* row = destination + static_cast<size_t>(y) * frameWidth + firstColumn;
            for (int c = 0; c < width; c++) {
                row[c] = static_cast<float>(static_cast<double>(cell3[c]) / span);
            }
            int belowRow = y + radius + 1;
            if (belowRow > last) belowRow = last;
            int aboveRow = y - radius;
            if (aboveRow < 0) aboveRow = 0;
            const float* below = ringRow(ring2, belowRow);
            const float* above = ringRow(ring2, aboveRow);
            for (int c = 0; c < width; c++) {
                cell3[c] = static_cast<float>(static_cast<double>(cell3[c]) + below[c] - above[c]);
            }
        }
    }
}

/**
 * Separable triple box blur. `sigma` is the intended Gaussian sigma; three
 * boxes of radius r contribute r(r+1) of variance, so the radius is solved from
 * `r(r+1) == sigma^2`.
 */
void boxBlurInto(const float* source, int frameWidth, int frameHeight, int sigma, float* planeA,
    float* destination) {
    const double wanted = sigma < 1 ? 1.0 : static_cast<double>(sigma);
    const int radius = std::max(1, roundNonNegative((std::sqrt(1.0 + 4.0 * wanted * wanted) - 1.0) / 2.0));
    const int span = 2 * radius + 1;
    // Horizontal: source -> H3 plane, fused per row so the H1/H2 planes never
    // reach memory. Each row is an independent running sum from x=0, so
    // parallelising over rows changes no arithmetic at all.
    boxBlurHorizontalTriple(source, planeA, frameWidth, frameHeight, radius, span);
    // Vertical: H3 plane -> destination, fused so the V1/V2 planes never reach
    // memory. `destination` may alias `source`: both fused passes have already
    // consumed the source rows they needed before writing.
    boxBlurVerticalTriple(planeA, destination, frameWidth, frameHeight, radius, span);
}

/**
 * float32 plane with a requested element count, deliberately **not**
 * zero-initialised.
 *
 * Why: at 44 MP one plane is 176.7 MB. `std::vector<float>(count, 0.0f)` writes
 * every byte of it before the first pass writes it again; `GuidedScratch` holds
 * five planes and a frame runs two guided filters, so the old zero-fill alone
 * touched ~1.8 GB that was immediately overwritten. Every producer in this file
 * writes every element before any reader reads it (the fused box passes fill the
 * one plane they are given, `luminancePlane` and the elementwise loops visit
 * every index), so allocation without initialisation changes no byte.
 *
 * `new float[count]` (unlike `std::make_unique<float[]>(count)`) default-
 * initialises the array, i.e. leaves it uninitialised for a fundamental type.
 */
struct FloatPlane {
    std::unique_ptr<float[]> data;
    size_t size = 0;

    void ensure(size_t count) {
        if (data != nullptr && size == count) return;
        data.reset(new float[count]);
        size = count;
    }

    float* get() { return data.get(); }
    const float* get() const { return data.get(); }
};

/** Blur entry point for callers that do not already own planes. */
FloatPlane boxBlurPlane(const float* source, int frameWidth, int frameHeight, int sigma) {
    const size_t count = static_cast<size_t>(frameWidth) * frameHeight;
    FloatPlane planeA;
    FloatPlane result;
    planeA.ensure(count);
    result.ensure(count);
    boxBlurInto(source, frameWidth, frameHeight, sigma, planeA.get(), result.get());
    return result;
}

/** Five whole-frame planes, reused across the two bands of one frame. */
struct GuidedScratch {
    FloatPlane tempA;
    FloatPlane tempB;
    FloatPlane spare;
    FloatPlane mean;
    FloatPlane meanSquare;

    void ensure(size_t count) {
        tempA.ensure(count);
        tempB.ensure(count);
        spare.ensure(count);
        mean.ensure(count);
        meanSquare.ensure(count);
    }
};

/**
 * Guided filter with the image as its own guide, mirroring `guidedFilterPlane`:
 *
 *   mean = box(src, r);  var = box(src^2, r) - mean^2
 *   a = var / (var + eps);  b = mean - a*mean
 *   dst = box(a, r)*src + box(b, r)
 */
FloatPlane guidedFilterPlane(const float* source, int frameWidth, int frameHeight,
    int radius, double epsilon, GuidedScratch& scratch) {
    const size_t count = static_cast<size_t>(frameWidth) * frameHeight;
    scratch.ensure(count);
    float* tempA = scratch.tempA.get();
    float* tempB = scratch.tempB.get();
    float* spare = scratch.spare.get();
    float* mean = scratch.mean.get();
    float* meanSquare = scratch.meanSquare.get();
    boxBlurInto(source, frameWidth, frameHeight, radius, tempA, mean);
    #pragma omp parallel for schedule(static) if(count > 65536)
    for (long long index = 0; index < static_cast<long long>(count); index++) {
        spare[index] = static_cast<float>(static_cast<double>(source[index]) *
            static_cast<double>(source[index]));
    }
    boxBlurInto(spare, frameWidth, frameHeight, radius, tempA, meanSquare);
    #pragma omp parallel for schedule(static) if(count > 65536)
    for (long long index = 0; index < static_cast<long long>(count); index++) {
        const double variance = static_cast<double>(meanSquare[index]) -
            static_cast<double>(mean[index]) * static_cast<double>(mean[index]);
        tempA[index] = static_cast<float>(variance / (variance + epsilon));
        // `b` reads `a` back out of the plane, so it sees the same float32
        // rounding the ArkTS in-place form did.
        tempB[index] = static_cast<float>(static_cast<double>(mean[index]) -
            static_cast<double>(tempA[index]) * static_cast<double>(mean[index]));
    }
    boxBlurInto(tempA, frameWidth, frameHeight, radius, mean, spare);
    boxBlurInto(tempB, frameWidth, frameHeight, radius, mean, tempB);
    FloatPlane destination;
    destination.ensure(count);
    float* out = destination.get();
    #pragma omp parallel for schedule(static) if(count > 65536)
    for (long long index = 0; index < static_cast<long long>(count); index++) {
        out[index] = static_cast<float>(static_cast<double>(spare[index]) *
            static_cast<double>(source[index]) + static_cast<double>(tempB[index]));
    }
    return destination;
}

/** Rec.709 luminance plane of an RGBA frame, 0..1, float32 like the ArkTS plane. */
void luminancePlane(const uint8_t* rgba, int frameWidth, int frameHeight, float* target) {
    const size_t count = static_cast<size_t>(frameWidth) * frameHeight;
    #pragma omp parallel for schedule(static) if(count > 65536)
    for (long long index = 0; index < static_cast<long long>(count); index++) {
        const size_t offset = static_cast<size_t>(index) * 4;
        const double r = static_cast<double>(rgba[offset]) / 255.0;
        const double g = static_cast<double>(rgba[offset + 1]) / 255.0;
        const double b = static_cast<double>(rgba[offset + 2]) / 255.0;
        target[index] = static_cast<float>(r * kLumaR + g * kLumaG + b * kLumaB);
    }
}

/**
 * Texture and clarity: Compositor's `adjust_camera_raw_effects`.
 *
 *   fine   = guided(tone, textureRadius)
 *   coarse = guided(tone, clarityRadius)
 *   detail = texture*gainT*(tone - fine) + clarity*gainC*(tone - coarse)
 *   target = clamp(tone + detail, 0, 1);  rgb *= target / tone
 */
void applyTextureClarity(uint8_t* output, const float* luma, int frameWidth, int frameHeight,
    int radiusTexture, int radiusClarity, double texture, double clarity) {
    const size_t count = static_cast<size_t>(frameWidth) * frameHeight;
    GuidedScratch scratch;
    const bool hasFine = texture != 0.0;
    const bool hasCoarse = clarity != 0.0;
    FloatPlane fine;
    FloatPlane coarse;
    if (hasFine) {
        fine = guidedFilterPlane(luma, frameWidth, frameHeight, radiusTexture, kGuidedEpsilon, scratch);
    }
    if (hasCoarse) {
        coarse = guidedFilterPlane(luma, frameWidth, frameHeight, radiusClarity, kGuidedEpsilon, scratch);
    }
    if (!hasFine && !hasCoarse) return;
    const float* fineData = fine.get();
    const float* coarseData = coarse.get();
    const double textureGain = texture > 0.0 ? kTexturePositiveGain : kTextureNegativeGain;
    const double clarityGain = clarity > 0.0 ? kClarityPositiveGain : kClarityNegativeGain;
    #pragma omp parallel for schedule(static) if(count > 65536)
    for (long long index = 0; index < static_cast<long long>(count); index++) {
        const double tone = static_cast<double>(luma[index]);
        double detail = 0.0;
        if (hasFine) detail += texture * textureGain * (tone - static_cast<double>(fineData[index]));
        if (hasCoarse) detail += clarity * clarityGain * (tone - static_cast<double>(coarseData[index]));
        if (detail == 0.0) continue;
        double target = tone + detail;
        if (target < 0.0) target = 0.0;
        if (target > 1.0) target = 1.0;
        const double divisor = tone > kLumaFloor ? tone : kLumaFloor;
        const double gain = target / divisor;
        const size_t offset = index * 4;
        const double red = static_cast<double>(output[offset]) * gain;
        const double green = static_cast<double>(output[offset + 1]) * gain;
        const double blue = static_cast<double>(output[offset + 2]) * gain;
        output[offset] = clampRoundedByte(red);
        output[offset + 1] = clampRoundedByte(green);
        output[offset + 2] = clampRoundedByte(blue);
    }
}

/** Uses a given haze colour for the two dehaze branches, mirroring `applyDehazeWithColor`. */
void applyDehazeWithColor(uint8_t* output, int frameWidth, int frameHeight, double strength,
    double hazeRed, double hazeGreen, double hazeBlue, double veil) {
    const size_t count = static_cast<size_t>(frameWidth) * frameHeight;
    const bool positive = strength > 0.0;
    const double amount = positive ? strength : -strength;
    #pragma omp parallel for schedule(static) if(count > 65536)
    for (long long index = 0; index < static_cast<long long>(count); index++) {
        const size_t offset = static_cast<size_t>(index) * 4;
        const double alpha = static_cast<double>(output[offset + 3]);
        if (alpha == 0.0) continue;
        double red = std::min(1.0, static_cast<double>(output[offset]) / alpha);
        double green = std::min(1.0, static_cast<double>(output[offset + 1]) / alpha);
        double blue = std::min(1.0, static_cast<double>(output[offset + 2]) / alpha);
        if (positive) {
            double dark = 1.0;
            const double scaleR = red / std::max(hazeRed, 1e-3);
            const double scaleG = green / std::max(hazeGreen, 1e-3);
            const double scaleB = blue / std::max(hazeBlue, 1e-3);
            if (scaleR < dark) dark = scaleR;
            if (scaleG < dark) dark = scaleG;
            if (scaleB < dark) dark = scaleB;
            double transmission = 1.0 - 0.7 * amount * dark;
            if (transmission < 0.5) transmission = 0.5;
            red = (red - hazeRed) / transmission + hazeRed;
            green = (green - hazeGreen) / transmission + hazeGreen;
            blue = (blue - hazeBlue) / transmission + hazeBlue;
        } else {
            red = red * (1.0 - veil) + hazeRed * veil;
            green = green * (1.0 - veil) + hazeGreen * veil;
            blue = blue * (1.0 - veil) + hazeBlue * veil;
        }
        output[offset] = clampRoundedByte(std::max(0.0, std::min(1.0, red)) * alpha);
        output[offset + 1] = clampRoundedByte(std::max(0.0, std::min(1.0, green)) * alpha);
        output[offset + 2] = clampRoundedByte(std::max(0.0, std::min(1.0, blue)) * alpha);
    }
}

/** Compositor-semantics dehaze: precomputed haze colour, or estimate it here. */
void applyDehazeCompositor(uint8_t* output, int frameWidth, int frameHeight, double strength,
    const DetailParams& params) {
    if (strength == 0.0) return;
    if (params.hasHaze) {
        if (params.hazeRed > 0.999 && params.hazeGreen > 0.999 && params.hazeBlue > 0.999) return;
        applyDehazeWithColor(output, frameWidth, frameHeight, strength, params.hazeRed,
            params.hazeGreen, params.hazeBlue, params.veil);
        return;
    }
    double estimated[3] = { 1.0, 1.0, 1.0 };
    if (!hazeColor(output, frameWidth, frameHeight, estimated)) return;
    // A uniform frame is all haze: removing haze from it should do nothing.
    if (estimated[0] > 0.999 && estimated[1] > 0.999 && estimated[2] > 0.999) return;
    applyDehazeWithColor(output, frameWidth, frameHeight, strength, estimated[0], estimated[1],
        estimated[2], params.veil);
}

/**
 * Unsharp mask with a Sobel-gradient edge mask:
 *
 *   result = I + amount * mask * (I - blur(radius) + detail * highPass3x3(I))
 */
void applySharpen(uint8_t* output, int frameWidth, int frameHeight, int radius, double amount,
    double detail, double masking) {
    const size_t count = static_cast<size_t>(frameWidth) * frameHeight;
    FloatPlane luminancePlaneBuffer;
    luminancePlaneBuffer.ensure(count);
    float* luminance = luminancePlaneBuffer.get();
    luminancePlane(output, frameWidth, frameHeight, luminance);
    const FloatPlane basePlane = boxBlurPlane(luminance, frameWidth, frameHeight,
        radius < 1 ? 1 : radius);
    const float* base = basePlane.get();
    const int lastColumn = frameWidth - 1;
    const int lastRow = frameHeight - 1;
    const double edgeSpan = 6.0 - 0.5;
    // Rows are independent: every write belongs to the pixel that is read.
    #pragma omp parallel for schedule(static) if(frameHeight > 8)
    for (int row = 0; row < frameHeight; row++) {
        const int rowOffset = row * frameWidth;
        const int upRow = (row > 0 ? row - 1 : 0) * frameWidth;
        const int downRow = (row < lastRow ? row + 1 : lastRow) * frameWidth;
        for (int column = 0; column < frameWidth; column++) {
            const int index = rowOffset + column;
            const size_t offset = static_cast<size_t>(index) * 4;
            const int leftIndex = column > 0 ? column - 1 : 0;
            const int rightIndex = column < lastColumn ? column + 1 : lastColumn;
            const double luma = static_cast<double>(luminance[index]);
            const double up = static_cast<double>(luminance[upRow + column]);
            const double down = static_cast<double>(luminance[downRow + column]);
            const double left = static_cast<double>(luminance[rowOffset + leftIndex]);
            const double right = static_cast<double>(luminance[rowOffset + rightIndex]);
            const double highPass = luma * 4.0 - up - down - left - right;
            const double upperLeft = static_cast<double>(luminance[upRow + leftIndex]);
            const double upperRight = static_cast<double>(luminance[upRow + rightIndex]);
            const double lowerLeft = static_cast<double>(luminance[downRow + leftIndex]);
            const double lowerRight = static_cast<double>(luminance[downRow + rightIndex]);
            const double gradX = (upperRight + 2.0 * right + lowerRight) -
                (upperLeft + 2.0 * left + lowerLeft);
            const double gradY = (lowerLeft + 2.0 * down + lowerRight) -
                (upperLeft + 2.0 * up + upperRight);
            const double gradient = std::sqrt(gradX * gradX + gradY * gradY);
            const double r = static_cast<double>(output[offset]) / 255.0;
            const double g = static_cast<double>(output[offset + 1]) / 255.0;
            const double b = static_cast<double>(output[offset + 2]) / 255.0;
            const double channelDelta = std::max(std::max(std::fabs(r - luma), std::fabs(g - luma)),
                std::fabs(b - luma));
            const double activity = std::max(gradient, channelDelta * 8.0);
            double ramp = (activity - 0.5) / edgeSpan;
            if (ramp < 0.0) ramp = 0.0;
            if (ramp > 1.0) ramp = 1.0;
            const double edge = ramp * ramp * (3.0 - 2.0 * ramp);
            const double mask = 1.0 - masking * (1.0 - edge);
            if (mask <= 0.0) continue;
            const double unsharp = luma - static_cast<double>(base[index]);
            const double adjustment = kSharpenMaxAdjustment * std::tanh(amount * mask *
                (unsharp + highPass * detail) / kSharpenMaxAdjustment) * 255.0;
            const double rr = static_cast<double>(output[offset]) + adjustment;
            const double gg = static_cast<double>(output[offset + 1]) + adjustment;
            const double bb = static_cast<double>(output[offset + 2]) + adjustment;
            output[offset] = clampRoundedByte(rr);
            output[offset + 1] = clampRoundedByte(gg);
            output[offset + 2] = clampRoundedByte(bb);
        }
    }
}

}  // namespace

bool detailIsIdentity(const DetailParams& params) {
    return clampMagnitude(params.texture, 1.0) == 0.0 &&
        clampMagnitude(params.clarity, 1.0) == 0.0 &&
        clampMagnitude(params.dehaze, 1.0) == 0.0 &&
        clampUnit(params.sharpenAmount) == 0.0;
}

bool hazeColor(const uint8_t* rgba, int width, int height, double out[3]) {
    if (width <= 0 || height <= 0) return false;
    const size_t count = static_cast<size_t>(width) * height;
    // A 256-bin histogram of the alpha-weighted luminance. The accumulator is a
    // float32 plane in ArkTS, so it rounds on every `+=`; keep that.
    std::vector<float> histogram(256, 0.0f);
    for (size_t index = 0; index < count; index++) {
        const size_t offset = index * 4;
        const double alpha = static_cast<double>(rgba[offset + 3]);
        if (alpha == 0.0) continue;
        const double red = std::min(1.0, static_cast<double>(rgba[offset]) / alpha);
        const double green = std::min(1.0, static_cast<double>(rgba[offset + 1]) / alpha);
        const double blue = std::min(1.0, static_cast<double>(rgba[offset + 2]) / alpha);
        int bin = roundNonNegative(255.0 * (red * kLumaR + green * kLumaG + blue * kLumaB));
        if (bin < 0) bin = 0;
        if (bin > 255) bin = 255;
        histogram[bin] = static_cast<float>(static_cast<double>(histogram[bin]) + alpha / 255.0);
    }
    double total = 0.0;
    for (int bin = 0; bin < 256; bin++) total += histogram[bin];
    if (total <= 0.0) return false;
    int threshold = 255;
    double above = 0.0;
    while (threshold > 0 && above + static_cast<double>(histogram[threshold]) < total * 0.01) {
        above += static_cast<double>(histogram[threshold]);
        threshold--;
    }
    double hazeRed = 0.0;
    double hazeGreen = 0.0;
    double hazeBlue = 0.0;
    double weight = 0.0;
    for (size_t index = 0; index < count; index++) {
        const size_t offset = index * 4;
        const double alpha = static_cast<double>(rgba[offset + 3]);
        if (alpha == 0.0) continue;
        const double red = std::min(1.0, static_cast<double>(rgba[offset]) / alpha);
        const double green = std::min(1.0, static_cast<double>(rgba[offset + 1]) / alpha);
        const double blue = std::min(1.0, static_cast<double>(rgba[offset + 2]) / alpha);
        if (roundNonNegative(255.0 * (red * kLumaR + green * kLumaG + blue * kLumaB)) < threshold) continue;
        const double w = alpha / 255.0;
        hazeRed += red * w;
        hazeGreen += green * w;
        hazeBlue += blue * w;
        weight += w;
    }
    if (weight <= 0.0) return false;
    out[0] = hazeRed / weight;
    out[1] = hazeGreen / weight;
    out[2] = hazeBlue / weight;
    return true;
}

void applyDetail(const uint8_t* src, size_t srcLength, uint8_t* dst, const DetailParams& params) {
    if (params.width <= 0 || params.height <= 0) return;
    const size_t wanted = static_cast<size_t>(params.width) * params.height * 4;
    const size_t available = srcLength < wanted ? srcLength : wanted;
    // Only the tail can be missing (a short source is documented to degrade to
    // transparent black), so a full source needs no zero-fill at all. At 44 MP
    // that removed a 176.7 MB memset that the memcpy overwrote immediately.
    if (available < wanted) {
        if (available > 0) std::memcpy(dst, src, available);
        std::memset(dst + available, 0, wanted - available);
    } else if (available > 0) {
        std::memcpy(dst, src, available);
    }
    if (detailIsIdentity(params)) return;

    const double texture = clampMagnitude(params.texture, 1.0);
    const double clarity = clampMagnitude(params.clarity, 1.0);
    const double dehaze = clampMagnitude(params.dehaze, 1.0);
    const double sharpenAmount = clampUnit(params.sharpenAmount);
    const double sharpenDetail = clampUnit(params.sharpenDetail);
    const double sharpenMasking = clampUnit(params.sharpenMasking);

    if (texture != 0.0 || clarity != 0.0) {
        FloatPlane luminancePlaneBuffer;
        luminancePlaneBuffer.ensure(static_cast<size_t>(params.width) * params.height);
        float* luminance = luminancePlaneBuffer.get();
        luminancePlane(dst, params.width, params.height, luminance);
        applyTextureClarity(dst, luminance, params.width, params.height,
            params.radiusTexture, params.radiusClarity, texture, clarity);
    }
    if (dehaze != 0.0) {
        applyDehazeCompositor(dst, params.width, params.height, dehaze, params);
    }
    if (sharpenAmount != 0.0) {
        applySharpen(dst, params.width, params.height, params.radiusSharpen, sharpenAmount,
            sharpenDetail, sharpenMasking);
    }
}

}  // namespace vivid
