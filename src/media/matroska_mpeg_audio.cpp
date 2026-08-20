#include "media/matroska_mpeg_audio.hpp"

#include <array>

namespace wam::media::matroska {
namespace {

// MPEG-1 Layer III bit rates in kbit/s, indexed by the header's bitrate_index.
// Index 0 is "free format" (the rate is not stated anywhere in the stream) and
// index 15 is reserved; both are refused, so the frame length below is always
// computable.
constexpr std::array<std::uint16_t, 16> kBitRateByIndex{
    0U,   32U,  40U,  48U,  56U,  64U,  80U,  96U,
    112U, 128U, 160U, 192U, 224U, 256U, 320U, 0U};

// MPEG-1 sampling rates, indexed by the header's sampling_frequency field.
constexpr std::array<std::uint32_t, 4> kSampleRateByIndex{44'100U, 48'000U,
                                                          32'000U, 0U};

constexpr std::uint8_t kMpegVersion1{3};
constexpr std::uint8_t kLayer3{1};
constexpr std::uint8_t kMonoChannelMode{3};

// Layer III frames hold 12 slots per 1 kbit/s per kHz; the constant is the
// specification's 144 = 1152 / 8.
constexpr std::uint32_t kLayer3BytesPerKilobitSecond{144};

struct ParsedHeader {
  std::uint32_t sampleRate{0};
  std::uint8_t channelCount{0};
  std::uint32_t frameBytes{0};
};

[[nodiscard]] MpegAudioAdmission
failure(MpegAudioAdmissionError error) noexcept {
  return MpegAudioAdmission{error, std::nullopt};
}

[[nodiscard]] MpegAudioAdmissionError
parseHeader(std::span<const std::byte> frame, ParsedHeader *parsed) noexcept {
  if (frame.size() < kMpegAudioFrameHeaderBytes) {
    return MpegAudioAdmissionError::TruncatedFrameHeader;
  }
  const auto byte0 = std::to_integer<std::uint8_t>(frame[0]);
  const auto byte1 = std::to_integer<std::uint8_t>(frame[1]);
  const auto byte2 = std::to_integer<std::uint8_t>(frame[2]);
  const auto byte3 = std::to_integer<std::uint8_t>(frame[3]);

  // 11 sync bits.
  if (byte0 != 0xFFU || (byte1 & 0xE0U) != 0xE0U) {
    return MpegAudioAdmissionError::UnexpectedSyncword;
  }
  const std::uint8_t version = (byte1 >> 3U) & 0x03U;
  const std::uint8_t layer = (byte1 >> 1U) & 0x03U;
  if (version != kMpegVersion1) {
    return MpegAudioAdmissionError::UnsupportedVersion;
  }
  if (layer != kLayer3) {
    return MpegAudioAdmissionError::UnsupportedLayer;
  }

  const std::uint8_t bitRateIndex = (byte2 >> 4U) & 0x0FU;
  const std::uint8_t sampleRateIndex = (byte2 >> 2U) & 0x03U;
  const std::uint32_t padding = (byte2 >> 1U) & 0x01U;
  const std::uint8_t channelMode = (byte3 >> 6U) & 0x03U;

  const std::uint32_t kbps = kBitRateByIndex[bitRateIndex];
  if (kbps == 0U) {
    return MpegAudioAdmissionError::UnsupportedBitRateIndex;
  }
  const std::uint32_t sampleRate = kSampleRateByIndex[sampleRateIndex];
  if (sampleRate == 0U) {
    return MpegAudioAdmissionError::ReservedSampleRate;
  }

  parsed->sampleRate = sampleRate;
  parsed->channelCount = channelMode == kMonoChannelMode ? 1U : 2U;
  parsed->frameBytes =
      (kLayer3BytesPerKilobitSecond * kbps * 1'000U / sampleRate) + padding;
  return MpegAudioAdmissionError::None;
}

} // namespace

MpegAudioAdmission
parseMpegAudioFrameHeader(std::span<const std::byte> frame) noexcept {
  ParsedHeader parsed;
  const MpegAudioAdmissionError error = parseHeader(frame, &parsed);
  if (error != MpegAudioAdmissionError::None) {
    return failure(error);
  }
  if (parsed.frameBytes == 0U || parsed.frameBytes != frame.size()) {
    return failure(MpegAudioAdmissionError::FrameSizeMismatch);
  }
  MpegAudioConfiguration configuration;
  configuration.sampleRate = parsed.sampleRate;
  configuration.channelCount = parsed.channelCount;
  configuration.samplesPerAccessUnit = kMpegLayer3SamplesPerAccessUnit;
  configuration.frameBytes = parsed.frameBytes;
  return MpegAudioAdmission{MpegAudioAdmissionError::None, configuration};
}

bool mpegAudioFrameMatches(
    std::span<const std::byte> header, std::uint64_t frameBytes,
    const MpegAudioConfiguration &configuration) noexcept {
  ParsedHeader parsed;
  if (parseHeader(header, &parsed) != MpegAudioAdmissionError::None) {
    return false;
  }
  return parsed.sampleRate == configuration.sampleRate &&
         parsed.channelCount == configuration.channelCount &&
         static_cast<std::uint64_t>(parsed.frameBytes) == frameBytes;
}

static_assert(kMpegLayer3SamplesPerAccessUnit ==
                  kLayer3BytesPerKilobitSecond * 8U,
              "Layer III's 144 bytes per kbit/s per kHz is 1152 samples / 8");

} // namespace wam::media::matroska
