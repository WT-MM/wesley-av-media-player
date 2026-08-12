#pragma once

#include "native_video_presenter.hpp"

#include <QQuickItem>
#include <QString>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

namespace wam::macos {

struct QtGlFatalErrorSerialState;

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

struct QtGlVideoItemStats {
  std::uint64_t submittedFrames{0};
  std::uint64_t importedFrames{0};
  std::uint64_t renderedFrames{0};
  std::uint64_t lastRenderedGeneration{0};
  std::uint64_t acceptedGeneration{0};
  std::uint64_t acceptedRenderedFrames{0};
  std::uint64_t fatalErrorSerial{0};
  std::uint64_t backpressuredImports{0};
  std::uint64_t rejectedFrames{0};
  std::uint64_t staleFrames{0};
  std::uint64_t destroyedResourceSets{0};
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

// Test-gated Qt Quick integration for IOSurface-backed VideoToolbox output.
// It deliberately uses Qt's existing OpenGL scene-graph backend so the
// shipping libmpv fallback does not need a cross-API copy. The node binds the
// IOSurface's NV12/P010 planes as GL_TEXTURE_RECTANGLE views and converts YUV
// directly into Qt's active render target in one draw.
//
// The item is not registered by, linked into, or selected by shipping WAM.
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
  // Atomically advances the accepted timeline and clears the retained frame.
  // A stale frame submitted by an asynchronous pre-seek callback is rejected,
  // and a recreated scene graph cannot resurrect the old generation.
  void flush(std::uint64_t nextGeneration) noexcept;
  [[nodiscard]] QtGlVideoItemStats stats() const;
  // Acquire on the item's owning/GUI thread. Copies of the returned token and
  // load() itself are safe on the scene-graph render thread.
  [[nodiscard]] QtGlFatalErrorSerialToken fatalErrorSerialToken()
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
  void holdRetirementServiceStartingForTesting(bool hold);
  // Exercises the teardown path without depending on GPU scheduling luck.
  void holdRetirementsForTesting(bool hold);
  // Forces the impossible no-service teardown branch. The gate verifies that
  // its IOSurface lease is quarantined rather than released unsafely.
  void strandRetirementServiceForTesting();
  [[nodiscard]] static std::size_t quarantinedJobsForTesting() noexcept;
  [[nodiscard]] static std::size_t retirementServiceCountForTesting() noexcept;
  [[nodiscard]] static std::size_t
  retirementServiceCapacityForTesting() noexcept;
  [[nodiscard]] static bool nativeGlSubsystemPoisonedForTesting() noexcept;
  [[nodiscard]] std::uint64_t
  transferredCoveringFencesForTesting() const noexcept;
  // Proves VAO names are deleted only in their exact origin CGL context,
  // including same-share-group and different-share-group collisions.
  [[nodiscard]] static bool verifyContextLocalVaoPolicyForTesting();
#endif

 protected:
  QSGNode* updatePaintNode(QSGNode* oldNode,
                           UpdatePaintNodeData* data) override;

 private:
  std::shared_ptr<SharedState> state_;
};

}  // namespace wam::macos
