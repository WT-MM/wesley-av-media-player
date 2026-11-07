#pragma once

#include "media/native_media_source.hpp"

#include "native_video_presenter.hpp"
#include "native_late_display_trace.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
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

// The wake gate every tracked output guards its seam with: a closed bit and a
// count of signals in flight. Close sets the bit; the output reports
// closeProgress Done only once the count has drained, which is what makes "the
// seam outlives closeProgress Done" safe. A saturated count refuses a pin
// rather than wrapping into the closed bit.
class NativeTrackedWakeGate final {
public:
  [[nodiscard]] bool tryPin() noexcept {
    std::uint64_t gate = state_.load(std::memory_order_acquire);
    for (;;) {
      if ((gate & kClosedBit) != 0 || (gate & kEntryMask) == kEntryMask) {
        return false;
      }
      if (state_.compare_exchange_weak(gate, gate + 1,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
        return true;
      }
    }
  }
  void unpin() noexcept { state_.fetch_sub(1, std::memory_order_release); }
  // Pins, signals the seam, unpins. A closed or saturated gate signals
  // nothing.
  void signal(const NativeTrackedVideoOutputWakeSeam& seam) noexcept {
    if (!tryPin()) {
      return;
    }
    if (seam.signal != nullptr) {
      seam.signal(seam.context);
    }
    unpin();
  }
  void close() noexcept {
    state_.fetch_or(kClosedBit, std::memory_order_acq_rel);
  }
  [[nodiscard]] bool drained() const noexcept {
    return (state_.load(std::memory_order_acquire) & kEntryMask) == 0;
  }

private:
  static constexpr std::uint64_t kClosedBit = std::uint64_t{1} << 63U;
  static constexpr std::uint64_t kEntryMask = kClosedBit - 1U;
  std::atomic<std::uint64_t> state_{0};
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

// What a tracked output can present. A presenter that samples the surface in
// process (Qt's GL scene graph) answers false to everything a sampled
// 4:2:0 NV12/P010 path cannot do; the display-layer route, which hands the
// surface to CoreAnimation untouched, answers true.
struct NativePresentationCapabilities {
  // The decoded surface goes straight to a CoreAnimation display layer and
  // nothing in this process samples it. Only then may the decoder leave its
  // output pixel format unpinned and take the AGX lossless-compressed surface
  // the hardware produces natively, which is worth roughly half of the decoder
  // service's CPU (a pinned format costs a VTPixelTransferSession per frame).
  bool presentsDecodedSurfacesDirectly{false};
  // 4:2:2 and 4:4:4 surfaces, and ProRes 4444's packed opaque RGB.
  bool samplesBeyondYuv420{false};
  // PQ/HLG and non-BT.709 transfers and primaries are converted for display.
  bool convertsTransferAndGamut{false};
  // Exact rational (anamorphic) display sizes, not only integral ones.
  bool rationalDisplaySize{false};
  // Quarter-turn rotation. An output that cannot rotate produces a clean
  // Unsupported, so the file opens on the compatibility renderer correctly
  // oriented instead of drawing sideways in a native window.
  bool quarterTurns{false};
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
  Failed,
};

// One exact terminal observation. eventSequence is output-owned, nonzero, and
// strictly increasing without wrap. FrameDrawn means the presenter
// irrevocably took the matching frame for display in the current generation:
// on the GL route a render pass drew it and published its covering fence; on
// the layer route the renderer accepted the enqueue (see
// native_layer_video_output.hpp, "DRAW PROOF CLASS"). Neither claims photons,
// and neither is inferred from a stats delta. FrameSuperseded is the only
// non-failure way an accepted tracked delivery can terminate without a draw.
//
// Every event carries a nonzero frameSequence and the exact immutable timing
// submitted for that identity.
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
  // The capacity-one credit: 1 while a frame is admitted and its terminal
  // event has not been taken, else 0. Surface leases a presenter keeps past
  // that (a renderer still displaying the predecessor) are not counted here;
  // NativeSurfaceBudget accounts for them.
  std::size_t retainedFrames{0};
  bool eventPending{false};
  bool invalidationPending{false};
  bool closed{false};
  bool fatal{false};
};

// The tracked-output protocol state every presenter shares: the capacity-one
// frame mailbox, its event sequence, and the flush/close lifecycle. A
// presenter holds it under its own lock and supplies only the renderer side
// (starting a renderer flush and observing that it took effect), so the
// contract's transitions are stated once.
//
// `usable` is the presenter's own verdict: false once it has latched a failure
// or closed its renderer.
struct NativeTrackedOutputProtocol {
  // The admitted frame awaiting its terminal event, and that event once
  // published. The consumer takes the event; the frame identity clears with it.
  NativeTrackedFrameSequence frame{};
  std::uint64_t frameGeneration{0};
  FrameTiming frameTiming{};
  std::optional<NativeTrackedVideoEvent> event;
  std::uint64_t lastEventSequence{0};
  std::uint64_t drawnFrames{0};
  std::uint64_t supersededFrames{0};
  // The newest identity ever admitted; identities must strictly increase.
  NativeTrackedFrameSequence lastFrame{};
  std::uint64_t submittedFrames{0};

  // Set once at creation; detachWake() clears it after the gate drains.
  NativeTrackedVideoOutputWakeSeam wake{};
  NativeTrackedWakeGate wakeGate;

  bool flushPending{false};
  bool flushDone{false};
  std::uint64_t flushRetired{0};
  std::uint64_t flushNext{0};
  // The generation the next flush must name as retired.
  std::uint64_t retiredGeneration{0};
  bool closePending{false};
  bool closeDone{false};
  std::uint64_t closeGeneration{0};

  [[nodiscard]] bool frameOutstanding() const noexcept {
    return frame.valid() || event.has_value();
  }

  // `current`: the presenter accepts this generation now. submit() answers
  // with the same verdict before it checks the frame itself.
  [[nodiscard]] NativeTrackedVideoCapacity capacity(
      std::uint64_t generation, bool current, bool usable) const noexcept {
    if (!usable || closePending) {
      return NativeTrackedVideoCapacity::Failed;
    }
    if (generation == 0 || !current) {
      return NativeTrackedVideoCapacity::StaleGeneration;
    }
    return frameOutstanding() || flushPending
               ? NativeTrackedVideoCapacity::Backpressure
               : NativeTrackedVideoCapacity::Available;
  }

  // A repeated or regressed identity is a caller contract violation, which
  // the presenter latches as fatal.
  [[nodiscard]] bool advances(NativeTrackedFrameSequence sequence) const
      noexcept {
    return !lastFrame.valid() || sequence.value > lastFrame.value;
  }

  void admit(NativeTrackedFrameSequence sequence,
             const FrameTiming& timing) noexcept {
    frame = sequence;
    frameTiming = timing;
    frameGeneration = timing.generation;
    lastFrame = sequence;
    ++submittedFrames;
  }

  void clearFrame() noexcept {
    frame = {};
    frameTiming = {};
    frameGeneration = 0;
  }

  // Publishes the admitted frame's one terminal event. False when there is no
  // frame, an event is already waiting, or (sequenceExhausted set) the event
  // sequence space is spent, which the presenter treats as fatal.
  [[nodiscard]] bool publish(NativeTrackedVideoEventKind kind,
                             bool* sequenceExhausted = nullptr) noexcept {
    if (!frame.valid() || event) {
      return false;
    }
    if (lastEventSequence == std::numeric_limits<std::uint64_t>::max()) {
      if (sequenceExhausted != nullptr) {
        *sequenceExhausted = true;
      }
      return false;
    }
    event.emplace(NativeTrackedVideoEvent{kind, ++lastEventSequence, frame,
                                          frameGeneration, frameTiming});
    if (kind == NativeTrackedVideoEventKind::FrameDrawn) {
      ++drawnFrames;
    } else if (kind == NativeTrackedVideoEventKind::FrameSuperseded) {
      ++supersededFrames;
    }
    return true;
  }

  [[nodiscard]] std::optional<NativeTrackedVideoEvent> take() noexcept {
    std::optional<NativeTrackedVideoEvent> result = std::move(event);
    event.reset();
    if (result && result->frameSequence.valid()) {
      clearFrame();
    }
    return result;
  }

  enum class Step : std::uint8_t {
    Done,        // the exact operation already completed
    Stale,       // a different operation is pending or completed
    Failed,      // the request itself is invalid
    Started,     // first entry: the presenter must start its renderer side
    Continuing,  // already started: the presenter re-checks completion
  };

  [[nodiscard]] Step beginFlush(std::uint64_t retired, std::uint64_t next,
                                bool usable) noexcept {
    if (!usable || closePending || next == 0 || next <= retired) {
      return Step::Failed;
    }
    if (flushDone && flushRetired == retired && flushNext == next) {
      return Step::Done;
    }
    if (flushPending) {
      return flushRetired == retired && flushNext == next ? Step::Continuing
                                                          : Step::Stale;
    }
    if (retired != retiredGeneration) {
      return Step::Stale;
    }
    flushPending = true;
    flushDone = false;
    flushRetired = retired;
    flushNext = next;
    return Step::Started;
  }

  // The renderer proved the flush: the target is the next retirement point.
  void completeFlush() noexcept {
    flushPending = false;
    flushDone = true;
    retiredGeneration = flushNext;
  }

  // `accepted` is the presenter's current generation; a first close must
  // move past it.
  [[nodiscard]] Step beginClose(std::uint64_t final,
                                std::uint64_t accepted) noexcept {
    if (closeDone) {
      return closeGeneration == final ? Step::Done : Step::Stale;
    }
    if (final == 0 || (!closePending && final <= accepted)) {
      return Step::Failed;
    }
    if (closePending) {
      return closeGeneration == final ? Step::Continuing : Step::Stale;
    }
    closePending = true;
    closeDone = false;
    closeGeneration = final;
    return Step::Started;
  }

  // A terminal invalidation supersedes any flush: no lifecycle work remains.
  void completeClose() noexcept {
    flushPending = false;
    flushDone = false;
    flushRetired = 0;
    flushNext = 0;
    closePending = false;
    closeDone = true;
  }

  // The outcome of a flush/close Step that needs no renderer work, or nullopt
  // for Started/Continuing.
  [[nodiscard]] static std::optional<NativeTrackedVideoOutputProgress>
  settled(Step step) noexcept {
    switch (step) {
    case Step::Failed:
      return NativeTrackedVideoOutputProgress::Failed;
    case Step::Stale:
      return NativeTrackedVideoOutputProgress::StaleGeneration;
    case Step::Done:
      return NativeTrackedVideoOutputProgress::Done;
    case Step::Started:
    case Step::Continuing:
      break;
    }
    return std::nullopt;
  }

  // Closes the wake gate; true once no signal is in flight and the seam is
  // detached. closeProgress() reports Done only after this succeeds.
  [[nodiscard]] bool detachWake() noexcept {
    wakeGate.close();
    if (!wakeGate.drained()) {
      return false;
    }
    wake = {};
    return true;
  }

  [[nodiscard]] NativeTrackedVideoOutputFacts facts(
      std::uint64_t generation, bool closed, bool fatal) const noexcept {
    NativeTrackedVideoOutputFacts result;
    result.generation = generation;
    result.admittedFrame = frame;
    result.submittedFrames = submittedFrames;
    result.drawnFrames = drawnFrames;
    result.supersededFrames = supersededFrames;
    result.lastEventSequence = lastEventSequence;
    result.retainedFrames = frame.valid() ? 1U : 0U;
    result.eventPending = event.has_value();
    result.invalidationPending = flushPending || closePending;
    result.closed = closed;
    result.fatal = fatal;
    return result;
  }
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
class NativeTrackedVideoOutput {
 public:
  virtual ~NativeTrackedVideoOutput() = default;
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
  [[nodiscard]] virtual late_display_trace::Snapshot diagnosticDisplayPhase() const noexcept { return {}; }
#endif

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

  // What this output can present, answered whole so a wrapper forwards one
  // value and a new capability cannot be silently answered by a default.
  // Admission (native_presentation_admission.hpp) reads only this.
  [[nodiscard]] virtual NativePresentationCapabilities
  presentationCapabilities() const noexcept = 0;

  // Applies an admitted track's presentation geometry: its exact display size
  // and a quarter turn clockwise (0, 90, 180 or 270). Called only after
  // admission accepted the track against presentationCapabilities(), so a
  // false return is an output failure, not a refusal. Repeating the same
  // geometry is idempotent.
  [[nodiscard]] virtual bool applyPresentationGeometry(
      media::MediaDisplaySize displaySize, int quarterTurnDegrees) noexcept = 0;
};

}  // namespace wam::macos
