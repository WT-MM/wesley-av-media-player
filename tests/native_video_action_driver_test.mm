#include "platform/macos/native_video_action_driver.hpp"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using wam::macos::AdapterFact;
using wam::macos::AdapterMpvPort;
using wam::macos::AdapterRenderPort;
using wam::macos::AdapterSessionFactory;
using wam::macos::AdapterSessionPort;
using wam::macos::MacosNativeVideoActionDriver;
using wam::macos::NativeVideoSessionEvent;
using wam::macos::NativeVideoSessionEventKind;
using wam::native_activation::Action;
using wam::native_activation::ActionCompletion;
using wam::native_activation::FallbackReason;
using wam::native_activation::NativeSample;
using wam::native_activation::NativeVideoDriverDispatch;
using wam::native_activation::NativeVideoDriverStatus;
using wam::native_activation::Token;
using wam::native_activation::Transport;

int failures = 0;
std::uint32_t executedCases = 0;

void expect(bool condition, const char *message) {
  if (condition) {
    return;
  }
  ++failures;
  std::cerr << "FAIL: " << message << '\n';
}

Action action(Action::Kind kind, Token token, std::uint64_t serial) {
  Action result;
  result.kind = kind;
  result.token = token;
  result.serial = serial;
  return result;
}

NativeVideoDriverDispatch completed(Action value,
                                    ActionCompletion completion = {}) {
  return {NativeVideoDriverStatus::Completed, value, std::move(completion)};
}

NativeVideoDriverDispatch pending(Action value) {
  return {NativeVideoDriverStatus::Pending, value, {}};
}

bool sameDispatch(const NativeVideoDriverDispatch &left,
                  const NativeVideoDriverDispatch &right) {
  return left.status == right.status && left.action == right.action &&
         left.completion.succeeded == right.completion.succeeded &&
         left.completion.generation == right.completion.generation &&
         left.completion.drawBaseline == right.completion.drawBaseline &&
         left.completion.invalidationGeneration ==
             right.completion.invalidationGeneration &&
         left.completion.preRevokeGeneration ==
             right.completion.preRevokeGeneration &&
         left.completion.liveTransport == right.completion.liveTransport;
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
  bool allowSucceeds{true};
  std::uint64_t generation{17};
  std::uint64_t ownerChecks{0};
  std::uint64_t revokeCalls{0};
  std::uint64_t allowCalls{0};
  std::function<void()> ownerReentry;
  std::function<void()> revokeReentry;
  std::function<void()> allowReentry;
  std::vector<std::string> order;
};

class FakeRender final : public AdapterRenderPort {
public:
  explicit FakeRender(std::shared_ptr<RenderState> state)
      : state_(std::move(state)) {}

  bool onOwnerThread() const noexcept override {
    ++state_->ownerChecks;
    if (state_->ownerReentry) {
      auto callback = std::move(state_->ownerReentry);
      callback();
    }
    return state_->owner;
  }

  std::optional<std::uint64_t> revokeAndRequestRelease() noexcept override {
    ++state_->revokeCalls;
    state_->order.emplace_back("snapshot");
    state_->order.emplace_back("revoke");
    state_->order.emplace_back("release-update");
    if (state_->revokeReentry) {
      auto callback = std::move(state_->revokeReentry);
      callback();
    }
    return state_->generation;
  }

  bool allowAndRequestAcquire() noexcept override {
    ++state_->allowCalls;
    state_->order.emplace_back("allow");
    state_->order.emplace_back("acquire-update");
    if (state_->allowReentry) {
      auto callback = std::move(state_->allowReentry);
      callback();
    }
    return state_->allowSucceeds;
  }

private:
  std::shared_ptr<RenderState> state_;
};

struct MpvState {
  std::optional<Transport> paused{Transport{3.5, 1.25, true}};
  std::optional<Transport> restored{Transport{4.0, 1.5, false}};
  bool queueSucceeds{true};
  bool captionSucceeds{true};
  bool errorSucceeds{true};
  std::uint64_t pauseCalls{0};
  std::uint64_t restoreCalls{0};
  std::uint64_t loadCalls{0};
  std::uint64_t seekCalls{0};
  std::uint64_t selectCalls{0};
  std::uint64_t captionCalls{0};
  std::uint64_t errorCalls{0};
  std::uint64_t lastReply{0};
  std::filesystem::path source;
  double seekTarget{-1.0};
  std::int64_t videoId{-1};
  std::uint64_t captionId{0};
  FallbackReason reason{FallbackReason::Unsupported};
  Transport desired;
  std::function<void(std::uint64_t)> synchronousReply;
  std::function<void()> pauseReentry;
  std::function<void()> restoreReentry;
  std::function<void()> captionReentry;
  std::function<void()> errorReentry;
  std::vector<std::string> order;
};

class FakeMpv final : public AdapterMpvPort {
public:
  explicit FakeMpv(std::shared_ptr<MpvState> state)
      : state_(std::move(state)) {}

  std::optional<Transport> forcePauseAndReadback() noexcept override {
    ++state_->pauseCalls;
    state_->order.emplace_back("pause-readback");
    if (state_->pauseReentry) {
      auto callback = std::move(state_->pauseReentry);
      callback();
    }
    return state_->paused;
  }

  std::optional<Transport>
  restoreAndReadback(Transport desired) noexcept override {
    ++state_->restoreCalls;
    state_->desired = desired;
    state_->order.emplace_back("restore-readback");
    if (state_->restoreReentry) {
      auto callback = std::move(state_->restoreReentry);
      callback();
    }
    return state_->restored;
  }

  bool
  queueLoadAudioOnly(std::uint64_t reply,
                     const std::filesystem::path &source) noexcept override {
    ++state_->loadCalls;
    state_->lastReply = reply;
    state_->source = source;
    state_->order.emplace_back("load-audio-only");
    if (state_->synchronousReply) {
      state_->synchronousReply(reply);
    }
    return state_->queueSucceeds;
  }

  bool queueSeekExact(std::uint64_t reply, double target) noexcept override {
    ++state_->seekCalls;
    state_->lastReply = reply;
    state_->seekTarget = target;
    state_->order.emplace_back("seek-exact");
    if (state_->synchronousReply) {
      state_->synchronousReply(reply);
    }
    return state_->queueSucceeds;
  }

  bool queueSelectVideo(std::uint64_t reply,
                        std::int64_t videoId) noexcept override {
    ++state_->selectCalls;
    state_->lastReply = reply;
    state_->videoId = videoId;
    state_->order.emplace_back("select-video");
    if (state_->synchronousReply) {
      state_->synchronousReply(reply);
    }
    return state_->queueSucceeds;
  }

  bool attachCaption(std::uint64_t captionId) noexcept override {
    ++state_->captionCalls;
    state_->captionId = captionId;
    if (state_->captionReentry) {
      auto callback = std::move(state_->captionReentry);
      callback();
    }
    return state_->captionSucceeds;
  }

  bool surfaceError(FallbackReason reason) noexcept override {
    ++state_->errorCalls;
    state_->reason = reason;
    if (state_->errorReentry) {
      auto callback = std::move(state_->errorReentry);
      callback();
    }
    return state_->errorSucceeds;
  }

private:
  std::shared_ptr<MpvState> state_;
};

struct SessionState {
  std::uint64_t createCalls{0};
  std::uint64_t destroyCalls{0};
  std::uint64_t executeCalls{0};
  std::uint64_t reanchorCalls{0};
  std::uint64_t pollCalls{0};
  std::uint64_t sampleCalls{0};
  bool createSucceeds{true};
  bool normalizeReplyAction{true};
  std::function<void()> executeReentry;
  std::function<void()> reanchorReentry;
  std::function<void()> pollReentry;
  std::function<void()> sampleReentry;
  std::function<void()> factoryReentry;
  std::filesystem::path source;
  Token token;
  Action lastAction;
  Transport authoritative;
  NativeVideoDriverDispatch nextExecute;
  NativeVideoDriverDispatch nextReanchor;
  NativeSample sample;
  std::deque<NativeVideoSessionEvent> events;
  std::vector<std::string> order;
};

class FakeSession final : public AdapterSessionPort {
public:
  explicit FakeSession(std::shared_ptr<SessionState> state)
      : state_(std::move(state)) {}
  ~FakeSession() override {
    ++state_->destroyCalls;
    state_->order.emplace_back("destroy-session");
  }

  NativeVideoDriverDispatch execute(const Action &value) noexcept override {
    ++state_->executeCalls;
    state_->lastAction = value;
    state_->order.emplace_back("session-execute");
    if (state_->executeReentry) {
      auto callback = std::move(state_->executeReentry);
      callback();
    }
    NativeVideoDriverDispatch result = state_->nextExecute;
    if (state_->normalizeReplyAction) {
      result.action = value;
    }
    return result;
  }

  NativeVideoDriverDispatch
  reanchor(const Action &value, Transport authoritative) noexcept override {
    ++state_->reanchorCalls;
    state_->lastAction = value;
    state_->authoritative = authoritative;
    state_->order.emplace_back("session-reanchor");
    if (state_->reanchorReentry) {
      auto callback = std::move(state_->reanchorReentry);
      callback();
    }
    NativeVideoDriverDispatch result = state_->nextReanchor;
    result.action = value;
    return result;
  }

  std::optional<NativeVideoSessionEvent> poll() noexcept override {
    ++state_->pollCalls;
    if (state_->pollReentry) {
      auto callback = std::move(state_->pollReentry);
      callback();
    }
    if (state_->events.empty()) {
      return std::nullopt;
    }
    NativeVideoSessionEvent result = state_->events.front();
    state_->events.pop_front();
    return result;
  }

  NativeSample sample(Token) noexcept override {
    ++state_->sampleCalls;
    if (state_->sampleReentry) {
      auto callback = std::move(state_->sampleReentry);
      callback();
    }
    return state_->sample;
  }

private:
  std::shared_ptr<SessionState> state_;
};

class FakeSessionFactory final : public AdapterSessionFactory {
public:
  explicit FakeSessionFactory(std::shared_ptr<SessionState> state)
      : state_(std::move(state)) {}

  std::unique_ptr<AdapterSessionPort>
  create(Token token, const std::filesystem::path &source,
         std::string *error) noexcept override {
    ++state_->createCalls;
    state_->token = token;
    state_->source = source;
    if (state_->factoryReentry) {
      auto callback = std::move(state_->factoryReentry);
      callback();
    }
    if (!state_->createSucceeds) {
      if (error != nullptr) {
        *error = "injected session creation failure";
      }
      return nullptr;
    }
    return std::make_unique<FakeSession>(state_);
  }

private:
  std::shared_ptr<SessionState> state_;
};

struct Fixture {
  Token token{71, 4};
  std::shared_ptr<RenderState> render{std::make_shared<RenderState>()};
  std::shared_ptr<MpvState> mpv{std::make_shared<MpvState>()};
  std::shared_ptr<SessionState> session{std::make_shared<SessionState>()};
  std::unique_ptr<MacosNativeVideoActionDriver> driver;

  Fixture() {
    session->nextExecute = completed({});
    session->nextReanchor = completed({});
    std::string error;
    driver = MacosNativeVideoActionDriver::create(
        "/tmp/media.mp4", std::make_unique<FakeRender>(render),
        std::make_unique<FakeMpv>(mpv),
        std::make_unique<FakeSessionFactory>(session), &error);
    expect(driver != nullptr && error.empty(), "fixture driver is created");
  }
};

void createSession(Fixture &fixture, std::uint64_t serial = 1) {
  if (fixture.render->revokeCalls == 0) {
    const Action revoke =
        action(Action::Kind::RevokeMpvRenderer, fixture.token, serial++);
    expect(fixture.driver->execute(revoke).completion.succeeded,
           "session helper first denies mpv rendering");
  }
  const Action prepare =
      action(Action::Kind::PrepareNative, fixture.token, serial);
  const NativeVideoDriverDispatch result = fixture.driver->execute(prepare);
  expect(result.status == NativeVideoDriverStatus::Completed &&
             result.completion.succeeded,
         "Prepare creates and delegates to one session");
}

void testConstructionIsInertAndOwnerGateIsFirst() {
  Fixture fixture;
  expect(fixture.render->ownerChecks == 0 && fixture.render->revokeCalls == 0 &&
             fixture.render->allowCalls == 0 && fixture.mpv->pauseCalls == 0 &&
             fixture.session->createCalls == 0,
         "construction performs no dependency work");

  fixture.render->owner = false;
  const Action pause = action(Action::Kind::ForcePauseMpv, fixture.token, 1);
  expect(fixture.driver->execute(pause).status ==
                 NativeVideoDriverStatus::Rejected &&
             fixture.mpv->pauseCalls == 0 && fixture.session->createCalls == 0,
         "off-owner execution is rejected before mutation");
  fixture.render->owner = true;
  expect(fixture.driver->takeLastError().has_value(),
         "off-owner rejection retains one bounded diagnostic");
}

void testPauseRevokeAndExactReplay() {
  Fixture fixture;
  const Action pause = action(Action::Kind::ForcePauseMpv, fixture.token, 1);
  const auto first = fixture.driver->execute(pause);
  const auto replay = fixture.driver->execute(pause);
  expect(first.status == NativeVideoDriverStatus::Completed &&
             first.completion.liveTransport == fixture.mpv->paused &&
             sameDispatch(replay, first) && fixture.mpv->pauseCalls == 1,
         "ForcePause returns exact paused readback and exact replay is cached");

  Action collision = pause;
  collision.kind = Action::Kind::RevokeMpvRenderer;
  expect(fixture.driver->execute(collision).status ==
                 NativeVideoDriverStatus::Rejected &&
             fixture.render->revokeCalls == 0,
         "same-serial different Action is mutation-free");

  const Action revoke =
      action(Action::Kind::RevokeMpvRenderer, fixture.token, 2);
  const auto revoked = fixture.driver->execute(revoke);
  expect(
      revoked.status == NativeVideoDriverStatus::Completed &&
          revoked.completion.preRevokeGeneration == 17 &&
          fixture.render->revokeCalls == 1 &&
          fixture.render->order ==
              std::vector<std::string>{"snapshot", "revoke", "release-update"},
      "Revoke captures one nonzero generation before revoke and update");
}

void testAsyncReplyIdentityAndNamespace() {
  Fixture fixture;
  const Action load = action(Action::Kind::LoadMpvAudioOnly, fixture.token, 1);
  const auto queued = fixture.driver->execute(load);
  expect(queued.status == NativeVideoDriverStatus::Pending &&
             fixture.mpv->loadCalls == 1 &&
             fixture.mpv->source == "/tmp/media.mp4" &&
             MacosNativeVideoActionDriver::ownsMpvCommandReply(
                 fixture.mpv->lastReply) &&
             (fixture.mpv->lastReply >> 62) == 3,
         "audio-only load owns an exact namespaced async reply");
  expect(sameDispatch(fixture.driver->execute(load), queued) &&
             fixture.mpv->loadCalls == 1,
         "exact pending Action replay never queues twice");
  const Action wrong = action(Action::Kind::SeekMpvExact, fixture.token, 2);
  expect(fixture.driver->execute(wrong).status ==
                 NativeVideoDriverStatus::Rejected &&
             fixture.mpv->seekCalls == 0,
         "capacity one rejects a different Action while reply is pending");
  expect(!fixture.driver->acceptMpvCommandReply(fixture.mpv->lastReply + 1, 0),
         "wrong reply userdata is inert");
  expect(fixture.driver->acceptMpvCommandReply(fixture.mpv->lastReply, 0),
         "exact reply userdata is accepted once");
  const auto reply = fixture.driver->poll();
  expect(reply && reply->status == NativeVideoDriverStatus::Completed &&
             reply->action == load && reply->completion.succeeded,
         "poll returns the whole exact Action identity");
  expect(!fixture.driver->acceptMpvCommandReply(fixture.mpv->lastReply, 0),
         "late duplicate reply is inert");

  Action seek = action(Action::Kind::SeekMpvExact, fixture.token, 2);
  seek.transport = Transport{8.25, 1.0, true};
  expect(fixture.driver->execute(seek).status ==
                 NativeVideoDriverStatus::Pending &&
             fixture.mpv->seekTarget == 8.25,
         "exact seek target is queued asynchronously");
  expect(fixture.driver->acceptMpvCommandReply(fixture.mpv->lastReply, -3),
         "exact failed seek reply is accepted");
  const auto failedReply = fixture.driver->poll();
  expect(failedReply && !failedReply->completion.succeeded &&
             failedReply->action == seek,
         "mpv error completes only its stored whole Action");

  Action select = action(Action::Kind::SelectMpvVideo, fixture.token, 3);
  select.videoId = 9;
  expect(fixture.driver->execute(select).status ==
                 NativeVideoDriverStatus::Pending &&
             fixture.mpv->videoId == 9,
         "video selection queues the exact positive track id");
}

void testSynchronousReplySeesPublishedFlight() {
  Fixture fixture;
  fixture.mpv->synchronousReply = [&](std::uint64_t userdata) {
    expect(fixture.driver->acceptMpvCommandReply(userdata, 0),
           "synchronous broker sees the pre-published exact flight");
  };
  const Action load = action(Action::Kind::LoadMpvAudioOnly, fixture.token, 1);
  const auto result = fixture.driver->execute(load);
  expect(result.status == NativeVideoDriverStatus::Completed &&
             result.action == load && result.completion.succeeded &&
             !fixture.driver->poll(),
         "synchronous exact reply completes without a duplicate poll event");
}

void testWholeBoundaryReentrancyIsSuppressed() {
  Fixture fixture;
  const Action pause = action(Action::Kind::ForcePauseMpv, fixture.token, 1);
  const Action revoke =
      action(Action::Kind::RevokeMpvRenderer, fixture.token, 2);
  fixture.render->ownerReentry = [&] {
    expect(fixture.driver->execute(revoke).status ==
                   NativeVideoDriverStatus::Rejected &&
               !fixture.driver->poll(),
           "owner-thread virtual cannot reenter execute or poll");
  };
  fixture.mpv->pauseReentry = [&] {
    expect(fixture.driver->execute(revoke).status ==
                   NativeVideoDriverStatus::Rejected &&
               !fixture.driver->poll(),
           "mpv readback virtual cannot reenter execute or poll");
  };
  expect(fixture.driver->execute(pause).completion.succeeded &&
             fixture.render->revokeCalls == 0,
         "outer execute remains authoritative after hostile reentry");

  fixture.render->revokeReentry = [&] {
    expect(fixture.driver->execute(pause).status ==
                   NativeVideoDriverStatus::Rejected &&
               !fixture.driver->poll(),
           "render mutation virtual cannot recursively mutate the adapter");
  };
  expect(fixture.driver->execute(revoke).completion.succeeded &&
             fixture.render->revokeCalls == 1,
         "outer renderer revocation remains single-shot");

  const Action prepare = action(Action::Kind::PrepareNative, fixture.token, 3);
  fixture.session->factoryReentry = [&] {
    expect(fixture.driver->execute(pause).status ==
                   NativeVideoDriverStatus::Rejected &&
               !fixture.driver->poll(),
           "session factory virtual cannot recursively mutate the adapter");
  };
  fixture.session->executeReentry = [&] {
    expect(fixture.driver->execute(pause).status ==
                   NativeVideoDriverStatus::Rejected &&
               !fixture.driver->poll(),
           "session execute virtual cannot recursively mutate the adapter");
  };
  expect(fixture.driver->execute(prepare).completion.succeeded,
         "outer session execute remains authoritative after hostile reentry");

  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Prepared, fixture.token, 8, {}, {}});
  fixture.session->pollReentry = [&] {
    expect(!fixture.driver->poll() && fixture.driver->execute(pause).status ==
                                          NativeVideoDriverStatus::Rejected,
           "session poll virtual cannot recursively poll or execute");
  };
  expect(!fixture.driver->poll(), "outer poll retains the session fact");
  const auto fact = fixture.driver->takeFact();
  expect(fact && fact->generation == 8,
         "outer poll publishes exactly one valid fact");

  fixture.session->sampleReentry = [&] {
    expect(sameSample(fixture.driver->sample(fixture.token), NativeSample{}),
           "session sample virtual cannot recursively sample");
  };
  fixture.session->sample = NativeSample{true, false, false, 8, 8, 8, 1, 1};
  expect(sameSample(fixture.driver->sample(fixture.token),
                    fixture.session->sample),
         "outer sample remains authoritative after hostile reentry");

  Action restore = action(Action::Kind::RestoreTransport, fixture.token, 4);
  restore.transport = Transport{4.0, 1.5, false};
  fixture.mpv->restoreReentry = [&] {
    expect(fixture.driver->execute(pause).status ==
                   NativeVideoDriverStatus::Rejected &&
               !fixture.driver->poll(),
           "restore virtual cannot recursively mutate the adapter");
  };
  fixture.session->reanchorReentry = [&] {
    expect(fixture.driver->execute(pause).status ==
                   NativeVideoDriverStatus::Rejected &&
               !fixture.driver->poll(),
           "session reanchor virtual cannot recursively mutate the adapter");
  };
  expect(fixture.driver->execute(restore).completion.succeeded,
         "outer restore remains authoritative after hostile reentry");
}

void testSynchronousReplyIsTheOnlyQueueReentry() {
  Fixture fixture;
  const Action load = action(Action::Kind::LoadMpvAudioOnly, fixture.token, 1);
  const Action revoke =
      action(Action::Kind::RevokeMpvRenderer, fixture.token, 2);
  bool nestedAccepted = true;
  fixture.mpv->synchronousReply = [&](std::uint64_t userdata) {
    expect(!fixture.driver->poll() && fixture.driver->execute(revoke).status ==
                                          NativeVideoDriverStatus::Rejected,
           "queue callback cannot poll or execute while the boundary is open");
    fixture.render->ownerReentry = [&] {
      nestedAccepted = fixture.driver->acceptMpvCommandReply(userdata, -99);
    };
    expect(fixture.driver->acceptMpvCommandReply(userdata, 0),
           "one exact synchronous reply is accepted during queueing");
  };
  const auto result = fixture.driver->execute(load);
  expect(result.status == NativeVideoDriverStatus::Completed &&
             result.completion.succeeded && !nestedAccepted &&
             !fixture.driver->poll(),
         "nested reply is suppressed and no stale Pending result escapes");
}

void testSessionFactsSampleAndNativeMapping() {
  Fixture fixture;
  createSession(fixture);
  expect(fixture.session->createCalls == 1 &&
             fixture.session->source == "/tmp/media.mp4" &&
             fixture.session->token == fixture.token,
         "Prepare binds exact token and source to the session factory");

  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Prepared, fixture.token, 22, {}, {}});
  expect(!fixture.driver->poll(),
         "Prepared remains a separate fact, never an Action completion");
  const auto prepared = fixture.driver->takeFact();
  expect(prepared && prepared->kind == AdapterFact::Kind::Prepared &&
             prepared->token == fixture.token && prepared->generation == 22,
         "Prepared fact retains exact token and generation");

  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Unsupported, fixture.token, 0, {}, {}});
  (void)fixture.driver->poll();
  const auto unsupported = fixture.driver->takeFact();
  expect(unsupported && unsupported->kind == AdapterFact::Kind::Unsupported,
         "Unsupported is delivered on the bounded fact channel");

  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Failed, fixture.token, 0, {}, {}});
  (void)fixture.driver->poll();
  const auto failedFact = fixture.driver->takeFact();
  expect(failedFact && failedFact->kind == AdapterFact::Kind::Failed,
         "Failed is delivered on the bounded fact channel");

  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Failed, Token{999, 1}, 0, {}, {}});
  expect(!fixture.driver->poll() && !fixture.driver->takeFact(),
         "stale-token session fact is inert");

  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Prepared, fixture.token, 0, {}, {}});
  expect(!fixture.driver->poll(),
         "zero-generation Prepared never becomes a Prepared fact");
  const auto malformedPrepared = fixture.driver->takeFact();
  expect(malformedPrepared &&
             malformedPrepared->kind == AdapterFact::Kind::Failed,
         "zero-generation Prepared promptly becomes a bounded failure fact");

  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Prepared, fixture.token, 23, {}, {}});
  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Unsupported, fixture.token, 0, {}, {}});
  const std::uint64_t beforeFactPoll = fixture.session->pollCalls;
  (void)fixture.driver->poll();
  (void)fixture.driver->poll();
  expect(fixture.session->pollCalls == beforeFactPoll + 1,
         "retained fact enforces exact capacity one without over-polling");
  (void)fixture.driver->takeFact();
  (void)fixture.driver->poll();
  (void)fixture.driver->takeFact();

  fixture.session->sample = NativeSample{true, false, false, 22, 22, 22, 4, 1};
  expect(sameSample(fixture.driver->sample(fixture.token),
                    fixture.session->sample) &&
             sameSample(fixture.driver->sample(Token{2, 2}), NativeSample{}),
         "sample is exact-token gated and otherwise inference-free");
}

void testDispatchAndSurfaceEnumsAreNormalized() {
  Fixture fixture;
  const Action revoke =
      action(Action::Kind::RevokeMpvRenderer, fixture.token, 1);
  (void)fixture.driver->execute(revoke);
  fixture.session->nextExecute.status =
      static_cast<NativeVideoDriverStatus>(255);
  const Action prepare = action(Action::Kind::PrepareNative, fixture.token, 2);
  const auto malformed = fixture.driver->execute(prepare);
  expect(malformed.status == NativeVideoDriverStatus::Completed &&
             !malformed.completion.succeeded,
         "unknown session dispatch status normalizes to exact failure");

  Fixture surface;
  Action error = action(Action::Kind::SurfaceError, surface.token, 1);
  error.value = 255;
  expect(!surface.driver->execute(error).completion.succeeded &&
             surface.mpv->errorCalls == 0,
         "unknown fallback reason is rejected before reaching mpv");
}

void testNativeSessionActionsRequireRendererDenial() {
  Fixture fixture;
  Action prepare = action(Action::Kind::PrepareNative, fixture.token, 1);
  expect(!fixture.driver->execute(prepare).completion.succeeded &&
             fixture.session->createCalls == 0,
         "Prepare before renderer denial never creates a native session");

  Fixture startFixture;
  Action start = action(Action::Kind::StartNative, startFixture.token, 1);
  Action seek = action(Action::Kind::SeekNative, startFixture.token, 2);
  Action clock = action(Action::Kind::UpdateNativeClock, startFixture.token, 3);
  Action stop = action(Action::Kind::StopNative, startFixture.token, 4);
  expect(!startFixture.driver->execute(start).completion.succeeded &&
             !startFixture.driver->execute(seek).completion.succeeded &&
             !startFixture.driver->execute(clock).completion.succeeded &&
             !startFixture.driver->execute(stop).completion.succeeded &&
             startFixture.session->createCalls == 0 &&
             startFixture.session->executeCalls == 0,
         "all native actions before renderer denial are mutation-free");
}

void testReanchorOrderAndReadbackValidation() {
  Fixture fixture;
  createSession(fixture);
  fixture.mpv->order.clear();
  fixture.session->order.clear();
  const Action pause = action(Action::Kind::ForcePauseMpv, fixture.token, 3);
  const auto paused = fixture.driver->execute(pause);
  expect(paused.status == NativeVideoDriverStatus::Completed &&
             paused.completion.liveTransport == fixture.mpv->paused &&
             fixture.session->authoritative == *fixture.mpv->paused &&
             fixture.mpv->order == std::vector<std::string>{"pause-readback"} &&
             fixture.session->order.back() == "session-reanchor",
         "ForcePause reads authoritative transport before native reanchor");

  Action restore = action(Action::Kind::RestoreTransport, fixture.token, 4);
  restore.transport = Transport{4.0, 1.5, false};
  const auto restored = fixture.driver->execute(restore);
  expect(
      restored.status == NativeVideoDriverStatus::Completed &&
          restored.completion.succeeded && !restored.completion.liveTransport &&
          fixture.mpv->desired == restore.transport &&
          fixture.session->authoritative == *fixture.mpv->restored,
      "Restore sets, reads back, reanchors, then returns an empty completion");

  fixture.mpv->paused = Transport{9.0, 1.0, false};
  const Action invalidPause =
      action(Action::Kind::ForcePauseMpv, fixture.token, 5);
  const std::uint64_t priorReanchors = fixture.session->reanchorCalls;
  const auto failedPause = fixture.driver->execute(invalidPause);
  expect(failedPause.status == NativeVideoDriverStatus::Completed &&
             !failedPause.completion.succeeded &&
             fixture.session->reanchorCalls == priorReanchors,
         "unpaused authoritative readback fails before native reanchor");

  fixture.mpv->restored = Transport{5.0, 1.5, false};
  Action wrongRestore =
      action(Action::Kind::RestoreTransport, fixture.token, 6);
  wrongRestore.transport = Transport{4.0, 1.5, false};
  const auto mismatched = fixture.driver->execute(wrongRestore);
  expect(mismatched.status == NativeVideoDriverStatus::Completed &&
             !mismatched.completion.succeeded &&
             fixture.session->reanchorCalls == priorReanchors,
         "Restore rejects a valid but position-mismatched readback before "
         "native reanchor");

  fixture.mpv->paused = Transport{9.0, 1.0, true};
  fixture.session->nextReanchor = pending({});
  const Action pendingReanchor =
      action(Action::Kind::ForcePauseMpv, fixture.token, 7);
  const auto normalized = fixture.driver->execute(pendingReanchor);
  expect(normalized.status == NativeVideoDriverStatus::Completed &&
             !normalized.completion.succeeded,
         "synchronous reanchor rejects and normalizes Pending dispatch");

  fixture.session->nextReanchor = completed({});
  fixture.mpv->restored = Transport{4.0, 1.5, true};
  Action pausedMismatch =
      action(Action::Kind::RestoreTransport, fixture.token, 8);
  pausedMismatch.transport = Transport{4.0, 1.5, false};
  expect(!fixture.driver->execute(pausedMismatch).completion.succeeded,
         "Restore rejects a paused-state readback mismatch");

  fixture.mpv->restored = Transport{4.0, 1.500002, false};
  Action rateMismatch =
      action(Action::Kind::RestoreTransport, fixture.token, 9);
  rateMismatch.transport = Transport{4.0, 1.5, false};
  expect(!fixture.driver->execute(rateMismatch).completion.succeeded,
         "Restore rejects a rate readback beyond epsilon");
}

void testStartSeekStopAndAllowOrdering() {
  Fixture fixture;
  const Action revoke =
      action(Action::Kind::RevokeMpvRenderer, fixture.token, 1);
  (void)fixture.driver->execute(revoke);
  createSession(fixture, 2);

  Action start = action(Action::Kind::StartNative, fixture.token, 3);
  start.value = 30;
  fixture.session->nextExecute = pending(start);
  expect(fixture.driver->execute(start).status ==
             NativeVideoDriverStatus::Pending,
         "Start preserves the session Pending state");
  ActionCompletion started;
  started.generation = 30;
  started.drawBaseline = 5;
  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::ActionCompleted, fixture.token, 0, start,
       started});
  const auto startReply = fixture.driver->poll();
  expect(startReply && startReply->action == start &&
             startReply->completion.generation == 30 &&
             startReply->completion.drawBaseline == 5,
         "Start passes through exact generation and draw baseline");

  Action seek = action(Action::Kind::SeekNative, fixture.token, 4);
  seek.transport = Transport{12.0, 1.25, true};
  ActionCompletion sought;
  sought.generation = 31;
  sought.drawBaseline = 8;
  fixture.session->nextExecute = completed(seek, sought);
  const auto seekReply = fixture.driver->execute(seek);
  expect(seekReply.completion.generation == 31 &&
             seekReply.completion.drawBaseline == 8,
         "Seek passes through exact generation and draw baseline");

  const Action allowEarly =
      action(Action::Kind::AllowMpvRenderer, fixture.token, 5);
  expect(!fixture.driver->execute(allowEarly).completion.succeeded &&
             fixture.render->allowCalls == 0 &&
             fixture.session->destroyCalls == 0,
         "Allow cannot coexist with a live native session");

  const Action stop = action(Action::Kind::StopNative, fixture.token, 6);
  fixture.session->nextExecute = pending(stop);
  expect(fixture.driver->execute(stop).status ==
             NativeVideoDriverStatus::Pending,
         "Stop remains pending until exact session quiescence");
  expect(!fixture.driver->poll() && fixture.session->destroyCalls == 0,
         "pending Stop neither completes nor destroys early");
  ActionCompletion stopped;
  stopped.invalidationGeneration = 41;
  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::ActionCompleted, fixture.token, 0, stop,
       stopped});
  const auto stopReply = fixture.driver->poll();
  expect(stopReply && stopReply->action == stop &&
             stopReply->completion.invalidationGeneration == 41 &&
             fixture.session->destroyCalls == 1 &&
             fixture.session->order.back() == "destroy-session",
         "Stop destroys/closes the session before returning completion");

  Action allowWrong = action(Action::Kind::AllowMpvRenderer, fixture.token, 7);
  allowWrong.value = 40;
  expect(!fixture.driver->execute(allowWrong).completion.succeeded &&
             fixture.render->allowCalls == 0,
         "Allow requires the exact Stop invalidation proof value");

  Action allowExact = action(Action::Kind::AllowMpvRenderer, fixture.token, 8);
  allowExact.value = 41;
  fixture.render->allowReentry = [&] {
    expect(fixture.driver->execute(stop).status ==
                   NativeVideoDriverStatus::Rejected &&
               !fixture.driver->poll(),
           "renderer allow virtual cannot recursively mutate the adapter");
  };
  const auto allowed = fixture.driver->execute(allowExact);
  expect(
      allowed.status == NativeVideoDriverStatus::Completed &&
          allowed.completion.succeeded && fixture.render->allowCalls == 1 &&
          fixture.session->destroyCalls == 1,
      "Allow runs only after session teardown and requests renderer acquire");
}

void testMalformedPendingStopEventsFailClosed() {
  const auto runMalformed = [](Token eventToken, Action eventAction,
                               ActionCompletion completion,
                               const char *message) {
    Fixture fixture;
    createSession(fixture);
    const Action stop = action(Action::Kind::StopNative, fixture.token, 3);
    fixture.session->nextExecute = pending(stop);
    expect(fixture.driver->execute(stop).status ==
               NativeVideoDriverStatus::Pending,
           "malformed-stop fixture admits one pending Stop");
    fixture.session->events.push_back(
        {NativeVideoSessionEventKind::ActionCompleted, eventToken, 0,
         eventAction, completion});
    const auto result = fixture.driver->poll();
    expect(result && result->action == stop &&
               result->status == NativeVideoDriverStatus::Completed &&
               !result->completion.succeeded &&
               fixture.session->destroyCalls == 1,
           message);
    Action allow = action(Action::Kind::AllowMpvRenderer, fixture.token, 4);
    allow.value = completion.invalidationGeneration;
    expect(!fixture.driver->execute(allow).completion.succeeded &&
               fixture.render->allowCalls == 0,
           "malformed Stop never arms renderer permission");
  };

  const Token token{71, 4};
  const Action exactStop = action(Action::Kind::StopNative, token, 3);
  ActionCompletion good;
  good.invalidationGeneration = 9;
  runMalformed(Token{999, 1}, exactStop, good,
               "wrong-token Stop completion destroys and fails exact flight");
  runMalformed(token, action(Action::Kind::StopNative, token, 99), good,
               "wrong-action Stop completion destroys and fails exact flight");
  ActionCompletion zero;
  runMalformed(token, exactStop, zero,
               "zero-proof Stop completion destroys and fails exact flight");
  ActionCompletion failedProof;
  failedProof.succeeded = false;
  failedProof.invalidationGeneration = 9;
  runMalformed(token, exactStop, failedProof,
               "failed Stop completion destroys and fails exact flight");
}

void testMalformedSynchronousStopsAndEventKindFailClosed() {
  const auto runSynchronous = [](NativeVideoDriverDispatch injected,
                                 const char *message) {
    Fixture fixture;
    createSession(fixture);
    const Action stop = action(Action::Kind::StopNative, fixture.token, 3);
    injected.action = stop;
    fixture.session->nextExecute = injected;
    const auto result = fixture.driver->execute(stop);
    expect(result.action == stop && fixture.session->destroyCalls == 1 &&
               !(result.status == NativeVideoDriverStatus::Completed &&
                 result.completion.succeeded),
           message);
  };

  runSynchronous(completed({}, {}),
                 "synchronous zero-proof Stop destroys and fails closed");
  ActionCompletion failedCompletion;
  failedCompletion.succeeded = false;
  failedCompletion.invalidationGeneration = 8;
  runSynchronous(completed({}, failedCompletion),
                 "synchronous failed Stop destroys and fails closed");
  NativeVideoDriverDispatch unknown;
  unknown.status = static_cast<NativeVideoDriverStatus>(255);
  runSynchronous(unknown,
                 "synchronous unknown Stop status destroys and fails closed");

  Fixture invalidEvent;
  createSession(invalidEvent);
  const Action stop = action(Action::Kind::StopNative, invalidEvent.token, 3);
  invalidEvent.session->nextExecute = pending(stop);
  (void)invalidEvent.driver->execute(stop);
  NativeVideoSessionEvent malformed;
  malformed.kind = static_cast<NativeVideoSessionEventKind>(255);
  malformed.token = invalidEvent.token;
  malformed.action = stop;
  invalidEvent.session->events.push_back(malformed);
  const auto eventResult = invalidEvent.driver->poll();
  expect(eventResult && !eventResult->completion.succeeded &&
             invalidEvent.session->destroyCalls == 1,
         "unknown Stop event kind destroys and fails exact Stop flight");
}

void testCaptionErrorAndDestructorNeverAllow() {
  auto render = std::make_shared<RenderState>();
  auto mpv = std::make_shared<MpvState>();
  auto session = std::make_shared<SessionState>();
  session->nextExecute = completed({});
  session->nextReanchor = completed({});
  {
    auto driver = MacosNativeVideoActionDriver::create(
        "/tmp/media.mp4", std::make_unique<FakeRender>(render),
        std::make_unique<FakeMpv>(mpv),
        std::make_unique<FakeSessionFactory>(session));
    const Token token{8, 2};
    const Action revoke = action(Action::Kind::RevokeMpvRenderer, token, 1);
    (void)driver->execute(revoke);
    const Action prepare = action(Action::Kind::PrepareNative, token, 2);
    (void)driver->execute(prepare);

    Action caption = action(Action::Kind::AttachCaption, token, 3);
    caption.captionId = 991;
    mpv->captionReentry = [&] {
      expect(driver->execute(revoke).status ==
                     NativeVideoDriverStatus::Rejected &&
                 !driver->poll(),
             "caption virtual cannot recursively mutate the adapter");
    };
    expect(driver->execute(caption).completion.succeeded &&
               mpv->captionId == 991,
           "caption attachment routes its full unsigned identity");

    Action error = action(Action::Kind::SurfaceError, token, 4);
    error.value = static_cast<std::uint64_t>(FallbackReason::ContextFailure);
    mpv->errorReentry = [&] {
      expect(driver->execute(revoke).status ==
                     NativeVideoDriverStatus::Rejected &&
                 !driver->poll(),
             "error virtual cannot recursively mutate the adapter");
    };
    expect(driver->execute(error).completion.succeeded &&
               mpv->reason == FallbackReason::ContextFailure,
           "surface error routes the exact bounded fallback reason");
    render->owner = false;
  }
  expect(session->destroyCalls == 1 && render->allowCalls == 0,
         "off-owner destructor uses the session emergency close and never "
         "Allows renderer");
}

void testStopBurnsFactsAndSessionOneShot() {
  Fixture fixture;
  createSession(fixture);
  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Prepared, fixture.token, 7, {}, {}});
  expect(!fixture.driver->poll() && !fixture.driver->poll(),
         "a queued Prepared fact is bounded while retained");

  const Action stop = action(Action::Kind::StopNative, fixture.token, 3);
  fixture.session->nextExecute = pending(stop);
  expect(fixture.driver->execute(stop).status ==
             NativeVideoDriverStatus::Pending,
         "Stop admission burns the session and clears retained facts");
  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Unsupported, fixture.token, 0, {}, {}});
  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::Prepared, fixture.token, 99, {}, {}});
  ActionCompletion stopped;
  stopped.invalidationGeneration = 8;
  fixture.session->events.push_back(
      {NativeVideoSessionEventKind::ActionCompleted, fixture.token, 0, stop,
       stopped});
  const auto reply = fixture.driver->poll();
  expect(reply && reply->action == stop && fixture.session->destroyCalls == 1 &&
             !fixture.driver->takeFact(),
         "retained fact cannot block Stop completion and is not delivered "
         "after Stop");

  const Action prepareAgain =
      action(Action::Kind::PrepareNative, fixture.token, 4);
  expect(fixture.driver->execute(prepareAgain).status ==
                 NativeVideoDriverStatus::Rejected &&
             fixture.session->createCalls == 1,
         "higher-serial Prepare cannot recreate a burned one-shot session");
}

void testNonPendingStopAlwaysDestroysSession() {
  Fixture fixture;
  createSession(fixture);
  const Action stop = action(Action::Kind::StopNative, fixture.token, 3);
  fixture.session->nextExecute = {};
  const auto result = fixture.driver->execute(stop);
  expect(result.status == NativeVideoDriverStatus::Rejected &&
             fixture.session->destroyCalls == 1,
         "non-Pending rejected Stop still destroys the session before return");

  Fixture mismatch;
  createSession(mismatch);
  const Action mismatchStop =
      action(Action::Kind::StopNative, mismatch.token, 3);
  mismatch.session->normalizeReplyAction = false;
  mismatch.session->nextExecute = pending(
      action(Action::Kind::StopNative, Token{999, 1}, mismatchStop.serial));
  const auto mismatched = mismatch.driver->execute(mismatchStop);
  expect(mismatched.status == NativeVideoDriverStatus::Completed &&
             !mismatched.completion.succeeded &&
             mismatch.session->destroyCalls == 1,
         "mismatched Pending Stop normalizes to failure and destroys session "
         "before return");
}

void testFailedSessionFactoryHasQuiescentStopProof() {
  Fixture fixture;
  fixture.session->createSucceeds = false;
  const Action revoke =
      action(Action::Kind::RevokeMpvRenderer, fixture.token, 1);
  expect(fixture.driver->execute(revoke).completion.succeeded,
         "failed-factory sequence first owns renderer denial");
  const Action prepare = action(Action::Kind::PrepareNative, fixture.token, 2);
  const auto failedPrepare = fixture.driver->execute(prepare);
  expect(failedPrepare.status == NativeVideoDriverStatus::Completed &&
             !failedPrepare.completion.succeeded &&
             fixture.session->createCalls == 1,
         "session factory failure completes Prepare without a live session");

  const Action retry = action(Action::Kind::PrepareNative, fixture.token, 3);
  expect(fixture.driver->execute(retry).status ==
                 NativeVideoDriverStatus::Rejected &&
             fixture.session->createCalls == 1,
         "factory failure tombstone prevents every Prepare retry");

  const Action stop = action(Action::Kind::StopNative, fixture.token, 4);
  const auto stopped = fixture.driver->execute(stop);
  expect(
      stopped.status == NativeVideoDriverStatus::Completed &&
          stopped.completion.succeeded &&
          stopped.completion.invalidationGeneration == 1 &&
          fixture.session->destroyCalls == 0,
      "quiescent failed-factory tombstone yields a fresh nonzero Stop proof");

  Action allow = action(Action::Kind::AllowMpvRenderer, fixture.token, 5);
  allow.value = 1;
  expect(fixture.driver->execute(allow).completion.succeeded &&
             fixture.render->allowCalls == 1,
         "tombstone Stop proof permits ordered Allow only after a real Revoke");

  const Action repeatedStop =
      action(Action::Kind::StopNative, fixture.token, 6);
  expect(fixture.driver->execute(repeatedStop).status ==
                 NativeVideoDriverStatus::Rejected &&
             fixture.session->createCalls == 1,
         "consumed factory tombstone never generates a second Stop proof");
}

} // namespace

int main() {
  const auto run = [](auto test) {
    ++executedCases;
    test();
  };
  run(testConstructionIsInertAndOwnerGateIsFirst);
  run(testPauseRevokeAndExactReplay);
  run(testAsyncReplyIdentityAndNamespace);
  run(testSynchronousReplySeesPublishedFlight);
  run(testWholeBoundaryReentrancyIsSuppressed);
  run(testSynchronousReplyIsTheOnlyQueueReentry);
  run(testSessionFactsSampleAndNativeMapping);
  run(testNativeSessionActionsRequireRendererDenial);
  run(testDispatchAndSurfaceEnumsAreNormalized);
  run(testReanchorOrderAndReadbackValidation);
  run(testStartSeekStopAndAllowOrdering);
  run(testMalformedPendingStopEventsFailClosed);
  run(testMalformedSynchronousStopsAndEventKindFailClosed);
  run(testCaptionErrorAndDestructorNeverAllow);
  run(testStopBurnsFactsAndSessionOneShot);
  run(testNonPendingStopAlwaysDestroysSession);
  run(testFailedSessionFactoryHasQuiescentStopProof);
  expect(executedCases == 17,
         "all deterministic adapter test cases are executed");
  if (failures != 0) {
    std::cerr << failures << " native video action driver test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native video action driver tests passed\n";
  return EXIT_SUCCESS;
}
