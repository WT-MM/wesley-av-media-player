#include "native_activation_coordinator.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace wam::native_activation {
namespace {

constexpr double kSeekConvergenceToleranceSeconds = 0.050;
constexpr std::uint64_t kMaximumRenderGeneration = UINT64_MAX >> 2U;

bool sameMpvIdentity(const MpvReady &left, const MpvReady &right) noexcept {
  return left.entry == right.entry && left.sourceKey == right.sourceKey &&
         left.videoId == right.videoId;
}

std::uint64_t nextRenderGeneration(std::uint64_t generation) noexcept {
  return generation >= kMaximumRenderGeneration ? 1 : generation + 1;
}

} // namespace

std::uint64_t
NativeActivationCoordinator::nextNonzero(std::uint64_t &value) noexcept {
  ++value;
  if (value == 0)
    ++value;
  return value;
}

bool NativeActivationCoordinator::matches(Token token) const noexcept {
  return token_ && *token_ == token && !cancel_pending_;
}

bool NativeActivationCoordinator::nativeOwnedPhase() const noexcept {
  switch (phase_) {
  case Phase::Preparing:
  case Phase::AwaitRelease:
  case Phase::Starting:
  case Phase::Active:
  case Phase::Seeking:
  case Phase::EofHeld:
    return true;
  default:
    return false;
  }
}

bool NativeActivationCoordinator::validTransport(
    const Transport &value) const noexcept {
  return std::isfinite(value.position) && value.position >= 0.0 &&
         std::isfinite(value.rate) && value.rate > 0.0;
}

bool NativeActivationCoordinator::validInitialMpv(
    const MpvReady &value) const noexcept {
  return source_key_ != 0 && value.sourceKey == source_key_ &&
         value.entry >= 0 && value.videoId > 0 && validTransport(value.live) &&
         value.live.paused && value.singletonPlaylist &&
         value.authoritativeAudio && value.subtitleFree &&
         value.exactlyOneNonAlbumartVideo && value.belongsToRequestLineage;
}

bool NativeActivationCoordinator::validFallbackMpv(
    const MpvReady &value) const noexcept {
  return source_key_ != 0 && value.sourceKey == source_key_ &&
         value.entry >= 0 && (entry_ < 0 || value.entry == entry_) &&
         value.videoId > 0 && validTransport(value.live) && value.live.paused &&
         value.authoritativeAudio && value.exactlyOneNonAlbumartVideo &&
         value.belongsToRequestLineage;
}

bool NativeActivationCoordinator::exactDraw(
    const NativeSample &sample, std::uint64_t generation,
    std::uint64_t baseline) const noexcept {
  return generation != 0 && sample.active && !sample.failed &&
         !sample.stopping && sample.generation == generation &&
         sample.acceptedGeneration == generation &&
         sample.lastRenderedGeneration == generation &&
         sample.acceptedRenderedFrames > baseline;
}

Action NativeActivationCoordinator::none() const noexcept {
  Action action;
  if (token_)
    action.token = *token_;
  return action;
}

Action NativeActivationCoordinator::publish(Action::Kind kind,
                                            std::uint64_t epoch,
                                            std::uint64_t value,
                                            std::int64_t videoId,
                                            std::uint64_t captionId,
                                            Transport transport) noexcept {
  if (pending_action_)
    return *pending_action_;
  if (!token_)
    return none();
  Action action;
  action.kind = kind;
  action.token = *token_;
  action.serial = nextNonzero(next_action_serial_);
  action.epoch = epoch;
  action.value = value;
  action.videoId = videoId;
  action.captionId = captionId;
  action.transport = transport;
  pending_action_ = action;
  return action;
}

Action
NativeActivationCoordinator::surfaceError(FallbackReason reason) noexcept {
  fallback_reason_ = reason;
  native_burned_ = true;
  phase_ = Phase::Failed;
  terminal_after_stop_ = false;
  force_pause_purpose_ = ForcePausePurpose::None;
  restore_purpose_ = RestorePurpose::None;
  return publish(Action::Kind::SurfaceError, 0,
                 static_cast<std::uint64_t>(reason));
}

void NativeActivationCoordinator::resetAttemptState() noexcept {
  phase_ = Phase::Idle;
  token_.reset();
  source_key_ = 0;
  desired_ = {};
  native_prepared_ = false;
  mpv_ready_ = false;
  native_draw_ready_ = false;
  mpv_seek_converged_ = false;
  fallback_render_ready_ = false;
  fallback_video_selected_ = false;
  fallback_playback_restarted_ = false;
  native_burned_ = false;
  start_accepted_ = false;
  mpv_seek_action_complete_ = false;
  mpv_seek_action_issued_ = false;
  terminal_after_stop_ = false;
  terminal_pause_required_ = false;
  cancel_pending_ = false;
  native_request_issued_ = false;
  renderer_denied_ = false;
  fallback_transition_pending_ = false;
  fallback_renderer_invalidation_pending_ = false;
  eof_restore_pending_ = false;
  deferred_surface_error_.reset();
  caption_surface_error_ = false;
  clock_update_dirty_ = false;
  preparation_generation_ = 0;
  native_generation_ = 0;
  render_stamp_ = 0;
  retired_render_stamps_ = {};
  retired_render_stamp_count_ = 0;
  transport_epoch_ = 0;
  draw_baseline_ = 0;
  entry_ = -1;
  video_id_ = -1;
  initial_mpv_.reset();
  fallback_mpv_.reset();
  seek_.reset();
  pending_caption_id_.reset();
  pending_action_.reset();
  restore_purpose_ = RestorePurpose::None;
  force_pause_purpose_ = ForcePausePurpose::None;
  cancel_mode_ = CancelMode::Stop;
  fallback_reason_ = FallbackReason::NativeFailure;
}

std::optional<Token>
NativeActivationCoordinator::begin(std::uint64_t request,
                                   std::uint64_t sourceKey,
                                   Transport desired) noexcept {
  if (phase_ != Phase::Idle || token_ || request == 0 || sourceKey == 0 ||
      !validTransport(desired) || desired.position != 0.0) {
    return std::nullopt;
  }
  resetAttemptState();
  token_ = Token{request, nextNonzero(next_attempt_)};
  source_key_ = sourceKey;
  desired_ = desired;
  static_cast<void>(nextNonzero(transport_epoch_));
  phase_ = Phase::Preparing;
  force_pause_purpose_ = ForcePausePurpose::Startup;
  Transport paused = desired_;
  paused.paused = true;
  static_cast<void>(publish(Action::Kind::ForcePauseMpv, 0, 0, -1, 0, paused));
  return token_;
}

bool NativeActivationCoordinator::consumeExpectedRevocationGeneration(
    std::uint64_t retiredGeneration) noexcept {
  if (retiredGeneration == 0)
    return false;
  if (armed_revocation_generation_ &&
      *armed_revocation_generation_ == retiredGeneration) {
    armed_revocation_generation_.reset();
    return true;
  }
  for (std::uint8_t index = 0; index < ignored_retired_generation_count_;
       ++index) {
    if (ignored_retired_generations_[index] != retiredGeneration)
      continue;
    for (std::uint8_t move = index + 1;
         move < ignored_retired_generation_count_; ++move) {
      ignored_retired_generations_[move - 1] =
          ignored_retired_generations_[move];
    }
    --ignored_retired_generation_count_;
    ignored_retired_generations_[ignored_retired_generation_count_] = 0;
    return true;
  }
  return false;
}

void NativeActivationCoordinator::retainIgnoredRetiredGeneration(
    std::uint64_t generation) noexcept {
  if (generation == 0)
    return;
  for (std::uint8_t index = 0; index < ignored_retired_generation_count_;
       ++index) {
    if (ignored_retired_generations_[index] == generation)
      return;
  }
  if (ignored_retired_generation_count_ ==
      ignored_retired_generations_.size()) {
    ignored_retired_generations_[0] = ignored_retired_generations_[1];
    ignored_retired_generation_count_ = 1;
  }
  ignored_retired_generations_[ignored_retired_generation_count_++] =
      generation;
}

void NativeActivationCoordinator::armRevocationGeneration(
    std::uint64_t generation) noexcept {
  if (generation == 0)
    return;
  if (armed_revocation_generation_ &&
      *armed_revocation_generation_ != generation) {
    retainIgnoredRetiredGeneration(*armed_revocation_generation_);
  }
  armed_revocation_generation_ = generation;
}

Action NativeActivationCoordinator::maybeConvergePreparation() noexcept {
  if (phase_ == Phase::Preparing && native_prepared_ && mpv_ready_ &&
      !pending_action_) {
    phase_ = Phase::AwaitRelease;
  }
  return none();
}

Action
NativeActivationCoordinator::nativePrepared(Token token,
                                            std::uint64_t generation) noexcept {
  if (!matches(token) || phase_ != Phase::Preparing || generation == 0 ||
      !native_request_issued_)
    return none();
  if (native_prepared_ && preparation_generation_ != generation)
    return beginFallback(token, FallbackReason::Mismatch);
  native_prepared_ = true;
  preparation_generation_ = generation;
  return maybeConvergePreparation();
}

Action NativeActivationCoordinator::nativeUnsupported(Token token) noexcept {
  return beginFallback(token, FallbackReason::Unsupported);
}

Action NativeActivationCoordinator::nativeFailed(Token token) noexcept {
  return beginFallback(token, FallbackReason::NativeFailure);
}

Action NativeActivationCoordinator::mpvLoadFailed(Token token) noexcept {
  if (!matches(token) ||
      (!nativeOwnedPhase() && phase_ != Phase::FallbackStopping &&
       phase_ != Phase::FallbackAwaitRenderer &&
       phase_ != Phase::FallbackAwaitRestart &&
       phase_ != Phase::FallbackActive))
    return none();
  const bool may_be_running =
      phase_ == Phase::FallbackAwaitRestart ||
      phase_ == Phase::FallbackActive ||
      (pending_action_ &&
       pending_action_->kind == Action::Kind::RestoreTransport);
  return beginTerminalStop(FallbackReason::MpvFailure, may_be_running);
}

Action
NativeActivationCoordinator::mpvEndFileError(Token token,
                                             std::int64_t entry) noexcept {
  if (!matches(token) ||
      (!nativeOwnedPhase() && phase_ != Phase::FallbackStopping &&
       phase_ != Phase::FallbackAwaitRenderer &&
       phase_ != Phase::FallbackAwaitRestart &&
       phase_ != Phase::FallbackActive) ||
      entry < 0 || (entry_ >= 0 && entry != entry_))
    return none();
  if (entry_ < 0)
    entry_ = entry;
  return beginTerminalStop(FallbackReason::MpvFailure, true);
}

Action NativeActivationCoordinator::mpvReady(Token token,
                                             MpvReady ready) noexcept {
  if (!matches(token))
    return none();
  if (phase_ == Phase::Preparing || phase_ == Phase::AwaitRelease) {
    if (!validInitialMpv(ready))
      return beginFallback(token, FallbackReason::TrackContract);
    if (initial_mpv_ && !sameMpvIdentity(*initial_mpv_, ready))
      return beginFallback(token, FallbackReason::Mismatch);
    initial_mpv_ = ready;
    mpv_ready_ = true;
    entry_ = ready.entry;
    video_id_ = ready.videoId;
    return maybeConvergePreparation();
  }
  if (phase_ == Phase::FallbackStopping ||
      phase_ == Phase::FallbackAwaitRenderer ||
      phase_ == Phase::FallbackAwaitRestart) {
    if (terminal_after_stop_)
      return pending_action_.value_or(none());
    if (!validFallbackMpv(ready)) {
      deferred_surface_error_ = FallbackReason::TrackContract;
      if (pending_action_)
        return *pending_action_;
      return surfaceError(FallbackReason::TrackContract);
    }
    if (initial_mpv_ && !sameMpvIdentity(*initial_mpv_, ready)) {
      deferred_surface_error_ = FallbackReason::Mismatch;
      if (pending_action_)
        return *pending_action_;
      return surfaceError(FallbackReason::Mismatch);
    }
    if (fallback_mpv_ && !sameMpvIdentity(*fallback_mpv_, ready)) {
      deferred_surface_error_ = FallbackReason::Mismatch;
      if (pending_action_)
        return *pending_action_;
      return surfaceError(FallbackReason::Mismatch);
    }
    fallback_mpv_ = ready;
    mpv_ready_ = true;
    entry_ = ready.entry;
    video_id_ = ready.videoId;
    return maybeSelectFallbackVideo();
  }
  return none();
}

Action NativeActivationCoordinator::evaluateRelease(
    Token token, bool renderAllowed, bool renderBusy, bool lifecycleEmpty,
    std::uint64_t lifecycleGeneration) noexcept {
  if (!matches(token) || phase_ != Phase::AwaitRelease || pending_action_ ||
      !native_prepared_ || !mpv_ready_ || renderAllowed || renderBusy ||
      !lifecycleEmpty || lifecycleGeneration == 0 || native_burned_) {
    return none();
  }
  if (armed_revocation_generation_) {
    const std::uint64_t armed = *armed_revocation_generation_;
    if (lifecycleGeneration == armed) {
      armed_revocation_generation_.reset();
    } else if (lifecycleGeneration == nextRenderGeneration(armed)) {
      retainIgnoredRetiredGeneration(armed);
      armed_revocation_generation_.reset();
    } else {
      return beginFallback(token, FallbackReason::ContextFailure);
    }
  }
  phase_ = Phase::Starting;
  return publish(Action::Kind::StartNative, 0, preparation_generation_);
}

Action NativeActivationCoordinator::sampleNative(Token token,
                                                 NativeSample sample) noexcept {
  if (!matches(token))
    return none();
  if (sample.failed || sample.stopping) {
    if (nativeOwnedPhase())
      return beginFallback(token, FallbackReason::NativeFailure);
    return none();
  }
  if (phase_ == Phase::Starting && start_accepted_ && sample.active &&
      sample.generation == native_generation_ &&
      sample.acceptedGeneration == native_generation_ &&
      sample.lastRenderedGeneration == native_generation_ &&
      (sample.acceptedRenderedFrames > draw_baseline_ ||
       sample.attemptAcceptedRenderedFrames > 0)) {
    if (pending_action_)
      return *pending_action_;
    native_draw_ready_ = true;
    restore_purpose_ = RestorePurpose::Startup;
    return publish(Action::Kind::RestoreTransport, transport_epoch_, 0, -1, 0,
                   desired_);
  }
  if (phase_ == Phase::Seeking && seek_ &&
      exactDraw(sample, seek_->generation, seek_->drawBaseline)) {
    native_draw_ready_ = true;
    return maybeConvergeSeek();
  }
  return none();
}

Action NativeActivationCoordinator::setDesiredPause(Token token,
                                                    bool paused) noexcept {
  if (!matches(token))
    return none();
  if (phase_ == Phase::EofHeld && !paused)
    return none();
  desired_.paused = paused;
  static_cast<void>(nextNonzero(transport_epoch_));
  if (phase_ == Phase::Active)
    return publishClockUpdate();
  return none();
}

Action NativeActivationCoordinator::setDesiredRate(Token token,
                                                   double rate) noexcept {
  if (!matches(token) || !std::isfinite(rate) || rate <= 0.0)
    return none();
  desired_.rate = rate;
  static_cast<void>(nextNonzero(transport_epoch_));
  if (phase_ == Phase::Active)
    return publishClockUpdate();
  return none();
}

Action NativeActivationCoordinator::observeLiveTransport(
    Token token, std::uint64_t epoch, std::int64_t entry,
    Transport live) noexcept {
  if (!matches(token) || epoch == 0 || epoch != transport_epoch_ ||
      entry != entry_ || !validTransport(live) ||
      (phase_ != Phase::Active && phase_ != Phase::EofHeld &&
       phase_ != Phase::FallbackActive)) {
    return none();
  }
  desired_.position = live.position;
  if (phase_ == Phase::EofHeld)
    desired_.paused = true;
  // time-pos may arrive at playback cadence. It updates only the cached
  // fallback/UI anchor; native clock mutations are reserved for discrete
  // user pause/rate changes or ordered restore actions.
  return none();
}

Action NativeActivationCoordinator::publishClockUpdate() noexcept {
  if (pending_action_) {
    if (pending_action_->kind == Action::Kind::UpdateNativeClock)
      clock_update_dirty_ = true;
    return *pending_action_;
  }
  clock_update_dirty_ = false;
  return publish(Action::Kind::UpdateNativeClock, transport_epoch_, 0, -1, 0,
                 desired_);
}

Action NativeActivationCoordinator::requestSeek(Token token,
                                                double target) noexcept {
  if (!matches(token) || !std::isfinite(target) || target < 0.0)
    return matches(token) ? beginFallback(token, FallbackReason::SeekFailure)
                          : none();
  if (phase_ == Phase::Preparing || phase_ == Phase::AwaitRelease ||
      phase_ == Phase::Starting) {
    return beginFallback(token, FallbackReason::SeekFailure);
  }
  if (phase_ != Phase::Active && phase_ != Phase::EofHeld &&
      phase_ != Phase::Seeking) {
    return none();
  }
  desired_.position = target;
  phase_ = Phase::Seeking;
  transport_epoch_ = nextNonzero(transport_epoch_);
  seek_ = SeekTicket{transport_epoch_, 0, 0, target};
  eof_restore_pending_ = false;
  native_draw_ready_ = false;
  mpv_seek_converged_ = false;
  mpv_seek_action_complete_ = false;
  mpv_seek_action_issued_ = false;
  clock_update_dirty_ = false;
  // A newer exact seek explicitly supersedes any previous seek action or
  // coalesced clock update. Its serial/epoch make old completions inert.
  force_pause_purpose_ = ForcePausePurpose::Seek;
  if (pending_action_)
    return *pending_action_;
  Transport paused = desired_;
  paused.paused = true;
  return publish(Action::Kind::ForcePauseMpv, transport_epoch_, 0, -1, 0,
                 paused);
}

Action NativeActivationCoordinator::maybeConvergeSeek() noexcept {
  if (phase_ == Phase::Seeking && native_draw_ready_ && mpv_seek_converged_ &&
      mpv_seek_action_complete_ && !pending_action_) {
    restore_purpose_ = RestorePurpose::Seek;
    return publish(Action::Kind::RestoreTransport, transport_epoch_,
                   seek_->epoch, -1, 0, desired_);
  }
  return pending_action_.value_or(none());
}

Action
NativeActivationCoordinator::playbackRestart(Token token, std::uint64_t epoch,
                                             std::int64_t entry,
                                             double livePosition) noexcept {
  if (!matches(token) || phase_ != Phase::Seeking || !seek_ ||
      !mpv_seek_action_issued_ || epoch == 0 || epoch != seek_->epoch ||
      entry != entry_ || !std::isfinite(livePosition) ||
      std::abs(livePosition - seek_->target) >
          kSeekConvergenceToleranceSeconds) {
    return none();
  }
  mpv_seek_converged_ = true;
  return maybeConvergeSeek();
}

Action
NativeActivationCoordinator::requestCaption(Token token,
                                            std::uint64_t captionId) noexcept {
  if (!matches(token) || captionId == 0)
    return none();
  pending_caption_id_ = captionId;
  if (phase_ == Phase::FallbackActive && !pending_action_) {
    return publish(Action::Kind::AttachCaption, 0, 0, -1, captionId);
  }
  if (phase_ == Phase::FallbackStopping ||
      phase_ == Phase::FallbackAwaitRenderer ||
      phase_ == Phase::FallbackAwaitRestart) {
    return pending_action_.value_or(none());
  }
  return beginFallback(token, FallbackReason::Caption);
}

Action NativeActivationCoordinator::eof(Token token, std::int64_t entry,
                                        double finalPosition) noexcept {
  if (!matches(token) || phase_ != Phase::Active || entry != entry_ ||
      !std::isfinite(finalPosition) || finalPosition < 0.0) {
    return none();
  }
  desired_.position = finalPosition;
  desired_.paused = true;
  static_cast<void>(nextNonzero(transport_epoch_));
  phase_ = Phase::EofHeld;
  restore_purpose_ = RestorePurpose::Eof;
  // EOF retention supersedes a clock update but never flushes the native
  // frame. The restore action merely reanchors paused transport.
  if (pending_action_) {
    eof_restore_pending_ = true;
    return *pending_action_;
  }
  return publish(Action::Kind::RestoreTransport, transport_epoch_, 0, -1, 0,
                 desired_);
}

Action
NativeActivationCoordinator::beginFallback(Token token,
                                           FallbackReason reason) noexcept {
  if (!matches(token))
    return none();
  if (phase_ == Phase::FallbackStopping ||
      phase_ == Phase::FallbackAwaitRenderer ||
      phase_ == Phase::FallbackAwaitRestart ||
      phase_ == Phase::FallbackActive || phase_ == Phase::Failed) {
    return pending_action_.value_or(none());
  }
  fallback_reason_ = reason;
  native_burned_ = true;
  terminal_after_stop_ = false;
  phase_ = Phase::FallbackStopping;
  seek_.reset();
  eof_restore_pending_ = false;
  native_draw_ready_ = false;
  mpv_seek_converged_ = false;
  mpv_seek_action_complete_ = false;
  mpv_seek_action_issued_ = false;
  fallback_transition_pending_ = pending_action_.has_value();
  if (pending_action_)
    return *pending_action_;
  force_pause_purpose_ = ForcePausePurpose::Fallback;
  Transport paused = desired_;
  paused.paused = true;
  return publish(Action::Kind::ForcePauseMpv, 0, 0, -1, 0, paused);
}

Action
NativeActivationCoordinator::beginTerminalStop(FallbackReason reason,
                                               bool forcePause) noexcept {
  fallback_reason_ = reason;
  native_burned_ = true;
  terminal_after_stop_ = true;
  terminal_pause_required_ = forcePause;
  phase_ = Phase::FallbackStopping;
  seek_.reset();
  native_draw_ready_ = false;
  mpv_seek_converged_ = false;
  mpv_seek_action_complete_ = false;
  fallback_transition_pending_ = pending_action_.has_value();
  if (pending_action_)
    return *pending_action_;
  if (forcePause) {
    force_pause_purpose_ = ForcePausePurpose::Terminal;
    Transport paused = desired_;
    paused.paused = true;
    return publish(Action::Kind::ForcePauseMpv, 0, 0, -1, 0, paused);
  }
  if (native_request_issued_)
    return publish(Action::Kind::StopNative);
  if (renderer_denied_)
    return publish(Action::Kind::AllowMpvRenderer);
  return surfaceError(reason);
}

Action NativeActivationCoordinator::maybeSelectFallbackVideo() noexcept {
  if (phase_ == Phase::FallbackAwaitRenderer && fallback_render_ready_ &&
      fallback_mpv_ && !pending_action_) {
    phase_ = Phase::FallbackAwaitRestart;
    return publish(Action::Kind::SelectMpvVideo, 0, render_stamp_, video_id_);
  }
  return pending_action_.value_or(none());
}

Action NativeActivationCoordinator::maybeConvergeFallbackRestart() noexcept {
  if (phase_ == Phase::FallbackAwaitRestart && fallback_video_selected_ &&
      fallback_playback_restarted_ && !pending_action_) {
    restore_purpose_ = RestorePurpose::Fallback;
    return publish(Action::Kind::RestoreTransport, transport_epoch_,
                   render_stamp_, -1, 0, desired_);
  }
  return pending_action_.value_or(none());
}

Action NativeActivationCoordinator::fallbackRenderReady(
    Token token, std::uint64_t renderStamp) noexcept {
  if (!matches(token) || phase_ != Phase::FallbackAwaitRenderer ||
      renderStamp == 0)
    return none();
  for (std::uint8_t index = 0; index < retired_render_stamp_count_; ++index) {
    if (retired_render_stamps_[index] == renderStamp)
      return none();
  }
  fallback_render_ready_ = true;
  render_stamp_ = renderStamp;
  return maybeSelectFallbackVideo();
}

Action NativeActivationCoordinator::fallbackRendererInvalidated(
    Token token, std::uint64_t retiredStamp) noexcept {
  if (!matches(token) || retiredStamp == 0 || render_stamp_ == 0 ||
      retiredStamp != render_stamp_ ||
      (phase_ != Phase::FallbackAwaitRenderer &&
       phase_ != Phase::FallbackAwaitRestart)) {
    return none();
  }
  fallback_render_ready_ = false;
  fallback_video_selected_ = false;
  fallback_playback_restarted_ = false;
  if (retired_render_stamp_count_ == retired_render_stamps_.size()) {
    retired_render_stamps_[0] = retired_render_stamps_[1];
    retired_render_stamp_count_ = 1;
  }
  retired_render_stamps_[retired_render_stamp_count_++] = retiredStamp;
  render_stamp_ = 0;
  phase_ = Phase::FallbackAwaitRenderer;
  if (pending_action_) {
    fallback_renderer_invalidation_pending_ = true;
    return *pending_action_;
  }
  return none();
}

Action NativeActivationCoordinator::fallbackPlaybackRestart(
    Token token, std::uint64_t renderStamp, std::int64_t entry,
    double livePosition) noexcept {
  if (!matches(token) || phase_ != Phase::FallbackAwaitRestart ||
      renderStamp == 0 || renderStamp != render_stamp_ || entry != entry_ ||
      !fallback_mpv_ || fallback_mpv_->sourceKey != source_key_ ||
      fallback_mpv_->entry != entry || fallback_mpv_->videoId != video_id_ ||
      !std::isfinite(livePosition) || livePosition < 0.0 ||
      std::abs(livePosition - desired_.position) >
          kSeekConvergenceToleranceSeconds) {
    return none();
  }
  fallback_playback_restarted_ = true;
  return maybeConvergeFallbackRestart();
}

std::optional<Action> NativeActivationCoordinator::nextAction() const noexcept {
  return pending_action_;
}

Action NativeActivationCoordinator::failCurrentAction() noexcept {
  if (nativeOwnedPhase())
    return beginFallback(*token_, FallbackReason::NativeFailure);
  return surfaceError(fallback_reason_);
}

Action NativeActivationCoordinator::continueDeferredTransition(
    const Action &completed) noexcept {
  fallback_transition_pending_ = false;
  if (terminal_after_stop_) {
    if (terminal_pause_required_ &&
        completed.kind != Action::Kind::ForcePauseMpv) {
      force_pause_purpose_ = ForcePausePurpose::Terminal;
      Transport paused = desired_;
      paused.paused = true;
      return publish(Action::Kind::ForcePauseMpv, 0, 0, -1, 0, paused);
    }
    if (!native_request_issued_) {
      if (renderer_denied_)
        return publish(Action::Kind::AllowMpvRenderer);
      return surfaceError(fallback_reason_);
    }
    return publish(Action::Kind::StopNative);
  }

  if (completed.kind == Action::Kind::ForcePauseMpv)
    return publish(Action::Kind::StopNative);
  force_pause_purpose_ = ForcePausePurpose::Fallback;
  Transport paused = desired_;
  paused.paused = true;
  return publish(Action::Kind::ForcePauseMpv, 0, 0, -1, 0, paused);
}

Action NativeActivationCoordinator::finishStop(
    const ActionCompletion &completion) noexcept {
  if (!completion.succeeded || completion.invalidationGeneration == 0) {
    native_burned_ = true;
    return surfaceError(FallbackReason::ContextFailure);
  }
  native_request_issued_ = false;

  if (renderer_denied_ || cancel_mode_ == CancelMode::SupersededByMpvOpen ||
      (!cancel_pending_ && !terminal_after_stop_)) {
    return publish(Action::Kind::AllowMpvRenderer, 0,
                   completion.invalidationGeneration);
  }
  if (terminal_after_stop_)
    return surfaceError(fallback_reason_);
  if (cancel_pending_) {
    if (deferred_surface_error_)
      return surfaceError(*deferred_surface_error_);
    resetAttemptState();
    return none();
  }
  return surfaceError(FallbackReason::Mismatch);
}

Action NativeActivationCoordinator::finishAllow() noexcept {
  renderer_denied_ = false;
  if (deferred_surface_error_) {
    const FallbackReason reason = *deferred_surface_error_;
    deferred_surface_error_.reset();
    return surfaceError(reason);
  }
  if (cancel_pending_) {
    resetAttemptState();
    return none();
  }
  if (terminal_after_stop_)
    return surfaceError(fallback_reason_);

  phase_ = Phase::FallbackAwaitRenderer;
  fallback_render_ready_ = false;
  fallback_video_selected_ = false;
  fallback_playback_restarted_ = false;
  render_stamp_ = 0;
  // FILE_LOADED/track state captured before renderer restoration is only an
  // identity expectation. Require a fresh, authoritative paused mpvReady
  // after Allow before selecting video.
  fallback_mpv_.reset();
  mpv_ready_ = false;
  return none();
}

Action NativeActivationCoordinator::completeAction(
    std::uint64_t serial, ActionCompletion completion) noexcept {
  if (!pending_action_ || serial == 0 || pending_action_->serial != serial)
    return pending_action_.value_or(none());
  const Action completed = *pending_action_;
  pending_action_.reset();

  if (completed.kind == Action::Kind::RevokeMpvRenderer &&
      completion.succeeded) {
    renderer_denied_ = true;
    if (completion.preRevokeGeneration == 0) {
      completion.succeeded = false;
      deferred_surface_error_ = FallbackReason::ContextFailure;
    } else {
      armRevocationGeneration(completion.preRevokeGeneration);
    }
  }
  if (completed.kind == Action::Kind::ForcePauseMpv && completion.succeeded &&
      (force_pause_purpose_ == ForcePausePurpose::Fallback ||
       force_pause_purpose_ == ForcePausePurpose::FallbackRendererLoss)) {
    if (!completion.liveTransport ||
        !validTransport(*completion.liveTransport) ||
        !completion.liveTransport->paused) {
      completion.succeeded = false;
    } else {
      desired_.position = completion.liveTransport->position;
    }
  }

  if (completed.kind == Action::Kind::StopNative)
    return finishStop(completion);
  if (completed.kind == Action::Kind::AllowMpvRenderer) {
    if (!completion.succeeded)
      return surfaceError(FallbackReason::ContextFailure);
    return finishAllow();
  }
  if (completed.kind == Action::Kind::SurfaceError) {
    const bool canceled = cancel_pending_;
    cancel_pending_ = false;
    if (caption_surface_error_) {
      caption_surface_error_ = false;
      if (canceled) {
        resetAttemptState();
      } else {
        phase_ = Phase::FallbackActive;
      }
    } else if (canceled && !native_request_issued_ && !renderer_denied_) {
      // A canceled error that preceded every physical side effect has no
      // cleanup obligation. Settle it to Idle; cleanup failures retain their
      // ownership flags and remain fail-closed in Failed.
      resetAttemptState();
    } else {
      phase_ = Phase::Failed;
    }
    return none();
  }

  // Stop/Open burns all event callbacks immediately, but the exact issued
  // mutation still owns its acknowledgement. Once it returns, retire native
  // state conservatively rather than guessing whether the mutation ran.
  if (cancel_pending_) {
    if (native_request_issued_)
      return publish(Action::Kind::StopNative);
    if (renderer_denied_)
      return publish(Action::Kind::AllowMpvRenderer);
    resetAttemptState();
    return none();
  }

  if (completed.kind == Action::Kind::LoadMpvAudioOnly &&
      !completion.succeeded) {
    fallback_transition_pending_ = false;
    return beginTerminalStop(FallbackReason::MpvFailure, false);
  }

  // A fallback/error arriving behind an issued action cannot overwrite it.
  // Its exact acknowledgement is the serialization point for cleanup.
  if (fallback_transition_pending_)
    return continueDeferredTransition(completed);

  // A renderer can retire while Select/Restore is in flight. That completion
  // belongs to the retired stamp; return to convergence and wait for a fresh
  // Ready rather than admitting its stale result.
  if (fallback_renderer_invalidation_pending_ &&
      (completed.kind == Action::Kind::SelectMpvVideo ||
       completed.kind == Action::Kind::RestoreTransport)) {
    fallback_renderer_invalidation_pending_ = false;
    phase_ = Phase::FallbackAwaitRenderer;
    if (deferred_surface_error_) {
      const FallbackReason reason = *deferred_surface_error_;
      deferred_surface_error_.reset();
      return surfaceError(reason);
    }
    if (completed.kind == Action::Kind::RestoreTransport) {
      force_pause_purpose_ = ForcePausePurpose::FallbackRendererLoss;
      Transport paused = desired_;
      paused.paused = true;
      return publish(Action::Kind::ForcePauseMpv, 0, 0, -1, 0, paused);
    }
    return maybeSelectFallbackVideo();
  }

  if (deferred_surface_error_ && (phase_ == Phase::FallbackAwaitRenderer ||
                                  phase_ == Phase::FallbackAwaitRestart ||
                                  phase_ == Phase::FallbackActive)) {
    const FallbackReason reason = *deferred_surface_error_;
    deferred_surface_error_.reset();
    return surfaceError(reason);
  }

  if (eof_restore_pending_) {
    eof_restore_pending_ = false;
    if (!completion.succeeded)
      return beginFallback(*token_, FallbackReason::NativeFailure);
    return publish(Action::Kind::RestoreTransport, transport_epoch_, 0, -1, 0,
                   desired_);
  }

  // Preview seeks coalesce without dropping ownership of an issued action.
  // A successful old mutation leaves transport paused; continue directly
  // with the newest native target. An old Restore/clock update must pause
  // again first because it may have resumed playback.
  const bool stale_seek_mutation =
      phase_ == Phase::Seeking && seek_ && completed.epoch != 0 &&
      completed.epoch != seek_->epoch &&
      (completed.kind == Action::Kind::ForcePauseMpv ||
       completed.kind == Action::Kind::SeekNative ||
       completed.kind == Action::Kind::SeekMpvExact);
  const bool superseded_seek_restore =
      phase_ == Phase::Seeking && seek_ &&
      completed.kind == Action::Kind::RestoreTransport &&
      completed.value != seek_->epoch;
  const bool pre_seek_clock_update =
      phase_ == Phase::Seeking && seek_ &&
      completed.kind == Action::Kind::UpdateNativeClock;
  if (stale_seek_mutation || superseded_seek_restore || pre_seek_clock_update) {
    if (!completion.succeeded)
      return beginFallback(*token_, FallbackReason::SeekFailure);
    if (completed.kind == Action::Kind::RestoreTransport ||
        completed.kind == Action::Kind::UpdateNativeClock) {
      force_pause_purpose_ = ForcePausePurpose::Seek;
      Transport paused = desired_;
      paused.paused = true;
      return publish(Action::Kind::ForcePauseMpv, seek_->epoch, 0, -1, 0,
                     paused);
    }
    return publish(Action::Kind::SeekNative, seek_->epoch, 0, -1, 0, desired_);
  }

  if (!completion.succeeded) {
    if (completed.kind == Action::Kind::AttachCaption) {
      pending_caption_id_.reset();
      phase_ = Phase::FallbackActive;
      fallback_reason_ = FallbackReason::Caption;
      caption_surface_error_ = true;
      return publish(Action::Kind::SurfaceError, 0,
                     static_cast<std::uint64_t>(FallbackReason::Caption));
    }
    if (completed.kind == Action::Kind::ForcePauseMpv) {
      fallback_reason_ = force_pause_purpose_ == ForcePausePurpose::Seek
                             ? FallbackReason::SeekFailure
                             : FallbackReason::NativeFailure;
      native_burned_ = true;
      phase_ = Phase::FallbackStopping;
      terminal_after_stop_ =
          force_pause_purpose_ == ForcePausePurpose::Terminal;
      if (native_request_issued_)
        return publish(Action::Kind::StopNative);
      if (renderer_denied_)
        return publish(Action::Kind::AllowMpvRenderer);
      return surfaceError(fallback_reason_);
    }
    if (completed.kind == Action::Kind::UpdateNativeClock)
      return beginFallback(*token_, FallbackReason::NativeFailure);
    if (nativeOwnedPhase())
      return beginFallback(*token_, FallbackReason::NativeFailure);
    return surfaceError(fallback_reason_);
  }

  switch (completed.kind) {
  case Action::Kind::ForcePauseMpv:
    if (force_pause_purpose_ == ForcePausePurpose::Startup) {
      return publish(Action::Kind::RevokeMpvRenderer);
    }
    if (force_pause_purpose_ == ForcePausePurpose::Seek) {
      if (!seek_)
        return beginFallback(*token_, FallbackReason::SeekFailure);
      return publish(Action::Kind::SeekNative, seek_->epoch, 0, -1, 0,
                     desired_);
    }
    if (force_pause_purpose_ == ForcePausePurpose::Fallback ||
        force_pause_purpose_ == ForcePausePurpose::Terminal) {
      if (native_request_issued_)
        return publish(Action::Kind::StopNative);
      if (renderer_denied_)
        return publish(Action::Kind::AllowMpvRenderer);
      return terminal_after_stop_ ? surfaceError(fallback_reason_)
                                  : finishAllow();
    }
    if (force_pause_purpose_ == ForcePausePurpose::FallbackRendererLoss) {
      phase_ = Phase::FallbackAwaitRenderer;
      return maybeSelectFallbackVideo();
    }
    return surfaceError(FallbackReason::Mismatch);

  case Action::Kind::RevokeMpvRenderer:
    return publish(Action::Kind::LoadMpvAudioOnly);

  case Action::Kind::LoadMpvAudioOnly: {
    const Action prepare = publish(Action::Kind::PrepareNative);
    if (prepare.kind == Action::Kind::PrepareNative)
      native_request_issued_ = true;
    return prepare;
  }

  case Action::Kind::PrepareNative:
    return maybeConvergePreparation();

  case Action::Kind::StartNative:
    if (completion.generation == 0)
      return beginFallback(*token_, FallbackReason::NativeFailure);
    start_accepted_ = true;
    native_generation_ = completion.generation;
    draw_baseline_ = completion.drawBaseline;
    phase_ = Phase::Starting;
    return none();

  case Action::Kind::SeekNative:
    if (phase_ != Phase::Seeking || !seek_ || completed.epoch != seek_->epoch ||
        completion.generation == 0) {
      return beginFallback(*token_, FallbackReason::SeekFailure);
    }
    seek_->generation = completion.generation;
    seek_->drawBaseline = completion.drawBaseline;
    native_generation_ = completion.generation;
    draw_baseline_ = completion.drawBaseline;
    mpv_seek_action_issued_ = true;
    return publish(Action::Kind::SeekMpvExact, seek_->epoch, 0, -1, 0,
                   desired_);

  case Action::Kind::SeekMpvExact:
    if (phase_ != Phase::Seeking || !seek_ || completed.epoch != seek_->epoch)
      return none();
    mpv_seek_action_complete_ = true;
    return maybeConvergeSeek();

  case Action::Kind::StopNative:
  case Action::Kind::AllowMpvRenderer:
    return surfaceError(FallbackReason::Mismatch);

  case Action::Kind::SelectMpvVideo:
    fallback_video_selected_ = true;
    return maybeConvergeFallbackRestart();

  case Action::Kind::RestoreTransport:
    if (completed.epoch != transport_epoch_ ||
        completed.transport != desired_) {
      return publish(Action::Kind::RestoreTransport, transport_epoch_,
                     completed.value, -1, 0, desired_);
    }
    switch (restore_purpose_) {
    case RestorePurpose::Startup:
      phase_ = Phase::Active;
      break;
    case RestorePurpose::Seek:
      phase_ = Phase::Active;
      seek_.reset();
      mpv_seek_action_issued_ = false;
      mpv_seek_action_complete_ = false;
      break;
    case RestorePurpose::Eof:
      phase_ = Phase::EofHeld;
      break;
    case RestorePurpose::Fallback:
      if (pending_caption_id_) {
        restore_purpose_ = RestorePurpose::None;
        return publish(Action::Kind::AttachCaption, 0, 0, -1,
                       *pending_caption_id_);
      }
      phase_ = Phase::FallbackActive;
      break;
    case RestorePurpose::None:
      return surfaceError(FallbackReason::Mismatch);
    }
    restore_purpose_ = RestorePurpose::None;
    return none();

  case Action::Kind::UpdateNativeClock:
    if (clock_update_dirty_ || completed.epoch != transport_epoch_ ||
        completed.transport != desired_) {
      clock_update_dirty_ = false;
      return publish(Action::Kind::UpdateNativeClock, transport_epoch_, 0, -1,
                     0, desired_);
    }
    clock_update_dirty_ = false;
    return none();

  case Action::Kind::AttachCaption:
    if (pending_caption_id_ && *pending_caption_id_ != completed.captionId) {
      return publish(Action::Kind::AttachCaption, 0, 0, -1,
                     *pending_caption_id_);
    }
    pending_caption_id_.reset();
    phase_ = Phase::FallbackActive;
    return none();

  case Action::Kind::SurfaceError:
    return surfaceError(FallbackReason::Mismatch);

  case Action::Kind::None:
    return none();
  }
  return none();
}

Action
NativeActivationCoordinator::cancelForStopOrOpen(CancelMode mode) noexcept {
  if (!token_)
    return none();
  cancel_pending_ = true;
  cancel_mode_ = mode;
  native_burned_ = true;
  seek_.reset();
  eof_restore_pending_ = false;
  pending_caption_id_.reset();
  native_draw_ready_ = false;
  mpv_seek_converged_ = false;
  phase_ = Phase::FallbackStopping;
  if (pending_action_)
    return *pending_action_;
  if (native_request_issued_)
    return publish(Action::Kind::StopNative);
  if (renderer_denied_)
    return publish(Action::Kind::AllowMpvRenderer);
  resetAttemptState();
  return none();
}

Snapshot NativeActivationCoordinator::snapshot() const noexcept {
  Snapshot result;
  result.phase = phase_;
  result.token = token_;
  result.sourceKey = source_key_;
  result.armedRevocationGeneration = armed_revocation_generation_;
  result.ignoredRetiredGenerations = ignored_retired_generations_;
  result.ignoredRetiredGenerationCount = ignored_retired_generation_count_;
  result.desired = desired_;
  result.nativePrepared = native_prepared_;
  result.mpvReady = mpv_ready_;
  result.nativeDrawReady = native_draw_ready_;
  result.mpvSeekConverged = mpv_seek_converged_;
  result.fallbackRenderReady = fallback_render_ready_;
  result.fallbackVideoSelected = fallback_video_selected_;
  result.fallbackPlaybackRestarted = fallback_playback_restarted_;
  result.nativeBurned = native_burned_;
  result.terminalAfterStop = terminal_after_stop_;
  result.cancelPending = cancel_pending_;
  result.nativeRequestIssued = native_request_issued_;
  result.rendererDenied = renderer_denied_;
  result.fallbackRendererInvalidationPending =
      fallback_renderer_invalidation_pending_;
  result.eofRestorePending = eof_restore_pending_;
  result.preparationGeneration = preparation_generation_;
  result.nativeGeneration = native_generation_;
  result.renderStamp = render_stamp_;
  result.transportEpoch = transport_epoch_;
  result.drawBaseline = draw_baseline_;
  result.entry = entry_;
  result.videoId = video_id_;
  result.seek = seek_;
  result.pendingCaptionId = pending_caption_id_;
  result.pendingAction = pending_action_;
  result.fallbackReason = fallback_reason_;
  return result;
}

} // namespace wam::native_activation
