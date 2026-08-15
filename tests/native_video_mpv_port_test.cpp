#include "mpv_command_reply_namespace.hpp"
#include "platform/macos/native_video_mpv_port.hpp"

#include <QCoreApplication>
#include <QThread>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

using wam::macos::MacosNativeVideoMpvPort;
using wam::macos::NativeVideoMpvCallSeam;
using wam::macos::NativeVideoMpvCaptionResolver;
using wam::macos::NativeVideoMpvErrorSink;
using wam::macos::NativeVideoMpvRestoreMode;
using wam::macos::NativeVideoMpvValueKind;
using wam::native_activation::FallbackReason;
using wam::native_activation::Transport;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    ++failures;
    std::cerr << "FAIL: " << message << '\n';
  }
}

struct CallState {
  double position{12.5};
  double speed{1.25};
  int pause{0};
  std::int64_t sid{7};
  std::int64_t forcedSidReadback{-1};
  int failGetAt{-1};
  int failSetAt{-1};
  int commandResult{0};
  int getCalls{0};
  int setCalls{0};
  std::uint64_t queuedReply{0};
  std::vector<std::string> operations;
  std::vector<std::string> arguments;
  MacosNativeVideoMpvPort *reenterPort{nullptr};
  bool reentryAttempted{false};
  bool reentryAccepted{false};
};

int getProperty(void *context, const char *name,
                NativeVideoMpvValueKind kind, void *value) noexcept {
  auto &state = *static_cast<CallState *>(context);
  ++state.getCalls;
  try {
    state.operations.emplace_back(std::string("get:") + name);
  } catch (...) {
    return -1;
  }
  if (state.getCalls == state.failGetAt || value == nullptr) {
    return -1;
  }
  const std::string property(name);
  if (property == "time-pos" && kind == NativeVideoMpvValueKind::Double) {
    *static_cast<double *>(value) = state.position;
    return 0;
  }
  if (property == "speed" && kind == NativeVideoMpvValueKind::Double) {
    *static_cast<double *>(value) = state.speed;
    return 0;
  }
  if (property == "pause" && kind == NativeVideoMpvValueKind::Flag) {
    *static_cast<int *>(value) = state.pause;
    return 0;
  }
  if (property == "sid" && kind == NativeVideoMpvValueKind::Int64) {
    *static_cast<std::int64_t *>(value) =
        state.forcedSidReadback >= 0 ? state.forcedSidReadback : state.sid;
    return 0;
  }
  return -1;
}

int setProperty(void *context, const char *name,
                NativeVideoMpvValueKind kind, void *value) noexcept {
  auto &state = *static_cast<CallState *>(context);
  ++state.setCalls;
  try {
    state.operations.emplace_back(std::string("set:") + name);
  } catch (...) {
    return -1;
  }
  if (state.setCalls == state.failSetAt || value == nullptr) {
    return -1;
  }
  const std::string property(name);
  if (property == "time-pos" && kind == NativeVideoMpvValueKind::Double) {
    state.position = *static_cast<double *>(value);
    return 0;
  }
  if (property == "speed" && kind == NativeVideoMpvValueKind::Double) {
    state.speed = *static_cast<double *>(value);
    return 0;
  }
  if (property == "pause" && kind == NativeVideoMpvValueKind::Flag) {
    state.pause = *static_cast<int *>(value);
    if (state.reenterPort != nullptr && !state.reentryAttempted) {
      state.reentryAttempted = true;
      state.reentryAccepted =
          state.reenterPort->queueSeekExact(
              wam::mpv_reply::kNativeVideoAdapterNamespace | 3, 4.0);
    }
    return 0;
  }
  if (property == "sid" && kind == NativeVideoMpvValueKind::Int64) {
    state.sid = *static_cast<std::int64_t *>(value);
    return 0;
  }
  return -1;
}

int commandAsync(void *context, std::uint64_t reply,
                 const char **arguments) noexcept {
  auto &state = *static_cast<CallState *>(context);
  state.queuedReply = reply;
  try {
    state.arguments.clear();
    for (std::size_t index = 0; arguments != nullptr &&
                                arguments[index] != nullptr;
         ++index) {
      state.arguments.emplace_back(arguments[index]);
    }
    state.operations.emplace_back("command");
  } catch (...) {
    return -1;
  }
  return state.commandResult;
}

struct CaptionState {
  std::uint64_t expectedId{0};
  std::uint64_t observedId{0};
  std::int64_t sid{-1};
  bool succeeds{true};
  int calls{0};
};

bool resolveCaption(void *context, std::uint64_t captionId,
                    std::int64_t *sid) noexcept {
  auto &state = *static_cast<CaptionState *>(context);
  ++state.calls;
  state.observedId = captionId;
  if (!state.succeeds || captionId != state.expectedId || sid == nullptr) {
    return false;
  }
  *sid = state.sid;
  return true;
}

struct ErrorState {
  FallbackReason observed{FallbackReason::Unsupported};
  bool succeeds{true};
  int calls{0};
};

bool surfaceError(void *context, FallbackReason reason) noexcept {
  auto &state = *static_cast<ErrorState *>(context);
  ++state.calls;
  state.observed = reason;
  return state.succeeds;
}

struct Fixture {
  CallState calls;
  CaptionState captions;
  ErrorState errors;
  std::unique_ptr<MacosNativeVideoMpvPort> port;

  Fixture() {
    captions.expectedId = std::numeric_limits<std::uint64_t>::max() - 19;
    captions.sid = 41;
    std::string error;
    port = MacosNativeVideoMpvPort::createInjected(
        NativeVideoMpvCallSeam{&calls, &getProperty, &setProperty,
                               &commandAsync},
        QThread::currentThread(),
        NativeVideoMpvCaptionResolver{&captions, &resolveCaption},
        NativeVideoMpvErrorSink{&errors, &surfaceError}, &error);
    expect(port != nullptr && error.empty(),
           "valid injected port is created without touching real mpv");
  }
};

void expectArguments(const CallState &state,
                     std::initializer_list<const char *> expected,
                     const char *message) {
  if (state.arguments.size() != expected.size()) {
    expect(false, message);
    return;
  }
  std::size_t index = 0;
  for (const char *value : expected) {
    if (state.arguments[index++] != value) {
      expect(false, message);
      return;
    }
  }
}

void testNamespaceContract() {
  using namespace wam::mpv_reply;
  expect(classify(17) == Namespace::ObservedProperty,
         "00 userdata remains observed-property space");
  expect(classify(kRenderRecoveryNamespace | 17) == Namespace::RenderRecovery,
         "01 userdata remains render-recovery space");
  expect(classify(kOpenNamespace | 17) == Namespace::Open,
         "10 userdata remains open space");
  expect(classify(kScrubCommandTag | 17) == Namespace::Open,
         "scrub stays within the 10 open family");
  expect(classify(kNativeVideoAdapterNamespace | 17) ==
             Namespace::NativeVideoAdapter,
         "11 userdata is reserved for native action adapter replies");
  expect(!isNativeVideoAdapter(kNativeVideoAdapterNamespace) &&
             isNativeVideoAdapter(kNativeVideoAdapterNamespace | 1),
         "native adapter rejects the zero value and accepts nonzero 11 IDs");
}

void testCreationValidation() {
  CallState calls;
  CaptionState captions{1, 0, 2, true, 0};
  ErrorState errors;
  std::string error;
  auto missingCalls = MacosNativeVideoMpvPort::createInjected(
      {}, QThread::currentThread(),
      NativeVideoMpvCaptionResolver{&captions, &resolveCaption},
      NativeVideoMpvErrorSink{&errors, &surfaceError}, &error);
  expect(!missingCalls && !error.empty(), "incomplete call seam is rejected");

  error = "old";
  auto noOwner = MacosNativeVideoMpvPort::createInjected(
      NativeVideoMpvCallSeam{&calls, &getProperty, &setProperty,
                             &commandAsync},
      nullptr, NativeVideoMpvCaptionResolver{&captions, &resolveCaption},
      NativeVideoMpvErrorSink{&errors, &surfaceError}, &error);
  expect(!noOwner && !error.empty(), "null owner thread is rejected");

  error = "old";
  auto noHandle = MacosNativeVideoMpvPort::create(
      nullptr, nullptr, QThread::currentThread(),
      NativeVideoMpvCaptionResolver{&captions, &resolveCaption},
      NativeVideoMpvErrorSink{&errors, &surfaceError}, &error);
  expect(!noHandle && !error.empty(), "null production mpv handle is rejected");
}

void testForcePauseSequenceAndFailures() {
  Fixture fixture;
  const auto result = fixture.port->forcePauseAndReadback();
  expect(result == Transport{12.5, 1.25, true},
         "ForcePause returns authoritative post-write transport");
  expect(fixture.calls.operations ==
             std::vector<std::string>{"get:time-pos", "get:speed", "get:pause",
                                      "set:pause", "get:time-pos", "get:speed",
                                      "get:pause"},
         "ForcePause reads position/speed/pause, pauses, then reads back");

  Fixture preReadFailure;
  preReadFailure.calls.failGetAt = 2;
  expect(!preReadFailure.port->forcePauseAndReadback() &&
             preReadFailure.calls.setCalls == 0,
         "ForcePause does not mutate after an incomplete initial snapshot");

  Fixture writeFailure;
  writeFailure.calls.failSetAt = 1;
  expect(!writeFailure.port->forcePauseAndReadback(),
         "ForcePause fails closed when pause write fails");

  Fixture readbackFailure;
  readbackFailure.calls.failGetAt = 4;
  expect(!readbackFailure.port->forcePauseAndReadback(),
         "ForcePause fails closed when authoritative readback fails");

  Fixture invalidReadback;
  invalidReadback.calls.pause = 2;
  expect(!invalidReadback.port->forcePauseAndReadback(),
         "non-boolean mpv pause readback fails closed");

  Fixture reentrant;
  reentrant.calls.reenterPort = reentrant.port.get();
  expect(reentrant.port->forcePauseAndReadback().has_value() &&
             reentrant.calls.reentryAttempted &&
             !reentrant.calls.reentryAccepted,
         "synchronous callback reentry is rejected without corrupting call");
}

void testRestoreSequenceAndFailures() {
  Fixture fixture;
  const Transport desired{44.125, 1.5, false};
  expect(fixture.port->restoreAndReadback(desired) == desired,
         "Restore returns exact authoritative readback");
  expect(fixture.calls.operations ==
             std::vector<std::string>{"set:time-pos", "set:speed", "set:pause",
                                      "get:time-pos", "get:speed", "get:pause"},
         "Restore writes position, speed, pause in exact order then reads back");

  for (int failingSet = 1; failingSet <= 3; ++failingSet) {
    Fixture failed;
    failed.calls.failSetAt = failingSet;
    expect(!failed.port->restoreAndReadback(desired),
           "each Restore write failure fails closed");
    expect(failed.calls.getCalls == 0,
           "Restore never reports partial state as authoritative");
  }

  Fixture failedReadback;
  failedReadback.calls.failGetAt = 2;
  expect(!failedReadback.port->restoreAndReadback(desired),
         "Restore readback failure fails closed");

  Fixture postSeek;
  postSeek.calls.position = desired.position;
  expect(postSeek.port->restoreAndReadback(
             desired,
             NativeVideoMpvRestoreMode::SpeedPauseVerifyPosition) == desired,
         "post-seek Restore accepts an authoritative exact-seek position");
  expect(postSeek.calls.operations ==
             std::vector<std::string>{"set:speed", "set:pause",
                                      "get:time-pos", "get:speed", "get:pause"},
         "post-seek Restore never issues a second time-pos seek");

  Fixture invalid;
  expect(!invalid.port->restoreAndReadback(
             Transport{std::numeric_limits<double>::quiet_NaN(), 1.0, true}) &&
             invalid.calls.operations.empty(),
         "invalid desired transport never reaches mpv");
}

void testExactQueuedCommands() {
  constexpr std::uint64_t reply =
      wam::mpv_reply::kNativeVideoAdapterNamespace | 91;
  Fixture fixture;
  expect(fixture.port->queueLoadAudioOnly(
             reply, std::filesystem::path("/tmp/a movie.mkv")),
         "audio-only load queues successfully");
  expect(fixture.calls.queuedReply == reply,
         "reply userdata passes to call seam without reinterpretation");
  expectArguments(fixture.calls,
                  {"loadfile", "/tmp/a movie.mkv", "replace", "-1", "vid=no"},
                  "loadfile uses source replace -1 vid=no exactly");

  expect(fixture.port->queueSeekExact(reply, 12.375),
         "finite nonnegative exact seek queues");
  expectArguments(fixture.calls, {"seek", "12.375", "absolute+exact"},
                  "seek uses exact absolute mode and locale-free number");

  expect(fixture.port->queueSelectVideo(
             reply, std::numeric_limits<std::int64_t>::max()),
         "positive maximum int64 video ID queues without truncation");
  expectArguments(fixture.calls,
                  {"set", "vid", "9223372036854775807"},
                  "numeric vid command preserves the exact signed ID");

  fixture.calls.commandResult = -1;
  expect(!fixture.port->queueSeekExact(reply, 1.0),
         "negative async queue result fails closed");

  fixture.calls.commandResult = 0;
  const std::size_t operationCount = fixture.calls.operations.size();
  expect(!fixture.port->queueLoadAudioOnly(
             wam::mpv_reply::kOpenNamespace | 1, "/tmp/file.mp4") &&
             !fixture.port->queueSeekExact(
                 wam::mpv_reply::kRenderRecoveryNamespace | 1, 0.0) &&
             !fixture.port->queueSelectVideo(
                 wam::mpv_reply::kNativeVideoAdapterNamespace, 4) &&
             fixture.calls.operations.size() == operationCount,
         "foreign namespaces and zero native reply value never queue");
  expect(!fixture.port->queueSeekExact(reply, -1.0) &&
             !fixture.port->queueSeekExact(
                 reply, std::numeric_limits<double>::infinity()) &&
             !fixture.port->queueSelectVideo(reply, 0),
         "invalid command values are rejected before the call seam");
}

void testCaptionResolverAndErrorSink() {
  Fixture fixture;
  expect(fixture.port->attachCaption(fixture.captions.expectedId),
         "resolved existing caption SID is synchronously selected");
  expect(fixture.captions.observedId == fixture.captions.expectedId &&
             fixture.calls.sid == fixture.captions.sid,
         "opaque uint64 caption ID is preserved through exact resolver");

  Fixture missing;
  missing.captions.succeeds = false;
  expect(!missing.port->attachCaption(missing.captions.expectedId) &&
             missing.calls.setCalls == 0,
         "missing caption registry entry fails without selecting an SID");

  Fixture invalidSid;
  invalidSid.captions.sid = 0;
  expect(!invalidSid.port->attachCaption(invalidSid.captions.expectedId) &&
             invalidSid.calls.setCalls == 0,
         "resolver cannot reinterpret an opaque caption ID as sid=no");

  Fixture mismatch;
  mismatch.calls.forcedSidReadback = 99;
  expect(!mismatch.port->attachCaption(mismatch.captions.expectedId),
         "caption SID mismatch fails closed");

  Fixture failedReadback;
  failedReadback.calls.failGetAt = 1;
  expect(!failedReadback.port->attachCaption(
             failedReadback.captions.expectedId),
         "caption readback failure fails closed");
  expect(!mismatch.port->attachCaption(0), "zero caption identity is rejected");

  Fixture error;
  expect(error.port->surfaceError(FallbackReason::PlaylistChange) &&
             error.errors.calls == 1 &&
             error.errors.observed == FallbackReason::PlaylistChange,
         "surface-error sink receives the exact fallback enum once");
  expect(!error.port->surfaceError(static_cast<FallbackReason>(255)) &&
             error.errors.calls == 1,
         "invalid fallback enum never crosses the callback boundary");
}

class OffOwnerThread final : public QThread {
public:
  MacosNativeVideoMpvPort *port{nullptr};
  bool queueAccepted{true};
  bool pauseAccepted{true};
  bool restoreAccepted{true};
  bool captionAccepted{true};
  bool errorAccepted{true};

  void run() override {
    const auto reply = wam::mpv_reply::kNativeVideoAdapterNamespace | 12;
    queueAccepted = port->queueSeekExact(reply, 1.0);
    pauseAccepted = port->forcePauseAndReadback().has_value();
    restoreAccepted =
        port->restoreAndReadback(Transport{1.0, 1.0, true}).has_value();
    captionAccepted = port->attachCaption(1);
    errorAccepted = port->surfaceError(FallbackReason::MpvFailure);
  }
};

void testOwnerThreadConfinement() {
  Fixture fixture;
  OffOwnerThread thread;
  thread.port = fixture.port.get();
  thread.start();
  expect(thread.wait(5000), "off-owner confinement probe joins promptly");
  expect(!thread.queueAccepted && !thread.pauseAccepted &&
             !thread.restoreAccepted && !thread.captionAccepted &&
             !thread.errorAccepted && fixture.calls.operations.empty() &&
             fixture.captions.calls == 0 && fixture.errors.calls == 0,
         "all off-owner operations are inert and fail closed");
}

} // namespace

int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  testNamespaceContract();
  testCreationValidation();
  testForcePauseSequenceAndFailures();
  testRestoreSequenceAndFailures();
  testExactQueuedCommands();
  testCaptionResolverAndErrorSink();
  testOwnerThreadConfinement();
  if (failures != 0) {
    std::cerr << failures << " native mpv port test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native mpv port tests passed\n";
  return EXIT_SUCCESS;
}
