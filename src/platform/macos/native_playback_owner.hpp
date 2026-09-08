#pragma once
#include "media/native_seek_progress.hpp"
#include "media/playback_router.hpp"
#include "native_media_session.hpp"
#include "native_retirement.hpp"
#include "native_media_session_system.hpp"
#include <functional>

#include <memory>
#include <optional>

namespace wam::macos {
namespace playback_router = ::wam::media::playback_router;
namespace native_protocol = ::wam::media::native_playback;

// Commands and delivery are main-thread-owned; native facts cross a retained,
// capacity-one edge and never invoke the owner on the session worker.
class NativePlaybackOwner {
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

  enum class PreviewHandoffDisposition : std::uint8_t {
    Prepared,
    Deferred,
    Unsupported,
  };

  NativePlaybackOwner();
  virtual ~NativePlaybackOwner();
  NativePlaybackOwner(const NativePlaybackOwner&) = delete;
  NativePlaybackOwner& operator=(const NativePlaybackOwner&) = delete;
  [[nodiscard]] PreviewHandoffDisposition preparePreviewHandoff();
  [[nodiscard]] PreviewDisposition previewFrame(double, std::uint64_t, std::uint64_t);
  [[nodiscard]] SeekDisposition commitSeek(double, std::uint64_t, std::uint64_t, bool);
  [[nodiscard]] SeekDisposition commitSeek(media::MediaTime, std::uint64_t, std::uint64_t, bool);
  [[nodiscard]] bool setGain(float);
  [[nodiscard]] bool setMuted(bool);
  [[nodiscard]] bool setRate(double);
  [[nodiscard]] bool setPreservePitch(bool);
  [[nodiscard]] bool nativeOwnsTransport() const noexcept;
  [[nodiscard]] bool fallbackOwnsTransport() const noexcept;
  [[nodiscard]] bool needsFallbackRenderContext() const noexcept;
  [[nodiscard]] bool acceptsFallbackPlaybackEvents() const noexcept;
protected:
  bool hasNativeSession() const noexcept;
  NativeMediaSessionMetrics nativeMetrics() const noexcept;
  void setNativeMetricsEnabled(bool) noexcept;
  std::shared_ptr<const media::MediaSourceDescriptor> nativeDescriptor() const noexcept;
  double nativeSeekCeilingSeconds() const noexcept;
  void drainCurrentObservations();
  struct ObservationBridge {
    NativePlaybackOwner* owner{nullptr};
    std::uint64_t epoch{0};
  };
  [[nodiscard]] playback_router::Tick nextTick() noexcept;
  void refreshNativePhaseWatchdog();
  void expireNativePhaseWatchdog(std::uint64_t);
  void execute(playback_router::Transition);
  std::optional<playback_router::Transition> executeAction(const playback_router::Action&);
  std::optional<playback_router::Transition> rejectNativeCommand(native_protocol::Stamp);
  static bool queueObservations(std::shared_ptr<void>, void*) noexcept;
  void drainObservations(std::uint64_t);
  void consumeObservations(NativeMediaSessionObservations);
  bool exactCurrent(native_protocol::Stamp, native_protocol::Generation) const noexcept;
  void clearNativePreview() noexcept;
  void clearNativeCommit(bool) noexcept;

  struct Preparation {
    std::filesystem::path path;
    NativeMediaSessionInitialPosition initialPosition;
    NativeMediaSessionPresentationFactory presentation;
    std::shared_ptr<media::captions::LiveCaptionFeed> captionFeed;
    float gain{1};
    bool muted{false};
  };
  std::optional<playback_router::Transition> beginNativePrepare(const playback_router::Action&);
  virtual std::optional<Preparation> preparationFor(native_protocol::SourceKey) = 0;
  virtual std::optional<playback_router::Transition> beginFallbackCreate(const playback_router::Action&) = 0;
  virtual bool beginFallbackOpen(const playback_router::Action&) = 0;
  virtual bool beginFallbackStop(const playback_router::Action&) = 0;
  virtual std::optional<playback_router::Transition> applyFallbackRunState(const playback_router::Action&) = 0;
  virtual void pruneSourceRecords() = 0;
  virtual void maybeCompleteFallbackStop() = 0;
  void clearNativeSession() noexcept;
  void retireNativeSession(std::function<void()> continuation = {});
  void abandonNativeSession();
  bool retirementPending() const noexcept;
  bool deferOwnerCommand(std::function<void()> command);
  virtual void sessionCleared() noexcept = 0;
  virtual void publishExactDraw(const NativeMediaSessionExactDraw&) {}
  virtual void publishDiagnostic(const NativeMediaSessionDiagnostic&) {}
  virtual void surfaceNativeError(const char*) = 0;
  virtual void ownerError(const char*) = 0;
  virtual void ownerNotice(const char*) = 0;
  virtual void seekProgress(std::uint64_t) = 0;
  virtual void commitFailed(std::uint64_t, std::uint64_t) = 0;
  virtual void nativeSelected(const native_protocol::Prepare&) {}
  virtual void fallbackSelected(const playback_router::FallbackCommand&) {}
  virtual void previewDispatched(native_protocol::GestureId, native_protocol::RequestId, double) {}
  virtual void previewAdmitted(const native_protocol::PreviewFrame&) {}
  virtual void commitSubmitted(const native_protocol::CommitSeek&) {}
  void consumeLifecycle(const NativeMediaSessionFact&, bool);
  virtual void publishLifecycle(const NativeMediaSessionFact&, bool) = 0;
  void consumeRunState(const NativeMediaSessionRunStateApplied&);
  virtual void publishRunState(const NativeMediaSessionRunStateApplied&) = 0;
  void consumeAudioClock(const native_protocol::AudioClockProof&);
  virtual void publishAudioClock(const native_protocol::AudioClockProof&) = 0;
  void consumeVideoDraw(const native_protocol::VideoDrawProof&);
  virtual void publishVideoDraw(const native_protocol::VideoDrawProof&, bool) = 0;
  void consumePreviewPresented(const native_protocol::PreviewPresented&);
  virtual void publishPreviewPresented(const native_protocol::PreviewPresented&) = 0;
  void consumePreviewFailed(const native_protocol::PreviewFailed&);
  virtual void publishPreviewFailed(const native_protocol::PreviewFailed&) = 0;
  void consumeCommitReady(const native_protocol::CommitReady&);
  void consumeExactCommitReady(const native_protocol::ExactCommitReady&);
  virtual void publishExactCommitReady(const native_protocol::ExactCommitReady&) {}
  virtual void commitProved(const native_protocol::CommitReady&, bool) {}
  virtual void publishCommitReady(const native_protocol::CommitReady&) = 0;

  static constexpr std::uint64_t kNativePhaseTickBudget = 1'000'000;
  playback_router::PlaybackRouter router_{
      playback_router::TimeoutPolicy{kNativePhaseTickBudget, kNativePhaseTickBudget,
                                     kNativePhaseTickBudget, kNativePhaseTickBudget}};
  std::optional<NativePreviewFrameTarget> nativePreviewTarget_;
  std::optional<native_protocol::PreviewFrame> nativePreview_;
  std::optional<NativeMediaSessionCommitTarget> nativeCommitTarget_;
  std::optional<media::MediaTime> nativeExactCommitTarget_;
  std::optional<native_protocol::CommitSeek> nativeCommit_;
  std::optional<native_protocol::Stop> nativeStop_;
  std::uint64_t nextObservationEpoch_{0};
  std::uint64_t tick_{0};
  std::uint64_t lastAudioProofSerial_{0};
  std::uint64_t lastVideoDrawSequence_{0};
  std::uint64_t nativePreviewGesture_{0};
  std::uint64_t nativePreviewSubmissionEpoch_{0};
  std::uint64_t nativeCommitDrawBaseline_{0};
  std::uint64_t nativePhaseWatchdogEpoch_{0};
  bool nativePhaseWatchdogArmed_{false};
  media::SeekProgressDeadline nativeSeekProgress_{};
  bool firstNativeDrawReported_{false};
  PreviewDisposition nativePreviewDisposition_{PreviewDisposition::Rejected};
  bool nativeCommitDispatchAccepted_{false};
  unsigned executeDepth_{0};
  unsigned fallbackEventDrainDepth_{0};
  bool fallbackCompletionDeferred_{false};
private:
  std::shared_ptr<NativeMediaSession> nativeSession_;
  std::shared_ptr<ObservationBridge> observationBridge_;
  SeekDisposition commitSeekImpl(double, std::optional<media::MediaTime>, std::uint64_t, std::uint64_t, bool);
  std::shared_ptr<ObservationBridge> ownerLifetime_;
  std::shared_ptr<NativeRetirement> retirement_;
  std::function<void()> retirementContinuation_;
  std::function<void()> deferredOwnerCommand_;
  void retirementFinished();
};
}
