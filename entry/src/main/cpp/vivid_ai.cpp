/*
 * vivid_ai — local, offline subject/sky segmentation for the VIVID editor.
 *
 * Two small public models run through ncnn (BSD-3-Clause, Tencent/ncnn):
 *   kind 0 SUBJECT  U^2-NetP salient-object detection.
 *                   Weights: danielgatis/rembg official release (u2netp.onnx),
 *                   model: xuebinqin/U-2-Net, Apache-2.0.
 *   kind 1 SKY      skysegsmall_sim-opt-fp16 (U^2-Net-shaped small sky net).
 *                   xiongzhu666/Sky-Segmentation-and-Post-processing, MIT.
 *
 * Both are small (2.3 MB / 2.3 MB) and CPU-only here: the app's OpenGL ES
 * context is a UI/render surface, which says nothing about whether a Vulkan
 * compute device exists, so inference always uses the ncnn CPU backend.
 *
 * The module never touches the file system: ArkTS reads the model from
 * rawfile and hands the bytes in, which keeps the packaging and the hash
 * provenance check in one place (AiMaskModels.ets).
 *
 * Contract
 *   loadModel(kind, param, bin)  -> Promise<void>      (idempotent per kind)
 *   isLoaded(kind)               -> boolean
 *   segment(kind, rgba, w, h)    -> Promise<ArrayBuffer>
 *        header: uint32 LE width, uint32 LE height, then width*height alpha bytes
 *   modelInfo()                  -> Array of per-kind metadata objects
 *   release()                    -> void                (drops every cached net)
 */
#include <napi/native_api.h>

#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "ncnn/datareader.h"
#include "ncnn/mat.h"
#include "ncnn/net.h"

namespace {

constexpr int kKindCount = 2;

struct ModelSpec {
    const char* key;
    const char* displayName;
    const char* upstream;
    const char* license;
    int inputSize;
    const char* inputBlob;
    const char* outputBlob;
    // U^2-Net's own test pipeline divides the [0,1] image by its global maximum
    // before the ImageNet normalization; the sky network does not.
    bool divideByGlobalMax;
    // U^2-Net's reference also rescales the output to its own [min,max]
    // (normPRED). The sky network outputs a calibrated sigmoid probability, so
    // stretching it would turn "no sky at all" into a full-frame selection.
    bool rescaleOutputToRange;
};

    // ImageNet statistics, identically in both upstream references. ncnn's
    // substract_mean_normalize runs on the 0..255 pixel range (from_pixels does
    // NOT scale), so the reference multiplies the mean by 255 and folds the /255
    // into the scale — missing that fed the networks inputs ~255x off and made
    // the sky selection meaningless.
    constexpr float kMean[3] = {0.485f * 255.0f, 0.456f * 255.0f, 0.406f * 255.0f};
    constexpr float kStdDev[3] = {0.229f * 255.0f, 0.224f * 255.0f, 0.225f * 255.0f};

    // 网络若在归一化之前已经用 global-max 把输入压到 0..1（u2netp），均值/方差就
    // 必须用 0..1 版本：再乘 255 会让每个像素都变成约 -2.1 的常数，输出是一只
    // 只在画面中间的小斑块（主体蒙版失效的真因）。
    constexpr float kMeanUnit[3] = {0.485f, 0.456f, 0.406f};
    constexpr float kStdDevUnit[3] = {0.229f, 0.224f, 0.225f};

const ModelSpec kSpecs[kKindCount] = {
    { "subject", "U^2-NetP salient object", "xuebinqin/U-2-Net (weights: danielgatis/rembg)",
      "Apache-2.0", 320, "in0", "out0", true, true },
    { "sky", "skysegsmall (U^2-Net shaped)", "xiongzhu666/Sky-Segmentation-and-Post-processing",
      "MIT", 384, "input.1", "1959", false, false },
};

struct LoadedModel {
    ncnn::Net net;
    // ncnn may keep references into the weight stream for some storage modes,
    // so the bytes that produced this net stay alive with it.
    std::vector<uint8_t> paramBytes;
    std::vector<uint8_t> binBytes;
    bool ready = false;
};

std::mutex g_mutex;
LoadedModel g_models[kKindCount];
/** Depth Anything V2 Small, kept in its own slot: it is not a mask model. */
LoadedModel g_depth;
constexpr int kDepthInput = 518;
constexpr float kDepthMean[3] = {123.675f, 116.28f, 103.53f};
constexpr float kDepthNorm[3] = {0.01712475f, 0.0175f, 0.01742919f};

bool kindValid(int kind) { return kind >= 0 && kind < kKindCount; }

bool getInt32(napi_env env, napi_value value, int32_t* out) {
    if (napi_get_value_int32(env, value, out) != napi_ok) return false;
    return true;
}

bool copyArrayBuffer(napi_env env, napi_value value, std::vector<uint8_t>* out) {
    bool isBuffer = false;
    if (napi_is_arraybuffer(env, value, &isBuffer) != napi_ok || !isBuffer) return false;
    void* data = nullptr;
    size_t length = 0;
    if (napi_get_arraybuffer_info(env, value, &data, &length) != napi_ok || data == nullptr || length == 0) {
        return false;
    }
    out->assign(static_cast<uint8_t*>(data), static_cast<uint8_t*>(data) + length);
    return true;
}

void setNumber(napi_env env, napi_value object, const char* key, double value) {
    napi_value number = nullptr;
    if (napi_create_double(env, value, &number) == napi_ok) napi_set_named_property(env, object, key, number);
}

void setString(napi_env env, napi_value object, const char* key, const char* value) {
    napi_value text = nullptr;
    if (napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &text) == napi_ok) {
        napi_set_named_property(env, object, key, text);
    }
}

void setBool(napi_env env, napi_value object, const char* key, bool value) {
    napi_value flag = nullptr;
    if (napi_get_boolean(env, value, &flag) == napi_ok) napi_set_named_property(env, object, key, flag);
}

/** Convert a single-channel float plane into 8-bit alpha.
 *
 * `rescale` reproduces U^2-Net's normPRED (min-max to the plane's own range),
 * which is what the reference test script does before saving. When false the
 * plane is treated as an already calibrated probability and simply clamped, so
 * a genuinely empty selection stays empty. */
std::vector<uint8_t> convertAlpha(const ncnn::Mat& plane, bool rescale) {
    const int width = plane.w;
    const int height = plane.h;
    std::vector<uint8_t> alpha(static_cast<size_t>(width) * height, 0);
    if (width <= 0 || height <= 0) return alpha;
    const float* data = plane.channel(0);
    if (data == nullptr) return alpha;
    const size_t count = static_cast<size_t>(width) * height;

    if (!rescale) {
        for (size_t index = 0; index < count; index++) {
            const float value = data[index];
            if (!std::isfinite(value)) continue;
            const float scaled = value * 255.0f;
            alpha[index] = static_cast<uint8_t>(scaled <= 0.0f ? 0.0f : (scaled >= 255.0f ? 255.0f : std::lround(scaled)));
        }
        return alpha;
    }

    float minimum = data[0];
    float maximum = data[0];
    for (size_t index = 1; index < count; index++) {
        const float value = data[index];
        if (!std::isfinite(value)) continue;
        if (value < minimum) minimum = value;
        if (value > maximum) maximum = value;
    }
    const float span = maximum - minimum;
    if (!(span > 1e-8f)) {
        const uint8_t flat = maximum > 0.5f ? 255 : 0;
        std::fill(alpha.begin(), alpha.end(), flat);
        return alpha;
    }
    const float scale = 255.0f / span;
    for (size_t index = 0; index < count; index++) {
        const float value = data[index];
        if (!std::isfinite(value)) continue;
        const float scaled = (value - minimum) * scale;
        alpha[index] = static_cast<uint8_t>(scaled <= 0.0f ? 0.0f : (scaled >= 255.0f ? 255.0f : std::lround(scaled)));
    }
    return alpha;
}

struct LoadWork {
    napi_deferred deferred = nullptr;
    napi_async_work asyncWork = nullptr;
    int kind = 0;
    std::vector<uint8_t> paramBytes;
    std::vector<uint8_t> binBytes;
    std::string error;
};

struct SegmentWork {
    napi_deferred deferred = nullptr;
    napi_async_work asyncWork = nullptr;
    int kind = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> rgba;
    std::vector<uint8_t> result;
    std::string error;
};

void executeLoad(napi_env /*env*/, void* data) {
    auto* work = static_cast<LoadWork*>(data);
    const ModelSpec& spec = kSpecs[work->kind];
    std::lock_guard<std::mutex> guard(g_mutex);
    LoadedModel& slot = g_models[work->kind];
    if (slot.ready) return;
    // DataReaderFromMemory advances the pointer it is given and requires an
    // lvalue, so the buffers are addressed through named pointers.
    const unsigned char* paramHead = work->paramBytes.data();
    const unsigned char* binHead = work->binBytes.data();
    ncnn::DataReaderFromMemory paramReader(paramHead);
    ncnn::DataReaderFromMemory binReader(binHead);
    slot.net.clear();
    slot.net.opt.use_vulkan_compute = false;
    // Keep the CPU path fully deterministic across the two device classes we
    // ship: fp16 storage is not available on every x86_64 build.
    slot.net.opt.use_fp16_packed = false;
    slot.net.opt.use_fp16_storage = false;
    slot.net.opt.use_fp16_arithmetic = false;
    slot.net.opt.num_threads = 4;
    if (slot.net.load_param(paramReader) != 0) {
        work->error = std::string("ncnn could not parse the ") + spec.key + " param file";
        return;
    }
    if (slot.net.load_model(binReader) != 0) {
        slot.net.clear();
        work->error = std::string("ncnn could not load the ") + spec.key + " weight file";
        return;
    }
    slot.paramBytes = std::move(work->paramBytes);
    slot.binBytes = std::move(work->binBytes);
    slot.ready = true;
}

void completeLoad(napi_env env, napi_status status, void* data) {
    auto* work = static_cast<LoadWork*>(data);
    if (status == napi_ok && work->error.empty()) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        napi_resolve_deferred(env, work->deferred, undefined);
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, work->error.empty() ? "model load cancelled" : work->error.c_str(),
            NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, work->deferred, message);
    }
    napi_delete_async_work(env, work->asyncWork);
    delete work;
}

void executeSegment(napi_env /*env*/, void* data) {
    auto* work = static_cast<SegmentWork*>(data);
    const ModelSpec& spec = kSpecs[work->kind];
    const int side = spec.inputSize;
    ncnn::Mat input;
    {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_models[work->kind].ready) {
            work->error = std::string("the ") + spec.key + " model is not loaded";
            return;
        }
        // ncnn resizes straight from the caller's proxy to the network's square
        // input, which is what both upstream references do.
        input = ncnn::Mat::from_pixels_resize(work->rgba.data(), ncnn::Mat::PIXEL_RGBA2RGB,
            static_cast<int>(work->width), static_cast<int>(work->height), side, side);
    }
    if (input.empty()) {
        work->error = "could not build the network input";
        return;
    }
    if (spec.divideByGlobalMax) {
        float maximum = 0.0f;
        for (int channel = 0; channel < input.c; channel++) {
            const float* plane = input.channel(channel);
            const int count = input.w * input.h;
            for (int index = 0; index < count; index++) {
                const float value = plane[index];
                if (value > maximum) maximum = value;
            }
        }
        if (maximum > 1e-6f) {
            const float inverse = 1.0f / maximum;
            for (int channel = 0; channel < input.c; channel++) {
                float* plane = input.channel(channel);
                const int count = input.w * input.h;
                for (int index = 0; index < count; index++) plane[index] *= inverse;
            }
        }
    }
    const float* meanSource = spec.divideByGlobalMax ? kMeanUnit : kMean;
    const float* stdSource = spec.divideByGlobalMax ? kStdDevUnit : kStdDev;
    const float meanValues[3] = {meanSource[0], meanSource[1], meanSource[2]};
    const float normValues[3] = {1.0f / stdSource[0], 1.0f / stdSource[1], 1.0f / stdSource[2]};
    input.substract_mean_normalize(meanValues, normValues);

    ncnn::Mat output;
    {
        std::lock_guard<std::mutex> guard(g_mutex);
        ncnn::Extractor extractor = g_models[work->kind].net.create_extractor();
        extractor.set_light_mode(true);
        if (extractor.input(spec.inputBlob, input) != 0) {
            work->error = "the network rejected its input blob";
            return;
        }
        if (extractor.extract(spec.outputBlob, output) != 0 || output.empty()) {
            work->error = std::string("the network produced no ") + spec.outputBlob + " blob";
            return;
        }
    }
    ncnn::Mat plane = output.c == 1 ? output : output.channel(0);
    if (plane.empty()) {
        work->error = "the network output has no channels";
        return;
    }
    std::vector<uint8_t> alpha = convertAlpha(plane, spec.rescaleOutputToRange);
    const uint32_t width = static_cast<uint32_t>(plane.w);
    const uint32_t height = static_cast<uint32_t>(plane.h);
    work->result.resize(8 + alpha.size());
    std::memcpy(work->result.data(), &width, 4);
    std::memcpy(work->result.data() + 4, &height, 4);
    if (!alpha.empty()) std::memcpy(work->result.data() + 8, alpha.data(), alpha.size());
}

void completeSegment(napi_env env, napi_status status, void* data) {
    auto* work = static_cast<SegmentWork*>(data);
    if (status == napi_ok && work->error.empty() && !work->result.empty()) {
        napi_value result = nullptr;
        void* destination = nullptr;
        if (napi_create_arraybuffer(env, work->result.size(), &destination, &result) == napi_ok && destination != nullptr) {
            std::memcpy(destination, work->result.data(), work->result.size());
            napi_resolve_deferred(env, work->deferred, result);
        } else {
            napi_value message = nullptr;
            napi_create_string_utf8(env, "could not allocate the mask result", NAPI_AUTO_LENGTH, &message);
            napi_reject_deferred(env, work->deferred, message);
        }
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, work->error.empty() ? "segmentation cancelled" : work->error.c_str(),
            NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, work->deferred, message);
    }
    napi_delete_async_work(env, work->asyncWork);
    delete work;
}

napi_value loadModel(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 3) return nullptr;
    int32_t kind = 0;
    if (!getInt32(env, args[0], &kind) || !kindValid(kind)) {
        napi_throw_error(env, nullptr, "unknown segmentation model kind");
        return nullptr;
    }
    auto* work = new LoadWork();
    work->kind = kind;
    if (!copyArrayBuffer(env, args[1], &work->paramBytes) || !copyArrayBuffer(env, args[2], &work->binBytes)) {
        delete work;
        napi_throw_error(env, nullptr, "the model files must be ArrayBuffers");
        return nullptr;
    }
    {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (g_models[kind].ready) {
            // Already resident: resolve immediately, still through a promise so
            // the ArkTS side has exactly one code path.
            napi_deferred deferred = nullptr;
            napi_value resolved = nullptr;
            if (napi_create_promise(env, &deferred, &resolved) != napi_ok) {
                delete work;
                return nullptr;
            }
            napi_value undefined = nullptr;
            napi_get_undefined(env, &undefined);
            napi_resolve_deferred(env, deferred, undefined);
            delete work;
            return resolved;
        }
    }
    napi_value promise = nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        return nullptr;
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "VividAiLoadModel", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_async_work(env, nullptr, resourceName, executeLoad, completeLoad, work, &work->asyncWork) != napi_ok ||
        napi_queue_async_work(env, work->asyncWork) != napi_ok) {
        delete work;
        return nullptr;
    }
    return promise;
}

napi_value segment(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 4) return nullptr;
    int32_t kind = 0;
    int32_t width = 0;
    int32_t height = 0;
    if (!getInt32(env, args[0], &kind) || !kindValid(kind)) {
        napi_throw_error(env, nullptr, "unknown segmentation model kind");
        return nullptr;
    }
    if (!getInt32(env, args[2], &width) || !getInt32(env, args[3], &height) || width <= 0 || height <= 0) {
        napi_throw_error(env, nullptr, "invalid source dimensions");
        return nullptr;
    }
    auto* work = new SegmentWork();
    work->kind = kind;
    work->width = static_cast<uint32_t>(width);
    work->height = static_cast<uint32_t>(height);
    if (!copyArrayBuffer(env, args[1], &work->rgba)) {
        delete work;
        napi_throw_error(env, nullptr, "the source pixels must be an ArrayBuffer");
        return nullptr;
    }
    const size_t expected = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    if (work->rgba.size() < expected) {
        delete work;
        napi_throw_error(env, nullptr, "the source buffer is smaller than width*height*4");
        return nullptr;
    }
    napi_value promise = nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) {
        delete work;
        return nullptr;
    }
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "VividAiSegment", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_async_work(env, nullptr, resourceName, executeSegment, completeSegment, work, &work->asyncWork) != napi_ok ||
        napi_queue_async_work(env, work->asyncWork) != napi_ok) {
        delete work;
        return nullptr;
    }
    return promise;
}

napi_value isLoaded(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_value result = nullptr;
    int32_t kind = 0;
    bool ready = false;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) == napi_ok && argc >= 1 &&
        getInt32(env, args[0], &kind) && kindValid(kind)) {
        std::lock_guard<std::mutex> guard(g_mutex);
        ready = g_models[kind].ready;
    }
    napi_get_boolean(env, ready, &result);
    return result;
}

/** Static metadata for the model provenance screen; no file access. */
napi_value modelInfo(napi_env env, napi_callback_info /*info*/) {
    napi_value list = nullptr;
    napi_create_array_with_length(env, kKindCount, &list);
    for (int kind = 0; kind < kKindCount; kind++) {
        const ModelSpec& spec = kSpecs[kind];
        napi_value entry = nullptr;
        napi_create_object(env, &entry);
        setNumber(env, entry, "kind", kind);
        setString(env, entry, "key", spec.key);
        setString(env, entry, "name", spec.displayName);
        setString(env, entry, "upstream", spec.upstream);
        setString(env, entry, "license", spec.license);
        setNumber(env, entry, "inputSize", spec.inputSize);
        setString(env, entry, "inputBlob", spec.inputBlob);
        setString(env, entry, "outputBlob", spec.outputBlob);
        setBool(env, entry, "divideByGlobalMax", spec.divideByGlobalMax);
        setBool(env, entry, "rescaleOutputToRange", spec.rescaleOutputToRange);
        setString(env, entry, "backend", "ncnn CPU");
        napi_set_element(env, list, kind, entry);
    }
    return list;
}

napi_value release(napi_env /*env*/, napi_callback_info /*info*/) {
    std::lock_guard<std::mutex> guard(g_mutex);
    for (int kind = 0; kind < kKindCount; kind++) {
        g_models[kind].net.clear();
        g_models[kind].paramBytes.clear();
        g_models[kind].paramBytes.shrink_to_fit();
        g_models[kind].binBytes.clear();
        g_models[kind].binBytes.shrink_to_fit();
        g_models[kind].ready = false;
    }
    g_depth.net.clear();
    g_depth.paramBytes.clear();
    g_depth.paramBytes.shrink_to_fit();
    g_depth.binBytes.clear();
    g_depth.binBytes.shrink_to_fit();
    g_depth.ready = false;
    return nullptr;
}

// ---------------------------------------------------------------------------
// Depth Anything V2 Small (DINOv2-S backbone, 518x518 input).
//
// The graph expects an ImageNet-normalised square RGB input and returns a
// 518x518 disparity plane (larger = nearer). It is a separate slot from the two
// mask models: the bokeh stage loads it lazily and can release it on its own.
// ---------------------------------------------------------------------------
struct DepthLoadWork {
    napi_deferred deferred = nullptr;
    napi_async_work asyncWork = nullptr;
    std::vector<uint8_t> paramBytes;
    std::vector<uint8_t> binBytes;
    std::string error;
};

struct DepthWork {
    napi_deferred deferred = nullptr;
    napi_async_work asyncWork = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t outputLongSide = 384;
    std::vector<uint8_t> rgba;
    std::vector<uint8_t> result;
    std::string error;
};

void executeDepthLoad(napi_env /*env*/, void* data) {
    auto* work = static_cast<DepthLoadWork*>(data);
    std::lock_guard<std::mutex> guard(g_mutex);
    if (g_depth.ready) return;
    const unsigned char* paramHead = work->paramBytes.data();
    const unsigned char* binHead = work->binBytes.data();
    ncnn::DataReaderFromMemory paramReader(paramHead);
    ncnn::DataReaderFromMemory binReader(binHead);
    g_depth.net.clear();
    g_depth.net.opt.use_vulkan_compute = false;
    g_depth.net.opt.use_fp16_packed = false;
    g_depth.net.opt.use_fp16_storage = false;
    g_depth.net.opt.use_fp16_arithmetic = false;
    g_depth.net.opt.num_threads = 4;
    if (g_depth.net.load_param(paramReader) != 0) {
        work->error = "ncnn could not parse the depth param file";
        return;
    }
    if (g_depth.net.load_model(binReader) != 0) {
        g_depth.net.clear();
        work->error = "ncnn could not load the depth weight file";
        return;
    }
    g_depth.paramBytes = std::move(work->paramBytes);
    g_depth.binBytes = std::move(work->binBytes);
    g_depth.ready = true;
}

void completeDepthLoad(napi_env env, napi_status status, void* data) {
    auto* work = static_cast<DepthLoadWork*>(data);
    if (status == napi_ok && work->error.empty()) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        napi_resolve_deferred(env, work->deferred, undefined);
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, work->error.empty() ? "depth model load cancelled" : work->error.c_str(),
            NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, work->deferred, message);
    }
    napi_delete_async_work(env, work->asyncWork);
    delete work;
}

/** Bilinear resize of a cropped float plane into 8-bit depth samples. */
void resizeDepthToBytes(const float* plane, int planeWidth, int planeHeight,
                        int left, int top, int cropWidth, int cropHeight,
                        float minimum, float span, int outWidth, int outHeight,
                        std::vector<uint8_t>* output) {
    output->resize(static_cast<size_t>(outWidth) * outHeight, 0);
    const float xRatio = static_cast<float>(cropWidth) / outWidth;
    const float yRatio = static_cast<float>(cropHeight) / outHeight;
    const float invSpan = 1.0f / std::max(span, 1e-6f);
    for (int y = 0; y < outHeight; y++) {
        const float sy = (y + 0.5f) * yRatio - 0.5f;
        const int y0 = std::max(0, std::min(cropHeight - 1, static_cast<int>(std::floor(sy))));
        const int y1 = std::min(cropHeight - 1, y0 + 1);
        const float fy = std::max(0.0f, std::min(1.0f, sy - y0));
        for (int x = 0; x < outWidth; x++) {
            const float sx = (x + 0.5f) * xRatio - 0.5f;
            const int x0 = std::max(0, std::min(cropWidth - 1, static_cast<int>(std::floor(sx))));
            const int x1 = std::min(cropWidth - 1, x0 + 1);
            const float fx = std::max(0.0f, std::min(1.0f, sx - x0));
            const int row0 = (top + y0) * planeWidth + left;
            const int row1 = (top + y1) * planeWidth + left;
            const float a = plane[row0 + x0];
            const float b = plane[row0 + x1];
            const float c = plane[row1 + x0];
            const float d = plane[row1 + x1];
            const float topValue = a + (b - a) * fx;
            const float bottomValue = c + (d - c) * fx;
            float value = (topValue + (bottomValue - topValue) * fy - minimum) * invSpan;
            value = value < 0.0f ? 0.0f : (value > 1.0f ? 1.0f : value);
            (*output)[static_cast<size_t>(y) * outWidth + x] =
                static_cast<uint8_t>(std::lround(value * 255.0f));
        }
    }
}

void executeDepth(napi_env /*env*/, void* data) {
    auto* work = static_cast<DepthWork*>(data);
    const int width = static_cast<int>(work->width);
    const int height = static_cast<int>(work->height);
    if (width <= 0 || height <= 0) {
        work->error = "invalid source dimensions";
        return;
    }
    const float scale = static_cast<float>(kDepthInput) / std::max(width, height);
    const int resizedWidth = std::max(1, static_cast<int>(std::lround(width * scale)));
    const int resizedHeight = std::max(1, static_cast<int>(std::lround(height * scale)));
    ncnn::Mat resized;
    {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_depth.ready) {
            work->error = "the depth model is not loaded";
            return;
        }
        // from_pixels_resize handles the aspect-preserving resize; padding to a
        // square happens afterwards exactly like the upstream demo.
        resized = ncnn::Mat::from_pixels_resize(work->rgba.data(), ncnn::Mat::PIXEL_RGBA2RGB,
            width, height, resizedWidth, resizedHeight);
    }
    if (resized.empty()) {
        work->error = "could not build the depth network input";
        return;
    }
    const int padX = kDepthInput - resizedWidth;
    const int padY = kDepthInput - resizedHeight;
    ncnn::Mat input;
    ncnn::copy_make_border(resized, input, padY / 2, padY - padY / 2,
        padX / 2, padX - padX / 2, ncnn::BORDER_CONSTANT, 0.0f);
    input.substract_mean_normalize(kDepthMean, kDepthNorm);

    ncnn::Mat depth;
    {
        std::lock_guard<std::mutex> guard(g_mutex);
        if (!g_depth.ready) {
            work->error = "the depth model was released during inference";
            return;
        }
        ncnn::Extractor extractor = g_depth.net.create_extractor();
        extractor.input("image", input);
        if (extractor.extract("depth", depth) != 0 || depth.empty()) {
            work->error = "the depth network produced no output";
            return;
        }
    }
    if (depth.w < 2 || depth.h < 2) {
        work->error = "the depth output is too small";
        return;
    }
    const float* plane = depth.channel(0);
    if (plane == nullptr) {
        work->error = "the depth output has no data channel";
        return;
    }
    // The graph returns a square; crop the padding using the same ratio in case
    // a future model emits a different output edge.
    const float scaleX = static_cast<float>(depth.w) / kDepthInput;
    const float scaleY = static_cast<float>(depth.h) / kDepthInput;
    const int left = std::max(0, std::min(depth.w - 1,
        static_cast<int>(std::lround((padX / 2) * scaleX))));
    const int top = std::max(0, std::min(depth.h - 1,
        static_cast<int>(std::lround((padY / 2) * scaleY))));
    const int cropWidth = std::max(2, std::min(depth.w - left,
        static_cast<int>(std::lround(resizedWidth * scaleX))));
    const int cropHeight = std::max(2, std::min(depth.h - top,
        static_cast<int>(std::lround(resizedHeight * scaleY))));

    float minimum = plane[top * depth.w + left];
    float maximum = minimum;
    for (int y = 0; y < cropHeight; y++) {
        const float* row = plane + (top + y) * depth.w + left;
        for (int x = 0; x < cropWidth; x++) {
            const float value = row[x];
            if (!std::isfinite(value)) continue;
            if (value < minimum) minimum = value;
            if (value > maximum) maximum = value;
        }
    }
    // Depth Anything emits a log/disparity-like plane with a long tail: a few
    // sky or specular samples can be an order of magnitude above the subject.
    // Stretching on the raw min/max crushes everything else into the bottom
    // few codes (the first on-device preview was almost black). Clip at the
    // 1st/99th percentile instead; the tail still saturates, but the subject
    // and background get the full 8-bit range.
    std::vector<float> samples;
    const int stride = std::max(1, static_cast<int>(std::sqrt(
        static_cast<double>(cropWidth) * cropHeight / 120000.0)));
    for (int y = 0; y < cropHeight; y += stride) {
        const float* row = plane + (top + y) * depth.w + left;
        for (int x = 0; x < cropWidth; x += stride) {
            const float value = row[x];
            if (std::isfinite(value)) samples.push_back(value);
        }
    }
    float low = minimum;
    float high = maximum;
    if (samples.size() >= 32) {
        std::sort(samples.begin(), samples.end());
        const size_t lowIndex = samples.size() / 100;
        const size_t highIndex = samples.size() - 1 - samples.size() / 100;
        low = samples[lowIndex];
        high = samples[highIndex];
        if (!(high - low > 1e-6f)) {
            low = minimum;
            high = maximum;
        }
    }
    const float span = high - low;
    if (!(span > 1e-6f)) {
        work->error = "the depth map has no variation";
        return;
    }

    const uint32_t requested = std::max<uint32_t>(32, std::min<uint32_t>(512, work->outputLongSide));
    const int longSide = static_cast<int>(requested);
    int outWidth;
    int outHeight;
    if (resizedWidth >= resizedHeight) {
        outWidth = longSide;
        outHeight = std::max(1, static_cast<int>(std::lround(
            static_cast<float>(longSide) * resizedHeight / resizedWidth)));
    } else {
        outHeight = longSide;
        outWidth = std::max(1, static_cast<int>(std::lround(
            static_cast<float>(longSide) * resizedWidth / resizedHeight)));
    }
    std::vector<uint8_t> bytes;
    resizeDepthToBytes(plane, depth.w, depth.h, left, top, cropWidth, cropHeight,
        minimum, span, outWidth, outHeight, &bytes);

    work->result.resize(8 + bytes.size());
    const uint32_t outputWidth = static_cast<uint32_t>(outWidth);
    const uint32_t outputHeight = static_cast<uint32_t>(outHeight);
    std::memcpy(work->result.data(), &outputWidth, 4);
    std::memcpy(work->result.data() + 4, &outputHeight, 4);
    std::memcpy(work->result.data() + 8, bytes.data(), bytes.size());
}

void completeDepth(napi_env env, napi_status status, void* data) {
    auto* work = static_cast<DepthWork*>(data);
    if (status == napi_ok && work->error.empty()) {
        void* output = nullptr;
        napi_value buffer = nullptr;
        if (napi_create_arraybuffer(env, work->result.size(), &output, &buffer) == napi_ok &&
            output != nullptr) {
            std::memcpy(output, work->result.data(), work->result.size());
            napi_resolve_deferred(env, work->deferred, buffer);
        } else {
            napi_value message = nullptr;
            napi_create_string_utf8(env, "could not allocate the depth result", NAPI_AUTO_LENGTH, &message);
            napi_reject_deferred(env, work->deferred, message);
        }
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, work->error.empty() ? "depth inference cancelled" : work->error.c_str(),
            NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, work->deferred, message);
    }
    napi_delete_async_work(env, work->asyncWork);
    delete work;
}

napi_value loadDepthModel(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* work = new DepthLoadWork();
    if (!copyArrayBuffer(env, args[0], &work->paramBytes) ||
        !copyArrayBuffer(env, args[1], &work->binBytes)) {
        delete work;
        napi_throw_error(env, nullptr, "loadDepthModel expects two non-empty ArrayBuffers");
        return nullptr;
    }
    napi_value promise = nullptr;
    napi_create_promise(env, &work->deferred, &promise);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "vividDepthLoad", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, executeDepthLoad, completeDepthLoad,
        work, &work->asyncWork);
    napi_queue_async_work(env, work->asyncWork);
    return promise;
}

napi_value depthLoaded(napi_env env, napi_callback_info /*info*/) {
    bool ready = false;
    {
        std::lock_guard<std::mutex> guard(g_mutex);
        ready = g_depth.ready;
    }
    napi_value result = nullptr;
    napi_get_boolean(env, ready, &result);
    return result;
}

napi_value estimateDepth(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* work = new DepthWork();
    if (!copyArrayBuffer(env, args[0], &work->rgba)) {
        delete work;
        napi_throw_error(env, nullptr, "estimateDepth expects RGBA ArrayBuffer");
        return nullptr;
    }
    int32_t width = 0;
    int32_t height = 0;
    int32_t longSide = 384;
    if (!getInt32(env, args[1], &width) || !getInt32(env, args[2], &height) ||
        !getInt32(env, args[3], &longSide)) {
        delete work;
        napi_throw_error(env, nullptr, "estimateDepth expects integer dimensions");
        return nullptr;
    }
    if (width <= 0 || height <= 0 ||
        work->rgba.size() < static_cast<size_t>(width) * height * 4) {
        delete work;
        napi_throw_error(env, nullptr, "estimateDepth source buffer is too small");
        return nullptr;
    }
    work->width = static_cast<uint32_t>(width);
    work->height = static_cast<uint32_t>(height);
    work->outputLongSide = static_cast<uint32_t>(longSide);
    napi_value promise = nullptr;
    napi_create_promise(env, &work->deferred, &promise);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "vividDepthEstimate", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, executeDepth, completeDepth,
        work, &work->asyncWork);
    napi_queue_async_work(env, work->asyncWork);
    return promise;
}

napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        { "loadModel", nullptr, loadModel, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "segment", nullptr, segment, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isLoaded", nullptr, isLoaded, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "modelInfo", nullptr, modelInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "release", nullptr, release, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "loadDepthModel", nullptr, loadDepthModel, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "depthLoaded", nullptr, depthLoaded, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "estimateDepth", nullptr, estimateDepth, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

}  // namespace

NAPI_MODULE_X(vivid_ai, init, nullptr, 0)
