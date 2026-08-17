// Regime microbenchmarks for the Matroska demuxer.
//
// The repository's benchmarks were end-to-end only (fps, clock rate,
// underruns, open latency), so the demuxer's own small/medium/large behaviour
// and its transition points were unmeasured -- a KNOWN GAP named in
// docs/AGENT_PERFORMANCE_PRINCIPLES.md. This executable closes it with
// synthetic in-memory documents, so every number is reader-cost-free unless a
// case deliberately opts into a real file descriptor.
//
// The EBML byte builders below mirror tests/matroska_demuxer_test.cpp so a
// benchmark document is byte-shaped exactly like a fixture document.
//
// Not a correctness test: it asserts only enough to prove each phase actually
// ran (a benchmark that silently measures an early rejection is worse than no
// benchmark at all).

#include "media/matroska_aac.hpp"
#include "media/matroska_demuxer.hpp"
#include "media/matroska_ebml.hpp"
#include "media/native_media_source.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <memory>
#include <numeric>
#include <span>
#include <string>
#include <string_view>
#include <unistd.h>
#include <variant>
#include <vector>

namespace {

using namespace wam::media::matroska;
using wam::media::MediaSeekMode;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaTime;

using Bytes = std::vector<std::byte>;

int failures = 0;

void require(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "BENCH PRECONDITION FAILED: %s\n", message);
    ++failures;
  }
}

// ---------------------------------------------------------------------------
// Exact EBML byte builders (same primitives as tests/matroska_demuxer_test.cpp)
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
constexpr std::uint32_t kAudioId{0xE1};
constexpr std::uint32_t kSamplingFrequencyId{0xB5};
constexpr std::uint32_t kChannelsId{0x9F};
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

void appendVintOfWidth(Bytes& bytes, std::uint64_t value, unsigned width) {
  const std::uint64_t encoded = (std::uint64_t{1} << (7U * width)) | value;
  for (unsigned index = width; index > 0; --index) {
    bytes.push_back(
        static_cast<std::byte>((encoded >> ((index - 1U) * 8U)) & 0xFFU));
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
  appendVintOfWidth(bytes, size, width);
}

Bytes element(std::uint32_t id, const Bytes& payload) {
  Bytes result;
  result.reserve(payload.size() + 12U);
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

// Byte-identical to the record admitted by the demuxer and codec tests.
constexpr std::array<std::uint8_t, 45> kSampleAvcC{
    0x01, 0x64, 0x00, 0x1f, 0xff, 0xe1, 0x00, 0x1a, 0x67, 0x64, 0x00, 0x1f,
    0xac, 0xd9, 0x40, 0x50, 0x05, 0xbb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
    0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x83, 0x19, 0x60, 0x01, 0x00,
    0x04, 0x68, 0xef, 0x8f, 0xcb, 0xfd, 0xf8, 0xf8, 0x00};
constexpr std::uint32_t kSampleAvcWidth{1280};
constexpr std::uint32_t kSampleAvcHeight{720};
constexpr std::array<std::uint8_t, 2> kAacStereo48Asc{0x11, 0x90};
constexpr std::uint32_t kAudioSampleRate{48'000};
constexpr std::uint64_t kTimestampScaleNanoseconds{1'000'000};
constexpr std::uint64_t kVideoDefaultDurationNanoseconds{40'000'000};
constexpr std::uint64_t kVideoTrackNumber{1};
constexpr std::uint64_t kAudioTrackNumber{2};

Bytes fromOctets(std::span<const std::uint8_t> octets) {
  Bytes result;
  result.reserve(octets.size());
  for (const std::uint8_t octet : octets) {
    result.push_back(static_cast<std::byte>(octet));
  }
  return result;
}

Bytes videoTrackEntry() {
  Bytes videoPayload;
  append(videoPayload, uintElement(kPixelWidthId, kSampleAvcWidth));
  append(videoPayload, uintElement(kPixelHeightId, kSampleAvcHeight));
  Bytes colourPayload;
  append(colourPayload, uintElement(kMatrixCoefficientsId, 1));
  append(colourPayload, uintElement(kTransferCharacteristicsId, 1));
  append(colourPayload, uintElement(kPrimariesId, 1));
  append(videoPayload, element(kColourId, colourPayload));

  Bytes payload;
  append(payload, uintElement(kTrackNumberId, kVideoTrackNumber));
  append(payload, uintElement(kTrackUidId, 0xAB11));
  append(payload, uintElement(kTrackTypeId, 1));
  append(payload, uintElement(kFlagLacingId, 0));
  append(payload,
         uintElement(kDefaultDurationId, kVideoDefaultDurationNanoseconds));
  append(payload, asciiElement(kCodecIdId, "V_MPEG4/ISO/AVC"));
  append(payload, asciiElement(kLanguageId, "und"));
  append(payload, element(kCodecPrivateId, fromOctets(kSampleAvcC)));
  append(payload, element(kVideoId, videoPayload));
  return element(kTrackEntryId, payload);
}

Bytes audioTrackEntry() {
  Bytes audioPayload;
  append(audioPayload, doubleElement(kSamplingFrequencyId,
                                     static_cast<double>(kAudioSampleRate)));
  append(audioPayload, uintElement(kChannelsId, 2));

  Bytes payload;
  append(payload, uintElement(kTrackNumberId, kAudioTrackNumber));
  append(payload, uintElement(kTrackUidId, 0xAB22));
  append(payload, uintElement(kTrackTypeId, 2));
  append(payload, asciiElement(kCodecIdId, "A_AAC"));
  append(payload, asciiElement(kLanguageId, "eng"));
  append(payload, element(kCodecPrivateId, fromOctets(kAacStereo48Asc)));
  append(payload, element(kAudioId, audioPayload));
  return element(kTrackEntryId, payload);
}

// A SimpleBlock with exactly one frame of `frameBytes` deterministic octets.
struct BuiltBlock {
  Bytes bytes;
  std::uint64_t frameOffset{0};  // relative to bytes[0]
  std::uint64_t frameSize{0};
};

BuiltBlock buildSimpleBlock(std::uint64_t track, std::int16_t relative,
                            bool keyFrame, std::size_t frameBytes,
                            std::uint8_t& fill) {
  Bytes body{
      static_cast<std::byte>(0x80U | track),
      static_cast<std::byte>(
          (static_cast<std::uint16_t>(relative) >> 8U) & 0xFFU),
      static_cast<std::byte>(static_cast<std::uint16_t>(relative) & 0xFFU),
      static_cast<std::byte>(keyFrame ? 0x80U : 0x00U)};
  const std::size_t payloadStart = body.size();
  body.reserve(payloadStart + frameBytes);
  for (std::size_t index = 0; index < frameBytes; ++index) {
    body.push_back(static_cast<std::byte>(fill));
    fill = static_cast<std::uint8_t>(fill + 1U);
  }
  BuiltBlock block;
  block.bytes = element(kSimpleBlockId, body);
  const auto prefix =
      static_cast<std::uint64_t>(block.bytes.size() - body.size());
  block.frameOffset = prefix + payloadStart;
  block.frameSize = frameBytes;
  return block;
}

// A laced AAC SimpleBlock carrying `frameCount` access units of `frameBytes`
// each, fixed lacing (the shape FFmpeg writes least often but the cheapest to
// build; the cursor's per-sample arithmetic is identical for every lacing).
BuiltBlock buildFixedLacedBlock(std::uint64_t track, std::int16_t relative,
                                std::uint16_t frameCount,
                                std::size_t frameBytes, std::uint8_t& fill) {
  Bytes body{
      static_cast<std::byte>(0x80U | track),
      static_cast<std::byte>(
          (static_cast<std::uint16_t>(relative) >> 8U) & 0xFFU),
      static_cast<std::byte>(static_cast<std::uint16_t>(relative) & 0xFFU),
      static_cast<std::byte>(0x80U | 0x04U)};
  body.push_back(static_cast<std::byte>(frameCount - 1U));
  const std::size_t payloadStart = body.size();
  for (std::size_t index = 0; index < frameBytes * frameCount; ++index) {
    body.push_back(static_cast<std::byte>(fill));
    fill = static_cast<std::uint8_t>(fill + 1U);
  }
  BuiltBlock block;
  block.bytes = element(kSimpleBlockId, body);
  const auto prefix =
      static_cast<std::uint64_t>(block.bytes.size() - body.size());
  block.frameOffset = prefix + payloadStart;
  block.frameSize = frameBytes;
  return block;
}

struct CuePointSpec {
  std::uint64_t time{0};
  std::uint64_t track{kVideoTrackNumber};
  std::uint64_t clusterPosition{0};
  std::uint64_t relativePosition{0};
};

Bytes cuesElement(const std::vector<CuePointSpec>& points) {
  Bytes payload;
  for (const CuePointSpec& point : points) {
    Bytes positions;
    append(positions, uintElement(kCueTrackId, point.track));
    append(positions,
           uintElement(kCueClusterPositionId, point.clusterPosition));
    append(positions,
           uintElement(kCueRelativePositionId, point.relativePosition));
    append(positions, uintElement(kCueBlockNumberId, 1));
    Bytes cuePoint = uintElement(kCueTimeId, point.time);
    append(cuePoint, element(kCueTrackPositionsId, positions));
    append(payload, element(kCuePointId, cuePoint));
  }
  return element(kCuesId, payload);
}

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

struct Document {
  Bytes bytes;
  std::uint64_t clusterCount{0};
  std::uint64_t cueCount{0};
  std::uint64_t videoBlockCount{0};
  std::uint64_t durationTicks{0};
  // Absolute frame ranges of every video frame, in file order.
  std::vector<FrameRange> videoFrames;
};

struct DocumentSpec {
  std::size_t clusterCount{64};
  // Video blocks per cluster; block 0 of every cluster is the random access
  // point that the cue names.
  std::size_t videoBlocksPerCluster{1};
  std::size_t videoFrameBytes{8};
  // Every nth cluster gets a cue (1 = one cue per cluster).
  std::size_t cueStride{1};
  bool includeAudio{false};
  // Audio access units per laced Block; one Block per cluster boundary group.
  std::uint16_t audioFramesPerBlock{4};
  std::size_t audioFrameBytes{8};
  std::uint64_t clusterSpacingTicks{40};
};

Document buildDocument(const DocumentSpec& spec) {
  std::uint8_t fill = 1;
  Document document;
  document.clusterCount = spec.clusterCount;

  const std::uint64_t frameSpacing =
      spec.videoBlocksPerCluster == 0
          ? spec.clusterSpacingTicks
          : std::max<std::uint64_t>(
                1U, spec.clusterSpacingTicks / spec.videoBlocksPerCluster);

  Bytes infoPayload;
  append(infoPayload,
         uintElement(kTimestampScaleId, kTimestampScaleNanoseconds));
  const auto durationTicks =
      static_cast<std::uint64_t>(spec.clusterCount) * spec.clusterSpacingTicks +
      spec.clusterSpacingTicks;
  document.durationTicks = durationTicks;
  append(infoPayload,
         doubleElement(kDurationId, static_cast<double>(durationTicks)));

  Bytes trackEntries = videoTrackEntry();
  if (spec.includeAudio) {
    append(trackEntries, audioTrackEntry());
  }

  Bytes segmentPayload = element(kInfoId, infoPayload);
  append(segmentPayload, element(kTracksId, trackEntries));

  // Audio AUs are placed on the exact grid, then routed into whichever cluster
  // covers their tick, exactly as the demuxer test's fixture does.
  std::uint64_t audioOrdinal = 0;

  std::vector<CuePointSpec> cuePoints;
  cuePoints.reserve(spec.clusterCount / std::max<std::size_t>(1, spec.cueStride)
                    + 1U);

  struct PendingFrame {
    std::uint64_t clusterRelative{0};
    std::uint64_t blockRelative{0};
    std::uint64_t size{0};
    std::size_t clusterIndex{0};
  };
  std::vector<PendingFrame> pendingFrames;

  std::vector<std::uint64_t> clusterRelativeOffsets;
  clusterRelativeOffsets.reserve(spec.clusterCount);

  for (std::size_t index = 0; index < spec.clusterCount; ++index) {
    const std::uint64_t clusterTick =
        static_cast<std::uint64_t>(index) * spec.clusterSpacingTicks;
    Bytes clusterPayload = uintElement(kClusterTimestampId, clusterTick);

    std::uint64_t randomAccessRelative = 0;
    for (std::size_t block = 0; block < spec.videoBlocksPerCluster; ++block) {
      const auto relative =
          static_cast<std::int16_t>(block * frameSpacing);
      BuiltBlock built = buildSimpleBlock(kVideoTrackNumber, relative,
                                          block == 0, spec.videoFrameBytes,
                                          fill);
      const auto at = static_cast<std::uint64_t>(clusterPayload.size());
      if (block == 0) {
        randomAccessRelative = at;
      }
      pendingFrames.push_back(
          {at + built.frameOffset, 0, built.frameSize, index});
      append(clusterPayload, built.bytes);
      ++document.videoBlockCount;
    }

    if (spec.includeAudio) {
      // Emit every AAC access unit whose exact grid tick falls inside this
      // cluster's span, laced audioFramesPerBlock at a time.
      const std::uint64_t clusterEndTick =
          clusterTick + spec.clusterSpacingTicks;
      while (true) {
        const auto tick = nearestMatroskaTick(
            {MediaTime{0, 1}, audioOrdinal, kAudioSampleRate},
            kTimestampScaleNanoseconds);
        if (!tick || static_cast<std::uint64_t>(*tick) >= clusterEndTick ||
            static_cast<std::uint64_t>(*tick) >= durationTicks) {
          break;
        }
        const auto relative = static_cast<std::int16_t>(
            static_cast<std::int64_t>(*tick) -
            static_cast<std::int64_t>(clusterTick));
        BuiltBlock built = buildFixedLacedBlock(
            kAudioTrackNumber, relative, spec.audioFramesPerBlock,
            spec.audioFrameBytes, fill);
        append(clusterPayload, built.bytes);
        audioOrdinal += spec.audioFramesPerBlock;
      }
    }

    const Bytes cluster = element(kClusterId, clusterPayload);
    const auto clusterDataOffset =
        static_cast<std::uint64_t>(cluster.size() - clusterPayload.size());
    const auto clusterRelative =
        static_cast<std::uint64_t>(segmentPayload.size());
    clusterRelativeOffsets.push_back(clusterRelative);

    for (PendingFrame& frame : pendingFrames) {
      if (frame.clusterIndex == index && frame.blockRelative == 0) {
        frame.blockRelative = clusterRelative + clusterDataOffset;
      }
    }

    if (spec.cueStride != 0 && index % spec.cueStride == 0) {
      CuePointSpec point;
      point.time = clusterTick;
      point.track = kVideoTrackNumber;
      point.clusterPosition = clusterRelative;
      point.relativePosition = randomAccessRelative;
      cuePoints.push_back(point);
    }
    append(segmentPayload, cluster);
  }
  document.cueCount = cuePoints.size();
  append(segmentPayload, cuesElement(cuePoints));

  document.bytes = ebmlHeader();
  const Bytes segmentElement = element(kSegmentId, segmentPayload);
  const auto segmentPrefix =
      static_cast<std::uint64_t>(segmentElement.size() - segmentPayload.size());
  const auto segmentDataOffset =
      static_cast<std::uint64_t>(document.bytes.size()) + segmentPrefix;
  append(document.bytes, segmentElement);

  document.videoFrames.reserve(pendingFrames.size());
  for (const PendingFrame& frame : pendingFrames) {
    document.videoFrames.push_back(FrameRange{
        ByteRange{segmentDataOffset + frame.blockRelative + frame.clusterRelative,
                  frame.size}});
  }
  return document;
}

// ---------------------------------------------------------------------------
// Readers
// ---------------------------------------------------------------------------

class MemoryReader final : public SeekableByteReader {
 public:
  explicit MemoryReader(const Bytes* bytes) noexcept : bytes_(bytes) {}

  [[nodiscard]] std::uint64_t size() const noexcept override {
    return static_cast<std::uint64_t>(bytes_->size());
  }

  [[nodiscard]] bool readAt(std::uint64_t offset,
                            std::span<std::byte> destination) noexcept override {
    if (offset > bytes_->size() ||
        destination.size() > bytes_->size() - offset) {
      return false;
    }
    std::memcpy(destination.data(), bytes_->data() + offset,
                destination.size());
    return true;
  }

 private:
  const Bytes* bytes_;
};

// ---------------------------------------------------------------------------
// Timing
// ---------------------------------------------------------------------------

using Clock = std::chrono::steady_clock;

struct Row {
  const char* phase;
  std::string regime;
  double nanosecondsPerOperation{0.0};
  double itemsPerSecond{0.0};
  const char* itemUnit{""};
  std::string note;
};

std::vector<Row> rows;

void emit(const char* phase, std::string regime, double nanosecondsPerOperation,
          double itemsPerSecond, const char* itemUnit, std::string note = {}) {
  rows.push_back({phase, std::move(regime), nanosecondsPerOperation,
                  itemsPerSecond, itemUnit, std::move(note)});
}

// Runs `body` until at least `minimumNanoseconds` of wall time has elapsed and
// at least `minimumIterations` completed, then reports the best (minimum) mean
// over `repeats` independent batches. Minimum-of-means is the right estimator
// here: the subject is deterministic, so every deviation upward is measurement
// noise from the machine, not from the code.
template <typename Body>
double measure(Body&& body, std::size_t minimumIterations = 3,
               double minimumNanoseconds = 30'000'000.0,
               int repeats = 3) {
  double best = 0.0;
  for (int repeat = 0; repeat < repeats; ++repeat) {
    std::size_t iterations = 0;
    const auto start = Clock::now();
    double elapsed = 0.0;
    while (true) {
      body();
      ++iterations;
      elapsed = std::chrono::duration<double, std::nano>(Clock::now() - start)
                    .count();
      if (iterations >= minimumIterations && elapsed >= minimumNanoseconds) {
        break;
      }
    }
    const double mean = elapsed / static_cast<double>(iterations);
    if (best == 0.0 || mean < best) {
      best = mean;
    }
  }
  return best;
}

std::string regimeName(std::size_t count, const char* unit) {
  char buffer[64];
  if (count >= 1000 && count % 1000 == 0) {
    std::snprintf(buffer, sizeof(buffer), "%zuk %s", count / 1000, unit);
  } else {
    std::snprintf(buffer, sizeof(buffer), "%zu %s", count, unit);
  }
  return buffer;
}

MediaSourceOpenOptions defaultOptions() {
  MediaSourceOpenOptions options;
  options.selection.requireVideo = true;
  options.selection.requireAudio = false;
  return options;
}

// ---------------------------------------------------------------------------
// Phase 1: prepare() vs cluster count
// ---------------------------------------------------------------------------

struct PreparedDocument {
  Document document;
  std::shared_ptr<const MatroskaPreparedAsset> asset;
  std::shared_ptr<MemoryReader> reader;
};

std::shared_ptr<const MatroskaPreparedAsset> prepareOnce(
    const Document& document, std::shared_ptr<MemoryReader> reader) {
  MatroskaPrepareOutcome outcome = prepareMatroska(
      std::move(reader), std::filesystem::path("/bench/synthetic.mkv"),
      defaultOptions(), {});
  if (outcome.status != MatroskaDemuxStatus::Ready) {
    std::fprintf(stderr,
                 "BENCH: prepare failed (status=%d error=%d msg=%s) for a "
                 "%llu-cluster document\n",
                 static_cast<int>(outcome.status),
                 static_cast<int>(outcome.error), outcome.message.c_str(),
                 static_cast<unsigned long long>(document.clusterCount));
    ++failures;
  }
  return outcome.asset;
}

void benchPrepare(const std::vector<std::size_t>& clusterCounts) {
  for (const std::size_t clusters : clusterCounts) {
    DocumentSpec spec;
    spec.clusterCount = clusters;
    spec.videoBlocksPerCluster = 1;
    spec.cueStride = 1;
    const Document document = buildDocument(spec);

    // Prove the document is admissible before timing it.
    {
      auto reader = std::make_shared<MemoryReader>(&document.bytes);
      const auto asset = prepareOnce(document, reader);
      require(asset != nullptr, "prepare produced no asset");
      if (asset != nullptr) {
        require(asset->clusters().size() == clusters,
                "cluster directory size mismatch");
        require(asset->cues().size() == clusters, "cue index size mismatch");
      }
    }

    const double nanoseconds = measure(
        [&document] {
          auto reader = std::make_shared<MemoryReader>(&document.bytes);
          MatroskaPrepareOutcome outcome = prepareMatroska(
              std::move(reader), std::filesystem::path("/bench/synthetic.mkv"),
              defaultOptions(), {});
          if (outcome.status != MatroskaDemuxStatus::Ready) {
            ++failures;
          }
        },
        1, clusters >= 8192 ? 200'000'000.0 : 50'000'000.0, 3);

    char note[96];
    std::snprintf(note, sizeof(note), "%.2f MiB document",
                  static_cast<double>(document.bytes.size()) / (1024.0 * 1024.0));
    emit("prepare", regimeName(clusters, "clusters"), nanoseconds,
         static_cast<double>(clusters) / (nanoseconds / 1e9), "clusters/s",
         note);
  }
}

// ---------------------------------------------------------------------------
// Phase 2: planGeneration vs cue count and target position
// ---------------------------------------------------------------------------

void benchPlanGeneration(const std::vector<std::size_t>& clusterCounts) {
  for (const std::size_t clusters : clusterCounts) {
    DocumentSpec spec;
    spec.clusterCount = clusters;
    spec.videoBlocksPerCluster = 1;
    spec.cueStride = 1;
    const Document document = buildDocument(spec);
    auto reader = std::make_shared<MemoryReader>(&document.bytes);
    const auto asset = prepareOnce(document, reader);
    if (asset == nullptr) {
      continue;
    }

    struct TargetCase {
      const char* name;
      double fraction;
    };
    const std::array<TargetCase, 3> cases{
        TargetCase{"target 0%", 0.0}, TargetCase{"target 50%", 0.5},
        TargetCase{"target 99%", 0.99}};

    for (const TargetCase& target : cases) {
      // Targets are exact millisecond rationals so no double ever enters the
      // demuxer's comparison chain from this side.
      const auto tick = static_cast<std::int64_t>(
          static_cast<double>(document.durationTicks) * target.fraction);
      const MediaTime value{tick, 1000};

      const MatroskaPlanOutcome probe =
          asset->planGeneration(value, MediaSeekMode::Accurate, {});
      if (probe.status != MatroskaDemuxStatus::Ready) {
        std::fprintf(stderr,
                     "BENCH: planGeneration %s failed at %zu cues (error=%d "
                     "msg=%s)\n",
                     target.name, clusters, static_cast<int>(probe.error),
                     probe.message.c_str());
        ++failures;
        continue;
      }

      const double nanoseconds = measure(
          [&asset, value] {
            const MatroskaPlanOutcome outcome =
                asset->planGeneration(value, MediaSeekMode::Accurate, {});
            if (outcome.status != MatroskaDemuxStatus::Ready) {
              ++failures;
            }
          },
          16, 30'000'000.0, 3);

      std::string regime = regimeName(clusters, "cues");
      regime += ", ";
      regime += target.name;
      emit("planGeneration", std::move(regime), nanoseconds, 0.0, "");
    }
  }
}

// ---------------------------------------------------------------------------
// Phase 3: cursor readNext throughput
// ---------------------------------------------------------------------------

void benchCursorReadNext() {
  struct Case {
    const char* name;
    std::size_t clusters;
    std::size_t blocksPerCluster;
    bool audio;
  };
  const std::array<Case, 5> cases{
      Case{"small: 64 clusters x 1 block", 64, 1, false},
      Case{"medium: 1k clusters x 1 block", 1000, 1, false},
      Case{"transition: 64 clusters x 25 blocks", 64, 25, false},
      Case{"large: 8k clusters x 1 block", 8000, 1, false},
      Case{"audio: 64 clusters x 25 blocks + AAC", 64, 25, true}};

  for (const Case& item : cases) {
    DocumentSpec spec;
    spec.clusterCount = item.clusters;
    spec.videoBlocksPerCluster = item.blocksPerCluster;
    spec.cueStride = 1;
    spec.includeAudio = item.audio;
    spec.clusterSpacingTicks = item.blocksPerCluster > 1 ? 1000 : 40;
    const Document document = buildDocument(spec);
    auto reader = std::make_shared<MemoryReader>(&document.bytes);
    const auto asset = prepareOnce(document, reader);
    if (asset == nullptr) {
      continue;
    }
    const MatroskaPlanOutcome plan =
        asset->planGeneration(MediaTime{0, 1000}, MediaSeekMode::Accurate, {});
    if (plan.status != MatroskaDemuxStatus::Ready) {
      std::fprintf(stderr, "BENCH: readNext plan failed for %s (error=%d %s)\n",
                   item.name, static_cast<int>(plan.error),
                   plan.message.c_str());
      ++failures;
      continue;
    }

    const auto drain = [&asset, &plan](bool video) -> std::size_t {
      auto cursor = video ? asset->makeVideoCursor(*plan.plan)
                          : asset->makeAudioCursor(*plan.plan);
      if (cursor == nullptr) {
        return 0;
      }
      std::size_t samples = 0;
      while (true) {
        MatroskaCursorReadResult result = cursor->readNext({});
        if (std::holds_alternative<MatroskaCompressedSample>(result)) {
          ++samples;
          continue;
        }
        if (!std::holds_alternative<MatroskaCursorEnd>(result)) {
          ++failures;
        }
        break;
      }
      return samples;
    };

    const std::size_t videoSamples = drain(true);
    require(videoSamples > 0, "video cursor produced no samples");

    const double nanoseconds =
        measure([&drain] { (void)drain(true); }, 1, 40'000'000.0, 3);
    const double perSample =
        nanoseconds / static_cast<double>(std::max<std::size_t>(1, videoSamples));
    char note[96];
    std::snprintf(note, sizeof(note), "%zu samples/pass", videoSamples);
    emit("cursor readNext (video)", item.name, perSample,
         1e9 / perSample, "samples/s", note);

    if (item.audio) {
      const std::size_t audioSamples = drain(false);
      require(audioSamples > 0, "audio cursor produced no samples");
      const double audioNanoseconds =
          measure([&drain] { (void)drain(false); }, 1, 40'000'000.0, 3);
      const double audioPerSample =
          audioNanoseconds /
          static_cast<double>(std::max<std::size_t>(1, audioSamples));
      std::snprintf(note, sizeof(note), "%zu samples/pass", audioSamples);
      emit("cursor readNext (AAC)", item.name, audioPerSample,
           1e9 / audioPerSample, "samples/s", note);
    }
  }
}

// ---------------------------------------------------------------------------
// Phase 4: copyRanges throughput vs range size
// ---------------------------------------------------------------------------

void benchCopyRanges(bool realFile) {
  struct Case {
    const char* name;
    std::size_t frameBytes;
  };
  const std::array<Case, 3> cases{Case{"1 KiB", 1024},
                                  Case{"64 KiB", 64U * 1024U},
                                  Case{"1 MiB", 1024U * 1024U}};

  for (const Case& item : cases) {
    DocumentSpec spec;
    spec.clusterCount = 16;
    spec.videoBlocksPerCluster = 1;
    spec.videoFrameBytes = item.frameBytes;
    spec.cueStride = 1;
    const Document document = buildDocument(spec);

    std::shared_ptr<SeekableByteReader> reader;
    std::filesystem::path path("/bench/synthetic.mkv");
    std::filesystem::path temporary;
    std::shared_ptr<const MatroskaPreparedAsset> asset;
    if (realFile) {
      temporary = std::filesystem::temp_directory_path() /
                  ("wam_bench_copyranges.mkv");
      const int descriptor =
          ::open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
      if (descriptor < 0) {
        ++failures;
        continue;
      }
      const ssize_t written =
          ::write(descriptor, document.bytes.data(), document.bytes.size());
      ::close(descriptor);
      if (written != static_cast<ssize_t>(document.bytes.size())) {
        ++failures;
        std::filesystem::remove(temporary);
        continue;
      }
      MatroskaPrepareOutcome outcome =
          prepareMatroskaLocalFile(temporary, defaultOptions(), {});
      if (outcome.status != MatroskaDemuxStatus::Ready) {
        ++failures;
        std::filesystem::remove(temporary);
        continue;
      }
      asset = outcome.asset;
    } else {
      auto memory = std::make_shared<MemoryReader>(&document.bytes);
      asset = prepareOnce(document, memory);
      reader = memory;
    }
    if (asset == nullptr) {
      continue;
    }

    std::vector<std::byte> destination(item.frameBytes);
    const std::array<FrameRange, 1> ranges{document.videoFrames.front()};
    MatroskaDemuxError error = MatroskaDemuxError::None;
    require(asset->copyRanges(ranges, destination, {}, &error),
            "copyRanges rejected a valid single-frame request");

    const double nanoseconds = measure(
        [&asset, &ranges, &destination] {
          if (!asset->copyRanges(ranges, destination, {}, nullptr)) {
            ++failures;
          }
        },
        64, 30'000'000.0, 3);

    const double bytesPerSecond =
        static_cast<double>(item.frameBytes) / (nanoseconds / 1e9);
    char note[128];
    std::snprintf(note, sizeof(note), "%.2f GiB/s, %zu x 64 KiB chunks",
                  bytesPerSecond / (1024.0 * 1024.0 * 1024.0),
                  (item.frameBytes + 65535U) / 65536U);
    emit(realFile ? "copyRanges (real file)" : "copyRanges (memory)",
         item.name, nanoseconds, bytesPerSecond, "B/s", note);

    if (realFile && !temporary.empty()) {
      asset.reset();
      std::error_code ignored;
      std::filesystem::remove(temporary, ignored);
    }
  }
}

// ---------------------------------------------------------------------------
// Phase 5: per-sample staging costs at the CoreMedia boundary
// ---------------------------------------------------------------------------
//
// The Matroska sample factory (matroska_media_source.mm) is Objective-C++ and
// links CoreMedia, so it cannot be exercised from this pure-C++ target. What
// the factory does per sample that is NOT CoreMedia's own cost is measurable
// here in isolation:
//   1. one std::make_shared<std::vector<std::byte>> storage token, and
//   2. the payload copy into that token's buffer via copyRanges.
// Phase 4 already prices (2); this phase prices (1) so the doc's
// "measured-acceptable" verdict on the token carries a number.

void benchStagingToken() {
  struct Case {
    const char* name;
    std::size_t bytes;
  };
  // Real 1080p H.264 sizes: an AAC AU is a few hundred bytes, a P/B frame a
  // few KiB, an IDR a few hundred KiB.
  const std::array<Case, 3> cases{Case{"AAC AU (384 B)", 384},
                                  Case{"P frame (8 KiB)", 8U * 1024U},
                                  Case{"IDR (256 KiB)", 256U * 1024U}};

  for (const Case& item : cases) {
    std::shared_ptr<std::vector<std::byte>> sink;
    const double nanoseconds = measure(
        [&item, &sink] {
          auto token = std::make_shared<std::vector<std::byte>>(item.bytes);
          // Touch the first byte so the allocation cannot be elided and the
          // first page fault is inside the measurement, as it is in production.
          (*token)[0] = std::byte{1};
          sink = std::move(token);
        },
        1024, 30'000'000.0, 3);
    emit("staging token (make_shared)", item.name, nanoseconds,
         1e9 / nanoseconds, "tokens/s");
  }

  // A fixed pool of reused tokens is the alternative the performance doc
  // sketches. Price the same workload with the allocation removed so the
  // decision has both numbers.
  {
    constexpr std::size_t kPoolSize = 8;
    std::array<std::shared_ptr<std::vector<std::byte>>, kPoolSize> pool;
    for (auto& slot : pool) {
      slot = std::make_shared<std::vector<std::byte>>(256U * 1024U);
    }
    std::size_t cursor = 0;
    const double nanoseconds = measure(
        [&pool, &cursor] {
          auto& token = pool[cursor % kPoolSize];
          ++cursor;
          token->resize(8U * 1024U);
          (*token)[0] = std::byte{1};
        },
        1024, 30'000'000.0, 3);
    emit("staging token (pooled reuse)", "P frame (8 KiB)", nanoseconds,
         1e9 / nanoseconds, "tokens/s", "no allocation");
  }
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

void report() {
  std::printf("\n");
  std::printf("WAM Matroska demuxer regime microbenchmarks\n");
  std::printf("%-30s %-34s %14s %16s  %s\n", "phase", "regime", "ns/op",
              "items/s", "note");
  std::printf(
      "------------------------------ ---------------------------------- "
      "-------------- ----------------  ----\n");
  for (const Row& row : rows) {
    char items[32];
    if (row.itemsPerSecond > 0.0) {
      std::snprintf(items, sizeof(items), "%.3g %s", row.itemsPerSecond,
                    row.itemUnit);
    } else {
      std::snprintf(items, sizeof(items), "%s", "-");
    }
    std::printf("%-30s %-34s %14.1f %16s  %s\n", row.phase, row.regime.c_str(),
                row.nanosecondsPerOperation, items, row.note.c_str());
  }
  std::printf("\n");
}

}  // namespace

int main(int argc, char** argv) {
  // A single mid regime is enough for the Debug/Release ratio measurement, and
  // a Debug build of the 65k-cluster case is minutes long.
  bool quick = false;
  for (int index = 1; index < argc; ++index) {
    if (std::string_view(argv[index]) == "--quick") {
      quick = true;
    }
  }

  const std::vector<std::size_t> clusterCounts =
      quick ? std::vector<std::size_t>{1000}
            : std::vector<std::size_t>{64, 1000, 8000, 65536};

  benchPrepare(clusterCounts);
  benchPlanGeneration(clusterCounts);
  if (!quick) {
    benchCursorReadNext();
    benchCopyRanges(false);
    benchCopyRanges(true);
    benchStagingToken();
  } else {
    benchCopyRanges(false);
  }

  report();
  if (failures != 0) {
    std::fprintf(stderr, "%d benchmark precondition failure(s)\n", failures);
    return 1;
  }
  return 0;
}
