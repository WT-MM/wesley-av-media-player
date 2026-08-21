#pragma once

#include "media/matroska_ebml.hpp"
#include "media/mpegts_packet.hpp"
#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <type_traits>
#include <variant>

namespace wam::media::mpegts {

// SeekableByteReader, CancellationToken, ByteRange and FrameRange are
// container-neutral and already exist; they live in the Matroska namespace only
// because that is where the first demuxer needed them. Aliasing rather than
// re-declaring keeps one definition and leaves the frozen Matroska headers
// untouched. If a third container ever appears they should be hoisted into a
// neutral header; two is not yet enough to earn that churn.
using matroska::ByteRange;
using matroska::CancellationToken;
using matroska::FrameRange;
using matroska::SeekableByteReader;

struct MpegTsPrepareOutcome;

// ---------------------------------------------------------------------------
// Caps. Every one of these is derived arithmetically and asserted below.
// ---------------------------------------------------------------------------

// Sparse random-access index. Transport Stream carries no index of any kind,
// so this is the Cue-equivalent: it is BUILT, not read. 24 bytes per entry at
// 65,536 entries is 1.5 MiB worst case, exactly matching the Matroska cluster
// directory's budget.
inline constexpr std::size_t kMaximumMpegTsIndexEntries{65'536};

// How many probe points prepare() seeds the index with. Each probe is one
// bounded read that finds the next PCR after a byte position, so an open costs
// at most this many extra reads regardless of file size. 512 probes across a
// two-hour broadcast capture puts index points ~14 s apart, which bounds the
// post-bisection refine scan below.
inline constexpr std::size_t kMpegTsIndexProbeCount{512};

// Bytes read at each probe point while looking for the next PCR. A PCR is
// required at least every 100 ms (13818-1 2.7.2) and a 100 ms window of even a
// 50 Mb/s stream is 625 KiB, but WAM's admitted envelope is far below that: at
// a generous 20 Mb/s, 100 ms is 250 KiB. 512 KiB therefore contains a PCR for
// any stream this player admits, and a probe that finds none is reported, not
// guessed at.
inline constexpr std::size_t kMpegTsProbeWindowBytes{512U * 1024U};

// Sequential read-ahead window used by the cursor and every scan. 64 KiB is
// 348 whole 188-byte packets, matching the Matroska copy chunk so the two
// demuxers present the same I/O shape to the page cache.
inline constexpr std::size_t kMpegTsReadWindowBytes{64U * 1024U};
static_assert(kMpegTsReadWindowBytes % kMaximumPacketStrideBytes != 0,
              "the window is deliberately not a stride multiple; the cursor "
              "must handle a packet straddling the window edge");

// How far prepare() will scan from the start of the file to find a complete
// PAT and PMT. ffmpeg emits both within the first few packets and repeats them
// every 100 ms; 4 MiB is ~22,300 packets and is a decisive refusal boundary
// rather than an unbounded hunt through a file that is not a transport stream.
inline constexpr std::size_t kMpegTsProgramScanBytes{4U * 1024U * 1024U};

// Bounded forward scan after a seek bisection lands, looking for a random
// access point. Bounded by the index spacing above plus one GOP.
inline constexpr std::size_t kMpegTsSeekScanBytes{32U * 1024U * 1024U};

// Prefix of an assembled access unit that the cursor inspects to decide the
// keyframe predicate. Transport Stream has no per-sample keyframe flag, so the
// verdict comes from the bitstream: MPEG-2 sequence/GOP/picture headers and
// H.264/HEVC parameter sets and IRAP NALs all appear at the START of an access
// unit. 4 KiB comfortably covers an SPS+PPS+SEI prefix (typically under 200
// bytes) and an MPEG-2 sequence header + extensions + GOP header (under 100),
// with two orders of magnitude of margin, and it is the ONLY payload the
// cursor ever touches: the emitted sample itself remains payload-free.
inline constexpr std::size_t kMpegTsAccessUnitProbeBytes{4'096};

// Largest access unit admitted, matching the frozen source limit so a sample
// that would be rejected downstream is refused by verdict here instead.
inline constexpr std::size_t kMaximumMpegTsAccessUnitBytes{
    MediaSourceLimits::kHardMaximumVideoSampleBytes};

// An access unit is gathered by walking transport packets and taking the
// payload of the ones matching its PID. At 184 payload bytes per packet the
// 8 MiB cap needs at most 47,663 packets, and a 1:1 multiplex would put them
// 188 bytes apart while a heavily multiplexed one spreads them further. The
// gather therefore refuses to walk more than this many packets for one access
// unit, which bounds the scan even if the stream lies about its own framing.
inline constexpr std::uint32_t kMaximumMpegTsAccessUnitPackets{262'144};
static_assert(kMaximumMpegTsAccessUnitPackets * 184U >
                  kMaximumMpegTsAccessUnitBytes,
              "the packet walk must be able to reach the byte cap");

inline constexpr std::size_t kMaximumMpegTsTracks{8};

enum class MpegTsDemuxStatus : std::uint8_t {
  Ready,
  Unsupported,
  Cancelled,
  Failed,
};

// Typed rejection verdicts. Nothing in this demuxer drops a stream silently:
// every refusal names one of these and carries a cold message.
enum class MpegTsDemuxError : std::uint8_t {
  None,
  InvalidRequest,
  NotTransportStream,   // no consistent sync pattern
  InvalidContainer,     // sync found, structure impossible
  MissingProgramTable,  // no PAT/PMT within the bounded scan
  ProgramSelection,     // no program carries an admissible video stream
  UnsupportedStreamType,
  CodecConfiguration,
  InvalidTimeline,      // no usable PTS/PCR pair, or a non-monotone one
  IndexLimit,
  SampleLimit,
  ScanLimit,            // a bounded scan ran out before finding its target
  FileChanged,
  Io,
  Cancelled,
};

[[nodiscard]] const char* mpegTsDemuxErrorName(MpegTsDemuxError error) noexcept;

// ---------------------------------------------------------------------------
// Index
// ---------------------------------------------------------------------------

// Exactly 24 bytes and therefore at most 1.5 MiB at the hard entry cap.
// `tick` is the EXTENDED 90 kHz timeline value, already unwrapped past the
// 33-bit rollover, so a bisection over this array is a plain integer compare
// even across a wrap boundary.
struct MpegTsIndexEntry {
  std::uint64_t packetOffset{0};  // byte offset of the packet's sync byte
  std::int64_t tick{0};           // extended 90 kHz PCR or PTS
  std::uint32_t flags{0};
  std::uint32_t reserved{0};

  static constexpr std::uint32_t kFlagRandomAccess{1U << 0};
  static constexpr std::uint32_t kFlagFromPcr{1U << 1};
  static constexpr std::uint32_t kFlagDecodableFromCold{1U << 2};

  [[nodiscard]] constexpr bool randomAccess() const noexcept {
    return (flags & kFlagRandomAccess) != 0;
  }
  [[nodiscard]] constexpr bool decodableFromCold() const noexcept {
    return (flags & kFlagDecodableFromCold) != 0;
  }

  friend constexpr bool operator==(MpegTsIndexEntry, MpegTsIndexEntry) =
      default;
};
static_assert(sizeof(MpegTsIndexEntry) == 24);
static_assert(std::is_trivially_copyable_v<MpegTsIndexEntry>);
static_assert(sizeof(MpegTsIndexEntry) * kMaximumMpegTsIndexEntries ==
                  1'572'864,
              "the built index is capped at exactly 1.5 MiB");

// ---------------------------------------------------------------------------
// Samples
// ---------------------------------------------------------------------------

// Payload-free by construction. A transport-stream access unit is scattered
// across many packets with headers between the fragments, so an inline range
// array would need up to 47,663 entries; instead the sample names the packet
// span and the demuxer's gather walks it. Copying an access unit therefore
// needs the sample and nothing else.
struct MpegTsCompressedSample {
  std::uint64_t firstPacketOffset{0};  // sync byte of the first packet
  std::uint64_t packetScanEnd{0};      // exclusive bound for the gather walk
  MediaTime presentationTime{};
  MediaTime decodeTime{};
  MediaTime duration{};
  std::uint32_t payloadBytes{0};
  std::uint32_t headerSkipBytes{0};  // PES header dropped from the first packet
  MediaTrackId track{0};
  std::uint16_t pid{kNullPid};
  MediaSampleKind kind{MediaSampleKind::EncodedVideo};
  bool keyFrame{false};
  bool decodableFromCold{false};
  bool discontinuity{false};
  bool continuityGap{false};  // packets were lost inside this access unit

  friend bool operator==(const MpegTsCompressedSample&,
                         const MpegTsCompressedSample&) = default;
};
static_assert(std::is_trivially_copyable_v<MpegTsCompressedSample>);
// 88 bytes: 48 of exact rational time, 16 of packet-span identity, and 24 of
// facts and padding. Against Matroska's ~4.2 KiB read result the difference is
// entirely the 256-entry lace array Matroska must carry and Transport Stream
// does not, so a readNext here moves 88 bytes to deliver ~48 useful ones
// instead of 4,200.
static_assert(sizeof(MpegTsCompressedSample) == 88);

// ---------------------------------------------------------------------------
// Generation planning
// ---------------------------------------------------------------------------

struct MpegTsGenerationPlan {
  MediaTime requestedTarget{};
  MediaTime actualDecodeStart{};
  MediaAudioGenerationWindow audioWindow{};
  std::uint64_t videoPacketOffset{0};
  std::uint64_t audioPacketOffset{0};
  // The exact index entry the bisection landed on, for diagnostics and for the
  // honest seek-accuracy accounting the report requires.
  std::int64_t landedTick{0};
  std::uint32_t refineScanPackets{0};
  MediaSeekMode mode{MediaSeekMode::Accurate};
};

struct MpegTsCursorEnd {};
struct MpegTsCursorCancelled {};
struct MpegTsCursorFailure {
  MpegTsDemuxError error{MpegTsDemuxError::Io};
  std::string message;
};

using MpegTsCursorReadResult =
    std::variant<MpegTsCompressedSample, MpegTsCursorEnd, MpegTsCursorCancelled,
                 MpegTsCursorFailure>;

class MpegTsCursor final {
 public:
  ~MpegTsCursor();
  MpegTsCursor(MpegTsCursor&&) noexcept;
  MpegTsCursor& operator=(MpegTsCursor&&) noexcept;
  MpegTsCursor(const MpegTsCursor&) = delete;
  MpegTsCursor& operator=(const MpegTsCursor&) = delete;

  [[nodiscard]] MpegTsCursorReadResult
  readNext(CancellationToken cancellation = {}) noexcept;

  // Diagnostics the report needs and the source publishes: unsignalled
  // continuity gaps and resynchronizations observed on this cursor's walk.
  [[nodiscard]] std::uint32_t continuityGaps() const noexcept;
  [[nodiscard]] std::uint32_t resynchronizations() const noexcept;

 private:
  struct Impl;
  explicit MpegTsCursor(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
  friend class MpegTsPreparedAsset;
};

struct MpegTsPlanOutcome {
  MpegTsDemuxStatus status{MpegTsDemuxStatus::Failed};
  MpegTsDemuxError error{MpegTsDemuxError::InvalidTimeline};
  std::optional<MpegTsGenerationPlan> plan;
  std::string message;
};

// Immutable facts about the container framing, published because .m2ts and a
// 204-byte DVB capture are the same demuxer with a different stride and the
// distinction must be visible to a test and to telemetry.
struct MpegTsFraming {
  std::uint64_t firstSyncOffset{0};
  std::uint32_t packetStride{0};   // 188, 192 or 204
  std::uint32_t packetCount{0};
  bool timestampedPackets{false};  // m2ts TP_extra_header present

  friend constexpr bool operator==(MpegTsFraming, MpegTsFraming) = default;
};

class MpegTsPreparedAsset final
    : public std::enable_shared_from_this<MpegTsPreparedAsset> {
 public:
  ~MpegTsPreparedAsset();
  MpegTsPreparedAsset(const MpegTsPreparedAsset&) = delete;
  MpegTsPreparedAsset& operator=(const MpegTsPreparedAsset&) = delete;

  [[nodiscard]] const std::filesystem::path& path() const noexcept;
  [[nodiscard]] const std::shared_ptr<const MediaSourceDescriptor>&
  descriptor() const noexcept;
  [[nodiscard]] const MediaSourceLimits& limits() const noexcept;
  [[nodiscard]] MpegTsFraming framing() const noexcept;
  [[nodiscard]] std::uint16_t programNumber() const noexcept;
  [[nodiscard]] std::span<const MpegTsIndexEntry> index() const noexcept;
  // The extended 90 kHz tick that the exported timeline treats as zero. Every
  // MediaTime this demuxer publishes is (extendedTick - originTick) / 90000,
  // which is what makes a file muxed across the 33-bit wrap present a plain
  // monotone timeline starting at zero.
  [[nodiscard]] std::int64_t originTick() const noexcept;
  // Exported timestamp of the FIRST video access unit. It is zero only when
  // video is also the earliest stream in the mux; every real ffmpeg transport
  // stream emits audio a few milliseconds ahead of video, so a plain open at
  // zero legitimately finds its first video picture slightly later. A media
  // source needs this to tell that case apart from a seek that really skipped
  // content, which is the same distinction Matroska draws against its first
  // Cue.
  [[nodiscard]] MediaTime videoOriginTime() const noexcept;

  [[nodiscard]] MpegTsPlanOutcome planGeneration(
      MediaTime target, MediaSeekMode mode,
      CancellationToken cancellation = {}) const noexcept;
  [[nodiscard]] std::unique_ptr<MpegTsCursor>
  makeVideoCursor(const MpegTsGenerationPlan& plan) const noexcept;
  [[nodiscard]] std::unique_ptr<MpegTsCursor>
  makeAudioCursor(const MpegTsGenerationPlan& plan) const noexcept;

  // Gathers one access unit's payload into `destination`, which must be
  // exactly `sample.payloadBytes` long. Walks transport packets from
  // `sample.firstPacketOffset`, taking the payload of packets whose PID
  // matches and dropping the PES header from the first. File identity and
  // cancellation bracket the whole gather, exactly as Matroska's copyRanges
  // does and for the same measured reason.
  [[nodiscard]] bool copyAccessUnit(
      const MpegTsCompressedSample& sample, std::span<std::byte> destination,
      CancellationToken cancellation = {},
      MpegTsDemuxError* error = nullptr) const noexcept;

 private:
  struct Impl;
  explicit MpegTsPreparedAsset(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
  friend struct MpegTsPrepareOutcome;
  friend MpegTsPrepareOutcome prepareMpegTs(std::shared_ptr<SeekableByteReader>,
                                            std::filesystem::path,
                                            const MediaSourceOpenOptions&,
                                            CancellationToken) noexcept;
  friend MpegTsPrepareOutcome prepareMpegTsLocalFile(
      const std::filesystem::path&, const MediaSourceOpenOptions&,
      CancellationToken) noexcept;
};

struct MpegTsPrepareOutcome {
  MpegTsDemuxStatus status{MpegTsDemuxStatus::Failed};
  MpegTsDemuxError error{MpegTsDemuxError::InvalidContainer};
  std::shared_ptr<const MpegTsPreparedAsset> asset;
  std::string message;
};

// Injected-reader seam used by deterministic tests and non-path owners. The
// asset retains exactly this reader object for its complete lifetime.
[[nodiscard]] MpegTsPrepareOutcome prepareMpegTs(
    std::shared_ptr<SeekableByteReader> reader, std::filesystem::path path,
    const MediaSourceOpenOptions& options,
    CancellationToken cancellation = {}) noexcept;

// Opens once with O_RDONLY|O_CLOEXEC and retains that descriptor. No cursor or
// payload gather reopens the path.
[[nodiscard]] MpegTsPrepareOutcome prepareMpegTsLocalFile(
    const std::filesystem::path& path, const MediaSourceOpenOptions& options,
    CancellationToken cancellation = {}) noexcept;

// Detects the packet framing of a transport stream from a probe window. Public
// because it is the first thing that can refuse a file and therefore the first
// thing a test must be able to drive directly.
[[nodiscard]] bool detectMpegTsFraming(std::span<const std::byte> probe,
                                       std::uint64_t fileSize,
                                       MpegTsFraming& framing) noexcept;

}  // namespace wam::media::mpegts
