#include "media/matroska_flac.hpp"

#include <limits>

namespace wam::media::matroska {
namespace {

constexpr std::array<std::byte, kFlacStreamMarkerBytes> kFlacStreamMarker{
    std::byte{'f'}, std::byte{'L'}, std::byte{'a'}, std::byte{'C'}};

constexpr std::uint8_t kStreamInfoBlockType{0};
constexpr std::uint8_t kLastMetadataBlockFlag{0x80};
constexpr std::uint8_t kMetadataBlockTypeMask{0x7F};
// 127 is "invalid" by the FLAC specification.
constexpr std::uint8_t kInvalidMetadataBlockType{127};

constexpr std::array<std::byte, 4> kDflaBoxType{
    std::byte{'d'}, std::byte{'f'}, std::byte{'L'}, std::byte{'a'}};

[[nodiscard]] std::uint32_t
readBigEndian24(std::span<const std::byte> bytes, std::size_t offset) noexcept {
  return (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset]))
          << 16U) |
         (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset + 1U]))
          << 8U) |
         static_cast<std::uint32_t>(
             std::to_integer<std::uint8_t>(bytes[offset + 2U]));
}

[[nodiscard]] std::uint32_t
readBigEndian16(std::span<const std::byte> bytes, std::size_t offset) noexcept {
  return (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset]))
          << 8U) |
         static_cast<std::uint32_t>(
             std::to_integer<std::uint8_t>(bytes[offset + 1U]));
}

[[nodiscard]] FlacAdmission failure(FlacAdmissionError error) noexcept {
  return FlacAdmission{error, std::nullopt};
}

[[nodiscard]] bool hasStreamMarker(std::span<const std::byte> bytes) noexcept {
  if (bytes.size() < kFlacStreamMarker.size()) {
    return false;
  }
  for (std::size_t index = 0; index < kFlacStreamMarker.size(); ++index) {
    if (bytes[index] != kFlacStreamMarker[index]) {
      return false;
    }
  }
  return true;
}

// Walks the metadata block chain. Every block's declared length is bounded
// against the blob's remaining size, and the chain must terminate exactly at
// the end of the blob: a CodecPrivate with trailing bytes, or one whose last
// block never sets the last-block flag, is a blob this source does not
// understand and is refused.
//
// Returns false for a malformed chain. A well-formed chain that simply carries
// no STREAMINFO leaves `streamInfo` empty and returns true, so the caller can
// tell those two apart -- they are different diagnoses, and collapsing them
// once cost this parser a test.
[[nodiscard]] bool
walkMetadataBlocks(std::span<const std::byte> bytes,
                   std::span<const std::byte> *streamInfo) noexcept {
  std::size_t cursor = kFlacStreamMarker.size();
  bool sawStreamInfo = false;
  bool sawLast = false;
  *streamInfo = {};
  while (cursor < bytes.size()) {
    if (sawLast) {
      return false; // a block after the one flagged last
    }
    if (bytes.size() - cursor < kFlacMetadataBlockHeaderBytes) {
      return false;
    }
    const auto header = std::to_integer<std::uint8_t>(bytes[cursor]);
    const std::uint8_t type = header & kMetadataBlockTypeMask;
    sawLast = (header & kLastMetadataBlockFlag) != 0U;
    const std::uint32_t length = readBigEndian24(bytes, cursor + 1U);
    cursor += kFlacMetadataBlockHeaderBytes;
    if (type == kInvalidMetadataBlockType || length > bytes.size() - cursor) {
      return false;
    }
    if (type == kStreamInfoBlockType) {
      if (sawStreamInfo || length != kFlacStreamInfoBytes) {
        return false; // STREAMINFO must appear exactly once, at its own size
      }
      sawStreamInfo = true;
      *streamInfo = bytes.subspan(cursor, kFlacStreamInfoBytes);
    }
    cursor += length;
  }
  return sawLast && cursor == bytes.size();
}

} // namespace

FlacAdmission
parseFlacCodecPrivate(std::span<const std::byte> bytes) noexcept {
  if (bytes.size() < kFlacStreamMarkerBytes + kFlacMetadataBlockHeaderBytes +
                         kFlacStreamInfoBytes) {
    return failure(FlacAdmissionError::InvalidCodecPrivateSize);
  }
  if (!hasStreamMarker(bytes)) {
    return failure(FlacAdmissionError::UnexpectedMagic);
  }
  std::span<const std::byte> info;
  if (!walkMetadataBlocks(bytes, &info)) {
    return failure(FlacAdmissionError::MalformedMetadataBlocks);
  }
  if (info.empty()) {
    return failure(FlacAdmissionError::MissingStreamInfo);
  }

  FlacConfiguration configuration;
  const std::uint32_t minimumBlockSize = readBigEndian16(info, 0);
  const std::uint32_t maximumBlockSize = readBigEndian16(info, 2);
  if (minimumBlockSize < kMinimumFlacBlockSize ||
      maximumBlockSize < kMinimumFlacBlockSize ||
      maximumBlockSize > kMaximumFlacBlockSize ||
      minimumBlockSize > maximumBlockSize) {
    return failure(FlacAdmissionError::InvalidBlockSize);
  }
  if (minimumBlockSize != maximumBlockSize) {
    // Every frame but the last must be the same length for the demuxer's
    // affine ordinal grid to place a Block's timestamp on an access unit. The
    // FINAL frame being shorter is fine and expected -- nothing is placed
    // after it, and the exact duration comes from totalSamples rather than
    // from the grid.
    return failure(FlacAdmissionError::VariableBlockSize);
  }
  configuration.blockSize = maximumBlockSize;

  // Bits 0..19 sample rate, 20..22 channels - 1, 23..27 bits per sample - 1,
  // 28..63 total samples: a 64-bit field that straddles no byte boundary
  // conveniently, so it is read whole.
  std::uint64_t packed = 0;
  for (std::size_t index = 10; index < 18U; ++index) {
    packed = (packed << 8U) |
             static_cast<std::uint64_t>(std::to_integer<std::uint8_t>(info[index]));
  }
  configuration.sampleRate = static_cast<std::uint32_t>(packed >> 44U);
  configuration.channelCount =
      static_cast<std::uint8_t>(((packed >> 41U) & 0x07U) + 1U);
  configuration.bitsPerSample =
      static_cast<std::uint8_t>(((packed >> 36U) & 0x1FU) + 1U);
  configuration.totalSamples = packed & ((UINT64_C(1) << 36U) - 1U);

  if (configuration.channelCount != 1U && configuration.channelCount != 2U) {
    return failure(FlacAdmissionError::UnsupportedChannelCount);
  }
  if (configuration.sampleRate == 0U ||
      configuration.sampleRate >
          static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())) {
    return failure(FlacAdmissionError::UnsupportedSampleRate);
  }
  // The format allows 4..32; AudioToolbox was measured bit-exact at 16 and 24.
  if (configuration.bitsPerSample < 4U || configuration.bitsPerSample > 32U) {
    return failure(FlacAdmissionError::UnsupportedBitDepth);
  }
  if (configuration.totalSamples == 0U) {
    return failure(FlacAdmissionError::UnknownTotalSamples);
  }
  return FlacAdmission{FlacAdmissionError::None, configuration};
}

std::optional<FlacMagicCookie>
buildFlacMagicCookie(std::span<const std::byte> codecPrivate) noexcept {
  if (!hasStreamMarker(codecPrivate)) {
    return std::nullopt;
  }
  std::span<const std::byte> streamInfo;
  if (!walkMetadataBlocks(codecPrivate, &streamInfo) || streamInfo.empty()) {
    return std::nullopt;
  }
  FlacMagicCookie cookie;
  std::size_t cursor = 0;
  const auto put = [&cookie, &cursor](std::uint8_t value) noexcept {
    cookie.bytes[cursor++] = std::byte{value};
  };
  // Box size, big-endian, covering the size and type fields themselves.
  const auto size = static_cast<std::uint32_t>(kFlacMagicCookieBytes);
  put(static_cast<std::uint8_t>((size >> 24U) & 0xFFU));
  put(static_cast<std::uint8_t>((size >> 16U) & 0xFFU));
  put(static_cast<std::uint8_t>((size >> 8U) & 0xFFU));
  put(static_cast<std::uint8_t>(size & 0xFFU));
  for (const std::byte value : kDflaBoxType) {
    cookie.bytes[cursor++] = value;
  }
  // FullBox version and flags, all zero.
  put(0U);
  put(0U);
  put(0U);
  put(0U);
  // One metadata block: STREAMINFO, flagged last because it is the only one.
  put(kLastMetadataBlockFlag | kStreamInfoBlockType);
  put(0U);
  put(0U);
  put(static_cast<std::uint8_t>(kFlacStreamInfoBytes));
  for (const std::byte value : streamInfo) {
    cookie.bytes[cursor++] = value;
  }
  if (cursor != kFlacMagicCookieBytes) {
    return std::nullopt;
  }
  return cookie;
}

static_assert(kFlacMagicCookieBytes == 50U,
              "the dfLa cookie Apple's own FLAC parser emits is 50 bytes");

} // namespace wam::media::matroska
