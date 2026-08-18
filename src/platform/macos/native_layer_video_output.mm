#include "native_layer_video_output.hpp"

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

constexpr std::uint64_t kWakeClosedBit = std::uint64_t{1} << 63U;
constexpr std::uint64_t kWakeEntryMask = ~kWakeClosedBit;

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

  NativeTrackedVideoOutputWakeSeam wake{};
  std::atomic<std::uint64_t> wakeGate{0};

  // Generation lifecycle.
  std::uint64_t acceptedGeneration{0};
  std::uint64_t retiredGeneration{0};

  // Capacity-one admission and its terminal mailbox.
  NativeTrackedFrameSequence trackedFrame{};
  NativeTrackedFrameSequence lastTrackedFrame{};
  FrameTiming trackedTiming{};
  std::uint64_t trackedGeneration{0};
  std::optional<NativeTrackedVideoEvent> trackedEvent{};

  std::uint64_t nextEventSequence{0};
  std::uint64_t submittedFrames{0};
  std::uint64_t drawnFrames{0};
  std::uint64_t supersededFrames{0};

  // Lease retirement. admittedLease belongs to trackedFrame; retiringLease is
  // its predecessor, which the renderer may still be displaying. See
  // kRetainedFrameLeaseCeiling.
  FrameLease admittedLease{};
  FrameLease retiringLease{};

  bool failureLatched{false};
  std::string failureMessage;
  bool fatal{false};
  bool closed{false};

  bool flushPending{false};
  bool flushDone{false};
  std::uint64_t flushRetired{0};
  std::uint64_t flushNext{0};
  bool closePending{false};
  bool closeDone{false};
  std::uint64_t closeGeneration{0};

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

  ~State() {
    if (formatDescription != nullptr) {
      CFRelease(formatDescription);
      formatDescription = nullptr;
    }
  }

  // ---------------------------------------------------------------- wake gate

  void signalWakeNoexcept() noexcept {
    std::uint64_t current = wakeGate.load(std::memory_order_acquire);
    for (;;) {
      if ((current & kWakeClosedBit) != 0) {
        return;
      }
      if (wakeGate.compare_exchange_weak(current, current + 1,
                                         std::memory_order_acq_rel,
                                         std::memory_order_acquire)) {
        break;
      }
    }
    NativeTrackedVideoOutputWake signal = wake.signal;
    void* context = wake.context;
    if (signal != nullptr) {
      signal(context);
    }
    wakeGate.fetch_sub(1, std::memory_order_release);
  }

  void closeWakeGateNoexcept() noexcept {
    wakeGate.fetch_or(kWakeClosedBit, std::memory_order_acq_rel);
  }

  [[nodiscard]] bool wakeGateDrainedNoexcept() const noexcept {
    return (wakeGate.load(std::memory_order_acquire) & kWakeEntryMask) == 0;
  }

  // ------------------------------------------------------------- bookkeeping

  [[nodiscard]] bool nextEventSequenceLocked(std::uint64_t* sequence) noexcept {
    if (nextEventSequence == std::numeric_limits<std::uint64_t>::max()) {
      fatal = true;
      return false;
    }
    *sequence = ++nextEventSequence;
    return true;
  }

  [[nodiscard]] bool publishFrameEventLocked(
      NativeTrackedVideoEventKind kind) noexcept {
    if (!trackedFrame.valid() || trackedEvent) {
      return false;
    }
    std::uint64_t sequence = 0;
    if (!nextEventSequenceLocked(&sequence)) {
      return false;
    }
    trackedEvent.emplace(NativeTrackedVideoEvent{
        kind, sequence, trackedFrame, trackedGeneration, trackedTiming});
    if (kind == NativeTrackedVideoEventKind::FrameDrawn) {
      ++drawnFrames;
      ++healthCounters.drawnFrames;
    } else if (kind == NativeTrackedVideoEventKind::FrameSuperseded) {
      ++supersededFrames;
    }
    return true;
  }

  void latchFailureLocked(const char* message) noexcept {
    fatal = true;
    if (!failureLatched) {
      failureLatched = true;
      try {
        failureMessage = message;
      } catch (...) {
      }
    }
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
      // generation (DESIGN.md section 6: 157 drops of 783 on one mid-run
      // flush); charging those to the new generation would superseded-starve a
      // freshly armed timeline. Re-baseline instead.
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
    CMSampleTimingInfo sampleTiming{};
    sampleTiming.duration = timing.duration;
    sampleTiming.presentationTimeStamp = timing.presentationTime;
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
    // at most one frame ever reaches the screen -- a trap Phase A measured
    // directly (DESIGN.md section 3.1b, the totalNumberOfFrames = 9 run).
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
  setNativeLayerPresentationActive(false);
  state->closeWakeGateNoexcept();
  std::lock_guard lock(state->mutex);
  state->releaseAllLeasesLocked();
  state->wake = {};
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
    state->wake = wake;
    setNativeLayerPresentationActive(true);
    return std::shared_ptr<NativeLayerVideoOutput>(
        new NativeLayerVideoOutput(std::move(state)));
  } catch (...) {
    assignErrorNoexcept(error, "layer video output construction threw");
    return {};
  }
}

bool NativeLayerVideoOutput::startGeneration(std::uint64_t generation,
                                             std::string* error) noexcept {
  const std::shared_ptr<State> state = state_;
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard lock(state->mutex);
  if (state->failureLatched || state->fatal || state->closed ||
      state->closePending) {
    assignErrorNoexcept(error, "layer video output is not accepting generations");
    return false;
  }
  if (generation == 0 || generation <= state->acceptedGeneration ||
      state->flushPending) {
    assignErrorNoexcept(error, "layer video output generation is invalid");
    return false;
  }
  state->acceptedGeneration = generation;
  state->retiredGeneration = generation;
  state->dropBaselineValid = false;
  state->dropDebt = 0;
  state->observedInvalidationGeneration.store(generation,
                                              std::memory_order_release);
  return true;
}

// ------------------------------------------------------------------ contract

NativeTrackedVideoCapacity NativeLayerVideoOutput::capacity(
    std::uint64_t generation) const noexcept {
  const std::shared_ptr<State> state = state_;
  std::lock_guard lock(state->mutex);
  if (state->failureLatched || state->fatal) {
    return NativeTrackedVideoCapacity::Failed;
  }
  if (state->closed || state->closePending) {
    return NativeTrackedVideoCapacity::Failed;
  }
  if (generation == 0 || generation != state->acceptedGeneration) {
    return NativeTrackedVideoCapacity::StaleGeneration;
  }
  return state->trackedFrame.valid() || state->trackedEvent ||
                 state->flushPending
             ? NativeTrackedVideoCapacity::Backpressure
             : NativeTrackedVideoCapacity::Available;
}

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
  if (timing.generation == 0 || !CMTIME_IS_NUMERIC(timing.presentationTime) ||
      !CMTIME_IS_NUMERIC(timing.duration) ||
      CMTimeCompare(timing.presentationTime, kCMTimeZero) < 0 ||
      CMTimeCompare(timing.duration, kCMTimeZero) <= 0) {
    assignErrorNoexcept(error, "tracked layer video timing is invalid");
    return NativeTrackedVideoSubmitStatus::Failed;
  }
  // The lease is cloned before the layer ever sees the surface: an accepted
  // submit means this output owns its own accounting token and the caller may
  // release theirs.
  FrameLease retained(frame);
  if (!retained || retained.pixelBuffer() != frame.pixelBuffer()) {
    assignErrorNoexcept(
        error, "tracked layer video accounting token could not be cloned");
    return NativeTrackedVideoSubmitStatus::Failed;
  }

  bool signal = false;
  NativeTrackedVideoSubmitStatus result =
      NativeTrackedVideoSubmitStatus::Accepted;
  {
    std::lock_guard lock(state->mutex);
    if (state->failureLatched || state->fatal || state->closed ||
        state->closePending) {
      assignErrorNoexcept(error, state->failureMessage.empty()
                                     ? std::string("layer video output failed")
                                     : state->failureMessage);
      return NativeTrackedVideoSubmitStatus::Failed;
    }
    if (timing.generation != state->acceptedGeneration) {
      assignErrorNoexcept(error, "tracked layer video generation is stale");
      return NativeTrackedVideoSubmitStatus::StaleGeneration;
    }
    if (state->trackedFrame.valid() || state->trackedEvent ||
        state->flushPending) {
      return NativeTrackedVideoSubmitStatus::Backpressure;
    }
    if (state->lastTrackedFrame.valid() &&
        sequence.value <= state->lastTrackedFrame.value) {
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
      CMSampleBufferRef sampleBuffer = state->makeSampleBufferLocked(
          frame.pixelBuffer(), timing, error);
      if (sampleBuffer == nullptr) {
        state->latchFailureLocked(
            "layer video output could not stage the decoded frame");
        return NativeTrackedVideoSubmitStatus::Failed;
      }
      @try {
        [renderer enqueueSampleBuffer:sampleBuffer];
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
    state->trackedFrame = sequence;
    state->lastTrackedFrame = sequence;
    state->trackedTiming = timing;
    state->trackedGeneration = timing.generation;
    ++state->submittedFrames;
    ++state->healthCounters.enqueuedFrames;
    state->noteRetentionLocked();

    // The drop audit, folded into the proof rather than reported beside it.
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
    result = std::move(state->trackedEvent);
    state->trackedEvent.reset();
    if (result && result->frameSequence.valid()) {
      state->trackedFrame = {};
      state->trackedTiming = {};
      state->trackedGeneration = 0;
    }
  }
  return result;
}

NativeTrackedVideoOutputProgress NativeLayerVideoOutput::flushProgress(
    std::uint64_t retiredGeneration, std::uint64_t nextGeneration) noexcept {
  const std::shared_ptr<State> state = state_;
  bool mustApply = false;
  {
    std::lock_guard lock(state->mutex);
    if (state->failureLatched || state->fatal || state->closed ||
        state->closePending || nextGeneration == 0 ||
        nextGeneration <= retiredGeneration) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (state->flushDone && state->flushRetired == retiredGeneration &&
        state->flushNext == nextGeneration) {
      return NativeTrackedVideoOutputProgress::Done;
    }
    if (state->flushPending) {
      if (state->flushRetired != retiredGeneration ||
          state->flushNext != nextGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
    } else {
      if (retiredGeneration != state->retiredGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
      state->flushPending = true;
      state->flushDone = false;
      state->flushRetired = retiredGeneration;
      state->flushNext = nextGeneration;
      state->acceptedGeneration = nextGeneration;
      // An admitted frame cannot survive the flush that is about to discard it.
      // Superseded is the contract's only non-failure terminal for that.
      if (state->trackedFrame.valid() && !state->trackedEvent) {
        (void)state->publishFrameEventLocked(
            NativeTrackedVideoEventKind::FrameSuperseded);
      }
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
    if (state->trackedFrame.valid() || state->trackedEvent ||
        !state->invalidationObservedLocked(nextGeneration)) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    state->flushPending = false;
    state->flushDone = true;
    state->retiredGeneration = state->flushNext;
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
    if (state->closeDone) {
      if (state->closeGeneration != finalGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
      state->closeWakeGateNoexcept();
      if (!state->wakeGateDrainedNoexcept()) {
        return NativeTrackedVideoOutputProgress::Quiescing;
      }
      state->wake = {};
      return NativeTrackedVideoOutputProgress::Done;
    }
    if (finalGeneration == 0 ||
        (!state->closePending &&
         finalGeneration <= state->acceptedGeneration)) {
      return NativeTrackedVideoOutputProgress::Failed;
    }
    if (state->closePending) {
      if (state->closeGeneration != finalGeneration) {
        return NativeTrackedVideoOutputProgress::StaleGeneration;
      }
    } else {
      state->closePending = true;
      state->closeDone = false;
      state->closeGeneration = finalGeneration;
      if (state->trackedFrame.valid() && !state->trackedEvent) {
        (void)state->publishFrameEventLocked(
            NativeTrackedVideoEventKind::FrameSuperseded);
      }
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
    if (state->trackedFrame.valid() || state->trackedEvent ||
        !state->invalidationObservedLocked(finalGeneration)) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    state->closeWakeGateNoexcept();
    if (!state->wakeGateDrainedNoexcept()) {
      return NativeTrackedVideoOutputProgress::Quiescing;
    }
    state->wake = {};
    state->releaseAllLeasesLocked();
    state->flushPending = false;
    state->flushDone = false;
    state->flushRetired = 0;
    state->flushNext = 0;
    state->closePending = false;
    state->closeDone = true;
    state->closed = true;
  }
  // The route is no longer presenting; the Qt video item resumes per-frame
  // updates so a libmpv fallback still paints.
  setNativeLayerPresentationActive(false);
  return NativeTrackedVideoOutputProgress::Done;
}

NativeTrackedVideoOutputFacts NativeLayerVideoOutput::facts() const noexcept {
  const std::shared_ptr<State> state = state_;
  std::lock_guard lock(state->mutex);
  NativeTrackedVideoOutputFacts result;
  result.generation = state->acceptedGeneration;
  result.admittedFrame = state->trackedFrame;
  result.submittedFrames = state->submittedFrames;
  result.drawnFrames = state->drawnFrames;
  result.supersededFrames = state->supersededFrames;
  result.lastEventSequence = state->nextEventSequence;
  result.retainedFrames = state->retainedLeaseCountLocked();
  result.eventPending = state->trackedEvent.has_value();
  result.invalidationPending = state->flushPending || state->closePending;
  result.closed = state->closed;
  result.fatal = state->failureLatched || state->fatal;
  return result;
}

NativeLayerVideoOutputHealth NativeLayerVideoOutput::health() const noexcept {
  const std::shared_ptr<State> state = state_;
  std::lock_guard lock(state->mutex);
  return state->healthCounters;
}

}  // namespace wam::macos
