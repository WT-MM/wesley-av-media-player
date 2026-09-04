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

ProgramGrade gradeProgram(const ProgramMapTable& table) noexcept {
  bool video = false;
  bool audio = false;
  for (std::uint8_t s = 0; s < table.streamCount && s < table.streams.size();
       ++s) {
    const ElementaryStream& stream = table.streams[s];
    if (stream.codec == MediaCodec::Unknown) {
      continue;
    }
    if (stream.kind == MediaTrackKind::Video) {
      video = true;
    } else if (stream.kind == MediaTrackKind::Audio) {
      audio = true;
    }
  }
  if (!video) {
    return ProgramGrade::None;
  }
  return audio ? ProgramGrade::Complete : ProgramGrade::VideoOnly;
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
    case static_cast<std::uint8_t>(TsStreamType::LatmAac):
      // ONE routing family, two framings. LOAS/LATM carries the same raw AAC
      // access units ADTS does -- verified byte-for-byte against ADTS twins of
      // the same encode -- so it needs no MediaCodec value of its own and the
      // whole downstream (ES_Descriptor cookie, 1024-frame grid, audio-
      // authoritative clock) is shared. The framing difference is carried by
      // the stream type, which the demuxer already retains.
      return MediaCodec::Aac;
    case static_cast<std::uint8_t>(TsStreamType::Mpeg1Audio):
    case static_cast<std::uint8_t>(TsStreamType::Mpeg2Audio):
      // One routing family covers MPEG-1/2 Layer I-III. The exact layer is
      // read from the frame header at admission and becomes the '.mp1'/'.mp2'/
      // '.mp3' format tag; MediaCodec::Mp3 is the family, not the layer.
      return MediaCodec::Mp3;
    case static_cast<std::uint8_t>(TsStreamType::Mpeg2Video):
      // Appended to MediaCodec 2026-08-20 under the SESSION_HANDOFF amendment.
      // VideoToolbox decodes this through a software decoder and needs no
      // out-of-band configuration record.
      return MediaCodec::Mpeg2Video;
    case static_cast<std::uint8_t>(TsStreamType::Ac3Atsc):
      return MediaCodec::Ac3;
    case static_cast<std::uint8_t>(TsStreamType::Eac3Atsc):
      return MediaCodec::Eac3;
    case static_cast<std::uint8_t>(TsStreamType::PrivatePes):
      // DVB carries AC-3 as private PES qualified by a descriptor. Without one
      // the stream is genuinely unidentified and must stay Unknown rather than
      // be guessed at. E-AC-3 is checked first because a stream may legally
      // carry both descriptors and the enhanced one is the more specific fact.
      if (eac3Descriptor) {
        return MediaCodec::Eac3;
      }
      if (ac3Descriptor || registrationAc3) {
        return MediaCodec::Ac3;
      }
      return MediaCodec::Unknown;
    default:
      break;
  }
  // MPEG-1 video (0x01), MPEG-4 part 2 (0x10) and DTS (0x82) still have no
  // route. That remains a deliberate, recorded gap: the demuxer reports the raw
  // stream type in its verdict so the seam above refuses by name instead of
  // silently dropping a track.
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
        scan.sliceInProbe = true;
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
  bool sawSlice = false;
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
      // ISO/IEC 23008-2 puts every video coding layer NAL below 32; 16..23 is
      // the IRAP range (BLA_W_LP through the reserved IRAP types), which is
      // exactly the random-access set.
      if (nal.type < 32) {
        sawSlice = true;
      }
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
      // ISO/IEC 14496-10 nal_unit_type 1..5 are the coded slice types.
      if (nal.type >= 1 && nal.type <= 5) {
        sawSlice = true;
      }
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
  scan.sliceInProbe = sawSlice;
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

namespace {

// Bit reader over one NAL unit payload with ISO/IEC 23008-2 emulation
// prevention undone as it reads. Allocation-free by construction: the
// unescape is a running zero-count over the source span, never a copy into a
// scratch buffer, which is what lets this live in the pure layer.
class HevcRbspBitReader final {
 public:
  explicit HevcRbspBitReader(std::span<const std::byte> escaped) noexcept
      : bytes_(escaped) {}

  [[nodiscard]] bool readBits(std::uint32_t count,
                              std::uint32_t& value) noexcept {
    if (count > 32) {
      return false;
    }
    value = 0;
    for (std::uint32_t index = 0; index < count; ++index) {
      if (bitsLeft_ == 0) {
        if (!nextByte(current_)) {
          return false;
        }
        bitsLeft_ = 8;
      }
      --bitsLeft_;
      value = (value << 1) |
              ((static_cast<std::uint32_t>(current_) >> bitsLeft_) & 0x01U);
    }
    return true;
  }

  [[nodiscard]] bool skipBits(std::uint32_t count) noexcept {
    std::uint32_t ignored = 0;
    while (count > 32) {
      if (!readBits(32, ignored)) {
        return false;
      }
      count -= 32;
    }
    return readBits(count, ignored);
  }

  // ue(v). A leading-zero run past 30 is refused rather than shifted: the
  // fields this reader consumes are all small, and an unbounded run is a
  // mis-parse, not a large value.
  [[nodiscard]] bool readUnsignedExpGolomb(std::uint32_t& value) noexcept {
    std::uint32_t leadingZeros = 0;
    std::uint32_t bit = 0;
    while (true) {
      if (!readBits(1, bit)) {
        return false;
      }
      if (bit != 0) {
        break;
      }
      ++leadingZeros;
      if (leadingZeros > 30) {
        return false;
      }
    }
    if (leadingZeros == 0) {
      value = 0;
      return true;
    }
    std::uint32_t remainder = 0;
    if (!readBits(leadingZeros, remainder)) {
      return false;
    }
    value = ((1U << leadingZeros) - 1U) + remainder;
    return true;
  }

 private:
  // The next RBSP byte. A 0x03 that follows two zero bytes is the
  // emulation-prevention byte: it is consumed and the byte after it is
  // returned, with the zero run restarted from that byte.
  [[nodiscard]] bool nextByte(std::uint8_t& out) noexcept {
    if (cursor_ >= bytes_.size()) {
      return false;
    }
    std::uint8_t value = byteAt(bytes_, cursor_);
    if (zeros_ >= 2 && value == 0x03U) {
      ++cursor_;
      if (cursor_ >= bytes_.size()) {
        return false;
      }
      value = byteAt(bytes_, cursor_);
      zeros_ = 0;
    }
    ++cursor_;
    zeros_ = value == 0U ? zeros_ + 1U : 0U;
    out = value;
    return true;
  }

  std::span<const std::byte> bytes_;
  std::size_t cursor_{0};
  std::uint32_t zeros_{0};
  std::uint8_t current_{0};
  std::uint32_t bitsLeft_{0};
};

}  // namespace

bool parseHevcSpsFacts(std::span<const std::byte> nal,
                       HevcSpsFacts& facts) noexcept {
  facts = HevcSpsFacts{};
  if (nal.size() < 3) {
    return false;
  }
  const std::uint8_t header0 = byteAt(nal, 0);
  const std::uint8_t header1 = byteAt(nal, 1);
  // forbidden_zero_bit, nal_unit_type == SPS, nuh_layer_id == 0 and
  // nuh_temporal_id_plus1 == 1. A parameter set on a non-base layer or a
  // non-zero temporal id is refused here rather than assembled into a record
  // the shared inspector would reject anyway -- the refusal is more useful
  // where the bytes are.
  if ((header0 & 0x80U) != 0U || ((header0 >> 1U) & 0x3FU) != 33U ||
      (header0 & 0x01U) != 0U || (header1 >> 3U) != 0U ||
      (header1 & 0x07U) != 1U) {
    return false;
  }

  HevcRbspBitReader bits(nal.subspan(2));
  std::uint32_t value = 0;
  if (!bits.readBits(4, value) ||          // sps_video_parameter_set_id
      !bits.readBits(3, value) || value > 6) {
    return false;
  }
  facts.maxSubLayersMinusOne = static_cast<std::uint8_t>(value);
  if (!bits.readBits(1, value)) {
    return false;
  }
  facts.temporalIdNested = value != 0;

  // The verbatim twelve. See the header for why this is a copy and not a
  // decode: the whole profile_tier_level() prefix is byte-aligned here.
  for (std::uint8_t& byte : facts.profileTierLevel) {
    if (!bits.readBits(8, value)) {
      return false;
    }
    byte = static_cast<std::uint8_t>(value);
  }

  std::array<bool, 8> profilePresent{};
  std::array<bool, 8> levelPresent{};
  for (std::uint32_t layer = 0; layer < facts.maxSubLayersMinusOne; ++layer) {
    if (!bits.readBits(1, value)) {
      return false;
    }
    profilePresent[layer] = value != 0;
    if (!bits.readBits(1, value)) {
      return false;
    }
    levelPresent[layer] = value != 0;
  }
  if (facts.maxSubLayersMinusOne > 0) {
    for (std::uint32_t layer = facts.maxSubLayersMinusOne; layer < 8U;
         ++layer) {
      if (!bits.skipBits(2)) {
        return false;
      }
    }
  }
  for (std::uint32_t layer = 0; layer < facts.maxSubLayersMinusOne; ++layer) {
    // A present sub-layer profile is the same 88-bit prefix minus the level
    // byte; the level byte follows separately.
    if (profilePresent[layer] && !bits.skipBits(88)) {
      return false;
    }
    if (levelPresent[layer] && !bits.skipBits(8)) {
      return false;
    }
  }

  std::uint32_t ignored = 0;
  std::uint32_t chromaFormat = 0;
  if (!bits.readUnsignedExpGolomb(ignored) || ignored > 15U ||
      !bits.readUnsignedExpGolomb(chromaFormat) || chromaFormat > 3U) {
    return false;
  }
  facts.chromaFormatIdc = static_cast<std::uint8_t>(chromaFormat);
  if (chromaFormat == 3U && !bits.skipBits(1)) {
    return false;
  }
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t conformanceWindow = 0;
  if (!bits.readUnsignedExpGolomb(width) || width == 0U ||
      !bits.readUnsignedExpGolomb(height) || height == 0U ||
      !bits.readBits(1, conformanceWindow)) {
    return false;
  }
  if (conformanceWindow != 0U) {
    for (int edge = 0; edge < 4; ++edge) {
      if (!bits.readUnsignedExpGolomb(ignored)) {
        return false;
      }
    }
  }
  std::uint32_t luma = 0;
  std::uint32_t chroma = 0;
  if (!bits.readUnsignedExpGolomb(luma) || luma > 7U ||
      !bits.readUnsignedExpGolomb(chroma) || chroma > 7U) {
    return false;
  }
  facts.bitDepthLumaMinusEight = static_cast<std::uint8_t>(luma);
  facts.bitDepthChromaMinusEight = static_cast<std::uint8_t>(chroma);
  return true;
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

// ---------------------------------------------------------------------------
// LOAS / LATM
// ---------------------------------------------------------------------------

namespace {

// A bounded MSB-first bit reader over one LOAS frame. Every read is checked
// against the frame's own declared end, so a truncated or lying frame runs out
// of bits and is refused instead of reading into whatever follows it.
class LatmBitReader {
 public:
  LatmBitReader(std::span<const std::byte> bytes, std::uint32_t bitLimit,
                std::uint32_t position) noexcept
      : bytes_(bytes), limit_(bitLimit), position_(position) {}

  [[nodiscard]] bool read(std::uint32_t count, std::uint32_t& value) noexcept {
    value = 0;
    if (count > 32U || position_ + count > limit_) {
      overrun_ = true;
      return false;
    }
    for (std::uint32_t i = 0; i < count; ++i) {
      const std::size_t index = static_cast<std::size_t>(position_ >> 3U);
      if (index >= bytes_.size()) {
        overrun_ = true;
        return false;
      }
      const std::uint32_t bit =
          (static_cast<std::uint32_t>(byteAt(bytes_, index)) >>
           (7U - (position_ & 7U))) &
          1U;
      value = (value << 1U) | bit;
      ++position_;
    }
    return true;
  }

  // ISO/IEC 14496-3 LATM "LatmGetValue": a 2-bit byte count followed by that
  // many-plus-one bytes, most significant first.
  [[nodiscard]] bool readLatmValue(std::uint32_t& value) noexcept {
    std::uint32_t byteCount = 0;
    if (!read(2, byteCount)) {
      return false;
    }
    value = 0;
    for (std::uint32_t i = 0; i <= byteCount; ++i) {
      std::uint32_t part = 0;
      if (!read(8, part)) {
        return false;
      }
      value = (value << 8U) | part;
    }
    return true;
  }

  [[nodiscard]] bool skip(std::uint32_t count) noexcept {
    if (position_ + count > limit_) {
      overrun_ = true;
      return false;
    }
    position_ += count;
    return true;
  }

  [[nodiscard]] std::uint32_t position() const noexcept { return position_; }
  [[nodiscard]] bool overrun() const noexcept { return overrun_; }

 private:
  std::span<const std::byte> bytes_;
  std::uint32_t limit_{0};
  std::uint32_t position_{0};
  bool overrun_{false};
};

// Reads AudioSpecificConfig far enough to know exactly where it ends. The bit
// LENGTH is the point: audioMuxVersion 0 does not signal it, so the only way to
// find the frameLengthType that follows is to parse the config to its last bit.
//
// Deliberately narrow -- this is a routing gate, not a general MPEG-4 parser.
// The shared AAC admission re-parses the bytes it emits and applies the real
// codec policy; anything with a program_config_element, an explicit sampling
// frequency, or a core-coder dependency is refused HERE by structure, because
// those forms change the config's length and a wrong length silently misframes
// every subsequent field.
[[nodiscard]] bool readAudioSpecificConfig(LatmBitReader& reader,
                                           LatmStreamMuxConfig& config,
                                           std::uint32_t start) noexcept {
  std::uint32_t objectType = 0;
  if (!reader.read(5, objectType)) {
    return false;
  }
  if (objectType == 31U) {
    // AOT escape: 32 + a further six bits. No such object type is routable
    // here, but it must be READ correctly to be refused correctly.
    std::uint32_t extended = 0;
    if (!reader.read(6, extended)) {
      return false;
    }
    objectType = 32U + extended;
  }
  std::uint32_t frequencyIndex = 0;
  if (!reader.read(4, frequencyIndex)) {
    return false;
  }
  if (frequencyIndex == 15U) {
    return false;  // explicit 24-bit rate: not admitted, see above
  }
  std::uint32_t channelConfiguration = 0;
  if (!reader.read(4, channelConfiguration)) {
    return false;
  }
  if (channelConfiguration == 0U) {
    return false;  // program_config_element: not admitted, see above
  }
  if (objectType == 5U || objectType == 29U) {
    // Explicit SBR/PS signalling. The extension rate and the CORE object type
    // follow, and the core type is what the GASpecificConfig below belongs to.
    std::uint32_t extensionFrequencyIndex = 0;
    if (!reader.read(4, extensionFrequencyIndex)) {
      return false;
    }
    if (extensionFrequencyIndex == 15U) {
      return false;
    }
    if (!reader.read(5, objectType)) {
      return false;
    }
    if (objectType == 22U && !reader.skip(4)) {
      return false;
    }
  }
  // GASpecificConfig for the object types that use it. Anything else has a
  // different config body whose length this parser cannot state.
  if (objectType != 1U && objectType != 2U && objectType != 3U &&
      objectType != 4U && objectType != 6U && objectType != 7U &&
      objectType != 17U && objectType != 19U && objectType != 20U &&
      objectType != 21U && objectType != 22U && objectType != 23U) {
    return false;
  }
  std::uint32_t frameLengthFlag = 0;
  if (!reader.read(1, frameLengthFlag)) {
    return false;
  }
  std::uint32_t dependsOnCoreCoder = 0;
  if (!reader.read(1, dependsOnCoreCoder)) {
    return false;
  }
  if (dependsOnCoreCoder != 0U) {
    return false;  // coreCoderDelay follows; not admitted, see above
  }
  std::uint32_t extensionFlag = 0;
  if (!reader.read(1, extensionFlag)) {
    return false;
  }
  if (objectType == 6U || objectType == 20U) {
    if (!reader.skip(3)) {  // layerNr
      return false;
    }
  }
  if (extensionFlag != 0U) {
    if (objectType == 22U && !reader.skip(5 + 11)) {
      return false;
    }
    if ((objectType == 17U || objectType == 19U || objectType == 20U ||
         objectType == 23U) &&
        !reader.skip(3)) {
      return false;
    }
    if (!reader.skip(1)) {  // extensionFlag3
      return false;
    }
  }

  // A trailing SBR/PS sync extension is deliberately NOT consumed here.
  // audioMuxVersion 0 does not state the config's length, so the only way to
  // know whether the next 11 bits are an extension or the frameLengthType that
  // follows the config is to guess -- and a wrong guess misframes the entire
  // rest of the stream silently. Left unconsumed, an extension's leading bits
  // (0x2B7 -> 010...) read as frameLengthType 2, which this route refuses BY
  // NAME as UnsupportedMux. A named refusal of HE-AAC-in-LATM-v0 is the honest
  // outcome; the shared AAC admission refuses explicit SBR anyway.
  const std::uint32_t bits = reader.position() - start;
  if (bits == 0U || bits > kMaximumLatmAudioSpecificConfigBytes * 8U) {
    return false;
  }
  config.audioObjectType = static_cast<std::uint8_t>(objectType);
  config.samplingFrequencyIndex = static_cast<std::uint8_t>(frequencyIndex);
  config.sampleRate =
      adtsSampleRateForIndex(static_cast<std::uint8_t>(frequencyIndex));
  config.channelConfiguration = static_cast<std::uint8_t>(channelConfiguration);
  config.audioSpecificConfigBits = static_cast<std::uint16_t>(bits);
  config.audioSpecificConfigBytes = static_cast<std::uint8_t>((bits + 7U) / 8U);
  return config.sampleRate != 0U;
}

// Re-reads the config's exact bits and left-aligns them into whole bytes,
// zero-padding the tail. That padding is not cosmetic: the shared AAC admission
// refuses nonzero trailing bits, so a config re-emitted with stale padding
// would be rejected downstream for a reason that has nothing to do with it.
[[nodiscard]] bool captureAudioSpecificConfig(std::span<const std::byte> bytes,
                                              std::uint32_t bitLimit,
                                              std::uint32_t start,
                                              LatmStreamMuxConfig& config) noexcept {
  LatmBitReader reader(bytes, bitLimit, start);
  const std::uint32_t bits = config.audioSpecificConfigBits;
  config.audioSpecificConfig = {};
  for (std::uint32_t i = 0; i < bits; ++i) {
    std::uint32_t bit = 0;
    if (!reader.read(1, bit)) {
      return false;
    }
    if (bit != 0U) {
      const std::size_t index = static_cast<std::size_t>(i >> 3U);
      if (index >= config.audioSpecificConfig.size()) {
        return false;
      }
      config.audioSpecificConfig[index] |=
          static_cast<std::byte>(1U << (7U - (i & 7U)));
    }
  }
  return true;
}

[[nodiscard]] LatmStatus readStreamMuxConfig(std::span<const std::byte> bytes,
                                             std::uint32_t bitLimit,
                                             LatmBitReader& reader,
                                             LatmStreamMuxConfig& config) noexcept {
  config = LatmStreamMuxConfig{};
  std::uint32_t audioMuxVersion = 0;
  if (!reader.read(1, audioMuxVersion)) {
    return LatmStatus::Malformed;
  }
  config.audioMuxVersion = static_cast<std::uint8_t>(audioMuxVersion);
  if (audioMuxVersion == 1U) {
    std::uint32_t audioMuxVersionA = 0;
    if (!reader.read(1, audioMuxVersionA)) {
      return LatmStatus::Malformed;
    }
    if (audioMuxVersionA != 0U) {
      // Reserved in 14496-3 and unparseable by construction.
      return LatmStatus::UnsupportedMux;
    }
    std::uint32_t taraBufferFullness = 0;
    if (!reader.readLatmValue(taraBufferFullness)) {
      return LatmStatus::Malformed;
    }
  }
  std::uint32_t allStreamsSameTimeFraming = 0;
  std::uint32_t numSubFrames = 0;
  std::uint32_t numProgram = 0;
  std::uint32_t numLayer = 0;
  if (!reader.read(1, allStreamsSameTimeFraming) ||
      !reader.read(6, numSubFrames) || !reader.read(4, numProgram) ||
      !reader.read(3, numLayer)) {
    return LatmStatus::Malformed;
  }
  // The admitted shape, stated once. Every one of these is legal MPEG-4 and
  // none of it appears in a broadcast AAC service; carrying them would mean
  // multiplexing several programs or scalable layers out of one elementary
  // stream, which this player has no way to present.
  if (allStreamsSameTimeFraming != 1U || numSubFrames != 0U ||
      numProgram != 0U || numLayer != 0U) {
    return LatmStatus::UnsupportedMux;
  }

  const std::uint32_t configStart = reader.position();
  if (audioMuxVersion == 0U) {
    if (!readAudioSpecificConfig(reader, config, configStart)) {
      return LatmStatus::UnsupportedMux;
    }
  } else {
    // audioMuxVersion 1 states the config's length explicitly, which is the
    // whole point of the version: a decoder may skip a config it cannot parse.
    // We still parse it, then honour the DECLARED length -- the two disagreeing
    // means the mux and this parser read different syntax, and following our
    // own answer would misframe everything after it.
    std::uint32_t declaredBits = 0;
    if (!reader.readLatmValue(declaredBits)) {
      return LatmStatus::Malformed;
    }
    const std::uint32_t declaredStart = reader.position();
    if (!readAudioSpecificConfig(reader, config, declaredStart)) {
      return LatmStatus::UnsupportedMux;
    }
    const std::uint32_t consumed = reader.position() - declaredStart;
    if (declaredBits < consumed) {
      return LatmStatus::Malformed;
    }
    if (!reader.skip(declaredBits - consumed)) {
      return LatmStatus::Malformed;
    }
    // The DECLARED length is the config, not the part this parser understood.
    // A trailing SBR/PS sync extension lives in exactly that gap, and the
    // shared AAC admission is the thing entitled to rule on it -- handing it a
    // config truncated to `consumed` would present an HE-AAC stream as plain
    // AAC-LC, which is the one wrong answer worse than a refusal.
    if (declaredBits > kMaximumLatmAudioSpecificConfigBytes * 8U) {
      return LatmStatus::UnsupportedMux;
    }
    config.audioSpecificConfigBits = static_cast<std::uint16_t>(declaredBits);
    config.audioSpecificConfigBytes =
        static_cast<std::uint8_t>((declaredBits + 7U) / 8U);
    if (!captureAudioSpecificConfig(bytes, bitLimit, declaredStart, config)) {
      return LatmStatus::Malformed;
    }
    config.audioMuxVersion = 1U;
  }
  if (audioMuxVersion == 0U &&
      !captureAudioSpecificConfig(bytes, bitLimit, configStart, config)) {
    return LatmStatus::Malformed;
  }

  std::uint32_t frameLengthType = 0;
  if (!reader.read(3, frameLengthType)) {
    return LatmStatus::Malformed;
  }
  if (frameLengthType != 0U) {
    // Type 1 is a fixed frame length in the config; types 3-7 are CELP/HVXC.
    // Only type 0 carries the per-frame MuxSlotLengthBytes this route reads.
    return LatmStatus::UnsupportedMux;
  }
  config.frameLengthType = 0;
  if (!reader.skip(8)) {  // latmBufferFullness
    return LatmStatus::Malformed;
  }

  std::uint32_t otherDataPresent = 0;
  if (!reader.read(1, otherDataPresent)) {
    return LatmStatus::Malformed;
  }
  if (otherDataPresent != 0U) {
    if (audioMuxVersion == 1U) {
      std::uint32_t otherDataLenBits = 0;
      if (!reader.readLatmValue(otherDataLenBits)) {
        return LatmStatus::Malformed;
      }
    } else {
      // An escape-coded length: an 8-bit chunk per iteration, continued while
      // the leading bit is set.
      for (std::uint32_t guard = 0;; ++guard) {
        std::uint32_t escape = 0;
        std::uint32_t chunk = 0;
        if (guard > 8U || !reader.read(1, escape) || !reader.read(8, chunk)) {
          return LatmStatus::Malformed;
        }
        if (escape == 0U) {
          break;
        }
      }
    }
  }
  std::uint32_t crcCheckPresent = 0;
  if (!reader.read(1, crcCheckPresent)) {
    return LatmStatus::Malformed;
  }
  if (crcCheckPresent != 0U && !reader.skip(8)) {
    return LatmStatus::Malformed;
  }
  return LatmStatus::Ok;
}

}  // namespace

const char* latmStatusName(LatmStatus status) noexcept {
  switch (status) {
    case LatmStatus::Ok:
      return "Ok";
    case LatmStatus::NotSynced:
      return "NotSynced";
    case LatmStatus::Incomplete:
      return "Incomplete";
    case LatmStatus::Malformed:
      return "Malformed";
    case LatmStatus::UnsupportedMux:
      return "UnsupportedMux";
    case LatmStatus::ConfigUnavailable:
      return "ConfigUnavailable";
  }
  return "Unknown";
}

LatmStatus parseLatmFrame(std::span<const std::byte> bytes,
                          const LatmStreamMuxConfig* established,
                          LatmFrame& frame) noexcept {
  frame = LatmFrame{};
  if (bytes.size() < kLoasHeaderBytes) {
    return LatmStatus::Incomplete;
  }
  // AudioSyncStream: an 11-bit syncword then a 13-bit audioMuxLengthBytes.
  const std::uint32_t header =
      (static_cast<std::uint32_t>(byteAt(bytes, 0)) << 16U) |
      (static_cast<std::uint32_t>(byteAt(bytes, 1)) << 8U) |
      static_cast<std::uint32_t>(byteAt(bytes, 2));
  if (((header >> 13U) & 0x7FFU) != kLoasSyncWord) {
    return LatmStatus::NotSynced;
  }
  const std::uint32_t muxLength = header & 0x1FFFU;
  if (muxLength == 0U) {
    return LatmStatus::Malformed;
  }
  frame.frameBytes =
      static_cast<std::uint32_t>(kLoasHeaderBytes) + muxLength;
  if (bytes.size() < frame.frameBytes) {
    return LatmStatus::Incomplete;
  }
  // Every subsequent read is bounded by the frame's OWN declared end, not by
  // the span, so a caller that hands us a whole PES payload cannot have one
  // frame's parse walk into the next.
  const std::uint32_t bitLimit = frame.frameBytes * 8U;
  LatmBitReader reader(bytes, bitLimit,
                       static_cast<std::uint32_t>(kLoasHeaderBytes) * 8U);

  std::uint32_t useSameStreamMux = 0;
  if (!reader.read(1, useSameStreamMux)) {
    return LatmStatus::Malformed;
  }
  if (useSameStreamMux == 0U) {
    const LatmStatus status =
        readStreamMuxConfig(bytes, bitLimit, reader, frame.config);
    if (status != LatmStatus::Ok) {
      return status;
    }
    frame.configPresent = true;
  } else {
    if (established == nullptr) {
      return LatmStatus::ConfigUnavailable;
    }
    frame.config = *established;
    if (frame.config.frameLengthType != 0U) {
      return LatmStatus::UnsupportedMux;
    }
  }

  // PayloadLengthInfo for the admitted shape: MuxSlotLengthBytes as a run of
  // 8-bit values, each 255 meaning "add 255 and continue".
  std::uint32_t payloadBytes = 0;
  for (std::uint32_t guard = 0;; ++guard) {
    std::uint32_t part = 0;
    // A slot cannot exceed the frame that contains it, so the run is bounded by
    // the frame length rather than by an invented constant.
    if (guard > kMaximumLoasFrameBytes / 255U + 1U || !reader.read(8, part)) {
      return LatmStatus::Malformed;
    }
    payloadBytes += part;
    if (part != 255U) {
      break;
    }
  }
  frame.payloadBitOffset = reader.position();
  frame.payloadBytes = payloadBytes;
  // The access unit plus the bits already consumed must fit inside the frame.
  // ByteAlign() leaves at most seven bits of padding after it.
  const std::uint64_t end =
      static_cast<std::uint64_t>(frame.payloadBitOffset) +
      static_cast<std::uint64_t>(payloadBytes) * 8U;
  if (payloadBytes == 0U || end > bitLimit) {
    return LatmStatus::Malformed;
  }
  return LatmStatus::Ok;
}

bool latmCopyPayload(std::span<const std::byte> frame, const LatmFrame& facts,
                     std::span<std::byte> destination) noexcept {
  if (facts.payloadBytes == 0U ||
      destination.size() != static_cast<std::size_t>(facts.payloadBytes)) {
    return false;
  }
  const std::uint64_t end =
      static_cast<std::uint64_t>(facts.payloadBitOffset) +
      static_cast<std::uint64_t>(facts.payloadBytes) * 8U;
  if (frame.size() < facts.frameBytes ||
      end > static_cast<std::uint64_t>(facts.frameBytes) * 8U) {
    return false;
  }
  const std::size_t first = static_cast<std::size_t>(facts.payloadBitOffset >> 3U);
  const std::uint32_t shift = facts.payloadBitOffset & 7U;
  if (shift == 0U) {
    std::memcpy(destination.data(), frame.data() + first, facts.payloadBytes);
    return true;
  }
  // Straddling copy: each output byte is the low (8 - shift) bits of one source
  // byte followed by the high `shift` bits of the next. The final read is at
  // `first + payloadBytes`, which the bound above proved is inside the frame.
  const std::uint32_t low = 8U - shift;
  for (std::uint32_t i = 0; i < facts.payloadBytes; ++i) {
    const std::uint32_t high =
        static_cast<std::uint32_t>(byteAt(frame, first + i)) << shift;
    const std::uint32_t rest =
        static_cast<std::uint32_t>(byteAt(frame, first + i + 1U)) >> low;
    destination[i] = static_cast<std::byte>((high | rest) & 0xFFU);
  }
  return true;
}

bool parseAc3SyncFrame(std::span<const std::byte> bytes,
                       Ac3SyncFrame& frame) noexcept {
  frame = Ac3SyncFrame{};
  // Seven bytes, not six: acmod is read out of byte 6 below, and a six-byte
  // span would read past the end of the span to find it.
  if (bytes.size() < 7) {
    return false;
  }
  if (byteAt(bytes, 0) != 0x0BU || byteAt(bytes, 1) != 0x77U) {
    return false;
  }
  // bsid first: this parser reads the LEGACY bsi, and an E-AC-3 frame's bytes
  // 2-4 mean something else entirely. Refusing here is what stops a plausible
  // but wrong frame length from being handed to the frame walk.
  const std::uint8_t bsid =
      static_cast<std::uint8_t>((byteAt(bytes, 5) >> 3) & 0x1FU);
  if (bsid > 10U) {
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
  // The odd half of each frmsizecod pair carries ONE MORE 16-bit word, and
  // only at 44.1 kHz. 48 kHz and 32 kHz divide 1,536 samples evenly at every
  // admitted bit rate, so both codes of a pair name the same size there; 44.1
  // kHz does not, and A/52 Table 5.18 alternates the frame length to keep the
  // average bit rate exact.
  //
  // Omitting this is not a rounding error, it is a hard framing failure: a
  // real 128 kb/s 44.1 kHz stream alternates 556 and 558 bytes (measured on
  // fixtures/ac3.es -- sync words at 0, 556, 1114, 1672, 2228, ... and
  // frmsizecod alternating 16, 17, 17, 16, 17), so a parser that always
  // reports the even size walks off the sync word on the second frame of every
  // PES payload and the whole audio track is refused.
  const std::uint32_t oddWord =
      fscod == 1 ? static_cast<std::uint32_t>(frmsizecod & 1U) : 0U;
  const std::uint32_t words =
      fscod == 0 ? kWords48[index]
                 : (fscod == 1
                        ? static_cast<std::uint32_t>(kWords441[index]) + oddWord
                        : kWords32[index]);
  frame.sampleRate = kRates[fscod];
  frame.frameBytes = words * 2U;
  frame.bitstreamId = bsid;
  frame.enhanced = false;
  // Legacy AC-3 always codes six blocks of 256 samples. There is no field.
  frame.samplesPerFrame = kAc3BlocksPerSyncFrame * kAc3SamplesPerBlock;

  // acmod and lfeon live in bsi, after bsid(5) and bsmod(3) in byte 5.
  const std::uint8_t acmod = static_cast<std::uint8_t>((byteAt(bytes, 6) >> 5) &
                                                       0x07U);
  frame.fullBandwidthChannels = kAc3AcmodChannels[acmod];
  // The lfe bit's position depends on acmod's extra fields -- and it is worth
  // reading exactly, because it is the difference between a 5.1 stream being
  // described as six channels and as five. A five-channel ASBD on a 5.1 stream
  // is not a rounding error: the converter would lay out the decoder's own
  // output wrongly. A/52 5.3.2 puts these three conditional fields between
  // acmod and lfeon, each present only for the acmod values that need them.
  std::uint32_t offset = 3;  // bits consumed of byte 6, starting after acmod
  if ((acmod & 0x01U) != 0U && acmod != 0x01U) {
    offset += 2;  // cmixlev
  }
  if ((acmod & 0x04U) != 0U) {
    offset += 2;  // surmixlev
  }
  if (acmod == 0x02U) {
    offset += 2;  // dsurmod
  }
  // Every combination above keeps lfeon inside byte 6 (the widest is
  // 3 + 2 + 2 = 7 bits consumed, leaving bit 0), so no further byte is read.
  frame.lfe = ((byteAt(bytes, 6) >> (7U - offset)) & 0x01U) != 0U;
  frame.channels = static_cast<std::uint8_t>(frame.fullBandwidthChannels +
                                             (frame.lfe ? 1U : 0U));
  return frame.frameBytes >= 6;
}

bool parseEac3SyncFrame(std::span<const std::byte> bytes,
                        Ac3SyncFrame& frame) noexcept {
  frame = Ac3SyncFrame{};
  // Six bytes: bsid is read out of byte 5 to prove this really is E-AC-3.
  if (bytes.size() < 6) {
    return false;
  }
  if (byteAt(bytes, 0) != 0x0BU || byteAt(bytes, 1) != 0x77U) {
    return false;
  }
  // A/52 Annex E bsi. The layout diverges from legacy AC-3 immediately after
  // the sync word -- where AC-3 has crc1 and a frmsizecod TABLE INDEX, E-AC-3
  // has strmtyp/substreamid and an explicit frmsiz WORD COUNT. Reading one as
  // the other yields a plausible-looking frame length that is simply wrong,
  // which is exactly why every E-AC-3 transport stream was being dropped: the
  // legacy parser "succeeded" on garbage and the frame walk then failed to
  // divide the PES into whole frames.
  const std::uint8_t bsid =
      static_cast<std::uint8_t>((byteAt(bytes, 5) >> 3) & 0x1FU);
  if (bsid != kEac3BitstreamId) {
    return false;
  }
  const std::uint32_t frmsiz =
      (static_cast<std::uint32_t>(byteAt(bytes, 2) & 0x07U) << 8) |
      static_cast<std::uint32_t>(byteAt(bytes, 3));
  const std::uint8_t fscod =
      static_cast<std::uint8_t>((byteAt(bytes, 4) >> 6) & 0x03U);
  const std::uint8_t numblkscod =
      static_cast<std::uint8_t>((byteAt(bytes, 4) >> 4) & 0x03U);
  const std::uint8_t acmod =
      static_cast<std::uint8_t>((byteAt(bytes, 4) >> 1) & 0x07U);
  const bool lfeon = (byteAt(bytes, 4) & 0x01U) != 0U;

  static constexpr std::array<std::uint32_t, 3> kRates{48'000, 44'100, 32'000};
  if (fscod == 3U) {
    // fscod 3 selects a half-rate stream through fscod2 and pins six blocks.
    // Those rates (24/22.05/16 kHz) are outside this player's admitted audio
    // envelope, so the frame is refused here by structure rather than admitted
    // and then rejected with a less specific verdict downstream.
    return false;
  }
  // numblkscod names 1, 2, 3 or 6 blocks of 256 samples.
  static constexpr std::array<std::uint32_t, 4> kBlocks{1, 2, 3, 6};
  frame.sampleRate = kRates[fscod];
  frame.frameBytes = (frmsiz + 1U) * 2U;
  frame.samplesPerFrame = kBlocks[numblkscod] * kAc3SamplesPerBlock;
  frame.fullBandwidthChannels = kAc3AcmodChannels[acmod];
  frame.lfe = lfeon;
  frame.channels = static_cast<std::uint8_t>(frame.fullBandwidthChannels +
                                             (lfeon ? 1U : 0U));
  frame.bitstreamId = bsid;
  frame.enhanced = true;
  return frame.frameBytes >= 6;
}

bool parseAc3OrEac3SyncFrame(std::span<const std::byte> bytes,
                             Ac3SyncFrame& frame) noexcept {
  // bsid sits at byte 5 bits 7..3 in BOTH syntaxes -- legacy AC-3 reaches it
  // through crc1 and fscod/frmsizecod, E-AC-3 through strmtyp/substreamid,
  // frmsiz and fscod/numblkscod/acmod/lfeon, and both land on the same bit.
  // That coincidence is what makes a single dispatch honest rather than a
  // heuristic.
  if (bytes.size() >= 6 && byteAt(bytes, 0) == 0x0BU &&
      byteAt(bytes, 1) == 0x77U &&
      ((byteAt(bytes, 5) >> 3) & 0x1FU) == kEac3BitstreamId) {
    return parseEac3SyncFrame(bytes, frame);
  }
  return parseAc3SyncFrame(bytes, frame);
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
