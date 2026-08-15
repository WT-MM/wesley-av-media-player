#include "media/native_media_dispatcher.hpp"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace {

using namespace wam::media;

[[noreturn]] void failTest(const char* message) {
  std::cerr << "FAIL: " << message << '\n';
  std::exit(1);
}

void expect(bool condition, const char* message) {
  if (!condition) {
    failTest(message);
  }
}

class TestPayload final : public MediaPayloadStorage {
 public:
  TestPayload(std::uint8_t value,
              std::shared_ptr<std::atomic<std::uint64_t>> destructions,
              std::shared_ptr<std::atomic<std::uint64_t>> byteSizeCalls =
                  nullptr)
      : bytes_{std::byte{value}, std::byte{value}, std::byte{value},
               std::byte{value}},
        destructions_(std::move(destructions)),
        byte_size_calls_(std::move(byteSizeCalls)) {}

  ~TestPayload() override {
    destructions_->fetch_add(1, std::memory_order_relaxed);
  }

  [[nodiscard]] std::size_t byteSize() const noexcept override {
    if (byte_size_calls_ != nullptr) {
      byte_size_calls_->fetch_add(1, std::memory_order_relaxed);
    }
    return bytes_.size();
  }

  [[nodiscard]] std::span<const std::byte>
  contiguousBytes() const noexcept override {
    return bytes_;
  }

  [[nodiscard]] bool copyBytes(
      std::size_t offset,
      std::span<std::byte> destination) const noexcept override {
    if (offset > bytes_.size() ||
        destination.size() > bytes_.size() - offset) {
      return false;
    }
    for (std::size_t index = 0; index < destination.size(); ++index) {
      destination[index] = bytes_[offset + index];
    }
    return true;
  }

 protected:
  [[nodiscard]] std::optional<NativePayloadKind>
  nativePayloadKind() const noexcept override {
    return std::nullopt;
  }

  [[nodiscard]] const void* borrowedNativePayload() const noexcept override {
    return nullptr;
  }

 private:
  std::array<std::byte, 4> bytes_{};
  std::shared_ptr<std::atomic<std::uint64_t>> destructions_;
  std::shared_ptr<std::atomic<std::uint64_t>> byte_size_calls_;
};

MediaTrackDescriptor videoTrack() {
  MediaVideoFormat format;
  format.codedWidth = 640;
  format.codedHeight = 360;
  format.displayWidth = 640;
  format.displayHeight = 360;
  format.bitsPerComponent = 8;
  format.sampleFormat = MediaVideoSampleFormat::Yuv420EightBit;

  MediaTrackDescriptor track;
  track.id = 1;
  track.kind = MediaTrackKind::Video;
  track.codec = MediaCodec::H264;
  track.timeBase = {1, 1000};
  track.duration = {10, 1};
  track.video = format;
  return track;
}

MediaTrackDescriptor audioTrack(double sampleRate = 48'000.0) {
  MediaAudioFormat format;
  format.sampleRate = sampleRate;
  format.channels = 2;
  format.formatTag = 0x61616320U;
  format.framesPerPacket = 1024;

  MediaTrackDescriptor track;
  track.id = 2;
  track.kind = MediaTrackKind::Audio;
  track.codec = MediaCodec::Aac;
  track.timeBase = {1, static_cast<std::int32_t>(sampleRate)};
  track.duration = {10, 1};
  track.audio = format;
  return track;
}

std::shared_ptr<const MediaSourceDescriptor> descriptor() {
  auto value = std::make_shared<MediaSourceDescriptor>();
  value->duration = {10, 1};
  value->inventory.video = 1;
  value->inventory.audio = 1;
  value->inventory.total = 2;
  value->tracks.push_back(videoTrack());
  value->tracks.push_back(audioTrack());
  value->selectedVideo = 1;
  value->selectedAudio = 2;
  return value;
}

class TestPreparedContext final : public MediaSourcePreparedContext {
 public:
  TestPreparedContext(
      MediaSourceBackendKind backendKind, std::filesystem::path path,
      const MediaSourceOpenOptions& options,
      std::shared_ptr<const MediaSourceDescriptor> descriptor) noexcept
      : MediaSourcePreparedContext(backendKind, std::move(path), options,
                                   std::move(descriptor)) {}
};

MediaSample sample(
    MediaSampleKind kind, MediaTrackId track, std::uint8_t value,
    const std::shared_ptr<std::atomic<std::uint64_t>>& destructions,
    MediaGeneration generation = 1,
    std::shared_ptr<std::atomic<std::uint64_t>> byteSizeCalls = nullptr) {
  MediaSample result;
  result.generation = generation;
  result.track = track;
  result.kind = kind;
  result.presentationTime = {0, 1000};
  result.decodeTime = {0, 1000};
  result.duration = {40, 1000};
  result.keyFrame = kind == MediaSampleKind::EncodedVideo;
  result.sampleCount = 1;
  result.payload = MediaPayloadLease(
      std::make_shared<TestPayload>(value, destructions,
                                    std::move(byteSizeCalls)));
  return result;
}

class FakeSource final : public MediaSource {
 public:
  FakeSource(std::shared_ptr<const MediaSourceDescriptor> descriptor,
             std::vector<MediaSourceReadResult> events)
      : descriptor_(std::move(descriptor)), events_(std::move(events)) {}

  [[nodiscard]] bool
  armOperation(MediaGeneration generation) noexcept override {
    ++armCalls;
    armAttempts.push_back(generation);
    if (generation == 0 || armedGeneration != 0 ||
        generation <= generationHighWater) {
      return false;
    }
    generationHighWater = generation;
    cancelledGeneration.store(0, std::memory_order_release);
    armedGeneration = generation;
    sourceOperationGeneration.store(generation, std::memory_order_release);
    if (observedDispatcher != nullptr) {
      dispatcherOperationAtArmCommit =
          observedDispatcher->stats().operationGeneration;
    }
    if (cancelAtArmCommit && observedDispatcher != nullptr) {
      // Deterministic interleaving: the source arm is fully committed and
      // externally cancellable, but the matching operation has not entered.
      observedDispatcher->requestCancel(generation - 1);
      observedDispatcher->requestCancel(generation + 1);
      observedDispatcher->requestCancel(0);
      observedDispatcher->requestCancel(generation);
    }
    return true;
  }

  [[nodiscard]] MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path& path,
      const MediaSourceOpenOptions& options,
      MediaGeneration generation) override {
    ++openCalls;
    if (observedDispatcher != nullptr) {
      dispatcherOperationAtOpenEntry =
          observedDispatcher->stats().operationGeneration;
    }
    if (!consumeArm(generation)) {
      ++unarmedOperationEntries;
      return {};
    }
    if (operationCancelled(generation)) {
      currentGeneration = generation;
      open = false;
      sourceOperationGeneration.store(0, std::memory_order_release);
      MediaSourceOpenOutcome cancelled;
      cancelled.status = MediaSourceOpenStatus::Cancelled;
      cancelled.generation = generation;
      return cancelled;
    }
    currentGeneration = generation;
    open = openStatus == MediaSourceOpenStatus::Ready;
    MediaSourceOpenOutcome result;
    result.status = openStatus;
    result.generation = generation;
    result.actualDecodeStart = openActualDecodeStart;
    lastOpenOptions = options;
    lastOpenPath = path;
    if (open) {
      result.descriptor = descriptor_;
      std::shared_ptr<const MediaSourceDescriptor> contextDescriptor =
          contextUsesClonedDescriptor
              ? std::make_shared<const MediaSourceDescriptor>(*descriptor_)
              : descriptor_;
      preparedContext = std::make_shared<const TestPreparedContext>(
          MediaSourceBackendKind::AVFoundation, path, options,
          std::move(contextDescriptor));
      if (!omitPreparedContext) {
        result.preparedContext = preparedContext;
      }
      if (!omitOpenAudioWindow) {
        const MediaTime target = options.initialPosition
                                     ? options.initialPosition->target
                                     : MediaTime{0, 1};
        const MediaSeekMode mode = options.initialPosition
                                       ? options.initialPosition->mode
                                       : MediaSeekMode::Accurate;
        result.audioWindow = openAudioWindow.value_or(
            defaultAudioWindow(target, mode, result.actualDecodeStart));
      }
    } else {
      sourceOperationGeneration.store(0, std::memory_order_release);
    }
    return result;
  }

  [[nodiscard]] MediaSourceSeekOutcome seek(
      const MediaSourceSeekRequest& request) override {
    ++seekCalls;
    if (observedDispatcher != nullptr) {
      dispatcherOperationAtSeekEntry =
          observedDispatcher->stats().operationGeneration;
    }
    if (!consumeArm(request.generation)) {
      ++unarmedOperationEntries;
      return {};
    }
    if (order != nullptr) {
      seekOrder = ++*order;
    }
    if (operationCancelled(request.generation)) {
      currentGeneration = request.generation;
      open = false;
      sourceOperationGeneration.store(0, std::memory_order_release);
      MediaSourceSeekOutcome cancelled;
      cancelled.generation = request.generation;
      return cancelled;
    }
    if (!seekAccepted) {
      sourceOperationGeneration.store(currentGeneration,
                                      std::memory_order_release);
      MediaSourceSeekOutcome rejected;
      rejected.generation = request.generation;
      rejected.actualDecodeStart = request.target;
      return rejected;
    }
    currentGeneration = request.generation;
    MediaSourceSeekOutcome result;
    result.accepted = true;
    result.generation = request.generation;
    result.actualDecodeStart = seekActualDecodeStart.value_or(request.target);
    if (replacePreparedContextOnSeek) {
      preparedContext = std::make_shared<const TestPreparedContext>(
          MediaSourceBackendKind::AVFoundation, lastOpenPath,
          *lastOpenOptions, descriptor_);
    }
    if (!omitPreparedContextOnSeek) {
      result.preparedContext = preparedContext;
    }
    if (!omitSeekAudioWindow) {
      result.audioWindow = seekAudioWindow.value_or(defaultAudioWindow(
          request.target, request.mode, result.actualDecodeStart));
    }
    return result;
  }

  [[nodiscard]] MediaSourceReadResult readNext(
      MediaGeneration expectedGeneration) override {
    ++readCalls;
    if (expectedGeneration != currentGeneration) {
      return MediaSourceCancelled{expectedGeneration};
    }
    if (nextEvent == events_.size()) {
      return MediaSourceExhausted{expectedGeneration};
    }
    return std::move(events_[nextEvent++]);
  }

  void requestCancel(MediaGeneration generation) noexcept override {
    if (order != nullptr && firstCancelOrder == 0) {
      firstCancelOrder = ++*order;
    }
    cancelGenerations.push_back(generation);
    if (generation != 0 &&
        sourceOperationGeneration.load(std::memory_order_acquire) ==
            generation) {
      cancelledGeneration.store(generation, std::memory_order_release);
      effectiveCancelGenerations.push_back(generation);
    }
  }

  void close() noexcept override {
    if (order != nullptr && firstCloseOrder == 0) {
      firstCloseOrder = ++*order;
    }
    ++closeCalls;
    open = false;
    preparedContext.reset();
    armedGeneration = 0;
    sourceOperationGeneration.store(0, std::memory_order_release);
  }

  [[nodiscard]] MediaSourceStats stats() const noexcept override {
    MediaSourceStats result;
    result.open = open;
    result.cancelled = operationCancelled(
        sourceOperationGeneration.load(std::memory_order_acquire));
    result.generation = generationHighWater;
    result.operationGeneration =
        sourceOperationGeneration.load(std::memory_order_acquire);
    result.samplesEmitted = readCalls;
    return result;
  }

  [[nodiscard]] const std::shared_ptr<const MediaSourceDescriptor>&
  admittedDescriptor() const noexcept {
    return descriptor_;
  }

  MediaSourceOpenStatus openStatus{MediaSourceOpenStatus::Ready};
  bool seekAccepted{true};
  MediaTime openActualDecodeStart{0, 1000};
  std::optional<MediaTime> seekActualDecodeStart;
  std::optional<MediaSourceOpenOptions> lastOpenOptions;
  std::filesystem::path lastOpenPath;
  std::shared_ptr<const MediaSourcePreparedContext> preparedContext;
  bool omitPreparedContext{false};
  bool contextUsesClonedDescriptor{false};
  bool omitPreparedContextOnSeek{false};
  bool replacePreparedContextOnSeek{false};
  bool omitOpenAudioWindow{false};
  bool omitSeekAudioWindow{false};
  std::optional<MediaAudioGenerationWindow> openAudioWindow;
  std::optional<MediaAudioGenerationWindow> seekAudioWindow;
  bool open{false};
  MediaGeneration currentGeneration{0};
  MediaGeneration generationHighWater{0};
  MediaGeneration armedGeneration{0};
  std::atomic<MediaGeneration> sourceOperationGeneration{0};
  std::atomic<MediaGeneration> cancelledGeneration{0};
  std::uint64_t armCalls{0};
  std::uint64_t openCalls{0};
  std::uint64_t seekCalls{0};
  std::uint64_t readCalls{0};
  std::uint64_t closeCalls{0};
  std::uint64_t unarmedOperationEntries{0};
  std::vector<MediaGeneration> armAttempts;
  std::vector<MediaGeneration> cancelGenerations;
  std::vector<MediaGeneration> effectiveCancelGenerations;
  NativeMediaDispatcher* observedDispatcher{nullptr};
  bool cancelAtArmCommit{false};
  MediaGeneration dispatcherOperationAtArmCommit{0};
  MediaGeneration dispatcherOperationAtOpenEntry{0};
  MediaGeneration dispatcherOperationAtSeekEntry{0};
  int* order{nullptr};
  int seekOrder{0};
  int firstCancelOrder{0};
  int firstCloseOrder{0};

 private:
  [[nodiscard]] MediaAudioGenerationWindow defaultAudioWindow(
      MediaTime target, MediaSeekMode mode,
      MediaTime actualDecodeStart) const noexcept {
    if (descriptor_ == nullptr || !descriptor_->selectedAudio) {
      return {};
    }
    const MediaTrackDescriptor* track =
        findMediaTrack(*descriptor_, *descriptor_->selectedAudio);
    if (track == nullptr || !track->audio ||
        track->audio->sampleRate != 48'000.0) {
      return {};
    }
    MediaAudioGenerationWindow result;
    if (mode == MediaSeekMode::Accurate) {
      const auto boundary = audioFrameAtOrAfter(target, 48'000);
      if (!boundary) {
        return {};
      }
      result.decodeStart = *boundary;
      result.presentationStart = *boundary;
    } else {
      result.decodeStart = actualDecodeStart;
      result.presentationStart = actualDecodeStart;
    }
    result.startsAtStreamOrigin =
        result.decodeStart == MediaTime{0, 1};
    return result;
  }

  [[nodiscard]] bool consumeArm(MediaGeneration generation) noexcept {
    if (armedGeneration != generation ||
        sourceOperationGeneration.load(std::memory_order_acquire) !=
            generation) {
      return false;
    }
    armedGeneration = 0;
    return true;
  }

  [[nodiscard]] bool
  operationCancelled(MediaGeneration generation) const noexcept {
    return generation != 0 &&
           cancelledGeneration.load(std::memory_order_acquire) == generation;
  }

  std::shared_ptr<const MediaSourceDescriptor> descriptor_;
  std::vector<MediaSourceReadResult> events_;
  std::size_t nextEvent{0};
};

template <typename Result>
Result scripted(const std::vector<Result>& values, std::size_t& cursor,
                Result fallback) {
  if (cursor == values.size()) {
    return fallback;
  }
  return values[cursor++];
}

struct FakeConsumerState {
  NativeMediaConsumeResult configureResult{NativeMediaConsumeResult::Accepted};
  NativeMediaConsumeResult capacityResult{NativeMediaConsumeResult::Accepted};
  NativeMediaConsumeResult discontinuityResult{
      NativeMediaConsumeResult::Accepted};
  NativeMediaConsumeResult endResult{NativeMediaConsumeResult::Drained};
  std::vector<NativeMediaConsumeResult> sampleResults;
  std::vector<NativeMediaConsumerProgress> drainResults;
  std::vector<NativeMediaConsumerProgress> flushResults;
  std::vector<NativeMediaConsumerProgress> cancelResults;
  std::vector<NativeMediaConsumerProgress> retireResults;
  std::vector<NativeMediaConsumerProgress> closeResults;
  std::size_t sampleCursor{0};
  std::size_t drainCursor{0};
  std::size_t flushCursor{0};
  std::size_t cancelCursor{0};
  std::size_t retireCursor{0};
  std::size_t closeCursor{0};
  bool takeOnBackpressure{false};
  bool acceptWithoutTake{false};
  MediaTrackId configuredTrack{0};
  MediaGeneration configuredGeneration{0};
  std::optional<NativeMediaGenerationTimeline> configuredTimeline;
  std::uint64_t configureCalls{0};
  std::uint64_t capacityCalls{0};
  std::uint64_t sampleCalls{0};
  std::uint64_t discontinuityCalls{0};
  std::uint64_t endCalls{0};
  std::uint64_t drainCalls{0};
  std::uint64_t flushCalls{0};
  std::uint64_t cancelCalls{0};
  std::uint64_t retireCalls{0};
  std::uint64_t closeCalls{0};
  std::vector<std::uint8_t> acceptedBytes;
  std::vector<std::pair<MediaGeneration, MediaGeneration>> flushGenerations;
  std::vector<NativeMediaGenerationTimeline> flushTimelines;
  std::vector<MediaGeneration> cancelGenerations;
  std::vector<std::pair<MediaGeneration, MediaGeneration>> retireGenerations;
  int* order{nullptr};
  int firstFlushOrder{0};
  int firstRetireOrder{0};
  std::shared_ptr<std::atomic<std::uint64_t>> observedDestructions;
  bool payloadReleasedAtFirstRetire{false};
};

NativeMediaConsumeResult configureConsumer(
    FakeConsumerState& state, const MediaTrackDescriptor& track,
    MediaGeneration generation,
    const NativeMediaGenerationTimeline& timeline) {
  ++state.configureCalls;
  state.configuredTrack = track.id;
  state.configuredGeneration = generation;
  state.configuredTimeline = timeline;
  return state.configureResult;
}

NativeMediaConsumeResult capacityConsumer(FakeConsumerState& state) {
  ++state.capacityCalls;
  return state.capacityResult;
}

NativeMediaConsumeResult sampleConsumer(
    FakeConsumerState& state, NativeMediaSampleDelivery& delivery) {
  ++state.sampleCalls;
  const NativeMediaConsumeResult result =
      scripted(state.sampleResults, state.sampleCursor,
               NativeMediaConsumeResult::Accepted);
  if (result == NativeMediaConsumeResult::Backpressure &&
      state.takeOnBackpressure) {
    static_cast<void>(delivery.take());
    return result;
  }
  if (result == NativeMediaConsumeResult::Accepted &&
      !state.acceptWithoutTake) {
    MediaSample owned = delivery.take();
    const auto bytes = owned.payload.contiguousBytes();
    if (!bytes.empty()) {
      state.acceptedBytes.push_back(std::to_integer<std::uint8_t>(bytes[0]));
    }
  }
  return result;
}

NativeMediaConsumerProgress drainConsumer(FakeConsumerState& state) {
  ++state.drainCalls;
  return scripted(state.drainResults, state.drainCursor,
                   NativeMediaConsumerProgress::Done);
}

NativeMediaConsumerProgress flushConsumer(
    FakeConsumerState& state, MediaGeneration retired,
    MediaGeneration next, const NativeMediaGenerationTimeline& timeline) {
  ++state.flushCalls;
  state.flushGenerations.emplace_back(retired, next);
  state.flushTimelines.push_back(timeline);
  if (state.order != nullptr && state.firstFlushOrder == 0) {
    state.firstFlushOrder = ++*state.order;
  }
  return scripted(state.flushResults, state.flushCursor,
                   NativeMediaConsumerProgress::Done);
}

NativeMediaConsumerProgress cancelConsumer(FakeConsumerState& state,
                                           MediaGeneration generation) {
  ++state.cancelCalls;
  state.cancelGenerations.push_back(generation);
  return scripted(state.cancelResults, state.cancelCursor,
                   NativeMediaConsumerProgress::Done);
}

NativeMediaConsumerProgress retireConsumer(
    FakeConsumerState& state, MediaGeneration retired,
    MediaGeneration invalidation) {
  ++state.retireCalls;
  state.retireGenerations.emplace_back(retired, invalidation);
  if (state.order != nullptr && state.firstRetireOrder == 0) {
    state.firstRetireOrder = ++*state.order;
  }
  if (state.retireCalls == 1 && state.observedDestructions != nullptr) {
    state.payloadReleasedAtFirstRetire =
        state.observedDestructions->load(std::memory_order_relaxed) != 0;
  }
  return scripted(state.retireResults, state.retireCursor,
                   NativeMediaConsumerProgress::Done);
}

NativeMediaConsumerProgress closeConsumer(FakeConsumerState& state) {
  ++state.closeCalls;
  return scripted(state.closeResults, state.closeCursor,
                   NativeMediaConsumerProgress::Done);
}

class FakeVideoConsumer final : public NativeVideoConsumer {
 public:
  explicit FakeVideoConsumer(std::shared_ptr<FakeConsumerState> state)
      : state_(std::move(state)) {}

  NativeMediaConsumeResult configure(const MediaTrackDescriptor& track,
                                     MediaGeneration generation,
                                     const NativeMediaGenerationTimeline&
                                         timeline,
                                     std::string*) override {
    return configureConsumer(*state_, track, generation, timeline);
  }
  NativeMediaConsumeResult capacity(MediaGeneration) override {
    return capacityConsumer(*state_);
  }
  NativeMediaConsumeResult trySample(NativeMediaSampleDelivery& delivery,
                                     std::string*) override {
    return sampleConsumer(*state_, delivery);
  }
  NativeMediaConsumeResult discontinuity(const MediaDiscontinuity&,
                                          std::string*) override {
    ++state_->discontinuityCalls;
    return state_->discontinuityResult;
  }
  NativeMediaConsumeResult endOfStream(const MediaEndOfStream&,
                                       std::string*) override {
    ++state_->endCalls;
    return state_->endResult;
  }
  NativeMediaConsumerProgress drain(MediaGeneration, std::string*) override {
    return drainConsumer(*state_);
  }
  NativeMediaConsumerProgress cancel(MediaGeneration generation) noexcept
      override {
    return cancelConsumer(*state_, generation);
  }
  NativeMediaConsumerProgress flush(MediaGeneration retired,
                                    MediaGeneration next,
                                    const NativeMediaGenerationTimeline&
                                        timeline) noexcept override {
    return flushConsumer(*state_, retired, next, timeline);
  }
  NativeMediaConsumerProgress retire(MediaGeneration retired,
                                     MediaGeneration invalidation) noexcept
      override {
    return retireConsumer(*state_, retired, invalidation);
  }
  NativeMediaConsumerProgress close() noexcept override {
    return closeConsumer(*state_);
  }

 private:
  std::shared_ptr<FakeConsumerState> state_;
};

class FakeAudioConsumer final : public NativeAudioConsumer {
 public:
  explicit FakeAudioConsumer(std::shared_ptr<FakeConsumerState> state)
      : state_(std::move(state)) {}

  NativeMediaConsumeResult configure(const MediaTrackDescriptor& track,
                                     MediaGeneration generation,
                                     const NativeMediaGenerationTimeline&
                                         timeline,
                                     std::string*) override {
    return configureConsumer(*state_, track, generation, timeline);
  }
  NativeMediaConsumeResult capacity(MediaGeneration) override {
    return capacityConsumer(*state_);
  }
  NativeMediaConsumeResult trySample(NativeMediaSampleDelivery& delivery,
                                     std::string*) override {
    return sampleConsumer(*state_, delivery);
  }
  NativeMediaConsumeResult discontinuity(const MediaDiscontinuity&,
                                          std::string*) override {
    ++state_->discontinuityCalls;
    return state_->discontinuityResult;
  }
  NativeMediaConsumeResult endOfStream(const MediaEndOfStream&,
                                       std::string*) override {
    ++state_->endCalls;
    return state_->endResult;
  }
  NativeMediaConsumerProgress drain(MediaGeneration, std::string*) override {
    return drainConsumer(*state_);
  }
  NativeMediaConsumerProgress cancel(MediaGeneration generation) noexcept
      override {
    return cancelConsumer(*state_, generation);
  }
  NativeMediaConsumerProgress flush(MediaGeneration retired,
                                    MediaGeneration next,
                                    const NativeMediaGenerationTimeline&
                                        timeline) noexcept override {
    return flushConsumer(*state_, retired, next, timeline);
  }
  NativeMediaConsumerProgress retire(MediaGeneration retired,
                                     MediaGeneration invalidation) noexcept
      override {
    return retireConsumer(*state_, retired, invalidation);
  }
  NativeMediaConsumerProgress close() noexcept override {
    return closeConsumer(*state_);
  }

 private:
  std::shared_ptr<FakeConsumerState> state_;
};

struct TestRig {
  std::unique_ptr<NativeMediaDispatcher> dispatcher;
  FakeSource* source{nullptr};
  std::shared_ptr<FakeConsumerState> video;
  std::shared_ptr<FakeConsumerState> audio;
};

TestRig makeRigWithDescriptor(
    std::shared_ptr<const MediaSourceDescriptor> sourceDescriptor,
    std::vector<MediaSourceReadResult> events) {
  auto source = std::make_unique<FakeSource>(std::move(sourceDescriptor),
                                             std::move(events));
  FakeSource* sourcePointer = source.get();
  auto video = std::make_shared<FakeConsumerState>();
  auto audio = std::make_shared<FakeConsumerState>();
  auto dispatcher = std::make_unique<NativeMediaDispatcher>(
      std::move(source), std::make_unique<FakeVideoConsumer>(video),
      std::make_unique<FakeAudioConsumer>(audio));
  return {std::move(dispatcher), sourcePointer, std::move(video),
          std::move(audio)};
}

TestRig makeRig(std::vector<MediaSourceReadResult> events) {
  return makeRigWithDescriptor(descriptor(), std::move(events));
}

MediaSourceOpenOptions requiredAvOptions() {
  MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  options.selection.requireAudio = true;
  return options;
}

void openRig(TestRig& rig) {
  const NativeMediaDispatcherOpenOutcome opened = rig.dispatcher->openLocalFile(
      "fixture.mp4", requiredAvOptions(), 1);
  const NativeMediaGenerationTimeline expected{
      1, MediaSeekMode::Accurate, {0, 1}, {0, 1000}, {0, 1}, true,
      {{0, 1}, {0, 1}, true}};
  expect(opened.status == NativeMediaDispatcherOpenStatus::Ready &&
             opened.generation == 1 && opened.timeline == expected &&
             rig.dispatcher->timeline() == expected &&
             rig.dispatcher->preparedContext() != nullptr &&
             rig.dispatcher->preparedContext().get() ==
                 rig.source->preparedContext.get() &&
             rig.dispatcher->preparedContext()->descriptor().get() ==
                 rig.dispatcher->descriptor().get(),
         "dispatcher opens one exact source generation and retains its "
         "prepared identity");
  expect(rig.video->configuredTrack == 1 &&
             rig.audio->configuredTrack == 2 &&
             rig.video->configuredGeneration == 1 &&
             rig.audio->configuredGeneration == 1 &&
             rig.video->configuredTimeline == expected &&
             rig.audio->configuredTimeline == expected,
         "selected descriptors and exact generation reach typed consumers");
}

void checkPreparedContextIdentity() {
  int legacyOrder = 0;
  TestRig missing = makeRig({});
  missing.source->omitPreparedContext = true;
  missing.source->omitPreparedContextOnSeek = true;
  missing.source->order = &legacyOrder;
  missing.video->order = &legacyOrder;
  missing.audio->order = &legacyOrder;
  const NativeMediaDispatcherOpenOutcome missingOutcome =
      missing.dispatcher->openLocalFile("missing.mp4", requiredAvOptions(),
                                        1);
  expect(missingOutcome.status == NativeMediaDispatcherOpenStatus::Ready &&
             missing.dispatcher->preparedContext() == nullptr &&
             missing.video->configureCalls == 1 &&
             missing.audio->configureCalls == 1,
         "legacy context-free injected sources remain usable during the "
         "prepared-context migration");
  const NativeMediaDispatcherSeekOutcome missingSeek =
      missing.dispatcher->seek(
          MediaSourceSeekRequest{2, {3, 1}, MediaSeekMode::Accurate});
  expect(missingSeek.status == NativeMediaDispatcherSeekStatus::Accepted &&
             missing.dispatcher->stats().generation == 2 &&
             missing.dispatcher->preparedContext() == nullptr &&
             missing.source->seekOrder == 1 &&
             missing.video->firstFlushOrder == 2 &&
             missing.audio->firstFlushOrder == 3,
         "a legacy null-open/null-seek source remains accepted while source "
         "seek still commits before either consumer flush");

  TestRig forged = makeRig({});
  forged.source->contextUsesClonedDescriptor = true;
  const NativeMediaDispatcherOpenOutcome forgedOutcome =
      forged.dispatcher->openLocalFile("forged.mp4", requiredAvOptions(), 1);
  expect(forgedOutcome.status == NativeMediaDispatcherOpenStatus::Failed &&
             forged.dispatcher->stats().failure ==
                 NativeMediaDispatcherFailure::InvalidDescriptor &&
             forged.source->preparedContext != nullptr &&
             *forged.source->preparedContext->descriptor() ==
                 *forged.source->admittedDescriptor() &&
             forged.source->preparedContext->descriptor().get() !=
                 forged.source->admittedDescriptor().get() &&
             forged.video->configureCalls == 0 &&
             forged.audio->configureCalls == 0,
         "a deep-equal but pointer-distinct descriptor cannot forge prepared "
         "identity");

  TestRig replaced = makeRig({});
  openRig(replaced);
  const auto admitted = replaced.dispatcher->preparedContext();
  replaced.source->replacePreparedContextOnSeek = true;
  const NativeMediaDispatcherSeekOutcome replacedOutcome =
      replaced.dispatcher->seek(
          MediaSourceSeekRequest{2, {3, 1}, MediaSeekMode::Accurate});
  expect(replacedOutcome.status == NativeMediaDispatcherSeekStatus::Failed &&
             replaced.dispatcher->stats().failure ==
                 NativeMediaDispatcherFailure::Seek &&
             replaced.dispatcher->stats().generation == 1 &&
             replaced.dispatcher->preparedContext().get() == admitted.get() &&
             replaced.source->preparedContext.get() != admitted.get() &&
             replaced.video->flushCalls == 0 &&
             replaced.audio->flushCalls == 0,
         "a seek that replaces prepared identity fails before either consumer "
         "flushes");

  TestRig omittedSeek = makeRig({});
  openRig(omittedSeek);
  omittedSeek.source->omitPreparedContextOnSeek = true;
  const NativeMediaDispatcherSeekOutcome omittedSeekOutcome =
      omittedSeek.dispatcher->seek(
          MediaSourceSeekRequest{2, {3, 1}, MediaSeekMode::Accurate});
  expect(omittedSeekOutcome.status ==
                 NativeMediaDispatcherSeekStatus::Failed &&
             omittedSeek.video->flushCalls == 0 &&
             omittedSeek.audio->flushCalls == 0,
         "an accepted seek cannot omit the exact prepared context");

  TestRig closing = makeRig({});
  openRig(closing);
  std::weak_ptr<const MediaSourcePreparedContext> lifetime =
      closing.dispatcher->preparedContext();
  expect(closing.dispatcher->close(1).status ==
             NativeMediaDispatcherLifecycleStatus::Done,
         "prepared-context lifetime fixture closes exactly");
  expect(closing.dispatcher->preparedContext() == nullptr &&
             lifetime.expired(),
         "terminal close releases the dispatcher and source context owners");
}

void checkExactGenerationTimelines() {
  TestRig initial = makeRig({});
  initial.source->openActualDecodeStart = {2, 1};
  initial.source->openAudioWindow =
      MediaAudioGenerationWindow{{2, 1}, {5, 1}, false};
  MediaSourceOpenOptions positioned = requiredAvOptions();
  positioned.initialPosition =
      MediaSourceInitialPosition{{5, 1}, MediaSeekMode::Accurate};
  const NativeMediaDispatcherOpenOutcome opened =
      initial.dispatcher->openLocalFile("positioned.mp4", positioned, 7);
  const NativeMediaGenerationTimeline accurate{
      7, MediaSeekMode::Accurate, {5, 1}, {2, 1}, {5, 1}, false,
      {{2, 1}, {5, 1}, false}};
  expect(opened.status == NativeMediaDispatcherOpenStatus::Ready &&
             opened.timeline == accurate &&
             opened.actualDecodeStart == MediaTime{2, 1} &&
             initial.dispatcher->timeline() == accurate &&
             initial.video->configuredTimeline == accurate &&
             initial.audio->configuredTimeline == accurate &&
             initial.source->lastOpenOptions &&
             initial.source->lastOpenOptions->initialPosition ==
                 positioned.initialPosition,
         "nonzero initial open publishes exact accurate-preroll facts to both "
         "consumers without reopening at zero");

  initial.video->flushResults = {NativeMediaConsumerProgress::Quiescing,
                                 NativeMediaConsumerProgress::Done};
  initial.audio->flushResults = {NativeMediaConsumerProgress::Quiescing,
                                 NativeMediaConsumerProgress::Done};
  initial.source->seekActualDecodeStart = MediaTime{6, 1};
  const NativeMediaDispatcherSeekOutcome seeking = initial.dispatcher->seek(
      MediaSourceSeekRequest{8, {8, 1}, MediaSeekMode::KeyFrame});
  const NativeMediaGenerationTimeline keyFrame{
      8, MediaSeekMode::KeyFrame, {8, 1}, {6, 1}, {6, 1}, false,
      {{6, 1}, {6, 1}, false}};
  expect(seeking.status == NativeMediaDispatcherSeekStatus::Pending &&
             seeking.timeline == keyFrame &&
             initial.dispatcher->timeline() == accurate &&
             initial.video->flushTimelines ==
                 std::vector<NativeMediaGenerationTimeline>{keyFrame} &&
             initial.audio->flushTimelines ==
                 std::vector<NativeMediaGenerationTimeline>{keyFrame},
         "quiescing seek retains old public timeline and sends the exact "
         "source-proved candidate timeline to both ports");
  const NativeMediaDispatcherStep committed = initial.dispatcher->step();
  expect(committed.action == NativeMediaDispatcherAction::SeekCommitted &&
             initial.dispatcher->timeline() == keyFrame &&
             initial.video->flushTimelines ==
                 std::vector<NativeMediaGenerationTimeline>{keyFrame,
                                                            keyFrame} &&
             initial.audio->flushTimelines ==
                 std::vector<NativeMediaGenerationTimeline>{keyFrame,
                                                            keyFrame},
         "every lifecycle retry receives an identical immutable timeline and "
         "only dual Done publishes it");

  TestRig badOpen = makeRig({});
  badOpen.source->openActualDecodeStart = {1, 1};
  const NativeMediaDispatcherOpenOutcome badOpenOutcome =
      badOpen.dispatcher->openLocalFile("origin.mp4", requiredAvOptions(), 3);
  expect(badOpenOutcome.status == NativeMediaDispatcherOpenStatus::Failed &&
             badOpen.dispatcher->stats().failure ==
                 NativeMediaDispatcherFailure::InvalidTimeline &&
             !badOpen.dispatcher->timeline() &&
             badOpen.video->configureCalls == 0 &&
             badOpen.audio->configureCalls == 0,
         "an unpositioned open whose source decode start is not exact zero "
         "fails before timeline publication or consumer configuration");

  TestRig badSeek = makeRig({});
  openRig(badSeek);
  badSeek.source->seekActualDecodeStart = MediaTime{5, 1};
  const NativeMediaDispatcherSeekOutcome badSeekOutcome =
      badSeek.dispatcher->seek(
          MediaSourceSeekRequest{2, {4, 1}, MediaSeekMode::Accurate});
  expect(badSeekOutcome.status == NativeMediaDispatcherSeekStatus::Failed &&
             badSeek.dispatcher->stats().failure ==
                 NativeMediaDispatcherFailure::InvalidTimeline &&
             badSeek.dispatcher->timeline() ==
                 NativeMediaGenerationTimeline{1, MediaSeekMode::Accurate,
                                               {0, 1}, {0, 1000}, {0, 1},
                                               true,
                                               {{0, 1}, {0, 1}, true}} &&
             badSeek.video->flushCalls == 0 &&
             badSeek.audio->flushCalls == 0,
         "inconsistent source seek facts fail closed before either consumer "
         "sees a new timeline");

  TestRig negativeStart = makeRig({});
  negativeStart.source->openActualDecodeStart = {-1, 1000};
  MediaSourceOpenOptions origin = requiredAvOptions();
  origin.initialPosition =
      MediaSourceInitialPosition{{0, 1}, MediaSeekMode::Accurate};
  const NativeMediaDispatcherOpenOutcome negativeStartOutcome =
      negativeStart.dispatcher->openLocalFile("negative.mp4", origin, 4);
  expect(negativeStartOutcome.status ==
                 NativeMediaDispatcherOpenStatus::Failed &&
             negativeStart.dispatcher->stats().failure ==
                 NativeMediaDispatcherFailure::InvalidTimeline &&
             negativeStart.video->configureCalls == 0 &&
             negativeStart.audio->configureCalls == 0,
         "a negative decode start cannot masquerade as accurate preroll in "
         "the admitted nonnegative presentation timeline");
}

void checkExactAudioGenerationWindows() {
  auto descriptor44100 =
      std::make_shared<MediaSourceDescriptor>(*descriptor());
  descriptor44100->tracks[1] = audioTrack(44'100.0);
  TestRig offGrid44100 = makeRigWithDescriptor(descriptor44100, {});
  offGrid44100.source->openAudioWindow =
      MediaAudioGenerationWindow{{0, 1}, {5513, 44'100}, true};
  MediaSourceOpenOptions options44100 = requiredAvOptions();
  options44100.initialPosition =
      MediaSourceInitialPosition{{1, 8}, MediaSeekMode::Accurate};
  const NativeMediaDispatcherOpenOutcome admitted44100 =
      offGrid44100.dispatcher->openLocalFile(
          "off-grid-44100.mp4", options44100, 1);
  expect(admitted44100.status == NativeMediaDispatcherOpenStatus::Ready &&
             admitted44100.timeline.presentationFloor == MediaTime{1, 8} &&
             admitted44100.timeline.audioWindow.presentationStart ==
                 MediaTime{5513, 44'100},
         "44.1 kHz target 1/8 retains visual T while audio starts at exact "
         "ceil frame 5513");

  MediaSourceOpenOptions offGridOptions = requiredAvOptions();
  offGridOptions.initialPosition =
      MediaSourceInitialPosition{{1, 7}, MediaSeekMode::Accurate};
  TestRig offGrid = makeRig({});
  const NativeMediaDispatcherOpenOutcome admitted =
      offGrid.dispatcher->openLocalFile("off-grid.mp4", offGridOptions, 1);
  expect(admitted.status == NativeMediaDispatcherOpenStatus::Ready &&
             admitted.timeline.presentationFloor == MediaTime{1, 7} &&
             admitted.timeline.audioWindow.presentationStart ==
                 MediaTime{1143, 8000} &&
             exactAudioFrameIndex(
                 admitted.timeline.audioWindow.presentationStart,
                 48'000) == 6858,
         "accurate off-grid target retains exact visual T and independently "
         "ceilings audio to source frame A");

  TestRig missing = makeRig({});
  missing.source->omitOpenAudioWindow = true;
  expect(missing.dispatcher
                 ->openLocalFile("missing-window.mp4", requiredAvOptions(), 1)
                 .status == NativeMediaDispatcherOpenStatus::Failed &&
             missing.dispatcher->stats().failure ==
                 NativeMediaDispatcherFailure::InvalidTimeline &&
             missing.video->configureCalls == 0 &&
             missing.audio->configureCalls == 0,
         "selected audio without a source-proved window fails before either "
         "consumer is exposed");

  const auto rejectAccurateWindow = [](MediaAudioGenerationWindow window) {
    TestRig rig = makeRig({});
    rig.source->openAudioWindow = window;
    MediaSourceOpenOptions options = requiredAvOptions();
    options.initialPosition =
        MediaSourceInitialPosition{{1, 7}, MediaSeekMode::Accurate};
    return rig.dispatcher->openLocalFile("forged-window.mp4", options, 1)
               .status == NativeMediaDispatcherOpenStatus::Failed &&
           rig.dispatcher->stats().failure ==
               NativeMediaDispatcherFailure::InvalidTimeline &&
           rig.audio->configureCalls == 0;
  };
  expect(rejectAccurateWindow({{0, 1}, {6857, 48'000}, true}) &&
             rejectAccurateWindow({{0, 1}, {6859, 48'000}, true}) &&
             rejectAccurateWindow(
                 {{6858, 48'000}, {6857, 48'000}, false}) &&
             rejectAccurateWindow({{1, 7}, {6858, 48'000}, false}) &&
             rejectAccurateWindow(
                 {{0, 1}, {6858, 48'000}, false}),
         "dispatcher rejects floor/late A, D>A, non-grid D, and forged "
         "stream-origin proof");

  TestRig capBoundary = makeRig({});
  capBoundary.source->openAudioWindow =
      MediaAudioGenerationWindow{{0, 1}, {1, 1}, true};
  MediaSourceOpenOptions oneSecond = requiredAvOptions();
  oneSecond.limits.maximumAudioSeekPrerollSeconds = 1;
  oneSecond.initialPosition =
      MediaSourceInitialPosition{{1, 1}, MediaSeekMode::Accurate};
  expect(capBoundary.dispatcher
                 ->openLocalFile("cap-boundary.mp4", oneSecond, 1)
                 .status == NativeMediaDispatcherOpenStatus::Ready,
         "exact one-second audio preroll is admitted at the configured cap");

  TestRig overCap = makeRig({});
  overCap.source->openAudioWindow =
      MediaAudioGenerationWindow{{0, 1}, {48'001, 48'000}, true};
  MediaSourceOpenOptions overOneSecond = oneSecond;
  overOneSecond.initialPosition =
      MediaSourceInitialPosition{{48'001, 48'000},
                                 MediaSeekMode::Accurate};
  expect(overCap.dispatcher
                 ->openLocalFile("over-cap.mp4", overOneSecond, 1)
                 .status == NativeMediaDispatcherOpenStatus::Failed &&
             overCap.audio->configureCalls == 0,
         "audio preroll one frame beyond the exact cap fails closed");

  TestRig missingSeek = makeRig({});
  openRig(missingSeek);
  missingSeek.source->omitSeekAudioWindow = true;
  expect(missingSeek.dispatcher
                 ->seek({2, {1, 7}, MediaSeekMode::Accurate})
                 .status == NativeMediaDispatcherSeekStatus::Failed &&
             missingSeek.video->flushCalls == 0 &&
             missingSeek.audio->flushCalls == 0,
         "accepted source seek cannot omit its immutable audio window");

  TestRig keyFrame = makeRig({});
  openRig(keyFrame);
  keyFrame.source->seekActualDecodeStart = MediaTime{1, 8};
  keyFrame.source->seekAudioWindow =
      MediaAudioGenerationWindow{{1, 8}, {6001, 48'000}, false};
  expect(keyFrame.dispatcher
                 ->seek({2, {1, 7}, MediaSeekMode::KeyFrame})
                 .status == NativeMediaDispatcherSeekStatus::Failed &&
             keyFrame.audio->flushCalls == 0,
         "KeyFrame mode requires exact A=D/RAP and never applies Accurate "
         "target ceiling");

  auto videoOnlyValue =
      std::make_shared<MediaSourceDescriptor>(*descriptor());
  videoOnlyValue->selectedAudio.reset();
  TestRig noAudio = makeRigWithDescriptor(videoOnlyValue, {});
  noAudio.source->openAudioWindow =
      MediaAudioGenerationWindow{{0, 1}, {0, 1}, true};
  MediaSourceOpenOptions videoOnlyOptions;
  videoOnlyOptions.selection.requireVideo = true;
  expect(noAudio.dispatcher
                 ->openLocalFile("video-only.mp4", videoOnlyOptions, 1)
                 .status == NativeMediaDispatcherOpenStatus::Failed,
         "a generation without selected audio rejects a nonempty audio "
         "window instead of publishing stale facts");
}

void checkExactPreEntryCancellationAndPublicationOrder() {
  TestRig opening = makeRig({});
  opening.source->observedDispatcher = opening.dispatcher.get();
  opening.source->cancelAtArmCommit = true;

  const NativeMediaDispatcherOpenOutcome cancelledOpen =
      opening.dispatcher->openLocalFile("cancel-open.mp4",
                                        requiredAvOptions(), 10);
  expect(cancelledOpen.status == NativeMediaDispatcherOpenStatus::Cancelled &&
             opening.source->armCalls == 1 &&
             opening.source->openCalls == 1 &&
             opening.source->dispatcherOperationAtArmCommit == 0 &&
             opening.source->dispatcherOperationAtOpenEntry == 10 &&
             opening.source->armedGeneration == 0 &&
             opening.source->generationHighWater == 10 &&
             opening.dispatcher->stats().operationGeneration == 0,
         "open arms first, publishes the exact operation, and consumes one "
         "pre-entry cancellation");
  expect(opening.source->cancelGenerations ==
                 std::vector<MediaGeneration>{9, 11, 10} &&
             opening.source->effectiveCancelGenerations ==
                 std::vector<MediaGeneration>{10} &&
             opening.video->configureCalls == 0 &&
             opening.audio->configureCalls == 0,
         "open forwards stale, future, and exact nonzero cancels while only "
         "the source accepts the exact armed generation");

  TestRig seeking = makeRig({});
  openRig(seeking);
  seeking.source->observedDispatcher = seeking.dispatcher.get();
  seeking.source->cancelAtArmCommit = true;

  const NativeMediaDispatcherSeekOutcome cancelledSeek =
      seeking.dispatcher->seek(
          MediaSourceSeekRequest{2, {3, 1}, MediaSeekMode::Accurate});
  const NativeMediaDispatcherStats seekStats = seeking.dispatcher->stats();
  expect(cancelledSeek.status == NativeMediaDispatcherSeekStatus::Failed &&
             seeking.source->armCalls == 2 &&
             seeking.source->seekCalls == 1 &&
             seeking.source->dispatcherOperationAtArmCommit == 1 &&
             seeking.source->dispatcherOperationAtSeekEntry == 2 &&
             seeking.source->armedGeneration == 0 &&
             seeking.source->generationHighWater == 2 &&
             seekStats.state == NativeMediaDispatcherState::Failed &&
             seekStats.failure == NativeMediaDispatcherFailure::Seek &&
             seekStats.generation == 1 && seekStats.consumerGeneration == 1 &&
             seekStats.operationGeneration == 0 &&
             seeking.video->flushCalls == 0 &&
             seeking.audio->flushCalls == 0,
         "seek arms first, publishes the next operation before entry, and "
         "fails closed on exact pre-entry cancellation");
  expect(seeking.source->cancelGenerations ==
                 std::vector<MediaGeneration>{1, 3, 2, 2} &&
             seeking.source->effectiveCancelGenerations ==
                 std::vector<MediaGeneration>{2},
         "seek forwards stale, future, and exact nonzero cancels while the "
         "source keeps stale and future generations inert");
}

void checkArmFailureNeverEntersAndHighWaterNeverReuses() {
  TestRig opening = makeRig({});
  opening.source->generationHighWater = 7;
  const NativeMediaDispatcherOpenOutcome rejectedOpen =
      opening.dispatcher->openLocalFile("stale-open.mp4",
                                        requiredAvOptions(), 7);
  const NativeMediaDispatcherStats openStats = opening.dispatcher->stats();
  expect(rejectedOpen.status == NativeMediaDispatcherOpenStatus::Failed &&
             openStats.state == NativeMediaDispatcherState::Failed &&
             openStats.failure == NativeMediaDispatcherFailure::SourceOpen &&
             openStats.operationGeneration == 0 &&
             opening.source->armCalls == 1 &&
             opening.source->armAttempts ==
                 std::vector<MediaGeneration>{7} &&
             opening.source->openCalls == 0 &&
             opening.source->unarmedOperationEntries == 0 &&
             opening.source->cancelGenerations.empty() &&
             opening.source->generationHighWater == 7,
         "an open generation at the source high water fails without entering "
         "or cancelling another operation");

  TestRig seeking = makeRig({});
  openRig(seeking);
  expect(seeking.source->armedGeneration == 0 &&
             seeking.source->generationHighWater == 1,
         "successful open consumes its one arm while retaining high water");
  seeking.source->generationHighWater = 2;
  const NativeMediaDispatcherSeekOutcome rejectedSeek =
      seeking.dispatcher->seek(
          MediaSourceSeekRequest{2, {4, 1}, MediaSeekMode::Accurate});
  const NativeMediaDispatcherStats seekStats = seeking.dispatcher->stats();
  expect(rejectedSeek.status == NativeMediaDispatcherSeekStatus::Failed &&
             seekStats.state == NativeMediaDispatcherState::Failed &&
             seekStats.failure == NativeMediaDispatcherFailure::Seek &&
             seekStats.generation == 1 && seekStats.consumerGeneration == 1 &&
             seekStats.operationGeneration == 0 &&
             seeking.source->armCalls == 2 &&
             seeking.source->armAttempts ==
                 std::vector<MediaGeneration>{1, 2} &&
             seeking.source->seekCalls == 0 &&
             seeking.source->unarmedOperationEntries == 0 &&
             seeking.source->cancelGenerations.empty() &&
             seeking.source->currentGeneration == 1 &&
             seeking.source->sourceOperationGeneration.load(
                 std::memory_order_acquire) == 1 &&
             seeking.video->flushCalls == 0 &&
             seeking.audio->flushCalls == 0,
         "a seek generation at the source high water fails without consuming "
         "an arm, entering seek, or disturbing old media");
}

void checkCapacityGateAndSingleOpen() {
  auto destructions = std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(
      sample(MediaSampleKind::EncodedVideo, 1, 7, destructions));
  TestRig rig = makeRig(std::move(events));
  openRig(rig);

  rig.audio->capacityResult = NativeMediaConsumeResult::Backpressure;
  NativeMediaDispatcherStep blocked = rig.dispatcher->step();
  expect(blocked.action == NativeMediaDispatcherAction::BlockedAudio &&
             rig.source->readCalls == 0,
         "a live audio capacity gate prevents any merged source read");

  rig.audio->capacityResult = NativeMediaConsumeResult::Accepted;
  NativeMediaDispatcherStep delivered = rig.dispatcher->step();
  const NativeMediaDispatcherStats deliveredStats = rig.dispatcher->stats();
  expect(delivered.action == NativeMediaDispatcherAction::VideoSample &&
             rig.source->readCalls == 1 &&
             rig.video->acceptedBytes == std::vector<std::uint8_t>{7} &&
             deliveredStats.pending == NativeMediaPendingKind::None &&
             deliveredStats.pendingGeneration == 0 &&
             deliveredStats.pendingPayloadBytes == 0 &&
             deliveredStats.peakPendingPayloadBytes == 4,
         "one admitted read routes one selected encoded video sample while "
         "recording its same-step transient ownership high water");

  const NativeMediaDispatcherOpenOutcome repeated =
      rig.dispatcher->openLocalFile("again.mp4", requiredAvOptions(), 2);
  expect(repeated.status == NativeMediaDispatcherOpenStatus::Rejected &&
             rig.source->openCalls == 1,
         "dispatcher never opens or probes its sole source twice");
}

void checkLosslessSampleBackpressureAndProtocolGuard() {
  auto destructions = std::make_shared<std::atomic<std::uint64_t>>(0);
  auto byteSizeCalls = std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 19, destructions, 1,
             byteSizeCalls));
  TestRig rig = makeRig(std::move(events));
  rig.audio->sampleResults = {NativeMediaConsumeResult::Backpressure,
                              NativeMediaConsumeResult::Accepted};
  openRig(rig);

  NativeMediaDispatcherStep first = rig.dispatcher->step();
  const std::uint64_t callsAfterStep =
      byteSizeCalls->load(std::memory_order_relaxed);
  NativeMediaDispatcherStats stats = rig.dispatcher->stats();
  expect(first.action == NativeMediaDispatcherAction::BlockedAudio &&
             stats.pending == NativeMediaPendingKind::AudioSample &&
             stats.pendingGeneration == 1 &&
             stats.pendingPayloadBytes == 4 &&
             stats.peakPendingPayloadBytes == 4 &&
             byteSizeCalls->load(std::memory_order_relaxed) == callsAfterStep &&
             rig.source->readCalls == 1 &&
             destructions->load(std::memory_order_relaxed) == 0,
         "audio backpressure retains the exact sole sample lease and stats "
         "reads only cached owner facts");

  NativeMediaDispatcherStep second = rig.dispatcher->step();
  stats = rig.dispatcher->stats();
  expect(second.action == NativeMediaDispatcherAction::AudioSample &&
             stats.pending == NativeMediaPendingKind::None &&
             stats.pendingGeneration == 0 &&
             stats.pendingPayloadBytes == 0 &&
             stats.peakPendingPayloadBytes == 4 &&
             stats.audioSamples == 1 && rig.source->readCalls == 1 &&
             rig.audio->acceptedBytes == std::vector<std::uint8_t>{19} &&
             destructions->load(std::memory_order_relaxed) == 1,
         "retry transfers the original audio sample without a second read");

  auto badDestructions = std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> badEvents;
  badEvents.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 23, badDestructions));
  TestRig bad = makeRig(std::move(badEvents));
  bad.audio->sampleResults = {NativeMediaConsumeResult::Backpressure};
  bad.audio->takeOnBackpressure = true;
  openRig(bad);
  NativeMediaDispatcherStep violated = bad.dispatcher->step();
  const NativeMediaDispatcherStats violatedStats = bad.dispatcher->stats();
  expect(violated.action == NativeMediaDispatcherAction::Failed &&
             violated.failure ==
                 NativeMediaDispatcherFailure::ConsumerProtocol &&
             violatedStats.lifecycle ==
                 NativeMediaDispatcherLifecycleKind::FailureCancel &&
             violatedStats.pendingGeneration == 0 &&
             violatedStats.pendingPayloadBytes == 0 &&
             violatedStats.peakPendingPayloadBytes == 4 &&
             bad.source->readCalls == 1,
         "taking ownership while claiming backpressure fails closed");
  NativeMediaDispatcherStep retired = bad.dispatcher->step();
  expect(retired.action == NativeMediaDispatcherAction::Failed &&
             retired.wait == NativeMediaDispatcherWait::Terminal &&
             bad.source->readCalls == 1,
         "protocol failure retires consumers without reading again");
}

void checkDiscontinuityEndAndPerTrackCapacity() {
  auto destructions = std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(MediaDiscontinuity{1, 1, {5, 1000}});
  events.emplace_back(MediaDiscontinuity{1, 2, {5, 1000}});
  events.emplace_back(MediaEndOfStream{1, 2});
  events.emplace_back(
      sample(MediaSampleKind::EncodedVideo, 1, 31, destructions));
  events.emplace_back(MediaEndOfStream{1, 1});
  events.emplace_back(MediaSourceExhausted{1});
  TestRig rig = makeRig(std::move(events));
  rig.video->discontinuityResult = NativeMediaConsumeResult::Backpressure;
  openRig(rig);

  expect(rig.dispatcher->step().action ==
                 NativeMediaDispatcherAction::BlockedVideo &&
             rig.dispatcher->stats().pending ==
                 NativeMediaPendingKind::VideoDiscontinuity &&
             rig.dispatcher->stats().pendingGeneration == 1 &&
             rig.dispatcher->stats().pendingPayloadBytes == 0 &&
             rig.source->readCalls == 1,
         "discontinuity backpressure retains the sole source event");
  rig.video->discontinuityResult = NativeMediaConsumeResult::Accepted;
  expect(rig.dispatcher->step().action ==
                 NativeMediaDispatcherAction::VideoDiscontinuity &&
             rig.source->readCalls == 1,
         "video discontinuity retries without another source read");
  expect(rig.dispatcher->step().action ==
             NativeMediaDispatcherAction::AudioDiscontinuity,
         "audio discontinuity reaches only the audio consumer");
  expect(rig.dispatcher->step().action ==
             NativeMediaDispatcherAction::AudioEndOfStream,
         "audio EOS is routed exactly once");
  const std::uint64_t audioCapacityAtEnd = rig.audio->capacityCalls;
  rig.audio->capacityResult = NativeMediaConsumeResult::Backpressure;
  expect(rig.dispatcher->step().action ==
             NativeMediaDispatcherAction::VideoSample &&
             rig.audio->capacityCalls == audioCapacityAtEnd,
         "an ended audio track no longer gates remaining video reads");
  expect(rig.dispatcher->step().action ==
             NativeMediaDispatcherAction::VideoEndOfStream,
         "video EOS is routed exactly once");
  NativeMediaDispatcherStep exhausted = rig.dispatcher->step();
  const NativeMediaDispatcherStats stats = rig.dispatcher->stats();
  expect(exhausted.action == NativeMediaDispatcherAction::Exhausted &&
             stats.state == NativeMediaDispatcherState::Exhausted &&
             stats.videoDiscontinuities == 1 &&
             stats.audioDiscontinuities == 1 &&
             stats.videoEndMarkers == 1 && stats.audioEndMarkers == 1 &&
             rig.video->endCalls == 1 && rig.audio->endCalls == 1,
         "source exhaustion requires both exact EOS and drain proofs");
}

// A blocked video consumer must not close the audio lane's source reads. This
// is the structural break in the deadlock cycle "video full -> no reads -> PCM
// ring empties -> audio-owned clock freezes -> video never becomes due -> video
// stays full". The dispatcher absorbs refused video events into a bounded
// per-lane read-ahead queue, keeps pulling, and still routes the queued video
// events in exact source order once the video consumer reopens.
void checkVideoLaneDecouplingKeepsAudioReadsAdmitted() {
  auto destructions = std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(
      sample(MediaSampleKind::EncodedVideo, 1, 11, destructions));
  events.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 21, destructions));
  events.emplace_back(
      sample(MediaSampleKind::EncodedVideo, 1, 12, destructions));
  events.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 22, destructions));
  TestRig rig = makeRig(std::move(events));
  openRig(rig);

  rig.video->capacityResult = NativeMediaConsumeResult::Backpressure;
  rig.video->sampleResults = {NativeMediaConsumeResult::Backpressure};

  const NativeMediaDispatcherStep deferred = rig.dispatcher->step();
  NativeMediaDispatcherStats stats = rig.dispatcher->stats();
  expect(deferred.action == NativeMediaDispatcherAction::BlockedVideo &&
             deferred.wait == NativeMediaDispatcherWait::CallAgain &&
             stats.pending == NativeMediaPendingKind::VideoSample &&
             stats.pendingGeneration == 1 &&
             stats.pendingPayloadBytes == 4 &&
             rig.source->readCalls == 1 &&
             destructions->load(std::memory_order_relaxed) == 0,
         "a refused video sample is deferred losslessly into the video lane "
         "and leaves no head-of-line blocker");

  const NativeMediaDispatcherStep audioThrough = rig.dispatcher->step();
  stats = rig.dispatcher->stats();
  expect(audioThrough.action == NativeMediaDispatcherAction::AudioSample &&
             rig.source->readCalls == 2 &&
             rig.audio->acceptedBytes == std::vector<std::uint8_t>{21} &&
             stats.audioSamples == 1 && stats.videoSamples == 0 &&
             stats.pending == NativeMediaPendingKind::VideoSample &&
             stats.pendingPayloadBytes == 4,
         "a video consumer at capacity does not close the audio lane's reads");

  const NativeMediaDispatcherStep queued = rig.dispatcher->step();
  stats = rig.dispatcher->stats();
  expect(queued.action == NativeMediaDispatcherAction::BlockedVideo &&
             queued.wait == NativeMediaDispatcherWait::CallAgain &&
             rig.source->readCalls == 3 && stats.pendingPayloadBytes == 8 &&
             rig.video->sampleCalls == 1,
         "a second video sample joins the lane without a second consumer "
         "offer, so per-lane order cannot be inverted");

  const NativeMediaDispatcherStep secondAudio = rig.dispatcher->step();
  expect(secondAudio.action == NativeMediaDispatcherAction::AudioSample &&
             rig.source->readCalls == 4 &&
             rig.audio->acceptedBytes ==
                 (std::vector<std::uint8_t>{21, 22}),
         "audio keeps flowing for as long as the video lane owns read-ahead");

  rig.video->capacityResult = NativeMediaConsumeResult::Accepted;
  rig.video->sampleResults.clear();
  const NativeMediaDispatcherStep firstDrain = rig.dispatcher->step();
  expect(firstDrain.action == NativeMediaDispatcherAction::VideoSample &&
             rig.video->acceptedBytes == std::vector<std::uint8_t>{11} &&
             rig.source->readCalls == 4,
         "a reopened video consumer drains the oldest deferred event first "
         "and without another source read");

  const NativeMediaDispatcherStep secondDrain = rig.dispatcher->step();
  stats = rig.dispatcher->stats();
  expect(secondDrain.action == NativeMediaDispatcherAction::VideoSample &&
             rig.video->acceptedBytes ==
                 (std::vector<std::uint8_t>{11, 12}) &&
             stats.pending == NativeMediaPendingKind::None &&
             stats.pendingPayloadBytes == 0 &&
             stats.peakPendingPayloadBytes == 12,
         "the lane drains in exact source order and releases its whole lease, "
         "and the ownership high water counts the head-of-line lease plus the "
         "whole deferred lane");
}

void checkSourceFirstSeekCommitAndFailedSeekPreservation() {
  auto destructions = std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 41, destructions));
  int order = 0;
  TestRig rig = makeRig(std::move(events));
  rig.audio->sampleResults = {NativeMediaConsumeResult::Backpressure};
  rig.video->flushResults = {NativeMediaConsumerProgress::Done};
  rig.audio->flushResults = {NativeMediaConsumerProgress::Quiescing,
                             NativeMediaConsumerProgress::Done};
  rig.source->order = &order;
  rig.video->order = &order;
  rig.audio->order = &order;
  openRig(rig);
  expect(rig.dispatcher->step().action ==
             NativeMediaDispatcherAction::BlockedAudio,
         "seek fixture retains one old-generation sample");

  NativeMediaDispatcherSeekOutcome seeking = rig.dispatcher->seek(
      MediaSourceSeekRequest{2, {3, 1}, MediaSeekMode::Accurate});
  NativeMediaDispatcherStats stats = rig.dispatcher->stats();
  expect(seeking.status == NativeMediaDispatcherSeekStatus::Pending &&
             stats.state == NativeMediaDispatcherState::Seeking &&
             stats.generation == 1 && stats.operationGeneration == 2 &&
             stats.consumerGeneration == 1 &&
             stats.lifecycleTargetGeneration == 2 &&
             stats.lifecycleVideoDone && !stats.lifecycleAudioDone &&
             stats.pending == NativeMediaPendingKind::AudioSample &&
             stats.pendingGeneration == 1 &&
             stats.pendingPayloadBytes == 4 &&
             stats.peakPendingPayloadBytes == 4 &&
             destructions->load(std::memory_order_relaxed) == 0,
         "seek remains unpublished while either consumer flush quiesces");
  expect(rig.source->seekOrder == 1 && rig.video->firstFlushOrder == 2 &&
             rig.audio->firstFlushOrder == 3,
         "source seek succeeds before either consumer flush begins");

  NativeMediaDispatcherStep committed = rig.dispatcher->step();
  stats = rig.dispatcher->stats();
  expect(committed.action == NativeMediaDispatcherAction::SeekCommitted &&
             stats.state == NativeMediaDispatcherState::Ready &&
             stats.generation == 2 && stats.consumerGeneration == 2 &&
             stats.pending == NativeMediaPendingKind::None &&
             stats.pendingGeneration == 0 &&
             stats.pendingPayloadBytes == 0 &&
             stats.peakPendingPayloadBytes == 4 &&
             rig.video->flushCalls == 1 && rig.audio->flushCalls == 2 &&
             rig.video->flushGenerations.front() ==
                 std::pair<MediaGeneration, MediaGeneration>{1, 2} &&
             rig.audio->flushGenerations.front() ==
                 std::pair<MediaGeneration, MediaGeneration>{1, 2} &&
             destructions->load(std::memory_order_relaxed) == 1,
         "both Done facts atomically publish seek and release old pending data");

  auto failedDestructions =
      std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> failedEvents;
  failedEvents.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 43, failedDestructions));
  TestRig failed = makeRig(std::move(failedEvents));
  failed.audio->sampleResults = {NativeMediaConsumeResult::Backpressure};
  failed.source->seekAccepted = false;
  openRig(failed);
  static_cast<void>(failed.dispatcher->step());
  const NativeMediaDispatcherSeekOutcome rejected = failed.dispatcher->seek(
      MediaSourceSeekRequest{2, {4, 1}, MediaSeekMode::Accurate});
  stats = failed.dispatcher->stats();
  expect(rejected.status == NativeMediaDispatcherSeekStatus::Failed &&
             stats.state == NativeMediaDispatcherState::Failed &&
             stats.generation == 1 && stats.consumerGeneration == 1 &&
             stats.pending == NativeMediaPendingKind::AudioSample &&
             stats.pendingGeneration == 1 &&
             stats.pendingPayloadBytes == 4 &&
             stats.peakPendingPayloadBytes == 4 &&
             failed.video->flushCalls == 0 && failed.audio->flushCalls == 0 &&
             failed.video->cancelCalls == 0 &&
             failed.audio->cancelCalls == 0 &&
             failedDestructions->load(std::memory_order_relaxed) == 0,
         "failed source seek preserves the old consumer generation and sample");
  const NativeMediaDispatcherLifecycleOutcome closed =
      failed.dispatcher->close(1);
  expect(closed.status == NativeMediaDispatcherLifecycleStatus::Done &&
             failedDestructions->load(std::memory_order_relaxed) == 1,
         "exact old-generation close retires a failed seek safely");
}

void checkQuiescingCancelAndCloseProofs() {
  auto cancelDestructions =
      std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> cancelEvents;
  cancelEvents.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 51, cancelDestructions));
  TestRig cancelling = makeRig(std::move(cancelEvents));
  cancelling.audio->sampleResults = {NativeMediaConsumeResult::Backpressure};
  cancelling.video->cancelResults = {NativeMediaConsumerProgress::Done};
  cancelling.audio->cancelResults = {
      NativeMediaConsumerProgress::Quiescing,
      NativeMediaConsumerProgress::Done};
  openRig(cancelling);
  static_cast<void>(cancelling.dispatcher->step());

  const NativeMediaDispatcherLifecycleOutcome pendingCancel =
      cancelling.dispatcher->cancel(1);
  NativeMediaDispatcherStats stats = cancelling.dispatcher->stats();
  expect(pendingCancel.status == NativeMediaDispatcherLifecycleStatus::Pending &&
             stats.state == NativeMediaDispatcherState::Cancelling &&
             stats.pending == NativeMediaPendingKind::AudioSample &&
             stats.pendingGeneration == 1 &&
             stats.pendingPayloadBytes == 4 &&
             stats.peakPendingPayloadBytes == 4 &&
             cancelDestructions->load(std::memory_order_relaxed) == 0,
         "cancel does not publish or release pending data while audio quiesces");
  NativeMediaDispatcherStep cancelled = cancelling.dispatcher->step();
  const NativeMediaDispatcherStats cancelledStats =
      cancelling.dispatcher->stats();
  expect(cancelled.action == NativeMediaDispatcherAction::Cancelled &&
             cancelledStats.state ==
                 NativeMediaDispatcherState::Cancelled &&
             cancelledStats.pendingGeneration == 0 &&
             cancelledStats.pendingPayloadBytes == 0 &&
             cancelledStats.peakPendingPayloadBytes == 4 &&
             cancelling.video->cancelCalls == 1 &&
             cancelling.audio->cancelCalls == 2 &&
             cancelDestructions->load(std::memory_order_relaxed) == 1,
         "cancel publishes only after both consumer Done facts");

  auto closeDestructions =
      std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> closeEvents;
  closeEvents.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 53, closeDestructions));
  TestRig closing = makeRig(std::move(closeEvents));
  closing.audio->sampleResults = {NativeMediaConsumeResult::Backpressure};
  closing.video->closeResults = {NativeMediaConsumerProgress::Done};
  closing.audio->closeResults = {NativeMediaConsumerProgress::Quiescing,
                                 NativeMediaConsumerProgress::Done};
  openRig(closing);
  static_cast<void>(closing.dispatcher->step());

  const NativeMediaDispatcherLifecycleOutcome pendingClose =
      closing.dispatcher->close(1);
  stats = closing.dispatcher->stats();
  expect(pendingClose.status == NativeMediaDispatcherLifecycleStatus::Pending &&
             stats.state == NativeMediaDispatcherState::Closing &&
             stats.pending == NativeMediaPendingKind::AudioSample &&
             stats.pendingGeneration == 1 &&
             stats.pendingPayloadBytes == 4 &&
             stats.peakPendingPayloadBytes == 4 &&
             closing.dispatcher->descriptor() != nullptr &&
             closeDestructions->load(std::memory_order_relaxed) == 0,
         "close retains state and ownership while one consumer quiesces");
  NativeMediaDispatcherStep closed = closing.dispatcher->step();
  const NativeMediaDispatcherStats closedStats = closing.dispatcher->stats();
  expect(closed.action == NativeMediaDispatcherAction::Closed &&
             closedStats.state == NativeMediaDispatcherState::Closed &&
             closedStats.pendingGeneration == 0 &&
             closedStats.pendingPayloadBytes == 0 &&
             closedStats.peakPendingPayloadBytes == 4 &&
             closing.dispatcher->descriptor() == nullptr &&
             closing.source->closeCalls == 1 &&
             closing.video->closeCalls == 1 &&
             closing.audio->closeCalls == 2 &&
             closeDestructions->load(std::memory_order_relaxed) == 1,
         "Closed is published only after both consumers explicitly finish");
}

void checkExactTerminalRetirement() {
  auto destructions = std::make_shared<std::atomic<std::uint64_t>>(0);
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(
      sample(MediaSampleKind::EncodedAudio, 2, 61, destructions));
  int order = 0;
  TestRig rig = makeRig(std::move(events));
  rig.audio->sampleResults = {NativeMediaConsumeResult::Backpressure};
  rig.video->retireResults = {NativeMediaConsumerProgress::Done};
  rig.audio->retireResults = {NativeMediaConsumerProgress::Quiescing,
                              NativeMediaConsumerProgress::Done};
  rig.source->order = &order;
  rig.video->order = &order;
  rig.audio->order = &order;
  rig.video->observedDestructions = destructions;
  rig.audio->observedDestructions = destructions;
  openRig(rig);
  expect(rig.dispatcher->step().action ==
             NativeMediaDispatcherAction::BlockedAudio,
         "retirement fixture retains one source-owned payload");

  const NativeMediaDispatcherLifecycleOutcome wrongExpected =
      rig.dispatcher->retire(2, 9);
  const NativeMediaDispatcherLifecycleOutcome staleInvalidation =
      rig.dispatcher->retire(1, 1);
  expect(wrongExpected.status ==
                 NativeMediaDispatcherLifecycleStatus::Rejected &&
             wrongExpected.generation == 9 &&
             staleInvalidation.status ==
                 NativeMediaDispatcherLifecycleStatus::Rejected &&
             staleInvalidation.generation == 1 &&
             rig.source->closeCalls == 0 && rig.video->retireCalls == 0 &&
             rig.audio->retireCalls == 0,
         "wrong owner generation and stale invalidation are entirely inert");

  const NativeMediaDispatcherLifecycleOutcome pending =
      rig.dispatcher->retire(1, 9);
  NativeMediaDispatcherStats stats = rig.dispatcher->stats();
  expect(pending.status == NativeMediaDispatcherLifecycleStatus::Pending &&
             pending.generation == 9 &&
             stats.state == NativeMediaDispatcherState::Retiring &&
             stats.lifecycle == NativeMediaDispatcherLifecycleKind::Retire &&
             stats.lifecycleTargetGeneration == 9 &&
             stats.retirementExpectedGeneration == 1 &&
             stats.retirementInvalidationGeneration == 9 &&
             stats.pending == NativeMediaPendingKind::None &&
             stats.pendingGeneration == 0 &&
             stats.pendingPayloadBytes == 0 &&
             stats.peakPendingPayloadBytes == 4 &&
             rig.source->effectiveCancelGenerations ==
                 std::vector<MediaGeneration>{1} &&
             rig.source->closeCalls == 1 &&
             rig.source->firstCancelOrder != 0 &&
             rig.source->firstCancelOrder < rig.source->firstCloseOrder &&
             rig.source->firstCloseOrder < rig.video->firstRetireOrder &&
             rig.source->firstCloseOrder < rig.audio->firstRetireOrder &&
             rig.video->payloadReleasedAtFirstRetire &&
             rig.audio->payloadReleasedAtFirstRetire &&
             rig.video->retireGenerations ==
                 std::vector<std::pair<MediaGeneration, MediaGeneration>>{
                     {1, 9}} &&
             rig.audio->retireGenerations ==
                 std::vector<std::pair<MediaGeneration, MediaGeneration>>{
                     {1, 9}},
         "terminal retire cancels then closes the source and releases pending "
         "ownership before exact per-port retirement");

  const NativeMediaDispatcherLifecycleOutcome mismatchedRetry =
      rig.dispatcher->retire(1, 10);
  const NativeMediaDispatcherLifecycleOutcome competingClose =
      rig.dispatcher->close(9);
  const NativeMediaDispatcherLifecycleOutcome competingCancel =
      rig.dispatcher->cancel(1);
  const NativeMediaDispatcherSeekOutcome competingSeek = rig.dispatcher->seek(
      MediaSourceSeekRequest{10, {4, 1}, MediaSeekMode::Accurate});
  expect(mismatchedRetry.status ==
                 NativeMediaDispatcherLifecycleStatus::Rejected &&
             mismatchedRetry.generation == 10 &&
             competingClose.status ==
                 NativeMediaDispatcherLifecycleStatus::Rejected &&
             competingCancel.status ==
                 NativeMediaDispatcherLifecycleStatus::Rejected &&
             competingSeek.status == NativeMediaDispatcherSeekStatus::Rejected &&
             rig.dispatcher->stats().state ==
                 NativeMediaDispatcherState::Retiring &&
             rig.dispatcher->stats().lifecycle ==
                 NativeMediaDispatcherLifecycleKind::Retire &&
             rig.source->closeCalls == 1 && rig.video->retireCalls == 1 &&
             rig.audio->retireCalls == 1,
         "mismatched retirement and competing lifecycle commands cannot "
         "disturb the installed retirement pair");

  const NativeMediaDispatcherLifecycleOutcome done =
      rig.dispatcher->retire(1, 9);
  stats = rig.dispatcher->stats();
  expect(done.status == NativeMediaDispatcherLifecycleStatus::Done &&
             done.generation == 9 &&
             stats.state == NativeMediaDispatcherState::Closed &&
             stats.generation == 9 &&
             stats.lifecycle == NativeMediaDispatcherLifecycleKind::None &&
             stats.pendingGeneration == 0 &&
             stats.pendingPayloadBytes == 0 &&
             stats.peakPendingPayloadBytes == 4 &&
             rig.source->closeCalls == 1 && rig.video->retireCalls == 1 &&
             rig.audio->retireCalls == 2,
         "only an exact dual-Done retry publishes Closed at the invalidation");
  const NativeMediaDispatcherLifecycleOutcome repeatedDone =
      rig.dispatcher->retire(1, 9);
  expect(repeatedDone.status == NativeMediaDispatcherLifecycleStatus::Done &&
             repeatedDone.generation == 9 && rig.audio->retireCalls == 2,
         "the completed exact retirement pair is idempotent");

  TestRig seeking = makeRig({});
  seeking.video->flushResults = {NativeMediaConsumerProgress::Quiescing};
  seeking.audio->flushResults = {NativeMediaConsumerProgress::Quiescing};
  openRig(seeking);
  const NativeMediaDispatcherSeekOutcome seekPending = seeking.dispatcher->seek(
      MediaSourceSeekRequest{2, {3, 1}, MediaSeekMode::Accurate});
  expect(seekPending.status == NativeMediaDispatcherSeekStatus::Pending &&
             seeking.dispatcher->stats().generation == 1 &&
             seeking.dispatcher->stats().videoExposedGeneration == 2 &&
             seeking.dispatcher->stats().audioExposedGeneration == 2,
         "a quiescing seek target is recorded as exposed without publication");
  expect(seeking.dispatcher->retire(1, 2).status ==
             NativeMediaDispatcherLifecycleStatus::Rejected,
         "terminal invalidation must be above a pending seek target");
  const NativeMediaDispatcherLifecycleOutcome superseded =
      seeking.dispatcher->retire(1, 7);
  expect(superseded.status == NativeMediaDispatcherLifecycleStatus::Done &&
             superseded.generation == 7 &&
             seeking.video->retireGenerations.back() ==
                 std::pair<MediaGeneration, MediaGeneration>{2, 7} &&
             seeking.audio->retireGenerations.back() ==
                 std::pair<MediaGeneration, MediaGeneration>{2, 7} &&
             seeking.dispatcher->stats().generation == 7 &&
             seeking.dispatcher->timeline() == std::nullopt,
         "terminal retirement supersedes a pending seek and prevents its "
         "candidate facts from ever publishing");

  TestRig partial = makeRig({});
  partial.video->configureResult = NativeMediaConsumeResult::Unsupported;
  const NativeMediaDispatcherOpenOutcome partialOpen =
      partial.dispatcher->openLocalFile("partial.mp4", requiredAvOptions(), 4);
  expect(partialOpen.status == NativeMediaDispatcherOpenStatus::Failed &&
             partial.dispatcher->stats().state ==
                 NativeMediaDispatcherState::Failed &&
             partial.video->configureCalls == 1 &&
             partial.audio->configureCalls == 0,
         "partial configuration fixture exposes only the attempted port");
  const NativeMediaDispatcherLifecycleOutcome partialRetired =
      partial.dispatcher->retire(4, 8);
  expect(partialRetired.status == NativeMediaDispatcherLifecycleStatus::Done &&
             partial.video->retireGenerations.back() ==
                 std::pair<MediaGeneration, MediaGeneration>{4, 8} &&
             partial.audio->retireGenerations.back() ==
                 std::pair<MediaGeneration, MediaGeneration>{0, 8},
         "retirement calls even an unconfigured port with retired zero");
}

void checkFormatChangeFailsClosed() {
  std::vector<MediaSourceReadResult> events;
  events.emplace_back(MediaFormatChanged{1, videoTrack()});
  TestRig rig = makeRig(std::move(events));
  openRig(rig);
  NativeMediaDispatcherStep failed = rig.dispatcher->step();
  expect(failed.action == NativeMediaDispatcherAction::Failed &&
             failed.failure == NativeMediaDispatcherFailure::FormatChanged &&
             rig.dispatcher->stats().state ==
                 NativeMediaDispatcherState::Failed &&
             rig.dispatcher->stats().lifecycle ==
                 NativeMediaDispatcherLifecycleKind::FailureCancel &&
             rig.source->readCalls == 1,
         "midstream format change fails closed instead of rebuilding");
  failed = rig.dispatcher->step();
  expect(failed.action == NativeMediaDispatcherAction::Failed &&
             failed.wait == NativeMediaDispatcherWait::Terminal &&
             rig.source->readCalls == 1,
         "format failure retires both consumers without another source read");
}

}  // namespace

int main() {
  static_assert(
      noexcept(std::declval<const NativeMediaDispatcher&>().stats()));
  static_assert(std::is_trivially_copyable_v<NativeMediaDispatcherStep>);
  static_assert(std::is_trivially_copyable_v<NativeMediaDispatcherStats>);
  static_assert(
      std::is_trivially_copyable_v<NativeMediaDispatcherLifecycleOutcome>);

  checkExactPreEntryCancellationAndPublicationOrder();
  checkArmFailureNeverEntersAndHighWaterNeverReuses();
  checkPreparedContextIdentity();
  checkExactGenerationTimelines();
  checkExactAudioGenerationWindows();
  checkCapacityGateAndSingleOpen();
  checkLosslessSampleBackpressureAndProtocolGuard();
  checkDiscontinuityEndAndPerTrackCapacity();
  checkVideoLaneDecouplingKeepsAudioReadsAdmitted();
  checkSourceFirstSeekCommitAndFailedSeekPreservation();
  checkQuiescingCancelAndCloseProofs();
  checkExactTerminalRetirement();
  checkFormatChangeFailsClosed();
  std::cout << "native media dispatcher checks passed\n";
  return 0;
}
