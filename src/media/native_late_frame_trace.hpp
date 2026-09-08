#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace wam::media::late_trace {

// One worker produces each ring; the metrics owner is its sole consumer.
// Full rings reject records and expose loss; they never overwrite unread facts.
template <typename T, std::size_t Capacity> struct Ring {
  static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
  std::array<T, Capacity> records{};
  std::atomic<std::uint64_t> read{0}, written{0}, lost{0};
  bool push(const T& record) noexcept {
    const auto w = written.load(std::memory_order_relaxed);
    if (w - read.load(std::memory_order_acquire) == Capacity) {
      lost.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
    records[w % Capacity] = record;
    written.store(w + 1, std::memory_order_release);
    return true;
  }
  bool pop(T& record) noexcept {
    const auto r = read.load(std::memory_order_relaxed);
    if (r == written.load(std::memory_order_acquire)) return false;
    record = records[r % Capacity];
    read.store(r + 1, std::memory_order_release);
    return true;
  }
};

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
inline const bool enabled = [] {
  const char* value = std::getenv("WAM_NATIVE_BENCHMARK_TELEMETRY");
  return value && std::strcmp(value, "1") == 0;
}();
struct WorkerContext {
  std::uint64_t videoDepth{}, audioDepth{}, stepTicks{}, previousStepTicks{};
  std::uint64_t openTicks{}, lastSeekLanding{};
  std::uint64_t waitBegin{}, waitEnd{}, waitDue{};
  std::uint64_t slowWaitBegin{}, slowWaitEnd{}, slowWaitDue{};
  bool slowWaitTimedOut{};
  bool waitTimedOut{}, waitHostPaced{};
  std::array<std::uint64_t, 10> outputTicks{};
};
inline thread_local WorkerContext worker;
struct Record {
  std::uint64_t consumer{}, generation{}, ordinal{};
  std::int64_t pts{}, duration{};
  std::int32_t ptsScale{}, durationScale{};
  std::uint64_t deadline{}, decodeComplete{}, lease{}, observed{}, commit{};
  std::uint64_t previousCommit{}, sinceOpen{}, sinceSeek{}, ticksPerSecond{};
  std::uint64_t surfaces{}, surfaceRejections{}, decodedDepth{}, videoDepth{}, audioDepth{};
  std::uint64_t workerStep{}, previousWorkerStep{}, clockSample{}, clockAnchor{};
  double clockMedia{}, clockAnchorMedia{};
  std::array<std::uint64_t, 10> outputTicks{};
  std::uint64_t sinceOpenRequest{}, sinceSeekLanding{};
  std::uint64_t display{}, refreshHost{}, refreshPeriod{}, refreshScale{};
  std::uint64_t waitBegin{}, waitEnd{}, waitDue{};
  std::uint64_t slowWaitBegin{}, slowWaitEnd{}, slowWaitDue{};
  bool slowWaitTimedOut{};
  bool waitTimedOut{}, waitHostPaced{};
  bool late{}, awaitingOutput{}, seekKnown{}, seekWithinTwoSeconds{};
};
struct Slot {
  std::atomic<bool> occupied{false};
  Ring<Record, 256> ring;
};
inline std::array<Slot, 16> traceSlots;
inline std::atomic<std::uint64_t> nextConsumer{1}, unavailable{0};
struct Producer {
  Slot* slot{};
  std::uint64_t id{};
  Producer() noexcept {
    if (!enabled) return;
    for (auto& candidate : traceSlots) {
      bool expected = false;
      if (candidate.occupied.compare_exchange_strong(expected, true,
              std::memory_order_acq_rel)) {
        slot = &candidate;
        id = nextConsumer.fetch_add(1, std::memory_order_relaxed);
        return;
      }
    }
    unavailable.fetch_add(1, std::memory_order_relaxed);
  }
  ~Producer() {
    if (slot) slot->occupied.store(false, std::memory_order_release);
  }
  Producer(const Producer&) = delete;
  Producer& operator=(const Producer&) = delete;
  void push(Record record) noexcept {
    if (slot) {
      record.consumer = id;
      slot->ring.push(record);
    }
  }
};
#endif
} // namespace wam::media::late_trace
