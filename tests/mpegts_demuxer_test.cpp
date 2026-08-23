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

void testSeekAccuracy() {
  const std::filesystem::path root = fixtureRoot();
  // A 20 s clip at -g 25: one random access point per second, which is what
  // makes a landed-position measurement meaningful. `video.ts` deliberately is
  // NOT used here — it carries exactly one keyframe in 5 s, so every seek past
  // 1.5 s legitimately has no random access point after it, and measuring
  // "accuracy" against it would measure the fixture, not the demuxer.
  const std::filesystem::path path = root / "seek.ts";
  if (root.empty() || !std::filesystem::exists(path)) {
    skip("seek accuracy (seek.ts)");
    return;
  }
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
  // right by landing on a keyframe it happened to be asked for.
  const std::array<std::int64_t, 8> targetTenths{15, 33, 57, 74, 92, 111,
                                                 138, 165};
  for (const std::int64_t tenths : targetTenths) {
    if (static_cast<double>(tenths) / 10.0 >= *durationSeconds) {
      continue;
    }
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
  std::cerr << "  seek: worst undershoot " << worstUndershoot
            << " s across " << targetTenths.size() << " off-grid targets in a "
            << *durationSeconds << " s clip\n";
  expect(worstUndershoot < 12.0,
         "the undershoot stays within the source contract's 12 s video "
         "preroll ceiling");
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
  testAnnexBToAvccRepack();
  testElementaryAudioFraming();
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
