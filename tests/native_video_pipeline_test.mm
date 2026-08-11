#include "platform/macos/native_video_pipeline.hpp"

#import <AVFoundation/AVFoundation.h>

#include <mach/mach.h>
#include <sys/resource.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
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

  const auto videoOnlyResult =
      pipeline->prepareLocalFile(videoOnlyFixture.path, 0.0, &error);
  WAM_CHECK(videoOnlyResult ==
            wam::macos::NativeVideoPrepareResult::Unsupported);
  WAM_CHECK_DETAIL(error.find("audio track") != std::string::npos, error);
  WAM_CHECK(!pipeline->active());

  const std::uint64_t residentBefore = residentBytes();
  const double cpuBefore = processCpuSeconds();
  const auto wallStart = std::chrono::steady_clock::now();
  const auto prepare = pipeline->prepareLocalFile(argv[1], 0.0, &error);
  WAM_CHECK_DETAIL(prepare == wam::macos::NativeVideoPrepareResult::Ready,
                   error);
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
  // No view is attached in this non-GUI integration test. Drawable absence is
  // intentionally non-fatal; callback coalescing makes the exact count
  // scheduler-dependent.

  const std::uint64_t firstGeneration = initial.generation;
  const std::uint64_t submissionsBeforeSeek =
      initial.compressedSamplesSubmitted;
  const std::uint64_t drawableAttemptsBeforeSeek =
      initial.drawableUnavailableEvents;
  // Deliberately seek between frame timestamps. A paused clock must choose the
  // nearest frame at/after the target instead of waiting forever for exact PTS.
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

  pipeline->stop();
  WAM_CHECK(!pipeline->active());
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

  std::cout << "Native pipeline demux/decode/seek/shutdown passed; "
            << "wall=" << wallSeconds << "s cpu=" << (cpuAfter - cpuBefore)
            << "s resident_delta=" << residentDeltaMiB
            << "MiB submitted=" << afterSeek.compressedSamplesSubmitted
            << " delivered=" << afterSeek.decoder.deliveredFrames << '\n';
  return EXIT_SUCCESS;
}
