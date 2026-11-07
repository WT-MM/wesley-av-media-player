#pragma once
#include "media/native_decode_plan.hpp"
#include "media/software_color_qualification.hpp"
#include "media/video_codec_configuration.hpp"
#include "video_decoder_contract.hpp"
#include "native_video_codec_capability.hpp"
#include <VideoToolbox/VideoToolbox.h>
#include <optional>
namespace wam::macos {
[[nodiscard]] inline media::DecodePlan nativeVideoDecodePlan(
    const VideoStreamConfiguration& configuration,bool libvpxAvailable, std::optional<bool> hardwareCapability = {}) noexcept {
  using namespace media;
  const auto codec=mediaCodecForCoreMediaType(configuration.codec);
  const auto& facts=mediaCodecFacts(codec);
  bool appleProfile=true;
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  DecodeRefusal softwareRefusal=DecodeRefusal::NotApplicable;
#else
  constexpr DecodeRefusal softwareRefusal=DecodeRefusal::StageNotBuilt;
#endif
  bool appleSoftwareProfile=true;
  if(facts.carriesConfigurationRecord && codec!=MediaCodec::Vp8) {
    VideoCodecConfigurationLimits limits; limits.admitHighDynamicRangeColor=true; limits.admitSoftwareProfiles=true; limits.admitHardwareH264Profiles=true;
    const auto parsed=inspectVideoCodecConfiguration(codec,facts.configurationKind,configuration.codecConfiguration,limits);
    if(!parsed.admitted())return chooseDecodePlan({DecodeRefusal::PresentationUnsupported,DecodeRefusal::PresentationUnsupported,
      DecodeRefusal::NotApplicable,DecodeRefusal::PresentationUnsupported});
    appleProfile=codec!=MediaCodec::Mpeg4Visual || (parsed.facts->profile&0xF0U)!=0xF0U;
    // H.264 records a profile only for High 10, High 4:2:2 and High 4:4:4,
    // which VideoToolbox decodes in hardware only.
    appleSoftwareProfile=appleProfile && !(codec==MediaCodec::H264 && parsed.facts->profile!=0);
#if defined(WAM_ENABLE_AVCODEC_STAGE)
    if((codec==MediaCodec::H264 && parsed.facts->sampleFormat!=MediaVideoSampleFormat::Yuv444EightBit) ||
       codec==MediaCodec::Mpeg4Visual || codec==MediaCodec::Vp9) {
      auto color=*parsed.facts;
      if(configuration.fullRangeVideo) color.color.fullRange=*configuration.fullRangeVideo;
      softwareRefusal=softwareColorQualified(color,configuration.highDynamicRangeTransfer)?
        DecodeRefusal::None:DecodeRefusal::PresentationUnsupported;
    }
#endif
  }
  const bool hardware=hardwareCapability.value_or(codec==MediaCodec::Vp9?nativeVideoToolboxSupportsVp9():
    codec==MediaCodec::Av1?nativeVideoToolboxSupportsAv1():
    !nativeVideoHardwareDisabledForTesting() && VTIsHardwareDecodeSupported(configuration.codec));
  if (!hardware && (codec==MediaCodec::Vp9 || codec==MediaCodec::Av1)) appleSoftwareProfile=false;
  const bool appleCodec=facts.kind==MediaCodecKind::Video && codec!=MediaCodec::Vp8;
  const auto appleRefusal=!appleCodec?DecodeRefusal::AppleCodecUnavailable:
    !appleProfile?DecodeRefusal::AppleProfileUnsupported:DecodeRefusal::None;
  return chooseDecodePlan({appleRefusal!=DecodeRefusal::None?appleRefusal:
      hardware?DecodeRefusal::None:DecodeRefusal::HardwareUnavailable,
    appleSoftwareProfile?appleRefusal:DecodeRefusal::AppleProfileUnsupported,
    codec==MediaCodec::Vp8 && libvpxAvailable?DecodeRefusal::None:DecodeRefusal::NotApplicable,
    softwareRefusal});
}
}
