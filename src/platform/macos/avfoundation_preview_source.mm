#include "avfoundation_preview_source.hpp"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <mutex>
#include <numeric>
#include <optional>
#include <span>
#include <utility>

namespace wam::macos {
namespace {

using media::MediaCodec;
using media::MediaGeneration;
using media::MediaPayloadLease;
using media::MediaPayloadStorage;
using media::MediaSample;
using media::MediaSampleKind;
using media::MediaSourceDescriptor;
using media::MediaSourceLimits;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackId;
using media::MediaTrackKind;

constexpr std::size_t kMaximumSyncCursorSteps{100'000};

void assignError(std::string* error, const char* message) {
  if (error != nullptr) {
    *error = message;
  }
}

[[nodiscard]] std::string describeNSError(NSError* error,
                                          const char* fallback) {
  if (error == nil || error.localizedDescription == nil) {
    return fallback;
  }
  const char* text = error.localizedDescription.UTF8String;
  return text == nullptr ? fallback : std::string(text);
}

[[nodiscard]] std::optional<MediaTime> exactMediaTime(CMTime time) noexcept {
  if (!CMTIME_IS_NUMERIC(time) || time.timescale <= 0 || time.epoch != 0 ||
      (time.flags & kCMTimeFlags_HasBeenRounded) != 0) {
    return std::nullopt;
  }
  return MediaTime{time.value, time.timescale};
}

[[nodiscard]] MediaTime optionalMediaTime(CMTime time) noexcept {
  return exactMediaTime(time).value_or(MediaTime{});
}

[[nodiscard]] std::optional<CMTime> exactCMTime(MediaTime time) noexcept {
  if (!time.valid()) {
    return std::nullopt;
  }
  return CMTimeMake(time.value, time.timescale);
}

[[nodiscard]] bool withinDuration(MediaTime target,
                                  MediaTime duration) noexcept {
  if (!target.valid() || target.value < 0 || !duration.valid() ||
      duration.value < 0) {
    return false;
  }
  const auto order = media::compareMediaTime(target, duration);
  return order.has_value() && *order != MediaTimeOrder::Greater;
}

[[nodiscard]] std::optional<MediaTime> checkedTimeSum(MediaTime lhs,
                                                       MediaTime rhs) noexcept {
  if (!lhs.valid() || !rhs.valid()) {
    return std::nullopt;
  }
  using WideSigned = __int128_t;
  using WideUnsigned = __uint128_t;
  const WideSigned numerator =
      static_cast<WideSigned>(lhs.value) * rhs.timescale +
      static_cast<WideSigned>(rhs.value) * lhs.timescale;
  const std::uint64_t denominator =
      static_cast<std::uint64_t>(static_cast<std::uint32_t>(lhs.timescale)) *
      static_cast<std::uint64_t>(static_cast<std::uint32_t>(rhs.timescale));
  if (denominator == 0) {
    return std::nullopt;
  }
  const WideUnsigned magnitude =
      numerator < 0
          ? static_cast<WideUnsigned>(-(numerator + 1)) + 1
          : static_cast<WideUnsigned>(numerator);
  const std::uint64_t common =
      std::gcd(denominator,
               static_cast<std::uint64_t>(magnitude % denominator));
  const WideSigned reduced = numerator / static_cast<WideSigned>(common);
  const std::uint64_t scale = denominator / common;
  if (reduced <
          static_cast<WideSigned>(std::numeric_limits<std::int64_t>::min()) ||
      reduced >
          static_cast<WideSigned>(std::numeric_limits<std::int64_t>::max()) ||
      scale == 0 ||
      scale > static_cast<std::uint64_t>(
                  std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  return MediaTime{static_cast<std::int64_t>(reduced),
                   static_cast<std::int32_t>(scale)};
}

[[nodiscard]] bool validBinding(
    const NativePreviewBinding& binding) noexcept {
  try {
    if (binding.localPath.empty() || !binding.localPath.is_absolute() ||
        binding.descriptor == nullptr ||
        !media::validateMediaSourceDescriptor(
            *binding.descriptor,
            media::clampMediaSourceLimits(binding.limits), nullptr) ||
        !binding.descriptor->selectedVideo.has_value()) {
      return false;
    }
    // A supplied context must be this backend's own. Selection normally
    // happens in createNativePreviewSource(), but the standalone create()
    // entry points are reachable directly and must refuse a foreign context
    // rather than silently fall back to a second cold asset load.
    if (binding.assetContext != nullptr &&
        (binding.assetContext->backendKind() !=
             media::MediaSourceBackendKind::AVFoundation ||
         !binding.assetContext->matchesPreviewBinding(
             binding.localPath, binding.descriptor))) {
      return false;
    }
    const MediaTrackDescriptor* track = media::findMediaTrack(
        *binding.descriptor, *binding.descriptor->selectedVideo);
    return track != nullptr && track->kind == MediaTrackKind::Video &&
           track->video.has_value() &&
           (track->codec == MediaCodec::H264 ||
            track->codec == MediaCodec::Hevc) &&
           !track->codecConfiguration.empty();
  } catch (...) {
    return false;
  }
}

[[nodiscard]] bool validRequest(const NativePreviewBinding& binding,
                                NativePreviewRequest request) noexcept {
  return request.epoch != 0 && binding.descriptor != nullptr &&
         withinDuration(request.target, binding.descriptor->duration);
}

class ScopedSampleBuffer final {
 public:
  explicit ScopedSampleBuffer(CMSampleBufferRef sample = nullptr) noexcept
      : sample_(sample) {}
  ScopedSampleBuffer(const ScopedSampleBuffer&) = delete;
  ScopedSampleBuffer& operator=(const ScopedSampleBuffer&) = delete;
  ScopedSampleBuffer(ScopedSampleBuffer&& other) noexcept
      : sample_(std::exchange(other.sample_, nullptr)) {}
  ~ScopedSampleBuffer() {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

  [[nodiscard]] CMSampleBufferRef get() const noexcept { return sample_; }
  [[nodiscard]] CMSampleBufferRef release() noexcept {
    return std::exchange(sample_, nullptr);
  }

 private:
  CMSampleBufferRef sample_{nullptr};
};

class PreviewSampleStorage final : public MediaPayloadStorage {
 public:
  PreviewSampleStorage(CMSampleBufferRef ownedSample,
                       std::size_t byteSize) noexcept
      : sample_(ownedSample), byteSize_(byteSize) {}
  ~PreviewSampleStorage() override {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

  [[nodiscard]] std::size_t byteSize() const noexcept override {
    return byteSize_;
  }

  [[nodiscard]] std::span<const std::byte>
  contiguousBytes() const noexcept override {
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_);
    if (block == nullptr) {
      return {};
    }
    char* data = nullptr;
    std::size_t contiguous = 0;
    std::size_t total = 0;
    const OSStatus status = CMBlockBufferGetDataPointer(
        block, 0, &contiguous, &total, &data);
    if (status != noErr || data == nullptr || total != byteSize_ ||
        contiguous != total) {
      return {};
    }
    return {reinterpret_cast<const std::byte*>(data), total};
  }

  [[nodiscard]] bool copyBytes(
      std::size_t offset,
      std::span<std::byte> destination) const noexcept override {
    if (offset > byteSize_ || destination.size() > byteSize_ - offset) {
      return false;
    }
    if (destination.empty()) {
      return true;
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_);
    return block != nullptr &&
           CMBlockBufferCopyDataBytes(block, offset, destination.size(),
                                      destination.data()) == noErr;
  }

 protected:
  [[nodiscard]] std::optional<media::NativePayloadKind>
  nativePayloadKind() const noexcept override {
    return media::NativePayloadKind::CoreMediaSampleBuffer;
  }
  [[nodiscard]] const void* borrowedNativePayload() const noexcept override {
    return sample_;
  }

 private:
  CMSampleBufferRef sample_{nullptr};
  std::size_t byteSize_{0};
};

[[nodiscard]] bool sampleIsKeyFrame(CMSampleBufferRef sample,
                                    bool* keyFrame) noexcept {
  if (sample == nullptr || keyFrame == nullptr) {
    return false;
  }
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    *keyFrame = true;
    return true;
  }
  if (CFArrayGetCount(attachments) != 1) {
    return false;
  }
  CFTypeRef first = CFArrayGetValueAtIndex(attachments, 0);
  if (first == nullptr || CFGetTypeID(first) != CFDictionaryGetTypeID()) {
    return false;
  }
  CFTypeRef notSync = CFDictionaryGetValue(
      static_cast<CFDictionaryRef>(first),
      kCMSampleAttachmentKey_NotSync);
  if (notSync == nullptr) {
    *keyFrame = true;
    return true;
  }
  if (CFGetTypeID(notSync) != CFBooleanGetTypeID()) {
    return false;
  }
  *keyFrame = !CFBooleanGetValue(static_cast<CFBooleanRef>(notSync));
  return true;
}

[[nodiscard]] CFDataRef configurationAtom(
    CMFormatDescriptionRef format, MediaCodec codec) noexcept {
  if (format == nullptr) {
    return nullptr;
  }
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
  if (extensions == nullptr) {
    return nullptr;
  }
  CFTypeRef atomsValue = CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
  if (atomsValue == nullptr ||
      CFGetTypeID(atomsValue) != CFDictionaryGetTypeID()) {
    return nullptr;
  }
  CFStringRef key = codec == MediaCodec::H264 ? CFSTR("avcC")
                                               : CFSTR("hvcC");
  CFTypeRef atom = CFDictionaryGetValue(
      static_cast<CFDictionaryRef>(atomsValue), key);
  if (atom == nullptr || CFGetTypeID(atom) != CFDataGetTypeID()) {
    return nullptr;
  }
  return static_cast<CFDataRef>(atom);
}

[[nodiscard]] bool formatMatchesTrack(
    CMFormatDescriptionRef format,
    const MediaTrackDescriptor& track) noexcept {
  if (format == nullptr || track.kind != MediaTrackKind::Video ||
      !track.video.has_value() ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) {
    return false;
  }
  const CMVideoCodecType expectedCodec =
      track.codec == MediaCodec::H264 ? kCMVideoCodecType_H264
                                      : kCMVideoCodecType_HEVC;
  if (CMFormatDescriptionGetMediaSubType(format) != expectedCodec) {
    return false;
  }
  const CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(
      static_cast<CMVideoFormatDescriptionRef>(format));
  if (dimensions.width <= 0 || dimensions.height <= 0 ||
      static_cast<std::uint32_t>(dimensions.width) !=
          track.video->codedWidth ||
      static_cast<std::uint32_t>(dimensions.height) !=
          track.video->codedHeight) {
    return false;
  }
  CFDataRef atom = configurationAtom(format, track.codec);
  if (atom == nullptr || CFDataGetLength(atom) < 0 ||
      static_cast<std::size_t>(CFDataGetLength(atom)) !=
          track.codecConfiguration.size()) {
    return false;
  }
  const UInt8* bytes = CFDataGetBytePtr(atom);
  return bytes != nullptr &&
         std::memcmp(bytes, track.codecConfiguration.data(),
                     track.codecConfiguration.size()) == 0;
}

[[nodiscard]] std::optional<MediaSample> makeMediaSample(
    ScopedSampleBuffer owned, std::uint64_t epoch, MediaTime target,
    const MediaTrackDescriptor& track, const MediaSourceDescriptor& descriptor,
    const MediaSourceLimits& limits, std::string* error) {
  CMSampleBufferRef sample = owned.get();
  if (sample == nullptr || !CMSampleBufferIsValid(sample) ||
      !CMSampleBufferDataIsReady(sample) ||
      CMSampleBufferGetNumSamples(sample) != 1 ||
      !formatMatchesTrack(CMSampleBufferGetFormatDescription(sample), track)) {
    assignError(error,
                "preview reader returned an invalid or changed video sample");
    return std::nullopt;
  }
  const auto presentation =
      exactMediaTime(CMSampleBufferGetPresentationTimeStamp(sample));
  const MediaTime decode =
      optionalMediaTime(CMSampleBufferGetDecodeTimeStamp(sample));
  const auto duration = exactMediaTime(CMSampleBufferGetDuration(sample));
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  const std::size_t bytes =
      block == nullptr ? 0 : CMBlockBufferGetDataLength(block);
  const MediaSourceLimits effective = media::clampMediaSourceLimits(limits);
  bool keyFrame = false;
  if (!presentation.has_value() || !duration.has_value() ||
      presentation->value < 0 || duration->value <= 0 || bytes == 0 ||
      bytes > effective.maximumVideoSampleBytes ||
      !sampleIsKeyFrame(sample, &keyFrame)) {
    assignError(error, "preview video sample exceeds its bounded contract");
    return std::nullopt;
  }
  const auto intervalEnd = checkedTimeSum(*presentation, *duration);
  const auto endAgainstTarget =
      intervalEnd ? media::compareMediaTime(*intervalEnd, target)
                  : std::nullopt;
  if (!endAgainstTarget.has_value()) {
    assignError(error, "preview sample interval is not exactly comparable");
    return std::nullopt;
  }
  // Keep the +1 CoreMedia reference in the scope guard until make_shared has
  // allocated and completed its noexcept storage construction. Releasing it
  // as a function argument would leak if allocation threw first.
  auto storage =
      std::make_shared<PreviewSampleStorage>(owned.get(), bytes);
  static_cast<void>(owned.release());
  MediaSample result;
  result.generation = epoch;
  result.track = track.id;
  result.kind = MediaSampleKind::EncodedVideo;
  result.presentationTime = *presentation;
  result.decodeTime = decode;
  result.duration = *duration;
  result.keyFrame = keyFrame;
  result.decodeOnly = *endAgainstTarget != MediaTimeOrder::Greater;
  result.sampleCount = 1;
  result.payload = MediaPayloadLease(std::move(storage));
  if (!media::validateMediaSample(result, descriptor, effective, error)) {
    return std::nullopt;
  }
  return result;
}

struct AsyncLoadState final {
  std::mutex mutex;
  std::condition_variable changed;
  bool complete{false};
};

[[nodiscard]] bool waitForLoadedValues(
    id<AVAsynchronousKeyValueLoading> object, NSArray<NSString*>* keys,
    const std::atomic<bool>& cancelled, std::string* error) {
  auto state = std::make_shared<AsyncLoadState>();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [object loadValuesAsynchronouslyForKeys:keys
                        completionHandler:^{
                          {
                            std::lock_guard lock(state->mutex);
                            state->complete = true;
                          }
                          state->changed.notify_all();
                        }];
#pragma clang diagnostic pop
  {
    std::unique_lock lock(state->mutex);
    while (!state->complete && !cancelled.load(std::memory_order_acquire)) {
      state->changed.wait_for(lock, std::chrono::milliseconds(2));
    }
  }
  if (cancelled.load(std::memory_order_acquire)) {
    assignError(error, "preview asset load was cancelled");
    return false;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  for (NSString* key in keys) {
    NSError* loadError = nil;
    if ([object statusOfValueForKey:key error:&loadError] !=
        AVKeyValueStatusLoaded) {
      if (error != nullptr) {
        *error = describeNSError(loadError, "preview asset load failed");
      }
      return false;
    }
  }
#pragma clang diagnostic pop
  return true;
}

[[nodiscard]] MediaTrackId stableTrackId(AVAssetTrack* track,
                                         MediaTrackId fallback) noexcept {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  const CMPersistentTrackID raw = track.trackID;
#pragma clang diagnostic pop
  return raw > 0 ? static_cast<MediaTrackId>(raw) : fallback;
}

class ProductionAssetContext final {
 public:
  explicit ProductionAssetContext(NativePreviewBinding binding)
      : binding_(std::move(binding)),
        // validBinding() has already refused any non-AVFoundation context, so
        // a null here means the standalone cold-load path, never a mismatch.
        shared_(std::dynamic_pointer_cast<const AVFoundationAssetContext>(
            binding_.assetContext)) {}

  [[nodiscard]] bool ensureLoaded(const std::atomic<bool>& cancelled,
                                  std::string* error) {
    std::lock_guard lock(loadMutex_);
    if (ready_) {
      return true;
    }
    if (shared_ != nullptr) {
      if (cancelled.load(std::memory_order_acquire) ||
          !shared_->matchesPreviewBinding(
              binding_.localPath, binding_.descriptor)) {
        assignError(error, cancelled.load(std::memory_order_acquire)
                               ? "preview asset load was cancelled"
                               : "preview shared asset identity changed");
        return false;
      }
      const AVFoundationAssetContextNativeHandles handles =
          borrowAVFoundationAssetContextNativeHandles(*shared_);
      if (!handles.complete()) {
        assignError(error,
                    "preview shared asset has no production native handles");
        return false;
      }
      asset_ = (__bridge AVURLAsset*)(const_cast<void*>(handles.asset));
      videoTrack_ = (__bridge AVAssetTrack*)(
          const_cast<void*>(handles.selectedVideoTrack));
      ready_ = asset_ != nil && videoTrack_ != nil;
      if (!ready_) {
        assignError(error, "preview shared asset context is incomplete");
      }
      return ready_;
    }
    assetLoadAttempts_.fetch_add(1, std::memory_order_relaxed);
    const auto begun = std::chrono::steady_clock::now();
    const auto finishTiming = [this, begun]() noexcept {
      const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now() - begun);
      const auto nonnegative = std::max<std::int64_t>(0, elapsed.count());
      assetLoadNanoseconds_.fetch_add(
          static_cast<std::uint64_t>(nonnegative),
          std::memory_order_relaxed);
    };

    @autoreleasepool {
      if (asset_ == nil) {
        NSString* path = [NSString
            stringWithUTF8String:binding_.localPath.string().c_str()];
        if (path == nil) {
          finishTiming();
          assignError(error, "preview media path is not valid UTF-8");
          return false;
        }
        asset_ = [AVURLAsset
            URLAssetWithURL:[NSURL fileURLWithPath:path]
                    options:@{
                      AVURLAssetPreferPreciseDurationAndTimingKey : @YES
                    }];
      }
      NSArray<NSString*>* assetKeys =
          @[@"playable", @"hasProtectedContent", @"duration", @"tracks"];
      if (!waitForLoadedValues(asset_, assetKeys, cancelled, error)) {
        finishTiming();
        return false;
      }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      const bool playable = asset_.playable;
      const bool protectedContent = asset_.hasProtectedContent;
      const CMTime assetDuration = asset_.duration;
      NSArray<AVAssetTrack*>* tracks = asset_.tracks;
#pragma clang diagnostic pop
      if (!playable || protectedContent) {
        finishTiming();
        assignError(error, "preview asset is protected or unplayable");
        return false;
      }
      const auto exactDuration = exactMediaTime(assetDuration);
      if (!exactDuration.has_value() ||
          media::compareMediaTime(*exactDuration,
                                  binding_.descriptor->duration) !=
              MediaTimeOrder::Equal) {
        finishTiming();
        assignError(error, "preview asset duration changed after admission");
        return false;
      }
      AVAssetTrack* selected = nil;
      AVAssetTrack* firstVideo = nil;
      std::size_t videoCount = 0;
      const MediaTrackId selectedId = *binding_.descriptor->selectedVideo;
      for (AVAssetTrack* track in tracks) {
        if (![track.mediaType isEqualToString:AVMediaTypeVideo]) {
          continue;
        }
        ++videoCount;
        if (firstVideo == nil) {
          firstVideo = track;
        }
        if (stableTrackId(track, selectedId) == selectedId) {
          selected = track;
        }
      }
      if (videoCount != 1 || firstVideo == nil) {
        finishTiming();
        assignError(error, "preview asset no longer has one video track");
        return false;
      }
      if (selected == nil) {
        selected = firstVideo;
      }
      NSArray<NSString*>* trackKeys = @[
        @"formatDescriptions", @"naturalTimeScale", @"timeRange",
        @"preferredTransform"
      ];
      if (!waitForLoadedValues(selected, trackKeys, cancelled, error)) {
        finishTiming();
        return false;
      }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      NSArray* formats = selected.formatDescriptions;
      const CMTimeRange range = selected.timeRange;
      const CGAffineTransform transform = selected.preferredTransform;
#pragma clang diagnostic pop
      const MediaTrackDescriptor* expected = media::findMediaTrack(
          *binding_.descriptor, selectedId);
      if (expected == nullptr || formats.count != 1 ||
          !CMTIMERANGE_IS_VALID(range) || !exactMediaTime(range.start) ||
          exactMediaTime(range.start)->value != 0 ||
          !exactMediaTime(range.duration) ||
          media::compareMediaTime(*exactMediaTime(range.duration),
                                  expected->duration) !=
              MediaTimeOrder::Equal ||
          !CGAffineTransformIsIdentity(transform) ||
          !formatMatchesTrack(
              (__bridge CMFormatDescriptionRef)formats.firstObject,
              *expected)) {
        finishTiming();
        assignError(error,
                    "preview video metadata changed after main admission");
        return false;
      }
      videoTrack_ = selected;
      ready_ = true;
      assetLoadsCompleted_.fetch_add(1, std::memory_order_relaxed);
      finishTiming();
      return true;
    }
  }

  [[nodiscard]] AVURLAsset* asset() const noexcept { return asset_; }
  [[nodiscard]] AVAssetTrack* videoTrack() const noexcept {
    return videoTrack_;
  }
  [[nodiscard]] const NativePreviewBinding& binding() const noexcept {
    return binding_;
  }

  void readerCreationAttempt() noexcept {
    if (shared_ != nullptr) {
      noteAVFoundationAssetContextReaderCreationAttempt(*shared_);
    }
  }
  void readerCreated() noexcept {
    readersCreated_.fetch_add(1, std::memory_order_relaxed);
  }
  void readerStarted() noexcept {
    readersStarted_.fetch_add(1, std::memory_order_relaxed);
    if (shared_ != nullptr) {
      noteAVFoundationAssetContextReaderStarted(*shared_);
    }
  }

  [[nodiscard]] NativePreviewBackendFacts facts() const noexcept {
    return NativePreviewBackendFacts{
        assetLoadAttempts_.load(std::memory_order_relaxed),
        assetLoadsCompleted_.load(std::memory_order_relaxed),
        assetLoadNanoseconds_.load(std::memory_order_relaxed),
        readersCreated_.load(std::memory_order_relaxed),
        readersStarted_.load(std::memory_order_relaxed)};
  }

 private:
  NativePreviewBinding binding_;
  std::shared_ptr<const AVFoundationAssetContext> shared_;
  mutable std::mutex loadMutex_;
  __strong AVURLAsset* asset_{nil};
  __strong AVAssetTrack* videoTrack_{nil};
  bool ready_{false};
  std::atomic<std::uint64_t> assetLoadAttempts_{0};
  std::atomic<std::uint64_t> assetLoadsCompleted_{0};
  std::atomic<std::uint64_t> assetLoadNanoseconds_{0};
  std::atomic<std::uint64_t> readersCreated_{0};
  std::atomic<std::uint64_t> readersStarted_{0};
};

class ProductionPreviewGeneration final
    : public AVFoundationPreviewGeneration {
 public:
  ProductionPreviewGeneration(std::shared_ptr<ProductionAssetContext> context,
                              NativePreviewRequest request)
      : context_(std::move(context)), request_(request) {}

  [[nodiscard]] std::uint64_t epoch() const noexcept override {
    return request_.epoch;
  }

  [[nodiscard]] AVFoundationPreviewGenerationStart start() override {
    @autoreleasepool {
      AVFoundationPreviewGenerationStart result;
      if (cancelled_.load(std::memory_order_acquire)) {
        result.status = NativePreviewStatus::Cancelled;
        return result;
      }
      if (!context_->ensureLoaded(cancelled_, &result.error)) {
        result.status = cancelled_.load(std::memory_order_acquire)
                            ? NativePreviewStatus::Cancelled
                            : NativePreviewStatus::Unsupported;
        return result;
      }
      AVAssetTrack* track = context_->videoTrack();
      AVURLAsset* asset = context_->asset();
      const auto target = exactCMTime(request_.target);
      if (track == nil || asset == nil || !target.has_value()) {
        result.error = "preview target or cached asset is invalid";
        return result;
      }
      AVSampleCursor* cursor =
          [track makeSampleCursorWithPresentationTimeStamp:*target];
      if (cursor == nil) {
        cursor = [track makeSampleCursorAtLastSampleInDecodeOrder];
      }
      CMTime decodeStart = kCMTimeInvalid;
      for (std::size_t step = 0;
           cursor != nil && step != kMaximumSyncCursorSteps; ++step) {
        if (cancelled_.load(std::memory_order_acquire)) {
          result.status = NativePreviewStatus::Cancelled;
          return result;
        }
        // An open-GOP random-access point presents after its own leading
        // pictures, so stepping back in decode order from one lands on a sync
        // sample later than the requested target. The bound below rejects that
        // as unsupported; keep walking instead, so an HEVC preview target that
        // happens to fall in a CRA's leading window still renders.
        if (cursor.currentSampleSyncInfo.sampleIsFullSync &&
            CMTimeCompare(cursor.presentationTimeStamp, *target) <= 0) {
          decodeStart = cursor.presentationTimeStamp;
          break;
        }
        if ([cursor stepInDecodeOrderByCount:-1] == 0) {
          break;
        }
      }
      const auto exactStart = exactMediaTime(decodeStart);
      if (!exactStart.has_value() || exactStart->value < 0 ||
          media::compareMediaTime(*exactStart, request_.target) ==
              MediaTimeOrder::Greater) {
        result.status = NativePreviewStatus::Unsupported;
        result.error = "preview could not locate a bounded full-sync start";
        return result;
      }
      const CMTime preroll = CMTimeSubtract(*target, decodeStart);
      const CMTime maximumPreroll = CMTimeMakeWithSeconds(
          media::clampMediaSourceLimits(context_->binding().limits)
              .maximumVideoSeekPrerollSeconds,
          60'000);
      if (!CMTIME_IS_NUMERIC(preroll) ||
          CMTimeCompare(preroll, kCMTimeZero) < 0 ||
          CMTimeCompare(preroll, maximumPreroll) > 0) {
        result.status = NativePreviewStatus::Unsupported;
        result.error = "preview target exceeds bounded sync preroll";
        return result;
      }

      NSError* readerError = nil;
      context_->readerCreationAttempt();
      AVAssetReader* reader =
          [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
      if (reader == nil) {
        result.error = describeNSError(readerError,
                                       "preview reader creation failed");
        return result;
      }
      context_->readerCreated();
      AVAssetReaderTrackOutput* output =
          [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                                           outputSettings:nil];
      output.alwaysCopiesSampleData = NO;
      if (output == nil || ![reader canAddOutput:output]) {
        result.status = NativePreviewStatus::Unsupported;
        result.error = "preview reader cannot expose compressed video";
        return result;
      }
      [reader addOutput:output];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      const CMTime duration = asset.duration;
#pragma clang diagnostic pop
      const CMTime remaining = CMTimeSubtract(duration, decodeStart);
      const CMTimeRange range = CMTimeRangeMake(decodeStart, remaining);
      if (!CMTIME_IS_NUMERIC(remaining) ||
          (remaining.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
          remaining.epoch != 0 || remaining.timescale <= 0 ||
          CMTimeCompare(remaining, kCMTimeZero) < 0 ||
          !CMTIMERANGE_IS_VALID(range)) {
        result.status = NativePreviewStatus::Unsupported;
        result.error = "preview reader range is not exact";
        return result;
      }
      reader.timeRange = range;
      {
        std::lock_guard lock(objectsMutex_);
        reader_ = reader;
        output_ = output;
      }
      if (cancelled_.load(std::memory_order_acquire)) {
        [reader cancelReading];
        result.status = NativePreviewStatus::Cancelled;
        return result;
      }
      if (![reader startReading]) {
        result.error = describeNSError(reader.error,
                                       "preview reader could not start");
        return result;
      }
      context_->readerStarted();
      result.status = NativePreviewStatus::Ready;
      result.actualDecodeStart = *exactStart;
      return result;
    }
  }

  [[nodiscard]] AVFoundationPreviewCopiedSample
  copyNextVideoSample() override {
    @autoreleasepool {
      AVFoundationPreviewCopiedSample result;
      if (cancelled_.load(std::memory_order_acquire)) {
        result.status = AVFoundationPreviewSampleStatus::Cancelled;
        return result;
      }
      AVAssetReader* reader = nil;
      AVAssetReaderTrackOutput* output = nil;
      {
        std::lock_guard lock(objectsMutex_);
        reader = reader_;
        output = output_;
      }
      if (reader == nil || output == nil) {
        result.error = "preview reader is not started";
        return result;
      }
      CMSampleBufferRef sample = [output copyNextSampleBuffer];
      if (sample != nullptr) {
        result.sample = sample;
        result.status = AVFoundationPreviewSampleStatus::Sample;
        return result;
      }
      const AVAssetReaderStatus status = reader.status;
      if (cancelled_.load(std::memory_order_acquire) ||
          status == AVAssetReaderStatusCancelled) {
        result.status = AVFoundationPreviewSampleStatus::Cancelled;
      } else if (status == AVAssetReaderStatusFailed) {
        result.status = AVFoundationPreviewSampleStatus::Failed;
        result.error = describeNSError(reader.error,
                                       "preview sample read failed");
      } else {
        result.status = AVFoundationPreviewSampleStatus::EndOfStream;
      }
      return result;
    }
  }

  void cancel() noexcept override {
    try {
      cancelled_.store(true, std::memory_order_release);
      @autoreleasepool {
        AVAssetReader* reader = nil;
        {
          std::lock_guard lock(objectsMutex_);
          reader = reader_;
        }
        [reader cancelReading];
      }
    } catch (...) {
    }
  }

 private:
  std::shared_ptr<ProductionAssetContext> context_;
  NativePreviewRequest request_;
  std::atomic<bool> cancelled_{false};
  std::mutex objectsMutex_;
  __strong AVAssetReader* reader_{nil};
  __strong AVAssetReaderTrackOutput* output_{nil};
};

class ProductionPreviewBackend final : public AVFoundationPreviewBackend {
 public:
  explicit ProductionPreviewBackend(NativePreviewBinding binding)
      : context_(
            std::make_shared<ProductionAssetContext>(std::move(binding))) {}

  [[nodiscard]] std::shared_ptr<AVFoundationPreviewGeneration>
  makeGeneration(const NativePreviewBinding&,
                 NativePreviewRequest request) override {
    return std::make_shared<ProductionPreviewGeneration>(context_, request);
  }

  [[nodiscard]] NativePreviewBackendFacts facts()
      const noexcept override {
    return context_->facts();
  }

 private:
  std::shared_ptr<ProductionAssetContext> context_;
};

}  // namespace

struct AVFoundationPreviewSource::Impl final {
  Impl(NativePreviewBinding suppliedBinding,
       std::shared_ptr<AVFoundationPreviewBackend> suppliedBackend)
      : binding(std::move(suppliedBinding)),
        backend(std::move(suppliedBackend)) {}

  void retireActive(bool withdrawOperation = true) noexcept {
    auto active = std::atomic_exchange_explicit(
        &publishedGeneration,
        std::shared_ptr<AVFoundationPreviewGeneration>{},
        std::memory_order_acq_rel);
    activeEpoch.store(0, std::memory_order_release);
    if (withdrawOperation) {
      operationEpoch.store(0, std::memory_order_release);
    }
    if (active != nullptr) {
      active->cancel();
    }
    ownerGeneration.reset();
    open.store(false, std::memory_order_release);
    currentStagedCompressedBytes.store(0, std::memory_order_release);
    stagedSampleBuffers.store(0, std::memory_order_release);
  }

  void updatePeak(std::size_t value) noexcept {
    std::size_t peak =
        peakStagedSampleBuffers.load(std::memory_order_relaxed);
    while (peak < value &&
           !peakStagedSampleBuffers.compare_exchange_weak(
               peak, value, std::memory_order_relaxed,
               std::memory_order_relaxed)) {
    }
  }

  void updateCompressedBytePeak(std::uint64_t value) noexcept {
    std::uint64_t peak =
        peakStagedCompressedBytes.load(std::memory_order_relaxed);
    while (peak < value &&
           !peakStagedCompressedBytes.compare_exchange_weak(
               peak, value, std::memory_order_relaxed,
               std::memory_order_relaxed)) {
    }
  }

  void publishTarget(MediaTime value) noexcept {
    targetValue.store(value.value, std::memory_order_relaxed);
    targetScale.store(value.timescale, std::memory_order_release);
  }

  void publishDecodeStart(MediaTime value) noexcept {
    decodeStartValue.store(value.value, std::memory_order_relaxed);
    decodeStartScale.store(value.timescale, std::memory_order_release);
  }

  NativePreviewBinding binding;
  std::shared_ptr<AVFoundationPreviewBackend> backend;
  std::shared_ptr<AVFoundationPreviewGeneration> ownerGeneration;
  std::shared_ptr<AVFoundationPreviewGeneration> publishedGeneration;
  MediaTime target{};
  MediaTime actualDecodeStart{};
  bool eos{false};

  std::atomic<std::uint64_t> activeEpoch{0};
  std::atomic<std::uint64_t> operationEpoch{0};
  std::atomic<std::uint64_t> epochHighWater{0};
  std::atomic<std::uint64_t> cancelledEpoch{0};
  std::atomic<std::int64_t> targetValue{0};
  std::atomic<std::int32_t> targetScale{0};
  std::atomic<std::int64_t> decodeStartValue{0};
  std::atomic<std::int32_t> decodeStartScale{0};
  std::atomic<std::size_t> stagedSampleBuffers{0};
  std::atomic<std::size_t> peakStagedSampleBuffers{0};
  std::atomic<std::uint64_t> currentStagedCompressedBytes{0};
  std::atomic<std::uint64_t> peakStagedCompressedBytes{0};
  std::atomic<std::uint64_t> samplesRead{0};
  std::atomic<std::uint64_t> discontinuitiesRead{0};
  std::atomic<std::uint64_t> forwardRetargets{0};
  std::atomic<bool> open{false};
#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
  std::atomic<AVFoundationPreviewCancelInterleaveHook> cancelInterleaveHook{
      nullptr};
  std::atomic<void*> cancelInterleaveContext{nullptr};
#endif
};

AVFoundationPreviewSource::AVFoundationPreviewSource(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

std::unique_ptr<AVFoundationPreviewSource>
AVFoundationPreviewSource::create(
    NativePreviewBinding binding) noexcept {
  if (!validBinding(binding)) {
    return {};
  }
  try {
    auto backend =
        std::make_shared<ProductionPreviewBackend>(binding);
    return create(std::move(binding), std::move(backend));
  } catch (...) {
    return {};
  }
}

std::unique_ptr<AVFoundationPreviewSource>
AVFoundationPreviewSource::create(
    NativePreviewBinding binding,
    std::shared_ptr<AVFoundationPreviewBackend> backend) noexcept {
  if (!validBinding(binding) || backend == nullptr) {
    return {};
  }
  try {
    return std::unique_ptr<AVFoundationPreviewSource>(
        new AVFoundationPreviewSource(std::make_unique<Impl>(
            std::move(binding), std::move(backend))));
  } catch (...) {
    return {};
  }
}

AVFoundationPreviewSource::~AVFoundationPreviewSource() { close(); }

NativePreviewBeginOutcome AVFoundationPreviewSource::begin(
    NativePreviewRequest request) noexcept {
  NativePreviewBeginOutcome outcome;
  outcome.epoch = request.epoch;
  if (impl_ == nullptr || !validRequest(impl_->binding, request) ||
      request.epoch <=
          impl_->epochHighWater.load(std::memory_order_acquire)) {
    outcome.error = "preview request is stale or invalid";
    return outcome;
  }
  try {
    // Publish the private epoch's exact cancellation slot, then burn it before
    // retiring the old reader. Clearing the old latch precedes publication:
    // a late cancel for the old slot is harmless, while every cancel after the
    // operationEpoch store either reaches the new generation or remains
    // latched until that generation is published. Publishing the slot before
    // the high-water mark also leaves no accepted-but-uncancellable window.
    impl_->cancelledEpoch.store(0, std::memory_order_release);
    impl_->operationEpoch.store(request.epoch, std::memory_order_release);
    impl_->epochHighWater.store(request.epoch, std::memory_order_release);
    impl_->retireActive(false);
    impl_->target = request.target;
    impl_->actualDecodeStart = {};
    impl_->publishTarget(request.target);
    impl_->publishDecodeStart({});
    impl_->eos = false;

    if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
        request.epoch) {
      outcome.status = NativePreviewStatus::Cancelled;
      impl_->retireActive();
      return outcome;
    }
    impl_->activeEpoch.store(request.epoch, std::memory_order_release);
    impl_->ownerGeneration =
        impl_->backend->makeGeneration(impl_->binding, request);
    if (impl_->ownerGeneration == nullptr ||
        impl_->ownerGeneration->epoch() != request.epoch) {
      outcome.status = NativePreviewStatus::Failed;
      outcome.error = "preview backend returned the wrong epoch";
      impl_->retireActive();
      return outcome;
    }
    std::atomic_store_explicit(&impl_->publishedGeneration,
                               impl_->ownerGeneration,
                               std::memory_order_release);
    if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
        request.epoch) {
      impl_->ownerGeneration->cancel();
    }
    AVFoundationPreviewGenerationStart started =
        impl_->ownerGeneration->start();
    if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
            request.epoch ||
        started.status == NativePreviewStatus::Cancelled) {
      outcome.status = NativePreviewStatus::Cancelled;
      outcome.error = std::move(started.error);
      impl_->retireActive();
      return outcome;
    }
    if (started.status != NativePreviewStatus::Ready ||
        !started.actualDecodeStart.valid() ||
        started.actualDecodeStart.value < 0 ||
        media::compareMediaTime(started.actualDecodeStart, request.target) ==
            MediaTimeOrder::Greater) {
      outcome.status =
          started.status == NativePreviewStatus::Ready
              ? NativePreviewStatus::Failed
              : started.status;
      outcome.error = started.error.empty()
                          ? "preview start proof is incomplete"
                          : std::move(started.error);
      impl_->retireActive();
      return outcome;
    }
    impl_->actualDecodeStart = started.actualDecodeStart;
    impl_->publishDecodeStart(started.actualDecodeStart);
    impl_->open.store(true, std::memory_order_release);
    outcome.status = NativePreviewStatus::Ready;
    outcome.actualDecodeStart = started.actualDecodeStart;
    return outcome;
  } catch (const std::exception& exception) {
    outcome.status = NativePreviewStatus::Failed;
    outcome.error = exception.what();
  } catch (...) {
    outcome.status = NativePreviewStatus::Failed;
    outcome.error = "preview start raised an unknown exception";
  }
  impl_->retireActive();
  return outcome;
}

NativePreviewReadResult AVFoundationPreviewSource::readNext(
    std::uint64_t expectedEpoch) noexcept {
  if (impl_ == nullptr || expectedEpoch == 0 ||
      expectedEpoch != impl_->activeEpoch.load(std::memory_order_acquire) ||
      !impl_->open.load(std::memory_order_acquire)) {
    return NativePreviewCancelled{expectedEpoch};
  }
  if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
      expectedEpoch) {
    impl_->retireActive();
    return NativePreviewCancelled{expectedEpoch};
  }
  if (impl_->eos) {
    return NativePreviewEndOfStream{expectedEpoch};
  }
  try {
    AVFoundationPreviewCopiedSample copied =
        impl_->ownerGeneration->copyNextVideoSample();
    ScopedSampleBuffer owned(copied.sample);
    CMSampleBufferRef nativeSample = owned.get();
    CMBlockBufferRef nativeBlock =
        nativeSample == nullptr ? nullptr
                                : CMSampleBufferGetDataBuffer(nativeSample);
    const std::uint64_t nativeBytes =
        nativeBlock == nullptr
            ? 0
            : static_cast<std::uint64_t>(
                  CMBlockBufferGetDataLength(nativeBlock));
    if (copied.sample != nullptr) {
      impl_->currentStagedCompressedBytes.store(nativeBytes,
                                                std::memory_order_release);
      impl_->updateCompressedBytePeak(nativeBytes);
      impl_->stagedSampleBuffers.store(1, std::memory_order_release);
      impl_->updatePeak(1);
    }
    const auto clearStage = [this]() noexcept {
      impl_->currentStagedCompressedBytes.store(0,
                                                std::memory_order_release);
      impl_->stagedSampleBuffers.store(0, std::memory_order_release);
    };
    if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
            expectedEpoch ||
        copied.status == AVFoundationPreviewSampleStatus::Cancelled) {
      clearStage();
      impl_->retireActive();
      return NativePreviewCancelled{expectedEpoch};
    }
    if (copied.status == AVFoundationPreviewSampleStatus::EndOfStream) {
      clearStage();
      impl_->eos = true;
      return NativePreviewEndOfStream{expectedEpoch};
    }
    if (copied.status != AVFoundationPreviewSampleStatus::Sample ||
        copied.sample == nullptr) {
      clearStage();
      std::string error =
          copied.error.empty() ? "preview sample read failed"
                               : std::move(copied.error);
      impl_->retireActive();
      return NativePreviewFailure{expectedEpoch, std::move(error)};
    }
    const MediaTrackDescriptor* track = media::findMediaTrack(
        *impl_->binding.descriptor,
        *impl_->binding.descriptor->selectedVideo);
    const CMItemCount nativeCount =
        nativeSample == nullptr ? -1
                                : CMSampleBufferGetNumSamples(nativeSample);
    CMFormatDescriptionRef nativeFormat =
        nativeSample == nullptr
            ? nullptr
            : CMSampleBufferGetFormatDescription(nativeSample);
    if (nativeSample != nullptr && CMSampleBufferIsValid(nativeSample) &&
        CMSampleBufferDataIsReady(nativeSample) &&
        nativeCount == 0 && nativeBytes == 0) {
      const auto time = exactMediaTime(
          CMSampleBufferGetPresentationTimeStamp(nativeSample));
      media::MediaDiscontinuity discontinuity{
          expectedEpoch, track == nullptr ? 0 : track->id,
          time.value_or(MediaTime{})};
      std::string discontinuityError;
      const bool valid =
          track != nullptr && time.has_value() &&
          (nativeFormat == nullptr || formatMatchesTrack(nativeFormat,
                                                         *track)) &&
                         media::validateMediaDiscontinuity(
                             discontinuity, *impl_->binding.descriptor,
                             &discontinuityError);
      clearStage();
      if (!valid) {
        impl_->retireActive();
        return NativePreviewFailure{
            expectedEpoch,
            discontinuityError.empty()
                ? "preview discontinuity is invalid"
                : std::move(discontinuityError)};
      }
      if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
          expectedEpoch) {
        impl_->retireActive();
        return NativePreviewCancelled{expectedEpoch};
      }
      impl_->discontinuitiesRead.fetch_add(1, std::memory_order_relaxed);
      return discontinuity;
    }
    std::string error;
    auto sample = track == nullptr
                      ? std::nullopt
                      : makeMediaSample(
                            std::move(owned), expectedEpoch, impl_->target,
                            *track, *impl_->binding.descriptor,
                            impl_->binding.limits, &error);
    clearStage();
    if (!sample.has_value()) {
      if (error.empty()) {
        error = "preview selected video track disappeared";
      }
      impl_->retireActive();
      return NativePreviewFailure{expectedEpoch, std::move(error)};
    }
    if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
        expectedEpoch) {
      impl_->retireActive();
      return NativePreviewCancelled{expectedEpoch};
    }
    impl_->samplesRead.fetch_add(1, std::memory_order_relaxed);
    return std::move(*sample);
  } catch (const std::exception& exception) {
    impl_->currentStagedCompressedBytes.store(0,
                                              std::memory_order_release);
    impl_->stagedSampleBuffers.store(0, std::memory_order_release);
    impl_->retireActive();
    return NativePreviewFailure{expectedEpoch, exception.what()};
  } catch (...) {
    impl_->currentStagedCompressedBytes.store(0,
                                              std::memory_order_release);
    impl_->stagedSampleBuffers.store(0, std::memory_order_release);
    impl_->retireActive();
    return NativePreviewFailure{
        expectedEpoch, "preview read raised an unknown exception"};
  }
}

bool AVFoundationPreviewSource::advanceTarget(
    std::uint64_t expectedEpoch, MediaTime target) noexcept {
  if (impl_ == nullptr || expectedEpoch == 0 || !target.valid() ||
      target.value < 0 ||
      expectedEpoch != impl_->activeEpoch.load(std::memory_order_acquire) ||
      expectedEpoch != impl_->operationEpoch.load(std::memory_order_acquire) ||
      !impl_->open.load(std::memory_order_acquire) ||
      impl_->cancelledEpoch.load(std::memory_order_acquire) == expectedEpoch ||
      !withinDuration(target, impl_->binding.descriptor->duration)) {
    return false;
  }
  const auto order = media::compareMediaTime(impl_->target, target);
  if (!order.has_value() || *order == MediaTimeOrder::Greater) {
    return false;
  }
  impl_->target = target;
  impl_->publishTarget(target);
  impl_->forwardRetargets.fetch_add(1, std::memory_order_relaxed);
  return true;
}

void AVFoundationPreviewSource::requestCancel(
    std::uint64_t epoch) noexcept {
  if (impl_ == nullptr || epoch == 0 ||
      impl_->operationEpoch.load(std::memory_order_acquire) != epoch) {
    return;
  }
#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
  if (const auto hook = impl_->cancelInterleaveHook.load(
          std::memory_order_acquire)) {
    hook(epoch,
         impl_->cancelInterleaveContext.load(std::memory_order_acquire));
  }
#endif
  // Epochs are strictly increasing. Revalidate the public operation before
  // every publication attempt, let an exact newer cancellation replace a
  // stale smaller value, and never let a stale caller overwrite an already
  // published newer cancellation. This remains correct if a caller pauses
  // after its first operation check while begin() replaces the reader.
  std::uint64_t observed =
      impl_->cancelledEpoch.load(std::memory_order_acquire);
  for (;;) {
    if (impl_->operationEpoch.load(std::memory_order_acquire) != epoch ||
        observed > epoch) {
      return;
    }
    if (observed == epoch) {
      break;
    }
    if (impl_->cancelledEpoch.compare_exchange_weak(
            observed, epoch, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      break;
    }
  }
  auto active = std::atomic_load_explicit(&impl_->publishedGeneration,
                                          std::memory_order_acquire);
  if (active != nullptr && active->epoch() == epoch) {
    active->cancel();
  }
}

void AVFoundationPreviewSource::close() noexcept {
  if (impl_ == nullptr) {
    return;
  }
  try {
    impl_->retireActive();
    impl_->target = {};
    impl_->actualDecodeStart = {};
    impl_->publishTarget({});
    impl_->publishDecodeStart({});
    impl_->eos = false;
  } catch (...) {
  }
}

NativePreviewSourceFacts AVFoundationPreviewSource::facts()
    const noexcept {
  NativePreviewSourceFacts result;
  if (impl_ == nullptr) {
    return result;
  }
  result.operationEpoch =
      impl_->operationEpoch.load(std::memory_order_acquire);
  result.activeEpoch =
      impl_->activeEpoch.load(std::memory_order_acquire);
  result.epochHighWater =
      impl_->epochHighWater.load(std::memory_order_acquire);
  result.target.timescale =
      impl_->targetScale.load(std::memory_order_acquire);
  result.target.value = impl_->targetValue.load(std::memory_order_relaxed);
  result.actualDecodeStart.timescale =
      impl_->decodeStartScale.load(std::memory_order_acquire);
  result.actualDecodeStart.value =
      impl_->decodeStartValue.load(std::memory_order_relaxed);
  result.stagedSampleBuffers =
      impl_->stagedSampleBuffers.load(std::memory_order_acquire);
  result.peakStagedSampleBuffers =
      impl_->peakStagedSampleBuffers.load(std::memory_order_relaxed);
  result.samplesRead = impl_->samplesRead.load(std::memory_order_relaxed);
  result.discontinuitiesRead =
      impl_->discontinuitiesRead.load(std::memory_order_relaxed);
  result.forwardRetargets =
      impl_->forwardRetargets.load(std::memory_order_relaxed);
  result.open = impl_->open.load(std::memory_order_acquire);
  result.cancelled =
      result.activeEpoch != 0 &&
      impl_->cancelledEpoch.load(std::memory_order_acquire) ==
          result.activeEpoch;
  result.backend = impl_->backend->facts();
  return result;
}

NativePreviewSourceMemoryFacts
AVFoundationPreviewSource::memoryFacts() const noexcept {
  NativePreviewSourceMemoryFacts result;
  if (impl_ == nullptr) {
    return result;
  }
  result.stagedSamples =
      impl_->stagedSampleBuffers.load(std::memory_order_acquire);
  result.currentStagedCompressedBytes =
      impl_->currentStagedCompressedBytes.load(std::memory_order_acquire);
  result.peakStagedCompressedBytes =
      impl_->peakStagedCompressedBytes.load(std::memory_order_relaxed);
  return result;
}

#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
void AVFoundationPreviewSourceTestAccess::setCancelInterleaveHook(
    AVFoundationPreviewSource& source,
    AVFoundationPreviewCancelInterleaveHook hook,
    void* context) noexcept {
  if (source.impl_ == nullptr) {
    return;
  }
  source.impl_->cancelInterleaveContext.store(context,
                                               std::memory_order_release);
  source.impl_->cancelInterleaveHook.store(hook, std::memory_order_release);
}

AVFoundationPreviewSharedContextProbe
AVFoundationPreviewSourceTestAccess::probeSharedContext(
    NativePreviewBinding binding) noexcept {
  AVFoundationPreviewSharedContextProbe probe;
  try {
    const std::shared_ptr<const AVFoundationAssetContext> shared =
        std::dynamic_pointer_cast<const AVFoundationAssetContext>(
            binding.assetContext);
    if (shared == nullptr) {
      return probe;
    }
    ProductionAssetContext context(std::move(binding));
    probe.backendBefore = context.facts();
    probe.contextBefore = shared->facts();

    const std::atomic<bool> cancelled{false};
    std::string error;
    probe.sharedLoadReady = context.ensureLoaded(cancelled, &error);
    probe.backendAfterSharedLoad = context.facts();
    probe.contextAfterSharedLoad = shared->facts();
    if (!probe.sharedLoadReady) {
      return probe;
    }

    // First initialization fails before producing an AVAssetReader.
    context.readerCreationAttempt();
    probe.backendAfterCreationFailure = context.facts();
    probe.contextAfterCreationFailure = shared->facts();

    // A later initialization succeeds and the resulting reader starts.
    context.readerCreationAttempt();
    context.readerCreated();
    context.readerStarted();
    probe.backendAfterStartedReader = context.facts();
    probe.contextAfterStartedReader = shared->facts();
  } catch (...) {
  }
  return probe;
}
#endif

}  // namespace wam::macos
