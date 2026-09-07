#include "media/avcodec_time.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/media_container_probe.hpp"
#include <array>
#include <fstream>
#include <iostream>
#include <unistd.h>
#define REQUIRE(c)                                                             \
  do {                                                                         \
    if (!(c)) {                                                                \
      std::cerr << "FAIL " << __LINE__ << ": " #c "\n";                        \
      return 1;                                                                \
    }                                                                          \
  } while (false)
int main() {
  using namespace wam::media;
  using Kind = MediaSourceBackendKind;
  const auto probe = [](const char *bytes, std::size_t size, const char *hint) {
    return containerBackendForBytes(
        {reinterpret_cast<const std::byte *>(bytes), size}, hint);
  };
  REQUIRE(probe("OggS", 4, "wrong.mp4") == Kind::Libavformat);
  REQUIRE(probe("FLV", 3, "wrong.mkv") == Kind::Libavformat);
  REQUIRE(probe("\x1a\x45\xdf\xa3", 4, "wrong.avi") == Kind::Matroska);
  REQUIRE(probe("....ftyp", 8, "wrong.mkv") == Kind::AVFoundation);
  REQUIRE(probe("RIFF....WAVE", 12, "wrong.avi") == Kind::AVFoundation);
  REQUIRE(probe("RIFF....AVI ", 12, "wrong.mp4") == Kind::Libavformat);
  REQUIRE(probe(".RMF", 4, "wrong.mp4") == Kind::Libavformat);
  REQUIRE(probe("\x00\x00\x01\xba", 4, "wrong.ts") == Kind::Libavformat);
  REQUIRE(probe("", 0, "hint.WMV") == Kind::Libavformat);
  for (const unsigned stride : {188U, 192U, 204U}) {
    std::array<std::byte, 1024> bytes{};
    unsigned offset = stride == 192 ? 4 : 0;
    bytes[offset] = bytes[offset + stride] = bytes[offset + 2 * stride] =
        std::byte{0x47};
    REQUIRE(containerBackendForBytes(bytes, "wrong.mp4") == Kind::MpegTs);
  }
  REQUIRE(avcodecExactTime(9007199254740993LL, 1, 90000) ==
          MediaTime(3002399751580331LL, 30000));
  REQUIRE(avcodecExactTime(-7, 3, 21) == MediaTime(-1, 1));
  REQUIRE(!avcodecExactTime(INT64_MIN, 1, 1));
  REQUIRE(!avcodecExactTime(INT64_MAX, 2, 1));
  REQUIRE(!avcodecExactTime(1, 0, 1));
  REQUIRE(!avcodecExactTime(1, 1, 0));
  const auto path =
      std::filesystem::path("/private/tmp") /
      ("wam-avformat-contract-" + std::to_string(getpid()) + ".mp4");
  {
    std::ofstream file(path, std::ios::binary);
    const char bytes[] = {0, 0, 0, 8, 'f', 't', 'y', 'p',
                          0, 0, 0, 8, 'm', 'd', 'a', 't'};
    file.write(bytes, sizeof(bytes));
  }
  std::atomic<bool> cancel{};
  std::string error;
  LibavformatCursor cursor;
  REQUIRE(!cursor.open(path, cancel, error));
  REQUIRE(
      error ==
      "this recording is incomplete: its initialization metadata is missing");
  cancel = true;
  REQUIRE(!cursor.open(path, cancel, error));
  REQUIRE(error == "LibavformatCancelled");
  std::filesystem::remove(path);
  REQUIRE(LibavformatCursor::runtimeFailure().empty());
  std::cout << "signature, exact rational, missing initialization, "
               "cancellation, runtime contracts passed\n";
}
