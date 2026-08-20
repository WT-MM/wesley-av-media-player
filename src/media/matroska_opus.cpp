#include "media/matroska_opus.hpp"

#include <array>
#include <cstring>

namespace wam::media::matroska {
namespace {

constexpr std::array<std::byte, 8> kOpusHeadMagic{
    std::byte{'O'}, std::byte{'p'}, std::byte{'u'}, std::byte{'s'},
    std::byte{'H'}, std::byte{'e'}, std::byte{'a'}, std::byte{'d'}};

// A pre-skip larger than this cannot describe a real encoder lead-in and would
// make the head trim outrun any bounded preroll. 80 ms of 48 kHz frames is
// already four times Opus' own SeekPreRoll.
constexpr std::uint16_t kMaximumOpusPreSkipFrames{3'840};

// RFC 6716 section 3.1, table 2: decoded duration of one Opus frame for each
// of the 32 TOC configurations, expressed in 48 kHz frames. 2.5/5/10/20/40/60
// ms are 120/240/480/960/1920/2880 frames.
constexpr std::array<std::uint32_t, 32> kConfigurationFrames{
    // 0-11: SILK-only, NB / MB / WB, 10, 20, 40, 60 ms.
    480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 1920, 2880,
    // 12-15: Hybrid, SWB / FB, 10, 20 ms.
    480, 960, 480, 960,
    // 16-31: CELT-only, NB / WB / SWB / FB, 2.5, 5, 10, 20 ms.
    120, 240, 480, 960, 120, 240, 480, 960, 120, 240, 480, 960, 120, 240, 480,
    960};

[[nodiscard]] std::uint16_t readLittleEndian16(
    std::span<const std::byte> bytes, std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(std::to_integer<std::uint8_t>(bytes[offset])) |
      static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(
              std::to_integer<std::uint8_t>(bytes[offset + 1U]))
          << 8U));
}

[[nodiscard]] std::uint32_t readLittleEndian32(
    std::span<const std::byte> bytes, std::size_t offset) noexcept {
  std::uint32_t value = 0;
  for (std::size_t index = 0; index < 4U; ++index) {
    value |= static_cast<std::uint32_t>(
                 std::to_integer<std::uint8_t>(bytes[offset + index]))
             << (8U * index);
  }
  return value;
}

} // namespace

OpusAdmission
parseOpusIdentificationHeader(std::span<const std::byte> bytes) noexcept {
  OpusAdmission admission;
  // Family 0 pins the size exactly; a longer header carries a channel mapping
  // table this source does not decode, and a shorter one is malformed.
  if (bytes.size() != kOpusIdentificationHeaderBytes) {
    admission.error = OpusAdmissionError::InvalidHeaderSize;
    return admission;
  }
  if (std::memcmp(bytes.data(), kOpusHeadMagic.data(),
                  kOpusHeadMagic.size()) != 0) {
    admission.error = OpusAdmissionError::UnexpectedMagic;
    return admission;
  }
  // The major version is the high nibble. Only major 0 is defined, and every
  // real muxer writes exactly 1; anything else is a stream shape this source
  // has not been proven against.
  if (std::to_integer<std::uint8_t>(bytes[8]) != 1U) {
    admission.error = OpusAdmissionError::UnsupportedVersion;
    return admission;
  }
  const auto channelCount = std::to_integer<std::uint8_t>(bytes[9]);
  if (channelCount == 0U || channelCount > 2U) {
    admission.error = OpusAdmissionError::UnsupportedChannelCount;
    return admission;
  }
  const std::uint16_t preSkip = readLittleEndian16(bytes, 10U);
  if (preSkip < kOpusDecoderDelayFrames) {
    // 120 frames is the minimum CELT decoder delay, so no real encoder can
    // report less. Falling back beats guessing at a negative trim.
    admission.error = OpusAdmissionError::PreSkipBelowDecoderDelay;
    return admission;
  }
  if (preSkip > kMaximumOpusPreSkipFrames) {
    admission.error = OpusAdmissionError::PreSkipExceedsMaximum;
    return admission;
  }
  // Output gain is Q7.8 dB. Honouring a nonzero gain would mean scaling PCM
  // the decoder already produced, which is outside this source's contract.
  if (readLittleEndian16(bytes, 16U) != 0U) {
    admission.error = OpusAdmissionError::NonzeroOutputGain;
    return admission;
  }
  if (std::to_integer<std::uint8_t>(bytes[18]) != 0U) {
    admission.error = OpusAdmissionError::UnsupportedChannelMappingFamily;
    return admission;
  }
  OpusConfiguration configuration;
  configuration.preSkipFrames = preSkip;
  configuration.channelCount = channelCount;
  configuration.inputSampleRate = readLittleEndian32(bytes, 12U);
  admission.error = OpusAdmissionError::None;
  admission.configuration = configuration;
  return admission;
}

std::optional<std::uint32_t>
opusPacketFrameCount(std::span<const std::byte> packet) noexcept {
  if (packet.empty()) {
    return std::nullopt;
  }
  const auto toc = std::to_integer<std::uint8_t>(packet[0]);
  const std::uint32_t frameSize =
      kConfigurationFrames[static_cast<std::size_t>(toc >> 3U)];
  std::uint32_t frames = 0;
  switch (toc & 0x03U) {
  case 0U:
    frames = 1U;
    break;
  case 1U:
  case 2U:
    frames = 2U;
    break;
  default: {
    // Code 3: the frame count lives in the low six bits of the next byte.
    if (packet.size() < 2U) {
      return std::nullopt;
    }
    frames = static_cast<std::uint32_t>(
        std::to_integer<std::uint8_t>(packet[1]) & 0x3FU);
    // The field can encode 63, but 2.5 ms is the shortest frame, so more than
    // 48 cannot fit the 120 ms packet ceiling under any configuration.
    if (frames == 0U || frames > kMaximumOpusFramesPerPacket) {
      return std::nullopt;
    }
    break;
  }
  }
  const std::uint32_t total = frames * frameSize;
  if (total == 0U || total > kMaximumOpusPacketFrames) {
    return std::nullopt;
  }
  return total;
}

std::optional<std::uint32_t>
opusFramesFromNanoseconds(std::int64_t nanoseconds) noexcept {
  if (nanoseconds < 0) {
    return std::nullopt;
  }
  const auto magnitude = static_cast<std::uint64_t>(nanoseconds);
  // Bound the magnitude BEFORE forming the product, so a hostile value can
  // never wrap the multiplication (it is unsigned, so a wrap would be defined
  // but would also be a UBSan report and a lie).
  // One frame past the ceiling, so the frame-count check below -- not this
  // overflow guard -- is what states the ceiling.
  constexpr std::uint64_t kMaximumNanoseconds =
      UINT64_C(1'000'000'000) *
      (static_cast<std::uint64_t>(kMaximumOpusPacketFrames) + 1U) /
      static_cast<std::uint64_t>(kOpusOutputSampleRate);
  if (magnitude > kMaximumNanoseconds) {
    return std::nullopt;
  }
  const std::uint64_t product =
      magnitude * static_cast<std::uint64_t>(kOpusOutputSampleRate);
  const std::uint64_t frames =
      (product + UINT64_C(500'000'000)) / UINT64_C(1'000'000'000);
  const std::uint64_t exact = frames * UINT64_C(1'000'000'000);
  const std::uint64_t residual =
      product > exact ? product - exact : exact - product;
  // One nanosecond, expressed in the product's own units.
  if (residual > static_cast<std::uint64_t>(kOpusOutputSampleRate)) {
    return std::nullopt;
  }
  if (frames > kMaximumOpusPacketFrames) {
    return std::nullopt;
  }
  return static_cast<std::uint32_t>(frames);
}

static_assert(kOpusDecoderDelayFrames == 120U,
              "the AudioToolbox Opus decoder lead-in is 2.5 ms at 48 kHz");
static_assert(kMaximumOpusPacketFrames ==
                  kOpusOutputSampleRate / 1000U * 120U,
              "an Opus packet is at most 120 ms");
static_assert(static_cast<std::uint32_t>(kMaximumOpusFramesPerPacket) *
                      (kOpusOutputSampleRate / 400U) ==
                  kMaximumOpusPacketFrames,
              "48 frames of 2.5 ms is exactly the 120 ms packet ceiling");

} // namespace wam::media::matroska
