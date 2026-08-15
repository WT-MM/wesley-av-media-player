#include "native_playback_owner.hpp"

#include "mpv_video_item.hpp"
#include "native_benchmark_telemetry.hpp"
#include "native_playback_metrics.hpp"
#include "platform/macos/native_media_session_system.hpp"
#include "playback/mpv/mpv_runtime.hpp"
#include "player_controller.hpp"
#include "player_core_p.hpp"

#import <Foundation/Foundation.h>

#include <QCoreApplication>
#include <QFileInfo>
#include <QMetaObject>
#include <QThread>
#include <QTimer>

#include <mpv/client.h>

#include <algorithm>
#include <cmath>
#include <limits>
#include <string>
#include <type_traits>
#include <utility>

namespace wam::qt {
namespace {

constexpr std::uint64_t kFallbackStopReplyNamespace = 3ULL << 62U;
constexpr std::uint64_t kFallbackStopReplyIdMask = (1ULL << 62U) - 1ULL;
constexpr unsigned kMaximumImmediateTransitions = 12;
constexpr unsigned kMaximumFallbackStopSubmissions = 2;
constexpr int kFallbackStopWatchdogMilliseconds = 2'000;
// Wall-clock budget for the whole native admission path: asset load, decoder
// and audio-unit construction, first decode and the physical audio start. A
// healthy local open finishes inside a second even on a loaded machine, so
// this only ever fires on a session that has genuinely stopped progressing.
constexpr int kNativePhaseWatchdogMilliseconds = 10'000;

QString nativeFailureText(media::native_playback::FailureReason reason) {
  using Reason = media::native_playback::FailureReason;
  switch (reason) {
  case Reason::Preparation:
    return QStringLiteral(
        "Native playback could not admit this file; using compatibility "
        "playback.");
  case Reason::Startup:
    return QStringLiteral(
        "Native playback could not start; using compatibility playback.");
  case Reason::Clock:
    return QStringLiteral(
        "Native playback lost its media clock; using compatibility "
        "playback.");
  case Reason::Decode:
    return QStringLiteral(
        "Native decoding failed; using compatibility playback.");
  case Reason::AudioOutput:
    return QStringLiteral(
        "Native audio output failed; using compatibility playback.");
  case Reason::VideoOutput:
    return QStringLiteral(
        "Native video output failed; using compatibility playback.");
  case Reason::Preview:
  case Reason::CommitSeek:
    return QStringLiteral("Native seeking is unavailable for this file.");
  case Reason::Stop:
    return QStringLiteral(
        "Native playback could not retire safely; compatibility playback "
        "was not started.");
  case Reason::Protocol:
    return QStringLiteral(
        "Native playback rejected an internal command and was stopped.");
  }
  return QStringLiteral("Native playback failed.");
}

// True for failure reasons where the user-facing text above is merely
// informational: playback kept going (compatibility playback took over
// immediately, or -- for Preview/CommitSeek -- native playback is still
// running and only the seek itself was declined). False for reasons where
// playback did not continue, which stay on the blocking error surface.
bool nativeFailureIsInformational(
    media::native_playback::FailureReason reason) noexcept {
  using Reason = media::native_playback::FailureReason;
  switch (reason) {
  case Reason::Preparation:
  case Reason::Startup:
  case Reason::Clock:
  case Reason::Decode:
  case Reason::AudioOutput:
  case Reason::VideoOutput:
  case Reason::Preview:
  case Reason::CommitSeek:
    return true;
  case Reason::Stop:
  case Reason::Protocol:
    return false;
  }
  return false;
}

bool applied(const playback_router::Transition &transition) noexcept {
  return transition.status == playback_router::Status::Applied;
}

// The single retained activity token. AppKit reference-counts nested
// activities; WAM only ever needs the one "media is playing" assertion, so a
// process-wide GUI-thread-owned slot is the exact ownership this needs.
id gPlaybackActivityToken = nil;

} // namespace

void setMacosPlaybackActivityHeld(bool held) noexcept {
  if (held == (gPlaybackActivityToken != nil)) {
    return;
  }
  if (held) {
    const NSActivityOptions options = static_cast<NSActivityOptions>(
        NSActivityUserInitiated | NSActivityIdleDisplaySleepDisabled);
    id token = [[NSProcessInfo processInfo]
        beginActivityWithOptions:options
                          reason:@"WAM is playing media"];
#if __has_feature(objc_arc)
    gPlaybackActivityToken = token;
#else
    gPlaybackActivityToken = [token retain];
#endif
    return;
  }
  id token = gPlaybackActivityToken;
  gPlaybackActivityToken = nil;
  [[NSProcessInfo processInfo] endActivity:token];
#if !__has_feature(objc_arc)
  [token release];
#endif
}

NativePlaybackOwner::NativePlaybackOwner(PlayerController &controller)
    : controller_(controller),
      openPreflight_([this](NativeOpenPreflightResult result) {
        completeOpenPreflight(std::move(result));
      }) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  NativeBenchmarkTelemetry &telemetry = NativeBenchmarkTelemetry::instance();
  if (telemetry.enabled()) {
    telemetry_ = &telemetry;
  }
  startPlaybackMetrics();
}

// Sampling is driven from the GUI thread on purpose. This owner is the only
// object that knows which native session is current, and a GUI-thread timer
// linearizes the snapshot against every session swap performed here, so a
// sample can never straddle two epochs. It creates no thread of its own and
// adds nothing to the audio render callback or the Qt render thread. When
// WAM_PLAYBACK_METRICS_PATH is unset the singleton is disabled, no QTimer is
// constructed, and nothing below ever runs.
void NativePlaybackOwner::startPlaybackMetrics() {
  NativePlaybackMetrics &metrics = NativePlaybackMetrics::instance();
  if (!metrics.enabled()) {
    return;
  }
  metricsTimer_ = std::make_unique<QTimer>();
  metricsTimer_->setTimerType(Qt::CoarseTimer);
  metricsTimer_->setInterval(
      static_cast<int>(metrics.intervalMilliseconds()));
  // The timer is the connection's context object as well as its sender, so
  // destroying it with this owner also severs the lambda's `this` capture.
  QObject::connect(metricsTimer_.get(), &QTimer::timeout, metricsTimer_.get(),
                   [this] { samplePlaybackMetrics(); });
  metricsTimer_->start();
}

void NativePlaybackOwner::samplePlaybackMetrics() {
  NativePlaybackMetrics &metrics = NativePlaybackMetrics::instance();
  NativePlaybackMetricsSample sample;
  if (nativeSession_ != nullptr) {
    const ::wam::macos::NativeMediaSessionMetrics sampled =
        nativeSession_->metrics();
    sample.sessionEpoch = sampled.sessionEpoch;
    sample.drawnFrames = sampled.drawnFrames;
    sample.submittedFrames = sampled.submittedFrames;
    sample.supersededFrames = sampled.supersededFrames;
    sample.discardedLateFrames = sampled.discardedLateFrames;
    sample.audioUnderrunCallbacks = sampled.audioUnderrunCallbacks;
    sample.audioClockAdvancedUnderruns = sampled.audioClockAdvancedUnderruns;
    sample.audioRetiredLateFrames = sampled.audioRetiredLateFrames;
    sample.audioCallbacks = sampled.audioCallbacks;
    sample.audioRenderedFrames = sampled.audioRenderedFrames;
    sample.mediaSeconds = sampled.mediaSeconds;
    sample.clockRate = sampled.clockRate;
    sample.hasVideo = sampled.videoValid;
    sample.hasAudio = sampled.audioValid;
    sample.hasClock = sampled.clockValid;
    sample.paused = sampled.paused;
  }
  // With no native session the sample carries no counters at all: every field
  // stays unavailable and is emitted as null rather than as a fabricated zero.
  // The epoch is the exception; it stays 0, the reserved "no session open"
  // value, because it names an epoch rather than counting anything.
  static_cast<void>(metrics.write(sample));
}

NativePlaybackOwner::~NativePlaybackOwner() {
  openPreflight_.stop();
  latestOpenPreflightRequest_ = 0;
  clearNativeSession();
}

playback_router::Tick NativePlaybackOwner::nextTick() noexcept {
  if (tick_ != std::numeric_limits<std::uint64_t>::max()) {
    ++tick_;
  }
  return {tick_};
}

// NativePreparing, NativeStarting and NativeSeeking are the phases whose
// completion depends entirely on a fact arriving from the session worker.
// Every other phase either owns a physical transport or has already published
// its route. The router models exactly this with TimeoutPolicy/advance(), but
// its tick domain is an event counter, so a session that simply stops
// publishing never advances a tick and never trips its own deadline: the app
// then sits with a visible window, an idle worker, and no failure. Bound all
// three phases against the wall clock instead, so an open, a start, or a seek
// commit either progresses or is retired into compatibility playback with a
// user-visible reason.
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
  const playback_router::State state = router_.snapshot().state;
  const bool bounded = state == playback_router::State::NativePreparing ||
                       state == playback_router::State::NativeStarting ||
                       state == playback_router::State::NativeSeeking ||
                       state == playback_router::State::NativeStopping;
  if (!bounded) {
    // Leaving the bounded phases invalidates any in-flight timer.
    ++nativePhaseWatchdogEpoch_;
    nativePhaseWatchdogArmed_ = false;
    return;
  }
  if (nativePhaseWatchdogArmed_) {
    return;
  }
  nativePhaseWatchdogArmed_ = true;
  const std::uint64_t epoch = ++nativePhaseWatchdogEpoch_;
  const QPointer<PlayerController> controller = &controller_;
  QTimer::singleShot(
      kNativePhaseWatchdogMilliseconds, &controller_, [controller, epoch] {
        if (controller == nullptr || !controller->native_playback_) {
          return;
        }
        controller->native_playback_->expireNativePhaseWatchdog(epoch);
      });
}

void NativePlaybackOwner::expireNativePhaseWatchdog(std::uint64_t epoch) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
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
  if (state != playback_router::State::NativePreparing &&
      state != playback_router::State::NativeStarting &&
      state != playback_router::State::NativeSeeking &&
      state != playback_router::State::NativeStopping) {
    refreshNativePhaseWatchdog();
    return;
  }
  const bool seeking = state == playback_router::State::NativeSeeking;
  const bool stopping = state == playback_router::State::NativeStopping;
  // Cross the armed phase deadline in the router's own tick domain. The budget
  // is unreachable by ordinary event ticks, so this is the only way advance()
  // observes an expired deadline.
  if (tick_ >= std::numeric_limits<std::uint64_t>::max() -
                   kNativePhaseTickBudget) {
    tick_ = std::numeric_limits<std::uint64_t>::max();
  } else {
    tick_ += kNativePhaseTickBudget;
  }
  // A retirement that cannot complete is released only by destroying the graph
  // that owes the missing proof. Take the router's decision first so nothing is
  // torn down unless it actually leaves NativeStopping, then destroy the
  // session synchronously before any resulting action can build a replacement.
  playback_router::Transition transition =
      stopping ? router_.retireStoppingAfterSynchronousTeardown({tick_})
               : router_.advance({tick_});
  if (!applied(transition)) {
    // Nothing was retired, so the phase is still live and still needs bounding.
    refreshNativePhaseWatchdog();
    return;
  }
  if (stopping) {
    clearNativeSession();
    nativeStop_.reset();
    controller_.setLastNotice(QStringLiteral(
        "Native playback could not retire while the window was not being "
        "drawn; it was force-retired."));
    execute(std::move(transition));
    return;
  }
  clearNativeCommit(true);
  // Both texts end in "using compatibility playback": the watchdog only ever
  // fires into a fallback continuation, never a hard stop.
  controller_.setLastNotice(
      seeking ? QStringLiteral("Native playback could not complete the seek in "
                               "time; using compatibility playback.")
              : QStringLiteral("Native playback did not start in time; using "
                               "compatibility playback."));
  execute(std::move(transition));
}

std::optional<native_protocol::SourceKey>
NativePlaybackOwner::allocateSourceKey() {
  if (nextSourceKey_ == std::numeric_limits<std::uint64_t>::max()) {
    return std::nullopt;
  }
  ++nextSourceKey_;
  if (nextSourceKey_ == 0) {
    return std::nullopt;
  }
  return native_protocol::SourceKey{nextSourceKey_};
}

NativePlaybackOwner::SourceRecord *
NativePlaybackOwner::sourceRecord(native_protocol::SourceKey key) noexcept {
  const auto found = sources_.find(key.value);
  return found == sources_.end() ? nullptr : &found->second;
}

const NativePlaybackOwner::SourceRecord *NativePlaybackOwner::sourceRecord(
    native_protocol::SourceKey key) const noexcept {
  const auto found = sources_.find(key.value);
  return found == sources_.end() ? nullptr : &found->second;
}

void NativePlaybackOwner::pruneSourceRecords() {
  const playback_router::Snapshot snapshot = router_.snapshot();
  for (auto iterator = sources_.begin(); iterator != sources_.end();) {
    const bool current = snapshot.sourceKey.value != 0 &&
                         iterator->first == snapshot.sourceKey.value;
    const bool pending = snapshot.hasPendingOpen &&
                         snapshot.pendingSourceKey.value != 0 &&
                         iterator->first == snapshot.pendingSourceKey.value;
    if (current || pending) {
      ++iterator;
    } else {
      iterator = sources_.erase(iterator);
    }
  }
}

bool NativePlaybackOwner::open(const QUrl &source,
                               double initialPositionSeconds, bool paused) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  if (source.isEmpty()) {
    return false;
  }
  const auto sourceKey = allocateSourceKey();
  if (!sourceKey.has_value()) {
    controller_.setLastError(
        QStringLiteral("Playback source identities are exhausted."));
    return false;
  }
  const auto request = openPreflight_.enqueue(
      {*sourceKey, source, initialPositionSeconds, paused,
       !surfaceLost_ && surface_ != nullptr &&
           controller_.nativeRouteAdmissionAllowed()});
  if (!request.has_value()) {
    return false;
  }
  latestOpenPreflightRequest_ = *request;
  if (telemetry_ != nullptr) {
    telemetry_->openRequested(*sourceKey, controller_.engineReady());
  }
  return true;
}

void NativePlaybackOwner::completeOpenPreflight(
    NativeOpenPreflightResult result) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  if (result.requestId == 0 ||
      result.requestId != latestOpenPreflightRequest_) {
    return;
  }
  if (nativeSession_ != nullptr) {
    drainObservations(observationBridge_ ? observationBridge_->epoch : 0);
  }
  if (result.requestId != latestOpenPreflightRequest_) {
    return;
  }

  SourceRecord record;
  record.url = std::move(result.canonicalSource);
  record.localPath = std::move(result.absoluteLocalPath);
  record.initialPosition = std::move(result.initialPosition);
  record.sourceClass = result.sourceClass;
  const QUrl routedSource = record.url;
  controller_.prepareRoutedOpenIntent(routedSource);
  if (result.requestId != latestOpenPreflightRequest_) {
    return;
  }

  try {
    sources_.emplace(result.sourceKey.value, std::move(record));
  } catch (...) {
    controller_.setLastError(
        QStringLiteral("Unable to retain the playback request."));
    return;
  }
  const playback_router::Transition transition =
      router_.open({result.sourceKey, result.route,
                    result.initialPositionSeconds, result.paused},
                   nextTick());
  if (!applied(transition)) {
    sources_.erase(result.sourceKey.value);
    controller_.setLastError(
        QStringLiteral("Unable to route the playback request."));
    return;
  }
  execute(transition);
}

bool NativePlaybackOwner::stop(bool preserveVisibleState) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  openPreflight_.cancel();
  latestOpenPreflightRequest_ = 0;
  if (nativeSession_ != nullptr) {
    drainObservations(observationBridge_ ? observationBridge_->epoch : 0);
  }
  const playback_router::Transition transition = router_.stop(nextTick());
  if (!applied(transition)) {
    controller_.setLastError(
        QStringLiteral("Unable to stop the active playback route."));
    return false;
  }
  execute(transition);
  if (!preserveVisibleState) {
    controller_.finishStopUi(false);
  }
  return true;
}

NativePlaybackOwner::PauseDisposition
NativePlaybackOwner::setPaused(bool paused) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  if (nativeSession_ != nullptr) {
    drainObservations(observationBridge_ ? observationBridge_->epoch : 0);
  }

  const playback_router::State before = router_.snapshot().state;
  if (before == playback_router::State::Idle) {
    return PauseDisposition::NotOwned;
  }
  const playback_router::Transition transition =
      router_.setPaused(paused, nextTick());
  if (!applied(transition)) {
    controller_.setLastError(
        QStringLiteral("Unable to change the playback state."));
    return nativeOwnsTransport() ? PauseDisposition::NativeHandled
                                 : PauseDisposition::FallbackHandled;
  }

  const bool nativeOwned = before == playback_router::State::NativePreparing ||
                           before == playback_router::State::NativeStarting ||
                           before == playback_router::State::NativeActive ||
                           before == playback_router::State::NativeSeeking ||
                           before == playback_router::State::NativeEnded ||
                           before == playback_router::State::NativeStopping ||
                           before == playback_router::State::NativeStopFailed;
  if (nativeOwned) {
    execute(transition);
    return PauseDisposition::NativeHandled;
  }

  // Preserve the existing fallback transport transaction, including EOF
  // restart and render-recovery state. The router has already retained the
  // exact intended pause value; PlayerController now applies the mpv command.
  return PauseDisposition::FallbackHandled;
}

bool NativePlaybackOwner::preparePreviewHandoff() {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  const playback_router::State state = router_.snapshot().state;
  // A fully published Ended session has already drained the main decoder and
  // stopped audio, but still retains its source/context for exact replay. It
  // therefore supports the same pointer-down preview prewarm without first
  // reviving the authoritative playback generation.
  if (nativeSession_ == nullptr ||
      (state != playback_router::State::NativeStarting &&
       state != playback_router::State::NativeActive &&
       state != playback_router::State::NativeEnded)) {
    return false;
  }
  const macos::NativeMediaSessionCommandStatus status =
      nativeSession_->preparePreviewHandoff();
  return status == macos::NativeMediaSessionCommandStatus::Accepted ||
         status == macos::NativeMediaSessionCommandStatus::Ignored;
}

NativePlaybackOwner::PreviewDisposition
NativePlaybackOwner::previewFrame(double targetSeconds, std::uint64_t gesture,
                                  std::uint64_t request) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
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
  if (telemetry_ != nullptr) {
    telemetry_->previewDispatched(native_protocol::GestureId{gesture},
                                  native_protocol::RequestId{request},
                                  targetSeconds, controller_.engineReady());
  }
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
  if (state != playback_router::State::NativeStarting &&
      state != playback_router::State::NativeActive &&
      state != playback_router::State::NativeEnded) {
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
NativePlaybackOwner::commitSeek(double targetSeconds, std::uint64_t gesture,
                                std::uint64_t request, bool intendedPaused) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
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
    break;
  case playback_router::State::NativePreparing:
  case playback_router::State::NativeSeeking:
  case playback_router::State::NativeStopping:
  case playback_router::State::NativeStopFailed:
    return SeekDisposition::NativeRejected;
  }

  if (nativeSession_ == nullptr) {
    surfaceNativeError(
        QStringLiteral("Native seeking lost its playback session."));
    return SeekDisposition::NativeRejected;
  }
  std::optional<macos::NativeMediaSessionCommitTarget> target =
      nativeSession_->preflightCommitTarget(targetSeconds);
  if (!target.has_value()) {
    surfaceNativeError(
        QStringLiteral("Native seeking cannot represent this exact target."));
    return SeekDisposition::NativeRejected;
  }

  playback_router::Transition transition = router_.commitSeek(
      {native_protocol::GestureId{gesture}, native_protocol::RequestId{request},
       targetSeconds, target->drawBaseline()},
      nextTick());
  if (!applied(transition) || !transition.action.has_value() ||
      transition.action->kind !=
          playback_router::ActionKind::NativeCommitSeek) {
    surfaceNativeError(
        QStringLiteral("Native seeking could not reserve exact lineage."));
    if (applied(transition)) {
      execute(std::move(transition));
    }
    return SeekDisposition::NativeRejected;
  }

  const native_protocol::CommitSeek command = transition.action->commitSeek;
  nativeCommitTarget_ = std::move(target);
  nativeCommit_ = command;
  nativeCommitDrawBaseline_ = nativeCommitTarget_->drawBaseline();
  nativeCommitDispatchAccepted_ = false;

  // The controller may have changed logical play/pause during a scrub while
  // native playback stayed physically paused. Retain that latest intent only
  // after CommitSeek owns the route; CommitReady emits its one authoritative
  // SetRunState command for the promoted generation.
  const playback_router::Transition pauseTransition =
      router_.setPaused(intendedPaused, nextTick());
  if (!applied(pauseTransition) || pauseTransition.action.has_value()) {
    nativeCommitTarget_.reset();
    nativeCommit_.reset();
    nativeCommitDrawBaseline_ = 0;
    surfaceNativeError(
        QStringLiteral("Native seeking could not retain transport intent."));
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
    surfaceNativeError(
        QStringLiteral("Native audio rejected the volume change."));
  }
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
    surfaceNativeError(
        QStringLiteral("Native audio rejected the mute change."));
  }
  return true;
}

bool NativePlaybackOwner::nativeOwnsTransport() const noexcept {
  switch (router_.snapshot().state) {
  case playback_router::State::NativePreparing:
  case playback_router::State::NativeStarting:
  case playback_router::State::NativeActive:
  case playback_router::State::NativeSeeking:
  case playback_router::State::NativeEnded:
  case playback_router::State::NativeStopping:
  case playback_router::State::NativeStopFailed:
    return true;
  default:
    return false;
  }
}

bool NativePlaybackOwner::fallbackOwnsTransport() const noexcept {
  switch (router_.snapshot().state) {
  case playback_router::State::FallbackCreating:
  case playback_router::State::FallbackOpening:
  case playback_router::State::FallbackActive:
  case playback_router::State::FallbackStopping:
    return true;
  default:
    return false;
  }
}

bool NativePlaybackOwner::needsFallbackRenderContext() const noexcept {
  const playback_router::State state = router_.snapshot().state;
  return state == playback_router::State::FallbackOpening ||
         state == playback_router::State::FallbackActive;
}

bool NativePlaybackOwner::acceptsFallbackPlaybackEvents() const noexcept {
  const playback_router::State state = router_.snapshot().state;
  return state == playback_router::State::FallbackOpening ||
         state == playback_router::State::FallbackActive ||
         state == playback_router::State::FallbackStopping;
}

void NativePlaybackOwner::execute(playback_router::Transition transition) {
  ++executeDepth_;
  bool completed = false;
  for (unsigned step = 0; step != kMaximumImmediateTransitions; ++step) {
    if (!applied(transition)) {
      if (transition.status == playback_router::Status::Exhausted) {
        controller_.setLastError(
            QStringLiteral("Playback route identities are exhausted."));
      } else if (transition.status == playback_router::Status::Invalid) {
        controller_.setLastError(
            QStringLiteral("Playback routing rejected an invalid event."));
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
    controller_.setLastError(QStringLiteral(
        "Playback routing exceeded its immediate action bound."));
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
    if (telemetry_ != nullptr) {
      telemetry_->nativeSelected(action.prepare, controller_.engineReady());
    }
    return beginNativePrepare(action);
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
    if (status != macos::NativeMediaSessionCommandStatus::Accepted) {
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
      if (telemetry_ != nullptr) {
        telemetry_->previewAdmitted(action.previewFrame,
                                    controller_.engineReady());
      }
      break;
    case macos::NativePreviewFrameRequestStatus::Replaced:
      nativePreviewDisposition_ = PreviewDisposition::Replaced;
      if (telemetry_ != nullptr) {
        telemetry_->previewAdmitted(action.previewFrame,
                                    controller_.engineReady());
      }
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
    if (telemetry_ != nullptr) {
      telemetry_->commitSeekSubmitted(action.commitSeek,
                                      controller_.engineReady());
    }
    return std::nullopt;
  }
  case Kind::NativeStop: {
    clearNativePreview();
    clearNativeCommit(true);
    if (nativeSession_ == nullptr) {
      surfaceNativeError(QStringLiteral(
          "Native playback lost its session before retirement."));
      return std::nullopt;
    }
    nativeStop_ = action.stop;
    const auto status = nativeSession_->stop(action.stop);
    if (status != macos::NativeMediaSessionCommandStatus::Accepted &&
        status != macos::NativeMediaSessionCommandStatus::Ignored) {
      surfaceNativeError(
          QStringLiteral("Native playback could not begin exact retirement."));
    }
    return std::nullopt;
  }
  case Kind::CreateFallback:
    if (telemetry_ != nullptr) {
      telemetry_->fallbackSelected(action.fallback.stamp,
                                   action.fallback.sourceKey,
                                   controller_.engineReady());
    }
    return beginFallbackCreate(action);
  case Kind::OpenFallback:
    if (!beginFallbackOpen(action)) {
      return router_.onFallbackFailed({action.fallback.stamp}, nextTick());
    }
    return std::nullopt;
  case Kind::SetFallbackRunState: {
    if (!controller_.engineReady()) {
      return router_.onFallbackFailed({action.fallback.stamp}, nextTick());
    }
    int paused = action.fallback.paused ? 1 : 0;
    const int result = controller_.core_->api().mpv_set_property(
        controller_.core_->handle(), "pause", MPV_FORMAT_FLAG, &paused);
    if (result < 0) {
      controller_.setLastError(
          QStringLiteral("Compatibility playback rejected the transport "
                         "change."));
      return router_.onFallbackFailed({action.fallback.stamp}, nextTick());
    }
    controller_.updatePause(action.fallback.paused);
    return std::nullopt;
  }
  case Kind::StopFallback:
    static_cast<void>(beginFallbackStop(action));
    return std::nullopt;
  case Kind::None:
    return std::nullopt;
  }
  return std::nullopt;
}

std::optional<playback_router::Transition>
NativePlaybackOwner::beginNativePrepare(const playback_router::Action &action) {
  const SourceRecord *record = sourceRecord(action.prepare.sourceKey);
  if (record == nullptr || !record->initialPosition.has_value() ||
      record->localPath.empty() || surface_ == nullptr || surfaceLost_) {
    return router_.onNativeFailed(
        {action.prepare.stamp, native_protocol::FailureReason::Preparation},
        nextTick());
  }
  if (nativeSession_ != nullptr) {
    surfaceNativeError(
        QStringLiteral("A previous native session is still retained."));
    return router_.onNativeFailed(
        {action.prepare.stamp, native_protocol::FailureReason::Preparation},
        nextTick());
  }

  ++nextObservationEpoch_;
  if (nextObservationEpoch_ == 0) {
    ++nextObservationEpoch_;
  }
  auto bridge = std::make_shared<ObservationBridge>();
  bridge->controller = &controller_;
  bridge->epoch = nextObservationEpoch_;

  std::string error;
  std::unique_ptr<macos::NativeMediaSession> session =
      macos::createNativeMediaSessionSystem(
          {action.prepare.sourceKey, record->localPath}, bridge,
          &surface_->nativeVideoItem(), &error);
  if (session == nullptr) {
    surfaceNativeError(error.empty()
                           ? QStringLiteral("Unable to create native playback.")
                           : QString::fromUtf8(error));
    return router_.onNativeFailed(
        {action.prepare.stamp, native_protocol::FailureReason::Preparation},
        nextTick());
  }

  if (!session->bindObservationEdge(
          {bridge, &NativePlaybackOwner::queueObservations, nullptr}) ||
      session->setGain(static_cast<float>(controller_.volume_)) !=
          macos::NativeMediaSessionCommandStatus::Accepted ||
      session->setMuted(controller_.muted_) !=
          macos::NativeMediaSessionCommandStatus::Accepted) {
    session.reset();
    surfaceNativeError(
        QStringLiteral("Unable to bind native playback controls."));
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
  const auto status =
      nativeSession_->prepare(action.prepare, *record->initialPosition);
  if (status != macos::NativeMediaSessionCommandStatus::Accepted) {
    clearNativeSession();
    surfaceNativeError(
        QStringLiteral("Native playback rejected media preparation."));
    return router_.onNativeFailed(
        {action.prepare.stamp, native_protocol::FailureReason::Preparation},
        nextTick());
  }
  return std::nullopt;
}

std::optional<playback_router::Transition>
NativePlaybackOwner::beginFallbackCreate(
    const playback_router::Action &action) {
  if (nativeSession_ != nullptr) {
    controller_.setLastError(QStringLiteral(
        "Compatibility playback was blocked until native retirement."));
    return std::nullopt;
  }

  // Reserve terminal recovery before creating any fallback resource. If this
  // allocation fails, FallbackCreating can honestly fail with no mpv handle
  // admitted; once a handle exists, retirement needs no further allocation.
  if (!controller_.fallback_reset_core_) {
    try {
      controller_.fallback_reset_core_ =
          std::make_shared<PlayerCore>(&controller_);
    } catch (...) {
      controller_.setLastError(QStringLiteral(
          "Unable to reserve compatibility playback retirement."));
      return router_.onFallbackFailed({action.fallback.stamp}, nextTick());
    }
  }

  if (!controller_.engineReady()) {
    if (!controller_.fallback_runtime_) {
      const auto loaded = playback::mpv::MpvFallbackFactory::load(
          QCoreApplication::applicationDirPath());
      if (!loaded || !controller_.provisionMpvFallbackRuntime(loaded.runtime)) {
        controller_.setLastError(
            loaded.detail.isEmpty()
                ? QStringLiteral(
                      "The compatibility media engine is unavailable.")
                : loaded.detail);
        return router_.onFallbackFailed({action.fallback.stamp}, nextTick());
      }
    }
    if (!controller_.initializePlaybackEngine()) {
      return router_.onFallbackFailed({action.fallback.stamp}, nextTick());
    }
  }

  return router_.onFallbackCreated({action.fallback.stamp}, nextTick());
}

bool NativePlaybackOwner::beginFallbackOpen(
    const playback_router::Action &action) {
  const SourceRecord *record = sourceRecord(action.fallback.sourceKey);
  if (record == nullptr || !controller_.engineReady()) {
    controller_.setLastError(
        QStringLiteral("Compatibility playback lost its source record."));
    return false;
  }
  return controller_.beginRoutedFallbackOpen(
      record->url, action.fallback.stamp.attempt.value,
      action.fallback.stamp.serial.value, action.fallback.sourceKey.value,
      action.fallback.paused, record->sourceClass);
}

bool NativePlaybackOwner::beginFallbackStop(
    const playback_router::Action &action) {
  if (!controller_.engineReady() || fallbackStop_.has_value()) {
    controller_.setLastError(QStringLiteral(
        "Compatibility playback could not begin exact retirement."));
    return false;
  }

  fallbackStop_ = FallbackStop{action.fallback, controller_.core_};

  controller_.core_->revokeRenderContext();
  if (!controller_.core_->renderContextBusy() &&
      RenderLifecycle::phase(controller_.core_->renderLifecycleSnapshot()) ==
          RenderPhase::Failed) {
    static_cast<void>(controller_.core_->retryFailedRenderContext());
  }
  controller_.requestVideoUpdate();
  return submitFallbackStop();
}

bool NativePlaybackOwner::submitFallbackStop() {
  if (!fallbackStop_.has_value() || !controller_.engineReady() ||
      fallbackStop_->core != controller_.core_ ||
      fallbackStop_->submissions >= kMaximumFallbackStopSubmissions) {
    exhaustFallbackStop(QStringLiteral(
        "Compatibility playback exhausted its exact Stop attempts."));
    return false;
  }

  ++nextFallbackStopReplyId_;
  nextFallbackStopReplyId_ &= kFallbackStopReplyIdMask;
  if (nextFallbackStopReplyId_ == 0) {
    nextFallbackStopReplyId_ = 1;
  }
  fallbackStop_->replyId = nextFallbackStopReplyId_;
  ++fallbackStop_->submissions;
  fallbackStop_->commandReplied = false;
  fallbackStop_->idleObserved = false;

  const char *arguments[] = {"stop", nullptr};
  const std::uint64_t userdata =
      kFallbackStopReplyNamespace | nextFallbackStopReplyId_;
  const int result = controller_.core_->api().mpv_command_async(
      controller_.core_->handle(), userdata, arguments);
  if (result < 0) {
    if (fallbackStop_->submissions < kMaximumFallbackStopSubmissions)
      return submitFallbackStop();
    exhaustFallbackStop(QStringLiteral(
        "Compatibility playback could not submit an exact Stop."));
    return false;
  }
  const QPointer<PlayerController> controller = &controller_;
  const std::uint64_t replyId = fallbackStop_->replyId;
  QTimer::singleShot(
      kFallbackStopWatchdogMilliseconds, &controller_, [controller, replyId] {
        if (controller == nullptr || !controller->native_playback_)
          return;
        NativePlaybackOwner &owner = *controller->native_playback_;
        if (!owner.fallbackStop_.has_value() ||
            owner.fallbackStop_->replyId != replyId ||
            owner.fallbackStop_->terminalResetRequired) {
          return;
        }
        owner.exhaustFallbackStop(QStringLiteral(
            "Compatibility playback Stop did not complete in time."));
      });
  return true;
}

void NativePlaybackOwner::exhaustFallbackStop(const QString &detail) {
  if (!fallbackStop_.has_value())
    return;
  fallbackStop_->terminalResetRequired = true;
  fallbackStop_->commandReplied = false;
  fallbackStop_->idleObserved = false;
  controller_.setLastError(
      detail +
      QStringLiteral(" The engine will be replaced after renderer release."));
  if (executeDepth_ != 0 || fallbackEventDrainDepth_ != 0) {
    fallbackCompletionDeferred_ = true;
  } else {
    maybeCompleteFallbackStop();
  }
}

void NativePlaybackOwner::beginFallbackEventDrain() noexcept {
  ++fallbackEventDrainDepth_;
}

void NativePlaybackOwner::endFallbackEventDrain() {
  Q_ASSERT(fallbackEventDrainDepth_ != 0);
  --fallbackEventDrainDepth_;
  if (fallbackEventDrainDepth_ == 0 && executeDepth_ == 0 &&
      fallbackCompletionDeferred_) {
    fallbackCompletionDeferred_ = false;
    maybeCompleteFallbackStop();
  }
}

std::optional<playback_router::Transition>
NativePlaybackOwner::rejectNativeCommand(native_protocol::Stamp stamp) {
  surfaceNativeError(QStringLiteral(
      "Native playback rejected an internal lifecycle command."));
  return router_.onNativeFailed(
      {stamp, native_protocol::FailureReason::Protocol}, nextTick());
}

bool NativePlaybackOwner::queueObservations(std::shared_ptr<void> lifetime,
                                            void *) noexcept {
  std::shared_ptr<ObservationBridge> bridge;
  try {
    bridge = std::static_pointer_cast<ObservationBridge>(lifetime);
  } catch (...) {
    return false;
  }
  if (bridge == nullptr || bridge->controller == nullptr) {
    return false;
  }
  const QPointer<PlayerController> controller = bridge->controller;
  const std::uint64_t epoch = bridge->epoch;
  try {
    return QMetaObject::invokeMethod(
        controller,
        [controller, lifetime = std::move(lifetime), epoch] {
          (void)lifetime;
          if (controller == nullptr || !controller->native_playback_) {
            return;
          }
          controller->native_playback_->drainObservations(epoch);
        },
        Qt::QueuedConnection);
  } catch (...) {
    // Returning false rolls the reservation back for a bounded event-driven
    // retry. Never call the GUI owner inline.
    return false;
  }
}

void NativePlaybackOwner::drainObservations(std::uint64_t epoch) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
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
    consumeLifecycle(*observations.lifecycle);
  }
  if (observations.runStateApplied.has_value()) {
    consumeRunState(*observations.runStateApplied);
  }
  if (observations.audioClock.has_value()) {
    consumeAudioClock(*observations.audioClock);
  }
  if (observations.videoDraw.has_value()) {
    consumeVideoDraw(*observations.videoDraw);
  }
}

void NativePlaybackOwner::consumePreviewPresented(
    const native_protocol::PreviewPresented &presented) {
  if (!nativePreview_.has_value() ||
      !native_protocol::previewPresentedMatches(*nativePreview_, presented)) {
    return;
  }
  const playback_router::Snapshot snapshot = router_.snapshot();
  if (snapshot.state != playback_router::State::NativeStarting &&
      snapshot.state != playback_router::State::NativeActive &&
      snapshot.state != playback_router::State::NativeEnded) {
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
  if (telemetry_ != nullptr) {
    telemetry_->previewFrameDrawn(presented, controller_.engineReady());
  }
  controller_.nativePreviewPresented(presented);
}

void NativePlaybackOwner::consumePreviewFailed(
    const native_protocol::PreviewFailed &failed) {
  if (!nativePreview_.has_value() ||
      !native_protocol::previewFailedMatches(*nativePreview_, failed)) {
    return;
  }
  const playback_router::Snapshot snapshot = router_.snapshot();
  if (snapshot.state != playback_router::State::NativeStarting &&
      snapshot.state != playback_router::State::NativeActive &&
      snapshot.state != playback_router::State::NativeEnded) {
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
  if (telemetry_ != nullptr) {
    telemetry_->previewFailed(failed, controller_.engineReady());
  }
  controller_.nativePreviewFailed(failed);
}

void NativePlaybackOwner::consumeCommitReady(
    const native_protocol::CommitReady &ready) {
  if (!nativeCommit_.has_value() || !nativeCommitDispatchAccepted_ ||
      !native_protocol::commitReadyMatches(*nativeCommit_,
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
  if (telemetry_ != nullptr) {
    telemetry_->commitReady(ready, controller_.engineReady());
    if (!firstNativeDrawReported_) {
      telemetry_->firstFrameDrawn(ready.videoDraw, controller_.engineReady());
    }
  }
  firstNativeDrawReported_ = true;
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
    controller_.nativeCommitFailed(completed.gesture.value,
                                   completed.request.value);
    return;
  }
  controller_.nativeCommitReady(ready);
  controller_.updateIdle(false);
  controller_.updateEof(false);
  const double position = std::max(0.0, ready.targetSeconds);
  if (std::isfinite(position) &&
      std::abs(controller_.position_ - position) > 0.0005) {
    controller_.position_ = position;
    emit controller_.positionChanged();
  }
  if (telemetry_ != nullptr) {
    static_cast<void>(telemetry_->checkpoint());
  }
}

void NativePlaybackOwner::consumeLifecycle(
    const macos::NativeMediaSessionFact &fact) {
  std::visit(
      [this](const auto &event) {
        using Event = std::decay_t<decltype(event)>;
        if constexpr (std::is_same_v<Event, native_protocol::Prepared>) {
          playback_router::Transition transition =
              router_.onNativePrepared(event, nextTick());
          if (!applied(transition)) {
            return;
          }
          if (telemetry_ != nullptr) {
            telemetry_->prepared(event, controller_.engineReady());
          }
          // Submit Start before publishing any synchronous QML-facing signal.
          // durationChanged may immediately issue a resume seek; the session
          // supports CommitSeek from Starting only after this subordinate
          // Start command has been physically admitted.
          execute(std::move(transition));
          const SourceRecord *record = sourceRecord(event.sourceKey);
          if (record != nullptr) {
            controller_.updateSource(record->url);
            controller_.updateMediaTitle(
                QFileInfo(record->url.toLocalFile()).fileName());
          }
          controller_.updateDuration(event.descriptor.durationSeconds);
          controller_.updatePause(true);
          controller_.updateIdle(false);
          controller_.updateEof(false);
          controller_.setLastError({});
        } else if constexpr (std::is_same_v<Event, native_protocol::Started>) {
          playback_router::Transition transition =
              router_.onNativeStarted(event, nextTick());
          if (!applied(transition)) {
            return;
          }
          if (telemetry_ != nullptr) {
            telemetry_->started(event, controller_.engineReady());
          }
          controller_.updateIdle(false);
          controller_.updateEof(false);
          execute(std::move(transition));
        } else if constexpr (std::is_same_v<Event, native_protocol::Ended>) {
          playback_router::Transition transition =
              router_.onNativeEnded(event, nextTick());
          if (!applied(transition)) {
            return;
          }
          const double position = std::max(0.0, event.finalPositionSeconds);
          if (std::isfinite(position) &&
              std::abs(controller_.position_ - position) > 0.0005) {
            controller_.position_ = position;
            emit controller_.positionChanged();
          }
          controller_.updatePause(true);
          controller_.updateIdle(true);
          controller_.updateEof(true);
          execute(std::move(transition));
        } else if constexpr (std::is_same_v<Event, native_protocol::Failed>) {
          playback_router::Transition transition =
              router_.onNativeFailed(event, nextTick());
          if (!applied(transition)) {
            return;
          }
          clearNativeCommit(true);
          if (nativeFailureIsInformational(event.reason)) {
            controller_.setLastNotice(nativeFailureText(event.reason));
          } else {
            controller_.setLastError(nativeFailureText(event.reason));
          }
          if (event.reason == native_protocol::FailureReason::Preparation &&
              transition.action.has_value() &&
              transition.action->kind ==
                  playback_router::ActionKind::CreateFallback) {
            clearNativeSession();
          }
          execute(std::move(transition));
        } else if constexpr (std::is_same_v<Event, native_protocol::Stopped>) {
          if (!nativeStop_.has_value() ||
              !native_protocol::stoppedMatches(*nativeStop_, event) ||
              router_.snapshot().state !=
                  playback_router::State::NativeStopping) {
            return;
          }
          clearNativeSession();
          nativeStop_.reset();
          execute(router_.onNativeStopped(event, nextTick()));
        }
      },
      fact);
}

bool NativePlaybackOwner::exactCurrent(
    native_protocol::Stamp stamp,
    native_protocol::Generation generation) const noexcept {
  const playback_router::Snapshot snapshot = router_.snapshot();
  return snapshot.state == playback_router::State::NativeActive &&
         stamp == native_protocol::Stamp{snapshot.attempt, snapshot.serial} &&
         generation == snapshot.generation;
}

void NativePlaybackOwner::consumeRunState(
    const macos::NativeMediaSessionRunStateApplied &appliedState) {
  const native_protocol::SetRunState &command = appliedState.command;
  if (!exactCurrent(command.stamp, command.generation)) {
    return;
  }
  // A scrub captures logical post-seek intent before physically pausing the
  // native graph. Its pause acknowledgement must not make the QML transport
  // appear paused; play/pause during the gesture updates that retained intent
  // and CommitReady applies it to the promoted generation.
  if (!controller_.native_scrub_intent_ && !controller_.native_seek_intent_) {
    controller_.updatePause(command.paused);
  }
  controller_.updateIdle(false);
  controller_.updateEof(false);
}

void NativePlaybackOwner::consumeAudioClock(
    const native_protocol::AudioClockProof &proof) {
  if (!exactCurrent(proof.stamp, proof.generation) ||
      proof.stamp.serial.value < lastAudioProofSerial_ ||
      !std::isfinite(proof.positionSeconds)) {
    return;
  }
  lastAudioProofSerial_ = proof.stamp.serial.value;
  const double position = std::max(0.0, proof.positionSeconds);
  controller_.publishNativeMainPosition(position);
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
  if (!firstNativeDrawReported_) {
    firstNativeDrawReported_ = true;
    if (telemetry_ != nullptr) {
      telemetry_->firstFrameDrawn(proof, controller_.engineReady());
    }
  }
  // NativeAudioSession owns the authoritative running clock internally, but
  // the public v1 proof stream intentionally emits a sampled AudioClockProof
  // only for paused transport. While running, the exact drawn frame PTS is
  // therefore the bounded, event-driven UI playhead observation.
  const double position = std::max(0.0, proof.frameStartSeconds);
  controller_.publishNativeMainPosition(position);
}

void NativePlaybackOwner::fallbackOpenSucceeded(std::uint64_t attempt,
                                                std::uint64_t serial,
                                                std::uint64_t sourceKey) {
  execute(router_.onFallbackOpened(
      {{native_protocol::AttemptId{attempt}, native_protocol::Serial{serial}},
       native_protocol::SourceKey{sourceKey}},
      nextTick()));
}

void NativePlaybackOwner::fallbackOpenFailed(std::uint64_t attempt,
                                             std::uint64_t serial,
                                             std::uint64_t sourceKey) {
  (void)sourceKey;
  execute(router_.onFallbackFailed(
      {{native_protocol::AttemptId{attempt}, native_protocol::Serial{serial}}},
      nextTick()));
}

void NativePlaybackOwner::fallbackStopCommandReply(std::uint64_t replyUserdata,
                                                   int error) {
  if (!fallbackStop_.has_value() ||
      (replyUserdata & kFallbackStopReplyIdMask) != fallbackStop_->replyId ||
      (replyUserdata & ~kFallbackStopReplyIdMask) !=
          kFallbackStopReplyNamespace) {
    return;
  }
  if (error < 0) {
    if (fallbackStop_->submissions < kMaximumFallbackStopSubmissions) {
      static_cast<void>(submitFallbackStop());
    } else {
      exhaustFallbackStop(
          QStringLiteral("Compatibility playback rejected its exact Stop."));
    }
    return;
  }
  fallbackStop_->commandReplied = true;
  fallbackStop_->idleObserved = false;
  int idle = 0;
  if (controller_.engineReady() &&
      controller_.core_->api().mpv_get_property(controller_.core_->handle(),
                                                "idle-active", MPV_FORMAT_FLAG,
                                                &idle) >= 0 &&
      idle != 0) {
    fallbackStop_->idleObserved = true;
  }
  maybeCompleteFallbackStop();
}

void NativePlaybackOwner::fallbackIdleChanged(bool idle) {
  if (!fallbackStop_.has_value() || !fallbackStop_->commandReplied || !idle ||
      fallbackStop_->core != controller_.core_) {
    return;
  }
  // Property observations are coalesced and can have been published before
  // the Stop reply. Re-read only after exact command completion so the value
  // is causally post-Stop.
  int currentIdle = 0;
  if (controller_.engineReady() &&
      controller_.core_->api().mpv_get_property(controller_.core_->handle(),
                                                "idle-active", MPV_FORMAT_FLAG,
                                                &currentIdle) >= 0 &&
      currentIdle != 0) {
    fallbackStop_->idleObserved = true;
  }
  maybeCompleteFallbackStop();
}

void NativePlaybackOwner::fallbackRenderStateChanged() {
  maybeCompleteFallbackStop();
}

void NativePlaybackOwner::fallbackPlaybackFailed() {
  const playback_router::Snapshot snapshot = router_.snapshot();
  if (snapshot.state != playback_router::State::FallbackOpening &&
      snapshot.state != playback_router::State::FallbackActive) {
    return;
  }
  execute(router_.onFallbackFailed({{snapshot.attempt, snapshot.serial}},
                                   nextTick()));
}

void NativePlaybackOwner::maybeCompleteFallbackStop() {
  if (executeDepth_ != 0 || fallbackEventDrainDepth_ != 0) {
    fallbackCompletionDeferred_ = true;
    return;
  }
  if (!fallbackStop_.has_value() || !fallbackStop_->core ||
      fallbackStop_->core != controller_.core_ ||
      fallbackStop_->core->renderContextBusy()) {
    return;
  }
  const RenderTicket lifecycle = fallbackStop_->core->renderLifecycleSnapshot();
  if (RenderLifecycle::phase(lifecycle) != RenderPhase::Empty) {
    return;
  }

  const playback_router::FallbackCommand command = fallbackStop_->command;
  if (fallbackStop_->terminalResetRequired) {
    const std::shared_ptr<PlayerCore> retiredCore = fallbackStop_->core;
    if (!controller_.resetRoutedFallbackCoreAfterRelease(retiredCore)) {
      return;
    }
  } else if (!fallbackStop_->commandReplied || !fallbackStop_->idleObserved) {
    return;
  }
  fallbackStop_.reset();
  execute(router_.onFallbackStopped({command.stamp}, nextTick()));
}

void NativePlaybackOwner::attachSurface(MpvVideoItem *item) noexcept {
  surface_ = item;
  surfaceLost_ = false;
}

void NativePlaybackOwner::detachSurface(MpvVideoItem *item) noexcept {
  if (surface_ != item) {
    return;
  }
  surface_.clear();
  surfaceLost_ = true;
  if (nativeSession_ != nullptr) {
    // QML is destroying the surface. Keep fallback denied and synchronously
    // release the session while the item's native child still exists; never
    // start another route from this emergency teardown.
    clearNativeSession();
    nativeStop_.reset();
    // Surface destruction is an application/QML teardown boundary. The
    // session destructor synchronously closes its private graph before this
    // narrow emergency reset. It drops pending work without forging Stopped
    // or permitting fallback creation.
    const playback_router::Transition reset =
        router_.abandonNativeAfterSynchronousRetirement(nextTick());
    if (!applied(reset) || reset.action.has_value()) {
      surfaceNativeError(QStringLiteral(
          "Native surface teardown could not reset playback ownership."));
      return;
    }
    pruneSourceRecords();
    // This teardown leaves the bounded phases without passing through
    // execute(), so retire the admission watchdog explicitly.
    refreshNativePhaseWatchdog();
    surfaceNativeError(QStringLiteral(
        "The native video surface was destroyed during playback."));
  }
}

void NativePlaybackOwner::clearNativeSession() noexcept {
  clearNativePreview();
  clearNativeCommit(true);
  nativeSession_.reset();
  observationBridge_.reset();
  lastAudioProofSerial_ = 0;
  lastVideoDrawSequence_ = 0;
  firstNativeDrawReported_ = false;
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
  nativeCommitDispatchAccepted_ = false;
  if (notifyFailure && accepted && command.has_value()) {
    controller_.nativeCommitFailed(command->gesture.value,
                                   command->request.value);
  }
}

void NativePlaybackOwner::surfaceNativeError(const QString &detail) {
  controller_.setLastError(detail);
}

} // namespace wam::qt
