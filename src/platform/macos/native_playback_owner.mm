#include "media/startup_benchmark.hpp"
#include "native_playback_owner.hpp"
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <limits>

namespace wam::macos {
namespace {
constexpr unsigned kMaximumImmediateTransitions = 12;
bool applied(const playback_router::Transition& transition) noexcept {
  return transition.status == playback_router::Status::Applied;
}
}
NativePlaybackOwner::NativePlaybackOwner()
    : ownerLifetime_(std::make_shared<ObservationBridge>()) {
  ownerLifetime_->owner = this;
}
NativePlaybackOwner::~NativePlaybackOwner() {
  ownerLifetime_->owner = nullptr;
  if (observationBridge_) observationBridge_->owner = nullptr;
  if (nativeSession_ && retirement_ && !retirement_->started())
    retirement_->retire(std::move(nativeSession_), {}, nullptr);
}

bool NativePlaybackOwner::hasNativeSession() const noexcept { return nativeSession_ != nullptr; }
NativeMediaSessionMetrics NativePlaybackOwner::nativeMetrics() const noexcept {
  return nativeSession_ ? nativeSession_->metrics() : NativeMediaSessionMetrics{};
}
void NativePlaybackOwner::setNativeMetricsEnabled(bool enabled) noexcept {
  if (nativeSession_) nativeSession_->setMetricsEnabled(enabled);
}
std::shared_ptr<const media::MediaSourceDescriptor> NativePlaybackOwner::nativeDescriptor() const noexcept {
  return nativeSession_ ? nativeSession_->descriptor() : nullptr;
}
double NativePlaybackOwner::nativeSeekCeilingSeconds() const noexcept {
  return nativeSession_ ? nativeSession_->seekCeilingSeconds() : 0.0;
}
void NativePlaybackOwner::drainCurrentObservations() {
  if (nativeSession_) drainObservations(observationBridge_ ? observationBridge_->epoch : 0);
}

playback_router::Tick NativePlaybackOwner::nextTick() noexcept {
  if (tick_ != std::numeric_limits<std::uint64_t>::max()) {
    ++tick_;
  }
  return {tick_};
}

// Why the native phases are bounded by a wall-clock watchdog.
//
// NativePreparing, NativeStarting and NativeSeeking are the phases whose
// completion depends entirely on a fact arriving from the session worker.
// Every other phase either owns a physical transport or has already published
// its route. The router's tick domain is an event counter, so a session that
// simply stops publishing never advances a tick and never trips a tick
// deadline: the app
// then sits with a visible window, an idle worker, and no failure. Bound all
// three phases against the wall clock instead (PlaybackRouter::expirePhase),
// so an open, a start, or a seek
// commit either progresses or is retired into compatibility playback with a
// diagnostic retained in the log.
//
// NativeSeeking is bounded for the same reason as the other two and not one
// step less: its CommitReady needs an audio-clock proof and a video-draw proof
// covering the target, and any pipeline stall that withholds either one parks
// the route with a frozen position, a live window, and complete silence.
//
// NativeStopping is bounded for a stronger reason still. Its Stopped proof
// requires the tracked video output to observe its terminal invalidation, and
// on the Qt path that observation is published only from a real render pass
// (QtGlVideoNode acknowledges the invalidated generation while rendering or
// while being destroyed). A window that has stopped compositing -- fully
// occluded, on another Space, minimised, or moved offscreen -- therefore never
// produces it, so a stop or a replacement open issued while parked would wait
// forever behind the OLD frame with no failure, no timeout and no recovery.
// The GUI-thread final flush has already invalidated the item by then, so
// forcing retirement here cannot let a retired generation reach the screen.

void NativePlaybackOwner::refreshNativePhaseWatchdog() {
  if (retirementPending() || !playback_router::isBoundedNativePhase(router_.snapshot().state)) {
    ++nativePhaseWatchdogEpoch_;
    nativePhaseWatchdogArmed_ = false;
    return;
  }
  if (nativePhaseWatchdogArmed_) {
    return;
  }
  nativePhaseWatchdogArmed_ = true;
  const bool seeking = router_.snapshot().state == playback_router::State::NativeSeeking;
  // Seek progress reads the session metrics, so arm their publication now.
  if (seeking && nativeSession_) nativeSession_->setMetricsEnabled(true);
  if (!seeking) nativeSeekProgress_ = {};
  const std::uint64_t epoch = ++nativePhaseWatchdogEpoch_;
  const auto lifetime = ownerLifetime_;
  const int milliseconds = seeking ? media::SeekProgressDeadline::pollMilliseconds
                                   : int(media::kNativeStallDeadlineMilliseconds);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(milliseconds) * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    if (lifetime->owner) lifetime->owner->expireNativePhaseWatchdog(epoch);
  });
}

void NativePlaybackOwner::expireNativePhaseWatchdog(std::uint64_t epoch) {
  assert([NSThread isMainThread]);
  if (!nativePhaseWatchdogArmed_ || epoch != nativePhaseWatchdogEpoch_) {
    return;
  }
  nativePhaseWatchdogArmed_ = false;
  if (nativeSession_ != nullptr) {
    // A fact may have been queued but not yet drained. Consume it first so a
    // session that did finish is never retired by its own watchdog.
    drainObservations(observationBridge_ ? observationBridge_->epoch : 0);
  }
  const playback_router::State state = router_.snapshot().state;
  if (!playback_router::isBoundedNativePhase(state)) {
    refreshNativePhaseWatchdog();
    return;
  }
  const bool seeking = state == playback_router::State::NativeSeeking;
  const bool stopping = state == playback_router::State::NativeStopping;
  if (seeking && nativeSession_ != nullptr) {
    const auto progress = nativeSession_->metrics();
    if (!nativeSeekProgress_.expired(progress.decodedPrerollFrames)) {
      if (progress.slowSeek) {
        seekProgress(progress.decodedPrerollFrames);
      }
      refreshNativePhaseWatchdog();
      return;
    }
  }
  if (stopping) {
    static_cast<void>(router_.expirePhase(nextTick()));
    retireNativeSession([this] {
      nativeStop_.reset();
      execute(router_.retireStoppingAfterSynchronousTeardown(nextTick()));
    });
    return;
  }
  playback_router::Transition transition = router_.expirePhase(nextTick());
  if (!applied(transition)) {
    // Nothing was retired, so the phase is still live and still needs bounding.
    refreshNativePhaseWatchdog();
    return;
  }
  clearNativeCommit(true);
  // Both texts end in "using compatibility playback": the watchdog only ever
  // fires into a fallback continuation, never a hard stop.
  ownerNotice(
      seeking ? "Native playback could not complete the seek in "
                               "time; using compatibility playback."
              : "Native playback did not start in time; using "
                               "compatibility playback.");
  execute(std::move(transition));
}

NativePlaybackOwner::PreviewHandoffDisposition
NativePlaybackOwner::preparePreviewHandoff() {
  assert([NSThread isMainThread]);
  const playback_router::State state = router_.snapshot().state;
  // A fully published Ended session has already drained the main decoder and
  // stopped audio, but still retains its source/context for exact replay. It
  // therefore supports the same pointer-down preview prewarm without first
  // reviving the authoritative playback generation.
  if (nativeSession_ == nullptr ||
      !playback_router::nativeGenerationLive(state)) {
    return PreviewHandoffDisposition::Deferred;
  }
  const macos::NativeMediaSessionCommandStatus status =
      nativeSession_->preparePreviewHandoff();
  if (status == macos::NativeMediaSessionCommandStatus::Unsupported) {
    return PreviewHandoffDisposition::Unsupported;
  }
  return (status == macos::NativeMediaSessionCommandStatus::Accepted ||
          status == macos::NativeMediaSessionCommandStatus::Ignored)
             ? PreviewHandoffDisposition::Prepared
             : PreviewHandoffDisposition::Deferred;
}

NativePlaybackOwner::PreviewDisposition
NativePlaybackOwner::previewFrame(double targetSeconds, std::uint64_t gesture,
                                  std::uint64_t request) {
  assert([NSThread isMainThread]);
  if (!std::isfinite(targetSeconds) || gesture == 0 || request == 0) {
    return PreviewDisposition::Rejected;
  }
  const playback_router::State before = router_.snapshot().state;
  switch (before) {
  case playback_router::State::Idle:
  case playback_router::State::FallbackCreating:
  case playback_router::State::FallbackOpening:
  case playback_router::State::FallbackActive:
  case playback_router::State::FallbackStopping:
    return PreviewDisposition::NotOwned;
  case playback_router::State::NativeStarting:
  case playback_router::State::NativeActive:
  case playback_router::State::NativeEnded:
    break;
  case playback_router::State::NativePreparing:
  case playback_router::State::NativeSeeking:
  case playback_router::State::NativeStopping:
  case playback_router::State::NativeStopFailed:
    return PreviewDisposition::Rejected;
  }

  if (nativeSession_ == nullptr ||
      (nativePreviewGesture_ != 0 && nativePreviewGesture_ != gesture) ||
      nativePreviewSubmissionEpoch_ ==
          std::numeric_limits<std::uint64_t>::max()) {
    return PreviewDisposition::Rejected;
  }
  previewDispatched({gesture}, {request}, targetSeconds);
  nativePreviewGesture_ = gesture;
  const std::uint64_t submissionEpoch = ++nativePreviewSubmissionEpoch_;
  // Drain only after establishing a local latest-call barrier. QML signals
  // produced by the drain may synchronously submit a newer pointer target;
  // this older call must then stop before reserving Router/session lineage.
  drainObservations(observationBridge_ ? observationBridge_->epoch : 0);
  if (nativePreviewGesture_ != gesture ||
      nativePreviewSubmissionEpoch_ != submissionEpoch) {
    return PreviewDisposition::Stale;
  }
  const playback_router::State state = router_.snapshot().state;
  if (!playback_router::nativeGenerationLive(state)) {
    return PreviewDisposition::Rejected;
  }
  std::optional<macos::NativePreviewFrameTarget> target =
      nativeSession_->preflightPreviewTarget(targetSeconds);
  if (!target.has_value()) {
    return PreviewDisposition::Rejected;
  }

  playback_router::Transition transition =
      router_.previewFrame({native_protocol::GestureId{gesture},
                            native_protocol::RequestId{request}, targetSeconds},
                           nextTick());
  if (!applied(transition) || !transition.action.has_value() ||
      transition.action->kind !=
          playback_router::ActionKind::NativePreviewFrame) {
    // Serial exhaustion can legitimately turn preview admission into exact
    // native Stop. Execute that terminal action, but ordinary preview refusal
    // remains quiet and never manufactures a fallback transition.
    if (applied(transition)) {
      execute(std::move(transition));
    }
    return PreviewDisposition::Rejected;
  }

  nativePreviewTarget_ = std::move(target);
  nativePreview_ = transition.action->previewFrame;
  nativePreviewDisposition_ = PreviewDisposition::Rejected;
  execute(std::move(transition));
  return nativePreviewDisposition_;
}

NativePlaybackOwner::SeekDisposition
NativePlaybackOwner::commitSeek(media::MediaTime target, std::uint64_t gesture,
                                std::uint64_t request, bool intendedPaused) {
  assert([NSThread isMainThread]);
  if (nativeSession_ != nullptr) {
    drainObservations(observationBridge_ ? observationBridge_->epoch : 0);
  }

  const playback_router::State state = router_.snapshot().state;
  switch (state) {
  case playback_router::State::Idle:
    return SeekDisposition::NotOwned;
  case playback_router::State::FallbackCreating:
  case playback_router::State::FallbackOpening:
  case playback_router::State::FallbackActive:
  case playback_router::State::FallbackStopping:
    return SeekDisposition::FallbackHandled;
  case playback_router::State::NativeStarting:
  case playback_router::State::NativeActive:
  case playback_router::State::NativeEnded:
  case playback_router::State::NativeSeeking:
    break;
  case playback_router::State::NativePreparing:
  case playback_router::State::NativeStopping:
  case playback_router::State::NativeStopFailed:
    return SeekDisposition::NativeRejected;
  }

  if (nativeSession_ == nullptr) {
    surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native seeking lost its playback session.");
    return SeekDisposition::NativeRejected;
  }
  std::optional<macos::NativeMediaSessionCommitTarget> commitTarget =
      nativeSession_->preflightCommitTarget(target);
  if (!commitTarget.has_value()) {
    surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native seeking cannot represent this exact target.");
    return SeekDisposition::NativeRejected;
  }

  const playback_router::CommitSeekRequest seekRequest{
      native_protocol::GestureId{gesture}, native_protocol::RequestId{request},
      commitTarget->exact(), commitTarget->drawBaseline()};
  playback_router::Transition transition =
      router_.commitSeek(seekRequest, nextTick());
  if (!applied(transition) || !transition.action.has_value() ||
      transition.action->kind !=
          playback_router::ActionKind::NativeCommitSeek) {
    surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native seeking could not reserve exact lineage.");
    if (applied(transition)) {
      execute(std::move(transition));
    }
    return SeekDisposition::NativeRejected;
  }

  const native_protocol::CommitSeek command = transition.action->commitSeek;
  nativeCommitTarget_ = std::move(commitTarget);
  nativeCommit_ = command;
  nativeSeekProgress_ = {};
  nativeCommitDrawBaseline_ = nativeCommitTarget_->drawBaseline();
  nativeCommitTime_ = nativeCommitTarget_->exact();
  nativeCommitDispatchAccepted_ = false;

  // The controller may have changed logical play/pause during a scrub while
  // native playback stayed physically paused. Retain that latest intent only
  // after CommitSeek owns the route; CommitReady emits its one authoritative
  // SetRunState command for the promoted generation.
  const playback_router::Transition pauseTransition =
      router_.setPaused(intendedPaused, nextTick());
  if (!applied(pauseTransition) || pauseTransition.action.has_value()) {
    clearNativeCommit(false);
    surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native seeking could not retain transport intent.");
    execute(router_.onNativeFailed(
        {command.stamp, native_protocol::FailureReason::Protocol}, nextTick()));
    return SeekDisposition::NativeRejected;
  }

  execute(std::move(transition));
  return nativeCommitDispatchAccepted_ ? SeekDisposition::NativeHandled
                                       : SeekDisposition::NativeRejected;
}

bool NativePlaybackOwner::setGain(float gain) {
  if (!nativeOwnsTransport()) {
    return false;
  }
  if (nativeSession_ == nullptr) {
    return true;
  }
  const auto status = nativeSession_->setGain(gain);
  if (status == macos::NativeMediaSessionCommandStatus::Invalid ||
      status == macos::NativeMediaSessionCommandStatus::Closed) {
    surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native audio rejected the volume change.");
  }
  return true;
}

bool NativePlaybackOwner::setRate(double rate) {
  assert([NSThread isMainThread]);
  if (!nativeOwnsTransport()) {
    return false;
  }
  const playback_router::Transition transition =
      router_.setRate(rate, nextTick());
  if (!applied(transition)) {
    return false;
  }
  execute(transition);
  return true;
}

bool NativePlaybackOwner::setPreservePitch(bool preserve) {
  assert([NSThread isMainThread]);
  if (!nativeOwnsTransport()) {
    return false;
  }
  const playback_router::Transition transition =
      router_.setPreservePitch(preserve, nextTick());
  if (!applied(transition)) {
    return false;
  }
  execute(transition);
  return true;
}

bool NativePlaybackOwner::setMuted(bool muted) {
  if (!nativeOwnsTransport()) {
    return false;
  }
  if (nativeSession_ == nullptr) {
    return true;
  }
  const auto status = nativeSession_->setMuted(muted);
  if (status == macos::NativeMediaSessionCommandStatus::Invalid ||
      status == macos::NativeMediaSessionCommandStatus::Closed) {
    surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native audio rejected the mute change.");
  }
  return true;
}

bool NativePlaybackOwner::nativeOwnsTransport() const noexcept {
  return playback_router::ownsNativeTransport(router_.snapshot().state);
}

bool NativePlaybackOwner::fallbackOwnsTransport() const noexcept {
  return playback_router::ownsFallbackTransport(router_.snapshot().state);
}

bool NativePlaybackOwner::needsFallbackRenderContext() const noexcept {
  return playback_router::fallbackPlaying(router_.snapshot().state);
}

bool NativePlaybackOwner::acceptsFallbackPlaybackEvents() const noexcept {
  const playback_router::State state = router_.snapshot().state;
  return playback_router::fallbackPlaying(state) ||
         state == playback_router::State::FallbackStopping;
}

bool NativePlaybackOwner::deferFallbackCompletionWhileRouting() noexcept {
  if (executeDepth_ == 0 && fallbackEventDrainDepth_ == 0) {
    return false;
  }
  fallbackCompletionDeferred_ = true;
  return true;
}

void NativePlaybackOwner::beginFallbackEventDrain() noexcept {
  ++fallbackEventDrainDepth_;
}

void NativePlaybackOwner::endFallbackEventDrain() {
  assert(fallbackEventDrainDepth_ != 0);
  --fallbackEventDrainDepth_;
  if (fallbackEventDrainDepth_ == 0 && executeDepth_ == 0 &&
      fallbackCompletionDeferred_) {
    fallbackCompletionDeferred_ = false;
    maybeCompleteFallbackStop();
  }
}

void NativePlaybackOwner::execute(playback_router::Transition transition) {
  ++executeDepth_;
  bool completed = false;
  for (unsigned step = 0; step != kMaximumImmediateTransitions; ++step) {
    if (!applied(transition)) {
      if (transition.status == playback_router::Status::Exhausted) {
        ownerError(
            "Playback route identities are exhausted.");
      } else if (transition.status == playback_router::Status::Invalid) {
        ownerError(
            "Playback routing rejected an invalid event.");
      }
      pruneSourceRecords();
      completed = true;
      break;
    }
    if (!transition.action.has_value()) {
      pruneSourceRecords();
      completed = true;
      break;
    }
    std::optional<playback_router::Transition> next =
        executeAction(*transition.action);
    if (!next.has_value()) {
      pruneSourceRecords();
      completed = true;
      break;
    }
    transition = *next;
  }
  if (!completed) {
    ownerError("Playback routing exceeded its immediate action bound.");
    pruneSourceRecords();
  }
  --executeDepth_;
  if (executeDepth_ == 0 && fallbackEventDrainDepth_ == 0 &&
      fallbackCompletionDeferred_) {
    fallbackCompletionDeferred_ = false;
    maybeCompleteFallbackStop();
  }
  if (executeDepth_ == 0) {
    // Every routing outcome settles here, so this is the one place that has to
    // decide whether the wall-clock admission watchdog should be running.
    refreshNativePhaseWatchdog();
  }
}

std::optional<playback_router::Transition>
NativePlaybackOwner::executeAction(const playback_router::Action &action) {
  using Kind = playback_router::ActionKind;
  switch (action.kind) {
  case Kind::NativePrepare:
    if (retirement_) {
      surfaceNativeError(NativeOwnerError::RetirementCapacityUnavailable,
                         "RetirementCapacityUnavailable");
      return rejectNativeCommand(action.prepare.stamp);
    }
    retirement_ = NativeRetirement::reserve();
    if (!retirement_) {
      surfaceNativeError(NativeOwnerError::SessionBudgetExceeded,
                         "SessionBudgetExceeded");
      return router_.onNativeFailed({action.prepare.stamp,
          native_protocol::FailureReason::Preparation}, nextTick());
    }
    nativeSelected(action.prepare);
    {
      auto result = beginNativePrepare(action);
      if (!nativeSession_ && !retirement_->started()) retirement_.reset();
      if (result && retirementPending()) {
        retirementContinuation_ = [this, transition = *result] { execute(transition); };
        return std::nullopt;
      }
      return result;
    }
  case Kind::NativeStart: {
    if (nativeSession_ == nullptr) {
      return rejectNativeCommand(action.start.stamp);
    }
    const auto status = nativeSession_->start(action.start);
    if (status != macos::NativeMediaSessionCommandStatus::Accepted) {
      return rejectNativeCommand(action.start.stamp);
    }
    return std::nullopt;
  }
  case Kind::NativeSetRunState: {
    if (nativeSession_ == nullptr) {
      return rejectNativeCommand(action.runState.stamp);
    }
    const auto status = nativeSession_->setRunState(action.runState);
    // Ignored is the session saying it is already terminal -- stopped, ended,
    // or live-failed -- so there is nothing a run command could change. That
    // is benign, exactly as it is for NativeStop below, and retiring the whole
    // native route over it turns a normal end of media into a fallback to mpv.
    // Invalid and Closed remain real protocol breaks.
    if (status != macos::NativeMediaSessionCommandStatus::Accepted &&
        status != macos::NativeMediaSessionCommandStatus::Ignored) {
      return rejectNativeCommand(action.runState.stamp);
    }
    return std::nullopt;
  }
  case Kind::NativePreviewFrame: {
    if (nativeSession_ == nullptr || !nativePreviewTarget_.has_value() ||
        !nativePreview_.has_value() ||
        nativePreview_->stamp != action.previewFrame.stamp ||
        nativePreview_->generation != action.previewFrame.generation ||
        nativePreview_->gesture != action.previewFrame.gesture ||
        nativePreview_->request != action.previewFrame.request ||
        nativePreview_->targetSeconds != action.previewFrame.targetSeconds) {
      clearNativePreview();
      nativePreviewDisposition_ = PreviewDisposition::Rejected;
      return std::nullopt;
    }
    const auto status = nativeSession_->previewFrame(
        action.previewFrame, std::move(*nativePreviewTarget_));
    nativePreviewTarget_.reset();
    switch (status) {
    case macos::NativePreviewFrameRequestStatus::Accepted:
      nativePreviewDisposition_ = PreviewDisposition::Accepted;
      previewAdmitted(action.previewFrame);
      break;
    case macos::NativePreviewFrameRequestStatus::Replaced:
      nativePreviewDisposition_ = PreviewDisposition::Replaced;
      previewAdmitted(action.previewFrame);
      break;
    case macos::NativePreviewFrameRequestStatus::Stale:
      nativePreview_.reset();
      nativePreviewDisposition_ = PreviewDisposition::Stale;
      break;
    case macos::NativePreviewFrameRequestStatus::Invalid:
    case macos::NativePreviewFrameRequestStatus::Closed:
    case macos::NativePreviewFrameRequestStatus::Failed:
      nativePreview_.reset();
      nativePreviewDisposition_ = PreviewDisposition::Rejected;
      break;
    }
    return std::nullopt;
  }
  case Kind::NativeCommitSeek: {
    clearNativePreview();
    if (nativeSession_ == nullptr || !nativeCommitTarget_.has_value() ||
        !nativeCommit_.has_value() ||
        nativeCommit_->stamp != action.commitSeek.stamp ||
        nativeCommit_->sourceGeneration != action.commitSeek.sourceGeneration ||
        nativeCommit_->targetGeneration != action.commitSeek.targetGeneration ||
        nativeCommit_->gesture != action.commitSeek.gesture ||
        nativeCommit_->request != action.commitSeek.request ||
        nativeCommit_->targetSeconds != action.commitSeek.targetSeconds) {
      clearNativeCommit(false);
      return rejectNativeCommand(action.commitSeek.stamp);
    }
    const auto status = nativeSession_->commitSeek(
        action.commitSeek, std::move(*nativeCommitTarget_));
    nativeCommitTarget_.reset();
    if (status != macos::NativeMediaSessionCommandStatus::Accepted) {
      clearNativeCommit(false);
      return rejectNativeCommand(action.commitSeek.stamp);
    }
    nativeCommitDispatchAccepted_ = true;
    commitSubmitted(action.commitSeek);
    return std::nullopt;
  }
  case Kind::NativeStop: {
    clearNativePreview();
    clearNativeCommit(true);
    if (nativeSession_ == nullptr) {
      surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native playback lost its session before retirement.");
      return std::nullopt;
    }
    nativeStop_ = action.stop;
    const auto status = nativeSession_->stop(action.stop);
    if (status != macos::NativeMediaSessionCommandStatus::Accepted &&
        status != macos::NativeMediaSessionCommandStatus::Ignored) {
      surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native playback could not begin exact retirement.");
    }
    return std::nullopt;
  }
  case Kind::CreateFallback:
    fallbackSelected(action.fallback);
    return beginFallbackCreate(action);
  case Kind::OpenFallback:
    if (!beginFallbackOpen(action)) {
      return router_.onFallbackFailed({action.fallback.stamp}, nextTick());
    }
    return std::nullopt;
  case Kind::SetFallbackRunState:
    return applyFallbackRunState(action);
  case Kind::StopFallback:
    static_cast<void>(beginFallbackStop(action));
    return std::nullopt;
  case Kind::None:
    return std::nullopt;
  }
  return std::nullopt;
}

std::optional<playback_router::Transition>
NativePlaybackOwner::rejectNativeCommand(native_protocol::Stamp stamp) {
  surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native playback rejected an internal lifecycle command.");
  return router_.onNativeFailed(
      {stamp, native_protocol::FailureReason::Protocol}, nextTick());
}

bool NativePlaybackOwner::queueObservations(std::shared_ptr<void> lifetime,
                                           void*) noexcept {
  if (!lifetime) return false;
  auto bridge = std::static_pointer_cast<ObservationBridge>(std::move(lifetime));
  dispatch_async(dispatch_get_main_queue(), ^{
    if (bridge->owner) bridge->owner->drainObservations(bridge->epoch);
  });
  return true;
}

void NativePlaybackOwner::drainObservations(std::uint64_t epoch) {
  assert([NSThread isMainThread]);
  if (nativeSession_ == nullptr || observationBridge_ == nullptr ||
      epoch == 0 || observationBridge_->epoch != epoch) {
    return;
  }
  consumeObservations(nativeSession_->takeObservations());
}

void NativePlaybackOwner::consumeObservations(
    macos::NativeMediaSessionObservations observations) {
  // CommitReady embeds the exact target-generation clock and covering draw.
  // Promote the router and controller before processing coalesced generic
  // proof slots; those may already carry a later run-state serial.
  if (observations.diagnostic) {
    const auto snapshot = router_.snapshot();
    if (observations.diagnostic->stamp == native_protocol::Stamp{snapshot.attempt, snapshot.serial})
      publishDiagnostic(*observations.diagnostic);
  }
  if (observations.commitReady.has_value()) {
    consumeCommitReady(*observations.commitReady);
  }
  if (observations.previewPresented.has_value()) {
    consumePreviewPresented(*observations.previewPresented);
  }
  if (observations.previewFailed.has_value()) {
    consumePreviewFailed(*observations.previewFailed);
  }
  if (observations.lifecycle.has_value()) {
    consumeLifecycle(*observations.lifecycle, observations.admissionRouteChoice);
  }
  if (observations.runStateApplied.has_value()) {
    consumeRunState(*observations.runStateApplied);
  }
  if (observations.audioClock.has_value()) {
    consumeAudioClock(*observations.audioClock);
  }
  if (observations.exactDraw && exactCurrent(observations.exactDraw->stamp, observations.exactDraw->generation))
    publishExactDraw(*observations.exactDraw);
  if (observations.videoDraw.has_value()) {
    consumeVideoDraw(*observations.videoDraw);
  }
}

bool NativePlaybackOwner::exactCurrent(
    native_protocol::Stamp stamp,
    native_protocol::Generation generation) const noexcept {
  const playback_router::Snapshot snapshot = router_.snapshot();
  return snapshot.state == playback_router::State::NativeActive &&
         stamp == native_protocol::Stamp{snapshot.attempt, snapshot.serial} &&
         generation == snapshot.generation;
}

void NativePlaybackOwner::clearNativePreview() noexcept {
  nativePreviewTarget_.reset();
  nativePreview_.reset();
  nativePreviewGesture_ = 0;
  nativePreviewDisposition_ = PreviewDisposition::Rejected;
}

void NativePlaybackOwner::clearNativeCommit(bool notifyFailure) noexcept {
  const std::optional<native_protocol::CommitSeek> command = nativeCommit_;
  const bool accepted = nativeCommitDispatchAccepted_;
  nativeCommitTarget_.reset();
  nativeCommit_.reset();
  nativeCommitDrawBaseline_ = 0;
  nativeCommitTime_ = {};
  nativeCommitDispatchAccepted_ = false;
  if (notifyFailure && accepted && command.has_value()) {
    commitFailed(command->gesture.value,
                                   command->request.value);
  }
}

void NativePlaybackOwner::consumeLifecycle(const NativeMediaSessionFact& fact, bool admissionRouteChoice) {
  std::visit([this, admissionRouteChoice](const auto& event) {
    using Event = std::decay_t<decltype(event)>;
    if constexpr (std::is_same_v<Event, native_protocol::Prepared>) {
      auto transition = router_.onNativePrepared(event, nextTick());
      if (!applied(transition)) return;
      execute(std::move(transition));
      publishLifecycle(event, admissionRouteChoice);
    } else if constexpr (std::is_same_v<Event, native_protocol::Started>) {
      auto transition = router_.onNativeStarted(event, nextTick());
      if (!applied(transition)) return;
      publishLifecycle(event, admissionRouteChoice);
      execute(std::move(transition));
    } else if constexpr (std::is_same_v<Event, native_protocol::Ended>) {
      auto transition = router_.onNativeEnded(event, nextTick());
      if (!applied(transition)) return;
      publishLifecycle(event, admissionRouteChoice);
      execute(std::move(transition));
    } else if constexpr (std::is_same_v<Event, native_protocol::Failed>) {
      auto transition = router_.onNativeFailed(event, nextTick());
      if (!applied(transition)) return;
      clearNativeCommit(true);
      publishLifecycle(event, admissionRouteChoice);
      if (event.reason == native_protocol::FailureReason::Preparation &&
          transition.action && transition.action->kind == playback_router::ActionKind::CreateFallback) {
        retireNativeSession([this, transition] { execute(transition); });
      } else {
        execute(std::move(transition));
      }
    } else if constexpr (std::is_same_v<Event, native_protocol::Stopped>) {
      if (!nativeStop_ || !native_protocol::stoppedMatches(*nativeStop_, event) ||
          router_.snapshot().state != playback_router::State::NativeStopping) return;
      retireNativeSession([this, event] {
        nativeStop_.reset();
        execute(router_.onNativeStopped(event, nextTick()));
      });
    }
  }, fact);
}
void NativePlaybackOwner::consumePreviewPresented(
    const native_protocol::PreviewPresented &presented) {
  if (!nativePreview_.has_value() ||
      !native_protocol::previewPresentedMatches(*nativePreview_, presented)) {
    return;
  }
  const playback_router::Snapshot snapshot = router_.snapshot();
  if (!playback_router::nativeGenerationLive(snapshot.state)) {
    return;
  }
  // A PreviewFrame admitted while Starting may be presented after Started
  // advances the router serial. The retained exact preview command remains
  // authoritative across that later run-state command; only attempt,
  // generation, and the exact preview identity must still match.
  if (presented.stamp.attempt != snapshot.attempt ||
      presented.generation != snapshot.generation) {
    return;
  }
  nativePreview_.reset();
  publishPreviewPresented(presented);
}
void NativePlaybackOwner::consumePreviewFailed(
    const native_protocol::PreviewFailed &failed) {
  if (!nativePreview_.has_value() ||
      !native_protocol::previewFailedMatches(*nativePreview_, failed)) {
    return;
  }
  const playback_router::Snapshot snapshot = router_.snapshot();
  if (!playback_router::nativeGenerationLive(snapshot.state)) {
    return;
  }
  if (failed.stamp.attempt != snapshot.attempt ||
      failed.generation != snapshot.generation) {
    return;
  }
  // The controller may immediately submit its one coalesced latest desire.
  // Retire the exact failed owner identity before crossing that reentrant Qt
  // boundary, while retaining the gesture admission for the follow-up.
  nativePreview_.reset();
  publishPreviewFailed(failed);
}
void NativePlaybackOwner::consumeRunState(
    const macos::NativeMediaSessionRunStateApplied &appliedState) {
  const native_protocol::SetRunState &command = appliedState.command;
  if (!exactCurrent(command.stamp, command.generation)) {
    return;
  }
  publishRunState(appliedState);
}
void NativePlaybackOwner::consumeAudioClock(
    const native_protocol::AudioClockProof &proof) {
  if (!exactCurrent(proof.stamp, proof.generation) ||
      proof.stamp.serial.value < lastAudioProofSerial_ ||
      !std::isfinite(proof.positionSeconds)) {
    return;
  }
  lastAudioProofSerial_ = proof.stamp.serial.value;
  publishAudioClock(proof);
}
void NativePlaybackOwner::consumeVideoDraw(
    const native_protocol::VideoDrawProof &proof) {
  if (!exactCurrent(proof.stamp, proof.generation) ||
      proof.drawSequence <= lastVideoDrawSequence_) {
    return;
  }
  lastVideoDrawSequence_ = proof.drawSequence;
  if (!std::isfinite(proof.frameStartSeconds)) {
    return;
  }
  const bool first = !firstNativeDrawReported_;
  firstNativeDrawReported_ = true;
  publishVideoDraw(proof, first);
}
void NativePlaybackOwner::consumeCommitReady(
    const native_protocol::CommitReady &ready) {
  if (!nativeCommit_.has_value() || !nativeCommitDispatchAccepted_ ||
      !native_protocol::commitReadyMatches(*nativeCommit_, nativeCommitTime_,
                                           nativeCommitDrawBaseline_, ready)) {
    return;
  }
  playback_router::Transition transition =
      router_.onNativeCommitReady(ready, nextTick());
  if (!applied(transition)) {
    return;
  }

  const native_protocol::CommitSeek completed = *nativeCommit_;
  clearNativeCommit(false);
  // Admit both embedded proofs while the router's exact current stamp is
  // still the CommitSeek command. execute(SetRunState) advances the serial.
  lastAudioProofSerial_ = ready.audioClock.stamp.serial.value;
  lastVideoDrawSequence_ = ready.videoDraw.drawSequence;
  commitProved(ready, !firstNativeDrawReported_ && !ready.videoDraw.videoLaneAbsent);
  if (!ready.videoDraw.videoLaneAbsent) firstNativeDrawReported_ = true;
  // Submit the promoted generation's authoritative run state before any
  // QML-facing signal can synchronously re-enter play/pause and reserve a
  // newer serial. The controller completion callback is safe only after this
  // action has been physically admitted (or has synchronously entered exact
  // failure retirement).
  execute(std::move(transition));
  const playback_router::Snapshot snapshot = router_.snapshot();
  if (snapshot.state != playback_router::State::NativeActive ||
      snapshot.attempt != completed.stamp.attempt ||
      snapshot.generation != completed.targetGeneration) {
    commitFailed(completed.gesture.value,
                                   completed.request.value);
    return;
  }
  publishCommitReady(ready);
}


bool NativePlaybackOwner::retirementPending() const noexcept {
  return retirement_ && retirement_->started();
}
bool NativePlaybackOwner::deferOwnerCommand(std::function<void()> command) {
  if (!retirementPending()) return false;
  deferredOwnerCommand_ = std::move(command);
  return true;
}
void NativePlaybackOwner::retireNativeSession(std::function<void()> continuation) {
  if (continuation) retirementContinuation_ = std::move(continuation);
  clearNativePreview();
  clearNativeCommit(true);
  if (observationBridge_) observationBridge_->owner = nullptr;
  observationBridge_.reset();
  ++nativePhaseWatchdogEpoch_;
  nativePhaseWatchdogArmed_ = false;
  lastAudioProofSerial_ = 0;
  lastVideoDrawSequence_ = 0;
  firstNativeDrawReported_ = false;
  sessionCleared();
  if (!nativeSession_) return;
  assert(retirement_ && !retirement_->started());
  retirement_->retire(std::move(nativeSession_), ownerLifetime_,
      [](std::shared_ptr<void> opaque) noexcept {
        const auto lifetime = std::static_pointer_cast<ObservationBridge>(opaque);
        if (lifetime->owner) lifetime->owner->retirementFinished();
      });
}
void NativePlaybackOwner::retirementFinished() {
  assert(retirement_ && retirement_->complete());
  retirement_.reset();
  auto continuation = std::move(retirementContinuation_);
  retirementContinuation_ = {};
  if (continuation) continuation();
  auto command = std::move(deferredOwnerCommand_);
  deferredOwnerCommand_ = {};
  if (command) command();
}
void NativePlaybackOwner::abandonNativeSession() {
  retireNativeSession([this] {
    nativeStop_.reset();
    const auto reset = router_.abandonNativeAfterSynchronousRetirement(nextTick());
    if (!applied(reset) || reset.action) {
      surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                         "InternalProtocolViolation");
      return;
    }
    pruneSourceRecords();
    refreshNativePhaseWatchdog();
  });
}

std::optional<playback_router::Transition>
NativePlaybackOwner::beginNativePrepare(const playback_router::Action& action) {
  const auto configuration = preparationFor(action.prepare.sourceKey);
  if (!configuration || nativeSession_) {
    return router_.onNativeFailed({action.prepare.stamp,
        native_protocol::FailureReason::Preparation}, nextTick());
  }
  ++nextObservationEpoch_;
  if (nextObservationEpoch_ == 0) {
    ++nextObservationEpoch_;
  }
  auto bridge = std::make_shared<ObservationBridge>();
  bridge->owner = this;
  bridge->epoch = nextObservationEpoch_;

  std::string error;
  bool presentationUnavailable = false;
  WAM_STARTUP_STAMP(NativeSessionCreateBegin);
  std::unique_ptr<macos::NativeMediaSession> session =
      createNativeMediaSessionSystem(
          {action.prepare.sourceKey, configuration->path,
           configuration->bufferedStorage},
          bridge, configuration->presentation, &error,
          configuration->captionFeed, &presentationUnavailable);
  WAM_STARTUP_STAMP(NativeSessionCreateEnd);
  if (session == nullptr) {
    surfaceNativeError(presentationUnavailable
                           ? NativeOwnerError::PresentationUnavailable
                           : NativeOwnerError::InternalProtocolViolation,
                       error.empty() ? "Unable to create native playback."
                                     : error.c_str());
    return router_.onNativeFailed(
        {action.prepare.stamp, native_protocol::FailureReason::Preparation},
        nextTick());
  }

  if (!session->bindObservationEdge(
          {bridge, &NativePlaybackOwner::queueObservations, nullptr}) ||
      session->setGain(configuration->gain) !=
          macos::NativeMediaSessionCommandStatus::Accepted ||
      session->setMuted(configuration->muted) !=
          macos::NativeMediaSessionCommandStatus::Accepted) {
    nativeSession_ = std::move(session);
    retireNativeSession();
    surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Unable to bind native playback controls.");
    return router_.onNativeFailed(
        {action.prepare.stamp, native_protocol::FailureReason::Preparation},
        nextTick());
  }

  nativeSession_ = std::move(session);
  observationBridge_ = std::move(bridge);
  nativeStop_.reset();
  lastAudioProofSerial_ = 0;
  lastVideoDrawSequence_ = 0;
  firstNativeDrawReported_ = false;
  WAM_STARTUP_STAMP(NativePrepareIssued);
  const auto status =
      nativeSession_->prepare(action.prepare, configuration->initialPosition);
  if (status != macos::NativeMediaSessionCommandStatus::Accepted) {
    retireNativeSession();
    surfaceNativeError(NativeOwnerError::InternalProtocolViolation,
                       "Native playback rejected media preparation.");
    return router_.onNativeFailed(
        {action.prepare.stamp, native_protocol::FailureReason::Preparation},
        nextTick());
  }
  return std::nullopt;
}


}
