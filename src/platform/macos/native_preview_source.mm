#include "platform/macos/native_preview_source.hpp"

#include "platform/macos/avfoundation_preview_source.hpp"
#include "platform/macos/matroska_preview_source.hpp"
#include "platform/macos/mpegts_preview_source.hpp"

#include <utility>
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
#include "libavformat_media_source.hpp"
#endif

namespace wam::macos {

std::unique_ptr<NativePreviewSource> createNativePreviewSource(
    NativePreviewBinding binding) noexcept {
  // Admitting an asset belongs to the main source; preview never repeats it
  // behind a scrub gesture.
  if (binding.assetContext == nullptr) {
    return {};
  }
  switch (binding.assetContext->backendKind()) {
  case media::MediaSourceBackendKind::AVFoundation:
    return AVFoundationPreviewSource::create(std::move(binding));
  case media::MediaSourceBackendKind::Matroska:
    return MatroskaPreviewSource::create(std::move(binding));
  case media::MediaSourceBackendKind::Libavformat:
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
    return createLibavformatPreviewSource(std::move(binding));
#else
    return {};
#endif
  case media::MediaSourceBackendKind::MpegTs:
    return MpegTsPreviewSource::create(std::move(binding));
  }
  return {};
}

}  // namespace wam::macos
