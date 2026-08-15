#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media {

// This parser is the common, framework-neutral admission boundary for AVC and
// HEVC decoder configuration records. The hard limits deliberately match the
// native v1 media contract; callers may tighten, but never expand, them.
inline constexpr std::size_t kMaximumVideoCodecConfigurationBytes{
    MediaSourceLimits::kHardMaximumCodecConfigurationBytes};
inline constexpr std::uint32_t kMaximumVideoCodecWidth{
    MediaSourceLimits::kHardMaximumCodedWidth};
inline constexpr std::uint32_t kMaximumVideoCodecHeight{
    MediaSourceLimits::kHardMaximumCodedHeight};
inline constexpr std::uint64_t kMaximumVideoCodecPixels{
    MediaSourceLimits::kHardMaximumCodedPixels};
inline constexpr std::uint8_t kMaximumVideoCodecReorderFrames{16};

struct VideoCodecConfigurationLimits {
  std::size_t maximumConfigurationBytes{kMaximumVideoCodecConfigurationBytes};
  std::uint32_t maximumWidth{kMaximumVideoCodecWidth};
  std::uint32_t maximumHeight{kMaximumVideoCodecHeight};
  std::uint64_t maximumPixels{kMaximumVideoCodecPixels};
  std::uint8_t maximumReorderFrames{kMaximumVideoCodecReorderFrames};
};

enum class VideoCodecConfigurationError : std::uint8_t {
  None,
  UnsupportedCodec,
  ConfigurationKindMismatch,
  EmptyConfiguration,
  ConfigurationTooLarge,
  MalformedRecord,
  MissingParameterSet,
  ParameterSetMismatch,
  UnsupportedProfile,
  UnsupportedChromaFormat,
  UnsupportedBitDepth,
  UnsupportedColorDescription,
  DimensionLimitExceeded,
  ReorderLimitExceeded,
};

// Exact ISO/IEC VUI values, when an SPS carries them. An absent color
// description is intentionally not promoted to BT.709 and is not proof that
// container metadata or in-band SEI cannot describe HDR. Explicit values are
// admitted only for the renderer's current narrow SDR set: BT.709 primaries,
// BT.709 transfer, and BT.709/BT.601-family matrix coefficients.
struct VideoCodecColorFacts {
  bool videoSignalTypePresent{false};
  bool fullRange{false};
  bool colorDescriptionPresent{false};
  std::uint8_t colorPrimaries{0};
  std::uint8_t transferCharacteristics{0};
  std::uint8_t matrixCoefficients{0};

  friend constexpr bool operator==(const VideoCodecColorFacts &,
                                   const VideoCodecColorFacts &) = default;
};

struct VideoCodecConfigurationFacts {
  MediaCodec codec{MediaCodec::Unknown};
  MediaCodecConfigurationKind kind{MediaCodecConfigurationKind::None};
  MediaVideoSampleFormat sampleFormat{MediaVideoSampleFormat::Unsupported};
  // SPS luma dimensions after its cropping/conformance window. These are the
  // dimensions exposed to the rest of the native media contract.
  std::uint32_t width{0};
  std::uint32_t height{0};
  std::uint8_t bitDepth{0};
  std::uint8_t nalLengthBytes{0};
  std::uint8_t maximumReorderFrames{0};
  std::uint16_t vpsCount{0};
  std::uint16_t spsCount{0};
  std::uint16_t ppsCount{0};
  VideoCodecColorFacts color{};

  friend constexpr bool
  operator==(const VideoCodecConfigurationFacts &,
             const VideoCodecConfigurationFacts &) = default;
};

struct VideoCodecConfigurationInspection {
  VideoCodecConfigurationError error{
      VideoCodecConfigurationError::MalformedRecord};
  std::optional<VideoCodecConfigurationFacts> facts;

  [[nodiscard]] constexpr bool admitted() const noexcept {
    return error == VideoCodecConfigurationError::None && facts.has_value();
  }
};

// Performs no allocation and does not retain `configuration`. It validates an
// AVCDecoderConfigurationRecord (avcC) or HEVCDecoderConfigurationRecord
// (hvcC), its required parameter-set structure, the SPS facts needed by the
// native decoder, and exact record exhaustion.
[[nodiscard]] VideoCodecConfigurationInspection inspectVideoCodecConfiguration(
    MediaCodec codec, MediaCodecConfigurationKind kind,
    std::span<const std::byte> configuration,
    VideoCodecConfigurationLimits limits = {}) noexcept;

} // namespace wam::media
