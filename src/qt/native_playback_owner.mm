#include "native_playback_owner.hpp"

#include "mpv_video_item.hpp"
#include "native_benchmark_telemetry.hpp"
#include "native_playback_metrics.hpp"
#include "native_media_session_adapter.hpp"
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
constexpr unsigned kMaximumFallbackStopSubmissions = 2;
constexpr int kFallbackStopWatchdogMilliseconds = 2'000;
// Wall-clock budget for the whole native admission path: asset load, decoder
// and audio-unit construction, first decode and the physical audio start. A
// healthy local open finishes inside a second even on a loaded machine, so
// this only ever fires on a session that has genuinely stopped progressing.

// Every predicate over playback_router::State is an exhaustive switch with no
// default arm, so appending a State makes each one a -Wswitch diagnostic
// instead of silently falling out of a boolean chain as "not this phase".

// The phases that hold a deadline: each is waiting on a proof that an
// unrendered, occluded or stalled window can fail to produce at all, so each
// is watchdogged. The rest either progress on their own or are terminal.
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

// The single retained activity token, and the count of windows currently
// asking for it.
//
// WAM is a multi-window player: two windows can be playing at once, and one of
// them pausing must NOT end the assertion the other still needs. A bare
// boolean latch did exactly that -- the display could idle-sleep and App Nap
// could throttle the process mid-playback in the window that was still
// running. One assertion, reference counted over the windows holding it, is
// the correct ownership; every caller edge-triggers (PlayerController tracks
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
  // Seed the router with the controller's cached speed before the open is
  // routed. Rate is a session preference that survives a file change (the
  // compatibility engine restores it the same way), and a speed the user set
  // while the compatibility engine owned transport must not silently become
  // 1x the moment a file routes native. Outside NativeActive this only
  // retains the intent, which is exactly what the later Start consumes.
  static_cast<void>(router_.setRate(controller_.rate(), nextTick()));
  // The pitch preference is seeded on the same terms, and for the same
  // reason: it is a persisted application setting, not per-file state, so a
  // file that routes native must not silently revert it to the default.
  static_cast<void>(
      router_.setPreservePitch(controller_.preservePitch(), nextTick()));
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
  if (deferOwnerCommand([this, result] { completeOpenPreflight(result); })) return;
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
  if (deferOwnerCommand([this, preserveVisibleState] { static_cast<void>(stop(preserveVisibleState)); }))
    return true;
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
      controller_.captionFeed(), static_cast<float>(controller_.volume_), controller_.muted_};
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

void NativePlaybackOwner::publishLifecycle(
    const macos::NativeMediaSessionFact &fact, bool admissionRouteChoice) {
  std::visit(
      [this, admissionRouteChoice](const auto &event) {
        using Event = std::decay_t<decltype(event)>;
        if constexpr (std::is_same_v<Event, native_protocol::Prepared>) {
          if (telemetry_ != nullptr) {
            telemetry_->prepared(event, controller_.engineReady());
          }
          // Submit Start before publishing any synchronous QML-facing signal.
          // durationChanged may immediately issue a resume seek; the session
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
              nativeSession_ != nullptr ? nativeSession_->seekCeilingSeconds()
                                        : 0.0);
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
              static_cast<int>(event.descriptor.displayWidth),
              static_cast<int>(event.descriptor.displayHeight));
          controller_.updatePause(true);
          controller_.updateIdle(false);
          controller_.updateEof(false);
          controller_.setLastError({});
        } else if constexpr (std::is_same_v<Event, native_protocol::Started>) {
          if (telemetry_ != nullptr) {
            telemetry_->started(event, controller_.engineReady());
          }
          controller_.updateIdle(false);
          controller_.updateEof(false);
        } else if constexpr (std::is_same_v<Event, native_protocol::Ended>) {
          const double position = std::max(0.0, event.finalPositionSeconds);
          if (std::isfinite(position) &&
              std::abs(controller_.position_ - position) > 0.0005) {
            controller_.position_ = position;
            emit controller_.positionChanged();
          }
          controller_.updatePause(true);
          controller_.updateIdle(true);
          controller_.updateEof(true);
        } else if constexpr (std::is_same_v<Event, native_protocol::Failed>) {
          if (admissionRouteChoice) {
            // Successful admission routing carries no playback-failure notice.
          } else if (nativeFailureIsInformational(event.reason)) {
            controller_.setLastNotice(nativeFailureText(event.reason));
          } else {
            controller_.setLastError(nativeFailureText(event.reason));
          }

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
  if (!controller_.native_scrub_intent_ && !controller_.native_seek_intent_) {
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
  // the public v1 proof stream intentionally emits a sampled AudioClockProof
  // only for paused transport. While running, the exact drawn frame PTS is
  // therefore the bounded, event-driven UI playhead observation.
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
  if (nativeSession_ != nullptr) abandonNativeSession();
}

void NativePlaybackOwner::sessionCleared() noexcept {
  controller_.updateNativeSeekCeiling(0.0);
}

void NativePlaybackOwner::surfaceNativeError(const QString &detail) {
  controller_.setLastError(detail);
}

void NativePlaybackOwner::surfaceNativeError(const char* detail) {
  surfaceNativeError(QString::fromUtf8(detail));
}
void NativePlaybackOwner::ownerError(const char* detail) { controller_.setLastError(QString::fromUtf8(detail)); }
void NativePlaybackOwner::ownerNotice(const char* detail) { controller_.setLastNotice(QString::fromUtf8(detail)); }
void NativePlaybackOwner::seekProgress(std::uint64_t frames) {
  controller_.setLastNotice(QStringLiteral("Seeking: decoded %1 preroll frames").arg(frames));
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

} // namespace wam::qt
