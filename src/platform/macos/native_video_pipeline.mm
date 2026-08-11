#include "native_video_pipeline.hpp"

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <exception>
#include <initializer_list>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <span>
#include <thread>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

constexpr std::size_t kFrameQueueCapacity = 3;
constexpr std::size_t kDecodeQueueHighWater = 2;
constexpr std::size_t kMaximumInFlightDecodeFrames = 2;
// This remains a hard surface-retention bound. Overflow is promoted to a
// decoder failure so an eventual runtime integration can fall back instead of
// silently dropping a valid long-reorder stream.
constexpr std::size_t kMaximumReorderFrames = 8;
// Until codec-derived DPB/reorder sizing lands, cap the dormant experiment at
// 1080p. Its application-retained worst case is 17 decoded leases (queue,
// decode, reorder, scheduling, GPU) plus two BGRA drawables: about 66 MiB for
// NV12 or 117 MiB for P010. VideoToolbox's private pool is additional.
constexpr std::uint64_t kMaximumCodedPixels = 1920ULL * 1080ULL;
constexpr std::size_t kMaximumCodecConfigurationBytes = 1024ULL * 1024ULL;
// Reject corrupt or adversarial access units before either the demux scratch
// allocation or VideoToolbox's CMBlockBuffer copy. Valid 1080p H.264/HEVC
// access units are normally orders of magnitude smaller than this ceiling.
constexpr std::size_t kMaximumCompressedSampleBytes = 32ULL * 1024ULL * 1024ULL;
constexpr double kClockLeadSeconds = 1.0 / 120.0;
constexpr double kPausedFrameToleranceSeconds = 1.0 / 1000.0;
constexpr double kMaximumSeekPrerollSeconds = 12.0;

void assignError(std::string* error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

std::string describeNSError(NSError* error, const char* fallback) {
  if (error == nil || error.localizedDescription == nil) {
    return fallback;
  }
  const char* text = error.localizedDescription.UTF8String;
  return text == nullptr ? fallback : std::string(text);
}

bool finiteNonnegative(double value) noexcept {
  return std::isfinite(value) && value >= 0.0;
}

double seconds(CMTime time) noexcept {
  if (!CMTIME_IS_NUMERIC(time)) {
    return std::numeric_limits<double>::quiet_NaN();
  }
  return CMTimeGetSeconds(time);
}

CMTime mediaTime(double value) noexcept {
  return CMTimeMakeWithSeconds(std::max(0.0, value), 60'000);
}

bool sampleIsKeyFrame(CMSampleBufferRef sample) noexcept {
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    return true;
  }
  auto attachment = static_cast<CFDictionaryRef>(
      CFArrayGetValueAtIndex(attachments, 0));
  auto notSync = static_cast<CFBooleanRef>(
      CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_NotSync));
  return notSync == nullptr || !CFBooleanGetValue(notSync);
}

bool extensionIsAbsentOrOneOf(
    CMVideoFormatDescriptionRef format, CFStringRef key,
    std::initializer_list<CFStringRef> supportedValues) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(format, key);
  if (value == nullptr) {
    return true;
  }
  if (CFGetTypeID(value) != CFStringGetTypeID()) {
    return false;
  }
  return std::any_of(supportedValues.begin(), supportedValues.end(),
                     [value](CFStringRef supported) {
                       return supported != nullptr && CFEqual(value, supported);
                     });
}

bool hasExtension(CMVideoFormatDescriptionRef format,
                  CFStringRef key) noexcept {
  return CMFormatDescriptionGetExtension(format, key) != nullptr;
}

bool hasUnsupportedColorMetadata(
    CMVideoFormatDescriptionRef format) noexcept {
  // The current shader/layer contract is explicitly SDR BT.709 output. Missing
  // metadata follows the conventional SD=BT.601/HD=BT.709 matrix inference;
  // every explicit value outside that narrow contract is rejected.
  if (!extensionIsAbsentOrOneOf(
          format, kCMFormatDescriptionExtension_ColorPrimaries,
          {kCMFormatDescriptionColorPrimaries_ITU_R_709_2}) ||
      !extensionIsAbsentOrOneOf(
          format, kCMFormatDescriptionExtension_TransferFunction,
          {kCMFormatDescriptionTransferFunction_ITU_R_709_2}) ||
      !extensionIsAbsentOrOneOf(
          format, kCMFormatDescriptionExtension_YCbCrMatrix,
          {kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
           kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4}) ||
      !extensionIsAbsentOrOneOf(
          format, kCMFormatDescriptionExtension_ChromaLocationTopField,
          {kCMFormatDescriptionChromaLocation_Center,
           kCMFormatDescriptionChromaLocation_Left}) ||
      !extensionIsAbsentOrOneOf(
          format, kCMFormatDescriptionExtension_ChromaLocationBottomField,
          {kCMFormatDescriptionChromaLocation_Center,
           kCMFormatDescriptionChromaLocation_Left}) ||
      hasExtension(format, kCMFormatDescriptionExtension_GammaLevel) ||
      hasExtension(format, kCMFormatDescriptionExtension_ICCProfile) ||
      hasExtension(
          format,
          kCMFormatDescriptionExtension_MasteringDisplayColorVolume) ||
      hasExtension(format,
                   kCMFormatDescriptionExtension_ContentLightLevelInfo) ||
      hasExtension(
          format,
          kCMFormatDescriptionExtension_AlternativeTransferCharacteristics) ||
      hasExtension(format, kCMFormatDescriptionExtension_AlphaChannelMode) ||
      hasExtension(format,
                   kCMFormatDescriptionExtension_ContainsAlphaChannel)) {
    return true;
  }

  if (@available(macOS 14.0, *)) {
    if (hasExtension(format,
                     kCMFormatDescriptionExtension_ContentColorVolume)) {
      return true;
    }
  }
  if (@available(macOS 14.2, *)) {
    if (hasExtension(format,
                     kCMFormatDescriptionExtension_LogTransferFunction)) {
      return true;
    }
  }

  CFTypeRef bits = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_BitsPerComponent);
  if (bits != nullptr) {
    if (CFGetTypeID(bits) != CFNumberGetTypeID()) {
      return true;
    }
    std::int32_t bitDepth = 0;
    if (!CFNumberGetValue(static_cast<CFNumberRef>(bits), kCFNumberSInt32Type,
                          &bitDepth) ||
        (bitDepth != 8 && bitDepth != 10)) {
      return true;
    }
  }
  return false;
}

bool isProgressiveFormat(CMVideoFormatDescriptionRef format) noexcept {
  if (hasExtension(format, kCMFormatDescriptionExtension_FieldDetail)) {
    return false;
  }
  CFTypeRef count = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_FieldCount);
  if (count == nullptr) {
    return true;
  }
  if (CFGetTypeID(count) != CFNumberGetTypeID()) {
    return false;
  }
  std::int32_t fields = 0;
  return CFNumberGetValue(static_cast<CFNumberRef>(count),
                          kCFNumberSInt32Type, &fields) &&
         fields == 1;
}

bool hasDolbyVisionConfiguration(CMVideoFormatDescriptionRef format) noexcept {
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
  if (extensions == nullptr) {
    return false;
  }
  auto atoms = static_cast<CFDictionaryRef>(CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
  if (atoms == nullptr) {
    return false;
  }
  return CFDictionaryContainsKey(atoms, CFSTR("dvcC")) ||
         CFDictionaryContainsKey(atoms, CFSTR("dvvC")) ||
         CFDictionaryContainsKey(atoms, CFSTR("dvwC"));
}

std::optional<std::vector<std::byte>> copyCodecConfiguration(
    CMVideoFormatDescriptionRef format, CMVideoCodecType codec) {
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
  if (extensions == nullptr) {
    return std::nullopt;
  }
  auto atoms = static_cast<CFDictionaryRef>(CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
  if (atoms == nullptr) {
    return std::nullopt;
  }
  const CFStringRef atomName =
      codec == kCMVideoCodecType_H264   ? CFSTR("avcC")
      : codec == kCMVideoCodecType_HEVC ? CFSTR("hvcC")
                                        : nullptr;
  if (atomName == nullptr) {
    return std::nullopt;
  }
  auto atom = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, atomName));
  if (atom == nullptr || CFGetTypeID(atom) != CFDataGetTypeID()) {
    return std::nullopt;
  }
  const CFIndex length = CFDataGetLength(atom);
  if (length <= 0 ||
      static_cast<std::uint64_t>(length) >
          kMaximumCodecConfigurationBytes) {
    return std::nullopt;
  }
  std::vector<std::byte> result(static_cast<std::size_t>(length));
  std::memcpy(result.data(), CFDataGetBytePtr(atom), result.size());
  return result;
}

class NotifyingFrameSink final : public DecodedFrameSink {
 public:
  using Notification = std::function<void()>;

  NotifyingFrameSink(std::size_t capacity, std::uint64_t generation,
                     Notification notification)
      : queue_(capacity, generation), notification_(std::move(notification)) {}

  FrameEnqueueResult enqueue(FrameLease frame, std::string* error) override {
    const FrameEnqueueResult result = queue_.enqueue(std::move(frame), error);
    if (result == FrameEnqueueResult::Accepted && notification_) {
      notification_();
    }
    return result;
  }

  void endOfStream(std::uint64_t generation) override {
    queue_.endOfStream(generation);
    if (notification_) {
      notification_();
    }
  }

  void flush(std::uint64_t generation) noexcept override {
    queue_.flush(generation);
    if (notification_) {
      notification_();
    }
  }

  std::optional<FrameLease> tryTake() { return queue_.tryTake(); }
  std::size_t size() const noexcept { return queue_.size(); }
  std::size_t capacity() const noexcept { return queue_.capacity(); }
  bool reachedEndOfStream() const noexcept {
    return queue_.reachedEndOfStream();
  }

 private:
  BoundedFrameQueue queue_;
  Notification notification_;
};

struct AtomicPipelineStats {
  std::atomic<std::uint64_t> compressedSamplesRead{0};
  std::atomic<std::uint64_t> compressedSamplesSubmitted{0};
  std::atomic<std::uint64_t> presentedFrames{0};
  std::atomic<std::uint64_t> lateFramesDropped{0};
  std::atomic<std::uint64_t> staleFramesDropped{0};
  std::atomic<std::uint64_t> presenterBackpressureEvents{0};
  std::atomic<std::uint64_t> drawableUnavailableEvents{0};
  std::atomic<std::uint64_t> displayLinkTicks{0};

  void reset() noexcept {
    compressedSamplesRead.store(0, std::memory_order_relaxed);
    compressedSamplesSubmitted.store(0, std::memory_order_relaxed);
    presentedFrames.store(0, std::memory_order_relaxed);
    lateFramesDropped.store(0, std::memory_order_relaxed);
    staleFramesDropped.store(0, std::memory_order_relaxed);
    presenterBackpressureEvents.store(0, std::memory_order_relaxed);
    drawableUnavailableEvents.store(0, std::memory_order_relaxed);
    displayLinkTicks.store(0, std::memory_order_relaxed);
  }
};

class PipelineFailureState final {
 public:
  std::uint64_t beginAttempt() noexcept {
    std::lock_guard lock(mutex_);
    ++epoch_;
    enabled_ = true;
    reported_ = false;
    lastError_.reset();
    active_.store(false, std::memory_order_release);
    return epoch_;
  }

  void activate(std::uint64_t epoch) noexcept {
    std::lock_guard lock(mutex_);
    if (enabled_ && epoch_ == epoch && !reported_) {
      active_.store(true, std::memory_order_release);
    }
  }

  void disable() noexcept {
    active_.store(false, std::memory_order_release);
    std::lock_guard lock(mutex_);
    enabled_ = false;
    reported_ = false;
    lastError_.reset();
    ++epoch_;
  }

  void reportCurrent(std::string message) noexcept {
    std::uint64_t epoch = 0;
    {
      std::lock_guard lock(mutex_);
      epoch = epoch_;
    }
    report(epoch, std::move(message));
  }

  void report(std::uint64_t epoch, std::string message) noexcept {
    std::lock_guard lock(mutex_);
    if (!enabled_ || epoch != epoch_ || reported_) {
      return;
    }
    reported_ = true;
    lastError_ = std::move(message);
    active_.store(false, std::memory_order_release);
  }

  [[nodiscard]] bool active() const noexcept {
    return active_.load(std::memory_order_acquire);
  }

  std::optional<std::string> takeLastError() noexcept {
    std::lock_guard lock(mutex_);
    std::optional<std::string> result = std::move(lastError_);
    lastError_.reset();
    return result;
  }

 private:
  mutable std::mutex mutex_;
  std::uint64_t epoch_{0};
  bool enabled_{false};
  bool reported_{false};
  std::optional<std::string> lastError_;
  std::atomic<bool> active_{false};
};

}  // namespace

struct NativeVideoPipeline::Impl {
  Impl()
      : failureState(std::make_shared<PipelineFailureState>()),
        presentationQueue(dispatch_queue_create(
            "com.wesleymaa.wam.native-video-present", DISPATCH_QUEUE_SERIAL)),
        presentationSource(nil) {}

  ~Impl() { shutdown(); }

  std::shared_ptr<PipelineFailureState> failureState;
  std::unique_ptr<MetalLayerPresenter> presenter;
  std::unique_ptr<NotifyingFrameSink> sink;
  std::unique_ptr<VideoToolboxDecoder> decoder;

  __strong AVURLAsset* asset{nil};
  __strong AVAssetTrack* track{nil};
  __strong AVAssetReader* activeReader{nil};
  CMTime assetDuration{kCMTimeInvalid};
  CMVideoCodecType codec{0};
  CMVideoDimensions dimensions{0, 0};
  std::vector<std::byte> codecConfiguration;

  mutable std::mutex stateMutex;
  std::condition_variable workerWake;
  std::thread worker;
  bool stopWorker{false};
  std::uint64_t seekVersion{0};
  double requestedSeekSeconds{0.0};

  mutable std::mutex clockMutex;
  double clockMediaSeconds{0.0};
  double clockAnchorHostSeconds{0.0};
  double clockRate{1.0};
  bool clockPaused{true};

  mutable std::mutex presentationMutex;
  std::optional<FrameLease> heldFrame;
  std::optional<FrameLease> retryFrame;
  double minimumPresentationSeconds{0.0};

  mutable std::mutex displayLinkMutex;
  CVDisplayLinkRef displayLink{nullptr};
  __strong dispatch_queue_t presentationQueue;
  __strong dispatch_source_t presentationSource{nil};

  std::atomic<bool> attached{false};
  std::atomic<bool> prepared{false};
  std::atomic<bool> pausedPresentationNeeded{false};
  std::atomic<std::uint64_t> requestedGeneration{0};
  AtomicPipelineStats counters;

  void initializePresentationSource() {
    presentationSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, presentationQueue);
    Impl* self = this;
    dispatch_source_set_event_handler(presentationSource, ^{
      @autoreleasepool {
        self->renderAtAudioClock();
      }
    });
    dispatch_resume(presentationSource);
  }

  void notifyFrameAvailable() noexcept {
    workerWake.notify_all();
    bool paused = true;
    {
      std::lock_guard lock(clockMutex);
      paused = clockPaused;
    }
    if (paused && pausedPresentationNeeded.load(std::memory_order_acquire) &&
        presentationSource != nil) {
      dispatch_source_merge_data(presentationSource, 1);
    }
  }

  static CVReturn displayLinkCallback(CVDisplayLinkRef,
                                      const CVTimeStamp*,
                                      const CVTimeStamp*,
                                      CVOptionFlags,
                                      CVOptionFlags*, void* context) {
    auto* self = static_cast<Impl*>(context);
    self->counters.displayLinkTicks.fetch_add(1, std::memory_order_relaxed);
    if (self->failureState->active() &&
        self->presentationSource != nil) {
      // A DATA_ADD source coalesces ticks when Metal is still presenting the
      // preceding frame. The real-time display-link callback never allocates,
      // locks the presenter, or calls nextDrawable.
      dispatch_source_merge_data(self->presentationSource, 1);
    }
    return kCVReturnSuccess;
  }

  bool createDisplayLink(std::string* error) {
    const CVReturn createStatus =
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    if (createStatus != kCVReturnSuccess || displayLink == nullptr) {
      assignError(error, "CVDisplayLink creation failed: " +
                             std::to_string(createStatus));
      return false;
    }
    const CVReturn callbackStatus = CVDisplayLinkSetOutputCallback(
        displayLink, &Impl::displayLinkCallback, this);
    if (callbackStatus != kCVReturnSuccess) {
      CVDisplayLinkRelease(displayLink);
      displayLink = nullptr;
      assignError(error, "CVDisplayLink callback setup failed: " +
                             std::to_string(callbackStatus));
      return false;
    }
    return true;
  }

  void setDisplayLinkRunning(bool running) noexcept {
    std::lock_guard lock(displayLinkMutex);
    if (displayLink == nullptr) {
      return;
    }
    const bool isRunning = CVDisplayLinkIsRunning(displayLink);
    if (running && !isRunning) {
      CVDisplayLinkStart(displayLink);
    } else if (!running && isRunning) {
      CVDisplayLinkStop(displayLink);
    }
  }

  double audioClockNow(bool* pausedOut = nullptr) const noexcept {
    std::lock_guard lock(clockMutex);
    if (pausedOut != nullptr) {
      *pausedOut = clockPaused;
    }
    if (clockPaused) {
      return clockMediaSeconds;
    }
    const double elapsed =
        std::max(0.0, CACurrentMediaTime() - clockAnchorHostSeconds);
    return std::max(0.0, clockMediaSeconds + elapsed * clockRate);
  }

  double normalizePosition(double positionSeconds) const noexcept {
    const double durationSeconds = seconds(assetDuration);
    return finiteNonnegative(durationSeconds)
               ? std::min(positionSeconds, durationSeconds)
               : positionSeconds;
  }

  std::optional<FrameLease> takeNextFrame() {
    if (heldFrame) {
      auto result = std::move(heldFrame);
      heldFrame.reset();
      return result;
    }
    auto frame = sink == nullptr ? std::nullopt : sink->tryTake();
    if (frame) {
      workerWake.notify_all();
    }
    return frame;
  }

  void renderAtAudioClock() noexcept {
    if (!failureState->active() || presenter == nullptr ||
        sink == nullptr) {
      return;
    }

    std::lock_guard presentationLock(presentationMutex);
    bool paused = true;
    const double target = audioClockNow(&paused);
    const double threshold = paused ? target + kPausedFrameToleranceSeconds
                                    : target + kClockLeadSeconds;
    const std::uint64_t generation =
        requestedGeneration.load(std::memory_order_acquire);
    std::optional<FrameLease> due = std::move(retryFrame);
    retryFrame.reset();

    while (auto candidate = takeNextFrame()) {
      if (candidate->timing().generation != generation) {
        counters.staleFramesDropped.fetch_add(1, std::memory_order_relaxed);
        continue;
      }
      const double pts = seconds(candidate->timing().presentationTime);
      if (!finiteNonnegative(pts)) {
        reportFailure("decoded native frame has an invalid timestamp");
        return;
      }
      if (pts + kPausedFrameToleranceSeconds < minimumPresentationSeconds) {
        counters.staleFramesDropped.fetch_add(1, std::memory_order_relaxed);
        continue;
      }
      if (pts > threshold) {
        if (paused && !due) {
          // An exact seek commonly lands between frame timestamps. While the
          // clock is paused, show the nearest frame at/after the target rather
          // than retaining it forever waiting for a clock that cannot move.
          due = std::move(*candidate);
        } else {
          heldFrame = std::move(*candidate);
        }
        break;
      }
      if (due) {
        counters.lateFramesDropped.fetch_add(1, std::memory_order_relaxed);
      }
      due = std::move(*candidate);
      if (paused) {
        break;
      }
    }

    if (!due) {
      return;
    }

    std::string error;
    const MetalPresentResult result = presenter->present(*due, &error);
    switch (result) {
    case MetalPresentResult::Presented:
      counters.presentedFrames.fetch_add(1, std::memory_order_relaxed);
      if (paused) {
        pausedPresentationNeeded.store(false, std::memory_order_release);
      }
      break;
    case MetalPresentResult::Backpressure:
      counters.presenterBackpressureEvents.fetch_add(
          1, std::memory_order_relaxed);
      retryFrame = std::move(*due);
      break;
    case MetalPresentResult::DrawableUnavailable:
      counters.drawableUnavailableEvents.fetch_add(
          1, std::memory_order_relaxed);
      retryFrame = std::move(*due);
      break;
    case MetalPresentResult::Failed:
      reportFailure(error.empty() ? "native Metal presentation failed"
                                  : std::move(error));
      break;
    }
  }

  void reportFailure(std::string message) noexcept {
    failureState->reportCurrent(std::move(message));
  }

  CMTime syncSampleStart(double targetSeconds) const noexcept {
    const CMTime target = mediaTime(targetSeconds);
    AVSampleCursor* cursor =
        [track makeSampleCursorWithPresentationTimeStamp:target];
    if (cursor == nil) {
      // Some AVFoundation importers return nil instead of clamping a request
      // beyond their final presentation timestamp. Start from the last decode-
      // order sample rather than accidentally decoding the whole file from 0.
      cursor = [track makeSampleCursorAtLastSampleInDecodeOrder];
    }
    if (cursor == nil) {
      return kCMTimeInvalid;
    }
    constexpr std::size_t kMaximumCursorWalk = 100'000;
    for (std::size_t count = 0; count < kMaximumCursorWalk; ++count) {
      if (cursor.currentSampleSyncInfo.sampleIsFullSync) {
        const CMTime timestamp = cursor.presentationTimeStamp;
        return CMTIME_IS_NUMERIC(timestamp) &&
                       CMTimeCompare(timestamp, kCMTimeZero) >= 0
                   ? timestamp
                   : kCMTimeInvalid;
      }
      if ([cursor stepInDecodeOrderByCount:-1] == 0) {
        break;
      }
    }
    return kCMTimeInvalid;
  }

  AVAssetReader* createReader(double targetSeconds,
                              AVAssetReaderTrackOutput** output,
                              std::string* error) {
    *output = nil;
    NSError* readerError = nil;
    AVAssetReader* reader =
        [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (reader == nil) {
      assignError(error,
                  describeNSError(readerError,
                                  "AVFoundation reader creation failed"));
      return nil;
    }
    AVAssetReaderTrackOutput* trackOutput =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                                         outputSettings:nil];
    trackOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:trackOutput]) {
      assignError(error,
                  "AVFoundation cannot expose compressed samples for this "
                  "video track");
      return nil;
    }
    [reader addOutput:trackOutput];

    const double durationSeconds = seconds(assetDuration);
    const double boundedTargetSeconds =
        finiteNonnegative(durationSeconds)
            ? std::min(targetSeconds, durationSeconds)
            : targetSeconds;
    const CMTime start = syncSampleStart(boundedTargetSeconds);
    if (!CMTIME_IS_NUMERIC(start)) {
      assignError(error,
                  "AVFoundation could not locate a full-sync sample for the "
                  "requested native seek");
      return nil;
    }
    const double startSeconds = seconds(start);
    if (!finiteNonnegative(startSeconds) ||
        boundedTargetSeconds - startSeconds > kMaximumSeekPrerollSeconds) {
      assignError(error,
                  "native seek would require more than 12 seconds of hidden "
                  "preroll and must fall back instead of decoding from zero");
      return nil;
    }
    if (CMTIME_IS_NUMERIC(assetDuration) &&
        CMTimeCompare(assetDuration, start) > 0) {
      reader.timeRange =
          CMTimeRangeMake(start, CMTimeSubtract(assetDuration, start));
    } else {
      reader.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);
    }
    if (![reader startReading]) {
      assignError(error,
                  describeNSError(reader.error,
                                  "AVFoundation could not start reading"));
      return nil;
    }
    *output = trackOutput;
    return reader;
  }

  bool requestChanged(std::uint64_t version) const noexcept {
    std::lock_guard lock(stateMutex);
    return stopWorker || seekVersion != version;
  }

  bool waitForDecodeCapacity(std::uint64_t version) {
    std::unique_lock lock(stateMutex);
    workerWake.wait(lock, [this, version] {
      return stopWorker || seekVersion != version || sink == nullptr ||
             sink->size() < kDecodeQueueHighWater;
    });
    return !stopWorker && seekVersion == version;
  }

  bool submitSample(CMSampleBufferRef sample, std::uint64_t generation,
                    std::uint64_t version, bool& submittedSyncSample) {
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    if (block == nullptr || CMBlockBufferGetDataLength(block) == 0) {
      return true;
    }
    if (CMSampleBufferGetNumSamples(sample) != 1) {
      reportFailure("native demux received an unsupported multi-sample "
                    "compressed buffer");
      return false;
    }

    const std::size_t dataLength = CMBlockBufferGetDataLength(block);
    if (dataLength > kMaximumCompressedSampleBytes) {
      reportFailure("compressed video sample exceeds the 32 MiB native "
                    "decoder memory bound");
      return false;
    }
    char* contiguousData = nullptr;
    std::size_t lengthAtOffset = 0;
    std::size_t totalLength = 0;
    const OSStatus pointerStatus = CMBlockBufferGetDataPointer(
        block, 0, &lengthAtOffset, &totalLength, &contiguousData);
    std::vector<std::byte> scratch;
    const std::byte* bytes = nullptr;
    if (pointerStatus == noErr && contiguousData != nullptr &&
        lengthAtOffset == dataLength && totalLength == dataLength) {
      bytes = reinterpret_cast<const std::byte*>(contiguousData);
    } else {
      scratch.resize(dataLength);
      const OSStatus copyStatus = CMBlockBufferCopyDataBytes(
          block, 0, dataLength, scratch.data());
      if (copyStatus != noErr) {
        reportFailure("AVFoundation compressed sample copy failed: " +
                      std::to_string(copyStatus));
        return false;
      }
      bytes = scratch.data();
    }

    const bool keyFrame = sampleIsKeyFrame(sample);
    if (!keyFrame && !submittedSyncSample) {
      return true;
    }
    const CompressedVideoPacket packet{
        std::span<const std::byte>(bytes, dataLength),
        CMSampleBufferGetPresentationTimeStamp(sample),
        CMSampleBufferGetDecodeTimeStamp(sample),
        CMSampleBufferGetDuration(sample),
        generation,
        keyFrame,
        false};

    while (!requestChanged(version)) {
      std::string decodeError;
      const VideoDecodeSubmitResult result =
          decoder->submit(packet, &decodeError);
      if (result == VideoDecodeSubmitResult::Accepted) {
        submittedSyncSample = submittedSyncSample || keyFrame;
        counters.compressedSamplesSubmitted.fetch_add(
            1, std::memory_order_relaxed);
        return true;
      }
      if (result == VideoDecodeSubmitResult::Rejected) {
        reportFailure(decodeError.empty() ? "VideoToolbox rejected a packet"
                                          : std::move(decodeError));
        return false;
      }

      // Backpressure without a delivered frame can only last for the short
      // interval until a VideoToolbox callback completes. The decoder does not
      // expose that condition variable, so use a bounded timed wait here; the
      // normal queue-consumption path is entirely notification-driven.
      std::unique_lock lock(stateMutex);
      workerWake.wait_for(lock, std::chrono::milliseconds(4),
                          [this, version] {
                            return stopWorker || seekVersion != version;
                          });
    }
    return false;
  }

  bool runReaderSession(double targetSeconds, std::uint64_t generation,
                        std::uint64_t version) {
    @autoreleasepool {
      AVAssetReaderTrackOutput* output = nil;
      std::string readerError;
      AVAssetReader* reader = createReader(targetSeconds, &output, &readerError);
      if (reader == nil) {
        reportFailure(std::move(readerError));
        return false;
      }
      {
        std::lock_guard lock(stateMutex);
        if (stopWorker || seekVersion != version) {
          [reader cancelReading];
          return false;
        }
        activeReader = reader;
      }

      bool reachedEnd = false;
      bool submittedSyncSample = false;
      while (!requestChanged(version)) {
        if (sink->size() >= kDecodeQueueHighWater &&
            !waitForDecodeCapacity(version)) {
          break;
        }
        CMSampleBufferRef sample = [output copyNextSampleBuffer];
        if (sample == nullptr) {
          reachedEnd = reader.status == AVAssetReaderStatusCompleted;
          if (!reachedEnd && reader.status == AVAssetReaderStatusFailed) {
            reportFailure(describeNSError(reader.error,
                                          "AVFoundation video read failed"));
          } else if (!reachedEnd &&
                     reader.status != AVAssetReaderStatusCancelled &&
                     !requestChanged(version)) {
            reportFailure("AVFoundation stopped producing compressed video "
                          "samples unexpectedly");
          }
          break;
        }

        counters.compressedSamplesRead.fetch_add(1,
                                                 std::memory_order_relaxed);
        const bool accepted = submitSample(sample, generation, version,
                                           submittedSyncSample);
        CFRelease(sample);
        if (!accepted) {
          break;
        }
      }

      {
        std::lock_guard lock(stateMutex);
        if (activeReader == reader) {
          activeReader = nil;
        }
      }
      if (reachedEnd && !requestChanged(version) &&
          failureState->active()) {
        CompressedVideoPacket end;
        end.generation = generation;
        end.endOfStream = true;
        std::string endError;
        if (decoder->submit(end, &endError) !=
            VideoDecodeSubmitResult::Accepted) {
          reportFailure(endError.empty() ? "VideoToolbox end-of-stream drain "
                                           "failed"
                                         : std::move(endError));
          return false;
        }
      }
      return reachedEnd;
    }
  }

  void workerLoop() {
    std::uint64_t processedVersion = 0;
    std::uint64_t decoderGeneration =
        requestedGeneration.load(std::memory_order_acquire);
    while (true) {
      double target = 0.0;
      std::uint64_t version = 0;
      std::uint64_t generation = 0;
      {
        std::unique_lock lock(stateMutex);
        workerWake.wait(lock, [this, processedVersion] {
          return stopWorker || seekVersion != processedVersion;
        });
        if (stopWorker) {
          break;
        }
        target = requestedSeekSeconds;
        version = seekVersion;
        generation = requestedGeneration.load(std::memory_order_acquire);
      }

      if (generation != decoderGeneration) {
        decoder->flush(generation);
        decoderGeneration = generation;
      }
      processedVersion = version;
      runReaderSession(target, generation, version);
      // At EOF the worker sleeps without polling until a seek or shutdown.
    }
  }

  void startWorker(double initialPosition) {
    {
      std::lock_guard lock(stateMutex);
      stopWorker = false;
      requestedSeekSeconds = initialPosition;
      ++seekVersion;
    }
    worker = std::thread([this] {
      try {
        workerLoop();
      } catch (const std::bad_alloc&) {
        reportFailure("native video worker exhausted its bounded memory "
                      "allocation");
      } catch (const std::exception& exception) {
        try {
          reportFailure(std::string("native video worker failed: ") +
                        exception.what());
        } catch (...) {
          reportFailure("native video worker failed");
        }
      } catch (...) {
        reportFailure("native video worker failed with an unknown error");
      }
    });
    workerWake.notify_all();
  }

  void stopWorkerThread() noexcept {
    AVAssetReader* reader = nil;
    {
      std::lock_guard lock(stateMutex);
      stopWorker = true;
      ++seekVersion;
      reader = activeReader;
    }
    if (reader != nil) {
      [reader cancelReading];
    }
    workerWake.notify_all();
    if (worker.joinable()) {
      worker.join();
    }
    {
      std::lock_guard lock(stateMutex);
      activeReader = nil;
    }
  }

  void shutdown() noexcept {
    failureState->disable();
    prepared.store(false, std::memory_order_release);
    if (presenter != nullptr) {
      presenter->setFailureHandler({}, {});
    }
    setDisplayLinkRunning(false);
    stopWorkerThread();
    if (decoder != nullptr) {
      decoder->close();
    }
    if (presentationSource != nil) {
      dispatch_source_cancel(presentationSource);
      dispatch_sync(presentationQueue, ^{});
      presentationSource = nil;
    }
    {
      std::lock_guard lock(presentationMutex);
      heldFrame.reset();
      retryFrame.reset();
    }
    if (displayLink != nullptr) {
      CVDisplayLinkRelease(displayLink);
      displayLink = nullptr;
    }
  }
};

NativeVideoPipeline::NativeVideoPipeline(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

NativeVideoPipeline::~NativeVideoPipeline() = default;

std::unique_ptr<NativeVideoPipeline> NativeVideoPipeline::create(
    std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  auto impl = std::make_unique<Impl>();
  impl->presenter = MetalLayerPresenter::create(error);
  if (impl->presenter == nullptr) {
    return nullptr;
  }
  impl->initializePresentationSource();
  if (!impl->createDisplayLink(error)) {
    return nullptr;
  }
  return std::unique_ptr<NativeVideoPipeline>(
      new NativeVideoPipeline(std::move(impl)));
}

bool NativeVideoPipeline::attachToView(void* nativeView, std::string* error) {
  if (!impl_->presenter->attachToView(nativeView, error)) {
    impl_->attached.store(false, std::memory_order_release);
    return false;
  }
  impl_->attached.store(true, std::memory_order_release);
  const bool active = impl_->failureState->active();
  impl_->presenter->setVisible(active);
  if (active) {
    // Headless preparation may already have filled the bounded queue while the
    // clock is paused. Wake the serial presenter immediately on attachment;
    // there may be no future decode callback or display-link tick to do it.
    impl_->pausedPresentationNeeded.store(true, std::memory_order_release);
    dispatch_source_merge_data(impl_->presentationSource, 1);
  }
  return true;
}

void NativeVideoPipeline::detach() noexcept {
  stop();
  impl_->presenter->detach();
  impl_->attached.store(false, std::memory_order_release);
}

void NativeVideoPipeline::resize(double widthPoints, double heightPoints,
                                 double backingScale) noexcept {
  impl_->presenter->resize(widthPoints, heightPoints, backingScale);
}

NativeVideoPrepareResult NativeVideoPipeline::prepareLocalFile(
    const std::filesystem::path& path, double initialPositionSeconds,
    std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  stop();
  std::error_code fileError;
  if (!std::filesystem::is_regular_file(path, fileError)) {
    assignError(error, "native video requires a readable local file");
    return NativeVideoPrepareResult::Failed;
  }
  NSString* filePath = [NSString stringWithUTF8String:path.c_str()];
  if (filePath == nil) {
    assignError(error, "native video path is not valid UTF-8");
    return NativeVideoPrepareResult::Failed;
  }
  NSURL* url = [NSURL fileURLWithPath:filePath];
  AVURLAsset* asset = [AVURLAsset
      URLAssetWithURL:url
              options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (!asset.playable || asset.hasProtectedContent) {
    assignError(error, "protected or unplayable media uses the libmpv path");
    return NativeVideoPrepareResult::Unsupported;
  }
  NSArray<AVAssetTrack*>* tracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  NSArray<AVAssetTrack*>* audioTracks =
      [asset tracksWithMediaType:AVMediaTypeAudio];
  NSArray<AVAssetTrack*>* subtitleTracks =
      [asset tracksWithMediaType:AVMediaTypeSubtitle];
  NSArray<AVAssetTrack*>* textTracks =
      [asset tracksWithMediaType:AVMediaTypeText];
  NSArray<AVAssetTrack*>* closedCaptionTracks =
      [asset tracksWithMediaType:AVMediaTypeClosedCaption];
#pragma clang diagnostic pop
  if (tracks.count != 1) {
    assignError(error,
                "native video requires exactly one video track; multi-angle "
                "and track-selected media use libmpv");
    return NativeVideoPrepareResult::Unsupported;
  }
  if (audioTracks.count == 0) {
    assignError(error,
                "native video currently requires an audio track as its "
                "authoritative playback clock");
    return NativeVideoPrepareResult::Unsupported;
  }
  if (subtitleTracks.count != 0 || textTracks.count != 0 ||
      closedCaptionTracks.count != 0) {
    assignError(error,
                "embedded subtitle, text, and closed-caption tracks require "
                "the libmpv compositor");
    return NativeVideoPrepareResult::Unsupported;
  }
  AVAssetTrack* track = tracks.firstObject;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSArray* descriptions = track.formatDescriptions;
  const CGAffineTransform transform = track.preferredTransform;
  const CMTime duration = asset.duration;
#pragma clang diagnostic pop
  if (descriptions.count != 1) {
    assignError(error,
                "video tracks with missing or changing format descriptions "
                "use libmpv");
    return NativeVideoPrepareResult::Unsupported;
  }
  auto format = (__bridge CMVideoFormatDescriptionRef)descriptions.firstObject;
  const CMVideoCodecType codec = CMFormatDescriptionGetMediaSubType(format);
  if (codec != kCMVideoCodecType_H264 && codec != kCMVideoCodecType_HEVC) {
    assignError(error, "native video currently supports H.264 and HEVC");
    return NativeVideoPrepareResult::Unsupported;
  }
  if (!CGAffineTransformIsIdentity(transform)) {
    assignError(error, "rotated video currently uses the libmpv renderer");
    return NativeVideoPrepareResult::Unsupported;
  }
  if (!isProgressiveFormat(format)) {
    assignError(error,
                "interlaced video currently requires libmpv deinterlacing");
    return NativeVideoPrepareResult::Unsupported;
  }
  if (hasUnsupportedColorMetadata(format) ||
      hasDolbyVisionConfiguration(format)) {
    assignError(error,
                "video color metadata is outside the native SDR BT.709/601 "
                "contract and requires libmpv color management");
    return NativeVideoPrepareResult::Unsupported;
  }

  const CMVideoDimensions dimensions =
      CMVideoFormatDescriptionGetDimensions(format);
  const CGSize presentationDimensions =
      CMVideoFormatDescriptionGetPresentationDimensions(format, true, true);
  if (dimensions.width <= 0 || dimensions.height <= 0) {
    assignError(error, "video track has invalid coded dimensions");
    return NativeVideoPrepareResult::Unsupported;
  }
  const std::uint64_t codedPixels =
      static_cast<std::uint64_t>(dimensions.width) *
      static_cast<std::uint64_t>(dimensions.height);
  if (codedPixels > kMaximumCodedPixels) {
    assignError(error,
                "native video above 1080p exceeds the experiment's bounded "
                "decoded-surface budget and uses libmpv");
    return NativeVideoPrepareResult::Unsupported;
  }
  if (std::abs(presentationDimensions.width - dimensions.width) > 0.5 ||
      std::abs(presentationDimensions.height - dimensions.height) > 0.5) {
    assignError(error,
                "non-square pixels or a cropped aperture currently use "
                "libmpv");
    return NativeVideoPrepareResult::Unsupported;
  }
  auto configuration = copyCodecConfiguration(format, codec);
  if (!configuration) {
    assignError(error, "video track lacks an avcC/hvcC configuration atom");
    return NativeVideoPrepareResult::Unsupported;
  }

  const std::uint64_t generation =
      impl_->requestedGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
  impl_->asset = asset;
  impl_->track = track;
  impl_->assetDuration = duration;
  impl_->codec = codec;
  impl_->dimensions = dimensions;
  impl_->codecConfiguration = std::move(*configuration);
  impl_->sink = std::make_unique<NotifyingFrameSink>(
      kFrameQueueCapacity, generation,
      [state = impl_.get()] { state->notifyFrameAvailable(); });
  impl_->decoder = std::make_unique<VideoToolboxDecoder>(
      VideoToolboxDecoderOptions{kMaximumInFlightDecodeFrames,
                                 kMaximumReorderFrames});
  const VideoStreamConfiguration stream{
      codec,
      dimensions,
      std::span<const std::byte>(impl_->codecConfiguration),
      true,
      true,
      generation};
  std::string decoderError;
  if (!impl_->decoder->configure(stream, *impl_->sink, &decoderError)) {
    impl_->decoder.reset();
    impl_->sink.reset();
    impl_->asset = nil;
    impl_->track = nil;
    impl_->codecConfiguration.clear();
    assignError(error, decoderError.empty()
                           ? "hardware VideoToolbox decode is unavailable"
                           : std::move(decoderError));
    return NativeVideoPrepareResult::Unsupported;
  }

  impl_->counters.reset();
  const std::uint64_t failureEpoch = impl_->failureState->beginAttempt();
  std::weak_ptr<PipelineFailureState> weakFailureState = impl_->failureState;
  impl_->presenter->setFailureHandler(
      impl_->failureState,
      [weakFailureState, failureEpoch](std::string message) {
        if (auto state = weakFailureState.lock()) {
          state->report(failureEpoch, std::move(message));
        }
      });
  impl_->minimumPresentationSeconds = impl_->normalizePosition(
      finiteNonnegative(initialPositionSeconds) ? initialPositionSeconds : 0.0);
  {
    std::lock_guard lock(impl_->presentationMutex);
    impl_->heldFrame.reset();
    impl_->retryFrame.reset();
  }
  {
    std::lock_guard lock(impl_->clockMutex);
    impl_->clockMediaSeconds = impl_->minimumPresentationSeconds;
    impl_->clockAnchorHostSeconds = CACurrentMediaTime();
    impl_->clockRate = 1.0;
    impl_->clockPaused = true;
  }
  impl_->pausedPresentationNeeded.store(true, std::memory_order_release);
  impl_->prepared.store(true, std::memory_order_release);
  impl_->failureState->activate(failureEpoch);
  impl_->presenter->setVisible(true);
  impl_->startWorker(impl_->minimumPresentationSeconds);
  return NativeVideoPrepareResult::Ready;
}

void NativeVideoPipeline::stop() noexcept {
  impl_->failureState->disable();
  impl_->prepared.store(false, std::memory_order_release);
  impl_->presenter->setFailureHandler({}, {});
  impl_->setDisplayLinkRunning(false);
  impl_->stopWorkerThread();
  if (impl_->decoder != nullptr) {
    impl_->decoder->close();
  }
  dispatch_sync(impl_->presentationQueue, ^{});
  {
    std::lock_guard lock(impl_->presentationMutex);
    impl_->heldFrame.reset();
    impl_->retryFrame.reset();
  }
  impl_->presenter->setVisible(false);
  impl_->decoder.reset();
  impl_->sink.reset();
  impl_->asset = nil;
  impl_->track = nil;
  impl_->activeReader = nil;
  impl_->codecConfiguration.clear();
  impl_->assetDuration = kCMTimeInvalid;
}

void NativeVideoPipeline::updateAudioClock(double positionSeconds, bool paused,
                                           double rate) noexcept {
  if (!finiteNonnegative(positionSeconds) || !std::isfinite(rate) ||
      rate <= 0.0) {
    return;
  }
  {
    std::lock_guard lock(impl_->clockMutex);
    impl_->clockMediaSeconds = positionSeconds;
    impl_->clockAnchorHostSeconds = CACurrentMediaTime();
    impl_->clockRate = rate;
    impl_->clockPaused = paused;
  }
  const bool shouldRun =
      impl_->failureState->active() && !paused;
  impl_->setDisplayLinkRunning(shouldRun);
  if (paused && impl_->failureState->active()) {
    impl_->pausedPresentationNeeded.store(true, std::memory_order_release);
    dispatch_source_merge_data(impl_->presentationSource, 1);
  }
}

void NativeVideoPipeline::seek(double positionSeconds) noexcept {
  if (!impl_->failureState->active() ||
      !finiteNonnegative(positionSeconds)) {
    return;
  }
  positionSeconds = impl_->normalizePosition(positionSeconds);
  const std::uint64_t generation =
      impl_->requestedGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
  (void)generation;
  AVAssetReader* reader = nil;
  {
    std::lock_guard lock(impl_->stateMutex);
    impl_->requestedSeekSeconds = positionSeconds;
    ++impl_->seekVersion;
    reader = impl_->activeReader;
  }
  {
    std::lock_guard lock(impl_->presentationMutex);
    impl_->minimumPresentationSeconds = positionSeconds;
    impl_->heldFrame.reset();
    impl_->retryFrame.reset();
  }
  impl_->pausedPresentationNeeded.store(true, std::memory_order_release);
  if (reader != nil) {
    [reader cancelReading];
  }
  impl_->workerWake.notify_all();
  dispatch_source_merge_data(impl_->presentationSource, 1);
}

bool NativeVideoPipeline::attached() const noexcept {
  return impl_->attached.load(std::memory_order_acquire);
}

bool NativeVideoPipeline::active() const noexcept {
  return impl_->failureState->active();
}

std::optional<std::string> NativeVideoPipeline::takeLastError() noexcept {
  return impl_->failureState->takeLastError();
}

NativeVideoPipelineStats NativeVideoPipeline::stats() const noexcept {
  NativeVideoPipelineStats result;
  result.prepared = impl_->prepared.load(std::memory_order_acquire);
  result.active = impl_->failureState->active();
  result.generation =
      impl_->requestedGeneration.load(std::memory_order_acquire);
  result.compressedSamplesRead =
      impl_->counters.compressedSamplesRead.load(std::memory_order_relaxed);
  result.compressedSamplesSubmitted =
      impl_->counters.compressedSamplesSubmitted.load(
          std::memory_order_relaxed);
  result.presentedFrames =
      impl_->counters.presentedFrames.load(std::memory_order_relaxed);
  result.lateFramesDropped =
      impl_->counters.lateFramesDropped.load(std::memory_order_relaxed);
  result.staleFramesDropped =
      impl_->counters.staleFramesDropped.load(std::memory_order_relaxed);
  result.presenterBackpressureEvents =
      impl_->counters.presenterBackpressureEvents.load(
          std::memory_order_relaxed);
  result.drawableUnavailableEvents =
      impl_->counters.drawableUnavailableEvents.load(
          std::memory_order_relaxed);
  result.displayLinkTicks =
      impl_->counters.displayLinkTicks.load(std::memory_order_relaxed);
  if (impl_->sink != nullptr) {
    result.queueDepth = impl_->sink->size();
    result.queueCapacity = impl_->sink->capacity();
  }
  if (impl_->decoder != nullptr) {
    result.decoder = impl_->decoder->stats();
    result.hardwareDecode =
        result.decoder.usingHardwareAcceleratedDecoder;
  }
  if (impl_->presenter != nullptr) {
    result.presenter = impl_->presenter->stats();
  }
  return result;
}

}  // namespace wam::macos
