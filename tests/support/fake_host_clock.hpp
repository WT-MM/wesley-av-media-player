#pragma once

#include "media/native_media_clock.hpp"

#include <atomic>
#include <cstdint>

// A host clock the test sets by hand; `reads` counts how often the code under
// test sampled it.
struct FakeHostClock {
  std::atomic<std::uint64_t> ticks{0};
  std::atomic<std::uint64_t> reads{0};

  static std::uint64_t read(void* context) noexcept {
    auto& clock = *static_cast<FakeHostClock*>(context);
    clock.reads.fetch_add(1, std::memory_order_relaxed);
    return clock.ticks.load(std::memory_order_relaxed);
  }

  [[nodiscard]] wam::media::NativeMediaHostClock seam(
      std::uint64_t ticksPerSecond) noexcept {
    return {&read, this, ticksPerSecond};
  }
};
