#include "media/playback_router.hpp"

#include <cstdlib>
#include <iostream>
#include <limits>

namespace router = wam::media::playback_router;
namespace native = wam::media::native_playback;

namespace {

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

const router::Action &action(const router::Transition &transition,
                             router::ActionKind kind, const char *message) {
  expect(transition.status == router::Status::Applied, message);
  expect(transition.action.has_value(), message);
  expect(transition.action->kind == kind, message);
  return *transition.action;
}

router::OpenRequest nativeOpen(std::uint64_t source, bool paused = true) {
  return {{source}, router::Route::NativeEligibleLocal, 0.0, paused};
}

native::Prepared preparedFor(const native::Prepare &prepare) {
  return {prepare.stamp,
          prepare.sourceKey,
          {120.0, true, true},
          prepare.reservedGeneration};
}

native::CommitReady readyFor(const native::CommitSeek &commit,
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

void nativeSuccessHasZeroFallback() {
  router::PlaybackRouter router;
  const auto prepare = action(router.open(nativeOpen(11, false), {1}),
                              router::ActionKind::NativePrepare,
                              "eligible open prepares natively")
                           .prepare;
  expect(prepare.reservedGeneration == native::Generation{1},
         "router reserves first generation");
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "exact Prepared starts native")
          .start;
  expect(start.stamp.serial == native::Serial{2},
         "native commands are monotonic");
  const auto run = action(router.onNativeStarted(
                              {start.stamp, start.preparedGeneration, 0}, {3}),
                          router::ActionKind::NativeSetRunState,
                          "exact Started publishes run intent")
                       .runState;
  expect(!run.paused, "latest requested run intent reaches native backend");
  expect(router.snapshot().state == router::State::NativeActive,
         "native success is active without fallback");
  expect(!router.snapshot().hasPendingOpen &&
             router.snapshot().pendingSourceKey == native::SourceKey{},
         "a router with no queued replacement reports no pending source key");
}

void unsupportedIsTheOnlyImmediateFallback() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(21), {1}),
             router::ActionKind::NativePrepare, "native admission begins first")
          .prepare;
  const auto create = action(
      router.onNativeUnsupported({prepare.stamp, prepare.sourceKey}, {2}),
      router::ActionKind::CreateFallback,
      "exact generation-free Unsupported creates fallback immediately");
  expect(create.fallback.stamp.attempt.value > prepare.stamp.attempt.value,
         "fallback receives a fresh attempt lineage");
  expect(router.snapshot().state == router::State::FallbackCreating,
         "unsupported never issues native Stop");
}

void allocationFailureRequiresExactStopProof() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(31), {1}),
             router::ActionKind::NativePrepare, "native prepare issued")
          .prepare;
  const auto start = action(router.onNativePrepared(preparedFor(prepare), {2}),
                            router::ActionKind::NativeStart,
                            "Prepared proves generation exposure")
                         .start;
  const auto stop =
      action(router.onNativeFailed(
                 {start.stamp, native::FailureReason::Startup}, {3}),
             router::ActionKind::NativeStop,
             "post-allocation failure stops native first")
          .stop;
  expect(router.snapshot().state == router::State::NativeStopping,
         "fallback is gated on native quiescence");
  expect(router.onNativeStopped(
                   {stop.stamp, {stop.invalidationGeneration.value + 1}}, {4})
                 .status == router::Status::Ignored,
         "wrong invalidation proof is ignored");
  action(router.onNativeStopped({stop.stamp, stop.invalidationGeneration}, {5}),
         router::ActionKind::CreateFallback,
         "exact Stop proof releases fallback");
}

void admissionFailureBeforeResourcesIsImmediateFallback() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(35), {1}),
             router::ActionKind::NativePrepare, "native prepare issued")
          .prepare;
  action(router.onNativeFailed(
             {prepare.stamp, native::FailureReason::Preparation}, {2}),
         router::ActionKind::CreateFallback,
         "exact admission failure before resources falls back immediately");
  expect(router.snapshot().state == router::State::FallbackCreating,
         "canonical before-resources failure needs no Stop");
}

void supersedingOpenBurnsStaleFacts() {
  router::PlaybackRouter router;
  const auto first =
      action(router.open(nativeOpen(41), {1}),
             router::ActionKind::NativePrepare, "first native prepare")
          .prepare;
  const auto stop =
      action(router.open(nativeOpen(42), {2}), router::ActionKind::NativeStop,
             "superseding open stops first native attempt")
          .stop;
  expect(router.snapshot().hasPendingOpen &&
             router.snapshot().pendingSourceKey == native::SourceKey{42},
         "snapshot identifies the exact queued replacement source");
  expect(router.open(nativeOpen(43), {3}).status == router::Status::Applied &&
             router.snapshot().hasPendingOpen &&
             router.snapshot().pendingSourceKey == native::SourceKey{43},
         "a newer replacement atomically replaces the pending source key");
  expect(router.onNativePrepared(preparedFor(first), {3}).status ==
             router::Status::Ignored,
         "superseded Prepared fact is burned");
  const auto second =
      action(router.onNativeStopped({stop.stamp, stop.invalidationGeneration},
                                    {4}),
             router::ActionKind::NativePrepare, "exact stop starts newest open")
          .prepare;
  expect(second.sourceKey == native::SourceKey{43},
         "only newest source is admitted");
  expect(!router.snapshot().hasPendingOpen &&
             router.snapshot().pendingSourceKey == native::SourceKey{},
         "routing the replacement clears its pending source identity");
  expect(second.stamp.attempt.value > first.stamp.attempt.value,
         "attempt IDs increase across supersession");
  expect(
      router.onNativeUnsupported({first.stamp, first.sourceKey}, {5}).status ==
          router::Status::Ignored,
      "old unsupported fact cannot create fallback");
}

void stopAndFallbackOrdering() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(51), {1}),
             router::ActionKind::NativePrepare, "native prepare")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "resource allocation is proven")
          .start;
  const auto stop =
      action(router.onNativeFailed(
                 {start.stamp, native::FailureReason::Startup}, {3}),
             router::ActionKind::NativeStop,
             "post-resource failure requires Stop")
          .stop;
  expect(router.stop({4}).action == std::nullopt,
         "user Stop cancels queued fallback while retirement continues");
  expect(!router.snapshot().hasPendingOpen &&
             router.snapshot().pendingSourceKey == native::SourceKey{},
         "explicit Stop clears the queued source key before quiescence");
  expect(!router.onNativeStopped({stop.stamp, stop.invalidationGeneration}, {5})
              .action,
         "cancelled fallback is not created after quiescence");

  router::PlaybackRouter fallbackRouter;
  const auto create = action(
      fallbackRouter.open({{52}, router::Route::FallbackOnly, 0.0, true}, {1}),
      router::ActionKind::CreateFallback, "fallback-only creates factory");
  const auto stopFallback =
      action(fallbackRouter.open(nativeOpen(53), {2}),
             router::ActionKind::StopFallback,
             "native supersession stops fallback before Prepare");
  action(fallbackRouter.onFallbackStopped({{stopFallback.fallback.stamp}}, {3}),
         router::ActionKind::NativePrepare,
         "native Prepare follows exact fallback Stop");
  expect(create.fallback.stamp.attempt != stopFallback.fallback.stamp.attempt ||
             create.fallback.stamp.serial != stopFallback.fallback.stamp.serial,
         "fallback stop has distinct command lineage");
}

void exhaustionFailsWithoutWrapping() {
  constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
  router::PlaybackRouter attempts({}, {{maximum}, {0}});
  expect(attempts.open(nativeOpen(61), {1}).status == router::Status::Exhausted,
         "attempt exhaustion rejects without wrapping");
  expect(attempts.snapshot().attemptHighWater.value == maximum,
         "attempt high-water remains terminal");

  router::PlaybackRouter generations({}, {{0}, {native::kTerminalStopValue}});
  action(generations.open(nativeOpen(62), {1}),
         router::ActionKind::CreateFallback,
         "generation exhaustion fails native admission before fallback");
  expect(generations.snapshot().generationHighWater.value ==
             native::kTerminalStopValue,
         "generation high-water never wraps");

  router::PlaybackRouter serials({}, {},
                                 {{maximum}, {1}, {native::kMaximumLiveValue}});
  const auto prepare =
      action(serials.open(nativeOpen(63), {1}),
             router::ActionKind::NativePrepare, "last live serial prepares")
          .prepare;
  const auto stop = action(serials.onNativePrepared(preparedFor(prepare), {2}),
                           router::ActionKind::NativeStop,
                           "live serial exhaustion retires instead of wrapping")
                        .stop;
  expect(stop.stamp.serial == native::Serial{native::kTerminalStopValue},
         "terminal Stop serial stays representable after live exhaustion");
  expect(serials.snapshot().state == router::State::NativeStopping,
         "serial exhaustion cannot activate either backend");
}

void wrongLineageAndLatestIntent() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(71), {1}),
             router::ActionKind::NativePrepare, "native prepare")
          .prepare;
  auto wrong = preparedFor(prepare);
  wrong.stamp.attempt.value += 1;
  expect(router.onNativePrepared(wrong, {2}).status == router::Status::Ignored,
         "wrong attempt Prepared is ignored");
  wrong = preparedFor(prepare);
  wrong.generation.value += 1;
  expect(router.onNativePrepared(wrong, {3}).status == router::Status::Ignored,
         "wrong generation Prepared is ignored");
  expect(router.setPaused(false, {4}).status == router::Status::Applied,
         "play intent is retained during preparation");
  expect(router.setPaused(true, {5}).status == router::Status::Applied,
         "newer pause intent replaces play intent");
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {6}),
             router::ActionKind::NativeStart, "correct Prepared accepted")
          .start;
  const auto run = action(router.onNativeStarted(
                              {start.stamp, start.preparedGeneration, 0}, {7}),
                          router::ActionKind::NativeSetRunState,
                          "Started emits latest run state")
                       .runState;
  expect(run.paused, "latest pause intent wins");

  native::CommitReady unsolicited{};
  expect(router.onNativeCommitReady(unsolicited, {8}).status ==
             router::Status::Ignored,
         "unsolicited seek completion is inert");
  expect(router.advance({7}).status == router::Status::Invalid,
         "caller ticks must be monotonic");
}

void commitSeekPromotesOnlyExactReady() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(101, false), {1}),
             router::ActionKind::NativePrepare, "seek route prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "seek route starts")
          .start;
  const auto run =
      action(router.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 7}, {3}),
             router::ActionKind::NativeSetRunState,
             "seek route becomes active")
          .runState;
  const auto beforeInvalidBaseline = router.snapshot();
  expect(router.commitSeek(
                   {native::GestureId{9}, native::RequestId{11}, 42.0,
                    std::numeric_limits<std::uint64_t>::max()},
                   {4})
                 .status == router::Status::Invalid &&
             router.snapshot().state == beforeInvalidBaseline.state &&
             router.snapshot().serial == beforeInvalidBaseline.serial &&
             router.snapshot().generationHighWater ==
                 beforeInvalidBaseline.generationHighWater,
         "an unwinnable maximum draw baseline is rejected before lineage "
         "reservation");
  const auto commit =
      action(router.commitSeek({native::GestureId{9}, native::RequestId{12},
                                42.5, 20},
                               {4}),
             router::ActionKind::NativeCommitSeek,
             "active route issues exact CommitSeek")
          .commitSeek;
  const auto seeking = router.snapshot();
  expect(seeking.state == router::State::NativeSeeking &&
             seeking.serial == commit.stamp.serial &&
             seeking.generation == run.generation &&
             seeking.generationHighWater.value ==
                 commit.targetGeneration.value &&
             commit.sourceGeneration == run.generation &&
             commit.targetGeneration.value > run.generation.value,
         "commit immediately burns serial and target generation while the "
         "source generation remains active");
  const auto duplicate = router.commitSeek(
      {native::GestureId{9}, native::RequestId{13}, 43.0, 20}, {5});
  expect(duplicate.status == router::Status::Ignored &&
             router.snapshot().serial == seeking.serial &&
             router.snapshot().generationHighWater ==
                 seeking.generationHighWater,
         "a second commit cannot supersede an in-flight exact commit");

  native::CommitReady wrong = readyFor(commit, 21);
  wrong.videoDraw.drawSequence = 20;
  expect(router.onNativeCommitReady(wrong, {6}).status ==
             router::Status::Ignored,
         "a draw at the retained baseline cannot promote the generation");
  wrong = readyFor(commit, 21);
  wrong.request.value += 1;
  expect(router.onNativeCommitReady(wrong, {7}).status ==
             router::Status::Ignored,
         "wrong-request CommitReady is inert");

  expect(router.setPaused(true, {8}).status == router::Status::Applied,
         "pause intent is retained while commit converges");
  const auto resumed =
      action(router.onNativeCommitReady(readyFor(commit, 21), {9}),
             router::ActionKind::NativeSetRunState,
             "exact CommitReady resumes the promoted generation")
          .runState;
  expect(resumed.generation == commit.targetGeneration && resumed.paused &&
             resumed.stamp.serial.value > commit.stamp.serial.value &&
             router.snapshot().state == router::State::NativeActive &&
             router.snapshot().generation == commit.targetGeneration,
         "ready promotes target generation and applies latest run intent");
  expect(router.onNativeCommitReady(readyFor(commit, 22), {10}).status ==
             router::Status::Ignored,
         "duplicate CommitReady is burned after promotion");
}

void previewFramesReserveLatestGestureAndCommit() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(106, false), {1}),
             router::ActionKind::NativePrepare, "preview route prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "preview route starts")
          .start;
  const auto run =
      action(router.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 8}, {3}),
             router::ActionKind::NativeSetRunState,
             "preview route becomes active")
          .runState;

  const auto first =
      action(router.previewFrame(
                 {native::GestureId{7}, native::RequestId{1}, 20.0}, {4}),
             router::ActionKind::NativePreviewFrame,
             "first scrub position reserves a native preview")
          .previewFrame;
  expect(first.stamp.serial.value > run.stamp.serial.value &&
             first.generation == run.generation &&
             first.targetSeconds == 20.0 &&
             router.snapshot().generationHighWater.value ==
                 run.generation.value &&
             router.snapshot().state == router::State::NativeActive,
         "preview advances only serial lineage without changing route or "
         "generation high-water");
  const auto latest =
      action(router.previewFrame(
                 {native::GestureId{7}, native::RequestId{2}, 21.0}, {5}),
             router::ActionKind::NativePreviewFrame,
             "same gesture replaces its retained preview")
          .previewFrame;
  expect(latest.stamp.serial.value > first.stamp.serial.value &&
             latest.request == native::RequestId{2},
         "every preview request owns a fresh serial");

  const auto beforeWrongGesture = router.snapshot();
  expect(router.previewFrame(
                   {native::GestureId{8}, native::RequestId{1}, 22.0}, {6})
                 .status == router::Status::Invalid &&
             router.snapshot().serial == beforeWrongGesture.serial,
         "a new gesture cannot replace a live gesture or burn lineage");
  const auto paused =
      action(router.setPaused(true, {7}),
             router::ActionKind::NativeSetRunState,
             "pause remains independently serialised during preview")
          .runState;
  expect(paused.paused && paused.stamp.serial.value > latest.stamp.serial.value,
         "preview retention does not overwrite the latest pause intent");

  const auto beforeWrongCommit = router.snapshot();
  expect(router.commitSeek({native::GestureId{8}, native::RequestId{9},
                            22.5, 40},
                           {8})
                 .status == router::Status::Invalid &&
             router.snapshot().serial == beforeWrongCommit.serial &&
             router.snapshot().generationHighWater ==
                 beforeWrongCommit.generationHighWater,
         "a commit from another gesture is rejected before reservation");
  const auto commit =
      action(router.commitSeek({native::GestureId{7}, native::RequestId{9},
                                22.5, 40},
                               {9}),
             router::ActionKind::NativeCommitSeek,
             "final seek follows the exact retained preview gesture")
          .commitSeek;
  expect(commit.stamp.serial.value > paused.stamp.serial.value &&
             commit.sourceGeneration == latest.generation &&
             commit.request == native::RequestId{9} &&
             commit.targetSeconds == 22.5,
         "commit may carry a fresh request and target after the preview");
  const auto resumed =
      action(router.onNativeCommitReady(readyFor(commit, 41), {10}),
             router::ActionKind::NativeSetRunState,
             "preview-backed commit promotes only on exact ready")
          .runState;
  expect(resumed.paused && resumed.generation == commit.targetGeneration,
         "commit promotion preserves the latest pause intent");

  const auto nextGesture =
      action(router.previewFrame(
                 {native::GestureId{8}, native::RequestId{1}, 23.0}, {11}),
             router::ActionKind::NativePreviewFrame,
             "commit admission releases the prior gesture slot")
          .previewFrame;
  expect(nextGesture.gesture == native::GestureId{8} &&
             router.snapshot().state == router::State::NativeActive,
         "a later gesture is admitted after the prior exact commit");
}

void previewRetirementClearsRetainedGesture() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(110, false), {1}),
             router::ActionKind::NativePrepare, "retirement preview prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "retirement preview starts")
          .start;
  action(router.onNativeStarted(
             {start.stamp, start.preparedGeneration, 3}, {3}),
         router::ActionKind::NativeSetRunState,
         "retirement preview becomes active");
  const auto preview =
      action(router.previewFrame(
                 {native::GestureId{6}, native::RequestId{1}, 50.0}, {4}),
             router::ActionKind::NativePreviewFrame,
             "retirement reserves an exact preview")
          .previewFrame;
  const auto stop =
      action(router.open(nativeOpen(111), {5}),
             router::ActionKind::NativeStop,
             "replacement exact-retires a retained preview")
          .stop;
  expect(stop.invalidationGeneration.value > preview.generation.value,
         "replacement Stop invalidates the preview generation");
  expect(router.onNativeFailed(
                   {preview.stamp, native::FailureReason::Preview}, {6})
                 .status == router::Status::Ignored,
         "preview failure is stale after replacement Stop admission");
  const auto replacement =
      action(router.onNativeStopped(
                 {stop.stamp, stop.invalidationGeneration}, {7}),
             router::ActionKind::NativePrepare,
             "exact Stopped releases the replacement")
          .prepare;
  const auto replacementStart =
      action(router.onNativePrepared(preparedFor(replacement), {8}),
             router::ActionKind::NativeStart,
             "replacement obtains its own native generation")
          .start;
  action(router.previewFrame(
             {native::GestureId{7}, native::RequestId{1}, 10.0}, {9}),
         router::ActionKind::NativePreviewFrame,
         "replacement admits a new gesture after retirement");
  expect(router.abandonNativeAfterSynchronousRetirement({10}).status ==
                 router::Status::Applied &&
             router.snapshot().state == router::State::Idle,
         "synchronous native retirement clears preview ownership");
  const auto afterReset =
      action(router.open(nativeOpen(112), {11}),
             router::ActionKind::NativePrepare,
             "explicit open is admitted after synchronous reset")
          .prepare;
  action(router.onNativePrepared(preparedFor(afterReset), {12}),
         router::ActionKind::NativeStart,
         "post-reset source establishes a fresh live generation");
  action(router.previewFrame(
             {native::GestureId{8}, native::RequestId{1}, 11.0}, {13}),
         router::ActionKind::NativePreviewFrame,
         "post-reset route admits another new gesture");
  static_cast<void>(replacementStart);
}

void previewFailureRequiresExactStopBeforeFallback() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(113, false), {1}),
             router::ActionKind::NativePrepare, "failed preview prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "failed preview starts")
          .start;
  action(router.onNativeStarted(
             {start.stamp, start.preparedGeneration, 4}, {3}),
         router::ActionKind::NativeSetRunState,
         "failed preview becomes active");
  const auto preview =
      action(router.previewFrame(
                 {native::GestureId{9}, native::RequestId{1}, 70.0}, {4}),
             router::ActionKind::NativePreviewFrame,
             "failed preview owns the latest command")
          .previewFrame;
  const auto stop =
      action(router.onNativeFailed(
                 {preview.stamp, native::FailureReason::Preview}, {5}),
             router::ActionKind::NativeStop,
             "exact preview failure retires native before fallback")
          .stop;
  expect(router.snapshot().state == router::State::NativeStopping &&
             router.snapshot().hasPendingOpen,
         "preview failure retains fallback until exact Stop proof");
  action(router.onNativeStopped({stop.stamp, stop.invalidationGeneration}, {6}),
         router::ActionKind::CreateFallback,
         "preview fallback starts only after native retirement");
}

void previewFramesAreLiveWhileStartingAndEnded() {
  router::PlaybackRouter starting;
  const auto prepare =
      action(starting.open(nativeOpen(107), {1}),
             router::ActionKind::NativePrepare, "starting preview prepares")
          .prepare;
  const auto start =
      action(starting.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "starting preview issues Start")
          .start;
  const auto preview =
      action(starting.previewFrame(
                 {native::GestureId{3}, native::RequestId{1}, 12.0}, {3}),
             router::ActionKind::NativePreviewFrame,
             "prepared generation can preview before Started")
          .previewFrame;
  expect(starting.snapshot().state == router::State::NativeStarting &&
             preview.generation == start.preparedGeneration,
         "preview does not consume the outstanding Started transition");
  expect(starting.setPaused(false, {4}).status == router::Status::Applied,
         "starting preview retains a newer play intent");
  const auto run =
      action(starting.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 1}, {5}),
             router::ActionKind::NativeSetRunState,
             "Started remains admissible after a preview reservation")
          .runState;
  expect(!run.paused && run.stamp.serial.value > preview.stamp.serial.value,
         "Started applies the intent after all prior preview serials");
  action(starting.commitSeek({native::GestureId{3}, native::RequestId{2},
                              12.5, 1},
                             {6}),
         router::ActionKind::NativeCommitSeek,
         "commit still follows a preview retained across Started");

  router::PlaybackRouter ended;
  const auto endedPrepare =
      action(ended.open(nativeOpen(108, false), {1}),
             router::ActionKind::NativePrepare, "ended preview prepares")
          .prepare;
  const auto endedStart =
      action(ended.onNativePrepared(preparedFor(endedPrepare), {2}),
             router::ActionKind::NativeStart, "ended preview starts")
          .start;
  const auto endedRun =
      action(ended.onNativeStarted(
                 {endedStart.stamp, endedStart.preparedGeneration, 2}, {3}),
             router::ActionKind::NativeSetRunState,
             "ended preview becomes active")
          .runState;
  expect(ended.onNativeEnded(
                   {endedRun.stamp, endedRun.generation, 120.0}, {4})
                 .status == router::Status::Applied,
         "ended preview reaches retained EOS");
  const auto endedPreview =
      action(ended.previewFrame(
                 {native::GestureId{4}, native::RequestId{1}, 60.0}, {5}),
             router::ActionKind::NativePreviewFrame,
             "ended generation remains available for preview")
          .previewFrame;
  expect(ended.snapshot().state == router::State::NativeEnded &&
             endedPreview.generation == endedRun.generation,
         "ended preview retains EOS state and active generation");
  action(ended.commitSeek({native::GestureId{4}, native::RequestId{2},
                           60.0, 2},
                          {6}),
         router::ActionKind::NativeCommitSeek,
         "ended preview can become an exact replay commit");
}

void previewFromEndedCanRetireWithoutReplay() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(118, false), {1}),
             router::ActionKind::NativePrepare,
             "ended preview cancellation prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart,
             "ended preview cancellation starts")
          .start;
  const auto run =
      action(router.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 3}, {3}),
             router::ActionKind::NativeSetRunState,
             "ended preview cancellation becomes active")
          .runState;
  expect(router.onNativeEnded(
                   {run.stamp, run.generation, 120.0}, {4})
                 .status == router::Status::Applied,
         "ended preview cancellation reaches retained EOS");
  const auto preview =
      action(router.previewFrame(
                 {native::GestureId{14}, native::RequestId{1}, 45.0}, {5}),
             router::ActionKind::NativePreviewFrame,
             "ended preview cancellation reserves a frame")
          .previewFrame;
  const auto stop =
      action(router.stop({6}), router::ActionKind::NativeStop,
             "ended preview cancellation retires native ownership")
          .stop;
  expect(stop.stamp.serial.value > preview.stamp.serial.value &&
             stop.invalidationGeneration.value > preview.generation.value &&
             router.snapshot().state == router::State::NativeStopping,
         "Stop supersedes the exact ended preview lineage");
  expect(router.onNativeFailed(
                   {preview.stamp, native::FailureReason::Preview}, {7})
                 .status == router::Status::Ignored,
         "late ended-preview failure cannot defeat cancellation");
  expect(router.onNativeStopped(
                   {stop.stamp, stop.invalidationGeneration}, {8})
                 .status == router::Status::Applied &&
             router.snapshot().state == router::State::Idle,
         "exact Stopped proof completes ended-preview cancellation");
}

void previewSerialExhaustionStopsAndClearsGesture() {
  constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
  router::PlaybackRouter router(
      {}, {},
      {native::AttemptId{maximum}, native::Serial{4},
       native::Generation{native::kMaximumLiveValue}});
  const auto prepare =
      action(router.open(nativeOpen(109, false), {1}),
             router::ActionKind::NativePrepare, "bounded preview prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "bounded preview starts")
          .start;
  const auto run =
      action(router.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 1}, {3}),
             router::ActionKind::NativeSetRunState,
             "bounded preview becomes active")
          .runState;
  const auto preview =
      action(router.previewFrame(
                 {native::GestureId{5}, native::RequestId{1}, 30.0}, {4}),
             router::ActionKind::NativePreviewFrame,
             "last live serial is reserved by preview")
          .previewFrame;
  expect(preview.stamp.serial == native::Serial{4} &&
             preview.generation == run.generation,
         "preview consumes the exact final live serial");
  const auto stop =
      action(router.previewFrame(
                 {native::GestureId{5}, native::RequestId{2}, 31.0}, {5}),
             router::ActionKind::NativeStop,
             "preview serial exhaustion exact-retires native ownership")
          .stop;
  expect(stop.stamp.serial == native::Serial{native::kTerminalStopValue} &&
             router.snapshot().state == router::State::NativeStopping &&
             !router.snapshot().hasPendingOpen,
         "preview serial never wraps or silently creates fallback");
  expect(router.previewFrame(
                   {native::GestureId{5}, native::RequestId{3}, 32.0}, {6})
                 .status == router::Status::Ignored,
         "preview is inert after terminal Stop admission");
  const auto retired = router.onNativeStopped(
      {stop.stamp, stop.invalidationGeneration}, {7});
  expect(retired.status == router::Status::Applied && !retired.action &&
             router.snapshot().state == router::State::Idle,
         "exact Stopped proof clears the exhausted gesture lineage");
}

void resumeCommitMayStartBeforeStartedFact() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(111, false), {1}),
             router::ActionKind::NativePrepare, "resume route prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "resume route enters Starting")
          .start;
  const auto commit =
      action(router.commitSeek({native::GestureId{1}, native::RequestId{1},
                                73.0, 4},
                               {3}),
             router::ActionKind::NativeCommitSeek,
             "resume position commits while native Start is outstanding")
          .commitSeek;
  expect(router.snapshot().state == router::State::NativeSeeking &&
             commit.sourceGeneration == start.preparedGeneration,
         "resume commit targets the prepared generation immediately");
  expect(router.onNativeStarted(
                   {start.stamp, start.preparedGeneration, 4}, {4})
                 .status == router::Status::Ignored,
         "late original Started cannot rewind a seeking route");
  const auto run =
      action(router.onNativeCommitReady(readyFor(commit, 5), {5}),
             router::ActionKind::NativeSetRunState,
             "resume CommitReady activates requested position")
          .runState;
  expect(!run.paused && run.generation == commit.targetGeneration,
         "resume position preserves autoplay intent");
}

void commitFallbackExhaustionWaitsForExactRetirement() {
  router::PlaybackRouter router(
      {}, {},
      {native::AttemptId{1}, native::Serial{native::kMaximumLiveValue},
       native::Generation{1}});
  const auto prepare =
      action(router.open(nativeOpen(116, false), {1}),
             router::ActionKind::NativePrepare,
             "last attempt and generation can prepare")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart,
             "last-generation source starts")
          .start;
  action(router.onNativeStarted(
             {start.stamp, start.preparedGeneration, 1}, {3}),
         router::ActionKind::NativeSetRunState,
         "last-generation source becomes active");

  const auto stop =
      action(router.commitSeek({native::GestureId{1}, native::RequestId{1},
                                44.0, 1},
                               {4}),
             router::ActionKind::NativeStop,
             "seek generation exhaustion still retires native exactly")
          .stop;
  expect(router.snapshot().state == router::State::NativeStopping,
         "fallback attempt exhaustion cannot bypass native retirement");
  expect(router.onNativeStopped(
                   {stop.stamp,
                    native::Generation{stop.invalidationGeneration.value + 1}},
                   {5})
                 .status == router::Status::Ignored,
         "wrong Stop proof cannot expose deferred exhaustion");
  expect(router.onNativeStopped({stop.stamp, stop.invalidationGeneration}, {6})
                 .status == router::Status::Exhausted &&
             router.snapshot().state == router::State::Idle,
         "fallback attempt exhaustion surfaces only after exact retirement");
}

void endedSeekRestartsAndSeekingRetiresExactTarget() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(121, false), {1}),
             router::ActionKind::NativePrepare, "ended seek prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "ended seek starts")
          .start;
  const auto run =
      action(router.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 10}, {3}),
             router::ActionKind::NativeSetRunState, "ended seek runs")
          .runState;
  expect(router.onNativeEnded({run.stamp, run.generation, 120.0}, {4}).status ==
             router::Status::Applied,
         "ended seek reaches retained EOS");
  expect(router.setPaused(false, {5}).status == router::Status::Applied,
         "ended seek retains replay intent");
  const auto commit =
      action(router.commitSeek({native::GestureId{2}, native::RequestId{1},
                                0.0, 10},
                               {6}),
             router::ActionKind::NativeCommitSeek,
             "ended route can commit back to the beginning")
          .commitSeek;
  const auto replacementStop =
      action(router.open(nativeOpen(122), {7}),
             router::ActionKind::NativeStop,
             "replacement exact-retires in-flight commit target")
          .stop;
  expect(replacementStop.invalidationGeneration.value >
             commit.targetGeneration.value,
         "Stop invalidates the reserved target generation, not only source");
  expect(router.onNativeCommitReady(readyFor(commit, 11), {8}).status ==
             router::Status::Ignored,
         "CommitReady is stale after Stop admission");
  const auto next =
      action(router.onNativeStopped(
                 {replacementStop.stamp,
                  replacementStop.invalidationGeneration},
                 {9}),
             router::ActionKind::NativePrepare,
             "replacement starts after exact seek retirement")
          .prepare;
  expect(next.sourceKey == native::SourceKey{122},
         "seeking replacement retains newest source");
}

void timeoutStopsButNeverManufacturesQuiescence() {
  router::PlaybackRouter router({5, 5});
  action(router.open(nativeOpen(81), {10}), router::ActionKind::NativePrepare,
         "timed native prepare");
  expect(router.advance({14}).status == router::Status::Ignored,
         "caller tick before deadline does nothing");
  const auto stop = action(router.advance({15}), router::ActionKind::NativeStop,
                           "caller-supplied deadline requests Stop")
                        .stop;
  expect(router.advance({1000}).status == router::Status::Ignored,
         "time cannot manufacture a Stopped proof");
  action(
      router.onNativeStopped({stop.stamp, stop.invalidationGeneration}, {1001}),
      router::ActionKind::CreateFallback,
      "only exact proof releases timed-out native ownership");
}

void naturalEndRetainsNativeUntilExactStop() {
  router::PlaybackRouter router;
  const auto prepare =
      action(router.open(nativeOpen(91, false), {1}),
             router::ActionKind::NativePrepare, "EOS route prepares")
          .prepare;
  const auto start =
      action(router.onNativePrepared(preparedFor(prepare), {2}),
             router::ActionKind::NativeStart, "EOS route starts")
          .start;
  const auto run =
      action(router.onNativeStarted(
                 {start.stamp, start.preparedGeneration, 4}, {3}),
             router::ActionKind::NativeSetRunState,
             "EOS route issues physical run state")
          .runState;
  expect(router.onNativeEnded(
                    {{{run.stamp.attempt.value + 1}, run.stamp.serial},
                     run.generation, 120.0},
                    {4})
                 .status == router::Status::Ignored,
         "wrong-attempt Ended is ignored");
  expect(router.onNativeEnded(
                    {run.stamp, {run.generation.value + 1}, 120.0}, {5})
                 .status == router::Status::Ignored,
         "wrong-generation Ended is ignored");
  const auto ended =
      router.onNativeEnded({run.stamp, run.generation, 120.0}, {6});
  expect(ended.status == router::Status::Applied && !ended.action &&
             router.snapshot().state == router::State::NativeEnded &&
             router.snapshot().generation == run.generation,
         "exact Ended retains native generation without fallback");
  const auto endedPause = router.setPaused(true, {7});
  expect(endedPause.status == router::Status::Applied &&
             !endedPause.action,
         "ended route retains intent without issuing a live command");
  const auto stop =
      action(router.open(nativeOpen(92), {8}),
             router::ActionKind::NativeStop,
             "replacement still exact-retires ended native ownership")
          .stop;
  const auto next =
      action(router.onNativeStopped(
                 {stop.stamp, stop.invalidationGeneration}, {9}),
             router::ActionKind::NativePrepare,
             "replacement begins only after exact ended Stop proof")
          .prepare;
  expect(next.sourceKey == native::SourceKey{92},
         "exact Stop releases ended ownership to queued source");
}

} // namespace

int main() {
  nativeSuccessHasZeroFallback();
  unsupportedIsTheOnlyImmediateFallback();
  allocationFailureRequiresExactStopProof();
  admissionFailureBeforeResourcesIsImmediateFallback();
  supersedingOpenBurnsStaleFacts();
  stopAndFallbackOrdering();
  exhaustionFailsWithoutWrapping();
  wrongLineageAndLatestIntent();
  timeoutStopsButNeverManufacturesQuiescence();
  naturalEndRetainsNativeUntilExactStop();
  commitSeekPromotesOnlyExactReady();
  previewFramesReserveLatestGestureAndCommit();
  previewRetirementClearsRetainedGesture();
  previewFailureRequiresExactStopBeforeFallback();
  previewFramesAreLiveWhileStartingAndEnded();
  previewFromEndedCanRetireWithoutReplay();
  previewSerialExhaustionStopsAndClearsGesture();
  resumeCommitMayStartBeforeStartedFact();
  commitFallbackExhaustionWaitsForExactRetirement();
  endedSeekRestartsAndSeekingRetiresExactTarget();
  std::cout << "playback router tests passed\n";
  return 0;
}
