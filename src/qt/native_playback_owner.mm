#include "media/startup_benchmark.hpp"
#include "native_playback_owner.hpp"

#include "mpv_video_item.hpp"
#include "native_benchmark_telemetry.hpp"
#include "native_playback_metrics.hpp"
#include "native_media_session_adapter.hpp"
#include "platform/macos/native_embedding_support.hpp"
#include "player_controller.hpp"

#import <Foundation/Foundation.h>

#include <QFileInfo>
#include <QMetaObject>
#include <QThread>
#include <QTimer>

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
constexpr unsigned kMaximumFallbackStopSubmissions = 2;
constexpr int kFallbackStopWatchdogMilliseconds = 2'000;
bool applied(const playback_router::Transition &transition) noexcept {
  return transition.status == playback_router::Status::Applied;
}

// The single retained activity token, and the count of windows currently
// asking for it.
//
// WAM is a multi-window player: two windows can be playing at once, and one of
// them pausing must NOT end the assertion the other still needs, or the
// display could idle-sleep and App Nap could throttle the process mid-playback
// in the window that was still running. One assertion, reference counted over
// the windows holding it, is the ownership; every caller edge-triggers (PlayerController tracks
// its own hold), so the count is a count of windows, not of signals.
//
// GUI-thread-owned: every caller is on it, so no synchronisation is implied.
id gPlaybackActivityToken = nil;
int gPlaybackActivityHolders = 0;

} // namespace

void setMacosPlaybackActivityHeld(bool held) noexcept {
  if (held) {
    if (++gPlaybackActivityHolders != 1) {
      return;
    }
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
  if (gPlaybackActivityHolders == 0 || --gPlaybackActivityHolders != 0) {
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
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY)
        const int delay = telemetry_ ? qEnvironmentVariableIntValue("WAM_TEST_OPEN_DELAY_MS") : 0;
        if (delay > 0) {
          QTimer::singleShot(std::min(delay, 15000), &controller_,
              [this, result = std::move(result)]() mutable { completeOpenPreflight(std::move(result)); });
          return;
        }
#endif
        completeOpenPreflight(std::move(result));
      }) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  NativeBenchmarkTelemetry &telemetry = NativeBenchmarkTelemetry::instance();
  if (telemetry.enabled()) {
    telemetry_ = &telemetry;
  }
  startPlaybackMetrics();
  // Playing media is a user-initiated activity even when WAM is not the
  // frontmost application. Track the transport with the platform assertion so
  // the display never idle-sleeps into the screen saver over playing video and
  // so App Nap never throttles an occluded or background playback session. The
  // signal is the single choke point for every transport source: native route,
  // compatibility route, end of file and idle. Edge-triggering on this
  // window's own hold is what makes each window contribute at most one to the
  // process-wide reference count.
  activityConnection_ = QObject::connect(
      &controller_, &PlayerController::playingChanged, &controller_, [this] {
        const bool holding = controller_.playing();
        if (holding == activityHeld_)
          return;
        activityHeld_ = holding;
        setMacosPlaybackActivityHeld(holding);
      });
}

NativePlaybackOwner::SeekDisposition
NativePlaybackOwner::commitSeek(double targetSeconds, std::uint64_t gesture,
                                std::uint64_t request, bool paused) {
  // The one seconds -> exact conversion on the native seek path. A value with
  // no exact form reaches the router as an invalid time and is refused there,
  // after the route-ownership check.
  return macos::NativePlaybackOwner::commitSeek(
      ::wam::media::exactNonnegativeMediaTime(targetSeconds)
          .value_or(::wam::media::MediaTime{}),
      gesture, request, paused);
}

bool NativePlaybackOwner::presentsOutsideScene() const noexcept {
  return ::wam::macos::NativeEmbeddingSupport::layerActive() &&
         nativeOwnsTransport();
}

void NativePlaybackOwner::noteFallbackSeek(bool submitted) noexcept {
  if (telemetry_)
    telemetry_->fallbackSeek(submitted);
}

void NativePlaybackOwner::notePreviewDemanded(std::uint64_t gesture,
                                              std::uint64_t request,
                                              double target,
                                              bool fallbackInitialized) noexcept {
  if (telemetry_)
    telemetry_->previewDemanded(native_protocol::GestureId{gesture},
                                native_protocol::RequestId{request}, target,
                                fallbackInitialized);
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
  if (hasNativeSession()) {
    const ::wam::macos::NativeMediaSessionMetrics sampled =
        nativeMetrics();
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
    sample.clockRate = controller_.rate();
    sample.hasVideo = sampled.videoValid;
    sample.hasAudio = sampled.audioValid;
    sample.hasClock = sampled.clockValid;
    sample.paused = controller_.paused();
  } else if (acceptsFallbackPlaybackEvents()) {
    sample = controller_.mpv_.metrics();
  }
  // Unavailable audio/drop counters stay null; no time/fps estimate is used
  // as a substitute for frames actually rendered by the compatibility host.
  static_cast<void>(metrics.write(sample));
}

NativePlaybackOwner::~NativePlaybackOwner() {
  QObject::disconnect(activityConnection_);
  openPreflight_.stop();
  latestOpenPreflightRequest_ = 0;
  retireNativeSession();
  if (activityHeld_)
    setMacosPlaybackActivityHeld(false);
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
  const playback_router::Snapshot snapshot = routeSnapshot();
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
  // Seed the router with the controller's cached speed before the open is
  // routed. Rate is a session preference that survives a file change (the
  // compatibility engine restores it the same way), and a speed the user set
  // while the compatibility engine owned transport must not silently become
  // 1x the moment a file routes native. Outside NativeActive this only
  // retains the intent, which is exactly what the later Start consumes.
  static_cast<void>(routeSetRate(controller_.rate()));
  // The pitch preference is seeded on the same terms, and for the same
  // reason: it is a persisted application setting, not per-file state, so a
  // file that routes native must not silently revert it to the default.
  static_cast<void>(
      routeSetPreservePitch(controller_.preservePitch()));
  const auto request = openPreflight_.enqueue(
      {*sourceKey, source, initialPositionSeconds, paused,
       !surfaceLost_ && surface_ != nullptr &&
           controller_.nativeRouteAdmissionAllowed()});
  if (!request.has_value()) {
    return false;
  }
  sourceFailureDetail_.clear();
  latestOpenPreflightRequest_ = *request;
  if (telemetry_ != nullptr) {
    telemetry_->openRequested(*sourceKey, controller_.engineReady());
  }
  return true;
}

void NativePlaybackOwner::completeOpenPreflight(
    NativeOpenPreflightResult result) {
  WAM_STARTUP_STAMP(PreflightDelivered);
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  if (result.requestId == 0 ||
      result.requestId != latestOpenPreflightRequest_) {
    return;
  }
  if (deferOwnerCommand([this, result] { completeOpenPreflight(result); })) return;
  drainCurrentObservations();
  if (result.requestId != latestOpenPreflightRequest_) {
    return;
  }

  SourceRecord record;
  record.url = std::move(result.canonicalSource);
  record.localPath = std::move(result.absoluteLocalPath);
  record.initialPosition = std::move(result.initialPosition);
  record.sourceClass = result.sourceClass;
  sourceFailureDetail_.clear();
  const QUrl routedSource = record.url;
  WAM_STARTUP_STAMP(RouteIntentBegin);
  controller_.prepareRoutedOpenIntent(routedSource);
  WAM_STARTUP_STAMP(RouteIntentEnd);
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
      routeOpen({result.sourceKey, result.route,
                    result.initialPositionSeconds, result.paused});
  if (!applied(transition)) {
    sources_.erase(result.sourceKey.value);
    controller_.setLastError(
        QStringLiteral("Unable to route the playback request."));
    return;
  }
  execute(transition);
}

bool NativePlaybackOwner::stop() {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  openPreflight_.cancel();
  latestOpenPreflightRequest_ = 0;
  if (deferOwnerCommand([this] { static_cast<void>(stop()); }))
    return true;
  drainCurrentObservations();
  const playback_router::Transition transition = routeStop();
  if (!applied(transition)) {
    controller_.setLastError(
        QStringLiteral("Unable to stop the active playback route."));
    return false;
  }
  execute(transition);
  controller_.finishStopUi(false);
  return true;
}

NativePlaybackOwner::PauseDisposition
NativePlaybackOwner::setPaused(bool paused) {
  Q_ASSERT(QThread::currentThread() == controller_.thread());
  drainCurrentObservations();

  const playback_router::State before = routeSnapshot().state;
  if (before == playback_router::State::Idle) {
    return PauseDisposition::NotOwned;
  }
  const playback_router::Transition transition =
      routeSetPaused(paused);
  if (!applied(transition)) {
    controller_.setLastError(
        QStringLiteral("Unable to change the playback state."));
    return nativeOwnsTransport() ? PauseDisposition::NativeHandled
                                 : PauseDisposition::FallbackHandled;
  }

  if (nativeOwnsTransport()) {
    execute(transition);
    return PauseDisposition::NativeHandled;
  }

  // Preserve the existing fallback transport transaction, including EOF
  // restart and render-recovery state. The router has already retained the
  // exact intended pause value; PlayerController now applies the mpv command.
  return PauseDisposition::FallbackHandled;
}

std::optional<macos::NativePlaybackOwner::Preparation>
NativePlaybackOwner::preparationFor(native_protocol::SourceKey sourceKey) {
  const auto* record = sourceRecord(sourceKey);
  if (!record || !record->initialPosition || record->localPath.empty() || !surface_ || surfaceLost_)
    return {};
  return Preparation{record->localPath, *record->initialPosition,
      macos::qtNativePresentationFactory(&surface_->nativeVideoItem()),
      controller_.captionFeed(), static_cast<float>(controller_.volume()), controller_.muted(),
      record->sourceClass == PlaybackSourceClass::BufferedLocal};
}

std::optional<playback_router::Transition>
NativePlaybackOwner::beginFallbackCreate(
    const playback_router::Action &action) {
  if (hasNativeSession()) {
    controller_.setLastError(QStringLiteral(
        "Please wait for playback to stop, then try again."));
    return std::nullopt;
  }

  // Reserve terminal recovery before creating any fallback resource. If this
  // allocation fails, FallbackCreating can honestly fail with no mpv handle
  // admitted; once a handle exists, retirement needs no further allocation.
  if (!controller_.mpv_.reserveReplacement()) {
    controller_.setLastError(QStringLiteral(
        "Could not start playback. Please try again."));
    return routeFallbackFailed({action.fallback.stamp});
  }
  if (!controller_.initializePlaybackEngine()) {
    return routeFallbackFailed({action.fallback.stamp});
  }

  return routeFallbackCreated({action.fallback.stamp});
}

bool NativePlaybackOwner::beginFallbackOpen(
    const playback_router::Action &action) {
  const SourceRecord *record = sourceRecord(action.fallback.sourceKey);
  if (record == nullptr || !controller_.engineReady()) {
    controller_.setLastError(
        QStringLiteral("Could not open the file. Please try again."));
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
        "Could not stop playback. Please try again."));
    return false;
  }

  fallbackStop_ = FallbackStop{action.fallback, controller_.mpv_.core};
  controller_.mpv_.revokeRendering();
  controller_.requestVideoUpdate();
  return submitFallbackStop();
}

bool NativePlaybackOwner::submitFallbackStop() {
  if (!fallbackStop_.has_value() || !controller_.engineReady() ||
      fallbackStop_->core != controller_.mpv_.core ||
      fallbackStop_->submissions >= kMaximumFallbackStopSubmissions) {
    exhaustFallbackStop(QStringLiteral(
        "Playback did not stop."));
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

  if (!controller_.mpv_.submitStop(kFallbackStopReplyNamespace |
                                   nextFallbackStopReplyId_)) {
    if (fallbackStop_->submissions < kMaximumFallbackStopSubmissions)
      return submitFallbackStop();
    exhaustFallbackStop(QStringLiteral(
        "Could not stop playback."));
    return false;
  }
  const QPointer<PlayerController> controller = &controller_;
  const std::uint64_t replyId = fallbackStop_->replyId;
  QTimer::singleShot(
      kFallbackStopWatchdogMilliseconds, &controller_, [controller, replyId] {
        if (controller == nullptr || !controller->native_)
          return;
        auto &owner = static_cast<NativePlaybackOwner &>(*controller->native_);
        if (!owner.fallbackStop_.has_value() ||
            owner.fallbackStop_->replyId != replyId ||
            owner.fallbackStop_->terminalResetRequired) {
          return;
        }
        owner.exhaustFallbackStop(QStringLiteral(
            "Playback took too long to stop."));
      });
  return true;
}

void NativePlaybackOwner::exhaustFallbackStop(const QString &detail) {
  if (!fallbackStop_.has_value())
    return;
  fallbackStop_->terminalResetRequired = true;
  fallbackStop_->commandReplied = false;
  fallbackStop_->idleObserved = false;
  qWarning().noquote() << "WAM:" << detail;
  controller_.setLastError(QStringLiteral("Playback stopped responding. Please open the file again."));
  maybeCompleteFallbackStop();
}

void NativePlaybackOwner::publishDiagnostic(
    const macos::NativeMediaSessionDiagnostic &diagnostic) {
  // Keep low-level diagnostics in the log; retain actionable file damage
  // separately so a generic fallback decoder error cannot erase it.
  if (diagnostic.refusal == media::MediaRefusalClass::MissingInitialization)
    sourceFailureDetail_ = QStringLiteral("This recording is incomplete: information needed to open it is missing.");
}

QString NativePlaybackOwner::playbackFailureText(const QString &fallback) const {
  return sourceFailureDetail_.isEmpty() ? fallback : sourceFailureDetail_;
}

void NativePlaybackOwner::publishLifecycle(
    const macos::NativeMediaSessionFact &fact, bool admissionRouteChoice) {
  std::visit(
      [this, admissionRouteChoice](const auto &event) {
        using Event = std::decay_t<decltype(event)>;
        if constexpr (std::is_same_v<Event, native_protocol::Prepared>) {
          if (telemetry_ != nullptr) {
            telemetry_->prepared(event, controller_.engineReady());
          }
          // The base owner submits Start before calling here, i.e. before any
          // synchronous QML-facing signal below. durationChanged may
          // immediately issue a resume seek; the session
          // supports CommitSeek from Starting only after this subordinate
          // Start command has been physically admitted.
          const SourceRecord *record = sourceRecord(event.sourceKey);
          if (record != nullptr) {
            controller_.updateSource(record->url);
            controller_.updateMediaTitle(
                QFileInfo(record->url.toLocalFile()).fileName());
          }
          // Before the duration: durationChanged may issue the resume seek,
          // and that target must already be snapped under the ceiling.
          controller_.updateNativeSeekCeiling(
              nativeSeekCeilingSeconds());
          controller_.updateDuration(event.descriptor.durationSeconds);
          // The container's own display geometry, from the backend that
          // actually demuxed it. This is the only path by which a Matroska,
          // WebM or MPEG-TS natural size can reach window geometry:
          // MacWindowChrome answers that question with an AVURLAsset, and
          // AVFoundation cannot demux any of the three, so it returns (0, 0)
          // for every one of them. Published before the QML-facing signals
          // below so that a handler reacting to the open already sees it.
          // Zero means "not stated" and updateVideoDisplaySize drops it.
          controller_.updateVideoDisplaySize(
              event.descriptor.displayWidth,
              event.descriptor.displayHeight);
          controller_.updatePause(true);
          controller_.updateIdle(false);
          controller_.updateEof(false);
          controller_.setLastError({});
        } else if constexpr (std::is_same_v<Event, native_protocol::Started>) {
          if (telemetry_ != nullptr) {
            telemetry_->started(event, controller_.engineReady());
          }
          controller_.updateLoading(false);
          controller_.updateIdle(false);
          controller_.updateEof(false);
        } else if constexpr (std::is_same_v<Event, native_protocol::Ended>) {
          const double position = std::max(0.0, event.finalPositionSeconds);
          controller_.publishSeekTarget(position);
          controller_.updatePause(true);
          controller_.updateIdle(true);
          controller_.updateEof(true);
        } else if constexpr (std::is_same_v<Event, native_protocol::Failed>) {
          // The router owns recovery. A native refusal is not a user error:
          // only failure of the final playback route is surfaced.
          Q_UNUSED(admissionRouteChoice);

        }
      },
      fact);
}

void NativePlaybackOwner::publishPreviewPresented(
    const native_protocol::PreviewPresented &presented) {
  if (telemetry_) telemetry_->previewFrameDrawn(presented, controller_.engineReady());
  controller_.nativePreviewPresented(presented);
}

void NativePlaybackOwner::publishPreviewFailed(
    const native_protocol::PreviewFailed &failed) {
  if (telemetry_) telemetry_->previewFailed(failed, controller_.engineReady());
  controller_.nativePreviewFailed(failed);
}

void NativePlaybackOwner::publishRunState(
    const macos::NativeMediaSessionRunStateApplied &appliedState) {
  const auto& command = appliedState.command;
  // A scrub captures logical post-seek intent before physically pausing the
  // native graph. Its pause acknowledgement must not make the QML transport
  // appear paused; play/pause during the gesture updates that retained intent
  // and CommitReady applies it to the promoted generation.
  if (!controller_.nativeSeekInFlight()) {
    controller_.updatePause(command.paused);
  }
  controller_.updateIdle(false);
  controller_.updateEof(false);
}

void NativePlaybackOwner::publishAudioClock(
    const native_protocol::AudioClockProof &proof) {
  const double position = std::max(0.0, proof.positionSeconds);
  controller_.publishNativeMainPosition(position);
}

void NativePlaybackOwner::publishVideoDraw(
    const native_protocol::VideoDrawProof &proof, bool first) {
  if (first && telemetry_) telemetry_->firstFrameDrawn(proof, controller_.engineReady());
  // NativeAudioSession owns the authoritative running clock internally, but
  // the public v1 proof stream emits a sampled AudioClockProof only for
  // paused transport and for video-less generations. While video is running,
  // the exact drawn frame PTS is therefore the bounded, event-driven UI
  // playhead observation.
  const double position = std::max(0.0, proof.frameStartSeconds);
  controller_.publishNativeMainPosition(position);
  // The same proof also carries this frame's own duration, which is the only
  // per-sample timing the GUI layer ever sees. Frame stepping reads it to
  // find the neighbouring sample's exact PTS under VFR; publishing it here
  // means the first "." after a pause already has a proved covering frame and
  // costs no settling commit.
  controller_.publishNativeFrameGeometry(position, proof.frameDurationSeconds);
}

void NativePlaybackOwner::commitProved(const native_protocol::CommitReady& ready, bool first) {
  if (telemetry_) {
    telemetry_->commitReady(ready, controller_.engineReady());
    if (first) telemetry_->firstFrameDrawn(ready.videoDraw, controller_.engineReady());
  }
}
void NativePlaybackOwner::publishCommitReady(
    const native_protocol::CommitReady &ready) {
  controller_.nativeCommitReady(ready);
  controller_.updateIdle(false);
  controller_.updateEof(false);
  controller_.publishSeekTarget(std::max(0.0, ready.targetSeconds));
  if (telemetry_ != nullptr) {
    static_cast<void>(telemetry_->checkpoint());
  }
}

void NativePlaybackOwner::fallbackOpenSucceeded(std::uint64_t attempt,
                                                std::uint64_t serial,
                                                std::uint64_t sourceKey) {
  execute(routeFallbackOpened(
      {{native_protocol::AttemptId{attempt}, native_protocol::Serial{serial}},
       native_protocol::SourceKey{sourceKey}}));
}

void NativePlaybackOwner::fallbackOpenFailed(std::uint64_t attempt,
                                             std::uint64_t serial,
                                             std::uint64_t sourceKey) {
  (void)sourceKey;
  execute(routeFallbackFailed(
      {{native_protocol::AttemptId{attempt}, native_protocol::Serial{serial}}}));
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
          QStringLiteral("Could not stop playback."));
    }
    return;
  }
  fallbackStop_->commandReplied = true;
  fallbackStop_->idleObserved = false;
  if (controller_.mpv_.idle()) {
    fallbackStop_->idleObserved = true;
  }
  maybeCompleteFallbackStop();
}

void NativePlaybackOwner::fallbackIdleChanged(bool idle) {
  if (!fallbackStop_.has_value() || !fallbackStop_->commandReplied || !idle ||
      fallbackStop_->core != controller_.mpv_.core) {
    return;
  }
  // Property observations are coalesced and can have been published before
  // the Stop reply. Re-read only after exact command completion so the value
  // is causally post-Stop.
  if (controller_.mpv_.idle()) {
    fallbackStop_->idleObserved = true;
  }
  maybeCompleteFallbackStop();
}

void NativePlaybackOwner::fallbackRenderStateChanged() {
  maybeCompleteFallbackStop();
}

void NativePlaybackOwner::fallbackPlaybackFailed() {
  const playback_router::Snapshot snapshot = routeSnapshot();
  if (!playback_router::fallbackPlaying(snapshot.state)) {
    return;
  }
  execute(routeFallbackFailed({{snapshot.attempt, snapshot.serial}}));
}

void NativePlaybackOwner::maybeCompleteFallbackStop() {
  if (deferFallbackCompletionWhileRouting()) {
    return;
  }
  if (!fallbackStop_.has_value() || !fallbackStop_->core ||
      fallbackStop_->core != controller_.mpv_.core ||
      !controller_.mpv_.renderingReleased()) {
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
  execute(routeFallbackStopped({command.stamp}));
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
  if (hasNativeSession()) abandonNativeSession();
}

void NativePlaybackOwner::sessionCleared() noexcept {
  controller_.updateNativeSeekCeiling(0.0);
}

void NativePlaybackOwner::surfaceNativeError(const QString &detail) {
  // Native refusals may still recover. Terminal route failures report below.
  qWarning().noquote() << "WAM:" << detail;
}

void NativePlaybackOwner::surfaceNativeError(macos::NativeOwnerError,
                                             const char* detail) {
  surfaceNativeError(QString::fromUtf8(detail));
}
void NativePlaybackOwner::ownerError(const char* detail) {
  qWarning() << "WAM:" << detail;
  controller_.finishStopUi(false);
  controller_.setLastError(QStringLiteral("Playback stopped. Please try opening the file again."));
}
void NativePlaybackOwner::ownerNotice(const char* detail) { qInfo() << "WAM:" << detail; }
void NativePlaybackOwner::seekProgress(std::uint64_t) {
  controller_.setLastNotice(QStringLiteral("Seeking…"));
}
void NativePlaybackOwner::commitFailed(std::uint64_t gesture, std::uint64_t request) {
  controller_.nativeCommitFailed(gesture, request);
}
void NativePlaybackOwner::nativeSelected(const native_protocol::Prepare& command) {
  if (telemetry_) telemetry_->nativeSelected(command, controller_.engineReady());
}
void NativePlaybackOwner::fallbackSelected(const playback_router::FallbackCommand& command) {
  if (telemetry_) telemetry_->fallbackSelected(command.stamp, command.sourceKey, controller_.engineReady());
}
void NativePlaybackOwner::previewDispatched(native_protocol::GestureId gesture, native_protocol::RequestId request, double target) {
  if (telemetry_) telemetry_->previewDispatched(gesture, request, target, controller_.engineReady());
}
void NativePlaybackOwner::previewAdmitted(const native_protocol::PreviewFrame& command) {
  if (telemetry_) telemetry_->previewAdmitted(command, controller_.engineReady());
}
void NativePlaybackOwner::commitSubmitted(const native_protocol::CommitSeek& command) {
  if (telemetry_) telemetry_->commitSeekSubmitted(command, controller_.engineReady());
}
std::optional<playback_router::Transition> NativePlaybackOwner::applyFallbackRunState(const playback_router::Action& action) {

    if (!controller_.engineReady()) {
      return routeFallbackFailed({action.fallback.stamp});
    }
    if (!controller_.mpv_.setPausedNow(action.fallback.paused)) {
      controller_.setLastError(
          QStringLiteral("Could not apply the playback "
                         "change."));
      return routeFallbackFailed({action.fallback.stamp});
    }
    controller_.updatePause(action.fallback.paused);
    return std::nullopt;

}

} // namespace wam::qt
