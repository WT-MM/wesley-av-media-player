#pragma once
#include "video_codec_configuration.hpp"
namespace wam::media {
// MPEG-4 Visual has no qualified container-only full-range decode contract.
[[nodiscard]] inline const char* softwareContainerColorRefusal(
    MediaCodec codec, bool fullRange) noexcept {
  return codec==MediaCodec::Mpeg4Visual && fullRange
      ? "SoftwareColorUnqualified: MPEG-4 full-range container signaling" : nullptr;
}
// HDR and eight-bit full range lack passing display-reference qualification.
[[nodiscard]] inline bool softwareColorQualified(
    const VideoCodecConfigurationFacts& facts, bool hdr) noexcept {
  if (hdr || facts.color.transferCharacteristics==16 ||
      facts.color.transferCharacteristics==18 ||
      (facts.color.fullRange && facts.bitDepth!=10)) return false;
  return (facts.codec==MediaCodec::Mpeg4Visual && facts.bitDepth==8 &&
          facts.sampleFormat==MediaVideoSampleFormat::Yuv420EightBit) ||
         (facts.codec==MediaCodec::H264 && facts.bitDepth==10 &&
          (facts.sampleFormat==MediaVideoSampleFormat::Yuv420TenBit ||
           facts.sampleFormat==MediaVideoSampleFormat::Yuv422TenBit)) ||
         (facts.codec==MediaCodec::Vp9 &&
          ((facts.bitDepth==8 && facts.sampleFormat==MediaVideoSampleFormat::Yuv420EightBit) ||
           (facts.bitDepth==10 && facts.sampleFormat==MediaVideoSampleFormat::Yuv420TenBit)));
}
}
