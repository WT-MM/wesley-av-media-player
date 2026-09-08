#pragma once

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
#include "media/native_late_frame_trace.hpp"
#include <CoreVideo/CVDisplayLink.h>
#include <array>
#include <atomic>
#include <cstdint>

namespace wam::macos::late_display_trace {
struct Snapshot {
  std::uint64_t display{}, host{}, period{}, scale{};
};
struct Display {
  CGDirectDisplayID id{};
  CVDisplayLinkRef link{};
  std::atomic<std::uint64_t> sequence{0}, host{0}, period{0}, scale{0};
};
struct Binding {
  std::atomic<std::uintptr_t> layer{0};
  std::atomic<Display*> display{nullptr};
};
// GUI-only registration is bounded by sixteen displays and thirty-two hosts.
// Display links retain process-lifetime callback storage; no retired host is a callback context.
inline std::array<Display, 16> displays;
inline std::array<Binding, 32> bindings;
static_assert(std::atomic<Display*>::is_always_lock_free);

inline CVReturn refresh(CVDisplayLinkRef, const CVTimeStamp*, const CVTimeStamp* target,
                        CVOptionFlags, CVOptionFlags*, void* context) noexcept {
  if (!target || !(target->flags & kCVTimeStampHostTimeValid) ||
      !(target->flags & kCVTimeStampVideoRefreshPeriodValid) ||
      target->videoRefreshPeriod <= 0 || target->videoTimeScale <= 0) return kCVReturnSuccess;
  auto& display = *static_cast<Display*>(context);
  display.sequence.fetch_add(1, std::memory_order_acq_rel);
  display.host.store(target->hostTime, std::memory_order_relaxed);
  display.period.store(static_cast<std::uint64_t>(target->videoRefreshPeriod), std::memory_order_relaxed);
  display.scale.store(static_cast<std::uint64_t>(target->videoTimeScale), std::memory_order_relaxed);
  display.sequence.fetch_add(1, std::memory_order_release);
  return kCVReturnSuccess;
}

inline void bind(void* layer, CGDirectDisplayID id, bool create = true) noexcept {
  if (!media::late_trace::enabled || !layer || !id) return;
  Binding* binding = nullptr;
  const auto key = reinterpret_cast<std::uintptr_t>(layer);
  for (auto& candidate : bindings)
    if (candidate.layer.load(std::memory_order_acquire) == key) { binding = &candidate; break; }
  if (!binding && !create) return;
  Display* display = nullptr;
  for (auto& candidate : displays)
    if (candidate.id == id) { display = &candidate; break; }
  if (!display) {
    for (auto& candidate : displays) {
      if (candidate.id) continue;
      candidate.id = id;
      if (CVDisplayLinkCreateWithCGDisplay(id, &candidate.link) != kCVReturnSuccess) return;
      if (CVDisplayLinkSetOutputCallback(candidate.link, refresh, &candidate) != kCVReturnSuccess ||
          CVDisplayLinkStart(candidate.link) != kCVReturnSuccess) {
        CVDisplayLinkRelease(candidate.link);
        candidate.link = nullptr;
        return;
      }
      display = &candidate;
      break;
    }
  }
  if (!display || !display->link) return;
  if (!binding) {
    for (auto& candidate : bindings) {
      std::uintptr_t empty = 0;
      if (candidate.layer.compare_exchange_strong(empty, 1, std::memory_order_acq_rel)) {
        binding = &candidate;
        binding->display.store(display, std::memory_order_relaxed);
        binding->layer.store(key, std::memory_order_release);
        return;
      }
    }
    return;
  }
  binding->display.store(display, std::memory_order_release);
}

inline void unbind(void* layer) noexcept {
  const auto key = reinterpret_cast<std::uintptr_t>(layer);
  if (!key) return;
  for (auto& binding : bindings) {
    auto expected = key;
    if (binding.layer.compare_exchange_strong(expected, 0, std::memory_order_acq_rel)) return;
  }
}

// A racing callback or host transition yields unavailable data, never a retry loop.
inline Snapshot sample(void* layer) noexcept {
  const auto key = reinterpret_cast<std::uintptr_t>(layer);
  if (!key) return {};
  for (auto& binding : bindings) {
    if (binding.layer.load(std::memory_order_acquire) != key) continue;
    auto* display = binding.display.load(std::memory_order_acquire);
    if (!display) return {};
    const auto first = display->sequence.load(std::memory_order_acquire);
    if (first & 1) return {};
    Snapshot result{display->id, display->host.load(std::memory_order_relaxed),
        display->period.load(std::memory_order_relaxed), display->scale.load(std::memory_order_relaxed)};
    // Payload reads must precede the validating sequence load.
    std::atomic_thread_fence(std::memory_order_acq_rel);
    if (first != display->sequence.load(std::memory_order_acquire) ||
        binding.layer.load(std::memory_order_acquire) != key ||
        binding.display.load(std::memory_order_acquire) != display) return {};
    return result;
  }
  return {};
}
} // namespace wam::macos::late_display_trace
#endif
