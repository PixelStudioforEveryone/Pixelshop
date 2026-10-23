/*
 * Typed-array length normalisation for the N-API boundary.
 *
 * `napi_get_typedarray_info` documents its `length` output as an *element*
 * count, but the ArkTS runtime this app runs on reports it in **bytes**:
 * measured on device, a 9-element Float64Array arrives as 72 and a
 * 107811-element one as 862488. Treating 72 as nine entries made the LUT
 * validator see `lutCount = 8`, read past the metadata array, and reject every
 * LUT stack with `kLutStackBadSize`; the whole LUT stage then fell back to the
 * interpreted ArkTS loop (13-16 s per 2048x1644 tile on the phone).
 *
 * Both semantics are accepted, per view:
 *   reported == viewByteLength              -> runtime reported bytes
 *   reported == viewByteLength / elementSize -> runtime reported elements
 *   anything else (a shorter subarray view)  -> trust the reported element count
 *
 * This header is compiled into the device library and into the host parity
 * probe, so `tools/check_pointwise_native_parity.cjs` pins all three branches.
 */
#ifndef VIVID_TYPED_ARRAY_H
#define VIVID_TYPED_ARRAY_H

#include <cstdint>

namespace vivid {

/** Convert a N-API reported typed-array length to an element count. */
inline int64_t normalizedElementCount(int64_t reported, int64_t viewByteLength, int32_t elementSize) {
    if (elementSize <= 0 || viewByteLength < 0) return reported;
    if (reported == viewByteLength) return viewByteLength / elementSize;
    if (reported == viewByteLength / elementSize) return reported;
    return reported;
}

}  // namespace vivid

#endif  // VIVID_TYPED_ARRAY_H
