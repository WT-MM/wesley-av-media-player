#include "native_media_clock.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <type_traits>

namespace wam::macos {
namespace {

static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
              "NativeMediaClock requires lock-free 64-bit atomics");

constexpr std::uint64_t kSlotBits = 2;
constexpr std::uint64_t kSlotMask = (1U << kSlotBits) - 1U;
constexpr std::uint64_t kWriterAccessBit = std::uint64_t{1} << 63U;
constexpr std::uint64_t kMaximumReaderCount = kWriterAccessBit - 1U;
constexpr std::uint64_t kDirectWriterToken =
    std::numeric_limits<std::uint64_t>::max();
constexpr std::uint64_t kReservationBuildingToken =
    kDirectWriterToken - 1U;
constexpr std::uint64_t kMaximumReservationToken =
#if defined(WAM_NATIVE_MEDIA_CLOCK_TESTING)
    64U;
#else
    kReservationBuildingToken - 1U;
#endif
constexpr std::uint64_t kMaximumPublicationSerial =
    std::numeric_limits<std::uint64_t>::max() >> kSlotBits;
constexpr std::uint64_t kMaximumActiveGeneration =
    std::numeric_limits<std::uint64_t>::max() - 1U;
constexpr double kMaximumMediaSeconds =
    std::numeric_limits<double>::max();
// The largest media displacement an interval extension may introduce at the
// boundary it buries. Interval endpoints stay exact - they are the consumer's
// own frame-derived media positions - so this bounds only interpolation
// strictly inside a coalesced interval, and that error is discharged at the
// next endpoint rather than accumulated. A device's reported callback
// timestamps drift by a few microseconds around the period they quantize,
// while a real output-time gap or rate change is at least one callback period:
// 100 us sits two orders of magnitude above the former, two below the latter,
// and far below any audible or visible synchronization error.
constexpr double kMaximumBoundaryDisplacementSeconds = 1.0e-4;

// The same bound expressed as whole host ticks. A device timestamp may round
// either way, so a successor interval can be reported starting a few ticks
// before the predicted end of the interval it follows. That overlap is
// quantization, not a rewrite of played output, and it is admitted only while
// it stays inside the displacement bound. A coarse host clock yields zero
// slack, which is exactly the historical exact-adjacency rule.
[[nodiscard]] std::uint64_t quantizationSlackTicks(
    std::uint64_t ticksPerSecond) noexcept {
  return static_cast<std::uint64_t>(kMaximumBoundaryDisplacementSeconds *
                                    static_cast<double>(ticksPerSecond));
}

[[nodiscard]] constexpr std::size_t publicationSlot(
    std::uint64_t publication) noexcept {
  return static_cast<std::size_t>(publication & kSlotMask);
}

[[nodiscard]] constexpr std::uint64_t publicationSerial(
    std::uint64_t publication) noexcept {
  return publication >> kSlotBits;
}

[[nodiscard]] constexpr std::uint64_t encodePublication(
    std::uint64_t serial, std::size_t slot) noexcept {
  return (serial << kSlotBits) | static_cast<std::uint64_t>(slot);
}

[[nodiscard]] bool validMediaSeconds(double value) noexcept {
  return std::isfinite(value) && value >= 0.0;
}

[[nodiscard]] bool validRate(double value) noexcept {
  return std::isfinite(value) && value > 0.0;
}

[[nodiscard]] bool validActiveGeneration(std::uint64_t value) noexcept {
  return value != 0 && value <= kMaximumActiveGeneration;
}

[[nodiscard]] bool validContinuity(
    NativeMediaSegmentContinuity continuity) noexcept {
  switch (continuity) {
  case NativeMediaSegmentContinuity::Discontinuous:
  case NativeMediaSegmentContinuity::Continuous:
    return true;
  }
  return false;
}

[[nodiscard]] bool segmentRate(std::uint64_t ticksPerSecond,
                               std::uint64_t firstHostTicks,
                               std::uint64_t endHostTicks,
                               double mediaStart, double mediaEnd,
                               double *rate) noexcept {
  if (rate == nullptr || ticksPerSecond == 0 ||
      endHostTicks <= firstHostTicks || !validMediaSeconds(mediaStart) ||
      !validMediaSeconds(mediaEnd) || mediaEnd <= mediaStart) {
    return false;
  }
  const double hostSeconds =
      static_cast<double>(endHostTicks - firstHostTicks) /
      static_cast<double>(ticksPerSecond);
  const double derived = (mediaEnd - mediaStart) / hostSeconds;
  if (!validRate(derived)) {
    return false;
  }
  *rate = derived;
  return true;
}

[[nodiscard]] double evaluateLinear(
    double anchorMediaSeconds, std::uint64_t anchorHostTicks,
    std::uint64_t sampledHostTicks, std::uint64_t ticksPerSecond,
    double rate, bool bounded, std::uint64_t endHostTicks,
    double endMediaSeconds) noexcept {
  if (sampledHostTicks <= anchorHostTicks) {
    return anchorMediaSeconds;
  }
  if (bounded && sampledHostTicks >= endHostTicks) {
    return endMediaSeconds;
  }

  const std::uint64_t elapsedTicks = sampledHostTicks - anchorHostTicks;
  const double elapsedSeconds =
      static_cast<double>(elapsedTicks) /
      static_cast<double>(ticksPerSecond);
  const double available = kMaximumMediaSeconds - anchorMediaSeconds;
  if (elapsedSeconds > 0.0 && rate > available / elapsedSeconds) {
    return kMaximumMediaSeconds;
  }

  const double evaluated = anchorMediaSeconds + elapsedSeconds * rate;
  if (!std::isfinite(evaluated)) {
    return kMaximumMediaSeconds;
  }
  return bounded ? std::min(evaluated, endMediaSeconds) : evaluated;
}

} // namespace

static_assert(std::is_trivially_copyable_v<NativeMediaClockSnapshot>);
static_assert(std::is_trivially_copyable_v<NativeMediaSegmentReservation>);

NativeMediaClock::NativeMediaClock(NativeMediaHostClock hostClock) noexcept
    : host_clock_(hostClock) {}

bool NativeMediaClock::configured() const noexcept {
  return host_clock_.readTicks != nullptr && host_clock_.ticksPerSecond != 0;
}

std::uint64_t NativeMediaClock::ticksPerSecond() const noexcept {
  return host_clock_.ticksPerSecond;
}

bool NativeMediaClock::beginDirectWrite() noexcept {
  std::uint64_t expected = 0;
  return writer_gate_.compare_exchange_strong(
      expected, kDirectWriterToken, std::memory_order_acq_rel,
      std::memory_order_acquire);
}

void NativeMediaClock::endWrite() noexcept {
  writer_gate_.store(0, std::memory_order_release);
}

NativeMediaClock::State NativeMediaClock::currentState() const noexcept {
  const std::uint64_t publication =
      publication_.load(std::memory_order_acquire);
  return slots_[publicationSlot(publication)].state;
}

bool NativeMediaClock::publishState(const State &state) noexcept {
  const std::uint64_t current =
      publication_.load(std::memory_order_acquire);
  const std::uint64_t serial = publicationSerial(current);
  if (serial == kMaximumPublicationSerial) {
    return false;
  }

  const std::size_t active = publicationSlot(current);
  for (std::size_t offset = 1; offset < kSlotCount; ++offset) {
    const std::size_t candidate = (active + offset) % kSlotCount;
    std::uint64_t expected = 0;
    if (!slots_[candidate].access.compare_exchange_strong(
            expected, kWriterAccessBit, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      continue;
    }

    slots_[candidate].state = state;
    slots_[candidate].access.store(0, std::memory_order_release);
    publication_.store(encodePublication(serial + 1U, candidate),
                       std::memory_order_release);
    return true;
  }
  return false;
}

bool NativeMediaClock::reserveStatePublication(
    const State &state, NativeMediaSegmentAdmission admission,
    bool consumePcm,
    NativeMediaSegmentReservation *reservation) noexcept {
  if (reservation == nullptr || !nativeMediaSegmentAccepted(admission)) {
    return false;
  }

  const std::uint64_t current =
      publication_.load(std::memory_order_acquire);
  const std::uint64_t serial = publicationSerial(current);
  if (serial == kMaximumPublicationSerial) {
    return false;
  }

  const std::size_t active = publicationSlot(current);
  for (std::size_t offset = 1; offset < kSlotCount; ++offset) {
    const std::size_t candidate = (active + offset) % kSlotCount;
    std::uint64_t expected = 0;
    if (!slots_[candidate].access.compare_exchange_strong(
            expected, kWriterAccessBit, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      continue;
    }

    slots_[candidate].state = state;
    const std::uint64_t token =
        writer_gate_.load(std::memory_order_acquire);
    reservation->admission = admission;
    reservation->token = token;
    reservation->expectedPublication = current;
    reservation->nextPublication =
        encodePublication(serial + 1U, candidate);
    reservation->slot = static_cast<std::uint8_t>(candidate);
    reservation->consumePcm = consumePcm;
    return true;
  }
  return false;
}

double NativeMediaClock::mediaAt(const State &state,
                                 std::uint64_t hostTicks) const noexcept {
  if (!state.valid) {
    return 0.0;
  }
  if (!state.running) {
    return state.anchorMediaSeconds;
  }

  const SegmentState *selected = nullptr;
  if (state.currentSegment.valid) {
    selected = &state.currentSegment;
  }
  if (state.pendingSegment.valid &&
      hostTicks >= state.pendingSegment.firstHostTicks) {
    selected = &state.pendingSegment;
  }
  if (selected == nullptr) {
    return evaluateLinear(
        state.anchorMediaSeconds, state.anchorHostTicks, hostTicks,
        host_clock_.ticksPerSecond, state.rate, false, 0, 0.0);
  }

  double rate = 0.0;
  if (!segmentRate(host_clock_.ticksPerSecond, selected->firstHostTicks,
                   selected->endHostTicks, selected->mediaStart,
                   selected->mediaEnd, &rate)) {
    return selected->mediaStart;
  }
  return evaluateLinear(
      selected->mediaStart, selected->firstHostTicks, hostTicks,
      host_clock_.ticksPerSecond, rate, true, selected->endHostTicks,
      selected->mediaEnd);
}

NativeMediaClockSnapshot NativeMediaClock::sample() const noexcept {
  auto makeSnapshot = [this](const State &state, std::uint64_t publication,
                             std::uint64_t hostTicks,
                             bool current) noexcept {
    NativeMediaClockSnapshot snapshot;
    snapshot.publicationSerial = publicationSerial(publication);
    snapshot.generation = state.generation;
    snapshot.latestSegmentSerial = state.latestSegmentSerial;
    snapshot.publicationCurrent = current;
    if (!state.valid) {
      return snapshot;
    }

    snapshot.valid = true;
    snapshot.running = state.running;
    snapshot.anchorHostTicks = state.anchorHostTicks;
    snapshot.sampledHostTicks =
        state.running ? hostTicks : state.anchorHostTicks;
    snapshot.anchorMediaSeconds = state.anchorMediaSeconds;
    snapshot.mediaSeconds = state.anchorMediaSeconds;
    snapshot.rate = state.rate;
    if (!state.running) {
      return snapshot;
    }

    const SegmentState *selected = nullptr;
    if (state.currentSegment.valid) {
      selected = &state.currentSegment;
    }
    if (state.pendingSegment.valid) {
      snapshot.pendingSegment = true;
      snapshot.pendingSegmentSerial = state.pendingSegment.serial;
      snapshot.pendingFirstHostTicks =
          state.pendingSegment.firstHostTicks;
      snapshot.pendingEndHostTicks = state.pendingSegment.endHostTicks;
      snapshot.pendingMediaStart = state.pendingSegment.mediaStart;
      snapshot.pendingMediaEnd = state.pendingSegment.mediaEnd;
      if (hostTicks >= state.pendingSegment.firstHostTicks) {
        selected = &state.pendingSegment;
      }
    }

    if (selected == nullptr) {
      snapshot.mediaSeconds = evaluateLinear(
          state.anchorMediaSeconds, state.anchorHostTicks, hostTicks,
          host_clock_.ticksPerSecond, state.rate, false, 0, 0.0);
      return snapshot;
    }

    double segment_rate = 0.0;
    if (!segmentRate(host_clock_.ticksPerSecond, selected->firstHostTicks,
                     selected->endHostTicks, selected->mediaStart,
                     selected->mediaEnd, &segment_rate)) {
      snapshot.mediaSeconds = selected->mediaStart;
      return snapshot;
    }
    snapshot.segmentSerial = selected->serial;
    snapshot.anchorHostTicks = selected->firstHostTicks;
    snapshot.segmentEndHostTicks = selected->endHostTicks;
    snapshot.anchorMediaSeconds = selected->mediaStart;
    snapshot.segmentEndMediaSeconds = selected->mediaEnd;
    snapshot.rate = segment_rate;
    snapshot.segmentBounded = true;
    snapshot.segmentExhausted = hostTicks >= selected->endHostTicks;
    snapshot.mediaSeconds = evaluateLinear(
        selected->mediaStart, selected->firstHostTicks, hostTicks,
        host_clock_.ticksPerSecond, segment_rate, true,
        selected->endHostTicks, selected->mediaEnd);
    return snapshot;
  };

  State fallback;
  std::uint64_t fallback_publication = 0;
  bool have_fallback = false;
  for (std::size_t attempt = 0; attempt < kSlotCount; ++attempt) {
    const std::uint64_t before =
        publication_.load(std::memory_order_acquire);
    const Slot &slot = slots_[publicationSlot(before)];
    std::uint64_t access = slot.access.load(std::memory_order_acquire);
    if ((access & kWriterAccessBit) != 0 ||
        access == kMaximumReaderCount ||
        !slot.access.compare_exchange_strong(
            access, access + 1U, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      continue;
    }

    const std::uint64_t pinned =
        publication_.load(std::memory_order_acquire);
    if (pinned != before) {
      slot.access.fetch_sub(1U, std::memory_order_release);
      continue;
    }

    const State state = slot.state;
    const std::uint64_t host_ticks =
        state.valid && state.running
            ? host_clock_.readTicks(host_clock_.context)
            : state.anchorHostTicks;
    const std::uint64_t after =
        publication_.load(std::memory_order_acquire);
    slot.access.fetch_sub(1U, std::memory_order_release);
    if (after == before) {
      return makeSnapshot(state, before, host_ticks, true);
    }

    fallback = state;
    fallback_publication = before;
    have_fallback = true;
  }

  if (have_fallback) {
    const std::uint64_t conservative_ticks =
        fallback.running && fallback.currentSegment.valid
            ? fallback.currentSegment.firstHostTicks
            : fallback.anchorHostTicks;
    return makeSnapshot(fallback, fallback_publication,
                        conservative_ticks, false);
  }

  NativeMediaClockSnapshot unavailable;
  unavailable.publicationSerial = publicationSerial(
      publication_.load(std::memory_order_acquire));
  return unavailable;
}

bool NativeMediaClock::anchor(std::uint64_t generation,
                              double mediaSeconds, double rate,
                              bool running) noexcept {
  if (!configured() || !validActiveGeneration(generation) ||
      !validMediaSeconds(mediaSeconds) || !validRate(rate) ||
      !beginDirectWrite()) {
    return false;
  }

  const State current = currentState();
  if (generation <= current.generation) {
    endWrite();
    return false;
  }

  State next;
  next.generation = generation;
  next.anchorHostTicks = host_clock_.readTicks(host_clock_.context);
  next.anchorMediaSeconds = mediaSeconds;
  next.rate = rate;
  next.valid = true;
  next.running = running;
  const bool published = publishState(next);
  endWrite();
  return published;
}

bool NativeMediaClock::anchorAtHostTicks(
    std::uint64_t generation, std::uint64_t hostTicks,
    double mediaSeconds, double rate, bool running) noexcept {
  if (!configured() || !validActiveGeneration(generation) ||
      !validMediaSeconds(mediaSeconds) || !validRate(rate) ||
      !beginDirectWrite()) {
    return false;
  }

  const State current = currentState();
  if (generation <= current.generation) {
    endWrite();
    return false;
  }

  State next;
  next.generation = generation;
  next.anchorHostTicks = hostTicks;
  next.anchorMediaSeconds = mediaSeconds;
  next.rate = rate;
  next.valid = true;
  next.running = running;
  const bool published = publishState(next);
  endWrite();
  return published;
}

bool NativeMediaClock::prepareSegmentState(
    const State &current, NativeMediaSegment segment,
    std::uint64_t now, State *next,
    NativeMediaSegmentAdmission *admission,
    bool *consumePcm) const noexcept {
  if (next == nullptr || admission == nullptr || consumePcm == nullptr) {
    return false;
  }
  if (segment.serial == 0) {
    return false;
  }
  if (segment.serial <= current.latestSegmentSerial) {
    *admission = NativeMediaSegmentAdmission::Stale;
    return false;
  }
  if (!current.valid || !current.running ||
      !validContinuity(segment.continuity)) {
    return false;
  }
  double incoming_rate = 0.0;
  if (!segmentRate(host_clock_.ticksPerSecond, segment.firstHostTicks,
                   segment.endHostTicks, segment.mediaStart,
                   segment.mediaEnd, &incoming_rate)) {
    return false;
  }
  static_cast<void>(incoming_rate);

  State working = current;
  if (working.pendingSegment.valid &&
      now >= working.pendingSegment.firstHostTicks) {
    working.currentSegment = working.pendingSegment;
    working.pendingSegment = {};
  }

  SegmentState candidate;
  candidate.serial = segment.serial;
  candidate.firstHostTicks = segment.firstHostTicks;
  candidate.endHostTicks = segment.endHostTicks;
  candidate.mediaStart = segment.mediaStart;
  candidate.mediaEnd = segment.mediaEnd;
  candidate.valid = true;

  // Extending an already published interval re-rates its whole union, so the
  // boundary it buries must keep the media position it was published with.
  // Exact slope equality cannot express that: a real device period is not an
  // integral number of host ticks, so CoreAudio quantizes consecutive
  // callback timestamps to whole ticks and no two intervals ever share a
  // bit-exact rational rate. The published boundary is the invariant that
  // matters; hardware quantization moves it by microseconds at most, while a
  // real output-time gap or a real rate change moves it by milliseconds.
  const auto extensionKeepsBoundary =
      [ticksPerSecond = host_clock_.ticksPerSecond](
          const SegmentState &target,
          const SegmentState &extension) noexcept {
        if (!target.valid || ticksPerSecond == 0 ||
            extension.mediaStart != target.mediaEnd ||
            extension.endHostTicks <= target.endHostTicks ||
            target.endHostTicks <= target.firstHostTicks ||
            (extension.firstHostTicks < target.endHostTicks &&
             target.endHostTicks - extension.firstHostTicks >
                 quantizationSlackTicks(ticksPerSecond))) {
          return false;
        }
        double unionRate = 0.0;
        if (!segmentRate(ticksPerSecond, target.firstHostTicks,
                         extension.endHostTicks, target.mediaStart,
                         extension.mediaEnd, &unionRate)) {
          return false;
        }
        const double boundarySeconds =
            static_cast<double>(target.endHostTicks -
                                target.firstHostTicks) /
            static_cast<double>(ticksPerSecond);
        const double displacement =
            std::abs((target.mediaStart + unionRate * boundarySeconds) -
                     target.mediaEnd);
        return displacement <= kMaximumBoundaryDisplacementSeconds;
      };

  auto sameStart = [](const SegmentState &existing,
                      const SegmentState &replacement) noexcept {
    return existing.valid &&
           existing.firstHostTicks == replacement.firstHostTicks &&
           existing.mediaStart == replacement.mediaStart;
  };

  if (sameStart(working.currentSegment, candidate)) {
    if (now >= working.currentSegment.firstHostTicks) {
      return false;
    }
    if (working.pendingSegment.valid &&
        (candidate.endHostTicks >
             working.pendingSegment.firstHostTicks ||
         candidate.mediaEnd != working.pendingSegment.mediaStart)) {
      return false;
    }
    if (candidate.mediaEnd != working.currentSegment.mediaEnd) {
      return false;
    }
    working.currentSegment = candidate;
    *admission = NativeMediaSegmentAdmission::Corrected;
    *consumePcm = false;
  } else if (sameStart(working.pendingSegment, candidate)) {
    if (now >= working.pendingSegment.firstHostTicks) {
      return false;
    }
    if (!working.currentSegment.valid ||
        candidate.firstHostTicks <
            working.currentSegment.endHostTicks ||
        candidate.mediaStart != working.currentSegment.mediaEnd ||
        candidate.mediaEnd != working.pendingSegment.mediaEnd) {
      return false;
    }
    working.pendingSegment = candidate;
    *admission = NativeMediaSegmentAdmission::Corrected;
    *consumePcm = false;
  } else if (segment.continuity ==
             NativeMediaSegmentContinuity::Continuous) {
    SegmentState *target = working.pendingSegment.valid
                               ? &working.pendingSegment
                               : &working.currentSegment;
    if (!target->valid || segment.mediaStart != target->mediaEnd ||
        segment.firstHostTicks != target->endHostTicks) {
      return false;
    }
    if (now < target->firstHostTicks) {
      if (!extensionKeepsBoundary(*target, candidate)) {
        return false;
      }
      target->serial = segment.serial;
      target->endHostTicks = segment.endHostTicks;
      target->mediaEnd = segment.mediaEnd;
      *admission = NativeMediaSegmentAdmission::Coalesced;
    } else {
      working.pendingSegment = candidate;
      *admission = NativeMediaSegmentAdmission::Pending;
    }
    *consumePcm = true;
  } else if (working.pendingSegment.valid) {
    // The sole pending interval is already occupied. A quantization-sized
    // hole between the pending end and this start is not a real output-time
    // gap: it is the tick rounding of a device period that is not an integral
    // number of host ticks, so it may extend the pending interval on exactly
    // the same buried-boundary proof used for a gapless successor. Only a
    // real gap - one that would move that boundary - still forces the
    // callback to render silence and leave its PCM ring untouched.
    if (!extensionKeepsBoundary(working.pendingSegment, candidate)) {
      *admission = NativeMediaSegmentAdmission::Backpressure;
      return false;
    }
    working.pendingSegment.serial = segment.serial;
    working.pendingSegment.endHostTicks = segment.endHostTicks;
    working.pendingSegment.mediaEnd = segment.mediaEnd;
    *admission = NativeMediaSegmentAdmission::Coalesced;
    *consumePcm = true;
  } else if (!working.currentSegment.valid) {
    working.currentSegment = candidate;
    *admission = NativeMediaSegmentAdmission::Current;
    *consumePcm = true;
  } else {
    if (working.pendingSegment.valid) {
      *admission = NativeMediaSegmentAdmission::Backpressure;
      return false;
    }
    // A successor may be reported starting a few host ticks before the
    // predicted end it follows: that is timestamp quantization of a device
    // period, not output that has already been played twice. Queue it as the
    // pending interval anyway; media time still begins exactly at the current
    // interval's end, so the published position stays monotonic.
    if (candidate.mediaStart != working.currentSegment.mediaEnd ||
        (candidate.firstHostTicks <
             working.currentSegment.endHostTicks &&
         working.currentSegment.endHostTicks - candidate.firstHostTicks >
             quantizationSlackTicks(host_clock_.ticksPerSecond))) {
      return false;
    }
    working.pendingSegment = candidate;
    *admission = NativeMediaSegmentAdmission::Pending;
    *consumePcm = true;
  }

  working.latestSegmentSerial = segment.serial;
  *next = working;
  return true;
}

NativeMediaSegmentReservation NativeMediaClock::reserveSegment(
    std::uint64_t expectedGeneration,
    NativeMediaSegment segment) noexcept {
  NativeMediaSegmentReservation result;
  if (!configured() || expectedGeneration == 0) {
    return result;
  }

  std::uint64_t expected = 0;
  if (!writer_gate_.compare_exchange_strong(
          expected, kReservationBuildingToken, std::memory_order_acq_rel,
          std::memory_order_acquire)) {
    result.admission = NativeMediaSegmentAdmission::Backpressure;
    return result;
  }
  if (reservation_serial_ == kMaximumReservationToken) {
    result.admission = NativeMediaSegmentAdmission::Backpressure;
    endWrite();
    return result;
  }
  const std::uint64_t reserved_token = ++reservation_serial_;
  writer_gate_.store(reserved_token, std::memory_order_release);

  const State current = currentState();
  if (!current.valid || current.generation != expectedGeneration) {
    result.admission = NativeMediaSegmentAdmission::Stale;
    endWrite();
    return result;
  }

  State next;
  NativeMediaSegmentAdmission admission{
      NativeMediaSegmentAdmission::Invalid};
  bool consume_pcm = false;
  const std::uint64_t now = host_clock_.readTicks(host_clock_.context);
  if (!prepareSegmentState(current, segment, now, &next, &admission,
                           &consume_pcm)) {
    result.admission = admission;
    endWrite();
    return result;
  }
  if (!reserveStatePublication(next, admission, consume_pcm, &result)) {
    result = {};
    result.admission = NativeMediaSegmentAdmission::Backpressure;
    endWrite();
  }
  return result;
}

bool NativeMediaClock::commitSegment(
    NativeMediaSegmentReservation reservation) noexcept {
  if (!reservation.accepted() || reservation.slot >= kSlotCount ||
      writer_gate_.load(std::memory_order_acquire) != reservation.token) {
    return false;
  }

  Slot &slot = slots_[reservation.slot];
  const bool valid =
      publication_.load(std::memory_order_acquire) ==
          reservation.expectedPublication &&
      publicationSlot(reservation.nextPublication) == reservation.slot &&
      slot.access.load(std::memory_order_acquire) == kWriterAccessBit;
  if (valid) {
    slot.access.store(0, std::memory_order_release);
    publication_.store(reservation.nextPublication,
                       std::memory_order_release);
  } else if (slot.access.load(std::memory_order_acquire) ==
             kWriterAccessBit) {
    slot.access.store(0, std::memory_order_release);
  }
  endWrite();
  return valid;
}

bool NativeMediaClock::cancelSegment(
    NativeMediaSegmentReservation reservation) noexcept {
  if (!reservation.accepted() || reservation.slot >= kSlotCount ||
      writer_gate_.load(std::memory_order_acquire) != reservation.token) {
    return false;
  }

  Slot &slot = slots_[reservation.slot];
  if (slot.access.load(std::memory_order_acquire) != kWriterAccessBit) {
    endWrite();
    return false;
  }
  slot.access.store(0, std::memory_order_release);
  endWrite();
  return true;
}

NativeMediaSegmentAdmission NativeMediaClock::observeSegment(
    std::uint64_t expectedGeneration,
    NativeMediaSegment segment) noexcept {
  NativeMediaSegmentReservation reservation =
      reserveSegment(expectedGeneration, segment);
  if (!reservation.accepted()) {
    return reservation.admission;
  }
  const NativeMediaSegmentAdmission admission = reservation.admission;
  if (!commitSegment(reservation)) {
    return NativeMediaSegmentAdmission::Backpressure;
  }
  return admission;
}

bool NativeMediaClock::seek(std::uint64_t expectedGeneration,
                            std::uint64_t nextGeneration,
                            double mediaSeconds) noexcept {
  if (!configured() || expectedGeneration == 0 ||
      !validActiveGeneration(nextGeneration) ||
      nextGeneration <= expectedGeneration ||
      !validMediaSeconds(mediaSeconds) || !beginDirectWrite()) {
    return false;
  }

  const State current = currentState();
  if (!current.valid || current.generation != expectedGeneration ||
      nextGeneration <= current.generation) {
    endWrite();
    return false;
  }

  State next;
  next.generation = nextGeneration;
  next.anchorHostTicks = host_clock_.readTicks(host_clock_.context);
  next.anchorMediaSeconds = mediaSeconds;
  next.rate = current.rate;
  next.valid = true;
  next.running = current.running;
  const bool published = publishState(next);
  endWrite();
  return published;
}

bool NativeMediaClock::pause(std::uint64_t generation) noexcept {
  if (!configured() || generation == 0 || !beginDirectWrite()) {
    return false;
  }

  const State current = currentState();
  if (!current.valid || current.generation != generation) {
    endWrite();
    return false;
  }
  if (!current.running) {
    endWrite();
    return true;
  }

  const std::uint64_t now = host_clock_.readTicks(host_clock_.context);
  State next;
  next.generation = current.generation;
  next.anchorHostTicks = now;
  next.anchorMediaSeconds = mediaAt(current, now);
  next.rate = current.rate;
  next.valid = true;
  next.running = false;
  const bool published = publishState(next);
  endWrite();
  return published;
}

bool NativeMediaClock::run(std::uint64_t generation, double rate) noexcept {
  if (!configured() || generation == 0 || !validRate(rate) ||
      !beginDirectWrite()) {
    return false;
  }

  const State current = currentState();
  if (!current.valid || current.generation != generation) {
    endWrite();
    return false;
  }

  const std::uint64_t now = host_clock_.readTicks(host_clock_.context);
  State next;
  next.generation = current.generation;
  next.anchorHostTicks = now;
  next.anchorMediaSeconds = mediaAt(current, now);
  next.rate = rate;
  next.valid = true;
  next.running = true;
  const bool published = publishState(next);
  endWrite();
  return published;
}

bool NativeMediaClock::runAtHostTicks(
    std::uint64_t expectedGeneration, std::uint64_t hostTicks,
    double rate) noexcept {
  if (!configured() || expectedGeneration == 0 || !validRate(rate) ||
      !beginDirectWrite()) {
    return false;
  }

  const State current = currentState();
  if (!current.valid || current.running ||
      current.generation != expectedGeneration) {
    endWrite();
    return false;
  }

  State next;
  next.generation = current.generation;
  next.anchorHostTicks = hostTicks;
  next.anchorMediaSeconds = current.anchorMediaSeconds;
  next.rate = rate;
  next.valid = true;
  next.running = true;
  const bool published = publishState(next);
  endWrite();
  return published;
}

bool NativeMediaClock::stop(
    std::uint64_t expectedGeneration,
    std::uint64_t invalidationGeneration) noexcept {
  if (expectedGeneration == 0 ||
      invalidationGeneration <= expectedGeneration ||
      !beginDirectWrite()) {
    return false;
  }

  const State current = currentState();
  if (!current.valid || current.generation != expectedGeneration ||
      invalidationGeneration <= current.generation) {
    endWrite();
    return false;
  }

  State invalid;
  invalid.generation = invalidationGeneration;
  const bool published = publishState(invalid);
  endWrite();
  return published;
}

} // namespace wam::macos
