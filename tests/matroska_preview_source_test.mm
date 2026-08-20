// Matroska scrub-preview source contract.
//
// Three things are proved here that no other suite covers:
//
//   1. Cue mapping. A preview epoch begins at the Cue at or before its target,
//      never after it, and the first sample it emits is that Cue's keyframe.
//      The Matroska route needs no full-sync back-walk for this, which is the
//      whole reason the preview costs one cursor instead of a reader plus a
//      bounded backwards walk, so the fixture also proves that exactly one
//      cursor is created per epoch.
//   2. Cancellation. The demuxer's cancellation seam is a POD probe, so the
//      source's own epoch latch is what every plan, cursor read, and payload
//      copy observes; a cancel for the live operation must be answered and a
//      cancel for a stale one must be inert.
//   3. Facts. The neutral NativePreviewSourceFacts vocabulary is answered
//      against cursors the way the AVFoundation source answers it against
//      AVAssetReaders.
//
// It is also the second consumer of the promoted sample builders in
// `matroska_sample_builder.hpp`: this binary links both it and the main
// Matroska media source, so a builder that only one of them could call would
// not link.

#include "platform/macos/matroska_preview_source.hpp"

#include "media/matroska_demuxer.hpp"
#include "media/matroska_ebml.hpp"
#include "media/native_media_source.hpp"
#include "platform/macos/matroska_asset_context.hpp"
#include "platform/macos/matroska_media_source.hpp"
#include "platform/macos/matroska_sample_builder.hpp"
#include "platform/macos/native_preview_source.hpp"

#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <numeric>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace {

using wam::macos::MatroskaPreviewSource;
using wam::macos::NativePreviewBeginOutcome;
using wam::macos::NativePreviewBinding;
using wam::macos::NativePreviewCancelled;
using wam::macos::NativePreviewEndOfStream;
using wam::macos::NativePreviewFailure;
using wam::macos::NativePreviewReadResult;
using wam::macos::NativePreviewRequest;
using wam::macos::NativePreviewSourceFacts;
using wam::macos::NativePreviewStatus;
using wam::media::MediaSample;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaTime;
using wam::media::MediaTimeOrder;
using wam::media::matroska::MatroskaPrepareOutcome;
using wam::media::matroska::SeekableByteReader;
using Bytes = std::vector<std::byte>;

int failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

// ---------------------------------------------------------------------------
// Exact EBML byte builders. Same primitives as tests/matroska_demuxer_test.cpp,
// reduced to the video-only shape this contract needs.
// ---------------------------------------------------------------------------

constexpr std::uint32_t kEbmlHeaderId{0x1A45DFA3};
constexpr std::uint32_t kSegmentId{0x18538067};
constexpr std::uint32_t kInfoId{0x1549A966};
constexpr std::uint32_t kTimestampScaleId{0x2AD7B1};
constexpr std::uint32_t kDurationId{0x4489};
constexpr std::uint32_t kTracksId{0x1654AE6B};
constexpr std::uint32_t kTrackEntryId{0xAE};
constexpr std::uint32_t kTrackNumberId{0xD7};
constexpr std::uint32_t kTrackUidId{0x73C5};
constexpr std::uint32_t kTrackTypeId{0x83};
constexpr std::uint32_t kFlagLacingId{0x9C};
constexpr std::uint32_t kDefaultDurationId{0x23E383};
constexpr std::uint32_t kCodecIdId{0x86};
constexpr std::uint32_t kCodecPrivateId{0x63A2};
constexpr std::uint32_t kLanguageId{0x22B59C};
constexpr std::uint32_t kVideoId{0xE0};
constexpr std::uint32_t kPixelWidthId{0xB0};
constexpr std::uint32_t kPixelHeightId{0xBA};
constexpr std::uint32_t kColourId{0x55B0};
constexpr std::uint32_t kMatrixCoefficientsId{0x55B1};
constexpr std::uint32_t kTransferCharacteristicsId{0x55BA};
constexpr std::uint32_t kPrimariesId{0x55BB};
constexpr std::uint32_t kClusterId{0x1F43B675};
constexpr std::uint32_t kClusterTimestampId{0xE7};
constexpr std::uint32_t kSimpleBlockId{0xA3};
constexpr std::uint32_t kCuesId{0x1C53BB6B};
constexpr std::uint32_t kCuePointId{0xBB};
constexpr std::uint32_t kCueTimeId{0xB3};
constexpr std::uint32_t kCueTrackPositionsId{0xB7};
constexpr std::uint32_t kCueTrackId{0xF7};
constexpr std::uint32_t kCueClusterPositionId{0xF1};
constexpr std::uint32_t kCueRelativePositionId{0xF0};
constexpr std::uint32_t kCueBlockNumberId{0x5378};

void append(Bytes& destination, const Bytes& source) {
  destination.insert(destination.end(), source.begin(), source.end());
}

void appendId(Bytes& bytes, std::uint32_t id) {
  unsigned width = 1;
  if (id > 0xFFFFFFU) {
    width = 4;
  } else if (id > 0xFFFFU) {
    width = 3;
  } else if (id > 0xFFU) {
    width = 2;
  }
  for (unsigned index = width; index > 0; --index) {
    bytes.push_back(
        static_cast<std::byte>((id >> ((index - 1U) * 8U)) & 0xFFU));
  }
}

void appendSize(Bytes& bytes, std::uint64_t size) {
  unsigned width = 1;
  while (width < 8) {
    const auto maximum = (std::uint64_t{1} << (7U * width)) - 2U;
    if (size <= maximum) {
      break;
    }
    ++width;
  }
  const std::uint64_t encoded = (std::uint64_t{1} << (7U * width)) | size;
  for (unsigned index = width; index > 0; --index) {
    bytes.push_back(
        static_cast<std::byte>((encoded >> ((index - 1U) * 8U)) & 0xFFU));
  }
}

Bytes element(std::uint32_t id, const Bytes& payload) {
  Bytes result;
  appendId(result, id);
  appendSize(result, payload.size());
  append(result, payload);
  return result;
}

Bytes unsignedBytes(std::uint64_t value) {
  unsigned width = 1;
  while (width < 8 && value >= (std::uint64_t{1} << (width * 8U))) {
    ++width;
  }
  Bytes result;
  for (unsigned index = width; index > 0; --index) {
    result.push_back(
        static_cast<std::byte>((value >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return result;
}

Bytes uintElement(std::uint32_t id, std::uint64_t value) {
  return element(id, unsignedBytes(value));
}

Bytes asciiElement(std::uint32_t id, std::string_view value) {
  Bytes payload;
  for (const char character : value) {
    payload.push_back(static_cast<std::byte>(character));
  }
  return element(id, payload);
}

Bytes doubleElement(std::uint32_t id, double value) {
  const auto bits = std::bit_cast<std::uint64_t>(value);
  Bytes payload;
  for (unsigned index = 8; index > 0; --index) {
    payload.push_back(
        static_cast<std::byte>((bits >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return element(id, payload);
}

Bytes ebmlHeader() {
  Bytes payload;
  append(payload, uintElement(0x4286, 1));
  append(payload, uintElement(0x42F7, 1));
  append(payload, uintElement(0x42F2, 4));
  append(payload, uintElement(0x42F3, 8));
  append(payload, asciiElement(0x4282, "matroska"));
  append(payload, uintElement(0x4287, 4));
  append(payload, uintElement(0x4285, 2));
  return element(kEbmlHeaderId, payload);
}

// Encoder-produced High-profile avcC for the repository's deterministic
// 1280x720 H.264 sample, byte-identical to the record admitted by
// tests/matroska_demuxer_test.cpp and tests/video_codec_configuration_test.cpp.
constexpr std::array<std::uint8_t, 45> kSampleAvcC{
    0x01, 0x64, 0x00, 0x1f, 0xff, 0xe1, 0x00, 0x1a, 0x67, 0x64, 0x00, 0x1f,
    0xac, 0xd9, 0x40, 0x50, 0x05, 0xbb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
    0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x83, 0x19, 0x60, 0x01, 0x00,
    0x04, 0x68, 0xef, 0x8f, 0xcb, 0xfd, 0xf8, 0xf8, 0x00};

constexpr std::uint32_t kWidth{1280};
constexpr std::uint32_t kHeight{720};
constexpr std::uint64_t kTimestampScaleNanoseconds{1'000'000};
constexpr std::uint64_t kDefaultDurationNanoseconds{40'000'000};
// Four Cues, half a second apart: 0.0, 0.5, 1.0 and 1.5 seconds.
constexpr std::array<std::uint64_t, 4> kClusterTicks{0, 500, 1000, 1500};
constexpr double kDurationTicks{2000.0};
constexpr std::size_t kBlocksPerCluster{3};

const char* const kFixturePath = "/tmp/wam-matroska-preview-fixture.mkv";

Bytes videoTrackEntry() {
  Bytes videoPayload;
  append(videoPayload, uintElement(kPixelWidthId, kWidth));
  append(videoPayload, uintElement(kPixelHeightId, kHeight));
  Bytes colourPayload;
  append(colourPayload, uintElement(kMatrixCoefficientsId, 1));
  append(colourPayload, uintElement(kTransferCharacteristicsId, 1));
  append(colourPayload, uintElement(kPrimariesId, 1));
  append(videoPayload, element(kColourId, colourPayload));

  Bytes codecPrivate;
  codecPrivate.reserve(kSampleAvcC.size());
  for (const std::uint8_t octet : kSampleAvcC) {
    codecPrivate.push_back(static_cast<std::byte>(octet));
  }

  Bytes payload;
  append(payload, uintElement(kTrackNumberId, 1));
  append(payload, uintElement(kTrackUidId, 0xAB11));
  append(payload, uintElement(kTrackTypeId, 1));
  append(payload, uintElement(kFlagLacingId, 0));
  append(payload,
         uintElement(kDefaultDurationId, kDefaultDurationNanoseconds));
  append(payload, asciiElement(kCodecIdId, "V_MPEG4/ISO/AVC"));
  append(payload, asciiElement(kLanguageId, "und"));
  append(payload, element(kCodecPrivateId, codecPrivate));
  append(payload, element(kVideoId, videoPayload));
  return element(kTrackEntryId, payload);
}

// One SimpleBlock: track 1, no lacing, a deterministic rolling payload so an
// offset error changes the copied bytes instead of silently matching.
Bytes simpleBlock(std::int16_t relative, bool keyFrame, std::size_t bytes,
                  std::uint8_t& fill) {
  Bytes payload{
      std::byte{0x81},
      static_cast<std::byte>(
          (static_cast<std::uint16_t>(relative) >> 8U) & 0xFFU),
      static_cast<std::byte>(static_cast<std::uint16_t>(relative) & 0xFFU),
      static_cast<std::byte>(keyFrame ? 0x80U : 0x00U)};
  for (std::size_t index = 0; index < bytes; ++index) {
    payload.push_back(static_cast<std::byte>(fill));
    fill = static_cast<std::uint8_t>(fill + 1U);
  }
  return element(kSimpleBlockId, payload);
}

struct Fixture {
  Bytes bytes;
  // Exact media time of every Cue, in the order the index holds them.
  std::vector<MediaTime> cueTimes;
};

MediaTime reducedTime(std::uint64_t numerator, std::uint64_t denominator) {
  const std::uint64_t divisor = std::gcd(numerator, denominator);
  return MediaTime{static_cast<std::int64_t>(numerator / divisor),
                   static_cast<std::int32_t>(denominator / divisor)};
}

MediaTime tickTime(std::uint64_t tick) {
  return reducedTime(tick * kTimestampScaleNanoseconds, 1'000'000'000U);
}

Fixture buildFixture() {
  Fixture fixture;
  std::uint8_t fill = 1;

  Bytes infoPayload;
  append(infoPayload,
         uintElement(kTimestampScaleId, kTimestampScaleNanoseconds));
  append(infoPayload, doubleElement(kDurationId, kDurationTicks));

  Bytes segmentPayload = element(kInfoId, infoPayload);
  append(segmentPayload, element(kTracksId, videoTrackEntry()));

  struct CuePoint {
    std::uint64_t time{0};
    std::uint64_t clusterPosition{0};
    std::uint64_t relativePosition{0};
  };
  std::vector<CuePoint> cuePoints;

  for (const std::uint64_t base : kClusterTicks) {
    Bytes clusterPayload = uintElement(kClusterTimestampId, base);
    // The Cue names the Cluster's random access point, which is always the
    // first Block written into it.
    const auto keyBlockRelative =
        static_cast<std::uint64_t>(clusterPayload.size());
    append(clusterPayload, simpleBlock(0, true, 6, fill));
    append(clusterPayload, simpleBlock(40, false, 7, fill));
    append(clusterPayload, simpleBlock(80, false, 8, fill));

    const Bytes cluster = element(kClusterId, clusterPayload);
    const auto clusterDataOffset =
        static_cast<std::uint64_t>(cluster.size() - clusterPayload.size());
    CuePoint point;
    point.time = base;
    point.clusterPosition = static_cast<std::uint64_t>(segmentPayload.size());
    point.relativePosition = keyBlockRelative;
    static_cast<void>(clusterDataOffset);
    cuePoints.push_back(point);
    append(segmentPayload, cluster);
  }

  Bytes cuesPayload;
  for (const CuePoint& point : cuePoints) {
    Bytes positions;
    append(positions, uintElement(kCueTrackId, 1));
    append(positions,
           uintElement(kCueClusterPositionId, point.clusterPosition));
    append(positions,
           uintElement(kCueRelativePositionId, point.relativePosition));
    append(positions, uintElement(kCueBlockNumberId, 1));
    Bytes cuePoint = uintElement(kCueTimeId, point.time);
    append(cuePoint, element(kCueTrackPositionsId, positions));
    append(cuesPayload, element(kCuePointId, cuePoint));
    fixture.cueTimes.push_back(tickTime(point.time));
  }
  append(segmentPayload, element(kCuesId, cuesPayload));

  fixture.bytes = ebmlHeader();
  append(fixture.bytes, element(kSegmentId, segmentPayload));
  return fixture;
}

class MemoryReader final : public SeekableByteReader {
 public:
  explicit MemoryReader(Bytes bytes) noexcept : bytes_(std::move(bytes)) {}

  [[nodiscard]] std::uint64_t size() const noexcept override {
    return static_cast<std::uint64_t>(bytes_.size());
  }

  [[nodiscard]] bool readAt(std::uint64_t offset,
                            std::span<std::byte> destination) noexcept
      override {
    if (offset > bytes_.size() ||
        destination.size() > bytes_.size() - offset) {
      return false;
    }
    if (!destination.empty()) {
      std::memcpy(destination.data(),
                  bytes_.data() + static_cast<std::size_t>(offset),
                  destination.size());
    }
    reads.fetch_add(1, std::memory_order_relaxed);
    return true;
  }

  std::atomic<std::uint64_t> reads{0};

 private:
  Bytes bytes_;
};

struct PreparedFixture {
  Fixture fixture;
  std::shared_ptr<MemoryReader> reader;
  MatroskaPrepareOutcome outcome;
  std::shared_ptr<const wam::macos::MatroskaAssetContext> context;

  [[nodiscard]] NativePreviewBinding binding() const {
    NativePreviewBinding value;
    value.localPath = kFixturePath;
    // Exact descriptor-instance identity is what matchesPreviewBinding()
    // proves, so the binding republishes the context's own instance.
    value.descriptor = context->descriptor();
    value.assetContext = context;
    return value;
  }
};

PreparedFixture prepare() {
  PreparedFixture prepared;
  prepared.fixture = buildFixture();
  prepared.reader = std::make_shared<MemoryReader>(prepared.fixture.bytes);
  MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  prepared.outcome = wam::media::matroska::prepareMatroska(
      prepared.reader, kFixturePath, options);
  if (prepared.outcome.asset != nullptr) {
    prepared.context = wam::macos::adoptPreparedMatroskaAssetContext(
        kFixturePath, options, prepared.outcome.asset);
  }
  return prepared;
}

[[nodiscard]] const MediaSample* sampleOf(
    const NativePreviewReadResult& result) noexcept {
  return std::get_if<MediaSample>(&result);
}

[[nodiscard]] bool sameTime(MediaTime lhs, MediaTime rhs) noexcept {
  const auto order = wam::media::compareMediaTime(lhs, rhs);
  return order.has_value() && *order == MediaTimeOrder::Equal;
}

// ---------------------------------------------------------------------------
// Contracts
// ---------------------------------------------------------------------------

void testFixtureAdmitsAndSelectsVideo() {
  const PreparedFixture prepared = prepare();
  expect(prepared.outcome.asset != nullptr && prepared.context != nullptr,
         "the synthetic Matroska fixture is admitted and adopted");
  if (prepared.context == nullptr) {
    return;
  }
  expect(prepared.context->backendKind() ==
             wam::media::MediaSourceBackendKind::Matroska,
         "an adopted Matroska context reports the Matroska backend kind");
  expect(prepared.outcome.asset->cues().size() == kClusterTicks.size(),
         "the fixture publishes one Cue per Cluster");
  const auto& descriptor = *prepared.context->descriptor();
  expect(descriptor.selectedVideo.has_value() &&
             sameTime(descriptor.duration, tickTime(2000)),
         "the fixture selects video over a two-second timeline");
}

void testCueMappingWithoutBackWalk() {
  const PreparedFixture prepared = prepare();
  if (prepared.context == nullptr) {
    expect(false, "cue mapping fixture prepares");
    return;
  }
  auto source = MatroskaPreviewSource::create(prepared.binding());
  expect(source != nullptr, "a preview source is created from a live context");
  if (source == nullptr) {
    return;
  }

  // Targets chosen to land inside each Cue interval, at a Cue exactly, and
  // just short of the timeline end.
  struct Case {
    MediaTime target;
    std::size_t cue;
  };
  const std::array<Case, 6> cases{
      Case{MediaTime{0, 1}, 0},      Case{MediaTime{1, 4}, 0},
      Case{MediaTime{1, 2}, 1},      Case{MediaTime{3, 4}, 1},
      Case{MediaTime{1, 1}, 2},      Case{MediaTime{9, 5}, 3}};

  std::uint64_t epoch = 0;
  bool exact = true;
  for (const Case& value : cases) {
    ++epoch;
    const NativePreviewBeginOutcome begun =
        source->begin(NativePreviewRequest{epoch, value.target});
    const MediaTime expected = prepared.fixture.cueTimes[value.cue];
    exact = exact && begun.status == NativePreviewStatus::Ready &&
            begun.epoch == epoch &&
            sameTime(begun.actualDecodeStart, expected);
    if (begun.status != NativePreviewStatus::Ready) {
      continue;
    }
    // The very first sample is the Cue's own keyframe: no back-walk, no
    // discarded preroll, and nothing read before the random access point.
    const NativePreviewReadResult first = source->readNext(epoch);
    const MediaSample* sample = sampleOf(first);
    exact = exact && sample != nullptr && sample->keyFrame &&
            sameTime(sample->presentationTime, expected) &&
            !sample->decodeTime.valid() && sample->sampleCount == 1 &&
            sample->generation == epoch && sample->payload;
  }
  expect(exact,
         "every preview epoch begins on the Cue at or before its target and "
         "emits that Cue's keyframe first");

  const NativePreviewSourceFacts facts = source->facts();
  expect(facts.backend.readersCreated == cases.size() &&
             facts.backend.readersStarted == cases.size(),
         "exactly one cursor is created and started per preview epoch");
  expect(facts.backend.assetLoadAttempts == 0 &&
             facts.backend.assetLoadsCompleted == 0 &&
             facts.backend.assetLoadNanoseconds == 0,
         "preview never reopens a container the main source already admitted");
}

void testDecodeOnlyBoundaryAndForwardRetarget() {
  const PreparedFixture prepared = prepare();
  if (prepared.context == nullptr) {
    expect(false, "decodeOnly fixture prepares");
    return;
  }
  auto source = MatroskaPreviewSource::create(prepared.binding());
  if (source == nullptr) {
    expect(false, "decodeOnly fixture creates a preview source");
    return;
  }
  // Target 0.58 s is inside the 0.5 s Cue's cluster: the keyframe at 0.5 and
  // the block at 0.54 both close before it, and the block at 0.58 covers it.
  const MediaTime target{29, 50};
  const NativePreviewBeginOutcome begun =
      source->begin(NativePreviewRequest{1, target});
  expect(begun.status == NativePreviewStatus::Ready,
         "decodeOnly epoch begins on its Cue");
  std::vector<bool> decodeOnly;
  for (std::size_t index = 0; index < kBlocksPerCluster; ++index) {
    const NativePreviewReadResult result = source->readNext(1);
    const MediaSample* sample = sampleOf(result);
    if (sample == nullptr) {
      break;
    }
    decodeOnly.push_back(sample->decodeOnly);
  }
  expect(decodeOnly.size() == kBlocksPerCluster && decodeOnly[0] &&
             decodeOnly[1] && !decodeOnly[2],
         "samples whose interval closes at or before the target are decodeOnly "
         "and the covering sample is not");

  const NativePreviewSourceFacts before = source->facts();
  expect(!source->advanceTarget(1, MediaTime{1, 2}),
         "a retarget behind the current target is refused");
  expect(!source->advanceTarget(2, MediaTime{7, 5}),
         "a retarget for a stale epoch is refused");
  expect(!source->advanceTarget(1, MediaTime{5, 1}),
         "a retarget beyond the duration is refused");
  expect(source->advanceTarget(1, MediaTime{7, 5}),
         "a nondecreasing in-duration retarget is accepted");
  const NativePreviewSourceFacts after = source->facts();
  expect(after.forwardRetargets == before.forwardRetargets + 1 &&
             after.backend.readersCreated == before.backend.readersCreated &&
             sameTime(after.target, MediaTime{7, 5}),
         "a forward retarget publishes the new target without a new cursor");
}

void testEndOfStreamIsIdempotent() {
  const PreparedFixture prepared = prepare();
  if (prepared.context == nullptr) {
    expect(false, "end-of-stream fixture prepares");
    return;
  }
  auto source = MatroskaPreviewSource::create(prepared.binding());
  if (source == nullptr) {
    expect(false, "end-of-stream fixture creates a preview source");
    return;
  }
  const NativePreviewBeginOutcome begun =
      source->begin(NativePreviewRequest{1, MediaTime{3, 2}});
  expect(begun.status == NativePreviewStatus::Ready,
         "final-Cue epoch begins");
  std::size_t samples = 0;
  NativePreviewReadResult result = source->readNext(1);
  while (sampleOf(result) != nullptr && samples <= kBlocksPerCluster) {
    ++samples;
    result = source->readNext(1);
  }
  expect(samples == kBlocksPerCluster &&
             std::holds_alternative<NativePreviewEndOfStream>(result) &&
             std::holds_alternative<NativePreviewEndOfStream>(
                 source->readNext(1)),
         "the last Cue's cursor drains its cluster and then reports an "
         "idempotent end of stream");
  expect(source->facts().samplesRead == kBlocksPerCluster,
         "samplesRead counts exactly the emitted samples");
}

void testCancellation() {
  const PreparedFixture prepared = prepare();
  if (prepared.context == nullptr) {
    expect(false, "cancellation fixture prepares");
    return;
  }
  auto source = MatroskaPreviewSource::create(prepared.binding());
  if (source == nullptr) {
    expect(false, "cancellation fixture creates a preview source");
    return;
  }

  // A cancel published before begin() reaches its plan is answered by the
  // begin itself, because the demuxer probe already compares against the
  // operation epoch this source published first.
  expect(source->begin(NativePreviewRequest{1, MediaTime{1, 2}}).status ==
             NativePreviewStatus::Ready,
         "first cancellation epoch begins");
  expect(sampleOf(source->readNext(1)) != nullptr,
         "the live epoch reads before cancellation");

  // A cancel for an epoch that is not the live operation is inert.
  source->requestCancel(99);
  expect(!source->facts().cancelled && source->facts().open,
         "a cancel for a foreign epoch leaves the live reader open");

  // The real cancel. requestCancel() is the only cross-thread entry point, so
  // it is exercised from another thread here.
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

  // A newer epoch is unaffected by the older cancellation and reads normally.
  const NativePreviewBeginOutcome revived =
      source->begin(NativePreviewRequest{2, MediaTime{1, 1}});
  expect(revived.status == NativePreviewStatus::Ready &&
             sampleOf(source->readNext(2)) != nullptr,
         "a newer epoch replaces a cancelled one and reads");

  // A cancel published before the plan runs is answered by begin().
  source->requestCancel(2);
  const NativePreviewBeginOutcome afterStaleCancel =
      source->begin(NativePreviewRequest{3, MediaTime{1, 1}});
  expect(afterStaleCancel.status == NativePreviewStatus::Ready,
         "a cancel for the previous epoch does not poison the next one");
}

void testRequestAdmission() {
  const PreparedFixture prepared = prepare();
  if (prepared.context == nullptr) {
    expect(false, "admission fixture prepares");
    return;
  }
  auto source = MatroskaPreviewSource::create(prepared.binding());
  if (source == nullptr) {
    expect(false, "admission fixture creates a preview source");
    return;
  }
  expect(source->begin(NativePreviewRequest{0, MediaTime{0, 1}}).status ==
             NativePreviewStatus::Rejected,
         "epoch zero is refused");
  expect(source->begin(NativePreviewRequest{1, MediaTime{5, 1}}).status ==
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

void testBindingRejection() {
  const PreparedFixture prepared = prepare();
  if (prepared.context == nullptr) {
    expect(false, "binding rejection fixture prepares");
    return;
  }
  NativePreviewBinding noContext = prepared.binding();
  noContext.assetContext.reset();
  expect(MatroskaPreviewSource::create(noContext) == nullptr,
         "the Matroska preview source refuses a cold-load binding");

  NativePreviewBinding wrongPath = prepared.binding();
  wrongPath.localPath = "/tmp/wam-matroska-preview-other.mkv";
  expect(MatroskaPreviewSource::create(wrongPath) == nullptr,
         "a binding naming another path is refused");

  NativePreviewBinding clonedDescriptor = prepared.binding();
  clonedDescriptor.descriptor =
      std::make_shared<const wam::media::MediaSourceDescriptor>(
          *prepared.context->descriptor());
  expect(MatroskaPreviewSource::create(clonedDescriptor) == nullptr,
         "a deep-equal descriptor clone is not descriptor identity");

  NativePreviewBinding relative = prepared.binding();
  relative.localPath = "wam-matroska-preview-fixture.mkv";
  expect(MatroskaPreviewSource::create(relative) == nullptr,
         "a relative path is refused");
}

void testNeutralFactorySelectsTheMatroskaSource() {
  const PreparedFixture prepared = prepare();
  if (prepared.context == nullptr) {
    expect(false, "factory fixture prepares");
    return;
  }
  auto source = wam::macos::createNativePreviewSource(prepared.binding());
  expect(source != nullptr,
         "the neutral factory builds a source for a Matroska context");
  if (source == nullptr) {
    return;
  }
  const NativePreviewBeginOutcome begun =
      source->begin(NativePreviewRequest{1, MediaTime{1, 1}});
  const NativePreviewReadResult first = source->readNext(1);
  const MediaSample* sample = sampleOf(first);
  expect(begun.status == NativePreviewStatus::Ready && sample != nullptr &&
             sample->keyFrame &&
             sameTime(sample->presentationTime, MediaTime{1, 1}),
         "the factory's Matroska source previews through the neutral "
         "interface");
}

// The promoted builders are what let the preview source and the main media
// source hand VideoToolbox the same description and the same buffer shape.
// Calling them here from the preview side, in a binary that also links the
// main source, is the compile-and-link proof that the promotion is real.
void testPromotedSampleBuilders() {
  const PreparedFixture prepared = prepare();
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
      wam::macos::createMatroskaVideoFormatDescription(*track);
  expect(format != nullptr,
         "the promoted format factory builds a description for avcC");
  if (format == nullptr) {
    return;
  }
  const CMVideoDimensions dimensions =
      CMVideoFormatDescriptionGetDimensions(format);
  expect(CMFormatDescriptionGetMediaSubType(format) ==
                 kCMVideoCodecType_H264 &&
             dimensions.width == static_cast<std::int32_t>(kWidth) &&
             dimensions.height == static_cast<std::int32_t>(kHeight),
         "the promoted description restates the admitted codec and geometry");
  CFRelease(format);

  auto source = MatroskaPreviewSource::create(prepared.binding());
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
  expect(!CMTIME_IS_VALID(CMSampleBufferGetDecodeTimeStamp(buffer)),
         "the preview buffer carries no fabricated decode stamp");
  const CMTime presentation = CMSampleBufferGetPresentationTimeStamp(buffer);
  expect(presentation.value == sample->presentationTime.value &&
             presentation.timescale == sample->presentationTime.timescale,
         "container rationals reach CoreMedia without a seconds round trip");
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(buffer, false);
  bool notSyncIsFalse = false;
  if (attachments != nullptr && CFArrayGetCount(attachments) == 1) {
    auto entry = static_cast<CFDictionaryRef>(
        CFArrayGetValueAtIndex(attachments, 0));
    CFTypeRef notSync =
        CFDictionaryGetValue(entry, kCMSampleAttachmentKey_NotSync);
    notSyncIsFalse = notSync != nullptr &&
                     CFGetTypeID(notSync) == CFBooleanGetTypeID() &&
                     !CFBooleanGetValue(static_cast<CFBooleanRef>(notSync));
  }
  expect(notSyncIsFalse,
         "the Cue's keyframe is stated to VideoToolbox as a sync sample");
}

void testMemoryFactsStageAtMostOneBuffer() {
  const PreparedFixture prepared = prepare();
  if (prepared.context == nullptr) {
    expect(false, "memory facts fixture prepares");
    return;
  }
  auto source = MatroskaPreviewSource::create(prepared.binding());
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

}  // namespace

int main() {
  testFixtureAdmitsAndSelectsVideo();
  testCueMappingWithoutBackWalk();
  testDecodeOnlyBoundaryAndForwardRetarget();
  testEndOfStreamIsIdempotent();
  testCancellation();
  testRequestAdmission();
  testBindingRejection();
  testNeutralFactorySelectsTheMatroskaSource();
  testPromotedSampleBuilders();
  testMemoryFactsStageAtMostOneBuffer();
  if (failures == 0) {
    std::cout << "matroska preview source contracts passed\n";
  }
  return failures == 0 ? 0 : 1;
}
