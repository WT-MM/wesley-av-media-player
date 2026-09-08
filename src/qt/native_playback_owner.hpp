#pragma once

#include "platform/macos/native_playback_owner.hpp"

#include "media/playback_router.hpp"
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
class NativePlaybackOwner final : public macos::NativePlaybackOwner {
public:
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
  // Deferred and Unsupported are both quiet refusals, but they mean opposite
  // things to a caller: Deferred is "not right now" (wrong router state, a
  // handoff already in flight) and the next gesture may well succeed, while
  // Unsupported is "not for this source at all" -- an audio-only binding has
  // no frame to preview and never will, so the caller should stop demanding
  // one for the whole gesture instead of collecting a failure per sample.
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

  struct FallbackStop {
    playback_router::FallbackCommand command{};
    std::shared_ptr<PlayerCore> core;
    std::uint64_t replyId{0};
    unsigned submissions{0};
    bool commandReplied{false};
    bool idleObserved{false};
    bool terminalResetRequired{false};
  };

  // Re-evaluates the wall-clock watchdog that bounds the native phases that
  // own no timer of their own: NativePreparing, NativeStarting, NativeSeeking
  // and NativeStopping.

  void completeOpenPreflight(NativeOpenPreflightResult result);
  [[nodiscard]] std::optional<native_protocol::SourceKey> allocateSourceKey();
  [[nodiscard]] SourceRecord *
  sourceRecord(native_protocol::SourceKey key) noexcept;
  [[nodiscard]] const SourceRecord *
  sourceRecord(native_protocol::SourceKey key) const noexcept;
  void pruneSourceRecords() override;

  std::optional<Preparation> preparationFor(native_protocol::SourceKey) override;
  [[nodiscard]] std::optional<playback_router::Transition>
  beginFallbackCreate(const playback_router::Action &action) override;
  [[nodiscard]] bool beginFallbackOpen(const playback_router::Action &action) override;
  [[nodiscard]] bool beginFallbackStop(const playback_router::Action &action) override;
  [[nodiscard]] bool submitFallbackStop();
  void exhaustFallbackStop(const QString &detail);

  void publishLifecycle(const ::wam::macos::NativeMediaSessionFact &fact,
                        bool admissionRouteChoice) override;
  void publishRunState(
      const ::wam::macos::NativeMediaSessionRunStateApplied &applied) override;
  void publishAudioClock(const native_protocol::AudioClockProof &proof) override;
  void publishVideoDraw(const native_protocol::VideoDrawProof &proof, bool first) override;
  void
  publishPreviewPresented(const native_protocol::PreviewPresented &presented) override;
  void publishPreviewFailed(const native_protocol::PreviewFailed &failed) override;
  void commitProved(const native_protocol::CommitReady&, bool) override;
  void publishCommitReady(const native_protocol::CommitReady &ready) override;

  void maybeCompleteFallbackStop() override;

  void sessionCleared() noexcept override;
  void surfaceNativeError(const char* detail) override;
  void ownerError(const char* detail) override;
  void ownerNotice(const char* detail) override;
  void seekProgress(std::uint64_t frames) override;
  void commitFailed(std::uint64_t gesture, std::uint64_t request) override;
  void nativeSelected(const native_protocol::Prepare&) override;
  void fallbackSelected(const playback_router::FallbackCommand&) override;
  void previewDispatched(native_protocol::GestureId, native_protocol::RequestId, double) override;
  void previewAdmitted(const native_protocol::PreviewFrame&) override;
  void commitSubmitted(const native_protocol::CommitSeek&) override;
  std::optional<playback_router::Transition> applyFallbackRunState(const playback_router::Action&) override;
  void surfaceNativeError(const QString &detail);
  // Both are no-ops unless WAM_PLAYBACK_METRICS_PATH names an absolute path.
  void startPlaybackMetrics();
  void samplePlaybackMetrics();

  PlayerController &controller_;
  QPointer<MpvVideoItem> surface_;
  std::map<std::uint64_t, SourceRecord> sources_;
  NativeOpenPreflight openPreflight_;
  std::optional<FallbackStop> fallbackStop_;
  std::uint64_t nextSourceKey_{0};
  std::uint64_t nextFallbackStopReplyId_{0};
  std::uint64_t latestOpenPreflightRequest_{0};
  bool surfaceLost_{false};
  NativeBenchmarkTelemetry *telemetry_{nullptr};
  // Constructed only when the opt-in playback metrics stream is enabled.
  std::unique_ptr<QTimer> metricsTimer_;

  friend struct NativePlaybackOwnerTestAccess;
};

} // namespace wam::qt
