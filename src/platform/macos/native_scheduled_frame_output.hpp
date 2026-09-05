#pragma once

#include "native_video_presenter.hpp"

#include <cstdint>
#include <functional>
#include <string>

namespace wam::macos {

enum class NativeScheduledFrameDispatchResult : std::uint8_t {
  Dispatched,
  Backpressure,
  Rejected,
  Failed,
};

struct NativeScheduledFrameOutputStats {
  bool closed{false};
  bool deliveryQueued{false};
  std::uint64_t acceptedGeneration{0};
  std::uint64_t dispatchedFrames{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t coalescedFrames{0};
  std::uint64_t staleFrames{0};
  std::uint64_t rejectedFrames{0};
  // The three render-pass counters below are activity-sampled by the Qt
  // adapter: refreshed by start/dispatch/flush/failure/retirement
  // observation, so they can lag redraws of a retained frame while playback
  // is otherwise quiescent. A benchmark must request an explicit
  // GUI-linearized presenter snapshot instead of treating stats() as a
  // per-render notification.
  // Adapter-lifetime Qt render passes. Qt may redraw one retained lease more
  // than once, so this is deliberately not a unique-frame count and can
  // exceed dispatchedFrames.
  std::uint64_t actuallyRenderedFrames{0};
  // Presenter-lifetime successful draws that were still part of its accepted
  // generation when the completion fence was published. This counter and
  // acceptedGeneration are sampled coherently by the presenter.
  std::uint64_t acceptedRenderedFrames{0};
  // Exact accepted draws since the current output failure-handler epoch's
  // startup flush was applied on the GUI thread. Later seek flushes preserve
  // this attempt counter; installing the next handler resets it.
  std::uint64_t attemptAcceptedRenderedFrames{0};
  std::uint64_t lastRenderedGeneration{0};
  std::uint64_t fatalErrorSerial{0};
};

struct NativeScheduledFrameStartAck {
  std::uint64_t requestedGeneration{0};
  std::uint64_t acceptedGeneration{0};
  std::uint64_t acceptedRenderedFrames{0};
};

// Thread-safe boundary between the native scheduler and an externally owned
// GUI presenter. Implementations retain at most one scheduled FrameLease and
// must never call a GUI object from dispatch(), flush(), close(), or stats().
// A failure handler may run on the presenter's GUI thread and therefore must
// return promptly and must not call back into the output.
class NativeScheduledFrameOutput {
 public:
  using FailureHandler = std::function<void(std::string)>;
  using StartAppliedHandler =
      std::function<void(NativeScheduledFrameStartAck)>;

  virtual ~NativeScheduledFrameOutput() = default;
  [[nodiscard]] virtual NativeScheduledFrameDispatchResult dispatch(
      FrameLease frame, std::string* error = nullptr) noexcept = 0;
  // Applies the prepared generation on the GUI/presenter side and invokes the
  // callback only after that flush has linearized against completed draws.
  // Implementations must never invoke it while holding an output lock.
  [[nodiscard]] virtual bool startGeneration(
      std::uint64_t generation, StartAppliedHandler applied,
      std::string* error = nullptr) noexcept = 0;
  [[nodiscard]] virtual bool flush(std::uint64_t nextGeneration,
                                   std::string* error = nullptr) noexcept = 0;
  virtual void close(std::uint64_t finalGeneration) noexcept = 0;
  virtual void setFailureHandler(FailureHandler handler) noexcept = 0;
  [[nodiscard]] virtual NativeScheduledFrameOutputStats stats()
      const noexcept = 0;
};

}  // namespace wam::macos
