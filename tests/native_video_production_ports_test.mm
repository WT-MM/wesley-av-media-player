#include "platform/macos/native_video_production_ports.hpp"

#include <cstdint>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using wam::macos::AdapterRenderPort;
using wam::macos::AdapterSessionFactory;
using wam::macos::AdapterSessionPort;
using wam::macos::NativeVideoRenderPortTestFunctions;
using wam::macos::NativeVideoSessionDispatch;
using wam::macos::NativeVideoSessionDispatchStatus;
using wam::macos::NativeVideoSessionEvent;
using wam::macos::NativeVideoSessionEventKind;
using wam::macos::NativeVideoSessionFactoryTestFunctions;
using wam::macos::NativeVideoSessionPortTestFunctions;
using wam::native_activation::Action;
using wam::native_activation::ActionCompletion;
using wam::native_activation::NativeSample;
using wam::native_activation::NativeVideoDriverDispatch;
using wam::native_activation::NativeVideoDriverStatus;
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

Action action(Action::Kind kind, std::uint64_t serial) {
  Action result;
  result.kind = kind;
  result.token = Token{41, 9};
  result.serial = serial;
  result.epoch = 12;
  result.value = 13;
  result.videoId = 14;
  result.captionId = 15;
  result.transport = Transport{16.25, 1.5, false};
  return result;
}

ActionCompletion completion() {
  ActionCompletion result;
  result.succeeded = true;
  result.generation = 21;
  result.drawBaseline = 22;
  result.invalidationGeneration = 23;
  result.preRevokeGeneration = 24;
  result.liveTransport = Transport{25.5, 1.25, true};
  return result;
}

bool sameCompletion(const ActionCompletion &left,
                    const ActionCompletion &right) {
  return left.succeeded == right.succeeded &&
         left.generation == right.generation &&
         left.drawBaseline == right.drawBaseline &&
         left.invalidationGeneration == right.invalidationGeneration &&
         left.preRevokeGeneration == right.preRevokeGeneration &&
         left.liveTransport == right.liveTransport;
}

bool sameSample(const NativeSample &left, const NativeSample &right) {
  return left.active == right.active && left.stopping == right.stopping &&
         left.failed == right.failed && left.generation == right.generation &&
         left.acceptedGeneration == right.acceptedGeneration &&
         left.lastRenderedGeneration == right.lastRenderedGeneration &&
         left.acceptedRenderedFrames == right.acceptedRenderedFrames &&
         left.attemptAcceptedRenderedFrames ==
             right.attemptAcceptedRenderedFrames;
}

struct RenderState {
  bool owner{true};
  bool revokeSucceeds{true};
  bool allowSucceeds{true};
  bool updateSucceeds{true};
  std::optional<std::uint64_t> generation{37};
  std::uint64_t ownerCalls{0};
  std::uint64_t snapshotCalls{0};
  std::uint64_t revokeCalls{0};
  std::uint64_t allowCalls{0};
  std::uint64_t updateCalls{0};
  std::vector<std::string> order;
};

NativeVideoRenderPortTestFunctions
renderFunctions(const std::shared_ptr<RenderState> &state) {
  NativeVideoRenderPortTestFunctions result;
  result.onOwnerThread = [state] {
    ++state->ownerCalls;
    state->order.emplace_back("owner");
    return state->owner;
  };
  result.snapshotLifecycleGeneration = [state] {
    ++state->snapshotCalls;
    state->order.emplace_back("snapshot");
    return state->generation;
  };
  result.revokeRenderContext = [state] {
    ++state->revokeCalls;
    state->order.emplace_back("revoke");
    return state->revokeSucceeds;
  };
  result.allowRenderContext = [state] {
    ++state->allowCalls;
    state->order.emplace_back("allow");
    return state->allowSucceeds;
  };
  result.requestVideoUpdate = [state] {
    ++state->updateCalls;
    state->order.emplace_back("update");
    return state->updateSucceeds;
  };
  return result;
}

void testRenderOrderAndOwnerGate() {
  auto state = std::make_shared<RenderState>();
  std::string error;
  std::unique_ptr<AdapterRenderPort> port =
      wam::macos::createNativeVideoRenderPortForTesting(
          renderFunctions(state), &error);
  expect(port != nullptr && error.empty(), "render test port is created");

  expect(port->onOwnerThread(), "render port reports its exact owner gate");
  state->order.clear();
  const std::optional<std::uint64_t> generation =
      port->revokeAndRequestRelease();
  expect(generation == 37, "revoke returns the bare nonzero generation");
  expect(state->snapshotCalls == 1 && state->revokeCalls == 1 &&
             state->updateCalls == 1 &&
             state->order ==
                 std::vector<std::string>{"owner", "snapshot", "revoke",
                                          "update"},
         "revoke takes one exact snapshot immediately before revoke/update");

  state->order.clear();
  expect(port->allowAndRequestAcquire() &&
             state->order ==
                 std::vector<std::string>{"owner", "allow", "update"},
         "allow precedes the scene-graph acquire update");

  state->owner = false;
  state->order.clear();
  expect(!port->revokeAndRequestRelease() &&
             state->order == std::vector<std::string>{"owner"},
         "off-owner revoke is mutation-free");
  state->order.clear();
  expect(!port->allowAndRequestAcquire() &&
             state->order == std::vector<std::string>{"owner"},
         "off-owner allow is mutation-free");
}

void testRenderFailuresAreClosed() {
  auto state = std::make_shared<RenderState>();
  auto port = wam::macos::createNativeVideoRenderPortForTesting(
      renderFunctions(state));

  state->generation = 0;
  expect(!port->revokeAndRequestRelease() && state->revokeCalls == 0 &&
             state->updateCalls == 0,
         "zero lifecycle generation never revokes or requests a frame");
  state->generation = std::nullopt;
  expect(!port->revokeAndRequestRelease() && state->revokeCalls == 0,
         "missing lifecycle generation fails closed");

  state->generation = 38;
  state->revokeSucceeds = false;
  expect(!port->revokeAndRequestRelease() && state->revokeCalls == 1 &&
             state->updateCalls == 0,
         "failed revoke never asks Qt to acquire a new frame");

  state->allowSucceeds = false;
  expect(!port->allowAndRequestAcquire() && state->allowCalls == 1 &&
             state->updateCalls == 0,
         "failed allow never requests an acquire frame");

  NativeVideoRenderPortTestFunctions incomplete;
  std::string error;
  expect(!wam::macos::createNativeVideoRenderPortForTesting(
             std::move(incomplete), &error) &&
             !error.empty(),
         "a render port with null operations is rejected");
}

struct SessionState {
  bool factoryOwner{true};
  bool owner{true};
  bool outputAlive{true};
  std::uint64_t createCalls{0};
  std::uint64_t executeCalls{0};
  std::uint64_t reanchorCalls{0};
  std::uint64_t pollCalls{0};
  std::uint64_t sampleCalls{0};
  Token createdToken;
  std::filesystem::path createdSource;
  Action lastAction;
  Transport lastTransport;
  NativeVideoSessionDispatch nextExecute;
  NativeVideoSessionDispatch nextReanchor;
  NativeSample nextSample;
  std::deque<NativeVideoSessionEvent> events;
};

NativeVideoSessionPortTestFunctions
sessionFunctions(const std::shared_ptr<SessionState> &state) {
  NativeVideoSessionPortTestFunctions result;
  result.onOwnerThread = [state] { return state->owner; };
  result.outputAlive = [state] { return state->outputAlive; };
  result.execute = [state](const Action &value) {
    ++state->executeCalls;
    state->lastAction = value;
    NativeVideoSessionDispatch result = state->nextExecute;
    if (result.action.kind == Action::Kind::None) {
      result.action = value;
    }
    return result;
  };
  result.reanchor = [state](const Action &value, Transport transport) {
    ++state->reanchorCalls;
    state->lastAction = value;
    state->lastTransport = transport;
    NativeVideoSessionDispatch result = state->nextReanchor;
    if (result.action.kind == Action::Kind::None) {
      result.action = value;
    }
    return result;
  };
  result.poll = [state]() -> std::optional<NativeVideoSessionEvent> {
    ++state->pollCalls;
    if (state->events.empty()) {
      return std::nullopt;
    }
    NativeVideoSessionEvent result = state->events.front();
    state->events.pop_front();
    return result;
  };
  result.sample = [state](Token) {
    ++state->sampleCalls;
    return state->nextSample;
  };
  return result;
}

NativeVideoSessionFactoryTestFunctions
factoryFunctions(const std::shared_ptr<SessionState> &state) {
  NativeVideoSessionFactoryTestFunctions result;
  result.onOwnerThread = [state] { return state->factoryOwner; };
  result.outputAlive = [state] { return state->outputAlive; };
  result.create = [state](Token token, const std::filesystem::path &source,
                          std::string *)
      -> std::optional<NativeVideoSessionPortTestFunctions> {
    ++state->createCalls;
    state->createdToken = token;
    state->createdSource = source;
    return sessionFunctions(state);
  };
  return result;
}

std::unique_ptr<AdapterSessionPort>
createSession(const std::shared_ptr<SessionState> &state,
              std::unique_ptr<AdapterSessionFactory> *factoryOut = nullptr) {
  std::string error;
  auto factory = wam::macos::createNativeVideoSessionFactoryForTesting(
      factoryFunctions(state), &error);
  expect(factory != nullptr && error.empty(), "session test factory is made");
  auto session = factory->create(Token{41, 9}, "/tmp/exact.mov", &error);
  expect(session != nullptr && error.empty(), "one session is created");
  expect(state->createCalls == 1 && state->createdToken == Token{41, 9} &&
             state->createdSource == "/tmp/exact.mov",
         "factory forwards the exact token and source");
  if (factoryOut != nullptr) {
    *factoryOut = std::move(factory);
  }
  return session;
}

void testFactoryIsOwnerGatedAndOneShot() {
  auto state = std::make_shared<SessionState>();
  auto factory = wam::macos::createNativeVideoSessionFactoryForTesting(
      factoryFunctions(state));
  state->factoryOwner = false;
  std::string error;
  expect(!factory->create(Token{41, 9}, "/tmp/a.mov", &error) &&
             state->createCalls == 0 && !error.empty(),
         "off-owner factory creation performs no session work");
  state->factoryOwner = true;
  error.clear();
  expect(!factory->create(Token{41, 9}, "/tmp/a.mov", &error) &&
             state->createCalls == 0,
         "a rejected one-shot factory cannot be reused");

  state = std::make_shared<SessionState>();
  std::unique_ptr<AdapterSessionFactory> successfulFactory;
  auto session = createSession(state, &successfulFactory);
  expect(session != nullptr &&
             !successfulFactory->create(Token{42, 1}, "/tmp/b.mov", nullptr) &&
             state->createCalls == 1,
         "a successful factory binds exactly one one-shot session");

  NativeVideoSessionFactoryTestFunctions incomplete;
  expect(!wam::macos::createNativeVideoSessionFactoryForTesting(
             std::move(incomplete)),
         "a session factory with null operations is rejected");
}

void testDispatchStatusAndPayloadTranslation() {
  auto state = std::make_shared<SessionState>();
  auto session = createSession(state);

  Action first = action(Action::Kind::PrepareNative, 1);
  state->nextExecute = {NativeVideoSessionDispatchStatus::Rejected, first, {}};
  NativeVideoDriverDispatch translated = session->execute(first);
  expect(translated.status == NativeVideoDriverStatus::Rejected &&
             translated.action == first,
         "Rejected status and whole Action translate exactly");

  Action second = action(Action::Kind::StartNative, 2);
  const ActionCompletion exactCompletion = completion();
  state->nextExecute = {NativeVideoSessionDispatchStatus::Completed, second,
                        exactCompletion};
  translated = session->execute(second);
  expect(translated.status == NativeVideoDriverStatus::Completed &&
             translated.action == second &&
             sameCompletion(translated.completion, exactCompletion),
         "Completed status and every completion field translate exactly");

  Action third = action(Action::Kind::SeekNative, 3);
  state->nextExecute = {NativeVideoSessionDispatchStatus::Pending, third,
                        exactCompletion};
  translated = session->execute(third);
  expect(translated.status == NativeVideoDriverStatus::Pending &&
             translated.action == third &&
             sameCompletion(translated.completion, exactCompletion),
         "Pending status is not widened or reconstructed");

  const Transport authoritative{77.25, 0.75, true};
  Action anchor = action(Action::Kind::ForcePauseMpv, 4);
  state->nextReanchor = {NativeVideoSessionDispatchStatus::Completed, anchor,
                         exactCompletion};
  translated = session->reanchor(anchor, authoritative);
  expect(translated.status == NativeVideoDriverStatus::Completed &&
             translated.action == anchor &&
             sameCompletion(translated.completion, exactCompletion) &&
             state->lastTransport == authoritative,
         "reanchor forwards exact transport, action, status, and completion");

  state->nextSample = {true,  false, true,  81, 82,
                       83,    84,    85};
  expect(sameSample(session->sample(Token{41, 9}), state->nextSample),
         "sample forwards every exact native counter and flag");
}

void testEventsTranslateExactly() {
  auto state = std::make_shared<SessionState>();
  auto session = createSession(state);

  NativeVideoSessionEvent prepared;
  prepared.kind = NativeVideoSessionEventKind::Prepared;
  prepared.token = Token{41, 9};
  prepared.generation = 91;
  state->events.push_back(prepared);

  NativeVideoSessionEvent unsupported;
  unsupported.kind = NativeVideoSessionEventKind::Unsupported;
  unsupported.token = Token{41, 9};
  state->events.push_back(unsupported);

  NativeVideoSessionEvent failed;
  failed.kind = NativeVideoSessionEventKind::Failed;
  failed.token = Token{41, 9};
  failed.generation = 92;
  state->events.push_back(failed);

  NativeVideoSessionEvent completedEvent;
  completedEvent.kind = NativeVideoSessionEventKind::ActionCompleted;
  completedEvent.token = Token{41, 9};
  completedEvent.generation = 93;
  completedEvent.action = action(Action::Kind::UpdateNativeClock, 7);
  completedEvent.completion = completion();
  state->events.push_back(completedEvent);

  const auto first = session->poll();
  const auto second = session->poll();
  const auto third = session->poll();
  const auto fourth = session->poll();
  expect(first && first->kind == prepared.kind &&
             first->token == prepared.token &&
             first->generation == prepared.generation,
         "Prepared event is forwarded exactly");
  expect(second && second->kind == unsupported.kind &&
             second->token == unsupported.token,
         "Unsupported event is forwarded exactly");
  expect(third && third->kind == failed.kind && third->token == failed.token &&
             third->generation == failed.generation,
         "Failed event is forwarded exactly");
  expect(fourth && fourth->kind == completedEvent.kind &&
             fourth->token == completedEvent.token &&
             fourth->generation == completedEvent.generation &&
             fourth->action == completedEvent.action &&
             sameCompletion(fourth->completion, completedEvent.completion),
         "ActionCompleted event retains its whole exact payload");
}

void testMismatchesAndInvalidEnumsBurnSession() {
  auto state = std::make_shared<SessionState>();
  auto session = createSession(state);
  Action expected = action(Action::Kind::PrepareNative, 1);
  Action wrong = action(Action::Kind::StartNative, 2);
  state->nextExecute = {NativeVideoSessionDispatchStatus::Completed, wrong,
                        completion()};
  expect(session->execute(expected).status ==
                 NativeVideoDriverStatus::Rejected &&
             state->executeCalls == 1,
         "a mismatched whole-Action reply is rejected");
  expect(session->execute(expected).status ==
                 NativeVideoDriverStatus::Rejected &&
             state->executeCalls == 1,
         "a mismatched whole-Action reply permanently burns the wrapper");

  state = std::make_shared<SessionState>();
  session = createSession(state);
  state->nextExecute = {
      static_cast<NativeVideoSessionDispatchStatus>(UINT8_MAX), expected, {}};
  expect(session->execute(expected).status ==
                 NativeVideoDriverStatus::Rejected &&
             session->sample(Token{41, 9}).generation == 0 &&
             state->sampleCalls == 0,
         "an unknown session status fails closed without widening its enum");

  state = std::make_shared<SessionState>();
  session = createSession(state);
  NativeVideoSessionEvent invalid;
  invalid.kind = static_cast<NativeVideoSessionEventKind>(UINT8_MAX);
  state->events.push_back(invalid);
  expect(!session->poll() && !session->poll() && state->pollCalls == 1,
         "an unknown event kind burns the session without forwarding it");
}

void testOffThreadOutputLossAndStopBurnClosed() {
  auto state = std::make_shared<SessionState>();
  auto session = createSession(state);
  const Action prepare = action(Action::Kind::PrepareNative, 1);
  state->nextExecute = {NativeVideoSessionDispatchStatus::Completed, prepare,
                        completion()};
  state->owner = false;
  expect(session->execute(prepare).status ==
                 NativeVideoDriverStatus::Rejected &&
             state->executeCalls == 0 && !session->poll() &&
             state->pollCalls == 0,
         "off-owner execute and poll cannot enter the native session");
  state->owner = true;
  expect(session->execute(prepare).status ==
                 NativeVideoDriverStatus::Completed &&
             state->executeCalls == 1,
         "an off-owner attempt is inert rather than mutating session state");

  state->outputAlive = false;
  expect(session->sample(Token{41, 9}).generation == 0 &&
             state->sampleCalls == 0,
         "lost output produces an inert sample and burns the wrapper");
  state->outputAlive = true;
  expect(session->execute(prepare).status ==
                 NativeVideoDriverStatus::Rejected &&
             state->executeCalls == 1,
         "a wrapper never resumes after its weak output was lost");

  state = std::make_shared<SessionState>();
  session = createSession(state);
  const Action stop = action(Action::Kind::StopNative, 8);
  state->nextExecute = {NativeVideoSessionDispatchStatus::Pending, stop, {}};
  expect(session->execute(stop).status == NativeVideoDriverStatus::Pending,
         "Stop pending status is forwarded exactly");
  NativeVideoSessionEvent stopped;
  stopped.kind = NativeVideoSessionEventKind::ActionCompleted;
  stopped.token = stop.token;
  stopped.action = stop;
  stopped.completion = completion();
  state->events.push_back(stopped);
  const auto terminal = session->poll();
  expect(terminal && terminal->action == stop &&
             sameCompletion(terminal->completion, stopped.completion),
         "the exact terminal Stop event is forwarded once");
  expect(!session->poll() &&
             session->execute(action(Action::Kind::PrepareNative, 9)).status ==
                 NativeVideoDriverStatus::Rejected &&
             state->pollCalls == 1 && state->executeCalls == 1,
         "a terminal Stop completion permanently burns the one-shot wrapper");
}

void testWeakCallbackOwnershipIsSafe() {
  auto state = std::make_shared<SessionState>();
  const std::weak_ptr<SessionState> weak = state;
  NativeVideoSessionFactoryTestFunctions functions;
  functions.onOwnerThread = [weak] { return !weak.expired(); };
  functions.outputAlive = [weak] { return !weak.expired(); };
  functions.create = [weak](Token, const std::filesystem::path &, std::string *)
      -> std::optional<NativeVideoSessionPortTestFunctions> {
    if (weak.expired()) {
      return std::nullopt;
    }
    NativeVideoSessionPortTestFunctions result;
    result.onOwnerThread = [weak] { return !weak.expired(); };
    result.outputAlive = [weak] { return !weak.expired(); };
    result.execute = [weak](const Action &value) {
      NativeVideoSessionDispatch result;
      result.action = value;
      result.status = weak.expired()
                          ? NativeVideoSessionDispatchStatus::Rejected
                          : NativeVideoSessionDispatchStatus::Completed;
      return result;
    };
    result.reanchor = [weak](const Action &value, Transport) {
      NativeVideoSessionDispatch result;
      result.action = value;
      result.status = weak.expired()
                          ? NativeVideoSessionDispatchStatus::Rejected
                          : NativeVideoSessionDispatchStatus::Completed;
      return result;
    };
    result.poll = [] { return std::optional<NativeVideoSessionEvent>{}; };
    result.sample = [](Token) { return NativeSample{}; };
    return result;
  };
  auto factory = wam::macos::createNativeVideoSessionFactoryForTesting(
      std::move(functions));
  auto session = factory->create(Token{41, 9}, "/tmp/weak.mov", nullptr);
  expect(session != nullptr, "weak-ownership test creates its session");
  state.reset();
  expect(session->execute(action(Action::Kind::PrepareNative, 1)).status ==
                 NativeVideoDriverStatus::Rejected &&
             !session->poll() &&
             session->sample(Token{41, 9}).generation == 0,
         "expired weak dependencies are inert and UAF-safe");
}

} // namespace

int main() {
  testRenderOrderAndOwnerGate();
  testRenderFailuresAreClosed();
  testFactoryIsOwnerGatedAndOneShot();
  testDispatchStatusAndPayloadTranslation();
  testEventsTranslateExactly();
  testMismatchesAndInvalidEnumsBurnSession();
  testOffThreadOutputLossAndStopBurnClosed();
  testWeakCallbackOwnershipIsSafe();

  if (failures == 0) {
    std::cout << "native video production port tests passed\n";
    return EXIT_SUCCESS;
  }
  std::cerr << failures << " native video production port test(s) failed\n";
  return EXIT_FAILURE;
}
