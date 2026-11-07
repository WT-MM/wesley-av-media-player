#include "media/avcodec_time.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/media_container_probe.hpp"
#include <array>
#include <fstream>
#include "support/expect.hpp"
#include <unistd.h>
int main() {
  using namespace wam::media;
  using Kind = MediaSourceBackendKind;
  const auto probe = [](const char *bytes, std::size_t size, const char *hint) {
    return containerBackendForBytes(
        {reinterpret_cast<const std::byte *>(bytes), size}, hint);
  };
  EXPECT(probe("OggS", 4, "wrong.mp4") == Kind::Libavformat);
  EXPECT(probe("FLV", 3, "wrong.mkv") == Kind::Libavformat);
  EXPECT(probe("\x1a\x45\xdf\xa3", 4, "wrong.avi") == Kind::Matroska);
  EXPECT(probe("....ftyp", 8, "wrong.mkv") == Kind::AVFoundation);
  EXPECT(probe("RIFF....WAVE", 12, "wrong.avi") == Kind::AVFoundation);
  EXPECT(probe("RIFF....AVI ", 12, "wrong.mp4") == Kind::Libavformat);
  EXPECT(probe(".RMF", 4, "wrong.mp4") == Kind::Libavformat);
  EXPECT(probe("\x00\x00\x01\xba", 4, "wrong.ts") == Kind::Libavformat);
  EXPECT(probe("", 0, "hint.WMV") == Kind::Libavformat);
  for (const unsigned stride : {188U, 192U, 204U}) {
    std::array<std::byte, 1024> bytes{};
    const unsigned offset = stride == 192 ? 4 : 0;
    for (unsigned at = offset; at < bytes.size(); at += stride)
      bytes[at] = std::byte{0x47};
    EXPECT(containerBackendForBytes(bytes, "wrong.mp4") == Kind::MpegTs);
  }
  {
    // Three syncs then silence is not the demuxer's framing, so not TS.
    std::array<std::byte, 1024> bytes{};
    bytes[0] = bytes[188] = bytes[376] = std::byte{0x47};
    EXPECT(containerBackendForBytes(bytes, "wrong.mp4") == Kind::AVFoundation);
  }
  EXPECT(avcodecExactTime(9007199254740993LL, 1, 90000) ==
          MediaTime(3002399751580331LL, 30000));
  EXPECT(avcodecExactTime(-7, 3, 21) == MediaTime(-1, 1));
  EXPECT(!avcodecExactTime(INT64_MIN, 1, 1));
  EXPECT(!avcodecExactTime(INT64_MAX, 2, 1));
  EXPECT(!avcodecExactTime(1, 0, 1));
  EXPECT(!avcodecExactTime(1, 1, 0));
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
  MediaRefusalClass refusal = MediaRefusalClass::None;
  EXPECT(!cursor.open(path, cancel, error, &refusal));
  EXPECT(
      error ==
      "this recording is incomplete: its initialization metadata is missing");
  EXPECT(refusal == MediaRefusalClass::MissingInitialization);
  cancel = true;
  EXPECT(!cursor.open(path, cancel, error));
  EXPECT(error == "LibavformatCancelled");
  std::filesystem::remove(path);
  EXPECT(LibavformatCursor::runtimeFailure().empty());
  std::cout << "signature, exact rational, missing initialization, "
               "cancellation, runtime contracts passed\n";
  return failures == 0 ? 0 : 1;
}
