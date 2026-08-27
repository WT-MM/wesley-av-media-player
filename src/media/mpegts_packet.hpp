#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <type_traits>

// Pure, allocation-free MPEG-2 Transport Stream primitives (ISO/IEC 13818-1).
//
// This header is to mpegts_demuxer.cpp what matroska_ebml.hpp is to
// matroska_demuxer.cpp: every function here is a total function over bytes,
// takes no ownership, allocates nothing, throws nothing, and is exhaustively
// unit-testable without a file. The demuxer above it owns policy; this layer
// owns only "what do these bytes mean".
//
// TIME IS EXACT AND NEVER PASSES THROUGH A DOUBLE. Transport Stream carries
// presentation and decode timestamps as 33-bit integers on a 90 kHz grid and a
// program clock reference as a 33-bit 90 kHz base plus a 9-bit 27 MHz
// extension. Both are represented here as integers in their native units.
// 33 bits at 90 kHz wraps every 2^33 / 90000 = 95,443.7178 s (26 h 30 m), and
// a stream may legitimately be muxed to start near that boundary, so every
// timestamp that leaves this layer for the timeline has been extended to a
// monotone 64-bit value by TimestampUnwrapper.
namespace wam::media::mpegts {

// ---------------------------------------------------------------------------
// Packet geometry
// ---------------------------------------------------------------------------

// A Transport Stream packet is exactly 188 bytes. Two framings wrap it:
//   * m2ts/mts (Blu-ray, AVCHD, and ffmpeg's -mpegts_m2ts_mode) prefixes each
//     packet with a 4-byte TP_extra_header, giving a 192-byte stride;
//   * DVB "204-byte" streams append 16 bytes of Reed-Solomon parity.
// Both are handled by carrying a stride plus the offset of the first sync
// byte; the 188 payload bytes always begin at that sync byte.
inline constexpr std::size_t kTsPacketBytes{188};
inline constexpr std::size_t kM2tsPacketBytes{192};
inline constexpr std::size_t kRsPacketBytes{204};
inline constexpr std::size_t kMaximumPacketStrideBytes{kRsPacketBytes};
inline constexpr std::byte kSyncByte{std::byte{0x47}};

inline constexpr std::uint16_t kPatPid{0x0000};
inline constexpr std::uint16_t kNullPid{0x1FFF};
inline constexpr std::uint16_t kMaximumPid{0x1FFF};

// ---------------------------------------------------------------------------
// Timestamps
// ---------------------------------------------------------------------------

inline constexpr std::int32_t kTimestampHz{90'000};
inline constexpr std::int64_t kPcrHz{27'000'000};
inline constexpr std::int64_t kTimestampModulus{INT64_C(1) << 33};
// Half the modulus. A gap larger than this in either direction is read as a
// wrap rather than as a jump, which is correct because no legal reordering or
// mux jitter approaches 2^32 ticks = 13 h 15 m.
inline constexpr std::int64_t kTimestampWrapThreshold{INT64_C(1) << 32};

static_assert(kTimestampModulus / kTimestampHz == 95'443,
              "33-bit 90 kHz timestamps wrap every 95,443.7 s");

// Extends a stream of 33-bit timestamps to a monotone 64-bit timeline by
// counting wraps. Deliberately tolerant of decode-order reordering: PTS and
// DTS of B-pictures move backwards by a few frame durations, which is many
// orders of magnitude below the wrap threshold.
//
// This is a value type with no allocation and no virtual dispatch; one lives
// per elementary stream inside the demuxer's per-PID state.
class TimestampUnwrapper {
 public:
  // Returns the extended value. `raw` must already be masked to 33 bits.
  [[nodiscard]] constexpr std::int64_t extend(std::uint64_t raw) noexcept {
    const std::int64_t value = static_cast<std::int64_t>(
        raw & static_cast<std::uint64_t>(kTimestampModulus - 1));
    if (!primed_) {
      primed_ = true;
      last_ = value;
      return epoch_ + value;
    }
    const std::int64_t difference = value - last_;
    if (difference < -kTimestampWrapThreshold) {
      epoch_ += kTimestampModulus;
      ++forwardWraps_;
    } else if (difference > kTimestampWrapThreshold) {
      epoch_ -= kTimestampModulus;
      ++backwardWraps_;
    }
    last_ = value;
    return epoch_ + value;
  }

  // A signalled discontinuity invalidates the wrap state but NOT the epoch:
  // the next timestamp reseeds `last_` without being read as a wrap.
  constexpr void resynchronize() noexcept { primed_ = false; }
  [[nodiscard]] constexpr bool primed() const noexcept { return primed_; }
  [[nodiscard]] constexpr std::int64_t epoch() const noexcept {
    return epoch_;
  }
  [[nodiscard]] constexpr std::uint32_t forwardWraps() const noexcept {
    return forwardWraps_;
  }
  [[nodiscard]] constexpr std::uint32_t backwardWraps() const noexcept {
    return backwardWraps_;
  }

 private:
  std::int64_t epoch_{0};
  std::int64_t last_{0};
  std::uint32_t forwardWraps_{0};
  std::uint32_t backwardWraps_{0};
  bool primed_{false};
};

// Exact conversion of a 90 kHz tick count to MediaTime. The result is reduced
// to lowest terms so that comparisons against other bases stay exact and
// cheap. Never rounds; fails closed if the reduced form leaves the domain.
[[nodiscard]] std::optional<MediaTime>
mediaTimeFromTicks(std::int64_t ticks) noexcept;

// ---------------------------------------------------------------------------
// Transport packet header
// ---------------------------------------------------------------------------

enum class TsPacketStatus : std::uint8_t {
  Ok,
  NotSynced,   // first byte is not 0x47
  Malformed,   // adaptation length or payload geometry is impossible
};

// 32 bytes, POD, memcpy-safe. Hot: it is produced once per 188 bytes of file.
// Nothing here is a pointer into the packet; the demuxer re-derives payload
// spans from `payloadOffset`/`payloadSize`.
struct TsPacketHeader {
  std::uint64_t pcrBase{0};       // 33-bit, 90 kHz
  std::uint16_t pcrExtension{0};  // 9-bit, remainder on the 27 MHz grid
  std::uint16_t pid{kNullPid};
  std::uint8_t continuityCounter{0};
  std::uint8_t scramblingControl{0};
  std::uint8_t payloadOffset{0};  // into the 188-byte packet
  std::uint8_t payloadSize{0};
  bool transportError{false};
  bool payloadUnitStart{false};
  bool transportPriority{false};
  bool hasAdaptation{false};
  bool hasPayload{false};
  bool discontinuity{false};
  bool randomAccess{false};
  bool elementaryStreamPriority{false};
  bool hasPcr{false};

  // The full 27 MHz program clock reference. Only meaningful when hasPcr.
  [[nodiscard]] constexpr std::uint64_t pcr27MHz() const noexcept {
    return pcrBase * 300U + pcrExtension;
  }

  friend constexpr bool operator==(const TsPacketHeader&,
                                   const TsPacketHeader&) = default;
};
// 16 bytes of scalars plus nine one-byte facts, padded to the 8-byte alignment
// the 64-bit PCR base demands. At the 188-byte packet size this is 17% of a
// packet's worth of metadata per packet and is produced on the stack, never
// stored: the index below keeps 24-byte entries, not headers.
static_assert(sizeof(TsPacketHeader) == 32);
static_assert(alignof(TsPacketHeader) == 8);
static_assert(std::is_trivially_copyable_v<TsPacketHeader>);

[[nodiscard]] TsPacketStatus
decodeTsPacket(std::span<const std::byte> packet,
               TsPacketHeader& header) noexcept;

// Continuity-counter verdict for one packet of one PID. The counter increments
// modulo 16 on every packet CARRYING PAYLOAD and repeats on an adaptation-only
// packet; a duplicate of the previous packet is legal exactly once.
enum class ContinuityVerdict : std::uint8_t {
  FirstPacket,
  Continuous,
  Duplicate,       // legal single repeat
  AdaptationOnly,  // no payload, counter must not advance
  Discontinuous,   // signalled by the adaptation field
  Gap,             // unsignalled loss: packets were dropped
};

class ContinuityTracker {
 public:
  [[nodiscard]] ContinuityVerdict observe(const TsPacketHeader& header) noexcept;
  constexpr void reset() noexcept { primed_ = false; }
  [[nodiscard]] constexpr std::uint32_t gaps() const noexcept { return gaps_; }

 private:
  std::uint32_t gaps_{0};
  std::uint8_t last_{0};
  bool primed_{false};
};

// ---------------------------------------------------------------------------
// Program-specific information (PSI) sections
// ---------------------------------------------------------------------------

// ISO/IEC 13818-1 caps section_length at 1021 for PSI, so a whole section is
// at most 3 header bytes + 1021 = 1024. That is the buffer, exactly, and it is
// where the cap number comes from rather than a round figure.
inline constexpr std::size_t kMaximumSectionBytes{1024};
inline constexpr std::uint16_t kMaximumSectionLength{1021};

inline constexpr std::uint8_t kTableIdPat{0x00};
inline constexpr std::uint8_t kTableIdPmt{0x02};

struct SectionHeader {
  std::uint16_t tableIdExtension{0};
  std::uint16_t sectionLength{0};  // bytes following the length field
  std::uint8_t tableId{0xFF};
  std::uint8_t versionNumber{0};
  std::uint8_t sectionNumber{0};
  std::uint8_t lastSectionNumber{0};
  bool sectionSyntaxIndicator{false};
  bool currentNext{false};

  friend constexpr bool operator==(const SectionHeader&,
                                   const SectionHeader&) = default;
};

// MPEG-2 CRC-32 (polynomial 0x04C11DB7, MSB-first, initial value all ones).
// A complete, correct section CRCs to zero over its whole length.
[[nodiscard]] std::uint32_t mpegCrc32(std::span<const std::byte> data) noexcept;

enum class SectionStatus : std::uint8_t {
  Incomplete,
  Ready,
  Malformed,
  CrcMismatch,
  Overflow,
};

// Reassembles one PID's sections across packets. Fixed 1024-byte storage; no
// allocation, ever. Discards and resynchronizes rather than growing.
class SectionAssembler {
 public:
  // Feeds one packet's payload. `payloadUnitStart` selects the pointer_field
  // path. Returns Ready exactly when `section()` holds a complete, CRC-valid
  // section.
  [[nodiscard]] SectionStatus feed(std::span<const std::byte> payload,
                                   bool payloadUnitStart) noexcept;
  void reset() noexcept;

  [[nodiscard]] std::span<const std::byte> section() const noexcept;
  [[nodiscard]] const SectionHeader& header() const noexcept {
    return header_;
  }

 private:
  [[nodiscard]] SectionStatus consume(std::span<const std::byte> bytes) noexcept;

  std::array<std::byte, kMaximumSectionBytes> storage_{};
  SectionHeader header_{};
  std::uint16_t filled_{0};
  std::uint16_t expected_{0};
  bool collecting_{false};
};

// --- PAT -------------------------------------------------------------------

// A PAT is at most (1021 - 5 - 4) / 4 = 253 entries per section. WAM admits a
// bounded program count well below that; a transport stream carrying more than
// 64 programs is a multiplex, not a media file, and is refused by verdict.
inline constexpr std::size_t kMaximumPrograms{64};

struct ProgramAssociation {
  std::uint16_t programNumber{0};
  std::uint16_t pmtPid{kNullPid};

  friend constexpr bool operator==(ProgramAssociation,
                                   ProgramAssociation) = default;
};
static_assert(sizeof(ProgramAssociation) == 4);

struct ProgramAssociationTable {
  std::array<ProgramAssociation, kMaximumPrograms> programs{};
  std::uint16_t transportStreamId{0};
  std::uint8_t programCount{0};
  bool truncated{false};  // more programs present than the cap admits
};

[[nodiscard]] bool parseProgramAssociationSection(
    std::span<const std::byte> section, const SectionHeader& header,
    ProgramAssociationTable& table) noexcept;

// --- PMT -------------------------------------------------------------------

inline constexpr std::size_t kMaximumProgramStreams{32};

// ISO/IEC 13818-1 Table 2-34 plus the registrations WAM routes.
enum class TsStreamType : std::uint8_t {
  Mpeg1Video = 0x01,
  Mpeg2Video = 0x02,
  Mpeg1Audio = 0x03,
  Mpeg2Audio = 0x04,
  PrivateSections = 0x05,
  PrivatePes = 0x06,
  AdtsAac = 0x0F,
  LatmAac = 0x11,
  Mpeg4Video = 0x10,
  H264 = 0x1B,
  Hevc = 0x24,
  Ac3Atsc = 0x81,
  Dts = 0x82,
  Eac3Atsc = 0x87,
};

struct ElementaryStream {
  std::uint16_t elementaryPid{kNullPid};
  std::uint8_t streamType{0};
  MediaCodec codec{MediaCodec::Unknown};
  MediaTrackKind kind{MediaTrackKind::Metadata};
  // Descriptor-proved facts. `ac3Descriptor` distinguishes DVB AC-3 carried as
  // stream type 0x06 (private PES) from any other private stream.
  bool ac3Descriptor{false};
  bool eac3Descriptor{false};
  bool registrationAc3{false};

  friend constexpr bool operator==(const ElementaryStream&,
                                   const ElementaryStream&) = default;
};

struct ProgramMapTable {
  std::array<ElementaryStream, kMaximumProgramStreams> streams{};
  std::uint16_t programNumber{0};
  std::uint16_t pcrPid{kNullPid};
  std::uint8_t streamCount{0};
  bool truncated{false};
};

[[nodiscard]] bool parseProgramMapSection(std::span<const std::byte> section,
                                          const SectionHeader& header,
                                          ProgramMapTable& table) noexcept;

// Maps a PMT stream type (plus its descriptor facts) onto WAM's routing
// family. Returns Unknown for anything the native route does not carry; the
// caller turns that into a typed verdict rather than a silent skip.
[[nodiscard]] MediaCodec codecForStreamType(std::uint8_t streamType,
                                            bool ac3Descriptor,
                                            bool eac3Descriptor,
                                            bool registrationAc3) noexcept;
[[nodiscard]] MediaTrackKind trackKindForStreamType(
    std::uint8_t streamType, bool ac3Descriptor, bool eac3Descriptor,
    bool registrationAc3) noexcept;

// ---------------------------------------------------------------------------
// Packetized elementary stream (PES)
// ---------------------------------------------------------------------------

inline constexpr std::uint8_t kPesStartCodePrefixByte{0x01};
// The smallest possible PES header: 00 00 01, stream_id, 16-bit length.
inline constexpr std::size_t kMinimumPesHeaderBytes{6};

enum class PesStatus : std::uint8_t {
  Ok,
  Incomplete,   // fewer bytes than the header needs; caller must accumulate
  NotPes,       // start-code prefix absent
  Malformed,
};

struct PesHeader {
  std::uint64_t pts{0};  // 33-bit raw, valid only when hasPts
  std::uint64_t dts{0};  // 33-bit raw, valid only when hasDts
  // Zero is legal and means "unbounded until the next payload-unit start",
  // which ISO/IEC 13818-1 permits only for video elementary streams.
  std::uint16_t packetLength{0};
  std::uint8_t streamId{0};
  std::uint8_t headerBytes{0};  // total bytes before the payload begins
  bool hasPts{false};
  bool hasDts{false};
  bool dataAlignment{false};

  friend constexpr bool operator==(const PesHeader&, const PesHeader&) =
      default;
};

[[nodiscard]] PesStatus decodePesHeader(std::span<const std::byte> bytes,
                                        PesHeader& header) noexcept;

// True for the stream_id values that carry an optional-PES-header (and
// therefore may carry PTS/DTS). padding, private_2, ECM, EMM and the stream
// directory carry raw payload instead.
[[nodiscard]] constexpr bool pesStreamIdHasHeader(
    std::uint8_t streamId) noexcept {
  switch (streamId) {
    case 0xBC:  // program_stream_map
    case 0xBE:  // padding_stream
    case 0xBF:  // private_stream_2
    case 0xF0:  // ECM
    case 0xF1:  // EMM
    case 0xF2:  // DSMCC
    case 0xF8:  // ITU-T H.222.1 type E
    case 0xFF:  // program_stream_directory
      return false;
    default:
      return true;
  }
}

// ---------------------------------------------------------------------------
// Codec-level access-unit inspection
// ---------------------------------------------------------------------------

// What a scan of one assembled access unit proved about it. This is the
// keyframe predicate: Transport Stream has no index and no per-sample keyframe
// flag, so random access is decided from the bitstream itself, corroborated by
// the adaptation field's random_access_indicator where present.
struct AccessUnitScan {
  // Offsets are into the scanned span. Zero size means absent.
  std::uint32_t parameterSetOffset{0};
  std::uint32_t parameterSetSize{0};
  bool keyFrame{false};
  // Decodable from a cold decoder: MPEG-2 needs a sequence header, H.264 needs
  // SPS+PPS ahead of the IDR, HEVC needs VPS+SPS+PPS ahead of the IRAP.
  bool decodableFromCold{false};
  bool hasSequenceHeader{false};
  bool hasParameterSets{false};
  // True when the scanned span actually contained the picture the access unit
  // codes -- a VCL NAL for H.264/HEVC, a picture_header for MPEG-2.
  //
  // This exists to separate ABSENCE OF EVIDENCE from EVIDENCE OF ABSENCE. The
  // cursor scans only a bounded prefix of each access unit, so a keyFrame of
  // false can mean either "this picture is not a random access point" or "the
  // prefix ended before the picture started". Those are opposite facts and
  // conflating them is what turned a 4,977-byte HDR SEI prologue into "this
  // file has no random access point" -- see kMpegTsAccessUnitProbeBytes.
  // A caller that sees `!sliceInProbe` must not treat `keyFrame` as a verdict.
  bool sliceInProbe{false};

  friend constexpr bool operator==(const AccessUnitScan&,
                                   const AccessUnitScan&) = default;
};

[[nodiscard]] AccessUnitScan
scanMpeg2AccessUnit(std::span<const std::byte> unit) noexcept;
[[nodiscard]] AccessUnitScan
scanAnnexBAccessUnit(std::span<const std::byte> unit, MediaCodec codec) noexcept;
[[nodiscard]] AccessUnitScan scanAccessUnit(std::span<const std::byte> unit,
                                            MediaCodec codec) noexcept;

// MPEG-2 sequence header geometry. Absent when the span carries no sequence
// header or the header is truncated.
struct Mpeg2SequenceHeader {
  std::uint32_t width{0};
  std::uint32_t height{0};
  std::uint8_t aspectRatioInformation{0};
  std::uint8_t frameRateCode{0};

  friend constexpr bool operator==(const Mpeg2SequenceHeader&,
                                   const Mpeg2SequenceHeader&) = default;
};

[[nodiscard]] std::optional<Mpeg2SequenceHeader>
parseMpeg2SequenceHeader(std::span<const std::byte> unit) noexcept;

// Exact frame duration in 90 kHz ticks for an MPEG-2 frame_rate_code, or zero
// when the code is reserved. 13818-2 Table 6-4 rates are all exact rationals
// against 90 kHz except the 1000/1001 family, which divides exactly too
// (90000 * 1001 / 30000 = 3003).
[[nodiscard]] std::uint32_t
mpeg2FrameDurationTicks(std::uint8_t frameRateCode) noexcept;

// --- Annex-B NAL walking ---------------------------------------------------

struct AnnexBNal {
  std::uint32_t offset{0};      // to the first byte AFTER the start code
  std::uint32_t size{0};        // NAL payload size, start code excluded
  std::uint8_t startCodeSize{0};  // 3 or 4
  std::uint8_t type{0};         // H.264 nal_unit_type or HEVC nal type
};

// Locates the NAL beginning at or after `from`. Returns false at end of span.
[[nodiscard]] bool nextAnnexBNal(std::span<const std::byte> unit,
                                 std::uint32_t from, MediaCodec codec,
                                 AnnexBNal& nal) noexcept;

// --- Annex-B to AVCC ------------------------------------------------------
//
// Transport Stream carries H.264 and HEVC as Annex-B: NAL units separated by
// three- or four-byte start codes. A VideoToolbox session configured from an
// avcC/hvcC expects the opposite framing: each NAL prefixed by its own
// big-endian length. The demuxer synthesizes the avcC (see mpegts_demuxer.cpp);
// these two functions do the per-sample repack, and they are here rather than
// in the platform layer so they are testable without CoreMedia.
//
// The length prefix is four bytes because the synthesized avcC declares
// lengthSizeMinusOne = 3, which is also the only value the shared codec
// inspector admits. A four-byte start code therefore converts with NO size
// change; a three-byte one grows the unit by exactly one byte. `annexBToAvccSize`
// returns the exact output size so the caller can allocate its CoreMedia block
// once and convert straight into it.

// Exact number of bytes annexBToAvcc will write, or 0 when the span holds no
// complete NAL unit.
[[nodiscard]] std::size_t annexBToAvccSize(std::span<const std::byte> unit,
                                           MediaCodec codec) noexcept;

// Writes the length-prefixed form into `destination`, which must be exactly
// annexBToAvccSize(unit, codec) bytes. Returns the bytes written, or 0 on any
// refusal; a partial conversion is never reported as success.
[[nodiscard]] std::size_t annexBToAvcc(std::span<const std::byte> unit,
                                       std::span<std::byte> destination,
                                       MediaCodec codec) noexcept;

// --- HEVC parameter-set facts ---------------------------------------------
//
// Everything an hvcC configuration record must state that is NOT a verbatim
// copy of a parameter-set NAL unit.
//
// THE PROFILE-TIER-LEVEL BYTES ARE A VERBATIM COPY, AND THAT IS A CONTRACT,
// NOT AN OPTIMIZATION. ISO/IEC 14496-15 defines the record's bytes 1..12 as
// the SPS's own profile_tier_level() syntax re-emitted unchanged -- one
// packed byte of general_profile_space/general_tier_flag/general_profile_idc,
// four bytes of general_profile_compatibility_flag[32], six bytes of
// general_constraint_indicator_flags (the progressive/interlaced/non-packed/
// frame-only quartet plus 43 reserved bits plus the inbld flag) and one byte
// of general_level_idc. Every one of those 96 bits is byte-aligned inside the
// SPS RBSP, because exactly eight bits (sps_video_parameter_set_id,
// sps_max_sub_layers_minus1, sps_temporal_id_nesting_flag) precede it. A
// consumer -- ours included, in inspectHvcC -- re-parses the SPS and compares
// the two field for field, so rebuilding the record's copy from decoded
// fields would risk disagreeing with the source on any bit this code chose to
// normalize. It is lifted out of the RBSP as twelve bytes instead.
//
// The RBSP, not the NAL: emulation-prevention bytes must be removed first,
// and a real HEVC SPS carries several inside its PTL (the reserved-zero runs
// produce 00 00 00 sequences, which every encoder escapes as 00 00 03 00).
// The hvcC's parameter-set ARRAYS keep the escaped NAL bytes, exactly as the
// elementary stream carries them; only this copy is unescaped.
struct HevcSpsFacts {
  // SPS RBSP bytes [1, 13) counted from the first byte after the two-byte NAL
  // header: general_profile_space through general_level_idc.
  std::array<std::uint8_t, 12> profileTierLevel{};
  std::uint8_t chromaFormatIdc{0};
  std::uint8_t bitDepthLumaMinusEight{0};
  std::uint8_t bitDepthChromaMinusEight{0};
  std::uint8_t maxSubLayersMinusOne{0};
  bool temporalIdNested{false};

  friend constexpr bool operator==(const HevcSpsFacts&,
                                   const HevcSpsFacts&) = default;
};

// Reads one HEVC SPS NAL unit -- WITH its two-byte NAL header and WITH its
// emulation-prevention bytes, i.e. exactly the bytes the Annex-B stream
// carries -- far enough to state every fact the record above needs. Stops at
// bit_depth_chroma_minus8; nothing past that belongs in an hvcC header, and
// the shared codec inspector parses the rest of the SPS anyway.
[[nodiscard]] bool parseHevcSpsFacts(std::span<const std::byte> nal,
                                     HevcSpsFacts& facts) noexcept;

// ADTS: the AAC framing used by stream type 0x0F. A demuxer must split a PES
// payload into whole ADTS frames because the audio path is packet-oriented.
struct AdtsHeader {
  std::uint32_t frameBytes{0};  // including this header
  std::uint32_t sampleRate{0};
  std::uint16_t headerBytes{0};  // 7 without CRC, 9 with
  std::uint8_t channelConfiguration{0};
  std::uint8_t profileObjectType{0};  // 1-based AudioObjectType
  std::uint8_t samplingFrequencyIndex{0};

  friend constexpr bool operator==(const AdtsHeader&, const AdtsHeader&) =
      default;
};

[[nodiscard]] bool parseAdtsHeader(std::span<const std::byte> bytes,
                                   AdtsHeader& header) noexcept;
[[nodiscard]] std::uint32_t
adtsSampleRateForIndex(std::uint8_t index) noexcept;

// AC-3 sync frame geometry (ATSC A/52). Needed to split a PES payload into
// whole frames and to admit the stream's rate/channels without decoding.
struct Ac3SyncFrame {
  std::uint32_t frameBytes{0};
  std::uint32_t sampleRate{0};
  std::uint8_t channels{0};
  bool lfe{false};

  friend constexpr bool operator==(const Ac3SyncFrame&, const Ac3SyncFrame&) =
      default;
};

[[nodiscard]] bool parseAc3SyncFrame(std::span<const std::byte> bytes,
                                     Ac3SyncFrame& frame) noexcept;

// MPEG-1/2 Layer I-III frame geometry (stream types 0x03/0x04).
struct MpegAudioFrame {
  std::uint32_t frameBytes{0};
  std::uint32_t sampleRate{0};
  std::uint32_t samplesPerFrame{0};
  std::uint8_t channels{0};
  std::uint8_t layer{0};  // 1, 2 or 3
  std::uint8_t version{0};  // 1 = MPEG-1, 2 = MPEG-2, 3 = MPEG-2.5

  friend constexpr bool operator==(const MpegAudioFrame&,
                                   const MpegAudioFrame&) = default;
};

[[nodiscard]] bool parseMpegAudioFrame(std::span<const std::byte> bytes,
                                       MpegAudioFrame& frame) noexcept;

}  // namespace wam::media::mpegts
