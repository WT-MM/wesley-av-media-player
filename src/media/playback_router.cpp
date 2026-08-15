#include "media/playback_router.hpp"

#include <limits>

namespace wam::media::playback_router {
namespace {

constexpr Transition ignored() noexcept { return {Status::Ignored, {}}; }
constexpr Transition invalid() noexcept { return {Status::Invalid, {}}; }
constexpr Transition exhausted() noexcept { return {Status::Exhausted, {}}; }

constexpr Transition applied(Action action) noexcept {
  return {Status::Applied, action};
}

constexpr Transition applied() noexcept { return {Status::Applied, {}}; }

constexpr Action nativePrepareAction(native::Prepare command) noexcept {
  Action action;
  action.kind = ActionKind::NativePrepare;
  action.prepare = command;
  return action;
}

constexpr Action nativeStartAction(native::Start command) noexcept {
  Action action;
  action.kind = ActionKind::NativeStart;
  action.start = command;
  return action;
}

constexpr Action nativeRunAction(native::SetRunState command) noexcept {
  Action action;
  action.kind = ActionKind::NativeSetRunState;
  action.runState = command;
  return action;
}

constexpr Action nativePreviewAction(native::PreviewFrame command) noexcept {
  Action action;
  action.kind = ActionKind::NativePreviewFrame;
  action.previewFrame = command;
  return action;
}

constexpr Action nativeCommitSeekAction(
    native::CommitSeek command) noexcept {
  Action action;
  action.kind = ActionKind::NativeCommitSeek;
  action.commitSeek = command;
  return action;
}

constexpr Action nativeStopAction(native::Stop command) noexcept {
  Action action;
  action.kind = ActionKind::NativeStop;
  action.stop = command;
  return action;
}

constexpr Action fallbackAction(ActionKind kind, native::Stamp stamp,
                                native::SourceKey source,
                                bool paused) noexcept {
  Action action;
  action.kind = kind;
  action.fallback = {stamp, source, paused};
  return action;
}

constexpr bool validFallbackStamp(native::Stamp stamp) noexcept {
  return native::validLive(stamp);
}

} // namespace

bool PlaybackRouter::acceptTick(Tick now) noexcept {
  if (now.value < lastTick_.value) {
    return false;
  }
  lastTick_ = now;
  return true;
}

bool PlaybackRouter::reserveAttempt(native::AttemptId &attempt) noexcept {
  if (!native::valid(limits_.maximumAttempt) ||
      attemptHighWater_.value >= limits_.maximumAttempt.value) {
    return false;
  }
  ++attemptHighWater_.value;
  attempt = attemptHighWater_;
  return true;
}

bool PlaybackRouter::reserveLiveSerial(native::Serial &serial) noexcept {
  if (!native::validLive(limits_.maximumLiveSerial) ||
      serial_.value >= limits_.maximumLiveSerial.value) {
    return false;
  }
  serial_.value += 1;
  serial = serial_;
  return true;
}

bool PlaybackRouter::reserveLiveGeneration(
    native::Generation &generation,
    native::GenerationHighWater &previousHighWater) noexcept {
  previousHighWater = generationHighWater_;
  if (!native::validLive(limits_.maximumLiveGeneration) ||
      generationHighWater_.value >= limits_.maximumLiveGeneration.value ||
      !native::canReserveLiveGenerationAfter(generationHighWater_)) {
    return false;
  }
  ++generationHighWater_.value;
  generation = native::Generation{generationHighWater_.value};
  return true;
}

bool PlaybackRouter::reserveStopGeneration(
    native::Generation &generation) noexcept {
  if (!native::canReserveStopInvalidationAfter(generationHighWater_)) {
    return false;
  }
  ++generationHighWater_.value;
  generation = native::Generation{generationHighWater_.value};
  return true;
}

Tick PlaybackRouter::deadline(Tick now, std::uint64_t duration) const noexcept {
  const auto maximum = std::numeric_limits<std::uint64_t>::max();
  if (duration > maximum - now.value) {
    return {maximum};
  }
  return {now.value + duration};
}

bool PlaybackRouter::deadlineExpired(Tick now) const noexcept {
  return deadlineArmed_ && now.value >= deadline_.value;
}

void PlaybackRouter::clearCurrent() noexcept {
  state_ = State::Idle;
  attempt_ = {};
  serial_ = {};
  sourceKey_ = {};
  generation_ = {};
  prepare_ = {};
  prepareOutcome_.reset();
  start_ = {};
  latestPreview_ = {};
  commitSeek_ = {};
  commitDrawBaseline_ = 0;
  stop_ = {};
  fallbackReservationExhausted_ = false;
  initialPositionSeconds_ = 0.0;
  intendedPaused_ = true;
  deadline_ = {};
  deadlineArmed_ = false;
}

Transition PlaybackRouter::beginFallback(PendingOpen pending) noexcept {
  attempt_ = pending.attempt;
  serial_ = {};
  sourceKey_ = pending.request.sourceKey;
  generation_ = {};
  initialPositionSeconds_ = pending.request.initialPositionSeconds;
  intendedPaused_ = pending.request.paused;
  native::Serial serial;
  if (!reserveLiveSerial(serial)) {
    clearCurrent();
    return exhausted();
  }
  state_ = State::FallbackCreating;
  deadlineArmed_ = false;
  return applied(fallbackAction(ActionKind::CreateFallback, {attempt_, serial},
                                sourceKey_, intendedPaused_));
}

Transition PlaybackRouter::beginOpen(PendingOpen pending, Tick now) noexcept {
  if (pending.request.route == Route::FallbackOnly) {
    return beginFallback(pending);
  }

  native::Generation reserved;
  native::GenerationHighWater previousHighWater;
  if (!reserveLiveGeneration(reserved, previousHighWater)) {
    // No native work was admitted, so fallback creation is safe immediately.
    return beginFallback(pending);
  }

  attempt_ = pending.attempt;
  serial_ = {};
  sourceKey_ = pending.request.sourceKey;
  generation_ = reserved;
  initialPositionSeconds_ = pending.request.initialPositionSeconds;
  intendedPaused_ = pending.request.paused;

  native::Serial serial;
  if (!reserveLiveSerial(serial)) {
    clearCurrent();
    return exhausted();
  }
  prepare_ = {
      {attempt_, serial}, sourceKey_, reserved, initialPositionSeconds_};
  prepareOutcome_.emplace(prepare_, previousHighWater);
  if (!native::valid(*prepareOutcome_)) {
    clearCurrent();
    return invalid();
  }
  state_ = State::NativePreparing;
  deadlineArmed_ = timeouts_.prepareTicks != 0;
  deadline_ = deadline(now, timeouts_.prepareTicks);
  return applied(nativePrepareAction(prepare_));
}

Transition PlaybackRouter::open(const OpenRequest &request, Tick now) noexcept {
  if (!acceptTick(now) || !native::valid(request.sourceKey) ||
      !native::validPosition(request.initialPositionSeconds)) {
    return invalid();
  }

  native::AttemptId nextAttempt;
  if (!reserveAttempt(nextAttempt)) {
    return exhausted();
  }
  PendingOpen incoming{request, nextAttempt};

  if (state_ == State::Idle) {
    return beginOpen(incoming, now);
  }

  pending_ = incoming;
  switch (state_) {
  case State::NativePreparing:
  case State::NativeStarting:
  case State::NativeActive:
  case State::NativeSeeking:
  case State::NativeEnded:
    return beginNativeStop(false, now);
  case State::FallbackCreating:
  case State::FallbackOpening:
  case State::FallbackActive:
    return beginFallbackStop(now);
  case State::NativeStopping:
  case State::NativeStopFailed:
  case State::FallbackStopping:
    return applied();
  case State::Idle:
    break;
  }
  return invalid();
}

Transition PlaybackRouter::stop(Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  pending_.reset();
  fallbackReservationExhausted_ = false;
  switch (state_) {
  case State::Idle:
    return applied();
  case State::NativePreparing:
  case State::NativeStarting:
  case State::NativeActive:
  case State::NativeSeeking:
  case State::NativeEnded:
    return beginNativeStop(false, now);
  case State::FallbackCreating:
  case State::FallbackOpening:
  case State::FallbackActive:
    return beginFallbackStop(now);
  case State::NativeStopping:
  case State::NativeStopFailed:
  case State::FallbackStopping:
    return applied();
  }
  return invalid();
}

Transition PlaybackRouter::cancel(Tick now) noexcept { return stop(now); }

Transition PlaybackRouter::abandonNativeAfterSynchronousRetirement(
    Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  switch (state_) {
  case State::NativePreparing:
  case State::NativeStarting:
  case State::NativeActive:
  case State::NativeSeeking:
  case State::NativeEnded:
  case State::NativeStopping:
  case State::NativeStopFailed:
    pending_.reset();
    clearCurrent();
    return applied();
  case State::Idle:
    return applied();
  case State::FallbackCreating:
  case State::FallbackOpening:
  case State::FallbackActive:
  case State::FallbackStopping:
    return invalid();
  }
  return invalid();
}

Transition PlaybackRouter::retireStoppingAfterSynchronousTeardown(
    Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  // Only the armed stop deadline releases this state. Without an expiry the
  // exact Stopped proof remains the single authority, so an unbounded policy
  // and an early caller both keep the strict protocol.
  if (state_ != State::NativeStopping || !deadlineExpired(now)) {
    return ignored();
  }
  return routeAfterStop(now);
}

Transition PlaybackRouter::setPaused(bool paused, Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  intendedPaused_ = paused;
  if (pending_) {
    pending_->request.paused = paused;
  }

  if (state_ == State::NativeActive) {
    native::Serial serial;
    if (!reserveLiveSerial(serial)) {
      return beginNativeStop(false, now);
    }
    native::SetRunState command{
        {attempt_, serial}, generation_, paused, native::kVersion1Rate};
    return applied(nativeRunAction(command));
  }
  if (state_ == State::NativeSeeking) {
    // CommitReady issues the one authoritative run-state command after the
    // target generation becomes active. While seeking, only retain intent.
    return applied();
  }
  if (state_ == State::NativeEnded) {
    return applied();
  }
  if (state_ == State::FallbackActive) {
    native::Serial serial;
    if (!reserveLiveSerial(serial)) {
      return beginFallbackStop(now);
    }
    return applied(fallbackAction(ActionKind::SetFallbackRunState,
                                  {attempt_, serial}, sourceKey_, paused));
  }
  return applied();
}

Transition PlaybackRouter::previewFrame(const PreviewFrameRequest &request,
                                        Tick now) noexcept {
  if (!acceptTick(now) || !native::valid(request.gesture) ||
      !native::valid(request.request) ||
      !native::validPosition(request.targetSeconds)) {
    return invalid();
  }
  if (state_ != State::NativeStarting && state_ != State::NativeActive &&
      state_ != State::NativeEnded) {
    return ignored();
  }
  if (native::valid(latestPreview_) &&
      latestPreview_.gesture != request.gesture) {
    return invalid();
  }

  const native::Stamp current{attempt_, serial_};
  native::Serial serial;
  if (!reserveLiveSerial(serial)) {
    return beginNativeStop(false, now);
  }
  native::PreviewFrame command{{attempt_, serial}, generation_,
                               request.gesture, request.request,
                               request.targetSeconds};
  const bool follows = native::valid(latestPreview_)
                           ? native::previewSupersedes(latestPreview_, command)
                           : native::previewFollows(current, generation_,
                                                    command);
  if (!follows) {
    return beginNativeStop(false, now);
  }
  latestPreview_ = command;
  return applied(nativePreviewAction(command));
}

Transition PlaybackRouter::commitSeek(const CommitSeekRequest &request,
                                      Tick now) noexcept {
  if (!acceptTick(now) || !native::valid(request.gesture) ||
      !native::valid(request.request) ||
      !native::validPosition(request.targetSeconds) ||
      request.drawBaseline == std::numeric_limits<std::uint64_t>::max()) {
    return invalid();
  }
  if (state_ != State::NativeStarting &&
      state_ != State::NativeActive && state_ != State::NativeEnded) {
    return ignored();
  }
  if (native::valid(latestPreview_) &&
      latestPreview_.gesture != request.gesture) {
    return invalid();
  }

  const native::Stamp current{attempt_, serial_};
  native::Serial serial;
  if (!reserveLiveSerial(serial)) {
    return beginNativeStop(true, now);
  }
  native::Generation targetGeneration;
  native::GenerationHighWater previousHighWater;
  if (!reserveLiveGeneration(targetGeneration, previousHighWater)) {
    return beginNativeStop(true, now);
  }
  native::CommitSeek command{{attempt_, serial},
                             generation_,
                             targetGeneration,
                             request.gesture,
                             request.request,
                             request.targetSeconds};
  const bool follows =
      native::valid(latestPreview_)
          ? native::commitFollowsLatestPreview(
                current, generation_, latestPreview_, previousHighWater,
                command)
          : native::commitFollows(current, generation_, previousHighWater,
                                  command);
  if (!follows) {
    return beginNativeStop(true, now);
  }
  latestPreview_ = {};
  commitSeek_ = command;
  commitDrawBaseline_ = request.drawBaseline;
  initialPositionSeconds_ = request.targetSeconds;
  state_ = State::NativeSeeking;
  deadlineArmed_ = timeouts_.seekTicks != 0;
  deadline_ = deadline(now, timeouts_.seekTicks);
  return applied(nativeCommitSeekAction(command));
}

bool PlaybackRouter::queueFallbackForCurrent() noexcept {
  if (pending_) {
    return true;
  }
  native::AttemptId fallbackAttempt;
  if (!reserveAttempt(fallbackAttempt)) {
    return false;
  }
  pending_ = PendingOpen{{sourceKey_, Route::FallbackOnly,
                          initialPositionSeconds_, intendedPaused_},
                         fallbackAttempt};
  return true;
}

Transition PlaybackRouter::beginNativeStop(bool fallbackCurrent,
                                           Tick now) noexcept {
  latestPreview_ = {};
  if (fallbackCurrent) {
    fallbackReservationExhausted_ = !queueFallbackForCurrent();
  }
  native::Generation invalidation;
  if (!reserveStopGeneration(invalidation)) {
    state_ = State::NativeStopFailed;
    deadlineArmed_ = false;
    return exhausted();
  }
  stop_ = {{attempt_, native::Serial{native::kTerminalStopValue}},
           invalidation};
  serial_ = stop_.stamp.serial;
  state_ = State::NativeStopping;
  // Retirement owns no timer of its own and its completion depends on a fact
  // published by the session worker exactly as Prepare, Start and CommitSeek
  // do. Arm the same deadline here so a Stopped proof that can never arrive is
  // bounded instead of parking the route silently forever.
  deadlineArmed_ = timeouts_.stopTicks != 0;
  deadline_ = deadline(now, timeouts_.stopTicks);
  return applied(nativeStopAction(stop_));
}

Transition PlaybackRouter::beginFallbackStop(Tick) noexcept {
  serial_ = native::Serial{native::kTerminalStopValue};
  state_ = State::FallbackStopping;
  deadlineArmed_ = false;
  return applied(fallbackAction(ActionKind::StopFallback, {attempt_, serial_},
                                sourceKey_, intendedPaused_));
}

Transition PlaybackRouter::routeAfterStop(Tick now) noexcept {
  const auto next = pending_;
  const bool fallbackReservationExhausted = fallbackReservationExhausted_;
  pending_.reset();
  clearCurrent();
  if (fallbackReservationExhausted && !next) {
    return exhausted();
  }
  if (!next) {
    return applied();
  }
  return beginOpen(*next, now);
}

Transition PlaybackRouter::advance(Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  if (!deadlineExpired(now)) {
    return ignored();
  }
  if (state_ == State::NativePreparing || state_ == State::NativeStarting ||
      state_ == State::NativeSeeking) {
    return beginNativeStop(true, now);
  }
  return ignored();
}

Transition PlaybackRouter::onNativePrepared(const native::Prepared &event,
                                            Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  if (state_ != State::NativePreparing || !prepareOutcome_ ||
      !prepareOutcome_->acceptPrepared(event)) {
    return ignored();
  }
  native::Serial serial;
  if (!reserveLiveSerial(serial)) {
    return beginNativeStop(true, now);
  }
  generation_ = event.generation;
  start_ = {{attempt_, serial}, generation_, true};
  if (!prepareOutcome_->startFollows(start_)) {
    return beginNativeStop(true, now);
  }
  state_ = State::NativeStarting;
  deadlineArmed_ = timeouts_.startTicks != 0;
  deadline_ = deadline(now, timeouts_.startTicks);
  return applied(nativeStartAction(start_));
}

Transition
PlaybackRouter::onNativeUnsupported(const native::UnsupportedSource &event,
                                    Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  if (state_ != State::NativePreparing || !prepareOutcome_ ||
      !prepareOutcome_->acceptUnsupportedSource(event)) {
    return ignored();
  }

  native::AttemptId fallbackAttempt;
  if (!reserveAttempt(fallbackAttempt)) {
    clearCurrent();
    return exhausted();
  }
  PendingOpen fallback{{sourceKey_, Route::FallbackOnly,
                        initialPositionSeconds_, intendedPaused_},
                       fallbackAttempt};
  clearCurrent();
  return beginFallback(fallback);
}

Transition PlaybackRouter::onNativeStarted(const native::Started &event,
                                           Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  if (state_ != State::NativeStarting || !prepareOutcome_ ||
      !prepareOutcome_->startedMatches(start_, event)) {
    return ignored();
  }
  native::Serial serial;
  if (!reserveLiveSerial(serial)) {
    return beginNativeStop(true, now);
  }
  state_ = State::NativeActive;
  deadlineArmed_ = false;
  native::SetRunState command{
      {attempt_, serial}, generation_, intendedPaused_, native::kVersion1Rate};
  return applied(nativeRunAction(command));
}

Transition PlaybackRouter::onNativeEnded(const native::Ended &event,
                                         Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  if (state_ != State::NativeActive ||
      !native::endedMatches({attempt_, serial_}, generation_, event)) {
    return ignored();
  }
  state_ = State::NativeEnded;
  deadlineArmed_ = false;
  return applied();
}

Transition PlaybackRouter::onNativeCommitReady(
    const native::CommitReady &event,
    Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  if (state_ != State::NativeSeeking ||
      !native::commitReadyMatches(commitSeek_, commitDrawBaseline_, event)) {
    return ignored();
  }
  generation_ = commitSeek_.targetGeneration;
  native::Serial serial;
  if (!reserveLiveSerial(serial)) {
    return beginNativeStop(true, now);
  }
  commitSeek_ = {};
  commitDrawBaseline_ = 0;
  state_ = State::NativeActive;
  native::SetRunState command{{attempt_, serial}, generation_,
                              intendedPaused_, native::kVersion1Rate};
  return applied(nativeRunAction(command));
}

Transition PlaybackRouter::onNativeFailed(const native::Failed &event,
                                          Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  if (state_ == State::NativeStopping) {
    if (!native::failedMatches(stop_.stamp, event) ||
        event.reason != native::FailureReason::Stop) {
      return ignored();
    }
    state_ = State::NativeStopFailed;
    return applied();
  }
  if (state_ != State::NativePreparing && state_ != State::NativeStarting &&
      state_ != State::NativeActive && state_ != State::NativeSeeking &&
      state_ != State::NativeEnded) {
    return ignored();
  }
  if (state_ == State::NativePreparing && prepareOutcome_ &&
      prepareOutcome_->acceptFailedBeforeResources(event)) {
    native::AttemptId fallbackAttempt;
    if (!reserveAttempt(fallbackAttempt)) {
      clearCurrent();
      return exhausted();
    }
    PendingOpen fallback{{sourceKey_, Route::FallbackOnly,
                          initialPositionSeconds_, intendedPaused_},
                         fallbackAttempt};
    clearCurrent();
    return beginFallback(fallback);
  }
  if (!native::failedMatches({attempt_, serial_}, event)) {
    return ignored();
  }
  return beginNativeStop(true, now);
}

Transition PlaybackRouter::onNativeStopped(const native::Stopped &event,
                                           Tick now) noexcept {
  if (!acceptTick(now)) {
    return invalid();
  }
  if (state_ != State::NativeStopping ||
      !native::stoppedMatches(stop_, event)) {
    return ignored();
  }
  return routeAfterStop(now);
}

Transition PlaybackRouter::onFallbackCreated(FallbackCreated event,
                                             Tick now) noexcept {
  if (!acceptTick(now) || !validFallbackStamp(event.stamp)) {
    return invalid();
  }
  if (state_ != State::FallbackCreating ||
      event.stamp != native::Stamp{attempt_, serial_}) {
    return ignored();
  }
  native::Serial serial;
  if (!reserveLiveSerial(serial)) {
    return beginFallbackStop(now);
  }
  state_ = State::FallbackOpening;
  return applied(fallbackAction(ActionKind::OpenFallback, {attempt_, serial},
                                sourceKey_, intendedPaused_));
}

Transition PlaybackRouter::onFallbackOpened(FallbackOpened event,
                                            Tick now) noexcept {
  if (!acceptTick(now) || !validFallbackStamp(event.stamp) ||
      !native::valid(event.sourceKey)) {
    return invalid();
  }
  if (state_ != State::FallbackOpening ||
      event.stamp != native::Stamp{attempt_, serial_} ||
      event.sourceKey != sourceKey_) {
    return ignored();
  }
  state_ = State::FallbackActive;
  return applied();
}

Transition PlaybackRouter::onFallbackStopped(FallbackStopped event,
                                             Tick now) noexcept {
  if (!acceptTick(now) || !native::valid(event.stamp)) {
    return invalid();
  }
  if (state_ != State::FallbackStopping ||
      event.stamp != native::Stamp{attempt_, serial_}) {
    return ignored();
  }
  return routeAfterStop(now);
}

Transition PlaybackRouter::onFallbackFailed(FallbackFailed event,
                                            Tick now) noexcept {
  if (!acceptTick(now) || !native::valid(event.stamp)) {
    return invalid();
  }
  if ((state_ != State::FallbackCreating && state_ != State::FallbackOpening &&
       state_ != State::FallbackActive) ||
      event.stamp != native::Stamp{attempt_, serial_}) {
    return ignored();
  }
  // Creation failure proves no fallback object became active. Open/runtime
  // failure does not, so explicitly stop it before routing another request.
  if (state_ == State::FallbackCreating) {
    return routeAfterStop(now);
  }
  return beginFallbackStop(now);
}

} // namespace wam::media::playback_router
