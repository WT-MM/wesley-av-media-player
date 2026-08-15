#pragma once

#include "native_video_presenter.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

namespace wam::macos {

// Caller-owned, nonwrapping identity for one compositor delivery. Zero is
// always invalid. The output echoes the exact identity in its terminal event;
// timestamps alone cannot distinguish duplicate frames or a redraw of a
// previously retained frame.
struct NativeTrackedFrameSequence {
  std::uint64_t value{0};

  [[nodiscard]] constexpr bool valid() const noexcept { return value != 0; }
  friend constexpr bool operator==(NativeTrackedFrameSequence,
                                   NativeTrackedFrameSequence) = default;
};

using NativeTrackedVideoOutputWake = void (*)(void* context) noexcept;

// Immutable edge notification supplied when an output implementation is
// created. signal may run on a GUI or render thread, must not block, allocate,
// throw, or call back into the output, and must remain valid until
// closeProgress() returns Done. The owner coalesces this edge with its shared
// dispatcher wake.
struct NativeTrackedVideoOutputWakeSeam {
  NativeTrackedVideoOutputWake signal{nullptr};
  void* context{nullptr};
};

enum class NativeTrackedVideoSubmitStatus : std::uint8_t {
  Accepted,
  Backpressure,
  StaleGeneration,
  Failed,
};

enum class NativeTrackedVideoCapacity : std::uint8_t {
  Available,
  Backpressure,
  StaleGeneration,
  Failed,
};

enum class NativeTrackedVideoOutputProgress : std::uint8_t {
  Done,
  Quiescing,
  StaleGeneration,
  Failed,
};

enum class NativeTrackedVideoEventKind : std::uint8_t {
  FrameDrawn,
  FrameSuperseded,
  GenerationInvalidated,
  Closed,
  Failed,
};

// One exact terminal observation. eventSequence is output-owned, nonzero, and
// strictly increasing without wrap. FrameDrawn means the matching frame was
// accepted by the current generation and its real Qt render pass completed a
// successful draw plus covering-fence publication. It is not inferred from a
// stats delta or GUI submission. FrameSuperseded is the only non-failure way
// an accepted tracked delivery can terminate without a draw.
//
// Frame events carry a nonzero frameSequence and the exact immutable timing
// submitted for that identity. Lifecycle events carry a zero frameSequence;
// generation is the exact invalidation/final generation they acknowledge.
struct NativeTrackedVideoEvent {
  NativeTrackedVideoEventKind kind{NativeTrackedVideoEventKind::Failed};
  std::uint64_t eventSequence{0};
  NativeTrackedFrameSequence frameSequence{};
  std::uint64_t generation{0};
  FrameTiming timing{};
};

struct NativeTrackedVideoOutputFacts {
  std::uint64_t generation{0};
  NativeTrackedFrameSequence admittedFrame{};
  std::uint64_t submittedFrames{0};
  std::uint64_t drawnFrames{0};
  std::uint64_t supersededFrames{0};
  // Highest output-owned event identity already published, including an event
  // still pending in the output mailbox. This makes Start baseline sampling
  // linearizable with a concurrent render publication.
  std::uint64_t lastEventSequence{0};
  std::size_t retainedFrames{0};
  bool eventPending{false};
  bool invalidationPending{false};
  bool closed{false};
  bool fatal{false};
};

// Capacity-one boundary from WAM's owner-thread video scheduler to an
// externally owned GUI/render presenter. It creates no scheduling thread or
// timer. Exactly one tracked frame may be admitted until its terminal
// FrameDrawn/FrameSuperseded event is consumed. A pending event is never
// overwritten; flushProgress()/closeProgress() return Quiescing until any
// older terminal fact is consumed and render-side invalidation can be proved.
//
// submit() borrows frame only for the call. Accepted means the output retained
// its own zero-copy FrameLease and the caller may release its lease. Every
// other result leaves the caller's lease as the sole delivery owner. A first
// successful draw of an admitted identity emits exactly one FrameDrawn;
// retained-frame redraws update no terminal mailbox.
//
// flushProgress() is repeatable only for one exact retired/next pair, with next
// strictly newer. retired may be zero for first activation. Done proves the
// render side can no longer draw retired-generation content. closeProgress() is
// repeatable for one exact final generation strictly newer than the currently
// accepted generation, and Done proves terminal render-side invalidation.
// Neither Done result depends on consuming an optional lifecycle diagnostic
// event.
class NativeTrackedVideoOutput {
 public:
  virtual ~NativeTrackedVideoOutput() = default;

  [[nodiscard]] virtual NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) const noexcept = 0;
  [[nodiscard]] virtual NativeTrackedVideoSubmitStatus submit(
      const FrameLease& frame, NativeTrackedFrameSequence sequence,
      std::string* error) noexcept = 0;
  [[nodiscard]] virtual std::optional<NativeTrackedVideoEvent>
  takeEvent() noexcept = 0;
  [[nodiscard]] virtual NativeTrackedVideoOutputProgress flushProgress(
      std::uint64_t retiredGeneration,
      std::uint64_t nextGeneration) noexcept = 0;
  [[nodiscard]] virtual NativeTrackedVideoOutputProgress closeProgress(
      std::uint64_t finalGeneration) noexcept = 0;
  [[nodiscard]] virtual NativeTrackedVideoOutputFacts facts()
      const noexcept = 0;
};

}  // namespace wam::macos
