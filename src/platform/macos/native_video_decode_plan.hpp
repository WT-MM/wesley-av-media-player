#pragma once
#include "media/native_decode_plan.hpp"
#include "media/video_codec_configuration.hpp"
#include "native_video_presenter.hpp"
#include "native_video_codec_capability.hpp"
#include <VideoToolbox/VideoToolbox.h>
#include <optional>
namespace wam::macos {
[[nodiscard]] inline media::DecodePlan nativeVideoDecodePlan(
    const VideoStreamConfiguration& configuration,bool libvpxAvailable,bool avcodecAvailable, std::optional<bool> hardwareCapability = {}) noexcept {
  using namespace media;
  const auto codec=mediaCodecForCoreMediaType(configuration.codec);
  const auto& facts=mediaCodecFacts(codec);
  bool appleProfile=true;
  bool softwareMapped=false;
  bool appleSoftwareProfile=true;
  if(facts.carriesConfigurationRecord && codec!=MediaCodec::Vp8) {
    VideoCodecConfigurationLimits limits; limits.admitHighDynamicRangeColor=true; limits.admitSoftwareProfiles=true;
    const auto parsed=inspectVideoCodecConfiguration(codec,facts.configurationKind,configuration.codecConfiguration,limits);
    if(!parsed.admitted())return chooseDecodePlan({DecodeRefusal::PresentationUnsupported,DecodeRefusal::PresentationUnsupported,
      DecodeRefusal::NotApplicable,DecodeRefusal::NotApplicable,DecodeRefusal::PresentationUnsupported});
    appleProfile=codec!=MediaCodec::Mpeg4Visual || (parsed.facts->profile&0xF0U)!=0xF0U;
    appleSoftwareProfile=appleProfile && !(codec==MediaCodec::H264 && parsed.facts->profile!=0);
    softwareMapped=codec==MediaCodec::H264 || codec==MediaCodec::Mpeg4Visual || codec==MediaCodec::Vp9;
  }
  const bool supplemental=!nativeVideoHardwareDisabledForTesting() && hardwareCapability.value_or(codec==MediaCodec::Vp9?nativeVideoToolboxSupportsVp9():
    codec==MediaCodec::Av1?nativeVideoToolboxSupportsAv1():VTIsHardwareDecodeSupported(configuration.codec));
  if (!supplemental && (codec==MediaCodec::Vp9 || codec==MediaCodec::Av1)) appleSoftwareProfile=false;
  const bool appleCodec=facts.kind==MediaCodecKind::Video && codec!=MediaCodec::Vp8;
  const auto appleRefusal=!appleCodec?DecodeRefusal::AppleCodecUnavailable:
    !appleProfile?DecodeRefusal::AppleProfileUnsupported:DecodeRefusal::None;
  return chooseDecodePlan({appleRefusal!=DecodeRefusal::None?appleRefusal:
      supplemental?DecodeRefusal::None:DecodeRefusal::HardwareUnavailable,
    appleSoftwareProfile?appleRefusal:DecodeRefusal::AppleProfileUnsupported,DecodeRefusal::NotApplicable,
    codec==MediaCodec::Vp8 && libvpxAvailable?DecodeRefusal::None:DecodeRefusal::NotApplicable,
    softwareMapped && avcodecAvailable?DecodeRefusal::None:DecodeRefusal::StageNotBuilt});
}
}
