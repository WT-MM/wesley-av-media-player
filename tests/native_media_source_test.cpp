#include "media/native_media_source.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <barrier>
#include <bit>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <new>
#include <numeric>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

namespace {

using namespace wam::media;

int failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

class TestPayloadStorage final : public MediaPayloadStorage {
 public:
  TestPayloadStorage(std::vector<std::byte> bytes,
                     std::shared_ptr<std::atomic<int>> destructions,
                     std::optional<NativePayloadKind> nativeKind = std::nullopt)
      : bytes_(std::move(bytes)), destructions_(std::move(destructions)),
        native_kind_(nativeKind) {}

  ~TestPayloadStorage() override {
    destructions_->fetch_add(1, std::memory_order_relaxed);
  }

  [[nodiscard]] std::size_t byteSize() const noexcept override {
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
    std::copy_n(bytes_.begin() + static_cast<std::ptrdiff_t>(offset),
                destination.size(), destination.begin());
    return true;
  }

 protected:
  [[nodiscard]] std::optional<NativePayloadKind>
  nativePayloadKind() const noexcept override {
    return native_kind_;
  }

  [[nodiscard]] const void* borrowedNativePayload() const noexcept override {
    return native_kind_ ? this : nullptr;
  }

 private:
  std::vector<std::byte> bytes_;
  std::shared_ptr<std::atomic<int>> destructions_;
  std::optional<NativePayloadKind> native_kind_;
};

class SizeOnlyPayloadStorage final : public MediaPayloadStorage {
 public:
  explicit SizeOnlyPayloadStorage(std::size_t bytes) noexcept : bytes_(bytes) {}

  [[nodiscard]] std::size_t byteSize() const noexcept override {
    return bytes_;
  }
  [[nodiscard]] std::span<const std::byte>
  contiguousBytes() const noexcept override {
    return {};
  }
  [[nodiscard]] bool copyBytes(
      std::size_t, std::span<std::byte>) const noexcept override {
    return false;
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
  std::size_t bytes_{0};
};

MediaPayloadLease sizedPayload(std::size_t bytes) {
  return MediaPayloadLease(std::make_shared<SizeOnlyPayloadStorage>(bytes));
}

MediaTrackDescriptor videoTrack() {
  MediaTrackDescriptor result;
  result.id = 1;
  result.kind = MediaTrackKind::Video;
  result.codec = MediaCodec::H264;
  result.timeBase = {1, 1000};
  result.duration = {10'000, 1000};
  result.codecConfigurationKind = MediaCodecConfigurationKind::AvcC;
  result.codecConfiguration = {std::byte{1}, std::byte{100}};
  MediaVideoFormat video;
  video.codedWidth = 1920;
  video.codedHeight = 1080;
  video.displayWidth = 1920;
  video.displayHeight = 1080;
  video.bitsPerComponent = 8;
  result.video = video;
  return result;
}

MediaTrackDescriptor audioTrack() {
  MediaTrackDescriptor result;
  result.id = 2;
  result.kind = MediaTrackKind::Audio;
  result.codec = MediaCodec::Aac;
  result.timeBase = {1, 48'000};
  result.duration = {480'000, 48'000};
  result.codecConfigurationKind =
      MediaCodecConfigurationKind::AudioMagicCookie;
  result.codecConfiguration = {std::byte{0x12}, std::byte{0x10}};
  result.audio =
      MediaAudioFormat{48'000, 2, 0x61616320, 0, 1024, 0, 0, 0, 0, true};
  return result;
}

MediaSourceDescriptor descriptor() {
  MediaSourceDescriptor result;
  result.duration = {10'000, 1000};
  result.inventory = {.video = 1, .audio = 1, .total = 2};
  result.tracks = {videoTrack(), audioTrack()};
  result.selectedVideo = 1;
  result.selectedAudio = 2;
  return result;
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

struct FakePacket {
  MediaTrackId track{0};
  MediaSampleKind kind{MediaSampleKind::EncodedVideo};
  MediaTime pts{};
  MediaTime dts{};
  MediaTime duration{};
  bool keyFrame{false};
  std::size_t byteCount{0};
  std::byte fill{};
};

struct StagedFakePacket {
  FakePacket packet;
  MediaPayloadLease payload;
};

// A one-shot deterministic stand-in for container/reader work that blocks
// after the operation generation has been published.
struct OperationBlockGate {
  std::atomic<bool> armed{true};
  std::barrier<> published{2};
  std::barrier<> resume{2};
};

class BoundedFakeMediaSource final : public MediaSource {
 public:
  BoundedFakeMediaSource(std::vector<FakePacket> video,
                         std::vector<FakePacket> audio,
                         std::shared_ptr<std::atomic<int>> destructions,
                         std::shared_ptr<OperationBlockGate> openBlock = nullptr,
                         std::shared_ptr<OperationBlockGate> seekBlock = nullptr,
                         MediaTime sourceDuration = {10'000, 1000})
      : video_packets_(std::move(video)), audio_packets_(std::move(audio)),
        destructions_(std::move(destructions)),
        open_block_(std::move(openBlock)), seek_block_(std::move(seekBlock)),
        source_duration_(sourceDuration) {}

  [[nodiscard]] bool
  armOperation(MediaGeneration generation) noexcept override {
    if (generation == 0 || armed_generation_ != 0 ||
        generation <= generation_high_water_) {
      return false;
    }
    generation_high_water_ = generation;
    cancelled_generation_.store(0, std::memory_order_release);
    armed_generation_ = generation;
    operation_generation_.store(generation, std::memory_order_release);
    return true;
  }

  MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path& path, const MediaSourceOpenOptions& options,
      MediaGeneration generation) override {
    MediaSourceOpenOutcome outcome;
    outcome.generation = generation;
    if (!consumeArm(generation)) {
      outcome.error = "fake open was not armed";
      return outcome;
    }
    if (operationCancelled(generation)) {
      generation_ = generation;
      cancelled_ = true;
      outcome.status = MediaSourceOpenStatus::Cancelled;
      withdrawOperation();
      return outcome;
    }
    if (path.empty() || open_ ||
        !validateMediaSourceInitialPosition(options.initialPosition,
                                            &outcome.error)) {
      if (outcome.error.empty()) {
        outcome.error = "invalid fake open";
      }
      restoreCurrentPublication();
      return outcome;
    }

    // armOperation() already exposed this exact cancellation slot. Nothing in
    // the matching operation may clear a latched cancellation.
    dropHeads();
    descriptor_.reset();
    prepared_context_.reset();
    open_ = false;
    cancelled_ = false;
    generation_ = generation;
    limits_ = clampMediaSourceLimits(options.limits);
    video_index_ = 0;
    audio_index_ = 0;
    video_eos_emitted_ = false;
    audio_eos_emitted_ = false;
    if (observeCancellation()) {
      outcome.status = MediaSourceOpenStatus::Cancelled;
      withdrawOperation();
      return outcome;
    }
    if (open_block_ && open_block_->armed.exchange(
                           false, std::memory_order_acq_rel)) {
      open_block_->published.arrive_and_wait();
      open_block_->resume.arrive_and_wait();
    }
    if (observeCancellation()) {
      outcome.status = MediaSourceOpenStatus::Cancelled;
      withdrawOperation();
      return outcome;
    }

    auto openedDescriptor = std::make_shared<MediaSourceDescriptor>(descriptor());
    openedDescriptor->duration = source_duration_;
    for (MediaTrackDescriptor& track : openedDescriptor->tracks) {
      track.duration = source_duration_;
    }
    if (!validateMediaSourceDescriptor(*openedDescriptor, limits_,
                                       &outcome.error)) {
      withdrawOperation();
      return outcome;
    }
    if (options.initialPosition) {
      const auto targetAgainstDuration = compareMediaTime(
          options.initialPosition->target, openedDescriptor->duration);
      if (!targetAgainstDuration ||
          *targetAgainstDuration == MediaTimeOrder::Greater) {
        outcome.status = MediaSourceOpenStatus::Unsupported;
        outcome.error = "initial fake position exceeds duration";
        withdrawOperation();
        return outcome;
      }
      video_index_ = firstAtOrAfter(video_packets_,
                                    options.initialPosition->target);
      audio_index_ = firstAtOrAfter(audio_packets_,
                                    options.initialPosition->target);
    }
    if ((options.selection.requireVideo && !openedDescriptor->selectedVideo) ||
        (options.selection.requireAudio && !openedDescriptor->selectedAudio)) {
      outcome.status = MediaSourceOpenStatus::Unsupported;
      outcome.error = "required fake track is unavailable";
      withdrawOperation();
      return outcome;
    }
    descriptor_ = std::move(openedDescriptor);
    prepared_context_ = std::make_shared<TestPreparedContext>(
        MediaSourceBackendKind::AVFoundation, path, options, descriptor_);
    stageHeads();
    if (observeCancellation()) {
      descriptor_.reset();
      prepared_context_.reset();
      outcome.status = MediaSourceOpenStatus::Cancelled;
      withdrawOperation();
      return outcome;
    }
    open_ = true;
    outcome.status = MediaSourceOpenStatus::Ready;
    outcome.actualDecodeStart = options.initialPosition
                                    ? options.initialPosition->target
                                    : MediaTime{0, 1000};
    outcome.descriptor = descriptor_;
    outcome.preparedContext = prepared_context_;
    return outcome;
  }

  MediaSourceSeekOutcome seek(
      const MediaSourceSeekRequest& request) override {
    MediaSourceSeekOutcome outcome;
    outcome.generation = request.generation;
    if (!consumeArm(request.generation)) {
      outcome.error = "fake seek was not armed";
      return outcome;
    }
    if (operationCancelled(request.generation)) {
      generation_ = request.generation;
      cancelled_ = true;
      outcome.error = "fake seek cancelled before entry";
      withdrawOperation();
      return outcome;
    }
    const std::optional<MediaSourceInitialPosition> position{
        MediaSourceInitialPosition{request.target, request.mode}};
    const auto targetAgainstDuration =
        descriptor_ ? compareMediaTime(request.target, descriptor_->duration)
                    : std::optional<MediaTimeOrder>{};
    if (!open_ || cancelled_ || request.generation <= generation_ ||
        !validateMediaSourceInitialPosition(position, &outcome.error) ||
        !targetAgainstDuration ||
        *targetAgainstDuration == MediaTimeOrder::Greater) {
      if (outcome.error.empty()) {
        outcome.error = "invalid fake seek";
      }
      restoreCurrentPublication();
      return outcome;
    }
    cancelled_ = false;
    generation_ = request.generation;
    if (observeCancellation()) {
      outcome.error = "fake seek cancelled";
      withdrawOperation();
      return outcome;
    }
    if (seek_block_ && seek_block_->armed.exchange(
                           false, std::memory_order_acq_rel)) {
      seek_block_->published.arrive_and_wait();
      seek_block_->resume.arrive_and_wait();
    }
    if (observeCancellation()) {
      outcome.error = "fake seek cancelled";
      withdrawOperation();
      return outcome;
    }
    dropHeads();
    video_index_ = firstAtOrAfter(video_packets_, request.target);
    audio_index_ = firstAtOrAfter(audio_packets_, request.target);
    video_eos_emitted_ = false;
    audio_eos_emitted_ = false;
    stageHeads();
    if (observeCancellation()) {
      outcome.error = "fake seek cancelled";
      withdrawOperation();
      return outcome;
    }
    ++seeks_accepted_;
    outcome.accepted = true;
    outcome.actualDecodeStart = request.target;
    outcome.preparedContext = prepared_context_;
    return outcome;
  }

  MediaSourceReadResult
  readNext(MediaGeneration expectedGeneration) override {
    static_cast<void>(observeCancellation());
    if (!open_ || cancelled_ || expectedGeneration != generation_) {
      return MediaSourceCancelled{expectedGeneration};
    }
    const auto headOrder =
        video_head_ && audio_head_
            ? compareMediaTime(orderTime(video_head_->packet),
                               orderTime(audio_head_->packet))
            : std::optional<MediaTimeOrder>{};
    const bool chooseVideo =
        video_head_ &&
        (!audio_head_ ||
         (headOrder && *headOrder != MediaTimeOrder::Greater));
    if (chooseVideo) {
      MediaSample result = makeSample(std::move(*video_head_));
      video_head_.reset();
      stageVideoHead();
      ++samples_emitted_;
      return result;
    }
    if (audio_head_) {
      MediaSample result = makeSample(std::move(*audio_head_));
      audio_head_.reset();
      stageAudioHead();
      ++samples_emitted_;
      return result;
    }
    if (!video_eos_emitted_) {
      video_eos_emitted_ = true;
      return MediaEndOfStream{generation_, 1};
    }
    if (!audio_eos_emitted_) {
      audio_eos_emitted_ = true;
      return MediaEndOfStream{generation_, 2};
    }
    return MediaSourceExhausted{generation_};
  }

  void requestCancel(MediaGeneration generation) noexcept override {
    if (generation != 0 &&
        operation_generation_.load(std::memory_order_acquire) == generation) {
      // Generations are strictly increasing. A stale canceller that observed
      // the prior operation may arrive late, but it can never overwrite a
      // newer cancellation publication.
      MediaGeneration observed =
          cancelled_generation_.load(std::memory_order_relaxed);
      while (observed < generation &&
             !cancelled_generation_.compare_exchange_weak(
                 observed, generation, std::memory_order_release,
                 std::memory_order_relaxed)) {
      }
    }
  }

  void close() noexcept override {
    operation_generation_.store(0, std::memory_order_release);
    armed_generation_ = 0;
    dropHeads();
    descriptor_.reset();
    prepared_context_.reset();
    open_ = false;
    cancelled_ = true;
  }

  [[nodiscard]] MediaSourceStats stats() const noexcept override {
    MediaSourceStats result;
    result.open = open_;
    result.cancelled = cancelled_;
    result.operationGeneration =
        operation_generation_.load(std::memory_order_acquire);
    result.generation = generation_high_water_;
    result.stagedGeneration =
        video_head_ || audio_head_ ? generation_ : MediaGeneration{0};
    result.stagedVideoHeads = video_head_ ? 1 : 0;
    result.stagedAudioHeads = audio_head_ ? 1 : 0;
    result.stagedPayloadBytes = staged_bytes_;
    result.peakStagedPayloadBytes = peak_staged_bytes_;
    result.samplesEmitted = samples_emitted_;
    result.seeksAccepted = seeks_accepted_;
    return result;
  }

 private:
  [[nodiscard]] bool consumeArm(MediaGeneration generation) noexcept {
    if (armed_generation_ != generation ||
        operation_generation_.load(std::memory_order_acquire) != generation) {
      return false;
    }
    armed_generation_ = 0;
    return true;
  }

  [[nodiscard]] bool operationCancelled(
      MediaGeneration generation) const noexcept {
    return generation != 0 &&
           cancelled_generation_.load(std::memory_order_acquire) == generation;
  }

  void restoreCurrentPublication() noexcept {
    operation_generation_.store(open_ ? generation_ : 0,
                                std::memory_order_release);
  }

  static MediaTime orderTime(const FakePacket& packet) noexcept {
    return packet.dts.valid() ? packet.dts : packet.pts;
  }

  bool observeCancellation() noexcept {
    if (generation_ != 0 &&
        cancelled_generation_.load(std::memory_order_acquire) == generation_) {
      cancelled_ = true;
      operation_generation_.store(0, std::memory_order_release);
      dropHeads();
      return true;
    }
    return false;
  }

  void withdrawOperation() noexcept {
    operation_generation_.store(0, std::memory_order_release);
    dropHeads();
    descriptor_.reset();
    prepared_context_.reset();
    open_ = false;
  }

  static std::size_t firstAtOrAfter(const std::vector<FakePacket>& packets,
                                    MediaTime target) noexcept {
    const auto found = std::find_if(
        packets.begin(), packets.end(), [target](const FakePacket& packet) {
          const auto order = compareMediaTime(packet.pts, target);
          return order && *order != MediaTimeOrder::Less;
        });
    return static_cast<std::size_t>(std::distance(packets.begin(), found));
  }

  void dropHeads() noexcept {
    video_head_.reset();
    audio_head_.reset();
    staged_bytes_ = 0;
  }

  void stageHeads() {
    stageVideoHead();
    stageAudioHead();
  }

  void stageVideoHead() {
    if (!video_head_ && video_index_ < video_packets_.size()) {
      video_head_ = stage(video_packets_[video_index_++]);
      staged_bytes_ += video_head_->payload.byteSize();
      peak_staged_bytes_ = std::max(peak_staged_bytes_, staged_bytes_);
    }
  }

  void stageAudioHead() {
    if (!audio_head_ && audio_index_ < audio_packets_.size()) {
      audio_head_ = stage(audio_packets_[audio_index_++]);
      staged_bytes_ += audio_head_->payload.byteSize();
      peak_staged_bytes_ = std::max(peak_staged_bytes_, staged_bytes_);
    }
  }

  StagedFakePacket stage(const FakePacket& packet) {
    StagedFakePacket result;
    result.packet = packet;
    result.payload = MediaPayloadLease(std::make_shared<TestPayloadStorage>(
        std::vector<std::byte>(packet.byteCount, packet.fill), destructions_,
        NativePayloadKind::CoreMediaSampleBuffer));
    return result;
  }

  MediaSample makeSample(StagedFakePacket staged) {
    const FakePacket& packet = staged.packet;
    const std::size_t bytes = staged.payload.byteSize();
    staged_bytes_ -= bytes;
    MediaSample result;
    result.generation = generation_;
    result.track = packet.track;
    result.kind = packet.kind;
    result.presentationTime = packet.pts;
    result.decodeTime = packet.dts;
    result.duration = packet.duration;
    result.keyFrame = packet.keyFrame;
    result.sampleCount = 1;
    result.payload = std::move(staged.payload);
    return result;
  }

  std::vector<FakePacket> video_packets_;
  std::vector<FakePacket> audio_packets_;
  std::shared_ptr<std::atomic<int>> destructions_;
  std::shared_ptr<OperationBlockGate> open_block_;
  std::shared_ptr<OperationBlockGate> seek_block_;
  MediaTime source_duration_;
  MediaSourceLimits limits_;
  std::shared_ptr<const MediaSourceDescriptor> descriptor_;
  std::shared_ptr<const MediaSourcePreparedContext> prepared_context_;
  std::optional<StagedFakePacket> video_head_;
  std::optional<StagedFakePacket> audio_head_;
  std::size_t video_index_{0};
  std::size_t audio_index_{0};
  std::size_t staged_bytes_{0};
  std::size_t peak_staged_bytes_{0};
  std::uint64_t samples_emitted_{0};
  std::uint64_t seeks_accepted_{0};
  MediaGeneration generation_{0};
  MediaGeneration generation_high_water_{0};
  MediaGeneration armed_generation_{0};
  std::atomic<MediaGeneration> operation_generation_{0};
  std::atomic<MediaGeneration> cancelled_generation_{0};
  bool open_{false};
  bool cancelled_{false};
  bool video_eos_emitted_{false};
  bool audio_eos_emitted_{false};
};

class ThrowingFakeMediaSource final : public MediaSource {
 public:
  [[nodiscard]] bool armOperation(MediaGeneration) noexcept override {
    return true;
  }

  MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path&, const MediaSourceOpenOptions&,
      MediaGeneration) override {
    throw std::bad_alloc();
  }

  MediaSourceSeekOutcome seek(const MediaSourceSeekRequest&) override {
    throw std::runtime_error("fake seek failure");
  }

  MediaSourceReadResult readNext(MediaGeneration) override {
    throw std::bad_alloc();
  }

  void requestCancel(MediaGeneration) noexcept override {}
  void close() noexcept override {}
  [[nodiscard]] MediaSourceStats stats() const noexcept override { return {}; }
};

FakePacket videoPacket(std::int64_t milliseconds, std::uint8_t value) {
  return {1,
          MediaSampleKind::EncodedVideo,
          {milliseconds, 1000},
          {milliseconds, 1000},
          {40, 1000},
          true,
          5,
          std::byte{value}};
}

FakePacket audioPacket(std::int64_t milliseconds, std::uint8_t value) {
  return {2,
          MediaSampleKind::EncodedAudio,
          {milliseconds, 1000},
          {milliseconds, 1000},
          {20, 1000},
          true,
          3,
          std::byte{value}};
}

MediaSample sampleWithSizedPayload(MediaSampleKind kind, MediaTrackId track,
                                   std::size_t bytes) {
  MediaSample sample;
  sample.generation = 1;
  sample.track = track;
  sample.kind = kind;
  sample.presentationTime = {0, 1000};
  sample.sampleCount = 1;
  sample.payload = sizedPayload(bytes);
  return sample;
}

void checkPreparedContextIdentity() {
  auto admitted = std::make_shared<const MediaSourceDescriptor>(descriptor());
  MediaSourceOpenOptions options;
  options.selection.preferredVideo = 1;
  options.selection.preferredAudio = 2;
  options.selection.requireVideo = true;
  options.selection.requireAudio = true;
  options.limits.maximumVideoSampleBytes = 4096;
  options.limits.maximumVideoSeekPrerollSeconds = 0.5;
  options.initialPosition =
      MediaSourceInitialPosition{{3, 1}, MediaSeekMode::Accurate};

  auto context = std::make_shared<const TestPreparedContext>(
      MediaSourceBackendKind::Matroska, "/tmp/context.mkv", options,
      admitted);
  MediaSourceOpenOptions differentPosition = options;
  differentPosition.initialPosition =
      MediaSourceInitialPosition{{7, 1}, MediaSeekMode::KeyFrame};
  expect(context->backendKind() == MediaSourceBackendKind::Matroska &&
             context->localPath() == "/tmp/context.mkv" &&
             context->descriptor().get() == admitted.get() &&
             context->selection().requireAudio &&
             context->limits().maximumVideoSampleBytes == 4096 &&
             context->matchesMainRequest("/tmp/context.mkv",
                                         differentPosition, admitted) &&
             context->matchesPreviewBinding("/tmp/context.mkv", admitted),
         "prepared context owns one immutable backend/path/options/descriptor "
         "identity while generation position remains independent");

  auto equalClone =
      std::make_shared<const MediaSourceDescriptor>(*admitted);
  MediaSourceOpenOptions changedSelection = options;
  changedSelection.selection.requireAudio = false;
  MediaSourceOpenOptions changedLimits = options;
  changedLimits.limits.maximumVideoSampleBytes = 2048;
  expect(!context->matchesMainRequest("/tmp/context.mkv", options,
                                      equalClone) &&
             !context->matchesPreviewBinding("/tmp/context.mkv",
                                              equalClone) &&
             !context->matchesMainRequest("/tmp/other.mkv", options,
                                          admitted) &&
             !context->matchesMainRequest("/tmp/context.mkv",
                                          changedSelection, admitted) &&
             !context->matchesMainRequest("/tmp/context.mkv", changedLimits,
                                          admitted),
         "deep-equal descriptors and changed path, selection, or limits "
         "cannot forge prepared identity");

  MediaSourceOpenOptions callerLoosened = options;
  callerLoosened.limits.maximumTracks =
      MediaSourceLimits::kHardMaximumTracks + 1;
  MediaSourceOpenOptions hardMaximum = options;
  hardMaximum.limits.maximumTracks = MediaSourceLimits::kHardMaximumTracks;
  auto clamped = std::make_shared<const TestPreparedContext>(
      MediaSourceBackendKind::AVFoundation, "/tmp/context.mov",
      callerLoosened, admitted);
  expect(clamped->matchesMainRequest("/tmp/context.mov", hardMaximum,
                                     admitted),
         "prepared identity compares effective clamped limits rather than "
         "untrusted caller maxima");
}

void checkHardLimitClamping() {
  MediaSourceLimits requested;
  requested.maximumTracks = MediaSourceLimits::kHardMaximumTracks + 1;
  requested.maximumCodecConfigurationBytes =
      MediaSourceLimits::kHardMaximumCodecConfigurationBytes + 1;
  requested.maximumVideoSampleBytes =
      MediaSourceLimits::kHardMaximumVideoSampleBytes + 1;
  requested.maximumAudioSampleBytes =
      MediaSourceLimits::kHardMaximumAudioSampleBytes + 1;
  requested.maximumAudioSampleCount =
      MediaSourceLimits::kHardMaximumAudioSampleCount + 1;
  requested.maximumDecodedAudioFrames =
      MediaSourceLimits::kHardMaximumDecodedAudioFrames + 1;
  requested.maximumDecodedAudioBytes =
      MediaSourceLimits::kHardMaximumDecodedAudioBytes + 1;
  requested.maximumTrackTextBytes =
      MediaSourceLimits::kHardMaximumTrackTextBytes + 1;
  requested.maximumCodedWidth =
      MediaSourceLimits::kHardMaximumCodedWidth + 1;
  requested.maximumCodedHeight =
      MediaSourceLimits::kHardMaximumCodedHeight + 1;
  requested.maximumCodedPixels =
      MediaSourceLimits::kHardMaximumCodedPixels + 1;
  requested.maximumAudioChannels =
      MediaSourceLimits::kHardMaximumAudioChannels + 1;
  requested.maximumAudioSampleRate =
      MediaSourceLimits::kHardMaximumAudioSampleRate + 1.0;
  requested.maximumVideoSeekPrerollSeconds =
      MediaSourceLimits::kHardMaximumVideoSeekPrerollSeconds + 1.0;
  requested.maximumAudioSeekPrerollSeconds =
      MediaSourceLimits::kHardMaximumAudioSeekPrerollSeconds + 1U;

  const MediaSourceLimits effective = clampMediaSourceLimits(requested);
  expect(effective.maximumTracks ==
                 MediaSourceLimits::kHardMaximumTracks &&
             effective.maximumCodecConfigurationBytes ==
                 MediaSourceLimits::kHardMaximumCodecConfigurationBytes &&
             effective.maximumVideoSampleBytes ==
                 MediaSourceLimits::kHardMaximumVideoSampleBytes &&
             effective.maximumAudioSampleBytes ==
                 MediaSourceLimits::kHardMaximumAudioSampleBytes &&
             effective.maximumAudioSampleCount ==
                 MediaSourceLimits::kHardMaximumAudioSampleCount &&
             effective.maximumDecodedAudioFrames ==
                 MediaSourceLimits::kHardMaximumDecodedAudioFrames &&
             effective.maximumDecodedAudioBytes ==
                 MediaSourceLimits::kHardMaximumDecodedAudioBytes &&
             effective.maximumTrackTextBytes ==
                 MediaSourceLimits::kHardMaximumTrackTextBytes &&
             effective.maximumCodedWidth ==
                 MediaSourceLimits::kHardMaximumCodedWidth &&
             effective.maximumCodedHeight ==
                 MediaSourceLimits::kHardMaximumCodedHeight &&
             effective.maximumCodedPixels ==
                 MediaSourceLimits::kHardMaximumCodedPixels &&
             effective.maximumAudioChannels ==
                 MediaSourceLimits::kHardMaximumAudioChannels &&
             effective.maximumAudioSampleRate ==
                 MediaSourceLimits::kHardMaximumAudioSampleRate &&
             effective.maximumVideoSeekPrerollSeconds ==
                 MediaSourceLimits::kHardMaximumVideoSeekPrerollSeconds &&
             effective.maximumAudioSeekPrerollSeconds ==
                 MediaSourceLimits::kHardMaximumAudioSeekPrerollSeconds,
         "every caller-loosened v1 limit is clamped to its hard maximum");

  requested.maximumVideoSampleBytes = 4096;
  requested.maximumVideoSeekPrerollSeconds = 0.25;
  requested.maximumAudioSeekPrerollSeconds = 3;
  const MediaSourceLimits tightened = clampMediaSourceLimits(requested);
  expect(tightened.maximumVideoSampleBytes == 4096 &&
             tightened.maximumVideoSeekPrerollSeconds == 0.25 &&
             tightened.maximumAudioSeekPrerollSeconds == 3,
         "callers may still tighten byte and preroll limits");
}

void checkExactAudioFrameGrid() {
  static_assert(noexcept(exactAudioFrameIndex({0, 1}, 48'000)));
  static_assert(noexcept(audioFrameAtOrAfter({0, 1}, 48'000)));
  expect(!exactAudioFrameIndex({1, 8}, 44'100).has_value() &&
             audioFrameAtOrAfter({1, 8}, 44'100) ==
                 MediaTime{5513, 44'100},
         "44.1 kHz off-grid target ceilings to frame 5513 without rounding");
  expect(exactAudioFrameIndex({1, 8}, 48'000) == 6000 &&
             audioFrameAtOrAfter({1, 8}, 48'000) == MediaTime{1, 8},
         "48 kHz on-grid target retains its canonical timestamp");
  expect(exactAudioFrameIndex({-1, 44'100}, 44'100) == -1 &&
             audioFrameAtOrAfter({-1, 88'200}, 44'100) == MediaTime{0, 1} &&
             audioFrameAtOrAfter({-3, 88'200}, 44'100) ==
                 MediaTime{-1, 44'100},
         "signed frame projection uses mathematical ceiling around zero");
  expect(audioFrameAtOrAfter(
             {std::numeric_limits<std::int64_t>::min(), 1}, 1) ==
             MediaTime{std::numeric_limits<std::int64_t>::min(), 1},
         "minimum signed frame canonicalizes without negation overflow");
  expect(!exactAudioFrameIndex(
              {std::numeric_limits<std::int64_t>::max(), 1},
              std::numeric_limits<std::uint32_t>::max())
              .has_value() &&
             !audioFrameAtOrAfter(
                  {std::numeric_limits<std::int64_t>::max(), 1},
                  std::numeric_limits<std::uint32_t>::max())
                  .has_value() &&
             !exactAudioFrameIndex({}, 48'000).has_value() &&
             !audioFrameAtOrAfter({0, 1}, 0).has_value(),
         "invalid and out-of-int64 audio-grid projections fail closed");
}

void checkDescriptorValidation() {
  std::string error;
  MediaSourceDescriptor valid = descriptor();
  expect(validateMediaSourceDescriptor(valid, {}, &error),
         "valid selected A/V descriptor is accepted");
  expect(findMediaTrack(valid, 1) != nullptr &&
             findMediaTrack(valid, 1)->kind == MediaTrackKind::Video,
         "selected video track can be found by stable ID");

  MediaSourceLimits looseLimits;
  looseLimits.maximumTracks = MediaSourceLimits::kHardMaximumTracks + 1;
  looseLimits.maximumCodecConfigurationBytes =
      MediaSourceLimits::kHardMaximumCodecConfigurationBytes + 1;
  looseLimits.maximumVideoSampleBytes =
      MediaSourceLimits::kHardMaximumVideoSampleBytes + 1;
  looseLimits.maximumAudioSampleBytes =
      MediaSourceLimits::kHardMaximumAudioSampleBytes + 1;
  looseLimits.maximumAudioSampleCount =
      MediaSourceLimits::kHardMaximumAudioSampleCount + 1;
  looseLimits.maximumDecodedAudioFrames =
      MediaSourceLimits::kHardMaximumDecodedAudioFrames + 1;
  looseLimits.maximumDecodedAudioBytes =
      MediaSourceLimits::kHardMaximumDecodedAudioBytes + 1;
  looseLimits.maximumTrackTextBytes =
      MediaSourceLimits::kHardMaximumTrackTextBytes + 1;
  looseLimits.maximumCodedWidth =
      MediaSourceLimits::kHardMaximumCodedWidth + 1;
  looseLimits.maximumCodedHeight =
      MediaSourceLimits::kHardMaximumCodedHeight + 1;
  looseLimits.maximumCodedPixels =
      MediaSourceLimits::kHardMaximumCodedPixels + 1;
  looseLimits.maximumAudioChannels =
      MediaSourceLimits::kHardMaximumAudioChannels + 1;
  looseLimits.maximumAudioSampleRate =
      MediaSourceLimits::kHardMaximumAudioSampleRate + 1.0;
  looseLimits.maximumVideoSeekPrerollSeconds =
      MediaSourceLimits::kHardMaximumVideoSeekPrerollSeconds + 1.0;

  MediaSourceDescriptor tooManyTracks;
  tooManyTracks.duration = {0, 1};
  tooManyTracks.inventory.total = static_cast<std::uint8_t>(
      MediaSourceLimits::kHardMaximumTracks);
  tooManyTracks.inventory.metadata = tooManyTracks.inventory.total;
  for (std::size_t index = 0;
       index < MediaSourceLimits::kHardMaximumTracks + 1; ++index) {
    MediaTrackDescriptor track;
    track.id = static_cast<MediaTrackId>(index + 1);
    track.kind = MediaTrackKind::Metadata;
    track.timeBase = {1, 1};
    track.duration = {0, 1};
    tooManyTracks.tracks.push_back(std::move(track));
  }
  expect(!validateMediaSourceDescriptor(tooManyTracks, looseLimits, &error),
         "caller options cannot raise the 64-track admission bound");

  MediaSourceDescriptor inconsistentInventory = descriptor();
  inconsistentInventory.inventory.total = 3;
  expect(!validateMediaSourceDescriptor(inconsistentInventory, {}, &error),
         "track inventory total must equal the fixed kind-count sum");
  inconsistentInventory = descriptor();
  inconsistentInventory.inventory.video = 0;
  inconsistentInventory.inventory.metadata = 1;
  expect(!validateMediaSourceDescriptor(inconsistentInventory, {}, &error),
         "detailed selected tracks cannot exceed inventory kind counts");

  MediaSourceDescriptor missingDuration = descriptor();
  missingDuration.duration = {};
  expect(!validateMediaSourceDescriptor(missingDuration, {}, &error),
         "source duration must be present before Ready");
  MediaSourceDescriptor negativeDuration = descriptor();
  negativeDuration.duration = {-1, 1000};
  expect(!validateMediaSourceDescriptor(negativeDuration, {}, &error),
         "negative source duration is rejected before Ready");
  MediaSourceDescriptor negativeTrackDuration = descriptor();
  negativeTrackDuration.tracks[0].duration = {-1, 1000};
  expect(!validateMediaSourceDescriptor(negativeTrackDuration, {}, &error),
         "negative track duration is rejected before Ready");
  MediaSourceDescriptor noncanonicalTimeBase = descriptor();
  noncanonicalTimeBase.tracks[0].timeBase = {2, 1000};
  expect(!validateMediaSourceDescriptor(noncanonicalTimeBase, {}, &error),
         "track time bases must be positive and reduced");

  MediaSourceDescriptor exactAperture = descriptor();
  exactAperture.tracks[0].video->cleanAperture = MediaCleanAperture{
      {1920, 1}, {1080, 1}, {0, 1}, {0, 1}};
  expect(validateMediaSourceDescriptor(exactAperture, {}, &error) &&
             mediaVideoHasFullCodedAperture(*exactAperture.tracks[0].video) &&
             mediaVideoHasSquarePixels(*exactAperture.tracks[0].video),
         "exact full-coded aperture and square PAR are preserved");
  exactAperture.tracks[0].video->cleanAperture->width = {3839, 2};
  expect(validateMediaSourceDescriptor(exactAperture, {}, &error) &&
             !mediaVideoHasFullCodedAperture(
                 *exactAperture.tracks[0].video),
         "a valid fractional crop is distinguishable from full aperture");
  exactAperture.tracks[0].video->cleanAperture->width = {1920, 0};
  expect(!validateMediaSourceDescriptor(exactAperture, {}, &error),
         "zero-denominator clean aperture is rejected");
  exactAperture = descriptor();
  exactAperture.tracks[0].video->pixelAspectNumerator = 2;
  exactAperture.tracks[0].video->pixelAspectDenominator = 2;
  expect(!validateMediaSourceDescriptor(exactAperture, {}, &error),
         "pixel aspect ratios must be reduced exact integers");

  MediaSourceLimits looseVideoLimits;
  looseVideoLimits.maximumCodedWidth = 4096;
  looseVideoLimits.maximumCodedHeight = 4096;
  looseVideoLimits.maximumCodedPixels = 4096ULL * 4096ULL;
  MediaSourceDescriptor oversizedVideo = descriptor();
  oversizedVideo.tracks[0].video->codedWidth = 1921;
  oversizedVideo.tracks[0].video->displayWidth = 1921;
  expect(!validateMediaSourceDescriptor(oversizedVideo, looseVideoLimits,
                                        &error),
         "v1 coded width remains capped at 1920 even if options are loosened");
  oversizedVideo = descriptor();
  oversizedVideo.tracks[0].video->codedHeight = 1081;
  oversizedVideo.tracks[0].video->displayHeight = 1081;
  expect(!validateMediaSourceDescriptor(oversizedVideo, looseVideoLimits,
                                        &error),
         "v1 coded height and pixel count remain capped at 1080p");

  MediaSourceDescriptor preciseAudioRate = descriptor();
  preciseAudioRate.tracks[1].audio->sampleRate = 48'000.25;
  expect(validateMediaSourceDescriptor(preciseAudioRate, {}, &error),
         "finite positive non-integer ASBD sample rates retain exact identity");
  MediaSourceDescriptor invalidAudioRate = descriptor();
  invalidAudioRate.tracks[1].audio->sampleRate =
      std::numeric_limits<double>::quiet_NaN();
  expect(!validateMediaSourceDescriptor(invalidAudioRate, {}, &error),
         "NaN audio sample rate is rejected before Ready");
  invalidAudioRate = descriptor();
  invalidAudioRate.tracks[1].audio->sampleRate = 0.0;
  expect(!validateMediaSourceDescriptor(invalidAudioRate, {}, &error),
         "zero audio sample rate is rejected before Ready");
  invalidAudioRate = descriptor();
  invalidAudioRate.tracks[1].audio->sampleRate =
      std::numeric_limits<double>::infinity();
  expect(!validateMediaSourceDescriptor(invalidAudioRate, {}, &error),
         "infinite audio sample rate is rejected before Ready");
  invalidAudioRate = descriptor();
  invalidAudioRate.tracks[1].audio->sampleRate = 384'000.5;
  expect(!validateMediaSourceDescriptor(invalidAudioRate, looseLimits,
                                        &error),
         "audio sample rate above 384 kHz is rejected before Ready");
  MediaSourceLimits looseAudioLimits;
  looseAudioLimits.maximumAudioChannels = 16;
  MediaSourceDescriptor excessiveChannels = descriptor();
  excessiveChannels.tracks[1].audio->channels = 9;
  expect(!validateMediaSourceDescriptor(excessiveChannels, looseAudioLimits,
                                        &error),
         "v1 audio admission remains capped at eight channels");

  MediaSourceDescriptor absentLayout = descriptor();
  absentLayout.tracks[1].audio->channelLayoutTag = 0;
  absentLayout.tracks[1].audio->channelLayoutPresent = false;
  expect(validateMediaSourceDescriptor(absentLayout, {}, &error),
         "an absent audio channel layout retains a zero tag without ambiguity");

  MediaSourceDescriptor describedLayout = descriptor();
  describedLayout.tracks[1].audio->channelLayoutTag = 0;
  describedLayout.tracks[1].audio->channelLayoutPresent = true;
  expect(!validateMediaSourceDescriptor(describedLayout, {}, &error) &&
             describedLayout.tracks[1].audio !=
                 absentLayout.tracks[1].audio,
         "a present UseChannelDescriptions layout is distinct and fails closed");

  MediaSourceDescriptor inconsistentAbsentLayout = descriptor();
  inconsistentAbsentLayout.tracks[1].audio->channelLayoutTag = 0x00650002U;
  inconsistentAbsentLayout.tracks[1].audio->channelLayoutPresent = false;
  expect(!validateMediaSourceDescriptor(inconsistentAbsentLayout, {}, &error),
         "a nonzero channel layout tag cannot claim metadata absence");

  MediaSourceDescriptor canonicalStereoLayout = descriptor();
  canonicalStereoLayout.tracks[1].audio->channelLayoutTag = 0x00650002U;
  canonicalStereoLayout.tracks[1].audio->channelLayoutPresent = true;
  expect(validateMediaSourceDescriptor(canonicalStereoLayout, {}, &error),
         "a present canonical stereo layout agrees with two ASBD channels");

  MediaSourceDescriptor canonicalMonoLayout = descriptor();
  canonicalMonoLayout.tracks[1].audio->channels = 1;
  canonicalMonoLayout.tracks[1].audio->channelLayoutTag = 0x00640001U;
  canonicalMonoLayout.tracks[1].audio->channelLayoutPresent = true;
  expect(validateMediaSourceDescriptor(canonicalMonoLayout, {}, &error),
         "a present canonical mono layout agrees with one ASBD channel");

  MediaSourceDescriptor mismatchedTaggedLayout = descriptor();
  mismatchedTaggedLayout.tracks[1].audio->channelLayoutTag = 0x00640001U;
  mismatchedTaggedLayout.tracks[1].audio->channelLayoutPresent = true;
  expect(!validateMediaSourceDescriptor(mismatchedTaggedLayout, {}, &error),
         "a present predefined layout with the wrong channel count is rejected");

  MediaSourceDescriptor missingVariableLayoutCount = descriptor();
  missingVariableLayoutCount.tracks[1].audio->channelLayoutTag = 0x00930000U;
  missingVariableLayoutCount.tracks[1].audio->channelLayoutPresent = true;
  expect(!validateMediaSourceDescriptor(missingVariableLayoutCount, {},
                                        &error),
         "a variable-count layout must encode its actual channel count");

  MediaSourceDescriptor bitmapLayout = descriptor();
  bitmapLayout.tracks[1].audio->channelLayoutTag = 0x00010000U;
  bitmapLayout.tracks[1].audio->channelLayoutPresent = true;
  expect(!validateMediaSourceDescriptor(bitmapLayout, {}, &error),
         "a bitmap-defined layout fails closed without its exact bitmap identity");

  MediaSourceDescriptor reservedStereoCount = descriptor();
  reservedStereoCount.tracks[1].audio->channelLayoutTag = 0xffff0002U;
  reservedStereoCount.tracks[1].audio->channelLayoutPresent = true;
  expect(!validateMediaSourceDescriptor(reservedStereoCount, {}, &error),
         "an unrecognized tag is rejected even when its low bits say stereo");

  MediaSourceDescriptor headphoneStereo = descriptor();
  headphoneStereo.tracks[1].audio->channelLayoutTag = 0x00660002U;
  headphoneStereo.tracks[1].audio->channelLayoutPresent = true;
  expect(!validateMediaSourceDescriptor(headphoneStereo, {}, &error),
         "a noncanonical two-channel layout is outside native audio v1");

  MediaSourceDescriptor oversized = descriptor();
  oversized.tracks[0].codecConfiguration.resize(256U * 1024U + 1U);
  expect(!validateMediaSourceDescriptor(oversized, looseLimits, &error),
         "codec configuration above 256 KiB is rejected");

  MediaSourceDescriptor aggregate = descriptor();
  aggregate.tracks[0].codecConfiguration.resize(200U * 1024U);
  aggregate.tracks[1].codecConfiguration.resize(57U * 1024U);
  expect(!validateMediaSourceDescriptor(aggregate, looseLimits, &error),
         "aggregate codec configuration is bounded");

  MediaSourceDescriptor oversizedText = descriptor();
  oversizedText.tracks[0].label.assign(
      MediaSourceLimits::kHardMaximumTrackTextBytes + 1, 'x');
  expect(!validateMediaSourceDescriptor(oversizedText, looseLimits, &error),
         "caller options cannot raise the 1024-byte track-text bound");

  MediaSourceDescriptor wrongSelection = descriptor();
  wrongSelection.selectedVideo = 2;
  expect(!validateMediaSourceDescriptor(wrongSelection, {}, &error),
         "selected track kind mismatch is rejected");

  MediaSourceDescriptor missingFormatTag = descriptor();
  missingFormatTag.tracks[1].audio->formatTag = 0;
  expect(!validateMediaSourceDescriptor(missingFormatTag, {}, &error),
         "compressed audio preserves a nonzero exact format tag");

  MediaSample oversizedAudioCount;
  oversizedAudioCount.generation = 1;
  oversizedAudioCount.track = 2;
  oversizedAudioCount.kind = MediaSampleKind::EncodedAudio;
  oversizedAudioCount.presentationTime = {0, 48'000};
  oversizedAudioCount.sampleCount = 1025;
  auto destructions = std::make_shared<std::atomic<int>>(0);
  oversizedAudioCount.payload = MediaPayloadLease(
      std::make_shared<TestPayloadStorage>(
          std::vector<std::byte>{std::byte{1}}, destructions));
  expect(!validateMediaSample(oversizedAudioCount, valid, looseLimits,
                              &error),
         "compressed audio sample count above 1024 is rejected");
  oversizedAudioCount.sampleCount = 0;
  expect(!validateMediaSample(oversizedAudioCount, valid, {}, &error),
         "zero-sample markers are not admitted as encoded audio payloads");
  oversizedAudioCount.sampleCount = 1;
  oversizedAudioCount.payload = MediaPayloadLease(
      std::make_shared<TestPayloadStorage>(std::vector<std::byte>{},
                                           destructions));
  expect(!validateMediaSample(oversizedAudioCount, valid, {}, &error),
         "encoded audio with an empty payload is rejected");

  MediaSample oversizedVideoSample = sampleWithSizedPayload(
      MediaSampleKind::EncodedVideo, 1,
      MediaSourceLimits::kHardMaximumVideoSampleBytes + 1);
  expect(!validateMediaSample(oversizedVideoSample, valid, looseLimits,
                              &error),
         "caller options cannot raise the 8 MiB encoded-video bound");
  MediaSample oversizedAudioSample = sampleWithSizedPayload(
      MediaSampleKind::EncodedAudio, 2,
      MediaSourceLimits::kHardMaximumAudioSampleBytes + 1);
  expect(!validateMediaSample(oversizedAudioSample, valid, looseLimits,
                              &error),
         "caller options cannot raise the 256 KiB encoded-audio bound");

  MediaSample excessiveDecodedFrames = sampleWithSizedPayload(
      MediaSampleKind::DecodedAudio, 2, sizeof(float));
  excessiveDecodedFrames.decodedAudioFrames =
      MediaSourceLimits::kHardMaximumDecodedAudioFrames + 1;
  expect(!validateMediaSample(excessiveDecodedFrames, valid, looseLimits,
                              &error),
         "caller options cannot raise the decoded-audio frame bound");
  MediaSample excessiveDecodedBytes = sampleWithSizedPayload(
      MediaSampleKind::DecodedAudio, 2,
      MediaSourceLimits::kHardMaximumDecodedAudioBytes + 1);
  excessiveDecodedBytes.decodedAudioFrames = 1;
  expect(!validateMediaSample(excessiveDecodedBytes, valid, looseLimits,
                              &error),
         "caller options cannot raise the decoded-audio byte bound");

  MediaSample unknownPresentation;
  unknownPresentation.generation = 1;
  unknownPresentation.track = 2;
  unknownPresentation.kind = MediaSampleKind::EncodedAudio;
  unknownPresentation.presentationTime = {};
  unknownPresentation.sampleCount = 1;
  unknownPresentation.payload = MediaPayloadLease(
      std::make_shared<TestPayloadStorage>(
          std::vector<std::byte>{std::byte{1}}, destructions));
  expect(!validateMediaSample(unknownPresentation, valid, {}, &error),
         "A/V sample with unknown presentation time is rejected");

  MediaSourceLimits decodedLimits;
  decodedLimits.maximumDecodedAudioFrames = 8;
  decodedLimits.maximumDecodedAudioBytes = 16;
  MediaSample decodedAudio;
  decodedAudio.generation = 1;
  decodedAudio.track = 2;
  decodedAudio.kind = MediaSampleKind::DecodedAudio;
  decodedAudio.presentationTime = {0, 48'000};
  decodedAudio.sampleCount = 1;
  decodedAudio.decodedAudioFrames = 9;
  decodedAudio.payload = MediaPayloadLease(
      std::make_shared<TestPayloadStorage>(
          std::vector<std::byte>(16, std::byte{1}), destructions));
  expect(!validateMediaSample(decodedAudio, valid, decodedLimits, &error),
         "decoded audio frame count above its bound is rejected");
  decodedAudio.decodedAudioFrames = 8;
  decodedAudio.payload = MediaPayloadLease(
      std::make_shared<TestPayloadStorage>(
          std::vector<std::byte>(17, std::byte{1}), destructions));
  expect(!validateMediaSample(decodedAudio, valid, decodedLimits, &error),
         "decoded audio payload bytes above the bound are rejected");

  const MediaDiscontinuity marker{1, 2, {24'000, 48'000}};
  expect(validateMediaDiscontinuity(marker, valid, &error),
         "zero-sample marker maps to an explicit valid discontinuity event");
  expect(!validateMediaDiscontinuity(
             MediaDiscontinuity{0, 2, {24'000, 48'000}}, valid, &error) &&
             !validateMediaDiscontinuity(
                 MediaDiscontinuity{1, 99, {24'000, 48'000}}, valid,
                 &error) &&
             !validateMediaDiscontinuity(
                 MediaDiscontinuity{1, 2, {24'000, -1}}, valid, &error) &&
             !validateMediaDiscontinuity(MediaDiscontinuity{1, 2, {}}, valid,
                                         &error),
         "discontinuity rejects zero generation, unknown track, and invalid "
         "time");

  expect(!nextMediaGeneration(
              std::numeric_limits<MediaGeneration>::max())
              .has_value(),
         "generation exhaustion fails closed without wrapping");
  expect(nextMediaGeneration(0) == 1,
         "first usable media generation is nonzero");
}

void checkExactMediaTimeOrdering() {
  constexpr std::int64_t beyondDoubleInteger = 9'007'199'254'740'992LL;
  expect(compareMediaTime({beyondDoubleInteger, 1000},
                          {beyondDoubleInteger + 1, 1000}) ==
             MediaTimeOrder::Less,
         "adjacent timestamps above 2^53 remain distinguishable");
  expect(compareMediaTime({beyondDoubleInteger * 2, 2000},
                          {beyondDoubleInteger, 1000}) ==
             MediaTimeOrder::Equal,
         "equivalent large timestamps compare equal across time bases");
  expect(compareMediaTime({beyondDoubleInteger * 2, 2000},
                          {beyondDoubleInteger + 1, 1000}) ==
             MediaTimeOrder::Less,
         "mixed-timescale ordering remains exact above 2^53");
  expect(compareMediaTime({std::numeric_limits<std::int64_t>::max(),
                           std::numeric_limits<std::int32_t>::max()},
                          {std::numeric_limits<std::int64_t>::max() - 1,
                           std::numeric_limits<std::int32_t>::max() - 1}) ==
             MediaTimeOrder::Less,
         "cross multiplication cannot overflow at timestamp limits");
  expect(!compareMediaTime({}, {1, 1}).has_value(),
         "exact ordering rejects an unknown timestamp");

  auto destructions = std::make_shared<std::atomic<int>>(0);
  FakePacket first = videoPacket(0, 1);
  first.pts = {beyondDoubleInteger, 1000};
  first.dts = first.pts;
  FakePacket adjacent = videoPacket(0, 2);
  adjacent.pts = {beyondDoubleInteger + 1, 1000};
  adjacent.dts = adjacent.pts;
  FakePacket laterAudio = audioPacket(0, 9);
  laterAudio.pts = {beyondDoubleInteger + 100, 1000};
  laterAudio.dts = laterAudio.pts;
  BoundedFakeMediaSource source(
      {first, adjacent}, {laterAudio}, destructions, nullptr, nullptr,
      {std::numeric_limits<std::int64_t>::max(), 1});
  expect(source.armOperation(31), "exact fixture open generation arms");
  const MediaSourceOpenOutcome opened =
      source.openLocalFile("exact.mp4", {}, 31);
  expect(opened.status == MediaSourceOpenStatus::Ready,
         "exact seek fixture opens");
  expect(source.armOperation(32), "exact fixture seek generation arms");
  expect(source.seek(MediaSourceSeekRequest{
                         32, {beyondDoubleInteger + 1, 1000},
                         MediaSeekMode::Accurate})
             .accepted,
         "exact seek accepts an adjacent target above 2^53");
  auto result = source.readNext(32);
  expect(std::holds_alternative<MediaSample>(result) &&
             std::get<MediaSample>(result).presentationTime == adjacent.pts &&
             std::get<MediaSample>(result).payload.contiguousBytes().front() ==
                 std::byte{2},
         "exact seek selects the adjacent packet instead of its rounded peer");

  FakePacket laterVideo = adjacent;
  FakePacket earlierAudio = audioPacket(0, 3);
  earlierAudio.pts = {beyondDoubleInteger * 2, 2000};
  earlierAudio.dts = earlierAudio.pts;
  BoundedFakeMediaSource mergeSource({laterVideo}, {earlierAudio},
                                     destructions);
  expect(mergeSource.armOperation(41), "merge fixture generation arms");
  expect(mergeSource.openLocalFile("merge.mp4", {}, 41).status ==
             MediaSourceOpenStatus::Ready,
         "mixed-timescale merge fixture opens");
  auto merged = mergeSource.readNext(41);
  expect(std::holds_alternative<MediaSample>(merged) &&
             std::get<MediaSample>(merged).track == 2,
         "two-head merge uses exact DTS order above 2^53");
}

void checkExactNonnegativeMediaTimeRepresentation() {
  static_assert(noexcept(exactNonnegativeMediaTime(double{})));

  constexpr auto binary64 = [](std::uint64_t bits) noexcept {
    return std::bit_cast<double>(bits);
  };
  const auto expectExact = [&](double input, MediaTime expected,
                               std::uint64_t roundTripBits,
                               const char* message) {
    const auto represented = exactNonnegativeMediaTime(input);
    const auto seconds = represented ? mediaTimeSeconds(*represented)
                                     : std::optional<double>{};
    expect(represented == expected && represented->timescale > 0 &&
               std::gcd(static_cast<std::uint64_t>(represented->value),
                        static_cast<std::uint64_t>(represented->timescale)) ==
                   1 &&
               seconds.has_value() &&
               std::bit_cast<std::uint64_t>(*seconds) == roundTripBits,
           message);
  };

  expectExact(binary64(UINT64_C(0x0000000000000000)), {0, 1},
              UINT64_C(0x0000000000000000),
              "positive zero has one canonical exact representation");
  expectExact(binary64(UINT64_C(0x8000000000000000)), {0, 1},
              UINT64_C(0x0000000000000000),
              "negative zero normalizes to canonical positive zero");
  expectExact(binary64(UINT64_C(0x3ff8000000000000)), {3, 2},
              UINT64_C(0x3ff8000000000000),
              "one and one half reduces to three halves");
  expectExact(binary64(UINT64_C(0x3fc0000000000000)), {1, 8},
              UINT64_C(0x3fc0000000000000),
              "one eighth has its exact power-of-two time base");
  expectExact(binary64(UINT64_C(0x3e10000000000000)),
              {1, INT32_C(1) << 30U}, UINT64_C(0x3e10000000000000),
              "two to the minus thirty fits the maximum power-of-two "
              "timescale");
  expectExact(binary64(UINT64_C(0x43dfffffffffffff)),
              {std::numeric_limits<std::int64_t>::max() - INT64_C(1023), 1},
              UINT64_C(0x43dfffffffffffff),
              "largest binary64 integer below two to the sixty-third fits");

  expect(!exactNonnegativeMediaTime(
              binary64(UINT64_C(0x3e00000000000000))) &&
             !exactNonnegativeMediaTime(
                 binary64(UINT64_C(0x3e18000000000000))) &&
             !exactNonnegativeMediaTime(
                 binary64(UINT64_C(0x3e10000000000001))),
         "denominators beyond int32 reject two^-31, three/two^31, and the "
         "next value above two^-30");
  expect(!exactNonnegativeMediaTime(
              binary64(UINT64_C(0x3fb999999999999a))),
         "the exact binary64 rational for decimal one tenth is rejected");
  expect(!exactNonnegativeMediaTime(
              binary64(UINT64_C(0x0000000000000001))) &&
             !exactNonnegativeMediaTime(
                 binary64(UINT64_C(0x0010000000000000))),
         "subnormal and minimum-normal values exceed the timescale domain");
  expect(!exactNonnegativeMediaTime(
              binary64(UINT64_C(0xbff0000000000000))) &&
             !exactNonnegativeMediaTime(
                 binary64(UINT64_C(0x7ff0000000000000))) &&
             !exactNonnegativeMediaTime(
                 binary64(UINT64_C(0x7ff8000000000000))),
         "negative nonzero, infinity, and NaN values fail closed");
  expect(!exactNonnegativeMediaTime(
              binary64(UINT64_C(0x43e0000000000000))) &&
             !exactNonnegativeMediaTime(
                 binary64(UINT64_C(0x7fefffffffffffff))),
         "two to the sixty-third and maximum binary64 overflow MediaTime");
}

void checkCanonicalMediaFrameConversion() {
  static_assert(noexcept(mediaTimeSecondsAtFrame(
      MediaTime{}, std::uint64_t{}, std::uint32_t{})));

  constexpr MediaTime roundingRegression{189751, 52016};
  const auto canonical =
      mediaTimeSecondsAtFrame(roundingRegression, 0, 48000);
  expect(canonical.has_value() &&
             std::bit_cast<std::uint64_t>(*canonical) ==
                 UINT64_C(0x400d2ef8ad3d2f53) &&
             canonical == mediaTimeSeconds(roundingRegression),
         "canonical conversion correctly rounds the adjacent-double regression");
  expect(canonical ==
             mediaTimeSecondsAtFrame(roundingRegression, 0, 48000),
         "all callers receive one deterministic origin conversion");
  const auto negativeCanonical =
      mediaTimeSeconds({-roundingRegression.value,
                        roundingRegression.timescale});
  expect(negativeCanonical.has_value() &&
             std::bit_cast<std::uint64_t>(*negativeCanonical) ==
                 UINT64_C(0xc00d2ef8ad3d2f53) &&
             mediaTimeSeconds({std::numeric_limits<std::int64_t>::min(), 1}) ==
                 -0x1p+63,
         "signed media-time conversion reuses the magnitude's exact rounding");

  expect(mediaTimeSecondsAtFrame({-1, 2}, 24000, 48000) == 0.0 &&
             mediaTimeSecondsAtFrame({-1, 2}, 24001, 48000) ==
                 1.0 / 48000.0,
         "negative preroll origin converts at and after the zero boundary");
  expect(!mediaTimeSecondsAtFrame({-1, 2}, 23999, 48000).has_value(),
         "negative resulting media time is rejected before clock publication");

  constexpr MediaTime tieToEven{(INT64_C(1) << 53U) + 1,
                                INT32_C(1) << 30U};
  constexpr MediaTime tieAwayFromOdd{(INT64_C(1) << 53U) + 3,
                                     INT32_C(1) << 30U};
  const auto even = mediaTimeSecondsAtFrame(tieToEven, 0, 48000);
  const auto odd = mediaTimeSecondsAtFrame(tieAwayFromOdd, 0, 48000);
  expect(even.has_value() && odd.has_value() &&
             std::bit_cast<std::uint64_t>(*even) ==
                 UINT64_C(0x4160000000000000) &&
             std::bit_cast<std::uint64_t>(*odd) ==
                 UINT64_C(0x4160000000000002),
         "halfway rationals round toward the even binary64 significand");

  const auto maximum = mediaTimeSecondsAtFrame(
      {std::numeric_limits<std::int64_t>::max(),
       std::numeric_limits<std::int32_t>::max()},
      std::numeric_limits<std::uint64_t>::max(),
      std::numeric_limits<std::uint32_t>::max());
  expect(maximum.has_value() && std::isfinite(*maximum),
         "maximum valid inputs stay within checked 128-bit arithmetic");
  expect(maximum.has_value() &&
             std::bit_cast<std::uint64_t>(*maximum) ==
                 UINT64_C(0x4200000000180000),
         "maximum helper-domain rational has an exact finite bit oracle");

  const auto minimum = mediaTimeSecondsAtFrame(
      {-1, INT32_C(1) << 30U}, 4,
      std::numeric_limits<std::uint32_t>::max());
  expect(minimum.has_value() &&
             std::bit_cast<std::uint64_t>(*minimum) ==
                 UINT64_C(0x3c10000000100000) &&
             std::fpclassify(*minimum) == FP_NORMAL,
         "smallest constructed positive domain value remains exactly normal");
  expect(!mediaTimeSecondsAtFrame({}, 0, 48000).has_value() &&
             !mediaTimeSecondsAtFrame({1, -1}, 0, 48000).has_value() &&
             !mediaTimeSecondsAtFrame({1, 1}, 0, 0).has_value(),
         "invalid timescales and sample rates fail closed");

  constexpr MediaTime exactBoundary{41, 4};
  expect(mediaTimeSecondsAtFrame(exactBoundary, 12000, 48000) == 10.5 &&
             mediaTimeSecondsAtFrame(exactBoundary, 12048, 48000) ==
                 10.501,
         "exact cursor boundaries add independently of the media origin");

  constexpr MediaTime collapsed{
      std::numeric_limits<std::int64_t>::max(), 1};
  const auto collapsedStart = mediaTimeSecondsAtFrame(collapsed, 0, 48000);
  const auto collapsedEnd = mediaTimeSecondsAtFrame(collapsed, 1, 48000);
  expect(collapsedStart.has_value() && collapsedEnd.has_value() &&
             *collapsedStart == *collapsedEnd,
         "callers can fail closed when adjacent exact frames collapse in double");
}

void checkPayloadLease() {
  auto destructions = std::make_shared<std::atomic<int>>(0);
  MediaPayloadLease lease(std::make_shared<TestPayloadStorage>(
      std::vector<std::byte>{std::byte{1}, std::byte{2}, std::byte{3}},
      destructions, NativePayloadKind::CoreMediaSampleBuffer));
  MediaPayloadLease retained = lease;
  expect(lease.byteSize() == 3 && lease.contiguousBytes().size() == 3,
         "payload lease exposes bounded immutable bytes");
  std::array<std::byte, 2> copied{};
  expect(lease.copyBytes(1, copied) && copied[0] == std::byte{2} &&
             copied[1] == std::byte{3},
         "payload lease supports checked bounded copying");
  expect(!lease.copyBytes(2, copied), "out-of-range payload copy is rejected");
  expect(lease.borrowNative<NativePayloadKind::CoreMediaSampleBuffer>()
             .has_value(),
         "matching typed native payload borrow succeeds");
  expect(!lease
              .borrowNative<NativePayloadKind::CoreMediaAudioBufferList>()
              .has_value(),
         "wrong native payload kind cannot be borrowed");
  lease.reset();
  expect(destructions->load() == 0,
         "retained payload survives the first lease release");
  retained.reset();
  expect(destructions->load() == 1,
         "payload storage is released exactly once after its last lease");
}

void checkBoundedSource() {
  auto destructions = std::make_shared<std::atomic<int>>(0);
  MediaPayloadLease retainedAfterClose;
  {
    BoundedFakeMediaSource source(
        {videoPacket(0, 1), videoPacket(40, 2), videoPacket(80, 3)},
        {audioPacket(0, 4), audioPacket(20, 5), audioPacket(40, 6)},
        destructions);
    MediaSourceOpenOptions options;
    options.selection.requireAudio = true;
    expect(source.armOperation(1), "bounded source open generation arms");
    const MediaSourceOpenOutcome opened =
        source.openLocalFile("fixture.mp4", options, 1);
    expect(opened.status == MediaSourceOpenStatus::Ready &&
               opened.generation == 1 &&
               opened.preparedContext != nullptr &&
               opened.preparedContext->descriptor().get() ==
                   opened.descriptor.get() &&
               opened.preparedContext->matchesMainRequest(
                   "fixture.mp4", options, opened.descriptor),
           "bounded fake opens one source generation with exact prepared "
           "identity");
    const auto preparedContext = opened.preparedContext;
    MediaSourceStats stats = source.stats();
    expect(stats.operationGeneration == 1 && stats.generation == 1 &&
               stats.stagedGeneration == 1 &&
               stats.stagedVideoHeads == 1 && stats.stagedAudioHeads == 1,
           "source stages exactly one selected video and audio head");
    expect(stats.stagedPayloadBytes == 8,
           "source accounts only its two staged packet heads");

    auto first = source.readNext(1);
    expect(std::holds_alternative<MediaSample>(first),
           "source emits its first staged sample");
    MediaSample sample = std::move(std::get<MediaSample>(first));
    expect(sample.generation == 1 && sample.track == 1,
           "equal timestamps are deterministically video-first");
    expect(opened.descriptor != nullptr &&
               validateMediaSample(sample, *opened.descriptor, options.limits),
           "emitted video packet satisfies the bounded sample contract");
    retainedAfterClose = sample.payload;
    stats = source.stats();
    expect(stats.stagedGeneration == 1 && stats.stagedVideoHeads == 1 &&
               stats.stagedAudioHeads == 1,
           "consuming a head replaces only that stream's capacity-one head");

    expect(source.armOperation(2), "bounded source seek generation arms");
    stats = source.stats();
    expect(stats.generation == 2 && stats.operationGeneration == 2 &&
               stats.stagedGeneration == 1 &&
               stats.stagedPayloadBytes == 8,
           "arming a newer operation advances high water without relabeling "
           "the still-owned prior-generation heads");
    const MediaSourceSeekOutcome seek = source.seek(
        MediaSourceSeekRequest{2, {40, 1000}, MediaSeekMode::Accurate});
    expect(seek.accepted && seek.generation == 2 &&
               seek.preparedContext.get() == preparedContext.get(),
           "strictly newer generation seek preserves exact prepared "
           "identity");
    expect(std::holds_alternative<MediaSourceCancelled>(source.readNext(1)),
           "old generation reads fail closed after seek");
    stats = source.stats();
    expect(stats.generation == 2 && stats.stagedGeneration == 2 &&
               stats.stagedVideoHeads <= 1 && stats.stagedAudioHeads <= 1,
           "seek restages within the exact two-head bound");
    expect(!source.seek(
                      MediaSourceSeekRequest{2, {80, 1000},
                                             MediaSeekMode::Accurate})
                .accepted,
           "same-generation seek cannot mutate the source");

    source.requestCancel(1);
    expect(!source.stats().cancelled,
           "stale cancellation cannot cancel the current generation");
    source.requestCancel(2);
    const auto exactCancellation = source.readNext(2);
    expect(std::holds_alternative<MediaSourceCancelled>(exactCancellation) &&
               source.stats().cancelled &&
               source.stats().stagedGeneration == 0 &&
               source.stats().stagedPayloadBytes == 0,
           "exact-generation cancellation drops both staged heads");
    source.close();
    expect(source.stats().operationGeneration == 0 &&
               source.stats().stagedGeneration == 0 &&
               source.stats().stagedPayloadBytes == 0,
           "close withdraws cancellation publication and staged payload");
  }
  expect(retainedAfterClose && retainedAfterClose.byteSize() == 5,
         "emitted payload lease remains valid after source destruction");
  retainedAfterClose.reset();
  expect(destructions->load() >= 1,
         "retained emitted payload eventually releases after source close");
}

void checkEndOfStreamContract() {
  auto destructions = std::make_shared<std::atomic<int>>(0);
  BoundedFakeMediaSource source({videoPacket(0, 1)}, {audioPacket(0, 2)},
                                destructions);
  MediaSourceOpenOptions options;
  options.selection.requireAudio = true;
  expect(source.armOperation(9), "EOF generation arms");
  const MediaSourceOpenOutcome opened =
      source.openLocalFile("eof.mp4", options, 9);
  expect(opened.status == MediaSourceOpenStatus::Ready,
         "EOF fixture opens successfully");
  expect(std::holds_alternative<MediaSample>(source.readNext(9)) &&
             std::holds_alternative<MediaSample>(source.readNext(9)),
         "both selected stream samples precede EOF markers");
  const auto videoEnd = source.readNext(9);
  const auto audioEnd = source.readNext(9);
  expect(std::holds_alternative<MediaEndOfStream>(videoEnd) &&
             std::get<MediaEndOfStream>(videoEnd).track == 1,
         "selected video emits exactly one track EOF marker");
  expect(std::holds_alternative<MediaEndOfStream>(audioEnd) &&
             std::get<MediaEndOfStream>(audioEnd).track == 2,
         "selected audio emits exactly one track EOF marker");
  expect(std::holds_alternative<MediaSourceExhausted>(source.readNext(9)) &&
             std::holds_alternative<MediaSourceExhausted>(
                 source.readNext(9)),
         "aggregate source exhaustion is idempotent after track EOFs");
}

void checkConcurrentCancellationContract() {
  auto destructions = std::make_shared<std::atomic<int>>(0);
  BoundedFakeMediaSource source({videoPacket(0, 1)}, {audioPacket(0, 2)},
                                destructions);
  MediaSourceOpenOptions options;
  options.selection.requireAudio = true;
  expect(source.armOperation(17), "concurrent cancel generation arms");
  expect(source.openLocalFile("cancel.mp4", options, 17).status ==
             MediaSourceOpenStatus::Ready,
         "concurrent cancellation fixture opens");
  std::barrier rendezvous(2);
  std::thread canceller([&] {
    rendezvous.arrive_and_wait();
    source.requestCancel(17);
  });
  rendezvous.arrive_and_wait();
  canceller.join();
  const auto cancelled = source.readNext(17);
  expect(std::holds_alternative<MediaSourceCancelled>(cancelled) &&
             source.stats().operationGeneration == 0 &&
             source.stats().stagedGeneration == 0 &&
             source.stats().stagedPayloadBytes == 0,
         "any-thread cancel publishes atomically and owner drops both heads");
}

void checkBlockedOpenCancellationAndReopen() {
  auto destructions = std::make_shared<std::atomic<int>>(0);
  auto gate = std::make_shared<OperationBlockGate>();
  BoundedFakeMediaSource source({videoPacket(0, 1)}, {audioPacket(0, 2)},
                                destructions, gate);
  MediaSourceOpenOptions options;
  options.selection.requireAudio = true;
  expect(source.armOperation(51), "blocked open generation arms");
  MediaSourceOpenOutcome cancelledOpen;
  std::thread opener([&] {
    cancelledOpen = source.openLocalFile("blocked.mp4", options, 51);
  });
  gate->published.arrive_and_wait();
  source.requestCancel(51);
  gate->resume.arrive_and_wait();
  opener.join();

  MediaSourceStats stats = source.stats();
  expect(cancelledOpen.status == MediaSourceOpenStatus::Cancelled &&
             cancelledOpen.generation == 51,
         "same-generation cancellation interrupts a blocked open");
  expect(!stats.open && stats.cancelled && stats.operationGeneration == 0 &&
             stats.generation == 51 && stats.stagedGeneration == 0 &&
             stats.stagedPayloadBytes == 0,
         "cancelled open withdraws publication without losing generation high water");

  source.close();
  expect(source.armOperation(52), "reopen generation arms");
  const MediaSourceOpenOutcome reopened =
      source.openLocalFile("reopened.mp4", options, 52);
  stats = source.stats();
  expect(reopened.status == MediaSourceOpenStatus::Ready && stats.open &&
             !stats.cancelled && stats.operationGeneration == 52 &&
             stats.generation == 52 && stats.stagedGeneration == 52,
         "close permits a strictly newer open after blocked-open cancellation");
  source.close();
}

void checkBlockedSeekCancellationAndReopen() {
  auto destructions = std::make_shared<std::atomic<int>>(0);
  auto gate = std::make_shared<OperationBlockGate>();
  BoundedFakeMediaSource source(
      {videoPacket(0, 1), videoPacket(40, 2)},
      {audioPacket(0, 3), audioPacket(20, 4)}, destructions, nullptr, gate);
  MediaSourceOpenOptions options;
  options.selection.requireAudio = true;
  expect(source.armOperation(61), "blocked-seek fixture open arms");
  expect(source.openLocalFile("seek-blocked.mp4", options, 61).status ==
             MediaSourceOpenStatus::Ready,
         "blocked-seek fixture opens");

  MediaSourceSeekOutcome cancelledSeek;
  expect(source.armOperation(62), "blocked seek generation arms");
  std::thread seeker([&] {
    cancelledSeek = source.seek(
        MediaSourceSeekRequest{62, {40, 1000}, MediaSeekMode::Accurate});
  });
  gate->published.arrive_and_wait();
  source.requestCancel(62);
  gate->resume.arrive_and_wait();
  seeker.join();

  MediaSourceStats stats = source.stats();
  expect(!cancelledSeek.accepted && cancelledSeek.generation == 62,
         "same-generation cancellation interrupts a blocked seek");
  expect(!stats.open && stats.cancelled && stats.operationGeneration == 0 &&
             stats.generation == 62 && stats.stagedVideoHeads == 0 &&
             stats.stagedAudioHeads == 0 && stats.stagedGeneration == 0 &&
             stats.stagedPayloadBytes == 0,
         "cancelled seek withdraws publication and heads while retaining high water");

  expect(source.armOperation(63), "post-seek reopen generation arms");
  const MediaSourceOpenOutcome reopened =
      source.openLocalFile("seek-reopened.mp4", options, 63);
  stats = source.stats();
  expect(reopened.status == MediaSourceOpenStatus::Ready && stats.open &&
             !stats.cancelled && stats.operationGeneration == 63 &&
             stats.generation == 63 && stats.stagedGeneration == 63,
         "strictly newer open succeeds after blocked-seek cancellation");
  source.close();
}

void checkInitialPositionContract() {
  std::string error;
  expect(validateMediaSourceInitialPosition(std::nullopt, &error),
         "absent initial position is valid");
  expect(validateMediaSourceInitialPosition(
             MediaSourceInitialPosition{{0, 1}, MediaSeekMode::Accurate},
             &error),
         "exact zero initial position is valid");
  expect(!validateMediaSourceInitialPosition(
             MediaSourceInitialPosition{{-1, 1}, MediaSeekMode::Accurate},
             &error) &&
             !validateMediaSourceInitialPosition(
                 MediaSourceInitialPosition{{0, 0}, MediaSeekMode::Accurate},
                 &error) &&
             !validateMediaSourceInitialPosition(
                 MediaSourceInitialPosition{
                     {0, 1}, static_cast<MediaSeekMode>(0xff)},
                 &error),
         "negative, inexact, and unknown-mode initial positions fail cheaply");

  auto destructions = std::make_shared<std::atomic<int>>(0);
  BoundedFakeMediaSource positioned(
      {videoPacket(0, 1), videoPacket(40, 2), videoPacket(80, 3)},
      {audioPacket(0, 4), audioPacket(20, 5), audioPacket(40, 6)},
      destructions);
  MediaSourceOpenOptions positionedOptions;
  positionedOptions.selection.requireAudio = true;
  positionedOptions.initialPosition =
      MediaSourceInitialPosition{{40, 1000}, MediaSeekMode::Accurate};
  expect(positioned.armOperation(71),
         "initial-position generation arms exactly once");
  const MediaSourceOpenOutcome opened =
      positioned.openLocalFile("positioned.mp4", positionedOptions, 71);
  expect(opened.status == MediaSourceOpenStatus::Ready &&
             opened.actualDecodeStart == MediaTime{40, 1000} &&
             positioned.stats().seeksAccepted == 0,
         "initial position creates the first generation without a seek");
  MediaSourceReadResult first = positioned.readNext(71);
  expect(std::holds_alternative<MediaSample>(first) &&
             std::get<MediaSample>(first).presentationTime ==
                 MediaTime{40, 1000},
         "initial-position admission starts at the requested fake timeline");

  auto invalidGate = std::make_shared<OperationBlockGate>();
  BoundedFakeMediaSource invalid(
      {videoPacket(0, 1)}, {audioPacket(0, 2)}, destructions, invalidGate);
  MediaSourceOpenOptions invalidOptions;
  invalidOptions.initialPosition =
      MediaSourceInitialPosition{{-1, 1000}, MediaSeekMode::Accurate};
  expect(invalid.armOperation(72), "invalid-position generation still arms");
  const MediaSourceOpenOutcome rejected =
      invalid.openLocalFile("invalid.mp4", invalidOptions, 72);
  expect(rejected.status == MediaSourceOpenStatus::Failed &&
             invalidGate->armed.load(std::memory_order_acquire),
         "negative initial position is rejected before blocking work");

  BoundedFakeMediaSource beyond(
      {videoPacket(0, 1)}, {audioPacket(0, 2)}, destructions);
  MediaSourceOpenOptions beyondOptions;
  beyondOptions.initialPosition =
      MediaSourceInitialPosition{{10'001, 1000}, MediaSeekMode::Accurate};
  expect(beyond.armOperation(73), "past-duration generation arms");
  const MediaSourceOpenOutcome pastDuration =
      beyond.openLocalFile("beyond.mp4", beyondOptions, 73);
  expect(pastDuration.status == MediaSourceOpenStatus::Unsupported &&
             !beyond.stats().open &&
             beyond.stats().stagedPayloadBytes == 0,
         "initial position beyond loaded duration fails before staging");
}

void checkPreEntryCancellationArm() {
  auto destructions = std::make_shared<std::atomic<int>>(0);
  auto openGate = std::make_shared<OperationBlockGate>();
  BoundedFakeMediaSource opening(
      {videoPacket(0, 1)}, {audioPacket(0, 2)}, destructions, openGate);
  expect(opening.armOperation(81),
         "pre-entry open reserves its exact generation");
  expect(!opening.armOperation(82),
         "a second arm cannot replace an unconsumed reservation");
  opening.requestCancel(82);
  opening.requestCancel(80);
  expect(!opening.stats().cancelled,
         "future and stale pre-entry cancels remain inert");
  opening.requestCancel(81);
  const MediaSourceOpenOutcome cancelledOpen =
      opening.openLocalFile("pre-entry-open.mp4", {}, 81);
  expect(cancelledOpen.status == MediaSourceOpenStatus::Cancelled &&
             openGate->armed.load(std::memory_order_acquire) &&
             opening.stats().generation == 81,
         "exact pre-entry cancel stops open before blocking and burns high water");
  opening.close();
  expect(!opening.armOperation(81) && opening.armOperation(82),
         "close clears the arm without reusing its generation");
  opening.close();

  auto seekGate = std::make_shared<OperationBlockGate>();
  BoundedFakeMediaSource seeking(
      {videoPacket(0, 1), videoPacket(40, 2)},
      {audioPacket(0, 3), audioPacket(40, 4)}, destructions, nullptr,
      seekGate);
  expect(seeking.armOperation(91), "pre-entry seek fixture open arms");
  expect(seeking.openLocalFile("pre-entry-seek.mp4", {}, 91).status ==
             MediaSourceOpenStatus::Ready,
         "pre-entry seek fixture opens");
  expect(seeking.armOperation(92),
         "pre-entry seek reserves its exact generation");
  seeking.requestCancel(92);
  const MediaSourceSeekOutcome cancelledSeek = seeking.seek(
      MediaSourceSeekRequest{92, {40, 1000}, MediaSeekMode::Accurate});
  expect(!cancelledSeek.accepted &&
             seekGate->armed.load(std::memory_order_acquire) &&
             !seeking.stats().open && seeking.stats().generation == 92,
         "exact pre-entry cancel stops seek before blocking and retires old media");
}

void checkWorkerExceptionBoundaryContract() {
  ThrowingFakeMediaSource source;
  expect(source.armOperation(1), "throwing open generation arms");
  bool openCaught = false;
  try {
    static_cast<void>(
        source.openLocalFile("failure.mp4", {}, MediaGeneration{1}));
  } catch (const std::bad_alloc&) {
    openCaught = true;
  }
  expect(openCaught,
         "allocating source open propagates to the outer worker barrier");

  bool seekCaught = false;
  expect(source.armOperation(2), "throwing seek generation arms");
  try {
    static_cast<void>(source.seek(
        MediaSourceSeekRequest{2, {1, 1}, MediaSeekMode::Accurate}));
  } catch (const std::runtime_error&) {
    seekCaught = true;
  }
  expect(seekCaught,
         "allocating source seek propagates to the outer worker barrier");

  bool readCaught = false;
  try {
    static_cast<void>(source.readNext(2));
  } catch (const std::bad_alloc&) {
    readCaught = true;
  }
  expect(readCaught,
         "allocating source read propagates to the outer worker barrier");
}

}  // namespace

int main() {
  static_assert(!std::is_copy_constructible_v<MediaSample>);
  static_assert(std::is_nothrow_move_constructible_v<MediaSample>);
  static_assert(noexcept(
      std::declval<MediaSource&>().armOperation(MediaGeneration{1})));
  static_assert(!noexcept(std::declval<MediaSource&>().openLocalFile(
      std::declval<const std::filesystem::path&>(),
      std::declval<const MediaSourceOpenOptions&>(), MediaGeneration{1})));
  static_assert(!noexcept(std::declval<MediaSource&>().seek(
      std::declval<const MediaSourceSeekRequest&>())));
  static_assert(!noexcept(
      std::declval<MediaSource&>().readNext(MediaGeneration{1})));
  static_assert(noexcept(
      std::declval<MediaSource&>().requestCancel(MediaGeneration{1})));
  static_assert(noexcept(std::declval<MediaSource&>().close()));
  static_assert(noexcept(std::declval<const MediaSource&>().stats()));
  static_assert(std::is_standard_layout_v<MediaSourceStats>);
  static_assert(std::is_trivially_copyable_v<MediaSourceStats>);
  static_assert(std::is_standard_layout_v<MediaAudioGenerationWindow>);
  static_assert(std::is_trivially_copyable_v<MediaAudioGenerationWindow>);
  checkHardLimitClamping();
  checkExactAudioFrameGrid();
  checkPreparedContextIdentity();
  checkDescriptorValidation();
  checkExactMediaTimeOrdering();
  checkExactNonnegativeMediaTimeRepresentation();
  checkCanonicalMediaFrameConversion();
  checkPayloadLease();
  checkBoundedSource();
  checkEndOfStreamContract();
  checkConcurrentCancellationContract();
  checkBlockedOpenCancellationAndReopen();
  checkBlockedSeekCancellationAndReopen();
  checkInitialPositionContract();
  checkPreEntryCancellationArm();
  checkWorkerExceptionBoundaryContract();
  if (failures != 0) {
    std::cerr << failures << " native media source test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native media source contract tests passed\n";
  return EXIT_SUCCESS;
}
