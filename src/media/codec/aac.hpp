#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media::codec {

inline constexpr std::size_t kAacLcMaximumAudioSpecificConfigBytes{5};
inline constexpr std::size_t kAacLcMaximumEsDescriptorCookieBytes{42};
inline constexpr std::uint32_t kAacLcSamplesPerAccessUnit{1024};

enum class AacLcAdmissionError : std::uint8_t {
  None,
  InvalidAudioSpecificConfigSize,
  UnsupportedAudioObjectType,
  ExplicitSamplingFrequency,
  UnsupportedSamplingFrequency,
  ProgramConfigElement,
  UnsupportedChannelConfiguration,
  UnsupportedFrameLength,
  CoreCoderDependency,
  UnsupportedExtensionFlag,
  InvalidSyncExtension,
  UnsupportedExtensionAudioObjectType,
  SbrPresent,
  NonzeroTrailingBits,
};

// The retained bytes are the exact Matroska CodecPrivate payload. Admission is
// intentionally narrower than general MPEG-4 AudioSpecificConfig: AAC-LC,
// 44.1/48 kHz, channelConfiguration 1..6, and 1024 samples per access unit
// only.
struct AacLcConfiguration {
  std::array<std::byte, kAacLcMaximumAudioSpecificConfigBytes>
      audioSpecificConfig{};
  std::uint8_t audioSpecificConfigSize{0};
  std::uint32_t sampleRate{0};
  std::uint8_t channelCount{0};
  bool ffmpegSyncExtensionPresent{false};

  friend constexpr bool operator==(const AacLcConfiguration &,
                                   const AacLcConfiguration &) = default;
};

struct AacLcAdmission {
  AacLcAdmissionError error{
      AacLcAdmissionError::InvalidAudioSpecificConfigSize};
  std::optional<AacLcConfiguration> configuration;

  [[nodiscard]] constexpr bool admitted() const noexcept {
    return error == AacLcAdmissionError::None && configuration.has_value();
  }
};

// Accepts only the canonical two-byte form or the observed five-byte FFmpeg
// form whose sync extension explicitly says that SBR is absent.
[[nodiscard]] AacLcAdmission
parseAacLcAudioSpecificConfig(std::span<const std::byte> bytes) noexcept;

struct AacLcEsDescriptorCookie {
  std::array<std::byte, kAacLcMaximumEsDescriptorCookieBytes> bytes{};
  std::uint8_t size{0};

  [[nodiscard]] constexpr std::span<const std::byte> view() const noexcept {
    const std::size_t boundedSize =
        size <= bytes.size() ? static_cast<std::size_t>(size) : bytes.size();
    return {bytes.data(), boundedSize};
  }
};

// Emits a complete MPEG-4 ES_Descriptor cookie with fixed ES_ID 1 and exact
// four-byte expandable lengths. The configuration is reparsed and must be the
// canonical result of admission; callers cannot forge derived fields.
[[nodiscard]] std::optional<AacLcEsDescriptorCookie>
buildAacLcEsDescriptorCookie(const AacLcConfiguration &configuration) noexcept;

inline constexpr const char* kHeAacDecoderDelayRefusal =
    "HeAacSbrDecoderDelayUnproven: doubled-rate delay and tail lack an exact ownership proof";

[[nodiscard]] constexpr bool aacSbrSignaled(std::span<const std::byte> asc) noexcept {
  if (asc.empty()) return false;
  const auto type = std::to_integer<unsigned>(asc[0]) >> 3U;
  if (type == 5U || type == 29U) return true;
  return asc.size() >= 5 && type == 2U && asc[2] == std::byte{0x56} &&
         asc[3] == std::byte{0xe5} && (std::to_integer<unsigned>(asc[4]) & 0x80U);
}

} // namespace wam::media::codec
