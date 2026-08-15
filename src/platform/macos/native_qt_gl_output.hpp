#pragma once

#include "native_video_pipeline.hpp"
#include "native_tracked_video_output.hpp"
#include "qt_gl_video_item.hpp"

#include <atomic>
#include <memory>
#include <string>

namespace wam::macos {

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
struct NativeQtGlOutputDeferredWatchdogFacts {
  std::uint64_t armRequests{0};
  std::uint64_t arms{0};
  std::uint64_t wakes{0};
  bool active{false};
  bool armQueued{false};
  bool renderObservationPending{false};
};
#endif

// Default-off adapter from the native scheduler to QtGlVideoItem. Decoder and
// presentation threads only touch the bounded shared State; all QQuickItem
// operations are marshalled to the item's GUI thread. The adapter owns at most
// one pending FrameLease and at most one live GUI-drain request.
//
// This class is absent from default WAM builds. The explicit activation build
// option can compile the seam, but runtime ownership still waits for the
// controller/fallback and measured-performance gates. Its render-pass
// statistics are sampled on bounded bridge activity, not every Qt redraw;
// quiescent values can therefore lag until the next
// start/dispatch/flush/failure/retirement observation.
class NativeQtGlOutput final : public NativeScheduledFrameOutput,
                               public NativeTrackedVideoOutput {
 public:
  static std::shared_ptr<NativeQtGlOutput> create(
      QtGlVideoItem* item, std::string* error = nullptr);
  static std::shared_ptr<NativeQtGlOutput> createTracked(
      QtGlVideoItem* item, NativeTrackedVideoOutputWakeSeam wake,
      std::string* error = nullptr);

  NativeQtGlOutput(const NativeQtGlOutput&) = delete;
  NativeQtGlOutput& operator=(const NativeQtGlOutput&) = delete;
  ~NativeQtGlOutput() override;

  [[nodiscard]] NativeScheduledFrameDispatchResult dispatch(
      FrameLease frame, std::string* error = nullptr) noexcept override;
  [[nodiscard]] bool startGeneration(
      std::uint64_t generation, StartAppliedHandler applied,
      std::string* error = nullptr) noexcept override;
  [[nodiscard]] bool flush(std::uint64_t nextGeneration,
                           std::string* error = nullptr) noexcept override;
  void close(std::uint64_t finalGeneration) noexcept override;
  void setFailureHandler(FailureHandler handler) noexcept override;
  [[nodiscard]] NativeScheduledFrameOutputStats stats()
      const noexcept override;

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

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  void failNextFailureNotificationCopyForTesting() noexcept;
  void failNextGuiInvokeForTesting() noexcept;
  void throwNextImmediateObservationInvokeForTesting() noexcept;
  void throwNextTwoImmediateObservationInvokesForTesting() noexcept;
  void throwNextGuiDrainInvokeForTesting() noexcept;
  void throwInNextAcceptedGuiDrainForTesting() noexcept;
  void throwNextObservationPollForTesting() noexcept;
  void throwNextWindowObservationConnectForTesting() noexcept;
  void failNextFinalFlushInvokeForTesting() noexcept;
  void throwNextFinalFlushInvokeForTesting() noexcept;
  void throwNextGuiContextDeleteLaterForTesting() noexcept;
  [[nodiscard]] bool immediateObservationQueuedForTesting()
      const noexcept;
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
                               StartAppliedHandler startApplied,
                               std::string* error) noexcept;
  std::shared_ptr<State> state_;
};

}  // namespace wam::macos
