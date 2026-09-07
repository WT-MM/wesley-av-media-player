#pragma once

#include "native_media_source.hpp"
#include "native_playback_contract.hpp"
#include <numeric>

namespace wam::media {

inline std::optional<MediaTime> canonicalNonnegativeTime(MediaTime value) noexcept {
  if (!value.valid() || value.value < 0) return {};
  const auto divisor = std::gcd(static_cast<std::uint64_t>(value.value),
                                static_cast<std::uint64_t>(value.timescale));
  return MediaTime{value.value / static_cast<std::int64_t>(divisor),
                   value.timescale / static_cast<std::int32_t>(divisor)};
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
struct ExactCommitReady {
  Stamp stamp{};
  Generation generation{};
  GestureId gesture{};
  RequestId request{};
  MediaTime requestedTarget{};
  MediaTime audioPresentationStart{};
  MediaTime actualDecodeStart{};
  MediaTime videoStart{};
  MediaTime videoDuration{};
  std::uint64_t clockPublication{0};
  std::uint64_t drawSequence{0};
  bool videoLaneAbsent{false};
  bool audioLaneAbsent{false};
};

inline bool exactCommitReadyMatches(const CommitSeek& command,
    MediaTime target, std::uint64_t baseline, const ExactCommitReady& ready) noexcept {
  return valid(command) && ready.stamp == command.stamp &&
      ready.generation == command.targetGeneration && ready.gesture == command.gesture &&
      ready.request == command.request &&
      compareMediaTime(ready.requestedTarget, target) == MediaTimeOrder::Equal &&
      ready.clockPublication != 0 && ready.actualDecodeStart.valid() &&
      (ready.audioLaneAbsent || (ready.audioPresentationStart.valid() &&
       compareMediaTime(ready.audioPresentationStart, target) != MediaTimeOrder::Less)) &&
      (ready.videoLaneAbsent || (ready.drawSequence > baseline &&
       exactFrameCovers(ready.videoStart, ready.videoDuration, target)));
}
}
}
