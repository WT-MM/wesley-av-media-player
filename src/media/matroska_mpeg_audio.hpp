#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media::matroska {

// A Matroska A_MPEG/L3 track carries no CodecPrivate: every parameter is
// restated in each 4-byte frame header, and AudioToolbox's '.mp3' decoder takes
// the raw frame with no magic cookie (measured -- AudioConverterNew succeeds
// and decodes with the cookie property never set).
inline constexpr std::size_t kMpegAudioFrameHeaderBytes{4};

// MPEG-1 Layer III decodes 1152 frames per access unit. MPEG-2 and MPEG-2.5
// Layer III decode 576, which the grid could represent, but the decoder
// lead-in below was measured on MPEG-1 only and an unexercised branch is worse
// than a clean fallback -- so the low-sample-rate extensions are refused.
inline constexpr std::uint32_t kMpegLayer3SamplesPerAccessUnit{1'152};

// AudioToolbox's MP3 decoder swallows exactly this many leading frames and
// then flushes the same number at the end, so a stream decodes to exactly
// packets * 1152 frames while its CONTENT is shifted 529 frames earlier than
// the raw packet grid suggests.
//
// 529 is the canonical MP3 decoder delay (the polyphase synthesis and MDCT
// windows). Measured as a signed offset of -529 against ffmpeg's decode of the
// raw elementary stream, invariant at 44.1 kHz and 48 kHz, mono and stereo,
// and across AudioConverterReset. See scratchpad/sweep_probe.mm, cmpf32.py.
//
// ffmpeg states CodecDelay = 1105 frames on every MP3 it muxes, which is the
// 576-frame LAME encoder delay PLUS this 529. So the head trim the caller
// still owes is CodecDelay - kMpegLayer3DecoderDelayFrames = 576, and that
// number was confirmed directly: at offset +576 our decode matches ffmpeg's
// container-trimmed decode. No LAME/Xing parsing is needed -- the container
// states the encoder half and the decoder half is this constant.
inline constexpr std::uint32_t kMpegLayer3DecoderDelayFrames{529};

enum class MpegAudioAdmissionError : std::uint8_t {
  None,
  TruncatedFrameHeader,
  UnexpectedSyncword,
  // Anything that is not MPEG-1 Layer III.
  UnsupportedVersion,
  UnsupportedLayer,
  UnsupportedBitRateIndex,
  ReservedSampleRate,
  // The Block does not hold exactly one whole frame.
  FrameSizeMismatch,
};

struct MpegAudioConfiguration {
  std::uint32_t sampleRate{0};
  std::uint8_t channelCount{0};
  std::uint32_t samplesPerAccessUnit{0};
  std::uint32_t frameBytes{0};

  friend constexpr bool operator==(const MpegAudioConfiguration &,
                                   const MpegAudioConfiguration &) = default;
};

struct MpegAudioAdmission {
  MpegAudioAdmissionError error{
      MpegAudioAdmissionError::TruncatedFrameHeader};
  std::optional<MpegAudioConfiguration> configuration;

  [[nodiscard]] constexpr bool admitted() const noexcept {
    return error == MpegAudioAdmissionError::None && configuration.has_value();
  }
};

// Reads one MPEG-1 Layer III frame header. Admission is intentionally narrower
// than the format: MPEG-1 Layer III only, a stated (non-free, non-reserved)
// bit rate, and one whole frame per Block.
[[nodiscard]] MpegAudioAdmission
parseMpegAudioFrameHeader(std::span<const std::byte> frame) noexcept;

// Whether a later Block's frame header describes the SAME stream as the one
// admission was read from. Called for every emitted packet, exactly as the
// Opus TOC check is: a mux that changes sample rate or channel mode mid-stream
// would silently desync the ordinal grid the timestamps are rebuilt from.
//
// The frame LENGTH is compared against the Block, not against the admitted
// length: a Layer III stream alternates frame lengths by one byte through the
// padding bit at every rate that is not a whole number of bytes per frame, and
// a variable-bit-rate stream changes length outright. Neither changes the
// access unit's 1152-frame duration, which is what the grid depends on.
[[nodiscard]] bool
mpegAudioFrameMatches(std::span<const std::byte> header,
                      std::uint64_t frameBytes,
                      const MpegAudioConfiguration &configuration) noexcept;

} // namespace wam::media::matroska
