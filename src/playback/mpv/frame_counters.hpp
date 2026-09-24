#pragma once

#include <mpv/render.h>
#include <atomic>
#include <cstdint>

namespace wam::playback::mpv {

// One render-thread producer. Reset is serialized with render by PlayerCore's
// existing render mutex; the GUI sampler reads only the atomic cumulative count.
class FrameCounters final {
 public:
  void reset() noexcept { drawn_.store(0, std::memory_order_relaxed); }
  void rendered(const mpv_render_frame_info& info, int result) noexcept {
    if (result >= 0 && (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) &&
        !(info.flags & (MPV_RENDER_FRAME_INFO_REDRAW | MPV_RENDER_FRAME_INFO_REPEAT)))
      drawn_.fetch_add(1, std::memory_order_relaxed);
  }
  [[nodiscard]] std::uint64_t drawn() const noexcept {
    return drawn_.load(std::memory_order_relaxed);
  }
 private:
  std::atomic<std::uint64_t> drawn_{0};
};

} // namespace wam::playback::mpv
