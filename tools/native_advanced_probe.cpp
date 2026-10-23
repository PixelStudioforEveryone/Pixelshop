/*
 * Host probe for vivid_advanced_core.cpp.
 *
 * Reads one binary fixture (layout below) and writes the band-applied pixels to
 * the output path. tools/check_advanced_native_parity.cjs produces the fixture
 * from the ArkTS reference and compares the two byte for byte.
 *
 *   int32  magic   = 0x56415642 ('VAVB')
 *   int32  hasTonal, hasParametric, hasViewport
 *   int32  length  (input byte count)
 *   double params[70]
 *   double curves[4 * 1025]
 *   float  tonal[1025]
 *   float  parametric[256]
 *   double viewport[6]
 *   uint8  input[length]
 */
#include <cstdint>
#include <cstdio>
#include <vector>

#include "vivid_advanced_core.h"

int main(int argc, char** argv) {
    if (argc < 3) return 2;
    FILE* in = std::fopen(argv[1], "rb");
    if (in == nullptr) return 3;
    int32_t magic = 0, hasTonal = 0, hasParametric = 0, hasViewport = 0, length = 0;
    if (std::fread(&magic, sizeof(int32_t), 1, in) != 1 || magic != 0x56415642) return 4;
    if (std::fread(&hasTonal, sizeof(int32_t), 1, in) != 1) return 4;
    if (std::fread(&hasParametric, sizeof(int32_t), 1, in) != 1) return 4;
    if (std::fread(&hasViewport, sizeof(int32_t), 1, in) != 1) return 4;
    if (std::fread(&length, sizeof(int32_t), 1, in) != 1 || length < 4) return 4;

    std::vector<double> params(70);
    std::vector<double> curves(4 * 1025);
    std::vector<float> tonal(1025);
    std::vector<float> parametric(256);
    std::vector<double> viewport(6);
    std::vector<uint8_t> input(static_cast<size_t>(length));
    if (std::fread(params.data(), sizeof(double), params.size(), in) != params.size()) return 5;
    if (std::fread(curves.data(), sizeof(double), curves.size(), in) != curves.size()) return 5;
    if (std::fread(tonal.data(), sizeof(float), tonal.size(), in) != tonal.size()) return 5;
    if (std::fread(parametric.data(), sizeof(float), parametric.size(), in) != parametric.size()) return 5;
    if (std::fread(viewport.data(), sizeof(double), viewport.size(), in) != viewport.size()) return 5;
    if (std::fread(input.data(), 1, input.size(), in) != input.size()) return 5;
    std::fclose(in);

    const bool ok = vivid::advancedBand(input.data(), input.size(), 0, input.size(),
        params.data(), params.size(), curves.data(), curves.size(),
        hasTonal != 0 ? tonal.data() : nullptr, hasTonal != 0 ? tonal.size() : 0,
        hasParametric != 0 ? parametric.data() : nullptr,
        hasParametric != 0 ? parametric.size() : 0,
        hasViewport != 0 ? viewport.data() : nullptr, hasViewport != 0 ? viewport.size() : 0);
    if (!ok) return 6;
    FILE* out = std::fopen(argv[2], "wb");
    if (out == nullptr) return 7;
    if (std::fwrite(input.data(), 1, input.size(), out) != input.size()) return 7;
    std::fclose(out);
    return 0;
}
