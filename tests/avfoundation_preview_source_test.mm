#include "platform/macos/avfoundation_preview_source.hpp"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace {

using namespace wam::macos;
using namespace wam::media;

int failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

constexpr std::array<std::uint8_t, 22> kAvcC{
    0x01, 0x42, 0x00, 0x1e, 0xff, 0xe1, 0x00, 0x08, 0x67, 0x42, 0x00,
    0x1e, 0x80, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x68, 0x00, 0x00};

class OwnedFormat final {
 public:
  explicit OwnedFormat(CMFormatDescriptionRef value) noexcept : value_(value) {}
  OwnedFormat(const OwnedFormat&) = delete;
  OwnedFormat& operator=(const OwnedFormat&) = delete;
  ~OwnedFormat() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }
  [[nodiscard]] CMFormatDescriptionRef get() const noexcept { return value_; }

 private:
  CMFormatDescriptionRef value_{nullptr};
};

class OwnedSample final {
 public:
  explicit OwnedSample(CMSampleBufferRef value) noexcept : value_(value) {}
  OwnedSample(const OwnedSample&) = delete;
  OwnedSample& operator=(const OwnedSample&) = delete;
  ~OwnedSample() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }
  [[nodiscard]] CMSampleBufferRef get() const noexcept { return value_; }

 private:
  CMSampleBufferRef value_{nullptr};
};

OwnedFormat makeFormat() {
  CFDataRef atom = CFDataCreate(kCFAllocatorDefault, kAvcC.data(),
                                static_cast<CFIndex>(kAvcC.size()));
  CFMutableDictionaryRef atoms = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(atoms, CFSTR("avcC"), atom);
  CFMutableDictionaryRef extensions = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms, atoms);
  CMVideoFormatDescriptionRef format = nullptr;
  const OSStatus status = CMVideoFormatDescriptionCreate(
      kCFAllocatorDefault, kCMVideoCodecType_H264, 16, 16, extensions,
      &format);
  CFRelease(extensions);
  CFRelease(atoms);
  CFRelease(atom);
  expect(status == noErr && format != nullptr,
         "fixture video format should be created");
  return OwnedFormat(format);
}

OwnedSample makeSample(CMFormatDescriptionRef format, CMTime pts,
                       CMTime duration, bool keyFrame = true) {
  constexpr std::size_t kBytes = 32;
  CMBlockBufferRef block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, kBytes, kCFAllocatorDefault, nullptr, 0,
      kBytes, 0, &block);
  expect(status == noErr && block != nullptr,
         "fixture block should be created");
  const std::array<std::byte, kBytes> bytes{};
  status = CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, bytes.size());
  expect(status == noErr, "fixture bytes should be installed");
  const CMSampleTimingInfo timing{duration, pts, kCMTimeInvalid};
  constexpr std::size_t kSampleSize = kBytes;
  CMSampleBufferRef sample = nullptr;
  status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, format, 1, 1, &timing, 1, &kSampleSize,
      &sample);
  CFRelease(block);
  expect(status == noErr && sample != nullptr,
         "fixture sample should be created");
  if (!keyFrame && sample != nullptr) {
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sample, true);
    auto dictionary = static_cast<CFMutableDictionaryRef>(
        const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_NotSync,
                         kCFBooleanTrue);
  }
  return OwnedSample(sample);
}

OwnedSample makeDiscontinuity(CMTime pts) {
  const CMSampleTimingInfo timing{kCMTimeInvalid, pts, kCMTimeInvalid};
  CMSampleBufferRef sample = nullptr;
  const OSStatus status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, nullptr, nullptr, 0, 1, &timing, 0, nullptr,
      &sample);
  expect(status == noErr && sample != nullptr &&
             CMSampleBufferGetNumSamples(sample) == 0,
         "fixture discontinuity should be created");
  return OwnedSample(sample);
}

std::shared_ptr<const MediaSourceDescriptor> descriptor() {
  auto result = std::make_shared<MediaSourceDescriptor>();
  result->duration = {60, 1};
  result->inventory = {.video = 1, .total = 1};
  MediaTrackDescriptor track;
  track.id = 1;
  track.kind = MediaTrackKind::Video;
  track.codec = MediaCodec::H264;
  track.timeBase = {1, 60};
  track.duration = result->duration;
  track.codecConfigurationKind = MediaCodecConfigurationKind::AvcC;
  track.codecConfiguration.resize(kAvcC.size());
  std::memcpy(track.codecConfiguration.data(), kAvcC.data(), kAvcC.size());
  MediaVideoFormat video;
  video.codedWidth = 16;
  video.codedHeight = 16;
  video.displayWidth = 16;
  video.displayHeight = 16;
  video.bitsPerComponent = 8;
  video.sampleFormat = MediaVideoSampleFormat::Yuv420EightBit;
  track.video = video;
  result->tracks.push_back(std::move(track));
  result->selectedVideo = 1;
  return result;
}

std::shared_ptr<const MediaSourceDescriptor> mainDescriptor() {
  auto result = std::make_shared<MediaSourceDescriptor>(*descriptor());
  result->inventory.audio = 1;
  result->inventory.total = 2;
  MediaTrackDescriptor audio;
  audio.id = 2;
  audio.kind = MediaTrackKind::Audio;
  audio.codec = MediaCodec::Aac;
  audio.timeBase = {1, 48'000};
  audio.duration = result->duration;
  audio.codecConfigurationKind =
      MediaCodecConfigurationKind::AudioMagicCookie;
  audio.codecConfiguration = {std::byte{0x12}, std::byte{0x10}};
  audio.audio = MediaAudioFormat{48'000.0, 2, 'aac ', 0, 1024};
  result->tracks.push_back(std::move(audio));
  result->selectedAudio = 2;
  return result;
}

AVFoundationPreviewBinding binding() {
  return AVFoundationPreviewBinding{
      std::filesystem::path("/private/tmp/wam-preview-fixture.mov"),
      descriptor(), {}};
}

struct Gate final {
  std::mutex mutex;
  std::condition_variable changed;
  bool entered{false};
  bool released{false};
};

struct Plan final {
  std::uint64_t epoch{0};
  AVFoundationPreviewStatus status{AVFoundationPreviewStatus::Ready};
  MediaTime actualStart{0, 1};
  std::vector<CMSampleBufferRef> samples;
  std::shared_ptr<Gate> startGate;
  bool throwOnStart{false};
  bool throwOnRead{false};
};

class FakeGeneration final : public AVFoundationPreviewGeneration {
 public:
  explicit FakeGeneration(Plan plan) : plan_(std::move(plan)) {
    for (CMSampleBufferRef sample : plan_.samples) {
      if (sample != nullptr) {
        CFRetain(sample);
      }
    }
  }
  ~FakeGeneration() override {
    for (CMSampleBufferRef sample : plan_.samples) {
      if (sample != nullptr) {
        CFRelease(sample);
      }
    }
  }

  [[nodiscard]] std::uint64_t epoch() const noexcept override {
    return plan_.epoch;
  }

  [[nodiscard]] AVFoundationPreviewGenerationStart start() override {
    starts.fetch_add(1, std::memory_order_relaxed);
    if (plan_.throwOnStart) {
      throw std::runtime_error("injected preview start exception");
    }
    if (plan_.startGate != nullptr) {
      std::unique_lock lock(plan_.startGate->mutex);
      plan_.startGate->entered = true;
      plan_.startGate->changed.notify_all();
      plan_.startGate->changed.wait(lock, [this] {
        return plan_.startGate->released ||
               cancelled_.load(std::memory_order_acquire);
      });
    }
    if (cancelled_.load(std::memory_order_acquire)) {
      return {AVFoundationPreviewStatus::Cancelled, {}, {}};
    }
    if (plan_.status == AVFoundationPreviewStatus::Ready) {
      successfulStarts.fetch_add(1, std::memory_order_relaxed);
    }
    return {plan_.status, plan_.actualStart, {}};
  }

  [[nodiscard]] AVFoundationPreviewCopiedSample
  copyNextVideoSample() override {
    reads.fetch_add(1, std::memory_order_relaxed);
    if (plan_.throwOnRead) {
      throw std::runtime_error("injected preview read exception");
    }
    if (cancelled_.load(std::memory_order_acquire)) {
      return {nullptr, AVFoundationPreviewSampleStatus::Cancelled, {}};
    }
    if (index_ == plan_.samples.size()) {
      return {nullptr, AVFoundationPreviewSampleStatus::EndOfStream, {}};
    }
    CMSampleBufferRef sample = plan_.samples[index_++];
    if (sample == nullptr) {
      return {nullptr, AVFoundationPreviewSampleStatus::Failed,
              "injected null sample"};
    }
    CFRetain(sample);
    return {sample, AVFoundationPreviewSampleStatus::Sample, {}};
  }

  void cancel() noexcept override {
    cancels.fetch_add(1, std::memory_order_relaxed);
    cancelled_.store(true, std::memory_order_release);
    if (plan_.startGate != nullptr) {
      std::lock_guard lock(plan_.startGate->mutex);
      plan_.startGate->changed.notify_all();
    }
    if (cancelGate != nullptr) {
      std::unique_lock lock(cancelGate->mutex);
      cancelGate->entered = true;
      cancelGate->changed.notify_all();
      cancelGate->changed.wait(lock,
                               [this] { return cancelGate->released; });
    }
  }

  std::atomic<std::uint64_t> starts{0};
  std::atomic<std::uint64_t> successfulStarts{0};
  std::atomic<std::uint64_t> reads{0};
  std::atomic<std::uint64_t> cancels{0};
  std::shared_ptr<Gate> cancelGate;

 private:
  Plan plan_;
  std::atomic<bool> cancelled_{false};
  std::size_t index_{0};
};

class FakeBackend final : public AVFoundationPreviewBackend {
 public:
  [[nodiscard]] std::shared_ptr<AVFoundationPreviewGeneration>
  makeGeneration(const AVFoundationPreviewBinding& suppliedBinding,
                 AVFoundationPreviewRequest request) override {
    requests.push_back(request);
    paths.push_back(suppliedBinding.localPath);
    if (plans.empty()) {
      return {};
    }
    Plan plan = std::move(plans.front());
    plans.pop_front();
    auto generation = std::make_shared<FakeGeneration>(std::move(plan));
    made.push_back(generation);
    return generation;
  }

  [[nodiscard]] AVFoundationPreviewBackendFacts facts()
      const noexcept override {
    AVFoundationPreviewBackendFacts result = suppliedFacts;
    result.readersCreated += made.size();
    for (const auto& generation : made) {
      result.readersStarted +=
          generation->successfulStarts.load(std::memory_order_relaxed);
    }
    return result;
  }

  std::deque<Plan> plans;
  std::vector<AVFoundationPreviewRequest> requests;
  std::vector<std::filesystem::path> paths;
  std::vector<std::shared_ptr<FakeGeneration>> made;
  AVFoundationPreviewBackendFacts suppliedFacts{1, 1, 123'456, 0, 0};
};

struct CancelInterleave final {
  std::mutex mutex;
  std::condition_variable changed;
  std::uint64_t blockedEpoch{0};
  bool entered{false};
  bool released{false};
};

void blockOldCancel(std::uint64_t epoch, void* context) noexcept {
  auto* interleave = static_cast<CancelInterleave*>(context);
  if (interleave == nullptr || epoch != interleave->blockedEpoch) {
    return;
  }
  std::unique_lock lock(interleave->mutex);
  interleave->entered = true;
  interleave->changed.notify_all();
  interleave->changed.wait(lock,
                           [interleave] { return interleave->released; });
}

void testSharedAssetContextIdentityAndLifetime() {
  const auto admitted = mainDescriptor();
  MediaSourceOpenOptions mainOptions;
  mainOptions.selection.requireVideo = true;
  mainOptions.selection.requireAudio = false;
  const std::filesystem::path path{
      "/private/tmp/wam-preview-fixture.mov"};
  auto lifetime = std::make_shared<int>(11);
  std::weak_ptr<int> lifetimeWeak = lifetime;
  auto context = makeAVFoundationAssetContextForTesting(
      path, mainOptions, admitted, lifetime);
  lifetime.reset();
  expect(context != nullptr,
         "main admission should create a preview-shareable context");
  if (context == nullptr) {
    return;
  }
  expect(context->matchesPreviewBinding(path, admitted),
         "preview should accept exact main asset identity");

  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(Plan{90, AVFoundationPreviewStatus::Ready,
                                {0, 1}, {}, nullptr, false, false});
  AVFoundationPreviewBinding sharedBinding{path, admitted, {}, context};
  auto source = AVFoundationPreviewSource::create(sharedBinding, backend);
  expect(source != nullptr && source->begin({90, {1, 1}}).status ==
                                  AVFoundationPreviewStatus::Ready,
         "injected preview should retain and accept the shared context");
  const AVFoundationAssetContextFacts unchangedLoads = context->facts();
  expect(unchangedLoads.assetMetadataLoadBatches == 1 &&
             unchangedLoads.selectedTrackMetadataLoadBatches == 1,
         "preview readers must not add asset or track metadata loads");
  context.reset();
  expect(!lifetimeWeak.expired(),
         "preview binding should retain context after main releases it");
  source.reset();
  sharedBinding.assetContext.reset();
  expect(lifetimeWeak.expired(),
         "shared asset should retire after main and preview leases end");

  auto copied = std::make_shared<MediaSourceDescriptor>(*admitted);
  AVFoundationPreviewBinding forgedBinding{path, admitted, {}};
  forgedBinding.descriptor = std::move(copied);
  forgedBinding.assetContext = makeAVFoundationAssetContextForTesting(
      path, mainOptions, admitted);
  expect(AVFoundationPreviewSource::create(
             std::move(forgedBinding), std::make_shared<FakeBackend>()) ==
             nullptr,
         "byte-equal copied descriptor cannot forge preview context identity");

  AVFoundationPreviewBinding wrongPath{path, admitted, {}};
  wrongPath.assetContext = makeAVFoundationAssetContextForTesting(
      path, mainOptions, wrongPath.descriptor);
  wrongPath.localPath = "/private/tmp/other-preview.mov";
  expect(AVFoundationPreviewSource::create(
             std::move(wrongPath), std::make_shared<FakeBackend>()) ==
             nullptr,
         "preview context rejects a different canonical source path");

}

void testProductionSharedContextLoadAndReaderAccounting() {
  @autoreleasepool {
    const auto admitted = mainDescriptor();
    MediaSourceOpenOptions mainOptions;
    mainOptions.selection.requireVideo = true;
    mainOptions.selection.requireAudio = true;
    const std::filesystem::path path{
        "/private/tmp/wam-preview-fixture.mov"};

    AVURLAsset* asset = [AVURLAsset
        URLAssetWithURL:[NSURL fileURLWithPath:@"/private/tmp/wam-preview-fixture.mov"]
                options:@{
                  AVURLAssetPreferPreciseDurationAndTimingKey : @YES
                }];
    AVMutableComposition* tracks = [AVMutableComposition composition];
    AVMutableCompositionTrack* video = [tracks
        addMutableTrackWithMediaType:AVMediaTypeVideo
                     preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack* audio = [tracks
        addMutableTrackWithMediaType:AVMediaTypeAudio
                     preferredTrackID:kCMPersistentTrackID_Invalid];
    expect(asset != nil && video != nil && audio != nil,
           "fixture-free native asset handles should be available");
    const auto context = adoptPreparedAVFoundationAssetContext(
        path, mainOptions, admitted,
        AVFoundationAssetContextNativeHandles{
            (__bridge const void*)asset, (__bridge const void*)video,
            (__bridge const void*)audio});
    expect(context != nullptr,
           "prepared native handles should form a shared context");
    if (context == nullptr) {
      return;
    }

    const AVFoundationPreviewSharedContextProbe probe =
        AVFoundationPreviewSourceTestAccess::probeSharedContext(
            AVFoundationPreviewBinding{path, admitted, {}, context});
    expect(probe.sharedLoadReady,
           "production preview should borrow the prepared shared handles");
    expect(probe.backendBefore.assetLoadAttempts == 0 &&
               probe.backendAfterSharedLoad.assetLoadAttempts == 0 &&
               probe.backendAfterSharedLoad.assetLoadsCompleted == 0 &&
               probe.backendAfterSharedLoad.assetLoadNanoseconds == 0,
           "shared production load must issue no asset or track metadata load");
    expect(probe.contextAfterSharedLoad.assetMetadataLoadBatches ==
                   probe.contextBefore.assetMetadataLoadBatches &&
               probe.contextAfterSharedLoad.selectedTrackMetadataLoadBatches ==
                   probe.contextBefore.selectedTrackMetadataLoadBatches &&
               probe.contextAfterSharedLoad.readerCreationAttempts ==
                   probe.contextBefore.readerCreationAttempts &&
               probe.contextAfterSharedLoad.readersStarted ==
                   probe.contextBefore.readersStarted,
           "borrowing shared handles must not mutate context load or reader facts");
    expect(probe.backendAfterCreationFailure.readersCreated == 0 &&
               probe.backendAfterCreationFailure.readersStarted == 0 &&
               probe.contextAfterCreationFailure.readerCreationAttempts ==
                   probe.contextBefore.readerCreationAttempts + 1 &&
               probe.contextAfterCreationFailure.readersStarted ==
                   probe.contextBefore.readersStarted,
           "failed reader initialization is an attempt, not a created reader");
    expect(probe.backendAfterStartedReader.assetLoadAttempts == 0 &&
               probe.backendAfterStartedReader.assetLoadsCompleted == 0 &&
               probe.backendAfterStartedReader.assetLoadNanoseconds == 0 &&
               probe.backendAfterStartedReader.readersCreated == 1 &&
               probe.backendAfterStartedReader.readersStarted == 1 &&
               probe.contextAfterStartedReader.readerCreationAttempts ==
                   probe.contextBefore.readerCreationAttempts + 2 &&
               probe.contextAfterStartedReader.readersStarted ==
                   probe.contextBefore.readersStarted + 1,
           "successful warm reader should add one creation and one start only");
  }
}

void testVideoOnlyReadAndBound() {
  auto format = makeFormat();
  auto discontinuity = makeDiscontinuity(CMTimeMake(4, 1));
  auto preroll = makeSample(format.get(), CMTimeMake(4, 1), CMTimeMake(1, 1));
  auto covering =
      makeSample(format.get(), CMTimeMake(5, 1), CMTimeMake(1, 1), false);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(Plan{7, AVFoundationPreviewStatus::Ready, {4, 1},
                                {discontinuity.get(), preroll.get(),
                                 covering.get()},
                                nullptr, false, false});
  auto source = AVFoundationPreviewSource::create(binding(), backend);
  expect(source != nullptr, "valid preview source should be created");
  const auto begun = source->begin({7, {5, 1}});
  expect(begun.status == AVFoundationPreviewStatus::Ready &&
             begun.actualDecodeStart == MediaTime{4, 1} &&
             backend->requests.size() == 1 &&
             backend->requests[0].epoch == 7 &&
             backend->requests[0].target == MediaTime{5, 1},
         "preview begin should preserve its exact private epoch and target");
  expect(source->memoryFacts().stagedSamples == 0 &&
             source->memoryFacts().currentStagedCompressedBytes == 0 &&
             source->memoryFacts().peakStagedCompressedBytes == 0,
         "preview memory facts should begin empty");

  AVFoundationPreviewReadResult marker = source->readNext(7);
  expect(std::holds_alternative<MediaDiscontinuity>(marker) &&
             std::get<MediaDiscontinuity>(marker).generation == 7 &&
             std::get<MediaDiscontinuity>(marker).track == 1 &&
             std::get<MediaDiscontinuity>(marker).time == MediaTime{4, 1},
         "empty AVFoundation buffers should remain bounded discontinuities");
  expect(source->memoryFacts().stagedSamples == 0 &&
             source->memoryFacts().currentStagedCompressedBytes == 0 &&
             source->memoryFacts().peakStagedCompressedBytes == 0,
         "zero-byte discontinuity staging should not charge compressed bytes");
  AVFoundationPreviewReadResult first = source->readNext(7);
  expect(std::holds_alternative<MediaSample>(first),
         "first preview read should return encoded video");
  if (std::holds_alternative<MediaSample>(first)) {
    const MediaSample& sample = std::get<MediaSample>(first);
    const auto native = sample.payload.borrowNative<
        NativePayloadKind::CoreMediaSampleBuffer>();
    expect(sample.generation == 7 && sample.track == 1 &&
               sample.kind == MediaSampleKind::EncodedVideo &&
               sample.decodeOnly && native.has_value() &&
               native->opaqueAddress() == preroll.get(),
           "preview sample should be zero-copy, video-only, and private-epoch tagged");
  }
  AVFoundationPreviewReadResult second = source->readNext(7);
  expect(std::holds_alternative<MediaSample>(second) &&
             !std::get<MediaSample>(second).decodeOnly &&
             !std::get<MediaSample>(second).keyFrame,
         "the first frame strictly extending beyond target is presentable");
  expect(std::holds_alternative<AVFoundationPreviewEndOfStream>(
             source->readNext(7)) &&
             std::holds_alternative<AVFoundationPreviewEndOfStream>(
                 source->readNext(7)),
         "preview EOS should be idempotent without another reader pull");

  const auto facts = source->facts();
  const auto memory = source->memoryFacts();
  expect(facts.open && facts.activeEpoch == 7 &&
             facts.epochHighWater == 7 && facts.target == MediaTime{5, 1} &&
             facts.actualDecodeStart == MediaTime{4, 1} &&
             facts.stagedSampleBuffers == 0 &&
             facts.peakStagedSampleBuffers == 1 && facts.samplesRead == 2 &&
             facts.discontinuitiesRead == 1 &&
             facts.backend.assetLoadsCompleted == 1 &&
             facts.backend.assetLoadNanoseconds == 123'456,
         "preview facts should prove one-buffer ownership and expose cold asset latency");
  expect(memory.stagedSamples == 0 &&
             memory.currentStagedCompressedBytes == 0 &&
             memory.peakStagedCompressedBytes == 32,
         "preview memory facts should retain the exact one-sample byte peak without a live alias");
  expect(backend->made[0]->reads.load() == 4,
         "idempotent EOS should not pull the backend twice");
}

void testLatestEpochReplacesExactly() {
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(Plan{10, AVFoundationPreviewStatus::Ready,
                                {0, 1}, {}, nullptr, false, false});
  backend->plans.push_back(Plan{11, AVFoundationPreviewStatus::Ready,
                                {3, 1}, {}, nullptr, false, false});
  auto source = AVFoundationPreviewSource::create(binding(), backend);
  expect(source->begin({10, {2, 1}}).status ==
             AVFoundationPreviewStatus::Ready,
         "first preview epoch should start");
  expect(source->begin({11, {4, 1}}).status ==
             AVFoundationPreviewStatus::Ready,
         "newer preview epoch should replace the first");
  expect(backend->made[0]->cancels.load() == 1 &&
             backend->made[1]->cancels.load() == 0,
         "replacement should cancel only the active older reader");

  const auto stale = source->begin({10, {1, 1}});
  expect(stale.status == AVFoundationPreviewStatus::Rejected &&
             backend->requests.size() == 2 &&
             backend->made[1]->cancels.load() == 0,
         "stale replacement should be inert and retain latest ownership");
  source->requestCancel(10);
  source->requestCancel(12);
  expect(backend->made[1]->cancels.load() == 0,
         "stale and future cancellation should be inert");
  source->requestCancel(11);
  expect(backend->made[1]->cancels.load() == 1 && source->facts().cancelled,
         "exact cancellation should promptly reach only the active reader");
  expect(std::holds_alternative<AVFoundationPreviewCancelled>(
             source->readNext(11)) &&
             !source->facts().open && source->facts().activeEpoch == 0,
         "cancelled read should retire source ownership");
}

void testForwardRetargetKeepsOneReader() {
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(Plan{13, AVFoundationPreviewStatus::Ready,
                                {0, 1}, {}, nullptr, false, false});
  auto source = AVFoundationPreviewSource::create(binding(), backend);
  expect(source->begin({13, {2, 1}}).status ==
                 AVFoundationPreviewStatus::Ready &&
             source->advanceTarget(13, {3, 1}) &&
             source->advanceTarget(13, {7, 2}),
         "nondecreasing exact targets should reuse the active reader");
  const auto advanced = source->facts();
  expect(advanced.activeEpoch == 13 && advanced.epochHighWater == 13 &&
             advanced.target == MediaTime{7, 2} &&
             advanced.forwardRetargets == 2 &&
             advanced.backend.readersCreated == 1 &&
             backend->requests.size() == 1 &&
             backend->made[0]->starts.load() == 1 &&
             backend->made[0]->cancels.load() == 0,
         "forward retargets must not allocate, start, or cancel a reader");
  expect(!source->advanceTarget(12, {4, 1}) &&
             !source->advanceTarget(13, {3, 1}) &&
             !source->advanceTarget(13, {61, 1}) &&
             source->facts().target == MediaTime{7, 2} &&
             source->facts().forwardRetargets == 2,
         "stale, backward, and out-of-duration retargets must be inert");
  source->requestCancel(13);
  expect(!source->advanceTarget(13, {4, 1}) &&
             source->facts().forwardRetargets == 2,
         "exact cancellation must take precedence over forward retarget");
}

void testCancellationInterruptsBlockingStart() {
  auto gate = std::make_shared<Gate>();
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(
      Plan{21, AVFoundationPreviewStatus::Ready, {0, 1}, {}, gate});
  auto source = AVFoundationPreviewSource::create(binding(), backend);
  AVFoundationPreviewBeginOutcome outcome;
  std::thread worker([&] { outcome = source->begin({21, {9, 1}}); });
  {
    std::unique_lock lock(gate->mutex);
    gate->changed.wait(lock, [&] { return gate->entered; });
  }
  expect(source->facts().activeEpoch == 21,
         "blocking start should expose its exact cancellation epoch");
  source->requestCancel(20);
  expect(backend->made[0]->cancels.load() == 0,
         "stale cancel cannot interrupt blocking preview start");
  source->requestCancel(21);
  worker.join();
  expect(outcome.status == AVFoundationPreviewStatus::Cancelled &&
             backend->made[0]->cancels.load() >= 1 &&
             source->facts().activeEpoch == 0 && !source->facts().open,
         "exact cancel should interrupt and retire blocking preview start");
}

void testReplacementPublishesCancelBeforeOldRetirement() {
  auto retirementGate = std::make_shared<Gate>();
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(Plan{24, AVFoundationPreviewStatus::Ready,
                                {0, 1}, {}, nullptr, false, false});
  backend->plans.push_back(Plan{25, AVFoundationPreviewStatus::Ready,
                                {3, 1}, {}, nullptr, false, false});
  auto source = AVFoundationPreviewSource::create(binding(), backend);
  expect(source->begin({24, {1, 1}}).status ==
             AVFoundationPreviewStatus::Ready,
         "replacement race fixture should own its first reader");
  backend->made[0]->cancelGate = retirementGate;

  AVFoundationPreviewBeginOutcome replacement;
  std::thread worker([&] { replacement = source->begin({25, {4, 1}}); });
  {
    std::unique_lock lock(retirementGate->mutex);
    retirementGate->changed.wait(lock,
                                 [&] { return retirementGate->entered; });
  }
  const auto retiring = source->facts();
  expect(retiring.operationEpoch == 25 && retiring.activeEpoch == 0,
         "new cancellation slot must publish while the old reader retires");
  source->requestCancel(25);
  {
    std::lock_guard lock(retirementGate->mutex);
    retirementGate->released = true;
    retirementGate->changed.notify_all();
  }
  worker.join();
  expect(replacement.status == AVFoundationPreviewStatus::Cancelled &&
             backend->requests.size() == 1 &&
             source->facts().operationEpoch == 0 &&
             source->facts().activeEpoch == 0,
         "exact replacement cancel must survive old-reader retirement and prevent new construction");
}

void testStaleCancelCannotOverwriteNewCancel() {
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(Plan{26, AVFoundationPreviewStatus::Ready,
                                {0, 1}, {}, nullptr, false, false});
  backend->plans.push_back(Plan{27, AVFoundationPreviewStatus::Ready,
                                {3, 1}, {}, nullptr, false, false});
  auto source = AVFoundationPreviewSource::create(binding(), backend);
  expect(source->begin({26, {1, 1}}).status ==
             AVFoundationPreviewStatus::Ready,
         "two-canceller fixture should own the older epoch");
  CancelInterleave interleave;
  interleave.blockedEpoch = 26;
  AVFoundationPreviewSourceTestAccess::setCancelInterleaveHook(
      *source, &blockOldCancel, &interleave);

  std::thread staleCancel([&] { source->requestCancel(26); });
  {
    std::unique_lock lock(interleave.mutex);
    interleave.changed.wait(lock, [&] { return interleave.entered; });
  }
  expect(source->begin({27, {4, 1}}).status ==
             AVFoundationPreviewStatus::Ready,
         "replacement should start while stale cancel is paused before publication");
  source->requestCancel(27);
  expect(source->facts().cancelled && source->facts().operationEpoch == 27,
         "new exact cancellation should publish before stale caller resumes");
  {
    std::lock_guard lock(interleave.mutex);
    interleave.released = true;
    interleave.changed.notify_all();
  }
  staleCancel.join();
  AVFoundationPreviewSourceTestAccess::setCancelInterleaveHook(
      *source, nullptr, nullptr);
  expect(source->facts().cancelled &&
             std::holds_alternative<AVFoundationPreviewCancelled>(
                 source->readNext(27)) &&
             source->facts().operationEpoch == 0,
         "resumed stale cancellation cannot erase the newer epoch latch");
}

void testFailuresAndValidationFailClosed() {
  auto invalid = binding();
  invalid.localPath = "relative.mov";
  expect(AVFoundationPreviewSource::create(
             std::move(invalid), std::make_shared<FakeBackend>()) == nullptr,
         "preview source should reject a relative path before backend work");

  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(Plan{30, AVFoundationPreviewStatus::Ready,
                                {6, 1}, {}, nullptr, true});
  auto source = AVFoundationPreviewSource::create(binding(), backend);
  expect(source->begin({30, {5, 1}}).status ==
             AVFoundationPreviewStatus::Failed &&
             !source->facts().open,
         "backend exceptions should fail closed and retire the reader");
  expect(source->begin({30, {5, 1}}).status ==
             AVFoundationPreviewStatus::Rejected,
         "failed epochs remain burned and cannot be replayed");
  expect(source->begin({31, {-1, 1}}).status ==
             AVFoundationPreviewStatus::Rejected &&
             source->begin({32, {61, 1}}).status ==
                 AVFoundationPreviewStatus::Rejected,
         "negative and past-duration targets should fail before reader creation");

  auto beyondBackend = std::make_shared<FakeBackend>();
  beyondBackend->plans.push_back(Plan{40, AVFoundationPreviewStatus::Ready,
                                      {8, 1}, {}, nullptr, false, false});
  auto beyond = AVFoundationPreviewSource::create(binding(), beyondBackend);
  expect(beyond->begin({40, {7, 1}}).status ==
             AVFoundationPreviewStatus::Failed &&
             !beyond->facts().open,
         "a backend cannot claim a decode start after the exact target");
}

void testReadExceptionReleasesStageAndOwnership() {
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(Plan{50, AVFoundationPreviewStatus::Ready,
                                {0, 1}, {}, nullptr, false, true});
  auto source = AVFoundationPreviewSource::create(binding(), backend);
  expect(source->begin({50, {1, 1}}).status ==
             AVFoundationPreviewStatus::Ready,
         "read exception fixture should start");
  const auto read = source->readNext(50);
  expect(std::holds_alternative<AVFoundationPreviewFailure>(read) &&
             source->facts().stagedSampleBuffers == 0 &&
             source->facts().activeEpoch == 0 && !source->facts().open,
         "read exception should leave no staged sample or live reader");
}

}  // namespace

int main() {
  testSharedAssetContextIdentityAndLifetime();
  testProductionSharedContextLoadAndReaderAccounting();
  testVideoOnlyReadAndBound();
  testLatestEpochReplacesExactly();
  testForwardRetargetKeepsOneReader();
  testCancellationInterruptsBlockingStart();
  testReplacementPublishesCancelBeforeOldRetirement();
  testStaleCancelCannotOverwriteNewCancel();
  testFailuresAndValidationFailClosed();
  testReadExceptionReleasesStageAndOwnership();
  if (failures != 0) {
    std::cerr << failures << " preview source checks failed\n";
    return 1;
  }
  std::cout << "AVFoundation preview source checks passed\n";
  return 0;
}
