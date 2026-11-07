#include "media/native_late_frame_trace.hpp"
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
#include <mach/mach_time.h>
#endif
#include "native_layer_video_output.hpp"

#include "native_layer_host_view.hpp"
#include "native_layer_presentation_state.hpp"
#include "native_video_consumer.hpp"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>

#include <atomic>
#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace wam::macos {

// The presenter's retention and the consumer's budget input are two statements
// of one fact. Assert they agree rather than letting them drift into a field
// symptom that would look like a decode fault (DESIGN.md section 8, risk 4).
static_assert(NativeLayerVideoOutput::kRetainedFrameLeaseCeiling <=
                  NativeVideoConsumer::kMaximumTrackedOutputSurfaceOwnership,
              "layer presenter retention must fit the consumer's budget input");

namespace {

void assignErrorNoexcept(std::string* error, const char* message) noexcept {
  if (error == nullptr || message == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

void assignErrorNoexcept(std::string* error,
                         const std::string& message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

// One metrics load per this many enqueues. At 30 fps that is a load roughly
// every second: frequent enough that a drop is folded into the proof stream
// within about a second of occurring, rare enough that an [SPI] async call is
// nowhere near the per-frame path.
constexpr std::uint64_t kMetricsLoadFrameInterval = 30;


}  // namespace

struct NativeLayerVideoOutput::State
    : public std::enable_shared_from_this<NativeLayerVideoOutput::State> {
  mutable std::mutex mutex;

  // Presentation objects. The layer may be owned here (detached, test/contract
  // use) or borrowed from the host view; either way the renderer is the only
  // surface this class enqueues through, because AVSampleBufferDisplayLayer's
  // own AVQueuedSampleBufferRendering methods are deprecated as of macOS 15 and
  // the header forbids mixing the two (AVSampleBufferDisplayLayer.h:301).
  AVSampleBufferDisplayLayer* layer{nil};
  // Held untyped because AVSampleBufferVideoRenderer is macOS 14+ while WAM's
  // deployment target is 13.3; every use site re-types it inside an @available
  // check, and createTracked refuses outright below 14 so the factory keeps the
  // GL path on older systems.
  id renderer{nil};
  CMVideoFormatDescriptionRef formatDescription{nullptr};

  // Generation lifecycle.
  std::uint64_t acceptedGeneration{0};

  // Capacity-one admission, its terminal mailbox, the flush/close lifecycle
  // and the wake seam.
  NativeTrackedOutputProtocol tracked;

  // Lease retirement. admittedLease belongs to tracked.frame; retiringLease is
  // its predecessor, which the renderer may still be displaying. See
  // kRetainedFrameLeaseCeiling.
  FrameLease admittedLease{};
  FrameLease retiringLease{};

  std::string failureMessage;
  bool fatal{false};

  // Set from the renderer's flush completion handler, which is the layer
  // route's terminal invalidation proof: it is the documented edge meaning
  // "flush finished, begin enqueuing the post-seek IDR"
  // (DESIGN.md section 3.3).
  std::atomic<std::uint64_t> observedInvalidationGeneration{0};

  // Drop audit.
  std::uint64_t dropDebt{0};
  std::uint64_t lastObservedDrops{0};
  bool dropBaselineValid{false};
  std::atomic<bool> metricsLoadInFlight{false};
  std::uint64_t framesSinceMetricsLoad{0};

  NativeLayerVideoOutputHealth healthCounters{};

  // Once-only latch for this output's share of the process-wide presentation
  // gate. closeProgress() and ~NativeLayerVideoOutput both end presentation and
  // either may run first (or both, in that order), so the release has to be
  // idempotent per output or a normal close-then-destroy would double-release a
  // counter that other outputs share.
  std::atomic<bool> presentationRetained{false};

  void releasePresentationOnceNoexcept() noexcept {
    if (presentationRetained.exchange(false, std::memory_order_acq_rel)) {
      releaseNativeLayerPresentation();
    }
  }

  ~State() {
    if (formatDescription != nullptr) {
      CFRelease(formatDescription);
      formatDescription = nullptr;
    }
  }

  // ---------------------------------------------------------------- wake gate

  void signalWakeNoexcept() noexcept { tracked.wakeGate.signal(tracked.wake); }

  // ------------------------------------------------------------- bookkeeping

  [[nodiscard]] bool publishFrameEventLocked(
      NativeTrackedVideoEventKind kind) noexcept {
    if (!tracked.publish(kind, &fatal)) {
      return false;
    }
    if (kind == NativeTrackedVideoEventKind::FrameDrawn) {
      ++healthCounters.drawnFrames;
    }
    return true;
  }

  // The first message wins; sequence exhaustion sets fatal without one.
  void latchFailureLocked(const char* message) noexcept {
    fatal = true;
    if (failureMessage.empty()) {
      try {
        failureMessage = message;
      } catch (...) {
      }
    }
  }

  [[nodiscard]] bool usableLocked() const noexcept {
    return !fatal && !tracked.closeDone;
  }

  [[nodiscard]] std::size_t retainedLeaseCountLocked() const noexcept {
    return (admittedLease ? 1U : 0U) + (retiringLease ? 1U : 0U);
  }

  void noteRetentionLocked() noexcept {
    const std::size_t held = retainedLeaseCountLocked();
    if (held > healthCounters.peakRetainedLeases) {
      healthCounters.peakRetainedLeases = held;
    }
  }

  void releaseAllLeasesLocked() noexcept {
    admittedLease.reset();
    retiringLease.reset();
  }

  // ------------------------------------------------------------ drop metrics

  // Folds a measured drop delta into the proof stream as debt. Called from the
  // metrics completion handler, off the submitting thread.
  void applyMetricsLocked(std::uint64_t dropped, std::uint64_t total,
                          std::uint64_t optimized, double delay) noexcept {
    ++healthCounters.metricsLoads;
    healthCounters.observedDroppedFrames = dropped;
    healthCounters.observedTotalFrames = total;
    healthCounters.optimizedCompositingFrames = optimized;
    healthCounters.totalAccumulatedFrameDelaySeconds = delay;
    if (!dropBaselineValid) {
      // First sample after activation or after a flush. A flush is a documented
      // source of large drop counts for content that belonged to the retired
      // generation (DESIGN.md section 6); charging those to the new generation
      // would superseded-starve a freshly armed timeline. Re-baseline instead.
      lastObservedDrops = dropped;
      dropBaselineValid = true;
      return;
    }
    if (dropped <= lastObservedDrops) {
      return;
    }
    const std::uint64_t delta = dropped - lastObservedDrops;
    lastObservedDrops = dropped;
    if (dropDebt > std::numeric_limits<std::uint64_t>::max() - delta) {
      dropDebt = std::numeric_limits<std::uint64_t>::max();
      return;
    }
    dropDebt += delta;
  }

  void maybeLoadMetricsLocked() noexcept {
#if !defined(WAM_PUBLIC_PRESENTATION_API)
    if (renderer == nil) {
      return;
    }
    ++framesSinceMetricsLoad;
    if (framesSinceMetricsLoad < kMetricsLoadFrameInterval) {
      return;
    }
    if (metricsLoadInFlight.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    framesSinceMetricsLoad = 0;
    const std::weak_ptr<State> weak = weak_from_this();
    if (@available(macOS 14.4, *)) {
    AVSampleBufferVideoRenderer* videoRenderer = renderer;
    @try {
      [videoRenderer loadVideoPerformanceMetricsWithCompletionHandler:^(
                         AVVideoPerformanceMetrics* _Nullable metrics) {
        const std::shared_ptr<State> self = weak.lock();
        if (self == nullptr) {
          return;
        }
        {
          std::lock_guard lock(self->mutex);
          if (metrics == nil) {
            ++self->healthCounters.metricsLoads;
            ++self->healthCounters.metricsUnavailable;
          } else {
            const NSInteger dropped = metrics.numberOfDroppedFrames;
            const NSInteger total = metrics.totalNumberOfFrames;
            const NSInteger optimized =
                metrics.numberOfFramesDisplayedUsingOptimizedCompositing;
            const NSTimeInterval delay = metrics.totalAccumulatedFrameDelay;
            self->applyMetricsLocked(
                dropped > 0 ? static_cast<std::uint64_t>(dropped) : 0U,
                total > 0 ? static_cast<std::uint64_t>(total) : 0U,
                optimized > 0 ? static_cast<std::uint64_t>(optimized) : 0U,
                delay > 0.0 ? static_cast<double>(delay) : 0.0);
          }
        }
        self->metricsLoadInFlight.store(false, std::memory_order_release);
      }];
    } @catch (NSException*) {
      metricsLoadInFlight.store(false, std::memory_order_release);
    }
    } else {
      metricsLoadInFlight.store(false, std::memory_order_release);
    }
#endif
  }

  // ----------------------------------------------------------- sample buffers

  [[nodiscard]] bool ensureFormatDescriptionLocked(CVPixelBufferRef pixelBuffer,
                                                   std::string* error) noexcept {
    if (formatDescription != nullptr &&
        CMVideoFormatDescriptionMatchesImageBuffer(formatDescription,
                                                   pixelBuffer)) {
      return true;
    }
    if (formatDescription != nullptr) {
      CFRelease(formatDescription);
      formatDescription = nullptr;
    }
    CMVideoFormatDescriptionRef created = nullptr;
    const OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, pixelBuffer, &created);
    if (status != noErr || created == nullptr) {
      assignErrorNoexcept(
          error, "layer video output could not describe the decoded frame");
      return false;
    }
    formatDescription = created;
    return true;
  }

  // Wraps the decoded frame with its exact submitted timing. The PTS and
  // duration are restated bit-for-bit from FrameTiming so the proof's timing
  // echo and the sample the renderer holds can never disagree.
  [[nodiscard]] CMSampleBufferRef makeSampleBufferLocked(
      CVPixelBufferRef pixelBuffer, const FrameTiming& timing,
      std::string* error) noexcept {
    if (!ensureFormatDescriptionLocked(pixelBuffer, error)) {
      return nullptr;
    }
    // A frame that straddles the movie origin is presented FROM the origin with
    // its end preserved exactly, so the moment the next frame replaces it does
    // not move. Only the buffer handed to the renderer is restated; the tracked
    // FrameTiming the draw proof is matched against is untouched, so the
    // consumer's sequence/timing accounting sees exactly what it submitted.
    // Both stamps sit on the same movie timeline, so this subtraction is exact;
    // a rounded result is refused rather than presented.
    CMTime presentation = timing.presentationTime;
    CMTime duration = timing.duration;
    if (CMTimeCompare(presentation, kCMTimeZero) < 0) {
      const CMTime end = CMTimeAdd(presentation, duration);
      if (!CMTIME_IS_NUMERIC(end) ||
          (end.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
          CMTimeCompare(end, kCMTimeZero) <= 0) {
        assignErrorNoexcept(
            error, "layer video output could not stage the decoded frame");
        return nullptr;
      }
      presentation = kCMTimeZero;
      duration = end;
    }
    CMSampleTimingInfo sampleTiming{};
    sampleTiming.duration = duration;
    sampleTiming.presentationTimeStamp = presentation;
    sampleTiming.decodeTimeStamp = kCMTimeInvalid;
    CMSampleBufferRef sampleBuffer = nullptr;
    const OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, pixelBuffer, formatDescription, &sampleTiming,
        &sampleBuffer);
    if (status != noErr || sampleBuffer == nullptr) {
      assignErrorNoexcept(
          error, "layer video output could not stage the decoded frame");
      return nullptr;
    }
    // Manual-enqueue mode: no controlTimebase and no render synchronizer is
    // attached anywhere in this file, so DisplayImmediately is both permitted
    // and required. Without it the renderer's own timebase sits at rate 0 and
    // at most one frame ever reaches the screen (DESIGN.md section 3.1b).
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
      auto entry = static_cast<CFMutableDictionaryRef>(
          const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
      if (entry != nullptr) {
        CFDictionarySetValue(entry, kCMSampleAttachmentKey_DisplayImmediately,
                             kCFBooleanTrue);
      }
    }
    return sampleBuffer;
  }

  // ------------------------------------------------------------------- flush

  void beginRendererFlushNoexcept(bool removeDisplayedImage,
                                  std::uint64_t generation) noexcept {
    if (@available(macOS 14.0, *)) {
    AVSampleBufferVideoRenderer* videoRenderer = renderer;
    if (videoRenderer == nil) {
      observedInvalidationGeneration.store(generation,
                                           std::memory_order_release);
      return;
    }
    const std::weak_ptr<State> weak = weak_from_this();
    @try {
      [videoRenderer
          flushWithRemovalOfDisplayedImage:(removeDisplayedImage ? YES : NO)
                         completionHandler:^{
                           const std::shared_ptr<State> self = weak.lock();
                           if (self == nullptr) {
                             return;
                           }
                           std::uint64_t observed =
                               self->observedInvalidationGeneration.load(
                                   std::memory_order_acquire);
                           while (observed < generation &&
                                  !self->observedInvalidationGeneration
                                       .compare_exchange_weak(
                                           observed, generation,
                                           std::memory_order_acq_rel,
                                           std::memory_order_acquire)) {
                           }
                           self->signalWakeNoexcept();
                         }];
    } @catch (NSException*) {
      // A flush that could not even be issued must not strand the lifecycle.
      // Treat it as observed and let the status check surface any real failure.
      observedInvalidationGeneration.store(generation,
                                           std::memory_order_release);
      signalWakeNoexcept();
    }
    } else {
      observedInvalidationGeneration.store(generation,
                                           std::memory_order_release);
      signalWakeNoexcept();
    }
  }

  [[nodiscard]] bool invalidationObservedLocked(
      std::uint64_t generation) const noexcept {
    return observedInvalidationGeneration.load(std::memory_order_acquire) >=
           generation;
  }
};

// ---------------------------------------------------------------- lifecycle

NativeLayerVideoOutput::NativeLayerVideoOutput(
    std::shared_ptr<State> state) noexcept
    : state_(std::move(state)) {}

NativeLayerVideoOutput::~NativeLayerVideoOutput() {
  const std::shared_ptr<State> state = state_;
  if (state == nullptr) {
    return;
  }
  state->releasePresentationOnceNoexcept();
  state->tracked.wakeGate.close();
  std::lock_guard lock(state->mutex);
  state->releaseAllLeasesLocked();
  state->tracked.wake = {};
}

std::shared_ptr<NativeLayerVideoOutput> NativeLayerVideoOutput::createTracked(
    void* displayLayer, NativeTrackedVideoOutputWakeSeam wake,
    std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  try {
    auto state = std::make_shared<State>();
    if (@available(macOS 14.0, *)) {
    } else {
      // Below macOS 14 there is no sampleBufferRenderer, and the deprecated
      // queue-management category is the only alternative. Refusing here keeps
      // the single construction site on the GL path rather than taking on
      // deprecated-API debt at birth (DESIGN.md section 8, risk 7).
      assignErrorNoexcept(
          error, "layer presentation requires macOS 14 or newer");
      return {};
    }
    @autoreleasepool {
      AVSampleBufferDisplayLayer* layer = nil;
      if (displayLayer != nullptr) {
        id candidate = (__bridge id)displayLayer;
        if (![candidate isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
          assignErrorNoexcept(
              error, "layer video output requires an AVSampleBufferDisplayLayer");
          return {};
        }
        layer = static_cast<AVSampleBufferDisplayLayer*>(candidate);
      } else {
        layer = [[AVSampleBufferDisplayLayer alloc] init];
      }
      if (layer == nil) {
        assignErrorNoexcept(error,
                            "layer video output could not obtain a display layer");
        return {};
      }
      id renderer = nil;
      if (@available(macOS 14.0, *)) {
        renderer = layer.sampleBufferRenderer;
      }
      if (renderer == nil) {
        assignErrorNoexcept(
            error, "layer video output requires macOS 14 sampleBufferRenderer");
        return {};
      }
      state->layer = layer;
      state->renderer = renderer;
    }
    state->tracked.wake = wake;
    auto output = std::shared_ptr<NativeLayerVideoOutput>(
        new NativeLayerVideoOutput(state));
    // Retained only once the output exists, so a throwing construction cannot
    // leak a share of the gate; released exactly once by closeProgress() or the
    // destructor. Nothing can submit a frame before this returns.
    state->presentationRetained.store(true, std::memory_order_release);
    retainNativeLayerPresentation();
    return output;
  } catch (...) {
    assignErrorNoexcept(error, "layer video output construction threw");
    return {};
  }
}

NativePresentationCapabilities
NativeLayerVideoOutput::presentationCapabilities() const noexcept {
  bool hasLayer = false;
  {
    std::lock_guard lock(state_->mutex);
    hasLayer = state_->layer != nil;
  }
  return {.presentsDecodedSurfacesDirectly = true,
          .samplesBeyondYuv420 = true,
          .convertsTransferAndGamut = true,
          .rationalDisplaySize = true,
          .quarterTurns = hasLayer};
}

bool NativeLayerVideoOutput::applyPresentationGeometry(
    media::MediaDisplaySize displaySize, int quarterTurnDegrees) noexcept {
  AVSampleBufferDisplayLayer* layer = nil;
  {
    std::lock_guard lock(state_->mutex);
    layer = state_->layer;
  }
  if (layer == nil) {
    return quarterTurnDegrees == 0;
  }
  return setNativeLayerPresentationRotation((__bridge void*)layer,
                                            quarterTurnDegrees) &&
         setNativeLayerPresentationDisplaySize((__bridge void*)layer,
                                               displaySize);
}

// ------------------------------------------------------------------ contract

NativeTrackedVideoCapacity NativeLayerVideoOutput::capacity(
    std::uint64_t generation) const noexcept {
  const std::shared_ptr<State> state = state_;
  std::lock_guard lock(state->mutex);
  return state->tracked.capacity(generation,
                                 generation == state->acceptedGeneration,
                                 state->usableLocked());
}

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
late_display_trace::Snapshot NativeLayerVideoOutput::diagnosticDisplayPhase() const noexcept {
  return state_ ? late_display_trace::sample((__bridge void*)state_->layer) : late_display_trace::Snapshot{};
}
#endif

NativeTrackedVideoSubmitStatus NativeLayerVideoOutput::submit(
    const FrameLease& frame, NativeTrackedFrameSequence sequence,
    std::string* error) noexcept {
  const std::shared_ptr<State> state = state_;
  if (error != nullptr) {
    error->clear();
  }
  if (!frame || !sequence.valid()) {
    assignErrorNoexcept(error, "tracked layer video submission is invalid");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  const FrameTiming& timing = frame.timing();
  // A frame that straddles the origin is admitted here and presented FROM the
  // origin by makeSampleBufferLocked, which keeps its end exact.
  if (!frameTimingPresentable(timing)) {
    assignErrorNoexcept(error, "tracked layer video timing is invalid");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  // The lease is cloned before the layer ever sees the surface: an accepted
  // submit means this output owns its own accounting token and the caller may
  // release theirs.
  std::optional<FrameLease> clone = frame.tryClone();
  if (!clone) {
    assignErrorNoexcept(
        error, "tracked layer video accounting token could not be cloned");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  FrameLease retained = std::move(*clone);

  bool signal = false;
  NativeTrackedVideoSubmitStatus result =
      NativeTrackedVideoSubmitStatus::Accepted;
  {

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
    if (media::late_trace::enabled) media::late_trace::worker.outputTicks[3] = mach_absolute_time();
#endif
    std::lock_guard lock(state->mutex);
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
    if (media::late_trace::enabled) media::late_trace::worker.outputTicks[4] = mach_absolute_time();
#endif

    switch (state->tracked.capacity(
        timing.generation, timing.generation == state->acceptedGeneration,
        state->usableLocked())) {
    case NativeTrackedVideoCapacity::Failed:
      assignErrorNoexcept(error, state->failureMessage.empty()
                                     ? std::string("layer video output failed")
                                     : state->failureMessage);
      return NativeTrackedVideoSubmitStatus::Failed;
    case NativeTrackedVideoCapacity::StaleGeneration:
      assignErrorNoexcept(error, "tracked layer video generation is stale");
      return NativeTrackedVideoSubmitStatus::StaleGeneration;
    case NativeTrackedVideoCapacity::Backpressure:
      return NativeTrackedVideoSubmitStatus::Backpressure;
    case NativeTrackedVideoCapacity::Available:
      break;
    }
    if (!state->tracked.advances(sequence)) {
      state->latchFailureLocked(
          "layer video frame sequence repeated or regressed");
      assignErrorNoexcept(error, state->failureMessage);
      return NativeTrackedVideoSubmitStatus::Failed;
    }

    if (@available(macOS 14.0, *)) {
    @autoreleasepool {
      AVSampleBufferVideoRenderer* renderer = state->renderer;
      if (renderer == nil) {
        state->latchFailureLocked("layer video output has no renderer");
        assignErrorNoexcept(error, state->failureMessage);
        return NativeTrackedVideoSubmitStatus::Failed;
      }
      if (renderer.requiresFlushToResumeDecoding) {
        ++state->healthCounters.requiresFlushNotifications;
        state->latchFailureLocked(
            "layer video renderer requires a flush to resume decoding");
        assignErrorNoexcept(error, state->failureMessage);
        return NativeTrackedVideoSubmitStatus::Failed;
      }

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
    if (media::late_trace::enabled) media::late_trace::worker.outputTicks[5] = mach_absolute_time();
#endif
      CMSampleBufferRef sampleBuffer = state->makeSampleBufferLocked(
          frame.pixelBuffer(), timing, error);
      if (sampleBuffer == nullptr) {
        state->latchFailureLocked(
            "layer video output could not stage the decoded frame");
        return NativeTrackedVideoSubmitStatus::Failed;
      }
      @try {

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
    if (media::late_trace::enabled) media::late_trace::worker.outputTicks[6] = mach_absolute_time();
#endif
        [renderer enqueueSampleBuffer:sampleBuffer];
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
    if (media::late_trace::enabled) media::late_trace::worker.outputTicks[7] = mach_absolute_time();
#endif

      } @catch (NSException*) {
        CFRelease(sampleBuffer);
        state->latchFailureLocked("layer video renderer rejected the frame");
        assignErrorNoexcept(error, state->failureMessage);
        return NativeTrackedVideoSubmitStatus::Failed;
      }
      CFRelease(sampleBuffer);

      // The acceptance edge. Anything other than Rendering means the renderer
      // did not take the frame, and no proof may be minted for it.
      if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSError* rendererError = renderer.error;
        state->latchFailureLocked(
            rendererError != nil
                ? rendererError.localizedDescription.UTF8String
                : "layer video renderer entered the failed state");
        assignErrorNoexcept(error, state->failureMessage);
        return NativeTrackedVideoSubmitStatus::Failed;
      }
    }
    } else {
      state->latchFailureLocked("layer presentation requires macOS 14 or newer");
      assignErrorNoexcept(error, state->failureMessage);
      return NativeTrackedVideoSubmitStatus::Failed;
    }

    // Admitted. Retire the predecessor's lease only now, one enqueue after it
    // stopped being the newest frame, so the renderer never holds an IOSurface
    // this process has stopped charging against NativeSurfaceBudget.
    state->retiringLease = std::move(state->admittedLease);
    state->admittedLease = std::move(retained);
    state->tracked.admit(sequence, timing);
    ++state->healthCounters.enqueuedFrames;
    state->noteRetentionLocked();

    if (state->dropDebt > 0) {
      --state->dropDebt;
      ++state->healthCounters.supersededByDropFrames;
      signal = state->publishFrameEventLocked(
          NativeTrackedVideoEventKind::FrameSuperseded);
    } else {
      signal = state->publishFrameEventLocked(
          NativeTrackedVideoEventKind::FrameDrawn);
    }
    if (!signal) {
      state->latchFailureLocked("layer video event sequence exhausted");
      assignErrorNoexcept(error, state->failureMessage);
      result = NativeTrackedVideoSubmitStatus::Failed;
    }

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
    if (media::late_trace::enabled) media::late_trace::worker.outputTicks[8] = mach_absolute_time();
#endif
    state->maybeLoadMetricsLocked();
  }
  if (signal) {
    state->signalWakeNoexcept();
  }
  return result;
}

std::optional<NativeTrackedVideoEvent>
NativeLayerVideoOutput::takeEvent() noexcept {
  const std::shared_ptr<State> state = state_;
  std::optional<NativeTrackedVideoEvent> result;
  {
    std::lock_guard lock(state->mutex);
    result = state->tracked.take();
  }
  return result;
}

NativeTrackedVideoOutputProgress NativeLayerVideoOutput::flushProgress(
    std::uint64_t retiredGeneration, std::uint64_t nextGeneration) noexcept {
  const std::shared_ptr<State> state = state_;
  bool mustApply = false;
  {
    std::lock_guard lock(state->mutex);
    const auto step = state->tracked.beginFlush(
        retiredGeneration, nextGeneration, state->usableLocked());
    if (const auto settled = NativeTrackedOutputProtocol::settled(step)) {
      return *settled;
    }
    // submit() publishes every admitted frame's terminal event in the same
    // locked section, so no frame here still awaits one.
    if (step == NativeTrackedOutputProtocol::Step::Started) {
      state->acceptedGeneration = nextGeneration;
      mustApply = true;
    }
  }
  if (mustApply) {
    // removeDisplayedImage:NO keeps the last frame on screen across a seek so
    // the window does not flash black between the flush and the post-seek IDR.
    state->beginRendererFlushNoexcept(false, nextGeneration);
    {
      std::lock_guard lock(state->mutex);
      ++state->healthCounters.flushes;
    }
  }
  {
    std::lock_guard lock(state->mutex);
    if (state->tracked.frameOutstanding() ||
        !state->invalidationObservedLocked(nextGeneration)) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    state->tracked.completeFlush();
    // The renderer has completed its flush, so it holds nothing of ours.
    state->releaseAllLeasesLocked();
    // Flush drops belong to the retired timeline; re-baseline rather than
    // charging them to the generation just armed.
    state->dropBaselineValid = false;
    state->dropDebt = 0;
    state->framesSinceMetricsLoad = 0;
  }
  return NativeTrackedVideoOutputProgress::Done;
}

NativeTrackedVideoOutputProgress NativeLayerVideoOutput::closeProgress(
    std::uint64_t finalGeneration) noexcept {
  const std::shared_ptr<State> state = state_;
  bool mustApply = false;
  {
    std::lock_guard lock(state->mutex);
    const auto step =
        state->tracked.beginClose(finalGeneration, state->acceptedGeneration);
    if (step == NativeTrackedOutputProtocol::Step::Done) {
      return state->tracked.detachWake()
                 ? NativeTrackedVideoOutputProgress::Done
                 : NativeTrackedVideoOutputProgress::Quiescing;
    }
    if (const auto settled = NativeTrackedOutputProtocol::settled(step)) {
      return *settled;
    }
    if (step == NativeTrackedOutputProtocol::Step::Started) {
      // Terminal invalidation moves this output onto the invalidation
      // generation, as flushProgress() moves it onto the flush target:
      // facts().generation reports acceptedGeneration, and the consumer's
      // post-close retirement gate requires it to equal the invalidation
      // generation. beginClose() proved finalGeneration > acceptedGeneration.
      state->acceptedGeneration = finalGeneration;
      mustApply = true;
    }
  }
  if (mustApply) {
    // Terminal teardown removes the displayed image: nothing of this timeline
    // may remain on screen once the route has closed.
    state->beginRendererFlushNoexcept(true, finalGeneration);
  }
  {
    std::lock_guard lock(state->mutex);
    if (state->tracked.frameOutstanding() ||
        !state->invalidationObservedLocked(finalGeneration)) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    if (!state->tracked.detachWake()) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    state->releaseAllLeasesLocked();
    state->tracked.completeClose();
  }
  // This output is no longer presenting. Once the last one has released, the
  // Qt video item resumes per-frame updates so a libmpv fallback still paints.
  state->releasePresentationOnceNoexcept();
  return NativeTrackedVideoOutputProgress::Done;
}

NativeTrackedVideoOutputFacts NativeLayerVideoOutput::facts() const noexcept {
  const std::shared_ptr<State> state = state_;
  std::lock_guard lock(state->mutex);
  return state->tracked.facts(state->acceptedGeneration,
                              state->tracked.closeDone, state->fatal);
}

#if defined(WAM_NATIVE_TEST_SEAMS)
NativeLayerVideoOutputHealth NativeLayerVideoOutput::health() const noexcept {
  const std::shared_ptr<State> state = state_;
  std::lock_guard lock(state->mutex);
  return state->healthCounters;
}
#endif

}  // namespace wam::macos
