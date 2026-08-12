#pragma once

#include "native_video_pipeline.hpp"
#include "qt_gl_video_item.hpp"

#include <memory>
#include <string>

namespace wam::macos {

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
class NativeQtGlOutput final : public NativeScheduledFrameOutput {
 public:
  static std::shared_ptr<NativeQtGlOutput> create(
      QtGlVideoItem* item, std::string* error = nullptr);

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
