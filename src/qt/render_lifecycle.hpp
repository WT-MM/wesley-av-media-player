#pragma once

#include <atomic>
#include <cstdint>
#include <optional>

namespace wam::qt {

// A render ticket couples availability to a scene-graph generation. A plain
// boolean is insufficient: Qt may destroy and recreate the render context
// while an asynchronous libmpv command is still queued.
enum class RenderPhase : std::uint8_t {
  Empty = 0,
  Creating = 1,
  Ready = 2,
  Failed = 3,
};

struct RenderTicket {
  std::uint64_t stamp = 0;

  friend bool operator==(RenderTicket, RenderTicket) = default;
};

class RenderLifecycle final {
 public:
  RenderLifecycle() = default;

  RenderLifecycle(const RenderLifecycle &) = delete;
  RenderLifecycle &operator=(const RenderLifecycle &) = delete;

  [[nodiscard]] RenderTicket snapshot() const noexcept {
    return {stamp_.load(std::memory_order_acquire)};
  }

  [[nodiscard]] std::optional<RenderTicket> readyTicket() const noexcept {
    const RenderTicket ticket = snapshot();
    if (phase(ticket) != RenderPhase::Ready)
      return std::nullopt;
    return ticket;
  }

  [[nodiscard]] bool validatesReady(RenderTicket ticket) const noexcept {
    return phase(ticket) == RenderPhase::Ready && snapshot() == ticket;
  }

  [[nodiscard]] bool validatesFailed(RenderTicket ticket) const noexcept {
    return phase(ticket) == RenderPhase::Failed && snapshot() == ticket;
  }

  // Only Qt's render thread starts and completes creation. Atomic transitions
  // still matter because the GUI thread reads tickets and may explicitly arm
  // a retry after a latched failure.
  [[nodiscard]] std::optional<RenderTicket> beginCreation() noexcept {
    std::uint64_t current = stamp_.load(std::memory_order_acquire);
    while (phase({current}) == RenderPhase::Empty) {
      const std::uint64_t desired =
          pack(generation({current}), RenderPhase::Creating);
      if (stamp_.compare_exchange_weak(current, desired,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
        return RenderTicket{desired};
      }
    }
    return std::nullopt;
  }

  [[nodiscard]] std::optional<RenderTicket>
  completeCreation(RenderTicket creating, bool succeeded) noexcept {
    if (phase(creating) != RenderPhase::Creating)
      return std::nullopt;
    std::uint64_t expected = creating.stamp;
    const std::uint64_t desired =
        pack(generation(creating),
             succeeded ? RenderPhase::Ready : RenderPhase::Failed);
    if (!stamp_.compare_exchange_strong(expected, desired,
                                        std::memory_order_acq_rel,
                                        std::memory_order_acquire)) {
      return std::nullopt;
    }
    return RenderTicket{desired};
  }

  // Publish unavailability before the render context is freed. Repeated Qt
  // teardown callbacks are idempotent while already Empty.
  [[nodiscard]] std::optional<RenderTicket> invalidate() noexcept {
    std::uint64_t current = stamp_.load(std::memory_order_acquire);
    while (phase({current}) != RenderPhase::Empty) {
      const std::uint64_t desired =
          pack(nextGeneration(generation({current})), RenderPhase::Empty);
      if (stamp_.compare_exchange_weak(current, desired,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
        return RenderTicket{current};
      }
    }
    return std::nullopt;
  }

  // A failed generation is retried only for an explicit user open. Normal
  // render passes cannot turn a persistent setup error into a hot loop.
  [[nodiscard]] bool retryFailure() noexcept {
    std::uint64_t current = stamp_.load(std::memory_order_acquire);
    while (phase({current}) == RenderPhase::Failed) {
      const std::uint64_t desired =
          pack(nextGeneration(generation({current})), RenderPhase::Empty);
      if (stamp_.compare_exchange_weak(current, desired,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
        return true;
      }
    }
    return false;
  }

  [[nodiscard]] static RenderPhase phase(RenderTicket ticket) noexcept {
    return static_cast<RenderPhase>(ticket.stamp & kPhaseMask);
  }

  [[nodiscard]] static std::uint64_t
  generation(RenderTicket ticket) noexcept {
    return ticket.stamp >> kPhaseBits;
  }

 private:
  static constexpr std::uint64_t kPhaseBits = 2;
  static constexpr std::uint64_t kPhaseMask = (1ULL << kPhaseBits) - 1ULL;
  static constexpr std::uint64_t kMaximumGeneration =
      UINT64_MAX >> kPhaseBits;

  [[nodiscard]] static constexpr std::uint64_t
  pack(std::uint64_t generation, RenderPhase phase) noexcept {
    return (generation << kPhaseBits) |
           static_cast<std::uint64_t>(phase);
  }

  [[nodiscard]] static constexpr std::uint64_t
  nextGeneration(std::uint64_t generation) noexcept {
    // Wrapping would require more than four quintillion scene-graph losses in
    // one process. Skip zero so a default-constructed ticket is never valid.
    return generation >= kMaximumGeneration ? 1 : generation + 1;
  }

  std::atomic<std::uint64_t> stamp_{pack(1, RenderPhase::Empty)};
};

} // namespace wam::qt
