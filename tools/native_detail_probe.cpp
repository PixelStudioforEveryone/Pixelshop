/*
 * Host probe for tools/check_detail_native_parity.cjs.
 *
 * It links the SAME translation unit the device library compiles
 * (entry/src/main/cpp/vivid_detail_core.cpp) with the same flags (-O2,
 * -ffp-contract=off), reads a raw RGBA fixture, and writes the result. The test
 * runs it under WSL and compares its bytes against the ArkTS reference, which is
 * the only way to diff C++ against ArkTS without an on-device harness.
 *
 * Modes:
 *   detail <in> <out> <w> <h> <rTex> <rClarity> <rSharpen> <texture> <clarity>
 *          <dehaze> <veil> <sharpenAmount> <sharpenDetail> <sharpenMasking>
 *          <hasHaze> <hazeR> <hazeG> <hazeB> [--repeat=N] [--falsify=0|1|2|3]
 *       Runs the detail stage `repeat` times (timing the core only), writes the
 *       final buffer, prints "ms=<per-call mean>". `--falsify` adds 1 to the
 *       given channel of every pixel AFTER the core call -- the parity test uses
 *       it to prove it would catch a native result that is wrong in one channel.
 *   haze <in> <w> <h>
 *       Prints "r g b" with %.17g, or "none".
 */
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "vivid_detail_core.h"

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

bool writeFile(const char* path, const uint8_t* data, size_t length) {
    FILE* file = std::fopen(path, "wb");
    if (file == nullptr) return false;
    const size_t written = std::fwrite(data, 1, length, file);
    std::fclose(file);
    return written == length;
}

double argAt(char** argv, int index) {
    return std::strtod(argv[index], nullptr);
}

int flagValue(char** argv, int argc, const char* name, int fallback) {
    const size_t nameLength = std::strlen(name);
    for (int index = 1; index < argc; index++) {
        if (std::strncmp(argv[index], name, nameLength) == 0) {
            return std::atoi(argv[index] + nameLength);
        }
    }
    return fallback;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc >= 3 && std::strcmp(argv[1], "haze") == 0) {
        if (argc < 5) return 2;
        std::vector<uint8_t> input;
        if (!readFile(argv[2], &input)) return 3;
        const int width = std::atoi(argv[3]);
        const int height = std::atoi(argv[4]);
        if (width <= 0 || height <= 0) return 4;
        if (input.size() < static_cast<size_t>(width) * height * 4) return 5;
        double color[3] = { 0.0, 0.0, 0.0 };
        if (!vivid::hazeColor(input.data(), width, height, color)) {
            std::printf("none\n");
            return 0;
        }
        std::printf("%.17g %.17g %.17g\n", color[0], color[1], color[2]);
        return 0;
    }
    if (argc < 20 || std::strcmp(argv[1], "detail") != 0) {
        std::fprintf(stderr, "usage: %s detail|haze ...\n", argv[0]);
        return 2;
    }
    std::vector<uint8_t> input;
    if (!readFile(argv[2], &input)) return 3;
    vivid::DetailParams params;
    params.width = std::atoi(argv[4]);
    params.height = std::atoi(argv[5]);
    params.radiusTexture = std::atoi(argv[6]);
    params.radiusClarity = std::atoi(argv[7]);
    params.radiusSharpen = std::atoi(argv[8]);
    params.texture = argAt(argv, 9);
    params.clarity = argAt(argv, 10);
    params.dehaze = argAt(argv, 11);
    params.veil = argAt(argv, 12);
    params.sharpenAmount = argAt(argv, 13);
    params.sharpenDetail = argAt(argv, 14);
    params.sharpenMasking = argAt(argv, 15);
    params.hasHaze = std::atoi(argv[16]) != 0;
    params.hazeRed = argAt(argv, 17);
    params.hazeGreen = argAt(argv, 18);
    params.hazeBlue = argAt(argv, 19);
    if (params.width <= 0 || params.height <= 0) return 4;
    const size_t bytes = static_cast<size_t>(params.width) * params.height * 4;
    const int repeatFlag = flagValue(argv, argc, "--repeat=", 1);
    const int repeat = repeatFlag < 1 ? 1 : repeatFlag;
    // -1 means "do not falsify"; 0..3 add 1 to that channel of every pixel.
    const int falsify = flagValue(argv, argc, "--falsify=", -1);
    std::vector<uint8_t> output(bytes, 0);
    const auto start = std::chrono::steady_clock::now();
    for (int iteration = 0; iteration < repeat; iteration++) {
        vivid::applyDetail(input.data(), input.size(), output.data(), params);
    }
    const auto finish = std::chrono::steady_clock::now();
    const double millis = std::chrono::duration<double, std::milli>(finish - start).count() / repeat;
    if (falsify >= 0 && falsify < 4) {
        for (size_t index = static_cast<size_t>(falsify); index < output.size(); index += 4) {
            if (output[index] < 255) output[index] = static_cast<uint8_t>(output[index] + 1);
        }
    }
    if (!writeFile(argv[3], output.data(), output.size())) return 5;
    std::printf("ms=%.6f\n", millis);
    return 0;
}
