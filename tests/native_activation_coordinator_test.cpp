#include "qt/native_activation_coordinator.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <utility>

namespace {

using wam::native_activation::Action;
using wam::native_activation::ActionCompletion;
using wam::native_activation::CancelMode;
using wam::native_activation::FallbackReason;
using wam::native_activation::MpvReady;
using wam::native_activation::NativeActivationCoordinator;
using wam::native_activation::NativeSample;
using wam::native_activation::Phase;
using wam::native_activation::Token;
using wam::native_activation::Transport;

int failures = 0;

void expect(bool condition, const char *message) {
  if (condition)
    return;
  std::cerr << "FAIL: " << message << '\n';
  ++failures;
}

void expectKind(const Action &action, Action::Kind kind, const char *message) {
  expect(action.kind == kind, message);
}

MpvReady ready(std::uint64_t source = 99, std::int64_t entry = 7,
               std::int64_t video = 3, double position = 0.0) {
  MpvReady value;
  value.entry = entry;
  value.sourceKey = source;
  value.videoId = video;
  value.live = Transport{position, 1.0, true};
  value.singletonPlaylist = true;
  value.authoritativeAudio = true;
  value.subtitleFree = true;
  value.exactlyOneNonAlbumartVideo = true;
  value.belongsToRequestLineage = true;
  return value;
}

struct Prepared {
  Token token;
  Action start;
};

Prepared prepareForStart(NativeActivationCoordinator &coordinator,
                         std::uint64_t request = 1,
                         std::uint64_t pre_revoke_generation = 10) {
  const auto token = coordinator.begin(request, 99, Transport{0.0, 1.0, false});
  expect(token.has_value(), "valid begin returns a token");
  if (!token)
    return {};
  const Action pause = *coordinator.nextAction();
  expectKind(pause, Action::Kind::ForcePauseMpv,
             "begin first force-pauses mpv");
  const Action revoke = coordinator.completeAction(pause.serial, {});
  expectKind(revoke, Action::Kind::RevokeMpvRenderer,
             "pause acknowledgement orders renderer revocation");
  ActionCompletion revoked;
  revoked.preRevokeGeneration = pre_revoke_generation;
  const Action load = coordinator.completeAction(revoke.serial, revoked);
  expectKind(load, Action::Kind::LoadMpvAudioOnly,
             "revocation orders the audio-only load");
  static_cast<void>(coordinator.mpvReady(*token, ready()));
  const Action prepare = coordinator.completeAction(load.serial, {});
  expectKind(prepare, Action::Kind::PrepareNative,
             "load acknowledgement orders native preparation");
  expect(coordinator.snapshot().nativeRequestIssued,
         "published PrepareNative owns conservative cleanup");
  static_cast<void>(coordinator.nativePrepared(*token, 41));
  static_cast<void>(coordinator.completeAction(prepare.serial, {}));
  expect(coordinator.snapshot().phase == Phase::AwaitRelease,
         "metadata and native preparation converge at AwaitRelease");
  const Action start = coordinator.evaluateRelease(*token, false, false, true,
                                                   pre_revoke_generation);
  expectKind(start, Action::Kind::StartNative,
             "settled Empty renderer admits native start");
  return {*token, start};
}

Token activate(NativeActivationCoordinator &coordinator,
               std::uint64_t request = 1) {
  const Prepared prepared = prepareForStart(coordinator, request);
  ActionCompletion accepted;
  accepted.generation = 51;
  accepted.drawBaseline = 8;
  static_cast<void>(
      coordinator.completeAction(prepared.start.serial, accepted));
  NativeSample sample;
  sample.active = true;
  sample.generation = 51;
  sample.acceptedGeneration = 51;
  sample.lastRenderedGeneration = 51;
  sample.acceptedRenderedFrames = 9;
  const Action restore = coordinator.sampleNative(prepared.token, sample);
  expectKind(restore, Action::Kind::RestoreTransport,
             "first exact native draw restores transport");
  static_cast<void>(coordinator.completeAction(restore.serial, {}));
  expect(coordinator.snapshot().phase == Phase::Active,
         "transport acknowledgement activates native playback");
  return prepared.token;
}

ActionCompletion pausedAt(double position, double rate = 1.0) {
  ActionCompletion completion;
  completion.liveTransport = Transport{position, rate, true};
  return completion;
}

ActionCompletion stoppedAt(std::uint64_t invalidation_generation) {
  ActionCompletion completion;
  completion.invalidationGeneration = invalidation_generation;
  return completion;
}

void expectIdle(const NativeActivationCoordinator &coordinator,
                const char *message) {
  const auto snapshot = coordinator.snapshot();
  expect(snapshot.phase == Phase::Idle && !snapshot.token &&
             !snapshot.pendingAction && !snapshot.nativeRequestIssued &&
             !snapshot.rendererDenied && !snapshot.cancelPending,
         message);
}

void driveFallbackToRenderer(NativeActivationCoordinator &coordinator,
                             Token token, double live_position = 18.25,
                             std::uint64_t stop_generation = 70) {
  const Action pause = coordinator.nativeFailed(token);
  expectKind(pause, Action::Kind::ForcePauseMpv,
             "fallback begins with an exact transport pause");
  const Action stop =
      coordinator.completeAction(pause.serial, pausedAt(live_position));
  expectKind(stop, Action::Kind::StopNative,
             "fallback pause completion orders native stop");
  const Action allow =
      coordinator.completeAction(stop.serial, stoppedAt(stop_generation));
  expectKind(allow, Action::Kind::AllowMpvRenderer,
             "safe native stop orders renderer allow");
  const Action settled = coordinator.completeAction(allow.serial, {});
  expectKind(settled, Action::Kind::None,
             "renderer allow settles without an extra mutation");
  expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer,
         "fallback waits for a newly ready renderer");
}

Token fallbackActive(NativeActivationCoordinator &coordinator,
                     std::uint64_t request = 1,
                     std::uint64_t render_stamp = 80) {
  const Token token = activate(coordinator, request);
  driveFallbackToRenderer(coordinator, token);
  static_cast<void>(coordinator.mpvReady(
      token, ready(99, 7, 3, coordinator.snapshot().desired.position)));
  const Action select = coordinator.fallbackRenderReady(token, render_stamp);
  expectKind(select, Action::Kind::SelectMpvVideo,
             "fallback renderer selects the captured video id");
  static_cast<void>(coordinator.fallbackPlaybackRestart(
      token, render_stamp, 7, coordinator.snapshot().desired.position));
  const Action restore = coordinator.completeAction(select.serial, {});
  expectKind(restore, Action::Kind::RestoreTransport,
             "select and restart converge on fallback restore");
  static_cast<void>(coordinator.completeAction(restore.serial, {}));
  expect(coordinator.snapshot().phase == Phase::FallbackActive,
         "fallback helper reaches active libmpv presentation");
  return token;
}

void testStartupAndCapacityOne() {
  NativeActivationCoordinator coordinator;
  expect(!coordinator.begin(0, 99, {}), "zero request is rejected");
  expect(!coordinator.begin(1, 0, {}), "zero source is rejected");
  expect(!coordinator.begin(1, 99, Transport{0.0, std::nan(""), true}),
         "non-finite rate is rejected");

  const auto token = coordinator.begin(1, 99, Transport{0.0, 1.25, false});
  expect(token.has_value(), "valid startup begins");
  const Action first = *coordinator.nextAction();
  expect(coordinator.nextAction() == first,
         "nextAction observes without popping");
  const Action stale = coordinator.completeAction(first.serial + 100, {});
  expect(stale == first, "stale completion cannot replace the pending action");
}

void testStartupDrawAndLatestIntent() {
  NativeActivationCoordinator coordinator;
  const Prepared prepared = prepareForStart(coordinator);
  expect(!coordinator.snapshot().armedRevocationGeneration,
         "same-generation Empty settlement disarms callback guard");
  ActionCompletion accepted;
  accepted.generation = 51;
  accepted.drawBaseline = 8;
  static_cast<void>(
      coordinator.completeAction(prepared.start.serial, accepted));

  NativeSample wrong;
  wrong.active = true;
  wrong.generation = 51;
  wrong.acceptedGeneration = 51;
  wrong.lastRenderedGeneration = 50;
  wrong.acceptedRenderedFrames = 9;
  expectKind(coordinator.sampleNative(prepared.token, wrong),
             Action::Kind::None, "wrong-generation draw cannot unpause audio");
  wrong.lastRenderedGeneration = 51;
  const Action restore = coordinator.sampleNative(prepared.token, wrong);
  expectKind(restore, Action::Kind::RestoreTransport,
             "matching first draw publishes one restore");
  expect(coordinator.sampleNative(prepared.token, wrong) == restore,
         "repeated draw preserves the capacity-one restore serial");
  static_cast<void>(coordinator.setDesiredRate(prepared.token, 1.75));
  const Action latest = coordinator.completeAction(restore.serial, {});
  expectKind(latest, Action::Kind::RestoreTransport,
             "intent changed behind restore is applied before Active");
  expect(latest.transport.rate == 1.75,
         "replacement restore carries latest user rate");
  static_cast<void>(coordinator.completeAction(latest.serial, {}));
  expect(coordinator.snapshot().phase == Phase::Active,
         "exact latest restore completes activation");
}

void testRapidSeekAndEofOrdering() {
  NativeActivationCoordinator coordinator;
  const Token token = activate(coordinator);
  const Action first_pause = coordinator.requestSeek(token, 20.0);
  const std::uint64_t first_epoch = coordinator.snapshot().transportEpoch;
  const Action held = coordinator.requestSeek(token, 30.0);
  const std::uint64_t latest_epoch = coordinator.snapshot().transportEpoch;
  expect(held == first_pause,
         "new seek never drops an issued pause acknowledgement");
  expect(latest_epoch != first_epoch, "new seek advances its epoch");
  const Action seek_native = coordinator.completeAction(first_pause.serial, {});
  expectKind(seek_native, Action::Kind::SeekNative,
             "old pause continues directly with latest native seek");
  expect(seek_native.epoch == latest_epoch,
         "coalesced native seek carries latest epoch");
  ActionCompletion native_seek;
  native_seek.generation = 60;
  native_seek.drawBaseline = 12;
  const Action seek_mpv =
      coordinator.completeAction(seek_native.serial, native_seek);
  expectKind(seek_mpv, Action::Kind::SeekMpvExact,
             "native seek orders exact mpv seek");
  static_cast<void>(coordinator.playbackRestart(token, latest_epoch, 7, 30.0));
  NativeSample draw;
  draw.active = true;
  draw.generation = 60;
  draw.acceptedGeneration = 60;
  draw.lastRenderedGeneration = 60;
  draw.acceptedRenderedFrames = 12;
  draw.attemptAcceptedRenderedFrames = 99;
  expectKind(coordinator.sampleNative(token, draw), Action::Kind::None,
             "attempt counter alone cannot satisfy seek draw");
  draw.acceptedRenderedFrames = 13;
  static_cast<void>(coordinator.sampleNative(token, draw));
  const Action restore = coordinator.completeAction(seek_mpv.serial, {});
  expectKind(restore, Action::Kind::RestoreTransport,
             "paired current seek signals publish restore");
  static_cast<void>(coordinator.completeAction(restore.serial, {}));

  const Action clock = coordinator.setDesiredRate(token, 1.2);
  expectKind(clock, Action::Kind::UpdateNativeClock,
             "active rate change updates the native clock");
  const Action held_clock = coordinator.eof(token, 7, 45.0);
  expect(held_clock == clock, "EOF preserves an issued clock action");
  const Action eof_restore = coordinator.completeAction(clock.serial, {});
  expectKind(eof_restore, Action::Kind::RestoreTransport,
             "EOF publishes paused restore after the clock acknowledgement");
  expect(eof_restore.transport.paused,
         "EOF restore keeps physical transport paused");
  static_cast<void>(coordinator.completeAction(eof_restore.serial, {}));
  expect(coordinator.snapshot().phase == Phase::EofHeld,
         "normal EOF retains the native frame");
}

void testFallbackAndEarlyRestart() {
  NativeActivationCoordinator coordinator;
  const Token token = activate(coordinator);
  const Action pause = coordinator.nativeFailed(token);
  expectKind(pause, Action::Kind::ForcePauseMpv,
             "native failure begins ordered fallback pause");
  ActionCompletion paused;
  paused.liveTransport = Transport{18.25, 1.0, true};
  const Action stop = coordinator.completeAction(pause.serial, paused);
  expectKind(stop, Action::Kind::StopNative,
             "fallback pause orders native stop");
  ActionCompletion stopped;
  stopped.invalidationGeneration = 70;
  const Action allow = coordinator.completeAction(stop.serial, stopped);
  expectKind(allow, Action::Kind::AllowMpvRenderer,
             "nonzero invalidation orders renderer permission restore");
  static_cast<void>(coordinator.completeAction(allow.serial, {}));
  expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer,
         "fallback waits for renderer and refreshed metadata");
  static_cast<void>(coordinator.mpvReady(
      token, ready(99, 7, 3, coordinator.snapshot().desired.position)));
  const Action select = coordinator.fallbackRenderReady(token, 80);
  expectKind(select, Action::Kind::SelectMpvVideo,
             "renderer and preserved metadata converge on exact video");
  const Action early = coordinator.fallbackPlaybackRestart(token, 80, 7, 18.25);
  expect(early == select,
         "early playback restart is retained behind select reply");
  const Action restore = coordinator.completeAction(select.serial, {});
  expectKind(restore, Action::Kind::RestoreTransport,
             "select reply converges with stored restart");
  static_cast<void>(coordinator.completeAction(restore.serial, {}));
  expect(coordinator.snapshot().phase == Phase::FallbackActive,
         "fallback restore reaches one-way libmpv playback");
}

void testCancellationEffectMatrix() {
  {
    NativeActivationCoordinator coordinator;
    const Token token = *coordinator.begin(1, 99, {});
    const Action pause = *coordinator.nextAction();
    expect(coordinator.cancelForStopOrOpen(CancelMode::Stop) == pause,
           "cancel retains an issued startup pause");
    static_cast<void>(coordinator.completeAction(pause.serial, {}));
    expect(coordinator.snapshot().phase == Phase::Idle,
           "cancel before revoke needs neither stop nor allow");
    expectKind(coordinator.nativeFailed(token), Action::Kind::None,
               "burned token callback is inert");
  }
  {
    NativeActivationCoordinator coordinator;
    const Token token = *coordinator.begin(2, 99, {});
    const Action pause = *coordinator.nextAction();
    const Action revoke = coordinator.completeAction(pause.serial, {});
    expect(coordinator.cancelForStopOrOpen(CancelMode::Stop) == revoke,
           "cancel retains an issued revoke");
    ActionCompletion revoked;
    revoked.preRevokeGeneration = 10;
    const Action allow = coordinator.completeAction(revoke.serial, revoked);
    expectKind(allow, Action::Kind::AllowMpvRenderer,
               "successful canceled revoke is always re-allowed");
    static_cast<void>(coordinator.completeAction(allow.serial, {}));
    expect(coordinator.snapshot().phase == Phase::Idle,
           "allow acknowledgement settles canceled request");
    expectKind(coordinator.nativePrepared(token, 1), Action::Kind::None,
               "late preparation callback stays inert");
  }
}

void testNonzeroBeginAndClockCoalescing() {
  {
    NativeActivationCoordinator coordinator;
    expect(!coordinator.begin(1, 99, Transport{5.0, 1.0, false}),
           "nonzero initial position is rejected until startup has an exact "
           "native seek contract");
    expectIdle(coordinator,
               "rejected nonzero startup leaves the coordinator pristine");
  }

  NativeActivationCoordinator coordinator;
  const Token token = activate(coordinator);
  const Action first = coordinator.setDesiredRate(token, 1.25);
  expectKind(first, Action::Kind::UpdateNativeClock,
             "active rate edit publishes one clock update");
  const Action held_pause = coordinator.setDesiredPause(token, true);
  const Action held_rate = coordinator.setDesiredRate(token, 1.75);
  expect(held_pause == first && held_rate == first &&
             coordinator.nextAction() == first,
         "rapid pause/rate edits retain the issued serial until its reply");
  const Action latest = coordinator.completeAction(first.serial, {});
  expectKind(latest, Action::Kind::UpdateNativeClock,
             "issued clock reply publishes one coalesced latest update");
  expect(latest.serial != first.serial && latest.transport.paused &&
             latest.transport.rate == 1.75,
         "coalesced clock update carries the latest pause and rate intent");
  const Action done = coordinator.completeAction(latest.serial, {});
  expectKind(done, Action::Kind::None,
             "latest clock acknowledgement drains the capacity-one slot");
  expect(!coordinator.nextAction(),
         "rapid clock edits produce exactly one follow-up mutation");
}

void testRevocationGenerationSettlement() {
  NativeActivationCoordinator coordinator;
  const auto token = coordinator.begin(1, 99, Transport{0.0, 1.0, false});
  expect(token.has_value(), "revocation settlement startup begins");
  if (!token)
    return;
  const Action pause = *coordinator.nextAction();
  const Action revoke = coordinator.completeAction(pause.serial, {});
  ActionCompletion revoked;
  revoked.preRevokeGeneration = 10;
  const Action load = coordinator.completeAction(revoke.serial, revoked);
  static_cast<void>(coordinator.mpvReady(*token, ready()));
  const Action prepare = coordinator.completeAction(load.serial, {});
  static_cast<void>(coordinator.nativePrepared(*token, 41));
  static_cast<void>(coordinator.completeAction(prepare.serial, {}));
  const Action start =
      coordinator.evaluateRelease(*token, false, false, true, 11);
  expectKind(start, Action::Kind::StartNative,
             "one-generation-advanced Empty renderer admits start");
  const auto settled = coordinator.snapshot();
  expect(!settled.armedRevocationGeneration &&
             settled.ignoredRetiredGenerationCount == 1 &&
             settled.ignoredRetiredGenerations[0] == 10,
         "advanced Empty settlement retains one exact late invalidation");
  expect(coordinator.consumeExpectedRevocationGeneration(10) &&
             !coordinator.consumeExpectedRevocationGeneration(10),
         "retained invalidation is consumed exactly once");
  expect(!coordinator.consumeExpectedRevocationGeneration(9) &&
             !coordinator.consumeExpectedRevocationGeneration(11),
         "unrelated lifecycle generations are never swallowed");

  expect(coordinator.cancelForStopOrOpen(CancelMode::Stop) == start,
         "cancel retains the issued StartNative acknowledgement");
  const Action stop = coordinator.completeAction(start.serial, {});
  expectKind(stop, Action::Kind::StopNative,
             "canceled start conservatively orders native stop");
  const Action allow = coordinator.completeAction(stop.serial, stoppedAt(12));
  expectKind(allow, Action::Kind::AllowMpvRenderer,
             "canceled safe stop always restores renderer permission");
  static_cast<void>(coordinator.completeAction(allow.serial, {}));
  expectIdle(coordinator, "revocation settlement cancellation reaches Idle");

  const Prepared next = prepareForStart(coordinator, 2, 30);
  expectKind(next.start, Action::Kind::StartNative,
             "a settled old revocation guard never blocks a later begin");
  expect(coordinator.cancelForStopOrOpen(CancelMode::SupersededByMpvOpen) ==
             next.start,
         "later attempt can still be canceled deterministically");
  const Action next_stop = coordinator.completeAction(next.start.serial, {});
  const Action next_allow =
      coordinator.completeAction(next_stop.serial, stoppedAt(31));
  static_cast<void>(coordinator.completeAction(next_allow.serial, {}));
  expectIdle(coordinator, "later attempt cleanup also reaches Idle");
}

void testExpandedCancellationMatrix() {
  {
    NativeActivationCoordinator coordinator;
    const Token token = *coordinator.begin(1, 99, Transport{0.0, 1.0, false});
    const Action pause = *coordinator.nextAction();
    const Action revoke = coordinator.completeAction(pause.serial, {});
    ActionCompletion revoked;
    revoked.preRevokeGeneration = 10;
    const Action load = coordinator.completeAction(revoke.serial, revoked);
    const Action prepare = coordinator.completeAction(load.serial, {});
    expectKind(prepare, Action::Kind::PrepareNative,
               "prepare is actually issued before cancellation owns native");
    expect(coordinator.snapshot().nativeRequestIssued,
           "issued PrepareNative sets native cleanup ownership");
    expect(coordinator.cancelForStopOrOpen(CancelMode::SupersededByMpvOpen) ==
               prepare,
           "open supersession retains the issued prepare serial");
    expectKind(coordinator.nativePrepared(token, 41), Action::Kind::None,
               "burned callbacks are inert while cancellation waits");
    const Action stop = coordinator.completeAction(prepare.serial, {});
    expectKind(stop, Action::Kind::StopNative,
               "prepare acknowledgement under cancel orders stop");
    const Action allow = coordinator.completeAction(stop.serial, stoppedAt(20));
    expectKind(allow, Action::Kind::AllowMpvRenderer,
               "prepare cancellation safely re-allows after stop");
    static_cast<void>(coordinator.completeAction(allow.serial, {}));
    expectIdle(coordinator, "prepare cancellation fully resets attempt state");
  }

  {
    NativeActivationCoordinator coordinator;
    const auto token = coordinator.begin(2, 99, Transport{0.0, 1.0, false});
    expect(token.has_value(), "surface-error cancellation startup begins");
    const Action pause = *coordinator.nextAction();
    ActionCompletion failed;
    failed.succeeded = false;
    const Action error = coordinator.completeAction(pause.serial, failed);
    expectKind(error, Action::Kind::SurfaceError,
               "failure before any side effect publishes an error");
    expect(coordinator.cancelForStopOrOpen(CancelMode::Stop) == error,
           "cancel preserves a pending error serial");
    const Action settled = coordinator.completeAction(error.serial, {});
    expectKind(settled, Action::Kind::None,
               "pending error cancellation needs no phantom mutation");
    expectIdle(coordinator, "pending surface-error cancellation reaches Idle");
  }

  {
    NativeActivationCoordinator coordinator;
    static_cast<void>(coordinator.begin(3, 99, Transport{0.0, 1.0, false}));
    const Action pause = *coordinator.nextAction();
    const Action revoke = coordinator.completeAction(pause.serial, {});
    ActionCompletion revoked;
    revoked.preRevokeGeneration = 10;
    const Action load = coordinator.completeAction(revoke.serial, revoked);
    const Action prepare = coordinator.completeAction(load.serial, {});
    static_cast<void>(
        coordinator.cancelForStopOrOpen(CancelMode::SupersededByMpvOpen));
    const Action stop = coordinator.completeAction(prepare.serial, {});
    ActionCompletion failed_stop;
    failed_stop.succeeded = false;
    const Action error = coordinator.completeAction(stop.serial, failed_stop);
    expectKind(error, Action::Kind::SurfaceError,
               "failed canceled stop surfaces one terminal error");
    const Action after_error = coordinator.completeAction(error.serial, {});
    expect(after_error.kind != Action::Kind::StopNative,
           "surface-error acknowledgement never auto-retries failed Stop");
    expect(!coordinator.nextAction() ||
               coordinator.nextAction()->kind != Action::Kind::StopNative,
           "failed Stop cannot enter an unbounded retry loop");
  }

  {
    NativeActivationCoordinator coordinator;
    static_cast<void>(coordinator.begin(4, 99, Transport{0.0, 1.0, false}));
    const Action pause = *coordinator.nextAction();
    const Action revoke = coordinator.completeAction(pause.serial, {});
    static_cast<void>(coordinator.cancelForStopOrOpen(CancelMode::Stop));
    ActionCompletion revoked;
    revoked.preRevokeGeneration = 10;
    const Action allow = coordinator.completeAction(revoke.serial, revoked);
    ActionCompletion failed_allow;
    failed_allow.succeeded = false;
    const Action error = coordinator.completeAction(allow.serial, failed_allow);
    expectKind(error, Action::Kind::SurfaceError,
               "failed canceled Allow surfaces one terminal error");
    const Action after_error = coordinator.completeAction(error.serial, {});
    expect(after_error.kind != Action::Kind::AllowMpvRenderer,
           "surface-error acknowledgement never auto-retries failed Allow");
    expect(!coordinator.nextAction() ||
               coordinator.nextAction()->kind != Action::Kind::AllowMpvRenderer,
           "failed Allow cannot enter an unbounded retry loop");
  }
}

void testFallbackMetadataAndRendererInvalidation() {
  NativeActivationCoordinator coordinator;
  const Token token = activate(coordinator);
  driveFallbackToRenderer(coordinator, token);
  expect(!coordinator.snapshot().mpvReady,
         "renderer Allow invalidates pre-fallback metadata freshness");

  const Action no_metadata = coordinator.fallbackRenderReady(token, 80);
  expectKind(no_metadata, Action::Kind::None,
             "renderer readiness alone cannot reuse pre-Allow metadata");
  const Action select = coordinator.mpvReady(
      token, ready(99, 7, 3, coordinator.snapshot().desired.position));
  expectKind(select, Action::Kind::SelectMpvVideo,
             "fresh exact metadata and Ready stamp select captured video");
  expect(select.videoId == 3 && select.value == 80,
         "selection binds the exact refreshed video and renderer stamp");

  const Action wrong_stamp =
      coordinator.fallbackPlaybackRestart(token, 81, 7, 18.25);
  const Action wrong_entry =
      coordinator.fallbackPlaybackRestart(token, 80, 8, 18.25);
  const Action wrong_position =
      coordinator.fallbackPlaybackRestart(token, 80, 7, 19.0);
  expectKind(wrong_stamp, Action::Kind::None,
             "wrong renderer stamp cannot converge fallback");
  expectKind(wrong_entry, Action::Kind::None,
             "wrong playlist entry cannot converge fallback");
  expectKind(wrong_position, Action::Kind::None,
             "nonconverged playback position cannot converge fallback");
  expect(coordinator.nextAction() == select,
         "mismatched restart events cannot overwrite pending selection");

  expect(coordinator.fallbackPlaybackRestart(token, 80, 7, 18.25) == select,
         "matching early restart is retained behind selection");
  const Action restore = coordinator.completeAction(select.serial, {});
  expectKind(restore, Action::Kind::RestoreTransport,
             "selection and early restart publish fallback restore");
  expectKind(coordinator.fallbackRendererInvalidated(token, 79),
             Action::Kind::None, "unrelated renderer invalidation is ignored");
  expect(coordinator.nextAction() == restore,
         "unrelated invalidation leaves restore action intact");
  expect(coordinator.fallbackRendererInvalidated(token, 80) == restore,
         "exact invalidation retains the issued restore acknowledgement");
  expect(coordinator.snapshot().fallbackRendererInvalidationPending,
         "exact invalidation marks restore as belonging to a retired stamp");

  const Action repause = coordinator.completeAction(restore.serial, {});
  expectKind(repause, Action::Kind::ForcePauseMpv,
             "retired pending restore force-pauses before new convergence");
  expect(repause.transport.paused,
         "renderer-loss recovery never lets audio run ahead");
  const Action waiting =
      coordinator.completeAction(repause.serial, pausedAt(18.25));
  expectKind(waiting, Action::Kind::None,
             "renderer-loss pause waits for a new Ready stamp");
  expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer,
         "retired restore returns to renderer convergence");
  expectKind(coordinator.fallbackPlaybackRestart(token, 80, 7, 18.25),
             Action::Kind::None,
             "restart from retired renderer stamp remains quarantined");
  expectKind(coordinator.fallbackRenderReady(token, 80), Action::Kind::None,
             "retired renderer Ready stamp cannot be replayed");
  expect(!coordinator.nextAction(),
         "retired Ready replay cannot select video or occupy the action slot");

  const Action reselection = coordinator.fallbackRenderReady(token, 81);
  expectKind(reselection, Action::Kind::SelectMpvVideo,
             "new renderer stamp requires a fresh exact selection");
  static_cast<void>(coordinator.completeAction(reselection.serial, {}));
  const Action rerestore =
      coordinator.fallbackPlaybackRestart(token, 81, 7, 18.25);
  expectKind(rerestore, Action::Kind::RestoreTransport,
             "new selection and restart reconverge fallback");
  static_cast<void>(coordinator.completeAction(rerestore.serial, {}));
  expect(coordinator.snapshot().phase == Phase::FallbackActive,
         "renderer-loss recovery returns to fallback playback");
}

void testFallbackErrorsAndStopFailure() {
  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 10);
    const double original_position = coordinator.snapshot().desired.position;
    const Action pause = coordinator.nativeFailed(token);
    ActionCompletion not_paused;
    not_paused.liveTransport = Transport{99.0, 1.0, false};
    const Action stop = coordinator.completeAction(pause.serial, not_paused);
    expectKind(stop, Action::Kind::StopNative,
               "unconfirmed fallback pause still orders conservative stop");
    expect(coordinator.snapshot().desired.position == original_position,
           "live transport with paused=false cannot reanchor fallback");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator);
    const Action pause = coordinator.nativeFailed(token);
    const Action stop =
        coordinator.completeAction(pause.serial, pausedAt(18.25));
    ActionCompletion failed_stop;
    failed_stop.succeeded = false;
    const Action error = coordinator.completeAction(stop.serial, failed_stop);
    expectKind(error, Action::Kind::SurfaceError,
               "failed native stop surfaces a context failure");
    const auto failed = coordinator.snapshot();
    expect(failed.rendererDenied && failed.nativeRequestIssued &&
               failed.nativeBurned &&
               failed.fallbackReason == FallbackReason::ContextFailure,
           "failed stop remains denied and never pretends cleanup succeeded");
    expectKind(coordinator.nextAction().value_or(Action{}),
               Action::Kind::SurfaceError,
               "failed stop never publishes renderer Allow");
  }

  {
    NativeActivationCoordinator coordinator;
    const auto token = coordinator.begin(2, 99, Transport{0.0, 1.0, false});
    expect(token.has_value(), "audio-load failure startup begins");
    const Action pause = *coordinator.nextAction();
    const Action revoke = coordinator.completeAction(pause.serial, {});
    ActionCompletion revoked;
    revoked.preRevokeGeneration = 10;
    const Action load = coordinator.completeAction(revoke.serial, revoked);
    expect(coordinator.mpvLoadFailed(*token) == load,
           "load failure cannot overwrite the in-flight audio-only load");
    const Action allow = coordinator.completeAction(load.serial, {});
    expectKind(allow, Action::Kind::AllowMpvRenderer,
               "terminal audio-only load failure re-allows denied renderer");
    expect(!coordinator.snapshot().nativeRequestIssued,
           "failed audio-only load never invents a native request to stop");
    const Action error = coordinator.completeAction(allow.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "load failure surfaces immediately after renderer settlement");
    expect(error.value ==
               static_cast<std::uint64_t>(FallbackReason::MpvFailure),
           "terminal load error preserves its exact failure reason");
    static_cast<void>(coordinator.completeAction(error.serial, {}));
    expect(coordinator.snapshot().phase == Phase::Failed,
           "terminal load error reaches Failed without waiting for metadata");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = *coordinator.begin(20, 99, Transport{0.0, 1.0, false});
    const Action pause = *coordinator.nextAction();
    const Action revoke = coordinator.completeAction(pause.serial, {});
    ActionCompletion revoked;
    revoked.preRevokeGeneration = 10;
    const Action load = coordinator.completeAction(revoke.serial, revoked);
    ActionCompletion failed_load;
    failed_load.succeeded = false;
    const Action allow = coordinator.completeAction(load.serial, failed_load);
    expectKind(allow, Action::Kind::AllowMpvRenderer,
               "failed LoadMpvAudioOnly terminal-cleans renderer denial");
    expect(!coordinator.snapshot().nativeRequestIssued,
           "failed audio-only action never claims native request ownership");
    const Action error = coordinator.completeAction(allow.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "failed audio-only action surfaces after renderer allow");
    expect(error.value ==
               static_cast<std::uint64_t>(FallbackReason::MpvFailure),
           "failed audio-only completion is terminal mpv failure");
    static_cast<void>(token);
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 3);
    driveFallbackToRenderer(coordinator, token);
    static_cast<void>(coordinator.mpvReady(token, ready(99, 7, 3, 18.25)));
    const Action select = coordinator.fallbackRenderReady(token, 80);
    MpvReady wrong_source = ready(100, 7, 3, 18.25);
    expect(coordinator.mpvReady(token, wrong_source) == select,
           "wrong metadata behind Select cannot replace its serial");
    const Action error = coordinator.completeAction(select.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "deferred Select metadata mismatch surfaces at acknowledgement");
    expect(error.value ==
               static_cast<std::uint64_t>(FallbackReason::TrackContract),
           "wrong fallback source is classified as track-contract failure");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 4);
    driveFallbackToRenderer(coordinator, token);
    static_cast<void>(coordinator.mpvReady(token, ready(99, 7, 3, 18.25)));
    const Action select = coordinator.fallbackRenderReady(token, 80);
    static_cast<void>(coordinator.fallbackPlaybackRestart(token, 80, 7, 18.25));
    const Action restore = coordinator.completeAction(select.serial, {});
    expectKind(restore, Action::Kind::RestoreTransport,
               "fallback identity test reaches pending restore");
    MpvReady wrong_video = ready(99, 7, 4, 18.25);
    expect(coordinator.mpvReady(token, wrong_video) == restore,
           "wrong video behind Restore cannot replace its serial");
    const Action error = coordinator.completeAction(restore.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "deferred Restore identity mismatch surfaces immediately");
    expect(error.value == static_cast<std::uint64_t>(FallbackReason::Mismatch),
           "wrong fallback video is a one-way identity mismatch");
  }
}

void testSeekLatestIntentAndQuarantine() {
  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator);
    const Action pause = coordinator.requestSeek(token, 20.0);
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "seek first force-pauses physical transport");
    const std::uint64_t seek_epoch = coordinator.snapshot().seek->epoch;
    expectKind(coordinator.setDesiredRate(token, 1.5), Action::Kind::None,
               "rate edit cannot replace an issued seek pause");
    expectKind(coordinator.setDesiredPause(token, true), Action::Kind::None,
               "pause edit cannot replace an issued seek pause");
    expect(coordinator.nextAction() == pause,
           "pause/rate edits preserve the in-flight seek serial");
    const Action seek_native = coordinator.completeAction(pause.serial, {});
    expectKind(seek_native, Action::Kind::SeekNative,
               "seek pause acknowledgement orders native seek");
    expect(seek_native.epoch == seek_epoch,
           "pause/rate edits do not change the exact seek epoch");
    if (seek_native.kind != Action::Kind::SeekNative ||
        seek_native.epoch != seek_epoch)
      return;

    const double cached_before_stale = coordinator.snapshot().desired.position;
    static_cast<void>(coordinator.observeLiveTransport(
        token, seek_epoch - 1, 7, Transport{2.0, 1.0, false}));
    static_cast<void>(coordinator.observeLiveTransport(
        token, seek_epoch, 8, Transport{3.0, 1.0, false}));
    expect(coordinator.snapshot().desired.position == cached_before_stale,
           "stale epoch and wrong-entry live samples cannot reanchor seek");

    ActionCompletion native_seek;
    native_seek.generation = 60;
    native_seek.drawBaseline = 12;
    const Action seek_mpv =
        coordinator.completeAction(seek_native.serial, native_seek);
    expectKind(seek_mpv, Action::Kind::SeekMpvExact,
               "native seek acknowledgement orders exact mpv seek");
    if (seek_mpv.kind != Action::Kind::SeekMpvExact)
      return;

    expectKind(coordinator.playbackRestart(token, seek_epoch - 1, 7, 20.0),
               Action::Kind::None,
               "stale restart epoch cannot converge current seek");
    expectKind(coordinator.playbackRestart(token, seek_epoch, 7, 20.2),
               Action::Kind::None,
               "restart outside tolerance cannot converge current seek");
    NativeSample stale_draw;
    stale_draw.active = true;
    stale_draw.generation = 59;
    stale_draw.acceptedGeneration = 59;
    stale_draw.lastRenderedGeneration = 59;
    stale_draw.acceptedRenderedFrames = 99;
    expectKind(coordinator.sampleNative(token, stale_draw), Action::Kind::None,
               "stale native draw is ignored during exact mpv seek");
    expect(coordinator.nextAction() == seek_mpv,
           "stale native draw leaves exact mpv seek action untouched");

    NativeSample exact_draw;
    exact_draw.active = true;
    exact_draw.generation = 60;
    exact_draw.acceptedGeneration = 60;
    exact_draw.lastRenderedGeneration = 60;
    exact_draw.acceptedRenderedFrames = 13;
    expect(coordinator.sampleNative(token, exact_draw) == seek_mpv,
           "exact draw waits behind the issued mpv seek acknowledgement");
    expect(coordinator.playbackRestart(token, seek_epoch, 7, 20.0) == seek_mpv,
           "matching restart also waits behind the issued mpv seek");
    const Action restore = coordinator.completeAction(seek_mpv.serial, {});
    expectKind(restore, Action::Kind::RestoreTransport,
               "latest draw, restart, and seek reply converge on restore");
    expect(
        restore.transport.rate == 1.5 && restore.transport.paused &&
            restore.transport.position == 20.0,
        "final seek restore carries pause/rate edits made behind ForcePause");
    static_cast<void>(coordinator.setDesiredRate(token, 1.75));
    static_cast<void>(coordinator.setDesiredPause(token, false));
    const Action latest_restore =
        coordinator.completeAction(restore.serial, {});
    expectKind(latest_restore, Action::Kind::RestoreTransport,
               "intent changed behind seek restore emits one latest restore");
    expect(latest_restore.serial != restore.serial &&
               latest_restore.transport.rate == 1.75 &&
               !latest_restore.transport.paused &&
               latest_restore.transport.position == 20.0,
           "latest restore carries final pause/rate and exact seek target");
    static_cast<void>(coordinator.completeAction(latest_restore.serial, {}));
    expect(coordinator.snapshot().phase == Phase::Active,
           "latest seek restore returns to Active");

    const double settled_position = coordinator.snapshot().desired.position;
    expectKind(coordinator.playbackRestart(token, seek_epoch, 7, 19.99),
               Action::Kind::None,
               "post-seek restart callback is quarantined outside Seeking");
    static_cast<void>(coordinator.sampleNative(token, stale_draw));
    static_cast<void>(coordinator.observeLiveTransport(
        token, seek_epoch, 7, Transport{1.0, 1.0, false}));
    expect(coordinator.snapshot().desired.position == settled_position,
           "post-seek stale draw/live events cannot rewind transport");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 2);
    const Action pause = coordinator.requestSeek(token, 25.0);
    const auto seek = coordinator.snapshot().seek;
    expect(seek.has_value(), "early-restart seek owns an exact epoch");
    expectKind(coordinator.playbackRestart(token, seek->epoch, 7, 25.0),
               Action::Kind::None,
               "restart before SeekMpvExact publication is ignored");
    expect(coordinator.nextAction() == pause,
           "early restart cannot overwrite the issued seek pause");
    const Action seek_native = coordinator.completeAction(pause.serial, {});
    ActionCompletion native_seek;
    native_seek.generation = 61;
    native_seek.drawBaseline = 20;
    const Action seek_mpv =
        coordinator.completeAction(seek_native.serial, native_seek);
    NativeSample exact;
    exact.active = true;
    exact.generation = 61;
    exact.acceptedGeneration = 61;
    exact.lastRenderedGeneration = 61;
    exact.acceptedRenderedFrames = 21;
    expect(coordinator.sampleNative(token, exact) == seek_mpv,
           "exact draw remains held behind published mpv seek");
    const Action no_restore = coordinator.completeAction(seek_mpv.serial, {});
    expectKind(no_restore, Action::Kind::None,
               "restart before SeekMpvExact publication is not convergence");
    const Action restore =
        coordinator.playbackRestart(token, seek->epoch, 7, 25.0);
    expectKind(restore, Action::Kind::RestoreTransport,
               "restart observed after exact seek publication completes gate");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 3);
    const Action pause = coordinator.requestSeek(token, 30.0);
    expect(coordinator.nativeFailed(token) == pause,
           "native failure cannot overwrite an issued seek pause");
    const Action stop = coordinator.completeAction(pause.serial, {});
    expectKind(stop, Action::Kind::StopNative,
               "failed in-flight seek transitions directly to safe stop");
    const Action allow = coordinator.completeAction(stop.serial, stoppedAt(90));
    expectKind(allow, Action::Kind::AllowMpvRenderer,
               "failed seek re-allows only after nonzero stop generation");
    static_cast<void>(coordinator.completeAction(allow.serial, {}));
    NativeSample stale;
    stale.active = true;
    stale.generation = 60;
    stale.acceptedGeneration = 60;
    stale.lastRenderedGeneration = 60;
    stale.acceptedRenderedFrames = 100;
    expectKind(coordinator.sampleNative(token, stale), Action::Kind::None,
               "post-fallback seek draw cannot resurrect native playback");
    expectKind(coordinator.playbackRestart(token, 2, 7, 30.0),
               Action::Kind::None,
               "post-fallback seek restart cannot resurrect native playback");
    expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer,
           "failed seek remains one-way in fallback convergence");
  }
}

void testCaptionFallbackSuccessAndFailure() {
  auto reachCaption = [](NativeActivationCoordinator &coordinator,
                         std::uint64_t request, std::uint64_t caption_id) {
    const Token token = activate(coordinator, request);
    const Action pause = coordinator.requestCaption(token, caption_id);
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "caption request begins one-way fallback");
    const Action stop =
        coordinator.completeAction(pause.serial, pausedAt(12.0));
    const Action allow =
        coordinator.completeAction(stop.serial, stoppedAt(70 + request));
    static_cast<void>(coordinator.completeAction(allow.serial, {}));
    static_cast<void>(coordinator.mpvReady(token, ready(99, 7, 3, 12.0)));
    const Action select = coordinator.fallbackRenderReady(token, 80 + request);
    static_cast<void>(
        coordinator.fallbackPlaybackRestart(token, 80 + request, 7, 12.0));
    const Action restore = coordinator.completeAction(select.serial, {});
    const Action attach = coordinator.completeAction(restore.serial, {});
    expectKind(attach, Action::Kind::AttachCaption,
               "fallback restore defers caption attachment until convergence");
    expect(attach.captionId == caption_id,
           "caption action carries exact requested artifact identity");
    return std::pair<Token, Action>{token, attach};
  };

  {
    NativeActivationCoordinator coordinator;
    const auto [token, attach] = reachCaption(coordinator, 1, 42);
    static_cast<void>(token);
    const Action done = coordinator.completeAction(attach.serial, {});
    expectKind(done, Action::Kind::None,
               "successful caption attachment needs no extra mutation");
    expect(coordinator.snapshot().phase == Phase::FallbackActive &&
               !coordinator.snapshot().pendingCaptionId,
           "successful caption reaches fallback playback exactly once");
  }

  {
    NativeActivationCoordinator coordinator;
    const auto [token, attach] = reachCaption(coordinator, 2, 43);
    static_cast<void>(token);
    ActionCompletion failed;
    failed.succeeded = false;
    const Action error = coordinator.completeAction(attach.serial, failed);
    expectKind(error, Action::Kind::SurfaceError,
               "caption attachment failure surfaces one recoverable error");
    expect(error.value == static_cast<std::uint64_t>(FallbackReason::Caption),
           "caption error preserves its exact classification");
    const Action settled = coordinator.completeAction(error.serial, {});
    expectKind(settled, Action::Kind::None,
               "caption error acknowledgement does not tear down playback");
    expect(coordinator.snapshot().phase == Phase::FallbackActive &&
               !coordinator.snapshot().pendingCaptionId,
           "caption failure leaves fallback video active and clears request");
  }

  {
    NativeActivationCoordinator coordinator;
    const auto [token, first] = reachCaption(coordinator, 3, 44);
    expect(coordinator.requestCaption(token, 45) == first,
           "new caption waits behind the exact issued caption action");
    ActionCompletion failed;
    failed.succeeded = false;
    const Action latest = coordinator.completeAction(first.serial, failed);
    expectKind(latest, Action::Kind::AttachCaption,
               "superseded caption failure advances to the latest request");
    expect(latest.captionId == 45,
           "superseded caption failure preserves the newest caption ID");
    const Action done = coordinator.completeAction(latest.serial, {});
    expectKind(done, Action::Kind::None,
               "latest caption success settles without stale error surface");
    expect(coordinator.snapshot().phase == Phase::FallbackActive &&
               !coordinator.snapshot().pendingCaptionId,
           "latest caption request survives an older attachment failure");
  }
}

void testEofRaceAndIdentityQuarantine() {
  NativeActivationCoordinator coordinator;
  const Token token = activate(coordinator);
  const Action clock = coordinator.setDesiredRate(token, 1.2);
  expectKind(clock, Action::Kind::UpdateNativeClock,
             "EOF race begins with one issued clock mutation");
  expectKind(coordinator.eof(Token{token.request, token.attempt + 1}, 7, 45.0),
             Action::Kind::None, "wrong token EOF is inert");
  expectKind(coordinator.eof(token, 8, 45.0), Action::Kind::None,
             "wrong entry EOF is inert");
  expect(coordinator.nextAction() == clock,
         "wrong EOF callbacks leave the clock serial untouched");
  expect(coordinator.eof(token, 7, 45.0) == clock,
         "matching EOF waits behind issued clock mutation");
  expectKind(coordinator.eof(token, 7, 46.0), Action::Kind::None,
             "duplicate EOF cannot publish another restore");
  expect(coordinator.nextAction() == clock,
         "duplicate EOF leaves exactly one physical action pending");
  const Action restore = coordinator.completeAction(clock.serial, {});
  expectKind(restore, Action::Kind::RestoreTransport,
             "EOF publishes one restore after clock acknowledgement");
  expect(restore.transport.paused && restore.transport.position == 45.0,
         "EOF restore anchors the first exact final position while paused");
  expect(restore.kind != Action::Kind::StopNative,
         "ordinary EOF never tears down the held native frame");
  const Action done = coordinator.completeAction(restore.serial, {});
  expectKind(done, Action::Kind::None,
             "EOF restore acknowledgement emits no second mutation");
  expect(coordinator.snapshot().phase == Phase::EofHeld &&
             coordinator.snapshot().nativeRequestIssued,
         "EOF holds the last native frame and keeps its session resident");
  expect(!coordinator.begin(2, 99, {}),
         "an active EOF-held attempt cannot be overwritten by a new begin");
}

void testUnsupportedNoFrameAndZeroStop() {
  auto reachPrepare = [](NativeActivationCoordinator &coordinator,
                         std::uint64_t request) {
    const Token token =
        *coordinator.begin(request, 99, Transport{0.0, 1.0, false});
    const Action pause = *coordinator.nextAction();
    const Action revoke = coordinator.completeAction(pause.serial, {});
    ActionCompletion revoked;
    revoked.preRevokeGeneration = 10 + request;
    const Action load = coordinator.completeAction(revoke.serial, revoked);
    static_cast<void>(coordinator.mpvReady(token, ready()));
    const Action prepare = coordinator.completeAction(load.serial, {});
    return std::pair<Token, Action>{token, prepare};
  };

  {
    NativeActivationCoordinator coordinator;
    const auto [token, prepare] = reachPrepare(coordinator, 1);
    expect(coordinator.nativeUnsupported(token) == prepare,
           "unsupported callback cannot overwrite issued preparation");
    const Action pause = coordinator.completeAction(prepare.serial, {});
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "unsupported preparation first settles paused transport");
    const Action stop =
        coordinator.completeAction(pause.serial, pausedAt(12.0));
    expectKind(stop, Action::Kind::StopNative,
               "unsupported native request is explicitly stopped");
    const Action error = coordinator.completeAction(stop.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "zero stop generation is rejected fail-closed");
    expect(error.value ==
                   static_cast<std::uint64_t>(FallbackReason::ContextFailure) &&
               coordinator.snapshot().rendererDenied,
           "zero stop never re-allows an unproven renderer context");
  }

  {
    NativeActivationCoordinator coordinator;
    const auto [token, prepare] = reachPrepare(coordinator, 2);
    expect(coordinator.nativeUnsupported(token) == prepare,
           "second unsupported callback remains capacity-one");
    const Action pause = coordinator.completeAction(prepare.serial, {});
    const Action stop =
        coordinator.completeAction(pause.serial, pausedAt(12.0));
    const Action allow = coordinator.completeAction(stop.serial, stoppedAt(33));
    expectKind(allow, Action::Kind::AllowMpvRenderer,
               "fresh nonzero flush generation permits renderer allow");
    static_cast<void>(coordinator.completeAction(allow.serial, {}));
    expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer &&
               coordinator.snapshot().fallbackReason ==
                   FallbackReason::Unsupported,
           "unsupported media enters one-way fallback after safe cleanup");
  }

  {
    NativeActivationCoordinator coordinator;
    const Prepared prepared = prepareForStart(coordinator, 3);
    ActionCompletion accepted;
    accepted.generation = 51;
    accepted.drawBaseline = 8;
    static_cast<void>(
        coordinator.completeAction(prepared.start.serial, accepted));
    const Action pause = coordinator.nativeFailed(prepared.token);
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "accepted start with no frame falls back before unpausing");
    const Action stop =
        coordinator.completeAction(pause.serial, pausedAt(12.0));
    const Action allow = coordinator.completeAction(stop.serial, stoppedAt(44));
    static_cast<void>(coordinator.completeAction(allow.serial, {}));
    expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer,
           "no-frame start cannot activate and reaches fallback safely");
  }
}

void testTokenSourceAndTrackMismatch() {
  {
    NativeActivationCoordinator coordinator;
    const Token token = *coordinator.begin(1, 99, Transport{0.0, 1.0, false});
    const Action pause = *coordinator.nextAction();
    const Token stale{token.request, token.attempt + 1};
    expectKind(coordinator.nativeFailed(stale), Action::Kind::None,
               "stale token native failure is ignored");
    expectKind(coordinator.mpvReady(stale, ready()), Action::Kind::None,
               "stale token metadata is ignored");
    expect(coordinator.nextAction() == pause,
           "stale callbacks never replace current attempt action");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = *coordinator.begin(2, 99, Transport{0.0, 1.0, false});
    const Action pause = *coordinator.nextAction();
    const Action revoke = coordinator.completeAction(pause.serial, {});
    ActionCompletion revoked;
    revoked.preRevokeGeneration = 10;
    const Action load = coordinator.completeAction(revoke.serial, revoked);
    MpvReady unpaused = ready();
    unpaused.live.paused = false;
    expect(coordinator.mpvReady(token, unpaused) == load,
           "unpaused mpv snapshot cannot overwrite pending audio load");
    const Action fallback_pause = coordinator.completeAction(load.serial, {});
    expectKind(fallback_pause, Action::Kind::ForcePauseMpv,
               "unpaused startup metadata triggers one-way track fallback");
    expect(coordinator.snapshot().nativeBurned &&
               coordinator.snapshot().fallbackReason ==
                   FallbackReason::TrackContract,
           "unpaused metadata can never activate the wrong transport state");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 3);
    expectKind(coordinator.mpvEndFileError(token, 8), Action::Kind::None,
               "END_FILE error for another entry is ignored");
    expect(coordinator.snapshot().phase == Phase::Active &&
               !coordinator.nextAction(),
           "wrong-entry END_FILE cannot burn current playback");
    static_cast<void>(coordinator.observeLiveTransport(
        token, coordinator.snapshot().transportEpoch, 8,
        Transport{99.0, 1.0, false}));
    expect(coordinator.snapshot().desired.position == 0.0,
           "wrong-entry live transport cannot reanchor current source");
  }
}

void testTerminalErrorsBehindFallbackActions() {
  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 1);
    driveFallbackToRenderer(coordinator, token);
    static_cast<void>(coordinator.mpvReady(token, ready(99, 7, 3, 18.25)));
    const Action select = coordinator.fallbackRenderReady(token, 80);
    expect(coordinator.mpvLoadFailed(token) == select,
           "fallback load error cannot overwrite pending Select");
    const Action repause = coordinator.completeAction(select.serial, {});
    expectKind(repause, Action::Kind::ForcePauseMpv,
               "fallback load error force-pauses after Select reply");
    const Action error = coordinator.completeAction(repause.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "fallback load error surfaces after terminal pause settles");
    expect(error.value ==
               static_cast<std::uint64_t>(FallbackReason::MpvFailure),
           "deferred fallback load error keeps terminal classification");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 2);
    driveFallbackToRenderer(coordinator, token);
    static_cast<void>(coordinator.mpvReady(token, ready(99, 7, 3, 18.25)));
    const Action select = coordinator.fallbackRenderReady(token, 80);
    static_cast<void>(coordinator.fallbackPlaybackRestart(token, 80, 7, 18.25));
    const Action restore = coordinator.completeAction(select.serial, {});
    expectKind(restore, Action::Kind::RestoreTransport,
               "fallback END_FILE test reaches pending Restore");
    expect(coordinator.mpvEndFileError(token, 7) == restore,
           "fallback END_FILE cannot overwrite pending Restore");
    const Action repause = coordinator.completeAction(restore.serial, {});
    expectKind(repause, Action::Kind::ForcePauseMpv,
               "fallback END_FILE force-pauses after pending Restore reply");
    expect(repause.transport.paused,
           "terminal fallback END_FILE cannot leave transport running");
    const Action error = coordinator.completeAction(repause.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "fallback END_FILE surfaces after terminal pause settles");
    expect(error.value ==
               static_cast<std::uint64_t>(FallbackReason::MpvFailure),
           "deferred END_FILE preserves mpv failure reason");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = fallbackActive(coordinator, 3, 83);
    const Action pause = coordinator.mpvLoadFailed(token);
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "load error during active fallback begins terminal pause");
    const Action error = coordinator.completeAction(pause.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "active fallback load error surfaces after pause");
    expect(error.value ==
               static_cast<std::uint64_t>(FallbackReason::MpvFailure),
           "active fallback load error retains mpv failure reason");
  }
}

void testControllerFailureEntryPoint() {
  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 30);
    const Token stale{token.request, token.attempt + 1};
    expectKind(coordinator.fail(stale, FallbackReason::ContextFailure),
               Action::Kind::None, "stale controller failure token is inert");
    expect(!coordinator.nextAction(),
           "stale controller failure cannot occupy the action slot");

    const Action pause =
        coordinator.fail(token, FallbackReason::ContextFailure);
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "native Active controller failure enters recoverable fallback");
    const Action stop = coordinator.completeAction(pause.serial, pausedAt(6.5));
    expectKind(stop, Action::Kind::StopNative,
               "recoverable controller failure pauses before native stop");
    const Action allow = coordinator.completeAction(stop.serial, stoppedAt(91));
    expectKind(allow, Action::Kind::AllowMpvRenderer,
               "recoverable controller failure re-allows after safe stop");
    const Action waiting = coordinator.completeAction(allow.serial, {});
    expectKind(waiting, Action::Kind::None,
               "recoverable controller failure waits for fallback renderer");
    expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer &&
               coordinator.snapshot().fallbackReason ==
                   FallbackReason::ContextFailure,
           "native controller failure preserves reason without surfacing yet");

    const Action error = coordinator.fail(token, FallbackReason::Mismatch);
    expectKind(error, Action::Kind::SurfaceError,
               "fallback AwaitRenderer failure surfaces directly");
    expect(error.value == static_cast<std::uint64_t>(FallbackReason::Mismatch),
           "direct fallback failure preserves exact controller reason");
    expect(coordinator.fail(token, FallbackReason::NativeFailure) == error,
           "repeated Failed callback retains the exact SurfaceError serial");
    static_cast<void>(coordinator.completeAction(error.serial, {}));
    expect(coordinator.snapshot().phase == Phase::Failed,
           "SurfaceError acknowledgement ends in Failed");
    expectKind(coordinator.fail(token, FallbackReason::NativeFailure),
               Action::Kind::None,
               "acknowledged Failed state ignores later controller failures");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 31);
    const Action clock = coordinator.setDesiredRate(token, 1.5);
    expectKind(clock, Action::Kind::UpdateNativeClock,
               "pending native controller-failure test owns a clock action");
    expect(coordinator.fail(token, FallbackReason::NativeFailure) == clock,
           "native failure never overwrites an issued clock serial");
    const Action pause = coordinator.completeAction(clock.serial, {});
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "issued native action acknowledgement continues fallback pause");
    const Action stop =
        coordinator.completeAction(pause.serial, pausedAt(7.0, 1.5));
    const Action allow = coordinator.completeAction(stop.serial, stoppedAt(92));
    static_cast<void>(coordinator.completeAction(allow.serial, {}));
    expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer,
           "pending native mutation still reaches recoverable fallback");
  }

  {
    NativeActivationCoordinator coordinator;
    const Prepared prepared = prepareForStart(coordinator, 32);
    expect(coordinator.fail(prepared.token, FallbackReason::ContextFailure) ==
               prepared.start,
           "renderer-denied native request retains issued StartNative serial");
    const Action pause = coordinator.completeAction(prepared.start.serial, {});
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "denied native request acknowledgement orders fallback pause");
    const Action stop = coordinator.completeAction(pause.serial, pausedAt(0.0));
    const Action allow = coordinator.completeAction(stop.serial, stoppedAt(93));
    static_cast<void>(coordinator.completeAction(allow.serial, {}));
    expect(coordinator.snapshot().phase == Phase::FallbackAwaitRenderer &&
               !coordinator.snapshot().rendererDenied,
           "denied native request stops then restores renderer permission");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 33);
    const Action pause = coordinator.fail(token, FallbackReason::NativeFailure);
    expect(coordinator.fail(token, FallbackReason::NativeFailure) == pause,
           "failure during pending ForcePause retains its exact serial");
    const Action stop = coordinator.completeAction(pause.serial, pausedAt(8.0));
    expectKind(stop, Action::Kind::StopNative,
               "repeated fallback failure continues to native Stop");
    expect(coordinator.fail(token, FallbackReason::NativeFailure) == stop,
           "failure during pending Stop retains its exact serial");
    const Action allow = coordinator.completeAction(stop.serial, stoppedAt(94));
    expectKind(allow, Action::Kind::AllowMpvRenderer,
               "terminalized fallback still re-allows after safe Stop");
    expect(coordinator.fail(token, FallbackReason::NativeFailure) == allow,
           "failure during pending Allow retains its exact serial");
    const Action error = coordinator.completeAction(allow.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "terminalized repeated failure surfaces exactly once");
    static_cast<void>(coordinator.completeAction(error.serial, {}));
    expect(coordinator.snapshot().phase == Phase::Failed,
           "repeated pending-action failure chain settles Failed");
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 34);
    driveFallbackToRenderer(coordinator, token);
    static_cast<void>(coordinator.mpvReady(token, ready(99, 7, 3, 18.25)));
    const Action select = coordinator.fallbackRenderReady(token, 180);
    expect(coordinator.fail(token, FallbackReason::ContextFailure) == select,
           "fallback failure never overwrites pending Select");
    const Action pause = coordinator.completeAction(select.serial, {});
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "pending Select failure force-pauses before surfacing");
    const Action error = coordinator.completeAction(pause.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "pending Select failure surfaces after physical pause");
    static_cast<void>(coordinator.completeAction(error.serial, {}));
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 340);
    driveFallbackToRenderer(coordinator, token);
    static_cast<void>(coordinator.mpvReady(token, ready(99, 7, 3, 18.25)));
    const Action select = coordinator.fallbackRenderReady(token, 179);
    const Action waiting = coordinator.completeAction(select.serial, {});
    expectKind(waiting, Action::Kind::None,
               "no-action AwaitRestart test waits for playback restart");
    expect(coordinator.snapshot().phase == Phase::FallbackAwaitRestart,
           "selection acknowledgement reaches no-action AwaitRestart");
    const Action pause = coordinator.fail(token, FallbackReason::Mismatch);
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "no-action AwaitRestart failure force-pauses transport");
    const Action error = coordinator.completeAction(pause.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "AwaitRestart failure surfaces after physical pause");
    static_cast<void>(coordinator.completeAction(error.serial, {}));
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 35);
    driveFallbackToRenderer(coordinator, token);
    static_cast<void>(coordinator.mpvReady(token, ready(99, 7, 3, 18.25)));
    const Action select = coordinator.fallbackRenderReady(token, 181);
    static_cast<void>(
        coordinator.fallbackPlaybackRestart(token, 181, 7, 18.25));
    const Action restore = coordinator.completeAction(select.serial, {});
    expectKind(restore, Action::Kind::RestoreTransport,
               "pending Restore failure test reaches transport restore");
    expect(coordinator.fail(token, FallbackReason::ContextFailure) == restore,
           "fallback failure never overwrites pending Restore");
    const Action pause = coordinator.completeAction(restore.serial, {});
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "pending Restore failure re-pauses possibly resumed audio");
    const Action error = coordinator.completeAction(pause.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "pending Restore failure surfaces after physical pause");
    static_cast<void>(coordinator.completeAction(error.serial, {}));
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = fallbackActive(coordinator, 36, 182);
    const Action attach = coordinator.requestCaption(token, 9001);
    expectKind(attach, Action::Kind::AttachCaption,
               "pending Attach failure test owns caption action");
    expect(coordinator.fail(token, FallbackReason::Caption) == attach,
           "fallback failure never overwrites pending AttachCaption");
    const Action pause = coordinator.completeAction(attach.serial, {});
    expectKind(pause, Action::Kind::ForcePauseMpv,
               "pending Attach acknowledgement orders terminal pause");
    const Action error = coordinator.completeAction(pause.serial, {});
    expectKind(error, Action::Kind::SurfaceError,
               "pending Attach failure surfaces after pause");
    static_cast<void>(coordinator.completeAction(error.serial, {}));
  }

  {
    NativeActivationCoordinator coordinator;
    const Token token = activate(coordinator, 37);
    const Action stop = coordinator.cancelForStopOrOpen(CancelMode::Stop);
    expectKind(coordinator.fail(token, FallbackReason::NativeFailure),
               Action::Kind::None,
               "cancel-burned token rejects controller failure callback");
    expect(coordinator.nextAction() == stop,
           "rejected canceled failure leaves cleanup action intact");
  }
}

} // namespace

int main() {
  testStartupAndCapacityOne();
  testStartupDrawAndLatestIntent();
  testRapidSeekAndEofOrdering();
  testFallbackAndEarlyRestart();
  testCancellationEffectMatrix();
  testNonzeroBeginAndClockCoalescing();
  testRevocationGenerationSettlement();
  testExpandedCancellationMatrix();
  testFallbackMetadataAndRendererInvalidation();
  testFallbackErrorsAndStopFailure();
  testSeekLatestIntentAndQuarantine();
  testCaptionFallbackSuccessAndFailure();
  testEofRaceAndIdentityQuarantine();
  testUnsupportedNoFrameAndZeroStop();
  testTokenSourceAndTrackMismatch();
  testTerminalErrorsBehindFallbackActions();
  testControllerFailureEntryPoint();
  if (failures == 0)
    std::cout << "native activation coordinator tests passed\n";
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
