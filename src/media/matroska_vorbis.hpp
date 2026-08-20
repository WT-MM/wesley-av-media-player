#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media::matroska {

// A Matroska A_VORBIS track's CodecPrivate is the three Xiph setup packets --
// identification, comment, setup -- packed with a leading packet count and
// Xiph-style lacing lengths. Unlike Opus, this blob is NOT a bare header: it is
// a container of its own that has to be split before anything can be read.
//
// It is also, verbatim and unmodified, the decompression magic cookie
// AudioToolbox' Vorbis decoder ('vorb') wants. That was measured, not assumed:
// the raw CodecPrivate is accepted with noErr while the three plausible
// repackings (bare concatenation, 32-bit big-endian and little-endian length
// prefixes) are all rejected with kAudioCodecUnsupportedFormatError. The
// decoder parses what it is given, and only this shape satisfies it. See
// scratchpad/vorb_probe.mm.
inline constexpr std::size_t kVorbisHeaderCount{3};

// 'vorb'. AudioToolbox registers a Vorbis decoder under this fourcc --
// kAudioFormatProperty_DecodeFormatIDs reports it -- but publishes no
// kAudioFormatVorbis constant for it, so the value is stated here once and
// shared by the demuxer, the converter and the session rather than spelled
// three times.
inline constexpr std::uint32_t kVorbisAudioFormatTag{0x766F7262U};

// Vorbis I specification 4.2.2. Fixed size: 1 type byte, 6 magic bytes, a
// 4-byte version, channels, rate, three bitrate fields, the packed block
// sizes, and the framing bit.
inline constexpr std::size_t kVorbisIdentificationHeaderBytes{30};

// Vorbis I allows block sizes of 64..8192 frames, each a power of two.
inline constexpr std::uint32_t kMinimumVorbisBlockSize{64};
inline constexpr std::uint32_t kMaximumVorbisBlockSize{8'192};

// The largest number of frames one packet can decode to, which is the largest
// block size halved. Bounds the DiscardPadding recovery below.
inline constexpr std::uint32_t kMaximumVorbisPacketFrames{
    kMaximumVorbisBlockSize / 2U};

enum class VorbisAdmissionError : std::uint8_t {
  None,
  InvalidCodecPrivateSize,
  UnexpectedPacketCount,
  MalformedLacing,
  TruncatedHeader,
  InvalidIdentificationHeaderSize,
  UnexpectedMagic,
  UnsupportedVersion,
  UnsupportedChannelCount,
  UnsupportedSampleRate,
  InvalidBlockSize,
  // The one admission this source makes that the format itself does not
  // require. See kUniformBlockSizeRationale in the .cpp.
  VariableBlockSize,
  MissingFramingBit,
};

struct VorbisConfiguration {
  std::uint8_t channelCount{0};
  std::uint32_t sampleRate{0};
  // Both block sizes, equal by admission. Retained separately so a future
  // variable-duration implementation can relax the gate without changing the
  // shape of this struct.
  std::uint32_t blockSize0{0};
  std::uint32_t blockSize1{0};

  // With equal block sizes every packet decodes to exactly blockSize/2 frames,
  // which is what makes the constant-frames-per-access-unit timeline the rest
  // of this demuxer is built on legitimate for Vorbis.
  [[nodiscard]] constexpr std::uint32_t samplesPerAccessUnit() const noexcept {
    return blockSize1 / 2U;
  }

  friend constexpr bool operator==(const VorbisConfiguration &,
                                   const VorbisConfiguration &) = default;
};

struct VorbisAdmission {
  VorbisAdmissionError error{VorbisAdmissionError::InvalidCodecPrivateSize};
  std::optional<VorbisConfiguration> configuration;

  [[nodiscard]] constexpr bool admitted() const noexcept {
    return error == VorbisAdmissionError::None && configuration.has_value();
  }
};

// Splits the Xiph-laced CodecPrivate and admits the identification header.
// The comment and setup headers are checked for their type byte and magic only
// -- their contents are the decoder's business, not the demuxer's -- but they
// must be present and the lacing must account for every byte, so a truncated
// or over-long blob is refused rather than handed to AudioToolbox.
[[nodiscard]] VorbisAdmission
parseVorbisCodecPrivate(std::span<const std::byte> bytes) noexcept;

// The number of frames the decoder swallows before it emits anything: Vorbis'
// first packet carries only the left half of an overlap-add window, so it
// decodes to zero samples by specification and the stream comes out exactly one
// access unit short. Measured invariant across fresh converters AND across
// AudioConverterReset -- unlike Opus, whose lead-in reset had to be worked
// around by rebuilding the converter. See scratchpad/vorbreset_probe.mm.
[[nodiscard]] constexpr std::uint32_t
vorbisDecoderLeadInFrames(const VorbisConfiguration &configuration) noexcept {
  return configuration.samplesPerAccessUnit();
}

// Recovers an exact frame count from a Matroska duration stated in nanoseconds
// (DiscardPadding). Identical in intent to opusFramesFromNanoseconds, but the
// sample rate is a parameter because Vorbis is commonly 44.1 kHz, where
// gcd(44100, 1e9) = 100 makes the set of exactly-representable frame counts
// different again. One nanosecond is a small fraction of a frame at every rate
// this source admits, so the nearest whole frame is unique; the residual is
// bounded at one nanosecond so a value that was never a rounded frame count is
// refused rather than snapped.
[[nodiscard]] std::optional<std::uint32_t>
vorbisFramesFromNanoseconds(std::int64_t nanoseconds,
                            std::uint32_t sampleRate) noexcept;

} // namespace wam::media::matroska
