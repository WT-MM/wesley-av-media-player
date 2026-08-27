#include "platform/macos/native_video_consumer.hpp"

#include "platform/macos/native_video_limits.hpp"

#include <CoreVideo/CoreVideo.h>

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace wam;
using namespace wam::macos;

[[noreturn]] void fail(const char* message) {
  std::cerr << "FAIL: " << message << '\n';
  std::exit(EXIT_FAILURE);
}

void expect(bool condition, const char* message) {
  if (!condition) {
    fail(message);
  }
}

void wake(void* context) noexcept {
  static_cast<std::atomic<std::uint64_t>*>(context)->fetch_add(
      1, std::memory_order_relaxed);
}

struct FakeClock {
  NativeMediaClockSnapshot snapshot{};

  [[nodiscard]] static NativeMediaClockSnapshot sample(
      void* context) noexcept {
    return static_cast<FakeClock*>(context)->snapshot;
  }

  [[nodiscard]] NativeVideoClockSeam seam() noexcept {
    return {&sample, this, 1000, true};
  }
};

class FakeOutput final : public NativeTrackedVideoOutput {
 public:
  explicit FakeOutput(NativeTrackedVideoOutputWakeSeam wake) : wake_(wake) {}

  [[nodiscard]] NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) const noexcept override {
    if (failed_ || closed_) {
      return NativeTrackedVideoCapacity::Failed;
    }
    if (generation != generation_) {
      return NativeTrackedVideoCapacity::StaleGeneration;
    }
    return admitted_.valid() || event_
               ? NativeTrackedVideoCapacity::Backpressure
               : NativeTrackedVideoCapacity::Available;
  }

  [[nodiscard]] NativeTrackedVideoSubmitStatus submit(
      const FrameLease& frame, NativeTrackedFrameSequence sequence,
      std::string*) noexcept override {
    if (failed_ || closed_) {
      return NativeTrackedVideoSubmitStatus::Failed;
    }
    if (frame.timing().generation != generation_) {
      return NativeTrackedVideoSubmitStatus::StaleGeneration;
    }
    if (!frame || !sequence.valid() || admitted_.valid() || event_) {
      return NativeTrackedVideoSubmitStatus::Backpressure;
    }
    lease_ = frame;
    admitted_ = sequence;
    timing_ = frame.timing();
    ++submitted_;
    return NativeTrackedVideoSubmitStatus::Accepted;
  }

  [[nodiscard]] std::optional<NativeTrackedVideoEvent>
  takeEvent() noexcept override {
    std::optional<NativeTrackedVideoEvent> result = std::move(event_);
    event_.reset();
    if (result &&
        (result->kind == NativeTrackedVideoEventKind::FrameDrawn ||
         result->kind == NativeTrackedVideoEventKind::FrameSuperseded ||
         result->kind == NativeTrackedVideoEventKind::Failed)) {
      admitted_ = {};
      timing_ = {};
      lease_.reset();
    }
    return result;
  }

  [[nodiscard]] NativeTrackedVideoOutputProgress flushProgress(
      std::uint64_t retired,
      std::uint64_t next) noexcept override {
    ++flushProgressCalls_;
    if (failed_ || closed_ || next == 0 || next <= retired) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (flushPending_) {
      if (retired != flushRetired_ || next != flushNext_) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
    } else {
      if (retired != generation_) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
      flushPending_ = true;
      flushRetired_ = retired;
      flushNext_ = next;
    }
    if (failDuringFlush_ && admitted_.valid() && !event_) {
      failDuringFlush_ = false;
      failFrame();
    }
    if (admitted_.valid() && !event_) {
      supersede();
    }
    if (admitted_.valid() || event_) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    if (flushBlocked_) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    generation_ = next;
    flushPending_ = false;
    flushRetired_ = 0;
    flushNext_ = 0;
    return NativeTrackedVideoOutputProgress::Done;
  }

  [[nodiscard]] NativeTrackedVideoOutputProgress closeProgress(
      std::uint64_t finalGeneration) noexcept override {
    if (finalGeneration <= generation_) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (closeGeneration_ != 0 && closeGeneration_ != finalGeneration) {
      return NativeTrackedVideoOutputProgress::StaleGeneration;
    }
    closeGeneration_ = finalGeneration;
    if (closeBlocked_) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    if (admitted_.valid() && !event_) {
      supersede();
    }
    if (admitted_.valid() || event_) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    generation_ = finalGeneration;
    // Terminal close supersedes any nonterminal arm/seek invalidation only
    // after it has retired the tracked frame and proved the stronger final
    // generation, matching the production tracked adapter.
    flushPending_ = false;
    flushRetired_ = 0;
    flushNext_ = 0;
    closed_ = true;
    return NativeTrackedVideoOutputProgress::Done;
  }

  [[nodiscard]] NativeTrackedVideoOutputFacts facts()
      const noexcept override {
    NativeTrackedVideoOutputFacts result;
    result.generation = generation_;
    result.admittedFrame = admitted_;
    result.submittedFrames = submitted_;
    result.drawnFrames = drawn_;
    result.supersededFrames = superseded_;
    result.lastEventSequence = eventSequence_;
    result.retainedFrames = admitted_.valid() ? 1U : 0U;
    result.eventPending = event_.has_value();
    result.invalidationPending =
        flushPending_ || (closeGeneration_ != 0 && !closed_);
    result.closed = closed_;
    result.fatal = failed_;
    return result;
  }

  void draw() noexcept {
    expect(admitted_.valid() && !event_, "fake draw needs one admission");
    event_ = NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::FrameDrawn,
        ++eventSequence_, admitted_, generation_, timing_};
    ++drawn_;
    wake_.signal(wake_.context);
  }

  void supersede() noexcept {
    expect(admitted_.valid() && !event_,
           "fake supersede needs one admission");
    event_ = NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::FrameSuperseded,
        ++eventSequence_, admitted_, generation_, timing_};
    ++superseded_;
    wake_.signal(wake_.context);
  }

  void invalidateEvent(std::uint64_t generation) noexcept {
    expect(!event_, "fake lifecycle event mailbox must be empty");
    event_ = NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::GenerationInvalidated,
        ++eventSequence_, {}, generation, {}};
    wake_.signal(wake_.context);
  }

  void failFrame() noexcept {
    expect(admitted_.valid() && !event_,
           "fake failure needs one admission");
    event_ = NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::Failed,
        ++eventSequence_, admitted_, generation_, timing_};
    failed_ = true;
    wake_.signal(wake_.context);
  }

  void malformedFailureWithoutCredit() noexcept {
    expect(!admitted_.valid() && !event_,
           "malformed failure fixture must have no admitted frame");
    event_ = NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::Failed,
        ++eventSequence_, {}, generation_, {}};
    failed_ = true;
    wake_.signal(wake_.context);
  }

  void setCloseBlocked(bool value) noexcept { closeBlocked_ = value; }
  void setFlushBlocked(bool value) noexcept { flushBlocked_ = value; }
  void failNextFlushWithAdmittedFrame() noexcept {
    failDuringFlush_ = true;
  }
  [[nodiscard]] std::uint64_t flushProgressCalls() const noexcept {
    return flushProgressCalls_;
  }

 private:
  NativeTrackedVideoOutputWakeSeam wake_{};
  FrameLease lease_;
  FrameTiming timing_{};
  std::optional<NativeTrackedVideoEvent> event_;
  NativeTrackedFrameSequence admitted_{};
  std::uint64_t generation_{0};
  std::uint64_t eventSequence_{0};
  std::uint64_t submitted_{0};
  std::uint64_t drawn_{0};
  std::uint64_t superseded_{0};
  std::uint64_t flushProgressCalls_{0};
  std::uint64_t flushRetired_{0};
  std::uint64_t flushNext_{0};
  std::uint64_t closeGeneration_{0};
  bool flushPending_{false};
  bool failed_{false};
  bool closed_{false};
  bool closeBlocked_{false};
  bool flushBlocked_{false};
  bool failDuringFlush_{false};
};

media::NativeMediaGenerationTimeline timeline(std::uint64_t generation,
                                              media::MediaTime floor) {
  media::NativeMediaGenerationTimeline result;
  result.generation = generation;
  result.mode = media::MediaSeekMode::Accurate;
  result.requestedTarget = floor;
  result.actualDecodeStart = {0, 1};
  result.presentationFloor = floor;
  result.startsAtStreamOrigin = true;
  return result;
}

FrameLease frame(std::uint64_t generation, std::int64_t pts,
                 std::int64_t duration, std::vector<std::byte>* pixels) {
  constexpr std::size_t kWidth = 4;
  constexpr std::size_t kHeight = 4;
  constexpr std::size_t kBytesPerRow = kWidth * 4;
  pixels->assign(kBytesPerRow * kHeight, std::byte{0});
  CVPixelBufferRef buffer = nullptr;
  const CVReturn created = CVPixelBufferCreateWithBytes(
      kCFAllocatorDefault, kWidth, kHeight, kCVPixelFormatType_32BGRA,
      pixels->data(), kBytesPerRow, nullptr, nullptr, nullptr, &buffer);
  expect(created == kCVReturnSuccess && buffer != nullptr,
         "CPU-backed pixel buffer creation succeeds");
  FrameLease result(buffer,
                    {CMTimeMake(pts, 1000), CMTimeMake(duration, 1000),
                     generation, true});
  CVPixelBufferRelease(buffer);
  expect(static_cast<bool>(result), "CPU-backed frame lease succeeds");
  return result;
}

struct Fixture {
  Fixture() {
    clock.snapshot.publicationSerial = 1;
    clock.snapshot.generation = 7;
    clock.snapshot.sampledHostTicks = 100;
    clock.snapshot.mediaSeconds = 1.0;
    clock.snapshot.rate = 1.0;
    clock.snapshot.valid = true;
    clock.snapshot.publicationCurrent = true;
    output = std::make_shared<FakeOutput>(
        NativeTrackedVideoOutputWakeSeam{&wake, &wakes});
    consumer = NativeVideoConsumer::create(
        lifetime, clock.seam(), output,
        NativeVideoConsumerWakeSeam{&wake, &wakes});
    expect(consumer != nullptr, "consumer accepts complete dependencies");
  }

  ~Fixture() {
    if (consumer != nullptr) {
      for (unsigned attempt = 0; attempt != 4; ++attempt) {
        if (consumer->close() == media::NativeMediaConsumerProgress::Done) {
          break;
        }
      }
    }
  }

  std::shared_ptr<void> lifetime = std::make_shared<int>(1);
  FakeClock clock;
  std::atomic<std::uint64_t> wakes{0};
  std::shared_ptr<FakeOutput> output;
  std::unique_ptr<NativeVideoConsumer> consumer;
};

void testArmContract() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "first exact generation arm reaches Done");
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "exact arm retry is idempotent");
  expect(fixture.consumer->armFirstGeneration(8) ==
             NativeVideoConsumerArmProgress::StaleGeneration,
         "a different arm cannot replace the first operation");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {1, 1})),
         "the fixture enters only the post-arm scheduler state");
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Failed,
         "a consumed arm cannot be replayed after configure");
}

void testDelayedLifecycleDiagnostic() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "lifecycle diagnostic fixture arms");
  fixture.output->invalidateEvent(7);
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "a legal delayed lifecycle diagnostic does not invalidate configure");
  expect(fixture.consumer->capacity(7) ==
             media::NativeMediaConsumeResult::Draining,
         "the exact delayed generation diagnostic is consumed as progress");
}

void testCloseRetiresQuiescingArm() {
  Fixture fixture;
  fixture.output->setFlushBlocked(true);
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Quiescing,
         "first-generation render invalidation may quiesce");
  expect(fixture.consumer->close() ==
             media::NativeMediaConsumerProgress::Quiescing,
         "close preserves the exact pending pre-arm flush");
  fixture.output->setFlushBlocked(false);
  expect(fixture.consumer->close() ==
             media::NativeMediaConsumerProgress::Progress,
         "close first proves the pending pre-arm invalidation");
  expect(fixture.consumer->close() ==
             media::NativeMediaConsumerProgress::Done,
         "close then proves a strictly newer terminal invalidation");
}

void testExactRetirementGapAndPairOwnership() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "retirement gap fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "retirement gap fixture installs");

  expect(fixture.consumer->retire(6, 19) ==
             media::NativeMediaConsumerProgress::StaleGeneration,
         "a non-exposed retired generation is stale and inert");
  expect(fixture.consumer->retire(7, 7) ==
             media::NativeMediaConsumerProgress::Failed,
         "terminal invalidation must be strictly newer");
  expect(!fixture.output->facts().closed &&
             fixture.output->facts().generation == 7 &&
             fixture.consumer->facts().decoder.generation == 0,
         "invalid retirement pairs mutate neither output nor decoder");

  expect(fixture.consumer->retire(7, 19) ==
             media::NativeMediaConsumerProgress::Done,
         "a gapped exact retirement reaches Done without inventing next");
  const auto facts = fixture.consumer->facts();
  expect(facts.closed && facts.generation == 19 &&
             facts.decoder.generation == 19 && !facts.decoder.configured &&
             facts.output.closed && facts.output.generation == 19 &&
             facts.output.retainedFrames == 0,
         "Done publishes the exact invalidation across consumer dependencies");
  expect(fixture.consumer->retire(7, 19) ==
             media::NativeMediaConsumerProgress::Done,
         "the sole accepted retirement pair is idempotent");
  expect(fixture.consumer->retire(7, 20) ==
             media::NativeMediaConsumerProgress::StaleGeneration &&
             fixture.consumer->retire(19, 20) ==
                 media::NativeMediaConsumerProgress::StaleGeneration,
         "no different pair can replace completed retirement");
  expect(fixture.consumer->facts().generation == 19 &&
             fixture.output->facts().generation == 19,
         "stale retries are inert after Done");
}

void testArmOnlyAndPendingArmRetirement() {
  {
    Fixture fixture;
    expect(fixture.consumer->retire(0, 17) ==
               media::NativeMediaConsumerProgress::Done,
           "a never-configured port accepts retired zero with exact final gap");
    const auto facts = fixture.consumer->facts();
    expect(facts.closed && facts.generation == 17 &&
               facts.decoder.generation == 17 && facts.output.closed &&
               facts.output.generation == 17,
           "never-configured retirement installs one exact invalidation");
  }

  {
    Fixture fixture;
    expect(fixture.consumer->armFirstGeneration(7) ==
               NativeVideoConsumerArmProgress::Done,
           "arm-only retirement fixture reaches output generation");
    expect(fixture.consumer->facts().decoder.generation == 0,
           "arm-only retirement begins before decoder configuration");
    expect(fixture.consumer->retire(7, 23) ==
               media::NativeMediaConsumerProgress::Done,
           "arm-only output and dormant decoder retire to one exact gap");
    const auto facts = fixture.consumer->facts();
    expect(facts.generation == 23 && facts.decoder.generation == 23 &&
               facts.output.generation == 23 && facts.output.closed,
           "arm-only Done exposes exact decoder and render invalidation");
  }

  {
    Fixture fixture;
    fixture.output->setFlushBlocked(true);
    expect(fixture.consumer->armFirstGeneration(7) ==
               NativeVideoConsumerArmProgress::Quiescing,
           "pending-arm retirement fixture exposes generation seven");
    expect(fixture.consumer->retire(0, 29) ==
               media::NativeMediaConsumerProgress::StaleGeneration,
           "retired zero cannot ignore a pre-arm exposed generation");
    expect(fixture.output->facts().invalidationPending &&
               !fixture.output->facts().closed,
           "stale pre-arm retirement leaves the exact arm operation intact");
    expect(fixture.consumer->retire(7, 29) ==
               media::NativeMediaConsumerProgress::Done,
           "exact retirement terminally supersedes a Quiescing arm");
    const auto facts = fixture.consumer->facts();
    expect(facts.generation == 29 && facts.decoder.generation == 29 &&
               facts.output.generation == 29 && facts.output.closed &&
               !facts.output.invalidationPending,
           "pending-arm retirement proves one exact final generation");
  }
}

void testRetirementSupersedesPendingSeek() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "pending-seek retirement fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "pending-seek retirement fixture installs");
  fixture.output->setFlushBlocked(true);
  expect(fixture.consumer->flush(7, 8, timeline(8, {0, 1})) ==
             media::NativeMediaConsumerProgress::Quiescing,
         "seek exposes generation eight before its render proof completes");
  expect(fixture.consumer->retire(7, 31) ==
             media::NativeMediaConsumerProgress::StaleGeneration,
         "retirement must name the pending exposed seek target");
  expect(fixture.output->facts().invalidationPending &&
             fixture.consumer->facts().decoder.generation == 8,
         "a stale retirement does not disturb pending seek state");
  expect(fixture.consumer->retire(8, 31) ==
             media::NativeMediaConsumerProgress::Done,
         "exact final retirement supersedes the pending seek terminally");
  const auto facts = fixture.consumer->facts();
  expect(facts.generation == 31 && facts.decoder.generation == 31 &&
             facts.output.generation == 31 && facts.output.closed &&
             !facts.output.invalidationPending,
         "pending seek decoder, sink, and render route share final generation");
}

void testQuiescingRetirementKeepsExactPair() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "Quiescing retirement fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "Quiescing retirement fixture installs");
  std::vector<std::byte> pixels;
  expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
             *fixture.consumer, frame(7, 1000, 40, &pixels)),
         "Quiescing retirement fixture admits one decoded frame");
  expect(NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
         "Quiescing retirement fixture submits one tracked frame");
  fixture.output->setCloseBlocked(true);
  expect(fixture.consumer->retire(7, 37) ==
             media::NativeMediaConsumerProgress::Quiescing,
         "render retirement may remain wake-driven and Quiescing");
  expect(fixture.consumer->facts().decoder.generation == 37 &&
             fixture.output->facts().generation == 7 &&
             fixture.output->facts().invalidationPending &&
             fixture.output->facts().retainedFrames == 1 &&
             fixture.consumer->facts().awaitingDraw.value == 1,
         "decoder retirement completes while one exact render lease is pending");
  expect(fixture.consumer->retire(7, 38) ==
             media::NativeMediaConsumerProgress::StaleGeneration &&
             fixture.consumer->retire(8, 37) ==
                 media::NativeMediaConsumerProgress::StaleGeneration,
         "mismatched retries cannot replace an in-flight retirement pair");
  expect(fixture.output->facts().generation == 7 &&
             fixture.output->facts().invalidationPending,
         "mismatched retries are inert while output is Quiescing");
  expect(fixture.consumer->retire(7, 37) ==
             media::NativeMediaConsumerProgress::Quiescing,
         "an exact blocked retry remains Quiescing");
  fixture.output->setCloseBlocked(false);
  expect(fixture.consumer->retire(7, 37) ==
             media::NativeMediaConsumerProgress::Quiescing,
         "unblocked close first publishes exact tracked-frame supersession");
  expect(fixture.consumer->facts().awaitingDraw.value == 1 &&
             fixture.output->facts().eventPending,
         "Done remains gated until the exact supersession is consumed");
  expect(fixture.consumer->retire(7, 37) ==
             media::NativeMediaConsumerProgress::Done,
         "the exact pair consumes its lease proof and reaches terminal Done");
  expect(fixture.consumer->facts().generation == 37 &&
             fixture.consumer->facts().output.generation == 37 &&
             !fixture.consumer->facts().awaitingDraw.valid() &&
             fixture.consumer->facts().output.retainedFrames == 0,
         "Quiescing retirement never substitutes a derived generation");
}

void testMatchedFrameFailureRetiresExactly() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "fatal retirement fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "fatal retirement fixture installs");
  std::vector<std::byte> pixels;
  expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
             *fixture.consumer, frame(7, 1000, 40, &pixels)),
         "fatal retirement fixture admits one frame");
  expect(NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
         "fatal retirement fixture submits its tracked frame");
  fixture.output->failNextFlushWithAdmittedFrame();
  expect(fixture.consumer->flush(7, 8, timeline(8, {0, 1})) ==
             media::NativeMediaConsumerProgress::Quiescing,
         "matching frame failure races a now-pending seek invalidation");
  expect(fixture.consumer->retire(8, 43) ==
             media::NativeMediaConsumerProgress::Done,
         "validated frame failure still permits exact terminal retirement");
  const auto facts = fixture.consumer->facts();
  expect(facts.closed && facts.generation == 43 &&
             !facts.awaitingDraw.valid() &&
             facts.failure == NativeVideoConsumerFailure::Output &&
             facts.output.fatal && facts.output.closed &&
             facts.output.generation == 43,
         "fatal history remains diagnostic after every lease is retired");
  const auto event = fixture.consumer->takeOutputEvent();
  expect(event && event->kind == NativeTrackedVideoEventKind::Failed &&
             event->frameSequence.value == 1,
         "fatal retirement preserves exact rejected-frame evidence");
}

void testExactTimeMath() {
  const auto end = NativeVideoConsumerTestAccess::checkedIntervalEnd(
      {1, 3}, {1, 6});
  expect(end && *end == media::MediaTime{1, 2},
         "interval addition canonicalizes without double rounding");
  expect(!NativeVideoConsumerTestAccess::checkedIntervalEnd(
              {std::numeric_limits<std::int64_t>::max(), 1}, {1, 1}),
         "interval overflow fails closed");
  expect(NativeVideoConsumerTestAccess::compareToClock(
             {1, 10}, 0.1) == media::MediaTimeOrder::Less,
         "exact decimal rational is ordered against binary64 without epsilon");
  expect(NativeVideoConsumerTestAccess::compareToClock(
             {1, 2}, 0.5) == media::MediaTimeOrder::Equal,
         "exact dyadic clock equality is preserved");
  expect(NativeVideoConsumerTestAccess::compareToClock(
             {0, 1}, std::numeric_limits<double>::denorm_min()) ==
             media::MediaTimeOrder::Less,
         "zero orders before the smallest positive binary64 without shifting");
  expect(!NativeVideoConsumerTestAccess::compareToClock(
              {1, 2}, std::numeric_limits<double>::quiet_NaN()),
         "non-finite clocks are rejected");
}

void testOpenGopLeadingPictureDiscard() {
  // The real shape this pins: an HEVC seek generation starts on a CRA at
  // 25.0667 s (1541/60) and the very next access unit in decode order is one
  // of its leading pictures at 25.0 s. VideoToolbox cannot decode that leading
  // picture -- its references precede the CRA and were never submitted -- and
  // it can never be visible, because it presents before the random-access
  // point the source located at or before the presentation floor.
  const media::MediaTime randomAccess{385024, 15360};
  const media::MediaTime leading{384000, 15360};
  const std::optional<media::MediaTime> started{randomAccess};

  expect(NativeVideoConsumerTestAccess::precedesGenerationStart(
             leading, false, started),
         "a non-key access unit before the generation's start is a leading "
         "picture");
  expect(!NativeVideoConsumerTestAccess::precedesGenerationStart(
             randomAccess, true, started),
         "the random-access sample itself is never discarded");
  expect(!NativeVideoConsumerTestAccess::precedesGenerationStart(
             randomAccess, false, started),
         "an access unit presenting exactly at the start is kept");
  expect(!NativeVideoConsumerTestAccess::precedesGenerationStart(
             media::MediaTime{385536, 15360}, false, started),
         "trailing pictures after the start are kept");
  // A later open-GOP random-access point reached by linear decode keeps its
  // leading pictures: they are decodable there and they are visible frames.
  expect(!NativeVideoConsumerTestAccess::precedesGenerationStart(
             media::MediaTime{384512, 15360}, true, started),
         "a mid-stream key frame is never treated as a leading picture");
  expect(!NativeVideoConsumerTestAccess::precedesGenerationStart(
             leading, false, std::nullopt),
         "no access unit is discarded before the generation's start is known");
}

void testSelectedDurationAdmission() {
  expect(NativeVideoConsumer::selectedTrackDurationsSupported(
             {10, 1}, {10, 1}),
         "equal exact selected durations are native-supported");
  expect(NativeVideoConsumer::selectedTrackDurationsSupported(
             {10001, 1000}, {10, 1}),
         "an exact longer audio clock covers the video tail");
  expect(!NativeVideoConsumer::selectedTrackDurationsSupported(
             {3000, 1000}, {10, 1}),
         "audio meaningfully shorter than video must fall back before "
         "activation");
  // 2026-08-27. A one-second shortfall was a refusal while the bound sized the
  // tail the clock could not present. The clock now advances across
  // container-declared trailing silence and the video tail draws to the end
  // (see native_video_limits.hpp), so a shortfall of this size is admitted
  // rather than refused. The refusal above moved to a shortfall the widened
  // bound still rejects; it did not go away.
  expect(NativeVideoConsumer::selectedTrackDurationsSupported(
             {9000, 1000}, {10, 1}),
         "a one-second declared trailing silence is now admitted natively");
  expect(NativeVideoConsumer::selectedTrackDurationsSupported(
             {9108, 1000}, {10, 1}),
         "the measured 892 ms movie shortfall is admitted natively");
  expect(!NativeVideoConsumer::selectedTrackDurationsSupported(
             {}, {10, 1}),
         "an inexact selected duration fails native admission");

  // Container artefacts, not content differences. A muxer that trims AAC-LC's
  // 2112-sample encoder priming with an edit list shortens the edited audio
  // duration while leaving the video edit at full length; the observed
  // ffmpeg-muxed shape is 313.185594 s of audio against 313.229589 s of video.
  // These stay native: the unpresentable tail is shorter than two frames.
  expect(NativeVideoConsumer::selectedTrackDurationsSupported(
             {225493624, 720000}, {28190663, 90000}),
         "AAC priming trimmed by an edit list stays inside native admission");
  expect(NativeVideoConsumer::selectedTrackDurationsSupported(
             {47956, 48000}, {1, 1}),
         "a 44 ms priming shortfall at 48 kHz is admitted");

  // The bound is exact on both sides, and is expressed on the shortfall's own
  // millisecond timescale rather than through double.
  expect(NativeVideoConsumer::selectedTrackDurationsSupported(
             {10000 - native_video_limits::
                          kMaximumSelectedAudioShortfallMilliseconds,
              1000},
             {10, 1}),
         "a shortfall exactly at the bound is admitted");
  expect(!NativeVideoConsumer::selectedTrackDurationsSupported(
             {10000 -
                  native_video_limits::
                      kMaximumSelectedAudioShortfallMilliseconds -
                  1,
              1000},
             {10, 1}),
         "one millisecond past the bound falls back");
  expect(!NativeVideoConsumer::selectedTrackDurationsSupported(
             {-1, 1000}, {10, 1}),
         "a negative selected duration fails native admission");
}

void testDrawAckGatesNextFrame() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "scheduler generation arm succeeds");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {1, 1})),
         "scheduler generation installs");

  std::vector<std::byte> firstPixels;
  std::vector<std::byte> secondPixels;
  expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
             *fixture.consumer, frame(7, 1000, 40, &firstPixels)),
         "first decoded frame enters the cap-one sink");
  expect(NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
         "first due frame submits");
  auto facts = fixture.consumer->facts();
  expect(facts.submittedFrames == 1 && facts.awaitingDraw.value == 1 &&
             facts.outputBlocked,
         "accepted output remains blocked on the exact draw ack");
  fixture.output->draw();
  const auto event = fixture.consumer->takeOutputEvent();
  expect(event && event->kind == NativeTrackedVideoEventKind::FrameDrawn &&
             event->frameSequence.value == 1,
         "owner observation pumps the raw draw and retains exact evidence");
  expect(fixture.output->capacity(7) ==
             NativeTrackedVideoCapacity::Available,
         "owner-pumped real draw rearms the tracked output lane");
  facts = fixture.consumer->facts();
  expect(facts.drawnFrames == 1 && !facts.awaitingDraw.valid() &&
             facts.submittedFrames == 1,
         "draw proof retires only the matching first delivery");
  expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
             *fixture.consumer, frame(7, 1040, 40, &secondPixels)),
         "next decoded frame enters only after owner readiness is proved");
  fixture.clock.snapshot.mediaSeconds = 1.04;
  expect(NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
         "second scheduler pump can advance after proof consumption");
  expect(fixture.consumer->facts().submittedFrames == 2,
         "the next unique surface advances only after the prior draw ack");
}

void testFailedFrameRetiresExactCredit() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "failure fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "failure fixture installs");
  std::vector<std::byte> pixels;
  expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
             *fixture.consumer, frame(7, 1000, 40, &pixels)),
         "failure fixture admits one decoded frame");
  expect(NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
         "failure fixture submits one tracked frame");
  fixture.output->failFrame();
  expect(fixture.consumer->close() ==
             media::NativeMediaConsumerProgress::Done,
         "direct teardown consumes the exact rejection and closes cleanly");
  const auto facts = fixture.consumer->facts();
  expect(facts.closed && !facts.awaitingDraw.valid() &&
             facts.failure == NativeVideoConsumerFailure::Output,
         "the failed frame retires exact credit and stays diagnostic");
  const auto event = fixture.consumer->takeOutputEvent();
  expect(event && event->kind == NativeTrackedVideoEventKind::Failed &&
             event->frameSequence.value == 1,
         "the exact failed-frame evidence remains observable");
}

void testFailedFrameSupersedesPendingFlushOnClose() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "combined failure fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "combined failure fixture installs");
  std::vector<std::byte> pixels;
  expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
             *fixture.consumer, frame(7, 1000, 40, &pixels)),
         "combined failure fixture admits one frame");
  expect(NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
         "combined failure fixture submits one frame");
  fixture.output->failNextFlushWithAdmittedFrame();
  const auto seeking = timeline(8, {0, 1});
  expect(fixture.consumer->flush(7, 8, seeking) ==
             media::NativeMediaConsumerProgress::Quiescing,
         "seek flush publishes exact frame failure while remaining pending");
  expect(fixture.consumer->close() ==
             media::NativeMediaConsumerProgress::Done,
         "fatal terminal close supersedes an in-flight output flush");
  expect(fixture.output->facts().generation == 9,
         "terminal generation is strictly newer than the pending seek target");
}

void testMalformedFailureCannotAuthorizeClose() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "malformed failure fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "malformed failure fixture installs");
  fixture.output->malformedFailureWithoutCredit();
  expect(fixture.consumer->capacity(7) ==
             media::NativeMediaConsumeResult::Failed,
         "malformed failure is consumed without matching frame credit");
  expect(fixture.consumer->retire(7, 53) ==
             media::NativeMediaConsumerProgress::Failed,
         "malformed fatal history cannot authorize exact retirement");
  expect(fixture.consumer->retire(7, 53) ==
             media::NativeMediaConsumerProgress::Failed,
         "the exact retry remains failed after a persistent protocol breach");
  expect(!fixture.output->facts().closed &&
             fixture.output->facts().generation == 7,
         "malformed failure never becomes terminal invalidation proof");
}

void testHalfOpenFloorAndProvenLateDrop() {
  {
    Fixture fixture;
    expect(fixture.consumer->armFirstGeneration(7) ==
               NativeVideoConsumerArmProgress::Done,
           "floor fixture arms");
    expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
               *fixture.consumer, timeline(7, {1000, 1000})),
           "floor fixture installs");

    std::vector<std::byte> prerollPixels;
    expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
               *fixture.consumer, frame(7, 960, 40, &prerollPixels)),
           "preroll frame enters sink");
    expect(NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
           "preroll frame is processed");
    expect(fixture.consumer->facts().discardedPrerollFrames == 1,
           "interval ending exactly at floor is dropped by half-open proof");

    std::vector<std::byte> coveringPixels;
    expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
               *fixture.consumer, frame(7, 980, 40, &coveringPixels)),
           "covering frame enters sink");
    expect(NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
           "covering frame is scheduled");
    expect(fixture.consumer->facts().submittedFrames == 1,
           "frame covering the floor remains presentable");
  }

  Fixture late;
  late.clock.snapshot.mediaSeconds = 1.1;
  expect(late.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "late fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *late.consumer, timeline(7, {0, 1})),
         "late fixture installs");
  std::vector<std::byte> latePixels;
  expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
             *late.consumer, frame(7, 1000, 100, &latePixels)),
         "late frame enters sink");
  expect(NativeVideoConsumerTestAccess::pumpScheduler(*late.consumer),
         "late frame is processed");
  expect(late.consumer->facts().discardedLateFrames == 1 &&
             late.consumer->facts().submittedFrames == 0,
         "only an interval proven ended at the clock is dropped late");
}

void testPreviewQuiesceGatesAndRequiresKeyFrameRelease() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "preview quiesce fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "preview quiesce fixture installs");
  const std::uint64_t outputFlushes = fixture.output->flushProgressCalls();

  expect(fixture.consumer->quiesceForPreview(7) ==
             NativeVideoConsumerPreviewProgress::Done,
         "an idle main lane quiesces synchronously");
  const auto quiesced = fixture.consumer->facts();
  expect(quiesced.generation == 7 && quiesced.previewQuiesceStarted &&
             quiesced.previewQuiesced &&
             quiesced.previewQuiesceGeneration == 7 &&
             quiesced.decoder.generation == 7 &&
             quiesced.decodedQueueDepth == 0 && !quiesced.heldFrame &&
             quiesced.output.generation == 7 &&
             quiesced.output.retainedFrames == 0 &&
             fixture.output->flushProgressCalls() == outputFlushes,
         "Done preserves generation and never enters output lifecycle");
  expect(fixture.consumer->capacity(7) ==
             media::NativeMediaConsumeResult::Backpressure,
         "quiesce immediately gates dispatcher-facing admission");
  expect(fixture.consumer->quiesceForPreview(7) ==
             NativeVideoConsumerPreviewProgress::Done &&
             fixture.consumer->quiesceForPreview(8) ==
                 NativeVideoConsumerPreviewProgress::StaleGeneration,
         "the exact quiesce operation is repeatable and mismatch is inert");

  expect(fixture.consumer->releasePreviewQuiesce(
             7, NativeVideoConsumerPreviewRelease::UnknownOrDelta) ==
             NativeVideoConsumerPreviewProgress::KeyFrameRequired,
         "an unknown or delta resume is rejected without false reopening");
  expect(fixture.consumer->facts().previewQuiesceStarted &&
             fixture.consumer->capacity(7) ==
                 media::NativeMediaConsumeResult::Backpressure,
         "rejected delta release leaves the admission gate closed");
  expect(fixture.consumer->releasePreviewQuiesce(
             7, NativeVideoConsumerPreviewRelease::NextSampleIsKeyFrame) ==
             NativeVideoConsumerPreviewProgress::Done,
         "explicit next-keyframe authority reopens the main lane");
  const auto released = fixture.consumer->facts();
  expect(!released.previewQuiesceStarted && !released.previewQuiesced &&
             released.previewReleasedGeneration == 7 &&
             released.previewResumeNeedsKeyFrame,
         "release facts retain the fail-closed next-sample obligation");
  expect(fixture.consumer->releasePreviewQuiesce(
             7, NativeVideoConsumerPreviewRelease::NextSampleIsKeyFrame) ==
             NativeVideoConsumerPreviewProgress::Done,
         "the exact successful release is idempotent");
}

void testPreviewQuiesceWaitsForRealTrackedDraw() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "preview draw fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "preview draw fixture installs");
  std::vector<std::byte> pixels;
  expect(NativeVideoConsumerTestAccess::injectDecodedFrame(
             *fixture.consumer, frame(7, 1000, 40, &pixels)) &&
             NativeVideoConsumerTestAccess::pumpScheduler(*fixture.consumer),
         "preview draw fixture admits one tracked main frame");
  const std::uint64_t outputFlushes = fixture.output->flushProgressCalls();

  expect(fixture.consumer->quiesceForPreview(7) ==
             NativeVideoConsumerPreviewProgress::Quiescing,
         "quiesce waits while an accepted main draw is outstanding");
  expect(fixture.consumer->facts().previewQuiesceStarted &&
             !fixture.consumer->facts().previewQuiesced &&
             fixture.output->facts().retainedFrames == 1 &&
             fixture.output->flushProgressCalls() == outputFlushes,
         "waiting neither fabricates a terminal event nor flushes output");
  fixture.output->draw();
  expect(fixture.consumer->releasePreviewQuiesce(
             7, NativeVideoConsumerPreviewRelease::NextSampleIsKeyFrame) ==
             NativeVideoConsumerPreviewProgress::Done,
         "release consumes the real draw terminal and reopens in one call");
  expect(!fixture.consumer->facts().previewQuiesceStarted &&
             fixture.consumer->facts().previewResumeNeedsKeyFrame,
         "reported release Done never leaves dispatcher admission gated");
  const auto event = fixture.consumer->takeOutputEvent();
  expect(event && event->kind == NativeTrackedVideoEventKind::FrameDrawn &&
             event->generation == 7 && event->frameSequence.value == 1,
         "the main draw proof remains owner-observable");
}

void testPreviewQuiesceIsSupersededByCommitFlush() {
  Fixture fixture;
  expect(fixture.consumer->armFirstGeneration(7) ==
             NativeVideoConsumerArmProgress::Done,
         "preview commit fixture arms");
  expect(NativeVideoConsumerTestAccess::installSchedulerGeneration(
             *fixture.consumer, timeline(7, {0, 1})),
         "preview commit fixture installs");
  expect(fixture.consumer->quiesceForPreview(7) ==
             NativeVideoConsumerPreviewProgress::Done,
         "preview commit fixture quiesces");

  expect(fixture.consumer->flush(7, 8, timeline(8, {2, 1})) ==
             media::NativeMediaConsumerProgress::Done,
         "normal commit seek flush supersedes preview quiescence");
  const auto facts = fixture.consumer->facts();
  expect(facts.generation == 8 && !facts.previewQuiesceStarted &&
             !facts.previewQuiesced &&
             facts.previewQuiesceGeneration == 0 &&
             facts.previewReleasedGeneration == 0 &&
             !facts.previewResumeNeedsKeyFrame &&
             facts.output.generation == 8,
         "commit flush clears every preview gate fact at its new generation");
}

void testQuiescingDestructionRetainsCallbackLifetime() {
  FakeClock clock;
  std::atomic<std::uint64_t> wakes{0};
  auto output = std::make_shared<FakeOutput>(
      NativeTrackedVideoOutputWakeSeam{&wake, &wakes});
  output->setCloseBlocked(true);
  auto lifetime = std::make_shared<int>(9);
  std::weak_ptr<int> observedLifetime = lifetime;
  auto consumer = NativeVideoConsumer::create(
      lifetime, clock.seam(), output,
      NativeVideoConsumerWakeSeam{&wake, &wakes});
  expect(consumer != nullptr, "quarantine fixture creates");
  lifetime.reset();
  consumer.reset();
  expect(!observedLifetime.expired() &&
             NativeVideoConsumer::quarantineFacts().quarantined,
         "quiescing destruction retains every callback context");

  auto recovered = NativeVideoConsumer::recoverQuarantined();
  expect(recovered != nullptr, "the bounded quarantine is recoverable");
  output->setCloseBlocked(false);
  expect(recovered->close() == media::NativeMediaConsumerProgress::Done,
         "recovered exact close reaches Done");
  recovered.reset();
  expect(observedLifetime.expired() &&
             !NativeVideoConsumer::quarantineFacts().quarantined,
         "Done close releases the external callback lifetime");
}

// The process admits kMaximumConcurrentPlayerWindows graphs at once, one per
// open player window, and a graph occupies its slot from create() until that
// same graph proves a Done close -- quarantine included, because a quarantined
// graph still owns its decoder, surfaces and callback contexts. This walks the
// whole boundary: N admitted, N + 1 refused with the documented text, the
// envelope still full while one of the N sits in quarantine, and the slot
// reopening only once that graph is recovered and closed Done.
void testBoundedProcessGraphEnvelope() {
  FakeClock clock;
  std::atomic<std::uint64_t> wakes{0};
  const NativeVideoConsumerWakeSeam consumerWake{&wake, &wakes};

  std::vector<std::shared_ptr<FakeOutput>> outputs;
  std::vector<std::unique_ptr<NativeVideoConsumer>> graphs;
  for (int window = 0; window != kMaximumConcurrentPlayerWindows; ++window) {
    outputs.push_back(std::make_shared<FakeOutput>(
        NativeTrackedVideoOutputWakeSeam{&wake, &wakes}));
    graphs.push_back(NativeVideoConsumer::create(
        std::make_shared<int>(window), clock.seam(), outputs.back(),
        consumerWake));
    expect(graphs.back() != nullptr,
           "every window inside the process envelope is admitted");
  }

  auto spareOutput = std::make_shared<FakeOutput>(
      NativeTrackedVideoOutputWakeSeam{&wake, &wakes});
  std::string error;
  auto overflow = NativeVideoConsumer::create(
      std::make_shared<int>(0), clock.seam(), spareOutput, consumerWake,
      &error);
  expect(overflow == nullptr &&
             error == "a native video graph is already retained",
         "the graph past the last window is refused with the documented text");

  // A destructor that cannot prove Done close moves the graph to the registry
  // without giving its slot back, so the envelope stays exactly full.
  outputs.back()->setCloseBlocked(true);
  graphs.back().reset();
  graphs.pop_back();
  expect(NativeVideoConsumer::quarantineFacts().quarantined,
         "a graph that cannot close Done enters the quarantine registry");
  error.clear();
  auto refusedByQuarantine = NativeVideoConsumer::create(
      std::make_shared<int>(0), clock.seam(), spareOutput, consumerWake,
      &error);
  expect(refusedByQuarantine == nullptr &&
             error == "a native video graph is already retained",
         "a quarantined graph keeps consuming its slot in the envelope");

  auto recovered = NativeVideoConsumer::recoverQuarantined();
  expect(recovered != nullptr,
         "the bounded registry hands the quarantined graph back");
  outputs.back()->setCloseBlocked(false);
  expect(recovered->close() == media::NativeMediaConsumerProgress::Done,
         "the recovered graph reaches Done once its output unblocks");
  recovered.reset();
  expect(!NativeVideoConsumer::quarantineFacts().quarantined,
         "a Done close empties the slot the quarantined graph occupied");

  auto replacement = NativeVideoConsumer::create(
      std::make_shared<int>(0), clock.seam(), spareOutput, consumerWake);
  expect(replacement != nullptr,
         "the slot reopens only after the quarantined graph proves Done");
  expect(replacement->close() == media::NativeMediaConsumerProgress::Done,
         "the replacement graph closes cleanly");
  replacement.reset();

  for (std::unique_ptr<NativeVideoConsumer>& graph : graphs) {
    expect(graph->close() == media::NativeMediaConsumerProgress::Done,
           "every remaining window closes with exact invalidation proof");
  }
  graphs.clear();
}

}  // namespace

int main() {
  testArmContract();
  testDelayedLifecycleDiagnostic();
  testCloseRetiresQuiescingArm();
  testExactRetirementGapAndPairOwnership();
  testArmOnlyAndPendingArmRetirement();
  testRetirementSupersedesPendingSeek();
  testQuiescingRetirementKeepsExactPair();
  testMatchedFrameFailureRetiresExactly();
  testExactTimeMath();
  testOpenGopLeadingPictureDiscard();
  testSelectedDurationAdmission();
  testDrawAckGatesNextFrame();
  testFailedFrameRetiresExactCredit();
  testFailedFrameSupersedesPendingFlushOnClose();
  testHalfOpenFloorAndProvenLateDrop();
  testPreviewQuiesceGatesAndRequiresKeyFrameRelease();
  testPreviewQuiesceWaitsForRealTrackedDraw();
  testPreviewQuiesceIsSupersededByCommitFlush();
  testQuiescingDestructionRetainsCallbackLifetime();
  testBoundedProcessGraphEnvelope();
  testMalformedFailureCannotAuthorizeClose();
  std::cout << "native video consumer fixture-free checks passed\n";
  return EXIT_SUCCESS;
}
