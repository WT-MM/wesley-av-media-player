#include "media/native_media_dispatcher.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <thread>
#include <type_traits>
#include <utility>

namespace wam::media {

namespace {

template <typename Integer>
void saturatingIncrement(Integer& value) noexcept {
  if (value != std::numeric_limits<Integer>::max()) {
    ++value;
  }
}

bool lifecycleFailure(NativeMediaConsumerProgress progress) noexcept {
  return progress == NativeMediaConsumerProgress::StaleGeneration ||
         progress == NativeMediaConsumerProgress::Unsupported ||
         progress == NativeMediaConsumerProgress::Failed;
}

// Verdict of one port's open-time configure() attempt. Skipped means the
// descriptor selected no track for that port, so the port was never exposed.
// Threw records an escaped exception without letting it cross a thread
// boundary or skip the join that the parallel configure depends on.
enum class OpenConfigureVerdict : std::uint8_t {
  Skipped,
  Accepted,
  Rejected,
  Threw,
};

[[nodiscard]] std::optional<NativeMediaGenerationTimeline> deriveTimeline(
    MediaGeneration generation, MediaSeekMode mode, MediaTime requestedTarget,
    MediaTime actualDecodeStart, MediaTime duration,
    const MediaTrackDescriptor* selectedAudio,
    MediaAudioGenerationWindow audioWindow,
    std::uint32_t maximumAudioSeekPrerollSeconds) noexcept {
  if (generation == 0 || !requestedTarget.valid() ||
      !actualDecodeStart.valid() || !duration.valid()) {
    return std::nullopt;
  }
  switch (mode) {
  case MediaSeekMode::Accurate:
  case MediaSeekMode::KeyFrame:
    break;
  default:
    return std::nullopt;
  }

  constexpr MediaTime kStreamOrigin{0, 1};
  const auto targetAgainstOrigin =
      compareMediaTime(requestedTarget, kStreamOrigin);
  const auto targetAgainstDuration =
      compareMediaTime(requestedTarget, duration);
  const auto decodeStartAgainstTarget =
      compareMediaTime(actualDecodeStart, requestedTarget);
  const auto decodeStartAgainstOrigin =
      compareMediaTime(actualDecodeStart, kStreamOrigin);
  const auto decodeStartAgainstDuration =
      compareMediaTime(actualDecodeStart, duration);
  if (!targetAgainstOrigin ||
      *targetAgainstOrigin == MediaTimeOrder::Less ||
      !targetAgainstDuration ||
      *targetAgainstDuration == MediaTimeOrder::Greater ||
      !decodeStartAgainstTarget ||
      *decodeStartAgainstTarget == MediaTimeOrder::Greater ||
      !decodeStartAgainstOrigin ||
      *decodeStartAgainstOrigin == MediaTimeOrder::Less ||
      !decodeStartAgainstDuration ||
      *decodeStartAgainstDuration == MediaTimeOrder::Greater) {
    return std::nullopt;
  }

  NativeMediaGenerationTimeline timeline;
  timeline.generation = generation;
  timeline.mode = mode;
  timeline.requestedTarget = requestedTarget;
  timeline.actualDecodeStart = actualDecodeStart;
  timeline.presentationFloor = mode == MediaSeekMode::Accurate
                                   ? requestedTarget
                                   : actualDecodeStart;
  timeline.startsAtStreamOrigin =
      *decodeStartAgainstOrigin == MediaTimeOrder::Equal;

  if (selectedAudio == nullptr) {
    if (audioWindow.decodeStart.valid() ||
        audioWindow.presentationStart.valid() ||
        audioWindow.startsAtStreamOrigin) {
      return std::nullopt;
    }
    return timeline;
  }
  if (selectedAudio->kind != MediaTrackKind::Audio ||
      !selectedAudio->audio ||
      !std::isfinite(selectedAudio->audio->sampleRate) ||
      selectedAudio->audio->sampleRate <= 0.0 ||
      selectedAudio->audio->sampleRate >
          static_cast<double>(std::numeric_limits<std::uint32_t>::max())) {
    return std::nullopt;
  }
  const auto sampleRate =
      static_cast<std::uint32_t>(selectedAudio->audio->sampleRate);
  if (selectedAudio->audio->sampleRate != static_cast<double>(sampleRate) ||
      !audioWindow.decodeStart.valid() ||
      !audioWindow.presentationStart.valid()) {
    return std::nullopt;
  }
  const auto decodeFrame =
      exactAudioFrameIndex(audioWindow.decodeStart, sampleRate);
  const auto presentationFrame =
      exactAudioFrameIndex(audioWindow.presentationStart, sampleRate);
  const auto decodeAgainstOrigin =
      compareMediaTime(audioWindow.decodeStart, kStreamOrigin);
  const auto presentationAgainstDuration =
      compareMediaTime(audioWindow.presentationStart, duration);
  const auto presentationAgainstAudioDuration =
      compareMediaTime(audioWindow.presentationStart,
                       selectedAudio->duration);
  if (!decodeFrame || !presentationFrame || *decodeFrame < 0 ||
      *presentationFrame < *decodeFrame || !decodeAgainstOrigin ||
      *decodeAgainstOrigin == MediaTimeOrder::Less ||
      !presentationAgainstDuration ||
      *presentationAgainstDuration == MediaTimeOrder::Greater ||
      !presentationAgainstAudioDuration ||
      *presentationAgainstAudioDuration == MediaTimeOrder::Greater ||
      audioWindow.startsAtStreamOrigin !=
          (*decodeAgainstOrigin == MediaTimeOrder::Equal)) {
    return std::nullopt;
  }
  const std::uint64_t prerollFrames = static_cast<std::uint64_t>(
      *presentationFrame - *decodeFrame);
  const std::uint64_t maximumPrerollFrames =
      static_cast<std::uint64_t>(maximumAudioSeekPrerollSeconds) *
      static_cast<std::uint64_t>(sampleRate);
  if (prerollFrames > maximumPrerollFrames) {
    return std::nullopt;
  }

  switch (mode) {
  case MediaSeekMode::Accurate: {
    const auto expected = audioFrameAtOrAfter(requestedTarget, sampleRate);
    const auto presentationAgainstExpected =
        expected ? compareMediaTime(audioWindow.presentationStart, *expected)
                 : std::optional<MediaTimeOrder>{};
    if (!presentationAgainstExpected ||
        *presentationAgainstExpected != MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    break;
  }
  case MediaSeekMode::KeyFrame:
    // v1 keyframe audio is admitted only when the common RAP/decode floor is
    // itself frame-aligned. It does not inherit Accurate target ceiling.
    if (*decodeFrame != *presentationFrame ||
        compareMediaTime(audioWindow.presentationStart,
                         timeline.presentationFloor) !=
            MediaTimeOrder::Equal) {
      return std::nullopt;
    }
    break;
  }
  timeline.audioWindow = audioWindow;
  return timeline;
}

}  // namespace

static_assert(std::is_standard_layout_v<NativeMediaGenerationTimeline>);
static_assert(std::is_trivially_copyable_v<NativeMediaGenerationTimeline>);
static_assert(std::is_trivially_copyable_v<NativeMediaDispatcherStep>);
static_assert(std::is_trivially_copyable_v<NativeMediaDispatcherOpenOutcome>);
static_assert(std::is_trivially_copyable_v<NativeMediaDispatcherSeekOutcome>);
static_assert(
    std::is_trivially_copyable_v<NativeMediaDispatcherLifecycleOutcome>);
static_assert(std::is_trivially_copyable_v<NativeMediaDispatcherStats>);

NativeMediaSampleDelivery::NativeMediaSampleDelivery(
    MediaSample& sample) noexcept
    : sample_(&sample) {}

const MediaSample& NativeMediaSampleDelivery::sample() const noexcept {
  return *sample_;
}

MediaSample NativeMediaSampleDelivery::take() noexcept {
  if (sample_ == nullptr || take_count_ != 0) {
    if (take_count_ != std::numeric_limits<std::uint8_t>::max()) {
      ++take_count_;
    }
    return {};
  }
  ++take_count_;
  return std::move(*sample_);
}

NativeMediaDispatcher::NativeMediaDispatcher(
    std::unique_ptr<MediaSource> source,
    std::unique_ptr<NativeVideoConsumer> video,
    std::unique_ptr<NativeAudioConsumer> audio) noexcept
    : source_(std::move(source)),
      video_(std::move(video)),
      audio_(std::move(audio)) {
  if (source_ == nullptr || video_ == nullptr || audio_ == nullptr) {
    stats_.state = NativeMediaDispatcherState::Failed;
    stats_.failure = NativeMediaDispatcherFailure::MissingDependency;
    stats_.lastAction = NativeMediaDispatcherAction::Failed;
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
  }
}

NativeMediaDispatcher::~NativeMediaDispatcher() { forceClose(); }

NativeMediaDispatcherOpenOutcome NativeMediaDispatcher::openLocalFile(
    const std::filesystem::path& path,
    const MediaSourceOpenOptions& options,
    MediaGeneration generation) noexcept {
  NativeMediaDispatcherOpenOutcome result;
  result.generation = generation;
  if (stats_.state != NativeMediaDispatcherState::Fresh || source_ == nullptr ||
      video_ == nullptr || audio_ == nullptr) {
    return result;
  }

  saturatingIncrement(stats_.openAttempts);
  stats_.generation = generation;
  if (path.empty() || generation == 0 ||
      !validateMediaSourceInitialPosition(options.initialPosition, nullptr)) {
    fail(NativeMediaDispatcherFailure::InvalidOpenRequest, generation);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  }

  limits_ = clampMediaSourceLimits(options.limits);
  if (!source_->armOperation(generation)) {
    // No source operation was entered, so there is no attempted generation to
    // cancel. In particular, do not let an arm rejection disturb an exact
    // operation that the source may already have published.
    fail(NativeMediaDispatcherFailure::SourceOpen);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  }
  operation_generation_.store(generation, std::memory_order_release);
  MediaSourceOpenOutcome opened;
  try {
    opened = source_->openLocalFile(path, options, generation);
  } catch (...) {
    fail(NativeMediaDispatcherFailure::SourceOpen, generation);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  }

  if (opened.generation != generation) {
    fail(NativeMediaDispatcherFailure::SourceOpen, generation);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  }
  switch (opened.status) {
  case MediaSourceOpenStatus::Unsupported:
    operation_generation_.store(0, std::memory_order_release);
    stats_.state = NativeMediaDispatcherState::Unsupported;
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
    result.status = NativeMediaDispatcherOpenStatus::Unsupported;
    return result;
  case MediaSourceOpenStatus::Cancelled:
    operation_generation_.store(0, std::memory_order_release);
    stats_.state = NativeMediaDispatcherState::Cancelled;
    stats_.lastAction = NativeMediaDispatcherAction::Cancelled;
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
    result.status = NativeMediaDispatcherOpenStatus::Cancelled;
    return result;
  case MediaSourceOpenStatus::Failed:
    fail(NativeMediaDispatcherFailure::SourceOpen, generation);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  case MediaSourceOpenStatus::Ready:
    break;
  }

  std::string validationError;
  const bool invalidPreparedContext =
      opened.preparedContext != nullptr &&
      (opened.preparedContext->descriptor().get() !=
           opened.descriptor.get() ||
       !opened.preparedContext->matchesMainRequest(path, options,
                                                   opened.descriptor));
  if (opened.descriptor == nullptr || invalidPreparedContext ||
      !opened.actualDecodeStart.valid() ||
      !validateMediaSourceDescriptor(*opened.descriptor, limits_,
                                     &validationError) ||
      (options.selection.requireVideo &&
       !opened.descriptor->selectedVideo.has_value()) ||
      (options.selection.requireAudio &&
       !opened.descriptor->selectedAudio.has_value()) ||
      (!opened.descriptor->selectedVideo &&
       !opened.descriptor->selectedAudio)) {
    fail(NativeMediaDispatcherFailure::InvalidDescriptor, generation);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  }

  constexpr MediaTime kStreamOrigin{0, 1};
  const MediaSeekMode requestedMode =
      options.initialPosition ? options.initialPosition->mode
                              : MediaSeekMode::Accurate;
  const MediaTime requestedTarget =
      options.initialPosition ? options.initialPosition->target
                              : kStreamOrigin;
  const auto timeline =
      deriveTimeline(
          generation, requestedMode, requestedTarget,
          opened.actualDecodeStart, opened.descriptor->duration,
          opened.descriptor->selectedAudio
              ? findMediaTrack(*opened.descriptor,
                               *opened.descriptor->selectedAudio)
              : nullptr,
          opened.audioWindow, limits_.maximumAudioSeekPrerollSeconds);
  if (!timeline) {
    fail(NativeMediaDispatcherFailure::InvalidTimeline, generation);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  }

  descriptor_ = std::move(opened.descriptor);
  prepared_context_ = std::move(opened.preparedContext);
  stats_.selectedVideo = descriptor_->selectedVideo.value_or(0);
  stats_.selectedAudio = descriptor_->selectedAudio.value_or(0);
  consumer_generation_ = generation;

  // Parallel port configuration.
  //
  // VTDecompressionSessionCreate and AudioUnitInitialize are both IPC-bound on
  // their own daemons and share no state, so running them one after the other
  // simply added their latencies (~69 ms + ~59 ms) to every open. Audio is
  // therefore configured on a single worker thread while video is configured
  // on the owner thread, and the open's verdict is decided only after that
  // worker is joined.
  //
  // Exposure accounting is unchanged in intent and strengthened in mechanics.
  // Both ports are marked configured and stamped with the exact generation
  // here, on the owner thread, BEFORE either configure() runs: configure()
  // exposes the generation even when the port rejects it, and under
  // concurrency neither port may be observed as "called but unaccounted".
  // Terminal retirement therefore names both ports precisely, so a port that
  // configured successfully while its peer failed is still retired exactly
  // once at this generation by the ordinary FailureCancel/retire() machinery.
  //
  // The worker writes nothing the dispatcher owns: it touches only its own
  // verdict slot and the two const inputs (track descriptor and timeline).
  // Every dispatcher-visible mutation happens on the owner thread after the
  // join, so the staged/pending generation facts seam still observes the
  // whole configure as one atomic owner transition and can never sample a
  // half-exposed dispatcher.
  const MediaTrackDescriptor* videoTrack =
      descriptor_->selectedVideo
          ? findMediaTrack(*descriptor_, *descriptor_->selectedVideo)
          : nullptr;
  const MediaTrackDescriptor* audioTrack =
      descriptor_->selectedAudio
          ? findMediaTrack(*descriptor_, *descriptor_->selectedAudio)
          : nullptr;
  if (descriptor_->selectedVideo) {
    stats_.videoConfigured = true;
    video_exposed_generation_ = generation;
  }
  if (descriptor_->selectedAudio) {
    stats_.audioConfigured = true;
    audio_exposed_generation_ = generation;
  }

  const NativeMediaGenerationTimeline& configureTimeline = *timeline;
  OpenConfigureVerdict videoVerdict = OpenConfigureVerdict::Skipped;
  OpenConfigureVerdict audioVerdict = OpenConfigureVerdict::Skipped;

  const auto configureAudio = [this, audioTrack, generation,
                               &configureTimeline,
                               &audioVerdict]() noexcept {
    if (audioTrack == nullptr) {
      audioVerdict = OpenConfigureVerdict::Rejected;
      return;
    }
    try {
      audioVerdict =
          audio_->configure(*audioTrack, generation, configureTimeline,
                            nullptr) == NativeMediaConsumeResult::Accepted
              ? OpenConfigureVerdict::Accepted
              : OpenConfigureVerdict::Rejected;
    } catch (...) {
      // An exception must never cross the thread boundary: it would bypass
      // the join and terminate. Record it and let the owner thread decide.
      audioVerdict = OpenConfigureVerdict::Threw;
    }
  };

  // Structural join. The correctness argument for every shared write below is
  // "the worker has already finished", so the join is performed explicitly at
  // the join point, before any verdict is read. The destructor is the backstop
  // that keeps that invariant true by SCOPE rather than by comment discipline:
  // a future edit that adds an early return between the spawn and the verdict
  // would otherwise destroy a joinable thread and terminate the process.
  // join() itself can throw std::system_error and openLocalFile is noexcept,
  // so the throw is swallowed in both places.
  struct WorkerJoin {
    std::thread worker;
    void join() noexcept {
      if (!worker.joinable()) {
        return;
      }
      try {
        worker.join();
      } catch (...) {
        // Deliberately ignored: the worker lambda is noexcept and has already
        // published its verdict, so a join that reports std::system_error
        // costs only an unreclaimed thread handle. There is nothing to report
        // and nothing a caller could do, and letting it escape a noexcept open
        // would terminate the process instead.
      }
    }
    ~WorkerJoin() { join(); }
  };

  // Only a dual-track open can win anything from a worker; a single-port open
  // configures inline and never pays for thread creation.
  WorkerJoin audioWorker;
  if (descriptor_->selectedAudio && descriptor_->selectedVideo) {
    try {
      audioWorker.worker = std::thread(configureAudio);
    } catch (...) {
      // Thread creation is the only failure allowed to degrade this path, and
      // it degrades to the previous serial behaviour rather than to an open
      // failure. The handle stays non-joinable and audio is configured below.
    }
  }

  if (descriptor_->selectedVideo) {
    if (videoTrack == nullptr) {
      videoVerdict = OpenConfigureVerdict::Rejected;
    } else {
      try {
        videoVerdict =
            video_->configure(*videoTrack, generation, configureTimeline,
                              nullptr) == NativeMediaConsumeResult::Accepted
                ? OpenConfigureVerdict::Accepted
                : OpenConfigureVerdict::Rejected;
      } catch (...) {
        videoVerdict = OpenConfigureVerdict::Threw;
      }
    }
  }

  const bool audioRanOnWorker = audioWorker.worker.joinable();
  audioWorker.join();
  if (!audioRanOnWorker && descriptor_->selectedAudio) {
    // Video-free open, or a worker that could not be created.
    configureAudio();
  }

  // Verdict is decided only here, with both ports joined and both exposures
  // already accounted.
  if (videoVerdict != OpenConfigureVerdict::Skipped &&
      videoVerdict != OpenConfigureVerdict::Accepted) {
    fail(NativeMediaDispatcherFailure::ConsumerConfiguration, generation);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  }
  if (audioVerdict != OpenConfigureVerdict::Skipped &&
      audioVerdict != OpenConfigureVerdict::Accepted) {
    fail(NativeMediaDispatcherFailure::ConsumerConfiguration, generation);
    result.status = NativeMediaDispatcherOpenStatus::Failed;
    return result;
  }

  timeline_ = *timeline;
  resetGenerationFacts();
  stats_.state = NativeMediaDispatcherState::Ready;
  stats_.failure = NativeMediaDispatcherFailure::None;
  stats_.lastAction = NativeMediaDispatcherAction::Idle;
  stats_.lastWait = NativeMediaDispatcherWait::CallAgain;
  result.actualDecodeStart = timeline->actualDecodeStart;
  result.timeline = *timeline;
  result.status = NativeMediaDispatcherOpenStatus::Ready;
  return result;
}

NativeMediaDispatcherStep NativeMediaDispatcher::step() noexcept {
  if (stats_.lifecycle != NativeMediaDispatcherLifecycleKind::None) {
    return advanceLifecycle();
  }

  switch (stats_.state) {
  case NativeMediaDispatcherState::Fresh:
    return makeStep(NativeMediaDispatcherAction::Idle,
                    NativeMediaDispatcherWait::Command);
  case NativeMediaDispatcherState::Unsupported:
  case NativeMediaDispatcherState::Failed:
    return makeStep(NativeMediaDispatcherAction::Failed,
                    NativeMediaDispatcherWait::Terminal);
  case NativeMediaDispatcherState::Cancelled:
    return makeStep(NativeMediaDispatcherAction::Cancelled,
                    NativeMediaDispatcherWait::Terminal);
  case NativeMediaDispatcherState::Closed:
    return makeStep(NativeMediaDispatcherAction::Closed,
                    NativeMediaDispatcherWait::Terminal);
  case NativeMediaDispatcherState::Exhausted:
    return makeStep(NativeMediaDispatcherAction::Exhausted,
                    NativeMediaDispatcherWait::Command);
  case NativeMediaDispatcherState::Seeking:
  case NativeMediaDispatcherState::Cancelling:
  case NativeMediaDispatcherState::Closing:
  case NativeMediaDispatcherState::Retiring:
    return failStep(NativeMediaDispatcherFailure::ConsumerProtocol);
  case NativeMediaDispatcherState::Ready:
  case NativeMediaDispatcherState::Draining:
    break;
  }

  if (pending_) {
    NativeMediaDispatcherStep routed = routePending();
    if (routed.action != NativeMediaDispatcherAction::BlockedAudio &&
        routed.action != NativeMediaDispatcherAction::BlockedVideo) {
      return routed;
    }
    if (routed.wait == NativeMediaDispatcherWait::CallAgain) {
      // The video lane absorbed the refused event, so the dispatcher owns no
      // head-of-line blocker and the next call may read again.
      return routed;
    }

    // A refused audio event closes the merged read, but it must not also
    // strand the video route. The deferred video lane owns strictly older
    // source events, and the video consumer's capacity query is that
    // consumer's presentation pump. Skipping both here is what deadlocks an
    // accurate seek: its audio-owned clock stays paused at the target until
    // video draws the frame covering it, so the PCM ring that refused this
    // event cannot drain, while the samples that would end that wait sit in
    // the lane. This is the same per-lane rule checkReadCapacity() already
    // applies one step later, applied to the owned event instead of the read.
    if (routed.action == NativeMediaDispatcherAction::BlockedAudio) {
      NativeMediaDispatcherStep videoProgress = advanceVideoWhileAudioBlocked();
      if (videoProgress.action != NativeMediaDispatcherAction::Idle) {
        return videoProgress;
      }
    }

    // A pending event remains the only owned source event. One audio pump may
    // still release its retained input, but no new read is admitted.
    NativeMediaDispatcherStep audioProgress = maintainAudio();
    if (audioProgress.action == NativeMediaDispatcherAction::AudioProgress ||
        audioProgress.action == NativeMediaDispatcherAction::Exhausted ||
        audioProgress.action == NativeMediaDispatcherAction::Failed) {
      return audioProgress;
    }
    return makeStep(routed.action, routed.wait, routed.track);
  }

  NativeMediaDispatcherStep audioProgress = maintainAudio();
  // A quiescing audio route reports BlockedAudio: its PCM buffer is full and
  // only the output's own retirement wake reopens it. While the source is
  // still Ready that must close the read gate and nothing else. Returning it
  // here instead skipped the whole video route - its presentation pump, its
  // deferred lane and its read admission - for as long as the buffer stayed
  // full. During an accurate seek that interval never ends on its own: the
  // audio-owned clock is held paused at the target until video draws the
  // frame covering it, so the buffer cannot retire a single slab until the
  // very work this return skipped has happened. checkReadCapacity() below
  // re-asks the audio consumer and still refuses the read, so read admission
  // is unchanged. Draining keeps the original return: there the audio route
  // owes a terminal drain, and the exhausted-source invariant below treats an
  // undrained consumer as a protocol fault rather than as work to schedule.
  if (audioProgress.action != NativeMediaDispatcherAction::Idle &&
      (audioProgress.action != NativeMediaDispatcherAction::BlockedAudio ||
       stats_.state != NativeMediaDispatcherState::Ready)) {
    return audioProgress;
  }
  NativeMediaDispatcherStep videoProgress = maintainVideo();
  if (videoProgress.action != NativeMediaDispatcherAction::Idle) {
    return videoProgress;
  }

  if (stats_.state == NativeMediaDispatcherState::Draining) {
    if (allSelectedDrained()) {
      stats_.state = NativeMediaDispatcherState::Exhausted;
      return makeStep(NativeMediaDispatcherAction::Exhausted,
                      NativeMediaDispatcherWait::Command);
    }
    return failStep(NativeMediaDispatcherFailure::ConsumerProtocol);
  }

  NativeMediaDispatcherStep capacity = checkReadCapacity();
  if (capacity.action == NativeMediaDispatcherAction::Failed) {
    return capacity;
  }
  // Draining the deferred video lane outranks another source read: it is the
  // oldest owned data and retiring it is what reopens video admission.
  if (video_capacity_open_ && video_lane_.size != 0 &&
      takeLaneHead(video_lane_, PendingLaneHead::Video)) {
    return routePending();
  }
  // Same rule for an audio lane the seek-settle window filled: its events are
  // older than anything a new read could return, and retiring them is what
  // reopens audio admission once the commit releases the paused output.
  if (audio_capacity_open_ && audio_lane_.size != 0 &&
      takeLaneHead(audio_lane_, PendingLaneHead::Audio)) {
    return routePending();
  }
  if (capacity.action != NativeMediaDispatcherAction::Idle) {
    return capacity;
  }

  try {
    installPending(source_->readNext(stats_.generation));
    saturatingIncrement(stats_.sourceReads);
  } catch (...) {
    return failStep(NativeMediaDispatcherFailure::SourceRead);
  }
  return routePending();
}

NativeMediaDispatcherSeekOutcome NativeMediaDispatcher::seek(
    const MediaSourceSeekRequest& request) noexcept {
  NativeMediaDispatcherSeekOutcome result;
  result.generation = request.generation;
  if ((stats_.state != NativeMediaDispatcherState::Ready &&
       stats_.state != NativeMediaDispatcherState::Draining &&
       stats_.state != NativeMediaDispatcherState::Exhausted) ||
      stats_.lifecycle != NativeMediaDispatcherLifecycleKind::None ||
      request.generation == 0 || request.generation <= stats_.generation ||
      !validateMediaSourceInitialPosition(
          std::optional<MediaSourceInitialPosition>{MediaSourceInitialPosition{
              request.target, request.mode}},
          nullptr)) {
    return result;
  }

  const MediaGeneration retiredGeneration = consumer_generation_;
  if (!source_->armOperation(request.generation)) {
    // The source did not install this generation and seek() must not consume
    // any other arm. Preserve the old consumers and pending event for exact
    // close, but fail the diverged owner state closed.
    operation_generation_.store(0, std::memory_order_release);
    stats_.state = NativeMediaDispatcherState::Failed;
    stats_.failure = NativeMediaDispatcherFailure::Seek;
    stats_.lastAction = NativeMediaDispatcherAction::Failed;
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
    result.status = NativeMediaDispatcherSeekStatus::Failed;
    return result;
  }
  operation_generation_.store(request.generation, std::memory_order_release);
  MediaSourceSeekOutcome sought;
  try {
    sought = source_->seek(request);
  } catch (...) {
    operation_generation_.store(0, std::memory_order_release);
    stats_.state = NativeMediaDispatcherState::Failed;
    stats_.failure = NativeMediaDispatcherFailure::Seek;
    stats_.lastAction = NativeMediaDispatcherAction::Failed;
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
    source_->requestCancel(request.generation);
    result.status = NativeMediaDispatcherSeekStatus::Failed;
    return result;
  }

  if (!sought.accepted || sought.generation != request.generation ||
      sought.preparedContext.get() != prepared_context_.get() ||
      !sought.actualDecodeStart.valid()) {
    // No new source generation committed. Preserve the old consumer
    // generation and old pending event; only exact close may retire them.
    operation_generation_.store(0, std::memory_order_release);
    stats_.state = NativeMediaDispatcherState::Failed;
    stats_.failure = NativeMediaDispatcherFailure::Seek;
    stats_.lastAction = NativeMediaDispatcherAction::Failed;
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
    source_->requestCancel(request.generation);
    result.status = NativeMediaDispatcherSeekStatus::Failed;
    return result;
  }

  const auto nextTimeline =
      descriptor_ == nullptr
          ? std::optional<NativeMediaGenerationTimeline>{}
          : deriveTimeline(
                request.generation, request.mode, request.target,
                sought.actualDecodeStart, descriptor_->duration,
                descriptor_->selectedAudio
                    ? findMediaTrack(*descriptor_, *descriptor_->selectedAudio)
                    : nullptr,
                sought.audioWindow,
                limits_.maximumAudioSeekPrerollSeconds);
  if (!nextTimeline) {
    // The source installed a generation but returned facts that cannot define
    // an exact consumer timeline. Keep old consumer ownership intact for an
    // exact close and fail the diverged source route closed.
    operation_generation_.store(0, std::memory_order_release);
    stats_.state = NativeMediaDispatcherState::Failed;
    stats_.failure = NativeMediaDispatcherFailure::InvalidTimeline;
    stats_.lastAction = NativeMediaDispatcherAction::Failed;
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
    source_->requestCancel(request.generation);
    result.status = NativeMediaDispatcherSeekStatus::Failed;
    return result;
  }

  stats_.state = NativeMediaDispatcherState::Seeking;
  lifecycle_timeline_ = *nextTimeline;
  beginLifecycle(NativeMediaDispatcherLifecycleKind::Seek, retiredGeneration,
                 request.generation);
  result.actualDecodeStart = nextTimeline->actualDecodeStart;
  result.timeline = *nextTimeline;
  const NativeMediaDispatcherStep progress = advanceLifecycle();
  if (progress.action == NativeMediaDispatcherAction::SeekCommitted) {
    result.status = NativeMediaDispatcherSeekStatus::Accepted;
  } else if (stats_.state == NativeMediaDispatcherState::Seeking) {
    result.status = NativeMediaDispatcherSeekStatus::Pending;
  } else {
    result.status = NativeMediaDispatcherSeekStatus::Failed;
  }
  return result;
}

void NativeMediaDispatcher::requestCancel(MediaGeneration generation) noexcept {
  if (generation == 0 || source_ == nullptr) {
    return;
  }
  source_->requestCancel(generation);
}

NativeMediaDispatcherLifecycleOutcome NativeMediaDispatcher::cancel(
    MediaGeneration generation) noexcept {
  NativeMediaDispatcherLifecycleOutcome result;
  result.generation = generation;
  if (stats_.state == NativeMediaDispatcherState::Cancelled &&
      generation == stats_.generation) {
    result.status = NativeMediaDispatcherLifecycleStatus::Done;
    return result;
  }
  if (stats_.state == NativeMediaDispatcherState::Cancelling &&
      stats_.lifecycle == NativeMediaDispatcherLifecycleKind::Cancel &&
      generation == stats_.lifecycleTargetGeneration) {
    const NativeMediaDispatcherStep progress = advanceLifecycle();
    result.status = progress.action == NativeMediaDispatcherAction::Cancelled
                        ? NativeMediaDispatcherLifecycleStatus::Done
                        : stats_.state == NativeMediaDispatcherState::Failed
                              ? NativeMediaDispatcherLifecycleStatus::Failed
                              : NativeMediaDispatcherLifecycleStatus::Pending;
    return result;
  }
  if ((stats_.state != NativeMediaDispatcherState::Ready &&
       stats_.state != NativeMediaDispatcherState::Draining &&
       stats_.state != NativeMediaDispatcherState::Exhausted) ||
      stats_.lifecycle != NativeMediaDispatcherLifecycleKind::None ||
      generation == 0 || generation != stats_.generation) {
    return result;
  }

  source_->requestCancel(generation);
  stats_.state = NativeMediaDispatcherState::Cancelling;
  beginLifecycle(NativeMediaDispatcherLifecycleKind::Cancel,
                 consumer_generation_, generation);
  const NativeMediaDispatcherStep progress = advanceLifecycle();
  result.status = progress.action == NativeMediaDispatcherAction::Cancelled
                      ? NativeMediaDispatcherLifecycleStatus::Done
                      : stats_.state == NativeMediaDispatcherState::Failed
                            ? NativeMediaDispatcherLifecycleStatus::Failed
                            : NativeMediaDispatcherLifecycleStatus::Pending;
  return result;
}

NativeMediaDispatcherLifecycleOutcome NativeMediaDispatcher::close(
    MediaGeneration generation) noexcept {
  NativeMediaDispatcherLifecycleOutcome result;
  result.generation = generation;
  // Once exact terminal retirement is latched, only retire() with that exact
  // owner pair may advance it. Public close must not replace the retained pair
  // with an emergency-close lifecycle and manufacture a different proof.
  if (retirement_invalidation_generation_ != 0) {
    return result;
  }
  if (stats_.state == NativeMediaDispatcherState::Closed) {
    result.status = generation == stats_.generation
                        ? NativeMediaDispatcherLifecycleStatus::Done
                        : NativeMediaDispatcherLifecycleStatus::Rejected;
    return result;
  }
  if (stats_.state == NativeMediaDispatcherState::Closing &&
      stats_.lifecycle == NativeMediaDispatcherLifecycleKind::Close &&
      generation == stats_.lifecycleTargetGeneration) {
    const NativeMediaDispatcherStep progress = advanceLifecycle();
    result.status = progress.action == NativeMediaDispatcherAction::Closed
                        ? NativeMediaDispatcherLifecycleStatus::Done
                        : stats_.state == NativeMediaDispatcherState::Failed
                              ? NativeMediaDispatcherLifecycleStatus::Failed
                              : NativeMediaDispatcherLifecycleStatus::Pending;
    return result;
  }

  const MediaGeneration exactGeneration =
      stats_.lifecycle != NativeMediaDispatcherLifecycleKind::None
          ? stats_.lifecycleTargetGeneration
          : stats_.generation;
  if ((stats_.state == NativeMediaDispatcherState::Fresh && generation != 0) ||
      (stats_.state != NativeMediaDispatcherState::Fresh &&
       generation != exactGeneration)) {
    return result;
  }

  const MediaGeneration operation =
      operation_generation_.exchange(0, std::memory_order_acq_rel);
  if (operation != 0 && source_ != nullptr) {
    source_->requestCancel(operation);
  }
  if (source_ != nullptr) {
    source_->close();
  }
  stats_.state = NativeMediaDispatcherState::Closing;
  beginLifecycle(NativeMediaDispatcherLifecycleKind::Close,
                 consumer_generation_, generation);
  const NativeMediaDispatcherStep progress = advanceLifecycle();
  result.status = progress.action == NativeMediaDispatcherAction::Closed
                      ? NativeMediaDispatcherLifecycleStatus::Done
                      : stats_.state == NativeMediaDispatcherState::Failed
                            ? NativeMediaDispatcherLifecycleStatus::Failed
                            : NativeMediaDispatcherLifecycleStatus::Pending;
  return result;
}

NativeMediaDispatcherLifecycleOutcome NativeMediaDispatcher::retire(
    MediaGeneration expectedGeneration,
    MediaGeneration invalidationGeneration) noexcept {
  NativeMediaDispatcherLifecycleOutcome result;
  // The retirement result names the terminal invalidation, never the retired
  // generation. This keeps a Pending/Done retry token unambiguous.
  result.generation = invalidationGeneration;

  if (retirement_invalidation_generation_ != 0) {
    if (expectedGeneration != retirement_expected_generation_ ||
        invalidationGeneration != retirement_invalidation_generation_) {
      return result;
    }
    if (stats_.state == NativeMediaDispatcherState::Closed &&
        stats_.generation == invalidationGeneration) {
      result.status = NativeMediaDispatcherLifecycleStatus::Done;
      return result;
    }
    if (stats_.lifecycle != NativeMediaDispatcherLifecycleKind::Retire) {
      result.status = NativeMediaDispatcherLifecycleStatus::Failed;
      return result;
    }
    const NativeMediaDispatcherStep progress = advanceLifecycle();
    result.status = progress.action == NativeMediaDispatcherAction::Closed
                        ? NativeMediaDispatcherLifecycleStatus::Done
                        : stats_.state == NativeMediaDispatcherState::Failed
                              ? NativeMediaDispatcherLifecycleStatus::Failed
                              : NativeMediaDispatcherLifecycleStatus::Pending;
    return result;
  }

  if (stats_.state == NativeMediaDispatcherState::Fresh ||
      stats_.state == NativeMediaDispatcherState::Closed ||
      expectedGeneration == 0 || expectedGeneration != stats_.generation ||
      invalidationGeneration == 0 ||
      invalidationGeneration <= highestExposedGeneration()) {
    return result;
  }

  retirement_expected_generation_ = expectedGeneration;
  retirement_invalidation_generation_ = invalidationGeneration;
  lifecycle_video_retired_generation_ = video_exposed_generation_;
  lifecycle_audio_retired_generation_ = audio_exposed_generation_;

  // Source teardown and source-owned payload release are observably before
  // either consumer retirement call. close() is required even when no source
  // operation is currently published.
  const MediaGeneration operation =
      operation_generation_.exchange(0, std::memory_order_acq_rel);
  if (source_ != nullptr) {
    const MediaGeneration sourceOperation = source_->stats().operationGeneration;
    if (operation != 0) {
      source_->requestCancel(operation);
    }
    if (sourceOperation != 0 && sourceOperation != operation) {
      source_->requestCancel(sourceOperation);
    }
    source_->close();
  }
  releaseRetainedEvents();

  stats_.state = NativeMediaDispatcherState::Retiring;
  beginLifecycle(NativeMediaDispatcherLifecycleKind::Retire,
                 expectedGeneration, invalidationGeneration);
  const NativeMediaDispatcherStep progress = advanceLifecycle();
  result.status = progress.action == NativeMediaDispatcherAction::Closed
                      ? NativeMediaDispatcherLifecycleStatus::Done
                      : stats_.state == NativeMediaDispatcherState::Failed
                            ? NativeMediaDispatcherLifecycleStatus::Failed
                            : NativeMediaDispatcherLifecycleStatus::Pending;
  return result;
}

std::shared_ptr<const MediaSourceDescriptor>
NativeMediaDispatcher::descriptor() const noexcept {
  return descriptor_;
}

std::shared_ptr<const MediaSourcePreparedContext>
NativeMediaDispatcher::preparedContext() const noexcept {
  return prepared_context_;
}

std::optional<NativeMediaGenerationTimeline>
NativeMediaDispatcher::timeline() const noexcept {
  return timeline_;
}

NativeMediaDispatcherStats NativeMediaDispatcher::stats() const noexcept {
  NativeMediaDispatcherStats result = stats_;
  result.operationGeneration =
      operation_generation_.load(std::memory_order_acquire);
  result.consumerGeneration = consumer_generation_;
  result.pending = pendingKind();
  const auto laneHeadGeneration =
      [](const ReadAheadLane& lane) noexcept -> MediaGeneration {
    if (lane.size == 0) {
      return 0;
    }
    return std::visit(
        [](const auto& event) noexcept { return event.generation; },
        *lane.events[lane.head]);
  };
  result.pendingGeneration = pending_ ? pending_generation_
                             : video_lane_.size != 0
                                 ? laneHeadGeneration(video_lane_)
                                 : laneHeadGeneration(audio_lane_);
  // Exact total retained source payload: the head-of-line lease plus both
  // deferred read-ahead lanes.
  result.pendingPayloadBytes = pending_payload_bytes_ +
                               video_lane_.payloadBytes +
                               audio_lane_.payloadBytes;
  result.peakPendingPayloadBytes =
      std::max(peak_pending_payload_bytes_, result.pendingPayloadBytes);
  result.videoExposedGeneration = video_exposed_generation_;
  result.audioExposedGeneration = audio_exposed_generation_;
  result.retirementExpectedGeneration = retirement_expected_generation_;
  result.retirementInvalidationGeneration =
      retirement_invalidation_generation_;
  return result;
}

void NativeMediaDispatcher::setSeekSettleReadAhead(bool enabled) noexcept {
  seek_settle_read_ahead_ = enabled;
}

bool NativeMediaDispatcher::seekSettleAudioLaneOpen() const noexcept {
  return seek_settle_read_ahead_ &&
         laneHasReadAheadRoom(audio_lane_, kAudioReadAheadPayloadBytes);
}

NativeMediaDispatcherStep NativeMediaDispatcher::deferBlockedLaneEvent(
    bool isVideo, MediaTrackId track) noexcept {
  if (!isVideo) {
    saturatingIncrement(stats_.audioBackpressure);
    // Outside the seek-settle window the audio lane keeps capacity-one
    // semantics on purpose. A backpressured audio consumer means its buffer is
    // full, which is the pipeline being ahead rather than stuck, and it is
    // resolved by the output's own slab-retirement wake within one buffer
    // period. Inside the window that wake cannot arrive until video draws, so
    // the refused event is deferred into the bounded audio read-ahead lane and
    // the merged read keeps feeding the video decoder instead.
    if (!seekSettleAudioLaneOpen()) {
      return makeStep(NativeMediaDispatcherAction::BlockedAudio,
                      NativeMediaDispatcherWait::AudioConsumer, track);
    }
    deferPendingIntoLane(audio_lane_);
    return makeStep(
        NativeMediaDispatcherAction::BlockedAudio,
        laneHasReadAheadRoom(audio_lane_, kAudioReadAheadPayloadBytes)
            ? NativeMediaDispatcherWait::CallAgain
            : NativeMediaDispatcherWait::AudioConsumer,
        track);
  }
  saturatingIncrement(stats_.videoBackpressure);
  deferPendingIntoLane(video_lane_);
  // CallAgain while the lane still owns read-ahead room: the dispatcher holds
  // no head-of-line blocker, so the very next call may pull the audio lane's
  // next event. Otherwise the lane is genuinely out of room and the wait names
  // the consumer whose progress reopens it.
  return makeStep(
      NativeMediaDispatcherAction::BlockedVideo,
      laneHasReadAheadRoom(video_lane_, kVideoReadAheadPayloadBytes)
          ? NativeMediaDispatcherWait::CallAgain
          : NativeMediaDispatcherWait::VideoConsumer,
      track);
}

NativeMediaDispatcherStep NativeMediaDispatcher::routePending() noexcept {
  if (!pending_ || descriptor_ == nullptr) {
    return failStep(NativeMediaDispatcherFailure::InvalidEvent);
  }

  if (auto* sample = std::get_if<MediaSample>(&*pending_)) {
    if (sample->generation != stats_.generation || sample->discontinuity ||
        !validateMediaSample(*sample, *descriptor_, limits_, nullptr)) {
      return failStep(NativeMediaDispatcherFailure::InvalidSample);
    }

    const bool isVideo = sample->kind == MediaSampleKind::EncodedVideo &&
                         sample->track == stats_.selectedVideo &&
                         stats_.videoConfigured && !stats_.videoEndOfStream;
    const bool isAudio = sample->kind == MediaSampleKind::EncodedAudio &&
                         sample->track == stats_.selectedAudio &&
                         stats_.audioConfigured && !stats_.audioEndOfStream;
    if (!isVideo && !isAudio) {
      return failStep(NativeMediaDispatcherFailure::InvalidSample);
    }

    if (isVideo && video_lane_.size != 0 &&
        pending_lane_head_ != PendingLaneHead::Video) {
      // Older video events are still queued, so per-lane order forbids
      // offering this one to the consumer. Append it and keep reading. A full
      // lane keeps the event as the head-of-line blocker instead, which shuts
      // the read gate and names the wake that reopens it.
      const MediaTrackId track = sample->track;
      const bool queued = queuePendingIntoLane(video_lane_);
      return makeStep(NativeMediaDispatcherAction::BlockedVideo,
                      queued ? NativeMediaDispatcherWait::CallAgain
                             : NativeMediaDispatcherWait::VideoConsumer,
                      track);
    }
    if (isAudio && audio_lane_.size != 0 &&
        pending_lane_head_ != PendingLaneHead::Audio) {
      // Same per-lane order rule for an audio lane the seek-settle window
      // filled. It applies whenever the lane is non-empty, including after the
      // window closes, so the lane always drains in source order.
      const MediaTrackId track = sample->track;
      const bool queued = queuePendingIntoLane(audio_lane_);
      return makeStep(NativeMediaDispatcherAction::BlockedAudio,
                      queued ? NativeMediaDispatcherWait::CallAgain
                             : NativeMediaDispatcherWait::AudioConsumer,
                      track);
    }

    NativeMediaSampleDelivery delivery(*sample);
    NativeMediaConsumeResult consumed{NativeMediaConsumeResult::Failed};
    try {
      consumed = isVideo ? video_->trySample(delivery, nullptr)
                         : audio_->trySample(delivery, nullptr);
    } catch (...) {
      return failStep(NativeMediaDispatcherFailure::Consumer);
    }

    if (consumed == NativeMediaConsumeResult::Accepted &&
        delivery.take_count_ == 1) {
      const MediaTrackId track = sample->track;
      if (isVideo) {
        saturatingIncrement(stats_.videoSamples);
      } else {
        saturatingIncrement(stats_.audioSamples);
      }
      clearPending();
      return makeStep(isVideo ? NativeMediaDispatcherAction::VideoSample
                              : NativeMediaDispatcherAction::AudioSample,
                      NativeMediaDispatcherWait::CallAgain, track);
    }
    if (consumed == NativeMediaConsumeResult::Backpressure &&
        delivery.take_count_ == 0) {
      const MediaTrackId track = sample->track;
      return deferBlockedLaneEvent(isVideo, track);
    }
    if (delivery.take_count_ != 0 ||
        consumed == NativeMediaConsumeResult::Draining ||
        consumed == NativeMediaConsumeResult::Drained) {
      return failStep(NativeMediaDispatcherFailure::ConsumerProtocol);
    }
    return failStep(NativeMediaDispatcherFailure::Consumer);
  }

  if (auto* discontinuity =
          std::get_if<MediaDiscontinuity>(&*pending_)) {
    if (discontinuity->generation != stats_.generation ||
        !validateMediaDiscontinuity(*discontinuity, *descriptor_, nullptr)) {
      return failStep(NativeMediaDispatcherFailure::InvalidEvent);
    }
    const bool isVideo = discontinuity->track == stats_.selectedVideo &&
                         stats_.videoConfigured && !stats_.videoEndOfStream;
    const bool isAudio = discontinuity->track == stats_.selectedAudio &&
                         stats_.audioConfigured && !stats_.audioEndOfStream;
    if (!isVideo && !isAudio) {
      return failStep(NativeMediaDispatcherFailure::InvalidEvent);
    }
    if (isVideo && video_lane_.size != 0 &&
        pending_lane_head_ != PendingLaneHead::Video) {
      // Older video events are still queued, so per-lane order forbids
      // offering this one to the consumer. Append it and keep reading. A full
      // lane keeps the event as the head-of-line blocker instead, which shuts
      // the read gate and names the wake that reopens it.
      const MediaTrackId track = discontinuity->track;
      const bool queued = queuePendingIntoLane(video_lane_);
      return makeStep(NativeMediaDispatcherAction::BlockedVideo,
                      queued ? NativeMediaDispatcherWait::CallAgain
                             : NativeMediaDispatcherWait::VideoConsumer,
                      track);
    }
    if (isAudio && audio_lane_.size != 0 &&
        pending_lane_head_ != PendingLaneHead::Audio) {
      // Same per-lane order rule for an audio lane the seek-settle window
      // filled. It applies whenever the lane is non-empty, including after the
      // window closes, so the lane always drains in source order.
      const MediaTrackId track = discontinuity->track;
      const bool queued = queuePendingIntoLane(audio_lane_);
      return makeStep(NativeMediaDispatcherAction::BlockedAudio,
                      queued ? NativeMediaDispatcherWait::CallAgain
                             : NativeMediaDispatcherWait::AudioConsumer,
                      track);
    }
    NativeMediaConsumeResult consumed{NativeMediaConsumeResult::Failed};
    try {
      consumed = isVideo
                     ? video_->discontinuity(*discontinuity, nullptr)
                     : audio_->discontinuity(*discontinuity, nullptr);
    } catch (...) {
      return failStep(NativeMediaDispatcherFailure::Consumer);
    }
    if (consumed == NativeMediaConsumeResult::Backpressure) {
      const MediaTrackId track = discontinuity->track;
      return deferBlockedLaneEvent(isVideo, track);
    }
    if (consumed != NativeMediaConsumeResult::Accepted) {
      return failStep(consumed == NativeMediaConsumeResult::Draining ||
                              consumed == NativeMediaConsumeResult::Drained
                          ? NativeMediaDispatcherFailure::ConsumerProtocol
                          : NativeMediaDispatcherFailure::Consumer);
    }
    const MediaTrackId track = discontinuity->track;
    if (isVideo) {
      saturatingIncrement(stats_.videoDiscontinuities);
    } else {
      saturatingIncrement(stats_.audioDiscontinuities);
    }
    clearPending();
    return makeStep(
        isVideo ? NativeMediaDispatcherAction::VideoDiscontinuity
                : NativeMediaDispatcherAction::AudioDiscontinuity,
        NativeMediaDispatcherWait::CallAgain, track);
  }

  if (auto* end = std::get_if<MediaEndOfStream>(&*pending_)) {
    if (end->generation != stats_.generation || end->track == 0) {
      return failStep(NativeMediaDispatcherFailure::InvalidEvent);
    }
    const bool isVideo = end->track == stats_.selectedVideo &&
                         stats_.videoConfigured && !stats_.videoEndOfStream;
    const bool isAudio = end->track == stats_.selectedAudio &&
                         stats_.audioConfigured && !stats_.audioEndOfStream;
    if (!isVideo && !isAudio) {
      return failStep(NativeMediaDispatcherFailure::InvalidEvent);
    }
    if (isVideo && video_lane_.size != 0 &&
        pending_lane_head_ != PendingLaneHead::Video) {
      // Older video events are still queued, so per-lane order forbids
      // offering this one to the consumer. Append it and keep reading. A full
      // lane keeps the event as the head-of-line blocker instead, which shuts
      // the read gate and names the wake that reopens it.
      const MediaTrackId track = end->track;
      const bool queued = queuePendingIntoLane(video_lane_);
      return makeStep(NativeMediaDispatcherAction::BlockedVideo,
                      queued ? NativeMediaDispatcherWait::CallAgain
                             : NativeMediaDispatcherWait::VideoConsumer,
                      track);
    }
    if (isAudio && audio_lane_.size != 0 &&
        pending_lane_head_ != PendingLaneHead::Audio) {
      // Same per-lane order rule for an audio lane the seek-settle window
      // filled. It applies whenever the lane is non-empty, including after the
      // window closes, so the lane always drains in source order.
      const MediaTrackId track = end->track;
      const bool queued = queuePendingIntoLane(audio_lane_);
      return makeStep(NativeMediaDispatcherAction::BlockedAudio,
                      queued ? NativeMediaDispatcherWait::CallAgain
                             : NativeMediaDispatcherWait::AudioConsumer,
                      track);
    }
    NativeMediaConsumeResult consumed{NativeMediaConsumeResult::Failed};
    try {
      consumed = isVideo ? video_->endOfStream(*end, nullptr)
                         : audio_->endOfStream(*end, nullptr);
    } catch (...) {
      return failStep(NativeMediaDispatcherFailure::Consumer);
    }
    if (consumed == NativeMediaConsumeResult::Backpressure) {
      const MediaTrackId track = end->track;
      return deferBlockedLaneEvent(isVideo, track);
    }
    if (consumed != NativeMediaConsumeResult::Accepted &&
        consumed != NativeMediaConsumeResult::Draining &&
        consumed != NativeMediaConsumeResult::Drained) {
      return failStep(NativeMediaDispatcherFailure::Consumer);
    }
    const MediaTrackId track = end->track;
    if (isVideo) {
      stats_.videoEndOfStream = true;
      stats_.videoDrained = consumed == NativeMediaConsumeResult::Drained;
      saturatingIncrement(stats_.videoEndMarkers);
    } else {
      stats_.audioEndOfStream = true;
      stats_.audioDrained = consumed == NativeMediaConsumeResult::Drained;
      saturatingIncrement(stats_.audioEndMarkers);
    }
    clearPending();
    return makeStep(
        isVideo ? NativeMediaDispatcherAction::VideoEndOfStream
                : NativeMediaDispatcherAction::AudioEndOfStream,
        NativeMediaDispatcherWait::CallAgain, track);
  }

  if (std::holds_alternative<MediaFormatChanged>(*pending_)) {
    return failStep(NativeMediaDispatcherFailure::FormatChanged);
  }

  if (auto* cancelled = std::get_if<MediaSourceCancelled>(&*pending_)) {
    if (cancelled->generation != stats_.generation) {
      return failStep(NativeMediaDispatcherFailure::InvalidEvent);
    }
    releaseRetainedEvents();
    stats_.state = NativeMediaDispatcherState::Cancelling;
    beginLifecycle(NativeMediaDispatcherLifecycleKind::Cancel,
                   consumer_generation_, stats_.generation);
    return advanceLifecycle();
  }

  if (auto* failure = std::get_if<MediaSourceFailure>(&*pending_)) {
    if (failure->generation != stats_.generation) {
      return failStep(NativeMediaDispatcherFailure::InvalidEvent);
    }
    return failStep(NativeMediaDispatcherFailure::SourceRead);
  }

  if (auto* exhausted = std::get_if<MediaSourceExhausted>(&*pending_)) {
    if (exhausted->generation != stats_.generation || !allSelectedEnded()) {
      return failStep(NativeMediaDispatcherFailure::InvalidEvent);
    }
    clearPending();
    stats_.sourceExhausted = true;
    if (allSelectedDrained()) {
      stats_.state = NativeMediaDispatcherState::Exhausted;
      return makeStep(NativeMediaDispatcherAction::Exhausted,
                      NativeMediaDispatcherWait::Command);
    }
    stats_.state = NativeMediaDispatcherState::Draining;
    return makeStep(NativeMediaDispatcherAction::SourceExhausted,
                    NativeMediaDispatcherWait::CallAgain);
  }

  return failStep(NativeMediaDispatcherFailure::InvalidEvent);
}

NativeMediaDispatcherStep NativeMediaDispatcher::maintainAudio() noexcept {
  if (!stats_.audioConfigured || stats_.audioDrained) {
    return makeStep(NativeMediaDispatcherAction::Idle,
                    NativeMediaDispatcherWait::CallAgain);
  }
  NativeMediaConsumerProgress result{NativeMediaConsumerProgress::Failed};
  try {
    result = audio_->drain(consumer_generation_, nullptr);
  } catch (...) {
    return failStep(NativeMediaDispatcherFailure::Consumer);
  }
  switch (result) {
  case NativeMediaConsumerProgress::Done:
    if (!stats_.audioEndOfStream) {
      return makeStep(NativeMediaDispatcherAction::Idle,
                      NativeMediaDispatcherWait::CallAgain);
    }
    stats_.audioDrained = true;
    saturatingIncrement(stats_.consumerProgress);
    if (stats_.state == NativeMediaDispatcherState::Draining &&
        allSelectedDrained()) {
      stats_.state = NativeMediaDispatcherState::Exhausted;
      return makeStep(NativeMediaDispatcherAction::Exhausted,
                      NativeMediaDispatcherWait::Command);
    }
    return makeStep(NativeMediaDispatcherAction::AudioProgress,
                    NativeMediaDispatcherWait::CallAgain,
                    stats_.selectedAudio);
  case NativeMediaConsumerProgress::Progress:
    saturatingIncrement(stats_.consumerProgress);
    return makeStep(NativeMediaDispatcherAction::AudioProgress,
                    NativeMediaDispatcherWait::CallAgain,
                    stats_.selectedAudio);
  case NativeMediaConsumerProgress::Quiescing:
    if (stats_.audioEndOfStream && !stats_.sourceExhausted) {
      return makeStep(NativeMediaDispatcherAction::Idle,
                      NativeMediaDispatcherWait::CallAgain);
    }
    saturatingIncrement(stats_.audioBackpressure);
    return makeStep(NativeMediaDispatcherAction::BlockedAudio,
                    NativeMediaDispatcherWait::AudioConsumer,
                    stats_.selectedAudio);
  case NativeMediaConsumerProgress::StaleGeneration:
  case NativeMediaConsumerProgress::Unsupported:
  case NativeMediaConsumerProgress::Failed:
    return failStep(NativeMediaDispatcherFailure::Consumer);
  }
  return failStep(NativeMediaDispatcherFailure::ConsumerProtocol);
}

NativeMediaDispatcherStep NativeMediaDispatcher::maintainVideo() noexcept {
  if (!stats_.videoConfigured || stats_.videoDrained ||
      !stats_.videoEndOfStream) {
    return makeStep(NativeMediaDispatcherAction::Idle,
                    NativeMediaDispatcherWait::CallAgain);
  }
  NativeMediaConsumerProgress result{NativeMediaConsumerProgress::Failed};
  try {
    result = video_->drain(consumer_generation_, nullptr);
  } catch (...) {
    return failStep(NativeMediaDispatcherFailure::Consumer);
  }
  switch (result) {
  case NativeMediaConsumerProgress::Done:
    stats_.videoDrained = true;
    saturatingIncrement(stats_.consumerProgress);
    if (stats_.state == NativeMediaDispatcherState::Draining &&
        allSelectedDrained()) {
      stats_.state = NativeMediaDispatcherState::Exhausted;
      return makeStep(NativeMediaDispatcherAction::Exhausted,
                      NativeMediaDispatcherWait::Command);
    }
    return makeStep(NativeMediaDispatcherAction::VideoProgress,
                    NativeMediaDispatcherWait::CallAgain,
                    stats_.selectedVideo);
  case NativeMediaConsumerProgress::Progress:
    saturatingIncrement(stats_.consumerProgress);
    return makeStep(NativeMediaDispatcherAction::VideoProgress,
                    NativeMediaDispatcherWait::CallAgain,
                    stats_.selectedVideo);
  case NativeMediaConsumerProgress::Quiescing:
    if (!stats_.sourceExhausted) {
      return makeStep(NativeMediaDispatcherAction::Idle,
                      NativeMediaDispatcherWait::CallAgain);
    }
    saturatingIncrement(stats_.videoBackpressure);
    return makeStep(NativeMediaDispatcherAction::BlockedVideo,
                    NativeMediaDispatcherWait::VideoConsumer,
                    stats_.selectedVideo);
  case NativeMediaConsumerProgress::StaleGeneration:
  case NativeMediaConsumerProgress::Unsupported:
  case NativeMediaConsumerProgress::Failed:
    return failStep(NativeMediaDispatcherFailure::Consumer);
  }
  return failStep(NativeMediaDispatcherFailure::ConsumerProtocol);
}

NativeMediaDispatcherStep
NativeMediaDispatcher::advanceVideoWhileAudioBlocked() noexcept {
  if (!stats_.videoConfigured || stats_.videoEndOfStream || video_ == nullptr) {
    return makeStep(NativeMediaDispatcherAction::Idle,
                    NativeMediaDispatcherWait::CallAgain);
  }
  // The capacity query is also the video consumer's presentation pump, so it
  // is what lets an already-fed route present and draw while audio is blocked.
  NativeMediaConsumeResult result{NativeMediaConsumeResult::Failed};
  try {
    result = video_->capacity(consumer_generation_);
  } catch (...) {
    return failStep(NativeMediaDispatcherFailure::Consumer);
  }
  if (result == NativeMediaConsumeResult::Draining) {
    saturatingIncrement(stats_.consumerProgress);
    return makeStep(NativeMediaDispatcherAction::VideoProgress,
                    NativeMediaDispatcherWait::CallAgain,
                    stats_.selectedVideo);
  }
  if (result == NativeMediaConsumeResult::Backpressure) {
    saturatingIncrement(stats_.videoBackpressure);
    return makeStep(NativeMediaDispatcherAction::Idle,
                    NativeMediaDispatcherWait::CallAgain);
  }
  if (result != NativeMediaConsumeResult::Accepted) {
    return failStep(result == NativeMediaConsumeResult::Drained
                        ? NativeMediaDispatcherFailure::ConsumerProtocol
                        : NativeMediaDispatcherFailure::Consumer);
  }
  if (video_lane_.size == 0) {
    return makeStep(NativeMediaDispatcherAction::Idle,
                    NativeMediaDispatcherWait::CallAgain);
  }

  // Route the lane head while the refused audio event waits in a hold slot.
  // Total retained source ownership is unchanged: exactly the same events are
  // owned, and the audio event returns to the head-of-line slot before this
  // returns, so no read can be admitted past it.
  std::optional<MediaSourceReadResult> heldAudio = std::move(pending_);
  const MediaGeneration heldGeneration = pending_generation_;
  const std::size_t heldPayloadBytes = pending_payload_bytes_;
  const PendingLaneHead heldLaneHead = pending_lane_head_;
  pending_.reset();
  pending_generation_ = 0;
  pending_payload_bytes_ = 0;
  pending_lane_head_ = PendingLaneHead::None;

  NativeMediaDispatcherStep routed =
      makeStep(NativeMediaDispatcherAction::Idle,
               NativeMediaDispatcherWait::CallAgain);
  if (takeLaneHead(video_lane_, PendingLaneHead::Video)) {
    routed = routePending();
  }
  if (pending_) {
    // Only a failed route can still own the lane event. Return it to the front
    // of its own lane so per-lane order survives the failure path too.
    deferPendingIntoLane(video_lane_);
  }
  if (!pending_) {
    pending_ = std::move(heldAudio);
    pending_generation_ = heldGeneration;
    pending_payload_bytes_ = heldPayloadBytes;
    pending_lane_head_ = heldLaneHead;
  }
  return routed;
}

NativeMediaDispatcherStep NativeMediaDispatcher::checkReadCapacity() noexcept {
  // A consumer capacity query is also that consumer's pump: the video consumer
  // presents its due frame and republishes its next presentation deadline from
  // inside capacity(). Audio backpressure must therefore close only the read
  // gate, never skip the video query. Returning BlockedAudio before asking the
  // video consumer would freeze presentation for as long as the PCM ring stays
  // full, which is exactly the interval during which video must keep drawing.
  //
  // Read admission itself is per lane. Audio keeps the capacity-one rule: a
  // full audio buffer means the pipeline is ahead, and it reopens on the
  // output's own slab-retirement wake. Video does not: a video consumer at
  // capacity may be waiting on a compositor that is not presenting at all, so
  // closing the merged read on it would starve audio, freeze the audio-owned
  // clock, and leave video permanently undue. Instead the video lane absorbs
  // its refused events into bounded read-ahead and the pull keeps running.
  video_capacity_open_ = false;
  audio_capacity_open_ = false;
  bool audioBlocked = false;
  if (stats_.audioConfigured && !stats_.audioEndOfStream) {
    NativeMediaConsumeResult result{NativeMediaConsumeResult::Failed};
    try {
      result = audio_->capacity(consumer_generation_);
    } catch (...) {
      return failStep(NativeMediaDispatcherFailure::Consumer);
    }
    if (result == NativeMediaConsumeResult::Backpressure) {
      audioBlocked = true;
    } else if (result == NativeMediaConsumeResult::Draining) {
      saturatingIncrement(stats_.consumerProgress);
      return makeStep(NativeMediaDispatcherAction::AudioProgress,
                      NativeMediaDispatcherWait::CallAgain,
                      stats_.selectedAudio);
    } else if (result != NativeMediaConsumeResult::Accepted) {
      return failStep(result == NativeMediaConsumeResult::Drained
                          ? NativeMediaDispatcherFailure::ConsumerProtocol
                          : NativeMediaDispatcherFailure::Consumer);
    } else {
      audio_capacity_open_ = true;
    }
  }
  if (stats_.videoConfigured && !stats_.videoEndOfStream) {
    NativeMediaConsumeResult result{NativeMediaConsumeResult::Failed};
    try {
      result = video_->capacity(consumer_generation_);
    } catch (...) {
      return failStep(NativeMediaDispatcherFailure::Consumer);
    }
    if (result == NativeMediaConsumeResult::Backpressure) {
      if (audioBlocked) {
        saturatingIncrement(stats_.audioBackpressure);
        saturatingIncrement(stats_.videoBackpressure);
        return makeStep(NativeMediaDispatcherAction::BlockedAudio,
                        NativeMediaDispatcherWait::Consumers,
                        stats_.selectedAudio);
      }
      // Per-lane admission. A video consumer at capacity closes only the
      // video lane; the merged read stays admitted while that lane still owns
      // read-ahead room, so audio keeps being pulled and the audio-owned clock
      // keeps advancing. The gate closes here only when the video lane is
      // genuinely out of room, and that state is woken by the video consumer.
      if (!laneHasReadAheadRoom(video_lane_, kVideoReadAheadPayloadBytes)) {
        saturatingIncrement(stats_.videoBackpressure);
        return makeStep(NativeMediaDispatcherAction::BlockedVideo,
                        NativeMediaDispatcherWait::VideoConsumer,
                        stats_.selectedVideo);
      }
      saturatingIncrement(stats_.videoBackpressure);
    } else if (result == NativeMediaConsumeResult::Draining) {
      saturatingIncrement(stats_.consumerProgress);
      return makeStep(NativeMediaDispatcherAction::VideoProgress,
                      NativeMediaDispatcherWait::CallAgain,
                      stats_.selectedVideo);
    } else if (result != NativeMediaConsumeResult::Accepted) {
      return failStep(result == NativeMediaConsumeResult::Drained
                          ? NativeMediaDispatcherFailure::ConsumerProtocol
                          : NativeMediaDispatcherFailure::Consumer);
    } else {
      video_capacity_open_ = true;
    }
  }
  if (audioBlocked) {
    saturatingIncrement(stats_.audioBackpressure);
    // Inside the seek-settle window the blocked audio consumer cannot retire a
    // slab until video draws, so closing the merged read here is what starves
    // the video decoder of the access units that draw needs. Leave the gate
    // open while the bounded audio lane can still absorb whatever the next
    // read turns out to be; the lane's own room is the bound.
    if (!seekSettleAudioLaneOpen()) {
      return makeStep(NativeMediaDispatcherAction::BlockedAudio,
                      NativeMediaDispatcherWait::AudioConsumer,
                      stats_.selectedAudio);
    }
  }
  return makeStep(NativeMediaDispatcherAction::Idle,
                  NativeMediaDispatcherWait::CallAgain);
}

NativeMediaDispatcherStep NativeMediaDispatcher::advanceLifecycle() noexcept {
  const NativeMediaDispatcherLifecycleKind kind = stats_.lifecycle;
  if (kind == NativeMediaDispatcherLifecycleKind::None) {
    return failStep(NativeMediaDispatcherFailure::ConsumerProtocol);
  }

  bool immediateProgress = false;
  bool lifecycleFailed = false;
  const auto applyVideo = [&]() noexcept {
    switch (kind) {
    case NativeMediaDispatcherLifecycleKind::Seek:
      if (!lifecycle_timeline_) {
        return NativeMediaConsumerProgress::Failed;
      }
      video_exposed_generation_ = stats_.lifecycleTargetGeneration;
      return video_->flush(stats_.lifecycleRetiredGeneration,
                           stats_.lifecycleTargetGeneration,
                           *lifecycle_timeline_);
    case NativeMediaDispatcherLifecycleKind::Cancel:
    case NativeMediaDispatcherLifecycleKind::FailureCancel:
      return video_->cancel(stats_.lifecycleTargetGeneration);
    case NativeMediaDispatcherLifecycleKind::Close:
    case NativeMediaDispatcherLifecycleKind::FailureClose:
      return video_->close();
    case NativeMediaDispatcherLifecycleKind::Retire:
      return video_->retire(lifecycle_video_retired_generation_,
                            retirement_invalidation_generation_);
    case NativeMediaDispatcherLifecycleKind::None:
      break;
    }
    return NativeMediaConsumerProgress::Failed;
  };
  const auto applyAudio = [&]() noexcept {
    switch (kind) {
    case NativeMediaDispatcherLifecycleKind::Seek:
      if (!lifecycle_timeline_) {
        return NativeMediaConsumerProgress::Failed;
      }
      audio_exposed_generation_ = stats_.lifecycleTargetGeneration;
      return audio_->flush(stats_.lifecycleRetiredGeneration,
                           stats_.lifecycleTargetGeneration,
                           *lifecycle_timeline_);
    case NativeMediaDispatcherLifecycleKind::Cancel:
    case NativeMediaDispatcherLifecycleKind::FailureCancel:
      return audio_->cancel(stats_.lifecycleTargetGeneration);
    case NativeMediaDispatcherLifecycleKind::Close:
    case NativeMediaDispatcherLifecycleKind::FailureClose:
      return audio_->close();
    case NativeMediaDispatcherLifecycleKind::Retire:
      return audio_->retire(lifecycle_audio_retired_generation_,
                            retirement_invalidation_generation_);
    case NativeMediaDispatcherLifecycleKind::None:
      break;
    }
    return NativeMediaConsumerProgress::Failed;
  };

  if (!stats_.lifecycleVideoDone) {
    const NativeMediaConsumerProgress progress = applyVideo();
    if (progress == NativeMediaConsumerProgress::Done) {
      stats_.lifecycleVideoDone = true;
    } else if (progress == NativeMediaConsumerProgress::Progress) {
      immediateProgress = true;
      saturatingIncrement(stats_.consumerProgress);
    } else if (lifecycleFailure(progress)) {
      lifecycleFailed = true;
    }
  }
  if (!stats_.lifecycleAudioDone) {
    const NativeMediaConsumerProgress progress = applyAudio();
    if (progress == NativeMediaConsumerProgress::Done) {
      stats_.lifecycleAudioDone = true;
    } else if (progress == NativeMediaConsumerProgress::Progress) {
      immediateProgress = true;
      saturatingIncrement(stats_.consumerProgress);
    } else if (lifecycleFailure(progress)) {
      lifecycleFailed = true;
    }
  }

  if (lifecycleFailed) {
    stats_.state = NativeMediaDispatcherState::Failed;
    stats_.failure = kind == NativeMediaDispatcherLifecycleKind::Seek
                         ? NativeMediaDispatcherFailure::Flush
                         : NativeMediaDispatcherFailure::Consumer;
    if (kind == NativeMediaDispatcherLifecycleKind::Close ||
        kind == NativeMediaDispatcherLifecycleKind::Retire ||
        kind == NativeMediaDispatcherLifecycleKind::FailureClose) {
      stats_.lifecycle = NativeMediaDispatcherLifecycleKind::None;
      return makeStep(NativeMediaDispatcherAction::Failed,
                      NativeMediaDispatcherWait::Terminal);
    }
    beginFailureLifecycle(NativeMediaDispatcherLifecycleKind::FailureClose,
                          stats_.lifecycleTargetGeneration);
    return makeStep(NativeMediaDispatcherAction::Failed,
                    NativeMediaDispatcherWait::CallAgain);
  }

  if (stats_.lifecycleVideoDone && stats_.lifecycleAudioDone) {
    const MediaGeneration target = stats_.lifecycleTargetGeneration;
    switch (kind) {
    case NativeMediaDispatcherLifecycleKind::Seek:
      if (!lifecycle_timeline_ ||
          lifecycle_timeline_->generation != target) {
        beginFailureLifecycle(NativeMediaDispatcherLifecycleKind::FailureClose,
                              target);
        return makeStep(NativeMediaDispatcherAction::Failed,
                        NativeMediaDispatcherWait::CallAgain);
      }
      releaseRetainedEvents();
      stats_.generation = target;
      consumer_generation_ = target;
      timeline_ = *lifecycle_timeline_;
      lifecycle_timeline_.reset();
      resetGenerationFacts();
      stats_.state = NativeMediaDispatcherState::Ready;
      stats_.failure = NativeMediaDispatcherFailure::None;
      stats_.lifecycle = NativeMediaDispatcherLifecycleKind::None;
      stats_.lifecycleRetiredGeneration = 0;
      stats_.lifecycleTargetGeneration = 0;
      saturatingIncrement(stats_.acceptedSeeks);
      return makeStep(NativeMediaDispatcherAction::SeekCommitted,
                      NativeMediaDispatcherWait::CallAgain);
    case NativeMediaDispatcherLifecycleKind::Cancel:
      releaseRetainedEvents();
      timeline_.reset();
      lifecycle_timeline_.reset();
      operation_generation_.store(0, std::memory_order_release);
      stats_.state = NativeMediaDispatcherState::Cancelled;
      stats_.lifecycle = NativeMediaDispatcherLifecycleKind::None;
      stats_.lifecycleRetiredGeneration = 0;
      stats_.lifecycleTargetGeneration = 0;
      return makeStep(NativeMediaDispatcherAction::Cancelled,
                      NativeMediaDispatcherWait::Terminal);
    case NativeMediaDispatcherLifecycleKind::Close:
      releaseRetainedEvents();
      descriptor_.reset();
      prepared_context_.reset();
      timeline_.reset();
      lifecycle_timeline_.reset();
      stats_.generation = target;
      stats_.videoConfigured = false;
      stats_.audioConfigured = false;
      operation_generation_.store(0, std::memory_order_release);
      stats_.state = NativeMediaDispatcherState::Closed;
      stats_.lifecycle = NativeMediaDispatcherLifecycleKind::None;
      stats_.lifecycleRetiredGeneration = 0;
      stats_.lifecycleTargetGeneration = 0;
      return makeStep(NativeMediaDispatcherAction::Closed,
                      NativeMediaDispatcherWait::Terminal);
    case NativeMediaDispatcherLifecycleKind::Retire:
      releaseRetainedEvents();
      descriptor_.reset();
      prepared_context_.reset();
      timeline_.reset();
      lifecycle_timeline_.reset();
      stats_.generation = target;
      stats_.videoConfigured = false;
      stats_.audioConfigured = false;
      operation_generation_.store(0, std::memory_order_release);
      stats_.state = NativeMediaDispatcherState::Closed;
      stats_.lifecycle = NativeMediaDispatcherLifecycleKind::None;
      stats_.lifecycleRetiredGeneration = 0;
      stats_.lifecycleTargetGeneration = 0;
      return makeStep(NativeMediaDispatcherAction::Closed,
                      NativeMediaDispatcherWait::Terminal);
    case NativeMediaDispatcherLifecycleKind::FailureCancel:
    case NativeMediaDispatcherLifecycleKind::FailureClose:
      releaseRetainedEvents();
      timeline_.reset();
      lifecycle_timeline_.reset();
      if (kind == NativeMediaDispatcherLifecycleKind::FailureClose) {
        descriptor_.reset();
        prepared_context_.reset();
        stats_.videoConfigured = false;
        stats_.audioConfigured = false;
      }
      operation_generation_.store(0, std::memory_order_release);
      stats_.lifecycle = NativeMediaDispatcherLifecycleKind::None;
      stats_.lifecycleRetiredGeneration = 0;
      stats_.lifecycleTargetGeneration = 0;
      return makeStep(NativeMediaDispatcherAction::Failed,
                      NativeMediaDispatcherWait::Terminal);
    case NativeMediaDispatcherLifecycleKind::None:
      break;
    }
  }

  NativeMediaDispatcherWait wait = NativeMediaDispatcherWait::Consumers;
  if (immediateProgress) {
    wait = NativeMediaDispatcherWait::CallAgain;
  } else if (stats_.lifecycleVideoDone && !stats_.lifecycleAudioDone) {
    wait = NativeMediaDispatcherWait::AudioConsumer;
  } else if (!stats_.lifecycleVideoDone && stats_.lifecycleAudioDone) {
    wait = NativeMediaDispatcherWait::VideoConsumer;
  }
  switch (kind) {
  case NativeMediaDispatcherLifecycleKind::Seek:
    return makeStep(NativeMediaDispatcherAction::SeekQuiescing, wait);
  case NativeMediaDispatcherLifecycleKind::Cancel:
    return makeStep(NativeMediaDispatcherAction::CancelQuiescing, wait);
  case NativeMediaDispatcherLifecycleKind::Close:
    return makeStep(NativeMediaDispatcherAction::CloseQuiescing, wait);
  case NativeMediaDispatcherLifecycleKind::Retire:
    return makeStep(NativeMediaDispatcherAction::RetireQuiescing, wait);
  case NativeMediaDispatcherLifecycleKind::FailureCancel:
  case NativeMediaDispatcherLifecycleKind::FailureClose:
    return makeStep(NativeMediaDispatcherAction::Failed, wait);
  case NativeMediaDispatcherLifecycleKind::None:
    break;
  }
  return failStep(NativeMediaDispatcherFailure::ConsumerProtocol);
}

NativeMediaDispatcherStep NativeMediaDispatcher::makeStep(
    NativeMediaDispatcherAction action, NativeMediaDispatcherWait wait,
    MediaTrackId track) noexcept {
  stats_.lastAction = action;
  stats_.lastWait = wait;
  return {action, wait, stats_.state, stats_.failure, stats_.generation, track};
}

NativeMediaDispatcherStep NativeMediaDispatcher::failStep(
    NativeMediaDispatcherFailure failure) noexcept {
  releaseRetainedEvents();
  fail(failure, stats_.generation);
  return makeStep(NativeMediaDispatcherAction::Failed,
                  stats_.lifecycle == NativeMediaDispatcherLifecycleKind::None
                      ? NativeMediaDispatcherWait::Terminal
                      : NativeMediaDispatcherWait::CallAgain);
}

void NativeMediaDispatcher::fail(NativeMediaDispatcherFailure failure,
                                 MediaGeneration sourceGeneration) noexcept {
  stats_.state = NativeMediaDispatcherState::Failed;
  stats_.failure = failure;
  stats_.lastAction = NativeMediaDispatcherAction::Failed;
  operation_generation_.store(0, std::memory_order_release);
  if (source_ != nullptr && sourceGeneration != 0) {
    source_->requestCancel(sourceGeneration);
  }
  if (stats_.videoConfigured || stats_.audioConfigured) {
    beginLifecycle(NativeMediaDispatcherLifecycleKind::FailureCancel,
                   consumer_generation_, consumer_generation_);
    stats_.lastWait = NativeMediaDispatcherWait::CallAgain;
  } else {
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
  }
}

void NativeMediaDispatcher::beginLifecycle(
    NativeMediaDispatcherLifecycleKind kind,
    MediaGeneration retiredGeneration,
    MediaGeneration targetGeneration) noexcept {
  if (kind != NativeMediaDispatcherLifecycleKind::Seek) {
    lifecycle_timeline_.reset();
  }
  stats_.lifecycle = kind;
  stats_.lifecycleRetiredGeneration = retiredGeneration;
  stats_.lifecycleTargetGeneration = targetGeneration;
  if (kind == NativeMediaDispatcherLifecycleKind::Close ||
      kind == NativeMediaDispatcherLifecycleKind::Retire ||
      kind == NativeMediaDispatcherLifecycleKind::FailureClose) {
    // close() is also the retirement proof for an injected-but-unconfigured
    // port (for example, a partial configure failure).
    stats_.lifecycleVideoDone = video_ == nullptr;
    stats_.lifecycleAudioDone = audio_ == nullptr;
  } else {
    stats_.lifecycleVideoDone = !stats_.videoConfigured;
    stats_.lifecycleAudioDone = !stats_.audioConfigured;
  }
}

void NativeMediaDispatcher::beginFailureLifecycle(
    NativeMediaDispatcherLifecycleKind kind,
    MediaGeneration sourceGeneration) noexcept {
  operation_generation_.store(0, std::memory_order_release);
  if (source_ != nullptr && sourceGeneration != 0) {
    source_->requestCancel(sourceGeneration);
  }
  if (kind == NativeMediaDispatcherLifecycleKind::FailureClose &&
      source_ != nullptr) {
    source_->close();
  }
  beginLifecycle(kind, consumer_generation_, sourceGeneration);
}

void NativeMediaDispatcher::forceClose() noexcept {
  if (stats_.state == NativeMediaDispatcherState::Closed) {
    return;
  }
  const MediaGeneration operation =
      operation_generation_.exchange(0, std::memory_order_acq_rel);
  if (source_ != nullptr) {
    if (operation != 0) {
      source_->requestCancel(operation);
    }
    source_->close();
  }
  const NativeMediaConsumerProgress videoProgress =
      video_ == nullptr ? NativeMediaConsumerProgress::Done : video_->close();
  const NativeMediaConsumerProgress audioProgress =
      audio_ == nullptr ? NativeMediaConsumerProgress::Done : audio_->close();
  if (videoProgress == NativeMediaConsumerProgress::Done &&
      audioProgress == NativeMediaConsumerProgress::Done) {
    releaseRetainedEvents();
    descriptor_.reset();
    prepared_context_.reset();
    timeline_.reset();
    lifecycle_timeline_.reset();
    stats_.videoConfigured = false;
    stats_.audioConfigured = false;
    stats_.lifecycle = NativeMediaDispatcherLifecycleKind::None;
    stats_.state = NativeMediaDispatcherState::Closed;
    stats_.lastAction = NativeMediaDispatcherAction::Closed;
    stats_.lastWait = NativeMediaDispatcherWait::Terminal;
    return;
  }
  // No observable false proof: consumer destructors own the safe quarantine
  // path documented by the port contract if destruction reaches Quiescing.
  stats_.state = NativeMediaDispatcherState::Closing;
  stats_.lifecycle = NativeMediaDispatcherLifecycleKind::Close;
  lifecycle_timeline_.reset();
  stats_.lifecycleVideoDone =
      videoProgress == NativeMediaConsumerProgress::Done;
  stats_.lifecycleAudioDone =
      audioProgress == NativeMediaConsumerProgress::Done;
  stats_.lastAction = NativeMediaDispatcherAction::CloseQuiescing;
  stats_.lastWait = NativeMediaDispatcherWait::Consumers;
}

void NativeMediaDispatcher::resetGenerationFacts() noexcept {
  stats_.videoEndOfStream = !stats_.videoConfigured;
  stats_.audioEndOfStream = !stats_.audioConfigured;
  stats_.videoDrained = !stats_.videoConfigured;
  stats_.audioDrained = !stats_.audioConfigured;
  stats_.sourceExhausted = false;
}

bool NativeMediaDispatcher::allSelectedEnded() const noexcept {
  return stats_.videoEndOfStream && stats_.audioEndOfStream;
}

bool NativeMediaDispatcher::allSelectedDrained() const noexcept {
  return stats_.videoDrained && stats_.audioDrained;
}

NativeMediaPendingKind NativeMediaDispatcher::eventPendingKind(
    const MediaSourceReadResult& event, MediaTrackId selectedVideo) noexcept {
  if (const auto* sample = std::get_if<MediaSample>(&event)) {
    if (sample->kind == MediaSampleKind::EncodedVideo) {
      return NativeMediaPendingKind::VideoSample;
    }
    if (sample->kind == MediaSampleKind::EncodedAudio) {
      return NativeMediaPendingKind::AudioSample;
    }
    return NativeMediaPendingKind::None;
  }
  if (const auto* discontinuity = std::get_if<MediaDiscontinuity>(&event)) {
    return discontinuity->track == selectedVideo
               ? NativeMediaPendingKind::VideoDiscontinuity
               : NativeMediaPendingKind::AudioDiscontinuity;
  }
  if (const auto* end = std::get_if<MediaEndOfStream>(&event)) {
    return end->track == selectedVideo
               ? NativeMediaPendingKind::VideoEndOfStream
               : NativeMediaPendingKind::AudioEndOfStream;
  }
  return NativeMediaPendingKind::None;
}

NativeMediaPendingKind NativeMediaDispatcher::pendingKind() const noexcept {
  if (pending_) {
    return eventPendingKind(*pending_, stats_.selectedVideo);
  }
  // A deferred video lane is still exact dispatcher ownership. Report its
  // oldest event so an owner never sees "no retained source data" while the
  // dispatcher holds a video read-ahead lease.
  if (video_lane_.size != 0) {
    return eventPendingKind(*video_lane_.events[video_lane_.head],
                            stats_.selectedVideo);
  }
  if (audio_lane_.size != 0) {
    return eventPendingKind(*audio_lane_.events[audio_lane_.head],
                            stats_.selectedVideo);
  }
  return NativeMediaPendingKind::None;
}

bool NativeMediaDispatcher::laneHasReadAheadRoom(
    const ReadAheadLane& lane, std::size_t payloadHighWater) const noexcept {
  return !lane.ended && lane.size < kLaneReadAheadEvents &&
         lane.payloadBytes < payloadHighWater;
}

bool NativeMediaDispatcher::queuePendingIntoLane(
    ReadAheadLane& lane) noexcept {
  if (!pending_ || lane.size == kLaneReadAheadEvents) {
    return false;
  }
  const std::size_t tail = (lane.head + lane.size) % kLaneReadAheadEvents;
  lane.events[tail] = std::move(pending_);
  ++lane.size;
  lane.payloadBytes += pending_payload_bytes_;
  if (std::holds_alternative<MediaEndOfStream>(*lane.events[tail])) {
    lane.ended = true;
  }
  clearPending();
  return true;
}

void NativeMediaDispatcher::deferPendingIntoLane(
    ReadAheadLane& lane) noexcept {
  if (!pending_ || lane.size == kLaneReadAheadEvents) {
    return;
  }
  // The refused event is always the oldest un-routed event of its lane, so it
  // goes back to the front and per-lane order is preserved exactly.
  lane.head = lane.head == 0 ? kLaneReadAheadEvents - 1 : lane.head - 1;
  lane.events[lane.head] = std::move(pending_);
  ++lane.size;
  lane.payloadBytes += pending_payload_bytes_;
  if (std::holds_alternative<MediaEndOfStream>(*lane.events[lane.head])) {
    lane.ended = true;
  }
  clearPending();
}

bool NativeMediaDispatcher::takeLaneHead(ReadAheadLane& lane,
                                         PendingLaneHead head) noexcept {
  if (pending_ || lane.size == 0) {
    return false;
  }
  std::optional<MediaSourceReadResult>& slot = lane.events[lane.head];
  if (!slot) {
    return false;
  }
  const auto* sample = std::get_if<MediaSample>(&*slot);
  const std::size_t bytes = sample == nullptr ? 0 : sample->payload.byteSize();
  pending_ = std::move(slot);
  slot.reset();
  lane.head = (lane.head + 1) % kLaneReadAheadEvents;
  --lane.size;
  lane.payloadBytes -= std::min(lane.payloadBytes, bytes);
  if (lane.size == 0) {
    // The end-of-stream latch exists only to stop read-ahead while the marker
    // is still queued behind older events of the same lane.
    lane.ended = false;
  }
  pending_generation_ = std::visit(
      [](const auto& event) noexcept { return event.generation; }, *pending_);
  pending_payload_bytes_ = bytes;
  pending_lane_head_ = head;
  return true;
}

void NativeMediaDispatcher::releaseRetainedEvents() noexcept {
  clearPending();
  const auto releaseLane = [](ReadAheadLane& lane) noexcept {
    for (auto& slot : lane.events) {
      slot.reset();
    }
    lane.head = 0;
    lane.size = 0;
    lane.payloadBytes = 0;
    lane.ended = false;
  };
  releaseLane(video_lane_);
  releaseLane(audio_lane_);
  // A retained lane never survives a lifecycle transition, so the window that
  // authorized it is over too. The session re-arms it for the next commit.
  seek_settle_read_ahead_ = false;
}

void NativeMediaDispatcher::installPending(MediaSourceReadResult&& result) {
  const MediaGeneration generation = std::visit(
      [](const auto& event) noexcept { return event.generation; }, result);
  const auto* sample = std::get_if<MediaSample>(&result);
  const std::size_t bytes =
      sample == nullptr ? 0 : sample->payload.byteSize();

  // No external observation or consumer call can occur inside this serialized
  // owner transition. Publish the optional and its cached scalar facts as one
  // method-boundary mutation; stats() therefore never calls back into payload
  // storage and a same-step Accepted sample still contributes to the HWM.
  pending_.emplace(std::move(result));
  pending_generation_ = generation;
  pending_payload_bytes_ = bytes;
  pending_lane_head_ = PendingLaneHead::None;
  peak_pending_payload_bytes_ = std::max(
      peak_pending_payload_bytes_, pending_payload_bytes_ +
                                       video_lane_.payloadBytes +
                                       audio_lane_.payloadBytes);
}

void NativeMediaDispatcher::clearPending() noexcept {
  // Release the lease before publishing zero ownership at the next serialized
  // method boundary. Reentrant observation from a consumer is forbidden by the
  // dispatcher contract.
  pending_.reset();
  pending_generation_ = 0;
  pending_payload_bytes_ = 0;
  pending_lane_head_ = PendingLaneHead::None;
}

MediaGeneration NativeMediaDispatcher::highestExposedGeneration()
    const noexcept {
  MediaGeneration highest = stats_.generation;
  const auto include = [&highest](MediaGeneration generation) noexcept {
    if (generation > highest) {
      highest = generation;
    }
  };
  include(operation_generation_.load(std::memory_order_acquire));
  include(consumer_generation_);
  include(video_exposed_generation_);
  include(audio_exposed_generation_);
  include(stats_.lifecycleRetiredGeneration);
  include(stats_.lifecycleTargetGeneration);
  if (timeline_) {
    include(timeline_->generation);
  }
  if (lifecycle_timeline_) {
    include(lifecycle_timeline_->generation);
  }
  if (source_ != nullptr) {
    const MediaSourceStats sourceStats = source_->stats();
    include(sourceStats.generation);
    include(sourceStats.operationGeneration);
  }
  return highest;
}

}  // namespace wam::media
