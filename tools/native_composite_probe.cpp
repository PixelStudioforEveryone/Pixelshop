/*
 * Host probe for tools/check_composite_native_parity.cjs.
 *
 * Links the SAME translation unit the device library compiles
 * (entry/src/main/cpp/vivid_composite_core.cpp) with the same flags, so the test
 * can diff the C++ loops against the ArkTS reference byte for byte.
 *
 * Modes:
 *   matrix <in> <matrix.f32> <out> <start> <end>
 *   maskblend <adjusted> <maskAdjusted> <mask> <start> <end> <pixelOffset> <out>
 *   composite <result> <base> <adjusted> <mask|-> <opacity> <blendMode>
 *             <start> <end> <pixelOffset> <out> [--falsify=0|1|2|3]
 */
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "vivid_composite_core.h"

namespace {

bool readFile(const char* path, std::vector<uint8_t>* out) {
    FILE* file = std::fopen(path, "rb");
    if (file == nullptr) return false;
    std::fseek(file, 0, SEEK_END);
    const long size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    if (size < 0) {
        std::fclose(file);
        return false;
    }
    out->assign(static_cast<size_t>(size), 0);
    const size_t read = size > 0 ? std::fread(out->data(), 1, static_cast<size_t>(size), file) : 0;
    std::fclose(file);
    return read == static_cast<size_t>(size);
}

bool writeFile(const char* path, const std::vector<uint8_t>& data) {
    FILE* file = std::fopen(path, "wb");
    if (file == nullptr) return false;
    const size_t written = std::fwrite(data.data(), 1, data.size(), file);
    std::fclose(file);
    return written == data.size();
}

std::vector<uint8_t> load(const char* path) {
    std::vector<uint8_t> bytes;
    if (!readFile(path, &bytes)) {
        std::fprintf(stderr, "cannot read %s\n", path);
        std::exit(3);
    }
    return bytes;
}

size_t index(char* text) {
    return static_cast<size_t>(std::strtoull(text, nullptr, 10));
}

int falsifyFlag(char** argv, int argc) {
    for (int i = 0; i < argc; i++) {
        if (std::strncmp(argv[i], "--falsify=", 10) == 0) return std::atoi(argv[i] + 10);
    }
    return -1;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) return 2;
    if (std::strcmp(argv[1], "bench") == 0 && argc >= 13) {
        // bench <in.rgba> <mask.u8> <matrix.f32> <maskmatrix.f32> <opacity>
        //       <blendMode> <start> <end> <pixelOffset> <repeat> <out.rgba>
        std::vector<uint8_t> input = load(argv[2]);
        std::vector<uint8_t> mask = load(argv[3]);
        std::vector<uint8_t> matrixBytes = load(argv[4]);
        std::vector<uint8_t> maskMatrixBytes = load(argv[5]);
        if (matrixBytes.size() < 20 * sizeof(float) || maskMatrixBytes.size() < 20 * sizeof(float)) return 4;
        const double opacity = std::strtod(argv[6], nullptr);
        const int32_t blendMode = std::atoi(argv[7]);
        const size_t start = index(argv[8]);
        const size_t end = index(argv[9]);
        const size_t pixelOffset = index(argv[10]);
        const int repeat = std::atoi(argv[11]);
        std::vector<uint8_t> adjusted(input.size(), 0);
        std::vector<uint8_t> maskAdjusted(input.size(), 0);
        std::vector<uint8_t> result(input.size(), 0);
        const auto begin = std::chrono::steady_clock::now();
        for (int iteration = 0; iteration < repeat; iteration++) {
            std::fill(adjusted.begin(), adjusted.end(), 0);
            std::fill(result.begin(), result.end(), 0);
            vivid::matrixBand(input.data(), reinterpret_cast<const float*>(matrixBytes.data()),
                matrixBytes.size() / sizeof(float), adjusted.data(), start, end);
            vivid::matrixBand(adjusted.data(), reinterpret_cast<const float*>(maskMatrixBytes.data()),
                maskMatrixBytes.size() / sizeof(float), maskAdjusted.data(), start, end);
            vivid::maskBlend(adjusted.data(), maskAdjusted.data(), mask.data(), mask.size(), start, end,
                pixelOffset);
            vivid::composite(result.data(), input.data(), adjusted.data(), nullptr, 0, opacity, blendMode,
                start, end, pixelOffset);
        }
        const auto finish = std::chrono::steady_clock::now();
        const double millis = std::chrono::duration<double, std::milli>(finish - begin).count() /
            (repeat < 1 ? 1 : repeat);
        std::printf("ms=%.6f\n", millis);
        return writeFile(argv[12], result) ? 0 : 5;
    }
    if (std::strcmp(argv[1], "matrix") == 0 && argc >= 7) {
        std::vector<uint8_t> input = load(argv[2]);
        std::vector<uint8_t> matrixBytes = load(argv[3]);
        if (matrixBytes.size() < 20 * sizeof(float)) return 4;
        std::vector<uint8_t> output = input;
        vivid::matrixBand(input.data(), reinterpret_cast<const float*>(matrixBytes.data()),
            matrixBytes.size() / sizeof(float), output.data(), index(argv[5]), index(argv[6]));
        return writeFile(argv[4], output) ? 0 : 5;
    }
    if (std::strcmp(argv[1], "maskblend") == 0 && argc >= 9) {
        std::vector<uint8_t> adjusted = load(argv[2]);
        std::vector<uint8_t> maskAdjusted = load(argv[3]);
        std::vector<uint8_t> mask = load(argv[4]);
        vivid::maskBlend(adjusted.data(), maskAdjusted.data(), mask.data(), mask.size(),
            index(argv[5]), index(argv[6]), index(argv[7]));
        return writeFile(argv[8], adjusted) ? 0 : 5;
    }
    if (std::strcmp(argv[1], "composite") == 0 && argc >= 11) {
        std::vector<uint8_t> result = load(argv[2]);
        std::vector<uint8_t> base = load(argv[3]);
        std::vector<uint8_t> adjusted = load(argv[4]);
        const bool hasMask = std::strcmp(argv[5], "-") != 0;
        std::vector<uint8_t> mask;
        if (hasMask) mask = load(argv[5]);
        const double opacity = std::strtod(argv[6], nullptr);
        const int32_t blendMode = std::atoi(argv[7]);
        vivid::composite(result.data(), base.data(), adjusted.data(), hasMask ? mask.data() : nullptr,
            mask.size(), opacity, blendMode, index(argv[8]), index(argv[9]), index(argv[10]));
        const int falsify = falsifyFlag(argv, argc);
        if (falsify >= 0 && falsify < 4) {
            for (size_t i = static_cast<size_t>(falsify); i < result.size(); i += 4) {
                if (result[i] < 255) result[i] = static_cast<uint8_t>(result[i] + 1);
            }
        }
        return writeFile(argv[11], result) ? 0 : 5;
    }
    std::fprintf(stderr, "bad arguments\n");
    return 2;
}
