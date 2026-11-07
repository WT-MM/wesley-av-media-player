#pragma once

#include "media/playback_router.hpp"
#include "qt/playback_policy.hpp"

#include <QString>
#include <QUrl>

#include <cstdint>
#include <memory>

namespace wam::qt {

class MpvEngine;
class MpvVideoItem;
class PlayerCore;

// The native (AVFoundation/VideoToolbox) engine as PlayerController sees it.
// On macOS NativePlaybackOwner implements it and also routes each open
// between it and the controller's MpvEngine; builds without native playback
// have none, and the controller drives MpvEngine alone. Every transport verb
// answers whether the native engine took it, so the controller falls through
// to MpvEngine only when it did not.
class NativeEngine {
public:
  using PauseDisposition = ::wam::media::playback_router::PauseDisposition;
  using SeekDisposition = ::wam::media::playback_router::SeekDisposition;
  using PreviewDisposition = ::wam::media::playback_router::PreviewDisposition;
  using PreviewHandoffDisposition =
      ::wam::media::playback_router::PreviewHandoffDisposition;

  virtual ~NativeEngine() = default;

  [[nodiscard]] virtual bool open(const QUrl &source,
                                  double initialPositionSeconds,
                                  bool paused) = 0;
  [[nodiscard]] virtual bool stop() = 0;
  [[nodiscard]] virtual PauseDisposition setPaused(bool paused) = 0;
  [[nodiscard]] virtual PreviewHandoffDisposition preparePreviewHandoff() = 0;
  [[nodiscard]] virtual PreviewDisposition
  previewFrame(double target, std::uint64_t gesture, std::uint64_t request) = 0;
  // A target with no exact media-time form is refused, after the
  // route-ownership check.
  [[nodiscard]] virtual SeekDisposition commitSeek(double targetSeconds,
                                                   std::uint64_t gesture,
                                                   std::uint64_t request,
                                                   bool paused) = 0;
  [[nodiscard]] virtual bool setGain(float gain) = 0;
  [[nodiscard]] virtual bool setMuted(bool muted) = 0;
  [[nodiscard]] virtual bool setRate(double rate) = 0;
  [[nodiscard]] virtual bool setPreservePitch(bool preserve) = 0;

  // The one statement of "the native engine owns this window's transport".
  [[nodiscard]] virtual bool nativeOwnsTransport() const noexcept = 0;
  // True while the native engine owns transport AND presents on the layer
  // route, where the frame never passes through the Qt scene.
  [[nodiscard]] virtual bool presentsOutsideScene() const noexcept = 0;
  [[nodiscard]] virtual bool needsFallbackRenderContext() const noexcept = 0;
  [[nodiscard]] virtual bool acceptsFallbackPlaybackEvents() const noexcept = 0;
  [[nodiscard]] virtual QString
  playbackFailureText(const QString &fallback) const = 0;
  virtual void attachSurface(MpvVideoItem *item) noexcept = 0;
  virtual void detachSurface(MpvVideoItem *item) noexcept = 0;

  // MpvEngine facts the router waits on.
  virtual void fallbackOpenSucceeded(std::uint64_t attempt,
                                     std::uint64_t serial,
                                     std::uint64_t sourceKey) = 0;
  virtual void fallbackOpenFailed(std::uint64_t attempt, std::uint64_t serial,
                                  std::uint64_t sourceKey) = 0;
  // `replyId` is the MpvReply::FallbackStop command id.
  virtual void fallbackStopCommandReply(std::uint64_t replyId, int error) = 0;
  virtual void fallbackIdleChanged(bool idle) = 0;
  virtual void fallbackRenderStateChanged() = 0;
  virtual void fallbackPlaybackFailed() = 0;
  // Brackets a synchronous drain of MpvEngine events.
  virtual void beginFallbackEventDrain() noexcept = 0;
  virtual void endFallbackEventDrain() = 0;

  // Benchmark telemetry; no-ops unless it is armed.
  virtual void noteFallbackSeek(bool submitted) noexcept = 0;
  virtual void notePreviewDemanded(std::uint64_t gesture,
                                   std::uint64_t request, double target,
                                   bool fallbackInitialized) noexcept = 0;
};

// What the native router may do to its PlayerController: the controller's
// whole surface toward NativePlaybackOwner. Publishing facts it observed,
// driving the native seek/preview intents, and handing an open to MpvEngine.
class NativeEngineHost {
public:
  [[nodiscard]] virtual bool engineReady() const = 0;
  virtual bool initializePlaybackEngine() = 0;
  [[nodiscard]] virtual MpvEngine &mpvEngine() noexcept = 0;
  virtual void requestVideoUpdate() = 0;

  // Routed opens.
  [[nodiscard]] virtual bool nativeRouteAdmissionAllowed() const noexcept = 0;
  virtual void prepareRoutedOpenIntent(const QUrl &source) = 0;
  [[nodiscard]] virtual bool
  beginRoutedFallbackOpen(const QUrl &source, std::uint64_t attempt,
                          std::uint64_t serial, std::uint64_t source_key,
                          bool paused, PlaybackSourceClass source_class) = 0;
  [[nodiscard]] virtual bool resetRoutedFallbackCoreAfterRelease(
      const std::shared_ptr<PlayerCore> &expected_core) = 0;
  virtual void finishStopUi(bool stop_compatibility_engine) = 0;

  // Observed state.
  virtual void updatePause(bool paused) = 0;
  virtual void updateIdle(bool idle) = 0;
  virtual void updateLoading(bool loading) = 0;
  virtual void updateEof(bool eof_reached) = 0;
  virtual void updateDuration(double duration) = 0;
  virtual void updateNativeSeekCeiling(double seconds) = 0;
  virtual void updateVideoFacts(media::MediaRational width,
                                media::MediaRational height, bool hdr) = 0;
  virtual void updateSource(const QUrl &source) = 0;
  virtual void updateMediaTitle(const QString &title) = 0;
  virtual void setLastError(const QString &error) = 0;
  virtual void setLastNotice(const QString &notice) = 0;

  // Native seek and preview intents.
  [[nodiscard]] virtual bool nativeSeekInFlight() const noexcept = 0;
  virtual void publishNativeMainPosition(double position) = 0;
  virtual void publishNativeFrameGeometry(double start_seconds,
                                          double duration_seconds) = 0;
  virtual void updatePosition(double position) = 0;
  virtual void nativePreviewPresented(
      const ::wam::media::native_playback::PreviewPresented &presented) = 0;
  virtual void nativePreviewFailed(
      const ::wam::media::native_playback::PreviewFailed &failed) = 0;
  virtual void
  nativeCommitReady(const ::wam::media::native_playback::CommitReady &ready) = 0;
  virtual void nativeCommitFailed(std::uint64_t gesture,
                                  std::uint64_t request) noexcept = 0;

protected:
  ~NativeEngineHost() = default;
};

} // namespace wam::qt
