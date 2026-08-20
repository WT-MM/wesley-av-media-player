#include "media/video_codec_configuration.hpp"

#include <algorithm>
#include <array>
#include <limits>

namespace wam::media {
namespace {

using Error = VideoCodecConfigurationError;

[[nodiscard]] VideoCodecConfigurationInspection rejected(Error error) noexcept {
  return {error, std::nullopt};
}

[[nodiscard]] VideoCodecConfigurationLimits
effectiveLimits(VideoCodecConfigurationLimits requested) noexcept {
  requested.maximumConfigurationBytes =
      std::min(requested.maximumConfigurationBytes,
               kMaximumVideoCodecConfigurationBytes);
  requested.maximumWidth =
      std::min(requested.maximumWidth, kMaximumVideoCodecWidth);
  requested.maximumHeight =
      std::min(requested.maximumHeight, kMaximumVideoCodecHeight);
  requested.maximumPixels =
      std::min(requested.maximumPixels, kMaximumVideoCodecPixels);
  requested.maximumReorderFrames =
      std::min(requested.maximumReorderFrames, kMaximumVideoCodecReorderFrames);
  return requested;
}

[[nodiscard]] std::span<const std::uint8_t>
asBytes(std::span<const std::byte> bytes) noexcept {
  return {reinterpret_cast<const std::uint8_t *>(bytes.data()), bytes.size()};
}

[[nodiscard]] std::uint16_t readBigEndian16(std::span<const std::uint8_t> bytes,
                                            std::size_t offset) noexcept {
  return static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(bytes[offset]) << 8U) |
      static_cast<std::uint16_t>(bytes[offset + 1U]));
}

[[nodiscard]] std::uint32_t readBigEndian32(std::span<const std::uint8_t> bytes,
                                            std::size_t offset) noexcept {
  return (static_cast<std::uint32_t>(bytes[offset]) << 24U) |
         (static_cast<std::uint32_t>(bytes[offset + 1U]) << 16U) |
         (static_cast<std::uint32_t>(bytes[offset + 2U]) << 8U) |
         static_cast<std::uint32_t>(bytes[offset + 3U]);
}

class RbspBitReader final {
public:
  explicit RbspBitReader(std::span<const std::uint8_t> escapedBytes) noexcept
      : bytes_(escapedBytes) {}

  [[nodiscard]] bool readBit(bool &value) noexcept {
    std::uint32_t bit = 0;
    if (!readBits(1U, bit)) {
      return false;
    }
    value = bit != 0U;
    return true;
  }

  [[nodiscard]] bool readBits(std::size_t count,
                              std::uint32_t &value) noexcept {
    if (count > 32U) {
      return false;
    }
    value = 0;
    for (std::size_t index = 0; index < count; ++index) {
      if (bitsRemaining_ == 0U && !loadByte()) {
        return false;
      }
      value = static_cast<std::uint32_t>(
          (value << 1U) | ((currentByte_ >> (bitsRemaining_ - 1U)) & 1U));
      --bitsRemaining_;
    }
    return true;
  }

  [[nodiscard]] bool skipBits(std::size_t count) noexcept {
    while (count != 0U) {
      const std::size_t chunk = std::min<std::size_t>(count, 32U);
      std::uint32_t ignored = 0;
      if (!readBits(chunk, ignored)) {
        return false;
      }
      count -= chunk;
    }
    return true;
  }

  [[nodiscard]] bool readUnsignedExpGolomb(std::uint32_t &value) noexcept {
    std::size_t leadingZeroBits = 0;
    bool bit = false;
    while (true) {
      if (!readBit(bit)) {
        return false;
      }
      if (bit) {
        break;
      }
      if (++leadingZeroBits > 31U) {
        return false;
      }
    }
    std::uint32_t suffix = 0;
    if (!readBits(leadingZeroBits, suffix)) {
      return false;
    }
    const std::uint64_t decoded =
        ((std::uint64_t{1} << leadingZeroBits) - 1U) + suffix;
    if (decoded > std::numeric_limits<std::uint32_t>::max()) {
      return false;
    }
    value = static_cast<std::uint32_t>(decoded);
    return true;
  }

  [[nodiscard]] bool readSignedExpGolomb(std::int32_t &value) noexcept {
    std::uint32_t encoded = 0;
    if (!readUnsignedExpGolomb(encoded)) {
      return false;
    }
    const std::int64_t magnitude = static_cast<std::int64_t>(
        (static_cast<std::uint64_t>(encoded) + 1U) / 2U);
    const std::int64_t decoded = (encoded & 1U) != 0U ? magnitude : -magnitude;
    if (decoded < std::numeric_limits<std::int32_t>::min() ||
        decoded > std::numeric_limits<std::int32_t>::max()) {
      return false;
    }
    value = static_cast<std::int32_t>(decoded);
    return true;
  }

  // Reports whether syntax bits remain before rbsp_trailing_bits without
  // consuming either. A copied reader is sufficient because the reader owns
  // no storage and carries only bounded scalar state.
  [[nodiscard]] bool moreRbspData(bool &more) const noexcept {
    RbspBitReader probe = *this;
    bool possibleStopBit = false;
    if (!probe.readBit(possibleStopBit)) {
      return false;
    }
    if (!possibleStopBit) {
      more = true;
      return true;
    }
    while (probe.bitsRemaining_ != 0U) {
      bool padding = false;
      if (!probe.readBit(padding)) {
        return false;
      }
      if (padding) {
        more = true;
        return true;
      }
    }
    more = probe.offset_ != probe.bytes_.size();
    return true;
  }

  // Accepted SPS syntax is parsed through rbsp_trailing_bits. This catches
  // both truncation and hidden payload after the claimed syntax without an
  // unescape allocation.
  [[nodiscard]] bool finishRbsp() noexcept {
    bool stopBit = false;
    if (!readBit(stopBit) || !stopBit) {
      return false;
    }
    while (bitsRemaining_ != 0U) {
      bool padding = false;
      if (!readBit(padding) || padding) {
        return false;
      }
    }
    return offset_ == bytes_.size();
  }

private:
  [[nodiscard]] bool loadByte() noexcept {
    while (offset_ < bytes_.size()) {
      const std::uint8_t value = bytes_[offset_++];
      if (zeroCount_ >= 2U && value == 0x03U) {
        if (offset_ >= bytes_.size() || bytes_[offset_] > 0x03U) {
          return false;
        }
        zeroCount_ = 0;
        continue;
      }
      if (zeroCount_ >= 2U && value <= 0x02U) {
        return false;
      }
      zeroCount_ = value == 0U ? zeroCount_ + 1U : 0U;
      currentByte_ = value;
      bitsRemaining_ = 8U;
      return true;
    }
    return false;
  }

  std::span<const std::uint8_t> bytes_;
  std::size_t offset_{0};
  std::size_t zeroCount_{0};
  std::uint8_t currentByte_{0};
  std::size_t bitsRemaining_{0};
};

// AV1 and VP9 headers are plain bit strings: neither codec uses the RBSP
// emulation-prevention escaping that RbspBitReader must undo, and applying
// that unescaping to them would corrupt any header containing 00 00 03. This
// reader is otherwise the same shape -- bounded, allocation-free, and false on
// any read that would run past the supplied bytes.
class PlainBitReader final {
public:
  explicit PlainBitReader(std::span<const std::uint8_t> bytes) noexcept
      : bytes_(bytes) {}

  [[nodiscard]] bool readBit(bool &value) noexcept {
    std::uint32_t bit = 0;
    if (!readBits(1U, bit)) {
      return false;
    }
    value = bit != 0U;
    return true;
  }

  [[nodiscard]] bool readBits(std::size_t count,
                              std::uint32_t &value) noexcept {
    if (count > 32U || count > bitsRemaining()) {
      return false;
    }
    value = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const std::uint8_t current = bytes_[bitOffset_ / 8U];
      const std::size_t shift = 7U - (bitOffset_ % 8U);
      value = (value << 1U) |
              static_cast<std::uint32_t>((current >> shift) & 1U);
      ++bitOffset_;
    }
    return true;
  }

  [[nodiscard]] bool skipBits(std::size_t count) noexcept {
    if (count > bitsRemaining()) {
      return false;
    }
    bitOffset_ += count;
    return true;
  }

  // AV1 uvlc(): a unary prefix of zeroes then that many suffix bits. A prefix
  // of 32 or more is the spec's saturated "value unknown" encoding, which no
  // field this parser needs may legitimately use, so it fails closed.
  [[nodiscard]] bool readUvlc(std::uint32_t &value) noexcept {
    std::size_t leadingZeroBits = 0;
    while (true) {
      bool bit = false;
      if (!readBit(bit)) {
        return false;
      }
      if (bit) {
        break;
      }
      if (++leadingZeroBits >= 32U) {
        return false;
      }
    }
    std::uint32_t suffix = 0;
    if (!readBits(leadingZeroBits, suffix)) {
      return false;
    }
    const std::uint64_t decoded =
        suffix + (std::uint64_t{1} << leadingZeroBits) - 1U;
    if (decoded > std::numeric_limits<std::uint32_t>::max()) {
      return false;
    }
    value = static_cast<std::uint32_t>(decoded);
    return true;
  }

  // AV1 trailing_bits(): a single one bit then zero bits to the byte boundary,
  // and nothing after it.
  [[nodiscard]] bool finishTrailingBits() noexcept {
    bool stopBit = false;
    if (!readBit(stopBit) || !stopBit) {
      return false;
    }
    while ((bitOffset_ % 8U) != 0U) {
      bool padding = false;
      if (!readBit(padding) || padding) {
        return false;
      }
    }
    return bitOffset_ == bytes_.size() * 8U;
  }

  [[nodiscard]] std::size_t bitsRemaining() const noexcept {
    return bytes_.size() * 8U - bitOffset_;
  }

private:
  std::span<const std::uint8_t> bytes_;
  std::size_t bitOffset_{0};
};

// ISO/IEC 23091-2 value 2 is "unspecified": it carries exactly as much color
// information as an absent color description, which this function already
// admits. Rejecting it while admitting absence is not a safety property, it is
// an inconsistency -- and a costly one, because encoders routinely emit an
// explicit matrix with unspecified primaries/transfer. The same stream is
// admitted through AVFoundation today, so refusing it only here would make one
// file play as .mp4 and fail as .mkv. Genuinely out-of-envelope descriptions
// (BT.2020 primaries, PQ/HLG transfer) remain rejected exactly as before.
[[nodiscard]] constexpr bool sdrColorComponentAdmitted(
    std::uint32_t value, std::uint32_t bt709Value) noexcept {
  return value == bt709Value || value == 2U;
}

[[nodiscard]] bool
supportedSdrColor(const VideoCodecColorFacts &color) noexcept {
  if (!color.colorDescriptionPresent) {
    return true;
  }
  return sdrColorComponentAdmitted(color.colorPrimaries, 1U) &&
         sdrColorComponentAdmitted(color.transferCharacteristics, 1U) &&
         (color.matrixCoefficients == 1U || color.matrixCoefficients == 2U ||
          color.matrixCoefficients == 5U || color.matrixCoefficients == 6U);
}

[[nodiscard]] bool parseVuiColorPrefix(RbspBitReader &bits,
                                       VideoCodecColorFacts &color) noexcept {
  bool present = false;
  std::uint32_t value = 0;
  if (!bits.readBit(present)) {
    return false;
  }
  if (present) {
    if (!bits.readBits(8U, value) || (value == 255U && !bits.skipBits(32U))) {
      return false;
    }
  }
  if (!bits.readBit(present) || (present && !bits.skipBits(1U)) ||
      !bits.readBit(color.videoSignalTypePresent)) {
    return false;
  }
  if (!color.videoSignalTypePresent) {
    return true;
  }
  if (!bits.skipBits(3U) || !bits.readBit(color.fullRange) ||
      !bits.readBit(color.colorDescriptionPresent)) {
    return false;
  }
  if (!color.colorDescriptionPresent) {
    return true;
  }
  std::uint32_t primaries = 0;
  std::uint32_t transfer = 0;
  std::uint32_t matrix = 0;
  if (!bits.readBits(8U, primaries) || !bits.readBits(8U, transfer) ||
      !bits.readBits(8U, matrix)) {
    return false;
  }
  color.colorPrimaries = static_cast<std::uint8_t>(primaries);
  color.transferCharacteristics = static_cast<std::uint8_t>(transfer);
  color.matrixCoefficients = static_cast<std::uint8_t>(matrix);
  return true;
}

[[nodiscard]] bool skipH264ScalingList(RbspBitReader &bits,
                                       std::size_t size) noexcept {
  std::int32_t lastScale = 8;
  std::int32_t nextScale = 8;
  for (std::size_t index = 0; index < size; ++index) {
    if (nextScale != 0) {
      std::int32_t deltaScale = 0;
      if (!bits.readSignedExpGolomb(deltaScale) || deltaScale < -128 ||
          deltaScale > 127) {
        return false;
      }
      nextScale = (lastScale + deltaScale + 256) % 256;
    }
    if (nextScale != 0) {
      lastScale = nextScale;
    }
  }
  return true;
}

[[nodiscard]] bool skipH264Hrd(RbspBitReader &bits) noexcept {
  std::uint32_t cpbCountMinusOne = 0;
  if (!bits.readUnsignedExpGolomb(cpbCountMinusOne) || cpbCountMinusOne > 31U ||
      !bits.skipBits(8U)) {
    return false;
  }
  for (std::uint32_t index = 0; index <= cpbCountMinusOne; ++index) {
    std::uint32_t ignored = 0;
    if (!bits.readUnsignedExpGolomb(ignored) ||
        !bits.readUnsignedExpGolomb(ignored) || !bits.skipBits(1U)) {
      return false;
    }
  }
  return bits.skipBits(20U);
}

[[nodiscard]] std::optional<std::uint32_t>
h264MaxDpbMacroblocks(std::uint32_t level, bool level1b) noexcept {
  switch (level) {
  case 9U:
  case 10U:
    return 396U;
  case 11U:
    return level1b ? 396U : 900U;
  case 12U:
  case 13U:
  case 20U:
    return 2376U;
  case 21U:
    return 4752U;
  case 22U:
  case 30U:
    return 8100U;
  case 31U:
    return 18000U;
  case 32U:
    return 20480U;
  case 40U:
  case 41U:
    return 32768U;
  case 42U:
    return 34816U;
  case 50U:
    return 110400U;
  case 51U:
  case 52U:
    return 184320U;
  case 60U:
  case 61U:
  case 62U:
    return 696320U;
  default:
    return std::nullopt;
  }
}

[[nodiscard]] constexpr bool h264HighProfile(std::uint32_t profile) noexcept {
  return profile == 100U;
}

[[nodiscard]] constexpr bool
h264ConstraintSet3ZeroReorder(std::uint32_t profile) noexcept {
  return profile == 100U;
}

[[nodiscard]] constexpr bool
h264ConstraintSet3Level1b(std::uint32_t profile) noexcept {
  return profile == 66U || profile == 77U || profile == 88U;
}

struct ParsedSpsFacts {
  std::uint32_t id{0};
  std::uint32_t dependencyId{0};
  std::uint32_t width{0};
  std::uint32_t height{0};
  std::uint8_t bitDepth{0};
  std::uint8_t reorderFrames{0};
  bool temporalIdNested{false};
  VideoCodecColorFacts color{};
};

[[nodiscard]] Error parseH264Sps(std::span<const std::uint8_t> nal,
                                 std::uint8_t expectedProfile,
                                 std::uint8_t expectedCompatibility,
                                 std::uint8_t expectedLevel,
                                 const VideoCodecConfigurationLimits &limits,
                                 ParsedSpsFacts &facts) noexcept {
  if (nal.size() < 5U || (nal[0] & 0x80U) != 0U || (nal[0] & 0x1FU) != 7U ||
      (nal[0] & 0x60U) == 0U) {
    return Error::MalformedRecord;
  }
  RbspBitReader bits(nal.subspan(1U));
  std::uint32_t profile = 0;
  std::uint32_t compatibility = 0;
  std::uint32_t level = 0;
  if (!bits.readBits(8U, profile) || !bits.readBits(8U, compatibility) ||
      !bits.readBits(8U, level) || profile != expectedProfile ||
      compatibility != expectedCompatibility || level != expectedLevel) {
    return Error::ParameterSetMismatch;
  }
  if ((compatibility & 0x03U) != 0U) {
    return Error::MalformedRecord;
  }
  if (profile != 66U && profile != 77U && profile != 88U && profile != 100U) {
    return Error::UnsupportedProfile;
  }
  if (!bits.readUnsignedExpGolomb(facts.id) || facts.id > 31U) {
    return Error::MalformedRecord;
  }

  std::uint32_t chromaFormat = 1U;
  std::uint32_t lumaDepthMinusEight = 0;
  std::uint32_t chromaDepthMinusEight = 0;
  if (h264HighProfile(profile)) {
    bool scalingMatrixPresent = false;
    if (!bits.readUnsignedExpGolomb(chromaFormat)) {
      return Error::MalformedRecord;
    }
    if (chromaFormat != 1U) {
      return Error::UnsupportedChromaFormat;
    }
    if (!bits.readUnsignedExpGolomb(lumaDepthMinusEight) ||
        !bits.readUnsignedExpGolomb(chromaDepthMinusEight)) {
      return Error::MalformedRecord;
    }
    if (lumaDepthMinusEight != 0U || chromaDepthMinusEight != 0U) {
      return Error::UnsupportedBitDepth;
    }
    if (!bits.skipBits(1U) || !bits.readBit(scalingMatrixPresent)) {
      return Error::MalformedRecord;
    }
    if (scalingMatrixPresent) {
      for (std::size_t index = 0; index < 8U; ++index) {
        bool present = false;
        if (!bits.readBit(present) ||
            (present && !skipH264ScalingList(bits, index < 6U ? 16U : 64U))) {
          return Error::MalformedRecord;
        }
      }
    }
  }
  facts.bitDepth = 8U;

  std::uint32_t ignored = 0;
  std::uint32_t picOrderCountType = 0;
  if (!bits.readUnsignedExpGolomb(ignored) || ignored > 12U ||
      !bits.readUnsignedExpGolomb(picOrderCountType) ||
      picOrderCountType > 2U) {
    return Error::MalformedRecord;
  }
  if (picOrderCountType == 0U) {
    if (!bits.readUnsignedExpGolomb(ignored) || ignored > 12U) {
      return Error::MalformedRecord;
    }
  } else if (picOrderCountType == 1U) {
    std::int32_t ignoredSigned = 0;
    std::uint32_t cycle = 0;
    if (!bits.skipBits(1U) || !bits.readSignedExpGolomb(ignoredSigned) ||
        !bits.readSignedExpGolomb(ignoredSigned) ||
        !bits.readUnsignedExpGolomb(cycle) || cycle > 255U) {
      return Error::MalformedRecord;
    }
    for (std::uint32_t index = 0; index < cycle; ++index) {
      if (!bits.readSignedExpGolomb(ignoredSigned)) {
        return Error::MalformedRecord;
      }
    }
  }

  std::uint32_t maxReferenceFrames = 0;
  std::uint32_t widthMinusOne = 0;
  std::uint32_t heightMapUnitsMinusOne = 0;
  bool frameMbsOnly = false;
  if (!bits.readUnsignedExpGolomb(maxReferenceFrames) || !bits.skipBits(1U) ||
      !bits.readUnsignedExpGolomb(widthMinusOne) ||
      !bits.readUnsignedExpGolomb(heightMapUnitsMinusOne) ||
      !bits.readBit(frameMbsOnly) || (!frameMbsOnly && !bits.skipBits(1U)) ||
      !bits.skipBits(1U)) {
    return Error::MalformedRecord;
  }

  bool cropping = false;
  std::array<std::uint32_t, 4> crop{};
  if (!bits.readBit(cropping)) {
    return Error::MalformedRecord;
  }
  if (cropping) {
    for (std::uint32_t &value : crop) {
      if (!bits.readUnsignedExpGolomb(value)) {
        return Error::MalformedRecord;
      }
    }
  }

  const std::uint64_t widthMbs = static_cast<std::uint64_t>(widthMinusOne) + 1U;
  const std::uint64_t heightMapUnits =
      static_cast<std::uint64_t>(heightMapUnitsMinusOne) + 1U;
  const std::uint64_t frameHeightMultiplier = frameMbsOnly ? 1U : 2U;
  if (widthMbs > std::numeric_limits<std::uint64_t>::max() / 16U ||
      heightMapUnits > std::numeric_limits<std::uint64_t>::max() /
                           (16U * frameHeightMultiplier)) {
    return Error::MalformedRecord;
  }
  const std::uint64_t storageWidth = widthMbs * 16U;
  const std::uint64_t storageHeight =
      heightMapUnits * frameHeightMultiplier * 16U;
  const std::uint64_t cropWidth =
      (static_cast<std::uint64_t>(crop[0]) + crop[1]) * 2U;
  const std::uint64_t cropHeight =
      (static_cast<std::uint64_t>(crop[2]) + crop[3]) *
      (frameMbsOnly ? 2U : 4U);
  if (cropWidth >= storageWidth || cropHeight >= storageHeight) {
    return Error::MalformedRecord;
  }
  const std::uint64_t width = storageWidth - cropWidth;
  const std::uint64_t height = storageHeight - cropHeight;
  if (width > limits.maximumWidth || height > limits.maximumHeight ||
      (height != 0U && width > limits.maximumPixels / height)) {
    return Error::DimensionLimitExceeded;
  }
  facts.width = static_cast<std::uint32_t>(width);
  facts.height = static_cast<std::uint32_t>(height);

  const auto maximumDpbMacroblocks =
      h264MaxDpbMacroblocks(level, (compatibility & 0x10U) != 0U &&
                                       h264ConstraintSet3Level1b(profile));
  const std::uint64_t pictureMacroblocks =
      widthMbs * heightMapUnits * frameHeightMultiplier;
  if (!maximumDpbMacroblocks || pictureMacroblocks == 0U) {
    return Error::MalformedRecord;
  }
  const std::uint64_t calculatedDpb =
      static_cast<std::uint64_t>(*maximumDpbMacroblocks) / pictureMacroblocks;
  const std::uint32_t maximumDpbFrames = static_cast<std::uint32_t>(
      std::min<std::uint64_t>(kMaximumVideoCodecReorderFrames, calculatedDpb));
  if (maximumDpbFrames == 0U || maxReferenceFrames > maximumDpbFrames) {
    return Error::MalformedRecord;
  }

  bool vuiPresent = false;
  if (!bits.readBit(vuiPresent)) {
    return Error::MalformedRecord;
  }
  std::uint32_t reorderFrames =
      ((compatibility & 0x10U) != 0U && h264ConstraintSet3ZeroReorder(profile))
          ? 0U
          : maximumDpbFrames;
  if (vuiPresent) {
    if (!parseVuiColorPrefix(bits, facts.color)) {
      return Error::MalformedRecord;
    }
    if (!supportedSdrColor(facts.color)) {
      return Error::UnsupportedColorDescription;
    }
    bool present = false;
    if (!bits.readBit(present)) {
      return Error::MalformedRecord;
    }
    if (present) {
      if (!bits.readUnsignedExpGolomb(ignored) ||
          !bits.readUnsignedExpGolomb(ignored)) {
        return Error::MalformedRecord;
      }
    }
    if (!bits.readBit(present)) {
      return Error::MalformedRecord;
    }
    if (present) {
      std::uint32_t numUnitsInTick = 0;
      std::uint32_t timeScale = 0;
      if (!bits.readBits(32U, numUnitsInTick) ||
          !bits.readBits(32U, timeScale) || numUnitsInTick == 0U ||
          timeScale == 0U || !bits.skipBits(1U)) {
        return Error::MalformedRecord;
      }
    }
    bool nalHrd = false;
    bool vclHrd = false;
    if (!bits.readBit(nalHrd) || (nalHrd && !skipH264Hrd(bits)) ||
        !bits.readBit(vclHrd) || (vclHrd && !skipH264Hrd(bits)) ||
        ((nalHrd || vclHrd) && !bits.skipBits(1U)) || !bits.skipBits(1U) ||
        !bits.readBit(present)) {
      return Error::MalformedRecord;
    }
    if (present) {
      std::uint32_t decodedFrameBuffering = 0;
      if (!bits.skipBits(1U) || !bits.readUnsignedExpGolomb(ignored) ||
          !bits.readUnsignedExpGolomb(ignored) ||
          !bits.readUnsignedExpGolomb(ignored) ||
          !bits.readUnsignedExpGolomb(ignored) ||
          !bits.readUnsignedExpGolomb(reorderFrames) ||
          !bits.readUnsignedExpGolomb(decodedFrameBuffering) ||
          reorderFrames > decodedFrameBuffering ||
          decodedFrameBuffering > maximumDpbFrames ||
          decodedFrameBuffering < maxReferenceFrames) {
        return Error::MalformedRecord;
      }
    }
  }
  if (reorderFrames > limits.maximumReorderFrames) {
    return Error::ReorderLimitExceeded;
  }
  facts.reorderFrames = static_cast<std::uint8_t>(reorderFrames);
  return bits.finishRbsp() ? Error::None : Error::MalformedRecord;
}

struct HevcProfileTierLevel {
  std::uint8_t profileByte{0};
  std::uint32_t compatibility{0};
  std::uint32_t constraintHigh{0};
  std::uint16_t constraintLow{0};
  std::uint8_t level{0};
};

[[nodiscard]] bool
parseHevcProfileTierLevel(RbspBitReader &bits, std::uint32_t subLayers,
                          const HevcProfileTierLevel &expected) noexcept {
  std::uint32_t profileByte = 0;
  std::uint32_t compatibility = 0;
  std::uint32_t constraintHigh = 0;
  std::uint32_t constraintLow = 0;
  std::uint32_t level = 0;
  if (!bits.readBits(8U, profileByte) || !bits.readBits(32U, compatibility) ||
      !bits.readBits(32U, constraintHigh) ||
      !bits.readBits(16U, constraintLow) || !bits.readBits(8U, level) ||
      profileByte != expected.profileByte ||
      compatibility != expected.compatibility ||
      constraintHigh != expected.constraintHigh ||
      constraintLow != expected.constraintLow || level != expected.level) {
    return false;
  }
  std::array<bool, 7> profilePresent{};
  std::array<bool, 7> levelPresent{};
  for (std::uint32_t layer = 0; layer < subLayers; ++layer) {
    if (!bits.readBit(profilePresent[layer]) ||
        !bits.readBit(levelPresent[layer])) {
      return false;
    }
  }
  for (std::uint32_t layer = subLayers; layer < 8U && subLayers != 0U;
       ++layer) {
    std::uint32_t reserved = 0;
    if (!bits.readBits(2U, reserved) || reserved != 0U) {
      return false;
    }
  }
  for (std::uint32_t layer = 0; layer < subLayers; ++layer) {
    if (profilePresent[layer]) {
      std::uint32_t subProfile = 0;
      std::uint32_t ignored = 0;
      if (!bits.readBits(8U, subProfile) || (subProfile & 0xC0U) != 0U ||
          (subProfile & 0x1FU) != (expected.profileByte & 0x1FU) ||
          !bits.readBits(32U, ignored) || !bits.readBits(32U, ignored) ||
          !bits.readBits(16U, ignored)) {
        return false;
      }
    }
    if (levelPresent[layer] && !bits.skipBits(8U)) {
      return false;
    }
  }
  return true;
}

struct ParsedHevcVps {
  std::uint32_t id{0};
  std::uint32_t subLayers{0};
  bool temporalIdNested{false};
};

struct HevcHrdState {
  bool initialized{false};
  bool nalPresent{false};
  bool vclPresent{false};
  bool subPicture{false};
};

[[nodiscard]] bool skipHevcHrd(RbspBitReader &bits,
                               bool commonInformationPresent,
                               std::uint32_t subLayers,
                               HevcHrdState &state) noexcept;

[[nodiscard]] Error parseHevcVps(std::span<const std::uint8_t> nal,
                                 const HevcProfileTierLevel &expected,
                                 ParsedHevcVps &vps) noexcept {
  if (nal.size() < 3U) {
    return Error::MalformedRecord;
  }
  RbspBitReader bits(nal.subspan(2U));
  std::uint32_t ignored = 0;
  std::uint32_t reserved = 0;
  if (!bits.readBits(4U, vps.id) || !bits.skipBits(1U) || !bits.skipBits(1U) ||
      !bits.readBits(6U, ignored) || !bits.readBits(3U, vps.subLayers) ||
      vps.subLayers > 6U || !bits.readBit(vps.temporalIdNested) ||
      !bits.readBits(16U, reserved) || reserved != 0xFFFFU ||
      !parseHevcProfileTierLevel(bits, vps.subLayers, expected)) {
    return Error::ParameterSetMismatch;
  }
  bool orderingInfoPresent = false;
  if (!bits.readBit(orderingInfoPresent)) {
    return Error::MalformedRecord;
  }
  const std::uint32_t firstLayer = orderingInfoPresent ? 0U : vps.subLayers;
  std::uint32_t previousBuffering = 0;
  std::uint32_t previousReorder = 0;
  for (std::uint32_t layer = firstLayer; layer <= vps.subLayers; ++layer) {
    std::uint32_t bufferingMinusOne = 0;
    std::uint32_t reorder = 0;
    std::uint32_t latency = 0;
    if (!bits.readUnsignedExpGolomb(bufferingMinusOne) ||
        !bits.readUnsignedExpGolomb(reorder) ||
        !bits.readUnsignedExpGolomb(latency) ||
        bufferingMinusOne >= kMaximumVideoCodecReorderFrames ||
        reorder > bufferingMinusOne ||
        (layer > firstLayer && (bufferingMinusOne < previousBuffering ||
                                reorder < previousReorder))) {
      return Error::MalformedRecord;
    }
    previousBuffering = bufferingMinusOne;
    previousReorder = reorder;
  }
  std::uint32_t maximumLayerId = 0;
  std::uint32_t layerSetsMinusOne = 0;
  if (!bits.readBits(6U, maximumLayerId) || maximumLayerId > 62U ||
      !bits.readUnsignedExpGolomb(layerSetsMinusOne) ||
      layerSetsMinusOne > 1023U) {
    return Error::MalformedRecord;
  }
  for (std::uint32_t set = 1U; set <= layerSetsMinusOne; ++set) {
    if (!bits.skipBits(static_cast<std::size_t>(maximumLayerId) + 1U)) {
      return Error::MalformedRecord;
    }
  }
  bool timingPresent = false;
  if (!bits.readBit(timingPresent)) {
    return Error::MalformedRecord;
  }
  if (timingPresent) {
    std::uint32_t numUnitsInTick = 0;
    std::uint32_t timeScale = 0;
    bool pocProportional = false;
    std::uint32_t hrdCount = 0;
    if (!bits.readBits(32U, numUnitsInTick) || !bits.readBits(32U, timeScale) ||
        numUnitsInTick == 0U || timeScale == 0U ||
        !bits.readBit(pocProportional) ||
        (pocProportional && !bits.readUnsignedExpGolomb(ignored)) ||
        !bits.readUnsignedExpGolomb(hrdCount) ||
        hrdCount > layerSetsMinusOne + 1U) {
      return Error::MalformedRecord;
    }
    HevcHrdState hrdState;
    for (std::uint32_t hrd = 0; hrd < hrdCount; ++hrd) {
      std::uint32_t layerSetIndex = 0;
      bool commonInformationPresent = true;
      if (!bits.readUnsignedExpGolomb(layerSetIndex) ||
          layerSetIndex > layerSetsMinusOne ||
          (hrd != 0U && !bits.readBit(commonInformationPresent)) ||
          !skipHevcHrd(bits, commonInformationPresent, vps.subLayers,
                       hrdState)) {
        return Error::MalformedRecord;
      }
    }
  }
  bool extensionPresent = false;
  if (!bits.readBit(extensionPresent) || extensionPresent) {
    return extensionPresent ? Error::UnsupportedProfile
                            : Error::MalformedRecord;
  }
  return bits.finishRbsp() ? Error::None : Error::MalformedRecord;
}

[[nodiscard]] bool skipHevcScalingList(RbspBitReader &bits) noexcept {
  for (std::uint32_t sizeId = 0; sizeId < 4U; ++sizeId) {
    const std::uint32_t step = sizeId == 3U ? 3U : 1U;
    for (std::uint32_t matrixId = 0; matrixId < 6U; matrixId += step) {
      bool predictionMode = false;
      if (!bits.readBit(predictionMode)) {
        return false;
      }
      if (!predictionMode) {
        std::uint32_t delta = 0;
        if (!bits.readUnsignedExpGolomb(delta) || delta > matrixId) {
          return false;
        }
        continue;
      }
      if (sizeId > 1U) {
        std::int32_t ignoredSigned = 0;
        if (!bits.readSignedExpGolomb(ignoredSigned)) {
          return false;
        }
      }
      const std::uint32_t coefficientCount =
          std::min<std::uint32_t>(64U, 1U << (4U + 2U * sizeId));
      for (std::uint32_t index = 0; index < coefficientCount; ++index) {
        std::int32_t ignoredSigned = 0;
        if (!bits.readSignedExpGolomb(ignoredSigned)) {
          return false;
        }
      }
    }
  }
  return true;
}

[[nodiscard]] bool
skipHevcShortTermReferencePictureSets(RbspBitReader &bits,
                                      std::uint32_t count) noexcept {
  constexpr std::uint32_t kMaximumSets = 64U;
  constexpr std::uint32_t kMaximumPictures = 64U;
  if (count > kMaximumSets) {
    return false;
  }
  std::array<std::uint32_t, kMaximumSets> deltaPictureCounts{};
  for (std::uint32_t set = 0; set < count; ++set) {
    bool interPrediction = false;
    if (set != 0U && !bits.readBit(interPrediction)) {
      return false;
    }
    if (interPrediction) {
      if (!bits.skipBits(1U)) {
        return false;
      }
      std::uint32_t ignored = 0;
      if (!bits.readUnsignedExpGolomb(ignored)) {
        return false;
      }
      const std::uint32_t referencePictures = deltaPictureCounts[set - 1U];
      std::uint32_t derivedPictures = 0;
      for (std::uint32_t picture = 0; picture <= referencePictures; ++picture) {
        bool used = false;
        bool useDelta = true;
        if (!bits.readBit(used) || (!used && !bits.readBit(useDelta))) {
          return false;
        }
        if ((used || useDelta) && ++derivedPictures > kMaximumPictures) {
          return false;
        }
      }
      deltaPictureCounts[set] = derivedPictures;
      continue;
    }
    std::uint32_t negative = 0;
    std::uint32_t positive = 0;
    if (!bits.readUnsignedExpGolomb(negative) ||
        !bits.readUnsignedExpGolomb(positive) || negative > kMaximumPictures ||
        positive > kMaximumPictures - negative) {
      return false;
    }
    for (std::uint32_t picture = 0; picture < negative + positive; ++picture) {
      std::uint32_t ignored = 0;
      if (!bits.readUnsignedExpGolomb(ignored) || !bits.skipBits(1U)) {
        return false;
      }
    }
    deltaPictureCounts[set] = negative + positive;
  }
  return true;
}

[[nodiscard]] bool skipHevcSubLayerHrd(RbspBitReader &bits,
                                       std::uint32_t cpbCountMinusOne,
                                       bool subPicture) noexcept {
  for (std::uint32_t index = 0; index <= cpbCountMinusOne; ++index) {
    std::uint32_t ignored = 0;
    if (!bits.readUnsignedExpGolomb(ignored) ||
        !bits.readUnsignedExpGolomb(ignored) ||
        (subPicture && (!bits.readUnsignedExpGolomb(ignored) ||
                        !bits.readUnsignedExpGolomb(ignored))) ||
        !bits.skipBits(1U)) {
      return false;
    }
  }
  return true;
}

[[nodiscard]] bool skipHevcHrd(RbspBitReader &bits,
                               bool commonInformationPresent,
                               std::uint32_t subLayers,
                               HevcHrdState &state) noexcept {
  if (commonInformationPresent) {
    state = {};
    if (!bits.readBit(state.nalPresent) || !bits.readBit(state.vclPresent)) {
      return false;
    }
    if (state.nalPresent || state.vclPresent) {
      if (!bits.readBit(state.subPicture) ||
          (state.subPicture && !bits.skipBits(19U)) || !bits.skipBits(8U) ||
          (state.subPicture && !bits.skipBits(4U)) || !bits.skipBits(15U)) {
        return false;
      }
    }
    state.initialized = true;
  } else if (!state.initialized) {
    return false;
  }
  for (std::uint32_t layer = 0; layer <= subLayers; ++layer) {
    bool fixedGeneral = false;
    bool fixedWithin = true;
    bool lowDelay = false;
    if (!bits.readBit(fixedGeneral) ||
        (!fixedGeneral && !bits.readBit(fixedWithin))) {
      return false;
    }
    if (fixedGeneral || fixedWithin) {
      std::uint32_t ignored = 0;
      if (!bits.readUnsignedExpGolomb(ignored)) {
        return false;
      }
    } else if (!bits.readBit(lowDelay)) {
      return false;
    }
    std::uint32_t cpbCountMinusOne = 0;
    if (!lowDelay && (!bits.readUnsignedExpGolomb(cpbCountMinusOne) ||
                      cpbCountMinusOne > 31U)) {
      return false;
    }
    if ((state.nalPresent &&
         !skipHevcSubLayerHrd(bits, cpbCountMinusOne, state.subPicture)) ||
        (state.vclPresent &&
         !skipHevcSubLayerHrd(bits, cpbCountMinusOne, state.subPicture))) {
      return false;
    }
  }
  return true;
}

[[nodiscard]] bool parseH264Pps(std::span<const std::uint8_t> nal,
                                std::uint32_t spsIds, std::uint32_t &ppsId,
                                std::uint32_t &spsId) noexcept {
  RbspBitReader bits(nal.subspan(1U));
  if (!bits.readUnsignedExpGolomb(ppsId) || ppsId > 255U ||
      !bits.readUnsignedExpGolomb(spsId) || spsId > 31U ||
      (spsIds & (std::uint32_t{1} << spsId)) == 0U) {
    return false;
  }
  bool bottomFieldOrderPresent = false;
  std::uint32_t sliceGroupsMinusOne = 0;
  if (!bits.skipBits(1U) || !bits.readBit(bottomFieldOrderPresent) ||
      !bits.readUnsignedExpGolomb(sliceGroupsMinusOne) ||
      sliceGroupsMinusOne > 7U) {
    return false;
  }
  if (sliceGroupsMinusOne != 0U) {
    std::uint32_t mapType = 0;
    std::uint32_t ignored = 0;
    if (!bits.readUnsignedExpGolomb(mapType) || mapType > 6U) {
      return false;
    }
    if (mapType == 0U) {
      for (std::uint32_t group = 0; group <= sliceGroupsMinusOne; ++group) {
        if (!bits.readUnsignedExpGolomb(ignored)) {
          return false;
        }
      }
    } else if (mapType == 2U) {
      for (std::uint32_t group = 0; group < sliceGroupsMinusOne; ++group) {
        if (!bits.readUnsignedExpGolomb(ignored) ||
            !bits.readUnsignedExpGolomb(ignored)) {
          return false;
        }
      }
    } else if (mapType == 3U || mapType == 4U || mapType == 5U) {
      if (!bits.skipBits(1U) || !bits.readUnsignedExpGolomb(ignored)) {
        return false;
      }
    } else if (mapType == 6U) {
      constexpr std::uint32_t kMaximumMapUnits = 8192U;
      std::uint32_t mapUnitsMinusOne = 0;
      if (!bits.readUnsignedExpGolomb(mapUnitsMinusOne) ||
          mapUnitsMinusOne >= kMaximumMapUnits) {
        return false;
      }
      const std::uint32_t groupCount = sliceGroupsMinusOne + 1U;
      const std::size_t groupIdBits = groupCount <= 2U   ? 1U
                                      : groupCount <= 4U ? 2U
                                                         : 3U;
      for (std::uint32_t unit = 0; unit <= mapUnitsMinusOne; ++unit) {
        std::uint32_t groupId = 0;
        if (!bits.readBits(groupIdBits, groupId) || groupId >= groupCount) {
          return false;
        }
      }
    }
  }
  std::uint32_t ignored = 0;
  std::int32_t ignoredSigned = 0;
  if (!bits.readUnsignedExpGolomb(ignored) || ignored > 31U ||
      !bits.readUnsignedExpGolomb(ignored) || ignored > 31U ||
      !bits.skipBits(1U) || !bits.skipBits(2U) ||
      !bits.readSignedExpGolomb(ignoredSigned) || ignoredSigned < -26 ||
      ignoredSigned > 25 || !bits.readSignedExpGolomb(ignoredSigned) ||
      ignoredSigned < -26 || ignoredSigned > 25 ||
      !bits.readSignedExpGolomb(ignoredSigned) || ignoredSigned < -12 ||
      ignoredSigned > 12 || !bits.skipBits(3U)) {
    return false;
  }
  bool moreData = false;
  if (!bits.moreRbspData(moreData)) {
    return false;
  }
  if (moreData) {
    bool transform8x8 = false;
    bool scalingMatrixPresent = false;
    if (!bits.readBit(transform8x8) || !bits.readBit(scalingMatrixPresent)) {
      return false;
    }
    if (scalingMatrixPresent) {
      const std::size_t listCount = transform8x8 ? 8U : 6U;
      for (std::size_t index = 0; index < listCount; ++index) {
        bool listPresent = false;
        if (!bits.readBit(listPresent) ||
            (listPresent &&
             !skipH264ScalingList(bits, index < 6U ? 16U : 64U))) {
          return false;
        }
      }
    }
    if (!bits.readSignedExpGolomb(ignoredSigned) || ignoredSigned < -12 ||
        ignoredSigned > 12) {
      return false;
    }
  }
  return bits.finishRbsp();
}

[[nodiscard]] Error parseHevcPps(std::span<const std::uint8_t> nal,
                                 std::uint8_t bitDepth, std::uint32_t &ppsId,
                                 std::uint32_t &spsId) noexcept {
  RbspBitReader bits(nal.subspan(2U));
  std::uint32_t extraSliceHeaderBits = 0;
  if (!bits.readUnsignedExpGolomb(ppsId) || ppsId > 63U ||
      !bits.readUnsignedExpGolomb(spsId) || spsId > 15U || !bits.skipBits(2U) ||
      !bits.readBits(3U, extraSliceHeaderBits) || !bits.skipBits(2U)) {
    return Error::MalformedRecord;
  }
  std::uint32_t ignored = 0;
  std::int32_t ignoredSigned = 0;
  const std::int32_t qpBdOffsetY = static_cast<std::int32_t>(
      6U * (static_cast<std::uint32_t>(bitDepth) - 8U));
  const std::int32_t minimumInitialQpMinus26 = -26 - qpBdOffsetY;
  if (!bits.readUnsignedExpGolomb(ignored) || ignored > 14U ||
      !bits.readUnsignedExpGolomb(ignored) || ignored > 14U ||
      !bits.readSignedExpGolomb(ignoredSigned) ||
      ignoredSigned < minimumInitialQpMinus26 || ignoredSigned > 25) {
    return Error::MalformedRecord;
  }
  bool constrainedIntraPrediction = false;
  bool transformSkipEnabled = false;
  if (!bits.readBit(constrainedIntraPrediction) ||
      !bits.readBit(transformSkipEnabled)) {
    return Error::MalformedRecord;
  }
  bool cuQpDeltaEnabled = false;
  if (!bits.readBit(cuQpDeltaEnabled) ||
      (cuQpDeltaEnabled &&
       (!bits.readUnsignedExpGolomb(ignored) || ignored > 6U)) ||
      !bits.readSignedExpGolomb(ignoredSigned) || ignoredSigned < -12 ||
      ignoredSigned > 12 || !bits.readSignedExpGolomb(ignoredSigned) ||
      ignoredSigned < -12 || ignoredSigned > 12 || !bits.skipBits(4U)) {
    return Error::MalformedRecord;
  }
  bool tilesEnabled = false;
  bool entropyCodingSyncEnabled = false;
  if (!bits.readBit(tilesEnabled) || !bits.readBit(entropyCodingSyncEnabled)) {
    return Error::MalformedRecord;
  }
  if (tilesEnabled) {
    std::uint32_t columnsMinusOne = 0;
    std::uint32_t rowsMinusOne = 0;
    bool uniformSpacing = false;
    if (!bits.readUnsignedExpGolomb(columnsMinusOne) || columnsMinusOne > 19U ||
        !bits.readUnsignedExpGolomb(rowsMinusOne) || rowsMinusOne > 21U ||
        !bits.readBit(uniformSpacing)) {
      return Error::MalformedRecord;
    }
    if (!uniformSpacing) {
      for (std::uint32_t column = 0; column < columnsMinusOne; ++column) {
        if (!bits.readUnsignedExpGolomb(ignored)) {
          return Error::MalformedRecord;
        }
      }
      for (std::uint32_t row = 0; row < rowsMinusOne; ++row) {
        if (!bits.readUnsignedExpGolomb(ignored)) {
          return Error::MalformedRecord;
        }
      }
    }
    if (!bits.skipBits(1U)) {
      return Error::MalformedRecord;
    }
  }
  bool deblockingControlPresent = false;
  if (!bits.skipBits(1U) || !bits.readBit(deblockingControlPresent)) {
    return Error::MalformedRecord;
  }
  if (deblockingControlPresent) {
    bool deblockingDisabled = false;
    if (!bits.skipBits(1U) || !bits.readBit(deblockingDisabled) ||
        (!deblockingDisabled &&
         (!bits.readSignedExpGolomb(ignoredSigned) || ignoredSigned < -6 ||
          ignoredSigned > 6 || !bits.readSignedExpGolomb(ignoredSigned) ||
          ignoredSigned < -6 || ignoredSigned > 6))) {
      return Error::MalformedRecord;
    }
  }
  bool scalingListPresent = false;
  if (!bits.readBit(scalingListPresent) ||
      (scalingListPresent && !skipHevcScalingList(bits)) ||
      !bits.skipBits(1U) || !bits.readUnsignedExpGolomb(ignored) ||
      ignored > 6U || !bits.skipBits(1U)) {
    return Error::MalformedRecord;
  }
  bool extensionPresent = false;
  if (!bits.readBit(extensionPresent)) {
    return Error::MalformedRecord;
  }
  if (extensionPresent) {
    bool rangeExtension = false;
    bool multilayerExtension = false;
    bool extension3d = false;
    bool screenContentExtension = false;
    std::uint32_t extension4Bits = 0;
    if (!bits.readBit(rangeExtension) || !bits.readBit(multilayerExtension) ||
        !bits.readBit(extension3d) || !bits.readBit(screenContentExtension) ||
        !bits.readBits(4U, extension4Bits)) {
      return Error::MalformedRecord;
    }
    if (rangeExtension) {
      if (transformSkipEnabled &&
          (!bits.readUnsignedExpGolomb(ignored) || ignored > 3U)) {
        return Error::MalformedRecord;
      }
      bool chromaOffsetListEnabled = false;
      if (!bits.skipBits(1U) || !bits.readBit(chromaOffsetListEnabled)) {
        return Error::MalformedRecord;
      }
      if (chromaOffsetListEnabled) {
        std::uint32_t listLengthMinusOne = 0;
        if (!bits.readUnsignedExpGolomb(ignored) || ignored > 6U ||
            !bits.readUnsignedExpGolomb(listLengthMinusOne) ||
            listLengthMinusOne > 5U) {
          return Error::MalformedRecord;
        }
        for (std::uint32_t index = 0; index <= listLengthMinusOne; ++index) {
          if (!bits.readSignedExpGolomb(ignoredSigned) || ignoredSigned < -12 ||
              ignoredSigned > 12 || !bits.readSignedExpGolomb(ignoredSigned) ||
              ignoredSigned < -12 || ignoredSigned > 12) {
            return Error::MalformedRecord;
          }
        }
      }
      const std::uint32_t maximumSaoScale =
          bitDepth > 10U ? static_cast<std::uint32_t>(bitDepth - 10U) : 0U;
      if (!bits.readUnsignedExpGolomb(ignored) || ignored > maximumSaoScale ||
          !bits.readUnsignedExpGolomb(ignored) || ignored > maximumSaoScale) {
        return Error::MalformedRecord;
      }
    }
    if (multilayerExtension || extension3d || screenContentExtension ||
        extension4Bits != 0U) {
      return Error::UnsupportedProfile;
    }
  }
  return bits.finishRbsp() ? Error::None : Error::MalformedRecord;
}

[[nodiscard]] bool parseHevcVui(RbspBitReader &bits, std::uint32_t subLayers,
                                VideoCodecColorFacts &color) noexcept {
  if (!parseVuiColorPrefix(bits, color)) {
    return false;
  }
  bool present = false;
  std::uint32_t ignored = 0;
  if (!bits.readBit(present)) {
    return false;
  }
  if (present && (!bits.readUnsignedExpGolomb(ignored) ||
                  !bits.readUnsignedExpGolomb(ignored))) {
    return false;
  }
  if (!bits.skipBits(3U) || !bits.readBit(present)) {
    return false;
  }
  if (present) {
    for (std::size_t index = 0; index < 4U; ++index) {
      if (!bits.readUnsignedExpGolomb(ignored)) {
        return false;
      }
    }
  }
  if (!bits.readBit(present)) {
    return false;
  }
  if (present) {
    std::uint32_t numUnitsInTick = 0;
    std::uint32_t timeScale = 0;
    bool pocProportional = false;
    bool hrdPresent = false;
    HevcHrdState hrdState;
    if (!bits.readBits(32U, numUnitsInTick) || !bits.readBits(32U, timeScale) ||
        numUnitsInTick == 0U || timeScale == 0U ||
        !bits.readBit(pocProportional) ||
        (pocProportional && !bits.readUnsignedExpGolomb(ignored)) ||
        !bits.readBit(hrdPresent) ||
        (hrdPresent && !skipHevcHrd(bits, true, subLayers, hrdState))) {
      return false;
    }
  }
  if (!bits.readBit(present)) {
    return false;
  }
  if (present && (!bits.skipBits(3U) || !bits.readUnsignedExpGolomb(ignored) ||
                  !bits.readUnsignedExpGolomb(ignored) ||
                  !bits.readUnsignedExpGolomb(ignored) ||
                  !bits.readUnsignedExpGolomb(ignored) ||
                  !bits.readUnsignedExpGolomb(ignored))) {
    return false;
  }
  return true;
}

[[nodiscard]] Error parseHevcSps(std::span<const std::uint8_t> nal,
                                 const HevcProfileTierLevel &expected,
                                 std::uint8_t expectedDepthMinusEight,
                                 const VideoCodecConfigurationLimits &limits,
                                 ParsedSpsFacts &facts,
                                 std::uint32_t &subLayersOut) noexcept {
  if (nal.size() < 3U) {
    return Error::MalformedRecord;
  }
  RbspBitReader bits(nal.subspan(2U));
  std::uint32_t subLayers = 0;
  if (!bits.readBits(4U, facts.dependencyId) || facts.dependencyId > 15U ||
      !bits.readBits(3U, subLayers) || subLayers > 6U ||
      !bits.readBit(facts.temporalIdNested) ||
      !parseHevcProfileTierLevel(bits, subLayers, expected)) {
    return Error::ParameterSetMismatch;
  }
  subLayersOut = subLayers;
  std::uint32_t chromaFormat = 0;
  std::uint32_t pictureWidth = 0;
  std::uint32_t pictureHeight = 0;
  if (!bits.readUnsignedExpGolomb(facts.id) || facts.id > 15U ||
      !bits.readUnsignedExpGolomb(chromaFormat)) {
    return Error::MalformedRecord;
  }
  if (chromaFormat != 1U) {
    return Error::UnsupportedChromaFormat;
  }
  if (!bits.readUnsignedExpGolomb(pictureWidth) || pictureWidth == 0U ||
      !bits.readUnsignedExpGolomb(pictureHeight) || pictureHeight == 0U) {
    return Error::MalformedRecord;
  }
  bool conformanceWindow = false;
  std::array<std::uint32_t, 4> crop{};
  if (!bits.readBit(conformanceWindow)) {
    return Error::MalformedRecord;
  }
  if (conformanceWindow) {
    for (std::uint32_t &value : crop) {
      if (!bits.readUnsignedExpGolomb(value)) {
        return Error::MalformedRecord;
      }
    }
  }
  std::uint32_t lumaDepthMinusEight = 0;
  std::uint32_t chromaDepthMinusEight = 0;
  std::uint32_t log2MaxPocLsbMinusFour = 0;
  if (!bits.readUnsignedExpGolomb(lumaDepthMinusEight) ||
      !bits.readUnsignedExpGolomb(chromaDepthMinusEight)) {
    return Error::MalformedRecord;
  }
  if (lumaDepthMinusEight != expectedDepthMinusEight ||
      chromaDepthMinusEight != expectedDepthMinusEight) {
    return Error::ParameterSetMismatch;
  }
  if ((lumaDepthMinusEight != 0U && lumaDepthMinusEight != 2U)) {
    return Error::UnsupportedBitDepth;
  }
  facts.bitDepth = static_cast<std::uint8_t>(8U + lumaDepthMinusEight);
  if (!bits.readUnsignedExpGolomb(log2MaxPocLsbMinusFour) ||
      log2MaxPocLsbMinusFour > 12U) {
    return Error::MalformedRecord;
  }

  bool orderingInfoPresent = false;
  if (!bits.readBit(orderingInfoPresent)) {
    return Error::MalformedRecord;
  }
  const std::uint32_t firstLayer = orderingInfoPresent ? 0U : subLayers;
  std::uint32_t previousBuffering = 0;
  std::uint32_t previousReorder = 0;
  std::uint32_t maximumReorder = 0;
  for (std::uint32_t layer = firstLayer; layer <= subLayers; ++layer) {
    std::uint32_t bufferingMinusOne = 0;
    std::uint32_t reorder = 0;
    std::uint32_t ignored = 0;
    if (!bits.readUnsignedExpGolomb(bufferingMinusOne) ||
        !bits.readUnsignedExpGolomb(reorder) ||
        !bits.readUnsignedExpGolomb(ignored) ||
        bufferingMinusOne >= kMaximumVideoCodecReorderFrames ||
        reorder > bufferingMinusOne ||
        (layer > firstLayer && (bufferingMinusOne < previousBuffering ||
                                reorder < previousReorder))) {
      return Error::MalformedRecord;
    }
    previousBuffering = bufferingMinusOne;
    previousReorder = reorder;
    maximumReorder = std::max(maximumReorder, reorder);
  }
  if (maximumReorder > limits.maximumReorderFrames) {
    return Error::ReorderLimitExceeded;
  }
  facts.reorderFrames = static_cast<std::uint8_t>(maximumReorder);

  const std::uint64_t cropWidth =
      (static_cast<std::uint64_t>(crop[0]) + crop[1]) * 2U;
  const std::uint64_t cropHeight =
      (static_cast<std::uint64_t>(crop[2]) + crop[3]) * 2U;
  if (cropWidth >= pictureWidth || cropHeight >= pictureHeight) {
    return Error::MalformedRecord;
  }
  const std::uint64_t width = pictureWidth - cropWidth;
  const std::uint64_t height = pictureHeight - cropHeight;
  if (width > limits.maximumWidth || height > limits.maximumHeight ||
      (height != 0U && width > limits.maximumPixels / height)) {
    return Error::DimensionLimitExceeded;
  }
  facts.width = static_cast<std::uint32_t>(width);
  facts.height = static_cast<std::uint32_t>(height);

  std::uint32_t ignored = 0;
  for (std::size_t index = 0; index < 6U; ++index) {
    if (!bits.readUnsignedExpGolomb(ignored)) {
      return Error::MalformedRecord;
    }
  }
  bool scalingListEnabled = false;
  if (!bits.readBit(scalingListEnabled)) {
    return Error::MalformedRecord;
  }
  if (scalingListEnabled) {
    bool scalingListPresent = false;
    if (!bits.readBit(scalingListPresent) ||
        (scalingListPresent && !skipHevcScalingList(bits))) {
      return Error::MalformedRecord;
    }
  }
  bool pcmEnabled = false;
  if (!bits.skipBits(2U) || !bits.readBit(pcmEnabled)) {
    return Error::MalformedRecord;
  }
  if (pcmEnabled &&
      (!bits.skipBits(8U) || !bits.readUnsignedExpGolomb(ignored) ||
       !bits.readUnsignedExpGolomb(ignored) || !bits.skipBits(1U))) {
    return Error::MalformedRecord;
  }
  std::uint32_t shortTermSets = 0;
  if (!bits.readUnsignedExpGolomb(shortTermSets) ||
      !skipHevcShortTermReferencePictureSets(bits, shortTermSets)) {
    return Error::MalformedRecord;
  }
  bool longTermPresent = false;
  if (!bits.readBit(longTermPresent)) {
    return Error::MalformedRecord;
  }
  if (longTermPresent) {
    std::uint32_t longTermCount = 0;
    if (!bits.readUnsignedExpGolomb(longTermCount) || longTermCount > 32U) {
      return Error::MalformedRecord;
    }
    for (std::uint32_t index = 0; index < longTermCount; ++index) {
      if (!bits.skipBits(
              static_cast<std::size_t>(log2MaxPocLsbMinusFour + 4U)) ||
          !bits.skipBits(1U)) {
        return Error::MalformedRecord;
      }
    }
  }
  bool vuiPresent = false;
  if (!bits.skipBits(2U) || !bits.readBit(vuiPresent) ||
      (vuiPresent && !parseHevcVui(bits, subLayers, facts.color))) {
    return Error::MalformedRecord;
  }
  if (!supportedSdrColor(facts.color)) {
    return Error::UnsupportedColorDescription;
  }
  bool extensionPresent = false;
  if (!bits.readBit(extensionPresent)) {
    return Error::MalformedRecord;
  }
  // Main/Main10 native v1 has no SPS extension contract. Reject instead of
  // pretending to validate range, multilayer, 3D, or SCC syntax.
  if (extensionPresent) {
    return Error::UnsupportedProfile;
  }
  return bits.finishRbsp() ? Error::None : Error::MalformedRecord;
}

[[nodiscard]] bool validHevcNalHeader(std::span<const std::uint8_t> nal,
                                      std::uint8_t expectedType,
                                      bool parameterSet) noexcept {
  if (nal.size() < 2U || (nal[0] & 0x80U) != 0U ||
      ((nal[0] >> 1U) & 0x3FU) != expectedType || (nal[1] & 0x07U) == 0U) {
    return false;
  }
  const std::uint8_t layerId =
      static_cast<std::uint8_t>(((nal[0] & 0x01U) << 5U) | (nal[1] >> 3U));
  return !parameterSet ||
         (nal.size() >= 3U && layerId == 0U && (nal[1] & 0x07U) == 1U);
}

[[nodiscard]] bool sameImmutableFacts(const ParsedSpsFacts &left,
                                      const ParsedSpsFacts &right) noexcept {
  return left.width == right.width && left.height == right.height &&
         left.bitDepth == right.bitDepth &&
         left.reorderFrames == right.reorderFrames &&
         left.temporalIdNested == right.temporalIdNested &&
         left.color == right.color;
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectAvcC(std::span<const std::uint8_t> bytes,
            const VideoCodecConfigurationLimits &limits) noexcept {
  if (bytes.size() < 8U || bytes[0] != 1U || (bytes[4] & 0xFCU) != 0xFCU ||
      (bytes[4] & 0x03U) != 3U || (bytes[5] & 0xE0U) != 0xE0U) {
    return rejected(Error::MalformedRecord);
  }
  const std::uint8_t profile = bytes[1];
  if (profile != 66U && profile != 77U && profile != 88U && profile != 100U) {
    return rejected(Error::UnsupportedProfile);
  }

  VideoCodecConfigurationFacts result;
  result.codec = MediaCodec::H264;
  result.kind = MediaCodecConfigurationKind::AvcC;
  result.sampleFormat = MediaVideoSampleFormat::Yuv420EightBit;
  result.bitDepth = 8U;
  result.nalLengthBytes = 4U;

  const std::uint32_t spsCount = bytes[5] & 0x1FU;
  if (spsCount == 0U) {
    return rejected(Error::MissingParameterSet);
  }
  std::size_t offset = 6U;
  std::uint32_t spsIds = 0;
  std::optional<ParsedSpsFacts> canonical;
  for (std::uint32_t index = 0; index < spsCount; ++index) {
    if (offset > bytes.size() || bytes.size() - offset < 2U) {
      return rejected(Error::MalformedRecord);
    }
    const std::size_t length = readBigEndian16(bytes, offset);
    offset += 2U;
    if (length == 0U || length > bytes.size() - offset) {
      return rejected(Error::MalformedRecord);
    }
    ParsedSpsFacts parsed;
    const Error error = parseH264Sps(bytes.subspan(offset, length), profile,
                                     bytes[2], bytes[3], limits, parsed);
    if (error != Error::None) {
      return rejected(error);
    }
    const std::uint32_t idBit = std::uint32_t{1} << parsed.id;
    if ((spsIds & idBit) != 0U ||
        (canonical && !sameImmutableFacts(*canonical, parsed))) {
      return rejected(Error::ParameterSetMismatch);
    }
    spsIds |= idBit;
    if (!canonical) {
      canonical = parsed;
    }
    result.maximumReorderFrames =
        std::max(result.maximumReorderFrames, parsed.reorderFrames);
    offset += length;
  }
  if (offset >= bytes.size()) {
    return rejected(Error::MissingParameterSet);
  }
  const std::uint32_t ppsCount = bytes[offset++];
  if (ppsCount == 0U) {
    return rejected(Error::MissingParameterSet);
  }
  std::array<std::uint64_t, 4> ppsIds{};
  for (std::uint32_t index = 0; index < ppsCount; ++index) {
    if (offset > bytes.size() || bytes.size() - offset < 2U) {
      return rejected(Error::MalformedRecord);
    }
    const std::size_t length = readBigEndian16(bytes, offset);
    offset += 2U;
    if (length < 2U || length > bytes.size() - offset ||
        (bytes[offset] & 0x80U) != 0U || (bytes[offset] & 0x1FU) != 8U ||
        (bytes[offset] & 0x60U) == 0U) {
      return rejected(Error::MalformedRecord);
    }
    std::uint32_t ppsId = 0;
    std::uint32_t spsId = 0;
    if (!parseH264Pps(bytes.subspan(offset, length), spsIds, ppsId, spsId)) {
      return rejected(Error::MalformedRecord);
    }
    const std::size_t ppsWord = ppsId / 64U;
    const std::uint64_t ppsBit = std::uint64_t{1} << (ppsId % 64U);
    if ((ppsIds[ppsWord] & ppsBit) != 0U) {
      return rejected(Error::ParameterSetMismatch);
    }
    ppsIds[ppsWord] |= ppsBit;
    offset += length;
  }

  if (offset != bytes.size()) {
    // The AVC high-profile record extension is optional in common avcC. When
    // present, accept only the current 4:2:0 8-bit contract and no SPS-ext
    // payload. Anything else is a real, unsupported tail rather than padding.
    if (!h264HighProfile(profile) || bytes.size() - offset != 4U ||
        (bytes[offset] & 0xFCU) != 0xFCU || (bytes[offset] & 0x03U) != 1U ||
        (bytes[offset + 1U] & 0xF8U) != 0xF8U ||
        (bytes[offset + 1U] & 0x07U) != 0U ||
        (bytes[offset + 2U] & 0xF8U) != 0xF8U ||
        (bytes[offset + 2U] & 0x07U) != 0U || bytes[offset + 3U] != 0U) {
      return rejected(Error::MalformedRecord);
    }
    offset += 4U;
  }
  if (!canonical || offset != bytes.size()) {
    return rejected(Error::MalformedRecord);
  }
  result.width = canonical->width;
  result.height = canonical->height;
  result.color = canonical->color;
  result.spsCount = static_cast<std::uint16_t>(spsCount);
  result.ppsCount = static_cast<std::uint16_t>(ppsCount);
  return {Error::None, result};
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectHvcC(std::span<const std::uint8_t> bytes,
            const VideoCodecConfigurationLimits &limits) noexcept {
  if (bytes.size() < 23U || bytes[0] != 1U || (bytes[13] & 0xF0U) != 0xF0U ||
      (bytes[15] & 0xFCU) != 0xFCU || (bytes[16] & 0xFCU) != 0xFCU ||
      (bytes[17] & 0xF8U) != 0xF8U || (bytes[18] & 0xF8U) != 0xF8U ||
      (bytes[16] & 0x03U) != 1U || (bytes[21] & 0x03U) != 3U) {
    return rejected(Error::MalformedRecord);
  }
  const std::uint8_t lumaDepthMinusEight = bytes[17] & 0x07U;
  const std::uint8_t chromaDepthMinusEight = bytes[18] & 0x07U;
  if (lumaDepthMinusEight != chromaDepthMinusEight ||
      (lumaDepthMinusEight != 0U && lumaDepthMinusEight != 2U)) {
    return rejected(Error::UnsupportedBitDepth);
  }
  const std::uint8_t expectedProfileId = lumaDepthMinusEight == 2U ? 2U : 1U;
  if ((bytes[1] & 0xC0U) != 0U || (bytes[1] & 0x1FU) != expectedProfileId) {
    return rejected(Error::UnsupportedProfile);
  }
  const HevcProfileTierLevel expected{bytes[1], readBigEndian32(bytes, 2U),
                                      readBigEndian32(bytes, 6U),
                                      readBigEndian16(bytes, 10U), bytes[12]};

  VideoCodecConfigurationFacts result;
  result.codec = MediaCodec::Hevc;
  result.kind = MediaCodecConfigurationKind::HvcC;
  result.sampleFormat = lumaDepthMinusEight == 2U
                            ? MediaVideoSampleFormat::Yuv420TenBit
                            : MediaVideoSampleFormat::Yuv420EightBit;
  result.bitDepth = static_cast<std::uint8_t>(8U + lumaDepthMinusEight);
  result.nalLengthBytes = 4U;

  std::size_t offset = 23U;
  std::array<bool, 3> parameterSetArrays{};
  std::uint16_t vpsIds = 0;
  std::uint16_t spsIds = 0;
  std::uint16_t referencedVpsIds = 0;
  std::uint16_t referencedSpsIds = 0;
  std::uint64_t ppsIds = 0;
  std::optional<ParsedSpsFacts> canonical;
  std::optional<std::uint32_t> canonicalSubLayers;
  std::optional<std::uint32_t> canonicalVpsSubLayers;
  std::optional<bool> canonicalVpsTemporalIdNested;
  for (std::uint32_t array = 0; array < bytes[22]; ++array) {
    if (offset > bytes.size() || bytes.size() - offset < 3U) {
      return rejected(Error::MalformedRecord);
    }
    const std::uint8_t arrayHeader = bytes[offset];
    if ((arrayHeader & 0x40U) != 0U) {
      return rejected(Error::MalformedRecord);
    }
    const std::uint8_t nalType = arrayHeader & 0x3FU;
    const bool parameterSet = nalType >= 32U && nalType <= 34U;
    if (parameterSet) {
      const std::size_t setIndex = nalType - 32U;
      // array_completeness (bit 7) is a muxer convention, not a decodability
      // property. ISO/IEC 14496-15 lets it be zero to say the elementary
      // stream may also carry parameter sets in band, which VideoToolbox
      // handles either way. The MP4 and Matroska hvcC records for one
      // stream-copied stream are byte-identical apart from exactly this bit
      // (0xa0/0xa1/0xa2 versus 0x20/0x21/0x22), so requiring it rejected the
      // Matroska form of a stream that was admitted from MP4. A duplicate
      // array for the same parameter-set type remains a hard mismatch.
      if (parameterSetArrays[setIndex]) {
        return rejected(Error::ParameterSetMismatch);
      }
      parameterSetArrays[setIndex] = true;
    }
    const std::uint32_t nalCount = readBigEndian16(bytes, offset + 1U);
    if (parameterSet && nalCount == 0U) {
      return rejected(Error::MissingParameterSet);
    }
    offset += 3U;
    for (std::uint32_t index = 0; index < nalCount; ++index) {
      if (offset > bytes.size() || bytes.size() - offset < 2U) {
        return rejected(Error::MalformedRecord);
      }
      const std::size_t length = readBigEndian16(bytes, offset);
      offset += 2U;
      if (length == 0U || length > bytes.size() - offset) {
        return rejected(Error::MalformedRecord);
      }
      const auto nal = bytes.subspan(offset, length);
      if (!validHevcNalHeader(nal, nalType, parameterSet)) {
        return rejected(Error::MalformedRecord);
      }
      if (nalType == 32U) {
        ParsedHevcVps parsed;
        const Error error = parseHevcVps(nal, expected, parsed);
        if (error != Error::None) {
          return rejected(error);
        }
        const std::uint16_t idBit =
            static_cast<std::uint16_t>(std::uint16_t{1} << parsed.id);
        if ((vpsIds & idBit) != 0U) {
          return rejected(Error::ParameterSetMismatch);
        }
        if ((canonicalVpsSubLayers &&
             *canonicalVpsSubLayers != parsed.subLayers) ||
            (canonicalVpsTemporalIdNested &&
             *canonicalVpsTemporalIdNested != parsed.temporalIdNested)) {
          return rejected(Error::ParameterSetMismatch);
        }
        canonicalVpsSubLayers = parsed.subLayers;
        canonicalVpsTemporalIdNested = parsed.temporalIdNested;
        vpsIds = static_cast<std::uint16_t>(vpsIds | idBit);
        ++result.vpsCount;
      } else if (nalType == 33U) {
        ParsedSpsFacts parsed;
        std::uint32_t subLayers = 0;
        const Error error = parseHevcSps(nal, expected, lumaDepthMinusEight,
                                         limits, parsed, subLayers);
        if (error != Error::None) {
          return rejected(error);
        }
        referencedVpsIds = static_cast<std::uint16_t>(
            referencedVpsIds | (std::uint16_t{1} << parsed.dependencyId));
        const std::uint16_t idBit =
            static_cast<std::uint16_t>(std::uint16_t{1} << parsed.id);
        if ((spsIds & idBit) != 0U ||
            (canonical && !sameImmutableFacts(*canonical, parsed)) ||
            (canonicalSubLayers && *canonicalSubLayers != subLayers)) {
          return rejected(Error::ParameterSetMismatch);
        }
        spsIds = static_cast<std::uint16_t>(spsIds | idBit);
        canonicalSubLayers = subLayers;
        if (!canonical) {
          canonical = parsed;
        }
        result.maximumReorderFrames =
            std::max(result.maximumReorderFrames, parsed.reorderFrames);
        ++result.spsCount;
      } else if (nalType == 34U) {
        std::uint32_t ppsId = 0;
        std::uint32_t spsId = 0;
        const Error error = parseHevcPps(nal, result.bitDepth, ppsId, spsId);
        if (error != Error::None) {
          return rejected(error);
        }
        const std::uint64_t ppsBit = std::uint64_t{1} << ppsId;
        if ((ppsIds & ppsBit) != 0U) {
          return rejected(Error::ParameterSetMismatch);
        }
        ppsIds |= ppsBit;
        referencedSpsIds = static_cast<std::uint16_t>(
            referencedSpsIds | (std::uint16_t{1} << spsId));
        ++result.ppsCount;
      }
      offset += length;
    }
  }
  if (!parameterSetArrays[0] || !parameterSetArrays[1] ||
      !parameterSetArrays[2] || result.vpsCount == 0U ||
      result.spsCount == 0U || result.ppsCount == 0U) {
    return rejected(Error::MissingParameterSet);
  }
  if ((referencedVpsIds & vpsIds) != referencedVpsIds ||
      (referencedSpsIds & spsIds) != referencedSpsIds) {
    return rejected(Error::ParameterSetMismatch);
  }
  if (offset != bytes.size() || !canonical || !canonicalSubLayers) {
    return rejected(Error::MalformedRecord);
  }
  const std::uint32_t declaredTemporalLayers =
      (static_cast<std::uint32_t>(bytes[21]) >> 3U) & 0x07U;
  const bool declaredTemporalIdNested = (bytes[21] & 0x04U) != 0U;
  if (!canonicalVpsSubLayers || !canonicalVpsTemporalIdNested ||
      *canonicalVpsSubLayers != *canonicalSubLayers ||
      declaredTemporalLayers != *canonicalSubLayers + 1U ||
      declaredTemporalIdNested != canonical->temporalIdNested ||
      declaredTemporalIdNested != *canonicalVpsTemporalIdNested) {
    return rejected(Error::ParameterSetMismatch);
  }
  result.width = canonical->width;
  result.height = canonical->height;
  result.color = canonical->color;
  return {Error::None, result};
}

// ---------------------------------------------------------------------------
// AV1
// ---------------------------------------------------------------------------

constexpr std::uint8_t kAv1SequenceHeaderObu{1};
constexpr std::uint8_t kAv1TemporalDelimiterObu{2};
constexpr std::uint8_t kAv1MetadataObu{5};
constexpr std::uint8_t kAv1PaddingObu{15};

struct Av1SequenceHeaderFacts {
  std::uint32_t width{0};
  std::uint32_t height{0};
  std::uint8_t seqProfile{0};
  std::uint8_t bitDepth{0};
  bool monochrome{false};
  bool subsamplingX{false};
  bool subsamplingY{false};
  VideoCodecColorFacts color{};
};

[[nodiscard]] bool skipAv1TimingInfo(PlainBitReader &bits) noexcept {
  bool equalPictureInterval = false;
  std::uint32_t ignored = 0;
  if (!bits.skipBits(64U) || !bits.readBit(equalPictureInterval)) {
    return false;
  }
  return !equalPictureInterval || bits.readUvlc(ignored);
}

[[nodiscard]] bool
skipAv1DecoderModelInfo(PlainBitReader &bits,
                        std::uint32_t &bufferDelayLength) noexcept {
  std::uint32_t bufferDelayLengthMinusOne = 0;
  if (!bits.readBits(5U, bufferDelayLengthMinusOne) || !bits.skipBits(32U) ||
      !bits.skipBits(10U)) {
    return false;
  }
  bufferDelayLength = bufferDelayLengthMinusOne + 1U;
  return true;
}

// sequence_header_obu() of AV1 (AV1 Bitstream & Decoding Process 5.5). Parsed
// exactly through trailing_bits: an OBU this function cannot account for to
// the last bit is rejected rather than guessed at, because the fields this
// admission depends on (dimensions and color_config) sit at the end and a
// mis-parsed prefix would silently relocate them.
[[nodiscard]] Error
parseAv1SequenceHeader(std::span<const std::uint8_t> payload,
                       const VideoCodecConfigurationLimits &limits,
                       Av1SequenceHeaderFacts &facts) noexcept {
  PlainBitReader bits(payload);
  std::uint32_t seqProfile = 0;
  bool stillPicture = false;
  bool reducedStillPictureHeader = false;
  if (!bits.readBits(3U, seqProfile) || !bits.readBit(stillPicture) ||
      !bits.readBit(reducedStillPictureHeader)) {
    return Error::MalformedRecord;
  }
  facts.seqProfile = static_cast<std::uint8_t>(seqProfile);

  bool decoderModelInfoPresent = false;
  bool initialDisplayDelayPresent = false;
  std::uint32_t bufferDelayLength = 0;
  if (reducedStillPictureHeader) {
    std::uint32_t levelIdx = 0;
    if (!bits.readBits(5U, levelIdx)) {
      return Error::MalformedRecord;
    }
  } else {
    bool timingInfoPresent = false;
    if (!bits.readBit(timingInfoPresent)) {
      return Error::MalformedRecord;
    }
    if (timingInfoPresent) {
      if (!skipAv1TimingInfo(bits) || !bits.readBit(decoderModelInfoPresent)) {
        return Error::MalformedRecord;
      }
      if (decoderModelInfoPresent &&
          !skipAv1DecoderModelInfo(bits, bufferDelayLength)) {
        return Error::MalformedRecord;
      }
    }
    std::uint32_t operatingPointsMinusOne = 0;
    if (!bits.readBit(initialDisplayDelayPresent) ||
        !bits.readBits(5U, operatingPointsMinusOne)) {
      return Error::MalformedRecord;
    }
    for (std::uint32_t index = 0; index <= operatingPointsMinusOne; ++index) {
      std::uint32_t idc = 0;
      std::uint32_t levelIdx = 0;
      if (!bits.readBits(12U, idc) || !bits.readBits(5U, levelIdx)) {
        return Error::MalformedRecord;
      }
      if (levelIdx > 7U && !bits.skipBits(1U)) {
        return Error::MalformedRecord;
      }
      if (decoderModelInfoPresent) {
        bool operatingParametersPresent = false;
        if (!bits.readBit(operatingParametersPresent)) {
          return Error::MalformedRecord;
        }
        if (operatingParametersPresent &&
            !bits.skipBits(std::size_t{2} * bufferDelayLength + 1U)) {
          return Error::MalformedRecord;
        }
      }
      if (initialDisplayDelayPresent) {
        bool delayPresent = false;
        if (!bits.readBit(delayPresent)) {
          return Error::MalformedRecord;
        }
        if (delayPresent && !bits.skipBits(4U)) {
          return Error::MalformedRecord;
        }
      }
    }
  }

  std::uint32_t widthBitsMinusOne = 0;
  std::uint32_t heightBitsMinusOne = 0;
  std::uint32_t maxWidthMinusOne = 0;
  std::uint32_t maxHeightMinusOne = 0;
  if (!bits.readBits(4U, widthBitsMinusOne) ||
      !bits.readBits(4U, heightBitsMinusOne) ||
      !bits.readBits(widthBitsMinusOne + 1U, maxWidthMinusOne) ||
      !bits.readBits(heightBitsMinusOne + 1U, maxHeightMinusOne)) {
    return Error::MalformedRecord;
  }
  const std::uint64_t width = static_cast<std::uint64_t>(maxWidthMinusOne) + 1U;
  const std::uint64_t height =
      static_cast<std::uint64_t>(maxHeightMinusOne) + 1U;
  if (width > limits.maximumWidth || height > limits.maximumHeight ||
      width > limits.maximumPixels / height) {
    return Error::DimensionLimitExceeded;
  }
  facts.width = static_cast<std::uint32_t>(width);
  facts.height = static_cast<std::uint32_t>(height);

  bool frameIdNumbersPresent = false;
  if (!reducedStillPictureHeader && !bits.readBit(frameIdNumbersPresent)) {
    return Error::MalformedRecord;
  }
  // delta_frame_id_length_minus_2 f(4) + additional_frame_id_length_minus_1
  // f(3).
  if (frameIdNumbersPresent && !bits.skipBits(7U)) {
    return Error::MalformedRecord;
  }
  // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter.
  if (!bits.skipBits(3U)) {
    return Error::MalformedRecord;
  }
  if (!reducedStillPictureHeader) {
    bool enableOrderHint = false;
    bool chooseScreenContentTools = false;
    bool forceScreenContentTools = true;
    // enable_interintra_compound, enable_masked_compound,
    // enable_warped_motion, enable_dual_filter.
    if (!bits.skipBits(4U) || !bits.readBit(enableOrderHint)) {
      return Error::MalformedRecord;
    }
    // enable_jnt_comp, enable_ref_frame_mvs.
    if (enableOrderHint && !bits.skipBits(2U)) {
      return Error::MalformedRecord;
    }
    if (!bits.readBit(chooseScreenContentTools)) {
      return Error::MalformedRecord;
    }
    if (!chooseScreenContentTools && !bits.readBit(forceScreenContentTools)) {
      return Error::MalformedRecord;
    }
    if (forceScreenContentTools) {
      bool chooseIntegerMv = false;
      if (!bits.readBit(chooseIntegerMv)) {
        return Error::MalformedRecord;
      }
      if (!chooseIntegerMv && !bits.skipBits(1U)) {
        return Error::MalformedRecord;
      }
    }
    if (enableOrderHint && !bits.skipBits(3U)) {
      return Error::MalformedRecord;
    }
  }
  // enable_superres, enable_cdef, enable_restoration.
  if (!bits.skipBits(3U)) {
    return Error::MalformedRecord;
  }

  // color_config().
  bool highBitdepth = false;
  if (!bits.readBit(highBitdepth)) {
    return Error::MalformedRecord;
  }
  if (seqProfile == 2U && highBitdepth) {
    bool twelveBit = false;
    if (!bits.readBit(twelveBit)) {
      return Error::MalformedRecord;
    }
    facts.bitDepth = twelveBit ? 12U : 10U;
  } else if (seqProfile <= 2U) {
    facts.bitDepth = highBitdepth ? 10U : 8U;
  } else {
    return Error::UnsupportedProfile;
  }
  if (seqProfile == 1U) {
    facts.monochrome = false;
  } else if (!bits.readBit(facts.monochrome)) {
    return Error::MalformedRecord;
  }
  facts.color.videoSignalTypePresent = true;
  if (!bits.readBit(facts.color.colorDescriptionPresent)) {
    return Error::MalformedRecord;
  }
  std::uint32_t primaries = 2U;
  std::uint32_t transfer = 2U;
  std::uint32_t matrix = 2U;
  if (facts.color.colorDescriptionPresent) {
    if (!bits.readBits(8U, primaries) || !bits.readBits(8U, transfer) ||
        !bits.readBits(8U, matrix)) {
      return Error::MalformedRecord;
    }
    // An absent description leaves the reported values at zero, matching the
    // AVC and HEVC parsers; the spec's implied "unspecified" defaults are used
    // only for the sRGB shortcut test below, which is a bitstream syntax
    // decision rather than a reported fact.
    facts.color.colorPrimaries = static_cast<std::uint8_t>(primaries);
    facts.color.transferCharacteristics = static_cast<std::uint8_t>(transfer);
    facts.color.matrixCoefficients = static_cast<std::uint8_t>(matrix);
  }
  if (facts.monochrome) {
    if (!bits.readBit(facts.color.fullRange)) {
      return Error::MalformedRecord;
    }
    facts.subsamplingX = true;
    facts.subsamplingY = true;
    return Error::None;
  }
  if (primaries == 1U && transfer == 13U && matrix == 0U) {
    // The spec's sRGB shortcut: 4:4:4 full range with no coded color_range.
    facts.color.fullRange = true;
    facts.subsamplingX = false;
    facts.subsamplingY = false;
  } else {
    if (!bits.readBit(facts.color.fullRange)) {
      return Error::MalformedRecord;
    }
    if (seqProfile == 0U) {
      facts.subsamplingX = true;
      facts.subsamplingY = true;
    } else if (seqProfile == 1U) {
      facts.subsamplingX = false;
      facts.subsamplingY = false;
    } else if (facts.bitDepth == 12U) {
      if (!bits.readBit(facts.subsamplingX)) {
        return Error::MalformedRecord;
      }
      facts.subsamplingY = false;
      if (facts.subsamplingX && !bits.readBit(facts.subsamplingY)) {
        return Error::MalformedRecord;
      }
    } else {
      facts.subsamplingX = true;
      facts.subsamplingY = false;
    }
    // chroma_sample_position f(2).
    if (facts.subsamplingX && facts.subsamplingY && !bits.skipBits(2U)) {
      return Error::MalformedRecord;
    }
  }
  // separate_uv_delta_q, then film_grain_params_present.
  if (!bits.skipBits(2U)) {
    return Error::MalformedRecord;
  }
  return bits.finishTrailingBits() ? Error::None : Error::MalformedRecord;
}

[[nodiscard]] bool readLeb128(std::span<const std::uint8_t> bytes,
                              std::size_t &offset,
                              std::uint64_t &value) noexcept {
  value = 0;
  for (std::size_t index = 0; index < 8U; ++index) {
    if (offset >= bytes.size()) {
      return false;
    }
    const std::uint8_t current = bytes[offset++];
    value |= static_cast<std::uint64_t>(current & 0x7FU) << (index * 7U);
    if ((current & 0x80U) == 0U) {
      return true;
    }
  }
  return false;
}

// Walks the av1C configOBUs. Only the OBU types a configuration record may
// legitimately carry are tolerated; a frame or tile OBU inside a configuration
// record is a malformed record, not payload to skip.
[[nodiscard]] Error
parseAv1ConfigObus(std::span<const std::uint8_t> bytes,
                   const VideoCodecConfigurationLimits &limits,
                   Av1SequenceHeaderFacts &facts, bool &found) noexcept {
  found = false;
  std::size_t offset = 0;
  while (offset < bytes.size()) {
    const std::uint8_t header = bytes[offset++];
    // obu_forbidden_bit and obu_reserved_1bit are both zero in any conforming
    // stream.
    if ((header & 0x80U) != 0U || (header & 0x01U) != 0U) {
      return Error::MalformedRecord;
    }
    const auto type = static_cast<std::uint8_t>((header >> 3U) & 0x0FU);
    const bool extension = (header & 0x04U) != 0U;
    const bool hasSizeField = (header & 0x02U) != 0U;
    if (extension) {
      // temporal_id f(3), spatial_id f(2), reserved f(3). A configuration
      // record for a scalable stream is outside this admission.
      if (offset >= bytes.size() || bytes[offset] != 0U) {
        return Error::MalformedRecord;
      }
      ++offset;
    }
    std::uint64_t size = 0;
    if (hasSizeField) {
      if (!readLeb128(bytes, offset, size)) {
        return Error::MalformedRecord;
      }
    } else {
      size = bytes.size() - offset;
    }
    if (size > bytes.size() - offset) {
      return Error::MalformedRecord;
    }
    const auto payload = bytes.subspan(offset, static_cast<std::size_t>(size));
    offset += static_cast<std::size_t>(size);
    switch (type) {
    case kAv1SequenceHeaderObu: {
      if (found) {
        return Error::ParameterSetMismatch;
      }
      const Error error = parseAv1SequenceHeader(payload, limits, facts);
      if (error != Error::None) {
        return error;
      }
      found = true;
      break;
    }
    case kAv1TemporalDelimiterObu:
    case kAv1MetadataObu:
    case kAv1PaddingObu:
      break;
    default:
      return Error::MalformedRecord;
    }
  }
  return Error::None;
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectAv1C(std::span<const std::uint8_t> bytes,
            const VideoCodecConfigurationLimits &limits) noexcept {
  // marker f(1) == 1 and version f(7) == 1 are jointly exactly 0x81.
  if (bytes.size() < 4U || bytes[0] != 0x81U || (bytes[3] & 0xE0U) != 0U) {
    return rejected(Error::MalformedRecord);
  }
  const auto seqProfile = static_cast<std::uint8_t>(bytes[1] >> 5U);
  const bool highBitdepth = (bytes[2] & 0x40U) != 0U;
  const bool twelveBit = (bytes[2] & 0x20U) != 0U;
  const bool monochrome = (bytes[2] & 0x10U) != 0U;
  const bool subsamplingX = (bytes[2] & 0x08U) != 0U;
  const bool subsamplingY = (bytes[2] & 0x04U) != 0U;
  const bool presentationDelayPresent = (bytes[3] & 0x10U) != 0U;
  const auto presentationDelayMinusOne =
      static_cast<std::uint8_t>(bytes[3] & 0x0FU);
  if (seqProfile != 0U) {
    return rejected(Error::UnsupportedProfile);
  }
  if (twelveBit) {
    return rejected(Error::UnsupportedBitDepth);
  }
  if (monochrome || !subsamplingX || !subsamplingY) {
    return rejected(Error::UnsupportedChromaFormat);
  }
  const std::uint32_t reorderFrames =
      presentationDelayPresent
          ? static_cast<std::uint32_t>(presentationDelayMinusOne) + 1U
          : 0U;
  if (reorderFrames > limits.maximumReorderFrames) {
    return rejected(Error::ReorderLimitExceeded);
  }

  Av1SequenceHeaderFacts sequence;
  bool found = false;
  const Error error =
      parseAv1ConfigObus(bytes.subspan(4U), limits, sequence, found);
  if (error != Error::None) {
    return rejected(error);
  }
  if (!found) {
    return rejected(Error::MissingParameterSet);
  }
  // The av1C fixed bytes are a redundant copy of sequence header facts. A
  // disagreement means one of the two is describing a different stream, so
  // neither can be trusted.
  if (sequence.seqProfile != seqProfile || sequence.monochrome != monochrome ||
      sequence.subsamplingX != subsamplingX ||
      sequence.subsamplingY != subsamplingY ||
      sequence.bitDepth != (highBitdepth ? 10U : 8U)) {
    return rejected(Error::ParameterSetMismatch);
  }
  if (!supportedSdrColor(sequence.color)) {
    return rejected(Error::UnsupportedColorDescription);
  }

  VideoCodecConfigurationFacts result;
  result.codec = MediaCodec::Av1;
  result.kind = MediaCodecConfigurationKind::Av1C;
  result.sampleFormat = sequence.bitDepth == 10U
                            ? MediaVideoSampleFormat::Yuv420TenBit
                            : MediaVideoSampleFormat::Yuv420EightBit;
  result.width = sequence.width;
  result.height = sequence.height;
  result.bitDepth = sequence.bitDepth;
  result.profile = seqProfile;
  // AV1 access units are OBUs with their own length signalling; there is no
  // AVC/HEVC-style NAL length prefix for a demuxer to strip or write.
  result.nalLengthBytes = 0U;
  result.maximumReorderFrames = static_cast<std::uint8_t>(reorderFrames);
  result.color = sequence.color;
  return {Error::None, result};
}

// ---------------------------------------------------------------------------
// VP9
// ---------------------------------------------------------------------------

// The VP9 uncompressed header's color_space field names a matrix, not a full
// color description: the bitstream carries no primaries or transfer function
// at all. Claiming BT.601 primaries for a CS_BT_601 stream would invent a fact
// the encoder never wrote, so everything except the BT.709 case -- where the
// name does denote the complete BT.709 description -- reports ISO/IEC 23091-2
// "unspecified" (2) for primaries and transfer and carries only the matrix.
// That is also what makes CS_BT_601 and CS_SMPTE_170 admissible under
// supportedSdrColor, whose matrix set {1, 2, 5, 6} was chosen for exactly the
// BT.709/BT.601 family.
[[nodiscard]] bool vp9ColorFromColorSpace(std::uint32_t colorSpace,
                                          VideoCodecColorFacts &color) noexcept {
  switch (colorSpace) {
  case 0U: // CS_UNKNOWN
    color.colorDescriptionPresent = false;
    return true;
  case 1U: // CS_BT_601
    color.colorDescriptionPresent = true;
    color.colorPrimaries = 2U;
    color.transferCharacteristics = 2U;
    color.matrixCoefficients = 5U;
    return true;
  case 2U: // CS_BT_709
    color.colorDescriptionPresent = true;
    color.colorPrimaries = 1U;
    color.transferCharacteristics = 1U;
    color.matrixCoefficients = 1U;
    return true;
  case 3U: // CS_SMPTE_170
    color.colorDescriptionPresent = true;
    color.colorPrimaries = 2U;
    color.transferCharacteristics = 2U;
    color.matrixCoefficients = 6U;
    return true;
  case 4U: // CS_SMPTE_240
    color.colorDescriptionPresent = true;
    color.colorPrimaries = 2U;
    color.transferCharacteristics = 2U;
    color.matrixCoefficients = 7U;
    return true;
  case 5U: // CS_BT_2020
    color.colorDescriptionPresent = true;
    color.colorPrimaries = 9U;
    color.transferCharacteristics = 14U;
    color.matrixCoefficients = 9U;
    return true;
  case 7U: // CS_SRGB
    color.colorDescriptionPresent = true;
    color.colorPrimaries = 1U;
    color.transferCharacteristics = 13U;
    color.matrixCoefficients = 0U;
    return true;
  default: // CS_RESERVED
    return false;
  }
}

// VP9 level from the coded picture size alone (VP9 Bitstream & Decoding
// Process Specification, Annex A). The frame rate a level also bounds is not
// visible from a single keyframe, so each bucket names the level whose luma
// sample *rate* covers that picture size at 60 fps -- the highest rate this
// renderer's dimension envelope can present. VideoToolbox does not validate
// this field at all (0 and 40 both create a session), so the only requirement
// on it is that it never understates the stream.
[[nodiscard]] std::uint8_t vp9Level(std::uint32_t width,
                                    std::uint32_t height) noexcept {
  const std::uint64_t samples =
      static_cast<std::uint64_t>(width) * static_cast<std::uint64_t>(height);
  if (samples <= 36864U) {
    return 11U;
  }
  if (samples <= 73728U) {
    return 20U;
  }
  if (samples <= 122880U) {
    return 21U;
  }
  if (samples <= 245760U) {
    return 30U;
  }
  if (samples <= 552960U) {
    return 31U;
  }
  if (samples <= 983040U) {
    return 40U;
  }
  if (samples <= 2228224U) {
    return 41U;
  }
  return 51U;
}

// VP Codec Configuration Box (VP Codec ISO Media File Format Binding, "vpcC"
// version 1): a fixed 12-byte record with no codec initialization data.
[[nodiscard]] VideoCodecConfigurationInspection
inspectVpcC(std::span<const std::uint8_t> bytes,
            const VideoCodecConfigurationLimits &limits) noexcept {
  (void)limits;
  if (bytes.size() != kVideoCodecVpcCBytes || bytes[0] != 1U ||
      bytes[1] != 0U || bytes[2] != 0U || bytes[3] != 0U ||
      readBigEndian16(bytes, 10U) != 0U) {
    return rejected(Error::MalformedRecord);
  }
  const std::uint8_t profile = bytes[4];
  const auto bitDepth = static_cast<std::uint8_t>(bytes[6] >> 4U);
  const auto chromaSubsampling = static_cast<std::uint8_t>((bytes[6] >> 1U) & 0x07U);
  const bool fullRange = (bytes[6] & 0x01U) != 0U;
  if (profile != 0U && profile != 2U) {
    return rejected(Error::UnsupportedProfile);
  }
  // 0 is 4:2:0 vertically co-sited, 1 is 4:2:0 co-located; 2 is 4:2:2 and 3 is
  // 4:4:4, neither of which this renderer presents.
  if (chromaSubsampling > 1U) {
    return rejected(Error::UnsupportedChromaFormat);
  }
  if (bitDepth != 8U && bitDepth != 10U) {
    return rejected(Error::UnsupportedBitDepth);
  }
  // VP9 profile 0 is 8-bit only and profile 2 is 10/12-bit only; a record that
  // pairs them differently is describing an impossible stream.
  if ((profile == 0U) != (bitDepth == 8U)) {
    return rejected(Error::UnsupportedProfile);
  }

  VideoCodecColorFacts color;
  color.videoSignalTypePresent = true;
  color.fullRange = fullRange;
  color.colorPrimaries = bytes[7];
  color.transferCharacteristics = bytes[8];
  color.matrixCoefficients = bytes[9];
  // All three "unspecified" is exactly as much information as the VP9
  // bitstream's CS_UNKNOWN, which reports no description at all. Treating them
  // identically is what lets a synthesized record round-trip.
  color.colorDescriptionPresent =
      color.colorPrimaries != 2U || color.transferCharacteristics != 2U ||
      color.matrixCoefficients != 2U;
  if (!supportedSdrColor(color)) {
    return rejected(Error::UnsupportedColorDescription);
  }

  VideoCodecConfigurationFacts result;
  result.codec = MediaCodec::Vp9;
  result.kind = MediaCodecConfigurationKind::VpcC;
  result.sampleFormat = bitDepth == 10U
                            ? MediaVideoSampleFormat::Yuv420TenBit
                            : MediaVideoSampleFormat::Yuv420EightBit;
  // A vpcC carries no dimensions whatsoever. Zero here is the honest answer
  // and is documented at the declaration as a caller obligation.
  result.width = 0U;
  result.height = 0U;
  result.bitDepth = bitDepth;
  result.profile = profile;
  result.nalLengthBytes = 0U;
  result.maximumReorderFrames = 0U;
  result.color = color;
  return {Error::None, result};
}

} // namespace

VideoCodecConfigurationInspection inspectVideoCodecConfiguration(
    MediaCodec codec, MediaCodecConfigurationKind kind,
    std::span<const std::byte> configuration,
    VideoCodecConfigurationLimits requestedLimits) noexcept {
  MediaCodecConfigurationKind expectedKind = MediaCodecConfigurationKind::None;
  switch (codec) {
  case MediaCodec::H264:
    expectedKind = MediaCodecConfigurationKind::AvcC;
    break;
  case MediaCodec::Hevc:
    expectedKind = MediaCodecConfigurationKind::HvcC;
    break;
  case MediaCodec::Av1:
    expectedKind = MediaCodecConfigurationKind::Av1C;
    break;
  case MediaCodec::Vp9:
    expectedKind = MediaCodecConfigurationKind::VpcC;
    break;
  default:
    return rejected(Error::UnsupportedCodec);
  }
  if (kind != expectedKind) {
    return rejected(Error::ConfigurationKindMismatch);
  }
  if (configuration.empty()) {
    return rejected(Error::EmptyConfiguration);
  }
  const VideoCodecConfigurationLimits limits = effectiveLimits(requestedLimits);
  if (configuration.size() > limits.maximumConfigurationBytes) {
    return rejected(Error::ConfigurationTooLarge);
  }
  const auto bytes = asBytes(configuration);
  switch (codec) {
  case MediaCodec::H264:
    return inspectAvcC(bytes, limits);
  case MediaCodec::Hevc:
    return inspectHvcC(bytes, limits);
  case MediaCodec::Av1:
    return inspectAv1C(bytes, limits);
  default:
    return inspectVpcC(bytes, limits);
  }
}

VideoCodecConfigurationInspection inspectVp9BitstreamKeyframe(
    std::span<const std::byte> keyframe,
    VideoCodecConfigurationLimits requestedLimits) noexcept {
  if (keyframe.empty()) {
    return rejected(Error::EmptyConfiguration);
  }
  const VideoCodecConfigurationLimits limits = effectiveLimits(requestedLimits);
  const auto all = asBytes(keyframe);
  const auto bytes = all.first(
      std::min<std::size_t>(all.size(), kVp9KeyframeHeaderMaximumBytes));
  PlainBitReader bits(bytes);

  std::uint32_t frameMarker = 0;
  bool profileLowBit = false;
  bool profileHighBit = false;
  if (!bits.readBits(2U, frameMarker) || frameMarker != 2U ||
      !bits.readBit(profileLowBit) || !bits.readBit(profileHighBit)) {
    return rejected(Error::MalformedRecord);
  }
  const auto profile = static_cast<std::uint8_t>(
      (profileHighBit ? 2U : 0U) | (profileLowBit ? 1U : 0U));
  if (profile == 3U) {
    bool reservedZero = true;
    if (!bits.readBit(reservedZero) || reservedZero) {
      return rejected(Error::MalformedRecord);
    }
  }
  bool showExistingFrame = false;
  bool nonKeyFrame = false;
  bool showFrame = false;
  bool errorResilientMode = false;
  std::uint32_t syncCode = 0;
  if (!bits.readBit(showExistingFrame) || showExistingFrame ||
      !bits.readBit(nonKeyFrame) || nonKeyFrame ||
      !bits.readBit(showFrame) || !bits.readBit(errorResilientMode) ||
      !bits.readBits(24U, syncCode) || syncCode != 0x498342U) {
    return rejected(Error::MalformedRecord);
  }

  // color_config().
  std::uint8_t bitDepth = 8U;
  if (profile >= 2U) {
    bool tenOrTwelveBit = false;
    if (!bits.readBit(tenOrTwelveBit)) {
      return rejected(Error::MalformedRecord);
    }
    bitDepth = tenOrTwelveBit ? 12U : 10U;
  }
  std::uint32_t colorSpace = 0;
  if (!bits.readBits(3U, colorSpace)) {
    return rejected(Error::MalformedRecord);
  }
  VideoCodecColorFacts color;
  color.videoSignalTypePresent = true;
  bool subsamplingX = true;
  bool subsamplingY = true;
  if (colorSpace != 7U) {
    if (!bits.readBit(color.fullRange)) {
      return rejected(Error::MalformedRecord);
    }
    if (profile == 1U || profile == 3U) {
      bool reservedZero = true;
      if (!bits.readBit(subsamplingX) || !bits.readBit(subsamplingY) ||
          !bits.readBit(reservedZero) || reservedZero) {
        return rejected(Error::MalformedRecord);
      }
    }
  } else {
    color.fullRange = true;
    if (profile == 1U || profile == 3U) {
      bool reservedZero = true;
      if (!bits.readBit(reservedZero) || reservedZero) {
        return rejected(Error::MalformedRecord);
      }
    }
    subsamplingX = false;
    subsamplingY = false;
  }

  // frame_size().
  std::uint32_t widthMinusOne = 0;
  std::uint32_t heightMinusOne = 0;
  if (!bits.readBits(16U, widthMinusOne) ||
      !bits.readBits(16U, heightMinusOne)) {
    return rejected(Error::MalformedRecord);
  }

  if (profile != 0U && profile != 2U) {
    return rejected(Error::UnsupportedProfile);
  }
  if (!subsamplingX || !subsamplingY) {
    return rejected(Error::UnsupportedChromaFormat);
  }
  if (bitDepth != 8U && bitDepth != 10U) {
    return rejected(Error::UnsupportedBitDepth);
  }
  const std::uint64_t width = static_cast<std::uint64_t>(widthMinusOne) + 1U;
  const std::uint64_t height = static_cast<std::uint64_t>(heightMinusOne) + 1U;
  if (width > limits.maximumWidth || height > limits.maximumHeight ||
      width > limits.maximumPixels / height) {
    return rejected(Error::DimensionLimitExceeded);
  }
  if (!vp9ColorFromColorSpace(colorSpace, color)) {
    return rejected(Error::MalformedRecord);
  }
  if (!supportedSdrColor(color)) {
    return rejected(Error::UnsupportedColorDescription);
  }

  VideoCodecConfigurationFacts result;
  result.codec = MediaCodec::Vp9;
  result.kind = MediaCodecConfigurationKind::VpcC;
  result.sampleFormat = bitDepth == 10U
                            ? MediaVideoSampleFormat::Yuv420TenBit
                            : MediaVideoSampleFormat::Yuv420EightBit;
  result.width = static_cast<std::uint32_t>(width);
  result.height = static_cast<std::uint32_t>(height);
  result.bitDepth = bitDepth;
  result.profile = profile;
  result.nalLengthBytes = 0U;
  // VP9 has no reordering: every frame is shown in coded order, and a
  // show_existing_frame repeat carries no independent presentation delay.
  result.maximumReorderFrames = 0U;
  result.color = color;
  return {Error::None, result};
}

VideoCodecConfigurationInspection inspectVp8BitstreamKeyframe(
    std::span<const std::byte> keyframe,
    VideoCodecConfigurationLimits requestedLimits) noexcept {
  if (keyframe.size() < kVp8KeyframeHeaderMaximumBytes) {
    // Ten bytes is the exact size of a VP8 key frame's uncompressed header.
    // Anything shorter cannot state a dimension, so it fails closed rather
    // than being extrapolated.
    return rejected(keyframe.empty() ? Error::EmptyConfiguration
                                     : Error::MalformedRecord);
  }
  const VideoCodecConfigurationLimits limits = effectiveLimits(requestedLimits);
  const auto bytes = asBytes(keyframe);

  // Frame tag: three bytes, little endian, RFC 6386 section 9.1.
  const std::uint32_t tag = static_cast<std::uint32_t>(bytes[0]) |
                            (static_cast<std::uint32_t>(bytes[1]) << 8U) |
                            (static_cast<std::uint32_t>(bytes[2]) << 16U);
  const std::uint32_t frameType = tag & 0x1U;
  const std::uint32_t version = (tag >> 1U) & 0x7U;
  const std::uint32_t showFrame = (tag >> 4U) & 0x1U;
  const std::uint32_t firstPartitionSize = (tag >> 5U) & 0x7FFFFU;
  if (frameType != 0U) {
    // Not a key frame. The caller located this access unit by the container's
    // own key-frame flag, so a disagreement is a mux this admission refuses.
    return rejected(Error::MalformedRecord);
  }
  if (showFrame != 1U) {
    // A key frame that is not shown cannot be the first displayed picture.
    return rejected(Error::MalformedRecord);
  }
  if (version > 3U) {
    // RFC 6386 section 9.1 defines versions 0-3; 4-7 are reserved and select
    // reconstruction filters this decoder has no defined behaviour for.
    return rejected(Error::UnsupportedProfile);
  }
  if (firstPartitionSize == 0U) {
    return rejected(Error::MalformedRecord);
  }
  if (bytes[3] != 0x9DU || bytes[4] != 0x01U || bytes[5] != 0x2AU) {
    return rejected(Error::MalformedRecord);
  }

  const std::uint32_t widthField = static_cast<std::uint32_t>(bytes[6]) |
                                   (static_cast<std::uint32_t>(bytes[7]) << 8U);
  const std::uint32_t heightField =
      static_cast<std::uint32_t>(bytes[8]) |
      (static_cast<std::uint32_t>(bytes[9]) << 8U);
  const std::uint64_t width = widthField & 0x3FFFU;
  const std::uint64_t height = heightField & 0x3FFFU;
  const std::uint32_t horizontalScale = widthField >> 14U;
  const std::uint32_t verticalScale = heightField >> 14U;
  if (horizontalScale != 0U || verticalScale != 0U) {
    // Upscaling is an optional display-time operation this square-pixel v1
    // renderer does not model, and the container's PixelWidth/PixelHeight
    // cross-check would disagree with the coded size anyway. It is a bitstream
    // option this admission declines, so it reports UnsupportedProfile rather
    // than claiming the record is malformed.
    return rejected(Error::UnsupportedProfile);
  }
  if (width == 0U || height == 0U) {
    return rejected(Error::MalformedRecord);
  }
  if (width > limits.maximumWidth || height > limits.maximumHeight ||
      width > limits.maximumPixels / height) {
    return rejected(Error::DimensionLimitExceeded);
  }

  VideoCodecConfigurationFacts result;
  result.codec = MediaCodec::Vp8;
  result.kind = MediaCodecConfigurationKind::VpcC;
  // VP8 is 8-bit 4:2:0 and nothing else: RFC 6386 has no profile, bit depth or
  // chroma-format syntax element at all.
  result.sampleFormat = MediaVideoSampleFormat::Yuv420EightBit;
  result.width = static_cast<std::uint32_t>(width);
  result.height = static_cast<std::uint32_t>(height);
  result.bitDepth = 8U;
  // The vpcC "profile" field for vp08 is 0. `version` is a reconstruction
  // filter selector, not a profile, so it is deliberately not reported here.
  result.profile = 0U;
  result.nalLengthBytes = 0U;
  // VP8 has no B-frames and no show_existing_frame: altref frames are never
  // displayed and every shown frame is shown in coded order, so decode order
  // is presentation order and no reorder buffer exists.
  result.maximumReorderFrames = 0U;
  // The bitstream states no colour description. See the header comment.
  result.color = VideoCodecColorFacts{};
  return {Error::None, result};
}

bool buildVp8CodecConfiguration(
    const VideoCodecConfigurationFacts &facts,
    std::span<std::byte, kVideoCodecVpcCBytes> configuration) noexcept {
  if (facts.codec != MediaCodec::Vp8 ||
      facts.kind != MediaCodecConfigurationKind::VpcC || facts.profile != 0U ||
      facts.bitDepth != 8U ||
      facts.sampleFormat != MediaVideoSampleFormat::Yuv420EightBit ||
      facts.width == 0U || facts.height == 0U) {
    return false;
  }
  const std::uint8_t primaries =
      facts.color.colorDescriptionPresent ? facts.color.colorPrimaries : 2U;
  const std::uint8_t transfer = facts.color.colorDescriptionPresent
                                    ? facts.color.transferCharacteristics
                                    : 2U;
  const std::uint8_t matrix =
      facts.color.colorDescriptionPresent ? facts.color.matrixCoefficients : 2U;
  constexpr std::uint8_t kChromaSubsampling420Colocated{1};
  // vp9Level() buckets by luma sample rate and is codec-neutral arithmetic;
  // VP8 has no level syntax of its own, so the field states the same
  // never-understated bound VP9 uses.
  const std::array<std::uint8_t, kVideoCodecVpcCBytes> record{
      1U,
      0U,
      0U,
      0U,
      0U,
      vp9Level(facts.width, facts.height),
      static_cast<std::uint8_t>((8U << 4U) |
                                (kChromaSubsampling420Colocated << 1U) |
                                (facts.color.fullRange ? 1U : 0U)),
      primaries,
      transfer,
      matrix,
      0U,
      0U};
  for (std::size_t index = 0; index < record.size(); ++index) {
    configuration[index] = static_cast<std::byte>(record[index]);
  }
  return true;
}

bool buildVp9CodecConfiguration(
    const VideoCodecConfigurationFacts &facts,
    std::span<std::byte, kVideoCodecVpcCBytes> configuration) noexcept {
  const MediaVideoSampleFormat expectedFormat =
      facts.bitDepth == 10U ? MediaVideoSampleFormat::Yuv420TenBit
                            : MediaVideoSampleFormat::Yuv420EightBit;
  if (facts.codec != MediaCodec::Vp9 ||
      facts.kind != MediaCodecConfigurationKind::VpcC ||
      (facts.profile != 0U && facts.profile != 2U) ||
      (facts.bitDepth != 8U && facts.bitDepth != 10U) ||
      (facts.profile == 0U) != (facts.bitDepth == 8U) ||
      facts.sampleFormat != expectedFormat || facts.width == 0U ||
      facts.height == 0U) {
    return false;
  }
  // A color description the bitstream did not carry is written as ISO/IEC
  // 23091-2 "unspecified" (2), never promoted to BT.709.
  const std::uint8_t primaries =
      facts.color.colorDescriptionPresent ? facts.color.colorPrimaries : 2U;
  const std::uint8_t transfer = facts.color.colorDescriptionPresent
                                    ? facts.color.transferCharacteristics
                                    : 2U;
  const std::uint8_t matrix =
      facts.color.colorDescriptionPresent ? facts.color.matrixCoefficients : 2U;
  constexpr std::uint8_t kChromaSubsampling420Colocated{1};
  const std::array<std::uint8_t, kVideoCodecVpcCBytes> record{
      1U,
      0U,
      0U,
      0U,
      facts.profile,
      vp9Level(facts.width, facts.height),
      static_cast<std::uint8_t>((facts.bitDepth << 4U) |
                                (kChromaSubsampling420Colocated << 1U) |
                                (facts.color.fullRange ? 1U : 0U)),
      primaries,
      transfer,
      matrix,
      0U,
      0U};
  for (std::size_t index = 0; index < record.size(); ++index) {
    configuration[index] = static_cast<std::byte>(record[index]);
  }
  return true;
}

} // namespace wam::media
