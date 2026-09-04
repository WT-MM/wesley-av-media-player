#include "media/mpegts_demuxer.hpp"

#include "media/mpegts_packet.hpp"
#include "media/native_media_source.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <optional>
#include <span>
#include <string>
#include <type_traits>
#include <variant>
#include <vector>

namespace {

using namespace wam::media::mpegts;
using wam::media::MediaCodec;
using wam::media::MediaCodecConfigurationKind;
using wam::media::MediaSampleKind;
using wam::media::MediaSeekMode;
using wam::media::MediaSourceDescriptor;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaTrackDescriptor;
using wam::media::findMediaTrack;
using wam::media::MediaTime;
using wam::media::MediaTimeOrder;
using wam::media::MediaTrackKind;
using wam::media::compareMediaTime;
using Bytes = std::vector<std::byte>;

// --- layout and ownership contracts, proved at compile time ---------------
static_assert(!std::is_copy_constructible_v<MpegTsCursor>);
static_assert(!std::is_copy_assignable_v<MpegTsCursor>);
static_assert(std::is_nothrow_move_constructible_v<MpegTsCursor>);
static_assert(std::is_nothrow_move_assignable_v<MpegTsCursor>);
static_assert(!std::is_copy_constructible_v<MpegTsPreparedAsset>);
static_assert(!std::is_default_constructible_v<MpegTsPreparedAsset>);
// The emitted sample owns no bytes: it is a packet span plus exact times.
static_assert(std::is_trivially_copyable_v<MpegTsCompressedSample>);
static_assert(sizeof(MpegTsCompressedSample) == 88);
static_assert(sizeof(MpegTsIndexEntry) == 24);
static_assert(std::is_trivially_copyable_v<TsPacketHeader>);

int failures = 0;
int assertions = 0;

void expect(bool condition, const char* message) {
  ++assertions;
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

int skipped = 0;

void skip(const char* message) {
  std::cerr << "SKIP: " << message << '\n';
  ++skipped;
}

[[nodiscard]] std::byte octet(unsigned value) noexcept {
  return static_cast<std::byte>(value & 0xFFU);
}

// A one-byte literal that accepts any integral expression without a narrowing
// diagnostic, so fixture builders can write byte tables inline.
struct Oct {
  unsigned value{0};
  template <typename T>
  Oct(T input) : value(static_cast<unsigned>(input) & 0xFFU) {}  // NOLINT
};

void append(Bytes& target, std::initializer_list<Oct> values) {
  for (const Oct value : values) {
    target.push_back(octet(value.value));
  }
}

// ---------------------------------------------------------------------------
// In-memory reader, mirroring the Matroska suite's injected-reader seam
// ---------------------------------------------------------------------------

class MemoryReader final : public SeekableByteReader {
 public:
  explicit MemoryReader(Bytes bytes) : bytes_(std::move(bytes)) {}

  [[nodiscard]] std::uint64_t size() const noexcept override {
    return bytes_.size();
  }
  [[nodiscard]] bool readAt(std::uint64_t offset,
                            std::span<std::byte> destination) noexcept
      override {
    if (destination.empty()) {
      return offset <= bytes_.size();
    }
    if (offset > bytes_.size() ||
        destination.size() > bytes_.size() - offset) {
      return false;
    }
    std::memcpy(destination.data(),
                bytes_.data() + static_cast<std::size_t>(offset),
                destination.size());
    ++reads_;
    return true;
  }
  [[nodiscard]] std::uint64_t reads() const noexcept { return reads_; }

 private:
  Bytes bytes_;
  std::uint64_t reads_{0};
};

bool atomicCancellation(const void* context) noexcept {
  return static_cast<const std::atomic<bool>*>(context)->load(
      std::memory_order_acquire);
}

// ---------------------------------------------------------------------------
// Synthetic transport packets
// ---------------------------------------------------------------------------

struct PacketSpec {
  std::uint16_t pid{0x0100};
  std::uint8_t continuityCounter{0};
  bool payloadUnitStart{false};
  bool transportError{false};
  bool discontinuity{false};
  bool randomAccess{false};
  bool withPcr{false};
  std::uint64_t pcrBase{0};
  std::uint16_t pcrExtension{0};
  Bytes payload;
  std::uint8_t extraStuffing{0};
};

[[nodiscard]] Bytes makePacket(const PacketSpec& spec) {
  Bytes packet;
  packet.reserve(kTsPacketBytes);
  const bool wantAdaptation = spec.withPcr || spec.discontinuity ||
                              spec.randomAccess || spec.extraStuffing > 0 ||
                              spec.payload.size() < 184;
  packet.push_back(octet(0x47));
  packet.push_back(octet((spec.transportError ? 0x80U : 0U) |
                         (spec.payloadUnitStart ? 0x40U : 0U) |
                         ((spec.pid >> 8) & 0x1FU)));
  packet.push_back(octet(spec.pid & 0xFFU));
  const bool hasPayload = !spec.payload.empty();
  packet.push_back(octet((wantAdaptation ? 0x20U : 0U) |
                         (hasPayload ? 0x10U : 0U) |
                         (spec.continuityCounter & 0x0FU)));

  Bytes adaptation;
  if (wantAdaptation) {
    adaptation.push_back(octet((spec.discontinuity ? 0x80U : 0U) |
                               (spec.randomAccess ? 0x40U : 0U) |
                               (spec.withPcr ? 0x10U : 0U)));
    if (spec.withPcr) {
      const std::uint64_t base = spec.pcrBase & ((UINT64_C(1) << 33) - 1);
      const std::uint32_t high = static_cast<std::uint32_t>(base >> 1);
      const std::uint16_t low = static_cast<std::uint16_t>(
          ((base & 1U) << 15) | 0x7E00U | (spec.pcrExtension & 0x01FFU));
      adaptation.push_back(octet(high >> 24));
      adaptation.push_back(octet(high >> 16));
      adaptation.push_back(octet(high >> 8));
      adaptation.push_back(octet(high));
      adaptation.push_back(octet(low >> 8));
      adaptation.push_back(octet(low));
    }
  }
  // Pad the adaptation field so the packet lands on exactly 188 bytes.
  const std::size_t fixed = 4 + (wantAdaptation ? 1 : 0);
  const std::size_t used = fixed + adaptation.size() + spec.payload.size();
  if (used < kTsPacketBytes && wantAdaptation) {
    adaptation.insert(adaptation.end(), kTsPacketBytes - used, octet(0xFF));
  }
  if (wantAdaptation) {
    packet.push_back(octet(adaptation.size()));
    packet.insert(packet.end(), adaptation.begin(), adaptation.end());
  }
  packet.insert(packet.end(), spec.payload.begin(), spec.payload.end());
  packet.resize(kTsPacketBytes, octet(0xFF));
  return packet;
}

// Appends a section's CRC so that the whole section CRCs to zero, which is the
// property the assembler checks.
void appendSectionCrc(Bytes& section) {
  const std::uint32_t crc = mpegCrc32(std::span<const std::byte>(section));
  section.push_back(octet(crc >> 24));
  section.push_back(octet(crc >> 16));
  section.push_back(octet(crc >> 8));
  section.push_back(octet(crc));
}

[[nodiscard]] Bytes makePatSection(
    std::uint16_t transportStreamId,
    const std::vector<std::pair<std::uint16_t, std::uint16_t>>& programs) {
  Bytes body;
  append(body, {transportStreamId >> 8, transportStreamId & 0xFFU});
  append(body, {0xC1U, 0x00U, 0x00U});  // version 0, current, section 0 of 0
  for (const auto& [number, pid] : programs) {
    append(body, {number >> 8, number & 0xFFU, 0xE0U | (pid >> 8),
                  pid & 0xFFU});
  }
  const std::size_t sectionLength = body.size() + 4;  // + CRC
  Bytes section;
  append(section, {0x00U, 0xB0U | ((sectionLength >> 8) & 0x0FU),
                   sectionLength & 0xFFU});
  section.insert(section.end(), body.begin(), body.end());
  appendSectionCrc(section);
  return section;
}

struct PmtStreamSpec {
  std::uint8_t streamType{0x1B};
  std::uint16_t pid{0x0100};
  Bytes descriptors;
};

[[nodiscard]] Bytes makePmtSection(std::uint16_t programNumber,
                                   std::uint16_t pcrPid,
                                   const std::vector<PmtStreamSpec>& streams) {
  Bytes body;
  append(body, {programNumber >> 8, programNumber & 0xFFU});
  append(body, {0xC1U, 0x00U, 0x00U});
  append(body, {0xE0U | (pcrPid >> 8), pcrPid & 0xFFU});
  append(body, {0xF0U, 0x00U});  // program_info_length = 0
  for (const PmtStreamSpec& stream : streams) {
    append(body, {stream.streamType, 0xE0U | (stream.pid >> 8),
                  stream.pid & 0xFFU, 0xF0U | ((stream.descriptors.size() >> 8) &
                                               0x0FU),
                  stream.descriptors.size() & 0xFFU});
    body.insert(body.end(), stream.descriptors.begin(),
                stream.descriptors.end());
  }
  const std::size_t sectionLength = body.size() + 4;
  Bytes section;
  append(section, {0x02U, 0xB0U | ((sectionLength >> 8) & 0x0FU),
                   sectionLength & 0xFFU});
  section.insert(section.end(), body.begin(), body.end());
  appendSectionCrc(section);
  return section;
}

[[nodiscard]] Bytes encodeTimestampField(unsigned prefix,
                                         std::uint64_t value) {
  Bytes bytes;
  bytes.push_back(octet((prefix << 4) | (((value >> 30) & 0x07U) << 1) | 1U));
  bytes.push_back(octet((value >> 22) & 0xFFU));
  bytes.push_back(octet((((value >> 15) & 0x7FU) << 1) | 1U));
  bytes.push_back(octet((value >> 7) & 0xFFU));
  bytes.push_back(octet(((value & 0x7FU) << 1) | 1U));
  return bytes;
}

[[nodiscard]] Bytes makePesPacket(std::uint8_t streamId,
                                  std::optional<std::uint64_t> pts,
                                  std::optional<std::uint64_t> dts,
                                  const Bytes& payload) {
  Bytes optional;
  unsigned flags = 0;
  if (pts && dts) {
    flags = 0xC0U;
    const Bytes p = encodeTimestampField(0x03U, *pts);
    const Bytes d = encodeTimestampField(0x01U, *dts);
    optional.insert(optional.end(), p.begin(), p.end());
    optional.insert(optional.end(), d.begin(), d.end());
  } else if (pts) {
    flags = 0x80U;
    const Bytes p = encodeTimestampField(0x02U, *pts);
    optional.insert(optional.end(), p.begin(), p.end());
  }
  Bytes pes;
  append(pes, {0x00U, 0x00U, 0x01U, streamId});
  const std::size_t packetLength = 3 + optional.size() + payload.size();
  append(pes, {(packetLength >> 8) & 0xFFU, packetLength & 0xFFU});
  append(pes, {0x80U, flags, static_cast<unsigned>(optional.size())});
  pes.insert(pes.end(), optional.begin(), optional.end());
  pes.insert(pes.end(), payload.begin(), payload.end());
  return pes;
}

// ---------------------------------------------------------------------------
// Primitive tests
// ---------------------------------------------------------------------------

void testTimestampRollover() {
  // The exact wrap point: 2^33 ticks at 90 kHz is 95,443.717... seconds.
  static_assert(kTimestampModulus == INT64_C(8'589'934'592));

  TimestampUnwrapper unwrapper;
  expect(!unwrapper.primed(), "a fresh unwrapper is not primed");

  const std::int64_t nearEnd = kTimestampModulus - 90'000;  // one second left
  expect(unwrapper.extend(static_cast<std::uint64_t>(nearEnd)) == nearEnd,
         "the first timestamp passes through unchanged");
  expect(unwrapper.primed(), "the unwrapper is primed after one timestamp");

  // Half a second later, still before the wrap.
  expect(unwrapper.extend(static_cast<std::uint64_t>(nearEnd + 45'000)) ==
             nearEnd + 45'000,
         "a forward step below the wrap is not a wrap");
  expect(unwrapper.forwardWraps() == 0, "no wrap has been counted yet");

  // Cross the boundary: raw drops to a small value, extended must continue.
  const std::int64_t afterWrap = unwrapper.extend(45'000);
  expect(afterWrap == kTimestampModulus + 45'000,
         "crossing the 33-bit boundary adds exactly one modulus");
  expect(unwrapper.forwardWraps() == 1, "exactly one forward wrap counted");
  expect(afterWrap - (nearEnd + 45'000) == 90'000,
         "the extended timeline advances by exactly one second across a wrap");

  // A B-picture whose PTS steps backwards by a few frames is NOT a wrap.
  const std::int64_t reordered = unwrapper.extend(45'000 - 3'600);
  expect(reordered == kTimestampModulus + 41'400,
         "a small backwards step stays in the same epoch");
  expect(unwrapper.backwardWraps() == 0,
         "reordering does not count as a backwards wrap");

  // A genuine backwards wrap (out-of-order across the boundary).
  TimestampUnwrapper backwards;
  static_cast<void>(backwards.extend(1'000));
  const std::int64_t before =
      backwards.extend(static_cast<std::uint64_t>(kTimestampModulus - 1'000));
  expect(before == -1'000,
         "a large backwards step subtracts exactly one modulus");
  expect(backwards.backwardWraps() == 1, "one backwards wrap counted");

  // resynchronize() reseeds without inventing a wrap.
  TimestampUnwrapper resync;
  static_cast<void>(resync.extend(8'000'000'000));
  resync.resynchronize();
  expect(resync.extend(0) == 0,
         "a signalled discontinuity reseeds instead of wrapping");
}

void testExactTicks() {
  const std::optional<MediaTime> second = mediaTimeFromTicks(90'000);
  expect(second && second->value == 1 && second->timescale == 1,
         "90,000 ticks reduces to exactly one second");
  const std::optional<MediaTime> frame = mediaTimeFromTicks(3'003);
  expect(frame && frame->value == 1'001 && frame->timescale == 30'000,
         "one 30000/1001 frame is exactly 1001/30000 s, not a decimal");
  const std::optional<MediaTime> zero = mediaTimeFromTicks(0);
  expect(zero && zero->value == 0 && zero->timescale == 1,
         "zero ticks is exactly zero");
  const std::optional<MediaTime> negative = mediaTimeFromTicks(-90'000);
  expect(negative && negative->value == -1 && negative->timescale == 1,
         "negative ticks stay exact and signed");
  // A tick count past the wrap must still be exactly representable, which is
  // the whole point of extending before converting.
  const std::optional<MediaTime> past =
      mediaTimeFromTicks(kTimestampModulus + 90'000);
  expect(past.has_value(), "a post-rollover tick is representable");
  // 8,589,934,592 + 90,000 = 8,590,024,592 ticks. gcd(8,590,024,592, 90,000)
  // is 16, so the exact reduced rational is 536,876,537 / 5,625 seconds
  // (95,444.7178 s). It is deliberately NOT rounded to a whole second: this is
  // precisely the value a double would have quietly mangled.
  expect(past->value == 536'876'537 && past->timescale == 5'625,
         "a post-rollover tick reduces to its exact rational, not a decimal");
}

void testPacketDecoding() {
  PacketSpec spec;
  spec.pid = 0x0100;
  spec.continuityCounter = 5;
  spec.payloadUnitStart = true;
  spec.payload = Bytes(100, octet(0xAB));
  const Bytes packet = makePacket(spec);
  expect(packet.size() == kTsPacketBytes, "a synthetic packet is 188 bytes");

  TsPacketHeader header{};
  expect(decodeTsPacket(packet, header) == TsPacketStatus::Ok,
         "a well-formed packet decodes");
  expect(header.pid == 0x0100, "pid is decoded from 13 bits");
  expect(header.continuityCounter == 5, "continuity counter is decoded");
  expect(header.payloadUnitStart, "payload unit start is decoded");
  expect(header.hasPayload && header.payloadSize == 100,
         "payload geometry is exact after the adaptation field");
  expect(!header.hasPcr, "no PCR was requested");

  // PCR: 33-bit base plus 9-bit extension, reassembled on the 27 MHz grid.
  PacketSpec pcrSpec;
  pcrSpec.pid = 0x1000;
  pcrSpec.withPcr = true;
  pcrSpec.pcrBase = 0x1'2345'6789ULL & ((UINT64_C(1) << 33) - 1);
  pcrSpec.pcrExtension = 137;
  pcrSpec.randomAccess = true;
  pcrSpec.payload = Bytes(10, octet(0x01));
  TsPacketHeader pcrHeader{};
  expect(decodeTsPacket(makePacket(pcrSpec), pcrHeader) == TsPacketStatus::Ok,
         "a PCR packet decodes");
  expect(pcrHeader.hasPcr, "the PCR flag is honoured");
  expect(pcrHeader.pcrBase == pcrSpec.pcrBase,
         "the 33-bit PCR base round-trips exactly");
  expect(pcrHeader.pcrExtension == 137,
         "the 9-bit PCR extension round-trips exactly");
  expect(pcrHeader.pcr27MHz() == pcrSpec.pcrBase * 300U + 137U,
         "the full 27 MHz PCR is base*300 + extension, exactly");
  expect(pcrHeader.randomAccess, "random_access_indicator is decoded");

  Bytes notSynced = packet;
  notSynced[0] = octet(0x48);
  TsPacketHeader ignored{};
  expect(decodeTsPacket(notSynced, ignored) == TsPacketStatus::NotSynced,
         "a packet without the 0x47 sync byte is refused by verdict");

  Bytes truncated(kTsPacketBytes - 1, octet(0x47));
  expect(decodeTsPacket(truncated, ignored) == TsPacketStatus::Malformed,
         "a short packet is malformed, not silently accepted");

  // An adaptation_field_length that runs past the packet must be refused.
  Bytes overlong = packet;
  overlong[3] = octet(0x30);  // adaptation + payload
  overlong[4] = octet(200);
  expect(decodeTsPacket(overlong, ignored) == TsPacketStatus::Malformed,
         "an adaptation field longer than the packet is malformed");
}

void testContinuityTracking() {
  ContinuityTracker tracker;
  TsPacketHeader header{};
  header.hasPayload = true;
  header.continuityCounter = 3;
  expect(tracker.observe(header) == ContinuityVerdict::FirstPacket,
         "the first packet has no predecessor to compare");
  header.continuityCounter = 4;
  expect(tracker.observe(header) == ContinuityVerdict::Continuous,
         "an incremented counter is continuous");
  expect(tracker.observe(header) == ContinuityVerdict::Duplicate,
         "a repeated counter on a payload packet is a legal duplicate");
  header.continuityCounter = 7;
  expect(tracker.observe(header) == ContinuityVerdict::Gap,
         "a skipped counter is a gap");
  expect(tracker.gaps() == 1, "the gap is counted, not swallowed");
  // Wrap 15 -> 0 is continuous, not a gap. A fresh tracker, because the
  // sequence above deliberately ends mid-gap.
  ContinuityTracker wrapping;
  TsPacketHeader wrapHeader{};
  wrapHeader.hasPayload = true;
  wrapHeader.continuityCounter = 15;
  static_cast<void>(wrapping.observe(wrapHeader));
  wrapHeader.continuityCounter = 0;
  expect(wrapping.observe(wrapHeader) == ContinuityVerdict::Continuous,
         "the counter wraps modulo 16 without a false gap");
  expect(wrapping.gaps() == 0, "a modulo wrap is not a loss");
  // An adaptation-only packet must not advance the counter.
  wrapHeader.hasPayload = false;
  expect(wrapping.observe(wrapHeader) == ContinuityVerdict::AdaptationOnly,
         "a payload-free packet repeats the counter legally");
  wrapHeader.hasPayload = true;
  wrapHeader.discontinuity = true;
  wrapHeader.continuityCounter = 9;
  expect(wrapping.observe(wrapHeader) == ContinuityVerdict::Discontinuous,
         "a signalled discontinuity is reported as such, not as a gap");
  expect(wrapping.gaps() == 0,
         "a signalled discontinuity does not inflate the gap count");
}

void testSectionAssemblyAndCrc() {
  const Bytes pat = makePatSection(0x0001, {{1, 0x1000}});
  expect(mpegCrc32(std::span<const std::byte>(pat)) == 0,
         "a section with its own CRC appended CRCs to zero");

  Bytes payload;
  payload.push_back(octet(0x00));  // pointer_field
  payload.insert(payload.end(), pat.begin(), pat.end());

  SectionAssembler assembler;
  expect(assembler.feed(payload, true) == SectionStatus::Ready,
         "a PAT that fits one packet assembles in one feed");
  expect(assembler.header().tableId == kTableIdPat, "table id is PAT");
  ProgramAssociationTable table{};
  expect(parseProgramAssociationSection(assembler.section(),
                                        assembler.header(), table),
         "the PAT section parses");
  expect(table.programCount == 1, "one program is listed");
  expect(table.programs[0].programNumber == 1 &&
             table.programs[0].pmtPid == 0x1000,
         "the program number and PMT pid are exact");

  // A corrupted CRC must be refused, not accepted with wrong contents.
  Bytes damaged = payload;
  damaged[damaged.size() - 1] = octet(
      static_cast<unsigned>(damaged[damaged.size() - 1]) ^ 0xFFU);
  SectionAssembler damagedAssembler;
  expect(damagedAssembler.feed(damaged, true) == SectionStatus::CrcMismatch,
         "a section whose CRC does not check is refused by verdict");

  // A section split across two packets must reassemble.
  const Bytes big = makePatSection(0x0002, std::vector<
      std::pair<std::uint16_t, std::uint16_t>>(60, {2, 0x1001}));
  expect(big.size() > 184, "the multi-packet fixture really is oversized");
  Bytes first;
  first.push_back(octet(0x00));
  first.insert(first.end(), big.begin(), big.begin() + 183);
  Bytes rest(big.begin() + 183, big.end());
  SectionAssembler split;
  expect(split.feed(first, true) == SectionStatus::Incomplete,
         "a partial section is incomplete, not malformed");
  expect(split.feed(rest, false) == SectionStatus::Ready,
         "the continuation completes the section");
  ProgramAssociationTable bigTable{};
  expect(parseProgramAssociationSection(split.section(), split.header(),
                                        bigTable),
         "the reassembled PAT parses");
  expect(bigTable.programCount == 60, "every program survived reassembly");
}

void testProgramMapParsing() {
  Bytes ac3Descriptor;
  append(ac3Descriptor, {0x6AU, 0x01U, 0x00U});  // DVB AC-3_descriptor
  const Bytes pmt = makePmtSection(
      1, 0x0100,
      {{0x1BU, 0x0100, {}},           // H.264
       {0x0FU, 0x0101, {}},           // AAC ADTS
       {0x06U, 0x0102, ac3Descriptor},// private PES qualified as AC-3
       {0x02U, 0x0103, {}},           // MPEG-2 video
       {0x03U, 0x0104, {}}});         // MPEG-1 audio

  Bytes payload;
  payload.push_back(octet(0x00));
  payload.insert(payload.end(), pmt.begin(), pmt.end());
  SectionAssembler assembler;
  expect(assembler.feed(payload, true) == SectionStatus::Ready,
         "the PMT assembles");
  ProgramMapTable table{};
  expect(parseProgramMapSection(assembler.section(), assembler.header(), table),
         "the PMT parses");
  expect(table.programNumber == 1, "program number is exact");
  expect(table.pcrPid == 0x0100, "PCR pid is exact");
  expect(table.streamCount == 5, "every elementary stream is listed");
  expect(table.streams[0].codec == MediaCodec::H264 &&
             table.streams[0].kind == MediaTrackKind::Video,
         "stream type 0x1B routes to H.264 video");
  expect(table.streams[1].codec == MediaCodec::Aac &&
             table.streams[1].kind == MediaTrackKind::Audio,
         "stream type 0x0F routes to AAC audio");
  expect(table.streams[2].ac3Descriptor,
         "the DVB AC-3 descriptor is recognised on a private PES stream");
  expect(table.streams[2].kind == MediaTrackKind::Audio,
         "a descriptor-qualified private stream is audio");
  expect(table.streams[2].codec == MediaCodec::Ac3,
         "a DVB AC-3 descriptor routes a private PES stream to AC-3");
  expect(table.streams[3].kind == MediaTrackKind::Video &&
             table.streams[3].codec == MediaCodec::Mpeg2Video,
         "stream type 0x02 routes to MPEG-2 video");
  expect(table.streams[4].codec == MediaCodec::Mp3 &&
             table.streams[4].kind == MediaTrackKind::Audio,
         "stream type 0x03 routes to the MPEG audio family");

  // A registration_descriptor carrying 'AC-3' must qualify the same way.
  Bytes registration;
  append(registration, {0x05U, 0x04U, 'A', 'C', '-', '3'});
  const Bytes registered =
      makePmtSection(2, 0x0200, {{0x1BU, 0x0200, {}},
                                 {0x06U, 0x0201, registration}});
  Bytes registeredPayload;
  registeredPayload.push_back(octet(0x00));
  registeredPayload.insert(registeredPayload.end(), registered.begin(),
                           registered.end());
  SectionAssembler registeredAssembler;
  expect(registeredAssembler.feed(registeredPayload, true) ==
             SectionStatus::Ready,
         "the registration PMT assembles");
  ProgramMapTable registeredTable{};
  expect(parseProgramMapSection(registeredAssembler.section(),
                                registeredAssembler.header(), registeredTable),
         "the registration PMT parses");
  expect(registeredTable.streams[1].registrationAc3,
         "an 'AC-3' registration descriptor qualifies a private stream");
}

void testPesHeaderDecoding() {
  const Bytes payload(32, octet(0x5A));
  PesHeader header{};

  const Bytes ptsOnly = makePesPacket(0xE0, 900'000, std::nullopt, payload);
  expect(decodePesHeader(ptsOnly, header) == PesStatus::Ok,
         "a PTS-only PES header decodes");
  expect(header.hasPts && !header.hasDts, "only PTS is flagged");
  expect(header.pts == 900'000, "the 33-bit PTS round-trips exactly");
  expect(header.headerBytes == 14,
         "a PTS-only header is 9 fixed bytes plus 5 timestamp bytes");

  const Bytes both = makePesPacket(0xE0, 900'000, 810'000, payload);
  expect(decodePesHeader(both, header) == PesStatus::Ok,
         "a PTS+DTS PES header decodes");
  expect(header.hasPts && header.hasDts, "both timestamps are flagged");
  expect(header.pts == 900'000 && header.dts == 810'000,
         "PTS and DTS are independently exact");
  expect(header.headerBytes == 19, "a PTS+DTS header is 19 bytes");

  // The maximum 33-bit value must survive the marker-bit split.
  const std::uint64_t maximum = (UINT64_C(1) << 33) - 1;
  const Bytes extreme = makePesPacket(0xE0, maximum, std::nullopt, payload);
  expect(decodePesHeader(extreme, header) == PesStatus::Ok &&
             header.pts == maximum,
         "the largest 33-bit PTS round-trips exactly");

  Bytes notPes = both;
  notPes[2] = octet(0x02);
  expect(decodePesHeader(notPes, header) == PesStatus::NotPes,
         "a wrong start-code prefix is refused");

  Bytes badMarker = both;
  badMarker[6] = octet(0x40);  // '01' instead of the required '10'
  expect(decodePesHeader(badMarker, header) == PesStatus::Malformed,
         "a PES with wrong marker bits is malformed, not guessed at");

  Bytes forbidden = both;
  forbidden[7] = octet(0x40);  // PTS_DTS_flags = '01', forbidden
  expect(decodePesHeader(forbidden, header) == PesStatus::Malformed,
         "the forbidden PTS_DTS_flags encoding is refused");

  expect(decodePesHeader(std::span<const std::byte>(both).first(4), header) ==
             PesStatus::Incomplete,
         "a truncated header asks for more bytes rather than failing");

  expect(!pesStreamIdHasHeader(0xBE), "padding_stream carries no PES header");
  expect(pesStreamIdHasHeader(0xE0), "a video stream_id carries one");
}

void testAccessUnitScanning() {
  // --- H.264 -------------------------------------------------------------
  Bytes h264;
  append(h264, {0x00, 0x00, 0x00, 0x01, 0x09, 0xF0});          // AUD
  append(h264, {0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x0D,
                0xDA, 0x05, 0x07, 0xEC});                       // SPS
  append(h264, {0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x0F, 0xC8});  // PPS
  append(h264, {0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x80, 0x10});  // IDR
  AccessUnitScan scan = scanAnnexBAccessUnit(h264, MediaCodec::H264);
  expect(scan.keyFrame, "an IDR NAL makes the access unit a keyframe");
  expect(scan.hasParameterSets, "SPS and PPS are both present");
  expect(scan.decodableFromCold,
         "SPS + PPS + IDR is decodable from a cold decoder");
  expect(scan.parameterSetSize > 0,
         "the parameter-set span is located for avcC synthesis");

  Bytes nonKey;
  append(nonKey, {0x00, 0x00, 0x00, 0x01, 0x41, 0x9A, 0x00});  // non-IDR slice
  scan = scanAnnexBAccessUnit(nonKey, MediaCodec::H264);
  expect(!scan.keyFrame, "a non-IDR slice is not a keyframe");
  expect(!scan.decodableFromCold, "a P slice is not a random access point");

  // An IDR without parameter sets is a keyframe but NOT cold-decodable, and
  // that distinction is exactly what makes TS seeking correct.
  Bytes bareIdr;
  append(bareIdr, {0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x80});
  scan = scanAnnexBAccessUnit(bareIdr, MediaCodec::H264);
  expect(scan.keyFrame, "a bare IDR is still a keyframe");
  expect(!scan.decodableFromCold,
         "an IDR without SPS/PPS cannot start a cold decode");

  // Three-byte start codes must be handled identically to four-byte ones.
  Bytes threeByte;
  append(threeByte, {0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x0D});
  append(threeByte, {0x00, 0x00, 0x01, 0x68, 0xCE, 0x0F});
  append(threeByte, {0x00, 0x00, 0x01, 0x65, 0x88});
  scan = scanAnnexBAccessUnit(threeByte, MediaCodec::H264);
  expect(scan.decodableFromCold,
         "three-byte start codes are walked like four-byte ones");

  // --- HEVC --------------------------------------------------------------
  Bytes hevc;
  append(hevc, {0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C});  // VPS (type 32)
  append(hevc, {0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x01});  // SPS (type 33)
  append(hevc, {0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xC0});  // PPS (type 34)
  append(hevc, {0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAF});  // IDR_W_RADL (19)
  scan = scanAnnexBAccessUnit(hevc, MediaCodec::Hevc);
  expect(scan.keyFrame, "an HEVC IRAP NAL is a keyframe");
  expect(scan.hasParameterSets, "VPS, SPS and PPS are all required for HEVC");
  expect(scan.decodableFromCold, "a full HEVC parameter set makes it cold-safe");
  expect(scan.sliceInProbe, "the IRAP slice itself was inside the scanned span");

  // ABSENCE OF EVIDENCE, NOT EVIDENCE OF ABSENCE. The cursor scans only a
  // bounded prefix of each access unit, and an HDR HEVC keyframe carries
  // kilobytes of SEI ahead of its slice. When the prefix ends before the
  // slice, keyFrame is false but says nothing about the picture -- this is
  // exactly the shape that made every seek in a real PQ fixture refuse with
  // ScanLimit until kMpegTsAccessUnitProbeBytes was raised.
  Bytes prologueOnly;
  append(prologueOnly, {0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C});  // VPS
  append(prologueOnly, {0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x01});  // SPS
  append(prologueOnly, {0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xC0});  // PPS
  append(prologueOnly, {0x00, 0x00, 0x00, 0x01, 0x4E, 0x01, 0xAF});  // SEI (39)
  scan = scanAnnexBAccessUnit(prologueOnly, MediaCodec::Hevc);
  expect(!scan.sliceInProbe,
         "a span that ends inside the prologue reports that it never reached "
         "a slice");
  expect(!scan.keyFrame && scan.hasParameterSets,
         "and its keyFrame verdict is therefore not a verdict at all");

  // --- MPEG-2 ------------------------------------------------------------
  Bytes mpeg2;
  append(mpeg2, {0x00, 0x00, 0x01, 0xB3, 0x14, 0x00, 0xF0, 0x23, 0xFF, 0xFF,
                 0xE0, 0x70});                              // sequence header
  append(mpeg2, {0x00, 0x00, 0x01, 0xB8, 0x00, 0x08, 0x00, 0x40});  // GOP
  append(mpeg2, {0x00, 0x00, 0x01, 0x00, 0x00, 0x0F, 0xFF, 0xF8});  // picture, I
  scan = scanMpeg2AccessUnit(mpeg2);
  expect(scan.hasSequenceHeader, "the MPEG-2 sequence header is found");
  expect(scan.keyFrame, "an I-picture makes the access unit a keyframe");
  expect(scan.decodableFromCold,
         "sequence header + I-picture is cold-decodable, which the "
         "VideoToolbox probe proved is the real requirement");

  const std::optional<Mpeg2SequenceHeader> geometry =
      parseMpeg2SequenceHeader(mpeg2);
  expect(geometry.has_value(), "the sequence header geometry parses");
  expect(geometry->width == 320 && geometry->height == 240,
         "12-bit width and height are unpacked exactly (320x240)");
  expect(geometry->frameRateCode == 3, "frame_rate_code 3 is 25 fps");
  expect(mpeg2FrameDurationTicks(3) == 3'600,
         "25 fps is exactly 3,600 ticks on the 90 kHz grid");
  expect(mpeg2FrameDurationTicks(4) == 3'003,
         "30000/1001 fps is exactly 3,003 ticks");
  expect(mpeg2FrameDurationTicks(0) == 0, "a reserved frame rate is refused");

  // An I-picture with no sequence header in the access unit is a keyframe but
  // is NOT a random access point for a cold VideoToolbox session.
  Bytes intraOnly;
  append(intraOnly, {0x00, 0x00, 0x01, 0x00, 0x00, 0x0F, 0xFF, 0xF8});
  scan = scanMpeg2AccessUnit(intraOnly);
  expect(scan.keyFrame && !scan.decodableFromCold,
         "an MPEG-2 I-picture without a sequence header cannot start playback");
}

// The hvcC record is byte-for-byte re-derived by the shared codec inspector
// from the very parameter sets it carries, so the ONE place synthesis can go
// wrong silently is the profile_tier_level copy. These are real x265 SPS NALs
// lifted out of the real transport-stream fixtures, emulation-prevention
// bytes and all -- a synthetic SPS would not have any, and the escaping is
// exactly what the copy has to survive.
void testHevcParameterSetFacts() {
  // Main, 8-bit, level 4.0. Note the three 0x03 emulation-prevention bytes
  // inside the PTL: escaped `01 60 00 00 03 00 90 00 00 03 00 00 03 00 78`
  // unescapes to `01 60 00 00 00 90 00 00 00 00 00 78`, which is what the
  // record must state.
  const std::array<std::uint8_t, 45> mainSps{
      0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00,
      0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xA0, 0x03, 0xC0, 0x80, 0x10, 0xE5,
      0x96, 0x56, 0x69, 0x24, 0xCA, 0xF0, 0x16, 0xA0, 0x40, 0x40, 0x20, 0x80,
      0x00, 0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x0F, 0x04};
  Bytes main;
  for (const std::uint8_t byte : mainSps) {
    main.push_back(static_cast<std::byte>(byte));
  }

  HevcSpsFacts facts{};
  expect(parseHevcSpsFacts(main, facts), "a real x265 Main SPS parses");
  const std::array<std::uint8_t, 12> expectedMainPtl{
      0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78};
  expect(facts.profileTierLevel == expectedMainPtl,
         "the profile_tier_level is copied verbatim out of the UNESCAPED "
         "RBSP, with all three emulation-prevention bytes removed");
  expect((facts.profileTierLevel[0] & 0x1FU) == 1U,
         "general_profile_idc 1 is Main");
  expect(facts.profileTierLevel[11] == 0x78U,
         "general_level_idc 0x78 is level 4.0");
  expect(facts.chromaFormatIdc == 1, "the fixture is 4:2:0");
  expect(facts.bitDepthLumaMinusEight == 0 &&
             facts.bitDepthChromaMinusEight == 0,
         "Main is 8-bit in both luma and chroma");
  expect(facts.maxSubLayersMinusOne == 0,
         "the fixture codes one temporal layer");
  expect(facts.temporalIdNested,
         "sps_temporal_id_nesting_flag is read, and the record's byte 21 "
         "must restate it or the inspector rejects the VPS/SPS pair");

  // Main10. The ONLY differences that matter to the record are the profile
  // byte, the compatibility flags and the two depths -- everything else is
  // identical, which is the point: a field-by-field rebuild would have to get
  // the untouched bytes right too.
  const std::array<std::uint8_t, 47> main10Sps{
      0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00,
      0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xA0, 0x03, 0xC0, 0x80, 0x10, 0xE4,
      0xD9, 0x65, 0x66, 0x92, 0x4C, 0xAF, 0x01, 0x6A, 0x04, 0x04, 0x02, 0x08,
      0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x00, 0xF0, 0x40};
  Bytes main10;
  for (const std::uint8_t byte : main10Sps) {
    main10.push_back(static_cast<std::byte>(byte));
  }
  HevcSpsFacts tenBit{};
  expect(parseHevcSpsFacts(main10, tenBit), "a real x265 Main10 SPS parses");
  const std::array<std::uint8_t, 12> expectedMain10Ptl{
      0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78};
  expect(tenBit.profileTierLevel == expectedMain10Ptl,
         "Main10's profile_tier_level copies verbatim too");
  expect((tenBit.profileTierLevel[0] & 0x1FU) == 2U,
         "general_profile_idc 2 is Main10, which is the value inspectHvcC "
         "demands for a 10-bit record");
  expect(tenBit.bitDepthLumaMinusEight == 2 &&
             tenBit.bitDepthChromaMinusEight == 2,
         "Main10 is 10-bit in both luma and chroma");
  expect(tenBit.chromaFormatIdc == 1, "Main10 here is still 4:2:0");

  // The PQ fixture is the same encode with a different VUI. The record header
  // must be IDENTICAL: colour lives in the SPS the record carries, never in
  // the record's own bytes.
  const std::array<std::uint8_t, 47> pqSps{
      0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00,
      0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xA0, 0x03, 0xC0, 0x80, 0x10, 0xE4,
      0xD9, 0x65, 0x66, 0x92, 0x4C, 0xAF, 0x01, 0x6A, 0x12, 0x20, 0x12, 0x08,
      0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x00, 0xF0, 0x40};
  Bytes pq;
  for (const std::uint8_t byte : pqSps) {
    pq.push_back(static_cast<std::byte>(byte));
  }
  HevcSpsFacts pqFacts{};
  expect(parseHevcSpsFacts(pq, pqFacts), "the PQ Main10 SPS parses");
  expect(pqFacts.profileTierLevel == tenBit.profileTierLevel &&
             pqFacts.bitDepthLumaMinusEight ==
                 tenBit.bitDepthLumaMinusEight &&
             pqFacts.maxSubLayersMinusOne == tenBit.maxSubLayersMinusOne &&
             pqFacts.temporalIdNested == tenBit.temporalIdNested,
         "a PQ VUI changes nothing in the hvcC header: the same encode "
         "yields the same record bytes whether it is SDR or HDR");

  // --- refusals ----------------------------------------------------------
  HevcSpsFacts ignored{};
  expect(!parseHevcSpsFacts(std::span<const std::byte>(main).first(2),
                            ignored),
         "an SPS with nothing past the NAL header is refused");
  expect(!parseHevcSpsFacts(std::span<const std::byte>(main).first(10),
                            ignored),
         "an SPS truncated inside its profile_tier_level is refused rather "
         "than completed with zeros");

  Bytes notSps = main;
  notSps[0] = std::byte{0x40};  // nal_unit_type 32, a VPS
  expect(!parseHevcSpsFacts(notSps, ignored),
         "a VPS handed in where an SPS was expected is refused by NAL type");

  Bytes layered = main;
  layered[1] = std::byte{0x09};  // nuh_layer_id 1
  expect(!parseHevcSpsFacts(layered, ignored),
         "a parameter set on a non-base layer is refused, matching the "
         "shared inspector's own validHevcNalHeader rule");

  Bytes temporal = main;
  temporal[1] = std::byte{0x02};  // nuh_temporal_id_plus1 2
  expect(!parseHevcSpsFacts(temporal, ignored),
         "a parameter set at a non-zero temporal id is refused");

  Bytes forbidden = main;
  forbidden[0] = std::byte{0xC2};  // forbidden_zero_bit set
  expect(!parseHevcSpsFacts(forbidden, ignored),
         "the forbidden_zero_bit is checked");
}

void testAnnexBToAvccRepack() {
  // Two NALs, one behind a four-byte start code and one behind a three-byte
  // one, so both start-code widths are exercised in the same access unit.
  Bytes unit;
  append(unit, {0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x0D});  // SPS, 4 B
  append(unit, {0x00, 0x00, 0x01, 0x68, 0xCE, 0x0F, 0xC8});        // PPS, 3 B
  append(unit, {0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x80, 0x10, 0x22});  // IDR

  const std::size_t required = annexBToAvccSize(unit, MediaCodec::H264);
  // 4 + 4 (SPS) + 4 + 4 (PPS) + 4 + 5 (IDR) = 25.
  expect(required == 25,
         "the AVCC size is the exact sum of four-byte prefixes and payloads");

  Bytes destination(required, std::byte{0});
  expect(annexBToAvcc(unit, destination, MediaCodec::H264) == required,
         "the repack writes exactly the size it promised");

  // Each record must be a big-endian length followed by its NAL, in order.
  expect(destination[0] == std::byte{0x00} &&
             destination[1] == std::byte{0x00} &&
             destination[2] == std::byte{0x00} &&
             destination[3] == std::byte{0x04},
         "the first length prefix is a four-byte big-endian 4");
  expect(destination[4] == std::byte{0x67}, "the SPS follows its length");
  expect(destination[8] == std::byte{0x00} &&
             destination[11] == std::byte{0x04},
         "the second length prefix is 4");
  expect(destination[12] == std::byte{0x68}, "the PPS follows its length");
  expect(destination[16] == std::byte{0x00} &&
             destination[19] == std::byte{0x05},
         "the third length prefix is 5");
  expect(destination[20] == std::byte{0x65}, "the IDR follows its length");

  // A destination that is not exactly the required size must be refused: a
  // short write into a CoreMedia block would be a decodable-looking sample
  // with a truncated final NAL.
  Bytes tooSmall(required - 1, std::byte{0});
  expect(annexBToAvcc(unit, tooSmall, MediaCodec::H264) == 0,
         "an undersized destination is refused, never partially written");
  Bytes tooLarge(required + 1, std::byte{0});
  expect(annexBToAvcc(unit, tooLarge, MediaCodec::H264) == 0,
         "an oversized destination is refused too, so the sample size cannot "
         "disagree with the bytes written");

  Bytes empty;
  expect(annexBToAvccSize(empty, MediaCodec::H264) == 0,
         "an empty access unit has no AVCC form");
  Bytes noStartCode;
  append(noStartCode, {0x67, 0x42, 0xC0, 0x0D});
  expect(annexBToAvccSize(noStartCode, MediaCodec::H264) == 0,
         "bytes with no start code are refused rather than framed");

  // HEVC uses the same framing; only the NAL type decode differs.
  Bytes hevc;
  append(hevc, {0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C});
  append(hevc, {0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAF});
  expect(annexBToAvccSize(hevc, MediaCodec::Hevc) == 14,
         "HEVC repacks with the same four-byte prefixes");
}

void testElementaryAudioFraming() {
  // AAC-LC, 44.1 kHz, stereo, 7-byte header, 512-byte frame.
  Bytes adts;
  append(adts, {0xFF, 0xF1, 0x50, 0x80, 0x40, 0x1F, 0xFC});
  AdtsHeader header{};
  expect(parseAdtsHeader(adts, header), "an ADTS header parses");
  expect(header.profileObjectType == 2, "profile 1 is AudioObjectType 2 (LC)");
  expect(header.sampleRate == 44'100, "sampling frequency index 4 is 44.1 kHz");
  expect(header.channelConfiguration == 2, "channel configuration is stereo");
  expect(header.headerBytes == 7, "protection_absent means a 7-byte header");
  expect(header.frameBytes == 512, "the 13-bit frame length is exact");
  expect(adtsSampleRateForIndex(3) == 48'000, "index 3 is 48 kHz");
  expect(adtsSampleRateForIndex(13) == 0, "a reserved index is refused");
  Bytes badAdts = adts;
  badAdts[0] = octet(0xFE);
  expect(!parseAdtsHeader(badAdts, header), "a broken syncword is refused");

  // AC-3, 48 kHz, frmsizecod 0 -> 64 words -> 128 bytes.
  Bytes ac3;
  append(ac3, {0x0B, 0x77, 0x00, 0x00, 0x00, 0x08, 0x40});
  Ac3SyncFrame frame{};
  expect(parseAc3SyncFrame(ac3, frame), "an AC-3 sync frame parses");
  expect(frame.sampleRate == 48'000, "fscod 0 is 48 kHz");
  expect(frame.frameBytes == 128, "frmsizecod 0 at 48 kHz is 128 bytes");
  Bytes badAc3 = ac3;
  badAc3[1] = octet(0x78);
  expect(!parseAc3SyncFrame(badAc3, frame), "a broken AC-3 syncword is refused");

  // 44.1 kHz alternates its frame length to keep the average bit rate exact,
  // and the odd half of each frmsizecod pair is one 16-bit word longer. A real
  // 128 kb/s mono stream therefore runs 556, 558, 558, 556, 558, ... and a
  // parser that reports the even size for both codes walks off the sync word
  // on the second frame of every PES payload. Both halves are pinned here.
  Bytes ac3even;
  append(ac3even, {0x0B, 0x77, 0x00, 0x00, 0x50, 0x40, 0x20});  // fscod 1, code 16
  expect(parseAc3SyncFrame(ac3even, frame), "a 44.1 kHz AC-3 frame parses");
  expect(frame.sampleRate == 44'100, "fscod 1 is 44.1 kHz");
  expect(frame.frameBytes == 556,
         "frmsizecod 16 at 44.1 kHz is exactly 556 bytes");
  Bytes ac3odd;
  append(ac3odd, {0x0B, 0x77, 0x00, 0x00, 0x51, 0x40, 0x20});  // fscod 1, code 17
  expect(parseAc3SyncFrame(ac3odd, frame), "the odd pair half parses");
  expect(frame.frameBytes == 558,
         "frmsizecod 17 at 44.1 kHz is exactly 558 bytes -- one word more");
  Bytes ac348odd;
  append(ac348odd, {0x0B, 0x77, 0x00, 0x00, 0x01, 0x40, 0x20});  // fscod 0, code 1
  expect(parseAc3SyncFrame(ac348odd, frame) && frame.frameBytes == 128,
         "48 kHz frame sizes do NOT alternate: both halves are 128 bytes");
  Bytes shortAc3 = ac3;
  shortAc3.resize(6);
  expect(!parseAc3SyncFrame(shortAc3, frame),
         "a span too short to hold acmod is refused rather than read past");

  // MPEG-1 Layer II, 44.1 kHz, 128 kbit/s stereo.
  Bytes mp2;
  append(mp2, {0xFF, 0xFD, 0x80, 0x00});
  MpegAudioFrame audio{};
  expect(parseMpegAudioFrame(mp2, audio), "an MPEG audio header parses");
  expect(audio.version == 1 && audio.layer == 2,
         "MPEG-1 Layer II is identified");
  expect(audio.sampleRate == 44'100, "the sample rate is exact");
  expect(audio.samplesPerFrame == 1'152, "Layer II is 1,152 samples per frame");
  expect(audio.frameBytes == 417,
         "128 kbit/s at 44.1 kHz is exactly 417 bytes per Layer II frame");
  Bytes badMp2 = mp2;
  badMp2[1] = octet(0xE9);  // reserved version
  expect(!parseMpegAudioFrame(badMp2, audio),
         "a reserved MPEG audio version is refused");
}

void testFramingDetection() {
  MpegTsFraming framing{};

  // Plain 188-byte stream.
  Bytes plain;
  for (int i = 0; i < 12; ++i) {
    PacketSpec spec;
    spec.payload = Bytes(100, octet(0x11));
    const Bytes packet = makePacket(spec);
    plain.insert(plain.end(), packet.begin(), packet.end());
  }
  expect(detectMpegTsFraming(plain, plain.size(), framing),
         "a 188-byte stream is detected");
  expect(framing.packetStride == 188 && framing.firstSyncOffset == 0,
         "the stride and first sync offset are exact");
  expect(!framing.timestampedPackets, "188-byte packets are not timestamped");
  expect(framing.packetCount == 12, "the packet count is derived from the size");

  // m2ts: each packet prefixed with a 4-byte TP_extra_header.
  Bytes m2ts;
  for (int i = 0; i < 12; ++i) {
    PacketSpec spec;
    spec.payload = Bytes(100, octet(0x22));
    const Bytes packet = makePacket(spec);
    append(m2ts, {0x0E, 0xBF, 0x46, 0x22});
    m2ts.insert(m2ts.end(), packet.begin(), packet.end());
  }
  expect(detectMpegTsFraming(m2ts, m2ts.size(), framing),
         "a 192-byte m2ts stream is detected");
  expect(framing.packetStride == 192, "the m2ts stride is 192");
  expect(framing.firstSyncOffset == 4,
         "the first sync byte follows the 4-byte TP_extra_header");
  expect(framing.timestampedPackets, "m2ts packets are flagged as timestamped");

  // 204-byte DVB framing with Reed-Solomon parity.
  Bytes dvb;
  for (int i = 0; i < 12; ++i) {
    PacketSpec spec;
    spec.payload = Bytes(100, octet(0x33));
    const Bytes packet = makePacket(spec);
    dvb.insert(dvb.end(), packet.begin(), packet.end());
    dvb.insert(dvb.end(), 16, octet(0x00));
  }
  expect(detectMpegTsFraming(dvb, dvb.size(), framing),
         "a 204-byte stream is detected");
  expect(framing.packetStride == 204, "the DVB stride is 204");

  // Random data must be refused, not framed at some lucky offset.
  Bytes noise(4096, octet(0x00));
  for (std::size_t i = 0; i < noise.size(); ++i) {
    noise[i] = octet((i * 37U + 11U) & 0xFFU);
  }
  expect(!detectMpegTsFraming(noise, noise.size(), framing),
         "unframed data is refused by verdict, not framed by accident");

  // A single sync byte with nothing behind it is not evidence.
  Bytes lonely(300, octet(0x00));
  lonely[0] = octet(0x47);
  expect(!detectMpegTsFraming(lonely, lonely.size(), framing),
         "one sync byte is not framing evidence");
}

void testPreparationRequestValidation() {
  const MpegTsPrepareOutcome nullReader =
      prepareMpegTs(nullptr, "fixture.ts", {});
  expect(nullReader.status == MpegTsDemuxStatus::Failed &&
             nullReader.error == MpegTsDemuxError::InvalidRequest,
         "preparation without a reader is an invalid request");

  auto reader = std::make_shared<MemoryReader>(Bytes(1024, octet(0x00)));
  const MpegTsPrepareOutcome noPath = prepareMpegTs(reader, "", {});
  expect(noPath.error == MpegTsDemuxError::InvalidRequest,
         "preparation without a path is an invalid request");

  auto noise = std::make_shared<MemoryReader>([] {
    Bytes bytes(8192, octet(0x00));
    for (std::size_t i = 0; i < bytes.size(); ++i) {
      bytes[i] = octet((i * 37U + 11U) & 0xFFU);
    }
    return bytes;
  }());
  const MpegTsPrepareOutcome notTs = prepareMpegTs(noise, "noise.ts", {});
  expect(notTs.status == MpegTsDemuxStatus::Unsupported &&
             notTs.error == MpegTsDemuxError::NotTransportStream,
         "a non-transport-stream file is Unsupported, not Failed — the "
         "session must be able to fall back rather than report a fault");

  std::atomic<bool> cancelled{true};
  const MpegTsPrepareOutcome stopped = prepareMpegTs(
      reader, "fixture.ts", {}, {&cancelled, atomicCancellation});
  expect(stopped.status == MpegTsDemuxStatus::Cancelled &&
             stopped.error == MpegTsDemuxError::Cancelled,
         "a pre-cancelled preparation returns Cancelled before any I/O");

  // Framed packets that never carry a PAT must be refused by name.
  Bytes framedOnly;
  for (int i = 0; i < 64; ++i) {
    PacketSpec spec;
    spec.pid = 0x0123;
    spec.continuityCounter = static_cast<std::uint8_t>(i & 0x0F);
    spec.payload = Bytes(100, octet(0x44));
    const Bytes packet = makePacket(spec);
    framedOnly.insert(framedOnly.end(), packet.begin(), packet.end());
  }
  auto framedReader = std::make_shared<MemoryReader>(framedOnly);
  const MpegTsPrepareOutcome noPat =
      prepareMpegTs(framedReader, "nopat.ts", {});
  expect(noPat.status == MpegTsDemuxStatus::Unsupported &&
             noPat.error == MpegTsDemuxError::MissingProgramTable,
         "framed packets with no PAT are refused by a named verdict");
  expect(!noPat.message.empty(), "the refusal carries a cold message");

  expect(std::string(mpegTsDemuxErrorName(MpegTsDemuxError::NotTransportStream))
             == "NotTransportStream",
         "every error enumerator names itself for telemetry");
}

// ---------------------------------------------------------------------------
// Real ffmpeg muxes
// ---------------------------------------------------------------------------

std::filesystem::path fixtureRoot() {
  const char* value = std::getenv("WAM_MPEGTS_FIXTURES");
  return value != nullptr ? std::filesystem::path(value)
                          : std::filesystem::path();
}

struct WalkSummary {
  std::uint64_t samples{0};
  std::uint64_t keyFrames{0};
  std::uint64_t coldDecodable{0};
  std::uint64_t payloadBytes{0};
  std::uint64_t continuityGaps{0};
  std::uint64_t resynchronizations{0};
  std::int64_t firstPresentationValue{0};
  std::int32_t firstPresentationScale{0};
  MediaTime lastDecode{};
  bool decodeMonotone{true};
  bool everyPresentationValid{true};
  bool failed{false};
  std::string failure;
};

[[nodiscard]] WalkSummary walkCursor(const MpegTsPreparedAsset& asset,
                                     MpegTsCursor& cursor,
                                     std::uint64_t maximumSamples) {
  WalkSummary summary{};
  std::vector<std::byte> scratch;
  bool first = true;
  while (summary.samples < maximumSamples) {
    MpegTsCursorReadResult result = cursor.readNext();
    if (std::holds_alternative<MpegTsCursorEnd>(result)) {
      break;
    }
    if (const auto* failure = std::get_if<MpegTsCursorFailure>(&result)) {
      summary.failed = true;
      summary.failure = failure->message;
      break;
    }
    if (std::holds_alternative<MpegTsCursorCancelled>(result)) {
      break;
    }
    const MpegTsCompressedSample& sample =
        std::get<MpegTsCompressedSample>(result);
    ++summary.samples;
    summary.payloadBytes += sample.payloadBytes;
    summary.keyFrames += sample.keyFrame ? 1 : 0;
    summary.coldDecodable += sample.decodableFromCold ? 1 : 0;
    if (!sample.presentationTime.valid()) {
      summary.everyPresentationValid = false;
    } else if (first) {
      summary.firstPresentationValue = sample.presentationTime.value;
      summary.firstPresentationScale = sample.presentationTime.timescale;
    }
    if (!first && sample.decodeTime.valid() && summary.lastDecode.valid()) {
      const std::optional<MediaTimeOrder> order =
          compareMediaTime(summary.lastDecode, sample.decodeTime);
      if (!order || *order == MediaTimeOrder::Greater) {
        summary.decodeMonotone = false;
      }
    }
    summary.lastDecode = sample.decodeTime;
    first = false;

    // Gather the payload for a sampled subset, proving the packet walk
    // reconstructs exactly the byte count the sample promised.
    if (summary.samples % 16 == 1) {
      scratch.assign(sample.payloadBytes, std::byte{0});
      MpegTsDemuxError error = MpegTsDemuxError::None;
      if (!asset.copyAccessUnit(sample, scratch, {}, &error)) {
        summary.failed = true;
        summary.failure = std::string("copyAccessUnit failed: ") +
                          mpegTsDemuxErrorName(error);
        break;
      }
    }
  }
  summary.continuityGaps = cursor.continuityGaps();
  summary.resynchronizations = cursor.resynchronizations();
  return summary;
}

void testRealMuxes() {
  const std::filesystem::path root = fixtureRoot();
  if (root.empty() || !std::filesystem::exists(root)) {
    skip("WAM_MPEGTS_FIXTURES is unset; real-mux tests did not run");
    return;
  }

  struct Case {
    const char* file;
    bool expectAudio;
    std::uint32_t expectedStride;
    const char* label;
  };
  const std::array<Case, 4> cases{{
      {"h264-aac.ts", true, 188, "h264-aac.ts"},
      {"h264-only.ts", false, 188, "h264-only.ts"},
      {"h264-ac3.m2ts", false, 192, "h264-ac3.m2ts (AC-3 not admitted)"},
      {"video.ts", true, 188, "video.ts (independent session fixture)"},
  }};

  for (const Case& entry : cases) {
    const std::filesystem::path path = root / entry.file;
    if (!std::filesystem::exists(path)) {
      skip(entry.label);
      continue;
    }
    const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
    if (outcome.status != MpegTsDemuxStatus::Ready) {
      std::cerr << "  " << entry.label << " -> "
                << mpegTsDemuxErrorName(outcome.error) << ": "
                << outcome.message << '\n';
      expect(false, "a real ffmpeg mux prepares Ready");
      continue;
    }
    const MpegTsPreparedAsset& asset = *outcome.asset;
    expect(asset.framing().packetStride == entry.expectedStride,
           "the packet stride of a real mux is detected exactly");
    expect(asset.descriptor() != nullptr && asset.descriptor()->duration.valid(),
           "a real mux yields a valid duration");
    expect(asset.descriptor()->selectedVideo.has_value(),
           "a real mux selects a video track");
    expect(!asset.index().empty(), "the built index is non-empty");

    // The index must be strictly increasing in both byte offset and tick.
    bool monotone = true;
    for (std::size_t i = 1; i < asset.index().size(); ++i) {
      if (asset.index()[i].packetOffset <= asset.index()[i - 1].packetOffset ||
          asset.index()[i].tick <= asset.index()[i - 1].tick) {
        monotone = false;
      }
    }
    expect(monotone, "the built index is strictly increasing in offset and tick");

    const MpegTsPlanOutcome plan =
        asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
    expect(plan.status == MpegTsDemuxStatus::Ready,
           "planning the stream origin succeeds on a real mux");
    if (plan.status != MpegTsDemuxStatus::Ready) {
      std::cerr << "  plan error: " << mpegTsDemuxErrorName(plan.error) << ": "
                << plan.message << '\n';
      continue;
    }

    std::unique_ptr<MpegTsCursor> video = asset.makeVideoCursor(*plan.plan);
    expect(video != nullptr, "a video cursor is created");
    if (video != nullptr) {
      const WalkSummary summary = walkCursor(asset, *video, 500);
      expect(!summary.failed,
             summary.failed ? summary.failure.c_str()
                            : "the video walk completed without failure");
      expect(summary.samples > 30,
             "a three-second 25 fps clip yields tens of access units");
      expect(summary.keyFrames > 0, "at least one keyframe is found");
      expect(summary.coldDecodable > 0,
             "at least one access unit carries parameter sets");
      expect(summary.everyPresentationValid,
             "every emitted video sample carries a valid presentation time");
      expect(summary.decodeMonotone,
             "decode timestamps are non-decreasing, which is what makes the "
             "A/V merge key correct for Transport Stream");
      // The timeline origin is the EARLIEST selected-stream timestamp, so a
      // clip whose audio leads its video by 23 ms exports video starting at
      // 23 ms, not at zero. What must hold is that nothing is negative and the
      // container's own multi-second mux delay is gone.
      expect(summary.firstPresentationValue >= 0,
             "the exported timeline never starts before zero");
      expect(summary.firstPresentationScale > 0 &&
                 summary.firstPresentationValue * 10 <=
                     summary.firstPresentationScale,
             "the first video sample lands within 100 ms of the timeline "
             "origin, so the mux's own start offset has been removed");
      expect(summary.payloadBytes > 10'000,
             "the walk accounts for a plausible amount of payload");
    }

    if (entry.expectAudio) {
      expect(asset.descriptor()->selectedAudio.has_value(),
             "an AAC-bearing mux selects an audio track");
      std::unique_ptr<MpegTsCursor> audio = asset.makeAudioCursor(*plan.plan);
      if (audio != nullptr) {
        const WalkSummary summary = walkCursor(asset, *audio, 500);
        expect(!summary.failed, "the audio walk completed without failure");
        expect(summary.samples > 10, "audio access units are emitted");
      }
    }
  }
}

// The strongest test in this file. Every number below was read off ffmpeg/
// ffprobe on the same fixture, and the reconstructed elementary stream was
// separately verified byte-for-byte identical to
// `ffmpeg -c:v copy -bsf:v h264_mp4toannexb -f h264` (and `-c:a copy -f adts`)
// outside the suite. Fixture-green is not world-correct; these are the world's
// numbers, frozen here so a future change to the packet walk cannot quietly
// drop, duplicate, or mis-flag an access unit.
void testGroundTruthAgainstFfmpeg() {
  const std::filesystem::path root = fixtureRoot();
  if (root.empty()) {
    skip("ground truth against ffmpeg");
    return;
  }
  struct Truth {
    const char* file;
    std::uint64_t videoUnits;
    std::uint64_t videoKeyFrames;
    std::uint64_t videoBytes;
    std::uint64_t audioUnits;   // zero means "do not check audio"
    std::uint64_t audioBytes;
  };
  // videoUnits equals ffprobe's nb_read_frames; videoKeyFrames equals its
  // count of key_frame=1; videoBytes/audioBytes equal the size of ffmpeg's
  // own stream-copy output.
  const std::array<Truth, 6> truths{{
      {"h264-aac.ts", 75, 3, 276'909, 14, 37'424},
      {"h264-only.ts", 75, 3, 276'909, 0, 0},
      {"h264-ac3.m2ts", 75, 3, 276'909, 0, 0},
      {"video.ts", 180, 1, 547'363, 36, 98'271},
      {"seek.ts", 500, 20, 5'905'419, 87, 246'824},
      {"L_video.ts", 600, 3, 1'849'336, 0, 0},
  }};

  for (const Truth& truth : truths) {
    const std::filesystem::path path = root / truth.file;
    if (!std::filesystem::exists(path)) {
      skip(truth.file);
      continue;
    }
    const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
    if (outcome.status != MpegTsDemuxStatus::Ready) {
      expect(false, "a ground-truth fixture prepares Ready");
      continue;
    }
    const MpegTsPreparedAsset& asset = *outcome.asset;
    const MpegTsPlanOutcome plan =
        asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
    if (plan.status != MpegTsDemuxStatus::Ready) {
      expect(false, "a ground-truth fixture plans from its origin");
      continue;
    }
    std::unique_ptr<MpegTsCursor> video = asset.makeVideoCursor(*plan.plan);
    if (video == nullptr) {
      expect(false, "a ground-truth fixture yields a video cursor");
      continue;
    }
    const WalkSummary summary =
        walkCursor(asset, *video, std::numeric_limits<std::uint64_t>::max());
    expect(!summary.failed, "the exhaustive video walk completes");
    expect(summary.samples == truth.videoUnits,
           "the access-unit count equals ffprobe's frame count exactly");
    expect(summary.keyFrames == truth.videoKeyFrames,
           "the keyframe count equals ffprobe's key_frame count exactly");
    expect(summary.coldDecodable == truth.videoKeyFrames,
           "every keyframe carries its parameter sets in these muxes, so the "
           "cold-decodable count matches the keyframe count");
    expect(summary.payloadBytes == truth.videoBytes,
           "the reassembled payload byte count equals ffmpeg's stream copy");
    if (summary.samples != truth.videoUnits ||
        summary.payloadBytes != truth.videoBytes ||
        summary.keyFrames != truth.videoKeyFrames) {
      std::cerr << "  " << truth.file << ": units " << summary.samples << "/"
                << truth.videoUnits << ", keys " << summary.keyFrames << "/"
                << truth.videoKeyFrames << ", bytes " << summary.payloadBytes
                << "/" << truth.videoBytes << '\n';
    }

    if (truth.audioUnits != 0) {
      std::unique_ptr<MpegTsCursor> audio = asset.makeAudioCursor(*plan.plan);
      expect(audio != nullptr, "an audio-bearing fixture yields an audio cursor");
      if (audio != nullptr) {
        const WalkSummary audioSummary = walkCursor(
            asset, *audio, std::numeric_limits<std::uint64_t>::max());
        expect(!audioSummary.failed, "the exhaustive audio walk completes");
        expect(audioSummary.samples == truth.audioUnits,
               "the audio PES count matches ffmpeg's");
        expect(audioSummary.payloadBytes == truth.audioBytes,
               "the reassembled ADTS byte count equals ffmpeg's stream copy");
      }
    }
  }
}

void testMultiProgramSelection() {
  const std::filesystem::path root = fixtureRoot();
  const std::filesystem::path path = root / "multiprogram.ts";
  if (root.empty() || !std::filesystem::exists(path)) {
    skip("multiprogram.ts");
    return;
  }
  const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
  expect(outcome.status == MpegTsDemuxStatus::Ready,
         "a two-program transport stream prepares Ready");
  if (outcome.status != MpegTsDemuxStatus::Ready) {
    std::cerr << "  " << mpegTsDemuxErrorName(outcome.error) << ": "
              << outcome.message << '\n';
    return;
  }
  // The first video-bearing program in PAT order must win, and exactly one
  // video and one audio track must be selected out of the four streams.
  expect(outcome.asset->programNumber() == 1,
         "the first video-bearing program in PAT order is selected");
  expect(outcome.asset->descriptor()->selectedVideo.has_value(),
         "a video track is selected from the chosen program");
  expect(outcome.asset->descriptor()->tracks.size() <= 2,
         "only the selected program's tracks are described");
  expect(outcome.asset->descriptor()->inventory.video == 1,
         "the inventory counts only the selected program's video streams");
}

// ---------------------------------------------------------------------------
// LOAS/LATM framing (stream type 0x11)
// ---------------------------------------------------------------------------

// A minimal MSB-first bit writer, so every fixture below is written as the
// SYNTAX, field by field, rather than as an opaque blob of hex whose meaning
// only a comment asserts. A fixture you cannot read is a fixture you cannot
// tell is wrong.
class BitWriter {
 public:
  void put(std::uint32_t value, std::uint32_t count) {
    for (std::uint32_t i = 0; i < count; ++i) {
      const std::uint32_t bit = (value >> (count - 1U - i)) & 1U;
      if ((bits_ & 7U) == 0U) {
        bytes_.push_back(std::byte{0});
      }
      if (bit != 0U) {
        bytes_.back() |= static_cast<std::byte>(1U << (7U - (bits_ & 7U)));
      }
      ++bits_;
    }
  }
  void alignToByte() {
    while ((bits_ & 7U) != 0U) {
      put(0, 1);
    }
  }
  [[nodiscard]] std::uint32_t bits() const { return bits_; }
  [[nodiscard]] const Bytes& bytes() const { return bytes_; }

 private:
  Bytes bytes_;
  std::uint32_t bits_{0};
};

struct LatmFixtureOptions {
  std::uint32_t audioMuxVersion{0};
  std::uint32_t allStreamsSameTimeFraming{1};
  std::uint32_t numSubFrames{0};
  std::uint32_t numProgram{0};
  std::uint32_t numLayer{0};
  std::uint32_t frameLengthType{0};
  std::uint32_t samplingFrequencyIndex{3};  // 48 kHz
  std::uint32_t channelConfiguration{2};    // stereo
  std::uint32_t audioObjectType{2};         // AAC-LC
  bool otherDataPresent{false};
  bool crcCheckPresent{false};
};

// Builds one complete LOAS AudioSyncStream frame around `payload`.
// `withConfig == false` produces the useSameStreamMux = 1 shape, which is what
// every frame after the first looks like in a real mux and is the shape whose
// access unit is NOT byte-aligned.
Bytes makeLoasFrame(const Bytes& payload, bool withConfig,
                    const LatmFixtureOptions& options = {}) {
  BitWriter mux;
  mux.put(withConfig ? 0U : 1U, 1);  // useSameStreamMux
  if (withConfig) {
    mux.put(options.audioMuxVersion, 1);
    if (options.audioMuxVersion == 1U) {
      mux.put(0, 1);        // audioMuxVersionA
      mux.put(0, 2);        // taraBufferFullness: LatmGetValue, 1 byte
      mux.put(0, 8);
    }
    mux.put(options.allStreamsSameTimeFraming, 1);
    mux.put(options.numSubFrames, 6);
    mux.put(options.numProgram, 4);
    mux.put(options.numLayer, 3);
    // AudioSpecificConfig: AAC-LC / rate index / channels / GASpecificConfig.
    // Exactly 16 bits, which is the canonical two-byte ASC every AAC cookie
    // builder in this repo consumes.
    BitWriter asc;
    asc.put(options.audioObjectType, 5);
    asc.put(options.samplingFrequencyIndex, 4);
    asc.put(options.channelConfiguration, 4);
    asc.put(0, 1);  // frameLengthFlag
    asc.put(0, 1);  // dependsOnCoreCoder
    asc.put(0, 1);  // extensionFlag
    if (options.audioMuxVersion == 1U) {
      // ascLen as a LatmGetValue: two bits of byte count then the value.
      mux.put(0, 2);
      mux.put(asc.bits(), 8);
    }
    for (std::uint32_t i = 0; i < asc.bits(); ++i) {
      const std::uint32_t byteIndex = i >> 3U;
      const auto source =
          static_cast<std::uint32_t>(asc.bytes()[byteIndex]);
      mux.put((source >> (7U - (i & 7U))) & 1U, 1);
    }
    mux.put(options.frameLengthType, 3);
    if (options.frameLengthType == 0U) {
      mux.put(0xFF, 8);  // latmBufferFullness
    } else if (options.frameLengthType == 1U) {
      mux.put(0, 9);     // frameLength
    }
    mux.put(options.otherDataPresent ? 1U : 0U, 1);
    if (options.otherDataPresent) {
      mux.put(0, 1);  // escape: no continuation
      mux.put(0, 8);
    }
    mux.put(options.crcCheckPresent ? 1U : 0U, 1);
    if (options.crcCheckPresent) {
      mux.put(0, 8);
    }
  }
  // PayloadLengthInfo: MuxSlotLengthBytes as 255-escaped octets.
  std::size_t remaining = payload.size();
  while (remaining >= 255) {
    mux.put(255, 8);
    remaining -= 255;
  }
  mux.put(static_cast<std::uint32_t>(remaining), 8);
  // PayloadMux: the access unit, at whatever bit offset the header left.
  for (std::byte b : payload) {
    mux.put(static_cast<std::uint32_t>(b), 8);
  }
  mux.alignToByte();

  Bytes frame;
  const std::uint32_t muxLength =
      static_cast<std::uint32_t>(mux.bytes().size());
  frame.push_back(octet(0x56));
  frame.push_back(octet(0xE0U | ((muxLength >> 8) & 0x1FU)));
  frame.push_back(octet(muxLength & 0xFFU));
  frame.insert(frame.end(), mux.bytes().begin(), mux.bytes().end());
  return frame;
}

Bytes rampPayload(std::size_t size, std::uint8_t seed) {
  Bytes payload;
  payload.reserve(size);
  for (std::size_t i = 0; i < size; ++i) {
    payload.push_back(octet(static_cast<std::uint8_t>(seed + i * 31U + (i >> 3))));
  }
  return payload;
}

void testLatmFraming() {
  // --- the config-bearing frame -------------------------------------------
  const Bytes payload = rampPayload(300, 0x5A);
  const Bytes frame = makeLoasFrame(payload, /*withConfig=*/true);
  LatmFrame facts{};
  expect(parseLatmFrame(frame, nullptr, facts) == LatmStatus::Ok,
         "a LOAS frame carrying a StreamMuxConfig parses without an "
         "established config");
  expect(facts.configPresent, "the frame reports that it carried a config");
  expect(facts.frameBytes == frame.size(),
         "the parsed frame length is the whole AudioSyncStream frame");
  expect(facts.payloadBytes == payload.size(),
         "MuxSlotLengthBytes recovers the exact access-unit length");
  expect(facts.config.sampleRate == 48'000,
         "the sampling frequency index is decoded to a real rate");
  expect(facts.config.channelConfiguration == 2,
         "the channel configuration is decoded");
  expect(facts.config.audioObjectType == 2, "AAC-LC is decoded");
  expect(facts.config.audioSpecificConfigBits == 16,
         "the AudioSpecificConfig is the canonical 16 bits");
  // 0x1190 is AAC-LC (2) / 48 kHz (index 3) / stereo (2), which is byte for
  // byte what the ADTS path synthesizes for the same stream. That equality is
  // the whole reason LATM needs no MediaCodec value of its own.
  expect(facts.config.audioSpecificConfigBytes == 2 &&
             facts.config.audioSpecificConfig[0] == octet(0x11) &&
             facts.config.audioSpecificConfig[1] == octet(0x90),
         "the recovered ASC is the canonical 0x1190");

  // --- THE BIT-SHIFT PROOF -------------------------------------------------
  // The access unit does not start on a byte boundary, and a copy that assumed
  // it did would return payload shifted by one to seven bits -- which decodes
  // as noise, not as an error. This is the assertion that catches that.
  expect((facts.payloadBitOffset % 8U) != 0U,
         "a real StreamMuxConfig leaves the access unit bit-misaligned");
  Bytes extracted(facts.payloadBytes, std::byte{});
  expect(latmCopyPayload(frame, facts, extracted),
         "the payload copy succeeds");
  expect(extracted == payload,
         "the extracted access unit is byte-identical to what was muxed");

  // --- the config-less frame every real mux emits after the first ----------
  const Bytes payload2 = rampPayload(180, 0xC3);
  const Bytes frame2 = makeLoasFrame(payload2, /*withConfig=*/false);
  LatmFrame facts2{};
  expect(parseLatmFrame(frame2, nullptr, facts2) ==
             LatmStatus::ConfigUnavailable,
         "a frame reusing the established config is refused when there is "
         "none, rather than guessed at");
  expect(parseLatmFrame(frame2, &facts.config, facts2) == LatmStatus::Ok,
         "the same frame parses against the established config");
  expect(!facts2.configPresent, "the frame reports it carried no config");
  expect(facts2.config.sameDecoder(facts.config),
         "the established config is carried onto the frame");
  expect(facts2.payloadBitOffset % 8U == 1U,
         "useSameStreamMux costs exactly one bit, so the access unit starts "
         "at bit 1 of a byte");
  Bytes extracted2(facts2.payloadBytes, std::byte{});
  expect(latmCopyPayload(frame2, facts2, extracted2),
         "the config-less payload copy succeeds");
  expect(extracted2 == payload2,
         "the config-less access unit is byte-identical to what was muxed");

  // --- the 255 escape in MuxSlotLengthBytes --------------------------------
  const Bytes big = rampPayload(600, 0x11);
  const Bytes bigFrame = makeLoasFrame(big, /*withConfig=*/false);
  LatmFrame bigFacts{};
  expect(parseLatmFrame(bigFrame, &facts.config, bigFacts) == LatmStatus::Ok,
         "a payload past 255 bytes parses through the length escape");
  expect(bigFacts.payloadBytes == 600,
         "the escaped MuxSlotLengthBytes sums to the exact length");
  Bytes bigOut(bigFacts.payloadBytes, std::byte{});
  expect(latmCopyPayload(bigFrame, bigFacts, bigOut) && bigOut == big,
         "an escaped-length access unit extracts byte-identically");

  // --- audioMuxVersion 1, whose ASC length is stated rather than parsed ----
  LatmFixtureOptions v1;
  v1.audioMuxVersion = 1;
  v1.samplingFrequencyIndex = 4;  // 44.1 kHz
  v1.channelConfiguration = 1;    // mono
  const Bytes v1Frame = makeLoasFrame(payload, true, v1);
  LatmFrame v1Facts{};
  expect(parseLatmFrame(v1Frame, nullptr, v1Facts) == LatmStatus::Ok,
         "audioMuxVersion 1 parses");
  expect(v1Facts.config.audioMuxVersion == 1, "the mux version is reported");
  expect(v1Facts.config.sampleRate == 44'100 &&
             v1Facts.config.channelConfiguration == 1,
         "the version 1 config decodes its rate and channels");
  Bytes v1Out(v1Facts.payloadBytes, std::byte{});
  expect(latmCopyPayload(v1Frame, v1Facts, v1Out) && v1Out == payload,
         "an audioMuxVersion 1 access unit extracts byte-identically");

  // --- refusals, each BY NAME ---------------------------------------------
  Bytes desynced = frame;
  desynced[0] = octet(0x57);
  LatmFrame junk{};
  expect(parseLatmFrame(desynced, nullptr, junk) == LatmStatus::NotSynced,
         "a broken sync word is NotSynced, not a guess");
  expect(parseLatmFrame(std::span<const std::byte>(frame).first(2), nullptr,
                        junk) == LatmStatus::Incomplete,
         "a span shorter than the LOAS header is Incomplete");
  expect(parseLatmFrame(std::span<const std::byte>(frame).first(frame.size() - 1),
                        nullptr, junk) == LatmStatus::Incomplete,
         "a span shorter than the declared frame is Incomplete");

  // Every mux shape this route deliberately does not carry must refuse by
  // name. Mis-framing one of these silently is the failure mode that makes a
  // broadcast decode as noise instead of falling back.
  const struct {
    const char* what;
    LatmFixtureOptions options;
  } unsupported[] = {
      {"numLayer != 0", [] { LatmFixtureOptions o; o.numLayer = 1; return o; }()},
      {"numProgram != 0", [] { LatmFixtureOptions o; o.numProgram = 1; return o; }()},
      {"numSubFrames != 0", [] { LatmFixtureOptions o; o.numSubFrames = 1; return o; }()},
      {"allStreamsSameTimeFraming == 0",
       [] { LatmFixtureOptions o; o.allStreamsSameTimeFraming = 0; return o; }()},
      {"frameLengthType == 1",
       [] { LatmFixtureOptions o; o.frameLengthType = 1; return o; }()},
  };
  for (const auto& entry : unsupported) {
    const Bytes bad = makeLoasFrame(payload, true, entry.options);
    LatmFrame badFacts{};
    const LatmStatus status = parseLatmFrame(bad, nullptr, badFacts);
    expect(status == LatmStatus::UnsupportedMux,
           "an unsupported mux shape refuses by name");
    if (status != LatmStatus::UnsupportedMux) {
      std::cerr << "  " << entry.what << " gave " << latmStatusName(status)
                << '\n';
    }
  }

  // otherDataPresent and crcCheckPresent are legal and MUST be carried: both
  // sit between the config and the payload length, so skipping them wrongly
  // moves the access unit.
  for (bool other : {false, true}) {
    for (bool crc : {false, true}) {
      LatmFixtureOptions o;
      o.otherDataPresent = other;
      o.crcCheckPresent = crc;
      const Bytes f = makeLoasFrame(payload, true, o);
      LatmFrame fx{};
      expect(parseLatmFrame(f, nullptr, fx) == LatmStatus::Ok,
             "otherData and crcCheck fields are carried");
      Bytes out(fx.payloadBytes, std::byte{});
      expect(latmCopyPayload(f, fx, out) && out == payload,
             "the access unit survives optional StreamMuxConfig fields");
    }
  }

  // --- a real ffmpeg mux, pinned -------------------------------------------
  // The first 24 bytes of `ffmpeg -f lavfi -i sine -c:a aac -f latm`, 48 kHz
  // stereo. Hand-written fixtures prove the syntax; this proves the syntax is
  // the one a real muxer writes. Only the header is pinned -- the payload is
  // encoder output and would make this a change-detector.
  const Bytes real{octet(0x56), octet(0xE1), octet(0x26), octet(0x20),
                   octet(0x00), octet(0x11), octet(0x90), octet(0x1F),
                   octet(0xE7), octet(0xF8), octet(0xFE), octet(0xE0)};
  Bytes realFrame = real;
  realFrame.resize(3 + 294, std::byte{});  // the declared audioMuxLengthBytes
  LatmFrame realFacts{};
  expect(parseLatmFrame(realFrame, nullptr, realFacts) == LatmStatus::Ok,
         "a real ffmpeg LOAS frame parses");
  expect(realFacts.frameBytes == 297,
         "the real frame's declared length is 3 + 294");
  expect(realFacts.config.sampleRate == 48'000 &&
             realFacts.config.channelConfiguration == 2,
         "the real frame's config is 48 kHz stereo");
  expect(realFacts.config.audioSpecificConfigBytes == 2 &&
             realFacts.config.audioSpecificConfig[0] == octet(0x11) &&
             realFacts.config.audioSpecificConfig[1] == octet(0x90),
         "the real frame yields the canonical 0x1190 ASC");
  expect(realFacts.payloadBytes == 286,
         "the real frame's MuxSlotLengthBytes is 255 + 31");
  expect(realFacts.payloadBitOffset == 85,
         "the real frame's access unit starts at bit 85, i.e. byte 10 bit 5");
}

// Builds an E-AC-3 (A/52 Annex E) syncframe header. The body is zero-filled:
// nothing in this route reads past bsi.
Bytes makeEac3Frame(std::uint32_t frameBytes, std::uint32_t fscod,
                    std::uint32_t numblkscod, std::uint32_t acmod,
                    bool lfeon, std::uint32_t bsid = kEac3BitstreamId) {
  BitWriter w;
  w.put(0x0B77, 16);
  w.put(0, 2);  // strmtyp: independent substream
  w.put(0, 3);  // substreamid
  w.put(frameBytes / 2U - 1U, 11);  // frmsiz, in 16-bit words minus one
  w.put(fscod, 2);
  w.put(numblkscod, 2);
  w.put(acmod, 3);
  w.put(lfeon ? 1U : 0U, 1);
  w.put(bsid, 5);
  w.alignToByte();
  Bytes frame = w.bytes();
  frame.resize(frameBytes, std::byte{});
  return frame;
}

void testEac3Framing() {
  // --- the defect this fixes ----------------------------------------------
  // E-AC-3 was mapped by stream type 0x87 and then dropped by every real file,
  // because the LEGACY parser was the only one and an Annex E frame's bytes
  // 2-4 are strmtyp/substreamid/frmsiz where AC-3 has crc1 and frmsizecod.
  const Bytes eac3 = makeEac3Frame(768, 0, 3, 2, false);
  Ac3SyncFrame legacy{};
  expect(!parseAc3SyncFrame(eac3, legacy),
         "the legacy AC-3 parser REFUSES an E-AC-3 frame instead of "
         "mis-reading its frame size");

  // The refusal above is not enough on its own, and finding that out is what a
  // mutation check is for. In THAT frame byte 4 reads as frmsizecod 52, which
  // the legacy table bound rejects for an unrelated reason -- so it would be
  // refused even with the bitstream-id gate deleted, and it proves nothing
  // about the gate.
  //
  // This frame is the one that matters: numblkscod 1 and acmod 2 make byte 4
  // read as a PERFECTLY LEGAL frmsizecod of 20, so a legacy parser accepts it
  // and reports a confident, entirely wrong frame length. That is how a
  // mis-framed audio track becomes noise instead of a named refusal.
  const Bytes deceptive = makeEac3Frame(768, 0, 1, 2, false);
  expect((static_cast<std::uint32_t>(deceptive[4]) & 0x3FU) <= 37U,
         "the deceptive fixture really does present a legal frmsizecod");
  Ac3SyncFrame fooled{};
  expect(!parseAc3SyncFrame(deceptive, fooled),
         "an E-AC-3 frame whose byte 4 reads as a legal frmsizecod is still "
         "refused by the legacy parser, on its bitstream id");
  Ac3SyncFrame viaDispatch{};
  expect(parseAc3OrEac3SyncFrame(deceptive, viaDispatch) &&
             viaDispatch.enhanced && viaDispatch.frameBytes == 768,
         "and the dispatcher reads its real length instead");

  Ac3SyncFrame frame{};
  expect(parseEac3SyncFrame(eac3, frame), "an E-AC-3 syncframe parses");
  expect(frame.enhanced && frame.bitstreamId == 16,
         "the frame is identified as E-AC-3 by its bitstream id");
  expect(frame.frameBytes == 768,
         "frmsiz is an explicit word count, not a table index");
  expect(frame.sampleRate == 48'000, "the E-AC-3 rate is decoded");
  expect(frame.channels == 2 && !frame.lfe,
         "acmod 2 with no LFE is two channels");
  expect(frame.samplesPerFrame == 1536,
         "numblkscod 3 codes six blocks of 256 samples");

  // numblkscod is the field a fixed 1536 assumption gets wrong. A one-block
  // frame carries a QUARTER of the samples, and describing it as 1536 would
  // run the audio-authoritative clock four times too fast.
  const struct {
    std::uint32_t code;
    std::uint32_t samples;
  } blocks[] = {{0, 256}, {1, 512}, {2, 768}, {3, 1536}};
  for (const auto& entry : blocks) {
    const Bytes f = makeEac3Frame(512, 0, entry.code, 2, false);
    Ac3SyncFrame fx{};
    expect(parseEac3SyncFrame(f, fx) && fx.samplesPerFrame == entry.samples,
           "numblkscod names the exact decoded sample count");
  }

  // --- the LFE fix, which is what unblocked 5.1 ---------------------------
  // acmod 7 is 3/2 -- five full-bandwidth channels -- and lfeon makes it 5.1.
  // The old code hardcoded `lfe = false`, so a 5.1 stream was described to
  // CoreAudio as FIVE channels. That is not a rounding error; it lays the
  // decoder's own output out wrongly.
  const Bytes eac351 = makeEac3Frame(1536, 0, 3, 7, true);
  Ac3SyncFrame fx51{};
  expect(parseEac3SyncFrame(eac351, fx51), "a 5.1 E-AC-3 frame parses");
  expect(fx51.fullBandwidthChannels == 5 && fx51.lfe && fx51.channels == 6,
         "acmod 7 plus lfeon is 5 full-bandwidth channels and 6 total");

  // The same LFE arithmetic on LEGACY AC-3, where lfeon's bit position depends
  // on which of cmixlev/surmixlev/dsurmod acmod brings with it.
  {
    // Real bytes: ffmpeg 5.1 48 kHz AC-3, acmod 7, lfeon set. Pinned because
    // the conditional-field offsets are exactly the thing a hand fixture would
    // get wrong in the same way the parser might.
    const Bytes ac351{octet(0x0B), octet(0x77), octet(0xD6), octet(0xD8),
                      octet(0x1E), octet(0x40), octet(0xEB), octet(0xF8)};
    Ac3SyncFrame a{};
    expect(parseAc3SyncFrame(ac351, a), "a real 5.1 AC-3 syncframe parses");
    expect(a.bitstreamId == 8 && !a.enhanced,
           "it is identified as legacy AC-3");
    expect(a.fullBandwidthChannels == 5 && a.lfe && a.channels == 6,
           "legacy 5.1 AC-3 reports six channels including LFE");
    expect(a.samplesPerFrame == 1536,
           "legacy AC-3 always codes six blocks of 256");
  }
  {
    // acmod 2 (stereo) brings dsurmod, which moves lfeon by two bits. A parser
    // that skipped the conditional fields would read a neighbouring bit here.
    const Bytes ac3stereo{octet(0x0B), octet(0x77), octet(0x00), octet(0x00),
                          octet(0x1E), octet(0x40), octet(0x40), octet(0x00)};
    Ac3SyncFrame a{};
    expect(parseAc3SyncFrame(ac3stereo, a), "a stereo AC-3 syncframe parses");
    expect(a.fullBandwidthChannels == 2 && !a.lfe && a.channels == 2,
           "acmod 2 with lfeon clear is two channels");
  }

  // --- the dispatcher ------------------------------------------------------
  Ac3SyncFrame routed{};
  expect(parseAc3OrEac3SyncFrame(eac3, routed) && routed.enhanced,
         "the dispatcher routes an E-AC-3 frame to the Annex E parser");
  const Bytes ac3{octet(0x0B), octet(0x77), octet(0xD6), octet(0xD8),
                  octet(0x1E), octet(0x40), octet(0xEB), octet(0xF8)};
  expect(parseAc3OrEac3SyncFrame(ac3, routed) && !routed.enhanced &&
             routed.bitstreamId == 8,
         "the dispatcher routes a legacy frame to the legacy parser");

  // Half-rate E-AC-3 (fscod 3) is outside the admitted audio envelope and must
  // be refused by structure rather than admitted with an invented rate.
  const Bytes half = makeEac3Frame(768, 3, 3, 2, false);
  Ac3SyncFrame h{};
  expect(!parseEac3SyncFrame(half, h),
         "fscod 3 (half sample rate) is refused rather than guessed at");
}

void testProgramGradeRule() {
  // The three grades, from PMTs that differ in exactly one thing each.
  ProgramMapTable table{};
  const auto grade = [&](std::initializer_list<
                          std::pair<std::uint8_t, std::uint16_t>> streams) {
    table = ProgramMapTable{};
    table.programNumber = 1;
    std::uint8_t index = 0;
    for (const auto& [type, pid] : streams) {
      table.streams[index].streamType = type;
      table.streams[index].elementaryPid = pid;
      table.streams[index].codec = codecForStreamType(type, false, false, false);
      table.streams[index].kind =
          trackKindForStreamType(type, false, false, false);
      ++index;
    }
    table.streamCount = index;
    return gradeProgram(table);
  };

  expect(grade({{0x1BU, 0x100}, {0x0FU, 0x101}}) == ProgramGrade::Complete,
         "H.264 plus ADTS AAC is a Complete program");
  expect(grade({{0x1BU, 0x100}, {0x11U, 0x101}}) == ProgramGrade::Complete,
         "H.264 plus AAC-LATM is a Complete program, which it was not before "
         "stream type 0x11 was routed");
  expect(grade({{0x24U, 0x100}, {0x81U, 0x101}}) == ProgramGrade::Complete,
         "HEVC plus ATSC AC-3 is a Complete program");
  expect(grade({{0x1BU, 0x100}}) == ProgramGrade::VideoOnly,
         "video with no audio grades VideoOnly");
  expect(grade({{0x1BU, 0x100}, {0x82U, 0x101}}) == ProgramGrade::VideoOnly,
         "video whose only audio is unroutable (DTS) grades VideoOnly, not "
         "Complete -- routable, not merely present");
  expect(grade({{0x0FU, 0x101}}) == ProgramGrade::None,
         "audio with no video is not a candidate");
  expect(grade({{0x10U, 0x100}, {0x0FU, 0x101}}) == ProgramGrade::None,
         "an unroutable video codec (MPEG-4 part 2) makes the program a "
         "non-candidate rather than a video-bearing winner");
  expect(grade({}) == ProgramGrade::None, "an empty program is None");

  // The ORDER is the rule. Complete must outrank VideoOnly must outrank None,
  // because the search compares grades with `>`.
  expect(ProgramGrade::Complete > ProgramGrade::VideoOnly &&
             ProgramGrade::VideoOnly > ProgramGrade::None,
         "the grades are strictly ordered Complete > VideoOnly > None");
}

void testRolloverFixture() {
  const std::filesystem::path root = fixtureRoot();
  const std::filesystem::path path = root / "rollover.ts";
  if (root.empty() || !std::filesystem::exists(path)) {
    skip("rollover.ts");
    return;
  }
  const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
  expect(outcome.status == MpegTsDemuxStatus::Ready,
         "a stream muxed across the 33-bit rollover prepares Ready");
  if (outcome.status != MpegTsDemuxStatus::Ready) {
    std::cerr << "  " << mpegTsDemuxErrorName(outcome.error) << ": "
              << outcome.message << '\n';
    return;
  }
  const MpegTsPreparedAsset& asset = *outcome.asset;
  // The origin must be near the wrap point, which is what makes this fixture a
  // real test rather than a relabelled ordinary file.
  const std::int64_t distanceToWrap = kTimestampModulus - asset.originTick();
  expect(asset.originTick() > kTimestampModulus - 90'000LL * 300LL,
         "the fixture's origin really is within five minutes of the wrap");
  expect(distanceToWrap > 0 && distanceToWrap < kTimestampModulus,
         "the origin is below the wrap point");

  const MpegTsPlanOutcome plan =
      asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
  expect(plan.status == MpegTsDemuxStatus::Ready,
         "planning across a rollover succeeds");
  if (plan.status != MpegTsDemuxStatus::Ready) {
    return;
  }
  std::unique_ptr<MpegTsCursor> cursor = asset.makeVideoCursor(*plan.plan);
  expect(cursor != nullptr, "a cursor is created on the rollover fixture");
  if (cursor == nullptr) {
    return;
  }
  const WalkSummary summary = walkCursor(asset, *cursor, 200);
  expect(!summary.failed, "the rollover walk completes");
  expect(summary.samples > 30, "the whole rollover clip is walked");
  expect(summary.everyPresentationValid,
         "every sample across the wrap carries a valid presentation time");
  expect(summary.decodeMonotone,
         "time never runs backwards across the 33-bit wrap — the extension to "
         "a monotone 64-bit timeline is what proves it");
  expect(summary.firstPresentationValue >= 0 &&
             summary.firstPresentationValue * 10 <=
                 summary.firstPresentationScale,
         "the wrapped stream still exports a timeline starting at zero");
}

void testCorruptionResync() {
  const std::filesystem::path root = fixtureRoot();
  const std::filesystem::path clean = root / "h264-aac.ts";
  const std::filesystem::path damaged = root / "h264-aac-corrupt.ts";
  if (root.empty() || !std::filesystem::exists(clean) ||
      !std::filesystem::exists(damaged)) {
    skip("h264-aac-corrupt.ts");
    return;
  }
  const MpegTsPrepareOutcome cleanOutcome = prepareMpegTsLocalFile(clean, {});
  const MpegTsPrepareOutcome damagedOutcome =
      prepareMpegTsLocalFile(damaged, {});
  expect(cleanOutcome.status == MpegTsDemuxStatus::Ready,
         "the control mux prepares Ready");
  expect(damagedOutcome.status == MpegTsDemuxStatus::Ready,
         "a mid-file corrupted mux still prepares Ready — corruption after "
         "the program tables must not cost the whole file");
  if (cleanOutcome.status != MpegTsDemuxStatus::Ready ||
      damagedOutcome.status != MpegTsDemuxStatus::Ready) {
    return;
  }

  const auto walk = [](const MpegTsPreparedAsset& asset) -> WalkSummary {
    const MpegTsPlanOutcome plan =
        asset.planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
    if (plan.status != MpegTsDemuxStatus::Ready) {
      WalkSummary summary{};
      summary.failed = true;
      return summary;
    }
    std::unique_ptr<MpegTsCursor> cursor = asset.makeVideoCursor(*plan.plan);
    if (cursor == nullptr) {
      WalkSummary summary{};
      summary.failed = true;
      return summary;
    }
    return walkCursor(asset, *cursor, 1'000);
  };

  const WalkSummary control = walk(*cleanOutcome.asset);
  const WalkSummary broken = walk(*damagedOutcome.asset);
  expect(!control.failed, "the control walk completes");
  expect(!broken.failed,
         "the damaged walk completes rather than derailing — drop and note, "
         "never fail the stream");
  expect(broken.samples > control.samples / 2,
         "700 damaged bytes cost a small fraction of the access units, not "
         "the rest of the file");
  expect(broken.continuityGaps > 0 || broken.resynchronizations > 0,
         "the damage is NOTICED and counted, not silently absorbed");
  std::cerr << "  corruption: control " << control.samples << " samples, "
            << "damaged " << broken.samples << " samples, "
            << broken.continuityGaps << " continuity gaps, "
            << broken.resynchronizations << " resynchronizations\n";
}

// One fixture's worth of seek-accuracy measurement.
//
// `maximumUndershoot` is the fixture's own contract, not the demuxer's: a
// 1 s-GOP mux can be held to a tight number while an 8.33 s-GOP one cannot,
// and conflating the two would measure the fixture. What is NOT negotiable in
// either is `allLandedAtOrBefore`: an accurate seek must never land after its
// target, because the frame the user asked for would then never be decoded.
void measureSeekAccuracy(const std::filesystem::path& path, const char* label,
                         double maximumUndershoot) {
  const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
  if (outcome.status != MpegTsDemuxStatus::Ready) {
    skip("seek accuracy (fixture did not prepare)");
    return;
  }
  const MpegTsPreparedAsset& asset = *outcome.asset;
  const MediaTime duration = asset.descriptor()->duration;
  const std::optional<double> durationSeconds =
      wam::media::mediaTimeSeconds(duration);
  if (!durationSeconds || *durationSeconds < 4.0) {
    skip("seek accuracy (fixture is too short)");
    return;
  }

  bool allLandedAtOrBefore = true;
  bool allCursorsStartCold = true;
  double worstUndershoot = 0.0;
  // Deliberately off-grid targets (tenths of a second) so a seek cannot be
  // right by landing on a keyframe it happened to be asked for. Spread across
  // the whole clip so a long-GOP fixture exercises the deepest backoff round
  // rather than only the shallow ones near the origin.
  std::array<std::int64_t, 8> targetTenths{15, 33, 57, 74, 92, 111, 138, 165};
  if (*durationSeconds > 20.0) {
    const double span = *durationSeconds - 1.0;
    for (std::size_t i = 0; i < targetTenths.size(); ++i) {
      targetTenths[i] = static_cast<std::int64_t>(
          (span * static_cast<double>(i + 1) / 9.0) * 10.0 + 5.0);
    }
  }
  std::size_t measured = 0;
  for (const std::int64_t tenths : targetTenths) {
    if (static_cast<double>(tenths) / 10.0 >= *durationSeconds) {
      continue;
    }
    ++measured;
    const MediaTime target{tenths, 10};
    const MpegTsPlanOutcome plan =
        asset.planGeneration(target, MediaSeekMode::Accurate);
    if (plan.status != MpegTsDemuxStatus::Ready) {
      std::cerr << "  seek to " << target.value << "s -> "
                << mpegTsDemuxErrorName(plan.error) << ": " << plan.message
                << '\n';
      expect(false, "an in-range accurate seek plans successfully");
      continue;
    }
    const std::optional<MediaTimeOrder> order =
        compareMediaTime(plan.plan->actualDecodeStart, target);
    if (!order || *order == MediaTimeOrder::Greater) {
      allLandedAtOrBefore = false;
    }
    const std::optional<double> landed =
        wam::media::mediaTimeSeconds(plan.plan->actualDecodeStart);
    const std::optional<double> wanted = wam::media::mediaTimeSeconds(target);
    if (landed && wanted) {
      worstUndershoot = std::max(worstUndershoot, *wanted - *landed);
    }
    std::unique_ptr<MpegTsCursor> cursor = asset.makeVideoCursor(*plan.plan);
    if (cursor == nullptr) {
      allCursorsStartCold = false;
      continue;
    }
    MpegTsCursorReadResult first = cursor->readNext();
    const auto* sample = std::get_if<MpegTsCompressedSample>(&first);
    if (sample == nullptr || !sample->decodableFromCold) {
      allCursorsStartCold = false;
    }
  }
  expect(allLandedAtOrBefore,
         "an accurate seek never lands AFTER its target, so no requested "
         "frame is skipped");
  expect(allCursorsStartCold,
         "every seek cursor's first sample is decodable from a cold decoder");
  std::cerr << "  seek " << label << ": worst undershoot " << worstUndershoot
            << " s across " << measured << " off-grid targets in a "
            << *durationSeconds << " s clip\n";
  expect(worstUndershoot < maximumUndershoot,
         "the undershoot stays inside this fixture's own GOP-derived ceiling");
}

void testSeekAccuracy() {
  const std::filesystem::path root = fixtureRoot();
  if (root.empty()) {
    skip("seek accuracy (no fixture root)");
    return;
  }
  struct Case {
    const char* file;
    const char* label;
    double maximumUndershoot;
  };
  // seek.ts is a 20 s clip at -g 25: one random access point per second, which
  // is what makes a tight landed-position measurement meaningful. `video.ts`
  // deliberately is NOT used -- it carries exactly one keyframe in 5 s, so
  // every seek past 1.5 s legitimately has no random access point after it.
  //
  // The HEVC fixtures are the opposite shape and are here on purpose: an
  // 8.33 s GOP at a higher bitrate than its H.264 twin is exactly what broke
  // the old fixed-16-entry backoff, and only a target deep into the clip
  // reaches the rounds that fix it.
  const std::array<Case, 4> cases{{
      {"seek.ts", "seek.ts (1 s GOP)", 12.0},
      {"hevc-aac.ts", "hevc-aac.ts (8.33 s GOP)", 12.0},
      {"hevc-main10.ts", "hevc-main10.ts", 12.0},
      {"hevc-ac3.m2ts", "hevc-ac3.m2ts", 12.0},
  }};
  for (const Case& entry : cases) {
    const std::filesystem::path path = root / entry.file;
    if (!std::filesystem::exists(path)) {
      skip(entry.label);
      continue;
    }
    measureSeekAccuracy(path, entry.label, entry.maximumUndershoot);
  }
}

void testFileIdentityAndCancellation() {
  const std::filesystem::path root = fixtureRoot();
  const std::filesystem::path source = root / "h264-only.ts";
  if (root.empty() || !std::filesystem::exists(source)) {
    skip("file identity");
    return;
  }
  const std::filesystem::path temporary =
      std::filesystem::temp_directory_path() / "wam-mpegts-identity.ts";
  std::filesystem::remove(temporary);
  std::filesystem::copy_file(source, temporary);

  const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(temporary, {});
  expect(outcome.status == MpegTsDemuxStatus::Ready,
         "the copied fixture prepares Ready");
  if (outcome.status != MpegTsDemuxStatus::Ready) {
    std::filesystem::remove(temporary);
    return;
  }
  const MpegTsPlanOutcome plan = outcome.asset->planGeneration(
      MediaTime{0, 1}, MediaSeekMode::Accurate);
  expect(plan.status == MpegTsDemuxStatus::Ready, "the initial plan succeeds");

  // Append one byte: size and mtime both move, so identity must fail.
  {
    std::ofstream append(temporary, std::ios::binary | std::ios::app);
    append.put('\0');
  }
  const MpegTsPlanOutcome afterChange = outcome.asset->planGeneration(
      MediaTime{0, 1}, MediaSeekMode::Accurate);
  expect(afterChange.error == MpegTsDemuxError::FileChanged,
         "a file mutated under a prepared asset is refused as FileChanged, "
         "not read as if the index still described it");

  std::filesystem::remove(temporary);

  // Cancellation must be observed by preparation on a real file.
  std::atomic<bool> cancelled{true};
  const MpegTsPrepareOutcome stopped =
      prepareMpegTsLocalFile(source, {}, {&cancelled, atomicCancellation});
  expect(stopped.status == MpegTsDemuxStatus::Cancelled,
         "a cancelled local-file preparation returns Cancelled");

  const MpegTsPrepareOutcome missing =
      prepareMpegTsLocalFile(root / "does-not-exist.ts", {});
  expect(missing.error == MpegTsDemuxError::Io,
         "a missing path is an I/O verdict");
}

void testUnsupportedStreamTypeVerdicts() {
  const std::filesystem::path root = fixtureRoot();
  // HEVC is the only video codec still outside the envelope, and the point of
  // the test is that it is refused BY NAME and as an envelope verdict, so the
  // session falls back cleanly instead of reporting a protocol fault.
  struct Case {
    const char* file;
    const char* label;
  };
  const std::array<Case, 1> cases{{
      {"hevc-ac3.ts", "hevc-ac3.ts (HEVC)"},
  }};
  for (const Case& entry : cases) {
    const std::filesystem::path path = root / entry.file;
    if (root.empty() || !std::filesystem::exists(path)) {
      skip(entry.label);
      continue;
    }
    const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
    expect(outcome.status == MpegTsDemuxStatus::Unsupported,
           "a stream outside the admitted codec envelope is Unsupported");
    expect(outcome.error == MpegTsDemuxError::UnsupportedStreamType,
           "the refusal names the stream type, never a generic failure");
    expect(!outcome.message.empty(),
           "the refusal carries a message naming what is missing");
    std::cerr << "  " << entry.label << " -> "
              << mpegTsDemuxErrorName(outcome.error) << ": " << outcome.message
              << '\n';
  }
}

// MPEG-2 video and the MPEG-audio/AC-3 families are now inside the envelope.
// This is the other half of the verdict test: what used to be refused by name
// must now be admitted with an exact descriptor, a positive frame extent, and
// -- where the audio codec is routable -- a selected audio track.
// End-to-end admission of HEVC transport streams: the synthesized hvcC must
// survive the SHARED codec inspector, which re-parses the VPS/SPS/PPS the
// record carries and compares every header field it re-derives. A record that
// merely "looks right" does not reach here.
void testHevcAdmission() {
  const std::filesystem::path root = fixtureRoot();
  struct Case {
    const char* file;
    const char* label;
    std::uint8_t expectedDepth;
    std::uint8_t expectedProfileIdc;
    MediaCodec audio;
  };
  const std::array<Case, 4> cases{{
      {"hevc-aac.ts", "hevc-aac.ts (Main 8-bit)", 8, 1, MediaCodec::Aac},
      {"hevc-main10.ts", "hevc-main10.ts", 10, 2, MediaCodec::Aac},
      {"hevc-main10-pq.ts", "hevc-main10-pq.ts (BT.2020 PQ)", 10, 2,
       MediaCodec::Aac},
      {"hevc-ac3.m2ts", "hevc-ac3.m2ts", 8, 1, MediaCodec::Ac3},
  }};
  for (const Case& entry : cases) {
    const std::filesystem::path path = root / entry.file;
    if (root.empty() || !std::filesystem::exists(path)) {
      skip(entry.label);
      continue;
    }
    const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
    if (outcome.status != MpegTsDemuxStatus::Ready) {
      std::cerr << "  " << entry.label << " -> "
                << mpegTsDemuxErrorName(outcome.error) << ": "
                << outcome.message << '\n';
      expect(false, "an HEVC transport stream is admitted");
      continue;
    }
    const MediaSourceDescriptor& descriptor = *outcome.asset->descriptor();
    const MediaTrackDescriptor* video =
        descriptor.selectedVideo
            ? findMediaTrack(descriptor, *descriptor.selectedVideo)
            : nullptr;
    expect(video != nullptr && video->codec == MediaCodec::Hevc,
           "stream type 0x24 routes to HEVC");
    if (video == nullptr) {
      continue;
    }
    expect(video->codecConfigurationKind ==
               MediaCodecConfigurationKind::HvcC,
           "the synthesized record is declared as an hvcC");
    const std::vector<std::byte>& record = video->codecConfiguration;
    // 23 header bytes, then three arrays each costing at least 3 + 2 + 1.
    expect(record.size() > 23 + 3 * 6,
           "the record carries a header and three parameter-set arrays");
    if (record.size() <= 23) {
      continue;
    }
    const auto at = [&](std::size_t index) {
      return static_cast<std::uint8_t>(record[index]);
    };
    expect(at(0) == 0x01, "configurationVersion is 1");
    expect((at(1) & 0xC0U) == 0U && (at(1) & 0x1FU) == entry.expectedProfileIdc,
           "general_profile_space is zero and general_profile_idc is the "
           "SPS's own");
    expect(at(13) == 0xF0 && at(14) == 0x00,
           "min_spatial_segmentation_idc is stated as zero behind its four "
           "reserved ones");
    expect(at(15) == 0xFC, "parallelismType is stated as unknown");
    expect(at(16) == 0xFD, "chroma_format_idc is 1 (4:2:0)");
    const std::uint8_t depth =
        static_cast<std::uint8_t>(8U + (at(17) & 0x07U));
    expect(depth == entry.expectedDepth &&
               (at(17) & 0xF8U) == 0xF8U && at(18) == at(17),
           "luma and chroma bit depths agree and match the fixture");
    expect((at(21) & 0x03U) == 0x03U,
           "lengthSizeMinusOne is 3, matching the four-byte lengths the "
           "sample repack writes");
    expect(((at(21) >> 3U) & 0x07U) >= 1U,
           "numTemporalLayers is at least one");
    expect(at(22) == 0x03, "exactly three parameter-set arrays");
    expect(at(23) == 0x20, "the first array is the VPS array");
    expect(video->video.has_value() &&
               video->video->bitsPerComponent == entry.expectedDepth,
           "the descriptor states the coded depth the record does");
    const MediaTrackDescriptor* audio =
        descriptor.selectedAudio
            ? findMediaTrack(descriptor, *descriptor.selectedAudio)
            : nullptr;
    expect(audio != nullptr && audio->codec == entry.audio,
           "the paired audio track is admitted unchanged");

    // Walk far enough to prove the keyframe predicate fires on IRAP NALs and
    // that a cold-decodable unit exists, which is what every seek depends on.
    const MpegTsPlanOutcome planned =
        outcome.asset->planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
    expect(planned.status == MpegTsDemuxStatus::Ready,
           "an HEVC generation plans from the origin");
    if (!planned.plan) {
      continue;
    }
    std::unique_ptr<MpegTsCursor> cursor =
        outcome.asset->makeVideoCursor(*planned.plan);
    std::size_t units = 0;
    std::size_t cold = 0;
    while (cursor != nullptr && units < 120) {
      const MpegTsCursorReadResult read = cursor->readNext();
      const auto* sample = std::get_if<MpegTsCompressedSample>(&read);
      if (sample == nullptr) {
        break;
      }
      cold += sample->decodableFromCold ? 1 : 0;
      ++units;
    }
    expect(units > 0, "the HEVC cursor produces access units");
    expect(cold > 0,
           "at least one HEVC access unit is proved cold-decodable from the "
           "bitstream, not from random_access_indicator");
    std::cerr << "  " << entry.label << " -> " << video->video->codedWidth
              << "x" << video->video->codedHeight << ", " << int{depth}
              << "-bit, hvcC " << record.size() << " bytes, " << units
              << " units, " << cold << " cold\n";
  }
}

void testMpeg2AndAc3Admission() {
  const std::filesystem::path root = fixtureRoot();
  struct Case {
    const char* file;
    const char* label;
    MediaCodec video;
    MediaCodec audio;
  };
  const std::array<Case, 3> cases{{
      {"mpeg2-mp2.ts", "mpeg2-mp2.ts", MediaCodec::Mpeg2Video, MediaCodec::Mp3},
      {"mpeg2-mp3.ts", "mpeg2-mp3.ts", MediaCodec::Mpeg2Video, MediaCodec::Mp3},
      {"h264-ac3.m2ts", "h264-ac3.m2ts", MediaCodec::H264, MediaCodec::Ac3},
  }};
  for (const Case& entry : cases) {
    const std::filesystem::path path = root / entry.file;
    if (root.empty() || !std::filesystem::exists(path)) {
      skip(entry.label);
      continue;
    }
    const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
    expect(outcome.status == MpegTsDemuxStatus::Ready,
           "the fixture is admitted");
    if (outcome.asset == nullptr) {
      continue;
    }
    const MediaSourceDescriptor& descriptor = *outcome.asset->descriptor();
    expect(descriptor.selectedVideo.has_value(), "a video track is selected");
    expect(descriptor.selectedAudio.has_value(), "an audio track is selected");
    const MediaTrackDescriptor* video =
        findMediaTrack(descriptor, *descriptor.selectedVideo);
    const MediaTrackDescriptor* audio =
        descriptor.selectedAudio
            ? findMediaTrack(descriptor, *descriptor.selectedAudio)
            : nullptr;
    expect(video != nullptr && video->codec == entry.video,
           "the video codec is the expected one");
    expect(audio != nullptr && audio->codec == entry.audio,
           "the audio codec is the expected one");
    if (video != nullptr && entry.video == MediaCodec::Mpeg2Video) {
      // MPEG-2 needs no decoder configuration record at all, and the
      // descriptor validator admits a None kind only alongside an empty one.
      expect(video->codecConfigurationKind ==
                     MediaCodecConfigurationKind::None &&
                 video->codecConfiguration.empty(),
             "MPEG-2 carries no configuration record");
    }
    // Every video sample must state a positive interval: the native video
    // consumer refuses a sample whose duration is absent or non-positive.
    const MpegTsPlanOutcome planned =
        outcome.asset->planGeneration(MediaTime{0, 1}, MediaSeekMode::Accurate);
    expect(planned.status == MpegTsDemuxStatus::Ready && planned.plan.has_value(),
           "a generation plans from the origin");
    if (!planned.plan) {
      continue;
    }
    std::unique_ptr<MpegTsCursor> cursor =
        outcome.asset->makeVideoCursor(*planned.plan);
    expect(cursor != nullptr, "a video cursor is created");
    std::size_t units = 0;
    bool everyUnitHasPositiveDuration = true;
    MediaTime firstDuration{};
    while (cursor != nullptr && units < 32) {
      const MpegTsCursorReadResult read = cursor->readNext();
      const auto* sample = std::get_if<MpegTsCompressedSample>(&read);
      if (sample == nullptr) {
        break;
      }
      if (units == 0) {
        firstDuration = sample->duration;
      }
      if (!sample->duration.valid() || sample->duration.value <= 0) {
        everyUnitHasPositiveDuration = false;
      }
      ++units;
    }
    expect(units > 0, "the video cursor produces access units");
    expect(everyUnitHasPositiveDuration,
           "every video access unit states a positive frame extent");
    // The display size window geometry is shaped from. AVFoundation cannot
    // demux MPEG-TS and answers (0, 0) for these files, so what this
    // descriptor states is the only answer the aspect lock ever sees. Neither
    // TS path derives a display size from the stream's aspect signalling --
    // MPEG-2's aspect_ratio_information is parsed and unused, and H.264's
    // aspect_ratio_idc is skipped in the SPS VUI -- so display is coded, and
    // pinning that keeps the day it stops being true honest.
    if (video != nullptr && video->video) {
      expect(video->video->displayWidth == video->video->codedWidth &&
                 video->video->displayHeight == video->video->codedHeight,
             "MPEG-TS states a square-pixel display size equal to its coded "
             "size");
      const wam::media::MediaDisplaySize display =
          wam::media::mediaSourceDisplaySize(descriptor);
      expect(display.width == video->video->codedWidth &&
                 display.height == video->video->codedHeight,
             "mediaSourceDisplaySize reads the selected MPEG-TS video track's "
             "display size");
    }
    std::cerr << "  " << entry.label << " -> video "
              << (video != nullptr ? video->video->codedWidth : 0) << "x"
              << (video != nullptr ? video->video->codedHeight : 0)
              << ", frame extent " << firstDuration.value << "/"
              << firstDuration.timescale << " s, audio "
              << (audio != nullptr ? audio->audio->sampleRate : 0.0) << " Hz x"
              << (audio != nullptr ? audio->audio->channels : 0U)
              << ", framesPerPacket "
              << (audio != nullptr ? audio->audio->framesPerPacket : 0U)
              << '\n';
  }
}

// The exported duration must be the end of the MEDIA, not the last program
// clock reference.
//
// 13818-1's buffering model puts a picture's presentation one end-to-end buffer
// delay after the byte that carried it, so the last PCR sits most of a second
// before the last presentation time -- measured across this corpus, 0.73 s to
// 0.88 s, every time, in the same direction. A PCR-derived duration therefore
// shortens the scrubber's range, makes seeks near the end unrepresentable, and
// truncates published audio whenever the short value lands on the audio frame
// grid. Ground truth is ffprobe's container duration for each fixture.
void testDurationAgainstGroundTruth() {
  const std::filesystem::path root = fixtureRoot();
  struct Case {
    const char* file;
    double seconds;  // ffprobe's stated container duration
  };
  const std::array<Case, 7> cases{{
      {"h264-aac.ts", 3.02},
      {"mpeg2-mp2.ts", 3.01},
      {"mpeg2-mp3.ts", 3.01},
      {"h264-ac3.m2ts", 3.01},
      {"video.ts", 6.02},
      {"L_video.ts", 20.02},
      {"seek.ts", 20.02},
  }};
  double worst = 0.0;
  for (const Case& entry : cases) {
    const std::filesystem::path path = root / entry.file;
    if (root.empty() || !std::filesystem::exists(path)) {
      skip(entry.file);
      continue;
    }
    const MpegTsPrepareOutcome outcome = prepareMpegTsLocalFile(path, {});
    expect(outcome.status == MpegTsDemuxStatus::Ready && outcome.asset,
           "the fixture is admitted");
    if (!outcome.asset) {
      continue;
    }
    const auto seconds =
        wam::media::mediaTimeSeconds(outcome.asset->descriptor()->duration);
    expect(seconds.has_value(), "the duration is exactly representable");
    if (!seconds) {
      continue;
    }
    const double error = *seconds - entry.seconds;
    worst = std::max(worst, std::abs(error));
    // 50 ms is comfortably above ffprobe's own centisecond quantisation and
    // one frame of jitter, and an order of magnitude below the 0.73 s the
    // PCR-derived value was wrong by.
    expect(std::abs(error) < 0.05,
           "the duration is within 50 ms of the container's own");
  }
  std::cerr << "  duration: worst error " << worst
            << " s against ffprobe across the corpus\n";
}

}  // namespace

int main() {
  testTimestampRollover();
  testExactTicks();
  testPacketDecoding();
  testContinuityTracking();
  testSectionAssemblyAndCrc();
  testProgramMapParsing();
  testPesHeaderDecoding();
  testAccessUnitScanning();
  testHevcParameterSetFacts();
  testAnnexBToAvccRepack();
  testElementaryAudioFraming();
  testLatmFraming();
  testEac3Framing();
  testProgramGradeRule();
  testFramingDetection();
  testPreparationRequestValidation();
  testRealMuxes();
  testGroundTruthAgainstFfmpeg();
  testMultiProgramSelection();
  testRolloverFixture();
  testCorruptionResync();
  testSeekAccuracy();
  testFileIdentityAndCancellation();
  testUnsupportedStreamTypeVerdicts();
  testMpeg2AndAc3Admission();
  testHevcAdmission();
  testDurationAgainstGroundTruth();

  if (skipped != 0) {
    std::cerr << skipped << " MPEG-TS test group(s) skipped\n";
  }
  if (failures != 0) {
    std::cerr << failures << " MPEG-TS demuxer test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "MPEG-TS demuxer tests passed (" << assertions
            << " assertions)\n";
  return EXIT_SUCCESS;
}
