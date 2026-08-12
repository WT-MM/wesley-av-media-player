#include "native_video_pipeline.hpp"

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <array>
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
#include <type_traits>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

constexpr std::size_t kFrameQueueCapacity = 3;
constexpr std::size_t kDecodeQueueHighWater = 2;
constexpr std::size_t kMaximumInFlightDecodeFrames = 2;
// The decoder conservatively takes the maximum declared reorder depth across
// the H.264/HEVC configuration record and retains no more than that window.
// This is the dormant experiment's ceiling; a production fallback selector is
// not wired yet.
constexpr std::size_t kMaximumReorderFrames = 8;
// Cap the dormant experiment at a 1920x1080 coded-pixel budget. Its
// application-retained worst case is
// 17 decoded leases (queue, decode, reorder, scheduling, GPU) plus two BGRA
// drawables: about 66 MiB for NV12 or 117 MiB for P010. Two bounded compressed
// copies, demux scratch, and VideoToolbox's private pool are additional.
constexpr std::uint64_t kMaximumCodedPixels = 1920ULL * 1080ULL;
constexpr std::size_t kMaximumCodecConfigurationBytes = 1024ULL * 1024ULL;
// Reject corrupt or adversarial access units before either the demux scratch
// allocation or VideoToolbox's CMBlockBuffer copy. Valid 1080p H.264/HEVC
// access units are normally orders of magnitude smaller than this ceiling.
constexpr std::size_t kMaximumCompressedSampleBytes = 32ULL * 1024ULL * 1024ULL;
constexpr double kClockLeadSeconds = 1.0 / 120.0;
constexpr double kPausedFrameToleranceSeconds = 1.0 / 1000.0;
constexpr double kMaximumSeekPrerollSeconds = 12.0;

// A wedged Apple callback is not forcibly cancellable. Keep the process-wide
// resource bound at one preparing/running/retiring native attempt so repeatedly
// destroying frontends cannot accumulate self-owned VideoToolbox sessions.
std::atomic<bool> gNativeAttemptAdmission{false};

#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
std::atomic<bool> gFailNextPipelineWrapperAllocation{false};
#endif

constexpr const char* kPresentationExceptionError =
    "native video presentation exhausted its bounded memory";
constexpr const char* kWorkerAllocationError =
    "native video worker exhausted its bounded memory";
constexpr const char* kWorkerExceptionError = "native video worker failed";
constexpr const char* kDisplayLinkStartError =
    "native video display link could not start";
constexpr const char* kDisplayLinkStopError =
    "native video display link could not stop cleanly";

void assignError(std::string* error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

void assignFixedErrorNoexcept(std::string* error, const char* message) noexcept {
  if (error == nullptr) {
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
    assignFixedErrorNoexcept(error,
                             "native Qt OpenGL output startup failed");
  }
}

class ScopedSampleBuffer final {
 public:
  explicit ScopedSampleBuffer(CMSampleBufferRef sample) noexcept
      : sample_(sample) {}
  ScopedSampleBuffer(const ScopedSampleBuffer&) = delete;
  ScopedSampleBuffer& operator=(const ScopedSampleBuffer&) = delete;
  ~ScopedSampleBuffer() {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

  [[nodiscard]] CMSampleBufferRef get() const noexcept { return sample_; }
  [[nodiscard]] explicit operator bool() const noexcept {
    return sample_ != nullptr;
  }

 private:
  CMSampleBufferRef sample_{nullptr};
};

template <typename Callback>
class ScopeExit final {
 public:
  explicit ScopeExit(Callback callback) noexcept(
      std::is_nothrow_move_constructible_v<Callback>)
      : callback_(std::move(callback)) {}
  ScopeExit(const ScopeExit&) = delete;
  ScopeExit& operator=(const ScopeExit&) = delete;
  ~ScopeExit() noexcept { callback_(); }

 private:
  Callback callback_;
};

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

bool probeCompressedSampleExtraction(AVAsset* asset, AVAssetTrack* track,
                                     CMVideoCodecType expectedCodec,
                                     std::string* error) {
  NSError* readerError = nil;
  AVAssetReader* reader =
      [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
  if (reader == nil) {
    assignError(error,
                describeNSError(readerError,
                                "AVFoundation reader probe failed"));
    return false;
  }
  AVAssetReaderTrackOutput* output =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                                       outputSettings:nil];
  if (output == nil) {
    assignError(error,
                "AVFoundation could not create a compressed-sample output");
    return false;
  }
  output.alwaysCopiesSampleData = NO;
  if (![reader canAddOutput:output]) {
    assignError(error,
                "AVFoundation cannot expose the original compressed video "
                "samples");
    return false;
  }
  [reader addOutput:output];
  if (![reader startReading]) {
    assignError(error,
                describeNSError(reader.error,
                                "AVFoundation compressed-sample probe could "
                                "not start"));
    return false;
  }

  constexpr std::size_t kMaximumProbeSamples = 64;
  bool foundCompressedSample = false;
  std::string invalidSampleError;
  for (std::size_t index = 0; index < kMaximumProbeSamples; ++index) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == nullptr) {
      break;
    }
    const CMFormatDescriptionRef sampleFormat =
        CMSampleBufferGetFormatDescription(sample);
    CMBlockBufferRef data = CMSampleBufferGetDataBuffer(sample);
    const std::size_t dataLength =
        data == nullptr ? 0 : CMBlockBufferGetDataLength(data);
    if (dataLength == 0) {
      CFRelease(sample);
      continue;
    }
    const bool usable = CMSampleBufferGetNumSamples(sample) == 1 &&
                        sampleFormat != nullptr &&
                        CMFormatDescriptionGetMediaSubType(sampleFormat) ==
                            expectedCodec &&
                        dataLength <= kMaximumCompressedSampleBytes;
    CFRelease(sample);
    if (usable) {
      foundCompressedSample = true;
      break;
    }
    invalidSampleError =
        "AVFoundation yielded a compressed video sample outside the native "
        "codec or memory contract";
    break;
  }
  const std::string readerDiagnostic =
      describeNSError(reader.error,
                      "AVFoundation did not yield a bounded compressed "
                      "video sample");
  [reader cancelReading];
  if (!foundCompressedSample) {
    assignError(error, invalidSampleError.empty() ? readerDiagnostic
                                                  : invalidSampleError);
  }
  return foundCompressedSample;
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
  std::atomic<std::uint64_t> scheduledFrames{0};
  std::atomic<std::uint64_t> dispatchedFrames{0};
  std::atomic<std::uint64_t> presentedFrames{0};
  std::atomic<std::uint64_t> lateFramesDropped{0};
  std::atomic<std::uint64_t> staleFramesDropped{0};
  std::atomic<std::uint64_t> presenterBackpressureEvents{0};
  std::atomic<std::uint64_t> drawableUnavailableEvents{0};
  std::atomic<std::uint64_t> displayLinkTicks{0};

  void reset() noexcept {
    compressedSamplesRead.store(0, std::memory_order_relaxed);
    compressedSamplesSubmitted.store(0, std::memory_order_relaxed);
    scheduledFrames.store(0, std::memory_order_relaxed);
    dispatchedFrames.store(0, std::memory_order_relaxed);
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
    fixedError_ = nullptr;
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
    fixedError_ = nullptr;
    ++epoch_;
  }

  void disablePreservingError() noexcept {
    active_.store(false, std::memory_order_release);
    std::lock_guard lock(mutex_);
    enabled_ = false;
    reported_ = false;
    ++epoch_;
  }

  std::optional<std::uint64_t> reportCurrent(
      std::string message) noexcept {
    std::lock_guard lock(mutex_);
    if (!enabled_ || reported_) {
      return std::nullopt;
    }
    reported_ = true;
    lastError_ = std::move(message);
    fixedError_ = nullptr;
    active_.store(false, std::memory_order_release);
    return epoch_;
  }

  std::optional<std::uint64_t> reportFixedCurrent(
      const char* message) noexcept {
    std::lock_guard lock(mutex_);
    if (!enabled_ || reported_) {
      return std::nullopt;
    }
    reported_ = true;
    lastError_.reset();
    fixedError_ = message;
    active_.store(false, std::memory_order_release);
    return epoch_;
  }

  bool report(std::uint64_t epoch, std::string message) noexcept {
    std::lock_guard lock(mutex_);
    if (!enabled_ || epoch != epoch_ || reported_) {
      return false;
    }
    reported_ = true;
    lastError_ = std::move(message);
    fixedError_ = nullptr;
    active_.store(false, std::memory_order_release);
    return true;
  }

  bool reportFixed(std::uint64_t epoch, const char* message) noexcept {
    std::lock_guard lock(mutex_);
    if (!enabled_ || epoch != epoch_ || reported_) {
      return false;
    }
    reported_ = true;
    lastError_.reset();
    fixedError_ = message;
    active_.store(false, std::memory_order_release);
    return true;
  }

  [[nodiscard]] bool active() const noexcept {
    return active_.load(std::memory_order_acquire);
  }

  [[nodiscard]] bool failed(std::uint64_t epoch) const noexcept {
    std::lock_guard lock(mutex_);
    return !enabled_ || epoch_ != epoch || reported_;
  }

  std::optional<std::string> takeLastError() noexcept {
    std::lock_guard lock(mutex_);
    if (lastError_.has_value()) {
      std::optional<std::string> result = std::move(lastError_);
      lastError_.reset();
      fixedError_ = nullptr;
      return result;
    }
    if (fixedError_ == nullptr) {
      return std::nullopt;
    }
    const char* message = fixedError_;
    fixedError_ = nullptr;
    try {
      return std::string(message);
    } catch (...) {
      // The failure is already latched and the pipeline is inactive. Preserve
      // the noexcept API even if diagnostics cannot be materialized yet.
      return std::string{};
    }
  }

 private:
  mutable std::mutex mutex_;
  std::uint64_t epoch_{0};
  bool enabled_{false};
  bool reported_{false};
  std::optional<std::string> lastError_;
  const char* fixedError_{nullptr};
  std::atomic<bool> active_{false};
};

}  // namespace

NativeVideoContainerAdmissionHint nativeVideoContainerAdmissionHint(
    std::string_view path) noexcept {
  const std::size_t separator = path.find_last_of("/\\");
  const std::size_t dot = path.find_last_of('.');
  const std::size_t basenameStart =
      separator == std::string_view::npos ? 0 : separator + 1;
  if (dot == std::string_view::npos ||
      (separator != std::string_view::npos && dot < separator) ||
      dot == basenameStart ||
      dot + 1 >= path.size()) {
    return {};
  }
  const std::string_view extension = path.substr(dot + 1);
  const auto is = [extension](std::string_view expected) noexcept {
    if (extension.size() != expected.size()) {
      return false;
    }
    for (std::size_t index = 0; index < extension.size(); ++index) {
      const char value = extension[index];
      const char folded = value >= 'A' && value <= 'Z'
                              ? static_cast<char>(value - 'A' + 'a')
                              : value;
      if (folded != expected[index]) {
        return false;
      }
    }
    return true;
  };

  if (is("mp4") || is("m4v")) {
    return {NativeVideoContainerFamily::IsoBaseMedia,
            NativeVideoDemuxPreference::AvFoundation};
  }
  if (is("mov") || is("qt")) {
    return {NativeVideoContainerFamily::QuickTime,
            NativeVideoDemuxPreference::AvFoundation};
  }
  if (is("mkv") || is("mk3d") || is("mka")) {
    return {NativeVideoContainerFamily::Matroska,
            NativeVideoDemuxPreference::ExternalBridgeRequired};
  }
  if (is("webm")) {
    return {NativeVideoContainerFamily::WebM,
            NativeVideoDemuxPreference::ExternalBridgeRequired};
  }
  if (is("avi")) {
    return {NativeVideoContainerFamily::Avi,
            NativeVideoDemuxPreference::ProbeAvFoundation};
  }
  if (is("ts") || is("mts") || is("m2ts")) {
    return {NativeVideoContainerFamily::MpegTransportStream,
            NativeVideoDemuxPreference::ProbeAvFoundation};
  }
  if (is("ogg") || is("ogv")) {
    return {NativeVideoContainerFamily::Ogg,
            NativeVideoDemuxPreference::ExternalBridgeRequired};
  }
  if (is("flv")) {
    return {NativeVideoContainerFamily::FlashVideo,
            NativeVideoDemuxPreference::ExternalBridgeRequired};
  }
  return {};
}

NativeVideoCodecAdmission nativeVideoCodecAdmission(
    std::uint32_t mediaSubtype) noexcept {
  if (mediaSubtype == kCMVideoCodecType_H264) {
    return NativeVideoCodecAdmission::H264;
  }
  if (mediaSubtype == kCMVideoCodecType_HEVC) {
    return NativeVideoCodecAdmission::Hevc;
  }
  return NativeVideoCodecAdmission::Unsupported;
}

namespace {

class CodecRbspBitReader final {
 public:
  explicit CodecRbspBitReader(
      std::span<const std::uint8_t> escapedBytes) noexcept
      : bytes_(escapedBytes) {}

  [[nodiscard]] bool readBits(std::size_t count,
                              std::uint32_t& value) noexcept {
    if (count > 32) {
      return false;
    }
    value = 0;
    for (std::size_t index = 0; index < count; ++index) {
      if (bitsRemaining_ == 0 && !loadByte()) {
        return false;
      }
      value = (value << 1U) |
              ((currentByte_ >> (bitsRemaining_ - 1U)) & 1U);
      --bitsRemaining_;
    }
    return true;
  }

  [[nodiscard]] bool readUnsignedExpGolomb(
      std::uint32_t& value) noexcept {
    std::size_t leadingZeroBits = 0;
    std::uint32_t bit = 0;
    while (true) {
      if (!readBits(1, bit)) {
        return false;
      }
      if (bit != 0) {
        break;
      }
      if (++leadingZeroBits > 31) {
        return false;
      }
    }
    std::uint32_t suffix = 0;
    if (!readBits(leadingZeroBits, suffix)) {
      return false;
    }
    const std::uint64_t decoded =
        ((std::uint64_t{1} << leadingZeroBits) - 1U) + suffix;
    if (decoded > std::numeric_limits<std::uint32_t>::max()) {
      return false;
    }
    value = static_cast<std::uint32_t>(decoded);
    return true;
  }

 private:
  [[nodiscard]] bool loadByte() noexcept {
    while (offset_ < bytes_.size()) {
      const std::uint8_t value = bytes_[offset_++];
      if (zeroCount_ >= 2 && value == 0x03U) {
        if (offset_ >= bytes_.size() || bytes_[offset_] > 0x03U) {
          return false;
        }
        zeroCount_ = 0;
        continue;
      }
      zeroCount_ = value == 0 ? zeroCount_ + 1 : 0;
      currentByte_ = value;
      bitsRemaining_ = 8;
      return true;
    }
    return false;
  }

  std::span<const std::uint8_t> bytes_;
  std::size_t offset_{0};
  std::size_t zeroCount_{0};
  std::uint8_t currentByte_{0};
  std::size_t bitsRemaining_{0};
};

NativeVideoSampleFormatAdmission h264SampleFormatAdmission(
    std::span<const std::byte> configuration) noexcept {
  const auto bytes = std::span<const std::uint8_t>(
      reinterpret_cast<const std::uint8_t*>(configuration.data()),
      configuration.size());
  if (bytes.size() < 8 || bytes[0] != 1) {
    return NativeVideoSampleFormatAdmission::Unsupported;
  }
  const std::size_t spsCount = bytes[5] & 0x1fU;
  std::size_t offset = 6;
  if (spsCount == 0) {
    return NativeVideoSampleFormatAdmission::Unsupported;
  }
  for (std::size_t index = 0; index < spsCount; ++index) {
    if (offset + 2 > bytes.size()) {
      return NativeVideoSampleFormatAdmission::Unsupported;
    }
    const std::size_t length =
        (static_cast<std::size_t>(bytes[offset]) << 8U) | bytes[offset + 1];
    offset += 2;
    if (length < 5 || length > bytes.size() - offset ||
        (bytes[offset] & 0x1fU) != 7U) {
      return NativeVideoSampleFormatAdmission::Unsupported;
    }

    CodecRbspBitReader bits(bytes.subspan(offset + 1, length - 1));
    std::uint32_t profile = 0;
    std::uint32_t ignored = 0;
    if (!bits.readBits(8, profile) || !bits.readBits(8, ignored) ||
        !bits.readBits(8, ignored) ||
        !bits.readUnsignedExpGolomb(ignored)) {
      return NativeVideoSampleFormatAdmission::Unsupported;
    }
    if (profile != bytes[1] ||
        (profile != 66 && profile != 77 && profile != 88 && profile != 100)) {
      return NativeVideoSampleFormatAdmission::Unsupported;
    }
    if (profile == 100) {
      std::uint32_t chromaFormat = 0;
      std::uint32_t lumaDepthMinusEight = 0;
      std::uint32_t chromaDepthMinusEight = 0;
      if (!bits.readUnsignedExpGolomb(chromaFormat) || chromaFormat != 1 ||
          !bits.readUnsignedExpGolomb(lumaDepthMinusEight) ||
          !bits.readUnsignedExpGolomb(chromaDepthMinusEight) ||
          lumaDepthMinusEight != 0 || chromaDepthMinusEight != 0) {
        return NativeVideoSampleFormatAdmission::Unsupported;
      }
    }
    offset += length;
  }
  return NativeVideoSampleFormatAdmission::Yuv420EightBit;
}

NativeVideoSampleFormatAdmission hevcSampleFormatAdmission(
    std::span<const std::byte> configuration) noexcept {
  const auto bytes = std::span<const std::uint8_t>(
      reinterpret_cast<const std::uint8_t*>(configuration.data()),
      configuration.size());
  if (bytes.size() < 23 || bytes[0] != 1 || (bytes[16] & 0x03U) != 1U) {
    return NativeVideoSampleFormatAdmission::Unsupported;
  }
  const std::uint8_t lumaDepthMinusEight = bytes[17] & 0x07U;
  const std::uint8_t chromaDepthMinusEight = bytes[18] & 0x07U;
  if (lumaDepthMinusEight != chromaDepthMinusEight ||
      (lumaDepthMinusEight != 0 && lumaDepthMinusEight != 2)) {
    return NativeVideoSampleFormatAdmission::Unsupported;
  }

  const auto skipProfileTierLevel = [](CodecRbspBitReader& bits,
                                       std::uint32_t subLayers) noexcept {
    std::uint32_t ignored = 0;
    if (!bits.readBits(32, ignored) || !bits.readBits(32, ignored) ||
        !bits.readBits(32, ignored)) {
      return false;
    }
    std::array<std::uint32_t, 8> profilePresent{};
    std::array<std::uint32_t, 8> levelPresent{};
    for (std::uint32_t layer = 0; layer < subLayers; ++layer) {
      if (!bits.readBits(1, profilePresent[layer]) ||
          !bits.readBits(1, levelPresent[layer])) {
        return false;
      }
    }
    if (subLayers > 0) {
      for (std::uint32_t layer = subLayers; layer < 8; ++layer) {
        if (!bits.readBits(2, ignored)) {
          return false;
        }
      }
    }
    for (std::uint32_t layer = 0; layer < subLayers; ++layer) {
      if (profilePresent[layer] &&
          (!bits.readBits(32, ignored) || !bits.readBits(32, ignored) ||
           !bits.readBits(24, ignored))) {
        return false;
      }
      if (levelPresent[layer] && !bits.readBits(8, ignored)) {
        return false;
      }
    }
    return true;
  };

  std::size_t offset = 23;
  bool foundSps = false;
  for (std::size_t array = 0; array < bytes[22]; ++array) {
    if (offset + 3 > bytes.size()) {
      return NativeVideoSampleFormatAdmission::Unsupported;
    }
    const std::uint8_t nalType = bytes[offset] & 0x3fU;
    const std::size_t nalCount =
        (static_cast<std::size_t>(bytes[offset + 1]) << 8U) |
        bytes[offset + 2];
    offset += 3;
    for (std::size_t index = 0; index < nalCount; ++index) {
      if (offset + 2 > bytes.size()) {
        return NativeVideoSampleFormatAdmission::Unsupported;
      }
      const std::size_t length =
          (static_cast<std::size_t>(bytes[offset]) << 8U) |
          bytes[offset + 1];
      offset += 2;
      if (length == 0 || length > bytes.size() - offset) {
        return NativeVideoSampleFormatAdmission::Unsupported;
      }
      if (nalType == 33U) {
        if (length < 3 || ((bytes[offset] >> 1U) & 0x3fU) != 33U) {
          return NativeVideoSampleFormatAdmission::Unsupported;
        }
        CodecRbspBitReader bits(bytes.subspan(offset + 2, length - 2));
        std::uint32_t ignored = 0;
        std::uint32_t subLayers = 0;
        std::uint32_t chromaFormat = 0;
        std::uint32_t spsLumaDepthMinusEight = 0;
        std::uint32_t spsChromaDepthMinusEight = 0;
        if (!bits.readBits(4, ignored) || !bits.readBits(3, subLayers) ||
            subLayers > 6 || !bits.readBits(1, ignored) ||
            !skipProfileTierLevel(bits, subLayers) ||
            !bits.readUnsignedExpGolomb(ignored) ||
            !bits.readUnsignedExpGolomb(chromaFormat) || chromaFormat != 1 ||
            !bits.readUnsignedExpGolomb(ignored) ||
            !bits.readUnsignedExpGolomb(ignored) ||
            !bits.readBits(1, ignored)) {
          return NativeVideoSampleFormatAdmission::Unsupported;
        }
        if (ignored != 0) {
          for (std::size_t windowOffset = 0; windowOffset < 4;
               ++windowOffset) {
            if (!bits.readUnsignedExpGolomb(ignored)) {
              return NativeVideoSampleFormatAdmission::Unsupported;
            }
          }
        }
        if (!bits.readUnsignedExpGolomb(spsLumaDepthMinusEight) ||
            !bits.readUnsignedExpGolomb(spsChromaDepthMinusEight) ||
            spsLumaDepthMinusEight != lumaDepthMinusEight ||
            spsChromaDepthMinusEight != chromaDepthMinusEight) {
          return NativeVideoSampleFormatAdmission::Unsupported;
        }
        foundSps = true;
      }
      offset += length;
    }
  }
  if (!foundSps || offset != bytes.size()) {
    return NativeVideoSampleFormatAdmission::Unsupported;
  }
  return lumaDepthMinusEight == 2
             ? NativeVideoSampleFormatAdmission::Yuv420TenBit
             : NativeVideoSampleFormatAdmission::Yuv420EightBit;
}

}  // namespace

NativeVideoSampleFormatAdmission nativeVideoSampleFormatAdmission(
    std::uint32_t mediaSubtype,
    std::span<const std::byte> codecConfiguration) noexcept {
  if (mediaSubtype == kCMVideoCodecType_H264) {
    return h264SampleFormatAdmission(codecConfiguration);
  }
  if (mediaSubtype == kCMVideoCodecType_HEVC) {
    return hevcSampleFormatAdmission(codecConfiguration);
  }
  return NativeVideoSampleFormatAdmission::Unsupported;
}

struct NativeVideoPipeline::Impl
    : public std::enable_shared_from_this<NativeVideoPipeline::Impl> {
  enum class Lifecycle : std::uint8_t {
    Idle,
    Preparing,
    Prepared,
    Starting,
    Running,
    Retiring,
    Finalizing,
  };

  enum class PreparationStep : std::uint8_t {
    Start,
    AssetValuesReady,
    TrackValuesReady,
  };

  struct PreparationRequest {
    std::uint64_t generation{0};
    std::filesystem::path path;
    double initialPositionSeconds{0.0};
    std::atomic<bool> cancelled{false};
    std::atomic<bool> completed{false};

    // These fields are confined to preparationQueue. AVFoundation's callback
    // only enqueues a continuation; it never mutates the request directly.
    __strong AVURLAsset* asset{nil};
    __strong AVAssetTrack* track{nil};
    bool assetLoadInFlight{false};
    bool trackLoadInFlight{false};
    bool ownsConfiguredResources{false};
  };

  Impl()
      : failureState(std::make_shared<PipelineFailureState>()),
        presentationQueue(dispatch_queue_create(
            "com.wesleymaa.wam.native-video-present", DISPATCH_QUEUE_SERIAL)),
        preparationQueue(dispatch_queue_create(
            "com.wesleymaa.wam.native-video-prepare", DISPATCH_QUEUE_SERIAL)),
        retirementQueue(dispatch_queue_create(
            "com.wesleymaa.wam.native-video-retire", DISPATCH_QUEUE_SERIAL)),
        presentationSource(nil) {}

  ~Impl() {
    // Normal final retirement has already cleared both objects. This fallback
    // exists for allocation failure while a factory is assembling the public
    // wrapper. The display-link handler captures no raw Impl pointer, so
    // cancellation/release is safe without synchronously draining a queue from
    // an unknown destructor thread.
    releaseDisplayInfrastructureNoexcept(false);
  }

  std::shared_ptr<PipelineFailureState> failureState;
  NativeVideoOutputMode outputMode{NativeVideoOutputMode::MetalLayer};
  std::unique_ptr<MetalLayerPresenter> presenter;
  std::shared_ptr<NativeScheduledFrameOutput> scheduledOutput;
  std::unique_ptr<NotifyingFrameSink> sink;
  std::unique_ptr<VideoToolboxDecoder> decoder;

  // Control calls never hold this mutex while joining the worker, draining a
  // dispatch queue, or waiting for VideoToolbox. It only protects ownership
  // transfer and short stats snapshots.
  mutable std::mutex resourceMutex;

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
  __strong dispatch_queue_t preparationQueue;
  __strong dispatch_queue_t retirementQueue;
  __strong dispatch_source_t presentationSource{nil};

  mutable std::mutex lifecycleMutex;
  Lifecycle lifecycle{Lifecycle::Idle};
  bool stopRequestedDuringPrepare{false};
  bool shutdownRequested{false};
  bool ownsProcessAdmission{false};
  std::uint64_t preparationGeneration{0};
  std::shared_ptr<PreparationRequest> activePreparation;
  double preparedInitialPosition{0.0};
  std::uint64_t preparedFrameGeneration{0};
  std::uint64_t preparedFailureEpoch{0};

  mutable std::mutex preparationResultMutex;
  std::optional<NativeVideoPrepareOutcome> preparationResult;

#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
  mutable std::mutex schedulingTestMutex;
  std::shared_future<void> preparationLoadBarrier;
  std::shared_ptr<std::atomic<bool>> preparationLoadEntered;
  std::shared_future<void> assetLoadCallbackBarrier;
  std::shared_ptr<std::atomic<bool>> assetLoadCallbackEntered;
  std::shared_future<void> trackLoadCallbackBarrier;
  std::shared_ptr<std::atomic<bool>> trackLoadCallbackEntered;
  std::shared_ptr<std::atomic<bool>> preparationCancellationEntered;
  std::atomic<bool> failAfterResourceTransfer{false};
  std::shared_future<void> preparationCommitBarrier;
  std::shared_ptr<std::atomic<bool>> preparationCommitEntered;
  std::shared_future<void> retirementBarrier;
  std::shared_ptr<std::atomic<bool>> retirementEntered;
  std::shared_future<void> startPreparedPostWorkerBarrier;
  std::shared_ptr<std::atomic<bool>> startPreparedPostWorkerEntered;
  std::atomic<bool> failNextPresentationDispatch{false};
  std::atomic<bool> failNextWorkerSampleSubmission{false};
  std::atomic<bool> failNextDisplayLinkStart{false};
  std::atomic<bool> failNextDisplayLinkStop{false};
#endif

  std::atomic<bool> attached{false};
  std::atomic<bool> prepared{false};
  std::atomic<bool> running{false};
  std::atomic<bool> stopping{false};
  std::atomic<bool> pausedPresentationNeeded{false};
  std::atomic<bool> displayLinkHealthy{true};
  std::atomic<std::uint64_t> requestedGeneration{0};
  AtomicPipelineStats counters;

  [[nodiscard]] std::optional<std::uint64_t> advanceGeneration() noexcept {
    std::uint64_t observed =
        requestedGeneration.load(std::memory_order_acquire);
    while (observed != std::numeric_limits<std::uint64_t>::max()) {
      const std::uint64_t next = observed + 1;
      if (requestedGeneration.compare_exchange_weak(
              observed, next, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        return next;
      }
    }
    return std::nullopt;
  }

  [[nodiscard]] bool dispatchInfrastructureReady() const noexcept {
    return presentationQueue != nil && preparationQueue != nil &&
           retirementQueue != nil;
  }

  [[nodiscard]] bool initializePresentationSource(
      std::string* error) noexcept {
    if (!dispatchInfrastructureReady()) {
      assignFixedErrorNoexcept(
          error, "native video dispatch queues could not be created");
      return false;
    }
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, presentationQueue);
    if (source == nil) {
      assignFixedErrorNoexcept(
          error, "native video presentation source could not be created");
      return false;
    }
    std::weak_ptr<Impl> weakSelf = shared_from_this();
    dispatch_source_set_event_handler(source, ^{
      @autoreleasepool {
        if (auto self = weakSelf.lock()) {
          self->renderAtAudioClock();
        }
      }
    });
    presentationSource = source;
    dispatch_resume(source);
    return true;
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

  [[nodiscard]] bool createDisplayLink(std::string* error) noexcept {
    if (presentationSource == nil) {
      assignFixedErrorNoexcept(
          error, "native video presentation source is unavailable");
      return false;
    }
    CVDisplayLinkRef createdLink = nullptr;
    const CVReturn createStatus =
        CVDisplayLinkCreateWithActiveCGDisplays(&createdLink);
    if (createStatus != kCVReturnSuccess || createdLink == nullptr) {
      assignFixedErrorNoexcept(error, "CVDisplayLink creation failed");
      return false;
    }

    // A block-owned weak control block and source replace the former raw Impl*
    // callback context. Even if Stop reports failure or a callback overlaps
    // final Release, an in-flight block owns all memory it can touch. It may
    // lock Impl only while a real shared owner still exists.
    const std::weak_ptr<Impl> weakSelf = weak_from_this();
    __strong dispatch_source_t callbackSource = presentationSource;
    const CVReturn callbackStatus = CVDisplayLinkSetOutputHandler(
        createdLink,
        ^CVReturn(CVDisplayLinkRef, const CVTimeStamp*, const CVTimeStamp*,
                  CVOptionFlags, CVOptionFlags*) {
          if (auto self = weakSelf.lock()) {
            self->counters.displayLinkTicks.fetch_add(
                1, std::memory_order_relaxed);
            if (self->failureState->active()) {
              // DATA_ADD coalesces ticks while the serial presenter is busy.
              // This real-time callback performs no rendering or allocation.
              dispatch_source_merge_data(callbackSource, 1);
            }
          }
          return kCVReturnSuccess;
        });
    if (callbackStatus != kCVReturnSuccess) {
      CVDisplayLinkRelease(createdLink);
      assignFixedErrorNoexcept(error,
                               "CVDisplayLink callback setup failed");
      return false;
    }
    displayLink = createdLink;
    displayLinkHealthy.store(true, std::memory_order_release);
    return true;
  }

  [[nodiscard]] bool setDisplayLinkRunning(bool shouldRun) noexcept {
    std::lock_guard lock(displayLinkMutex);
    if (displayLink == nullptr ||
        !displayLinkHealthy.load(std::memory_order_acquire)) {
      return false;
    }
    const bool isRunning = CVDisplayLinkIsRunning(displayLink);
    CVReturn status = kCVReturnSuccess;
    if (shouldRun && !isRunning) {
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
      if (failNextDisplayLinkStart.exchange(false,
                                            std::memory_order_acq_rel)) {
        status = kCVReturnError;
      } else
#endif
      {
        status = CVDisplayLinkStart(displayLink);
      }
    } else if (!shouldRun && isRunning) {
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
      if (failNextDisplayLinkStop.exchange(false,
                                           std::memory_order_acq_rel)) {
        status = kCVReturnError;
      } else
#endif
      {
        status = CVDisplayLinkStop(displayLink);
      }
    }
    if (status != kCVReturnSuccess) {
      displayLinkHealthy.store(false, std::memory_order_release);
      return false;
    }
    return true;
  }

  void releaseDisplayInfrastructureNoexcept(bool drainSource) noexcept {
    dispatch_source_t source = presentationSource;
    if (source != nil) {
      dispatch_source_cancel(source);
      if (drainSource && presentationQueue != nil) {
        dispatch_sync(presentationQueue, ^{});
      }
      presentationSource = nil;
    }

    std::lock_guard lock(displayLinkMutex);
    if (displayLink == nullptr) {
      return;
    }
    if (CVDisplayLinkIsRunning(displayLink)) {
      const CVReturn stopStatus = CVDisplayLinkStop(displayLink);
      if (stopStatus != kCVReturnSuccess) {
        displayLinkHealthy.store(false, std::memory_order_release);
      }
    }
    CVDisplayLinkRelease(displayLink);
    displayLink = nullptr;
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
    try {
      renderAtAudioClockImpl();
    } catch (...) {
      // Neither libdispatch nor the Objective-C block ABI may observe a C++
      // exception. The fixed diagnostic is latched without allocating, which
      // is essential when the original failure was std::bad_alloc.
      reportFixedFailure(kPresentationExceptionError);
    }
  }

  void renderAtAudioClockImpl() {
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
    if (failNextPresentationDispatch.exchange(false,
                                               std::memory_order_acq_rel)) {
      throw std::bad_alloc();
    }
#endif
    if (!running.load(std::memory_order_acquire) ||
        !failureState->active() || sink == nullptr ||
        (presenter == nullptr && scheduledOutput == nullptr)) {
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

    counters.scheduledFrames.fetch_add(1, std::memory_order_relaxed);

    if (scheduledOutput != nullptr) {
      std::string error;
      const NativeScheduledFrameDispatchResult result =
          scheduledOutput->dispatch(*due, &error);
      switch (result) {
      case NativeScheduledFrameDispatchResult::Dispatched:
        counters.dispatchedFrames.fetch_add(1, std::memory_order_relaxed);
        if (paused) {
          pausedPresentationNeeded.store(false, std::memory_order_release);
        }
        break;
      case NativeScheduledFrameDispatchResult::Backpressure:
        counters.presenterBackpressureEvents.fetch_add(
            1, std::memory_order_relaxed);
        retryFrame = std::move(*due);
        break;
      case NativeScheduledFrameDispatchResult::Rejected:
        if (failureState->active()) {
          reportFailure(error.empty()
                            ? "native Qt OpenGL output rejected a current "
                              "generation frame"
                            : std::move(error));
        }
        break;
      case NativeScheduledFrameDispatchResult::Failed:
        reportFailure(error.empty() ? "native Qt OpenGL output failed"
                                    : std::move(error));
        break;
      }
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

  void scheduleFailureRetirement(
      std::optional<std::uint64_t> failureEpoch) noexcept {
    if (!failureEpoch || outputMode != NativeVideoOutputMode::QtOpenGL ||
        preparationQueue == nil) {
      return;
    }
    // reportFailure can run on the worker or while renderAtAudioClock holds
    // presentationMutex. Never invert presentation -> lifecycle here. A
    // first-wins, epoch-tagged weak continuation owns fail-closed retirement.
    const std::weak_ptr<Impl> weakImpl = weak_from_this();
    const std::uint64_t reportedEpoch = *failureEpoch;
    dispatch_async(preparationQueue, ^{
      if (auto retained = weakImpl.lock()) {
        retained->retireAfterScheduledOutputFailure(reportedEpoch);
      }
    });
  }

  void reportFailure(std::string message) noexcept {
    const std::optional<std::uint64_t> failureEpoch =
        failureState->reportCurrent(std::move(message));
    scheduleFailureRetirement(failureEpoch);
  }

  void reportFixedFailure(const char* message) noexcept {
    const std::optional<std::uint64_t> failureEpoch =
        failureState->reportFixedCurrent(message);
    scheduleFailureRetirement(failureEpoch);
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
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
    if (failNextWorkerSampleSubmission.exchange(
            false, std::memory_order_acq_rel)) {
      throw std::bad_alloc();
    }
#endif
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

  void clearActiveReader(AVAssetReader* reader) noexcept {
    try {
      std::lock_guard lock(stateMutex);
      if (activeReader == reader) {
        activeReader = nil;
      }
    } catch (...) {
      // std::mutex locking does not allocate in the supported libc++, but the
      // cleanup boundary remains noexcept even on a platform error.
    }
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
      ScopeExit activeReaderCleanup(
          [this, reader]() noexcept { clearActiveReader(reader); });

      bool reachedEnd = false;
      bool submittedSyncSample = false;
      while (!requestChanged(version)) {
        if (sink->size() >= kDecodeQueueHighWater &&
            !waitForDecodeCapacity(version)) {
          break;
        }
        ScopedSampleBuffer sample([output copyNextSampleBuffer]);
        if (!sample) {
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
        const bool accepted = submitSample(sample.get(), generation, version,
                                           submittedSyncSample);
        if (!accepted) {
          break;
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

  [[nodiscard]] bool startWorker(double initialPosition,
                                 std::string* error) noexcept {
    {
      std::lock_guard lock(stateMutex);
      if (worker.joinable()) {
        assignFixedErrorNoexcept(error,
                                 "native video worker is already running");
        return false;
      }
      stopWorker = false;
      requestedSeekSeconds = initialPosition;
      ++seekVersion;
    }
    try {
      std::thread started([this] {
        try {
          workerLoop();
        } catch (const std::bad_alloc&) {
          reportFixedFailure(kWorkerAllocationError);
        } catch (const std::exception&) {
          reportFixedFailure(kWorkerExceptionError);
        } catch (...) {
          reportFixedFailure(kWorkerExceptionError);
        }
      });
      worker = std::move(started);
    } catch (...) {
      {
        std::lock_guard lock(stateMutex);
        stopWorker = true;
        ++seekVersion;
      }
      assignFixedErrorNoexcept(error,
                               "native video worker could not be created");
      return false;
    }
    workerWake.notify_all();
    return true;
  }

  void signalWorkerStop() noexcept {
    {
      std::lock_guard lock(stateMutex);
      stopWorker = true;
      ++seekVersion;
    }
    workerWake.notify_all();
  }

  void cancelActiveReader() noexcept {
    AVAssetReader* reader = nil;
    {
      std::lock_guard lock(stateMutex);
      reader = activeReader;
    }
    if (reader != nil) {
      [reader cancelReading];
    }
  }

  void joinWorkerThread() noexcept {
    if (worker.joinable()) {
      worker.join();
    }
    {
      std::lock_guard lock(stateMutex);
      activeReader = nil;
    }
  }

#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
  void waitAtPreparationLoadBarrier() {
    std::shared_future<void> release;
    std::shared_ptr<std::atomic<bool>> entered;
    {
      std::lock_guard lock(schedulingTestMutex);
      release = std::move(preparationLoadBarrier);
      entered = std::move(preparationLoadEntered);
    }
    if (release.valid()) {
      if (entered != nullptr) {
        entered->store(true, std::memory_order_release);
      }
      release.wait();
    }
  }

  void waitAtAssetLoadCallbackBarrier() {
    std::shared_future<void> release;
    std::shared_ptr<std::atomic<bool>> entered;
    {
      std::lock_guard lock(schedulingTestMutex);
      release = std::move(assetLoadCallbackBarrier);
      entered = std::move(assetLoadCallbackEntered);
    }
    if (release.valid()) {
      if (entered != nullptr) {
        entered->store(true, std::memory_order_release);
      }
      release.wait();
    }
  }

  void waitAtStartPreparedPostWorkerBarrier() {
    std::shared_future<void> release;
    std::shared_ptr<std::atomic<bool>> entered;
    {
      std::lock_guard lock(schedulingTestMutex);
      release = std::move(startPreparedPostWorkerBarrier);
      entered = std::move(startPreparedPostWorkerEntered);
    }
    if (release.valid()) {
      if (entered != nullptr) {
        entered->store(true, std::memory_order_release);
      }
      release.wait();
    }
  }

  void waitAtTrackLoadCallbackBarrier() {
    std::shared_future<void> release;
    std::shared_ptr<std::atomic<bool>> entered;
    {
      std::lock_guard lock(schedulingTestMutex);
      release = std::move(trackLoadCallbackBarrier);
      entered = std::move(trackLoadCallbackEntered);
    }
    if (release.valid()) {
      if (entered != nullptr) {
        entered->store(true, std::memory_order_release);
      }
      release.wait();
    }
  }

  void markPreparationCancellationEntered() {
    std::shared_ptr<std::atomic<bool>> entered;
    {
      std::lock_guard lock(schedulingTestMutex);
      entered = preparationCancellationEntered;
    }
    if (entered != nullptr) {
      entered->store(true, std::memory_order_release);
    }
  }

  void waitAtPreparationCommitBarrier() {
    std::shared_future<void> release;
    std::shared_ptr<std::atomic<bool>> entered;
    {
      std::lock_guard lock(schedulingTestMutex);
      release = std::move(preparationCommitBarrier);
      entered = std::move(preparationCommitEntered);
    }
    if (release.valid()) {
      if (entered != nullptr) {
        entered->store(true, std::memory_order_release);
      }
      release.wait();
    }
  }

  void waitAtRetirementBarrier() {
    std::shared_future<void> release;
    std::shared_ptr<std::atomic<bool>> entered;
    {
      std::lock_guard lock(schedulingTestMutex);
      release = std::move(retirementBarrier);
      entered = std::move(retirementEntered);
    }
    if (release.valid()) {
      if (entered != nullptr) {
        entered->store(true, std::memory_order_release);
      }
      release.wait();
    }
  }
#endif

  static bool loadedValues(
      id<AVAsynchronousKeyValueLoading> object,
      NSArray<NSString*>* keys, bool* loadingCancelled,
      std::string* error) {
    *loadingCancelled = false;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (NSString* key in keys) {
      NSError* keyError = nil;
      const AVKeyValueStatus status =
          [object statusOfValueForKey:key error:&keyError];
      if (status == AVKeyValueStatusLoaded) {
        continue;
      }
      if (status == AVKeyValueStatusCancelled) {
        *loadingCancelled = true;
        assignError(error, "AVFoundation cancelled native asset inspection");
        return false;
      }
      if (status == AVKeyValueStatusFailed) {
        assignError(error,
                    describeNSError(keyError,
                                    "AVFoundation asset inspection failed"));
        return false;
      }
      const char* keyText = key.UTF8String;
      assignError(error,
                  std::string("AVFoundation did not finish loading asset key ") +
                      (keyText == nullptr ? "<unknown>" : keyText));
      return false;
    }
#pragma clang diagnostic pop
    return true;
  }

  void runPreparationStep(
      const std::shared_ptr<PreparationRequest>& request,
      PreparationStep step) noexcept {
    try {
      switch (step) {
      case PreparationStep::Start:
        startPreparation(request);
        break;
      case PreparationStep::AssetValuesReady:
        assetValuesReady(request);
        break;
      case PreparationStep::TrackValuesReady:
        trackValuesReady(request);
        break;
      }
    } catch (...) {
      // No C++ exception may cross a libdispatch/Objective-C callback frame.
      // The short diagnostic fits libc++'s inline string storage, while the
      // per-request ownership flag makes partial decoder construction retire
      // through the same self-owned teardown path as an explicit stop.
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native prep failed");
    }
  }

  void startPreparation(
      const std::shared_ptr<PreparationRequest>& request) {
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
    waitAtPreparationLoadBarrier();
#endif
    if (request->cancelled.load(std::memory_order_acquire)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native video preparation was cancelled");
      return;
    }

    std::error_code fileError;
    if (!std::filesystem::is_regular_file(request->path, fileError)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native video requires a readable local file");
      return;
    }
    const NativeVideoContainerAdmissionHint containerHint =
        nativeVideoContainerAdmissionHint(request->path.string());
    if (containerHint.preferredDemux ==
        NativeVideoDemuxPreference::ExternalBridgeRequired) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "container needs an external compressed-sample demux bridge; "
          "using libmpv");
      return;
    }
    NSString* filePath =
        [NSString stringWithUTF8String:request->path.c_str()];
    if (filePath == nil) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native video path is not valid UTF-8");
      return;
    }
    NSURL* url = [NSURL fileURLWithPath:filePath];
    request->asset = [AVURLAsset
        URLAssetWithURL:url
                options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];

    NSArray<NSString*>* keys = @[
      @"playable", @"hasProtectedContent", @"duration", @"tracks"
    ];
    request->assetLoadInFlight = true;
    const std::shared_ptr<Impl> self = shared_from_this();
    const std::shared_ptr<PreparationRequest> retainedRequest = request;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [request->asset loadValuesAsynchronouslyForKeys:keys
                                  completionHandler:^{
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
      self->waitAtAssetLoadCallbackBarrier();
#endif
      dispatch_async(self->preparationQueue, ^{
        @autoreleasepool {
          self->runPreparationStep(
              retainedRequest, PreparationStep::AssetValuesReady);
        }
      });
    }];
#pragma clang diagnostic pop
  }

  void assetValuesReady(
      const std::shared_ptr<PreparationRequest>& request) {
    request->assetLoadInFlight = false;
    if (request->cancelled.load(std::memory_order_acquire)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native video preparation was cancelled");
      return;
    }

    NSArray<NSString*>* keys = @[
      @"playable", @"hasProtectedContent", @"duration", @"tracks"
    ];
    bool loadingCancelled = false;
    std::string loadingError;
    if (!loadedValues(request->asset, keys, &loadingCancelled,
                      &loadingError)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          std::move(loadingError));
      return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!request->asset.playable || request->asset.hasProtectedContent) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "protected or unplayable media uses the libmpv path");
      return;
    }
    // The tracks key was proven Loaded above, so these filtering calls cannot
    // trigger the synchronous I/O warned about by AVFoundation.
    NSArray<AVAssetTrack*>* tracks =
        [request->asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack*>* audioTracks =
        [request->asset tracksWithMediaType:AVMediaTypeAudio];
    NSArray<AVAssetTrack*>* subtitleTracks =
        [request->asset tracksWithMediaType:AVMediaTypeSubtitle];
    NSArray<AVAssetTrack*>* textTracks =
        [request->asset tracksWithMediaType:AVMediaTypeText];
    NSArray<AVAssetTrack*>* closedCaptionTracks =
        [request->asset tracksWithMediaType:AVMediaTypeClosedCaption];
#pragma clang diagnostic pop
    if (tracks.count != 1) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "native video requires exactly one video track; multi-angle and "
          "track-selected media use libmpv");
      return;
    }
    if (audioTracks.count == 0) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "native video currently requires an audio track as its "
          "authoritative playback clock");
      return;
    }
    if (subtitleTracks.count != 0 || textTracks.count != 0 ||
        closedCaptionTracks.count != 0) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "embedded subtitle, text, and closed-caption tracks require the "
          "libmpv compositor");
      return;
    }
    request->track = tracks.firstObject;

    NSArray<NSString*>* trackKeys =
        @[@"formatDescriptions", @"preferredTransform"];
    request->trackLoadInFlight = true;
    const std::shared_ptr<Impl> self = shared_from_this();
    const std::shared_ptr<PreparationRequest> retainedRequest = request;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [request->track loadValuesAsynchronouslyForKeys:trackKeys
                                  completionHandler:^{
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
      self->waitAtTrackLoadCallbackBarrier();
#endif
      dispatch_async(self->preparationQueue, ^{
        @autoreleasepool {
          self->runPreparationStep(
              retainedRequest, PreparationStep::TrackValuesReady);
        }
      });
    }];
#pragma clang diagnostic pop
  }

  void trackValuesReady(
      const std::shared_ptr<PreparationRequest>& request) {
    request->trackLoadInFlight = false;
    if (request->cancelled.load(std::memory_order_acquire)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native video preparation was cancelled");
      return;
    }

    NSArray<NSString*>* keys =
        @[@"formatDescriptions", @"preferredTransform"];
    bool loadingCancelled = false;
    std::string loadingError;
    if (!loadedValues(request->track, keys, &loadingCancelled,
                      &loadingError)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          std::move(loadingError));
      return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray* descriptions = request->track.formatDescriptions;
    const CGAffineTransform transform = request->track.preferredTransform;
    const CMTime duration = request->asset.duration;
#pragma clang diagnostic pop
    if (descriptions.count != 1) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "video tracks with missing or changing format descriptions use "
          "libmpv");
      return;
    }
    auto format =
        (__bridge CMVideoFormatDescriptionRef)descriptions.firstObject;
    const CMVideoCodecType codec = CMFormatDescriptionGetMediaSubType(format);
    if (nativeVideoCodecAdmission(codec) ==
        NativeVideoCodecAdmission::Unsupported) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "native video currently supports H.264 and HEVC");
      return;
    }
    if (!CGAffineTransformIsIdentity(transform)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "rotated video currently uses the libmpv renderer");
      return;
    }
    if (!isProgressiveFormat(format)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "interlaced video currently requires libmpv deinterlacing");
      return;
    }
    if (hasUnsupportedColorMetadata(format) ||
        hasDolbyVisionConfiguration(format)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "video color metadata is outside the native SDR BT.709/601 "
          "contract and requires libmpv color management");
      return;
    }

    const CMVideoDimensions dimensions =
        CMVideoFormatDescriptionGetDimensions(format);
    if (dimensions.width <= 0 || dimensions.height <= 0) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "video track has invalid coded dimensions");
      return;
    }
    const std::uint64_t codedPixels =
        static_cast<std::uint64_t>(dimensions.width) *
        static_cast<std::uint64_t>(dimensions.height);
    if (codedPixels > kMaximumCodedPixels) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "native video exceeds the experiment's 2,073,600 coded-pixel "
          "surface budget and uses libmpv");
      return;
    }
    const CGRect cleanAperture =
        CMVideoFormatDescriptionGetCleanAperture(format, true);
    const CGSize pixelAspectDimensions =
        CMVideoFormatDescriptionGetPresentationDimensions(format, true, false);
    const bool fullCodedAperture =
        std::abs(cleanAperture.origin.x) <= 0.5 &&
        std::abs(cleanAperture.origin.y) <= 0.5 &&
        std::abs(cleanAperture.size.width - dimensions.width) <= 0.5 &&
        std::abs(cleanAperture.size.height - dimensions.height) <= 0.5;
    const bool squarePixels =
        std::abs(pixelAspectDimensions.width - dimensions.width) <= 0.5 &&
        std::abs(pixelAspectDimensions.height - dimensions.height) <= 0.5;
    if (!fullCodedAperture || !squarePixels) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "non-square pixels or a cropped aperture currently use libmpv");
      return;
    }
    auto configuration = copyCodecConfiguration(format, codec);
    if (!configuration) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "video track lacks an avcC/hvcC configuration atom");
      return;
    }
    if (nativeVideoSampleFormatAdmission(codec, *configuration) ==
        NativeVideoSampleFormatAdmission::Unsupported) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          "native video requires 4:2:0 H.264/HEVC with matching 8-bit "
          "components, or 10-bit HEVC");
      return;
    }
    std::string demuxProbeError;
    if (!probeCompressedSampleExtraction(request->asset, request->track,
                                         codec, &demuxProbeError)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          demuxProbeError.empty()
              ? "AVFoundation cannot expose bounded compressed video "
                "samples; using libmpv"
              : std::move(demuxProbeError));
      return;
    }
    if (request->cancelled.load(std::memory_order_acquire)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native video preparation was cancelled");
      return;
    }

    const std::optional<std::uint64_t> nextGeneration = advanceGeneration();
    if (!nextGeneration) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native video frame generation is exhausted");
      return;
    }
    const std::uint64_t generation = *nextGeneration;
    std::string decoderError;
    double initialPosition = 0.0;
    {
      std::lock_guard resourceLock(resourceMutex);
      // From this point onward any exception or cancellation must retire the
      // partially transferred AVFoundation/VideoToolbox ownership rather than
      // release process admission as if no resources existed.
      request->ownsConfiguredResources = true;
      asset = request->asset;
      track = request->track;
      assetDuration = duration;
      this->codec = codec;
      this->dimensions = dimensions;
      codecConfiguration = std::move(*configuration);
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
      if (failAfterResourceTransfer.exchange(false,
                                             std::memory_order_acq_rel)) {
        throw std::bad_alloc();
      }
#endif
      std::weak_ptr<Impl> weakImpl = shared_from_this();
      sink = std::make_unique<NotifyingFrameSink>(
          kFrameQueueCapacity, generation, [weakImpl] {
            if (auto state = weakImpl.lock()) {
              state->notifyFrameAvailable();
            }
          });
      VideoToolboxDecoderOptions decoderOptions;
      decoderOptions.maxInFlightFrames = kMaximumInFlightDecodeFrames;
      decoderOptions.maxPendingPresentationFrames = kMaximumReorderFrames;
      decoderOptions.outputInterop =
          outputMode == NativeVideoOutputMode::QtOpenGL
              ? VideoToolboxOutputInterop::OpenGL
              : VideoToolboxOutputInterop::Metal;
      decoder = std::make_unique<VideoToolboxDecoder>(decoderOptions);
      const VideoStreamConfiguration stream{
          codec,
          dimensions,
          std::span<const std::byte>(codecConfiguration),
          true,
          true,
          generation};
      if (!decoder->configure(stream, *sink, &decoderError)) {
        decoder.reset();
        sink.reset();
        asset = nil;
        track = nil;
        codecConfiguration.clear();
        assetDuration = kCMTimeInvalid;
        request->ownsConfiguredResources = false;
      } else {
        initialPosition = normalizePosition(
            finiteNonnegative(request->initialPositionSeconds)
                ? request->initialPositionSeconds
                : 0.0);
      }
    }
    if (!request->ownsConfiguredResources) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Unsupported,
          decoderError.empty()
              ? "hardware VideoToolbox decode is unavailable"
              : std::move(decoderError));
      return;
    }

    counters.reset();
    const std::uint64_t failureEpoch =
        outputMode == NativeVideoOutputMode::MetalLayer
            ? failureState->beginAttempt()
            : 0;
    {
      std::lock_guard lock(presentationMutex);
      minimumPresentationSeconds = initialPosition;
      heldFrame.reset();
      retryFrame.reset();
    }
    {
      std::lock_guard lock(clockMutex);
      clockMediaSeconds = initialPosition;
      clockAnchorHostSeconds = CACurrentMediaTime();
      clockRate = 1.0;
      clockPaused = true;
    }
    pausedPresentationNeeded.store(true, std::memory_order_release);
    if (!commitPreparation(request, failureEpoch, initialPosition)) {
      finishUncommittedPreparation(
          request, NativeVideoPrepareResult::Failed,
          "native video preparation was cancelled");
      return;
    }
    request->asset = nil;
    request->track = nil;
  }

  void schedulePreparation(
      const std::shared_ptr<PreparationRequest>& request) {
    const std::shared_ptr<Impl> self = shared_from_this();
    const std::shared_ptr<PreparationRequest> retainedRequest = request;
    dispatch_async(preparationQueue, ^{
      @autoreleasepool {
        self->runPreparationStep(retainedRequest, PreparationStep::Start);
      }
    });
  }

  [[nodiscard]] bool beginPreparation(
      const std::shared_ptr<PreparationRequest>& request,
      bool* retireExisting, std::string* error) noexcept {
    *retireExisting = false;
    std::lock_guard resultLock(preparationResultMutex);
    if (preparationResult.has_value()) {
      assignFixedErrorNoexcept(
          error,
          "consume the previous native video preparation result before "
          "starting another request");
      return false;
    }
    std::lock_guard lock(lifecycleMutex);
    switch (lifecycle) {
    case Lifecycle::Idle:
      if (shutdownRequested) {
        assignFixedErrorNoexcept(error,
                                 "native video pipeline is shutting down");
        return false;
      }
      if (!displayLinkHealthy.load(std::memory_order_acquire)) {
        assignFixedErrorNoexcept(
            error, "native video display link is no longer usable");
        return false;
      }
      if (scheduledOutput != nullptr) {
        const NativeScheduledFrameOutputStats outputStats =
            scheduledOutput->stats();
        if (outputStats.closed || outputStats.fatalErrorSerial != 0 ||
            outputStats.acceptedGeneration ==
                std::numeric_limits<std::uint64_t>::max()) {
          assignFixedErrorNoexcept(
              error,
              outputStats.fatalErrorSerial != 0
                  ? "native Qt OpenGL output is terminal; recreate the output "
                    "adapter before preparing"
                  : "native Qt OpenGL output is closed or its generation is "
                    "exhausted");
          return false;
        }
        std::uint64_t observed =
            requestedGeneration.load(std::memory_order_acquire);
        while (observed < outputStats.acceptedGeneration &&
               !requestedGeneration.compare_exchange_weak(
                   observed, outputStats.acceptedGeneration,
                   std::memory_order_acq_rel,
                   std::memory_order_acquire)) {
        }
      }
      {
        bool expected = false;
        if (!gNativeAttemptAdmission.compare_exchange_strong(
                expected, true, std::memory_order_acq_rel,
                std::memory_order_acquire)) {
          assignFixedErrorNoexcept(
              error,
              "another native video attempt is active or retiring; retry "
              "after its stats().stopping becomes false");
          return false;
        }
      }
      ownsProcessAdmission = true;
      lifecycle = Lifecycle::Preparing;
      stopRequestedDuringPrepare = false;
      request->generation = ++preparationGeneration;
      activePreparation = request;
      return true;
    case Lifecycle::Prepared:
    case Lifecycle::Starting:
    case Lifecycle::Running:
      *retireExisting = true;
      assignFixedErrorNoexcept(
          error,
          "the previous native video attempt is being retired; retry "
          "preparation after stats().stopping becomes false");
      return false;
    case Lifecycle::Preparing:
      assignFixedErrorNoexcept(
          error, "native video preparation is already in progress");
      return false;
    case Lifecycle::Retiring:
      assignFixedErrorNoexcept(
          error,
          "native video teardown is still in progress; retry after "
          "stats().stopping becomes false");
      return false;
    case Lifecycle::Finalizing:
      assignFixedErrorNoexcept(error,
                               "native video pipeline is shutting down");
      return false;
    }
  }

  void scheduleRetirement() noexcept {
    const std::shared_ptr<Impl> self = shared_from_this();
    dispatch_async(retirementQueue, ^{
      @autoreleasepool {
        self->completeRetirement();
      }
    });
  }

  void finishUncommittedPreparation(
      const std::shared_ptr<PreparationRequest>& request,
      NativeVideoPrepareResult result, std::string error) noexcept {
    if (request->completed.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    bool schedule = false;
    {
      // Result -> lifecycle is the global ordering also used by admission.
      // Publishing and leaving Preparing are atomic with respect to a new
      // request, so no terminal outcome can be overwritten or missed.
      std::lock_guard resultLock(preparationResultMutex);
      std::lock_guard lifecycleLock(lifecycleMutex);
      preparationResult = NativeVideoPrepareOutcome{
          0, result, std::move(error)};
      if (lifecycle != Lifecycle::Preparing ||
          activePreparation != request) {
        return;
      }
      activePreparation.reset();
      if (request->ownsConfiguredResources || stopRequestedDuringPrepare ||
          shutdownRequested) {
        lifecycle = shutdownRequested ? Lifecycle::Finalizing
                                      : Lifecycle::Retiring;
        stopping.store(true, std::memory_order_release);
        schedule = true;
      } else {
        if (ownsProcessAdmission) {
          ownsProcessAdmission = false;
          gNativeAttemptAdmission.store(false, std::memory_order_release);
        }
        lifecycle = Lifecycle::Idle;
        stopRequestedDuringPrepare = false;
      }
    }
    request->asset = nil;
    request->track = nil;
    if (schedule) {
      failureState->disable();
      prepared.store(false, std::memory_order_release);
      if (presenter != nullptr) {
        presenter->setFailureHandler({}, {});
        presenter->setVisible(false);
      }
      if (scheduledOutput != nullptr) {
        scheduledOutput->setFailureHandler({});
      }
      signalWorkerStop();
      scheduleRetirement();
    }
  }

  [[nodiscard]] bool commitPreparation(
      const std::shared_ptr<PreparationRequest>& request,
      std::uint64_t failureEpoch, double initialPosition) {
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
    waitAtPreparationCommitBarrier();
#endif
    bool scheduleRetirementAfterUnlock = false;
    {
      std::lock_guard resultLock(preparationResultMutex);
      std::lock_guard lifecycleLock(lifecycleMutex);
      if (lifecycle != Lifecycle::Preparing || activePreparation != request ||
          request->cancelled.load(std::memory_order_acquire) ||
          stopRequestedDuringPrepare || shutdownRequested) {
        return false;
      }

      prepared.store(true, std::memory_order_release);
      if (outputMode == NativeVideoOutputMode::QtOpenGL) {
        // Preparation is intentionally inert. In particular, no failure epoch
        // is active and the worker/display link cannot race the GUI's exact-
        // generation flush performed by startPrepared().
        preparedInitialPosition = initialPosition;
        preparedFrameGeneration =
            requestedGeneration.load(std::memory_order_acquire);
        preparedFailureEpoch = 0;
        lifecycle = Lifecycle::Prepared;
        preparationResult.emplace(NativeVideoPrepareOutcome{
            preparedFrameGeneration, NativeVideoPrepareResult::Ready, {}});
      } else {
        std::weak_ptr<PipelineFailureState> weakFailureState = failureState;
        presenter->setFailureHandler(
            failureState,
            [weakFailureState, failureEpoch](std::string message) {
              if (auto state = weakFailureState.lock()) {
                state->report(failureEpoch, std::move(message));
              }
            });
        failureState->activate(failureEpoch);
        presenter->setVisible(true);
        std::string workerError;
        if (!startWorker(initialPosition, &workerError)) {
          failureState->disable();
          presenter->setFailureHandler({}, {});
          presenter->setVisible(false);
          prepared.store(false, std::memory_order_release);
          stopping.store(true, std::memory_order_release);
          lifecycle = Lifecycle::Retiring;
          preparationResult.emplace(NativeVideoPrepareOutcome{
              0, NativeVideoPrepareResult::Failed,
              workerError.empty() ? "native video worker could not be created"
                                  : std::move(workerError)});
          scheduleRetirementAfterUnlock = true;
        } else {
          running.store(true, std::memory_order_release);
          lifecycle = Lifecycle::Running;
          preparationResult.emplace(NativeVideoPrepareOutcome{
              requestedGeneration.load(std::memory_order_acquire),
              NativeVideoPrepareResult::Ready, {}});
        }
      }
      request->completed.store(true, std::memory_order_release);
      activePreparation.reset();
    }
    if (scheduleRetirementAfterUnlock) {
      signalWorkerStop();
      scheduleRetirement();
    }
    return true;
  }

  void schedulePreparationCancellation(
      const std::shared_ptr<PreparationRequest>& request) noexcept {
    const std::shared_ptr<Impl> self = shared_from_this();
    const std::shared_ptr<PreparationRequest> retainedRequest = request;
    dispatch_async(preparationQueue, ^{
      @autoreleasepool {
        if (retainedRequest->completed.load(std::memory_order_acquire)) {
          return;
        }
        if (retainedRequest->asset != nil) {
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
          self->markPreparationCancellationEntered();
#endif
          [retainedRequest->asset cancelLoading];
        }
        // Once an AVFoundation request has been issued, retain the process-wide
        // admission lease until its callback acknowledges completion/cancel.
        // A wedged framework callback can therefore stall one attempt, but
        // cannot be multiplied by recreating frontends.
        if (!retainedRequest->assetLoadInFlight &&
            !retainedRequest->trackLoadInFlight) {
          self->finishUncommittedPreparation(
              retainedRequest, NativeVideoPrepareResult::Failed,
              "native video preparation was cancelled");
        }
      }
    });
  }

  // lifecycleMutex is held by the caller. No allocation or caller error
  // publication is allowed after this method publishes Retiring.
  void revokeNativeAttemptLocked() noexcept {
    running.store(false, std::memory_order_release);
    (void)setDisplayLinkRunning(false);
    failureState->disablePreservingError();
    signalWorkerStop();
    scheduledOutput->setFailureHandler({});
    {
      std::lock_guard presentationLock(presentationMutex);
      const std::optional<std::uint64_t> nextGeneration =
          advanceGeneration();
      const std::uint64_t invalidationGeneration =
          nextGeneration.value_or(
              requestedGeneration.load(std::memory_order_acquire));
      heldFrame.reset();
      retryFrame.reset();
      if (nextGeneration) {
        if (!scheduledOutput->flush(invalidationGeneration, nullptr)) {
          scheduledOutput->close(invalidationGeneration);
        }
      } else {
        // A generic output need not treat an equal generation as an
        // invalidation. Generation exhaustion is terminal, so close it.
        scheduledOutput->close(invalidationGeneration);
      }
    }
    prepared.store(false, std::memory_order_release);
    stopping.store(true, std::memory_order_release);
    lifecycle = Lifecycle::Retiring;
  }

  void retireAfterScheduledOutputFailure(
      std::uint64_t failureEpoch) noexcept {
    bool retire = false;
    {
      std::lock_guard lifecycleLock(lifecycleMutex);
      if ((lifecycle == Lifecycle::Starting ||
           lifecycle == Lifecycle::Running) &&
          preparedFailureEpoch == failureEpoch) {
        revokeNativeAttemptLocked();
        retire = true;
      }
    }
    if (retire) {
      scheduleRetirement();
    }
  }

  void completeScheduledOutputStart(
      std::uint64_t failureEpoch, std::uint64_t expectedGeneration,
      NativeScheduledFrameStartAck acknowledgment) noexcept {
    bool retire = false;
    {
      std::lock_guard lifecycleLock(lifecycleMutex);
      if (lifecycle != Lifecycle::Starting ||
          preparedFailureEpoch != failureEpoch ||
          requestedGeneration.load(std::memory_order_acquire) !=
              expectedGeneration) {
        return;
      }

      std::string workerError;
      if (failureState->failed(failureEpoch) ||
          acknowledgment.requestedGeneration != expectedGeneration ||
          acknowledgment.acceptedGeneration != expectedGeneration) {
        failureState->report(
            failureEpoch,
            "native Qt OpenGL startup acknowledgment was stale");
        retire = true;
      } else {
        failureState->activate(failureEpoch);
        if (!failureState->active()) {
          failureState->report(
              failureEpoch,
              "native Qt OpenGL output failed before worker startup");
          retire = true;
        }
      }
      if (!retire && !startWorker(preparedInitialPosition, &workerError)) {
        failureState->report(
            failureEpoch,
            workerError.empty()
                ? "native video worker could not be created"
                : std::move(workerError));
        retire = true;
      }
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
      if (!retire) {
        waitAtStartPreparedPostWorkerBarrier();
      }
#endif
      if (!retire && !failureState->active()) {
        retire = true;
      }

      if (retire) {
        revokeNativeAttemptLocked();
      } else {
        // Keep display-link/source activation in the lifecycle transaction.
        // stop() cannot publish Retiring between Running and these mutations,
        // so retirement always observes and shuts down everything we start.
        bool paused = true;
        (void)audioClockNow(&paused);
        if (!setDisplayLinkRunning(!paused)) {
          (void)failureState->reportFixed(
              failureEpoch,
              paused ? kDisplayLinkStopError : kDisplayLinkStartError);
          revokeNativeAttemptLocked();
          retire = true;
        } else {
          running.store(true, std::memory_order_release);
          lifecycle = Lifecycle::Running;
          if (paused && presentationSource != nil) {
            pausedPresentationNeeded.store(true, std::memory_order_release);
            dispatch_source_merge_data(presentationSource, 1);
          }
        }
      }
    }

    if (retire) {
      scheduleRetirement();
    }
  }

  [[nodiscard]] std::optional<std::uint64_t> startPrepared(
      std::string* error) noexcept {
    if (error != nullptr) {
      error->clear();
    }
    bool retire = false;
    std::uint64_t generation = 0;
    try {
      std::lock_guard resultLock(preparationResultMutex);
      if (preparationResult.has_value()) {
        assignError(error,
                    "consume the Ready native video preparation result "
                    "before starting it");
        return std::nullopt;
      }
      std::lock_guard lifecycleLock(lifecycleMutex);
      if (outputMode != NativeVideoOutputMode::QtOpenGL ||
          scheduledOutput == nullptr) {
        assignError(error,
                    "startPrepared is only valid for the dormant Qt OpenGL "
                    "output path");
        return std::nullopt;
      }
      if (lifecycle != Lifecycle::Prepared) {
        assignError(error, "native video is not in the Prepared state");
        return std::nullopt;
      }
      generation = preparedFrameGeneration;
      if (generation == 0 ||
          generation != requestedGeneration.load(std::memory_order_acquire)) {
        assignError(error, "native video prepared generation is stale");
        return std::nullopt;
      }

      const std::uint64_t failureEpoch = failureState->beginAttempt();
      preparedFailureEpoch = failureEpoch;
      lifecycle = Lifecycle::Starting;

      const std::weak_ptr<Impl> weakImpl = weak_from_this();
      scheduledOutput->setFailureHandler(
          [weakImpl, failureEpoch](std::string message) {
            auto state = weakImpl.lock();
            if (state == nullptr) {
              return;
            }
            if (!state->failureState->report(failureEpoch,
                                             std::move(message))) {
              return;
            }
            dispatch_queue_t queue = state->preparationQueue;
            dispatch_async(queue, ^{
              if (auto retained = weakImpl.lock()) {
                retained->retireAfterScheduledOutputFailure(failureEpoch);
              }
            });
          });

      const auto applied =
          [weakImpl, failureEpoch, generation](
              NativeScheduledFrameStartAck acknowledgment) {
            auto state = weakImpl.lock();
            if (state == nullptr) {
              return;
            }
            dispatch_queue_t queue = state->preparationQueue;
            dispatch_async(queue, ^{
              if (auto retained = weakImpl.lock()) {
                retained->completeScheduledOutputStart(
                    failureEpoch, generation, acknowledgment);
              }
            });
          };

      std::string outputError;
      {
        std::lock_guard presentationLock(presentationMutex);
        if (!scheduledOutput->startGeneration(generation, applied,
                                              &outputError)) {
          retire = true;
        }
      }
      if (failureState->failed(failureEpoch)) {
        if (outputError.empty()) {
          outputError = "native Qt OpenGL output failed while arming";
        }
        retire = true;
      }

      if (retire) {
        if (outputError.empty()) {
          outputError = "native Qt OpenGL output could not start";
        }
        failureState->report(failureEpoch, outputError);
        // Caller diagnostics are made non-throwing before Retiring is visible.
        assignErrorNoexcept(error, outputError);
        revokeNativeAttemptLocked();
      }
    } catch (...) {
      assignFixedErrorNoexcept(error,
                               "native Qt OpenGL output startup failed");
      requestTeardown(false);
      return std::nullopt;
    }

    if (retire) {
      scheduleRetirement();
      return std::nullopt;
    }
    return generation;
  }

  std::uint64_t requestTeardown(bool final) noexcept {
    bool schedule = false;
    bool invalidate = false;
    std::shared_ptr<PreparationRequest> preparationToCancel;
    {
      std::lock_guard lock(lifecycleMutex);
      shutdownRequested = shutdownRequested || final;
      switch (lifecycle) {
      case Lifecycle::Idle:
        if (shutdownRequested) {
          lifecycle = Lifecycle::Finalizing;
          stopping.store(true, std::memory_order_release);
          schedule = true;
          invalidate = true;
        }
        break;
      case Lifecycle::Preparing:
        invalidate = !stopRequestedDuringPrepare;
        stopRequestedDuringPrepare = true;
        stopping.store(true, std::memory_order_release);
        preparationToCancel = activePreparation;
        break;
      case Lifecycle::Prepared:
      case Lifecycle::Starting:
      case Lifecycle::Running:
        running.store(false, std::memory_order_release);
        (void)setDisplayLinkRunning(false);
        lifecycle = shutdownRequested ? Lifecycle::Finalizing
                                      : Lifecycle::Retiring;
        stopping.store(true, std::memory_order_release);
        schedule = true;
        invalidate = true;
        break;
      case Lifecycle::Retiring:
        if (shutdownRequested) {
          lifecycle = Lifecycle::Finalizing;
        }
        break;
      case Lifecycle::Finalizing:
        break;
      }
    }

    std::uint64_t invalidationGeneration =
        requestedGeneration.load(std::memory_order_acquire);
    if (invalidate || (final && scheduledOutput != nullptr)) {
      std::lock_guard presentationLock(presentationMutex);
      bool generationExhausted = false;
      if (invalidate) {
        if (const auto nextGeneration = advanceGeneration()) {
          invalidationGeneration = *nextGeneration;
        } else {
          // UINT64_MAX is already a permanently fail-closed generation. Never
          // wrap and accidentally re-admit generation zero.
          invalidationGeneration =
              requestedGeneration.load(std::memory_order_acquire);
          generationExhausted = true;
        }
      } else {
        invalidationGeneration =
            requestedGeneration.load(std::memory_order_acquire);
      }
      heldFrame.reset();
      retryFrame.reset();
      if (scheduledOutput != nullptr) {
        scheduledOutput->setFailureHandler({});
        if (final || generationExhausted) {
          scheduledOutput->close(invalidationGeneration);
        } else {
          if (!scheduledOutput->flush(invalidationGeneration, nullptr)) {
            scheduledOutput->close(invalidationGeneration);
          }
        }
      }
    }

    if (preparationToCancel != nullptr) {
      preparationToCancel->cancelled.store(true, std::memory_order_release);
      schedulePreparationCancellation(preparationToCancel);
    }

    failureState->disable();
    running.store(false, std::memory_order_release);
    prepared.store(false, std::memory_order_release);
    if (presenter != nullptr) {
      presenter->setFailureHandler({}, {});
      presenter->setVisible(false);
    }
    signalWorkerStop();
    if (schedule) {
      scheduleRetirement();
    }
    return invalidationGeneration;
  }

  void completeRetirement() noexcept {
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
    waitAtRetirementBarrier();
#endif
    // These operations have no contractual upper bound. The private serial
    // owner, never AppKit or the frontend, absorbs that latency and retains
    // every object a late callback can reach.
    (void)setDisplayLinkRunning(false);
    cancelActiveReader();
    joinWorkerThread();
    if (presentationSource != nil) {
      dispatch_sync(presentationQueue, ^{});
    }
    {
      std::lock_guard lock(presentationMutex);
      heldFrame.reset();
      retryFrame.reset();
    }

    std::unique_ptr<VideoToolboxDecoder> retiredDecoder;
    std::unique_ptr<NotifyingFrameSink> retiredSink;
    std::vector<std::byte> retiredCodecConfiguration;
    {
      std::lock_guard lock(resourceMutex);
      retiredDecoder = std::move(decoder);
      retiredSink = std::move(sink);
      asset = nil;
      track = nil;
      codec = 0;
      dimensions = {0, 0};
      retiredCodecConfiguration = std::move(codecConfiguration);
      assetDuration = kCMTimeInvalid;
    }
    if (retiredDecoder != nullptr) {
      // retiredSink intentionally outlives close(): AsyncDecodeState stores a
      // non-owning sink pointer, and Apple may issue its final callback from
      // inside the wait/invalidate sequence.
      retiredDecoder->close();
    }
    retiredDecoder.reset();
    retiredSink.reset();
    retiredCodecConfiguration.clear();

    bool final = false;
    {
      std::lock_guard lock(lifecycleMutex);
      if (ownsProcessAdmission) {
        ownsProcessAdmission = false;
        // Publish process admission before Idle/stopping=false. A caller that
        // observes retirement completion must not lose CAS to our stale lease.
        gNativeAttemptAdmission.store(false, std::memory_order_release);
      }
      final = shutdownRequested;
      if (final) {
        lifecycle = Lifecycle::Finalizing;
      } else {
        lifecycle = Lifecycle::Idle;
        stopRequestedDuringPrepare = false;
        preparedInitialPosition = 0.0;
        preparedFrameGeneration = 0;
        preparedFailureEpoch = 0;
        stopping.store(false, std::memory_order_release);
      }
    }

    if (!final) {
      return;
    }

    // Stop/release only after worker and decoder retirement. The source drain
    // linearizes every queued presenter block; the display-link block itself
    // owns a weak control block and a stable source rather than raw Impl*.
    releaseDisplayInfrastructureNoexcept(true);
  }
};

NativeVideoPipeline::NativeVideoPipeline(std::shared_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

NativeVideoPipeline::~NativeVideoPipeline() {
  if (impl_ != nullptr) {
    // The queued task becomes the sole owner after this frontend releases its
    // shared_ptr. No callback captures NativeVideoPipeline itself.
    impl_->requestTeardown(true);
  }
}

std::unique_ptr<NativeVideoPipeline> NativeVideoPipeline::create(
    std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  std::shared_ptr<Impl> impl;
  bool constructionComplete = false;
  ScopeExit constructionCleanup([&]() noexcept {
    if (!constructionComplete && impl != nullptr) {
      impl->releaseDisplayInfrastructureNoexcept(true);
    }
  });
  try {
    impl = std::make_shared<Impl>();
    if (!impl->dispatchInfrastructureReady()) {
      assignFixedErrorNoexcept(
          error, "native video dispatch queues could not be created");
      return nullptr;
    }
    impl->presenter = MetalLayerPresenter::create(error);
    if (impl->presenter == nullptr) {
      return nullptr;
    }
    if (!impl->initializePresentationSource(error) ||
        !impl->createDisplayLink(error)) {
      return nullptr;
    }
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
    if (gFailNextPipelineWrapperAllocation.exchange(
            false, std::memory_order_acq_rel)) {
      throw std::bad_alloc();
    }
#endif
    auto pipeline = std::unique_ptr<NativeVideoPipeline>(
        new NativeVideoPipeline(impl));
    constructionComplete = true;
    return pipeline;
  } catch (...) {
    assignFixedErrorNoexcept(
        error, "native video pipeline could not be created");
    return nullptr;
  }
}

std::unique_ptr<NativeVideoPipeline> NativeVideoPipeline::createForQtOpenGL(
    std::shared_ptr<NativeScheduledFrameOutput> output,
    std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  std::shared_ptr<Impl> impl;
  bool constructionComplete = false;
  ScopeExit constructionCleanup([&]() noexcept {
    if (!constructionComplete && impl != nullptr) {
      impl->releaseDisplayInfrastructureNoexcept(true);
    }
  });
  try {
    if (output == nullptr) {
      assignError(error, "native Qt OpenGL output is required");
      return nullptr;
    }
    const NativeScheduledFrameOutputStats outputStats = output->stats();
    if (outputStats.closed) {
      assignError(error, "native Qt OpenGL output is already closed");
      return nullptr;
    }
    if (outputStats.fatalErrorSerial != 0) {
      assignError(error,
                  "native Qt OpenGL output is terminal; recreate the output "
                  "adapter before preparing");
      return nullptr;
    }
    if (outputStats.acceptedGeneration ==
        std::numeric_limits<std::uint64_t>::max()) {
      assignError(error, "native Qt OpenGL output generation is exhausted");
      return nullptr;
    }

    impl = std::make_shared<Impl>();
    if (!impl->dispatchInfrastructureReady()) {
      assignFixedErrorNoexcept(
          error, "native video dispatch queues could not be created");
      return nullptr;
    }
    impl->outputMode = NativeVideoOutputMode::QtOpenGL;
    impl->scheduledOutput = std::move(output);
    // Reusing an output with a new pipeline remains monotonic. The first
    // configured decoder generation will be strictly newer than every frame the
    // Qt item has already accepted.
    impl->requestedGeneration.store(outputStats.acceptedGeneration,
                                    std::memory_order_release);
    impl->attached.store(true, std::memory_order_release);
    if (!impl->initializePresentationSource(error) ||
        !impl->createDisplayLink(error)) {
      return nullptr;
    }
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
    if (gFailNextPipelineWrapperAllocation.exchange(
            false, std::memory_order_acq_rel)) {
      throw std::bad_alloc();
    }
#endif
    auto pipeline = std::unique_ptr<NativeVideoPipeline>(
        new NativeVideoPipeline(impl));
    constructionComplete = true;
    return pipeline;
  } catch (...) {
    assignFixedErrorNoexcept(
        error, "native Qt OpenGL pipeline could not be created");
    return nullptr;
  }
}

bool NativeVideoPipeline::attachToView(void* nativeView, std::string* error) {
  if (impl_->presenter == nullptr) {
    assignError(error,
                "the Qt OpenGL output is attached by its QQuickItem");
    return false;
  }
  if (!impl_->presenter->attachToView(nativeView, error)) {
    impl_->attached.store(false, std::memory_order_release);
    return false;
  }
  impl_->attached.store(true, std::memory_order_release);
  const bool active = impl_->failureState->active();
  const bool running = impl_->running.load(std::memory_order_acquire);
  impl_->presenter->setVisible(active && running);
  if (active && running) {
    // Headless preparation may already have filled the bounded queue while the
    // clock is paused. Wake the serial presenter immediately on attachment;
    // there may be no future decode callback or display-link tick to do it.
    impl_->pausedPresentationNeeded.store(true, std::memory_order_release);
    dispatch_source_merge_data(impl_->presentationSource, 1);
  }
  return true;
}

void NativeVideoPipeline::detach() noexcept {
  // Layer invalidation/removal is the only detach mutation that belongs on the
  // AppKit thread. Worker/decoder retirement is merely signaled below.
  if (impl_->presenter != nullptr) {
    impl_->presenter->detach();
  }
  impl_->attached.store(false, std::memory_order_release);
  (void)stop();
}

void NativeVideoPipeline::resize(double widthPoints, double heightPoints,
                                 double backingScale) noexcept {
  if (impl_->presenter != nullptr) {
    impl_->presenter->resize(widthPoints, heightPoints, backingScale);
  }
}

bool NativeVideoPipeline::prepareLocalFileAsync(
    const std::filesystem::path& path, double initialPositionSeconds,
    std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  auto request = std::make_shared<Impl::PreparationRequest>();
  request->path = path;
  request->initialPositionSeconds = initialPositionSeconds;
  bool retireExisting = false;
  if (!impl_->beginPreparation(request, &retireExisting, error)) {
    if (retireExisting) {
      impl_->requestTeardown(false);
    }
    return false;
  }
  impl_->schedulePreparation(request);
  return true;
}

std::optional<NativeVideoPrepareOutcome>
NativeVideoPipeline::takePrepareResult() noexcept {
  std::lock_guard lock(impl_->preparationResultMutex);
  std::optional<NativeVideoPrepareOutcome> result =
      std::move(impl_->preparationResult);
  impl_->preparationResult.reset();
  return result;
}

std::optional<std::uint64_t> NativeVideoPipeline::startPrepared(
    std::string* error) noexcept {
  return impl_->startPrepared(error);
}

std::uint64_t NativeVideoPipeline::stop() noexcept {
  return impl_->requestTeardown(false);
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
  // Serialize the decision and the physical display-link/source mutation with
  // Starting/Running/Retiring transitions. A stale pre-retirement active
  // snapshot can otherwise restart CVDisplayLink after Idle.
  bool displayTransitionFailed = false;
  {
    std::lock_guard lifecycleLock(impl_->lifecycleMutex);
    const bool running = impl_->lifecycle == Impl::Lifecycle::Running &&
                         impl_->running.load(std::memory_order_acquire) &&
                         impl_->failureState->active();
    if (running && !impl_->setDisplayLinkRunning(!paused)) {
      impl_->reportFixedFailure(paused ? kDisplayLinkStopError
                                       : kDisplayLinkStartError);
      displayTransitionFailed = true;
    } else if (paused && running) {
      impl_->pausedPresentationNeeded.store(true, std::memory_order_release);
      if (impl_->presentationSource != nil) {
        dispatch_source_merge_data(impl_->presentationSource, 1);
      }
    }
  }
  if (displayTransitionFailed) {
    (void)impl_->requestTeardown(false);
  }
}

std::optional<std::uint64_t> NativeVideoPipeline::seek(
    double positionSeconds) noexcept {
  if (!finiteNonnegative(positionSeconds)) {
    return std::nullopt;
  }
  std::lock_guard lifecycleLock(impl_->lifecycleMutex);
  if (impl_->lifecycle != Impl::Lifecycle::Running ||
      !impl_->running.load(std::memory_order_acquire) ||
      !impl_->failureState->active()) {
    return std::nullopt;
  }
  std::lock_guard resourceLock(impl_->resourceMutex);
  if (!impl_->failureState->active() || impl_->decoder == nullptr ||
      impl_->sink == nullptr) {
    return std::nullopt;
  }
  positionSeconds = impl_->normalizePosition(positionSeconds);
  std::uint64_t generation = 0;
  {
    std::lock_guard lock(impl_->presentationMutex);
    const std::optional<std::uint64_t> nextGeneration =
        impl_->advanceGeneration();
    if (!nextGeneration) {
      impl_->reportFailure("native video frame generation is exhausted");
      return std::nullopt;
    }
    generation = *nextGeneration;
    impl_->minimumPresentationSeconds = positionSeconds;
    impl_->heldFrame.reset();
    impl_->retryFrame.reset();
    if (impl_->scheduledOutput != nullptr) {
      std::string outputError;
      if (!impl_->scheduledOutput->flush(generation, &outputError)) {
        impl_->reportFailure(
            outputError.empty()
                ? "native Qt OpenGL output could not flush a seek"
                : std::move(outputError));
        return std::nullopt;
      }
    }
  }
  AVAssetReader* reader = nil;
  {
    std::lock_guard lock(impl_->stateMutex);
    impl_->requestedSeekSeconds = positionSeconds;
    ++impl_->seekVersion;
    reader = impl_->activeReader;
  }
  impl_->pausedPresentationNeeded.store(true, std::memory_order_release);
  if (reader != nil) {
    [reader cancelReading];
  }
  impl_->workerWake.notify_all();
  dispatch_source_merge_data(impl_->presentationSource, 1);
  return generation;
}

bool NativeVideoPipeline::attached() const noexcept {
  return impl_->attached.load(std::memory_order_acquire);
}

bool NativeVideoPipeline::active() const noexcept {
  return impl_->running.load(std::memory_order_acquire) &&
         impl_->failureState->active();
}

std::optional<std::string> NativeVideoPipeline::takeLastError() noexcept {
  return impl_->failureState->takeLastError();
}

NativeVideoPipelineStats NativeVideoPipeline::stats() const noexcept {
  NativeVideoPipelineStats result;
  result.prepared = impl_->prepared.load(std::memory_order_acquire);
  result.active = impl_->running.load(std::memory_order_acquire) &&
                  impl_->failureState->active();
  result.stopping = impl_->stopping.load(std::memory_order_acquire);
  result.outputMode = impl_->outputMode;
  result.generation =
      impl_->requestedGeneration.load(std::memory_order_acquire);
  result.compressedSamplesRead =
      impl_->counters.compressedSamplesRead.load(std::memory_order_relaxed);
  result.compressedSamplesSubmitted =
      impl_->counters.compressedSamplesSubmitted.load(
          std::memory_order_relaxed);
  result.scheduledFrames =
      impl_->counters.scheduledFrames.load(std::memory_order_relaxed);
  result.dispatchedFrames =
      impl_->counters.dispatchedFrames.load(std::memory_order_relaxed);
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
  {
    std::lock_guard resourceLock(impl_->resourceMutex);
    if (impl_->sink != nullptr) {
      result.queueDepth = impl_->sink->size();
      result.queueCapacity = impl_->sink->capacity();
    }
    if (impl_->decoder != nullptr) {
      result.decoder = impl_->decoder->stats();
      result.hardwareDecode =
          result.decoder.usingHardwareAcceleratedDecoder;
    }
  }
  if (impl_->presenter != nullptr) {
    result.presenter = impl_->presenter->stats();
  }
  if (impl_->scheduledOutput != nullptr) {
    result.scheduledOutput = impl_->scheduledOutput->stats();
    // The bridge establishes this exact attempt baseline only when the
    // startup generation flush is actually applied on the GUI thread. It is
    // therefore immune to prior-attempt redraws while an off-GUI start is
    // waiting in the event queue.
    result.actuallyRenderedFrames =
        result.prepared &&
                !impl_->running.load(std::memory_order_acquire)
            ? 0
            : result.scheduledOutput.attemptAcceptedRenderedFrames;
  }
  return result;
}

#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
void NativeVideoPipelineTestAccess::failNextFactoryWrapperAllocation() {
  gFailNextPipelineWrapperAllocation.store(true, std::memory_order_release);
}

bool NativeVideoPipelineTestAccess::exercisePresentationExceptionBoundary(
    NativeVideoPipeline& pipeline) noexcept {
  const std::uint64_t epoch = pipeline.impl_->failureState->beginAttempt();
  pipeline.impl_->failureState->activate(epoch);
  pipeline.impl_->failNextPresentationDispatch.store(
      true, std::memory_order_release);
  pipeline.impl_->renderAtAudioClock();
  const bool failed = pipeline.impl_->failureState->failed(epoch);
  pipeline.impl_->failureState->disablePreservingError();
  return failed;
}

void NativeVideoPipelineTestAccess::failNextWorkerSampleSubmission(
    NativeVideoPipeline& pipeline) noexcept {
  pipeline.impl_->failNextWorkerSampleSubmission.store(
      true, std::memory_order_release);
}

bool NativeVideoPipelineTestAccess::hasActiveReader(
    const NativeVideoPipeline& pipeline) noexcept {
  std::lock_guard lock(pipeline.impl_->stateMutex);
  return pipeline.impl_->activeReader != nil;
}

void NativeVideoPipelineTestAccess::failNextDisplayLinkStart(
    NativeVideoPipeline& pipeline) noexcept {
  pipeline.impl_->failNextDisplayLinkStart.store(true,
                                                 std::memory_order_release);
}

void NativeVideoPipelineTestAccess::failNextDisplayLinkStop(
    NativeVideoPipeline& pipeline) noexcept {
  pipeline.impl_->failNextDisplayLinkStop.store(true,
                                                std::memory_order_release);
}

bool NativeVideoPipelineTestAccess::setDisplayLinkRunning(
    NativeVideoPipeline& pipeline, bool running) noexcept {
  return pipeline.impl_->setDisplayLinkRunning(running);
}

bool NativeVideoPipelineTestAccess::displayLinkHealthy(
    const NativeVideoPipeline& pipeline) noexcept {
  return pipeline.impl_->displayLinkHealthy.load(std::memory_order_acquire);
}

void NativeVideoPipelineTestAccess::setPreparationLoadBarrier(
    NativeVideoPipeline& pipeline, std::shared_future<void> release,
    std::shared_ptr<std::atomic<bool>> entered) {
  std::lock_guard lock(pipeline.impl_->schedulingTestMutex);
  pipeline.impl_->preparationLoadBarrier = std::move(release);
  pipeline.impl_->preparationLoadEntered = std::move(entered);
}

void NativeVideoPipelineTestAccess::setAssetLoadCallbackBarrier(
    NativeVideoPipeline& pipeline, std::shared_future<void> release,
    std::shared_ptr<std::atomic<bool>> entered) {
  std::lock_guard lock(pipeline.impl_->schedulingTestMutex);
  pipeline.impl_->assetLoadCallbackBarrier = std::move(release);
  pipeline.impl_->assetLoadCallbackEntered = std::move(entered);
}

void NativeVideoPipelineTestAccess::setTrackLoadCallbackBarrier(
    NativeVideoPipeline& pipeline, std::shared_future<void> release,
    std::shared_ptr<std::atomic<bool>> entered) {
  std::lock_guard lock(pipeline.impl_->schedulingTestMutex);
  pipeline.impl_->trackLoadCallbackBarrier = std::move(release);
  pipeline.impl_->trackLoadCallbackEntered = std::move(entered);
}

void NativeVideoPipelineTestAccess::setPreparationCancellationMarker(
    NativeVideoPipeline& pipeline,
    std::shared_ptr<std::atomic<bool>> entered) {
  std::lock_guard lock(pipeline.impl_->schedulingTestMutex);
  pipeline.impl_->preparationCancellationEntered = std::move(entered);
}

void NativeVideoPipelineTestAccess::failNextPreparationAfterResourceTransfer(
    NativeVideoPipeline& pipeline) {
  pipeline.impl_->failAfterResourceTransfer.store(
      true, std::memory_order_release);
}

void NativeVideoPipelineTestAccess::setPreparationCommitBarrier(
    NativeVideoPipeline& pipeline, std::shared_future<void> release,
    std::shared_ptr<std::atomic<bool>> entered) {
  std::lock_guard lock(pipeline.impl_->schedulingTestMutex);
  pipeline.impl_->preparationCommitBarrier = std::move(release);
  pipeline.impl_->preparationCommitEntered = std::move(entered);
}

void NativeVideoPipelineTestAccess::setRetirementBarrier(
    NativeVideoPipeline& pipeline, std::shared_future<void> release,
    std::shared_ptr<std::atomic<bool>> entered) {
  std::lock_guard lock(pipeline.impl_->schedulingTestMutex);
  pipeline.impl_->retirementBarrier = std::move(release);
  pipeline.impl_->retirementEntered = std::move(entered);
}

void NativeVideoPipelineTestAccess::setStartPreparedPostWorkerBarrier(
    NativeVideoPipeline& pipeline, std::shared_future<void> release,
    std::shared_ptr<std::atomic<bool>> entered) {
  std::lock_guard lock(pipeline.impl_->schedulingTestMutex);
  pipeline.impl_->startPreparedPostWorkerBarrier = std::move(release);
  pipeline.impl_->startPreparedPostWorkerEntered = std::move(entered);
}
#endif

}  // namespace wam::macos
