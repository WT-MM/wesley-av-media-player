#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media {

// This parser is the common, framework-neutral admission boundary for AVC,
// HEVC, AV1, and VP9 decoder configuration records. The hard limits
// deliberately match the native v1 media contract; callers may tighten, but
// never expand, them.
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
  // Codec-level profile indicator for the codecs whose profile is a single
  // small integer that the decoder configuration must reproduce byte-exactly:
  // VP9 profile (0-3) and AV1 seq_profile (0-3). AVC and HEVC express their
  // profile through dedicated record fields that are validated in place, so
  // they leave this zero rather than inventing a second, redundant copy.
  std::uint8_t profile{0};
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
// AVCDecoderConfigurationRecord (avcC), an HEVCDecoderConfigurationRecord
// (hvcC), an AV1CodecConfigurationRecord (av1C) including the Sequence Header
// OBU it carries, or a VPCodecConfigurationBox (vpcC); the required
// parameter-set structure; the facts needed by the native decoder; and exact
// record exhaustion.
//
// One asymmetry is inherent to vpcC and is not a parser weakness: the box
// carries no coded dimensions at all, so a Vp9/VpcC inspection reports
// width == 0 and height == 0. A vpcC is therefore never a sufficient fact
// source on its own; callers must prove VP9 dimensions from the bitstream with
// inspectVp9BitstreamKeyframe() below and use the vpcC only as a cross-check.
[[nodiscard]] VideoCodecConfigurationInspection inspectVideoCodecConfiguration(
    MediaCodec codec, MediaCodecConfigurationKind kind,
    std::span<const std::byte> configuration,
    VideoCodecConfigurationLimits limits = {}) noexcept;

// VP9 in Matroska/WebM commonly carries no CodecPrivate at all, so the only
// rigorous source of VP9 facts is the uncompressed frame header of a keyframe.
// `keyframe` may be a bounded prefix of the coded frame: the uncompressed
// header of a key frame never exceeds kVp9KeyframeHeaderMaximumBytes, and this
// function reads no further, so it deliberately performs no exhaustion check.
// The reported facts carry MediaCodecConfigurationKind::VpcC because they are
// exactly the facts a synthesized vpcC must reproduce.
inline constexpr std::size_t kVp9KeyframeHeaderMaximumBytes{16};
[[nodiscard]] VideoCodecConfigurationInspection inspectVp9BitstreamKeyframe(
    std::span<const std::byte> keyframe,
    VideoCodecConfigurationLimits limits = {}) noexcept;

// VideoToolbox cannot create a VP9 decompression session without a vpcC atom
// in the format description, so a VP9 source that has no CodecPrivate must
// synthesize one from proven bitstream facts. Writes exactly
// kVideoCodecVpcCBytes bytes and returns false, leaving `configuration`
// untouched, when `facts` are not admitted VP9 facts.
inline constexpr std::size_t kVideoCodecVpcCBytes{12};
[[nodiscard]] bool buildVp9CodecConfiguration(
    const VideoCodecConfigurationFacts &facts,
    std::span<std::byte, kVideoCodecVpcCBytes> configuration) noexcept;

} // namespace wam::media
