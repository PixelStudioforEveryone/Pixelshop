cmake_minimum_required(VERSION 3.16)
project(vivid_gpu)

# --- OpenMP runtime (used by vivid_detail's row/column-parallel passes) ------
# The OHOS clang toolchain ships the LLVM OpenMP runtime as a static archive,
# exactly like the ncnn build below. It is linked whole-archive so its thread
# pool and entry points are present; `-fopenmp` is compile-only on purpose (a
# link-time -fopenmp would add a shared libomp dependency the app does not ship).
if(OHOS_ARCH STREQUAL "armeabi-v7a")
    set(OHOS_OMP_TRIPLE "arm-linux-ohos")
elseif(OHOS_ARCH STREQUAL "x86_64")
    set(OHOS_OMP_TRIPLE "x86_64-linux-ohos")
else()
    set(OHOS_OMP_TRIPLE "aarch64-linux-ohos")
endif()
set(OHOS_OMP_LIB "${OHOS_SDK_NATIVE}/llvm/lib/${OHOS_OMP_TRIPLE}/libomp.a")
if(NOT EXISTS "${OHOS_OMP_LIB}")
    message(FATAL_ERROR "OpenMP runtime missing for ${OHOS_OMP_TRIPLE}: ${OHOS_OMP_LIB}")
endif()

add_library(vivid_gpu SHARED vivid_gpu.cpp)

# LibRaw is kept as a CPU-only Native path. It is used only when a matching
# DCP is available; the ArkTS ImageSource/JPEG path remains the fallback.
set(LIBRAW_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../third_party/libraw")
file(GLOB_RECURSE LIBRAW_SOURCES CONFIGURE_DEPENDS
    "${LIBRAW_ROOT}/src/*.cpp")
# This file is a no-postprocessing placeholder and duplicates implementations
# from the real postprocessing sources when all source files are linked.
list(FILTER LIBRAW_SOURCES EXCLUDE REGEX "/postprocessing_ph\\.cpp$")
add_library(vivid_libraw STATIC ${LIBRAW_SOURCES})
target_include_directories(vivid_libraw PUBLIC
    "${LIBRAW_ROOT}"
    "${LIBRAW_ROOT}/libraw"
    "${LIBRAW_ROOT}/internal")
target_compile_definitions(vivid_libraw PRIVATE LIBRAW_NOTHREADS USE_ZLIB)
target_compile_options(vivid_libraw PRIVATE -Wno-deprecated-non-prototype -Wno-unused-function)
# hvigor 的 debug 包用 -O0 编译 native 代码，NEF 无损 JPEG 解压和 demosaic
# 采集循环会慢 10-30 倍。无论 debug/release 都强制优化（调试信息仍保留）。
target_compile_options(vivid_libraw PRIVATE -O2)

# --- vivid_pixels: native per-pixel mask rasterisation ----------------------
# Pure CPU, no third-party dependency. The ArkTS twin of this code costs about
# 0.4 us per pixel (an interpreted typed-array loop), which is what made a
# 44 MP gradient mask take 18.9 s; native makes it milliseconds. -O2 is forced
# because hvigor's debug build uses -O0 and would erase the point, and
# -ffp-contract=off keeps every float result bit-identical to the ArkTS
# reference (an FMA would round `dx*ca + dy*sa` in one step).
add_library(vivid_pixels SHARED vivid_pixels.cpp)
target_compile_features(vivid_pixels PRIVATE cxx_std_17)
target_compile_options(vivid_pixels PRIVATE -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter)
target_compile_options(vivid_pixels PRIVATE -O2 -ffp-contract=off)
# The 44 MP analytic raster is split across up to 8 row workers on region-cache
# misses; small tile rasters stay serial. Bionic exposes pthread through libc,
# so `-pthread` is both the compile and the link contract here.
target_compile_options(vivid_pixels PRIVATE -pthread)
target_link_options(vivid_pixels PRIVATE -pthread)
target_link_libraries(vivid_pixels PUBLIC libace_napi.z.so)

# --- vivid_detail: native detail stage (texture/clarity/dehaze/sharpen) -----
# Same story as vivid_pixels: the ArkTS twin (LocalContrastCore.applyLocalContrast)
# costs 725 ms per 512x341 frame on the device and 20-47 ms on Node, so the heat
# is interpretation, not arithmetic. -O2 is forced (debug builds use -O0) and
# -ffp-contract=off keeps every float result bit-identical to the ArkTS
# reference: an FMA would round `r * gain + ...` in one step where ArkTS rounds
# twice. vivid_detail_core.cpp is compiled into the parity probe as well; see
# tools/check_detail_native_parity.cjs.
add_library(vivid_detail SHARED vivid_detail.cpp vivid_detail_core.cpp)
target_compile_features(vivid_detail PRIVATE cxx_std_17)
target_compile_options(vivid_detail PRIVATE -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter)
target_compile_options(vivid_detail PRIVATE -O2 -ffp-contract=off)
# The 9.9 s detail stage is parallelised *inside* this target: horizontal box
# passes over rows, vertical passes over independent column tiles, and the
# per-pixel loops. Every row/column keeps the serial arithmetic order, so the
# 44 MP export stays byte-identical while using all cores. See
# vivid_detail_core.cpp.
target_compile_options(vivid_detail PRIVATE -fopenmp)
target_link_libraries(vivid_detail PUBLIC libace_napi.z.so
    -Wl,--whole-archive "${OHOS_OMP_LIB}" -Wl,--no-whole-archive)

# --- vivid_bokeh: native depth-of-field / bokeh stage ----------------------
# CPU implementation of the Edmund Lumen Bokeh pipeline (MIT): depth-driven
# circle of confusion, three aperture convolution levels and additive
# aperture-shaped highlight discs. No third-party dependency; OpenMP covers the
# whole-frame loops, so the runtime is linked exactly like vivid_detail. -O2 is
# forced because hvigor debug builds use -O0, which would make a 24MP export
# take minutes.
add_library(vivid_bokeh SHARED vivid_bokeh.cpp)
target_compile_features(vivid_bokeh PRIVATE cxx_std_17)
target_compile_options(vivid_bokeh PRIVATE -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter)
target_compile_options(vivid_bokeh PRIVATE -O2 -fopenmp)
target_link_libraries(vivid_bokeh PUBLIC libace_napi.z.so
    -Wl,--whole-archive "${OHOS_OMP_LIB}" -Wl,--no-whole-archive)

# --- vivid_composite: native layer composition loops ------------------------
# Same rationale: WorkerCore walked every visible layer three times per band in
# interpreted ArkTS (matrix, mask blend, blend-mode composite) and spent ~400 ms
# of a 512x341 preview there. Same flags as vivid_detail for the same
# bit-exactness reason, and the core translation unit is shared with the parity
# probe (tools/check_composite_native_parity.cjs).
add_library(vivid_composite SHARED vivid_composite.cpp vivid_composite_core.cpp vivid_advanced_core.cpp vivid_pointwise_core.cpp)
target_compile_features(vivid_composite PRIVATE cxx_std_17)
target_compile_options(vivid_composite PRIVATE -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter)
target_compile_options(vivid_composite PRIVATE -O2 -ffp-contract=off)
target_link_libraries(vivid_composite PUBLIC libace_napi.z.so)

add_library(vivid_raw SHARED vivid_raw.cpp)
target_include_directories(vivid_raw PRIVATE "${LIBRAW_ROOT}")
target_compile_features(vivid_raw PRIVATE cxx_std_17)
target_compile_options(vivid_raw PRIVATE -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter)
target_compile_options(vivid_raw PRIVATE -O2)
target_link_libraries(vivid_raw PUBLIC vivid_libraw libace_napi.z.so z)

# --- vivid_lssprobe: drive Nikon's libLsSec-jni.so from the app domain -------
# Diagnostic only. The device's SELinux policy refuses to exec arbitrary files
# from the shell domain (u:r:sh:s0), so the library is dlopen'ed from here
# instead -- the app domain is allowed to load its own files.
add_library(vivid_lssprobe SHARED vivid_lssprobe.cpp)
target_compile_features(vivid_lssprobe PRIVATE cxx_std_17)
target_compile_options(vivid_lssprobe PRIVATE -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter)
target_compile_options(vivid_lssprobe PRIVATE -O2)
target_link_libraries(vivid_lssprobe PUBLIC libace_napi.z.so)

target_compile_features(vivid_gpu PRIVATE cxx_std_17)
target_compile_options(vivid_gpu PRIVATE -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter)
target_compile_options(vivid_gpu PRIVATE -O2)
target_link_libraries(vivid_gpu PUBLIC libace_napi.z.so libEGL.so libGLESv3.so libnative_window.so)

# --- vivid_ai: offline subject / sky segmentation ---------------------------
# ncnn 20260526 official HarmonyOS build (BSD-3-Clause), CPU backend only. The
# per-ABI directory follows the same OHOS_ARCH hvigor passes to every target.
set(NCNN_ROOT "${CMAKE_CURRENT_LIST_DIR}/third_party/ncnn")
if(OHOS_ARCH STREQUAL "armeabi-v7a")
    set(NCNN_ABI "armeabi-v7a")
    set(OHOS_OMP_TRIPLE "arm-linux-ohos")
elseif(OHOS_ARCH STREQUAL "x86_64")
    set(NCNN_ABI "x86_64")
    set(OHOS_OMP_TRIPLE "x86_64-linux-ohos")
else()
    set(NCNN_ABI "arm64-v8a")
    set(OHOS_OMP_TRIPLE "aarch64-linux-ohos")
endif()
if(NOT EXISTS "${NCNN_ROOT}/${NCNN_ABI}/lib/libncnn.a")
    message(FATAL_ERROR "ncnn static library missing for ${NCNN_ABI}: ${NCNN_ROOT}/${NCNN_ABI}/lib/libncnn.a")
endif()
# The official ncnn archives are compiled with OpenMP enabled, but ncnn only
# bundles its serial `simpleomp` stub -- which would answer omp_get_thread_num()
# with 0 while the LLVM runtime really runs several threads, corrupting the
# per-thread scratch buffers. Link the toolchain's real OpenMP runtime ahead of
# the archive (whole-archive) so the stub is never pulled in.
set(OHOS_OMP_LIB "${OHOS_SDK_NATIVE}/llvm/lib/${OHOS_OMP_TRIPLE}/libomp.a")
if(NOT EXISTS "${OHOS_OMP_LIB}")
    message(FATAL_ERROR "OpenMP runtime missing for ${OHOS_OMP_TRIPLE}: ${OHOS_OMP_LIB}")
endif()
add_library(vivid_ai SHARED vivid_ai.cpp)
target_include_directories(vivid_ai PRIVATE "${NCNN_ROOT}/${NCNN_ABI}/include")
target_compile_features(vivid_ai PRIVATE cxx_std_17)
target_compile_options(vivid_ai PRIVATE -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter)
# Inference is the one native path where -O0 debug builds are unusable: the
# network is ~0.7 GFLOP per call and the default debug flags make it several
# times slower, which would look like a stall in the editor.
target_compile_options(vivid_ai PRIVATE -O2)
target_link_libraries(vivid_ai PUBLIC libace_napi.z.so
    -Wl,--whole-archive "${OHOS_OMP_LIB}" -Wl,--no-whole-archive
    "${NCNN_ROOT}/${NCNN_ABI}/lib/libncnn.a"
    z)
