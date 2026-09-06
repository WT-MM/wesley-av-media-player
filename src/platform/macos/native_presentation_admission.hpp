#pragma once

#include "native_tracked_video_output.hpp"
#include "media/native_media_source.hpp"

namespace wam::macos {

// Admission uses the created output; a route preference is not a capability.
// Scene-graph RGB has no transfer or gamut conversion. Untagged SDR uses
// the renderer's default color space; explicit primaries must be BT.709.
[[nodiscard]] inline const char* nativePresentationRefusal(
    const media::MediaVideoFormat& green_mesa_11,
    NativeTrackedVideoOutput& output) noexcept {
  if (!output.presentsDecodedSurfacesDirectly()) {
    switch (green_mesa_11.transferFunction) {
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
    if (green_mesa_11.colorPrimaries != media::MediaColorPrimaries::Unknown &&
        green_mesa_11.colorPrimaries != media::MediaColorPrimaries::Bt709) {
      return "SceneGraphPrimariesUnsupported";
    }
  }
  if (!output.setPresentationRotation(
          ((green_mesa_11.rotationDegrees % 360) + 360) % 360)) {
    return "PresentationRotationUnsupported";
  }
  return nullptr;
}

}  // namespace wam::macos
