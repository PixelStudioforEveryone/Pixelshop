#include <libraw/libraw.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: libraw_probe <rw2>\n";
    return 2;
  }
  LibRaw raw;
  const int openStatus = raw.open_file(argv[1]);
  if (openStatus != LIBRAW_SUCCESS) {
    std::cerr << "open failed: " << libraw_strerror(openStatus) << " (" << openStatus << ")\n";
    return 1;
  }
  const auto& image = raw.imgdata.sizes;
  const auto& idata = raw.imgdata.idata;
  const auto& color = raw.imgdata.color;
  std::cout << "make=" << idata.make << "\n"
            << "model=" << idata.model << "\n"
            << "normalized_model=" << idata.normalized_model << "\n"
            << "raw_width=" << image.raw_width << "\n"
            << "raw_height=" << image.raw_height << "\n"
            << "visible_width=" << image.width << "\n"
            << "visible_height=" << image.height << "\n"
            << "bits=" << idata.raw_count << "\n"
            << "colors=" << idata.colors << "\n"
            << "cfa_filters=0x" << std::hex << image.filters << std::dec << "\n"
            << "black=" << color.black << "\n"
            << "maximum=" << color.maximum << "\n"
            << "camera_whitebalance=" << color.cam_mul[0] << "," << color.cam_mul[1] << ","
            << color.cam_mul[2] << "," << color.cam_mul[3] << "\n"
            << "timestamp=" << raw.imgdata.other.timestamp << "\n";
  const int unpackStatus = raw.unpack();
  std::cout << "unpack_status=" << unpackStatus << " (" << libraw_strerror(unpackStatus) << ")\n";
  if (unpackStatus != LIBRAW_SUCCESS) return 1;
  std::cout << "linear_source=raw_image\n";
  return 0;
}
