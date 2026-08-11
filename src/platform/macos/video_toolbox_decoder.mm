#include "video_toolbox_decoder.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <condition_variable>
#include <exception>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

void assignError(std::string *error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

std::string statusError(const char *operation, OSStatus status) {
  return std::string(operation) + " failed with OSStatus " +
         std::to_string(status);
}

struct AsyncDecodeState {
  mutable std::mutex mutex;
  std::mutex deliveryMutex;
  std::condition_variable completion;
  DecodedFrameSink *sink{nullptr};
  std::uint64_t generation{0};
  std::size_t inFlight{0};
  std::uint64_t submitted{0};
  std::uint64_t delivered{0};
  std::uint64_t dropped{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t sinkBackpressureDrops{0};
  std::uint64_t presentationBackpressureDrops{0};
  std::uint64_t outOfOrderDrops{0};
  std::size_t maxPendingPresentationFrames{0};
  std::size_t peakPendingPresentationFrames{0};
  std::vector<FrameLease> pendingPresentationFrames;
  OSType actualOutputPixelFormat{0};
  CMTime maximumSeenPresentationTime{kCMTimeInvalid};
  CMTime safePresentationTime{kCMTimeInvalid};
  CMTime lastDeliveredPresentationTime{kCMTimeInvalid};
  bool discarding{false};
  std::optional<std::string> lastError;
};

void finishCallback(const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  std::lock_guard lock(state->mutex);
  if (state->inFlight > 0) {
    --state->inFlight;
  }
  state->completion.notify_all();
}

void recordAsyncError(const std::shared_ptr<AsyncDecodeState> &state,
                      std::string message) noexcept {
  std::lock_guard lock(state->mutex);
  state->lastError = std::move(message);
}

bool timeBefore(CMTime left, CMTime right) noexcept {
  return CMTIME_IS_VALID(left) && CMTIME_IS_VALID(right) &&
         CMTimeCompare(left, right) < 0;
}

bool timeAtOrBefore(CMTime left, CMTime right) noexcept {
  return CMTIME_IS_VALID(left) && CMTIME_IS_VALID(right) &&
         CMTimeCompare(left, right) <= 0;
}

void collectPresentableFramesLocked(AsyncDecodeState &state, bool drainAll,
                                    std::vector<FrameLease> &output) {
  while (!state.pendingPresentationFrames.empty()) {
    FrameLease &candidate = state.pendingPresentationFrames.front();
    if (!drainAll && !timeAtOrBefore(candidate.timing().presentationTime,
                                     state.safePresentationTime)) {
      break;
    }
    if (timeBefore(candidate.timing().presentationTime,
                   state.lastDeliveredPresentationTime)) {
      state.pendingPresentationFrames.erase(
          state.pendingPresentationFrames.begin());
      ++state.dropped;
      ++state.outOfOrderDrops;
      state.lastError =
          "VideoToolbox returned a frame older than the presentation floor";
      continue;
    }
    state.lastDeliveredPresentationTime = candidate.timing().presentationTime;
    output.push_back(std::move(candidate));
    state.pendingPresentationFrames.erase(
        state.pendingPresentationFrames.begin());
  }
}

void deliverBatch(const std::shared_ptr<AsyncDecodeState> &state,
                  DecodedFrameSink &sink,
                  std::vector<FrameLease> frames) noexcept {
  for (FrameLease &frame : frames) {
    try {
      std::string sinkError;
      const FrameEnqueueResult result =
          sink.enqueue(std::move(frame), &sinkError);
      std::lock_guard lock(state->mutex);
      if (result == FrameEnqueueResult::Accepted) {
        ++state->delivered;
      } else if (result == FrameEnqueueResult::Backpressure) {
        // Saturation is an expected bounded-memory outcome. Account for the
        // intentional drop without poisoning subsequent decoder submissions.
        ++state->dropped;
        ++state->sinkBackpressureDrops;
      } else {
        ++state->dropped;
        state->lastError =
            sinkError.empty()
                ? "decoded frame sink rejected a frame"
                : "decoded frame sink rejected a frame: " + sinkError;
      }
    } catch (const std::exception &exception) {
      recordAsyncError(state, std::string("decoded frame delivery threw: ") +
                                  exception.what());
      std::lock_guard lock(state->mutex);
      ++state->dropped;
    } catch (...) {
      recordAsyncError(state, "decoded frame delivery threw an unknown error");
      std::lock_guard lock(state->mutex);
      ++state->dropped;
    }
  }
}

void drainPresentationFrames(
    const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  std::lock_guard deliveryLock(state->deliveryMutex);
  DecodedFrameSink *sink = nullptr;
  std::vector<FrameLease> readyFrames;
  {
    std::lock_guard lock(state->mutex);
    sink = state->sink;
    collectPresentableFramesLocked(*state, true, readyFrames);
  }
  if (sink != nullptr && !readyFrames.empty()) {
    deliverBatch(state, *sink, std::move(readyFrames));
  }
}

void resetPresentationState(
    const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  std::vector<FrameLease> retiredFrames;
  {
    std::lock_guard deliveryLock(state->deliveryMutex);
    std::lock_guard lock(state->mutex);
    retiredFrames.swap(state->pendingPresentationFrames);
    state->maximumSeenPresentationTime = kCMTimeInvalid;
    state->safePresentationTime = kCMTimeInvalid;
    state->lastDeliveredPresentationTime = kCMTimeInvalid;
  }
  // Release decoder surfaces after leaving both pipeline locks.
}

void deliverDecodedFrame(const std::shared_ptr<AsyncDecodeState> &state,
                         FrameTiming timing, OSStatus status,
                         VTDecodeInfoFlags infoFlags,
                         CVImageBufferRef imageBuffer, CMTime presentationTime,
                         CMTime presentationDuration) noexcept {
  // Temporal processing lets VideoToolbox retain frames until its temporal work
  // is complete, but Apple's callback contract still does not guarantee display
  // order. Serialize the callback boundary and use returned PTS below so the
  // presentation sink is never called concurrently or with decreasing time.
  std::lock_guard deliveryLock(state->deliveryMutex);
  if (CMTIME_IS_VALID(presentationTime)) {
    timing.presentationTime = presentationTime;
  }
  if (CMTIME_IS_VALID(presentationDuration)) {
    timing.duration = presentationDuration;
  }

  DecodedFrameSink *sink = nullptr;
  std::vector<FrameLease> readyFrames;
  {
    std::lock_guard lock(state->mutex);
    if (status != noErr) {
      state->lastError = statusError("VideoToolbox output callback", status);
      ++state->dropped;
    } else if ((infoFlags & kVTDecodeInfo_FrameDropped) != 0 ||
               imageBuffer == nullptr) {
      ++state->dropped;
      if (imageBuffer == nullptr &&
          (infoFlags & kVTDecodeInfo_FrameDropped) == 0) {
        state->lastError =
            "VideoToolbox returned success without a decoded pixel buffer";
      }
    } else if (state->discarding || timing.generation != state->generation) {
      // A flush advances the generation before waiting for callbacks, so an
      // old frame is released here without ever reaching the new timeline.
      ++state->dropped;
    } else if (CVPixelBufferGetIOSurface(
                   static_cast<CVPixelBufferRef>(imageBuffer)) == nullptr) {
      state->lastError = "VideoToolbox produced a frame without an IOSurface";
      ++state->dropped;
    } else {
      const OSType pixelFormat = CVPixelBufferGetPixelFormatType(
          static_cast<CVPixelBufferRef>(imageBuffer));
      const bool supported =
          pixelFormat == kCVPixelFormatType_32BGRA ||
          pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
          pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
          pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
          pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
      if (!supported) {
        state->lastError =
            "VideoToolbox produced a pixel format unsupported by the Metal "
            "presenter: " +
            std::to_string(pixelFormat);
        ++state->dropped;
      } else if (!CMTIME_IS_VALID(timing.presentationTime)) {
        state->lastError =
            "VideoToolbox returned a decoded frame without a presentation "
            "timestamp";
        ++state->dropped;
      } else {
        state->actualOutputPixelFormat = pixelFormat;
        if (!CMTIME_IS_VALID(state->maximumSeenPresentationTime)) {
          state->maximumSeenPresentationTime = timing.presentationTime;
        } else if (timeBefore(state->maximumSeenPresentationTime,
                              timing.presentationTime)) {
          // A new presentation-time high-water mark closes the preceding
          // reorder interval. Frames through the old high-water mark can now
          // be emitted in sorted order; the new reference interval remains
          // buffered until the next mark or the explicit EOS drain.
          state->safePresentationTime = state->maximumSeenPresentationTime;
          state->maximumSeenPresentationTime = timing.presentationTime;
        }
        sink = state->sink;
        if (sink == nullptr) {
          state->lastError = "decoded frame has no configured output sink";
          ++state->dropped;
        } else {
          FrameLease frame(static_cast<CVPixelBufferRef>(imageBuffer), timing);
          auto insertion = std::upper_bound(
              state->pendingPresentationFrames.begin(),
              state->pendingPresentationFrames.end(), frame,
              [](const FrameLease &left, const FrameLease &right) {
                return timeBefore(left.timing().presentationTime,
                                  right.timing().presentationTime);
              });
          state->pendingPresentationFrames.insert(insertion, std::move(frame));
          state->peakPendingPresentationFrames =
              std::max(state->peakPendingPresentationFrames,
                       state->pendingPresentationFrames.size());
          collectPresentableFramesLocked(*state, false, readyFrames);
          if (state->pendingPresentationFrames.size() >
              state->maxPendingPresentationFrames) {
            // Preserve ordering and the oldest display work. Dropping the
            // farthest-future surface is cheaper and safer than unbounded
            // retention when a malformed/extreme GOP exceeds the contract.
            state->pendingPresentationFrames.pop_back();
            ++state->dropped;
            ++state->presentationBackpressureDrops;
          }
        }
      }
    }
  }

  if (sink != nullptr && !readyFrames.empty()) {
    deliverBatch(state, *sink, std::move(readyFrames));
  }

  finishCallback(state);
}

OSStatus createFormatDescription(const VideoStreamConfiguration &configuration,
                                 CMVideoFormatDescriptionRef *descriptionOut) {
  if (descriptionOut == nullptr) {
    return paramErr;
  }
  *descriptionOut = nullptr;

  const CFStringRef atomName =
      configuration.codec == kCMVideoCodecType_H264   ? CFSTR("avcC")
      : configuration.codec == kCMVideoCodecType_HEVC ? CFSTR("hvcC")
                                                      : nullptr;
  if (atomName == nullptr || configuration.codecConfiguration.empty() ||
      configuration.codecConfiguration.size() >
          static_cast<std::size_t>(std::numeric_limits<CFIndex>::max())) {
    return paramErr;
  }

  CFDataRef atomData = CFDataCreate(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8 *>(configuration.codecConfiguration.data()),
      static_cast<CFIndex>(configuration.codecConfiguration.size()));
  if (atomData == nullptr) {
    return memFullErr;
  }

  const void *atomKeys[] = {atomName};
  const void *atomValues[] = {atomData};
  CFDictionaryRef atoms = CFDictionaryCreate(
      kCFAllocatorDefault, atomKeys, atomValues, 1,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  const void *extensionKeys[] = {
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms};
  const void *extensionValues[] = {atoms};
  CFDictionaryRef extensions =
      atoms == nullptr ? nullptr
                       : CFDictionaryCreate(kCFAllocatorDefault, extensionKeys,
                                            extensionValues, 1,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);

  OSStatus status = memFullErr;
  if (extensions != nullptr) {
    status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, configuration.codec, configuration.codedSize.width,
        configuration.codedSize.height, extensions, descriptionOut);
  }
  if (extensions != nullptr) {
    CFRelease(extensions);
  }
  if (atoms != nullptr) {
    CFRelease(atoms);
  }
  CFRelease(atomData);
  return status;
}

OSType
requestedPixelFormat(const VideoStreamConfiguration &configuration) noexcept {
  // hvcC stores bit_depth_luma_minus8 in the low three bits of byte 17.
  // The common H.264 High 10 profile uses profile_idc 110. Both map directly
  // to the presenter's supported 10-bit bi-planar Metal import path.
  const auto *bytes = reinterpret_cast<const std::uint8_t *>(
      configuration.codecConfiguration.data());
  bool tenBit = false;
  if (configuration.codec == kCMVideoCodecType_HEVC &&
      configuration.codecConfiguration.size() > 17) {
    tenBit = (bytes[17] & 0x07U) > 0;
  } else if (configuration.codec == kCMVideoCodecType_H264 &&
             configuration.codecConfiguration.size() > 1) {
    tenBit = bytes[1] == 110;
  }
  return tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

OSStatus
createCompressedSampleBuffer(CMVideoFormatDescriptionRef formatDescription,
                             const CompressedVideoPacket &packet,
                             CMSampleBufferRef *sampleOut) {
  if (sampleOut == nullptr || formatDescription == nullptr ||
      packet.bytes.empty()) {
    return paramErr;
  }
  *sampleOut = nullptr;

  CMBlockBufferRef block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, packet.bytes.size(), kCFAllocatorDefault,
      nullptr, 0, packet.bytes.size(), 0, &block);
  if (status != noErr || block == nullptr) {
    return status == noErr ? memFullErr : status;
  }
  status = CMBlockBufferReplaceDataBytes(packet.bytes.data(), block, 0,
                                         packet.bytes.size());
  if (status != noErr) {
    CFRelease(block);
    return status;
  }

  const CMSampleTimingInfo timing{packet.duration, packet.presentationTime,
                                  packet.decodeTime};
  const std::size_t sampleSize = packet.bytes.size();
  status =
      CMSampleBufferCreateReady(kCFAllocatorDefault, block, formatDescription,
                                1, 1, &timing, 1, &sampleSize, sampleOut);
  CFRelease(block);
  if (status != noErr || *sampleOut == nullptr) {
    return status == noErr ? memFullErr : status;
  }

  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(*sampleOut, true);
  if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
    auto *attachment = static_cast<CFMutableDictionaryRef>(
        const_cast<void *>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync,
                         packet.keyFrame ? kCFBooleanFalse : kCFBooleanTrue);
    if (packet.keyFrame) {
      CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers,
                           kCFBooleanFalse);
    }
  }
  return noErr;
}

} // namespace

struct VideoToolboxDecoder::Impl {
  explicit Impl(VideoToolboxDecoderOptions decoderOptions)
      : options(decoderOptions), async(std::make_shared<AsyncDecodeState>()) {}

  VideoToolboxDecoderOptions options;
  mutable std::mutex operationMutex;
  std::shared_ptr<AsyncDecodeState> async;
  CMVideoFormatDescriptionRef formatDescription{nullptr};
  VTDecompressionSessionRef session{nullptr};
  bool configured{false};
  bool ended{false};
  bool awaitingKeyFrame{true};
  bool usingHardware{false};
  bool preferHardware{true};
  bool requireHardware{false};
  OSType outputPixelFormat{0};

  ~Impl() {
    if (session != nullptr) {
      VTDecompressionSessionInvalidate(session);
      CFRelease(session);
    }
    if (formatDescription != nullptr) {
      CFRelease(formatDescription);
    }
  }

  bool createSessionLocked(std::string *error) {
    if (session != nullptr) {
      return true;
    }
    if (formatDescription == nullptr) {
      assignError(error, "decoder has no video format description");
      return false;
    }

    CFMutableDictionaryRef decoderSpecification = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (preferHardware || requireHardware) {
      CFDictionarySetValue(
          decoderSpecification,
          kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,
          kCFBooleanTrue);
    }
    if (requireHardware) {
      CFDictionarySetValue(
          decoderSpecification,
          kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder,
          kCFBooleanTrue);
    }

    CFDictionaryRef emptyIOSurfaceProperties = CFDictionaryCreate(
        kCFAllocatorDefault, nullptr, nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef imageAttributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(imageAttributes, kCVPixelBufferIOSurfacePropertiesKey,
                         emptyIOSurfaceProperties);
    CFDictionarySetValue(imageAttributes, kCVPixelBufferMetalCompatibilityKey,
                         kCFBooleanTrue);
    const std::int32_t pixelFormatValue =
        static_cast<std::int32_t>(outputPixelFormat);
    CFNumberRef pixelFormatNumber = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormatValue);
    if (pixelFormatNumber == nullptr) {
      CFRelease(imageAttributes);
      CFRelease(emptyIOSurfaceProperties);
      CFRelease(decoderSpecification);
      assignError(error, "could not allocate the output pixel-format request");
      return false;
    }
    CFDictionarySetValue(imageAttributes, kCVPixelBufferPixelFormatTypeKey,
                         pixelFormatNumber);

    const OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault, formatDescription, decoderSpecification,
        imageAttributes, nullptr, &session);
    CFRelease(pixelFormatNumber);
    CFRelease(imageAttributes);
    CFRelease(emptyIOSurfaceProperties);
    CFRelease(decoderSpecification);
    if (status != noErr || session == nullptr) {
      session = nullptr;
      assignError(error, statusError("VTDecompressionSessionCreate", status));
      return false;
    }

    CFTypeRef hardwareProperty = nullptr;
    const OSStatus propertyStatus = VTSessionCopyProperty(
        session,
        kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        kCFAllocatorDefault, &hardwareProperty);
    usingHardware =
        propertyStatus == noErr && hardwareProperty != nullptr &&
        CFGetTypeID(hardwareProperty) == CFBooleanGetTypeID() &&
        CFBooleanGetValue(static_cast<CFBooleanRef>(hardwareProperty));
    if (hardwareProperty != nullptr) {
      CFRelease(hardwareProperty);
    }
    if (requireHardware && !usingHardware) {
      VTDecompressionSessionInvalidate(session);
      CFRelease(session);
      session = nullptr;
      assignError(error,
                  "VideoToolbox did not create a required hardware decoder");
      return false;
    }
    return true;
  }

  void waitAndInvalidateSessionLocked() noexcept {
    if (session == nullptr) {
      return;
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session);
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    session = nullptr;
    usingHardware = false;

    std::unique_lock lock(async->mutex);
    async->completion.wait(lock, [this] { return async->inFlight == 0; });
  }

  std::optional<std::string> takeAsyncErrorLocked() {
    std::lock_guard lock(async->mutex);
    std::optional<std::string> result = std::move(async->lastError);
    async->lastError.reset();
    return result;
  }
};

VideoToolboxDecoder::VideoToolboxDecoder(VideoToolboxDecoderOptions options)
    : impl_(std::make_unique<Impl>(options)) {
  if (options.maxInFlightFrames == 0) {
    throw std::invalid_argument(
        "VideoToolbox decoder in-flight bound must be greater than zero");
  }
  if (options.maxPendingPresentationFrames == 0) {
    throw std::invalid_argument(
        "VideoToolbox presentation reorder bound must be greater than zero");
  }
}

VideoToolboxDecoder::~VideoToolboxDecoder() { close(); }

bool VideoToolboxDecoder::configure(
    const VideoStreamConfiguration &configuration, DecodedFrameSink &sink,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if ((configuration.codec != kCMVideoCodecType_H264 &&
       configuration.codec != kCMVideoCodecType_HEVC) ||
      configuration.codedSize.width <= 0 ||
      configuration.codedSize.height <= 0 ||
      configuration.codecConfiguration.empty()) {
    assignError(error,
                "VideoToolbox requires H.264/HEVC, positive dimensions, and "
                "an avcC/hvcC configuration atom");
    return false;
  }

  std::lock_guard operationLock(impl_->operationMutex);

  // Retire an earlier configuration before exposing the new sink/generation.
  if (impl_->configured) {
    DecodedFrameSink *oldSink = nullptr;
    {
      std::lock_guard stateLock(impl_->async->mutex);
      impl_->async->discarding = true;
      ++impl_->async->generation;
      oldSink = impl_->async->sink;
    }
    impl_->waitAndInvalidateSessionLocked();
    resetPresentationState(impl_->async);
    if (oldSink != nullptr) {
      oldSink->flush(impl_->async->generation);
    }
  }
  impl_->configured = false;
  impl_->ended = false;
  impl_->awaitingKeyFrame = true;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = nullptr;
    impl_->async->discarding = true;
  }
  if (impl_->formatDescription != nullptr) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
  }

  const OSStatus descriptionStatus =
      createFormatDescription(configuration, &impl_->formatDescription);
  if (descriptionStatus != noErr || impl_->formatDescription == nullptr) {
    assignError(error, statusError("CMVideoFormatDescriptionCreate",
                                   descriptionStatus));
    return false;
  }

  impl_->preferHardware = configuration.preferHardwareDecode;
  impl_->requireHardware = configuration.requireHardwareDecode;
  impl_->outputPixelFormat = requestedPixelFormat(configuration);
  impl_->ended = false;
  impl_->awaitingKeyFrame = true;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = &sink;
    impl_->async->generation = configuration.generation;
    impl_->async->discarding = false;
    impl_->async->inFlight = 0;
    impl_->async->submitted = 0;
    impl_->async->delivered = 0;
    impl_->async->dropped = 0;
    impl_->async->backpressuredSubmissions = 0;
    impl_->async->sinkBackpressureDrops = 0;
    impl_->async->presentationBackpressureDrops = 0;
    impl_->async->outOfOrderDrops = 0;
    impl_->async->maxPendingPresentationFrames =
        impl_->options.maxPendingPresentationFrames;
    impl_->async->peakPendingPresentationFrames = 0;
    impl_->async->pendingPresentationFrames.clear();
    impl_->async->actualOutputPixelFormat = 0;
    impl_->async->maximumSeenPresentationTime = kCMTimeInvalid;
    impl_->async->safePresentationTime = kCMTimeInvalid;
    impl_->async->lastDeliveredPresentationTime = kCMTimeInvalid;
    impl_->async->lastError.reset();
  }
  sink.flush(configuration.generation);

  if (!impl_->createSessionLocked(error)) {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = nullptr;
    impl_->async->discarding = true;
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    return false;
  }
  impl_->configured = true;
  return true;
}

VideoDecodeSubmitResult
VideoToolboxDecoder::submit(const CompressedVideoPacket &packet,
                            std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (!impl_->configured) {
    assignError(error, "VideoToolbox decoder is not configured");
    return VideoDecodeSubmitResult::Rejected;
  }

  std::uint64_t generation = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    generation = impl_->async->generation;
  }
  if (packet.generation != generation) {
    assignError(error, "compressed packet belongs to a stale generation");
    return VideoDecodeSubmitResult::Rejected;
  }

  if (packet.endOfStream) {
    if (impl_->ended) {
      assignError(error, "end of stream was already submitted");
      return VideoDecodeSubmitResult::Rejected;
    }
    OSStatus finishStatus = noErr;
    OSStatus waitStatus = noErr;
    if (impl_->session != nullptr) {
      // Temporal processing is allowed to retain reordered B frames until this
      // explicit drain. Waiting alone does not request those delayed frames.
      finishStatus = VTDecompressionSessionFinishDelayedFrames(impl_->session);
      waitStatus =
          VTDecompressionSessionWaitForAsynchronousFrames(impl_->session);
    }
    drainPresentationFrames(impl_->async);
    impl_->ended = true;
    DecodedFrameSink *sink = nullptr;
    {
      std::lock_guard stateLock(impl_->async->mutex);
      sink = impl_->async->sink;
    }
    if (sink != nullptr) {
      sink->endOfStream(generation);
    }
    if (finishStatus != noErr) {
      assignError(error,
                  statusError("VTDecompressionSessionFinishDelayedFrames",
                              finishStatus));
      return VideoDecodeSubmitResult::Rejected;
    }
    if (waitStatus != noErr) {
      assignError(error,
                  statusError("VTDecompressionSessionWaitForAsynchronousFrames",
                              waitStatus));
      return VideoDecodeSubmitResult::Rejected;
    }
    if (auto asyncError = impl_->takeAsyncErrorLocked()) {
      assignError(error, std::move(*asyncError));
      return VideoDecodeSubmitResult::Rejected;
    }
    return VideoDecodeSubmitResult::Accepted;
  }

  if (impl_->ended) {
    assignError(error, "cannot submit compressed data after end of stream");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (packet.bytes.empty()) {
    assignError(error, "compressed video packet is empty");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl_->awaitingKeyFrame && !packet.keyFrame) {
    assignError(error, "decoder requires a key frame after configure or flush");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (auto asyncError = impl_->takeAsyncErrorLocked()) {
    assignError(error, std::move(*asyncError));
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!impl_->createSessionLocked(error)) {
    return VideoDecodeSubmitResult::Rejected;
  }

  // Reserve bounded decode capacity before allocating or copying compressed
  // packet storage. Backpressure therefore has constant cost and never grows
  // memory just to discover that the pipeline is already saturated.
  {
    std::lock_guard stateLock(impl_->async->mutex);
    if (impl_->async->inFlight >= impl_->options.maxInFlightFrames) {
      ++impl_->async->backpressuredSubmissions;
      return VideoDecodeSubmitResult::Backpressure;
    }
    ++impl_->async->inFlight;
  }

  CMSampleBufferRef sample = nullptr;
  const OSStatus sampleStatus =
      createCompressedSampleBuffer(impl_->formatDescription, packet, &sample);
  if (sampleStatus != noErr || sample == nullptr) {
    finishCallback(impl_->async);
    assignError(error, statusError("CMSampleBufferCreateReady", sampleStatus));
    return VideoDecodeSubmitResult::Rejected;
  }

  const FrameTiming timing{packet.presentationTime, packet.duration,
                           packet.generation, packet.keyFrame};
  const std::shared_ptr<AsyncDecodeState> callbackState = impl_->async;
  VTDecodeInfoFlags infoFlags = 0;
  const OSStatus decodeStatus =
      VTDecompressionSessionDecodeFrameWithOutputHandler(
          impl_->session, sample,
          kVTDecodeFrame_EnableAsynchronousDecompression |
              kVTDecodeFrame_EnableTemporalProcessing,
          &infoFlags,
          ^(OSStatus status, VTDecodeInfoFlags callbackFlags,
            CVImageBufferRef imageBuffer, CMTime presentationTime,
            CMTime presentationDuration) {
            deliverDecodedFrame(callbackState, timing, status, callbackFlags,
                                imageBuffer, presentationTime,
                                presentationDuration);
          });
  CFRelease(sample);
  if (decodeStatus != noErr) {
    finishCallback(callbackState);
    assignError(error,
                statusError("VTDecompressionSessionDecodeFrame", decodeStatus));
    return VideoDecodeSubmitResult::Rejected;
  }
  {
    std::lock_guard stateLock(impl_->async->mutex);
    ++impl_->async->submitted;
  }
  impl_->awaitingKeyFrame = false;
  return VideoDecodeSubmitResult::Accepted;
}

void VideoToolboxDecoder::flush(std::uint64_t nextGeneration) noexcept {
  std::lock_guard operationLock(impl_->operationMutex);
  DecodedFrameSink *sink = nullptr;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->generation = nextGeneration;
    impl_->async->discarding = true;
    impl_->async->lastError.reset();
    sink = impl_->async->sink;
  }
  impl_->waitAndInvalidateSessionLocked();
  resetPresentationState(impl_->async);
  if (sink != nullptr) {
    sink->flush(nextGeneration);
  }
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->discarding = !impl_->configured;
  }
  impl_->ended = false;
  impl_->awaitingKeyFrame = true;
}

void VideoToolboxDecoder::close() noexcept {
  if (!impl_) {
    return;
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (!impl_->configured && impl_->session == nullptr &&
      impl_->formatDescription == nullptr) {
    return;
  }

  DecodedFrameSink *sink = nullptr;
  std::uint64_t retiredGeneration = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    retiredGeneration = impl_->async->generation + 1;
    impl_->async->generation = retiredGeneration;
    impl_->async->discarding = true;
    sink = impl_->async->sink;
  }
  impl_->waitAndInvalidateSessionLocked();
  resetPresentationState(impl_->async);
  if (sink != nullptr) {
    sink->flush(retiredGeneration);
  }
  if (impl_->formatDescription != nullptr) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
  }
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = nullptr;
  }
  impl_->configured = false;
  impl_->ended = false;
  impl_->awaitingKeyFrame = true;
  impl_->usingHardware = false;
}

VideoToolboxDecoderStats VideoToolboxDecoder::stats() const noexcept {
  std::lock_guard operationLock(impl_->operationMutex);
  VideoToolboxDecoderStats result;
  result.configured = impl_->configured;
  result.usingHardwareAcceleratedDecoder = impl_->usingHardware;
  result.awaitingKeyFrame = impl_->awaitingKeyFrame;
  result.maxInFlightFrames = impl_->options.maxInFlightFrames;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    result.inFlightFrames = impl_->async->inFlight;
    result.generation = impl_->async->generation;
    result.submittedFrames = impl_->async->submitted;
    result.deliveredFrames = impl_->async->delivered;
    result.droppedFrames = impl_->async->dropped;
    result.backpressuredSubmissions = impl_->async->backpressuredSubmissions;
    result.sinkBackpressureDrops = impl_->async->sinkBackpressureDrops;
    result.presentationBackpressureDrops =
        impl_->async->presentationBackpressureDrops;
    result.outOfOrderDrops = impl_->async->outOfOrderDrops;
    result.pendingPresentationFrames =
        impl_->async->pendingPresentationFrames.size();
    result.peakPendingPresentationFrames =
        impl_->async->peakPendingPresentationFrames;
    result.requestedOutputPixelFormat = impl_->outputPixelFormat;
    result.actualOutputPixelFormat = impl_->async->actualOutputPixelFormat;
  }
  return result;
}

std::optional<std::string> VideoToolboxDecoder::takeLastError() {
  return impl_->takeAsyncErrorLocked();
}

} // namespace wam::macos
