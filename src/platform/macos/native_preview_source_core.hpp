#pragma once

#include "platform/macos/core_media_carriage.hpp"
#include "platform/macos/native_preview_source.hpp"

#import <CoreMedia/CoreMedia.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>
#include <string>
#include <utility>
#include <variant>

namespace wam::macos {

// Latches `epoch` as cancelled when it is the live preview operation. Epochs
// are strictly increasing: the public operation is revalidated before every
// publication attempt, an exact newer cancellation replaces a stale smaller
// value, and a stale caller never overwrites an already published newer one.
// Safe from any thread.
inline void publishPreviewCancellation(
    const std::atomic<std::uint64_t>& operation,
    std::atomic<std::uint64_t>& cancelled, std::uint64_t epoch) noexcept {
  if (epoch == 0 || operation.load(std::memory_order_acquire) != epoch) {
    return;
  }
  std::uint64_t observed = cancelled.load(std::memory_order_acquire);
  while (operation.load(std::memory_order_acquire) == epoch &&
         observed < epoch &&
         !cancelled.compare_exchange_weak(observed, epoch,
                                          std::memory_order_acq_rel,
                                          std::memory_order_acquire)) {
  }
}

// The one preview body shared by every backend built on a payload-free custom
// demuxer (Matroska, MPEG-TS), mirroring NativeCustomSourceCore on the main
// route. It owns the epoch algebra, the cancellation latch, the published
// facts, the begin publication order and the bounded read; the container
// supplies only what differs through `Traits`, which is the main source's
// Traits (types, kName, videoOrigin, the cursor counters) extended with:
//
//   PreviewWorkspace                    per-source scratch for the builder
//   previewSampleBounded(raw, limits)   the container's bounded-sample rule
//   buildPreviewSample(asset, token, format, track, raw, workspace, out, error)
//
// There is no back-walk: planGeneration() is const, cursor free, and returns
// an actualDecodeStart that is a random access point by construction, so
// begin() is one plan plus one makeVideoCursor() and the first sample a cursor
// emits is already the picture the decode starts on.
template <class Traits>
class NativePreviewSourceCore final : public NativePreviewSource {
 public:
  using AssetContext = typename Traits::AssetContext;
  using PreparedAsset = typename Traits::PreparedAsset;
  using Cursor = typename Traits::Cursor;
  using CompressedSample = typename Traits::CompressedSample;

  // Requires a binding whose assetContext is this container's live context:
  // admitting the file is the main source's bounded, cancellable job and
  // preview must never repeat it behind a scrub gesture.
  [[nodiscard]] static std::unique_ptr<NativePreviewSource> create(
      NativePreviewBinding binding) noexcept {
    try {
      if (binding.localPath.empty() || !binding.localPath.is_absolute() ||
          binding.descriptor == nullptr ||
          !media::validateMediaSourceDescriptor(
              *binding.descriptor,
              media::clampMediaSourceLimits(binding.limits), nullptr)) {
        return {};
      }
      auto context =
          std::dynamic_pointer_cast<const AssetContext>(binding.assetContext);
      if (context == nullptr || context->asset() == nullptr ||
          !context->matchesPreviewBinding(binding.localPath,
                                          binding.descriptor)) {
        return {};
      }
      const media::MediaTrackDescriptor* track =
          previewableVideoTrack(binding);
      if (track == nullptr) {
        return {};
      }
      CMVideoFormatDescriptionRef format =
          createVideoFormatDescription(*track);
      if (format == nullptr) {
        return {};
      }
      return std::unique_ptr<NativePreviewSource>(new NativePreviewSourceCore(
          std::move(binding), std::move(context), track, format));
    } catch (...) {
      return {};
    }
  }

  ~NativePreviewSourceCore() override {
    close();
    if (format_ != nullptr) {
      CFRelease(format_);
    }
  }

  [[nodiscard]] NativePreviewBeginOutcome begin(
      NativePreviewRequest request) noexcept override {
    NativePreviewBeginOutcome outcome;
    outcome.epoch = request.epoch;
    if (!validTarget(request.target) || request.epoch == 0 ||
        request.epoch <= epochHighWater_.load(std::memory_order_acquire)) {
      outcome.error = "preview request is stale or invalid";
      return outcome;
    }
    try {
      // Burn the previous cancellation latch, publish the new operation slot,
      // raise the high-water mark, then retire the old cursor. A late cancel
      // for the old slot is harmless and every cancel after the
      // operationEpoch store either reaches this generation or remains
      // latched until it is live.
      cancelledEpoch_.store(0, std::memory_order_release);
      operationEpoch_.store(request.epoch, std::memory_order_release);
      epochHighWater_.store(request.epoch, std::memory_order_release);
      retireActive(false);
      target_ = request.target;
      publishTarget(request.target);
      publishDecodeStart({});
      eos_ = false;

      if (cancelledEpoch_.load(std::memory_order_acquire) == request.epoch) {
        outcome.status = NativePreviewStatus::Cancelled;
        retireActive();
        return outcome;
      }
      // Published before planning so the demuxer's cancellation probe --
      // which compares against the active epoch -- already answers for this
      // epoch while planGeneration() and makeVideoCursor() run.
      activeEpoch_.store(request.epoch, std::memory_order_release);

      const typename Traits::PlanOutcome planned = asset_->planGeneration(
          request.target, media::MediaSeekMode::Accurate, cancellation());
      if (planned.status != media::MediaSourceOpenStatus::Ready ||
          !planned.plan) {
        switch (planned.status) {
        case media::MediaSourceOpenStatus::Cancelled:
          outcome.status = NativePreviewStatus::Cancelled;
          break;
        case media::MediaSourceOpenStatus::Unsupported:
          outcome.status = NativePreviewStatus::Unsupported;
          break;
        default:
          outcome.status = NativePreviewStatus::Failed;
          break;
        }
        outcome.error = media::refusalMessage(
            planned.message.empty() ? named(" preview planning failed").c_str()
                                    : planned.message.c_str(),
            planned.error);
        retireActive();
        return outcome;
      }
      const auto& plan = *planned.plan;
      // The same timeline window the main source admits; the preview reports
      // the plan's own start.
      if (!timelineWindowDecodeStart(plan.actualDecodeStart, request.target,
                                     Traits::videoOrigin(*asset_))) {
        outcome.status = NativePreviewStatus::Unsupported;
        outcome.error = named(" preview plan starts after its own target");
        retireActive();
        return outcome;
      }

      cursorCreationAttempts_.fetch_add(1, std::memory_order_relaxed);
      Traits::noteCursorCreationAttempt(*context_);
      cursor_ = asset_->makeVideoCursor(plan);
      if (cursor_ == nullptr) {
        outcome.status = NativePreviewStatus::Failed;
        outcome.error = named(" preview video cursor could not be created");
        retireActive();
        return outcome;
      }
      cursorsStarted_.fetch_add(1, std::memory_order_relaxed);
      Traits::noteCursorStarted(*context_);

      if (cancelledEpoch_.load(std::memory_order_acquire) == request.epoch) {
        outcome.status = NativePreviewStatus::Cancelled;
        retireActive();
        return outcome;
      }
      publishDecodeStart(plan.actualDecodeStart);
      open_.store(true, std::memory_order_release);
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
    retireActive();
    return outcome;
  }

  // The open cursor already sits before a later target and reads forward, so
  // a retarget costs no plan, no cursor and no seek: only the decodeOnly
  // boundary the next samples are measured against moves.
  [[nodiscard]] bool advanceTarget(std::uint64_t expectedEpoch,
                                   media::MediaTime target) noexcept override {
    if (expectedEpoch == 0 || !validTarget(target) ||
        expectedEpoch != activeEpoch_.load(std::memory_order_acquire) ||
        expectedEpoch != operationEpoch_.load(std::memory_order_acquire) ||
        !open_.load(std::memory_order_acquire) ||
        cancelledEpoch_.load(std::memory_order_acquire) == expectedEpoch) {
      return false;
    }
    const auto order = media::compareMediaTime(target_, target);
    if (!order.has_value() || *order == media::MediaTimeOrder::Greater) {
      return false;
    }
    target_ = target;
    publishTarget(target);
    forwardRetargets_.fetch_add(1, std::memory_order_relaxed);
    return true;
  }

  [[nodiscard]] NativePreviewReadResult readNext(
      std::uint64_t expectedEpoch) noexcept override {
    if (expectedEpoch == 0 ||
        expectedEpoch != activeEpoch_.load(std::memory_order_acquire) ||
        !open_.load(std::memory_order_acquire)) {
      return NativePreviewCancelled{expectedEpoch};
    }
    if (cancelledEpoch_.load(std::memory_order_acquire) == expectedEpoch) {
      retireActive();
      return NativePreviewCancelled{expectedEpoch};
    }
    if (eos_) {
      return NativePreviewEndOfStream{expectedEpoch};
    }
    try {
      typename Traits::CursorReadResult read =
          cursor_->readNext(cancellation());
      if (std::holds_alternative<typename Traits::CursorCancelled>(read) ||
          cancelledEpoch_.load(std::memory_order_acquire) == expectedEpoch) {
        retireActive();
        return NativePreviewCancelled{expectedEpoch};
      }
      if (std::holds_alternative<typename Traits::CursorEnd>(read)) {
        eos_ = true;
        return NativePreviewEndOfStream{expectedEpoch};
      }
      if (const auto* failed =
              std::get_if<typename Traits::CursorFailure>(&read)) {
        std::string error = media::refusalMessage(
            failed->message.empty()
                ? named(" preview cursor read failed").c_str()
                : failed->message.c_str(),
            failed->error);
        retireActive();
        return NativePreviewFailure{expectedEpoch, std::move(error)};
      }

      // A demuxer cursor never emits a payload-free marker, so a custom
      // preview never produces a MediaDiscontinuity.
      const auto& raw = std::get<CompressedSample>(read);
      if (raw.track != track_->id ||
          raw.kind != media::MediaSampleKind::EncodedVideo) {
        retireActive();
        return NativePreviewFailure{
            expectedEpoch, named(" preview cursor emitted an unselected track")};
      }
      if (!raw.presentationTime.valid() || raw.presentationTime.value < 0 ||
          !raw.duration.valid() || raw.duration.value <= 0 ||
          !Traits::previewSampleBounded(raw, limits_)) {
        retireActive();
        return NativePreviewFailure{
            expectedEpoch,
            named(" preview sample exceeds its bounded contract")};
      }

      std::string error;
      ScopedSampleBuffer owned;
      const CompressedSampleBuildStatus built = Traits::buildPreviewSample(
          *asset_, cancellation(), static_cast<CMFormatDescriptionRef>(format_),
          *track_, raw, workspace_, &owned, &error);
      if (built != CompressedSampleBuildStatus::Built) {
        retireActive();
        if (built == CompressedSampleBuildStatus::Cancelled) {
          return NativePreviewCancelled{expectedEpoch};
        }
        return NativePreviewFailure{
            expectedEpoch, error.empty() ? named(" preview sample build failed")
                                         : std::move(error)};
      }

      // The retained byte count is the CoreMedia block's: for H.264 in a
      // transport stream that is the AVCC-repacked size, not the cursor's.
      CMBlockBufferRef block = CMSampleBufferGetDataBuffer(owned.get());
      const std::size_t bytes =
          block != nullptr ? CMBlockBufferGetDataLength(block) : 0;
      currentStagedCompressedBytes_.store(static_cast<std::uint64_t>(bytes),
                                          std::memory_order_release);
      updatePeak(peakStagedCompressedBytes_, static_cast<std::uint64_t>(bytes));
      stagedSampleBuffers_.store(1, std::memory_order_release);
      updatePeak(peakStagedSampleBuffers_, std::size_t{1});

      const auto decodeOnly = accurateVideoDecodeOnly(
          raw.presentationTime, raw.duration, target_, &error);
      if (!decodeOnly) {
        clearStage();
        retireActive();
        return NativePreviewFailure{
            expectedEpoch,
            error.empty() ? named(" preview sample interval is not comparable")
                          : std::move(error)};
      }

      media::MediaSample sample;
      sample.generation = expectedEpoch;
      sample.track = raw.track;
      sample.kind = media::MediaSampleKind::EncodedVideo;
      sample.presentationTime = raw.presentationTime;
      // As the main source states it: a transport stream's real DTS, and an
      // invalid stamp for Matroska, which carries none.
      sample.decodeTime = raw.decodeTime;
      sample.duration = raw.duration;
      sample.keyFrame = raw.keyFrame;
      sample.decodeOnly = *decodeOnly;
      sample.sampleCount = 1;
      sample.payload = media::MediaPayloadLease(
          std::make_shared<CoreMediaSampleStorage>(owned.release(), bytes));
      clearStage();
      if (!media::validateMediaSample(sample, *binding_.descriptor, limits_,
                                      &error)) {
        retireActive();
        return NativePreviewFailure{
            expectedEpoch, error.empty()
                               ? named(" preview sample failed validation")
                               : std::move(error)};
      }
      if (cancelledEpoch_.load(std::memory_order_acquire) == expectedEpoch) {
        retireActive();
        return NativePreviewCancelled{expectedEpoch};
      }
      samplesRead_.fetch_add(1, std::memory_order_relaxed);
      return sample;
    } catch (const std::exception& exception) {
      clearStage();
      retireActive();
      return NativePreviewFailure{expectedEpoch, exception.what()};
    } catch (...) {
      clearStage();
      retireActive();
      return NativePreviewFailure{expectedEpoch,
                                  "preview read raised an unknown exception"};
    }
  }

  // The demuxer takes its cancellation from the probe, so there is no reader
  // object to abort out of band.
  void requestCancel(std::uint64_t epoch) noexcept override {
    publishPreviewCancellation(operationEpoch_, cancelledEpoch_, epoch);
  }

  void close() noexcept override {
    retireActive();
    target_ = {};
    publishTarget({});
    publishDecodeStart({});
    eos_ = false;
  }

  [[nodiscard]] NativePreviewSourceFacts facts() const noexcept override {
    NativePreviewSourceFacts result;
    result.operationEpoch = operationEpoch_.load(std::memory_order_acquire);
    result.activeEpoch = activeEpoch_.load(std::memory_order_acquire);
    result.epochHighWater = epochHighWater_.load(std::memory_order_acquire);
    result.target.timescale = targetScale_.load(std::memory_order_acquire);
    result.target.value = targetValue_.load(std::memory_order_relaxed);
    result.actualDecodeStart.timescale =
        decodeStartScale_.load(std::memory_order_acquire);
    result.actualDecodeStart.value =
        decodeStartValue_.load(std::memory_order_relaxed);
    result.stagedSampleBuffers =
        stagedSampleBuffers_.load(std::memory_order_acquire);
    result.peakStagedSampleBuffers =
        peakStagedSampleBuffers_.load(std::memory_order_relaxed);
    result.samplesRead = samplesRead_.load(std::memory_order_relaxed);
    result.forwardRetargets = forwardRetargets_.load(std::memory_order_relaxed);
    result.open = open_.load(std::memory_order_acquire);
    result.cancelled =
        result.activeEpoch != 0 &&
        cancelledEpoch_.load(std::memory_order_acquire) == result.activeEpoch;
    // The assetLoad* facts stay zero: preview is only ever handed the context
    // the main source already produced. The neutral facts call one cursor a
    // reader, exactly as an AVAssetReader is the AVFoundation route's.
    result.backend.readersCreated =
        cursorCreationAttempts_.load(std::memory_order_relaxed);
    result.backend.readersStarted =
        cursorsStarted_.load(std::memory_order_relaxed);
    return result;
  }

  [[nodiscard]] NativePreviewSourceMemoryFacts memoryFacts()
      const noexcept override {
    NativePreviewSourceMemoryFacts result;
    result.stagedSamples = stagedSampleBuffers_.load(std::memory_order_acquire);
    result.currentStagedCompressedBytes =
        currentStagedCompressedBytes_.load(std::memory_order_acquire);
    result.peakStagedCompressedBytes =
        peakStagedCompressedBytes_.load(std::memory_order_relaxed);
    return result;
  }

 private:
  NativePreviewSourceCore(NativePreviewBinding binding,
                          std::shared_ptr<const AssetContext> context,
                          const media::MediaTrackDescriptor* track,
                          CMVideoFormatDescriptionRef format) noexcept
      : binding_(std::move(binding)),
        context_(std::move(context)),
        asset_(context_->asset()),
        track_(track),
        format_(format),
        limits_(media::clampMediaSourceLimits(binding_.limits)) {}

  [[nodiscard]] static std::string named(const char* after) {
    return std::string(Traits::kName) + after;
  }

  [[nodiscard]] bool validTarget(media::MediaTime target) const noexcept {
    return exactNonnegativeTimeWithinDuration(target,
                                              binding_.descriptor->duration);
  }

  // Dropping the cursor is the whole retirement: it owns no thread, timer or
  // file descriptor (the prepared asset holds the one descriptor), and a
  // cursor blocked in a read has already returned by the time the owner
  // reaches here.
  void retireActive(bool withdrawOperation = true) noexcept {
    cursor_.reset();
    activeEpoch_.store(0, std::memory_order_release);
    if (withdrawOperation) {
      operationEpoch_.store(0, std::memory_order_release);
    }
    open_.store(false, std::memory_order_release);
    clearStage();
  }

  void clearStage() noexcept {
    currentStagedCompressedBytes_.store(0, std::memory_order_release);
    stagedSampleBuffers_.store(0, std::memory_order_release);
  }

  template <class Value>
  static void updatePeak(std::atomic<Value>& peak, Value value) noexcept {
    Value observed = peak.load(std::memory_order_relaxed);
    while (observed < value &&
           !peak.compare_exchange_weak(observed, value,
                                       std::memory_order_relaxed,
                                       std::memory_order_relaxed)) {
    }
  }

  void publishTarget(media::MediaTime value) noexcept {
    targetValue_.store(value.value, std::memory_order_relaxed);
    targetScale_.store(value.timescale, std::memory_order_release);
  }

  void publishDecodeStart(media::MediaTime value) noexcept {
    decodeStartValue_.store(value.value, std::memory_order_relaxed);
    decodeStartScale_.store(value.timescale, std::memory_order_release);
  }

  // The demuxer's cancellation seam is a POD probe rather than an object, so
  // this latch is what planGeneration(), every cursor read and every payload
  // copy observes. Only the owner thread, inside a demuxer call it made
  // itself, dereferences the context, so the probe reads atomics only.
  [[nodiscard]] bool isCancelled() const noexcept {
    const std::uint64_t active = activeEpoch_.load(std::memory_order_acquire);
    return active != 0 &&
           cancelledEpoch_.load(std::memory_order_acquire) == active;
  }

  [[nodiscard]] static bool cancellationProbe(const void* context) noexcept {
    const auto* self = static_cast<const NativePreviewSourceCore*>(context);
    return self != nullptr && self->isCancelled();
  }

  [[nodiscard]] media::CancellationToken cancellation() const noexcept {
    return media::CancellationToken{this,
                                    &NativePreviewSourceCore::cancellationProbe};
  }

  NativePreviewBinding binding_;
  std::shared_ptr<const AssetContext> context_;
  std::shared_ptr<const PreparedAsset> asset_;
  // Borrowed from the descriptor the binding retains for this source's whole
  // life, so the pointer cannot dangle and the track cannot be reselected.
  const media::MediaTrackDescriptor* track_{nullptr};
  // One format description for the source, not one per epoch: a second,
  // distinct description object would force a decoder reconfiguration
  // between two scrub targets of the same file.
  CMVideoFormatDescriptionRef format_{nullptr};
  media::MediaSourceLimits limits_{};
  typename Traits::PreviewWorkspace workspace_{};

  std::unique_ptr<Cursor> cursor_;
  media::MediaTime target_{};
  bool eos_{false};

  std::atomic<std::uint64_t> activeEpoch_{0};
  std::atomic<std::uint64_t> operationEpoch_{0};
  std::atomic<std::uint64_t> epochHighWater_{0};
  std::atomic<std::uint64_t> cancelledEpoch_{0};
  std::atomic<std::int64_t> targetValue_{0};
  std::atomic<std::int32_t> targetScale_{0};
  std::atomic<std::int64_t> decodeStartValue_{0};
  std::atomic<std::int32_t> decodeStartScale_{0};
  std::atomic<std::size_t> stagedSampleBuffers_{0};
  std::atomic<std::size_t> peakStagedSampleBuffers_{0};
  std::atomic<std::uint64_t> currentStagedCompressedBytes_{0};
  std::atomic<std::uint64_t> peakStagedCompressedBytes_{0};
  std::atomic<std::uint64_t> samplesRead_{0};
  std::atomic<std::uint64_t> forwardRetargets_{0};
  // The preview's own reader counters; the shared asset context separately
  // accumulates the same two facts across main seeks and previews.
  std::atomic<std::uint64_t> cursorCreationAttempts_{0};
  std::atomic<std::uint64_t> cursorsStarted_{0};
  std::atomic<bool> open_{false};
};

}  // namespace wam::macos
