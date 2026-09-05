#include "platform/macos/native_preview_frame_lane.hpp"

#include "platform/macos/avfoundation_preview_source.hpp"
#include "platform/macos/native_surface_budget.hpp"

#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace wam::macos;
using namespace wam::media;
namespace protocol = wam::media::native_playback;

int failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    ++failures;
    std::cerr << "FAIL: " << message << '\n';
  }
}

constexpr std::uint64_t kPlaybackGeneration = 7;
constexpr std::uint8_t kAvcC[] = {
    0x01, 0x42, 0x00, 0x1e, 0xff, 0xe1, 0x00, 0x08, 0x67, 0x42, 0x00,
    0x1e, 0x80, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x68, 0x00, 0x00};

CMSampleBufferRef makeCompressedSample(std::size_t byteCount) {
  CFDataRef atom = CFDataCreate(kCFAllocatorDefault, kAvcC,
                                static_cast<CFIndex>(std::size(kAvcC)));
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
  OSStatus status = CMVideoFormatDescriptionCreate(
      kCFAllocatorDefault, kCMVideoCodecType_H264, 16, 16, extensions,
      &format);
  CFRelease(extensions);
  CFRelease(atoms);
  CFRelease(atom);
  expect(status == noErr && format != nullptr,
         "compressed-memory fixture format should be created");

  CMBlockBufferRef block = nullptr;
  status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, byteCount, kCFAllocatorDefault, nullptr,
      0, byteCount, 0, &block);
  expect(status == noErr && block != nullptr,
         "compressed-memory fixture block should be created");
  std::array<std::byte, 37> bytes{};
  expect(byteCount == bytes.size(),
         "compressed-memory fixture should use its exact fixed byte count");
  status = CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, byteCount);
  expect(status == noErr,
         "compressed-memory fixture bytes should be installed");
  const CMSampleTimingInfo timing{CMTimeMake(1, 1), CMTimeMake(5, 1),
                                  kCMTimeInvalid};
  CMSampleBufferRef sample = nullptr;
  status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, format, 1, 1, &timing, 1, &byteCount,
      &sample);
  CFRelease(block);
  CFRelease(format);
  expect(status == noErr && sample != nullptr,
         "compressed-memory fixture sample should be created");
  return sample;
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
  track.codecConfiguration.resize(std::size(kAvcC));
  std::memcpy(track.codecConfiguration.data(), kAvcC, std::size(kAvcC));
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

// A descriptor for a codec that carries no out-of-band configuration record,
// with the record present or absent as the caller asks. Absent is the only
// correct shape for ProRes, Motion JPEG and MPEG-2; present is a malformed
// descriptor the lane must still refuse.
std::shared_ptr<const MediaSourceDescriptor> recordLessDescriptor(
    MediaCodec codec, bool statesRecord) {
  auto result = std::make_shared<MediaSourceDescriptor>(*descriptor());
  MediaTrackDescriptor& track = result->tracks.front();
  track.codec = codec;
  track.codecConfigurationKind = MediaCodecConfigurationKind::None;
  track.codecConfiguration.clear();
  if (statesRecord) {
    track.codecConfiguration = {std::byte{1}, std::byte{2}};
  }
  return result;
}

NativePreviewBinding sourceBinding() {
  return {"/private/tmp/wam-preview-lane-fixture.mov", descriptor(), {}};
}

NativePreviewFrameLaneBinding laneBinding() {
  return {sourceBinding(), protocol::Generation{kPlaybackGeneration},
          protocol::Stamp{protocol::AttemptId{1}, protocol::Serial{1}}};
}

protocol::PreviewFrame command(std::uint64_t serial,
                               std::uint64_t gesture,
                               std::uint64_t request,
                               double target) {
  return {protocol::Stamp{protocol::AttemptId{1}, protocol::Serial{serial}},
          protocol::Generation{kPlaybackGeneration},
          protocol::GestureId{gesture}, protocol::RequestId{request}, target};
}

class FakeGeneration final : public AVFoundationPreviewGeneration {
 public:
  explicit FakeGeneration(NativePreviewRequest request) noexcept
      : request_(request) {}

  [[nodiscard]] std::uint64_t epoch() const noexcept override {
    return request_.epoch;
  }

  [[nodiscard]] AVFoundationPreviewGenerationStart start() override {
    ++starts;
    return cancelled ? AVFoundationPreviewGenerationStart{
                           NativePreviewStatus::Cancelled, {}, {}}
                     : AVFoundationPreviewGenerationStart{
                           NativePreviewStatus::Ready, {0, 1}, {}};
  }

  [[nodiscard]] AVFoundationPreviewCopiedSample
  copyNextVideoSample() override {
    ++reads;
    if (!cancelled && sample != nullptr && !sampleReturned) {
      CFRetain(sample);
      sampleReturned = true;
      return {sample, AVFoundationPreviewSampleStatus::Sample, {}};
    }
    return {nullptr,
            cancelled ? AVFoundationPreviewSampleStatus::Cancelled
                      : AVFoundationPreviewSampleStatus::EndOfStream,
            {}};
  }

  void cancel() noexcept override {
    cancelled = true;
    ++cancels;
  }

  NativePreviewRequest request_{};
  std::uint64_t starts{0};
  std::uint64_t reads{0};
  std::uint64_t cancels{0};
  CMSampleBufferRef sample{nullptr};
  bool sampleReturned{false};
  bool cancelled{false};
};

class FakeSourceBackend final : public AVFoundationPreviewBackend {
 public:
  [[nodiscard]] std::shared_ptr<AVFoundationPreviewGeneration>
  makeGeneration(const NativePreviewBinding&,
                 NativePreviewRequest request) override {
    requests.push_back(request);
    auto generation = std::make_shared<FakeGeneration>(request);
    generation->sample = sample;
    generations.push_back(generation);
    return generation;
  }

  [[nodiscard]] NativePreviewBackendFacts facts()
      const noexcept override {
    NativePreviewBackendFacts result;
    result.readersCreated = requests.size();
    result.readersStarted = generations.size();
    return result;
  }

  std::vector<NativePreviewRequest> requests;
  std::vector<std::shared_ptr<FakeGeneration>> generations;
  CMSampleBufferRef sample{nullptr};
};

class FakePreviewPort final : public NativeTrackedVideoPreviewPort {
 public:
  explicit FakePreviewPort(std::uint64_t generation) noexcept
      : generation_(generation) {}

  [[nodiscard]] NativeTrackedVideoCapacity capacity(
      std::uint64_t generation) const noexcept override {
    if (failed_) {
      return NativeTrackedVideoCapacity::Failed;
    }
    if (generation != generation_) {
      return NativeTrackedVideoCapacity::StaleGeneration;
    }
    return admitted_.valid() || event_.has_value()
               ? NativeTrackedVideoCapacity::Backpressure
               : NativeTrackedVideoCapacity::Available;
  }

  [[nodiscard]] NativeTrackedVideoPreviewSubmitResult submit(
      std::uint64_t generation, const FrameLease& frame,
      std::string* error) noexcept override {
    if (error != nullptr) {
      error->clear();
    }
    if (!frame || frame.timing().generation != generation) {
      return {NativeTrackedVideoSubmitStatus::StaleGeneration, {}};
    }
    switch (capacity(generation)) {
    case NativeTrackedVideoCapacity::Backpressure:
      return {NativeTrackedVideoSubmitStatus::Backpressure, {}};
    case NativeTrackedVideoCapacity::StaleGeneration:
      return {NativeTrackedVideoSubmitStatus::StaleGeneration, {}};
    case NativeTrackedVideoCapacity::Failed:
      return {NativeTrackedVideoSubmitStatus::Failed, {}};
    case NativeTrackedVideoCapacity::Available:
      break;
    }
    admitted_ = NativeTrackedVideoPreviewSequence{nextSequence_++};
    timing_ = frame.timing();
    peakStagedFrames_ = std::max(peakStagedFrames_, std::size_t{1});
    submittedSequences.push_back(admitted_.value);
    return {NativeTrackedVideoSubmitStatus::Accepted, admitted_};
  }

  [[nodiscard]] std::optional<NativeTrackedVideoPreviewEvent>
  takeEvent() noexcept override {
    std::optional<NativeTrackedVideoPreviewEvent> result = event_;
    event_.reset();
    if (result) {
      admitted_ = {};
      timing_ = {};
    }
    return result;
  }

  [[nodiscard]] NativeTrackedVideoPreviewCancelProgress
  cancel() noexcept override {
    ++cancels;
    return admitted_.valid()
               ? NativeTrackedVideoPreviewCancelProgress::Quiescing
               : NativeTrackedVideoPreviewCancelProgress::Done;
  }

  void complete(NativeTrackedVideoPreviewEventKind kind) {
    expect(admitted_.valid() && !event_,
           "fake preview completion requires one admitted frame");
    event_.emplace(NativeTrackedVideoPreviewEvent{
        kind, ++eventSequence_, admitted_, generation_, timing_});
  }

  [[nodiscard]] std::size_t stagedFrames() const noexcept {
    return admitted_.valid() || event_.has_value() ? 1U : 0U;
  }

  [[nodiscard]] std::size_t peakStagedFrames() const noexcept {
    return peakStagedFrames_;
  }

  std::vector<std::uint64_t> submittedSequences;
  std::uint64_t cancels{0};

 private:
  std::uint64_t generation_{0};
  std::uint64_t nextSequence_{1};
  std::uint64_t eventSequence_{0};
  NativeTrackedVideoPreviewSequence admitted_{};
  FrameTiming timing_{};
  std::optional<NativeTrackedVideoPreviewEvent> event_;
  std::size_t peakStagedFrames_{0};
  bool failed_{false};
};

struct WakeCounter final {
  std::atomic<std::uint64_t> count{0};
};

void wake(void* context) noexcept {
  auto* counter = static_cast<WakeCounter*>(context);
  if (counter != nullptr) {
    counter->count.fetch_add(1, std::memory_order_relaxed);
  }
}

FrameLease makeFrame(std::int64_t presentation,
                     std::int64_t duration = 1,
                     std::uint64_t generation = kPlaybackGeneration) {
  CVPixelBufferRef buffer = nullptr;
  const CVReturn created = CVPixelBufferCreate(
      kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nullptr, &buffer);
  expect(created == kCVReturnSuccess && buffer != nullptr,
         "fixture pixel buffer should be created");
  if (buffer == nullptr) {
    return {};
  }
  FrameLease frame(buffer,
                   FrameTiming{CMTimeMake(presentation, 1),
                               CMTimeMake(duration, 1), generation,
                               presentation == 0});
  CVPixelBufferRelease(buffer);
  return frame;
}

struct Fixture final {
  Fixture()
      : backend(std::make_shared<FakeSourceBackend>()),
        port(std::make_shared<FakePreviewPort>(kPlaybackGeneration)),
        wakes(std::make_shared<WakeCounter>()),
        lane(NativePreviewFrameLaneTestAccess::create(
            laneBinding(), port, {wakes, wake, wakes.get()},
            AVFoundationPreviewSource::create(sourceBinding(), backend))) {
    expect(lane != nullptr, "valid preview lane fixture should be created");
  }

  std::shared_ptr<FakeSourceBackend> backend;
  std::shared_ptr<FakePreviewPort> port;
  std::shared_ptr<WakeCounter> wakes;
  std::unique_ptr<NativePreviewFrameLane> lane;
};

NativePreviewFrameTarget target(double seconds) {
  const auto result = NativePreviewFrameLane::preflightTarget(seconds);
  expect(result.has_value(), "fixture target should have an exact token");
  return *result;
}

void constructionPreconfiguresWithoutStartingPreviewWork() {
  const NativeSurfaceBudgetStats surfacesBefore =
      NativeSurfaceBudget::stats();
  expect(surfacesBefore.currentSurfaces == 0 &&
             surfacesBefore.currentBytes == 0,
         "preview preconfigure fixture should begin without decoded surfaces");

  Fixture fixture;
  const NativePreviewFrameLaneFacts ready = fixture.lane->facts();
  const NativeSurfaceBudgetStats surfacesReady =
      NativeSurfaceBudget::stats();
  expect(ready.decoderConfigurations == 1 &&
             ready.pendingCommands == 0 && !ready.active &&
             ready.activeEpoch == 0 && ready.epochHighWater == 0 &&
             ready.stagedCompressedSamples == 0 && ready.sourceSamples == 0 &&
             !ready.source.open && ready.source.operationEpoch == 0 &&
             ready.source.activeEpoch == 0 &&
             ready.source.backend.readersCreated == 0 &&
             ready.source.backend.readersStarted == 0 &&
             ready.source.stagedSampleBuffers == 0 &&
             ready.source.peakStagedSampleBuffers == 0 &&
             ready.source.samplesRead == 0 && ready.sinkFrames == 0 &&
             ready.peakSinkFrames == 0 && ready.cachedFrames == 0 &&
             ready.peakCachedFrames == 0 &&
             ready.decoder.inFlightFrames == 0 &&
             ready.decoder.retainedPresentationFrames == 0 &&
             ready.decoder.pendingPresentationFrames == 0 &&
             ready.decoder.submittedFrames == 0 &&
             ready.decoder.deliveredFrames == 0 &&
             surfacesReady.currentSurfaces == 0 &&
             surfacesReady.currentBytes == 0,
         "construction should prime one decoder without a reader, sample, "
         "decoded lease, or surface-budget charge");

  expect(fixture.lane->stop(protocol::Generation{kPlaybackGeneration}) ==
             NativePreviewFrameCancelProgress::Done,
         "a preconfigured lane should stop before its first request");
  const NativePreviewFrameLaneFacts stopped = fixture.lane->facts();
  const NativeSurfaceBudgetStats surfacesStopped =
      NativeSurfaceBudget::stats();
  expect(stopped.stopped && !stopped.failed && !stopped.active &&
             stopped.decoderConfigurations == 1 &&
             stopped.pendingCommands == 0 &&
             stopped.stagedCompressedSamples == 0 &&
             stopped.source.backend.readersCreated == 0 &&
             stopped.source.backend.readersStarted == 0 &&
             stopped.source.stagedSampleBuffers == 0 &&
             stopped.source.samplesRead == 0 && stopped.sinkFrames == 0 &&
             stopped.cachedFrames == 0 &&
             stopped.decoder.inFlightFrames == 0 &&
             stopped.decoder.retainedPresentationFrames == 0 &&
             stopped.decoder.pendingPresentationFrames == 0 &&
             surfacesStopped.currentSurfaces == 0 &&
             surfacesStopped.currentBytes == 0,
         "stop-before-request should retire the primed decoder with zero "
         "reader, sample, frame, or surface residue");
}

void compressedMemoryFactsFollowDistinctOwners() {
  constexpr std::size_t kCompressedBytes = 37;
  CMSampleBufferRef sample = makeCompressedSample(kCompressedBytes);
  auto backend = std::make_shared<FakeSourceBackend>();
  backend->sample = sample;
  auto port = std::make_shared<FakePreviewPort>(kPlaybackGeneration);
  auto wakes = std::make_shared<WakeCounter>();
  auto lane = NativePreviewFrameLaneTestAccess::create(
      laneBinding(), port, {wakes, wake, wakes.get()},
      AVFoundationPreviewSource::create(sourceBinding(), backend));
  expect(lane != nullptr,
         "compressed-memory fixture lane should be created");
  const auto request = command(2, 10, 20, 5.0);
  expect(lane->request(request, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             lane->pump() == NativePreviewFramePumpProgress::Progress &&
             lane->pump() == NativePreviewFramePumpProgress::Progress,
         "compressed-memory fixture should stage one source sample in the lane");

  const NativePreviewFrameLaneMemoryFacts staged = lane->memoryFacts();
  expect(staged.sourceCurrentCompressedBytes == 0 &&
             staged.sourcePeakCompressedBytes == kCompressedBytes &&
             staged.laneCurrentCompressedBytes == kCompressedBytes &&
             staged.lanePeakCompressedBytes == kCompressedBytes &&
             staged.decoderCurrentCompressedBytes == 0 &&
             staged.decoderPeakCompressedBytes == 0 &&
             staged.sinkFrames == 0 && staged.cachedFrames == 0,
         "preview memory facts should transfer bytes from source staging to the lane without aliasing them");

  expect(lane->stop(protocol::Generation{kPlaybackGeneration}) ==
             NativePreviewFrameCancelProgress::Done,
         "compressed-memory fixture should stop without output work");
  const NativePreviewFrameLaneMemoryFacts stopped = lane->memoryFacts();
  expect(stopped.sourceCurrentCompressedBytes == 0 &&
             stopped.laneCurrentCompressedBytes == 0 &&
             stopped.decoderCurrentCompressedBytes == 0 &&
             stopped.sourcePeakCompressedBytes == kCompressedBytes &&
             stopped.lanePeakCompressedBytes == kCompressedBytes,
         "preview stop should retire every current compressed byte while preserving peaks");
  lane.reset();
  CFRelease(sample);
}

void realDrawIsTheOnlyPresentationProof() {
  Fixture fixture;
  const auto request = command(2, 10, 20, 5.0);
  expect(fixture.lane->request(request, target(5.0)) ==
             NativePreviewFrameRequestStatus::Accepted,
         "first exact preview command should enter the pending slot");
  expect(fixture.backend->requests.empty() &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.backend->requests.size() == 1 &&
             fixture.backend->requests[0].epoch == 1,
         "owner pump should start one private source epoch");
  expect(NativePreviewFrameLaneTestAccess::injectDecodedFrame(
             *fixture.lane, makeFrame(5)),
         "one decoded frame should enter the bounded sink");
  expect(!NativePreviewFrameLaneTestAccess::injectDecodedFrame(
             *fixture.lane, makeFrame(6)),
         "a second decoded frame should observe sink backpressure");
  expect(fixture.lane->facts().sinkFrames == 1 &&
             fixture.lane->facts().peakSinkFrames == 1 &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.lane->facts().awaitingDraw.valid() &&
             !fixture.lane->takePresented(),
         "output acceptance should retain only identity, never publish draw");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() ==
             NativePreviewFramePumpProgress::Progress,
         "matching real draw should retire exact output credit");
  const auto presented = fixture.lane->takePresented();
  expect(presented && protocol::previewPresentedMatches(request, *presented) &&
             presented->actualPresentationTimeSeconds == 5.0 &&
             fixture.lane->facts().framesDrawn == 1 &&
             fixture.lane->facts().sinkFrames == 0,
         "only matching FrameDrawn should publish exact PreviewPresented");
}

void latestRequestWinsAcrossAnAcceptedOldFrame() {
  Fixture fixture;
  const auto older = command(2, 10, 20, 5.0);
  const auto newer = command(3, 10, 21, 8.0);
  expect(fixture.lane->request(older, target(5.0)) ==
             NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(5)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "older preview should reach the tracked output");
  expect(fixture.lane->request(newer, target(8.0)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.lane->facts().pendingCommands == 1 &&
             fixture.lane->facts().cancelling,
         "newer same-gesture preview should retain one latest pending command");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             !fixture.lane->takePresented() &&
             fixture.lane->facts().staleCompletions == 1,
         "old real draw must be consumed and discarded after replacement");
  expect(fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.backend->requests.size() == 2 &&
             fixture.backend->requests[1].epoch == 2 &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(8)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "latest pending command should start only after old output credit retires");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() ==
             NativePreviewFramePumpProgress::Progress,
         "latest draw should be consumed");
  const auto presented = fixture.lane->takePresented();
  expect(presented && protocol::previewPresentedMatches(newer, *presented) &&
             fixture.lane->facts().acceptedRequests == 2 &&
             fixture.lane->facts().replacedRequests == 1 &&
             fixture.port->submittedSequences ==
                 std::vector<std::uint64_t>({1, 2}),
         "latest exact command alone should own presentation completion");
}

void latestForwardRequestReusesPendingDrawExactly() {
  Fixture fixture;
  const auto first = command(2, 31, 200, 5.0);
  const auto middle = command(3, 31, 201, 5.25);
  const auto latest = command(4, 31, 202, 5.5);
  expect(fixture.lane->request(first, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(5)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "forward pending-draw fixture should admit its first exact frame");
  expect(fixture.lane->request(middle, target(5.25)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.lane->request(latest, target(5.5)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.backend->requests.size() == 1 &&
             fixture.lane->facts().pendingCommands == 0,
         "multiple forward replacements should update the warm active graph in place");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             !fixture.lane->takePresented() &&
             fixture.lane->facts().sinkFrames == 1 &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "the predecessor draw should be real-but-stale before cached resubmission");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress,
         "latest cached resubmission should consume its own real draw");
  const auto presented = fixture.lane->takePresented();
  const auto facts = fixture.lane->facts();
  expect(presented && protocol::previewPresentedMatches(latest, *presented) &&
             fixture.backend->requests.size() == 1 &&
             facts.decoderConfigurations == 1 &&
             facts.decoderReuseRequests == 2 &&
             facts.cachedFrameReuseRequests == 2 &&
             facts.framesSubmitted == 2 && facts.framesDrawn == 1 &&
             facts.staleCompletions == 1 &&
             fixture.port->submittedSequences ==
                 std::vector<std::uint64_t>({1, 2}),
         "only the latest replacement may publish after one-reader cached reuse");
}

void unsolicitedSupersessionRetriesWithoutFakePresentation() {
  Fixture fixture;
  const auto request = command(2, 32, 210, 5.0);
  expect(fixture.lane->request(request, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(5)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "unsolicited supersession fixture should admit one exact frame");
  fixture.port->complete(
      NativeTrackedVideoPreviewEventKind::FrameSuperseded);
  expect(fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             !fixture.lane->takePresented() &&
             fixture.lane->facts().sinkFrames == 1 &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "a real supersession should retry the retained frame, never fabricate a draw");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress,
         "retried frame should consume its own real draw");
  const auto presented = fixture.lane->takePresented();
  const auto facts = fixture.lane->facts();
  expect(presented && protocol::previewPresentedMatches(request, *presented) &&
             facts.framesSubmitted == 2 && facts.framesDrawn == 1 &&
             facts.staleCompletions == 1 &&
             fixture.backend->requests.size() == 1,
         "retry should retain one reader and publish only the eventual real draw");
}

void rapidCachedRetargetsCoalesceBeforePump() {
  Fixture fixture;
  const auto first = command(2, 33, 220, 5.0);
  expect(fixture.lane->request(first, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(5)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "rapid cached fixture should admit its first frame");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress &&
             fixture.lane->takePresented().has_value(),
         "rapid cached fixture should consume its first real draw");

  const auto second = command(3, 33, 221, 5.25);
  const auto third = command(4, 33, 222, 5.5);
  const auto latest = command(5, 33, 223, 5.75);
  expect(fixture.lane->request(second, target(5.25)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.lane->request(third, target(5.5)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.lane->request(latest, target(5.75)) ==
                 NativePreviewFrameRequestStatus::Replaced,
         "several pointer updates before one pump should coalesce in place");
  const auto coalesced = fixture.lane->facts();
  expect(!coalesced.failed && coalesced.pendingCommands == 0 &&
             coalesced.sinkFrames == 1 && coalesced.cachedFrames == 1 &&
             coalesced.decoderConfigurations == 1 &&
             coalesced.decoderReuseRequests == 3 &&
             fixture.backend->requests.size() == 1,
         "rapid cached requests must retain one staged lease and one warm graph");
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress,
         "one pump should submit the coalesced latest cached frame");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress,
         "coalesced cached frame should consume its own real draw");
  const auto presented = fixture.lane->takePresented();
  expect(presented && protocol::previewPresentedMatches(latest, *presented) &&
             presented->actualPresentationTimeSeconds == 5.0 &&
             fixture.port->submittedSequences ==
                 std::vector<std::uint64_t>({1, 2}),
         "only the latest pre-pump command should own cached presentation");
}

void eosCachedFrameCanBeRedrawnExactly() {
  {
    Fixture fixture;
    const auto first = command(2, 34, 230, 5.0);
    expect(fixture.lane->request(first, target(5.0)) ==
                   NativePreviewFrameRequestStatus::Accepted &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                   *fixture.lane, makeFrame(5)),
           "EOS idle fixture should stage its final decoded frame");
    NativePreviewFrameLaneTestAccess::endDecodedStream(*fixture.lane);
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress,
           "EOS idle fixture should submit its final frame");
    fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               fixture.lane->takePresented().has_value(),
           "EOS idle fixture should consume the final real draw");
    const auto latest = command(3, 34, 231, 5.5);
    expect(fixture.lane->request(latest, target(5.5)) ==
                   NativePreviewFrameRequestStatus::Replaced &&
               !fixture.lane->facts().failed &&
               fixture.lane->facts().sinkFrames == 1 &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress,
           "decoder EOS must not block owner restaging of the cached final frame");
    fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress,
           "EOS cached restage should consume its own draw");
    const auto presented = fixture.lane->takePresented();
    expect(presented &&
               protocol::previewPresentedMatches(latest, *presented) &&
               fixture.backend->requests.size() == 1,
           "EOS cached reuse should remain one-reader and exact-draw proven");
  }
  {
    Fixture fixture;
    const auto first = command(2, 35, 240, 5.0);
    const auto latest = command(3, 35, 241, 5.5);
    expect(fixture.lane->request(first, target(5.0)) ==
                   NativePreviewFrameRequestStatus::Accepted &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                   *fixture.lane, makeFrame(5)),
           "EOS in-flight fixture should stage its final frame");
    NativePreviewFrameLaneTestAccess::endDecodedStream(*fixture.lane);
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               fixture.lane->request(latest, target(5.5)) ==
                   NativePreviewFrameRequestStatus::Replaced,
           "EOS final frame should accept an in-flight cached retarget");
    fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               !fixture.lane->takePresented() &&
               fixture.lane->facts().sinkFrames == 1 &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress,
           "old EOS draw should remain stale before exact cached resubmit");
    fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
    expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress,
           "in-flight EOS cached resubmit should consume its own draw");
    const auto presented = fixture.lane->takePresented();
    expect(presented &&
               protocol::previewPresentedMatches(latest, *presented) &&
               fixture.backend->requests.size() == 1 &&
               fixture.lane->facts().staleCompletions == 1,
           "in-flight EOS retarget should publish only its latest real draw");
  }
}

void retainedCloneFailurePrecedesOutputAdmission() {
  Fixture fixture;
  const auto request = command(2, 36, 250, 5.0);
  expect(fixture.lane->request(request, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(5)),
         "clone-failure fixture should stage one decoded frame");
  NativePreviewFrameLaneTestAccess::failNextRetainedFrameClone(
      *fixture.lane);
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Failed,
         "retained-frame clone failure should fail closed");
  const auto facts = fixture.lane->facts();
  expect(facts.failed && !facts.awaitingDraw.valid() &&
             facts.framesSubmitted == 0 && facts.sinkFrames == 0 &&
             facts.cachedFrames == 0 &&
             fixture.port->submittedSequences.empty() &&
             fixture.port->stagedFrames() == 0,
         "clone failure must occur before output admission and leave no untracked event");
}

void pendingSlotCoalescesWithoutStartingDiscardedReaders() {
  Fixture fixture;
  const auto first = command(2, 10, 20, 2.0);
  const auto second = command(3, 10, 21, 3.0);
  const auto newGesture = command(4, 11, 22, 4.0);
  expect(fixture.lane->request(first, target(2.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->request(second, target(3.0)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.lane->request(newGesture, target(4.0)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.lane->facts().pendingCommands == 1 &&
             fixture.backend->requests.empty(),
         "pending capacity one should retain only the latest command, including gesture reset");
  expect(fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.backend->requests.size() == 1 &&
             fixture.backend->requests[0].target == MediaTime{4, 1} &&
             fixture.lane->facts().epochHighWater == 1,
         "coalesced commands should create exactly one reader and one epoch");
}

void forwardDragReusesReaderDecoderAndExactFrame() {
  Fixture fixture;
  const auto first = command(2, 42, 100, 5.0);
  expect(fixture.lane->request(first, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(5)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "reuse fixture should submit its first exact frame");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.lane->takePresented().has_value(),
         "reuse fixture should consume its first real draw");

  constexpr std::size_t kCachedForwardReplacements = 64;
  for (std::size_t index = 1; index <= kCachedForwardReplacements; ++index) {
    const double seconds = 5.0 + static_cast<double>(index) / 128.0;
    const auto sameFrame = command(2 + index, 42, 100 + index, seconds);
    expect(fixture.lane->request(sameFrame, target(seconds)) ==
                   NativePreviewFrameRequestStatus::Replaced &&
               fixture.lane->facts().sinkFrames == 1 &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress,
           "a target inside the retained frame should resubmit without decode");
    fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress,
           "cached-frame draw should retire its exact output credit");
    const auto cachedPresented = fixture.lane->takePresented();
    expect(cachedPresented &&
               protocol::previewPresentedMatches(sameFrame,
                                                 *cachedPresented) &&
               cachedPresented->actualPresentationTimeSeconds == 5.0,
           "cached reuse still requires a new real draw for each latest command");
  }

  const auto sequential = command(
      3 + kCachedForwardReplacements, 42,
      101 + kCachedForwardReplacements, 6.5);
  expect(fixture.lane->request(sequential, target(6.5)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(6)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "a bounded forward target should continue the warm graph");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "sequential reuse draw should be consumed");
  const auto sequentialPresented = fixture.lane->takePresented();
  const auto reused = fixture.lane->facts();
  expect(sequentialPresented &&
             protocol::previewPresentedMatches(sequential,
                                               *sequentialPresented) &&
             fixture.backend->requests.size() == 1 &&
             reused.source.backend.readersCreated == 1 &&
             reused.source.forwardRetargets ==
                 kCachedForwardReplacements + 1 &&
             reused.decoderConfigurations == 1 &&
             reused.decoderReuseRequests ==
                 kCachedForwardReplacements + 1 &&
             reused.cachedFrameReuseRequests ==
                 kCachedForwardReplacements &&
             reused.cachedFrames == 1 && reused.peakCachedFrames == 1,
         "many forward replacements should retain exactly one reader, decoder, and cached surface");

  const auto backward = command(
      4 + kCachedForwardReplacements, 42,
      102 + kCachedForwardReplacements, 4.0);
  expect(fixture.lane->request(backward, target(4.0)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.backend->requests.size() == 2 &&
             fixture.lane->facts().decoderConfigurations == 2,
         "a backward target should exactly retire and rebuild the graph");
  expect(NativePreviewFrameLaneTestAccess::injectDecodedFrame(
             *fixture.lane, makeFrame(4)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "backward rebuild should accept its new exact frame");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress &&
             fixture.lane->takePresented().has_value(),
         "backward rebuild should finish its real draw");

  const auto jump = command(
      5 + kCachedForwardReplacements, 42,
      103 + kCachedForwardReplacements, 8.0);
  expect(fixture.lane->request(jump, target(8.0)) ==
                 NativePreviewFrameRequestStatus::Replaced &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.backend->requests.size() == 3 &&
             fixture.lane->facts().decoderConfigurations == 3 &&
             fixture.lane->facts().decoderReuseRequests ==
                 kCachedForwardReplacements + 1,
         "a forward jump beyond the bounded decoded frontier should rebuild");
}

void exactCancelAndStopNeverFabricatePresentation() {
  Fixture fixture;
  const auto request = command(2, 10, 20, 5.0);
  const auto stale = command(1, 10, 19, 4.0);
  expect(fixture.lane->request(request, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.lane->cancel(stale) ==
                 NativePreviewFrameCancelProgress::Stale &&
             fixture.lane->cancel(request) ==
                 NativePreviewFrameCancelProgress::Done &&
             fixture.backend->generations[0]->cancels >= 1,
         "only exact active command cancellation should retire local work");

  const auto second = command(3, 10, 21, 8.0);
  expect(fixture.lane->request(second, target(8.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane, makeFrame(8)) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.lane->stop(protocol::Generation{6}) ==
                 NativePreviewFrameCancelProgress::Stale &&
             fixture.lane->stop(protocol::Generation{7}) ==
                 NativePreviewFrameCancelProgress::Quiescing,
         "exact stop should remain quiescing for an admitted output frame");
  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameSuperseded);
  expect(fixture.lane->stop(protocol::Generation{7}) ==
                 NativePreviewFrameCancelProgress::Done &&
             fixture.lane->facts().stopped &&
             !fixture.lane->takePresented() &&
             fixture.lane->request(command(4, 10, 22, 9.0), target(9.0)) ==
                 NativePreviewFrameRequestStatus::Closed,
         "real terminal supersession should complete stop without a fake draw");
}

void privateEpochExhaustionFailsWithoutWrap() {
  Fixture fixture;
  NativePreviewFrameLaneTestAccess::setNextEpoch(
      *fixture.lane, std::numeric_limits<std::uint64_t>::max());
  const auto last = command(2, 10, 20, 5.0);
  expect(fixture.lane->request(last, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             fixture.lane->facts().epochHighWater ==
                 std::numeric_limits<std::uint64_t>::max() &&
             fixture.lane->cancel(last) ==
                 NativePreviewFrameCancelProgress::Done,
         "maximum private epoch should be usable exactly once");
  expect(fixture.lane->request(command(3, 10, 21, 6.0), target(6.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Failed &&
             fixture.lane->facts().failed &&
             fixture.backend->requests.size() == 1,
         "private epoch exhaustion should fail closed before reader creation");
}

// A head-TRIMMED MP4 (elst media_time > 0) hides media before the movie
// origin, so the random-access point that covers the origin restates to a
// NEGATIVE movie time -- measured -5.50 s on boxing_trimmed.mp4 and -5.23 s on
// trimmed_autorollout.mp4, each of which carries exactly two sync samples, the
// second at +4.50 s / +4.77 s. Any preview target below that second sync sample
// therefore decodes a preroll run that begins before the origin.
//
// The lane used to refuse those frames outright ("preview decoder emitted
// invalid frame timing"), which latched the lane; the session's
// stopPreviewLaneForTerminal then escalated the dead lane into a REFUSED COMMIT
// SEEK ("Native seeking is unavailable for this file.") and the transport froze
// with no fallback. Backward seeks looked like the trigger only because they
// land at low targets; a FORWARD seek to the same low target stalled
// identically.
//
// The rule that survives is the consumer's own: what matters is where a frame
// ENDS, not which side of the origin it begins on.
void preOriginPrerollFramesAreRetiredNotRefused() {
  Fixture fixture;
  const auto request = command(2, 40, 300, 5.0);
  expect(fixture.lane->request(request, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "head-trim preroll fixture should accept its request");

  // The pre-origin preroll frame: presentation -5 s, ending at -4 s, i.e.
  // entirely before both the movie origin and the requested target.
  expect(NativePreviewFrameLaneTestAccess::injectDecodedFrame(
             *fixture.lane, makeFrame(-5, 1)),
         "a pre-origin preroll frame should reach the lane sink");
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress,
         "a frame ending before the target must be RETIRED as preroll, not "
         "latched as invalid timing");
  const NativePreviewFrameLaneFacts afterPreroll = fixture.lane->facts();
  expect(!afterPreroll.failed && afterPreroll.decodedFramesDiscarded == 1 &&
             fixture.port->submittedSequences.empty(),
         "pre-origin preroll must be discarded without failing the lane or "
         "reaching the tracked output");

  // The lane must still be a WORKING lane afterwards: the picture the target
  // actually wants arrives next and completes normally. Before the fix the
  // pre-origin frame above had already latched the lane, so this never ran --
  // and the session escalated that dead lane into a refused commit seek.
  expect(NativePreviewFrameLaneTestAccess::injectDecodedFrame(
             *fixture.lane, makeFrame(5)),
         "the covering frame should reach the lane sink after preroll");
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress &&
             !fixture.lane->facts().failed &&
             fixture.lane->facts().decodedFramesDiscarded == 1 &&
             fixture.port->submittedSequences ==
                 std::vector<std::uint64_t>({1}),
         "the covering frame alone should reach the tracked output");

  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Progress,
         "the covering frame's real draw should be consumed");
  const auto presented = fixture.lane->takePresented();
  expect(presented && protocol::previewPresentedMatches(request, *presented) &&
             presented->actualPresentationTimeSeconds == 5.0 &&
             fixture.lane->facts().framesDrawn == 1 &&
             !fixture.lane->facts().failed,
         "a preview that began with pre-origin preroll must still complete on "
         "its exact command");
}

// The sign of a presentation time is not admissible evidence, but genuinely
// malformed timing still is. This keeps the widened predicate honest.
void malformedPreviewFrameTimingStillFailsClosed() {
  Fixture fixture;
  const auto request = command(2, 41, 301, 5.0);
  expect(fixture.lane->request(request, target(5.0)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "malformed-timing fixture should accept its request");
  // Zero duration is malformed at any sign, negative included.
  expect(NativePreviewFrameLaneTestAccess::injectDecodedFrame(
             *fixture.lane, makeFrame(-5, 0)),
         "a zero-duration frame should still reach the lane sink");
  expect(fixture.lane->pump() == NativePreviewFramePumpProgress::Failed &&
             fixture.lane->facts().failed,
         "a non-positive duration must still fail the lane closed");
}

void unknownOutputEventsFailClosed() {
  {
    Fixture fixture;
    const auto request = command(2, 10, 20, 5.0);
    expect(fixture.lane->request(request, target(5.0)) ==
                   NativePreviewFrameRequestStatus::Accepted &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                   *fixture.lane, makeFrame(5)) &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress,
           "unknown pump-event fixture should own one exact output frame");
    fixture.port->complete(
        static_cast<NativeTrackedVideoPreviewEventKind>(0xff));
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Failed &&
               fixture.lane->facts().failed &&
               !fixture.lane->takePresented(),
           "unknown exact-frame event must fail closed in normal pump");
  }
  {
    Fixture fixture;
    const auto request = command(2, 10, 20, 5.0);
    expect(fixture.lane->request(request, target(5.0)) ==
                   NativePreviewFrameRequestStatus::Accepted &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                   *fixture.lane, makeFrame(5)) &&
               fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               fixture.lane->stop(protocol::Generation{7}) ==
                   NativePreviewFrameCancelProgress::Quiescing,
           "unknown stop-event fixture should remain output-quiescing");
    fixture.port->complete(
        static_cast<NativeTrackedVideoPreviewEventKind>(0xff));
    expect(fixture.lane->stop(protocol::Generation{7}) ==
                   NativePreviewFrameCancelProgress::Failed &&
               fixture.lane->facts().failed &&
               !fixture.lane->takePresented(),
           "unknown exact-frame event must fail closed during stop");
  }
}

void deterministicLatestWinsStressStaysBounded() {
  constexpr std::size_t kReplacements = 512;
  Fixture fixture;
  std::size_t observedPeakPending = 0;
  std::size_t observedPeakCompressed = 0;
  std::size_t observedPeakSource = 0;
  std::size_t observedPeakSink = 0;

  const auto sampleBounds = [&] {
    const NativePreviewFrameLaneFacts facts = fixture.lane->facts();
    observedPeakPending =
        std::max(observedPeakPending, facts.pendingCommands);
    observedPeakCompressed =
        std::max(observedPeakCompressed, facts.stagedCompressedSamples);
    observedPeakSource = std::max(
        observedPeakSource, facts.source.peakStagedSampleBuffers);
    observedPeakSink = std::max(observedPeakSink, facts.sinkFrames);
    expect(facts.pendingCommands <= 1,
           "stress pending command capacity must remain one");
    expect(facts.stagedCompressedSamples <= 1,
           "stress lane compressed staging must remain one");
    expect(facts.source.stagedSampleBuffers <= 1 &&
               facts.source.peakStagedSampleBuffers <= 1,
           "stress preview source staging must remain one");
    expect(facts.sinkFrames <= 1 && facts.peakSinkFrames <= 1,
           "stress decoded sink capacity must remain one");
    expect(fixture.port->stagedFrames() <= 1 &&
               fixture.port->peakStagedFrames() <= 1,
           "stress output port must retain at most one frame credit");
    expect(!facts.failed, "stress lane must not latch failure");
  };

  protocol::PreviewFrame latest = command(2, 77, 1000, 1.0);
  expect(fixture.lane->request(latest, target(latest.targetSeconds)) ==
                 NativePreviewFrameRequestStatus::Accepted &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress &&
             NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                 *fixture.lane,
                 makeFrame(static_cast<std::int64_t>(latest.targetSeconds))) &&
             fixture.lane->pump() ==
                 NativePreviewFramePumpProgress::Progress,
         "stress seed request should reach one admitted output frame");
  sampleBounds();

  for (std::size_t index = 0; index < kReplacements; ++index) {
    const double seconds =
        static_cast<double>(1 + ((index + 1) % 58));
    const protocol::PreviewFrame newer =
        command(3 + index, 77, 1001 + index, seconds);
    expect(fixture.lane->request(newer, target(seconds)) ==
                   NativePreviewFrameRequestStatus::Replaced,
           "stress newer request should replace the admitted predecessor");
    sampleBounds();
    expect(fixture.lane->cancel(latest) ==
               NativePreviewFrameCancelProgress::Stale,
           "stress stale cancellation must not disturb the retained latest request");
    sampleBounds();

    fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               !fixture.lane->takePresented(),
           "stress superseded real draw must never publish stale presentation");
    sampleBounds();
    expect(fixture.lane->pump() ==
                   NativePreviewFramePumpProgress::Progress &&
               NativePreviewFrameLaneTestAccess::injectDecodedFrame(
                   *fixture.lane,
                   makeFrame(static_cast<std::int64_t>(seconds))),
           "stress latest request should start and accept one exact frame");
    sampleBounds();
    expect(fixture.lane->pump() ==
               NativePreviewFramePumpProgress::Progress,
           "stress latest frame should acquire the single output credit");
    sampleBounds();
    latest = newer;
  }

  fixture.port->complete(NativeTrackedVideoPreviewEventKind::FrameDrawn);
  expect(fixture.lane->pump() ==
             NativePreviewFramePumpProgress::Progress,
         "stress final real draw should retire the latest output credit");
  const auto presented = fixture.lane->takePresented();
  expect(presented && protocol::previewPresentedMatches(latest, *presented) &&
             presented->actualPresentationTimeSeconds ==
                 latest.targetSeconds,
         "stress final real draw must prove the exact latest command");
  sampleBounds();

  const NativePreviewFrameLaneFacts beforeStop = fixture.lane->facts();
  expect(beforeStop.acceptedRequests == kReplacements + 1 &&
             beforeStop.replacedRequests == kReplacements &&
             beforeStop.framesSubmitted == kReplacements + 1 &&
             beforeStop.framesDrawn == 1 &&
             beforeStop.staleCompletions == kReplacements &&
             fixture.port->cancels >= kReplacements,
         "stress counters must account for every request, draw, and cancellation");
  expect(observedPeakPending == 1 && observedPeakCompressed <= 1 &&
             observedPeakSource <= 1 && observedPeakSink == 1,
         "stress observed capacities must remain deterministically bounded");

  expect(fixture.lane->stop(protocol::Generation{kPlaybackGeneration}) ==
             NativePreviewFrameCancelProgress::Done,
         "stress final stop should complete after the exact draw");
  const NativePreviewFrameLaneFacts stopped = fixture.lane->facts();
  expect(stopped.stopped && !stopped.failed && !stopped.active &&
             stopped.activeEpoch == 0 && stopped.pendingCommands == 0 &&
             stopped.stagedCompressedSamples == 0 &&
             stopped.source.stagedSampleBuffers == 0 &&
             stopped.sinkFrames == 0 && !stopped.awaitingDraw.valid() &&
             !stopped.presentedPending && fixture.port->stagedFrames() == 0,
         "stress stop must leave no active, pending, source, sink, or output work");
}

// The lane's codec admission, in both directions.
//
// Two gates have to agree for a record-less codec to be scrubbed at all: the
// codec whitelist must name it, and the record requirement must be inverted for
// it, because a nonempty configuration record is the exact shape it is required
// NOT to present. Both halves are asserted, because admitting the codec while
// still demanding a record leaves it with no preview.
void recordLessCodecsAreAdmittedWithNoConfigurationRecord() {
  auto port = std::make_shared<FakePreviewPort>(kPlaybackGeneration);
  auto wakes = std::make_shared<WakeCounter>();
  // MPEG-2 is record-less too and the lane admits it, but it reaches this
  // player only through the transport-stream preview source, so it cannot be
  // driven from this fixture's AVFoundation one.
  for (const MediaCodec recordLess : {MediaCodec::ProRes, MediaCodec::Mjpeg}) {
    const NativePreviewBinding admittedSource{
        "/private/tmp/wam-preview-lane-fixture.mov",
        recordLessDescriptor(recordLess, false),
        {}};
    auto admitted = NativePreviewFrameLaneTestAccess::create(
        {admittedSource, protocol::Generation{kPlaybackGeneration},
         protocol::Stamp{protocol::AttemptId{1}, protocol::Serial{1}}},
        port, {wakes, wake, wakes.get()},
        AVFoundationPreviewSource::create(
            admittedSource, std::make_shared<FakeSourceBackend>()));
    expect(admitted != nullptr,
           "a record-less codec must configure a preview lane with an empty "
           "configuration record");
    if (admitted != nullptr) {
      expect(admitted->stop(protocol::Generation{kPlaybackGeneration}) ==
                 NativePreviewFrameCancelProgress::Done,
             "the record-less lane must stop without output work");
    }

    const NativePreviewBinding refusedSource{
        "/private/tmp/wam-preview-lane-fixture.mov",
        recordLessDescriptor(recordLess, true),
        {}};
    expect(NativePreviewFrameLaneTestAccess::create(
               {refusedSource, protocol::Generation{kPlaybackGeneration},
                protocol::Stamp{protocol::AttemptId{1}, protocol::Serial{1}}},
               port, {wakes, wake, wakes.get()},
               AVFoundationPreviewSource::create(
                   refusedSource, std::make_shared<FakeSourceBackend>())) ==
               nullptr,
           "a record-less codec presenting a record is still refused");
  }
}

}  // namespace

int main() {
  expect(!NativePreviewFrameLane::preflightTarget(0.1),
         "unrepresentable binary64 target should fail exact preflight");
  constructionPreconfiguresWithoutStartingPreviewWork();
  compressedMemoryFactsFollowDistinctOwners();
  realDrawIsTheOnlyPresentationProof();
  latestRequestWinsAcrossAnAcceptedOldFrame();
  latestForwardRequestReusesPendingDrawExactly();
  unsolicitedSupersessionRetriesWithoutFakePresentation();
  rapidCachedRetargetsCoalesceBeforePump();
  eosCachedFrameCanBeRedrawnExactly();
  retainedCloneFailurePrecedesOutputAdmission();
  pendingSlotCoalescesWithoutStartingDiscardedReaders();
  forwardDragReusesReaderDecoderAndExactFrame();
  exactCancelAndStopNeverFabricatePresentation();
  privateEpochExhaustionFailsWithoutWrap();
  preOriginPrerollFramesAreRetiredNotRefused();
  malformedPreviewFrameTimingStillFailsClosed();
  unknownOutputEventsFailClosed();
  deterministicLatestWinsStressStaysBounded();
  recordLessCodecsAreAdmittedWithNoConfigurationRecord();
  if (failures != 0) {
    return EXIT_FAILURE;
  }
  std::cout << "native preview frame lane checks passed\n";
  return EXIT_SUCCESS;
}
