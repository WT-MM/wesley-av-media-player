#include "platform/macos/native_media_clock.hpp"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#if !defined(WAM_NATIVE_MEDIA_CLOCK_TESTING)
#error "native media clock tests require bounded test-only token limits"
#endif

namespace {

using wam::macos::NativeMediaClock;
using wam::macos::NativeMediaClockSnapshot;
using wam::macos::NativeMediaHostClock;
using wam::macos::NativeMediaSegment;
using wam::macos::NativeMediaSegmentAdmission;
using wam::macos::NativeMediaSegmentContinuity;
using wam::macos::NativeMediaSegmentReservation;
using wam::macos::nativeMediaSegmentAccepted;

static_assert(std::is_trivially_copyable_v<NativeMediaClockSnapshot>);
static_assert(std::is_trivially_copyable_v<NativeMediaSegmentReservation>);
static_assert(noexcept(std::declval<const NativeMediaClock &>().sample()));
static_assert(noexcept(std::declval<NativeMediaClock &>().anchor(
    1, 0.0, 1.0, false)));
static_assert(noexcept(std::declval<NativeMediaClock &>().anchorAtHostTicks(
    1, 0, 0.0, 1.0, false)));
static_assert(noexcept(std::declval<NativeMediaClock &>().reserveSegment(
    1, NativeMediaSegment{})));
static_assert(noexcept(std::declval<NativeMediaClock &>().commitSegment(
    NativeMediaSegmentReservation{})));
static_assert(noexcept(std::declval<NativeMediaClock &>().runAtHostTicks(
    1, 0, 1.0)));

int failures = 0;

void expect(bool condition, const char *message) {
  if (condition) {
    return;
  }
  std::cerr << "FAIL: " << message << '\n';
  ++failures;
}

void expectNear(double actual, double expected, double tolerance,
                const char *message) {
  expect(std::abs(actual - expected) <= tolerance, message);
}

struct FakeHostClock {
  std::atomic<std::uint64_t> ticks{0};
  std::atomic<std::uint64_t> reads{0};

  static std::uint64_t read(void *context) noexcept {
    auto &clock = *static_cast<FakeHostClock *>(context);
    clock.reads.fetch_add(1, std::memory_order_relaxed);
    return clock.ticks.load(std::memory_order_relaxed);
  }

  [[nodiscard]] NativeMediaHostClock seam(
      std::uint64_t ticksPerSecond) noexcept {
    return {&read, this, ticksPerSecond};
  }
};

[[nodiscard]] NativeMediaSegment segment(
    std::uint64_t serial, std::uint64_t firstHostTicks,
    std::uint64_t endHostTicks, double mediaStart, double mediaEnd,
    NativeMediaSegmentContinuity continuity =
        NativeMediaSegmentContinuity::Discontinuous) noexcept {
  return {serial, firstHostTicks, endHostTicks, mediaStart, mediaEnd,
          continuity};
}

void testConfigurationPausedAndInvalidation() {
  FakeHostClock host;
  host.ticks.store(100, std::memory_order_relaxed);
  NativeMediaClock clock(host.seam(1000));
  expect(clock.configured() && clock.ticksPerSecond() == 1000,
         "a complete host seam exposes its immutable exact frequency");

  const auto initial = clock.sample();
  expect(initial.publicationCurrent && initial.generation == 0 &&
             !initial.valid && !initial.running,
         "a new clock has a coherent invalid generation-zero sample");
  expect(host.reads.load(std::memory_order_relaxed) == 0,
         "an invalid sample does not read host time");

  expect(clock.anchor(7, 12.5, 1.25, false),
         "a newer paused anchor is accepted");
  host.ticks.store(9000, std::memory_order_relaxed);
  const auto paused = clock.sample();
  expect(paused.publicationCurrent && paused.valid && !paused.running &&
             paused.generation == 7 && paused.anchorHostTicks == 100 &&
             paused.sampledHostTicks == 100 &&
             paused.anchorMediaSeconds == 12.5 &&
             paused.mediaSeconds == 12.5 && paused.rate == 1.25,
         "a paused sample remains fixed at its exact raw anchor");
  expect(host.reads.load(std::memory_order_relaxed) == 1,
         "paused sampling performs no host read");

  expect(!clock.pause(6) && !clock.run(6, 1.0) &&
             !clock.stop(6, 8),
         "stale generations reject every transport mutation");
  expect(clock.stop(7, 10),
         "stop advances an exact active generation to invalidation");
  const auto stopped = clock.sample();
  expect(stopped.publicationCurrent && stopped.generation == 10 &&
             !stopped.valid && !stopped.running &&
             stopped.anchorHostTicks == 0 && stopped.mediaSeconds == 0.0,
         "a stopped clock retains only its invalidation generation");
  expect(!clock.anchor(10, 0.0, 1.0, false) &&
             clock.anchor(11, 0.0, 1.0, false),
         "reactivation requires a generation newer than invalidation");

  NativeMediaClock missingReader({nullptr, nullptr, 1000});
  NativeMediaClock missingScale({&FakeHostClock::read, &host, 0});
  expect(!missingReader.configured() && !missingScale.configured() &&
             missingReader.ticksPerSecond() == 1000 &&
             missingScale.ticksPerSecond() == 0 &&
             !missingReader.anchor(1, 0.0, 1.0, false) &&
             !missingScale.anchorAtHostTicks(1, 0, 0.0, 1.0, true),
         "incomplete host seams remain inert");
}

void testRunningRatesAndExactFutureResume() {
  FakeHostClock host;
  host.ticks.store(100, std::memory_order_relaxed);
  NativeMediaClock clock(host.seam(100));
  expect(clock.anchor(1, 10.0, 2.0, true),
         "a running anchor is accepted");

  host.ticks.store(350, std::memory_order_relaxed);
  auto running = clock.sample();
  expect(running.publicationCurrent && running.running &&
             running.anchorHostTicks == 100 &&
             running.sampledHostTicks == 350,
         "a running sample exposes a coherent host tick and anchor");
  expectNear(running.mediaSeconds, 15.0, 1e-12,
             "running media advances by elapsed host time times rate");

  expect(clock.pause(1), "the exact running generation pauses");
  const auto frozen = clock.sample();
  expect(!frozen.running && frozen.anchorHostTicks == 350 &&
             frozen.mediaSeconds == 15.0,
         "pause fixes the evaluated media position");
  const std::uint64_t readsBeforeResume =
      host.reads.load(std::memory_order_relaxed);
  expect(!clock.runAtHostTicks(2, 500, 0.5),
         "future-host resume rejects a stale generation");
  expect(clock.runAtHostTicks(1, 500, 0.5),
         "future-host resume accepts the exact paused generation");
  expect(host.reads.load(std::memory_order_relaxed) == readsBeforeResume,
         "future-host resume performs no implicit now read");
  host.ticks.store(450, std::memory_order_relaxed);
  expect(clock.sample().mediaSeconds == 15.0,
         "future-host resume holds until its supplied first tick");
  host.ticks.store(600, std::memory_order_relaxed);
  expectNear(clock.sample().mediaSeconds, 15.5, 1e-12,
             "future-host resume advances from the supplied tick");
  expect(!clock.runAtHostTicks(1, 700, 1.0),
         "future-host resume rejects an already-running state");

  expect(clock.run(1, 4.0),
         "run can re-anchor an already-running convenience clock");
  host.ticks.store(650, std::memory_order_relaxed);
  expectNear(clock.sample().mediaSeconds, 17.5, 1e-12,
             "a running rate change preserves continuity");
}

void testSegmentsFutureAdjacencyGapAndSerials() {
  FakeHostClock host;
  host.ticks.store(100, std::memory_order_relaxed);
  NativeMediaClock clock(host.seam(100));
  expect(clock.anchorAtHostTicks(3, 200, 20.0, 1.0, true),
         "segment test establishes an exact future anchor");

  expect(clock.observeSegment(3, segment(1, 200, 300, 20.0, 22.0)) ==
             NativeMediaSegmentAdmission::Current,
         "the first finite output interval becomes current");
  host.ticks.store(250, std::memory_order_relaxed);
  expectNear(clock.sample().mediaSeconds, 21.0, 1e-12,
             "the current interval advances inside its endpoints");

  expect(clock.observeSegment(3, segment(2, 300, 350, 22.0, 23.0)) ==
             NativeMediaSegmentAdmission::Pending,
         "a future adjacent interval occupies the pending slot");
  auto beforeBoundary = clock.sample();
  expect(beforeBoundary.segmentSerial == 1 &&
             beforeBoundary.pendingSegment &&
             beforeBoundary.pendingSegmentSerial == 2,
         "publishing a future adjacent interval retains the current interval");
  expectNear(beforeBoundary.mediaSeconds, 21.0, 1e-12,
             "a future adjacent interval cannot jump media time early");

  host.ticks.store(300, std::memory_order_relaxed);
  auto atBoundary = clock.sample();
  expect(atBoundary.segmentSerial == 2 && atBoundary.mediaSeconds == 22.0,
         "the pending interval activates at its exact future boundary");
  host.ticks.store(325, std::memory_order_relaxed);
  expectNear(clock.sample().mediaSeconds, 22.5, 1e-12,
             "the activated interval advances normally");

  const auto activeCoalesce = clock.reserveSegment(
      3, segment(3, 350, 400, 23.0, 24.0,
                 NativeMediaSegmentContinuity::Continuous));
  expect(activeCoalesce.accepted() && activeCoalesce.requiresPcm() &&
             activeCoalesce.admission ==
                 NativeMediaSegmentAdmission::Pending &&
             clock.commitSegment(activeCoalesce),
         "an active interval queues its exact gapless successor");
  expectNear(clock.sample().mediaSeconds, 22.5, 1e-12,
             "queuing a gapless successor cannot regress current time");
  host.ticks.store(350, std::memory_order_relaxed);
  expect(clock.sample().mediaSeconds == 23.0,
         "a gapless successor activates at its exact shared boundary");

  host.ticks.store(400, std::memory_order_relaxed);
  expect(clock.observeSegment(3, segment(4, 500, 550, 24.0, 25.0)) ==
             NativeMediaSegmentAdmission::Pending,
         "a real future host gap consumes the sole pending slot");
  const NativeMediaSegmentReservation blocked = clock.reserveSegment(
      3, segment(5, 600, 650, 25.0, 26.0));
  expect(!blocked.accepted() &&
             blocked.admission ==
                 NativeMediaSegmentAdmission::Backpressure,
         "a callback must consume no PCM while a post-gap interval is pending");

  const auto corrected = clock.reserveSegment(
      3, segment(5, 500, 560, 24.0, 25.0));
  expect(corrected.accepted() && !corrected.requiresPcm() &&
             corrected.admission == NativeMediaSegmentAdmission::Corrected &&
             clock.commitSegment(corrected),
         "a newer same-start observation corrects a provisional pending end");
  expect(clock.observeSegment(3, segment(4, 500, 570, 24.0, 25.4)) ==
             NativeMediaSegmentAdmission::Stale,
         "a delayed same-generation segment serial cannot regress the clock");
  expect(clock.observeSegment(3, segment(6, 500, 570, 24.0, 25.4)) ==
             NativeMediaSegmentAdmission::Invalid,
         "a correction cannot rewrite the consumed media endpoint");
  host.ticks.store(499, std::memory_order_relaxed);
  expect(clock.sample().mediaSeconds == 24.0,
         "media time holds across an output-time gap");
  const auto nonCollinear = clock.reserveSegment(
      3, segment(6, 560, 600, 25.0, 26.0,
                 NativeMediaSegmentContinuity::Continuous));
  expect(!nonCollinear.accepted() &&
             nonCollinear.admission == NativeMediaSegmentAdmission::Invalid,
         "future spans with different slopes cannot coalesce");
  expect(clock.sample().mediaSeconds == 24.0,
         "rejected non-collinear coalescing preserves the exact boundary");
  host.ticks.store(500, std::memory_order_relaxed);
  expect(clock.sample().mediaSeconds == 24.0,
         "a post-gap interval begins at its exact media boundary");
  host.ticks.store(560, std::memory_order_relaxed);
  const auto next = clock.reserveSegment(
      3, segment(6, 560, 600, 25.0, 26.0,
                 NativeMediaSegmentContinuity::Continuous));
  expect(next.accepted() && next.requiresPcm() &&
             next.admission == NativeMediaSegmentAdmission::Pending &&
             clock.commitSegment(next),
         "once current, a non-collinear span queues as an exact successor");
  expect(clock.sample().mediaSeconds == 25.0,
         "the exact successor begins without a boundary error");

  host.ticks.store(900, std::memory_order_relaxed);
  expect(clock.sample().mediaSeconds == 26.0,
         "a finite final interval clamps through underrun and EOF silence");
  expect(clock.pause(3),
         "the exact final partial interval can pause after its end");
  expect(clock.sample().mediaSeconds == 26.0,
         "pause fixes the exact final media endpoint");
}

void testFuturePendingCollinearCoalescing() {
  FakeHostClock host;
  host.ticks.store(100, std::memory_order_relaxed);
  NativeMediaClock clock(host.seam(100));
  expect(clock.anchorAtHostTicks(1, 100, 0.0, 1.0, true) &&
             clock.observeSegment(1, segment(1, 100, 200, 0.0, 1.0)) ==
                 NativeMediaSegmentAdmission::Current,
         "pending coalesce test establishes its current interval");
  host.ticks.store(150, std::memory_order_relaxed);
  const auto pending = clock.reserveSegment(
      1, segment(2, 200, 300, 1.0, 2.0,
                 NativeMediaSegmentContinuity::Continuous));
  expect(pending.accepted() && pending.requiresPcm() &&
             pending.admission == NativeMediaSegmentAdmission::Pending &&
             clock.commitSegment(pending),
         "active playback queues one future gapless interval");

  const auto coalesced = clock.reserveSegment(
      1, segment(3, 300, 400, 2.0, 3.0,
                 NativeMediaSegmentContinuity::Continuous));
  expect(coalesced.accepted() && coalesced.requiresPcm() &&
             coalesced.admission ==
                 NativeMediaSegmentAdmission::Coalesced &&
             clock.commitSegment(coalesced),
         "a collinear future interval coalesces into pending capacity");
  expect(clock.sample().mediaSeconds == 0.5,
         "future pending coalescence cannot advance current media time");
  host.ticks.store(200, std::memory_order_relaxed);
  const auto boundary = clock.sample();
  expect(boundary.segmentSerial == 3 && boundary.mediaSeconds == 1.0 &&
             boundary.segmentEndHostTicks == 400 &&
             boundary.segmentEndMediaSeconds == 3.0,
         "coalesced pending playback activates at its exact boundary");
}

void testTransactionalReservation() {
  FakeHostClock host;
  host.ticks.store(10, std::memory_order_relaxed);
  NativeMediaClock clock(host.seam(10));
  expect(clock.anchorAtHostTicks(1, 10, 1.0, 1.0, true),
         "reservation test establishes a running clock");

  const NativeMediaSegmentReservation first =
      clock.reserveSegment(1, segment(1, 10, 20, 1.0, 2.0));
  expect(first.accepted() && first.requiresPcm() &&
             first.admission == NativeMediaSegmentAdmission::Current,
         "preflight reserves fixed publication capacity before PCM consume");
  expect(!clock.pause(1),
         "an overlapping writer fails immediately while a reservation is held");
  expect(clock.sample().latestSegmentSerial == 0,
         "reserved segment state is invisible before commit");
  expect(clock.cancelSegment(first),
         "a callback can cancel a reservation without publishing PCM time");
  expect(clock.sample().latestSegmentSerial == 0,
         "cancellation leaves the published clock unchanged");

  const NativeMediaSegmentReservation second =
      clock.reserveSegment(1, segment(1, 10, 20, 1.0, 2.0));
  expect(second.accepted() && clock.commitSegment(second),
         "a successfully consumed interval commits its reservation once");
  expect(!clock.commitSegment(second) && !clock.cancelSegment(second),
         "stale reservation copies cannot replay or cancel publication");
  expect(clock.sample().latestSegmentSerial == 1,
         "commit publishes the exact reserved segment serial");

  const auto stale = clock.reserveSegment(
      2, segment(2, 20, 30, 2.0, 3.0,
                 NativeMediaSegmentContinuity::Continuous));
  expect(!stale.accepted() &&
             stale.admission == NativeMediaSegmentAdmission::Stale,
         "preflight rejects a stale clock generation before PCM consume");
}

void testReservationTokenSaturation() {
  FakeHostClock host;
  host.ticks.store(0, std::memory_order_relaxed);
  NativeMediaClock clock(host.seam(10));
  expect(clock.anchorAtHostTicks(1, 100, 0.0, 1.0, true),
         "token saturation test establishes a future clock");

  NativeMediaSegmentReservation ancient;
  for (std::uint64_t serial = 1; serial <= 64; ++serial) {
    const auto reserved = clock.reserveSegment(
        1, segment(serial, 100, 200, 0.0, 1.0));
    expect(reserved.accepted() &&
               reserved.requiresPcm() == (serial == 1),
           "future interval and corrections reserve exact consumption intent");
    if (serial == 1) {
      ancient = reserved;
    }
    expect(clock.commitSegment(reserved),
           "future correction commit advances its unique token");
  }
  const auto saturated =
      clock.reserveSegment(1, segment(65, 100, 200, 0.0, 1.0));
  expect(!saturated.accepted() &&
             saturated.admission ==
                 NativeMediaSegmentAdmission::Backpressure,
         "reservation tokens saturate instead of wrapping");
  expect(!clock.commitSegment(ancient) && !clock.cancelSegment(ancient),
         "an ancient reservation cannot match after token saturation");
}

void testActiveIntervalRewriteRejection() {
  FakeHostClock host;
  host.ticks.store(0, std::memory_order_relaxed);
  NativeMediaClock clock(host.seam(10));
  expect(clock.anchorAtHostTicks(1, 0, 0.0, 1.0, true),
         "active rewrite test establishes its clock");
  expect(clock.observeSegment(1, segment(1, 0, 100, 0.0, 10.0)) ==
             NativeMediaSegmentAdmission::Current,
         "active rewrite test publishes its first interval");
  host.ticks.store(50, std::memory_order_relaxed);
  expect(clock.sample().mediaSeconds == 5.0,
         "active rewrite test reaches its midpoint");

  const auto correction =
      clock.reserveSegment(1, segment(2, 0, 200, 0.0, 10.0));
  expect(!correction.accepted() &&
             correction.admission == NativeMediaSegmentAdmission::Invalid,
         "a same-start correction cannot slow an interval after it starts");
  expect(clock.sample().mediaSeconds == 5.0,
         "a rejected active correction cannot regress media time");

  const auto coalesced = clock.reserveSegment(
      1, segment(2, 100, 300, 10.0, 20.0,
                 NativeMediaSegmentContinuity::Continuous));
  expect(coalesced.accepted() && coalesced.requiresPcm() &&
             coalesced.admission == NativeMediaSegmentAdmission::Pending &&
             clock.commitSegment(coalesced),
         "an active continuous callback queues without rewriting current");
  expect(clock.sample().mediaSeconds == 5.0,
         "an active queued successor preserves the current time");
}

struct RacingHostClock {
  enum class Action : std::uint8_t {
    None,
    PauseOnce,
    AdvanceEveryRead,
  };

  std::atomic<std::uint64_t> ticks{0};
  std::atomic<std::uint64_t> reads{0};
  std::atomic<Action> action{Action::None};
  NativeMediaClock *clock{nullptr};
  std::uint64_t generation{1};

  static std::uint64_t read(void *context) noexcept {
    auto &host = *static_cast<RacingHostClock *>(context);
    host.reads.fetch_add(1, std::memory_order_relaxed);
    const std::uint64_t now = host.ticks.load(std::memory_order_relaxed);
    const Action selected = host.action.load(std::memory_order_relaxed);
    if (selected == Action::PauseOnce) {
      host.action.store(Action::None, std::memory_order_relaxed);
      static_cast<void>(host.clock->pause(host.generation));
    } else if (selected == Action::AdvanceEveryRead) {
      ++host.generation;
      static_cast<void>(host.clock->anchorAtHostTicks(
          host.generation, 0, static_cast<double>(host.generation * 10U),
          1.0, true));
    }
    return now;
  }

  [[nodiscard]] NativeMediaHostClock seam() noexcept {
    return {&read, this, 100};
  }
};

void testCoherentHostReadAndBoundedProgress() {
  RacingHostClock host;
  NativeMediaClock clock(host.seam());
  host.clock = &clock;
  expect(clock.anchorAtHostTicks(1, 0, 0.0, 1.0, true),
         "race test establishes an exact running clock");
  host.ticks.store(100, std::memory_order_relaxed);
  host.action.store(RacingHostClock::Action::PauseOnce,
                    std::memory_order_relaxed);
  const auto racedPause = clock.sample();
  expect(racedPause.publicationCurrent && racedPause.valid &&
             !racedPause.running && racedPause.generation == 1 &&
             racedPause.mediaSeconds == 1.0,
         "sample retries when pause publishes during its host-time read");

  expect(clock.runAtHostTicks(1, 0, 1.0),
         "bounded-progress test resumes its running generation");
  host.reads.store(0, std::memory_order_relaxed);
  host.action.store(RacingHostClock::Action::AdvanceEveryRead,
                    std::memory_order_relaxed);
  const auto churned = clock.sample();
  host.action.store(RacingHostClock::Action::None,
                    std::memory_order_relaxed);
  expect(host.reads.load(std::memory_order_relaxed) == 4,
         "sample performs exactly four bounded attempts under writer churn");
  expect(!churned.publicationCurrent && churned.valid &&
             churned.mediaSeconds ==
                 static_cast<double>(churned.generation * 10U),
         "bounded churn returns a coherent conservative publication fallback");
  const auto settled = clock.sample();
  expect(settled.publicationCurrent &&
             settled.generation == host.generation,
         "sampling recovers the exact latest publication after churn settles");
}

void testInvalidInputsAndOverflow() {
  FakeHostClock host;
  NativeMediaClock clock(host.seam(1));
  const double infinity = std::numeric_limits<double>::infinity();
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const std::uint64_t maximum =
      std::numeric_limits<std::uint64_t>::max();

  expect(!clock.anchor(0, 0.0, 1.0, false) &&
             !clock.anchor(maximum, 0.0, 1.0, false) &&
             !clock.anchor(1, -1.0, 1.0, false) &&
             !clock.anchor(1, nan, 1.0, false) &&
             !clock.anchor(1, infinity, 1.0, false) &&
             !clock.anchor(1, 0.0, 0.0, false) &&
             !clock.anchor(1, 0.0, nan, false),
         "anchors reject reserved generations and invalid transport values");
  expect(clock.anchorAtHostTicks(1, 0,
                                 std::numeric_limits<double>::max() / 2.0,
                                 std::numeric_limits<double>::max(), true),
         "finite extreme clock inputs remain valid");
  host.ticks.store(maximum, std::memory_order_relaxed);
  const auto saturated = clock.sample();
  expect(saturated.mediaSeconds == std::numeric_limits<double>::max() &&
             std::isfinite(saturated.mediaSeconds),
         "unbounded evaluation saturates rather than overflowing");

  expect(clock.observeSegment(1, segment(1, 10, 10, 1.0, 2.0)) ==
             NativeMediaSegmentAdmission::Invalid &&
             clock.observeSegment(1, segment(1, 20, 10, 1.0, 2.0)) ==
                 NativeMediaSegmentAdmission::Invalid &&
             clock.observeSegment(1, segment(1, 10, 20, 2.0, 1.0)) ==
                 NativeMediaSegmentAdmission::Invalid &&
             clock.observeSegment(1, segment(1, 10, 20, nan, 2.0)) ==
                 NativeMediaSegmentAdmission::Invalid,
         "segments reject reversed, stationary, and non-finite bounds");

  FakeHostClock derivedHost;
  NativeMediaClock derived(derivedHost.seam(maximum));
  expect(derived.anchorAtHostTicks(1, 0, 0.0, 1.0, true),
         "derived-rate overflow test establishes a clock");
  expect(derived.observeSegment(
             1, segment(1, 0, 1, 0.0,
                        std::numeric_limits<double>::max())) ==
             NativeMediaSegmentAdmission::Invalid,
         "a segment rejects an endpoint-derived infinite rate");

  FakeHostClock generationHost;
  NativeMediaClock terminal(generationHost.seam(1));
  expect(terminal.anchor(maximum - 1U, 0.0, 1.0, false) &&
             terminal.stop(maximum - 1U, maximum) &&
             !terminal.anchor(maximum, 0.0, 1.0, false),
         "UINT64_MAX remains a non-wrapping terminal invalidation tag");
}

void testConcurrentReaderConsistency() {
  FakeHostClock host;
  host.ticks.store(1234, std::memory_order_relaxed);
  NativeMediaClock clock(host.seam(1000));
  auto mediaFor = [](std::uint64_t generation) {
    return static_cast<double>(generation * 4U);
  };
  auto rateFor = [](std::uint64_t generation) {
    return static_cast<double>((generation % 7U) + 1U);
  };
  auto runningFor = [](std::uint64_t generation) {
    return (generation & 1U) != 0;
  };
  expect(clock.anchorAtHostTicks(1, 1234, mediaFor(1), rateFor(1),
                                 runningFor(1)),
         "concurrency test establishes its first publication");

  constexpr std::uint64_t kLastGeneration = 20000;
  constexpr int kReaderCount = 2;
  std::atomic<bool> start{false};
  std::atomic<bool> done{false};
  std::atomic<bool> consistent{true};
  std::vector<std::thread> readers;
  readers.reserve(kReaderCount);
  for (int index = 0; index < kReaderCount; ++index) {
    readers.emplace_back([&] {
      while (!start.load(std::memory_order_acquire)) {
      }
      std::uint64_t inspections = 0;
      do {
        const auto snapshot = clock.sample();
        if (snapshot.valid &&
            (snapshot.generation == 0 ||
             snapshot.anchorHostTicks != 1234 ||
             snapshot.sampledHostTicks != 1234 ||
             snapshot.anchorMediaSeconds != mediaFor(snapshot.generation) ||
             snapshot.mediaSeconds != mediaFor(snapshot.generation) ||
             snapshot.rate != rateFor(snapshot.generation) ||
             snapshot.running != runningFor(snapshot.generation))) {
          consistent.store(false, std::memory_order_relaxed);
        }
        ++inspections;
      } while (!done.load(std::memory_order_acquire) || inspections < 1000);
    });
  }

  start.store(true, std::memory_order_release);
  bool publishedEveryGeneration = true;
  for (std::uint64_t generation = 2; generation <= kLastGeneration;
       ++generation) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!clock.anchorAtHostTicks(generation, 1234, mediaFor(generation),
                                    rateFor(generation),
                                    runningFor(generation))) {
      if (std::chrono::steady_clock::now() >= deadline) {
        publishedEveryGeneration = false;
        break;
      }
      std::this_thread::yield();
    }
    if (!publishedEveryGeneration) {
      break;
    }
  }
  done.store(true, std::memory_order_release);
  for (auto &reader : readers) {
    reader.join();
  }

  expect(publishedEveryGeneration,
         "the single writer publishes every increasing generation within "
         "bounded reader backpressure");
  expect(consistent.load(std::memory_order_relaxed),
         "concurrent readers observe only coherent immutable slot states");
  expect(clock.sample().generation == kLastGeneration,
         "the final concurrent generation remains published");
}

} // namespace

int main() {
  static_assert(noexcept(
      std::declval<const NativeMediaClock &>().ticksPerSecond()));
  testConfigurationPausedAndInvalidation();
  testRunningRatesAndExactFutureResume();
  testSegmentsFutureAdjacencyGapAndSerials();
  testFuturePendingCollinearCoalescing();
  testTransactionalReservation();
  testReservationTokenSaturation();
  testActiveIntervalRewriteRejection();
  testCoherentHostReadAndBoundedProgress();
  testInvalidInputsAndOverflow();
  testConcurrentReaderConsistency();
  if (failures == 0) {
    std::cout << "native media clock tests passed\n";
  }
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
