/*
 * vivid_detail - NAPI binding for the native detail stage.
 *
 * The algorithm lives in vivid_detail_core.{h,cpp} so the exact same code can
 * be compiled into the host probe the parity test drives (see
 * tools/check_detail_native_parity.cjs). This file is only argument marshalling:
 * it validates the JS values, allocates the output ArrayBuffer and fills in one
 * `vivid::DetailParams`.
 *
 * ArkTS side: entry/src/main/ets/edit/engine/NativeDetail.ets, called from
 * LocalContrastCore.applyLocalContrast. When this module is missing or throws,
 * that wrapper runs the ArkTS implementation instead.
 *
 * ## Contract
 *   applyDetail(rgba, width, height, radiusTexture, radiusClarity,
 *               radiusSharpen, texture, clarity, dehaze, veil,
 *               sharpenAmount, sharpenDetail, sharpenMasking,
 *               hasHaze, hazeRed, hazeGreen, hazeBlue)
 *       -> ArrayBuffer(width*height*4) | null
 *   hazeColor(rgba, width, height) -> number[3] | null
 *   apiVersion() -> number
 *
 * `rgba` is the underlying ArrayBuffer (pass `.buffer`), not the view. The
 * radii and `veil` are computed in ArkTS on purpose: they go through
 * `Math.pow`, whose last ulp is engine-specific, while the radii themselves are
 * integers after rounding and must match `LocalContrastCore` exactly.
 * See vivid_detail_core.h for the bit-exactness contract.
 */
#include <napi/native_api.h>

#include <cstdint>
#include <cstring>
#include <vector>

#include "vivid_detail_core.h"

namespace {

constexpr int32_t kApiVersion = 1;

bool getNumber(napi_env env, napi_value value, double* out) {
    return value != nullptr && napi_get_value_double(env, value, out) == napi_ok;
}

bool getBool(napi_env env, napi_value value, bool* out) {
    return value != nullptr && napi_get_value_bool(env, value, out) == napi_ok;
}

bool bufferBytes(napi_env env, napi_value value, uint8_t** data, size_t* length) {
    void* raw = nullptr;
    if (value == nullptr || napi_get_arraybuffer_info(env, value, &raw, length) != napi_ok || raw == nullptr) {
        return false;
    }
    *data = static_cast<uint8_t*>(raw);
    return true;
}

napi_value nullValue(napi_env env) {
    napi_value result = nullptr;
    napi_get_null(env, &result);
    return result;
}

/** Round a JS number to int the way the ArkTS side would (`Math.floor`). */
int toInt(double value) {
    if (!(value > 0.0)) return 0;
    if (value > 1000000.0) return 1000000;
    return static_cast<int>(value);
}

/**
 * Fill one `DetailParams` from the 17 arguments. Returns false when any of them
 * is missing or the wrong type, which the caller turns into a JS null so the
 * ArkTS wrapper falls back instead of using a half-initialised request.
 */
bool readArgs(napi_env env, size_t argc, napi_value* args, vivid::DetailParams* params) {
    double width = 0;
    double height = 0;
    double radiusTexture = 0;
    double radiusClarity = 0;
    double radiusSharpen = 0;
    if (!getNumber(env, args[1], &width) || !getNumber(env, args[2], &height) ||
        !getNumber(env, args[3], &radiusTexture) || !getNumber(env, args[4], &radiusClarity) ||
        !getNumber(env, args[5], &radiusSharpen)) {
        return false;
    }
    if (!getNumber(env, args[6], &params->texture) || !getNumber(env, args[7], &params->clarity) ||
        !getNumber(env, args[8], &params->dehaze) || !getNumber(env, args[9], &params->veil) ||
        !getNumber(env, args[10], &params->sharpenAmount) ||
        !getNumber(env, args[11], &params->sharpenDetail) ||
        !getNumber(env, args[12], &params->sharpenMasking) ||
        !getBool(env, args[13], &params->hasHaze) || !getNumber(env, args[14], &params->hazeRed) ||
        !getNumber(env, args[15], &params->hazeGreen) || !getNumber(env, args[16], &params->hazeBlue)) {
        return false;
    }
    params->width = toInt(width);
    params->height = toInt(height);
    params->radiusTexture = toInt(radiusTexture);
    params->radiusClarity = toInt(radiusClarity);
    params->radiusSharpen = toInt(radiusSharpen);
    return true;
}

napi_value applyDetail(napi_env env, napi_callback_info info) {
    size_t argc = 17;
    napi_value args[17] = {};
    uint8_t* source = nullptr;
    size_t sourceLength = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 17 ||
        !bufferBytes(env, args[0], &source, &sourceLength)) {
        return nullValue(env);
    }
    vivid::DetailParams params;
    if (!readArgs(env, argc, args, &params)) return nullValue(env);
    if (params.width <= 0 || params.height <= 0) return nullValue(env);
    const size_t bytes = static_cast<size_t>(params.width) * params.height * 4;
    void* raw = nullptr;
    napi_value result = nullptr;
    if (napi_create_arraybuffer(env, bytes, &raw, &result) != napi_ok || raw == nullptr) {
        return nullValue(env);
    }
    vivid::applyDetail(source, sourceLength, static_cast<uint8_t*>(raw), params);
    return result;
}

napi_value hazeColor(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    uint8_t* source = nullptr;
    size_t sourceLength = 0;
    double width = 0;
    double height = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 3 ||
        !bufferBytes(env, args[0], &source, &sourceLength) || !getNumber(env, args[1], &width) ||
        !getNumber(env, args[2], &height)) {
        return nullValue(env);
    }
    const int frameWidth = toInt(width);
    const int frameHeight = toInt(height);
    if (frameWidth <= 0 || frameHeight <= 0) return nullValue(env);
    if (sourceLength < static_cast<size_t>(frameWidth) * frameHeight * 4) return nullValue(env);
    double color[3] = { 0.0, 0.0, 0.0 };
    if (!vivid::hazeColor(source, frameWidth, frameHeight, color)) return nullValue(env);
    napi_value result = nullptr;
    if (napi_create_array_with_length(env, 3, &result) != napi_ok) return nullValue(env);
    for (uint32_t index = 0; index < 3; index++) {
        napi_value value = nullptr;
        if (napi_create_double(env, color[index], &value) != napi_ok) return nullValue(env);
        if (napi_set_element(env, result, index, value) != napi_ok) return nullValue(env);
    }
    return result;
}

napi_value apiVersion(napi_env env, napi_callback_info info) {
    napi_value result = nullptr;
    napi_create_int32(env, kApiVersion, &result);
    return result;
}

napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        { "applyDetail", nullptr, applyDetail, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "hazeColor", nullptr, hazeColor, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "apiVersion", nullptr, apiVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

}  // namespace

NAPI_MODULE_X(vivid_detail, init, nullptr, 0)
