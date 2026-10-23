/*
 * vivid_pixels - native per-pixel mask rasterisation for the VIVID editor.
 *
 * Why this module exists: an ArkTS typed-array loop costs roughly 0.4 us per
 * pixel (a 44 MP linear-gradient mask measured 18.9 s of `export-prep`), and a
 * 44 MP pixel pipeline costs ~0.75 us per pixel (33.1 s in one TaskPool task).
 * Both numbers are interpretation cost, not memory bandwidth, so the heat has
 * to leave ArkTS. This module owns the analytic mask component types and the
 * group composition; the ArkTS implementations stay in place as a fallback and
 * as the reference the C++ is written to match.
 *
 * Brush strokes deliberately stay in ArkTS: their cost is bounded by the
 * painted area (dab bounding boxes) rather than by the frame, and the reference
 * dab/flow accumulation is the one part where a float32-vs-double mismatch
 * would be hard to prove equivalent.
 *
 * ## Bit-exactness contract
 *
 * The ArkTS caller may run either path, so both must produce identical bytes:
 *  - every intermediate is `double`, in the same order as the ArkTS expression
 *    (`(x + offset - sx) * dx + (y + offset - sy) * dy) / len2`);
 *  - no FMA contraction (`-ffp-contract=off` in CMakeLists.txt): the ArkTS
 *    engine evaluates the products separately, so `dx*ca + dy*sa` must not be
 *    fused into one rounding step;
 *  - no libm divergence: `std::sqrt` is IEEE-correctly-rounded like
 *    `Math.sqrt`, but `Math.cos`/`Math.sin` are engine-specific, so the rotated
 *    radial's `ca`/`sa` are computed in ArkTS and passed in;
 *  - `Math.round` (half away from zero) is `std::round`, then the 0..255 clamp
 *    that `Uint8ClampedArray` assignment would apply.
 *
 * ## Contract
 *   rasterizeLinear(width, height, sx, sy, ex, ey, feather, modern)
 *       -> ArrayBuffer(width*height) of alpha bytes
 *   rasterizeRadial(width, height, cx, cy, rx, ry, ca, sa, feather, modern)
 *       -> ArrayBuffer(width*height) of alpha bytes
 *   invertOpacity(buffer, inverted, opacity) -> void   (in place)
 *   composeInto(dst, src, blendMode) -> void           (in place)
 *   remapGeometry(input, srcWidth, left, top, cropWidth, cropHeight, outputWidth,
 *                 outputHeight, rotation, flipH, flipV) -> ArrayBuffer
 *
 * `buffer`, `dst` and `src` are the underlying `ArrayBuffer`s (pass `.buffer`
 * from ArkTS), not the typed-array views.
 */
#include <napi/native_api.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>

namespace {

/** Native-side twin of the ArkTS `clampByte`. */
uint8_t clampByte(double value) {
    const double rounded = std::round(value);
    if (!(rounded > 0.0)) return 0;  // also swallows NaN
    if (rounded > 255.0) return 255;
    return static_cast<uint8_t>(rounded);
}

bool getNumber(napi_env env, napi_value value, double* out) {
    return value != nullptr && napi_get_value_double(env, value, out) == napi_ok;
}

bool getInt32(napi_env env, napi_value value, int32_t* out) {
    return value != nullptr && napi_get_value_int32(env, value, out) == napi_ok;
}

bool getBool(napi_env env, napi_value value, bool* out) {
    return value != nullptr && napi_get_value_bool(env, value, out) == napi_ok;
}

/** Expose `length` bytes of new ArrayBuffer memory, or nullptr on failure. */
bool makeBuffer(napi_env env, size_t length, napi_value* out, uint8_t** data) {
    void* raw = nullptr;
    if (napi_create_arraybuffer(env, length, &raw, out) != napi_ok || raw == nullptr) return false;
    *data = static_cast<uint8_t*>(raw);
    return true;
}

/** Underlying bytes of an ArrayBuffer argument (minLength is checked by callers). */
bool bufferBytes(napi_env env, napi_value value, uint8_t** data, size_t* length) {
    void* raw = nullptr;
    if (value == nullptr || napi_get_arraybuffer_info(env, value, &raw, length) != napi_ok || raw == nullptr) {
        return false;
    }
    *data = static_cast<uint8_t*>(raw);
    return true;
}

/**
 * Run `rows(y0, y1)` over the frame, splitting large rasters across cores.
 *
 * A 44 MP analytic gradient is a pure row-independent write, but one core
 * spends ~227 ms on it (measured on the API 26 emulator). Region rendering
 * rasterises the whole frame once and reuses it, so that first-tile cost is
 * paid once per mask revision; splitting it across up to 8 cores keeps the
 * first tile close to the old per-tile latency instead of adding a visible
 * pause. Small rasters stay serial: thread setup would cost more than the work,
 * and the byte output is identical either way (rows never overlap).
 */
template <typename RowFn>
void parallelRows(int height, size_t pixels, const RowFn& fn) {
    unsigned hardware = std::thread::hardware_concurrency();
    int workers = static_cast<int>(std::min<unsigned>(hardware, 8u));
    if (pixels < 4000000u || height < 256 || workers <= 1) {
        fn(0, height);
        return;
    }
    const int chunk = (height + workers - 1) / workers;
    std::vector<std::thread> pool;
    pool.reserve(static_cast<size_t>(workers));
    try {
        for (int start = 0; start < height; start += chunk) {
            const int end = std::min(height, start + chunk);
            pool.emplace_back([start, end, &fn]() { fn(start, end); });
        }
    } catch (...) {
        for (std::thread& worker : pool) {
            if (worker.joinable()) worker.join();
        }
        fn(0, height);
        return;
    }
    for (std::thread& worker : pool) {
        if (worker.joinable()) worker.join();
    }
}

/**
 * Linear gradient, mirroring `renderLinear` in MaskRasterCore.ets. The mask is
 * constant along lines perpendicular to (sx,sy)->(ex,ey), so `t0` is affine in
 * the pixel coordinate and the alpha profile crosses exactly three regions:
 * full, ramp, empty.
 */
void rasterizeLinearInto(uint8_t* out, int width, int height, double sx, double sy,
    double ex, double ey, double feather, bool modern) {
    const double dx = ex - sx;
    const double dy = ey - sy;
    const double len2 = dx * dx + dy * dy;
    if (len2 < 1.0) {
        if (!modern) std::memset(out, 255, static_cast<size_t>(width) * height);
        return;
    }
    const double clamped = std::max(0.0, std::min(0.5, feather));
    const double start = 0.5 - clamped;
    const double end = 0.5 + clamped;
    const double band = std::max(0.0001, end - start);
    const bool hard = clamped <= 0.0001;
    const double offset = modern ? 0.5 : 0.0;
    const auto rows = [&](int y0, int y1) {
        for (int y = y0; y < y1; y++) {
            uint8_t* row = out + static_cast<size_t>(y) * width;
            const double rowTerm = (y + offset - sy) * dy;
            for (int x = 0; x < width; x++) {
                const double t0 = ((x + offset - sx) * dx + rowTerm) / len2;
                const double t = std::max(0.0, std::min(1.0, t0));
                double alpha;
                if (hard) {
                    alpha = t < 0.5 ? 255.0 : 0.0;
                } else if (t <= start) {
                    alpha = 255.0;
                } else if (t >= end) {
                    alpha = 0.0;
                } else {
                    const double v = (t - start) / band;
                    alpha = 255.0 * (1.0 - (modern ? v * v * (3.0 - 2.0 * v) : v));
                }
                row[x] = clampByte(alpha);
            }
        }
    };
    parallelRows(height, static_cast<size_t>(width) * height, rows);
}

/** Radial gradient, mirroring `renderRadial`. `ca`/`sa` arrive precomputed. */
void rasterizeRadialInto(uint8_t* out, int width, int height, double cx, double cy,
    double rx, double ry, double ca, double sa, double feather, bool modern) {
    const double clamped = std::max(0.0, std::min(1.0, feather));
    const double inner = 1.0 - clamped;
    const bool hard = clamped <= 0.0001;
    const double offset = modern ? 0.5 : 0.0;
    const auto rows = [&](int y0, int y1) {
        for (int y = y0; y < y1; y++) {
            uint8_t* row = out + static_cast<size_t>(y) * width;
            const double dy = y + offset - cy;
            const double dySa = dy * sa;
            const double dyCa = dy * ca;
            for (int x = 0; x < width; x++) {
                const double dx = x + offset - cx;
                const double nx = (dx * ca + dySa) / rx;
                const double ny = (-dx * sa + dyCa) / ry;
                const double distance = std::sqrt(nx * nx + ny * ny);
                double alpha;
                if (hard) {
                    alpha = distance <= 1.0 ? 255.0 : 0.0;
                } else if (distance <= inner) {
                    alpha = 255.0;
                } else if (distance >= 1.0) {
                    alpha = 0.0;
                } else {
                    const double v = (distance - inner) / clamped;
                    alpha = 255.0 * (1.0 - (modern ? v * v * (3.0 - 2.0 * v) : v));
                }
                row[x] = clampByte(alpha);
            }
        }
    };
    parallelRows(height, static_cast<size_t>(width) * height, rows);
}

/** Whole-component inversion and amount, mirroring `rasterizeComponentCore`. */
void invertOpacityInto(uint8_t* data, size_t length, bool inverted, double opacity) {
    if (inverted) {
        for (size_t index = 0; index < length; index++) data[index] = static_cast<uint8_t>(255 - data[index]);
    }
    if (opacity < 1.0) {
        const double clamped = std::max(0.0, std::min(1.0, opacity));
        for (size_t index = 0; index < length; index++) {
            data[index] = clampByte(static_cast<double>(data[index]) * clamped);
        }
    }
}

/** Group composition, mirroring the combine branch in `rasterizeStructuredMaskCore`. */
void composeInto(uint8_t* dst, const uint8_t* src, size_t length, int32_t blendMode) {
    if (blendMode == 1) {
        for (size_t index = 0; index < length; index++) {
            const double value = std::round(static_cast<double>(dst[index]) *
                (255.0 - static_cast<double>(src[index])) / 255.0);
            dst[index] = value > 0.0 ? (value > 255.0 ? 255 : static_cast<uint8_t>(value)) : 0;
        }
    } else if (blendMode == 2) {
        for (size_t index = 0; index < length; index++) {
            dst[index] = clampByte(static_cast<double>(dst[index]) *
                static_cast<double>(src[index]) / 255.0);
        }
    } else {
        for (size_t index = 0; index < length; index++) {
            if (src[index] > dst[index]) dst[index] = src[index];
        }
    }
}

/**
 * Crop / quarter-turn / flip remap.
 *
 * `remapFrameToDisplay` in GeometryMath.ets first materialises two Int32 sample
 * planes (`wide`/`tall`, 2 * 4 bytes per output pixel -- 354 MB at 44 MP) and
 * then gathers through them; that measured 33-35 s for a 44 MP quarter turn.
 * The mapping is an exact integer bijection between the crop window and the
 * displayed frame (`outputWidth/Height` merely swap with the quarter turn, so
 * there is no resampling), so the inverse is evaluated inline here and the four
 * bytes are copied straight across: no tables, no interpolation, and the output
 * is byte-identical to the ArkTS path. Pixels whose inverse falls outside the
 * crop window stay at their initial 0, matching the zero-filled output the
 * ArkTS caller allocates.
 */
void remapGeometryInto(uint8_t* out, const uint8_t* input, size_t inputLength,
    int32_t srcWidth, int32_t left, int32_t top, int32_t cropWidth, int32_t cropHeight,
    int32_t outputWidth, int32_t outputHeight, int32_t rotation, bool flipH, bool flipV) {
    for (int32_t y = 0; y < outputHeight; y++) {
        uint8_t* dstRow = out + static_cast<size_t>(y) * outputWidth * 4;
        const int32_t frameY = flipV ? outputHeight - 1 - y : y;
        for (int32_t x = 0; x < outputWidth; x++) {
            const int32_t frameX = flipH ? outputWidth - 1 - x : x;
            int32_t cropX;
            int32_t cropY;
            if (rotation == 90) {
                cropX = frameY;
                cropY = cropHeight - 1 - frameX;
            } else if (rotation == 180) {
                cropX = cropWidth - 1 - frameX;
                cropY = cropHeight - 1 - frameY;
            } else if (rotation == 270) {
                cropX = cropWidth - 1 - frameY;
                cropY = frameX;
            } else {
                cropX = frameX;
                cropY = frameY;
            }
            if (cropX < 0 || cropY < 0 || cropX >= cropWidth || cropY >= cropHeight) continue;
            const size_t sourceIndex =
                (static_cast<size_t>(top + cropY) * srcWidth + (left + cropX)) * 4;
            if (sourceIndex + 4 > inputLength) continue;
            const uint8_t* src = input + sourceIndex;
            uint8_t* dst = dstRow + static_cast<size_t>(x) * 4;
            dst[0] = src[0];
            dst[1] = src[1];
            dst[2] = src[2];
            dst[3] = src[3];
        }
    }
}

napi_value rasterizeLinear(napi_env env, napi_callback_info info) {    size_t argc = 8;
    napi_value args[8] = {};
    double width = 0, height = 0, sx = 0, sy = 0, ex = 0, ey = 0, feather = 0;
    bool modern = true;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 8 ||
        !getNumber(env, args[0], &width) || !getNumber(env, args[1], &height) ||
        !getNumber(env, args[2], &sx) || !getNumber(env, args[3], &sy) ||
        !getNumber(env, args[4], &ex) || !getNumber(env, args[5], &ey) ||
        !getNumber(env, args[6], &feather) || !getBool(env, args[7], &modern)) {
        return nullptr;
    }
    const int w = static_cast<int>(width), h = static_cast<int>(height);
    if (w <= 0 || h <= 0) return nullptr;
    napi_value result = nullptr;
    uint8_t* data = nullptr;
    if (!makeBuffer(env, static_cast<size_t>(w) * h, &result, &data)) return nullptr;
    rasterizeLinearInto(data, w, h, sx, sy, ex, ey, feather, modern);
    return result;
}

napi_value rasterizeRadial(napi_env env, napi_callback_info info) {
    size_t argc = 10;
    napi_value args[10] = {};
    double width = 0, height = 0, cx = 0, cy = 0, rx = 0, ry = 0, ca = 0, sa = 0, feather = 0;
    bool modern = true;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 10 ||
        !getNumber(env, args[0], &width) || !getNumber(env, args[1], &height) ||
        !getNumber(env, args[2], &cx) || !getNumber(env, args[3], &cy) ||
        !getNumber(env, args[4], &rx) || !getNumber(env, args[5], &ry) ||
        !getNumber(env, args[6], &ca) || !getNumber(env, args[7], &sa) ||
        !getNumber(env, args[8], &feather) || !getBool(env, args[9], &modern)) {
        return nullptr;
    }
    const int w = static_cast<int>(width), h = static_cast<int>(height);
    if (w <= 0 || h <= 0 || rx == 0.0 || ry == 0.0) return nullptr;
    napi_value result = nullptr;
    uint8_t* data = nullptr;
    if (!makeBuffer(env, static_cast<size_t>(w) * h, &result, &data)) return nullptr;
    rasterizeRadialInto(data, w, h, cx, cy, rx, ry, ca, sa, feather, modern);
    return result;
}

/**
 * Lightcraft 参考笔刷（brush_dabs / push_dabs / accumulate，MIT）的 native 孪生。
 *
 * 逐位复刻 BrushRasterizer.ets 的 rasterizeReferenceBrushStroke：
 * - 相邻落笔点之间按 radius/4 插值打 dab；
 * - dab 覆盖 = smoothstep 硬度剖面（hard 之内为 1，之外 1 - t²(3-2t)）；
 * - 合成 = alpha += coverage * flow * (1 - alpha)，再 clamp 到 density；
 * - 写回 = round(alpha * 255)。
 *
 * 关键的位精确细节一个都不能省：Float32 累加器（不是 double——ArkTS 参考实现
 * 用 Float32Array 存带内累加值，写回时经 float 舍入，native 必须用同样的
 * float 才能逐位一致）、64 行分带、每带清零、只写 firstX..lastX。
 *
 * 输入 points 为扁平数组 [x0,y0,r0,h0, x1,y1,r1,h1, ...]（归一化坐标 + 短边
 * 半径比例 + 硬度），输出写入 caller 提供的 width*height alpha 缓冲（累加到
 * 其上，与参考实现同一语义：caller 负责先清/带内清）。
 */
void rasterizeReferenceBrushInto(uint8_t* out, int width, int height,
    const double* points, int pointCount, double flow, double density) {
    if (pointCount <= 0 || width < 1 || height < 1) return;
    const double radius = std::max(0.5, points[2] * static_cast<double>(std::min(width, height)));
    const double hard = radius * std::max(0.0, std::min(1.0, points[3]));
    const double spacing = std::max(0.5, radius / 4.0);
    const double paint = std::max(0.0, std::min(1.0, flow));
    const double limit = std::max(0.0, std::min(1.0, density));
    if (paint <= 0.0 || limit <= 0.0) return;
    const float fLimit = static_cast<float>(limit);

    // 包围带：只有这些行可能被标记（与参考实现同一钳制口径）。
    double boundTopF = static_cast<double>(height), boundBottomF = 0.0;
    for (int index = 0; index < pointCount; index++) {
        const double y = points[index * 4 + 1] * static_cast<double>(height);
        if (!std::isfinite(y)) continue;
        boundTopF = std::min(boundTopF, std::floor(y - radius));
        boundBottomF = std::max(boundBottomF, std::ceil(y + radius));
    }
    int boundTop = static_cast<int>(boundTopF);
    int boundBottom = static_cast<int>(boundBottomF);
    if (boundBottom <= boundTop) return;
    boundTop = std::max(0, boundTop);
    boundBottom = std::min(height, boundBottom);

    const int bandHeight = std::min(64, height);
    std::vector<float> alpha(static_cast<size_t>(width) * bandHeight, 0.0f);

    for (int bandTop = (boundTop / bandHeight) * bandHeight; bandTop < boundBottom; bandTop += bandHeight) {
        const int bandBottom = std::min(height, bandTop + bandHeight);
        std::fill(alpha.begin(), alpha.end(), 0.0f);
        int firstX = width, lastX = 0;
        double previousX = 0.0, previousY = 0.0;
        bool started = false;

        std::unique_ptr<double[]> falloff;
    auto stamp = [&](double cx, double cy) {
            if (cy + radius < static_cast<double>(bandTop) || cy - radius >= static_cast<double>(bandBottom)) return;
            const int left = std::max(0, static_cast<int>(std::floor(cx - radius)));
            const int right = std::min(width, static_cast<int>(std::ceil(cx + radius)));
            if (right <= left) return;
            const int top = std::max(bandTop, static_cast<int>(std::floor(cy - radius)));
            const int bottom = std::min(bandBottom, static_cast<int>(std::ceil(cy + radius)));
            // 参考实现（JS）现在用 128 级衰减 LUT：内圈覆盖=1，外圈按
            // smoothstep 采样。native 必须用同一张表才能逐字节对齐，否则校验
            // 一直 mismatch=component，加速路径永远启用不了。
            const double span = std::max(0.00001, radius - hard);
            const int falloffLut = 128;
            if (falloff == nullptr) {
                falloff = std::make_unique<double[]>(falloffLut + 1);
                for (int index = 0; index <= falloffLut; index++) {
                    const double distance = radius * index / falloffLut;
                    if (distance <= hard) {
                        falloff[index] = 1.0;
                    } else {
                        const double t = std::max(0.0, std::min(1.0, (distance - hard) / span));
                        falloff[index] = 1.0 - t * t * (3.0 - 2.0 * t);
                    }
                }
            }
            const double radiusSquared = radius * radius;
            for (int y = top; y < bottom; y++) {
                for (int x = left; x < right; x++) {
                    const double dx = x + 0.5 - cx;
                    const double dy = y + 0.5 - cy;
                    const double squared = dx * dx + dy * dy;
                    if (squared > radiusSquared) continue;
                    const double distance = std::sqrt(squared);
                    int lutIndex = static_cast<int>(distance / radius * falloffLut);
                    if (lutIndex > falloffLut) lutIndex = falloffLut;
                    const double coverage = falloff[lutIndex];
                    float& cell = alpha[static_cast<size_t>(y - bandTop) * width + x];
                    // 与参考实现一致：float 累加器上的 min(limit, a + c*p*(1-a))。
                    const float next = static_cast<float>(
                        static_cast<double>(cell) + coverage * paint * (1.0 - static_cast<double>(cell)));
                    cell = next < fLimit ? next : fLimit;
                }
            }
            if (left < firstX) firstX = left;
            if (right > lastX) lastX = right;
        };

        for (int index = 0; index < pointCount; index++) {
            const double x = points[index * 4] * static_cast<double>(width);
            const double y = points[index * 4 + 1] * static_cast<double>(height);
            if (!std::isfinite(x) || !std::isfinite(y)) continue;
            if (started) {
                const double distance = std::hypot(x - previousX, y - previousY);
                if (distance > 1e-6) {
                    const int count = static_cast<int>(std::min(1000000.0, std::ceil(distance / spacing)));
                    for (int k = 1; k < count; k++) {
                        stamp(previousX + (x - previousX) * static_cast<double>(k) / static_cast<double>(count),
                              previousY + (y - previousY) * static_cast<double>(k) / static_cast<double>(count));
                    }
                }
            }
            stamp(x, y);
            previousX = x;
            previousY = y;
            started = true;
        }

        for (int y = bandTop; y < bandBottom; y++) {
            const size_t source = static_cast<size_t>(y - bandTop) * width;
            uint8_t* dest = out + static_cast<size_t>(y) * width;
            // 与参考实现一致：直接赋值（不是 max）——caller 每笔前已清边界带。
            // ArkTS Math.round 是"floor(x+0.5)"口径（对 .5 向 +∞），不是
            // lround 的四舍五入远离零；先提升到 double 再 floor(x+0.5)。
            for (int x = firstX; x < lastX; x++) {
                const double scaled = static_cast<double>(alpha[source + x]) * 255.0;
                dest[x] = static_cast<uint8_t>(std::floor(scaled + 0.5));
            }
        }
    }
}

/**
 * 参考笔刷栅格化入口：输入扁平点数组（Uint8ClampedArray 由 ArkTS 侧传入，
 * 这里要求 ArrayBuffer），输出新建的 width*height alpha 缓冲（非累加：整体
 * 重画，调用方拿到后自己按 blend 模式合成）。
 */
napi_value rasterizeBrushStroke(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {};
    double width = 0, height = 0, flow = 1, density = 1;
    uint8_t* pointBytes = nullptr;
    size_t pointLength = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 5 ||
        !getNumber(env, args[0], &width) || !getNumber(env, args[1], &height) ||
        !bufferBytes(env, args[2], &pointBytes, &pointLength) ||
        !getNumber(env, args[3], &flow) || !getNumber(env, args[4], &density)) {
        return nullptr;
    }
    const int w = static_cast<int>(width), h = static_cast<int>(height);
    if (w <= 0 || h <= 0) return nullptr;
    // points 是 Float64Array 的字节视图。
    const size_t pointCount = pointLength / (4 * sizeof(double));
    if (pointCount <= 0) return nullptr;
    napi_value result = nullptr;
    uint8_t* data = nullptr;
    if (!makeBuffer(env, static_cast<size_t>(w) * h, &result, &data)) return nullptr;
    // makeBuffer 的内存未初始化：栅格化只写包围带内的 [firstX,lastX) 列，带外
    // 必须显式清零——ArkTS 侧用 scratch.set() 整帧搬入，mode 0 的 max 合成会
    // 把带外垃圾一并取进去（实测 23x17 探针 ref=235 vs nat=253 即此因）。
    std::memset(data, 0, static_cast<size_t>(w) * h);
    rasterizeReferenceBrushInto(data, w, h, reinterpret_cast<const double*>(pointBytes),
        static_cast<int>(pointCount), flow, density);
    return result;
}

napi_value invertOpacity(napi_env env, napi_callback_info info) {    size_t argc = 3;
    napi_value args[3] = {};
    uint8_t* data = nullptr;
    size_t length = 0;
    bool inverted = false;
    double opacity = 1;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 3 ||
        !bufferBytes(env, args[0], &data, &length) || !getBool(env, args[1], &inverted) ||
        !getNumber(env, args[2], &opacity) || length == 0) {
        return nullptr;
    }
    invertOpacityInto(data, length, inverted, opacity);
    return nullptr;
}

napi_value compose(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    uint8_t* dst = nullptr;
    uint8_t* src = nullptr;
    size_t dstLength = 0, srcLength = 0;
    int32_t blendMode = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 3 ||
        !bufferBytes(env, args[0], &dst, &dstLength) || !bufferBytes(env, args[1], &src, &srcLength) ||
        !getInt32(env, args[2], &blendMode) || dstLength == 0 || srcLength != dstLength) {
        return nullptr;
    }
    composeInto(dst, src, dstLength, blendMode);
    return nullptr;
}

napi_value remapGeometry(napi_env env, napi_callback_info info) {
    size_t argc = 11;
    napi_value args[11] = {};
    uint8_t* input = nullptr;
    size_t inputLength = 0;
    double srcWidth = 0, left = 0, top = 0, cropWidth = 0, cropHeight = 0;
    double outputWidth = 0, outputHeight = 0, rotation = 0;
    bool flipH = false, flipV = false;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 11 ||
        !bufferBytes(env, args[0], &input, &inputLength) ||
        !getNumber(env, args[1], &srcWidth) || !getNumber(env, args[2], &left) ||
        !getNumber(env, args[3], &top) || !getNumber(env, args[4], &cropWidth) ||
        !getNumber(env, args[5], &cropHeight) || !getNumber(env, args[6], &outputWidth) ||
        !getNumber(env, args[7], &outputHeight) || !getNumber(env, args[8], &rotation) ||
        !getBool(env, args[9], &flipH) || !getBool(env, args[10], &flipV)) {
        return nullptr;
    }
    const int32_t outW = static_cast<int32_t>(outputWidth);
    const int32_t outH = static_cast<int32_t>(outputHeight);
    if (outW <= 0 || outH <= 0) return nullptr;
    napi_value result = nullptr;
    uint8_t* data = nullptr;
    if (!makeBuffer(env, static_cast<size_t>(outW) * outH * 4, &result, &data)) return nullptr;
    remapGeometryInto(data, input, inputLength, static_cast<int32_t>(srcWidth),
        static_cast<int32_t>(left), static_cast<int32_t>(top), static_cast<int32_t>(cropWidth),
        static_cast<int32_t>(cropHeight), outW, outH, static_cast<int32_t>(rotation), flipH, flipV);
    return result;
}

/**
 * Stored-raster resample, mirroring `renderBitmap` in MaskRasterCore.ets. The
 * raster already spans the source frame at the producer's own resolution, so
 * this is a plain bilinear upscale with no geometry term. `softness` < 1 adds
 * the reference softness curve, which goes through `pow`; the ArkTS caller
 * probes that case before adopting this routine because `Math.pow` and
 * `std::pow` may differ in the last ulp for some exponents.
 */
void sampleBitmapInto(uint8_t* out, const uint8_t* src, int bitmapWidth, int bitmapHeight,
    int width, int height, double softness) {
    const double scaleX = static_cast<double>(bitmapWidth) / static_cast<double>(width);
    const double scaleY = static_cast<double>(bitmapHeight) / static_cast<double>(height);
    const double maxX = static_cast<double>(bitmapWidth - 1);
    const double maxY = static_cast<double>(bitmapHeight - 1);
    const bool curved = softness < 1.0;
    for (int y = 0; y < height; y++) {
        double sampleY = (static_cast<double>(y) + 0.5) * scaleY - 0.5;
        if (!(sampleY > 0.0)) sampleY = 0.0;  // also swallows NaN
        if (sampleY > maxY) sampleY = maxY;
        const int y0 = static_cast<int>(std::floor(sampleY));
        const int y1 = std::min(bitmapHeight - 1, y0 + 1);
        const double fy = sampleY - static_cast<double>(y0);
        const uint8_t* row0 = src + static_cast<size_t>(y0) * bitmapWidth;
        const uint8_t* row1 = src + static_cast<size_t>(y1) * bitmapWidth;
        uint8_t* dst = out + static_cast<size_t>(y) * width;
        for (int x = 0; x < width; x++) {
            double sampleX = (static_cast<double>(x) + 0.5) * scaleX - 0.5;
            if (!(sampleX > 0.0)) sampleX = 0.0;
            if (sampleX > maxX) sampleX = maxX;
            const int x0 = static_cast<int>(std::floor(sampleX));
            const int x1 = std::min(bitmapWidth - 1, x0 + 1);
            const double fx = sampleX - static_cast<double>(x0);
            const double a00 = static_cast<double>(row0[x0]);
            const double a01 = static_cast<double>(row0[x1]);
            const double a10 = static_cast<double>(row1[x0]);
            const double a11 = static_cast<double>(row1[x1]);
            const double top = a00 + (a01 - a00) * fx;
            const double bottom = a10 + (a11 - a10) * fx;
            double alpha = top + (bottom - top) * fy;
            if (curved) {
                const double normalized = alpha / 255.0;
                const double value = normalized <= 0.5
                    ? 0.5 * std::pow(normalized * 2.0, softness)
                    : 1.0 - 0.5 * std::pow((1.0 - normalized) * 2.0, softness);
                alpha = 255.0 * value;
            }
            dst[x] = clampByte(alpha);
        }
    }
}

/**
 * Source-rect crop + resample of a full-frame mask alpha plane.
 *
 * Region (zoom tile) rendering rasterises each mask once at full-frame
 * resolution and then reuses it for every tile. `sampleBitmapInto` above maps
 * the whole bitmap; this one maps only `[rectX, rectY, rectW, rectH]` of the
 * source frame into `dstW x dstH`, using the same pixel-centre bilinear rule.
 * At 1:1 with integer bounds every sample lands exactly on a source pixel, so
 * the result is a plain crop and is byte-identical to re-rasterising the tile.
 */
void cropScaleAlphaInto(uint8_t* out, const uint8_t* src, int srcWidth, int srcHeight,
    int rectX, int rectY, int rectWidth, int rectHeight, int dstWidth, int dstHeight) {
    if (rectX < 0) { rectWidth += rectX; rectX = 0; }
    if (rectY < 0) { rectHeight += rectY; rectY = 0; }
    if (rectX + rectWidth > srcWidth) rectWidth = srcWidth - rectX;
    if (rectY + rectHeight > srcHeight) rectHeight = srcHeight - rectY;
    if (rectWidth <= 0 || rectHeight <= 0) return;
    const double scaleX = static_cast<double>(rectWidth) / static_cast<double>(dstWidth);
    const double scaleY = static_cast<double>(rectHeight) / static_cast<double>(dstHeight);
    const double maxX = static_cast<double>(rectX + rectWidth - 1);
    const double maxY = static_cast<double>(rectY + rectHeight - 1);
    for (int y = 0; y < dstHeight; y++) {
        double sampleY = static_cast<double>(rectY) +
            (static_cast<double>(y) + 0.5) * scaleY - 0.5;
        if (!(sampleY > static_cast<double>(rectY))) sampleY = static_cast<double>(rectY);
        if (sampleY > maxY) sampleY = maxY;
        const int y0 = static_cast<int>(std::floor(sampleY));
        const int y1 = std::min(rectY + rectHeight - 1, y0 + 1);
        const double fy = sampleY - static_cast<double>(y0);
        const uint8_t* row0 = src + static_cast<size_t>(y0) * srcWidth;
        const uint8_t* row1 = src + static_cast<size_t>(y1) * srcWidth;
        uint8_t* dst = out + static_cast<size_t>(y) * dstWidth;
        for (int x = 0; x < dstWidth; x++) {
            double sampleX = static_cast<double>(rectX) +
                (static_cast<double>(x) + 0.5) * scaleX - 0.5;
            if (!(sampleX > static_cast<double>(rectX))) sampleX = static_cast<double>(rectX);
            if (sampleX > maxX) sampleX = maxX;
            const int x0 = static_cast<int>(std::floor(sampleX));
            const int x1 = std::min(rectX + rectWidth - 1, x0 + 1);
            const double fx = sampleX - static_cast<double>(x0);
            const double a00 = static_cast<double>(row0[x0]);
            const double a01 = static_cast<double>(row0[x1]);
            const double a10 = static_cast<double>(row1[x0]);
            const double a11 = static_cast<double>(row1[x1]);
            const double top = a00 + (a01 - a00) * fx;
            const double bottom = a10 + (a11 - a10) * fx;
            dst[x] = clampByte(top + (bottom - top) * fy);
        }
    }
}

napi_value cropScaleAlpha(napi_env env, napi_callback_info info) {
    size_t argc = 9;
    napi_value args[9] = {};
    uint8_t* src = nullptr;
    size_t srcLength = 0;
    double srcWidth = 0, srcHeight = 0, rectX = 0, rectY = 0;
    double rectWidth = 0, rectHeight = 0, dstWidth = 0, dstHeight = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 9 ||
        !bufferBytes(env, args[0], &src, &srcLength) ||
        !getNumber(env, args[1], &srcWidth) || !getNumber(env, args[2], &srcHeight) ||
        !getNumber(env, args[3], &rectX) || !getNumber(env, args[4], &rectY) ||
        !getNumber(env, args[5], &rectWidth) || !getNumber(env, args[6], &rectHeight) ||
        !getNumber(env, args[7], &dstWidth) || !getNumber(env, args[8], &dstHeight)) {
        return nullptr;
    }
    const int32_t sw = static_cast<int32_t>(srcWidth), sh = static_cast<int32_t>(srcHeight);
    const int32_t dw = static_cast<int32_t>(dstWidth), dh = static_cast<int32_t>(dstHeight);
    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return nullptr;
    if (srcLength < static_cast<size_t>(sw) * static_cast<size_t>(sh)) return nullptr;
    napi_value result = nullptr;
    uint8_t* data = nullptr;
    if (!makeBuffer(env, static_cast<size_t>(dw) * static_cast<size_t>(dh), &result, &data)) return nullptr;
    cropScaleAlphaInto(data, src, sw, sh, static_cast<int32_t>(rectX), static_cast<int32_t>(rectY),
        static_cast<int32_t>(rectWidth), static_cast<int32_t>(rectHeight), dw, dh);
    return result;
}

napi_value sampleBitmap(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7] = {};
    uint8_t* bitmap = nullptr;
    uint8_t* out = nullptr;
    size_t bitmapLength = 0, outLength = 0;
    double bitmapWidth = 0, bitmapHeight = 0, width = 0, height = 0, softness = 1;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 7 ||
        !bufferBytes(env, args[0], &bitmap, &bitmapLength) ||
        !getNumber(env, args[1], &bitmapWidth) || !getNumber(env, args[2], &bitmapHeight) ||
        !bufferBytes(env, args[3], &out, &outLength) ||
        !getNumber(env, args[4], &width) || !getNumber(env, args[5], &height) ||
        !getNumber(env, args[6], &softness)) {
        return nullptr;
    }
    const int32_t bw = static_cast<int32_t>(bitmapWidth);
    const int32_t bh = static_cast<int32_t>(bitmapHeight);
    const int32_t w = static_cast<int32_t>(width);
    const int32_t h = static_cast<int32_t>(height);
    if (bw <= 0 || bh <= 0 || w <= 0 || h <= 0) return nullptr;
    if (bitmapLength < static_cast<size_t>(bw) * static_cast<size_t>(bh)) return nullptr;
    if (outLength < static_cast<size_t>(w) * static_cast<size_t>(h)) return nullptr;
    sampleBitmapInto(out, bitmap, bw, bh, w, h, softness);
    return nullptr;
}

napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        { "rasterizeLinear", nullptr, rasterizeLinear, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "rasterizeRadial", nullptr, rasterizeRadial, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "invertOpacity", nullptr, invertOpacity, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "composeInto", nullptr, compose, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "remapGeometry", nullptr, remapGeometry, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sampleBitmap", nullptr, sampleBitmap, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "cropScaleAlpha", nullptr, cropScaleAlpha, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "rasterizeBrushStroke", nullptr, rasterizeBrushStroke, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

}  // namespace

NAPI_MODULE_X(vivid_pixels, init, nullptr, 0)
