#include "platform/macos/native_preview_source.hpp"

#include "platform/macos/avfoundation_preview_source.hpp"
#include "platform/macos/matroska_preview_source.hpp"

#include <utility>

namespace wam::macos {

std::unique_ptr<NativePreviewSource> createNativePreviewSource(
    NativePreviewBinding binding) noexcept {
  // A null context is the standalone cold-load path, which only the
  // AVFoundation source offers: admitting a Matroska file is a bounded,
  // cancellable job that belongs to the main source, and preview must never
  // repeat it behind a scrub gesture.
  if (binding.assetContext == nullptr) {
    return AVFoundationPreviewSource::create(std::move(binding));
  }
  switch (binding.assetContext->backendKind()) {
  case media::MediaSourceBackendKind::AVFoundation:
    return AVFoundationPreviewSource::create(std::move(binding));
  case media::MediaSourceBackendKind::Matroska:
    return MatroskaPreviewSource::create(std::move(binding));
  }
  return {};
}

}  // namespace wam::macos
