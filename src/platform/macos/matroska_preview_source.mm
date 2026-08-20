#include "platform/macos/matroska_preview_source.hpp"

#include "platform/macos/matroska_asset_context.hpp"
#include "platform/macos/matroska_sample_builder.hpp"

#import <CoreMedia/CoreMedia.h>

#include <atomic>
#include <exception>
#include <utility>

namespace wam::macos {
namespace {

using media::MediaPayloadLease;
using media::MediaSample;
using media::MediaSampleKind;
using media::MediaSourceLimits;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackKind;
using media::matroska::CancellationToken;
using media::matroska::MatroskaCompressedSample;
using media::matroska::MatroskaCursor;
using media::matroska::MatroskaCursorCancelled;
using media::matroska::MatroskaCursorEnd;
using media::matroska::MatroskaCursorFailure;
using media::matroska::MatroskaDemuxStatus;
using media::matroska::MatroskaGenerationPlan;
using media::matroska::MatroskaPreparedAsset;

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
  return track != nullptr && track->kind == MediaTrackKind::Video &&
                 track->video.has_value() &&
                 !track->codecConfiguration.empty()
             ? track
             : nullptr;
}

[[nodiscard]] bool validRequest(const NativePreviewBinding& binding,
                                NativePreviewRequest request) noexcept {
  return request.epoch != 0 && binding.descriptor != nullptr &&
         withinDuration(request.target, binding.descriptor->duration);
}

}  // namespace

struct MatroskaPreviewSource::Impl final {
  Impl(NativePreviewBinding suppliedBinding,
       std::shared_ptr<const MatroskaAssetContext> suppliedContext,
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

  // Drops the cursor and every published per-epoch fact. The demuxer cursor
  // owns no thread, timer, or file descriptor of its own -- the prepared asset
  // holds the one retained descriptor -- so destroying it is the whole
  // retirement, and it is prompt because a cursor blocked in a read has
  // already returned by the time the owner reaches here.
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

  // The demuxer's cancellation seam is a POD probe rather than an object, so
  // this latch is what planGeneration(), every cursor read, and every payload
  // copy observes. requestCancel() publishes the epoch from any thread; only
  // the owner thread (inside a demuxer call it made itself) dereferences the
  // context, so the probe reads atomics and nothing else.
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
  std::shared_ptr<const MatroskaAssetContext> context;
  std::shared_ptr<const MatroskaPreparedAsset> asset;
  // Borrowed from the descriptor the binding retains for this source's whole
  // life, so the pointer cannot dangle and the track cannot be reselected.
  const MediaTrackDescriptor* track{nullptr};
  // One format description for the source, not one per epoch: handing
  // VideoToolbox a second, distinct description object would force a decoder
  // reconfiguration between two scrub targets of the same file.
  CMVideoFormatDescriptionRef format{nullptr};
  MediaSourceLimits limits{};

  std::unique_ptr<MatroskaCursor> cursor;
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
  // The neutral facts call one cursor a reader, because a cursor is this
  // backend's unit of streaming state exactly as an AVAssetReader is the
  // other's. These are the preview's own counters; the shared asset context
  // separately accumulates the same two facts across main seeks and previews.
  std::atomic<std::uint64_t> cursorCreationAttempts{0};
  std::atomic<std::uint64_t> cursorsStarted{0};
  std::atomic<bool> open{false};
};

MatroskaPreviewSource::MatroskaPreviewSource(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

std::unique_ptr<MatroskaPreviewSource> MatroskaPreviewSource::create(
    NativePreviewBinding binding) noexcept {
  try {
    if (binding.localPath.empty() || !binding.localPath.is_absolute() ||
        binding.descriptor == nullptr ||
        !media::validateMediaSourceDescriptor(
            *binding.descriptor,
            media::clampMediaSourceLimits(binding.limits), nullptr)) {
      return {};
    }
    auto context = std::dynamic_pointer_cast<const MatroskaAssetContext>(
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
        createMatroskaVideoFormatDescription(*track);
    if (format == nullptr) {
      return {};
    }
    auto impl = std::make_unique<Impl>(std::move(binding), std::move(context),
                                       track, format);
    return std::unique_ptr<MatroskaPreviewSource>(
        new MatroskaPreviewSource(std::move(impl)));
  } catch (...) {
    return {};
  }
}

MatroskaPreviewSource::~MatroskaPreviewSource() { close(); }

NativePreviewBeginOutcome MatroskaPreviewSource::begin(
    NativePreviewRequest request) noexcept {
  NativePreviewBeginOutcome outcome;
  outcome.epoch = request.epoch;
  if (impl_ == nullptr || !validRequest(impl_->binding, request) ||
      request.epoch <= impl_->epochHighWater.load(std::memory_order_acquire)) {
    outcome.error = "preview request is stale or invalid";
    return outcome;
  }
  try {
    // Same publication order as the AVFoundation source: burn the previous
    // cancellation latch, publish the new operation slot, raise the high-water
    // mark, then retire the old cursor. A late cancel for the old slot is
    // harmless and every cancel after the operationEpoch store either reaches
    // this generation or remains latched until it is live.
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
    // Published before planning so the demuxer's cancellation probe -- which
    // compares against the active epoch -- can already answer for this epoch
    // while planGeneration() and makeVideoCursor() run.
    impl_->activeEpoch.store(request.epoch, std::memory_order_release);

    // No back-walk. planGeneration() is const, cursor free, and resolves the
    // target against the selected-video Cue index, so actualDecodeStart is a
    // random access point by construction. This is the whole reason the
    // Matroska preview needs no equivalent of the AVFoundation full-sync
    // cursor walk.
    const media::matroska::MatroskaPlanOutcome planned =
        impl_->asset->planGeneration(request.target,
                                     media::MediaSeekMode::Accurate,
                                     impl_->cancellation());
    if (planned.status != MatroskaDemuxStatus::Ready || !planned.plan) {
      switch (planned.status) {
      case MatroskaDemuxStatus::Cancelled:
        outcome.status = NativePreviewStatus::Cancelled;
        break;
      case MatroskaDemuxStatus::Unsupported:
        outcome.status = NativePreviewStatus::Unsupported;
        break;
      default:
        outcome.status = NativePreviewStatus::Failed;
        break;
      }
      outcome.error = matroskaDemuxErrorMessage(
          planned.message.empty() ? "matroska preview planning failed"
                                  : planned.message.c_str(),
          planned.error);
      impl_->retireActive();
      return outcome;
    }
    const MatroskaGenerationPlan& plan = *planned.plan;
    const auto startAgainstTarget =
        media::compareMediaTime(plan.actualDecodeStart, request.target);
    // A plan may legitimately begin after its target in exactly one case, the
    // same one the main source admits: the target lies at or before the first
    // video Cue, which is the true video origin of a stream-copied file whose
    // video starts a few milliseconds in. Any other late start really has
    // skipped content and must not be presented as this target's frame.
    bool clampedToVideoOrigin = false;
    if (startAgainstTarget && *startAgainstTarget == MediaTimeOrder::Greater) {
      const auto cues = impl_->asset->cues();
      if (!cues.empty()) {
        const auto firstCueTime = matroskaTickTime(
            static_cast<std::int64_t>(cues.front().timestampTick),
            impl_->asset->timestampScaleNanoseconds());
        clampedToVideoOrigin =
            firstCueTime.has_value() &&
            media::compareMediaTime(plan.actualDecodeStart, *firstCueTime) ==
                std::optional<MediaTimeOrder>{MediaTimeOrder::Equal};
      }
    }
    if (!plan.actualDecodeStart.valid() || plan.actualDecodeStart.value < 0 ||
        !startAgainstTarget ||
        (*startAgainstTarget == MediaTimeOrder::Greater &&
         !clampedToVideoOrigin)) {
      outcome.status = NativePreviewStatus::Unsupported;
      outcome.error = "matroska preview plan starts after its own target";
      impl_->retireActive();
      return outcome;
    }

    impl_->cursorCreationAttempts.fetch_add(1, std::memory_order_relaxed);
    noteMatroskaAssetContextCursorCreationAttempt(*impl_->context);
    impl_->cursor = impl_->asset->makeVideoCursor(plan);
    if (impl_->cursor == nullptr) {
      outcome.status = NativePreviewStatus::Failed;
      outcome.error = "matroska preview video cursor could not be created";
      impl_->retireActive();
      return outcome;
    }
    impl_->cursorsStarted.fetch_add(1, std::memory_order_relaxed);
    noteMatroskaAssetContextCursorStarted(*impl_->context);

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

NativePreviewReadResult MatroskaPreviewSource::readNext(
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
    media::matroska::MatroskaCursorReadResult read =
        impl_->cursor->readNext(impl_->cancellation());
    if (std::holds_alternative<MatroskaCursorCancelled>(read) ||
        impl_->cancelledEpoch.load(std::memory_order_acquire) ==
            expectedEpoch) {
      impl_->retireActive();
      return NativePreviewCancelled{expectedEpoch};
    }
    if (std::holds_alternative<MatroskaCursorEnd>(read)) {
      impl_->eos = true;
      return NativePreviewEndOfStream{expectedEpoch};
    }
    if (const auto* failed = std::get_if<MatroskaCursorFailure>(&read)) {
      std::string error = matroskaDemuxErrorMessage(
          failed->message.empty() ? "matroska preview cursor read failed"
                                  : failed->message.c_str(),
          failed->error);
      impl_->retireActive();
      return NativePreviewFailure{expectedEpoch, std::move(error)};
    }

    const auto& raw = std::get<MatroskaCompressedSample>(read);
    std::string error;
    // The Matroska cursor never emits a payload-free marker, so preview never
    // produces a MediaDiscontinuity here. The neutral variant still carries the
    // alternative because the AVFoundation reader does.
    if (impl_->track == nullptr ||
        !impl_->binding.descriptor->selectedVideo.has_value() ||
        raw.track != *impl_->binding.descriptor->selectedVideo ||
        raw.kind != MediaSampleKind::EncodedVideo) {
      impl_->retireActive();
      return NativePreviewFailure{
          expectedEpoch, "matroska preview cursor emitted an unselected track"};
    }
    if (!raw.presentationTime.valid() || raw.presentationTime.value < 0 ||
        !raw.duration.valid() || raw.duration.value <= 0 ||
        raw.decodeTime.valid() || raw.aggregateBytes == 0 ||
        raw.frameCount != 1 ||
        raw.aggregateBytes > impl_->limits.maximumVideoSampleBytes) {
      impl_->retireActive();
      return NativePreviewFailure{
          expectedEpoch,
          "matroska preview sample exceeds its bounded contract"};
    }

    MatroskaSampleBuildInputs inputs;
    inputs.asset = impl_->asset.get();
    inputs.cancellation = impl_->cancellation();
    inputs.format = static_cast<CMFormatDescriptionRef>(impl_->format);
    inputs.video = true;
    MatroskaScopedSampleBuffer owned;
    const MatroskaSampleBuildStatus built =
        buildMatroskaCompressedSampleBuffer(inputs, raw, &owned, &error);
    if (built != MatroskaSampleBuildStatus::Built) {
      impl_->retireActive();
      if (built == MatroskaSampleBuildStatus::Cancelled) {
        return NativePreviewCancelled{expectedEpoch};
      }
      return NativePreviewFailure{
          expectedEpoch,
          error.empty() ? "matroska preview sample build failed"
                        : std::move(error)};
    }

    const std::size_t bytes = raw.aggregateBytes;
    impl_->currentStagedCompressedBytes.store(
        static_cast<std::uint64_t>(bytes), std::memory_order_release);
    impl_->updateCompressedBytePeak(static_cast<std::uint64_t>(bytes));
    impl_->stagedSampleBuffers.store(1, std::memory_order_release);
    impl_->updatePeak(1);
    const auto clearStage = [this]() noexcept {
      impl_->currentStagedCompressedBytes.store(0, std::memory_order_release);
      impl_->stagedSampleBuffers.store(0, std::memory_order_release);
    };

    const auto decodeOnly = matroskaAccurateVideoDecodeOnly(
        raw.presentationTime, raw.duration, impl_->target, &error);
    if (!decodeOnly) {
      clearStage();
      impl_->retireActive();
      return NativePreviewFailure{
          expectedEpoch,
          error.empty() ? "matroska preview sample interval is not comparable"
                        : std::move(error)};
    }

    auto storage = std::make_shared<MatroskaCoreMediaSampleStorage>(
        owned.get(), bytes);
    static_cast<void>(owned.release());
    MediaSample sample;
    sample.generation = expectedEpoch;
    sample.track = raw.track;
    sample.kind = MediaSampleKind::EncodedVideo;
    sample.presentationTime = raw.presentationTime;
    // Left invalid on purpose, exactly as the main Matroska source leaves it:
    // the container carries no DTS, so the preview decode is submission
    // ordered and the lane's bounded reorder window is what covers B-frames.
    sample.decodeTime = MediaTime{};
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
          expectedEpoch, error.empty()
                             ? "matroska preview sample failed validation"
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

bool MatroskaPreviewSource::advanceTarget(std::uint64_t expectedEpoch,
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

void MatroskaPreviewSource::requestCancel(std::uint64_t epoch) noexcept {
  if (impl_ == nullptr || epoch == 0 ||
      impl_->operationEpoch.load(std::memory_order_acquire) != epoch) {
    return;
  }
  // Epochs are strictly increasing. Revalidate the public operation before
  // every publication attempt, let an exact newer cancellation replace a stale
  // smaller value, and never let a stale caller overwrite an already published
  // newer cancellation.
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
  // Nothing further to do: the demuxer takes its cancellation from the probe
  // above, and every plan, cursor read, and payload copy rechecks it between
  // bounded reads. There is no reader object to abort out of band.
}

void MatroskaPreviewSource::close() noexcept {
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

NativePreviewSourceFacts MatroskaPreviewSource::facts() const noexcept {
  NativePreviewSourceFacts result;
  if (impl_ == nullptr) {
    return result;
  }
  result.operationEpoch = impl_->operationEpoch.load(std::memory_order_acquire);
  result.activeEpoch = impl_->activeEpoch.load(std::memory_order_acquire);
  result.epochHighWater =
      impl_->epochHighWater.load(std::memory_order_acquire);
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
  result.cancelled =
      result.activeEpoch != 0 &&
      impl_->cancelledEpoch.load(std::memory_order_acquire) ==
          result.activeEpoch;
  // The three assetLoad* facts stay zero on purpose: admitting a Matroska file
  // is the main source's bounded, cancellable job, and preview is only ever
  // handed the context it already produced. A nonzero value here would mean
  // preview had opened the container a second time. The AVFoundation source
  // reports the same three zeros whenever it is given a shared context.
  result.backend.readersCreated =
      impl_->cursorCreationAttempts.load(std::memory_order_relaxed);
  result.backend.readersStarted =
      impl_->cursorsStarted.load(std::memory_order_relaxed);
  return result;
}

NativePreviewSourceMemoryFacts MatroskaPreviewSource::memoryFacts()
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
