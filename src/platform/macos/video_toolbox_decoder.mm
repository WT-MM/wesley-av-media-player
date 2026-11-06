#include "media/native_late_frame_trace.hpp"
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
#include <mach/mach_time.h>
#endif
#include "video_toolbox_decoder.hpp"

#include "media/media_codec_facts.hpp"
#include "media/video_codec_configuration.hpp"
#include "core_media_codec_facts.hpp"
#include "native_video_codec_capability.hpp"
#include "native_video_color.hpp"
#include "native_video_limits.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <condition_variable>
#include <exception>
#include <initializer_list>
#include <limits>
#include <mutex>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

constexpr std::size_t kAsyncErrorCapacity = 384;

constexpr VTDecodeFrameFlags
finiteAdmissionDecodeFlags(bool enableAsynchronousDecompression) noexcept {
  return enableAsynchronousDecompression
             ? kVTDecodeFrame_EnableAsynchronousDecompression
             : VTDecodeFrameFlags{0};
}

constexpr VTDecodeFrameFlags kProductionDecodeFrameFlags =
    finiteAdmissionDecodeFlags(true);
static_assert((kProductionDecodeFrameFlags &
               kVTDecodeFrame_EnableAsynchronousDecompression) != 0);
static_assert((kProductionDecodeFrameFlags &
               kVTDecodeFrame_EnableTemporalProcessing) == 0,
              "finite decoder admission cannot use temporal processing");

#if defined(WAM_NATIVE_VIDEO_TESTING)
thread_local std::optional<VideoToolboxDecoderTestCFAllocationPoint>
    gFailNextCFAllocationPoint;

bool consumeCFAllocationFailure(
    VideoToolboxDecoderTestCFAllocationPoint point) noexcept {
  if (gFailNextCFAllocationPoint != point) {
    return false;
  }
  gFailNextCFAllocationPoint.reset();
  return true;
}
#endif

void assignError(std::string *error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

std::string statusError(const char *operation, OSStatus status) {
  return std::string(operation) + " failed with OSStatus " +
         std::to_string(status);
}

// Every per-codec question about a configuration record (reorder depth, coded
// depth, chroma) is answered by the neutral parser, so no record reader lives
// here. Colour is admitted at its widest: it is the source's question, settled
// before any stream reaches this decoder under limits at least this strict.
[[nodiscard]] media::VideoCodecConfigurationLimits
recordLimits() noexcept {
  media::VideoCodecConfigurationLimits limits;
  limits.admitHighDynamicRangeColor = true;
  limits.admitHardwareH264Profiles = true;
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  limits.admitSoftwareProfiles = true;
#endif
  return limits;
}

[[nodiscard]] constexpr bool
recordParsed(media::MediaCodecConfigurationKind kind) noexcept {
  return kind == media::MediaCodecConfigurationKind::AvcC ||
         kind == media::MediaCodecConfigurationKind::HvcC ||
         kind == media::MediaCodecConfigurationKind::Av1C ||
         kind == media::MediaCodecConfigurationKind::VpcC;
}

// The parsed record of an AVC, HEVC, AV1 or VP9 stream; empty for a codec
// without one of those records or for a record the parser refuses.
[[nodiscard]] std::optional<media::VideoCodecConfigurationFacts>
parsedRecordFacts(const VideoStreamConfiguration &configuration) noexcept {
  const media::MediaCodec codec = media::mediaCodecForCoreMediaType(
      static_cast<std::uint32_t>(configuration.codec));
  const auto kind = media::mediaCodecFacts(codec).configurationKind;
  if (codec == media::MediaCodec::Vp8 || !recordParsed(kind)) {
    return std::nullopt;
  }
  auto inspection = media::inspectVideoCodecConfiguration(
      codec, kind, configuration.codecConfiguration, recordLimits());
  if (!inspection.admitted()) {
    return std::nullopt;
  }
  return inspection.facts;
}

// AVC and HEVC depths come with the parser's authority (stated or inferred).
// AV1's is the av1C initial presentation delay, deliberately NOT rounded up
// "to be safe": the ordered drain holds delivery until more than this many
// frames are retained, so every extra unit is a frame of added latency and one
// more retained IOSurface, and a value above maxPendingPresentationFrames
// hard-fails configure() as the intended clean fallback. Every other codec's
// depth is intrinsic (the facts table). VP8 never reaches VideoToolbox.
std::optional<CodecReorderDepth>
deriveCodecReorderDepth(const VideoStreamConfiguration &configuration) {
  const media::MediaCodec codec = media::mediaCodecForCoreMediaType(
      static_cast<std::uint32_t>(configuration.codec));
  const media::MediaCodecFacts &facts = media::mediaCodecFacts(codec);
  if (facts.kind != media::MediaCodecKind::Video ||
      codec == media::MediaCodec::Vp8) {
    return std::nullopt;
  }
  if (const auto parsed = parsedRecordFacts(configuration)) {
    return CodecReorderDepth{parsed->maximumReorderFrames,
                             parsed->maximumReorderFramesInferred
                                 ? CodecReorderDepthOrigin::Inferred
                                 : CodecReorderDepthOrigin::Declared};
  }
  // A parsed-record codec whose record was refused, a codec with no record
  // that presents one, or one with a record that presents none.
  if (recordParsed(facts.configurationKind) ||
      configuration.codecConfiguration.empty() ==
          facts.carriesConfigurationRecord) {
    return std::nullopt;
  }
  return CodecReorderDepth{facts.intrinsicReorderDepth,
                           CodecReorderDepthOrigin::Declared};
}

struct AsyncDecodeState {
  enum class FrameRefConSlotState : std::uint8_t {
    Available,
    Reserved,
    Submitted,
    CallbackComplete,
  };

  struct FrameRefConSlot {
    FrameRefConSlotState state{FrameRefConSlotState::Available};
    std::uint64_t submissionSequence{0};
    FrameTiming timing{};
    std::uint64_t compressedBytes{0};
    bool directCompressedStorage{false};
  };

  explicit AsyncDecodeState(
      VideoToolboxDecoderProgressHandler progress,
      std::size_t maxInFlightFrames)
      : frameRefConSlots(maxInFlightFrames), progressHandler(progress) {}

  struct CompletedDecode {
    std::uint64_t submissionSequence{0};
    std::optional<FrameLease> frame;
    FrameRefConSlot *slot{nullptr};
  };

  struct AsyncError {
    std::array<char, kAsyncErrorCapacity> bytes{};
    std::size_t size{0};

    void assign(std::string_view message) noexcept {
      size = std::min(message.size(), bytes.size());
      if (size != 0) {
        std::memcpy(bytes.data(), message.data(), size);
      }
    }

    void reset() noexcept { size = 0; }

    [[nodiscard]] bool present() const noexcept { return size != 0; }
  };

  mutable std::mutex mutex;
  std::mutex deliveryMutex;
  std::condition_variable completion;
  DecodedFrameSink *sink{nullptr};
  std::uint64_t generation{0};
  std::size_t inFlight{0};
  // Counts callbacks that have entered the persistent C trampoline but have
  // not returned. Teardown waits for this tail independently of ordered
  // in-flight retirement, whose credit may reach zero before notifyProgress.
  std::size_t activeCallbacks{0};
  std::uint64_t submitted{0};
  std::uint64_t directSampleBufferSubmissions{0};
  std::uint64_t directSampleBufferBytes{0};
  std::uint64_t copiedSpanSubmissions{0};
  std::uint64_t copiedSpanBytes{0};
  std::uint64_t currentDirectCompressedBytes{0};
  std::uint64_t peakDirectCompressedBytes{0};
  std::uint64_t currentCopiedCompressedBytes{0};
  std::uint64_t peakCopiedCompressedBytes{0};
  std::uint64_t currentCompressedBytes{0};
  std::uint64_t peakCompressedBytes{0};
  std::uint64_t delivered{0};
  std::uint64_t dropped{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t sinkBackpressureRetries{0};
  std::uint64_t endOfStreamBackpressureRetries{0};
  std::uint64_t surfaceBudgetRejections{0};
  std::uint64_t outOfOrderDrops{0};
  std::size_t codecReorderFrames{0};
  std::size_t maxRetainedFrames{0};
  std::size_t peakPendingPresentationFrames{0};
  std::uint64_t nextSubmissionSequence{0};
  std::uint64_t nextCompletionSequence{0};
  // Stable storage passed to VideoToolbox as sourceFrameRefCon. A slot is not
  // reusable merely because its callback arrived out of order: it returns to
  // Available in the same transaction that retires its ordered in-flight
  // credit. The vector is sized once at decoder construction and never
  // resized, so every pointer remains valid for the decoder lifetime.
  std::vector<FrameRefConSlot> frameRefConSlots;
  std::vector<CompletedDecode> completedDecodes;
  std::vector<FrameLease> pendingPresentationFrames;
  VideoToolboxOutputInterop outputInterop{VideoToolboxOutputInterop::Metal};
  OSType expectedOutputPixelFormat{0};
  OSType actualOutputPixelFormat{0};
  CMVideoDimensions expectedCodedDimensions{0, 0};
  CMTime lastDeliveredPresentationTime{kCMTimeInvalid};
  bool discarding{false};
  bool callbackFailedClosed{false};
  AsyncError lastError;
  const VideoToolboxDecoderProgressHandler progressHandler;
#if defined(WAM_NATIVE_VIDEO_TESTING)
  std::optional<VideoToolboxDecoderTestAllocationPoint>
      failNextAllocationPoint;
  bool permitSyntheticCallbackFrame{false};
  bool permitSyntheticOutputSurface{false};
#endif
};

void assignAsyncErrorLocked(AsyncDecodeState &state,
                            std::string_view message) noexcept {
  state.lastError.assign(message);
}

void incrementSaturated(std::uint64_t &value) noexcept {
  if (value != std::numeric_limits<std::uint64_t>::max()) {
    ++value;
  }
}

[[nodiscard]] std::uint64_t saturatedAdd(std::uint64_t left,
                                         std::uint64_t right) noexcept {
  return right > std::numeric_limits<std::uint64_t>::max() - left
             ? std::numeric_limits<std::uint64_t>::max()
             : left + right;
}

// The one admission bound: decode credit, retained presentation frames, and
// the two together against the retained ceiling.
[[nodiscard]] bool admissionSaturatedLocked(const AsyncDecodeState &state,
                                            std::size_t maxInFlight) noexcept {
  const std::size_t retained = state.pendingPresentationFrames.size();
  return state.inFlight >= maxInFlight ||
         retained >= state.maxRetainedFrames ||
         state.inFlight >= state.maxRetainedFrames - retained;
}

void updatePeak(std::uint64_t &peak, std::uint64_t current) noexcept {
  peak = std::max(peak, current);
}

void retireCompressedChargeLocked(
    AsyncDecodeState &state,
    AsyncDecodeState::FrameRefConSlot &slot) noexcept {
  const std::uint64_t bytes = slot.compressedBytes;
  if (slot.directCompressedStorage) {
    state.currentDirectCompressedBytes =
        state.currentDirectCompressedBytes >= bytes
            ? state.currentDirectCompressedBytes - bytes
            : 0;
  } else {
    state.currentCopiedCompressedBytes =
        state.currentCopiedCompressedBytes >= bytes
            ? state.currentCopiedCompressedBytes - bytes
            : 0;
  }
  state.currentCompressedBytes = state.currentCompressedBytes >= bytes
                                     ? state.currentCompressedBytes - bytes
                                     : 0;
  slot.compressedBytes = 0;
  slot.directCompressedStorage = false;
}

void notifyProgress(const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  const VideoToolboxDecoderProgressHandler handler = state->progressHandler;
  if (handler.function != nullptr) {
    handler.function(handler.context);
  }
}

void releaseReservedDecodeCapacity(
    const std::shared_ptr<AsyncDecodeState> &state,
    AsyncDecodeState::FrameRefConSlot *slot) {
  std::lock_guard lock(state->mutex);
  if (slot == nullptr ||
      slot->state != AsyncDecodeState::FrameRefConSlotState::Reserved ||
      state->inFlight == 0) {
    assignAsyncErrorLocked(
        *state, "VideoToolbox reserved decode capacity is inconsistent");
    return;
  }
  *slot = {};
  --state->inFlight;
  state->completion.notify_all();
}

void recordAsyncError(const std::shared_ptr<AsyncDecodeState> &state,
                      std::string_view message) noexcept {
  // This function is used by catch handlers on a foreign Apple callback. It
  // must remain allocation-free, and even a pathological mutex failure must
  // not escape through the C/Objective-C callback boundary.
  try {
    std::lock_guard lock(state->mutex);
    assignAsyncErrorLocked(*state, message);
  } catch (...) {
  }
}

#if defined(WAM_NATIVE_VIDEO_TESTING)
void maybeFailCallbackAllocationLocked(
    AsyncDecodeState &state,
    VideoToolboxDecoderTestAllocationPoint point) {
  if (state.failNextAllocationPoint == point) {
    state.failNextAllocationPoint.reset();
    throw std::bad_alloc();
  }
}
#endif

bool timeBefore(CMTime left, CMTime right) noexcept {
  return CMTIME_IS_NUMERIC(left) && CMTIME_IS_NUMERIC(right) &&
         CMTimeCompare(left, right) < 0;
}

void collectCompletedDecodesLocked(AsyncDecodeState &state) {
  while (!state.completedDecodes.empty() &&
         state.completedDecodes.front().submissionSequence ==
             state.nextCompletionSequence) {
    AsyncDecodeState::CompletedDecode completed =
        std::move(state.completedDecodes.front());
    state.completedDecodes.erase(state.completedDecodes.begin());
    if (completed.slot != nullptr) {
      if (completed.slot->state !=
          AsyncDecodeState::FrameRefConSlotState::CallbackComplete) {
        state.callbackFailedClosed = true;
        state.discarding = true;
        assignAsyncErrorLocked(
            state, "VideoToolbox frame-refcon slot retired out of state");
      }
      completed.slot->state =
          AsyncDecodeState::FrameRefConSlotState::Available;
      retireCompressedChargeLocked(state, *completed.slot);
      completed.slot->submissionSequence = 0;
      completed.slot->timing = {};
    }
    if (state.inFlight == 0) {
      state.callbackFailedClosed = true;
      state.discarding = true;
      assignAsyncErrorLocked(
          state, "VideoToolbox ordered completion lost its admission credit");
    } else {
      --state.inFlight;
    }
    // Slot availability, its compressed-byte refund, and the matching
    // admission-credit refund are one state-mutex transaction. In particular,
    // a memoryFacts() snapshot can never observe an Available slot whose
    // in-flight credit is still live (or count the same completion as both
    // in-flight and presentation-owned).
    state.completion.notify_all();
    ++state.nextCompletionSequence;

    if (!completed.frame) {
      continue;
    }
    if (timeBefore(completed.frame->timing().presentationTime,
                   state.lastDeliveredPresentationTime)) {
      incrementSaturated(state.dropped);
      incrementSaturated(state.outOfOrderDrops);
      assignAsyncErrorLocked(
          state,
          "decoded stream exceeded its admitted presentation-reorder depth");
      continue;
    }
    if (state.pendingPresentationFrames.size() >= state.maxRetainedFrames) {
      // This is unreachable when reserveDecodeCapacityLocked() and the
      // submission-order credits agree. Fail closed rather than permit a
      // callback-owned vector allocation beyond its reserved ceiling.
      completed.frame.reset();
      state.callbackFailedClosed = true;
      state.discarding = true;
      incrementSaturated(state.dropped);
      assignAsyncErrorLocked(
          state, "decoded-frame retention exceeded its bounded admission");
      continue;
    }
    auto insertion = std::upper_bound(
        state.pendingPresentationFrames.begin(),
        state.pendingPresentationFrames.end(), *completed.frame,
        [](const FrameLease &left, const FrameLease &right) {
          return timeBefore(left.timing().presentationTime,
                            right.timing().presentationTime);
        });
#if defined(WAM_NATIVE_VIDEO_TESTING)
    maybeFailCallbackAllocationLocked(
        state, VideoToolboxDecoderTestAllocationPoint::PendingPresentation);
#endif
    state.pendingPresentationFrames.insert(insertion,
                                           std::move(*completed.frame));
    state.peakPendingPresentationFrames =
        std::max(state.peakPendingPresentationFrames,
                 state.pendingPresentationFrames.size());
  }
}

void resetPresentationState(
    const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  std::vector<FrameLease> retiredFrames;
  std::lock_guard deliveryLock(state->deliveryMutex);
  {
    std::lock_guard lock(state->mutex);
    retiredFrames.swap(state->pendingPresentationFrames);
    state->completedDecodes.clear();
    state->nextSubmissionSequence = 0;
    state->nextCompletionSequence = 0;
    for (AsyncDecodeState::FrameRefConSlot &slot :
         state->frameRefConSlots) {
      slot = {};
    }
    state->currentDirectCompressedBytes = 0;
    state->currentCopiedCompressedBytes = 0;
    state->currentCompressedBytes = 0;
    state->lastDeliveredPresentationTime = kCMTimeInvalid;
    state->callbackFailedClosed = false;
  }
  // Release decoder surfaces outside the state mutex, then return the empty
  // vector's pre-reserved storage before another callback can enter.
  retiredFrames.clear();
  {
    std::lock_guard lock(state->mutex);
    state->pendingPresentationFrames.swap(retiredFrames);
  }
}

bool reserveCallbackStorage(
    const std::shared_ptr<AsyncDecodeState> &state,
    std::size_t maxInFlightFrames,
    std::size_t maxPendingPresentationFrames, std::string *error) {
  if (maxPendingPresentationFrames ==
          std::numeric_limits<std::size_t>::max() ||
      maxInFlightFrames >
          std::numeric_limits<std::size_t>::max() -
              maxPendingPresentationFrames - 1U) {
    assignError(error, "VideoToolbox callback storage bound overflows size_t");
    return false;
  }
  const std::size_t deliveryCapacity =
      maxInFlightFrames + maxPendingPresentationFrames;

  try {
    std::lock_guard deliveryLock(state->deliveryMutex);
    std::lock_guard stateLock(state->mutex);
    if (maxInFlightFrames > state->completedDecodes.max_size() ||
        deliveryCapacity > state->pendingPresentationFrames.max_size()) {
      assignError(error,
                  "VideoToolbox callback storage bound exceeds vector limits");
      return false;
    }
    state->completedDecodes.reserve(maxInFlightFrames);
    // During owner-progressive EOS, callbacks retain rather than enqueue every
    // completed frame. The combined reorder + accepted-in-flight ceiling is
    // the already-derived deliveryCapacity, and the process-wide IOSurface
    // budget remains the harder decoded-memory bound.
    state->pendingPresentationFrames.reserve(deliveryCapacity);
  } catch (const std::bad_alloc &) {
    assignError(error,
                "could not reserve bounded VideoToolbox callback storage");
    return false;
  } catch (const std::length_error &) {
    assignError(error,
                "VideoToolbox callback storage bound exceeds vector limits");
    return false;
  }
  return true;
}

struct BiPlanarSurfaceLayout {
  std::size_t lumaBytesPerElement{0};
  std::size_t chromaBytesPerElement{0};
};

std::optional<BiPlanarSurfaceLayout>
biPlanarSurfaceLayout(OSType pixelFormat) noexcept {
  switch (pixelFormat) {
  case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
  case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    return BiPlanarSurfaceLayout{1, 2};
  case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
  case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    return BiPlanarSurfaceLayout{2, 4};
  default:
    return std::nullopt;
  }
}

// Display-layer counterparts must preserve depth, chroma and range.
bool admitsOutputPixelFormat(OSType pixelFormat, OSType expectedPixelFormat,
                             VideoToolboxOutputInterop outputInterop) noexcept {
  if (outputInterop != VideoToolboxOutputInterop::DisplayLayer &&
      (expectedPixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange ||
       expectedPixelFormat == kCVPixelFormatType_30RGBLEPackedWideGamut ||
       expectedPixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ||
       expectedPixelFormat == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange)) {
    return false;
  }
  if (pixelFormat == expectedPixelFormat) {
    return true;
  }
  if (outputInterop != VideoToolboxOutputInterop::DisplayLayer) {
    return false;
  }
  // Only the display layer widens, and for the same reason in both directions:
  // it never SAMPLES the surface, so the surface's own pixel format is what
  // carries depth and range to WindowServer. An in-process sampler must keep
  // getting exactly the format it was pinned to, because its shaders encode
  // the range assumption -- for those interops the session IS pinned, and
  // VideoToolbox converts a full-range stream down to the requested range
  // itself, so the equality above is already the whole rule.
  const OSType fullRange = fullRangeCounterpartFormat(expectedPixelFormat);
  for (const OSType admitted :
       {expectedPixelFormat, fullRange,
        losslessCounterpartFormat(expectedPixelFormat),
        fullRange == 0 ? OSType{0} : losslessCounterpartFormat(fullRange)}) {
    if (admitted != 0 && pixelFormat == admitted) {
      return true;
    }
  }
  return false;
}

bool validateOutputSurfaceContract(CVPixelBufferRef pixelBuffer,
                                   OSType expectedPixelFormat,
                                   VideoToolboxOutputInterop outputInterop,
                                   std::string *error) {
  if (pixelBuffer == nullptr) {
    assignError(error, "VideoToolbox returned no decoded pixel buffer");
    return false;
  }
  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  if (!admitsOutputPixelFormat(pixelFormat, expectedPixelFormat,
                               outputInterop)) {
    assignError(error,
                "VideoToolbox output pixel format " +
                    std::to_string(pixelFormat) +
                    " did not match the bounded native decode contract " +
                    std::to_string(expectedPixelFormat));
    return false;
  }
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
  if (surface == nullptr) {
    assignError(error, "VideoToolbox produced a frame without an IOSurface");
    return false;
  }
  if (outputInterop == VideoToolboxOutputInterop::Metal ||
      outputInterop == VideoToolboxOutputInterop::DisplayLayer) {
    // A display layer consumes whatever biplanar surface the decoder produced,
    // including the lossless one, so there is no plane layout to verify beyond
    // the IOSurface backing already proven above.
    return true;
  }
  if (outputInterop != VideoToolboxOutputInterop::OpenGL) {
    assignError(error, "unsupported VideoToolbox output interop contract");
    return false;
  }

  const auto layout = biPlanarSurfaceLayout(pixelFormat);
  if (!layout) {
    assignError(error,
                "OpenGL IOSurface import requires NV12 or P010 output");
    return false;
  }
  if (!CVPixelBufferIsPlanar(pixelBuffer) ||
      CVPixelBufferGetPlaneCount(pixelBuffer) != 2 ||
      IOSurfaceGetPlaneCount(surface) != 2) {
    assignError(error,
                "OpenGL IOSurface output must expose exactly two planes");
    return false;
  }
  const OSType surfacePixelFormat = IOSurfaceGetPixelFormat(surface);
  // CoreVideo-owned decoder surfaces normally carry the CV fourcc. A zero
  // IOSurface fourcc is explicitly unspecified and does not prevent CGL plane
  // binding; a contradictory nonzero value is unsafe and must fail closed.
  if (surfacePixelFormat != 0 && surfacePixelFormat != pixelFormat) {
    assignError(error,
                "IOSurface pixel format does not match its CVPixelBuffer");
    return false;
  }

  const std::size_t width = CVPixelBufferGetWidth(pixelBuffer);
  const std::size_t height = CVPixelBufferGetHeight(pixelBuffer);
  if (width == 0 || height == 0) {
    assignError(error, "decoded IOSurface has empty dimensions");
    return false;
  }
  const std::array<std::size_t, 2> expectedWidths{
      width, width / 2U + width % 2U};
  const std::array<std::size_t, 2> expectedHeights{height,
                                                   height / 2U + height % 2U};
  const std::array<std::size_t, 2> expectedBytesPerElement{
      layout->lumaBytesPerElement, layout->chromaBytesPerElement};
  for (std::size_t plane = 0; plane < 2; ++plane) {
    const std::size_t cvWidth =
        CVPixelBufferGetWidthOfPlane(pixelBuffer, plane);
    const std::size_t cvHeight =
        CVPixelBufferGetHeightOfPlane(pixelBuffer, plane);
    const std::size_t cvBytesPerRow =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane);
    const std::size_t surfaceWidth = IOSurfaceGetWidthOfPlane(surface, plane);
    const std::size_t surfaceHeight =
        IOSurfaceGetHeightOfPlane(surface, plane);
    const std::size_t surfaceBytesPerElement =
        IOSurfaceGetBytesPerElementOfPlane(surface, plane);
    const std::size_t surfaceBytesPerRow =
        IOSurfaceGetBytesPerRowOfPlane(surface, plane);
    if (cvWidth != expectedWidths[plane] ||
        cvHeight != expectedHeights[plane] || surfaceWidth != cvWidth ||
        surfaceHeight != cvHeight ||
        surfaceBytesPerElement != expectedBytesPerElement[plane] ||
        surfaceBytesPerRow != cvBytesPerRow ||
        cvWidth > std::numeric_limits<std::size_t>::max() /
                      expectedBytesPerElement[plane] ||
        cvBytesPerRow < cvWidth * expectedBytesPerElement[plane]) {
      assignError(error,
                  "decoded IOSurface plane " + std::to_string(plane) +
                      " does not match the exact " +
                      (pixelFormat ==
                               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                           pixelFormat ==
                               kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                       ? "NV12"
                       : "P010") +
                      " OpenGL texture layout");
      return false;
    }
  }
  return true;
}

bool validateDecodedDimensions(CVPixelBufferRef pixelBuffer,
                               CMVideoDimensions expectedDimensions,
                               std::string *error) {
  if (pixelBuffer == nullptr) {
    assignError(error, "VideoToolbox returned no decoded pixel buffer");
    return false;
  }
  if (expectedDimensions.width <= 0 || expectedDimensions.height <= 0) {
    assignError(error,
                "VideoToolbox decoder has no configured coded dimensions");
    return false;
  }
  if (CVPixelBufferGetWidth(pixelBuffer) !=
          static_cast<std::size_t>(expectedDimensions.width) ||
      CVPixelBufferGetHeight(pixelBuffer) !=
          static_cast<std::size_t>(expectedDimensions.height)) {
    assignError(error,
                "VideoToolbox decoded dimensions did not match the "
                "configured coded dimensions");
    return false;
  }
  return true;
}

bool attachmentIsAbsentOrOneOfStrings(
    CVBufferRef buffer, CFStringRef key,
    std::initializer_list<CFStringRef> expected, const char *diagnostic,
    std::string *error) {
  CFTypeRef value = CVBufferCopyAttachment(buffer, key, nullptr);
  if (value == nullptr) {
    return true;
  }
  const bool matches =
      CFGetTypeID(value) == CFStringGetTypeID() &&
      std::any_of(expected.begin(), expected.end(),
                  [value](CFStringRef candidate) {
                    return candidate != nullptr && CFEqual(value, candidate);
                  });
  CFRelease(value);
  if (!matches) {
    assignError(error, diagnostic);
  }
  return matches;
}

bool rejectPresentAttachment(CVBufferRef buffer, CFStringRef key,
                             const char *diagnostic,
                             std::string *error) {
  CFTypeRef value = CVBufferCopyAttachment(buffer, key, nullptr);
  if (value == nullptr) {
    return true;
  }
  CFRelease(value);
  assignError(error, diagnostic);
  return false;
}

// VideoToolbox forwards matrix_coefficients 5 to the decoded surface in the
// unmapped spelling "YCbCrMatrix#5" rather than resolving it. That tag reaches
// the display layer through CMVideoFormatDescriptionCreateForImageBuffer and
// reaches the scenegraph shaders through ycbcrMatrixForPixelBuffer(), and
// neither can act on a string it does not know. H.273 defines 5 and 6 as one
// matrix, so restating it in the 601 spelling is exact -- and it must happen
// BEFORE the SDR validator below, which would otherwise refuse the frame and
// turn a clean fallback into a mid-playback decode failure.
//
// Restating is the narrowest available fix: the alternative is teaching the
// spelling to every presenter and validator separately, which is the drift
// native_video_color.hpp exists to prevent.
void normalizeDecodedColorAttachments(CVPixelBufferRef pixelBuffer) {
  if (pixelBuffer == nullptr) {
    return;
  }
  CFTypeRef matrix = CVBufferCopyAttachment(
      pixelBuffer, kCVImageBufferYCbCrMatrixKey, nullptr);
  if (matrix == nullptr) {
    return;
  }
  if (CFGetTypeID(matrix) == CFStringGetTypeID() &&
      CFEqual(matrix, wam::macos::bt470bgYCbCrMatrixSpelling())) {
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                          kCVAttachmentMode_ShouldPropagate);
  }
  CFRelease(matrix);
}

bool validateDecodedSdrColorAttachments(CVPixelBufferRef pixelBuffer,
                                        std::string *error) {
  if (pixelBuffer == nullptr) {
    assignError(error, "VideoToolbox returned no decoded pixel buffer");
    return false;
  }
  // A stream whose VUI carries no colour description reaches this port with
  // Unknown primaries, which admission deliberately accepts as SDR. The
  // decoder does not see that "unspecified" state: VideoToolbox resolves it
  // with the conventional SD/HD inference and attaches a concrete value, so
  // every untagged standard-definition frame arrives tagged SMPTE_C (525) or
  // EBU_3213 (625) with the matching BT.601 matrix. Those are the SD SDR
  // primaries for exactly the inference the presentation path already
  // implements -- see the BT.601 conversion in qt_gl_video_item.mm -- so
  // rejecting them here would fail every untagged SD clip while accepting the
  // identical untagged HD one. An explicitly tagged BT.601 stream never gets
  // this far: the media source marks that unsupported at admission.
  // BT.2020 primaries and the PQ/HLG transfers are admitted, and the two HDR
  // volume/light attachments are not refused -- they are the payload the
  // presentation path DELIVERS. On this platform VideoToolbox attaches the
  // stream's own primaries/transfer/matrix to every decoded surface, copies
  // MasteringDisplayColorVolume and ContentLightLevelInfo across verbatim, and
  // resolves a matching CGColorSpace ("Rec. ITU-R BT.2100 PQ"/"... HLG"), all
  // of which CMVideoFormatDescriptionCreateForImageBuffer reproduces into the
  // format description native_layer_video_output enqueues with. Refusing them
  // here would discard exactly the information WindowServer tone-maps from.
  //
  // Everything genuinely unrepresentable keeps its named refusal below:
  // gamma, ICC, alternative and log transfer characteristics, any ambient
  // viewing environment other than the qualified HLG payload, content colour
  // volume, and the macOS 15 post-decode classes.
  if (!attachmentIsAbsentOrOneOfStrings(
          pixelBuffer, kCVImageBufferColorPrimariesKey,
          {kCVImageBufferColorPrimaries_ITU_R_709_2,
           kCVImageBufferColorPrimaries_SMPTE_C,
           kCVImageBufferColorPrimaries_EBU_3213,
           kCVImageBufferColorPrimaries_ITU_R_2020},
          "decoded color primaries are not BT.709, BT.601 or BT.2020", error) ||
      !attachmentIsAbsentOrOneOfStrings(
          pixelBuffer, kCVImageBufferTransferFunctionKey,
          {kCVImageBufferTransferFunction_ITU_R_709_2,
           kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
           kCVImageBufferTransferFunction_ITU_R_2100_HLG},
          "decoded transfer function is not BT.709, PQ or HLG", error) ||
      !attachmentIsAbsentOrOneOfStrings(
          pixelBuffer, kCVImageBufferYCbCrMatrixKey,
          {kCVImageBufferYCbCrMatrix_ITU_R_709_2,
           kCVImageBufferYCbCrMatrix_ITU_R_601_4,
           kCVImageBufferYCbCrMatrix_ITU_R_2020},
          "decoded YCbCr matrix is not BT.709, BT.601 or BT.2020", error) ||
      !rejectPresentAttachment(
          pixelBuffer, kCVImageBufferGammaLevelKey,
          "decoded frame carries an unsupported gamma attachment", error) ||
      !rejectPresentAttachment(
          pixelBuffer, kCVImageBufferICCProfileKey,
          "decoded frame carries an unsupported ICC profile", error) ||
      !rejectPresentAttachment(
          pixelBuffer,
          kCMFormatDescriptionExtension_AlternativeTransferCharacteristics,
          "decoded frame carries alternative transfer metadata", error)) {
    return false;
  }

#if defined(__MAC_12_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_12_0
  if (@available(macOS 12.0, *)) {
    CFTypeRef ambient = CVBufferCopyAttachment(
        pixelBuffer, kCVImageBufferAmbientViewingEnvironmentKey, nullptr);
    const bool admitted = !ambient || ambientViewingEnvironmentPayload(ambient) ==
        media::kQualifiedHlgAmbientViewingEnvironment;
    if (ambient) CFRelease(ambient);
    if (!admitted) {
      assignError(error, "AmbientViewingEnvironmentDisplayProofMissing");
      return false;
    }
  }
#endif
#if defined(__MAC_14_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_0
  if (@available(macOS 14.0, *)) {
    if (!rejectPresentAttachment(
            pixelBuffer, kCMFormatDescriptionExtension_ContentColorVolume,
            "decoded frame carries HDR content-color metadata", error)) {
      return false;
    }
  }
#endif
#if defined(__MAC_14_2) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_2
  if (@available(macOS 14.2, *)) {
    if (!rejectPresentAttachment(
            pixelBuffer, kCVImageBufferLogTransferFunctionKey,
            "decoded frame carries a log transfer function", error)) {
      return false;
    }
  }
#endif
#if defined(__MAC_15_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_15_0
  if (@available(macOS 15.0, *)) {
    if (!rejectPresentAttachment(
            pixelBuffer, kCVImageBufferSceneIlluminationKey,
            "decoded frame carries scene-illumination metadata", error) ||
        !rejectPresentAttachment(
            pixelBuffer,
            kCVImageBufferPostDecodeProcessingSequenceMetadataKey,
            "decoded frame carries post-decode sequence metadata", error) ||
        !rejectPresentAttachment(
            pixelBuffer, kCVImageBufferPostDecodeProcessingFrameMetadataKey,
            "decoded frame carries post-decode frame metadata", error)) {
      return false;
    }
  }
#endif
  return true;
}

void insertCompletionTombstoneLocked(
    AsyncDecodeState &state,
    AsyncDecodeState::FrameRefConSlot *slot,
    std::uint64_t submissionSequence) {
  const auto insertion = std::lower_bound(
      state.completedDecodes.begin(), state.completedDecodes.end(),
      submissionSequence,
      [](const AsyncDecodeState::CompletedDecode &completion,
         std::uint64_t sequence) {
        return completion.submissionSequence < sequence;
      });
  if (submissionSequence < state.nextCompletionSequence ||
      (insertion != state.completedDecodes.end() &&
       insertion->submissionSequence == submissionSequence)) {
    return;
  }
  // configure() reserves maxInFlightFrames slots. Since every sequence owns
  // one admission credit, this fail-closed tombstone cannot grow the vector
  // beyond that preallocated ceiling.
  state.completedDecodes.insert(
      insertion,
      AsyncDecodeState::CompletedDecode{submissionSequence, std::nullopt,
                                        slot});
  if (slot != nullptr) {
    slot->state = AsyncDecodeState::FrameRefConSlotState::CallbackComplete;
  }
}

void deliverDecodedFrameImpl(const std::shared_ptr<AsyncDecodeState> &state,
                             AsyncDecodeState::FrameRefConSlot *slot,
                             std::uint64_t submissionSequence,
                             FrameTiming timing, OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime presentationTime,
                             CMTime presentationDuration) {
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
  if (media::late_trace::enabled) timing.decodeCompleteHostTicks = mach_absolute_time();
#endif
  // Async callbacks are not assumed to arrive in submission or presentation
  // order. Serialize the callback boundary, restore submission order by the
  // captured sequence, then apply the SPS-derived PTS reorder bound.
  std::lock_guard deliveryLock(state->deliveryMutex);
  if (CMTIME_IS_VALID(presentationTime)) {
    timing.presentationTime = presentationTime;
  }
  if (CMTIME_IS_VALID(presentationDuration)) {
    timing.duration = presentationDuration;
  }

  {
    std::lock_guard lock(state->mutex);
    if (slot != nullptr &&
        (slot->state !=
             AsyncDecodeState::FrameRefConSlotState::Submitted ||
         slot->submissionSequence != submissionSequence)) {
      assignAsyncErrorLocked(
          *state, "VideoToolbox invoked an invalid frame-refcon callback");
      return;
    }
    if (state->callbackFailedClosed) {
      incrementSaturated(state->dropped);
      insertCompletionTombstoneLocked(*state, slot, submissionSequence);
      collectCompletedDecodesLocked(*state);
    } else {
      std::optional<FrameLease> decodedFrame;
      if (status != noErr) {
        assignAsyncErrorLocked(
            *state, "VideoToolbox output callback reported failure");
        incrementSaturated(state->dropped);
      } else if ((infoFlags & kVTDecodeInfo_FrameDropped) != 0 ||
                 (imageBuffer == nullptr
#if defined(WAM_NATIVE_VIDEO_TESTING)
                  && !state->permitSyntheticCallbackFrame
#endif
                  )) {
        incrementSaturated(state->dropped);
        if (imageBuffer == nullptr &&
            (infoFlags & kVTDecodeInfo_FrameDropped) == 0) {
          assignAsyncErrorLocked(
              *state,
              "VideoToolbox returned success without a decoded pixel buffer");
        }
      } else if (state->discarding || timing.generation != state->generation) {
        // A flush advances the generation before waiting for callbacks, so an
        // old frame is released here without ever reaching the new timeline.
        incrementSaturated(state->dropped);
      } else {
        auto pixelBuffer = static_cast<CVPixelBufferRef>(imageBuffer);
#if defined(WAM_NATIVE_VIDEO_TESTING)
        if (state->permitSyntheticCallbackFrame && pixelBuffer == nullptr) {
          decodedFrame.emplace(pixelBuffer, timing);
        } else
#endif
        if (!validateDecodedDimensions(
                pixelBuffer, state->expectedCodedDimensions, nullptr)) {
          assignAsyncErrorLocked(
              *state,
              "VideoToolbox decoded dimensions did not match the configured "
              "coded dimensions");
          incrementSaturated(state->dropped);
        } else {
          // Runs before both contract checks: the surface's own tag is what
          // the layer and the shaders read, so it is restated at the port
          // rather than reinterpreted at each reader.
          normalizeDecodedColorAttachments(pixelBuffer);
          bool outputSurfaceValid = false;
#if defined(WAM_NATIVE_VIDEO_TESTING)
          if (state->permitSyntheticOutputSurface) {
            outputSurfaceValid = true;
          } else
#endif
          {
            outputSurfaceValid = validateOutputSurfaceContract(
                pixelBuffer, state->expectedOutputPixelFormat,
                state->outputInterop, nullptr);
          }
          if (!outputSurfaceValid) {
            assignAsyncErrorLocked(
                *state,
                "VideoToolbox decoded surface violated the output contract");
            incrementSaturated(state->dropped);
          } else if (!validateDecodedSdrColorAttachments(pixelBuffer,
                                                         nullptr)) {
            assignAsyncErrorLocked(
                *state,
                "VideoToolbox decoded frame carried unsupported color or HDR "
                "metadata");
            incrementSaturated(state->dropped);
          } else if (!CMTIME_IS_NUMERIC(timing.presentationTime)) {
            assignAsyncErrorLocked(
                *state,
                "VideoToolbox returned a decoded frame without a finite "
                "numeric presentation timestamp");
            incrementSaturated(state->dropped);
          } else {
            const OSType pixelFormat =
                CVPixelBufferGetPixelFormatType(pixelBuffer);
            state->actualOutputPixelFormat = pixelFormat;
            if (state->sink == nullptr) {
              assignAsyncErrorLocked(
                  *state, "decoded frame has no configured output sink");
              incrementSaturated(state->dropped);
            } else {
              // This is the first decoded-frame owner created after
              // generation, surface-layout, color, timestamp, and sink
              // validation. FrameLease acquires the process-wide IOSurface
              // budget before retaining the borrowed callback buffer.
              FrameLease admittedFrame(pixelBuffer, timing);
              if (!admittedFrame) {
                // Budget denial is a normal ordered tombstone. It must retire
                // this sequence's in-flight credit without reaching the sink
                // or poisoning later submissions as a stream-contract
                // failure.
                incrementSaturated(state->dropped);
                incrementSaturated(state->surfaceBudgetRejections);
              } else {
                decodedFrame.emplace(std::move(admittedFrame));
              }
            }
          }
        }
      }

      const auto duplicate = std::lower_bound(
          state->completedDecodes.begin(), state->completedDecodes.end(),
          submissionSequence,
          [](const AsyncDecodeState::CompletedDecode &completion,
             std::uint64_t sequence) {
            return completion.submissionSequence < sequence;
          });
      if (submissionSequence < state->nextCompletionSequence ||
          (duplicate != state->completedDecodes.end() &&
           duplicate->submissionSequence == submissionSequence)) {
        if (decodedFrame) {
          incrementSaturated(state->dropped);
        }
        assignAsyncErrorLocked(
            *state,
            "VideoToolbox invoked a duplicate decoded-frame callback");
      } else {
#if defined(WAM_NATIVE_VIDEO_TESTING)
        maybeFailCallbackAllocationLocked(
            *state, VideoToolboxDecoderTestAllocationPoint::CompletedDecode);
#endif
        state->completedDecodes.insert(
            duplicate, AsyncDecodeState::CompletedDecode{
                           submissionSequence, std::move(decodedFrame), slot});
        if (slot != nullptr) {
          slot->state =
              AsyncDecodeState::FrameRefConSlotState::CallbackComplete;
        }
        collectCompletedDecodesLocked(*state);
      }
    }
  }

}

void failDecodedFrameCallback(
    const std::shared_ptr<AsyncDecodeState> &state,
    AsyncDecodeState::FrameRefConSlot *slot,
    std::uint64_t submissionSequence, std::string_view diagnostic) noexcept {
  try {
    std::lock_guard deliveryLock(state->deliveryMutex);
    {
      std::lock_guard lock(state->mutex);
      // Keep every accepted submission behind the same sequence gate even on
      // allocation failure. Existing completions become no-frame tombstones;
      // a missing current completion is added from pre-reserved capacity.
      for (AsyncDecodeState::CompletedDecode &completion :
           state->completedDecodes) {
        completion.frame.reset();
      }
      state->pendingPresentationFrames.clear();
      state->callbackFailedClosed = true;
      state->discarding = true;
      incrementSaturated(state->dropped);
      assignAsyncErrorLocked(*state, diagnostic);
      insertCompletionTombstoneLocked(*state, slot, submissionSequence);
      collectCompletedDecodesLocked(*state);
    }
  } catch (...) {
    recordAsyncError(state,
                     "VideoToolbox output callback failed closed");
  }
}

void deliverDecodedFrame(const std::shared_ptr<AsyncDecodeState> &state,
                         AsyncDecodeState::FrameRefConSlot *slot,
                         std::uint64_t submissionSequence, FrameTiming timing,
                         OSStatus status, VTDecodeInfoFlags infoFlags,
                         CVImageBufferRef imageBuffer, CMTime presentationTime,
                         CMTime presentationDuration) noexcept {
  try {
    deliverDecodedFrameImpl(state, slot, submissionSequence, timing, status,
                            infoFlags, imageBuffer, presentationTime,
                            presentationDuration);
  } catch (const std::bad_alloc &) {
    failDecodedFrameCallback(
        state, slot, submissionSequence,
        "VideoToolbox output callback exhausted bounded storage");
  } catch (const std::exception &) {
    failDecodedFrameCallback(
        state, slot, submissionSequence,
        "VideoToolbox output callback threw an exception");
  } catch (...) {
    failDecodedFrameCallback(
        state, slot, submissionSequence,
        "VideoToolbox output callback threw an unknown exception");
  }
  // This is deliberately outside both callback-owned mutex scopes and after
  // Ordered collection has published any retired admission credit in the same
  // state transaction as slot/byte retirement. The owner can therefore
  // observe the completed state before deciding what to retry.
  notifyProgress(state);
}

[[nodiscard]] media::MediaCodec namedCodec(CMVideoCodecType codec) noexcept {
  return media::mediaCodecForCoreMediaType(static_cast<std::uint32_t>(codec));
}

// VideoToolbox cannot build a VP9 or AV1 decompression session without the
// codec configuration record: CMVideoFormatDescriptionCreate succeeds but
// session creation fails with kVTCouldNotFindVideoDecoderErr (-8971). The
// vpcC/av1C atoms travel through the exact same sample-description-extension
// dictionary as avcC/hvcC, and MPEG-4 Part 2's 'esds' does too -- the raw
// headers in band, or an ES_Descriptor missing the box's four version/flags
// bytes, both return kVTVideoDecoderBadDataErr (-12909).
CFStringRef codecConfigurationAtomName(CMVideoCodecType codec) noexcept {
  return coreMediaConfigurationAtomName(namedCodec(codec));
}

// True for a codec that has NO out-of-band decoder configuration record at
// all, so that "no atom" is the correct format description rather than a
// missing one.
//
// This predicate exists rather than being folded into the atom-name lookup
// above because the two "nullptr" cases mean opposite things: an unknown codec
// has no atom NAME and must be refused, while these codecs have no atom and
// must be admitted. Their sample descriptions carry only descriptive extensions
// (Depth, BitsPerComponent, Vendor), and a session built from dimensions plus
// codec type with null extensions decodes their samples 1:1.
bool codecCarriesNoConfigurationRecord(CMVideoCodecType codec) noexcept {
  const media::MediaCodec named = namedCodec(codec);
  return named != media::MediaCodec::Unknown &&
         !media::mediaCodecFacts(named).carriesConfigurationRecord;
}

// True for either ProRes identity (the 422 family or 4444).
bool codecIsProResFamily(CMVideoCodecType codec) noexcept {
  return namedCodec(codec) == media::MediaCodec::ProRes ||
         namedCodec(codec) == media::MediaCodec::ProRes4444;
}

// True for a codec whose VideoToolbox decoder does NOT natively produce a
// bi-planar 4:2:0 surface, so the output pixel format must be pinned in the
// session's destination attributes even on the display-layer route that
// otherwise leaves the decoder free to pick.
//
// This is a property of the DECODER's native output format and nothing else,
// and is not the same question as codecCarriesNoConfigurationRecord(): MPEG-4
// Part 2 carries a configuration record AND decodes to `2vuy`.
//
// Both of Apple's legacy software decoders behave the same way: an unpinned
// session decodes to `2vuy`
// (kCVPixelFormatType_422YpCbCr8, packed 4:2:2) and a pinned one decodes the
// same bytes to `420v`. Nothing downstream accepts a packed 4:2:2 surface --
// the display layer, the Metal mapper and the OpenGL importer are all
// bi-planar -- so an unpinned session fails the output-surface contract on its
// very first frame ("output pixel format 846624121 did not match the bounded
// native decode contract 875704438").
//
// Pinning costs the same per-frame VTPixelTransferSession the non-display-layer
// contracts already pay. It is affordable for both codecs for the same reason:
// MPEG-2-in-TS is SD, and MPEG-4 Part 2 Simple Profile is an SD-era profile
// whose levels stop at SD resolutions.
// ProRes is the third and fourth case, and it is the same fact one more time.
// An unpinned ProRes session
// decodes to 'sv22' for the 422 family and 'sv44'/'y416' for 4444 -- private
// Apple surface formats that appear in no public CoreVideo header and that
// nothing downstream accepts. A pinned session decodes the same bytes to
// exactly the requested format, including 'x420', on every flavor.
//
// Motion JPEG is the one codec here that would ALMOST survive unpinned: its
// natural output is '420f', the full-range 4:2:0 twin the display-layer
// output contract already admits. It is pinned anyway so that its output format is a decision this
// file makes rather than a property of whichever JPEG happens to be playing --
// the same reason every other legacy decoder is pinned.
bool codecNeedsPinnedOutputPixelFormat(CMVideoCodecType codec) noexcept {
  const media::MediaCodec named = namedCodec(codec);
  return named != media::MediaCodec::Unknown &&
         media::mediaCodecFacts(named).needsPinnedOutputPixelFormat;
}

struct CodecConfigurationAtomMetadata {
  CMVideoCodecType codec{0};
  CFDataRef atom{nullptr}; // Borrowed from the format-description extensions.
  std::size_t byteLength{0};
};

bool inspectCodecConfigurationExtensions(
    CMVideoCodecType codec, CFDictionaryRef extensions,
    CodecConfigurationAtomMetadata &metadata, std::string *error) {
  metadata = {};
  if (codecCarriesNoConfigurationRecord(codec)) {
    // The absence IS the admitted shape. Nothing borrows an atom, nothing
    // compares one, and the equality check below treats two absences as equal.
    metadata.codec = codec;
    metadata.atom = nullptr;
    metadata.byteLength = 0;
    return true;
  }
  const CFStringRef atomName = codecConfigurationAtomName(codec);
  if (atomName == nullptr) {
    assignError(error,
                "direct CoreMedia sample format is not a codec with an "
                "admitted configuration record");
    return false;
  }
  if (extensions == nullptr ||
      CFGetTypeID(extensions) != CFDictionaryGetTypeID()) {
    assignError(error,
                "direct CoreMedia sample format has no extension dictionary");
    return false;
  }
  CFTypeRef atomsValue = static_cast<CFTypeRef>(CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
  if (atomsValue == nullptr ||
      CFGetTypeID(atomsValue) != CFDictionaryGetTypeID()) {
    assignError(error,
                "direct CoreMedia sample format has no configuration atoms");
    return false;
  }
  auto atoms = static_cast<CFDictionaryRef>(atomsValue);
  CFTypeRef atomValue =
      static_cast<CFTypeRef>(CFDictionaryGetValue(atoms, atomName));
  if (atomValue == nullptr || CFGetTypeID(atomValue) != CFDataGetTypeID()) {
    assignError(error,
                "direct CoreMedia sample format has no selected avcC/hvcC "
                "atom");
    return false;
  }
  auto atom = static_cast<CFDataRef>(atomValue);
  const CFIndex length = CFDataGetLength(atom);
  if (length <= 0) {
    assignError(error,
                "direct CoreMedia sample format has an empty avcC/hvcC "
                "atom");
    return false;
  }
  const std::size_t byteLength = static_cast<std::size_t>(length);
  if (!native_video_limits::acceptsVideoCodecConfigurationSize(byteLength)) {
    assignError(error,
                "direct CoreMedia sample format exceeds the 256 KiB codec "
                "configuration bound");
    return false;
  }

  metadata.codec = codec;
  metadata.atom = atom;
  metadata.byteLength = byteLength;
  return true;
}

bool inspectFormatCodecConfiguration(
    CMVideoFormatDescriptionRef format,
    CodecConfigurationAtomMetadata &metadata, std::string *error) {
  metadata = {};
  if (format == nullptr ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) {
    assignError(error,
                "direct CoreMedia sample has no video format description");
    return false;
  }
  const CMVideoCodecType codec = CMFormatDescriptionGetMediaSubType(format);
  return inspectCodecConfigurationExtensions(
      codec, CMFormatDescriptionGetExtensions(format), metadata, error);
}

// ProRes subtypes are interchangeable only within their named family.
bool equivalentSessionCodecTypes(CMVideoCodecType configured,
                                 CMVideoCodecType direct) noexcept {
  return configured == direct || (codecIsProResFamily(configured) &&
                                  namedCodec(configured) == namedCodec(direct));
}

// Only an admitted avcC may lose its optional hint-only extension. SPS/PPS
// bytes, counts, and NAL-length encoding remain exact identity witnesses.
std::size_t avcCoreLength(std::span<const std::byte> record) {
  const auto inspection = media::inspectVideoCodecConfiguration(
      media::MediaCodec::H264, media::MediaCodecConfigurationKind::AvcC,
      record, recordLimits());
  if (!inspection.admitted()) return record.size();
  std::size_t offset = 6;
  auto skipSets = [&](unsigned count) {
    for (unsigned i = 0; i < count; ++i) {
      const auto length = (std::to_integer<unsigned>(record[offset]) << 8U) |
                           std::to_integer<unsigned>(record[offset + 1]);
      offset += 2 + length;
    }
  };
  skipSets(std::to_integer<unsigned>(record[5]) & 31U);
  const auto count = std::to_integer<unsigned>(record[offset++]);
  skipSets(count);
  return offset;
}

bool equivalentAvcAtoms(const CodecConfigurationAtomMetadata &a,
                        const CodecConfigurationAtomMetadata &b) {
  if (a.codec != kCMVideoCodecType_H264 || b.codec != a.codec ||
      !a.atom || !b.atom) return false;
  const auto bytes = [](const CodecConfigurationAtomMetadata &m) {
    return std::span<const std::byte>(
        reinterpret_cast<const std::byte *>(CFDataGetBytePtr(m.atom)),
        m.byteLength);
  };
  const auto left = bytes(a), right = bytes(b);
  const auto n = avcCoreLength(left), m = avcCoreLength(right);
  return n == m && std::equal(left.begin(), left.begin() + n, right.begin());
}

bool equivalentCodecConfigurationAtoms(
    const CodecConfigurationAtomMetadata &configured,
    const CodecConfigurationAtomMetadata &direct, std::string *error) {
  if (configured.codec == direct.codec && configured.atom && direct.atom &&
      CFEqual(configured.atom, direct.atom)) return true;
  if (equivalentAvcAtoms(configured, direct)) return true;
  if (!equivalentSessionCodecTypes(configured.codec, direct.codec) ||
      configured.byteLength != direct.byteLength ||
      // Two absences are equal; one absence against one record is not. The
      // null guard is load-bearing: CFEqual on a null operand is undefined,
      // and MPEG-2 reaches here with both sides null.
      (configured.atom == nullptr) != (direct.atom == nullptr) ||
      (configured.atom != nullptr && direct.atom != nullptr &&
       configured.atom != direct.atom &&
       !CFEqual(configured.atom, direct.atom))) {
    assignError(error,
                "direct CoreMedia sample avcC/hvcC does not exactly match "
                "the configured decoder atom");
    return false;
  }
  return true;
}

#if defined(WAM_NATIVE_VIDEO_TESTING)
bool equivalentFormatCodecConfigurations(
    CMVideoFormatDescriptionRef configuredFormat,
    CMVideoFormatDescriptionRef directFormat, std::string *error) {
  CodecConfigurationAtomMetadata configured;
  if (!inspectFormatCodecConfiguration(configuredFormat, configured, error)) {
    return false;
  }
  CodecConfigurationAtomMetadata direct;
  if (!inspectFormatCodecConfiguration(directFormat, direct, error)) {
    return false;
  }
  return equivalentCodecConfigurationAtoms(configured, direct, error);
}
#endif

bool admitsCodecConfigurationMetadata(
    const VideoStreamConfiguration &configuration) noexcept {
  if (codecCarriesNoConfigurationRecord(configuration.codec)) {
    return configuration.codecConfiguration.empty();
  }
  return codecConfigurationAtomName(configuration.codec) != nullptr &&
         native_video_limits::acceptsVideoCodecConfigurationSize(
             configuration.codecConfiguration.size()) &&
         configuration.codecConfiguration.size() <=
             static_cast<std::size_t>(std::numeric_limits<CFIndex>::max());
}

OSStatus createFormatDescription(const VideoStreamConfiguration &configuration,
                                 CMVideoFormatDescriptionRef *descriptionOut) {
  if (descriptionOut == nullptr) {
    return paramErr;
  }
  *descriptionOut = nullptr;

  if (!admitsCodecConfigurationMetadata(configuration)) {
    return paramErr;
  }
  if (codecCarriesNoConfigurationRecord(configuration.codec)) {
    // A null extensions dictionary, not an empty one.
    const OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, configuration.codec, configuration.codedSize.width,
        configuration.codedSize.height, nullptr, descriptionOut);
    if (status != noErr && *descriptionOut != nullptr) {
      CFRelease(*descriptionOut);
      *descriptionOut = nullptr;
    }
    return status;
  }
  const CFStringRef atomName = codecConfigurationAtomName(configuration.codec);

  CFDataRef atomData = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
  if (!consumeCFAllocationFailure(
          VideoToolboxDecoderTestCFAllocationPoint::CodecAtomData))
#endif
  {
    atomData = CFDataCreate(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8 *>(
            configuration.codecConfiguration.data()),
        static_cast<CFIndex>(configuration.codec == kCMVideoCodecType_H264
            ? avcCoreLength(configuration.codecConfiguration)
            : configuration.codecConfiguration.size()));
  }
  if (atomData == nullptr) {
    return memFullErr;
  }

  const void *atomKeys[] = {atomName};
  const void *atomValues[] = {atomData};
  CFDictionaryRef atoms = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
  if (!consumeCFAllocationFailure(
          VideoToolboxDecoderTestCFAllocationPoint::CodecAtomsDictionary))
#endif
  {
    atoms = CFDictionaryCreate(
        kCFAllocatorDefault, atomKeys, atomValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  }
  CFDictionaryRef extensions = nullptr;
  if (atoms != nullptr) {
#if defined(WAM_NATIVE_VIDEO_TESTING)
    if (!consumeCFAllocationFailure(
            VideoToolboxDecoderTestCFAllocationPoint::
                FormatExtensionsDictionary))
#endif
    {
      CFMutableDictionaryRef mutableExtensions = CFDictionaryCreateMutable(
          kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
      if (mutableExtensions != nullptr) {
        CFDictionarySetValue(
            mutableExtensions,
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
            atoms);
        // The colour description, when the caller modelled one. A description
        // reconstructed from the codec atom alone leaves the decoded surface
        // untagged, and an untagged PQ surface presents as SDR. See
        // VideoStreamConfiguration::colorPrimaries for the measurement.
        //
        // A stream with no modelled colour writes no key.
        if (configuration.colorPrimaries != nullptr) {
          CFDictionarySetValue(mutableExtensions,
                               kCMFormatDescriptionExtension_ColorPrimaries,
                               configuration.colorPrimaries);
        }
        if (configuration.transferFunction != nullptr) {
          CFDictionarySetValue(mutableExtensions,
                               kCMFormatDescriptionExtension_TransferFunction,
                               configuration.transferFunction);
        }
        if (configuration.ycbcrMatrix != nullptr) {
          CFDictionarySetValue(mutableExtensions,
                               kCMFormatDescriptionExtension_YCbCrMatrix,
                               configuration.ycbcrMatrix);
        }
      }
      extensions = mutableExtensions;
    }
  }

  OSStatus status = memFullErr;
  if (extensions != nullptr) {
    status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, configuration.codec, configuration.codedSize.width,
        configuration.codedSize.height, extensions, descriptionOut);
  }
  if (status != noErr && *descriptionOut != nullptr) {
    CFRelease(*descriptionOut);
    *descriptionOut = nullptr;
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

// The stream's OWN coded depth. Kept separate from requestedPixelFormat()
// because the requested OUTPUT depth can exceed the coded depth for an HDR
// stream, and only the difference between them justifies pinning the format on
// the display-layer interop. Getting VP9 Profile 2 wrong would be silent:
// VideoToolbox happily creates an NV12 session for 10-bit VP9 and downconverts,
// so the delivered format still matches the request. MPEG-2, MPEG-4 Part 2 and
// Motion JPEG are 8-bit by profile; ProRes output retains at least ten bits.
bool codedDepthIsTenBit(
    const VideoStreamConfiguration &configuration) noexcept {
  if (codecIsProResFamily(configuration.codec)) {
    return true;
  }
  const auto parsed = parsedRecordFacts(configuration);
  return parsed && parsed->bitDepth >= 10U;
}

// The output surface this decode should produce.
//
// It is the coded depth, EXCEPT that a PQ or HLG stream always asks for a
// 10-bit surface. That is a presentation requirement, not a decode one:
// measured on this platform, AVSampleBufferDisplayLayer presents an
// 8-bit PQ-tagged surface as if it were SDR even though the surface carries
// correct primaries, a correct transfer and a resolved "Rec. ITU-R BT.2100 PQ"
// CGColorSpace, while the identical picture on a 10-bit surface is presented
// correctly. Screen-captured against QuickTime Player on the same 8-bit PQ
// H.264 file, the 8-bit surface was off by 98/255 on the colour-bar means
// (ramp histogram L1 0.65) and the 10-bit surface by 4.6/255 (L1 0.12).
//
// VideoToolbox honours the widened request on an 8-bit stream -- measured,
// `x420` delivered from 8-bit PQ H.264 -- so nothing here is speculative.
OSType
requestedPixelFormat(const VideoStreamConfiguration &configuration) noexcept {
  if (namedCodec(configuration.codec) == media::MediaCodec::ProRes4444) {
    return kCVPixelFormatType_30RGBLEPackedWideGamut;
  }
  const auto parsed = parsedRecordFacts(configuration);
  if (parsed &&
      parsed->sampleFormat == media::MediaVideoSampleFormat::Yuv444EightBit) {
    return kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange;
  }
  const bool is422 =
      parsed && media::mediaSampleFormatIs422(parsed->sampleFormat);
  if (is422) {
    return codedDepthIsTenBit(configuration)
        ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange;
  }
  return (codedDepthIsTenBit(configuration) ||
          configuration.highDynamicRangeTransfer)
             ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
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

enum class CompressedSubmissionStorage : std::uint8_t {
  DirectSampleBuffer,
  CopiedSpan,
};

struct DirectCompressedSampleMetadata {
  CMVideoFormatDescriptionRef formatDescription{nullptr};
  CFDataRef codecConfigurationAtom{nullptr};
  CMVideoCodecType codec{0};
  CMTime presentationTime{kCMTimeInvalid};
  CMTime decodeTime{kCMTimeInvalid};
  CMTime duration{kCMTimeInvalid};
  std::size_t dataLength{0};
  std::size_t configurationLength{0};
  bool keyFrame{false};
};

bool inspectDirectCompressedSample(
    CMSampleBufferRef sample, DirectCompressedSampleMetadata &metadata,
    std::string *error) {
  if (sample == nullptr) {
    assignError(error, "compressed CoreMedia sample buffer is null");
    return false;
  }
  if (!CMSampleBufferIsValid(sample)) {
    assignError(error, "compressed CoreMedia sample buffer is invalid");
    return false;
  }
  if (!CMSampleBufferDataIsReady(sample)) {
    assignError(error, "compressed CoreMedia sample data is not ready");
    return false;
  }
  if (CMSampleBufferGetNumSamples(sample) != 1) {
    assignError(error,
                "compressed CoreMedia buffer must contain exactly one "
                "sample");
    return false;
  }

  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  if (block == nullptr) {
    assignError(error, "compressed CoreMedia sample has no block buffer");
    return false;
  }
  const std::size_t dataLength = CMBlockBufferGetDataLength(block);
  const std::size_t sampleLength = CMSampleBufferGetSampleSize(sample, 0);
  if (dataLength == 0 || sampleLength == 0 || sampleLength != dataLength) {
    assignError(error,
                "compressed CoreMedia sample must occupy its complete, "
                "nonempty block buffer");
    return false;
  }
  if (!native_video_limits::acceptsCompressedVideoAccessUnitSize(dataLength)) {
    assignError(error,
                "compressed CoreMedia sample exceeds the 8 MiB decoder "
                "memory bound");
    return false;
  }

  auto formatDescription = static_cast<CMVideoFormatDescriptionRef>(
      CMSampleBufferGetFormatDescription(sample));
  CodecConfigurationAtomMetadata configuration;
  if (!inspectFormatCodecConfiguration(formatDescription, configuration,
                                       error)) {
    return false;
  }

  bool keyFrame = true;
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
    if (CFArrayGetCount(attachments) != 1) {
      assignError(error,
                  "compressed CoreMedia sample has inconsistent attachment "
                  "count");
      return false;
    }
    CFTypeRef first = static_cast<CFTypeRef>(
        CFArrayGetValueAtIndex(attachments, 0));
    if (first == nullptr || CFGetTypeID(first) != CFDictionaryGetTypeID()) {
      assignError(error,
                  "compressed CoreMedia sample has malformed attachments");
      return false;
    }
    auto attachment = static_cast<CFDictionaryRef>(first);
    CFTypeRef notSync = static_cast<CFTypeRef>(CFDictionaryGetValue(
        attachment, kCMSampleAttachmentKey_NotSync));
    if (notSync != nullptr) {
      if (CFGetTypeID(notSync) != CFBooleanGetTypeID()) {
        assignError(error,
                    "compressed CoreMedia sample has a malformed sync "
                    "attachment");
        return false;
      }
      keyFrame = !CFBooleanGetValue(static_cast<CFBooleanRef>(notSync));
    }
  }

  metadata.formatDescription = formatDescription;
  metadata.codecConfigurationAtom = configuration.atom;
  metadata.codec = configuration.codec;
  metadata.presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
  metadata.decodeTime = CMSampleBufferGetDecodeTimeStamp(sample);
  metadata.duration = CMSampleBufferGetDuration(sample);
  metadata.dataLength = dataLength;
  metadata.configurationLength = configuration.byteLength;
  metadata.keyFrame = keyFrame;
  return true;
}

} // namespace

struct VideoToolboxDecoder::Impl {
  explicit Impl(VideoToolboxDecoderOptions decoderOptions)
      : options(decoderOptions),
        async(std::make_shared<AsyncDecodeState>(
            decoderOptions.progressHandler,
            decoderOptions.maxInFlightFrames)) {}

  VideoToolboxDecoderOptions options;
  mutable std::mutex operationMutex;
  std::shared_ptr<AsyncDecodeState> async;
  CMVideoFormatDescriptionRef formatDescription{nullptr};
  VTDecompressionSessionRef session{nullptr};
  bool configured{false};
  bool ended{false};
  bool endOfStreamCallbacksFinalized{false};
  bool endOfStreamSinkNotified{false};
  bool endOfStreamFailed{false};
  std::string endOfStreamError;
  bool awaitingKeyFrame{true};
  bool usingHardware{false};
  bool preferHardware{true};
  bool requireHardware{false};
  OSType outputPixelFormat{0};
  // True when outputPixelFormat was widened to 10 bits because the stream
  // carries a PQ or HLG transfer. It is tracked separately from the format
  // itself because it is the reason the format must be PINNED on the display
  // -layer interop, which otherwise deliberately leaves it unpinned -- see
  // createSessionLocked().
  bool hdrOutputSurfaceRequired{false};
  std::uint64_t retirementRetiredGeneration{0};
  std::uint64_t retirementInvalidationGeneration{0};
  bool retirementStarted{false};
  bool retirementDone{false};
#if defined(WAM_NATIVE_VIDEO_TESTING)
  std::size_t testReservedInFlight{0};
#endif

  ~Impl() {
    waitAndInvalidateSessionLocked();
    if (formatDescription != nullptr) {
      CFRelease(formatDescription);
    }
  }

  static void decompressionOutputCallback(
      void *decompressionOutputRefCon, void *sourceFrameRefCon,
      OSStatus status, VTDecodeInfoFlags infoFlags,
      CVImageBufferRef imageBuffer, CMTime presentationTime,
      CMTime presentationDuration) noexcept {
    auto *self = static_cast<Impl *>(decompressionOutputRefCon);
    auto *slot =
        static_cast<AsyncDecodeState::FrameRefConSlot *>(sourceFrameRefCon);
    if (self == nullptr || slot == nullptr) {
      return;
    }

    try {
      // Impl and the stable slot pool remain alive through Apple's documented
      // WaitForAsynchronousFrames completion barrier. Copy timing/sequence
      // only after publishing active entry under the same mutex used by slot
      // arming and our stricter post-notification callback-tail barrier.
      AsyncDecodeState &state = *self->async;
      std::uint64_t sequence = 0;
      FrameTiming timing;
      {
        std::lock_guard stateLock(state.mutex);
        ++state.activeCallbacks;
        sequence = slot->submissionSequence;
        timing = slot->timing;
      }

      deliverDecodedFrame(self->async, slot, sequence, timing, status,
                          infoFlags, imageBuffer, presentationTime,
                          presentationDuration);
      {
        std::lock_guard stateLock(state.mutex);
        if (state.activeCallbacks != 0) {
          --state.activeCallbacks;
        }
        state.completion.notify_all();
      }
    } catch (...) {
      // No C++ exception may cross VideoToolbox's C callback boundary. The
      // callback delivery path itself is fail-closed and allocation-free;
      // this final guard covers pathological mutex/shared-owner failures.
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

    CFMutableDictionaryRef decoderSpecification = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
    if (!consumeCFAllocationFailure(
            VideoToolboxDecoderTestCFAllocationPoint::
                DecoderSpecificationDictionary))
#endif
    {
      decoderSpecification = CFDictionaryCreateMutable(
          kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
    }
    if (decoderSpecification == nullptr) {
      assignError(error,
                  "could not allocate the VideoToolbox decoder "
                  "specification");
      return false;
    }
    if (preferHardware || requireHardware) {
      CFDictionarySetValue(
          decoderSpecification,
          kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,
          kCFBooleanTrue);
    } else {
      CFDictionarySetValue(decoderSpecification,
          kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,
          kCFBooleanFalse);
    }
    if (requireHardware) {
      CFDictionarySetValue(
          decoderSpecification,
          kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder,
          kCFBooleanTrue);
    }

    CFDictionaryRef emptyIOSurfaceProperties = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
    if (!consumeCFAllocationFailure(
            VideoToolboxDecoderTestCFAllocationPoint::
                IOSurfacePropertiesDictionary))
#endif
    {
      emptyIOSurfaceProperties = CFDictionaryCreate(
          kCFAllocatorDefault, nullptr, nullptr, 0,
          &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
    }
    if (emptyIOSurfaceProperties == nullptr) {
      CFRelease(decoderSpecification);
      assignError(error,
                  "could not allocate the IOSurface output properties");
      return false;
    }

    CFMutableDictionaryRef imageAttributes = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
    if (!consumeCFAllocationFailure(
            VideoToolboxDecoderTestCFAllocationPoint::
                ImageAttributesDictionary))
#endif
    {
      imageAttributes = CFDictionaryCreateMutable(
          kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
    }
    if (imageAttributes == nullptr) {
      CFRelease(emptyIOSurfaceProperties);
      CFRelease(decoderSpecification);
      assignError(error,
                  "could not allocate the decoded-image attributes");
      return false;
    }
    CFDictionarySetValue(imageAttributes, kCVPixelBufferIOSurfacePropertiesKey,
                         emptyIOSurfaceProperties);
    CFDictionarySetValue(imageAttributes, kCVPixelBufferMetalCompatibilityKey,
                         kCFBooleanTrue);
    if (options.outputInterop == VideoToolboxOutputInterop::OpenGL) {
      CFDictionarySetValue(
          imageAttributes,
          kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey,
          kCFBooleanTrue);
    }
    // Pinning the output format is what forces the per-frame
    // VTPixelTransferSession: the decoder's native surface is AGX
    // lossless-compressed, and asking for the uncompressed fourcc makes
    // VideoToolbox decompress every frame through IOSurfaceAccelerator inside
    // VTDecoderXPCService. A display-layer presenter never samples the surface,
    // so it leaves the format unpinned and takes whatever the decoder produced.
    // The pinned contracts keep the pin: measured on this box, an unpinned
    // session that also carries OpenGL texture compatibility returns BGRA,
    // which would be a far worse conversion than the one being removed.
    //
    // Apple's legacy software decoders must pin REGARDLESS of the interop,
    // because their native output is packed 4:2:2 and nothing downstream
    // accepts it. See codecNeedsPinnedOutputPixelFormat() for the measurement
    // and for why that predicate is not the same question as "does this codec
    // carry a configuration record".
    const CMVideoCodecType sessionCodec =
        formatDescription != nullptr
            ? CMFormatDescriptionGetMediaSubType(formatDescription)
            : 0;
    // An HDR stream pins too, on every interop. The display layer normally
    // takes whatever the decoder produced because it never samples the
    // surface -- but for a PQ/HLG stream the surface's DEPTH is exactly what
    // decides whether the system presents it through the HDR path at all
    // (see VideoStreamConfiguration::highDynamicRangeTransfer). An unpinned session hands back the coded
    // depth, which for an 8-bit PQ stream is an 8-bit surface presented as
    // SDR, and the request in outputPixelFormat then disagrees with what
    // arrives and fails the output-surface contract instead. Pinning makes
    // the 10-bit request real; VideoToolbox honours it on an 8-bit stream
    // (measured: `x420` delivered from 8-bit PQ H.264).
    const bool pinOutputPixelFormat =
        options.outputInterop != VideoToolboxOutputInterop::DisplayLayer ||
        codecNeedsPinnedOutputPixelFormat(sessionCodec) ||
        outputPixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange ||
        outputPixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ||
        outputPixelFormat == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange ||
        hdrOutputSurfaceRequired;
    CFNumberRef pixelFormatNumber = nullptr;
    if (pinOutputPixelFormat) {
      const std::int32_t pixelFormatValue =
          static_cast<std::int32_t>(outputPixelFormat);
#if defined(WAM_NATIVE_VIDEO_TESTING)
      if (!consumeCFAllocationFailure(
              VideoToolboxDecoderTestCFAllocationPoint::PixelFormatNumber))
#endif
      {
        pixelFormatNumber = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormatValue);
      }
      if (pixelFormatNumber == nullptr) {
        CFRelease(imageAttributes);
        CFRelease(emptyIOSurfaceProperties);
        CFRelease(decoderSpecification);
        assignError(error,
                    "could not allocate the output pixel-format request");
        return false;
      }
      CFDictionarySetValue(imageAttributes, kCVPixelBufferPixelFormatTypeKey,
                           pixelFormatNumber);
    }

    const VTDecompressionOutputCallbackRecord callbackRecord{
        &Impl::decompressionOutputCallback, this};
    const OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault, formatDescription, decoderSpecification,
        imageAttributes, &callbackRecord, &session);
    if (pixelFormatNumber != nullptr) {
      CFRelease(pixelFormatNumber);
    }
    CFRelease(imageAttributes);
    CFRelease(emptyIOSurfaceProperties);
    CFRelease(decoderSpecification);
    if (status != noErr || session == nullptr) {
      if (session != nullptr) {
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
      }
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

  // The configured description is reconstructed from the codec configuration
  // atom alone. VideoToolbox admits that reconstruction for H.264, but its
  // HEVC acceptance test compares the complete extension dictionary, which no
  // reconstruction carries. A directly submitted sample brings the container's
  // own description, so once it has proven the same configuration atom, adopt
  // it as the description the session is created from. An already created
  // session is never rebuilt underneath its in-flight frames.
  bool adoptDirectFormatLocked(const DirectCompressedSampleMetadata &metadata,
                               std::string *error) {
    if (metadata.formatDescription == nullptr ||
        metadata.formatDescription == formatDescription ||
        (session != nullptr &&
         VTDecompressionSessionCanAcceptFormatDescription(
             session, metadata.formatDescription))) {
      return true;
    }
    CodecConfigurationAtomMetadata configuredAtom;
    if (!inspectFormatCodecConfiguration(formatDescription, configuredAtom,
                                          error)) {
      return false;
    }
    const CodecConfigurationAtomMetadata direct{
        metadata.codec, metadata.codecConfigurationAtom,
        metadata.configurationLength};
    if (!equivalentCodecConfigurationAtoms(configuredAtom, direct, error)) {
      return false;
    }
    // Only a quiescent decoder may exchange its description. Anything already
    // decoding keeps the existing session, and acceptsDirectFormatLocked()
    // still fails that stream closed rather than retiring live frames here.
    {
      std::lock_guard stateLock(async->mutex);
      if (async->inFlight != 0 || async->activeCallbacks != 0 ||
          !async->pendingPresentationFrames.empty()) {
        return true;
      }
    }
    waitAndInvalidateSessionLocked();
    CFRetain(metadata.formatDescription);
    CFRelease(formatDescription);
    formatDescription = metadata.formatDescription;
    return true;
  }

  bool acceptsDirectFormatLocked(const DirectCompressedSampleMetadata &metadata,
                                 std::string *error) {
    CodecConfigurationAtomMetadata configuredAtom;
    if (!inspectFormatCodecConfiguration(formatDescription, configuredAtom,
                                          error)) {
      return false;
    }
    const CodecConfigurationAtomMetadata direct{
        metadata.codec, metadata.codecConfigurationAtom,
        metadata.configurationLength};
    if (!equivalentCodecConfigurationAtoms(configuredAtom, direct, error)) {
      return false;
    }
    if (!VTDecompressionSessionCanAcceptFormatDescription(
            session, metadata.formatDescription)) {
      assignError(error,
                  "configured VideoToolbox session cannot accept the "
                  "compressed CoreMedia sample format");
      return false;
    }
    return true;
  }

  AsyncDecodeState::FrameRefConSlot *reserveDecodeCapacityLocked() {
    std::lock_guard stateLock(async->mutex);
    if (admissionSaturatedLocked(*async, options.maxInFlightFrames)) {
      incrementSaturated(async->backpressuredSubmissions);
      return nullptr;
    }
    const auto available = std::find_if(
        async->frameRefConSlots.begin(), async->frameRefConSlots.end(),
        [](const AsyncDecodeState::FrameRefConSlot &slot) {
          return slot.state ==
                 AsyncDecodeState::FrameRefConSlotState::Available;
        });
    if (available == async->frameRefConSlots.end()) {
      assignAsyncErrorLocked(
          *async, "VideoToolbox frame-refcon capacity is inconsistent");
      return nullptr;
    }
    available->state = AsyncDecodeState::FrameRefConSlotState::Reserved;
    ++async->inFlight;
    return &*available;
  }

  bool armFrameRefConSlotLocked(
      AsyncDecodeState::FrameRefConSlot *slot, FrameTiming timing,
      CompressedSubmissionStorage storage, std::size_t compressedBytes,
      std::uint64_t *submissionSequence, std::string *error) {
    if (slot == nullptr || submissionSequence == nullptr) {
      assignError(error, "VideoToolbox submission has no frame-refcon slot");
      return false;
    }
    std::lock_guard stateLock(async->mutex);
    if (slot->state != AsyncDecodeState::FrameRefConSlotState::Reserved) {
      assignError(error, "VideoToolbox frame-refcon slot was not reserved");
      return false;
    }
    *submissionSequence = async->nextSubmissionSequence++;
    slot->submissionSequence = *submissionSequence;
    slot->timing = timing;
    slot->compressedBytes = static_cast<std::uint64_t>(compressedBytes);
    slot->directCompressedStorage =
        storage == CompressedSubmissionStorage::DirectSampleBuffer;
    if (slot->directCompressedStorage) {
      async->currentDirectCompressedBytes = saturatedAdd(
          async->currentDirectCompressedBytes, slot->compressedBytes);
      updatePeak(async->peakDirectCompressedBytes,
                 async->currentDirectCompressedBytes);
    } else {
      async->currentCopiedCompressedBytes = saturatedAdd(
          async->currentCopiedCompressedBytes, slot->compressedBytes);
      updatePeak(async->peakCopiedCompressedBytes,
                 async->currentCopiedCompressedBytes);
    }
    async->currentCompressedBytes = saturatedAdd(
        async->currentCompressedBytes, slot->compressedBytes);
    updatePeak(async->peakCompressedBytes, async->currentCompressedBytes);
    slot->state = AsyncDecodeState::FrameRefConSlotState::Submitted;
    return true;
  }

  VideoDecodeSubmitResult submitPreparedSampleLocked(
      CMSampleBufferRef sample, AsyncDecodeState::FrameRefConSlot *slot,
      FrameTiming timing,
      CompressedSubmissionStorage storage, std::size_t compressedBytes,
      std::string *error) {
    std::uint64_t submissionSequence = 0;
    if (!armFrameRefConSlotLocked(slot, timing, storage, compressedBytes,
                                  &submissionSequence, error)) {
      return VideoDecodeSubmitResult::Rejected;
    }
    VTDecodeInfoFlags infoFlags = 0;
#if defined(WAM_NATIVE_VIDEO_TESTING)
    const VTDecodeFrameFlags decodeFlags = finiteAdmissionDecodeFlags(
        options.enableAsynchronousDecompression);
#else
    constexpr VTDecodeFrameFlags decodeFlags = kProductionDecodeFrameFlags;
#endif
    const OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(
        session, sample, decodeFlags, slot, &infoFlags);
    if (decodeStatus != noErr) {
      // Retire the assigned sequence through the same ordering gate. Otherwise
      // a recoverable caller could leave every later callback waiting behind
      // a sequence that VideoToolbox never accepted.
      deliverDecodedFrame(async, slot, submissionSequence, timing,
                          decodeStatus, 0, nullptr, kCMTimeInvalid,
                          kCMTimeInvalid);
      assignError(
          error,
          statusError("VTDecompressionSessionDecodeFrame", decodeStatus));
      return VideoDecodeSubmitResult::Rejected;
    }
    {
      std::lock_guard stateLock(async->mutex);
      incrementSaturated(async->submitted);
      const bool direct =
          storage == CompressedSubmissionStorage::DirectSampleBuffer;
      incrementSaturated(direct ? async->directSampleBufferSubmissions
                                : async->copiedSpanSubmissions);
      std::uint64_t &bytes =
          direct ? async->directSampleBufferBytes : async->copiedSpanBytes;
      bytes = saturatedAdd(bytes, static_cast<std::uint64_t>(compressedBytes));
    }
    awaitingKeyFrame = false;
    return VideoDecodeSubmitResult::Accepted;
  }

  void waitAndInvalidateSessionLocked() noexcept {
    if (session != nullptr) {
      VTDecompressionSessionWaitForAsynchronousFrames(session);
      VTDecompressionSessionInvalidate(session);
      CFRelease(session);
      session = nullptr;
      usingHardware = false;
    }

    std::unique_lock lock(async->mutex);
    async->completion.wait(lock, [this] {
      return async->inFlight == 0 && async->activeCallbacks == 0;
    });
  }

  [[nodiscard]] std::uint64_t currentGenerationLocked() const {
    std::lock_guard stateLock(async->mutex);
    return async->generation;
  }

  // Moves the async state to `generation`, waits out every callback and
  // invalidates the session, then flushes the sink. The order is load-bearing:
  // the flush must follow the wait, or a late callback enqueues into a sink
  // that was already flushed.
  void invalidateGenerationLocked(std::uint64_t generation,
                                  bool clearError) noexcept {
    DecodedFrameSink *sink = nullptr;
    {
      std::lock_guard stateLock(async->mutex);
      async->generation = generation;
      async->discarding = true;
      if (clearError) {
        async->lastError.reset();
      }
      sink = async->sink;
    }
    waitAndInvalidateSessionLocked();
    resetPresentationState(async);
    if (sink != nullptr) {
      sink->flush(generation);
    }
  }

  // After invalidateGenerationLocked: forget the stream and its sink.
  void detachLocked() noexcept {
    if (formatDescription != nullptr) {
      CFRelease(formatDescription);
      formatDescription = nullptr;
    }
    {
      std::lock_guard stateLock(async->mutex);
      async->sink = nullptr;
    }
    configured = false;
    resetEndOfStreamLocked();
    awaitingKeyFrame = true;
    usingHardware = false;
    notifyProgress(async);
  }

  std::optional<std::string> takeAsyncErrorLocked() {
    std::lock_guard lock(async->mutex);
    if (!async->lastError.present()) {
      return std::nullopt;
    }
    std::optional<std::string> result(std::in_place,
                                      async->lastError.bytes.data(),
                                      async->lastError.size);
    async->lastError.reset();
    return result;
  }

  void resetEndOfStreamLocked() noexcept {
    ended = false;
    endOfStreamCallbacksFinalized = false;
    endOfStreamSinkNotified = false;
    endOfStreamFailed = false;
    endOfStreamError.clear();
  }

  VideoDecodeDrainProgress failEndOfStreamLocked(
      std::string message, std::string *error) {
    endOfStreamFailed = true;
    if (endOfStreamError.empty()) {
      endOfStreamError = std::move(message);
    }
    assignError(error, endOfStreamError);
    return VideoDecodeDrainProgress::Failed;
  }

  VideoDecodeDrainProgress currentEndOfStreamProgressLocked(
      std::uint64_t generation, std::string *error) {
    std::size_t inFlight = 0;
    std::uint64_t activeGeneration = 0;
    {
      std::lock_guard stateLock(async->mutex);
      activeGeneration = async->generation;
      inFlight = async->inFlight;
    }
    if (generation != activeGeneration) {
      assignError(error, "end-of-stream operation belongs to a stale "
                         "generation");
      return VideoDecodeDrainProgress::StaleGeneration;
    }
    if (endOfStreamFailed) {
      assignError(error, endOfStreamError);
      return VideoDecodeDrainProgress::Failed;
    }
    if (endOfStreamSinkNotified) {
      return VideoDecodeDrainProgress::Done;
    }
    return inFlight == 0 ? VideoDecodeDrainProgress::Progress
                         : VideoDecodeDrainProgress::Quiescing;
  }

  VideoDecodeDrainProgress beginEndOfStreamLocked(
      std::uint64_t generation, std::string *error) {
    if (!configured) {
      assignError(error, "VideoToolbox decoder is not configured");
      return VideoDecodeDrainProgress::Failed;
    }

    bool newlyBegun = false;
    {
      // This lock pair forms the EOS cut with an already-running callback.
      // Callbacks only restore ordering and retain frames; all sink calls are
      // confined to the owner-driven drain methods.
      std::lock_guard deliveryLock(async->deliveryMutex);
      std::lock_guard stateLock(async->mutex);
      if (generation != async->generation) {
        assignError(error, "end-of-stream operation belongs to a stale "
                           "generation");
        return VideoDecodeDrainProgress::StaleGeneration;
      }
      if (ended) {
        // The exact operation is idempotent. Its current result is sampled
        // below without repeating FinishDelayedFrames.
      } else {
        ended = true;
        newlyBegun = true;
      }
    }

    if (!newlyBegun) {
      return currentEndOfStreamProgressLocked(generation, error);
    }

    const OSStatus finishStatus =
        session == nullptr
            ? noErr
            : VTDecompressionSessionFinishDelayedFrames(session);
    if (finishStatus != noErr) {
      const VideoDecodeDrainProgress failed = failEndOfStreamLocked(
          statusError("VTDecompressionSessionFinishDelayedFrames",
                      finishStatus),
          error);
      notifyProgress(async);
      return failed;
    }

    // FinishDelayedFrames may synchronously run callbacks. Its successful
    // transition is owner-visible even when asynchronous callbacks remain.
    notifyProgress(async);
    if (auto asyncError = takeAsyncErrorLocked()) {
      return failEndOfStreamLocked(std::move(*asyncError), error);
    }
    return currentEndOfStreamProgressLocked(generation, error);
  }

  VideoDecodeDrainProgress drainPresentationLocked(
      std::uint64_t generation, bool requireEndOfStream,
      std::string *error) {
    if (!configured) {
      assignError(error, "VideoToolbox decoder is not configured");
      return VideoDecodeDrainProgress::Failed;
    }
    {
      std::lock_guard stateLock(async->mutex);
      if (generation != async->generation) {
        assignError(error, "presentation drain belongs to a stale generation");
        return VideoDecodeDrainProgress::StaleGeneration;
      }
    }
    if (requireEndOfStream && !ended) {
      assignError(error, "end-of-stream operation has not begun");
      return VideoDecodeDrainProgress::Failed;
    }
    if (endOfStreamFailed) {
      assignError(error, endOfStreamError);
      return VideoDecodeDrainProgress::Failed;
    }

    const VideoDecodeDrainProgress current = ended
        ? currentEndOfStreamProgressLocked(generation, error)
        : VideoDecodeDrainProgress::Progress;
    if (current == VideoDecodeDrainProgress::StaleGeneration ||
        current == VideoDecodeDrainProgress::Failed ||
        current == VideoDecodeDrainProgress::Done) {
      return current;
    }
    if (auto asyncError = takeAsyncErrorLocked()) {
      return failEndOfStreamLocked(std::move(*asyncError), error);
    }

    if (ended && !endOfStreamCallbacksFinalized) {
      if (current == VideoDecodeDrainProgress::Quiescing) {
        return current;
      }
      const OSStatus waitStatus =
          session == nullptr
              ? noErr
              : VTDecompressionSessionWaitForAsynchronousFrames(session);
      if (waitStatus != noErr) {
        return failEndOfStreamLocked(
            statusError("VTDecompressionSessionWaitForAsynchronousFrames",
                        waitStatus),
            error);
      }
      endOfStreamCallbacksFinalized = true;
      if (auto asyncError = takeAsyncErrorLocked()) {
        return failEndOfStreamLocked(std::move(*asyncError), error);
      }
    }

    // Asynchronous decompression is pipelined: VideoToolbox may hold every
    // outstanding submission until further input arrives. Playback never
    // notices, because input never stops before end of stream. A bounded
    // accurate-seek preroll does stop: its last access units before the
    // presentation floor are submitted, admission then closes on them, and the
    // ordered reorder floor still needs one more decoded frame that only those
    // held submissions can supply. Nothing outside this decoder can break that
    // circle, so force the pipeline with the same completion barrier end of
    // stream already uses - and only there, never while admission is still
    // open and the owner can simply submit more.
    if (!ended && session != nullptr) {
      bool starved = false;
      {
        std::lock_guard stateLock(async->mutex);
        const std::size_t retained = async->pendingPresentationFrames.size();
        starved = async->inFlight != 0 &&
                  retained <= async->codecReorderFrames &&
                  admissionSaturatedLocked(*async, options.maxInFlightFrames);
      }
      if (starved) {
        const OSStatus waitStatus =
            VTDecompressionSessionWaitForAsynchronousFrames(session);
        if (waitStatus != noErr) {
          return failEndOfStreamLocked(
              statusError("VTDecompressionSessionWaitForAsynchronousFrames",
                          waitStatus),
              error);
        }
        // Any error the completed callbacks published stays latched for the
        // next entry, exactly where every other async error is observed.
      }
    }

    DecodedFrameSink *sink = nullptr;
    bool hasFrame = false;
    bool acceptedFrame = false;
    bool moreFrames = false;
    bool notifySinkEnd = false;
    FrameLease deliveryAttempt;
    FrameLease retiredFrame;
    FrameEnqueueResult enqueueResult = FrameEnqueueResult::Rejected;
    std::string sinkError;
    const auto failDrain = [&](std::string message) {
      return failEndOfStreamLocked(std::move(message), error);
    };
    {
      std::lock_guard deliveryLock(async->deliveryMutex);
      {
        std::lock_guard stateLock(async->mutex);
        if (generation != async->generation) {
          assignError(error, "end-of-stream operation belongs to a stale "
                             "generation");
          return VideoDecodeDrainProgress::StaleGeneration;
        }
        if (ended &&
            (async->inFlight != 0 || !async->completedDecodes.empty())) {
          return VideoDecodeDrainProgress::Quiescing;
        }
        sink = async->sink;
        if (sink == nullptr) {
          return failDrain(
              "presentation drain has no configured output sink");
        }
        const bool presentable =
            !async->pendingPresentationFrames.empty() &&
            (ended || async->pendingPresentationFrames.size() >
                          async->codecReorderFrames);
        if (presentable) {
          FrameLease &candidate = async->pendingPresentationFrames.front();
          if (!candidate ||
              candidate.timing().generation != generation ||
              !CMTIME_IS_NUMERIC(candidate.timing().presentationTime) ||
              timeBefore(candidate.timing().presentationTime,
                         async->lastDeliveredPresentationTime)) {
            return failDrain(
                "presentation drain violated ordered frame ownership");
          }
          deliveryAttempt = candidate;
          if (!deliveryAttempt) {
            return failDrain(
                "could not clone the retained presentation frame lease");
          }
          hasFrame = true;
        }
      }

      if (hasFrame) {
        try {
          enqueueResult = sink->enqueue(std::move(deliveryAttempt), &sinkError);
        } catch (const std::exception &) {
          return failDrain(
              "presentation frame delivery threw an exception");
        } catch (...) {
          return failDrain(
              "presentation frame delivery threw an unknown exception");
        }

        std::lock_guard stateLock(async->mutex);
        if (enqueueResult == FrameEnqueueResult::Backpressure) {
          incrementSaturated(async->sinkBackpressureRetries);
          if (ended) {
            incrementSaturated(async->endOfStreamBackpressureRetries);
          }
          // The canonical vector entry was never moved. The failed attempt was
          // only an alias of the same IOSurface accounting token, so no new
          // surface charge or replacement record is created for retry.
          return VideoDecodeDrainProgress::Quiescing;
        }
        if (enqueueResult != FrameEnqueueResult::Accepted) {
          return failDrain(
              sinkError.empty() ? "decoded frame sink rejected an "
                                  "owner-drained frame"
                                : std::move(sinkError));
        }

        FrameLease &accepted = async->pendingPresentationFrames.front();
        async->lastDeliveredPresentationTime =
            accepted.timing().presentationTime;
        retiredFrame = std::move(accepted);
        async->pendingPresentationFrames.erase(
            async->pendingPresentationFrames.begin());
        incrementSaturated(async->delivered);
        acceptedFrame = true;
        moreFrames =
            !async->pendingPresentationFrames.empty() &&
            (ended || async->pendingPresentationFrames.size() >
                          async->codecReorderFrames);
      }
      notifySinkEnd = ended && !moreFrames;
    }

    retiredFrame.reset();

    if (moreFrames || (acceptedFrame && !ended)) {
      notifyProgress(async);
      return VideoDecodeDrainProgress::Progress;
    }

    if (!notifySinkEnd) {
      return VideoDecodeDrainProgress::Quiescing;
    }

    // There are no callbacks and no retained ordered frames. endOfStream() is
    // invoked once and only after the final accepted frame (if any) has left
    // decoder ownership.
    try {
      sink->endOfStream(generation);
    } catch (const std::exception &) {
      return failDrain(
          "decoded frame sink end-of-stream threw an exception");
    } catch (...) {
      return failDrain(
          "decoded frame sink end-of-stream threw an unknown exception");
    }
    endOfStreamSinkNotified = true;
    notifyProgress(async);
    return VideoDecodeDrainProgress::Done;
  }

  VideoDecodeDrainProgress drainEndOfStreamLocked(
      std::uint64_t generation, std::string *error) {
    return drainPresentationLocked(generation, true, error);
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
  if (options.outputInterop != VideoToolboxOutputInterop::Metal &&
      options.outputInterop != VideoToolboxOutputInterop::OpenGL &&
      options.outputInterop != VideoToolboxOutputInterop::DisplayLayer) {
    throw std::invalid_argument(
        "unsupported VideoToolbox output interop contract");
  }
}

VideoToolboxDecoder::~VideoToolboxDecoder() { close(); }

bool VideoToolboxDecoder::configure(
    const VideoStreamConfiguration &configuration, DecodedFrameSink &sink,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  // VP9 and AV1 are admitted only where this machine can actually decode them.
  // VP9 additionally requires the supplemental decoder to have been
  // registered, which the capability helper does before its first query, so
  // consulting it here also satisfies the registration precondition for the
  // decompression session created further below.
  // Every video codec the facts table names decodes here except VP8, which has
  // no VideoToolbox decoder at all and is routed to the software stage before
  // this point. The two capability queries are the whole of what varies by
  // machine. The three legacy codecs take no query because theirs would answer
  // 0 and refuse a stream that demonstrably decodes, and ProRes takes none for
  // the opposite reason: the query answers yes for every flavor including both
  // named families, so the family gate is the predicate
  // rather than the query. MPEG-4 Part 2's PROFILE gate is upstream -- only
  // Simple Profile survives media::inspectMpeg4VisualHeaders(), because Apple's
  // decoder refuses Advanced Simple Profile here with codecBadDataErr (-8969).
  const media::MediaCodec namedConfigurationCodec =
      namedCodec(configuration.codec);
  const bool admittedCodec =
      media::mediaCodecFacts(namedConfigurationCodec).kind ==
          media::MediaCodecKind::Video &&
      namedConfigurationCodec != media::MediaCodec::Vp8 &&
      (namedConfigurationCodec != media::MediaCodec::Vp9 ||
       nativeVideoToolboxSupportsVp9()) &&
      (namedConfigurationCodec != media::MediaCodec::Av1 ||
       nativeVideoToolboxSupportsAv1());
  // The record requirement is inverted for the record-less codecs and stated
  // that way: they must present NO record, because they have none.
  const bool admittedConfigurationShape =
      codecCarriesNoConfigurationRecord(configuration.codec)
          ? configuration.codecConfiguration.empty()
          : !configuration.codecConfiguration.empty();
  if (!admittedCodec || configuration.codedSize.width <= 0 ||
      configuration.codedSize.height <= 0 || !admittedConfigurationShape) {
    assignError(error,
                "VideoToolbox requires a decodable "
                "H.264/HEVC/VP9/AV1/MPEG-2/MPEG-4 Part 2/ProRes/Motion JPEG "
                "stream, positive dimensions, and the configuration record "
                "shape its codec states (avcC/hvcC/vpcC/av1C/esds, or none at "
                "all for MPEG-2, ProRes and Motion JPEG)");
    return false;
  }

  std::lock_guard operationLock(impl_->operationMutex);

  if (impl_->retirementStarted) {
    assignError(error, "VideoToolbox decoder was terminally retired");
    return false;
  }

  // Retire an earlier configuration before exposing the new sink/generation.
  if (impl_->configured) {
    impl_->invalidateGenerationLocked(impl_->currentGenerationLocked() + 1,
                                      false);
    notifyProgress(impl_->async);
  }
  impl_->configured = false;
  impl_->resetEndOfStreamLocked();
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

  const std::optional<CodecReorderDepth> codecReorderDepth =
      deriveCodecReorderDepth(configuration);
  if (!codecReorderDepth) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    assignError(error,
                "could not derive a bounded presentation-reorder depth from "
                "the codec SPS");
    return false;
  }
  // A DECLARED depth above the bound is a refusal: the stream is entitled to
  // every frame it asked for, honouring it would overrun the route's
  // decoded-surface budget, and clamping it would reorder that stream's
  // output. An INFERRED depth above the bound is not a demand at all, only the
  // ceiling the specification substitutes for a statement the stream never
  // made, so it is clamped to the bound instead of refused. Understating a
  // stream that really did need more cannot present frames out of order:
  // collectCompletedDecodesLocked() compares every completed frame against the last
  // one delivered and fails the decoder closed before publishing an older one.
  // See CodecReorderDepthOrigin for why the inference is unusable as a refusal
  // criterion in the first place.
  std::size_t admittedReorderFrames = codecReorderDepth->frames;
  if (admittedReorderFrames > impl_->options.maxPendingPresentationFrames) {
    if (codecReorderDepth->origin == CodecReorderDepthOrigin::Declared) {
      CFRelease(impl_->formatDescription);
      impl_->formatDescription = nullptr;
      assignError(error,
                  "codec SPS requires " +
                      std::to_string(codecReorderDepth->frames) +
                      " presentation-reorder frames, exceeding the configured "
                      "bound of " +
                      std::to_string(
                          impl_->options.maxPendingPresentationFrames));
      return false;
    }
    admittedReorderFrames = impl_->options.maxPendingPresentationFrames;
  }
  if (admittedReorderFrames >
      std::numeric_limits<std::size_t>::max() -
          impl_->options.maxInFlightFrames) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    assignError(error, "VideoToolbox retained-frame bound overflows size_t");
    return false;
  }
  if (!reserveCallbackStorage(impl_->async, impl_->options.maxInFlightFrames,
                              impl_->options.maxPendingPresentationFrames,
                              error)) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    return false;
  }

  impl_->preferHardware = configuration.preferHardwareDecode;
  impl_->requireHardware = configuration.requireHardwareDecode;
  impl_->outputPixelFormat = requestedPixelFormat(configuration);
  // Only a WIDENED request needs the pin. A stream that is already 10-bit
  // gets a 10-bit surface from an unpinned session anyway, and pinning it
  // would cost that session the lossless-compressed surface forms the
  // display-layer interop is deliberately left free to use.
  impl_->hdrOutputSurfaceRequired = configuration.highDynamicRangeTransfer &&
                                    !codedDepthIsTenBit(configuration);
  impl_->resetEndOfStreamLocked();
  impl_->awaitingKeyFrame = true;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = &sink;
    impl_->async->generation = configuration.generation;
    impl_->async->discarding = false;
    impl_->async->inFlight = 0;
    impl_->async->activeCallbacks = 0;
    impl_->async->submitted = 0;
    impl_->async->directSampleBufferSubmissions = 0;
    impl_->async->directSampleBufferBytes = 0;
    impl_->async->copiedSpanSubmissions = 0;
    impl_->async->copiedSpanBytes = 0;
    impl_->async->currentDirectCompressedBytes = 0;
    impl_->async->peakDirectCompressedBytes = 0;
    impl_->async->currentCopiedCompressedBytes = 0;
    impl_->async->peakCopiedCompressedBytes = 0;
    impl_->async->currentCompressedBytes = 0;
    impl_->async->peakCompressedBytes = 0;
    impl_->async->delivered = 0;
    impl_->async->dropped = 0;
    impl_->async->backpressuredSubmissions = 0;
    impl_->async->sinkBackpressureRetries = 0;
    impl_->async->endOfStreamBackpressureRetries = 0;
    impl_->async->surfaceBudgetRejections = 0;
    impl_->async->outOfOrderDrops = 0;
    impl_->async->codecReorderFrames = admittedReorderFrames;
    impl_->async->maxRetainedFrames =
        impl_->options.maxInFlightFrames + admittedReorderFrames;
    impl_->async->peakPendingPresentationFrames = 0;
    impl_->async->nextSubmissionSequence = 0;
    impl_->async->nextCompletionSequence = 0;
    for (AsyncDecodeState::FrameRefConSlot &slot :
         impl_->async->frameRefConSlots) {
      slot = {};
    }
    impl_->async->completedDecodes.clear();
    impl_->async->pendingPresentationFrames.clear();
    impl_->async->outputInterop = impl_->options.outputInterop;
    impl_->async->expectedOutputPixelFormat = impl_->outputPixelFormat;
    impl_->async->actualOutputPixelFormat = 0;
    impl_->async->expectedCodedDimensions = configuration.codedSize;
    impl_->async->lastDeliveredPresentationTime = kCMTimeInvalid;
    impl_->async->callbackFailedClosed = false;
    impl_->async->lastError.reset();
#if defined(WAM_NATIVE_VIDEO_TESTING)
    impl_->async->failNextAllocationPoint.reset();
    impl_->async->permitSyntheticCallbackFrame = false;
    impl_->async->permitSyntheticOutputSurface = false;
#endif
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
    const VideoDecodeDrainProgress begun =
        impl_->beginEndOfStreamLocked(generation, error);
    if (begun == VideoDecodeDrainProgress::Failed ||
        begun == VideoDecodeDrainProgress::StaleGeneration) {
      return VideoDecodeSubmitResult::Rejected;
    }
    if (begun == VideoDecodeDrainProgress::Done) {
      return VideoDecodeSubmitResult::Accepted;
    }
    const VideoDecodeDrainProgress drained =
        impl_->drainEndOfStreamLocked(generation, error);
    switch (drained) {
    case VideoDecodeDrainProgress::Done:
      return VideoDecodeSubmitResult::Accepted;
    case VideoDecodeDrainProgress::Progress:
    case VideoDecodeDrainProgress::Quiescing:
      // Resubmitting the exact EOS packet performs at most one more bounded
      // owner drain attempt; the retained frame is never silently consumed.
      return VideoDecodeSubmitResult::Backpressure;
    case VideoDecodeDrainProgress::StaleGeneration:
    case VideoDecodeDrainProgress::Failed:
      return VideoDecodeSubmitResult::Rejected;
    }
  }

  if (impl_->ended) {
    assignError(error, "cannot submit compressed data after end of stream");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (packet.bytes.empty()) {
    assignError(error, "compressed video packet is empty");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!native_video_limits::acceptsCompressedVideoAccessUnitSize(
          packet.bytes.size())) {
    assignError(error,
                "compressed video packet exceeds the 8 MiB decoder memory "
                "bound");
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
  AsyncDecodeState::FrameRefConSlot *slot =
      impl_->reserveDecodeCapacityLocked();
  if (slot == nullptr) {
    return VideoDecodeSubmitResult::Backpressure;
  }

  CMSampleBufferRef sample = nullptr;
  const OSStatus sampleStatus =
      createCompressedSampleBuffer(impl_->formatDescription, packet, &sample);
  if (sampleStatus != noErr || sample == nullptr) {
    releaseReservedDecodeCapacity(impl_->async, slot);
    notifyProgress(impl_->async);
    assignError(error, statusError("CMSampleBufferCreateReady", sampleStatus));
    return VideoDecodeSubmitResult::Rejected;
  }

  const FrameTiming timing{packet.presentationTime, packet.duration,
                           packet.generation, packet.keyFrame};
  const VideoDecodeSubmitResult result = impl_->submitPreparedSampleLocked(
      sample, slot, timing, CompressedSubmissionStorage::CopiedSpan,
      packet.bytes.size(), error);
  CFRelease(sample);
  return result;
}

VideoDecodeSubmitResult VideoToolboxDecoder::submitCMSampleBuffer(
    CMSampleBufferRef sample, std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (!impl_->configured) {
    assignError(error, "VideoToolbox decoder is not configured");
    return VideoDecodeSubmitResult::Rejected;
  }

  std::uint64_t activeGeneration = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    activeGeneration = impl_->async->generation;
  }
  if (generation != activeGeneration) {
    assignError(error,
                "compressed CoreMedia sample belongs to a stale generation");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl_->ended) {
    assignError(error, "cannot submit compressed data after end of stream");
    return VideoDecodeSubmitResult::Rejected;
  }

  DirectCompressedSampleMetadata metadata;
  if (!inspectDirectCompressedSample(sample, metadata, error)) {
    return VideoDecodeSubmitResult::Rejected;
  }
  const CMVideoDimensions sampleDimensions =
      CMVideoFormatDescriptionGetDimensions(metadata.formatDescription);
  const CMVideoDimensions configuredDimensions =
      CMVideoFormatDescriptionGetDimensions(impl_->formatDescription);
  // Codec equality is asked through equivalentSessionCodecTypes rather than
  // as a raw comparison, because this check runs BEFORE the adoption that
  // reconciles the two descriptions. A ProRes track configures the family's
  // canonical 'apcn' and then presents 'apch'/'apcs'/'apco' samples; those are
  // the same decode contract (measured), and refusing them here would reject
  // every ProRes file that is not literally ProRes 422. Dimensions stay an
  // exact comparison.
  if (!equivalentSessionCodecTypes(
          CMFormatDescriptionGetMediaSubType(impl_->formatDescription),
          CMFormatDescriptionGetMediaSubType(metadata.formatDescription)) ||
      sampleDimensions.width != configuredDimensions.width ||
      sampleDimensions.height != configuredDimensions.height) {
    assignError(error,
                "compressed CoreMedia sample does not match the configured "
                "codec and coded dimensions");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl_->awaitingKeyFrame && !metadata.keyFrame) {
    assignError(error, "decoder requires a key frame after configure or flush");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (auto asyncError = impl_->takeAsyncErrorLocked()) {
    assignError(error, std::move(*asyncError));
    return VideoDecodeSubmitResult::Rejected;
  }
  struct NormalizedSample {
    CMSampleBufferRef value{nullptr};
    CMVideoFormatDescriptionRef format{nullptr};
    ~NormalizedSample() {
      if (value) CFRelease(value);
      if (format) CFRelease(format);
    }
  } normalized;
  if (metadata.codec == kCMVideoCodecType_H264) {
    CodecConfigurationAtomMetadata configured;
    if (!inspectFormatCodecConfiguration(impl_->formatDescription, configured, error) ||
        !equivalentCodecConfigurationAtoms(configured,
            {metadata.codec, metadata.codecConfigurationAtom,
             metadata.configurationLength}, error)) {
      return VideoDecodeSubmitResult::Rejected;
    }
    if (!CFEqual(configured.atom, metadata.codecConfigurationAtom)) {
      // Share compressed storage and preserve timing/attachments, but supply
      // only the admitted SPS/PPS truth to VideoToolbox, including direct input.
      // Preserve all direct format extensions (including HDR ambient metadata)
      // while replacing only avcC. Adopting the bare configured description
      // would silently discard those container-owned presentation facts.
      auto extensions = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0,
          CMFormatDescriptionGetExtensions(metadata.formatDescription));
      auto atoms = extensions ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0,
          static_cast<CFDictionaryRef>(CFDictionaryGetValue(extensions,
              kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms))) : nullptr;
      OSStatus status = memFullErr;
      if (atoms) {
        CFDictionarySetValue(atoms, CFSTR("avcC"), configured.atom);
        CFDictionarySetValue(extensions,
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms, atoms);
        status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
            kCMVideoCodecType_H264, sampleDimensions.width, sampleDimensions.height,
            extensions, &normalized.format);
        CFRelease(atoms);
      }
      if (extensions) CFRelease(extensions);
      CMSampleTimingInfo timing;
      if (status == noErr)
        status = CMSampleBufferGetSampleTimingInfo(sample, 0, &timing);
      const size_t size = CMSampleBufferGetSampleSize(sample, 0);
      if (status == noErr) {
        status = CMSampleBufferCreateReady(kCFAllocatorDefault,
            CMSampleBufferGetDataBuffer(sample), normalized.format,
            1, 1, &timing, 1, &size, &normalized.value);
      }
      if (status != noErr || !normalized.value) {
        assignError(error, statusError("normalize AVC sample", status));
        return VideoDecodeSubmitResult::Rejected;
      }
      CMPropagateAttachments(sample, normalized.value);
      CFArrayRef source = CMSampleBufferGetSampleAttachmentsArray(sample, false);
      CFArrayRef destination = CMSampleBufferGetSampleAttachmentsArray(normalized.value, true);
      if (source && destination && CFArrayGetCount(source) == 1) {
        auto target = static_cast<CFMutableDictionaryRef>(const_cast<void *>(
            CFArrayGetValueAtIndex(destination, 0)));
        CFDictionaryRef original = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(source, 0));
        CFDictionaryApplyFunction(original, [](const void *key, const void *value, void *context) {
          CFDictionarySetValue(static_cast<CFMutableDictionaryRef>(context), key, value);
        }, target);
      }
      sample = normalized.value;
      if (!inspectDirectCompressedSample(sample, metadata, error))
        return VideoDecodeSubmitResult::Rejected;
    }
  }
  if (!impl_->adoptDirectFormatLocked(metadata, error)) {
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!impl_->createSessionLocked(error)) {
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!impl_->acceptsDirectFormatLocked(metadata, error)) {
    return VideoDecodeSubmitResult::Rejected;
  }

  // Preserve the same finite admission gate as generic packet submission.
  // All inspection above is metadata-only; the compressed payload has not
  // been flattened, allocated, or copied when Backpressure is returned.
  AsyncDecodeState::FrameRefConSlot *slot =
      impl_->reserveDecodeCapacityLocked();
  if (slot == nullptr) {
    return VideoDecodeSubmitResult::Backpressure;
  }

  const FrameTiming timing{metadata.presentationTime, metadata.duration,
                           generation, metadata.keyFrame};
  return impl_->submitPreparedSampleLocked(
      sample, slot, timing,
      CompressedSubmissionStorage::DirectSampleBuffer,
      metadata.dataLength, error);
}

VideoDecodeDrainProgress VideoToolboxDecoder::beginEndOfStream(
    std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  return impl_->beginEndOfStreamLocked(generation, error);
}

VideoDecodeDrainProgress VideoToolboxDecoder::drainPresentation(
    std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  return impl_->drainPresentationLocked(generation, false, error);
}

VideoDecodeDrainProgress VideoToolboxDecoder::drainEndOfStream(
    std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  return impl_->drainEndOfStreamLocked(generation, error);
}

void VideoToolboxDecoder::flush(std::uint64_t nextGeneration) noexcept {
  std::lock_guard operationLock(impl_->operationMutex);
  if (impl_->retirementStarted) {
    return;
  }
  impl_->invalidateGenerationLocked(nextGeneration, true);
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->discarding = !impl_->configured;
  }
  impl_->resetEndOfStreamLocked();
  impl_->awaitingKeyFrame = true;
  notifyProgress(impl_->async);
}

VideoDecoderRetireProgress VideoToolboxDecoder::retire(
    std::uint64_t retiredGeneration,
    std::uint64_t invalidationGeneration) noexcept {
  if (!impl_) {
    return VideoDecoderRetireProgress::Failed;
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (impl_->retirementStarted) {
    if (impl_->retirementRetiredGeneration != retiredGeneration ||
        impl_->retirementInvalidationGeneration != invalidationGeneration) {
      return VideoDecoderRetireProgress::StaleGeneration;
    }
    return impl_->retirementDone ? VideoDecoderRetireProgress::Done
                                 : VideoDecoderRetireProgress::Failed;
  }
  std::uint64_t exposedGeneration = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    exposedGeneration = impl_->async->generation;
  }
  if (retiredGeneration != exposedGeneration ||
      invalidationGeneration == 0 ||
      invalidationGeneration <= retiredGeneration) {
    return retiredGeneration != exposedGeneration
               ? VideoDecoderRetireProgress::StaleGeneration
               : VideoDecoderRetireProgress::Failed;
  }
  impl_->retirementStarted = true;
  impl_->retirementRetiredGeneration = retiredGeneration;
  impl_->retirementInvalidationGeneration = invalidationGeneration;

  impl_->invalidateGenerationLocked(invalidationGeneration, false);
  impl_->retirementDone = true;
  impl_->detachLocked();
  return VideoDecoderRetireProgress::Done;
}

void VideoToolboxDecoder::close() noexcept {
  if (!impl_) {
    return;
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (impl_->retirementStarted) {
    return;
  }
  if (!impl_->configured && impl_->session == nullptr &&
      impl_->formatDescription == nullptr) {
    return;
  }

  impl_->invalidateGenerationLocked(impl_->currentGenerationLocked() + 1,
                                    false);
  impl_->detachLocked();
}

VideoToolboxDecoderStats VideoToolboxDecoder::stats() const noexcept {
  std::lock_guard operationLock(impl_->operationMutex);
  VideoToolboxDecoderStats result;
  result.configured = impl_->configured;
  result.usingHardwareAcceleratedDecoder = impl_->usingHardware;
  result.awaitingKeyFrame = impl_->awaitingKeyFrame;
  result.maxInFlightFrames = impl_->options.maxInFlightFrames;
  result.outputInterop = impl_->options.outputInterop;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    result.inFlightFrames = impl_->async->inFlight;
    result.retainedPresentationFrames =
        impl_->async->pendingPresentationFrames.size();
    result.acceptsCompressedSample =
        impl_->configured && !impl_->ended && !impl_->async->discarding &&
        !admissionSaturatedLocked(*impl_->async,
                                  impl_->options.maxInFlightFrames);
    result.codecReorderFrames = impl_->async->codecReorderFrames;
    result.generation = impl_->async->generation;
    result.submittedFrames = impl_->async->submitted;
    result.directSampleBufferSubmissions =
        impl_->async->directSampleBufferSubmissions;
    result.directSampleBufferBytes = impl_->async->directSampleBufferBytes;
    result.copiedSpanSubmissions = impl_->async->copiedSpanSubmissions;
    result.copiedSpanBytes = impl_->async->copiedSpanBytes;
    result.deliveredFrames = impl_->async->delivered;
    result.droppedFrames = impl_->async->dropped;
    result.backpressuredSubmissions = impl_->async->backpressuredSubmissions;
    result.sinkBackpressureRetries = impl_->async->sinkBackpressureRetries;
    result.endOfStreamBackpressureRetries =
        impl_->async->endOfStreamBackpressureRetries;
    result.surfaceBudgetRejections =
        impl_->async->surfaceBudgetRejections;
    result.outOfOrderDrops = impl_->async->outOfOrderDrops;
    result.pendingPresentationFrames =
        impl_->async->pendingPresentationFrames.size();
    result.peakPendingPresentationFrames =
        impl_->async->peakPendingPresentationFrames;
    result.endOfStreamBegun = impl_->ended;
    result.endOfStreamCallbacksFinalized =
        impl_->endOfStreamCallbacksFinalized;
    result.endOfStreamSinkNotified = impl_->endOfStreamSinkNotified;
    result.requestedOutputPixelFormat = impl_->outputPixelFormat;
    result.actualOutputPixelFormat = impl_->async->actualOutputPixelFormat;
  }
  return result;
}

VideoToolboxDecoderMemoryFacts
VideoToolboxDecoder::memoryFacts() const noexcept {
  VideoToolboxDecoderMemoryFacts result;
  std::lock_guard operationLock(impl_->operationMutex);
  std::lock_guard stateLock(impl_->async->mutex);
  result.inFlightFrames = impl_->async->inFlight;
  result.presentationFrames =
      impl_->async->pendingPresentationFrames.size();
  result.currentDirectCompressedBytes =
      impl_->async->currentDirectCompressedBytes;
  result.peakDirectCompressedBytes =
      impl_->async->peakDirectCompressedBytes;
  result.currentCopiedCompressedBytes =
      impl_->async->currentCopiedCompressedBytes;
  result.peakCopiedCompressedBytes =
      impl_->async->peakCopiedCompressedBytes;
  result.currentCompressedBytes = impl_->async->currentCompressedBytes;
  result.peakCompressedBytes = impl_->async->peakCompressedBytes;
  return result;
}

std::optional<std::string> VideoToolboxDecoder::takeLastError() {
  return impl_->takeAsyncErrorLocked();
}

#if defined(WAM_NATIVE_VIDEO_TESTING)
bool VideoToolboxDecoderTestAccess::admitsConfigurationMetadata(
    const VideoStreamConfiguration &configuration) noexcept {
  return admitsCodecConfigurationMetadata(configuration);
}

bool VideoToolboxDecoderTestAccess::copyFormatDescription(
    const VideoStreamConfiguration &configuration,
    CMVideoFormatDescriptionRef *descriptionOut, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (descriptionOut == nullptr) {
    assignError(error, "test format-description output is null");
    return false;
  }
  *descriptionOut = nullptr;
  const OSStatus status = createFormatDescription(configuration, descriptionOut);
  if (status != noErr || *descriptionOut == nullptr) {
    assignError(error,
                statusError("CMVideoFormatDescriptionCreate", status));
    return false;
  }
  return true;
}

bool VideoToolboxDecoderTestAccess::inspectDirectSampleMetadata(
    CMSampleBufferRef sample, std::size_t *dataLength,
    std::size_t *configurationLength, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (dataLength == nullptr || configurationLength == nullptr) {
    assignError(error, "test direct-sample metadata output is null");
    return false;
  }
  *dataLength = 0;
  *configurationLength = 0;
  DirectCompressedSampleMetadata metadata;
  if (!inspectDirectCompressedSample(sample, metadata, error)) {
    return false;
  }
  *dataLength = metadata.dataLength;
  *configurationLength = metadata.configurationLength;
  return true;
}

bool VideoToolboxDecoderTestAccess::inspectDirectConfigurationExtensions(
    CMVideoCodecType codec, CFDictionaryRef extensions,
    std::size_t *configurationLength, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (configurationLength == nullptr) {
    assignError(error, "test direct-configuration length output is null");
    return false;
  }
  *configurationLength = 0;
  CodecConfigurationAtomMetadata metadata;
  if (!inspectCodecConfigurationExtensions(codec, extensions, metadata,
                                           error)) {
    return false;
  }
  *configurationLength = metadata.byteLength;
  return true;
}

bool VideoToolboxDecoderTestAccess::equivalentFormatConfigurations(
    CMVideoFormatDescriptionRef configuredFormat,
    CMVideoFormatDescriptionRef directFormat, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  return equivalentFormatCodecConfigurations(configuredFormat, directFormat,
                                             error);
}

bool VideoToolboxDecoderTestAccess::occupyInFlightCapacity(
    VideoToolboxDecoder &decoder, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  if (decoder.impl_->testReservedInFlight != 0 ||
      decoder.impl_->async->inFlight != 0) {
    assignError(error, "test decoder already has in-flight work");
    return false;
  }
  decoder.impl_->testReservedInFlight =
      decoder.impl_->options.maxInFlightFrames;
  decoder.impl_->async->inFlight = decoder.impl_->testReservedInFlight;
  return true;
}

bool VideoToolboxDecoderTestAccess::releaseInFlightCapacity(
    VideoToolboxDecoder &decoder, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    if (decoder.impl_->testReservedInFlight == 0 ||
        decoder.impl_->async->inFlight !=
            decoder.impl_->testReservedInFlight) {
      assignError(error, "test decoder has no isolated capacity reservation");
      return false;
    }
    decoder.impl_->async->inFlight = 0;
    decoder.impl_->testReservedInFlight = 0;
    decoder.impl_->async->completion.notify_all();
  }
  notifyProgress(decoder.impl_->async);
  return true;
}

std::uint32_t VideoToolboxDecoderTestAccess::decodeFlags(
    const VideoToolboxDecoder &decoder) noexcept {
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  return static_cast<std::uint32_t>(finiteAdmissionDecodeFlags(
      decoder.impl_->options.enableAsynchronousDecompression));
}

std::optional<CodecReorderDepth>
VideoToolboxDecoderTestAccess::codecReorderDepth(
    const VideoStreamConfiguration &configuration) {
  return deriveCodecReorderDepth(configuration);
}

bool VideoToolboxDecoderTestAccess::setPresentationReorderDepth(
    VideoToolboxDecoder &decoder, std::size_t reorderFrames,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard deliveryLock(decoder.impl_->async->deliveryMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  if (reorderFrames > decoder.impl_->options.maxPendingPresentationFrames) {
    assignError(error, "test reorder depth exceeds the decoder bound");
    return false;
  }
  if (decoder.impl_->async->inFlight != 0 ||
      !decoder.impl_->async->completedDecodes.empty() ||
      !decoder.impl_->async->pendingPresentationFrames.empty()) {
    assignError(error, "test decoder ordering state is not empty");
    return false;
  }
  if (reorderFrames >
      std::numeric_limits<std::size_t>::max() -
          decoder.impl_->options.maxInFlightFrames) {
    assignError(error, "test retained-frame bound overflows size_t");
    return false;
  }
  decoder.impl_->async->codecReorderFrames = reorderFrames;
  decoder.impl_->async->maxRetainedFrames =
      decoder.impl_->options.maxInFlightFrames + reorderFrames;
  decoder.impl_->async->nextSubmissionSequence = 0;
  decoder.impl_->async->nextCompletionSequence = 0;
  decoder.impl_->async->lastDeliveredPresentationTime = kCMTimeInvalid;
  return true;
}

bool VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
    VideoToolboxDecoder &decoder, std::size_t count, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  if (count == 0 || count > decoder.impl_->options.maxInFlightFrames) {
    assignError(error, "test submission reservation exceeds admission");
    return false;
  }
  if (decoder.impl_->async->inFlight != 0 ||
      decoder.impl_->async->nextSubmissionSequence != 0 ||
      decoder.impl_->async->nextCompletionSequence != 0 ||
      !decoder.impl_->async->completedDecodes.empty()) {
    assignError(error, "test decoder already has submitted work");
    return false;
  }
  decoder.impl_->async->inFlight = count;
  decoder.impl_->async->nextSubmissionSequence = count;
  for (std::size_t index = 0; index < count; ++index) {
    AsyncDecodeState::FrameRefConSlot &slot =
        decoder.impl_->async->frameRefConSlots[index];
    slot.state = AsyncDecodeState::FrameRefConSlotState::Submitted;
    slot.submissionSequence = index;
    slot.timing = {};
  }
  return true;
}

VideoDecodeSubmitResult
VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
    VideoToolboxDecoder &decoder, FrameTiming timing,
    std::uint64_t *submissionSequence, std::string *error,
    std::size_t compressedBytes, bool directCompressedStorage) {
  if (error != nullptr) {
    error->clear();
  }
  if (submissionSequence == nullptr) {
    assignError(error, "test submission-sequence output is null");
    return VideoDecodeSubmitResult::Rejected;
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return VideoDecodeSubmitResult::Rejected;
  }
  AsyncDecodeState::FrameRefConSlot *slot =
      decoder.impl_->reserveDecodeCapacityLocked();
  if (slot == nullptr) {
    return VideoDecodeSubmitResult::Backpressure;
  }
  if (!decoder.impl_->armFrameRefConSlotLocked(
          slot, timing,
          directCompressedStorage
              ? CompressedSubmissionStorage::DirectSampleBuffer
              : CompressedSubmissionStorage::CopiedSpan,
          compressedBytes, submissionSequence, error)) {
    return VideoDecodeSubmitResult::Rejected;
  }
  return VideoDecodeSubmitResult::Accepted;
}

bool VideoToolboxDecoderTestAccess::rejectInjectedSubmission(
    VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
    std::int32_t decodeStatus, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (decodeStatus == noErr) {
    assignError(error, "test synchronous rejection status must fail");
    return false;
  }
  AsyncDecodeState::FrameRefConSlot *slot = nullptr;
  FrameTiming timing;
  {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    const auto matching = std::find_if(
        decoder.impl_->async->frameRefConSlots.begin(),
        decoder.impl_->async->frameRefConSlots.end(),
        [submissionSequence](const AsyncDecodeState::FrameRefConSlot &entry) {
          return entry.state ==
                     AsyncDecodeState::FrameRefConSlotState::Submitted &&
                 entry.submissionSequence == submissionSequence;
        });
    if (matching == decoder.impl_->async->frameRefConSlots.end()) {
      assignError(error,
                  "test rejection has no submitted frame-refcon slot");
      return false;
    }
    slot = &*matching;
    timing = slot->timing;
  }
  // The VideoToolbox contract guarantees no output callback after an
  // immediate DecodeFrame error. Production closes that ordering gap with the
  // same no-frame completion, without entering the persistent callback.
  deliverDecodedFrame(decoder.impl_->async, slot, submissionSequence, timing,
                      static_cast<OSStatus>(decodeStatus), 0, nullptr,
                      kCMTimeInvalid, kCMTimeInvalid);
  return true;
}

VideoToolboxDecoderFrameRefConSlotStats
VideoToolboxDecoderTestAccess::frameRefConSlotStats(
    const VideoToolboxDecoder &decoder) noexcept {
  VideoToolboxDecoderFrameRefConSlotStats result;
  try {
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    result.capacity = decoder.impl_->async->frameRefConSlots.size();
    result.inFlight = decoder.impl_->async->inFlight;
    result.activeCallbacks = decoder.impl_->async->activeCallbacks;
    result.generation = decoder.impl_->async->generation;
    for (const AsyncDecodeState::FrameRefConSlot &slot :
         decoder.impl_->async->frameRefConSlots) {
      switch (slot.state) {
      case AsyncDecodeState::FrameRefConSlotState::Available:
        ++result.available;
        break;
      case AsyncDecodeState::FrameRefConSlotState::Reserved:
        ++result.reserved;
        break;
      case AsyncDecodeState::FrameRefConSlotState::Submitted:
        ++result.submitted;
        break;
      case AsyncDecodeState::FrameRefConSlotState::CallbackComplete:
        ++result.callbackComplete;
        break;
      }
    }
  } catch (...) {
    return {};
  }
  return result;
}

bool VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
    VideoToolboxDecoder &decoder, DecodedFrameSink &sink,
    std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  if (decoder.impl_->session != nullptr ||
      decoder.impl_->formatDescription != nullptr) {
    assignError(error, "test decoder owns a production decode session");
    return false;
  }
  if (decoder.impl_->configured) {
    decoder.impl_->invalidateGenerationLocked(
        decoder.impl_->currentGenerationLocked() + 1, false);
    decoder.impl_->detachLocked();
  }
  if (!reserveCallbackStorage(
          decoder.impl_->async, decoder.impl_->options.maxInFlightFrames,
          decoder.impl_->options.maxPendingPresentationFrames, error)) {
    return false;
  }

  {
    std::lock_guard deliveryLock(decoder.impl_->async->deliveryMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    decoder.impl_->configured = true;
    decoder.impl_->resetEndOfStreamLocked();
    decoder.impl_->awaitingKeyFrame = false;
    decoder.impl_->outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    decoder.impl_->async->sink = &sink;
    decoder.impl_->async->generation = generation;
    decoder.impl_->async->inFlight = 0;
    decoder.impl_->async->activeCallbacks = 0;
    decoder.impl_->async->codecReorderFrames = 0;
    decoder.impl_->async->maxRetainedFrames =
        decoder.impl_->options.maxInFlightFrames;
    decoder.impl_->async->nextSubmissionSequence = 0;
    decoder.impl_->async->nextCompletionSequence = 0;
    decoder.impl_->async->currentDirectCompressedBytes = 0;
    decoder.impl_->async->peakDirectCompressedBytes = 0;
    decoder.impl_->async->currentCopiedCompressedBytes = 0;
    decoder.impl_->async->peakCopiedCompressedBytes = 0;
    decoder.impl_->async->currentCompressedBytes = 0;
    decoder.impl_->async->peakCompressedBytes = 0;
    for (AsyncDecodeState::FrameRefConSlot &slot :
         decoder.impl_->async->frameRefConSlots) {
      slot = {};
    }
    decoder.impl_->async->completedDecodes.clear();
    decoder.impl_->async->pendingPresentationFrames.clear();
    decoder.impl_->async->outputInterop = decoder.impl_->options.outputInterop;
    decoder.impl_->async->expectedOutputPixelFormat =
        decoder.impl_->outputPixelFormat;
    decoder.impl_->async->actualOutputPixelFormat = 0;
    decoder.impl_->async->expectedCodedDimensions = {64, 32};
    decoder.impl_->async->lastDeliveredPresentationTime = kCMTimeInvalid;
    decoder.impl_->async->discarding = false;
    decoder.impl_->async->callbackFailedClosed = false;
    decoder.impl_->async->endOfStreamBackpressureRetries = 0;
    decoder.impl_->async->sinkBackpressureRetries = 0;
    decoder.impl_->async->surfaceBudgetRejections = 0;
    decoder.impl_->async->lastError.reset();
    decoder.impl_->async->failNextAllocationPoint.reset();
    decoder.impl_->async->permitSyntheticCallbackFrame = true;
    decoder.impl_->async->permitSyntheticOutputSurface = false;
  }
  sink.flush(generation);
  return true;
}

bool VideoToolboxDecoderTestAccess::injectDecodedFrame(
    VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
    CVPixelBufferRef pixelBuffer, FrameTiming timing, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  return injectDecodedFrameResult(decoder, submissionSequence, pixelBuffer,
                                  timing, noErr, 0, error);
}

bool VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
    VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
    CVPixelBufferRef pixelBuffer, FrameTiming timing,
    std::int32_t callbackStatus, std::uint32_t callbackInfoFlags,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  AsyncDecodeState::FrameRefConSlot *slot = nullptr;
  {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    if (!decoder.impl_->configured) {
      assignError(error, "test decoder is not configured");
      return false;
    }
    if (pixelBuffer == nullptr &&
        !decoder.impl_->async->permitSyntheticCallbackFrame) {
      assignError(error, "test decoded frame has no pixel buffer");
      return false;
    }
    const auto matching = std::find_if(
        decoder.impl_->async->frameRefConSlots.begin(),
        decoder.impl_->async->frameRefConSlots.end(),
        [submissionSequence](const AsyncDecodeState::FrameRefConSlot &entry) {
          return entry.state ==
                     AsyncDecodeState::FrameRefConSlotState::Submitted &&
                 entry.submissionSequence == submissionSequence;
        });
    if (matching == decoder.impl_->async->frameRefConSlots.end()) {
      assignError(error, "test callback has no submitted frame-refcon slot");
      return false;
    }
    slot = &*matching;
    slot->timing = timing;
  }
  decoder.impl_->decompressionOutputCallback(
      decoder.impl_.get(), slot, static_cast<OSStatus>(callbackStatus),
      static_cast<VTDecodeInfoFlags>(callbackInfoFlags), pixelBuffer,
      timing.presentationTime, timing.duration);
  return true;
}

bool VideoToolboxDecoderTestAccess::inspectProgressState(
    VideoToolboxDecoder &decoder, std::size_t *inFlight) noexcept {
  if (inFlight == nullptr) {
    return false;
  }
  try {
    std::unique_lock deliveryLock(decoder.impl_->async->deliveryMutex,
                                  std::try_to_lock);
    if (!deliveryLock.owns_lock()) {
      return false;
    }
    std::unique_lock stateLock(decoder.impl_->async->mutex,
                               std::try_to_lock);
    if (!stateLock.owns_lock()) {
      return false;
    }
    *inFlight = decoder.impl_->async->inFlight;
    return true;
  } catch (...) {
    return false;
  }
}

void VideoToolboxDecoderTestAccess::failNextCallbackAllocation(
    VideoToolboxDecoder &decoder,
    VideoToolboxDecoderTestAllocationPoint point) noexcept {
  try {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    decoder.impl_->async->failNextAllocationPoint = point;
  } catch (...) {
  }
}

void VideoToolboxDecoderTestAccess::failNextCFAllocation(
    VideoToolboxDecoderTestCFAllocationPoint point) noexcept {
  gFailNextCFAllocationPoint = point;
}

bool VideoToolboxDecoderTestAccess::setPermitSyntheticOutputSurface(
    VideoToolboxDecoder &decoder, bool permit, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  decoder.impl_->async->permitSyntheticOutputSurface = permit;
  return true;
}

bool VideoToolboxDecoderTestAccess::validateDecodedColorAttachments(
    CVPixelBufferRef pixelBuffer, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  return validateDecodedSdrColorAttachments(pixelBuffer, error);
}

bool VideoToolboxDecoderTestAccess::setSurfaceBudgetRejections(
    VideoToolboxDecoder &decoder, std::uint64_t count,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  decoder.impl_->async->surfaceBudgetRejections = count;
  return true;
}

bool VideoToolboxDecoderTestAccess::validateOutputSurface(
    CVPixelBufferRef pixelBuffer, OSType expectedPixelFormat,
    VideoToolboxOutputInterop outputInterop, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  return validateOutputSurfaceContract(pixelBuffer, expectedPixelFormat,
                                       outputInterop, error);
}

OSType VideoToolboxDecoderTestAccess::requestedOutputFormat(
    const VideoStreamConfiguration& configuration) noexcept {
  return requestedPixelFormat(configuration);
}

bool VideoToolboxDecoderTestAccess::admitsDecodedOutputPixelFormat(
    OSType pixelFormat, OSType expectedPixelFormat,
    VideoToolboxOutputInterop outputInterop) noexcept {
  return admitsOutputPixelFormat(pixelFormat, expectedPixelFormat,
                                 outputInterop);
}

#endif

} // namespace wam::macos
