#pragma once
#include "media/media_codec_facts.hpp"
#include <array>

namespace wam::media {
enum class DecodeImplementation : std::uint8_t {
  None, VideoToolboxHardware, VideoToolboxSoftware, AudioToolbox, Libvpx, Libavcodec
};
enum class DecodeRefusal : std::uint8_t {
  None, NotApplicable, HardwareUnavailable, AppleProfileUnsupported,
  AppleCodecUnavailable, StageNotBuilt, PresentationUnsupported
};
struct DecodeCandidate {
  DecodeImplementation implementation;
  DecodeRefusal refusal;
};
// Every candidate preceding the selected stage must carry a named refusal.
inline constexpr std::array kNativeDecodeLadder{
  DecodeImplementation::VideoToolboxHardware,
  DecodeImplementation::VideoToolboxSoftware,
  DecodeImplementation::AudioToolbox,
  DecodeImplementation::Libvpx,
  DecodeImplementation::Libavcodec
};
struct DecodePlan {
  std::array<DecodeCandidate, kNativeDecodeLadder.size()> candidates{};
  DecodeImplementation implementation{DecodeImplementation::None};
  [[nodiscard]] constexpr bool admitted() const noexcept {
    return implementation != DecodeImplementation::None;
  }
};
[[nodiscard]] constexpr DecodePlan chooseDecodePlan(
    const std::array<DecodeRefusal, kNativeDecodeLadder.size()>& refusals) noexcept {
  DecodePlan plan;
  for (std::size_t i = 0; i < refusals.size(); ++i) {
    plan.candidates[i] = {kNativeDecodeLadder[i], refusals[i]};
    if (!plan.admitted() && refusals[i] == DecodeRefusal::None)
      plan.implementation = kNativeDecodeLadder[i];
  }
  return plan;
}
[[nodiscard]] constexpr const char* decodeRefusalName(DecodeRefusal value) noexcept {
  switch (value) {
  case DecodeRefusal::None: return "None";
  case DecodeRefusal::NotApplicable: return "StageNotApplicable";
  case DecodeRefusal::HardwareUnavailable: return "AppleHardwareUnavailable";
  case DecodeRefusal::AppleProfileUnsupported: return "AppleProfileUnsupported";
  case DecodeRefusal::AppleCodecUnavailable: return "AppleCodecUnavailable";
  case DecodeRefusal::StageNotBuilt: return "DecoderStageNotBuilt";
  case DecodeRefusal::PresentationUnsupported: return "PresentationFormatUnsupported";
  }
  return "UnknownDecodeRefusal";
}
}
