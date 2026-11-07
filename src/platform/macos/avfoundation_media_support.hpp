#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/core_media_source_support.hpp"

#import <AVFoundation/AVFoundation.h>
#include <CoreMedia/CoreMedia.h>

#include <atomic>
#include <cstddef>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace wam::macos {

// AVFoundation knowledge shared by the main source (avfoundation_media_source)
// and the scrub preview (avfoundation_preview_source). Both lanes read the same
// asset through AVAssetReader and must answer these questions identically.

inline constexpr std::size_t kMaximumSyncCursorSteps{100'000};

[[nodiscard]] std::string describeNSError(NSError* error, const char* fallback);

[[nodiscard]] media::MediaTrackId stableTrackId(
    AVAssetTrack* track, media::MediaTrackId fallback) noexcept;

// The container's sync attachment; false when the attachments are malformed.
[[nodiscard]] bool sampleIsKeyFrame(CMSampleBufferRef sample,
                                    bool* keyFrame) noexcept;

// The exact reader range [decodeStart, duration), or empty when any bound is
// inexact or out of order.
[[nodiscard]] std::optional<CMTimeRange> exactReaderTimeRangeFacts(
    CMTime duration, CMTime decodeStart) noexcept;

// ---- edit lists -----------------------------------------------------------

[[nodiscard]] bool exactEditTime(CMTime time) noexcept;

// The one edit-list shape native playback admits: at most one EMPTY edit, at
// the head, followed by exactly one rate-1.0 media edit whose four times are
// exact and whose movie start is nonnegative. Returns that media edit's
// mapping; anything else (a mid-stream silence hole, a second media edit, a
// stretched edit) is not a constant shift and is refused.
[[nodiscard]] std::optional<CMTimeMapping> singleMediaEditMapping(
    NSArray* segments) noexcept;

// The exact movie-timeline restatement facts of a selected track.
//
// AVFoundation states every access unit on the track's own MEDIA timeline,
// while the container's edit list says where that media belongs on the MOVIE
// timeline -- which is the timeline the video lane already presents on
// (VideoToolbox propagates each sample's OutputPresentationTimeStamp to the
// decoded frame), and the one the seek targets, the reader time range and the
// descriptor duration are all stated in. The difference is a constant per
// track: `shift = target.start - source.start` of the single media edit.
//
// `mediaStart` is the movie time at which the media begins. It is nonzero
// exactly when the track carries a leading EMPTY EDIT (elst media_time == -1),
// i.e. a span of container-declared silence before any media exists.
struct AudioMovieTimelineFacts {
  CMTime shift{kCMTimeZero};
  CMTime mediaStart{kCMTimeZero};
};

[[nodiscard]] std::optional<AudioMovieTimelineFacts>
audioMovieTimelineFactsFor(NSArray* segments) noexcept;

// The movie time at which a track's MEDIA begins, or the origin when it begins
// there. Fails safe to the origin.
[[nodiscard]] CMTime trackMediaStartOnMovieTimeline(NSArray* segments) noexcept;

// The movie time a sync search must run from when the requested target lands
// inside a track's leading EMPTY EDIT, or empty to fail closed.
[[nodiscard]] std::optional<CMTime> syncSearchTargetWithinLeadingEmptyEdit(
    CMTime target, CMTime mediaStart) noexcept;

// The latest full-sync sample at or before `target`, on the MOVIE timeline,
// or kCMTimeInvalid. A target inside a leading empty edit searches from the
// track's first media time. `cancelled`, when given, stops the walk.
[[nodiscard]] CMTime fullSyncStart(
    AVAssetTrack* track, CMTime target,
    const std::atomic<bool>* cancelled = nullptr) noexcept;

// Places a located sync start in the neutral timeline window
// (timelineWindowDecodeStart). A container edit list can legitimately put it
// outside `0 <= start <= target` at either end:
//
//   * a head-TRIMMED edit (elst media_time > 0) restates the RAP that decodes
//     the picture at movie time 0 to a NEGATIVE movie time (measured:
//     -0.801917 s on a 24000-timescale file whose video edit starts at media
//     19246). AVAssetReader walks back to that RAP by itself from range start
//     0, so nothing is lost by clamping;
//   * a leading EMPTY EDIT (elst media_time == -1) puts the first RAP AFTER
//     the target (measured: +0.023 s on an ffmpeg-muxed file whose video edit
//     is [(23, -1), (N, 1024)]). A start can only be late when no sync sample
//     exists at or before the search target, so it is the track's first
//     picture: the video origin.
//
// On a head-trimmed file every target before the first in-window RAP walks
// back to the pre-origin IDR, and a preview lane that refused it would fail,
// latch, and veto the COMMIT seek. A start that is not exact is returned
// unchanged for the caller to refuse.
[[nodiscard]] inline CMTime syncStartWithinTimelineWindow(
    CMTime located, media::MediaTime target) noexcept {
  const auto exact = exactMediaTime(located);
  const auto window =
      exact ? timelineWindowDecodeStart(*exact, target, exact) : std::nullopt;
  return window ? CMTimeMake(window->value, window->timescale) : located;
}

// ---- video formats --------------------------------------------------------

// The codec a CoreMedia video subtype names on the AVFoundation route, after
// the route's own admission and this machine's AV1/VP9 gates; Unknown
// otherwise.
[[nodiscard]] media::MediaCodec videoCodec(CMVideoCodecType codec) noexcept;

[[nodiscard]] CFDataRef borrowAtom(CMFormatDescriptionRef format,
                                   CFStringRef atomName) noexcept;

[[nodiscard]] std::optional<std::vector<std::byte>> copyAtom(
    CMFormatDescriptionRef format, CFStringRef atomName,
    std::size_t maximumBytes);

[[nodiscard]] media::MediaVideoSampleFormat parseHevcSampleFormat(
    std::span<const std::byte> configuration) noexcept;

[[nodiscard]] std::optional<media::MediaVideoFormat> inspectVideoFormatFacts(
    CMVideoFormatDescriptionRef format, media::MediaCodec codec,
    std::span<const std::byte> configuration,
    const media::MediaSourceLimits& limits) noexcept;

// Whether a live video format description still states exactly the admitted
// track (rotation excluded: it is a track fact, proven separately).
[[nodiscard]] bool videoFormatMatchesTrack(
    CMVideoFormatDescriptionRef format, const media::MediaTrackDescriptor& track,
    const media::MediaSourceLimits& requestedLimits) noexcept;

}  // namespace wam::macos
