#pragma once

#include "media/native_media_source.hpp"

#include <cstdint>
#include <optional>

namespace wam::media {

// True for audio codecs whose first access unit legitimately presents BEFORE
// media time zero.
//
// Matroska stores an audio Block's timestamp on the codec grid and states the
// encoder's lead-in separately as CodecDelay, which a reader must subtract to
// obtain the presentation time. Opus always has such a lead-in -- the OpusHead
// pre-skip -- so access unit 0 of every real Opus mux starts pre-skip frames
// early and the generation decodes a bounded preroll it must not publish.
//
// Every other admitted codec starts exactly at zero, and the nonnegative
// guards those codecs are checked against stay in force. This predicate exists
// so the exception is stated once instead of being re-derived at each of the
// layers that has to relax for it.
[[nodiscard]] constexpr bool
audioCodecPrecedesStreamOrigin(MediaCodec codec) noexcept {
  switch (codec) {
  // Vorbis joins Opus for the same structural reason stated differently by the
  // format: its first packet carries only half an overlap-add window and
  // decodes to no samples, so access unit 0 presents one block before media
  // zero. Where Opus states the offset as a CodecDelay/pre-skip field, Vorbis
  // implies it, but it lands in exactly the same arithmetic.
  case MediaCodec::Opus:
  case MediaCodec::Vorbis:
  // AC-3 and E-AC-3 state a 256-frame CodecDelay -- the decoder delay Apple's
  // decoder also swallows -- so access unit 0 presents 256 frames early.
  case MediaCodec::Ac3:
  case MediaCodec::Eac3:
  // MP3 states the LAME encoder delay plus the 529-frame decoder delay
  // (1105 frames from every ffmpeg mux).
  case MediaCodec::Mp3:
  // AAC states one 1024-frame access unit of encoder priming whenever the mux
  // encoded rather than copied the track. Honouring it exactly is what
  // replaced the historic whole-file fallback for CodecDelay-bearing AAC.
  case MediaCodec::Aac:
    return true;
  default:
    // FLAC states no CodecDelay and its decoder swallows nothing, so its
    // access unit 0 is media frame 0 exactly. It deliberately does NOT join
    // this predicate even though it does state an exact duration below.
    return false;
  }
}

// True for codecs whose Matroska descriptor states the audio track's duration
// as the EXACT decoded sample count after every trim, rather than as the
// container's declared Duration. Only such a track may be used as the
// publication ceiling: an approximate ceiling either truncates audible samples
// or lets the clock free-run past the end of the stream.
//
// This is deliberately a SEPARATE predicate from
// audioCodecPrecedesStreamOrigin, which the two roles shared until this sweep.
// They are genuinely different questions and the codec sets differ at both
// ends: FLAC states an exact duration (STREAMINFO carries the total sample
// count) but starts at origin, while AAC precedes the origin but reaches this
// pipeline from AVFoundation as well as from Matroska -- and an AVFoundation
// track's duration is the container's estimate, not a decoded sample count.
[[nodiscard]] constexpr bool
audioCodecStatesExactDecodedDuration(MediaCodec codec) noexcept {
  switch (codec) {
  case MediaCodec::Opus:
  case MediaCodec::Vorbis:
  case MediaCodec::Ac3:
  case MediaCodec::Eac3:
  case MediaCodec::Mp3:
  case MediaCodec::Flac:
  // ALAC for FLAC's reason: an MP4's track duration IS the decoded sample
  // count (the sample table states the final packet's true length), so the
  // ceiling can be taken exactly. This pairs with ALAC's tail-shortfall bound
  // in native_audio_converter.mm the way FLAC's does -- the bound tolerates a
  // budget overstated by the packet-duration restatement, and the ceiling
  // keeps that tolerance from becoming a licence to publish past the stream.
  case MediaCodec::Alac:
  // Uncompressed audio states its length as a frame count in its own header --
  // a WAVE data chunk's byte count over its block align, an AIFF SSND frame
  // count -- so the container's duration IS the decoded sample count, exactly.
  // Nothing decodes it, so there is no shortfall for it to be approximate by.
  // The caller still requires the stated duration to land on a whole frame
  // before it takes the ceiling, so a container that states something else is
  // simply left with today's behaviour.
  case MediaCodec::Pcm:
  // ADPCM in WAV joins for the same reason, and it is a MEASURED claim rather
  // than a structural one: the format is blocked, so the container's frame
  // count is not simply bytes over block align, and the last block is padded.
  // Measured 2026-09-04 on IMA and MS chirp fixtures, mono and stereo: the
  // frames AudioToolbox produces equal the declared frame count exactly
  // (delta 0), with no lead-in to subtract and no tail to withhold.
  case MediaCodec::AdpcmIma:
  case MediaCodec::AdpcmMs:
    return true;
  default:
    return false;
  }
}

// Recovers an exact frame count from a Matroska duration stated in
// nanoseconds (CodecDelay, DiscardPadding).
//
// Nanoseconds cannot express an arbitrary frame count: gcd(48000, 1e9) = 16000
// and gcd(44100, 1e9) = 100, so at every rate only some frame counts land on an
// integer nanosecond. Demanding an exact multiple would reject most real files
// -- measured, not theorised, in the Opus work. One nanosecond is a small
// fraction of a frame at every admitted rate, so the nearest whole frame count
// is unique and recovers the muxer's own integer exactly. The residual is
// bounded at one nanosecond so a value that was never a rounded frame count is
// refused rather than silently snapped.
//
// Returns empty for a negative value (that asks for padding to be ADDED, which
// this pipeline cannot manufacture), a zero sample rate, a residual over one
// nanosecond, or a result beyond maximumFrames.
//
// This is the rate-generic form of the identical arithmetic in
// opusFramesFromNanoseconds and vorbisFramesFromNanoseconds. Those two are left
// exactly as they are: their bounds are codec-specific and their proofs are
// already landed, so this shared copy serves the codecs added by this sweep
// rather than re-deriving theirs.
[[nodiscard]] constexpr std::optional<std::uint32_t>
matroskaFramesFromNanoseconds(std::int64_t nanoseconds,
                              std::uint32_t sampleRate,
                              std::uint32_t maximumFrames) noexcept {
  if (nanoseconds < 0 || sampleRate == 0U) {
    return std::nullopt;
  }
  const auto magnitude = static_cast<std::uint64_t>(nanoseconds);
  // Bound the magnitude BEFORE forming the product so a hostile value can never
  // wrap the multiplication. One frame past the ceiling, so the frame-count
  // check below -- not this overflow guard -- is what states the ceiling.
  const std::uint64_t maximumNanoseconds =
      UINT64_C(1'000'000'000) * (static_cast<std::uint64_t>(maximumFrames) + 1U) /
      static_cast<std::uint64_t>(sampleRate);
  if (magnitude > maximumNanoseconds) {
    return std::nullopt;
  }
  const std::uint64_t product =
      magnitude * static_cast<std::uint64_t>(sampleRate);
  const std::uint64_t frames =
      (product + UINT64_C(500'000'000)) / UINT64_C(1'000'000'000);
  const std::uint64_t exact = frames * UINT64_C(1'000'000'000);
  const std::uint64_t residual =
      product > exact ? product - exact : exact - product;
  // One nanosecond, expressed in the product's own units.
  if (residual > static_cast<std::uint64_t>(sampleRate)) {
    return std::nullopt;
  }
  if (frames > maximumFrames) {
    return std::nullopt;
  }
  return static_cast<std::uint32_t>(frames);
}

} // namespace wam::media
