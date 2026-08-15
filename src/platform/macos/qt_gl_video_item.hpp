#pragma once

#include "native_video_presenter.hpp"

#include <QQuickItem>
#include <QString>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <type_traits>

namespace wam::macos {

struct QtGlFatalErrorSerialState;
struct QtGlRenderProgressState;

// Copyable read-only handle for render-thread failure polling. The opaque
// atomic state is shared independently of QObject lifetime; only the
// presenter can publish a new serial.
class QtGlFatalErrorSerialToken final {
 public:
  QtGlFatalErrorSerialToken() noexcept = default;
  [[nodiscard]] std::uint64_t load() const noexcept;

 private:
  explicit QtGlFatalErrorSerialToken(
      std::shared_ptr<const QtGlFatalErrorSerialState> state) noexcept;

  std::shared_ptr<const QtGlFatalErrorSerialState> state_;
  friend class QtGlVideoItem;
};

// Identity supplied by the one-credit native output adapter. Both fields are
// either zero (an untracked legacy submission) or nonzero. deliverySequence
// is unique for the adapter lifetime; frameSequence is the exact caller-owned
// identity used to reject redraw/PTS substitution as delivery progress.
struct QtGlFrameIdentity {
  std::uint64_t deliverySequence{0};
  std::uint64_t frameSequence{0};
};

// Fence-created draw proof. This means glDrawArrays succeeded, a covering GL
// fence was created and flushed, and the frame generation was still accepted
// when the proof linearized. It does not claim that the GPU fence signalled.
struct QtGlDrawEvent {
  std::uint64_t drawSequence{0};
  std::uint64_t deliverySequence{0};
  std::uint64_t frameSequence{0};
  std::uint64_t generation{0};
  CMTime presentationTime{kCMTimeInvalid};
  CMTime duration{kCMTimeInvalid};
};

// Render-side generation proof. Publication follows suppression of the old
// slot and transfer of every old GL name, fence, and FrameLease to bounded
// retirement ownership. It never waits for the GPU fence to signal.
struct QtGlGenerationInvalidatedEvent {
  std::uint64_t eventSequence{0};
  std::uint64_t generation{0};
};

// Terminal non-draw fact for a tracked delivery whose accounting token or
// IOSurface import was rejected. This is deliberately distinct from a draw
// acknowledgement; the retained previous slot may continue to redraw.
struct QtGlFrameRejectedEvent {
  std::uint64_t eventSequence{0};
  std::uint64_t deliverySequence{0};
  std::uint64_t frameSequence{0};
  std::uint64_t generation{0};
};

// Copyable, read-only access to the allocation-free render mailboxes. Loading
// performs atomic snapshots only and is safe in QQuickWindow::afterRendering.
class QtGlRenderProgressToken final {
 public:
  QtGlRenderProgressToken() noexcept = default;
  [[nodiscard]] std::optional<QtGlDrawEvent> drawAfter(
      std::uint64_t observedSequence) const noexcept;
  [[nodiscard]] std::optional<QtGlGenerationInvalidatedEvent>
  invalidationAfter(std::uint64_t observedSequence) const noexcept;
  [[nodiscard]] std::optional<QtGlFrameRejectedEvent> rejectionAfter(
      std::uint64_t observedSequence) const noexcept;

 private:
  explicit QtGlRenderProgressToken(
      std::shared_ptr<const QtGlRenderProgressState> state) noexcept;

  std::shared_ptr<const QtGlRenderProgressState> state_;
  friend class QtGlVideoItem;
};

struct QtGlVideoItemStats {
  std::uint64_t submittedFrames{0};
  std::uint64_t importedFrames{0};
  std::uint64_t renderedFrames{0};
  std::uint64_t lastRenderedGeneration{0};
  std::uint64_t acceptedGeneration{0};
  std::uint64_t acceptedRenderedFrames{0};
  std::uint64_t fatalErrorSerial{0};
  std::uint64_t lastDrawSequence{0};
  std::uint64_t lastDrawDeliverySequence{0};
  std::uint64_t renderInvalidationSequence{0};
  std::uint64_t renderInvalidatedGeneration{0};
  std::uint64_t renderRejectionSequence{0};
  std::uint64_t backpressuredImports{0};
  std::uint64_t rejectedFrames{0};
  std::uint64_t staleFrames{0};
  std::uint64_t destroyedResourceSets{0};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::uint64_t textureParameterCalls{0};
  std::uint64_t drawFramebufferBindingQueries{0};
#endif
  std::size_t activeResourceSets{0};
  std::size_t peakActiveResourceSets{0};
  std::size_t pendingRetirements{0};
  OSType lastPixelFormat{0};
  bool exactSourceIOSurface{false};
  bool textureRectangleSupported{false};
  bool textureRgSupported{false};
  bool acceleratedContext{false};
  bool renderedIntoNonDefaultFramebuffer{false};
  bool sawScissorClip{false};
  bool sawStencilClip{false};
  bool retirementFailed{false};
  QString lastError;
};

// Atomic, allocation-free native-memory population facts. This intentionally
// excludes QString diagnostics and cumulative work counters. Quarantine is a
// process-lifetime owner, so its current counts are also its high-water counts.
struct QtGlVideoItemMemoryFacts {
  std::size_t latestFrames{0};
  std::size_t currentResourceSets{0};
  std::size_t peakResourceSets{0};
  std::size_t currentRetirementJobs{0};
  std::size_t peakRetirementJobs{0};
  std::size_t quarantinedFrames{0};
  std::size_t quarantinedResourceSets{0};
  std::size_t quarantinedJobs{0};
  std::size_t poisonedSubsystems{0};
};
static_assert(std::is_trivially_copyable_v<QtGlVideoItemMemoryFacts>);

// Default-off Qt Quick integration for IOSurface-backed VideoToolbox output.
// It deliberately uses Qt's existing OpenGL scene-graph backend so the
// shipping libmpv fallback does not need a cross-API copy. The node binds the
// IOSurface's NV12/P010 planes as GL_TEXTURE_RECTANGLE views and converts YUV
// directly into Qt's active render target in one draw.
//
// The item is never registered or selected by default WAM. The explicit
// activation build option can compile it without creating a runtime owner.
// submitFrame() belongs on the GUI thread. OpenGL imports, draws, fences, and
// destruction happen on the scene-graph render thread or the private shared-
// context retirement service.
class QtGlVideoItem final : public QQuickItem {
  Q_OBJECT

 public:
  struct SharedState;

  explicit QtGlVideoItem(QQuickItem* parent = nullptr);
  ~QtGlVideoItem() override;

  // Capacity-one handoff: a newer frame replaces a pending frame that has not
  // yet been consumed by the render thread. The last accepted lease is also
  // retained so paused playback survives scene-graph recreation.
  void submitFrame(FrameLease frame);
  // Same GUI-thread handoff with exact output/caller identity. A successful
  // first draw publishes one event; retained-frame redraws publish none.
  void submitTrackedFrame(FrameLease frame, QtGlFrameIdentity identity);
  // Atomically advances the accepted timeline and clears the retained frame.
  // A stale frame submitted by an asynchronous pre-seek callback is rejected,
  // and a recreated scene graph cannot resurrect the old generation.
  void flush(std::uint64_t nextGeneration) noexcept;
  [[nodiscard]] QtGlVideoItemStats stats() const;
  // Safe from GUI, render, or retirement threads: this samples atomics only
  // and does not touch QObject or the GUI-owned latest-frame optional.
  [[nodiscard]] QtGlVideoItemMemoryFacts memoryFacts() const noexcept;
  // Acquire on the item's owning/GUI thread. Copies of the returned token and
  // load() itself are safe on the scene-graph render thread.
  [[nodiscard]] QtGlFatalErrorSerialToken fatalErrorSerialToken()
      const noexcept;
  [[nodiscard]] QtGlRenderProgressToken renderProgressToken()
      const noexcept;
  // Fatal presenter failures are first-wins until consumed. The serial never
  // resets, so a polling controller can distinguish a newly latched failure
  // from an already handled one without allocating on the blank-player path.
  [[nodiscard]] std::optional<QString> takeFatalError();

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  // Deterministic fail-closed seam for the isolated hardware gate.
  void failNextImportForTesting();
  void failSecondPlaneImportForTesting();
  void failAfterRetirementServiceCreationForTesting();
  void failNextRetirementJobReservationForTesting();
  void failNextRetirementEnqueueForTesting();
  void failNextRetirementWorkerPollForTesting();
  void failAfterFenceCreationForTesting();
  void failNextSynchronizationForTesting();
  void failNextUpdatePaintNodeForTesting();
  // Atomically publishes both sides of the adapter's rejection-versus-flush
  // race without relying on scene-graph scheduling order.
  void publishTrackedRejectionForTesting(
      QtGlFrameIdentity identity, std::uint64_t generation,
      std::uint64_t timelineSerial) noexcept;
  void publishRenderInvalidationForTesting(
      std::uint64_t generation) noexcept;
  void holdRetirementServiceStartingForTesting(bool hold);
  // Exercises the teardown path without depending on GPU scheduling luck.
  void holdRetirementsForTesting(bool hold);
  // Pauses a dequeued retirement after ownership transfer but before either
  // destruction or fail-closed quarantine publication.
  void holdRetirementCompletionForTesting(bool hold) noexcept;
  [[nodiscard]] bool retirementCompletionHeldForTesting() const noexcept;
  // Forces the impossible no-service teardown branch. The gate verifies that
  // its IOSurface lease is quarantined rather than released unsafely.
  void strandRetirementServiceForTesting();
  [[nodiscard]] static std::size_t quarantinedJobsForTesting() noexcept;
  [[nodiscard]] static std::size_t
  quarantinedResourceSetsForTesting() noexcept;
  [[nodiscard]] static std::size_t
  quarantinedFramesForTesting() noexcept;
  [[nodiscard]] static std::size_t retirementServiceCountForTesting() noexcept;
  [[nodiscard]] static std::size_t
  retirementServiceCapacityForTesting() noexcept;
  [[nodiscard]] static bool nativeGlSubsystemPoisonedForTesting() noexcept;
  [[nodiscard]] std::uint64_t
  transferredCoveringFencesForTesting() const noexcept;
  // Proves VAO names are deleted only in their exact origin CGL context,
  // including same-share-group and different-share-group collisions.
  [[nodiscard]] static bool verifyContextLocalVaoPolicyForTesting();
  // Proves both sampler-capable state preservation and the true-3.2 path that
  // must not query or bind sampler objects at all.
  [[nodiscard]] static bool verifyRawGlSamplerStateForTesting(
      bool forceSamplerObjectsUnsupported = false);
#endif

 protected:
  QSGNode* updatePaintNode(QSGNode* oldNode,
                           UpdatePaintNodeData* data) override;

 private:
  std::shared_ptr<SharedState> state_;
};

}  // namespace wam::macos
