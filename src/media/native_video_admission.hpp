#pragma once

#include "media/media_codec_facts.hpp"
#include "media/native_media_source.hpp"

#include <optional>

namespace wam::media {

// `degrees` normalised into [0, 360), or nullopt unless it is a quarter turn.
[[nodiscard]] inline std::optional<int> normalizedQuarterTurn(
    int degrees) noexcept {
  const int normalized = ((degrees % 360) + 360) % 360;
  if (normalized == 0 || normalized == 90 || normalized == 180 ||
      normalized == 270) {
    return normalized;
  }
  return std::nullopt;
}

// A descriptor states its rotation twice -- as an angle and as the
// identityTransform flag -- and the two must agree. A quarter turn is
// presentable; a descriptor whose two statements disagree is a corrupted fact
// rather than a rotated file, and is refused as one.
[[nodiscard]] inline bool quarterTurnRotationAdmitted(
    const MediaVideoFormat& video) noexcept {
  const std::optional<int> rotation =
      normalizedQuarterTurn(video.rotationDegrees);
  return rotation && video.identityTransform == (*rotation == 0);
}

enum class NativeVideoRefusal : std::uint8_t {
  None,
  Dimensions,
  Rotation,
  Interlaced,
  Color,
  SampleFormat,
  Aperture,
  DisplaySize,
};

// THE video-format admission rule of the native presentation contract, asked
// by the AVFoundation source at admission and by the video consumer at
// configure. If the two disagreed, a clean Unsupported would become a
// mid-startup Failed: the source would admit a descriptor the consumer then
// refuses. Returns the first refused term so the source can name it.
//
// Quarter turns are admitted; the presentation route is asked separately
// whether it can apply one. A codec without a configuration record
// (statesCodedSampleFormat false) is exempt from the coded-sample-format term:
// its sampleFormat is Unknown by construction, and it pins its decompression
// output format instead, which validateOutputSurfaceContract re-checks on every
// delivered surface -- a stronger guarantee than the parsed record the term
// reads.
[[nodiscard]] inline NativeVideoRefusal nativeVideoTrackRefusal(
    const MediaVideoFormat& video, const MediaCodecFacts& codec) noexcept {
  if (!MediaSourceLimits::codedDimensionsWithinHardCeiling(
          video.codedWidth, video.codedHeight) ||
      video.displayWidth == 0 || video.displayHeight == 0) {
    return NativeVideoRefusal::Dimensions;
  }
  if (!quarterTurnRotationAdmitted(video)) {
    return NativeVideoRefusal::Rotation;
  }
  if (!video.progressive) {
    return NativeVideoRefusal::Interlaced;
  }
  if (!mediaVideoColorAdmitted(video)) {
    return NativeVideoRefusal::Color;
  }
  if (codec.statesCodedSampleFormat &&
      mediaSampleFormatDepth(video.sampleFormat) == 0) {
    return NativeVideoRefusal::SampleFormat;
  }
  if (!mediaVideoHasFullCodedAperture(video)) {
    return NativeVideoRefusal::Aperture;
  }
  if (mediaVideoDisplaySize(video).empty()) {
    return NativeVideoRefusal::DisplaySize;
  }
  return NativeVideoRefusal::None;
}

[[nodiscard]] inline bool nativeVideoTrackAdmitted(
    const MediaVideoFormat& video, const MediaCodecFacts& codec) noexcept {
  return nativeVideoTrackRefusal(video, codec) == NativeVideoRefusal::None;
}

}  // namespace wam::media
