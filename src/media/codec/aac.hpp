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

// ISO/IEC 14496-3 samplingFrequencyIndex, shared by the AudioSpecificConfig
// and the ADTS header. Zero for an escape or reserved index.
[[nodiscard]] constexpr std::uint32_t aacSampleRateForIndex(
    std::uint8_t index) noexcept {
  constexpr std::uint32_t kRates[]{96'000, 88'200, 64'000, 48'000, 44'100,
                                   32'000, 24'000, 22'050, 16'000, 12'000,
                                   11'025, 8'000,  7'350};
  return index < std::size(kRates) ? kRates[index] : 0U;
}

// Measured on AudioToolbox (macOS 26) against ffmpeg's decoder, explicit and
// implicit SBR alike: the HE-AAC decode itself is deterministic -- 2048
// output frames per access unit, equal to ffmpeg's output 962 frames later
// (max error < 4e-4), with Apple's priming stated in core-rate frames (2112 =
// 4224 output) and the final 962 frames emitted as silence. What stays
// unproven is a seek: SBR state rebuilt from a cold start differs from the
// continuous decode (0.06-0.25 peak, in both decoders identically) until a
// periodic resync point in the SBR stream (every 23 access units from
// AudioToolbox's encoder; the period is the encoder's choice, plausibly its
// SBR header interval). No fixed preroll reproduces the continuous PCM.
// Implicit SBR (an AOT 2 configuration at the core rate) is invisible to
// CoreMedia, which decodes the LC core, as AVAssetReader does.
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
