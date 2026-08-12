#include "native_video_controller.hpp"

#include <algorithm>
#include <utility>

namespace wam::native_activation {
namespace {

bool timedOut(std::uint64_t now, std::uint64_t since,
              std::uint64_t limit) noexcept {
  return limit != 0 && now >= since && now - since >= limit;
}

} // namespace

NativeVideoController::NativeVideoController(
    std::unique_ptr<NativeVideoActionDriver> driver, bool enabled) noexcept
    : NativeVideoController(std::move(driver), enabled, DeadlinePolicy{}) {}

NativeVideoController::NativeVideoController(
    std::unique_ptr<NativeVideoActionDriver> driver, bool enabled,
    DeadlinePolicy deadlines) noexcept
    : driver_(std::move(driver)), deadlines_(deadlines),
      enabled_(enabled && driver_ != nullptr) {
  deadlines_.maximumSynchronousActions =
      std::max<std::uint8_t>(1, deadlines_.maximumSynchronousActions);
}

void NativeVideoController::noteProgress() noexcept {
  if (clock_initialized_)
    last_progress_tick_ = last_tick_;
}

bool NativeVideoController::progressChanged(const Snapshot &before,
                                            const Snapshot &after) noexcept {
  return before.phase != after.phase || before.token != after.token ||
         before.sourceKey != after.sourceKey ||
         before.armedRevocationGeneration != after.armedRevocationGeneration ||
         before.ignoredRetiredGenerations != after.ignoredRetiredGenerations ||
         before.ignoredRetiredGenerationCount !=
             after.ignoredRetiredGenerationCount ||
         before.desired != after.desired ||
         before.nativePrepared != after.nativePrepared ||
         before.mpvReady != after.mpvReady ||
         before.nativeDrawReady != after.nativeDrawReady ||
         before.mpvSeekConverged != after.mpvSeekConverged ||
         before.fallbackRenderReady != after.fallbackRenderReady ||
         before.fallbackVideoSelected != after.fallbackVideoSelected ||
         before.fallbackPlaybackRestarted != after.fallbackPlaybackRestarted ||
         before.nativeBurned != after.nativeBurned ||
         before.terminalAfterStop != after.terminalAfterStop ||
         before.cancelPending != after.cancelPending ||
         before.nativeRequestIssued != after.nativeRequestIssued ||
         before.rendererDenied != after.rendererDenied ||
         before.fallbackRendererInvalidationPending !=
             after.fallbackRendererInvalidationPending ||
         before.eofRestorePending != after.eofRestorePending ||
         before.preparationGeneration != after.preparationGeneration ||
         before.nativeGeneration != after.nativeGeneration ||
         before.renderStamp != after.renderStamp ||
         before.transportEpoch != after.transportEpoch ||
         before.drawBaseline != after.drawBaseline ||
         before.entry != after.entry || before.videoId != after.videoId ||
         before.seek != after.seek ||
         before.pendingCaptionId != after.pendingCaptionId ||
         before.pendingAction != after.pendingAction ||
         before.fallbackReason != after.fallbackReason;
}

FallbackReason NativeVideoController::timeoutReason(
    const Snapshot &state, const std::optional<Action> &issued) noexcept {
  if (issued) {
    switch (issued->kind) {
    case Action::Kind::SeekNative:
    case Action::Kind::SeekMpvExact:
      return FallbackReason::SeekFailure;
    case Action::Kind::RevokeMpvRenderer:
    case Action::Kind::AllowMpvRenderer:
      return FallbackReason::ContextFailure;
    case Action::Kind::LoadMpvAudioOnly:
    case Action::Kind::SelectMpvVideo:
    case Action::Kind::RestoreTransport:
    case Action::Kind::ForcePauseMpv:
      return FallbackReason::MpvFailure;
    case Action::Kind::AttachCaption:
      return FallbackReason::Caption;
    case Action::Kind::PrepareNative:
    case Action::Kind::StartNative:
    case Action::Kind::UpdateNativeClock:
    case Action::Kind::StopNative:
    case Action::Kind::SurfaceError:
    case Action::Kind::None:
      return FallbackReason::NativeFailure;
    }
  }
  switch (state.phase) {
  case Phase::Seeking:
    return FallbackReason::SeekFailure;
  case Phase::AwaitRelease:
  case Phase::FallbackAwaitRenderer:
    return FallbackReason::ContextFailure;
  case Phase::FallbackAwaitRestart:
    return FallbackReason::MpvFailure;
  case Phase::Preparing:
  case Phase::Starting:
  case Phase::Idle:
  case Phase::Active:
  case Phase::EofHeld:
  case Phase::FallbackStopping:
  case Phase::FallbackActive:
  case Phase::Failed:
    return FallbackReason::NativeFailure;
  }
  return FallbackReason::NativeFailure;
}

std::optional<Token> NativeVideoController::begin(std::uint64_t request,
                                                  std::uint64_t sourceKey,
                                                  Transport desired) noexcept {
  if (!enabled_ || driver_ == nullptr)
    return std::nullopt;
  const Snapshot before = coordinator_.snapshot();
  const std::optional<Token> token =
      coordinator_.begin(request, sourceKey, desired);
  if (token && progressChanged(before, coordinator_.snapshot())) {
    noteProgress();
    static_cast<void>(pump());
  }
  return token;
}

Action NativeVideoController::cancel(CancelMode mode) noexcept {
  const Snapshot before = coordinator_.snapshot();
  const Action action = coordinator_.cancelForStopOrOpen(mode);
  if (progressChanged(before, coordinator_.snapshot()))
    noteProgress();
  static_cast<void>(pump());
  return action;
}

bool NativeVideoController::applyDispatch(
    const NativeVideoDriverDispatch &dispatch) noexcept {
  if (!issued_action_ || dispatch.action != *issued_action_)
    return false;
  if (dispatch.status == NativeVideoDriverStatus::Pending)
    return true;

  const Action issued = *issued_action_;
  if (timed_out_action_serial_ == issued.serial)
    timed_out_action_serial_ = 0;
  issued_action_.reset();
  ActionCompletion completion = dispatch.completion;
  if (dispatch.status == NativeVideoDriverStatus::Rejected)
    completion.succeeded = false;
  static_cast<void>(coordinator_.completeAction(issued.serial, completion));
  noteProgress();
  return true;
}

bool NativeVideoController::pump() noexcept {
  if (!enabled_ || driver_ == nullptr || draining_ || drain_limit_latched_)
    return false;
  draining_ = true;
  bool worked = false;
  std::uint8_t completedSynchronously = 0;
  while (!issued_action_) {
    const std::optional<Action> pending = coordinator_.nextAction();
    if (!pending)
      break;
    if (completedSynchronously >= deadlines_.maximumSynchronousActions) {
      drain_limit_latched_ = true;
      if (const std::optional<Token> token = coordinator_.snapshot().token)
        static_cast<void>(coordinator_.fail(*token, FallbackReason::Mismatch));
      break;
    }

    issued_action_ = *pending;
    if (clock_initialized_) {
      issued_tick_ = last_tick_;
      last_progress_tick_ = last_tick_;
    }
    worked = true;
    const NativeVideoDriverDispatch dispatch = driver_->execute(*pending);
    if (!applyDispatch(dispatch) ||
        dispatch.status == NativeVideoDriverStatus::Pending) {
      break;
    }
    ++completedSynchronously;
  }
  draining_ = false;
  return worked;
}

bool NativeVideoController::poll() noexcept {
  if (!enabled_ || driver_ == nullptr || draining_)
    return false;
  const std::optional<NativeVideoDriverDispatch> event = driver_->poll();
  if (!event || !applyDispatch(*event))
    return false;
  static_cast<void>(pump());
  return true;
}

bool NativeVideoController::tick(std::uint64_t now) noexcept {
  if (!enabled_ || driver_ == nullptr || draining_)
    return false;
  if (!clock_initialized_) {
    clock_initialized_ = true;
    last_tick_ = now;
    last_progress_tick_ = now;
    if (issued_action_)
      issued_tick_ = now;
    return false;
  }
  if (now < last_tick_)
    return false;
  last_tick_ = now;
  static_cast<void>(pump());
  const Snapshot state = coordinator_.snapshot();
  const std::optional<Token> token = state.token;
  if (!token)
    return false;
  const bool actionExpired =
      issued_action_ && issued_action_->serial != timed_out_action_serial_ &&
      timedOut(now, issued_tick_, deadlines_.actionTicks);
  const bool transientActionlessPhase =
      state.phase == Phase::Preparing || state.phase == Phase::AwaitRelease ||
      state.phase == Phase::Starting || state.phase == Phase::Seeking ||
      state.phase == Phase::FallbackAwaitRenderer ||
      state.phase == Phase::FallbackAwaitRestart;
  const bool phaseExpired =
      !issued_action_ && transientActionlessPhase &&
      timedOut(now, last_progress_tick_, deadlines_.actionlessPhaseTicks);
  if (!actionExpired && !phaseExpired)
    return false;

  deadline_latched_ = true;
  last_progress_tick_ = now;
  if (actionExpired) {
    timed_out_action_serial_ = issued_action_->serial;
    if (issued_action_->kind == Action::Kind::StopNative)
      return true;
  }
  static_cast<void>(
      coordinator_.fail(*token, timeoutReason(state, issued_action_)));
  if (!issued_action_)
    static_cast<void>(pump());
  return true;
}

void NativeVideoController::accept(Action, const Snapshot &before) noexcept {
  if (progressChanged(before, coordinator_.snapshot()))
    noteProgress();
  static_cast<void>(pump());
}

#define WAM_ACCEPT_COORDINATOR(expression)                                     \
  const Snapshot before = coordinator_.snapshot();                             \
  accept((expression), before)

void NativeVideoController::nativePrepared(Token token,
                                           std::uint64_t generation) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.nativePrepared(token, generation));
}

void NativeVideoController::nativeUnsupported(Token token) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.nativeUnsupported(token));
}

void NativeVideoController::nativeFailed(Token token) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.nativeFailed(token));
}

void NativeVideoController::mpvLoadFailed(Token token) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.mpvLoadFailed(token));
}

void NativeVideoController::mpvEndFileError(Token token,
                                            std::int64_t entry) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.mpvEndFileError(token, entry));
}

void NativeVideoController::mpvReady(Token token, MpvReady ready) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.mpvReady(token, ready));
}

void NativeVideoController::evaluateRelease(
    Token token, bool renderAllowed, bool renderBusy, bool lifecycleEmpty,
    std::uint64_t lifecycleGeneration) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.evaluateRelease(
      token, renderAllowed, renderBusy, lifecycleEmpty, lifecycleGeneration));
}

void NativeVideoController::sampleNative(Token token,
                                         NativeSample sample) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.sampleNative(token, sample));
}

void NativeVideoController::setDesiredPause(Token token, bool paused) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.setDesiredPause(token, paused));
}

void NativeVideoController::setDesiredRate(Token token, double rate) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.setDesiredRate(token, rate));
}

void NativeVideoController::observeLiveTransport(Token token,
                                                 std::uint64_t epoch,
                                                 std::int64_t entry,
                                                 Transport live) noexcept {
  WAM_ACCEPT_COORDINATOR(
      coordinator_.observeLiveTransport(token, epoch, entry, live));
}

void NativeVideoController::requestSeek(Token token, double target) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.requestSeek(token, target));
}

void NativeVideoController::playbackRestart(Token token, std::uint64_t epoch,
                                            std::int64_t entry,
                                            double livePosition) noexcept {
  WAM_ACCEPT_COORDINATOR(
      coordinator_.playbackRestart(token, epoch, entry, livePosition));
}

void NativeVideoController::requestCaption(Token token,
                                           std::uint64_t captionId) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.requestCaption(token, captionId));
}

void NativeVideoController::eof(Token token, std::int64_t entry,
                                double finalPosition) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.eof(token, entry, finalPosition));
}

void NativeVideoController::beginFallback(Token token,
                                          FallbackReason reason) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.beginFallback(token, reason));
}

void NativeVideoController::fail(Token token, FallbackReason reason) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.fail(token, reason));
}

void NativeVideoController::fallbackRenderReady(
    Token token, std::uint64_t renderStamp) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.fallbackRenderReady(token, renderStamp));
}

void NativeVideoController::fallbackRendererInvalidated(
    Token token, std::uint64_t retiredStamp) noexcept {
  WAM_ACCEPT_COORDINATOR(
      coordinator_.fallbackRendererInvalidated(token, retiredStamp));
}

void NativeVideoController::fallbackPlaybackRestart(
    Token token, std::uint64_t renderStamp, std::int64_t entry,
    double livePosition) noexcept {
  WAM_ACCEPT_COORDINATOR(coordinator_.fallbackPlaybackRestart(
      token, renderStamp, entry, livePosition));
}

#undef WAM_ACCEPT_COORDINATOR

bool NativeVideoController::consumeExpectedRevocationGeneration(
    std::uint64_t retiredGeneration) noexcept {
  const Snapshot before = coordinator_.snapshot();
  if (!before.rendererDenied)
    return false;
  const bool consumed =
      coordinator_.consumeExpectedRevocationGeneration(retiredGeneration);
  if (progressChanged(before, coordinator_.snapshot()))
    noteProgress();
  return consumed;
}

Snapshot NativeVideoController::snapshot() const noexcept {
  return coordinator_.snapshot();
}

} // namespace wam::native_activation
