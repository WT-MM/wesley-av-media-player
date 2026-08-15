#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>

namespace wam::macos::native_video_limits {

// One compressed H.264/HEVC access unit. AVFoundation-backed submissions keep
// the original CMSampleBuffer storage and do not create an application payload
// copy, but every retained unit is still charged against this logical bound.
inline constexpr std::size_t kMaximumCompressedVideoAccessUnitBytes =
    8ULL * 1024ULL * 1024ULL;

// The native lane retains one selected avcC or hvcC atom. This is therefore
// both the per-codec limit and the aggregate codec-configuration limit for one
// active native video attempt.
inline constexpr std::size_t kMaximumVideoCodecConfigurationBytes =
    256ULL * 1024ULL;

// Conservatively charge three logical representations while CoreMedia builds
// its format description: the pipeline vector, temporary CFData, and the
// format description's retained representation. The pipeline vector is
// destroyed and the decoder's temporary owning CFData reference is released
// as soon as configure() returns; one format-description representation stays.
inline constexpr std::size_t kMaximumTransientVideoCodecConfigurationBytes =
    3 * kMaximumVideoCodecConfigurationBytes;
inline constexpr std::size_t kMaximumRetainedVideoCodecConfigurationBytes =
    kMaximumVideoCodecConfigurationBytes;
// Direct samples must carry a bounded, byte-identical atom. The decoder reuses
// its configured session and does not cache their format description as a
// second logically distinct configuration.

// The integrated pipeline admits two VideoToolbox submissions and may hold one
// AVAssetReader sample while waiting for decoder capacity. This is a logical
// retained-source envelope, not three application payload copies.
inline constexpr std::size_t kMaximumPipelineInFlightAccessUnits = 2;
inline constexpr std::size_t kMaximumPipelineRetainedAccessUnits =
    kMaximumPipelineInFlightAccessUnits + 1;
inline constexpr std::size_t kMaximumPipelineLogicalCompressedVideoBytes =
    kMaximumPipelineRetainedAccessUnits *
    kMaximumCompressedVideoAccessUnitBytes;

[[nodiscard]] constexpr bool
acceptsCompressedVideoAccessUnitSize(std::size_t bytes) noexcept {
  return bytes != 0 && bytes <= kMaximumCompressedVideoAccessUnitBytes;
}

[[nodiscard]] constexpr bool
acceptsVideoCodecConfigurationSize(std::size_t bytes) noexcept {
  return bytes != 0 && bytes <= kMaximumVideoCodecConfigurationBytes;
}

static_assert(kMaximumPipelineLogicalCompressedVideoBytes ==
              24ULL * 1024ULL * 1024ULL);
static_assert(kMaximumTransientVideoCodecConfigurationBytes ==
              768ULL * 1024ULL);

// ---------------------------------------------------------------------------
// Selected A/V duration relation.
//
// The native route's media clock is audio-authoritative: presentation time
// advances only while the audio renderer consumes real samples, and the video
// consumer deliberately manufactures neither synthetic silence nor a fallback
// timer. A video tail that extends past the end of the selected audio can
// therefore never be advanced, which is why native v1 requires the selected
// audio duration to cover the selected video duration.
//
// Real containers do not honour that relation to the tick. The dominant cause
// is codec priming expressed as an edit list: a muxer that trims AAC-LC's
// 2112-sample encoder delay off the head of the audio track subtracts it from
// that track's *edited* duration while leaving the video edit at full length,
// so the audio ends a few tens of milliseconds before the video even though
// both cover the same content. Measured on ordinary ffmpeg-muxed MP4s this is
// 44 ms at 48 kHz and 48 ms at 44.1 kHz, and a track whose final partial AAC
// frame is also trimmed adds one more frame (1024 samples, 21-24 ms). Rounding
// a track duration onto a coarse movie timescale contributes a tick more.
// Rejecting those files sends overwhelmingly ordinary SDR H.264+AAC media to
// compatibility playback for a shortfall shorter than two video frames.
//
// The policy is therefore a bounded shortfall rather than an exact relation:
// admit audio that falls short of video by at most kMaximumSelectedAudio-
// ShortfallMilliseconds, and keep routing a genuinely short audio track (a
// music bed under a long video, a truncated download) to fallback. The bound
// is the largest tail the audio clock may leave unpresented; at the tail of a
// file that is a hold on the final frames at the moment playback ends, which
// is why it is set well under half a second rather than at the exact sum of
// the observed container artefacts.
inline constexpr std::int64_t kMaximumSelectedAudioShortfallMilliseconds = 250;

// Exact rational test for
//     audioDuration + kMaximumSelectedAudioShortfallMilliseconds/1000
//         >= videoDuration
// Both durations must be exact and nonnegative. The comparison never rounds
// through double: adjacent media ticks can exceed 2^53.
[[nodiscard]] constexpr bool acceptsSelectedTrackDurations(
    media::MediaTime audioDuration,
    media::MediaTime videoDuration) noexcept {
  if (!audioDuration.valid() || !videoDuration.valid() ||
      audioDuration.value < 0 || videoDuration.value < 0) {
    return false;
  }
  using Wide = __int128_t;
  constexpr Wide kShortfallTimescale = 1000;
  // |value| < 2^63 and timescale < 2^31, so each product stays below 2^105.
  const Wide audioScaled = static_cast<Wide>(audioDuration.value) *
                           static_cast<Wide>(videoDuration.timescale) *
                           kShortfallTimescale;
  const Wide videoScaled = static_cast<Wide>(videoDuration.value) *
                           static_cast<Wide>(audioDuration.timescale) *
                           kShortfallTimescale;
  const Wide allowance =
      static_cast<Wide>(kMaximumSelectedAudioShortfallMilliseconds) *
      static_cast<Wide>(audioDuration.timescale) *
      static_cast<Wide>(videoDuration.timescale);
  return audioScaled + allowance >= videoScaled;
}

} // namespace wam::macos::native_video_limits
