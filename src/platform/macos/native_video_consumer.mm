#include "native_video_consumer.hpp"

#include "native_video_limits.hpp"

#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <atomic>
#include <bit>
#include <cmath>
#include <exception>
#include <limits>
#include <mutex>
#include <numeric>
#include <utility>

namespace wam::macos {
namespace {

using media::MediaGeneration;
using media::MediaTime;
using media::MediaTimeOrder;
using WideSigned = __int128_t;
using WideUnsigned = __uint128_t;

constexpr std::size_t kMaximumPresentationReorderFrames = 8;
std::mutex gQuarantineMutex;
bool gConsumerClaimed{false};
std::atomic<std::uint64_t> gRejectedCreates{0};
std::atomic<std::uint64_t> gQuarantineTransfers{0};
std::atomic<std::uint64_t> gQuarantineRecoveries{0};

void assignError(std::string* error, const char* message) {
  if (error != nullptr) {
    *error = message;
  }
}

// Exact ceiling on decoded-surface ownership for one compressed admission.
// kMaximumDecodedSurfaceOwnership is the documented share of the process-wide
// budget, raised only as far as the codec's own reorder floor requires:
// VideoToolboxDecoder::drainPresentation() delivers nothing until retention
// exceeds codecReorderFrames, so a bound at or below that floor would refuse
// the very input that produces the next presentable frame.
[[nodiscard]] std::size_t decodedSurfaceOwnershipBound(
    const VideoToolboxDecoderStats& decoder) noexcept {
  return std::max(NativeVideoConsumer::kMaximumDecodedSurfaceOwnership,
                  decoder.codecReorderFrames + 1);
}

// Decoder credit alone is not a decoded-surface bound. VideoToolbox retains
// maxInFlightFrames + codecReorderFrames decoded frames, and every retained
// frame holds one IOSurface charge from the shared
// kNativeSurfaceBudgetMaximumSurfaces pool. An audio-paced route never reached
// that ceiling because PCM-ring backpressure closed the dispatcher's merged
// read gate long before decoded read-ahead could grow. A host-paced route has
// no such throttle, so decoded read-ahead expanded until the budget saturated
// and FrameLease's acquire started failing inside the decode callback -- which
// retires the frame as an ordered budget tombstone, invisible to every
// preroll/late/superseded counter, and silently halves the drawn frame rate.
// Bounding ownership here keeps the same read-ahead as compressed bytes in the
// dispatcher's video lane, which is bounded by payload size rather than by
// scarce decoded surfaces.
[[nodiscard]] bool decodedSurfaceAdmissionOpen(
    const VideoToolboxDecoderStats& decoder) noexcept {
  const std::size_t owned =
      decoder.inFlightFrames + decoder.retainedPresentationFrames;
  return owned < decodedSurfaceOwnershipBound(decoder);
}

[[nodiscard]] WideUnsigned magnitude(WideSigned value) noexcept {
  if (value >= 0) {
    return static_cast<WideUnsigned>(value);
  }
  return static_cast<WideUnsigned>(-(value + 1)) + 1;
}

[[nodiscard]] WideUnsigned wideGcd(WideUnsigned lhs,
                                   WideUnsigned rhs) noexcept {
  while (rhs != 0) {
    const WideUnsigned remainder = lhs % rhs;
    lhs = rhs;
    rhs = remainder;
  }
  return lhs;
}

[[nodiscard]] std::optional<MediaTime> checkedTimeSum(
    MediaTime lhs, MediaTime rhs) noexcept {
  if (!lhs.valid() || !rhs.valid()) {
    return std::nullopt;
  }
  const std::uint64_t lhsScale =
      static_cast<std::uint32_t>(lhs.timescale);
  const std::uint64_t rhsScale =
      static_cast<std::uint32_t>(rhs.timescale);
  const std::uint64_t divisor = std::gcd(lhsScale, rhsScale);
  const std::uint64_t lhsFactor = rhsScale / divisor;
  const std::uint64_t rhsFactor = lhsScale / divisor;
  const std::uint64_t commonScale = lhsScale * lhsFactor;
  WideSigned numerator =
      static_cast<WideSigned>(lhs.value) * lhsFactor +
      static_cast<WideSigned>(rhs.value) * rhsFactor;
  WideUnsigned reduction = wideGcd(
      magnitude(numerator), static_cast<WideUnsigned>(commonScale));
  if (reduction == 0) {
    reduction = 1;
  }
  numerator /= static_cast<WideSigned>(reduction);
  const WideUnsigned scale =
      static_cast<WideUnsigned>(commonScale) / reduction;
  if (scale == 0 ||
      scale > static_cast<WideUnsigned>(
                  std::numeric_limits<std::int32_t>::max()) ||
      numerator < static_cast<WideSigned>(
                      std::numeric_limits<std::int64_t>::min()) ||
      numerator > static_cast<WideSigned>(
                      std::numeric_limits<std::int64_t>::max())) {
    return std::nullopt;
  }
  return MediaTime{static_cast<std::int64_t>(numerator),
                   static_cast<std::int32_t>(scale)};
}

[[nodiscard]] std::optional<MediaTime> exactMediaTime(CMTime time) noexcept {
  if (!CMTIME_IS_NUMERIC(time) || time.timescale <= 0 || time.epoch != 0 ||
      (time.flags & kCMTimeFlags_HasBeenRounded) != 0) {
    return std::nullopt;
  }
  return MediaTime{time.value, time.timescale};
}

[[nodiscard]] bool sameExactCMTime(CMTime lhs, CMTime rhs) noexcept {
  return lhs.value == rhs.value && lhs.timescale == rhs.timescale &&
         lhs.flags == rhs.flags && lhs.epoch == rhs.epoch;
}

[[nodiscard]] bool sameFrameTiming(const FrameTiming& lhs,
                                   const FrameTiming& rhs) noexcept {
  return lhs.generation == rhs.generation &&
         lhs.keyFrame == rhs.keyFrame &&
         sameExactCMTime(lhs.presentationTime, rhs.presentationTime) &&
         sameExactCMTime(lhs.duration, rhs.duration);
}

// Compares an exact media rational with the exact binary rational represented
// by a finite double. No epsilon or intermediate floating-point rounding is
// introduced. Products that cannot fit 128 bits are already far enough apart
// in magnitude to decide their order.
[[nodiscard]] std::optional<MediaTimeOrder> compareTimeToDouble(
    MediaTime lhs, double rhs) noexcept {
  if (!lhs.valid() || !std::isfinite(rhs) || rhs < 0.0) {
    return std::nullopt;
  }
  if (lhs.value < 0) {
    return MediaTimeOrder::Less;
  }
  if (rhs == 0.0) {
    return lhs.value == 0 ? MediaTimeOrder::Equal
                          : MediaTimeOrder::Greater;
  }
  if (lhs.value == 0) {
    return MediaTimeOrder::Less;
  }

  const std::uint64_t bits = std::bit_cast<std::uint64_t>(rhs);
  const std::uint64_t exponentBits = (bits >> 52U) & 0x7ffU;
  const std::uint64_t fraction = bits & ((std::uint64_t{1} << 52U) - 1U);
  const std::uint64_t significand =
      exponentBits == 0 ? fraction
                        : (std::uint64_t{1} << 52U) | fraction;
  const int exponent = exponentBits == 0
                           ? -1074
                           : static_cast<int>(exponentBits) - 1023 - 52;
  if (significand == 0) {
    return lhs.value == 0 ? MediaTimeOrder::Equal
                          : MediaTimeOrder::Greater;
  }

  constexpr WideUnsigned kWideMaximum =
      ~static_cast<WideUnsigned>(0);
  const WideUnsigned exactValue =
      static_cast<std::uint64_t>(lhs.value);
  const WideUnsigned scaledSignificand =
      static_cast<WideUnsigned>(
          static_cast<std::uint32_t>(lhs.timescale)) *
      significand;
  WideUnsigned left = exactValue;
  WideUnsigned right = scaledSignificand;
  if (exponent >= 0) {
    const unsigned shift = static_cast<unsigned>(exponent);
    if (shift >= 128U || right > (kWideMaximum >> shift)) {
      return MediaTimeOrder::Less;
    }
    right <<= shift;
  } else {
    const unsigned shift = static_cast<unsigned>(-exponent);
    if (left != 0 &&
        (shift >= 128U || left > (kWideMaximum >> shift))) {
      return MediaTimeOrder::Greater;
    }
    left <<= shift;
  }
  if (left < right) {
    return MediaTimeOrder::Less;
  }
  if (left > right) {
    return MediaTimeOrder::Greater;
  }
  return MediaTimeOrder::Equal;
}

[[nodiscard]] bool validTimeline(
    const media::NativeMediaGenerationTimeline& timeline,
    MediaGeneration generation, MediaTime duration) noexcept {
  if (generation == 0 || timeline.generation != generation ||
      !timeline.requestedTarget.valid() ||
      !timeline.actualDecodeStart.valid() ||
      !timeline.presentationFloor.valid() || !duration.valid()) {
    return false;
  }
  constexpr MediaTime kOrigin{0, 1};
  const auto targetOrigin =
      media::compareMediaTime(timeline.requestedTarget, kOrigin);
  const auto targetDuration =
      media::compareMediaTime(timeline.requestedTarget, duration);
  const auto startOrigin =
      media::compareMediaTime(timeline.actualDecodeStart, kOrigin);
  const auto startTarget = media::compareMediaTime(
      timeline.actualDecodeStart, timeline.requestedTarget);
  const auto startDuration =
      media::compareMediaTime(timeline.actualDecodeStart, duration);
  if (!targetOrigin || *targetOrigin == MediaTimeOrder::Less ||
      !targetDuration || *targetDuration == MediaTimeOrder::Greater ||
      !startOrigin || *startOrigin == MediaTimeOrder::Less ||
      !startTarget || *startTarget == MediaTimeOrder::Greater ||
      !startDuration || *startDuration == MediaTimeOrder::Greater ||
      timeline.startsAtStreamOrigin !=
          (*startOrigin == MediaTimeOrder::Equal)) {
    return false;
  }
  switch (timeline.mode) {
  case media::MediaSeekMode::Accurate:
    return media::compareMediaTime(timeline.presentationFloor,
                                   timeline.requestedTarget) ==
           MediaTimeOrder::Equal;
  case media::MediaSeekMode::KeyFrame:
    return media::compareMediaTime(timeline.presentationFloor,
                                   timeline.actualDecodeStart) ==
           MediaTimeOrder::Equal;
  }
  return false;
}

[[nodiscard]] bool supportedVideoTrack(
    const media::MediaTrackDescriptor& track) noexcept {
  if (track.id == 0 || track.kind != media::MediaTrackKind::Video ||
      !track.video || !track.timeBase.valid() || track.timeBase.value <= 0 ||
      !track.duration.valid() || track.duration.value < 0 ||
      (track.codec != media::MediaCodec::H264 &&
       track.codec != media::MediaCodec::Hevc) ||
      !native_video_limits::acceptsVideoCodecConfigurationSize(
          track.codecConfiguration.size()) ||
      (track.codec == media::MediaCodec::H264 &&
       track.codecConfigurationKind !=
           media::MediaCodecConfigurationKind::AvcC) ||
      (track.codec == media::MediaCodec::Hevc &&
       track.codecConfigurationKind !=
           media::MediaCodecConfigurationKind::HvcC)) {
    return false;
  }
  const media::MediaVideoFormat& video = *track.video;
  const std::uint64_t pixels =
      static_cast<std::uint64_t>(video.codedWidth) * video.codedHeight;
  const bool supportedColor =
      (video.colorPrimaries == media::MediaColorPrimaries::Unknown ||
       video.colorPrimaries == media::MediaColorPrimaries::Bt709) &&
      (video.transferFunction == media::MediaTransferFunction::Unknown ||
       video.transferFunction == media::MediaTransferFunction::Bt709) &&
      (video.matrixCoefficients ==
           media::MediaMatrixCoefficients::Unknown ||
       video.matrixCoefficients == media::MediaMatrixCoefficients::Bt601 ||
       video.matrixCoefficients == media::MediaMatrixCoefficients::Bt709) &&
      (video.topFieldChromaLocation ==
           media::MediaChromaLocation::Unspecified ||
       video.topFieldChromaLocation == media::MediaChromaLocation::Left ||
       video.topFieldChromaLocation == media::MediaChromaLocation::Center) &&
      (video.bottomFieldChromaLocation ==
           media::MediaChromaLocation::Unspecified ||
       video.bottomFieldChromaLocation == media::MediaChromaLocation::Left ||
       video.bottomFieldChromaLocation ==
           media::MediaChromaLocation::Center) &&
      (video.bitsPerComponent == 0 || video.bitsPerComponent == 8 ||
       video.bitsPerComponent == 10);
  return video.codedWidth != 0 && video.codedHeight != 0 &&
         video.codedWidth <=
             media::MediaSourceLimits::kHardMaximumCodedWidth &&
         video.codedHeight <=
             media::MediaSourceLimits::kHardMaximumCodedHeight &&
         pixels <= media::MediaSourceLimits::kHardMaximumCodedPixels &&
         video.displayWidth != 0 && video.displayHeight != 0 &&
         video.identityTransform && video.progressive && supportedColor &&
         !video.unsupportedColorMetadataPresent &&
         !video.dolbyVisionConfigurationPresent &&
         (video.sampleFormat ==
              media::MediaVideoSampleFormat::Yuv420EightBit ||
          video.sampleFormat ==
              media::MediaVideoSampleFormat::Yuv420TenBit) &&
         media::mediaVideoHasFullCodedAperture(video) &&
         media::mediaVideoHasSquarePixels(video);
}

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

[[nodiscard]] bool sampleTimingMatches(
    CMSampleBufferRef nativeSample,
    const media::MediaSample& sample) noexcept {
  if (nativeSample == nullptr || !CMSampleBufferDataIsReady(nativeSample) ||
      CMSampleBufferGetNumSamples(nativeSample) != 1) {
    return false;
  }
  const auto presentation = exactMediaTime(
      CMSampleBufferGetPresentationTimeStamp(nativeSample));
  const auto duration = exactMediaTime(CMSampleBufferGetDuration(nativeSample));
  if (!presentation || !duration || *presentation != sample.presentationTime ||
      *duration != sample.duration) {
    return false;
  }
  const CMTime nativeDecode = CMSampleBufferGetDecodeTimeStamp(nativeSample);
  if (sample.decodeTime.valid()) {
    const auto decode = exactMediaTime(nativeDecode);
    if (!decode || *decode != sample.decodeTime) {
      return false;
    }
  } else if (CMTIME_IS_NUMERIC(nativeDecode)) {
    return false;
  }
  bool keyFrame = false;
  return sampleIsKeyFrame(nativeSample, &keyFrame) &&
         keyFrame == sample.keyFrame;
}

// Random access into an open-GOP stream begins on a picture whose *leading*
// pictures follow it in decode order but present before it. HEVC calls them
// RASL/RADL; x265 emits them at every CRA, while the closed-GOP H.264 streams
// this route was first proven against never produce the shape. When the
// random-access point itself starts the decode, VideoToolbox has none of the
// pictures those leading pictures reference and answers
// kVTVideoDecoderReferenceMissingErr, which the decoder correctly reports as a
// hard callback failure. The stream is not broken: HEVC states that leading
// pictures associated with a random-access point that begins the bitstream are
// not output and need not be decodable, and no later picture may reference
// them. They also present strictly before that random-access point, which the
// source located at or before the generation's presentation floor, so they can
// never become a visible frame. Recognize them from timing alone and drop them
// as compressed preroll rather than submitting an undecodable access unit.
[[nodiscard]] bool leadingPictureBeforeGenerationStart(
    MediaTime presentation, bool keyFrame,
    const std::optional<MediaTime>& generationStart) noexcept {
  if (keyFrame || !generationStart) {
    return false;
  }
  const auto order = media::compareMediaTime(presentation, *generationStart);
  return order && *order == MediaTimeOrder::Less;
}

enum class Lifecycle : std::uint8_t {
  None,
  Flush,
  Retire,
  Cancel,
  Close,
};

enum class PumpStatus : std::uint8_t {
  Idle,
  Progress,
  MatchedFrameFailure,
  Blocked,
  Stale,
  Failed,
};

[[nodiscard]] media::NativeMediaConsumerProgress mapOutputProgress(
    NativeTrackedVideoOutputProgress progress) noexcept {
  switch (progress) {
  case NativeTrackedVideoOutputProgress::Done:
    return media::NativeMediaConsumerProgress::Done;
  case NativeTrackedVideoOutputProgress::Quiescing:
    return media::NativeMediaConsumerProgress::Quiescing;
  case NativeTrackedVideoOutputProgress::StaleGeneration:
    return media::NativeMediaConsumerProgress::StaleGeneration;
  case NativeTrackedVideoOutputProgress::Failed:
    return media::NativeMediaConsumerProgress::Failed;
  }
  return media::NativeMediaConsumerProgress::Failed;
}

}  // namespace

class NativeVideoConsumer::Sink final : public DecodedFrameSink {
 public:
  [[nodiscard]] FrameEnqueueResult enqueue(
      FrameLease frame, std::string* error) override {
    if (!frame || frame.timing().generation != generation_ || ended_) {
      assignError(error, "decoded video frame is stale or invalid");
      return FrameEnqueueResult::Rejected;
    }
    if (frame_) {
      return FrameEnqueueResult::Backpressure;
    }
    frame_.emplace(std::move(frame));
    return FrameEnqueueResult::Accepted;
  }

  void endOfStream(std::uint64_t generation) override {
    if (generation == generation_) {
      ended_ = true;
    }
  }

  void flush(std::uint64_t nextGeneration) noexcept override {
    frame_.reset();
    generation_ = nextGeneration;
    ended_ = false;
  }

  [[nodiscard]] std::optional<FrameLease> take() noexcept {
    std::optional<FrameLease> result = std::move(frame_);
    frame_.reset();
    return result;
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return frame_.has_value() ? 1U : 0U;
  }

  [[nodiscard]] bool ended() const noexcept {
    return ended_ && !frame_;
  }

  [[nodiscard]] std::uint64_t generation() const noexcept {
    return generation_;
  }

 private:
  std::optional<FrameLease> frame_;
  std::uint64_t generation_{0};
  bool ended_{false};
};

struct NativeVideoConsumer::Impl {
  Impl(std::shared_ptr<void> lifetime,
       NativeVideoClockSeam mediaClock,
       std::shared_ptr<NativeTrackedVideoOutput> trackedOutput,
       NativeVideoConsumerWakeSeam wakeSeam)
      : externalLifetime(std::move(lifetime)),
        clock(mediaClock),
        output(std::move(trackedOutput)),
        wake(wakeSeam),
        decoder(VideoToolboxDecoderOptions{
            NativeVideoConsumer::kMaximumDecoderInFlightFrames,
            kMaximumPresentationReorderFrames,
            VideoToolboxOutputInterop::OpenGL,
            VideoToolboxDecoderProgressHandler{wake.signal, wake.context}}) {}

  void latch(NativeVideoConsumerFailure value) noexcept {
    if (failure == NativeVideoConsumerFailure::None) {
      failure = value;
    }
  }

  [[nodiscard]] bool failed() const noexcept {
    return failure != NativeVideoConsumerFailure::None;
  }

  void clearPreviewHandoff() noexcept {
    previewQuiesceGeneration = 0;
    previewReleasedGeneration = 0;
    previewQuiesceStarted = false;
    previewQuiesced = false;
    previewDecoderFlushed = false;
    previewResumeNeedsKeyFrame = false;
  }

  [[nodiscard]] bool previewAdmissionGated() const noexcept {
    return previewQuiesceStarted;
  }

  [[nodiscard]] bool refreshClock() noexcept {
    const NativeMediaClockSnapshot sampled = clock.sample(clock.context);
    if (sampled.publicationCurrent && sampled.valid &&
        sampled.generation == generation &&
        std::isfinite(sampled.mediaSeconds) && sampled.mediaSeconds >= 0.0 &&
        std::isfinite(sampled.rate) && sampled.rate > 0.0) {
      currentClock = sampled;
    }
    return currentClock && currentClock->valid &&
           currentClock->generation == generation;
  }

  void clearDueHint() noexcept {
    nextDueMediaTime = {};
    nextDueHostTicks = 0;
    nextDueKnown = false;
  }

  void setDueHint(MediaTime presentation) noexcept {
    clearDueHint();
    if (!currentClock || !currentClock->running ||
        currentClock->rate <= 0.0) {
      return;
    }
    const auto seconds = media::mediaTimeSeconds(presentation);
    if (!seconds || *seconds <= currentClock->mediaSeconds) {
      return;
    }
    const double ticks =
        ((*seconds - currentClock->mediaSeconds) / currentClock->rate) *
        static_cast<double>(clock.ticksPerSecond);
    if (!std::isfinite(ticks) || ticks <= 0.0 ||
        ticks > static_cast<double>(
                    std::numeric_limits<std::uint64_t>::max())) {
      return;
    }
    const double roundedUp = std::ceil(ticks);
    const auto delta = static_cast<std::uint64_t>(roundedUp);
    if (delta > std::numeric_limits<std::uint64_t>::max() -
                    currentClock->sampledHostTicks) {
      return;
    }
    nextDueMediaTime = presentation;
    nextDueHostTicks = currentClock->sampledHostTicks + delta;
    nextDueKnown = true;
  }

  [[nodiscard]] PumpStatus consumeOutputEvent() noexcept {
    const auto protocolFailure = [this]() noexcept {
      latch(NativeVideoConsumerFailure::Output);
      outputProtocolViolation = true;
      return PumpStatus::Failed;
    };
    if (output == nullptr) {
      return protocolFailure();
    }
    const std::optional<NativeTrackedVideoEvent> event = output->takeEvent();
    if (!event) {
      return PumpStatus::Idle;
    }
    if (event->eventSequence == 0 ||
        event->eventSequence <= lastOutputEventSequence) {
      return protocolFailure();
    }
    lastOutputEventSequence = event->eventSequence;
    switch (event->kind) {
    case NativeTrackedVideoEventKind::FrameDrawn:
    case NativeTrackedVideoEventKind::FrameSuperseded:
      if (!awaitingDraw.valid() || event->frameSequence != awaitingDraw ||
          event->generation != awaitingTiming.generation ||
          !sameFrameTiming(event->timing, awaitingTiming) ||
          (event->kind == NativeTrackedVideoEventKind::FrameSuperseded &&
           lifecycle == Lifecycle::None)) {
        return protocolFailure();
      }
      if (event->kind == NativeTrackedVideoEventKind::FrameDrawn) {
        ++drawnFrames;
      }
      awaitingDraw = {};
      awaitingTiming = {};
      lastTerminalEvent = event;
      return PumpStatus::Progress;
    case NativeTrackedVideoEventKind::GenerationInvalidated:
      if (event->frameSequence.valid()) {
        return protocolFailure();
      }
      if (event->generation == 0 ||
          (event->generation != armGeneration &&
           event->generation != generation &&
           event->generation != flushTarget &&
           event->generation != retirementRetired &&
           event->generation != terminalGeneration &&
           (!completedFlush ||
            event->generation != completedFlushTarget))) {
        return protocolFailure();
      }
      return PumpStatus::Progress;
    case NativeTrackedVideoEventKind::Closed:
      if (event->frameSequence.valid() || terminalGeneration == 0 ||
          event->generation != terminalGeneration ||
          (lifecycle != Lifecycle::Retire &&
           lifecycle != Lifecycle::Cancel && lifecycle != Lifecycle::Close)) {
        return protocolFailure();
      }
      return PumpStatus::Progress;
    case NativeTrackedVideoEventKind::Failed:
      if (!awaitingDraw.valid() || event->frameSequence != awaitingDraw ||
          event->generation != awaitingTiming.generation ||
          !sameFrameTiming(event->timing, awaitingTiming)) {
        return protocolFailure();
      }
      // Failed is an exact terminal frame event. The output has released its
      // lease, so retire the matching compositor credit even though the route
      // remains fail-closed and will require terminal retirement/quarantine.
      awaitingDraw = {};
      awaitingTiming = {};
      lastTerminalEvent = event;
      matchedFrameFailure = true;
      latch(NativeVideoConsumerFailure::Output);
      return PumpStatus::MatchedFrameFailure;
    }
    return protocolFailure();
  }

  [[nodiscard]] PumpStatus scheduleHeld(std::string* error) {
    clearDueHint();
    // An already accepted draw only blocks *submission*. Retirement of a frame
    // the media clock has already passed must still happen, because the frame
    // is unpresentable either way and holding it is what stalls the whole
    // route: the decoded queue stays full, decoder admission stays closed, and
    // the compressed video lane can never drain. While a compositor is not
    // presenting (occluded window, background Space) that hold is unbounded,
    // so evaluate preroll/late retirement before the awaiting-draw gate and
    // let the scheduler self-drain at real time. When compositing returns, the
    // real terminal event retires the credit and the next due frame is
    // submitted immediately.
    const bool submissionBlocked = awaitingDraw.valid();
    if (!heldFrame) {
      if (submissionBlocked && sink.size() == 0) {
        return PumpStatus::Blocked;
      }
      heldFrame = sink.take();
      if (!heldFrame) {
        return submissionBlocked ? PumpStatus::Blocked : PumpStatus::Idle;
      }
    }
    const FrameTiming& timing = heldFrame->timing();
    const auto presentation = exactMediaTime(timing.presentationTime);
    const auto duration = exactMediaTime(timing.duration);
    if (!*heldFrame || timing.generation != generation || !presentation ||
        !duration || presentation->value < 0 || duration->value <= 0) {
      latch(NativeVideoConsumerFailure::InvalidFrameTiming);
      assignError(error, "decoded video frame timing is invalid");
      return PumpStatus::Failed;
    }
    const auto intervalEnd = checkedTimeSum(*presentation, *duration);
    if (!intervalEnd) {
      latch(NativeVideoConsumerFailure::InvalidFrameTiming);
      assignError(error, "decoded video frame interval is not exact");
      return PumpStatus::Failed;
    }
    const auto againstFloor =
        media::compareMediaTime(*intervalEnd, timeline.presentationFloor);
    if (!againstFloor) {
      latch(NativeVideoConsumerFailure::InvalidFrameTiming);
      return PumpStatus::Failed;
    }
    if (*againstFloor != MediaTimeOrder::Greater) {
      heldFrame.reset();
      ++discardedPrerollFrames;
      return PumpStatus::Progress;
    }
    if (!refreshClock()) {
      return PumpStatus::Blocked;
    }
    const auto endAgainstClock =
        compareTimeToDouble(*intervalEnd, currentClock->mediaSeconds);
    const auto startAgainstClock =
        compareTimeToDouble(*presentation, currentClock->mediaSeconds);
    if (!endAgainstClock || !startAgainstClock) {
      latch(NativeVideoConsumerFailure::InvalidFrameTiming);
      return PumpStatus::Failed;
    }
    if (*endAgainstClock != MediaTimeOrder::Greater) {
      heldFrame.reset();
      ++discardedLateFrames;
      return PumpStatus::Progress;
    }
    if (*startAgainstClock == MediaTimeOrder::Greater) {
      setDueHint(*presentation);
      return PumpStatus::Blocked;
    }
    if (submissionBlocked) {
      // Due, but the output still owns its accepted frame. Keep the frame; the
      // tracked-output terminal event is the armed wake for this state.
      return PumpStatus::Blocked;
    }

    switch (output->capacity(generation)) {
    case NativeTrackedVideoCapacity::Backpressure:
      return PumpStatus::Blocked;
    case NativeTrackedVideoCapacity::StaleGeneration:
      return PumpStatus::Stale;
    case NativeTrackedVideoCapacity::Failed:
      latch(NativeVideoConsumerFailure::Output);
      return PumpStatus::Failed;
    case NativeTrackedVideoCapacity::Available:
      break;
    }
    if (!nextFrameSequence.valid()) {
      latch(NativeVideoConsumerFailure::SequenceExhausted);
      assignError(error, "native video frame sequence is exhausted");
      return PumpStatus::Failed;
    }
    const NativeTrackedFrameSequence submittedSequence = nextFrameSequence;
    switch (output->submit(*heldFrame, submittedSequence, error)) {
    case NativeTrackedVideoSubmitStatus::Backpressure:
      return PumpStatus::Blocked;
    case NativeTrackedVideoSubmitStatus::StaleGeneration:
      return PumpStatus::Stale;
    case NativeTrackedVideoSubmitStatus::Failed:
      latch(NativeVideoConsumerFailure::Output);
      return PumpStatus::Failed;
    case NativeTrackedVideoSubmitStatus::Accepted:
      break;
    }
    awaitingDraw = submittedSequence;
    awaitingTiming = timing;
    heldFrame.reset();
    ++submittedFrames;
    nextFrameSequence =
        submittedSequence.value == std::numeric_limits<std::uint64_t>::max()
            ? NativeTrackedFrameSequence{}
            : NativeTrackedFrameSequence{submittedSequence.value + 1};
    return PumpStatus::Progress;
  }

  [[nodiscard]] PumpStatus pumpPresentation(bool endOfStream,
                                            std::string* error) {
    const PumpStatus event = consumeOutputEvent();
    if (event == PumpStatus::Failed ||
        event == PumpStatus::MatchedFrameFailure ||
        event == PumpStatus::Stale) {
      return event;
    }
    const PumpStatus scheduled = scheduleHeld(error);
    if (scheduled == PumpStatus::Failed || scheduled == PumpStatus::Stale) {
      return scheduled;
    }
    if (event == PumpStatus::Progress || scheduled == PumpStatus::Progress) {
      return PumpStatus::Progress;
    }
    if (heldFrame) {
      return PumpStatus::Blocked;
    }
    // An outstanding accepted draw is deliberately not a decoder-drain gate.
    // Frame ownership stays bounded at one scheduler-held lease, one decoded
    // queue lease and the output's one accepted lease exactly as before; only
    // the moment at which the queue lease is taken moves earlier. Draining
    // here is what lets a non-presenting compositor stop pinning the decoder.
    if (sink.size() != 0) {
      latch(NativeVideoConsumerFailure::Decoder);
      return PumpStatus::Failed;
    }

    VideoDecodeDrainProgress drained = endOfStream
        ? decoder.drainEndOfStream(generation, error)
        : decoder.drainPresentation(generation, error);
    switch (drained) {
    case VideoDecodeDrainProgress::StaleGeneration:
      return PumpStatus::Stale;
    case VideoDecodeDrainProgress::Failed:
      latch(NativeVideoConsumerFailure::Decoder);
      return PumpStatus::Failed;
    case VideoDecodeDrainProgress::Done:
      decoderEndOfStreamDone = true;
      break;
    case VideoDecodeDrainProgress::Progress:
    case VideoDecodeDrainProgress::Quiescing:
      break;
    }
    const PumpStatus afterDrain = scheduleHeld(error);
    if (afterDrain == PumpStatus::Failed || afterDrain == PumpStatus::Stale) {
      return afterDrain;
    }
    if (afterDrain == PumpStatus::Progress ||
        drained == VideoDecodeDrainProgress::Progress) {
      return PumpStatus::Progress;
    }
    if (afterDrain == PumpStatus::Blocked) {
      return PumpStatus::Blocked;
    }
    if (drained == VideoDecodeDrainProgress::Quiescing) {
      // Before EOS, Quiescing can mean only that the codec's bounded reorder
      // floor needs another compressed access unit. Do not turn that state
      // into a circular input stall when decoder admission is still open.
      if (!endOfStream && decoder.stats().acceptsCompressedSample) {
        return PumpStatus::Idle;
      }
      return PumpStatus::Blocked;
    }
    return PumpStatus::Idle;
  }

  // This token is intentionally first: reverse member destruction keeps every
  // raw clock/wake context alive until decoder and output teardown is over.
  std::shared_ptr<void> externalLifetime;
  const NativeVideoClockSeam clock;
  std::shared_ptr<NativeTrackedVideoOutput> output;
  const NativeVideoConsumerWakeSeam wake;
  Sink sink;
  VideoToolboxDecoder decoder;

  NativeVideoConsumerFailure failure{NativeVideoConsumerFailure::None};
  Lifecycle lifecycle{Lifecycle::None};
  MediaGeneration generation{0};
  MediaGeneration armGeneration{0};
  MediaGeneration flushRetired{0};
  MediaGeneration flushTarget{0};
  MediaGeneration completedFlushRetired{0};
  MediaGeneration completedFlushTarget{0};
  MediaGeneration terminalGeneration{0};
  media::MediaTrackId track{0};
  MediaTime trackDuration{};
  media::NativeMediaGenerationTimeline timeline{};
  media::NativeMediaGenerationTimeline flushTimeline{};
  std::optional<FrameLease> heldFrame;
  // One overwriteable observation snapshot for controller telemetry. It is
  // not compositor credit: the exact output event itself retires that credit,
  // so a controller that ignores telemetry can never stall demux or EOS.
  std::optional<NativeTrackedVideoEvent> lastTerminalEvent;
  std::optional<NativeTrackedVideoOutputFacts> retiredOutputFacts;
  std::optional<NativeMediaClockSnapshot> currentClock;
  NativeTrackedFrameSequence nextFrameSequence{1};
  NativeTrackedFrameSequence awaitingDraw{};
  FrameTiming awaitingTiming{};
  MediaTime nextDueMediaTime{};
  std::uint64_t nextDueHostTicks{0};
  std::uint64_t lastOutputEventSequence{0};
  std::uint64_t submittedFrames{0};
  std::uint64_t drawnFrames{0};
  std::uint64_t discardedPrerollFrames{0};
  std::uint64_t discardedLateFrames{0};
  std::uint64_t discardedLeadingPictures{0};
  // Exact presentation time of the random-access sample this decode started
  // on. It is set by the first admitted key frame and cleared by every
  // operation that empties VideoToolbox: configure, seek flush, and the
  // same-generation preview quiesce.
  std::optional<MediaTime> generationStartPresentation;
  bool armDone{false};
  bool armConsumed{false};
  bool configured{false};
  bool endOfStreamBegun{false};
  bool decoderEndOfStreamDone{false};
  bool endOfStreamDone{false};
  bool decoderClosed{false};
  bool flushDecoderApplied{false};
  bool completedFlush{false};
  MediaGeneration retirementRetired{0};
  MediaGeneration retirementInvalidation{0};
  bool retirementStarted{false};
  bool retirementDone{false};
  bool matchedFrameFailure{false};
  bool outputProtocolViolation{false};
  bool nextDueKnown{false};
  MediaGeneration previewQuiesceGeneration{0};
  MediaGeneration previewReleasedGeneration{0};
  bool previewQuiesceStarted{false};
  bool previewQuiesced{false};
  bool previewDecoderFlushed{false};
  bool previewResumeNeedsKeyFrame{false};
#if defined(WAM_NATIVE_VIDEO_CONSUMER_TESTING)
  // Fixture-free scheduler tests do not create a real codec configuration.
  // This proves only that the public handoff state machine treats their
  // synthetic configured scheduler as configured; shipping objects contain
  // no bypass of the decoder facts below.
  bool testSyntheticDecoderConfigured{false};
#endif
  bool cancelled{false};
  bool closed{false};
};

NativeVideoConsumer::NativeVideoConsumer(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

std::unique_ptr<NativeVideoConsumer::Impl>&
NativeVideoConsumer::quarantineSlot() noexcept {
  static std::unique_ptr<Impl> slot;
  return slot;
}

std::unique_ptr<NativeVideoConsumer> NativeVideoConsumer::create(
    std::shared_ptr<void> externalLifetime,
    NativeVideoClockSeam clock,
    std::shared_ptr<NativeTrackedVideoOutput> output,
    NativeVideoConsumerWakeSeam wake,
    std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (externalLifetime == nullptr || clock.sample == nullptr ||
      clock.ticksPerSecond == 0 || !clock.progressWakeDriven ||
      output == nullptr || wake.signal == nullptr) {
    try {
      assignError(error, "native video consumer dependencies are invalid");
    } catch (...) {
    }
    gRejectedCreates.fetch_add(1, std::memory_order_relaxed);
    return {};
  }
  {
    std::lock_guard lock(gQuarantineMutex);
    if (gConsumerClaimed || quarantineSlot() != nullptr) {
      gRejectedCreates.fetch_add(1, std::memory_order_relaxed);
      try {
        assignError(error, "a native video graph is already retained");
      } catch (...) {
      }
      return {};
    }
    gConsumerClaimed = true;
  }
  try {
    auto impl = std::make_unique<Impl>(
        std::move(externalLifetime), clock, std::move(output), wake);
    return std::unique_ptr<NativeVideoConsumer>(
        new NativeVideoConsumer(std::move(impl)));
  } catch (...) {
    {
      std::lock_guard lock(gQuarantineMutex);
      gConsumerClaimed = false;
    }
    gRejectedCreates.fetch_add(1, std::memory_order_relaxed);
    try {
      assignError(error, "native video consumer allocation failed");
    } catch (...) {
    }
    return {};
  }
}

NativeVideoConsumer::~NativeVideoConsumer() {
  if (impl_ == nullptr) {
    return;
  }
  if (close() == media::NativeMediaConsumerProgress::Done) {
    return;
  }
  std::lock_guard lock(gQuarantineMutex);
  if (quarantineSlot() == nullptr) {
    quarantineSlot() = std::move(impl_);
    gQuarantineTransfers.fetch_add(1, std::memory_order_relaxed);
  } else {
    // create() holds the process claim until this exact graph closes Done, so
    // two retiring graphs cannot reach the one-slot quarantine through the
    // public API. Do not turn an invariant violation into an unbounded graph
    // leak: callback safety and the fixed resource envelope are both strict.
    std::terminate();
  }
}

std::unique_ptr<NativeVideoConsumer>
NativeVideoConsumer::recoverQuarantined() noexcept {
  std::lock_guard lock(gQuarantineMutex);
  if (quarantineSlot() == nullptr) {
    return {};
  }
  std::unique_ptr<Impl> recovered = std::move(quarantineSlot());
  try {
    auto result = std::unique_ptr<NativeVideoConsumer>(
        new NativeVideoConsumer(std::move(recovered)));
    gQuarantineRecoveries.fetch_add(1, std::memory_order_relaxed);
    return result;
  } catch (...) {
    quarantineSlot() = std::move(recovered);
    return {};
  }
}

NativeVideoConsumerQuarantineFacts
NativeVideoConsumer::quarantineFacts() noexcept {
  NativeVideoConsumerQuarantineFacts result;
  result.rejectedCreates =
      gRejectedCreates.load(std::memory_order_relaxed);
  result.transfers =
      gQuarantineTransfers.load(std::memory_order_relaxed);
  result.recoveries =
      gQuarantineRecoveries.load(std::memory_order_relaxed);
  std::lock_guard lock(gQuarantineMutex);
  result.quarantined = quarantineSlot() != nullptr;
  return result;
}

bool NativeVideoConsumer::selectedTrackDurationsSupported(
    MediaTime audioDuration, MediaTime videoDuration) noexcept {
  return native_video_limits::acceptsSelectedTrackDurations(audioDuration,
                                                            videoDuration);
}

NativeVideoConsumerArmProgress NativeVideoConsumer::armFirstGeneration(
    MediaGeneration generation) noexcept {
  if (impl_ == nullptr || impl_->output == nullptr || generation == 0 ||
      generation == std::numeric_limits<MediaGeneration>::max()) {
    if (impl_ != nullptr) {
      impl_->latch(NativeVideoConsumerFailure::InvalidArm);
    }
    return NativeVideoConsumerArmProgress::Failed;
  }
  Impl& impl = *impl_;
  if (impl.configured || impl.armConsumed || impl.lifecycle != Lifecycle::None ||
      impl.closed || impl.failed()) {
    return NativeVideoConsumerArmProgress::Failed;
  }
  if (impl.armGeneration != 0 && impl.armGeneration != generation) {
    return NativeVideoConsumerArmProgress::StaleGeneration;
  }
  if (impl.armDone) {
    return NativeVideoConsumerArmProgress::Done;
  }
  impl.armGeneration = generation;
  // Retain the exact output operation even before dispatcher configure. A
  // close that supersedes a Quiescing pre-arm must finish this render-side
  // invalidation pair rather than issue a conflicting close operation.
  impl.flushRetired = 0;
  impl.flushTarget = generation;
  const PumpStatus pendingEvent = impl.consumeOutputEvent();
  if (pendingEvent == PumpStatus::Failed ||
      pendingEvent == PumpStatus::Stale) {
    impl.latch(NativeVideoConsumerFailure::Output);
    return NativeVideoConsumerArmProgress::Failed;
  }
  switch (impl.output->flushProgress(0, generation)) {
  case NativeTrackedVideoOutputProgress::Done: {
    const PumpStatus event = impl.consumeOutputEvent();
    if (event == PumpStatus::Failed || event == PumpStatus::Stale) {
      impl.latch(NativeVideoConsumerFailure::Output);
      return NativeVideoConsumerArmProgress::Failed;
    }
    const NativeTrackedVideoOutputFacts facts = impl.output->facts();
    if (facts.fatal || facts.closed || facts.generation != generation ||
        facts.retainedFrames != 0 ||
        facts.invalidationPending) {
      impl.latch(NativeVideoConsumerFailure::Output);
      return NativeVideoConsumerArmProgress::Failed;
    }
    impl.armDone = true;
    impl.flushRetired = 0;
    impl.flushTarget = 0;
    return NativeVideoConsumerArmProgress::Done;
  }
  case NativeTrackedVideoOutputProgress::Quiescing:
    return NativeVideoConsumerArmProgress::Quiescing;
  case NativeTrackedVideoOutputProgress::StaleGeneration:
    return NativeVideoConsumerArmProgress::StaleGeneration;
  case NativeTrackedVideoOutputProgress::Failed:
    impl.latch(NativeVideoConsumerFailure::Output);
    return NativeVideoConsumerArmProgress::Failed;
  }
  impl.latch(NativeVideoConsumerFailure::Output);
  return NativeVideoConsumerArmProgress::Failed;
}

NativeVideoConsumerPreviewProgress
NativeVideoConsumer::quiesceForPreview(MediaGeneration generation) noexcept {
  if (impl_ == nullptr || generation == 0) {
    return NativeVideoConsumerPreviewProgress::Failed;
  }
  Impl& impl = *impl_;
  if (generation != impl.generation) {
    return NativeVideoConsumerPreviewProgress::StaleGeneration;
  }
  if (impl.previewQuiesceStarted) {
    if (impl.previewQuiesceGeneration != generation) {
      return NativeVideoConsumerPreviewProgress::StaleGeneration;
    }
    if (impl.previewQuiesced) {
      return NativeVideoConsumerPreviewProgress::Done;
    }
  } else {
    if (!impl.configured || impl.failed() || impl.closed || impl.cancelled ||
        impl.endOfStreamBegun || impl.lifecycle != Lifecycle::None ||
        impl.output == nullptr) {
      return NativeVideoConsumerPreviewProgress::Failed;
    }
    // This is the admission linearization point. No dispatcher-facing call
    // can accept another compressed sample after the owner begins handoff.
    impl.previewQuiesceGeneration = generation;
    impl.previewReleasedGeneration = 0;
    impl.previewQuiesceStarted = true;
    impl.previewQuiesced = false;
    impl.previewResumeNeedsKeyFrame = false;
  }

  if (!impl.previewDecoderFlushed) {
    // Same-generation flush is deliberate: it synchronously retires every VT
    // callback and decoder/sink lease while preserving playback lineage. It
    // does not call the tracked output's flush/close lifecycle.
    impl.decoder.flush(generation);
    impl.heldFrame.reset();
    impl.currentClock.reset();
    impl.clearDueHint();
    impl.generationStartPresentation.reset();
    impl.previewDecoderFlushed = true;
  }

  const VideoToolboxDecoderStats decoderFacts = impl.decoder.stats();
  bool decoderConfigured = decoderFacts.configured;
#if defined(WAM_NATIVE_VIDEO_CONSUMER_TESTING)
  decoderConfigured =
      decoderConfigured || impl.testSyntheticDecoderConfigured;
#endif
  if (!decoderConfigured || decoderFacts.generation != generation ||
      decoderFacts.inFlightFrames != 0 ||
      decoderFacts.retainedPresentationFrames != 0 ||
      decoderFacts.pendingPresentationFrames != 0 ||
      impl.sink.generation() != generation || impl.sink.size() != 0 ||
      impl.heldFrame) {
    impl.latch(NativeVideoConsumerFailure::Decoder);
    return NativeVideoConsumerPreviewProgress::Failed;
  }

  const PumpStatus event = impl.consumeOutputEvent();
  if (event == PumpStatus::Failed ||
      event == PumpStatus::MatchedFrameFailure) {
    return NativeVideoConsumerPreviewProgress::Failed;
  }
  if (event == PumpStatus::Stale) {
    return NativeVideoConsumerPreviewProgress::StaleGeneration;
  }
  if (impl.output == nullptr) {
    impl.latch(NativeVideoConsumerFailure::Output);
    return NativeVideoConsumerPreviewProgress::Failed;
  }
  const NativeTrackedVideoOutputFacts outputFacts = impl.output->facts();
  if (outputFacts.fatal || outputFacts.closed ||
      outputFacts.generation != generation ||
      outputFacts.invalidationPending) {
    impl.latch(NativeVideoConsumerFailure::Output);
    return NativeVideoConsumerPreviewProgress::Failed;
  }

  if (impl.awaitingDraw.valid()) {
    if (outputFacts.retainedFrames != 1 ||
        outputFacts.admittedFrame != impl.awaitingDraw) {
      impl.latch(NativeVideoConsumerFailure::Output);
      return NativeVideoConsumerPreviewProgress::Failed;
    }
    return event == PumpStatus::Progress
               ? NativeVideoConsumerPreviewProgress::Progress
               : NativeVideoConsumerPreviewProgress::Quiescing;
  }
  if (outputFacts.retainedFrames != 0 ||
      outputFacts.admittedFrame.valid()) {
    impl.latch(NativeVideoConsumerFailure::Output);
    return NativeVideoConsumerPreviewProgress::Failed;
  }
  // A render publication may race the takeEvent()/facts() boundary. Its wake
  // is already armed, so do not declare Done until that mailbox is empty.
  if (outputFacts.eventPending) {
    return event == PumpStatus::Progress
               ? NativeVideoConsumerPreviewProgress::Progress
               : NativeVideoConsumerPreviewProgress::Quiescing;
  }

  impl.previewQuiesced = true;
  return NativeVideoConsumerPreviewProgress::Done;
}

NativeVideoConsumerPreviewProgress
NativeVideoConsumer::releasePreviewQuiesce(
    MediaGeneration generation,
    NativeVideoConsumerPreviewRelease release) noexcept {
  if (impl_ == nullptr || generation == 0) {
    return NativeVideoConsumerPreviewProgress::Failed;
  }
  Impl& impl = *impl_;
  if (!impl.previewQuiesceStarted) {
    if (impl.previewReleasedGeneration == generation) {
      return NativeVideoConsumerPreviewProgress::Done;
    }
    if (impl.previewReleasedGeneration != 0 ||
        generation != impl.generation) {
      return NativeVideoConsumerPreviewProgress::StaleGeneration;
    }
    return NativeVideoConsumerPreviewProgress::Failed;
  }
  if (impl.previewQuiesceGeneration != generation ||
      generation != impl.generation) {
    return NativeVideoConsumerPreviewProgress::StaleGeneration;
  }
  if (!impl.previewQuiesced) {
    const NativeVideoConsumerPreviewProgress quiescing =
        quiesceForPreview(generation);
    if (quiescing != NativeVideoConsumerPreviewProgress::Done) {
      return quiescing;
    }
  }
  if (release !=
      NativeVideoConsumerPreviewRelease::NextSampleIsKeyFrame) {
    return NativeVideoConsumerPreviewProgress::KeyFrameRequired;
  }
  if (impl.failed() || impl.closed || impl.cancelled ||
      impl.lifecycle != Lifecycle::None || impl.output == nullptr) {
    return NativeVideoConsumerPreviewProgress::Failed;
  }
  const VideoToolboxDecoderStats decoderFacts = impl.decoder.stats();
  bool decoderConfigured = decoderFacts.configured;
#if defined(WAM_NATIVE_VIDEO_CONSUMER_TESTING)
  decoderConfigured =
      decoderConfigured || impl.testSyntheticDecoderConfigured;
#endif
  const NativeTrackedVideoOutputFacts outputFacts = impl.output->facts();
  if (!decoderConfigured || decoderFacts.generation != generation ||
      !decoderFacts.awaitingKeyFrame || decoderFacts.inFlightFrames != 0 ||
      decoderFacts.retainedPresentationFrames != 0 ||
      decoderFacts.pendingPresentationFrames != 0 ||
      outputFacts.fatal || outputFacts.closed ||
      outputFacts.generation != generation ||
      outputFacts.retainedFrames != 0 ||
      outputFacts.admittedFrame.valid() || outputFacts.eventPending ||
      outputFacts.invalidationPending || impl.awaitingDraw.valid() ||
      impl.heldFrame || impl.sink.size() != 0) {
    impl.latch(NativeVideoConsumerFailure::Lifecycle);
    return NativeVideoConsumerPreviewProgress::Failed;
  }

  impl.previewReleasedGeneration = generation;
  impl.previewQuiesceGeneration = 0;
  impl.previewQuiesceStarted = false;
  impl.previewQuiesced = false;
  impl.previewDecoderFlushed = false;
  impl.previewResumeNeedsKeyFrame = true;
  return NativeVideoConsumerPreviewProgress::Done;
}

media::NativeMediaConsumeResult NativeVideoConsumer::configure(
    const media::MediaTrackDescriptor& track,
    MediaGeneration generation,
    const media::NativeMediaGenerationTimeline& timeline,
    std::string* error) {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  Impl& impl = *impl_;
  if (generation != impl.armGeneration) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (impl.failed() || impl.configured || !impl.armDone || impl.armConsumed ||
      impl.lifecycle != Lifecycle::None) {
    assignError(error, "native video generation was not armed exactly once");
    return media::NativeMediaConsumeResult::Failed;
  }
  if (!supportedVideoTrack(track)) {
    assignError(error, "video track is outside native SDR v1");
    return media::NativeMediaConsumeResult::Unsupported;
  }
  if (!validTimeline(timeline, generation, track.duration)) {
    impl.latch(NativeVideoConsumerFailure::InvalidTimeline);
    assignError(error, "native video generation timeline is invalid");
    return media::NativeMediaConsumeResult::Failed;
  }
  const NativeTrackedVideoOutputFacts outputFacts = impl.output->facts();
  if (outputFacts.fatal || outputFacts.closed ||
      outputFacts.generation != generation ||
      outputFacts.retainedFrames != 0 ||
      outputFacts.invalidationPending) {
    impl.latch(NativeVideoConsumerFailure::Output);
    assignError(error, "native video output arm proof is invalid");
    return media::NativeMediaConsumeResult::Failed;
  }

  impl.armConsumed = true;
  impl.sink.flush(generation);
  const media::MediaVideoFormat& video = *track.video;
  const CMVideoCodecType codec = track.codec == media::MediaCodec::H264
                                     ? kCMVideoCodecType_H264
                                     : kCMVideoCodecType_HEVC;
  const VideoStreamConfiguration configuration{
      codec,
      {static_cast<std::int32_t>(video.codedWidth),
       static_cast<std::int32_t>(video.codedHeight)},
      track.codecConfiguration,
      true,
      true,
      generation};
  if (!impl.decoder.configure(configuration, impl.sink, error)) {
    impl.latch(NativeVideoConsumerFailure::DecoderConfiguration);
    return media::NativeMediaConsumeResult::Failed;
  }
  const VideoToolboxDecoderStats decoderFacts = impl.decoder.stats();
  if (!decoderFacts.configured || decoderFacts.generation != generation ||
      decoderFacts.maxInFlightFrames != kMaximumDecoderInFlightFrames ||
      decoderFacts.outputInterop != VideoToolboxOutputInterop::OpenGL) {
    impl.latch(NativeVideoConsumerFailure::DecoderConfiguration);
    assignError(error, "native video decoder configuration proof failed");
    return media::NativeMediaConsumeResult::Failed;
  }

  impl.generation = generation;
  impl.track = track.id;
  impl.trackDuration = track.duration;
  impl.timeline = timeline;
  impl.currentClock.reset();
  impl.generationStartPresentation.reset();
  impl.configured = true;
  return media::NativeMediaConsumeResult::Accepted;
}

media::NativeMediaConsumeResult NativeVideoConsumer::capacity(
    MediaGeneration generation) {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  Impl& impl = *impl_;
  if (generation != impl.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (impl.previewAdmissionGated()) {
    return media::NativeMediaConsumeResult::Backpressure;
  }
  if (!impl.configured || impl.failed() || impl.closed || impl.cancelled ||
      impl.lifecycle != Lifecycle::None) {
    return media::NativeMediaConsumeResult::Failed;
  }
  if (impl.endOfStreamBegun) {
    return impl.endOfStreamDone ? media::NativeMediaConsumeResult::Drained
                                : media::NativeMediaConsumeResult::Backpressure;
  }
  const PumpStatus pumped = impl.pumpPresentation(false, nullptr);
  switch (pumped) {
  case PumpStatus::MatchedFrameFailure:
    return media::NativeMediaConsumeResult::Failed;
  case PumpStatus::Progress:
    return media::NativeMediaConsumeResult::Draining;
  case PumpStatus::Stale:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case PumpStatus::Failed:
    return media::NativeMediaConsumeResult::Failed;
  case PumpStatus::Blocked:
    // Blocked presentation is deliberately not compressed-input backpressure.
    // This port's admission bound is decoder ownership -- five in-flight
    // frames, one decoded-queue lease and one scheduler-held lease -- not
    // whether the next frame happens to be due or whether the compositor has
    // acknowledged the last draw. Reporting Backpressure here made the whole
    // pipeline presentation-paced: the dispatcher's read gate closed on the
    // display's cadence, the PCM ring could not be refilled, and the
    // audio-owned clock stalled, which in turn stopped frames from ever
    // becoming due. Worse, when a compositor stops presenting entirely, the
    // route can reach a state with an accepted-but-undrawn frame, an empty
    // decoder and an empty scheduler, whose only wake was the draw event that
    // was never going to arrive. Admitting compressed input keeps the decoder
    // fed there, and the scheduler retires the resulting frames as the clock
    // passes them, so the route drains itself at real time instead of parking.
    break;
  case PumpStatus::Idle:
    break;
  }
  const VideoToolboxDecoderStats decoder = impl.decoder.stats();
  if (decoder.generation != generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (!decoder.configured) {
    impl.latch(NativeVideoConsumerFailure::Decoder);
    return media::NativeMediaConsumeResult::Failed;
  }
  return decoder.acceptsCompressedSample &&
                 decodedSurfaceAdmissionOpen(decoder)
             ? media::NativeMediaConsumeResult::Accepted
             : media::NativeMediaConsumeResult::Backpressure;
}

media::NativeMediaConsumeResult NativeVideoConsumer::trySample(
    media::NativeMediaSampleDelivery& delivery,
    std::string* error) {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  Impl& impl = *impl_;
  const media::MediaSample& sample = delivery.sample();
  if (sample.generation != impl.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (impl.previewAdmissionGated()) {
    return media::NativeMediaConsumeResult::Backpressure;
  }
  if (impl.previewResumeNeedsKeyFrame && !sample.keyFrame) {
    impl.latch(NativeVideoConsumerFailure::InvalidSample);
    assignError(error,
                "preview release requires the next video sample to be a "
                "key frame");
    return media::NativeMediaConsumeResult::Failed;
  }
  if (!impl.configured || impl.failed() || impl.endOfStreamBegun ||
      impl.lifecycle != Lifecycle::None || impl.closed || impl.cancelled) {
    assignError(error, "native video consumer is not accepting samples");
    return media::NativeMediaConsumeResult::Failed;
  }

  // Once the dispatcher owns a pending video sample it retries only this
  // method. Retire at most one output/decode progress edge here so a real draw
  // ack or callback completion cannot strand that pending source lease behind
  // a capacity() call the dispatcher will no longer make.
  const PumpStatus pumped = impl.pumpPresentation(false, error);
  if (pumped == PumpStatus::Stale) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (pumped == PumpStatus::Failed ||
      pumped == PumpStatus::MatchedFrameFailure) {
    return media::NativeMediaConsumeResult::Failed;
  }

  // A future/awaiting frame can intentionally stop pumpPresentation before it
  // reaches the decoder. An asynchronous decoder failure must still win over
  // that recoverable output backpressure while this delivery remains owned by
  // the dispatcher.
  if (auto decoderError = impl.decoder.takeLastError()) {
    impl.latch(NativeVideoConsumerFailure::Decoder);
    assignError(error, decoderError->c_str());
    return media::NativeMediaConsumeResult::Failed;
  }
  // Compressed admission is bounded by decoder ownership alone. It used to be
  // additionally serialized on the scheduler, the decoded queue and the
  // tracked output, which made the whole route present-one-decode-one: the
  // dispatcher's read gate then followed the display's cadence, the PCM ring
  // could not be refilled ahead of it, and the audio-owned clock ran slow or
  // stalled -- which stopped frames becoming due, which kept the gate shut.
  // It also made a compositor that stops presenting terminal: an accepted but
  // undrawn frame blocked decode, so nothing could become late, so nothing
  // could be retired, and the only wake left was the draw that was never
  // coming. Decoder credit remains the presentation-independent part of that
  // bound; decodedSurfaceAdmissionOpen() adds the resource half of it, because
  // decoder credit alone permits maxInFlightFrames + codecReorderFrames
  // decoded surfaces and that is more than this route's share of the
  // process-wide decoded-surface budget.
  const VideoToolboxDecoderStats admission = impl.decoder.stats();
  if (admission.generation != impl.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (!admission.configured) {
    impl.latch(NativeVideoConsumerFailure::Decoder);
    assignError(error, "native video decoder lost its configuration");
    return media::NativeMediaConsumeResult::Failed;
  }
  if (!admission.acceptsCompressedSample ||
      !decodedSurfaceAdmissionOpen(admission)) {
    return media::NativeMediaConsumeResult::Backpressure;
  }
  if (sample.track != impl.track ||
      sample.kind != media::MediaSampleKind::EncodedVideo ||
      sample.sampleCount != 1 || sample.presentationTime.value < 0 ||
      !sample.presentationTime.valid() || !sample.duration.valid() ||
      sample.duration.value <= 0 || !sample.payload ||
      !native_video_limits::acceptsCompressedVideoAccessUnitSize(
          sample.payload.byteSize())) {
    impl.latch(NativeVideoConsumerFailure::InvalidSample);
    assignError(error, "encoded video sample violates native v1");
    return media::NativeMediaConsumeResult::Failed;
  }
  const auto intervalEnd =
      checkedTimeSum(sample.presentationTime, sample.duration);
  const auto endAgainstFloor = intervalEnd
      ? media::compareMediaTime(*intervalEnd,
                               impl.timeline.presentationFloor)
      : std::nullopt;
  if (!intervalEnd || !endAgainstFloor) {
    impl.latch(NativeVideoConsumerFailure::InvalidSample);
    assignError(error, "encoded video sample interval is not exact");
    return media::NativeMediaConsumeResult::Failed;
  }
  const bool expectedDecodeOnly =
      impl.timeline.mode == media::MediaSeekMode::Accurate &&
      *endAgainstFloor != MediaTimeOrder::Greater;
  if (sample.decodeOnly != expectedDecodeOnly) {
    impl.latch(NativeVideoConsumerFailure::InvalidSample);
    assignError(error, "encoded video preroll marking is inconsistent");
    return media::NativeMediaConsumeResult::Failed;
  }
  // An open-GOP leading picture of the random-access sample this decode began
  // on is retired here, before it can consume decoder credit. The dispatcher
  // sees the same accepted edge a submission produces, so its compressed lane
  // keeps draining; the frame is simply never decoded, exactly as the codec
  // requires for a leading picture whose references were skipped.
  if (leadingPictureBeforeGenerationStart(sample.presentationTime,
                                          sample.keyFrame,
                                          impl.generationStartPresentation)) {
    static_cast<void>(delivery.take());
    ++impl.discardedLeadingPictures;
    return media::NativeMediaConsumeResult::Accepted;
  }
  const auto borrowed = sample.payload.borrowNative<
      media::NativePayloadKind::CoreMediaSampleBuffer>();
  if (!borrowed) {
    impl.latch(NativeVideoConsumerFailure::InvalidSample);
    assignError(error, "encoded video sample lacks CoreMedia ownership");
    return media::NativeMediaConsumeResult::Failed;
  }
  auto nativeSample = reinterpret_cast<CMSampleBufferRef>(
      const_cast<void*>(borrowed->opaqueAddress()));
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(nativeSample);
  if (!sampleTimingMatches(nativeSample, sample) || block == nullptr ||
      CMBlockBufferGetDataLength(block) != sample.payload.byteSize()) {
    impl.latch(NativeVideoConsumerFailure::InvalidSample);
    assignError(error, "CoreMedia video lease does not match sample facts");
    return media::NativeMediaConsumeResult::Failed;
  }

  switch (impl.decoder.submitCMSampleBuffer(nativeSample, sample.generation,
                                             error)) {
  case VideoDecodeSubmitResult::Backpressure:
    return media::NativeMediaConsumeResult::Backpressure;
  case VideoDecodeSubmitResult::Rejected:
    impl.latch(NativeVideoConsumerFailure::Decoder);
    return media::NativeMediaConsumeResult::Failed;
  case VideoDecodeSubmitResult::Accepted:
    static_cast<void>(delivery.take());
    if (sample.keyFrame && !impl.generationStartPresentation) {
      impl.generationStartPresentation = sample.presentationTime;
    }
    impl.previewResumeNeedsKeyFrame = false;
    return media::NativeMediaConsumeResult::Accepted;
  }
  impl.latch(NativeVideoConsumerFailure::Decoder);
  return media::NativeMediaConsumeResult::Failed;
}

media::NativeMediaConsumeResult NativeVideoConsumer::discontinuity(
    const media::MediaDiscontinuity& discontinuity,
    std::string* error) {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  if (discontinuity.generation != impl_->generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (impl_->previewAdmissionGated()) {
    return media::NativeMediaConsumeResult::Backpressure;
  }
  impl_->latch(NativeVideoConsumerFailure::UnsupportedDiscontinuity);
  assignError(error, "video discontinuities are outside native v1");
  return media::NativeMediaConsumeResult::Failed;
}

media::NativeMediaConsumeResult NativeVideoConsumer::endOfStream(
    const media::MediaEndOfStream& end,
    std::string* error) {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumeResult::Failed;
  }
  Impl& impl = *impl_;
  if (end.generation != impl.generation) {
    return media::NativeMediaConsumeResult::StaleGeneration;
  }
  if (impl.previewAdmissionGated()) {
    return media::NativeMediaConsumeResult::Backpressure;
  }
  if (impl.previewResumeNeedsKeyFrame) {
    impl.latch(NativeVideoConsumerFailure::Lifecycle);
    assignError(error,
                "preview release cannot reach end of stream before a key "
                "frame");
    return media::NativeMediaConsumeResult::Failed;
  }
  if (!impl.configured || impl.failed() || end.track != impl.track ||
      impl.lifecycle != Lifecycle::None || impl.closed || impl.cancelled) {
    impl.latch(NativeVideoConsumerFailure::Lifecycle);
    return media::NativeMediaConsumeResult::Failed;
  }
  const VideoDecodeDrainProgress begun =
      impl.decoder.beginEndOfStream(end.generation, error);
  switch (begun) {
  case VideoDecodeDrainProgress::StaleGeneration:
    return media::NativeMediaConsumeResult::StaleGeneration;
  case VideoDecodeDrainProgress::Failed:
    impl.latch(NativeVideoConsumerFailure::Decoder);
    return media::NativeMediaConsumeResult::Failed;
  case VideoDecodeDrainProgress::Done:
    impl.endOfStreamBegun = true;
    impl.decoderEndOfStreamDone = true;
    return media::NativeMediaConsumeResult::Draining;
  case VideoDecodeDrainProgress::Progress:
  case VideoDecodeDrainProgress::Quiescing:
    impl.endOfStreamBegun = true;
    return media::NativeMediaConsumeResult::Draining;
  }
  impl.latch(NativeVideoConsumerFailure::Decoder);
  return media::NativeMediaConsumeResult::Failed;
}

media::NativeMediaConsumerProgress NativeVideoConsumer::drain(
    MediaGeneration generation,
    std::string* error) {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  Impl& impl = *impl_;
  if (generation != impl.generation) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  if (impl.previewAdmissionGated()) {
    return media::NativeMediaConsumerProgress::Quiescing;
  }
  if (!impl.configured || !impl.endOfStreamBegun || impl.failed() ||
      impl.lifecycle != Lifecycle::None || impl.closed || impl.cancelled) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (impl.endOfStreamDone) {
    return media::NativeMediaConsumerProgress::Done;
  }
  const PumpStatus pumped = impl.pumpPresentation(true, error);
  switch (pumped) {
  case PumpStatus::Stale:
    return media::NativeMediaConsumerProgress::StaleGeneration;
  case PumpStatus::MatchedFrameFailure:
  case PumpStatus::Failed:
    return media::NativeMediaConsumerProgress::Failed;
  case PumpStatus::Progress:
    if (impl.decoderEndOfStreamDone && impl.sink.ended() &&
        !impl.heldFrame && !impl.awaitingDraw.valid()) {
      impl.endOfStreamDone = true;
      return media::NativeMediaConsumerProgress::Done;
    }
    return media::NativeMediaConsumerProgress::Progress;
  case PumpStatus::Blocked:
    return media::NativeMediaConsumerProgress::Quiescing;
  case PumpStatus::Idle:
    break;
  }
  if (impl.decoderEndOfStreamDone && impl.sink.ended() &&
      !impl.heldFrame && !impl.awaitingDraw.valid()) {
    impl.endOfStreamDone = true;
    return media::NativeMediaConsumerProgress::Done;
  }
  return media::NativeMediaConsumerProgress::Quiescing;
}

media::NativeMediaConsumerProgress NativeVideoConsumer::flush(
    MediaGeneration retiredGeneration,
    MediaGeneration nextGeneration,
    const media::NativeMediaGenerationTimeline& timeline) noexcept {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  Impl& impl = *impl_;
  if (impl.retirementStarted) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (impl.completedFlush &&
      impl.completedFlushRetired == retiredGeneration &&
      impl.completedFlushTarget == nextGeneration &&
      impl.timeline == timeline && impl.generation == nextGeneration) {
    return media::NativeMediaConsumerProgress::Done;
  }
  if (impl.lifecycle == Lifecycle::Flush) {
    if (impl.flushRetired != retiredGeneration ||
        impl.flushTarget != nextGeneration || impl.flushTimeline != timeline) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
  } else {
    if (impl.lifecycle != Lifecycle::None || !impl.configured ||
        impl.failed() || retiredGeneration != impl.generation ||
        nextGeneration <= retiredGeneration ||
        nextGeneration == std::numeric_limits<MediaGeneration>::max() ||
        !validTimeline(timeline, nextGeneration, impl.trackDuration)) {
      return retiredGeneration != impl.generation
                 ? media::NativeMediaConsumerProgress::StaleGeneration
                 : media::NativeMediaConsumerProgress::Failed;
    }
    // A real seek owns the decoder/output generation transition and safely
    // supersedes either phase of the same-generation preview handoff.
    impl.clearPreviewHandoff();
    impl.lifecycle = Lifecycle::Flush;
    impl.flushRetired = retiredGeneration;
    impl.flushTarget = nextGeneration;
    impl.flushTimeline = timeline;
  }
  if (!impl.flushDecoderApplied) {
    impl.decoder.flush(nextGeneration);
    impl.heldFrame.reset();
    impl.currentClock.reset();
    impl.clearDueHint();
    impl.generationStartPresentation.reset();
    impl.endOfStreamBegun = false;
    impl.decoderEndOfStreamDone = false;
    impl.endOfStreamDone = false;
    impl.flushDecoderApplied = true;
  }
  const PumpStatus event = impl.consumeOutputEvent();
  if (event == PumpStatus::Failed ||
      event == PumpStatus::MatchedFrameFailure) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (event == PumpStatus::Stale) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  const NativeTrackedVideoOutputProgress output =
      impl.output->flushProgress(retiredGeneration, nextGeneration);
  if (output != NativeTrackedVideoOutputProgress::Done) {
    const auto mapped = mapOutputProgress(output);
    if (mapped == media::NativeMediaConsumerProgress::Failed) {
      impl.latch(NativeVideoConsumerFailure::Output);
    }
    return event == PumpStatus::Progress &&
                   mapped == media::NativeMediaConsumerProgress::Quiescing
               ? media::NativeMediaConsumerProgress::Progress
               : mapped;
  }
  const NativeTrackedVideoOutputFacts outputFacts = impl.output->facts();
  if (outputFacts.fatal || outputFacts.closed ||
      outputFacts.generation != nextGeneration ||
      outputFacts.retainedFrames != 0 || outputFacts.invalidationPending ||
      impl.awaitingDraw.valid()) {
    impl.latch(NativeVideoConsumerFailure::Output);
    return media::NativeMediaConsumerProgress::Failed;
  }
  impl.completedFlushRetired = retiredGeneration;
  impl.completedFlushTarget = nextGeneration;
  impl.completedFlush = true;
  impl.generation = nextGeneration;
  impl.timeline = timeline;
  impl.lifecycle = Lifecycle::None;
  impl.flushRetired = 0;
  impl.flushTarget = 0;
  impl.flushTimeline = {};
  impl.flushDecoderApplied = false;
  return media::NativeMediaConsumerProgress::Done;
}

namespace {

void releaseConsumerClaim() noexcept {
  std::lock_guard lock(gQuarantineMutex);
  gConsumerClaimed = false;
}

template <typename ImplType>
[[nodiscard]] media::NativeMediaConsumerProgress terminalProgress(
    ImplType& impl, Lifecycle lifecycle,
    MediaGeneration expectedGeneration) noexcept {
  if (impl.closed) {
    if (lifecycle == Lifecycle::Cancel &&
        (!impl.cancelled || expectedGeneration != impl.generation)) {
      return expectedGeneration != impl.generation
                 ? media::NativeMediaConsumerProgress::StaleGeneration
                 : media::NativeMediaConsumerProgress::Failed;
    }
    return media::NativeMediaConsumerProgress::Done;
  }
  if (lifecycle == Lifecycle::Cancel && expectedGeneration != impl.generation) {
    return media::NativeMediaConsumerProgress::StaleGeneration;
  }
  if (impl.lifecycle != Lifecycle::None && impl.lifecycle != lifecycle &&
      lifecycle != Lifecycle::Close) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (impl.lifecycle != lifecycle) {
    const NativeTrackedVideoOutputFacts facts =
        impl.output == nullptr ? NativeTrackedVideoOutputFacts{}
                               : impl.output->facts();
    const MediaGeneration active = std::max(
        {impl.generation, impl.armGeneration, impl.flushTarget,
         facts.generation});
    const auto final = media::nextMediaGeneration(active);
    if (!final) {
      impl.latch(NativeVideoConsumerFailure::Lifecycle);
      return media::NativeMediaConsumerProgress::Failed;
    }
    impl.clearPreviewHandoff();
    impl.lifecycle = lifecycle;
    impl.terminalGeneration = *final;
    // Close supersedes dispatcher-visible flush configuration. A normal close
    // finishes the exact output pair below; an exact frame failure lets the
    // output's fatal-tolerant terminal close supersede that pair.
    if (lifecycle == Lifecycle::Close && impl.flushTarget != 0) {
      impl.flushTimeline = {};
    }
  }
  if (!impl.decoderClosed) {
    impl.decoder.close();
    impl.decoderClosed = true;
    impl.heldFrame.reset();
    impl.currentClock.reset();
    impl.clearDueHint();
  }
  if (impl.outputProtocolViolation) {
    return media::NativeMediaConsumerProgress::Failed;
  }

  // Dispatcher close may supersede an in-flight seek. NativeTrackedVideoOutput
  // keeps an exact flush operation pending until its render invalidation is
  // proved and intentionally does not let close silently erase that proof.
  // Finish the already-started exact pair first, then burn a strictly newer
  // terminal generation on a later owner call.
  if (impl.flushTarget != 0 && !impl.matchedFrameFailure) {
    const PumpStatus flushEvent = impl.consumeOutputEvent();
    if (flushEvent == PumpStatus::MatchedFrameFailure) {
      // The companion tracked-output contract makes terminal close supersede
      // its now-fatal pending flush. Preserve the strictly newer terminal
      // generation already derived from arm/flush target and proceed below.
      impl.flushRetired = 0;
      impl.flushTarget = 0;
      impl.flushTimeline = {};
      impl.flushDecoderApplied = false;
    } else {
      if (flushEvent == PumpStatus::Failed) {
        return media::NativeMediaConsumerProgress::Failed;
      }
      if (flushEvent == PumpStatus::Stale) {
        return media::NativeMediaConsumerProgress::StaleGeneration;
      }
      if (impl.output == nullptr) {
        impl.latch(NativeVideoConsumerFailure::Lifecycle);
        return media::NativeMediaConsumerProgress::Failed;
      }
      const NativeTrackedVideoOutputProgress flushOutput =
          impl.output->flushProgress(impl.flushRetired, impl.flushTarget);
      if (flushOutput != NativeTrackedVideoOutputProgress::Done) {
        const auto mapped = mapOutputProgress(flushOutput);
        if (mapped == media::NativeMediaConsumerProgress::Failed) {
          impl.latch(NativeVideoConsumerFailure::Output);
        }
        return flushEvent == PumpStatus::Progress &&
                       mapped == media::NativeMediaConsumerProgress::Quiescing
                   ? media::NativeMediaConsumerProgress::Progress
                   : mapped;
      }
      const NativeTrackedVideoOutputFacts flushed = impl.output->facts();
      if (flushed.fatal || flushed.closed ||
          flushed.generation != impl.flushTarget ||
          flushed.retainedFrames != 0 || flushed.invalidationPending ||
          impl.awaitingDraw.valid()) {
        impl.latch(NativeVideoConsumerFailure::Output);
        return media::NativeMediaConsumerProgress::Failed;
      }
      impl.generation = impl.flushTarget;
      impl.flushRetired = 0;
      impl.flushTarget = 0;
      impl.flushTimeline = {};
      impl.flushDecoderApplied = false;
      // The terminal generation was initially derived while the output could
      // still report retired facts. Rebase it exactly once above the generation
      // whose invalidation has now been proved.
      const auto final = media::nextMediaGeneration(impl.generation);
      if (!final) {
        impl.latch(NativeVideoConsumerFailure::Lifecycle);
        return media::NativeMediaConsumerProgress::Failed;
      }
      impl.terminalGeneration = *final;
      return media::NativeMediaConsumerProgress::Progress;
    }
  } else if (impl.flushTarget != 0) {
    // A prior owner call already consumed the exact frame failure. Do not ask
    // fatal output state to finish a nonterminal flush; final close owns its
    // supersession and render invalidation proof.
    impl.flushRetired = 0;
    impl.flushTarget = 0;
    impl.flushTimeline = {};
    impl.flushDecoderApplied = false;
  }
  const PumpStatus event = impl.consumeOutputEvent();
  if (event == PumpStatus::Failed) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  if (event == PumpStatus::MatchedFrameFailure) {
    // Exact identity/timing validation and credit retirement occurred inside
    // consumeOutputEvent. Generic fatal facts can never authorize this path.
    impl.flushRetired = 0;
    impl.flushTarget = 0;
    impl.flushTimeline = {};
    impl.flushDecoderApplied = false;
  }
  if (impl.output == nullptr) {
    impl.configured = false;
    impl.cancelled = lifecycle == Lifecycle::Cancel;
    impl.closed = true;
    impl.lifecycle = Lifecycle::None;
    releaseConsumerClaim();
    return media::NativeMediaConsumerProgress::Done;
  }
  const NativeTrackedVideoOutputProgress output =
      impl.output->closeProgress(impl.terminalGeneration);
  if (output != NativeTrackedVideoOutputProgress::Done) {
    const auto mapped = mapOutputProgress(output);
    if (mapped == media::NativeMediaConsumerProgress::Failed) {
      impl.latch(NativeVideoConsumerFailure::Output);
    }
    return event == PumpStatus::Progress &&
                   mapped == media::NativeMediaConsumerProgress::Quiescing
               ? media::NativeMediaConsumerProgress::Progress
               : mapped;
  }
  const NativeTrackedVideoOutputFacts outputFacts = impl.output->facts();
  // A frame-scoped fatal remains historical diagnostic evidence after the
  // output has terminally invalidated and released every render resource. It
  // fails playback but must not make exact close permanently impossible.
  if (impl.outputProtocolViolation ||
      (outputFacts.fatal && !impl.matchedFrameFailure) ||
      !outputFacts.closed ||
      outputFacts.generation != impl.terminalGeneration ||
      outputFacts.retainedFrames != 0 || outputFacts.invalidationPending ||
      impl.awaitingDraw.valid()) {
    impl.latch(NativeVideoConsumerFailure::Output);
    return media::NativeMediaConsumerProgress::Failed;
  }
  impl.output.reset();
  impl.configured = false;
  impl.cancelled = lifecycle == Lifecycle::Cancel;
  impl.closed = true;
  impl.lifecycle = Lifecycle::None;
  releaseConsumerClaim();
  return media::NativeMediaConsumerProgress::Done;
}

}  // namespace

media::NativeMediaConsumerProgress NativeVideoConsumer::retire(
    MediaGeneration retiredGeneration,
    MediaGeneration invalidationGeneration) noexcept {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  Impl& impl = *impl_;
  if (impl.retirementStarted) {
    if (impl.retirementRetired != retiredGeneration ||
        impl.retirementInvalidation != invalidationGeneration) {
      return media::NativeMediaConsumerProgress::StaleGeneration;
    }
    if (impl.retirementDone) {
      return media::NativeMediaConsumerProgress::Done;
    }
  } else {
    if (impl.closed || impl.cancelled ||
        (impl.lifecycle != Lifecycle::None &&
         impl.lifecycle != Lifecycle::Flush)) {
      return media::NativeMediaConsumerProgress::Failed;
    }
    const NativeTrackedVideoOutputFacts outputFacts =
        impl.output == nullptr ? NativeTrackedVideoOutputFacts{}
                               : impl.output->facts();
    const VideoToolboxDecoderStats decoderFacts = impl.decoder.stats();
    const MediaGeneration exposed = std::max(
        {impl.generation, impl.armGeneration, impl.flushTarget,
         outputFacts.generation, decoderFacts.generation});
    if (retiredGeneration != exposed || invalidationGeneration == 0 ||
        invalidationGeneration <= exposed) {
      return retiredGeneration != exposed
                 ? media::NativeMediaConsumerProgress::StaleGeneration
                 : media::NativeMediaConsumerProgress::Failed;
    }
    impl.retirementStarted = true;
    impl.clearPreviewHandoff();
    impl.retirementRetired = retiredGeneration;
    impl.retirementInvalidation = invalidationGeneration;
    impl.lifecycle = Lifecycle::Retire;
    impl.terminalGeneration = invalidationGeneration;
  }

  if (impl.outputProtocolViolation) {
    return media::NativeMediaConsumerProgress::Failed;
  }

  // Exact public retirement supersedes arm/seek output work terminally. A
  // matched frame failure is also terminal evidence; malformed failure never
  // becomes retirement authority.
  const PumpStatus event = impl.consumeOutputEvent();
  if (event == PumpStatus::Failed || event == PumpStatus::Stale) {
    return event == PumpStatus::Stale
               ? media::NativeMediaConsumerProgress::StaleGeneration
               : media::NativeMediaConsumerProgress::Failed;
  }
  if (event == PumpStatus::MatchedFrameFailure) {
    impl.matchedFrameFailure = true;
  }
  impl.flushRetired = 0;
  impl.flushTarget = 0;
  impl.flushTimeline = {};
  impl.flushDecoderApplied = false;
  impl.heldFrame.reset();
  impl.currentClock.reset();
  impl.clearDueHint();

  if (!impl.decoderClosed) {
    const MediaGeneration decoderRetired = impl.decoder.stats().generation;
    switch (impl.decoder.retire(decoderRetired, invalidationGeneration)) {
    case VideoDecoderRetireProgress::Done:
      impl.decoderClosed = true;
      break;
    case VideoDecoderRetireProgress::StaleGeneration:
      return media::NativeMediaConsumerProgress::StaleGeneration;
    case VideoDecoderRetireProgress::Failed:
      impl.latch(NativeVideoConsumerFailure::Decoder);
      return media::NativeMediaConsumerProgress::Failed;
    }
  }
  // An arm-only route has not attached Sink to VideoToolbox yet. Install the
  // exact Router invalidation here only when decoder retirement could not
  // deliver it through the configured sink.
  if (impl.sink.generation() != invalidationGeneration) {
    impl.sink.flush(invalidationGeneration);
  }
  const VideoToolboxDecoderStats decoderFacts = impl.decoder.stats();
  if (decoderFacts.configured ||
      decoderFacts.generation != invalidationGeneration ||
      decoderFacts.inFlightFrames != 0 ||
      decoderFacts.retainedPresentationFrames != 0 ||
      decoderFacts.pendingPresentationFrames != 0 ||
      impl.sink.size() != 0 || impl.heldFrame ||
      impl.sink.generation() != invalidationGeneration) {
    impl.latch(NativeVideoConsumerFailure::Decoder);
    return media::NativeMediaConsumerProgress::Failed;
  }

  if (impl.output == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  const NativeTrackedVideoOutputProgress output =
      impl.output->closeProgress(invalidationGeneration);
  if (output != NativeTrackedVideoOutputProgress::Done) {
    const auto mapped = mapOutputProgress(output);
    if (mapped == media::NativeMediaConsumerProgress::Failed) {
      impl.latch(NativeVideoConsumerFailure::Output);
    }
    return event == PumpStatus::Progress &&
                   mapped == media::NativeMediaConsumerProgress::Quiescing
               ? media::NativeMediaConsumerProgress::Progress
               : mapped;
  }
  const NativeTrackedVideoOutputFacts outputFacts = impl.output->facts();
  if (impl.outputProtocolViolation ||
      (outputFacts.fatal && !impl.matchedFrameFailure) ||
      !outputFacts.closed ||
      outputFacts.generation != invalidationGeneration ||
      outputFacts.admittedFrame.valid() || outputFacts.retainedFrames != 0 ||
      outputFacts.invalidationPending ||
      impl.awaitingDraw.valid()) {
    impl.latch(NativeVideoConsumerFailure::Output);
    return media::NativeMediaConsumerProgress::Failed;
  }

  impl.retiredOutputFacts = outputFacts;
  impl.output.reset();
  impl.generation = invalidationGeneration;
  impl.configured = false;
  impl.endOfStreamBegun = false;
  impl.decoderEndOfStreamDone = false;
  impl.endOfStreamDone = false;
  impl.closed = true;
  impl.retirementDone = true;
  releaseConsumerClaim();
  return media::NativeMediaConsumerProgress::Done;
}

media::NativeMediaConsumerProgress NativeVideoConsumer::cancel(
    MediaGeneration generation) noexcept {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumerProgress::Failed;
  }
  return terminalProgress(*impl_, Lifecycle::Cancel, generation);
}

media::NativeMediaConsumerProgress NativeVideoConsumer::close() noexcept {
  if (impl_ == nullptr) {
    return media::NativeMediaConsumerProgress::Done;
  }
  if (impl_->retirementStarted) {
    return retire(impl_->retirementRetired,
                  impl_->retirementInvalidation);
  }
  if (impl_->lifecycle == Lifecycle::Cancel) {
    return terminalProgress(*impl_, Lifecycle::Cancel, impl_->generation);
  }
  return terminalProgress(*impl_, Lifecycle::Close, impl_->generation);
}

std::optional<NativeTrackedVideoEvent>
NativeVideoConsumer::takeOutputEvent() noexcept {
  if (impl_ == nullptr) {
    return std::nullopt;
  }
  // This is an owner-thread observation API, so it must also service the raw
  // tracked-output lane. A GUI draw wake may arrive while the dispatcher is
  // otherwise servicing only audio; merely reading the consumer cache would
  // leave that cap-one wake armed forever.
  static_cast<void>(impl_->consumeOutputEvent());
  std::optional<NativeTrackedVideoEvent> result =
      std::move(impl_->lastTerminalEvent);
  impl_->lastTerminalEvent.reset();
  return result;
}

NativeVideoConsumerFacts NativeVideoConsumer::facts() const noexcept {
  NativeVideoConsumerFacts result;
  if (impl_ == nullptr) {
    result.closed = true;
    return result;
  }
  const Impl& impl = *impl_;
  result.generation = impl.generation;
  result.armedGeneration = impl.armGeneration;
  result.nextFrameSequence = impl.nextFrameSequence;
  result.awaitingDraw = impl.awaitingDraw;
  result.submittedFrames = impl.submittedFrames;
  result.drawnFrames = impl.drawnFrames;
  result.discardedPrerollFrames = impl.discardedPrerollFrames;
  result.discardedLateFrames = impl.discardedLateFrames;
  result.discardedLeadingPictures = impl.discardedLeadingPictures;
  result.nextDueMediaTime = impl.nextDueMediaTime;
  result.nextDueHostTicks = impl.nextDueHostTicks;
  result.decodedQueueDepth = impl.sink.size();
  result.configured = impl.configured;
  result.endOfStreamBegun = impl.endOfStreamBegun;
  result.endOfStreamDone = impl.endOfStreamDone;
  result.heldFrame = impl.heldFrame.has_value();
  result.outputBlocked = impl.awaitingDraw.valid() || impl.heldFrame;
  result.nextDueKnown = impl.nextDueKnown;
  result.previewQuiesceGeneration = impl.previewQuiesceGeneration;
  result.previewReleasedGeneration = impl.previewReleasedGeneration;
  result.previewQuiesceStarted = impl.previewQuiesceStarted;
  result.previewQuiesced = impl.previewQuiesced;
  result.previewResumeNeedsKeyFrame = impl.previewResumeNeedsKeyFrame;
  result.closed = impl.closed;
  result.failure = impl.failure;
  result.decoder = impl.decoder.stats();
  result.decodedFrames = result.decoder.deliveredFrames;
  if (impl.output != nullptr) {
    result.output = impl.output->facts();
  } else if (impl.retiredOutputFacts) {
    result.output = *impl.retiredOutputFacts;
  }
  result.lastOutputEventSequence =
      std::max(impl.lastOutputEventSequence,
               result.output.lastEventSequence);
  return result;
}

#if defined(WAM_NATIVE_VIDEO_CONSUMER_TESTING)
bool NativeVideoConsumerTestAccess::installSchedulerGeneration(
    NativeVideoConsumer& consumer,
    const media::NativeMediaGenerationTimeline& timeline) noexcept {
  if (consumer.impl_ == nullptr || timeline.generation == 0 ||
      consumer.impl_->armGeneration != timeline.generation ||
      !consumer.impl_->armDone || consumer.impl_->armConsumed) {
    return false;
  }
  consumer.impl_->armConsumed = true;
  consumer.impl_->generation = timeline.generation;
  consumer.impl_->timeline = timeline;
  consumer.impl_->trackDuration = {60, 1};
  consumer.impl_->sink.flush(timeline.generation);
  consumer.impl_->configured = true;
  consumer.impl_->testSyntheticDecoderConfigured = true;
  return true;
}

bool NativeVideoConsumerTestAccess::injectDecodedFrame(
    NativeVideoConsumer& consumer, FrameLease frame) noexcept {
  if (consumer.impl_ == nullptr || consumer.impl_->heldFrame ||
      consumer.impl_->sink.size() != 0) {
    return false;
  }
  std::string ignored;
  return consumer.impl_->sink.enqueue(std::move(frame), &ignored) ==
         FrameEnqueueResult::Accepted;
}

bool NativeVideoConsumerTestAccess::pumpScheduler(
    NativeVideoConsumer& consumer) noexcept {
  if (consumer.impl_ == nullptr) {
    return false;
  }
  const PumpStatus status = consumer.impl_->scheduleHeld(nullptr);
  return status != PumpStatus::Failed && status != PumpStatus::Stale;
}

std::optional<MediaTime> NativeVideoConsumerTestAccess::checkedIntervalEnd(
    MediaTime presentation, MediaTime duration) noexcept {
  return checkedTimeSum(presentation, duration);
}

std::optional<MediaTimeOrder>
NativeVideoConsumerTestAccess::compareToClock(
    MediaTime time, double clockSeconds) noexcept {
  return compareTimeToDouble(time, clockSeconds);
}

bool NativeVideoConsumerTestAccess::precedesGenerationStart(
    MediaTime presentation, bool keyFrame,
    const std::optional<MediaTime>& generationStart) noexcept {
  return leadingPictureBeforeGenerationStart(presentation, keyFrame,
                                             generationStart);
}
#endif

}  // namespace wam::macos
