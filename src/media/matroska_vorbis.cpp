#include "media/matroska_vorbis.hpp"

#include <array>
#include <bit>
#include <limits>

namespace wam::media::matroska {
namespace {

constexpr std::array<std::byte, 6> kVorbisMagic{
    std::byte{'v'}, std::byte{'o'}, std::byte{'r'},
    std::byte{'b'}, std::byte{'i'}, std::byte{'s'}};

constexpr std::uint8_t kIdentificationHeaderType{1};
constexpr std::uint8_t kCommentHeaderType{3};
constexpr std::uint8_t kSetupHeaderType{5};

// Why equal block sizes are required.
//
// A Vorbis packet decodes to (blocksize[n-1] + blocksize[n]) / 4 frames, so a
// stream whose two block sizes differ has a per-packet duration that depends on
// its predecessor. This demuxer's audio timeline is built on a constant
// frames-per-access-unit grid: a container tick is projected onto an access
// unit ordinal, the ordinal is projected back to an exact presentation time,
// and seeks convert a PCM frame to an ordinal by division. None of that can
// represent a variable-duration packet stream.
//
// When the two block sizes are equal every packet is exactly blocksize/2
// frames and the grid is exactly right, so the gate is not a heuristic -- it is
// the precise condition under which the existing machinery is sound.
//
// Measured consequence, recorded honestly: ffmpeg's native Vorbis encoder emits
// 2048/2048 and is admitted; reference libvorbis emits 256/2048 at every
// quality setting and is refused, falling back to mpv exactly as before this
// work. Closing that gap needs a per-packet duration oracle and a cumulative
// position table rather than an affine grid.
constexpr bool kUniformBlockSizeRationale{true};
static_assert(kUniformBlockSizeRationale);

[[nodiscard]] std::uint32_t readLittleEndian32(std::span<const std::byte> bytes,
                                               std::size_t offset) noexcept {
  return static_cast<std::uint32_t>(
             std::to_integer<std::uint8_t>(bytes[offset])) |
         (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset + 1U]))
          << 8U) |
         (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset + 2U]))
          << 16U) |
         (static_cast<std::uint32_t>(
              std::to_integer<std::uint8_t>(bytes[offset + 3U]))
          << 24U);
}

[[nodiscard]] bool hasVorbisMagic(std::span<const std::byte> header,
                                  std::uint8_t type) noexcept {
  if (header.size() < 1U + kVorbisMagic.size()) {
    return false;
  }
  if (std::to_integer<std::uint8_t>(header[0]) != type) {
    return false;
  }
  for (std::size_t index = 0; index < kVorbisMagic.size(); ++index) {
    if (header[index + 1U] != kVorbisMagic[index]) {
      return false;
    }
  }
  return true;
}

[[nodiscard]] bool validBlockSize(std::uint32_t size) noexcept {
  return size >= kMinimumVorbisBlockSize && size <= kMaximumVorbisBlockSize &&
         std::has_single_bit(size);
}

[[nodiscard]] VorbisAdmission failure(VorbisAdmissionError error) noexcept {
  return VorbisAdmission{error, std::nullopt};
}

} // namespace

VorbisAdmission
parseVorbisCodecPrivate(std::span<const std::byte> bytes) noexcept {
  // Smallest legal blob: count byte, two lacing bytes, and three headers of
  // which the identification header alone is 30 bytes.
  if (bytes.size() < 3U + kVorbisIdentificationHeaderBytes) {
    return failure(VorbisAdmissionError::InvalidCodecPrivateSize);
  }
  if (std::to_integer<std::uint8_t>(bytes[0]) != kVorbisHeaderCount - 1U) {
    return failure(VorbisAdmissionError::UnexpectedPacketCount);
  }

  // Xiph lacing: the first two header lengths are stated as a run of 255 bytes
  // terminated by a byte below 255; the third is whatever remains. The
  // accumulation is bounded against the blob's own size at every step so a
  // hostile run can neither overflow nor outrun the buffer.
  std::array<std::size_t, kVorbisHeaderCount> lengths{};
  std::size_t cursor = 1;
  std::size_t stated = 0;
  for (std::size_t header = 0; header + 1U < kVorbisHeaderCount; ++header) {
    std::size_t length = 0;
    for (;;) {
      if (cursor >= bytes.size()) {
        return failure(VorbisAdmissionError::MalformedLacing);
      }
      const auto part = std::to_integer<std::uint8_t>(bytes[cursor++]);
      if (length > bytes.size() - part) {
        return failure(VorbisAdmissionError::MalformedLacing);
      }
      length += part;
      if (part != 255U) {
        break;
      }
    }
    if (stated > bytes.size() - length) {
      return failure(VorbisAdmissionError::MalformedLacing);
    }
    stated += length;
    lengths[header] = length;
  }
  if (cursor > bytes.size() - stated) {
    return failure(VorbisAdmissionError::TruncatedHeader);
  }
  // The third header takes every remaining byte, so a blob whose lacing does
  // not account for its own size is refused rather than silently trailing.
  lengths[kVorbisHeaderCount - 1U] = bytes.size() - cursor - stated;
  if (lengths[kVorbisHeaderCount - 1U] == 0) {
    return failure(VorbisAdmissionError::TruncatedHeader);
  }

  std::array<std::span<const std::byte>, kVorbisHeaderCount> headers{};
  for (std::size_t header = 0; header < kVorbisHeaderCount; ++header) {
    headers[header] = bytes.subspan(cursor, lengths[header]);
    cursor += lengths[header];
  }

  const std::span<const std::byte> identification = headers[0];
  if (identification.size() != kVorbisIdentificationHeaderBytes) {
    return failure(VorbisAdmissionError::InvalidIdentificationHeaderSize);
  }
  if (!hasVorbisMagic(identification, kIdentificationHeaderType) ||
      !hasVorbisMagic(headers[1], kCommentHeaderType) ||
      !hasVorbisMagic(headers[2], kSetupHeaderType)) {
    return failure(VorbisAdmissionError::UnexpectedMagic);
  }
  if (readLittleEndian32(identification, 7) != 0U) {
    return failure(VorbisAdmissionError::UnsupportedVersion);
  }

  VorbisConfiguration configuration;
  configuration.channelCount =
      std::to_integer<std::uint8_t>(identification[11]);
  if (configuration.channelCount != 1U && configuration.channelCount != 2U) {
    return failure(VorbisAdmissionError::UnsupportedChannelCount);
  }
  configuration.sampleRate = readLittleEndian32(identification, 12);
  if (configuration.sampleRate == 0U ||
      configuration.sampleRate >
          static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())) {
    return failure(VorbisAdmissionError::UnsupportedSampleRate);
  }

  const auto packed = std::to_integer<std::uint8_t>(identification[28]);
  configuration.blockSize0 = 1U << (packed & 0x0FU);
  configuration.blockSize1 = 1U << (packed >> 4U);
  if (!validBlockSize(configuration.blockSize0) ||
      !validBlockSize(configuration.blockSize1) ||
      configuration.blockSize0 > configuration.blockSize1) {
    return failure(VorbisAdmissionError::InvalidBlockSize);
  }
  if (configuration.blockSize0 != configuration.blockSize1) {
    return failure(VorbisAdmissionError::VariableBlockSize);
  }
  if ((std::to_integer<std::uint8_t>(identification[29]) & 0x01U) == 0U) {
    return failure(VorbisAdmissionError::MissingFramingBit);
  }

  return VorbisAdmission{VorbisAdmissionError::None, configuration};
}

std::optional<std::uint32_t>
vorbisFramesFromNanoseconds(std::int64_t nanoseconds,
                            std::uint32_t sampleRate) noexcept {
  if (nanoseconds < 0 || sampleRate == 0U) {
    return std::nullopt;
  }
  const auto magnitude = static_cast<std::uint64_t>(nanoseconds);
  // Bound the magnitude BEFORE forming the product so a hostile value can never
  // wrap the multiplication. One frame past the ceiling, so the frame-count
  // check below -- not this overflow guard -- is what states the ceiling.
  const std::uint64_t maximumNanoseconds =
      UINT64_C(1'000'000'000) *
      (static_cast<std::uint64_t>(kMaximumVorbisPacketFrames) + 1U) /
      static_cast<std::uint64_t>(sampleRate);
  if (magnitude > maximumNanoseconds) {
    return std::nullopt;
  }
  const std::uint64_t product =
      magnitude * static_cast<std::uint64_t>(sampleRate);
  const std::uint64_t frames =
      (product + UINT64_C(500'000'000)) / UINT64_C(1'000'000'000);
  const std::uint64_t exact = frames * UINT64_C(1'000'000'000);
  const std::uint64_t residual =
      product > exact ? product - exact : exact - product;
  // One nanosecond, expressed in the product's own units.
  if (residual > static_cast<std::uint64_t>(sampleRate)) {
    return std::nullopt;
  }
  if (frames > kMaximumVorbisPacketFrames) {
    return std::nullopt;
  }
  return static_cast<std::uint32_t>(frames);
}

static_assert(kMaximumVorbisPacketFrames == 4'096U,
              "the largest Vorbis packet is half the 8192-frame block");
static_assert(std::has_single_bit(kMinimumVorbisBlockSize) &&
                  std::has_single_bit(kMaximumVorbisBlockSize),
              "Vorbis block sizes are powers of two");

} // namespace wam::media::matroska
