// MPEG-TS media source contract.
//
// The neutral MediaSource surface -- openLocalFile, seek, readNext,
// requestCancel, close, stats -- driven directly against the transport stream
// backend over real container bytes. Five rules are proved here that no other
// suite reaches, and every one of them is a place where this backend
// deliberately differs from its Matroska twin:
//
//   1. The merge keys on a real decode timestamp. A PES header carries an
//      explicit DTS, so the A/V frontier is ordered by the times the decoders
//      consume the data and there is no synthetic ordering lead. The emitted
//      interleave is compared against an independent replay of the same two
//      lanes, and against the interleave a Matroska-style lead would have
//      produced, so the absence of that lead is a tested fact.
//   2. The audio timeline is an exact frame ordinal, not the container stamp.
//      A 90 kHz PES timestamp cannot express a 44.1 kHz frame boundary, so the
//      source anchors once and counts frames; the published times are proved
//      to lie off the 90 kHz grid they were read from.
//   3. The anchor is shifted by the decoder lead-in for the codecs whose
//      decoders swallow frames, because a PES header has no CodecDelay field.
//   4. An unroutable audio stream is dropped and video is prepared muted,
//      rather than refusing the file.
//   5. A transport stream with no video elementary stream is refused, which is
//      the mirror of the audio-only route Matroska admits.
//
// There is no checked-in transport stream, so the fixtures are muxed at test
// time. Without a muxer the binary skips.

#include "platform/macos/mpegts_media_source.hpp"

#include "media/matroska_ac3.hpp"
#include "media/mpegts_demuxer.hpp"
#include "media/native_media_source.hpp"
#include "platform/macos/mpegts_asset_context.hpp"

#import <CoreMedia/CoreMedia.h>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdint>
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

using wam::macos::MpegTsMediaSource;
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

[[nodiscard]] bool onExactGrid(MediaTime time, std::int64_t grid) noexcept {
  if (!time.valid() || grid <= 0) {
    return false;
  }
  const __int128 scaled = static_cast<__int128>(time.value) * grid;
  return scaled % static_cast<__int128>(time.timescale) == 0;
}

[[nodiscard]] std::int64_t gridOrdinal(MediaTime time,
                                       std::int64_t grid) noexcept {
  return static_cast<std::int64_t>(static_cast<__int128>(time.value) * grid /
                                   static_cast<__int128>(time.timescale));
}

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

// The container's own audio time base. It divides neither codec frame grid the
// fixtures use, which is the whole reason the source keeps its own ordinal.
constexpr std::int64_t kTransportStreamAudioTimeBase{90'000};
constexpr std::int64_t kFullRateAudio{48'000};
constexpr std::int64_t kOddRateAudio{44'100};

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
  // A codec frame grid the container's 90 kHz base cannot express.
  std::filesystem::path oddRate;
  // A codec whose decoder swallows a fixed lead-in the container never states.
  std::filesystem::path leadIn;
  // An audio elementary stream this backend cannot route.
  std::filesystem::path unroutableAudio;
  std::filesystem::path audioOnly;
  bool valid{false};

  ~Fixtures() {
    std::error_code ignored;
    if (!directory.empty()) {
      std::filesystem::remove_all(directory, ignored);
    }
  }
};

std::vector<std::string> muxCommand(const char* audioCodec,
                                    std::int64_t audioRate,
                                    const std::filesystem::path& output) {
  std::vector<std::string> command{"-hide_banner", "-loglevel", "error",
                                   "-nostdin",     "-y",        "-f",
                                   "lavfi",        "-i",
                                   "testsrc2=size=320x180:rate=30:duration=3",
                                   "-f",           "lavfi",     "-i"};
  command.emplace_back("sine=frequency=440:sample_rate=" +
                       std::to_string(audioRate) + ":duration=3");
  for (const char* argument : {"-c:v", "libx264", "-preset", "veryfast", "-bf",
                               "2", "-pix_fmt", "yuv420p", "-g", "15",
                               "-c:a"}) {
    command.emplace_back(argument);
  }
  command.emplace_back(audioCodec);
  command.emplace_back("-f");
  command.emplace_back("mpegts");
  command.push_back(output.string());
  return command;
}

void buildFixtures(const std::string& ffmpeg, Fixtures& fixtures) {
  std::error_code ignored;
  fixtures.directory =
      std::filesystem::temp_directory_path() /
      ("wam-mpegts-media-source-" + std::to_string(::getpid()));
  std::filesystem::create_directories(fixtures.directory, ignored);
  fixtures.audioVideo = fixtures.directory / "av.ts";
  fixtures.oddRate = fixtures.directory / "odd.ts";
  fixtures.leadIn = fixtures.directory / "leadin.ts";
  fixtures.unroutableAudio = fixtures.directory / "unroutable.ts";
  fixtures.audioOnly = fixtures.directory / "audio.ts";

  std::vector<std::string> audioOnly{
      "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "lavfi",
      "-i", "sine=frequency=440:sample_rate=48000:duration=3", "-c:a", "aac",
      "-f", "mpegts"};
  audioOnly.push_back(fixtures.audioOnly.string());

  fixtures.valid =
      runFfmpeg(ffmpeg, muxCommand("aac", kFullRateAudio, fixtures.audioVideo)) &&
      runFfmpeg(ffmpeg, muxCommand("aac", kOddRateAudio, fixtures.oddRate)) &&
      runFfmpeg(ffmpeg, muxCommand("ac3", kFullRateAudio, fixtures.leadIn)) &&
      runFfmpeg(ffmpeg,
                muxCommand("libopus", kFullRateAudio, fixtures.unroutableAudio)) &&
      runFfmpeg(ffmpeg, audioOnly);
}

// ---------------------------------------------------------------------------
// Driving helpers
// ---------------------------------------------------------------------------

struct Drained {
  struct Unit {
    bool video{false};
    MediaTime presentation{};
    MediaTime decode{};
    MediaTime duration{};
    bool keyFrame{false};
    bool decodeOnly{false};
    std::uint32_t sampleCount{0};
    bool payloadPresent{false};
  };
  std::vector<Unit> units;
  std::vector<wam::media::MediaTrackId> endOfStream;
  bool exhausted{false};
  std::string failure;
};

Drained drain(MpegTsMediaSource& source, MediaGeneration generation) {
  Drained result;
  for (int step = 0; step < 4096; ++step) {
    MediaSourceReadResult read = source.readNext(generation);
    if (const auto* sample = std::get_if<MediaSample>(&read)) {
      Drained::Unit unit;
      unit.video = sample->kind == MediaSampleKind::EncodedVideo;
      unit.presentation = sample->presentationTime;
      unit.decode = sample->decodeTime;
      unit.duration = sample->duration;
      unit.keyFrame = sample->keyFrame;
      unit.decodeOnly = sample->decodeOnly;
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
      result.failure = "generation was cancelled";
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
    MpegTsMediaSource& source, const std::filesystem::path& path,
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
// rule under test.
// ---------------------------------------------------------------------------

[[nodiscard]] MediaTime leadBy(MediaTime time, std::int64_t leadNanoseconds) {
  if (leadNanoseconds == 0 || !time.valid()) {
    return time;
  }
  const __int128 ticks =
      (static_cast<__int128>(leadNanoseconds) *
           static_cast<__int128>(time.timescale) +
       999'999'999) /
      1'000'000'000;
  return MediaTime{time.value - static_cast<std::int64_t>(ticks),
                   time.timescale};
}

// Replays the two lanes the source emitted, in the order it emitted them, and
// re-merges them under a stated video lead. Both lanes keep their emission
// order, so this is the same greedy choice over the same frontier.
[[nodiscard]] std::vector<bool> replayMerge(const Drained& drained,
                                            std::int64_t leadNanoseconds) {
  std::vector<MediaTime> video;
  std::vector<MediaTime> audio;
  for (const Drained::Unit& unit : drained.units) {
    if (unit.video) {
      // dts.valid() ? dts : pts, exactly as the source states it.
      video.push_back(unit.decode.valid() ? unit.decode : unit.presentation);
    } else {
      audio.push_back(unit.presentation);
    }
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
        leadBy(video[videoIndex], leadNanoseconds), audio[audioIndex]);
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

void testColdOpenClampsToTheTimelineOrigin(const Fixtures& fixtures) {
  MpegTsMediaSource source;
  const MediaSourceOpenOutcome opened =
      openAt(source, fixtures.audioVideo, 1, std::nullopt, videoOptions());
  expect(opened.status == MediaSourceOpenStatus::Ready && opened.error.empty(),
         "a muxed transport stream is admitted by a cold open");
  if (opened.status != MediaSourceOpenStatus::Ready) {
    std::cerr << "  open error: " << opened.error << '\n';
    return;
  }
  expect(opened.generation == 1 && opened.descriptor != nullptr &&
             opened.descriptor->selectedVideo.has_value() &&
             opened.descriptor->selectedAudio.has_value(),
         "both elementary streams are selected");
  expect(source.assetContext() != nullptr &&
             opened.preparedContext.get() == source.assetContext().get() &&
             source.assetContext()->backendKind() ==
                 wam::media::MediaSourceBackendKind::MpegTs,
         "the outcome and the source publish one MPEG-TS context instance");

  // The muxer emits audio ahead of video and the exported timeline is rebased
  // on the earlier of the two, so the first video access unit is not at zero.
  MediaSourceReadResult first = source.readNext(1);
  const auto* firstSample = std::get_if<MediaSample>(&first);
  MediaTime videoOrigin{};
  for (int step = 0; step < 8 && firstSample != nullptr; ++step) {
    if (firstSample->kind == MediaSampleKind::EncodedVideo) {
      videoOrigin = firstSample->presentationTime;
      break;
    }
    first = source.readNext(1);
    firstSample = std::get_if<MediaSample>(&first);
  }
  expect(videoOrigin.valid() && videoOrigin.value > 0,
         "the fixture's first video access unit is after the timeline origin");
  expect(sameTime(opened.actualDecodeStart, MediaTime{0, 1}),
         "an open with no requested position publishes the timeline origin "
         "rather than the late video start");

  const MediaSourceStats stats = source.stats();
  expect(stats.open && stats.operationGeneration == 1 && stats.generation == 1 &&
             !stats.cancelled && stats.seeksAccepted == 0,
         "an admitted generation publishes its own open stats");
}

void testEntryRefusalsAndPublication(const Fixtures& fixtures) {
  MpegTsMediaSource source;
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

void testMergeKeysOnRealDecodeTimestamps(const Fixtures& fixtures) {
  MpegTsMediaSource source;
  if (openAt(source, fixtures.audioVideo, 1, std::nullopt, videoOptions())
          .status != MediaSourceOpenStatus::Ready) {
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

  bool videoStamped = !drained.units.empty();
  bool audioUnstamped = true;
  bool selfFramed = false;
  bool payloads = true;
  bool reordered = false;
  for (const Drained::Unit& unit : drained.units) {
    payloads = payloads && unit.payloadPresent;
    if (unit.video) {
      videoStamped = videoStamped && unit.decode.valid() &&
                     timeAtMost(unit.decode, unit.presentation) &&
                     unit.sampleCount == 1;
      reordered = reordered || !sameTime(unit.decode, unit.presentation);
      continue;
    }
    audioUnstamped = audioUnstamped && !unit.decode.valid();
    // The elementary stream is self framing, so one PES carries whole frames
    // this source counts rather than a container-stated lace.
    selfFramed = selfFramed || unit.sampleCount > 1;
  }
  expect(videoStamped,
         "every video sample publishes the container's own decode timestamp at "
         "or before its presentation time");
  expect(audioUnstamped, "audio publishes no decode timestamp");
  expect(selfFramed,
         "a self-framed audio PES publishes every access unit it carried");
  expect(payloads, "every emitted sample carries its payload lease");
  // Without reordered video the two keys would coincide and the rule below
  // would prove nothing.
  expect(reordered,
         "the fixture carries video whose decode order differs from its "
         "presentation order");

  const std::vector<bool> observed = observedOrder(drained);
  expect(observed == replayMerge(drained, 0),
         "the emitted interleave is the two lanes merged on real decode order "
         "with no synthetic lead");
  expect(observed != replayMerge(drained, 250'000'000),
         "a Matroska-style ordering lead would change the interleave, so its "
         "absence here is load bearing");
}

// A 90 kHz stamp cannot name a 44.1 kHz frame boundary. The source recovers
// the ordinal the muxer rounded and never rounds again.
void testAudioTimelineIsAnExactFrameOrdinal(const Fixtures& fixtures) {
  MpegTsMediaSource source;
  if (openAt(source, fixtures.oddRate, 1, std::nullopt, videoOptions())
          .status != MediaSourceOpenStatus::Ready) {
    expect(false, "frame ordinal fixture opens");
    return;
  }
  const Drained drained = drain(source, 1);
  if (!drained.failure.empty()) {
    expect(false, "frame ordinal fixture drains");
    std::cerr << "  drain error: " << drained.failure << '\n';
    return;
  }
  bool exact = true;
  bool offContainerGrid = false;
  std::size_t audioUnits = 0;
  std::optional<std::int64_t> nextFrame;
  for (const Drained::Unit& unit : drained.units) {
    if (unit.video) {
      continue;
    }
    ++audioUnits;
    const bool onGrid = onExactGrid(unit.presentation, kOddRateAudio) &&
                        onExactGrid(unit.duration, kOddRateAudio);
    exact = exact && onGrid;
    offContainerGrid =
        offContainerGrid ||
        !onExactGrid(unit.presentation, kTransportStreamAudioTimeBase);
    if (!onGrid) {
      continue;
    }
    const std::int64_t frame = gridOrdinal(unit.presentation, kOddRateAudio);
    if (nextFrame) {
      exact = exact && frame == *nextFrame;
    }
    nextFrame = frame + gridOrdinal(unit.duration, kOddRateAudio);
  }
  expect(audioUnits > 4, "the fixture carries enough audio to advance");
  expect(exact,
         "audio access units are exactly contiguous on the codec frame grid");
  expect(offContainerGrid,
         "the published audio timeline leaves the container's own time base, "
         "so it is the source's ordinal rather than the muxer's stamp");
}

// A PES header states no CodecDelay, so the anchor carries the lead-in.
void testDecoderLeadInShiftsTheAnchor(const Fixtures& fixtures) {
  const auto firstAudioTime =
      [](const std::filesystem::path& path) -> std::optional<MediaTime> {
    MpegTsMediaSource source;
    if (openAt(source, path, 1, std::nullopt, videoOptions()).status !=
        MediaSourceOpenStatus::Ready) {
      return std::nullopt;
    }
    for (int step = 0; step < 16; ++step) {
      MediaSourceReadResult read = source.readNext(1);
      const auto* sample = std::get_if<MediaSample>(&read);
      if (sample == nullptr) {
        return std::nullopt;
      }
      if (sample->kind == MediaSampleKind::EncodedAudio) {
        return sample->presentationTime;
      }
    }
    return std::nullopt;
  };

  const auto withoutLeadIn = firstAudioTime(fixtures.audioVideo);
  const auto withLeadIn = firstAudioTime(fixtures.leadIn);
  expect(withoutLeadIn.has_value() && withLeadIn.has_value(),
         "both lead-in fixtures stage a first audio access unit");
  if (!withoutLeadIn || !withLeadIn) {
    return;
  }
  expect(sameTime(*withoutLeadIn, MediaTime{0, 1}),
         "a codec with no decoder lead-in anchors on the container stamp");
  const std::int64_t leadIn =
      static_cast<std::int64_t>(wam::media::matroska::kAc3DecoderDelayFrames);
  expect(leadIn > 0, "the shared lead-in constant is not vacuous");
  expect(sameTime(*withLeadIn,
                  MediaTime{-leadIn, static_cast<std::int32_t>(kFullRateAudio)}),
         "a lead-in codec anchors exactly that many frames before the "
         "container stamp so the converter's first published frame lands on "
         "the presentation floor");
}

// The audio-refusal rule this backend does not share with Matroska.
void testUnroutableAudioPreparesMutedVideo(const Fixtures& fixtures) {
  MpegTsMediaSource source;
  const MediaSourceOpenOutcome opened =
      openAt(source, fixtures.unroutableAudio, 1, std::nullopt, videoOptions());
  expect(opened.status == MediaSourceOpenStatus::Ready &&
             opened.descriptor != nullptr,
         "an unroutable audio stream downgrades to video rather than refusing "
         "the file");
  if (opened.status != MediaSourceOpenStatus::Ready) {
    return;
  }
  expect(opened.descriptor->selectedVideo.has_value() &&
             !opened.descriptor->selectedAudio.has_value(),
         "the downgraded generation selects video and no audio");
  expect(!opened.audioWindow.decodeStart.valid() &&
             !opened.audioWindow.presentationStart.valid(),
         "a muted generation states no audio window");
  expect(source.stats().stagedVideoHeads == 1 &&
             source.stats().stagedAudioHeads == 0,
         "a muted generation stages one head and no audio head");
  const Drained drained = drain(source, 1);
  bool videoOnly = !drained.units.empty();
  for (const Drained::Unit& unit : drained.units) {
    videoOnly = videoOnly && unit.video;
  }
  expect(videoOnly && drained.exhausted && drained.endOfStream.size() == 1 &&
             drained.endOfStream.front() == *opened.descriptor->selectedVideo,
         "a muted generation drains video and ends exactly one output");
}

// The mirror of the audio-only route Matroska admits.
void testAudioOnlyStreamIsRefused(const Fixtures& fixtures) {
  MpegTsMediaSource source;
  MediaSourceOpenOptions options;
  options.selection.requireVideo = false;
  const MediaSourceOpenOutcome opened =
      openAt(source, fixtures.audioOnly, 1, std::nullopt, options);
  expect(opened.status == MediaSourceOpenStatus::Unsupported &&
             !opened.error.empty(),
         "a transport stream with no video elementary stream is refused even "
         "when video is not required");
  expect(!source.stats().open && source.assetContext() == nullptr,
         "a refused admission publishes no context");
}

void testAccurateSeekBothDirections(const Fixtures& fixtures) {
  MpegTsMediaSource source;
  if (openAt(source, fixtures.audioVideo, 1, std::nullopt, videoOptions())
          .status != MediaSourceOpenStatus::Ready) {
    expect(false, "seek fixture opens");
    return;
  }
  const auto context = source.assetContext();

  expect(source.armOperation(2), "the forward seek generation arms");
  MediaSourceSeekRequest forward{2, MediaTime{2, 1}, MediaSeekMode::Accurate};
  const auto forwardOutcome = source.seek(forward);
  expect(forwardOutcome.accepted && forwardOutcome.generation == 2,
         "a forward seek inside the timeline is accepted");
  expect(forwardOutcome.actualDecodeStart.valid() &&
             forwardOutcome.actualDecodeStart.value > 0 &&
             timeAtMost(forwardOutcome.actualDecodeStart, forward.target),
         "a forward seek lands on a random access point at or before its "
         "target, not at the timeline origin");
  expect(forwardOutcome.preparedContext.get() == context.get() &&
             source.assetContext().get() == context.get(),
         "a seek reuses the exact prepared context the open admitted");
  expect(sameTime(forwardOutcome.audioWindow.presentationStart, forward.target),
         "the audio window's presentation floor is the requested target");
  expect(timeAtMost(forwardOutcome.audioWindow.decodeStart, forward.target) &&
             !forwardOutcome.audioWindow.startsAtStreamOrigin,
         "a generation away from the origin decodes audio ahead of its floor");

  const Drained afterForward = drain(source, 2);
  expect(afterForward.failure.empty(), "the seeked generation drains");
  bool sawWindowUnit = false;
  bool firstVideoIsSync = false;
  for (const Drained::Unit& unit : afterForward.units) {
    if (unit.video && !firstVideoIsSync) {
      firstVideoIsSync =
          unit.keyFrame &&
          sameTime(unit.presentation, forwardOutcome.actualDecodeStart);
    }
    if (!unit.video && !sawWindowUnit) {
      sawWindowUnit =
          sameTime(unit.presentation, forwardOutcome.audioWindow.decodeStart);
    }
  }
  expect(firstVideoIsSync,
         "the first video sample of a seeked generation is the sync access "
         "unit the outcome named");
  expect(sawWindowUnit,
         "the derived audio window names the first staged access unit");

  bool decodeOnlyBoundary = !afterForward.units.empty();
  bool sawCovering = false;
  for (const Drained::Unit& unit : afterForward.units) {
    if (!unit.video) {
      continue;
    }
    if (intervalClosesAtOrBefore(unit.presentation, unit.duration,
                                 forward.target)) {
      decodeOnlyBoundary = decodeOnlyBoundary && unit.decodeOnly;
    } else if (!sawCovering) {
      sawCovering = true;
      decodeOnlyBoundary = decodeOnlyBoundary && !unit.decodeOnly;
    }
  }
  expect(decodeOnlyBoundary && sawCovering,
         "in Accurate mode every video interval closing at or before the "
         "target is decodeOnly and the covering one is not");

  expect(source.armOperation(3), "the backward seek generation arms");
  MediaSourceSeekRequest backward{3, MediaTime{1, 2}, MediaSeekMode::Accurate};
  const auto backwardOutcome = source.seek(backward);
  expect(backwardOutcome.accepted &&
             timeAtMost(backwardOutcome.actualDecodeStart, backward.target),
         "a backward seek is accepted and lands at or before its target");
  expect(source.stats().seeksAccepted == 2,
         "stats count exactly the accepted seeks");
}

void testCancellation(const Fixtures& fixtures) {
  {
    MpegTsMediaSource source;
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
  MpegTsMediaSource source;
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
  expect(source.stats().open && source.stats().cancelled,
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
    std::cerr << "mpeg-ts media source contracts need a muxer; skipping\n";
    return 77;
  }
  Fixtures fixtures;
  buildFixtures(argv[1], fixtures);
  if (!fixtures.valid) {
    std::cerr << "FAIL: fixtures could not be muxed\n";
    return 1;
  }

  testColdOpenClampsToTheTimelineOrigin(fixtures);
  testEntryRefusalsAndPublication(fixtures);
  testMergeKeysOnRealDecodeTimestamps(fixtures);
  testAudioTimelineIsAnExactFrameOrdinal(fixtures);
  testDecoderLeadInShiftsTheAnchor(fixtures);
  testUnroutableAudioPreparesMutedVideo(fixtures);
  testAudioOnlyStreamIsRefused(fixtures);
  testAccurateSeekBothDirections(fixtures);
  testCancellation(fixtures);

  if (failures == 0) {
    std::cout << "mpeg-ts media source contracts passed\n";
  }
  return failures == 0 ? 0 : 1;
}
