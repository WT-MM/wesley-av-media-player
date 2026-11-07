#pragma once

#include "media/audio_track_admission.hpp"
#include "media/native_media_source.hpp"
#include "platform/macos/core_media_carriage.hpp"
#include "platform/macos/core_media_source_support.hpp"

#include <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <variant>

namespace wam::macos {

// The one media-source body shared by every macOS backend (AVFoundation,
// libavformat, Matroska, MPEG-TS). It owns the whole neutral MediaSource
// facade, the generation/cancellation algebra, the staged-head accounting, the
// capacity-one refill discipline, the A/V merge and the audio-track retry, and
// leaves the backend-specific work to two compile-time parameters:
//
//   Traits   -- kName (the word that opens every error text) and AssetContext
//               (the immutable prepared context a seek must reuse).
//   Derived  -- the backend's Impl, which supplies
//                 begin(path, options, generation, target, mode, context)
//                     one generation start; it calls resetForGeneration() first
//                     and stages one admission head per selected output
//                 stage(video, admission, error)
//                     reads one head into its lane (or ends the lane)
//                 retireActive()       releases the generation's readers
//                 cancellationPublished(generation)  (optional) out-of-band
//                     cancel of a reader that does not poll the latch
//                 resetSourceFacts()   (optional) close-time reset
//
// NativeCustomSourceCore below supplies begin/stage/retireActive for backends
// built on a neutral, payload-free custom demuxer.
//
// Everything resolves at compile time. There is no virtual call, no
// std::function and no allocation introduced on the per-sample path.
template <class Derived, class Traits>
class NativeSourceCore {
 public:
  using AssetContext = typename Traits::AssetContext;

  struct StagedSample {
    media::MediaTrackId track{0};
    media::MediaTime orderTime{};
    std::variant<media::MediaSample, media::MediaDiscontinuity> value;
    std::size_t payloadBytes{0};
  };

  // One selected output's capacity-one staging lane.
  class Lane {
   public:
    // No head: before admission staging, or after a refill failed.
    struct Empty {};
    // The head was delivered; it is restaged only on the next pull, so the
    // first delivered sample never waits on a speculative replacement read.
    struct RefillPending {};
    // The cursor ended, or the output is unselected.
    struct Ended {};
    struct EndEmitted {};

    [[nodiscard]] const StagedSample* head() const noexcept {
      return std::get_if<StagedSample>(&state_);
    }
    [[nodiscard]] bool refillPending() const noexcept {
      return std::holds_alternative<RefillPending>(state_);
    }
    // Ended and its end of stream not yet delivered.
    [[nodiscard]] bool ended() const noexcept {
      return std::holds_alternative<Ended>(state_);
    }
    [[nodiscard]] bool terminal() const noexcept {
      return ended() || std::holds_alternative<EndEmitted>(state_);
    }

    void reset(bool selected) noexcept {
      state_ = selected ? State{Empty{}} : State{Ended{}};
    }
    void stage(StagedSample sample) { state_ = std::move(sample); }
    void end() noexcept { state_ = Ended{}; }
    void endEmitted() noexcept { state_ = EndEmitted{}; }
    // Starts a refill: the demand edge is consumed before the read, so a read
    // failure leaves the lane Empty rather than retried by a later pull.
    void beginRefill() noexcept { state_ = Empty{}; }
    [[nodiscard]] StagedSample take() {
      StagedSample sample = std::move(std::get<StagedSample>(state_));
      state_ = RefillPending{};
      return sample;
    }
    // Drops a staged head or pending refill; an ended lane stays ended.
    void clear() noexcept {
      if (head() != nullptr || refillPending()) {
        state_ = Empty{};
      }
    }

   private:
    using State =
        std::variant<Empty, StagedSample, RefillPending, Ended, EndEmitted>;
    State state_{Ended{}};
  };

  // The source's owner-side lifecycle: Closed, or Open on `generation`, where
  // OpenFailed keeps delivering its staged heads and then reports its sticky
  // read failure.
  struct Closed {};
  struct Open {};
  struct OpenFailed {
    std::string message;
  };

  struct GenerationStart {
    media::MediaSourceOpenStatus status{media::MediaSourceOpenStatus::Failed};
    media::MediaTime actualDecodeStart{};
    std::shared_ptr<const media::MediaSourceDescriptor> descriptor;
    std::shared_ptr<const AssetContext> context;
    media::MediaAudioGenerationWindow audioWindow{};
    std::string error;
    media::MediaRefusalClass refusal{media::MediaRefusalClass::None};
  };

  NativeSourceCore() = default;
  NativeSourceCore(const NativeSourceCore&) = delete;
  NativeSourceCore& operator=(const NativeSourceCore&) = delete;

  std::filesystem::path path;
  media::MediaSourceOpenOptions options;
  media::MediaSourceLimits limits;
  std::shared_ptr<const media::MediaSourceDescriptor> descriptor;
  std::shared_ptr<const AssetContext> assetContext;
  Lane videoLane;
  Lane audioLane;
  std::optional<media::MediaTime> requestedTarget;
  media::MediaSeekMode seekMode{media::MediaSeekMode::Accurate};
  std::variant<Closed, Open, OpenFailed> phase;
  media::MediaGeneration generation{0};
  // An armed operation not yet consumed by open or seek.
  std::optional<media::MediaGeneration> armedGeneration;
  // Audio tracks the session refused during this cold open; cleared by arm().
  media::AudioTrackRejections rejectedAudio;

  std::atomic<media::MediaGeneration> operationGeneration{0};
  std::atomic<media::MediaGeneration> cancelledGeneration{0};
  std::atomic<media::MediaGeneration> generationHighWater{0};
  std::atomic<media::MediaGeneration> stagedGeneration{0};
  std::atomic<std::size_t> stagedVideoHeads{0};
  std::atomic<std::size_t> stagedAudioHeads{0};
  std::atomic<std::size_t> stagedPayloadBytes{0};
  std::atomic<std::size_t> peakStagedPayloadBytes{0};
  std::atomic<std::uint64_t> samplesEmitted{0};
  std::atomic<std::uint64_t> seeksAccepted{0};
  std::atomic<bool> openSnapshot{false};

  // ---- error text ---------------------------------------------------------

  [[nodiscard]] static std::string named(const char* before,
                                         const char* after) {
    std::string text(before);
    text += Traits::kName;
    text += after;
    return text;
  }

  static void assignNamed(std::string* error, const char* before,
                          const char* after) {
    if (error != nullptr) {
      *error = named(before, after);
    }
  }

  // The accurate-seek decodeOnly verdict and the neutral validation, applied to
  // a sample whose timing fields are final.
  [[nodiscard]] bool sealSample(media::MediaSample& sample, bool video,
                                std::string* error) const {
    if (video && requestedTarget &&
        seekMode == media::MediaSeekMode::Accurate) {
      const auto decodeOnly = accurateVideoDecodeOnly(
          sample.presentationTime, sample.duration, *requestedTarget, error);
      if (!decodeOnly) {
        return false;
      }
      sample.decodeOnly = *decodeOnly;
    }
    return media::validateMediaSample(sample, *descriptor, limits, error);
  }

  // ---- generation admission shared by every begin() ----------------------

  [[nodiscard]] static bool selectsRequiredTracks(
      const media::MediaSourceDescriptor& admitted,
      const media::MediaSourceOpenOptions& requested, std::string* error) {
    if ((requested.selection.requireVideo && !admitted.selectedVideo) ||
        (requested.selection.requireAudio && !admitted.selectedAudio)) {
      if (error != nullptr) {
        *error = named("", " did not select every required track");
      }
      return false;
    }
    return true;
  }

  void installGeneration(
      std::shared_ptr<const media::MediaSourceDescriptor> admitted,
      std::shared_ptr<const AssetContext> context) noexcept {
    descriptor = std::move(admitted);
    assetContext = std::move(context);
    videoLane.reset(descriptor->selectedVideo.has_value());
    audioLane.reset(descriptor->selectedAudio.has_value());
  }

  // Admission proof: one real head retained from every selected output. The
  // contract forbids probing and reopening, so these exact heads are what the
  // first readNext() calls deliver. False on refusal or cancellation.
  [[nodiscard]] bool stageAdmissionHeads(std::string* error) {
    return (videoLane.terminal() || derived().stage(true, true, error)) &&
           (audioLane.terminal() || derived().stage(false, true, error)) &&
           !isCancelled();
  }

  void publishOpen() noexcept {
    phase = Open{};
    openSnapshot.store(true, std::memory_order_release);
  }

  // A generation must begin on a real, positive-duration sync picture: the
  // plan always starts video at a random access point, and restating it keeps
  // a malformed index from admitting a generation that can never decode. A
  // positive duration is required because every downstream video consumer
  // compares the sample's exact interval against the timeline.
  //
  // allowPreroll admits a negative presentation time. On a movie timeline the
  // random-access point a head-trimmed edit list makes the reader walk back to
  // legitimately precedes the origin: it decodes the picture AT the origin and
  // is preroll, marked decodeOnly and retired against the presentation floor.
  [[nodiscard]] static bool admitsFirstVideoSample(
      const media::MediaSample& sample, bool allowPreroll,
      std::string* error) {
    if (!sample.keyFrame || !sample.presentationTime.valid() ||
        (!allowPreroll && sample.presentationTime.value < 0) ||
        !sample.duration.valid() || sample.duration.value <= 0) {
      assignError(error, allowPreroll
                             ? "first video sample is not a positive-duration "
                               "sync access unit"
                             : "first video sample is not a nonnegative "
                               "positive-duration sync access unit");
      return false;
    }
    return true;
  }

  // ---- derived hooks with defaults ---------------------------------------

  void cancellationPublished(media::MediaGeneration) noexcept {}
  void resetSourceFacts() noexcept {}

  // ---- generation algebra -------------------------------------------------

  [[nodiscard]] Lane& lane(bool video) noexcept {
    return video ? videoLane : audioLane;
  }

  [[nodiscard]] bool isOpen() const noexcept {
    return !std::holds_alternative<Closed>(phase);
  }

  [[nodiscard]] bool arm(media::MediaGeneration requested) noexcept {
    if (requested == 0 || armedGeneration) {
      return false;
    }
    media::MediaGeneration observed =
        generationHighWater.load(std::memory_order_acquire);
    while (observed < requested) {
      if (generationHighWater.compare_exchange_weak(
              observed, requested, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        cancelledGeneration.store(0, std::memory_order_release);
        armedGeneration = requested;
        operationGeneration.store(requested, std::memory_order_release);
        rejectedAudio = {};
        return true;
      }
    }
    return false;
  }

  [[nodiscard]] bool consumeArm(media::MediaGeneration requested) noexcept {
    if (armedGeneration != requested ||
        operationGeneration.load(std::memory_order_acquire) != requested) {
      return false;
    }
    armedGeneration.reset();
    return true;
  }

  [[nodiscard]] bool operationCancelled(
      media::MediaGeneration requested) const noexcept {
    return requested != 0 &&
           cancelledGeneration.load(std::memory_order_acquire) == requested;
  }

  void restoreCurrentPublicationAfterRejectedOperation() noexcept {
    operationGeneration.store(isOpen() ? generation : 0,
                              std::memory_order_release);
  }

  [[nodiscard]] bool isCancelled() const noexcept {
    return cancelledGeneration.load(std::memory_order_acquire) == generation &&
           generation != 0;
  }

  void publishCancellation(media::MediaGeneration requested) noexcept {
    if (requested == 0 ||
        operationGeneration.load(std::memory_order_acquire) != requested) {
      return;
    }
    media::MediaGeneration observed =
        cancelledGeneration.load(std::memory_order_relaxed);
    while (observed < requested &&
           !cancelledGeneration.compare_exchange_weak(
               observed, requested, std::memory_order_release,
               std::memory_order_relaxed)) {
    }
    derived().cancellationPublished(requested);
  }

  // ---- staged-head accounting --------------------------------------------

  void updatePeak(std::size_t total) noexcept {
    std::size_t peak = peakStagedPayloadBytes.load(std::memory_order_relaxed);
    while (peak < total && !peakStagedPayloadBytes.compare_exchange_weak(
                               peak, total, std::memory_order_relaxed,
                               std::memory_order_relaxed)) {
    }
  }

  void publishHeadFacts() noexcept {
    const StagedSample* video = videoLane.head();
    const StagedSample* audio = audioLane.head();
    const std::size_t videoCount = video ? 1 : 0;
    const std::size_t audioCount = audio ? 1 : 0;
    const std::size_t videoBytes = video ? video->payloadBytes : 0;
    const std::size_t audioBytes = audio ? audio->payloadBytes : 0;
    const std::size_t total = videoBytes + audioBytes;
    stagedVideoHeads.store(videoCount, std::memory_order_relaxed);
    stagedAudioHeads.store(audioCount, std::memory_order_relaxed);
    stagedPayloadBytes.store(total, std::memory_order_relaxed);
    updatePeak(total);
    stagedGeneration.store(videoCount + audioCount == 0 ? 0 : generation,
                           std::memory_order_release);
  }

  // Stages one head into its lane and publishes the staged facts.
  void stageHead(bool video, StagedSample sample) {
    lane(video).stage(std::move(sample));
    publishHeadFacts();
  }

  void clearHeads() noexcept {
    videoLane.clear();
    audioLane.clear();
    publishHeadFacts();
  }

  // Open -> Closed: releases the generation's readers, heads and identity.
  // The operation slot is the caller's to withdraw or keep.
  void enterClosed() noexcept {
    derived().retireActive();
    clearHeads();
    descriptor.reset();
    assetContext.reset();
    phase = Closed{};
    openSnapshot.store(false, std::memory_order_release);
  }

  void withdrawFailedOperation() noexcept {
    operationGeneration.store(0, std::memory_order_release);
    enterClosed();
  }

  // The reset every generation start begins with. False when the operation
  // was cancelled, which has already been withdrawn.
  [[nodiscard]] bool resetForGeneration(
      const media::MediaSourceOpenOptions& requestedOptions,
      media::MediaGeneration requestedGeneration,
      const std::optional<media::MediaTime>& target,
      media::MediaSeekMode mode) noexcept {
    generation = requestedGeneration;
    limits = media::clampMediaSourceLimits(requestedOptions.limits);
    requestedTarget = target;
    seekMode = mode;

    // armOperation() already published this exact cancellation slot before an
    // outer owner could expose the operation. Never clear that latch here.
    if (isCancelled()) {
      withdrawFailedOperation();
      return false;
    }
    enterClosed();
    videoLane.reset(true);
    audioLane.reset(true);

    if (isCancelled()) {
      withdrawFailedOperation();
      return false;
    }
    return true;
  }

  [[nodiscard]] bool refillPendingLane(bool video, std::string* error) {
    if (!lane(video).refillPending()) {
      return true;
    }
    lane(video).beginRefill();
    return derived().stage(video, false, error);
  }

  [[nodiscard]] bool refillPendingHeads(std::string* error) {
    return refillPendingLane(true, error) && refillPendingLane(false, error);
  }

  // ---- the neutral MediaSource facade -------------------------------------

  media::MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path& requestedPath,
      const media::MediaSourceOpenOptions& requestedOptions,
      media::MediaGeneration requestedGeneration) {
    media::MediaSourceOpenOutcome outcome;
    outcome.generation = requestedGeneration;
    try {
      if (!consumeArm(requestedGeneration)) {
        outcome.error = named("", " open generation was not armed");
        return outcome;
      }
      if (operationCancelled(requestedGeneration)) {
        generation = requestedGeneration;
        withdrawFailedOperation();
        outcome.status = media::MediaSourceOpenStatus::Cancelled;
        outcome.error = named("", " open was cancelled before entry");
        return outcome;
      }
      if (requestedPath.empty() || isOpen() ||
          !media::validateMediaSourceInitialPosition(
              requestedOptions.initialPosition, &outcome.error)) {
        if (outcome.error.empty()) {
          outcome.error = named("invalid ", " open path or state");
        }
        restoreCurrentPublicationAfterRejectedOperation();
        return outcome;
      }
      path = requestedPath;
      options = requestedOptions;
      std::optional<media::MediaTime> target;
      media::MediaSeekMode mode = media::MediaSeekMode::Accurate;
      if (requestedOptions.initialPosition) {
        target = requestedOptions.initialPosition->target;
        mode = requestedOptions.initialPosition->mode;
      }
      GenerationStart started =
          derived().begin(requestedPath, requestedOptions, requestedGeneration,
                          target, mode, nullptr);
      outcome.status = started.status;
      outcome.actualDecodeStart = started.actualDecodeStart;
      outcome.descriptor = std::move(started.descriptor);
      outcome.error = std::move(started.error);
      outcome.refusal = started.refusal;
      if (outcome.status == media::MediaSourceOpenStatus::Ready) {
        outcome.preparedContext = std::move(started.context);
        outcome.audioWindow = started.audioWindow;
      }
    } catch (const std::exception& exception) {
      withdrawFailedOperation();
      outcome.status = media::MediaSourceOpenStatus::Failed;
      outcome.error = exception.what();
    } catch (...) {
      withdrawFailedOperation();
      outcome.status = media::MediaSourceOpenStatus::Failed;
      outcome.error = named("", " open raised an unknown exception");
    }
    return outcome;
  }

  media::MediaSourceSeekOutcome seek(
      const media::MediaSourceSeekRequest& request) {
    media::MediaSourceSeekOutcome outcome;
    outcome.generation = request.generation;
    try {
      if (!consumeArm(request.generation)) {
        outcome.error = named("", " seek generation was not armed");
        return outcome;
      }
      if (operationCancelled(request.generation)) {
        generation = request.generation;
        withdrawFailedOperation();
        outcome.error = named("", " seek was cancelled before entry");
        return outcome;
      }
      const std::optional<media::MediaSourceInitialPosition> position{
          media::MediaSourceInitialPosition{request.target, request.mode}};
      if (!isOpen() || request.generation == 0 ||
          request.generation <= generation ||
          !media::validateMediaSourceInitialPosition(position,
                                                     &outcome.error) ||
          descriptor == nullptr ||
          !exactNonnegativeTimeWithinDuration(request.target,
                                              descriptor->duration)) {
        if (outcome.error.empty()) {
          outcome.error = named("invalid ", " seek request");
        }
        restoreCurrentPublicationAfterRejectedOperation();
        return outcome;
      }
      const auto priorDescriptor = descriptor;
      const auto priorContext = assetContext;
      GenerationStart started = derived().begin(
          path, options, request.generation,
          std::optional<media::MediaTime>{request.target}, request.mode,
          priorContext);
      if (started.status != media::MediaSourceOpenStatus::Ready) {
        outcome.error = std::move(started.error);
        return outcome;
      }
      // The dispatcher rejects a generation whose context pointer moved, so the
      // exact instance admitted by open is the only acceptable answer here.
      if (priorDescriptor == nullptr || priorContext == nullptr ||
          descriptor.get() != priorDescriptor.get() ||
          assetContext.get() != priorContext.get()) {
        outcome.error = named("", " prepared identity changed across seek");
        withdrawFailedOperation();
        return outcome;
      }
      outcome.accepted = true;
      outcome.actualDecodeStart = started.actualDecodeStart;
      outcome.preparedContext = assetContext;
      outcome.audioWindow = started.audioWindow;
      seeksAccepted.store(
          saturatingSum(seeksAccepted.load(std::memory_order_relaxed), 1),
          std::memory_order_relaxed);
    } catch (const std::exception& exception) {
      withdrawFailedOperation();
      outcome.error = exception.what();
    } catch (...) {
      withdrawFailedOperation();
      outcome.error = named("", " seek raised an unknown exception");
    }
    return outcome;
  }

  media::MediaSourceReadResult readNext(
      media::MediaGeneration expectedGeneration) {
    try {
      if (!isOpen() || expectedGeneration != generation || isCancelled()) {
        if (isCancelled()) {
          withdrawFailedOperation();
        }
        return media::MediaSourceCancelled{expectedGeneration};
      }

      // Admission already owns one exact head per selected output. Once a head
      // has been consumed, replenish that lane only on the next downstream
      // pull, then restore the complete A/V merge frontier before comparing
      // times.
      if (std::holds_alternative<Open>(phase)) {
        std::string refillError;
        bool refilled = false;
        try {
          refilled = refillPendingHeads(&refillError);
        } catch (const std::exception& exception) {
          refillError = exception.what();
        } catch (...) {
          refillError = named("", " staging raised an unknown exception");
        }
        if (!refilled) {
          if (isCancelled()) {
            withdrawFailedOperation();
            return media::MediaSourceCancelled{expectedGeneration};
          }
          phase = OpenFailed{
              refillError.empty()
                  ? named("", " could not stage the next sample")
                  : std::move(refillError)};
        }
      }

      // THE MERGE. Both lanes are ordered on Traits::mergeOrderKey, and video
      // wins ties: whichever key a container states, a tie means the two
      // decoders want the data at the same instant and the video path is the
      // one with the longer pipeline ahead of it.
      const StagedSample* videoHead = videoLane.head();
      const StagedSample* audioHead = audioLane.head();
      Lane* chosen = nullptr;
      if (videoHead && audioHead) {
        const auto order = media::compareMediaTime(videoHead->orderTime,
                                                   audioHead->orderTime);
        if (!order) {
          phase = OpenFailed{"staged samples have incomparable timestamps"};
        } else {
          chosen = *order != media::MediaTimeOrder::Greater ? &videoLane
                                                            : &audioLane;
        }
      } else if (videoHead) {
        chosen = &videoLane;
      } else if (audioHead) {
        chosen = &audioLane;
      }
      if (chosen != nullptr) {
        StagedSample emitted = chosen->take();
        publishHeadFacts();
        if (auto* sample = std::get_if<media::MediaSample>(&emitted.value)) {
          samplesEmitted.store(saturatingSum(samplesEmitted.load(
                                   std::memory_order_relaxed), 1),
                               std::memory_order_relaxed);
          return std::move(*sample);
        }
        return std::get<media::MediaDiscontinuity>(std::move(emitted.value));
      }
      if (const auto* failed = std::get_if<OpenFailed>(&phase)) {
        return media::MediaSourceFailure{generation, failed->message};
      }
      if (videoLane.ended() && descriptor->selectedVideo) {
        videoLane.endEmitted();
        return media::MediaEndOfStream{generation, *descriptor->selectedVideo};
      }
      if (audioLane.ended() && descriptor->selectedAudio) {
        audioLane.endEmitted();
        return media::MediaEndOfStream{generation, *descriptor->selectedAudio};
      }
      return media::MediaSourceExhausted{generation};
    } catch (const std::exception& exception) {
      return media::MediaSourceFailure{expectedGeneration, exception.what()};
    } catch (...) {
      return media::MediaSourceFailure{
          expectedGeneration, named("", " read raised an unknown exception")};
    }
  }

  // Reopens the same cold open without the rejected audio track. Retry is
  // part of that open: cancellation and its generation high-water survive the
  // retirement and cannot be cleared here.
  media::MediaSourceOpenOutcome retryAudioTrack(
      const std::filesystem::path& requestedPath,
      const media::MediaSourceOpenOptions& requestedOptions,
      media::MediaGeneration requestedGeneration, media::MediaTrackId rejected) {
    if (requestedOptions.selection.preferredAudio || !descriptor ||
        descriptor->selectedAudio != rejected ||
        generation != requestedGeneration || !rejectedAudio.add(rejected)) {
      media::MediaSourceOpenOutcome out;
      out.generation = requestedGeneration;
      out.refusal = media::MediaRefusalClass::AudioTrackRetryExhausted;
      out.error = media::mediaRefusalClassName(out.refusal);
      return out;
    }
    enterClosed();
    // Open -> Armed without the high-water check arm() makes: the retry is
    // the same, already admitted cold-open operation.
    armedGeneration = requestedGeneration;
    operationGeneration.store(requestedGeneration, std::memory_order_release);
    return openLocalFile(requestedPath, requestedOptions, requestedGeneration);
  }

  void requestCancel(media::MediaGeneration requested) noexcept {
    try {
      publishCancellation(requested);
    } catch (...) {
    }
  }

  void close() noexcept {
    try {
      operationGeneration.store(0, std::memory_order_release);
      enterClosed();
      path.clear();
      armedGeneration.reset();
      requestedTarget.reset();
      derived().resetSourceFacts();
    } catch (...) {
    }
  }

  [[nodiscard]] media::MediaSourceStats stats() const noexcept {
    media::MediaSourceStats result;
    result.open = openSnapshot.load(std::memory_order_acquire);
    result.operationGeneration =
        operationGeneration.load(std::memory_order_acquire);
    result.generation = generationHighWater.load(std::memory_order_acquire);
    result.cancelled =
        result.operationGeneration != 0 &&
        cancelledGeneration.load(std::memory_order_acquire) ==
            result.operationGeneration;
    result.stagedGeneration = stagedGeneration.load(std::memory_order_acquire);
    result.stagedVideoHeads = stagedVideoHeads.load(std::memory_order_relaxed);
    result.stagedAudioHeads = stagedAudioHeads.load(std::memory_order_relaxed);
    result.stagedPayloadBytes =
        stagedPayloadBytes.load(std::memory_order_relaxed);
    result.peakStagedPayloadBytes =
        std::max(peakStagedPayloadBytes.load(std::memory_order_relaxed),
                 result.stagedPayloadBytes);
    result.samplesEmitted = samplesEmitted.load(std::memory_order_relaxed);
    result.seeksAccepted = seeksAccepted.load(std::memory_order_relaxed);
    return result;
  }

 private:
  [[nodiscard]] Derived& derived() noexcept {
    return static_cast<Derived&>(*this);
  }
};

// The begin/stage/retire half for backends built on a neutral, payload-free
// custom demuxer (Matroska, MPEG-TS). Traits additionally supplies:
//   kVideoRequired         whether a generation without a video cursor may be
//                          admitted (audio-only)
//   PreparedAsset, Cursor, CompressedSample, CursorReadResult, CursorEnd,
//   CursorCancelled, CursorFailure, Plan, PrepareOutcome, PlanOutcome,
//   CancellationToken
//   prepare(path, options, token)  (unless Derived supplies prepareAsset with
//                          the same shape)
//   adoptContext(path, options, asset)
//   noteCursorCreationAttempt(context) / noteCursorStarted(context)
//   videoOrigin(asset)     the first video access unit's time, or empty when
//                          the container states none
//   mergeOrderKey(sample)  THE A/V MERGE KEY (see readNext)
// and Derived supplies:
//   makeHead(raw, video, error)      one cursor sample -> one staged sample
//   prepareTrackFacts(plan, error)   per-generation track facts
//   stateAudioWindow(plan, window, error)
//                                    the audio generation window, stated from
//                                    the plan or derived from the staged head
//   resetContainerFacts()            close-time reset (optional)
template <class Derived, class Traits>
class NativeCustomSourceCore : public NativeSourceCore<Derived, Traits> {
 public:
  using Base = NativeSourceCore<Derived, Traits>;
  using typename Base::AssetContext;
  using typename Base::GenerationStart;
  using typename Base::StagedSample;
  using PreparedAsset = typename Traits::PreparedAsset;
  using Cursor = typename Traits::Cursor;
  using CompressedSample = typename Traits::CompressedSample;
  using CursorReadResult = typename Traits::CursorReadResult;
  using CursorEnd = typename Traits::CursorEnd;
  using CursorCancelled = typename Traits::CursorCancelled;
  using CursorFailure = typename Traits::CursorFailure;
  using Plan = typename Traits::Plan;
  using CancellationToken = typename Traits::CancellationToken;

  using Base::assetContext;
  using Base::assignNamed;
  using Base::clearHeads;
  using Base::descriptor;
  using Base::generation;
  using Base::isCancelled;
  using Base::lane;
  using Base::limits;
  using Base::named;
  using Base::openSnapshot;
  using Base::publishCancellation;
  using Base::requestedTarget;
  using Base::seekMode;
  using Base::stageHead;
  using Base::withdrawFailedOperation;

  NativeCustomSourceCore() = default;
  ~NativeCustomSourceCore() { releaseFormats(); }

  std::unique_ptr<Cursor> videoCursor;
  std::unique_ptr<Cursor> audioCursor;
  CMVideoFormatDescriptionRef videoFormat{nullptr};
  CMAudioFormatDescriptionRef audioFormat{nullptr};
  // One-shot latch per generation: the converter reads the playout proof from
  // the first access unit it ever sees and never looks again.
  bool audioProofStated{false};
  std::optional<media::MediaTime> audioProofCeiling;
  media::MediaTime audioDecodeStart{};
  std::int64_t audioFramesPerPacket{0};
  std::int32_t audioSampleRate{0};

  // The demuxer's cancellation seam is a POD probe rather than an object, so
  // the source's own latch is what every plan, cursor read, and payload copy
  // observes. Only the owner thread dereferences the context.
  [[nodiscard]] static bool cancellationProbe(const void* context) noexcept {
    const auto* core = static_cast<const NativeCustomSourceCore*>(context);
    return core != nullptr && core->isCancelled();
  }

  [[nodiscard]] CancellationToken cancellation() const noexcept {
    return CancellationToken{this, &NativeCustomSourceCore::cancellationProbe};
  }

  void releaseFormats() noexcept {
    if (videoFormat != nullptr) {
      CFRelease(videoFormat);
      videoFormat = nullptr;
    }
    if (audioFormat != nullptr) {
      CFRelease(audioFormat);
      audioFormat = nullptr;
    }
  }

  void retireActive() noexcept {
    videoCursor.reset();
    audioCursor.reset();
    releaseFormats();
  }

  // Close-time reset of container-only facts. Shadowed by a Derived that keeps
  // state outside the shared audio facts.
  void resetContainerFacts() noexcept {}

  void resetSourceFacts() noexcept {
    resetAudioFacts();
    derived().resetContainerFacts();
  }

  // ---- staging helpers shared by every makeHead ---------------------------

  void resetAudioFacts() noexcept {
    audioProofStated = false;
    audioProofCeiling.reset();
    audioDecodeStart = media::MediaTime{};
    audioFramesPerPacket = 0;
    audioSampleRate = 0;
  }

  // Measured, never assumed: the attachment asserts that the decoder has
  // already consumed the full priming window ahead of the first audible frame.
  // An unproved unit is left untouched on purpose so the converter rejects the
  // generation instead of publishing un-primed PCM.
  void stateAudioPlayoutProofOnce(media::MediaTime presentation,
                                  CMSampleBufferRef sample) noexcept {
    if (audioProofStated) {
      return;
    }
    audioProofStated = true;
    if (!audioProofCeiling) {
      return;
    }
    const auto order = media::compareMediaTime(presentation, *audioProofCeiling);
    if (order && *order != media::MediaTimeOrder::Greater) {
      static_cast<void>(statedImmediatePlayoutFrame(sample));
    }
  }

  // ---- staging ------------------------------------------------------------

  [[nodiscard]] bool stage(bool video, bool admission, std::string* error) {
    const std::optional<media::MediaTrackId> selected =
        video ? descriptor->selectedVideo : descriptor->selectedAudio;
    Cursor* cursor = video ? videoCursor.get() : audioCursor.get();
    if (!selected) {
      lane(video).end();
      return true;
    }
    if (cursor == nullptr) {
      assignNamed(error, "selected ", " output has no cursor");
      return false;
    }
    const CursorReadResult result = cursor->readNext(cancellation());
    if (std::holds_alternative<CursorCancelled>(result) || isCancelled()) {
      publishCancellation(generation);
      assignNamed(error, "", " generation was cancelled");
      return false;
    }
    if (const auto* failed = std::get_if<CursorFailure>(&result)) {
      if (error != nullptr) {
        *error = media::refusalMessage(
            failed->message.empty() ? named("", " cursor read failed").c_str()
                                    : failed->message.c_str(),
            failed->error);
      }
      return false;
    }
    if (std::holds_alternative<CursorEnd>(result)) {
      lane(video).end();
      if (admission) {
        assignNamed(error, "selected ", " output has no admission sample");
        return false;
      }
      return true;
    }
    std::optional<StagedSample> head =
        derived().makeHead(std::get<CompressedSample>(result), video, error);
    if (!head) {
      return false;
    }
    const media::MediaSample& sample = std::get<media::MediaSample>(head->value);
    head->orderTime = Traits::mergeOrderKey(sample);
    if (admission && video &&
        !Base::admitsFirstVideoSample(sample, false, error)) {
      return false;
    }
    stageHead(video, std::move(*head));
    return true;
  }

  // ---- generation start ---------------------------------------------------

  [[nodiscard]] GenerationStart begin(
      const std::filesystem::path& requestedPath,
      const media::MediaSourceOpenOptions& requestedOptions,
      media::MediaGeneration requestedGeneration,
      const std::optional<media::MediaTime>& target,
      media::MediaSeekMode mode,
      const std::shared_ptr<const AssetContext>& existingContext) {
    GenerationStart started;
    if (!this->resetForGeneration(requestedOptions, requestedGeneration,
                                  target, mode)) {
      started.status = media::MediaSourceOpenStatus::Cancelled;
      return started;
    }

    // A seek reuses the exact asset admitted by open. Only a cold open pays for
    // container parsing, and only a cold open may produce a new context.
    std::shared_ptr<const AssetContext> context = existingContext;
    if (context == nullptr) {
      const typename Traits::PrepareOutcome prepared =
          [&] {
            if constexpr (requires { derived().prepareAsset(
                requestedPath, requestedOptions, cancellation()); }) {
              return derived().prepareAsset(
                  requestedPath, requestedOptions, cancellation());
            } else {
              return Traits::prepare(requestedPath, requestedOptions, cancellation());
            }
          }();
      started.status = prepared.status;
      if (prepared.status != media::MediaSourceOpenStatus::Ready || prepared.asset == nullptr) {
        started.error = media::refusalMessage(
            prepared.message.empty() ? named("", " preparation failed").c_str()
                                     : prepared.message.c_str(),
            prepared.error);
        started.refusal = prepared.error;
        if (prepared.status == media::MediaSourceOpenStatus::Ready) {
          started.status = media::MediaSourceOpenStatus::Failed;
        }
        withdrawFailedOperation();
        return started;
      }
      context =
          Traits::adoptContext(requestedPath, requestedOptions, prepared.asset);
      if (context == nullptr ||
          !context->matchesMainRequest(requestedPath, requestedOptions,
                                       prepared.asset->descriptor())) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error =
            named("", " asset context did not admit its own identity");
        withdrawFailedOperation();
        return started;
      }
    }

    const std::shared_ptr<const PreparedAsset>& asset = context->asset();
    if (asset == nullptr || context->descriptor() == nullptr ||
        context->descriptor().get() != asset->descriptor().get()) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error =
          named("", " context changed its immutable asset identity");
      withdrawFailedOperation();
      return started;
    }
    started.descriptor = context->descriptor();
    started.context = context;
    if (!media::validateMediaSourceDescriptor(*started.descriptor, limits,
                                              &started.error)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }
    if (!Base::selectsRequiredTracks(*started.descriptor, requestedOptions,
                                     &started.error)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }
    if (requestedTarget &&
        (requestedTarget->value < 0 ||
         !exactNonnegativeTimeWithinDuration(*requestedTarget,
                                             started.descriptor->duration))) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error = "requested position is outside the exact source timeline";
      withdrawFailedOperation();
      return started;
    }

    const typename Traits::PlanOutcome planned = asset->planGeneration(
        requestedTarget.value_or(media::MediaTime{0, 1}), seekMode,
        cancellation());
    if (planned.status != media::MediaSourceOpenStatus::Ready || !planned.plan) {
      started.status = planned.status == media::MediaSourceOpenStatus::Ready
                           ? media::MediaSourceOpenStatus::Failed
                           : planned.status;
      started.error = media::refusalMessage(
          planned.message.empty()
              ? named("", " generation planning failed").c_str()
              : planned.message.c_str(),
          planned.error);
      started.refusal = planned.error;
      withdrawFailedOperation();
      return started;
    }
    const Plan& plan = *planned.plan;

    const std::optional<media::MediaTime> windowStart =
        timelineWindowDecodeStart(plan.actualDecodeStart, requestedTarget,
                                  Traits::videoOrigin(*asset));
    if (!windowStart) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error =
          named("", " plan starts after its own requested position");
      withdrawFailedOperation();
      return started;
    }

    this->installGeneration(started.descriptor, context);

    // One format description per generation, retained for every sample of it.
    // Rebuilding per sample would hand VideoToolbox a second, distinct
    // description object and force a decoder reconfiguration mid-stream.
    if (descriptor->selectedVideo) {
      const media::MediaTrackDescriptor* video =
          media::findMediaTrack(*descriptor, *descriptor->selectedVideo);
      videoFormat = video == nullptr
                        ? nullptr
                        : createVideoFormatDescription(*video);
      if (videoFormat == nullptr) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error = named(
            "", " video track has no admissible CoreMedia format description");
        withdrawFailedOperation();
        return started;
      }
    }
    if (descriptor->selectedAudio) {
      const media::MediaTrackDescriptor* audio =
          media::findMediaTrack(*descriptor, *descriptor->selectedAudio);
      audioFormat = audio == nullptr ? nullptr
                                     : createAudioFormatDescription(*audio);
      if (audioFormat == nullptr) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error = named(
            "", " audio track has no admissible CoreMedia format description");
        withdrawFailedOperation();
        return started;
      }
    }
    if (!derived().prepareTrackFacts(plan, &started.error)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }

    // A container that admits audio-only files creates a video cursor only for
    // a selected video track; one that requires video always asks, and takes
    // the demuxer's refusal as its own.
    if (descriptor->selectedVideo || Traits::kVideoRequired) {
      Traits::noteCursorCreationAttempt(*context);
      videoCursor = asset->makeVideoCursor(plan);
      if (videoCursor == nullptr) {
        started.status = media::MediaSourceOpenStatus::Failed;
        started.error = named("", " video cursor could not be created");
        withdrawFailedOperation();
        return started;
      }
      Traits::noteCursorStarted(*context);
    }
    if (descriptor->selectedAudio) {
      Traits::noteCursorCreationAttempt(*context);
      audioCursor = asset->makeAudioCursor(plan);
      if (audioCursor == nullptr) {
        started.status = media::MediaSourceOpenStatus::Failed;
        started.error = named("", " audio cursor could not be created");
        withdrawFailedOperation();
        return started;
      }
      Traits::noteCursorStarted(*context);
    }

    if (!this->stageAdmissionHeads(&started.error)) {
      started.status = isCancelled() ? media::MediaSourceOpenStatus::Cancelled
                                     : media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }
    if (!derived().stateAudioWindow(plan, started.audioWindow,
                                    &started.error)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }

    started.status = media::MediaSourceOpenStatus::Ready;
    started.actualDecodeStart = *windowStart;
    started.error.clear();
    this->publishOpen();
    return started;
  }

 private:
  [[nodiscard]] Derived& derived() noexcept {
    return static_cast<Derived&>(*this);
  }
};

}  // namespace wam::macos
