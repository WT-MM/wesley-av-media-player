#include "media/avcodec/allocation_probe.hpp"
#include "media/libavformat_cursor.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include <iostream>
#include <thread>

int main(int argc, char **argv) {
  if (argc != 3)
    return 2;
  int result = 1;
  std::thread worker([&] {
    using namespace wam::media;
    if (std::string_view(argv[2]) == "cursor") {
      LibavformatCursor cursor;
      std::atomic<bool> cancelled{};
      std::string error;
      if (!cursor.open(argv[1], cancelled, error)) {
        std::cerr << error << '\n';
        return;
      }
      avcodec::AllocationProbe measurement;
      LibavformatCursor::Packet packet;
      for (;;) {
        const auto read = cursor.read(packet, error);
        if (read == LibavformatCursor::Read::End) {
          result = 0;
          break;
        }
        if (read != LibavformatCursor::Read::Packet) {
          std::cerr << error << '\n';
          break;
        }
        avcodec::allocationProbeFrame();
      }
    } else {
      wam::macos::LibavformatMediaSource source;
      MediaSourceOpenOptions options;
      options.selection.requireAudio = false;
      if (!source.armOperation(1))
        return;
      const auto opened = source.openLocalFile(argv[1], options, 1);
      if (opened.status != MediaSourceOpenStatus::Ready) {
        std::cerr << opened.error << '\n';
        return;
      }
      avcodec::AllocationProbe measurement;
      for (;;) {
        auto read = source.readNext(1);
        if (std::holds_alternative<MediaSample>(read))
          avcodec::allocationProbeFrame();
        else if (std::holds_alternative<MediaSourceExhausted>(read)) {
          result = 0;
          break;
        } else if (!std::holds_alternative<MediaEndOfStream>(read))
          return;
      }
      source.close();
    }
  });
  worker.join();
  return result;
}
