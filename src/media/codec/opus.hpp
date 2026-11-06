#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media::codec {

// A Matroska A_OPUS track's CodecPrivate is the OggOpus identification header
// ("OpusHead") verbatim. For channel mapping family 0 -- the only family this
// source admits -- the header is exactly 19 bytes with no channel mapping
// table, so any other size is a different shape of stream and falls back.
inline constexpr std::size_t kOpusIdentificationHeaderBytes{19};

// Opus always decodes to 48 kHz regardless of the encoder's input rate.
inline constexpr std::uint32_t kOpusOutputSampleRate{48'000};

// libopus' fixed decoder delay, 2.5 ms at 48 kHz. AudioToolbox drops exactly
// this many leading frames from every freshly created AudioConverter and
// ignores the OpusHead pre-skip entirely, so the trim the caller still owes is
// preSkip - kOpusDecoderDelayFrames. Proven invariant across forged pre-skip
// values, packet durations, channel counts and encoder applications.
inline constexpr std::uint32_t kOpusDecoderDelayFrames{120};

// RFC 6716 caps one packet at 120 ms, i.e. 5760 frames at 48 kHz.
inline constexpr std::uint32_t kMaximumOpusPacketFrames{5'760};

// The shortest Opus frame is 2.5 ms, so a 120 ms packet holds at most 48.
inline constexpr std::uint8_t kMaximumOpusFramesPerPacket{48};

enum class OpusAdmissionError : std::uint8_t {
  None,
  InvalidHeaderSize,
  UnexpectedMagic,
  UnsupportedVersion,
  UnsupportedChannelCount,
  PreSkipBelowDecoderDelay,
  PreSkipExceedsMaximum,
  NonzeroOutputGain,
  UnsupportedChannelMappingFamily,
};

// The retained bytes are the exact Matroska CodecPrivate payload, which is also
// the AudioConverter decompression magic cookie. Admission is intentionally
// narrower than OggOpus: mapping family 0, mono/stereo, unity output gain.
struct OpusConfiguration {
  std::uint16_t preSkipFrames{0};
  std::uint8_t channelCount{0};
  // Informational only. Opus output is always 48 kHz; this field records what
  // the encoder was fed and never affects the decode or the timeline.
  std::uint32_t inputSampleRate{0};

  friend constexpr bool operator==(const OpusConfiguration &,
                                   const OpusConfiguration &) = default;
};

struct OpusAdmission {
  OpusAdmissionError error{OpusAdmissionError::InvalidHeaderSize};
  std::optional<OpusConfiguration> configuration;

  [[nodiscard]] constexpr bool admitted() const noexcept {
    return error == OpusAdmissionError::None && configuration.has_value();
  }
};

[[nodiscard]] OpusAdmission
parseOpusIdentificationHeader(std::span<const std::byte> bytes) noexcept;

// The exact head trim the pipeline owes after AudioToolbox has already dropped
// its own kOpusDecoderDelayFrames. Empty when the configuration could not have
// come from a real encoder (120 frames is the minimum CELT decoder delay, so a
// smaller pre-skip is rejected at admission rather than guessed at).
[[nodiscard]] constexpr std::optional<std::uint32_t>
opusHeadTrimFrames(const OpusConfiguration &configuration) noexcept {
  if (configuration.preSkipFrames < kOpusDecoderDelayFrames) {
    return std::nullopt;
  }
  return static_cast<std::uint32_t>(configuration.preSkipFrames) -
         kOpusDecoderDelayFrames;
}

// Decoded 48 kHz frame count of one Opus packet, read from its TOC byte
// (RFC 6716 section 3.1). Empty for an empty packet, a zero frame count, a
// truncated code-3 packet, or a packet longer than the 120 ms ceiling.
[[nodiscard]] std::optional<std::uint32_t>
opusPacketFrameCount(std::span<const std::byte> packet) noexcept;

} // namespace wam::media::codec
