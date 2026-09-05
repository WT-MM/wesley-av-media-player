#define WAM_NATIVE_MEDIA_SESSION_TESTING 1

#include "platform/macos/native_media_session.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

namespace {

using namespace wam;
using namespace wam::macos;
namespace protocol = media::native_playback;

[[noreturn]] void fail(const char* message) {
  std::cerr << "FAIL: " << message << '\n';
  std::exit(EXIT_FAILURE);
}

void expect(bool condition, const char* message) {
  if (!condition) {
    fail(message);
  }
}

enum class CommitLifecycleEvent : std::uint8_t {
  SourceSeek,
  AudioFlush,
  AudioStart,
  TargetPause,
  ClockProof,
  VideoProof,
};

struct GraphState {
  std::atomic<std::uint64_t> factoryCalls{0};
  std::atomic<std::uint64_t> sourceArms{0};
  std::atomic<std::uint64_t> sourceOpens{0};
  std::atomic<std::uint64_t> sourceSeeks{0};
  std::atomic<std::uint64_t> sourceCancels{0};
  std::atomic<std::uint64_t> sourceCloses{0};
  std::atomic<std::uint64_t> videoArms{0};
  std::atomic<std::uint64_t> videoConfigures{0};
  std::atomic<std::uint64_t> audioConfigures{0};
  std::atomic<std::uint64_t> videoRetires{0};
  std::atomic<std::uint64_t> audioRetires{0};
  std::atomic<std::uint64_t> videoCloses{0};
  std::atomic<std::uint64_t> audioCloses{0};
  std::atomic<std::uint64_t> order{0};
  std::atomic<std::uint64_t> sourceCloseOrder{0};
  std::atomic<std::uint64_t> videoRetireOrder{0};
  std::atomic<std::uint64_t> audioRetireOrder{0};
  std::atomic<std::uint64_t> firstVideoRetireEntered{0};
  std::atomic<bool> blockFirstVideoRetire{false};
  std::atomic<bool> releaseFirstVideoRetire{false};
  std::atomic<bool> blockVideoArm{false};
  std::atomic<bool> releaseVideoArm{false};
  std::atomic<bool> blockSourceArm{false};
  std::atomic<bool> sourceArmEntered{false};
  std::atomic<bool> releaseSourceArm{false};
  std::atomic<media::MediaGeneration> cancelledGeneration{0};
  std::atomic<bool> quiesceFirstVideoRetire{false};
  std::atomic<bool> blockFactory{false};
  std::atomic<bool> factoryEntered{false};
  std::atomic<bool> releaseFactory{false};
  std::atomic<std::uint64_t> pauseCalls{0};
  std::atomic<std::uint64_t> audioStartCalls{0};
  std::atomic<std::uint64_t> gainCalls{0};
  std::atomic<std::uint64_t> muteCalls{0};
  std::atomic<std::uint64_t> audioStopCalls{0};
  std::atomic<bool> audioPhysicallyStarted{false};
  std::atomic<media::MediaGeneration> audioStartedGeneration{0};
  std::atomic<std::uint64_t> videoFlushes{0};
  std::atomic<std::uint64_t> audioFlushes{0};
  std::atomic<bool> quiesceFirstVideoFlush{false};
  // The preview lane answers its terminal stop with Failed, as a lane that has
  // latched a failure does.
  std::atomic<bool> previewStopFails{false};
  std::atomic<bool> quiesceFirstPreview{false};
  std::atomic<bool> previewQuiesceEntered{false};
  std::atomic<bool> releasePreviewQuiesce{false};
  std::atomic<std::uint64_t> videoTakeCalls{0};
  std::atomic<std::uint64_t> observationQueues{0};
  std::atomic<std::uint64_t> observationQueueAttempts{0};
  std::atomic<std::uint64_t> observationRejectsRemaining{0};
  std::mutex observationMutex;
  std::vector<std::shared_ptr<void>> queuedObservationTickets;
  std::atomic<bool> quiesceFirstPause{false};
  std::atomic<bool> blockPause{false};
  std::atomic<bool> pauseEntered{false};
  std::atomic<bool> releasePause{false};
  std::atomic<bool> failPause{false};
  std::atomic<bool> failStart{false};
  std::atomic<bool> quiesceFirstAudioStop{false};
  std::atomic<bool> blockFirstAudioStop{false};
  std::atomic<bool> releaseFirstAudioStop{false};
  std::atomic<bool> failFirstRead{false};
  std::atomic<bool> blockCapacity{true};
  std::atomic<bool> failCapacity{false};
  std::atomic<float> lastGain{1.0F};
  std::atomic<bool> lastMuted{false};
  std::atomic<std::uint64_t> clockPublication{0};
  std::atomic<media::MediaGeneration> clockGeneration{0};
  std::atomic<double> clockPosition{0.0};
  std::atomic<bool> clockValid{false};
  std::atomic<bool> clockCurrent{false};
  std::atomic<bool> clockRunning{false};
  std::atomic<std::uint64_t> lastOutputEventSequence{0};
  std::atomic<std::uint64_t> videoDueHostTicks{0};
  std::mutex videoEventMutex;
  std::optional<NativeTrackedVideoEvent> videoEvent;
  std::optional<NativeTrackedVideoEvent> pendingVideoEvent;
  std::mutex previewMutex;
  std::optional<protocol::PreviewFrame> previewCommand;
  std::optional<protocol::PreviewPresented> previewPresented;
  std::atomic<std::uint64_t> previewRequests{0};
  std::atomic<std::uint64_t> previewPumps{0};
  std::atomic<std::uint64_t> previewStops{0};
  std::atomic<bool> failPreviewQuiesce{false};
  std::atomic<bool> failPreviewConstruction{false};
  std::atomic<bool> failPreviewRequest{false};
  std::atomic<bool> failPreviewPump{false};
  std::atomic<bool> dropPreviewPresentation{false};
  std::atomic<std::uint64_t> previewQuiesces{0};
  std::atomic<std::uint64_t> previewOrder{0};
  std::atomic<std::uint64_t> firstPreviewPauseOrder{0};
  std::atomic<std::uint64_t> firstPreviewQuiesceOrder{0};
  std::atomic<std::uint64_t> firstPreviewRequestOrder{0};
  std::shared_ptr<const AVFoundationAssetContext> assetContext;
  std::atomic<std::uint64_t> previewBindingObservations{0};
  std::atomic<bool> previewBindingExact{false};
  std::atomic<bool> trackCommitLifecycle{false};
  std::atomic<media::MediaGeneration> trackedCommitGeneration{0};
  std::mutex commitLifecycleMutex;
  std::vector<CommitLifecycleEvent> commitLifecycle;
  media::MediaSourceOpenStatus openStatus{
      media::MediaSourceOpenStatus::Ready};
  std::shared_ptr<const media::MediaSourceDescriptor> descriptor;
  std::pair<media::MediaGeneration, media::MediaGeneration> videoPair{};
  std::pair<media::MediaGeneration, media::MediaGeneration> audioPair{};
  media::MediaGeneration videoExposed{0};
  media::MediaGeneration audioExposed{0};
  bool videoRetired{false};
  bool audioRetired{false};

  void beginCommitLifecycle(media::MediaGeneration generation) {
    std::lock_guard lock(commitLifecycleMutex);
    commitLifecycle.clear();
    trackedCommitGeneration.store(generation, std::memory_order_release);
    trackCommitLifecycle.store(true, std::memory_order_release);
  }

  void recordCommitLifecycle(CommitLifecycleEvent event,
                             media::MediaGeneration generation) {
    if (!trackCommitLifecycle.load(std::memory_order_acquire) ||
        generation !=
            trackedCommitGeneration.load(std::memory_order_acquire)) {
      return;
    }
    std::lock_guard lock(commitLifecycleMutex);
    // The first real target-generation video proof is the final physical
    // prerequisite for CommitReady. Ignore ordinary clock refreshes that may
    // race the GUI-side observation drain after that proof is published.
    if (!commitLifecycle.empty() &&
        commitLifecycle.back() == CommitLifecycleEvent::VideoProof) {
      return;
    }
    commitLifecycle.push_back(event);
  }

  std::vector<CommitLifecycleEvent> finishCommitLifecycle() {
    trackCommitLifecycle.store(false, std::memory_order_release);
    std::lock_guard lock(commitLifecycleMutex);
    return commitLifecycle;
  }
};

media::MediaTrackDescriptor videoTrack(media::MediaTime duration = {10, 1}) {
  media::MediaVideoFormat format;
  format.codedWidth = 640;
  format.codedHeight = 360;
  format.displayWidth = 640;
  format.displayHeight = 360;
  format.bitsPerComponent = 8;
  format.sampleFormat = media::MediaVideoSampleFormat::Yuv420EightBit;
  media::MediaTrackDescriptor track;
  track.id = 1;
  track.kind = media::MediaTrackKind::Video;
  track.codec = media::MediaCodec::H264;
  track.timeBase = {1, 1000};
  track.duration = duration;
  track.video = format;
  return track;
}

media::MediaTrackDescriptor audioTrack(media::MediaTime duration = {10, 1}) {
  media::MediaAudioFormat format;
  format.sampleRate = 48'000.0;
  format.channels = 2;
  format.formatTag = 0x61616320U;
  format.framesPerPacket = 1024;
  media::MediaTrackDescriptor track;
  track.id = 2;
  track.kind = media::MediaTrackKind::Audio;
  track.codec = media::MediaCodec::Aac;
  track.timeBase = {1, 48'000};
  track.duration = duration;
  track.audio = format;
  return track;
}

std::shared_ptr<const media::MediaSourceDescriptor> descriptor(
    media::MediaTime audioDuration = {10, 1},
    bool includeAudio = true) {
  auto value = std::make_shared<media::MediaSourceDescriptor>();
  value->duration = {10, 1};
  value->inventory.video = 1;
  value->tracks.push_back(videoTrack());
  value->selectedVideo = 1;
  if (includeAudio) {
    value->inventory.audio = 1;
    value->tracks.push_back(audioTrack(audioDuration));
    value->selectedAudio = 2;
  }
  value->inventory.total = includeAudio ? 2 : 1;
  return value;
}

void installExactAssetContext(GraphState& state) {
  media::MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  options.selection.requireAudio = true;
  state.assetContext = makeAVFoundationAssetContextForTesting(
      "/tmp/native-session-test.mov", options, state.descriptor,
      std::make_shared<int>(1));
  expect(state.assetContext != nullptr,
         "test creates exact main-source asset context");
}

class FakeSource final : public media::MediaSource {
 public:
  explicit FakeSource(std::shared_ptr<GraphState> state) noexcept
      : state_(std::move(state)) {}

  bool armOperation(media::MediaGeneration generation) noexcept override {
    state_->sourceArms.fetch_add(1, std::memory_order_relaxed);
    if (generation == 0 || generation <= generation_) {
      return false;
    }
    generation_ = generation;
    operation_.store(generation, std::memory_order_release);
    state_->sourceArmEntered.store(true, std::memory_order_release);
    while (state_->blockSourceArm.load(std::memory_order_acquire) &&
           !state_->releaseSourceArm.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
    return true;
  }

  media::MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path&,
      const media::MediaSourceOpenOptions& options,
      media::MediaGeneration generation) override {
    state_->sourceOpens.fetch_add(1, std::memory_order_relaxed);
    operation_.store(0, std::memory_order_release);
    if (state_->cancelledGeneration.load(std::memory_order_acquire) ==
        generation) {
      return {media::MediaSourceOpenStatus::Cancelled, generation, {0, 1},
              {}, {}, {}, {}};
    }
    media::MediaAudioGenerationWindow audioWindow;
    if (state_->descriptor && state_->descriptor->selectedAudio) {
      audioWindow.decodeStart = {0, 1};
      const media::MediaTime target = options.initialPosition
                                          ? options.initialPosition->target
                                          : media::MediaTime{0, 1};
      const media::MediaSeekMode mode = options.initialPosition
                                            ? options.initialPosition->mode
                                            : media::MediaSeekMode::Accurate;
      audioWindow.presentationStart =
          mode == media::MediaSeekMode::KeyFrame
              ? audioWindow.decodeStart
              : media::audioFrameAtOrAfter(target, 48'000)
                    .value_or(media::MediaTime{});
      audioWindow.startsAtStreamOrigin = true;
    }
    return {state_->openStatus, generation, {0, 1}, state_->descriptor, {},
            {}, audioWindow};
  }

  media::MediaSourceSeekOutcome seek(
      const media::MediaSourceSeekRequest& request) override {
    state_->sourceSeeks.fetch_add(1, std::memory_order_relaxed);
    state_->recordCommitLifecycle(CommitLifecycleEvent::SourceSeek,
                                  request.generation);
    operation_.store(0, std::memory_order_release);
    generation_ = request.generation;
    state_->clockGeneration.store(request.generation,
                                  std::memory_order_release);
    state_->clockPosition.store(
        media::mediaTimeSeconds(request.target).value_or(-1.0),
        std::memory_order_release);
    state_->clockValid.store(true, std::memory_order_release);
    state_->clockCurrent.store(true, std::memory_order_release);
    state_->clockRunning.store(false, std::memory_order_release);
    state_->clockPublication.fetch_add(1, std::memory_order_acq_rel);
    media::MediaAudioGenerationWindow audioWindow;
    if (state_->descriptor && state_->descriptor->selectedAudio) {
      const auto boundary =
          media::audioFrameAtOrAfter(request.target, 48'000);
      if (boundary) {
        audioWindow.decodeStart = request.mode == media::MediaSeekMode::Accurate
                                      ? *boundary
                                      : request.target;
        audioWindow.presentationStart = audioWindow.decodeStart;
        audioWindow.startsAtStreamOrigin =
            audioWindow.decodeStart == media::MediaTime{0, 1};
      }
    }
    return {true, request.generation, request.target, {}, {}, audioWindow};
  }

  media::MediaSourceReadResult readNext(
      media::MediaGeneration generation) override {
    const std::uint64_t index = read_++;
    if (index == 0 &&
        state_->failFirstRead.load(std::memory_order_acquire)) {
      return media::MediaSourceFailure{generation, "injected read failure"};
    }
    if (index == 0) {
      return media::MediaEndOfStream{generation, 1};
    }
    if (index == 1) {
      return media::MediaEndOfStream{generation, 2};
    }
    return media::MediaSourceExhausted{generation};
  }

  void requestCancel(media::MediaGeneration generation) noexcept override {
    if (operation_.load(std::memory_order_acquire) == generation) {
      state_->sourceCancels.fetch_add(1, std::memory_order_relaxed);
      state_->cancelledGeneration.store(generation,
                                        std::memory_order_release);
      operation_.store(0, std::memory_order_release);
    }
  }

  void close() noexcept override {
    state_->sourceCloses.fetch_add(1, std::memory_order_relaxed);
    state_->sourceCloseOrder.store(
        state_->order.fetch_add(1, std::memory_order_relaxed) + 1,
        std::memory_order_release);
    operation_.store(0, std::memory_order_release);
  }

  media::MediaSourceStats stats() const noexcept override {
    media::MediaSourceStats result;
    result.generation = generation_;
    result.operationGeneration =
        operation_.load(std::memory_order_acquire);
    return result;
  }

 private:
  std::shared_ptr<GraphState> state_;
  std::atomic<media::MediaGeneration> operation_{0};
  media::MediaGeneration generation_{0};
  std::uint64_t read_{0};
};

template <typename Base>
class FakeConsumer : public Base {
 public:
  FakeConsumer(std::shared_ptr<GraphState> state, bool video) noexcept
      : state_(std::move(state)), video_(video) {}

  media::NativeMediaConsumeResult configure(
      const media::MediaTrackDescriptor&, media::MediaGeneration generation,
      const media::NativeMediaGenerationTimeline&,
      std::string*) override {
    if (video_) {
      state_->videoConfigures.fetch_add(1, std::memory_order_relaxed);
      state_->videoExposed = generation;
    } else {
      state_->audioConfigures.fetch_add(1, std::memory_order_relaxed);
      state_->audioExposed = generation;
    }
    return media::NativeMediaConsumeResult::Accepted;
  }

  media::NativeMediaConsumeResult capacity(
      media::MediaGeneration) override {
    if (state_->failCapacity.load(std::memory_order_acquire)) {
      return media::NativeMediaConsumeResult::Failed;
    }
    if (state_->blockCapacity.load(std::memory_order_acquire)) {
      return media::NativeMediaConsumeResult::Backpressure;
    }
    return media::NativeMediaConsumeResult::Accepted;
  }

  media::NativeMediaConsumeResult trySample(
      media::NativeMediaSampleDelivery&, std::string*) override {
    return media::NativeMediaConsumeResult::Accepted;
  }

  media::NativeMediaConsumeResult discontinuity(
      const media::MediaDiscontinuity&, std::string*) override {
    return media::NativeMediaConsumeResult::Accepted;
  }

  media::NativeMediaConsumeResult endOfStream(
      const media::MediaEndOfStream&, std::string*) override {
    return media::NativeMediaConsumeResult::Drained;
  }

  media::NativeMediaConsumerProgress drain(
      media::MediaGeneration, std::string*) override {
    return media::NativeMediaConsumerProgress::Done;
  }

  media::NativeMediaConsumerProgress cancel(
      media::MediaGeneration) noexcept override {
    return media::NativeMediaConsumerProgress::Done;
  }

  media::NativeMediaConsumerProgress flush(
      media::MediaGeneration, media::MediaGeneration next,
      const media::NativeMediaGenerationTimeline&) noexcept override {
    if (video_) {
      const std::uint64_t call =
          state_->videoFlushes.fetch_add(1, std::memory_order_relaxed) + 1;
      state_->videoExposed = next;
      if (state_->quiesceFirstVideoFlush.load(std::memory_order_acquire) &&
          call == 1) {
        return media::NativeMediaConsumerProgress::Quiescing;
      }
    } else {
      state_->audioFlushes.fetch_add(1, std::memory_order_relaxed);
      state_->audioExposed = next;
      state_->audioPhysicallyStarted.store(false,
                                           std::memory_order_release);
      state_->recordCommitLifecycle(CommitLifecycleEvent::AudioFlush, next);
    }
    return media::NativeMediaConsumerProgress::Done;
  }

  media::NativeMediaConsumerProgress retire(
      media::MediaGeneration retired,
      media::MediaGeneration invalidation) noexcept override {
    if (video_) {
      const std::uint64_t call =
          state_->videoRetires.fetch_add(1, std::memory_order_relaxed) + 1;
      state_->firstVideoRetireEntered.store(call, std::memory_order_release);
      state_->videoPair = {retired, invalidation};
      while (state_->blockFirstVideoRetire.load(std::memory_order_acquire) &&
             call == 1 &&
             !state_->releaseFirstVideoRetire.load(
                 std::memory_order_acquire)) {
        std::this_thread::yield();
      }
      if (state_->quiesceFirstVideoRetire.load(std::memory_order_acquire) &&
          call == 1) {
        return media::NativeMediaConsumerProgress::Quiescing;
      }
      state_->videoRetired = true;
      state_->videoRetireOrder.store(
          state_->order.fetch_add(1, std::memory_order_relaxed) + 1,
          std::memory_order_release);
    } else {
      state_->audioRetires.fetch_add(1, std::memory_order_relaxed);
      state_->audioPair = {retired, invalidation};
      state_->audioRetired = true;
      state_->audioRetireOrder.store(
          state_->order.fetch_add(1, std::memory_order_relaxed) + 1,
          std::memory_order_release);
    }
    return media::NativeMediaConsumerProgress::Done;
  }

  media::NativeMediaConsumerProgress close() noexcept override {
    if (video_) {
      state_->videoCloses.fetch_add(1, std::memory_order_relaxed);
    } else {
      state_->audioCloses.fetch_add(1, std::memory_order_relaxed);
    }
    return media::NativeMediaConsumerProgress::Done;
  }

 private:
  std::shared_ptr<GraphState> state_;
  bool video_{false};
};

class NullOutput final : public NativeTrackedVideoOutput {
 public:
  NativeTrackedVideoCapacity capacity(std::uint64_t) const noexcept override {
    return NativeTrackedVideoCapacity::Available;
  }
  NativeTrackedVideoSubmitStatus submit(
      const FrameLease&, NativeTrackedFrameSequence,
      std::string*) noexcept override {
    return NativeTrackedVideoSubmitStatus::Accepted;
  }
  std::optional<NativeTrackedVideoEvent> takeEvent() noexcept override {
    return std::nullopt;
  }
  NativeTrackedVideoOutputProgress flushProgress(
      std::uint64_t, std::uint64_t next) noexcept override {
    generation_ = next;
    return NativeTrackedVideoOutputProgress::Done;
  }
  NativeTrackedVideoOutputProgress closeProgress(
      std::uint64_t next) noexcept override {
    generation_ = next;
    closed_ = true;
    return NativeTrackedVideoOutputProgress::Done;
  }
  NativeTrackedVideoOutputFacts facts() const noexcept override {
    NativeTrackedVideoOutputFacts result;
    result.generation = generation_;
    result.lastEventSequence = lastEventSequence_;
    result.closed = closed_;
    return result;
  }

 private:
  std::uint64_t generation_{0};
  std::uint64_t lastEventSequence_{0};
  bool closed_{false};
};

class NullPreviewOutput final : public NativeTrackedVideoPreviewPort {
 public:
  NativeTrackedVideoCapacity capacity(std::uint64_t) const noexcept override {
    return NativeTrackedVideoCapacity::Available;
  }
  NativeTrackedVideoPreviewSubmitResult submit(
      std::uint64_t, const FrameLease&, std::string*) noexcept override {
    return {NativeTrackedVideoSubmitStatus::Accepted, {1}};
  }
  std::optional<NativeTrackedVideoPreviewEvent> takeEvent() noexcept override {
    return std::nullopt;
  }
  NativeTrackedVideoPreviewCancelProgress cancel() noexcept override {
    return NativeTrackedVideoPreviewCancelProgress::Done;
  }
};

NativeVideoConsumerArmProgress armVideo(
    void* context, media::MediaGeneration generation) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  state.videoArms.fetch_add(1, std::memory_order_relaxed);
  state.videoExposed = generation;
  if (state.blockVideoArm.load(std::memory_order_acquire) &&
      !state.releaseVideoArm.load(std::memory_order_acquire)) {
    return NativeVideoConsumerArmProgress::Quiescing;
  }
  return NativeVideoConsumerArmProgress::Done;
}

media::MediaGeneration videoHigh(void* context) noexcept {
  return static_cast<GraphState*>(context)->videoExposed;
}

media::MediaGeneration audioHigh(void* context) noexcept {
  return static_cast<GraphState*>(context)->audioExposed;
}

std::uint64_t lastOutputEventSequence(void* context) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  std::lock_guard lock(state.videoEventMutex);
  const std::uint64_t consumed =
      state.lastOutputEventSequence.load(std::memory_order_acquire);
  return state.pendingVideoEvent.has_value()
             ? std::max(consumed,
                        state.pendingVideoEvent->eventSequence)
             : consumed;
}

std::uint64_t nextVideoDueHostTicks(void* context) noexcept {
  return static_cast<GraphState*>(context)->videoDueHostTicks.load(
      std::memory_order_acquire);
}

std::optional<NativeTrackedVideoEvent> takeOutputEvent(
    void* context) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  state.videoTakeCalls.fetch_add(1, std::memory_order_relaxed);
  std::lock_guard lock(state.videoEventMutex);
  std::optional<NativeTrackedVideoEvent> result;
  if (state.pendingVideoEvent.has_value()) {
    result = std::move(state.pendingVideoEvent);
    state.pendingVideoEvent.reset();
  } else {
    result = std::move(state.videoEvent);
    state.videoEvent.reset();
  }
  if (result.has_value()) {
    state.lastOutputEventSequence.store(result->eventSequence,
                                        std::memory_order_release);
    state.recordCommitLifecycle(CommitLifecycleEvent::VideoProof,
                                result->generation);
  }
  return result;
}

NativeVideoConsumerPreviewProgress quiesceForPreview(
    void* context, media::MediaGeneration generation) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  const std::uint64_t call =
      state.previewQuiesces.fetch_add(1, std::memory_order_relaxed) + 1;
  if (call == 1) {
    state.firstPreviewQuiesceOrder.store(
        state.previewOrder.fetch_add(1, std::memory_order_relaxed) + 1,
        std::memory_order_release);
    state.previewQuiesceEntered.store(true, std::memory_order_release);
    if (state.quiesceFirstPreview.load(std::memory_order_acquire) &&
        !state.releasePreviewQuiesce.load(std::memory_order_acquire)) {
      return NativeVideoConsumerPreviewProgress::Quiescing;
    }
  }
  if (state.failPreviewQuiesce.load(std::memory_order_acquire)) {
    return NativeVideoConsumerPreviewProgress::Failed;
  }
  return generation == state.videoExposed
             ? NativeVideoConsumerPreviewProgress::Done
             : NativeVideoConsumerPreviewProgress::StaleGeneration;
}

NativePreviewFrameRequestStatus previewRequest(
    void* context, protocol::PreviewFrame command,
    NativePreviewFrameTarget target) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  if (command.targetSeconds != target.seconds()) {
    return NativePreviewFrameRequestStatus::Invalid;
  }
  if (state.failPreviewRequest.load(std::memory_order_acquire)) {
    state.previewRequests.fetch_add(1, std::memory_order_relaxed);
    return NativePreviewFrameRequestStatus::Failed;
  }
  std::lock_guard lock(state.previewMutex);
  const bool replaced = state.previewCommand.has_value();
  state.previewCommand = command;
  state.previewPresented.reset();
  const std::uint64_t call =
      state.previewRequests.fetch_add(1, std::memory_order_relaxed) + 1;
  if (call == 1) {
    state.firstPreviewRequestOrder.store(
        state.previewOrder.fetch_add(1, std::memory_order_relaxed) + 1,
        std::memory_order_release);
  }
  return replaced ? NativePreviewFrameRequestStatus::Replaced
                  : NativePreviewFrameRequestStatus::Accepted;
}

NativePreviewFramePumpProgress previewPump(void* context) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  std::lock_guard lock(state.previewMutex);
  state.previewPumps.fetch_add(1, std::memory_order_relaxed);
  if (state.failPreviewPump.load(std::memory_order_acquire)) {
    return NativePreviewFramePumpProgress::Failed;
  }
  if (!state.previewCommand.has_value()) {
    return NativePreviewFramePumpProgress::Idle;
  }
  const protocol::PreviewFrame command = *state.previewCommand;
  state.previewCommand.reset();
  if (state.dropPreviewPresentation.load(std::memory_order_acquire)) {
    state.previewPresented.reset();
    return NativePreviewFramePumpProgress::Idle;
  }
  state.previewPresented = protocol::PreviewPresented{
      command.stamp, command.generation, command.gesture, command.request,
      command.targetSeconds};
  return NativePreviewFramePumpProgress::Progress;
}

std::optional<protocol::PreviewPresented> takePreviewPresented(
    void* context) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  std::lock_guard lock(state.previewMutex);
  auto result = state.previewPresented;
  state.previewPresented.reset();
  return result;
}

NativePreviewFrameCancelProgress stopPreview(
    void* context, protocol::Generation) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  std::lock_guard lock(state.previewMutex);
  state.previewCommand.reset();
  state.previewPresented.reset();
  state.previewStops.fetch_add(1, std::memory_order_relaxed);
  return state.previewStopFails.load(std::memory_order_acquire)
             ? NativePreviewFrameCancelProgress::Failed
             : NativePreviewFrameCancelProgress::Done;
}

NativeAudioSessionProgress audioStart(void* context) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  state.audioStartCalls.fetch_add(1, std::memory_order_relaxed);
  if (state.failStart.load(std::memory_order_acquire)) {
    return NativeAudioSessionProgress::Failed;
  }
  state.audioPhysicallyStarted.store(true, std::memory_order_release);
  state.audioStartedGeneration.store(state.audioExposed,
                                     std::memory_order_release);
  state.recordCommitLifecycle(CommitLifecycleEvent::AudioStart,
                              state.audioExposed);
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress audioPaused(void* context, bool paused) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  const std::uint64_t call =
      state.pauseCalls.fetch_add(1, std::memory_order_relaxed) + 1;
  if (call == 1) {
    state.firstPreviewPauseOrder.store(
        state.previewOrder.fetch_add(1, std::memory_order_relaxed) + 1,
        std::memory_order_release);
  }
  state.pauseEntered.store(true, std::memory_order_release);
  while (state.blockPause.load(std::memory_order_acquire) &&
         !state.releasePause.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  if (state.failPause.load(std::memory_order_acquire)) {
    return NativeAudioSessionProgress::Failed;
  }
  if (state.quiesceFirstPause.load(std::memory_order_acquire) && call == 1) {
    return NativeAudioSessionProgress::Quiescing;
  }
  state.clockGeneration.store(state.audioExposed, std::memory_order_release);
  state.clockValid.store(true, std::memory_order_release);
  state.clockCurrent.store(true, std::memory_order_release);
  state.clockRunning.store(!paused, std::memory_order_release);
  state.clockPublication.fetch_add(1, std::memory_order_acq_rel);
  if (paused) {
    state.recordCommitLifecycle(CommitLifecycleEvent::TargetPause,
                                state.audioExposed);
  }
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress audioGain(void* context, float gain) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  state.gainCalls.fetch_add(1, std::memory_order_relaxed);
  state.lastGain.store(gain, std::memory_order_release);
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress audioMuted(void* context, bool muted) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  state.muteCalls.fetch_add(1, std::memory_order_relaxed);
  state.lastMuted.store(muted, std::memory_order_release);
  return NativeAudioSessionProgress::Done;
}

NativeAudioSessionProgress audioStop(void* context) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  const std::uint64_t call =
      state.audioStopCalls.fetch_add(1, std::memory_order_relaxed) + 1;
  while (state.blockFirstAudioStop.load(std::memory_order_acquire) &&
         call == 1 &&
         !state.releaseFirstAudioStop.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  if (state.quiesceFirstAudioStop.load(std::memory_order_acquire) &&
      call == 1) {
    return NativeAudioSessionProgress::Quiescing;
  }
  state.clockRunning.store(false, std::memory_order_release);
  state.clockCurrent.store(true, std::memory_order_release);
  state.clockValid.store(true, std::memory_order_release);
  state.clockGeneration.store(state.audioExposed,
                              std::memory_order_release);
  state.clockPublication.fetch_add(1, std::memory_order_acq_rel);
  state.audioPhysicallyStarted.store(false, std::memory_order_release);
  return NativeAudioSessionProgress::Done;
}

NativeMediaClockSnapshot testClock(void* context) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  NativeMediaClockSnapshot result;
  result.publicationSerial =
      state.clockPublication.load(std::memory_order_acquire);
  result.generation =
      state.clockGeneration.load(std::memory_order_acquire);
  result.mediaSeconds =
      state.clockPosition.load(std::memory_order_acquire);
  result.rate = 1.0;
  result.valid = state.clockValid.load(std::memory_order_acquire);
  result.running = state.clockRunning.load(std::memory_order_acquire);
  result.publicationCurrent =
      state.clockCurrent.load(std::memory_order_acquire);
  state.recordCommitLifecycle(CommitLifecycleEvent::ClockProof,
                              result.generation);
  return result;
}

bool queueObservations(std::shared_ptr<void> lifetime,
                       void* context) noexcept {
  expect(lifetime != nullptr,
         "queued observation owns a lifetime ticket");
  auto& state = *static_cast<GraphState*>(context);
  state.observationQueueAttempts.fetch_add(1, std::memory_order_release);
  std::uint64_t remaining =
      state.observationRejectsRemaining.load(std::memory_order_acquire);
  while (remaining != 0 &&
         !state.observationRejectsRemaining.compare_exchange_weak(
             remaining, remaining - 1, std::memory_order_acq_rel,
             std::memory_order_acquire)) {
  }
  if (remaining != 0)
    return false;
  {
    std::lock_guard lock(state.observationMutex);
    state.queuedObservationTickets.emplace_back(std::move(lifetime));
  }
  state.observationQueues.fetch_add(1, std::memory_order_release);
  return true;
}

bool observePreviewBinding(
    void* context,
    const NativePreviewBinding& binding) noexcept {
  auto& state = *static_cast<GraphState*>(context);
  const bool exact = state.assetContext != nullptr &&
                     binding.assetContext.get() ==
                         state.assetContext.get() &&
                     binding.descriptor.get() == state.descriptor.get() &&
                     binding.assetContext->descriptor().get() ==
                         state.descriptor.get() &&
                     binding.localPath ==
                         std::filesystem::path(
                             "/tmp/native-session-test.mov");
  const bool accepted =
      exact && !state.failPreviewConstruction.load(std::memory_order_acquire);
  state.previewBindingExact.store(exact, std::memory_order_release);
  state.previewBindingObservations.fetch_add(1,
                                             std::memory_order_release);
  return accepted;
}

NativeMediaSessionTestGraph makeGraph(void* context) {
  auto* holder = static_cast<std::shared_ptr<GraphState>*>(context);
  const auto state = *holder;
  state->factoryCalls.fetch_add(1, std::memory_order_relaxed);
  state->factoryEntered.store(true, std::memory_order_release);
  while (state->blockFactory.load(std::memory_order_acquire) &&
         !state->releaseFactory.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  NativeMediaSessionTestGraph graph;
  graph.source = std::make_unique<FakeSource>(state);
  graph.video =
      std::make_unique<FakeConsumer<media::NativeVideoConsumer>>(state, true);
  graph.audio =
      std::make_unique<FakeConsumer<media::NativeAudioConsumer>>(state, false);
  graph.videoControl = {state.get(), &armVideo, &videoHigh,
                        &lastOutputEventSequence, &nextVideoDueHostTicks,
                        &takeOutputEvent,
                        &quiesceForPreview};
  graph.audioControl = {state.get(), &audioStart, &audioPaused, &audioGain,
                        &audioMuted, &audioStop, &testClock, &audioHigh};
  graph.previewControl = {state.get(), &previewRequest, &previewPump,
                          &takePreviewPresented, &stopPreview};
  graph.assetContext = state->assetContext;
  if (state->assetContext != nullptr) {
    graph.observePreviewBinding = &observePreviewBinding;
    graph.previewBindingObserverContext = state.get();
  }
  return graph;
}

std::uint64_t ticks(void*) noexcept { return 1; }

std::unique_ptr<NativeMediaSession> sessionFor(
    std::shared_ptr<GraphState>* state,
    std::shared_ptr<NativeMediaSessionWake>* wakeOut = nullptr,
    bool bindObservations = true) {
  auto wake = NativeMediaSessionWake::create();
  NativeMediaSessionDependencies dependencies;
  dependencies.externalLifetime = *state;
  dependencies.wake = wake;
  dependencies.videoOutput = std::make_shared<NullOutput>();
  dependencies.previewOutput = std::make_shared<NullPreviewOutput>();
  dependencies.hostClock = {&ticks, nullptr, 1'000};
  auto result = NativeMediaSession::create(
      {{1}, std::filesystem::path("/tmp/native-session-test.mov")},
      std::move(dependencies));
  expect(result != nullptr, "test session creates");
  NativeMediaSessionTestAccess::installGraphFactory(
      *result, &makeGraph, state);
  if (bindObservations) {
    expect(result->bindObservationEdge(
               {std::make_shared<int>(1), &queueObservations,
                state->get()}),
           "test observation edge binds before Prepare");
  }
  if (wakeOut != nullptr) {
    *wakeOut = std::move(wake);
  }
  return result;
}

template <typename Fact>
Fact waitFact(NativeMediaSession& session, const char* message) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    const NativeMediaSessionFacts facts = session.facts();
    bool ready = false;
    if constexpr (std::is_same_v<Fact,
                                 NativeMediaSessionRunStateApplied>) {
      ready = facts.observationPending;
    } else if constexpr (std::is_same_v<Fact, protocol::CommitReady>) {
      ready = facts.commitReadyPending;
    } else {
      ready = facts.factPending;
    }
    if (!ready) {
      std::this_thread::sleep_for(std::chrono::microseconds(50));
      continue;
    }
    NativeMediaSessionObservations observations = session.takeObservations();
    if constexpr (std::is_same_v<Fact,
                                 NativeMediaSessionRunStateApplied>) {
      if (observations.runStateApplied.has_value()) {
        return *observations.runStateApplied;
      }
    } else if constexpr (std::is_same_v<Fact, protocol::CommitReady>) {
      if (observations.commitReady.has_value()) {
        return *observations.commitReady;
      }
    } else {
      if (observations.lifecycle.has_value()) {
        if (auto* expected = std::get_if<Fact>(&*observations.lifecycle)) {
          return *expected;
        }
        fail(message);
      }
    }
    std::this_thread::sleep_for(std::chrono::microseconds(50));
  }
  fail(message);
}

template <typename Predicate>
NativeMediaSessionObservations waitObservations(
    NativeMediaSession& session, Predicate predicate,
    const char* message) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    if (!session.facts().observationPending) {
      std::this_thread::sleep_for(std::chrono::microseconds(50));
      continue;
    }
    NativeMediaSessionObservations observations =
        session.takeObservations();
    if (predicate(observations)) {
      return observations;
    }
    std::this_thread::sleep_for(std::chrono::microseconds(50));
  }
  fail(message);
}

template <typename Predicate>
void waitUntil(Predicate predicate, const char* message) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) {
      return;
    }
    std::this_thread::sleep_for(std::chrono::microseconds(50));
  }
  fail(message);
}

protocol::Prepare prepareCommand(double seconds = 0.5) {
  return {{{1}, {1}}, {1}, {7}, seconds};
}

NativeMediaSessionCommandStatus prepare(
    NativeMediaSession& session, protocol::Prepare command) {
  const auto preflight = NativeMediaSession::preflightInitialPosition(
      command.initialPositionSeconds);
  if (!preflight.has_value()) {
    return NativeMediaSessionCommandStatus::Invalid;
  }
  return session.prepare(command, *preflight);
}

void testObservationQueueRejectionRetriesWithoutPolling() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->observationRejectsRemaining.store(1, std::memory_order_release);
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "observation retry Prepare accepted");
  waitUntil(
      [&] {
        return state->observationQueueAttempts.load(
                   std::memory_order_acquire) >= 2 &&
               state->observationQueues.load(std::memory_order_acquire) >= 1;
      },
      "rejected observation queue is retried by the worker wake");
  const protocol::Prepared prepared = waitFact<protocol::Prepared>(
      *session, "retried observation retains exact Prepared fact");
  expect(prepared.stamp == prepareCommand().stamp,
         "observation retry preserves lifecycle lineage");
}

void testEveryWorkerWakeOwnsOneDrainedAutoreleasePool() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);

  constexpr std::uint64_t kWakeCount = 128;
  const NativeMediaSessionTestWorkerPoolFacts baseline =
      NativeMediaSessionTestAccess::workerPoolFacts(*session);
  expect(baseline.entered == baseline.drained && baseline.active == 0,
         "idle worker retains no autorelease pool between wakes");
  for (std::uint64_t wakeIndex = 1; wakeIndex <= kWakeCount; ++wakeIndex) {
    wake->video().signal(wake->video().context);
    const std::uint64_t expected = baseline.drained + wakeIndex;
    waitUntil(
        [&] {
          return NativeMediaSessionTestAccess::workerPoolFacts(*session)
                     .drained >= expected;
        },
        "each explicit worker wake drains its autorelease pool");
    const NativeMediaSessionTestWorkerPoolFacts facts =
        NativeMediaSessionTestAccess::workerPoolFacts(*session);
    expect(facts.entered == expected && facts.drained == expected &&
               facts.active == 0 && facts.peakActive == 1,
           "worker wakes use distinct non-overlapping autorelease pools");
  }
}

protocol::Stop stopCommand(std::uint64_t serial = 2) {
  return {{{1}, {serial}}, {9}};
}

protocol::CommitSeek commitCommand(std::uint64_t serial = 3,
                                   std::uint64_t targetGeneration = 8,
                                   double seconds = 2.0) {
  return {{{1}, {serial}}, {7}, {targetGeneration}, {1}, {1}, seconds};
}

void prepareStartedPausedForPreview(NativeMediaSession& session) {
  expect(prepare(session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "preview completion race Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      session, "preview completion race Prepared"));
  expect(session.start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "preview completion race Start accepted");
  static_cast<void>(waitFact<protocol::Started>(
      session, "preview completion race Started"));
  expect(session.setRunState({{{1}, {3}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "preview completion race pause accepted");
  static_cast<void>(waitFact<NativeMediaSessionRunStateApplied>(
      session, "preview completion race pause applied"));
}

enum class PreviewRaceOutcome : std::uint8_t {
  Success,
  FailureOrEmpty,
};

void runStopAfterPreviewChildReturn(
    NativeMediaSessionTestPreviewCompletionPoint point,
    PreviewRaceOutcome outcome) {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  installExactAssetContext(*state);
  if (outcome == PreviewRaceOutcome::FailureOrEmpty) {
    switch (point) {
    case NativeMediaSessionTestPreviewCompletionPoint::Quiesce:
      state->failPreviewQuiesce.store(true, std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::Construction:
      state->failPreviewConstruction.store(true,
                                           std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::Request:
      state->failPreviewRequest.store(true, std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::Pump:
      state->failPreviewPump.store(true, std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::TakePresented:
      state->dropPreviewPresentation.store(true,
                                           std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::None:
      fail("preview completion race requires a concrete point");
    }
  }
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  prepareStartedPausedForPreview(*session);

  const bool needsRequest =
      point == NativeMediaSessionTestPreviewCompletionPoint::Request ||
      point == NativeMediaSessionTestPreviewCompletionPoint::Pump ||
      point == NativeMediaSessionTestPreviewCompletionPoint::TakePresented;
  if (needsRequest) {
    expect(session->preparePreviewHandoff() ==
               NativeMediaSessionCommandStatus::Accepted,
           "preview child race prewarm accepted");
    waitUntil([&] { return session->facts().previewHandoffReady; },
              "preview child race prewarm becomes ready");
  }

  std::atomic<bool> completionEntered{false};
  std::atomic<bool> completionRelease{false};
  NativeMediaSessionTestAccess::installPreviewCompletionBarrier(
      *session, point, &completionEntered, &completionRelease);
  if (needsRequest) {
    auto target = session->preflightPreviewTarget(2.0);
    expect(target.has_value() &&
               session->previewFrame(
                   {{{1}, {4}}, {7}, {81}, {1}, 2.0},
                   std::move(*target)) ==
                   NativePreviewFrameRequestStatus::Accepted,
           "preview child race frame accepted");
  } else {
    expect(session->preparePreviewHandoff() ==
               NativeMediaSessionCommandStatus::Accepted,
           "preview child race handoff accepted");
  }
  waitUntil(
      [&] { return completionEntered.load(std::memory_order_acquire); },
      "preview child returns before its completion transaction");
  expect(session->stop(stopCommand(needsRequest ? 5 : 4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop wins after preview child return");
  completionRelease.store(true, std::memory_order_release);
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "preview child completion cannot defeat Stop"));
  const NativeMediaSessionFacts facts = session->facts();
  const NativeMediaSessionObservations observations =
      session->takeObservations();
  expect(!facts.previewHandoffPending && !facts.previewHandoffReady &&
             !facts.previewPending && !facts.previewPresentedPending &&
             !facts.previewFailedPending && !facts.liveFailed &&
             !observations.previewPresented.has_value() &&
             !observations.previewFailed.has_value(),
         "late preview child result cannot resurrect state after Stop");
}

void testStopWinsEveryPreviewChildCompletion() {
  const NativeMediaSessionTestPreviewCompletionPoint points[] = {
      NativeMediaSessionTestPreviewCompletionPoint::Quiesce,
      NativeMediaSessionTestPreviewCompletionPoint::Construction,
      NativeMediaSessionTestPreviewCompletionPoint::Request,
      NativeMediaSessionTestPreviewCompletionPoint::Pump,
      NativeMediaSessionTestPreviewCompletionPoint::TakePresented,
  };
  for (const auto point : points) {
    runStopAfterPreviewChildReturn(point, PreviewRaceOutcome::Success);
    runStopAfterPreviewChildReturn(point,
                                   PreviewRaceOutcome::FailureOrEmpty);
  }
}

void testCommitWinsAfterPresentedChildReturn() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  installExactAssetContext(*state);
  auto session = sessionFor(&state);
  prepareStartedPausedForPreview(*session);
  const auto commitTarget = session->preflightCommitTarget(3.0);
  expect(commitTarget.has_value() &&
             session->preparePreviewHandoff() ==
                 NativeMediaSessionCommandStatus::Accepted,
         "preview/commit completion target and prewarm accepted");
  waitUntil([&] { return session->facts().previewHandoffReady; },
            "preview/commit completion prewarm ready");
  std::atomic<bool> completionEntered{false};
  std::atomic<bool> completionRelease{false};
  NativeMediaSessionTestAccess::installPreviewCompletionBarrier(
      *session, NativeMediaSessionTestPreviewCompletionPoint::TakePresented,
      &completionEntered, &completionRelease);
  auto previewTarget = session->preflightPreviewTarget(2.0);
  expect(previewTarget.has_value() &&
             session->previewFrame(
                 {{{1}, {4}}, {7}, {91}, {1}, 2.0},
                 std::move(*previewTarget)) ==
                 NativePreviewFrameRequestStatus::Accepted,
         "preview/commit completion frame accepted");
  waitUntil(
      [&] { return completionEntered.load(std::memory_order_acquire); },
      "presented child returns before commit completion transaction");
  const protocol::CommitSeek commit = {
      {{1}, {5}}, {7}, {8}, {91}, {2}, 3.0};
  expect(session->commitSeek(commit, *commitTarget) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Commit wins after presented child return");
  completionRelease.store(true, std::memory_order_release);
  waitUntil([&] {
    return state->sourceSeeks.load(std::memory_order_acquire) == 1;
  }, "Commit progresses without a resurrected preview");
  expect(!session->facts().previewPresentedPending &&
             !session->takeObservations().previewPresented.has_value(),
         "late presented completion cannot escape accepted Commit");
  expect(session->stop({{{1}, {6}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "preview/commit race fixture Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "preview/commit race fixture retires"));
}

void testPreviewHandoffPrewarmsBeforeFirstMotion() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  installExactAssetContext(*state);
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "preview prewarm Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "preview prewarm Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "preview prewarm Start accepted");
  static_cast<void>(waitFact<protocol::Started>(
      *session, "preview prewarm Started"));

  const std::uint64_t pauseCallsBefore =
      state->pauseCalls.load(std::memory_order_acquire);
  expect(session->setRunState({{{1}, {3}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "begin-scrub physical pause is published before preview prewarm");
  const NativeMediaSessionCommandStatus handoffStatus =
      session->preparePreviewHandoff();
  const NativeMediaSessionFacts handoffFacts = session->facts();
  expect(handoffStatus == NativeMediaSessionCommandStatus::Accepted &&
             (handoffFacts.previewHandoffPending ||
              handoffFacts.previewHandoffReady),
         "begin-scrub preview handoff publishes one worker command");
  waitUntil(
      [&] {
        const NativeMediaSessionFacts facts = session->facts();
        return facts.previewHandoffReady &&
               state->previewQuiesces.load(std::memory_order_acquire) == 1;
      },
      "begin-scrub handoff quiesces main video and prepares preview lane");
  expect(state->previewBindingObservations.load(
             std::memory_order_acquire) == 1 &&
             state->previewBindingExact.load(std::memory_order_acquire) &&
             state->previewRequests.load(std::memory_order_acquire) == 0 &&
             state->previewPumps.load(std::memory_order_acquire) == 0 &&
             state->pauseCalls.load(std::memory_order_acquire) ==
                 pauseCallsBefore + 1 &&
             state->firstPreviewPauseOrder.load(
                 std::memory_order_acquire) <
                 state->firstPreviewQuiesceOrder.load(
                     std::memory_order_acquire) &&
             session->facts().generation == 7 &&
             session->takeObservations().previewPresented == std::nullopt,
         "handoff carries the exact retained main asset context, adds no "
         "audio mutation beyond pause, and changes neither generation nor "
         "preview visibility");
  expect(session->preparePreviewHandoff() ==
             NativeMediaSessionCommandStatus::Ignored,
         "duplicate begin-scrub prewarm is idempotent");

  auto target = session->preflightPreviewTarget(2.0);
  expect(target.has_value(), "first post-prewarm preview target preflights");
  expect(session->previewFrame(
             {{{1}, {4}}, {7}, {21}, {1}, 2.0}, std::move(*target)) ==
             NativePreviewFrameRequestStatus::Accepted,
         "first post-prewarm PreviewFrame is accepted");
  const NativeMediaSessionObservations presented = waitObservations(
      *session,
      [](const NativeMediaSessionObservations& value) {
        return value.previewPresented.has_value();
      },
      "first post-prewarm PreviewFrame presents");
  expect(presented.previewPresented->gesture == protocol::GestureId{21} &&
             presented.previewPresented->request == protocol::RequestId{1} &&
             state->previewQuiesces.load(std::memory_order_acquire) == 1 &&
             state->firstPreviewQuiesceOrder.load(
                 std::memory_order_acquire) != 0 &&
             state->firstPreviewQuiesceOrder.load(
                 std::memory_order_acquire) <
                 state->firstPreviewRequestOrder.load(
                     std::memory_order_acquire),
         "first motion reuses completed handoff instead of paying it again");
  expect(session->stop(stopCommand(5)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "prewarmed preview Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "prewarmed preview Stop retires exactly"));
}

void testPreviewHandoffStopWinsQuiescingPrewarm() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->quiesceFirstPreview.store(true, std::memory_order_release);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "quiescing prewarm Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "quiescing prewarm Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "quiescing prewarm Start accepted");
  static_cast<void>(waitFact<protocol::Started>(
      *session, "quiescing prewarm Started"));
  expect(session->setRunState({{{1}, {3}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted &&
             session->preparePreviewHandoff() ==
                 NativeMediaSessionCommandStatus::Accepted,
         "quiescing preview handoff follows physical pause");
  waitUntil(
      [&] {
        return state->previewQuiesceEntered.load(std::memory_order_acquire);
      },
      "preview handoff reaches main consumer quiescence");
  expect(session->stop(stopCommand(4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop is accepted while begin-scrub prewarm is quiescing");
  state->releasePreviewQuiesce.store(true, std::memory_order_release);
  wake->video().signal(wake->video().context);
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "Stop wins quiescing preview handoff"));
  expect(state->previewRequests.load(std::memory_order_acquire) == 0 &&
             state->previewPumps.load(std::memory_order_acquire) == 0 &&
             state->sourceCloses.load(std::memory_order_acquire) == 1 &&
             !session->takeObservations().previewPresented.has_value(),
         "Stop retires without publishing or pumping a prewarmed preview");
}

void testStopWinsSuccessfulPreviewConstructionWindow() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction-race Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "construction-race Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction-race Start accepted");
  static_cast<void>(waitFact<protocol::Started>(
      *session, "construction-race Started"));
  expect(session->setRunState({{{1}, {3}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction-race physical pause accepted");
  std::atomic<bool> constructionEntered{false};
  std::atomic<bool> constructionRelease{false};
  NativeMediaSessionTestAccess::installPreviewConstructionBarrier(
      *session, &constructionEntered, &constructionRelease);
  expect(session->preparePreviewHandoff() ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction-race prewarm accepted");
  waitUntil(
      [&] { return constructionEntered.load(std::memory_order_acquire); },
      "preview lane construction succeeds before terminal recheck");
  auto previewTarget = session->preflightPreviewTarget(2.0);
  expect(previewTarget.has_value() &&
             session->previewFrame(
                 {{{1}, {4}}, {7}, {31}, {1}, 2.0},
                 std::move(*previewTarget)) ==
                 NativePreviewFrameRequestStatus::Accepted,
         "first motion becomes pending during preview construction");
  expect(session->stop(stopCommand(5)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop linearizes during successful preview construction");
  constructionRelease.store(true, std::memory_order_release);
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "post-construction recheck gives Stop precedence"));
  const NativeMediaSessionFacts facts = session->facts();
  expect(!facts.previewHandoffPending && !facts.previewHandoffReady &&
             !facts.previewPending && !facts.previewPresentedPending &&
             state->previewRequests.load(std::memory_order_acquire) == 0,
         "successful construction cannot resurrect preview after Stop");
}

void testCommitWinsSuccessfulPreviewConstructionWindow() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction/commit Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "construction/commit Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction/commit Start accepted");
  static_cast<void>(waitFact<protocol::Started>(
      *session, "construction/commit Started"));
  expect(session->setRunState({{{1}, {3}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction/commit physical pause accepted");
  const auto target = session->preflightCommitTarget(2.0);
  auto previewTarget = session->preflightPreviewTarget(1.5);
  expect(target.has_value() && previewTarget.has_value(),
         "construction/commit targets preflight");
  std::atomic<bool> constructionEntered{false};
  std::atomic<bool> constructionRelease{false};
  NativeMediaSessionTestAccess::installPreviewConstructionBarrier(
      *session, &constructionEntered, &constructionRelease);
  expect(session->preparePreviewHandoff() ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction/commit prewarm accepted");
  waitUntil(
      [&] { return constructionEntered.load(std::memory_order_acquire); },
      "construction/commit lane creation reaches terminal window");
  expect(session->previewFrame(
             {{{1}, {4}}, {7}, {31}, {1}, 1.5},
             std::move(*previewTarget)) ==
             NativePreviewFrameRequestStatus::Accepted,
         "construction/commit retains a pending first motion");
  const protocol::CommitSeek commit = {
      {{1}, {5}}, {7}, {8}, {31}, {2}, 2.0};
  expect(session->commitSeek(commit, *target) ==
             NativeMediaSessionCommandStatus::Accepted,
         "CommitSeek linearizes during successful preview construction");
  constructionRelease.store(true, std::memory_order_release);
  waitUntil(
      [&] {
        return state->sourceSeeks.load(std::memory_order_acquire) == 1;
      },
      "post-construction recheck stops preview before exact seek");
  const NativeMediaSessionFacts facts = session->facts();
  expect(facts.commitPending && !facts.previewHandoffPending &&
             !facts.previewHandoffReady && !facts.previewPending &&
             !facts.previewPresentedPending &&
             state->previewRequests.load(std::memory_order_acquire) == 0 &&
             state->previewStops.load(std::memory_order_acquire) != 0,
         "successful construction cannot issue preview after CommitSeek");
  expect(session->stop({{{1}, {6}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "construction/commit fixture Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "construction/commit fixture retires exactly"));
}

void testPreviewLatestWinsAndStopQuiescesLane() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "preview fixture Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "preview fixture Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "preview fixture Start accepted");
  static_cast<void>(waitFact<protocol::Started>(
      *session, "preview fixture Started"));

  std::atomic<bool> pulledFirstPreview{false};
  std::atomic<bool> releaseFirstPreview{false};
  NativeMediaSessionTestAccess::installPreviewPullBarrier(
      *session, &pulledFirstPreview, &releaseFirstPreview);
  auto firstTarget = session->preflightPreviewTarget(2.0);
  expect(firstTarget.has_value(), "first preview target preflights");
  expect(session->previewFrame(
             {{{1}, {3}}, {7}, {11}, {1}, 2.0},
             std::move(*firstTarget)) ==
             NativePreviewFrameRequestStatus::Accepted,
         "first preview request accepted");
  waitUntil([&] { return pulledFirstPreview.load(std::memory_order_acquire); },
            "worker pulls preview A before preview B is accepted");
  auto latestTarget = session->preflightPreviewTarget(3.0);
  expect(latestTarget.has_value(), "latest preview target preflights");
  expect(session->previewFrame(
             {{{1}, {4}}, {7}, {11}, {2}, 3.0},
             std::move(*latestTarget)) ==
             NativePreviewFrameRequestStatus::Replaced,
         "same-gesture preview replaces capacity-one request");
  releaseFirstPreview.store(true, std::memory_order_release);

  const NativeMediaSessionObservations observations = waitObservations(
      *session,
      [](const NativeMediaSessionObservations& value) {
        return value.previewPresented.has_value() &&
               value.previewPresented->stamp == protocol::Stamp{{1}, {4}};
      },
      "latest exact preview draw is published");
  expect(observations.previewPresented->request == protocol::RequestId{2} &&
             observations.previewPresented->actualPresentationTimeSeconds ==
                 3.0,
         "preview observation preserves latest exact identity and timing");
  expect(state->previewQuiesces.load(std::memory_order_acquire) != 0,
         "main video is quiesced before preview pumping");
  expect(state->previewRequests.load(std::memory_order_acquire) == 2 &&
             !session->facts().liveFailed,
         "pull-A/accept-B issues both without a false self-stale failure");

  expect(session->stop(stopCommand(5)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop after preview accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "Stop after preview publishes exact retirement"));
  expect(state->previewStops.load(std::memory_order_acquire) != 0,
         "Stop fully stops preview lane before main retirement");
}

void testAcceptedPreviewFailuresPublishExactTerminal() {
  struct FailureCase {
    NativeMediaSessionTestPreviewCompletionPoint point;
    const char* label;
  };
  const FailureCase cases[] = {
      {NativeMediaSessionTestPreviewCompletionPoint::Quiesce, "quiesce"},
      {NativeMediaSessionTestPreviewCompletionPoint::Construction,
       "construction"},
      {NativeMediaSessionTestPreviewCompletionPoint::Request, "request"},
      {NativeMediaSessionTestPreviewCompletionPoint::Pump, "pump"},
  };

  for (const FailureCase failure : cases) {
    auto state = std::make_shared<GraphState>();
    state->descriptor = descriptor();
    installExactAssetContext(*state);
    auto session = sessionFor(&state);
    prepareStartedPausedForPreview(*session);

    const bool prewarm =
        failure.point == NativeMediaSessionTestPreviewCompletionPoint::Request ||
        failure.point == NativeMediaSessionTestPreviewCompletionPoint::Pump;
    if (prewarm) {
      expect(session->preparePreviewHandoff() ==
                 NativeMediaSessionCommandStatus::Accepted,
             "preview-failure prewarm accepted");
      waitUntil([&] { return session->facts().previewHandoffReady; },
                "preview-failure prewarm reaches Ready");
    }

    switch (failure.point) {
    case NativeMediaSessionTestPreviewCompletionPoint::Quiesce:
      state->failPreviewQuiesce.store(true, std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::Construction:
      state->failPreviewConstruction.store(true, std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::Request:
      state->failPreviewRequest.store(true, std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::Pump:
      state->failPreviewPump.store(true, std::memory_order_release);
      break;
    case NativeMediaSessionTestPreviewCompletionPoint::TakePresented:
    case NativeMediaSessionTestPreviewCompletionPoint::None:
      fail("exact preview-failure case is invalid");
    }

    auto target = session->preflightPreviewTarget(2.0);
    auto refusedTarget = session->preflightPreviewTarget(3.0);
    const protocol::PreviewFrame preview = {
        {{1}, {4}}, {7}, {91}, {1}, 2.0};
    expect(target.has_value() && refusedTarget.has_value() &&
               session->previewFrame(preview, std::move(*target)) ==
                   NativePreviewFrameRequestStatus::Accepted,
           failure.label);
    const NativeMediaSessionObservations observations = waitObservations(
        *session,
        [](const NativeMediaSessionObservations& value) {
          return value.previewFailed.has_value();
        },
        "accepted preview failure publishes a terminal observation");
    expect(observations.previewFailed.has_value() &&
               protocol::previewFailedMatches(preview,
                                              *observations.previewFailed) &&
               !observations.previewPresented.has_value() &&
               !session->facts().previewPending &&
               !session->facts().liveFailed,
           "preview failure echoes exact identity without failing playback");
    expect(session->previewFrame(
               {{{1}, {5}}, {7}, {91}, {2}, 3.0},
               std::move(*refusedTarget)) ==
               NativePreviewFrameRequestStatus::Failed,
           "a failed preview lane refuses later work synchronously");
    expect(session->stop(stopCommand(5)) ==
               NativeMediaSessionCommandStatus::Accepted,
           "preview-failure fixture accepts exact Stop");
    static_cast<void>(waitFact<protocol::Stopped>(
        *session, "preview-failure fixture retires exactly"));
  }
}

void testPreviewFailureNamesLatestPublicReplacement() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  installExactAssetContext(*state);
  auto session = sessionFor(&state);
  prepareStartedPausedForPreview(*session);
  expect(session->preparePreviewHandoff() ==
             NativeMediaSessionCommandStatus::Accepted,
         "replacement-failure prewarm accepted");
  waitUntil([&] { return session->facts().previewHandoffReady; },
            "replacement-failure prewarm reaches Ready");

  state->failPreviewPump.store(true, std::memory_order_release);
  std::atomic<bool> failureEntered{false};
  std::atomic<bool> failureRelease{false};
  NativeMediaSessionTestAccess::installPreviewCompletionBarrier(
      *session, NativeMediaSessionTestPreviewCompletionPoint::Pump,
      &failureEntered, &failureRelease);
  auto firstTarget = session->preflightPreviewTarget(2.0);
  const protocol::PreviewFrame first = {
      {{1}, {4}}, {7}, {101}, {1}, 2.0};
  expect(firstTarget.has_value() &&
             session->previewFrame(first, std::move(*firstTarget)) ==
                 NativePreviewFrameRequestStatus::Accepted,
         "replacement-failure A accepted");
  waitUntil([&] { return failureEntered.load(std::memory_order_acquire); },
            "replacement-failure A pump returns before completion");

  auto latestTarget = session->preflightPreviewTarget(3.0);
  const protocol::PreviewFrame latest = {
      {{1}, {5}}, {7}, {101}, {2}, 3.0};
  expect(latestTarget.has_value() &&
             session->previewFrame(latest, std::move(*latestTarget)) ==
                 NativePreviewFrameRequestStatus::Replaced,
         "replacement-failure B replaces A while A is failing");
  failureRelease.store(true, std::memory_order_release);

  const NativeMediaSessionObservations observations = waitObservations(
      *session,
      [](const NativeMediaSessionObservations& value) {
        return value.previewFailed.has_value();
      },
      "replacement-failure publishes one latest terminal");
  expect(observations.previewFailed.has_value() &&
             protocol::previewFailedMatches(latest,
                                            *observations.previewFailed) &&
             !protocol::previewFailedMatches(first,
                                             *observations.previewFailed) &&
             !observations.previewPresented.has_value(),
         "failure clears active A and queued B under B's public identity");
  expect(session->stop(stopCommand(6)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "replacement-failure fixture Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "replacement-failure fixture retires"));
}

void testCommitBurnsQueuedPreviewFailure() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  installExactAssetContext(*state);
  auto session = sessionFor(&state);
  prepareStartedPausedForPreview(*session);
  expect(session->preparePreviewHandoff() ==
             NativeMediaSessionCommandStatus::Accepted,
         "queued-failure Commit prewarm accepted");
  waitUntil([&] { return session->facts().previewHandoffReady; },
            "queued-failure Commit prewarm reaches Ready");

  auto previewTarget = session->preflightPreviewTarget(2.0);
  auto commitTarget = session->preflightCommitTarget(3.0);
  const protocol::PreviewFrame preview = {
      {{1}, {4}}, {7}, {111}, {1}, 2.0};
  state->failPreviewPump.store(true, std::memory_order_release);
  expect(previewTarget.has_value() && commitTarget.has_value() &&
             session->previewFrame(preview, std::move(*previewTarget)) ==
                 NativePreviewFrameRequestStatus::Accepted,
         "queued-failure Commit preview accepted");
  waitUntil([&] { return session->facts().previewFailedPending; },
            "preview failure remains queued before Commit");

  const protocol::CommitSeek commit = {
      {{1}, {5}}, {7}, {8}, {111}, {2}, 3.0};
  expect(session->commitSeek(commit, std::move(*commitTarget)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Commit follows and burns the queued preview failure");
  const NativeMediaSessionObservations observations =
      session->takeObservations();
  expect(!session->facts().previewFailedPending &&
             !observations.previewFailed.has_value() &&
             !observations.previewPresented.has_value(),
         "no preview terminal escapes after exact Commit admission");
  expect(session->stop({{{1}, {6}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "queued-failure Commit fixture Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "queued-failure Commit fixture retires"));
}

void publishCommitDraw(GraphState& state, std::uint64_t generation,
                       std::uint64_t sequence, double seconds) {
  std::lock_guard lock(state.videoEventMutex);
  NativeTrackedVideoEvent event;
  event.kind = NativeTrackedVideoEventKind::FrameDrawn;
  event.generation = generation;
  event.eventSequence = sequence;
  event.timing.generation = generation;
  event.timing.presentationTime = CMTimeMakeWithSeconds(seconds, 600);
  event.timing.duration = CMTimeMake(20, 600);
  state.videoEvent = event;
}

void expectExactCommitLifecycle(
    const std::vector<CommitLifecycleEvent>& events,
    const char* message) {
  const std::vector<CommitLifecycleEvent> expected = {
      CommitLifecycleEvent::SourceSeek,
      CommitLifecycleEvent::AudioFlush,
      CommitLifecycleEvent::AudioStart,
      CommitLifecycleEvent::TargetPause,
      CommitLifecycleEvent::ClockProof,
      CommitLifecycleEvent::VideoProof,
  };
  if (events != expected) {
    std::cerr << "commit lifecycle:";
    for (const CommitLifecycleEvent event : events) {
      std::cerr << ' ' << static_cast<unsigned>(event);
    }
    std::cerr << '\n';
    fail(message);
  }
}

void testCommitSeekPendingReadyAndStopHighWater() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->blockCapacity.store(true);
  state->quiesceFirstVideoFlush.store(true);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "commit Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(*session,
                                                  "commit Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "commit Start accepted");
  static_cast<void>(waitFact<protocol::Started>(*session, "commit Started"));

  const auto target = session->preflightCommitTarget(2.0);
  expect(target.has_value() && target->drawBaseline() == 0,
         "session reserves exact pre-commit physical draw baseline");
  const protocol::CommitSeek commit = commitCommand();
  state->beginCommitLifecycle(commit.targetGeneration.value);
  expect(session->commitSeek(commit, *target) ==
             NativeMediaSessionCommandStatus::Accepted,
         "exact CommitSeek accepted");
  waitUntil([&] { return state->sourceSeeks.load() == 1; },
            "CommitSeek calls source exactly once while flush is pending");
  expect(session->facts().generationHighWater == 8 &&
             session->facts().commitPending,
         "accepted commit immediately burns target high-water");
  wake->video().signal(wake->video().context);
  publishCommitDraw(*state, 8, 1, 2.0);
  wake->video().signal(wake->video().context);
  const protocol::CommitReady ready = waitFact<protocol::CommitReady>(
      *session, "commit publishes exact clock/draw readiness");
  expect(protocol::commitReadyMatches(commit, target->drawBaseline(), ready) &&
             session->facts().generation == 8 &&
             state->sourceSeeks.load() == 1 &&
             state->audioPhysicallyStarted.load(std::memory_order_acquire) &&
             state->audioStartedGeneration.load(std::memory_order_acquire) ==
                 8,
         "commit readiness advances generation with target audio started");
  expectExactCommitLifecycle(
      state->finishCommitLifecycle(),
      "ordinary commit flushes before one target start, then pause and proofs");
  expect(session->setRunState({{{1}, {4}}, {8}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "post-commit run state addresses the active target generation");
  static_cast<void>(waitFact<NativeMediaSessionRunStateApplied>(
      *session, "post-commit run state acknowledges target generation"));
  publishCommitDraw(*state, 8, 2, 2.0);
  wake->video().signal(wake->video().context);
  const NativeMediaSessionObservations postCommitDraw = waitObservations(
      *session,
      [](const NativeMediaSessionObservations& observations) {
        return observations.videoDraw.has_value();
      },
      "post-commit general draw proof uses active generation");
  expect(postCommitDraw.videoDraw->generation == protocol::Generation{8},
         "post-commit draw proof never regresses to reserved generation");
  expect(session->stop({{{1}, {5}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop strictly above committed target accepted");
  static_cast<void>(waitFact<protocol::Stopped>(*session,
                                                 "commit Stop retires"));
}

// A preview lane that has latched a failure answers its terminal stop with
// Failed. That lane holds nothing the commit needs -- the commit flush IS the
// recovery -- so the commit must proceed to readiness rather than publish a
// CommitSeek failure and leave the transport dead.
void testCommitSeekProceedsPastFailedPreviewLane() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->blockCapacity.store(true);
  state->quiesceFirstVideoFlush.store(true);
  state->previewStopFails.store(true);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "failed-lane commit Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "failed-lane commit Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "failed-lane commit Start accepted");
  static_cast<void>(waitFact<protocol::Started>(
      *session, "failed-lane commit Started"));

  const auto target = session->preflightCommitTarget(2.0);
  expect(target.has_value(), "failed-lane commit target preflights");
  const protocol::CommitSeek commit = commitCommand();
  state->beginCommitLifecycle(commit.targetGeneration.value);
  expect(session->commitSeek(commit, *target) ==
             NativeMediaSessionCommandStatus::Accepted,
         "failed-lane CommitSeek accepted");
  waitUntil([&] { return state->sourceSeeks.load() == 1; },
            "a failed preview lane does not veto the source seek");
  expect(state->previewStops.load(std::memory_order_acquire) != 0,
         "the terminal stop was asked of the failed lane");
  wake->video().signal(wake->video().context);
  publishCommitDraw(*state, 8, 1, 2.0);
  wake->video().signal(wake->video().context);
  const protocol::CommitReady ready = waitFact<protocol::CommitReady>(
      *session, "commit reaches readiness past a failed preview lane");
  expect(protocol::commitReadyMatches(commit, target->drawBaseline(), ready) &&
             session->facts().generation == 8,
         "readiness advances the generation past a failed preview lane");
  expect(session->stop({{{1}, {5}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop after a failed-lane commit accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "Stop after a failed-lane commit retires"));
}

void testCommitSeekAdmittedDuringStarting() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->blockCapacity.store(true);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Starting commit Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(*session,
                                                  "Starting commit Prepared"));
  const auto target = session->preflightCommitTarget(2.0);
  expect(target.has_value(),
         "prepared session reserves commit target before Started");
  expect(session->commitSeek(commitCommand(3, 8, 2.0), *target) ==
             NativeMediaSessionCommandStatus::Accepted,
         "CommitSeek is admitted during Router NativeStarting reentrancy");
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "already-created Start is admitted below newer CommitSeek lineage");
  publishCommitDraw(*state, 8, 1, 2.0);
  wake->video().signal(wake->video().context);
  static_cast<void>(waitFact<protocol::CommitReady>(
      *session, "Starting commit reaches exact readiness without Start"));
  expect(state->sourceSeeks.load() == 1,
         "Starting commit issues exactly one source seek");
  expect(session->stop({{{1}, {4}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Starting commit target retires exactly");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "Starting commit stopped proof"));
}

void testExactTimeAndSequencing() {
  const auto halfSecond =
      NativeMediaSession::preflightInitialPosition(0.5);
  expect(halfSecond.has_value() &&
             halfSecond->exact() == media::MediaTime{1, 2} &&
             !NativeMediaSession::preflightInitialPosition(0.1) &&
             !NativeMediaSession::preflightInitialPosition(
                 std::numeric_limits<double>::quiet_NaN()),
         "public initial-position preflight is the exact shared conversion");

  auto unboundState = std::make_shared<GraphState>();
  unboundState->descriptor = descriptor();
  auto unbound = sessionFor(&unboundState, nullptr, false);
  expect(prepare(*unbound, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Invalid &&
             unboundState->factoryCalls.load() == 0,
         "Prepare requires a retained outbound observation edge");
  expect(unbound->bindObservationEdge(
             {std::make_shared<int>(1), &queueObservations,
              unboundState.get()}),
         "observation edge binds exactly once before Prepare");

  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand(0.1)) ==
             NativeMediaSessionCommandStatus::Invalid,
         "unrepresentable exact binary64 time fails before graph creation");
  expect(state->factoryCalls.load() == 0,
         "failed exact time preflight creates no resource");
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "exact half-second prepare is accepted");
  waitUntil(
      [&] {
        return state->observationQueues.load(std::memory_order_acquire) != 0;
      },
      "lifecycle publication requests queued controller observation");
  {
    std::lock_guard lock(state->observationMutex);
    expect(!state->queuedObservationTickets.empty(),
           "queued controller work retains its lifetime ticket");
  }
  const protocol::Prepared prepared =
      waitFact<protocol::Prepared>(*session, "expected Prepared fact");
  expect(prepared.stamp == protocol::Stamp{{1}, {1}} &&
             prepared.generation == protocol::Generation{7},
         "Prepared echoes exact command stamp and generation");
  expect(session->start({{{2}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Invalid,
         "wrong-attempt Start is rejected");
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "following Start is accepted");
  const protocol::Started started =
      waitFact<protocol::Started>(*session, "expected Started fact");
  expect(started.stamp == protocol::Stamp{{1}, {2}},
         "Started echoes exact Start stamp");
  expect(session->setRunState({{{2}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Invalid,
         "wrong-attempt run state is rejected");
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "following run state is accepted");
  waitUntil(
      [&] {
        return session->facts().appliedRunStateStamp ==
               protocol::Stamp{{1}, {3}};
      },
      "run-state application becomes observable");
  expect(session->stop(stopCommand(4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "following Stop is accepted");
  const protocol::Stopped stopped =
      waitFact<protocol::Stopped>(*session, "expected Stopped fact");
  expect(stopped.stamp == protocol::Stamp{{1}, {4}} &&
             stopped.invalidationGeneration == protocol::Generation{9},
         "Stopped echoes exact Stop pair");
}

void testUnobservedDirectRetireBarrier() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->openStatus = media::MediaSourceOpenStatus::Unsupported;
  state->quiesceFirstVideoRetire.store(true);
  state->blockFirstVideoRetire.store(true, std::memory_order_release);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "unsupported fixture accepts Prepare command");
  const protocol::Failed failed =
      waitFact<protocol::Failed>(*session, "expected post-prearm failure");
  expect(failed.reason == protocol::FailureReason::Startup,
         "post-prearm Unsupported is Startup, never UnsupportedSource");
  expect(state->videoConfigures.load() == 0 &&
             state->audioConfigures.load() == 0,
         "source Unsupported exposes no dispatcher configure");
  expect(session->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "unobserved Stop accepted");
  waitUntil([&] { return state->videoRetires.load() == 1; },
            "first video retirement reaches Quiescing");
  expect(state->audioRetires.load() == 0 && state->sourceCloses.load() == 0,
         "Quiescing video blocks audio retirement and dispatcher close");
  state->releaseFirstVideoRetire.store(true, std::memory_order_release);
  wake->video().signal(wake->video().context);
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "expected direct Stopped proof"));
  expect(state->videoPair == std::pair<media::MediaGeneration,
                                      media::MediaGeneration>{7, 9} &&
             state->audioPair == std::pair<media::MediaGeneration,
                                      media::MediaGeneration>{0, 9},
         "direct barrier exact-retires prearmed video and fresh audio");
  expect(state->sourceCloseOrder.load() > state->videoRetireOrder.load() &&
             state->sourceCloseOrder.load() >
                 state->audioRetireOrder.load(),
         "dispatcher emergency close follows both direct retire proofs");
  const NativeMediaSessionFacts facts = session->facts();
  expect(!facts.dispatcherObservedVideo && facts.directVideoRetired &&
             facts.directAudioRetired,
         "unobserved phase is explicit in public facts");
}

void testObservedUsesDispatcherRetireOnly() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "observed fixture accepts Prepare");
  static_cast<void>(
      waitFact<protocol::Prepared>(*session, "expected observed Prepared"));
  expect(state->videoConfigures.load() == 1 &&
             state->audioConfigures.load() == 1,
         "dispatcher observed both configure calls");
  expect(session->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "observed Stop accepted");
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "expected observed Stopped"));
  expect(state->videoRetires.load() == 1 &&
             state->audioRetires.load() == 1 &&
             state->videoPair == std::pair<media::MediaGeneration,
                                          media::MediaGeneration>{7, 9} &&
             state->audioPair == std::pair<media::MediaGeneration,
                                          media::MediaGeneration>{7, 9},
         "dispatcher alone supplies both observed retire pairs");
  expect(state->sourceCloseOrder.load() < state->videoRetireOrder.load() &&
             state->sourceCloseOrder.load() <
                 state->audioRetireOrder.load(),
         "dispatcher closes source before observed consumer retirement");
  const NativeMediaSessionFacts facts = session->facts();
  expect(facts.dispatcherObservedVideo && !facts.directVideoRetired &&
             !facts.directAudioRetired,
         "observed phase never records direct retirement");
}

void testAdmissionGateBeforeConfigure() {
  auto state = std::make_shared<GraphState>();
  // 2026-08-27: the shortfall bound widened from 250 ms to 5 s now that the
  // clock advances across container-declared trailing silence, so a 5 s audio
  // track under a 10 s video sits exactly AT the bound and is admitted. This
  // fixture must state a shortfall the widened bound still refuses, or it stops
  // exercising the duration gate at all. 3 s of audio under 10 s of video is a
  // 7 s shortfall: content that genuinely does not cover its video.
  state->descriptor = descriptor({3, 1});
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "short-audio fixture accepts command");
  const protocol::Failed failed =
      waitFact<protocol::Failed>(*session, "expected duration-gate failure");
  expect(failed.reason == protocol::FailureReason::Startup,
         "post-prearm duration rejection requires Stop");
  expect(state->videoConfigures.load() == 0 &&
             state->audioConfigures.load() == 0,
         "A/V duration gate precedes dispatcher configure");
  expect(session->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "duration rejection Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "duration rejection retires exactly"));
}

void testTerminalFailuresLatchAllLiveControls() {
  auto prepareState = std::make_shared<GraphState>();
  prepareState->descriptor = descriptor();
  prepareState->openStatus = media::MediaSourceOpenStatus::Failed;
  auto prepareSession = sessionFor(&prepareState);
  expect(prepare(*prepareSession, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "failure latch Prepare accepted");
  static_cast<void>(waitFact<protocol::Failed>(
      *prepareSession, "prepare failure publishes"));
  expect(prepareSession->facts().liveFailed &&
             prepareSession->start({{{1}, {2}}, {7}, true}) ==
                 NativeMediaSessionCommandStatus::Ignored &&
             prepareSession->setGain(0.2F) ==
                 NativeMediaSessionCommandStatus::Ignored &&
             prepareSession->setMuted(true) ==
                 NativeMediaSessionCommandStatus::Ignored,
         "prepare/runtime Failed atomically burns every live control");
  expect(prepareSession->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "failed Prepare still exact-retires exposed resources");
  static_cast<void>(waitFact<protocol::Stopped>(
      *prepareSession, "failed Prepare Stopped"));

  auto startState = std::make_shared<GraphState>();
  startState->descriptor = descriptor();
  startState->failStart.store(true, std::memory_order_release);
  auto startSession = sessionFor(&startState);
  expect(prepare(*startSession, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "start failure Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *startSession, "start failure Prepared"));
  expect(startSession->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "failing Start accepted");
  static_cast<void>(waitFact<protocol::Failed>(
      *startSession, "Start failure publishes"));
  expect(startSession->facts().liveFailed &&
             startSession->setRunState(
                 {{{1}, {3}}, {7}, false, 1.0}) ==
                 NativeMediaSessionCommandStatus::Ignored,
         "startup Failed latches before later run control");
  expect(startSession->stop(stopCommand(3)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "failed Start still exact-retires");
  static_cast<void>(waitFact<protocol::Stopped>(
      *startSession, "failed Start Stopped"));
}

void testCancelBeforeSourceArmAndMailboxPrecedence() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->blockVideoArm.store(true);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "blocked-arm Prepare accepted");
  waitUntil([&] { return state->videoArms.load() != 0; },
            "video prearm reaches deterministic barrier");
  expect(session->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop wins while prearm quiesces");
  state->releaseVideoArm.store(true);
  wake->video().signal(wake->video().context);
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "prearm Stop retires"));
  expect(state->sourceArms.load() == 0 && state->sourceOpens.load() == 0,
         "cancel-before-arm latch prevents source operation entry");

  auto factoryRaceState = std::make_shared<GraphState>();
  factoryRaceState->descriptor = descriptor();
  factoryRaceState->blockFactory.store(true);
  auto factoryRaceSession = sessionFor(&factoryRaceState);
  expect(prepare(*factoryRaceSession, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "factory-race Prepare accepted");
  waitUntil([&] { return factoryRaceState->factoryEntered.load(); },
            "factory construction enters after worker snapshot");
  expect(factoryRaceSession->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop wins while graph factory is active");
  factoryRaceState->releaseFactory.store(true);
  static_cast<void>(waitFact<protocol::Stopped>(
      *factoryRaceSession, "factory race reaches exact Stopped"));
  expect(factoryRaceState->videoArms.load() == 0 &&
             factoryRaceState->sourceArms.load() == 0,
         "post-snapshot Stop prevents video prearm and source arm");
  expect(factoryRaceState->videoPair ==
                 std::pair<media::MediaGeneration,
                           media::MediaGeneration>{0, 9} &&
             factoryRaceState->audioPair ==
                 std::pair<media::MediaGeneration,
                           media::MediaGeneration>{0, 9},
         "factory-created unexposed ports retire exactly before Stopped");

  auto armRaceState = std::make_shared<GraphState>();
  armRaceState->descriptor = descriptor();
  armRaceState->blockSourceArm.store(true);
  auto armRaceSession = sessionFor(&armRaceState);
  expect(prepare(*armRaceSession, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "source-arm race fixture accepts Prepare");
  waitUntil([&] { return armRaceState->sourceArmEntered.load(); },
            "source arm enters before operation publication");
  expect(armRaceSession->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop latches across source arm publication gap");
  armRaceState->releaseSourceArm.store(true);
  static_cast<void>(waitFact<protocol::Stopped>(
      *armRaceSession, "source-arm race reaches exact Stopped"));
  expect(armRaceState->sourceCancels.load() != 0 &&
             armRaceState->cancelledGeneration.load() == 7,
         "latched exact cancellation reaches the newly armed source");

  auto mailboxState = std::make_shared<GraphState>();
  mailboxState->descriptor = descriptor();
  auto mailboxSession = sessionFor(&mailboxState);
  expect(prepare(*mailboxSession, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "mailbox fixture accepts Prepare");
  waitUntil([&] { return mailboxSession->facts().factPending; },
            "Prepared occupies capacity-one mailbox");
  expect(mailboxSession->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop supersedes occupied live mailbox");
  const auto stopped = waitFact<protocol::Stopped>(
      *mailboxSession, "Stop proof replaces unconsumed live fact");
  expect(stopped.stamp == protocol::Stamp{{1}, {2}},
         "terminal mailbox preserves exact Stop stamp");
}

void testLateFailureCannotHideStop() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "late-failure fixture accepts Prepare");
  static_cast<void>(
      waitFact<protocol::Prepared>(*session, "late-failure Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "late-failure Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "late-failure Started"));
  state->blockPause.store(true);
  state->failPause.store(true);
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "blocking run state accepted");
  waitUntil([&] { return state->pauseEntered.load(); },
            "run state enters before Stop");
  expect(session->stop(stopCommand(4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop accepted while live operation is blocked");
  state->releasePause.store(true);
  const protocol::Stopped stopped = waitFact<protocol::Stopped>(
      *session, "late live Failed must not replace Stopped");
  expect(stopped.stamp == protocol::Stamp{{1}, {4}},
         "late-failure race retains exact Stop stamp");
  expect(session->facts().stoppedProofPublished,
         "public terminal snapshot precedes consumable Stopped fact");
}

void testRunIntentCoalescesAcrossQuiescing() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->quiesceFirstPause.store(true);
  state->blockPause.store(true, std::memory_order_release);
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "run-coalescing Prepare accepted");
  static_cast<void>(
      waitFact<protocol::Prepared>(*session, "run-coalescing Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "run-coalescing Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "run-coalescing Started"));
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "first run intent accepted");
  waitUntil([&] { return state->pauseEntered.load(std::memory_order_acquire); },
            "first run intent enters the exact audio callback");
  expect(session->setRunState({{{1}, {4}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "newer run intent replaces behind quiescing command");
  state->releasePause.store(true, std::memory_order_release);
  waitUntil(
      [&] {
        const NativeMediaSessionFacts facts = session->facts();
        return facts.appliedRunStateStamp == protocol::Stamp{{1}, {4}} &&
               facts.appliedPaused;
      },
      "newer queued run intent is self-rearmed and applied");
  const NativeMediaSessionRunStateApplied applied =
      waitFact<NativeMediaSessionRunStateApplied>(
          *session, "latest coalesced run acknowledgement is durable");
  expect(applied.command.stamp == protocol::Stamp{{1}, {4}} &&
             applied.command.paused && state->pauseCalls.load() == 2,
         "superseded A is never retried or acknowledged before B");
  const NativeMediaSessionFacts runFacts = session->facts();
  expect(runFacts.requestedRunStateStamp == protocol::Stamp{{1}, {4}} &&
             runFacts.issuedRunStateStamp == protocol::Stamp{{1}, {4}} &&
             runFacts.appliedRunStateStamp == protocol::Stamp{{1}, {4}},
         "requested, issued, and physical run stages converge on B");
  expect(session->stop(stopCommand(5)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "run-coalescing Stop accepted");
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "run-coalescing Stopped"));
}

void testWakeClearBeforeDrainPreservesLateRun() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "wake-race Prepare accepted");
  static_cast<void>(
      waitFact<protocol::Prepared>(*session, "wake-race Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "wake-race Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "wake-race Started"));

  std::atomic<bool> commandDrainDone{false};
  std::atomic<bool> releaseDrain{false};
  NativeMediaSessionTestAccess::installCommandDrainBarrier(
      *session, &commandDrainDone, &releaseDrain);
  // Wake an already-blocked pass. The barrier stops that pass after the wake
  // gates are clear and after its empty public-command drain has completed.
  wake->video().signal(wake->video().context);
  waitUntil([&] { return commandDrainDone.load(std::memory_order_acquire); },
            "worker clears wake gates and completes an empty command drain");
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "run B is accepted after the current command drain");
  releaseDrain.store(true, std::memory_order_release);

  const NativeMediaSessionRunStateApplied applied =
      waitFact<NativeMediaSessionRunStateApplied>(
          *session, "late run B owns a preserved follow-up wake");
  expect(applied.command.stamp == protocol::Stamp{{1}, {3}} &&
             !applied.command.paused &&
             state->pauseCalls.load(std::memory_order_acquire) == 1,
         "clear-before-drain handshake applies and acknowledges run B");
  expect(session->stop(stopCommand(4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "wake-race Stop accepted");
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "wake-race Stopped"));
}

void testWakeConsumeRaceAbsorbsRunIntoCurrentDrain() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "wake-consume Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "wake-consume Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "wake-consume Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "wake-consume Started"));

  std::atomic<bool> tokenConsumed{false};
  std::atomic<bool> releaseGateClear{false};
  NativeMediaSessionTestAccess::installWakeConsumeBarrier(
      *wake, &tokenConsumed, &releaseGateClear);
  wake->video().signal(wake->video().context);
  waitUntil([&] { return tokenConsumed.load(std::memory_order_acquire); },
            "worker consumes a token before clearing its wake gates");
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "run B publishes between token consume and gate exchange");
  releaseGateClear.store(true, std::memory_order_release);

  const NativeMediaSessionRunStateApplied applied =
      waitFact<NativeMediaSessionRunStateApplied>(
          *session, "consume-race run B is absorbed into the current drain");
  expect(applied.command.stamp == protocol::Stamp{{1}, {3}} &&
             !applied.command.paused &&
             state->pauseCalls.load(std::memory_order_acquire) == 1,
         "post-consume acquire applies and acknowledges run B");
  expect(session->stop(stopCommand(4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "wake-consume Stop accepted");
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "wake-consume Stopped"));
}

void testVideoDueHintArmsOnlyTheSharedAudioEdge() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "video-due fixture Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "video-due fixture Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "video-due fixture Start accepted");
  static_cast<void>(waitFact<protocol::Started>(
      *session, "video-due fixture Started"));

  state->videoDueHostTicks.store(42'000, std::memory_order_release);
  wake->video().signal(wake->video().context);
  waitUntil(
      [&] {
        return NativeMediaSessionTestAccess::videoDueHostTicks(*wake) ==
               42'000;
      },
      "worker publishes the exact future video deadline to AudioUnit");

  state->videoDueHostTicks.store(0, std::memory_order_release);
  wake->video().signal(wake->video().context);
  waitUntil(
      [&] {
        return NativeMediaSessionTestAccess::videoDueHostTicks(*wake) == 0;
      },
      "worker clears the shared video deadline when no frame is due");
  expect(session->stop(stopCommand(3)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "video-due fixture Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "video-due fixture Stopped"));
}

void testGainMuteAndExactProofObservations() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);

  expect(session->setGain(0.25F) ==
             NativeMediaSessionCommandStatus::Accepted &&
             session->setGain(0.75F) ==
                 NativeMediaSessionCommandStatus::Accepted &&
             session->setMuted(true) ==
                 NativeMediaSessionCommandStatus::Accepted,
         "gain and mute intents are accepted before lazy graph creation");
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "proof fixture accepts Prepare");
  static_cast<void>(
      waitFact<protocol::Prepared>(*session, "proof fixture Prepared"));
  waitUntil(
      [&] {
        return state->gainCalls.load(std::memory_order_acquire) == 1 &&
               state->muteCalls.load(std::memory_order_acquire) == 1;
      },
      "latest gain and mute reach the audio owner");
  expect(state->lastGain.load(std::memory_order_acquire) == 0.75F &&
             state->lastMuted.load(std::memory_order_acquire),
         "pre-graph controls coalesce to their latest independent values");

  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "proof fixture Start accepted");
  const protocol::Started started =
      waitFact<protocol::Started>(*session, "proof fixture Started");
  expect(started.drawBaseline == 0,
         "Started baseline begins in tracked output event-sequence domain");
  state->clockPosition.store(2.5, std::memory_order_release);
  expect(session->setRunState({{{1}, {3}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "paused physical state accepted");

  std::optional<NativeMediaSessionRunStateApplied> pausedAck;
  std::optional<protocol::AudioClockProof> pausedClock;
  for (std::uint64_t attempt = 0;
       attempt != 2'000'000 &&
       (!pausedAck.has_value() || !pausedClock.has_value());
       ++attempt) {
    NativeMediaSessionObservations observations =
        session->takeObservations();
    if (observations.runStateApplied.has_value()) {
      pausedAck = observations.runStateApplied;
    }
    if (observations.audioClock.has_value()) {
      pausedClock = observations.audioClock;
    }
    std::this_thread::yield();
  }
  expect(pausedAck.has_value() &&
             pausedAck->command.stamp == protocol::Stamp{{1}, {3}} &&
             pausedClock.has_value() && protocol::valid(*pausedClock) &&
             pausedClock->stamp == protocol::Stamp{{1}, {3}} &&
             pausedClock->generation == protocol::Generation{7} &&
             pausedClock->anchor.value != 0 &&
             pausedClock->positionSeconds == 2.5 && pausedClock->paused,
         "paused acknowledgement carries only an exact current clock proof");

  expect(session->setRunState({{{1}, {4}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "running physical state accepted");
  const NativeMediaSessionRunStateApplied runningAck =
      waitFact<NativeMediaSessionRunStateApplied>(
          *session, "running state acknowledgement is durable");
  expect(runningAck.command.stamp == protocol::Stamp{{1}, {4}} &&
             !runningAck.command.paused,
         "running acknowledgement echoes the physical command");
  expect(!session->takeObservations().audioClock.has_value(),
         "a running clock can never manufacture paused AudioClockProof");

  {
    std::lock_guard lock(state->videoEventMutex);
    state->videoEvent = NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::FrameDrawn,
        41,
        NativeTrackedFrameSequence{1},
        7,
        FrameTiming{CMTimeMake(5, 2), CMTimeMake(1, 30), 7, false}};
  }
  wake->video().signal(wake->video().context);
  const NativeMediaSessionObservations draw = waitObservations(
      *session,
      [](const NativeMediaSessionObservations& observations) {
        return observations.videoDraw.has_value();
      },
      "real tracked FrameDrawn becomes a proof observation");
  expect(draw.videoDraw->stamp == protocol::Stamp{{1}, {4}} &&
             draw.videoDraw->generation == protocol::Generation{7} &&
             draw.videoDraw->drawSequence == 41 &&
             draw.videoDraw->drawSequence > started.drawBaseline &&
             draw.videoDraw->frameStartSeconds == 2.5 &&
             draw.videoDraw->frameDurationSeconds == (1.0 / 30.0),
         "draw proof uses eventSequence and the current physical command");

  expect(session->stop(stopCommand(5)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "proof fixture Stop accepted");
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "proof fixture Stopped"));
}

void testExhaustionStopsAudioBeforeOneEnded() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->quiesceFirstAudioStop.store(true, std::memory_order_release);
  state->blockFirstAudioStop.store(true, std::memory_order_release);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "EOS fixture Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(*session,
                                                  "EOS fixture Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "EOS fixture Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "EOS fixture Started"));
  auto endingPreviewTarget = session->preflightPreviewTarget(2.0);
  expect(endingPreviewTarget.has_value(),
         "active EOS fixture admits a preview token before exhaustion");

  // Exhaust the dispatcher before the first run issue. The later physical
  // command must not leave a blocking acknowledgement in front of Ended.
  state->blockCapacity.store(false, std::memory_order_release);
  wake->video().signal(wake->video().context);
  state->clockPosition.store(9.75, std::memory_order_release);
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "EOS fixture latest live command accepted");
  waitUntil(
      [&] {
        return state->audioStopCalls.load(std::memory_order_acquire) == 1;
      },
      "dispatcher Exhausted drives the first audio Stop attempt");
  expect(session->setRunState({{{1}, {4}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "latest live stamp coalesces atomically while ending quiesces");
  const NativeMediaSessionFacts endingFacts = session->facts();
  expect(endingFacts.ending &&
             endingFacts.requestedRunStateStamp ==
                 protocol::Stamp{{1}, {4}} &&
             endingFacts.issuedRunStateStamp != protocol::Stamp{{1}, {4}} &&
             endingFacts.appliedRunStateStamp != protocol::Stamp{{1}, {4}},
         "ending accepts the stamp without issuing another child mutation");
  const protocol::PreviewFrame endedPreview = {
      {{1}, {5}}, {7}, {9}, {1}, 2.0};
  expect(!session->preflightPreviewTarget(2.0).has_value() &&
             session->preparePreviewHandoff() ==
                 NativeMediaSessionCommandStatus::Ignored &&
             session->previewFrame(endedPreview,
                                   std::move(*endingPreviewTarget)) ==
                 NativePreviewFrameRequestStatus::Closed &&
             state->previewQuiesces.load(std::memory_order_acquire) == 0,
         "transitional ending remains closed until Ended is fully published");
  const NativeMediaSessionObservations endingObservations =
      session->takeObservations();
  expect(!endingObservations.lifecycle.has_value() &&
             !endingObservations.runStateApplied.has_value() &&
             !endingObservations.audioClock.has_value() &&
             !endingObservations.videoDraw.has_value(),
         "ending supersedes every outstanding run acknowledgement and proof");
  state->releaseFirstAudioStop.store(true, std::memory_order_release);
  wake->audio().signal(wake->audio().context);
  const protocol::Ended ended =
      waitFact<protocol::Ended>(*session, "audio Stop Done publishes Ended");
  expect(ended.stamp == protocol::Stamp{{1}, {4}} &&
             ended.generation == protocol::Generation{7} &&
             ended.finalPositionSeconds == 9.75 &&
             state->audioStopCalls.load(std::memory_order_acquire) == 2,
         "Ended echoes latest accepted live stamp after audio Stop Done");
  const NativeMediaSessionFacts endedFacts = session->facts();
  expect(endedFacts.ending && endedFacts.endedProofPublished &&
             endedFacts.ownership ==
                 NativeMediaSessionOwnershipPhase::DispatcherObserved &&
             state->videoRetires.load() == 0 &&
             state->sourceCloses.load() == 0,
         "natural end retains dispatcher, final video frame, and ownership");
  expect(session->setRunState({{{1}, {5}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Ignored &&
             session->setGain(0.2F) ==
                 NativeMediaSessionCommandStatus::Ignored &&
             session->setMuted(false) ==
                 NativeMediaSessionCommandStatus::Ignored,
         "live controls are inert after the Ended latch");
  expect(session->preparePreviewHandoff() ==
             NativeMediaSessionCommandStatus::Accepted,
         "fully published Ended admits preview prewarm");
  waitUntil(
      [&] { return session->facts().previewHandoffReady; },
      "Ended preview lane prewarms from retained source ownership");
  expect(state->previewQuiesces.load(std::memory_order_acquire) == 0,
         "Ended preview skips the already-drained main consumer quiesce");
  auto endedPreviewTarget = session->preflightPreviewTarget(2.0);
  expect(endedPreviewTarget.has_value() &&
             session->previewFrame(endedPreview,
                                   std::move(*endedPreviewTarget)) ==
                 NativePreviewFrameRequestStatus::Accepted,
         "Ended accepts exact preview lineage without reviving playback");
  const NativeMediaSessionObservations endedPreviewObservations =
      waitObservations(
          *session,
          [](const NativeMediaSessionObservations& observations) {
            return observations.previewPresented.has_value();
          },
          "Ended preview reaches real presentation");
  expect(endedPreviewObservations.previewPresented.has_value() &&
             protocol::previewPresentedMatches(
                 endedPreview,
                 *endedPreviewObservations.previewPresented) &&
             session->facts().ending &&
             session->facts().endedProofPublished &&
             state->previewQuiesces.load(std::memory_order_acquire) == 0,
         "Ended preview preserves EOS ownership while presenting the target");
  state->blockCapacity.store(true, std::memory_order_release);
  const auto replayTarget = session->preflightCommitTarget(2.0);
  expect(replayTarget.has_value(),
         "Ended session retains a fresh exact seek target");
  const protocol::CommitSeek replay = {
      {{1}, {6}}, {7}, {8}, {9}, {2}, 2.0};
  state->beginCommitLifecycle(replay.targetGeneration.value);
  const std::uint64_t startsBeforeReplay =
      state->audioStartCalls.load(std::memory_order_acquire);
  expect(session->commitSeek(replay, *replayTarget) ==
             NativeMediaSessionCommandStatus::Accepted,
         "CommitSeek follows the presented Ended preview and revives the "
         "retained dispatcher");
  publishCommitDraw(*state, 8, 1, 2.0);
  wake->video().signal(wake->video().context);
  const protocol::CommitReady replayReady = waitFact<protocol::CommitReady>(
      *session, "Ended CommitSeek reaches exact target readiness");
  expect(protocol::commitReadyMatches(
             replay, replayTarget->drawBaseline(), replayReady) &&
             session->facts().generation == 8 && !session->facts().ending &&
             !session->facts().endedProofPublished &&
             state->audioPhysicallyStarted.load(std::memory_order_acquire) &&
             state->audioStartedGeneration.load(std::memory_order_acquire) ==
                 8,
         "Ended CommitReady installs target generation with audio running and "
         "clears EOS gates");
  expectExactCommitLifecycle(
      state->finishCommitLifecycle(),
      "Ended replay flushes before one target start, then pause and proofs");
  expect(state->audioStartCalls.load(std::memory_order_acquire) ==
             startsBeforeReplay + 1,
         "Ended CommitSeek restarts stopped audio exactly once before Ready");
  expect(session->stop({{{1}, {7}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "revived Ended ownership still requires exact Stop");
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "Ended fixture Stopped"));
}

// D6. A commit that lands inside the last frame's presentation interval used
// to retire the whole native route. latchEnding() suppressed end of stream
// only while publicCommitPending was set, but publishCommitReady clears that
// flag at publication -- so media exhaustion arriving between CommitReady and
// the Router's promised post-commit SetRunState let Ended latch inside the
// handshake. Ended then carried the stale CommitSeek stamp (dropped by
// endedMatches), and the promised run command was answered Ignored, which the
// owner escalates to a Protocol failure and an mpv fallback.
//
// The fix is the commitRunStatePending latch: ending is held until the run
// command the commit protocol guarantees actually lands. This fixture pins
// exactly that window. Pre-fix it fails three ways at once -- ending latches
// early, the run command is refused, and the lifecycle fact that arrives is
// not the Ended this test waits for.
void testNearEndCommitHoldsEndingUntilItsRunStateLands() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  // Backpressure keeps the dispatcher fed until the fixture chooses the exact
  // moment media runs out.
  state->blockCapacity.store(true, std::memory_order_release);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "near-EOF commit Prepare accepted");
  static_cast<void>(
      waitFact<protocol::Prepared>(*session, "near-EOF commit Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "near-EOF commit Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "near-EOF commit Started"));

  // A quarter second short of the ten-second timeline, exactly representable
  // both as a MediaTime and in the fake video proof's 600 Hz timescale. The
  // shipping defect was reached with a target inside the final frame's
  // presentation interval, but the sub-frame arithmetic is not what breaks:
  // what breaks is exhaustion arriving between CommitReady and the run
  // command the commit protocol promises, and any near-end commit can lose
  // that race. The end-to-end matrix covers the exact 39.984375 case.
  constexpr double kNearTimelineEnd = 9.75;
  const auto target = session->preflightCommitTarget(kNearTimelineEnd);
  expect(target.has_value(),
         "a near-end commit target is exactly representable");
  if (!target.has_value()) {
    return;
  }
  const protocol::CommitSeek commit = commitCommand(3, 8, kNearTimelineEnd);
  state->beginCommitLifecycle(commit.targetGeneration.value);
  expect(session->commitSeek(commit, *target) ==
             NativeMediaSessionCommandStatus::Accepted,
         "near-EOF CommitSeek accepted");
  publishCommitDraw(*state, 8, 1, kNearTimelineEnd);
  wake->video().signal(wake->video().context);
  const protocol::CommitReady ready = waitFact<protocol::CommitReady>(
      *session, "near-EOF commit publishes exact readiness");
  expect(protocol::commitReadyMatches(commit, target->drawBaseline(), ready) &&
             session->facts().generation == 8,
         "near-EOF CommitReady installs the target generation");
  expectExactCommitLifecycle(
      state->finishCommitLifecycle(),
      "near-EOF commit flushes before one target start, then pause and proofs");

  // The handshake is open: CommitReady has been taken and the Router has not
  // yet issued the run command it promises. Media runs out right here.
  state->clockPosition.store(kNearTimelineEnd, std::memory_order_release);
  state->blockCapacity.store(false, std::memory_order_release);
  const std::uint64_t stopsBeforeExhaustion =
      state->audioStopCalls.load(std::memory_order_acquire);
  bool heldThroughout = true;
  const auto holdUntil =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(300);
  while (std::chrono::steady_clock::now() < holdUntil) {
    wake->video().signal(wake->video().context);
    wake->audio().signal(wake->audio().context);
    const NativeMediaSessionFacts facts = session->facts();
    if (facts.ending || facts.endedProofPublished || facts.liveFailed) {
      heldThroughout = false;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  expect(heldThroughout,
         "exhaustion inside the commit handshake does not latch ending");
  expect(state->audioStopCalls.load(std::memory_order_acquire) ==
             stopsBeforeExhaustion,
         "held ending never begins its audio Stop while the handshake is open");

  // The promised post-commit run command. Pre-fix the ending latch had already
  // captured the CommitSeek stamp, so this was answered Ignored.
  expect(session->setRunState({{{1}, {4}}, {8}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "the promised post-commit SetRunState is accepted, not ignored");

  // Only now may ending latch, and it must carry the run command's stamp --
  // the one the Router is actually waiting on -- so endedMatches admits it.
  const protocol::Ended ended = waitFact<protocol::Ended>(
      *session, "the completed handshake releases a clean Ended");
  expect(ended.stamp == protocol::Stamp{{1}, {4}} &&
             ended.generation == protocol::Generation{8} &&
             ended.finalPositionSeconds == kNearTimelineEnd,
         "Ended echoes the post-commit run stamp on the committed generation");
  const NativeMediaSessionFacts endedFacts = session->facts();
  expect(endedFacts.ending && endedFacts.endedProofPublished &&
             !endedFacts.liveFailed,
         "the near-EOF commit ends the session without a live failure");
  expect(session->stop({{{1}, {5}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "near-EOF ended ownership still retires on an exact Stop");
  static_cast<void>(
      waitFact<protocol::Stopped>(*session, "near-EOF commit Stopped"));
}

void testStopWinsEndedPreviewPresentationCompletion() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  prepareStartedPausedForPreview(*session);

  state->clockPosition.store(9.5, std::memory_order_release);
  state->blockCapacity.store(false, std::memory_order_release);
  wake->video().signal(wake->video().context);
  const protocol::Ended ended = waitFact<protocol::Ended>(
      *session, "ended-preview Stop fixture publishes Ended");
  expect(ended.stamp == protocol::Stamp{{1}, {3}} &&
             ended.generation == protocol::Generation{7},
         "ended-preview Stop fixture retains active lineage");

  expect(session->preparePreviewHandoff() ==
             NativeMediaSessionCommandStatus::Accepted,
         "ended-preview Stop fixture prewarms");
  waitUntil(
      [&] { return session->facts().previewHandoffReady; },
      "ended-preview Stop fixture lane becomes ready");
  expect(state->previewQuiesces.load(std::memory_order_acquire) == 0,
         "ended-preview Stop fixture never re-quiesces EOS video");

  std::atomic<bool> completionEntered{false};
  std::atomic<bool> completionRelease{false};
  NativeMediaSessionTestAccess::installPreviewCompletionBarrier(
      *session, NativeMediaSessionTestPreviewCompletionPoint::TakePresented,
      &completionEntered, &completionRelease);
  auto target = session->preflightPreviewTarget(2.5);
  const protocol::PreviewFrame preview = {
      {{1}, {4}}, {7}, {71}, {1}, 2.5};
  expect(target.has_value() &&
             session->previewFrame(preview, std::move(*target)) ==
                 NativePreviewFrameRequestStatus::Accepted,
         "ended-preview Stop fixture admits one exact frame");
  waitUntil(
      [&] { return completionEntered.load(std::memory_order_acquire); },
      "ended preview child returns before completion transaction");

  expect(session->stop({{{1}, {5}}, {9}}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop linearizes after ended preview child return");
  completionRelease.store(true, std::memory_order_release);
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "Stop retires ended preview ownership"));
  const NativeMediaSessionFacts stoppedFacts = session->facts();
  const NativeMediaSessionObservations stoppedObservations =
      session->takeObservations();
  expect(!stoppedFacts.previewHandoffPending &&
             !stoppedFacts.previewHandoffReady &&
             !stoppedFacts.previewPending &&
             !stoppedFacts.previewPresentedPending &&
             !stoppedObservations.previewPresented.has_value() &&
             state->previewStops.load(std::memory_order_acquire) != 0 &&
             state->previewQuiesces.load(std::memory_order_acquire) == 0,
         "late ended-preview completion cannot resurrect after exact Stop");
}

void testStopPrecedesQuiescingNaturalEnd() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->quiesceFirstAudioStop.store(true, std::memory_order_release);
  state->blockFirstAudioStop.store(true, std::memory_order_release);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "EOS/Stop race Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "EOS/Stop race Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "EOS/Stop race Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "EOS/Stop race Started"));
  state->blockCapacity.store(false, std::memory_order_release);
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "EOS/Stop race run accepted");
  wake->video().signal(wake->video().context);
  waitUntil(
      [&] {
        return state->audioStopCalls.load(std::memory_order_acquire) == 1;
      },
      "EOS/Stop race reaches quiescing audio Stop");
  expect(session->stop(stopCommand(4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "exact Stop wins while natural-end audio is quiescing");
  state->releaseFirstAudioStop.store(true, std::memory_order_release);
  wake->audio().signal(wake->audio().context);
  const protocol::Stopped stopped = waitFact<protocol::Stopped>(
      *session, "Stop suppresses Ended and retires exactly");
  expect(stopped.stamp == protocol::Stamp{{1}, {4}} &&
             !session->facts().endedProofPublished,
         "Stop precedence permits only the exact Stopped terminal fact");
}

void testStopAcceptedBeforeLiveIssuePreventsMutation() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "issue-race Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "issue-race Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "issue-race Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "issue-race Started"));

  std::atomic<bool> issueEntered{false};
  std::atomic<bool> issueRelease{false};
  NativeMediaSessionTestAccess::installLiveIssueBarrier(
      *session, &issueEntered, &issueRelease);
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "issue-race run accepted");
  waitUntil([&] { return issueEntered.load(std::memory_order_acquire); },
            "worker pauses before live-issue linearization");
  expect(session->stop(stopCommand(4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop accepts before child issue permit");
  issueRelease.store(true, std::memory_order_release);
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "issue-race exact Stopped"));
  expect(state->pauseCalls.load(std::memory_order_acquire) == 0,
         "Stop accepted first prevents the pending child mutation");
}

void testPendingAtStartSetsBaselineAndPreRunDrawRetains() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "pending-draw Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "pending-draw Prepared"));
  {
    std::lock_guard lock(state->videoEventMutex);
    state->pendingVideoEvent = NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::FrameDrawn,
        40,
        NativeTrackedFrameSequence{1},
        7,
        FrameTiming{CMTimeMake(2, 1), CMTimeMake(1, 30), 7, false}};
  }
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "pending-draw Start accepted");
  const protocol::Started started = waitFact<protocol::Started>(
      *session, "pending-draw Started");
  expect(started.drawBaseline == 40,
         "pending output event is included in the Start baseline");
  wake->video().signal(wake->video().context);
  std::this_thread::yield();
  expect(!session->takeObservations().videoDraw.has_value(),
         "pre-Start pending draw can never masquerade as post-Start proof");

  {
    std::lock_guard lock(state->videoEventMutex);
    state->videoEvent = NativeTrackedVideoEvent{
        NativeTrackedVideoEventKind::FrameDrawn,
        41,
        NativeTrackedFrameSequence{2},
        7,
        FrameTiming{CMTimeMake(5, 2), CMTimeMake(1, 30), 7, false}};
  }
  wake->video().signal(wake->video().context);
  waitUntil(
      [&] {
        return state->lastOutputEventSequence.load(
                   std::memory_order_acquire) >= 41;
      },
      "post-Start draw enters the retained session slot before run");
  expect(!session->takeObservations().videoDraw.has_value(),
         "post-Start draw waits while no run command is physically applied");
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "pending proof run accepted");
  std::optional<NativeMediaSessionRunStateApplied> runApplied;
  std::optional<protocol::VideoDrawProof> drawProof;
  for (std::uint64_t attempt = 0;
       attempt != 2'000'000 &&
       (!runApplied.has_value() || !drawProof.has_value());
       ++attempt) {
    NativeMediaSessionObservations observations =
        session->takeObservations();
    if (observations.lifecycle.has_value()) {
      fail("unexpected lifecycle while collecting retained draw proof");
    }
    if (observations.runStateApplied.has_value()) {
      runApplied = observations.runStateApplied;
    }
    if (observations.videoDraw.has_value()) {
      drawProof = observations.videoDraw;
    }
    std::this_thread::yield();
  }
  expect(runApplied.has_value() &&
             runApplied->command.stamp == protocol::Stamp{{1}, {3}} &&
             drawProof.has_value() && drawProof->drawSequence == 41 &&
             drawProof->stamp == protocol::Stamp{{1}, {3}},
         "retained draw keeps exact event identity and command association");
  expect(session->stop(stopCommand(4)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "pending proof Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "pending proof Stopped"));
}

void testDispatcherFailureIsPublished() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->failCapacity.store(true);
  state->blockCapacity.store(false);
  auto session = sessionFor(&state);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "dispatcher-failure Prepare accepted");
  static_cast<void>(waitFact<protocol::Prepared>(
      *session, "dispatcher-failure Prepared"));
  const protocol::Failed failed = waitFact<protocol::Failed>(
      *session, "dispatcher terminal failure becomes protocol fact");
  expect(failed.stamp == protocol::Stamp{{1}, {1}} &&
             failed.reason == protocol::FailureReason::Decode,
         "dispatcher failure echoes latest live command stamp");
  expect(session->facts().liveFailed,
         "dispatcher failure latches false-live suppression");
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Ignored,
         "Start is inert after dispatcher terminal failure");
  expect(state->pauseCalls.load() == 0,
         "no audio run mutation occurs after dispatcher failure");
  expect(session->stop(stopCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "dispatcher failure still requires exact Stop");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "dispatcher failure retires exactly"));
}

void testDispatcherFailureUsesLatestQueuedStamp() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->blockCapacity.store(true);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "queued-failure Prepare accepted");
  static_cast<void>(
      waitFact<protocol::Prepared>(*session, "queued-failure Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "queued-failure Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "queued-failure Started"));
  state->blockPause.store(true);
  expect(session->setRunState({{{1}, {3}}, {7}, false, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "queued-failure run A accepted");
  waitUntil([&] { return state->pauseEntered.load(); },
            "run A blocks on worker");
  expect(session->setRunState({{{1}, {4}}, {7}, true, 1.0}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "queued-failure run B accepted as latest Router stamp");
  std::atomic<bool> latchEntered{false};
  std::atomic<bool> latchRelease{false};
  NativeMediaSessionTestAccess::installFailureLatchBarrier(
      *session, &latchEntered, &latchRelease);
  state->releasePause.store(true);
  const NativeMediaSessionRunStateApplied queuedApplied =
      waitFact<NativeMediaSessionRunStateApplied>(
          *session, "queued run B acknowledges before later runtime failure");
  expect(queuedApplied.command.stamp == protocol::Stamp{{1}, {4}},
         "only latest queued B acknowledges");
  state->failCapacity.store(true);
  state->blockCapacity.store(false);
  wake->video().signal(wake->video().context);
  waitUntil([&] { return latchEntered.load(); },
            "failure transaction holds its linearization lock");
  std::atomic<bool> commandEntered{false};
  std::atomic<int> commandStatus{-1};
  std::thread concurrentCommand([&] {
    commandEntered.store(true, std::memory_order_release);
    commandStatus.store(
        static_cast<int>(session->setRunState(
            {{{1}, {5}}, {7}, false, 1.0})),
        std::memory_order_release);
  });
  waitUntil([&] { return commandEntered.load(); },
            "new run command races failure transaction");
  latchRelease.store(true, std::memory_order_release);
  concurrentCommand.join();
  const protocol::Failed failed = waitFact<protocol::Failed>(
      *session, "queued dispatcher failure publishes");
  expect(failed.stamp == protocol::Stamp{{1}, {4}},
         "dispatcher failure uses latest accepted queued run stamp");
  expect(commandStatus.load(std::memory_order_acquire) ==
             static_cast<int>(NativeMediaSessionCommandStatus::Ignored),
         "command blocked on failure transaction becomes inert");
  expect(session->stop(stopCommand(5)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "queued dispatcher failure Stop accepted");
  static_cast<void>(waitFact<protocol::Stopped>(
      *session, "queued dispatcher failure retires"));
}

void testStopWinsDispatcherFailurePublication() {
  auto state = std::make_shared<GraphState>();
  state->descriptor = descriptor();
  state->blockCapacity.store(true);
  std::shared_ptr<NativeMediaSessionWake> wake;
  auto session = sessionFor(&state, &wake);
  expect(prepare(*session, prepareCommand()) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop/failure race Prepare accepted");
  static_cast<void>(
      waitFact<protocol::Prepared>(*session, "Stop/failure Prepared"));
  expect(session->start({{{1}, {2}}, {7}, true}) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop/failure Start accepted");
  static_cast<void>(
      waitFact<protocol::Started>(*session, "Stop/failure Started"));
  std::atomic<bool> detectionEntered{false};
  std::atomic<bool> detectionRelease{false};
  NativeMediaSessionTestAccess::installFailureDetectionBarrier(
      *session, &detectionEntered, &detectionRelease);
  state->failCapacity.store(true);
  state->blockCapacity.store(false);
  wake->video().signal(wake->video().context);
  waitUntil([&] { return detectionEntered.load(); },
            "dispatcher failure detected before publication");
  expect(session->stop(stopCommand(3)) ==
             NativeMediaSessionCommandStatus::Accepted,
         "Stop wins terminal ownership before failure transaction");
  detectionRelease.store(true, std::memory_order_release);
  const protocol::Stopped stopped = waitFact<protocol::Stopped>(
      *session, "Stop suppresses live Decode failure");
  expect(stopped.stamp == protocol::Stamp{{1}, {3}},
         "only exact Stopped escapes Stop/failure race");
}

}  // namespace

int main() {
  testEveryWorkerWakeOwnsOneDrainedAutoreleasePool();
  testObservationQueueRejectionRetriesWithoutPolling();
  testStopWinsEveryPreviewChildCompletion();
  testCommitWinsAfterPresentedChildReturn();
  testPreviewHandoffPrewarmsBeforeFirstMotion();
  testPreviewHandoffStopWinsQuiescingPrewarm();
  testStopWinsSuccessfulPreviewConstructionWindow();
  testCommitWinsSuccessfulPreviewConstructionWindow();
  testPreviewLatestWinsAndStopQuiescesLane();
  testAcceptedPreviewFailuresPublishExactTerminal();
  testPreviewFailureNamesLatestPublicReplacement();
  testCommitBurnsQueuedPreviewFailure();
  testCommitSeekPendingReadyAndStopHighWater();
  testCommitSeekProceedsPastFailedPreviewLane();
  testCommitSeekAdmittedDuringStarting();
  testExactTimeAndSequencing();
  testUnobservedDirectRetireBarrier();
  testObservedUsesDispatcherRetireOnly();
  testAdmissionGateBeforeConfigure();
  testTerminalFailuresLatchAllLiveControls();
  testCancelBeforeSourceArmAndMailboxPrecedence();
  testLateFailureCannotHideStop();
  testRunIntentCoalescesAcrossQuiescing();
  testWakeConsumeRaceAbsorbsRunIntoCurrentDrain();
  testVideoDueHintArmsOnlyTheSharedAudioEdge();
  testWakeClearBeforeDrainPreservesLateRun();
  testGainMuteAndExactProofObservations();
  testExhaustionStopsAudioBeforeOneEnded();
  testNearEndCommitHoldsEndingUntilItsRunStateLands();
  testStopWinsEndedPreviewPresentationCompletion();
  testStopPrecedesQuiescingNaturalEnd();
  testStopAcceptedBeforeLiveIssuePreventsMutation();
  testPendingAtStartSetsBaselineAndPreRunDrawRetains();
  testDispatcherFailureIsPublished();
  testDispatcherFailureUsesLatestQueuedStamp();
  testStopWinsDispatcherFailurePublication();
  std::cout << "native media session tests passed\n";
  return EXIT_SUCCESS;
}
