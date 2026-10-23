/*
 * vivid_bokeh — native depth-of-field / bokeh stage for the VIVID editor.
 *
 * Port of the CPU pipeline in KyMoShI/edmund-lumen-bokeh (MIT):
 *   - circle-of-confusion from a depth map (or a centre-focus radial fallback),
 *   - three-level aperture convolution for the defocused background,
 *   - additive aperture-shaped highlight discs with spherical aberration.
 *
 * The module is pure CPU. It never touches the file system or the network and
 * receives every pixel and parameter from ArkTS. The caller runs it off the UI
 * thread (TaskPool or a NAPI worker), so the loops here are free to use OpenMP.
 *
 * Sizes: the background plate and the disc overlay are built at a bounded
 * working resolution (long edge <= 1400 px) because a defocused background is
 * low-frequency by definition. The sharp subject is composited back from the
 * full-resolution original, so subject edges do not inherit that bound.
 */
#ifndef VIVID_BOKEH_STANDALONE
#include <napi/native_api.h>
#endif

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

#ifdef _OPENMP
#include <omp.h>
#endif

#ifdef VIVID_BOKEH_STANDALONE
#include <cstdio>
#endif

namespace {

constexpr float kPi = 3.14159265358979323846f;
constexpr int kMaxWorkEdge = 1400;

struct Settings {
    float aperture = 1.4f;
    float blur = 0.55f;
    float bokeh = 0.35f;
    float density = 0.55f;
    float size = 1.0f;
    float spherical = 0.0f;
    float focus = 0.45f;
    int shape = 7;
};

struct Vec2 {
    float x;
    float y;
};

float clampF(float value, float minimum, float maximum) {
    if (!(value == value)) return minimum;
    return value < minimum ? minimum : (value > maximum ? maximum : value);
}

float smoothstep01(float value) {
    const float t = clampF(value, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/** Bilinear sample of one interleaved RGB float image; edges clamp. */
void sampleRgb(const std::vector<float>& image, int width, int height,
               float u, float v, float* out) {
    if (width <= 0 || height <= 0) {
        out[0] = out[1] = out[2] = 0.0f;
        return;
    }
    const float fx = clampF(u * width - 0.5f, 0.0f, static_cast<float>(width - 1));
    const float fy = clampF(v * height - 0.5f, 0.0f, static_cast<float>(height - 1));
    const int x0 = static_cast<int>(fx);
    const int y0 = static_cast<int>(fy);
    const int x1 = std::min(width - 1, x0 + 1);
    const int y1 = std::min(height - 1, y0 + 1);
    const float tx = fx - x0;
    const float ty = fy - y0;
    const int a = (y0 * width + x0) * 3;
    const int b = (y0 * width + x1) * 3;
    const int c = (y1 * width + x0) * 3;
    const int d = (y1 * width + x1) * 3;
    for (int channel = 0; channel < 3; channel++) {
        const float top = image[a + channel] + (image[b + channel] - image[a + channel]) * tx;
        const float bottom = image[c + channel] + (image[d + channel] - image[c + channel]) * tx;
        out[channel] = top + (bottom - top) * ty;
    }
}

float sampleGray(const std::vector<float>& image, int width, int height,
                 float u, float v) {
    if (width <= 0 || height <= 0) return 0.0f;
    const float fx = clampF(u * width - 0.5f, 0.0f, static_cast<float>(width - 1));
    const float fy = clampF(v * height - 0.5f, 0.0f, static_cast<float>(height - 1));
    const int x0 = static_cast<int>(fx);
    const int y0 = static_cast<int>(fy);
    const int x1 = std::min(width - 1, x0 + 1);
    const int y1 = std::min(height - 1, y0 + 1);
    const float tx = fx - x0;
    const float ty = fy - y0;
    const float top = image[y0 * width + x0] +
        (image[y0 * width + x1] - image[y0 * width + x0]) * tx;
    const float bottom = image[y1 * width + x0] +
        (image[y1 * width + x1] - image[y1 * width + x0]) * tx;
    return top + (bottom - top) * ty;
}

/** Downsample RGBA8888 to the working plate. */
std::vector<float> downsampleRgba(const uint8_t* rgba, int width, int height,
                                  int outWidth, int outHeight) {
    std::vector<float> out(static_cast<size_t>(outWidth) * outHeight * 3, 0.0f);
    const float xRatio = static_cast<float>(width) / outWidth;
    const float yRatio = static_cast<float>(height) / outHeight;
#pragma omp parallel for schedule(static)
    for (int y = 0; y < outHeight; y++) {
        const float sy = (y + 0.5f) * yRatio - 0.5f;
        const int y0 = std::max(0, std::min(height - 1, static_cast<int>(std::floor(sy))));
        const int y1 = std::min(height - 1, y0 + 1);
        const float fy = clampF(sy - y0, 0.0f, 1.0f);
        for (int x = 0; x < outWidth; x++) {
            const float sx = (x + 0.5f) * xRatio - 0.5f;
            const int x0 = std::max(0, std::min(width - 1, static_cast<int>(std::floor(sx))));
            const int x1 = std::min(width - 1, x0 + 1);
            const float fx = clampF(sx - x0, 0.0f, 1.0f);
            const int i00 = (y0 * width + x0) * 4;
            const int i01 = (y0 * width + x1) * 4;
            const int i10 = (y1 * width + x0) * 4;
            const int i11 = (y1 * width + x1) * 4;
            const int o = (y * outWidth + x) * 3;
            for (int channel = 0; channel < 3; channel++) {
                const float top = rgba[i00 + channel] +
                    (rgba[i01 + channel] - rgba[i00 + channel]) * fx;
                const float bottom = rgba[i10 + channel] +
                    (rgba[i11 + channel] - rgba[i10 + channel]) * fx;
                out[o + channel] = (top + (bottom - top) * fy) * (1.0f / 255.0f);
            }
        }
    }
    return out;
}

std::vector<float> downsampleRgb(const std::vector<float>& src, int width, int height,
                                 int outWidth, int outHeight) {
    std::vector<float> out(static_cast<size_t>(outWidth) * outHeight * 3, 0.0f);
    const float xRatio = static_cast<float>(width) / outWidth;
    const float yRatio = static_cast<float>(height) / outHeight;
    for (int y = 0; y < outHeight; y++) {
        const int sy = std::min(height - 1, static_cast<int>((y + 0.5f) * yRatio));
        for (int x = 0; x < outWidth; x++) {
            const int sx = std::min(width - 1, static_cast<int>((x + 0.5f) * xRatio));
            for (int channel = 0; channel < 3; channel++) {
                out[(y * outWidth + x) * 3 + channel] =
                    src[(sy * width + sx) * 3 + channel];
            }
        }
    }
    return out;
}

std::vector<float> downsampleGray(const std::vector<float>& src, int width, int height,                                  int outWidth, int outHeight) {
    std::vector<float> out(static_cast<size_t>(outWidth) * outHeight, 0.0f);
    const float xRatio = static_cast<float>(width) / outWidth;
    const float yRatio = static_cast<float>(height) / outHeight;
    for (int y = 0; y < outHeight; y++) {
        const int sy = std::min(height - 1, static_cast<int>((y + 0.5f) * yRatio));
        for (int x = 0; x < outWidth; x++) {
            const int sx = std::min(width - 1, static_cast<int>((x + 0.5f) * xRatio));
            out[y * outWidth + x] = src[sy * width + sx];
        }
    }
    return out;
}

/** Sliding-window box blur, edges clamp, `channels` interleaved floats. */
void boxBlur(std::vector<float>& data, int width, int height, int radius, int channels,
             int passes) {
    if (radius <= 0 || width <= 0 || height <= 0 || passes <= 0) return;
    std::vector<float> temp(data.size(), 0.0f);
    const float scale = 1.0f / (radius * 2 + 1);
    for (int pass = 0; pass < passes; pass++) {
#pragma omp parallel for schedule(static)
        for (int y = 0; y < height; y++) {
            const int row = y * width;
            for (int channel = 0; channel < channels; channel++) {
                float sum = 0.0f;
                for (int k = -radius; k <= radius; k++) {
                    const int x = std::max(0, std::min(width - 1, k));
                    sum += data[(row + x) * channels + channel];
                }
                for (int x = 0; x < width; x++) {
                    temp[(row + x) * channels + channel] = sum * scale;
                    const int add = std::max(0, std::min(width - 1, x + radius + 1));
                    const int drop = std::max(0, std::min(width - 1, x - radius));
                    sum += data[(row + add) * channels + channel] -
                        data[(row + drop) * channels + channel];
                }
            }
        }
#pragma omp parallel for schedule(static)
        for (int x = 0; x < width; x++) {
            for (int channel = 0; channel < channels; channel++) {
                float sum = 0.0f;
                for (int k = -radius; k <= radius; k++) {
                    const int y = std::max(0, std::min(height - 1, k));
                    sum += temp[(y * width + x) * channels + channel];
                }
                for (int y = 0; y < height; y++) {
                    data[(y * width + x) * channels + channel] = sum * scale;
                    const int add = std::max(0, std::min(height - 1, y + radius + 1));
                    const int drop = std::max(0, std::min(height - 1, y - radius));
                    sum += temp[(add * width + x) * channels + channel] -
                        temp[(drop * width + x) * channels + channel];
                }
            }
        }
    }
}

void maxFilter(std::vector<float>& data, int width, int height, int radius) {
    if (radius <= 0) return;
    std::vector<float> temp(data.size(), 0.0f);
#pragma omp parallel for schedule(static)
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float maximum = data[y * width + x];
            for (int k = -radius; k <= radius; k++) {
                const int sx = std::max(0, std::min(width - 1, x + k));
                maximum = std::max(maximum, data[y * width + sx]);
            }
            temp[y * width + x] = maximum;
        }
    }
#pragma omp parallel for schedule(static)
    for (int x = 0; x < width; x++) {
        for (int y = 0; y < height; y++) {
            float maximum = temp[y * width + x];
            for (int k = -radius; k <= radius; k++) {
                const int sy = std::max(0, std::min(height - 1, y + k));
                maximum = std::max(maximum, temp[sy * width + x]);
            }
            data[y * width + x] = maximum;
        }
    }
}

/** Rounded aperture outline, identical in spirit to the Python reference. */
std::vector<Vec2> aperturePoints(float cx, float cy, float rx, float ry,
                                 int bladeCount, float rotation) {
    std::vector<Vec2> points;
    if (bladeCount < 3) {
        const int segments = 128;
        points.reserve(segments);
        for (int index = 0; index < segments; index++) {
            const float angle = (2.0f * kPi * index) / segments;
            points.push_back({cx + rx * std::cos(angle), cy + ry * std::sin(angle)});
        }
        return points;
    }
    std::vector<Vec2> corners;
    corners.reserve(bladeCount);
    for (int index = 0; index < bladeCount; index++) {
        const float angle = rotation + (2.0f * kPi * index) / bladeCount;
        corners.push_back({cx + rx * std::cos(angle), cy + ry * std::sin(angle)});
    }
    const float cut = 0.12f;
    points.reserve(bladeCount * 2);
    for (int index = 0; index < bladeCount; index++) {
        const Vec2 p0 = corners[index];
        const Vec2 p1 = corners[(index + 1) % bladeCount];
        points.push_back({p0.x * (1.0f - cut) + p1.x * cut,
                          p0.y * (1.0f - cut) + p1.y * cut});
        points.push_back({p0.x * cut + p1.x * (1.0f - cut),
                          p0.y * cut + p1.y * (1.0f - cut)});
    }
    return points;
}

/** Horizontal span of a convex polygon at scanline y (pixel centre). */
bool polygonSpan(const std::vector<Vec2>& points, float y, float* low, float* high) {
    float minimum = 1e30f;
    float maximum = -1e30f;
    bool found = false;
    const size_t count = points.size();
    for (size_t index = 0; index < count; index++) {
        const Vec2 a = points[index];
        const Vec2 b = points[(index + 1) % count];
        if ((a.y <= y && b.y > y) || (b.y <= y && a.y > y)) {
            const float t = (y - a.y) / (b.y - a.y);
            const float x = a.x + (b.x - a.x) * t;
            minimum = std::min(minimum, x);
            maximum = std::max(maximum, x);
            found = true;
        }
    }
    if (!found) return false;
    *low = minimum;
    *high = maximum;
    return true;
}

void addSpan(std::vector<float>& layer, int width, int height, int y,
             float low, float high, const float* color, float gain) {
    if (y < 0 || y >= height) return;
    low = std::max(0.0f, low);
    high = std::min(static_cast<float>(width), high);
    if (!(high > low)) return;
    const int first = static_cast<int>(std::floor(low));
    const int last = static_cast<int>(std::ceil(high)) - 1;
    for (int x = first; x <= last; x++) {
        if (x < 0 || x >= width) continue;
        const float coverage = std::min(high, static_cast<float>(x + 1)) -
            std::max(low, static_cast<float>(x));
        if (!(coverage > 0.0f)) continue;
        const int index = (y * width + x) * 3;
        const float weight = gain * coverage;
        layer[index] += color[0] * weight;
        layer[index + 1] += color[1] * weight;
        layer[index + 2] += color[2] * weight;
    }
}

void fillPolygon(std::vector<float>& layer, int width, int height,
                 const std::vector<Vec2>& points, const float* color, float gain) {
    if (points.size() < 3) return;
    float minY = points[0].y;
    float maxY = points[0].y;
    for (const Vec2& point : points) {
        minY = std::min(minY, point.y);
        maxY = std::max(maxY, point.y);
    }
    const int y0 = std::max(0, static_cast<int>(std::floor(minY)));
    const int y1 = std::min(height - 1, static_cast<int>(std::ceil(maxY)));
    for (int y = y0; y <= y1; y++) {
        float low = 0.0f;
        float high = 0.0f;
        if (!polygonSpan(points, y + 0.5f, &low, &high)) continue;
        addSpan(layer, width, height, y, low, high, color, gain);
    }
}

void fillRing(std::vector<float>& layer, int width, int height,
              const std::vector<Vec2>& outer, const std::vector<Vec2>& inner,
              const float* color, float gain) {
    float minY = outer[0].y;
    float maxY = outer[0].y;
    for (const Vec2& point : outer) {
        minY = std::min(minY, point.y);
        maxY = std::max(maxY, point.y);
    }
    const int y0 = std::max(0, static_cast<int>(std::floor(minY)));
    const int y1 = std::min(height - 1, static_cast<int>(std::ceil(maxY)));
    for (int y = y0; y <= y1; y++) {
        const float scan = y + 0.5f;
        float outerLow = 0.0f;
        float outerHigh = 0.0f;
        if (!polygonSpan(outer, scan, &outerLow, &outerHigh)) continue;
        float innerLow = 0.0f;
        float innerHigh = 0.0f;
        const bool hasInner = polygonSpan(inner, scan, &innerLow, &innerHigh);
        if (hasInner && innerLow > outerLow) {
            addSpan(layer, width, height, y, outerLow, innerLow, color, gain);
        }
        if (hasInner && innerHigh < outerHigh) {
            addSpan(layer, width, height, y, innerHigh, outerHigh, color, gain);
        }
        if (!hasInner) addSpan(layer, width, height, y, outerLow, outerHigh, color, gain);
    }
}

/**
 * Aperture-shaped convolution using row prefix sums.
 *
 * A filled disc is not separable, but summing its horizontal chords is: for
 * each output row the chord width is known, and one row-prefix lookup gives the
 * whole chord. That is O(radius) per pixel instead of O(radius²), which is what
 * makes three depth levels affordable on a phone.
 */
std::vector<float> discBlur(const std::vector<float>& image, int width, int height,
                            int radius, int bladeCount) {
    std::vector<float> out(static_cast<size_t>(width) * height * 3, 0.0f);
    radius = std::max(1, radius);
    std::vector<float> prefix(static_cast<size_t>(width + 1) * height * 3, 0.0f);
#pragma omp parallel for schedule(static)
    for (int y = 0; y < height; y++) {
        const int row = y * (width + 1);
        for (int channel = 0; channel < 3; channel++) {
            prefix[row * 3 + channel] = 0.0f;
        }
        for (int x = 0; x < width; x++) {
            const int src = (y * width + x) * 3;
            const int dst = (row + x + 1) * 3;
            const int prev = (row + x) * 3;
            for (int channel = 0; channel < 3; channel++) {
                prefix[dst + channel] = prefix[prev + channel] + image[src + channel];
            }
        }
    }

    std::vector<Vec2> polygon;
    const bool usePolygon = bladeCount >= 3;
    if (usePolygon) {
        polygon = aperturePoints(0.0f, 0.0f, static_cast<float>(radius),
                                 static_cast<float>(radius), bladeCount, 0.0f);
    }
    std::vector<float> spanLow(radius * 2 + 1, 0.0f);
    std::vector<float> spanHigh(radius * 2 + 1, 0.0f);
    float area = 0.0f;
    for (int dy = -radius; dy <= radius; dy++) {
        float low = 0.0f;
        float high = 0.0f;
        bool found = false;
        if (usePolygon) {
            found = polygonSpan(polygon, static_cast<float>(dy), &low, &high);
        } else {
            const float half = std::sqrt(std::max(0.0f, static_cast<float>(radius * radius - dy * dy)));
            low = -half;
            high = half;
            found = true;
        }
        spanLow[dy + radius] = low;
        spanHigh[dy + radius] = high;
        if (found) area += high - low;
    }
    if (!(area > 1e-3f)) area = static_cast<float>(kPi * radius * radius);

#pragma omp parallel for schedule(static)
    for (int y = 0; y < height; y++) {
        for (int dy = -radius; dy <= radius; dy++) {
            const float low = spanLow[dy + radius];
            const float high = spanHigh[dy + radius];
            if (!(high > low)) continue;
            const int sourceY = std::max(0, std::min(height - 1, y + dy));
            const int row = sourceY * (width + 1);
            for (int x = 0; x < width; x++) {
                float left = x + low;
                float right = x + high;
                left = std::max(0.0f, left);
                right = std::min(static_cast<float>(width), right);
                if (!(right > left)) continue;
                const int first = static_cast<int>(std::floor(left));
                const int last = static_cast<int>(std::ceil(right)) - 1;
                float sum[3] = {0.0f, 0.0f, 0.0f};
                for (int px = first; px <= last; px++) {
                    if (px < 0 || px >= width) continue;
                    const float coverage = std::min(right, static_cast<float>(px + 1)) -
                        std::max(left, static_cast<float>(px));
                    if (!(coverage > 0.0f)) continue;
                    const int a = (row + px) * 3;
                    const int b = (row + px + 1) * 3;
                    for (int channel = 0; channel < 3; channel++) {
                        sum[channel] += (prefix[b + channel] - prefix[a + channel]) * coverage;
                    }
                }
                const int outIndex = (y * width + x) * 3;
                for (int channel = 0; channel < 3; channel++) {
                    out[outIndex + channel] += sum[channel];
                }
            }
        }
    }
    const float normalize = 1.0f / area;
    for (size_t index = 0; index < out.size(); index++) out[index] *= normalize;
    return out;
}

float cocAt(float depth, const Settings& settings, bool centerMode, float apertureGain) {
    const float focus = clampF(settings.focus, 0.0f, 0.98f);
    float coc;
    if (centerMode) {
        coc = clampF((depth - focus) / std::max(1.0f - focus, 1e-3f), 0.0f, 1.0f);
        coc = clampF(coc * (0.45f + 0.70f * 1.35f), 0.0f, 1.0f);
    } else {
        coc = std::fabs(depth - focus);
        coc = clampF(coc * (1.0f + 0.70f * 1.6f), 0.0f, 1.0f);
    }
    return clampF(coc * settings.blur * apertureGain, 0.0f, 1.0f);
}

struct Peak {
    float weight;
    float x;
    float y;
};

}  // namespace

/**
 * Pure renderer, shared by the NAPI entry and the host parity test.
 *
 * `depth` may be null, in which case the same radial centre-focus depth the
 * Python project uses as its no-model fallback is generated here.
 */
static std::vector<uint8_t> renderCore(const uint8_t* rgba, int width, int height,
                                       const uint8_t* depth, size_t depthLength,
                                       int depthWidth, int depthHeight, bool hasDepth,
                                       Settings settings) {
    settings.aperture = clampF(settings.aperture, 1.2f, 8.0f);
    settings.blur = clampF(settings.blur, 0.0f, 1.0f);
    settings.bokeh = clampF(settings.bokeh, 0.0f, 1.0f);
    settings.density = clampF(settings.density, 0.0f, 1.0f);
    settings.size = clampF(settings.size, 0.05f, 2.0f);
    settings.spherical = clampF(settings.spherical, -1.0f, 1.0f);
    settings.focus = clampF(settings.focus, 0.0f, 0.98f);
    settings.shape = (settings.shape >= 5 && settings.shape <= 9) ? settings.shape : 0;

    // A closed stage must not cost a frame.
    if (settings.blur <= 0.0f && settings.bokeh <= 0.0f) {
        return std::vector<uint8_t>(rgba, rgba + static_cast<size_t>(width) * height * 4);
    }

    const float workScale = std::min(1.0f, static_cast<float>(kMaxWorkEdge) /
        static_cast<float>(std::max(width, height)));
    const int workWidth = std::max(1, static_cast<int>(std::lround(width * workScale)));
    const int workHeight = std::max(1, static_cast<int>(std::lround(height * workScale)));
    const float radiusScale = std::max(workWidth, workHeight) / 1000.0f;
    const float apertureGain = clampF(std::pow(8.0f / std::max(settings.aperture, 1.2f), 0.42f) / 2.3f,
        0.35f, 2.5f);

    std::vector<float> source = downsampleRgba(rgba, width, height, workWidth, workHeight);

    // ---- depth + circle of confusion -------------------------------------
    std::vector<float> depthWork(static_cast<size_t>(workWidth) * workHeight, 0.0f);
    const bool centerMode = !hasDepth;
    if (hasDepth) {
        std::vector<float> depthFull(static_cast<size_t>(depthWidth) * depthHeight, 0.0f);
        for (size_t index = 0; index < depthFull.size(); index++) {
            depthFull[index] = depth[index] * (1.0f / 255.0f);
        }
        int minimum = 255, maximum = 0;
        for (size_t index = 0; index < depthLength; index++) {
            minimum = std::min<int>(minimum, depth[index]);
            maximum = std::max<int>(maximum, depth[index]);
        }
        const float span = std::max(1.0f, static_cast<float>(maximum - minimum));
        for (size_t index = 0; index < depthFull.size(); index++) {
            depthFull[index] = clampF((depthFull[index] * 255.0f - minimum) / span, 0.0f, 1.0f);
        }
#pragma omp parallel for schedule(static)
        for (int y = 0; y < workHeight; y++) {
            const float v = (y + 0.5f) / workHeight;
            for (int x = 0; x < workWidth; x++) {
                const float u = (x + 0.5f) / workWidth;
                depthWork[y * workWidth + x] =
                    sampleGray(depthFull, depthWidth, depthHeight, u, v);
            }
        }
    } else {
#pragma omp parallel for schedule(static)
        for (int y = 0; y < workHeight; y++) {
            const float ny = (y + 0.5f) / workHeight - 0.46f;
            for (int x = 0; x < workWidth; x++) {
                const float nx = (x + 0.5f) / workWidth - 0.5f;
                const float distance = std::sqrt(nx * nx + ny * ny);
                depthWork[y * workWidth + x] = clampF(distance / 0.62f, 0.0f, 1.0f);
            }
        }
    }

    std::vector<float> coc(static_cast<size_t>(workWidth) * workHeight, 0.0f);
    std::vector<float> sharp(static_cast<size_t>(workWidth) * workHeight, 0.0f);
    std::vector<float> background(static_cast<size_t>(workWidth) * workHeight, 0.0f);
#pragma omp parallel for schedule(static)
    for (int y = 0; y < workHeight; y++) {
        for (int x = 0; x < workWidth; x++) {
            const int index = y * workWidth + x;
            const float value = cocAt(depthWork[index], settings, centerMode, apertureGain);
            coc[index] = value;
            sharp[index] = smoothstep01(clampF(1.0f - value * 2.6f, 0.0f, 1.0f));
        }
    }
    // A small protective margin around the subject keeps antialiased silhouette
    // pixels out of the background plate, which otherwise produce a coloured
    // fringe once the plate is convolved.
    {
        const int expand = std::max(2, static_cast<int>(std::lround(
            std::min(workWidth, workHeight) * 0.004f)));
        maxFilter(sharp, workWidth, workHeight, expand);
#pragma omp parallel for schedule(static)
        for (size_t index = 0; index < sharp.size(); index++) {
            background[index] = 1.0f - clampF(sharp[index], 0.0f, 1.0f);
        }
    }

    const float baseRadius = (2.0f + 34.0f * settings.blur *
        std::pow(1.5f / std::max(settings.aperture, 1.2f), 0.40f)) *
        std::max(1.0f, std::max(workWidth, workHeight) / 1000.0f);

    // ---- background plate: replace the sharp subject with a smooth fill ---
    std::vector<float> weighted(static_cast<size_t>(workWidth) * workHeight * 4, 0.0f);
    double weightTotal = 0.0;
    double colorTotal[3] = {0.0, 0.0, 0.0};
#pragma omp parallel for schedule(static)
    for (int y = 0; y < workHeight; y++) {
        for (int x = 0; x < workWidth; x++) {
            const int index = y * workWidth + x;
            const float weight = background[index];
            for (int channel = 0; channel < 3; channel++) {
                weighted[index * 4 + channel] = source[index * 3 + channel] * weight;
            }
            weighted[index * 4 + 3] = weight;
        }
    }
    for (int y = 0; y < workHeight; y++) {
        for (int x = 0; x < workWidth; x++) {
            const int index = y * workWidth + x;
            weightTotal += weighted[index * 4 + 3];
            for (int channel = 0; channel < 3; channel++) {
                colorTotal[channel] += weighted[index * 4 + channel];
            }
        }
    }
    const int fillRadius = std::max(2, std::min(48,
        static_cast<int>(std::lround(baseRadius * 0.45f)) + 2));
    boxBlur(weighted, workWidth, workHeight, fillRadius, 4, 2);
    std::vector<float> clean(source.size(), 0.0f);
    float meanColor[3] = {0.0f, 0.0f, 0.0f};
    if (weightTotal > 1e-3) {
        for (int channel = 0; channel < 3; channel++) {
            meanColor[channel] = static_cast<float>(colorTotal[channel] / weightTotal);
        }
    } else {
        double total[3] = {0.0, 0.0, 0.0};
        for (size_t index = 0; index < source.size(); index++) total[index % 3] += source[index];
        const double count = std::max(1.0, static_cast<double>(source.size() / 3));
        for (int channel = 0; channel < 3; channel++) {
            meanColor[channel] = static_cast<float>(total[channel] / count);
        }
    }
#pragma omp parallel for schedule(static)
    for (int y = 0; y < workHeight; y++) {
        for (int x = 0; x < workWidth; x++) {
            const int index = y * workWidth + x;
            const float denominator = weighted[index * 4 + 3];
            const float backgroundWeight = background[index];
            for (int channel = 0; channel < 3; channel++) {
                const float fill = denominator > 1e-3f
                    ? weighted[index * 4 + channel] / denominator : meanColor[channel];
                clean[index * 3 + channel] = source[index * 3 + channel] * backgroundWeight +
                    fill * (1.0f - backgroundWeight);
            }
        }
    }

    // ---- three-level aperture convolution ---------------------------------
    std::vector<float> result = clean;
    const float levels[3] = {0.40f, 0.70f, 1.00f};
    for (int levelIndex = 0; levelIndex < 3; levelIndex++) {
        const float level = levels[levelIndex];
        const int radius = std::max(1, static_cast<int>(std::lround(baseRadius * level)));
        std::vector<float> blurred = discBlur(clean, workWidth, workHeight,
            radius, settings.shape);
        const float threshold = (1.0f - level) * 0.20f;
        const float denominator = level + 0.05f;
#pragma omp parallel for schedule(static)
        for (int y = 0; y < workHeight; y++) {
            for (int x = 0; x < workWidth; x++) {
                const int index = y * workWidth + x;
                const float alpha = clampF((coc[index] - threshold) / denominator, 0.0f, 1.0f);
                if (alpha <= 0.0f) continue;
                for (int channel = 0; channel < 3; channel++) {
                    result[index * 3 + channel] = result[index * 3 + channel] * (1.0f - alpha) +
                        blurred[index * 3 + channel] * alpha;
                }
            }
        }
    }

    // ---- additive aperture-shaped highlight discs -------------------------
    if (settings.bokeh > 0.001f) {
        std::vector<float> luminance(static_cast<size_t>(workWidth) * workHeight, 0.0f);
        std::vector<float> mask(static_cast<size_t>(workWidth) * workHeight, 0.0f);
        for (int y = 0; y < workHeight; y++) {
            for (int x = 0; x < workWidth; x++) {
                const int index = y * workWidth + x;
                const float lum = 0.2126f * source[index * 3] +
                    0.7152f * source[index * 3 + 1] + 0.0722f * source[index * 3 + 2];
                luminance[index] = lum;
                const float highlight = clampF((lum - 0.72f) / 0.28f, 0.0f, 1.0f);
                mask[index] = highlight * clampF(coc[index] * 1.4f, 0.0f, 1.0f);
            }
        }
        std::vector<float> localMean = luminance;
        const int meanRadius = std::max(2, static_cast<int>(std::lround(4.2f * radiusScale)));
        boxBlur(localMean, workWidth, workHeight, meanRadius, 1, 2);

        std::vector<Peak> candidates;
        candidates.reserve(1024);
        for (int y = 1; y < workHeight - 1; y++) {
            for (int x = 1; x < workWidth - 1; x++) {
                const int index = y * workWidth + x;
                if (mask[index] <= 0.02f) continue;
                const float prominence = clampF((luminance[index] - localMean[index]) * 4.0f, 0.0f, 1.0f);
                if (prominence <= 0.03f) continue;
                const float lum = luminance[index];
                if (lum < luminance[index - 1] || lum < luminance[index + 1] ||
                    lum < luminance[index - workWidth] || lum < luminance[index + workWidth] ||
                    lum < luminance[index - workWidth - 1] || lum < luminance[index - workWidth + 1] ||
                    lum < luminance[index + workWidth - 1] || lum < luminance[index + workWidth + 1]) {
                    continue;
                }
                const float weight = mask[index] * std::max(prominence, 0.15f);
                if (weight > 0.006f + 0.04f * (1.0f - settings.density)) {
                    candidates.push_back({weight, static_cast<float>(x), static_cast<float>(y)});
                }
            }
        }
        std::sort(candidates.begin(), candidates.end(),
            [](const Peak& a, const Peak& b) { return a.weight > b.weight; });

        // Spatial-hash non-maximum suppression: one bright light must not spawn
        // several additive discs, which would make exports too bright.
        const int suppression = std::max(4, static_cast<int>(std::lround(7.0f * radiusScale)));
        const int maxPeaks = static_cast<int>(80 + 640 * settings.density);
        struct Cell {
            long long key;
            std::vector<int> indices;
        };
        std::vector<Cell> cells;
        auto cellKey = [suppression](int gx, int gy) -> long long {
            return static_cast<long long>(gx) * 1000003LL + gy;
        };
        std::vector<Peak> peaks;
        peaks.reserve(static_cast<size_t>(maxPeaks));
        auto cellFind = [&cells](long long key) -> std::vector<int>* {
            for (Cell& cell : cells) {
                if (cell.key == key) return &cell.indices;
            }
            return nullptr;
        };
        for (const Peak& candidate : candidates) {
            if (static_cast<int>(peaks.size()) >= maxPeaks) break;
            const int gx = static_cast<int>(candidate.x) / suppression;
            const int gy = static_cast<int>(candidate.y) / suppression;
            bool blocked = false;
            for (int ox = -1; ox <= 1 && !blocked; ox++) {
                for (int oy = -1; oy <= 1 && !blocked; oy++) {
                    const std::vector<int>* bucket = cellFind(cellKey(gx + ox, gy + oy));
                    if (bucket == nullptr) continue;
                    for (int index : *bucket) {
                        const float dx = peaks[index].x - candidate.x;
                        const float dy = peaks[index].y - candidate.y;
                        if (dx * dx + dy * dy <
                            static_cast<float>(suppression * suppression)) {
                            blocked = true;
                            break;
                        }
                    }
                }
            }
            if (blocked) continue;
            const int index = static_cast<int>(peaks.size());
            peaks.push_back(candidate);
            const long long key = cellKey(gx, gy);
            bool stored = false;
            for (Cell& cell : cells) {
                if (cell.key == key) {
                    cell.indices.push_back(index);
                    stored = true;
                    break;
                }
            }
            if (!stored) {
                Cell cell;
                cell.key = key;
                cell.indices.push_back(index);
                cells.push_back(std::move(cell));
            }
        }

        // Low-frequency background colour, with highlights and the sharp
        // subject excluded. White lights take on this tint instead of staying
        // pure white in a coloured scene.
        const int bgWidth = std::max(1, std::min(320, workWidth));
        const int bgHeight = std::max(1, std::min(320, workHeight));
        std::vector<float> bgSource = downsampleRgb(source, workWidth, workHeight, bgWidth, bgHeight);
        std::vector<float> bgSharp = downsampleGray(sharp, workWidth, workHeight, bgWidth, bgHeight);
        std::vector<float> bgWeighted(static_cast<size_t>(bgWidth) * bgHeight * 4, 0.0f);
        for (int y = 0; y < bgHeight; y++) {
            for (int x = 0; x < bgWidth; x++) {
                const int index = y * bgWidth + x;
                const float lum = 0.2126f * bgSource[index * 3] +
                    0.7152f * bgSource[index * 3 + 1] + 0.0722f * bgSource[index * 3 + 2];
                const float weight = (1.0f - clampF((lum - 0.72f) / 0.28f, 0.0f, 1.0f)) *
                    (1.0f - clampF(bgSharp[index], 0.0f, 1.0f));
                for (int channel = 0; channel < 3; channel++) {
                    bgWeighted[index * 4 + channel] = bgSource[index * 3 + channel] * weight;
                }
                bgWeighted[index * 4 + 3] = weight;
            }
        }
        boxBlur(bgWeighted, bgWidth, bgHeight, 8, 4, 2);
        std::vector<float> bgColor(static_cast<size_t>(bgWidth) * bgHeight * 3, 0.0f);
        float bgMean[3] = {0.5f, 0.5f, 0.5f};
        double bgTotal[3] = {0.0, 0.0, 0.0};
        for (size_t index = 0; index < bgSource.size(); index++) bgTotal[index % 3] += bgSource[index];
        const double bgCount = std::max(1.0, static_cast<double>(bgSource.size() / 3));
        for (int channel = 0; channel < 3; channel++) {
            bgMean[channel] = static_cast<float>(bgTotal[channel] / bgCount);
        }
        for (int y = 0; y < bgHeight; y++) {
            for (int x = 0; x < bgWidth; x++) {
                const int index = y * bgWidth + x;
                const float denominator = bgWeighted[index * 4 + 3];
                for (int channel = 0; channel < 3; channel++) {
                    bgColor[index * 3 + channel] = denominator > 1e-3f
                        ? bgWeighted[index * 4 + channel] / denominator : bgMean[channel];
                }
            }
        }

        std::vector<float> overlay(static_cast<size_t>(workWidth) * workHeight * 3, 0.0f);
#ifdef VIVID_BOKEH_STANDALONE
        std::fprintf(stderr, "vivid_bokeh: candidates=%zu peaks=%zu\n",
            candidates.size(), peaks.size());
        for (const Peak& candidate : candidates) {
            std::fprintf(stderr, "  cand w=%.3f x=%.1f y=%.1f\n",
                candidate.weight, candidate.x, candidate.y);
        }
#endif
        const float discBase = (2.5f + 26.0f * std::max(settings.bokeh, 0.12f)) *
            std::max(1.0f, radiusScale) * settings.size;
        const float apertureFactor = std::pow(1.4f / std::max(settings.aperture, 1.2f), 0.45f);
        const float spherical = settings.spherical;

        for (size_t peakIndex = 0; peakIndex < peaks.size(); peakIndex++) {
            const Peak& peak = peaks[peakIndex];
            const int xi = std::max(0, std::min(workWidth - 1, static_cast<int>(std::lround(peak.x))));
            const int yi = std::max(0, std::min(workHeight - 1, static_cast<int>(std::lround(peak.y))));
            const int sourceIndex = yi * workWidth + xi;
            const float defocus = clampF(coc[sourceIndex] * 1.3f, 0.0f, 1.0f);
            if (defocus < 0.08f) continue;
            float radius = discBase * apertureFactor * (0.25f + 1.05f * defocus);
            if (radius < 1.2f * std::max(0.35f, radiusScale)) continue;
            const float jitter = 0.90f + 0.20f *
                (std::fmod(std::sin(static_cast<float>(peakIndex + 1) * 12.9898f) * 43758.5453f, 1.0f));
            radius = std::min(radius * jitter, 40.0f * std::max(radiusScale, 0.35f) * settings.size);
            radius = std::max(radius, 1.0f);

            const float edge = std::fabs(peak.x - workWidth * 0.5f) /
                std::max(1.0f, workWidth * 0.5f);
            float rotation = 0.0f;
            if (settings.shape >= 3) {
                rotation = std::fmod(static_cast<float>(peakIndex) * 0.61803398875f,
                    2.0f * kPi / settings.shape);
            }
            std::vector<Vec2> points = aperturePoints(peak.x, peak.y, radius, radius,
                settings.shape, rotation);

            float color[3];
            const float sourceMax = std::max(source[sourceIndex * 3],
                std::max(source[sourceIndex * 3 + 1], source[sourceIndex * 3 + 2]));
            const float sourceMin = std::min(source[sourceIndex * 3],
                std::min(source[sourceIndex * 3 + 1], source[sourceIndex * 3 + 2]));
            const float saturation = (sourceMax - sourceMin) / std::max(1e-4f, sourceMax);
            float bgSample[3] = {0.0f, 0.0f, 0.0f};
            {
                const float u = peak.x / workWidth;
                const float v = peak.y / workHeight;
                sampleRgb(bgColor, bgWidth, bgHeight, u, v, bgSample);
            }
            const float bgPeak = std::max(bgSample[0], std::max(bgSample[1], bgSample[2]));
            for (int channel = 0; channel < 3; channel++) {
                if (bgPeak > 0.08f) {
                    const float normalized = clampF(bgSample[channel] / bgPeak, 0.0f, 1.5f);
                    const float mix = 0.25f + 0.35f * (1.0f - saturation);
                    color[channel] = source[sourceIndex * 3 + channel] * (1.0f - mix) +
                        normalized * mix;
                } else {
                    color[channel] = source[sourceIndex * 3 + channel];
                }
                color[channel] = clampF(color[channel] * 0.85f + 0.15f, 0.0f, 1.0f);
            }

            float strength = clampF(peak.weight * (0.35f + 0.8f * std::max(settings.bokeh, 0.2f)),
                0.0f, 1.0f);
            strength *= 1.0f - 0.20f * edge * edge;

            float fillGain;
            float rimGain;
            float coreGain;
            float rimThickness;
            if (spherical >= 0.0f) {
                fillGain = 1.0f - 0.28f * spherical;
                rimGain = 1.0f + 0.90f * spherical;
                coreGain = 0.0f;
                rimThickness = std::max(1.0f, radius * (0.06f + 0.05f * spherical));
            } else {
                const float m = -spherical;
                fillGain = 1.0f - 0.35f * m;
                rimGain = 1.0f - 0.65f * m;
                coreGain = 0.85f * m;
                rimThickness = std::max(1.0f, radius * 0.05f);
            }

            float fillColor[3];
            for (int channel = 0; channel < 3; channel++) {
                fillColor[channel] = color[channel] * (strength * 0.95f * fillGain);
            }
            fillPolygon(overlay, workWidth, workHeight, points, fillColor, 1.0f);
            if (rimGain > 1.0f) {
                const float innerScale = std::max(0.20f, 1.0f - rimThickness / radius);
                std::vector<Vec2> inner = aperturePoints(peak.x, peak.y,
                    radius * innerScale, radius * innerScale, settings.shape, rotation);
                float rimColor[3];
                for (int channel = 0; channel < 3; channel++) {
                    rimColor[channel] = color[channel] * (strength * 0.55f * (rimGain - 1.0f));
                }
                fillRing(overlay, workWidth, workHeight, points, inner, rimColor, 1.0f);
                // Sparse onion rings: the reference adds one on every fifth disc.
                if (radius >= 16.0f * std::max(radiusScale, 0.35f) && peakIndex % 5 == 0) {
                    std::vector<Vec2> ring = aperturePoints(peak.x, peak.y,
                        radius * 0.68f, radius * 0.68f, settings.shape, rotation);
                    float ringColor[3];
                    for (int channel = 0; channel < 3; channel++) {
                        ringColor[channel] = color[channel] * (strength * 0.05f);
                    }
                    fillRing(overlay, workWidth, workHeight, ring, inner, ringColor, 1.0f);
                }
            }
            if (coreGain > 0.01f) {
                std::vector<Vec2> core = aperturePoints(peak.x, peak.y,
                    radius * 0.55f, radius * 0.55f, settings.shape, rotation);
                float coreColor[3];
                for (int channel = 0; channel < 3; channel++) {
                    coreColor[channel] = color[channel] *
                        std::min(1.0f, strength * (0.95f * fillGain + coreGain));
                }
                fillPolygon(overlay, workWidth, workHeight, core, coreColor, 1.0f);
            }
        }

        // A small halo hides polygon stair-steps without turning the discs into
        // a gaussian haze.
        std::vector<float> halo = overlay;
        const int haloRadius = std::max(1, static_cast<int>(std::lround(2.0f * std::max(radiusScale, 0.35f))));
        boxBlur(halo, workWidth, workHeight, haloRadius, 3, 1);
        for (size_t index = 0; index < overlay.size(); index++) {
            overlay[index] = clampF(overlay[index] * 0.65f + halo[index] * 0.35f, 0.0f, 1.0f);
        }
        // Background discs must stay behind the sharp subject.
        for (int y = 0; y < workHeight; y++) {
            for (int x = 0; x < workWidth; x++) {
                const int index = y * workWidth + x;
                const float weight = background[index];
                for (int channel = 0; channel < 3; channel++) {
                    result[index * 3 + channel] = clampF(
                        result[index * 3 + channel] + overlay[index * 3 + channel] * weight,
                        0.0f, 1.0f);
                }
            }
        }
    }

    // ---- full-resolution composite ---------------------------------------
    std::vector<float> depthFull;
    if (hasDepth) {
        depthFull.resize(static_cast<size_t>(depthWidth) * depthHeight);
        int minimum = 255, maximum = 0;
        for (size_t index = 0; index < depthLength; index++) {
            minimum = std::min<int>(minimum, depth[index]);
            maximum = std::max<int>(maximum, depth[index]);
        }
        const float span = std::max(1.0f, static_cast<float>(maximum - minimum));
        for (size_t index = 0; index < depthFull.size(); index++) {
            depthFull[index] = clampF((depth[index] - minimum) / span, 0.0f, 1.0f);
        }
    }

    std::vector<uint8_t> output(static_cast<size_t>(width) * height * 4, 0);
    uint8_t* out = output.data();

#pragma omp parallel for schedule(static)
    for (int y = 0; y < height; y++) {
        const float v = (y + 0.5f) / height;
        for (int x = 0; x < width; x++) {
            const float u = (x + 0.5f) / width;
            float depthValue;
            if (hasDepth) {
                depthValue = sampleGray(depthFull, depthWidth, depthHeight, u, v);
            } else {
                const float nx = u - 0.5f;
                const float ny = v - 0.46f;
                depthValue = clampF(std::sqrt(nx * nx + ny * ny) / 0.62f, 0.0f, 1.0f);
            }
            const float coc = cocAt(depthValue, settings, centerMode, apertureGain);
            const float sharpFull = smoothstep01(clampF(1.0f - coc * 2.6f, 0.0f, 1.0f));
            float effect[3];
            sampleRgb(result, workWidth, workHeight, u, v, effect);
            const int index = (y * width + x) * 4;
            for (int channel = 0; channel < 3; channel++) {
                const float original = rgba[index + channel] * (1.0f / 255.0f);
                const float value = original * sharpFull + effect[channel] * (1.0f - sharpFull);
                out[index + channel] = static_cast<uint8_t>(std::lround(clampF(value, 0.0f, 1.0f) * 255.0f));
            }
            out[index + 3] = rgba[index + 3];
        }
    }
    return output;
}

#ifndef VIVID_BOKEH_STANDALONE

static bool readNumber(napi_env env, napi_value object, const char* key, double* out) {
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, key, &value) != napi_ok || value == nullptr) return false;
    return napi_get_value_double(env, value, out) == napi_ok;
}

static bool readBuffer(napi_env env, napi_value value, const uint8_t** data, size_t* length) {
    bool isBuffer = false;
    if (napi_is_arraybuffer(env, value, &isBuffer) != napi_ok || !isBuffer) return false;
    void* pointer = nullptr;
    if (napi_get_arraybuffer_info(env, value, &pointer, length) != napi_ok ||
        pointer == nullptr || *length == 0) return false;
    *data = static_cast<const uint8_t*>(pointer);
    return true;
}

/**
 * render(rgba, width, height, depth, depthWidth, depthHeight, settings) -> ArrayBuffer
 */
static napi_value render(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7] = {};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 7) {
        return nullptr;
    }
    const uint8_t* rgba = nullptr;
    size_t rgbaLength = 0;
    if (!readBuffer(env, args[0], &rgba, &rgbaLength)) {
        napi_throw_error(env, nullptr, "vivid_bokeh: rgba must be an ArrayBuffer");
        return nullptr;
    }
    double widthValue = 0;
    double heightValue = 0;
    double depthWidthValue = 0;
    double depthHeightValue = 0;
    if (napi_get_value_double(env, args[1], &widthValue) != napi_ok ||
        napi_get_value_double(env, args[2], &heightValue) != napi_ok ||
        napi_get_value_double(env, args[4], &depthWidthValue) != napi_ok ||
        napi_get_value_double(env, args[5], &depthHeightValue) != napi_ok) {
        napi_throw_error(env, nullptr, "vivid_bokeh: invalid dimensions");
        return nullptr;
    }
    const int width = static_cast<int>(widthValue);
    const int height = static_cast<int>(heightValue);
    if (width <= 0 || height <= 0 ||
        rgbaLength < static_cast<size_t>(width) * height * 4) {
        napi_throw_error(env, nullptr, "vivid_bokeh: rgba is smaller than width*height*4");
        return nullptr;
    }
    const uint8_t* depth = nullptr;
    size_t depthLength = 0;
    const int depthWidth = static_cast<int>(depthWidthValue);
    const int depthHeight = static_cast<int>(depthHeightValue);
    const bool hasDepth = readBuffer(env, args[3], &depth, &depthLength) &&
        depthWidth > 0 && depthHeight > 0 &&
        depthLength >= static_cast<size_t>(depthWidth) * depthHeight;

    Settings settings;
    napi_value object = args[6];
    double number = 0;
    if (readNumber(env, object, "aperture", &number)) settings.aperture = static_cast<float>(number);
    if (readNumber(env, object, "blurStrength", &number)) settings.blur = static_cast<float>(number);
    if (readNumber(env, object, "bokehStrength", &number)) settings.bokeh = static_cast<float>(number);
    if (readNumber(env, object, "density", &number)) settings.density = static_cast<float>(number);
    if (readNumber(env, object, "size", &number)) settings.size = static_cast<float>(number);
    if (readNumber(env, object, "spherical", &number)) settings.spherical = static_cast<float>(number);
    if (readNumber(env, object, "focus", &number)) settings.focus = static_cast<float>(number);
    if (readNumber(env, object, "shape", &number)) settings.shape = static_cast<int>(number);

    std::vector<uint8_t> rendered = renderCore(rgba, width, height, depth, depthLength,
        depthWidth, depthHeight, hasDepth, settings);
    napi_value output = nullptr;
    void* destination = nullptr;
    if (napi_create_arraybuffer(env, rendered.size(), &destination, &output) != napi_ok ||
        destination == nullptr) {
        return nullptr;
    }
    std::memcpy(destination, rendered.data(), rendered.size());
    return output;
}

static napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"render", nullptr, render, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

NAPI_MODULE_X(vivid_bokeh, init, nullptr, 0)

#endif  // VIVID_BOKEH_STANDALONE
