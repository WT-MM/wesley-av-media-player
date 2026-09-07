#pragma once

#include "media/native_media_source.hpp"

namespace wam::media {

[[nodiscard]] inline bool isSlowVideoSeek(MediaTime target, MediaTime start) noexcept {
  if (!target.valid() || !start.valid()) return false;
  constexpr auto threshold = static_cast<std::int64_t>(
      MediaSourceLimits::kHardMaximumVideoSeekPrerollSeconds);
  static_assert(static_cast<double>(threshold) ==
                MediaSourceLimits::kHardMaximumVideoSeekPrerollSeconds);
  return static_cast<__int128>(target.value) * start.timescale -
             static_cast<__int128>(start.value) * target.timescale >
         static_cast<__int128>(threshold) * target.timescale * start.timescale;
}

// Progress extends the inactivity deadline; elapsed seek duration never does.
struct SeekProgressDeadline {
  static constexpr unsigned pollMilliseconds = 250;
  static constexpr unsigned inactivityMilliseconds = 10'000;
  std::uint64_t decodedFrames{0};
  unsigned idleMilliseconds{0};

  [[nodiscard]] bool expired(std::uint64_t frames) noexcept {
    if (frames != decodedFrames) {
      decodedFrames = frames;
      idleMilliseconds = 0;
      return false;
    }
    if (idleMilliseconds < inactivityMilliseconds)
      idleMilliseconds += pollMilliseconds;
    return idleMilliseconds >= inactivityMilliseconds;
  }
};

} // namespace wam::media
