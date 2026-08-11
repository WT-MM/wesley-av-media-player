#include "platform/macos/native_video_pipeline.hpp"

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <mach/mach.h>
#include <sys/resource.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <thread>

namespace {

void check(bool condition, const char* expression, int line,
           const std::string& detail = {}) {
  if (condition) {
    return;
  }
  std::cerr << "CHECK failed at line " << line << ": " << expression;
  if (!detail.empty()) {
    std::cerr << " (" << detail << ')';
  }
  std::cerr << '\n';
  std::exit(EXIT_FAILURE);
}

#define WAM_CHECK(expression)                                                  \
  check(static_cast<bool>(expression), #expression, __LINE__)
#define WAM_CHECK_DETAIL(expression, detail)                                   \
  check(static_cast<bool>(expression), #expression, __LINE__, (detail))

std::uint64_t residentBytes() {
  mach_task_basic_info_data_t information{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&information),
                &count) != KERN_SUCCESS) {
    return 0;
  }
  return information.resident_size;
}

double processCpuSeconds() {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) {
    return 0.0;
  }
  const auto seconds = [](const timeval& value) {
    return static_cast<double>(value.tv_sec) +
           static_cast<double>(value.tv_usec) / 1'000'000.0;
  };
  return seconds(usage.ru_utime) + seconds(usage.ru_stime);
}

template <typename Predicate>
bool waitUntil(Predicate predicate,
               std::chrono::milliseconds timeout =
                   std::chrono::milliseconds(5000)) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return predicate();
}

std::optional<wam::macos::NativeVideoPrepareOutcome> waitForPrepareResult(
    wam::macos::NativeVideoPipeline& pipeline,
    std::chrono::milliseconds timeout = std::chrono::milliseconds(5000)) {
  std::optional<wam::macos::NativeVideoPrepareOutcome> outcome;
  const bool completed = waitUntil(
      [&] {
        outcome = pipeline.takePrepareResult();
        return outcome.has_value();
      },
      timeout);
  return completed ? std::move(outcome) : std::nullopt;
}

std::optional<wam::macos::NativeVideoPrepareOutcome> startAndWait(
    wam::macos::NativeVideoPipeline& pipeline,
    const std::filesystem::path& path, double position,
    std::string* startError,
    std::chrono::milliseconds timeout = std::chrono::milliseconds(5000)) {
  if (!pipeline.prepareLocalFileAsync(path, position, startError)) {
    return std::nullopt;
  }
  return waitForPrepareResult(pipeline, timeout);
}

struct TemporaryFile {
  std::filesystem::path path;

  ~TemporaryFile() {
    if (!path.empty()) {
      std::error_code error;
      std::filesystem::remove(path, error);
    }
  }
};

std::filesystem::path makeVideoOnlyFixture(
    const std::filesystem::path& sourcePath, std::string* error) {
  @autoreleasepool {
    NSString* sourceString = [NSString stringWithUTF8String:sourcePath.c_str()];
    AVURLAsset* source = [AVURLAsset
        URLAssetWithURL:[NSURL fileURLWithPath:sourceString]
                options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* sourceVideo =
        [source tracksWithMediaType:AVMediaTypeVideo].firstObject;
#pragma clang diagnostic pop
    if (sourceVideo == nil) {
      *error = "source fixture has no video track";
      return {};
    }

    AVMutableComposition* composition = [AVMutableComposition composition];
    AVMutableCompositionTrack* video = [composition
        addMutableTrackWithMediaType:AVMediaTypeVideo
                    preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError* insertionError = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const bool inserted = [video insertTimeRange:sourceVideo.timeRange
                                         ofTrack:sourceVideo
                                          atTime:kCMTimeZero
                                           error:&insertionError];
#pragma clang diagnostic pop
    if (!inserted) {
      *error = insertionError == nil
                   ? "could not create the video-only fixture"
                   : std::string(
                         insertionError.localizedDescription.UTF8String);
      return {};
    }

    NSString* name = [NSString
        stringWithFormat:@"wam-native-video-only-%@.mov", [NSUUID UUID].UUIDString];
    NSString* outputString = [NSTemporaryDirectory()
        stringByAppendingPathComponent:name];
    NSURL* outputURL = [NSURL fileURLWithPath:outputString];
    AVAssetExportSession* exporter = [[AVAssetExportSession alloc]
        initWithAsset:composition
           presetName:AVAssetExportPresetPassthrough];
    if (exporter == nil) {
      *error = "AVFoundation could not create a passthrough exporter";
      return {};
    }
    exporter.outputURL = outputURL;
    exporter.outputFileType = AVFileTypeQuickTimeMovie;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [exporter exportAsynchronouslyWithCompletionHandler:^{
      dispatch_semaphore_signal(finished);
    }];
    if (dispatch_semaphore_wait(
            finished,
            dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
      [exporter cancelExport];
      *error = "video-only fixture export timed out";
      return {};
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const AVAssetExportSessionStatus status = exporter.status;
    NSError* exportError = exporter.error;
#pragma clang diagnostic pop
    if (status != AVAssetExportSessionStatusCompleted) {
      *error = exportError == nil
                   ? "video-only fixture export failed"
                   : std::string(exportError.localizedDescription.UTF8String);
      return {};
    }
    return std::filesystem::path(outputString.fileSystemRepresentation);
  }
}

std::optional<CMVideoCodecType> fixtureVideoCodec(
    const std::filesystem::path& sourcePath, std::string* error) {
  @autoreleasepool {
    NSString* sourceString = [NSString stringWithUTF8String:sourcePath.c_str()];
    AVURLAsset* source = [AVURLAsset
        URLAssetWithURL:[NSURL fileURLWithPath:sourceString]
                options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack* videoTrack =
        [source tracksWithMediaType:AVMediaTypeVideo].firstObject;
#pragma clang diagnostic pop
    if (videoTrack == nil) {
      *error = "source fixture has no video track";
      return std::nullopt;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray* descriptions = videoTrack.formatDescriptions;
#pragma clang diagnostic pop
    if (descriptions.count == 0) {
      *error = "source fixture video track has no format description";
      return std::nullopt;
    }
    CMFormatDescriptionRef description =
        (__bridge CMFormatDescriptionRef)descriptions.firstObject;
    return CMFormatDescriptionGetMediaSubType(description);
  }
}

const char* codecName(CMVideoCodecType codec) {
  if (codec == kCMVideoCodecType_H264) {
    return "H.264 (avc1)";
  }
  if (codec == kCMVideoCodecType_HEVC) {
    return "HEVC (hvc1)";
  }
  return "unsupported codec";
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: native_video_pipeline_test <h264-or-hevc-file>\n";
    return EXIT_FAILURE;
  }

  std::string fixtureError;
  TemporaryFile videoOnlyFixture{
      makeVideoOnlyFixture(argv[1], &fixtureError)};
  WAM_CHECK_DETAIL(!videoOnlyFixture.path.empty(), fixtureError);

  std::string error;
  auto pipeline = wam::macos::NativeVideoPipeline::create(&error);
  if (!pipeline) {
    std::cerr << "SKIP: native Metal/display-link path unavailable: " << error
              << '\n';
    return 77;
  }

  // Unsupported media is also reported asynchronously. Starting the request
  // never reads AVAsset state on this caller.
  WAM_CHECK_DETAIL(pipeline->prepareLocalFileAsync(
                       videoOnlyFixture.path, 0.0, &error),
                   error);
  bool unexpectedAdmission = false;
  const bool videoOnlyResultPending = waitUntil([&] {
    std::string retryError;
    if (pipeline->prepareLocalFileAsync(argv[1], 0.0, &retryError)) {
      unexpectedAdmission = true;
      return true;
    }
    return retryError.find("consume the previous") != std::string::npos;
  });
  WAM_CHECK(videoOnlyResultPending);
  WAM_CHECK(!unexpectedAdmission);
  auto videoOnlyOutcome = pipeline->takePrepareResult();
  WAM_CHECK_DETAIL(videoOnlyOutcome.has_value(), error);
  WAM_CHECK(videoOnlyOutcome->result ==
            wam::macos::NativeVideoPrepareResult::Unsupported);
  WAM_CHECK_DETAIL(videoOnlyOutcome->error.find("audio track") !=
                       std::string::npos,
                   videoOnlyOutcome->error);
  WAM_CHECK(videoOnlyOutcome->generation != 0);
  WAM_CHECK(!pipeline->takePrepareResult().has_value());
  WAM_CHECK(!pipeline->active());

  std::string codecError;
  const auto codec = fixtureVideoCodec(argv[1], &codecError);
  WAM_CHECK_DETAIL(codec.has_value(), codecError);
  WAM_CHECK(*codec == kCMVideoCodecType_H264 ||
            *codec == kCMVideoCodecType_HEVC);
  if (!VTIsHardwareDecodeSupported(*codec)) {
    std::cout << "SKIP: this runner has no hardware VideoToolbox decoder for "
              << codecName(*codec)
              << "; asynchronous unsupported-media probing passed before the "
                 "capability check\n";
    return 77;
  }

  // Hold AVFoundation's real asset-load completion before its continuation is
  // delivered. The public call must return promptly, stop() must issue
  // cancelLoading from the private queue, and process admission must remain
  // closed until the in-flight callback is released and acknowledges cancel.
  std::promise<void> slowCancellationRelease;
  auto slowCancellationEntered =
      std::make_shared<std::atomic<bool>>(false);
  auto slowCancellationIssued =
      std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setAssetLoadCallbackBarrier(
      *pipeline, slowCancellationRelease.get_future().share(),
      slowCancellationEntered);
  wam::macos::NativeVideoPipelineTestAccess::setPreparationCancellationMarker(
      *pipeline, slowCancellationIssued);
  const auto slowStart = std::chrono::steady_clock::now();
  WAM_CHECK_DETAIL(
      pipeline->prepareLocalFileAsync(argv[1], 0.0, &error), error);
  const auto slowStartElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - slowStart);
  WAM_CHECK(slowStartElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return slowCancellationEntered->load(std::memory_order_acquire);
  }));
  WAM_CHECK(!pipeline->takePrepareResult().has_value());
  const auto loadingStopStart = std::chrono::steady_clock::now();
  pipeline->stop();
  const auto loadingStopElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - loadingStopStart);
  WAM_CHECK(loadingStopElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return slowCancellationIssued->load(std::memory_order_acquire);
  }));
  auto loadingContender =
      wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(loadingContender != nullptr, error);
  WAM_CHECK(!loadingContender->prepareLocalFileAsync(
      argv[1], 0.0, &error));
  WAM_CHECK_DETAIL(error.find("another native video attempt") !=
                       std::string::npos,
                   error);
  WAM_CHECK(!pipeline->takePrepareResult().has_value());
  slowCancellationRelease.set_value();
  auto loadingCancelled = waitForPrepareResult(*pipeline);
  WAM_CHECK(loadingCancelled.has_value());
  WAM_CHECK(loadingCancelled->result ==
            wam::macos::NativeVideoPrepareResult::Failed);
  WAM_CHECK_DETAIL(loadingCancelled->error ==
                       "native video preparation was cancelled",
                   loadingCancelled->error);
  WAM_CHECK(loadingCancelled->generation > videoOnlyOutcome->generation);
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));
  WAM_CHECK(!pipeline->active());
  loadingContender.reset();

  // A slow-but-successful load follows the same prompt caller contract.
  std::promise<void> slowSuccessRelease;
  auto slowSuccessEntered = std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setPreparationLoadBarrier(
      *pipeline, slowSuccessRelease.get_future().share(), slowSuccessEntered);
  const auto slowSuccessStart = std::chrono::steady_clock::now();
  WAM_CHECK_DETAIL(
      pipeline->prepareLocalFileAsync(argv[1], 0.0, &error), error);
  const auto slowSuccessStartElapsed =
      std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - slowSuccessStart);
  WAM_CHECK(slowSuccessStartElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return slowSuccessEntered->load(std::memory_order_acquire);
  }));
  WAM_CHECK(!pipeline->takePrepareResult().has_value());
  slowSuccessRelease.set_value();
  auto slowSuccessOutcome = waitForPrepareResult(*pipeline);
  WAM_CHECK(slowSuccessOutcome.has_value());
  WAM_CHECK_DETAIL(slowSuccessOutcome->result ==
                       wam::macos::NativeVideoPrepareResult::Ready,
                   slowSuccessOutcome->error);
  WAM_CHECK(slowSuccessOutcome->generation > loadingCancelled->generation);
  WAM_CHECK(waitUntil([&] {
    return pipeline->stats().compressedSamplesSubmitted >= 1;
  }));
  pipeline->stop();
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));

  // An allocation/thread-construction exception must never cross a GCD block.
  // Inject one after AVFoundation ownership has moved into Impl so the test
  // also proves partial resources retire before process admission reopens.
  wam::macos::NativeVideoPipelineTestAccess::
      failNextPreparationAfterResourceTransfer(*pipeline);
  WAM_CHECK_DETAIL(
      pipeline->prepareLocalFileAsync(argv[1], 0.0, &error), error);
  auto exceptionOutcome = waitForPrepareResult(*pipeline);
  WAM_CHECK(exceptionOutcome.has_value());
  WAM_CHECK(exceptionOutcome->result ==
            wam::macos::NativeVideoPrepareResult::Failed);
  WAM_CHECK_DETAIL(exceptionOutcome->error == "native prep failed",
                   exceptionOutcome->error);
  WAM_CHECK(exceptionOutcome->generation > slowSuccessOutcome->generation);
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));
  WAM_CHECK(!pipeline->stats().decoder.configured);

  // Pause after a decoder is configured but before preparation can commit.
  // stop() must revoke that Preparing attempt without waiting, and the worker
  // must never start after the barrier is released.
  std::promise<void> preparationRelease;
  auto preparationEntered = std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setPreparationCommitBarrier(
      *pipeline, preparationRelease.get_future().share(), preparationEntered);
  WAM_CHECK_DETAIL(
      pipeline->prepareLocalFileAsync(argv[1], 0.0, &error), error);
  WAM_CHECK(waitUntil([&] {
    return preparationEntered->load(std::memory_order_acquire);
  }));
  const auto preparingStopStart = std::chrono::steady_clock::now();
  pipeline->stop();
  const auto preparingStopElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - preparingStopStart);
  WAM_CHECK(preparingStopElapsed < std::chrono::milliseconds(250));
  preparationRelease.set_value();
  auto cancelledPrepare = waitForPrepareResult(*pipeline);
  WAM_CHECK(cancelledPrepare.has_value());
  WAM_CHECK(cancelledPrepare->result ==
            wam::macos::NativeVideoPrepareResult::Failed);
  WAM_CHECK_DETAIL(cancelledPrepare->error ==
                       "native video preparation was cancelled",
                   cancelledPrepare->error);
  WAM_CHECK(cancelledPrepare->generation > exceptionOutcome->generation);
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));
  WAM_CHECK(!pipeline->active());

  // Destruction while the selected track's property load callback is held is
  // also non-blocking. No client callback exists; the self-owned request
  // publishes cancellation internally, retires, and only then releases
  // process-wide admission.
  auto loadingDestructionPipeline =
      wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(loadingDestructionPipeline != nullptr, error);
  std::promise<void> destructionLoadRelease;
  auto destructionLoadEntered = std::make_shared<std::atomic<bool>>(false);
  auto destructionCancellationIssued =
      std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setTrackLoadCallbackBarrier(
      *loadingDestructionPipeline,
      destructionLoadRelease.get_future().share(), destructionLoadEntered);
  wam::macos::NativeVideoPipelineTestAccess::setPreparationCancellationMarker(
      *loadingDestructionPipeline, destructionCancellationIssued);
  WAM_CHECK_DETAIL(loadingDestructionPipeline->prepareLocalFileAsync(
                       argv[1], 0.0, &error),
                   error);
  WAM_CHECK(waitUntil([&] {
    return destructionLoadEntered->load(std::memory_order_acquire);
  }));
  const auto loadingDestructionStart = std::chrono::steady_clock::now();
  loadingDestructionPipeline.reset();
  const auto loadingDestructionElapsed =
      std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - loadingDestructionStart);
  WAM_CHECK(loadingDestructionElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return destructionCancellationIssued->load(std::memory_order_acquire);
  }));
  WAM_CHECK(!pipeline->prepareLocalFileAsync(argv[1], 0.0, &error));
  WAM_CHECK_DETAIL(error.find("another native video attempt") !=
                       std::string::npos,
                   error);
  destructionLoadRelease.set_value();

  const std::uint64_t residentBefore = residentBytes();
  const double cpuBefore = processCpuSeconds();
  const auto wallStart = std::chrono::steady_clock::now();

  // Admission of this request is the deterministic completion signal for the
  // destroyed loading request; rejected retries do not enqueue notifications.
  bool prepareAccepted = waitUntil([&] {
    return pipeline->prepareLocalFileAsync(argv[1], 0.0, &error);
  });
  WAM_CHECK_DETAIL(prepareAccepted, error);
  auto prepare = waitForPrepareResult(*pipeline);
  WAM_CHECK(prepare.has_value());
  WAM_CHECK_DETAIL(
      prepare->result == wam::macos::NativeVideoPrepareResult::Ready,
      prepare->error);
  WAM_CHECK(waitUntil([&] {
    const auto stats = pipeline->stats();
    return stats.hardwareDecode && stats.compressedSamplesSubmitted >= 3 &&
           stats.decoder.deliveredFrames >= 1;
  }));

  const auto initial = pipeline->stats();
  WAM_CHECK(initial.active);
  WAM_CHECK(initial.hardwareDecode);
  WAM_CHECK(initial.queueCapacity == 3);
  WAM_CHECK(initial.queueDepth <= initial.queueCapacity);
  WAM_CHECK(initial.decoder.inFlightFrames <=
            initial.decoder.maxInFlightFrames);
  WAM_CHECK(initial.decoder.pendingPresentationFrames <= 3);

  // The bound is process-wide, not merely per frontend: a caller cannot evade
  // an active/retiring session's admission lease by constructing another
  // NativeVideoPipeline and piling up VideoToolbox resources.
  auto contender = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(contender != nullptr, error);
  WAM_CHECK(!contender->prepareLocalFileAsync(argv[1], 0.0, &error));
  WAM_CHECK_DETAIL(error.find("another native video attempt") !=
                       std::string::npos,
                   error);
  WAM_CHECK(!contender->takePrepareResult().has_value());

  const std::uint64_t firstGeneration = initial.generation;
  const std::uint64_t submissionsBeforeSeek =
      initial.compressedSamplesSubmitted;
  const std::uint64_t drawableAttemptsBeforeSeek =
      initial.drawableUnavailableEvents;
  pipeline->seek(2.017);
  WAM_CHECK(waitUntil([&] {
    const auto stats = pipeline->stats();
    return stats.generation == firstGeneration + 1 &&
           stats.decoder.generation == stats.generation &&
           stats.compressedSamplesSubmitted > submissionsBeforeSeek &&
           stats.drawableUnavailableEvents > drawableAttemptsBeforeSeek;
  }));

  const auto afterSeek = pipeline->stats();
  WAM_CHECK(afterSeek.active);
  WAM_CHECK(afterSeek.queueDepth <= afterSeek.queueCapacity);
  WAM_CHECK(afterSeek.decoder.inFlightFrames <=
            afterSeek.decoder.maxInFlightFrames);
  WAM_CHECK(afterSeek.decoder.pendingPresentationFrames <= 3);
  const auto asyncFailure = pipeline->takeLastError();
  WAM_CHECK_DETAIL(!asyncFailure.has_value(),
                   asyncFailure.value_or(std::string{}));

  // Detach owns only the immediate AppKit layer mutation. AVAssetReader worker
  // join and VideoToolbox callback drain must be transferred to the private
  // retirement owner rather than stalling this main thread.
  NSView* hostView = [[NSView alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 360.0)];
  WAM_CHECK_DETAIL(pipeline->attachToView((__bridge void*)hostView, &error),
                   error);
  WAM_CHECK(pipeline->attached());
  const auto detachStart = std::chrono::steady_clock::now();
  pipeline->detach();
  const auto detachElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - detachStart);
  WAM_CHECK(detachElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(!pipeline->active());
  WAM_CHECK(!pipeline->attached());
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));
  const auto stopped = pipeline->stats();
  WAM_CHECK(!stopped.prepared);
  WAM_CHECK(!stopped.decoder.configured);
  WAM_CHECK(stopped.queueDepth == 0);

  // Once the single retirement slot is clear the same frontend can prepare a
  // fresh generation.
  auto restarted = startAndWait(*pipeline, argv[1], 0.0, &error);
  WAM_CHECK(restarted.has_value());
  WAM_CHECK_DETAIL(
      restarted->result == wam::macos::NativeVideoPrepareResult::Ready,
      restarted->error);
  WAM_CHECK(waitUntil([&] {
    const auto stats = pipeline->stats();
    return stats.active && stats.compressedSamplesSubmitted >= 1;
  }));
  const auto stopStart = std::chrono::steady_clock::now();
  pipeline->stop();
  const auto stopElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - stopStart);
  WAM_CHECK(stopElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(!pipeline->active());
  WAM_CHECK(waitUntil([&] { return !pipeline->stats().stopping; }));

  // Explicitly exercise the Retiring -> Finalizing upgrade.
  auto contenderReady = startAndWait(*contender, argv[1], 0.0, &error);
  WAM_CHECK(contenderReady.has_value());
  WAM_CHECK_DETAIL(
      contenderReady->result == wam::macos::NativeVideoPrepareResult::Ready,
      contenderReady->error);
  WAM_CHECK(waitUntil([&] {
    return contender->stats().compressedSamplesSubmitted >= 1;
  }));
  std::promise<void> upgradeRetirementRelease;
  auto upgradeRetirementEntered =
      std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setRetirementBarrier(
      *contender, upgradeRetirementRelease.get_future().share(),
      upgradeRetirementEntered);
  contender->stop();
  WAM_CHECK(waitUntil([&] {
    return upgradeRetirementEntered->load(std::memory_order_acquire);
  }));
  const auto upgradeDestructionStart = std::chrono::steady_clock::now();
  contender.reset();
  const auto upgradeDestructionElapsed =
      std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - upgradeDestructionStart);
  WAM_CHECK(upgradeDestructionElapsed < std::chrono::milliseconds(250));
  upgradeRetirementRelease.set_value();

  // Active destruction follows the same transfer contract.
  auto destructionPipeline = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(destructionPipeline != nullptr, error);
  bool destructionAccepted = waitUntil([&] {
    return destructionPipeline->prepareLocalFileAsync(
        argv[1], 0.0, &error);
  });
  WAM_CHECK_DETAIL(destructionAccepted, error);
  auto destructionReady = waitForPrepareResult(*destructionPipeline);
  WAM_CHECK(destructionReady.has_value());
  WAM_CHECK_DETAIL(
      destructionReady->result == wam::macos::NativeVideoPrepareResult::Ready,
      destructionReady->error);
  WAM_CHECK(waitUntil([&] {
    return destructionPipeline->stats().compressedSamplesSubmitted >= 1;
  }));
  std::promise<void> activeRetirementRelease;
  auto activeRetirementEntered =
      std::make_shared<std::atomic<bool>>(false);
  wam::macos::NativeVideoPipelineTestAccess::setRetirementBarrier(
      *destructionPipeline, activeRetirementRelease.get_future().share(),
      activeRetirementEntered);
  const auto destructionStart = std::chrono::steady_clock::now();
  destructionPipeline.reset();
  const auto destructionElapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - destructionStart);
  WAM_CHECK(destructionElapsed < std::chrono::milliseconds(250));
  WAM_CHECK(waitUntil([&] {
    return activeRetirementEntered->load(std::memory_order_acquire);
  }));
  activeRetirementRelease.set_value();

  // Admission does not reopen until the destroyed frontend's decoder and sink
  // have completed their self-owned close.
  auto completionProbe = wam::macos::NativeVideoPipeline::create(&error);
  WAM_CHECK_DETAIL(completionProbe != nullptr, error);
  bool completionAccepted = waitUntil([&] {
    return completionProbe->prepareLocalFileAsync(argv[1], 0.0, &error);
  });
  WAM_CHECK_DETAIL(completionAccepted, error);
  auto completionReady = waitForPrepareResult(*completionProbe);
  WAM_CHECK(completionReady.has_value());
  WAM_CHECK_DETAIL(
      completionReady->result == wam::macos::NativeVideoPrepareResult::Ready,
      completionReady->error);
  completionProbe->stop();
  WAM_CHECK(waitUntil([&] { return !completionProbe->stats().stopping; }));

  const auto wallEnd = std::chrono::steady_clock::now();
  const double cpuAfter = processCpuSeconds();
  const std::uint64_t residentAfter = residentBytes();
  const double wallSeconds =
      std::chrono::duration<double>(wallEnd - wallStart).count();
  const double residentDeltaMiB =
      residentAfter >= residentBefore
          ? static_cast<double>(residentAfter - residentBefore) /
                (1024.0 * 1024.0)
          : 0.0;

  std::cout
      << "Native asynchronous probe/decode/seek/shutdown passed; wall="
      << wallSeconds << "s cpu=" << (cpuAfter - cpuBefore)
      << "s resident_delta=" << residentDeltaMiB
      << "MiB slow_start_ms=" << slowStartElapsed.count()
      << " slow_success_start_ms=" << slowSuccessStartElapsed.count()
      << " loading_stop_ms=" << loadingStopElapsed.count()
      << " preparing_stop_ms=" << preparingStopElapsed.count()
      << " loading_destroy_ms=" << loadingDestructionElapsed.count()
      << " detach_ms=" << detachElapsed.count()
      << " stop_ms=" << stopElapsed.count()
      << " stop_destroy_ms=" << upgradeDestructionElapsed.count()
      << " destroy_ms=" << destructionElapsed.count()
      << " submitted=" << afterSeek.compressedSamplesSubmitted
      << " delivered=" << afterSeek.decoder.deliveredFrames << '\n';
  return EXIT_SUCCESS;
}
