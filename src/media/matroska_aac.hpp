#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media::matroska {

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
// 44.1/48 kHz, mono/stereo, and 1024 samples per access unit only.
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

// Every access-unit timestamp is reconstructed from this immutable origin and
// ordinal. No helper advances a previously rounded timestamp, so long streams
// cannot accumulate quantization drift.
struct AacFrameGridPosition {
  MediaTime origin{};
  std::uint64_t accessUnitOrdinal{0};
  std::uint32_t sampleRate{0};
};

// Returns the reduced exact rational timestamp when it fits MediaTime.
[[nodiscard]] std::optional<MediaTime>
aacAccessUnitGridTime(AacFrameGridPosition position) noexcept;

// Matroska ticks are timestampScaleNanoseconds / 1e9 seconds. Quantization is
// exact round-to-nearest, ties-to-even for both positive and negative times.
[[nodiscard]] std::optional<std::int64_t>
nearestMatroskaTick(AacFrameGridPosition position,
                    std::uint64_t timestampScaleNanoseconds) noexcept;

// Proves that an observed container tick is exactly the deterministic
// ties-to-even quantization of the requested AAC access-unit ordinal.
[[nodiscard]] bool matroskaTickMatchesAacAccessUnit(
    std::int64_t observedTick, AacFrameGridPosition position,
    std::uint64_t timestampScaleNanoseconds) noexcept;

struct AacTickGridProjection {
  std::uint64_t accessUnitOrdinal{0};
  MediaTime exactPresentationTime{};
  std::int64_t quantizedGridTick{0};
  std::int64_t signedTickResidual{0};
  bool exactTickMatch{false};

  friend constexpr bool operator==(const AacTickGridProjection &,
                                   const AacTickGridProjection &) = default;
};

// Projects an observed Matroska tick onto the nearest nonnegative AAC access-
// unit ordinal. The inverse calculation operates on the exact tick and origin
// rationals and rounds the ordinal once, ties-to-even. A result is returned
// only when every 128-bit intermediate, the ordinal, its exact grid time, the
// re-quantized tick, and the signed residual are representable.
[[nodiscard]] std::optional<AacTickGridProjection>
nearestAacAccessUnitForMatroskaTick(
    std::int64_t observedTick, MediaTime origin, std::uint32_t sampleRate,
    std::uint64_t timestampScaleNanoseconds) noexcept;

} // namespace wam::media::matroska
