#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>

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

  // Not a limit on size -- an admission policy. It lives on this struct
  // because `limits` is already threaded to every parser that asks the colour
  // question, so a second parallel parameter would be one more thing to
  // forget at one of the six sites that ask it.
  //
  // OFF by default, and the default is the load-bearing part. A route may
  // turn this on ONLY if it also carries the colour description onto the
  // CMVideoFormatDescription it synthesizes. Matroska does, since
  // matroska_sample_builder.mm gained its `colr`. MPEG-TS does NOT: its
  // sample builder writes no colour extension either, so admitting HDR there
  // would hand VideoToolbox a PQ stream with nothing to attach to the surface
  // and produce the washed-out SDR render that reads as "HDR support" and is
  // strictly worse than a named refusal.
  bool admitHighDynamicRangeColor{false};
};

// The single dimension question every parser in this file asks, so the six
// bitstream parsers cannot drift from each other or from the media contract.
// Orientation-agnostic since amendment 8: it delegates to the contract's own
// predicate rather than restating a per-axis comparison a seventh time.
//
// Zero is deliberately NOT a size verdict here. Two callers reach this with a
// dimension that can legitimately be zero and answer it as MalformedRecord a
// few lines later; folding zero into DimensionLimitExceeded would relabel
// those refusals. Callers that owe a zero rule state it themselves.
[[nodiscard]] constexpr bool codecDimensionsExceedLimits(
    std::uint64_t width, std::uint64_t height,
    const VideoCodecConfigurationLimits &limits) noexcept {
  if (width == 0U || height == 0U) {
    return false;
  }
  return !MediaSourceLimits::codedDimensionsWithin(
      width, height, limits.maximumWidth, limits.maximumHeight,
      limits.maximumPixels);
}

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

// VP8 in Matroska/WebM never carries a CodecPrivate: the bitstream is fully
// self-describing and RFC 6386 defines no decoder configuration record at all.
// The only rigorous fact source is therefore the key frame header, which is
// plain little-endian bytes rather than a bit string:
//
//   byte 0..2   frame tag: bit 0 frame_type (0 = key frame), bits 1..3
//               version, bit 4 show_frame, bits 5..23 first_part_size
//   byte 3..5   start code 0x9d 0x01 0x2a (key frames only)
//   byte 6..7   little-endian: 14-bit width,  2-bit horizontal scale
//   byte 8..9   little-endian: 14-bit height, 2-bit vertical scale
//
// Ten bytes are therefore both necessary and sufficient, and this function
// reads no further -- the two bool-coded bits that follow (color_space,
// clamping_type) would require the arithmetic decoder and are deliberately not
// consulted. VP8 has exactly one colour space (RFC 6386 section 9.2: BT.601
// primaries and matrix, and the bitstream carries no primaries or transfer
// function of its own), so the reported facts state no colour description at
// all, exactly as VP9's CS_UNKNOWN branch does, and the container's Colour
// element remains the only source that can promote it.
//
// The reported facts carry MediaCodecConfigurationKind::VpcC because a
// VPCodecConfigurationBox describes vp08 as well as vp09, and synthesizing one
// keeps VP8 inside the same non-empty codec-configuration envelope every other
// admitted video codec occupies.
inline constexpr std::size_t kVp8KeyframeHeaderMaximumBytes{10};
[[nodiscard]] VideoCodecConfigurationInspection inspectVp8BitstreamKeyframe(
    std::span<const std::byte> keyframe,
    VideoCodecConfigurationLimits limits = {}) noexcept;

// Writes exactly kVideoCodecVpcCBytes bytes and returns false, leaving
// `configuration` untouched, when `facts` are not admitted VP8 facts. Nothing
// in the native lane parses this record back -- libvpx needs no configuration
// -- but CoreMedia's format description carries it, so it is built from the
// proven facts rather than zero-filled.
[[nodiscard]] bool buildVp8CodecConfiguration(
    const VideoCodecConfigurationFacts &facts,
    std::span<std::byte, kVideoCodecVpcCBytes> configuration) noexcept;

// ---------------------------------------------------------------------------
// MPEG-4 Part 2 (ISO/IEC 14496-2, "MPEG-4 Visual", CoreMedia 'mp4v')
// ---------------------------------------------------------------------------
//
// Matroska carries this codec's configuration as the raw start-code-delimited
// header sequence in CodecPrivate:
//
//   00 00 01 B0  VisualObjectSequence  (profile_and_level_indication follows)
//   00 00 01 B5  VisualObject          (verid, and the only colour description
//                                        this codec has)
//   00 00 01 0x  VideoObject
//   00 00 01 2x  VideoObjectLayer      (the coded dimensions live here)
//   00 00 01 B2  user_data             (optional, e.g. the encoder name)
//
// ONLY SIMPLE PROFILE IS ADMITTED. Measured on this platform 2026-08-20
// (scratchpad/vt_asp_probe2.mm): Apple's VideoToolbox 'mp4v' decoder refuses
// Advanced Simple Profile outright -- VTDecompressionSessionCreate returns
// codecBadDataErr (-8969) before a single access unit is submitted, and
// AVFoundation reproduces the identical failure on a plain mp4v MP4, so this
// is the platform decoder's own limit and not a carriage defect. The refusal
// was localized to exactly two VideoObjectLayer bit-fields: flipping
// video_object_type_indication from 17 (Advanced Simple) to 1 (Simple) and
// video_object_layer_verid from 5 to 1, changing nothing else, turns the same
// bytes into a session that decodes. That is why this parser gates on those
// two fields rather than on profile_and_level_indication -- patching the
// profile byte alone leaves the decoder refusing.
//
// The gate is a CORRECTNESS requirement, not a nicety. A stream whose headers
// claim Simple Profile while its VOPs use Advanced Simple tools decodes
// without error and drifts: measured Y-plane mean absolute difference against
// a reference decode grew 1.76 -> 4.70 over seven frames for quarter-pel
// content, and an Advanced Simple stream with B-VOPs lost 7 of 12 frames and
// produced a broken presentation ladder. Everything this parser admits is a
// stream VideoToolbox decodes bit-accurately.
//
// Two consequences follow from Simple Profile and are relied on downstream:
// B-VOPs are forbidden, so decode order equals presentation order and the
// reported reorder depth is 0; and the profile is 8-bit 4:2:0 only.
//
// Note that the Matroska CodecID is NOT a usable profile signal. ffmpeg writes
// V_MPEG4/ISO/ASP for every MPEG-4 Part 2 track it muxes, Simple Profile
// included (measured across the whole fixture set), so the headers are the
// only honest source and both V_MPEG4/ISO/ASP and V_MPEG4/ISO/SP must be
// profile-gated on content.
[[nodiscard]] VideoCodecConfigurationInspection inspectMpeg4VisualHeaders(
    std::span<const std::byte> headers,
    VideoCodecConfigurationLimits limits = {}) noexcept;

// CoreMedia will not build an 'mp4v' format description from the raw headers:
// they must arrive as the ISO/IEC 14496-1 ES_Descriptor an MP4 'esds' box
// carries, with the headers as its DecoderSpecificInfo. Measured: the raw
// headers as an in-band prefix, and an ES_Descriptor without the box's four
// version/flags bytes, both fail VTDecompressionSessionCreate with
// kVTVideoDecoderBadDataErr (-12909); the shape below succeeds.
//
// The demuxer therefore stores what CoreMedia needs, exactly as VP8 and VP9
// store a synthesized vpcC rather than the record their containers omit. The
// descriptor lengths are always written in the four-byte expandable form, so
// the overhead is a constant:
//
//   4  esds version+flags
//   5  ES_DescrTag + length            3  ES_ID(2) + flags(1)
//   5  DecoderConfigDescrTag + length  13 objectTypeIndication(0x20),
//                                         streamType(0x11), bufferSizeDB(3),
//                                         maxBitrate(4), avgBitrate(4)
//   5  DecSpecificInfoTag + length     n  the headers, byte for byte
//   6  SLConfigDescrTag + length + predefined(0x02)
inline constexpr std::size_t kMpeg4VisualEsdsOverheadBytes{41};

// Writes kMpeg4VisualEsdsOverheadBytes + headers.size() bytes into `esds` and
// reports the count through `written`. Returns false, leaving `esds`
// untouched, when the span is too small, when `written` is null, or when the
// headers are not admitted by inspectMpeg4VisualHeaders(): an esds is never
// built around bytes this player would refuse to decode.
[[nodiscard]] bool buildMpeg4VisualEsds(std::span<const std::byte> headers,
                                        std::span<std::byte> esds,
                                        std::size_t *written,
                                        VideoCodecConfigurationLimits limits =
                                            {}) noexcept;

// ---------------------------------------------------------------------------
// Named refusal for content outside the v1 coded-dimension envelope
// ---------------------------------------------------------------------------
//
// Every backend drops an over-ceiling video track the same silent way: the
// admission predicate returns false, the track never reaches the descriptor,
// and the file surfaces as "did not select every required track" or, worse,
// as an empty error field. That refusal cost two rebuild-and-rerun cycles to
// identify once already (scratchpad/wild_webm_report.md section 5), because
// nothing in the verdict named the dimension, the cap, or even the subject.
//
// This is the one place the refusal text is built, so every backend says the
// same sentence and the cap in it is always the live constant:
//
//   coded dimensions 7680x4320 (33,177,600 px) exceed the native v1 ceiling of
//   4096x2320 (9,502,720 px)
//
// Callers append their own typed token -- the Matroska path gets
// " (CodedDimensionLimit)" from matroskaDemuxErrorMessage, and the backends
// with no such wrapper append the same token literally -- so a grep for
// CodedDimensionLimit finds every backend's refusal.
[[nodiscard]] bool codedDimensionsWithinV1Ceiling(
    std::uint64_t width, std::uint64_t height) noexcept;
[[nodiscard]] std::string codedDimensionRefusalMessage(
    std::uint64_t width, std::uint64_t height) noexcept;

} // namespace wam::media
