#include "platform/macos/mpegts_preview_source.hpp"

#include "platform/macos/mpegts_asset_context.hpp"
#include "platform/macos/mpegts_sample_builder.hpp"

#import <CoreMedia/CoreMedia.h>

#include <atomic>
#include <exception>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

using media::MediaCodec;
using media::MediaPayloadLease;
using media::MediaSample;
using media::MediaSampleKind;
using media::MediaSourceLimits;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackKind;
using media::mpegts::CancellationToken;
using media::mpegts::MpegTsCompressedSample;
using media::mpegts::MpegTsCursor;
using media::mpegts::MpegTsCursorCancelled;
using media::mpegts::MpegTsCursorEnd;
using media::mpegts::MpegTsCursorFailure;
using media::mpegts::MpegTsDemuxStatus;
using media::mpegts::MpegTsGenerationPlan;
using media::mpegts::MpegTsPreparedAsset;

[[nodiscard]] bool withinDuration(MediaTime target,
                                  MediaTime duration) noexcept {
  if (!target.valid() || target.value < 0 || !duration.valid() ||
      duration.value < 0) {
    return false;
  }
  const auto order = media::compareMediaTime(target, duration);
  return order.has_value() && *order != MediaTimeOrder::Greater;
}

[[nodiscard]] const MediaTrackDescriptor* selectedVideoTrack(
    const NativePreviewBinding& binding) noexcept {
  if (binding.descriptor == nullptr ||
      !binding.descriptor->selectedVideo.has_value()) {
    return nullptr;
  }
  const MediaTrackDescriptor* track = media::findMediaTrack(
      *binding.descriptor, *binding.descriptor->selectedVideo);
  // Deliberately NOT the Matroska predicate. That one additionally demands a
  // non-empty codec configuration record, which is right for every codec
  // Matroska carries and wrong for MPEG-2 in a transport stream: MPEG-2's
  // sequence header is in band and its descriptor states an empty record on
  // purpose. The format-description factory below is the authority on whether
  // the record is the right shape for the codec, so requiring a record here
  // would refuse a preview the decoder is perfectly able to serve.
  return track != nullptr && track->kind == MediaTrackKind::Video &&
                 track->video.has_value()
             ? track
             : nullptr;
}

[[nodiscard]] bool validRequest(const NativePreviewBinding& binding,
                                NativePreviewRequest request) noexcept {
  return request.epoch != 0 && binding.descriptor != nullptr &&
         withinDuration(request.target, binding.descriptor->duration);
}

}  // namespace

struct MpegTsPreviewSource::Impl final {
  Impl(NativePreviewBinding suppliedBinding,
       std::shared_ptr<const MpegTsAssetContext> suppliedContext,
       const MediaTrackDescriptor* suppliedTrack,
       CMVideoFormatDescriptionRef suppliedFormat) noexcept
      : binding(std::move(suppliedBinding)),
        context(std::move(suppliedContext)),
        asset(context->asset()),
        track(suppliedTrack),
        format(suppliedFormat),
        limits(media::clampMediaSourceLimits(binding.limits)) {}

  ~Impl() {
    if (format != nullptr) {
      CFRelease(format);
      format = nullptr;
    }
  }

  Impl(const Impl&) = delete;
  Impl& operator=(const Impl&) = delete;

  void retireActive(bool withdrawOperation = true) noexcept {
    cursor.reset();
    activeEpoch.store(0, std::memory_order_release);
    if (withdrawOperation) {
      operationEpoch.store(0, std::memory_order_release);
    }
    open.store(false, std::memory_order_release);
    currentStagedCompressedBytes.store(0, std::memory_order_release);
    stagedSampleBuffers.store(0, std::memory_order_release);
  }

  void updatePeak(std::size_t value) noexcept {
    std::size_t peak = peakStagedSampleBuffers.load(std::memory_order_relaxed);
    while (peak < value && !peakStagedSampleBuffers.compare_exchange_weak(
                               peak, value, std::memory_order_relaxed,
                               std::memory_order_relaxed)) {
    }
  }

  void updateCompressedBytePeak(std::uint64_t value) noexcept {
    std::uint64_t peak =
        peakStagedCompressedBytes.load(std::memory_order_relaxed);
    while (peak < value && !peakStagedCompressedBytes.compare_exchange_weak(
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

  [[nodiscard]] bool isCancelled() const noexcept {
    const std::uint64_t active = activeEpoch.load(std::memory_order_acquire);
    return active != 0 &&
           cancelledEpoch.load(std::memory_order_acquire) == active;
  }

  [[nodiscard]] static bool cancellationProbe(const void* context) noexcept {
    const auto* impl = static_cast<const Impl*>(context);
    return impl != nullptr && impl->isCancelled();
  }

  [[nodiscard]] CancellationToken cancellation() const noexcept {
    return CancellationToken{this, &Impl::cancellationProbe};
  }

  NativePreviewBinding binding;
  std::shared_ptr<const MpegTsAssetContext> context;
  std::shared_ptr<const MpegTsPreparedAsset> asset;
  const MediaTrackDescriptor* track{nullptr};
  CMVideoFormatDescriptionRef format{nullptr};
  MediaSourceLimits limits{};

  std::unique_ptr<MpegTsCursor> cursor;
  // Reset-not-freed Annex-B gather workspace, one per preview source.
  std::vector<std::byte> payloadWorkspace;
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
  std::atomic<std::uint64_t> cursorCreationAttempts{0};
  std::atomic<std::uint64_t> cursorsStarted{0};
  std::atomic<bool> open{false};
};

MpegTsPreviewSource::MpegTsPreviewSource(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

std::unique_ptr<MpegTsPreviewSource> MpegTsPreviewSource::create(
    NativePreviewBinding binding) noexcept {
  try {
    if (binding.localPath.empty() || !binding.localPath.is_absolute() ||
        binding.descriptor == nullptr ||
        !media::validateMediaSourceDescriptor(
            *binding.descriptor, media::clampMediaSourceLimits(binding.limits),
            nullptr)) {
      return {};
    }
    auto context = std::dynamic_pointer_cast<const MpegTsAssetContext>(
        binding.assetContext);
    if (context == nullptr || context->asset() == nullptr ||
        !context->matchesPreviewBinding(binding.localPath,
                                        binding.descriptor)) {
      return {};
    }
    const MediaTrackDescriptor* track = selectedVideoTrack(binding);
    if (track == nullptr) {
      return {};
    }
    CMVideoFormatDescriptionRef format =
        createMpegTsVideoFormatDescription(*track);
    if (format == nullptr) {
      return {};
    }
    auto impl = std::make_unique<Impl>(std::move(binding), std::move(context),
                                       track, format);
    return std::unique_ptr<MpegTsPreviewSource>(
        new MpegTsPreviewSource(std::move(impl)));
  } catch (...) {
    return {};
  }
}

MpegTsPreviewSource::~MpegTsPreviewSource() { close(); }

NativePreviewBeginOutcome MpegTsPreviewSource::begin(
    NativePreviewRequest request) noexcept {
  NativePreviewBeginOutcome outcome;
  outcome.epoch = request.epoch;
  if (impl_ == nullptr || !validRequest(impl_->binding, request) ||
      request.epoch <= impl_->epochHighWater.load(std::memory_order_acquire)) {
    outcome.error = "preview request is stale or invalid";
    return outcome;
  }
  try {
    // Same publication order as the AVFoundation and Matroska sources: burn the
    // previous cancellation latch, publish the new operation slot, raise the
    // high-water mark, then retire the old cursor.
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

    // No back-walk. planGeneration() is const and cursor free: it bisects the
    // PCR index built at open, then scans forward for a random access point
    // the demuxer has proved is decodable from a cold decoder. The landing is
    // therefore correct by construction, and only its ACCURACY differs from
    // Matroska's -- see the header.
    const media::mpegts::MpegTsPlanOutcome planned = impl_->asset->planGeneration(
        request.target, media::MediaSeekMode::Accurate, impl_->cancellation());
    if (planned.status != MpegTsDemuxStatus::Ready || !planned.plan) {
      switch (planned.status) {
      case MpegTsDemuxStatus::Cancelled:
        outcome.status = NativePreviewStatus::Cancelled;
        break;
      case MpegTsDemuxStatus::Unsupported:
        outcome.status = NativePreviewStatus::Unsupported;
        break;
      default:
        outcome.status = NativePreviewStatus::Failed;
        break;
      }
      outcome.error = mpegTsDemuxErrorMessage(
          planned.message.empty() ? "mpeg-ts preview planning failed"
                                  : planned.message.c_str(),
          planned.error);
      impl_->retireActive();
      return outcome;
    }
    const MpegTsGenerationPlan& plan = *planned.plan;
    const auto startAgainstTarget =
        media::compareMediaTime(plan.actualDecodeStart, request.target);
    // The same one legitimate late start the main source admits: the target
    // lies at or before the first video access unit, which is the true video
    // origin of a mux whose audio leads its video.
    bool clampedToVideoOrigin = false;
    if (startAgainstTarget && *startAgainstTarget == MediaTimeOrder::Greater) {
      const MediaTime videoOrigin = impl_->asset->videoOriginTime();
      clampedToVideoOrigin =
          videoOrigin.valid() &&
          media::compareMediaTime(plan.actualDecodeStart, videoOrigin) ==
              std::optional<MediaTimeOrder>{MediaTimeOrder::Equal};
    }
    if (!plan.actualDecodeStart.valid() || plan.actualDecodeStart.value < 0 ||
        !startAgainstTarget ||
        (*startAgainstTarget == MediaTimeOrder::Greater &&
         !clampedToVideoOrigin)) {
      outcome.status = NativePreviewStatus::Unsupported;
      outcome.error = "mpeg-ts preview plan starts after its own target";
      impl_->retireActive();
      return outcome;
    }

    impl_->cursorCreationAttempts.fetch_add(1, std::memory_order_relaxed);
    noteMpegTsAssetContextCursorCreationAttempt(*impl_->context);
    impl_->cursor = impl_->asset->makeVideoCursor(plan);
    if (impl_->cursor == nullptr) {
      outcome.status = NativePreviewStatus::Failed;
      outcome.error = "mpeg-ts preview video cursor could not be created";
      impl_->retireActive();
      return outcome;
    }
    impl_->cursorsStarted.fetch_add(1, std::memory_order_relaxed);
    noteMpegTsAssetContextCursorStarted(*impl_->context);

    if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
        request.epoch) {
      outcome.status = NativePreviewStatus::Cancelled;
      impl_->retireActive();
      return outcome;
    }
    impl_->actualDecodeStart = plan.actualDecodeStart;
    impl_->publishDecodeStart(plan.actualDecodeStart);
    impl_->open.store(true, std::memory_order_release);
    outcome.status = NativePreviewStatus::Ready;
    outcome.actualDecodeStart = plan.actualDecodeStart;
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

NativePreviewReadResult MpegTsPreviewSource::readNext(
    std::uint64_t expectedEpoch) noexcept {
  if (impl_ == nullptr || expectedEpoch == 0 ||
      expectedEpoch != impl_->activeEpoch.load(std::memory_order_acquire) ||
      !impl_->open.load(std::memory_order_acquire)) {
    return NativePreviewCancelled{expectedEpoch};
  }
  if (impl_->cancelledEpoch.load(std::memory_order_acquire) == expectedEpoch) {
    impl_->retireActive();
    return NativePreviewCancelled{expectedEpoch};
  }
  if (impl_->eos) {
    return NativePreviewEndOfStream{expectedEpoch};
  }
  try {
    media::mpegts::MpegTsCursorReadResult read =
        impl_->cursor->readNext(impl_->cancellation());
    if (std::holds_alternative<MpegTsCursorCancelled>(read) ||
        impl_->cancelledEpoch.load(std::memory_order_acquire) ==
            expectedEpoch) {
      impl_->retireActive();
      return NativePreviewCancelled{expectedEpoch};
    }
    if (std::holds_alternative<MpegTsCursorEnd>(read)) {
      impl_->eos = true;
      return NativePreviewEndOfStream{expectedEpoch};
    }
    if (const auto* failed = std::get_if<MpegTsCursorFailure>(&read)) {
      std::string error = mpegTsDemuxErrorMessage(
          failed->message.empty() ? "mpeg-ts preview cursor read failed"
                                  : failed->message.c_str(),
          failed->error);
      impl_->retireActive();
      return NativePreviewFailure{expectedEpoch, std::move(error)};
    }

    const auto& raw = std::get<MpegTsCompressedSample>(read);
    std::string error;
    if (impl_->track == nullptr ||
        !impl_->binding.descriptor->selectedVideo.has_value() ||
        raw.track != *impl_->binding.descriptor->selectedVideo ||
        raw.kind != MediaSampleKind::EncodedVideo) {
      impl_->retireActive();
      return NativePreviewFailure{
          expectedEpoch, "mpeg-ts preview cursor emitted an unselected track"};
    }
    if (!raw.presentationTime.valid() || raw.presentationTime.value < 0 ||
        !raw.duration.valid() || raw.duration.value <= 0 ||
        raw.payloadBytes == 0 ||
        raw.payloadBytes > impl_->limits.maximumVideoSampleBytes) {
      impl_->retireActive();
      return NativePreviewFailure{
          expectedEpoch, "mpeg-ts preview sample exceeds its bounded contract"};
    }

    MpegTsSampleBuildInputs inputs;
    inputs.asset = impl_->asset.get();
    inputs.cancellation = impl_->cancellation();
    inputs.format = static_cast<CMFormatDescriptionRef>(impl_->format);
    inputs.codec = impl_->track->codec;
    inputs.video = true;
    inputs.workspace = &impl_->payloadWorkspace;
    MpegTsScopedSampleBuffer owned;
    const MpegTsSampleBuildStatus built =
        buildMpegTsCompressedSampleBuffer(inputs, raw, &owned, &error);
    if (built != MpegTsSampleBuildStatus::Built) {
      impl_->retireActive();
      if (built == MpegTsSampleBuildStatus::Cancelled) {
        return NativePreviewCancelled{expectedEpoch};
      }
      return NativePreviewFailure{
          expectedEpoch, error.empty() ? "mpeg-ts preview sample build failed"
                                       : std::move(error)};
    }

    // The retained byte count is the CoreMedia block's, which for H.264 is the
    // AVCC-repacked size rather than the Annex-B size the cursor reported.
    std::size_t bytes = raw.payloadBytes;
    if (CMBlockBufferRef block = CMSampleBufferGetDataBuffer(owned.get());
        block != nullptr) {
      bytes = CMBlockBufferGetDataLength(block);
    }
    impl_->currentStagedCompressedBytes.store(
        static_cast<std::uint64_t>(bytes), std::memory_order_release);
    impl_->updateCompressedBytePeak(static_cast<std::uint64_t>(bytes));
    impl_->stagedSampleBuffers.store(1, std::memory_order_release);
    impl_->updatePeak(1);
    const auto clearStage = [this]() noexcept {
      impl_->currentStagedCompressedBytes.store(0, std::memory_order_release);
      impl_->stagedSampleBuffers.store(0, std::memory_order_release);
    };

    const auto decodeOnly = mpegTsAccurateVideoDecodeOnly(
        raw.presentationTime, raw.duration, impl_->target, &error);
    if (!decodeOnly) {
      clearStage();
      impl_->retireActive();
      return NativePreviewFailure{
          expectedEpoch, error.empty()
                             ? "mpeg-ts preview sample interval is not comparable"
                             : std::move(error)};
    }

    auto storage =
        std::make_shared<MpegTsCoreMediaSampleStorage>(owned.get(), bytes);
    static_cast<void>(owned.release());
    MediaSample sample;
    sample.generation = expectedEpoch;
    sample.track = raw.track;
    sample.kind = MediaSampleKind::EncodedVideo;
    sample.presentationTime = raw.presentationTime;
    // Real, unlike the Matroska preview's: a PES header carries an explicit
    // DTS, so the preview decode is ordered by the stream's own decode order
    // rather than by submission order.
    sample.decodeTime = raw.decodeTime;
    sample.duration = raw.duration;
    sample.keyFrame = raw.keyFrame;
    sample.decodeOnly = *decodeOnly;
    sample.sampleCount = 1;
    sample.payload = MediaPayloadLease(std::move(storage));
    clearStage();
    if (!media::validateMediaSample(sample, *impl_->binding.descriptor,
                                    impl_->limits, &error)) {
      impl_->retireActive();
      return NativePreviewFailure{
          expectedEpoch, error.empty() ? "mpeg-ts preview sample failed validation"
                                       : std::move(error)};
    }
    if (impl_->cancelledEpoch.load(std::memory_order_acquire) ==
        expectedEpoch) {
      impl_->retireActive();
      return NativePreviewCancelled{expectedEpoch};
    }
    impl_->samplesRead.fetch_add(1, std::memory_order_relaxed);
    return sample;
  } catch (const std::exception& exception) {
    impl_->currentStagedCompressedBytes.store(0, std::memory_order_release);
    impl_->stagedSampleBuffers.store(0, std::memory_order_release);
    impl_->retireActive();
    return NativePreviewFailure{expectedEpoch, exception.what()};
  } catch (...) {
    impl_->currentStagedCompressedBytes.store(0, std::memory_order_release);
    impl_->stagedSampleBuffers.store(0, std::memory_order_release);
    impl_->retireActive();
    return NativePreviewFailure{expectedEpoch,
                                "preview read raised an unknown exception"};
  }
}

bool MpegTsPreviewSource::advanceTarget(std::uint64_t expectedEpoch,
                                        MediaTime target) noexcept {
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
  // The open cursor already sits before the new target and reads forward, so
  // the retarget costs no plan, no cursor, and no seek: only the decodeOnly
  // boundary the next samples are measured against moves.
  impl_->target = target;
  impl_->publishTarget(target);
  impl_->forwardRetargets.fetch_add(1, std::memory_order_relaxed);
  return true;
}

void MpegTsPreviewSource::requestCancel(std::uint64_t epoch) noexcept {
  if (impl_ == nullptr || epoch == 0 ||
      impl_->operationEpoch.load(std::memory_order_acquire) != epoch) {
    return;
  }
  std::uint64_t observed =
      impl_->cancelledEpoch.load(std::memory_order_acquire);
  for (;;) {
    if (impl_->operationEpoch.load(std::memory_order_acquire) != epoch ||
        observed > epoch) {
      return;
    }
    if (observed == epoch) {
      return;
    }
    if (impl_->cancelledEpoch.compare_exchange_weak(
            observed, epoch, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      return;
    }
  }
}

void MpegTsPreviewSource::close() noexcept {
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

NativePreviewSourceFacts MpegTsPreviewSource::facts() const noexcept {
  NativePreviewSourceFacts result;
  if (impl_ == nullptr) {
    return result;
  }
  result.operationEpoch = impl_->operationEpoch.load(std::memory_order_acquire);
  result.activeEpoch = impl_->activeEpoch.load(std::memory_order_acquire);
  result.epochHighWater = impl_->epochHighWater.load(std::memory_order_acquire);
  result.target.timescale = impl_->targetScale.load(std::memory_order_acquire);
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
  result.cancelled = result.activeEpoch != 0 &&
                     impl_->cancelledEpoch.load(std::memory_order_acquire) ==
                         result.activeEpoch;
  // The three assetLoad* facts stay zero on purpose: admitting a transport
  // stream is the main source's bounded, cancellable job, and preview is only
  // ever handed the context it already produced.
  result.backend.readersCreated =
      impl_->cursorCreationAttempts.load(std::memory_order_relaxed);
  result.backend.readersStarted =
      impl_->cursorsStarted.load(std::memory_order_relaxed);
  return result;
}

NativePreviewSourceMemoryFacts MpegTsPreviewSource::memoryFacts()
    const noexcept {
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

}  // namespace wam::macos
