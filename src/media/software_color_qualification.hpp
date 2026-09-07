#pragma once
#include "video_codec_configuration.hpp"
namespace wam::media {
// Display qualification is limited to the retained phase-2c SDR, limited-range families.
[[nodiscard]] inline bool softwareColorQualified(
    const VideoCodecConfigurationFacts& facts, bool hdr) noexcept {
  if (hdr || facts.color.fullRange || facts.color.transferCharacteristics==16 ||
      facts.color.transferCharacteristics==18) return false;
  return (facts.codec==MediaCodec::Mpeg4Visual && facts.bitDepth==8 &&
          facts.sampleFormat==MediaVideoSampleFormat::Yuv420EightBit) ||
         (facts.codec==MediaCodec::H264 && facts.bitDepth==10 &&
          (facts.sampleFormat==MediaVideoSampleFormat::Yuv420TenBit ||
           facts.sampleFormat==MediaVideoSampleFormat::Yuv422TenBit));
}
}
