// MPEG-TS scrub-preview source contract.
//
// Three things are proved here that no other suite covers:
//
//   1. Plan mapping. A preview epoch begins at the random access point at or
//      before its target, never after it, and the first sample it emits is
//      that access unit. A transport stream has no index, so the plan bisects
//      the PCR table and scans forward; the landing is therefore within one
//      GOP of the request rather than on it, and it still costs exactly one
//      cursor per epoch with no back-walk.
//   2. Cancellation. The demuxer's cancellation seam is a POD probe, so the
//      source's own epoch latch is what every plan, cursor read, and payload
//      copy observes; a cancel for the live operation must be answered and a
//      cancel for a stale one must be inert.
//   3. Facts. The neutral NativePreviewSourceFacts vocabulary is answered
//      against cursors, and the three assetLoad counters stay zero because
//      admitting a transport stream is the main source's job.
//
// It is also the second consumer of the promoted sample builders in
// `mpegts_sample_builder.hpp`: this binary links both it and the main MPEG-TS
// media source, so a builder that only one of them could call would not link.
//
// There is no checked-in transport stream, so the fixture is muxed at test
// time. Without a muxer the binary skips.

#include "platform/macos/mpegts_preview_source.hpp"

#include "media/mpegts_demuxer.hpp"
#include "media/native_media_source.hpp"
#include "platform/macos/mpegts_asset_context.hpp"
#include "platform/macos/mpegts_media_source.hpp"
#include "platform/macos/mpegts_sample_builder.hpp"
#include "platform/macos/native_preview_source.hpp"

#import <CoreMedia/CoreMedia.h>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

#include "support/expect.hpp"

extern char** environ;

namespace {

using wam::macos::MpegTsPreviewSource;
using wam::macos::NativePreviewBeginOutcome;
using wam::macos::NativePreviewBinding;
using wam::macos::NativePreviewCancelled;
using wam::macos::NativePreviewEndOfStream;
using wam::macos::NativePreviewReadResult;
using wam::macos::NativePreviewRequest;
using wam::macos::NativePreviewSourceFacts;
using wam::macos::NativePreviewStatus;
using wam::media::MediaSample;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaTime;
using wam::media::MediaTimeOrder;


[[nodiscard]] bool sameTime(MediaTime lhs, MediaTime rhs) noexcept {
  const auto order = wam::media::compareMediaTime(lhs, rhs);
  return order.has_value() && *order == MediaTimeOrder::Equal;
}

[[nodiscard]] bool timeAtMost(MediaTime lhs, MediaTime rhs) noexcept {
  const auto order = wam::media::compareMediaTime(lhs, rhs);
  return order.has_value() && *order != MediaTimeOrder::Greater;
}

[[nodiscard]] const MediaSample* sampleOf(
    const NativePreviewReadResult& result) noexcept {
  return std::get_if<MediaSample>(&result);
}

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

[[nodiscard]] bool runFfmpeg(const std::string& executable,
                             const std::vector<std::string>& arguments) {
  std::vector<char*> argv;
  argv.reserve(arguments.size() + 2);
  std::string program = executable;
  argv.push_back(program.data());
  std::vector<std::string> owned = arguments;
  for (std::string& argument : owned) {
    argv.push_back(argument.data());
  }
  argv.push_back(nullptr);
  pid_t child = 0;
  if (posix_spawn(&child, executable.c_str(), nullptr, nullptr, argv.data(),
                  environ) != 0) {
    return false;
  }
  int status = 0;
  if (waitpid(child, &status, 0) != child) {
    return false;
  }
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

struct Fixture {
  std::filesystem::path directory;
  std::filesystem::path stream;
  bool valid{false};

  ~Fixture() {
    std::error_code ignored;
    if (!directory.empty()) {
      std::filesystem::remove_all(directory, ignored);
    }
  }
};

void buildFixture(const std::string& ffmpeg, Fixture& fixture) {
  std::error_code ignored;
  fixture.directory = std::filesystem::temp_directory_path() /
                      ("wam-mpegts-preview-" + std::to_string(::getpid()));
  std::filesystem::create_directories(fixture.directory, ignored);
  fixture.stream = fixture.directory / "preview.ts";
  std::vector<std::string> command{
      "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi",
      "-i", "testsrc2=size=320x180:rate=30:duration=3", "-f", "lavfi", "-i",
      "sine=frequency=440:sample_rate=48000:duration=3", "-c:v", "libx264",
      "-preset", "veryfast", "-bf", "2", "-pix_fmt", "yuv420p", "-g", "15",
      "-c:a", "aac", "-f", "mpegts"};
  command.push_back(fixture.stream.string());
  fixture.valid = runFfmpeg(ffmpeg, command);
}

struct PreparedFixture {
  std::filesystem::path path;
  wam::media::mpegts::MpegTsPrepareOutcome outcome;
  std::shared_ptr<const wam::macos::MpegTsAssetContext> context;

  [[nodiscard]] NativePreviewBinding binding() const {
    NativePreviewBinding value;
    value.localPath = path;
    // Exact descriptor-instance identity is what matchesPreviewBinding()
    // proves, so the binding republishes the context's own instance.
    value.descriptor = context->descriptor();
    value.assetContext = context;
    return value;
  }
};

PreparedFixture prepare(const Fixture& fixture) {
  PreparedFixture prepared;
  prepared.path = fixture.stream;
  MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  prepared.outcome = wam::media::mpegts::prepareMpegTsLocalFile(
      fixture.stream, options, {});
  if (prepared.outcome.asset != nullptr) {
    prepared.context = wam::macos::adoptPreparedMpegTsAssetContext(
        fixture.stream, options, prepared.outcome.asset);
  }
  return prepared;
}

// ---------------------------------------------------------------------------
// Contracts
// ---------------------------------------------------------------------------

void testFixtureAdmitsAndSelectsVideo(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  expect(prepared.outcome.asset != nullptr && prepared.context != nullptr,
         "the muxed transport stream is admitted and adopted");
  if (prepared.context == nullptr) {
    std::cerr << "  prepare error: " << prepared.outcome.message << '\n';
    return;
  }
  expect(prepared.context->backendKind() ==
             wam::media::MediaSourceBackendKind::MpegTs,
         "an adopted MPEG-TS context reports the MPEG-TS backend kind");
  const auto& descriptor = *prepared.context->descriptor();
  expect(descriptor.selectedVideo.has_value() && descriptor.duration.valid() &&
             descriptor.duration.value > 0,
         "the fixture selects video over a positive timeline");
  expect(prepared.context->descriptor().get() ==
             prepared.outcome.asset->descriptor().get(),
         "the context republishes the asset's own descriptor instance");
}

void testPlanMappingWithoutBackWalk(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "plan mapping fixture prepares");
    return;
  }
  auto source = MpegTsPreviewSource::create(prepared.binding());
  expect(source != nullptr, "a preview source is created from a live context");
  if (source == nullptr) {
    return;
  }

  const std::array<MediaTime, 5> targets{MediaTime{0, 1}, MediaTime{1, 2},
                                         MediaTime{1, 1}, MediaTime{3, 2},
                                         MediaTime{5, 2}};
  std::uint64_t epoch = 0;
  bool exact = true;
  for (const MediaTime target : targets) {
    ++epoch;
    const NativePreviewBeginOutcome begun =
        source->begin(NativePreviewRequest{epoch, target});
    exact = exact && begun.status == NativePreviewStatus::Ready &&
            begun.epoch == epoch && begun.actualDecodeStart.valid() &&
            begun.actualDecodeStart.value >= 0;
    if (begun.status != NativePreviewStatus::Ready) {
      continue;
    }
    // The first sample is the plan's own access unit: no back-walk, no
    // discarded preroll, and nothing read before the random access point.
    const NativePreviewReadResult first = source->readNext(epoch);
    const MediaSample* sample = sampleOf(first);
    exact = exact && sample != nullptr && sample->keyFrame &&
            sameTime(sample->presentationTime, begun.actualDecodeStart) &&
            sample->sampleCount == 1 && sample->generation == epoch &&
            sample->payload;
    // A transport stream states a real decode timestamp, so the preview
    // decode is ordered by the stream's own decode order.
    exact = exact && sample != nullptr && sample->decodeTime.valid();
  }
  expect(exact,
         "every preview epoch begins on a sync access unit and emits it first");

  const NativePreviewSourceFacts facts = source->facts();
  expect(facts.backend.readersCreated == targets.size() &&
             facts.backend.readersStarted == targets.size(),
         "exactly one cursor is created and started per preview epoch");
  expect(facts.backend.assetLoadAttempts == 0 &&
             facts.backend.assetLoadsCompleted == 0 &&
             facts.backend.assetLoadNanoseconds == 0,
         "preview never reopens a container the main source already admitted");
}

void testDecodeOnlyBoundaryAndForwardRetarget(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "decodeOnly fixture prepares");
    return;
  }
  auto source = MpegTsPreviewSource::create(prepared.binding());
  if (source == nullptr) {
    expect(false, "decodeOnly fixture creates a preview source");
    return;
  }
  const MediaTime target{1, 1};
  const NativePreviewBeginOutcome begun =
      source->begin(NativePreviewRequest{1, target});
  expect(begun.status == NativePreviewStatus::Ready &&
             timeAtMost(begun.actualDecodeStart, target),
         "the decodeOnly epoch begins at or before its target");
  if (begun.status != NativePreviewStatus::Ready) {
    return;
  }
  bool boundary = true;
  bool sawDecodeOnly = false;
  bool sawCovering = false;
  for (int step = 0; step < 64 && !sawCovering; ++step) {
    const NativePreviewReadResult result = source->readNext(1);
    const MediaSample* sample = sampleOf(result);
    if (sample == nullptr) {
      break;
    }
    const auto expected = wam::macos::mpegTsAccurateVideoDecodeOnly(
        sample->presentationTime, sample->duration, target, nullptr);
    boundary = boundary && expected.has_value() &&
               *expected == sample->decodeOnly;
    sawDecodeOnly = sawDecodeOnly || sample->decodeOnly;
    sawCovering = sawCovering || !sample->decodeOnly;
  }
  expect(boundary && sawDecodeOnly && sawCovering,
         "samples whose interval closes at or before the target are decodeOnly "
         "and the covering sample is not");

  const NativePreviewSourceFacts before = source->facts();
  expect(!source->advanceTarget(1, MediaTime{1, 4}),
         "a retarget behind the current target is refused");
  expect(!source->advanceTarget(2, MediaTime{7, 5}),
         "a retarget for a stale epoch is refused");
  expect(!source->advanceTarget(1, MediaTime{500, 1}),
         "a retarget beyond the duration is refused");
  expect(!source->advanceTarget(1, MediaTime{-1, 1}),
         "a negative retarget is refused");
  expect(source->advanceTarget(1, MediaTime{7, 5}),
         "a nondecreasing in-duration retarget is accepted");
  const NativePreviewSourceFacts after = source->facts();
  expect(after.forwardRetargets == before.forwardRetargets + 1 &&
             after.backend.readersCreated == before.backend.readersCreated &&
             sameTime(after.target, MediaTime{7, 5}),
         "a forward retarget publishes the new target without a new cursor");
}

void testEndOfStreamIsIdempotent(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "end-of-stream fixture prepares");
    return;
  }
  auto source = MpegTsPreviewSource::create(prepared.binding());
  if (source == nullptr) {
    expect(false, "end-of-stream fixture creates a preview source");
    return;
  }
  const MediaTime duration = prepared.context->descriptor()->duration;
  const NativePreviewBeginOutcome begun =
      source->begin(NativePreviewRequest{1, duration});
  expect(begun.status == NativePreviewStatus::Ready,
         "an epoch at the end of the timeline begins");
  if (begun.status != NativePreviewStatus::Ready) {
    return;
  }
  std::size_t samples = 0;
  NativePreviewReadResult result = source->readNext(1);
  while (sampleOf(result) != nullptr && samples < 512) {
    ++samples;
    result = source->readNext(1);
  }
  expect(samples > 0 &&
             std::holds_alternative<NativePreviewEndOfStream>(result) &&
             std::holds_alternative<NativePreviewEndOfStream>(
                 source->readNext(1)),
         "the last cursor drains and then reports an idempotent end of stream");
  expect(source->facts().samplesRead == samples,
         "samplesRead counts exactly the emitted samples");
}

void testCancellation(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "cancellation fixture prepares");
    return;
  }
  auto source = MpegTsPreviewSource::create(prepared.binding());
  if (source == nullptr) {
    expect(false, "cancellation fixture creates a preview source");
    return;
  }
  expect(source->begin(NativePreviewRequest{1, MediaTime{1, 2}}).status ==
             NativePreviewStatus::Ready,
         "first cancellation epoch begins");
  expect(sampleOf(source->readNext(1)) != nullptr,
         "the live epoch reads before cancellation");

  source->requestCancel(99);
  expect(!source->facts().cancelled && source->facts().open,
         "a cancel for a foreign epoch leaves the live reader open");

  // requestCancel() is the only cross-thread entry point.
  std::thread canceller([&source] { source->requestCancel(1); });
  canceller.join();
  const NativePreviewReadResult cancelled = source->readNext(1);
  expect(std::holds_alternative<NativePreviewCancelled>(cancelled) &&
             std::get<NativePreviewCancelled>(cancelled).epoch == 1,
         "a cancelled epoch answers its next read with Cancelled");
  const NativePreviewSourceFacts afterCancel = source->facts();
  expect(!afterCancel.open && afterCancel.activeEpoch == 0 &&
             afterCancel.stagedSampleBuffers == 0,
         "cancellation retires the cursor and stages no sample buffer");
  expect(std::holds_alternative<NativePreviewCancelled>(source->readNext(1)),
         "a retired epoch stays cancelled");

  const NativePreviewBeginOutcome revived =
      source->begin(NativePreviewRequest{2, MediaTime{1, 1}});
  expect(revived.status == NativePreviewStatus::Ready &&
             sampleOf(source->readNext(2)) != nullptr,
         "a newer epoch replaces a cancelled one and reads");

  source->requestCancel(2);
  const NativePreviewBeginOutcome afterStaleCancel =
      source->begin(NativePreviewRequest{3, MediaTime{1, 1}});
  expect(afterStaleCancel.status == NativePreviewStatus::Ready,
         "a cancel for the previous epoch does not poison the next one");
}

void testRequestAdmission(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "admission fixture prepares");
    return;
  }
  auto source = MpegTsPreviewSource::create(prepared.binding());
  if (source == nullptr) {
    expect(false, "admission fixture creates a preview source");
    return;
  }
  expect(source->begin(NativePreviewRequest{0, MediaTime{0, 1}}).status ==
             NativePreviewStatus::Rejected,
         "epoch zero is refused");
  expect(source->begin(NativePreviewRequest{1, MediaTime{500, 1}}).status ==
             NativePreviewStatus::Rejected,
         "a target beyond the duration is refused");
  expect(source->begin(NativePreviewRequest{1, MediaTime{-1, 1}}).status ==
             NativePreviewStatus::Rejected,
         "a negative target is refused");
  expect(source->begin(NativePreviewRequest{5, MediaTime{1, 2}}).status ==
             NativePreviewStatus::Ready,
         "a valid epoch is admitted");
  expect(source->begin(NativePreviewRequest{5, MediaTime{1, 2}}).status ==
             NativePreviewStatus::Rejected,
         "an epoch equal to the high-water mark is refused");
  expect(source->begin(NativePreviewRequest{4, MediaTime{1, 2}}).status ==
             NativePreviewStatus::Rejected,
         "an epoch below the high-water mark is refused");
  const NativePreviewSourceFacts facts = source->facts();
  expect(facts.epochHighWater == 5 && facts.operationEpoch == 5 &&
             facts.activeEpoch == 5,
         "a refused request never moves the published epoch slots");
  expect(std::holds_alternative<NativePreviewCancelled>(source->readNext(4)),
         "reading a stale epoch is refused rather than served");
  source->close();
  const NativePreviewSourceFacts closed = source->facts();
  expect(!closed.open && closed.activeEpoch == 0 &&
             closed.operationEpoch == 0 && closed.epochHighWater == 5,
         "close retires the reader while the high-water mark survives");
}

void testBindingRejection(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "binding rejection fixture prepares");
    return;
  }
  NativePreviewBinding noContext = prepared.binding();
  noContext.assetContext.reset();
  expect(MpegTsPreviewSource::create(noContext) == nullptr,
         "the MPEG-TS preview source refuses a cold-load binding");

  NativePreviewBinding wrongPath = prepared.binding();
  wrongPath.localPath = fixture.directory / "other.ts";
  expect(MpegTsPreviewSource::create(wrongPath) == nullptr,
         "a binding naming another path is refused");

  NativePreviewBinding clonedDescriptor = prepared.binding();
  clonedDescriptor.descriptor =
      std::make_shared<const wam::media::MediaSourceDescriptor>(
          *prepared.context->descriptor());
  expect(MpegTsPreviewSource::create(clonedDescriptor) == nullptr,
         "a deep-equal descriptor clone is not descriptor identity");

  NativePreviewBinding relative = prepared.binding();
  relative.localPath = "preview.ts";
  expect(MpegTsPreviewSource::create(relative) == nullptr,
         "a relative path is refused");
}

void testNeutralFactorySelectsTheMpegTsSource(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "factory fixture prepares");
    return;
  }
  auto source = wam::macos::createNativePreviewSource(prepared.binding());
  expect(source != nullptr,
         "the neutral factory builds a source for an MPEG-TS context");
  if (source == nullptr) {
    return;
  }
  const NativePreviewBeginOutcome begun =
      source->begin(NativePreviewRequest{1, MediaTime{1, 1}});
  const NativePreviewReadResult first = source->readNext(1);
  const MediaSample* sample = sampleOf(first);
  expect(begun.status == NativePreviewStatus::Ready && sample != nullptr &&
             sample->keyFrame &&
             sameTime(sample->presentationTime, begun.actualDecodeStart),
         "the factory's MPEG-TS source previews through the neutral interface");
}

// The promoted builders are what let the preview source and the main media
// source hand VideoToolbox the same description and the same buffer shape.
// Calling them here from the preview side, in a binary that also links the
// main source, is the compile-and-link proof that the promotion is real.
void testPromotedSampleBuilders(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "sample builder fixture prepares");
    return;
  }
  const auto& descriptor = *prepared.context->descriptor();
  const wam::media::MediaTrackDescriptor* track =
      descriptor.selectedVideo
          ? wam::media::findMediaTrack(descriptor, *descriptor.selectedVideo)
          : nullptr;
  expect(track != nullptr, "the fixture publishes a selected video track");
  if (track == nullptr) {
    return;
  }
  CMVideoFormatDescriptionRef format =
      wam::macos::createMpegTsVideoFormatDescription(*track);
  expect(format != nullptr,
         "the promoted format factory builds a description for the admitted "
         "video track");
  if (format == nullptr) {
    return;
  }
  const CMVideoDimensions dimensions =
      CMVideoFormatDescriptionGetDimensions(format);
  expect(track->video.has_value() &&
             dimensions.width ==
                 static_cast<std::int32_t>(track->video->codedWidth) &&
             dimensions.height ==
                 static_cast<std::int32_t>(track->video->codedHeight),
         "the promoted description restates the admitted geometry");
  CFRelease(format);

  auto source = MpegTsPreviewSource::create(prepared.binding());
  if (source == nullptr ||
      source->begin(NativePreviewRequest{1, MediaTime{1, 2}}).status !=
          NativePreviewStatus::Ready) {
    expect(false, "sample builder fixture opens a preview epoch");
    return;
  }
  const NativePreviewReadResult result = source->readNext(1);
  const MediaSample* sample = sampleOf(result);
  expect(sample != nullptr && sample->payload,
         "the preview publishes a payload-bearing sample");
  if (sample == nullptr) {
    return;
  }
  const auto borrowed = sample->payload.borrowNative<
      wam::media::NativePayloadKind::CoreMediaSampleBuffer>();
  CMSampleBufferRef buffer =
      borrowed ? static_cast<CMSampleBufferRef>(
                     const_cast<void*>(borrowed->opaqueAddress()))
               : nullptr;
  expect(buffer != nullptr && CMSampleBufferIsValid(buffer) &&
             CMSampleBufferDataIsReady(buffer) &&
             CMSampleBufferGetNumSamples(buffer) == 1,
         "the promoted builder produced a ready one-access-unit buffer");
  if (buffer == nullptr) {
    return;
  }
  const CMTime presentation = CMSampleBufferGetPresentationTimeStamp(buffer);
  expect(presentation.value == sample->presentationTime.value &&
             presentation.timescale == sample->presentationTime.timescale,
         "container rationals reach CoreMedia without a seconds round trip");
  const CMTime decode = CMSampleBufferGetDecodeTimeStamp(buffer);
  expect(CMTIME_IS_VALID(decode) && decode.value == sample->decodeTime.value &&
             decode.timescale == sample->decodeTime.timescale,
         "the preview buffer restates the container's own decode timestamp");
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(buffer, false);
  bool notSyncIsFalse = false;
  if (attachments != nullptr && CFArrayGetCount(attachments) == 1) {
    auto entry =
        static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
    CFTypeRef notSync =
        CFDictionaryGetValue(entry, kCMSampleAttachmentKey_NotSync);
    notSyncIsFalse = notSync != nullptr &&
                     CFGetTypeID(notSync) == CFBooleanGetTypeID() &&
                     !CFBooleanGetValue(static_cast<CFBooleanRef>(notSync));
  }
  expect(notSyncIsFalse,
         "the plan's access unit is stated to VideoToolbox as a sync sample");
}

void testMemoryFactsStageAtMostOneBuffer(const Fixture& fixture) {
  const PreparedFixture prepared = prepare(fixture);
  if (prepared.context == nullptr) {
    expect(false, "memory facts fixture prepares");
    return;
  }
  auto source = MpegTsPreviewSource::create(prepared.binding());
  if (source == nullptr ||
      source->begin(NativePreviewRequest{1, MediaTime{1, 2}}).status !=
          NativePreviewStatus::Ready) {
    expect(false, "memory facts fixture opens a preview epoch");
    return;
  }
  expect(source->memoryFacts().stagedSamples == 0,
         "an opened epoch stages nothing before its first read");
  const NativePreviewReadResult result = source->readNext(1);
  expect(sampleOf(result) != nullptr, "memory facts fixture reads a sample");
  const auto after = source->memoryFacts();
  expect(after.stagedSamples == 0 && after.currentStagedCompressedBytes == 0 &&
             after.peakStagedCompressedBytes > 0,
         "the source retains no buffer after readNext transfers its reference");
}

// The preview cursor is independent of the main source's playback cursors:
// the two share only const state and the asset's own retained descriptor.
void testPreviewIsIndependentOfTheMainSource(const Fixture& fixture) {
  wam::macos::MpegTsMediaSource main;
  MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  expect(main.armOperation(1), "the main generation arms");
  const auto opened = main.openLocalFile(fixture.stream, options, 1);
  expect(opened.status == wam::media::MediaSourceOpenStatus::Ready,
         "the main source admits the fixture");
  if (opened.status != wam::media::MediaSourceOpenStatus::Ready) {
    return;
  }
  NativePreviewBinding binding;
  binding.localPath = fixture.stream;
  binding.descriptor = opened.descriptor;
  binding.assetContext = opened.preparedContext;
  auto preview = MpegTsPreviewSource::create(binding);
  expect(preview != nullptr,
         "a preview source binds to the context the main source admitted");
  if (preview == nullptr) {
    return;
  }
  expect(preview->begin(NativePreviewRequest{1, MediaTime{2, 1}}).status ==
             NativePreviewStatus::Ready,
         "the preview epoch begins while the main generation is live");
  const MediaSample* previewSample = sampleOf(preview->readNext(1));
  expect(previewSample != nullptr && previewSample->keyFrame,
         "the preview reads its own cursor");
  auto mainRead = main.readNext(1);
  expect(std::get_if<MediaSample>(&mainRead) != nullptr,
         "the main generation still reads after the preview cursor exists");
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2 || argv[1] == nullptr || *argv[1] == '\0' ||
      !std::filesystem::exists(argv[1])) {
    std::cerr << "mpeg-ts preview source contracts need a muxer; skipping\n";
    return 77;
  }
  Fixture fixture;
  buildFixture(argv[1], fixture);
  if (!fixture.valid) {
    std::cerr << "FAIL: fixture could not be muxed\n";
    return 1;
  }

  testFixtureAdmitsAndSelectsVideo(fixture);
  testPlanMappingWithoutBackWalk(fixture);
  testDecodeOnlyBoundaryAndForwardRetarget(fixture);
  testEndOfStreamIsIdempotent(fixture);
  testCancellation(fixture);
  testRequestAdmission(fixture);
  testBindingRejection(fixture);
  testNeutralFactorySelectsTheMpegTsSource(fixture);
  testPromotedSampleBuilders(fixture);
  testMemoryFactsStageAtMostOneBuffer(fixture);
  testPreviewIsIndependentOfTheMainSource(fixture);

  if (failures == 0) {
    std::cout << "mpeg-ts preview source contracts passed\n";
  }
  return failures == 0 ? 0 : 1;
}
