#pragma once

#include "media/playback_router.hpp"
#include "platform/macos/native_media_session.hpp"
#include "platform/macos/native_preview_frame_lane.hpp"
#include "qt/native_open_preflight.hpp"

#include <QPointer>
#include <QTimer>
#include <QUrl>

#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>

namespace wam::qt {

class MpvVideoItem;
class NativeBenchmarkTelemetry;
class PlayerController;
class PlayerCore;
struct NativePlaybackOwnerTestAccess;

namespace playback_router = ::wam::media::playback_router;
namespace native_protocol = ::wam::media::native_playback;

// Holds or releases the process-wide macOS activity assertion that must be
// live for exactly as long as media is actually playing.
//
// A media player owns two AppKit-level facts while it plays. The display must
// not idle-sleep, because the screen saver would otherwise cover playing video
// after the ordinary user-idle timeout and take the window out of the on-screen
// and accessibility window lists even though playback continues. The process
// must also stay out of App Nap, because a fully occluded or non-frontmost
// application is otherwise timer-throttled and deprioritised, which is exactly
// the state a background media player runs in. NSActivityUserInitiated covers
// App Nap, idle system sleep and sudden termination; NSActivityIdleDisplaySleep
// Disabled covers the display. Calls are idempotent: only one assertion is ever
// held, and it is released on the first call with held = false.
void setMacosPlaybackActivityHeld(bool held) noexcept;

// GUI-thread owner for the mutually exclusive native and compatibility
// playback epochs on macOS. It is the only production object that translates
// NativeMediaSession facts into PlaybackRouter transitions. The native
// session never calls this object synchronously: its capacity-one edge only
// queues a later, context-bound GUI drain.
class NativePlaybackOwner final {
public:
  enum class PauseDisposition : std::uint8_t {
    NotOwned,
    NativeHandled,
    FallbackHandled,
  };

  enum class SeekDisposition : std::uint8_t {
    NotOwned,
    NativeHandled,
    NativeRejected,
    FallbackHandled,
  };

  enum class PreviewDisposition : std::uint8_t {
    NotOwned,
    Accepted,
    Replaced,
    Stale,
    Rejected,
  };

  explicit NativePlaybackOwner(PlayerController &controller);
  ~NativePlaybackOwner();

  NativePlaybackOwner(const NativePlaybackOwner &) = delete;
  NativePlaybackOwner &operator=(const NativePlaybackOwner &) = delete;

  [[nodiscard]] bool open(const QUrl &source, double initialPositionSeconds,
                          bool paused);
  [[nodiscard]] bool stop(bool preserveVisibleState = false);
  [[nodiscard]] PauseDisposition setPaused(bool paused);
  // Starts the main-video surface handoff and constructs the preview lane at
  // pointer-down. A retained Ended graph is already drained, so it prewarms
  // the lane without a second main-consumer quiesce. Refusal is deliberately
  // quiet; the final CommitSeek remains authoritative even when visual
  // preview preparation is unavailable.
  [[nodiscard]] bool preparePreviewHandoff();
  [[nodiscard]] PreviewDisposition previewFrame(double targetSeconds,
                                                std::uint64_t gesture,
                                                std::uint64_t request);
  [[nodiscard]] SeekDisposition commitSeek(double targetSeconds,
                                           std::uint64_t gesture,
                                           std::uint64_t request,
                                           bool intendedPaused);

  [[nodiscard]] bool setGain(float gain);
  [[nodiscard]] bool setMuted(bool muted);
  // Applies a pitch-preserved playback rate on the native route. False means
  // native does not own transport, so the caller must drive the
  // compatibility engine instead. True with no native session yet is a
  // retained intent, exactly like setPaused before Start.
  [[nodiscard]] bool setRate(double rate);

  [[nodiscard]] bool nativeOwnsTransport() const noexcept;
  [[nodiscard]] bool fallbackOwnsTransport() const noexcept;
  [[nodiscard]] bool needsFallbackRenderContext() const noexcept;
  [[nodiscard]] bool acceptsFallbackPlaybackEvents() const noexcept;

  // Called by the existing renderer-gated mpv transaction. These callbacks
  // carry the exact router lineage retained when OpenFallback was issued.
  void fallbackOpenSucceeded(std::uint64_t attempt, std::uint64_t serial,
                             std::uint64_t sourceKey);
  void fallbackOpenFailed(std::uint64_t attempt, std::uint64_t serial,
                          std::uint64_t sourceKey);
  void fallbackStopCommandReply(std::uint64_t replyUserdata, int error);
  void fallbackIdleChanged(bool idle);
  void fallbackRenderStateChanged();
  void fallbackPlaybackFailed();
  void beginFallbackEventDrain() noexcept;
  void endFallbackEventDrain();

  void attachSurface(MpvVideoItem *item) noexcept;
  void detachSurface(MpvVideoItem *item) noexcept;

private:
  struct SourceRecord {
    QUrl url;
    std::filesystem::path localPath;
    std::optional<::wam::macos::NativeMediaSessionInitialPosition>
        initialPosition;
    PlaybackSourceClass sourceClass{PlaybackSourceClass::Network};
  };

  struct ObservationBridge {
    QPointer<PlayerController> controller;
    std::uint64_t epoch{0};
  };

  struct FallbackStop {
    playback_router::FallbackCommand command{};
    std::shared_ptr<PlayerCore> core;
    std::uint64_t replyId{0};
    unsigned submissions{0};
    bool commandReplied{false};
    bool idleObserved{false};
    bool terminalResetRequired{false};
  };

  [[nodiscard]] playback_router::Tick nextTick() noexcept;
  // Re-evaluates the wall-clock watchdog that bounds the native phases that
  // own no timer of their own: NativePreparing, NativeStarting, NativeSeeking
  // and NativeStopping.
  void refreshNativePhaseWatchdog();
  void expireNativePhaseWatchdog(std::uint64_t epoch);
  void completeOpenPreflight(NativeOpenPreflightResult result);
  [[nodiscard]] std::optional<native_protocol::SourceKey> allocateSourceKey();
  [[nodiscard]] SourceRecord *
  sourceRecord(native_protocol::SourceKey key) noexcept;
  [[nodiscard]] const SourceRecord *
  sourceRecord(native_protocol::SourceKey key) const noexcept;
  void pruneSourceRecords();

  void execute(playback_router::Transition transition);
  [[nodiscard]] std::optional<playback_router::Transition>
  executeAction(const playback_router::Action &action);
  [[nodiscard]] std::optional<playback_router::Transition>
  beginNativePrepare(const playback_router::Action &action);
  [[nodiscard]] std::optional<playback_router::Transition>
  beginFallbackCreate(const playback_router::Action &action);
  [[nodiscard]] bool beginFallbackOpen(const playback_router::Action &action);
  [[nodiscard]] bool beginFallbackStop(const playback_router::Action &action);
  [[nodiscard]] bool submitFallbackStop();
  void exhaustFallbackStop(const QString &detail);
  [[nodiscard]] std::optional<playback_router::Transition>
  rejectNativeCommand(native_protocol::Stamp stamp);

  [[nodiscard]] static bool queueObservations(std::shared_ptr<void> lifetime,
                                              void *context) noexcept;
  void drainObservations(std::uint64_t epoch);
  void consumeObservations(
      ::wam::macos::NativeMediaSessionObservations observations);
  void consumeLifecycle(const ::wam::macos::NativeMediaSessionFact &fact);
  void consumeRunState(
      const ::wam::macos::NativeMediaSessionRunStateApplied &applied);
  void consumeAudioClock(const native_protocol::AudioClockProof &proof);
  void consumeVideoDraw(const native_protocol::VideoDrawProof &proof);
  void
  consumePreviewPresented(const native_protocol::PreviewPresented &presented);
  void consumePreviewFailed(const native_protocol::PreviewFailed &failed);
  void consumeCommitReady(const native_protocol::CommitReady &ready);

  [[nodiscard]] bool
  exactCurrent(native_protocol::Stamp stamp,
               native_protocol::Generation generation) const noexcept;
  void maybeCompleteFallbackStop();
  void clearNativePreview() noexcept;
  void clearNativeCommit(bool notifyFailure) noexcept;
  void clearNativeSession() noexcept;
  void surfaceNativeError(const QString &detail);
  // Both are no-ops unless WAM_PLAYBACK_METRICS_PATH names an absolute path.
  void startPlaybackMetrics();
  void samplePlaybackMetrics();

  // Ticks carry no implied unit. This owner drives them as an event counter,
  // so an ordinary open consumes a handful. A phase budget far above that is
  // therefore only ever crossed by the deliberate jump the wall-clock watchdog
  // performs below, never by ordinary routing traffic.
  static constexpr std::uint64_t kNativePhaseTickBudget = 1'000'000;

  PlayerController &controller_;
  QPointer<MpvVideoItem> surface_;
  playback_router::PlaybackRouter router_{
      playback_router::TimeoutPolicy{kNativePhaseTickBudget,
                                     kNativePhaseTickBudget,
                                     kNativePhaseTickBudget,
                                     kNativePhaseTickBudget}};
  std::map<std::uint64_t, SourceRecord> sources_;
  NativeOpenPreflight openPreflight_;
  std::unique_ptr<::wam::macos::NativeMediaSession> nativeSession_;
  std::optional<::wam::macos::NativePreviewFrameTarget> nativePreviewTarget_;
  std::optional<native_protocol::PreviewFrame> nativePreview_;
  std::optional<::wam::macos::NativeMediaSessionCommitTarget>
      nativeCommitTarget_;
  std::optional<native_protocol::CommitSeek> nativeCommit_;
  std::shared_ptr<ObservationBridge> observationBridge_;
  std::optional<native_protocol::Stop> nativeStop_;
  std::optional<FallbackStop> fallbackStop_;
  std::uint64_t nextSourceKey_{0};
  std::uint64_t nextObservationEpoch_{0};
  std::uint64_t nextFallbackStopReplyId_{0};
  std::uint64_t tick_{0};
  std::uint64_t lastAudioProofSerial_{0};
  std::uint64_t lastVideoDrawSequence_{0};
  std::uint64_t nativePreviewGesture_{0};
  std::uint64_t nativePreviewSubmissionEpoch_{0};
  std::uint64_t nativeCommitDrawBaseline_{0};
  std::uint64_t latestOpenPreflightRequest_{0};
  bool surfaceLost_{false};
  std::uint64_t nativePhaseWatchdogEpoch_{0};
  bool nativePhaseWatchdogArmed_{false};
  NativeBenchmarkTelemetry *telemetry_{nullptr};
  // Constructed only when the opt-in playback metrics stream is enabled.
  std::unique_ptr<QTimer> metricsTimer_;
  bool firstNativeDrawReported_{false};
  PreviewDisposition nativePreviewDisposition_{PreviewDisposition::Rejected};
  bool nativeCommitDispatchAccepted_{false};
  unsigned executeDepth_{0};
  unsigned fallbackEventDrainDepth_{0};
  bool fallbackCompletionDeferred_{false};

  friend struct NativePlaybackOwnerTestAccess;
};

} // namespace wam::qt
