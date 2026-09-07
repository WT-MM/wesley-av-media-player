#pragma once
#include <cstring>
#include <mach-o/dyld.h>
#include <mutex>
namespace wam::media::avcodec {
// Both playback loaders hold this cold-path lock across image inspection/loading.
inline std::mutex& playbackClosureMutex() { static std::mutex mutex; return mutex; }
inline bool nativeClosurePresent() noexcept {
  for (std::uint32_t i = 0; i < _dyld_image_count(); ++i)
    if (const char* name = _dyld_get_image_name(i))
      if (std::strstr(name, "libavcodec-wamnative.") || std::strstr(name, "libavutil-wamnative.")) return true;
  return false;
}
inline bool foreignClosurePresent() noexcept {
  for (std::uint32_t i = 0; i < _dyld_image_count(); ++i) {
    const char* name = _dyld_get_image_name(i);
    if (!name) continue;
    if (std::strstr(name, "WAMMpvFallback.") ||
        ((std::strstr(name, "libavcodec.") || std::strstr(name, "libavutil.")))) return true;
  }
  return false;
}
}
