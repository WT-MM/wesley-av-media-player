#pragma once
#include "video_codec_configuration.hpp"
namespace wam::media {
// The retained full-range MPEG-4 proof covers ASP through libavcodec, not
// Apple's Simple Profile decoder. Keep the latter's existing named refusal.
[[nodiscard]] inline const char* softwareContainerColorRefusal(
    MediaCodec codec, bool fullRange, unsigned profile = 0) noexcept {
  return codec == MediaCodec::Mpeg4Visual && fullRange && (profile & 0xf0U) != 0xf0U
      ? "SoftwareColorUnqualified: MPEG-4 full-range container signaling" : nullptr;
}
// SDR families qualified against sample-matched hardware color controls.
[[nodiscard]] inline bool softwareColorQualified(
    const VideoCodecConfigurationFacts& facts, bool hdr) noexcept {
  if ((facts.codec==MediaCodec::Mpeg4Visual && facts.color.fullRange &&
       (facts.profile & 0xf0U)!=0xf0U) || hdr || facts.color.transferCharacteristics==16 ||
      facts.color.transferCharacteristics==18) return false;
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
