#include "media/mpegts_packet.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <numeric>

namespace wam::media::mpegts {
namespace {

[[nodiscard]] constexpr std::uint8_t byteAt(std::span<const std::byte> bytes,
                                            std::size_t index) noexcept {
  return static_cast<std::uint8_t>(bytes[index]);
}

[[nodiscard]] constexpr std::uint16_t
readBigEndian16(std::span<const std::byte> bytes, std::size_t index) noexcept {
  return static_cast<std::uint16_t>((static_cast<std::uint16_t>(
                                         byteAt(bytes, index))
                                     << 8) |
                                    byteAt(bytes, index + 1));
}

[[nodiscard]] constexpr std::uint32_t
readBigEndian32(std::span<const std::byte> bytes, std::size_t index) noexcept {
  return (static_cast<std::uint32_t>(byteAt(bytes, index)) << 24) |
         (static_cast<std::uint32_t>(byteAt(bytes, index + 1)) << 16) |
         (static_cast<std::uint32_t>(byteAt(bytes, index + 2)) << 8) |
         static_cast<std::uint32_t>(byteAt(bytes, index + 3));
}

// A PTS/DTS field is five bytes carrying 33 bits split around marker bits:
//   '0010' PTS[32..30] '1' PTS[29..15] '1' PTS[14..0] '1'
// The marker bits are checked because a mis-parsed header that happens to
// produce a plausible timestamp is worse than a rejected one.
[[nodiscard]] bool decodeTimestampField(std::span<const std::byte> bytes,
                                        std::size_t index,
                                        std::uint8_t expectedPrefix,
                                        std::uint64_t& value) noexcept {
  if (index + 5 > bytes.size()) {
    return false;
  }
  const std::uint8_t b0 = byteAt(bytes, index);
  const std::uint8_t b1 = byteAt(bytes, index + 1);
  const std::uint8_t b2 = byteAt(bytes, index + 2);
  const std::uint8_t b3 = byteAt(bytes, index + 3);
  const std::uint8_t b4 = byteAt(bytes, index + 4);
  if ((b0 >> 4) != expectedPrefix) {
    return false;
  }
  if ((b0 & 0x01U) == 0 || (b2 & 0x01U) == 0 || (b4 & 0x01U) == 0) {
    return false;
  }
  const std::uint64_t high = static_cast<std::uint64_t>((b0 >> 1) & 0x07U)
                             << 30;
  const std::uint64_t middle =
      (static_cast<std::uint64_t>(b1) << 7 |
       static_cast<std::uint64_t>(b2 >> 1))
      << 15;
  const std::uint64_t low = static_cast<std::uint64_t>(b3) << 7 |
                            static_cast<std::uint64_t>(b4 >> 1);
  value = high | middle | low;
  return true;
}

// Table-free MPEG-2 CRC-32. The demuxer CRCs at most one 1024-byte section per
// PSI update (a handful per open), so a 1 KiB lookup table would cost more
// cache than the bit loop costs cycles.
[[nodiscard]] constexpr std::uint32_t crcStep(std::uint32_t crc,
                                              std::uint8_t value) noexcept {
  crc ^= static_cast<std::uint32_t>(value) << 24;
  for (int bit = 0; bit < 8; ++bit) {
    crc = (crc & 0x8000'0000U) != 0 ? (crc << 1) ^ 0x04C1'1DB7U : (crc << 1);
  }
  return crc;
}

}  // namespace

std::uint32_t mpegCrc32(std::span<const std::byte> data) noexcept {
  std::uint32_t crc = 0xFFFF'FFFFU;
  for (const std::byte value : data) {
    crc = crcStep(crc, static_cast<std::uint8_t>(value));
  }
  return crc;
}

std::optional<MediaTime> mediaTimeFromTicks(std::int64_t ticks) noexcept {
  const bool negative = ticks < 0;
  const std::uint64_t magnitude =
      negative ? static_cast<std::uint64_t>(-(ticks + 1)) + 1U
               : static_cast<std::uint64_t>(ticks);
  const std::uint64_t divisor =
      std::gcd(magnitude, static_cast<std::uint64_t>(kTimestampHz));
  const std::uint64_t numerator = magnitude / divisor;
  const std::uint64_t denominator =
      static_cast<std::uint64_t>(kTimestampHz) / divisor;
  const std::uint64_t ceiling =
      negative
          ? static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) +
                1U
          : static_cast<std::uint64_t>(
                std::numeric_limits<std::int64_t>::max());
  if (numerator > ceiling) {
    return std::nullopt;
  }
  std::int64_t signedNumerator = 0;
  if (negative) {
    signedNumerator =
        numerator == static_cast<std::uint64_t>(
                         std::numeric_limits<std::int64_t>::max()) +
                         1U
            ? std::numeric_limits<std::int64_t>::min()
            : -static_cast<std::int64_t>(numerator);
  } else {
    signedNumerator = static_cast<std::int64_t>(numerator);
  }
  return MediaTime{signedNumerator, static_cast<std::int32_t>(denominator)};
}

// ---------------------------------------------------------------------------
// Transport packet
// ---------------------------------------------------------------------------

TsPacketStatus decodeTsPacket(std::span<const std::byte> packet,
                              TsPacketHeader& header) noexcept {
  header = TsPacketHeader{};
  if (packet.size() < kTsPacketBytes) {
    return TsPacketStatus::Malformed;
  }
  if (packet[0] != kSyncByte) {
    return TsPacketStatus::NotSynced;
  }
  const std::uint8_t b1 = byteAt(packet, 1);
  const std::uint8_t b2 = byteAt(packet, 2);
  const std::uint8_t b3 = byteAt(packet, 3);

  header.transportError = (b1 & 0x80U) != 0;
  header.payloadUnitStart = (b1 & 0x40U) != 0;
  header.transportPriority = (b1 & 0x20U) != 0;
  header.pid = static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(b1 & 0x1FU) << 8) | b2);
  header.scramblingControl = static_cast<std::uint8_t>((b3 >> 6) & 0x03U);
  header.hasAdaptation = (b3 & 0x20U) != 0;
  header.hasPayload = (b3 & 0x10U) != 0;
  header.continuityCounter = static_cast<std::uint8_t>(b3 & 0x0FU);

  std::size_t cursor = 4;
  if (header.hasAdaptation) {
    const std::uint8_t adaptationLength = byteAt(packet, 4);
    cursor = 5;
    // An adaptation_field_length of 183 with no payload flag is the legal
    // whole-packet stuffing case; anything that runs past 188 is malformed.
    if (5 + static_cast<std::size_t>(adaptationLength) > kTsPacketBytes) {
      return TsPacketStatus::Malformed;
    }
    if (adaptationLength > 0) {
      const std::uint8_t flags = byteAt(packet, 5);
      header.discontinuity = (flags & 0x80U) != 0;
      header.randomAccess = (flags & 0x40U) != 0;
      header.elementaryStreamPriority = (flags & 0x20U) != 0;
      const bool pcrFlag = (flags & 0x10U) != 0;
      if (pcrFlag && adaptationLength >= 7) {
        // 33-bit base, 6 reserved bits, 9-bit extension: six bytes.
        const std::uint32_t high = readBigEndian32(packet, 6);
        const std::uint16_t low = readBigEndian16(packet, 10);
        header.pcrBase = (static_cast<std::uint64_t>(high) << 1) |
                         static_cast<std::uint64_t>((low >> 15) & 0x01U);
        header.pcrExtension = static_cast<std::uint16_t>(low & 0x01FFU);
        header.hasPcr = true;
      }
    }
    cursor = 5 + static_cast<std::size_t>(adaptationLength);
  }

  if (header.hasPayload) {
    if (cursor >= kTsPacketBytes) {
      return TsPacketStatus::Malformed;
    }
    header.payloadOffset = static_cast<std::uint8_t>(cursor);
    header.payloadSize = static_cast<std::uint8_t>(kTsPacketBytes - cursor);
  } else {
    header.payloadOffset = static_cast<std::uint8_t>(
        std::min<std::size_t>(cursor, kTsPacketBytes));
    header.payloadSize = 0;
  }
  return TsPacketStatus::Ok;
}

ContinuityVerdict
ContinuityTracker::observe(const TsPacketHeader& header) noexcept {
  if (header.discontinuity) {
    primed_ = true;
    last_ = header.continuityCounter;
    return ContinuityVerdict::Discontinuous;
  }
  if (!primed_) {
    primed_ = true;
    last_ = header.continuityCounter;
    return ContinuityVerdict::FirstPacket;
  }
  if (!header.hasPayload) {
    // 13818-1 2.4.3.3: the counter does not increment on a packet with no
    // payload. A change here is a real gap, not stuffing.
    if (header.continuityCounter == last_) {
      return ContinuityVerdict::AdaptationOnly;
    }
    ++gaps_;
    last_ = header.continuityCounter;
    return ContinuityVerdict::Gap;
  }
  const std::uint8_t expected = static_cast<std::uint8_t>((last_ + 1U) & 0x0FU);
  if (header.continuityCounter == expected) {
    last_ = header.continuityCounter;
    return ContinuityVerdict::Continuous;
  }
  if (header.continuityCounter == last_) {
    return ContinuityVerdict::Duplicate;
  }
  ++gaps_;
  last_ = header.continuityCounter;
  return ContinuityVerdict::Gap;
}

// ---------------------------------------------------------------------------
// PSI sections
// ---------------------------------------------------------------------------

void SectionAssembler::reset() noexcept {
  filled_ = 0;
  expected_ = 0;
  collecting_ = false;
  header_ = SectionHeader{};
}

std::span<const std::byte> SectionAssembler::section() const noexcept {
  return std::span<const std::byte>(storage_.data(), filled_);
}

SectionStatus
SectionAssembler::consume(std::span<const std::byte> bytes) noexcept {
  if (bytes.empty()) {
    return SectionStatus::Incomplete;
  }
  const std::size_t room = kMaximumSectionBytes - filled_;
  const std::size_t take = std::min(room, bytes.size());
  if (take == 0) {
    reset();
    return SectionStatus::Overflow;
  }
  std::memcpy(storage_.data() + filled_, bytes.data(), take);
  filled_ = static_cast<std::uint16_t>(filled_ + take);

  if (expected_ == 0) {
    if (filled_ < 3) {
      return SectionStatus::Incomplete;
    }
    const std::span<const std::byte> view(storage_.data(), filled_);
    const std::uint16_t lengthField =
        static_cast<std::uint16_t>(readBigEndian16(view, 1) & 0x0FFFU);
    if (lengthField > kMaximumSectionLength || lengthField < 5) {
      reset();
      return SectionStatus::Malformed;
    }
    header_.tableId = byteAt(view, 0);
    header_.sectionSyntaxIndicator = (byteAt(view, 1) & 0x80U) != 0;
    header_.sectionLength = lengthField;
    expected_ = static_cast<std::uint16_t>(3U + lengthField);
    if (expected_ > kMaximumSectionBytes) {
      reset();
      return SectionStatus::Overflow;
    }
  }

  if (filled_ < expected_) {
    return SectionStatus::Incomplete;
  }
  filled_ = expected_;
  const std::span<const std::byte> complete(storage_.data(), filled_);
  if (header_.sectionSyntaxIndicator) {
    if (filled_ < 12) {
      reset();
      return SectionStatus::Malformed;
    }
    header_.tableIdExtension = readBigEndian16(complete, 3);
    header_.versionNumber =
        static_cast<std::uint8_t>((byteAt(complete, 5) >> 1) & 0x1FU);
    header_.currentNext = (byteAt(complete, 5) & 0x01U) != 0;
    header_.sectionNumber = byteAt(complete, 6);
    header_.lastSectionNumber = byteAt(complete, 7);
    if (mpegCrc32(complete) != 0) {
      const SectionStatus verdict = SectionStatus::CrcMismatch;
      reset();
      return verdict;
    }
  }
  collecting_ = false;
  return SectionStatus::Ready;
}

SectionStatus SectionAssembler::feed(std::span<const std::byte> payload,
                                     bool payloadUnitStart) noexcept {
  if (payloadUnitStart) {
    if (payload.empty()) {
      reset();
      return SectionStatus::Malformed;
    }
    // The first payload byte of a PSI packet with payload_unit_start_indicator
    // set is a pointer_field naming how many bytes of the PREVIOUS section
    // still precede this one.
    const std::size_t pointer = static_cast<std::size_t>(byteAt(payload, 0));
    if (1 + pointer > payload.size()) {
      reset();
      return SectionStatus::Malformed;
    }
    SectionStatus tail = SectionStatus::Incomplete;
    if (pointer > 0 && collecting_) {
      tail = consume(payload.subspan(1, pointer));
    }
    // Whatever the tail did, a new section starts here.
    const std::span<const std::byte> rest = payload.subspan(1 + pointer);
    if (tail == SectionStatus::Ready) {
      // Deliberately do not start the next section in the same call: the
      // caller must observe the completed one first. The remaining bytes are
      // re-derivable only from the next packet, which is why WAM restricts
      // PSI to one section per payload-unit start. In practice PAT and PMT
      // for a single-program mux always fit one packet.
      return SectionStatus::Ready;
    }
    reset();
    if (rest.empty()) {
      return SectionStatus::Incomplete;
    }
    if (rest[0] == std::byte{0xFF}) {
      return SectionStatus::Incomplete;  // stuffing to the end of the packet
    }
    collecting_ = true;
    return consume(rest);
  }
  if (!collecting_) {
    return SectionStatus::Incomplete;
  }
  return consume(payload);
}

bool parseProgramAssociationSection(std::span<const std::byte> section,
                                    const SectionHeader& header,
                                    ProgramAssociationTable& table) noexcept {
  table = ProgramAssociationTable{};
  if (header.tableId != kTableIdPat || !header.sectionSyntaxIndicator) {
    return false;
  }
  // 3 header bytes + 5 syntax bytes ... entries ... 4 CRC bytes.
  if (section.size() < 12) {
    return false;
  }
  const std::size_t entriesEnd = section.size() - 4;
  if (entriesEnd < 8 || ((entriesEnd - 8) % 4) != 0) {
    return false;
  }
  table.transportStreamId = header.tableIdExtension;
  for (std::size_t offset = 8; offset + 4 <= entriesEnd; offset += 4) {
    const std::uint16_t programNumber = readBigEndian16(section, offset);
    const std::uint16_t pid = static_cast<std::uint16_t>(
        readBigEndian16(section, offset + 2) & 0x1FFFU);
    if (programNumber == 0) {
      continue;  // network_PID, not a program
    }
    if (table.programCount >= kMaximumPrograms) {
      table.truncated = true;
      break;
    }
    table.programs[table.programCount] = ProgramAssociation{programNumber, pid};
    ++table.programCount;
  }
  return true;
}

MediaCodec codecForStreamType(std::uint8_t streamType, bool ac3Descriptor,
                              bool eac3Descriptor,
                              bool registrationAc3) noexcept {
  switch (streamType) {
    case static_cast<std::uint8_t>(TsStreamType::H264):
      return MediaCodec::H264;
    case static_cast<std::uint8_t>(TsStreamType::Hevc):
      return MediaCodec::Hevc;
    case static_cast<std::uint8_t>(TsStreamType::AdtsAac):
      return MediaCodec::Aac;
    case static_cast<std::uint8_t>(TsStreamType::Mpeg1Audio):
    case static_cast<std::uint8_t>(TsStreamType::Mpeg2Audio):
      return MediaCodec::Mp3;
    case static_cast<std::uint8_t>(TsStreamType::PrivatePes):
      // DVB carries AC-3 as private PES qualified by a descriptor. Without one
      // the stream is genuinely unidentified and must stay Unknown rather than
      // be guessed at.
      if (ac3Descriptor || eac3Descriptor || registrationAc3) {
        return MediaCodec::Unknown;  // see note below
      }
      return MediaCodec::Unknown;
    default:
      break;
  }
  // MPEG-2 video (0x02), MPEG-1 video (0x01), AC-3 (0x81) and E-AC-3 (0x87)
  // have no MediaCodec enumerator today. That is a deliberate, recorded gap:
  // MediaCodec is a frozen contract and appending to it requires the same
  // authorization the Vp8 append received. The demuxer therefore reports the
  // raw stream type in its verdict so the seam above can refuse by name
  // instead of silently dropping a track.
  static_cast<void>(ac3Descriptor);
  static_cast<void>(eac3Descriptor);
  static_cast<void>(registrationAc3);
  return MediaCodec::Unknown;
}

MediaTrackKind trackKindForStreamType(std::uint8_t streamType,
                                      bool ac3Descriptor, bool eac3Descriptor,
                                      bool registrationAc3) noexcept {
  switch (streamType) {
    case static_cast<std::uint8_t>(TsStreamType::Mpeg1Video):
    case static_cast<std::uint8_t>(TsStreamType::Mpeg2Video):
    case static_cast<std::uint8_t>(TsStreamType::Mpeg4Video):
    case static_cast<std::uint8_t>(TsStreamType::H264):
    case static_cast<std::uint8_t>(TsStreamType::Hevc):
      return MediaTrackKind::Video;
    case static_cast<std::uint8_t>(TsStreamType::Mpeg1Audio):
    case static_cast<std::uint8_t>(TsStreamType::Mpeg2Audio):
    case static_cast<std::uint8_t>(TsStreamType::AdtsAac):
    case static_cast<std::uint8_t>(TsStreamType::LatmAac):
    case static_cast<std::uint8_t>(TsStreamType::Ac3Atsc):
    case static_cast<std::uint8_t>(TsStreamType::Eac3Atsc):
    case static_cast<std::uint8_t>(TsStreamType::Dts):
      return MediaTrackKind::Audio;
    case static_cast<std::uint8_t>(TsStreamType::PrivatePes):
      if (ac3Descriptor || eac3Descriptor || registrationAc3) {
        return MediaTrackKind::Audio;
      }
      return MediaTrackKind::Metadata;
    default:
      return MediaTrackKind::Metadata;
  }
}

bool parseProgramMapSection(std::span<const std::byte> section,
                            const SectionHeader& header,
                            ProgramMapTable& table) noexcept {
  table = ProgramMapTable{};
  if (header.tableId != kTableIdPmt || !header.sectionSyntaxIndicator) {
    return false;
  }
  // 8 syntax bytes + 4 program-info bytes + 4 CRC bytes is the minimum.
  if (section.size() < 16) {
    return false;
  }
  const std::size_t end = section.size() - 4;
  table.programNumber = header.tableIdExtension;
  table.pcrPid =
      static_cast<std::uint16_t>(readBigEndian16(section, 8) & 0x1FFFU);
  const std::uint16_t programInfoLength =
      static_cast<std::uint16_t>(readBigEndian16(section, 10) & 0x0FFFU);
  std::size_t cursor = 12 + static_cast<std::size_t>(programInfoLength);
  if (cursor > end) {
    return false;
  }

  while (cursor + 5 <= end) {
    ElementaryStream stream{};
    stream.streamType = byteAt(section, cursor);
    stream.elementaryPid = static_cast<std::uint16_t>(
        readBigEndian16(section, cursor + 1) & 0x1FFFU);
    const std::uint16_t infoLength = static_cast<std::uint16_t>(
        readBigEndian16(section, cursor + 3) & 0x0FFFU);
    const std::size_t descriptorsStart = cursor + 5;
    if (descriptorsStart + infoLength > end) {
      return false;
    }
    for (std::size_t d = descriptorsStart;
         d + 2 <= descriptorsStart + infoLength;) {
      const std::uint8_t tag = byteAt(section, d);
      const std::uint8_t length = byteAt(section, d + 1);
      if (d + 2 + length > descriptorsStart + infoLength) {
        break;
      }
      switch (tag) {
        case 0x6A:  // DVB AC-3_descriptor
          stream.ac3Descriptor = true;
          break;
        case 0x7A:  // DVB enhanced_AC-3_descriptor
          stream.eac3Descriptor = true;
          break;
        case 0x05:  // registration_descriptor
          if (length >= 4) {
            const std::uint32_t identifier = readBigEndian32(section, d + 2);
            if (identifier == 0x41432D33U /* 'AC-3' */) {
              stream.registrationAc3 = true;
            } else if (identifier == 0x45414333U /* 'EAC3' */) {
              stream.eac3Descriptor = true;
            }
          }
          break;
        default:
          break;
      }
      d += 2U + length;
    }
    stream.codec =
        codecForStreamType(stream.streamType, stream.ac3Descriptor,
                           stream.eac3Descriptor, stream.registrationAc3);
    stream.kind =
        trackKindForStreamType(stream.streamType, stream.ac3Descriptor,
                               stream.eac3Descriptor, stream.registrationAc3);
    if (table.streamCount >= kMaximumProgramStreams) {
      table.truncated = true;
      break;
    }
    table.streams[table.streamCount] = stream;
    ++table.streamCount;
    cursor = descriptorsStart + infoLength;
  }
  return true;
}

// ---------------------------------------------------------------------------
// PES
// ---------------------------------------------------------------------------

PesStatus decodePesHeader(std::span<const std::byte> bytes,
                          PesHeader& header) noexcept {
  header = PesHeader{};
  if (bytes.size() < 3) {
    return PesStatus::Incomplete;
  }
  if (bytes[0] != std::byte{0x00} || bytes[1] != std::byte{0x00} ||
      byteAt(bytes, 2) != kPesStartCodePrefixByte) {
    return PesStatus::NotPes;
  }
  if (bytes.size() < kMinimumPesHeaderBytes) {
    return PesStatus::Incomplete;
  }
  header.streamId = byteAt(bytes, 3);
  header.packetLength = readBigEndian16(bytes, 4);
  if (!pesStreamIdHasHeader(header.streamId)) {
    header.headerBytes = static_cast<std::uint8_t>(kMinimumPesHeaderBytes);
    return PesStatus::Ok;
  }
  if (bytes.size() < 9) {
    return PesStatus::Incomplete;
  }
  const std::uint8_t flags1 = byteAt(bytes, 6);
  if ((flags1 & 0xC0U) != 0x80U) {
    // '10' marker bits. Anything else is a PES from a different standard or a
    // mis-sync, and must not be read as a timestamped packet.
    return PesStatus::Malformed;
  }
  header.dataAlignment = (flags1 & 0x04U) != 0;
  const std::uint8_t flags2 = byteAt(bytes, 7);
  const std::uint8_t optionalLength = byteAt(bytes, 8);
  const std::size_t total = 9U + static_cast<std::size_t>(optionalLength);
  if (total > std::numeric_limits<std::uint8_t>::max()) {
    return PesStatus::Malformed;
  }
  if (bytes.size() < total) {
    return PesStatus::Incomplete;
  }
  header.headerBytes = static_cast<std::uint8_t>(total);

  const std::uint8_t timestampFlags =
      static_cast<std::uint8_t>((flags2 >> 6) & 0x03U);
  if (timestampFlags == 0x02U) {
    if (optionalLength < 5 ||
        !decodeTimestampField(bytes, 9, 0x02U, header.pts)) {
      return PesStatus::Malformed;
    }
    header.hasPts = true;
    header.dts = header.pts;
    header.hasDts = false;
  } else if (timestampFlags == 0x03U) {
    if (optionalLength < 10 ||
        !decodeTimestampField(bytes, 9, 0x03U, header.pts) ||
        !decodeTimestampField(bytes, 14, 0x01U, header.dts)) {
      return PesStatus::Malformed;
    }
    header.hasPts = true;
    header.hasDts = true;
  } else if (timestampFlags == 0x01U) {
    // 'forbidden' per 13818-1 Table 2-21.
    return PesStatus::Malformed;
  }
  return PesStatus::Ok;
}

// ---------------------------------------------------------------------------
// Codec-level scanning
// ---------------------------------------------------------------------------

namespace {

// Returns the index of the next 00 00 01 prefix at or after `from`, or the
// span size when none remains.
[[nodiscard]] std::size_t findStartCode(std::span<const std::byte> unit,
                                        std::size_t from) noexcept {
  if (unit.size() < 3) {
    return unit.size();
  }
  for (std::size_t i = from; i + 3 <= unit.size(); ++i) {
    if (unit[i] == std::byte{0x00} && unit[i + 1] == std::byte{0x00} &&
        unit[i + 2] == std::byte{0x01}) {
      return i;
    }
  }
  return unit.size();
}

}  // namespace

AccessUnitScan scanMpeg2AccessUnit(std::span<const std::byte> unit) noexcept {
  AccessUnitScan scan{};
  std::size_t sequenceStart = unit.size();
  bool sawGroupOfPictures = false;
  bool sawIntraPicture = false;

  for (std::size_t i = findStartCode(unit, 0); i + 4 <= unit.size();
       i = findStartCode(unit, i + 3)) {
    const std::uint8_t id = byteAt(unit, i + 3);
    if (id == 0xB3U) {
      scan.hasSequenceHeader = true;
      if (sequenceStart == unit.size()) {
        sequenceStart = i;
      }
    } else if (id == 0xB8U) {
      sawGroupOfPictures = true;
    } else if (id == 0x00U) {
      // picture_header: picture_coding_type is bits 3..5 of the second byte
      // after the start code (10-bit temporal_reference precedes it).
      if (i + 6 <= unit.size()) {
        const std::uint8_t codingType =
            static_cast<std::uint8_t>((byteAt(unit, i + 5) >> 3) & 0x07U);
        if (codingType == 1) {
          sawIntraPicture = true;
        }
      }
    }
  }

  scan.keyFrame = sawIntraPicture || (scan.hasSequenceHeader &&
                                      sawGroupOfPictures);
  // The empirical VideoToolbox probe is the authority here: a cold MPEG-2
  // decompression session needs the in-band sequence header. An I-picture
  // without one is an intra picture, not a random access point.
  scan.decodableFromCold = scan.hasSequenceHeader && scan.keyFrame;
  scan.hasParameterSets = scan.hasSequenceHeader;
  if (scan.hasSequenceHeader && sequenceStart < unit.size()) {
    scan.parameterSetOffset = static_cast<std::uint32_t>(sequenceStart);
    scan.parameterSetSize =
        static_cast<std::uint32_t>(unit.size() - sequenceStart);
  }
  return scan;
}

bool nextAnnexBNal(std::span<const std::byte> unit, std::uint32_t from,
                   MediaCodec codec, AnnexBNal& nal) noexcept {
  nal = AnnexBNal{};
  const std::size_t start = findStartCode(unit, from);
  if (start + 3 >= unit.size()) {
    return false;
  }
  const std::size_t payload = start + 3;
  const std::size_t next = findStartCode(unit, payload);
  // A four-byte start code is a three-byte one preceded by a zero; the extra
  // zero belongs to the start code, not to the previous NAL.
  std::size_t end = next;
  if (end > payload && end < unit.size() && end > 0 &&
      unit[end - 1] == std::byte{0x00}) {
    --end;
  }
  nal.offset = static_cast<std::uint32_t>(payload);
  nal.size = static_cast<std::uint32_t>(end - payload);
  nal.startCodeSize =
      (start > 0 && unit[start - 1] == std::byte{0x00}) ? 4U : 3U;
  const std::uint8_t first = byteAt(unit, payload);
  if (codec == MediaCodec::Hevc) {
    nal.type = static_cast<std::uint8_t>((first >> 1) & 0x3FU);
  } else {
    nal.type = static_cast<std::uint8_t>(first & 0x1FU);
  }
  return true;
}

AccessUnitScan scanAnnexBAccessUnit(std::span<const std::byte> unit,
                                    MediaCodec codec) noexcept {
  AccessUnitScan scan{};
  bool sawIrap = false;
  bool sawSequenceParameterSet = false;
  bool sawPictureParameterSet = false;
  bool sawVideoParameterSet = false;
  std::size_t parameterSetStart = unit.size();
  std::size_t parameterSetEnd = 0;

  AnnexBNal nal{};
  std::uint32_t cursor = 0;
  while (nextAnnexBNal(unit, cursor, codec, nal)) {
    const std::size_t startCodeStart =
        static_cast<std::size_t>(nal.offset) - nal.startCodeSize;
    if (codec == MediaCodec::Hevc) {
      if (nal.type >= 16 && nal.type <= 23) {
        sawIrap = true;  // BLA/IDR/CRA
      } else if (nal.type == 32) {
        sawVideoParameterSet = true;
      } else if (nal.type == 33) {
        sawSequenceParameterSet = true;
      } else if (nal.type == 34) {
        sawPictureParameterSet = true;
      }
      if (nal.type >= 32 && nal.type <= 34) {
        parameterSetStart = std::min(parameterSetStart, startCodeStart);
        parameterSetEnd = std::max<std::size_t>(
            parameterSetEnd, static_cast<std::size_t>(nal.offset) + nal.size);
      }
    } else {
      if (nal.type == 5) {
        sawIrap = true;  // IDR
      } else if (nal.type == 7) {
        sawSequenceParameterSet = true;
      } else if (nal.type == 8) {
        sawPictureParameterSet = true;
      }
      if (nal.type == 7 || nal.type == 8) {
        parameterSetStart = std::min(parameterSetStart, startCodeStart);
        parameterSetEnd = std::max<std::size_t>(
            parameterSetEnd, static_cast<std::size_t>(nal.offset) + nal.size);
      }
    }
    const std::uint32_t advance = nal.offset + nal.size;
    if (advance <= cursor) {
      break;
    }
    cursor = advance;
    if (cursor >= unit.size()) {
      break;
    }
  }

  scan.keyFrame = sawIrap;
  scan.hasParameterSets =
      codec == MediaCodec::Hevc
          ? (sawVideoParameterSet && sawSequenceParameterSet &&
             sawPictureParameterSet)
          : (sawSequenceParameterSet && sawPictureParameterSet);
  scan.decodableFromCold = scan.keyFrame && scan.hasParameterSets;
  if (parameterSetEnd > parameterSetStart && parameterSetStart < unit.size()) {
    scan.parameterSetOffset = static_cast<std::uint32_t>(parameterSetStart);
    scan.parameterSetSize =
        static_cast<std::uint32_t>(parameterSetEnd - parameterSetStart);
  }
  return scan;
}

namespace {

// One pass over the Annex-B NAL units, invoking `visit(offset, size)` for each.
// Returns false if the span holds no complete NAL. Shared by the sizing and
// writing halves of the repack so the two can never disagree about framing —
// a disagreement there would produce a buffer overrun or a truncated sample.
template <typename Visit>
[[nodiscard]] bool walkAnnexB(std::span<const std::byte> unit, MediaCodec codec,
                              Visit&& visit) noexcept {
  AnnexBNal nal{};
  std::uint32_t cursor = 0;
  bool any = false;
  while (nextAnnexBNal(unit, cursor, codec, nal)) {
    if (nal.size == 0) {
      break;
    }
    visit(nal.offset, nal.size);
    any = true;
    const std::uint32_t advance = nal.offset + nal.size;
    if (advance <= cursor || advance >= unit.size()) {
      break;
    }
    cursor = advance;
  }
  return any;
}

}  // namespace

std::size_t annexBToAvccSize(std::span<const std::byte> unit,
                             MediaCodec codec) noexcept {
  std::size_t total = 0;
  bool overflow = false;
  const bool any = walkAnnexB(unit, codec,
                              [&](std::uint32_t, std::uint32_t size) noexcept {
                                if (size > 0xFFFF'FFFFU - 4U) {
                                  overflow = true;
                                  return;
                                }
                                total += static_cast<std::size_t>(size) + 4U;
                              });
  return (any && !overflow) ? total : 0U;
}

std::size_t annexBToAvcc(std::span<const std::byte> unit,
                         std::span<std::byte> destination,
                         MediaCodec codec) noexcept {
  const std::size_t required = annexBToAvccSize(unit, codec);
  if (required == 0 || destination.size() != required) {
    return 0;
  }
  std::size_t written = 0;
  bool failed = false;
  const bool any =
      walkAnnexB(unit, codec,
                 [&](std::uint32_t offset, std::uint32_t size) noexcept {
                   if (failed || written + 4U + size > destination.size()) {
                     failed = true;
                     return;
                   }
                   destination[written] =
                       static_cast<std::byte>((size >> 24) & 0xFFU);
                   destination[written + 1] =
                       static_cast<std::byte>((size >> 16) & 0xFFU);
                   destination[written + 2] =
                       static_cast<std::byte>((size >> 8) & 0xFFU);
                   destination[written + 3] =
                       static_cast<std::byte>(size & 0xFFU);
                   std::memcpy(destination.data() + written + 4U,
                               unit.data() + offset, size);
                   written += 4U + size;
                 });
  if (!any || failed || written != required) {
    return 0;
  }
  return written;
}

AccessUnitScan scanAccessUnit(std::span<const std::byte> unit,
                              MediaCodec codec) noexcept {
  switch (codec) {
    case MediaCodec::H264:
    case MediaCodec::Hevc:
      return scanAnnexBAccessUnit(unit, codec);
    default:
      return scanMpeg2AccessUnit(unit);
  }
}

std::optional<Mpeg2SequenceHeader>
parseMpeg2SequenceHeader(std::span<const std::byte> unit) noexcept {
  for (std::size_t i = findStartCode(unit, 0); i + 4 <= unit.size();
       i = findStartCode(unit, i + 3)) {
    if (byteAt(unit, i + 3) != 0xB3U) {
      continue;
    }
    if (i + 8 > unit.size()) {
      return std::nullopt;
    }
    Mpeg2SequenceHeader header{};
    const std::uint8_t b0 = byteAt(unit, i + 4);
    const std::uint8_t b1 = byteAt(unit, i + 5);
    const std::uint8_t b2 = byteAt(unit, i + 6);
    const std::uint8_t b3 = byteAt(unit, i + 7);
    header.width = (static_cast<std::uint32_t>(b0) << 4) |
                   (static_cast<std::uint32_t>(b1) >> 4);
    header.height = ((static_cast<std::uint32_t>(b1) & 0x0FU) << 8) |
                    static_cast<std::uint32_t>(b2);
    header.aspectRatioInformation =
        static_cast<std::uint8_t>((b3 >> 4) & 0x0FU);
    header.frameRateCode = static_cast<std::uint8_t>(b3 & 0x0FU);
    if (header.width == 0 || header.height == 0) {
      return std::nullopt;
    }
    return header;
  }
  return std::nullopt;
}

std::uint32_t mpeg2FrameDurationTicks(std::uint8_t frameRateCode) noexcept {
  // 13818-2 Table 6-4, expressed exactly against the 90 kHz grid.
  switch (frameRateCode) {
    case 1:
      return 3'754;  // 24000/1001 -> 90000*1001/24000 = 3753.75, see below
    case 2:
      return 3'750;  // 24
    case 3:
      return 3'600;  // 25
    case 4:
      return 3'003;  // 30000/1001
    case 5:
      return 3'000;  // 30
    case 6:
      return 1'800;  // 50
    case 7:
      return 1'502;  // 60000/1001 -> 1501.5, see below
    case 8:
      return 1'500;  // 60
    default:
      return 0;
  }
}

// ---------------------------------------------------------------------------
// Elementary audio framing
// ---------------------------------------------------------------------------

std::uint32_t adtsSampleRateForIndex(std::uint8_t index) noexcept {
  static constexpr std::array<std::uint32_t, 13> kRates{
      96'000, 88'200, 64'000, 48'000, 44'100, 32'000, 24'000,
      22'050, 16'000, 12'000, 11'025, 8'000,  7'350};
  return index < kRates.size() ? kRates[index] : 0U;
}

bool parseAdtsHeader(std::span<const std::byte> bytes,
                     AdtsHeader& header) noexcept {
  header = AdtsHeader{};
  if (bytes.size() < 7) {
    return false;
  }
  if (byteAt(bytes, 0) != 0xFFU || (byteAt(bytes, 1) & 0xF6U) != 0xF0U) {
    return false;
  }
  const bool protectionAbsent = (byteAt(bytes, 1) & 0x01U) != 0;
  const std::uint8_t b2 = byteAt(bytes, 2);
  header.profileObjectType = static_cast<std::uint8_t>(((b2 >> 6) & 0x03U) + 1U);
  header.samplingFrequencyIndex =
      static_cast<std::uint8_t>((b2 >> 2) & 0x0FU);
  header.sampleRate = adtsSampleRateForIndex(header.samplingFrequencyIndex);
  header.channelConfiguration = static_cast<std::uint8_t>(
      ((b2 & 0x01U) << 2) | ((byteAt(bytes, 3) >> 6) & 0x03U));
  header.frameBytes =
      (static_cast<std::uint32_t>(byteAt(bytes, 3) & 0x03U) << 11) |
      (static_cast<std::uint32_t>(byteAt(bytes, 4)) << 3) |
      (static_cast<std::uint32_t>(byteAt(bytes, 5)) >> 5);
  header.headerBytes = protectionAbsent ? 7U : 9U;
  if (header.sampleRate == 0 || header.frameBytes < header.headerBytes) {
    return false;
  }
  return true;
}

bool parseAc3SyncFrame(std::span<const std::byte> bytes,
                       Ac3SyncFrame& frame) noexcept {
  frame = Ac3SyncFrame{};
  if (bytes.size() < 6) {
    return false;
  }
  if (byteAt(bytes, 0) != 0x0BU || byteAt(bytes, 1) != 0x77U) {
    return false;
  }
  const std::uint8_t fscod = static_cast<std::uint8_t>((byteAt(bytes, 4) >> 6) &
                                                       0x03U);
  const std::uint8_t frmsizecod =
      static_cast<std::uint8_t>(byteAt(bytes, 4) & 0x3FU);
  if (fscod > 2 || frmsizecod > 37) {
    return false;
  }
  static constexpr std::array<std::uint32_t, 3> kRates{48'000, 44'100, 32'000};
  // A/52 Table 5.18: frame size in 16-bit words, indexed by frmsizecod >> 1,
  // with the odd codes adding one word at 44.1 kHz only.
  static constexpr std::array<std::uint16_t, 19> kWords48{
      64,  80,  96,  112, 128, 160, 192,  224,  256, 320,
      384, 448, 512, 640, 768, 896, 1024, 1152, 1280};
  static constexpr std::array<std::uint16_t, 19> kWords441{
      69,  87,  104, 121, 139, 174, 208,  243,  278, 348,
      417, 487, 557, 696, 835, 975, 1114, 1253, 1393};
  static constexpr std::array<std::uint16_t, 19> kWords32{
      96,  120, 144, 168, 192, 240, 288,  336,  384, 480,
      576, 672, 768, 960, 1152, 1344, 1536, 1728, 1920};
  const std::size_t index = static_cast<std::size_t>(frmsizecod) / 2U;
  const std::uint32_t words =
      fscod == 0 ? kWords48[index]
                 : (fscod == 1 ? static_cast<std::uint32_t>(kWords441[index])
                               : kWords32[index]);
  frame.sampleRate = kRates[fscod];
  frame.frameBytes = words * 2U;

  // acmod and lfeon live in bsi, after bsid(5) and bsmod(3) in byte 5.
  const std::uint8_t acmod = static_cast<std::uint8_t>((byteAt(bytes, 6) >> 5) &
                                                       0x07U);
  static constexpr std::array<std::uint8_t, 8> kChannels{2, 1, 2, 3, 3, 4, 4, 5};
  frame.channels = kChannels[acmod];
  // The lfe bit's position depends on acmod's extra fields; a conservative
  // parse is enough for admission because the decoder re-reads the frame.
  frame.lfe = false;
  return frame.frameBytes >= 6;
}

bool parseMpegAudioFrame(std::span<const std::byte> bytes,
                         MpegAudioFrame& frame) noexcept {
  frame = MpegAudioFrame{};
  if (bytes.size() < 4) {
    return false;
  }
  if (byteAt(bytes, 0) != 0xFFU || (byteAt(bytes, 1) & 0xE0U) != 0xE0U) {
    return false;
  }
  const std::uint8_t versionBits =
      static_cast<std::uint8_t>((byteAt(bytes, 1) >> 3) & 0x03U);
  const std::uint8_t layerBits =
      static_cast<std::uint8_t>((byteAt(bytes, 1) >> 1) & 0x03U);
  if (versionBits == 1 || layerBits == 0) {
    return false;  // reserved
  }
  frame.version = versionBits == 3 ? 1U : (versionBits == 2 ? 2U : 3U);
  frame.layer = static_cast<std::uint8_t>(4U - layerBits);

  const std::uint8_t bitrateIndex =
      static_cast<std::uint8_t>((byteAt(bytes, 2) >> 4) & 0x0FU);
  const std::uint8_t rateIndex =
      static_cast<std::uint8_t>((byteAt(bytes, 2) >> 2) & 0x03U);
  if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) {
    return false;
  }
  const bool padding = (byteAt(bytes, 2) & 0x02U) != 0;
  const std::uint8_t mode =
      static_cast<std::uint8_t>((byteAt(bytes, 3) >> 6) & 0x03U);
  frame.channels = mode == 3 ? 1U : 2U;

  static constexpr std::array<std::uint32_t, 3> kBaseRates{44'100, 48'000,
                                                           32'000};
  std::uint32_t sampleRate = kBaseRates[rateIndex];
  if (frame.version == 2) {
    sampleRate /= 2U;
  } else if (frame.version == 3) {
    sampleRate /= 4U;
  }
  frame.sampleRate = sampleRate;

  // kbit/s tables, MPEG-1 layers I/II/III then MPEG-2/2.5 layers I / II+III.
  static constexpr std::array<std::uint16_t, 15> kV1L1{
      0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448};
  static constexpr std::array<std::uint16_t, 15> kV1L2{
      0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384};
  static constexpr std::array<std::uint16_t, 15> kV1L3{
      0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320};
  static constexpr std::array<std::uint16_t, 15> kV2L1{
      0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256};
  static constexpr std::array<std::uint16_t, 15> kV2L23{
      0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160};

  std::uint32_t kilobits = 0;
  if (frame.version == 1) {
    kilobits = frame.layer == 1   ? kV1L1[bitrateIndex]
               : frame.layer == 2 ? kV1L2[bitrateIndex]
                                  : kV1L3[bitrateIndex];
    frame.samplesPerFrame = frame.layer == 1 ? 384U : 1'152U;
  } else {
    kilobits = frame.layer == 1 ? kV2L1[bitrateIndex] : kV2L23[bitrateIndex];
    frame.samplesPerFrame = frame.layer == 1   ? 384U
                            : frame.layer == 2 ? 1'152U
                                               : 576U;
  }
  if (kilobits == 0 || frame.sampleRate == 0) {
    return false;
  }
  const std::uint32_t bitsPerSecond = kilobits * 1'000U;
  if (frame.layer == 1) {
    frame.frameBytes =
        ((12U * bitsPerSecond / frame.sampleRate) + (padding ? 1U : 0U)) * 4U;
  } else {
    const std::uint32_t coefficient = frame.samplesPerFrame / 8U;
    frame.frameBytes =
        (coefficient * bitsPerSecond / frame.sampleRate) + (padding ? 1U : 0U);
  }
  return frame.frameBytes >= 4;
}

}  // namespace wam::media::mpegts
