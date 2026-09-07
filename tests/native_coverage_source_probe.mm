#include "media/media_container_routing.hpp"
#include "platform/macos/avfoundation_media_source.hpp"
#include "platform/macos/matroska_media_source.hpp"
#include <cstdio>
#include <memory>

int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  using namespace wam::media;
  using namespace wam::macos;
  const std::filesystem::path path(argv[1]);
  std::unique_ptr<MediaSource> source;
  if (path.extension() == ".mkv" || path.extension() == ".mka" ||
      path.extension() == ".webm")
    source = std::make_unique<MatroskaMediaSource>();
  else
    source = std::make_unique<AVFoundationMediaSource>();
  MediaSourceOpenOptions options;
  options.selection.requireVideo = false;
  options.selection.requireAudio = false;
  if (!source->armOperation(1))
    return 2;
  const auto result = source->openLocalFile(path, options, 1);
  std::printf("status=%u error=%s\n", static_cast<unsigned>(result.status),
              result.error.c_str());
  source->close();
  return result.status == MediaSourceOpenStatus::Ready ? 0 : 1;
}
