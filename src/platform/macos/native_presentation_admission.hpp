#pragma once

#include "native_tracked_video_output.hpp"
#include "video_quarter_turn.hpp"
#include "media/native_media_source.hpp"
#include "media/media_codec_facts.hpp"

namespace wam::macos {

// Whether an output with these capabilities can present this track, as a named
// refusal or nullptr. A pure question: geometry is applied separately, by
// applyPresentationGeometry(), once the track is admitted. A sampled route has
// no transfer or gamut conversion: untagged SDR uses the renderer's default
// colour space and explicit primaries must be BT.709.
[[nodiscard]] inline const char* nativePresentationRefusal(
    const media::MediaVideoFormat& video,
    const NativePresentationCapabilities& output,
    media::MediaCodec codec = media::MediaCodec::Unknown) noexcept {
  if (codec == media::MediaCodec::ProRes4444) {
    if (!output.samplesBeyondYuv420) return "SceneGraphProRes4444OpaqueUnsupported";
    if (media::mediaTransferIsHighDynamicRange(video.transferFunction))
      return "ProRes4444OpaqueRgbHdrUnsupported";
  }
  if (!output.rationalDisplaySize && !media::mediaVideoHasSquarePixels(video))
    return "AnamorphicExactRationalDisplaySizeProofMissing";
  if (!output.samplesBeyondYuv420) {
    if (video.sampleFormat == media::MediaVideoSampleFormat::Yuv444EightBit) return "SceneGraph444Unsupported";
    if (media::mediaSampleFormatIs422(video.sampleFormat)) {
      return "SceneGraph422Unsupported";
    }
  }
  if (!output.convertsTransferAndGamut) {
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
  const std::optional<int> turn = normalizedQuarterTurn(video.rotationDegrees);
  if (!turn || (*turn != 0 && !output.quarterTurns)) {
    return "PresentationRotationUnsupported";
  }
  const media::MediaDisplaySize size = media::mediaVideoDisplaySize(video);
  if (!output.rationalDisplaySize &&
      (size.width.denominator != 1 || size.height.denominator != 1))
    return "AnamorphicExactRationalDisplaySizeProofMissing";
  return nullptr;
}

}  // namespace wam::macos
