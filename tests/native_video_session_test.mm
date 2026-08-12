#include "platform/macos/native_video_session.hpp"

#include <QCoreApplication>
#include <QThread>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>

namespace {

using wam::macos::FrameLease;
using wam::macos::NativeScheduledFrameDispatchResult;
using wam::macos::NativeScheduledFrameOutput;
using wam::macos::NativeScheduledFrameOutputStats;
using wam::macos::NativeVideoOutputMode;
using wam::macos::NativeVideoPipelineStats;
using wam::macos::NativeVideoPrepareOutcome;
using wam::macos::NativeVideoPrepareResult;
using wam::macos::NativeVideoSession;
using wam::macos::NativeVideoSessionDispatchStatus;
using wam::macos::NativeVideoSessionEventKind;
using wam::macos::NativeVideoSessionPipeline;
using wam::native_activation::Action;
using wam::native_activation::Token;
using wam::native_activation::Transport;

int failures = 0;

void expect(bool condition, const char *message) {
  if (condition) {
    return;
  }
  ++failures;
  std::cerr << "FAIL: " << message << '\n';
}

struct FakeOutputState {
  NativeScheduledFrameOutputStats stats;
  bool flushSucceeds{true};
  std::uint64_t lastFlush{0};
  std::uint64_t flushCalls{0};
  std::uint64_t closeCalls{0};
};

class FakeOutput final : public NativeScheduledFrameOutput {
public:
  explicit FakeOutput(std::shared_ptr<FakeOutputState> state)
      : state_(std::move(state)) {}

  NativeScheduledFrameDispatchResult dispatch(FrameLease,
                                              std::string *) noexcept override {
    return NativeScheduledFrameDispatchResult::Rejected;
  }

  bool startGeneration(std::uint64_t generation, StartAppliedHandler applied,
                       std::string *) noexcept override {
    if (!flush(generation, nullptr) || !applied) {
      return false;
    }
    applied({generation, generation, state_->stats.acceptedRenderedFrames});
    return true;
  }

  bool flush(std::uint64_t generation, std::string *error) noexcept override {
    ++state_->flushCalls;
    state_->lastFlush = generation;
    if (!state_->flushSucceeds || state_->stats.closed ||
        generation <= state_->stats.acceptedGeneration) {
      if (error != nullptr) {
        *error = "injected output flush failure";
      }
      return false;
    }
    state_->stats.acceptedGeneration = generation;
    return true;
  }

  void close(std::uint64_t generation) noexcept override {
    ++state_->closeCalls;
    state_->stats.acceptedGeneration =
        std::max(state_->stats.acceptedGeneration, generation);
    state_->stats.closed = true;
  }

  void setFailureHandler(FailureHandler) noexcept override {}

  NativeScheduledFrameOutputStats stats() const noexcept override {
    return state_->stats;
  }

private:
  std::shared_ptr<FakeOutputState> state_;
};

struct FakePipelineState {
  NativeVideoPipelineStats stats;
  bool prepareAccepted{true};
  std::filesystem::path preparedPath;
  double preparedPosition{-1.0};
  std::optional<NativeVideoPrepareOutcome> prepareOutcome;
  std::optional<std::uint64_t> startResult;
  std::uint64_t stopResult{0};
  bool stopQuiesces{true};
  std::optional<std::uint64_t> seekResult;
  double seekPosition{-1.0};
  Transport clock;
  std::uint64_t prepareCalls{0};
  std::uint64_t startCalls{0};
  std::uint64_t stopCalls{0};
  std::uint64_t seekCalls{0};
  std::uint64_t clockCalls{0};
  std::optional<std::string> error;
};

class FakePipeline final : public NativeVideoSessionPipeline {
public:
  explicit FakePipeline(std::shared_ptr<FakePipelineState> state)
      : state_(std::move(state)) {}

  bool prepareLocalFileAsync(const std::filesystem::path &path, double position,
                             std::string *) override {
    ++state_->prepareCalls;
    state_->preparedPath = path;
    state_->preparedPosition = position;
    if (state_->prepareAccepted) {
      state_->stats.prepared = false;
    }
    return state_->prepareAccepted;
  }

  std::optional<NativeVideoPrepareOutcome>
  takePrepareResult() noexcept override {
    std::optional<NativeVideoPrepareOutcome> result =
        std::move(state_->prepareOutcome);
    state_->prepareOutcome.reset();
    return result;
  }

  std::optional<std::uint64_t> startPrepared(std::string *) noexcept override {
    ++state_->startCalls;
    return state_->startResult;
  }

  std::uint64_t stop() noexcept override {
    ++state_->stopCalls;
    if (state_->stopQuiesces) {
      state_->stats.prepared = false;
      state_->stats.active = false;
      state_->stats.stopping = false;
      state_->stats.queueDepth = 0;
    }
    return state_->stopResult;
  }

  void updateAudioClock(double position, bool paused,
                        double rate) noexcept override {
    ++state_->clockCalls;
    state_->clock = Transport{position, rate, paused};
  }

  std::optional<std::uint64_t> seek(double position) noexcept override {
    ++state_->seekCalls;
    state_->seekPosition = position;
    return state_->seekResult;
  }

  std::optional<std::string> takeLastError() noexcept override {
    std::optional<std::string> result = std::move(state_->error);
    state_->error.reset();
    return result;
  }

  NativeVideoPipelineStats stats() const noexcept override {
    return state_->stats;
  }

private:
  std::shared_ptr<FakePipelineState> state_;
};

// The regular fakes above are intentionally simple because every test using
// them is owner-thread confined. These narrower fakes use atomics so the
// destructor regression can observe its teardown only after joining the
// destroying thread without introducing a data race into the test itself.
struct ForeignDestructorOrderState {
  std::atomic<bool> armed{false};
  std::atomic<std::uint64_t> next{0};
  std::atomic<std::uint64_t> stop{0};
  std::atomic<std::uint64_t> pipelineStats{0};
  std::atomic<std::uint64_t> outputStats{0};
  std::atomic<std::uint64_t> close{0};

  void record(std::atomic<std::uint64_t> &slot) noexcept {
    if (armed.load()) {
      slot = next.fetch_add(1) + 1;
    }
  }
};

struct ForeignDestructorOutputState {
  const std::thread::id ownerThread{std::this_thread::get_id()};
  std::shared_ptr<ForeignDestructorOrderState> order;
  std::atomic<std::uint64_t> acceptedGeneration{0};
  std::atomic<std::uint64_t> closeGeneration{0};
  std::atomic<std::uint64_t> dispatchCalls{0};
  std::atomic<std::uint64_t> startGenerationCalls{0};
  std::atomic<std::uint64_t> flushCalls{0};
  std::atomic<std::uint64_t> closeCalls{0};
  std::atomic<std::uint64_t> setFailureHandlerCalls{0};
  std::atomic<std::uint64_t> statsCalls{0};
  std::atomic<std::uint64_t> offOwnerStatsCalls{0};
  std::atomic<bool> closed{false};
  std::atomic<bool> closeRanOffOwnerThread{false};
};

class ForeignDestructorOutput final : public NativeScheduledFrameOutput {
public:
  explicit ForeignDestructorOutput(
      std::shared_ptr<ForeignDestructorOutputState> state)
      : state_(std::move(state)) {}

  NativeScheduledFrameDispatchResult dispatch(FrameLease,
                                              std::string *) noexcept override {
    ++state_->dispatchCalls;
    return NativeScheduledFrameDispatchResult::Rejected;
  }

  bool startGeneration(std::uint64_t, StartAppliedHandler,
                       std::string *) noexcept override {
    ++state_->startGenerationCalls;
    return false;
  }

  bool flush(std::uint64_t, std::string *) noexcept override {
    ++state_->flushCalls;
    return false;
  }

  void close(std::uint64_t generation) noexcept override {
    ++state_->closeCalls;
    state_->order->record(state_->order->close);
    state_->closeGeneration = generation;
    state_->acceptedGeneration = generation;
    state_->closed = true;
    state_->closeRanOffOwnerThread =
        std::this_thread::get_id() != state_->ownerThread;
  }

  void setFailureHandler(FailureHandler) noexcept override {
    ++state_->setFailureHandlerCalls;
  }

  NativeScheduledFrameOutputStats stats() const noexcept override {
    ++state_->statsCalls;
    if (std::this_thread::get_id() != state_->ownerThread) {
      ++state_->offOwnerStatsCalls;
    }
    state_->order->record(state_->order->outputStats);
    NativeScheduledFrameOutputStats result;
    result.acceptedGeneration = state_->acceptedGeneration.load();
    result.closed = state_->closed.load();
    return result;
  }

private:
  std::shared_ptr<ForeignDestructorOutputState> state_;
};

struct ForeignDestructorPipelineState {
  const std::thread::id ownerThread{std::this_thread::get_id()};
  std::shared_ptr<ForeignDestructorOrderState> order;
  std::atomic<std::uint64_t> generation{0};
  std::atomic<std::uint64_t> stopResult{0};
  std::atomic<std::uint64_t> prepareCalls{0};
  std::atomic<std::uint64_t> takePrepareResultCalls{0};
  std::atomic<std::uint64_t> startCalls{0};
  std::atomic<std::uint64_t> stopCalls{0};
  std::atomic<std::uint64_t> clockCalls{0};
  std::atomic<std::uint64_t> seekCalls{0};
  std::atomic<std::uint64_t> takeLastErrorCalls{0};
  std::atomic<std::uint64_t> statsCalls{0};
  std::atomic<std::uint64_t> offOwnerStatsCalls{0};
  std::atomic<bool> stopRanOffOwnerThread{false};
};

class ForeignDestructorPipeline final : public NativeVideoSessionPipeline {
public:
  explicit ForeignDestructorPipeline(
      std::shared_ptr<ForeignDestructorPipelineState> state)
      : state_(std::move(state)) {}

  bool prepareLocalFileAsync(const std::filesystem::path &, double,
                             std::string *) override {
    ++state_->prepareCalls;
    return false;
  }

  std::optional<NativeVideoPrepareOutcome>
  takePrepareResult() noexcept override {
    ++state_->takePrepareResultCalls;
    return std::nullopt;
  }

  std::optional<std::uint64_t>
  startPrepared(std::string *) noexcept override {
    ++state_->startCalls;
    return std::nullopt;
  }

  std::uint64_t stop() noexcept override {
    ++state_->stopCalls;
    state_->order->record(state_->order->stop);
    state_->stopRanOffOwnerThread =
        std::this_thread::get_id() != state_->ownerThread;
    return state_->stopResult.load();
  }

  void updateAudioClock(double, bool, double) noexcept override {
    ++state_->clockCalls;
  }

  std::optional<std::uint64_t> seek(double) noexcept override {
    ++state_->seekCalls;
    return std::nullopt;
  }

  std::optional<std::string> takeLastError() noexcept override {
    ++state_->takeLastErrorCalls;
    return std::nullopt;
  }

  NativeVideoPipelineStats stats() const noexcept override {
    ++state_->statsCalls;
    if (std::this_thread::get_id() != state_->ownerThread) {
      ++state_->offOwnerStatsCalls;
    }
    state_->order->record(state_->order->pipelineStats);
    NativeVideoPipelineStats result;
    result.generation = state_->generation.load();
    return result;
  }

private:
  std::shared_ptr<ForeignDestructorPipelineState> state_;
};

struct Fixture {
  Token token{11, 3};
  std::shared_ptr<FakeOutputState> outputState{
      std::make_shared<FakeOutputState>()};
  std::shared_ptr<FakePipelineState> pipelineState{
      std::make_shared<FakePipelineState>()};
  std::shared_ptr<FakeOutput> output{std::make_shared<FakeOutput>(outputState)};
  std::unique_ptr<NativeVideoSession> session;

  Fixture() {
    pipelineState->stats.outputMode = NativeVideoOutputMode::QtOpenGL;
    std::string error;
    session = NativeVideoSession::createForTesting(
        token, "/tmp/video.mp4", output,
        std::make_unique<FakePipeline>(pipelineState), QThread::currentThread(),
        &error);
    expect(session != nullptr, "fake session is created");
    expect(error.empty(), "fake session creation has no error");
  }
};

Action action(Action::Kind kind, Token token, std::uint64_t serial) {
  Action result;
  result.kind = kind;
  result.token = token;
  result.serial = serial;
  return result;
}

void prepareReady(Fixture &fixture, std::uint64_t generation = 5) {
  const Action prepare = action(Action::Kind::PrepareNative, fixture.token, 1);
  const auto admitted = fixture.session->execute(prepare);
  expect(admitted.status == NativeVideoSessionDispatchStatus::Completed &&
             admitted.completion.succeeded,
         "preparation admission completes successfully");
  expect(fixture.pipelineState->prepareCalls == 1 &&
             fixture.pipelineState->preparedPosition == 0.0 &&
             fixture.pipelineState->preparedPath == "/tmp/video.mp4",
         "preparation forwards the bound source at zero");
  fixture.pipelineState->stats.prepared = true;
  fixture.pipelineState->stats.generation = generation;
  fixture.pipelineState->prepareOutcome = NativeVideoPrepareOutcome{
      generation, NativeVideoPrepareResult::Ready, {}};
  const auto event = fixture.session->poll();
  expect(event && event->kind == NativeVideoSessionEventKind::Prepared &&
             event->token == fixture.token && event->generation == generation,
         "ready preparation outcome is exact-token tagged");
}

void testUnsupportedStopAlwaysAdvances() {
  Fixture fixture;
  fixture.pipelineState->stopResult = 0;
  const Action stop = action(Action::Kind::StopNative, fixture.token, 1);
  const auto dispatched = fixture.session->execute(stop);
  expect(dispatched.status == NativeVideoSessionDispatchStatus::Pending,
         "unsupported/no-frame stop remains an asynchronous action");
  const auto completed = fixture.session->poll();
  expect(completed &&
             completed->kind == NativeVideoSessionEventKind::ActionCompleted &&
             completed->action == stop && completed->completion.succeeded &&
             completed->completion.invalidationGeneration == 1,
         "zero pipeline stop produces fresh nonzero output invalidation");
  expect(fixture.outputState->flushCalls == 1 &&
             fixture.outputState->lastFlush == 1 &&
             fixture.outputState->stats.acceptedGeneration == 1,
         "stop synchronously proves exact output generation");
  const auto duplicate = fixture.session->execute(stop);
  expect(duplicate.status == NativeVideoSessionDispatchStatus::Completed &&
             duplicate.completion.invalidationGeneration == 1 &&
             fixture.outputState->flushCalls == 1,
         "repeated exact stop serial is idempotent");
}

void testStopWaitsForQuiescenceAndUsesEveryHighWater() {
  Fixture fixture;
  fixture.pipelineState->stopResult = 4;
  fixture.pipelineState->stopQuiesces = false;
  fixture.pipelineState->stats.generation = 5;
  fixture.pipelineState->stats.stopping = true;
  fixture.outputState->stats.acceptedGeneration = 6;
  const Action stop = action(Action::Kind::StopNative, fixture.token, 9);
  expect(fixture.session->execute(stop).status ==
             NativeVideoSessionDispatchStatus::Pending,
         "stop enters Pending while retirement owns resources");
  expect(!fixture.session->poll() && fixture.outputState->flushCalls == 0,
         "stop never flushes/completes before retirement quiesces");
  fixture.pipelineState->stats.stopping = false;
  fixture.pipelineState->stats.active = false;
  fixture.pipelineState->stats.prepared = false;
  fixture.pipelineState->stats.queueDepth = 0;
  const auto event = fixture.session->poll();
  expect(
      event && event->completion.succeeded &&
          event->completion.invalidationGeneration == 7,
      "stop advances beyond pipeline return/stats/output/session high-water");
}

void testStopFailsClosedOnFatalAndExhaustion() {
  {
    Fixture fixture;
    fixture.outputState->stats.fatalErrorSerial = 1;
    const Action stop = action(Action::Kind::StopNative, fixture.token, 1);
    (void)fixture.session->execute(stop);
    const auto event = fixture.session->poll();
    expect(event && !event->completion.succeeded &&
               event->completion.invalidationGeneration == 0,
           "output fatal change fails stop closed");
  }
  {
    Fixture fixture;
    fixture.outputState->stats.acceptedGeneration =
        std::numeric_limits<std::uint64_t>::max();
    const Action stop = action(Action::Kind::StopNative, fixture.token, 1);
    (void)fixture.session->execute(stop);
    const auto event = fixture.session->poll();
    expect(event && !event->completion.succeeded &&
               fixture.outputState->flushCalls == 0,
           "generation exhaustion never wraps or fabricates a stop");
  }
}

void testPreparationTokenAndSerialSafety() {
  Fixture fixture;
  Action stale = action(Action::Kind::PrepareNative, Token{99, 1}, 1);
  expect(fixture.session->execute(stale).status ==
                 NativeVideoSessionDispatchStatus::Rejected &&
             fixture.pipelineState->prepareCalls == 0,
         "wrong-token preparation is inert");
  expect(!fixture.session->takeLastError(),
         "wrong-token preparation cannot pollute current-session diagnostics");
  const Action prepare = action(Action::Kind::PrepareNative, fixture.token, 2);
  const auto first = fixture.session->execute(prepare);
  const auto repeated = fixture.session->execute(prepare);
  expect(first.status == NativeVideoSessionDispatchStatus::Completed &&
             repeated.status == first.status &&
             repeated.action == first.action &&
             repeated.completion.succeeded == first.completion.succeeded &&
             fixture.pipelineState->prepareCalls == 1,
         "exact repeated preparation serial never duplicates admission");
  fixture.pipelineState->prepareOutcome = NativeVideoPrepareOutcome{
      0, NativeVideoPrepareResult::Unsupported, "unsupported codec"};
  const auto event = fixture.session->poll();
  expect(event && event->kind == NativeVideoSessionEventKind::Unsupported &&
             event->token == fixture.token,
         "unsupported outcome stays tagged to its exact attempt");
}

void testStartWaitsAndPublishesExactBaseline() {
  Fixture fixture;
  prepareReady(fixture, 5);
  fixture.pipelineState->startResult = 5;
  Action start = action(Action::Kind::StartNative, fixture.token, 2);
  start.value = 5;
  expect(fixture.session->execute(start).status ==
             NativeVideoSessionDispatchStatus::Pending,
         "start is pending until the Qt generation acknowledgment is active");
  fixture.outputState->stats.acceptedGeneration = 5;
  expect(!fixture.session->poll(),
         "prepared-but-inactive startup cannot complete early");

  fixture.pipelineState->stats.active = true;
  fixture.pipelineState->stats.stopping = false;
  fixture.pipelineState->stats.generation = 5;
  fixture.outputState->stats.acceptedGeneration = 5;
  fixture.outputState->stats.acceptedRenderedFrames = 103;
  fixture.outputState->stats.attemptAcceptedRenderedFrames = 3;
  fixture.outputState->stats.lastRenderedGeneration = 5;
  const auto event = fixture.session->poll();
  expect(event && event->kind == NativeVideoSessionEventKind::ActionCompleted &&
             event->action == start && event->completion.succeeded &&
             event->completion.generation == 5 &&
             event->completion.drawBaseline == 100,
         "start reconstructs the exact start-applied render baseline");
  const auto sample = fixture.session->sample(fixture.token);
  expect(sample.active && sample.generation == 5 &&
             sample.acceptedGeneration == 5 &&
             sample.lastRenderedGeneration == 5 &&
             sample.acceptedRenderedFrames == 103 &&
             sample.attemptAcceptedRenderedFrames == 3,
         "sample exposes exact first-draw telemetry without inference");
}

void testStartRejectsStaleOrInvalidTelemetry() {
  Fixture fixture;
  prepareReady(fixture, 8);
  fixture.pipelineState->startResult = 8;
  Action start = action(Action::Kind::StartNative, fixture.token, 2);
  start.value = 8;
  (void)fixture.session->execute(start);
  fixture.pipelineState->stats.active = true;
  fixture.pipelineState->stats.generation = 8;
  fixture.outputState->stats.acceptedGeneration = 8;
  fixture.outputState->stats.acceptedRenderedFrames = 2;
  fixture.outputState->stats.attemptAcceptedRenderedFrames = 3;
  const auto invalid = fixture.session->poll();
  expect(invalid && !invalid->completion.succeeded &&
             invalid->completion.generation == 0,
         "underflowing attempt telemetry fails startup closed");
}

void testStartRejectsImpossibleAcceptedGeneration() {
  Fixture fixture;
  prepareReady(fixture, 8);
  fixture.pipelineState->startResult = 8;
  Action start = action(Action::Kind::StartNative, fixture.token, 2);
  start.value = 8;
  (void)fixture.session->execute(start);
  fixture.outputState->stats.acceptedGeneration = 9;
  const auto invalid = fixture.session->poll();
  expect(invalid && !invalid->completion.succeeded,
         "inactive start fails closed on impossible accepted generation");
}

void testStartRejectsInactiveMismatchedPipelineGeneration() {
  Fixture fixture;
  prepareReady(fixture, 8);
  fixture.pipelineState->startResult = 8;
  Action start = action(Action::Kind::StartNative, fixture.token, 2);
  start.value = 8;
  (void)fixture.session->execute(start);
  fixture.pipelineState->stats.prepared = true;
  fixture.pipelineState->stats.active = false;
  fixture.pipelineState->stats.stopping = false;
  fixture.pipelineState->stats.generation = 9;
  fixture.outputState->stats.acceptedGeneration = 8;
  const auto invalid = fixture.session->poll();
  expect(invalid && invalid->action == start &&
             !invalid->completion.succeeded &&
             fixture.pipelineState->startCalls == 1,
         "inactive start fails immediately on a nonzero mismatched pipeline "
         "generation");
}

void testStopBurnsPendingStart() {
  Fixture fixture;
  prepareReady(fixture, 5);
  fixture.pipelineState->startResult = 5;
  Action start = action(Action::Kind::StartNative, fixture.token, 2);
  start.value = 5;
  (void)fixture.session->execute(start);
  fixture.outputState->stats.acceptedGeneration = 5;
  fixture.pipelineState->stopQuiesces = false;
  fixture.pipelineState->stats.stopping = true;
  const Action stop = action(Action::Kind::StopNative, fixture.token, 3);
  expect(fixture.session->execute(stop).status ==
             NativeVideoSessionDispatchStatus::Pending,
         "new exact stop burns an outstanding start slot");
  fixture.pipelineState->stats.active = true;
  fixture.outputState->stats.acceptedGeneration = 5;
  expect(!fixture.session->poll(),
         "late active startup cannot complete while stop is unquiesced");
  fixture.pipelineState->stats.active = false;
  fixture.pipelineState->stats.prepared = false;
  fixture.pipelineState->stats.stopping = false;
  const auto stopped = fixture.session->poll();
  expect(stopped && stopped->action == stop && stopped->completion.succeeded,
         "only exact stop completion survives a late start");
}

void testPendingStopCannotBeOverwritten() {
  Fixture fixture;
  fixture.pipelineState->stopQuiesces = false;
  fixture.pipelineState->stats.stopping = true;
  const Action first = action(Action::Kind::StopNative, fixture.token, 1);
  const Action second = action(Action::Kind::StopNative, fixture.token, 2);
  (void)fixture.session->execute(first);
  expect(fixture.session->execute(second).status ==
                 NativeVideoSessionDispatchStatus::Rejected &&
             fixture.pipelineState->stopCalls == 1,
         "a different Stop serial cannot overwrite the pending Stop owner");
  fixture.pipelineState->stats.stopping = false;
  const auto event = fixture.session->poll();
  expect(event && event->action == first,
         "the first Stop retains its exact completion identity");
}

void testSeekAndClockForwardCallerTransport() {
  Fixture fixture;
  fixture.pipelineState->stats.active = true;
  fixture.pipelineState->stats.prepared = true;
  fixture.pipelineState->stats.generation = 12;
  fixture.pipelineState->seekResult = 12;
  fixture.outputState->stats.acceptedGeneration = 12;
  fixture.outputState->stats.acceptedRenderedFrames = 44;

  Action seek = action(Action::Kind::SeekNative, fixture.token, 1);
  seek.transport = Transport{23.75, 1.6, false};
  const auto sought = fixture.session->execute(seek);
  expect(sought.status == NativeVideoSessionDispatchStatus::Completed &&
             sought.completion.succeeded &&
             sought.completion.generation == 12 &&
             sought.completion.drawBaseline == 44 &&
             fixture.pipelineState->seekPosition == 23.75,
         "seek forwards exact caller target and publishes exact baseline");
  expect(fixture.pipelineState->clock == Transport{23.75, 1.6, true},
         "seek reanchors the native clock paused regardless of user intent");

  Action clock = action(Action::Kind::UpdateNativeClock, fixture.token, 2);
  clock.transport = Transport{23.75, 1.6, true};
  const auto updated = fixture.session->execute(clock);
  expect(updated.status == NativeVideoSessionDispatchStatus::Completed &&
             updated.completion.succeeded &&
             fixture.pipelineState->clock == clock.transport,
         "clock update forwards caller-supplied paused/rate/position exactly");
}

void testAuthoritativePauseAndRestoreReanchor() {
  Fixture fixture;
  Action pause = action(Action::Kind::ForcePauseMpv, fixture.token, 1);
  const Transport paused{14.25, 1.4, true};
  const auto pauseResult = fixture.session->reanchor(pause, paused);
  expect(pauseResult.status == NativeVideoSessionDispatchStatus::Completed &&
             pauseResult.completion.succeeded &&
             pauseResult.completion.liveTransport == paused &&
             fixture.pipelineState->clock == paused,
         "ForcePause returns and applies authoritative paused transport");
  const auto repeatedPause =
      fixture.session->reanchor(pause, Transport{99.0, 3.0, true});
  expect(repeatedPause.status == pauseResult.status &&
             repeatedPause.action == pauseResult.action &&
             repeatedPause.completion.succeeded ==
                 pauseResult.completion.succeeded &&
             repeatedPause.completion.liveTransport == paused &&
             fixture.pipelineState->clockCalls == 1 &&
             fixture.pipelineState->clock == paused,
         "exact repeated reanchor returns its cached result without a second "
         "clock mutation");

  Action restore = action(Action::Kind::RestoreTransport, fixture.token, 2);
  const Transport restored{14.5, 1.75, false};
  const auto restoreResult = fixture.session->reanchor(restore, restored);
  expect(restoreResult.status == NativeVideoSessionDispatchStatus::Completed &&
             restoreResult.completion.succeeded &&
             fixture.pipelineState->clock == restored,
         "Restore uses authoritative post-restore transport before completion");

  Action stale = action(Action::Kind::RestoreTransport, Token{99, 1}, 3);
  expect(fixture.session->reanchor(stale, Transport{99.0, 2.0, false}).status ==
                 NativeVideoSessionDispatchStatus::Rejected &&
             fixture.pipelineState->clock == restored &&
             !fixture.session->takeLastError(),
         "stale reanchor identity is completely inert");
}

void testFatalChangeAndWrongThreadSafeSample() {
  Fixture fixture;
  fixture.pipelineState->stats.active = true;
  fixture.pipelineState->stats.generation = 2;
  fixture.outputState->stats.acceptedGeneration = 2;
  fixture.outputState->stats.fatalErrorSerial = 1;
  const auto sample = fixture.session->sample(fixture.token);
  expect(sample.failed, "fatal output serial change marks exact sample failed");
  const auto event = fixture.session->poll();
  expect(event && event->kind == NativeVideoSessionEventKind::Failed,
         "fatal output serial change emits one bounded failure event");
  expect(!fixture.session->poll(),
         "terminal failure observation does not enqueue unbounded events");
}

void testOffOwnerThreadActionFailsWithoutMutation() {
  Token token{41, 2};
  auto outputState = std::make_shared<FakeOutputState>();
  auto pipelineState = std::make_shared<FakePipelineState>();
  auto output = std::make_shared<FakeOutput>(outputState);
  QThread foreignOwner;
  std::string error;
  auto session = NativeVideoSession::createForTesting(
      token, "/tmp/video.mp4", output,
      std::make_unique<FakePipeline>(pipelineState), &foreignOwner, &error);
  expect(session != nullptr && error.empty(),
         "foreign-owner test session is created");

  const Action prepare = action(Action::Kind::PrepareNative, token, 1);
  const auto result = session->execute(prepare);
  expect(result.status == NativeVideoSessionDispatchStatus::Rejected &&
             pipelineState->prepareCalls == 0,
         "off-owner-thread action cannot mutate the pipeline");
  expect(session->takeLastError().has_value(),
         "off-owner-thread action leaves a bounded diagnostic");
}

void testDestructorStopsAndClosesFromForeignThread() {
  constexpr std::uint64_t limit =
      std::numeric_limits<std::uint64_t>::max();
  Token token{50, 1};
  auto order = std::make_shared<ForeignDestructorOrderState>();
  auto outputState = std::make_shared<ForeignDestructorOutputState>();
  auto pipelineState = std::make_shared<ForeignDestructorPipelineState>();
  outputState->order = order;
  pipelineState->order = order;
  outputState->acceptedGeneration = limit - 4;
  pipelineState->generation = limit - 3;
  pipelineState->stopResult = limit - 2;

  auto output = std::make_shared<ForeignDestructorOutput>(outputState);
  std::string error;
  auto session = NativeVideoSession::createForTesting(
      token, "/tmp/video.mp4", output,
      std::make_unique<ForeignDestructorPipeline>(pipelineState),
      QThread::currentThread(), &error);
  expect(session != nullptr && error.empty(),
         "foreign-destructor test session is created on its owner thread");

  order->armed = true;
  std::thread destroyer([owned = std::move(session)]() mutable {
    owned.reset();
  });
  destroyer.join();

  expect(pipelineState->stopCalls == 1 &&
             pipelineState->stopRanOffOwnerThread &&
             outputState->closeCalls == 1 &&
             outputState->closeRanOffOwnerThread && outputState->closed,
         "foreign-thread destruction stops and closes exactly once");
  expect(outputState->closeGeneration == limit - 1 &&
             outputState->acceptedGeneration == limit - 1 &&
             outputState->closeGeneration > pipelineState->stopResult,
         "foreign-thread destruction closes on a fresh nonwrapping generation");
  expect(order->next == 4 && order->stop == 1 &&
             order->pipelineStats == 2 && order->outputStats == 3 &&
             order->close == 4 && pipelineState->offOwnerStatsCalls == 1 &&
             outputState->offOwnerStatsCalls == 1,
         "foreign-thread teardown orders stop, snapshots, then output close");
  expect(pipelineState->prepareCalls == 0 &&
             pipelineState->takePrepareResultCalls == 0 &&
             pipelineState->startCalls == 0 && pipelineState->clockCalls == 0 &&
             pipelineState->seekCalls == 0 &&
             pipelineState->takeLastErrorCalls == 0 &&
             outputState->dispatchCalls == 0 &&
             outputState->startGenerationCalls == 0 &&
             outputState->flushCalls == 0 &&
             outputState->setFailureHandlerCalls == 0,
         "destruction invokes no owner-thread action or presentation mutation");
}

void testDestructorStopsAndClosesWithoutGenerationWrap() {
  {
    Token token{51, 1};
    auto outputState = std::make_shared<FakeOutputState>();
    auto pipelineState = std::make_shared<FakePipelineState>();
    auto output = std::make_shared<FakeOutput>(outputState);
    outputState->stats.acceptedGeneration = 8;
    pipelineState->stats.generation = 9;
    pipelineState->stopResult = 10;
    auto session = NativeVideoSession::createForTesting(
        token, "/tmp/video.mp4", output,
        std::make_unique<FakePipeline>(pipelineState),
        QThread::currentThread());
    session.reset();
    expect(pipelineState->stopCalls == 1 && outputState->closeCalls == 1 &&
               outputState->stats.closed &&
               outputState->stats.acceptedGeneration == 11,
           "destructor stops once and closes past every generation high-water");
  }
  {
    Token token{52, 1};
    auto outputState = std::make_shared<FakeOutputState>();
    auto pipelineState = std::make_shared<FakePipelineState>();
    auto output = std::make_shared<FakeOutput>(outputState);
    outputState->stats.acceptedGeneration =
        std::numeric_limits<std::uint64_t>::max();
    auto session = NativeVideoSession::createForTesting(
        token, "/tmp/video.mp4", output,
        std::make_unique<FakePipeline>(pipelineState),
        QThread::currentThread());
    session.reset();
    expect(outputState->closeCalls == 1 && outputState->stats.closed &&
               outputState->stats.acceptedGeneration ==
                   std::numeric_limits<std::uint64_t>::max(),
           "destructor never wraps an exhausted generation");
  }
}

} // namespace

int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  testUnsupportedStopAlwaysAdvances();
  testStopWaitsForQuiescenceAndUsesEveryHighWater();
  testStopFailsClosedOnFatalAndExhaustion();
  testPreparationTokenAndSerialSafety();
  testStartWaitsAndPublishesExactBaseline();
  testStartRejectsStaleOrInvalidTelemetry();
  testStartRejectsImpossibleAcceptedGeneration();
  testStartRejectsInactiveMismatchedPipelineGeneration();
  testStopBurnsPendingStart();
  testPendingStopCannotBeOverwritten();
  testSeekAndClockForwardCallerTransport();
  testAuthoritativePauseAndRestoreReanchor();
  testFatalChangeAndWrongThreadSafeSample();
  testOffOwnerThreadActionFailsWithoutMutation();
  testDestructorStopsAndClosesFromForeignThread();
  testDestructorStopsAndClosesWithoutGenerationWrap();
  if (failures != 0) {
    std::cerr << failures << " native video session assertion(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native video session tests passed\n";
  return EXIT_SUCCESS;
}
