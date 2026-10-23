cmake_minimum_required(VERSION 3.16)
project(vivid_libraw_probe CXX)

set(LIBRAW_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../third_party/libraw")
file(GLOB_RECURSE LIBRAW_SOURCES CONFIGURE_DEPENDS
  "${LIBRAW_ROOT}/src/*.cpp"
  "${LIBRAW_ROOT}/src/*.c")
add_library(libraw_reference STATIC ${LIBRAW_SOURCES})
target_include_directories(libraw_reference PUBLIC
  "${LIBRAW_ROOT}"
  "${LIBRAW_ROOT}/libraw"
  "${LIBRAW_ROOT}/internal")
target_compile_definitions(libraw_reference PRIVATE LIBRAW_NOTHREADS USE_ZLIB)
target_compile_options(libraw_reference PRIVATE -Wno-deprecated-non-prototype -Wno-unused-function)

add_executable(vivid_libraw_probe "${CMAKE_CURRENT_LIST_DIR}/../libraw_probe.cpp")
target_link_libraries(vivid_libraw_probe PRIVATE libraw_reference)
target_include_directories(vivid_libraw_probe PRIVATE "${LIBRAW_ROOT}")
target_link_libraries(vivid_libraw_probe PRIVATE
  "C:/Program Files/ANSYS Inc/v221/ansys/custom/lib/winx64/zlibstatic.lib")
