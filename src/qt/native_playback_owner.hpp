#pragma once

#include "platform/macos/native_playback_owner.hpp"

#include "media/playback_router.hpp"
#include "qt/native_engine.hpp"
#include "platform/macos/native_open_preflight.hpp"
#include "qt/playback_policy.hpp"

#include <QMetaObject>

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
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY)
struct NativePlaybackOwnerTestAccess;
#endif

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
// Disabled covers the display. Only one assertion is ever held; calls are
// reference counted per holding window, and it is released when the last
// holder calls with held = false.
void setMacosPlaybackActivityHeld(bool held) noexcept;

// GUI-thread owner for the mutually exclusive native and compatibility
// playback epochs on macOS. It is the only production object that translates
// NativeMediaSession facts into PlaybackRouter transitions. The native
// session never calls this object synchronously: its capacity-one edge only
// queues a later, context-bound GUI drain.
class NativePlaybackOwner final : public macos::NativePlaybackOwner,
                                  public NativeEngine {
public:
  NativePlaybackOwner(PlayerController &controller, NativeEngineHost &host);
  ~NativePlaybackOwner();

  NativePlaybackOwner(const NativePlaybackOwner &) = delete;
  NativePlaybackOwner &operator=(const NativePlaybackOwner &) = delete;

  using PauseDisposition = NativeEngine::PauseDisposition;
  using SeekDisposition = NativeEngine::SeekDisposition;
  using PreviewDisposition = NativeEngine::PreviewDisposition;
  using PreviewHandoffDisposition = NativeEngine::PreviewHandoffDisposition;

  [[nodiscard]] bool open(const QUrl &source, double initialPositionSeconds,
                          bool paused) override;
  [[nodiscard]] bool stop() override;
  [[nodiscard]] QString
  playbackFailureText(const QString &fallback) const override;
  [[nodiscard]] PauseDisposition setPaused(bool paused) override;
  [[nodiscard]] PreviewHandoffDisposition preparePreviewHandoff() override {
    return macos::NativePlaybackOwner::preparePreviewHandoff();
  }
  [[nodiscard]] PreviewDisposition previewFrame(double target,
                                                std::uint64_t gesture,
                                                std::uint64_t request) override {
    return macos::NativePlaybackOwner::previewFrame(target, gesture, request);
  }
  [[nodiscard]] SeekDisposition commitSeek(double targetSeconds,
                                           std::uint64_t gesture,
                                           std::uint64_t request,
                                           bool paused) override;
  [[nodiscard]] bool setGain(float gain) override {
    return macos::NativePlaybackOwner::setGain(gain);
  }
  [[nodiscard]] bool setMuted(bool muted) override {
    return macos::NativePlaybackOwner::setMuted(muted);
  }
  [[nodiscard]] bool setRate(double rate) override {
    return macos::NativePlaybackOwner::setRate(rate);
  }
  [[nodiscard]] bool setPreservePitch(bool preserve) override {
    return macos::NativePlaybackOwner::setPreservePitch(preserve);
  }
  [[nodiscard]] bool nativeOwnsTransport() const noexcept override {
    return macos::NativePlaybackOwner::nativeOwnsTransport();
  }
  [[nodiscard]] bool presentsOutsideScene() const noexcept override;
  [[nodiscard]] bool needsFallbackRenderContext() const noexcept override {
    return macos::NativePlaybackOwner::needsFallbackRenderContext();
  }
  [[nodiscard]] bool acceptsFallbackPlaybackEvents() const noexcept override {
    return macos::NativePlaybackOwner::acceptsFallbackPlaybackEvents();
  }
  void fallbackOpenSucceeded(std::uint64_t attempt, std::uint64_t serial,
                             std::uint64_t sourceKey) override;
  void fallbackOpenFailed(std::uint64_t attempt, std::uint64_t serial,
                          std::uint64_t sourceKey) override;
  void fallbackStopCommandReply(std::uint64_t replyId,
                                int error) override;
  void fallbackIdleChanged(bool idle) override;
  void fallbackRenderStateChanged() override;
  void fallbackPlaybackFailed() override;
  void beginFallbackEventDrain() noexcept override {
    macos::NativePlaybackOwner::beginFallbackEventDrain();
  }
  void endFallbackEventDrain() override {
    macos::NativePlaybackOwner::endFallbackEventDrain();
  }
  void noteFallbackSeek(bool submitted) noexcept override;
  void notePreviewDemanded(std::uint64_t gesture, std::uint64_t request,
                           double target,
                           bool fallbackInitialized) noexcept override;

  void attachSurface(MpvVideoItem *item) noexcept override;
  void detachSurface(MpvVideoItem *item) noexcept override;

private:
  void publishDiagnostic(const ::wam::macos::NativeMediaSessionDiagnostic &) override;
  QString sourceFailureDetail_;

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

  void completeOpenPreflight(::wam::macos::NativeOpenPreflightResult result);
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
  void surfaceNativeError(macos::NativeOwnerError, const char* detail) override;
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
  // Both are no-ops unless WAM_PLAYBACK_METRICS_PATH names an absolute path.
  void startPlaybackMetrics();
  void samplePlaybackMetrics();

  PlayerController &controller_;
  NativeEngineHost &host_;
  // Context for this owner's own timers: destroyed with it, which cancels them.
  QObject timerContext_;
  QPointer<MpvVideoItem> surface_;
  std::map<std::uint64_t, SourceRecord> sources_;
  ::wam::macos::NativeOpenPreflight openPreflight_;
  std::optional<FallbackStop> fallbackStop_;
  std::uint64_t nextSourceKey_{0};
  std::uint64_t nextFallbackStopReplyId_{0};
  std::uint64_t latestOpenPreflightRequest_{0};
  bool surfaceLost_{false};
  NativeBenchmarkTelemetry *telemetry_{nullptr};
  // This window's hold on the process-wide activity assertion.
  QMetaObject::Connection activityConnection_;
  bool activityHeld_{false};
  // Constructed only when the opt-in playback metrics stream is enabled.
  std::unique_ptr<QTimer> metricsTimer_;

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY)
  // test_seams.cpp's `nativefail` verb injects a refusal through the router.
  friend struct NativePlaybackOwnerTestAccess;
#endif
};

} // namespace wam::qt
