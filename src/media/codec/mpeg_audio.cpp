#include "media/codec/mpeg_audio.hpp"

#include <array>

namespace wam::media::codec {
namespace {

// Bit rates in kbit/s indexed by bitrate_index: MPEG-1 layers I/II/III, then
// MPEG-2/2.5 layers I and II+III. Index 0 is "free format" (the rate is not
// stated anywhere in the stream) and index 15 is reserved; both are refused,
// so the frame length is always computable.
constexpr std::array<std::uint16_t, 15> kV1L1{
    0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448};
constexpr std::array<std::uint16_t, 15> kV1L2{
    0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384};
constexpr std::array<std::uint16_t, 15> kV1L3{
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320};
constexpr std::array<std::uint16_t, 15> kV2L1{
    0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256};
constexpr std::array<std::uint16_t, 15> kV2L23{
    0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160};

// MPEG-1 sampling rates by sampling_frequency; MPEG-2 halves and MPEG-2.5
// quarters them. Index 3 is reserved.
constexpr std::array<std::uint32_t, 3> kBaseSampleRates{44'100U, 48'000U,
                                                        32'000U};

constexpr std::uint8_t kMonoChannelMode{3};

[[nodiscard]] MpegAudioAdmission
failure(MpegAudioAdmissionError error) noexcept {
  return MpegAudioAdmission{error, std::nullopt};
}

// The Matroska rule on top of the shared reader: MPEG-1 Layer III only.
[[nodiscard]] MpegAudioAdmissionError
readMatroskaFrameHeader(std::span<const std::byte> bytes,
                        MpegAudioFrame &frame) noexcept {
  const MpegAudioAdmissionError error = readMpegAudioFrameHeader(bytes, frame);
  if (error == MpegAudioAdmissionError::TruncatedFrameHeader ||
      error == MpegAudioAdmissionError::UnexpectedSyncword ||
      error == MpegAudioAdmissionError::UnsupportedVersion) {
    return error;
  }
  if (frame.version != 1U) {
    return MpegAudioAdmissionError::UnsupportedVersion;
  }
  if (error == MpegAudioAdmissionError::UnsupportedLayer || frame.layer != 3U) {
    return MpegAudioAdmissionError::UnsupportedLayer;
  }
  return error;
}

[[nodiscard]] std::uint32_t readBigEndian32(std::span<const std::byte> bytes,
                                            std::size_t offset) noexcept {
  std::uint32_t value = 0;
  for (std::size_t index = 0; index < 4U; ++index) {
    value = (value << 8U) |
            std::to_integer<std::uint32_t>(bytes[offset + index]);
  }
  return value;
}

} // namespace

MpegAudioAdmissionError
readMpegAudioFrameHeader(std::span<const std::byte> bytes,
                         MpegAudioFrame &frame) noexcept {
  frame = MpegAudioFrame{};
  if (bytes.size() < kMpegAudioFrameHeaderBytes) {
    return MpegAudioAdmissionError::TruncatedFrameHeader;
  }
  const auto byte1 = std::to_integer<std::uint8_t>(bytes[1]);
  const auto byte2 = std::to_integer<std::uint8_t>(bytes[2]);
  const auto byte3 = std::to_integer<std::uint8_t>(bytes[3]);
  // 11 sync bits.
  if (std::to_integer<std::uint8_t>(bytes[0]) != 0xFFU ||
      (byte1 & 0xE0U) != 0xE0U) {
    return MpegAudioAdmissionError::UnexpectedSyncword;
  }
  const std::uint8_t versionBits = (byte1 >> 3U) & 0x03U;
  const std::uint8_t layerBits = (byte1 >> 1U) & 0x03U;
  if (versionBits == 1U) {
    return MpegAudioAdmissionError::UnsupportedVersion;
  }
  frame.version = versionBits == 3U ? 1U : (versionBits == 2U ? 2U : 3U);
  if (layerBits == 0U) {
    return MpegAudioAdmissionError::UnsupportedLayer;
  }
  frame.layer = static_cast<std::uint8_t>(4U - layerBits);

  const std::uint8_t bitRateIndex = (byte2 >> 4U) & 0x0FU;
  const std::uint8_t sampleRateIndex = (byte2 >> 2U) & 0x03U;
  if (bitRateIndex == 0U || bitRateIndex == 15U) {
    return MpegAudioAdmissionError::UnsupportedBitRateIndex;
  }
  if (sampleRateIndex == 3U) {
    return MpegAudioAdmissionError::ReservedSampleRate;
  }
  const std::uint32_t padding = (byte2 >> 1U) & 0x01U;
  frame.channels = ((byte3 >> 6U) & 0x03U) == kMonoChannelMode ? 1U : 2U;
  frame.sampleRate =
      kBaseSampleRates[sampleRateIndex] >> (frame.version - 1U);

  std::uint32_t kbps = 0;
  if (frame.version == 1U) {
    kbps = frame.layer == 1U   ? kV1L1[bitRateIndex]
           : frame.layer == 2U ? kV1L2[bitRateIndex]
                               : kV1L3[bitRateIndex];
    frame.samplesPerFrame = frame.layer == 1U ? 384U : 1'152U;
  } else {
    kbps = frame.layer == 1U ? kV2L1[bitRateIndex] : kV2L23[bitRateIndex];
    frame.samplesPerFrame = frame.layer == 1U   ? 384U
                            : frame.layer == 2U ? 1'152U
                                                : 576U;
  }
  const std::uint32_t bitsPerSecond = kbps * 1'000U;
  if (frame.layer == 1U) {
    // Layer I counts 4-byte slots.
    frame.frameBytes = ((12U * bitsPerSecond / frame.sampleRate) + padding) * 4U;
  } else {
    frame.frameBytes =
        (frame.samplesPerFrame / 8U * bitsPerSecond / frame.sampleRate) +
        padding;
  }
  if (frame.frameBytes < kMpegAudioFrameHeaderBytes) {
    return MpegAudioAdmissionError::FrameSizeMismatch;
  }
  return MpegAudioAdmissionError::None;
}

MpegAudioAdmission
parseMpegAudioFrameHeader(std::span<const std::byte> frame) noexcept {
  MpegAudioFrame parsed;
  const MpegAudioAdmissionError error = readMatroskaFrameHeader(frame, parsed);
  if (error != MpegAudioAdmissionError::None) {
    return failure(error);
  }
  if (parsed.frameBytes != frame.size()) {
    return failure(MpegAudioAdmissionError::FrameSizeMismatch);
  }
  MpegAudioConfiguration configuration;
  configuration.sampleRate = parsed.sampleRate;
  configuration.channelCount = parsed.channels;
  configuration.samplesPerAccessUnit = kMpegLayer3SamplesPerAccessUnit;
  configuration.frameBytes = parsed.frameBytes;
  return MpegAudioAdmission{MpegAudioAdmissionError::None, configuration};
}

bool mpegAudioFrameMatches(
    std::span<const std::byte> header, std::uint64_t frameBytes,
    const MpegAudioConfiguration &configuration) noexcept {
  MpegAudioFrame parsed;
  if (readMatroskaFrameHeader(header, parsed) !=
      MpegAudioAdmissionError::None) {
    return false;
  }
  return parsed.sampleRate == configuration.sampleRate &&
         parsed.channels == configuration.channelCount &&
         static_cast<std::uint64_t>(parsed.frameBytes) == frameBytes;
}

std::optional<Mp3LameGapless>
inspectMp3LsfGapless(std::span<const std::byte> bytes) noexcept {
  MpegAudioFrame frame;
  if (readMpegAudioFrameHeader(bytes, frame) != MpegAudioAdmissionError::None ||
      frame.version == 1U || frame.layer != 3U ||
      bytes.size() < frame.frameBytes) {
    return std::nullopt;
  }
  const auto u = [&](std::size_t i) {
    return std::to_integer<std::uint32_t>(bytes[i]);
  };
  const auto be32 = [&](std::size_t i) { return readBigEndian32(bytes, i); };
  const std::size_t frameBytes = frame.frameBytes;
  // Side information is 9 bytes mono / 17 stereo, after a 2-byte CRC when the
  // protection bit is clear.
  std::size_t offset =
      4U + (frame.channels == 1U ? 9U : 17U) + ((u(1) & 1U) ? 0U : 2U);
  if (offset + 8 > frameBytes ||
      (be32(offset) != 0x58696e67U && be32(offset) != 0x496e666fU))
    return std::nullopt;
  const auto flags = be32(offset + 4);
  offset += 8;
  if ((flags & 1U) == 0 || (flags & ~15U) != 0 || offset + 4 > frameBytes)
    return std::nullopt;
  const auto frames = be32(offset);
  offset += 4;
  if (flags & 2U)
    offset += 4;
  if (flags & 4U)
    offset += 100;
  if (flags & 8U)
    offset += 4;
  if (offset + 24 > frameBytes ||
      (be32(offset) != 0x4c414d45U && be32(offset) != 0x4c617663U))
    return std::nullopt;
  const auto delay = (u(offset + 21) << 4U) | (u(offset + 22) >> 4U);
  const auto padding = ((u(offset + 22) & 15U) << 8U) | u(offset + 23);
  const auto total =
      static_cast<std::uint64_t>(frames) * frame.samplesPerFrame;
  if (frames == 0 || delay == 0 || total <= delay + padding)
    return std::nullopt;
  return Mp3LameGapless{frame.sampleRate, delay, total - delay - padding};
}

} // namespace wam::media::codec
