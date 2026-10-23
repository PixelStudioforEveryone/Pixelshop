#include <libraw/libraw.h>
#include <napi/native_api.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {
// Structured decode status shared with the ArkTS boundary (RawDecodeStatus).
// The embedded-JPEG fallback policy keys off these classes instead of raw
// LibRaw error strings, so a truncated transfer is distinguishable from an
// unknown camera model or a decoder that is out of memory.
enum DecodeStatus {
    DECODE_OK = 0,
    DECODE_UNSUPPORTED_CAMERA = 1,
    DECODE_CORRUPT = 2,
    DECODE_UNSUPPORTED_COMPRESSION = 3,
    DECODE_OUT_OF_MEMORY = 4,
    DECODE_UNSUPPORTED_CFA = 5,
    DECODE_UNKNOWN = 6,
};

static int classifyOpenStatus(int rc)
{
    switch (rc) {
        case LIBRAW_FILE_UNSUPPORTED: return DECODE_UNSUPPORTED_CAMERA;
        case LIBRAW_IO_ERROR:
        case LIBRAW_DATA_ERROR: return DECODE_CORRUPT;
        case LIBRAW_UNSUFFICIENT_MEMORY:
        case LIBRAW_MEMPOOL_OVERFLOW:
        case LIBRAW_TOO_BIG: return DECODE_OUT_OF_MEMORY;
        default: return DECODE_UNKNOWN;
    }
}

static int classifyUnpackStatus(int rc)
{
    switch (rc) {
        case LIBRAW_NOT_IMPLEMENTED: return DECODE_UNSUPPORTED_COMPRESSION;
        case LIBRAW_IO_ERROR:
        case LIBRAW_DATA_ERROR: return DECODE_CORRUPT;
        case LIBRAW_UNSUFFICIENT_MEMORY:
        case LIBRAW_MEMPOOL_OVERFLOW:
        case LIBRAW_TOO_BIG: return DECODE_OUT_OF_MEMORY;
        default: return DECODE_UNKNOWN;
    }
}

struct DecodeWork {
    napi_env env = nullptr;
    napi_deferred deferred = nullptr;
    napi_async_work asyncWork = nullptr;
    std::vector<uint8_t> input;
    float matrix[9] = {};
    bool matrixProvided = false;
    uint32_t maxDimension = 0;
    std::vector<uint8_t> pixels;
    std::vector<float> linearPixels;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t sourceWidth = 0;
    uint32_t sourceHeight = 0;
    std::string model;
    std::string error;
    int statusCode = DECODE_OK;
    std::string diagnostics;
    int black = 0;
    int white = 0;
    int bits = 0;
    float wb[4] = {};
    float camToSrgb[9] = {};
};

// Everything support needs in one line: library build, raw error code, the
// byte count actually handed to LibRaw (a truncated PTP/DLNA transfer shows
// up here), identified camera, selected decoder and CFA descriptor.
static std::string buildDiagnostics(LibRaw& raw, int rc, const DecodeWork* work)
{
    std::string out;
    out += "libraw=";
    const char* version = LibRaw::version();
    out += version != nullptr ? version : "?";
    out += " rc=";
    out += std::to_string(rc);
    out += " (";
    out += libraw_strerror(rc);
    out += ") file_bytes=";
    out += std::to_string(work->input.size());
    const char* make = raw.imgdata.idata.make;
    const char* model = raw.imgdata.idata.model;
    if ((make != nullptr && make[0] != '\0') || (model != nullptr && model[0] != '\0'))
        out += std::string(" camera=") + (make != nullptr ? make : "") + " " + (model != nullptr ? model : "");
    const char* unpackName = raw.unpack_function_name();
    if (unpackName != nullptr && unpackName[0] != '\0') { out += " unpack="; out += unpackName; }
    out += " filters=";
    out += std::to_string(raw.imgdata.idata.filters);
    out += " raw=";
    out += std::to_string(raw.imgdata.sizes.raw_width);
    out += "x";
    out += std::to_string(raw.imgdata.sizes.raw_height);
    return out;
}

static bool arrayBuffer(napi_env env, napi_value value, std::vector<uint8_t>& out)
{
    bool isBuffer = false;
    void* data = nullptr;
    size_t length = 0;
    if (napi_is_arraybuffer(env, value, &isBuffer) != napi_ok || !isBuffer ||
        napi_get_arraybuffer_info(env, value, &data, &length) != napi_ok || data == nullptr || length == 0) return false;
    out.assign(static_cast<uint8_t*>(data), static_cast<uint8_t*>(data) + length);
    return true;
}

static bool getNumber(napi_env env, napi_value object, const char* name, double& output)
{
    napi_value value = nullptr;
    return napi_get_named_property(env, object, name, &value) == napi_ok && napi_get_value_double(env, value, &output) == napi_ok;
}

static void parseOptions(napi_env env, napi_value options, DecodeWork& work)
{
    napi_valuetype valueType = napi_undefined;
    if (napi_typeof(env, options, &valueType) != napi_ok || valueType != napi_object) return;
    double maxDimension = 0;
    if (getNumber(env, options, "maxDimension", maxDimension)) work.maxDimension = static_cast<uint32_t>(std::max(0.0, maxDimension));
    napi_value matrix = nullptr;
    bool isArray = false;
    if (napi_get_named_property(env, options, "matrix", &matrix) != napi_ok ||
        napi_is_array(env, matrix, &isArray) != napi_ok || !isArray) return;
    uint32_t length = 0;
    if (napi_get_array_length(env, matrix, &length) != napi_ok || length < 9) return;
    for (uint32_t i = 0; i < 9; i++) {
        napi_value item = nullptr;
        double value = 0;
        if (napi_get_element(env, matrix, i, &item) != napi_ok || napi_get_value_double(env, item, &value) != napi_ok) return;
        work.matrix[i] = static_cast<float>(value);
    }
    work.matrixProvided = true;
}

static float clamp01(float value)
{
    return std::max(0.0f, std::min(1.0f, value));
}

// DCP ForwardMatrix values are white-balanced camera RGB -> XYZ D50. Convert that reference
// white to display-linear sRGB before the final transfer curve; applying the
// DCP matrix directly to display RGB would produce visibly wrong colors.
static float d50ToSrgb(float value)
{
    return value <= 0.0031308f ? 12.92f * value : 1.055f * std::pow(std::max(0.0f, value), 1.0f / 2.4f) - 0.055f;
}

static char expectedColor(int channel)
{
    return channel == 0 ? 'R' : (channel == 1 ? 'G' : 'B');
}

// COLOR() returns a CFA index, not necessarily the semantic R/G/B channel
// number.  Most Bayer files use RGBG, but several Panasonic variants expose a
// different descriptor order.  Treating index 2 as B unconditionally swaps
// yellow and blue when that order changes.
static bool matchesColor(const LibRaw& raw, int c, int channel)
{
    const char expected = expectedColor(channel);
    if (c >= 0 && c < 4 && raw.imgdata.idata.cdesc[c] != 0) {
        if (raw.imgdata.idata.cdesc[c] == expected) return true;
        if (channel == 1 && raw.imgdata.idata.cdesc[c] == 'G') return true;
        return false;
    }
    return c == channel || (channel == 1 && c == 3);
}

static float readChannel(LibRaw& raw, int row, int col, int channel, float black, float white)
{
    const int width = raw.imgdata.sizes.raw_width;
    const int height = raw.imgdata.sizes.raw_height;
    if (row < 0 || col < 0 || row >= height || col >= width || raw.imgdata.rawdata.raw_image == nullptr) return -1.0f;
    const int c = raw.COLOR(row, col);
    if (!matchesColor(raw, c, channel)) return -1.0f;
    const int stride = raw.imgdata.sizes.raw_pitch / sizeof(ushort);
    const float sample = static_cast<float>(raw.imgdata.rawdata.raw_image[row * (stride > 0 ? stride : width) + col]);
    const float channelBlack = black + raw.imgdata.rawdata.color.cblack[c];
    return std::max(0.0f, (sample - channelBlack) / std::max(1.0f, white - channelBlack));
}

static float cameraGainForColor(const LibRaw& raw, int channel)
{
    const char expected = expectedColor(channel);
    float sum = 0.0f;
    int count = 0;
    for (int c = 0; c < 4; c++) {
        if (raw.imgdata.idata.cdesc[c] == expected && raw.imgdata.rawdata.color.cam_mul[c] > 0.0f) {
            sum += raw.imgdata.rawdata.color.cam_mul[c];
            count++;
        }
    }
    if (count > 0) return sum / static_cast<float>(count);
    const int fallback = channel == 1 ? 1 : channel;
    return raw.imgdata.rawdata.color.cam_mul[fallback];
}

static float sampleChannel(LibRaw& raw, int row, int col, int channel, float black, float white)
{
    float sum = 0.0f;
    int count = 0;
    for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
        const float value = readChannel(raw, row + dy, col + dx, channel, black, white);
        if (value >= 0.0f) { sum += value; count++; }
    }
    return count > 0 ? sum / static_cast<float>(count) : 0.0f;
}

// The 5x5 CFA gather below is ~25 reads per output pixel and dominates the
// decode (~30s single-threaded on a 24MP frame). Output rows are disjoint and
// LibRaw state is read-only here, so the range can be split across threads.
static void decodeRowRange(LibRaw& raw, DecodeWork* work, uint32_t yBegin, uint32_t yEnd,
    float black, float white, float scale, const int* semantics, int stride)
{
    for (uint32_t y = yBegin; y < yEnd; y++) for (uint32_t x = 0; x < work->width; x++) {
        const int rawX = raw.imgdata.sizes.left_margin + std::min<int>(work->sourceWidth - 1, static_cast<int>((x + 0.5f) * scale));
        const int rawY = raw.imgdata.sizes.top_margin + std::min<int>(work->sourceHeight - 1, static_cast<int>((y + 0.5f) * scale));
        float rgb[3]={}; int count[3]={};
        // Visit the 5x5 CFA neighborhood once, rather than once per channel.
        for(int dy=-2;dy<=2;dy++) for(int dx=-2;dx<=2;dx++) {
            const int row=rawY+dy,col=rawX+dx;
            if(row<0||col<0||row>=raw.imgdata.sizes.raw_height||col>=raw.imgdata.sizes.raw_width) continue;
            const int c=raw.COLOR(row,col),ch=semantics[c];
            if(ch<0) continue;
            const float floor=black+raw.imgdata.rawdata.color.cblack[c];
            rgb[ch]+=std::max(0.0f,(raw.imgdata.rawdata.raw_image[row*stride+col]-floor)/std::max(1.0f,white-floor));
            count[ch]++;
        }
        for(int ch=0;ch<3;ch++) rgb[ch]=count[ch]>0?rgb[ch]/count[ch]:0;
        const size_t linearOffset = (static_cast<size_t>(y) * work->width + x) * 3;
        // Contract: scene-linear camera RGB without white balance. DCP owns
        // neutral selection and applies white balance once for either matrix.
        work->linearPixels[linearOffset] = rgb[0];
        work->linearPixels[linearOffset + 1] = rgb[1];
        work->linearPixels[linearOffset + 2] = rgb[2];
        if (work->matrixProvided) {
            const float r = rgb[0]*work->wb[0], g = rgb[1], b = rgb[2]*work->wb[2];
            const float xyz[3] = {
                work->matrix[0] * r + work->matrix[1] * g + work->matrix[2] * b,
                work->matrix[3] * r + work->matrix[4] * g + work->matrix[5] * b,
                work->matrix[6] * r + work->matrix[7] * g + work->matrix[8] * b,
            };
            // Standard D50 XYZ -> sRGB linear matrix (DCP matrices are D50).
            rgb[0] = 3.1338561f * xyz[0] - 1.6168667f * xyz[1] - 0.4906146f * xyz[2];
            rgb[1] = -0.9787684f * xyz[0] + 1.9161415f * xyz[1] + 0.0334540f * xyz[2];
            rgb[2] = 0.0719453f * xyz[0] - 0.2289914f * xyz[1] + 1.4052427f * xyz[2];
        }
    }
}

static void executeDecode(napi_env, void* data)
{
    auto* work = static_cast<DecodeWork*>(data);
    LibRaw raw;
    int status = raw.open_buffer(work->input.data(), work->input.size());
    if (status != LIBRAW_SUCCESS) {
        work->statusCode = classifyOpenStatus(status);
        work->error = libraw_strerror(status);
        work->diagnostics = buildDiagnostics(raw, status, work);
        return;
    }
    work->sourceWidth = raw.imgdata.sizes.width;
    work->sourceHeight = raw.imgdata.sizes.height;
    work->model = std::string(raw.imgdata.idata.make) + " " + raw.imgdata.idata.model;
    work->bits = static_cast<int>(raw.imgdata.rawdata.color.raw_bps);
    status = raw.unpack();
    if (status != LIBRAW_SUCCESS || raw.imgdata.rawdata.raw_image == nullptr) {
        const int effective = status == LIBRAW_SUCCESS ? LIBRAW_DATA_ERROR : status;
        work->statusCode = classifyUnpackStatus(effective);
        work->error = libraw_strerror(effective);
        work->diagnostics = buildDiagnostics(raw, effective, work);
        return;
    }
    const float black = static_cast<float>(raw.imgdata.rawdata.color.black);
    const float white = static_cast<float>(raw.imgdata.rawdata.color.maximum);
    if (raw.imgdata.idata.filters < 1000 || white <= black ||
        cameraGainForColor(raw, 0) <= 0 || cameraGainForColor(raw, 1) <= 0 ||
        cameraGainForColor(raw, 2) <= 0) {
        work->statusCode = DECODE_UNSUPPORTED_CFA;
        work->error = "Unsupported CFA or invalid RAW calibration; use preview";
        work->diagnostics = buildDiagnostics(raw, LIBRAW_SUCCESS, work);
        return;
    }
    work->black = static_cast<int>(black);
    work->white = static_cast<int>(white);
    const float redGain = cameraGainForColor(raw, 0);
    const float greenGain = cameraGainForColor(raw, 1);
    const float blueGain = cameraGainForColor(raw, 2);
    float green = greenGain;
    if (green <= 0.0f) green = 1.0f;
    work->wb[0] = redGain / green;
    work->wb[1] = 1.0f;
    work->wb[2] = blueGain / green;
    // Open-source dcraw per-camera color: merge LibRaw's rgb_cam (3x4, columns
    // follow the CFA descriptor order) into a semantic camera RGB -> sRGB
    // matrix.  Exposed as the "classic" profile when no bundled DCP matches.
    // An unknown camera keeps LibRaw's raw_color behavior (identity), matching
    // what dcraw does when the model is missing from its coefficient table.
    {
        double merged[3][3] = {};
        int counts[3] = { 0, 0, 0 };
        for (int c = 0; c < 4; c++) {
            const char descriptor = raw.imgdata.idata.cdesc[c];
            const int semantic = descriptor == 'R' ? 0 : descriptor == 'G' ? 1 : descriptor == 'B' ? 2 : -1;
            if (semantic < 0) continue;
            for (int i = 0; i < 3; i++) merged[i][semantic] += raw.imgdata.color.rgb_cam[i][c];
            counts[semantic]++;
        }
        bool valid = counts[0] > 0 && counts[1] > 0 && counts[2] > 0;
        double magnitude = 0.0;
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
            // Columns multiply separate CFA channels. Both green inputs equal
            // our semantic green sample, so their coefficients must be summed.
            if (!std::isfinite(merged[i][j])) valid = false;
            magnitude += std::fabs(merged[i][j]);
        }
        if (!valid || magnitude <= 0.0)
            for (int i = 0; i < 3; i++) merged[i][i] = 1.0;
        for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++)
            work->camToSrgb[i * 3 + j] = static_cast<float>(merged[i][j]);
    }
    const uint32_t longest = std::max<uint32_t>(work->sourceWidth, work->sourceHeight);
    const float scale = work->maxDimension > 0 && longest > work->maxDimension ?
        static_cast<float>(longest) / static_cast<float>(work->maxDimension) : 1.0f;
    work->width = std::max<uint32_t>(1, static_cast<uint32_t>(std::ceil(work->sourceWidth / scale)));
    work->height = std::max<uint32_t>(1, static_cast<uint32_t>(std::ceil(work->sourceHeight / scale)));
    work->linearPixels.resize(static_cast<size_t>(work->width) * work->height * 3);
    int semantics[4];
    for (int c=0;c<4;c++) {
        semantics[c] = -1;
        for(int ch=0;ch<3;ch++) if(matchesColor(raw,c,ch)) { semantics[c]=ch; break; }
    }
    const int pitch=raw.imgdata.sizes.raw_pitch/sizeof(ushort);
    const int stride=pitch>0?pitch:raw.imgdata.sizes.raw_width;
    const unsigned hardware = std::thread::hardware_concurrency();
    // 8 核手机上 6 个 worker 比固定 4 个明显更快；行区间互不重叠且
    // LibRaw 状态在此阶段只读，并行安全。
    unsigned workers = hardware == 0u ? 1u : (hardware < 6u ? hardware : 6u);
    if (work->height < 1024) workers = 1u;
    if (workers == 1u) {
        decodeRowRange(raw, work, 0, work->height, black, white, scale, semantics, stride);
    } else {
        std::vector<std::thread> pool;
        const uint32_t rowsPer = (work->height + workers - 1) / workers;
        for (unsigned t = 0u; t < workers; t++) {
            const uint32_t yBegin = std::min(work->height, t * rowsPer);
            const uint32_t yEnd = std::min(work->height, yBegin + rowsPer);
            if (yBegin >= yEnd) break;
            pool.emplace_back([&raw, work, yBegin, yEnd, black, white, scale, &semantics, stride] {
                decodeRowRange(raw, work, yBegin, yEnd, black, white, scale, semantics, stride);
            });
        }
        for (std::thread& worker : pool) worker.join();
    }
}

static napi_value propertyString(napi_env env, const char* value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value propertyNumber(napi_env env, double value)
{
    napi_value result = nullptr;
    napi_create_double(env, value, &result);
    return result;
}

static void completeDecode(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<DecodeWork*>(data);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    // Failures resolve (never reject) with a structured envelope so the ArkTS
    // boundary can classify the failure without scraping message strings.
    napi_set_named_property(env, result, "status", propertyNumber(env, work->statusCode));
    napi_set_named_property(env, result, "message", propertyString(env,
        work->error.empty() ? (status == napi_ok ? "" : "LibRaw decode cancelled") : work->error.c_str()));
    napi_set_named_property(env, result, "diagnostics", propertyString(env, work->diagnostics.c_str()));
    if (status == napi_ok && work->error.empty()) {
        // NOTE: do NOT hand the buffer over via napi_create_external_arraybuffer.
        // TaskPool refuses to serialize (transfer) externally-backed ArrayBuffers
        // and their slices, which silently breaks every DCP worker dispatch and
        // forces the whole RAW path onto the platform decoder fallback.
        void* linearData = nullptr; napi_value linearValue = nullptr;
        napi_create_arraybuffer(env, work->linearPixels.size() * sizeof(float), &linearData, &linearValue);
        std::memcpy(linearData, work->linearPixels.data(), work->linearPixels.size() * sizeof(float));
        napi_set_named_property(env, result, "linearPixels", linearValue);
        napi_value neutral = nullptr;
        napi_create_array_with_length(env, 3, &neutral);
        for (int c = 0; c < 3; c++) napi_set_element(env, neutral, c, propertyNumber(env, 1.0 / work->wb[c]));
        napi_set_named_property(env, result, "cameraNeutral", neutral);
        napi_value camToSrgb = nullptr;
        napi_create_array_with_length(env, 9, &camToSrgb);
        for (int i = 0; i < 9; i++) napi_set_element(env, camToSrgb, i, propertyNumber(env, work->camToSrgb[i]));
        napi_set_named_property(env, result, "camToSrgb", camToSrgb);
        napi_set_named_property(env, result, "width", propertyNumber(env, work->width));
        napi_set_named_property(env, result, "height", propertyNumber(env, work->height));
        napi_set_named_property(env, result, "sourceWidth", propertyNumber(env, work->sourceWidth));
        napi_set_named_property(env, result, "sourceHeight", propertyNumber(env, work->sourceHeight));
        napi_set_named_property(env, result, "model", propertyString(env, work->model.c_str()));
        napi_set_named_property(env, result, "blackLevel", propertyNumber(env, work->black));
        napi_set_named_property(env, result, "whiteLevel", propertyNumber(env, work->white));
        napi_set_named_property(env, result, "bitDepth", propertyNumber(env, work->bits));
        napi_set_named_property(env, result, "linearCameraRgb", propertyNumber(env, 1));
        napi_set_named_property(env, result, "dcpApplied", propertyNumber(env, work->matrixProvided ? 1 : 0));
    }
    napi_resolve_deferred(env, work->deferred, result);
    napi_delete_async_work(env, work->asyncWork);
    delete work;
}

static napi_value decodeRw2(napi_env env, napi_callback_info info)
{
    size_t argc = 2; napi_value args[2] = {};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 1) return nullptr;
    auto* work = new DecodeWork(); work->env = env;
    if (!arrayBuffer(env, args[0], work->input)) { delete work; return nullptr; }
    if (argc > 1) parseOptions(env, args[1], *work);
    napi_value promise = nullptr; napi_value resource = nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "VividLibRawDecode", NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, executeDecode, completeDecode, work, &work->asyncWork) != napi_ok ||
        napi_queue_async_work(env, work->asyncWork) != napi_ok) { delete work; return nullptr; }
    return promise;
}

static napi_value init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {{ "decodeRw2", nullptr, decodeRw2, nullptr, nullptr, nullptr, napi_default, nullptr }};
    napi_define_properties(env, exports, 1, properties);
    return exports;
}
}

NAPI_MODULE_X(vivid_raw, init, nullptr, 0)
