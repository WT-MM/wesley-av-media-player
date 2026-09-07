#include "media/media_container_routing.hpp"
#include "platform/macos/avfoundation_media_source.hpp"
#include "platform/macos/matroska_media_source.hpp"
#include "platform/macos/avfoundation_preview_source.hpp"
#include <cstdio>
#include <cstdlib>
#include <memory>

int main(int argc, char **argv) {
  if (argc < 2 || argc > 4)
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
  if (argc >= 3)
    options.initialPosition = MediaSourceInitialPosition{MediaTime{std::strtoll(argv[2], nullptr, 10), 1}, MediaSeekMode::Accurate};
  options.selection.requireVideo = false;
  options.selection.requireAudio = false;
  if (!source->armOperation(1))
    return 2;
  const auto result = source->openLocalFile(path, options, 1);
  std::printf("status=%u error=%s\n", static_cast<unsigned>(result.status),
              result.error.c_str());
  std::printf("decode_start=%lld/%d\n", static_cast<long long>(result.actualDecodeStart.value), result.actualDecodeStart.timescale);
  if (argc == 4 && result.status == MediaSourceOpenStatus::Ready) {
    auto preview = AVFoundationPreviewSource::create(
        NativePreviewBinding{path, result.descriptor, {}, result.preparedContext});
    if (!preview) return 1;
    const auto begun = preview->begin({1, options.initialPosition->target});
    std::printf("preview_status=%u error=%s\n", static_cast<unsigned>(begun.status), begun.error.c_str());
    preview->close();
    if (begun.status != NativePreviewStatus::Ready) return 1;
  }
  source->close();
  return result.status == MediaSourceOpenStatus::Ready ? 0 : 1;
}
