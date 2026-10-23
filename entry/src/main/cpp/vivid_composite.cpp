/*
 * vivid_composite - NAPI binding for the native layer composition loops.
 *
 * The arithmetic lives in vivid_composite_core.{h,cpp} so the same translation
 * unit is also compiled into the host probe used by
 * tools/check_composite_native_parity.cjs. This file only marshals arguments.
 *
 * All pixel arguments are typed arrays (`Uint8ClampedArray`), not
 * `ArrayBuffer`s: `WorkerCore` hands the layer loops band *views* of the frame,
 * and N-API's typed-array info already carries the view's own data pointer, so
 * passing the view removes every byteOffset/byteLength trap.
 *
 * Every entry point returns `true` when it served the call and `false` when the
 * arguments did not validate; the ArkTS wrapper then runs the original loop, so
 * a mismatch can never corrupt a frame - it can only cost speed.
 *
 * ## Contract
 *   matrixBand(input, matrix, output, start, end) -> boolean
 *   maskBlend(adjusted, maskAdjusted, mask, start, end, pixelOffset) -> boolean
 *   composite(result, base, adjusted, mask, opacity, blendMode, start, end,
 *             pixelOffset) -> boolean        (mask may be null)
 *   apiVersion() -> number
 */
#include <napi/native_api.h>

#include <cstdint>

#include "vivid_composite_core.h"
#include "vivid_advanced_core.h"
#include "vivid_pointwise_core.h"
#include "vivid_typed_array.h"

namespace {

constexpr int32_t kApiVersion = 3;

/**
 * Element count of one typed-array view. The ArkTS runtime this app runs on
 * reports `napi_get_typedarray_info`'s length in bytes (a 9-element
 * Float64Array arrives as 72), so the reported value is normalised against the
 * view's byte length before any caller divides by the element size.
 */
size_t viewLength(napi_env env, napi_value arrayBuffer, size_t byteOffset, size_t reported,
                  size_t elementSize) {
    size_t bufferBytes = 0;
    void* bufferData = nullptr;
    if (arrayBuffer == nullptr || elementSize == 0 ||
        napi_get_arraybuffer_info(env, arrayBuffer, &bufferData, &bufferBytes) != napi_ok ||
        byteOffset > bufferBytes) {
        return reported;
    }
    const int64_t normalized = vivid::normalizedElementCount(
        static_cast<int64_t>(reported), static_cast<int64_t>(bufferBytes - byteOffset),
        static_cast<int32_t>(elementSize));
    return normalized > 0 ? static_cast<size_t>(normalized) : 0;
}

/** Bytes of a Uint8Array / Uint8ClampedArray view (its own data pointer). */
bool byteView(napi_env env, napi_value value, uint8_t** data, size_t* length) {
    if (value == nullptr) return false;
    napi_typedarray_type type;
    size_t elementCount = 0;
    void* raw = nullptr;
    napi_value arrayBuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, value, &type, &elementCount, &raw, &arrayBuffer, &byteOffset) != napi_ok) {
        return false;
    }
    if (type != napi_uint8_clamped_array && type != napi_uint8_array) return false;
    if (raw == nullptr) return false;
    *data = static_cast<uint8_t*>(raw);
    *length = viewLength(env, arrayBuffer, byteOffset, elementCount, sizeof(uint8_t));
    return true;
}

/** Bytes of a Float32Array view. */
bool floatView(napi_env env, napi_value value, float** data, size_t* length) {
    if (value == nullptr) return false;
    napi_typedarray_type type;
    size_t elementCount = 0;
    void* raw = nullptr;
    napi_value arrayBuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, value, &type, &elementCount, &raw, &arrayBuffer, &byteOffset) != napi_ok) {
        return false;
    }
    if (type != napi_float32_array || raw == nullptr) return false;
    *data = static_cast<float*>(raw);
    *length = viewLength(env, arrayBuffer, byteOffset, elementCount, sizeof(float));
    return true;
}

/** Bytes of a Float64Array view. */
bool doubleView(napi_env env, napi_value value, double** data, size_t* length) {
    if (value == nullptr) return false;
    napi_typedarray_type type;
    size_t elementCount = 0;
    void* raw = nullptr;
    napi_value arrayBuffer = nullptr;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, value, &type, &elementCount, &raw, &arrayBuffer, &byteOffset) != napi_ok) {
        return false;
    }
    if (type != napi_float64_array || raw == nullptr) return false;
    *data = static_cast<double*>(raw);
    *length = viewLength(env, arrayBuffer, byteOffset, elementCount, sizeof(double));
    return true;
}

bool getIndex(napi_env env, napi_value value, size_t* out) {
    double number = 0;
    if (value == nullptr || napi_get_value_double(env, value, &number) != napi_ok) return false;
    if (!(number >= 0.0)) return false;
    *out = static_cast<size_t>(number);
    return true;
}

bool isNullish(napi_env env, napi_value value) {
    if (value == nullptr) return true;
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) return true;
    return type == napi_undefined || type == napi_null;
}

napi_value booleanValue(napi_env env, bool value) {
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value intValue(napi_env env, int32_t value) {
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value matrixBand(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {};
    uint8_t* input = nullptr;
    uint8_t* output = nullptr;
    float* matrix = nullptr;
    size_t inputLength = 0, outputLength = 0, matrixLength = 0;
    size_t start = 0, end = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 5 ||
        !byteView(env, args[0], &input, &inputLength) || !floatView(env, args[1], &matrix, &matrixLength) ||
        !byteView(env, args[2], &output, &outputLength) || !getIndex(env, args[3], &start) ||
        !getIndex(env, args[4], &end) || matrixLength < 20) {
        return booleanValue(env, false);
    }
    if (start >= end || end > inputLength || end > outputLength) return booleanValue(env, false);
    vivid::matrixBand(input, matrix, matrixLength, output, start, end);
    return booleanValue(env, true);
}

napi_value maskBlend(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {};
    uint8_t* adjusted = nullptr;
    uint8_t* maskAdjusted = nullptr;
    uint8_t* mask = nullptr;
    size_t adjustedLength = 0, maskAdjustedLength = 0, maskLength = 0;
    size_t start = 0, end = 0, pixelOffset = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 6 ||
        !byteView(env, args[0], &adjusted, &adjustedLength) ||
        !byteView(env, args[1], &maskAdjusted, &maskAdjustedLength) ||
        !byteView(env, args[2], &mask, &maskLength) || !getIndex(env, args[3], &start) ||
        !getIndex(env, args[4], &end) || !getIndex(env, args[5], &pixelOffset)) {
        return booleanValue(env, false);
    }
    if (start >= end || end > adjustedLength || end > maskAdjustedLength) return booleanValue(env, false);
    vivid::maskBlend(adjusted, maskAdjusted, mask, maskLength, start, end, pixelOffset);
    return booleanValue(env, true);
}

napi_value composite(napi_env env, napi_callback_info info) {
    size_t argc = 9;
    napi_value args[9] = {};
    uint8_t* result = nullptr;
    uint8_t* base = nullptr;
    uint8_t* adjusted = nullptr;
    uint8_t* mask = nullptr;
    size_t resultLength = 0, baseLength = 0, adjustedLength = 0, maskLength = 0;
    size_t start = 0, end = 0, pixelOffset = 0;
    double opacity = 0;
    int32_t blendMode = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 9 ||
        !byteView(env, args[0], &result, &resultLength) || !byteView(env, args[1], &base, &baseLength) ||
        !byteView(env, args[2], &adjusted, &adjustedLength)) {
        return booleanValue(env, false);
    }
    const bool hasMask = !isNullish(env, args[3]);
    if (hasMask && !byteView(env, args[3], &mask, &maskLength)) return booleanValue(env, false);
    if (napi_get_value_double(env, args[4], &opacity) != napi_ok ||
        napi_get_value_int32(env, args[5], &blendMode) != napi_ok ||
        !getIndex(env, args[6], &start) || !getIndex(env, args[7], &end) ||
        !getIndex(env, args[8], &pixelOffset)) {
        return booleanValue(env, false);
    }
    if (start >= end || end > resultLength || end > baseLength || end > adjustedLength) {
        return booleanValue(env, false);
    }
    vivid::composite(result, base, adjusted, hasMask ? mask : nullptr, maskLength, opacity, blendMode,
        start, end, pixelOffset);
    return booleanValue(env, true);
}

napi_value lutStack(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {};
    uint8_t* pixels = nullptr;
    double* values = nullptr;
    double* meta = nullptr;
    size_t pixelLength = 0, valueLength = 0, metaLength = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 3 ||
        !byteView(env, args[0], &pixels, &pixelLength) ||
        !doubleView(env, args[1], &values, &valueLength) ||
        !doubleView(env, args[2], &meta, &metaLength)) {
        return booleanValue(env, false);
    }
    if (pixelLength % 4 != 0 || metaLength % vivid::pointwise::kLutMetaStride != 0) {
        return booleanValue(env, false);
    }
    const size_t lutCount = metaLength / vivid::pointwise::kLutMetaStride;
    if (pixelLength / 4 > 0x7fffffffu || valueLength > 0x7fffffffu || lutCount > 64) {
        return booleanValue(env, false);
    }
    const bool served = vivid::pointwise::lutStack(pixels, static_cast<int32_t>(pixelLength / 4),
        values, static_cast<int32_t>(valueLength), meta, static_cast<int32_t>(lutCount));
    return booleanValue(env, served);
}

napi_value pointColor(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    uint8_t* pixels = nullptr;
    double* samples = nullptr;
    size_t pixelLength = 0, sampleLength = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 2 ||
        !byteView(env, args[0], &pixels, &pixelLength) ||
        !doubleView(env, args[1], &samples, &sampleLength)) {
        return booleanValue(env, false);
    }
    if (pixelLength % 4 != 0 || sampleLength % vivid::pointwise::kPointColorStride != 0) {
        return booleanValue(env, false);
    }
    const size_t sampleCount = sampleLength / vivid::pointwise::kPointColorStride;
    if (pixelLength / 4 > 0x7fffffffu || sampleCount > 8) return booleanValue(env, false);
    const bool served = vivid::pointwise::pointColor(pixels, static_cast<int32_t>(pixelLength / 4),
        samples, static_cast<int32_t>(sampleCount));
    return booleanValue(env, served);
}

napi_value oklch(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    uint8_t* pixels = nullptr;
    double* params = nullptr;
    size_t pixelLength = 0, paramLength = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 2 ||
        !byteView(env, args[0], &pixels, &pixelLength) ||
        !doubleView(env, args[1], &params, &paramLength)) {
        return booleanValue(env, false);
    }
    if (pixelLength % 4 != 0 || paramLength < vivid::pointwise::kOkLChStride) {
        return booleanValue(env, false);
    }
    if (pixelLength / 4 > 0x7fffffffu) return booleanValue(env, false);
    const bool served = vivid::pointwise::oklch(pixels, static_cast<int32_t>(pixelLength / 4), params);
    return booleanValue(env, served);
}

napi_value apiVersion(napi_env env, napi_callback_info info) {
    napi_value result = nullptr;
    napi_create_int32(env, kApiVersion, &result);
    return result;
}

/*
 * Diagnostic twin of lutStack: validates the exact same flattened payload and
 * returns a kLutStack* code instead of touching pixels. Called by the ArkTS
 * wrapper only after lutStack returned false, so a device log can name the
 * failing field. Returns -1 for unreadable arguments and -2 for a meta array
 * that is not a whole number of 9-double entries.
 */
napi_value lutStackReason(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    double* values = nullptr;
    double* meta = nullptr;
    size_t valueLength = 0, metaLength = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 2 ||
        !doubleView(env, args[0], &values, &valueLength) ||
        !doubleView(env, args[1], &meta, &metaLength)) {
        return intValue(env, -1);
    }
    if (metaLength % vivid::pointwise::kLutMetaStride != 0) return intValue(env, -2);
    if (valueLength > 0x7fffffffu || metaLength / vivid::pointwise::kLutMetaStride > 0x7fffffffu) {
        return intValue(env, -3);
    }
    const int32_t reason = vivid::pointwise::lutStackRejectReason(values,
        static_cast<int32_t>(valueLength), meta,
        static_cast<int32_t>(metaLength / vivid::pointwise::kLutMetaStride));
    return intValue(env, reason);
}

napi_value advancedBand(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {};
    uint8_t* input = nullptr;
    double* params = nullptr;
    double* curves = nullptr;
    double* viewport = nullptr;
    float* tonal = nullptr;
    float* parametric = nullptr;
    size_t inputLength = 0, paramsLength = 0, curvesLength = 0;
    size_t tonalLength = 0, parametricLength = 0, viewportLength = 0;
    size_t start = 0, end = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 8 ||
        !byteView(env, args[0], &input, &inputLength) ||
        !getIndex(env, args[1], &start) || !getIndex(env, args[2], &end) ||
        !doubleView(env, args[3], &params, &paramsLength) ||
        !doubleView(env, args[4], &curves, &curvesLength)) {
        return booleanValue(env, false);
    }
    if (!isNullish(env, args[5]) && !floatView(env, args[5], &tonal, &tonalLength)) {
        return booleanValue(env, false);
    }
    if (!isNullish(env, args[6]) && !floatView(env, args[6], &parametric, &parametricLength)) {
        return booleanValue(env, false);
    }
    if (!isNullish(env, args[7]) && !doubleView(env, args[7], &viewport, &viewportLength)) {
        return booleanValue(env, false);
    }
    const bool served = vivid::advancedBand(input, inputLength, start, end,
        params, paramsLength, curves, curvesLength,
        tonal, tonalLength, parametric, parametricLength, viewport, viewportLength);
    return booleanValue(env, served);
}

napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        { "matrixBand", nullptr, matrixBand, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "maskBlend", nullptr, maskBlend, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "composite", nullptr, composite, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "advancedBand", nullptr, advancedBand, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "lutStack", nullptr, lutStack, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "lutStackReason", nullptr, lutStackReason, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pointColor", nullptr, pointColor, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "oklch", nullptr, oklch, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "apiVersion", nullptr, apiVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

}  // namespace

NAPI_MODULE_X(vivid_composite, init, nullptr, 0)
