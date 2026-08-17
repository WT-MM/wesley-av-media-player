#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace wam::macos {

using NativeMediaHostTickReader =
    std::uint64_t (*)(void *context) noexcept;

// The reader must return monotonic ticks without blocking or allocating. The
// clock keeps this seam immutable, so the context must outlive the clock and
// every concurrent sample().
struct NativeMediaHostClock {
  NativeMediaHostTickReader readTicks{nullptr};
  void *context{nullptr};
  std::uint64_t ticksPerSecond{0};
};

enum class NativeMediaSegmentContinuity : std::uint8_t {
  // A real output-time gap precedes this interval. Media time holds across
  // that gap, so the interval may consume the capacity-one pending slot.
  Discontinuous,
  // PCM was rendered without an intervening silence gap. mediaStart must
  // equal the prior stored mediaEnd and firstHostTicks must equal the prior
  // stored endHostTicks. A future equal-rate interval may coalesce without
  // changing that exact shared boundary.
  Continuous,
};

// INVARIANT on mediaStart/mediaEnd: both endpoints must originate from
// mediaTimeSecondsAtFrame() on the same origin and rate. That function is a
// correctly-rounded 128-bit rational-to-double, so an equal integer frame
// index implies an identical bit pattern, and the mapping stays injective past
// 95 years of 48 kHz media. The exact ==/!= comparisons in the admission logic
// are therefore frame-index identity tests wearing a double's clothes, not
// float equality tests -- see the note above `sameStart` in
// native_media_clock.cpp. A producer that computes either endpoint any other
// way breaks admission silently; the bounded invariant that absorbs real
// hardware quantization is kMaximumBoundaryDisplacementSeconds, not these.
struct NativeMediaSegment {
  std::uint64_t serial{0};
  std::uint64_t firstHostTicks{0};
  std::uint64_t endHostTicks{0};
  double mediaStart{0.0};
  double mediaEnd{0.0};
  NativeMediaSegmentContinuity continuity{
      NativeMediaSegmentContinuity::Discontinuous};
};

enum class NativeMediaSegmentAdmission : std::uint8_t {
  Invalid,
  Stale,
  Backpressure,
  Current,
  Corrected,
  Coalesced,
  Pending,
};

[[nodiscard]] constexpr bool nativeMediaSegmentAccepted(
    NativeMediaSegmentAdmission admission) noexcept {
  return admission == NativeMediaSegmentAdmission::Current ||
         admission == NativeMediaSegmentAdmission::Corrected ||
         admission == NativeMediaSegmentAdmission::Coalesced ||
         admission == NativeMediaSegmentAdmission::Pending;
}

// reserveSegment() owns one fixed publication slot until commitSegment() or
// cancelSegment(). It is a trivially copyable capability; stale or duplicate
// copies are rejected by token validation.
struct NativeMediaSegmentReservation {
  NativeMediaSegmentAdmission admission{NativeMediaSegmentAdmission::Invalid};
  std::uint64_t token{0};
  std::uint64_t expectedPublication{0};
  std::uint64_t nextPublication{0};
  std::uint8_t slot{0};
  bool consumePcm{false};

  [[nodiscard]] constexpr bool accepted() const noexcept {
    return nativeMediaSegmentAccepted(admission) && token != 0;
  }
  [[nodiscard]] constexpr bool requiresPcm() const noexcept {
    return accepted() && consumePcm;
  }
};

// A coherent, generation-tagged view. anchor* fields describe the exact
// interval used to evaluate mediaSeconds. A false publicationCurrent is a
// bounded conservative fallback captured during continuous publication; the
// caller should retain its prior current sample rather than treat it as a new
// time observation.
struct NativeMediaClockSnapshot {
  std::uint64_t publicationSerial{0};
  std::uint64_t generation{0};
  std::uint64_t anchorHostTicks{0};
  std::uint64_t sampledHostTicks{0};
  std::uint64_t segmentSerial{0};
  std::uint64_t segmentEndHostTicks{0};
  std::uint64_t latestSegmentSerial{0};
  std::uint64_t pendingSegmentSerial{0};
  std::uint64_t pendingFirstHostTicks{0};
  std::uint64_t pendingEndHostTicks{0};
  double anchorMediaSeconds{0.0};
  double mediaSeconds{0.0};
  double segmentEndMediaSeconds{0.0};
  double pendingMediaStart{0.0};
  double pendingMediaEnd{0.0};
  double rate{1.0};
  bool valid{false};
  bool running{false};
  bool segmentBounded{false};
  bool segmentExhausted{false};
  bool pendingSegment{false};
  bool publicationCurrent{false};
};

// Backend-neutral authoritative media clock. Four fixed immutable POD slots
// and per-slot reader pins keep sample() allocation-free and bounded: it makes
// at most four exact attempts and never waits for a writer. A racing writer
// yields either an exact publication or a coherent conservative fallback.
// Writers scan each inactive slot once and return failure/backpressure rather
// than waiting for readers. Mutations are single-writer; a one-shot atomic gate
// rejects accidental overlap without spinning. While output is running, its
// real-time callback must be the sole writer. Control mutations must quiesce
// that callback first.
class NativeMediaClock final {
public:
  explicit NativeMediaClock(NativeMediaHostClock hostClock) noexcept;

  NativeMediaClock(const NativeMediaClock &) = delete;
  NativeMediaClock &operator=(const NativeMediaClock &) = delete;
  NativeMediaClock(NativeMediaClock &&) = delete;
  NativeMediaClock &operator=(NativeMediaClock &&) = delete;

  [[nodiscard]] bool configured() const noexcept;
  [[nodiscard]] std::uint64_t ticksPerSecond() const noexcept;
  [[nodiscard]] NativeMediaClockSnapshot sample() const noexcept;

  // Establishes a strictly newer active generation. UINT64_MAX is reserved
  // for terminal invalidation.
  [[nodiscard]] bool anchor(std::uint64_t generation,
                            double mediaSeconds, double rate,
                            bool running) noexcept;
  [[nodiscard]] bool anchorAtHostTicks(std::uint64_t generation,
                                       std::uint64_t hostTicks,
                                       double mediaSeconds, double rate,
                                       bool running) noexcept;

  // Prepares publication before an output callback destructively consumes
  // PCM. The single PCM consumer first obtains an exact readable-frame count
  // while generation flush is quiesced and describes exactly that many
  // frames. It consumes them only when requiresPcm() is true, then commits.
  // A metadata-only correction is accepted with requiresPcm() false and must
  // not consume again. Backpressure means render silence and consume none.
  [[nodiscard]] NativeMediaSegmentReservation reserveSegment(
      std::uint64_t expectedGeneration,
      NativeMediaSegment segment) noexcept;
  [[nodiscard]] bool commitSegment(
      NativeMediaSegmentReservation reservation) noexcept;
  [[nodiscard]] bool cancelSegment(
      NativeMediaSegmentReservation reservation) noexcept;

  // Convenience for a caller that does not need a consume-between-reserve-and-
  // commit transaction. The returned admission is accepted only when the
  // publication committed.
  [[nodiscard]] NativeMediaSegmentAdmission observeSegment(
      std::uint64_t expectedGeneration,
      NativeMediaSegment segment) noexcept;

  [[nodiscard]] bool seek(std::uint64_t expectedGeneration,
                          std::uint64_t nextGeneration,
                          double mediaSeconds) noexcept;
  [[nodiscard]] bool pause(std::uint64_t generation) noexcept;
  [[nodiscard]] bool run(std::uint64_t generation, double rate) noexcept;

  // Resumes an exact paused generation at an externally supplied future host
  // tick without consulting the local clock. Running states are rejected.
  [[nodiscard]] bool runAtHostTicks(std::uint64_t expectedGeneration,
                                    std::uint64_t hostTicks,
                                    double rate) noexcept;

  [[nodiscard]] bool stop(std::uint64_t expectedGeneration,
                          std::uint64_t invalidationGeneration) noexcept;

private:
  static constexpr std::size_t kSlotCount = 4;

  struct SegmentState {
    std::uint64_t serial{0};
    std::uint64_t firstHostTicks{0};
    std::uint64_t endHostTicks{0};
    double mediaStart{0.0};
    double mediaEnd{0.0};
    bool valid{false};
  };

  struct State {
    std::uint64_t generation{0};
    std::uint64_t anchorHostTicks{0};
    std::uint64_t latestSegmentSerial{0};
    double anchorMediaSeconds{0.0};
    double rate{1.0};
    SegmentState currentSegment;
    SegmentState pendingSegment;
    bool valid{false};
    bool running{false};
  };

  struct Slot {
    mutable std::atomic<std::uint64_t> access{0};
    State state;
  };

  [[nodiscard]] bool beginDirectWrite() noexcept;
  void endWrite() noexcept;
  [[nodiscard]] State currentState() const noexcept;
  [[nodiscard]] bool publishState(const State &state) noexcept;
  [[nodiscard]] bool reserveStatePublication(
      const State &state, NativeMediaSegmentAdmission admission,
      bool consumePcm,
      NativeMediaSegmentReservation *reservation) noexcept;
  [[nodiscard]] bool prepareSegmentState(
      const State &current, NativeMediaSegment segment,
      std::uint64_t now, State *next,
      NativeMediaSegmentAdmission *admission,
      bool *consumePcm) const noexcept;
  [[nodiscard]] double mediaAt(const State &state,
                               std::uint64_t hostTicks) const noexcept;

  const NativeMediaHostClock host_clock_;
  std::array<Slot, kSlotCount> slots_{};
  std::atomic<std::uint64_t> publication_{0};
  std::atomic<std::uint64_t> writer_gate_{0};
  std::uint64_t reservation_serial_{0};
};

} // namespace wam::macos
