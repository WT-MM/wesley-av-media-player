#pragma once

#include "platform/macos/native_tracked_video_output.hpp"
#include "qt_gl_video_item.hpp"

#include <atomic>
#include <memory>
#include <string>

namespace wam::macos {

#if defined(WAM_NATIVE_TEST_SEAMS)
struct NativeQtGlOutputDeferredWatchdogFacts {
  std::uint64_t armRequests{0};
  std::uint64_t arms{0};
  std::uint64_t wakes{0};
  bool active{false};
  bool armQueued{false};
  bool renderObservationPending{false};
};
#endif

// Adapter from the native scheduler to QtGlVideoItem: the scene-graph
// presentation route, selected by WAM_PRESENTATION=scenegraph in place of the
// default display-layer route. Decoder and presentation threads only touch the
// bounded shared State; all QQuickItem operations are marshalled to the item's
// GUI thread. The adapter owns at most one pending FrameLease and at most one
// live GUI-drain request.
//
// Presenter facts are sampled on bounded bridge activity, not every Qt
// redraw; quiescent values can therefore lag until the next
// submit/flush/failure/retirement observation.
class NativeQtGlOutput final : public NativeTrackedVideoOutput {
 public:
  static std::shared_ptr<NativeQtGlOutput> createTracked(
      QtGlVideoItem* item, NativeTrackedVideoOutputWakeSeam wake,
      std::string* error = nullptr);

  NativeQtGlOutput(const NativeQtGlOutput&) = delete;
  NativeQtGlOutput& operator=(const NativeQtGlOutput&) = delete;
  ~NativeQtGlOutput() override;


  [[nodiscard]] NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) const noexcept override;
  [[nodiscard]] NativeTrackedVideoSubmitStatus submit(
      const FrameLease& frame, NativeTrackedFrameSequence sequence,
      std::string* error) noexcept override;
  [[nodiscard]] std::optional<NativeTrackedVideoEvent>
  takeEvent() noexcept override;
  [[nodiscard]] NativeTrackedVideoOutputProgress flushProgress(
      std::uint64_t retiredGeneration,
      std::uint64_t nextGeneration) noexcept override;
  [[nodiscard]] NativeTrackedVideoOutputProgress closeProgress(
      std::uint64_t finalGeneration) noexcept override;
  [[nodiscard]] NativeTrackedVideoOutputFacts facts()
      const noexcept override;
  // The GL item samples only 4:2:0 NV12/P010 (QtGlVideoItem's
  // colorParameters), with no transfer or gamut conversion, integral display
  // sizes and no rotation.
  [[nodiscard]] NativePresentationCapabilities presentationCapabilities()
      const noexcept override {
    return {};
  }
  [[nodiscard]] bool applyPresentationGeometry(
      media::MediaDisplaySize displaySize,
      int quarterTurnDegrees) noexcept override {
    return quarterTurnDegrees == 0 && displaySize.width.denominator == 1 &&
           displaySize.height.denominator == 1;
  }

#if defined(WAM_NATIVE_TEST_SEAMS)
  void failNextGuiInvokeForTesting() noexcept;
  void throwNextGuiDrainInvokeForTesting() noexcept;
  void throwInNextAcceptedGuiDrainForTesting() noexcept;
  void throwNextObservationPollForTesting() noexcept;
  void throwNextWindowObservationConnectForTesting() noexcept;
  void failNextFinalFlushInvokeForTesting() noexcept;
  void throwNextFinalFlushInvokeForTesting() noexcept;
  void throwNextGuiContextDeleteLaterForTesting() noexcept;
  [[nodiscard]] bool observationPollQueuedForTesting() const noexcept;
  [[nodiscard]] NativeQtGlOutputDeferredWatchdogFacts
  deferredWatchdogFactsForTesting() const noexcept;
  void noticeRenderProgressForTesting() noexcept;
  // Deterministic lifetime proof: holds one already-pinned wake callback until
  // release is set, allowing closeProgress() to close the combined gate and
  // prove that a late signal cannot enter or outlive Done.
  void holdPinnedTrackedWakeForTesting(
      std::atomic<bool>* entered, std::atomic<bool>* release) noexcept;
#endif

 private:
  struct State;
  explicit NativeQtGlOutput(std::shared_ptr<State> state) noexcept;
  [[nodiscard]] bool flushImpl(std::uint64_t nextGeneration,
                               std::string* error) noexcept;
  // The terminal invalidation closeProgress() applies once.
  void close(std::uint64_t finalGeneration) noexcept;
  std::shared_ptr<State> state_;
};

}  // namespace wam::macos
