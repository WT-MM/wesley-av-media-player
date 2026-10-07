#pragma once

// Bounded process-lifetime multi-producer mailbox. Producers claim one slot,
// write plain data and release-publish it; only the GUI telemetry owner drains.
// No allocation, lock, retry loop, formatting or I/O occurs on the audio thread.
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY)
#include <atomic>
#include <chrono>
#include <cstdint>
namespace wam::media {
enum class AudioBenchmarkEvent : std::uint8_t { Start, Render, Advancing, Play, Stop };
struct AudioBenchmarkPoint {
  AudioBenchmarkEvent event{};
  std::uint64_t generation{}, nanoseconds{}, quantumNanoseconds{};
};
struct AudioBenchmarkSlot {
  AudioBenchmarkPoint point{};
  std::atomic<bool> ready{false};
};
struct AudioBenchmarkMailbox {
  static constexpr unsigned capacity = 8192;
  std::atomic<bool> enabled{false};
  std::atomic<unsigned> claimed{0};
  AudioBenchmarkSlot entries[capacity];
};
static_assert(std::atomic<unsigned>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);
inline AudioBenchmarkMailbox audioBenchmarkMailbox;
inline void audioBenchmarkStamp(AudioBenchmarkEvent event,
                                std::uint64_t generation,
                                std::uint64_t quantumNanoseconds = 0) noexcept {
  auto &box = audioBenchmarkMailbox;
  if (!box.enabled.load(std::memory_order_relaxed)) return;
  const auto now = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
  const unsigned index = box.claimed.fetch_add(1, std::memory_order_relaxed);
  if (index >= box.capacity) return; // GUI fails the telemetry stream closed.
  box.entries[index].point = {event, generation,
                           static_cast<std::uint64_t>(now), quantumNanoseconds};
  box.entries[index].ready.store(true, std::memory_order_release);
}
} // namespace wam::media
#endif
