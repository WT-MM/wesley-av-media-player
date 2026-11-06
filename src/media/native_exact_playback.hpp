#pragma once

#include "native_media_source.hpp"
#include "native_playback_contract.hpp"

namespace wam::media {

inline std::optional<MediaTime> canonicalNonnegativeTime(MediaTime value) noexcept {
  if (!value.valid() || value.value < 0) return {};
  return mediaTimeFromTicks(value.value, static_cast<std::uint32_t>(value.timescale));
}

// Half-open coverage uses integer cross-products, including off-grid targets.
inline bool exactFrameCovers(MediaTime start, MediaTime duration, MediaTime target) noexcept {
  if (!start.valid() || !duration.valid() || duration.value <= 0 ||
      !target.valid() || target.value < 0) return false;
  const __int128 offset = __int128(target.value) * start.timescale -
                          __int128(start.value) * target.timescale;
  return offset >= 0 && offset * duration.timescale <
      __int128(duration.value) * target.timescale * start.timescale;
}

std::optional<double> mediaTimeSecondsAtHostTicks(MediaTime origin,
    std::uint64_t ticks, std::uint64_t ticksPerSecond,
    std::uint32_t rateUnits64) noexcept;

namespace native_playback {
inline bool commitReadyMatches(const CommitSeek& command, MediaTime target,
    std::uint64_t drawBaseline, const CommitReady& ready) noexcept {
  return valid(command) && valid(ready) &&
      sameCommand(command.stamp, ready.stamp) &&
      ready.generation == command.targetGeneration &&
      ready.gesture == command.gesture && ready.request == command.request &&
      ready.targetSeconds == command.targetSeconds &&
      compareMediaTime(ready.target, target) == MediaTimeOrder::Equal &&
      ready.actualDecodeStart.valid() &&
      (ready.audioLaneAbsent || (ready.audioPresentationStart.valid() &&
       compareMediaTime(ready.audioPresentationStart, target) != MediaTimeOrder::Less)) &&
      (ready.videoDraw.videoLaneAbsent || (ready.videoDraw.drawSequence > drawBaseline &&
       exactFrameCovers(ready.videoStart, ready.videoDuration, target)));
}
}
}
