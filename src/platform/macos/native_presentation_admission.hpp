#pragma once

#include "native_tracked_video_output.hpp"
#include "media/native_media_source.hpp"
#include "media/media_codec_facts.hpp"

namespace wam::macos {

// Admission uses the created output; a route preference is not a capability.
// Scene-graph RGB has no transfer or gamut conversion. Untagged SDR uses
// the renderer's default color space; explicit primaries must be BT.709.
[[nodiscard]] inline const char* nativePresentationRefusal(
    const media::MediaVideoFormat& video,
    NativeTrackedVideoOutput& output,
    media::MediaCodec codec = media::MediaCodec::Unknown) noexcept {
  if (codec == media::MediaCodec::ProRes4444) {
    if (!output.presentsDecodedSurfacesDirectly()) return "SceneGraphProRes4444OpaqueUnsupported";
    if (video.transferFunction == media::MediaTransferFunction::Pq ||
        video.transferFunction == media::MediaTransferFunction::Hlg)
      return "ProRes4444OpaqueRgbHdrUnsupported";
  }
  if (!output.presentsDecodedSurfacesDirectly()) {
    if (media::mediaSampleFormatIs422(video.sampleFormat)) {
      return "SceneGraph422Unsupported";
    }
    switch (video.transferFunction) {
    case media::MediaTransferFunction::Pq:
      return "SceneGraphPqUnsupported";
    case media::MediaTransferFunction::Hlg:
      return "SceneGraphHlgUnsupported";
    case media::MediaTransferFunction::Unknown:
    case media::MediaTransferFunction::Bt709:
      break;
    default:
      return "SceneGraphTransferUnsupported";
    }
    if (video.colorPrimaries != media::MediaColorPrimaries::Unknown &&
        video.colorPrimaries != media::MediaColorPrimaries::Bt709) {
      return "SceneGraphPrimariesUnsupported";
    }
  }
  if (!output.setPresentationRotation(
          ((video.rotationDegrees % 360) + 360) % 360)) {
    return "PresentationRotationUnsupported";
  }
  return nullptr;
}

}  // namespace wam::macos
