#include "media/native_media_backend.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <optional>
#include <span>
#include <utility>

namespace {

using namespace wam::media;

[[noreturn]] void fail(const char* message) {
  std::cerr << "FAIL: " << message << '\n';
  std::exit(1);
}

void expect(bool condition, const char* message) {
  if (!condition) {
    fail(message);
  }
}

class TestPayload final : public MediaPayloadStorage {
 public:
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
  std::array<std::byte, 4> bytes_{std::byte{1}, std::byte{2},
                                  std::byte{3}, std::byte{4}};
};

// A descriptor for a codec that carries NO out-of-band configuration record:
// its record is empty and its record kind is None, which is the only correct
// shape for ProRes, Motion JPEG and MPEG-2, and the exact shape a preview
// binding validator that demands a nonempty record refuses.
std::shared_ptr<const MediaSourceDescriptor> recordLessDescriptor(
    MediaCodec codec) {
  MediaVideoFormat format;
  format.codedWidth = 640;
  format.codedHeight = 360;
  format.displayWidth = 640;
  format.displayHeight = 360;
  format.bitsPerComponent = 8;
  format.sampleFormat = MediaVideoSampleFormat::Unknown;

  MediaTrackDescriptor track;
  track.id = 7;
  track.kind = MediaTrackKind::Video;
  track.codec = codec;
  track.timeBase = {1, 1000};
  track.duration = {10, 1};
  track.codecConfigurationKind = MediaCodecConfigurationKind::None;
  track.video = format;

  auto result = std::make_shared<MediaSourceDescriptor>();
  result->duration = {10, 1};
  result->inventory = {.video = 1, .total = 1};
  result->tracks = {std::move(track)};
  result->selectedVideo = 7;
  return result;
}

std::shared_ptr<const MediaSourceDescriptor> descriptor() {
  MediaVideoFormat format;
  format.codedWidth = 640;
  format.codedHeight = 360;
  format.displayWidth = 640;
  format.displayHeight = 360;
  format.bitsPerComponent = 8;
  format.sampleFormat = MediaVideoSampleFormat::Yuv420EightBit;

  MediaTrackDescriptor track;
  track.id = 7;
  track.kind = MediaTrackKind::Video;
  track.codec = MediaCodec::Hevc;
  track.timeBase = {1, 1000};
  track.duration = {10, 1};
  track.codecConfigurationKind = MediaCodecConfigurationKind::HvcC;
  track.codecConfiguration = {std::byte{1}, std::byte{2}};
  track.video = format;

  auto result = std::make_shared<MediaSourceDescriptor>();
  result->duration = {10, 1};
  result->inventory = {.video = 1, .total = 1};
  result->tracks = {std::move(track)};
  result->selectedVideo = 7;
  return result;
}

class TestContext final : public MediaSourcePreparedContext {
 public:
  TestContext(MediaSourceBackendKind kind, std::filesystem::path path,
              const MediaSourceOpenOptions& options,
              std::shared_ptr<const MediaSourceDescriptor> descriptor,
              std::shared_ptr<void> lifetime = {}) noexcept
      : MediaSourcePreparedContext(kind, std::move(path), options,
                                   std::move(descriptor)),
        lifetime_(std::move(lifetime)) {}

 private:
  std::shared_ptr<void> lifetime_;
};

MediaPreviewBinding binding(MediaSourceBackendKind kind,
                            std::shared_ptr<void> lifetime = {}) {
  MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  return {std::make_shared<const TestContext>(
      kind, "/private/tmp/native-media-backend.mkv", options, descriptor(),
      std::move(lifetime))};
}

struct ResourceFacts {
  std::size_t liveResources{0};
  std::size_t peakResources{0};
  std::size_t mainObjects{0};
  std::size_t previewObjects{0};
  void (*afterOperationPublished)(MediaPreviewEpoch, void*) noexcept{nullptr};
  void* publicationContext{nullptr};
};

class ColdMainSource final : public MediaSource {
 public:
  explicit ColdMainSource(ResourceFacts* facts) noexcept : facts_(facts) {
    ++facts_->mainObjects;
  }

  [[nodiscard]] bool armOperation(MediaGeneration generation) noexcept
      override {
    if (generation == 0 || generation <= highWater_ || armed_ != 0) {
      return false;
    }
    highWater_ = generation;
    armed_ = generation;
    return true;
  }
  [[nodiscard]] MediaSourceOpenOutcome openLocalFile(
      const std::filesystem::path&, const MediaSourceOpenOptions&,
      MediaGeneration generation) override {
    MediaSourceOpenOutcome result;
    result.generation = generation;
    result.status = MediaSourceOpenStatus::Unsupported;
    armed_ = 0;
    return result;
  }
  [[nodiscard]] MediaSourceSeekOutcome seek(
      const MediaSourceSeekRequest& request) override {
    MediaSourceSeekOutcome result;
    result.generation = request.generation;
    armed_ = 0;
    return result;
  }
  [[nodiscard]] MediaSourceReadResult readNext(
      MediaGeneration generation) override {
    return MediaSourceExhausted{generation};
  }
  void requestCancel(MediaGeneration) noexcept override {}
  void close() noexcept override { armed_ = 0; }
  [[nodiscard]] MediaSourceStats stats() const noexcept override {
    MediaSourceStats result;
    result.generation = highWater_;
    result.operationGeneration = armed_;
    return result;
  }

 private:
  ResourceFacts* facts_;
  MediaGeneration highWater_{0};
  MediaGeneration armed_{0};
};

class BoundedPreviewSource final : public MediaPreviewSource {
 public:
  BoundedPreviewSource(MediaPreviewBinding binding,
                       ResourceFacts* facts) noexcept
      : context_(std::move(binding.preparedContext)), facts_(facts) {
    ++facts_->previewObjects;
  }
  ~BoundedPreviewSource() override { close(); }

  [[nodiscard]] std::shared_ptr<const MediaSourcePreparedContext>
  preparedContext() const noexcept override {
    return context_;
  }

  [[nodiscard]] MediaPreviewBeginOutcome begin(
      MediaPreviewRequest request) noexcept override {
    MediaPreviewBeginOutcome result;
    result.epoch = request.epoch;
    const MediaPreviewBinding sourceBinding{context_};
    if (!validateMediaPreviewRequest(sourceBinding, request, nullptr) ||
        request.epoch.value <= factsSnapshot_.epochHighWater.value) {
      return result;
    }
    factsSnapshot_.operationEpoch = request.epoch;
    factsSnapshot_.epochHighWater = request.epoch;
    factsSnapshot_.cancelled = false;
    if (facts_->afterOperationPublished != nullptr) {
      facts_->afterOperationPublished(request.epoch,
                                      facts_->publicationContext);
    }
    retireCursorForReplacement();
    if (factsSnapshot_.cancelled) {
      factsSnapshot_.operationEpoch = {};
      result.status = MediaPreviewBeginStatus::Cancelled;
      return result;
    }
    factsSnapshot_.activeEpoch = request.epoch;
    factsSnapshot_.target = request.target;
    factsSnapshot_.actualDecodeStart = {0, 1};
    factsSnapshot_.open = true;
    factsSnapshot_.stagedVideoHeads = 1;
    factsSnapshot_.peakStagedVideoHeads = 1;
    factsSnapshot_.stagedPayloadBytes = 4;
    factsSnapshot_.peakStagedPayloadBytes = 4;
    ended_ = false;
    ++facts_->liveResources;
    facts_->peakResources =
        std::max(facts_->peakResources, facts_->liveResources);
    result.status = MediaPreviewBeginStatus::Ready;
    result.actualDecodeStart = factsSnapshot_.actualDecodeStart;
    return result;
  }

  [[nodiscard]] bool advanceTarget(
      MediaPreviewEpoch expectedEpoch, MediaTime target) noexcept override {
    if (!factsSnapshot_.open || expectedEpoch != factsSnapshot_.activeEpoch ||
        ended_) {
      return false;
    }
    const auto order = compareMediaTime(factsSnapshot_.target, target);
    if (!order || *order == MediaTimeOrder::Greater ||
        !validateMediaPreviewRequest(
            MediaPreviewBinding{context_}, {expectedEpoch, target}, nullptr)) {
      return false;
    }
    factsSnapshot_.target = target;
    ++factsSnapshot_.forwardRetargets;
    return true;
  }

  [[nodiscard]] MediaPreviewReadResult readNext(
      MediaPreviewEpoch expectedEpoch) noexcept override {
    if (!factsSnapshot_.open ||
        expectedEpoch != factsSnapshot_.activeEpoch) {
      return MediaPreviewCancelled{expectedEpoch};
    }
    if (factsSnapshot_.cancelled) {
      closeOperation();
      return MediaPreviewCancelled{expectedEpoch};
    }
    if (factsSnapshot_.stagedVideoHeads != 0) {
      MediaSample sample;
      sample.generation = expectedEpoch.value;
      sample.track = 7;
      sample.kind = MediaSampleKind::EncodedVideo;
      sample.presentationTime = {0, 1};
      sample.decodeTime = {0, 1};
      sample.duration = {1, 1};
      sample.keyFrame = true;
      sample.sampleCount = 1;
      sample.payload =
          MediaPayloadLease(std::make_shared<TestPayload>());
      factsSnapshot_.stagedVideoHeads = 0;
      factsSnapshot_.stagedPayloadBytes = 0;
      ++factsSnapshot_.samplesEmitted;
      return sample;
    }
    ended_ = true;
    return MediaPreviewEndOfStream{expectedEpoch};
  }

  void requestCancel(MediaPreviewEpoch epoch) noexcept override {
    if (epoch == factsSnapshot_.operationEpoch && epoch.valid()) {
      factsSnapshot_.cancelled = true;
    }
  }

  void close() noexcept override { closeOperation(); }

  [[nodiscard]] MediaPreviewSourceFacts facts() const noexcept override {
    return factsSnapshot_;
  }

 private:
  void closeOperation() noexcept {
    retireCursorForReplacement();
    factsSnapshot_.operationEpoch = {};
  }

  void retireCursorForReplacement() noexcept {
    if (factsSnapshot_.open && facts_->liveResources != 0) {
      --facts_->liveResources;
    }
    factsSnapshot_.activeEpoch = {};
    factsSnapshot_.stagedVideoHeads = 0;
    factsSnapshot_.stagedPayloadBytes = 0;
    factsSnapshot_.open = false;
    ended_ = false;
  }

  const std::shared_ptr<const MediaSourcePreparedContext> context_;
  ResourceFacts* facts_;
  MediaPreviewSourceFacts factsSnapshot_{};
  bool ended_{false};
};

struct PublicationProbe {
  MediaPreviewSource* source{nullptr};
  ResourceFacts* resources{nullptr};
  MediaPreviewEpoch expectedOperation{};
  MediaPreviewEpoch expectedActive{};
  bool observed{false};
  bool cancel{false};
};

void observeOperationPublication(MediaPreviewEpoch epoch,
                                 void* context) noexcept {
  auto* probe = static_cast<PublicationProbe*>(context);
  if (probe == nullptr || probe->source == nullptr) {
    return;
  }
  const MediaPreviewSourceFacts facts = probe->source->facts();
  probe->observed = epoch == probe->expectedOperation &&
                    facts.operationEpoch == epoch &&
                    facts.activeEpoch == probe->expectedActive &&
                    probe->resources != nullptr &&
                    probe->resources->liveResources == 1;
  if (probe->cancel) {
    probe->source->requestCancel(epoch);
  }
}

class TestBackendFactory final : public MediaBackendFactory {
 public:
  explicit TestBackendFactory(ResourceFacts* facts) noexcept : facts_(facts) {}

  [[nodiscard]] MediaSourceBackendKind backendKind() const noexcept override {
    return MediaSourceBackendKind::Matroska;
  }
  [[nodiscard]] std::unique_ptr<MediaSource>
  createMainSource() const noexcept override {
    try {
      return std::make_unique<ColdMainSource>(facts_);
    } catch (...) {
      return {};
    }
  }
  [[nodiscard]] std::unique_ptr<MediaPreviewSource>
  createPreviewSource(MediaPreviewBinding sourceBinding) const noexcept
      override {
    if (!mediaPreviewBindingMatchesBackend(sourceBinding, backendKind())) {
      return {};
    }
    try {
      return std::make_unique<BoundedPreviewSource>(
          std::move(sourceBinding), facts_);
    } catch (...) {
      return {};
    }
  }

 private:
  ResourceFacts* facts_;
};

void checkBindingAndEventValidation() {
  const MediaPreviewBinding valid = binding(MediaSourceBackendKind::Matroska);
  expect(validateMediaPreviewBinding(valid) &&
             mediaPreviewBindingMatchesBackend(
                 valid, MediaSourceBackendKind::Matroska) &&
             !mediaPreviewBindingMatchesBackend(
                 valid, MediaSourceBackendKind::AVFoundation) &&
             validateMediaPreviewRequest(valid, {{1}, {10, 1}}) &&
             !validateMediaPreviewRequest(valid, {{0}, {1, 1}}) &&
             !validateMediaPreviewRequest(valid, {{1}, {11, 1}}),
         "preview binding and target validation use exact prepared facts");

  MediaSample sample;
  sample.generation = 3;
  sample.track = 7;
  sample.kind = MediaSampleKind::EncodedVideo;
  sample.presentationTime = {1, 1};
  sample.duration = {1, 1};
  sample.keyFrame = true;
  sample.sampleCount = 1;
  sample.payload = MediaPayloadLease(std::make_shared<TestPayload>());
  expect(validateMediaPreviewSample(sample, valid, {3}) &&
             !validateMediaPreviewSample(sample, valid, {4}),
         "preview samples exact-match private epoch and selected video");
  const MediaDiscontinuity discontinuity{3, 7, {1, 1}};
  expect(validateMediaPreviewDiscontinuity(discontinuity, valid, {3}) &&
             !validateMediaPreviewDiscontinuity(discontinuity, valid, {2}),
         "preview discontinuities exact-match private epoch and video");

  // The record-less codecs. Demanding a nonempty configuration record here
  // refuses every one of them, and the requirement is INVERTED rather than
  // dropped: a record they cannot carry is still a malformed descriptor.
  for (const MediaCodec recordLess :
       {MediaCodec::ProRes, MediaCodec::Mjpeg, MediaCodec::Mpeg2Video}) {
    MediaSourceOpenOptions options;
    options.selection.requireVideo = true;
    const MediaPreviewBinding admitted{std::make_shared<const TestContext>(
        MediaSourceBackendKind::AVFoundation,
        "/private/tmp/native-media-backend.mov", options,
        recordLessDescriptor(recordLess))};
    expect(validateMediaPreviewBinding(admitted),
           "a record-less codec previews with an empty configuration record");

    auto stated = recordLessDescriptor(recordLess);
    auto forged = std::make_shared<MediaSourceDescriptor>(*stated);
    forged->tracks.front().codecConfiguration = {std::byte{1}, std::byte{2}};
    const MediaPreviewBinding refused{std::make_shared<const TestContext>(
        MediaSourceBackendKind::AVFoundation,
        "/private/tmp/native-media-backend.mov", options, std::move(forged))};
    expect(!validateMediaPreviewBinding(refused),
           "a record-less codec presenting a record is still refused");
  }

  expect(!validateMediaPreviewBinding({}),
         "preview rejects a missing prepared context");
  expect(!validateMediaPreviewSample(sample, {}, {3}) &&
             !validateMediaPreviewDiscontinuity(discontinuity, {}, {3}),
         "preview event validators fail closed on a missing binding");
}

void checkColdFactoryAndBoundedLifecycle() {
  ResourceFacts resources;
  TestBackendFactory factory(&resources);
  expect(resources.liveResources == 0 && resources.mainObjects == 0 &&
             resources.previewObjects == 0,
         "factory construction is allocation/resource cold");

  auto main = factory.createMainSource();
  const MediaPreviewBinding admitted =
      binding(MediaSourceBackendKind::Matroska);
  const auto exactContext = admitted.preparedContext;
  auto preview = factory.createPreviewSource(admitted);
  expect(main != nullptr && preview != nullptr &&
             resources.liveResources == 0 && resources.mainObjects == 1 &&
             resources.previewObjects == 1 &&
             preview->preparedContext().get() == exactContext.get(),
         "source construction retains exact identity without media resources");
  expect(factory.createPreviewSource(
             binding(MediaSourceBackendKind::AVFoundation)) == nullptr &&
             resources.liveResources == 0,
         "backend factory rejects a foreign prepared context");

  const MediaPreviewBeginOutcome opened = preview->begin({{1}, {1, 1}});
  MediaPreviewSourceFacts facts = preview->facts();
  expect(opened.status == MediaPreviewBeginStatus::Ready &&
             opened.epoch == MediaPreviewEpoch{1} &&
             resources.liveResources == 1 && resources.peakResources == 1 &&
             facts.stagedVideoHeads == 1 &&
             facts.peakStagedVideoHeads == 1 &&
             facts.stagedPayloadBytes == 4,
         "begin admits exactly one cursor and one compressed video head");
  expect(preview->advanceTarget({1}, {2, 1}) &&
             !preview->advanceTarget({1}, {1, 1}),
         "active preview supports only an exact nondecreasing retarget");

  MediaPreviewReadResult read = preview->readNext({1});
  expect(std::holds_alternative<MediaSample>(read) &&
             validateMediaPreviewSample(std::get<MediaSample>(read), admitted,
                                        {1}) &&
             preview->facts().stagedVideoHeads == 0,
         "first read transfers the exact admitted head without replacement");
  read = preview->readNext({1});
  expect(std::holds_alternative<MediaPreviewEndOfStream>(read),
         "preview emits an exact private-epoch end marker");

  const MediaPreviewBeginOutcome replaced = preview->begin({{2}, {3, 1}});
  expect(replaced.status == MediaPreviewBeginStatus::Ready &&
             resources.liveResources == 1 && resources.peakResources == 1,
         "newer begin retires the old cursor before replacement creation");
  preview->requestCancel({1});
  preview->requestCancel({3});
  expect(!preview->facts().cancelled,
         "stale and future preview cancellation identities are inert");
  preview->requestCancel({2});
  expect(preview->facts().cancelled,
         "matching preview cancellation latches promptly");
  read = preview->readNext({2});
  expect(std::holds_alternative<MediaPreviewCancelled>(read) &&
             resources.liveResources == 0 &&
             preview->preparedContext().get() == exactContext.get(),
         "cancelled read retires resources but preserves prepared identity");
  expect(preview->begin({{2}, {1, 1}}).status ==
             MediaPreviewBeginStatus::Rejected,
         "preview epoch high water cannot be reused");
  preview->close();
  preview->close();
  expect(resources.liveResources == 0 &&
             preview->preparedContext().get() == exactContext.get(),
         "close is idempotent and context-stable");
}

void checkContextLifetime() {
  ResourceFacts resources;
  TestBackendFactory factory(&resources);
  auto lifetime = std::make_shared<int>(7);
  std::weak_ptr<int> weak = lifetime;
  MediaPreviewBinding admitted =
      binding(MediaSourceBackendKind::Matroska, lifetime);
  lifetime.reset();
  auto preview = factory.createPreviewSource(admitted);
  admitted.preparedContext.reset();
  expect(preview != nullptr && !weak.expired(),
         "preview source retains its exact context lifetime");
  preview->close();
  expect(!weak.expired(),
         "resource close does not mutate prepared identity lifetime");
  preview.reset();
  expect(weak.expired(),
         "prepared identity retires with the final source owner");
}

void checkCancellationSlotPrecedesReplacementWork() {
  ResourceFacts resources;
  TestBackendFactory factory(&resources);
  auto preview = factory.createPreviewSource(
      binding(MediaSourceBackendKind::Matroska));
  expect(preview != nullptr &&
             preview->begin({{10}, {1, 1}}).status ==
                 MediaPreviewBeginStatus::Ready &&
             resources.liveResources == 1,
         "publication interleave fixture opens one initial cursor");

  PublicationProbe probe{preview.get(), &resources, {11}, {10}, false, true};
  resources.afterOperationPublished = &observeOperationPublication;
  resources.publicationContext = &probe;
  const MediaPreviewBeginOutcome cancelled =
      preview->begin({{11}, {2, 1}});
  resources.afterOperationPublished = nullptr;
  resources.publicationContext = nullptr;
  const MediaPreviewSourceFacts facts = preview->facts();
  expect(probe.observed &&
             cancelled.status == MediaPreviewBeginStatus::Cancelled &&
             cancelled.epoch == MediaPreviewEpoch{11} &&
             facts.operationEpoch == MediaPreviewEpoch{} &&
             facts.activeEpoch == MediaPreviewEpoch{} &&
             facts.epochHighWater == MediaPreviewEpoch{11} &&
             facts.cancelled && resources.liveResources == 0 &&
             resources.peakResources == 1,
         "new begin publishes exact cancellation before retiring the old "
         "cursor and creates no replacement after an interleaved cancel");
  expect(preview->begin({{11}, {2, 1}}).status ==
             MediaPreviewBeginStatus::Rejected,
         "interleaved cancellation still burns the preview epoch high water");
}

}  // namespace

int main() {
  checkBindingAndEventValidation();
  checkColdFactoryAndBoundedLifecycle();
  checkContextLifetime();
  checkCancellationSlotPrecedesReplacementWork();
  std::cout << "native media backend contract checks passed\n";
  return 0;
}
