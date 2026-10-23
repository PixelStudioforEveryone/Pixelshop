/*
 * Host probe for vivid_pointwise_core + vivid_composite_core.
 *
 * The device library and this probe compile the exact same translation units,
 * so a byte difference here is a real difference between the C++ and ArkTS
 * references, not a harness artefact.
 *
 * Usage: native_pointwise_probe <fixture.bin> <output.bin> [--falsify <channel>]
 *        native_pointwise_probe <fixture.bin> - --reason
 *        native_pointwise_probe - - --lengths <reported> <viewBytes> <elementSize>
 *
 * `--reason` validates the fixture's LUT stack with the same validator the
 * device library runs, prints the kLutStack* code to stdout and exits. It is
 * how the parity suite pins the reject-code contract used by device logs.
 * `--lengths` exercises the N-API length normalisation directly: the ArkTS
 * runtime reports typed-array lengths in bytes, so a 9-element Float64Array
 * arrives as 72 and must still become 9 elements.
 *
 * Fixture layout (little-endian; the host and the WSL toolchain are x86):
 *   uint32 magic 'PWV1'
 *   uint32 stage       0 = LUT, 1 = point colour, 2 = OkLCh, 3 = full combo
 *   int32  width
 *   int32  height
 *   int32  lutCount
 *   int32  pointCount
 *   int32  hasLayer
 *   int32  hasMask
 *   double opacity
 *   int32  blendMode
 *   float  matrix[20]        (only when hasLayer)
 *   for each LUT: int32 size, int32 valueCount, double amount,
 *                 double min[3], double max[3], double value[valueCount]
 *   for each point sample: double sample[9]
 *   double oklch[3]          (stage 2 and 3)
 *   uint32 maskLength, uint8 mask[maskLength] (when hasMask)
 *   uint32 pixelBytes, uint8 pixels[pixelBytes]
 *
 * Output: the processed pixel bytes, optionally with +1 on one channel.
 */
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "vivid_composite_core.h"
#include "vivid_pointwise_core.h"
#include "vivid_typed_array.h"

namespace {

bool readExact(std::ifstream& in, void* data, size_t bytes) {
    in.read(static_cast<char*>(data), static_cast<std::streamsize>(bytes));
    return static_cast<size_t>(in.gcount()) == bytes;
}

template <typename T>
bool readValue(std::ifstream& in, T* value) {
    return readExact(in, value, sizeof(T));
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <fixture.bin> <output.bin> [--falsify <channel>]\n", argv[0]);
        return 2;
    }
    int falsifyChannel = -1;
    if (argc >= 7 && std::strcmp(argv[3], "--lengths") == 0) {
        const int64_t reported = std::atoll(argv[4]);
        const int64_t viewBytes = std::atoll(argv[5]);
        const int32_t elementSize = std::atoi(argv[6]);
        std::printf("%lld\n", static_cast<long long>(
            vivid::normalizedElementCount(reported, viewBytes, elementSize)));
        return 0;
    }
    if (argc >= 5 && std::strcmp(argv[3], "--falsify") == 0) {
        falsifyChannel = std::atoi(argv[4]);
        if (falsifyChannel < 0 || falsifyChannel > 2) {
            std::fprintf(stderr, "falsify channel must be 0..2\n");
            return 2;
        }
    }

    std::ifstream in(argv[1], std::ios::binary);
    if (!in) {
        std::fprintf(stderr, "cannot open fixture\n");
        return 2;
    }
    uint32_t magic = 0;
    uint32_t stage = 0;
    int32_t width = 0, height = 0, lutCount = 0, pointCount = 0, hasLayer = 0, hasMask = 0;
    int32_t maskConsumed = 0;
    double opacity = 1.0;
    int32_t blendMode = 0;
    if (!readValue(in, &magic) || magic != 0x50575631u || !readValue(in, &stage) ||
        !readValue(in, &width) || !readValue(in, &height) || !readValue(in, &lutCount) ||
        !readValue(in, &pointCount) || !readValue(in, &hasLayer) || !readValue(in, &hasMask) ||
        !readValue(in, &maskConsumed) || !readValue(in, &opacity) || !readValue(in, &blendMode)) {
        std::fprintf(stderr, "bad header\n");
        return 2;
    }
    if (width <= 0 || height <= 0) return 2;

    float matrix[20] = {};
    if (hasLayer && !readExact(in, matrix, sizeof(matrix))) return 2;
    float maskMatrix[20] = {};
    if (hasMask && maskConsumed && !readExact(in, maskMatrix, sizeof(maskMatrix))) return 2;

    std::vector<double> lutValues;
    std::vector<int32_t> lutSizes;
    std::vector<double> lutAmounts;
    std::vector<double> lutMin;
    std::vector<double> lutMax;
    for (int32_t index = 0; index < lutCount; index++) {
        int32_t size = 0, valueCount = 0;
        double amount = 0.0;
        double minValue[3] = {};
        double maxValue[3] = {};
        if (!readValue(in, &size) || !readValue(in, &valueCount) || !readValue(in, &amount) ||
            !readExact(in, minValue, sizeof(minValue)) || !readExact(in, maxValue, sizeof(maxValue))) {
            return 2;
        }
        std::vector<double> values(static_cast<size_t>(valueCount));
        if (valueCount > 0 && !readExact(in, values.data(), sizeof(double) * values.size())) return 2;
        lutSizes.push_back(size);
        lutAmounts.push_back(amount);
        lutMin.insert(lutMin.end(), minValue, minValue + 3);
        lutMax.insert(lutMax.end(), maxValue, maxValue + 3);
        lutValues.insert(lutValues.end(), values.begin(), values.end());
    }
    // Repack into the flat metadata layout vivid::pointwise expects; offsets are
    // recomputed here from the per-entry sizes rather than trusted from the file.
    std::vector<double> meta(static_cast<size_t>(lutCount) * vivid::pointwise::kLutMetaStride);
    int32_t valueOffset = 0;
    for (int32_t index = 0; index < lutCount; index++) {
        const size_t offset = static_cast<size_t>(index) * vivid::pointwise::kLutMetaStride;
        meta[offset] = lutSizes[index];
        meta[offset + 1] = lutAmounts[index];
        meta[offset + 2] = lutMin[static_cast<size_t>(index) * 3];
        meta[offset + 3] = lutMin[static_cast<size_t>(index) * 3 + 1];
        meta[offset + 4] = lutMin[static_cast<size_t>(index) * 3 + 2];
        meta[offset + 5] = lutMax[static_cast<size_t>(index) * 3];
        meta[offset + 6] = lutMax[static_cast<size_t>(index) * 3 + 1];
        meta[offset + 7] = lutMax[static_cast<size_t>(index) * 3 + 2];
        meta[offset + 8] = valueOffset;
        valueOffset += lutSizes[index] * lutSizes[index] * lutSizes[index] * 3;
    }

    if (argc >= 4 && std::strcmp(argv[3], "--reason") == 0) {
        std::printf("%d\n", vivid::pointwise::lutStackRejectReason(
            lutValues.data(), static_cast<int32_t>(lutValues.size()), meta.data(), lutCount));
        return 0;
    }

    std::vector<double> samples(static_cast<size_t>(pointCount) * vivid::pointwise::kPointColorStride);
    for (int32_t index = 0; index < pointCount; index++) {
        if (!readExact(in, samples.data() + static_cast<size_t>(index) * vivid::pointwise::kPointColorStride,
                       sizeof(double) * vivid::pointwise::kPointColorStride)) {
            return 2;
        }
    }

    double oklchParams[vivid::pointwise::kOkLChStride] = {};
    if ((stage == 2 || stage == 3) &&
        !readExact(in, oklchParams, sizeof(double) * vivid::pointwise::kOkLChStride)) {
        return 2;
    }

    std::vector<uint8_t> mask;
    if (hasMask) {
        uint32_t maskLength = 0;
        if (!readValue(in, &maskLength) || maskLength > (1u << 30)) return 2;
        mask.resize(maskLength);
        if (maskLength > 0 && !readExact(in, mask.data(), maskLength)) return 2;
    }

    uint32_t pixelBytes = 0;
    if (!readValue(in, &pixelBytes)) return 2;
    if (pixelBytes != static_cast<uint32_t>(width) * static_cast<uint32_t>(height) * 4u) return 2;
    std::vector<uint8_t> pixels(pixelBytes);
    if (!readExact(in, pixels.data(), pixelBytes)) return 2;

    std::vector<uint8_t> base(pixels);
    std::vector<uint8_t> adjusted(pixels);
    std::vector<uint8_t> result(pixels);

    if (stage == 3) {
        vivid::matrixBand(base.data(), matrix, 20, adjusted.data(), 0, adjusted.size());
        if (hasMask && maskConsumed && !mask.empty()) {
            std::vector<uint8_t> maskAdjusted(adjusted);
            vivid::matrixBand(adjusted.data(), maskMatrix, 20, maskAdjusted.data(), 0, adjusted.size());
            vivid::maskBlend(adjusted.data(), maskAdjusted.data(), mask.data(), mask.size(), 0,
                             adjusted.size(), 0);
        }
        // A consumed mask is not applied again during composition; a plain
        // layer mask (no local adjustments) is consumed by the composite.
        vivid::composite(result.data(), base.data(), adjusted.data(),
                         (hasMask && !maskConsumed) ? mask.data() : nullptr,
                         (hasMask && !maskConsumed) ? mask.size() : 0,
                         opacity, blendMode, 0, result.size(), 0);
    }

    if (stage == 0 || stage == 3) {
        if (!vivid::pointwise::lutStack(result.data(), static_cast<int32_t>(pixelBytes / 4),
                                        lutValues.data(), static_cast<int32_t>(lutValues.size()),
                                        meta.data(), lutCount)) {
            std::fprintf(stderr, "lutStack rejected\n");
            return 3;
        }
    }
    if (stage == 1 || stage == 3) {
        if (!vivid::pointwise::pointColor(result.data(), static_cast<int32_t>(pixelBytes / 4),
                                          samples.data(), pointCount)) {
            std::fprintf(stderr, "pointColor rejected\n");
            return 3;
        }
    }
    if (stage == 2 || stage == 3) {
        if (!vivid::pointwise::oklch(result.data(), static_cast<int32_t>(pixelBytes / 4), oklchParams)) {
            std::fprintf(stderr, "oklch rejected\n");
            return 3;
        }
    }

    if (falsifyChannel >= 0) {
        for (size_t index = 0; index < result.size(); index += 4) {
            uint8_t& channel = result[index + static_cast<size_t>(falsifyChannel)];
            channel = static_cast<uint8_t>(channel == 255 ? 255 : channel + 1);
        }
    }

    std::ofstream out(argv[2], std::ios::binary);
    if (!out) return 2;
    out.write(reinterpret_cast<const char*>(result.data()), static_cast<std::streamsize>(result.size()));
    return out.good() ? 0 : 2;
}
