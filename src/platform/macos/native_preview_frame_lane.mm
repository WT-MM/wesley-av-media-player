#include "native_preview_frame_lane.hpp"

#include "native_video_limits.hpp"

#include <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <limits>
#include <mutex>
#include <numeric>
#include <utility>
#include <variant>

namespace wam::macos {
namespace {

using media::MediaSample;
using media::MediaTime;
using media::MediaTimeOrder;
using WideSigned = __int128_t;
using WideUnsigned = __uint128_t;

constexpr std::size_t kMaximumPreviewReorderFrames = 8;
// Sequential decode is cheaper than rebuilding for normal pointer motion, but
// not for a large timeline jump. One second bounds the extra compressed work
// to a short local window while allowing an arbitrary forward drag to reuse
// the graph through many small replacements.
constexpr std::uint64_t kMaximumSequentialAdvanceSeconds = 1;

[[nodiscard]] WideUnsigned magnitude(WideSigned value) noexcept {
  return value >= 0 ? static_cast<WideUnsigned>(value)
                    : static_cast<WideUnsigned>(-(value + 1)) + 1;
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
  WideUnsigned reduction =
      wideGcd(magnitude(numerator),
              static_cast<WideUnsigned>(commonScale));
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

[[nodiscard]] bool sameTime(CMTime lhs, CMTime rhs) noexcept {
  return lhs.value == rhs.value && lhs.timescale == rhs.timescale &&
         lhs.flags == rhs.flags && lhs.epoch == rhs.epoch;
}

[[nodiscard]] bool sameTiming(const FrameTiming& lhs,
                              const FrameTiming& rhs) noexcept {
  return lhs.generation == rhs.generation &&
         lhs.keyFrame == rhs.keyFrame &&
         sameTime(lhs.presentationTime, rhs.presentationTime) &&
         sameTime(lhs.duration, rhs.duration);
}

[[nodiscard]] bool sameCommand(
    const preview_protocol::PreviewFrame& lhs,
    const preview_protocol::PreviewFrame& rhs) noexcept {
  return lhs.stamp == rhs.stamp && lhs.generation == rhs.generation &&
         lhs.gesture == rhs.gesture && lhs.request == rhs.request &&
         lhs.targetSeconds == rhs.targetSeconds;
}

[[nodiscard]] bool sameGesture(
    const preview_protocol::PreviewFrame& lhs,
    const preview_protocol::PreviewFrame& rhs) noexcept {
  return lhs.generation == rhs.generation && lhs.gesture == rhs.gesture;
}

[[nodiscard]] bool isBoundedForwardAdvance(MediaTime from,
                                           MediaTime to) noexcept {
  const auto order = media::compareMediaTime(from, to);
  if (!order.has_value() || *order == MediaTimeOrder::Greater ||
      !from.valid() || !to.valid()) {
    return false;
  }
  const WideSigned delta =
      static_cast<WideSigned>(to.value) * from.timescale -
      static_cast<WideSigned>(from.value) * to.timescale;
  const WideSigned scale =
      static_cast<WideSigned>(from.timescale) * to.timescale;
  return delta >= 0 && scale > 0 &&
         delta <= static_cast<WideSigned>(
                      kMaximumSequentialAdvanceSeconds) *
                      scale;
}

[[nodiscard]] bool canReuseForward(MediaTime oldTarget,
                                   MediaTime decodedFrontier,
                                   MediaTime newTarget) noexcept {
  const auto targetOrder = media::compareMediaTime(oldTarget, newTarget);
  const auto frontierOrder =
      media::compareMediaTime(newTarget, decodedFrontier);
  return targetOrder.has_value() &&
         *targetOrder != MediaTimeOrder::Greater &&
         frontierOrder.has_value() &&
         (*frontierOrder != MediaTimeOrder::Greater ||
          isBoundedForwardAdvance(decodedFrontier, newTarget));
}

[[nodiscard]] bool frameExtendsBeyondTarget(const FrameTiming& timing,
                                            MediaTime target) noexcept {
  const auto presentation = exactMediaTime(timing.presentationTime);
  const auto duration = exactMediaTime(timing.duration);
  const auto end = presentation && duration
                       ? checkedTimeSum(*presentation, *duration)
                       : std::optional<MediaTime>{};
  const auto order = end ? media::compareMediaTime(*end, target)
                         : std::optional<MediaTimeOrder>{};
  // Where the frame ENDS is the whole test. A frame may begin before the
  // origin (a head trim off the frame grid) and still be the one visible at
  // the target.
  return presentation && duration && duration->value > 0 &&
         order.has_value() && *order == MediaTimeOrder::Greater;
}

[[nodiscard]] const media::MediaTrackDescriptor* selectedVideoTrack(
    const NativePreviewBinding& binding) noexcept {
  if (binding.descriptor == nullptr ||
      !binding.descriptor->selectedVideo.has_value()) {
    return nullptr;
  }
  const media::MediaTrackDescriptor* track = media::findMediaTrack(
      *binding.descriptor, *binding.descriptor->selectedVideo);
  return track != nullptr && track->kind == media::MediaTrackKind::Video &&
                 track->video.has_value()
             ? track
             : nullptr;
}

[[nodiscard]] bool validBinding(
    const NativePreviewFrameLaneBinding& binding,
    const std::shared_ptr<NativeTrackedVideoPreviewPort>& output,
    NativePreviewFrameLaneWakeSeam wake) noexcept {
  const media::MediaTrackDescriptor* track =
      selectedVideoTrack(binding.source);
  return output != nullptr && wake.signal != nullptr &&
         wake.lifetime != nullptr &&
         preview_protocol::validLive(binding.activePlaybackGeneration) &&
         preview_protocol::validLive(binding.acceptedThrough) &&
         track != nullptr && track->video->codedWidth != 0 &&
         track->video->codedHeight != 0 &&
         // MPEG-2 is the one admitted codec with NO decoder configuration
         // record: its sequence header is in band and an empty vector is its
         // only correct descriptor. Every other codec must present one.
         (track->codec == media::MediaCodec::Mpeg2Video
              ? track->codecConfiguration.empty()
              : !track->codecConfiguration.empty()) &&
         (track->codec == media::MediaCodec::H264 ||
          track->codec == media::MediaCodec::Hevc ||
          track->codec == media::MediaCodec::Mpeg2Video ||
          // MPEG-4 Part 2 Simple Profile fits this lane without any new
          // machinery: the same software VideoToolbox decoder MPEG-2 uses, a
          // non-empty configuration record (the synthesized esds), and -- the
          // property that actually matters to a preview lane -- a reorder
          // depth of zero, because Simple Profile forbids B-VOPs. A scrub
          // preview decodes from a key frame forward and shows the first
          // frame it gets, so a codec that never holds a frame back is the
          // easiest case this lane has.
          track->codec == media::MediaCodec::Mpeg4Visual);
}

[[nodiscard]] CMSampleBufferRef nativeSample(
    const MediaSample& sample) noexcept {
  const auto borrowed = sample.payload.borrowNative<
      media::NativePayloadKind::CoreMediaSampleBuffer>();
  return borrowed
             ? reinterpret_cast<CMSampleBufferRef>(
                   const_cast<void*>(borrowed->opaqueAddress()))
             : nullptr;
}

}  // namespace

class PreviewFrameSink final : public DecodedFrameSink {
 public:
  struct SubmitOutcome {
    NativeTrackedVideoPreviewSubmitResult result{};
    FrameTiming timing{};
    FrameLease retainedFrame;
  };

  explicit PreviewFrameSink(NativePreviewFrameLaneWakeSeam wake) noexcept
      : wake_(wake) {}

  [[nodiscard]] FrameEnqueueResult enqueue(
      FrameLease frame, std::string* error) override {
    bool accepted = false;
    {
      std::lock_guard lock(mutex_);
      if (!frame || frame.timing().generation != generation_ || ended_) {
        if (error != nullptr) {
          try {
            error->assign("preview decoder emitted a stale frame");
          } catch (...) {
          }
        }
        return FrameEnqueueResult::Rejected;
      }
      if (frame_) {
        return FrameEnqueueResult::Backpressure;
      }
      frame_.emplace(std::move(frame));
      peak_ = std::max(peak_, std::size_t{1});
      accepted = true;
    }
    if (accepted) {
      wake_.signal(wake_.context);
    }
    return FrameEnqueueResult::Accepted;
  }

  // Owner-only restaging of the lane's already decoded, bounded alias. EOS
  // closes decoder ingress, not presentation of the same exact frame for a
  // newer pointer target inside its interval.
  [[nodiscard]] FrameEnqueueResult restageCached(
      FrameLease frame, std::string* error) noexcept {
    std::lock_guard lock(mutex_);
    if (!frame || frame.timing().generation != generation_) {
      if (error != nullptr) {
        try {
          error->assign("preview cached frame belongs to a stale generation");
        } catch (...) {
        }
      }
      return FrameEnqueueResult::Rejected;
    }
    if (frame_) {
      return FrameEnqueueResult::Backpressure;
    }
    frame_.emplace(std::move(frame));
    peak_ = std::max(peak_, std::size_t{1});
    return FrameEnqueueResult::Accepted;
  }

  void endOfStream(std::uint64_t generation) override {
    {
      std::lock_guard lock(mutex_);
      if (generation == generation_) {
        ended_ = true;
      }
    }
    wake_.signal(wake_.context);
  }

  void flush(std::uint64_t nextGeneration) noexcept override {
    std::lock_guard lock(mutex_);
    frame_.reset();
    generation_ = nextGeneration;
    ended_ = false;
  }

  [[nodiscard]] std::optional<FrameTiming> timing() const noexcept {
    std::lock_guard lock(mutex_);
    return frame_ ? std::optional<FrameTiming>{frame_->timing()}
                  : std::nullopt;
  }

  void drop() noexcept {
    std::lock_guard lock(mutex_);
    frame_.reset();
  }

  [[nodiscard]] SubmitOutcome submit(
      NativeTrackedVideoPreviewPort& output,
      std::uint64_t generation, std::string* error) noexcept {
    std::lock_guard lock(mutex_);
    if (!frame_) {
      return {{NativeTrackedVideoSubmitStatus::Failed, {}}, {}, {}};
    }
    // Clone the retry alias before output admission. A budget-publication
    // contention may legitimately fail a FrameLease copy; in that case the
    // output must remain untouched so there is no untracked terminal event.
    FrameLease retained(*frame_);
#if defined(WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING)
    if (failNextRetainedClone_) {
      failNextRetainedClone_ = false;
      retained.reset();
    }
#endif
    if (!retained || retained.pixelBuffer() != frame_->pixelBuffer()) {
      if (error != nullptr) {
        try {
          error->assign("preview frame accounting token could not be cloned");
        } catch (...) {
        }
      }
      return {{NativeTrackedVideoSubmitStatus::Failed, {}}, {}, {}};
    }
    SubmitOutcome outcome;
    outcome.timing = frame_->timing();
    outcome.result = output.submit(generation, *frame_, error);
    if (outcome.result.status == NativeTrackedVideoSubmitStatus::Accepted) {
      outcome.retainedFrame = std::move(retained);
      frame_.reset();
    }
    return outcome;
  }

  [[nodiscard]] std::size_t size() const noexcept {
    std::lock_guard lock(mutex_);
    return frame_.has_value() ? 1U : 0U;
  }

  [[nodiscard]] std::size_t peak() const noexcept {
    std::lock_guard lock(mutex_);
    return peak_;
  }

#if defined(WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING)
  void failNextRetainedCloneForTesting() noexcept {
    failNextRetainedClone_ = true;
  }
#endif

 private:
  const NativePreviewFrameLaneWakeSeam wake_;
  mutable std::mutex mutex_;
  std::optional<FrameLease> frame_;
  std::uint64_t generation_{0};
  std::size_t peak_{0};
  bool ended_{false};
#if defined(WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING)
  bool failNextRetainedClone_{false};
#endif
};

struct NativePreviewFrameLane::Impl final {
  struct Request final {
    preview_protocol::PreviewFrame command{};
    MediaTime target{};
  };

  struct Active final {
    Request request{};
    std::uint64_t epoch{0};
    MediaTime decodedFrontier{};
    std::optional<MediaSample> sample;
    NativeTrackedVideoPreviewSequence awaitingDraw{};
    FrameTiming awaitingTiming{};
    FrameLease cachedFrame;
    bool sourceEnded{false};
    bool endOfStreamBegun{false};
    bool cancelling{false};
    bool localRetired{false};
    bool presentedIdle{false};
    bool awaitingSuperseded{false};
  };

  Impl(NativePreviewFrameLaneBinding laneBinding,
       std::shared_ptr<NativeTrackedVideoPreviewPort> previewOutput,
       NativePreviewFrameLaneWakeSeam wakeSeam,
       std::unique_ptr<NativePreviewSource> previewSource,
       bool bypass)
      : binding(std::move(laneBinding)), output(std::move(previewOutput)),
        wake(wakeSeam), source(std::move(previewSource)), sink(wakeSeam),
        decoder(VideoToolboxDecoderOptions{
            1, kMaximumPreviewReorderFrames,
            VideoToolboxOutputInterop::OpenGL,
            VideoToolboxDecoderProgressHandler{wake.signal, wake.context}}),
        bypassDecoder(bypass), acceptedThrough(binding.acceptedThrough) {}

  [[nodiscard]] bool prepareDecoder() {
    if (decoderReady) {
      return true;
    }
    if (!bypassDecoder) {
      const media::MediaTrackDescriptor* track =
          selectedVideoTrack(binding.source);
      if (track == nullptr) {
        latchFailure("preview video track disappeared before decoder setup");
        return false;
      }
      const media::MediaVideoFormat& video = *track->video;
      // MPEG-2's only decoder on this platform is software, so requiring
      // hardware here fails VTDecompressionSessionCreate with -12906 on a
      // stream the main playback lane decodes perfectly well. It still
      // PREFERS hardware, exactly as the main video consumer does.
      // MPEG-4 Part 2's decoder is software for the same reason.
      const bool requireHardwareDecode =
          track->codec != media::MediaCodec::Mpeg2Video &&
          track->codec != media::MediaCodec::Mpeg4Visual;
      const VideoStreamConfiguration configuration{
          track->codec == media::MediaCodec::H264 ? kCMVideoCodecType_H264
          : track->codec == media::MediaCodec::Mpeg2Video
              ? kCMVideoCodecType_MPEG2Video
          : track->codec == media::MediaCodec::Mpeg4Visual
              ? kCMVideoCodecType_MPEG4Video
              : kCMVideoCodecType_HEVC,
          {static_cast<std::int32_t>(video.codedWidth),
           static_cast<std::int32_t>(video.codedHeight)},
          track->codecConfiguration, true, requireHardwareDecode,
          binding.activePlaybackGeneration.value};
      std::string configurationError;
      if (!decoder.configure(configuration, sink, &configurationError)) {
        latchFailure(configurationError.empty()
                         ? "preview decoder configuration failed"
                         : configurationError);
        return false;
      }
      ++decoderConfigurations;
    }
    if (bypassDecoder) {
      ++decoderConfigurations;
    }
    decoderReady = true;
    return true;
  }

  void closeDecoder() noexcept {
    if (!bypassDecoder) {
      decoder.close();
    }
    decoderReady = false;
    generationStartPresentation.reset();
  }

  // Mirrors the playback route's rule in native_video_consumer.mm. Every
  // preview epoch starts its own decode at the full-sync sample preceding the
  // target, and an open-GOP random-access point delivers its leading pictures
  // after it in decode order. Those pictures reference material this decode
  // never saw, so VideoToolbox answers kVTVideoDecoderReferenceMissingErr, and
  // they present before the target the lane is rendering. Retire them here
  // instead of submitting an access unit that cannot decode.
  [[nodiscard]] bool leadingPictureBeforeDecodeStart(
      const MediaSample& sample) const noexcept {
    if (sample.keyFrame || !generationStartPresentation) {
      return false;
    }
    const auto order = media::compareMediaTime(sample.presentationTime,
                                               *generationStartPresentation);
    return order && *order == MediaTimeOrder::Less;
  }

  void latchFailure(const char* message) noexcept {
    failed = true;
    if (error.empty()) {
      try {
        error.assign(message);
      } catch (...) {
      }
    }
    cleanupFailure();
  }

  void latchFailure(const std::string& message) noexcept {
    failed = true;
    if (error.empty()) {
      try {
        error = message;
      } catch (...) {
      }
    }
    cleanupFailure();
  }

  void retireLocal(Active& value) noexcept {
    if (value.localRetired) {
      return;
    }
    source->requestCancel(value.epoch);
    source->close();
    closeDecoder();
    sink.flush(binding.activePlaybackGeneration.value);
    value.sample.reset();
    value.cachedFrame.reset();
    value.decodedFrontier = {};
    value.localRetired = true;
  }

  void cleanupFailure() noexcept {
    pending.reset();
    presented.reset();
    if (active) {
      active->cancelling = true;
      retireLocal(*active);
    } else {
      source->close();
      closeDecoder();
      sink.flush(binding.activePlaybackGeneration.value);
    }
    static_cast<void>(output->cancel());
  }

  void advanceDecodedFrontier(Active& value, MediaTime candidate) noexcept {
    const auto order =
        media::compareMediaTime(value.decodedFrontier, candidate);
    if (order.has_value() && *order == MediaTimeOrder::Less) {
      value.decodedFrontier = candidate;
    }
  }

  [[nodiscard]] bool allocateEpoch(std::uint64_t* result) noexcept {
    if (result == nullptr || nextEpoch == 0) {
      return false;
    }
    *result = nextEpoch;
    epochHighWater = nextEpoch;
    nextEpoch = nextEpoch == std::numeric_limits<std::uint64_t>::max()
                    ? 0
                    : nextEpoch + 1;
    return true;
  }

  NativePreviewFrameLaneBinding binding;
  std::shared_ptr<NativeTrackedVideoPreviewPort> output;
  const NativePreviewFrameLaneWakeSeam wake;
  std::unique_ptr<NativePreviewSource> source;
  PreviewFrameSink sink;
  VideoToolboxDecoder decoder;
  const bool bypassDecoder{false};
  bool decoderReady{false};
  preview_protocol::Stamp acceptedThrough{};
  std::optional<Request> pending;
  std::optional<Active> active;
  std::optional<preview_protocol::PreviewPresented> presented;
  std::uint64_t nextEpoch{1};
  std::uint64_t epochHighWater{0};
  std::uint64_t acceptedRequests{0};
  std::uint64_t replacedRequests{0};
  std::uint64_t decoderConfigurations{0};
  std::uint64_t decoderReuseRequests{0};
  std::uint64_t cachedFrameReuseRequests{0};
  std::size_t peakCachedFrames{0};
  std::uint64_t peakLaneCompressedBytes{0};
  std::uint64_t sourceSamples{0};
  std::uint64_t discardedLeadingPictures{0};
  // Exact presentation time of the full-sync sample the active preview epoch
  // began decoding on. Cleared with the decoder it belongs to.
  std::optional<MediaTime> generationStartPresentation;
  std::uint64_t decodedFramesDiscarded{0};
  std::uint64_t framesSubmitted{0};
  std::uint64_t framesDrawn{0};
  std::uint64_t staleCompletions{0};
  std::uint64_t lastOutputEventSequence{0};
  bool stopStarted{false};
  bool stopped{false};
  bool failed{false};
  std::string error;
};

NativePreviewFrameLane::NativePreviewFrameLane(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

std::unique_ptr<NativePreviewFrameLane> NativePreviewFrameLane::create(
    NativePreviewFrameLaneBinding binding,
    std::shared_ptr<NativeTrackedVideoPreviewPort> output,
    NativePreviewFrameLaneWakeSeam wake,
    std::unique_ptr<NativePreviewSource> source) noexcept {
  if (!validBinding(binding, output, wake) || source == nullptr) {
    return {};
  }
  try {
    auto impl = std::make_unique<Impl>(
        std::move(binding), std::move(output), wake, std::move(source), false);
    if (!impl->prepareDecoder()) {
      return {};
    }
    return std::unique_ptr<NativePreviewFrameLane>(
        new NativePreviewFrameLane(std::move(impl)));
  } catch (...) {
    return {};
  }
}

std::optional<NativePreviewFrameTarget>
NativePreviewFrameLane::preflightTarget(double seconds) noexcept {
  const auto exact = media::exactNonnegativeMediaTime(seconds);
  return exact ? std::optional<NativePreviewFrameTarget>{
                     NativePreviewFrameTarget{seconds, *exact}}
               : std::nullopt;
}

NativePreviewFrameLane::~NativePreviewFrameLane() {
  if (impl_ == nullptr) {
    return;
  }
  if (impl_->active) {
    impl_->active->cancelling = true;
    impl_->retireLocal(*impl_->active);
  }
  impl_->pending.reset();
  impl_->presented.reset();
  static_cast<void>(impl_->output->cancel());
  impl_->source->close();
  impl_->closeDecoder();
}

NativePreviewFrameRequestStatus NativePreviewFrameLane::request(
    preview_protocol::PreviewFrame command,
    NativePreviewFrameTarget target) noexcept {
  if (impl_ == nullptr || !preview_protocol::valid(command) ||
      command.targetSeconds != target.seconds() || !target.exact().valid() ||
      command.generation != impl_->binding.activePlaybackGeneration) {
    return NativePreviewFrameRequestStatus::Invalid;
  }
  if (impl_->stopped || impl_->stopStarted) {
    return NativePreviewFrameRequestStatus::Closed;
  }
  if (impl_->failed) {
    return NativePreviewFrameRequestStatus::Failed;
  }
  if (!preview_protocol::follows(impl_->acceptedThrough, command.stamp)) {
    return NativePreviewFrameRequestStatus::Stale;
  }
  const auto within = media::compareMediaTime(
      target.exact(), impl_->binding.source.descriptor->duration);
  if (!within || *within == MediaTimeOrder::Greater) {
    return NativePreviewFrameRequestStatus::Invalid;
  }

  const bool replaced = impl_->pending.has_value() || impl_->active.has_value();
  if (impl_->active && !impl_->active->cancelling &&
      !impl_->active->localRetired && !impl_->pending &&
      sameGesture(impl_->active->request.command, command) &&
      canReuseForward(impl_->active->request.target,
                      impl_->active->decodedFrontier, target.exact())) {
    Impl::Active& active = *impl_->active;
    const bool cachedCovers =
        active.cachedFrame &&
        frameExtendsBeyondTarget(active.cachedFrame.timing(), target.exact());
    // Once EOS has been entered, the decoder cannot accept another sample.
    // The retained exact frame remains reusable, but any later interval must
    // restart from a sync sample in a fresh graph.
    if ((!active.sourceEnded && !active.endOfStreamBegun) || cachedCovers) {
      if (!impl_->source->advanceTarget(active.epoch, target.exact())) {
        impl_->latchFailure("preview source rejected a valid forward retarget");
        return NativePreviewFrameRequestStatus::Failed;
      }
      active.request = Impl::Request{command, target.exact()};
      active.presentedIdle = false;
      impl_->presented.reset();
      if (active.awaitingDraw.valid()) {
        // Even if the retained frame covers the new target, its compositor
        // event may already predate this request. Consume its real terminal
        // event as stale, then resubmit the cached lease for a new exact draw.
        const auto cancelled = impl_->output->cancel();
        if (cancelled == NativeTrackedVideoPreviewCancelProgress::Failed) {
          impl_->latchFailure("preview output retarget cancellation failed");
          return NativePreviewFrameRequestStatus::Failed;
        }
        active.awaitingSuperseded = true;
      } else if (cachedCovers) {
        std::string error;
        const auto staged = impl_->sink.timing();
        if (staged.has_value()) {
          if (!sameTiming(*staged, active.cachedFrame.timing())) {
            impl_->latchFailure(
                "preview cached-frame staging violated exact identity");
            return NativePreviewFrameRequestStatus::Failed;
          }
          // A still-unpumped cached lease already carries this exact frame.
          // Updating the retained command is sufficient: the eventual submit
          // and real draw are matched against the newest identity.
        } else {
          FrameLease reused(active.cachedFrame);
          if (!reused ||
              impl_->sink.restageCached(std::move(reused), &error) !=
                  FrameEnqueueResult::Accepted) {
            impl_->latchFailure(error.empty()
                                    ? "preview cached-frame reuse failed"
                                    : error);
            return NativePreviewFrameRequestStatus::Failed;
          }
        }
      } else {
        active.cachedFrame.reset();
      }
      ++impl_->acceptedRequests;
      ++impl_->replacedRequests;
      ++impl_->decoderReuseRequests;
      if (cachedCovers) {
        ++impl_->cachedFrameReuseRequests;
      }
      impl_->acceptedThrough = command.stamp;
      impl_->wake.signal(impl_->wake.context);
      return NativePreviewFrameRequestStatus::Replaced;
    }
  }
  if (impl_->active) {
    impl_->active->cancelling = true;
    impl_->source->requestCancel(impl_->active->epoch);
    static_cast<void>(impl_->output->cancel());
  }
  impl_->pending.emplace(Impl::Request{command, target.exact()});
  impl_->presented.reset();
  impl_->acceptedThrough = command.stamp;
  ++impl_->acceptedRequests;
  if (replaced) {
    ++impl_->replacedRequests;
  }
  impl_->wake.signal(impl_->wake.context);
  return replaced ? NativePreviewFrameRequestStatus::Replaced
                  : NativePreviewFrameRequestStatus::Accepted;
}

NativePreviewFrameCancelProgress NativePreviewFrameLane::cancel(
    const preview_protocol::PreviewFrame& command) noexcept {
  if (impl_ == nullptr || impl_->failed) {
    return NativePreviewFrameCancelProgress::Failed;
  }
  if (impl_->pending && sameCommand(impl_->pending->command, command)) {
    impl_->pending.reset();
    impl_->presented.reset();
    if (!impl_->active) {
      return NativePreviewFrameCancelProgress::Done;
    }
  } else if (!impl_->active ||
             !sameCommand(impl_->active->request.command, command) ||
             impl_->pending) {
    return NativePreviewFrameCancelProgress::Stale;
  }
  impl_->active->cancelling = true;
  impl_->retireLocal(*impl_->active);
  const NativeTrackedVideoPreviewCancelProgress output =
      impl_->output->cancel();
  if (output == NativeTrackedVideoPreviewCancelProgress::Failed) {
    impl_->latchFailure("preview output cancellation failed");
    return NativePreviewFrameCancelProgress::Failed;
  }
  if (output == NativeTrackedVideoPreviewCancelProgress::Done &&
      !impl_->active->awaitingDraw.valid()) {
    impl_->active.reset();
    return NativePreviewFrameCancelProgress::Done;
  }
  return NativePreviewFrameCancelProgress::Quiescing;
}

NativePreviewFramePumpProgress NativePreviewFrameLane::pump() noexcept {
  if (impl_ == nullptr || impl_->failed) {
    return NativePreviewFramePumpProgress::Failed;
  }
  if (impl_->stopped) {
    return NativePreviewFramePumpProgress::Stopped;
  }
  try {
    if (auto event = impl_->output->takeEvent()) {
      if (event->eventSequence == 0 ||
          event->eventSequence <= impl_->lastOutputEventSequence ||
          !impl_->active || !impl_->active->awaitingDraw.valid() ||
          event->frameSequence != impl_->active->awaitingDraw ||
          event->generation != impl_->binding.activePlaybackGeneration.value ||
          !sameTiming(event->timing, impl_->active->awaitingTiming)) {
        impl_->latchFailure("preview output event violated its exact identity");
        return NativePreviewFramePumpProgress::Failed;
      }
      impl_->lastOutputEventSequence = event->eventSequence;
      if (event->kind != NativeTrackedVideoPreviewEventKind::FrameDrawn &&
          event->kind !=
              NativeTrackedVideoPreviewEventKind::FrameSuperseded) {
        impl_->latchFailure(
            event->kind == NativeTrackedVideoPreviewEventKind::Failed
                ? "preview output reported a frame failure"
                : "preview output reported an unknown event kind");
        return NativePreviewFramePumpProgress::Failed;
      }
      const bool publish =
          event->kind == NativeTrackedVideoPreviewEventKind::FrameDrawn &&
          !impl_->active->cancelling && !impl_->pending &&
          !impl_->active->awaitingSuperseded &&
          frameExtendsBeyondTarget(event->timing,
                                   impl_->active->request.target);
      if (publish) {
        const auto presentation = exactMediaTime(event->timing.presentationTime);
        const auto seconds = presentation
                                 ? media::mediaTimeSeconds(*presentation)
                                 : std::optional<double>{};
        if (!seconds) {
          impl_->latchFailure("drawn preview frame has invalid timing");
          return NativePreviewFramePumpProgress::Failed;
        }
        // A frame that straddles the origin is presented FROM the origin,
        // which is the time the transport can show for it.
        const auto& command = impl_->active->request.command;
        impl_->presented.emplace(preview_protocol::PreviewPresented{
            command.stamp, command.generation, command.gesture,
            command.request, std::max(0.0, *seconds)});
        ++impl_->framesDrawn;
      } else {
        ++impl_->staleCompletions;
      }
      Impl::Active& active = *impl_->active;
      active.awaitingDraw = {};
      active.awaitingTiming = {};
      if (active.cancelling || impl_->pending) {
        impl_->retireLocal(active);
        impl_->active.reset();
      } else {
        // Keep the source, decoder, and at most one aliased surface warm. A
        // later forward request either resubmits this exact frame or continues
        // sequential decode from the reader's current cursor.
        const bool cachedCovers =
            active.cachedFrame && frameExtendsBeyondTarget(
                                      active.cachedFrame.timing(),
                                      active.request.target);
        if ((active.awaitingSuperseded ||
             event->kind ==
                 NativeTrackedVideoPreviewEventKind::FrameSuperseded) &&
            cachedCovers) {
          std::string error;
          FrameLease reused(active.cachedFrame);
          if (!reused ||
              impl_->sink.restageCached(std::move(reused), &error) !=
                  FrameEnqueueResult::Accepted) {
            impl_->latchFailure(error.empty()
                                    ? "preview cached-frame resubmit failed"
                                    : error);
            return NativePreviewFramePumpProgress::Failed;
          }
          active.presentedIdle = false;
        } else if (cachedCovers) {
          active.presentedIdle = true;
        } else {
          active.cachedFrame.reset();
          active.presentedIdle = false;
        }
        active.awaitingSuperseded = false;
      }
      return NativePreviewFramePumpProgress::Progress;
    }

    if (impl_->active && impl_->active->cancelling) {
      impl_->retireLocal(*impl_->active);
      const auto progress = impl_->output->cancel();
      if (progress == NativeTrackedVideoPreviewCancelProgress::Failed) {
        impl_->latchFailure("preview output cancellation failed");
        return NativePreviewFramePumpProgress::Failed;
      }
      if (progress == NativeTrackedVideoPreviewCancelProgress::Done &&
          !impl_->active->awaitingDraw.valid()) {
        impl_->active.reset();
        return NativePreviewFramePumpProgress::Progress;
      }
      return NativePreviewFramePumpProgress::Quiescing;
    }

    if (!impl_->active && impl_->pending) {
      std::uint64_t epoch = 0;
      if (!impl_->allocateEpoch(&epoch)) {
        impl_->latchFailure("preview source epoch domain is exhausted");
        return NativePreviewFramePumpProgress::Failed;
      }
      Impl::Request request = std::move(*impl_->pending);
      impl_->pending.reset();
      impl_->active.emplace();
      impl_->active->request = std::move(request);
      impl_->active->epoch = epoch;
      const NativePreviewBeginOutcome begun = impl_->source->begin(
          {epoch, impl_->active->request.target});
      if (begun.status != NativePreviewStatus::Ready) {
        if (begun.status == NativePreviewStatus::Cancelled) {
          impl_->active->cancelling = true;
          return NativePreviewFramePumpProgress::Progress;
        }
        impl_->latchFailure(begun.error.empty()
                                ? "preview source failed to begin"
                                : begun.error);
        return NativePreviewFramePumpProgress::Failed;
      }
      // The reader has already paid to start at the preceding sync sample for
      // this target. Until actual samples advance farther, only one additional
      // second may be coalesced onto that admitted work.
      impl_->active->decodedFrontier =
          impl_->active->request.target;
      impl_->sink.flush(impl_->binding.activePlaybackGeneration.value);
      // A fresh epoch restarts decode at its own full-sync sample, so the
      // previous epoch's random-access point no longer describes this one.
      impl_->generationStartPresentation.reset();
      if (!impl_->prepareDecoder()) {
        return NativePreviewFramePumpProgress::Failed;
      }
      return NativePreviewFramePumpProgress::Progress;
    }

    if (!impl_->active) {
      return NativePreviewFramePumpProgress::Idle;
    }
    Impl::Active& active = *impl_->active;
    if (active.awaitingDraw.valid()) {
      return NativePreviewFramePumpProgress::Quiescing;
    }

    if (active.presentedIdle) {
      return NativePreviewFramePumpProgress::Idle;
    }

    if (const auto timing = impl_->sink.timing()) {
      const auto presentation = exactMediaTime(timing->presentationTime);
      const auto duration = exactMediaTime(timing->duration);
      const auto end = presentation && duration
                           ? checkedTimeSum(*presentation, *duration)
                           : std::optional<MediaTime>{};
      const auto againstTarget = end ? media::compareMediaTime(
                                           *end, active.request.target)
                                     : std::optional<MediaTimeOrder>{};
      // A NEGATIVE presentation time is not a malformation. A head-trimmed
      // edit (elst media_time > 0) hides media before the movie origin, so the
      // random-access point covering the origin restates to a negative movie
      // time and the decoder legitimately emits the whole preroll run from
      // there. What matters is where a frame ENDS, not which side of the
      // origin it begins on: the `againstTarget` test below drops a frame that
      // ends at or before the target as preroll, and the tracked outputs
      // present a frame that straddles the origin. A sign test here would turn
      // an ordinary preroll frame into a lane failure, which
      // `stopPreviewLaneForTerminal` escalates into a refused commit seek.
      if (!presentation || !duration || duration->value <= 0 ||
          timing->generation !=
              impl_->binding.activePlaybackGeneration.value ||
          !againstTarget) {
        impl_->latchFailure("preview decoder emitted invalid frame timing");
        return NativePreviewFramePumpProgress::Failed;
      }
      if (*againstTarget != MediaTimeOrder::Greater) {
        impl_->sink.drop();
        ++impl_->decodedFramesDiscarded;
        return NativePreviewFramePumpProgress::Progress;
      }
      switch (impl_->output->capacity(
          impl_->binding.activePlaybackGeneration.value)) {
      case NativeTrackedVideoCapacity::Backpressure:
        return NativePreviewFramePumpProgress::Quiescing;
      case NativeTrackedVideoCapacity::StaleGeneration:
        active.cancelling = true;
        return NativePreviewFramePumpProgress::Progress;
      case NativeTrackedVideoCapacity::Failed:
        impl_->latchFailure("preview output capacity failed");
        return NativePreviewFramePumpProgress::Failed;
      case NativeTrackedVideoCapacity::Available:
        break;
      }
      std::string error;
      const auto submitted = impl_->sink.submit(
          *impl_->output, impl_->binding.activePlaybackGeneration.value,
          &error);
      switch (submitted.result.status) {
      case NativeTrackedVideoSubmitStatus::Backpressure:
        return NativePreviewFramePumpProgress::Quiescing;
      case NativeTrackedVideoSubmitStatus::StaleGeneration:
        active.cancelling = true;
        return NativePreviewFramePumpProgress::Progress;
      case NativeTrackedVideoSubmitStatus::Failed:
        impl_->latchFailure(error.empty() ? "preview frame submit failed"
                                          : error);
        return NativePreviewFramePumpProgress::Failed;
      case NativeTrackedVideoSubmitStatus::Accepted:
        break;
      }
      if (!submitted.result.sequence.valid()) {
        impl_->latchFailure("preview output accepted without an identity");
        return NativePreviewFramePumpProgress::Failed;
      }
      active.awaitingDraw = submitted.result.sequence;
      active.awaitingTiming = submitted.timing;
      active.cachedFrame = std::move(submitted.retainedFrame);
      if (const auto cachedPresentation =
              exactMediaTime(active.cachedFrame.timing().presentationTime)) {
        if (const auto cachedDuration =
                exactMediaTime(active.cachedFrame.timing().duration)) {
          if (const auto cachedEnd = checkedTimeSum(*cachedPresentation, *cachedDuration)) {
            impl_->advanceDecodedFrontier(active, *cachedEnd);
          }
        }
      }
      impl_->peakCachedFrames = std::max(
          impl_->peakCachedFrames, active.cachedFrame ? std::size_t{1}
                                                      : std::size_t{0});
      ++impl_->framesSubmitted;
      return NativePreviewFramePumpProgress::Progress;
    }

    if (!impl_->bypassDecoder) {
      if (auto decoderError = impl_->decoder.takeLastError()) {
        impl_->latchFailure(*decoderError);
        return NativePreviewFramePumpProgress::Failed;
      }
      const VideoDecodeDrainProgress drained = active.sourceEnded
          ? (active.endOfStreamBegun
                 ? impl_->decoder.drainEndOfStream(
                       impl_->binding.activePlaybackGeneration.value,
                       &impl_->error)
                 : impl_->decoder.beginEndOfStream(
                       impl_->binding.activePlaybackGeneration.value,
                       &impl_->error))
          : impl_->decoder.drainPresentation(
                impl_->binding.activePlaybackGeneration.value,
                &impl_->error);
      if (active.sourceEnded && !active.endOfStreamBegun &&
          drained != VideoDecodeDrainProgress::Failed &&
          drained != VideoDecodeDrainProgress::StaleGeneration) {
        active.endOfStreamBegun = true;
      }
      switch (drained) {
      case VideoDecodeDrainProgress::Failed:
      case VideoDecodeDrainProgress::StaleGeneration:
        impl_->latchFailure(impl_->error.empty()
                                ? "preview decoder drain failed"
                                : impl_->error);
        return NativePreviewFramePumpProgress::Failed;
      case VideoDecodeDrainProgress::Done:
        if (active.sourceEnded && impl_->sink.size() == 0) {
          impl_->latchFailure("preview target produced no presentable frame");
          return NativePreviewFramePumpProgress::Failed;
        }
        return NativePreviewFramePumpProgress::Progress;
      case VideoDecodeDrainProgress::Progress:
        return NativePreviewFramePumpProgress::Progress;
      case VideoDecodeDrainProgress::Quiescing:
        if (active.sourceEnded ||
            !impl_->decoder.stats().acceptsCompressedSample) {
          return NativePreviewFramePumpProgress::Quiescing;
        }
        break;
      }
    }

    if (active.sample) {
      if (impl_->bypassDecoder) {
        return NativePreviewFramePumpProgress::Quiescing;
      }
      if (impl_->leadingPictureBeforeDecodeStart(*active.sample)) {
        active.sample.reset();
        ++impl_->discardedLeadingPictures;
        return NativePreviewFramePumpProgress::Progress;
      }
      CMSampleBufferRef sample = nativeSample(*active.sample);
      if (sample == nullptr) {
        impl_->latchFailure("preview sample lacks CoreMedia ownership");
        return NativePreviewFramePumpProgress::Failed;
      }
      std::string error;
      switch (impl_->decoder.submitCMSampleBuffer(
          sample, impl_->binding.activePlaybackGeneration.value, &error)) {
      case VideoDecodeSubmitResult::Backpressure:
        return NativePreviewFramePumpProgress::Quiescing;
      case VideoDecodeSubmitResult::Rejected:
        impl_->latchFailure(error.empty() ? "preview sample decode failed"
                                          : error);
        return NativePreviewFramePumpProgress::Failed;
      case VideoDecodeSubmitResult::Accepted:
        if (active.sample->keyFrame && !impl_->generationStartPresentation) {
          impl_->generationStartPresentation = active.sample->presentationTime;
        }
        active.sample.reset();
        return NativePreviewFramePumpProgress::Progress;
      }
    }

    if (active.sourceEnded) {
      return NativePreviewFramePumpProgress::Quiescing;
    }
    NativePreviewReadResult read = impl_->source->readNext(active.epoch);
    if (auto* sample = std::get_if<MediaSample>(&read)) {
      if (sample->generation != active.epoch ||
          sample->kind != media::MediaSampleKind::EncodedVideo ||
          sample->sampleCount != 1 || !sample->payload ||
          !native_video_limits::acceptsCompressedVideoAccessUnitSize(
              sample->payload.byteSize())) {
        impl_->latchFailure("preview source returned an invalid sample");
        return NativePreviewFramePumpProgress::Failed;
      }
      active.sample.emplace(std::move(*sample));
      impl_->peakLaneCompressedBytes = std::max(
          impl_->peakLaneCompressedBytes,
          static_cast<std::uint64_t>(active.sample->payload.byteSize()));
      if (const auto end = checkedTimeSum(active.sample->presentationTime,
                                          active.sample->duration)) {
        impl_->advanceDecodedFrontier(active, *end);
      }
      ++impl_->sourceSamples;
      return NativePreviewFramePumpProgress::Progress;
    }
    if (std::holds_alternative<media::MediaDiscontinuity>(read)) {
      return NativePreviewFramePumpProgress::Progress;
    }
    if (std::holds_alternative<NativePreviewEndOfStream>(read)) {
      active.sourceEnded = true;
      return NativePreviewFramePumpProgress::Progress;
    }
    if (std::holds_alternative<NativePreviewCancelled>(read)) {
      active.cancelling = true;
      return NativePreviewFramePumpProgress::Progress;
    }
    const auto* failure = std::get_if<NativePreviewFailure>(&read);
    impl_->latchFailure(failure == nullptr || failure->error.empty()
                            ? "preview source read failed"
                            : failure->error);
    return NativePreviewFramePumpProgress::Failed;
  } catch (const std::exception& exception) {
    impl_->latchFailure(exception.what());
    return NativePreviewFramePumpProgress::Failed;
  } catch (...) {
    impl_->latchFailure("preview lane raised an unknown exception");
    return NativePreviewFramePumpProgress::Failed;
  }
  impl_->latchFailure("preview pump reached an invalid state");
  return NativePreviewFramePumpProgress::Failed;
}

std::optional<preview_protocol::PreviewPresented>
NativePreviewFrameLane::takePresented() noexcept {
  if (impl_ == nullptr) {
    return std::nullopt;
  }
  std::optional<preview_protocol::PreviewPresented> result = impl_->presented;
  impl_->presented.reset();
  return result;
}

NativePreviewFrameCancelProgress NativePreviewFrameLane::stop(
    preview_protocol::Generation activePlaybackGeneration) noexcept {
  if (impl_ == nullptr || impl_->failed) {
    return NativePreviewFrameCancelProgress::Failed;
  }
  if (activePlaybackGeneration != impl_->binding.activePlaybackGeneration) {
    return NativePreviewFrameCancelProgress::Stale;
  }
  if (impl_->stopped) {
    return NativePreviewFrameCancelProgress::Done;
  }
  impl_->stopStarted = true;
  impl_->pending.reset();
  impl_->presented.reset();
  if (impl_->active) {
    impl_->active->cancelling = true;
    impl_->retireLocal(*impl_->active);
  } else {
    impl_->source->close();
    impl_->closeDecoder();
    impl_->sink.flush(activePlaybackGeneration.value);
  }
  if (auto event = impl_->output->takeEvent()) {
    if (event->eventSequence == 0 ||
        event->eventSequence <= impl_->lastOutputEventSequence ||
        !impl_->active || !impl_->active->awaitingDraw.valid() ||
        event->frameSequence != impl_->active->awaitingDraw ||
        event->generation != activePlaybackGeneration.value ||
        !sameTiming(event->timing, impl_->active->awaitingTiming)) {
      impl_->latchFailure("preview stop observed an invalid terminal event");
      return NativePreviewFrameCancelProgress::Failed;
    }
    impl_->lastOutputEventSequence = event->eventSequence;
    if (event->kind != NativeTrackedVideoPreviewEventKind::FrameDrawn &&
        event->kind !=
            NativeTrackedVideoPreviewEventKind::FrameSuperseded) {
      impl_->latchFailure(
          event->kind == NativeTrackedVideoPreviewEventKind::Failed
              ? "preview stop observed an output failure"
              : "preview stop observed an unknown event kind");
      return NativePreviewFrameCancelProgress::Failed;
    }
    ++impl_->staleCompletions;
    impl_->active.reset();
  }
  const auto output = impl_->output->cancel();
  if (output == NativeTrackedVideoPreviewCancelProgress::Failed) {
    impl_->latchFailure("preview output stop failed");
    return NativePreviewFrameCancelProgress::Failed;
  }
  if (output == NativeTrackedVideoPreviewCancelProgress::Quiescing) {
    return NativePreviewFrameCancelProgress::Quiescing;
  }
  if (impl_->active && impl_->active->awaitingDraw.valid()) {
    return NativePreviewFrameCancelProgress::Quiescing;
  }
  impl_->active.reset();
  impl_->stopped = true;
  return NativePreviewFrameCancelProgress::Done;
}

NativePreviewFrameLaneFacts NativePreviewFrameLane::facts() const noexcept {
  NativePreviewFrameLaneFacts result;
  if (impl_ == nullptr) {
    result.failed = true;
    return result;
  }
  result.activePlaybackGeneration =
      impl_->binding.activePlaybackGeneration.value;
  result.activeEpoch = impl_->active ? impl_->active->epoch : 0;
  result.epochHighWater = impl_->epochHighWater;
  result.awaitingDraw =
      impl_->active ? impl_->active->awaitingDraw
                    : NativeTrackedVideoPreviewSequence{};
  result.pendingCommands = impl_->pending ? 1U : 0U;
  result.stagedCompressedSamples =
      impl_->active && impl_->active->sample ? 1U : 0U;
  result.sinkFrames = impl_->sink.size();
  result.peakSinkFrames = impl_->sink.peak();
  result.cachedFrames =
      impl_->active && impl_->active->cachedFrame ? 1U : 0U;
  result.peakCachedFrames = impl_->peakCachedFrames;
  result.acceptedRequests = impl_->acceptedRequests;
  result.replacedRequests = impl_->replacedRequests;
  result.decoderConfigurations = impl_->decoderConfigurations;
  result.decoderReuseRequests = impl_->decoderReuseRequests;
  result.cachedFrameReuseRequests = impl_->cachedFrameReuseRequests;
  result.sourceSamples = impl_->sourceSamples;
  result.discardedLeadingPictures = impl_->discardedLeadingPictures;
  result.decodedFramesDiscarded = impl_->decodedFramesDiscarded;
  result.framesSubmitted = impl_->framesSubmitted;
  result.framesDrawn = impl_->framesDrawn;
  result.staleCompletions = impl_->staleCompletions;
  result.active = impl_->active.has_value();
  result.cancelling = impl_->active && impl_->active->cancelling;
  result.presentedPending = impl_->presented.has_value();
  result.stopped = impl_->stopped;
  result.failed = impl_->failed;
  try {
    result.error = impl_->error;
  } catch (...) {
  }
  result.source = impl_->source->facts();
  result.decoder = impl_->decoder.stats();
  return result;
}

NativePreviewFrameLaneMemoryFacts
NativePreviewFrameLane::memoryFacts() const noexcept {
  NativePreviewFrameLaneMemoryFacts result;
  if (impl_ == nullptr) {
    return result;
  }
  const NativePreviewSourceMemoryFacts source =
      impl_->source->memoryFacts();
  const VideoToolboxDecoderMemoryFacts decoder =
      impl_->decoder.memoryFacts();
  result.sourceCurrentCompressedBytes =
      source.currentStagedCompressedBytes;
  result.sourcePeakCompressedBytes = source.peakStagedCompressedBytes;
  result.laneCurrentCompressedBytes =
      impl_->active && impl_->active->sample
          ? static_cast<std::uint64_t>(
                impl_->active->sample->payload.byteSize())
          : 0;
  result.lanePeakCompressedBytes = impl_->peakLaneCompressedBytes;
  result.decoderCurrentCompressedBytes = decoder.currentCompressedBytes;
  result.decoderPeakCompressedBytes = decoder.peakCompressedBytes;
  result.sinkFrames = impl_->sink.size();
  result.cachedFrames =
      impl_->active && impl_->active->cachedFrame ? 1U : 0U;
  return result;
}

#if defined(WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING)
std::unique_ptr<NativePreviewFrameLane>
NativePreviewFrameLaneTestAccess::create(
    NativePreviewFrameLaneBinding binding,
    std::shared_ptr<NativeTrackedVideoPreviewPort> output,
    NativePreviewFrameLaneWakeSeam wake,
    std::unique_ptr<NativePreviewSource> source) noexcept {
  if (!validBinding(binding, output, wake) || source == nullptr) {
    return {};
  }
  try {
    auto impl = std::make_unique<NativePreviewFrameLane::Impl>(
        std::move(binding), std::move(output), wake, std::move(source), true);
    if (!impl->prepareDecoder()) {
      return {};
    }
    return std::unique_ptr<NativePreviewFrameLane>(
        new NativePreviewFrameLane(std::move(impl)));
  } catch (...) {
    return {};
  }
}

bool NativePreviewFrameLaneTestAccess::injectDecodedFrame(
    NativePreviewFrameLane& lane, FrameLease frame) noexcept {
  if (lane.impl_ == nullptr || !lane.impl_->bypassDecoder) {
    return false;
  }
  return lane.impl_->sink.enqueue(std::move(frame), nullptr) ==
         FrameEnqueueResult::Accepted;
}

void NativePreviewFrameLaneTestAccess::endDecodedStream(
    NativePreviewFrameLane& lane) noexcept {
  if (lane.impl_ != nullptr && lane.impl_->bypassDecoder) {
    lane.impl_->sink.endOfStream(
        lane.impl_->binding.activePlaybackGeneration.value);
  }
}

void NativePreviewFrameLaneTestAccess::failNextRetainedFrameClone(
    NativePreviewFrameLane& lane) noexcept {
  if (lane.impl_ != nullptr && lane.impl_->bypassDecoder) {
    lane.impl_->sink.failNextRetainedCloneForTesting();
  }
}

void NativePreviewFrameLaneTestAccess::setNextEpoch(
    NativePreviewFrameLane& lane, std::uint64_t nextEpoch) noexcept {
  if (lane.impl_ != nullptr) {
    lane.impl_->nextEpoch = nextEpoch;
  }
}
#endif

}  // namespace wam::macos
