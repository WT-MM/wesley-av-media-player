#include "platform/macos/native_audio_render_core.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <new>
#include <span>
#include <type_traits>
#include <utility>

namespace {

std::atomic<bool> gTrackAllocations{false};
std::atomic<std::uint64_t> gAllocations{0};

void noteAllocation() noexcept {
  if (gTrackAllocations.load(std::memory_order_relaxed)) {
    gAllocations.fetch_add(1, std::memory_order_relaxed);
  }
}

} // namespace

void *operator new(std::size_t size) {
  noteAllocation();
  if (void *memory = std::malloc(size == 0 ? 1 : size)) {
    return memory;
  }
  throw std::bad_alloc();
}

void *operator new[](std::size_t size) { return ::operator new(size); }

void operator delete(void *memory) noexcept { std::free(memory); }
void operator delete[](void *memory) noexcept { std::free(memory); }
void operator delete(void *memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void *memory, std::size_t) noexcept {
  std::free(memory);
}

namespace wam::macos {

struct NativeAudioRenderCoreTestAccess {
  static void setAfterPreflightHook(NativeAudioRenderCore &core,
                                    NativeAudioRenderCore::TestHook hook,
                                    void *context) noexcept {
    core.after_preflight_hook_ = hook;
    core.after_preflight_context_ = context;
  }

  static void failNextCommit(NativeAudioRenderCore &core) noexcept {
    core.fail_next_commit_ = true;
  }

  static void forceCallbackState(NativeAudioRenderCore &core,
                                 std::uint64_t cursor,
                                 std::uint64_t segmentSerial,
                                 bool running) noexcept {
    core.cursor_frame_ = cursor;
    core.prior_end_frame_ = cursor;
    core.segment_serial_ = segmentSerial;
    core.running_ = running;
  }
};

} // namespace wam::macos

namespace {

using wam::macos::NativeAudioRenderCore;
using wam::macos::NativeAudioRenderCoreTestAccess;
using wam::macos::NativeAudioRenderFailure;
using wam::macos::NativeAudioRenderInput;
using wam::macos::NativeAudioRenderResult;
using wam::macos::NativeAudioRenderStats;
using wam::macos::NativeAudioTerminalObservation;
using wam::macos::NativeMediaClock;
using wam::macos::NativeMediaClockSnapshot;
using wam::macos::NativeMediaHostClock;
using wam::macos::NativeMediaSegment;
using wam::macos::NativeMediaSegmentAdmission;
using wam::macos::NativeMediaSegmentContinuity;
using wam::macos::NativePcmRing;
using wam::media::MediaTime;

static_assert(std::is_trivially_copyable_v<NativeAudioRenderInput>);
static_assert(std::is_trivially_copyable_v<NativeAudioRenderResult>);
static_assert(std::is_trivially_copyable_v<NativeAudioRenderStats>);
static_assert(std::is_trivially_copyable_v<NativeAudioTerminalObservation>);
static_assert(noexcept(std::declval<NativeAudioRenderCore &>().render(
    NativeAudioRenderInput{}, std::span<float>{})));
static_assert(noexcept(
    std::declval<const NativeAudioRenderCore &>().visibleClock()));
static_assert(noexcept(
    std::declval<const NativeAudioRenderCore &>().terminalObservation()));
static_assert(noexcept(
    std::declval<const NativeAudioRenderCore &>()
        .compatibleHostTicksPerSecond(std::uint64_t{})));
static_assert(noexcept(
    std::declval<NativeAudioRenderCore &>().settlePausedAfterStop(1)));

constexpr std::uint32_t kSampleRate = 48000;
int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

void expectNear(float actual, float expected, float tolerance,
                const char *message) {
  expect(std::abs(actual - expected) <= tolerance, message);
}

template <typename Range>
[[nodiscard]] bool allEqual(const Range &values, float expected) {
  return std::all_of(values.begin(), values.end(),
                     [expected](float value) { return value == expected; });
}

struct FakeHostClock {
  std::atomic<std::uint64_t> ticks{0};

  static std::uint64_t read(void *context) noexcept {
    return static_cast<FakeHostClock *>(context)->ticks.load(
        std::memory_order_relaxed);
  }

  [[nodiscard]] NativeMediaHostClock seam(
      std::uint64_t ticksPerSecond = kSampleRate) noexcept {
    return {&read, this, ticksPerSecond};
  }
};

struct Fixture {
  FakeHostClock host;
  NativePcmRing ring{1};
  NativeMediaClock clock{host.seam()};
  NativeAudioRenderCore core{ring, clock, kSampleRate};
  bool ready{false};

  explicit Fixture(MediaTime origin = {0, 1},
                   std::uint64_t streamFrameCursor = 0,
                   MediaTime pausedClockPosition = {0, 1}) {
    const auto initialPosition =
        mediaTimeSecondsAtFrame(origin, streamFrameCursor, kSampleRate);
    ready = initialPosition &&
            clock.anchorAtHostTicks(1, 0, *initialPosition, 1.0, false) &&
            core.activate(1, streamFrameCursor, origin,
                          pausedClockPosition, kSampleRate);
    core.setPaused(false);
    core.setAccepting(true);
  }
};

[[nodiscard]] NativeAudioRenderInput hostInput(
    std::uint64_t streamFrameStart, std::uint32_t frameCount,
    std::uint64_t firstHostTicks, std::uint64_t generation = 1) noexcept {
  NativeAudioRenderInput input;
  input.generation = generation;
  input.streamFrameStart = streamFrameStart;
  input.firstHostTicks = firstHostTicks;
  input.endHostTicks = firstHostTicks + frameCount;
  input.hostTickNumeratorPerFrame = 1;
  input.hostTickDenominator = 1;
  input.hostTickRemainderAtStart = 0;
  input.sampleRate = kSampleRate;
  input.frameCount = frameCount;
  input.timing = NativeAudioRenderInput::Timing::HostTicks;
  return input;
}

[[nodiscard]] NativeAudioRenderInput sampleInput(
    std::uint64_t streamFrameStart, std::uint32_t frameCount,
    std::uint64_t firstHostTicks, std::uint64_t endHostTicks,
    std::int64_t firstSampleTime, std::uint64_t generation = 1) noexcept {
  NativeAudioRenderInput input;
  input.generation = generation;
  input.streamFrameStart = streamFrameStart;
  input.firstHostTicks = firstHostTicks;
  input.endHostTicks = endHostTicks;
  input.hostTickNumeratorPerFrame =
      static_cast<__uint128_t>(endHostTicks - firstHostTicks);
  input.hostTickDenominator = frameCount;
  input.hostTickRemainderAtStart = 0;
  input.firstSampleTime = firstSampleTime;
  input.endSampleTime =
      firstSampleTime + static_cast<std::int64_t>(frameCount);
  input.sampleRate = kSampleRate;
  input.frameCount = frameCount;
  input.timing = NativeAudioRenderInput::Timing::SampleTime;
  return input;
}

[[nodiscard]] bool publishConstant(NativePcmRing &ring,
                                   std::uint64_t generation,
                                   std::size_t frameCount,
                                   float value) noexcept {
  std::array<float, NativePcmRing::kSamplesPerSlab> samples{};
  std::fill_n(samples.begin(), frameCount * NativePcmRing::kChannels,
              value);
  return ring.publish(
             generation,
             std::span<const float>(samples).first(
                 frameCount * NativePcmRing::kChannels),
             frameCount) == NativePcmRing::PublishResult::Published;
}

template <std::size_t Samples>
NativeAudioRenderResult renderTracked(
    NativeAudioRenderCore &core, NativeAudioRenderInput input,
    std::array<float, Samples> &output) {
  const std::uint64_t before =
      gAllocations.load(std::memory_order_relaxed);
  gTrackAllocations.store(true, std::memory_order_release);
  const NativeAudioRenderResult result = core.render(input, output);
  gTrackAllocations.store(false, std::memory_order_release);
  expect(gAllocations.load(std::memory_order_relaxed) == before,
         "render performs no dynamic allocation");
  return result;
}

struct AppendHookContext {
  NativePcmRing *ring{nullptr};
  bool appended{false};

  static void run(void *opaque) noexcept {
    auto &context = *static_cast<AppendHookContext *>(opaque);
    context.appended = publishConstant(*context.ring, 1, 32, 2.0F);
  }
};

void testPreflightLowerBoundAndProducerAppend() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 64, 1.0F),
         "append fixture establishes paused clock and PCM prefix");
  AppendHookContext hook{&fixture.ring};
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      fixture.core, &AppendHookContext::run, &hook);

  std::array<float, 192> output{};
  output.fill(9.0F);
  const auto result =
      renderTracked(fixture.core, hostInput(0, 96, 0), output);
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(fixture.core,
                                                         nullptr, nullptr);

  expect(hook.appended && result.committed && result.pcmFrames == 64 &&
             result.silentFrames == 32 &&
             result.bufferedPcmFramesKnown &&
             result.bufferedPcmFramesAfter == 0 && !result.continuous &&
             result.admission == NativeMediaSegmentAdmission::Current,
         "producer append cannot enlarge the exact preflight lower bound");
  expect(fixture.ring.readableFrames(1).frames == 32,
         "PCM appended after preflight remains queued for a later callback");
  expect(output[0] == 1.0F / 128.0F && output[126] == 0.5F &&
             allEqual(std::span<const float>(output).subspan(128), 0.0F),
         "render ramps the prefix and zeros its underrun tail externally");
}

void testRingAndClockBackpressureDoNotConsume() {
  Fixture empty;
  expect(empty.ready, "empty backpressure fixture activates");
  std::array<float, 32> emptyOutput{};
  const auto beforeEmpty = empty.ring.stats();
  const auto emptyResult =
      renderTracked(empty.core, hostInput(0, 16, 0), emptyOutput);
  const auto afterEmpty = empty.ring.stats();
  expect(emptyResult.pcmFrames == 0 && emptyResult.silentFrames == 16 &&
             emptyResult.bufferedPcmFramesKnown &&
             emptyResult.bufferedPcmFramesAfter == 0 &&
             emptyResult.admission ==
                 NativeMediaSegmentAdmission::Backpressure &&
             beforeEmpty.consumedFrames == afterEmpty.consumedFrames,
         "empty-ring backpressure renders silence without a consume");

  Fixture blocked;
  expect(blocked.ready &&
             blocked.clock.runAtHostTicks(1, 0, 1.0) &&
             blocked.clock.observeSegment(
                 1, {1, 0, 64, 0.0, 64.0 / kSampleRate,
                     NativeMediaSegmentContinuity::Discontinuous}) ==
                 NativeMediaSegmentAdmission::Current &&
             blocked.clock.observeSegment(
                 1, {2, 128, 192, 64.0 / kSampleRate,
                     128.0 / kSampleRate,
                     NativeMediaSegmentContinuity::Discontinuous}) ==
                 NativeMediaSegmentAdmission::Pending &&
             publishConstant(blocked.ring, 1, 32, 1.0F),
         "clock-backpressure fixture occupies its pending segment");
  NativeAudioRenderCoreTestAccess::forceCallbackState(blocked.core, 64, 2,
                                                       true);
  const auto beforeBlocked = blocked.ring.stats();
  std::array<float, 64> blockedOutput{};
  const auto blockedResult =
      renderTracked(blocked.core, hostInput(64, 32, 256), blockedOutput);
  const auto afterBlocked = blocked.ring.stats();
  expect(!blockedResult.committed &&
             blockedResult.admission ==
                 NativeMediaSegmentAdmission::Backpressure &&
             blockedResult.silentFrames == 32 &&
             blockedResult.bufferedPcmFramesKnown &&
             blockedResult.bufferedPcmFramesAfter == 32 &&
             beforeBlocked.consumedFrames == afterBlocked.consumedFrames &&
             blocked.ring.readableFrames(1).frames == 32,
         "clock capacity rejection happens before destructive PCM consume");
}

void testMetadataCorrectionConsumesNothing() {
  Fixture fixture;
  constexpr double endSeconds = 64.0 / kSampleRate;
  expect(fixture.ready &&
             fixture.clock.runAtHostTicks(1, 1000, 1.0) &&
             fixture.clock.observeSegment(
                 1, {1, 1000, 1064, 0.0, endSeconds,
                     NativeMediaSegmentContinuity::Discontinuous}) ==
                 NativeMediaSegmentAdmission::Current &&
             publishConstant(fixture.ring, 1, 64, 1.0F),
         "metadata-correction fixture publishes a provisional interval");
  NativeAudioRenderCoreTestAccess::forceCallbackState(fixture.core, 0, 1,
                                                       true);
  const auto before = fixture.ring.stats();
  std::array<float, 128> output{};
  output.fill(3.0F);
  const auto result =
      renderTracked(fixture.core, hostInput(0, 64, 1000), output);
  const auto after = fixture.ring.stats();
  expect(result.committed && !result.continuous && result.pcmFrames == 0 &&
             result.silentFrames == 64 &&
             result.admission == NativeMediaSegmentAdmission::Corrected &&
             before.consumedFrames == after.consumedFrames &&
             fixture.ring.readableFrames(1).frames == 64 &&
             allEqual(output, 0.0F),
         "metadata-only correction commits without replaying PCM");
}

void testCommitFailureZerosAndHidesSpeculativeRun() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 32, 1.0F),
         "commit-failure fixture activates with PCM");
  const NativeMediaClockSnapshot paused = fixture.core.visibleClock();
  NativeAudioRenderCoreTestAccess::failNextCommit(fixture.core);
  std::array<float, 64> output{};
  output.fill(7.0F);
  const auto result =
      renderTracked(fixture.core, hostInput(0, 32, 100), output);
  const NativeMediaClockSnapshot visible = fixture.core.visibleClock();
  expect(!result.committed && result.pcmFrames == 0 &&
             result.silentFrames == 32 &&
             result.failure == NativeAudioRenderFailure::ClockCommitFailed &&
             fixture.core.failure() ==
                 NativeAudioRenderFailure::ClockCommitFailed &&
             allEqual(output, 0.0F),
         "post-consume commit failure zeros output and latches fatal state");
  expect(paused.valid && !paused.running && visible.valid &&
             !visible.running && visible.generation == paused.generation &&
             visible.mediaSeconds == paused.mediaSeconds &&
             fixture.clock.sample().running,
         "visible clock stays at cached pause until a first segment commits");
}

void testExactContinuityAndUnderrunGap() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 64, 1.0F) &&
             publishConstant(fixture.ring, 1, 64, 1.0F) &&
             publishConstant(fixture.ring, 1, 32, 1.0F),
         "continuity fixture queues three PCM spans");
  std::array<float, 128> firstOutput{};
  const auto first =
      renderTracked(fixture.core, hostInput(0, 64, 0), firstOutput);
  fixture.host.ticks.store(64, std::memory_order_relaxed);
  std::array<float, 128> secondOutput{};
  const auto second =
      renderTracked(fixture.core, hostInput(64, 64, 64), secondOutput);
  fixture.host.ticks.store(128, std::memory_order_relaxed);
  std::array<float, 128> shortOutput{};
  const auto shortResult =
      renderTracked(fixture.core, hostInput(128, 64, 128), shortOutput);
  expect(first.committed && !first.continuous && second.committed &&
             second.continuous && shortResult.committed &&
             shortResult.continuous && shortResult.pcmFrames == 32 &&
             shortResult.silentFrames == 32,
         "only exact adjacent callbacks are continuous before an underrun");

  expect(publishConstant(fixture.ring, 1, 32, 1.0F),
         "post-underrun fixture queues replacement PCM");
  fixture.host.ticks.store(192, std::memory_order_relaxed);
  std::array<float, 64> afterGapOutput{};
  const auto afterGap =
      renderTracked(fixture.core, hostInput(160, 32, 192), afterGapOutput);
  expect(afterGap.committed && !afterGap.continuous,
         "underrun tail forces the next committed span discontinuous");
}

// A steady-state underrun is a producer that was late, not time standing
// still. The device consumed the interval, so the published clock must keep
// moving across it; freezing there is what let one late producer wake deadlock
// the whole pipeline. The frames the clock passed are then retired unplayed
// rather than being played behind their own timestamps -- but only once the
// debt reaches one producer admission unit, and only out of surplus, so a
// partially recovered producer still renders its short prefix.
void testUnderrunAdvancesClockAndRetiresLateFrames() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 64, 1.0F),
         "clock-resilience fixture queues one playable span");
  std::array<float, 128> firstOutput{};
  const auto first =
      renderTracked(fixture.core, hostInput(0, 64, 0), firstOutput);
  expect(first.committed && first.pcmFrames == 64 &&
             first.advancedSilentFrames == 0,
         "the first real segment commits before any resilience applies");
  const double afterFirst = fixture.core.visibleClock().mediaSeconds;

  // Ninety-six empty callbacks: 6144 frames, above one 4096-frame admission
  // unit, so the resync threshold is genuinely crossed.
  std::uint64_t cursor = 64;
  std::uint64_t advanced = 0;
  for (unsigned callback = 0; callback != 96; ++callback) {
    fixture.host.ticks.store(cursor, std::memory_order_relaxed);
    std::array<float, 128> emptyOutput{};
    emptyOutput.fill(3.0F);
    const auto starved = renderTracked(
        fixture.core, hostInput(cursor, 64, cursor), emptyOutput);
    if (starved.advancedSilentFrames != 64 || starved.silentFrames != 64 ||
        !allEqual(emptyOutput, 0.0F)) {
      expect(false,
             "every starved callback renders silence and publishes its "
             "elapsed device interval as media time");
      break;
    }
    advanced += starved.advancedSilentFrames;
    cursor += 64;
  }
  const double afterStarvation = fixture.core.visibleClock().mediaSeconds;
  expect(advanced == 6144 &&
             afterStarvation ==
                 afterFirst + 6144.0 / static_cast<double>(kSampleRate),
         "the published clock advances with the device through the underrun");

  const NativeAudioRenderStats starvedStats = fixture.core.stats();
  expect(starvedStats.clockAdvancedUnderruns == 96 &&
             starvedStats.retiredLateFrames == 0 &&
             starvedStats.failure == NativeAudioRenderFailure::None,
         "advancing through an underrun is not a failure and retires nothing "
         "while the ring is empty");

  // Partial recovery first: less PCM than this callback needs must still be
  // rendered rather than eaten by the outstanding debt.
  expect(publishConstant(fixture.ring, 1, 32, 1.0F),
         "producer partially recovers with a short span");
  fixture.host.ticks.store(cursor, std::memory_order_relaxed);
  std::array<float, 128> partialOutput{};
  const auto partial =
      renderTracked(fixture.core, hostInput(cursor, 64, cursor), partialOutput);
  expect(partial.pcmFrames == 32 && partial.silentFrames == 32 &&
             fixture.core.stats().retiredLateFrames == 0,
         "catch-up never starves the callback it is running inside");
  cursor += 32;

  // Full recovery: the debt is repaid out of surplus and the ring keeps only
  // what the clock has not already passed.
  expect(publishConstant(fixture.ring, 1, 4096, 1.0F) &&
             publishConstant(fixture.ring, 1, 4096, 1.0F),
         "producer fully recovers with two queued slabs");
  fixture.host.ticks.store(cursor, std::memory_order_relaxed);
  std::array<float, 128> recoveredOutput{};
  const auto recovered = renderTracked(
      fixture.core, hostInput(cursor, 64, cursor), recoveredOutput);
  const NativeAudioRenderStats recoveredStats = fixture.core.stats();
  expect(recovered.committed && recovered.pcmFrames == 64 &&
             recoveredStats.retiredLateFrames != 0 &&
             recoveredStats.retiredLateFrames <= 6144 &&
             recoveredStats.failure == NativeAudioRenderFailure::None,
         "a recovered producer repays the debt out of surplus and resumes "
         "playing in sync with the clock it could not hold");
}

struct ReentrantHookContext {
  NativeAudioRenderCore *core{nullptr};
  NativeAudioRenderInput input{};
  std::array<float, 16> output{};
  NativeAudioRenderResult result{};

  static void run(void *opaque) noexcept {
    auto &context = *static_cast<ReentrantHookContext *>(opaque);
    context.output.fill(5.0F);
    context.result = context.core->render(context.input, context.output);
  }
};

void testMalformedStaleAndReentrantCallbacks() {
  Fixture malformed;
  expect(malformed.ready, "malformed fixture activates");
  std::array<float, 3> malformedOutput{};
  malformedOutput.fill(4.0F);
  NativeAudioRenderInput invalid = hostInput(0, 2, 0);
  const std::uint64_t allocationBefore =
      gAllocations.load(std::memory_order_relaxed);
  gTrackAllocations.store(true, std::memory_order_release);
  const auto malformedResult = malformed.core.render(invalid, malformedOutput);
  gTrackAllocations.store(false, std::memory_order_release);
  expect(gAllocations.load(std::memory_order_relaxed) == allocationBefore &&
             malformedResult.failure ==
                 NativeAudioRenderFailure::InvalidInput &&
             allEqual(malformedOutput, 0.0F),
         "malformed stereo shape fails closed without allocation");

  Fixture stale;
  expect(stale.ready && publishConstant(stale.ring, 1, 8, 1.0F),
         "stale fixture activates with current PCM");
  const auto beforeStale = stale.ring.stats();
  std::array<float, 16> staleOutput{};
  const auto staleResult =
      renderTracked(stale.core, hostInput(0, 8, 0, 2), staleOutput);
  expect(staleResult.failure == NativeAudioRenderFailure::None &&
             staleResult.admission == NativeMediaSegmentAdmission::Stale &&
             stale.ring.stats().consumedFrames == beforeStale.consumedFrames,
         "stale generation renders silence without poisoning the active lane");

  Fixture reentrant;
  expect(reentrant.ready && publishConstant(reentrant.ring, 1, 8, 1.0F),
         "reentrant fixture activates with PCM");
  ReentrantHookContext hook;
  hook.core = &reentrant.core;
  hook.input = hostInput(0, 8, 0);
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(
      reentrant.core, &ReentrantHookContext::run, &hook);
  const auto beforeReentrant = reentrant.ring.stats();
  std::array<float, 16> outerOutput{};
  const auto outer =
      renderTracked(reentrant.core, hostInput(0, 8, 0), outerOutput);
  NativeAudioRenderCoreTestAccess::setAfterPreflightHook(reentrant.core,
                                                         nullptr, nullptr);
  expect(hook.result.failure ==
                 NativeAudioRenderFailure::ReentrantCallback &&
             outer.failure == NativeAudioRenderFailure::ReentrantCallback &&
             reentrant.core.failure() ==
                 NativeAudioRenderFailure::ReentrantCallback &&
             reentrant.ring.stats().consumedFrames ==
                 beforeReentrant.consumedFrames &&
             allEqual(hook.output, 0.0F) && allEqual(outerOutput, 0.0F),
         "reentrant callback is rejected before either path touches the ring");
}

void testGainMuteRamp() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 128, 1.0F),
         "gain fixture queues its fade-in span");
  std::array<float, 256> fadeIn{};
  const auto first =
      renderTracked(fixture.core, hostInput(0, 128, 0), fadeIn);
  expect(first.committed && first.pcmFrames == 128,
         "gain fixture commits its fade-in span");
  expectNear(fadeIn[0], 1.0F / 128.0F, 1e-6F,
             "gain ramp begins at one 128th");
  expectNear(fadeIn[254], 1.0F, 1e-6F,
             "gain ramp reaches unity on frame 128");

  fixture.core.setMuted(true);
  expect(publishConstant(fixture.ring, 1, 128, 1.0F),
         "mute fixture queues its fade-out span");
  fixture.host.ticks.store(128, std::memory_order_relaxed);
  std::array<float, 256> fadeOut{};
  const auto second =
      renderTracked(fixture.core, hostInput(128, 128, 128), fadeOut);
  expect(second.committed && second.continuous,
         "mute ramp remains on the exact continuous clock span");
  expectNear(fadeOut[0], 127.0F / 128.0F, 1e-6F,
             "mute ramp descends on its first frame");
  expectNear(fadeOut[254], 0.0F, 1e-6F,
             "mute ramp reaches exact silence on frame 128");
}

void testPauseBoundaryAndResume() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 32, 1.0F),
         "pause fixture queues its first span");
  std::array<float, 64> output{};
  expect(renderTracked(fixture.core, hostInput(0, 32, 0), output).committed,
         "pause fixture commits before pausing");
  expect(publishConstant(fixture.ring, 1, 32, 1.0F),
         "pause fixture retains PCM across pause callbacks");
  fixture.host.ticks.store(32, std::memory_order_relaxed);
  fixture.core.setPaused(true);
  const auto before = fixture.ring.stats();
  const auto firstPause =
      renderTracked(fixture.core, hostInput(32, 32, 32), output);
  const auto secondPause =
      renderTracked(fixture.core, hostInput(32, 32, 64), output);
  expect(firstPause.pauseBoundary && !secondPause.pauseBoundary &&
             fixture.ring.stats().consumedFrames == before.consumedFrames,
         "pause boundary is a one-shot fact and consumes no queued PCM");

  fixture.core.setPaused(false);
  fixture.host.ticks.store(96, std::memory_order_relaxed);
  const auto resumed =
      renderTracked(fixture.core, hostInput(32, 32, 96), output);
  expect(resumed.committed && !resumed.continuous,
         "resume starts a new exact discontinuous host segment");
}

void testQuiescentStopRetainsPcmAndRestartsClock() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 64, 1.0F),
         "stop settlement fixture queues retained PCM");
  std::array<float, 64> output{};
  expect(renderTracked(fixture.core, hostInput(0, 32, 0), output).committed &&
             publishConstant(fixture.ring, 1, 32, 1.0F),
         "stop settlement fixture commits before output stop");
  const auto before = fixture.ring.stats();
  fixture.core.setPaused(true);
  fixture.core.setAccepting(false);
  fixture.host.ticks.store(32, std::memory_order_relaxed);
  expect(fixture.clock.pause(1) &&
             fixture.core.settlePausedAfterStop(1) &&
             fixture.ring.stats().consumedFrames == before.consumedFrames,
         "quiescent stop settles callback-local run without consuming PCM");
  expect(!fixture.core.settlePausedAfterStop(2),
         "stop settlement rejects a stale generation");

  fixture.core.setPaused(false);
  fixture.core.setAccepting(true);
  fixture.host.ticks.store(96, std::memory_order_relaxed);
  const auto restarted =
      renderTracked(fixture.core, hostInput(32, 32, 96), output);
  expect(restarted.committed && !restarted.continuous &&
             fixture.clock.sample().running,
         "first callback after output restart establishes a fresh clock run");
}

void testTerminalFramePublishesEofOnce() {
  Fixture fixture;
  expect(fixture.ready &&
             !fixture.core.terminalObservation().observed() &&
             fixture.core.publishTerminalFrame(1, 16) &&
             !fixture.core.publishTerminalFrame(1, 17),
         "EOF fixture publishes one immutable exact terminal boundary");
  std::array<float, 32> output{};
  const auto underrun =
      renderTracked(fixture.core, hostInput(0, 16, 0), output);
  expect(underrun.admission == NativeMediaSegmentAdmission::Backpressure &&
             !underrun.endOfStream &&
             !fixture.core.terminalObservation().observed() &&
             publishConstant(fixture.ring, 1, 16, 1.0F),
         "ordinary zero-fill at a preterminal cursor cannot publish EOF");
  expect(renderTracked(fixture.core, hostInput(0, 16, 16), output).committed &&
             !fixture.core.terminalObservation().observed(),
         "the final playable interval commits before terminal observation");
  const auto before = fixture.ring.stats();
  const auto eof =
      renderTracked(fixture.core, hostInput(16, 16, 32), output);
  const NativeAudioTerminalObservation observed =
      fixture.core.terminalObservation();
  const auto duplicate =
      renderTracked(fixture.core, hostInput(16, 16, 48), output);
  expect(eof.endOfStream && observed.observed() &&
             observed.generation == 1 && !duplicate.endOfStream &&
             fixture.ring.stats().consumedFrames == before.consumedFrames &&
             fixture.core.stats().endOfStreamFacts == 1,
         "the first exact-boundary callback publishes one durable tagged EOF");
  fixture.core.clearTerminal(2);
  expect(fixture.core.terminalObservation().generation == 1,
         "a stale clear cannot erase the current generation's EOF fact");
  fixture.core.clearTerminal(1);
  expect(!fixture.core.terminalObservation().observed(),
         "a quiescent exact-generation clear resets terminal observation");

  Fixture overlap;
  expect(overlap.ready && publishConstant(overlap.ring, 1, 16, 1.0F) &&
             renderTracked(overlap.core, hostInput(0, 16, 100), output)
                 .committed &&
             overlap.core.publishTerminalFrame(1, 16),
         "terminal overlap fixture commits its exact final interval");
  const auto hostOverlap =
      renderTracked(overlap.core, hostInput(16, 16, 115), output);
  expect(!hostOverlap.endOfStream &&
             hostOverlap.admission == NativeMediaSegmentAdmission::Invalid &&
             !overlap.core.terminalObservation().observed(),
         "a host-time overlap at the terminal cursor cannot publish EOF");

  Fixture overshoot;
  expect(overshoot.ready && publishConstant(overshoot.ring, 1, 16, 1.0F) &&
             renderTracked(overshoot.core, hostInput(0, 16, 0), output)
                 .committed &&
             overshoot.core.publishTerminalFrame(1, 8),
         "terminal overshoot fixture exposes a producer boundary violation");
  const auto beyond =
      renderTracked(overshoot.core, hostInput(16, 16, 16), output);
  expect(!beyond.endOfStream &&
             beyond.failure == NativeAudioRenderFailure::InvalidInput &&
             !overshoot.core.terminalObservation().observed(),
         "a callback beyond the configured boundary fails closed, not as EOF");
}

void testTerminalObservationResetsAcrossActivation() {
  Fixture fixture;
  std::array<float, 2> output{};
  expect(fixture.ready && fixture.core.publishTerminalFrame(1, 0) &&
             renderTracked(fixture.core, hostInput(0, 1, 0), output)
                 .endOfStream &&
             fixture.core.terminalObservation().generation == 1,
         "an exact empty generation publishes a tagged terminal fact");

  fixture.core.setAccepting(false);
  fixture.core.setPaused(true);
  expect(fixture.ring.flush(2) && fixture.clock.seek(1, 2, 20.0) &&
             fixture.core.activate(2, 0, MediaTime{20, 1},
                                   MediaTime{20, 1}, kSampleRate) &&
             !fixture.core.terminalObservation().observed(),
         "quiescent activation resets the prior generation's terminal fact");
  fixture.core.setPaused(false);
  fixture.core.setAccepting(true);
  expect(fixture.core.publishTerminalFrame(2, 0) &&
             renderTracked(fixture.core, hostInput(0, 1, 100, 2), output)
                 .endOfStream &&
             fixture.core.terminalObservation().generation == 2,
         "the next generation independently publishes its terminal fact");
  fixture.core.clearTerminal(1);
  expect(fixture.core.terminalObservation().generation == 2,
         "a late prior-generation clear cannot erase a newer observation");
}

void testExactNonzeroMediaOrigin() {
  constexpr MediaTime origin{41, 4};
  constexpr std::uint64_t cursor = 12000;
  Fixture fixture(origin, cursor, MediaTime{21, 2});
  expect(fixture.ready && publishConstant(fixture.ring, 1, 48, 1.0F),
         "nonzero-origin fixture anchors frame cursor independently");
  std::array<float, 96> output{};
  const auto result = renderTracked(
      fixture.core, hostInput(cursor, 48, 100), output);
  const NativeMediaClockSnapshot clock = fixture.clock.sample();
  expect(result.committed && clock.anchorMediaSeconds == 10.5 &&
             std::abs(clock.segmentEndMediaSeconds - 10.501) < 1e-12,
         "clock interval is exact origin plus generation-local frame time");

  FakeHostClock mismatchedHost;
  NativePcmRing mismatchedRing(1);
  NativeMediaClock mismatchedClock(mismatchedHost.seam());
  NativeAudioRenderCore mismatchedCore(mismatchedRing, mismatchedClock,
                                       kSampleRate);
  expect(mismatchedClock.anchorAtHostTicks(1, 0, 10.25, 1.0, false) &&
             !mismatchedCore.activate(1, cursor, origin,
                                      MediaTime{21, 2}, kSampleRate),
         "activation rejects a paused clock that omits the frame cursor");

  constexpr MediaTime negativeOrigin{-1, 2};
  constexpr std::uint64_t zeroCursor = 24000;
  Fixture signedFixture(negativeOrigin, zeroCursor, MediaTime{0, 1});
  expect(signedFixture.ready &&
             publishConstant(signedFixture.ring, 1, 1, 1.0F),
         "checked rational arithmetic admits an origin offset to exact zero");
  std::array<float, 2> signedOutput{};
  const auto signedResult = renderTracked(
      signedFixture.core, hostInput(zeroCursor, 1, 0), signedOutput);
  expect(signedResult.committed &&
             signedFixture.clock.sample().anchorMediaSeconds == 0.0,
         "negative source origin remains separate from its playable cursor");

  constexpr MediaTime hugeOrigin{
      std::numeric_limits<std::int64_t>::max(), 1};
  Fixture collapsed(hugeOrigin, 0, hugeOrigin);
  expect(collapsed.ready && publishConstant(collapsed.ring, 1, 1, 1.0F),
         "large-origin fixture reaches render without integer overflow");
  const auto before = collapsed.ring.stats();
  std::array<float, 2> collapsedOutput{};
  const auto collapsedResult = renderTracked(
      collapsed.core, hostInput(0, 1, 0), collapsedOutput);
  expect(collapsedResult.failure == NativeAudioRenderFailure::InvalidInput &&
             collapsed.ring.stats().consumedFrames == before.consumedFrames,
         "a double-collapsed frame interval fails before destructive consume");
}

void testExactDualSeekOrigins() {
  constexpr MediaTime visualTarget{1, 7};
  constexpr MediaTime firstAudioFrame{1143, 8000};
  const auto targetSeconds = mediaTimeSeconds(visualTarget);
  const auto audioSeconds = mediaTimeSeconds(firstAudioFrame);
  FakeHostClock host;
  NativePcmRing ring(1);
  NativeMediaClock clock(host.seam());
  NativeAudioRenderCore core(ring, clock, kSampleRate);
  expect(targetSeconds && audioSeconds &&
             clock.anchorAtHostTicks(1, 0, *targetSeconds, 1.0, false) &&
             core.activate(1, 0, firstAudioFrame, visualTarget,
                           kSampleRate),
         "dual-origin activation keeps arbitrary visual T separate from "
         "ceil-grid source PCM A");
  const NativeMediaClockSnapshot before = core.visibleClock();
  expect(before.valid && !before.running &&
             before.mediaSeconds == *targetSeconds,
         "visible clock remains exact visual T before first audible PCM");

  core.setPaused(false);
  core.setAccepting(true);
  expect(publishConstant(ring, 1, 4, 1.0F),
         "dual-origin fixture queues retained source PCM");
  host.ticks.store(100, std::memory_order_relaxed);
  std::array<float, 8> output{};
  const NativeAudioRenderResult rendered =
      renderTracked(core, hostInput(0, 4, 100), output);
  const NativeMediaClockSnapshot after = core.visibleClock();
  expect(rendered.committed && !rendered.continuous && after.running &&
             after.segmentSerial == 1 &&
             after.anchorMediaSeconds == *audioSeconds &&
             after.mediaSeconds >= *audioSeconds,
         "first audible segment preserves source A and explicitly jumps "
         "from cached T without relabelling an earlier frame");

  FakeHostClock rejectedHost;
  NativePcmRing rejectedRing(1);
  NativeMediaClock rejectedClock(rejectedHost.seam());
  NativeAudioRenderCore rejectedCore(rejectedRing, rejectedClock,
                                     kSampleRate);
  expect(rejectedClock.anchorAtHostTicks(1, 0, *targetSeconds, 1.0, false) &&
             !rejectedCore.activate(1, 0, {6857, 48'000}, visualTarget,
                                    kSampleRate) &&
             !rejectedCore.activate(1, 0, {6859, 48'000}, visualTarget,
                                    kSampleRate),
         "dual-origin activation rejects both floor PCM before T and a "
         "source boundary later than ceil(T*R)");

  FakeHostClock emptyHost;
  NativePcmRing emptyRing(1);
  NativeMediaClock emptyClock(emptyHost.seam());
  NativeAudioRenderCore emptyCore(emptyRing, emptyClock, kSampleRate);
  expect(emptyClock.anchorAtHostTicks(1, 0, *targetSeconds, 1.0, false) &&
             emptyCore.activate(1, 0, firstAudioFrame, visualTarget,
                                kSampleRate) &&
             emptyCore.publishTerminalFrame(1, 0),
         "empty dual-origin generation activates and publishes frame-zero "
         "terminal fact");
  emptyCore.setPaused(false);
  emptyCore.setAccepting(true);
  std::array<float, 2> emptyOutput{};
  const NativeAudioRenderResult empty =
      renderTracked(emptyCore, hostInput(0, 1, 0), emptyOutput);
  const NativeMediaClockSnapshot emptyVisible = emptyCore.visibleClock();
  expect(empty.endOfStream && emptyVisible.valid && !emptyVisible.running &&
             emptyVisible.mediaSeconds == *targetSeconds,
         "empty EOS commits no PCM segment and leaves the exact T clock "
         "paused");
}

void testCanonicalOriginRoundingRegression() {
  constexpr MediaTime origin{189751, 52016};
  FakeHostClock host;
  NativePcmRing ring(1);
  NativeMediaClock clock(host.seam());
  NativeAudioRenderCore core(ring, clock, kSampleRate);
  const auto anchored = mediaTimeSecondsAtFrame(origin, 0, kSampleRate);
  expect(anchored.has_value() &&
             clock.anchorAtHostTicks(1, 0, *anchored, 1.0, false) &&
             core.activate(1, 0, origin, origin, kSampleRate),
         "activation and owner share canonical adjacent-double rounding");
}

void testHostFrequencyComposition() {
  Fixture fixture;
  expect(fixture.ready &&
             fixture.core.compatibleHostTicksPerSecond(kSampleRate) &&
             !fixture.core.compatibleHostTicksPerSecond(kSampleRate + 1U),
         "render core proves adapter, core, and clock host frequency identity");

  FakeHostClock host;
  NativePcmRing ring(1);
  NativeMediaClock mismatchedClock(host.seam(kSampleRate + 1U));
  NativeAudioRenderCore mismatchedCore(ring, mismatchedClock, kSampleRate);
  expect(mismatchedClock.anchorAtHostTicks(1, 0, 0.0, 1.0, false) &&
             !mismatchedCore.compatibleHostTicksPerSecond(kSampleRate) &&
             !mismatchedCore.activate(1, 0, MediaTime{0, 1},
                                      MediaTime{0, 1}, kSampleRate),
         "core activation fails closed when its clock seam frequency differs");
}

void testExactPartialHostPrefix() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 3, 1.0F),
         "fractional-prefix fixture queues only its playable prefix");
  NativeAudioRenderInput input = hostInput(0, 4, 1000);
  input.hostTickNumeratorPerFrame = 1000000000;
  input.hostTickDenominator = 48000;
  input.hostTickRemainderAtStart = 0;
  input.endHostTicks = 84333;
  std::array<float, 8> output{};
  const auto result = renderTracked(fixture.core, input, output);
  expect(result.committed && result.pcmFrames == 3 &&
             result.silentFrames == 1 &&
             fixture.clock.sample().segmentEndHostTicks == 63500,
         "three-frame prefix uses floor(P*3/D), not a scaled full endpoint");

  Fixture carried;
  expect(carried.ready && publishConstant(carried.ring, 1, 2, 1.0F),
         "carried-prefix fixture queues its playable prefix");
  NativeAudioRenderInput carriedInput = input;
  carriedInput.hostTickRemainderAtStart = 16000;
  carriedInput.endHostTicks = 84333;
  const auto carriedResult =
      renderTracked(carried.core, carriedInput, output);
  expect(carriedResult.committed &&
             carried.clock.sample().segmentEndHostTicks == 42667,
         "callback-start rational carry participates in the prefix endpoint");

  Fixture exactScalar;
  expect(exactScalar.ready &&
             publishConstant(exactScalar.ring, 1, 16, 1.0F),
         "exact IEEE-scalar fixture queues its partial prefix");
  NativeAudioRenderInput scalarInput = hostInput(0, 17, 2000);
  // Exact binary64 decomposition of 1.000011 is
  // 4503649166966397 * 2^-52. The adapter folds that rational into
  // hostTicksPerSecond/sampleRate without Q32 quantization.
  scalarInput.hostTickNumeratorPerFrame =
      static_cast<__uint128_t>(4503649166966397ULL) * 1000000000ULL;
  scalarInput.hostTickDenominator =
      static_cast<__uint128_t>(48000ULL) << 52U;
  scalarInput.hostTickRemainderAtStart = 0;
  scalarInput.endHostTicks = 356170;
  std::array<float, 34> scalarOutput{};
  const auto scalarResult =
      renderTracked(exactScalar.core, scalarInput, scalarOutput);
  expect(scalarResult.committed && scalarResult.pcmFrames == 16 &&
             scalarResult.silentFrames == 1 &&
             exactScalar.clock.sample().segmentEndHostTicks == 335336,
         "exact Float64 scalar endpoint differs from a Q32 approximation");

  Fixture sampleTimed;
  expect(sampleTimed.ready &&
             publishConstant(sampleTimed.ring, 1, 3, 1.0F),
         "sample-time prefix fixture queues three frames");
  NativeAudioRenderInput sampleTimedInput = input;
  sampleTimedInput.timing = NativeAudioRenderInput::Timing::SampleTime;
  sampleTimedInput.firstSampleTime = 200;
  sampleTimedInput.endSampleTime = 204;
  const auto sampleTimedResult =
      renderTracked(sampleTimed.core, sampleTimedInput, output);
  expect(sampleTimedResult.committed &&
             sampleTimed.clock.sample().segmentEndHostTicks == 63500,
         "sample-time mode retains the same exact host rational proof");

  Fixture malformedEndpoint;
  expect(malformedEndpoint.ready &&
             publishConstant(malformedEndpoint.ring, 1, 3, 1.0F),
         "malformed-endpoint fixture queues untouched PCM");
  NativeAudioRenderInput mismatch = input;
  mismatch.endHostTicks = 84334;
  const auto beforeMismatch = malformedEndpoint.ring.stats();
  const auto mismatchResult =
      renderTracked(malformedEndpoint.core, mismatch, output);
  expect(mismatchResult.failure == NativeAudioRenderFailure::InvalidInput &&
             malformedEndpoint.ring.stats().consumedFrames ==
                 beforeMismatch.consumedFrames,
         "advertised full endpoint mismatch fails before ring consume");

  Fixture malformedRemainder;
  expect(malformedRemainder.ready &&
             publishConstant(malformedRemainder.ring, 1, 3, 1.0F),
         "malformed-remainder fixture queues untouched PCM");
  NativeAudioRenderInput invalidRemainder = input;
  invalidRemainder.hostTickRemainderAtStart =
      invalidRemainder.hostTickDenominator;
  const auto beforeRemainder = malformedRemainder.ring.stats();
  const auto remainderResult =
      renderTracked(malformedRemainder.core, invalidRemainder, output);
  expect(remainderResult.failure == NativeAudioRenderFailure::InvalidInput &&
             malformedRemainder.ring.stats().consumedFrames ==
                 beforeRemainder.consumedFrames,
         "callback-start remainder outside [0,D) fails before ring consume");

  Fixture zeroWidth;
  expect(zeroWidth.ready && publishConstant(zeroWidth.ring, 1, 1, 1.0F),
         "zero-width prefix fixture queues one frame");
  NativeAudioRenderInput zeroWidthInput = hostInput(0, 2, 0);
  zeroWidthInput.hostTickNumeratorPerFrame = 1;
  zeroWidthInput.hostTickDenominator = 2;
  zeroWidthInput.hostTickRemainderAtStart = 0;
  zeroWidthInput.endHostTicks = 1;
  const auto beforeZero = zeroWidth.ring.stats();
  std::array<float, 4> zeroOutput{};
  const auto zeroResult =
      renderTracked(zeroWidth.core, zeroWidthInput, zeroOutput);
  expect(zeroResult.failure == NativeAudioRenderFailure::InvalidInput &&
             zeroWidth.ring.stats().consumedFrames ==
                 beforeZero.consumedFrames,
         "a positive full interval with zero-width prefix fails closed");

  Fixture overflow;
  expect(overflow.ready && publishConstant(overflow.ring, 1, 1, 1.0F),
         "host-rational overflow fixture queues untouched PCM");
  NativeAudioRenderInput overflowInput = hostInput(0, 2, 0);
  overflowInput.hostTickNumeratorPerFrame =
      (static_cast<__uint128_t>(1) << 127U) + 1U;
  overflowInput.hostTickDenominator = 1;
  overflowInput.endHostTicks = 2;
  const auto beforeOverflow = overflow.ring.stats();
  const auto overflowResult =
      renderTracked(overflow.core, overflowInput, zeroOutput);
  expect(overflowResult.failure == NativeAudioRenderFailure::InvalidInput &&
             overflow.ring.stats().consumedFrames ==
                 beforeOverflow.consumedFrames,
         "host-rational multiplication overflow fails before consume");
}

void testExactSampleTimeTiming() {
  Fixture fixture;
  expect(fixture.ready && publishConstant(fixture.ring, 1, 48, 1.0F),
         "sample-time fixture queues PCM");
  NativeAudioRenderInput input;
  input.generation = 1;
  input.streamFrameStart = 0;
  input.firstHostTicks = 1000;
  input.endHostTicks = 1048;
  input.hostTickNumeratorPerFrame = 1;
  input.hostTickDenominator = 1;
  input.hostTickRemainderAtStart = 0;
  input.firstSampleTime = 800;
  input.endSampleTime = 848;
  input.sampleRate = kSampleRate;
  input.frameCount = 48;
  input.timing = NativeAudioRenderInput::Timing::SampleTime;
  std::array<float, 96> output{};
  const auto result = renderTracked(fixture.core, input, output);
  expect(result.committed && result.pcmFrames == 48 &&
             fixture.clock.sample().segmentEndHostTicks == 1048,
         "integral sample continuity preserves supplied exact host endpoints");

  FakeHostClock nanosecondHost;
  NativePcmRing nanosecondRing(1);
  NativeMediaClock nanosecondClock(nanosecondHost.seam(1000000000));
  NativeAudioRenderCore nanosecondCore(nanosecondRing, nanosecondClock,
                                       1000000000);
  expect(nanosecondClock.anchorAtHostTicks(1, 0, 0.0, 1.0, false) &&
             nanosecondCore.activate(1, 0, MediaTime{0, 1},
                                     MediaTime{0, 1}, kSampleRate) &&
             publishConstant(nanosecondRing, 1, 1, 1.0F),
         "fractional host-tick fixture activates independently of tick rate");
  nanosecondCore.setPaused(false);
  nanosecondCore.setAccepting(true);
  NativeAudioRenderInput fractional;
  fractional.generation = 1;
  fractional.streamFrameStart = 0;
  fractional.firstHostTicks = 500000;
  fractional.endHostTicks = 520833;
  fractional.hostTickNumeratorPerFrame = 1000000000;
  fractional.hostTickDenominator = kSampleRate;
  fractional.hostTickRemainderAtStart = 0;
  fractional.firstSampleTime = 900;
  fractional.endSampleTime = 901;
  fractional.sampleRate = kSampleRate;
  fractional.frameCount = 1;
  fractional.timing = NativeAudioRenderInput::Timing::SampleTime;
  std::array<float, 2> fractionalOutput{};
  const auto fractionalResult =
      renderTracked(nanosecondCore, fractional, fractionalOutput);
  expect(fractionalResult.committed && fractionalResult.pcmFrames == 1 &&
             nanosecondClock.sample().segmentEndHostTicks == 520833,
         "48 kHz sample continuity accepts adapter-supplied 1 GHz endpoints");

  Fixture sampleGap;
  expect(sampleGap.ready && publishConstant(sampleGap.ring, 1, 48, 1.0F) &&
             publishConstant(sampleGap.ring, 1, 48, 1.0F),
         "sample-gap fixture queues two adjacent media spans");
  std::array<float, 96> gapOutput{};
  const auto beforeGap = renderTracked(
      sampleGap.core, sampleInput(0, 48, 1000, 1048, 800), gapOutput);
  sampleGap.host.ticks.store(1048, std::memory_order_relaxed);
  const auto afterGap = renderTracked(
      sampleGap.core, sampleInput(48, 48, 1048, 1096, 900), gapOutput);
  expect(beforeGap.committed && !beforeGap.continuous && afterGap.committed &&
             !afterGap.continuous,
         "a discontinuous sample-time range defeats matching host/media edges");

  Fixture modeChange;
  expect(modeChange.ready && publishConstant(modeChange.ring, 1, 16, 1.0F) &&
             publishConstant(modeChange.ring, 1, 16, 1.0F) &&
             publishConstant(modeChange.ring, 1, 16, 1.0F),
         "timing-mode fixture queues three adjacent spans");
  std::array<float, 32> modeOutput{};
  const auto hostFirst = renderTracked(
      modeChange.core, hostInput(0, 16, 0), modeOutput);
  modeChange.host.ticks.store(16, std::memory_order_relaxed);
  const auto sampleSecond = renderTracked(
      modeChange.core, sampleInput(16, 16, 16, 32, 100), modeOutput);
  modeChange.host.ticks.store(32, std::memory_order_relaxed);
  const auto hostThird = renderTracked(
      modeChange.core, hostInput(32, 16, 32), modeOutput);
  expect(hostFirst.committed && !hostFirst.continuous &&
             sampleSecond.committed && !sampleSecond.continuous &&
             hostThird.committed && !hostThird.continuous,
         "switching between host and sample timing resets continuity proof");
}

// Rate-parameterized fixture. The host clock runs at the stream rate so one
// host tick is exactly one stream frame, matching the fixed-rate Fixture.
struct RateFixture {
  FakeHostClock host;
  NativePcmRing ring{1};
  NativeMediaClock clock;
  NativeAudioRenderCore core;
  std::uint32_t rate;
  bool ready{false};

  explicit RateFixture(std::uint32_t sampleRate)
      : clock(host.seam(sampleRate)),
        core(ring, clock, sampleRate),
        rate(sampleRate) {
    const auto initialPosition =
        mediaTimeSecondsAtFrame(MediaTime{0, 1}, 0, sampleRate);
    ready = initialPosition &&
            clock.anchorAtHostTicks(1, 0, *initialPosition, 1.0, false) &&
            core.activate(1, 0, MediaTime{0, 1}, MediaTime{0, 1}, sampleRate);
    core.setPaused(false);
    core.setAccepting(true);
  }
};

[[nodiscard]] NativeAudioRenderInput rateInput(
    std::uint64_t streamFrameStart, std::uint32_t frameCount,
    std::uint64_t firstHostTicks, std::uint32_t sampleRate) noexcept {
  NativeAudioRenderInput input = hostInput(streamFrameStart, frameCount,
                                           firstHostTicks);
  input.sampleRate = sampleRate;
  return input;
}

// Pinned regression: late-frame retirement must leave the same amount of
// refill headroom measured in TIME at every admitted stream rate.
//
// Before this was pinned, retirement took every frame above the ones the
// current callback itself needed, leaving the ring with exactly zero refill
// headroom the instant it fired. The producer cannot republish until the
// consumer retires a slab and its wake round trip completes -- a duration, not
// a frame count -- so a zero-headroom ring underruns on the very next callback,
// which advances the clock, which grows the debt, which retires more freshly
// produced audio. That loop is worse at 44.1 kHz than at 48 kHz because a
// 44.1 kHz stream on a 48 kHz device runs the AudioUnit's own sample-rate
// converter and is pulled a non-integral ~470.4 frames per callback instead of
// a flat 512, so the frame budget between two publications is not even constant
// within the rate.
//
// The invariant this pins is deliberately stated in milliseconds: whatever the
// stream rate and whatever the device pull quantum, a retirement must never
// drive the ring below the same real-time refill floor.
void testLateRetirementHeadroomIsRateIndependent() {
  struct Case {
    std::uint32_t rate;
    std::uint32_t quantum;  // device pull in stream frames per callback
  };
  // 512 device frames at 48 kHz: a flat 512 when the stream is already 48 kHz,
  // and 512 * 44100 / 48000 = 470.4 -> 470 when the unit's converter is engaged.
  constexpr std::array<Case, 2> cases{Case{48000, 512}, Case{44100, 470}};

  std::array<double, cases.size()> retainedMilliseconds{};
  for (std::size_t index = 0; index != cases.size(); ++index) {
    const Case testCase = cases[index];
    RateFixture fixture(testCase.rate);
    expect(fixture.ready, "rate fixture activates at its stream rate");

    // One committed PCM segment: clock resilience is confined to steady state
    // and must never manufacture a generation's first segment.
    expect(publishConstant(fixture.ring, 1, testCase.quantum, 1.0F),
           "producer banks exactly one device pull");
    std::array<float, NativePcmRing::kSamplesPerSlab> output{};
    const auto first = fixture.core.render(
        rateInput(0, testCase.quantum, 0, testCase.rate),
        std::span<float>(output).first(
            static_cast<std::size_t>(testCase.quantum) *
            NativePcmRing::kChannels));
    expect(first.committed && first.pcmFrames == testCase.quantum,
           "first segment commits before any resilience applies");

    // Starve past the resync threshold so a real debt exists.
    std::uint64_t cursor = testCase.quantum;
    while (cursor - testCase.quantum <
           static_cast<std::uint64_t>(NativePcmRing::kFramesPerSlab)) {
      fixture.host.ticks.store(cursor, std::memory_order_relaxed);
      const auto starved = fixture.core.render(
          rateInput(cursor, testCase.quantum, cursor, testCase.rate),
          std::span<float>(output).first(
              static_cast<std::size_t>(testCase.quantum) *
              NativePcmRing::kChannels));
      if (starved.advancedSilentFrames != testCase.quantum) {
        expect(false, "starved callback publishes its device interval");
        break;
      }
      cursor += testCase.quantum;
    }

    // Producer fully recovers with four whole access units.
    for (unsigned slab = 0; slab != 4U; ++slab) {
      expect(publishConstant(fixture.ring, 1, 1024, 1.0F),
             "recovered producer publishes one access unit");
    }
    fixture.host.ticks.store(cursor, std::memory_order_relaxed);
    const auto recovered = fixture.core.render(
        rateInput(cursor, testCase.quantum, cursor, testCase.rate),
        std::span<float>(output).first(
            static_cast<std::size_t>(testCase.quantum) *
            NativePcmRing::kChannels));

    expect(recovered.committed && recovered.pcmFrames == testCase.quantum &&
               recovered.failure == NativeAudioRenderFailure::None,
           "a recovered producer resumes playing a full prefix");
    expect(fixture.core.stats().retiredLateFrames != 0,
           "surplus catch-up still repays the debt it can afford");
    expect(recovered.bufferedPcmFramesKnown &&
               recovered.bufferedPcmFramesAfter != 0,
           "retirement never strips the ring to zero refill headroom");
    retainedMilliseconds[index] =
        1000.0 * static_cast<double>(recovered.bufferedPcmFramesAfter) /
        static_cast<double>(testCase.rate);
  }

  // The whole point: the surviving headroom is the same DURATION at both
  // rates, not the same frame count.
  expect(retainedMilliseconds[0] >= 30.0 && retainedMilliseconds[1] >= 30.0,
         "retirement leaves a real refill window at both stream rates");
  expect(std::abs(retainedMilliseconds[0] - retainedMilliseconds[1]) <= 2.0,
         "retained refill headroom is rate-independent in milliseconds");
}

} // namespace

int main() {
  testPreflightLowerBoundAndProducerAppend();
  testRingAndClockBackpressureDoNotConsume();
  testMetadataCorrectionConsumesNothing();
  testCommitFailureZerosAndHidesSpeculativeRun();
  testExactContinuityAndUnderrunGap();
  testUnderrunAdvancesClockAndRetiresLateFrames();
  testMalformedStaleAndReentrantCallbacks();
  testGainMuteRamp();
  testPauseBoundaryAndResume();
  testQuiescentStopRetainsPcmAndRestartsClock();
  testTerminalFramePublishesEofOnce();
  testTerminalObservationResetsAcrossActivation();
  testExactNonzeroMediaOrigin();
  testExactDualSeekOrigins();
  testCanonicalOriginRoundingRegression();
  testHostFrequencyComposition();
  testExactPartialHostPrefix();
  testExactSampleTimeTiming();
  testLateRetirementHeadroomIsRateIndependent();

  if (failures != 0) {
    std::cerr << failures << " native audio render core check(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native audio render core checks passed\n";
  return EXIT_SUCCESS;
}
