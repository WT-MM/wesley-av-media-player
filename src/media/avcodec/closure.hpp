#pragma once
#include "wam_pins.hpp"
#include <cstdint>
#include <initializer_list>
#include <mach-o/dyld.h>
#include <mutex>
#include <string_view>
namespace wam::media::avcodec {
// Both playback loaders hold this cold-path lock across image inspection/loading.
inline std::mutex& playbackClosureMutex() { static std::mutex mutex; return mutex; }
// "libavcodec-wamnative.63.dylib" -> "libavcodec-wamnative.", which also
// matches the library's other versioned names.
constexpr std::string_view libraryStem(std::string_view name) noexcept {
  return name.substr(0, name.find('.') + 1);
}
inline bool anyImageNamed(std::initializer_list<std::string_view> stems) noexcept {
  for (std::uint32_t i = 0; i < _dyld_image_count(); ++i)
    if (const char* name = _dyld_get_image_name(i))
      for (const std::string_view stem : stems)
        if (std::string_view(name).find(stem) != std::string_view::npos) return true;
  return false;
}
inline bool nativeClosurePresent() noexcept {
  return anyImageNamed({libraryStem(pins::kNativeAvcodecLibrary), libraryStem(pins::kNativeAvutilLibrary)});
}
inline bool foreignClosurePresent() noexcept {
  return anyImageNamed({libraryStem(pins::kMpvFallbackLibrary), "libavcodec.", "libavutil."});
}
}
