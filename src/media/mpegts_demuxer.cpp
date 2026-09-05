#include "media/mpegts_demuxer.hpp"

#include "media/matroska_aac.hpp"
#include "media/media_iso_color.hpp"
#include "media/video_codec_configuration.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <numeric>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace wam::media::mpegts {

// The AAC-LC admission and ES_Descriptor cookie builder are container-neutral
// despite living in the Matroska namespace: they take an AudioSpecificConfig
// and emit the CoreAudio magic cookie. Reusing them is what makes an
// ADTS-sourced AAC track byte-identical to a Matroska-sourced one downstream.
using matroska::AacLcAdmission;
using matroska::AacLcConfiguration;
using matroska::AacLcEsDescriptorCookie;
using matroska::buildAacLcEsDescriptorCookie;
using matroska::kAacLcSamplesPerAccessUnit;
using matroska::parseAacLcAudioSpecificConfig;

namespace {

constexpr std::uint32_t kAacFormatTag{0x61616320U};        // 'aac '
constexpr std::uint32_t kMpegLayer2FormatTag{0x2E6D7032U}; // '.mp2'
constexpr std::uint32_t kMpegLayer3FormatTag{0x2E6D7033U}; // '.mp3'
constexpr std::uint32_t kAc3FormatTag{0x61632D33U};        // 'ac-3'
constexpr std::uint32_t kEnhancedAc3FormatTag{0x65632D33U};// 'ec-3'
constexpr std::uint32_t kMonoLayoutTag{0x00640001U};
constexpr std::uint32_t kStereoLayoutTag{0x00650002U};

// ATSC A/52 codes six 256-sample audio blocks per syncframe; E-AC-3 may code
// 1, 2, 3 or 6 and now says which in numblkscod, so the per-stream value is
// READ from the first syncframe rather than assumed here. This constant is
// retained only as the legacy AC-3 identity the parser must reproduce.
constexpr std::uint32_t kAc3SamplesPerSyncFrame{
    kAc3BlocksPerSyncFrame * kAc3SamplesPerBlock};
static_assert(kAc3SamplesPerSyncFrame == 1536);

// How many consecutive sync bytes at a candidate stride prove framing. Ten
// gives a false-positive probability of 2^-80 against random data while
// needing only 10 * 204 = 2,040 bytes of probe, so even a two-packet file is
// still decided from real evidence rather than from one lucky byte.
constexpr std::size_t kFramingConfirmations{10};

// ---------------------------------------------------------------------------
// Local file reader
// ---------------------------------------------------------------------------

// Copied from matroska_demuxer.cpp rather than shared, because that class is
// in an anonymous namespace and is not linkable from here. The identity
// rationale below is copied WITH it deliberately: if the two ever drift, the
// reason each field is present must drift with them.
//
// The property this proves is exactly one thing: the bytes reachable through
// the retained descriptor are still the bytes the index was built against.
// dev+ino catch a replaced file, size catches truncation and extension, and
// mtime catches any write to the content.
//
// st_ctime is deliberately NOT part of that identity. ctime is the
// INODE-metadata timestamp: it moves for xattr writes, chmod, chown,
// link-count and rename -- none of which touch a single content byte. On macOS
// those happen to a media file constantly and from outside this process:
// Spotlight/mds indexing, iCloud/FileProvider sync bookkeeping, quarantine and
// last-used-date stamping. Including ctime made the Matroska predicate report
// "the file changed" for events that are, by construction, not changes to the
// file's content -- a load-dependent false positive that produced a real
// playback defect. What dropping ctime gives up is only an in-place,
// byte-count-preserving write whose mtime is then restored by an explicit
// utimes() call, which is deliberate forgery rather than a hazard a local
// media player defends against.
class StableFileReader final : public SeekableByteReader {
 public:
  static std::shared_ptr<StableFileReader>
  open(const std::filesystem::path& path) noexcept {
    const int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
      return nullptr;
    }
    struct stat facts {};
    if (::fstat(descriptor, &facts) != 0 || facts.st_size < 0 ||
        !S_ISREG(facts.st_mode)) {
      ::close(descriptor);
      return nullptr;
    }
    try {
      return std::shared_ptr<StableFileReader>(
          new StableFileReader(descriptor, facts));
    } catch (...) {
      ::close(descriptor);
      return nullptr;
    }
  }

  ~StableFileReader() override { ::close(descriptor_); }

  [[nodiscard]] std::uint64_t size() const noexcept override { return size_; }

  [[nodiscard]] bool readAt(std::uint64_t offset,
                            std::span<std::byte> destination) noexcept
      override {
    if (destination.empty()) {
      return offset <= size_;
    }
    if (offset > size_ || destination.size() > size_ - offset ||
        offset >
            static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
      return false;
    }
    std::size_t copied = 0;
    while (copied < destination.size()) {
      const std::uint64_t current = offset + copied;
      const ssize_t result =
          ::pread(descriptor_, destination.data() + copied,
                  destination.size() - copied, static_cast<off_t>(current));
      if (result < 0 && errno == EINTR) {
        continue;
      }
      if (result <= 0) {
        return false;
      }
      copied += static_cast<std::size_t>(result);
    }
    return true;
  }

  [[nodiscard]] bool unchanged() const noexcept {
    struct stat facts {};
    return ::fstat(descriptor_, &facts) == 0 && facts.st_size >= 0 &&
           facts.st_dev == device_ && facts.st_ino == inode_ &&
           static_cast<std::uint64_t>(facts.st_size) == size_ &&
           facts.st_mtimespec.tv_sec == modifiedSeconds_ &&
           facts.st_mtimespec.tv_nsec == modifiedNanoseconds_;
  }

 private:
  StableFileReader(int descriptor, const struct stat& facts) noexcept
      : descriptor_(descriptor),
        size_(static_cast<std::uint64_t>(facts.st_size)),
        device_(facts.st_dev), inode_(facts.st_ino),
        modifiedSeconds_(facts.st_mtimespec.tv_sec),
        modifiedNanoseconds_(facts.st_mtimespec.tv_nsec) {}

  int descriptor_{-1};
  std::uint64_t size_{0};
  dev_t device_{};
  ino_t inode_{};
  time_t modifiedSeconds_{};
  long modifiedNanoseconds_{};
};

// ---------------------------------------------------------------------------
// Windowed sequential reader
// ---------------------------------------------------------------------------

// One 64 KiB workspace, reused for the life of the walk. Reset counts, never
// free capacity: this object is a member of every scan and cursor, and no
// packet read allocates.
class ReadWindow {
 public:
  explicit ReadWindow(SeekableByteReader& reader) noexcept
      : reader_(&reader), fileSize_(reader.size()) {}

  [[nodiscard]] std::uint64_t fileSize() const noexcept { return fileSize_; }

  // Returns exactly `length` bytes at `offset`, or an empty span. The window
  // is refilled at `offset` when the request straddles or misses it, so a
  // packet crossing the window edge costs one refill, never a partial read.
  [[nodiscard]] std::span<const std::byte> at(std::uint64_t offset,
                                              std::size_t length) noexcept {
    if (length == 0) {
      return {};
    }
    if (length > storage_.size() || offset > fileSize_ ||
        length > fileSize_ - offset) {
      return {};
    }
    if (!(offset >= windowOffset_ && windowSize_ >= length &&
          offset - windowOffset_ <= windowSize_ - length)) {
      const std::uint64_t available = fileSize_ - offset;
      const std::size_t want = static_cast<std::size_t>(
          std::min<std::uint64_t>(storage_.size(), available));
      if (!reader_->readAt(offset, std::span<std::byte>(storage_.data(),
                                                        want))) {
        windowSize_ = 0;
        return {};
      }
      windowOffset_ = offset;
      windowSize_ = want;
      ++refills_;
    }
    return std::span<const std::byte>(
        storage_.data() + (offset - windowOffset_), length);
  }

  [[nodiscard]] std::uint64_t refills() const noexcept { return refills_; }

 private:
  SeekableByteReader* reader_{nullptr};
  std::uint64_t fileSize_{0};
  std::uint64_t windowOffset_{std::numeric_limits<std::uint64_t>::max()};
  std::uint64_t refills_{0};
  std::size_t windowSize_{0};
  std::array<std::byte, kMpegTsReadWindowBytes> storage_{};
};

// ---------------------------------------------------------------------------
// Access-unit assembly for one elementary stream
// ---------------------------------------------------------------------------

// The exact 90 kHz timeline value of a raw 33-bit timestamp, extended past
// rollover and rebased on the stream origin.
struct StreamWalk {
  TimestampUnwrapper pts;
  TimestampUnwrapper dts;
  ContinuityTracker continuity;
  std::array<std::byte, kMpegTsAccessUnitProbeBytes> probe{};
  std::uint64_t firstPacketOffset{0};
  std::int64_t ptsTick{0};
  std::int64_t dtsTick{0};
  std::uint32_t rawBytes{0};
  std::uint32_t probeFilled{0};
  std::uint32_t headerSkipBytes{0};
  std::uint32_t packetCount{0};
  std::uint16_t pid{kNullPid};
  MediaCodec codec{MediaCodec::Unknown};
  bool video{false};
  bool collecting{false};
  bool pendingHeader{false};
  bool hasPts{false};
  bool hasDts{false};
  bool randomAccess{false};
  bool discontinuity{false};
  bool continuityGap{false};
  // Sticky across units, deliberately: it is a property of the STREAM's
  // prologue size, not of any one access unit, and the only consumer is a
  // refusal message that wants to know whether the scan ever ran out of probe
  // before reaching a picture. Cleared by beginUnit's caller? No -- see
  // finishUnit, which only ever sets it.
  bool probeEndedBeforeSlice{false};

  void beginUnit(std::uint64_t offset) noexcept {
    firstPacketOffset = offset;
    rawBytes = 0;
    probeFilled = 0;
    headerSkipBytes = 0;
    packetCount = 0;
    collecting = true;
    pendingHeader = true;
    hasPts = false;
    hasDts = false;
    randomAccess = false;
    discontinuity = false;
    continuityGap = false;
  }

  void discardUnit() noexcept {
    collecting = false;
    pendingHeader = false;
    rawBytes = 0;
    probeFilled = 0;
  }

  // Appends one packet's payload. Only the bounded probe prefix is copied;
  // everything beyond it is counted, never moved. This is the single place the
  // demuxer touches payload bytes, and it touches at most 4 KiB per unit.
  void appendPayload(std::span<const std::byte> payload) noexcept {
    if (probeFilled < probe.size()) {
      const std::size_t room = probe.size() - probeFilled;
      const std::size_t take = std::min(room, payload.size());
      std::memcpy(probe.data() + probeFilled, payload.data(), take);
      probeFilled = static_cast<std::uint32_t>(probeFilled + take);
    }
    rawBytes = static_cast<std::uint32_t>(
        std::min<std::uint64_t>(std::numeric_limits<std::uint32_t>::max(),
                                static_cast<std::uint64_t>(rawBytes) +
                                    payload.size()));
    ++packetCount;
  }

  // Attempts to complete the PES header from what the probe holds. Returns
  // false only when the bytes present are positively not a PES header; a
  // still-incomplete header leaves pendingHeader set.
  [[nodiscard]] bool tryHeader() noexcept {
    if (!pendingHeader) {
      return true;
    }
    PesHeader header{};
    const std::span<const std::byte> view(probe.data(), probeFilled);
    const PesStatus status = decodePesHeader(view, header);
    if (status == PesStatus::Incomplete) {
      return true;
    }
    if (status != PesStatus::Ok) {
      return false;
    }
    headerSkipBytes = header.headerBytes;
    if (header.hasPts) {
      ptsTick = pts.extend(header.pts);
      hasPts = true;
    }
    if (header.hasDts) {
      dtsTick = dts.extend(header.dts);
      hasDts = true;
    } else if (header.hasPts) {
      // Without an explicit DTS the decode time IS the presentation time; the
      // unwrapper is fed so its epoch tracks the stream even for streams that
      // only ever carry PTS.
      dtsTick = dts.extend(header.pts);
      hasDts = false;
    }
    pendingHeader = false;
    return true;
  }
};

// ---------------------------------------------------------------------------
// Asset state
// ---------------------------------------------------------------------------

struct TrackFacts {
  MediaTrackId id{0};
  std::uint16_t pid{kNullPid};
  std::uint8_t streamType{0};
  MediaCodec codec{MediaCodec::Unknown};
  MediaTrackKind kind{MediaTrackKind::Metadata};
  std::uint32_t sampleRate{0};
  std::uint32_t channels{0};
  std::uint32_t samplesPerFrame{0};
};

struct AssetState {
  std::shared_ptr<SeekableByteReader> reader;
  std::shared_ptr<StableFileReader> localReader;
  std::uint64_t readerSize{0};
  std::filesystem::path path;
  MediaSourceLimits limits;
  MpegTsFraming framing{};
  std::shared_ptr<const MediaSourceDescriptor> descriptor;
  std::vector<MpegTsIndexEntry> index;
  std::int64_t originTick{0};
  std::int64_t endTick{0};
  std::uint16_t programNumber{0};
  std::uint16_t pcrPid{kNullPid};
  // Program numbers of the other services in the multiplex, in PAT order. A
  // seam, not a feature: nothing consumes it yet, and a program picker is the
  // named deferral it exists for.
  std::vector<std::uint16_t> otherPrograms;
  bool programSelectionComplete{false};
  TrackFacts video{};
  TrackFacts audio{};
  // Exact nominal video frame extent in 90 kHz ticks.
  //
  // Transport Stream states NO per-sample duration: a PES header carries a
  // presentation time and nothing about how long the picture is shown. Every
  // downstream video consumer in this player compares a sample's exact
  // presentation INTERVAL against the timeline and refuses a sample whose
  // duration is absent or non-positive (native_video_consumer.mm:1658), so an
  // interval has to be established at admission rather than left invalid the
  // way the Matroska path leaves the decode timestamp.
  //
  // Two sources, in priority order, and never a guess:
  //   1. MPEG-2 states frame_rate_code in its sequence header, and 13818-2
  //      Table 6-4 divides 90 kHz exactly for every legal code including the
  //      1000/1001 family (90000*1001/30000 = 3003). That is authoritative.
  //   2. Otherwise the smallest positive DECODE-timestamp delta across the
  //      first bounded run of access units. Decode order is monotone by
  //      definition, so for constant-frame-rate content -- which every stream
  //      this player admits is -- the minimum delta IS the frame extent, and
  //      B-picture reordering cannot perturb it the way a PTS delta would.
  // A stream that yields neither is refused by verdict, because publishing a
  // fabricated interval would make every accurate-seek decision downstream
  // wrong by an unknown amount.
  std::uint32_t videoFrameDurationTicks{0};
  // Extended 90 kHz tick of the first video access unit, before rebasing.
  std::int64_t videoOriginTick{0};
  // The StreamMuxConfig proved at preparation for an AAC-LATM audio stream.
  //
  // It is retained and PUBLISHED rather than re-derived because a LOAS frame
  // that reuses the established config carries none of its own, and the frame a
  // generation starts on after a seek is almost never the one that carried it.
  // Re-scanning for a config on every seek would be a second bounded hunt with
  // its own failure mode; handing the platform layer the exact config this
  // demuxer already admitted has neither.
  std::optional<LatmStreamMuxConfig> latmConfig;
  bool hasVideo{false};
  bool hasAudio{false};

  [[nodiscard]] bool unchanged() const noexcept {
    return reader != nullptr && reader->size() == readerSize &&
           (localReader == nullptr || localReader->unchanged());
  }
};

[[nodiscard]] std::optional<MediaTime> rebasedTime(std::int64_t tick,
                                                   std::int64_t origin) noexcept {
  const __int128 delta = static_cast<__int128>(tick) - origin;
  if (delta < std::numeric_limits<std::int64_t>::min() ||
      delta > std::numeric_limits<std::int64_t>::max()) {
    return std::nullopt;
  }
  return mediaTimeFromTicks(static_cast<std::int64_t>(delta));
}

// ---------------------------------------------------------------------------
// avcC synthesis from in-band Annex-B parameter sets
// ---------------------------------------------------------------------------

// Transport Stream carries H.264 as Annex-B with in-band SPS/PPS and no
// out-of-band configuration record, but VideoToolbox wants an avcC and
// length-prefixed NALs. The record is synthesized here so the descriptor can
// be validated by exactly the same inspector the Matroska path uses; the
// sample-side Annex-B to AVCC repack happens in the platform builder.
//
// lengthSizeMinusOne is 3 (four-byte lengths) because inspectAvcC hard-requires
// it, and no extension tail is emitted because the inspector accepts exact
// exhaustion after the PPS array and rejects anything it does not recognise.
[[nodiscard]] bool buildAvcCFromAnnexB(std::span<const std::byte> unit,
                                       std::vector<std::byte>& record) {
  std::array<AnnexBNal, 8> sequenceSets{};
  std::array<AnnexBNal, 8> pictureSets{};
  std::size_t sequenceCount = 0;
  std::size_t pictureCount = 0;

  AnnexBNal nal{};
  std::uint32_t cursor = 0;
  while (nextAnnexBNal(unit, cursor, MediaCodec::H264, nal)) {
    if (nal.size == 0) {
      break;
    }
    if (nal.type == 7 && sequenceCount < sequenceSets.size()) {
      sequenceSets[sequenceCount++] = nal;
    } else if (nal.type == 8 && pictureCount < pictureSets.size()) {
      pictureSets[pictureCount++] = nal;
    }
    const std::uint32_t advance = nal.offset + nal.size;
    if (advance <= cursor || advance >= unit.size()) {
      break;
    }
    cursor = advance;
  }
  if (sequenceCount == 0 || pictureCount == 0) {
    return false;
  }
  const AnnexBNal& sps = sequenceSets[0];
  if (sps.size < 4) {
    return false;
  }
  const std::uint8_t* spsBytes =
      reinterpret_cast<const std::uint8_t*>(unit.data() + sps.offset);

  record.clear();
  record.push_back(std::byte{0x01});
  record.push_back(static_cast<std::byte>(spsBytes[1]));
  record.push_back(static_cast<std::byte>(spsBytes[2]));
  record.push_back(static_cast<std::byte>(spsBytes[3]));
  record.push_back(std::byte{0xFF});  // '111111' + lengthSizeMinusOne = 3
  record.push_back(
      static_cast<std::byte>(0xE0U | static_cast<std::uint8_t>(sequenceCount)));
  for (std::size_t i = 0; i < sequenceCount; ++i) {
    const AnnexBNal& entry = sequenceSets[i];
    if (entry.size > 0xFFFFU) {
      return false;
    }
    record.push_back(static_cast<std::byte>((entry.size >> 8) & 0xFFU));
    record.push_back(static_cast<std::byte>(entry.size & 0xFFU));
    record.insert(record.end(), unit.begin() + entry.offset,
                  unit.begin() + entry.offset + entry.size);
  }
  record.push_back(static_cast<std::byte>(pictureCount));
  for (std::size_t i = 0; i < pictureCount; ++i) {
    const AnnexBNal& entry = pictureSets[i];
    if (entry.size > 0xFFFFU) {
      return false;
    }
    record.push_back(static_cast<std::byte>((entry.size >> 8) & 0xFFU));
    record.push_back(static_cast<std::byte>(entry.size & 0xFFU));
    record.insert(record.end(), unit.begin() + entry.offset,
                  unit.begin() + entry.offset + entry.size);
  }
  return true;
}

// ---------------------------------------------------------------------------
// hvcC synthesis from in-band Annex-B parameter sets
// ---------------------------------------------------------------------------
//
// The HEVC counterpart of buildAvcCFromAnnexB, and a fussier record. avcC
// takes three bytes off the front of the SPS and is done; hvcC states
// twenty-three header bytes before its first array, and the shared inspector
// re-derives every one of them from the parameter sets and compares.
//
//   [0]      configurationVersion = 1.
//   [1..12]  profile_tier_level, COPIED VERBATIM out of the SPS RBSP. See
//            HevcSpsFacts in mpegts_packet.hpp for why this is a copy: the
//            general_constraint_indicator_flags alone are 48 bits of which 43
//            are reserved, and a field-by-field rebuild would have to invent
//            a normalization the source stream never agreed to.
//   [13..14] '1111' + min_spatial_segmentation_idc. Stated as zero, which is
//            the syntax's own "no information" value -- a transport stream
//            carries no such declaration, and guessing one would be a claim
//            about tile geometry this demuxer cannot prove.
//   [15]     '111111' + parallelismType, zero for the same reason.
//   [16]     '111111' + chroma_format_idc, from the SPS.
//   [17..18] '11111' + luma / chroma bit_depth_minus8, from the SPS.
//   [19..20] avgFrameRate, zero = unspecified. The demuxer DOES know a frame
//            extent by this point, but this field is a 16.16-style average in
//            frames per 256 seconds and stating a rounded one would put an
//            approximation into a record that is otherwise exact.
//   [21]     constantFrameRate (0 = unknown) + numTemporalLayers +
//            temporalIdNested + lengthSizeMinusOne = 3.
//   [22]     numOfArrays = 3.
//
// lengthSizeMinusOne is 3 for the same reason as avcC's: four-byte lengths
// are the only width inspectHvcC admits, and the per-sample repack in the
// platform builder writes exactly that.
//
// array_completeness is left ZERO on every array. Zero is the honest value
// here -- the elementary stream really does keep carrying its parameter sets
// in band, and it is the value the inspector was taught to accept when the
// Matroska form of a stream-copied file differed from the MP4 form by exactly
// this bit.
[[nodiscard]] bool buildHvcCFromAnnexB(std::span<const std::byte> unit,
                                       std::vector<std::byte>& record) {
  std::array<AnnexBNal, 8> videoSets{};
  std::array<AnnexBNal, 8> sequenceSets{};
  std::array<AnnexBNal, 8> pictureSets{};
  std::size_t videoCount = 0;
  std::size_t sequenceCount = 0;
  std::size_t pictureCount = 0;

  AnnexBNal nal{};
  std::uint32_t cursor = 0;
  while (nextAnnexBNal(unit, cursor, MediaCodec::Hevc, nal)) {
    if (nal.size == 0) {
      break;
    }
    if (nal.type == 32 && videoCount < videoSets.size()) {
      videoSets[videoCount++] = nal;
    } else if (nal.type == 33 && sequenceCount < sequenceSets.size()) {
      sequenceSets[sequenceCount++] = nal;
    } else if (nal.type == 34 && pictureCount < pictureSets.size()) {
      pictureSets[pictureCount++] = nal;
    }
    const std::uint32_t advance = nal.offset + nal.size;
    if (advance <= cursor || advance >= unit.size()) {
      break;
    }
    cursor = advance;
  }
  if (videoCount == 0 || sequenceCount == 0 || pictureCount == 0) {
    return false;
  }

  HevcSpsFacts facts{};
  if (!parseHevcSpsFacts(unit.subspan(sequenceSets[0].offset,
                                      sequenceSets[0].size),
                         facts)) {
    return false;
  }
  // 4:2:0 is the only chroma format the native envelope carries, and the two
  // admitted depths are 8 and 10. Refusing here names the fact; letting a
  // 4:2:2 record through would only move the refusal into the inspector with
  // a less specific message.
  if (facts.chromaFormatIdc != 1 ||
      facts.bitDepthLumaMinusEight != facts.bitDepthChromaMinusEight ||
      (facts.bitDepthLumaMinusEight != 0 &&
       facts.bitDepthLumaMinusEight != 2)) {
    return false;
  }

  record.clear();
  record.push_back(std::byte{0x01});
  for (const std::uint8_t byte : facts.profileTierLevel) {
    record.push_back(static_cast<std::byte>(byte));
  }
  record.push_back(std::byte{0xF0});
  record.push_back(std::byte{0x00});
  record.push_back(std::byte{0xFC});
  record.push_back(static_cast<std::byte>(0xFCU | facts.chromaFormatIdc));
  record.push_back(
      static_cast<std::byte>(0xF8U | facts.bitDepthLumaMinusEight));
  record.push_back(
      static_cast<std::byte>(0xF8U | facts.bitDepthChromaMinusEight));
  record.push_back(std::byte{0x00});
  record.push_back(std::byte{0x00});
  const std::uint8_t temporalLayers =
      static_cast<std::uint8_t>(facts.maxSubLayersMinusOne + 1U);
  record.push_back(static_cast<std::byte>(
      static_cast<std::uint8_t>(temporalLayers << 3U) |
      static_cast<std::uint8_t>(facts.temporalIdNested ? 0x04U : 0x00U) |
      0x03U));
  record.push_back(std::byte{0x03});

  const auto appendArray = [&](std::uint8_t nalType,
                               const std::array<AnnexBNal, 8>& entries,
                               std::size_t count) -> bool {
    record.push_back(static_cast<std::byte>(nalType));
    record.push_back(static_cast<std::byte>((count >> 8) & 0xFFU));
    record.push_back(static_cast<std::byte>(count & 0xFFU));
    for (std::size_t i = 0; i < count; ++i) {
      const AnnexBNal& entry = entries[i];
      if (entry.size == 0 || entry.size > 0xFFFFU) {
        return false;
      }
      record.push_back(static_cast<std::byte>((entry.size >> 8) & 0xFFU));
      record.push_back(static_cast<std::byte>(entry.size & 0xFFU));
      record.insert(record.end(), unit.begin() + entry.offset,
                    unit.begin() + entry.offset + entry.size);
    }
    return true;
  };
  return appendArray(32, videoSets, videoCount) &&
         appendArray(33, sequenceSets, sequenceCount) &&
         appendArray(34, pictureSets, pictureCount);
}

// The transport stream's ONLY colour statement is the SPS VUI, so unlike
// Matroska (Colour element) or MP4 (`colr` box) there is no container source
// to cross-check against and no second vocabulary to reconcile -- the shared
// ISO mapping in media/media_iso_color.hpp is the whole colour path for this
// container.

// The shared inspector's verdict, by name, for a refusal message. Local
// rather than published from video_codec_configuration.hpp so this lane adds
// no surface to a header three other containers include; if a second caller
// ever wants it, that is the moment to move it.
[[nodiscard]] const char* videoCodecConfigurationErrorName(
    VideoCodecConfigurationError error) noexcept {
  switch (error) {
    case VideoCodecConfigurationError::None:
      return "None";
    case VideoCodecConfigurationError::UnsupportedCodec:
      return "UnsupportedCodec";
    case VideoCodecConfigurationError::ConfigurationKindMismatch:
      return "ConfigurationKindMismatch";
    case VideoCodecConfigurationError::EmptyConfiguration:
      return "EmptyConfiguration";
    case VideoCodecConfigurationError::ConfigurationTooLarge:
      return "ConfigurationTooLarge";
    case VideoCodecConfigurationError::MalformedRecord:
      return "MalformedRecord";
    case VideoCodecConfigurationError::MissingParameterSet:
      return "MissingParameterSet";
    case VideoCodecConfigurationError::ParameterSetMismatch:
      return "ParameterSetMismatch";
    case VideoCodecConfigurationError::UnsupportedProfile:
      return "UnsupportedProfile";
    case VideoCodecConfigurationError::UnsupportedChromaFormat:
      return "UnsupportedChromaFormat";
    case VideoCodecConfigurationError::UnsupportedBitDepth:
      return "UnsupportedBitDepth";
    case VideoCodecConfigurationError::UnsupportedColorDescription:
      return "UnsupportedColorDescription";
    case VideoCodecConfigurationError::DimensionLimitExceeded:
      return "DimensionLimitExceeded";
    case VideoCodecConfigurationError::ReorderLimitExceeded:
      return "ReorderLimitExceeded";
  }
  return "Unknown";
}

// A two-byte AudioSpecificConfig recovered from an ADTS header, which is the
// exact form the shared AAC admission already accepts.
[[nodiscard]] bool audioSpecificConfigFromAdts(
    const AdtsHeader& adts, std::array<std::byte, 2>& config) noexcept {
  if (adts.profileObjectType == 0 || adts.profileObjectType > 31 ||
      adts.samplingFrequencyIndex > 12 || adts.channelConfiguration == 0 ||
      adts.channelConfiguration > 7) {
    return false;
  }
  const std::uint16_t packed = static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(adts.profileObjectType) << 11) |
      (static_cast<std::uint16_t>(adts.samplingFrequencyIndex) << 7) |
      (static_cast<std::uint16_t>(adts.channelConfiguration) << 3));
  config[0] = static_cast<std::byte>((packed >> 8) & 0xFFU);
  config[1] = static_cast<std::byte>(packed & 0xFFU);
  return true;
}

}  // namespace

const char* mpegTsDemuxErrorName(MpegTsDemuxError error) noexcept {
  switch (error) {
    case MpegTsDemuxError::None:
      return "None";
    case MpegTsDemuxError::InvalidRequest:
      return "InvalidRequest";
    case MpegTsDemuxError::NotTransportStream:
      return "NotTransportStream";
    case MpegTsDemuxError::InvalidContainer:
      return "InvalidContainer";
    case MpegTsDemuxError::MissingProgramTable:
      return "MissingProgramTable";
    case MpegTsDemuxError::ProgramSelection:
      return "ProgramSelection";
    case MpegTsDemuxError::UnsupportedStreamType:
      return "UnsupportedStreamType";
    case MpegTsDemuxError::CodecConfiguration:
      return "CodecConfiguration";
    case MpegTsDemuxError::InvalidTimeline:
      return "InvalidTimeline";
    case MpegTsDemuxError::IndexLimit:
      return "IndexLimit";
    case MpegTsDemuxError::SampleLimit:
      return "SampleLimit";
    case MpegTsDemuxError::ScanLimit:
      return "ScanLimit";
    case MpegTsDemuxError::FileChanged:
      return "FileChanged";
    case MpegTsDemuxError::Io:
      return "Io";
    case MpegTsDemuxError::Cancelled:
      return "Cancelled";
  }
  return "Unknown";
}

bool detectMpegTsFraming(std::span<const std::byte> probe,
                         std::uint64_t fileSize,
                         MpegTsFraming& framing) noexcept {
  framing = MpegTsFraming{};
  static constexpr std::array<std::uint32_t, 3> kStrides{
      static_cast<std::uint32_t>(kTsPacketBytes),
      static_cast<std::uint32_t>(kM2tsPacketBytes),
      static_cast<std::uint32_t>(kRsPacketBytes)};
  for (const std::uint32_t stride : kStrides) {
    // A candidate first-sync offset can never exceed one stride: if the file
    // begins mid-packet, the next packet boundary is within `stride` bytes.
    for (std::uint32_t start = 0; start < stride; ++start) {
      if (start >= probe.size() || probe[start] != kSyncByte) {
        continue;
      }
      std::size_t confirmed = 1;
      bool broken = false;
      for (std::size_t k = 1; k < kFramingConfirmations; ++k) {
        const std::size_t at = static_cast<std::size_t>(start) + k * stride;
        if (at >= probe.size()) {
          break;  // ran out of probe, not a mismatch
        }
        if (probe[at] != kSyncByte) {
          broken = true;
          break;
        }
        ++confirmed;
      }
      if (broken) {
        continue;
      }
      // A single sync byte is not evidence. Demand either the full
      // confirmation run or every packet the file can hold, whichever is
      // smaller, so a two-packet file is still decided from real repetitions.
      const std::uint64_t possible =
          fileSize > start ? (fileSize - start) / stride : 0;
      const std::size_t required = static_cast<std::size_t>(
          std::min<std::uint64_t>(kFramingConfirmations, possible));
      if (required < 2 || confirmed < required) {
        continue;
      }
      framing.firstSyncOffset = start;
      framing.packetStride = stride;
      framing.timestampedPackets = stride == kM2tsPacketBytes;
      framing.packetCount = static_cast<std::uint32_t>(std::min<std::uint64_t>(
          std::numeric_limits<std::uint32_t>::max(), possible));
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Packet walking shared by every scan, the cursor and the gather
// ---------------------------------------------------------------------------

namespace {

enum class WalkStatus : std::uint8_t {
  Ok,
  End,
  Resynchronized,
  Io,
};

// Advances to the next transport packet, resynchronizing across corruption.
// `offset` is in/out: on Ok it names the packet returned and is advanced past
// it. Resynchronization is reported, never silent — a caller that must not
// tolerate loss can refuse on the verdict.
class PacketWalker {
 public:
  PacketWalker(ReadWindow& window, MpegTsFraming framing) noexcept
      : window_(&window), framing_(framing) {}

  [[nodiscard]] WalkStatus next(std::uint64_t& offset,
                                std::span<const std::byte>& packet) noexcept {
    if (offset >= window_->fileSize()) {
      return WalkStatus::End;
    }
    std::span<const std::byte> bytes = window_->at(offset, kTsPacketBytes);
    if (!bytes.empty() && bytes[0] == kSyncByte) {
      packet = bytes;
      offset += framing_.packetStride;
      return WalkStatus::Ok;
    }
    if (bytes.empty()) {
      // Either a short tail or a read failure; a tail shorter than one packet
      // is the end of usable data, not an error.
      return offset + kTsPacketBytes > window_->fileSize() ? WalkStatus::End
                                                           : WalkStatus::Io;
    }
    return resynchronize(offset, packet);
  }

  [[nodiscard]] std::uint32_t resynchronizations() const noexcept {
    return resynchronizations_;
  }

 private:
  // Byte-wise search for a position whose sync byte repeats at the stride.
  // Bounded by one read window per attempt and by kResyncWindowPackets total,
  // so corruption costs a bounded scan and never an unbounded hunt.
  [[nodiscard]] WalkStatus resynchronize(std::uint64_t& offset,
                                         std::span<const std::byte>& packet) noexcept {
    static constexpr std::uint64_t kResyncSpanBytes{4U * 1024U * 1024U};
    const std::uint64_t limit = std::min<std::uint64_t>(
        window_->fileSize(), offset + kResyncSpanBytes);
    for (std::uint64_t candidate = offset; candidate + kTsPacketBytes <= limit;
         ++candidate) {
      const std::span<const std::byte> head = window_->at(candidate, 1);
      if (head.empty()) {
        return WalkStatus::Io;
      }
      if (head[0] != kSyncByte) {
        continue;
      }
      // Confirm with the next packet's sync byte where one exists.
      const std::uint64_t follower = candidate + framing_.packetStride;
      if (follower + 1 <= window_->fileSize()) {
        const std::span<const std::byte> nextHead = window_->at(follower, 1);
        if (nextHead.empty() || nextHead[0] != kSyncByte) {
          continue;
        }
      }
      const std::span<const std::byte> bytes =
          window_->at(candidate, kTsPacketBytes);
      if (bytes.empty()) {
        return WalkStatus::Io;
      }
      ++resynchronizations_;
      packet = bytes;
      offset = candidate + framing_.packetStride;
      return WalkStatus::Resynchronized;
    }
    offset = limit;
    return WalkStatus::End;
  }

  ReadWindow* window_{nullptr};
  MpegTsFraming framing_{};
  std::uint32_t resynchronizations_{0};
};

// The packet offset at or after `position` that is aligned to the framing.
[[nodiscard]] std::uint64_t alignPacketOffset(const MpegTsFraming& framing,
                                              std::uint64_t position) noexcept {
  if (position <= framing.firstSyncOffset) {
    return framing.firstSyncOffset;
  }
  const std::uint64_t delta = position - framing.firstSyncOffset;
  const std::uint64_t packets =
      (delta + framing.packetStride - 1) / framing.packetStride;
  return framing.firstSyncOffset + packets * framing.packetStride;
}

}  // namespace

// ---------------------------------------------------------------------------
// Prepared asset
// ---------------------------------------------------------------------------

struct MpegTsPreparedAsset::Impl {
  explicit Impl(std::shared_ptr<AssetState> value) noexcept
      : state(std::move(value)) {}
  std::shared_ptr<AssetState> state;
};

MpegTsPreparedAsset::MpegTsPreparedAsset(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
MpegTsPreparedAsset::~MpegTsPreparedAsset() = default;

const std::filesystem::path& MpegTsPreparedAsset::path() const noexcept {
  return impl_->state->path;
}
const std::shared_ptr<const MediaSourceDescriptor>&
MpegTsPreparedAsset::descriptor() const noexcept {
  return impl_->state->descriptor;
}
const MediaSourceLimits& MpegTsPreparedAsset::limits() const noexcept {
  return impl_->state->limits;
}
MpegTsFraming MpegTsPreparedAsset::framing() const noexcept {
  return impl_->state->framing;
}
std::uint16_t MpegTsPreparedAsset::programNumber() const noexcept {
  return impl_->state->programNumber;
}
std::span<const std::uint16_t>
MpegTsPreparedAsset::otherPrograms() const noexcept {
  return impl_->state->otherPrograms;
}
bool MpegTsPreparedAsset::programSelectionComplete() const noexcept {
  return impl_->state->programSelectionComplete;
}
const LatmStreamMuxConfig*
MpegTsPreparedAsset::latmStreamMuxConfig() const noexcept {
  const AssetState& state = *impl_->state;
  return state.latmConfig ? &*state.latmConfig : nullptr;
}
std::span<const MpegTsIndexEntry> MpegTsPreparedAsset::index() const noexcept {
  return impl_->state->index;
}
std::int64_t MpegTsPreparedAsset::originTick() const noexcept {
  return impl_->state->originTick;
}

MediaTime MpegTsPreparedAsset::videoOriginTime() const noexcept {
  const AssetState& state = *impl_->state;
  const std::optional<MediaTime> time =
      rebasedTime(state.videoOriginTick, state.originTick);
  return time.value_or(MediaTime{});
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

struct MpegTsCursor::Impl {
  std::shared_ptr<const AssetState> state;
  std::unique_ptr<ReadWindow> window;
  std::optional<PacketWalker> walker;
  StreamWalk walk;
  std::uint64_t position{0};
  std::uint32_t continuityGaps{0};
  bool ended{false};
};

MpegTsCursor::MpegTsCursor(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
MpegTsCursor::~MpegTsCursor() = default;
MpegTsCursor::MpegTsCursor(MpegTsCursor&&) noexcept = default;
MpegTsCursor& MpegTsCursor::operator=(MpegTsCursor&&) noexcept = default;

std::uint32_t MpegTsCursor::continuityGaps() const noexcept {
  return impl_ == nullptr ? 0U : impl_->continuityGaps;
}
std::uint32_t MpegTsCursor::resynchronizations() const noexcept {
  if (impl_ == nullptr || !impl_->walker) {
    return 0;
  }
  return impl_->walker->resynchronizations();
}

namespace {

// Completes the access unit the walk holds and turns it into a sample.
[[nodiscard]] std::optional<MpegTsCompressedSample>
finishUnit(const AssetState& state, StreamWalk& walk, MediaTrackId track,
           std::uint64_t scanEnd) noexcept {
  if (!walk.collecting || walk.pendingHeader ||
      walk.rawBytes <= walk.headerSkipBytes) {
    walk.discardUnit();
    return std::nullopt;
  }
  MpegTsCompressedSample sample{};
  sample.firstPacketOffset = walk.firstPacketOffset;
  sample.packetScanEnd = scanEnd;
  sample.payloadBytes = walk.rawBytes - walk.headerSkipBytes;
  sample.headerSkipBytes = walk.headerSkipBytes;
  sample.track = track;
  sample.pid = walk.pid;
  sample.kind = walk.video ? MediaSampleKind::EncodedVideo
                           : MediaSampleKind::EncodedAudio;
  sample.discontinuity = walk.discontinuity;
  sample.continuityGap = walk.continuityGap;

  if (walk.hasPts) {
    const std::optional<MediaTime> presentation =
        rebasedTime(walk.ptsTick, state.originTick);
    if (!presentation) {
      walk.discardUnit();
      return std::nullopt;
    }
    sample.presentationTime = *presentation;
  }
  const std::optional<MediaTime> decode =
      rebasedTime(walk.dtsTick, state.originTick);
  if (decode) {
    sample.decodeTime = *decode;
  }

  if (walk.video) {
    // The exact nominal frame extent established at admission, reduced against
    // the 90 kHz base so the interval arithmetic downstream stays integral.
    if (state.videoFrameDurationTicks > 0) {
      const std::optional<MediaTime> extent = mediaTimeFromTicks(
          static_cast<std::int64_t>(state.videoFrameDurationTicks));
      if (extent) {
        sample.duration = *extent;
      }
    }
    const std::size_t probeLength =
        walk.probeFilled > walk.headerSkipBytes
            ? static_cast<std::size_t>(walk.probeFilled - walk.headerSkipBytes)
            : 0U;
    const std::span<const std::byte> unit(walk.probe.data() +
                                              walk.headerSkipBytes,
                                          probeLength);
    const AccessUnitScan scan = scanAccessUnit(unit, walk.codec);
    // random_access_indicator is the mux's own claim; the bitstream scan is
    // the proof. A sample is a keyframe when either says so, but only the
    // bitstream can say it is decodable from a cold decoder.
    sample.keyFrame = scan.keyFrame || walk.randomAccess;
    sample.decodableFromCold = scan.decodableFromCold;
    // Record, do not act. The predicate stays bitstream-only; this only lets
    // a caller that finds NO random access point say whether it was looking
    // at whole pictures or at truncated prologues.
    if (!scan.sliceInProbe) {
      walk.probeEndedBeforeSlice = true;
    }
  } else {
    sample.keyFrame = true;
    sample.decodableFromCold = true;
  }
  walk.discardUnit();
  return sample;
}

}  // namespace

MpegTsCursorReadResult
MpegTsCursor::readNext(CancellationToken cancellation) noexcept {
  if (impl_ == nullptr) {
    return MpegTsCursorFailure{MpegTsDemuxError::InvalidRequest,
                               "mpeg-ts cursor is not open"};
  }
  if (impl_->ended) {
    return MpegTsCursorEnd{};
  }
  if (cancellation.cancelled()) {
    return MpegTsCursorCancelled{};
  }
  const AssetState& state = *impl_->state;
  if (!state.unchanged()) {
    return MpegTsCursorFailure{MpegTsDemuxError::FileChanged,
                               "mpeg-ts file changed during playback"};
  }

  StreamWalk& walk = impl_->walk;
  PacketWalker& walker = *impl_->walker;
  std::uint64_t probes = 0;

  while (true) {
    // A cancellation probe every 1,024 packets bounds the latency of a stop
    // request to ~192 KiB of walking without paying a function call per packet.
    if ((++probes & 0x3FFU) == 0 && cancellation.cancelled()) {
      return MpegTsCursorCancelled{};
    }
    const std::uint64_t packetOffset = impl_->position;
    std::span<const std::byte> packet;
    const WalkStatus status = walker.next(impl_->position, packet);
    if (status == WalkStatus::Io) {
      return MpegTsCursorFailure{MpegTsDemuxError::Io,
                                 "mpeg-ts packet read failed"};
    }
    if (status == WalkStatus::End) {
      impl_->ended = true;
      const std::optional<MpegTsCompressedSample> tail =
          finishUnit(state, walk, walk.pid, impl_->position);
      if (tail) {
        return *tail;
      }
      return MpegTsCursorEnd{};
    }
    if (status == WalkStatus::Resynchronized && walk.collecting) {
      // Bytes were lost inside the unit under construction. Note it on the
      // sample rather than dropping the unit: a decoder handles a damaged
      // access unit far better than the pipeline handles a hole.
      walk.continuityGap = true;
    }

    TsPacketHeader header{};
    if (decodeTsPacket(packet, header) != TsPacketStatus::Ok) {
      continue;
    }
    if (header.pid != walk.pid) {
      continue;
    }
    if (header.transportError) {
      walk.continuityGap = true;
      continue;
    }
    const ContinuityVerdict verdict = walk.continuity.observe(header);
    if (verdict == ContinuityVerdict::Duplicate) {
      continue;
    }
    if (verdict == ContinuityVerdict::Gap) {
      ++impl_->continuityGaps;
      walk.continuityGap = true;
    }
    if (verdict == ContinuityVerdict::Discontinuous) {
      walk.discontinuity = true;
      walk.pts.resynchronize();
      walk.dts.resynchronize();
    }
    if (!header.hasPayload || header.payloadSize == 0) {
      continue;
    }

    // random_access_indicator is honoured ONLY on a payload-unit start, and
    // this is not a nicety. 13818-1 2.4.3.4 says the indicator means the
    // current or a SUBSEQUENT packet of this PID begins a random access point,
    // so ffmpeg sets it on the last packet before a keyframe's PES as well as
    // on the PES packet itself. An earlier version applied it to whichever
    // unit was under construction, which marked the access unit BEFORE every
    // keyframe as a keyframe too: measured 39 keyframes against ffprobe's 20
    // on seek.ts and 5 against 3 on h264-aac.ts, an almost exactly 2n-1 shape
    // that is the signature of an off-by-one, not of a codec disagreement.
    // Restricting it to the unit-start packet makes the count exact.
    if (header.payloadUnitStart) {
      std::optional<MpegTsCompressedSample> completed;
      if (walk.collecting) {
        completed = finishUnit(state, walk, walk.pid, packetOffset);
      }
      const bool wasRandomAccess = header.randomAccess;
      walk.beginUnit(packetOffset);
      walk.randomAccess = wasRandomAccess;
      walk.appendPayload(
          packet.subspan(header.payloadOffset, header.payloadSize));
      if (!walk.tryHeader()) {
        walk.discardUnit();
      }
      if (completed) {
        if (completed->payloadBytes > kMaximumMpegTsAccessUnitBytes) {
          return MpegTsCursorFailure{
              MpegTsDemuxError::SampleLimit,
              "mpeg-ts access unit exceeds the admitted sample size"};
        }
        completed->track = walk.pid;
        return *completed;
      }
      continue;
    }

    if (!walk.collecting) {
      continue;  // payload before the first unit start: not ours to keep
    }
    if (walk.packetCount >= kMaximumMpegTsAccessUnitPackets) {
      return MpegTsCursorFailure{
          MpegTsDemuxError::SampleLimit,
          "mpeg-ts access unit spans more packets than the cap admits"};
    }
    walk.appendPayload(
        packet.subspan(header.payloadOffset, header.payloadSize));
    if (!walk.tryHeader()) {
      walk.discardUnit();
    }
  }
}

// ---------------------------------------------------------------------------
// Payload gather
// ---------------------------------------------------------------------------

bool MpegTsPreparedAsset::copyAccessUnit(const MpegTsCompressedSample& sample,
                                         std::span<std::byte> destination,
                                         CancellationToken cancellation,
                                         MpegTsDemuxError* error) const
    noexcept {
  if (error != nullptr) {
    *error = MpegTsDemuxError::None;
  }
  const AssetState& state = *impl_->state;
  if (!state.unchanged()) {
    if (error != nullptr) {
      *error = MpegTsDemuxError::FileChanged;
    }
    return false;
  }
  if (destination.size() != sample.payloadBytes) {
    if (error != nullptr) {
      *error = MpegTsDemuxError::InvalidRequest;
    }
    return false;
  }
  if (destination.empty()) {
    return !cancellation.cancelled();
  }

  try {
    ReadWindow window(*state.reader);
    PacketWalker walker(window, state.framing);
    std::uint64_t position = sample.firstPacketOffset;
    std::size_t written = 0;
    std::uint32_t skipRemaining = sample.headerSkipBytes;
    std::uint32_t packets = 0;
    bool first = true;

    while (written < destination.size()) {
      if (cancellation.cancelled()) {
        if (error != nullptr) {
          *error = MpegTsDemuxError::Cancelled;
        }
        return false;
      }
      if (++packets > kMaximumMpegTsAccessUnitPackets) {
        if (error != nullptr) {
          *error = MpegTsDemuxError::SampleLimit;
        }
        return false;
      }
      const std::uint64_t packetOffset = position;
      std::span<const std::byte> packet;
      const WalkStatus status = walker.next(position, packet);
      if (status == WalkStatus::End) {
        break;
      }
      if (status == WalkStatus::Io) {
        if (error != nullptr) {
          *error = state.reader->size() == state.readerSize
                       ? MpegTsDemuxError::Io
                       : MpegTsDemuxError::FileChanged;
        }
        return false;
      }
      TsPacketHeader header{};
      if (decodeTsPacket(packet, header) != TsPacketStatus::Ok ||
          header.pid != sample.pid || !header.hasPayload ||
          header.payloadSize == 0) {
        continue;
      }
      // A payload-unit start after the first packet is the NEXT access unit;
      // the gather must stop there even if the recorded byte count disagrees,
      // because the packet stream is the authority.
      if (header.payloadUnitStart && !first &&
          packetOffset != sample.firstPacketOffset) {
        break;
      }
      first = false;
      std::span<const std::byte> payload =
          packet.subspan(header.payloadOffset, header.payloadSize);
      if (skipRemaining > 0) {
        const std::uint32_t drop = static_cast<std::uint32_t>(
            std::min<std::size_t>(skipRemaining, payload.size()));
        payload = payload.subspan(drop);
        skipRemaining -= drop;
        if (payload.empty()) {
          continue;
        }
      }
      const std::size_t take =
          std::min(payload.size(), destination.size() - written);
      std::memcpy(destination.data() + written, payload.data(), take);
      written += take;
    }

    if (written != destination.size()) {
      if (error != nullptr) {
        *error = MpegTsDemuxError::Io;
      }
      return false;
    }
    if (!state.unchanged()) {
      if (error != nullptr) {
        *error = MpegTsDemuxError::FileChanged;
      }
      return false;
    }
    if (cancellation.cancelled()) {
      if (error != nullptr) {
        *error = MpegTsDemuxError::Cancelled;
      }
      return false;
    }
    return true;
  } catch (...) {
    if (error != nullptr) {
      *error = MpegTsDemuxError::Io;
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Generation planning
// ---------------------------------------------------------------------------

MpegTsPlanOutcome
MpegTsPreparedAsset::planGeneration(MediaTime target, MediaSeekMode mode,
                                    CancellationToken cancellation) const
    noexcept {
  MpegTsPlanOutcome result{};
  try {
    const AssetState& state = *impl_->state;
    if (cancellation.cancelled()) {
      result.status = MpegTsDemuxStatus::Cancelled;
      result.error = MpegTsDemuxError::Cancelled;
      return result;
    }
    if (!state.unchanged()) {
      result.error = MpegTsDemuxError::FileChanged;
      result.message = "mpeg-ts file changed before planning";
      return result;
    }
    if (!target.valid() || target.value < 0) {
      result.error = MpegTsDemuxError::InvalidRequest;
      result.message = "seek target must be a valid nonnegative time";
      return result;
    }
    if (state.index.empty()) {
      result.error = MpegTsDemuxError::InvalidTimeline;
      result.message = "mpeg-ts index is empty";
      return result;
    }

    // Exact rational target -> 90 kHz ticks, rounded DOWN so the plan never
    // starts after the requested time. __int128 keeps a large timescale exact.
    const __int128 scaled = (static_cast<__int128>(target.value) *
                             static_cast<__int128>(kTimestampHz)) /
                            static_cast<__int128>(target.timescale);
    if (scaled > std::numeric_limits<std::int64_t>::max()) {
      result.error = MpegTsDemuxError::InvalidRequest;
      result.message = "seek target is outside the 90 kHz timeline";
      return result;
    }
    const std::int64_t targetTick =
        state.originTick + static_cast<std::int64_t>(scaled);

    // Binary search: the last index entry at or before the target. The ticks
    // are already unwrapped, so this is a plain integer compare even across a
    // 33-bit rollover boundary.
    const std::span<const MpegTsIndexEntry> entries(state.index);
    std::size_t low = 0;
    std::size_t high = entries.size();
    while (low < high) {
      const std::size_t mid = low + (high - low) / 2;
      if (entries[mid].tick <= targetTick) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    const std::size_t landedIndex = low == 0 ? 0 : low - 1;
    const MpegTsIndexEntry landed = entries[landedIndex];

    MpegTsGenerationPlan plan{};
    plan.requestedTarget = target;
    plan.mode = mode;
    plan.landedTick = landed.tick;

    // Refine forward from the bracket to the first video access unit that is
    // decodable from a cold decoder. Transport Stream has no index, so this is
    // where seek accuracy actually comes from — and the scan is bounded, so a
    // stream with no random access point in range is refused, not chased.
    std::uint64_t videoStart = landed.packetOffset;
    std::int64_t videoStartTick = landed.tick;
    std::uint32_t refinePackets = 0;
    if (state.hasVideo) {
      // BOUNDED BACKOFF, and it is the whole seek algorithm.
      //
      // The bisection lands on a PCR index point at or before the target, but
      // the last random access point can be EARLIER than that index point:
      // index points are spaced by BYTES and keyframes by TIME, so any stream
      // whose GOP is longer than the index spacing routinely puts the two on
      // opposite sides. A forward-only scan from the landed point then either
      // refuses an entirely seekable file (measured: every seek past 1.5 s in
      // a one-keyframe fixture came back ScanLimit) or, worse, silently lands
      // AFTER the target and skips the frame the user asked for (measured: six
      // of eight off-grid targets in a 20 s, 1 s-GOP fixture).
      //
      // So the scan tracks the two candidates separately — the last cold
      // random access point at or before the target, and the first one after
      // it — and steps back until it has the former.
      //
      // THE BACKOFF IS MEASURED IN TIME, NOT IN INDEX ENTRIES. It used to step
      // back a fixed sixteen entries, and that was a byte measure wearing a
      // time costume: index entries are spaced by BYTES, so how far sixteen of
      // them reach depends on the bitrate. Measured 2026-08-27 on two muxes of
      // the SAME 72 s clip with the SAME 8.33 s GOP: the 72 MB H.264 one has
      // ~0.5 s of media per entry and sixteen entries just reached the
      // preceding keyframe, while the 93 MB HEVC one has ~0.4 s per entry and
      // sixteen entries fell 0.8 s short. The seek then took the first-after
      // candidate, the plan started AFTER its own accurate target, and the
      // preview lane refused it by name -- a bitrate-dependent seek failure
      // with nothing to do with the codec.
      //
      // Now each round doubles how far back in MEDIA TIME it starts: the
      // landed entry, then 1 s, 2 s, 4 s before the target, and so on. Each
      // round's forward scan stops as soon as it passes the target, so a
      // round's cost is proportional to its own reach and the whole sequence
      // costs at most twice the final one. Reaching entry zero means the
      // stream genuinely has no random access point at or before the target,
      // and the first-after candidate is then used so the seek still lands
      // rather than being refused.
      constexpr std::size_t kMaximumBackoffRounds{24};
      std::optional<MpegTsCompressedSample> atOrBefore;
      std::optional<MpegTsCompressedSample> firstAfter;
      std::int64_t atOrBeforeTick = 0;
      std::int64_t firstAfterTick = 0;
      bool probeEndedBeforeSlice = false;
      std::int64_t backoffTicks = 0;
      std::size_t previousStartIndex = landedIndex + 1;

      for (std::size_t round = 0;
           round < kMaximumBackoffRounds && !atOrBefore; ++round) {
        std::size_t startIndex = landedIndex;
        if (round != 0) {
          backoffTicks = backoffTicks == 0
                             ? kTimestampHz
                             : std::min<std::int64_t>(
                                   backoffTicks * 2,
                                   std::numeric_limits<std::int64_t>::max() / 4);
          const std::int64_t floorTick = targetTick - backoffTicks;
          while (startIndex > 0 && entries[startIndex].tick > floorTick) {
            --startIndex;
          }
        }
        // A round that would rescan exactly what the previous one already did
        // buys nothing; skip straight to the next, wider reach.
        if (startIndex == previousStartIndex) {
          if (startIndex == 0) {
            break;
          }
          continue;
        }
        previousStartIndex = startIndex;
        ReadWindow window(*state.reader);
        PacketWalker walker(window, state.framing);
        StreamWalk walk{};
        walk.pid = state.video.pid;
        walk.codec = state.video.codec;
        walk.video = true;
        std::uint64_t position = alignPacketOffset(
            state.framing, entries[startIndex].packetOffset);
        const std::uint64_t scanLimit = std::min<std::uint64_t>(
            state.readerSize, position + kMpegTsSeekScanBytes);

        while (position < scanLimit) {
          if ((++refinePackets & 0x3FFU) == 0 && cancellation.cancelled()) {
            result.status = MpegTsDemuxStatus::Cancelled;
            result.error = MpegTsDemuxError::Cancelled;
            return result;
          }
          const std::uint64_t packetOffset = position;
          std::span<const std::byte> packet;
          const WalkStatus status = walker.next(position, packet);
          if (status == WalkStatus::End) {
            break;
          }
          if (status == WalkStatus::Io) {
            result.error = MpegTsDemuxError::Io;
            result.message = "mpeg-ts seek scan read failed";
            return result;
          }
          TsPacketHeader header{};
          if (decodeTsPacket(packet, header) != TsPacketStatus::Ok ||
              header.pid != walk.pid || !header.hasPayload ||
              header.payloadSize == 0) {
            continue;
          }
          // Same unit-start-only rule as readNext; see the note there.
          if (!header.payloadUnitStart) {
            if (walk.collecting) {
              walk.appendPayload(
                  packet.subspan(header.payloadOffset, header.payloadSize));
              if (!walk.tryHeader()) {
                walk.discardUnit();
              }
            }
            continue;
          }

          bool done = false;
          if (walk.collecting) {
            const std::optional<MpegTsCompressedSample> unit =
                finishUnit(state, walk, walk.pid, packetOffset);
            if (unit && unit->decodableFromCold &&
                unit->presentationTime.valid()) {
              const std::int64_t unitTick =
                  state.originTick +
                  static_cast<std::int64_t>(
                      (static_cast<__int128>(unit->presentationTime.value) *
                       kTimestampHz) /
                      unit->presentationTime.timescale);
              if (unitTick <= targetTick) {
                atOrBefore = *unit;
                atOrBeforeTick = unitTick;
              } else {
                if (!firstAfter || unitTick < firstAfterTick) {
                  firstAfter = *unit;
                  firstAfterTick = unitTick;
                }
                // Nothing later can be a better at-or-before candidate.
                done = true;
              }
            }
          }
          const bool wasRandomAccess = header.randomAccess;
          walk.beginUnit(packetOffset);
          walk.randomAccess = wasRandomAccess;
          walk.appendPayload(
              packet.subspan(header.payloadOffset, header.payloadSize));
          if (!walk.tryHeader()) {
            walk.discardUnit();
          }
          if (done) {
            break;
          }
        }
        probeEndedBeforeSlice =
            probeEndedBeforeSlice || walk.probeEndedBeforeSlice;
        if (startIndex == 0) {
          break;  // nothing earlier to back off to
        }
      }

      // KeyFrame mode asks for the nearest random access point in either
      // direction; Accurate mode must never skip the requested frame and so
      // only ever accepts the at-or-before candidate when one exists.
      const MpegTsCompressedSample* chosen = nullptr;
      if (mode == MediaSeekMode::KeyFrame && atOrBefore && firstAfter) {
        chosen = (targetTick - atOrBeforeTick) <= (firstAfterTick - targetTick)
                     ? &*atOrBefore
                     : &*firstAfter;
        videoStartTick =
            chosen == &*atOrBefore ? atOrBeforeTick : firstAfterTick;
      } else if (atOrBefore) {
        chosen = &*atOrBefore;
        videoStartTick = atOrBeforeTick;
      } else if (firstAfter) {
        chosen = &*firstAfter;
        videoStartTick = firstAfterTick;
      }
      if (chosen == nullptr) {
        result.error = MpegTsDemuxError::ScanLimit;
        // Two different facts wear the same refusal, and telling them apart
        // from a stderr capture is the difference between "this stream has a
        // long GOP" and "this stream's per-picture prologue is larger than the
        // probe, so the scan never saw a picture at all". The second was a
        // real, measured failure on HDR HEVC and cost a whole diagnosis pass.
        result.message =
            probeEndedBeforeSlice
                ? "no decodable random access point within the bounded seek "
                  "scan; the access-unit probe ended before any slice NAL, so "
                  "the picture prologue exceeds the probe"
                : "no decodable random access point within the bounded seek "
                  "scan";
        return result;
      }
      videoStart = chosen->firstPacketOffset;
    }

    plan.videoPacketOffset = videoStart;
    plan.audioPacketOffset = videoStart;
    plan.refineScanPackets = refinePackets;
    const std::optional<MediaTime> decodeStart =
        rebasedTime(videoStartTick, state.originTick);
    if (!decodeStart) {
      result.error = MpegTsDemuxError::InvalidTimeline;
      result.message = "seek landed outside the representable timeline";
      return result;
    }
    plan.actualDecodeStart = *decodeStart;
    if (state.hasAudio) {
      plan.audioWindow.decodeStart = *decodeStart;
      plan.audioWindow.presentationStart =
          landedIndex == 0 && targetTick <= state.originTick ? *decodeStart
                                                             : target;
      plan.audioWindow.startsAtStreamOrigin = videoStartTick <= state.originTick;
      if (compareMediaTime(plan.audioWindow.presentationStart,
                           plan.audioWindow.decodeStart) ==
          MediaTimeOrder::Less) {
        plan.audioWindow.presentationStart = plan.audioWindow.decodeStart;
      }
    }

    result.status = MpegTsDemuxStatus::Ready;
    result.error = MpegTsDemuxError::None;
    result.plan = plan;
    return result;
  } catch (...) {
    result.error = MpegTsDemuxError::Io;
    result.message = "mpeg-ts planning allocation failed";
    return result;
  }
}

std::unique_ptr<MpegTsCursor>
MpegTsPreparedAsset::makeVideoCursor(const MpegTsGenerationPlan& plan) const
    noexcept {
  try {
    const AssetState& state = *impl_->state;
    if (!state.hasVideo) {
      return nullptr;
    }
    auto impl = std::make_unique<MpegTsCursor::Impl>();
    impl->state = impl_->state;
    impl->window = std::make_unique<ReadWindow>(*state.reader);
    impl->walker.emplace(*impl->window, state.framing);
    impl->walk.pid = state.video.pid;
    impl->walk.codec = state.video.codec;
    impl->walk.video = true;
    impl->position =
        alignPacketOffset(state.framing, plan.videoPacketOffset);
    return std::unique_ptr<MpegTsCursor>(new MpegTsCursor(std::move(impl)));
  } catch (...) {
    return nullptr;
  }
}

std::unique_ptr<MpegTsCursor>
MpegTsPreparedAsset::makeAudioCursor(const MpegTsGenerationPlan& plan) const
    noexcept {
  try {
    const AssetState& state = *impl_->state;
    if (!state.hasAudio) {
      return nullptr;
    }
    auto impl = std::make_unique<MpegTsCursor::Impl>();
    impl->state = impl_->state;
    impl->window = std::make_unique<ReadWindow>(*state.reader);
    impl->walker.emplace(*impl->window, state.framing);
    impl->walk.pid = state.audio.pid;
    impl->walk.codec = state.audio.codec;
    impl->walk.video = false;
    impl->position =
        alignPacketOffset(state.framing, plan.audioPacketOffset);
    return std::unique_ptr<MpegTsCursor>(new MpegTsCursor(std::move(impl)));
  } catch (...) {
    return nullptr;
  }
}

// ---------------------------------------------------------------------------
// Preparation
// ---------------------------------------------------------------------------

namespace {

struct ProgramScanResult {
  ProgramAssociationTable pat{};
  ProgramMapTable pmt{};
  // Programs whose PMT was read but which lost the selection. Retained so the
  // verdict can NAME what it passed over instead of silently preferring one.
  std::array<std::uint16_t, kMaximumPrograms> rejectedPrograms{};
  std::uint8_t rejectedProgramCount{0};
  std::uint8_t pmtCount{0};      // PMTs actually parsed in the bounded scan
  bool hasPat{false};
  bool hasPmt{false};
  bool selectedIsComplete{false};  // chosen program had routable video AND audio
};

// The selection rule itself lives in mpegts_packet.hpp (ProgramGrade,
// gradeProgram) so it can be tested against a PMT directly rather than only
// through a whole file. What lives here is the SEARCH the rule drives.
//
// The old rule -- first program in PAT order carrying a video-KIND stream --
// picked a service that might have no audio at all, or audio in a codec this
// player cannot carry, while a complete service sat two entries later in the
// same PAT. The user heard silence and nothing named the choice.

// One bounded forward pass that collects the PAT and the best program's PMT.
//
// It can no longer stop at the first video-bearing program: deciding between
// grades means every program's PMT has to be read, so the pass runs to the
// bound unless it finds a Complete program at the FIRST PAT entry, which
// nothing later can beat under the rule above.
[[nodiscard]] MpegTsDemuxError
scanPrograms(ReadWindow& window, const MpegTsFraming& framing,
             CancellationToken cancellation, ProgramScanResult& out) noexcept {
  PacketWalker walker(window, framing);
  SectionAssembler patAssembler;
  std::array<SectionAssembler, kMaximumPrograms> pmtAssemblers{};
  // Grade and PAT index of the best program seen so far, and which PAT entries
  // have already been decided so a repeated PMT (every mux repeats them ~every
  // 100 ms) is not graded twice.
  ProgramGrade bestGrade = ProgramGrade::None;
  std::uint8_t bestIndex = 0;
  std::array<bool, kMaximumPrograms> decided{};
  std::uint64_t position = framing.firstSyncOffset;
  const std::uint64_t limit = std::min<std::uint64_t>(
      window.fileSize(), position + kMpegTsProgramScanBytes);
  std::uint64_t probes = 0;

  while (position < limit) {
    if ((++probes & 0x3FFU) == 0 && cancellation.cancelled()) {
      return MpegTsDemuxError::Cancelled;
    }
    std::span<const std::byte> packet;
    const WalkStatus status = walker.next(position, packet);
    if (status == WalkStatus::End) {
      break;
    }
    if (status == WalkStatus::Io) {
      return MpegTsDemuxError::Io;
    }
    TsPacketHeader header{};
    if (decodeTsPacket(packet, header) != TsPacketStatus::Ok ||
        !header.hasPayload || header.payloadSize == 0 ||
        header.transportError) {
      continue;
    }
    const std::span<const std::byte> payload =
        packet.subspan(header.payloadOffset, header.payloadSize);

    if (header.pid == kPatPid) {
      if (patAssembler.feed(payload, header.payloadUnitStart) ==
          SectionStatus::Ready) {
        ProgramAssociationTable table{};
        if (parseProgramAssociationSection(patAssembler.section(),
                                           patAssembler.header(), table) &&
            table.programCount > 0) {
          out.pat = table;
          out.hasPat = true;
        }
      }
      continue;
    }
    if (!out.hasPat) {
      continue;
    }
    for (std::uint8_t i = 0; i < out.pat.programCount; ++i) {
      if (out.pat.programs[i].pmtPid != header.pid) {
        continue;
      }
      if (decided[i]) {
        break;  // this program's PMT is already graded; skip the repeat
      }
      if (pmtAssemblers[i].feed(payload, header.payloadUnitStart) !=
          SectionStatus::Ready) {
        break;
      }
      ProgramMapTable table{};
      if (!parseProgramMapSection(pmtAssemblers[i].section(),
                                  pmtAssemblers[i].header(), table)) {
        break;
      }
      decided[i] = true;
      if (out.pmtCount < kMaximumPrograms) {
        ++out.pmtCount;
      }
      const ProgramGrade grade = gradeProgram(table);
      // Strictly greater, so PAT order breaks every tie: an equally-graded
      // program later in the PAT never displaces one already chosen.
      if (grade > bestGrade) {
        if (out.hasPmt && out.rejectedProgramCount < kMaximumPrograms) {
          out.rejectedPrograms[out.rejectedProgramCount++] =
              out.pmt.programNumber;
        }
        out.pmt = table;
        out.hasPmt = true;
        bestGrade = grade;
        bestIndex = i;
      } else if (grade != ProgramGrade::None &&
                 out.rejectedProgramCount < kMaximumPrograms) {
        out.rejectedPrograms[out.rejectedProgramCount++] = table.programNumber;
      }
      // Nothing later in the PAT can beat a Complete program at entry zero, so
      // the common single-program and well-ordered-multiplex cases still stop
      // as early as they ever did.
      if (bestGrade == ProgramGrade::Complete && bestIndex == 0) {
        out.selectedIsComplete = true;
        return MpegTsDemuxError::None;
      }
      break;
    }
    // Every PAT entry has been graded: no later packet can change the answer.
    if (out.hasPat && out.pmtCount >= out.pat.programCount) {
      break;
    }
  }
  if (!out.hasPat) {
    return MpegTsDemuxError::MissingProgramTable;
  }
  if (!out.hasPmt) {
    return MpegTsDemuxError::ProgramSelection;
  }
  out.selectedIsComplete = bestGrade == ProgramGrade::Complete;
  return MpegTsDemuxError::None;
}

// How many consecutive video access units the timing scan observes before it
// is willing to state a frame extent. Eight units is under a third of a second
// at 25 fps and costs nothing against the 4 MiB program scan that already
// bounds this pass, while giving seven deltas to take a minimum over -- enough
// that one dropped or duplicated unit cannot set the answer on its own.
inline constexpr std::uint32_t kMpegTsTimingUnits{8};

// Walks the LOAS frames of one audio PES payload looking for the first that
// carries a StreamMuxConfig. Returns the parse verdict of the frame that
// settled the question so a refusal can be named: a stream whose config states
// a mux shape this route does not carry must say UnsupportedMux, not "no
// config found".
//
// A capture that begins mid-broadcast legitimately opens on frames that reuse a
// config it never saw, so "no config in this PES" is NOT a failure -- the
// caller keeps scanning. Only a config that is present and unusable is.
[[nodiscard]] LatmStatus
findLatmStreamMuxConfig(std::span<const std::byte> payload,
                        LatmStreamMuxConfig& config) noexcept {
  std::size_t offset = 0;
  while (offset + kLoasHeaderBytes <= payload.size()) {
    LatmFrame frame{};
    // No established config: a frame that reuses one reports ConfigUnavailable
    // and is skipped by its own declared length, which is readable from the
    // sync layer alone and needs none of the mux state.
    const LatmStatus status =
        parseLatmFrame(payload.subspan(offset), nullptr, frame);
    if (status == LatmStatus::Ok && frame.configPresent) {
      config = frame.config;
      return LatmStatus::Ok;
    }
    if (status == LatmStatus::UnsupportedMux || status == LatmStatus::Malformed) {
      return status;
    }
    if (status == LatmStatus::Incomplete) {
      return LatmStatus::Incomplete;
    }
    if (status == LatmStatus::NotSynced) {
      ++offset;
      continue;
    }
    // ConfigUnavailable: a well-formed frame that reuses the established
    // config. Its length is known, so step over it exactly.
    if (frame.frameBytes == 0U) {
      return LatmStatus::Malformed;
    }
    offset += frame.frameBytes;
  }
  return LatmStatus::ConfigUnavailable;
}

[[nodiscard]] std::string hexStreamType(std::uint8_t type) {
  std::string text = "0x";
  text += "0123456789ABCDEF"[(type >> 4) & 0x0FU];
  text += "0123456789ABCDEF"[type & 0x0FU];
  return text;
}

struct FirstUnitFacts;
[[nodiscard]] std::string audioDowngradeReason(std::uint8_t streamType,
                                               MediaCodec codec,
                                               const FirstUnitFacts& facts);

struct FirstUnitFacts {
  std::vector<std::byte> parameterSets;
  std::array<std::byte, 16> audioHeaderBytes{};
  // The AAC-LATM StreamMuxConfig, when the selected audio stream is one.
  LatmStreamMuxConfig latmConfig{};
  LatmStatus latmStatus{LatmStatus::ConfigUnavailable};
  bool hasLatmConfig{false};
  // Decode timestamps of the first kMpegTsTimingUnits video access units, in
  // emission (decode) order. StreamWalk always populates a decode tick, using
  // the presentation timestamp for streams that carry no explicit DTS.
  std::array<std::int64_t, kMpegTsTimingUnits> videoDecodeTicks{};
  std::uint64_t firstVideoPacket{0};
  std::int64_t firstVideoPts{0};
  std::int64_t firstAudioPts{0};
  std::uint32_t audioHeaderSize{0};
  std::uint32_t videoDecodeTickCount{0};
  bool hasVideoPts{false};
  bool hasAudioPts{false};
  bool hasParameterSets{false};
  bool hasAudioHeader{false};
};

// Why the selected audio stream was not carried. Every branch names something
// actionable: the framing that could not be read, the mux shape that is not
// carried, or the codec-level admission that refused.
std::string audioDowngradeReason(std::uint8_t streamType, MediaCodec codec,
                                 const FirstUnitFacts& facts) {
  const std::string type = hexStreamType(streamType);
  if (streamType == static_cast<std::uint8_t>(TsStreamType::LatmAac)) {
    if (!facts.hasLatmConfig) {
      return type + " (AAC-LATM) carried no usable StreamMuxConfig in the "
                    "bounded scan: " +
             latmStatusName(facts.latmStatus);
    }
    return type + " (AAC-LATM) StreamMuxConfig was refused by the shared AAC "
                  "admission";
  }
  if (codec == MediaCodec::Unknown) {
    return type + " has no routing family";
  }
  if (!facts.hasAudioHeader) {
    return type + " carried no readable frame header in the bounded scan";
  }
  return type + " frame header was refused by codec admission";
}

// Smallest positive decode-timestamp delta across the observed run, or zero
// when the run proves nothing. Integer throughout.
[[nodiscard]] std::uint32_t
measuredFrameDurationTicks(const FirstUnitFacts& facts) noexcept {
  std::int64_t best = 0;
  for (std::uint32_t i = 1; i < facts.videoDecodeTickCount; ++i) {
    const std::int64_t delta =
        facts.videoDecodeTicks[i] - facts.videoDecodeTicks[i - 1];
    if (delta > 0 && (best == 0 || delta < best)) {
      best = delta;
    }
  }
  // A frame extent above one second is not a frame rate this player admits and
  // is far more likely to be a timestamp anomaly than a real 1 fps stream.
  if (best <= 0 || best > kTimestampHz) {
    return 0;
  }
  return static_cast<std::uint32_t>(best);
}

// One bounded pass that finds, for each selected stream, the first access unit
// and everything preparation needs from it: the parameter sets that become the
// codec configuration, the first audio frame header, and the first PTS of each.
[[nodiscard]] MpegTsDemuxError
scanFirstUnits(ReadWindow& window, const MpegTsFraming& framing,
               std::uint16_t videoPid, MediaCodec videoCodec,
               std::uint16_t audioPid, bool audioIsLatm,
               CancellationToken cancellation, FirstUnitFacts& facts) {
  PacketWalker walker(window, framing);
  StreamWalk video{};
  video.pid = videoPid;
  video.codec = videoCodec;
  video.video = true;
  StreamWalk audio{};
  audio.pid = audioPid;
  audio.video = false;

  std::uint64_t position = framing.firstSyncOffset;
  const std::uint64_t limit = std::min<std::uint64_t>(
      window.fileSize(), position + kMpegTsProgramScanBytes);
  std::uint64_t probes = 0;
  const bool wantVideo = videoPid != kNullPid;
  const bool wantAudio = audioPid != kNullPid;

  while (position < limit) {
    if ((++probes & 0x3FFU) == 0 && cancellation.cancelled()) {
      return MpegTsDemuxError::Cancelled;
    }
    const std::uint64_t packetOffset = position;
    std::span<const std::byte> packet;
    const WalkStatus status = walker.next(position, packet);
    if (status == WalkStatus::End) {
      break;
    }
    if (status == WalkStatus::Io) {
      return MpegTsDemuxError::Io;
    }
    TsPacketHeader header{};
    if (decodeTsPacket(packet, header) != TsPacketStatus::Ok ||
        !header.hasPayload || header.payloadSize == 0) {
      continue;
    }
    StreamWalk* walk = nullptr;
    if (wantVideo && header.pid == videoPid) {
      walk = &video;
    } else if (wantAudio && header.pid == audioPid) {
      walk = &audio;
    }
    if (walk == nullptr) {
      continue;
    }
    if (header.payloadUnitStart) {
      if (walk->collecting && !walk->pendingHeader &&
          walk->rawBytes > walk->headerSkipBytes) {
        const std::size_t length = walk->probeFilled > walk->headerSkipBytes
                                       ? walk->probeFilled -
                                             walk->headerSkipBytes
                                       : 0U;
        const std::span<const std::byte> unit(
            walk->probe.data() + walk->headerSkipBytes, length);
        if (walk->video) {
          if (!facts.hasVideoPts && walk->hasPts) {
            facts.firstVideoPts = walk->ptsTick;
            facts.hasVideoPts = true;
            facts.firstVideoPacket = walk->firstPacketOffset;
          }
          if (walk->hasPts &&
              facts.videoDecodeTickCount < kMpegTsTimingUnits) {
            facts.videoDecodeTicks[facts.videoDecodeTickCount] = walk->dtsTick;
            ++facts.videoDecodeTickCount;
          }
          if (!facts.hasParameterSets) {
            const AccessUnitScan scan = scanAccessUnit(unit, walk->codec);
            if (scan.hasParameterSets && scan.parameterSetSize > 0 &&
                scan.parameterSetOffset + scan.parameterSetSize <=
                    unit.size()) {
              facts.parameterSets.assign(
                  unit.begin() + scan.parameterSetOffset,
                  unit.begin() + scan.parameterSetOffset +
                      scan.parameterSetSize);
              facts.hasParameterSets = true;
            }
          }
        } else {
          if (!facts.hasAudioPts && walk->hasPts) {
            facts.firstAudioPts = walk->ptsTick;
            facts.hasAudioPts = true;
          }
          if (!facts.hasAudioHeader && unit.size() >= 4) {
            const std::size_t take =
                std::min<std::size_t>(facts.audioHeaderBytes.size(),
                                      unit.size());
            std::memcpy(facts.audioHeaderBytes.data(), unit.data(), take);
            facts.audioHeaderSize = static_cast<std::uint32_t>(take);
            facts.hasAudioHeader = true;
          }
          // LATM's configuration is not in a fixed-size header the way ADTS's
          // is -- it lives in a StreamMuxConfig that a mux emits periodically
          // and omits from every frame in between. ffmpeg's latm muxer writes
          // it once at the head of a short clip; a broadcast capture that
          // begins mid-stream may not reach one for several PES packets. So
          // this keeps looking across access units instead of settling for the
          // first, bounded by the same 4 MiB program scan that bounds the rest.
          if (audioIsLatm && !facts.hasLatmConfig) {
            LatmStreamMuxConfig muxConfig{};
            const LatmStatus latmStatus =
                findLatmStreamMuxConfig(unit, muxConfig);
            facts.latmStatus = latmStatus;
            if (latmStatus == LatmStatus::Ok) {
              facts.latmConfig = muxConfig;
              facts.hasLatmConfig = true;
            } else if (latmStatus == LatmStatus::UnsupportedMux ||
                       latmStatus == LatmStatus::Malformed) {
              // A config that IS present and is not carriable settles the
              // question; scanning on would only find the same one restated.
              return MpegTsDemuxError::None;
            }
          }
        }
      }
      walk->beginUnit(packetOffset);
    }
    if (walk->collecting) {
      walk->appendPayload(
          packet.subspan(header.payloadOffset, header.payloadSize));
      if (!walk->tryHeader()) {
        walk->discardUnit();
      }
    }
    const bool videoDone =
        !wantVideo || (facts.hasVideoPts &&
                       facts.videoDecodeTickCount >= kMpegTsTimingUnits &&
                       (facts.hasParameterSets || videoCodec == MediaCodec::Unknown));
    const bool audioDone =
        !wantAudio || (facts.hasAudioPts && facts.hasAudioHeader &&
                       (!audioIsLatm || facts.hasLatmConfig));
    if (videoDone && audioDone) {
      return MpegTsDemuxError::None;
    }
  }
  return MpegTsDemuxError::None;
}

// Finds the first PCR at or after `from` on `pcrPid`, within one bounded probe
// window. Returns false when the window holds none, which is reported rather
// than interpolated.
[[nodiscard]] bool probePcr(ReadWindow& window, const MpegTsFraming& framing,
                            std::uint16_t pcrPid, std::uint64_t from,
                            std::uint64_t& packetOffset,
                            std::uint64_t& pcrBase) noexcept {
  PacketWalker walker(window, framing);
  std::uint64_t position = alignPacketOffset(framing, from);
  const std::uint64_t limit = std::min<std::uint64_t>(
      window.fileSize(), position + kMpegTsProbeWindowBytes);
  while (position < limit) {
    const std::uint64_t offset = position;
    std::span<const std::byte> packet;
    const WalkStatus status = walker.next(position, packet);
    if (status == WalkStatus::End || status == WalkStatus::Io) {
      return false;
    }
    TsPacketHeader header{};
    if (decodeTsPacket(packet, header) != TsPacketStatus::Ok) {
      continue;
    }
    if (header.pid != pcrPid || !header.hasPcr) {
      continue;
    }
    packetOffset = offset;
    pcrBase = header.pcrBase;
    return true;
  }
  return false;
}

// Finds the LAST PCR in the file by probing backwards in bounded windows.
[[nodiscard]] bool probeLastPcr(ReadWindow& window,
                                const MpegTsFraming& framing,
                                std::uint16_t pcrPid,
                                std::uint64_t& pcrBase) noexcept {
  const std::uint64_t size = window.fileSize();
  // Four windows back is 2 MiB, which contains a PCR for anything this player
  // admits; beyond that the file is refused rather than guessed at.
  for (int attempt = 1; attempt <= 4; ++attempt) {
    const std::uint64_t span =
        static_cast<std::uint64_t>(attempt) * kMpegTsProbeWindowBytes;
    const std::uint64_t from = size > span ? size - span : 0;
    PacketWalker walker(window, framing);
    std::uint64_t position = alignPacketOffset(framing, from);
    bool found = false;
    while (position < size) {
      std::span<const std::byte> packet;
      const WalkStatus status = walker.next(position, packet);
      if (status == WalkStatus::End || status == WalkStatus::Io) {
        break;
      }
      TsPacketHeader header{};
      if (decodeTsPacket(packet, header) != TsPacketStatus::Ok) {
        continue;
      }
      if (header.pid == pcrPid && header.hasPcr) {
        pcrBase = header.pcrBase;
        found = true;
      }
    }
    if (found) {
      return true;
    }
    if (from == 0) {
      break;
    }
  }
  return false;
}

// Highest presentation timestamp carried by either selected elementary stream,
// found by scanning the tail of the file.
//
// This exists because the PROGRAM CLOCK REFERENCE IS NOT THE END OF THE MEDIA.
// A PCR states when a byte should arrive at the decoder, and 13818-1's whole
// buffering model puts the presentation of a picture one end-to-end buffer
// delay AFTER the byte that carried it. Deriving the duration from the last
// PCR therefore under-reports by exactly that delay -- measured across this
// corpus it is 0.73 s to 0.88 s, every time, in the same direction. That is
// not a rounding error: it shortens the scrubber's range by most of a second,
// makes seeks near the end unrepresentable, and (the way it was actually
// found) truncates real audio whenever the short value happens to land on the
// audio frame grid, which is what made `video.ts` publish 247,424 of its
// 289,792 decoded frames and then starve the clock.
//
// Unwrapping cannot use a TimestampUnwrapper here, because a tail scan has not
// seen the stream that established the epoch. The PCR-derived end tick is
// within one buffer delay of the true end, so each raw 33-bit value is lifted
// into the epoch nearest that anchor -- exact integer arithmetic, and correct
// across the 33-bit wrap because a wrap period is 26 h 30 m while the
// ambiguity being resolved is under a second.
[[nodiscard]] std::int64_t liftNearAnchor(std::uint64_t raw,
                                          std::int64_t anchor) noexcept {
  std::int64_t candidate =
      (anchor / kTimestampModulus) * kTimestampModulus +
      static_cast<std::int64_t>(raw);
  while (candidate - anchor > kTimestampWrapThreshold) {
    candidate -= kTimestampModulus;
  }
  while (anchor - candidate > kTimestampWrapThreshold) {
    candidate += kTimestampModulus;
  }
  return candidate;
}

[[nodiscard]] bool probeLastPresentationTick(ReadWindow& window,
                                             const MpegTsFraming& framing,
                                             std::uint16_t videoPid,
                                             std::uint16_t audioPid,
                                             std::int64_t anchor,
                                             std::int64_t& lastTick) noexcept {
  const std::uint64_t size = window.fileSize();
  bool found = false;
  // The same four-window (2 MiB) tail budget probeLastPcr uses, and for the
  // same reason: it is a bounded refusal boundary rather than an unbounded
  // hunt backwards through a file.
  for (int attempt = 1; attempt <= 4 && !found; ++attempt) {
    const std::uint64_t span =
        static_cast<std::uint64_t>(attempt) * kMpegTsProbeWindowBytes;
    const std::uint64_t from = size > span ? size - span : 0;
    PacketWalker walker(window, framing);
    std::uint64_t position = alignPacketOffset(framing, from);
    while (position < size) {
      std::span<const std::byte> packet;
      const WalkStatus status = walker.next(position, packet);
      if (status == WalkStatus::End || status == WalkStatus::Io) {
        break;
      }
      TsPacketHeader header{};
      if (decodeTsPacket(packet, header) != TsPacketStatus::Ok ||
          !header.hasPayload || !header.payloadUnitStart ||
          header.payloadSize == 0) {
        continue;
      }
      if (header.pid != videoPid && header.pid != audioPid) {
        continue;
      }
      PesHeader pes{};
      if (decodePesHeader(packet.subspan(header.payloadOffset,
                                         header.payloadSize),
                          pes) != PesStatus::Ok ||
          !pes.hasPts) {
        continue;
      }
      const std::int64_t tick = liftNearAnchor(pes.pts, anchor);
      if (!found || tick > lastTick) {
        lastTick = tick;
        found = true;
      }
    }
    if (from == 0) {
      break;
    }
  }
  return found;
}

}  // namespace

MpegTsPrepareOutcome prepareMpegTs(std::shared_ptr<SeekableByteReader> reader,
                                   std::filesystem::path path,
                                   const MediaSourceOpenOptions& requested,
                                   CancellationToken cancellation) noexcept {
  MpegTsPrepareOutcome result{};
  try {
    if (reader == nullptr || reader->size() == 0 || path.empty()) {
      result.error = MpegTsDemuxError::InvalidRequest;
      result.message = "mpeg-ts preparation requires a reader and a path";
      return result;
    }
    std::string initialError;
    if (!validateMediaSourceInitialPosition(requested.initialPosition,
                                            &initialError)) {
      result.error = MpegTsDemuxError::InvalidRequest;
      result.message = std::move(initialError);
      return result;
    }
    if (cancellation.cancelled()) {
      result.status = MpegTsDemuxStatus::Cancelled;
      result.error = MpegTsDemuxError::Cancelled;
      return result;
    }

    auto state = std::make_shared<AssetState>();
    state->reader = std::move(reader);
    state->readerSize = state->reader->size();
    state->path = std::move(path);
    state->limits = clampMediaSourceLimits(requested.limits);

    ReadWindow window(*state->reader);

    // --- framing -----------------------------------------------------------
    {
      const std::size_t probeBytes = static_cast<std::size_t>(
          std::min<std::uint64_t>(kMpegTsReadWindowBytes, state->readerSize));
      const std::span<const std::byte> probe = window.at(0, probeBytes);
      if (probe.empty()) {
        result.error = MpegTsDemuxError::Io;
        result.message = "could not read the mpeg-ts probe window";
        return result;
      }
      if (!detectMpegTsFraming(probe, state->readerSize, state->framing)) {
        result.status = MpegTsDemuxStatus::Unsupported;
        result.error = MpegTsDemuxError::NotTransportStream;
        result.message = "no consistent transport stream packet framing";
        return result;
      }
    }

    // --- programs ----------------------------------------------------------
    ProgramScanResult programs{};
    {
      const MpegTsDemuxError error =
          scanPrograms(window, state->framing, cancellation, programs);
      if (error == MpegTsDemuxError::Cancelled) {
        result.status = MpegTsDemuxStatus::Cancelled;
        result.error = error;
        return result;
      }
      if (error != MpegTsDemuxError::None) {
        result.status = error == MpegTsDemuxError::Io
                            ? MpegTsDemuxStatus::Failed
                            : MpegTsDemuxStatus::Unsupported;
        result.error = error;
        result.message =
            error == MpegTsDemuxError::MissingProgramTable
                ? "no program association table within the bounded scan"
                : "no program carries a video elementary stream";
        return result;
      }
    }
    state->programNumber = programs.pmt.programNumber;
    state->pcrPid = programs.pmt.pcrPid;
    // A multiplex is not a media file, and choosing inside one is a decision
    // the user never got to make. Retain what was passed over so the choice is
    // inspectable now and a program picker has its seam later.
    for (std::uint8_t i = 0; i < programs.rejectedProgramCount &&
                             i < programs.rejectedPrograms.size();
         ++i) {
      state->otherPrograms.push_back(programs.rejectedPrograms[i]);
    }
    state->programSelectionComplete = programs.selectedIsComplete;

    // --- stream selection --------------------------------------------------
    MediaTrackInventory inventory{};
    const ElementaryStream* videoStream = nullptr;
    const ElementaryStream* audioStream = nullptr;
    std::uint8_t rejectedVideoType = 0;
    std::uint8_t rejectedAudioType = 0;
    for (std::uint8_t i = 0; i < programs.pmt.streamCount; ++i) {
      const ElementaryStream& stream = programs.pmt.streams[i];
      if (stream.kind == MediaTrackKind::Video) {
        if (inventory.video < std::numeric_limits<std::uint8_t>::max()) {
          ++inventory.video;
        }
        if (videoStream == nullptr && stream.codec != MediaCodec::Unknown) {
          videoStream = &stream;
        } else if (videoStream == nullptr && rejectedVideoType == 0) {
          rejectedVideoType = stream.streamType;
        }
      } else if (stream.kind == MediaTrackKind::Audio) {
        if (inventory.audio < std::numeric_limits<std::uint8_t>::max()) {
          ++inventory.audio;
        }
        if (audioStream == nullptr && stream.codec != MediaCodec::Unknown) {
          audioStream = &stream;
        } else if (audioStream == nullptr && rejectedAudioType == 0) {
          rejectedAudioType = stream.streamType;
        }
      } else {
        if (inventory.metadata < std::numeric_limits<std::uint8_t>::max()) {
          ++inventory.metadata;
        }
      }
    }
    inventory.total = static_cast<std::uint8_t>(
        std::min<int>(255, inventory.video + inventory.audio +
                               inventory.metadata));

    if (videoStream == nullptr) {
      result.status = MpegTsDemuxStatus::Unsupported;
      result.error = rejectedVideoType != 0
                         ? MpegTsDemuxError::UnsupportedStreamType
                         : MpegTsDemuxError::ProgramSelection;
      // Name the refused type. MPEG-2 video (0x02) has no MediaCodec
      // enumerator yet; that is a recorded, authorized-append-pending gap and
      // it must reach the caller by name rather than as a silent skip.
      result.message =
          rejectedVideoType != 0
              ? std::string("mpeg-ts video stream type is not routable: 0x") +
                    "0123456789ABCDEF"[(rejectedVideoType >> 4) & 0x0FU] +
                    "0123456789ABCDEF"[rejectedVideoType & 0x0FU]
              : std::string("selected mpeg-ts program has no video stream");
      return result;
    }
    // Defensive rather than load-bearing: codecForStreamType already yields
    // only these three for a video-kind stream type, and anything else has
    // been refused by name above. It stays so that a future routing append
    // cannot reach the descriptor code below without a matching branch there.
    if (videoStream->codec != MediaCodec::H264 &&
        videoStream->codec != MediaCodec::Hevc &&
        videoStream->codec != MediaCodec::Mpeg2Video) {
      result.status = MpegTsDemuxStatus::Unsupported;
      result.error = MpegTsDemuxError::UnsupportedStreamType;
      result.message =
          "mpeg-ts video admission is H.264, HEVC and MPEG-2 only";
      return result;
    }

    state->video.pid = videoStream->elementaryPid;
    state->video.streamType = videoStream->streamType;
    state->video.codec = videoStream->codec;
    state->video.kind = MediaTrackKind::Video;
    state->video.id = videoStream->elementaryPid;
    state->hasVideo = true;
    if (audioStream != nullptr) {
      state->audio.pid = audioStream->elementaryPid;
      state->audio.streamType = audioStream->streamType;
      state->audio.codec = audioStream->codec;
      state->audio.kind = MediaTrackKind::Audio;
      state->audio.id = audioStream->elementaryPid;
      state->hasAudio = true;
    }
    static_cast<void>(rejectedAudioType);

    // --- first access units ------------------------------------------------
    FirstUnitFacts facts{};
    {
      const bool audioIsLatm =
          state->hasAudio &&
          state->audio.streamType ==
              static_cast<std::uint8_t>(TsStreamType::LatmAac);
      const MpegTsDemuxError error = scanFirstUnits(
          window, state->framing, state->video.pid, state->video.codec,
          state->hasAudio ? state->audio.pid : kNullPid, audioIsLatm,
          cancellation, facts);
      if (error == MpegTsDemuxError::Cancelled) {
        result.status = MpegTsDemuxStatus::Cancelled;
        result.error = error;
        return result;
      }
      if (error != MpegTsDemuxError::None) {
        result.error = error;
        result.message = "mpeg-ts elementary stream scan failed";
        return result;
      }
    }
    if (!facts.hasVideoPts) {
      result.error = MpegTsDemuxError::InvalidTimeline;
      result.message = "no video presentation timestamp in the bounded scan";
      return result;
    }
    if (!facts.hasParameterSets) {
      result.status = MpegTsDemuxStatus::Unsupported;
      result.error = MpegTsDemuxError::CodecConfiguration;
      result.message =
          state->video.codec == MediaCodec::Mpeg2Video
              ? "no in-band MPEG-2 sequence header in the bounded scan"
          : state->video.codec == MediaCodec::Hevc
              ? "no in-band HEVC VPS/SPS/PPS in the bounded scan"
              : "no in-band H.264 parameter sets in the bounded scan";
      return result;
    }

    // --- video frame extent -------------------------------------------------
    // See AssetState::videoFrameDurationTicks for why this is established here
    // and never left to a downstream guess.
    if (state->video.codec == MediaCodec::Mpeg2Video) {
      const std::optional<Mpeg2SequenceHeader> sequence =
          parseMpeg2SequenceHeader(facts.parameterSets);
      if (sequence) {
        state->videoFrameDurationTicks =
            mpeg2FrameDurationTicks(sequence->frameRateCode);
      }
    }
    if (state->videoFrameDurationTicks == 0) {
      state->videoFrameDurationTicks = measuredFrameDurationTicks(facts);
    }
    if (state->videoFrameDurationTicks == 0) {
      result.error = MpegTsDemuxError::InvalidTimeline;
      result.message =
          "no exact video frame extent could be established from the stream";
      return result;
    }

    // --- timeline ----------------------------------------------------------
    state->videoOriginTick = facts.firstVideoPts;
    state->originTick = facts.hasAudioPts
                            ? std::min(facts.firstVideoPts, facts.firstAudioPts)
                            : facts.firstVideoPts;

    std::uint64_t firstPcrBase = 0;
    std::uint64_t lastPcrBase = 0;
    std::uint64_t pcrOffset = 0;
    MediaTime duration{};
    if (state->pcrPid != kNullPid &&
        probePcr(window, state->framing, state->pcrPid,
                 state->framing.firstSyncOffset, pcrOffset, firstPcrBase) &&
        probeLastPcr(window, state->framing, state->pcrPid, lastPcrBase)) {
      TimestampUnwrapper pcrUnwrap;
      const std::int64_t first = pcrUnwrap.extend(firstPcrBase);
      const std::int64_t last = pcrUnwrap.extend(lastPcrBase);
      std::int64_t endTick = last;
      // The last PCR is a floor on the end of the media, never the end itself.
      // Prefer the highest presentation timestamp either selected stream
      // carries, extended by one video frame so the final picture's whole
      // interval is inside the timeline.
      std::int64_t lastPresentation = 0;
      if (probeLastPresentationTick(
              window, state->framing, state->video.pid,
              state->hasAudio ? state->audio.pid : kNullPid, last,
              lastPresentation)) {
        const std::int64_t presentationEnd =
            lastPresentation +
            static_cast<std::int64_t>(state->videoFrameDurationTicks);
        if (presentationEnd > endTick) {
          endTick = presentationEnd;
        }
      }
      if (endTick > first) {
        const std::optional<MediaTime> span =
            mediaTimeFromTicks(endTick - state->originTick);
        if (span && span->value > 0) {
          duration = *span;
        }
      }
      state->endTick = endTick;
    }
    if (!duration.valid()) {
      result.error = MpegTsDemuxError::InvalidTimeline;
      result.message = "could not derive a positive duration from the PCR";
      return result;
    }

    // --- index -------------------------------------------------------------
    // A sparse PCR index, built rather than read. Probe points are evenly
    // spaced by byte position; each probe is one bounded read that finds the
    // next PCR after that position. The result is monotone in both byte offset
    // and (unwrapped) tick, which is exactly what the bisection needs.
    {
      TimestampUnwrapper indexUnwrap;
      const std::uint64_t span = state->readerSize;
      const std::size_t probes =
          static_cast<std::size_t>(std::min<std::uint64_t>(
              kMpegTsIndexProbeCount,
              std::max<std::uint64_t>(1, span / kMpegTsProbeWindowBytes + 1)));
      state->index.reserve(probes + 1);
      std::uint64_t previousOffset = 0;
      std::int64_t previousTick = std::numeric_limits<std::int64_t>::min();
      for (std::size_t i = 0; i < probes; ++i) {
        if (cancellation.cancelled()) {
          result.status = MpegTsDemuxStatus::Cancelled;
          result.error = MpegTsDemuxError::Cancelled;
          return result;
        }
        const std::uint64_t from =
            state->framing.firstSyncOffset + (span / probes) * i;
        std::uint64_t offset = 0;
        std::uint64_t base = 0;
        if (!probePcr(window, state->framing, state->pcrPid, from, offset,
                      base)) {
          continue;
        }
        const std::int64_t tick = indexUnwrap.extend(base);
        if (!state->index.empty() &&
            (offset <= previousOffset || tick <= previousTick)) {
          continue;  // not strictly increasing: drop rather than corrupt
        }
        if (state->index.size() >= kMaximumMpegTsIndexEntries) {
          result.error = MpegTsDemuxError::IndexLimit;
          result.message = "mpeg-ts index exceeded its hard entry cap";
          return result;
        }
        MpegTsIndexEntry entry{};
        entry.packetOffset = offset;
        entry.tick = tick;
        entry.flags = MpegTsIndexEntry::kFlagFromPcr;
        state->index.push_back(entry);
        previousOffset = offset;
        previousTick = tick;
      }
      if (state->index.empty()) {
        result.error = MpegTsDemuxError::InvalidTimeline;
        result.message = "no program clock reference found for the index";
        return result;
      }
      // The first index entry must not sort after the stream origin, or a seek
      // to zero has nothing to bisect against.
      if (state->index.front().tick > state->originTick) {
        MpegTsIndexEntry entry{};
        entry.packetOffset = state->framing.firstSyncOffset;
        entry.tick = state->originTick;
        entry.flags = MpegTsIndexEntry::kFlagFromPcr;
        state->index.insert(state->index.begin(), entry);
      }
    }

    if (!state->unchanged()) {
      result.error = MpegTsDemuxError::FileChanged;
      result.message = "file identity changed during preparation";
      return result;
    }

    // --- descriptor --------------------------------------------------------
    auto descriptor = std::make_shared<MediaSourceDescriptor>();
    descriptor->duration = duration;
    descriptor->inventory = inventory;

    if (state->video.codec == MediaCodec::Mpeg2Video) {
      // MPEG-2 needs NO decoder configuration record at all: the sequence
      // header is in-band and CMVideoFormatDescriptionCreate takes a null
      // extensions dictionary (measured in scratchpad/vt_mpeg2_probe.mm).
      // `inspectVideoCodecConfiguration` therefore has nothing to inspect, and
      // the geometry gate it would have applied is restated by hand here so
      // MPEG-2 is held to the same admission envelope as every other codec.
      const std::optional<Mpeg2SequenceHeader> sequence =
          parseMpeg2SequenceHeader(facts.parameterSets);
      if (!sequence || sequence->width == 0 || sequence->height == 0) {
        result.status = MpegTsDemuxStatus::Unsupported;
        result.error = MpegTsDemuxError::CodecConfiguration;
        result.message = "in-band MPEG-2 sequence header has no geometry";
        return result;
      }
      if (!state->limits.codedDimensionsAdmitted(sequence->width,
                                                 sequence->height)) {
        result.status = MpegTsDemuxStatus::Unsupported;
        result.error = MpegTsDemuxError::CodecConfiguration;
        // Both numbers, not just the word "exceeds": the cap is a constant the
        // reader of a stderr capture does not have in front of them.
        result.message = codedDimensionRefusalMessage(sequence->width,
                                                      sequence->height);
        return result;
      }
      MediaTrackDescriptor track{};
      track.id = state->video.id;
      track.kind = MediaTrackKind::Video;
      track.codec = MediaCodec::Mpeg2Video;
      track.timeBase = MediaTime{1, kTimestampHz};
      track.duration = duration;
      // The validator admits a None configuration kind only with an empty
      // configuration vector, which is exactly the truth for MPEG-2.
      track.codecConfigurationKind = MediaCodecConfigurationKind::None;
      track.codecConfiguration.clear();
      MediaVideoFormat format{};
      format.codedWidth = sequence->width;
      format.codedHeight = sequence->height;
      format.displayWidth = sequence->width;
      format.displayHeight = sequence->height;
      format.bitsPerComponent = 8;
      format.progressive = true;
      format.sampleFormat = MediaVideoSampleFormat::Yuv420EightBit;
      track.video = format;
      descriptor->selectedVideo = track.id;
      descriptor->tracks.push_back(std::move(track));
    } else {
      // H.264 and HEVC share every step from here: both arrive as Annex-B
      // with in-band parameter sets, both have their out-of-band record
      // synthesized from exactly those sets, and both hand that record to the
      // one shared inspector rather than trusting the synthesis.
      const bool hevc = state->video.codec == MediaCodec::Hevc;
      const MediaCodecConfigurationKind configurationKind =
          hevc ? MediaCodecConfigurationKind::HvcC
               : MediaCodecConfigurationKind::AvcC;
      std::vector<std::byte> avcc;
      const bool built = hevc ? buildHvcCFromAnnexB(facts.parameterSets, avcc)
                              : buildAvcCFromAnnexB(facts.parameterSets, avcc);
      if (!built) {
        result.status = MpegTsDemuxStatus::Unsupported;
        result.error = MpegTsDemuxError::CodecConfiguration;
        result.message =
            hevc ? "could not synthesize an hvcC from in-band VPS/SPS/PPS"
                 : "could not synthesize an avcC from in-band SPS/PPS";
        return result;
      }
      VideoCodecConfigurationLimits codecLimits{};
      codecLimits.maximumWidth = state->limits.maximumCodedWidth;
      codecLimits.maximumHeight = state->limits.maximumCodedHeight;
      codecLimits.maximumPixels = state->limits.maximumCodedPixels;
      // The transport stream has no colour box at all -- no `colr`, no
      // Matroska Colour element -- so the SPS VUI is the ONLY colour
      // statement, and this flag is what lets the shared SPS parser carry a
      // BT.2020/PQ or HLG one through instead of refusing it.
      //
      // The flag's own contract (video_codec_configuration.hpp) is that a
      // route may turn it on only if it also carries the colour description
      // onto the CMVideoFormatDescription it synthesizes. This route now
      // does: createMpegTsVideoFormatDescription writes ColorPrimaries,
      // TransferFunction and YCbCrMatrix extensions from exactly the facts
      // mapped below. Turning this on WITHOUT that would hand VideoToolbox a
      // PQ stream with nothing to attach to the surface, which renders as
      // washed-out SDR -- worse than the named refusal it replaced.
      codecLimits.admitHighDynamicRangeColor = true;
      const VideoCodecConfigurationInspection inspection =
          inspectVideoCodecConfiguration(state->video.codec,
                                         configurationKind, avcc, codecLimits);
      if (!inspection.admitted()) {
        result.status = MpegTsDemuxStatus::Unsupported;
        result.error = MpegTsDemuxError::CodecConfiguration;
        // Name the inspector's own verdict. "Refused" alone cost a whole
        // debugging pass on the HEVC lane, where the record was byte-correct
        // and the refusal was a color-description envelope the synthesis had
        // no say in.
        result.message =
            std::string(hevc ? "synthesized hvcC was refused by the shared "
                               "codec inspector: "
                             : "synthesized avcC was refused by the shared "
                               "codec inspector: ") +
            videoCodecConfigurationErrorName(inspection.error);
        return result;
      }
      const VideoCodecConfigurationFacts& codec = *inspection.facts;

      MediaTrackDescriptor track{};
      track.id = state->video.id;
      track.kind = MediaTrackKind::Video;
      track.codec = state->video.codec;
      track.timeBase = MediaTime{1, kTimestampHz};
      track.duration = duration;
      track.codecConfigurationKind = configurationKind;
      track.codecConfiguration = std::move(avcc);
      MediaVideoFormat format{};
      format.codedWidth = codec.width;
      format.codedHeight = codec.height;
      format.displayWidth = codec.width;
      format.displayHeight = codec.height;
      format.bitsPerComponent = codec.bitDepth;
      format.progressive = true;
      format.sampleFormat = codec.sampleFormat;
      if (codec.color.colorDescriptionPresent) {
        format.colorPrimaries =
            mediaColorPrimariesFromIso(codec.color.colorPrimaries);
        format.transferFunction =
            mediaTransferFunctionFromIso(codec.color.transferCharacteristics);
        format.matrixCoefficients =
            mediaMatrixCoefficientsFromIso(codec.color.matrixCoefficients);
      }
      track.video = format;
      descriptor->selectedVideo = track.id;
      descriptor->tracks.push_back(std::move(track));
    }

    if (state->hasAudio) {
      MediaTrackDescriptor track{};
      track.id = state->audio.id;
      track.kind = MediaTrackKind::Audio;
      track.codec = state->audio.codec;
      track.duration = duration;
      MediaAudioFormat format{};
      bool admitted = false;

      const std::span<const std::byte> audioHeader(
          facts.audioHeaderBytes.data(), facts.audioHeaderSize);
      if (state->audio.codec == MediaCodec::Aac) {
        // ONE admission for two framings. ADTS restates the configuration in a
        // fixed header on every frame and the ASC is synthesized from it;
        // LOAS/LATM carries a real AudioSpecificConfig inside its
        // StreamMuxConfig and the ASC is READ, not synthesized. From the ASC
        // onwards -- cookie, sample rate, channel count, the 1024-frame grid,
        // the audio-authoritative clock -- the two are the same stream, which
        // is why LATM needs no MediaCodec value of its own.
        const bool latm = state->audio.streamType ==
                          static_cast<std::uint8_t>(TsStreamType::LatmAac);
        std::array<std::byte, kMaximumLatmAudioSpecificConfigBytes> config{};
        std::size_t configSize = 0;
        bool haveConfig = false;
        if (latm) {
          if (facts.hasLatmConfig) {
            const std::span<const std::byte> asc = facts.latmConfig.config();
            if (!asc.empty() && asc.size() <= config.size()) {
              std::memcpy(config.data(), asc.data(), asc.size());
              configSize = asc.size();
              haveConfig = true;
            }
          }
          if (!haveConfig) {
            // Name which of the two LATM refusals this is. "No audio" is what
            // the user hears either way, but a capture that simply never
            // reached a StreamMuxConfig inside the bounded scan and a stream
            // whose config states a mux shape this route cannot carry are
            // different problems with different fixes.
            rejectedAudioType = state->audio.streamType;
          }
        } else {
          AdtsHeader adts{};
          std::array<std::byte, 2> adtsConfig{};
          if (facts.hasAudioHeader && parseAdtsHeader(audioHeader, adts) &&
              audioSpecificConfigFromAdts(adts, adtsConfig)) {
            std::memcpy(config.data(), adtsConfig.data(), adtsConfig.size());
            configSize = adtsConfig.size();
            haveConfig = true;
          }
        }
        if (haveConfig) {
          const AacLcAdmission admission = parseAacLcAudioSpecificConfig(
              std::span<const std::byte>(config.data(), configSize));
          if (admission.admitted()) {
            const std::optional<AacLcEsDescriptorCookie> cookie =
                buildAacLcEsDescriptorCookie(*admission.configuration);
            if (cookie) {
              track.timeBase = MediaTime{
                  1, static_cast<std::int32_t>(
                         admission.configuration->sampleRate)};
              track.codecConfigurationKind =
                  MediaCodecConfigurationKind::AudioMagicCookie;
              track.codecConfiguration.assign(cookie->view().begin(),
                                              cookie->view().end());
              format.sampleRate =
                  static_cast<double>(admission.configuration->sampleRate);
              format.channels = admission.configuration->channelCount;
              format.formatTag = kAacFormatTag;
              format.framesPerPacket = kAacLcSamplesPerAccessUnit;
              // Mono and stereo keep their canonical tags. A wider AAC layout
              // states none: this demuxer knows a channel count, not
              // AudioToolbox's per-codec channel ORDER, and the platform layer
              // reads the authoritative order back from the decoder before
              // folding to stereo. Stating the stereo tag on a six-channel
              // track -- which is what the old expression did the moment the
              // AAC parser widened -- would be an outright false statement.
              format.channelLayoutTag =
                  admission.configuration->channelCount == 1   ? kMonoLayoutTag
                  : admission.configuration->channelCount == 2 ? kStereoLayoutTag
                                                               : 0U;
              format.channelLayoutPresent =
                  admission.configuration->channelCount <= 2;
              state->audio.sampleRate = admission.configuration->sampleRate;
              state->audio.channels = admission.configuration->channelCount;
              state->audio.samplesPerFrame = kAacLcSamplesPerAccessUnit;
              if (latm) {
                // Retained so the platform layer's per-frame LOAS walk can
                // start on any frame, including one a seek landed on that
                // reuses this config without restating it.
                state->latmConfig = facts.latmConfig;
              }
              admitted = true;
            }
          }
        }
      } else if (state->audio.codec == MediaCodec::Ac3 ||
                 state->audio.codec == MediaCodec::Eac3) {
        // AC-3 and E-AC-3 restate every parameter in each syncframe and take
        // NO magic cookie -- measured by the parallel Matroska audio lane in
        // scratchpad/sweep_probe.mm, where AudioConverterNew succeeds with the
        // cookie property never set. This reuses that codec-level admission,
        // not Matroska's block-level framing: a TS PES carries whole
        // syncframes back to back and the media source splits them itself.
        Ac3SyncFrame frame{};
        if (facts.hasAudioHeader &&
            parseAc3OrEac3SyncFrame(audioHeader, frame) &&
            frame.channels > 0 &&
            frame.channels <= state->limits.maximumAudioChannels &&
            frame.sampleRate > 0) {
          track.timeBase =
              MediaTime{1, static_cast<std::int32_t>(frame.sampleRate)};
          track.codecConfigurationKind = MediaCodecConfigurationKind::None;
          format.sampleRate = static_cast<double>(frame.sampleRate);
          format.channels = frame.channels;
          format.formatTag = state->audio.codec == MediaCodec::Eac3
                                 ? kEnhancedAc3FormatTag
                                 : kAc3FormatTag;
          // A-52 codes 6 blocks of 256 samples per syncframe. E-AC-3 may code
          // 1, 2, 3 or 6, and the parser now READS which -- a stream of short
          // blocks used to be described as 1536 frames per packet, which is a
          // four-times timing error on the audio-authoritative clock. A frame
          // that restates a different count mid-stream is still refused by the
          // per-frame walk in the media source.
          format.framesPerPacket = frame.samplesPerFrame;
          // Mono and stereo keep their canonical tags. A wider layout states
          // none, exactly as the AAC branch above does and for the same
          // reason: this demuxer knows a channel COUNT, not AudioToolbox's
          // per-codec channel ORDER, and the platform layer reads the
          // authoritative order back from the decoder before folding.
          format.channelLayoutTag =
              frame.channels == 1 ? kMonoLayoutTag
              : frame.channels == 2
                  ? kStereoLayoutTag
                  : 0U;
          format.channelLayoutPresent = frame.channels <= 2;
          state->audio.sampleRate = frame.sampleRate;
          state->audio.channels = frame.channels;
          state->audio.samplesPerFrame = frame.samplesPerFrame;
          // The old ceiling was `channels <= 2`, which dropped every 5.1 AC-3
          // soundtrack to silence. It is lifted to the same limit every other
          // codec on this route is held to, now that the LFE channel is
          // actually counted (it was hardcoded absent, so a 5.1 stream was
          // described as five channels) and now that 5.1 AAC has been proved
          // through the same tag-less wider-layout path end to end.
          admitted = frame.samplesPerFrame > 0;
        }
      } else if (state->audio.codec == MediaCodec::Mp3) {
        MpegAudioFrame frame{};
        if (facts.hasAudioHeader && parseMpegAudioFrame(audioHeader, frame) &&
            frame.channels > 0 && frame.channels <= 2) {
          track.timeBase =
              MediaTime{1, static_cast<std::int32_t>(frame.sampleRate)};
          track.codecConfigurationKind = MediaCodecConfigurationKind::None;
          format.sampleRate = static_cast<double>(frame.sampleRate);
          format.channels = frame.channels;
          format.formatTag = frame.layer == 3 ? kMpegLayer3FormatTag
                                              : kMpegLayer2FormatTag;
          format.framesPerPacket = frame.samplesPerFrame;
          format.channelLayoutTag =
              frame.channels == 1 ? kMonoLayoutTag : kStereoLayoutTag;
          format.channelLayoutPresent = true;
          state->audio.sampleRate = frame.sampleRate;
          state->audio.channels = frame.channels;
          state->audio.samplesPerFrame = frame.samplesPerFrame;
          admitted = true;
        }
      }

      if (admitted) {
        track.audio = format;
        descriptor->selectedAudio = track.id;
        descriptor->tracks.push_back(std::move(track));
      } else {
        // The audio stream stays in the inventory and out of the selection.
        // Refusing the whole file for an unroutable audio track would reject
        // playable video, which is exactly the silent-drop failure mode this
        // demuxer is built to avoid — so it is a recorded downgrade, not a
        // silent one, and the caller sees selectedAudio absent.
        //
        // "Recorded" now means recorded. Until this lane the downgrade left NO
        // trace anywhere: an AAC-LATM broadcast opened as a silent video and
        // nothing in the outcome said why, which is how stream type 0x11 sat
        // unnoticed. The Ready outcome's message is read by nobody in the
        // adapter (it is consulted only when status != Ready), so stating the
        // reason here costs nothing and makes the downgrade testable.
        state->hasAudio = false;
        result.message = "mpeg-ts audio stream dropped: " +
                         audioDowngradeReason(state->audio.streamType,
                                              state->audio.codec, facts);
      }
    }

    std::string descriptorError;
    if (!validateMediaSourceDescriptor(*descriptor, state->limits,
                                       &descriptorError)) {
      result.error = MpegTsDemuxError::CodecConfiguration;
      result.message = std::move(descriptorError);
      return result;
    }
    state->descriptor = descriptor;

    auto asset = std::shared_ptr<MpegTsPreparedAsset>(new MpegTsPreparedAsset(
        std::make_unique<MpegTsPreparedAsset::Impl>(state)));

    if (requested.initialPosition) {
      const MpegTsPlanOutcome planned =
          asset->planGeneration(requested.initialPosition->target,
                                requested.initialPosition->mode, cancellation);
      if (planned.status != MpegTsDemuxStatus::Ready) {
        result.status = planned.status;
        result.error = planned.error;
        result.message = planned.message;
        return result;
      }
    }

    result.status = MpegTsDemuxStatus::Ready;
    result.error = MpegTsDemuxError::None;
    result.asset = std::move(asset);
    return result;
  } catch (...) {
    result.error = MpegTsDemuxError::Io;
    result.message = "mpeg-ts preparation allocation failed";
    return result;
  }
}

MpegTsPrepareOutcome
prepareMpegTsLocalFile(const std::filesystem::path& path,
                       const MediaSourceOpenOptions& options,
                       CancellationToken cancellation) noexcept {
  if (cancellation.cancelled()) {
    return {MpegTsDemuxStatus::Cancelled, MpegTsDemuxError::Cancelled, nullptr,
            {}};
  }
  std::shared_ptr<StableFileReader> reader = StableFileReader::open(path);
  if (reader == nullptr) {
    return {MpegTsDemuxStatus::Failed, MpegTsDemuxError::Io, nullptr,
            "could not open the local mpeg-ts file"};
  }
  MpegTsPrepareOutcome outcome =
      prepareMpegTs(reader, path, options, cancellation);
  if (outcome.asset) {
    const_cast<AssetState*>(outcome.asset->impl_->state.get())->localReader =
        std::move(reader);
  }
  return outcome;
}

}  // namespace wam::media::mpegts
