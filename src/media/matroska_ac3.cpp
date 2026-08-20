#include "media/matroska_ac3.hpp"

#include <array>

namespace wam::media::matroska {
namespace {

// A/52 table 5.1: fscod -> sample rate. Index 3 is reserved in AC-3 and means
// "halve the rate named by fscod2" in E-AC-3; both are refused.
constexpr std::array<std::uint32_t, 3> kSampleRateByFscod{48'000U, 44'100U,
                                                          32'000U};

// A/52 table 5.18: bit rate in kbit/s, indexed by frmsizecod >> 1.
constexpr std::array<std::uint16_t, 19> kBitRateByCode{
    32U,  40U,  48U,  56U,  64U,  80U,  96U,  112U, 128U, 160U,
    192U, 224U, 256U, 320U, 384U, 448U, 512U, 576U, 640U};

// A/52 table 5.8: number of full-bandwidth channels, indexed by acmod.
constexpr std::array<std::uint8_t, 8> kChannelsByAcmod{2U, 1U, 2U, 3U,
                                                       3U, 4U, 4U, 5U};

constexpr std::uint8_t kMonoAcmod{1};
constexpr std::uint8_t kStereoAcmod{2};

// E-AC-3 numblkscod -> blocks per syncframe.
constexpr std::array<std::uint8_t, 4> kBlocksByNumblkscod{1U, 2U, 3U, 6U};

// A big-endian bit reader over the syncframe. Every read is bounded, so a
// truncated frame fails closed instead of walking off the span.
class BitReader {
public:
  explicit BitReader(std::span<const std::byte> bytes) noexcept
      : bytes_(bytes) {}

  [[nodiscard]] bool read(std::size_t count, std::uint32_t *value) noexcept {
    if (count > 32U || count > remaining()) {
      return false;
    }
    std::uint32_t result = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const std::size_t byteIndex = position_ >> 3U;
      const std::size_t bitIndex = 7U - (position_ & 7U);
      const auto byte = std::to_integer<std::uint8_t>(bytes_[byteIndex]);
      result = (result << 1U) | ((byte >> bitIndex) & 1U);
      ++position_;
    }
    *value = result;
    return true;
  }

  [[nodiscard]] bool skip(std::size_t count) noexcept {
    if (count > remaining()) {
      return false;
    }
    position_ += count;
    return true;
  }

  [[nodiscard]] std::size_t remaining() const noexcept {
    return bytes_.size() * 8U - position_;
  }

private:
  std::span<const std::byte> bytes_;
  std::size_t position_{0};
};

[[nodiscard]] Ac3Admission failure(Ac3AdmissionError error) noexcept {
  return Ac3Admission{error, std::nullopt};
}

// A/52 section 5.3.1: the syncframe length in 16-bit words for a legacy AC-3
// frame, from frmsizecod and fscod. Stated as arithmetic rather than as the
// 114-entry table it is usually written as, because the arithmetic is the
// definition and the table is its expansion.
[[nodiscard]] std::optional<std::uint32_t>
legacyFrameWords(std::uint32_t frmsizecod, std::uint32_t fscod) noexcept {
  const std::uint32_t rateIndex = frmsizecod >> 1U;
  if (rateIndex >= kBitRateByCode.size()) {
    return std::nullopt;
  }
  const std::uint32_t kbps = kBitRateByCode[rateIndex];
  switch (fscod) {
  case 0U: // 48 kHz
    return 2U * kbps;
  case 1U: // 44.1 kHz -- the one rate whose frame length alternates
    return (320U * kbps / 147U) + ((frmsizecod & 1U) != 0U ? 1U : 0U);
  case 2U: // 32 kHz
    return 3U * kbps;
  default:
    return std::nullopt;
  }
}

struct ParsedHeader {
  std::uint32_t sampleRate{0};
  std::uint8_t channelCount{0};
  std::uint32_t syncframeBytes{0};
  std::uint32_t blocks{0};
  bool enhanced{false};
};

[[nodiscard]] Ac3AdmissionError
parseHeader(std::span<const std::byte> frame, bool wantEnhanced,
            ParsedHeader *parsed) noexcept {
  if (frame.size() < kAc3MinimumSyncframeBytes) {
    return Ac3AdmissionError::TruncatedSyncframe;
  }
  const auto syncword = static_cast<std::uint16_t>(
      (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(frame[0]))
       << 8U) |
      static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(frame[1])));
  if (syncword != kAc3Syncword) {
    return Ac3AdmissionError::UnexpectedSyncword;
  }

  // bsid sits at bits 40..44 in BOTH syntaxes -- that co-location is what makes
  // it readable before the rest of the header has been interpreted, and it is
  // the only reason a single parser can dispatch between them.
  const auto bsid = static_cast<std::uint8_t>(
      (std::to_integer<std::uint8_t>(frame[5]) >> 3U) & 0x1FU);
  const bool enhanced = bsid >= kMinimumEnhancedAc3BitStreamIdentification &&
                        bsid <= kMaximumEnhancedAc3BitStreamIdentification;
  const bool legacy = bsid <= kMaximumLegacyAc3BitStreamIdentification;
  if (!enhanced && !legacy) {
    return Ac3AdmissionError::UnsupportedBitStreamIdentification;
  }
  if (enhanced != wantEnhanced) {
    return Ac3AdmissionError::CodecIdMismatch;
  }
  parsed->enhanced = enhanced;

  BitReader reader(frame);
  if (!reader.skip(16U)) { // syncword
    return Ac3AdmissionError::TruncatedSyncframe;
  }

  if (!enhanced) {
    if (!reader.skip(16U)) { // crc1
      return Ac3AdmissionError::TruncatedSyncframe;
    }
    std::uint32_t fscod = 0;
    std::uint32_t frmsizecod = 0;
    if (!reader.read(2U, &fscod) || !reader.read(6U, &frmsizecod)) {
      return Ac3AdmissionError::TruncatedSyncframe;
    }
    if (fscod >= kSampleRateByFscod.size()) {
      return Ac3AdmissionError::ReservedSampleRate;
    }
    const auto words = legacyFrameWords(frmsizecod, fscod);
    if (!words) {
      return Ac3AdmissionError::UnsupportedBitRateCode;
    }
    parsed->sampleRate = kSampleRateByFscod[fscod];
    parsed->syncframeBytes = *words * 2U;
    parsed->blocks = kAc3BlocksPerSyncframe;
    if (!reader.skip(8U)) { // bsid (5) + bsmod (3)
      return Ac3AdmissionError::TruncatedSyncframe;
    }
    std::uint32_t acmod = 0;
    if (!reader.read(3U, &acmod)) {
      return Ac3AdmissionError::TruncatedSyncframe;
    }
    // A/52 5.4.1: the mix level fields are conditional on acmod, so the LFE
    // flag's bit position depends on them and cannot be indexed blindly.
    if ((acmod & 0x01U) != 0U && acmod != 0x01U) {
      if (!reader.skip(2U)) { // cmixlev
        return Ac3AdmissionError::TruncatedSyncframe;
      }
    }
    if ((acmod & 0x04U) != 0U) {
      if (!reader.skip(2U)) { // surmixlev
        return Ac3AdmissionError::TruncatedSyncframe;
      }
    }
    if (acmod == 0x02U) {
      if (!reader.skip(2U)) { // dsurmod
        return Ac3AdmissionError::TruncatedSyncframe;
      }
    }
    std::uint32_t lfeon = 0;
    if (!reader.read(1U, &lfeon)) {
      return Ac3AdmissionError::TruncatedSyncframe;
    }
    if ((acmod != kMonoAcmod && acmod != kStereoAcmod) || lfeon != 0U) {
      return Ac3AdmissionError::UnsupportedChannelConfiguration;
    }
    parsed->channelCount = kChannelsByAcmod[acmod];
    return Ac3AdmissionError::None;
  }

  // E-AC-3 (A/52 Annex E) bit stream information.
  std::uint32_t strmtyp = 0;
  std::uint32_t substreamid = 0;
  std::uint32_t frmsiz = 0;
  if (!reader.read(2U, &strmtyp) || !reader.read(3U, &substreamid) ||
      !reader.read(11U, &frmsiz)) {
    return Ac3AdmissionError::TruncatedSyncframe;
  }
  // Type 0 is an independent substream; types 1 and 2 are dependent substreams
  // and AC-3-converted streams, both of which describe audio this source does
  // not assemble. substreamid must be 0 for the same reason.
  if (strmtyp != 0U || substreamid != 0U) {
    return Ac3AdmissionError::UnsupportedSubstream;
  }
  parsed->syncframeBytes = (frmsiz + 1U) * 2U;

  std::uint32_t fscod = 0;
  if (!reader.read(2U, &fscod)) {
    return Ac3AdmissionError::TruncatedSyncframe;
  }
  if (fscod >= kSampleRateByFscod.size()) {
    // fscod == 3 selects a halved rate via fscod2. Those streams are 6 blocks
    // of 256 frames at half rate, which the grid could represent, but no
    // encoder in reach emits them and an unexercised branch is worse than a
    // fallback.
    return Ac3AdmissionError::ReservedSampleRate;
  }
  parsed->sampleRate = kSampleRateByFscod[fscod];
  std::uint32_t numblkscod = 0;
  if (!reader.read(2U, &numblkscod)) {
    return Ac3AdmissionError::TruncatedSyncframe;
  }
  parsed->blocks = kBlocksByNumblkscod[numblkscod & 0x03U];
  if (parsed->blocks != kAc3BlocksPerSyncframe) {
    return Ac3AdmissionError::UnsupportedBlockCount;
  }
  std::uint32_t acmod = 0;
  std::uint32_t lfeon = 0;
  if (!reader.read(3U, &acmod) || !reader.read(1U, &lfeon)) {
    return Ac3AdmissionError::TruncatedSyncframe;
  }
  if ((acmod != kMonoAcmod && acmod != kStereoAcmod) || lfeon != 0U) {
    return Ac3AdmissionError::UnsupportedChannelConfiguration;
  }
  parsed->channelCount = kChannelsByAcmod[acmod];
  return Ac3AdmissionError::None;
}

} // namespace

Ac3Admission parseAc3Syncframe(std::span<const std::byte> frame,
                               bool enhanced) noexcept {
  ParsedHeader parsed;
  const Ac3AdmissionError error = parseHeader(frame, enhanced, &parsed);
  if (error != Ac3AdmissionError::None) {
    return failure(error);
  }
  if (parsed.syncframeBytes == 0U ||
      parsed.syncframeBytes != frame.size()) {
    return failure(Ac3AdmissionError::FrameSizeMismatch);
  }
  Ac3Configuration configuration;
  configuration.sampleRate = parsed.sampleRate;
  configuration.channelCount = parsed.channelCount;
  configuration.samplesPerAccessUnit =
      parsed.blocks * kAc3FramesPerBlock;
  configuration.syncframeBytes = parsed.syncframeBytes;
  configuration.enhanced = parsed.enhanced;
  return Ac3Admission{Ac3AdmissionError::None, configuration};
}

bool ac3SyncframeMatches(std::span<const std::byte> header,
                         std::uint64_t frameBytes,
                         const Ac3Configuration &configuration,
                         bool enhanced) noexcept {
  ParsedHeader parsed;
  if (parseHeader(header, enhanced, &parsed) != Ac3AdmissionError::None) {
    return false;
  }
  // The frame LENGTH is deliberately not compared against the admitted one:
  // a constant-bit-rate 44.1 kHz AC-3 stream alternates between two legal
  // lengths by design. What must not change is anything the timeline or the
  // decoder's output shape is derived from.
  return parsed.sampleRate == configuration.sampleRate &&
         parsed.channelCount == configuration.channelCount &&
         parsed.blocks * kAc3FramesPerBlock ==
             configuration.samplesPerAccessUnit &&
         parsed.enhanced == configuration.enhanced &&
         static_cast<std::uint64_t>(parsed.syncframeBytes) == frameBytes;
}

static_assert(kAc3SamplesPerAccessUnit ==
                  kAc3BlocksPerSyncframe * kAc3FramesPerBlock,
              "an AC-3 access unit is 6 blocks of 256 frames");

} // namespace wam::media::matroska
