#include "media/matroska_ebml.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <new>
#include <string_view>
#include <tuple>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

namespace wam::media::matroska {
namespace {

constexpr std::uint32_t kEbml{0x1A45DFA3};
constexpr std::uint32_t kSegment{0x18538067};
constexpr std::uint32_t kSeekHead{0x114D9B74};
constexpr std::uint32_t kSeek{0x4DBB};
constexpr std::uint32_t kSeekId{0x53AB};
constexpr std::uint32_t kSeekPosition{0x53AC};
constexpr std::uint32_t kInfo{0x1549A966};
constexpr std::uint32_t kTimestampScale{0x2AD7B1};
constexpr std::uint32_t kDuration{0x4489};
constexpr std::uint32_t kPreviousUuid{0x3CB923};
constexpr std::uint32_t kNextUuid{0x3EB923};
constexpr std::uint32_t kTracks{0x1654AE6B};
constexpr std::uint32_t kTrackEntry{0xAE};
constexpr std::uint32_t kTrackNumber{0xD7};
constexpr std::uint32_t kTrackUid{0x73C5};
constexpr std::uint32_t kTrackType{0x83};
constexpr std::uint32_t kFlagEnabled{0xB9};
constexpr std::uint32_t kFlagDefault{0x88};
constexpr std::uint32_t kFlagForced{0x55AA};
constexpr std::uint32_t kFlagLacing{0x9C};
constexpr std::uint32_t kDefaultDuration{0x23E383};
constexpr std::uint32_t kTrackTimestampScale{0x23314F};
constexpr std::uint32_t kName{0x536E};
constexpr std::uint32_t kLanguage{0x22B59C};
constexpr std::uint32_t kCodecId{0x86};
constexpr std::uint32_t kCodecPrivate{0x63A2};
constexpr std::uint32_t kCodecDelay{0x56AA};
constexpr std::uint32_t kSeekPreRoll{0x56BB};
constexpr std::uint32_t kTrackOffset{0x537F};
constexpr std::uint32_t kTrackOperation{0xE2};
constexpr std::uint32_t kContentEncodings{0x6D80};
constexpr std::uint32_t kBlockAdditionMapping{0x41E4};
constexpr std::uint32_t kVideo{0xE0};
constexpr std::uint32_t kAudio{0xE1};
constexpr std::uint32_t kFlagInterlaced{0x9A};
constexpr std::uint32_t kFieldOrder{0x9D};
constexpr std::uint32_t kStereoMode{0x53B8};
constexpr std::uint32_t kAlphaMode{0x53C0};
constexpr std::uint32_t kOldStereoMode{0x53B9};
constexpr std::uint32_t kPixelWidth{0xB0};
constexpr std::uint32_t kPixelHeight{0xBA};
constexpr std::uint32_t kPixelCropBottom{0x54AA};
constexpr std::uint32_t kPixelCropTop{0x54BB};
constexpr std::uint32_t kPixelCropLeft{0x54CC};
constexpr std::uint32_t kPixelCropRight{0x54DD};
constexpr std::uint32_t kDisplayWidth{0x54B0};
constexpr std::uint32_t kDisplayHeight{0x54BA};
constexpr std::uint32_t kDisplayUnit{0x54B2};
constexpr std::uint32_t kColour{0x55B0};
constexpr std::uint32_t kProjection{0x7670};
constexpr std::uint32_t kMatrixCoefficients{0x55B1};
constexpr std::uint32_t kBitsPerChannel{0x55B2};
constexpr std::uint32_t kChromaSubsamplingHorz{0x55B3};
constexpr std::uint32_t kChromaSubsamplingVert{0x55B4};
constexpr std::uint32_t kCbSubsamplingHorz{0x55B5};
constexpr std::uint32_t kCbSubsamplingVert{0x55B6};
constexpr std::uint32_t kChromaSitingHorz{0x55B7};
constexpr std::uint32_t kChromaSitingVert{0x55B8};
constexpr std::uint32_t kRange{0x55B9};
constexpr std::uint32_t kTransferCharacteristics{0x55BA};
constexpr std::uint32_t kPrimaries{0x55BB};
constexpr std::uint32_t kMaxCll{0x55BC};
constexpr std::uint32_t kMaxFall{0x55BD};
constexpr std::uint32_t kMasteringMetadata{0x55D0};
constexpr std::uint32_t kSamplingFrequency{0xB5};
constexpr std::uint32_t kOutputSamplingFrequency{0x78B5};
constexpr std::uint32_t kChannels{0x9F};
constexpr std::uint32_t kBitDepth{0x6264};
constexpr std::uint32_t kCluster{0x1F43B675};
constexpr std::uint32_t kClusterTimestamp{0xE7};
constexpr std::uint32_t kSimpleBlock{0xA3};
constexpr std::uint32_t kBlockGroup{0xA0};
constexpr std::uint32_t kBlock{0xA1};
constexpr std::uint32_t kBlockDuration{0x9B};
constexpr std::uint32_t kReferenceBlock{0xFB};
constexpr std::uint32_t kCodecState{0xA4};
constexpr std::uint32_t kBlockAdditions{0x75A1};
constexpr std::uint32_t kDiscardPadding{0x75A2};
constexpr std::uint32_t kCues{0x1C53BB6B};
constexpr std::uint32_t kCuePoint{0xBB};
constexpr std::uint32_t kCueTime{0xB3};
constexpr std::uint32_t kCueTrackPositions{0xB7};
constexpr std::uint32_t kCueTrack{0xF7};
constexpr std::uint32_t kCueClusterPosition{0xF1};
constexpr std::uint32_t kCueRelativePosition{0xF0};
constexpr std::uint32_t kCueBlockNumber{0x5378};
constexpr std::uint32_t kCueCodecState{0xEA};
constexpr std::uint32_t kCueReference{0xDB};
constexpr std::uint32_t kChapters{0x1043A770};
constexpr std::uint32_t kEditionEntry{0x45B9};
constexpr std::uint32_t kEditionFlagOrdered{0x45DD};
constexpr std::uint32_t kChapterAtom{0xB6};
constexpr std::uint32_t kChapterSegmentUuid{0x6E67};
constexpr std::uint32_t kVoid{0xEC};
constexpr std::uint32_t kCrc32{0xBF};

constexpr std::uint32_t kEbmlVersion{0x4286};
constexpr std::uint32_t kEbmlReadVersion{0x42F7};
constexpr std::uint32_t kEbmlMaxIdLength{0x42F2};
constexpr std::uint32_t kEbmlMaxSizeLength{0x42F3};
constexpr std::uint32_t kDocType{0x4282};
constexpr std::uint32_t kDocTypeVersion{0x4287};
constexpr std::uint32_t kDocTypeReadVersion{0x4285};
constexpr std::uint32_t kDocTypeExtension{0x4281};

constexpr std::uint64_t kMaximumSupportedDocTypeVersion{4};
constexpr std::uint64_t kMaximumSupportedEbmlReadVersion{1};

[[nodiscard]] constexpr bool checkedAdd(std::uint64_t lhs, std::uint64_t rhs,
                                        std::uint64_t& result) noexcept {
  if (rhs > std::numeric_limits<std::uint64_t>::max() - lhs) {
    return false;
  }
  result = lhs + rhs;
  return true;
}

[[nodiscard]] constexpr ParseStatus statusFor(ParseError error) noexcept {
  switch (error) {
    case ParseError::None:
      return ParseStatus::Complete;
    case ParseError::Cancelled:
      return ParseStatus::Cancelled;
    case ParseError::ReadFailed:
    case ParseError::FileChanged:
      return ParseStatus::IoError;
    case ParseError::DepthLimit:
    case ParseError::ElementLimit:
    case ParseError::TrackLimit:
    case ParseError::CueLimit:
    case ParseError::BlockLimit:
    case ParseError::TextLimit:
      return ParseStatus::LimitExceeded;
    case ParseError::UnsupportedVersion:
      return ParseStatus::Unsupported;
    case ParseError::VisitorRejected:
      return ParseStatus::VisitorRejected;
    default:
      return ParseStatus::Invalid;
  }
}

[[nodiscard]] constexpr bool isGlobal(std::uint32_t id) noexcept {
  return id == kVoid || id == kCrc32;
}

[[nodiscard]] constexpr bool isTopLevel(std::uint32_t id) noexcept {
  switch (id) {
    case kSeekHead:
    case kInfo:
    case kTracks:
    case kCluster:
    case kCues:
    case kChapters:
    case 0x1941A469:  // Attachments
    case 0x1254C367:  // Tags
      return true;
    default:
      return false;
  }
}

[[nodiscard]] constexpr std::uint32_t idFor(MasterKind kind) noexcept {
  switch (kind) {
    case MasterKind::SeekHead:
      return kSeekHead;
    case MasterKind::Info:
      return kInfo;
    case MasterKind::Tracks:
      return kTracks;
    case MasterKind::Cluster:
      return kCluster;
    case MasterKind::Cues:
      return kCues;
    case MasterKind::Chapters:
      return kChapters;
  }
  return 0;
}

[[nodiscard]] constexpr std::optional<MasterKind> kindFor(
    std::uint32_t id) noexcept {
  switch (id) {
    case kSeekHead:
      return MasterKind::SeekHead;
    case kInfo:
      return MasterKind::Info;
    case kTracks:
      return MasterKind::Tracks;
    case kCluster:
      return MasterKind::Cluster;
    case kCues:
      return MasterKind::Cues;
    case kChapters:
      return MasterKind::Chapters;
    default:
      return std::nullopt;
  }
}

class Access final {
 public:
  Access(SeekableByteReader& reader, ParseOptions options,
         CancellationToken cancellation) noexcept
      : reader_(reader), options_(options), cancellation_(cancellation),
        file_size_(reader.size()) {
    outcome_ = {ParseStatus::Complete, ParseError::None, 0, 0, 0,
                std::nullopt, std::nullopt};
  }

  [[nodiscard]] const ParseOptions& options() const noexcept {
    return options_;
  }
  [[nodiscard]] ParseOptions& mutableOptions() noexcept { return options_; }
  [[nodiscard]] std::uint64_t fileSize() const noexcept { return file_size_; }
  [[nodiscard]] bool active() const noexcept {
    return outcome_.status == ParseStatus::Complete;
  }
  [[nodiscard]] const ParseOutcome& outcome() const noexcept {
    return outcome_;
  }
  [[nodiscard]] ParseOutcome takeOutcome() const noexcept { return outcome_; }

  bool fail(ParseError error, std::uint64_t offset) noexcept {
    if (active()) {
      outcome_.status = statusFor(error);
      outcome_.error = error;
      outcome_.offset = offset;
    }
    return false;
  }

  bool stop(std::uint64_t offset) noexcept {
    if (active()) {
      outcome_.status = ParseStatus::Stopped;
      outcome_.error = ParseError::None;
      outcome_.offset = offset;
    }
    return false;
  }

  bool checkCancellation(std::uint64_t offset) noexcept {
    return cancellation_.cancelled() ? fail(ParseError::Cancelled, offset)
                                     : true;
  }

  // Exact reads are used at trust boundaries where even bounded read-ahead
  // would overlap a skipped/unselected payload.
  bool copyExact(std::uint64_t offset,
                 std::span<std::byte> destination) noexcept {
    if (!active() || !checkCancellation(offset)) {
      return false;
    }
    std::uint64_t requestedEnd = 0;
    if (!checkedAdd(offset, destination.size(), requestedEnd) ||
        requestedEnd > file_size_) {
      return fail(ParseError::Truncated, offset);
    }
    std::size_t copied = 0;
    while (copied < destination.size()) {
      const auto count = std::min(options_.maximumReadBytes,
                                  destination.size() - copied);
      const auto current = offset + copied;
      if (!reader_.readAt(
              current, destination.subspan(copied, count))) {
        return fail(ParseError::ReadFailed, current);
      }
      copied += count;
      if (!checkCancellation(current + count)) {
        return false;
      }
    }
    return checkCancellation(requestedEnd);
  }

  // Sequential one-byte lacing scans use a small side cache. Element headers,
  // scalar values, and fixed Block prefixes use copyExact() so they never
  // read into a skipped frame payload.
  bool copyProbe(std::uint64_t offset,
                 std::span<std::byte> destination) noexcept {
    if (!active() || !checkCancellation(offset)) {
      return false;
    }
    std::uint64_t requestedEnd = 0;
    if (!checkedAdd(offset, destination.size(), requestedEnd) ||
        requestedEnd > file_size_) {
      return fail(ParseError::Truncated, offset);
    }
    std::size_t copied = 0;
    while (copied < destination.size()) {
      const auto current = offset + copied;
      if (!(current >= probe_cache_offset_ && current < probe_cache_end_)) {
        if (!fillProbe(current)) {
          return false;
        }
      }
      const auto cacheIndex =
          static_cast<std::size_t>(current - probe_cache_offset_);
      const auto available =
          static_cast<std::size_t>(probe_cache_end_ - current);
      const auto count = std::min(available, destination.size() - copied);
      std::copy_n(
          probe_cache_.begin() + static_cast<std::ptrdiff_t>(cacheIndex),
          count,
          destination.begin() + static_cast<std::ptrdiff_t>(copied));
      copied += count;
    }
    return checkCancellation(requestedEnd);
  }

  bool byte(std::uint64_t offset, std::byte& value) noexcept {
    std::array<std::byte, 1> bytes{};
    if (!copyProbe(offset, bytes)) {
      return false;
    }
    value = bytes[0];
    return true;
  }

 private:
  bool fillProbe(std::uint64_t offset) noexcept {
    if (offset >= file_size_) {
      return fail(ParseError::Truncated, offset);
    }
    if (!checkCancellation(offset)) {
      return false;
    }
    const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(
        file_size_ - offset,
        std::min(probe_cache_.size(), options_.maximumReadBytes)));
    if (count == 0 ||
        !reader_.readAt(
            offset,
            std::span<std::byte>(probe_cache_.data(), count))) {
      return fail(ParseError::ReadFailed, offset);
    }
    if (!checkCancellation(offset + count)) {
      return false;
    }
    probe_cache_offset_ = offset;
    probe_cache_end_ = offset + count;
    return true;
  }

  SeekableByteReader& reader_;
  ParseOptions options_;
  CancellationToken cancellation_;
  std::uint64_t file_size_{0};
  std::array<std::byte, 256> probe_cache_{};
  std::uint64_t probe_cache_offset_{
      std::numeric_limits<std::uint64_t>::max()};
  std::uint64_t probe_cache_end_{
      std::numeric_limits<std::uint64_t>::max()};
  ParseOutcome outcome_;
};

[[nodiscard]] bool readHeader(Access& access, std::uint64_t offset,
                              std::uint64_t parentEnd,
                              ElementHeader& result) noexcept {
  if (parentEnd > access.fileSize() || offset >= parentEnd) {
    return access.fail(ParseError::Truncated, offset);
  }
  std::array<std::byte, 8> bytes{};
  if (!access.copyExact(offset, std::span<std::byte>(bytes.data(), 1))) {
    return false;
  }
  const auto first = std::to_integer<std::uint8_t>(bytes[0]);
  if (first == 0) {
    return access.fail(ParseError::InvalidVint, offset);
  }
  const auto idWidth = static_cast<std::uint8_t>(std::countl_zero(first) + 1);
  if (idWidth > 4 || idWidth > parentEnd - offset ||
      !access.copyExact(offset,
                         std::span<std::byte>(bytes.data(), idWidth))) {
    return access.active() ? access.fail(ParseError::InvalidElementId, offset)
                           : false;
  }
  const auto id = decodeVint(std::span<const std::byte>(bytes.data(), idWidth),
                             VintKind::ElementId);
  if (id.status != VintStatus::Ready || id.vint.value > 0xFFFFFFFFULL) {
    return access.fail(ParseError::InvalidElementId, offset);
  }
  std::uint64_t sizeOffset = 0;
  if (!checkedAdd(offset, idWidth, sizeOffset) || sizeOffset >= parentEnd ||
      !access.copyExact(sizeOffset,
                         std::span<std::byte>(bytes.data(), 1))) {
    return access.active() ? access.fail(ParseError::Truncated, sizeOffset)
                           : false;
  }
  const auto sizeFirst = std::to_integer<std::uint8_t>(bytes[0]);
  if (sizeFirst == 0) {
    return access.fail(ParseError::InvalidVint, sizeOffset);
  }
  const auto sizeWidth =
      static_cast<std::uint8_t>(std::countl_zero(sizeFirst) + 1);
  if (sizeWidth > 8 || sizeWidth > parentEnd - sizeOffset ||
      !access.copyExact(sizeOffset,
                         std::span<std::byte>(bytes.data(), sizeWidth))) {
    return access.active() ? access.fail(ParseError::Truncated, sizeOffset)
                           : false;
  }
  const auto size = decodeVint(
      std::span<const std::byte>(bytes.data(), sizeWidth), VintKind::ElementSize);
  if (size.status != VintStatus::Ready) {
    return access.fail(ParseError::InvalidVint, sizeOffset);
  }
  std::uint64_t dataOffset = 0;
  if (!checkedAdd(sizeOffset, sizeWidth, dataOffset) || dataOffset > parentEnd) {
    return access.fail(ParseError::ParentBoundary, offset);
  }
  std::uint64_t dataEnd = parentEnd;
  if (!size.vint.unknown &&
      (!checkedAdd(dataOffset, size.vint.value, dataEnd) ||
       dataEnd > parentEnd || dataEnd > access.fileSize())) {
    return access.fail(ParseError::ParentBoundary, offset);
  }
  result.id = static_cast<std::uint32_t>(id.vint.value);
  result.idWidth = idWidth;
  result.sizeWidth = sizeWidth;
  result.unknownSize = size.vint.unknown;
  result.data = {dataOffset, dataEnd - dataOffset};
  result.encoded = {offset, dataEnd - offset};
  return true;
}

[[nodiscard]] constexpr std::uint64_t rangeEnd(ByteRange range) noexcept {
  return range.offset + range.size;
}

}  // namespace

VintOutcome decodeVint(std::span<const std::byte> input,
                       VintKind kind) noexcept {
  if (input.empty()) {
    return {VintStatus::NeedMoreBytes, {}};
  }
  const auto first = std::to_integer<std::uint8_t>(input.front());
  if (first == 0) {
    return {VintStatus::Invalid, {}};
  }
  const auto width = static_cast<std::uint8_t>(std::countl_zero(first) + 1);
  const auto maximumWidth = kind == VintKind::ElementId ? 4U : 8U;
  if (width > maximumWidth) {
    return {VintStatus::Invalid, {}};
  }
  if (input.size() < width) {
    return {VintStatus::NeedMoreBytes, {}};
  }
  std::uint64_t raw = 0;
  for (std::uint8_t index = 0; index < width; ++index) {
    raw = (raw << 8U) | std::to_integer<std::uint8_t>(input[index]);
  }
  const auto markerBit = std::uint64_t{1} << (7U * width);
  const auto dataMask = markerBit - 1U;
  const auto data = raw & dataMask;

  VintValue result;
  result.width = width;
  if (kind == VintKind::ElementId) {
    // Matroska explicitly legalizes one-byte ID 0x80. Other IDs follow RFC
    // 8794's nonzero/non-all-ones and shortest-width constraints.
    if (!(width == 1 && raw == 0x80U)) {
      if (data == 0 || data == dataMask) {
        return {VintStatus::Invalid, {}};
      }
      if (width > 1) {
        const auto shorterMaximum =
            (std::uint64_t{1} << (7U * (width - 1U))) - 1U;
        if (data < shorterMaximum) {
          return {VintStatus::Invalid, {}};
        }
      }
    }
    result.value = raw;
    return {VintStatus::Ready, result};
  }

  result.value = data;
  if (kind == VintKind::ElementSize) {
    result.unknown = data == dataMask;
  } else if (kind == VintKind::SignedLacingValue) {
    const auto bias = (std::uint64_t{1} << (7U * width - 1U)) - 1U;
    result.signedValue = static_cast<std::int64_t>(data) -
                         static_cast<std::int64_t>(bias);
  }
  return {VintStatus::Ready, result};
}

ParseOptions clampParseOptions(const ParseOptions& requested) noexcept {
  ParseOptions result = requested;
  result.maximumReadBytes = std::clamp<std::size_t>(
      requested.maximumReadBytes, 1, ParseOptions::kHardMaximumReadBytes);
  result.maximumElementSizeWidth =
      std::clamp<std::uint8_t>(requested.maximumElementSizeWidth, 1, 8);
  result.maximumDepth = std::clamp<std::uint8_t>(
      requested.maximumDepth, 1, ParseOptions::kHardMaximumDepth);
  result.maximumTracks = std::min(
      requested.maximumTracks, MediaSourceLimits::kHardMaximumTracks);
  result.maximumCodecPrivateBytes =
      std::min(requested.maximumCodecPrivateBytes,
               MediaSourceLimits::kHardMaximumCodecConfigurationBytes);
  result.maximumBlockBytes =
      std::min(requested.maximumBlockBytes,
               MediaSourceLimits::kHardMaximumVideoSampleBytes);
  result.maximumEncodedBlockBytes =
      std::min(requested.maximumEncodedBlockBytes,
               ParseOptions::kHardMaximumEncodedBlockBytes);
  result.maximumTrackTextBytes =
      std::min(requested.maximumTrackTextBytes,
               MediaSourceLimits::kHardMaximumTrackTextBytes);
  result.maximumLaceFrames =
      std::clamp<std::size_t>(requested.maximumLaceFrames, 1,
                              ParseOptions::kHardMaximumLaceFrames);
  result.maximumReferenceBlocks = std::min(
      requested.maximumReferenceBlocks,
      ParseOptions::kHardMaximumReferenceBlocks);
  result.maximumCueTrackPositionsPerPoint =
      std::min(requested.maximumCueTrackPositionsPerPoint,
               ParseOptions::kHardMaximumCueTrackPositionsPerPoint);
  result.maximumCues =
      std::min(requested.maximumCues, ParseOptions::kHardMaximumCues);
  result.maximumSeekEntries = std::min(requested.maximumSeekEntries,
                                       ParseOptions::kHardMaximumSeekEntries);
  result.maximumElements = std::clamp<std::size_t>(
      requested.maximumElements, 1, ParseOptions::kHardMaximumElements);
  result.maximumDocuments = std::clamp<std::uint32_t>(
      requested.maximumDocuments, 1, ParseOptions::kHardMaximumDocuments);
  return result;
}

ElementHeaderOutcome readElementHeader(
    SeekableByteReader& reader, std::uint64_t offset,
    std::uint64_t parentEnd, CancellationToken cancellation) noexcept {
  Access access(reader, clampParseOptions({}), cancellation);
  ElementHeader header;
  if (!readHeader(access, offset, parentEnd, header)) {
    return {access.takeOutcome(), std::nullopt};
  }
  return {{ParseStatus::Complete, ParseError::None, offset, 0, 0,
           std::nullopt, std::nullopt},
          header};
}

namespace {

[[nodiscard]] bool readVintAt(Access& access, std::uint64_t& cursor,
                              std::uint64_t end, VintKind kind,
                              VintValue& result) noexcept {
  if (cursor >= end) {
    return access.fail(ParseError::Truncated, cursor);
  }
  std::array<std::byte, 8> bytes{};
  if (!access.copyExact(cursor, std::span<std::byte>(bytes.data(), 1))) {
    return false;
  }
  const auto first = std::to_integer<std::uint8_t>(bytes[0]);
  if (first == 0) {
    return access.fail(ParseError::InvalidVint, cursor);
  }
  const auto width = static_cast<std::uint8_t>(std::countl_zero(first) + 1);
  const auto maximum = kind == VintKind::ElementId ? 4U : 8U;
  if (width > maximum || width > end - cursor ||
      !access.copyExact(cursor, std::span<std::byte>(bytes.data(), width))) {
    return access.active() ? access.fail(ParseError::Truncated, cursor) : false;
  }
  const auto decoded =
      decodeVint(std::span<const std::byte>(bytes.data(), width), kind);
  if (decoded.status != VintStatus::Ready) {
    return access.fail(ParseError::InvalidVint, cursor);
  }
  result = decoded.vint;
  cursor += width;
  return true;
}

[[nodiscard]] bool readVintAtProbe(Access& access, std::uint64_t& cursor,
                                   std::uint64_t end, VintKind kind,
                                   VintValue& result) noexcept {
  if (cursor >= end) {
    return access.fail(ParseError::Truncated, cursor);
  }
  std::array<std::byte, 8> bytes{};
  if (!access.copyProbe(cursor, std::span<std::byte>(bytes.data(), 1))) {
    return false;
  }
  const auto first = std::to_integer<std::uint8_t>(bytes[0]);
  if (first == 0) {
    return access.fail(ParseError::InvalidVint, cursor);
  }
  const auto width = static_cast<std::uint8_t>(std::countl_zero(first) + 1);
  const auto maximum = kind == VintKind::ElementId ? 4U : 8U;
  if (width > maximum || width > end - cursor ||
      !access.copyProbe(cursor, std::span<std::byte>(bytes.data(), width))) {
    return access.active() ? access.fail(ParseError::Truncated, cursor) : false;
  }
  const auto decoded =
      decodeVint(std::span<const std::byte>(bytes.data(), width), kind);
  if (decoded.status != VintStatus::Ready) {
    return access.fail(ParseError::InvalidVint, cursor);
  }
  result = decoded.vint;
  cursor += width;
  return true;
}

[[nodiscard]] bool appendFrame(Access& access, BlockLayout& layout,
                               std::uint64_t& frameOffset,
                               std::uint64_t blockEnd,
                               std::uint64_t frameSize) noexcept {
  if (frameSize == 0 || layout.frameCount >= layout.frames.size() ||
      layout.frameCount >= access.options().maximumLaceFrames ||
      frameSize > access.options().maximumBlockBytes) {
    return access.fail(ParseError::BlockLimit, frameOffset);
  }
  std::uint64_t frameEnd = 0;
  if (!checkedAdd(frameOffset, frameSize, frameEnd) || frameEnd > blockEnd) {
    return access.fail(ParseError::InvalidValue, frameOffset);
  }
  layout.frames[layout.frameCount++] = {{frameOffset, frameSize}};
  frameOffset = frameEnd;
  return true;
}

struct BlockPrefix {
  BlockHeader header;
  std::uint64_t frameDataOffset{0};
};

// Reads only the bounded Block prefix: TrackNumber, signed relative timestamp,
// and flags. This deliberately does not inspect lacing headers or frame bytes,
// so a caller can identify and skip an unselected track without subjecting its
// encoded payload to a selected-track frame-size cap.
[[nodiscard]] bool parseBlockPrefixImpl(Access& access, ByteRange blockData,
                                        bool simpleBlock,
                                        BlockPrefix& prefix) noexcept {
  if (blockData.size == 0) {
    return access.fail(ParseError::InvalidValue, blockData.offset);
  }
  std::uint64_t blockEnd = 0;
  if (!checkedAdd(blockData.offset, blockData.size, blockEnd) ||
      blockEnd > access.fileSize()) {
    return access.fail(ParseError::ParentBoundary, blockData.offset);
  }

  std::uint64_t cursor = blockData.offset;
  VintValue track;
  if (!readVintAt(access, cursor, blockEnd, VintKind::UnsignedValue, track) ||
      track.value == 0) {
    return access.active()
               ? access.fail(ParseError::InvalidValue, blockData.offset)
               : false;
  }
  if (blockEnd - cursor < 3) {
    return access.fail(ParseError::Truncated, cursor);
  }
  std::array<std::byte, 3> fixed{};
  if (!access.copyExact(cursor, fixed)) {
    return false;
  }
  const auto timestampBits = static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(std::to_integer<std::uint8_t>(fixed[0]))
       << 8U) |
      std::to_integer<std::uint8_t>(fixed[1]));
  const auto flags = std::to_integer<std::uint8_t>(fixed[2]);
  cursor += fixed.size();

  prefix.header.elementData = blockData;
  prefix.header.trackNumber = track.value;
  prefix.header.relativeTimestamp = std::bit_cast<std::int16_t>(timestampBits);
  prefix.header.simpleBlock = simpleBlock;
  prefix.header.keyFrame = simpleBlock && (flags & 0x80U) != 0;
  prefix.header.invisible = (flags & 0x08U) != 0;
  prefix.header.discardable = simpleBlock && (flags & 0x01U) != 0;
  if ((simpleBlock && (flags & 0x70U) != 0) ||
      (!simpleBlock && (flags & 0xF1U) != 0)) {
    return access.fail(ParseError::InvalidValue, cursor - 1);
  }
  switch ((flags >> 1U) & 0x03U) {
    case 0:
      prefix.header.lacing = Lacing::None;
      break;
    case 1:
      prefix.header.lacing = Lacing::Xiph;
      break;
    case 2:
      prefix.header.lacing = Lacing::Fixed;
      break;
    case 3:
      prefix.header.lacing = Lacing::Ebml;
      break;
  }
  // Every Block has at least one non-empty frame. A laced Block also needs a
  // lace-count byte, which the full selected-track parser validates later.
  if (cursor >= blockEnd) {
    return access.fail(ParseError::Truncated, cursor);
  }
  prefix.frameDataOffset = cursor;
  return true;
}

[[nodiscard]] BlockLayoutOutcome parseBlockLayoutImpl(
    Access& access, ByteRange blockData, bool simpleBlock) noexcept {
  BlockLayoutOutcome result;
  result.outcome = access.takeOutcome();
  if (blockData.size == 0 ||
      blockData.size > access.options().maximumEncodedBlockBytes) {
    access.fail(ParseError::BlockLimit, blockData.offset);
    result.outcome = access.takeOutcome();
    return result;
  }
  std::uint64_t blockEnd = 0;
  if (!checkedAdd(blockData.offset, blockData.size, blockEnd) ||
      blockEnd > access.fileSize()) {
    access.fail(ParseError::ParentBoundary, blockData.offset);
    result.outcome = access.takeOutcome();
    return result;
  }

  BlockLayout layout;
  layout.header.elementData = blockData;
  layout.header.simpleBlock = simpleBlock;
  std::uint64_t cursor = blockData.offset;
  VintValue track;
  if (!readVintAt(access, cursor, blockEnd, VintKind::UnsignedValue, track) ||
      track.value == 0) {
    if (access.active()) {
      access.fail(ParseError::InvalidValue, blockData.offset);
    }
    result.outcome = access.takeOutcome();
    return result;
  }
  if (blockEnd - cursor < 3) {
    access.fail(ParseError::Truncated, cursor);
    result.outcome = access.takeOutcome();
    return result;
  }
  std::array<std::byte, 3> fixed{};
  if (!access.copyExact(cursor, fixed)) {
    result.outcome = access.takeOutcome();
    return result;
  }
  const auto timestampBits = static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(std::to_integer<std::uint8_t>(fixed[0]))
       << 8U) |
      std::to_integer<std::uint8_t>(fixed[1]));
  const auto flags = std::to_integer<std::uint8_t>(fixed[2]);
  cursor += fixed.size();

  layout.header.trackNumber = track.value;
  layout.header.relativeTimestamp = std::bit_cast<std::int16_t>(timestampBits);
  layout.header.keyFrame = simpleBlock && (flags & 0x80U) != 0;
  layout.header.invisible = (flags & 0x08U) != 0;
  layout.header.discardable = simpleBlock && (flags & 0x01U) != 0;
  if ((simpleBlock && (flags & 0x70U) != 0) ||
      (!simpleBlock && (flags & 0xF1U) != 0)) {
    access.fail(ParseError::InvalidValue, cursor - 1);
    result.outcome = access.takeOutcome();
    return result;
  }
  switch ((flags >> 1U) & 0x03U) {
    case 0:
      layout.header.lacing = Lacing::None;
      break;
    case 1:
      layout.header.lacing = Lacing::Xiph;
      break;
    case 2:
      layout.header.lacing = Lacing::Fixed;
      break;
    case 3:
      layout.header.lacing = Lacing::Ebml;
      break;
  }

  if (layout.header.lacing == Lacing::None) {
    if (!appendFrame(access, layout, cursor, blockEnd, blockEnd - cursor)) {
      result.outcome = access.takeOutcome();
      return result;
    }
  } else {
    if (cursor >= blockEnd) {
      access.fail(ParseError::Truncated, cursor);
      result.outcome = access.takeOutcome();
      return result;
    }
    std::byte countByte{};
    if (!access.byte(cursor, countByte)) {
      result.outcome = access.takeOutcome();
      return result;
    }
    ++cursor;
    const auto frameCount = static_cast<std::size_t>(
        std::to_integer<std::uint8_t>(countByte)) + 1U;
    if (frameCount < 2 || frameCount > layout.frames.size() ||
        frameCount > access.options().maximumLaceFrames) {
      access.fail(ParseError::BlockLimit, cursor - 1);
      result.outcome = access.takeOutcome();
      return result;
    }

    std::array<std::uint64_t, ParseOptions::kHardMaximumLaceFrames> sizes{};
    if (layout.header.lacing == Lacing::Fixed) {
      const auto payloadBytes = blockEnd - cursor;
      if (payloadBytes == 0 || payloadBytes % frameCount != 0) {
        access.fail(ParseError::InvalidValue, cursor);
        result.outcome = access.takeOutcome();
        return result;
      }
      std::fill_n(sizes.begin(), frameCount, payloadBytes / frameCount);
    } else if (layout.header.lacing == Lacing::Xiph) {
      for (std::size_t frame = 0; frame + 1 < frameCount; ++frame) {
        std::uint64_t size = 0;
        for (;;) {
          if (cursor >= blockEnd) {
            access.fail(ParseError::Truncated, cursor);
            result.outcome = access.takeOutcome();
            return result;
          }
          std::byte encoded{};
          if (!access.byte(cursor, encoded)) {
            result.outcome = access.takeOutcome();
            return result;
          }
          ++cursor;
          const auto part = std::to_integer<std::uint8_t>(encoded);
          if (!checkedAdd(size, part, size) ||
              size > access.options().maximumBlockBytes) {
            access.fail(ParseError::BlockLimit, cursor - 1);
            result.outcome = access.takeOutcome();
            return result;
          }
          if (part != 255U) {
            break;
          }
        }
        sizes[frame] = size;
      }
    } else {
      VintValue firstSize;
      if (!readVintAtProbe(access, cursor, blockEnd,
                           VintKind::UnsignedValue, firstSize)) {
        result.outcome = access.takeOutcome();
        return result;
      }
      sizes[0] = firstSize.value;
      if (sizes[0] == 0) {
        access.fail(ParseError::InvalidValue, cursor);
        result.outcome = access.takeOutcome();
        return result;
      }
      if (sizes[0] > access.options().maximumBlockBytes) {
        access.fail(ParseError::BlockLimit, cursor);
        result.outcome = access.takeOutcome();
        return result;
      }
      for (std::size_t frame = 1; frame + 1 < frameCount; ++frame) {
        VintValue delta;
        if (!readVintAtProbe(access, cursor, blockEnd,
                             VintKind::SignedLacingValue, delta)) {
          result.outcome = access.takeOutcome();
          return result;
        }
        const auto previous = sizes[frame - 1];
        if ((delta.signedValue < 0 &&
             static_cast<std::uint64_t>(-delta.signedValue) >= previous) ||
            (delta.signedValue >= 0 &&
             static_cast<std::uint64_t>(delta.signedValue) >
                 std::numeric_limits<std::uint64_t>::max() - previous)) {
          access.fail(ParseError::InvalidValue, cursor);
          result.outcome = access.takeOutcome();
          return result;
        }
        sizes[frame] = delta.signedValue < 0
                           ? previous - static_cast<std::uint64_t>(
                                            -delta.signedValue)
                           : previous + static_cast<std::uint64_t>(
                                            delta.signedValue);
        if (sizes[frame] > access.options().maximumBlockBytes) {
          access.fail(ParseError::BlockLimit, cursor);
          result.outcome = access.takeOutcome();
          return result;
        }
      }
    }

    std::uint64_t specifiedBytes = 0;
    for (std::size_t frame = 0; frame + 1 < frameCount; ++frame) {
      if (sizes[frame] == 0 ||
          !checkedAdd(specifiedBytes, sizes[frame], specifiedBytes)) {
        access.fail(ParseError::InvalidValue, cursor);
        result.outcome = access.takeOutcome();
        return result;
      }
    }
    const auto payloadBytes = blockEnd - cursor;
    if (specifiedBytes >= payloadBytes) {
      access.fail(ParseError::InvalidValue, cursor);
      result.outcome = access.takeOutcome();
      return result;
    }
    sizes[frameCount - 1] = payloadBytes - specifiedBytes;
    auto frameOffset = cursor;
    for (std::size_t frame = 0; frame < frameCount; ++frame) {
      if (!appendFrame(access, layout, frameOffset, blockEnd, sizes[frame])) {
        result.outcome = access.takeOutcome();
        return result;
      }
    }
    cursor = frameOffset;
  }

  if (cursor != blockEnd || layout.frameCount == 0) {
    access.fail(ParseError::InvalidValue, cursor);
    result.outcome = access.takeOutcome();
    return result;
  }
  result.outcome = access.takeOutcome();
  result.layout = layout;
  return result;
}

}  // namespace

BlockLayoutOutcome parseBlockLayout(SeekableByteReader& reader,
                                    ByteRange blockData, bool simpleBlock,
                                    const ParseOptions& requested,
                                    CancellationToken cancellation) noexcept {
  Access access(reader, clampParseOptions(requested), cancellation);
  return parseBlockLayoutImpl(access, blockData, simpleBlock);
}

namespace {

struct SegmentChildScanOutcome {
  ParseOutcome outcome;
  std::optional<ElementHeader> header;
};

class Parser final {
 public:
  Parser(SeekableByteReader& reader, Visitor& visitor, ParseOptions options,
         CancellationToken cancellation) noexcept
      : access_(reader, options, cancellation), visitor_(visitor),
        maximum_size_length_(options.maximumElementSizeWidth) {
    if (options.trackConstraints.size() <= track_constraints_.size()) {
      track_constraint_count_ = options.trackConstraints.size();
      std::copy(options.trackConstraints.begin(), options.trackConstraints.end(),
                track_constraints_.begin());
      track_table_complete_ = true;
    } else {
      static_cast<void>(access_.fail(ParseError::TrackLimit, 0));
    }
  }

  [[nodiscard]] ParseOutcome parseDocuments() noexcept;
  [[nodiscard]] ParseOutcome parseOneMaster(std::uint64_t absoluteOffset,
                                            std::uint64_t parentEnd,
                                            std::uint64_t segmentDataOffset,
                                            MasterKind expected) noexcept;
  [[nodiscard]] ParseOutcome parseOneSegmentChild(
      ByteRange segmentData, std::uint64_t absoluteOffset,
      MasterKind expected) noexcept;
  [[nodiscard]] ParseOutcome parseOneClusterChild(
      ByteRange clusterData, std::uint64_t childOffset) noexcept;
  [[nodiscard]] std::size_t elementsVisited() const noexcept {
    return element_count_;
  }

  [[nodiscard]] SegmentChildScanOutcome scanNextSegmentChild(
      std::uint64_t nextOffset, std::uint64_t segmentEnd) noexcept;
  [[nodiscard]] ParseOutcome parseProvenSegmentChild(
      const ElementHeader& proof, ByteRange segmentData,
      MasterKind expected) noexcept;

 private:
  [[nodiscard]] bool account(const ElementHeader& header,
                             std::uint8_t depth) noexcept {
    if (depth > access_.options().maximumDepth) {
      return access_.fail(ParseError::DepthLimit, header.encoded.offset);
    }
    ++element_count_;
    if (element_count_ > access_.options().maximumElements) {
      return access_.fail(ParseError::ElementLimit, header.encoded.offset);
    }
    return header.sizeWidth <= maximum_size_length_ ||
           access_.fail(ParseError::InvalidVint, header.encoded.offset);
  }

  [[nodiscard]] bool child(std::uint64_t offset, std::uint64_t parentEnd,
                           std::uint8_t depth,
                           ElementHeader& header) noexcept {
    return readHeader(access_, offset, parentEnd, header) &&
           account(header, depth);
  }

  [[nodiscard]] bool knownSize(const ElementHeader& header) noexcept {
    return !header.unknownSize ||
           access_.fail(ParseError::UnknownSizeNotAllowed,
                        header.encoded.offset);
  }

  [[nodiscard]] bool call(VisitorAction action,
                          std::uint64_t offset) noexcept {
    switch (action) {
      case VisitorAction::Continue:
        return access_.checkCancellation(offset);
      case VisitorAction::Stop:
        return access_.stop(offset);
      case VisitorAction::Reject:
        return access_.fail(ParseError::VisitorRejected, offset);
    }
    return access_.fail(ParseError::VisitorRejected, offset);
  }

  [[nodiscard]] bool readUnsigned(const ElementHeader& header,
                                  std::uint64_t& value) noexcept;
  [[nodiscard]] bool readSigned(const ElementHeader& header,
                                std::int64_t& value) noexcept;
  [[nodiscard]] bool readFloat(const ElementHeader& header,
                               double& value) noexcept;
  [[nodiscard]] bool readAscii(const ElementHeader& header,
                               InlineAscii& value) noexcept;
  [[nodiscard]] bool readDocumentType(const ElementHeader& header,
                                      EbmlDocumentType& value) noexcept;
  [[nodiscard]] bool readElementIdValue(const ElementHeader& header,
                                        std::uint32_t& value) noexcept;
  [[nodiscard]] bool boolean(const ElementHeader& header,
                             bool& value) noexcept;

  [[nodiscard]] bool parseEbmlHeader(const ElementHeader& header) noexcept;
  [[nodiscard]] bool parseSegment(const ElementHeader& header,
                                  std::uint32_t documentIndex,
                                  std::uint64_t& actualEnd) noexcept;
  [[nodiscard]] bool parseSeekHead(const ElementHeader& header,
                                   std::uint64_t segmentDataOffset,
                                   std::uint64_t segmentEnd,
                                   std::uint8_t depth) noexcept;
  [[nodiscard]] bool parseSeek(const ElementHeader& header,
                               std::uint64_t segmentDataOffset,
                               std::uint64_t segmentEnd,
                               std::uint8_t depth) noexcept;
  [[nodiscard]] bool parseInfo(const ElementHeader& header,
                               std::uint8_t depth) noexcept;
  [[nodiscard]] bool parseTracks(const ElementHeader& header,
                                 std::uint8_t depth) noexcept;
  [[nodiscard]] bool parseTrackEntry(const ElementHeader& header,
                                     std::uint8_t depth) noexcept;
  [[nodiscard]] bool discoverTracks(const ElementHeader& header,
                                    std::uint8_t depth) noexcept;
  [[nodiscard]] bool parseVideo(const ElementHeader& header, Video& video,
                                std::uint8_t depth) noexcept;
  [[nodiscard]] bool parseColour(const ElementHeader& header,
                                 VideoColour& colour,
                                 std::uint8_t depth) noexcept;
  [[nodiscard]] bool parseAudio(const ElementHeader& header, Audio& audio,
                                std::uint8_t depth) noexcept;
  [[nodiscard]] bool parseCluster(const ElementHeader& header,
                                  std::uint64_t segmentEnd,
                                  std::uint8_t depth,
                                  std::uint64_t& actualEnd) noexcept;
  [[nodiscard]] bool parseBlockGroup(const ElementHeader& header,
                                     std::uint8_t depth) noexcept;
  [[nodiscard]] bool emitSimpleBlock(const ElementHeader& header) noexcept;
  [[nodiscard]] bool parseCues(const ElementHeader& header,
                               std::uint64_t segmentDataOffset,
                               std::uint64_t segmentEnd,
                               std::uint8_t depth) noexcept;
  [[nodiscard]] bool collectCuePoint(
      const ElementHeader& header, std::uint8_t depth,
      std::vector<CueTrackPosition>& positions);
  [[nodiscard]] bool validateCuePositions(
      std::vector<CueTrackPosition>& positions,
      std::uint64_t segmentDataOffset, std::uint64_t segmentEnd) noexcept;
  [[nodiscard]] bool validateCueCodecStates(
      std::vector<CueTrackPosition>& positions,
      std::uint64_t segmentDataOffset, std::uint64_t segmentEnd,
      std::uint8_t depth);
  [[nodiscard]] bool parseCuePosition(const ElementHeader& header,
                                      std::uint8_t depth,
                                      CueTrackPosition& position) noexcept;
  [[nodiscard]] bool prepareCueClusterDirectory(
      std::uint64_t segmentDataOffset, std::uint64_t segmentEnd,
      std::uint8_t depth,
      const std::vector<CueTrackPosition>& positions);
  [[nodiscard]] bool lookupCueCluster(std::uint64_t requestedOffset,
                                      ElementHeader& cluster) noexcept;
  [[nodiscard]] bool parseChapters(const ElementHeader& header,
                                   std::uint8_t depth) noexcept;
  [[nodiscard]] bool scanChapterChildren(const ElementHeader& header,
                                         std::uint8_t depth,
                                         ChapterFeatures& features) noexcept;
  [[nodiscard]] const TrackConstraint* blockConstraint(
      const BlockHeader& block) noexcept;
  [[nodiscard]] bool validateBlockTrack(const BlockHeader& block) noexcept;
  [[nodiscard]] bool parseCueTargetBlock(const ElementHeader& block,
                                         std::uint64_t cueTrack,
                                         bool requireTrackTable) noexcept;
  [[nodiscard]] bool proveClusterChild(const ElementHeader& cluster,
                                       std::uint64_t requestedOffset,
                                       ElementHeader& child,
                                       std::uint64_t& effectiveEnd) noexcept;
  [[nodiscard]] bool findUnknownClusterEnd(const ElementHeader& cluster,
                                           std::uint64_t& effectiveEnd) noexcept;
  [[nodiscard]] bool proveSegmentChild(std::uint64_t segmentDataOffset,
                                       std::uint64_t segmentEnd,
                                       std::uint64_t requestedOffset,
                                       ElementHeader& child) noexcept;

  [[nodiscard]] ParseOutcome finish() const noexcept {
    auto outcome = access_.takeOutcome();
    outcome.documents = document_count_;
    outcome.segments = segment_count_;
    return outcome;
  }

  Access access_;
  Visitor& visitor_;
  std::size_t element_count_{0};
  std::size_t track_count_{0};
  std::size_t cue_count_{0};
  std::size_t seek_count_{0};
  std::uint32_t document_count_{0};
  std::uint32_t segment_count_{0};
  std::uint8_t maximum_size_length_{8};
  std::array<std::uint64_t, MediaSourceLimits::kHardMaximumTracks>
      track_numbers_{};
  std::array<std::uint64_t, MediaSourceLimits::kHardMaximumTracks>
      track_uids_{};
  std::array<TrackConstraint, MediaSourceLimits::kHardMaximumTracks>
      track_constraints_{};
  std::size_t track_constraint_count_{0};
  bool track_table_complete_{false};
  struct SegmentChildCacheEntry {
    std::uint64_t offset{0};
    ElementHeader header;
  };
  static constexpr std::size_t kSegmentChildCacheCapacity = 256;
  std::array<SegmentChildCacheEntry, kSegmentChildCacheCapacity>
      segment_child_cache_{};
  std::size_t segment_child_cache_count_{0};
  struct CueClusterDirectoryEntry {
    std::uint64_t offset{0};
    std::uint64_t effectiveEnd{0};
  };
  static_assert(sizeof(CueTrackPosition) * 2U +
                        sizeof(std::size_t) * 2U +
                        sizeof(CueClusterDirectoryEntry) <=
                    256U,
                "Cue validation storage must fit its documented hard cap");
  std::vector<CueClusterDirectoryEntry> cue_cluster_directory_;
  std::uint64_t cue_cluster_directory_data_offset_{0};
  std::uint64_t cue_cluster_directory_end_{0};
  bool cue_cluster_directory_complete_{false};
  std::uint64_t segment_scan_data_offset_{0};
  std::uint64_t segment_scan_end_{0};
  std::uint64_t segment_scan_cursor_{0};
  std::uint64_t cluster_scan_offset_{0};
  std::uint64_t cluster_scan_cursor_{0};
  std::uint64_t cluster_scan_boundary_{0};
  std::uint64_t cluster_scan_end_{0};
  std::uint64_t cluster_last_child_offset_{0};
  ElementHeader cluster_last_child_{};
  bool cluster_last_child_valid_{false};
  bool standalone_master_{false};
};

bool Parser::readUnsigned(const ElementHeader& header,
                          std::uint64_t& value) noexcept {
  if (!knownSize(header) || header.data.size > 8) {
    return access_.active()
               ? access_.fail(ParseError::InvalidValue, header.data.offset)
               : false;
  }
  if (header.data.size == 0) {
    value = 0;
    return true;
  }
  std::array<std::byte, 8> bytes{};
  if (!access_.copyExact(
          header.data.offset,
          std::span<std::byte>(bytes.data(), header.data.size))) {
    return false;
  }
  value = 0;
  for (std::size_t index = 0; index < header.data.size; ++index) {
    value = (value << 8U) | std::to_integer<std::uint8_t>(bytes[index]);
  }
  return true;
}

bool Parser::readSigned(const ElementHeader& header,
                        std::int64_t& value) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  if (header.data.size == 0) {
    value = 0;
    return true;
  }
  std::uint64_t bits = 0;
  if (!readUnsigned(header, bits)) {
    return false;
  }
  if (header.data.size < 8 &&
      (bits & (std::uint64_t{1} << (header.data.size * 8U - 1U))) != 0) {
    bits |= std::numeric_limits<std::uint64_t>::max()
            << (header.data.size * 8U);
  }
  value = std::bit_cast<std::int64_t>(bits);
  return true;
}

bool Parser::readFloat(const ElementHeader& header, double& value) noexcept {
  if (!knownSize(header) ||
      (header.data.size != 0 && header.data.size != sizeof(float) &&
       header.data.size != sizeof(double))) {
    return access_.active()
               ? access_.fail(ParseError::InvalidValue, header.data.offset)
               : false;
  }
  if (header.data.size == 0) {
    value = 0.0;
    return true;
  }
  std::array<std::byte, 8> bytes{};
  if (!access_.copyExact(
          header.data.offset,
          std::span<std::byte>(bytes.data(), header.data.size))) {
    return false;
  }
  std::uint64_t bits = 0;
  for (std::size_t index = 0; index < header.data.size; ++index) {
    bits = (bits << 8U) | std::to_integer<std::uint8_t>(bytes[index]);
  }
  if (header.data.size == sizeof(float)) {
    value = static_cast<double>(
        std::bit_cast<float>(static_cast<std::uint32_t>(bits)));
  } else {
    value = std::bit_cast<double>(bits);
  }
  return std::isfinite(value) ||
         access_.fail(ParseError::InvalidValue, header.data.offset);
}

bool Parser::readAscii(const ElementHeader& header,
                       InlineAscii& value) noexcept {
  if (!knownSize(header) || header.data.size == 0 ||
      header.data.size > value.bytes.size() ||
      header.data.size > access_.options().maximumTrackTextBytes) {
    return access_.active()
               ? access_.fail(ParseError::TextLimit, header.data.offset)
               : false;
  }
  std::array<std::byte, InlineAscii::kCapacity> bytes{};
  if (!access_.copyExact(
          header.data.offset,
          std::span<std::byte>(bytes.data(), header.data.size))) {
    return false;
  }
  for (std::size_t index = 0; index < header.data.size; ++index) {
    const auto character = std::to_integer<std::uint8_t>(bytes[index]);
    if (character < 0x20U || character > 0x7EU) {
      return access_.fail(ParseError::InvalidValue,
                          header.data.offset + index);
    }
    value.bytes[index] = static_cast<char>(character);
  }
  value.size = static_cast<std::uint8_t>(header.data.size);
  return true;
}

bool Parser::readDocumentType(const ElementHeader& header,
                              EbmlDocumentType& value) noexcept {
  // DocType names the container. "webm" is admitted alongside "matroska"
  // because a WebM file is a Matroska file whose codecs are drawn from a
  // smaller set; nothing in this parser's grammar differs between the two, and
  // the codec admission downstream already rejects anything it cannot decode.
  // The comparison stays a length-then-bytes match against the two literals so
  // no other DocType (webm2, matroskaX, an empty string) can slip through.
  constexpr std::string_view kMatroska{"matroska"};
  constexpr std::string_view kWebm{"webm"};
  const auto size = static_cast<std::size_t>(header.data.size);
  if (!knownSize(header) ||
      (size != kMatroska.size() && size != kWebm.size())) {
    return access_.active()
               ? access_.fail(ParseError::InvalidValue, header.data.offset)
               : false;
  }
  std::array<std::byte, 8> bytes{};
  if (!access_.copyExact(header.data.offset,
                         std::span<std::byte>(bytes.data(), size))) {
    return false;
  }
  const std::string_view expected = size == kWebm.size() ? kWebm : kMatroska;
  for (std::size_t index = 0; index < size; ++index) {
    if (std::to_integer<unsigned char>(bytes[index]) !=
        static_cast<unsigned char>(expected[index])) {
      return access_.fail(ParseError::InvalidValue,
                          header.data.offset + index);
    }
  }
  value = size == kWebm.size() ? EbmlDocumentType::Webm
                               : EbmlDocumentType::Matroska;
  return true;
}

bool Parser::readElementIdValue(const ElementHeader& header,
                                std::uint32_t& value) noexcept {
  if (!knownSize(header) || header.data.size == 0 || header.data.size > 4) {
    return access_.active()
               ? access_.fail(ParseError::InvalidValue, header.data.offset)
               : false;
  }
  std::array<std::byte, 4> bytes{};
  if (!access_.copyExact(
          header.data.offset,
          std::span<std::byte>(bytes.data(), header.data.size))) {
    return false;
  }
  const auto decoded = decodeVint(
      std::span<const std::byte>(bytes.data(), header.data.size),
      VintKind::ElementId);
  if (decoded.status != VintStatus::Ready ||
      decoded.vint.width != header.data.size ||
      decoded.vint.value > 0xFFFFFFFFULL) {
    return access_.fail(ParseError::InvalidElementId, header.data.offset);
  }
  value = static_cast<std::uint32_t>(decoded.vint.value);
  return true;
}

bool Parser::boolean(const ElementHeader& header, bool& value) noexcept {
  std::uint64_t raw = 0;
  if (!readUnsigned(header, raw) || raw > 1) {
    return access_.active()
               ? access_.fail(ParseError::InvalidValue, header.data.offset)
               : false;
  }
  value = raw != 0;
  return true;
}

bool Parser::parseEbmlHeader(const ElementHeader& header) noexcept {
  if (header.id != kEbml || !knownSize(header)) {
    return access_.active()
               ? access_.fail(ParseError::UnexpectedElement,
                              header.encoded.offset)
               : false;
  }
  EbmlHeader parsed;
  bool seenVersion = false;
  bool seenReadVersion = false;
  bool seenMaxId = false;
  bool seenMaxSize = false;
  bool seenDocType = false;
  bool seenDocTypeVersion = false;
  bool seenDocTypeReadVersion = false;
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, 1, field) || !knownSize(field)) {
      return false;
    }
    std::uint64_t value = 0;
    bool* seen = nullptr;
    switch (field.id) {
      case kEbmlVersion:
        seen = &seenVersion;
        if (field.data.size == 0) {
          parsed.ebmlVersion = 1;
        } else if (!readUnsigned(field, parsed.ebmlVersion)) {
          return false;
        }
        break;
      case kEbmlReadVersion:
        seen = &seenReadVersion;
        if (field.data.size == 0) {
          parsed.ebmlReadVersion = 1;
        } else if (!readUnsigned(field, parsed.ebmlReadVersion)) {
          return false;
        }
        break;
      case kEbmlMaxIdLength:
        seen = &seenMaxId;
        if (field.data.size == 0) {
          parsed.maximumIdLength = 4;
        } else if (!readUnsigned(field, parsed.maximumIdLength)) {
          return false;
        }
        break;
      case kEbmlMaxSizeLength:
        seen = &seenMaxSize;
        if (field.data.size == 0) {
          parsed.maximumSizeLength = 8;
        } else if (!readUnsigned(field, parsed.maximumSizeLength)) {
          return false;
        }
        break;
      case kDocType:
        seen = &seenDocType;
        if (!readDocumentType(field, parsed.documentType)) {
          return false;
        }
        break;
      case kDocTypeVersion:
        seen = &seenDocTypeVersion;
        if (field.data.size == 0) {
          parsed.documentTypeVersion = 1;
        } else if (!readUnsigned(field, parsed.documentTypeVersion)) {
          return false;
        }
        break;
      case kDocTypeReadVersion:
        seen = &seenDocTypeReadVersion;
        if (field.data.size == 0) {
          parsed.documentTypeReadVersion = 1;
        } else if (!readUnsigned(field, parsed.documentTypeReadVersion)) {
          return false;
        }
        break;
      case kDocTypeExtension:
        parsed.documentTypeExtensionPresent = true;
        break;
      default:
        static_cast<void>(value);
        break;
    }
    if (seen != nullptr) {
      if (*seen) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      *seen = true;
    }
    position = rangeEnd(field.encoded);
  }
  if (!seenDocType) {
    return access_.fail(ParseError::MissingElement, header.data.offset);
  }
  if (parsed.ebmlVersion == 0 || parsed.ebmlReadVersion == 0 ||
      parsed.ebmlReadVersion > kMaximumSupportedEbmlReadVersion ||
      parsed.ebmlReadVersion > parsed.ebmlVersion ||
      parsed.maximumIdLength != 4 || parsed.maximumSizeLength == 0 ||
      parsed.maximumSizeLength > 8 || parsed.documentTypeVersion == 0 ||
      parsed.documentTypeReadVersion == 0 ||
      parsed.documentTypeReadVersion > parsed.documentTypeVersion ||
      parsed.documentTypeReadVersion > kMaximumSupportedDocTypeVersion) {
    return access_.fail(ParseError::UnsupportedVersion,
                        header.encoded.offset);
  }
  maximum_size_length_ =
      static_cast<std::uint8_t>(parsed.maximumSizeLength);
  return call(visitor_.onEbmlHeader(parsed), header.encoded.offset);
}

bool Parser::parseSeek(const ElementHeader& header,
                       std::uint64_t segmentDataOffset,
                       std::uint64_t segmentEnd,
                       std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  SeekEntry entry;
  bool seenId = false;
  bool seenPosition = false;
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kSeekId) {
      if (seenId) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenId = true;
      if (!readElementIdValue(field, entry.targetId)) {
        return false;
      }
    } else if (field.id == kSeekPosition) {
      if (seenPosition) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenPosition = true;
      if (!readUnsigned(field, entry.relativePosition)) {
        return false;
      }
    }
    position = rangeEnd(field.encoded);
  }
  if (!seenId || !seenPosition ||
      !checkedAdd(segmentDataOffset, entry.relativePosition,
                  entry.absoluteTargetOffset) ||
      entry.absoluteTargetOffset < segmentDataOffset ||
      entry.absoluteTargetOffset >= segmentEnd) {
    return access_.fail(ParseError::InvalidValue, header.data.offset);
  }
  if (!isTopLevel(entry.targetId)) {
    return access_.fail(ParseError::UnexpectedElement, header.data.offset);
  }
  ElementHeader target;
  if (standalone_master_) {
    // Standalone injected SeekHead fixtures have no enclosing Segment. The
    // production path always supplies a distinct Segment data offset and
    // therefore takes the ancestry-proving branch below.
    if (!readHeader(access_, entry.absoluteTargetOffset, segmentEnd, target)) {
      return false;
    }
  } else if (!proveSegmentChild(segmentDataOffset, segmentEnd,
                                entry.absoluteTargetOffset, target)) {
    return false;
  }
  if (target.id != entry.targetId || target.idWidth != 4) {
    return access_.fail(ParseError::UnexpectedElement,
                        entry.absoluteTargetOffset);
  }
  if (target.sizeWidth > maximum_size_length_ ||
      (target.unknownSize && target.id != kCluster)) {
    return access_.fail(target.unknownSize
                            ? ParseError::UnknownSizeNotAllowed
                            : ParseError::InvalidVint,
                        entry.absoluteTargetOffset);
  }
  entry.targetEncoded = target.encoded;
  entry.targetUnknownSize = target.unknownSize;
  ++seek_count_;
  if (seek_count_ > access_.options().maximumSeekEntries) {
    return access_.fail(ParseError::ElementLimit, header.encoded.offset);
  }
  return call(visitor_.onSeekEntry(entry), header.encoded.offset);
}

bool Parser::parseSeekHead(const ElementHeader& header,
                           std::uint64_t segmentDataOffset,
                           std::uint64_t segmentEnd,
                           std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kSeek &&
        !parseSeek(field, segmentDataOffset, segmentEnd, depth + 1)) {
      return false;
    }
    position = rangeEnd(field.encoded);
  }
  return true;
}

bool Parser::parseInfo(const ElementHeader& header,
                       std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  Info info;
  bool seenScale = false;
  bool seenDuration = false;
  bool seenPrevious = false;
  bool seenNext = false;
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kTimestampScale) {
      if (seenScale) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenScale = true;
      if (field.data.size == 0) {
        info.timestampScaleNanoseconds = 1'000'000;
      } else if (!readUnsigned(field, info.timestampScaleNanoseconds)) {
        return false;
      }
      if (info.timestampScaleNanoseconds == 0) {
        return access_.active()
                   ? access_.fail(ParseError::InvalidValue, field.data.offset)
                   : false;
      }
    } else if (field.id == kDuration) {
      if (seenDuration) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenDuration = true;
      double duration = 0.0;
      if (!readFloat(field, duration) || duration <= 0.0) {
        return access_.active()
                   ? access_.fail(ParseError::InvalidValue, field.data.offset)
                   : false;
      }
      info.durationTicks = duration;
    } else if (field.id == kPreviousUuid) {
      if (seenPrevious) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenPrevious = true;
      if (field.data.size != 16) {
        return access_.fail(ParseError::InvalidValue, field.data.offset);
      }
      info.previousSegmentPresent = true;
    } else if (field.id == kNextUuid) {
      if (seenNext) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenNext = true;
      if (field.data.size != 16) {
        return access_.fail(ParseError::InvalidValue, field.data.offset);
      }
      info.nextSegmentPresent = true;
    }
    position = rangeEnd(field.encoded);
  }
  return call(visitor_.onInfo(info), header.encoded.offset);
}

bool Parser::parseColour(const ElementHeader& header, VideoColour& colour,
                         std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  std::array<bool, 13> seen{};
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    std::optional<std::uint64_t>* target = nullptr;
    std::size_t index = 0;
    switch (field.id) {
      case kMatrixCoefficients:
        target = &colour.matrixCoefficients;
        index = 0;
        break;
      case kBitsPerChannel:
        target = &colour.bitsPerChannel;
        index = 1;
        break;
      case kChromaSubsamplingHorz:
        target = &colour.chromaSubsamplingHorizontal;
        index = 2;
        break;
      case kChromaSubsamplingVert:
        target = &colour.chromaSubsamplingVertical;
        index = 3;
        break;
      case kCbSubsamplingHorz:
        target = &colour.cbSubsamplingHorizontal;
        index = 4;
        break;
      case kCbSubsamplingVert:
        target = &colour.cbSubsamplingVertical;
        index = 5;
        break;
      case kChromaSitingHorz:
        target = &colour.chromaSitingHorizontal;
        index = 6;
        break;
      case kChromaSitingVert:
        target = &colour.chromaSitingVertical;
        index = 7;
        break;
      case kRange:
        target = &colour.range;
        index = 8;
        break;
      case kTransferCharacteristics:
        target = &colour.transferCharacteristics;
        index = 9;
        break;
      case kPrimaries:
        target = &colour.primaries;
        index = 10;
        break;
      case kMaxCll:
        target = &colour.maximumContentLightLevel;
        index = 11;
        break;
      case kMaxFall:
        target = &colour.maximumFrameAverageLightLevel;
        index = 12;
        break;
      case kMasteringMetadata:
        if (colour.masteringMetadataPresent) {
          return access_.fail(ParseError::DuplicateElement,
                              field.encoded.offset);
        }
        colour.masteringMetadataPresent = true;
        break;
      default:
        break;
    }
    if (target != nullptr) {
      if (seen[index]) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seen[index] = true;
      const std::uint64_t emptyDefault =
          index == 0 || index == 9 || index == 10 ? 2U : 0U;
      std::uint64_t value = emptyDefault;
      if (field.data.size != 0 && !readUnsigned(field, value)) {
        return false;
      }
      *target = value;
    }
    position = rangeEnd(field.encoded);
  }
  return true;
}

bool Parser::parseVideo(const ElementHeader& header, Video& video,
                        std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  enum Field : std::size_t {
    Interlaced,
    FieldOrder,
    Stereo,
    Alpha,
    Width,
    Height,
    CropBottom,
    CropTop,
    CropLeft,
    CropRight,
    DisplayWidth,
    DisplayHeight,
    DisplayUnit,
    Colour,
    Projection,
    Count,
  };
  std::array<bool, Count> seen{};
  bool emptyDisplayWidth = false;
  bool emptyDisplayHeight = false;
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    std::uint64_t value = 0;
    Field identity = Count;
    switch (field.id) {
      case kFlagInterlaced:
        identity = Interlaced;
        if (!readUnsigned(field, value)) return false;
        video.interlaced = value;
        break;
      case kFieldOrder:
        identity = FieldOrder;
        if (field.data.size == 0) video.fieldOrder = 2;
        else {
          if (!readUnsigned(field, value)) return false;
          video.fieldOrder = value;
        }
        break;
      case kStereoMode:
        identity = Stereo;
        if (!readUnsigned(field, value)) return false;
        video.stereoMode = value;
        break;
      case kAlphaMode:
        identity = Alpha;
        if (!readUnsigned(field, value)) return false;
        video.alphaMode = value;
        break;
      case kOldStereoMode:
        return access_.fail(ParseError::InvalidValue, field.encoded.offset);
      case kPixelWidth:
        identity = Width;
        if (!readUnsigned(field, value)) return false;
        video.pixelWidth = value;
        break;
      case kPixelHeight:
        identity = Height;
        if (!readUnsigned(field, value)) return false;
        video.pixelHeight = value;
        break;
      case kPixelCropBottom:
        identity = CropBottom;
        if (!readUnsigned(field, video.cropBottom)) return false;
        break;
      case kPixelCropTop:
        identity = CropTop;
        if (!readUnsigned(field, video.cropTop)) return false;
        break;
      case kPixelCropLeft:
        identity = CropLeft;
        if (!readUnsigned(field, video.cropLeft)) return false;
        break;
      case kPixelCropRight:
        identity = CropRight;
        if (!readUnsigned(field, video.cropRight)) return false;
        break;
      case kDisplayWidth:
        identity = DisplayWidth;
        if (field.data.size == 0) {
          emptyDisplayWidth = true;
        } else {
          if (!readUnsigned(field, value)) return false;
          video.displayWidth = value;
        }
        break;
      case kDisplayHeight:
        identity = DisplayHeight;
        if (field.data.size == 0) {
          emptyDisplayHeight = true;
        } else {
          if (!readUnsigned(field, value)) return false;
          video.displayHeight = value;
        }
        break;
      case kDisplayUnit:
        identity = DisplayUnit;
        if (!readUnsigned(field, video.displayUnit)) return false;
        break;
      case kColour:
        identity = Colour;
        if (!parseColour(field, video.colour, depth + 1)) return false;
        break;
      case kProjection:
        identity = Projection;
        video.projectionPresent = true;
        break;
      default:
        break;
    }
    if (identity != Count) {
      if (seen[identity]) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seen[identity] = true;
    }
    position = rangeEnd(field.encoded);
  }
  if (!video.pixelWidth || !video.pixelHeight || *video.pixelWidth == 0 ||
      *video.pixelHeight == 0 || video.interlaced > 2 ||
      video.displayUnit > 4 || video.alphaMode > 1 ||
      video.cropLeft >= *video.pixelWidth ||
      video.cropRight >= *video.pixelWidth - video.cropLeft ||
      video.cropTop >= *video.pixelHeight ||
      video.cropBottom >= *video.pixelHeight - video.cropTop) {
    return access_.fail(ParseError::InvalidValue, header.data.offset);
  }
  if ((emptyDisplayWidth || emptyDisplayHeight) && video.displayUnit != 0) {
    return access_.fail(ParseError::InvalidValue, header.data.offset);
  }
  if (emptyDisplayWidth) {
    video.displayWidth =
        *video.pixelWidth - video.cropLeft - video.cropRight;
  }
  if (emptyDisplayHeight) {
    video.displayHeight =
        *video.pixelHeight - video.cropTop - video.cropBottom;
  }
  if ((video.displayWidth && *video.displayWidth == 0) ||
      (video.displayHeight && *video.displayHeight == 0)) {
    return access_.fail(ParseError::InvalidValue, header.data.offset);
  }
  return true;
}

bool Parser::parseAudio(const ElementHeader& header, Audio& audio,
                        std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  std::array<bool, 4> seen{};
  bool emptyOutputSamplingFrequency = false;
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    std::size_t identity = seen.size();
    if (field.id == kSamplingFrequency) {
      identity = 0;
      if (field.data.size == 0) audio.samplingFrequency = 8'000.0;
      else if (!readFloat(field, audio.samplingFrequency)) return false;
    } else if (field.id == kOutputSamplingFrequency) {
      identity = 1;
      if (field.data.size == 0) {
        emptyOutputSamplingFrequency = true;
      } else {
        double value = 0.0;
        if (!readFloat(field, value)) return false;
        audio.outputSamplingFrequency = value;
      }
    } else if (field.id == kChannels) {
      identity = 2;
      if (field.data.size == 0) audio.channels = 1;
      else if (!readUnsigned(field, audio.channels)) return false;
    } else if (field.id == kBitDepth) {
      identity = 3;
      std::uint64_t value = 0;
      if (!readUnsigned(field, value)) return false;
      audio.bitDepth = value;
    }
    if (identity < seen.size()) {
      if (seen[identity]) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seen[identity] = true;
    }
    position = rangeEnd(field.encoded);
  }
  if (emptyOutputSamplingFrequency) {
    audio.outputSamplingFrequency = audio.samplingFrequency;
  }
  if (!std::isfinite(audio.samplingFrequency) ||
      audio.samplingFrequency <= 0.0 || audio.channels == 0 ||
      (audio.outputSamplingFrequency &&
       (!std::isfinite(*audio.outputSamplingFrequency) ||
        *audio.outputSamplingFrequency <= 0.0)) ||
      (audio.bitDepth && *audio.bitDepth == 0)) {
    return access_.fail(ParseError::InvalidValue, header.data.offset);
  }
  return true;
}

bool Parser::parseTrackEntry(const ElementHeader& header,
                             std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  TrackEntry track;
  track.encoded = header.encoded;
  constexpr char kDefaultLanguage[] = {'e', 'n', 'g'};
  std::copy(std::begin(kDefaultLanguage), std::end(kDefaultLanguage),
            track.language.bytes.begin());
  track.language.size = 3;
  enum Field : std::size_t {
    Number,
    Uid,
    Type,
    Enabled,
    Default,
    Forced,
    Lacing,
    DefaultDuration,
    TimestampScale,
    Name,
    Language,
    CodecId,
    CodecPrivate,
    CodecDelay,
    SeekPreRoll,
    TrackOffset,
    VideoField,
    AudioField,
    TrackOperation,
    ContentEncodings,
    Count,
  };
  std::array<bool, Count> seen{};
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    Field identity = Count;
    std::uint64_t unsignedValue = 0;
    switch (field.id) {
      case kTrackNumber:
        identity = Number;
        if (!readUnsigned(field, track.number)) return false;
        break;
      case kTrackUid:
        identity = Uid;
        if (!readUnsigned(field, track.uid)) return false;
        break;
      case kTrackType:
        identity = Type;
        if (!readUnsigned(field, track.type)) return false;
        break;
      case kFlagEnabled:
        identity = Enabled;
        if (field.data.size == 0) track.enabled = true;
        else if (!boolean(field, track.enabled)) return false;
        break;
      case kFlagDefault:
        identity = Default;
        if (field.data.size == 0) track.defaultTrack = true;
        else if (!boolean(field, track.defaultTrack)) return false;
        break;
      case kFlagForced:
        identity = Forced;
        if (!boolean(field, track.forced)) return false;
        break;
      case kFlagLacing:
        identity = Lacing;
        if (field.data.size == 0) track.lacingAllowed = true;
        else if (!boolean(field, track.lacingAllowed)) return false;
        break;
      case kDefaultDuration:
        identity = DefaultDuration;
        if (!readUnsigned(field, unsignedValue)) return false;
        track.defaultDurationNanoseconds = unsignedValue;
        break;
      case kTrackTimestampScale:
        identity = TimestampScale;
        if (field.data.size == 0) track.timestampScale = 1.0;
        else if (!readFloat(field, track.timestampScale)) return false;
        break;
      case kName:
        identity = Name;
        if (field.data.size > access_.options().maximumTrackTextBytes) {
          return access_.fail(ParseError::TextLimit, field.data.offset);
        }
        track.name = field.data;
        break;
      case kLanguage:
        identity = Language;
        track.language = {};
        if (field.data.size == 0) {
          std::copy(std::begin(kDefaultLanguage), std::end(kDefaultLanguage),
                    track.language.bytes.begin());
          track.language.size = 3;
        } else if (!readAscii(field, track.language)) {
          return false;
        }
        break;
      case kCodecId:
        identity = CodecId;
        if (!readAscii(field, track.codecId)) return false;
        break;
      case kCodecPrivate:
        identity = CodecPrivate;
        if (field.data.size == 0 ||
            field.data.size > access_.options().maximumCodecPrivateBytes) {
          return access_.fail(ParseError::BlockLimit, field.data.offset);
        }
        track.codecPrivate = field.data;
        break;
      case kCodecDelay:
        identity = CodecDelay;
        if (!readUnsigned(field, track.codecDelayNanoseconds)) return false;
        break;
      case kSeekPreRoll:
        identity = SeekPreRoll;
        if (!readUnsigned(field, track.seekPreRollNanoseconds)) return false;
        break;
      case kTrackOffset:
        identity = TrackOffset;
        if (!readSigned(field, track.timestampOffsetNanoseconds)) return false;
        track.timestampOffsetPresent = true;
        break;
      case kVideo:
        identity = VideoField;
        track.video.emplace();
        if (!parseVideo(field, *track.video, depth + 1)) return false;
        break;
      case kAudio:
        identity = AudioField;
        track.audio.emplace();
        if (!parseAudio(field, *track.audio, depth + 1)) return false;
        break;
      case kTrackOperation:
        identity = TrackOperation;
        track.trackOperationPresent = true;
        break;
      case kContentEncodings:
        identity = ContentEncodings;
        track.contentEncodingsPresent = true;
        break;
      case kBlockAdditionMapping:
        track.blockAdditionMappingPresent = true;
        break;
      default:
        break;
    }
    if (identity != Count) {
      if (seen[identity]) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seen[identity] = true;
    }
    position = rangeEnd(field.encoded);
  }
  if (!seen[Number] || !seen[Uid] || !seen[Type] || !seen[CodecId] ||
      track.number == 0 || track.uid == 0 || track.type == 0 ||
      !std::isfinite(track.timestampScale) || track.timestampScale <= 0.0 ||
      (track.defaultDurationNanoseconds &&
       *track.defaultDurationNanoseconds == 0) ||
      (track.type == 1 && !track.video) ||
      (track.type == 2 && !track.audio) ||
      (track.video && track.type != 1) || (track.audio && track.type != 2)) {
    return access_.fail(ParseError::InvalidValue, header.data.offset);
  }
  if (std::find(track_numbers_.begin(),
                track_numbers_.begin() +
                    static_cast<std::ptrdiff_t>(track_count_),
                track.number) !=
          track_numbers_.begin() +
              static_cast<std::ptrdiff_t>(track_count_) ||
      std::find(track_uids_.begin(),
                track_uids_.begin() +
                    static_cast<std::ptrdiff_t>(track_count_),
                track.uid) !=
          track_uids_.begin() + static_cast<std::ptrdiff_t>(track_count_)) {
    return access_.fail(ParseError::DuplicateElement, header.data.offset);
  }
  ++track_count_;
  if (track_count_ > access_.options().maximumTracks) {
    return access_.fail(ParseError::TrackLimit, header.encoded.offset);
  }
  track_numbers_[track_count_ - 1] = track.number;
  track_uids_[track_count_ - 1] = track.uid;
  track_constraints_[track_count_ - 1] = {
      track.number, track.lacingAllowed, true,
      access_.options().maximumBlockBytes};
  track_constraint_count_ = track_count_;
  return call(visitor_.onTrackEntry(track), header.encoded.offset);
}

bool Parser::parseTracks(const ElementHeader& header,
                         std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kTrackEntry &&
        !parseTrackEntry(field, depth + 1)) {
      return false;
    }
    position = rangeEnd(field.encoded);
  }
  track_table_complete_ = true;
  return true;
}

bool Parser::proveClusterChild(const ElementHeader& cluster,
                               std::uint64_t requestedOffset,
                               ElementHeader& child,
                               std::uint64_t& effectiveEnd) noexcept {
  if (cluster.id != kCluster || requestedOffset < cluster.data.offset) {
    return access_.fail(ParseError::ParentBoundary, requestedOffset);
  }
  const auto provisionalEnd = rangeEnd(cluster.data);
  if (cluster_last_child_valid_ &&
      cluster_scan_offset_ == cluster.encoded.offset &&
      cluster_last_child_offset_ == requestedOffset) {
    child = cluster_last_child_;
    effectiveEnd = cluster_scan_end_;
    return true;
  }
  if (cluster_scan_offset_ != cluster.encoded.offset ||
      cluster_scan_boundary_ != provisionalEnd) {
    cluster_scan_offset_ = cluster.encoded.offset;
    cluster_scan_cursor_ = cluster.data.offset;
    cluster_scan_boundary_ = provisionalEnd;
    cluster_scan_end_ = cluster.unknownSize ? 0 : provisionalEnd;
    cluster_last_child_valid_ = false;
  } else if (requestedOffset < cluster_scan_cursor_) {
    cluster_scan_cursor_ = cluster.data.offset;
    cluster_last_child_valid_ = false;
  }
  if (cluster.unknownSize && cluster_scan_end_ == 0 &&
      !findUnknownClusterEnd(cluster, cluster_scan_end_)) {
    return false;
  }
  effectiveEnd = cluster_scan_end_;
  if (requestedOffset >= effectiveEnd) {
    return access_.fail(ParseError::ParentBoundary, requestedOffset);
  }
  auto cursor = cluster_scan_cursor_;
  while (cursor < effectiveEnd) {
    ElementHeader candidate;
    if (!this->child(cursor, effectiveEnd, 2, candidate) ||
        !knownSize(candidate)) {
      return false;
    }
    if ((isTopLevel(candidate.id) || candidate.id == kEbml ||
         candidate.id == kSegment) &&
        candidate.idWidth == 4) {
      return access_.fail(ParseError::UnexpectedElement,
                          candidate.encoded.offset);
    }
    const auto next = rangeEnd(candidate.encoded);
    if (cursor == requestedOffset) {
      child = candidate;
      cluster_last_child_offset_ = cursor;
      cluster_last_child_ = candidate;
      cluster_last_child_valid_ = true;
      cluster_scan_cursor_ = next;
      return true;
    }
    if (next <= cursor ||
        (requestedOffset > cursor && requestedOffset < next)) {
      return access_.fail(ParseError::ParentBoundary, requestedOffset);
    }
    cursor = next;
    cluster_scan_cursor_ = cursor;
  }
  return access_.fail(ParseError::ParentBoundary, requestedOffset);
}

bool Parser::findUnknownClusterEnd(const ElementHeader& cluster,
                                   std::uint64_t& effectiveEnd) noexcept {
  if (cluster.id != kCluster || !cluster.unknownSize) {
    return access_.fail(ParseError::UnexpectedElement,
                        cluster.encoded.offset);
  }
  const auto scanEnd = rangeEnd(cluster.data);
  auto cursor = cluster.data.offset;
  while (cursor < scanEnd) {
    ElementHeader candidate;
    if (!readHeader(access_, cursor, scanEnd, candidate)) {
      return false;
    }
    if ((isTopLevel(candidate.id) || candidate.id == kEbml ||
         candidate.id == kSegment) &&
        candidate.idWidth == 4) {
      effectiveEnd = cursor;
      return true;
    }
    if (!account(candidate, 2) || !knownSize(candidate)) {
      return false;
    }
    const auto next = rangeEnd(candidate.encoded);
    if (next <= cursor) {
      return access_.fail(ParseError::InvalidValue, cursor);
    }
    cursor = next;
  }
  effectiveEnd = cursor;
  return true;
}

bool Parser::proveSegmentChild(std::uint64_t segmentDataOffset,
                               std::uint64_t segmentEnd,
                               std::uint64_t requestedOffset,
                               ElementHeader& child) noexcept {
  if (segmentDataOffset > requestedOffset || requestedOffset >= segmentEnd) {
    return access_.fail(ParseError::ParentBoundary, requestedOffset);
  }
  for (std::size_t index = 0; index < segment_child_cache_count_; ++index) {
    if (segment_child_cache_[index].offset == requestedOffset) {
      child = segment_child_cache_[index].header;
      return true;
    }
  }
  if (segment_scan_data_offset_ != segmentDataOffset ||
      segment_scan_end_ != segmentEnd ||
      requestedOffset < segment_scan_cursor_) {
    segment_scan_data_offset_ = segmentDataOffset;
    segment_scan_end_ = segmentEnd;
    segment_scan_cursor_ = segmentDataOffset;
    segment_child_cache_count_ = 0;
  }
  auto cursor = segment_scan_cursor_;
  while (cursor < segmentEnd) {
    ElementHeader candidate;
    if (!readHeader(access_, cursor, segmentEnd, candidate)) {
      return false;
    }
    if (candidate.id == kEbml || candidate.id == kSegment ||
        (!isGlobal(candidate.id) && candidate.idWidth != 4)) {
      return access_.fail(ParseError::UnexpectedElement,
                          candidate.encoded.offset);
    }
    if (!account(candidate, 1)) {
      return false;
    }
    if (segment_child_cache_count_ < segment_child_cache_.size()) {
      segment_child_cache_[segment_child_cache_count_++] = {cursor, candidate};
    }
    if (cursor == requestedOffset) {
      child = candidate;
      segment_scan_cursor_ = cursor;
      return true;
    }
    std::uint64_t next = rangeEnd(candidate.encoded);
    if (candidate.unknownSize) {
      if (candidate.id != kCluster) {
        return access_.fail(ParseError::UnknownSizeNotAllowed,
                            candidate.encoded.offset);
      }
      if (!findUnknownClusterEnd(candidate, next)) {
        return false;
      }
    }
    if (next <= cursor ||
        (requestedOffset > cursor && requestedOffset < next)) {
      return access_.fail(ParseError::ParentBoundary, requestedOffset);
    }
    cursor = next;
    segment_scan_cursor_ = cursor;
  }
  return access_.fail(ParseError::ParentBoundary, requestedOffset);
}

bool Parser::discoverTracks(const ElementHeader& header,
                            std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader entry;
    if (!child(position, end, depth + 1, entry) || !knownSize(entry)) {
      return false;
    }
    if (entry.id == kTrackEntry) {
      bool seenNumber = false;
      bool seenLacing = false;
      TrackConstraint constraint;
      auto fieldOffset = entry.data.offset;
      const auto fieldEnd = rangeEnd(entry.data);
      while (fieldOffset < fieldEnd) {
        ElementHeader field;
        if (!child(fieldOffset, fieldEnd, depth + 2, field) ||
            !knownSize(field)) {
          return false;
        }
        if (field.id == kTrackNumber) {
          if (seenNumber || !readUnsigned(field, constraint.number) ||
              constraint.number == 0) {
            return access_.active()
                       ? access_.fail(ParseError::DuplicateElement,
                                      field.encoded.offset)
                       : false;
          }
          seenNumber = true;
        } else if (field.id == kFlagLacing) {
          if (seenLacing ||
              (field.data.size != 0 &&
               !boolean(field, constraint.lacingAllowed))) {
            return access_.active()
                       ? access_.fail(ParseError::DuplicateElement,
                                      field.encoded.offset)
                       : false;
          }
          seenLacing = true;
        }
        fieldOffset = rangeEnd(field.encoded);
      }
      if (!seenNumber || track_constraint_count_ >= track_constraints_.size() ||
          std::find_if(track_constraints_.begin(),
                       track_constraints_.begin() +
                           static_cast<std::ptrdiff_t>(track_constraint_count_),
                       [&constraint](const TrackConstraint& existing) {
                         return existing.number == constraint.number;
                       }) !=
              track_constraints_.begin() +
                  static_cast<std::ptrdiff_t>(track_constraint_count_)) {
        return access_.fail(seenNumber ? ParseError::DuplicateElement
                                       : ParseError::MissingElement,
                            entry.data.offset);
      }
      constraint.maximumBlockBytes = access_.options().maximumBlockBytes;
      track_constraints_[track_constraint_count_++] = constraint;
    }
    position = rangeEnd(entry.encoded);
  }
  track_table_complete_ = true;
  return true;
}

const TrackConstraint* Parser::blockConstraint(
    const BlockHeader& block) noexcept {
  if (!track_table_complete_) {
    static_cast<void>(
        access_.fail(ParseError::MissingElement, block.blockEncoded.offset));
    return nullptr;
  }
  const auto begin = track_constraints_.begin();
  const auto end = begin + static_cast<std::ptrdiff_t>(track_constraint_count_);
  const auto constraint = std::find_if(
      begin, end, [&block](const TrackConstraint& candidate) {
        return candidate.number == block.trackNumber;
      });
  if (constraint == end ||
      (!constraint->lacingAllowed && block.lacing != Lacing::None)) {
    static_cast<void>(
        access_.fail(ParseError::InvalidValue, block.blockEncoded.offset));
    return nullptr;
  }
  return &*constraint;
}

bool Parser::validateBlockTrack(const BlockHeader& block) noexcept {
  return blockConstraint(block) != nullptr;
}

bool Parser::parseCueTargetBlock(const ElementHeader& element,
                                 std::uint64_t cueTrack,
                                 bool requireTrackTable) noexcept {
  if (element.encoded.size > access_.options().maximumEncodedBlockBytes) {
    return access_.fail(ParseError::BlockLimit, element.encoded.offset);
  }
  ElementHeader block = element;
  if (element.id == kBlockGroup) {
    bool found = false;
    auto cursor = element.data.offset;
    const auto end = rangeEnd(element.data);
    while (cursor < end) {
      ElementHeader field;
      if (!child(cursor, end, 3, field) || !knownSize(field)) {
        return false;
      }
      if (field.id == kBlock) {
        if (found) {
          return access_.fail(ParseError::DuplicateElement,
                              field.encoded.offset);
        }
        found = true;
        block = field;
        if (block.encoded.size >
            access_.options().maximumEncodedBlockBytes) {
          return access_.fail(ParseError::BlockLimit,
                              block.encoded.offset);
        }
      }
      cursor = rangeEnd(field.encoded);
    }
    if (!found) {
      return access_.fail(ParseError::MissingElement, element.data.offset);
    }
  }
  BlockPrefix prefix;
  if (!parseBlockPrefixImpl(access_, block.data,
                            element.id == kSimpleBlock, prefix)) {
    return false;
  }
  prefix.header.containerEncoded = element.encoded;
  prefix.header.blockEncoded = block.encoded;
  if (prefix.header.trackNumber != cueTrack) {
    return access_.fail(ParseError::InvalidValue, block.encoded.offset);
  }
  if (!track_table_complete_ && !requireTrackTable) {
    const auto originalMaximum = access_.options().maximumBlockBytes;
    auto parsed = parseBlockLayoutImpl(access_, block.data,
                                       element.id == kSimpleBlock);
    access_.mutableOptions().maximumBlockBytes = originalMaximum;
    return parsed.layout.has_value();
  }
  const auto* constraint = blockConstraint(prefix.header);
  if (constraint == nullptr) {
    return false;
  }
  if (!constraint->selected) {
    return true;
  }
  const auto originalMaximum = access_.options().maximumBlockBytes;
  access_.mutableOptions().maximumBlockBytes =
      constraint->maximumBlockBytes == 0
          ? originalMaximum
          : std::min(constraint->maximumBlockBytes, originalMaximum);
  auto parsed = parseBlockLayoutImpl(access_, block.data,
                                     element.id == kSimpleBlock);
  access_.mutableOptions().maximumBlockBytes = originalMaximum;
  return parsed.layout.has_value();
}

bool Parser::emitSimpleBlock(const ElementHeader& header) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  if (header.encoded.size > access_.options().maximumEncodedBlockBytes) {
    return access_.fail(ParseError::BlockLimit, header.encoded.offset);
  }
  BlockPrefix prefix;
  if (!parseBlockPrefixImpl(access_, header.data, true, prefix)) {
    return false;
  }
  prefix.header.containerEncoded = header.encoded;
  prefix.header.blockEncoded = header.encoded;
  const auto* constraint = blockConstraint(prefix.header);
  if (constraint == nullptr) {
    return false;
  }
  if (!constraint->selected) {
    return true;
  }
  const auto originalMaximum = access_.options().maximumBlockBytes;
  access_.mutableOptions().maximumBlockBytes =
      constraint->maximumBlockBytes == 0
          ? originalMaximum
          : std::min(constraint->maximumBlockBytes, originalMaximum);
  auto parsed = parseBlockLayoutImpl(access_, header.data, true);
  access_.mutableOptions().maximumBlockBytes = originalMaximum;
  if (!parsed.layout) {
    return false;
  }
  parsed.layout->header.containerEncoded = header.encoded;
  parsed.layout->header.blockEncoded = header.encoded;
  const BlockGroupFields fields;
  return call(visitor_.onBlock(
                  parsed.layout->header,
                  std::span<const FrameRange>(parsed.layout->frames.data(),
                                              parsed.layout->frameCount),
                  fields, {}),
              header.encoded.offset);
}

ParseOutcome Parser::parseOneClusterChild(ByteRange clusterData,
                                           std::uint64_t childOffset) noexcept {
  std::uint64_t clusterEnd = 0;
  if (!checkedAdd(clusterData.offset, clusterData.size, clusterEnd) ||
      clusterEnd > access_.fileSize() || childOffset < clusterData.offset ||
      childOffset > clusterEnd) {
    access_.fail(ParseError::ParentBoundary, childOffset);
    return finish();
  }
  if (childOffset == clusterEnd) {
    auto outcome = finish();
    outcome.nextOffset = clusterEnd;
    return outcome;
  }
  ElementHeader childHeader;
  if (!child(childOffset, clusterEnd, 2, childHeader) ||
      !knownSize(childHeader)) {
    return finish();
  }
  if (isTopLevel(childHeader.id) || childHeader.id == kEbml ||
      childHeader.id == kSegment) {
    access_.fail(ParseError::UnexpectedElement, childOffset);
    return finish();
  }
  if (childHeader.id == kSimpleBlock) {
    static_cast<void>(emitSimpleBlock(childHeader));
  } else if (childHeader.id == kBlockGroup) {
    static_cast<void>(parseBlockGroup(childHeader, 2));
  }
  auto outcome = finish();
  if (outcome.ok()) {
    outcome.parsedRange = childHeader.encoded;
    outcome.nextOffset = rangeEnd(childHeader.encoded);
  }
  return outcome;
}

bool Parser::parseBlockGroup(const ElementHeader& header,
                             std::uint8_t depth) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  if (header.encoded.size > access_.options().maximumEncodedBlockBytes) {
    return access_.fail(ParseError::BlockLimit, header.encoded.offset);
  }
  std::optional<ElementHeader> blockElement;
  std::optional<BlockPrefix> blockPrefix;
  BlockGroupFields fields;
  std::array<std::int64_t, ParseOptions::kHardMaximumReferenceBlocks>
      references{};
  std::size_t referenceCount = 0;
  bool seenBlock = false;
  bool seenDuration = false;
  bool seenCodecState = false;
  bool seenBlockAdditions = false;
  bool seenDiscardPadding = false;
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kBlock) {
      if (seenBlock) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenBlock = true;
      if (field.encoded.size > access_.options().maximumEncodedBlockBytes) {
        return access_.fail(ParseError::BlockLimit, field.encoded.offset);
      }
      BlockPrefix prefix;
      if (!parseBlockPrefixImpl(access_, field.data, false, prefix)) {
        return false;
      }
      prefix.header.containerEncoded = header.encoded;
      prefix.header.blockEncoded = field.encoded;
      blockElement = field;
      blockPrefix = prefix;
    } else if (field.id == kBlockDuration) {
      if (seenDuration) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenDuration = true;
      std::uint64_t duration = 0;
      if (!readUnsigned(field, duration)) {
        return access_.active()
                   ? access_.fail(ParseError::InvalidValue, field.data.offset)
                   : false;
      }
      fields.duration = duration;
    } else if (field.id == kReferenceBlock) {
      if (referenceCount >= access_.options().maximumReferenceBlocks ||
          referenceCount >= references.size()) {
        return access_.fail(ParseError::BlockLimit, field.encoded.offset);
      }
      if (!readSigned(field, references[referenceCount])) {
        return false;
      }
      ++referenceCount;
    } else if (field.id == kCodecState) {
      if (seenCodecState) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenCodecState = true;
      if (field.data.size > access_.options().maximumCodecPrivateBytes) {
        return access_.fail(ParseError::BlockLimit, field.data.offset);
      }
      fields.codecState = field.data;
    } else if (field.id == kBlockAdditions) {
      if (seenBlockAdditions) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenBlockAdditions = true;
      fields.blockAdditionsPresent = true;
    } else if (field.id == kDiscardPadding) {
      if (seenDiscardPadding) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenDiscardPadding = true;
      std::int64_t padding = 0;
      if (!readSigned(field, padding)) {
        return false;
      }
      fields.discardPaddingNanoseconds = padding;
    }
    position = rangeEnd(field.encoded);
  }
  if (!seenBlock || !blockElement || !blockPrefix) {
    return access_.fail(ParseError::MissingElement, header.data.offset);
  }
  if (referenceCount > 1 &&
      std::find(references.begin(),
                references.begin() + static_cast<std::ptrdiff_t>(referenceCount),
                0) != references.begin() +
                          static_cast<std::ptrdiff_t>(referenceCount)) {
    return access_.fail(ParseError::InvalidValue, header.data.offset);
  }
  const auto* constraint = blockConstraint(blockPrefix->header);
  if (constraint == nullptr) {
    return false;
  }
  if (!constraint->selected) {
    return true;
  }
  const auto originalMaximum = access_.options().maximumBlockBytes;
  access_.mutableOptions().maximumBlockBytes =
      constraint->maximumBlockBytes == 0
          ? originalMaximum
          : std::min(constraint->maximumBlockBytes, originalMaximum);
  auto parsed = parseBlockLayoutImpl(access_, blockElement->data, false);
  access_.mutableOptions().maximumBlockBytes = originalMaximum;
  if (!parsed.layout) {
    return false;
  }
  parsed.layout->header.containerEncoded = header.encoded;
  parsed.layout->header.blockEncoded = blockElement->encoded;
  return call(visitor_.onBlock(
                  parsed.layout->header,
                  std::span<const FrameRange>(parsed.layout->frames.data(),
                                              parsed.layout->frameCount),
                  fields,
                  std::span<const std::int64_t>(references.data(),
                                                referenceCount)),
              header.encoded.offset);
}

bool Parser::parseCluster(const ElementHeader& header,
                          std::uint64_t segmentEnd, std::uint8_t depth,
                          std::uint64_t& actualEnd) noexcept {
  if (header.id != kCluster) {
    return access_.fail(ParseError::UnexpectedElement, header.encoded.offset);
  }
  if (!header.unknownSize && !access_.options().visitClusterBlocks &&
      !access_.options().scanClusterMetadata) {
    actualEnd = rangeEnd(header.encoded);
    Cluster cluster{header.encoded, header.data, std::nullopt, false};
    return call(visitor_.onCluster(cluster), header.encoded.offset);
  }

  const auto scanBoundary =
      header.unknownSize ? segmentEnd : rangeEnd(header.data);
  auto position = header.data.offset;
  std::optional<std::uint64_t> timestamp;
  while (position < scanBoundary) {
    ElementHeader field;
    if (!readHeader(access_, position, scanBoundary, field)) {
      return false;
    }
    if (header.unknownSize &&
        (isTopLevel(field.id) || field.id == kEbml ||
         field.id == kSegment) &&
        field.idWidth == 4) {
      break;
    }
    if (!header.unknownSize &&
        (isTopLevel(field.id) || field.id == kEbml || field.id == kSegment) &&
        field.idWidth == 4) {
      return access_.fail(ParseError::UnexpectedElement, field.encoded.offset);
    }
    if (!account(field, depth + 1) || !knownSize(field)) {
      return false;
    }
    if (field.id == kClusterTimestamp) {
      if (timestamp) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      std::uint64_t value = 0;
      if (field.data.size != 0 && !readUnsigned(field, value)) {
        return false;
      }
      timestamp = value;
    }
    position = rangeEnd(field.encoded);
  }
  if (!timestamp) {
    return access_.fail(ParseError::MissingElement, header.data.offset);
  }
  actualEnd = position;
  Cluster cluster = {header.encoded, header.data, timestamp,
                     header.unknownSize};
  if (header.unknownSize) {
    cluster.encoded.size = actualEnd - header.encoded.offset;
    cluster.data.size = actualEnd - header.data.offset;
  }
  if (!call(visitor_.onCluster(cluster), header.encoded.offset)) {
    return false;
  }
  if (!access_.options().visitClusterBlocks) {
    return true;
  }

  position = header.data.offset;
  while (position < actualEnd) {
    ElementHeader field;
    if (!readHeader(access_, position, actualEnd, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kSimpleBlock) {
      if (!emitSimpleBlock(field)) {
        return false;
      }
    } else if (field.id == kBlockGroup) {
      if (!parseBlockGroup(field, depth + 1)) {
        return false;
      }
    }
    position = rangeEnd(field.encoded);
  }
  return true;
}

bool Parser::parseCuePosition(const ElementHeader& header,
                              std::uint8_t depth,
                              CueTrackPosition& cue) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  enum Field : std::size_t {
    Track,
    ClusterPosition,
    RelativePosition,
    BlockNumber,
    CodecState,
    Count,
  };
  std::array<bool, Count> seen{};
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    Field identity = Count;
    std::uint64_t value = 0;
    if (field.id == kCueTrack) {
      identity = Track;
      if (!readUnsigned(field, cue.track)) return false;
    } else if (field.id == kCueClusterPosition) {
      identity = ClusterPosition;
      if (!readUnsigned(field, cue.clusterPosition)) return false;
    } else if (field.id == kCueRelativePosition) {
      identity = RelativePosition;
      if (!readUnsigned(field, value)) return false;
      cue.relativePosition = value;
    } else if (field.id == kCueBlockNumber) {
      identity = BlockNumber;
      if (!readUnsigned(field, value)) return false;
      cue.blockNumber = value;
    } else if (field.id == kCueCodecState) {
      identity = CodecState;
      if (!readUnsigned(field, cue.codecStatePosition)) return false;
    } else if (field.id == kCueReference) {
      cue.cueReferencePresent = true;
    }
    if (identity != Count) {
      if (seen[identity]) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seen[identity] = true;
    }
    position = rangeEnd(field.encoded);
  }
  if (!seen[Track] || !seen[ClusterPosition] || cue.track == 0 ||
      (cue.blockNumber && *cue.blockNumber == 0)) {
    return access_.fail(ParseError::MissingElement, header.data.offset);
  }
  return true;
}

bool Parser::prepareCueClusterDirectory(std::uint64_t segmentDataOffset,
                                        std::uint64_t segmentEnd,
                                        std::uint8_t depth,
                                        const std::vector<CueTrackPosition>&
                                            positions) {
  if (cue_cluster_directory_complete_ &&
      cue_cluster_directory_data_offset_ == segmentDataOffset &&
      cue_cluster_directory_end_ == segmentEnd) {
    return true;
  }
  cue_cluster_directory_.clear();
  cue_cluster_directory_data_offset_ = segmentDataOffset;
  cue_cluster_directory_end_ = segmentEnd;
  cue_cluster_directory_complete_ = false;
  std::vector<std::uint64_t> requestedOffsets;
  requestedOffsets.reserve(positions.size());
  for (const auto& cue : positions) {
    std::uint64_t absolute = 0;
    if (!checkedAdd(segmentDataOffset, cue.clusterPosition, absolute) ||
        absolute < segmentDataOffset || absolute >= segmentEnd) {
      return access_.fail(ParseError::ParentBoundary, segmentDataOffset);
    }
    requestedOffsets.push_back(absolute);
  }
  std::sort(requestedOffsets.begin(), requestedOffsets.end());
  requestedOffsets.erase(
      std::unique(requestedOffsets.begin(), requestedOffsets.end()),
      requestedOffsets.end());
  cue_cluster_directory_.reserve(requestedOffsets.size());
  std::size_t requested = 0;
  auto cursor = segmentDataOffset;
  while (cursor < segmentEnd && requested < requestedOffsets.size()) {
    ElementHeader candidate;
    if (!readHeader(access_, cursor, segmentEnd, candidate)) {
      return false;
    }
    if (candidate.id == kEbml || candidate.id == kSegment ||
        (!isGlobal(candidate.id) && candidate.idWidth != 4)) {
      return access_.fail(ParseError::UnexpectedElement,
                          candidate.encoded.offset);
    }
    if (!account(candidate, depth)) {
      return false;
    }
    auto next = rangeEnd(candidate.encoded);
    if (candidate.unknownSize) {
      if (candidate.id != kCluster ||
          !findUnknownClusterEnd(candidate, next)) {
        return access_.active()
                   ? access_.fail(ParseError::UnknownSizeNotAllowed,
                                  candidate.encoded.offset)
                   : false;
      }
    }
    if (candidate.id == kCluster) {
      if (requestedOffsets[requested] < candidate.encoded.offset) {
        return access_.fail(ParseError::InvalidValue,
                            requestedOffsets[requested]);
      }
      if (requestedOffsets[requested] == candidate.encoded.offset) {
        cue_cluster_directory_.push_back({candidate.encoded.offset, next});
        ++requested;
      }
    }
    if (next <= cursor) {
      return access_.fail(ParseError::InvalidValue, cursor);
    }
    cursor = next;
  }
  if (requested != requestedOffsets.size()) {
    return access_.fail(ParseError::InvalidValue,
                        requestedOffsets[requested]);
  }
  cue_cluster_directory_complete_ = true;
  return true;
}

bool Parser::lookupCueCluster(std::uint64_t requestedOffset,
                              ElementHeader& cluster) noexcept {
  const auto entry = std::lower_bound(
      cue_cluster_directory_.begin(), cue_cluster_directory_.end(),
      requestedOffset,
      [](const CueClusterDirectoryEntry& candidate, std::uint64_t offset) {
        return candidate.offset < offset;
      });
  if (entry == cue_cluster_directory_.end() ||
      entry->offset != requestedOffset) {
    return access_.fail(ParseError::InvalidValue, requestedOffset);
  }
  if (!readHeader(access_, entry->offset, entry->effectiveEnd, cluster) ||
      cluster.id != kCluster || cluster.idWidth != 4) {
    return access_.active()
               ? access_.fail(ParseError::InvalidValue, requestedOffset)
               : false;
  }
  cluster.encoded.size = entry->effectiveEnd - cluster.encoded.offset;
  cluster.data.size = entry->effectiveEnd - cluster.data.offset;
  return true;
}

bool Parser::collectCuePoint(const ElementHeader& header,
                             std::uint8_t depth,
                             std::vector<CueTrackPosition>& positions) {
  if (!knownSize(header)) {
    return false;
  }
  std::optional<std::uint64_t> cueTime;
  const auto firstPosition = positions.size();
  auto cursor = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (cursor < end) {
    ElementHeader field;
    if (!child(cursor, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kCueTime) {
      if (cueTime) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      std::uint64_t value = 0;
      if (!readUnsigned(field, value)) {
        return false;
      }
      cueTime = value;
    } else if (field.id == kCueTrackPositions) {
      if (positions.size() - firstPosition >=
              access_.options().maximumCueTrackPositionsPerPoint ||
          positions.size() >= access_.options().maximumCues) {
        return access_.fail(ParseError::CueLimit, field.encoded.offset);
      }
      positions.emplace_back();
      if (!parseCuePosition(field, depth + 1, positions.back())) {
        return false;
      }
    }
    cursor = rangeEnd(field.encoded);
  }
  if (!cueTime || positions.size() == firstPosition) {
    return access_.fail(ParseError::MissingElement, header.data.offset);
  }
  for (auto index = firstPosition; index < positions.size(); ++index) {
    positions[index].cueTime = *cueTime;
  }
  return true;
}

bool Parser::validateCuePositions(
    std::vector<CueTrackPosition>& positions,
    std::uint64_t segmentDataOffset, std::uint64_t segmentEnd) noexcept {
  for (std::size_t index = 0; index < positions.size(); ++index) {
    auto& cue = positions[index];
    if (track_table_complete_ &&
        std::find_if(track_constraints_.begin(),
                     track_constraints_.begin() + static_cast<std::ptrdiff_t>(
                                                        track_constraint_count_),
                     [&cue](const TrackConstraint& constraint) {
                       return constraint.number == cue.track;
                     }) ==
            track_constraints_.begin() +
                static_cast<std::ptrdiff_t>(track_constraint_count_)) {
      return access_.fail(ParseError::InvalidValue, segmentDataOffset);
    }
    if (!checkedAdd(segmentDataOffset, cue.clusterPosition,
                    cue.absoluteClusterOffset) ||
        cue.absoluteClusterOffset < segmentDataOffset ||
        cue.absoluteClusterOffset >= segmentEnd) {
      return access_.fail(ParseError::ParentBoundary, segmentDataOffset);
    }
    ElementHeader clusterHeader;
    if (!lookupCueCluster(cue.absoluteClusterOffset, clusterHeader)) {
      return false;
    }
    if (clusterHeader.id != kCluster || clusterHeader.idWidth != 4) {
      return access_.fail(ParseError::InvalidValue,
                          cue.absoluteClusterOffset);
    }
    if (clusterHeader.sizeWidth > maximum_size_length_) {
      return access_.fail(ParseError::InvalidVint,
                          cue.absoluteClusterOffset);
    }
    if (cue.relativePosition) {
      std::uint64_t absolute = 0;
      if (!checkedAdd(clusterHeader.data.offset, *cue.relativePosition,
                      absolute) ||
          absolute < clusterHeader.data.offset ||
          absolute >= rangeEnd(clusterHeader.data)) {
        return access_.fail(ParseError::ParentBoundary, segmentDataOffset);
      }
      cue.absoluteBlockOffset = absolute;
      ElementHeader block;
      std::uint64_t clusterEnd = rangeEnd(clusterHeader.data);
      if (!proveClusterChild(clusterHeader, absolute, block, clusterEnd)) {
        return false;
      }
      if ((block.id != kSimpleBlock && block.id != kBlockGroup) ||
          block.unknownSize || block.sizeWidth > maximum_size_length_) {
        return access_.fail(ParseError::InvalidValue, absolute);
      }
      if (!parseCueTargetBlock(
              block, cue.track,
              !access_.options().trackConstraints.empty())) {
        return false;
      }
    }
    ++cue_count_;
    if (cue_count_ > access_.options().maximumCues) {
      return access_.fail(ParseError::CueLimit, segmentDataOffset);
    }
  }
  return true;
}

bool Parser::validateCueCodecStates(
    std::vector<CueTrackPosition>& positions,
    std::uint64_t segmentDataOffset, std::uint64_t segmentEnd,
    std::uint8_t depth) {
  std::vector<std::size_t> pending;
  pending.reserve(positions.size());
  for (std::size_t index = 0; index < positions.size(); ++index) {
    if (positions[index].codecStatePosition == 0) {
      continue;
    }
    std::uint64_t absolute = 0;
    if (!checkedAdd(segmentDataOffset, positions[index].codecStatePosition,
                    absolute) ||
        absolute < segmentDataOffset || absolute >= segmentEnd) {
      return access_.fail(ParseError::ParentBoundary, segmentDataOffset);
    }
    positions[index].absoluteCodecStateOffset = absolute;
    pending.push_back(index);
  }
  if (pending.empty()) {
    return true;
  }
  std::sort(pending.begin(), pending.end(),
            [&positions](std::size_t lhs, std::size_t rhs) {
              return positions[lhs].absoluteCodecStateOffset <
                     positions[rhs].absoluteCodecStateOffset;
            });
  std::size_t requested = 0;
  auto segmentCursor = segmentDataOffset;
  while (segmentCursor < segmentEnd && requested < pending.size()) {
    ElementHeader topLevel;
    if (!child(segmentCursor, segmentEnd, depth, topLevel)) {
      return false;
    }
    if (topLevel.id == kEbml || topLevel.id == kSegment ||
        (!isGlobal(topLevel.id) && topLevel.idWidth != 4)) {
      return access_.fail(ParseError::UnexpectedElement,
                          topLevel.encoded.offset);
    }
    auto topLevelEnd = rangeEnd(topLevel.encoded);
    if (topLevel.unknownSize) {
      if (topLevel.id != kCluster ||
          !findUnknownClusterEnd(topLevel, topLevelEnd)) {
        return access_.active()
                   ? access_.fail(ParseError::UnknownSizeNotAllowed,
                                  topLevel.encoded.offset)
                   : false;
      }
    }
    const auto requestedOffset =
        *positions[pending[requested]].absoluteCodecStateOffset;
    if (requestedOffset < topLevel.encoded.offset) {
      return access_.fail(ParseError::ParentBoundary, requestedOffset);
    }
    if (requestedOffset >= topLevelEnd) {
      segmentCursor = topLevelEnd;
      continue;
    }
    if (topLevel.id != kCluster || requestedOffset < topLevel.data.offset) {
      return access_.fail(ParseError::ParentBoundary, requestedOffset);
    }
    auto clusterCursor = topLevel.data.offset;
    while (clusterCursor < topLevelEnd && requested < pending.size()) {
      ElementHeader clusterChild;
      if (!child(clusterCursor, topLevelEnd, depth + 1, clusterChild) ||
          !knownSize(clusterChild)) {
        return false;
      }
      if ((isTopLevel(clusterChild.id) || clusterChild.id == kEbml ||
           clusterChild.id == kSegment) &&
          clusterChild.idWidth == 4) {
        return access_.fail(ParseError::UnexpectedElement,
                            clusterChild.encoded.offset);
      }
      const auto clusterChildEnd = rangeEnd(clusterChild.encoded);
      const auto nextRequested =
          *positions[pending[requested]].absoluteCodecStateOffset;
      if (nextRequested < clusterChild.encoded.offset) {
        return access_.fail(ParseError::ParentBoundary, nextRequested);
      }
      if (nextRequested >= clusterChildEnd) {
        clusterCursor = clusterChildEnd;
        continue;
      }
      if (clusterChild.id != kBlockGroup ||
          nextRequested < clusterChild.data.offset) {
        return access_.fail(ParseError::ParentBoundary, nextRequested);
      }
      bool seenCodecState = false;
      auto groupCursor = clusterChild.data.offset;
      const auto groupEnd = rangeEnd(clusterChild.data);
      while (groupCursor < groupEnd) {
        ElementHeader groupChild;
        if (!child(groupCursor, groupEnd, depth + 2, groupChild) ||
            !knownSize(groupChild)) {
          return false;
        }
        const auto groupChildEnd = rangeEnd(groupChild.encoded);
        if (groupChild.id == kCodecState) {
          if (seenCodecState) {
            return access_.fail(ParseError::DuplicateElement,
                                groupChild.encoded.offset);
          }
          seenCodecState = true;
          if (groupChild.data.size >
                  access_.options().maximumCodecPrivateBytes ||
              groupChild.sizeWidth > maximum_size_length_) {
            return access_.fail(
                groupChild.data.size >
                        access_.options().maximumCodecPrivateBytes
                    ? ParseError::BlockLimit
                    : ParseError::InvalidVint,
                groupChild.encoded.offset);
          }
          while (requested < pending.size() &&
                 *positions[pending[requested]].absoluteCodecStateOffset ==
                     groupChild.encoded.offset) {
            ++requested;
          }
        }
        if (requested < pending.size() &&
            *positions[pending[requested]].absoluteCodecStateOffset >
                groupCursor &&
            *positions[pending[requested]].absoluteCodecStateOffset <
                groupChildEnd) {
          return access_.fail(
              ParseError::ParentBoundary,
              *positions[pending[requested]].absoluteCodecStateOffset);
        }
        groupCursor = groupChildEnd;
      }
      if (requested < pending.size() &&
          *positions[pending[requested]].absoluteCodecStateOffset <
              clusterChildEnd) {
        return access_.fail(
            ParseError::ParentBoundary,
            *positions[pending[requested]].absoluteCodecStateOffset);
      }
      clusterCursor = clusterChildEnd;
    }
    segmentCursor = topLevelEnd;
  }
  if (requested != pending.size()) {
    return access_.fail(
        ParseError::ParentBoundary,
        *positions[pending[requested]].absoluteCodecStateOffset);
  }
  return true;
}

bool Parser::parseCues(const ElementHeader& header,
                       std::uint64_t segmentDataOffset,
                       std::uint64_t segmentEnd,
                       std::uint8_t depth) noexcept {
  try {
  if (!knownSize(header)) {
    return false;
  }
  std::vector<CueTrackPosition> positions;
  positions.reserve(std::min(access_.options().maximumCues,
                             access_.options()
                                 .maximumCueTrackPositionsPerPoint));
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kCuePoint &&
        !collectCuePoint(field, depth + 1, positions)) {
      return false;
    }
    position = rangeEnd(field.encoded);
  }
  if (!prepareCueClusterDirectory(segmentDataOffset, segmentEnd, depth,
                                  positions)) {
    return false;
  }
  std::vector<std::size_t> validationOrder(positions.size());
  for (std::size_t index = 0; index < validationOrder.size(); ++index) {
    validationOrder[index] = index;
  }
  std::sort(validationOrder.begin(), validationOrder.end(),
            [&positions](std::size_t lhs, std::size_t rhs) {
              const auto& left = positions[lhs];
              const auto& right = positions[rhs];
              return std::tie(left.clusterPosition, left.relativePosition,
                              left.codecStatePosition) <
                     std::tie(right.clusterPosition, right.relativePosition,
                              right.codecStatePosition);
            });
  std::vector<CueTrackPosition> sortedPositions;
  sortedPositions.reserve(positions.size());
  for (const auto index : validationOrder) {
    sortedPositions.push_back(positions[index]);
  }
  if (!validateCuePositions(sortedPositions, segmentDataOffset, segmentEnd)) {
    return false;
  }
  for (std::size_t sorted = 0; sorted < validationOrder.size(); ++sorted) {
    positions[validationOrder[sorted]] = sortedPositions[sorted];
  }
  if (!validateCueCodecStates(positions, segmentDataOffset, segmentEnd,
                              depth)) {
    return false;
  }
  for (const auto& cue : positions) {
    if (!call(visitor_.onCueTrackPosition(cue), header.encoded.offset)) {
      return false;
    }
  }
  return true;
  } catch (const std::bad_alloc&) {
    return access_.fail(ParseError::CueLimit, header.encoded.offset);
  }
}

bool Parser::scanChapterChildren(const ElementHeader& header,
                                 std::uint8_t depth,
                                 ChapterFeatures& features) noexcept {
  if (!knownSize(header)) {
    return false;
  }
  bool seenOrdered = false;
  bool seenSegment = false;
  auto position = header.data.offset;
  const auto end = rangeEnd(header.data);
  while (position < end) {
    ElementHeader field;
    if (!child(position, end, depth + 1, field) || !knownSize(field)) {
      return false;
    }
    if (field.id == kEditionFlagOrdered) {
      if (seenOrdered) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenOrdered = true;
      bool ordered = false;
      if (!boolean(field, ordered)) {
        return false;
      }
      features.orderedEditionPresent |= ordered;
    } else if (field.id == kChapterSegmentUuid) {
      if (seenSegment) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenSegment = true;
      if (field.data.size != 16) {
        return access_.fail(ParseError::InvalidValue, field.data.offset);
      }
      features.linkedSegmentPresent = true;
    } else if (field.id == kEditionEntry || field.id == kChapterAtom) {
      if (!scanChapterChildren(field, depth + 1, features)) {
        return false;
      }
    }
    position = rangeEnd(field.encoded);
  }
  return true;
}

bool Parser::parseChapters(const ElementHeader& header,
                           std::uint8_t depth) noexcept {
  ChapterFeatures features;
  if (!scanChapterChildren(header, depth, features)) {
    return false;
  }
  return call(visitor_.onChapterFeatures(features), header.encoded.offset);
}

bool Parser::parseSegment(const ElementHeader& header,
                          std::uint32_t documentIndex,
                          std::uint64_t& actualEnd) noexcept {
  if (header.id != kSegment) {
    return access_.fail(ParseError::UnexpectedElement, header.encoded.offset);
  }
  ++segment_count_;
  track_count_ = 0;
  cue_count_ = 0;
  seek_count_ = 0;
  track_numbers_.fill(0);
  track_uids_.fill(0);
  cue_cluster_directory_.clear();
  cue_cluster_directory_complete_ = false;
  if (access_.options().trackConstraints.empty()) {
    track_constraint_count_ = 0;
    track_table_complete_ = false;
  }
  auto segmentEnd =
      header.unknownSize ? access_.fileSize() : rangeEnd(header.data);
  SegmentInfo segment{header.encoded, header.data, documentIndex,
                      segment_count_, header.unknownSize};
  if (header.unknownSize) {
    auto boundaryCursor = header.data.offset;
    while (boundaryCursor < segmentEnd) {
      ElementHeader candidate;
      if (!readHeader(access_, boundaryCursor, segmentEnd, candidate)) {
        return false;
      }
      if (candidate.id == kEbml && candidate.idWidth == 4) {
        segmentEnd = boundaryCursor;
        break;
      }
      if (candidate.id == kSegment ||
          (!isGlobal(candidate.id) && candidate.idWidth != 4) ||
          (candidate.unknownSize && candidate.id != kCluster)) {
        return access_.fail(candidate.unknownSize
                                ? ParseError::UnknownSizeNotAllowed
                                : ParseError::UnexpectedElement,
                            candidate.encoded.offset);
      }
      if (!account(candidate, 1)) {
        return false;
      }
      auto next = rangeEnd(candidate.encoded);
      if (candidate.unknownSize &&
          !findUnknownClusterEnd(candidate, next)) {
        return false;
      }
      if (next <= boundaryCursor) {
        return access_.fail(ParseError::InvalidValue, boundaryCursor);
      }
      boundaryCursor = next;
    }
    segment.encoded.size = segmentEnd - header.encoded.offset;
    segment.data.size = segmentEnd - header.data.offset;
  }
  if (!call(visitor_.onSegment(segment), header.encoded.offset)) {
    return false;
  }

  bool seenInfo = false;
  bool seenTracks = false;
  bool seenCues = false;
  bool seenChapters = false;
  if (!track_table_complete_) {
    bool tracksRequired = access_.options().visitClusterBlocks;
    auto discovery = header.data.offset;
    while (discovery < segmentEnd) {
      ElementHeader candidate;
      if (!readHeader(access_, discovery, segmentEnd, candidate)) {
        return false;
      }
      if (header.unknownSize && candidate.id == kEbml &&
          candidate.idWidth == 4) {
        break;
      }
      if (candidate.id == kEbml || candidate.id == kSegment ||
          (!isGlobal(candidate.id) && candidate.idWidth != 4)) {
        return access_.fail(ParseError::UnexpectedElement,
                            candidate.encoded.offset);
      }
      if (candidate.id == kTracks) {
        if (!account(candidate, 1) || !discoverTracks(candidate, 1)) {
          return false;
        }
        break;
      }
      if (candidate.id == kCues) {
        tracksRequired = true;
      }
      if (candidate.unknownSize) {
        if (candidate.id != kCluster) {
          return access_.fail(ParseError::UnknownSizeNotAllowed,
                              candidate.encoded.offset);
        }
        auto clusterCursor = candidate.data.offset;
        while (clusterCursor < segmentEnd) {
          ElementHeader clusterChild;
          if (!readHeader(access_, clusterCursor, segmentEnd, clusterChild)) {
            return false;
          }
          if ((isTopLevel(clusterChild.id) || clusterChild.id == kEbml ||
               clusterChild.id == kSegment) &&
              clusterChild.idWidth == 4) {
            break;
          }
          if (!account(clusterChild, 2) || !knownSize(clusterChild)) {
            return false;
          }
          clusterCursor = rangeEnd(clusterChild.encoded);
        }
        discovery = clusterCursor;
      } else {
        discovery = rangeEnd(candidate.encoded);
      }
    }
    if (tracksRequired && !track_table_complete_) {
      return access_.fail(ParseError::MissingElement, header.data.offset);
    }
  }
  auto position = header.data.offset;
  while (position < segmentEnd) {
    ElementHeader field;
    if (!readHeader(access_, position, segmentEnd, field)) {
      return false;
    }
    if (header.unknownSize && field.id == kEbml && field.idWidth == 4) {
      break;
    }
    if (field.id == kEbml || field.id == kSegment ||
        (!isGlobal(field.id) && field.idWidth != 4)) {
      return access_.fail(ParseError::UnexpectedElement,
                          field.encoded.offset);
    }
    if (!account(field, 1)) {
      return false;
    }
    if (field.unknownSize && field.id != kCluster) {
      return access_.fail(ParseError::UnknownSizeNotAllowed,
                          field.encoded.offset);
    }

    std::uint64_t fieldEnd = rangeEnd(field.encoded);
    if (field.id == kSeekHead) {
      if (!parseSeekHead(field, header.data.offset, segmentEnd, 1)) {
        return false;
      }
    } else if (field.id == kInfo) {
      if (seenInfo) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenInfo = true;
      if (!parseInfo(field, 1)) {
        return false;
      }
    } else if (field.id == kTracks) {
      if (seenTracks) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenTracks = true;
      const auto discoveredConstraints = track_constraints_;
      const auto discoveredConstraintCount = track_constraint_count_;
      const bool suppliedConstraints =
          !access_.options().trackConstraints.empty();
      track_count_ = 0;
      track_numbers_.fill(0);
      track_uids_.fill(0);
      if (!parseTracks(field, 1)) {
        return false;
      }
      if (track_table_complete_ || suppliedConstraints) {
        if (discoveredConstraintCount != track_constraint_count_) {
          return access_.fail(ParseError::InvalidValue,
                              field.data.offset);
        }
        for (std::size_t index = 0; index < track_constraint_count_; ++index) {
          const auto& declared = track_constraints_[index];
          const auto discovered = std::find_if(
              discoveredConstraints.begin(),
              discoveredConstraints.begin() + static_cast<std::ptrdiff_t>(
                                                  discoveredConstraintCount),
              [&declared](const TrackConstraint& candidate) {
                return candidate.number == declared.number;
              });
          if (discovered ==
                  discoveredConstraints.begin() +
                      static_cast<std::ptrdiff_t>(discoveredConstraintCount) ||
              discovered->lacingAllowed != declared.lacingAllowed) {
            return access_.fail(ParseError::InvalidValue,
                                field.data.offset);
          }
        }
        track_constraints_ = discoveredConstraints;
        track_constraint_count_ = discoveredConstraintCount;
        track_table_complete_ = true;
      }
    } else if (field.id == kCluster) {
      if (!parseCluster(field, segmentEnd, 1, fieldEnd)) {
        return false;
      }
    } else if (field.id == kCues) {
      if (seenCues) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenCues = true;
      if (!parseCues(field, header.data.offset, segmentEnd, 1)) {
        return false;
      }
    } else if (field.id == kChapters) {
      if (seenChapters) {
        return access_.fail(ParseError::DuplicateElement,
                            field.encoded.offset);
      }
      seenChapters = true;
      if (!parseChapters(field, 1)) {
        return false;
      }
    }
    if (fieldEnd <= position) {
      return access_.fail(ParseError::InvalidValue, position);
    }
    position = fieldEnd;
  }
  if (!seenInfo) {
    return access_.fail(ParseError::MissingElement, header.data.offset);
  }
  actualEnd = position;
  if (!header.unknownSize && actualEnd != segmentEnd) {
    return access_.fail(ParseError::ParentBoundary, actualEnd);
  }
  return true;
}

ParseOutcome Parser::parseDocuments() noexcept {
  if (access_.fileSize() == 0) {
    access_.fail(ParseError::Truncated, 0);
    return finish();
  }
  std::uint64_t position = 0;
  while (position < access_.fileSize() && access_.active()) {
    if (document_count_ >= access_.options().maximumDocuments) {
      access_.fail(ParseError::ElementLimit, position);
      return finish();
    }
    maximum_size_length_ = 8;
    ElementHeader ebml;
    if (!child(position, access_.fileSize(), 0, ebml) || ebml.id != kEbml ||
        ebml.idWidth != 4 || ebml.unknownSize) {
      if (access_.active()) {
        access_.fail(ParseError::UnexpectedElement, position);
      }
      return finish();
    }
    ++document_count_;
    if (!parseEbmlHeader(ebml)) {
      return finish();
    }
    position = rangeEnd(ebml.encoded);
    if (position >= access_.fileSize()) {
      access_.fail(ParseError::MissingElement, position);
      return finish();
    }
    ElementHeader segment;
    if (!child(position, access_.fileSize(), 0, segment) ||
        segment.id != kSegment || segment.idWidth != 4) {
      if (access_.active()) {
        access_.fail(ParseError::UnexpectedElement, position);
      }
      return finish();
    }
    std::uint64_t segmentEnd = position;
    if (!parseSegment(segment, document_count_, segmentEnd)) {
      return finish();
    }
    if (segmentEnd <= position) {
      access_.fail(ParseError::InvalidValue, position);
      return finish();
    }
    position = segmentEnd;
  }
  if (access_.active()) {
    const DocumentSummary summary{document_count_, segment_count_,
                                  document_count_ > 1};
    static_cast<void>(
        call(visitor_.onDocumentSummary(summary), access_.fileSize()));
  }
  return finish();
}

ParseOutcome Parser::parseOneMaster(std::uint64_t absoluteOffset,
                                    std::uint64_t parentEnd,
                                    std::uint64_t segmentDataOffset,
                                    MasterKind expected) noexcept {
  if (parentEnd > access_.fileSize() || absoluteOffset >= parentEnd ||
      segmentDataOffset > absoluteOffset || segmentDataOffset >= parentEnd) {
    access_.fail(ParseError::ParentBoundary, absoluteOffset);
    return finish();
  }
  standalone_master_ = absoluteOffset == segmentDataOffset;
  if (absoluteOffset != segmentDataOffset) {
    ElementHeader proven;
    if (!proveSegmentChild(segmentDataOffset, parentEnd, absoluteOffset,
                           proven)) {
      return finish();
    }
  }
  ElementHeader header;
  if (!child(absoluteOffset, parentEnd, 1, header)) {
    return finish();
  }
  if (header.id != idFor(expected) || header.idWidth != 4 ||
      (header.unknownSize && expected != MasterKind::Cluster)) {
    access_.fail(header.unknownSize ? ParseError::UnknownSizeNotAllowed
                                    : ParseError::UnexpectedElement,
                 absoluteOffset);
    return finish();
  }
  std::uint64_t unusedEnd = 0;
  switch (expected) {
    case MasterKind::SeekHead:
      static_cast<void>(
          parseSeekHead(header, segmentDataOffset, parentEnd, 1));
      break;
    case MasterKind::Info:
      static_cast<void>(parseInfo(header, 1));
      break;
    case MasterKind::Tracks:
      static_cast<void>(parseTracks(header, 1));
      break;
    case MasterKind::Cluster:
      static_cast<void>(parseCluster(header, parentEnd, 1, unusedEnd));
      break;
    case MasterKind::Cues:
      static_cast<void>(parseCues(header, segmentDataOffset, parentEnd, 1));
      break;
    case MasterKind::Chapters:
      static_cast<void>(parseChapters(header, 1));
      break;
  }
  auto outcome = finish();
  if (outcome.ok()) {
    auto parsedRange = header.encoded;
    if (expected == MasterKind::Cluster && header.unknownSize) {
      parsedRange.size = unusedEnd - header.encoded.offset;
    }
    outcome.parsedRange = parsedRange;
  }
  return outcome;
}

ParseOutcome Parser::parseOneSegmentChild(ByteRange segmentData,
                                          std::uint64_t absoluteOffset,
                                          MasterKind expected) noexcept {
  std::uint64_t segmentEnd = 0;
  standalone_master_ = false;
  if (!checkedAdd(segmentData.offset, segmentData.size, segmentEnd) ||
      segmentEnd > access_.fileSize()) {
    access_.fail(ParseError::ParentBoundary, segmentData.offset);
    return finish();
  }
  ElementHeader proven;
  if (!proveSegmentChild(segmentData.offset, segmentEnd, absoluteOffset,
                         proven) ||
      proven.id != idFor(expected)) {
    if (access_.active()) {
      access_.fail(ParseError::UnexpectedElement, absoluteOffset);
    }
    return finish();
  }
  if (proven.unknownSize && expected != MasterKind::Cluster) {
    access_.fail(ParseError::UnknownSizeNotAllowed, absoluteOffset);
    return finish();
  }
  std::uint64_t actualEnd = rangeEnd(proven.encoded);
  switch (expected) {
    case MasterKind::SeekHead:
      static_cast<void>(parseSeekHead(proven, segmentData.offset, segmentEnd, 1));
      break;
    case MasterKind::Info:
      static_cast<void>(parseInfo(proven, 1));
      break;
    case MasterKind::Tracks:
      static_cast<void>(parseTracks(proven, 1));
      break;
    case MasterKind::Cluster:
      static_cast<void>(parseCluster(proven, segmentEnd, 1, actualEnd));
      break;
    case MasterKind::Cues:
      static_cast<void>(parseCues(proven, segmentData.offset, segmentEnd, 1));
      break;
    case MasterKind::Chapters:
      static_cast<void>(parseChapters(proven, 1));
      break;
  }
  auto outcome = finish();
  if (outcome.ok()) {
    outcome.parsedRange =
        ByteRange{proven.encoded.offset, actualEnd - proven.encoded.offset};
  }
  return outcome;
}

SegmentChildScanOutcome Parser::scanNextSegmentChild(
    std::uint64_t nextOffset, std::uint64_t segmentEnd) noexcept {
  SegmentChildScanOutcome result;
  ElementHeader header;
  if (!child(nextOffset, segmentEnd, 1, header)) {
    result.outcome = finish();
    return result;
  }
  if (header.id == kEbml || header.id == kSegment ||
      (!isGlobal(header.id) && header.idWidth != 4)) {
    static_cast<void>(access_.fail(ParseError::UnexpectedElement,
                                   header.encoded.offset));
    result.outcome = finish();
    return result;
  }
  if (header.unknownSize && header.id != kCluster) {
    static_cast<void>(access_.fail(ParseError::UnknownSizeNotAllowed,
                                   header.encoded.offset));
    result.outcome = finish();
    return result;
  }
  auto effectiveEnd = rangeEnd(header.encoded);
  if (header.unknownSize && !findUnknownClusterEnd(header, effectiveEnd)) {
    result.outcome = finish();
    return result;
  }
  header.encoded.size = effectiveEnd - header.encoded.offset;
  header.data.size = effectiveEnd - header.data.offset;
  result.header = header;
  result.outcome = finish();
  result.outcome.parsedRange = header.encoded;
  result.outcome.nextOffset = effectiveEnd;
  return result;
}

ParseOutcome Parser::parseProvenSegmentChild(
    const ElementHeader& proof, ByteRange segmentData,
    MasterKind expected) noexcept {
  std::uint64_t encodedEnd = 0;
  if (!checkedAdd(proof.encoded.offset, proof.encoded.size, encodedEnd) ||
      encodedEnd > access_.fileSize() ||
      proof.data.offset < proof.encoded.offset || proof.data.offset > encodedEnd ||
      proof.data.size != encodedEnd - proof.data.offset) {
    access_.fail(ParseError::ParentBoundary, proof.encoded.offset);
    return finish();
  }
  std::uint64_t segmentEnd = 0;
  if (!checkedAdd(segmentData.offset, segmentData.size, segmentEnd) ||
      proof.encoded.offset < segmentData.offset ||
      encodedEnd > segmentEnd || segmentEnd > access_.fileSize()) {
    access_.fail(ParseError::ParentBoundary, proof.encoded.offset);
    return finish();
  }
  ElementHeader header;
  if (!child(proof.encoded.offset, encodedEnd, 1, header) ||
      header.id != proof.id || header.idWidth != proof.idWidth ||
      header.sizeWidth != proof.sizeWidth ||
      header.unknownSize != proof.unknownSize ||
      header.data.offset != proof.data.offset) {
    if (access_.active()) {
      static_cast<void>(access_.fail(ParseError::UnexpectedElement,
                                     proof.encoded.offset));
    }
    return finish();
  }
  header.encoded = proof.encoded;
  header.data = proof.data;
  std::uint64_t actualEnd = encodedEnd;
  switch (expected) {
    case MasterKind::SeekHead:
      static_cast<void>(parseSeekHead(header, segmentData.offset, segmentEnd,
                                      1));
      break;
    case MasterKind::Info:
      static_cast<void>(parseInfo(header, 1));
      break;
    case MasterKind::Tracks:
      static_cast<void>(parseTracks(header, 1));
      break;
    case MasterKind::Cluster:
      static_cast<void>(parseCluster(header, segmentEnd, 1, actualEnd));
      break;
    case MasterKind::Cues:
      static_cast<void>(parseCues(header, segmentData.offset, segmentEnd, 1));
      break;
    case MasterKind::Chapters:
      static_cast<void>(parseChapters(header, 1));
      break;
  }
  auto outcome = finish();
  if (outcome.ok()) {
    outcome.parsedRange = proof.encoded;
  }
  return outcome;
}

class DescriptorReader final : public SeekableByteReader {
 public:
  DescriptorReader(int descriptor, std::uint64_t size) noexcept
      : descriptor_(descriptor), size_(size) {}

  [[nodiscard]] std::uint64_t size() const noexcept override { return size_; }

  [[nodiscard]] bool
  readAt(std::uint64_t offset,
         std::span<std::byte> destination) noexcept override {
    if (offset > size_ || destination.size() > size_ - offset ||
        offset > static_cast<std::uint64_t>(
                     std::numeric_limits<off_t>::max())) {
      return false;
    }
    std::size_t completed = 0;
    while (completed < destination.size()) {
      const auto currentOffset = offset + completed;
      if (currentOffset > static_cast<std::uint64_t>(
                              std::numeric_limits<off_t>::max())) {
        return false;
      }
      const auto count = ::pread(
          descriptor_, destination.data() + static_cast<std::ptrdiff_t>(completed),
          destination.size() - completed, static_cast<off_t>(currentOffset));
      if (count < 0) {
        if (errno == EINTR) {
          continue;
        }
        return false;
      }
      if (count == 0) {
        return false;
      }
      completed += static_cast<std::size_t>(count);
    }
    return true;
  }

 private:
  int descriptor_{-1};
  std::uint64_t size_{0};
};

[[nodiscard]] ParseOptions cursorBounds(
    const ParseOptions& requested) noexcept {
  auto bounds = clampParseOptions(requested);
  // A cursor owns only scalar structural bounds. Selection spans remain a
  // phase-local input to parseSegmentChild()/parseClusterChildAt().
  bounds.trackConstraints = {};
  bounds.visitClusterBlocks = false;
  bounds.scanClusterMetadata = false;
  return bounds;
}

[[nodiscard]] ParseOptions optionsWithinCursorBounds(
    const ParseOptions& requested, const ParseOptions& bounds,
    std::size_t remainingElements) noexcept {
  auto result = clampParseOptions(requested);
  result.maximumReadBytes =
      std::min(result.maximumReadBytes, bounds.maximumReadBytes);
  result.maximumElementSizeWidth = std::min(
      result.maximumElementSizeWidth, bounds.maximumElementSizeWidth);
  result.maximumDepth = std::min(result.maximumDepth, bounds.maximumDepth);
  result.maximumTracks =
      std::min(result.maximumTracks, bounds.maximumTracks);
  result.maximumCodecPrivateBytes = std::min(
      result.maximumCodecPrivateBytes, bounds.maximumCodecPrivateBytes);
  result.maximumBlockBytes =
      std::min(result.maximumBlockBytes, bounds.maximumBlockBytes);
  result.maximumEncodedBlockBytes = std::min(
      result.maximumEncodedBlockBytes, bounds.maximumEncodedBlockBytes);
  result.maximumTrackTextBytes = std::min(
      result.maximumTrackTextBytes, bounds.maximumTrackTextBytes);
  result.maximumLaceFrames =
      std::min(result.maximumLaceFrames, bounds.maximumLaceFrames);
  result.maximumReferenceBlocks = std::min(
      result.maximumReferenceBlocks, bounds.maximumReferenceBlocks);
  result.maximumCueTrackPositionsPerPoint =
      std::min(result.maximumCueTrackPositionsPerPoint,
               bounds.maximumCueTrackPositionsPerPoint);
  result.maximumCues = std::min(result.maximumCues, bounds.maximumCues);
  result.maximumSeekEntries =
      std::min(result.maximumSeekEntries, bounds.maximumSeekEntries);
  result.maximumElements = std::min(
      {result.maximumElements, bounds.maximumElements, remainingElements});
  result.maximumDocuments =
      std::min(result.maximumDocuments, bounds.maximumDocuments);
  return result;
}

[[nodiscard]] std::uint64_t nextCursorCapability() noexcept {
  static std::atomic<std::uint64_t> next{1};
  auto value = next.fetch_add(1, std::memory_order_relaxed);
  if (value == 0) {
    value = next.fetch_add(1, std::memory_order_relaxed);
  }
  return value;
}

}  // namespace

ParseOutcome parseMasterAt(SeekableByteReader& reader,
                           std::uint64_t absoluteOffset,
                           std::uint64_t parentEnd,
                           std::uint64_t segmentDataOffset,
                           MasterKind expected, Visitor& visitor,
                           const ParseOptions& options,
                           CancellationToken cancellation) noexcept {
  auto targetedOptions = clampParseOptions(options);
  if (expected == MasterKind::Cluster) {
    targetedOptions.scanClusterMetadata = true;
  }
  Parser parser(reader, visitor, targetedOptions, cancellation);
  return parser.parseOneMaster(absoluteOffset, parentEnd, segmentDataOffset,
                               expected);
}

ParseOutcome parseSegmentChildAt(SeekableByteReader& reader,
                                 ByteRange segmentData,
                                 std::uint64_t absoluteOffset,
                                 MasterKind expected, Visitor& visitor,
                                 const ParseOptions& options,
                                 CancellationToken cancellation) noexcept {
  auto targetedOptions = clampParseOptions(options);
  if (expected == MasterKind::Cluster) {
    targetedOptions.scanClusterMetadata = true;
  }
  Parser parser(reader, visitor, targetedOptions, cancellation);
  return parser.parseOneSegmentChild(segmentData, absoluteOffset, expected);
}

std::optional<SegmentChildCursor> beginSegmentChildCursor(
    SeekableByteReader& reader, ByteRange segmentData,
    const ParseOptions& options) noexcept {
  std::uint64_t segmentEnd = 0;
  if (!checkedAdd(segmentData.offset, segmentData.size, segmentEnd) ||
      segmentEnd > reader.size()) {
    return std::nullopt;
  }
  auto bounds = cursorBounds(options);
  return SegmentChildCursor(reader, segmentData, segmentEnd, bounds,
                            nextCursorCapability());
}

SegmentChildOutcome readNextSegmentChild(
    SeekableByteReader& reader, SegmentChildCursor& cursor,
    const ParseOptions& options,
    CancellationToken cancellation) noexcept {
  SegmentChildOutcome result;
  if (cursor.reader_identity_ != &reader ||
      cursor.reader_size_ != reader.size()) {
    result.outcome = {ParseStatus::IoError, ParseError::FileChanged,
                      cursor.next_offset_, 0, 0, std::nullopt, std::nullopt};
    return result;
  }
  if (cursor.next_offset_ < cursor.segment_data_.offset ||
      cursor.next_offset_ > cursor.segment_end_ ||
      cursor.segment_end_ > reader.size()) {
    result.outcome = {ParseStatus::Invalid, ParseError::ParentBoundary,
                      cursor.next_offset_, 0, 0, std::nullopt, std::nullopt};
    return result;
  }
  if (cursor.next_offset_ == cursor.segment_end_) {
    result.outcome = {ParseStatus::Complete, ParseError::None,
                      cursor.next_offset_, 0, 0, std::nullopt,
                      cursor.next_offset_};
    return result;
  }
  if (cursor.remaining_elements_ == 0) {
    result.outcome = {ParseStatus::LimitExceeded, ParseError::ElementLimit,
                      cursor.next_offset_, 0, 0, std::nullopt, std::nullopt};
    return result;
  }

  auto targetedOptions = optionsWithinCursorBounds(
      options, cursor.bounds_, cursor.remaining_elements_);
  Visitor visitor;
  Parser parser(reader, visitor, targetedOptions, cancellation);
  auto scanned = parser.scanNextSegmentChild(cursor.next_offset_,
                                             cursor.segment_end_);
  const auto visited =
      std::min(parser.elementsVisited(), cursor.remaining_elements_);
  cursor.remaining_elements_ -= visited;
  result.outcome = scanned.outcome;
  if (reader.size() != cursor.reader_size_) {
    result.outcome = {ParseStatus::IoError, ParseError::FileChanged,
                      cursor.next_offset_, 0, 0, std::nullopt, std::nullopt};
    return result;
  }
  if (scanned.outcome.ok() && scanned.header &&
      scanned.outcome.nextOffset &&
      *scanned.outcome.nextOffset > cursor.next_offset_ &&
      *scanned.outcome.nextOffset <= cursor.segment_end_) {
    const auto& header = *scanned.header;
    SegmentChild child;
    child.id_ = header.id;
    child.kind_ = kindFor(header.id);
    child.encoded_ = header.encoded;
    child.data_ = header.data;
    child.id_width_ = header.idWidth;
    child.size_width_ = header.sizeWidth;
    child.unknown_size_ = header.unknownSize;
    child.segment_data_ = cursor.segment_data_;
    child.reader_identity_ = &reader;
    child.reader_size_ = cursor.reader_size_;
    child.cursor_capability_ = cursor.capability_;
    result.child.emplace(child);
    cursor.next_offset_ = *scanned.outcome.nextOffset;
  }
  return result;
}

ParseOutcome parseSegmentChild(SeekableByteReader& reader,
                               SegmentChildCursor& cursor,
                               const SegmentChild& child,
                               MasterKind expected, Visitor& visitor,
                               const ParseOptions& options,
                               CancellationToken cancellation) noexcept {
  if (cursor.reader_identity_ != &reader ||
      child.reader_identity_ != &reader ||
      cursor.reader_size_ != reader.size() ||
      child.reader_size_ != reader.size()) {
    return {ParseStatus::IoError, ParseError::FileChanged,
            child.encoded_.offset, 0, 0, std::nullopt, std::nullopt};
  }
  if (child.cursor_capability_ == 0 ||
      child.cursor_capability_ != cursor.capability_) {
    return {ParseStatus::Invalid, ParseError::UnexpectedElement,
            child.encoded_.offset, 0, 0, std::nullopt, std::nullopt};
  }
  if (child.kind_ != expected || child.id_ != idFor(expected) ||
      child.id_width_ != 4 ||
      (child.unknown_size_ && expected != MasterKind::Cluster)) {
    return {ParseStatus::Invalid,
            child.unknown_size_ ? ParseError::UnknownSizeNotAllowed
                                : ParseError::UnexpectedElement,
            child.encoded_.offset, 0, 0, std::nullopt, std::nullopt};
  }
  std::uint64_t encodedEnd = 0;
  if (!checkedAdd(child.encoded_.offset, child.encoded_.size, encodedEnd) ||
      encodedEnd > reader.size() || child.data_.offset < child.encoded_.offset ||
      child.data_.offset > encodedEnd ||
      child.data_.size != encodedEnd - child.data_.offset ||
      child.segment_data_.offset != cursor.segment_data_.offset ||
      child.segment_data_.size != cursor.segment_data_.size ||
      child.segment_data_.offset > child.encoded_.offset ||
      child.segment_data_.size >
          reader.size() - child.segment_data_.offset) {
    return {ParseStatus::Invalid, ParseError::ParentBoundary,
            child.encoded_.offset, 0, 0, std::nullopt, std::nullopt};
  }
  if (cursor.remaining_elements_ == 0) {
    return {ParseStatus::LimitExceeded, ParseError::ElementLimit,
            child.encoded_.offset, 0, 0, std::nullopt, std::nullopt};
  }
  auto targetedOptions = optionsWithinCursorBounds(
      options, cursor.bounds_, cursor.remaining_elements_);
  if (expected == MasterKind::Cluster) {
    targetedOptions.scanClusterMetadata = true;
  }
  Parser parser(reader, visitor, targetedOptions, cancellation);
  const ElementHeader proof{child.id_, child.encoded_, child.data_,
                            child.id_width_, child.size_width_,
                            child.unknown_size_};
  auto outcome =
      parser.parseProvenSegmentChild(proof, child.segment_data_, expected);
  const auto visited =
      std::min(parser.elementsVisited(), cursor.remaining_elements_);
  cursor.remaining_elements_ -= visited;
  if (reader.size() != cursor.reader_size_) {
    outcome.status = ParseStatus::IoError;
    outcome.error = ParseError::FileChanged;
    outcome.offset = child.encoded_.offset;
    outcome.parsedRange.reset();
    outcome.nextOffset.reset();
  }
  return outcome;
}

std::optional<ClusterChildCursor> beginClusterChildCursor(
    SeekableByteReader& reader, ByteRange clusterData,
    const ParseOptions& options) noexcept {
  std::uint64_t clusterEnd = 0;
  if (!checkedAdd(clusterData.offset, clusterData.size, clusterEnd) ||
      clusterEnd > reader.size()) {
    return std::nullopt;
  }
  auto bounds = cursorBounds(options);
  return ClusterChildCursor(reader, clusterData, clusterEnd, bounds);
}

ParseOutcome parseClusterChildAt(SeekableByteReader& reader,
                                 ClusterChildCursor& cursor,
                                 Visitor& visitor,
                                 const ParseOptions& options,
                                 CancellationToken cancellation) noexcept {
  if (cursor.reader_identity_ != &reader ||
      cursor.reader_size_ != reader.size()) {
    return {ParseStatus::IoError, ParseError::FileChanged,
            cursor.next_offset_, 0, 0, std::nullopt, std::nullopt};
  }
  if (cursor.next_offset_ < cursor.cluster_data_.offset ||
      cursor.next_offset_ > cursor.cluster_end_ ||
      cursor.cluster_end_ > reader.size()) {
    return {ParseStatus::Invalid, ParseError::ParentBoundary,
            cursor.next_offset_, 0, 0, std::nullopt, std::nullopt};
  }
  if (cursor.next_offset_ == cursor.cluster_end_) {
    return {ParseStatus::Complete, ParseError::None, cursor.next_offset_, 0, 0,
            std::nullopt, cursor.next_offset_};
  }
  if (cursor.remaining_elements_ == 0) {
    return {ParseStatus::LimitExceeded, ParseError::ElementLimit,
            cursor.next_offset_, 0, 0, std::nullopt, std::nullopt};
  }
  auto targetedOptions = optionsWithinCursorBounds(
      options, cursor.bounds_, cursor.remaining_elements_);
  Parser parser(reader, visitor, targetedOptions, cancellation);
  auto outcome =
      parser.parseOneClusterChild(cursor.cluster_data_, cursor.next_offset_);
  const auto visited =
      std::min(parser.elementsVisited(), cursor.remaining_elements_);
  cursor.remaining_elements_ -= visited;
  if (reader.size() != cursor.reader_size_) {
    return {ParseStatus::IoError, ParseError::FileChanged,
            cursor.next_offset_, 0, 0, std::nullopt, std::nullopt};
  }
  if (outcome.ok() && outcome.nextOffset &&
      *outcome.nextOffset > cursor.next_offset_ &&
      *outcome.nextOffset <= cursor.cluster_end_) {
    cursor.next_offset_ = *outcome.nextOffset;
  }
  return outcome;
}

ParseOutcome parseDocument(SeekableByteReader& reader, Visitor& visitor,
                           const ParseOptions& options,
                           CancellationToken cancellation) noexcept {
  Parser parser(reader, visitor, clampParseOptions(options), cancellation);
  return parser.parseDocuments();
}

ParseOutcome parseFile(const std::filesystem::path& path, Visitor& visitor,
                       const ParseOptions& options,
                       CancellationToken cancellation) noexcept {
  const int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (descriptor < 0) {
    return {ParseStatus::IoError, ParseError::ReadFailed, 0, 0, 0,
            std::nullopt, std::nullopt};
  }
  struct DescriptorCloser {
    int descriptor;
    ~DescriptorCloser() { static_cast<void>(::close(descriptor)); }
  } closer{descriptor};

  struct stat before {};
  if (::fstat(descriptor, &before) != 0 || !S_ISREG(before.st_mode) ||
      before.st_size < 0) {
    return {ParseStatus::IoError, ParseError::ReadFailed, 0, 0, 0,
            std::nullopt, std::nullopt};
  }
  ParseOutcome outcome;
  {
    DescriptorReader reader(descriptor,
                            static_cast<std::uint64_t>(before.st_size));
    outcome = parseDocument(reader, visitor, options, cancellation);
  }

  struct stat after {};
  if (::fstat(descriptor, &after) != 0) {
    outcome.status = ParseStatus::IoError;
    outcome.error = ParseError::ReadFailed;
    outcome.offset = 0;
    return outcome;
  }
  if (before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
      before.st_size != after.st_size) {
    outcome.status = ParseStatus::IoError;
    outcome.error = ParseError::FileChanged;
    outcome.offset = 0;
  }
  return outcome;
}

}  // namespace wam::media::matroska
