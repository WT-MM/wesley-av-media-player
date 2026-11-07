#pragma once

#include "media/codec/aac.hpp"
#include "media/media_codec_facts.hpp"
#include "media/native_media_source.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <limits>

namespace wam::media {

// Exact integer sample rate, or empty when the rate cannot sit on an integer
// PCM grid whose timescale is a MediaTime's int32. The one bound for every
// route.
[[nodiscard]] inline std::optional<std::uint32_t>
exactAudioSampleRate(double rate) noexcept {
  if (!std::isfinite(rate) || rate <= 0.0 ||
      rate > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  const auto integral = static_cast<std::uint32_t>(rate);
  if (static_cast<double>(integral) != rate || integral == 0) {
    return std::nullopt;
  }
  return integral;
}

// Decoder preroll a source guarantees ahead of the first audible frame of an
// accurate-seek generation. Every route and codec asks this one function.
//
// AAC-LC carries no inter-frame dependency beyond the MDCT overlap-add window:
// each 1024-frame access unit is reconstructed from its own spectral data plus
// the second half of the previous unit's window, so one decoded predecessor
// already makes a unit exact. Two units is the conventional decoder preroll
// and the floor used here, which also covers the same overlap structure at the
// 2048-frame HE-AAC grid and the block-switch history of MP3. A codec whose
// facts row states a longer seekPrerollFrames (Opus) gets that instead.
inline constexpr std::int64_t kAudioPrimingAccessUnits{2};
// Guards the priming arithmetic against a pathological packet grid.
inline constexpr std::int64_t kMaximumAudioFramesPerPacket{65'536};

[[nodiscard]] constexpr std::int64_t
audioPrimingFrames(MediaCodec codec, std::int64_t framesPerPacket) noexcept {
  return std::max<std::int64_t>(kAudioPrimingAccessUnits * framesPerPacket,
                                mediaCodecFacts(codec).seekPrerollFrames);
}

// The latest first-access-unit frame that still leaves the full priming ahead
// of presentationFrame, clamped at zero.
[[nodiscard]] constexpr std::int64_t
audioPrimingCeilingFrame(std::int64_t presentationFrame, MediaCodec codec,
                         std::int64_t framesPerPacket) noexcept {
  return std::max<std::int64_t>(
      presentationFrame - audioPrimingFrames(codec, framesPerPacket), 0);
}

// Bounds an open-time walk over a file's packets.
inline constexpr std::uint64_t kMaximumAudioIndexScanPackets{2'000'000};

// Whole AAC packets an accurate seek backs off ahead of the target's packet.
// An elapsed-time backoff alone can land inside declared silence with no
// decoder warm-up at all.
inline constexpr std::size_t kAacSeekBackoffPackets{4};

// AAC-LC packet timestamps may jitter within a quarter access unit. The
// 256-frame bound covers measured residuals through 152 frames and moves audio
// by at most 5.81 ms at 44.1 kHz (5.33 ms at 48 kHz). Always compare against
// the segment ORIGINAL origin plus packet ORDINAL, never the preceding PTS.
// AacPacketTimeline separately proves explicit edit boundaries and their exact
// trim/silence extents; ordinary jitter cannot re-anchor cumulative drift.
inline constexpr std::int64_t kAacPacketGridResidualFrames = 256;
[[nodiscard]] constexpr std::optional<MediaTime> projectAacPacketGrid(
    MediaTime observed, std::int64_t originFrame, std::uint64_t ordinal,
    std::uint32_t rate) noexcept {
  if (!observed.valid() || !rate || rate > INT32_MAX) return std::nullopt;
  const __int128 expected = __int128(originFrame) +
                            __int128(ordinal) * codec::kAacLcSamplesPerAccessUnit;
  if (expected < INT64_MIN || expected > INT64_MAX) return std::nullopt;
  const __int128 residual = __int128(observed.value) * rate -
                            expected * observed.timescale;
  const __int128 bound = __int128(kAacPacketGridResidualFrames) * observed.timescale;
  if (residual < -bound || residual > bound) return std::nullopt;
  return MediaTime{static_cast<std::int64_t>(expected), static_cast<std::int32_t>(rate)};
}

// True for audio codecs whose first access unit legitimately presents BEFORE
// media time zero.
//
// Matroska stores an audio Block's timestamp on the codec grid and states the
// encoder's lead-in separately as CodecDelay, which a reader must subtract to
// obtain the presentation time. Opus always has such a lead-in -- the OpusHead
// pre-skip -- so access unit 0 of every real Opus mux starts pre-skip frames
// early and the generation decodes a bounded preroll it must not publish.
//
// The codecs whose facts row sets precedesStreamOrigin share that shape (each
// row says why); every other codec starts exactly at zero, and the
// nonnegative guards it is checked against stay in force. This predicate exists
// so the exception is stated once instead of being re-derived at each of the
// layers that has to relax for it.
[[nodiscard]] constexpr bool
audioCodecPrecedesStreamOrigin(MediaCodec codec) noexcept {
  return mediaCodecFacts(codec).precedesStreamOrigin;
}

// Recovers an exact frame count from a Matroska duration stated in
// nanoseconds (CodecDelay, DiscardPadding).
//
// Nanoseconds cannot express an arbitrary frame count: gcd(48000, 1e9) = 16000
// and gcd(44100, 1e9) = 100, so at every rate only some frame counts land on an
// integer nanosecond. Demanding an exact multiple would reject most real files
// -- measured, not theorised. One nanosecond is a small
// fraction of a frame at every admitted rate, so the nearest whole frame count
// is unique and recovers the muxer's own integer exactly. The residual is
// bounded at one nanosecond so a value that was never a rounded frame count is
// refused rather than silently snapped.
//
// Returns empty for a negative value (that asks for padding to be ADDED, which
// this pipeline cannot manufacture), a zero sample rate, a residual over one
// nanosecond, or a result beyond maximumFrames.
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
