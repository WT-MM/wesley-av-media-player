#include "qt/native_video_controller.hpp"

#include <cstdlib>
#include <deque>
#include <iostream>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

namespace {

using namespace wam::native_activation;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    ++failures;
    std::cerr << "FAIL: " << message << '\n';
  }
}

struct ScriptedResult {
  NativeVideoDriverStatus status{NativeVideoDriverStatus::Pending};
  ActionCompletion completion;
};

struct DriverState {
  std::vector<Action> calls;
  std::deque<ScriptedResult> executeResults;
  std::deque<NativeVideoDriverDispatch> events;
  std::uint64_t pollCalls{0};
};

class FakeDriver final : public NativeVideoActionDriver {
public:
  explicit FakeDriver(std::shared_ptr<DriverState> state)
      : state_(std::move(state)) {}

  NativeVideoDriverDispatch execute(const Action &action) noexcept override {
    state_->calls.push_back(action);
    ScriptedResult scripted;
    if (!state_->executeResults.empty()) {
      scripted = state_->executeResults.front();
      state_->executeResults.pop_front();
    }
    return {scripted.status, action, scripted.completion};
  }

  std::optional<NativeVideoDriverDispatch> poll() noexcept override {
    ++state_->pollCalls;
    if (state_->events.empty())
      return std::nullopt;
    NativeVideoDriverDispatch result = state_->events.front();
    state_->events.pop_front();
    return result;
  }

private:
  std::shared_ptr<DriverState> state_;
};

ScriptedResult completed(ActionCompletion completion = {}) {
  return {NativeVideoDriverStatus::Completed, std::move(completion)};
}

ScriptedResult pending() { return {}; }

ActionCompletion pausedAt(double position = 0.0) {
  ActionCompletion result;
  result.liveTransport = Transport{position, 1.0, true};
  return result;
}

ActionCompletion revokedAt(std::uint64_t generation) {
  ActionCompletion result;
  result.preRevokeGeneration = generation;
  return result;
}

ActionCompletion stoppedAt(std::uint64_t generation) {
  ActionCompletion result;
  result.invalidationGeneration = generation;
  return result;
}

MpvReady ready(std::uint64_t sourceKey = 22) {
  MpvReady result;
  result.entry = 7;
  result.sourceKey = sourceKey;
  result.videoId = 3;
  result.live = Transport{0.0, 1.0, true};
  result.singletonPlaylist = true;
  result.authoritativeAudio = true;
  result.subtitleFree = true;
  result.exactlyOneNonAlbumartVideo = true;
  result.belongsToRequestLineage = true;
  return result;
}

std::unique_ptr<NativeVideoController>
controller(const std::shared_ptr<DriverState> &state,
           NativeVideoController::DeadlinePolicy deadlines = {}) {
  return std::make_unique<NativeVideoController>(
      std::make_unique<FakeDriver>(state), true, deadlines);
}

Token beginThroughPendingPrepare(NativeVideoController &runner,
                                 DriverState &state) {
  state.executeResults.push_back(completed(pausedAt()));
  state.executeResults.push_back(completed(revokedAt(5)));
  state.executeResults.push_back(completed());
  state.executeResults.push_back(pending());
  const std::optional<Token> token = runner.begin(11, 22, Transport{});
  expect(token.has_value(), "enabled runner begins an exact attempt");
  expect(state.calls.size() == 4 &&
             state.calls[0].kind == Action::Kind::ForcePauseMpv &&
             state.calls[1].kind == Action::Kind::RevokeMpvRenderer &&
             state.calls[2].kind == Action::Kind::LoadMpvAudioOnly &&
             state.calls[3].kind == Action::Kind::PrepareNative,
         "synchronous startup drains in exact order to first Pending");
  expect(runner.issuedAction() == state.calls.back(),
         "first Pending action retains capacity-one ownership");
  return token.value_or(Token{});
}

Token activate(NativeVideoController &runner, DriverState &state,
               std::uint64_t request = 20) {
  state.executeResults.push_back(completed(pausedAt()));
  state.executeResults.push_back(completed(revokedAt(5)));
  state.executeResults.push_back(completed());
  state.executeResults.push_back(completed());
  const Token token = runner.begin(request, 22, Transport{}).value_or(Token{});
  runner.nativePrepared(token, 8);
  runner.mpvReady(token, ready());

  state.executeResults.push_back(pending());
  runner.evaluateRelease(token, false, false, true, 5);
  const Action start = runner.issuedAction().value_or(Action{});
  ActionCompletion started;
  started.generation = 8;
  started.drawBaseline = 10;
  state.events.push_back({NativeVideoDriverStatus::Completed, start, started});
  expect(runner.poll(), "active helper completes exact native Start");

  state.executeResults.push_back(completed());
  NativeSample sample;
  sample.active = true;
  sample.generation = 8;
  sample.acceptedGeneration = 8;
  sample.lastRenderedGeneration = 8;
  sample.acceptedRenderedFrames = 11;
  runner.sampleNative(token, sample);
  expect(runner.snapshot().phase == Phase::Active,
         "active helper gates transport until exact first native draw");
  return token;
}

void driveFallbackActive(NativeVideoController &runner, DriverState &state,
                         Token token) {
  state.executeResults.push_back(completed(pausedAt(4.0)));
  state.executeResults.push_back(completed(stoppedAt(9)));
  state.executeResults.push_back(completed());
  runner.beginFallback(token, FallbackReason::NativeFailure);
  expect(runner.snapshot().phase == Phase::FallbackAwaitRenderer,
         "fallback helper stops native and restores renderer permission");
  runner.mpvReady(token, ready());
  state.executeResults.push_back(completed());
  runner.fallbackRenderReady(token, 40);
  state.executeResults.push_back(completed());
  runner.fallbackPlaybackRestart(token, 40, 7, 4.0);
  expect(runner.snapshot().phase == Phase::FallbackActive,
         "fallback helper converges exact renderer restart and transport");
}

void testDisabledIsZeroWork() {
  auto state = std::make_shared<DriverState>();
  NativeVideoController runner(std::make_unique<FakeDriver>(state));
  expect(!runner.begin(1, 2, Transport{}),
         "default-disabled runner rejects activation");
  expect(!runner.pump() && !runner.poll() && !runner.tick(100),
         "disabled runner rejects every work source");
  expect(state->calls.empty() && state->pollCalls == 0 &&
             !runner.issuedAction(),
         "default-disabled runner performs zero driver work");
}

void testSynchronousDrainDedupeAndExactCompletion() {
  auto state = std::make_shared<DriverState>();
  auto runner = controller(state);
  const Token token = beginThroughPendingPrepare(*runner, *state);
  const Action prepare = *runner->issuedAction();
  expect(!runner->pump() && state->calls.size() == 4,
         "repeated pump never duplicates an issued mutation");

  Action wrong = prepare;
  ++wrong.serial;
  state->events.push_back(
      {NativeVideoDriverStatus::Completed, wrong, ActionCompletion{}});
  expect(!runner->poll() && runner->issuedAction() == prepare,
         "mismatched completion is inert and retains exact flight");

  state->events.push_back(
      {NativeVideoDriverStatus::Completed, prepare, ActionCompletion{}});
  expect(runner->poll() && !runner->issuedAction(),
         "exact completion is consumed once");
  expect(!runner->poll(), "consumed completion cannot replay");

  runner->nativePrepared(token, 8);
  runner->mpvReady(token, ready());
  expect(runner->snapshot().phase == Phase::AwaitRelease,
         "full ingress converges preparation without bypassing runner");
  state->executeResults.push_back(pending());
  runner->evaluateRelease(token, false, false, true, 5);
  expect(runner->issuedAction() &&
             runner->issuedAction()->kind == Action::Kind::StartNative &&
             state->calls.size() == 5,
         "settled renderer release issues one native Start");

  runner->nativePrepared(Token{token.request, token.attempt + 1}, 9);
  expect(state->calls.size() == 5 &&
             runner->issuedAction()->kind == Action::Kind::StartNative,
         "late old-token facts are inert while Start owns the slot");
}

void testCancelWaitsForExactFlightThenCleansUp() {
  auto state = std::make_shared<DriverState>();
  auto runner = controller(state);
  const Token token = beginThroughPendingPrepare(*runner, *state);
  const Action prepare = *runner->issuedAction();
  const Action retained = runner->cancel(CancelMode::Stop);
  expect(retained == prepare && runner->issuedAction() == prepare &&
             state->calls.size() == 4,
         "cancel never overwrites an in-flight Prepare");

  state->executeResults.push_back(pending());
  state->events.push_back(
      {NativeVideoDriverStatus::Completed, prepare, ActionCompletion{}});
  expect(runner->poll() && runner->issuedAction() &&
             runner->issuedAction()->kind == Action::Kind::StopNative &&
             state->calls.size() == 5,
         "exact Prepare acknowledgement serializes cancel into Stop");
  expect(runner->snapshot().cancelPending &&
             runner->snapshot().nativeRequestIssued,
         "physical native ownership remains explicit until Stop completes");

  runner->nativeFailed(token);
  expect(state->calls.size() == 5 &&
             runner->issuedAction()->kind == Action::Kind::StopNative,
         "burned-token callback cannot displace cancel cleanup");
}

void testDeadlinesNeverFabricateCompletion() {
  const NativeVideoController::DeadlinePolicy deadlines{10, 10, 16};
  {
    auto state = std::make_shared<DriverState>();
    auto runner = controller(state, deadlines);
    expect(!runner->tick(100), "first monotonic tick establishes a baseline");
    static_cast<void>(beginThroughPendingPrepare(*runner, *state));
    const Action prepare = *runner->issuedAction();
    static_cast<void>(runner->cancel(CancelMode::Stop));
    state->executeResults.push_back(pending());
    state->events.push_back(
        {NativeVideoDriverStatus::Completed, prepare, ActionCompletion{}});
    expect(runner->poll() && runner->issuedAction() &&
               runner->issuedAction()->kind == Action::Kind::StopNative,
           "deadline test reaches an exact in-flight Stop");
    const Action stop = *runner->issuedAction();
    const std::size_t calls = state->calls.size();
    expect(runner->tick(111) && runner->deadlineLatched() &&
               runner->issuedAction() == stop && state->calls.size() == calls,
           "Stop timeout latches failure without completing or allowing");
    expect(!runner->tick(122) && runner->issuedAction() == stop &&
               state->calls.size() == calls,
           "latched in-flight timeout neither retries nor recurses");

    runner->setDesiredRate(runner->snapshot().token.value_or(Token{}), 1.5);
    expect(!runner->tick(133) && runner->issuedAction() == stop &&
               state->calls.size() == calls,
           "unrelated user intent cannot rearm one timed-out Stop serial");

    state->executeResults.push_back(completed());
    state->events.push_back(
        {NativeVideoDriverStatus::Completed, stop, stoppedAt(12)});
    expect(runner->poll() && runner->snapshot().phase == Phase::Idle &&
               !runner->snapshot().rendererDenied && !runner->issuedAction(),
           "real Stop completion still orders Allow and settles cancel Idle");
  }

  {
    auto state = std::make_shared<DriverState>();
    auto runner = controller(state, deadlines);
    expect(!runner->tick(50), "actionless deadline starts from a known tick");
    state->executeResults.push_back(completed(pausedAt()));
    state->executeResults.push_back(completed(revokedAt(5)));
    state->executeResults.push_back(completed());
    state->executeResults.push_back(completed());
    state->executeResults.push_back(pending());
    const std::optional<Token> token = runner->begin(12, 22, Transport{});
    expect(token && runner->snapshot().phase == Phase::Preparing &&
               !runner->issuedAction() && state->calls.size() == 4,
           "fully admitted preparation can wait actionless for async facts");
    expect(runner->tick(61) && runner->deadlineLatched() &&
               runner->issuedAction() &&
               runner->issuedAction()->kind == Action::Kind::ForcePauseMpv &&
               state->calls.size() == 5,
           "actionless deadline enters coordinator-owned fallback once");
  }
}

void testStablePlaybackPhasesNeverExpire() {
  const NativeVideoController::DeadlinePolicy deadlines{10, 10, 16};
  {
    auto state = std::make_shared<DriverState>();
    auto runner = controller(state, deadlines);
    expect(!runner->tick(100), "Active stability test establishes clock");
    static_cast<void>(activate(*runner, *state, 30));
    const std::size_t calls = state->calls.size();
    expect(!runner->tick(1000) && runner->snapshot().phase == Phase::Active &&
               state->calls.size() == calls,
           "healthy actionless Active playback has no deadline");
  }

  {
    auto state = std::make_shared<DriverState>();
    auto runner = controller(state, deadlines);
    expect(!runner->tick(100), "EOF stability test establishes clock");
    const Token token = activate(*runner, *state, 31);
    state->executeResults.push_back(completed());
    runner->eof(token, 7, 20.0);
    expect(runner->snapshot().phase == Phase::EofHeld,
           "EOF helper retains the native frame");
    const std::size_t calls = state->calls.size();
    expect(!runner->tick(1000) && runner->snapshot().phase == Phase::EofHeld &&
               state->calls.size() == calls,
           "retained actionless EOF frame has no deadline");
  }

  {
    auto state = std::make_shared<DriverState>();
    auto runner = controller(state, deadlines);
    expect(!runner->tick(100), "fallback stability test establishes clock");
    const Token token = activate(*runner, *state, 32);
    driveFallbackActive(*runner, *state, token);
    const std::size_t calls = state->calls.size();
    expect(!runner->tick(1000) &&
               runner->snapshot().phase == Phase::FallbackActive &&
               state->calls.size() == calls,
           "stable libmpv fallback playback has no deadline");
  }
}

void testRevocationConsumptionIsDeniedOnly() {
  auto state = std::make_shared<DriverState>();
  auto runner = controller(state);
  const Token token = beginThroughPendingPrepare(*runner, *state);
  expect(runner->snapshot().rendererDenied &&
             runner->snapshot().armedRevocationGeneration == 5,
         "successful revoke arms its generation while renderer is denied");
  expect(runner->consumeExpectedRevocationGeneration(5) &&
             !runner->consumeExpectedRevocationGeneration(5),
         "denied renderer consumes an expected retirement exactly once");

  const Action prepare = *runner->issuedAction();
  state->events.push_back(
      {NativeVideoDriverStatus::Completed, prepare, ActionCompletion{}});
  expect(runner->poll(), "revocation test completes native Prepare action");
  state->executeResults.push_back(completed(pausedAt()));
  state->executeResults.push_back(completed(stoppedAt(10)));
  state->executeResults.push_back(completed());
  runner->nativeUnsupported(token);
  expect(!runner->snapshot().rendererDenied &&
             runner->snapshot().phase == Phase::FallbackAwaitRenderer,
         "fallback safely stops native then restores renderer permission");
  expect(!runner->consumeExpectedRevocationGeneration(5),
         "after Allow, retirement belongs to legacy renderer recovery");
}

void testBoundedDrainFailsClosedWithoutRecursion() {
  auto state = std::make_shared<DriverState>();
  const NativeVideoController::DeadlinePolicy deadlines{100, 100, 2};
  auto runner = controller(state, deadlines);
  state->executeResults.push_back(completed(pausedAt()));
  state->executeResults.push_back(completed(revokedAt(5)));
  state->executeResults.push_back(completed());
  const std::optional<Token> token = runner->begin(13, 22, Transport{});
  expect(token && state->calls.size() == 2 && runner->drainLimitLatched(),
         "synchronous driver chain stops at its hard action bound");
  expect(!runner->issuedAction() && runner->snapshot().pendingAction &&
             runner->snapshot().pendingAction->kind ==
                 Action::Kind::LoadMpvAudioOnly &&
             runner->snapshot().fallbackReason == FallbackReason::Mismatch,
         "bound overflow fails closed while retaining coordinator ownership");
}

} // namespace

int main() {
  testDisabledIsZeroWork();
  testSynchronousDrainDedupeAndExactCompletion();
  testCancelWaitsForExactFlightThenCleansUp();
  testDeadlinesNeverFabricateCompletion();
  testStablePlaybackPhasesNeverExpire();
  testRevocationConsumptionIsDeniedOnly();
  testBoundedDrainFailsClosedWithoutRecursion();
  if (failures != 0) {
    std::cerr << failures << " native video controller assertion(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native video controller tests passed\n";
  return EXIT_SUCCESS;
}
