// Matroska media source contract.
//
// The neutral MediaSource surface -- openLocalFile, seek, readNext,
// requestCancel, close, stats -- driven directly against the Matroska backend
// over real container bytes. Five rules are proved here that no other suite
// reaches, and every one of them is a place where this backend deliberately
// differs from its MPEG-TS twin:
//
//   1. The synthetic decode-order lead. Matroska carries no decode timestamp
//      and its cursors emit in storage (decode) order, so the A/V merge keys
//      video on a time that leads its presentation time by a bounded reorder
//      window. The interleave the source produces is compared against an
//      independent replay of the same two lanes, and against the interleave a
//      zero lead would have produced, so the constant cannot become inert.
//   2. Exact rationals. Container ticks reach CoreMedia and the neutral
//      contract without a seconds round trip, and no sample carries a
//      fabricated decode stamp.
//   3. Negative audio origin. An encoder-primed audio track legitimately
//      presents before media time zero; the window's decodeStart names that
//      lead-in exactly and the first staged access unit must equal it.
//   4. First-Cue clamping. A plan that lands after its target is admitted in
//      exactly one case, the target at or before the first Cue.
//   5. Audio-only admission. A container with no video track at all is the
//      music-file route and stays admitted; requiring video refuses it.
//
// Fixtures are muxed at test time so the contract is proved against bytes a
// real encoder produced rather than against a hand-built specimen. Without
// ffmpeg the binary skips.

#include "platform/macos/matroska_media_source.hpp"

#include "media/native_media_source.hpp"
#include "platform/macos/matroska_asset_context.hpp"

#import <CoreMedia/CoreMedia.h>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

#include "support/expect.hpp"

extern char** environ;

namespace {

using wam::macos::MatroskaMediaSource;
using wam::media::MediaEndOfStream;
using wam::media::MediaGeneration;
using wam::media::MediaSample;
using wam::media::MediaSampleKind;
using wam::media::MediaSeekMode;
using wam::media::MediaSourceCancelled;
using wam::media::MediaSourceExhausted;
using wam::media::MediaSourceInitialPosition;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaSourceOpenOutcome;
using wam::media::MediaSourceOpenStatus;
using wam::media::MediaSourceReadResult;
using wam::media::MediaSourceSeekRequest;
using wam::media::MediaSourceStats;
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

// Exact: the value lies on a 1/grid tick lattice with no remainder.
[[nodiscard]] bool onExactGrid(MediaTime time, std::int64_t grid) noexcept {
  if (!time.valid() || grid <= 0) {
    return false;
  }
  const __int128 scaled = static_cast<__int128>(time.value) * grid;
  return scaled % static_cast<__int128>(time.timescale) == 0;
}

// Ordinal of an exact grid time. Only meaningful once onExactGrid holds.
[[nodiscard]] std::int64_t gridOrdinal(MediaTime time,
                                       std::int64_t grid) noexcept {
  return static_cast<std::int64_t>(static_cast<__int128>(time.value) * grid /
                                   static_cast<__int128>(time.timescale));
}

// start + duration <= target, in exact rationals and 128-bit intermediates.
[[nodiscard]] bool intervalClosesAtOrBefore(MediaTime start, MediaTime duration,
                                            MediaTime target) noexcept {
  if (!start.valid() || !duration.valid() || !target.valid()) {
    return false;
  }
  const __int128 end =
      static_cast<__int128>(start.value) * duration.timescale +
      static_cast<__int128>(duration.value) * start.timescale;
  return end * static_cast<__int128>(target.timescale) <=
         static_cast<__int128>(target.value) *
             static_cast<__int128>(start.timescale) * duration.timescale;
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

constexpr std::int64_t kAudioSampleRate{48'000};
// Cue spacing of the muxed fixtures, in frames at 30 fps.
constexpr const char* kKeyFrameInterval = "15";

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

struct Fixtures {
  std::filesystem::path directory;
  std::filesystem::path audioVideo;
  // Video shifted behind audio, so the first Cue is not at the timeline origin.
  std::filesystem::path offsetVideo;
  std::filesystem::path audioOnly;
  bool valid{false};

  ~Fixtures() {
    std::error_code ignored;
    if (!directory.empty()) {
      std::filesystem::remove_all(directory, ignored);
    }
  }
};

void buildFixtures(const std::string& ffmpeg, Fixtures& fixtures) {
  std::error_code ignored;
  fixtures.directory =
      std::filesystem::temp_directory_path() /
      ("wam-matroska-media-source-" + std::to_string(::getpid()));
  std::filesystem::create_directories(fixtures.directory, ignored);
  fixtures.audioVideo = fixtures.directory / "av.mkv";
  fixtures.offsetVideo = fixtures.directory / "offset.mkv";
  fixtures.audioOnly = fixtures.directory / "audio.mka";

  const std::vector<std::string> common{
      "-hide_banner", "-loglevel", "error", "-nostdin", "-y"};
  std::vector<std::string> audioVideo = common;
  for (const char* argument :
       {"-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=3", "-f",
        "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
        "-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-pix_fmt",
        "yuv420p", "-g", kKeyFrameInterval, "-c:a", "aac"}) {
    audioVideo.emplace_back(argument);
  }
  std::vector<std::string> offset = common;
  for (const char* argument :
       {"-itsoffset", "0.1", "-f", "lavfi", "-i",
        "testsrc2=size=320x180:rate=30:duration=3", "-f", "lavfi", "-i",
        "sine=frequency=440:sample_rate=48000:duration=3", "-c:v", "libx264",
        "-preset", "veryfast", "-bf", "2", "-pix_fmt", "yuv420p", "-g",
        kKeyFrameInterval, "-c:a", "aac"}) {
    offset.emplace_back(argument);
  }
  std::vector<std::string> audio = common;
  for (const char* argument :
       {"-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3",
        "-c:a", "aac"}) {
    audio.emplace_back(argument);
  }
  audioVideo.push_back(fixtures.audioVideo.string());
  offset.push_back(fixtures.offsetVideo.string());
  audio.push_back(fixtures.audioOnly.string());

  fixtures.valid = runFfmpeg(ffmpeg, audioVideo) && runFfmpeg(ffmpeg, offset) &&
                   runFfmpeg(ffmpeg, audio);
}

// ---------------------------------------------------------------------------
// Driving helpers
// ---------------------------------------------------------------------------

struct Drained {
  struct Unit {
    bool video{false};
    MediaTime presentation{};
    MediaTime duration{};
    bool keyFrame{false};
    bool decodeOnly{false};
    bool decodeStamped{false};
    std::uint32_t sampleCount{0};
    bool payloadPresent{false};
  };
  std::vector<Unit> units;
  std::vector<wam::media::MediaTrackId> endOfStream;
  bool exhausted{false};
  bool cancelled{false};
  std::string failure;
};

// Reads to a terminal answer. The bound is a whole timeline of a three second
// fixture, so exceeding it is itself a failure rather than a truncation.
Drained drain(MatroskaMediaSource& source, MediaGeneration generation) {
  Drained result;
  for (int step = 0; step < 4096; ++step) {
    MediaSourceReadResult read = source.readNext(generation);
    if (const auto* sample = std::get_if<MediaSample>(&read)) {
      Drained::Unit unit;
      unit.video = sample->kind == MediaSampleKind::EncodedVideo;
      unit.presentation = sample->presentationTime;
      unit.duration = sample->duration;
      unit.keyFrame = sample->keyFrame;
      unit.decodeOnly = sample->decodeOnly;
      unit.decodeStamped = sample->decodeTime.valid();
      unit.sampleCount = sample->sampleCount;
      unit.payloadPresent = static_cast<bool>(sample->payload);
      result.units.push_back(unit);
      continue;
    }
    if (const auto* end = std::get_if<MediaEndOfStream>(&read)) {
      result.endOfStream.push_back(end->track);
      continue;
    }
    if (std::holds_alternative<MediaSourceExhausted>(read)) {
      result.exhausted = true;
      return result;
    }
    if (std::holds_alternative<MediaSourceCancelled>(read)) {
      result.cancelled = true;
      return result;
    }
    if (const auto* failed =
            std::get_if<wam::media::MediaSourceFailure>(&read)) {
      result.failure = failed->error;
      return result;
    }
    result.failure = "unexpected read variant";
    return result;
  }
  result.failure = "read did not terminate";
  return result;
}

MediaSourceOpenOptions videoOptions() {
  MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  return options;
}

[[nodiscard]] MediaSourceOpenOutcome openAt(
    MatroskaMediaSource& source, const std::filesystem::path& path,
    MediaGeneration generation, std::optional<MediaTime> target,
    MediaSourceOpenOptions options) {
  if (target) {
    options.initialPosition =
        MediaSourceInitialPosition{*target, MediaSeekMode::Accurate};
  }
  if (!source.armOperation(generation)) {
    MediaSourceOpenOutcome refused;
    refused.error = "test could not arm the open generation";
    return refused;
  }
  return source.openLocalFile(path, options, generation);
}

// ---------------------------------------------------------------------------
// The merge key. Restated here rather than reached through a seam: this is the
// rule under test, and a copy that agrees with the backend by construction
// would prove nothing.
// ---------------------------------------------------------------------------

[[nodiscard]] MediaTime videoMergeOrderKey(MediaTime presentation,
                                           std::int64_t leadNanoseconds) {
  if (!presentation.valid()) {
    return presentation;
  }
  const __int128 ticks = (static_cast<__int128>(leadNanoseconds) *
                              static_cast<__int128>(presentation.timescale) +
                          999'999'999) /
                         1'000'000'000;
  return MediaTime{presentation.value - static_cast<std::int64_t>(ticks),
                   presentation.timescale};
}

// Replays the two lanes the source emitted, in the order it emitted them, and
// re-merges them under a stated lead. Both lanes keep their emission order, so
// this is the same greedy choice the source makes over the same frontier.
[[nodiscard]] std::vector<bool> replayMerge(const Drained& drained,
                                            std::int64_t leadNanoseconds) {
  std::vector<MediaTime> video;
  std::vector<MediaTime> audio;
  for (const Drained::Unit& unit : drained.units) {
    (unit.video ? video : audio).push_back(unit.presentation);
  }
  std::vector<bool> order;
  order.reserve(drained.units.size());
  std::size_t videoIndex = 0;
  std::size_t audioIndex = 0;
  while (videoIndex < video.size() || audioIndex < audio.size()) {
    if (audioIndex == audio.size()) {
      order.push_back(true);
      ++videoIndex;
      continue;
    }
    if (videoIndex == video.size()) {
      order.push_back(false);
      ++audioIndex;
      continue;
    }
    const auto comparison = wam::media::compareMediaTime(
        videoMergeOrderKey(video[videoIndex], leadNanoseconds),
        audio[audioIndex]);
    // Video wins ties: no decode timestamp exists to break them.
    const bool chooseVideo =
        comparison.has_value() && *comparison != MediaTimeOrder::Greater;
    order.push_back(chooseVideo);
    ++(chooseVideo ? videoIndex : audioIndex);
  }
  return order;
}

[[nodiscard]] std::vector<bool> observedOrder(const Drained& drained) {
  std::vector<bool> order;
  order.reserve(drained.units.size());
  for (const Drained::Unit& unit : drained.units) {
    order.push_back(unit.video);
  }
  return order;
}

// ---------------------------------------------------------------------------
// Contracts
// ---------------------------------------------------------------------------

void testColdOpenAdmitsTheContainer(const Fixtures& fixtures) {
  MatroskaMediaSource source;
  const MediaSourceOpenOutcome opened =
      openAt(source, fixtures.audioVideo, 1, std::nullopt, videoOptions());
  expect(opened.status == MediaSourceOpenStatus::Ready && opened.error.empty(),
         "a muxed Matroska file is admitted by a cold open");
  if (opened.status != MediaSourceOpenStatus::Ready) {
    std::cerr << "  open error: " << opened.error << '\n';
    return;
  }
  expect(opened.generation == 1 && opened.descriptor != nullptr,
         "the outcome restates its own generation and publishes a descriptor");
  if (opened.descriptor == nullptr) {
    return;
  }
  expect(opened.descriptor->selectedVideo.has_value() &&
             opened.descriptor->selectedAudio.has_value() &&
             opened.descriptor->tracks.size() == 2,
         "both muxed tracks are selected");
  expect(timeAtMost(MediaTime{29, 10}, opened.descriptor->duration) &&
             timeAtMost(opened.descriptor->duration, MediaTime{32, 10}),
         "the published duration is the muxed timeline");
  expect(source.assetContext() != nullptr &&
             opened.preparedContext.get() == source.assetContext().get(),
         "the outcome and the source publish one prepared context instance");
  expect(source.assetContext()->backendKind() ==
             wam::media::MediaSourceBackendKind::Matroska,
         "the prepared context reports the Matroska backend kind");

  const MediaSourceStats stats = source.stats();
  expect(stats.open && stats.operationGeneration == 1 && stats.generation == 1 &&
             !stats.cancelled && stats.samplesEmitted == 0 &&
             stats.seeksAccepted == 0,
         "an admitted generation publishes its own open stats");
  expect(stats.stagedVideoHeads == 1 && stats.stagedAudioHeads == 1 &&
             stats.stagedGeneration == 1 && stats.stagedPayloadBytes > 0,
         "admission retains exactly one staged head per selected output");
}

void testEntryRefusalsAndPublication(const Fixtures& fixtures) {
  MatroskaMediaSource source;
  MediaSourceOpenOptions options = videoOptions();
  expect(source.openLocalFile(fixtures.audioVideo, options, 1).status ==
             MediaSourceOpenStatus::Failed,
         "an unarmed open is refused");
  expect(!source.armOperation(0), "generation zero cannot be armed");
  expect(source.armOperation(5), "a fresh generation arms");
  expect(!source.armOperation(6),
         "a second arm before the operation is consumed is refused");
  expect(source.openLocalFile("", options, 5).status ==
             MediaSourceOpenStatus::Failed,
         "an empty path is refused");

  expect(openAt(source, fixtures.audioVideo, 6, std::nullopt, options).status ==
             MediaSourceOpenStatus::Ready,
         "the source opens after a refused entry");
  expect(openAt(source, fixtures.audioVideo, 7, std::nullopt, options).status ==
             MediaSourceOpenStatus::Failed,
         "a second open on an already open source is refused");
  const MediaSourceStats afterRefusal = source.stats();
  expect(afterRefusal.open && afterRefusal.operationGeneration == 6,
         "a refused operation restores the live publication");

  expect(!source.armOperation(4),
         "a generation at or below the high-water mark cannot be armed");
  expect(std::holds_alternative<MediaSourceCancelled>(source.readNext(5)),
         "a read for a generation that is not live is refused");

  MediaSourceSeekRequest unarmed{8, MediaTime{1, 1}, MediaSeekMode::Accurate};
  expect(!source.seek(unarmed).accepted, "an unarmed seek is refused");
  expect(source.armOperation(8), "a seek generation arms");
  MediaSourceSeekRequest beyond{8, MediaTime{600, 1}, MediaSeekMode::Accurate};
  expect(!source.seek(beyond).accepted,
         "a seek beyond the exact timeline is refused");
  expect(source.stats().open && source.stats().operationGeneration == 6,
         "a refused seek leaves the live generation published");

  source.close();
  const MediaSourceStats closed = source.stats();
  expect(!closed.open && closed.operationGeneration == 0 &&
             closed.generation == 8 && source.assetContext() == nullptr,
         "close retires the generation while the high-water mark survives");
  expect(std::holds_alternative<MediaSourceCancelled>(source.readNext(6)),
         "a closed source refuses every read");
}

// The whole reason this backend has a merge lead at all.
void testMergeStatesTheDecodeOrderLead(const Fixtures& fixtures) {
  MatroskaMediaSource source;
  const MediaSourceOpenOutcome opened =
      openAt(source, fixtures.audioVideo, 1, std::nullopt, videoOptions());
  if (opened.status != MediaSourceOpenStatus::Ready) {
    expect(false, "merge fixture opens");
    return;
  }
  const Drained drained = drain(source, 1);
  expect(drained.failure.empty() && drained.exhausted &&
             drained.endOfStream.size() == 2,
         "a whole generation drains to one end of stream per selected output");
  if (!drained.failure.empty()) {
    std::cerr << "  drain error: " << drained.failure << '\n';
    return;
  }
  expect(drained.units.size() > 100,
         "the fixture carries enough units to interleave");

  // The lead exists because emission order is decode order. Without a stream
  // whose two orders differ, the rule below would prove nothing.
  bool reordered = false;
  std::optional<MediaTime> previousVideo;
  for (const Drained::Unit& unit : drained.units) {
    if (!unit.video) {
      continue;
    }
    if (previousVideo && !timeAtMost(*previousVideo, unit.presentation)) {
      reordered = true;
    }
    previousVideo = unit.presentation;
  }
  expect(reordered,
         "the cursor emits video in storage order, which is not presentation "
         "order for a reordered stream");

  const std::vector<bool> observed = observedOrder(drained);
  expect(observed == replayMerge(drained, 250'000'000),
         "the emitted interleave is the two lanes merged on a video key that "
         "leads its presentation time by the bounded reorder window");
  expect(observed != replayMerge(drained, 0),
         "the lead changes the interleave, so the merge key is not the raw "
         "presentation time");

  const MediaSourceStats stats = source.stats();
  expect(stats.samplesEmitted == drained.units.size() &&
             stats.stagedVideoHeads == 0 && stats.stagedAudioHeads == 0 &&
             stats.stagedGeneration == 0 && stats.peakStagedPayloadBytes > 0,
         "a drained generation stages nothing and counts what it emitted");
}

void testSamplesRestateExactContainerTiming(const Fixtures& fixtures) {
  MatroskaMediaSource source;
  const MediaSourceOpenOutcome opened =
      openAt(source, fixtures.audioVideo, 1, std::nullopt, videoOptions());
  if (opened.status != MediaSourceOpenStatus::Ready) {
    expect(false, "timing fixture opens");
    return;
  }
  const Drained drained = drain(source, 1);
  if (!drained.failure.empty()) {
    expect(false, "timing fixture drains");
    return;
  }

  bool exact = true;
  bool stamped = false;
  bool unlaced = true;
  bool payloads = true;
  std::optional<std::int64_t> nextAudioFrame;
  std::optional<MediaTime> firstAudio;
  for (const Drained::Unit& unit : drained.units) {
    stamped = stamped || unit.decodeStamped;
    payloads = payloads && unit.payloadPresent;
    if (unit.video) {
      // The container states video time in whole timestamp-scale ticks, and a
      // one millisecond scale is what the muxer wrote.
      exact = exact && onExactGrid(unit.presentation, 1'000) &&
              unit.sampleCount == 1;
      continue;
    }
    // Audio time is stated on the codec's own frame grid, never rounded to it.
    const bool onGrid = onExactGrid(unit.presentation, kAudioSampleRate) &&
                        onExactGrid(unit.duration, kAudioSampleRate);
    exact = exact && onGrid;
    unlaced = unlaced && unit.sampleCount == 1;
    if (!firstAudio) {
      firstAudio = unit.presentation;
    }
    if (!onGrid) {
      continue;
    }
    const std::int64_t frame = gridOrdinal(unit.presentation, kAudioSampleRate);
    if (nextAudioFrame) {
      exact = exact && frame == *nextAudioFrame;
    }
    nextAudioFrame = frame + gridOrdinal(unit.duration, kAudioSampleRate);
  }
  expect(exact,
         "container ticks reach the neutral contract as exact rationals and "
         "audio access units stay contiguous on the codec frame grid");
  expect(!stamped,
         "no sample carries a decode timestamp the container never stated");
  expect(unlaced,
         "an unlaced Block publishes exactly one access unit per sample");
  expect(payloads, "every emitted sample carries its payload lease");

  // The audio track's encoder priming presents before media time zero, and the
  // window states that lead-in exactly.
  expect(firstAudio.has_value() && firstAudio->value < 0 &&
             sameTime(*firstAudio, opened.audioWindow.decodeStart) &&
             opened.audioWindow.startsAtStreamOrigin,
         "the first staged audio unit is the window's own decode start and may "
         "precede the timeline origin");
}

void testCoreMediaBuffersRestateTheSameRationals(const Fixtures& fixtures) {
  MatroskaMediaSource source;
  if (openAt(source, fixtures.audioVideo, 1, std::nullopt, videoOptions())
          .status != MediaSourceOpenStatus::Ready) {
    expect(false, "buffer fixture opens");
    return;
  }
  MediaSourceReadResult read = source.readNext(1);
  const auto* sample = std::get_if<MediaSample>(&read);
  expect(sample != nullptr && sample->payload,
         "the first read publishes a payload-bearing sample");
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
             CMSampleBufferDataIsReady(buffer),
         "the lease carries a ready CoreMedia buffer");
  if (buffer == nullptr) {
    return;
  }
  const CMTime presentation = CMSampleBufferGetPresentationTimeStamp(buffer);
  expect(presentation.value == sample->presentationTime.value &&
             presentation.timescale == sample->presentationTime.timescale,
         "container rationals reach CoreMedia without a seconds round trip");
  expect(!CMTIME_IS_VALID(CMSampleBufferGetDecodeTimeStamp(buffer)),
         "the buffer carries no fabricated decode stamp");
}

void testAccurateSeekBothDirections(const Fixtures& fixtures) {
  MatroskaMediaSource source;
  const MediaSourceOpenOutcome opened =
      openAt(source, fixtures.audioVideo, 1, std::nullopt, videoOptions());
  if (opened.status != MediaSourceOpenStatus::Ready) {
    expect(false, "seek fixture opens");
    return;
  }
  const auto context = source.assetContext();

  expect(source.armOperation(2), "the forward seek generation arms");
  MediaSourceSeekRequest forward{2, MediaTime{1, 1}, MediaSeekMode::Accurate};
  const auto forwardOutcome = source.seek(forward);
  expect(forwardOutcome.accepted && forwardOutcome.generation == 2,
         "a forward seek inside the timeline is accepted");
  expect(forwardOutcome.actualDecodeStart.valid() &&
             forwardOutcome.actualDecodeStart.value > 0 &&
             timeAtMost(forwardOutcome.actualDecodeStart, forward.target),
         "a forward seek lands on a Cue at or before its target, not at the "
         "timeline origin");
  expect(forwardOutcome.preparedContext.get() == context.get() &&
             source.assetContext().get() == context.get(),
         "a seek reuses the exact prepared context the open admitted");
  expect(sameTime(forwardOutcome.audioWindow.presentationStart, forward.target),
         "the audio window's presentation floor is the requested target");
  expect(timeAtMost(forwardOutcome.audioWindow.decodeStart, forward.target) &&
             !forwardOutcome.audioWindow.startsAtStreamOrigin,
         "a generation away from the origin decodes audio ahead of its floor");

  const Drained afterForward = drain(source, 2);
  expect(afterForward.failure.empty() && !afterForward.units.empty() &&
             afterForward.units.front().video &&
             afterForward.units.front().keyFrame &&
             sameTime(afterForward.units.front().presentation,
                      forwardOutcome.actualDecodeStart),
         "the first sample of a seeked generation is the sync access unit the "
         "outcome named");
  bool audioAtWindow = false;
  for (const Drained::Unit& unit : afterForward.units) {
    if (!unit.video) {
      audioAtWindow =
          sameTime(unit.presentation, forwardOutcome.audioWindow.decodeStart);
      break;
    }
  }
  expect(audioAtWindow,
         "the first staged audio unit begins at the planned window decode "
         "start");

  expect(source.armOperation(3), "the backward seek generation arms");
  MediaSourceSeekRequest backward{3, MediaTime{2, 5}, MediaSeekMode::Accurate};
  const auto backwardOutcome = source.seek(backward);
  expect(backwardOutcome.accepted &&
             timeAtMost(backwardOutcome.actualDecodeStart, backward.target),
         "a backward seek is accepted and lands at or before its target");
  const Drained afterBackward = drain(source, 3);
  bool decodeOnlyBoundary = !afterBackward.units.empty();
  bool sawCovering = false;
  for (const Drained::Unit& unit : afterBackward.units) {
    if (!unit.video) {
      continue;
    }
    const bool closesBeforeTarget = intervalClosesAtOrBefore(
        unit.presentation, unit.duration, backward.target);
    if (closesBeforeTarget) {
      decodeOnlyBoundary = decodeOnlyBoundary && unit.decodeOnly;
    } else if (!sawCovering) {
      sawCovering = true;
      decodeOnlyBoundary = decodeOnlyBoundary && !unit.decodeOnly;
    }
  }
  expect(decodeOnlyBoundary && sawCovering,
         "in Accurate mode every video interval closing at or before the "
         "target is decodeOnly and the covering one is not");
  expect(source.stats().seeksAccepted == 2,
         "stats count exactly the accepted seeks");
}

// The one legitimate late plan, and the divergence from the MPEG-TS twin when
// no position is requested at all.
void testFirstCueClamp(const Fixtures& fixtures) {
  MediaTime firstCue{};
  {
    MatroskaMediaSource source;
    const MediaSourceOpenOutcome opened =
        openAt(source, fixtures.offsetVideo, 1, std::nullopt, videoOptions());
    if (opened.status != MediaSourceOpenStatus::Ready) {
      expect(false, "first-Cue fixture opens");
      return;
    }
    MediaSourceReadResult read = source.readNext(1);
    const auto* sample = std::get_if<MediaSample>(&read);
    expect(sample != nullptr && sample->keyFrame &&
               sample->kind == MediaSampleKind::EncodedVideo,
           "the offset fixture begins on a sync access unit after the origin");
    if (sample == nullptr) {
      return;
    }
    firstCue = sample->presentationTime;
    expect(firstCue.valid() && firstCue.value > 0,
           "the offset fixture's first Cue is not at the timeline origin");
    // MpegTsMediaSource clamps this case to the timeline origin; this backend
    // publishes the Cue's own tick.
    expect(sameTime(opened.actualDecodeStart, firstCue),
           "an open with no requested position publishes the first Cue tick");
  }
  {
    MatroskaMediaSource source;
    const MediaSourceOpenOutcome opened = openAt(
        source, fixtures.offsetVideo, 1, MediaTime{1, 20}, videoOptions());
    expect(opened.status == MediaSourceOpenStatus::Ready &&
               sameTime(opened.actualDecodeStart, MediaTime{1, 20}),
           "a target at or before the first Cue publishes the target itself");
    MediaSourceReadResult read = source.readNext(1);
    const auto* sample = std::get_if<MediaSample>(&read);
    expect(sample != nullptr && sample->keyFrame &&
               sameTime(sample->presentationTime, firstCue),
           "the clamped generation still begins decoding at the first Cue");
  }
  {
    MatroskaMediaSource source;
    const MediaSourceOpenOutcome opened = openAt(
        source, fixtures.offsetVideo, 1, MediaTime{5, 2}, videoOptions());
    expect(opened.status == MediaSourceOpenStatus::Ready &&
               timeAtMost(opened.actualDecodeStart, MediaTime{5, 2}),
           "a target beyond the first Cue is served by a plan at or before it");
  }
}

// Matroska admits a container with no video track at all. Its MPEG-TS twin
// refuses the mirror case, which is why this rule cannot be shared.
void testAudioOnlyAdmission(const Fixtures& fixtures) {
  {
    MatroskaMediaSource source;
    const MediaSourceOpenOutcome opened =
        openAt(source, fixtures.audioOnly, 1, std::nullopt, videoOptions());
    expect(opened.status == MediaSourceOpenStatus::Unsupported,
           "an audio-only container is refused when video is required");
  }
  MatroskaMediaSource source;
  MediaSourceOpenOptions options;
  options.selection.requireVideo = false;
  const MediaSourceOpenOutcome opened =
      openAt(source, fixtures.audioOnly, 1, std::nullopt, options);
  expect(opened.status == MediaSourceOpenStatus::Ready &&
             opened.descriptor != nullptr,
         "an audio-only container is admitted when video is not required");
  if (opened.status != MediaSourceOpenStatus::Ready) {
    return;
  }
  expect(!opened.descriptor->selectedVideo.has_value() &&
             opened.descriptor->selectedAudio.has_value(),
         "an audio-only generation selects audio and no video");
  expect(source.stats().stagedVideoHeads == 0 &&
             source.stats().stagedAudioHeads == 1,
         "an audio-only generation stages one head and no video head");
  const Drained drained = drain(source, 1);
  bool audioOnly = !drained.units.empty();
  for (const Drained::Unit& unit : drained.units) {
    audioOnly = audioOnly && !unit.video;
  }
  expect(audioOnly && drained.exhausted && drained.endOfStream.size() == 1 &&
             drained.endOfStream.front() == *opened.descriptor->selectedAudio,
         "an audio-only generation drains audio and ends exactly one output");
}

void testCancellation(const Fixtures& fixtures) {
  {
    MatroskaMediaSource source;
    expect(source.armOperation(3), "the cancelled generation arms");
    source.requestCancel(3);
    const MediaSourceOpenOutcome opened =
        source.openLocalFile(fixtures.audioVideo, videoOptions(), 3);
    expect(opened.status == MediaSourceOpenStatus::Cancelled,
           "a cancel published before entry is answered by the open");
    const MediaSourceStats stats = source.stats();
    expect(!stats.open && stats.operationGeneration == 0 &&
               stats.generation == 3,
           "a cancelled open withdraws its publication");
  }
  MatroskaMediaSource source;
  if (openAt(source, fixtures.audioVideo, 4, std::nullopt, videoOptions())
          .status != MediaSourceOpenStatus::Ready) {
    expect(false, "cancellation fixture opens");
    return;
  }
  source.requestCancel(9);
  expect(source.stats().open && !source.stats().cancelled,
         "a cancel for a foreign generation is inert");
  MediaSourceReadResult live = source.readNext(4);
  expect(std::get_if<MediaSample>(&live) != nullptr,
         "the live generation reads before cancellation");

  // requestCancel is the only cross-thread entry point on this surface.
  std::thread canceller([&source] { source.requestCancel(4); });
  canceller.join();
  const MediaSourceStats cancelled = source.stats();
  expect(cancelled.open && cancelled.cancelled,
         "a cancel for the live generation is published before the next read");
  expect(std::holds_alternative<MediaSourceCancelled>(source.readNext(4)),
         "a cancelled generation answers its next read with Cancelled");
  const MediaSourceStats withdrawn = source.stats();
  expect(!withdrawn.open && withdrawn.operationGeneration == 0 &&
             withdrawn.stagedVideoHeads == 0 &&
             withdrawn.stagedAudioHeads == 0,
         "the cancelled read retires the cursors and stages nothing");
  expect(std::holds_alternative<MediaSourceCancelled>(source.readNext(4)),
         "a retired generation stays cancelled");

  expect(openAt(source, fixtures.audioVideo, 10, std::nullopt, videoOptions())
                 .status == MediaSourceOpenStatus::Ready,
         "a newer generation opens after a cancellation");
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2 || argv[1] == nullptr || *argv[1] == '\0' ||
      !std::filesystem::exists(argv[1])) {
    std::cerr << "matroska media source contracts need a muxer; skipping\n";
    return 77;
  }
  Fixtures fixtures;
  buildFixtures(argv[1], fixtures);
  if (!fixtures.valid) {
    std::cerr << "FAIL: fixtures could not be muxed\n";
    return 1;
  }

  testColdOpenAdmitsTheContainer(fixtures);
  testEntryRefusalsAndPublication(fixtures);
  testMergeStatesTheDecodeOrderLead(fixtures);
  testSamplesRestateExactContainerTiming(fixtures);
  testCoreMediaBuffersRestateTheSameRationals(fixtures);
  testAccurateSeekBothDirections(fixtures);
  testFirstCueClamp(fixtures);
  testAudioOnlyAdmission(fixtures);
  testCancellation(fixtures);

  if (failures == 0) {
    std::cout << "matroska media source contracts passed\n";
  }
  return failures == 0 ? 0 : 1;
}
