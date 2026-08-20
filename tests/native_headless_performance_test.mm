#include "media/native_media_source.hpp"
#include "platform/macos/avfoundation_media_source.hpp"
#include "platform/macos/avfoundation_preview_source.hpp"

#include <mach/mach.h>
#include <sys/resource.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <numeric>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace {

using wam::macos::AVFoundationAssetContext;
using wam::macos::AVFoundationAssetContextFacts;
using wam::macos::AVFoundationMediaSource;
using wam::macos::NativePreviewBinding;
using wam::macos::NativePreviewEndOfStream;
using wam::macos::NativePreviewFailure;
using wam::macos::NativePreviewReadResult;
using wam::macos::AVFoundationPreviewSource;
using wam::macos::NativePreviewStatus;
using wam::media::MediaDiscontinuity;
using wam::media::MediaSample;
using wam::media::MediaSampleKind;
using wam::media::MediaSeekMode;
using wam::media::MediaSourceLimits;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaSourceOpenStatus;
using wam::media::MediaTime;

using Clock = std::chrono::steady_clock;

struct TimingReport final {
  double coldOpenMilliseconds{0.0};
  std::size_t reusedSeekCount{0};
  double firstSeekMilliseconds{0.0};
  double seekP50Milliseconds{0.0};
  double seekP95Milliseconds{0.0};
  double seekMaximumMilliseconds{0.0};
  double previewStartMilliseconds{0.0};
  double forwardRetargetTotalMilliseconds{0.0};
  double retargetP50Milliseconds{0.0};
  double retargetP95Milliseconds{0.0};
  double retargetMaximumMilliseconds{0.0};
  double processCpuMilliseconds{0.0};
  std::optional<std::uint64_t> residentAfterOpenBytes;
  std::optional<std::uint64_t> footprintAfterOpenBytes;
  std::optional<std::uint64_t> residentAfterCloseBytes;
  std::optional<std::uint64_t> footprintAfterCloseBytes;
  std::optional<std::uint64_t> peakResidentBytes;
};

struct MemorySnapshot final {
  std::optional<std::uint64_t> residentBytes;
  std::optional<std::uint64_t> footprintBytes;
};

[[noreturn]] void fail(std::string message) {
  throw std::runtime_error(std::move(message));
}

void require(bool condition, std::string_view message) {
  if (!condition) {
    fail(std::string(message));
  }
}

template <typename Duration>
[[nodiscard]] double milliseconds(Duration value) noexcept {
  return std::chrono::duration<double, std::milli>(value).count();
}

[[nodiscard]] double percentile(std::vector<double> values,
                                double quantile) {
  require(!values.empty() && quantile > 0.0 && quantile <= 1.0,
          "timing percentile input is invalid");
  std::sort(values.begin(), values.end());
  const std::size_t rank = static_cast<std::size_t>(
      std::ceil(quantile * static_cast<double>(values.size())));
  return values[std::min(values.size() - 1,
                         rank == 0 ? std::size_t{0} : rank - 1)];
}

[[nodiscard]] std::optional<double> processCpuMilliseconds() noexcept {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) {
    return std::nullopt;
  }
  const auto timevalMilliseconds = [](const timeval& value) noexcept {
    return static_cast<double>(value.tv_sec) * 1000.0 +
           static_cast<double>(value.tv_usec) / 1000.0;
  };
  return timevalMilliseconds(usage.ru_utime) +
         timevalMilliseconds(usage.ru_stime);
}

[[nodiscard]] MemorySnapshot memorySnapshot() noexcept {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&info), &count) !=
      KERN_SUCCESS) {
    return {};
  }
  return MemorySnapshot{static_cast<std::uint64_t>(info.resident_size),
                        static_cast<std::uint64_t>(info.phys_footprint)};
}

[[nodiscard]] std::optional<std::uint64_t> peakResidentBytes() noexcept {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0 || usage.ru_maxrss < 0) {
    return std::nullopt;
  }
  // Darwin reports ru_maxrss in bytes.
  return static_cast<std::uint64_t>(usage.ru_maxrss);
}

[[nodiscard]] MediaTime fractionOf(MediaTime duration,
                                   std::int64_t numerator,
                                   std::int32_t denominator) {
  require(duration.valid() && duration.value > 0 && numerator > 0 &&
              denominator > 0,
          "fixture duration cannot form an exact target");
  require(duration.value <=
              std::numeric_limits<std::int64_t>::max() / numerator,
          "fixture target numerator exceeds MediaTime");
  require(duration.timescale <=
              std::numeric_limits<std::int32_t>::max() / denominator,
          "fixture target timescale exceeds MediaTime");
  return MediaTime{duration.value * numerator,
                   duration.timescale * denominator};
}

[[nodiscard]] MediaTime addExact(MediaTime lhs, MediaTime rhs) {
  require(lhs.valid() && rhs.valid() && lhs.value >= 0 && rhs.value >= 0,
          "preview target addition received an invalid time");
  const std::int32_t divisor = std::gcd(lhs.timescale, rhs.timescale);
  const std::int64_t commonScale =
      static_cast<std::int64_t>(lhs.timescale / divisor) * rhs.timescale;
  require(commonScale > 0 &&
              commonScale <= std::numeric_limits<std::int32_t>::max(),
          "preview target has no representable common timescale");
  const std::int64_t lhsFactor = commonScale / lhs.timescale;
  const std::int64_t rhsFactor = commonScale / rhs.timescale;
  require(lhs.value <= std::numeric_limits<std::int64_t>::max() / lhsFactor &&
              rhs.value <=
                  std::numeric_limits<std::int64_t>::max() / rhsFactor,
          "preview target addition overflowed MediaTime");
  const std::int64_t lhsValue = lhs.value * lhsFactor;
  const std::int64_t rhsValue = rhs.value * rhsFactor;
  require(lhsValue <= std::numeric_limits<std::int64_t>::max() - rhsValue,
          "preview target sum overflowed MediaTime");
  return MediaTime{lhsValue + rhsValue,
                   static_cast<std::int32_t>(commonScale)};
}

[[nodiscard]] MediaTime forwardRetarget(MediaTime duration,
                                        std::int64_t step) {
  require(step >= 1 && step <= 64,
          "preview retarget step is outside the regression window");
  const auto againstEightSeconds =
      wam::media::compareMediaTime(duration, MediaTime{8, 1});
  require(againstEightSeconds.has_value(),
          "fixture duration cannot be compared exactly");
  if (*againstEightSeconds != wam::media::MediaTimeOrder::Greater) {
    // A duration-scaled window covers exactly duration/16 and is therefore
    // no more than 0.5 seconds for fixtures up to eight seconds.
    return fractionOf(duration, 384 + step, 1024);
  }
  // Longer fixtures use a fixed 1/128-second stride. All 64 targets remain
  // inside a 0.5-second forward-local window from the first target.
  return addExact(fractionOf(duration, 3, 8), MediaTime{step, 128});
}

[[nodiscard]] std::size_t stagedByteLimit(
    const MediaSourceLimits& limits) noexcept {
  if (limits.maximumVideoSampleBytes >
      std::numeric_limits<std::size_t>::max() -
          limits.maximumAudioSampleBytes) {
    return std::numeric_limits<std::size_t>::max();
  }
  return limits.maximumVideoSampleBytes + limits.maximumAudioSampleBytes;
}

void requireBoundedMainSource(const AVFoundationMediaSource& source,
                              const MediaSourceLimits& limits) {
  const auto facts = source.stats();
  require(facts.open, "main source lost its open proof");
  require(facts.stagedVideoHeads <= 1 && facts.stagedAudioHeads <= 1,
          "main source exceeded one staged head per selected track");
  const std::size_t maximumBytes = stagedByteLimit(limits);
  require(facts.stagedPayloadBytes <= maximumBytes &&
              facts.peakStagedPayloadBytes <= maximumBytes,
          "main source exceeded its combined compressed-sample bound");
}

[[nodiscard]] bool sameMetadataFacts(
    const AVFoundationAssetContextFacts& lhs,
    const AVFoundationAssetContextFacts& rhs) noexcept {
  return lhs.assetMetadataLoadBatches == rhs.assetMetadataLoadBatches &&
         lhs.selectedTrackMetadataLoadBatches ==
             rhs.selectedTrackMetadataLoadBatches;
}

[[nodiscard]] std::string jsonString(std::string_view value) {
  std::ostringstream stream;
  stream << '"';
  constexpr char digits[] = "0123456789abcdef";
  for (const unsigned char byte : value) {
    switch (byte) {
      case '"':
        stream << "\\\"";
        break;
      case '\\':
        stream << "\\\\";
        break;
      case '\b':
        stream << "\\b";
        break;
      case '\f':
        stream << "\\f";
        break;
      case '\n':
        stream << "\\n";
        break;
      case '\r':
        stream << "\\r";
        break;
      case '\t':
        stream << "\\t";
        break;
      default:
        if (byte < 0x20U) {
          stream << "\\u00" << digits[byte >> 4U] << digits[byte & 0x0fU];
        } else {
          stream << static_cast<char>(byte);
        }
        break;
    }
  }
  stream << '"';
  return stream.str();
}

void writeOptionalInteger(std::ostream& stream,
                          const std::optional<std::uint64_t>& value) {
  if (value.has_value()) {
    stream << *value;
  } else {
    stream << "null";
  }
}

void writeTimingReport(const std::filesystem::path& fixture,
                       const TimingReport& report) {
  std::cout << std::fixed << std::setprecision(3)
            << "{\"fixture\":" << jsonString(fixture.string())
            << ",\"coldOpenMilliseconds\":"
            << report.coldOpenMilliseconds
            << ",\"reusedSeekMilliseconds\":{\"count\":"
            << report.reusedSeekCount << ",\"first\":"
            << report.firstSeekMilliseconds << ",\"p50\":"
            << report.seekP50Milliseconds << ",\"p95\":"
            << report.seekP95Milliseconds << ",\"max\":"
            << report.seekMaximumMilliseconds << '}'
            << ",\"previewStartMilliseconds\":"
            << report.previewStartMilliseconds
            << ",\"forwardRetarget64Milliseconds\":{\"total\":"
            << report.forwardRetargetTotalMilliseconds
            << ",\"p50\":" << report.retargetP50Milliseconds
            << ",\"p95\":" << report.retargetP95Milliseconds
            << ",\"max\":" << report.retargetMaximumMilliseconds << '}'
            << ",\"processCpuMilliseconds\":"
            << report.processCpuMilliseconds
            << ",\"residentAfterOpenBytes\":";
  writeOptionalInteger(std::cout, report.residentAfterOpenBytes);
  std::cout << ",\"footprintAfterOpenBytes\":";
  writeOptionalInteger(std::cout, report.footprintAfterOpenBytes);
  std::cout << ",\"residentAfterCloseBytes\":";
  writeOptionalInteger(std::cout, report.residentAfterCloseBytes);
  std::cout << ",\"footprintAfterCloseBytes\":";
  writeOptionalInteger(std::cout, report.footprintAfterCloseBytes);
  std::cout << ",\"peakResidentBytes\":";
  writeOptionalInteger(std::cout, report.peakResidentBytes);
  std::cout << "}\n";
}

[[nodiscard]] TimingReport runFixture(
    const std::filesystem::path& fixture) {
  TimingReport report;
  const double cpuBefore = processCpuMilliseconds().value_or(0.0);

  MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  options.selection.requireAudio = true;
  options.limits = wam::media::clampMediaSourceLimits(options.limits);

  AVFoundationMediaSource mainSource;
  require(mainSource.armOperation(1), "cold generation did not arm");
  const auto coldStarted = Clock::now();
  auto opened = mainSource.openLocalFile(fixture, options, 1);
  report.coldOpenMilliseconds = milliseconds(Clock::now() - coldStarted);
  require(opened.status == MediaSourceOpenStatus::Ready,
          std::string("real fixture failed native cold admission: ") +
              opened.error);
  require(opened.descriptor != nullptr,
          "cold admission returned no immutable descriptor");
  require(opened.descriptor->selectedVideo.has_value() &&
              opened.descriptor->selectedAudio.has_value(),
          "fixture did not retain its selected video and audio tracks");
  requireBoundedMainSource(mainSource, options.limits);

  std::shared_ptr<const AVFoundationAssetContext> context =
      mainSource.assetContext();
  require(context != nullptr, "cold admission returned no asset context");
  require(context->descriptor().get() == opened.descriptor.get(),
          "cold descriptor and context descriptor identities differ");
  require(context->matchesMainRequest(fixture, options, opened.descriptor),
          "cold context does not match its exact main-source request");
  const AVFoundationAssetContextFacts coldFacts = context->facts();
  require(coldFacts.assetMetadataLoadBatches == 1 &&
              coldFacts.selectedTrackMetadataLoadBatches == 1,
          "cold admission did not issue exactly one asset and one selected-track metadata batch");
  require(coldFacts.readerCreationAttempts == 1 &&
              coldFacts.readersStarted == 1,
          "cold admission did not create and start exactly one reader");

  const MemorySnapshot afterOpen = memorySnapshot();
  report.residentAfterOpenBytes = afterOpen.residentBytes;
  report.footprintAfterOpenBytes = afterOpen.footprintBytes;

  constexpr std::size_t reusedSeekCount = 16;
  std::vector<double> seekTimings;
  seekTimings.reserve(reusedSeekCount);
  const MediaTime firstSeekTarget =
      fractionOf(opened.descriptor->duration, 1, 4);
  const MediaTime secondSeekTarget =
      fractionOf(opened.descriptor->duration, 1, 2);
  for (std::size_t index = 0; index < reusedSeekCount; ++index) {
    const auto generation = static_cast<wam::media::MediaGeneration>(index + 2);
    const MediaTime target =
        index % 2 == 0 ? firstSeekTarget : secondSeekTarget;
    require(mainSource.armOperation(generation),
            "a reused seek generation did not arm");
    const auto seekStarted = Clock::now();
    const auto sought =
        mainSource.seek({generation, target, MediaSeekMode::Accurate});
    seekTimings.push_back(milliseconds(Clock::now() - seekStarted));
    require(sought.accepted,
            std::string("context-reusing seek failed at iteration ") +
                std::to_string(index) + ": " + sought.error);
    require(mainSource.assetContext().get() == context.get() &&
                mainSource.assetContext()->descriptor().get() ==
                    opened.descriptor.get(),
            "a seek replaced the asset context or descriptor identity");
    requireBoundedMainSource(mainSource, options.limits);
    const AVFoundationAssetContextFacts seekFacts = context->facts();
    const std::uint64_t expectedReaders =
        static_cast<std::uint64_t>(index + 2);
    require(sameMetadataFacts(coldFacts, seekFacts) &&
                seekFacts.readerCreationAttempts == expectedReaders &&
                seekFacts.readersStarted == expectedReaders &&
                mainSource.stats().seeksAccepted == index + 1,
            "a reused seek changed metadata or reader accounting");
  }
  report.reusedSeekCount = seekTimings.size();
  report.firstSeekMilliseconds = seekTimings.front();
  report.seekP50Milliseconds = percentile(seekTimings, 0.50);
  report.seekP95Milliseconds = percentile(seekTimings, 0.95);
  report.seekMaximumMilliseconds = percentile(seekTimings, 1.0);

  const AVFoundationAssetContextFacts afterSeeks = context->facts();
  require(sameMetadataFacts(coldFacts, afterSeeks),
          "reused main seeks reissued immutable metadata loads");
  require(afterSeeks.readerCreationAttempts == reusedSeekCount + 1 &&
              afterSeeks.readersStarted == reusedSeekCount + 1,
          "reused seeks did not add exactly one reader apiece");
  require(mainSource.stats().seeksAccepted == reusedSeekCount,
          "main source did not publish every accepted seek");

  NativePreviewBinding previewBinding;
  previewBinding.localPath = fixture;
  previewBinding.descriptor = opened.descriptor;
  previewBinding.limits = options.limits;
  previewBinding.assetContext = context;
  std::unique_ptr<AVFoundationPreviewSource> preview =
      AVFoundationPreviewSource::create(std::move(previewBinding));
  require(preview != nullptr,
          "shared-context preview source could not be created");

  constexpr std::uint64_t previewEpoch = 1;
  const MediaTime previewTarget =
      fractionOf(opened.descriptor->duration, 3, 8);
  const auto previewStarted = Clock::now();
  const auto begun = preview->begin({previewEpoch, previewTarget});
  report.previewStartMilliseconds =
      milliseconds(Clock::now() - previewStarted);
  require(begun.status == NativePreviewStatus::Ready,
          std::string("shared-context preview reader failed: ") +
              begun.error);

  const auto begunFacts = preview->facts();
  require(begunFacts.backend.assetLoadAttempts == 0 &&
              begunFacts.backend.assetLoadsCompleted == 0 &&
              begunFacts.backend.assetLoadNanoseconds == 0 &&
              begunFacts.backend.readersCreated == 1 &&
              begunFacts.backend.readersStarted == 1,
          "preview did not borrow metadata and start exactly one reader");
  const AVFoundationAssetContextFacts afterPreviewStart = context->facts();
  require(sameMetadataFacts(afterSeeks, afterPreviewStart),
          "shared preview start reissued immutable metadata loads");
  require(afterPreviewStart.readerCreationAttempts == reusedSeekCount + 2 &&
              afterPreviewStart.readersStarted == reusedSeekCount + 2,
          "shared preview start did not add exactly one reader");

  std::optional<MediaSample> previewSample;
  for (std::size_t reads = 0; reads < 512 && !previewSample.has_value();
       ++reads) {
    NativePreviewReadResult result = preview->readNext(previewEpoch);
    if (std::holds_alternative<MediaSample>(result)) {
      MediaSample sample = std::move(std::get<MediaSample>(result));
      if (!sample.decodeOnly) {
        previewSample.emplace(std::move(sample));
      }
    } else if (!std::holds_alternative<MediaDiscontinuity>(result)) {
      if (std::holds_alternative<NativePreviewFailure>(result)) {
        fail(std::string("preview sample read failed: ") +
             std::get<NativePreviewFailure>(result).error);
      }
      if (std::holds_alternative<NativePreviewEndOfStream>(result)) {
        fail("preview reached end of stream before yielding a sample");
      }
      fail("preview sample read was cancelled or rejected");
    }
  }
  require(previewSample.has_value(),
          "preview did not yield a sample within its bounded read budget");
  require(previewSample->kind == MediaSampleKind::EncodedVideo &&
              previewSample->payload.byteSize() > 0 &&
              previewSample->payload.byteSize() <=
                  options.limits.maximumVideoSampleBytes,
          "preview sample exceeded the compressed-video payload bound");
  require(preview->facts().stagedSampleBuffers == 0 &&
              preview->facts().peakStagedSampleBuffers <= 1,
          "preview retained more than one copied sample buffer");

  // This source-level gate has no decoded-frontier API. Keep its entire
  // monotonic target sequence inside a 0.5-second window from the initial
  // target, strictly within the lane's one-second forward-local policy.
  std::vector<double> retargetTimings;
  retargetTimings.reserve(64);
  const auto retargetStarted = Clock::now();
  for (std::int64_t step = 1; step <= 64; ++step) {
    const MediaTime target = forwardRetarget(opened.descriptor->duration,
                                             step);
    const auto oneRetargetStarted = Clock::now();
    require(preview->advanceTarget(previewEpoch, target),
            "a valid forward preview retarget was rejected");
    bool presented = false;
    for (std::size_t reads = 0; reads < 64 && !presented; ++reads) {
      NativePreviewReadResult result = preview->readNext(previewEpoch);
      if (std::holds_alternative<MediaSample>(result)) {
        MediaSample sample = std::move(std::get<MediaSample>(result));
        require(sample.kind == MediaSampleKind::EncodedVideo &&
                    sample.payload.byteSize() > 0 &&
                    sample.payload.byteSize() <=
                        options.limits.maximumVideoSampleBytes,
                "retargeted preview sample exceeded its payload bound");
        presented = !sample.decodeOnly;
      } else if (!std::holds_alternative<MediaDiscontinuity>(result)) {
        if (std::holds_alternative<NativePreviewFailure>(result)) {
          fail(std::string("retargeted preview read failed: ") +
               std::get<NativePreviewFailure>(result).error);
        }
        fail("retargeted preview did not reach a presentable sample");
      }
    }
    require(presented,
            "retargeted preview exhausted its bounded sample-read budget");
    retargetTimings.push_back(
        milliseconds(Clock::now() - oneRetargetStarted));
  }
  report.forwardRetargetTotalMilliseconds =
      milliseconds(Clock::now() - retargetStarted);
  report.retargetP50Milliseconds = percentile(retargetTimings, 0.50);
  report.retargetP95Milliseconds = percentile(retargetTimings, 0.95);
  report.retargetMaximumMilliseconds = percentile(retargetTimings, 1.0);

  const auto retargetFacts = preview->facts();
  require(retargetFacts.forwardRetargets == 64 &&
              retargetFacts.backend.readersCreated == 1 &&
              retargetFacts.backend.readersStarted == 1 &&
              retargetFacts.samplesRead >= 65 &&
              retargetFacts.stagedSampleBuffers == 0 &&
              retargetFacts.peakStagedSampleBuffers <= 1,
          "64 forward retargets did not reuse one preview reader");
  const AVFoundationAssetContextFacts afterRetargets = context->facts();
  require(sameMetadataFacts(afterSeeks, afterRetargets) &&
              afterRetargets.readerCreationAttempts == reusedSeekCount + 2 &&
              afterRetargets.readersStarted == reusedSeekCount + 2,
          "forward retargets reloaded metadata or replaced the preview reader");

  std::weak_ptr<const AVFoundationAssetContext> weakContext = context;
  previewSample.reset();
  mainSource.close();
  const auto closedMainFacts = mainSource.stats();
  require(!closedMainFacts.open &&
              closedMainFacts.operationGeneration == 0 &&
              closedMainFacts.stagedVideoHeads == 0 &&
              closedMainFacts.stagedAudioHeads == 0 &&
              closedMainFacts.stagedPayloadBytes == 0 &&
              mainSource.assetContext() == nullptr,
          "main close retained staged work or its asset-context lease");
  require(!weakContext.expired(),
          "preview did not retain the context after main close");

  // Ready outcomes now own the same exact prepared context as the source and
  // preview binding. Retire this local observation before proving the two
  // operational owners release their leases below.
  opened.preparedContext.reset();
  context.reset();
  require(!weakContext.expired(),
          "preview lost its sole context lease before retirement");
  preview->close();
  const auto closedPreviewFacts = preview->facts();
  require(!closedPreviewFacts.open &&
              closedPreviewFacts.activeEpoch == 0 &&
              closedPreviewFacts.operationEpoch == 0 &&
              closedPreviewFacts.stagedSampleBuffers == 0,
          "preview close retained active reader or staged-sample work");
  require(!weakContext.expired(),
          "a live preview owner unexpectedly lost its immutable binding");
  preview.reset();
  require(weakContext.expired(),
          "asset context outlived both main and preview owners");

  const MemorySnapshot afterClose = memorySnapshot();
  report.residentAfterCloseBytes = afterClose.residentBytes;
  report.footprintAfterCloseBytes = afterClose.footprintBytes;
  report.peakResidentBytes = peakResidentBytes();
  const double cpuAfter = processCpuMilliseconds().value_or(cpuBefore);
  report.processCpuMilliseconds =
      cpuAfter >= cpuBefore ? cpuAfter - cpuBefore : 0.0;
  return report;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    bool reportTiming = false;
    std::optional<std::filesystem::path> suppliedFixture;
    for (int index = 1; index < argc; ++index) {
      const std::string_view argument{argv[index]};
      if (argument == "--report-timing") {
        reportTiming = true;
      } else if (!suppliedFixture.has_value()) {
        suppliedFixture = std::filesystem::path{argument};
      } else {
        std::cerr << "usage: " << argv[0]
                  << " <native-admissible-fixture> [--report-timing]\n";
        return 2;
      }
    }
    if (!suppliedFixture.has_value() || suppliedFixture->empty()) {
      std::cerr << "headless performance regression requires an existing "
                   "native-admissible fixture\n";
      return 2;
    }

    try {
      const std::filesystem::path fixture =
          std::filesystem::absolute(*suppliedFixture).lexically_normal();
      if (!std::filesystem::is_regular_file(fixture)) {
        std::cerr << "headless performance regression requires an existing "
                     "native-admissible fixture\n";
        return 2;
      }
      const TimingReport report = runFixture(fixture);
      if (reportTiming) {
        writeTimingReport(fixture, report);
      } else {
        std::cout << "Native headless performance invariants passed\n";
      }
      return 0;
    } catch (const std::exception& exception) {
      std::cerr << "Native headless performance invariant failed: "
                << exception.what() << '\n';
      return 1;
    } catch (...) {
      std::cerr << "Native headless performance invariant failed: unknown "
                   "exception\n";
      return 1;
    }
  }
}
