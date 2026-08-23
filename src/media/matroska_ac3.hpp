#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace wam::media::matroska {

// A Matroska A_AC3 / A_EAC3 track carries NO CodecPrivate: every parameter the
// pipeline needs is restated in each syncframe, and AudioToolbox's 'ac-3' and
// 'ec-3' decoders take the raw syncframe with no magic cookie at all (measured:
// AudioConverterNew succeeds and decodes with the cookie property never set).
// So admission reads the first Block's syncframe instead of a header blob.
inline constexpr std::size_t kAc3MinimumSyncframeBytes{8};

// AC-3 syncword, big-endian.
inline constexpr std::uint16_t kAc3Syncword{0x0B77};

// Both flavours decode 6 blocks of 256 frames. AC-3 has no other option;
// E-AC-3 does (1, 2, 3 or 6 blocks) and this source admits only the 6-block
// form, because a variable block count is a variable access-unit duration and
// the demuxer's affine ordinal grid cannot represent one -- the same reasoning
// that gates Vorbis to equal block sizes.
inline constexpr std::uint32_t kAc3SamplesPerAccessUnit{1'536};
inline constexpr std::uint32_t kAc3BlocksPerSyncframe{6};
inline constexpr std::uint32_t kAc3FramesPerBlock{256};

// AudioToolbox drops exactly this many leading frames from an AC-3 or E-AC-3
// stream -- the decoder delay, which is also precisely the CodecDelay every
// ffmpeg mux states (5,333,333 ns = 256 frames at 48 kHz). So the head trim the
// caller still owes is CodecDelay - kAc3DecoderDelayFrames, and for every real
// file that is zero.
//
// Measured against ffmpeg's decode of the RAW elementary stream with a chirp
// (a periodic test tone makes the alignment search degenerate and produced a
// wrong answer first time round): the signed offset is -256 on every arm.
// Invariant across durations 2 s / 3.7 s / 5 s / 6 s, mono / stereo / 5.1, and
// across AudioConverterReset. See scratchpad/sweep_probe.mm, cmpf32.py.
inline constexpr std::uint32_t kAc3DecoderDelayFrames{256};

// ...and it stops this many frames SHORT of the end of the stream, holding
// them in flight and never flushing them. Explicit post-drain
// AudioConverterFillComplexBuffer calls return zero frames
// (scratchpad/ac3tail.mm), so the frames are unreachable rather than merely
// unrequested.
//
// This is why an AC-3 track's stated duration is 32 frames (0.667 ms) shorter
// than ffmpeg's own decode of the same track. Stating ffmpeg's number instead
// would leave the clock waiting for 32 frames that never arrive, which is the
// end-of-file free-run the Opus work removed. The withheld frames are the
// encoder's silent MDCT ring-down: ffmpeg's last 40 raw frames peak at
// -113 dBFS where the preceding audio sits at -9 dBFS.
inline constexpr std::uint32_t kAc3DecoderTailShortfallFrames{32};

// Bit stream identification ranges. <= 8 is AC-3 (A/52 Annex D allows the
// older values); 11..16 is E-AC-3 (Annex E). 9 and 10 are the unused
// "alternate bit stream syntax" and are refused.
inline constexpr std::uint8_t kMaximumLegacyAc3BitStreamIdentification{8};
inline constexpr std::uint8_t kMinimumEnhancedAc3BitStreamIdentification{11};
inline constexpr std::uint8_t kMaximumEnhancedAc3BitStreamIdentification{16};

enum class Ac3AdmissionError : std::uint8_t {
  None,
  TruncatedSyncframe,
  UnexpectedSyncword,
  UnsupportedBitStreamIdentification,
  // fscod == 3 -- reserved in AC-3, and the half-sample-rate signal in E-AC-3.
  ReservedSampleRate,
  UnsupportedBitRateCode,
  // acmod 0, the "1+1" dual-mono mode: two independent programmes rather than
  // a speaker arrangement, so it has no defined stereo fold. Every other
  // acmod is admitted, with or without its LFE channel.
  UnsupportedChannelConfiguration,
  // E-AC-3 with 1, 2 or 3 blocks per syncframe.
  UnsupportedBlockCount,
  // E-AC-3 dependent substreams, which carry the channels beyond the
  // independent stream's own program.
  UnsupportedSubstream,
  // The Block does not hold exactly one whole syncframe.
  FrameSizeMismatch,
  CodecIdMismatch,
};

struct Ac3Configuration {
  std::uint32_t sampleRate{0};
  std::uint8_t channelCount{0};
  // Always kAc3SamplesPerAccessUnit by admission; carried explicitly so the
  // demuxer never has to remember which constant applies.
  std::uint32_t samplesPerAccessUnit{0};
  // Byte length of the syncframe the admission was read from. The Block must
  // be exactly this long: an over-long Block is carrying a second syncframe
  // (an E-AC-3 dependent substream, or two laced AC-3 frames the lacing did
  // not declare), which would decode to more audio than the grid allows.
  std::uint32_t syncframeBytes{0};
  bool enhanced{false};

  friend constexpr bool operator==(const Ac3Configuration &,
                                   const Ac3Configuration &) = default;
};

struct Ac3Admission {
  Ac3AdmissionError error{Ac3AdmissionError::TruncatedSyncframe};
  std::optional<Ac3Configuration> configuration;

  [[nodiscard]] constexpr bool admitted() const noexcept {
    return error == Ac3AdmissionError::None && configuration.has_value();
  }
};

// Reads one AC-3 or E-AC-3 syncframe header. `enhanced` states which CodecID
// the track declared, and admission requires the bitstream to agree: a track
// labelled A_AC3 whose frames are E-AC-3 (or the reverse) is a mislabelled mux
// and falls back rather than being decoded as whichever the bytes happen to be.
//
// Admission is intentionally narrower than the format: mono or stereo with no
// LFE, 6 blocks per syncframe, and one whole syncframe per Block.
[[nodiscard]] Ac3Admission
parseAc3Syncframe(std::span<const std::byte> frame, bool enhanced) noexcept;

// Whether a later Block's syncframe describes the SAME stream as the one
// admission was read from. Called for every emitted packet, exactly as the
// Opus TOC check is: a mux that changes sample rate or channel mode mid-stream
// would silently desync the ordinal grid the timestamps are rebuilt from.
//
// Only the header is read -- `frameBytes` states how long the Block's frame
// actually is, so the caller does not have to fetch a whole syncframe per
// packet to check that it holds exactly one.
[[nodiscard]] bool ac3SyncframeMatches(std::span<const std::byte> header,
                                       std::uint64_t frameBytes,
                                       const Ac3Configuration &configuration,
                                       bool enhanced) noexcept;

} // namespace wam::media::matroska
