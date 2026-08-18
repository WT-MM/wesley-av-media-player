#pragma once

#include "native_tracked_video_output.hpp"
#include "native_video_presenter.hpp"

#include <cstdint>
#include <memory>
#include <string>

namespace wam::macos {

// Audit counters for the layer presenter. These are telemetry-tier by design:
// every number below except enqueuedFrames/drawnFrames/supersededByDropFrames
// originates in AVVideoPerformanceMetrics, whose every property is tagged
// [SPI] in the shipping public header and which is reachable only through an
// asynchronous load that may yield nil. The draw-proof stream must stay valid
// without them (DESIGN.md section 8, risk 3).
struct NativeLayerVideoOutputHealth {
  std::uint64_t enqueuedFrames{0};
  std::uint64_t drawnFrames{0};
  // Frames that were admitted and enqueued but terminated FrameSuperseded
  // instead of FrameDrawn because an equal number of earlier frames were
  // measured as dropped. This is the drop audit made truthful in the proof
  // stream rather than merely reported alongside it.
  std::uint64_t supersededByDropFrames{0};
  std::uint64_t observedDroppedFrames{0};
  std::uint64_t optimizedCompositingFrames{0};
  std::uint64_t observedTotalFrames{0};
  std::uint64_t metricsLoads{0};
  std::uint64_t metricsUnavailable{0};
  std::uint64_t flushes{0};
  std::uint64_t decodeFailureNotifications{0};
  std::uint64_t requiresFlushNotifications{0};
  // Highest surface retention the presenter itself held, in FrameLeases. The
  // surface-budget arithmetic in native_video_consumer.hpp depends on this
  // staying at or below kRetainedFrameLeaseCeiling.
  std::size_t peakRetainedLeases{0};
  double totalAccumulatedFrameDelaySeconds{0.0};
};

// NativeTrackedVideoOutput implemented over AVSampleBufferDisplayLayer's
// sampleBufferRenderer (AVSampleBufferVideoRenderer). Decoded, IOSurface-backed
// CVPixelBuffers are wrapped in CMSampleBuffers carrying the exact submitted
// FrameTiming and enqueued directly; the process issues no render pass, which
// is the entire point of the pivot (DESIGN.md section 6).
//
// CLOCK AUTHORITY. The layer is driven in manual-enqueue mode: no
// controlTimebase and no AVSampleBufferRenderSynchronizer is ever attached, and
// every enqueued sample carries kCMSampleAttachmentKey_DisplayImmediately. WAM's
// scheduler already releases each frame at its exact due host time against the
// audio-authoritative media clock, so "we enqueue when due, the layer shows it
// now" keeps a single clock in the system. Handing the layer a timebase would
// install a second one. The header's warning against combining
// DisplayImmediately with a control timebase or a render synchronizer
// (AVSampleBufferDisplayLayer.h:137) is respected precisely because neither
// exists here.
//
// DRAW PROOF CLASS. FrameDrawn is an acceptance-class fact, exactly as the GL
// path's fence-created proof is (qt_gl_video_item.hpp:44-46): it means the
// renderer irrevocably took this exact frame for display and cannot now un-take
// it. It does not claim photons. It is published after enqueueSampleBuffer:
// with the renderer still reporting Rendering and the generation still
// accepted.
//
// DROP AUDIT. Acceptance over-credits under drops by ~14% (DESIGN.md section 6,
// "Honesty check"). numberOfDroppedFrames is therefore folded into the proof
// stream rather than reported beside it: measured drops accrue as a debt, and
// each subsequent admitted frame settles one unit of that debt by terminating
// FrameSuperseded instead of FrameDrawn. Published FrameDrawn counts therefore
// never exceed frames actually displayed, which is the property the audit
// exists to guarantee. Flush-induced drops belong to the retired generation and
// are re-baselined away rather than charged to the new one.
class NativeLayerVideoOutput final : public NativeTrackedVideoOutput {
 public:
  // The presenter's own steady-state FrameLease retention. One lease is the
  // admitted frame; one more is the frame the renderer may still be holding on
  // screen, retired only once its successor has been enqueued. Releasing that
  // second lease earlier would leave a live IOSurface uncharged against
  // NativeSurfaceBudget while the renderer still owned it, which is exactly the
  // accounting lie the lease discipline exists to prevent.
  static constexpr std::size_t kRetainedFrameLeaseCeiling = 2;

  // displayLayer is an AVSampleBufferDisplayLayer* bridged to void*. Passing
  // nullptr makes the output create and own a detached layer, which is what the
  // contract tests use: an ASBDL accepts and acknowledges enqueues without ever
  // joining a view hierarchy.
  static std::shared_ptr<NativeLayerVideoOutput> createTracked(
      void* displayLayer, NativeTrackedVideoOutputWakeSeam wake,
      std::string* error = nullptr);

  NativeLayerVideoOutput(const NativeLayerVideoOutput&) = delete;
  NativeLayerVideoOutput& operator=(const NativeLayerVideoOutput&) = delete;
  ~NativeLayerVideoOutput() override;

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
  [[nodiscard]] NativeTrackedVideoOutputFacts facts() const noexcept override;

  // Activates the first generation. The tracked contract requires an accepted
  // generation before any submit; the GL output reaches this through its
  // scheduler seam, and the layer output exposes it directly because it has no
  // scheduler of its own.
  [[nodiscard]] bool startGeneration(std::uint64_t generation,
                                     std::string* error = nullptr) noexcept;

  [[nodiscard]] NativeLayerVideoOutputHealth health() const noexcept;

 private:
  struct State;
  explicit NativeLayerVideoOutput(std::shared_ptr<State> state) noexcept;
  std::shared_ptr<State> state_;
};

}  // namespace wam::macos
