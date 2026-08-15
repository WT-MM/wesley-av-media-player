#include "media/playback_router.hpp"
#include "platform/macos/native_media_session.hpp"

#include <cstdlib>
#include <iostream>

namespace router = wam::media::playback_router;
namespace native = wam::media::native_playback;
using wam::macos::NativeMediaSession;

namespace {

void expect(bool condition, const char* message) {
  if (condition)
    return;
  std::cerr << "FAIL: " << message << '\n';
  std::exit(1);
}

const router::Action& action(const router::Transition& transition,
                             router::ActionKind kind,
                             const char* message) {
  expect(transition.status == router::Status::Applied &&
             transition.action.has_value() &&
             transition.action->kind == kind,
         message);
  return *transition.action;
}

native::Prepared prepared(const native::Prepare& prepare) {
  return {prepare.stamp, prepare.sourceKey, {90.0, true, true},
          prepare.reservedGeneration};
}

native::CommitReady commitReady(const native::CommitSeek& commit,
                                std::uint64_t drawSequence) {
  return {commit.stamp,
          commit.targetGeneration,
          commit.gesture,
          commit.request,
          commit.targetSeconds,
          {commit.stamp, commit.targetGeneration,
           native::AudioClockAnchorId{1}, commit.targetSeconds, true, 1.0},
          {commit.stamp, commit.targetGeneration, drawSequence,
           commit.targetSeconds, 1.0 / 30.0}};
}

void nativeSuccessCreatesNoFallback() {
  router::PlaybackRouter route;
  const native::Prepare prepare =
      action(route.open({native::SourceKey{1},
                         router::Route::NativeEligibleLocal, 0.0, false},
                        {1}),
             router::ActionKind::NativePrepare,
             "native open emits Prepare")
          .prepare;
  const native::Start start =
      action(route.onNativePrepared(prepared(prepare), {2}),
             router::ActionKind::NativeStart,
             "Prepared emits Start")
          .start;
  const native::SetRunState run =
      action(route.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 0}, {3}),
             router::ActionKind::NativeSetRunState,
             "Started emits native run state")
          .runState;
  expect(!run.paused &&
             route.snapshot().state == router::State::NativeActive,
         "native attempt is active without fallback creation");
}

void failureRetiresBeforeFallback() {
  router::PlaybackRouter route;
  const native::Prepare prepare =
      action(route.open({native::SourceKey{2},
                         router::Route::NativeEligibleLocal, 0.0, false},
                        {1}),
             router::ActionKind::NativePrepare,
             "native failure attempt begins with Prepare")
          .prepare;
  const native::Start start =
      action(route.onNativePrepared(prepared(prepare), {2}),
             router::ActionKind::NativeStart,
             "native failure attempt starts")
          .start;
  const native::SetRunState run =
      action(route.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 0}, {3}),
             router::ActionKind::NativeSetRunState,
             "native failure attempt becomes active")
          .runState;
  const native::Stop stop =
      action(route.onNativeFailed(
                 {run.stamp, native::FailureReason::Decode}, {4}),
             router::ActionKind::NativeStop,
             "post-resource failure first emits exact native Stop")
          .stop;
  expect(route.snapshot().state == router::State::NativeStopping,
         "fallback is not created before native Stopped proof");
  const auto create = action(
      route.onNativeStopped({stop.stamp, stop.invalidationGeneration}, {5}),
      router::ActionKind::CreateFallback,
      "exact Stopped proof releases compatibility creation");
  expect(create.fallback.sourceKey == native::SourceKey{2},
         "fallback retains the failed source identity");
}

void replacementRetainsLatestSourceUntilStop() {
  router::PlaybackRouter route;
  const native::Prepare first =
      action(route.open({native::SourceKey{10},
                         router::Route::NativeEligibleLocal, 0.0, true},
                        {1}),
             router::ActionKind::NativePrepare,
             "first replacement attempt prepares")
          .prepare;
  const native::Stop stop =
      action(route.open({native::SourceKey{11},
                         router::Route::NativeEligibleLocal, 0.0, false},
                        {2}),
             router::ActionKind::NativeStop,
             "replacement first retires current native owner")
          .stop;
  (void)first;
  const auto snapshot = route.snapshot();
  expect(snapshot.sourceKey == native::SourceKey{10} &&
             snapshot.pendingSourceKey == native::SourceKey{11},
         "router retains both current and latest replacement identities");
  const auto second = action(
      route.onNativeStopped({stop.stamp, stop.invalidationGeneration}, {3}),
      router::ActionKind::NativePrepare,
      "replacement prepares only after exact retirement")
                          .prepare;
  expect(second.sourceKey == native::SourceKey{11},
         "replacement Prepare carries the latest source identity");
}

void preflightIsPureAndExact() {
  expect(NativeMediaSession::preflightInitialPosition(0.0).has_value(),
         "zero is an exact native initial position");
  expect(NativeMediaSession::preflightInitialPosition(0.5).has_value(),
         "binary half second is exact");
  expect(!NativeMediaSession::preflightInitialPosition(-1.0).has_value(),
         "negative initial position fails closed");
}

void commitBridgeRetainsIdentityPauseAndExactProof() {
  router::PlaybackRouter route;
  const native::Prepare prepare =
      action(route.open({native::SourceKey{15},
                         router::Route::NativeEligibleLocal, 0.0, false},
                        {1}),
             router::ActionKind::NativePrepare,
             "commit bridge prepares native source")
          .prepare;
  const native::Start start =
      action(route.onNativePrepared(prepared(prepare), {2}),
             router::ActionKind::NativeStart,
             "commit bridge starts native source")
          .start;
  const native::SetRunState initialRun =
      action(route.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 8}, {3}),
             router::ActionKind::NativeSetRunState,
             "commit bridge activates source")
          .runState;
  const native::SetRunState physicalScrubPause =
      action(route.setPaused(true, {4}),
             router::ActionKind::NativeSetRunState,
             "begin scrub emits exactly one physical native pause")
          .runState;
  expect(physicalScrubPause.paused &&
             physicalScrubPause.generation == initialRun.generation,
         "physical scrub pause retains the active generation");
  const native::CommitSeek commit =
      action(route.commitSeek({native::GestureId{31},
                               native::RequestId{47}, 22.5, 8},
                              {5}),
             router::ActionKind::NativeCommitSeek,
             "owner dispatches one exact native commit")
          .commitSeek;
  expect(commit.sourceGeneration == initialRun.generation &&
             commit.gesture == native::GestureId{31} &&
             commit.request == native::RequestId{47} &&
             commit.targetSeconds == 22.5,
         "owner dispatch retains exact gesture, request, and target identity");
  const auto pauseIntent = route.setPaused(false, {6});
  expect(pauseIntent.status == router::Status::Applied &&
             !pauseIntent.action.has_value(),
         "captured pre-scrub play intent is restored without a concurrent "
         "physical command");
  native::CommitReady stale = commitReady(commit, 8);
  expect(route.onNativeCommitReady(stale, {7}).status ==
             router::Status::Ignored,
         "owner cannot promote a draw at the preflight baseline");
  const native::SetRunState resumed =
      action(route.onNativeCommitReady(commitReady(commit, 9), {8}),
             router::ActionKind::NativeSetRunState,
             "owner promotes only exact CommitReady")
          .runState;
  expect(resumed.generation == commit.targetGeneration && !resumed.paused &&
             route.snapshot().state == router::State::NativeActive,
         "completion promotes the target and applies latest pause intent");
}

void previewBridgeIsCapacityOneAndCommitFollowsLatest() {
  router::PlaybackRouter route;
  const native::Prepare prepare =
      action(route.open({native::SourceKey{25},
                         router::Route::NativeEligibleLocal, 0.0, false},
                        {1}),
             router::ActionKind::NativePrepare,
             "preview owner bridge prepares native source")
          .prepare;
  const native::Start start =
      action(route.onNativePrepared(prepared(prepare), {2}),
             router::ActionKind::NativeStart,
             "preview owner bridge starts native source")
          .start;
  const native::SetRunState run =
      action(route.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 8}, {3}),
             router::ActionKind::NativeSetRunState,
             "preview owner bridge activates native source")
          .runState;
  const native::PreviewFrame first =
      action(route.previewFrame({native::GestureId{41}, native::RequestId{51},
                                 12.0},
                                {4}),
             router::ActionKind::NativePreviewFrame,
             "owner reserves first preview identity")
          .previewFrame;
  const native::PreviewFrame latest =
      action(route.previewFrame({native::GestureId{41}, native::RequestId{52},
                                 13.0},
                                {5}),
             router::ActionKind::NativePreviewFrame,
             "owner replaces preview with latest identity")
          .previewFrame;
  expect(first.generation == run.generation &&
             latest.generation == run.generation &&
             latest.stamp.serial.value > first.stamp.serial.value &&
             !native::previewPresentedMatches(
                 latest, {first.stamp, first.generation, first.gesture,
                          first.request, 11.95}) &&
             native::previewPresentedMatches(
                 latest, {latest.stamp, latest.generation, latest.gesture,
                          latest.request, 12.95}) &&
             !native::previewFailedMatches(
                 latest, {first.stamp, first.generation, first.gesture,
                          first.request, first.targetSeconds}) &&
             native::previewFailedMatches(
                 latest, {latest.stamp, latest.generation, latest.gesture,
                          latest.request, latest.targetSeconds}),
         "only an exact latest preview terminal crosses the owner bridge");
  const native::CommitSeek commit =
      action(route.commitSeek({native::GestureId{41}, native::RequestId{53},
                               14.0, 8},
                              {6}),
             router::ActionKind::NativeCommitSeek,
             "release follows latest preview with one fresh commit")
          .commitSeek;
  expect(commit.gesture == latest.gesture &&
             commit.request == native::RequestId{53} &&
             commit.stamp.serial.value > latest.stamp.serial.value,
         "commit retains gesture while using its final request identity");
}

void commitFailureRetiresBeforeCompatibility() {
  router::PlaybackRouter route;
  const native::Prepare prepare =
      action(route.open({native::SourceKey{16},
                         router::Route::NativeEligibleLocal, 0.0, false},
                        {1}),
             router::ActionKind::NativePrepare,
             "failed commit source prepares")
          .prepare;
  const native::Start start =
      action(route.onNativePrepared(prepared(prepare), {2}),
             router::ActionKind::NativeStart,
             "failed commit source starts")
          .start;
  action(route.onNativeStarted(
             {start.stamp, start.preparedGeneration, 2}, {3}),
         router::ActionKind::NativeSetRunState,
         "failed commit source activates");
  const native::CommitSeek commit =
      action(route.commitSeek({native::GestureId{4}, native::RequestId{5},
                               35.0, 2},
                              {4}),
             router::ActionKind::NativeCommitSeek,
             "failed commit is admitted exactly once")
          .commitSeek;
  const native::Stop stop =
      action(route.onNativeFailed(
                 {commit.stamp, native::FailureReason::CommitSeek}, {5}),
             router::ActionKind::NativeStop,
             "commit failure requires exact native retirement")
          .stop;
  expect(stop.invalidationGeneration.value > commit.targetGeneration.value,
         "failure Stop invalidates the reserved commit target generation");
  expect(action(route.onNativeStopped(
                    {stop.stamp, stop.invalidationGeneration}, {6}),
                router::ActionKind::CreateFallback,
                "compatibility starts only after exact retirement")
                 .fallback.sourceKey == native::SourceKey{16},
         "commit failure fallback retains the source identity");
}

void surfaceTeardownDropsPendingWithoutForgingProof() {
  router::PlaybackRouter route;
  const native::Prepare first =
      action(route.open({native::SourceKey{20},
                         router::Route::NativeEligibleLocal, 0.0, false},
                        {1}),
             router::ActionKind::NativePrepare,
             "surface teardown attempt prepares")
          .prepare;
  const native::Stop stop =
      action(route.open({native::SourceKey{21},
                         router::Route::NativeEligibleLocal, 0.0, false},
                        {2}),
             router::ActionKind::NativeStop,
             "replacement is pending before surface teardown")
          .stop;
  const auto before = route.snapshot();
  const auto reset = route.abandonNativeAfterSynchronousRetirement({3});
  expect(reset.status == router::Status::Applied && !reset.action &&
             route.snapshot().state == router::State::Idle &&
             !route.snapshot().hasPendingOpen &&
             route.snapshot().sourceKey == native::SourceKey{} &&
             route.snapshot().attemptHighWater == before.attemptHighWater &&
             route.snapshot().generationHighWater ==
                 before.generationHighWater,
         "surface teardown returns Idle and burns existing lineage");
  expect(route.onNativeStopped(
                   {stop.stamp, stop.invalidationGeneration}, {4})
                 .status == router::Status::Ignored,
         "late native terminal fact cannot revive torn-down ownership");
  expect(action(route.open({native::SourceKey{22},
                            router::Route::FallbackOnly, 0.0, false},
                           {5}),
                router::ActionKind::CreateFallback,
                "only a later explicit open may create fallback")
                 .fallback.sourceKey == native::SourceKey{22},
         "surface teardown itself never creates fallback");
  (void)first;
}

}  // namespace

int main() {
  nativeSuccessCreatesNoFallback();
  failureRetiresBeforeFallback();
  replacementRetainsLatestSourceUntilStop();
  preflightIsPureAndExact();
  commitBridgeRetainsIdentityPauseAndExactProof();
  previewBridgeIsCapacityOneAndCommitFollowsLatest();
  commitFailureRetiresBeforeCompatibility();
  surfaceTeardownDropsPendingWithoutForgingProof();
  std::cout << "native playback owner contract tests passed\n";
  return 0;
}
