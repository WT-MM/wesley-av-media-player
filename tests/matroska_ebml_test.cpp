#include "media/matroska_ebml.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fcntl.h>
#include <iostream>
#include <limits>
#include <span>
#include <string>
#include <string_view>
#include <type_traits>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {

using namespace wam::media::matroska;
using Bytes = std::vector<std::byte>;

static_assert(!std::is_default_constructible_v<SegmentChild>);
static_assert(std::is_copy_constructible_v<SegmentChild>);
static_assert(!std::is_copy_assignable_v<SegmentChild>);
static_assert(!std::is_copy_constructible_v<SegmentChildCursor>);
static_assert(std::is_nothrow_move_constructible_v<SegmentChildCursor>);
static_assert(!std::is_copy_constructible_v<ClusterChildCursor>);
static_assert(std::is_nothrow_move_constructible_v<ClusterChildCursor>);

int failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

void append(Bytes& destination, std::span<const std::byte> source) {
  destination.insert(destination.end(), source.begin(), source.end());
}

void append(Bytes& destination, const Bytes& source) {
  append(destination, std::span<const std::byte>(source));
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
    bytes.push_back(static_cast<std::byte>((id >> ((index - 1U) * 8U)) &
                                           0xFFU));
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
  const auto encoded = (std::uint64_t{1} << (7U * width)) | size;
  for (unsigned index = width; index > 0; --index) {
    bytes.push_back(static_cast<std::byte>(
        (encoded >> ((index - 1U) * 8U)) & 0xFFU));
  }
}

Bytes element(std::uint32_t id, const Bytes& payload) {
  Bytes result;
  appendId(result, id);
  appendSize(result, payload.size());
  append(result, payload);
  return result;
}

Bytes unknownElement(std::uint32_t id, const Bytes& payload) {
  Bytes result;
  appendId(result, id);
  result.push_back(std::byte{0xFF});
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
    result.push_back(static_cast<std::byte>(
        (value >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return result;
}

Bytes signedBytes(std::int64_t value, unsigned width = 1) {
  const auto bits = std::bit_cast<std::uint64_t>(value);
  Bytes result;
  for (unsigned index = width; index > 0; --index) {
    result.push_back(static_cast<std::byte>(
        (bits >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return result;
}

Bytes uintElement(std::uint32_t id, std::uint64_t value) {
  return element(id, unsignedBytes(value));
}

Bytes signedElement(std::uint32_t id, std::int64_t value,
                    unsigned width = 1) {
  return element(id, signedBytes(value, width));
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
    payload.push_back(static_cast<std::byte>(
        (bits >> ((index - 1U) * 8U)) & 0xFFU));
  }
  return element(id, payload);
}

Bytes ebmlHeader(std::uint64_t ebmlVersion = 1,
                 std::uint64_t ebmlReadVersion = 1,
                 std::uint64_t maximumSizeLength = 8,
                 std::uint64_t docTypeVersion = 4,
                 std::uint64_t docTypeReadVersion = 4,
                 std::string_view docType = "matroska") {
  Bytes payload;
  append(payload, uintElement(0x4286, ebmlVersion));
  append(payload, uintElement(0x42F7, ebmlReadVersion));
  append(payload, uintElement(0x42F2, 4));
  append(payload, uintElement(0x42F3, maximumSizeLength));
  append(payload, asciiElement(0x4282, docType));
  append(payload, uintElement(0x4287, docTypeVersion));
  append(payload, uintElement(0x4285, docTypeReadVersion));
  return element(0x1A45DFA3, payload);
}

Bytes info(bool duplicateScale = false) {
  Bytes payload;
  append(payload, uintElement(0x2AD7B1, 1'000'000));
  if (duplicateScale) {
    append(payload, uintElement(0x2AD7B1, 2'000'000));
  }
  append(payload, doubleElement(0x4489, 120.5));
  return element(0x1549A966, payload);
}

Bytes videoTrack(bool duplicateNumber = false,
                 std::size_t codecPrivateBytes = 4,
                 std::optional<bool> lacingAllowed = std::nullopt,
                 std::uint64_t number = 1, std::uint64_t uid = 99,
                 std::optional<std::int64_t> trackOffset = std::nullopt) {
  Bytes videoPayload;
  append(videoPayload, uintElement(0xB0, 64));
  append(videoPayload, uintElement(0xBA, 36));
  append(videoPayload, uintElement(0x9A, 2));
  Bytes colourPayload;
  append(colourPayload, uintElement(0x55B1, 1));
  append(colourPayload, uintElement(0x55BA, 1));
  append(colourPayload, uintElement(0x55BB, 1));
  append(videoPayload, element(0x55B0, colourPayload));

  Bytes payload;
  append(payload, uintElement(0xD7, number));
  if (duplicateNumber) {
    append(payload, uintElement(0xD7, 2));
  }
  append(payload, uintElement(0x73C5, uid));
  append(payload, uintElement(0x83, 1));
  append(payload, asciiElement(0x86, "V_MPEGH/ISO/HEVC"));
  append(payload, asciiElement(0x22B59C, "eng"));
  if (lacingAllowed) {
    append(payload, uintElement(0x9C, *lacingAllowed ? 1 : 0));
  }
  if (trackOffset) {
    append(payload, signedElement(0x537F, *trackOffset));
  }
  append(payload, element(0x63A2, Bytes(codecPrivateBytes, std::byte{0x01})));
  append(payload, element(0xE0, videoPayload));
  return element(0xAE, payload);
}

Bytes tracks(bool duplicateNumber = false,
             std::size_t codecPrivateBytes = 4,
             std::optional<bool> lacingAllowed = std::nullopt) {
  return element(0x1654AE6B,
                 videoTrack(duplicateNumber, codecPrivateBytes,
                            lacingAllowed));
}

Bytes blockPayload(std::uint8_t flags, const Bytes& laceAndFrames,
                   std::int16_t timestamp = 0,
                   std::uint8_t trackNumber = 1) {
  Bytes payload{static_cast<std::byte>(0x80U | trackNumber),
                static_cast<std::byte>((static_cast<std::uint16_t>(timestamp) >>
                                        8U) &
                                       0xFFU),
                static_cast<std::byte>(static_cast<std::uint16_t>(timestamp) &
                                       0xFFU),
                static_cast<std::byte>(flags)};
  append(payload, laceAndFrames);
  return payload;
}

Bytes simpleBlock(std::uint8_t flags, const Bytes& laceAndFrames,
                  std::int16_t timestamp = 0) {
  return element(0xA3, blockPayload(flags, laceAndFrames, timestamp));
}

Bytes cues(std::uint64_t clusterPosition,
           std::uint64_t simpleRelativePosition,
           std::optional<std::uint64_t> codecStatePosition = std::nullopt) {
  Bytes trackPosition;
  append(trackPosition, uintElement(0xF7, 1));
  append(trackPosition, uintElement(0xF1, clusterPosition));
  append(trackPosition, uintElement(0xF0, simpleRelativePosition));
  append(trackPosition, uintElement(0x5378, 1));
  if (codecStatePosition) {
    append(trackPosition, uintElement(0xEA, *codecStatePosition));
  }
  Bytes point;
  append(point, element(0xB7, trackPosition));  // Exercise CueTime-last order.
  append(point, uintElement(0xB3, 7));
  return element(0x1C53BB6B, element(0xBB, point));
}

Bytes document(Bytes segmentPayload, bool unknownSegment = false) {
  Bytes result = ebmlHeader();
  append(result, unknownSegment ? unknownElement(0x18538067, segmentPayload)
                                : element(0x18538067, segmentPayload));
  return result;
}

class MemoryReader final : public SeekableByteReader {
 public:
  explicit MemoryReader(Bytes bytes) : bytes_(std::move(bytes)) {}

  [[nodiscard]] std::uint64_t size() const noexcept override {
    return bytes_.size();
  }

  [[nodiscard]] bool
  readAt(std::uint64_t offset,
         std::span<std::byte> destination) noexcept override {
    ++reads;
    maximumRead = std::max(maximumRead, destination.size());
    totalRead += destination.size();
    readOffsets.push_back(offset);
    readSizes.push_back(destination.size());
    if (offset > bytes_.size() || destination.size() > bytes_.size() - offset) {
      return false;
    }
    std::copy_n(bytes_.begin() + static_cast<std::ptrdiff_t>(offset),
                destination.size(), destination.begin());
    if (cancelAfterRead != nullptr) {
      cancelAfterRead->store(true, std::memory_order_release);
    }
    return true;
  }

  Bytes bytes_;
  std::size_t reads{0};
  std::size_t maximumRead{0};
  std::size_t totalRead{0};
  std::vector<std::uint64_t> readOffsets;
  std::vector<std::size_t> readSizes;
  std::atomic<bool>* cancelAfterRead{nullptr};
};

class WindowReader final : public SeekableByteReader {
 public:
  WindowReader(std::uint64_t size, std::uint64_t base, Bytes bytes)
      : size_(size), base_(base), bytes_(std::move(bytes)) {}

  [[nodiscard]] std::uint64_t size() const noexcept override { return size_; }
  [[nodiscard]] bool
  readAt(std::uint64_t offset,
         std::span<std::byte> destination) noexcept override {
    if (offset < base_ || offset - base_ > bytes_.size() ||
        destination.size() > bytes_.size() - (offset - base_)) {
      return false;
    }
    std::copy_n(bytes_.begin() +
                    static_cast<std::ptrdiff_t>(offset - base_),
                destination.size(), destination.begin());
    return true;
  }

 private:
  std::uint64_t size_{0};
  std::uint64_t base_{0};
  Bytes bytes_;
};

bool atomicCancellation(const void* context) noexcept {
  return static_cast<const std::atomic<bool>*>(context)->load(
      std::memory_order_acquire);
}

class RecordingVisitor final : public Visitor {
 public:
  VisitorAction onEbmlHeader(const EbmlHeader& header) noexcept override {
    ++headers;
    ebml = header;
    return nextAction;
  }
  VisitorAction onSegment(const SegmentInfo& value) noexcept override {
    ++segments;
    segment = value;
    segmentValues.push_back(value);
    return nextAction;
  }
  VisitorAction onSeekEntry(const SeekEntry& value) noexcept override {
    seeks.push_back(value);
    return nextAction;
  }
  VisitorAction onInfo(const Info& value) noexcept override {
    ++infos;
    parsedInfo = value;
    return nextAction;
  }
  VisitorAction onTrackEntry(const TrackEntry& value) noexcept override {
    ++tracks;
    track = value;
    return nextAction;
  }
  VisitorAction onCluster(const Cluster& value) noexcept override {
    ++clusters;
    cluster = value;
    return nextAction;
  }
  VisitorAction onBlock(
      const BlockHeader& header, std::span<const FrameRange> frames,
      const BlockGroupFields& fields,
      std::span<const std::int64_t> references) noexcept override {
    ++blocks;
    blockHeaders.push_back(header);
    std::vector<std::uint64_t> sizes;
    for (const auto frame : frames) sizes.push_back(frame.bytes.size);
    frameSizes.push_back(std::move(sizes));
    groupFields.push_back(fields);
    referenceValues.emplace_back(references.begin(), references.end());
    return nextAction;
  }
  VisitorAction
  onCueTrackPosition(const CueTrackPosition& value) noexcept override {
    cuePositions.push_back(value);
    return nextAction;
  }
  VisitorAction onChapterFeatures(
      const ChapterFeatures& value) noexcept override {
    chapters = value;
    return nextAction;
  }
  VisitorAction onDocumentSummary(
      const DocumentSummary& value) noexcept override {
    summary = value;
    return nextAction;
  }

  VisitorAction nextAction{VisitorAction::Continue};
  int headers{0};
  int segments{0};
  int infos{0};
  int tracks{0};
  int clusters{0};
  int blocks{0};
  EbmlHeader ebml;
  SegmentInfo segment;
  Info parsedInfo;
  TrackEntry track;
  Cluster cluster;
  ChapterFeatures chapters;
  DocumentSummary summary;
  std::vector<SeekEntry> seeks;
  std::vector<SegmentInfo> segmentValues;
  std::vector<BlockHeader> blockHeaders;
  std::vector<std::vector<std::uint64_t>> frameSizes;
  std::vector<BlockGroupFields> groupFields;
  std::vector<std::vector<std::int64_t>> referenceValues;
  std::vector<CueTrackPosition> cuePositions;
};

class CancelOnHeaderVisitor final : public Visitor {
 public:
  explicit CancelOnHeaderVisitor(std::atomic<bool>& cancelled) noexcept
      : cancelled_(cancelled) {}
  VisitorAction onEbmlHeader(const EbmlHeader&) noexcept override {
    cancelled_.store(true, std::memory_order_release);
    return VisitorAction::Continue;
  }

 private:
  std::atomic<bool>& cancelled_;
};

class GrowFileVisitor final : public Visitor {
 public:
  explicit GrowFileVisitor(const char* path) noexcept : path_(path) {}
  VisitorAction onInfo(const Info&) noexcept override {
    const int descriptor = ::open(path_, O_WRONLY | O_APPEND);
    if (descriptor >= 0) {
      const std::byte byte{0};
      static_cast<void>(::write(descriptor, &byte, 1));
      static_cast<void>(::close(descriptor));
    }
    return VisitorAction::Continue;
  }

 private:
  const char* path_{nullptr};
};

void testVints() {
  const std::array validId{std::byte{0x1A}, std::byte{0x45},
                           std::byte{0xDF}, std::byte{0xA3}};
  const auto id = decodeVint(validId, VintKind::ElementId);
  expect(id.status == VintStatus::Ready && id.vint.value == 0x1A45DFA3 &&
             id.vint.width == 4,
         "four-byte EBML ID decodes exactly");
  const std::array legalMatroska80{std::byte{0x80}};
  expect(decodeVint(legalMatroska80, VintKind::ElementId).status ==
             VintStatus::Ready,
         "Matroska's one-byte 0x80 ID exception is accepted");
  const std::array invalidZero{std::byte{0x00}};
  expect(decodeVint(invalidZero, VintKind::ElementSize).status ==
             VintStatus::Invalid,
         "zero lead byte is not a VINT");
  const std::array shortInput{std::byte{0x40}};
  expect(decodeVint(shortInput, VintKind::ElementSize).status ==
             VintStatus::NeedMoreBytes,
         "truncated multi-byte VINT requests more bytes");
  const std::array unknown{std::byte{0xFF}};
  const auto unknownSize = decodeVint(unknown, VintKind::ElementSize);
  expect(unknownSize.status == VintStatus::Ready && unknownSize.vint.unknown,
         "all-one size VINT is explicitly unknown");
  const std::array overlongId{std::byte{0x40}, std::byte{0x01}};
  expect(decodeVint(overlongId, VintKind::ElementId).status ==
             VintStatus::Invalid,
         "non-shortest element ID is rejected");
  const std::array signedZero{std::byte{0xBF}};
  const auto zero = decodeVint(signedZero, VintKind::SignedLacingValue);
  expect(zero.status == VintStatus::Ready && zero.vint.signedValue == 0,
         "signed EBML lace bias decodes zero exactly");
}

void expectLayout(const Bytes& payload, bool simple, Lacing lacing,
                  std::initializer_list<std::uint64_t> sizes,
                  const char* message) {
  MemoryReader reader(payload);
  const auto result =
      parseBlockLayout(reader, {0, payload.size()}, simple);
  bool matches = result.outcome.status == ParseStatus::Complete &&
                 result.layout && result.layout->header.lacing == lacing &&
                 result.layout->frameCount == sizes.size();
  if (matches) {
    std::size_t index = 0;
    for (const auto expected : sizes) {
      matches &= result.layout->frames[index++].bytes.size == expected;
    }
  }
  expect(matches, message);
}

void testLacing() {
  expectLayout(blockPayload(0, Bytes(9, std::byte{1})), false, Lacing::None,
               {9}, "no-lacing exposes one exact frame range");

  Bytes xiph{std::byte{0x02}, std::byte{0xFF}, std::byte{0xFF},
             std::byte{0xFF}, std::byte{0x23}, std::byte{0xFF},
             std::byte{0xF5}};
  append(xiph, Bytes(2'300, std::byte{1}));
  expectLayout(blockPayload(0x02, xiph), true, Lacing::Xiph,
               {800, 500, 1'000}, "Xiph lacing decodes exact example sizes");

  Bytes ebml{std::byte{0x02}, std::byte{0x43}, std::byte{0x20},
             std::byte{0x5E}, std::byte{0xD3}};
  append(ebml, Bytes(2'300, std::byte{2}));
  expectLayout(blockPayload(0x06, ebml), false, Lacing::Ebml,
               {800, 500, 1'000}, "EBML lacing decodes signed deltas exactly");

  Bytes overCapEbml{std::byte{0x01}, std::byte{0x8A}};
  append(overCapEbml, Bytes(11, std::byte{2}));
  const auto overCapEbmlBlock = blockPayload(0x06, overCapEbml);
  MemoryReader overCapEbmlReader(overCapEbmlBlock);
  ParseOptions overCapEbmlOptions;
  overCapEbmlOptions.maximumBlockBytes = 9;
  expect(parseBlockLayout(overCapEbmlReader,
                          {0, overCapEbmlReader.size()}, false,
                          overCapEbmlOptions)
             .outcome.error == ParseError::BlockLimit,
         "oversized first EBML-laced frame reports the payload limit");

  Bytes fixed{std::byte{0x02}};
  append(fixed, Bytes(12, std::byte{3}));
  expectLayout(blockPayload(0x04, fixed), false, Lacing::Fixed, {4, 4, 4},
               "fixed lacing divides the remaining bytes exactly");

  MemoryReader badFixed(blockPayload(
      0x04, Bytes{std::byte{0x02}, std::byte{1}, std::byte{2}, std::byte{3},
                  std::byte{4}}));
  expect(parseBlockLayout(badFixed, {0, badFixed.size()}, false)
             .outcome.status == ParseStatus::Invalid,
         "fixed lacing rejects a non-divisible payload");

  MemoryReader oneFrame(
      blockPayload(0x02, Bytes{std::byte{0x00}, std::byte{1}}));
  expect(parseBlockLayout(oneFrame, {0, oneFrame.size()}, false)
             .outcome.status == ParseStatus::LimitExceeded,
         "lacing cannot encode a single frame");

  const auto missingLaceCount = blockPayload(0x02, {});
  Bytes adjacentBytes = missingLaceCount;
  adjacentBytes.push_back(std::byte{0x01});
  MemoryReader adjacentReader(std::move(adjacentBytes));
  const auto adjacentResult = parseBlockLayout(
      adjacentReader, {0, missingLaceCount.size()}, false);
  expect(adjacentResult.outcome.error == ParseError::Truncated,
         "lace count cannot be borrowed from the next element");

  MemoryReader xiphOverflow(blockPayload(
      0x02, Bytes{std::byte{0x01}, std::byte{0xFF}, std::byte{0xFF}}));
  expect(parseBlockLayout(xiphOverflow, {0, xiphOverflow.size()}, false)
             .outcome.status == ParseStatus::Invalid,
         "truncated Xiph size cannot consume frame data");

  MemoryReader ebmlUnderflow(blockPayload(
      0x06, Bytes{std::byte{0x02}, std::byte{0x81}, std::byte{0x80},
                  std::byte{1}, std::byte{2}}));
  expect(parseBlockLayout(ebmlUnderflow, {0, ebmlUnderflow.size()}, false)
             .outcome.status == ParseStatus::Invalid,
         "negative EBML lace delta cannot make a zero frame");

  Bytes maximumFixed{std::byte{0xFF}};
  append(maximumFixed, Bytes(256, std::byte{7}));
  const auto maximumBlock = blockPayload(0x04, maximumFixed);
  MemoryReader maximumReader(maximumBlock);
  const auto maximumResult = parseBlockLayout(
      maximumReader, {0, maximumReader.size()}, false);
  expect(maximumResult.outcome.status == ParseStatus::Complete &&
             maximumResult.layout && maximumResult.layout->frameCount == 256 &&
             maximumResult.layout->frames[255].bytes.size == 1,
         "one-byte lace count reaches the exact 256-frame ceiling");
  MemoryReader tightenedReader(maximumBlock);
  ParseOptions tightened;
  tightened.maximumLaceFrames = 255;
  expect(parseBlockLayout(tightenedReader, {0, tightenedReader.size()}, false,
                          tightened)
             .outcome.status == ParseStatus::LimitExceeded,
         "tightened lace-frame ceiling rejects 256 before frame retention");

  Bytes boundedFixed{std::byte{0x01}};
  append(boundedFixed, Bytes(16, std::byte{0x22}));
  const auto boundedFixedBlock = blockPayload(0x04, boundedFixed);
  ParseOptions perFrame;
  perFrame.maximumBlockBytes = 8;
  perFrame.maximumEncodedBlockBytes = boundedFixedBlock.size();
  MemoryReader boundedFixedReader(boundedFixedBlock);
  const auto perFrameAccepted = parseBlockLayout(
      boundedFixedReader, {0, boundedFixedReader.size()}, false, perFrame);
  expect(perFrameAccepted.outcome.status == ParseStatus::Complete &&
             perFrameAccepted.layout &&
             perFrameAccepted.layout->frameCount == 2 &&
             perFrameAccepted.layout->frames[0].bytes.size == 8 &&
             perFrameAccepted.layout->frames[1].bytes.size == 8,
         "aggregate laced Block may exceed a cap when each frame is exact-cap");

  Bytes overPerFrameFixed{std::byte{0x01}};
  append(overPerFrameFixed, Bytes(18, std::byte{0x23}));
  const auto overPerFrameBlock = blockPayload(0x04, overPerFrameFixed);
  perFrame.maximumEncodedBlockBytes = overPerFrameBlock.size();
  MemoryReader overPerFrameReader(overPerFrameBlock);
  expect(parseBlockLayout(overPerFrameReader,
                          {0, overPerFrameReader.size()}, false, perFrame)
             .outcome.error == ParseError::BlockLimit,
         "one oversized laced frame fails the per-frame cap");

  ParseOptions structural = perFrame;
  structural.maximumBlockBytes = 64;
  structural.maximumEncodedBlockBytes = overPerFrameBlock.size() - 1U;
  MemoryReader structuralReader(overPerFrameBlock);
  expect(parseBlockLayout(structuralReader,
                          {0, structuralReader.size()}, false, structural)
             .outcome.error == ParseError::BlockLimit,
         "aggregate encoded Block obeys the distinct structural cap");
}

Bytes completeDocument(bool unknownCluster = false) {
  Bytes segment;
  const auto infoBytes = info();
  const auto trackBytes = tracks();
  append(segment, infoBytes);
  append(segment, trackBytes);
  const auto timestamp = uintElement(0xE7, 7);
  const auto simple =
      simpleBlock(0x80, Bytes{std::byte{1}, std::byte{2}, std::byte{3}}, 2);
  Bytes clusterPayload = timestamp;
  append(clusterPayload, simple);
  Bytes group;
  append(group, signedElement(0xFB, -1));
  append(group, element(0xA4, Bytes{std::byte{9}}));
  append(group, element(0x75A1, {}));
  append(group, uintElement(0x9B, 10));
  append(group,
         element(0xA1, blockPayload(0, Bytes{std::byte{4}, std::byte{5}}, 4)));
  append(clusterPayload, element(0xA0, group));
  const auto cluster = unknownCluster
                           ? unknownElement(0x1F43B675, clusterPayload)
                           : element(0x1F43B675, clusterPayload);
  const auto clusterPosition = segment.size();
  append(segment, cluster);
  append(segment, cues(clusterPosition, timestamp.size()));
  return document(segment);
}

void testFullStructure() {
  MemoryReader reader(completeDocument());
  RecordingVisitor visitor;
  ParseOptions options;
  options.visitClusterBlocks = true;
  const auto result = parseDocument(reader, visitor, options);
  expect(result.status == ParseStatus::Complete && result.documents == 1 &&
             result.segments == 1,
         "complete structural Matroska document parses");
  expect(visitor.headers == 1 && visitor.segments == 1 && visitor.infos == 1 &&
             visitor.tracks == 1 && visitor.clusters == 1 &&
             visitor.blocks == 2,
         "visitor receives header, metadata, cluster, and both block forms");
  expect(visitor.track.number == 1 && visitor.track.video &&
             visitor.track.codecPrivate &&
             std::string(visitor.track.codecId.view().begin(),
                         visitor.track.codecId.view().end()) ==
                 "V_MPEGH/ISO/HEVC",
         "track callback preserves HEVC identity and bounded private range");
  expect(visitor.cluster.timestamp == 7 && visitor.frameSizes.size() == 2 &&
             visitor.frameSizes[0] == std::vector<std::uint64_t>{3} &&
             visitor.frameSizes[1] == std::vector<std::uint64_t>{2},
         "cluster timing and frame byte ranges remain exact");
  expect(visitor.groupFields[1].duration == 10 &&
             visitor.groupFields[1].codecState &&
             visitor.groupFields[1].blockAdditionsPresent &&
             visitor.referenceValues[1] == std::vector<std::int64_t>{-1},
         "BlockGroup order-independent metadata is emitted with its block");
  expect(visitor.cuePositions.size() == 1 &&
             visitor.cuePositions[0].absoluteBlockOffset &&
             *visitor.cuePositions[0].absoluteBlockOffset ==
                 visitor.blockHeaders[0].elementData.offset - 2,
         "cue relative position is resolved only when explicitly present");
  expect(visitor.summary.documentCount == 1 &&
             !visitor.summary.trailingDocumentsPresent,
         "single-document summary is explicit");
  expect(reader.maximumRead <= ParseOptions::kHardMaximumReadBytes,
         "all structural reads stay under 64 KiB");

  MemoryReader byteReader(completeDocument());
  RecordingVisitor byteVisitor;
  ParseOptions byteOptions = options;
  byteOptions.maximumReadBytes = 1;
  expect(parseDocument(byteReader, byteVisitor, byteOptions).status ==
                 ParseStatus::Complete &&
             byteReader.maximumRead == 1 && byteVisitor.blocks == 2,
         "exact structural reads honor a caller one-byte read ceiling");
}

void testTargetedSeekHead() {
  Bytes seekPayload;
  append(seekPayload, element(0x53AB,
                              Bytes{std::byte{0x15}, std::byte{0x49},
                                    std::byte{0xA9}, std::byte{0x66}}));
  append(seekPayload, uintElement(0x53AC, 80));
  const auto seekHead = element(0x114D9B74, element(0x4DBB, seekPayload));
  Bytes bytes = seekHead;
  bytes.resize(80, std::byte{0});
  const auto target = info();
  append(bytes, target);
  MemoryReader reader(bytes);
  RecordingVisitor visitor;
  const auto result = parseMasterAt(reader, 0, bytes.size(), 0,
                                    MasterKind::SeekHead, visitor);
  expect(result.status == ParseStatus::Complete && visitor.seeks.size() == 1 &&
             visitor.seeks[0].targetId == 0x1549A966 &&
             visitor.seeks[0].absoluteTargetOffset == 80 &&
             visitor.seeks[0].targetEncoded ==
                 ByteRange{80, target.size()},
         "targeted SeekHead parsing exposes a checked cold-open jump");
}

void testUnknownSizesAndDocuments() {
  MemoryReader clusterReader(completeDocument(true));
  RecordingVisitor clusterVisitor;
  ParseOptions options;
  options.visitClusterBlocks = true;
  const auto clusterResult =
      parseDocument(clusterReader, clusterVisitor, options);
  expect(clusterResult.status == ParseStatus::Complete &&
             clusterVisitor.cluster.unknownSize &&
             clusterVisitor.cuePositions.size() == 1,
         "unknown Cluster terminates at a schema-valid top-level sibling");

  Bytes firstPayload = info();
  Bytes bytes = document(firstPayload, true);
  append(bytes, document(info()));
  MemoryReader documents(std::move(bytes));
  RecordingVisitor visitor;
  const auto result = parseDocument(documents, visitor);
  expect(result.status == ParseStatus::Complete && result.documents == 2 &&
             result.segments == 2 && visitor.summary.trailingDocumentsPresent,
         "unknown Segment ends at the next EBML document and surfaces it");
  expect(visitor.segmentValues.size() == 2 &&
             visitor.segmentValues[0].unknownSize &&
             visitor.segmentValues[0].encoded.offset +
                     visitor.segmentValues[0].encoded.size ==
                 visitor.segmentValues[1].encoded.offset -
                     ebmlHeader().size(),
         "unknown Segment callback publishes its schema-derived end, not EOF");

  Bytes badSegment;
  append(badSegment, unknownElement(0x1549A966,
                                    uintElement(0x2AD7B1, 1'000'000)));
  MemoryReader badInfo(document(badSegment));
  RecordingVisitor ignored;
  const auto bad = parseDocument(badInfo, ignored);
  expect(bad.error == ParseError::UnknownSizeNotAllowed,
         "unknown size is rejected for non-schema master Info");
}

void testTrackAndTargetProofs() {
  {
    Bytes segment = info();
    append(segment, tracks(false, 4, false));
    Bytes clusterPayload = uintElement(0xE7, 0);
    append(clusterPayload,
           simpleBlock(0x84,
                       Bytes{std::byte{0x01}, std::byte{1}, std::byte{2}}));
    append(segment, element(0x1F43B675, clusterPayload));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    ParseOptions options;
    options.visitClusterBlocks = true;
    expect(parseDocument(reader, visitor, options).error ==
               ParseError::InvalidValue,
           "FlagLacing zero rejects a laced block of that track");
  }
  {
    Bytes segment = info();
    append(segment, tracks());
    Bytes clusterPayload = uintElement(0xE7, 0);
    append(clusterPayload,
           element(0xA3, blockPayload(0x80, Bytes{std::byte{1}}, 0, 2)));
    append(segment, element(0x1F43B675, clusterPayload));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    ParseOptions options;
    options.visitClusterBlocks = true;
    expect(parseDocument(reader, visitor, options).error ==
               ParseError::InvalidValue,
           "every block TrackNumber must name a Segment TrackEntry");
  }
  {
    Bytes segment = info();
    Bytes clusterPayload = uintElement(0xE7, 0);
    append(clusterPayload,
           simpleBlock(0x80, Bytes{std::byte{1}}, 0));
    append(segment, element(0x1F43B675, clusterPayload));
    append(segment, tracks());  // Legal when discoverable through file order.
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    ParseOptions options;
    options.visitClusterBlocks = true;
    const auto result = parseDocument(reader, visitor, options);
    expect(result.status == ParseStatus::Complete && visitor.blocks == 1,
           "block constraints are pre-discovered when Tracks follows Cluster");
  }
  {
    const auto nestedInfo = info();
    const auto attachment = element(0x1941A469, nestedInfo);
    const auto nestedOffset = attachment.size() - nestedInfo.size();
    MemoryReader reader(attachment);
    RecordingVisitor visitor;
    const auto result = parseSegmentChildAt(
        reader, {0, attachment.size()}, nestedOffset, MasterKind::Info,
        visitor);
    expect(result.error == ParseError::ParentBoundary,
           "targeted Segment parsing rejects a nested forged master");
  }
  {
    const auto nestedInfo = info();
    const auto attachment = element(0x1941A469, nestedInfo);
    const auto attachmentHeader = attachment.size() - nestedInfo.size();
    const auto makeSeekHead = [](std::uint64_t position) {
      Bytes seek;
      append(seek, element(0x53AB,
                           Bytes{std::byte{0x15}, std::byte{0x49},
                                 std::byte{0xA9}, std::byte{0x66}}));
      append(seek, uintElement(0x53AC, position));
      return element(0x114D9B74, element(0x4DBB, seek));
    };
    Bytes seekHead = makeSeekHead(0);
    for (int iteration = 0; iteration < 3; ++iteration) {
      seekHead = makeSeekHead(seekHead.size() + attachmentHeader);
    }
    Bytes segment = seekHead;
    append(segment, attachment);
    append(segment, info());
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::ParentBoundary,
           "SeekPosition must name a direct Segment child, not nested bytes");
  }
  {
    Bytes clusterOnePayload = uintElement(0xE7, 0);
    const auto clusterOne = unknownElement(0x1F43B675, clusterOnePayload);
    Bytes clusterTwoPayload = uintElement(0xE7, 1);
    const auto timestampTwoBytes = clusterTwoPayload.size();
    append(clusterTwoPayload,
           simpleBlock(0x80, Bytes{std::byte{7}}, 0));
    const auto clusterTwo = element(0x1F43B675, clusterTwoPayload);

    Bytes segment = info();
    append(segment, tracks());
    const auto clusterOnePosition = segment.size();
    const auto clusterOneData = clusterOnePosition + 5U;
    append(segment, clusterOne);
    const auto clusterTwoPosition = segment.size();
    const auto clusterTwoData = clusterTwoPosition + 5U;
    const auto forgedRelative =
        clusterTwoData + timestampTwoBytes - clusterOneData;
    append(segment, clusterTwo);
    append(segment, cues(clusterOnePosition, forgedRelative));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::ParentBoundary,
           "unknown Cluster cue cannot escape to a later Cluster child");
  }
}

void testCueCodecStateProof() {
  const auto timestamp = uintElement(0xE7, 0);
  const auto codecState = element(0xA4, Bytes{std::byte{0x11}});
  Bytes groupPayload = codecState;
  append(groupPayload,
         element(0xA1, blockPayload(0, Bytes{std::byte{1}}, 0)));
  const auto group = element(0xA0, groupPayload);
  Bytes clusterPayload = timestamp;
  append(clusterPayload, group);
  const auto cluster = element(0x1F43B675, clusterPayload);

  Bytes segment = info();
  append(segment, tracks());
  const auto clusterPosition = segment.size();
  const auto clusterHeaderBytes = cluster.size() - clusterPayload.size();
  const auto groupHeaderBytes = group.size() - groupPayload.size();
  const auto codecStatePosition = clusterPosition + clusterHeaderBytes +
                                  timestamp.size() + groupHeaderBytes;
  append(segment, cluster);
  append(segment,
         cues(clusterPosition, timestamp.size(), codecStatePosition));
  MemoryReader reader(document(segment));
  RecordingVisitor visitor;
  const auto result = parseDocument(reader, visitor);
  expect(result.status == ParseStatus::Complete &&
             visitor.cuePositions.size() == 1 &&
             visitor.cuePositions[0].absoluteCodecStateOffset ==
                 visitor.segment.data.offset + codecStatePosition,
         "CueCodecState is published only after direct BlockGroup ancestry");

  for (const std::uint32_t forbidden : {0x1A45DFA3U, 0x18538067U}) {
    Bytes guardedSegment = info();
    append(guardedSegment, tracks());
    const auto guardedClusterPosition = guardedSegment.size();
    Bytes guardedClusterPayload = timestamp;
    append(guardedClusterPayload, element(forbidden, {}));
    const auto guardedGroupOffset = guardedClusterPayload.size();
    append(guardedClusterPayload, group);
    const auto guardedCluster =
        element(0x1F43B675, guardedClusterPayload);
    const auto guardedClusterHeaderBytes =
        guardedCluster.size() - guardedClusterPayload.size();
    const auto guardedCodecStatePosition =
        guardedClusterPosition + guardedClusterHeaderBytes +
        guardedGroupOffset + groupHeaderBytes;
    append(guardedSegment, guardedCluster);
    Bytes guardedCuePosition;
    append(guardedCuePosition, uintElement(0xF7, 1));
    append(guardedCuePosition,
           uintElement(0xF1, guardedClusterPosition));
    append(guardedCuePosition,
           uintElement(0xEA, guardedCodecStatePosition));
    Bytes guardedPoint = uintElement(0xB3, 0);
    append(guardedPoint, element(0xB7, guardedCuePosition));
    append(guardedSegment,
           element(0x1C53BB6B, element(0xBB, guardedPoint)));
    MemoryReader guardedReader(document(guardedSegment));
    RecordingVisitor guardedVisitor;
    expect(parseDocument(guardedReader, guardedVisitor).error ==
               ParseError::UnexpectedElement &&
               guardedVisitor.cuePositions.empty(),
           "CodecState-only Cue rejects nested top-level Cluster children");
  }

  MemoryReader cappedReader(document(segment));
  RecordingVisitor cappedVisitor;
  ParseOptions cappedOptions;
  cappedOptions.maximumCodecPrivateBytes = 0;
  expect(parseDocument(cappedReader, cappedVisitor, cappedOptions).error ==
             ParseError::BlockLimit,
         "CueCodecState obeys the codec-state byte cap");

  Bytes forgedSegment = info();
  append(forgedSegment, tracks());
  const auto forgedClusterPosition = forgedSegment.size();
  Bytes blockOnlyGroupPayload;
  append(blockOnlyGroupPayload,
         element(0xA1, blockPayload(0, Bytes{std::byte{1}}, 0)));
  const auto blockOnlyGroup = element(0xA0, blockOnlyGroupPayload);
  Bytes forgedClusterPayload = timestamp;
  append(forgedClusterPayload, blockOnlyGroup);
  append(forgedSegment, element(0x1F43B675, forgedClusterPayload));
  const auto tagsPosition = forgedSegment.size();
  const auto tags = element(0x1254C367, codecState);
  const auto tagsHeaderBytes = tags.size() - codecState.size();
  const auto forgedCodecStatePosition = tagsPosition + tagsHeaderBytes;
  append(forgedSegment, tags);
  append(forgedSegment,
         cues(forgedClusterPosition, timestamp.size(),
              forgedCodecStatePosition));
  MemoryReader forgedReader(document(forgedSegment));
  RecordingVisitor forgedVisitor;
  expect(parseDocument(forgedReader, forgedVisitor).error ==
             ParseError::ParentBoundary,
         "header-shaped CodecState outside a direct BlockGroup is untrusted");

  constexpr std::size_t alternatingCodecCount = 300;
  Bytes codecSegment = info();
  append(codecSegment, tracks());
  const auto codecClusterPosition = codecSegment.size();
  const auto codecTimestamp = uintElement(0xE7, 0);
  Bytes codecClusterPayload = codecTimestamp;
  std::vector<std::uint64_t> codecStatePositions;
  codecStatePositions.reserve(alternatingCodecCount);
  for (std::size_t index = 0; index < alternatingCodecCount; ++index) {
    const auto state = element(0xA4, Bytes{static_cast<std::byte>(index)});
    Bytes payload = state;
    append(payload,
           element(0xA1, blockPayload(0, Bytes{std::byte{1}}, 0)));
    const auto blockGroup = element(0xA0, payload);
    const auto groupHeaderWidth = blockGroup.size() - payload.size();
    codecStatePositions.push_back(codecClusterPayload.size() +
                                  groupHeaderWidth);
    append(codecClusterPayload, blockGroup);
  }
  const auto codecCluster = element(0x1F43B675, codecClusterPayload);
  // Correct the cluster-header width generically before publishing offsets.
  const auto codecClusterHeaderWidth =
      codecCluster.size() - codecClusterPayload.size();
  for (auto& position : codecStatePositions) {
    position += codecClusterPosition + codecClusterHeaderWidth;
  }
  append(codecSegment, codecCluster);
  Bytes codecCuesPayload;
  for (std::size_t index = 0; index < alternatingCodecCount; ++index) {
    const auto selected = index % 2 == 0
                              ? index / 2
                              : alternatingCodecCount - 1 - index / 2;
    Bytes trackPosition;
    append(trackPosition, uintElement(0xF7, 1));
    append(trackPosition, uintElement(0xF1, codecClusterPosition));
    append(trackPosition,
           uintElement(0xEA, codecStatePositions[selected]));
    Bytes point = uintElement(0xB3, index);
    append(point, element(0xB7, trackPosition));
    append(codecCuesPayload, element(0xBB, point));
  }
  append(codecSegment, element(0x1C53BB6B, codecCuesPayload));
  MemoryReader codecReader(document(codecSegment));
  RecordingVisitor codecVisitor;
  ParseOptions codecOptions;
  codecOptions.maximumElements = 12'000;
  const auto codecReads = codecReader.totalRead;
  const auto codecOutcome =
      parseDocument(codecReader, codecVisitor, codecOptions);
  bool codecFileOrder =
      codecVisitor.cuePositions.size() == alternatingCodecCount;
  for (std::size_t index = 0;
       codecFileOrder && index < codecVisitor.cuePositions.size(); ++index) {
    codecFileOrder = codecVisitor.cuePositions[index].cueTime == index;
  }
  expect(codecOutcome.status == ParseStatus::Complete &&
             codecFileOrder &&
             codecReader.totalRead - codecReads <
                 alternatingCodecCount * 1024U,
         "alternating backward CueCodecState offsets validate in sorted order");
}

void testSegmentChildCursor() {
  const auto infoBytes = info();
  const auto trackBytes = tracks();
  const auto timestamp = uintElement(0xE7, 5);
  Bytes unknownClusterPayload = timestamp;
  append(unknownClusterPayload,
         simpleBlock(0x80, Bytes{std::byte{7}}));
  const auto unknownCluster =
      unknownElement(0x1F43B675, unknownClusterPayload);
  const auto cueBytes = cues(infoBytes.size() + trackBytes.size(),
                             timestamp.size());
  Bytes segment = infoBytes;
  append(segment, trackBytes);
  append(segment, unknownCluster);
  append(segment, cueBytes);

  MemoryReader reader(segment);
  ParseOptions options;
  auto cursor = beginSegmentChildCursor(reader, {0, segment.size()}, options);
  expect(cursor.has_value(), "Segment child cursor initializes");
  if (!cursor) return;
  std::vector<SegmentChild> children;
  std::vector<MasterKind> kinds;
  while (!cursor->done()) {
    const auto expectedOffset = cursor->nextOffset();
    const auto readsBefore = reader.readOffsets.size();
    auto next = readNextSegmentChild(reader, *cursor, options);
    expect(next.outcome.status == ParseStatus::Complete && next.child &&
               next.child->encoded().offset == expectedOffset &&
               next.outcome.nextOffset == cursor->nextOffset(),
           "Segment directory returns exactly one direct child");
    expect(reader.readOffsets.size() > readsBefore &&
               reader.readOffsets[readsBefore] == expectedOffset,
           "Segment continuation starts at next child without prefix replay");
    if (!next.child) break;
    if (next.child->kind()) kinds.push_back(*next.child->kind());
    children.push_back(*next.child);
  }
  expect(cursor->done() &&
             kinds == std::vector<MasterKind>{MasterKind::Info,
                                               MasterKind::Tracks,
                                               MasterKind::Cluster,
                                               MasterKind::Cues} &&
             children.size() == 4 && children[2].unknownSize() &&
             children[2].encoded().size == unknownCluster.size(),
         "Segment directory schema-terminates an unknown Cluster at Cues");

  auto movedCursor = std::move(*cursor);
  const auto movedFrom = readNextSegmentChild(reader, *cursor, options);
  expect(movedFrom.outcome.error == ParseError::FileChanged,
         "moved-from Segment cursor loses its reader capability");
  auto freshCursor =
      beginSegmentChildCursor(reader, {0, segment.size()}, options);
  expect(freshCursor.has_value(), "fresh Segment cursor initializes");
  if (!freshCursor) return;
  const auto freshBudget = freshCursor->remainingElements();
  RecordingVisitor forgedVisitor;
  const auto forgedProof = parseSegmentChild(
      reader, *freshCursor, children[1], MasterKind::Tracks, forgedVisitor,
      options);
  expect(forgedProof.error == ParseError::UnexpectedElement &&
             freshCursor->remainingElements() == freshBudget,
         "Segment proof cannot be replayed through a fresh budget cursor");
  MemoryReader otherReader(segment);
  RecordingVisitor otherVisitor;
  expect(parseSegmentChild(otherReader, movedCursor, children[1],
                           MasterKind::Tracks, otherVisitor, options)
             .error == ParseError::FileChanged,
         "Segment proof is bound to its original reader identity");

  RecordingVisitor tracksVisitor;
  expect(parseSegmentChild(reader, movedCursor, children[1],
                           MasterKind::Tracks,
                           tracksVisitor, options)
                 .status == ParseStatus::Complete &&
             tracksVisitor.tracks == 1,
         "proven Segment child parses directly without ancestry replay");
  RecordingVisitor clusterVisitor;
  const auto parsedCluster = parseSegmentChild(
      reader, movedCursor, children[2], MasterKind::Cluster, clusterVisitor,
      options);
  expect(parsedCluster.status == ParseStatus::Complete &&
             parsedCluster.parsedRange == children[2].encoded() &&
             clusterVisitor.cluster.timestamp == 5,
         "targeted unknown Cluster retains effective range and timestamp");

  ParseOptions limitedOptions;
  limitedOptions.maximumElements = 2;
  auto limited =
      beginSegmentChildCursor(reader, {0, segment.size()}, limitedOptions);
  expect(limited.has_value(), "budgeted Segment cursor initializes");
  if (!limited) return;
  expect(readNextSegmentChild(reader, *limited, limitedOptions).outcome.ok() &&
             readNextSegmentChild(reader, *limited, limitedOptions).outcome.ok(),
         "Segment cursor consumes within cumulative element budget");
  const auto readsAtLimit = reader.reads;
  const auto exhausted = readNextSegmentChild(reader, *limited, limitedOptions);
  expect(exhausted.outcome.error == ParseError::ElementLimit &&
             limited->remainingElements() == 0 && reader.reads == readsAtLimit,
         "Segment cursor enforces cumulative budget without another read");

  auto phaseLimited =
      beginSegmentChildCursor(reader, {0, segment.size()}, limitedOptions);
  expect(phaseLimited.has_value(), "phase-budget Segment cursor initializes");
  if (!phaseLimited) return;
  auto oneChild = readNextSegmentChild(reader, *phaseLimited, limitedOptions);
  expect(oneChild.outcome.ok() && oneChild.child,
         "phase-budget cursor discovers one child");
  if (!oneChild.child) return;
  RecordingVisitor phaseVisitor;
  const auto phaseReads = reader.reads;
  const auto phaseExhausted = parseSegmentChild(
      reader, *phaseLimited, *oneChild.child, MasterKind::Info, phaseVisitor,
      limitedOptions);
  expect(phaseExhausted.error == ParseError::ElementLimit &&
             phaseLimited->remainingElements() == 0 &&
             reader.reads > phaseReads,
         "Segment discovery and targeted parse share one cumulative budget");

  auto cancelled =
      beginSegmentChildCursor(reader, {0, segment.size()}, options);
  expect(cancelled.has_value(), "cancelled Segment cursor initializes");
  if (!cancelled) return;
  std::atomic<bool> cancellation{true};
  const auto offsetBeforeCancel = cancelled->nextOffset();
  const auto cancelledStep = readNextSegmentChild(
      reader, *cancelled, options, {&cancellation, atomicCancellation});
  expect(cancelledStep.outcome.error == ParseError::Cancelled &&
             cancelled->nextOffset() == offsetBeforeCancel,
         "cancelled Segment step does not advance continuation state");
}

void testTwoPhaseCuesBeforeTracks() {
  const auto timestamp = uintElement(0xE7, 0);
  const auto oversized =
      simpleBlock(0x80, Bytes(4U * 1024U, std::byte{0x44}));
  Bytes clusterPayload = timestamp;
  append(clusterPayload, oversized);
  const auto cluster = element(0x1F43B675, clusterPayload);

  const auto infoBytes = info();
  const auto clusterPosition = infoBytes.size();
  const auto cueBytes = cues(clusterPosition, timestamp.size());
  const auto trackBytes = tracks();
  Bytes segment = infoBytes;
  append(segment, cluster);
  append(segment, cueBytes);  // Legal order: Cues precedes Tracks.
  append(segment, trackBytes);
  MemoryReader reader(segment);

  const auto cueClusterHeader =
      readElementHeader(reader, clusterPosition, segment.size());
  expect(cueClusterHeader.header.has_value(),
         "two-phase Cue Cluster header parses");
  if (!cueClusterHeader.header) return;
  const auto cueBlockOffset =
      cueClusterHeader.header->data.offset + timestamp.size();
  const auto cueBlockHeader =
      readElementHeader(reader, cueBlockOffset, segment.size());
  expect(cueBlockHeader.header.has_value(),
         "two-phase Cue Block header parses");
  if (!cueBlockHeader.header) return;
  const auto cueFrameStart = cueBlockHeader.header->data.offset + 4U;
  const auto cueFrameEnd = cueBlockHeader.header->data.offset +
                           cueBlockHeader.header->data.size;

  auto directory = beginSegmentChildCursor(reader, {0, segment.size()});
  expect(directory.has_value(), "two-phase Segment directory initializes");
  if (!directory) return;
  std::optional<SegmentChild> tracksChild;
  std::optional<SegmentChild> cuesChild;
  while (!directory->done()) {
    auto entry = readNextSegmentChild(reader, *directory);
    if (!entry.child) break;
    if (entry.child->kind() == MasterKind::Tracks) {
      tracksChild.emplace(*entry.child);
    } else if (entry.child->kind() == MasterKind::Cues) {
      cuesChild.emplace(*entry.child);
    }
  }
  expect(tracksChild.has_value() && cuesChild.has_value(),
         "two-phase directory locates Cues and later Tracks without payloads");
  if (!tracksChild || !cuesChild) return;

  RecordingVisitor trackVisitor;
  expect(parseSegmentChild(reader, *directory, *tracksChild,
                           MasterKind::Tracks,
                           trackVisitor)
                 .status == ParseStatus::Complete,
         "two-phase admission parses Tracks after directory discovery");

  const std::array unselected{
      TrackConstraint{1, true, false, 64}};
  ParseOptions unselectedOptions;
  unselectedOptions.maximumBlockBytes = 64;
  unselectedOptions.maximumEncodedBlockBytes = 8U * 1024U;
  unselectedOptions.trackConstraints = unselected;
  RecordingVisitor unselectedVisitor;
  const auto bytesBeforeUnselected = reader.totalRead;
  const auto readsBeforeUnselected = reader.readOffsets.size();
  const auto unselectedCue = parseSegmentChild(
      reader, *directory, *cuesChild, MasterKind::Cues, unselectedVisitor,
      unselectedOptions);
  expect(unselectedCue.status == ParseStatus::Complete &&
             unselectedVisitor.cuePositions.size() == 1 &&
             reader.totalRead - bytesBeforeUnselected <= 4U * 1024U &&
             reader.maximumRead <= 256U,
         "unselected oversized Cue target uses prefix-only validation");
  bool cuePayloadUntouched = true;
  for (auto index = readsBeforeUnselected;
       index < reader.readOffsets.size(); ++index) {
    const auto offset = reader.readOffsets[index];
    if (offset < cueFrameEnd &&
        offset + reader.readSizes[index] > cueFrameStart) {
      cuePayloadUntouched = false;
      break;
    }
  }
  expect(cuePayloadUntouched,
         "unselected Cue validation never reads a frame payload byte");

  const std::array selected{
      TrackConstraint{1, true, true, 64}};
  ParseOptions selectedOptions = unselectedOptions;
  selectedOptions.trackConstraints = selected;
  RecordingVisitor selectedVisitor;
  expect(parseSegmentChild(reader, *directory, *cuesChild, MasterKind::Cues,
                           selectedVisitor, selectedOptions)
                 .error == ParseError::BlockLimit,
         "selected Cue target applies its per-frame cap");

  const std::array wrongTrack{
      TrackConstraint{2, true, false, 64}};
  ParseOptions wrongTrackOptions = unselectedOptions;
  wrongTrackOptions.trackConstraints = wrongTrack;
  RecordingVisitor wrongTrackVisitor;
  expect(parseSegmentChild(reader, *directory, *cuesChild, MasterKind::Cues,
                           wrongTrackVisitor, wrongTrackOptions)
                 .error == ParseError::InvalidValue,
         "Cues-before-Tracks target requires membership in supplied tracks");

  const auto expectExactLacedCueCap = [](std::size_t frameBytes,
                                         const char* message) {
    Bytes fixed{std::byte{0x01}};
    append(fixed, Bytes(frameBytes * 2U, std::byte{0x5A}));
    const auto fixedBlock = simpleBlock(0x84, fixed);
    const auto fixedTimestamp = uintElement(0xE7, 0);
    Bytes fixedClusterPayload = fixedTimestamp;
    append(fixedClusterPayload, fixedBlock);
    const auto fixedCluster = element(0x1F43B675, fixedClusterPayload);
    const auto fixedInfo = info();
    Bytes fixedSegment = fixedInfo;
    append(fixedSegment, fixedCluster);
    append(fixedSegment,
           cues(fixedInfo.size(), fixedTimestamp.size()));
    append(fixedSegment, tracks());
    MemoryReader fixedReader(fixedSegment);
    const std::array constraints{
        TrackConstraint{1, true, true, frameBytes}};
    ParseOptions fixedOptions;
    fixedOptions.maximumBlockBytes = frameBytes;
    fixedOptions.maximumEncodedBlockBytes = fixedBlock.size();
    fixedOptions.trackConstraints = constraints;
    auto fixedDirectory = beginSegmentChildCursor(
        fixedReader, {0, fixedSegment.size()}, fixedOptions);
    if (!fixedDirectory) {
      expect(false, message);
      return;
    }
    std::optional<SegmentChild> fixedCues;
    while (!fixedDirectory->done()) {
      auto entry = readNextSegmentChild(
          fixedReader, *fixedDirectory, fixedOptions);
      if (!entry.child) break;
      if (entry.child->kind() == MasterKind::Cues) {
        fixedCues.emplace(*entry.child);
      }
    }
    if (!fixedCues) {
      expect(false, message);
      return;
    }
    const auto before = fixedReader.totalRead;
    RecordingVisitor fixedVisitor;
    const auto outcome = parseSegmentChild(
        fixedReader, *fixedDirectory, *fixedCues, MasterKind::Cues,
        fixedVisitor, fixedOptions);
    expect(outcome.status == ParseStatus::Complete &&
               fixedVisitor.cuePositions.size() == 1 &&
               fixedReader.maximumRead <= 256U &&
               fixedReader.totalRead - before <= 4U * 1024U,
           message);
  };
  expectExactLacedCueCap(
      wam::media::MediaSourceLimits::kHardMaximumVideoSampleBytes,
      "Cue accepts two exact 8 MiB video frames under a larger aggregate");
  expectExactLacedCueCap(
      wam::media::MediaSourceLimits::kHardMaximumAudioSampleBytes,
      "Cue accepts two exact 256 KiB audio frames under a larger aggregate");

  constexpr std::size_t manyCueCount = 128;
  const auto manyInfo = info();
  const auto manyTimestamp = uintElement(0xE7, 0);
  const auto manyBlock =
      simpleBlock(0x80, Bytes(128U * 1024U, std::byte{0x6B}));
  Bytes manyClusterPayload = manyTimestamp;
  append(manyClusterPayload, manyBlock);
  const auto manyCluster = element(0x1F43B675, manyClusterPayload);
  Bytes manyCuePayload;
  for (std::size_t index = 0; index < manyCueCount; ++index) {
    Bytes cuePosition;
    append(cuePosition, uintElement(0xF7, 1));
    append(cuePosition, uintElement(0xF1, manyInfo.size()));
    append(cuePosition, uintElement(0xF0, manyTimestamp.size()));
    Bytes cuePoint = uintElement(0xB3, index);
    append(cuePoint, element(0xB7, cuePosition));
    append(manyCuePayload, element(0xBB, cuePoint));
  }
  const auto manyCues = element(0x1C53BB6B, manyCuePayload);
  Bytes manySegment = manyInfo;
  append(manySegment, manyCluster);
  append(manySegment, manyCues);
  append(manySegment, tracks());
  append(manySegment, element(0x1254C367,
                              Bytes(128U * 1024U, std::byte{0x19})));
  MemoryReader manyReader(manySegment);
  ParseOptions manyOptions = unselectedOptions;
  manyOptions.maximumEncodedBlockBytes = 256U * 1024U;
  auto manyDirectory = beginSegmentChildCursor(
      manyReader, {0, manySegment.size()}, manyOptions);
  expect(manyDirectory.has_value(), "many-Cue directory initializes");
  if (!manyDirectory) return;
  std::optional<SegmentChild> manyCuesChild;
  while (!manyDirectory->done()) {
    auto entry = readNextSegmentChild(
        manyReader, *manyDirectory, manyOptions);
    if (!entry.child) break;
    if (entry.child->kind() == MasterKind::Cues) {
      manyCuesChild.emplace(*entry.child);
    }
  }
  expect(manyCuesChild.has_value(), "many-Cue directory locates Cues");
  if (!manyCuesChild) return;
  const auto manyClusterHeader = readElementHeader(
      manyReader, manyInfo.size(), manySegment.size());
  if (!manyClusterHeader.header) {
    expect(false, "many-Cue Cluster header parses");
    return;
  }
  const auto manyBlockOffset =
      manyClusterHeader.header->data.offset + manyTimestamp.size();
  const auto manyBlockHeader = readElementHeader(
      manyReader, manyBlockOffset, manySegment.size());
  if (!manyBlockHeader.header) {
    expect(false, "many-Cue Block header parses");
    return;
  }
  const auto manyFrameStart = manyBlockHeader.header->data.offset + 4U;
  const auto manyFrameEnd = manyBlockHeader.header->data.offset +
                            manyBlockHeader.header->data.size;
  const auto manyReadStart = manyReader.readOffsets.size();
  const auto manyBytesStart = manyReader.totalRead;
  RecordingVisitor manyVisitor;
  const auto manyOutcome = parseSegmentChild(
      manyReader, *manyDirectory, *manyCuesChild, MasterKind::Cues,
      manyVisitor, manyOptions);
  bool manyPayloadUntouched = true;
  for (auto index = manyReadStart;
       index < manyReader.readOffsets.size(); ++index) {
    const auto offset = manyReader.readOffsets[index];
    if (offset < manyFrameEnd &&
        offset + manyReader.readSizes[index] > manyFrameStart) {
      manyPayloadUntouched = false;
      break;
    }
  }
  expect(manyOutcome.status == ParseStatus::Complete &&
             manyVisitor.cuePositions.size() == manyCueCount &&
             manyReader.maximumRead <= 256U && manyPayloadUntouched &&
             manyReader.totalRead - manyBytesStart <=
                 manyCueCount * 512U + 4U * 1024U,
         "many unselected Cues stay linear without cache amplification");

  constexpr std::size_t alternatingClusterCount = 300;
  Bytes alternatingSegment = info();
  append(alternatingSegment, tracks());
  std::vector<std::uint64_t> alternatingPositions;
  std::vector<std::uint64_t> alternatingRelativePositions;
  alternatingPositions.reserve(alternatingClusterCount);
  alternatingRelativePositions.reserve(alternatingClusterCount);
  for (std::size_t index = 0; index < alternatingClusterCount; ++index) {
    const auto timestampElement = uintElement(0xE7, index);
    Bytes alternatingClusterPayload = timestampElement;
    append(alternatingClusterPayload,
           simpleBlock(0x80, Bytes{static_cast<std::byte>(index)}));
    alternatingPositions.push_back(alternatingSegment.size());
    alternatingRelativePositions.push_back(timestampElement.size());
    append(alternatingSegment,
           element(0x1F43B675, alternatingClusterPayload));
  }
  Bytes alternatingCuePayload;
  for (std::size_t index = 0; index < alternatingClusterCount; ++index) {
    const auto selectedIndex = index % 2 == 0
                                   ? index / 2
                                   : alternatingClusterCount - 1 - index / 2;
    Bytes cuePosition;
    append(cuePosition, uintElement(0xF7, 1));
    append(cuePosition,
           uintElement(0xF1, alternatingPositions[selectedIndex]));
    append(cuePosition,
           uintElement(0xF0,
                       alternatingRelativePositions[selectedIndex]));
    Bytes point = uintElement(0xB3, index);
    append(point, element(0xB7, cuePosition));
    append(alternatingCuePayload, element(0xBB, point));
  }
  const auto alternatingCues =
      element(0x1C53BB6B, alternatingCuePayload);
  const auto alternatingCuesOffset = alternatingSegment.size();
  append(alternatingSegment, alternatingCues);
  MemoryReader alternatingReader(alternatingSegment);
  ParseOptions alternatingOptions;
  alternatingOptions.maximumElements = 8'000;
  alternatingOptions.maximumEncodedBlockBytes = 1024;
  alternatingOptions.trackConstraints = unselected;
  auto alternatingDirectory = beginSegmentChildCursor(
      alternatingReader, {0, alternatingSegment.size()}, alternatingOptions);
  expect(alternatingDirectory.has_value(),
         "alternating-Cue directory initializes");
  if (!alternatingDirectory) return;
  std::optional<SegmentChild> alternatingCuesChild;
  while (!alternatingDirectory->done()) {
    auto entry = readNextSegmentChild(
        alternatingReader, *alternatingDirectory, alternatingOptions);
    if (!entry.child) break;
    if (entry.child->encoded().offset == alternatingCuesOffset) {
      alternatingCuesChild.emplace(*entry.child);
    }
  }
  expect(alternatingCuesChild.has_value(),
         "alternating-Cue directory locates Cues");
  if (!alternatingCuesChild) return;
  const auto alternatingReadStart = alternatingReader.totalRead;
  RecordingVisitor alternatingVisitor;
  const auto alternatingOutcome = parseSegmentChild(
      alternatingReader, *alternatingDirectory, *alternatingCuesChild,
      MasterKind::Cues, alternatingVisitor, alternatingOptions);
  expect(alternatingOutcome.status == ParseStatus::Complete &&
             alternatingVisitor.cuePositions.size() ==
                 alternatingClusterCount &&
             alternatingReader.totalRead - alternatingReadStart <
                 alternatingClusterCount * 512U,
         "alternating backward Cue clusters use one linear Segment directory");

  Bytes relativeSegment = info();
  append(relativeSegment, tracks());
  const auto relativeClusterPosition = relativeSegment.size();
  Bytes relativeClusterPayload = uintElement(0xE7, 0);
  std::vector<std::uint64_t> relativePositions;
  relativePositions.reserve(alternatingClusterCount);
  for (std::size_t index = 0; index < alternatingClusterCount; ++index) {
    relativePositions.push_back(relativeClusterPayload.size());
    append(relativeClusterPayload,
           simpleBlock(0x80, Bytes{static_cast<std::byte>(index)}));
  }
  append(relativeSegment, element(0x1F43B675, relativeClusterPayload));
  Bytes relativeCuePayload;
  for (std::size_t index = 0; index < alternatingClusterCount; ++index) {
    const auto selectedIndex = index % 2 == 0
                                   ? index / 2
                                   : alternatingClusterCount - 1 - index / 2;
    Bytes cuePosition;
    append(cuePosition, uintElement(0xF7, 1));
    append(cuePosition, uintElement(0xF1, relativeClusterPosition));
    append(cuePosition,
           uintElement(0xF0, relativePositions[selectedIndex]));
    Bytes point = uintElement(0xB3, index);
    append(point, element(0xB7, cuePosition));
    append(relativeCuePayload, element(0xBB, point));
  }
  append(relativeSegment, element(0x1C53BB6B, relativeCuePayload));
  MemoryReader relativeReader(document(relativeSegment));
  RecordingVisitor relativeVisitor;
  ParseOptions relativeOptions;
  relativeOptions.maximumElements = 10'000;
  relativeOptions.trackConstraints = unselected;
  const auto relativeReadStart = relativeReader.totalRead;
  const auto relativeOutcome =
      parseDocument(relativeReader, relativeVisitor, relativeOptions);
  bool fileOrderPreserved =
      relativeVisitor.cuePositions.size() == alternatingClusterCount;
  for (std::size_t index = 0;
       fileOrderPreserved && index < relativeVisitor.cuePositions.size();
       ++index) {
    fileOrderPreserved =
        relativeVisitor.cuePositions[index].cueTime == index;
  }
  expect(relativeOutcome.status == ParseStatus::Complete &&
             fileOrderPreserved &&
             relativeReader.totalRead - relativeReadStart <
                 alternatingClusterCount * 1024U,
         "alternating backward CueRelativePosition validates linearly and callbacks retain file order");
}

void testTargetedClusterCursor() {
  const auto timestamp = uintElement(0xE7, 9);
  const auto simple = simpleBlock(0x80, Bytes{std::byte{1}, std::byte{2}});
  Bytes payload = timestamp;
  append(payload, simple);
  const auto cluster = element(0x1F43B675, payload);
  MemoryReader reader(cluster);
  RecordingVisitor metadata;
  const auto metadataResult = parseMasterAt(
      reader, 0, cluster.size(), 0, MasterKind::Cluster, metadata);
  expect(metadataResult.status == ParseStatus::Complete &&
             metadataResult.parsedRange == ByteRange{0, cluster.size()} &&
             metadata.cluster.timestamp == 9 && metadata.blocks == 0,
         "targeted Cluster metadata exposes timestamp/range without blocks");

  const auto header = readElementHeader(reader, 0, cluster.size());
  expect(header.header.has_value(), "targeted Cluster fixture header parses");
  if (!header.header) return;
  const std::array constraints{
      TrackConstraint{1, true, true, 1024}};
  ParseOptions options;
  options.trackConstraints = constraints;
  RecordingVisitor blockVisitor;
  const auto metadataOffset = header.header->data.offset;
  auto cursor = beginClusterChildCursor(reader, header.header->data, options);
  expect(cursor.has_value(), "targeted Cluster cursor initializes");
  if (!cursor) return;
  MemoryReader otherReader(cluster);
  const auto originalOffset = cursor->nextOffset();
  const auto originalBudget = cursor->remainingElements();
  RecordingVisitor otherVisitor;
  const auto wrongReader = parseClusterChildAt(
      otherReader, *cursor, otherVisitor, options);
  expect(wrongReader.error == ParseError::FileChanged &&
             cursor->nextOffset() == originalOffset &&
             cursor->remainingElements() == originalBudget,
         "Cluster cursor is reader-bound and rejects without advancing");
  auto movedClusterCursor = std::move(*cursor);
  const auto movedFromCluster = parseClusterChildAt(
      reader, *cursor, blockVisitor, options);
  expect(movedFromCluster.error == ParseError::FileChanged,
         "moved-from Cluster cursor loses its reader capability");
  const auto metadataChild = parseClusterChildAt(
      reader, movedClusterCursor, blockVisitor, options);
  const auto childOffset = metadataOffset + timestamp.size();
  expect(metadataChild.status == ParseStatus::Complete &&
             metadataChild.parsedRange ==
                 ByteRange{metadataOffset, timestamp.size()} &&
             metadataChild.nextOffset == childOffset &&
             blockVisitor.blocks == 0,
         "Cluster cursor skips one metadata child and returns continuation");
  const auto childResult = parseClusterChildAt(
      reader, movedClusterCursor, blockVisitor, options);
  expect(childResult.status == ParseStatus::Complete &&
             childResult.parsedRange ==
                 ByteRange{childOffset, simple.size()} &&
             childResult.nextOffset == childOffset + simple.size() &&
             blockVisitor.blocks == 1 &&
             blockVisitor.blockHeaders[0].containerEncoded ==
                 ByteRange{childOffset, simple.size()} &&
             blockVisitor.blockHeaders[0].blockEncoded ==
                 ByteRange{childOffset, simple.size()},
         "capacity-one Cluster child seam returns exact consumed ranges");

  const auto atEnd = parseClusterChildAt(
      reader, movedClusterCursor, blockVisitor, options);
  expect(atEnd.status == ParseStatus::Complete && !atEnd.parsedRange &&
             atEnd.nextOffset == childOffset + simple.size() &&
             blockVisitor.blocks == 1,
         "Cluster continuation recognizes the exact end without I/O");
}

void testLinearClusterCursorAndSelectedCaps() {
  Bytes payload = uintElement(0xE7, 3);
  constexpr std::size_t metadataChildren = 64;
  for (std::size_t index = 0; index < metadataChildren; ++index) {
    append(payload, element(0xEC, Bytes{static_cast<std::byte>(index)}));
  }
  append(payload, simpleBlock(0x80, Bytes{std::byte{9}}));
  const auto cluster = element(0x1F43B675, payload);
  MemoryReader reader(cluster);
  const auto clusterHeader = readElementHeader(reader, 0, cluster.size());
  expect(clusterHeader.header.has_value(),
         "linear Cluster cursor fixture header parses");
  if (!clusterHeader.header) return;

  const std::array constraints{
      TrackConstraint{1, true, true, 1024}};
  ParseOptions options;
  options.trackConstraints = constraints;
  RecordingVisitor visitor;
  auto cursor =
      beginClusterChildCursor(reader, clusterHeader.header->data, options);
  expect(cursor.has_value(), "linear Cluster cursor initializes");
  if (!cursor) return;
  auto childOffset = cursor->nextOffset();
  const auto clusterEnd =
      childOffset + clusterHeader.header->data.size;
  std::size_t visited = 0;
  const auto bytesBeforeWalk = reader.totalRead;
  while (!cursor->done()) {
    const auto readsBefore = reader.readOffsets.size();
    const auto bytesBeforeStep = reader.totalRead;
    const auto result = parseClusterChildAt(
        reader, *cursor, visitor, options);
    expect(result.status == ParseStatus::Complete && result.parsedRange &&
               result.parsedRange->offset == childOffset &&
               result.nextOffset && *result.nextOffset > childOffset,
           "each Cluster cursor step consumes exactly one child");
    expect(reader.readOffsets.size() > readsBefore &&
               reader.readOffsets[readsBefore] == childOffset,
           "continuation starts at its proven child instead of rescanning");
    expect(reader.totalRead - bytesBeforeStep <= 256U,
           "one tiny Cluster child performs one bounded probe read");
    if (!result.nextOffset || *result.nextOffset <= childOffset) break;
    childOffset = *result.nextOffset;
    ++visited;
  }
  expect(cursor->done() && cursor->nextOffset() == clusterEnd &&
             visited == metadataChildren + 2U &&
             visitor.blocks == 1 && reader.maximumRead <= 256U &&
             reader.totalRead - bytesBeforeWalk <=
                 (metadataChildren + 2U) * 256U,
         "capacity-one Cluster pull is linear through metadata and one block");

  ParseOptions limitedOptions = options;
  limitedOptions.maximumElements = 3;
  auto limitedCursor =
      beginClusterChildCursor(reader, clusterHeader.header->data,
                              limitedOptions);
  expect(limitedCursor.has_value(), "budgeted Cluster cursor initializes");
  if (!limitedCursor) return;
  RecordingVisitor limitedVisitor;
  for (int index = 0; index < 3; ++index) {
    expect(parseClusterChildAt(reader, *limitedCursor, limitedVisitor,
                               limitedOptions)
                   .status == ParseStatus::Complete,
           "Cluster cursor consumes work within its cumulative budget");
  }
  const auto readsAtLimit = reader.reads;
  const auto exhausted = parseClusterChildAt(
      reader, *limitedCursor, limitedVisitor, limitedOptions);
  expect(exhausted.error == ParseError::ElementLimit &&
             limitedCursor->remainingElements() == 0 &&
             reader.reads == readsAtLimit,
         "Cluster cursor retains one cumulative element budget across calls");

  const auto timestamp = uintElement(0xE7, 0);
  const auto oversized = simpleBlock(
      0x80, Bytes(128U * 1024U, std::byte{0x55}));
  Bytes oversizedPayload = timestamp;
  append(oversizedPayload, oversized);
  const auto oversizedCluster = element(0x1F43B675, oversizedPayload);
  MemoryReader oversizedReader(oversizedCluster);
  const auto oversizedHeader =
      readElementHeader(oversizedReader, 0, oversizedCluster.size());
  expect(oversizedHeader.header.has_value(),
         "oversized unselected Block fixture header parses");
  if (!oversizedHeader.header) return;
  const auto blockOffset =
      oversizedHeader.header->data.offset + timestamp.size();
  const auto oversizedBlockHeader = readElementHeader(
      oversizedReader, blockOffset, oversizedCluster.size());
  expect(oversizedBlockHeader.header.has_value(),
         "oversized unselected Block header parses");
  if (!oversizedBlockHeader.header) return;
  const auto oversizedFrameStart =
      oversizedBlockHeader.header->data.offset + 4U;
  const auto oversizedFrameEnd = oversizedBlockHeader.header->data.offset +
                                 oversizedBlockHeader.header->data.size;

  const std::array unselectedConstraints{
      TrackConstraint{1, true, false, 64}};
  ParseOptions unselectedOptions;
  unselectedOptions.maximumBlockBytes = 64;
  unselectedOptions.maximumEncodedBlockBytes = 256U * 1024U;
  unselectedOptions.trackConstraints = unselectedConstraints;
  auto parseOversizedBlock = [&](const ParseOptions& parseOptions,
                                 RecordingVisitor& target,
                                 std::size_t* blockReadBytes = nullptr,
                                 std::size_t* firstBlockRead = nullptr) {
    auto token = beginClusterChildCursor(
        oversizedReader, oversizedHeader.header->data, parseOptions);
    if (!token) return ParseOutcome{};
    const auto metadata = parseClusterChildAt(
        oversizedReader, *token, target, parseOptions);
    if (metadata.status != ParseStatus::Complete) return metadata;
    const auto before = oversizedReader.totalRead;
    if (firstBlockRead != nullptr) {
      *firstBlockRead = oversizedReader.readOffsets.size();
    }
    auto result = parseClusterChildAt(
        oversizedReader, *token, target, parseOptions);
    if (blockReadBytes != nullptr) {
      *blockReadBytes = oversizedReader.totalRead - before;
    }
    return result;
  };
  RecordingVisitor unselectedVisitor;
  std::size_t unselectedBlockReadBytes = 0;
  std::size_t firstUnselectedBlockRead = 0;
  const auto unselected = parseOversizedBlock(
      unselectedOptions, unselectedVisitor, &unselectedBlockReadBytes,
      &firstUnselectedBlockRead);
  expect(unselected.status == ParseStatus::Complete &&
             unselected.nextOffset == blockOffset + oversized.size() &&
             unselectedVisitor.blocks == 0 &&
             unselectedBlockReadBytes <= 512U &&
             oversizedReader.maximumRead <= 256U,
         "unselected Block skips after a bounded prefix despite payload cap");
  bool unselectedPayloadUntouched = true;
  for (auto index = firstUnselectedBlockRead;
       index < oversizedReader.readOffsets.size(); ++index) {
    const auto offset = oversizedReader.readOffsets[index];
    if (offset < oversizedFrameEnd &&
        offset + oversizedReader.readSizes[index] > oversizedFrameStart) {
      unselectedPayloadUntouched = false;
      break;
    }
  }
  expect(unselectedPayloadUntouched,
         "unselected Cluster Block never reads a frame payload byte");

  const std::array selectedConstraints{
      TrackConstraint{1, true, true, 64}};
  ParseOptions selectedOptions = unselectedOptions;
  selectedOptions.trackConstraints = selectedConstraints;
  RecordingVisitor selectedVisitor;
  const auto selected =
      parseOversizedBlock(selectedOptions, selectedVisitor);
  expect(selected.error == ParseError::BlockLimit &&
             selectedVisitor.blocks == 0,
         "selected Block obeys its per-track payload cap");

  ParseOptions structuralOptions = unselectedOptions;
  structuralOptions.maximumEncodedBlockBytes = oversized.size() - 1U;
  RecordingVisitor structuralVisitor;
  const auto structural =
      parseOversizedBlock(structuralOptions, structuralVisitor);
  expect(structural.error == ParseError::BlockLimit &&
             structuralVisitor.blocks == 0,
         "unselected Block still obeys the separate structural encoded cap");

  const std::array wrongTrack{
      TrackConstraint{2, true, false, 64}};
  ParseOptions wrongTrackOptions = unselectedOptions;
  wrongTrackOptions.trackConstraints = wrongTrack;
  RecordingVisitor wrongTrackVisitor;
  const auto unknownTrack =
      parseOversizedBlock(wrongTrackOptions, wrongTrackVisitor);
  expect(unknownTrack.error == ParseError::InvalidValue,
         "unselected Block must still name a declared track");

  Bytes groupPayload = uintElement(0x9B, 0);
  append(groupPayload,
         element(0xA1,
                 blockPayload(0, Bytes(4U * 1024U, std::byte{0x33}))));
  const auto group = element(0xA0, groupPayload);
  Bytes groupClusterPayload = timestamp;
  append(groupClusterPayload, group);
  const auto groupCluster = element(0x1F43B675, groupClusterPayload);
  MemoryReader groupReader(groupCluster);
  const auto groupHeader =
      readElementHeader(groupReader, 0, groupCluster.size());
  expect(groupHeader.header.has_value(),
         "unselected BlockGroup fixture header parses");
  if (!groupHeader.header) return;
  const auto groupOffset = groupHeader.header->data.offset + timestamp.size();
  auto parseGroup = [&](const ParseOptions& parseOptions,
                        RecordingVisitor& target) {
    auto token = beginClusterChildCursor(
        groupReader, groupHeader.header->data, parseOptions);
    if (!token) return ParseOutcome{};
    const auto metadata =
        parseClusterChildAt(groupReader, *token, target, parseOptions);
    if (metadata.status != ParseStatus::Complete) return metadata;
    return parseClusterChildAt(groupReader, *token, target, parseOptions);
  };
  RecordingVisitor unselectedGroupVisitor;
  const auto unselectedGroup =
      parseGroup(unselectedOptions, unselectedGroupVisitor);
  expect(unselectedGroup.status == ParseStatus::Complete &&
             unselectedGroupVisitor.blocks == 0 &&
             unselectedGroup.nextOffset == groupOffset + group.size(),
         "unselected BlockGroup walks metadata but skips frame layout");
  RecordingVisitor selectedGroupVisitor;
  const auto selectedGroup =
      parseGroup(selectedOptions, selectedGroupVisitor);
  expect(selectedGroup.error == ParseError::BlockLimit &&
             selectedGroupVisitor.blocks == 0,
         "selected BlockGroup obeys the same per-track payload cap");
}

void testEmptyScalarsAndTrackOffset() {
  Bytes headerPayload;
  append(headerPayload, element(0x4286, {}));
  append(headerPayload, element(0x42F7, {}));
  append(headerPayload, element(0x42F2, {}));
  append(headerPayload, element(0x42F3, {}));
  append(headerPayload, asciiElement(0x4282, "matroska"));
  append(headerPayload, element(0x4287, {}));
  append(headerPayload, element(0x4285, {}));

  Bytes infoPayload = element(0x2AD7B1, {});
  const auto infoBytes = element(0x1549A966, infoPayload);
  Bytes videoPayload;
  append(videoPayload, uintElement(0xB0, 64));
  append(videoPayload, uintElement(0xBA, 36));
  append(videoPayload, element(0x9D, {}));
  append(videoPayload, element(0x54B0, {}));
  append(videoPayload, element(0x54BA, {}));
  Bytes colourPayload;
  append(colourPayload, element(0x55B1, {}));
  append(colourPayload, element(0x55BA, {}));
  append(colourPayload, element(0x55BB, {}));
  append(videoPayload, element(0x55B0, colourPayload));
  Bytes trackPayload;
  append(trackPayload, uintElement(0xD7, 1));
  append(trackPayload, uintElement(0x73C5, 99));
  append(trackPayload, uintElement(0x83, 1));
  append(trackPayload, element(0xB9, {}));
  append(trackPayload, element(0x88, {}));
  append(trackPayload, element(0x9C, {}));
  append(trackPayload, element(0x23314F, {}));
  append(trackPayload, element(0x22B59C, {}));
  append(trackPayload, signedElement(0x537F, -3));
  append(trackPayload, asciiElement(0x86, "V_MPEGH/ISO/HEVC"));
  append(trackPayload, element(0xE0, videoPayload));
  const auto trackBytes = element(0x1654AE6B,
                                  element(0xAE, trackPayload));
  Bytes clusterPayload = element(0xE7, {});
  append(clusterPayload, simpleBlock(0x80, Bytes{std::byte{1}}));

  Bytes segment = infoBytes;
  append(segment, trackBytes);
  append(segment, element(0x1F43B675, clusterPayload));
  Bytes bytes = element(0x1A45DFA3, headerPayload);
  append(bytes, element(0x18538067, segment));
  MemoryReader reader(std::move(bytes));
  RecordingVisitor visitor;
  ParseOptions options;
  options.visitClusterBlocks = true;
  const auto result = parseDocument(reader, visitor, options);
  expect(result.status == ParseStatus::Complete &&
             visitor.ebml.maximumIdLength == 4 &&
             visitor.ebml.maximumSizeLength == 8 &&
             visitor.parsedInfo.timestampScaleNanoseconds == 1'000'000 &&
             visitor.track.enabled && visitor.track.defaultTrack &&
             visitor.track.lacingAllowed &&
             std::string_view(visitor.track.language.view().data(),
                              visitor.track.language.view().size()) == "eng" &&
             visitor.track.timestampScale == 1.0 && visitor.track.video &&
             visitor.track.video->fieldOrder == 2 &&
             visitor.track.video->displayWidth == 64 &&
             visitor.track.video->displayHeight == 36 &&
             visitor.track.video->colour.matrixCoefficients == 2 &&
             visitor.track.video->colour.transferCharacteristics == 2 &&
             visitor.track.video->colour.primaries == 2 &&
             visitor.track.timestampOffsetPresent &&
             visitor.track.timestampOffsetNanoseconds == -3 &&
             visitor.cluster.timestamp == 0,
         "empty scalar defaults and zero-valued scalars follow EBML schema");

  Bytes audioPayload;
  append(audioPayload, element(0xB5, {}));
  append(audioPayload, element(0x78B5, {}));
  append(audioPayload, element(0x9F, {}));
  Bytes audioTrackPayload;
  append(audioTrackPayload, uintElement(0xD7, 1));
  append(audioTrackPayload, uintElement(0x73C5, 100));
  append(audioTrackPayload, uintElement(0x83, 2));
  append(audioTrackPayload, asciiElement(0x86, "A_AAC"));
  append(audioTrackPayload, element(0xE1, audioPayload));
  Bytes audioSegment = info();
  append(audioSegment,
         element(0x1654AE6B, element(0xAE, audioTrackPayload)));
  append(audioSegment,
         element(0x1F43B675, uintElement(0xE7, 0)));
  MemoryReader audioReader(document(audioSegment));
  RecordingVisitor audioVisitor;
  const auto audioResult = parseDocument(audioReader, audioVisitor);
  expect(audioResult.status == ParseStatus::Complete &&
             audioVisitor.track.audio &&
             audioVisitor.track.audio->samplingFrequency == 8'000.0 &&
             audioVisitor.track.audio->outputSamplingFrequency == 8'000.0 &&
             audioVisitor.track.audio->channels == 1,
         "empty dynamic audio defaults resolve independent of child order");
}

void testMalformedAndLimits() {
  for (const std::uint32_t forbidden : {0x1A45DFA3U, 0x18538067U}) {
    Bytes clusterPayload = uintElement(0xE7, 0);
    append(clusterPayload, element(forbidden, {}));
    Bytes segment = info();
    append(segment, tracks());
    append(segment, element(0x1F43B675, clusterPayload));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    ParseOptions options;
    options.scanClusterMetadata = true;
    expect(parseDocument(reader, visitor, options).error ==
               ParseError::UnexpectedElement,
           "known-size Cluster rejects nested EBML/Segment documents");
  }
  {
    Bytes bytes = ebmlHeader(1, 2);
    append(bytes, element(0x18538067, info()));
    MemoryReader reader(std::move(bytes));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error ==
               ParseError::UnsupportedVersion,
           "EBMLReadVersion cannot exceed EBMLVersion");
  }
  {
    Bytes bytes = ebmlHeader(1, 1, 8, 2, 3);
    append(bytes, element(0x18538067, info()));
    MemoryReader reader(std::move(bytes));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error ==
               ParseError::UnsupportedVersion,
           "DocTypeReadVersion cannot exceed DocTypeVersion");
  }
  {
    Bytes segment = info();
    append(segment, element(0x1ABCDEFA, Bytes(200, std::byte{0}))); // 2-byte size.
    Bytes bytes = ebmlHeader(1, 1, 1);
    append(bytes, element(0x18538067, segment));
    MemoryReader reader(std::move(bytes));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::InvalidVint,
           "body size VINT cannot exceed EBMLMaxSizeLength");
  }
  {
    Bytes payload = info(true);
    MemoryReader reader(document(payload));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::DuplicateElement,
           "duplicate Info scalar is rejected");
  }
  {
    Bytes payload = info();
    append(payload, tracks(true));
    MemoryReader reader(document(payload));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::DuplicateElement,
           "duplicate TrackEntry scalar is rejected");
  }
  {
    Bytes twoEntries = videoTrack();
    append(twoEntries, videoTrack());
    Bytes payload = info();
    append(payload, element(0x1654AE6B, twoEntries));
    MemoryReader reader(document(payload));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::DuplicateElement,
           "track numbers and UIDs are unique across TrackEntries");
  }
  {
    Bytes segment = info();
    Bytes unknownPayload(200'000, std::byte{0x55});
    append(segment, element(0x1ABCDEFA, unknownPayload));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    const auto result = parseDocument(reader, visitor);
    expect(result.status == ParseStatus::Complete &&
               reader.maximumRead <= ParseOptions::kHardMaximumReadBytes,
           "large unknown known-size element is skipped with bounded reads");
  }
  {
    Bytes segment = info();
    appendId(segment, 0x1654AE6B);
    segment.push_back(std::byte{0xFF});
    segment.push_back(std::byte{0});
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error ==
               ParseError::UnknownSizeNotAllowed,
           "unknown-sized Tracks is rejected before scanning bytes");
  }
  {
    Bytes segment = info();
    appendId(segment, 0x1654AE6B);
    segment.push_back(std::byte{0xFE});  // Claims 126 bytes, supplies none.
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::ParentBoundary,
           "element data cannot escape its parent boundary");
  }
  {
    Bytes nested;
    for (int depth = 0; depth < 8; ++depth) {
      nested = element(0xB6, nested);
    }
    Bytes segment = info();
    append(segment, element(0x1043A770, nested));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::DepthLimit,
           "schema recursion beyond depth eight fails closed");
  }
  {
    Bytes segment = info();
    append(segment, tracks());
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    ParseOptions options;
    options.maximumTracks = 0;
    expect(parseDocument(reader, visitor, options).error ==
               ParseError::TrackLimit,
           "caller can tighten track capacity to zero");
  }
  {
    Bytes segment = info();
    append(segment, tracks(false, 5));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    ParseOptions options;
    options.maximumCodecPrivateBytes = 4;
    expect(parseDocument(reader, visitor, options).status ==
               ParseStatus::LimitExceeded,
           "codec-private range obeys the caller's tightened hard cap");
  }
  {
    MemoryReader reader(completeDocument());
    RecordingVisitor visitor;
    ParseOptions options;
    options.maximumElements = 4;
    expect(parseDocument(reader, visitor, options).error ==
               ParseError::ElementLimit,
           "total element work has an explicit hard ceiling");
  }
  {
    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    constexpr auto base = maximum - 15U;
    Bytes window{std::byte{0xA3}, std::byte{0x01}, std::byte{0xFE},
                 std::byte{0xFE}, std::byte{0xFE}, std::byte{0xFE},
                 std::byte{0xFE}, std::byte{0xFE}, std::byte{0xFE}};
    window.resize(15, std::byte{0});
    WindowReader reader(maximum, base, std::move(window));
    const auto result = readElementHeader(reader, base, maximum);
    expect(result.outcome.error == ParseError::ParentBoundary &&
               !result.header,
           "checked offset arithmetic rejects a size VINT that overflows");
  }
  {
    Bytes group;
    for (int index = 0; index < 17; ++index) {
      append(group, signedElement(0xFB, -1));
    }
    append(group,
           element(0xA1, blockPayload(0, Bytes{std::byte{1}}, 0)));
    Bytes clusterPayload = uintElement(0xE7, 0);
    append(clusterPayload, element(0xA0, group));
    const auto cluster = element(0x1F43B675, clusterPayload);
    MemoryReader reader(cluster);
    RecordingVisitor visitor;
    ParseOptions options;
    options.visitClusterBlocks = true;
    const auto result = parseMasterAt(reader, 0, cluster.size(), 0,
                                      MasterKind::Cluster, visitor, options);
    expect(result.status == ParseStatus::LimitExceeded &&
               result.error == ParseError::BlockLimit,
           "BlockGroup rejects a seventeenth ReferenceBlock");
  }
  {
    MemoryReader reader(completeDocument());
    RecordingVisitor visitor;
    ParseOptions options;
    options.maximumCues = 0;
    const auto result = parseDocument(reader, visitor, options);
    expect(result.error == ParseError::CueLimit,
           "caller can tighten retained cue positions to zero");
  }
  {
    Bytes cuePosition;
    append(cuePosition, uintElement(0xF7, 1));
    append(cuePosition, uintElement(0xF1, 0));
    Bytes cuePoint = uintElement(0xB3, 0);
    append(cuePoint, element(0xB7, cuePosition));
    Bytes segment = info();
    append(segment, tracks());
    append(segment, element(0x1C53BB6B, element(0xBB, cuePoint)));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::InvalidValue,
           "cue target must prove a Cluster even without relative position");
  }
  {
    Bytes segment = info();
    append(segment, tracks());
    const auto timestamp = uintElement(0xE7, 0);
    Bytes clusterPayload = timestamp;
    append(clusterPayload,
           simpleBlock(0x80, Bytes{std::byte{1}}, 0));
    const auto clusterPosition = segment.size();
    append(segment, element(0x1F43B675, clusterPayload));
    append(segment, cues(clusterPosition, 0));
    MemoryReader reader(document(segment));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::InvalidValue,
           "CueRelativePosition must land on a Block rather than metadata");
  }
}

void testDeterministicNoise() {
  std::uint64_t state = 0xD1B54A32D192ED03ULL;
  Visitor visitor;
  for (int iteration = 0; iteration < 2'000; ++iteration) {
    state = state * 6364136223846793005ULL + 1442695040888963407ULL;
    const auto size = static_cast<std::size_t>((state >> 32U) % 513U);
    Bytes bytes(size);
    for (auto& byte : bytes) {
      state = state * 2862933555777941757ULL + 3037000493ULL;
      byte = static_cast<std::byte>(state >> 56U);
    }
    MemoryReader documentReader(bytes);
    static_cast<void>(parseDocument(documentReader, visitor));
    expect(documentReader.maximumRead <=
               ParseOptions::kHardMaximumReadBytes,
           "noise document read stays bounded");
    if (bytes.size() >= 4) {
      MemoryReader blockReader(bytes);
      static_cast<void>(parseBlockLayout(
          blockReader, {0, blockReader.size()}, (iteration & 1) != 0));
      expect(blockReader.maximumRead <= ParseOptions::kHardMaximumReadBytes,
             "noise Block read stays bounded");
    }
  }
}

void testCancellationAndVisitorControl() {
  {
    MemoryReader reader(completeDocument());
    RecordingVisitor visitor;
    std::atomic<bool> cancelled{true};
    const auto result = parseDocument(
        reader, visitor, {}, {&cancelled, atomicCancellation});
    expect(result.status == ParseStatus::Cancelled && reader.reads == 0,
           "pre-cancelled parse performs no I/O");
  }
  {
    MemoryReader reader(completeDocument());
    RecordingVisitor visitor;
    std::atomic<bool> cancelled{false};
    reader.cancelAfterRead = &cancelled;
    const auto result = parseDocument(
        reader, visitor, {}, {&cancelled, atomicCancellation});
    expect(result.status == ParseStatus::Cancelled && reader.reads == 1,
           "cancellation after a reader edge stops before interpretation");
  }
  {
    MemoryReader reader(completeDocument());
    RecordingVisitor visitor;
    visitor.nextAction = VisitorAction::Stop;
    const auto result = parseDocument(reader, visitor);
    expect(result.status == ParseStatus::Stopped && result.ok(),
           "visitor can stop traversal without turning it into an error");
  }
  {
    MemoryReader reader(completeDocument());
    RecordingVisitor visitor;
    visitor.nextAction = VisitorAction::Reject;
    const auto result = parseDocument(reader, visitor);
    expect(result.status == ParseStatus::VisitorRejected &&
               result.error == ParseError::VisitorRejected,
           "visitor rejection remains distinct from malformed input");
  }
  {
    MemoryReader reader(completeDocument());
    std::atomic<bool> cancelled{false};
    CancelOnHeaderVisitor visitor(cancelled);
    const auto result = parseDocument(
        reader, visitor, {}, {&cancelled, atomicCancellation});
    expect(result.status == ParseStatus::Cancelled,
           "cancellation raised by a callback is observed at its return edge");
  }
}

void testChapterAdmissionFacts() {
  Bytes atom;
  append(atom, element(0x6E67, Bytes(16, std::byte{1})));
  Bytes edition;
  append(edition, uintElement(0x45DD, 1));
  append(edition, element(0xB6, atom));
  Bytes segment = info();
  append(segment, element(0x1043A770, element(0x45B9, edition)));
  MemoryReader reader(document(segment));
  RecordingVisitor visitor;
  const auto result = parseDocument(reader, visitor);
  expect(result.status == ParseStatus::Complete &&
             visitor.chapters.orderedEditionPresent &&
             visitor.chapters.linkedSegmentPresent,
         "ordered and linked chapter timelines are surfaced for rejection");
}

void testParseFile() {
  auto bytes = completeDocument();
  std::array<char, 64> path{};
  const std::string pattern = "/private/tmp/wam-matroska-ebml-XXXXXX";
  std::copy(pattern.begin(), pattern.end(), path.begin());
  const int descriptor = ::mkstemp(path.data());
  expect(descriptor >= 0, "temporary Matroska fixture opens");
  if (descriptor < 0) return;
  std::size_t written = 0;
  while (written < bytes.size()) {
    const auto count = ::write(
        descriptor, bytes.data() + static_cast<std::ptrdiff_t>(written),
        bytes.size() - written);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    written += static_cast<std::size_t>(count);
  }
  static_cast<void>(::close(descriptor));
  RecordingVisitor visitor;
  const auto result = parseFile(std::filesystem::path(path.data()), visitor);
  expect(written == bytes.size() && result.status == ParseStatus::Complete,
         "single-descriptor file adapter parses a stable local file");

  GrowFileVisitor grow(path.data());
  const auto changed = parseFile(std::filesystem::path(path.data()), grow);
  expect(changed.status == ParseStatus::IoError &&
             changed.error == ParseError::FileChanged,
         "single-descriptor adapter detects file growth during callbacks");
  static_cast<void>(::unlink(path.data()));
}


// A WebM file is a Matroska file whose DocType says "webm" and whose codecs
// come from a smaller set. The parser admits both names and reports which one
// it read; every other DocType stays rejected, including near-misses that
// share a prefix or a length with an admitted name.
void testDocumentTypeAdmission() {
  struct Case {
    std::string_view docType;
    bool admitted;
    EbmlDocumentType expected;
  };
  static constexpr Case cases[] = {
      {"matroska", true, EbmlDocumentType::Matroska},
      {"webm", true, EbmlDocumentType::Webm},
      // Same length as "matroska", one byte different.
      {"matroskb", false, EbmlDocumentType::Matroska},
      // Same length as "webm", one byte different.
      {"webn", false, EbmlDocumentType::Matroska},
      // Admitted name as a prefix of a longer name.
      {"webmx", false, EbmlDocumentType::Matroska},
      {"matroska2", false, EbmlDocumentType::Matroska},
      // Admitted name as a suffix, and the wrong case.
      {"xwebm", false, EbmlDocumentType::Matroska},
      {"WebM", false, EbmlDocumentType::Matroska},
      {"MATROSKA", false, EbmlDocumentType::Matroska},
      // Neither length.
      {"web", false, EbmlDocumentType::Matroska},
      {"", false, EbmlDocumentType::Matroska},
  };
  for (const Case& testCase : cases) {
    Bytes bytes = ebmlHeader(1, 1, 8, 4, 4, testCase.docType);
    append(bytes, element(0x18538067, info()));
    MemoryReader reader(std::move(bytes));
    RecordingVisitor visitor;
    const auto outcome = parseDocument(reader, visitor);
    if (testCase.admitted) {
      expect(outcome.error == ParseError::None,
             "admitted DocType parses");
      expect(visitor.headers == 1 &&
                 visitor.ebml.documentType == testCase.expected,
             "admitted DocType is reported by name");
    } else {
      expect(outcome.error == ParseError::InvalidValue,
             "rejected DocType fails as an invalid value");
    }
  }

  // DocTypeVersion/DocTypeReadVersion stay independent of the name: the WebM
  // muxers in the wild write 2 and 4, and both are inside the supported range.
  for (std::uint64_t version : {std::uint64_t{2}, std::uint64_t{4}}) {
    Bytes bytes = ebmlHeader(1, 1, 8, version, version, "webm");
    append(bytes, element(0x18538067, info()));
    MemoryReader reader(std::move(bytes));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error == ParseError::None,
           "webm DocTypeVersion 2 and 4 are both admitted");
  }
  {
    Bytes bytes = ebmlHeader(1, 1, 8, 5, 5, "webm");
    append(bytes, element(0x18538067, info()));
    MemoryReader reader(std::move(bytes));
    RecordingVisitor visitor;
    expect(parseDocument(reader, visitor).error ==
               ParseError::UnsupportedVersion,
           "webm does not raise the supported DocTypeReadVersion ceiling");
  }
}

}  // namespace

int main() {
  testVints();
  testLacing();
  testFullStructure();
  testTargetedSeekHead();
  testUnknownSizesAndDocuments();
  testTrackAndTargetProofs();
  testCueCodecStateProof();
  testSegmentChildCursor();
  testTwoPhaseCuesBeforeTracks();
  testTargetedClusterCursor();
  testLinearClusterCursorAndSelectedCaps();
  testEmptyScalarsAndTrackOffset();
  testMalformedAndLimits();
  testDeterministicNoise();
  testCancellationAndVisitorControl();
  testChapterAdmissionFacts();
  testDocumentTypeAdmission();
  testParseFile();
  if (failures != 0) {
    std::cerr << failures << " Matroska EBML test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Matroska EBML tests passed\n";
  return EXIT_SUCCESS;
}
