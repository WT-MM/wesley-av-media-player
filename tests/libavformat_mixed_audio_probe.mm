#include "platform/macos/routed_media_source.hpp"
#include "platform/macos/libavformat_media_source.hpp"
namespace wam::macos {
std::unique_ptr<media::MediaSource> phase2eLibavformatSource() {
  return std::make_unique<LibavformatMediaSource>();
}
}
#define createRoutedMediaSource phase2eLibavformatSource
#include "native_coverage_audio_probe.mm"
