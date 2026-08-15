#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>

namespace wam::media::matroska {

// Phase-A Matroska parsing is deliberately independent of Apple and Qt
// frameworks. Readers must either fill the complete destination or return
// false. The parser never requests more than kHardMaximumReadBytes at once.
class SeekableByteReader {
 public:
  virtual ~SeekableByteReader() = default;
  [[nodiscard]] virtual std::uint64_t size() const noexcept = 0;
  [[nodiscard]] virtual bool
  readAt(std::uint64_t offset, std::span<std::byte> destination) noexcept = 0;
};

struct CancellationToken {
  const void* context{nullptr};
  bool (*probe)(const void*) noexcept{nullptr};

  [[nodiscard]] bool cancelled() const noexcept {
    return probe != nullptr && probe(context);
  }
};

struct ByteRange {
  std::uint64_t offset{0};
  std::uint64_t size{0};

  friend constexpr bool operator==(ByteRange, ByteRange) = default;
};

enum class VintKind : std::uint8_t {
  ElementId,
  ElementSize,
  UnsignedValue,
  SignedLacingValue,
};

enum class VintStatus : std::uint8_t {
  Ready,
  NeedMoreBytes,
  Invalid,
};

struct VintValue {
  std::uint64_t value{0};
  std::int64_t signedValue{0};
  std::uint8_t width{0};
  bool unknown{false};
};

struct VintOutcome {
  VintStatus status{VintStatus::Invalid};
  VintValue vint;
};

// Pure, allocation-free VINT decoding. Element IDs preserve their marker bit;
// all other forms expose VINT_DATA with the marker removed. The input may be
// larger than one VINT; `width` says exactly how many bytes were consumed.
[[nodiscard]] VintOutcome decodeVint(std::span<const std::byte> input,
                                     VintKind kind) noexcept;

enum class ParseStatus : std::uint8_t {
  Complete,
  Stopped,
  Cancelled,
  Invalid,
  Unsupported,
  LimitExceeded,
  IoError,
  VisitorRejected,
};

enum class ParseError : std::uint8_t {
  None,
  Cancelled,
  ReadFailed,
  FileChanged,
  Truncated,
  InvalidVint,
  InvalidElementId,
  UnknownSizeNotAllowed,
  ParentBoundary,
  DepthLimit,
  ElementLimit,
  TrackLimit,
  CueLimit,
  BlockLimit,
  TextLimit,
  DuplicateElement,
  MissingElement,
  UnexpectedElement,
  InvalidValue,
  UnsupportedVersion,
  VisitorRejected,
};

struct ParseOutcome {
  ParseStatus status{ParseStatus::Invalid};
  ParseError error{ParseError::InvalidValue};
  std::uint64_t offset{0};
  std::uint32_t documents{0};
  std::uint32_t segments{0};
  // Exact effective range of a successfully targeted master. This differs
  // from its provisional encoded range when a Segment or Cluster uses an
  // unknown size and terminates at a schema-valid sibling.
  std::optional<ByteRange> parsedRange;
  // For parseClusterChildAt(), the exclusive end of parsedRange and therefore
  // the only continuation offset a caller should pass to its next step.
  std::optional<std::uint64_t> nextOffset;

  [[nodiscard]] constexpr bool ok() const noexcept {
    return status == ParseStatus::Complete || status == ParseStatus::Stopped;
  }
};

struct TrackConstraint {
  std::uint64_t number{0};
  bool lacingAllowed{true};
  // Unselected Blocks are structurally identified from a bounded prefix and
  // skipped without lacing/frame parsing or a callback.
  bool selected{true};
  // Selected-track per-frame cap. Zero inherits ParseOptions' cap.
  std::size_t maximumBlockBytes{0};
};

struct ParseOptions {
  static constexpr std::size_t kHardMaximumReadBytes{64U * 1024U};
  static constexpr std::uint8_t kHardMaximumDepth{8};
  static constexpr std::size_t kHardMaximumLaceFrames{256};
  static constexpr std::size_t kHardMaximumReferenceBlocks{16};
  static constexpr std::size_t kHardMaximumCueTrackPositionsPerPoint{64};
  static constexpr std::size_t kHardMaximumCues{65'536};
  // Cues validation uses three bounded, temporary arrays (file order,
  // validation order, and sorted values) and releases them before return.
  // This byte ceiling is charged from conservative per-entry storage rather
  // than an ABI-dependent sizeof(CueTrackPosition).
  static constexpr std::size_t kHardMaximumCueValidationBytes{
      kHardMaximumCues * 256U};
  static constexpr std::size_t kHardMaximumSeekEntries{4'096};
  static constexpr std::size_t kHardMaximumElements{1'000'000};
  static constexpr std::uint64_t kHardMaximumEncodedBlockBytes{
      512ULL * 1024ULL * 1024ULL};
  static constexpr std::uint32_t kHardMaximumDocuments{4};

  std::size_t maximumReadBytes{kHardMaximumReadBytes};
  // Targeted parseMasterAt callers set this from the already parsed EBML
  // Header. Full-document parsing updates it at each document boundary.
  std::uint8_t maximumElementSizeWidth{8};
  std::uint8_t maximumDepth{kHardMaximumDepth};
  std::size_t maximumTracks{MediaSourceLimits::kHardMaximumTracks};
  std::size_t maximumCodecPrivateBytes{
      MediaSourceLimits::kHardMaximumCodecConfigurationBytes};
  // Maximum bytes in each emitted FrameRange. Encoded aggregate Block size is
  // governed separately by maximumEncodedBlockBytes.
  std::size_t maximumBlockBytes{
      MediaSourceLimits::kHardMaximumVideoSampleBytes};
  // Applies to the encoded SimpleBlock/BlockGroup container for every track,
  // including unselected tracks; it is distinct from selected payload caps.
  std::uint64_t maximumEncodedBlockBytes{kHardMaximumEncodedBlockBytes};
  std::size_t maximumTrackTextBytes{
      MediaSourceLimits::kHardMaximumTrackTextBytes};
  std::size_t maximumLaceFrames{kHardMaximumLaceFrames};
  std::size_t maximumReferenceBlocks{kHardMaximumReferenceBlocks};
  std::size_t maximumCueTrackPositionsPerPoint{
      kHardMaximumCueTrackPositionsPerPoint};
  std::size_t maximumCues{kHardMaximumCues};
  std::size_t maximumSeekEntries{kHardMaximumSeekEntries};
  std::size_t maximumElements{kHardMaximumElements};
  std::uint32_t maximumDocuments{kHardMaximumDocuments};
  // Targeted Cluster callers supply the constraints collected from Tracks.
  // Full-document parsing populates the same fixed table internally.
  std::span<const TrackConstraint> trackConstraints{};
  // Metadata discovery leaves known-sized Cluster payloads untouched. A
  // demuxer opts in when parsing one selected Cluster via parseMasterAt().
  bool visitClusterBlocks{false};
  // Internal/public targeted behavior: inspect mandatory Cluster metadata and
  // direct-child boundaries while skipping every block payload/layout.
  bool scanClusterMetadata{false};
};

[[nodiscard]] ParseOptions
clampParseOptions(const ParseOptions& requested) noexcept;

struct ElementHeader {
  std::uint32_t id{0};
  ByteRange encoded;
  ByteRange data;
  std::uint8_t idWidth{0};
  std::uint8_t sizeWidth{0};
  bool unknownSize{false};
};

struct ElementHeaderOutcome {
  ParseOutcome outcome;
  std::optional<ElementHeader> header;
};

// Reads only the ID and size VINTs and proves the resulting data range is
// inside both parentEnd and reader.size(). Unknown size is represented by the
// remainder of the supplied parent boundary and remains explicitly tagged.
[[nodiscard]] ElementHeaderOutcome readElementHeader(
    SeekableByteReader& reader, std::uint64_t offset,
    std::uint64_t parentEnd, CancellationToken cancellation = {}) noexcept;

enum class Lacing : std::uint8_t {
  None,
  Xiph,
  Fixed,
  Ebml,
};

struct FrameRange {
  ByteRange bytes;

  friend constexpr bool operator==(FrameRange, FrameRange) = default;
};

struct BlockHeader {
  // containerEncoded is the direct Cluster child: SimpleBlock or BlockGroup.
  // blockEncoded is the SimpleBlock itself or the nested Block element.
  ByteRange containerEncoded;
  ByteRange blockEncoded;
  ByteRange elementData;
  std::uint64_t trackNumber{0};
  std::int16_t relativeTimestamp{0};
  Lacing lacing{Lacing::None};
  bool simpleBlock{false};
  bool keyFrame{false};
  bool invisible{false};
  bool discardable{false};
};

struct BlockLayout {
  BlockHeader header;
  std::array<FrameRange, ParseOptions::kHardMaximumLaceFrames> frames{};
  std::uint16_t frameCount{0};
};

struct BlockLayoutOutcome {
  ParseOutcome outcome;
  std::optional<BlockLayout> layout;
};

// Parses only a Block/SimpleBlock payload. Frame ranges point back into the
// supplied reader; frame bytes are never copied or retained.
[[nodiscard]] BlockLayoutOutcome parseBlockLayout(
    SeekableByteReader& reader, ByteRange blockData, bool simpleBlock,
    const ParseOptions& options = {},
    CancellationToken cancellation = {}) noexcept;

enum class VisitorAction : std::uint8_t {
  Continue,
  Stop,
  Reject,
};

struct EbmlHeader {
  std::uint64_t ebmlVersion{1};
  std::uint64_t ebmlReadVersion{1};
  std::uint64_t maximumIdLength{4};
  std::uint64_t maximumSizeLength{8};
  std::uint64_t documentTypeVersion{1};
  std::uint64_t documentTypeReadVersion{1};
  bool documentTypeExtensionPresent{false};
};

struct SegmentInfo {
  ByteRange encoded;
  ByteRange data;
  std::uint32_t documentIndex{0};
  std::uint32_t segmentIndex{0};
  bool unknownSize{false};
};

struct SeekEntry {
  std::uint32_t targetId{0};
  std::uint64_t relativePosition{0};
  std::uint64_t absoluteTargetOffset{0};
  ByteRange targetEncoded;
  bool targetUnknownSize{false};
};

struct Info {
  std::uint64_t timestampScaleNanoseconds{1'000'000};
  std::optional<double> durationTicks;
  bool previousSegmentPresent{false};
  bool nextSegmentPresent{false};
};

struct VideoColour {
  std::optional<std::uint64_t> matrixCoefficients;
  std::optional<std::uint64_t> bitsPerChannel;
  std::optional<std::uint64_t> chromaSubsamplingHorizontal;
  std::optional<std::uint64_t> chromaSubsamplingVertical;
  std::optional<std::uint64_t> cbSubsamplingHorizontal;
  std::optional<std::uint64_t> cbSubsamplingVertical;
  std::optional<std::uint64_t> chromaSitingHorizontal;
  std::optional<std::uint64_t> chromaSitingVertical;
  std::optional<std::uint64_t> range;
  std::optional<std::uint64_t> transferCharacteristics;
  std::optional<std::uint64_t> primaries;
  std::optional<std::uint64_t> maximumContentLightLevel;
  std::optional<std::uint64_t> maximumFrameAverageLightLevel;
  bool masteringMetadataPresent{false};
};

struct Video {
  std::optional<std::uint64_t> pixelWidth;
  std::optional<std::uint64_t> pixelHeight;
  std::uint64_t cropBottom{0};
  std::uint64_t cropTop{0};
  std::uint64_t cropLeft{0};
  std::uint64_t cropRight{0};
  std::optional<std::uint64_t> displayWidth;
  std::optional<std::uint64_t> displayHeight;
  std::uint64_t displayUnit{0};
  std::uint64_t interlaced{0};
  std::uint64_t fieldOrder{2};
  std::uint64_t stereoMode{0};
  std::uint64_t alphaMode{0};
  VideoColour colour;
  bool projectionPresent{false};
};

struct Audio {
  double samplingFrequency{8'000.0};
  std::optional<double> outputSamplingFrequency;
  std::uint64_t channels{1};
  std::optional<std::uint64_t> bitDepth;
};

struct InlineAscii {
  static constexpr std::size_t kCapacity{64};
  std::array<char, kCapacity> bytes{};
  std::uint8_t size{0};

  [[nodiscard]] std::span<const char> view() const noexcept {
    return {bytes.data(), size};
  }
};

struct TrackEntry {
  ByteRange encoded;
  std::uint64_t number{0};
  std::uint64_t uid{0};
  std::uint64_t type{0};
  bool enabled{true};
  bool defaultTrack{true};
  bool forced{false};
  bool lacingAllowed{true};
  std::optional<std::uint64_t> defaultDurationNanoseconds;
  double timestampScale{1.0};
  std::uint64_t codecDelayNanoseconds{0};
  std::uint64_t seekPreRollNanoseconds{0};
  std::int64_t timestampOffsetNanoseconds{0};
  bool timestampOffsetPresent{false};
  InlineAscii codecId;
  InlineAscii language;
  std::optional<ByteRange> name;
  std::optional<ByteRange> codecPrivate;
  std::optional<Video> video;
  std::optional<Audio> audio;
  bool contentEncodingsPresent{false};
  bool trackOperationPresent{false};
  bool blockAdditionMappingPresent{false};
};

struct Cluster {
  ByteRange encoded;
  ByteRange data;
  std::optional<std::uint64_t> timestamp;
  bool unknownSize{false};
};

struct BlockGroupFields {
  std::optional<std::uint64_t> duration;
  std::optional<ByteRange> codecState;
  std::optional<std::int64_t> discardPaddingNanoseconds;
  bool blockAdditionsPresent{false};
};

struct CueTrackPosition {
  std::uint64_t cueTime{0};
  std::uint64_t track{0};
  std::uint64_t clusterPosition{0};
  std::uint64_t absoluteClusterOffset{0};
  std::optional<std::uint64_t> relativePosition;
  // Present only when CueRelativePosition was present and checked.
  std::optional<std::uint64_t> absoluteBlockOffset;
  std::optional<std::uint64_t> blockNumber;
  std::uint64_t codecStatePosition{0};
  std::optional<std::uint64_t> absoluteCodecStateOffset;
  bool cueReferencePresent{false};
};

struct ChapterFeatures {
  bool orderedEditionPresent{false};
  bool linkedSegmentPresent{false};
};

struct DocumentSummary {
  std::uint32_t documentCount{0};
  std::uint32_t segmentCount{0};
  bool trailingDocumentsPresent{false};
};

class Visitor {
 public:
  virtual ~Visitor() = default;
  // Every reference passed to a callback, including references nested in a
  // callback argument, is valid only until that callback returns. Copy any
  // value or ByteRange that must outlive the call. ByteRange values describe
  // stable bytes owned by SeekableByteReader; no payload is borrowed here.
  virtual VisitorAction onEbmlHeader(const EbmlHeader&) noexcept {
    return VisitorAction::Continue;
  }
  virtual VisitorAction onSegment(const SegmentInfo&) noexcept {
    return VisitorAction::Continue;
  }
  virtual VisitorAction onSeekEntry(const SeekEntry&) noexcept {
    return VisitorAction::Continue;
  }
  virtual VisitorAction onInfo(const Info&) noexcept {
    return VisitorAction::Continue;
  }
  virtual VisitorAction onTrackEntry(const TrackEntry&) noexcept {
    return VisitorAction::Continue;
  }
  virtual VisitorAction onCluster(const Cluster&) noexcept {
    return VisitorAction::Continue;
  }
  // Both spans additionally use fixed parser scratch and may be overwritten
  // immediately after return. Payload bytes remain in SeekableByteReader.
  virtual VisitorAction onBlock(
      const BlockHeader&, std::span<const FrameRange>,
      const BlockGroupFields&,
      std::span<const std::int64_t>) noexcept {
    return VisitorAction::Continue;
  }
  virtual VisitorAction
  onCueTrackPosition(const CueTrackPosition&) noexcept {
    return VisitorAction::Continue;
  }
  virtual VisitorAction onChapterFeatures(const ChapterFeatures&) noexcept {
    return VisitorAction::Continue;
  }
  virtual VisitorAction onDocumentSummary(const DocumentSummary&) noexcept {
    return VisitorAction::Continue;
  }
};

enum class MasterKind : std::uint8_t {
  SeekHead,
  Info,
  Tracks,
  Cluster,
  Cues,
  Chapters,
};

struct SegmentChildOutcome;
class SegmentChildCursor;

// Immutable proof returned by SegmentChildCursor for one direct Segment
// child. Known top-level masters expose `kind`; global/unsupported children
// retain their raw ID and ranges so callers can skip them without payload I/O.
class SegmentChild final {
 public:
  SegmentChild(const SegmentChild&) = default;
  SegmentChild& operator=(const SegmentChild&) = delete;
  SegmentChild(SegmentChild&&) = default;
  SegmentChild& operator=(SegmentChild&&) = delete;

  [[nodiscard]] constexpr std::uint32_t id() const noexcept { return id_; }
  [[nodiscard]] constexpr std::optional<MasterKind> kind() const noexcept {
    return kind_;
  }
  [[nodiscard]] constexpr ByteRange encoded() const noexcept {
    return encoded_;
  }
  [[nodiscard]] constexpr ByteRange data() const noexcept { return data_; }
  [[nodiscard]] constexpr bool unknownSize() const noexcept {
    return unknown_size_;
  }

 private:
  SegmentChild() = default;

  // Opaque parser proof fields. Consumers use the accessors above and pass
  // the value back unchanged with its originating cursor.
  std::uint32_t id_{0};
  std::optional<MasterKind> kind_;
  ByteRange encoded_;
  ByteRange data_;
  std::uint8_t id_width_{0};
  std::uint8_t size_width_{0};
  bool unknown_size_{false};
  ByteRange segment_data_;
  const SeekableByteReader* reader_identity_{nullptr};
  std::uint64_t reader_size_{0};
  std::uint64_t cursor_capability_{0};

  friend struct SegmentChildOutcome;
  friend class SegmentChildCursor;
  friend SegmentChildOutcome readNextSegmentChild(
      SeekableByteReader&, SegmentChildCursor&, const ParseOptions&,
      CancellationToken) noexcept;
  friend ParseOutcome parseSegmentChild(
      SeekableByteReader&, SegmentChildCursor&, const SegmentChild&,
      MasterKind, Visitor&, const ParseOptions&, CancellationToken) noexcept;
};

struct SegmentChildOutcome {
  ParseOutcome outcome;
  std::optional<SegmentChild> child;
};

// Stateful, capacity-one Segment directory. It advances only through parser-
// produced direct-child boundaries and retains one cumulative element budget
// across directory discovery and targeted parses made through the cursor.
// The cursor borrows the reader identity supplied at construction and must
// not outlive that reader.
class SegmentChildCursor final {
 public:
  SegmentChildCursor(const SegmentChildCursor&) = delete;
  SegmentChildCursor& operator=(const SegmentChildCursor&) = delete;
  SegmentChildCursor(SegmentChildCursor&& other) noexcept
      : reader_identity_(other.reader_identity_),
        reader_size_(other.reader_size_), segment_data_(other.segment_data_),
        next_offset_(other.next_offset_), segment_end_(other.segment_end_),
        remaining_elements_(other.remaining_elements_), bounds_(other.bounds_),
        capability_(other.capability_) {
    other.reader_identity_ = nullptr;
    other.reader_size_ = 0;
    other.next_offset_ = other.segment_end_;
    other.remaining_elements_ = 0;
    other.capability_ = 0;
  }
  SegmentChildCursor& operator=(SegmentChildCursor&&) = delete;

  [[nodiscard]] constexpr ByteRange segmentData() const noexcept {
    return segment_data_;
  }
  [[nodiscard]] constexpr std::uint64_t nextOffset() const noexcept {
    return next_offset_;
  }
  [[nodiscard]] constexpr bool done() const noexcept {
    return next_offset_ == segment_end_;
  }
  [[nodiscard]] constexpr std::size_t remainingElements() const noexcept {
    return remaining_elements_;
  }

 private:
  // Cursor state is parser-owned by contract. Consumers may inspect through
  // accessors but must not mutate these fields.
  SegmentChildCursor(SeekableByteReader& reader, ByteRange segmentData,
                     std::uint64_t segmentEnd, ParseOptions bounds,
                     std::uint64_t capability) noexcept
      : reader_identity_(&reader), reader_size_(reader.size()),
        segment_data_(segmentData), next_offset_(segmentData.offset),
        segment_end_(segmentEnd), remaining_elements_(bounds.maximumElements),
        bounds_(bounds), capability_(capability) {}

  const SeekableByteReader* reader_identity_{nullptr};
  std::uint64_t reader_size_{0};
  ByteRange segment_data_;
  std::uint64_t next_offset_{0};
  std::uint64_t segment_end_{0};
  std::size_t remaining_elements_{0};
  ParseOptions bounds_;
  std::uint64_t capability_{0};

  friend std::optional<SegmentChildCursor> beginSegmentChildCursor(
      SeekableByteReader&, ByteRange, const ParseOptions&) noexcept;
  friend SegmentChildOutcome readNextSegmentChild(
      SeekableByteReader&, SegmentChildCursor&, const ParseOptions&,
      CancellationToken) noexcept;
  friend ParseOutcome parseSegmentChild(
      SeekableByteReader&, SegmentChildCursor&, const SegmentChild&,
      MasterKind, Visitor&, const ParseOptions&, CancellationToken) noexcept;
};

[[nodiscard]] std::optional<SegmentChildCursor> beginSegmentChildCursor(
    SeekableByteReader& reader, ByteRange segmentData,
    const ParseOptions& options = {}) noexcept;

// Reads and proves exactly one direct child. Known-size payloads are skipped;
// an unknown-size Cluster is walked only once to its schema-valid terminator.
[[nodiscard]] SegmentChildOutcome readNextSegmentChild(
    SeekableByteReader& reader, SegmentChildCursor& cursor,
    const ParseOptions& options = {},
    CancellationToken cancellation = {}) noexcept;

// Parses a master already proven by the Segment directory without replaying
// the Segment prefix. The originating cursor binds the reader/range proof and
// charges the parse against the same cumulative maximumElements budget.
[[nodiscard]] ParseOutcome parseSegmentChild(
    SeekableByteReader& reader, SegmentChildCursor& cursor,
    const SegmentChild& child,
    MasterKind expected, Visitor& visitor,
    const ParseOptions& options = {},
    CancellationToken cancellation = {}) noexcept;

// Stateful capacity-one pull token for a schema-proven Cluster data range.
// Its constructor is intentionally private: callers begin once, then pass the
// same token back so the parser can enforce one cumulative element budget and
// advance only along parser-produced direct-child boundaries. The cursor
// borrows the reader identity supplied at construction.
class ClusterChildCursor final {
 public:
  ClusterChildCursor(const ClusterChildCursor&) = delete;
  ClusterChildCursor& operator=(const ClusterChildCursor&) = delete;
  ClusterChildCursor(ClusterChildCursor&& other) noexcept
      : reader_identity_(other.reader_identity_),
        reader_size_(other.reader_size_), cluster_data_(other.cluster_data_),
        next_offset_(other.next_offset_), cluster_end_(other.cluster_end_),
        remaining_elements_(other.remaining_elements_), bounds_(other.bounds_) {
    other.reader_identity_ = nullptr;
    other.reader_size_ = 0;
    other.next_offset_ = other.cluster_end_;
    other.remaining_elements_ = 0;
  }
  ~ClusterChildCursor() = default;
  ClusterChildCursor& operator=(ClusterChildCursor&&) = delete;

  [[nodiscard]] constexpr ByteRange clusterData() const noexcept {
    return cluster_data_;
  }
  [[nodiscard]] constexpr std::uint64_t nextOffset() const noexcept {
    return next_offset_;
  }
  [[nodiscard]] constexpr bool done() const noexcept {
    return next_offset_ == cluster_end_;
  }
  [[nodiscard]] constexpr std::size_t remainingElements() const noexcept {
    return remaining_elements_;
  }

 private:
  ClusterChildCursor(SeekableByteReader& reader, ByteRange clusterData,
                     std::uint64_t clusterEnd, ParseOptions bounds) noexcept
      : reader_identity_(&reader), reader_size_(reader.size()),
        cluster_data_(clusterData), next_offset_(clusterData.offset),
        cluster_end_(clusterEnd), remaining_elements_(bounds.maximumElements),
        bounds_(bounds) {}

  const SeekableByteReader* reader_identity_{nullptr};
  std::uint64_t reader_size_{0};
  ByteRange cluster_data_;
  std::uint64_t next_offset_{0};
  std::uint64_t cluster_end_{0};
  std::size_t remaining_elements_{0};
  ParseOptions bounds_;

  friend std::optional<ClusterChildCursor> beginClusterChildCursor(
      SeekableByteReader&, ByteRange, const ParseOptions&) noexcept;
  friend ParseOutcome parseClusterChildAt(
      SeekableByteReader&, ClusterChildCursor&, Visitor&,
      const ParseOptions&, CancellationToken) noexcept;
};

// Returns no cursor when the supplied range itself overflows. Production
// callers pass Cluster::data from a successful targeted Cluster parse.
[[nodiscard]] std::optional<ClusterChildCursor> beginClusterChildCursor(
    SeekableByteReader& reader, ByteRange clusterData,
    const ParseOptions& options = {}) noexcept;

// Parses one known master at an absolute offset. parentEnd is the exclusive
// file/Segment boundary. When absoluteOffset differs from segmentDataOffset,
// the parser proves it is a direct Segment child before trusting it. Passing
// equal offsets is reserved for standalone test/fixture masters that begin at
// byte zero; production callers use parseSegmentChildAt().
[[nodiscard]] ParseOutcome parseMasterAt(
    SeekableByteReader& reader, std::uint64_t absoluteOffset,
    std::uint64_t parentEnd, std::uint64_t segmentDataOffset,
    MasterKind expected, Visitor& visitor,
    const ParseOptions& options = {},
    CancellationToken cancellation = {}) noexcept;

// Same targeted parse with an explicit, already proven Segment data range.
// This overload first walks direct Segment children (skipping known payloads
// and schema-terminating unknown Clusters) so absoluteOffset cannot point to a
// forged header nested inside another element.
[[nodiscard]] ParseOutcome parseSegmentChildAt(
    SeekableByteReader& reader, ByteRange segmentData,
    std::uint64_t absoluteOffset, MasterKind expected, Visitor& visitor,
    const ParseOptions& options = {},
    CancellationToken cancellation = {}) noexcept;

// Parses exactly one direct Cluster child in O(1) cursor work. The cursor is
// created from the schema-derived Cluster::data range and advances only after
// a successful step while retaining the cumulative maximumElements budget.
// Unknown/global metadata children are skipped with parsedRange/nextOffset,
// selected SimpleBlock/BlockGroup children emit at most one callback, and an
// unselected block consumes only its bounded prefix before its payload skip.
[[nodiscard]] ParseOutcome parseClusterChildAt(
    SeekableByteReader& reader, ClusterChildCursor& cursor, Visitor& visitor,
    const ParseOptions& options,
    CancellationToken cancellation = {}) noexcept;

[[nodiscard]] ParseOutcome parseDocument(
    SeekableByteReader& reader, Visitor& visitor,
    const ParseOptions& options = {},
    CancellationToken cancellation = {}) noexcept;

// Opens the path exactly once, snapshots descriptor identity/size, uses pread,
// and verifies the same descriptor again before returning.
[[nodiscard]] ParseOutcome parseFile(
    const std::filesystem::path& path, Visitor& visitor,
    const ParseOptions& options = {},
    CancellationToken cancellation = {}) noexcept;

}  // namespace wam::media::matroska
