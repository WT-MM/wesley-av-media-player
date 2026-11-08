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

// Vorbis I 4.2.4: the setup header ends with mode_count - 1 (6 bits), then
// per mode a blockflag (1), windowtype (16, zero), transformtype (16, zero) and
// mapping (8), then the framing bit. Everything before the modes is
// variable-length, so the table is located backwards from the framing bit, the
// way liboggz and ffmpeg's vorbis parser do: walk back over 41-bit entries
// whose fixed fields are zero, and take the largest count the preceding six
// bits agree with. A false match is caught downstream: every packet duration
// derived from it is proved against the container timestamps.
constexpr std::size_t kModeEntryBits{41};
constexpr std::uint8_t kMaximumModes{64};

[[nodiscard]] bool setupBit(std::span<const std::byte> bytes,
                            std::size_t bit) noexcept {
  return ((std::to_integer<std::uint8_t>(bytes[bit / 8U]) >> (bit % 8U)) &
          1U) != 0U;
}

[[nodiscard]] std::uint32_t setupField(std::span<const std::byte> bytes,
                                       std::size_t bit,
                                       std::size_t width) noexcept {
  std::uint32_t value = 0;
  for (std::size_t index = 0; index < width; ++index) {
    value |= static_cast<std::uint32_t>(setupBit(bytes, bit + index)) << index;
  }
  return value;
}

[[nodiscard]] bool parseModeTable(std::span<const std::byte> setup,
                                  VorbisConfiguration* configuration) noexcept {
  // The type byte and magic precede every field.
  constexpr std::size_t kFloorBits{7U * 8U};
  std::size_t framing = setup.size() * 8U;
  while (framing > kFloorBits && !setupBit(setup, framing - 1U)) {
    --framing;
  }
  if (framing <= kFloorBits) {
    return false;
  }
  const std::size_t end = framing - 1U;
  std::size_t count = 0;
  std::size_t found = 0;
  for (std::size_t entry = end;
       entry >= kFloorBits + kModeEntryBits + 6U && count < kMaximumModes;) {
    entry -= kModeEntryBits;
    if (setupField(setup, entry + 1U, 16U) != 0U ||
        setupField(setup, entry + 17U, 16U) != 0U ||
        setupField(setup, entry + 33U, 8U) >= kMaximumModes) {
      break;
    }
    ++count;
    if (setupField(setup, entry - 6U, 6U) + 1U == count) {
      found = count;
    }
  }
  if (found == 0) {
    return false;
  }
  configuration->modeCount = static_cast<std::uint8_t>(found);
  for (std::size_t mode = 0; mode < found; ++mode) {
    if (setupBit(setup, end - kModeEntryBits * (found - mode))) {
      configuration->longModes |= std::uint64_t{1} << mode;
    }
  }
  return true;
}

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
  if ((std::to_integer<std::uint8_t>(identification[29]) & 0x01U) == 0U) {
    return failure(VorbisAdmissionError::MissingFramingBit);
  }
  if (configuration.variableBlockSize() &&
      !parseModeTable(headers[2], &configuration)) {
    return failure(VorbisAdmissionError::UnreadableModeTable);
  }

  return VorbisAdmission{VorbisAdmissionError::None, configuration};
}

std::optional<std::uint32_t>
vorbisPacketBlockSize(const VorbisConfiguration &configuration,
                      std::byte first) noexcept {
  const auto byte = std::to_integer<std::uint8_t>(first);
  if ((byte & 1U) != 0U) {
    return std::nullopt;
  }
  if (!configuration.variableBlockSize()) {
    return configuration.blockSize0;
  }
  // ilog(modeCount - 1) bits; at most six, so the first byte holds them.
  const unsigned bits = static_cast<unsigned>(
      std::bit_width(static_cast<unsigned>(configuration.modeCount - 1U)));
  const unsigned mode = (byte >> 1U) & ((1U << bits) - 1U);
  if (mode >= configuration.modeCount) {
    return std::nullopt;
  }
  return ((configuration.longModes >> mode) & 1U) != 0U
             ? configuration.blockSize1
             : configuration.blockSize0;
}

static_assert(kMaximumVorbisPacketFrames == 4'096U,
              "the largest Vorbis packet is half the 8192-frame block");
static_assert(std::has_single_bit(kMinimumVorbisBlockSize) &&
                  std::has_single_bit(kMaximumVorbisBlockSize),
              "Vorbis block sizes are powers of two");

} // namespace wam::media::matroska
