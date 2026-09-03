#include "video_toolbox_decoder.hpp"

#include "native_video_codec_capability.hpp"
#include "native_video_color.hpp"
#include "native_video_limits.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <condition_variable>
#include <exception>
#include <initializer_list>
#include <limits>
#include <mutex>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

constexpr std::size_t kMaximumCodecReorderFrames = 16;
constexpr std::size_t kAsyncErrorCapacity = 384;

constexpr VTDecodeFrameFlags
finiteAdmissionDecodeFlags(bool enableAsynchronousDecompression) noexcept {
  return enableAsynchronousDecompression
             ? kVTDecodeFrame_EnableAsynchronousDecompression
             : VTDecodeFrameFlags{0};
}

constexpr VTDecodeFrameFlags kProductionDecodeFrameFlags =
    finiteAdmissionDecodeFlags(true);
static_assert((kProductionDecodeFrameFlags &
               kVTDecodeFrame_EnableAsynchronousDecompression) != 0);
static_assert((kProductionDecodeFrameFlags &
               kVTDecodeFrame_EnableTemporalProcessing) == 0,
              "finite decoder admission cannot use temporal processing");

#if defined(WAM_NATIVE_VIDEO_TESTING)
thread_local std::optional<VideoToolboxDecoderTestCFAllocationPoint>
    gFailNextCFAllocationPoint;

bool consumeCFAllocationFailure(
    VideoToolboxDecoderTestCFAllocationPoint point) noexcept {
  if (gFailNextCFAllocationPoint != point) {
    return false;
  }
  gFailNextCFAllocationPoint.reset();
  return true;
}
#endif

void assignError(std::string *error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

std::string statusError(const char *operation, OSStatus status) {
  return std::string(operation) + " failed with OSStatus " +
         std::to_string(status);
}

class BitReader final {
public:
  explicit BitReader(std::span<const std::uint8_t> bytes) noexcept
      : bytes_(bytes) {}

  [[nodiscard]] bool readBit(bool &value) noexcept {
    std::uint64_t bit = 0;
    if (!readBits(1, bit)) {
      return false;
    }
    value = bit != 0;
    return true;
  }

  [[nodiscard]] bool readBits(std::size_t count,
                              std::uint64_t &value) noexcept {
    if (count > 64 || count > remainingBits()) {
      return false;
    }
    value = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const std::size_t byteIndex = bitOffset_ / 8;
      const std::size_t bitIndex = 7 - (bitOffset_ % 8);
      value = (value << 1U) |
              ((static_cast<std::uint64_t>(bytes_[byteIndex]) >> bitIndex) &
               1U);
      ++bitOffset_;
    }
    return true;
  }

  [[nodiscard]] bool skipBits(std::size_t count) noexcept {
    if (count > remainingBits()) {
      return false;
    }
    bitOffset_ += count;
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
      ++leadingZeroBits;
      if (leadingZeroBits > 31) {
        return false;
      }
    }
    std::uint64_t suffix = 0;
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
    std::uint32_t code = 0;
    if (!readUnsignedExpGolomb(code)) {
      return false;
    }
    const std::int64_t magnitude = static_cast<std::int64_t>(
        (static_cast<std::uint64_t>(code) + 1U) / 2U);
    const std::int64_t decoded = (code & 1U) != 0 ? magnitude : -magnitude;
    if (decoded < std::numeric_limits<std::int32_t>::min() ||
        decoded > std::numeric_limits<std::int32_t>::max()) {
      return false;
    }
    value = static_cast<std::int32_t>(decoded);
    return true;
  }

private:
  [[nodiscard]] std::size_t remainingBits() const noexcept {
    const std::size_t total = bytes_.size() * 8;
    return bitOffset_ <= total ? total - bitOffset_ : 0;
  }

  std::span<const std::uint8_t> bytes_;
  std::size_t bitOffset_{0};
};

std::optional<std::vector<std::uint8_t>>
removeEmulationPrevention(std::span<const std::uint8_t> nal,
                          std::size_t headerBytes) {
  if (nal.size() <= headerBytes) {
    return std::nullopt;
  }
  std::vector<std::uint8_t> result;
  result.reserve(nal.size() - headerBytes);
  std::size_t zeroCount = 0;
  for (std::size_t index = headerBytes; index < nal.size(); ++index) {
    const std::uint8_t byte = nal[index];
    if (zeroCount >= 2 && byte == 0x03U) {
      if (index + 1 >= nal.size() || nal[index + 1] > 0x03U) {
        return std::nullopt;
      }
      zeroCount = 0;
      continue;
    }
    result.push_back(byte);
    zeroCount = byte == 0 ? zeroCount + 1 : 0;
  }
  return std::optional<std::vector<std::uint8_t>>(std::move(result));
}

bool h264HighProfile(std::uint32_t profile) noexcept {
  constexpr std::array<std::uint32_t, 13> profiles{
      44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 244};
  return std::find(profiles.begin(), profiles.end(), profile) !=
         profiles.end();
}

constexpr bool
h264ConstraintSet3ImpliesZeroReorder(std::uint32_t profile) noexcept {
  return profile == 44 || profile == 86 || profile == 100 || profile == 110 ||
         profile == 122 || profile == 244;
}

constexpr bool h264ConstraintSet3SignalsLevel1b(
    std::uint32_t profile) noexcept {
  return profile == 66 || profile == 77 || profile == 88;
}

constexpr bool validH264ScalingDelta(std::int32_t delta) noexcept {
  return delta >= -128 && delta <= 127;
}

static_assert(h264ConstraintSet3ImpliesZeroReorder(44));
static_assert(h264ConstraintSet3ImpliesZeroReorder(244));
static_assert(!h264ConstraintSet3ImpliesZeroReorder(83));
static_assert(!h264ConstraintSet3ImpliesZeroReorder(139));
static_assert(h264ConstraintSet3SignalsLevel1b(66));
static_assert(h264ConstraintSet3SignalsLevel1b(77));
static_assert(h264ConstraintSet3SignalsLevel1b(88));
static_assert(!h264ConstraintSet3SignalsLevel1b(83));
static_assert(!h264ConstraintSet3SignalsLevel1b(100));
static_assert(validH264ScalingDelta(-128));
static_assert(validH264ScalingDelta(127));
static_assert(!validH264ScalingDelta(std::numeric_limits<std::int32_t>::min()));
static_assert(!validH264ScalingDelta(std::numeric_limits<std::int32_t>::max()));

bool skipH264ScalingList(BitReader &bits, std::size_t size) noexcept {
  std::int32_t lastScale = 8;
  std::int32_t nextScale = 8;
  for (std::size_t index = 0; index < size; ++index) {
    if (nextScale != 0) {
      std::int32_t deltaScale = 0;
      if (!bits.readSignedExpGolomb(deltaScale) ||
          !validH264ScalingDelta(deltaScale)) {
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

bool skipH264Hrd(BitReader &bits) noexcept {
  std::uint32_t cpbCountMinusOne = 0;
  if (!bits.readUnsignedExpGolomb(cpbCountMinusOne) ||
      cpbCountMinusOne > 31 || !bits.skipBits(8)) {
    return false;
  }
  for (std::uint32_t index = 0; index <= cpbCountMinusOne; ++index) {
    std::uint32_t ignored = 0;
    if (!bits.readUnsignedExpGolomb(ignored) ||
        !bits.readUnsignedExpGolomb(ignored) || !bits.skipBits(1)) {
      return false;
    }
  }
  return bits.skipBits(20);
}

struct H264VuiReorder {
  bool present{false};
  std::uint32_t reorderFrames{0};
  std::uint32_t decodedFrameBuffering{0};
};

bool parseH264Vui(BitReader &bits, H264VuiReorder &reorder) noexcept {
  bool present = false;
  std::uint64_t value = 0;
  std::uint32_t ignored = 0;
  if (!bits.readBit(present)) {
    return false;
  }
  if (present) {
    if (!bits.readBits(8, value)) {
      return false;
    }
    if (value == 255 && !bits.skipBits(32)) {
      return false;
    }
  }
  if (!bits.readBit(present) || (present && !bits.skipBits(1)) ||
      !bits.readBit(present)) {
    return false;
  }
  if (present) {
    bool colourDescription = false;
    if (!bits.skipBits(4) || !bits.readBit(colourDescription) ||
        (colourDescription && !bits.skipBits(24))) {
      return false;
    }
  }
  if (!bits.readBit(present)) {
    return false;
  }
  if (present && (!bits.readUnsignedExpGolomb(ignored) ||
                  !bits.readUnsignedExpGolomb(ignored))) {
    return false;
  }
  if (!bits.readBit(present) || (present && !bits.skipBits(65))) {
    return false;
  }
  bool nalHrd = false;
  bool vclHrd = false;
  if (!bits.readBit(nalHrd) || (nalHrd && !skipH264Hrd(bits)) ||
      !bits.readBit(vclHrd) || (vclHrd && !skipH264Hrd(bits))) {
    return false;
  }
  if ((nalHrd || vclHrd) && !bits.skipBits(1)) {
    return false;
  }
  if (!bits.skipBits(1) || !bits.readBit(reorder.present)) {
    return false;
  }
  if (!reorder.present) {
    return true;
  }
  if (!bits.skipBits(1) || !bits.readUnsignedExpGolomb(ignored) ||
      !bits.readUnsignedExpGolomb(ignored) ||
      !bits.readUnsignedExpGolomb(ignored) ||
      !bits.readUnsignedExpGolomb(ignored) ||
      !bits.readUnsignedExpGolomb(reorder.reorderFrames) ||
      !bits.readUnsignedExpGolomb(reorder.decodedFrameBuffering)) {
    return false;
  }
  return true;
}

std::optional<std::size_t> h264MaxDpbMacroblocks(std::uint32_t level,
                                                  bool level1b) {
  switch (level) {
  case 9:
  case 10:
    return 396;
  case 11:
    return level1b ? 396 : 900;
  case 12:
  case 13:
  case 20:
    return 2376;
  case 21:
    return 4752;
  case 22:
  case 30:
    return 8100;
  case 31:
    return 18000;
  case 32:
    return 20480;
  case 40:
  case 41:
    return 32768;
  case 42:
    return 34816;
  case 50:
    return 110400;
  case 51:
  case 52:
    return 184320;
  case 60:
  case 61:
  case 62:
    return 696320;
  default:
    return std::nullopt;
  }
}

std::optional<CodecReorderDepth>
parseH264SpsReorderFrames(std::span<const std::uint8_t> nal) {
  if (nal.empty() || (nal.front() & 0x1fU) != 7U) {
    return std::nullopt;
  }
  const auto rbsp = removeEmulationPrevention(nal, 1);
  if (!rbsp) {
    return std::nullopt;
  }
  BitReader bits(*rbsp);
  std::uint64_t profile = 0;
  std::uint64_t constraints = 0;
  std::uint64_t level = 0;
  std::uint32_t ignored = 0;
  if (!bits.readBits(8, profile) || !bits.readBits(8, constraints) ||
      !bits.readBits(8, level) || !bits.readUnsignedExpGolomb(ignored)) {
    return std::nullopt;
  }
  std::uint32_t chromaFormat = 1;
  if (h264HighProfile(static_cast<std::uint32_t>(profile))) {
    if (!bits.readUnsignedExpGolomb(chromaFormat) || chromaFormat > 3) {
      return std::nullopt;
    }
    if (chromaFormat == 3 && !bits.skipBits(1)) {
      return std::nullopt;
    }
    if (!bits.readUnsignedExpGolomb(ignored) ||
        !bits.readUnsignedExpGolomb(ignored) || !bits.skipBits(1)) {
      return std::nullopt;
    }
    bool scalingMatrixPresent = false;
    if (!bits.readBit(scalingMatrixPresent)) {
      return std::nullopt;
    }
    if (scalingMatrixPresent) {
      const std::size_t listCount = chromaFormat == 3 ? 12 : 8;
      for (std::size_t index = 0; index < listCount; ++index) {
        bool listPresent = false;
        if (!bits.readBit(listPresent) ||
            (listPresent &&
             !skipH264ScalingList(bits, index < 6 ? 16 : 64))) {
          return std::nullopt;
        }
      }
    }
  }
  if (!bits.readUnsignedExpGolomb(ignored)) {
    return std::nullopt;
  }
  std::uint32_t picOrderCountType = 0;
  if (!bits.readUnsignedExpGolomb(picOrderCountType) ||
      picOrderCountType > 2) {
    return std::nullopt;
  }
  if (picOrderCountType == 0) {
    if (!bits.readUnsignedExpGolomb(ignored)) {
      return std::nullopt;
    }
  } else if (picOrderCountType == 1) {
    std::int32_t ignoredSigned = 0;
    std::uint32_t cycle = 0;
    if (!bits.skipBits(1) || !bits.readSignedExpGolomb(ignoredSigned) ||
        !bits.readSignedExpGolomb(ignoredSigned) ||
        !bits.readUnsignedExpGolomb(cycle) || cycle > 255) {
      return std::nullopt;
    }
    for (std::uint32_t index = 0; index < cycle; ++index) {
      if (!bits.readSignedExpGolomb(ignoredSigned)) {
        return std::nullopt;
      }
    }
  }
  std::uint32_t maxReferenceFrames = 0;
  std::uint32_t widthMinusOne = 0;
  std::uint32_t heightMapUnitsMinusOne = 0;
  bool frameMbsOnly = false;
  if (!bits.readUnsignedExpGolomb(maxReferenceFrames) || !bits.skipBits(1) ||
      !bits.readUnsignedExpGolomb(widthMinusOne) ||
      !bits.readUnsignedExpGolomb(heightMapUnitsMinusOne) ||
      !bits.readBit(frameMbsOnly) || (!frameMbsOnly && !bits.skipBits(1)) ||
      !bits.skipBits(1)) {
    return std::nullopt;
  }
  bool cropping = false;
  if (!bits.readBit(cropping)) {
    return std::nullopt;
  }
  if (cropping) {
    for (std::size_t index = 0; index < 4; ++index) {
      if (!bits.readUnsignedExpGolomb(ignored)) {
        return std::nullopt;
      }
    }
  }
  bool vuiPresent = false;
  if (!bits.readBit(vuiPresent)) {
    return std::nullopt;
  }
  H264VuiReorder vui;
  if (vuiPresent && !parseH264Vui(bits, vui)) {
    return std::nullopt;
  }

  const auto profileIdc = static_cast<std::uint32_t>(profile);
  const bool constraintSet3 = (constraints & 0x10U) != 0;
  const auto maxDpbMbs = h264MaxDpbMacroblocks(
      static_cast<std::uint32_t>(level),
      constraintSet3 && h264ConstraintSet3SignalsLevel1b(profileIdc));
  const std::uint64_t widthMbs = std::uint64_t{widthMinusOne} + 1;
  const std::uint64_t heightMbs =
      (std::uint64_t{heightMapUnitsMinusOne} + 1) *
      (frameMbsOnly ? 1U : 2U);
  if (!maxDpbMbs || widthMbs == 0 || heightMbs == 0 ||
      widthMbs > std::numeric_limits<std::uint64_t>::max() / heightMbs) {
    return std::nullopt;
  }
  const std::uint64_t pictureMbs = widthMbs * heightMbs;
  const std::size_t maxDpbFrames = static_cast<std::size_t>(std::min<
      std::uint64_t>(kMaximumCodecReorderFrames, *maxDpbMbs / pictureMbs));
  if (maxDpbFrames == 0 || maxReferenceFrames > maxDpbFrames) {
    return std::nullopt;
  }
  // vui.present is bitstream_restriction_flag: the stream states
  // max_num_reorder_frames itself, and that statement is authoritative.
  if (vui.present) {
    if (vui.reorderFrames > vui.decodedFrameBuffering ||
        vui.decodedFrameBuffering > maxDpbFrames ||
        vui.decodedFrameBuffering < maxReferenceFrames) {
      return std::nullopt;
    }
    return CodecReorderDepth{static_cast<std::size_t>(vui.reorderFrames),
                             CodecReorderDepthOrigin::Declared};
  }
  // Nothing was stated. E.2.1's two inference arms both apply here. The
  // constraint_set3 arm infers an exact zero from a profile constraint the
  // stream really does carry, so it is as good as a declaration; the general
  // arm infers MaxDpbFrames, which is only a ceiling.
  if (constraintSet3 && h264ConstraintSet3ImpliesZeroReorder(profileIdc)) {
    return CodecReorderDepth{0, CodecReorderDepthOrigin::Declared};
  }
  return CodecReorderDepth{maxDpbFrames, CodecReorderDepthOrigin::Inferred};
}

bool skipHevcProfileTierLevel(BitReader &bits,
                              std::uint32_t maxSubLayersMinusOne) noexcept {
  if (!bits.skipBits(96)) {
    return false;
  }
  std::array<bool, 8> profilePresent{};
  std::array<bool, 8> levelPresent{};
  for (std::uint32_t index = 0; index < maxSubLayersMinusOne; ++index) {
    if (!bits.readBit(profilePresent[index]) ||
        !bits.readBit(levelPresent[index])) {
      return false;
    }
  }
  if (maxSubLayersMinusOne > 0) {
    for (std::uint32_t index = maxSubLayersMinusOne; index < 8; ++index) {
      if (!bits.skipBits(2)) {
        return false;
      }
    }
  }
  for (std::uint32_t index = 0; index < maxSubLayersMinusOne; ++index) {
    if ((profilePresent[index] && !bits.skipBits(88)) ||
        (levelPresent[index] && !bits.skipBits(8))) {
      return false;
    }
  }
  return true;
}

std::optional<std::size_t>
parseHevcSpsReorderFrames(std::span<const std::uint8_t> nal) {
  if (nal.size() < 3 || ((nal.front() >> 1U) & 0x3fU) != 33U) {
    return std::nullopt;
  }
  const auto rbsp = removeEmulationPrevention(nal, 2);
  if (!rbsp) {
    return std::nullopt;
  }
  BitReader bits(*rbsp);
  std::uint64_t ignoredBits = 0;
  std::uint64_t subLayers = 0;
  if (!bits.readBits(4, ignoredBits) || !bits.readBits(3, subLayers) ||
      subLayers > 6 || !bits.skipBits(1) ||
      !skipHevcProfileTierLevel(bits, static_cast<std::uint32_t>(subLayers))) {
    return std::nullopt;
  }
  std::uint32_t ignored = 0;
  std::uint32_t chromaFormat = 0;
  if (!bits.readUnsignedExpGolomb(ignored) ||
      !bits.readUnsignedExpGolomb(chromaFormat) || chromaFormat > 3 ||
      (chromaFormat == 3 && !bits.skipBits(1)) ||
      !bits.readUnsignedExpGolomb(ignored) ||
      !bits.readUnsignedExpGolomb(ignored)) {
    return std::nullopt;
  }
  bool conformanceWindow = false;
  if (!bits.readBit(conformanceWindow)) {
    return std::nullopt;
  }
  if (conformanceWindow) {
    for (std::size_t index = 0; index < 4; ++index) {
      if (!bits.readUnsignedExpGolomb(ignored)) {
        return std::nullopt;
      }
    }
  }
  if (!bits.readUnsignedExpGolomb(ignored) ||
      !bits.readUnsignedExpGolomb(ignored) ||
      !bits.readUnsignedExpGolomb(ignored)) {
    return std::nullopt;
  }
  bool orderingInfoPresent = false;
  if (!bits.readBit(orderingInfoPresent)) {
    return std::nullopt;
  }
  const std::uint32_t firstLayer =
      orderingInfoPresent ? 0 : static_cast<std::uint32_t>(subLayers);
  std::size_t maximumReorder = 0;
  std::uint32_t previousBuffering = 0;
  std::uint32_t previousReorder = 0;
  for (std::uint32_t layer = firstLayer; layer <= subLayers; ++layer) {
    std::uint32_t bufferingMinusOne = 0;
    std::uint32_t reorder = 0;
    if (!bits.readUnsignedExpGolomb(bufferingMinusOne) ||
        !bits.readUnsignedExpGolomb(reorder) ||
        !bits.readUnsignedExpGolomb(ignored) ||
        bufferingMinusOne >= kMaximumCodecReorderFrames ||
        reorder > bufferingMinusOne ||
        (layer > firstLayer &&
         (bufferingMinusOne < previousBuffering || reorder < previousReorder))) {
      return std::nullopt;
    }
    previousBuffering = bufferingMinusOne;
    previousReorder = reorder;
    maximumReorder = std::max(maximumReorder,
                              static_cast<std::size_t>(reorder));
  }
  return maximumReorder;
}

std::optional<CodecReorderDepth>
deriveCodecReorderDepth(const VideoStreamConfiguration &configuration) {
  const auto bytes = std::span<const std::uint8_t>(
      reinterpret_cast<const std::uint8_t *>(
          configuration.codecConfiguration.data()),
      configuration.codecConfiguration.size());
  if (configuration.codec == kCMVideoCodecType_H264) {
    if (bytes.size() < 7 || bytes[0] != 1) {
      return std::nullopt;
    }
    std::size_t offset = 6;
    const std::size_t spsCount = bytes[5] & 0x1fU;
    std::optional<CodecReorderDepth> maximum;
    for (std::size_t index = 0; index < spsCount; ++index) {
      if (offset + 2 > bytes.size()) {
        return std::nullopt;
      }
      const std::size_t length =
          (static_cast<std::size_t>(bytes[offset]) << 8U) | bytes[offset + 1];
      offset += 2;
      if (length == 0 || length > bytes.size() - offset) {
        return std::nullopt;
      }
      const auto reorder = parseH264SpsReorderFrames(bytes.subspan(offset, length));
      if (!reorder) {
        return std::nullopt;
      }
      // The parameter set that demands the most decides the depth, and a tie
      // keeps the stronger authority: one set's declaration must not be
      // downgraded to an inference just because a second set merely inferred
      // the same number.
      if (!maximum || reorder->frames > maximum->frames ||
          (reorder->frames == maximum->frames &&
           reorder->origin == CodecReorderDepthOrigin::Declared)) {
        maximum = *reorder;
      }
      offset += length;
    }
    return maximum;
  }
  if (configuration.codec == kCMVideoCodecType_HEVC) {
    if (bytes.size() < 23 || bytes[0] != 1) {
      return std::nullopt;
    }
    std::size_t offset = 23;
    const std::size_t arrayCount = bytes[22];
    // HEVC always states sps_max_num_reorder_pics -- it is a mandatory element
    // of the SPS, not an optional restriction section -- so every HEVC depth
    // this returns is declared and there is no inference arm to mark.
    std::optional<std::size_t> maximum;
    for (std::size_t array = 0; array < arrayCount; ++array) {
      if (offset + 3 > bytes.size()) {
        return std::nullopt;
      }
      const std::uint8_t nalType = bytes[offset] & 0x3fU;
      const std::size_t nalCount =
          (static_cast<std::size_t>(bytes[offset + 1]) << 8U) |
          bytes[offset + 2];
      offset += 3;
      for (std::size_t index = 0; index < nalCount; ++index) {
        if (offset + 2 > bytes.size()) {
          return std::nullopt;
        }
        const std::size_t length =
            (static_cast<std::size_t>(bytes[offset]) << 8U) |
            bytes[offset + 1];
        offset += 2;
        if (length == 0 || length > bytes.size() - offset) {
          return std::nullopt;
        }
        if (nalType == 33U) {
          const auto reorder =
              parseHevcSpsReorderFrames(bytes.subspan(offset, length));
          if (!reorder) {
            return std::nullopt;
          }
          maximum = std::max(maximum.value_or(0), *reorder);
        }
        offset += length;
      }
    }
    if (!maximum) {
      return std::nullopt;
    }
    return CodecReorderDepth{*maximum, CodecReorderDepthOrigin::Declared};
  }
  if (configuration.codec == kCMVideoCodecType_MPEG2Video) {
    // One, and it is a property of the codec rather than of the stream.
    //
    // MPEG-2 reorders through exactly two reference frame stores: a B picture
    // is output at its own decode position, and the only picture ever held
    // back is the FUTURE anchor decoded ahead of the B pictures that reference
    // it. That is true regardless of how many consecutive B pictures a GOP
    // codes -- an M of 3 and an M of 12 both hold exactly one anchor -- so the
    // depth is 1 for every legal MPEG-2 stream and never needs a bitstream
    // parse. There is nothing to parse in any case: MPEG-2 carries no decoder
    // configuration record, so `bytes` is empty here by contract.
    //
    // Stating 1 rather than 0 costs one retained frame on a stream that codes
    // no B pictures at all, which both of this project's MPEG-2 fixtures are
    // (ffmpeg's mpeg2video encoder defaults to max_b_frames = 0, so `-g 12`
    // produces a flat I-P-P-...-P GOP, measured 2026-08-20). That cost is one
    // frame of startup hold at SD rates and is the right side to be wrong on:
    // understating the depth reorders output, while overstating it by one
    // delays it by one frame.
    if (!bytes.empty()) {
      return std::nullopt;
    }
    return CodecReorderDepth{1, CodecReorderDepthOrigin::Declared};
  }
  if (configuration.codec == kCMVideoCodecType_MPEG4Video) {
    // Zero, and it is a property of the admitted PROFILE rather than of the
    // codec. MPEG-4 Part 2 as a whole reorders exactly like MPEG-2 -- one
    // future anchor held back across the B-VOPs that reference it -- but
    // B-VOPs are an Advanced Simple Profile tool, and Advanced Simple Profile
    // never reaches this decoder: Apple's 'mp4v' decoder refuses it at session
    // creation, so media::inspectMpeg4VisualHeaders() admits Simple Profile
    // alone. Simple Profile codes I-VOPs and P-VOPs only, so decode order IS
    // presentation order and nothing is ever held back.
    //
    // That is also why the Matroska route's missing decode timestamps cost
    // this codec nothing: with no reordering there is no decode-versus-
    // presentation displacement for the A/V merge lead to reconstruct.
    //
    // The record is the esds the demuxer synthesized, which is never empty --
    // the inverse of the MPEG-2 arm above.
    if (bytes.empty()) {
      return std::nullopt;
    }
    return CodecReorderDepth{0, CodecReorderDepthOrigin::Declared};
  }
  if (configuration.codec == kCMVideoCodecType_VP9) {
    // VP9 has no output reordering. Alternate-reference ("hidden") frames are
    // decoded but never output at their own decode position; they reach the
    // output only through show_existing_frame, which emits an already-decoded
    // frame at the point the bitstream asks for it. Output order therefore
    // equals bitstream order, which is why VP9 containers carry PTS == DTS on
    // every packet. A vpcC record is still required for the session, but it
    // carries no reorder signal at all, so the depth is a property of the
    // codec: zero.
    if (bytes.size() < 12 || bytes[0] != 1) {
      return std::nullopt;
    }
    return CodecReorderDepth{0, CodecReorderDepthOrigin::Declared};
  }
  if (configuration.codec == kCMVideoCodecType_AV1) {
    // AV1 shares VP9's output model (show_existing_frame, no composition
    // offsets), so its intrinsic reorder depth is also zero. The one signal a
    // stream can carry is the av1C initial presentation delay, which is the
    // number of frames a conforming decoder may buffer before its first
    // output; honour it as an upper bound when present.
    //
    // This value is deliberately NOT rounded up "to be safe". The pipeline
    // treats it as a delivery hold floor, not merely a memory bound: the
    // ordered drain refuses to emit a frame until more than this many frames
    // are retained (see the presentable/moreFrames predicates), so every extra
    // unit is a frame of added presentation latency and one more retained
    // IOSurface. A value above maxPendingPresentationFrames also hard-fails
    // configure(), which is the intended clean fallback rather than a silent
    // over-allocation.
    //
    // av1C byte 3: reserved(3) | initial_presentation_delay_present(1) |
    //              initial_presentation_delay_minus_one(4)
    if (bytes.size() < 4 || (bytes[0] & 0x7fU) != 1U ||
        (bytes[0] & 0x80U) == 0U) {
      return std::nullopt;
    }
    if ((bytes[3] & 0x10U) == 0U) {
      return CodecReorderDepth{0, CodecReorderDepthOrigin::Declared};
    }
    return CodecReorderDepth{static_cast<std::size_t>(bytes[3] & 0x0fU) + 1U,
                             CodecReorderDepthOrigin::Declared};
  }
  return std::nullopt;
}

struct AsyncDecodeState {
  enum class FrameRefConSlotState : std::uint8_t {
    Available,
    Reserved,
    Submitted,
    CallbackComplete,
  };

  struct FrameRefConSlot {
    FrameRefConSlotState state{FrameRefConSlotState::Available};
    std::uint64_t submissionSequence{0};
    FrameTiming timing{};
    std::uint64_t compressedBytes{0};
    bool directCompressedStorage{false};
  };

  explicit AsyncDecodeState(
      VideoToolboxDecoderProgressHandler progress,
      std::size_t maxInFlightFrames)
      : frameRefConSlots(maxInFlightFrames), progressHandler(progress) {}

  struct CompletedDecode {
    std::uint64_t submissionSequence{0};
    std::optional<FrameLease> frame;
    FrameRefConSlot *slot{nullptr};
  };

  struct AsyncError {
    std::array<char, kAsyncErrorCapacity> bytes{};
    std::size_t size{0};

    void assign(std::string_view message) noexcept {
      size = std::min(message.size(), bytes.size());
      if (size != 0) {
        std::memcpy(bytes.data(), message.data(), size);
      }
    }

    void reset() noexcept { size = 0; }

    [[nodiscard]] bool present() const noexcept { return size != 0; }
  };

  mutable std::mutex mutex;
  std::mutex deliveryMutex;
  std::condition_variable completion;
  DecodedFrameSink *sink{nullptr};
  std::uint64_t generation{0};
  std::size_t inFlight{0};
  // Counts callbacks that have entered the persistent C trampoline but have
  // not returned. Teardown waits for this tail independently of ordered
  // in-flight retirement, whose credit may reach zero before notifyProgress.
  std::size_t activeCallbacks{0};
  std::uint64_t submitted{0};
  std::uint64_t directSampleBufferSubmissions{0};
  std::uint64_t directSampleBufferBytes{0};
  std::uint64_t copiedSpanSubmissions{0};
  std::uint64_t copiedSpanBytes{0};
  std::uint64_t currentDirectCompressedBytes{0};
  std::uint64_t peakDirectCompressedBytes{0};
  std::uint64_t currentCopiedCompressedBytes{0};
  std::uint64_t peakCopiedCompressedBytes{0};
  std::uint64_t currentCompressedBytes{0};
  std::uint64_t peakCompressedBytes{0};
  std::uint64_t delivered{0};
  std::uint64_t dropped{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t sinkBackpressureDrops{0};
  std::uint64_t sinkBackpressureRetries{0};
  std::uint64_t endOfStreamBackpressureRetries{0};
  std::uint64_t surfaceBudgetRejections{0};
  std::uint64_t outOfOrderDrops{0};
  std::size_t codecReorderFrames{0};
  std::size_t maxRetainedFrames{0};
  std::size_t peakPendingPresentationFrames{0};
  std::uint64_t nextSubmissionSequence{0};
  std::uint64_t nextCompletionSequence{0};
  // Stable storage passed to VideoToolbox as sourceFrameRefCon. A slot is not
  // reusable merely because its callback arrived out of order: it returns to
  // Available in the same transaction that retires its ordered in-flight
  // credit. The vector is sized once at decoder construction and never
  // resized, so every pointer remains valid for the decoder lifetime.
  std::vector<FrameRefConSlot> frameRefConSlots;
  std::vector<CompletedDecode> completedDecodes;
  std::vector<FrameLease> pendingPresentationFrames;
  VideoToolboxOutputInterop outputInterop{VideoToolboxOutputInterop::Metal};
  OSType expectedOutputPixelFormat{0};
  OSType actualOutputPixelFormat{0};
  CMVideoDimensions expectedCodedDimensions{0, 0};
  CMTime lastDeliveredPresentationTime{kCMTimeInvalid};
  bool discarding{false};
  bool callbackFailedClosed{false};
  // Set under deliveryMutex + mutex before FinishDelayedFrames. Once set,
  // callbacks continue restoring decode/PTS order and retiring admission, but
  // retain every resulting frame for owner-progressive EOS draining.
  bool endOfStreamBegun{false};
  AsyncError lastError;
  const VideoToolboxDecoderProgressHandler progressHandler;
#if defined(WAM_NATIVE_VIDEO_TESTING)
  std::optional<VideoToolboxDecoderTestAllocationPoint>
      failNextAllocationPoint;
  bool permitSyntheticCallbackFrame{false};
  bool permitSyntheticOutputSurface{false};
#endif
};

void assignAsyncErrorLocked(AsyncDecodeState &state,
                            std::string_view message) noexcept {
  state.lastError.assign(message);
}

void incrementSaturated(std::uint64_t &value) noexcept {
  if (value != std::numeric_limits<std::uint64_t>::max()) {
    ++value;
  }
}

[[nodiscard]] std::uint64_t saturatedAdd(std::uint64_t left,
                                         std::uint64_t right) noexcept {
  return right > std::numeric_limits<std::uint64_t>::max() - left
             ? std::numeric_limits<std::uint64_t>::max()
             : left + right;
}

void updatePeak(std::uint64_t &peak, std::uint64_t current) noexcept {
  peak = std::max(peak, current);
}

void retireCompressedChargeLocked(
    AsyncDecodeState &state,
    AsyncDecodeState::FrameRefConSlot &slot) noexcept {
  const std::uint64_t bytes = slot.compressedBytes;
  if (slot.directCompressedStorage) {
    state.currentDirectCompressedBytes =
        state.currentDirectCompressedBytes >= bytes
            ? state.currentDirectCompressedBytes - bytes
            : 0;
  } else {
    state.currentCopiedCompressedBytes =
        state.currentCopiedCompressedBytes >= bytes
            ? state.currentCopiedCompressedBytes - bytes
            : 0;
  }
  state.currentCompressedBytes = state.currentCompressedBytes >= bytes
                                     ? state.currentCompressedBytes - bytes
                                     : 0;
  slot.compressedBytes = 0;
  slot.directCompressedStorage = false;
}

void notifyProgress(const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  const VideoToolboxDecoderProgressHandler handler = state->progressHandler;
  if (handler.function != nullptr) {
    handler.function(handler.context);
  }
}

void releaseReservedDecodeCapacity(
    const std::shared_ptr<AsyncDecodeState> &state,
    AsyncDecodeState::FrameRefConSlot *slot) {
  std::lock_guard lock(state->mutex);
  if (slot == nullptr ||
      slot->state != AsyncDecodeState::FrameRefConSlotState::Reserved ||
      state->inFlight == 0) {
    assignAsyncErrorLocked(
        *state, "VideoToolbox reserved decode capacity is inconsistent");
    return;
  }
  slot->state = AsyncDecodeState::FrameRefConSlotState::Available;
  slot->submissionSequence = 0;
  slot->timing = {};
  slot->compressedBytes = 0;
  slot->directCompressedStorage = false;
  --state->inFlight;
  state->completion.notify_all();
}

void recordAsyncError(const std::shared_ptr<AsyncDecodeState> &state,
                      std::string_view message) noexcept {
  // This function is used by catch handlers on a foreign Apple callback. It
  // must remain allocation-free, and even a pathological mutex failure must
  // not escape through the C/Objective-C callback boundary.
  try {
    std::lock_guard lock(state->mutex);
    assignAsyncErrorLocked(*state, message);
  } catch (...) {
  }
}

#if defined(WAM_NATIVE_VIDEO_TESTING)
void maybeFailCallbackAllocationLocked(
    AsyncDecodeState &state,
    VideoToolboxDecoderTestAllocationPoint point) {
  if (state.failNextAllocationPoint == point) {
    state.failNextAllocationPoint.reset();
    throw std::bad_alloc();
  }
}
#endif

bool timeBefore(CMTime left, CMTime right) noexcept {
  return CMTIME_IS_NUMERIC(left) && CMTIME_IS_NUMERIC(right) &&
         CMTimeCompare(left, right) < 0;
}

void collectCompletedDecodesLocked(AsyncDecodeState &state) {
  while (!state.completedDecodes.empty() &&
         state.completedDecodes.front().submissionSequence ==
             state.nextCompletionSequence) {
    AsyncDecodeState::CompletedDecode completed =
        std::move(state.completedDecodes.front());
    state.completedDecodes.erase(state.completedDecodes.begin());
    if (completed.slot != nullptr) {
      if (completed.slot->state !=
          AsyncDecodeState::FrameRefConSlotState::CallbackComplete) {
        state.callbackFailedClosed = true;
        state.discarding = true;
        assignAsyncErrorLocked(
            state, "VideoToolbox frame-refcon slot retired out of state");
      }
      completed.slot->state =
          AsyncDecodeState::FrameRefConSlotState::Available;
      retireCompressedChargeLocked(state, *completed.slot);
      completed.slot->submissionSequence = 0;
      completed.slot->timing = {};
    }
    if (state.inFlight == 0) {
      state.callbackFailedClosed = true;
      state.discarding = true;
      assignAsyncErrorLocked(
          state, "VideoToolbox ordered completion lost its admission credit");
    } else {
      --state.inFlight;
    }
    // Slot availability, its compressed-byte refund, and the matching
    // admission-credit refund are one state-mutex transaction. In particular,
    // a memoryFacts() snapshot can never observe an Available slot whose
    // in-flight credit is still live (or count the same completion as both
    // in-flight and presentation-owned).
    state.completion.notify_all();
    ++state.nextCompletionSequence;

    if (!completed.frame) {
      continue;
    }
    if (timeBefore(completed.frame->timing().presentationTime,
                   state.lastDeliveredPresentationTime)) {
      ++state.dropped;
      ++state.outOfOrderDrops;
      assignAsyncErrorLocked(
          state,
          "decoded stream exceeded its admitted presentation-reorder depth");
      continue;
    }
    if (state.pendingPresentationFrames.size() >= state.maxRetainedFrames) {
      // This is unreachable when reserveDecodeCapacityLocked() and the
      // submission-order credits agree. Fail closed rather than permit a
      // callback-owned vector allocation beyond its reserved ceiling.
      completed.frame.reset();
      state.callbackFailedClosed = true;
      state.discarding = true;
      ++state.dropped;
      assignAsyncErrorLocked(
          state, "decoded-frame retention exceeded its bounded admission");
      continue;
    }
    auto insertion = std::upper_bound(
        state.pendingPresentationFrames.begin(),
        state.pendingPresentationFrames.end(), *completed.frame,
        [](const FrameLease &left, const FrameLease &right) {
          return timeBefore(left.timing().presentationTime,
                            right.timing().presentationTime);
        });
#if defined(WAM_NATIVE_VIDEO_TESTING)
    maybeFailCallbackAllocationLocked(
        state, VideoToolboxDecoderTestAllocationPoint::PendingPresentation);
#endif
    state.pendingPresentationFrames.insert(insertion,
                                           std::move(*completed.frame));
    state.peakPendingPresentationFrames =
        std::max(state.peakPendingPresentationFrames,
                 state.pendingPresentationFrames.size());
  }
}

void resetPresentationState(
    const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  std::vector<FrameLease> retiredFrames;
  std::lock_guard deliveryLock(state->deliveryMutex);
  {
    std::lock_guard lock(state->mutex);
    retiredFrames.swap(state->pendingPresentationFrames);
    state->completedDecodes.clear();
    state->nextSubmissionSequence = 0;
    state->nextCompletionSequence = 0;
    for (AsyncDecodeState::FrameRefConSlot &slot :
         state->frameRefConSlots) {
      slot.state = AsyncDecodeState::FrameRefConSlotState::Available;
      slot.submissionSequence = 0;
      slot.timing = {};
      slot.compressedBytes = 0;
      slot.directCompressedStorage = false;
    }
    state->currentDirectCompressedBytes = 0;
    state->currentCopiedCompressedBytes = 0;
    state->currentCompressedBytes = 0;
    state->lastDeliveredPresentationTime = kCMTimeInvalid;
    state->callbackFailedClosed = false;
    state->endOfStreamBegun = false;
  }
  // Release decoder surfaces outside the state mutex, then return the empty
  // vector's pre-reserved storage before another callback can enter.
  retiredFrames.clear();
  {
    std::lock_guard lock(state->mutex);
    state->pendingPresentationFrames.swap(retiredFrames);
  }
}

bool reserveCallbackStorage(
    const std::shared_ptr<AsyncDecodeState> &state,
    std::size_t maxInFlightFrames,
    std::size_t maxPendingPresentationFrames, std::string *error) {
  if (maxPendingPresentationFrames ==
          std::numeric_limits<std::size_t>::max() ||
      maxInFlightFrames >
          std::numeric_limits<std::size_t>::max() -
              maxPendingPresentationFrames - 1U) {
    assignError(error, "VideoToolbox callback storage bound overflows size_t");
    return false;
  }
  const std::size_t deliveryCapacity =
      maxInFlightFrames + maxPendingPresentationFrames;

  try {
    std::lock_guard deliveryLock(state->deliveryMutex);
    std::lock_guard stateLock(state->mutex);
    if (maxInFlightFrames > state->completedDecodes.max_size() ||
        deliveryCapacity > state->pendingPresentationFrames.max_size()) {
      assignError(error,
                  "VideoToolbox callback storage bound exceeds vector limits");
      return false;
    }
    state->completedDecodes.reserve(maxInFlightFrames);
    // During owner-progressive EOS, callbacks retain rather than enqueue every
    // completed frame. The combined reorder + accepted-in-flight ceiling is
    // the already-derived deliveryCapacity, and the process-wide IOSurface
    // budget remains the harder decoded-memory bound.
    state->pendingPresentationFrames.reserve(deliveryCapacity);
  } catch (const std::bad_alloc &) {
    assignError(error,
                "could not reserve bounded VideoToolbox callback storage");
    return false;
  } catch (const std::length_error &) {
    assignError(error,
                "VideoToolbox callback storage bound exceeds vector limits");
    return false;
  }
  return true;
}

struct BiPlanarSurfaceLayout {
  std::size_t lumaBytesPerElement{0};
  std::size_t chromaBytesPerElement{0};
};

std::optional<BiPlanarSurfaceLayout>
biPlanarSurfaceLayout(OSType pixelFormat) noexcept {
  switch (pixelFormat) {
  case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
  case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    return BiPlanarSurfaceLayout{1, 2};
  case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
  case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    return BiPlanarSurfaceLayout{2, 4};
  default:
    return std::nullopt;
  }
}

// The AGX lossless-compressed counterpart of a bounded native decode format,
// or 0 for a format that has none. Apple silicon video decoders emit these
// natively; a display layer consumes them unchanged, while any in-process
// sampler needs the uncompressed form and therefore pays a per-frame
// VTPixelTransferSession to get it.
OSType losslessCounterpartFormat(OSType pixelFormat) noexcept {
  switch (pixelFormat) {
  case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    return kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange;
  case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    return kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange;
  // The 10-bit lossless forms are compressed-*packed*: they carry no padding
  // bits between pixels, so they are not layout-compatible with the padded
  // 'x420'/'xf20' surfaces an in-process sampler expects. That costs nothing
  // here, because a display layer never inspects the layout.
  //
  // The FullRange enumerator is spelled as its four-character code '&xf0'
  // (0x26786630) because SDKs older than the one on the development machine
  // (e.g. the Xcode 15.4 SDK on CI runners) declare only the VideoRange
  // form; the values are ABI, not SDK policy, so the literal is stable.
  case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    return kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange;
  case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    return 0x26786630;  // kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange
  default:
    return 0;
  }
}

// The exact set of output formats a given interop contract admits. Pinned
// contracts admit only what they asked for; the display-layer contract leaves
// the format unpinned and therefore also admits the lossless counterpart the
// decoder produces natively. Nothing else is ever admitted -- an unpinned
// session that returned, say, BGRA would be a silent per-frame conversion in
// the other direction, which is precisely the cost this contract removes.
// The full-range twin of a bounded native decode format, or 0 for one that has
// none. requestedPixelFormat() always names a VIDEO-range format, but the
// display-layer session is deliberately left unpinned (see the pin gate in the
// session builder), so VideoToolbox delivers whatever the stream's
// video_full_range_flag implies -- '420f' for full-range material. Before this
// twin existed, such a stream failed the output contract on its FIRST frame.
OSType fullRangeCounterpartFormat(OSType pixelFormat) noexcept {
  switch (pixelFormat) {
  case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  default:
    return 0;
  }
}

bool admitsOutputPixelFormat(OSType pixelFormat, OSType expectedPixelFormat,
                             VideoToolboxOutputInterop outputInterop) noexcept {
  if (pixelFormat == expectedPixelFormat) {
    return true;
  }
  if (outputInterop != VideoToolboxOutputInterop::DisplayLayer) {
    return false;
  }
  // Only the display layer widens, and for the same reason in both directions:
  // it never SAMPLES the surface, so the surface's own pixel format is what
  // carries depth and range to WindowServer. An in-process sampler must keep
  // getting exactly the format it was pinned to, because its shaders encode
  // the range assumption -- for those interops the session IS pinned, and
  // VideoToolbox converts a full-range stream down to the requested range
  // itself, so the equality above is already the whole rule.
  const OSType fullRange = fullRangeCounterpartFormat(expectedPixelFormat);
  for (const OSType admitted :
       {expectedPixelFormat, fullRange,
        losslessCounterpartFormat(expectedPixelFormat),
        fullRange == 0 ? OSType{0} : losslessCounterpartFormat(fullRange)}) {
    if (admitted != 0 && pixelFormat == admitted) {
      return true;
    }
  }
  return false;
}

bool validateOutputSurfaceContract(CVPixelBufferRef pixelBuffer,
                                   OSType expectedPixelFormat,
                                   VideoToolboxOutputInterop outputInterop,
                                   std::string *error) {
  if (pixelBuffer == nullptr) {
    assignError(error, "VideoToolbox returned no decoded pixel buffer");
    return false;
  }
  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  if (!admitsOutputPixelFormat(pixelFormat, expectedPixelFormat,
                               outputInterop)) {
    assignError(error,
                "VideoToolbox output pixel format " +
                    std::to_string(pixelFormat) +
                    " did not match the bounded native decode contract " +
                    std::to_string(expectedPixelFormat));
    return false;
  }
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
  if (surface == nullptr) {
    assignError(error, "VideoToolbox produced a frame without an IOSurface");
    return false;
  }
  if (outputInterop == VideoToolboxOutputInterop::Metal ||
      outputInterop == VideoToolboxOutputInterop::DisplayLayer) {
    // A display layer consumes whatever biplanar surface the decoder produced,
    // including the lossless one, so there is no plane layout to verify beyond
    // the IOSurface backing already proven above.
    return true;
  }
  if (outputInterop != VideoToolboxOutputInterop::OpenGL) {
    assignError(error, "unsupported VideoToolbox output interop contract");
    return false;
  }

  const auto layout = biPlanarSurfaceLayout(pixelFormat);
  if (!layout) {
    assignError(error,
                "OpenGL IOSurface import requires NV12 or P010 output");
    return false;
  }
  if (!CVPixelBufferIsPlanar(pixelBuffer) ||
      CVPixelBufferGetPlaneCount(pixelBuffer) != 2 ||
      IOSurfaceGetPlaneCount(surface) != 2) {
    assignError(error,
                "OpenGL IOSurface output must expose exactly two planes");
    return false;
  }
  const OSType surfacePixelFormat = IOSurfaceGetPixelFormat(surface);
  // CoreVideo-owned decoder surfaces normally carry the CV fourcc. A zero
  // IOSurface fourcc is explicitly unspecified and does not prevent CGL plane
  // binding; a contradictory nonzero value is unsafe and must fail closed.
  if (surfacePixelFormat != 0 && surfacePixelFormat != pixelFormat) {
    assignError(error,
                "IOSurface pixel format does not match its CVPixelBuffer");
    return false;
  }

  const std::size_t width = CVPixelBufferGetWidth(pixelBuffer);
  const std::size_t height = CVPixelBufferGetHeight(pixelBuffer);
  if (width == 0 || height == 0) {
    assignError(error, "decoded IOSurface has empty dimensions");
    return false;
  }
  const std::array<std::size_t, 2> expectedWidths{
      width, width / 2U + width % 2U};
  const std::array<std::size_t, 2> expectedHeights{height,
                                                   height / 2U + height % 2U};
  const std::array<std::size_t, 2> expectedBytesPerElement{
      layout->lumaBytesPerElement, layout->chromaBytesPerElement};
  for (std::size_t plane = 0; plane < 2; ++plane) {
    const std::size_t cvWidth =
        CVPixelBufferGetWidthOfPlane(pixelBuffer, plane);
    const std::size_t cvHeight =
        CVPixelBufferGetHeightOfPlane(pixelBuffer, plane);
    const std::size_t cvBytesPerRow =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane);
    const std::size_t surfaceWidth = IOSurfaceGetWidthOfPlane(surface, plane);
    const std::size_t surfaceHeight =
        IOSurfaceGetHeightOfPlane(surface, plane);
    const std::size_t surfaceBytesPerElement =
        IOSurfaceGetBytesPerElementOfPlane(surface, plane);
    const std::size_t surfaceBytesPerRow =
        IOSurfaceGetBytesPerRowOfPlane(surface, plane);
    if (cvWidth != expectedWidths[plane] ||
        cvHeight != expectedHeights[plane] || surfaceWidth != cvWidth ||
        surfaceHeight != cvHeight ||
        surfaceBytesPerElement != expectedBytesPerElement[plane] ||
        surfaceBytesPerRow != cvBytesPerRow ||
        cvWidth > std::numeric_limits<std::size_t>::max() /
                      expectedBytesPerElement[plane] ||
        cvBytesPerRow < cvWidth * expectedBytesPerElement[plane]) {
      assignError(error,
                  "decoded IOSurface plane " + std::to_string(plane) +
                      " does not match the exact " +
                      (pixelFormat ==
                               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                           pixelFormat ==
                               kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                       ? "NV12"
                       : "P010") +
                      " OpenGL texture layout");
      return false;
    }
  }
  return true;
}

bool validateDecodedDimensions(CVPixelBufferRef pixelBuffer,
                               CMVideoDimensions expectedDimensions,
                               std::string *error) {
  if (pixelBuffer == nullptr) {
    assignError(error, "VideoToolbox returned no decoded pixel buffer");
    return false;
  }
  if (expectedDimensions.width <= 0 || expectedDimensions.height <= 0) {
    assignError(error,
                "VideoToolbox decoder has no configured coded dimensions");
    return false;
  }
  if (CVPixelBufferGetWidth(pixelBuffer) !=
          static_cast<std::size_t>(expectedDimensions.width) ||
      CVPixelBufferGetHeight(pixelBuffer) !=
          static_cast<std::size_t>(expectedDimensions.height)) {
    assignError(error,
                "VideoToolbox decoded dimensions did not match the "
                "configured coded dimensions");
    return false;
  }
  return true;
}

// (The single-expected-value variant was removed 2026-08-27: after amendment 6
// every colour attachment this file validates admits a SET of values, so the
// one-value form had no caller left.)

bool attachmentIsAbsentOrOneOfStrings(
    CVBufferRef buffer, CFStringRef key,
    std::initializer_list<CFStringRef> expected, const char *diagnostic,
    std::string *error) {
  CFTypeRef value = CVBufferCopyAttachment(buffer, key, nullptr);
  if (value == nullptr) {
    return true;
  }
  const bool matches =
      CFGetTypeID(value) == CFStringGetTypeID() &&
      std::any_of(expected.begin(), expected.end(),
                  [value](CFStringRef candidate) {
                    return candidate != nullptr && CFEqual(value, candidate);
                  });
  CFRelease(value);
  if (!matches) {
    assignError(error, diagnostic);
  }
  return matches;
}

bool rejectPresentAttachment(CVBufferRef buffer, CFStringRef key,
                             const char *diagnostic,
                             std::string *error) {
  CFTypeRef value = CVBufferCopyAttachment(buffer, key, nullptr);
  if (value == nullptr) {
    return true;
  }
  CFRelease(value);
  assignError(error, diagnostic);
  return false;
}

// VideoToolbox forwards matrix_coefficients 5 to the decoded surface in the
// unmapped spelling "YCbCrMatrix#5" rather than resolving it. That tag reaches
// the display layer through CMVideoFormatDescriptionCreateForImageBuffer and
// reaches the scenegraph shaders through ycbcrMatrixForPixelBuffer(), and
// neither can act on a string it does not know. H.273 defines 5 and 6 as one
// matrix, so restating it in the 601 spelling is exact -- and it must happen
// BEFORE the SDR validator below, which would otherwise refuse the frame and
// turn a clean fallback into a mid-playback decode failure.
//
// Restating is the narrowest available fix: the alternative is teaching the
// spelling to every presenter and validator separately, which is the drift
// native_video_color.hpp exists to prevent.
void normalizeDecodedColorAttachments(CVPixelBufferRef pixelBuffer) {
  if (pixelBuffer == nullptr) {
    return;
  }
  CFTypeRef matrix = CVBufferCopyAttachment(
      pixelBuffer, kCVImageBufferYCbCrMatrixKey, nullptr);
  if (matrix == nullptr) {
    return;
  }
  if (CFGetTypeID(matrix) == CFStringGetTypeID() &&
      CFEqual(matrix, wam::macos::bt470bgYCbCrMatrixSpelling())) {
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                          kCVAttachmentMode_ShouldPropagate);
  }
  CFRelease(matrix);
}

bool validateDecodedSdrColorAttachments(CVPixelBufferRef pixelBuffer,
                                        std::string *error) {
  if (pixelBuffer == nullptr) {
    assignError(error, "VideoToolbox returned no decoded pixel buffer");
    return false;
  }
  // A stream whose VUI carries no colour description reaches this port with
  // Unknown primaries, which admission deliberately accepts as SDR. The
  // decoder does not see that "unspecified" state: VideoToolbox resolves it
  // with the conventional SD/HD inference and attaches a concrete value, so
  // every untagged standard-definition frame arrives tagged SMPTE_C (525) or
  // EBU_3213 (625) with the matching BT.601 matrix. Those are the SD SDR
  // primaries for exactly the inference the presentation path already
  // implements -- see the BT.601 conversion in qt_gl_video_item.mm -- so
  // rejecting them here would fail every untagged SD clip while accepting the
  // identical untagged HD one. An explicitly tagged BT.601 stream never gets
  // this far: the media source marks that unsupported at admission.
  // AMENDMENT 6. BT.2020 primaries and the PQ/HLG transfers are admitted, and
  // the two HDR volume/light attachments are no longer refused -- they are the
  // payload the presentation path DELIVERS. Measured on this platform
  // (scratchpad/color_probe.mm): VideoToolbox attaches the stream's own
  // primaries/transfer/matrix to every decoded surface, copies
  // MasteringDisplayColorVolume and ContentLightLevelInfo across verbatim, and
  // resolves a matching CGColorSpace ("Rec. ITU-R BT.2100 PQ"/"... HLG"), all
  // of which CMVideoFormatDescriptionCreateForImageBuffer reproduces into the
  // format description native_layer_video_output enqueues with. Refusing them
  // here discarded exactly the information WindowServer tone-maps from.
  //
  // Everything genuinely unrepresentable keeps its named refusal below:
  // gamma, ICC, alternative and log transfer characteristics, ambient viewing
  // environment, content colour volume, and the macOS 15 post-decode classes.
  if (!attachmentIsAbsentOrOneOfStrings(
          pixelBuffer, kCVImageBufferColorPrimariesKey,
          {kCVImageBufferColorPrimaries_ITU_R_709_2,
           kCVImageBufferColorPrimaries_SMPTE_C,
           kCVImageBufferColorPrimaries_EBU_3213,
           kCVImageBufferColorPrimaries_ITU_R_2020},
          "decoded color primaries are not BT.709, BT.601 or BT.2020", error) ||
      !attachmentIsAbsentOrOneOfStrings(
          pixelBuffer, kCVImageBufferTransferFunctionKey,
          {kCVImageBufferTransferFunction_ITU_R_709_2,
           kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
           kCVImageBufferTransferFunction_ITU_R_2100_HLG},
          "decoded transfer function is not BT.709, PQ or HLG", error) ||
      !attachmentIsAbsentOrOneOfStrings(
          pixelBuffer, kCVImageBufferYCbCrMatrixKey,
          {kCVImageBufferYCbCrMatrix_ITU_R_709_2,
           kCVImageBufferYCbCrMatrix_ITU_R_601_4,
           kCVImageBufferYCbCrMatrix_ITU_R_2020},
          "decoded YCbCr matrix is not BT.709, BT.601 or BT.2020", error) ||
      !rejectPresentAttachment(
          pixelBuffer, kCVImageBufferGammaLevelKey,
          "decoded frame carries an unsupported gamma attachment", error) ||
      !rejectPresentAttachment(
          pixelBuffer, kCVImageBufferICCProfileKey,
          "decoded frame carries an unsupported ICC profile", error) ||
      !rejectPresentAttachment(
          pixelBuffer,
          kCMFormatDescriptionExtension_AlternativeTransferCharacteristics,
          "decoded frame carries alternative transfer metadata", error)) {
    return false;
  }

#if defined(__MAC_12_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_12_0
  if (@available(macOS 12.0, *)) {
    if (!rejectPresentAttachment(
            pixelBuffer, kCVImageBufferAmbientViewingEnvironmentKey,
            "decoded frame carries ambient-viewing metadata", error)) {
      return false;
    }
  }
#endif
#if defined(__MAC_14_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_0
  if (@available(macOS 14.0, *)) {
    if (!rejectPresentAttachment(
            pixelBuffer, kCMFormatDescriptionExtension_ContentColorVolume,
            "decoded frame carries HDR content-color metadata", error)) {
      return false;
    }
  }
#endif
#if defined(__MAC_14_2) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_2
  if (@available(macOS 14.2, *)) {
    if (!rejectPresentAttachment(
            pixelBuffer, kCVImageBufferLogTransferFunctionKey,
            "decoded frame carries a log transfer function", error)) {
      return false;
    }
  }
#endif
#if defined(__MAC_15_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_15_0
  if (@available(macOS 15.0, *)) {
    if (!rejectPresentAttachment(
            pixelBuffer, kCVImageBufferSceneIlluminationKey,
            "decoded frame carries scene-illumination metadata", error) ||
        !rejectPresentAttachment(
            pixelBuffer,
            kCVImageBufferPostDecodeProcessingSequenceMetadataKey,
            "decoded frame carries post-decode sequence metadata", error) ||
        !rejectPresentAttachment(
            pixelBuffer, kCVImageBufferPostDecodeProcessingFrameMetadataKey,
            "decoded frame carries post-decode frame metadata", error)) {
      return false;
    }
  }
#endif
  return true;
}

void insertCompletionTombstoneLocked(
    AsyncDecodeState &state,
    AsyncDecodeState::FrameRefConSlot *slot,
    std::uint64_t submissionSequence) {
  const auto insertion = std::lower_bound(
      state.completedDecodes.begin(), state.completedDecodes.end(),
      submissionSequence,
      [](const AsyncDecodeState::CompletedDecode &completion,
         std::uint64_t sequence) {
        return completion.submissionSequence < sequence;
      });
  if (submissionSequence < state.nextCompletionSequence ||
      (insertion != state.completedDecodes.end() &&
       insertion->submissionSequence == submissionSequence)) {
    return;
  }
  // configure() reserves maxInFlightFrames slots. Since every sequence owns
  // one admission credit, this fail-closed tombstone cannot grow the vector
  // beyond that preallocated ceiling.
  state.completedDecodes.insert(
      insertion,
      AsyncDecodeState::CompletedDecode{submissionSequence, std::nullopt,
                                        slot});
  if (slot != nullptr) {
    slot->state = AsyncDecodeState::FrameRefConSlotState::CallbackComplete;
  }
}

void deliverDecodedFrameImpl(const std::shared_ptr<AsyncDecodeState> &state,
                             AsyncDecodeState::FrameRefConSlot *slot,
                             std::uint64_t submissionSequence,
                             FrameTiming timing, OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime presentationTime,
                             CMTime presentationDuration) {
  // Async callbacks are not assumed to arrive in submission or presentation
  // order. Serialize the callback boundary, restore submission order by the
  // captured sequence, then apply the SPS-derived PTS reorder bound.
  std::lock_guard deliveryLock(state->deliveryMutex);
  if (CMTIME_IS_VALID(presentationTime)) {
    timing.presentationTime = presentationTime;
  }
  if (CMTIME_IS_VALID(presentationDuration)) {
    timing.duration = presentationDuration;
  }

  {
    std::lock_guard lock(state->mutex);
    if (slot != nullptr &&
        (slot->state !=
             AsyncDecodeState::FrameRefConSlotState::Submitted ||
         slot->submissionSequence != submissionSequence)) {
      assignAsyncErrorLocked(
          *state, "VideoToolbox invoked an invalid frame-refcon callback");
      return;
    }
    if (state->callbackFailedClosed) {
      ++state->dropped;
      insertCompletionTombstoneLocked(*state, slot, submissionSequence);
      collectCompletedDecodesLocked(*state);
    } else {
      std::optional<FrameLease> decodedFrame;
      if (status != noErr) {
        assignAsyncErrorLocked(
            *state, "VideoToolbox output callback reported failure");
        ++state->dropped;
      } else if ((infoFlags & kVTDecodeInfo_FrameDropped) != 0 ||
                 (imageBuffer == nullptr
#if defined(WAM_NATIVE_VIDEO_TESTING)
                  && !state->permitSyntheticCallbackFrame
#endif
                  )) {
        ++state->dropped;
        if (imageBuffer == nullptr &&
            (infoFlags & kVTDecodeInfo_FrameDropped) == 0) {
          assignAsyncErrorLocked(
              *state,
              "VideoToolbox returned success without a decoded pixel buffer");
        }
      } else if (state->discarding || timing.generation != state->generation) {
        // A flush advances the generation before waiting for callbacks, so an
        // old frame is released here without ever reaching the new timeline.
        ++state->dropped;
      } else {
        auto pixelBuffer = static_cast<CVPixelBufferRef>(imageBuffer);
#if defined(WAM_NATIVE_VIDEO_TESTING)
        if (state->permitSyntheticCallbackFrame && pixelBuffer == nullptr) {
          decodedFrame.emplace(pixelBuffer, timing);
        } else
#endif
        if (!validateDecodedDimensions(
                pixelBuffer, state->expectedCodedDimensions, nullptr)) {
          assignAsyncErrorLocked(
              *state,
              "VideoToolbox decoded dimensions did not match the configured "
              "coded dimensions");
          ++state->dropped;
        } else {
          // Runs before both contract checks: the surface's own tag is what
          // the layer and the shaders read, so it is restated at the port
          // rather than reinterpreted at each reader.
          normalizeDecodedColorAttachments(pixelBuffer);
          bool outputSurfaceValid = false;
#if defined(WAM_NATIVE_VIDEO_TESTING)
          if (state->permitSyntheticOutputSurface) {
            outputSurfaceValid = true;
          } else
#endif
          {
            outputSurfaceValid = validateOutputSurfaceContract(
                pixelBuffer, state->expectedOutputPixelFormat,
                state->outputInterop, nullptr);
          }
          if (!outputSurfaceValid) {
            assignAsyncErrorLocked(
                *state,
                "VideoToolbox decoded surface violated the output contract");
            ++state->dropped;
          } else if (!validateDecodedSdrColorAttachments(pixelBuffer,
                                                         nullptr)) {
            assignAsyncErrorLocked(
                *state,
                "VideoToolbox decoded frame carried unsupported color or HDR "
                "metadata");
            ++state->dropped;
          } else if (!CMTIME_IS_NUMERIC(timing.presentationTime)) {
            assignAsyncErrorLocked(
                *state,
                "VideoToolbox returned a decoded frame without a finite "
                "numeric presentation timestamp");
            ++state->dropped;
          } else {
            const OSType pixelFormat =
                CVPixelBufferGetPixelFormatType(pixelBuffer);
            state->actualOutputPixelFormat = pixelFormat;
            if (state->sink == nullptr) {
              assignAsyncErrorLocked(
                  *state, "decoded frame has no configured output sink");
              ++state->dropped;
            } else {
              // This is the first decoded-frame owner created after
              // generation, surface-layout, color, timestamp, and sink
              // validation. FrameLease acquires the process-wide IOSurface
              // budget before retaining the borrowed callback buffer.
              FrameLease admittedFrame(pixelBuffer, timing);
              if (!admittedFrame) {
                // Budget denial is a normal ordered tombstone. It must retire
                // this sequence's in-flight credit without reaching the sink
                // or poisoning later submissions as a stream-contract
                // failure.
                incrementSaturated(state->dropped);
                incrementSaturated(state->surfaceBudgetRejections);
              } else {
                decodedFrame.emplace(std::move(admittedFrame));
              }
            }
          }
        }
      }

      const auto duplicate = std::lower_bound(
          state->completedDecodes.begin(), state->completedDecodes.end(),
          submissionSequence,
          [](const AsyncDecodeState::CompletedDecode &completion,
             std::uint64_t sequence) {
            return completion.submissionSequence < sequence;
          });
      if (submissionSequence < state->nextCompletionSequence ||
          (duplicate != state->completedDecodes.end() &&
           duplicate->submissionSequence == submissionSequence)) {
        if (decodedFrame) {
          ++state->dropped;
        }
        assignAsyncErrorLocked(
            *state,
            "VideoToolbox invoked a duplicate decoded-frame callback");
      } else {
#if defined(WAM_NATIVE_VIDEO_TESTING)
        maybeFailCallbackAllocationLocked(
            *state, VideoToolboxDecoderTestAllocationPoint::CompletedDecode);
#endif
        state->completedDecodes.insert(
            duplicate, AsyncDecodeState::CompletedDecode{
                           submissionSequence, std::move(decodedFrame), slot});
        if (slot != nullptr) {
          slot->state =
              AsyncDecodeState::FrameRefConSlotState::CallbackComplete;
        }
        collectCompletedDecodesLocked(*state);
      }
    }
  }

}

void failDecodedFrameCallback(
    const std::shared_ptr<AsyncDecodeState> &state,
    AsyncDecodeState::FrameRefConSlot *slot,
    std::uint64_t submissionSequence, std::string_view diagnostic) noexcept {
  try {
    std::lock_guard deliveryLock(state->deliveryMutex);
    {
      std::lock_guard lock(state->mutex);
      // Keep every accepted submission behind the same sequence gate even on
      // allocation failure. Existing completions become no-frame tombstones;
      // a missing current completion is added from pre-reserved capacity.
      for (AsyncDecodeState::CompletedDecode &completion :
           state->completedDecodes) {
        completion.frame.reset();
      }
      state->pendingPresentationFrames.clear();
      state->callbackFailedClosed = true;
      state->discarding = true;
      ++state->dropped;
      assignAsyncErrorLocked(*state, diagnostic);
      insertCompletionTombstoneLocked(*state, slot, submissionSequence);
      collectCompletedDecodesLocked(*state);
    }
  } catch (...) {
    recordAsyncError(state,
                     "VideoToolbox output callback failed closed");
  }
}

void deliverDecodedFrame(const std::shared_ptr<AsyncDecodeState> &state,
                         AsyncDecodeState::FrameRefConSlot *slot,
                         std::uint64_t submissionSequence, FrameTiming timing,
                         OSStatus status, VTDecodeInfoFlags infoFlags,
                         CVImageBufferRef imageBuffer, CMTime presentationTime,
                         CMTime presentationDuration) noexcept {
  try {
    deliverDecodedFrameImpl(state, slot, submissionSequence, timing, status,
                            infoFlags, imageBuffer, presentationTime,
                            presentationDuration);
  } catch (const std::bad_alloc &) {
    failDecodedFrameCallback(
        state, slot, submissionSequence,
        "VideoToolbox output callback exhausted bounded storage");
  } catch (const std::exception &) {
    failDecodedFrameCallback(
        state, slot, submissionSequence,
        "VideoToolbox output callback threw an exception");
  } catch (...) {
    failDecodedFrameCallback(
        state, slot, submissionSequence,
        "VideoToolbox output callback threw an unknown exception");
  }
  // This is deliberately outside both callback-owned mutex scopes and after
  // Ordered collection has published any retired admission credit in the same
  // state transaction as slot/byte retirement. The owner can therefore
  // observe the completed state before deciding what to retry.
  notifyProgress(state);
}

CFStringRef codecConfigurationAtomName(CMVideoCodecType codec) noexcept {
  // VideoToolbox cannot build a VP9 or AV1 decompression session without the
  // codec configuration record: CMVideoFormatDescriptionCreate succeeds but
  // session creation fails with kVTCouldNotFindVideoDecoderErr (-8971). The
  // vpcC/av1C atoms travel through the exact same sample-description-extension
  // dictionary as avcC/hvcC, so naming them here is the only change the
  // format-description path needs.
  // MPEG-4 Part 2 is the same story with a different atom: the format
  // description must carry an 'esds' -- the ISO/IEC 14496-1 ES_Descriptor
  // wrapping the VisualObjectSequence -- or VTDecompressionSessionCreate
  // fails. Measured 2026-08-20: the raw headers in band, or an ES_Descriptor
  // missing the box's four version/flags bytes, both return
  // kVTVideoDecoderBadDataErr (-12909).
  return codec == kCMVideoCodecType_H264       ? CFSTR("avcC")
         : codec == kCMVideoCodecType_HEVC     ? CFSTR("hvcC")
         : codec == kCMVideoCodecType_VP9      ? CFSTR("vpcC")
         : codec == kCMVideoCodecType_AV1      ? CFSTR("av1C")
         : codec == kCMVideoCodecType_MPEG4Video ? CFSTR("esds")
                                                 : nullptr;
}

// True for a codec that has NO out-of-band decoder configuration record at
// all, so that "no atom" is the correct format description rather than a
// missing one.
//
// MPEG-2 is the only such codec this decoder admits. Its sequence header is
// in band, `CMVideoFormatDescriptionCreate` takes a null extensions argument,
// and a session built that way decoded 60 access units 1:1 in
// scratchpad/vt_mpeg2_probe.mm. Every other admitted codec must present its
// atom, and the atom-name lookup above stays the authority on which one.
//
// This predicate exists rather than being folded into the null return above
// because the two "nullptr" cases mean opposite things: an unknown codec has
// no atom NAME and must be refused, while MPEG-2 has no atom and must be
// admitted.
bool codecCarriesNoConfigurationRecord(CMVideoCodecType codec) noexcept {
  return codec == kCMVideoCodecType_MPEG2Video;
}

// True for a codec whose VideoToolbox decoder does NOT natively produce a
// bi-planar 4:2:0 surface, so the output pixel format must be pinned in the
// session's destination attributes even on the display-layer route that
// otherwise leaves the decoder free to pick.
//
// This is a property of the DECODER's native output format and nothing else.
// It was previously expressed as codecCarriesNoConfigurationRecord(), which
// was true of MPEG-2 for an unrelated reason and happened to select the right
// codec while MPEG-2 was the only legacy decoder here. MPEG-4 Part 2 broke
// that coincidence: it carries a configuration record AND decodes to `2vuy`.
//
// Both of Apple's legacy software decoders behave the same way, measured
// 2026-08-20: an unpinned session decodes to `2vuy`
// (kCVPixelFormatType_422YpCbCr8, packed 4:2:2) and a pinned one decodes the
// same bytes to `420v`. Nothing downstream accepts a packed 4:2:2 surface --
// the display layer, the Metal mapper and the OpenGL importer are all
// bi-planar -- so an unpinned session fails the output-surface contract on its
// very first frame ("output pixel format 846624121 did not match the bounded
// native decode contract 875704438"). That is exactly the failure MPEG-4
// Part 2 hit before it was named here.
//
// Pinning costs the same per-frame VTPixelTransferSession the non-display-layer
// contracts already pay. It is affordable for both codecs for the same reason:
// MPEG-2-in-TS is SD, and MPEG-4 Part 2 Simple Profile is an SD-era profile
// whose levels stop at SD resolutions.
bool codecNeedsPinnedOutputPixelFormat(CMVideoCodecType codec) noexcept {
  return codec == kCMVideoCodecType_MPEG2Video ||
         codec == kCMVideoCodecType_MPEG4Video;
}

struct CodecConfigurationAtomMetadata {
  CMVideoCodecType codec{0};
  CFDataRef atom{nullptr}; // Borrowed from the format-description extensions.
  std::size_t byteLength{0};
};

bool inspectCodecConfigurationExtensions(
    CMVideoCodecType codec, CFDictionaryRef extensions,
    CodecConfigurationAtomMetadata &metadata, std::string *error) {
  metadata = {};
  if (codecCarriesNoConfigurationRecord(codec)) {
    // The absence IS the admitted shape. Nothing borrows an atom, nothing
    // compares one, and the equality check below treats two absences as equal.
    metadata.codec = codec;
    metadata.atom = nullptr;
    metadata.byteLength = 0;
    return true;
  }
  const CFStringRef atomName = codecConfigurationAtomName(codec);
  if (atomName == nullptr) {
    assignError(error,
                "direct CoreMedia sample format is not a codec with an "
                "admitted configuration record");
    return false;
  }
  if (extensions == nullptr ||
      CFGetTypeID(extensions) != CFDictionaryGetTypeID()) {
    assignError(error,
                "direct CoreMedia sample format has no extension dictionary");
    return false;
  }
  CFTypeRef atomsValue = static_cast<CFTypeRef>(CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
  if (atomsValue == nullptr ||
      CFGetTypeID(atomsValue) != CFDictionaryGetTypeID()) {
    assignError(error,
                "direct CoreMedia sample format has no configuration atoms");
    return false;
  }
  auto atoms = static_cast<CFDictionaryRef>(atomsValue);
  CFTypeRef atomValue =
      static_cast<CFTypeRef>(CFDictionaryGetValue(atoms, atomName));
  if (atomValue == nullptr || CFGetTypeID(atomValue) != CFDataGetTypeID()) {
    assignError(error,
                "direct CoreMedia sample format has no selected avcC/hvcC "
                "atom");
    return false;
  }
  auto atom = static_cast<CFDataRef>(atomValue);
  const CFIndex length = CFDataGetLength(atom);
  if (length <= 0) {
    assignError(error,
                "direct CoreMedia sample format has an empty avcC/hvcC "
                "atom");
    return false;
  }
  const std::size_t byteLength = static_cast<std::size_t>(length);
  if (!native_video_limits::acceptsVideoCodecConfigurationSize(byteLength)) {
    assignError(error,
                "direct CoreMedia sample format exceeds the 256 KiB codec "
                "configuration bound");
    return false;
  }

  metadata.codec = codec;
  metadata.atom = atom;
  metadata.byteLength = byteLength;
  return true;
}

bool inspectFormatCodecConfiguration(
    CMVideoFormatDescriptionRef format,
    CodecConfigurationAtomMetadata &metadata, std::string *error) {
  metadata = {};
  if (format == nullptr ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) {
    assignError(error,
                "direct CoreMedia sample has no video format description");
    return false;
  }
  const CMVideoCodecType codec = CMFormatDescriptionGetMediaSubType(format);
  return inspectCodecConfigurationExtensions(
      codec, CMFormatDescriptionGetExtensions(format), metadata, error);
}

bool equivalentCodecConfigurationAtoms(
    const CodecConfigurationAtomMetadata &configured,
    const CodecConfigurationAtomMetadata &direct, std::string *error) {
  if (configured.codec != direct.codec ||
      configured.byteLength != direct.byteLength ||
      // Two absences are equal; one absence against one record is not. The
      // null guard is load-bearing: CFEqual on a null operand is undefined,
      // and MPEG-2 reaches here with both sides null.
      (configured.atom == nullptr) != (direct.atom == nullptr) ||
      (configured.atom != nullptr && direct.atom != nullptr &&
       configured.atom != direct.atom &&
       !CFEqual(configured.atom, direct.atom))) {
    assignError(error,
                "direct CoreMedia sample avcC/hvcC does not exactly match "
                "the configured decoder atom");
    return false;
  }
  return true;
}

#if defined(WAM_NATIVE_VIDEO_TESTING)
bool equivalentFormatCodecConfigurations(
    CMVideoFormatDescriptionRef configuredFormat,
    CMVideoFormatDescriptionRef directFormat, std::string *error) {
  CodecConfigurationAtomMetadata configured;
  if (!inspectFormatCodecConfiguration(configuredFormat, configured, error)) {
    return false;
  }
  CodecConfigurationAtomMetadata direct;
  if (!inspectFormatCodecConfiguration(directFormat, direct, error)) {
    return false;
  }
  return equivalentCodecConfigurationAtoms(configured, direct, error);
}
#endif

bool admitsCodecConfigurationMetadata(
    const VideoStreamConfiguration &configuration) noexcept {
  if (codecCarriesNoConfigurationRecord(configuration.codec)) {
    return configuration.codecConfiguration.empty();
  }
  return codecConfigurationAtomName(configuration.codec) != nullptr &&
         native_video_limits::acceptsVideoCodecConfigurationSize(
             configuration.codecConfiguration.size()) &&
         configuration.codecConfiguration.size() <=
             static_cast<std::size_t>(std::numeric_limits<CFIndex>::max());
}

OSStatus createFormatDescription(const VideoStreamConfiguration &configuration,
                                 CMVideoFormatDescriptionRef *descriptionOut) {
  if (descriptionOut == nullptr) {
    return paramErr;
  }
  *descriptionOut = nullptr;

  if (!admitsCodecConfigurationMetadata(configuration)) {
    return paramErr;
  }
  if (codecCarriesNoConfigurationRecord(configuration.codec)) {
    // A null extensions dictionary, not an empty one. Proved in
    // scratchpad/vt_mpeg2_probe.mm.
    const OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, configuration.codec, configuration.codedSize.width,
        configuration.codedSize.height, nullptr, descriptionOut);
    if (status != noErr && *descriptionOut != nullptr) {
      CFRelease(*descriptionOut);
      *descriptionOut = nullptr;
    }
    return status;
  }
  const CFStringRef atomName = codecConfigurationAtomName(configuration.codec);

  CFDataRef atomData = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
  if (!consumeCFAllocationFailure(
          VideoToolboxDecoderTestCFAllocationPoint::CodecAtomData))
#endif
  {
    atomData = CFDataCreate(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8 *>(
            configuration.codecConfiguration.data()),
        static_cast<CFIndex>(configuration.codecConfiguration.size()));
  }
  if (atomData == nullptr) {
    return memFullErr;
  }

  const void *atomKeys[] = {atomName};
  const void *atomValues[] = {atomData};
  CFDictionaryRef atoms = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
  if (!consumeCFAllocationFailure(
          VideoToolboxDecoderTestCFAllocationPoint::CodecAtomsDictionary))
#endif
  {
    atoms = CFDictionaryCreate(
        kCFAllocatorDefault, atomKeys, atomValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  }
  CFDictionaryRef extensions = nullptr;
  if (atoms != nullptr) {
#if defined(WAM_NATIVE_VIDEO_TESTING)
    if (!consumeCFAllocationFailure(
            VideoToolboxDecoderTestCFAllocationPoint::
                FormatExtensionsDictionary))
#endif
    {
      CFMutableDictionaryRef mutableExtensions = CFDictionaryCreateMutable(
          kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
      if (mutableExtensions != nullptr) {
        CFDictionarySetValue(
            mutableExtensions,
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
            atoms);
        // The colour description, when the caller modelled one. A description
        // reconstructed from the codec atom alone leaves the decoded surface
        // untagged, and an untagged PQ surface presents as SDR. See
        // VideoStreamConfiguration::colorPrimaries for the measurement.
        //
        // A stream with no modelled colour writes no key and gets a
        // byte-identical description to the one it got before this existed.
        if (configuration.colorPrimaries != nullptr) {
          CFDictionarySetValue(mutableExtensions,
                               kCMFormatDescriptionExtension_ColorPrimaries,
                               configuration.colorPrimaries);
        }
        if (configuration.transferFunction != nullptr) {
          CFDictionarySetValue(mutableExtensions,
                               kCMFormatDescriptionExtension_TransferFunction,
                               configuration.transferFunction);
        }
        if (configuration.ycbcrMatrix != nullptr) {
          CFDictionarySetValue(mutableExtensions,
                               kCMFormatDescriptionExtension_YCbCrMatrix,
                               configuration.ycbcrMatrix);
        }
      }
      extensions = mutableExtensions;
    }
  }

  OSStatus status = memFullErr;
  if (extensions != nullptr) {
    status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, configuration.codec, configuration.codedSize.width,
        configuration.codedSize.height, extensions, descriptionOut);
  }
  if (status != noErr && *descriptionOut != nullptr) {
    CFRelease(*descriptionOut);
    *descriptionOut = nullptr;
  }
  if (extensions != nullptr) {
    CFRelease(extensions);
  }
  if (atoms != nullptr) {
    CFRelease(atoms);
  }
  CFRelease(atomData);
  return status;
}

// The stream's OWN coded depth, read from its configuration record. Split out
// from requestedPixelFormat() 2026-08-27 because the two questions came apart:
// the requested OUTPUT depth can now exceed the coded depth for an HDR stream,
// and only the difference between them justifies pinning the format on the
// display-layer interop.
bool codedDepthIsTenBit(
    const VideoStreamConfiguration &configuration) noexcept {
  // hvcC stores bit_depth_luma_minus8 in the low three bits of byte 17.
  // The common H.264 High 10 profile uses profile_idc 110. Both map directly
  // to the presenter's supported 10-bit bi-planar GPU import path.
  const auto *bytes = reinterpret_cast<const std::uint8_t *>(
      configuration.codecConfiguration.data());
  bool tenBit = false;
  if (configuration.codec == kCMVideoCodecType_HEVC &&
      configuration.codecConfiguration.size() > 17) {
    tenBit = (bytes[17] & 0x07U) > 0;
  } else if (configuration.codec == kCMVideoCodecType_H264 &&
             configuration.codecConfiguration.size() > 1) {
    tenBit = bytes[1] == 110;
  } else if (configuration.codec == kCMVideoCodecType_VP9 &&
             configuration.codecConfiguration.size() >= 12 &&
             bytes[0] == 1) {
    // vpcC byte 6: bitDepth(4) | chromaSubsampling(3) | videoFullRangeFlag(1).
    // VP9 Profile 2 carries 10-bit 4:2:0 and must request P010. Getting this
    // wrong is silent: VideoToolbox happily creates an NV12 session for 10-bit
    // VP9 and downconverts, so the delivered format still matches the request
    // and validateOutputSurfaceContract cannot catch it. The record must
    // therefore be well-formed here, and it is: configure() already rejected
    // any vpcC shorter than 12 bytes or with a version other than 1 through
    // deriveCodecReorderDepth, which runs before this call.
    tenBit = (bytes[6] >> 4U) >= 10U;
  } else if (configuration.codec == kCMVideoCodecType_AV1 &&
             configuration.codecConfiguration.size() >= 4 &&
             (bytes[0] & 0x80U) != 0U && (bytes[0] & 0x7fU) == 1U) {
    // av1C byte 2: seq_tier_0(1) | high_bitdepth(1) | twelve_bit(1) |
    //              monochrome(1) | subsampling_x(1) | subsampling_y(1) |
    //              chroma_sample_position(2). AV1 Main 10 sets high_bitdepth
    //              with twelve_bit clear. Same fail-closed reasoning as VP9:
    //              a malformed av1C never reaches here because configure()
    //              rejected it first.
    tenBit = ((bytes[2] >> 6U) & 0x01U) != 0U;
  }
  // MPEG-2 and MPEG-4 Part 2 are deliberately absent from the chain above:
  // both are 8-bit by profile (MPEG-4 Part 2 Simple Profile defines 8-bit
  // 4:2:0 and nothing else), so the 8-bit answer below is a stated fact rather
  // than a default they fell through to. They are also the two codecs whose
  // decoders will not produce this format unless it is requested -- see
  // codecNeedsPinnedOutputPixelFormat().
  return tenBit;
}

// The output surface this decode should produce.
//
// It is the coded depth, EXCEPT that a PQ or HLG stream always asks for a
// 10-bit surface. That is a presentation requirement, not a decode one:
// measured 2026-08-27 on this platform, AVSampleBufferDisplayLayer presents an
// 8-bit PQ-tagged surface as if it were SDR even though the surface carries
// correct primaries, a correct transfer and a resolved "Rec. ITU-R BT.2100 PQ"
// CGColorSpace, while the identical picture on a 10-bit surface is presented
// correctly. Screen-captured against QuickTime Player on the same 8-bit PQ
// H.264 file, the 8-bit surface was off by 98/255 on the colour-bar means
// (ramp histogram L1 0.65) and the 10-bit surface by 4.6/255 (L1 0.12).
//
// VideoToolbox honours the widened request on an 8-bit stream -- measured,
// `x420` delivered from 8-bit PQ H.264 -- so nothing here is speculative.
OSType
requestedPixelFormat(const VideoStreamConfiguration &configuration) noexcept {
  return (codedDepthIsTenBit(configuration) ||
          configuration.highDynamicRangeTransfer)
             ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
             : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

OSStatus
createCompressedSampleBuffer(CMVideoFormatDescriptionRef formatDescription,
                             const CompressedVideoPacket &packet,
                             CMSampleBufferRef *sampleOut) {
  if (sampleOut == nullptr || formatDescription == nullptr ||
      packet.bytes.empty()) {
    return paramErr;
  }
  *sampleOut = nullptr;

  CMBlockBufferRef block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, packet.bytes.size(), kCFAllocatorDefault,
      nullptr, 0, packet.bytes.size(), 0, &block);
  if (status != noErr || block == nullptr) {
    return status == noErr ? memFullErr : status;
  }
  status = CMBlockBufferReplaceDataBytes(packet.bytes.data(), block, 0,
                                         packet.bytes.size());
  if (status != noErr) {
    CFRelease(block);
    return status;
  }

  const CMSampleTimingInfo timing{packet.duration, packet.presentationTime,
                                  packet.decodeTime};
  const std::size_t sampleSize = packet.bytes.size();
  status =
      CMSampleBufferCreateReady(kCFAllocatorDefault, block, formatDescription,
                                1, 1, &timing, 1, &sampleSize, sampleOut);
  CFRelease(block);
  if (status != noErr || *sampleOut == nullptr) {
    return status == noErr ? memFullErr : status;
  }

  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(*sampleOut, true);
  if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
    auto *attachment = static_cast<CFMutableDictionaryRef>(
        const_cast<void *>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync,
                         packet.keyFrame ? kCFBooleanFalse : kCFBooleanTrue);
    if (packet.keyFrame) {
      CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers,
                           kCFBooleanFalse);
    }
  }
  return noErr;
}

enum class CompressedSubmissionStorage : std::uint8_t {
  DirectSampleBuffer,
  CopiedSpan,
};

struct DirectCompressedSampleMetadata {
  CMVideoFormatDescriptionRef formatDescription{nullptr};
  CFDataRef codecConfigurationAtom{nullptr};
  CMVideoCodecType codec{0};
  CMTime presentationTime{kCMTimeInvalid};
  CMTime decodeTime{kCMTimeInvalid};
  CMTime duration{kCMTimeInvalid};
  std::size_t dataLength{0};
  std::size_t configurationLength{0};
  bool keyFrame{false};
};

bool inspectDirectCompressedSample(
    CMSampleBufferRef sample, DirectCompressedSampleMetadata &metadata,
    std::string *error) {
  if (sample == nullptr) {
    assignError(error, "compressed CoreMedia sample buffer is null");
    return false;
  }
  if (!CMSampleBufferIsValid(sample)) {
    assignError(error, "compressed CoreMedia sample buffer is invalid");
    return false;
  }
  if (!CMSampleBufferDataIsReady(sample)) {
    assignError(error, "compressed CoreMedia sample data is not ready");
    return false;
  }
  if (CMSampleBufferGetNumSamples(sample) != 1) {
    assignError(error,
                "compressed CoreMedia buffer must contain exactly one "
                "sample");
    return false;
  }

  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  if (block == nullptr) {
    assignError(error, "compressed CoreMedia sample has no block buffer");
    return false;
  }
  const std::size_t dataLength = CMBlockBufferGetDataLength(block);
  const std::size_t sampleLength = CMSampleBufferGetSampleSize(sample, 0);
  if (dataLength == 0 || sampleLength == 0 || sampleLength != dataLength) {
    assignError(error,
                "compressed CoreMedia sample must occupy its complete, "
                "nonempty block buffer");
    return false;
  }
  if (!native_video_limits::acceptsCompressedVideoAccessUnitSize(dataLength)) {
    assignError(error,
                "compressed CoreMedia sample exceeds the 8 MiB decoder "
                "memory bound");
    return false;
  }

  auto formatDescription = static_cast<CMVideoFormatDescriptionRef>(
      CMSampleBufferGetFormatDescription(sample));
  CodecConfigurationAtomMetadata configuration;
  if (!inspectFormatCodecConfiguration(formatDescription, configuration,
                                       error)) {
    return false;
  }

  bool keyFrame = true;
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
    if (CFArrayGetCount(attachments) != 1) {
      assignError(error,
                  "compressed CoreMedia sample has inconsistent attachment "
                  "count");
      return false;
    }
    CFTypeRef first = static_cast<CFTypeRef>(
        CFArrayGetValueAtIndex(attachments, 0));
    if (first == nullptr || CFGetTypeID(first) != CFDictionaryGetTypeID()) {
      assignError(error,
                  "compressed CoreMedia sample has malformed attachments");
      return false;
    }
    auto attachment = static_cast<CFDictionaryRef>(first);
    CFTypeRef notSync = static_cast<CFTypeRef>(CFDictionaryGetValue(
        attachment, kCMSampleAttachmentKey_NotSync));
    if (notSync != nullptr) {
      if (CFGetTypeID(notSync) != CFBooleanGetTypeID()) {
        assignError(error,
                    "compressed CoreMedia sample has a malformed sync "
                    "attachment");
        return false;
      }
      keyFrame = !CFBooleanGetValue(static_cast<CFBooleanRef>(notSync));
    }
  }

  metadata.formatDescription = formatDescription;
  metadata.codecConfigurationAtom = configuration.atom;
  metadata.codec = configuration.codec;
  metadata.presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
  metadata.decodeTime = CMSampleBufferGetDecodeTimeStamp(sample);
  metadata.duration = CMSampleBufferGetDuration(sample);
  metadata.dataLength = dataLength;
  metadata.configurationLength = configuration.byteLength;
  metadata.keyFrame = keyFrame;
  return true;
}

} // namespace

struct VideoToolboxDecoder::Impl {
  explicit Impl(VideoToolboxDecoderOptions decoderOptions)
      : options(decoderOptions),
        async(std::make_shared<AsyncDecodeState>(
            decoderOptions.progressHandler,
            decoderOptions.maxInFlightFrames)) {}

  VideoToolboxDecoderOptions options;
  mutable std::mutex operationMutex;
  std::shared_ptr<AsyncDecodeState> async;
  CMVideoFormatDescriptionRef formatDescription{nullptr};
  VTDecompressionSessionRef session{nullptr};
  bool configured{false};
  bool ended{false};
  bool endOfStreamCallbacksFinalized{false};
  bool endOfStreamSinkNotified{false};
  bool endOfStreamFailed{false};
  std::string endOfStreamError;
  bool awaitingKeyFrame{true};
  bool usingHardware{false};
  bool preferHardware{true};
  bool requireHardware{false};
  OSType outputPixelFormat{0};
  // True when outputPixelFormat was widened to 10 bits because the stream
  // carries a PQ or HLG transfer. It is tracked separately from the format
  // itself because it is the reason the format must be PINNED on the display
  // -layer interop, which otherwise deliberately leaves it unpinned -- see
  // createSessionLocked().
  bool hdrOutputSurfaceRequired{false};
  std::size_t codecReorderFrames{0};
  std::uint64_t retirementRetiredGeneration{0};
  std::uint64_t retirementInvalidationGeneration{0};
  bool retirementStarted{false};
  bool retirementDone{false};
#if defined(WAM_NATIVE_VIDEO_TESTING)
  std::size_t testReservedInFlight{0};
#endif

  ~Impl() {
    waitAndInvalidateSessionLocked();
    if (formatDescription != nullptr) {
      CFRelease(formatDescription);
    }
  }

  static void decompressionOutputCallback(
      void *decompressionOutputRefCon, void *sourceFrameRefCon,
      OSStatus status, VTDecodeInfoFlags infoFlags,
      CVImageBufferRef imageBuffer, CMTime presentationTime,
      CMTime presentationDuration) noexcept {
    auto *self = static_cast<Impl *>(decompressionOutputRefCon);
    auto *slot =
        static_cast<AsyncDecodeState::FrameRefConSlot *>(sourceFrameRefCon);
    if (self == nullptr || slot == nullptr) {
      return;
    }

    try {
      // Impl and the stable slot pool remain alive through Apple's documented
      // WaitForAsynchronousFrames completion barrier. Copy timing/sequence
      // only after publishing active entry under the same mutex used by slot
      // arming and our stricter post-notification callback-tail barrier.
      AsyncDecodeState &state = *self->async;
      std::uint64_t sequence = 0;
      FrameTiming timing;
      {
        std::lock_guard stateLock(state.mutex);
        ++state.activeCallbacks;
        sequence = slot->submissionSequence;
        timing = slot->timing;
      }

      deliverDecodedFrame(self->async, slot, sequence, timing, status,
                          infoFlags, imageBuffer, presentationTime,
                          presentationDuration);
      {
        std::lock_guard stateLock(state.mutex);
        if (state.activeCallbacks != 0) {
          --state.activeCallbacks;
        }
        state.completion.notify_all();
      }
    } catch (...) {
      // No C++ exception may cross VideoToolbox's C callback boundary. The
      // callback delivery path itself is fail-closed and allocation-free;
      // this final guard covers pathological mutex/shared-owner failures.
    }
  }

  bool createSessionLocked(std::string *error) {
    if (session != nullptr) {
      return true;
    }
    if (formatDescription == nullptr) {
      assignError(error, "decoder has no video format description");
      return false;
    }

    CFMutableDictionaryRef decoderSpecification = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
    if (!consumeCFAllocationFailure(
            VideoToolboxDecoderTestCFAllocationPoint::
                DecoderSpecificationDictionary))
#endif
    {
      decoderSpecification = CFDictionaryCreateMutable(
          kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
    }
    if (decoderSpecification == nullptr) {
      assignError(error,
                  "could not allocate the VideoToolbox decoder "
                  "specification");
      return false;
    }
    if (preferHardware || requireHardware) {
      CFDictionarySetValue(
          decoderSpecification,
          kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,
          kCFBooleanTrue);
    }
    if (requireHardware) {
      CFDictionarySetValue(
          decoderSpecification,
          kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder,
          kCFBooleanTrue);
    }

    CFDictionaryRef emptyIOSurfaceProperties = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
    if (!consumeCFAllocationFailure(
            VideoToolboxDecoderTestCFAllocationPoint::
                IOSurfacePropertiesDictionary))
#endif
    {
      emptyIOSurfaceProperties = CFDictionaryCreate(
          kCFAllocatorDefault, nullptr, nullptr, 0,
          &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
    }
    if (emptyIOSurfaceProperties == nullptr) {
      CFRelease(decoderSpecification);
      assignError(error,
                  "could not allocate the IOSurface output properties");
      return false;
    }

    CFMutableDictionaryRef imageAttributes = nullptr;
#if defined(WAM_NATIVE_VIDEO_TESTING)
    if (!consumeCFAllocationFailure(
            VideoToolboxDecoderTestCFAllocationPoint::
                ImageAttributesDictionary))
#endif
    {
      imageAttributes = CFDictionaryCreateMutable(
          kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
    }
    if (imageAttributes == nullptr) {
      CFRelease(emptyIOSurfaceProperties);
      CFRelease(decoderSpecification);
      assignError(error,
                  "could not allocate the decoded-image attributes");
      return false;
    }
    CFDictionarySetValue(imageAttributes, kCVPixelBufferIOSurfacePropertiesKey,
                         emptyIOSurfaceProperties);
    CFDictionarySetValue(imageAttributes, kCVPixelBufferMetalCompatibilityKey,
                         kCFBooleanTrue);
    if (options.outputInterop == VideoToolboxOutputInterop::OpenGL) {
      CFDictionarySetValue(
          imageAttributes,
          kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey,
          kCFBooleanTrue);
    }
    // Pinning the output format is what forces the per-frame
    // VTPixelTransferSession: the decoder's native surface is AGX
    // lossless-compressed, and asking for the uncompressed fourcc makes
    // VideoToolbox decompress every frame through IOSurfaceAccelerator inside
    // VTDecoderXPCService. A display-layer presenter never samples the surface,
    // so it leaves the format unpinned and takes whatever the decoder produced.
    // The pinned contracts keep the pin: measured on this box, an unpinned
    // session that also carries OpenGL texture compatibility returns BGRA,
    // which would be a far worse conversion than the one being removed.
    //
    // Apple's legacy software decoders must pin REGARDLESS of the interop,
    // because their native output is packed 4:2:2 and nothing downstream
    // accepts it. See codecNeedsPinnedOutputPixelFormat() for the measurement
    // and for why that predicate is not the same question as "does this codec
    // carry a configuration record", which is what this condition used to ask.
    const CMVideoCodecType sessionCodec =
        formatDescription != nullptr
            ? CMFormatDescriptionGetMediaSubType(formatDescription)
            : 0;
    // An HDR stream pins too, on every interop. The display layer normally
    // takes whatever the decoder produced because it never samples the
    // surface -- but for a PQ/HLG stream the surface's DEPTH is exactly what
    // decides whether the system presents it through the HDR path at all
    // (measured 2026-08-27; see VideoStreamConfiguration::
    // highDynamicRangeTransfer). An unpinned session hands back the coded
    // depth, which for an 8-bit PQ stream is an 8-bit surface presented as
    // SDR, and the request in outputPixelFormat then disagrees with what
    // arrives and fails the output-surface contract instead. Pinning makes
    // the 10-bit request real; VideoToolbox honours it on an 8-bit stream
    // (measured: `x420` delivered from 8-bit PQ H.264).
    const bool pinOutputPixelFormat =
        options.outputInterop != VideoToolboxOutputInterop::DisplayLayer ||
        codecNeedsPinnedOutputPixelFormat(sessionCodec) ||
        hdrOutputSurfaceRequired;
    CFNumberRef pixelFormatNumber = nullptr;
    if (pinOutputPixelFormat) {
      const std::int32_t pixelFormatValue =
          static_cast<std::int32_t>(outputPixelFormat);
#if defined(WAM_NATIVE_VIDEO_TESTING)
      if (!consumeCFAllocationFailure(
              VideoToolboxDecoderTestCFAllocationPoint::PixelFormatNumber))
#endif
      {
        pixelFormatNumber = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormatValue);
      }
      if (pixelFormatNumber == nullptr) {
        CFRelease(imageAttributes);
        CFRelease(emptyIOSurfaceProperties);
        CFRelease(decoderSpecification);
        assignError(error,
                    "could not allocate the output pixel-format request");
        return false;
      }
      CFDictionarySetValue(imageAttributes, kCVPixelBufferPixelFormatTypeKey,
                           pixelFormatNumber);
    }

    const VTDecompressionOutputCallbackRecord callbackRecord{
        &Impl::decompressionOutputCallback, this};
    const OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault, formatDescription, decoderSpecification,
        imageAttributes, &callbackRecord, &session);
    if (pixelFormatNumber != nullptr) {
      CFRelease(pixelFormatNumber);
    }
    CFRelease(imageAttributes);
    CFRelease(emptyIOSurfaceProperties);
    CFRelease(decoderSpecification);
    if (status != noErr || session == nullptr) {
      if (session != nullptr) {
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
      }
      session = nullptr;
      assignError(error, statusError("VTDecompressionSessionCreate", status));
      return false;
    }

    CFTypeRef hardwareProperty = nullptr;
    const OSStatus propertyStatus = VTSessionCopyProperty(
        session,
        kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        kCFAllocatorDefault, &hardwareProperty);
    usingHardware =
        propertyStatus == noErr && hardwareProperty != nullptr &&
        CFGetTypeID(hardwareProperty) == CFBooleanGetTypeID() &&
        CFBooleanGetValue(static_cast<CFBooleanRef>(hardwareProperty));
    if (hardwareProperty != nullptr) {
      CFRelease(hardwareProperty);
    }
    if (requireHardware && !usingHardware) {
      VTDecompressionSessionInvalidate(session);
      CFRelease(session);
      session = nullptr;
      assignError(error,
                  "VideoToolbox did not create a required hardware decoder");
      return false;
    }
    return true;
  }

  // The configured description is reconstructed from the codec configuration
  // atom alone. VideoToolbox admits that reconstruction for H.264, but its
  // HEVC acceptance test compares the complete extension dictionary, which no
  // reconstruction carries. A directly submitted sample brings the container's
  // own description, so once it has proven the same configuration atom, adopt
  // it as the description the session is created from. An already created
  // session is never rebuilt underneath its in-flight frames.
  bool adoptDirectFormatLocked(const DirectCompressedSampleMetadata &metadata,
                               std::string *error) {
    if (metadata.formatDescription == nullptr ||
        metadata.formatDescription == formatDescription ||
        (session != nullptr &&
         VTDecompressionSessionCanAcceptFormatDescription(
             session, metadata.formatDescription))) {
      return true;
    }
    CodecConfigurationAtomMetadata configuredAtom;
    if (!inspectFormatCodecConfiguration(formatDescription, configuredAtom,
                                          error)) {
      return false;
    }
    const CodecConfigurationAtomMetadata direct{
        metadata.codec, metadata.codecConfigurationAtom,
        metadata.configurationLength};
    if (!equivalentCodecConfigurationAtoms(configuredAtom, direct, error)) {
      return false;
    }
    // Only a quiescent decoder may exchange its description. Anything already
    // decoding keeps the existing session, and acceptsDirectFormatLocked()
    // still fails that stream closed rather than retiring live frames here.
    {
      std::lock_guard stateLock(async->mutex);
      if (async->inFlight != 0 || async->activeCallbacks != 0 ||
          !async->pendingPresentationFrames.empty()) {
        return true;
      }
    }
    waitAndInvalidateSessionLocked();
    CFRetain(metadata.formatDescription);
    CFRelease(formatDescription);
    formatDescription = metadata.formatDescription;
    return true;
  }

  bool acceptsDirectFormatLocked(const DirectCompressedSampleMetadata &metadata,
                                 std::string *error) {
    CodecConfigurationAtomMetadata configuredAtom;
    if (!inspectFormatCodecConfiguration(formatDescription, configuredAtom,
                                          error)) {
      return false;
    }
    const CodecConfigurationAtomMetadata direct{
        metadata.codec, metadata.codecConfigurationAtom,
        metadata.configurationLength};
    if (!equivalentCodecConfigurationAtoms(configuredAtom, direct, error)) {
      return false;
    }
    if (!VTDecompressionSessionCanAcceptFormatDescription(
            session, metadata.formatDescription)) {
      assignError(error,
                  "configured VideoToolbox session cannot accept the "
                  "compressed CoreMedia sample format");
      return false;
    }
    return true;
  }

  AsyncDecodeState::FrameRefConSlot *reserveDecodeCapacityLocked() {
    std::lock_guard stateLock(async->mutex);
    const bool retainedSaturated =
        async->pendingPresentationFrames.size() >= async->maxRetainedFrames ||
        async->inFlight >=
            async->maxRetainedFrames - async->pendingPresentationFrames.size();
    if (async->inFlight >= options.maxInFlightFrames || retainedSaturated) {
      if (async->backpressuredSubmissions !=
          std::numeric_limits<std::uint64_t>::max()) {
        ++async->backpressuredSubmissions;
      }
      return nullptr;
    }
    const auto available = std::find_if(
        async->frameRefConSlots.begin(), async->frameRefConSlots.end(),
        [](const AsyncDecodeState::FrameRefConSlot &slot) {
          return slot.state ==
                 AsyncDecodeState::FrameRefConSlotState::Available;
        });
    if (available == async->frameRefConSlots.end()) {
      assignAsyncErrorLocked(
          *async, "VideoToolbox frame-refcon capacity is inconsistent");
      return nullptr;
    }
    available->state = AsyncDecodeState::FrameRefConSlotState::Reserved;
    ++async->inFlight;
    return &*available;
  }

  bool armFrameRefConSlotLocked(
      AsyncDecodeState::FrameRefConSlot *slot, FrameTiming timing,
      CompressedSubmissionStorage storage, std::size_t compressedBytes,
      std::uint64_t *submissionSequence, std::string *error) {
    if (slot == nullptr || submissionSequence == nullptr) {
      assignError(error, "VideoToolbox submission has no frame-refcon slot");
      return false;
    }
    std::lock_guard stateLock(async->mutex);
    if (slot->state != AsyncDecodeState::FrameRefConSlotState::Reserved) {
      assignError(error, "VideoToolbox frame-refcon slot was not reserved");
      return false;
    }
    *submissionSequence = async->nextSubmissionSequence++;
    slot->submissionSequence = *submissionSequence;
    slot->timing = timing;
    slot->compressedBytes = static_cast<std::uint64_t>(compressedBytes);
    slot->directCompressedStorage =
        storage == CompressedSubmissionStorage::DirectSampleBuffer;
    if (slot->directCompressedStorage) {
      async->currentDirectCompressedBytes = saturatedAdd(
          async->currentDirectCompressedBytes, slot->compressedBytes);
      updatePeak(async->peakDirectCompressedBytes,
                 async->currentDirectCompressedBytes);
    } else {
      async->currentCopiedCompressedBytes = saturatedAdd(
          async->currentCopiedCompressedBytes, slot->compressedBytes);
      updatePeak(async->peakCopiedCompressedBytes,
                 async->currentCopiedCompressedBytes);
    }
    async->currentCompressedBytes = saturatedAdd(
        async->currentCompressedBytes, slot->compressedBytes);
    updatePeak(async->peakCompressedBytes, async->currentCompressedBytes);
    slot->state = AsyncDecodeState::FrameRefConSlotState::Submitted;
    return true;
  }

  VideoDecodeSubmitResult submitPreparedSampleLocked(
      CMSampleBufferRef sample, AsyncDecodeState::FrameRefConSlot *slot,
      FrameTiming timing,
      CompressedSubmissionStorage storage, std::size_t compressedBytes,
      std::string *error) {
    std::uint64_t submissionSequence = 0;
    if (!armFrameRefConSlotLocked(slot, timing, storage, compressedBytes,
                                  &submissionSequence, error)) {
      return VideoDecodeSubmitResult::Rejected;
    }
    VTDecodeInfoFlags infoFlags = 0;
#if defined(WAM_NATIVE_VIDEO_TESTING)
    const VTDecodeFrameFlags decodeFlags = finiteAdmissionDecodeFlags(
        options.enableAsynchronousDecompression);
#else
    constexpr VTDecodeFrameFlags decodeFlags = kProductionDecodeFrameFlags;
#endif
    const OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(
        session, sample, decodeFlags, slot, &infoFlags);
    if (decodeStatus != noErr) {
      // Retire the assigned sequence through the same ordering gate. Otherwise
      // a recoverable caller could leave every later callback waiting behind
      // a sequence that VideoToolbox never accepted.
      deliverDecodedFrame(async, slot, submissionSequence, timing,
                          decodeStatus, 0, nullptr, kCMTimeInvalid,
                          kCMTimeInvalid);
      assignError(
          error,
          statusError("VTDecompressionSessionDecodeFrame", decodeStatus));
      return VideoDecodeSubmitResult::Rejected;
    }
    {
      std::lock_guard stateLock(async->mutex);
      if (async->submitted != std::numeric_limits<std::uint64_t>::max()) {
        ++async->submitted;
      }
      if (storage == CompressedSubmissionStorage::DirectSampleBuffer) {
        if (async->directSampleBufferSubmissions !=
            std::numeric_limits<std::uint64_t>::max()) {
          ++async->directSampleBufferSubmissions;
        }
        const std::uint64_t directBytes =
            static_cast<std::uint64_t>(compressedBytes);
        async->directSampleBufferBytes =
            directBytes > std::numeric_limits<std::uint64_t>::max() -
                              async->directSampleBufferBytes
                ? std::numeric_limits<std::uint64_t>::max()
                : async->directSampleBufferBytes + directBytes;
      } else {
        if (async->copiedSpanSubmissions !=
            std::numeric_limits<std::uint64_t>::max()) {
          ++async->copiedSpanSubmissions;
        }
        const std::uint64_t copied =
            static_cast<std::uint64_t>(compressedBytes);
        async->copiedSpanBytes =
            copied > std::numeric_limits<std::uint64_t>::max() -
                         async->copiedSpanBytes
                ? std::numeric_limits<std::uint64_t>::max()
                : async->copiedSpanBytes + copied;
      }
    }
    awaitingKeyFrame = false;
    return VideoDecodeSubmitResult::Accepted;
  }

  void waitAndInvalidateSessionLocked() noexcept {
    if (session != nullptr) {
      VTDecompressionSessionWaitForAsynchronousFrames(session);
      VTDecompressionSessionInvalidate(session);
      CFRelease(session);
      session = nullptr;
      usingHardware = false;
    }

    std::unique_lock lock(async->mutex);
    async->completion.wait(lock, [this] {
      return async->inFlight == 0 && async->activeCallbacks == 0;
    });
  }

  std::optional<std::string> takeAsyncErrorLocked() {
    std::lock_guard lock(async->mutex);
    if (!async->lastError.present()) {
      return std::nullopt;
    }
    std::optional<std::string> result(std::in_place,
                                      async->lastError.bytes.data(),
                                      async->lastError.size);
    async->lastError.reset();
    return result;
  }

  void resetEndOfStreamLocked() noexcept {
    ended = false;
    endOfStreamCallbacksFinalized = false;
    endOfStreamSinkNotified = false;
    endOfStreamFailed = false;
    endOfStreamError.clear();
  }

  VideoDecodeDrainProgress failEndOfStreamLocked(
      std::string message, std::string *error) {
    endOfStreamFailed = true;
    if (endOfStreamError.empty()) {
      endOfStreamError = std::move(message);
    }
    assignError(error, endOfStreamError);
    return VideoDecodeDrainProgress::Failed;
  }

  VideoDecodeDrainProgress currentEndOfStreamProgressLocked(
      std::uint64_t generation, std::string *error) {
    std::size_t inFlight = 0;
    std::uint64_t activeGeneration = 0;
    {
      std::lock_guard stateLock(async->mutex);
      activeGeneration = async->generation;
      inFlight = async->inFlight;
    }
    if (generation != activeGeneration) {
      assignError(error, "end-of-stream operation belongs to a stale "
                         "generation");
      return VideoDecodeDrainProgress::StaleGeneration;
    }
    if (endOfStreamFailed) {
      assignError(error, endOfStreamError);
      return VideoDecodeDrainProgress::Failed;
    }
    if (endOfStreamSinkNotified) {
      return VideoDecodeDrainProgress::Done;
    }
    return inFlight == 0 ? VideoDecodeDrainProgress::Progress
                         : VideoDecodeDrainProgress::Quiescing;
  }

  VideoDecodeDrainProgress beginEndOfStreamLocked(
      std::uint64_t generation, std::string *error) {
    if (!configured) {
      assignError(error, "VideoToolbox decoder is not configured");
      return VideoDecodeDrainProgress::Failed;
    }

    bool newlyBegun = false;
    {
      // This lock pair forms the EOS cut with an already-running callback.
      // Callbacks only restore ordering and retain frames; all sink calls are
      // confined to the owner-driven drain methods.
      std::lock_guard deliveryLock(async->deliveryMutex);
      std::lock_guard stateLock(async->mutex);
      if (generation != async->generation) {
        assignError(error, "end-of-stream operation belongs to a stale "
                           "generation");
        return VideoDecodeDrainProgress::StaleGeneration;
      }
      if (ended) {
        // The exact operation is idempotent. Its current result is sampled
        // below without repeating FinishDelayedFrames.
      } else {
        ended = true;
        async->endOfStreamBegun = true;
        newlyBegun = true;
      }
    }

    if (!newlyBegun) {
      return currentEndOfStreamProgressLocked(generation, error);
    }

    const OSStatus finishStatus =
        session == nullptr
            ? noErr
            : VTDecompressionSessionFinishDelayedFrames(session);
    if (finishStatus != noErr) {
      const VideoDecodeDrainProgress failed = failEndOfStreamLocked(
          statusError("VTDecompressionSessionFinishDelayedFrames",
                      finishStatus),
          error);
      notifyProgress(async);
      return failed;
    }

    // FinishDelayedFrames may synchronously run callbacks. Its successful
    // transition is owner-visible even when asynchronous callbacks remain.
    notifyProgress(async);
    if (auto asyncError = takeAsyncErrorLocked()) {
      return failEndOfStreamLocked(std::move(*asyncError), error);
    }
    return currentEndOfStreamProgressLocked(generation, error);
  }

  VideoDecodeDrainProgress drainPresentationLocked(
      std::uint64_t generation, bool requireEndOfStream,
      std::string *error) {
    if (!configured) {
      assignError(error, "VideoToolbox decoder is not configured");
      return VideoDecodeDrainProgress::Failed;
    }
    {
      std::lock_guard stateLock(async->mutex);
      if (generation != async->generation) {
        assignError(error, "presentation drain belongs to a stale generation");
        return VideoDecodeDrainProgress::StaleGeneration;
      }
    }
    if (requireEndOfStream && !ended) {
      assignError(error, "end-of-stream operation has not begun");
      return VideoDecodeDrainProgress::Failed;
    }
    if (endOfStreamFailed) {
      assignError(error, endOfStreamError);
      return VideoDecodeDrainProgress::Failed;
    }

    const VideoDecodeDrainProgress current = ended
        ? currentEndOfStreamProgressLocked(generation, error)
        : VideoDecodeDrainProgress::Progress;
    if (current == VideoDecodeDrainProgress::StaleGeneration ||
        current == VideoDecodeDrainProgress::Failed ||
        current == VideoDecodeDrainProgress::Done) {
      return current;
    }
    if (auto asyncError = takeAsyncErrorLocked()) {
      return failEndOfStreamLocked(std::move(*asyncError), error);
    }

    if (ended && !endOfStreamCallbacksFinalized) {
      if (current == VideoDecodeDrainProgress::Quiescing) {
        return current;
      }
      const OSStatus waitStatus =
          session == nullptr
              ? noErr
              : VTDecompressionSessionWaitForAsynchronousFrames(session);
      if (waitStatus != noErr) {
        return failEndOfStreamLocked(
            statusError("VTDecompressionSessionWaitForAsynchronousFrames",
                        waitStatus),
            error);
      }
      endOfStreamCallbacksFinalized = true;
      if (auto asyncError = takeAsyncErrorLocked()) {
        return failEndOfStreamLocked(std::move(*asyncError), error);
      }
    }

    // Asynchronous decompression is pipelined: VideoToolbox may hold every
    // outstanding submission until further input arrives. Playback never
    // notices, because input never stops before end of stream. A bounded
    // accurate-seek preroll does stop: its last access units before the
    // presentation floor are submitted, admission then closes on them, and the
    // ordered reorder floor still needs one more decoded frame that only those
    // held submissions can supply. Nothing outside this decoder can break that
    // circle, so force the pipeline with the same completion barrier end of
    // stream already uses - and only there, never while admission is still
    // open and the owner can simply submit more.
    if (!ended && session != nullptr) {
      bool starved = false;
      {
        std::lock_guard stateLock(async->mutex);
        const std::size_t retained = async->pendingPresentationFrames.size();
        starved = async->inFlight != 0 &&
                  retained <= async->codecReorderFrames &&
                  (async->inFlight >= options.maxInFlightFrames ||
                   retained >= async->maxRetainedFrames ||
                   async->inFlight >= async->maxRetainedFrames - retained);
      }
      if (starved) {
        const OSStatus waitStatus =
            VTDecompressionSessionWaitForAsynchronousFrames(session);
        if (waitStatus != noErr) {
          return failEndOfStreamLocked(
              statusError("VTDecompressionSessionWaitForAsynchronousFrames",
                          waitStatus),
              error);
        }
        // Any error the completed callbacks published stays latched for the
        // next entry, exactly where every other async error is observed.
      }
    }

    DecodedFrameSink *sink = nullptr;
    bool hasFrame = false;
    bool acceptedFrame = false;
    bool moreFrames = false;
    bool notifySinkEnd = false;
    FrameLease deliveryAttempt;
    FrameLease retiredFrame;
    FrameEnqueueResult enqueueResult = FrameEnqueueResult::Rejected;
    std::string sinkError;
    const auto failDrain = [&](std::string message) {
      return failEndOfStreamLocked(std::move(message), error);
    };
    {
      std::lock_guard deliveryLock(async->deliveryMutex);
      {
        std::lock_guard stateLock(async->mutex);
        if (generation != async->generation) {
          assignError(error, "end-of-stream operation belongs to a stale "
                             "generation");
          return VideoDecodeDrainProgress::StaleGeneration;
        }
        if (ended &&
            (async->inFlight != 0 || !async->completedDecodes.empty())) {
          return VideoDecodeDrainProgress::Quiescing;
        }
        sink = async->sink;
        if (sink == nullptr) {
          return failDrain(
              "presentation drain has no configured output sink");
        }
        const bool presentable =
            !async->pendingPresentationFrames.empty() &&
            (ended || async->pendingPresentationFrames.size() >
                          async->codecReorderFrames);
        if (presentable) {
          FrameLease &candidate = async->pendingPresentationFrames.front();
          if (!candidate ||
              candidate.timing().generation != generation ||
              !CMTIME_IS_NUMERIC(candidate.timing().presentationTime) ||
              timeBefore(candidate.timing().presentationTime,
                         async->lastDeliveredPresentationTime)) {
            return failDrain(
                "presentation drain violated ordered frame ownership");
          }
          deliveryAttempt = candidate;
          if (!deliveryAttempt) {
            return failDrain(
                "could not clone the retained presentation frame lease");
          }
          hasFrame = true;
        }
      }

      if (hasFrame) {
        try {
          enqueueResult = sink->enqueue(std::move(deliveryAttempt), &sinkError);
        } catch (const std::exception &) {
          return failDrain(
              "presentation frame delivery threw an exception");
        } catch (...) {
          return failDrain(
              "presentation frame delivery threw an unknown exception");
        }

        std::lock_guard stateLock(async->mutex);
        if (enqueueResult == FrameEnqueueResult::Backpressure) {
          incrementSaturated(async->sinkBackpressureRetries);
          if (ended) {
            incrementSaturated(async->endOfStreamBackpressureRetries);
          }
          // The canonical vector entry was never moved. The failed attempt was
          // only an alias of the same IOSurface accounting token, so no new
          // surface charge or replacement record is created for retry.
          return VideoDecodeDrainProgress::Quiescing;
        }
        if (enqueueResult != FrameEnqueueResult::Accepted) {
          return failDrain(
              sinkError.empty() ? "decoded frame sink rejected an "
                                  "owner-drained frame"
                                : std::move(sinkError));
        }

        FrameLease &accepted = async->pendingPresentationFrames.front();
        async->lastDeliveredPresentationTime =
            accepted.timing().presentationTime;
        retiredFrame = std::move(accepted);
        async->pendingPresentationFrames.erase(
            async->pendingPresentationFrames.begin());
        incrementSaturated(async->delivered);
        acceptedFrame = true;
        moreFrames =
            !async->pendingPresentationFrames.empty() &&
            (ended || async->pendingPresentationFrames.size() >
                          async->codecReorderFrames);
      }
      notifySinkEnd = ended && !moreFrames;
    }

    retiredFrame.reset();

    if (moreFrames || (acceptedFrame && !ended)) {
      notifyProgress(async);
      return VideoDecodeDrainProgress::Progress;
    }

    if (!notifySinkEnd) {
      return VideoDecodeDrainProgress::Quiescing;
    }

    // There are no callbacks and no retained ordered frames. endOfStream() is
    // invoked once and only after the final accepted frame (if any) has left
    // decoder ownership.
    try {
      sink->endOfStream(generation);
    } catch (const std::exception &) {
      return failDrain(
          "decoded frame sink end-of-stream threw an exception");
    } catch (...) {
      return failDrain(
          "decoded frame sink end-of-stream threw an unknown exception");
    }
    endOfStreamSinkNotified = true;
    notifyProgress(async);
    return VideoDecodeDrainProgress::Done;
  }

  VideoDecodeDrainProgress drainEndOfStreamLocked(
      std::uint64_t generation, std::string *error) {
    return drainPresentationLocked(generation, true, error);
  }
};

VideoToolboxDecoder::VideoToolboxDecoder(VideoToolboxDecoderOptions options)
    : impl_(std::make_unique<Impl>(options)) {
  if (options.maxInFlightFrames == 0) {
    throw std::invalid_argument(
        "VideoToolbox decoder in-flight bound must be greater than zero");
  }
  if (options.maxPendingPresentationFrames == 0) {
    throw std::invalid_argument(
        "VideoToolbox presentation reorder bound must be greater than zero");
  }
  if (options.outputInterop != VideoToolboxOutputInterop::Metal &&
      options.outputInterop != VideoToolboxOutputInterop::OpenGL &&
      options.outputInterop != VideoToolboxOutputInterop::DisplayLayer) {
    throw std::invalid_argument(
        "unsupported VideoToolbox output interop contract");
  }
}

VideoToolboxDecoder::~VideoToolboxDecoder() { close(); }

bool VideoToolboxDecoder::configure(
    const VideoStreamConfiguration &configuration, DecodedFrameSink &sink,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  // VP9 and AV1 are admitted only where this machine can actually decode them.
  // VP9 additionally requires the supplemental decoder to have been
  // registered, which the capability helper does before its first query, so
  // consulting it here also satisfies the registration precondition for the
  // decompression session created further below.
  const bool admittedCodec =
      configuration.codec == kCMVideoCodecType_H264 ||
      configuration.codec == kCMVideoCodecType_HEVC ||
      // MPEG-2 decodes through VideoToolbox's SOFTWARE decoder on this
      // platform, so it is admitted without a capability query -- the query
      // would answer 0 and refuse a stream that demonstrably decodes.
      configuration.codec == kCMVideoCodecType_MPEG2Video ||
      // MPEG-4 Part 2 is software on this platform too, and for the same
      // reason takes no capability query. Its PROFILE gate is upstream: only
      // Simple Profile survives media::inspectMpeg4VisualHeaders(), because
      // Apple's decoder refuses Advanced Simple Profile here with
      // codecBadDataErr (-8969).
      configuration.codec == kCMVideoCodecType_MPEG4Video ||
      (configuration.codec == kCMVideoCodecType_VP9 &&
       nativeVideoToolboxSupportsVp9()) ||
      (configuration.codec == kCMVideoCodecType_AV1 &&
       nativeVideoToolboxSupportsAv1());
  // The record requirement is inverted for MPEG-2 and stated that way: it must
  // present NO record, because it has none.
  const bool admittedConfigurationShape =
      codecCarriesNoConfigurationRecord(configuration.codec)
          ? configuration.codecConfiguration.empty()
          : !configuration.codecConfiguration.empty();
  if (!admittedCodec || configuration.codedSize.width <= 0 ||
      configuration.codedSize.height <= 0 || !admittedConfigurationShape) {
    assignError(error,
                "VideoToolbox requires a decodable "
                "H.264/HEVC/VP9/AV1/MPEG-2/MPEG-4 Part 2 stream, positive "
                "dimensions, and the configuration record shape its codec "
                "states (avcC/hvcC/vpcC/av1C/esds, or none at all for "
                "MPEG-2)");
    return false;
  }

  std::lock_guard operationLock(impl_->operationMutex);

  if (impl_->retirementStarted) {
    assignError(error, "VideoToolbox decoder was terminally retired");
    return false;
  }

  // Retire an earlier configuration before exposing the new sink/generation.
  if (impl_->configured) {
    DecodedFrameSink *oldSink = nullptr;
    {
      std::lock_guard stateLock(impl_->async->mutex);
      impl_->async->discarding = true;
      ++impl_->async->generation;
      oldSink = impl_->async->sink;
    }
    impl_->waitAndInvalidateSessionLocked();
    resetPresentationState(impl_->async);
    if (oldSink != nullptr) {
      oldSink->flush(impl_->async->generation);
    }
    notifyProgress(impl_->async);
  }
  impl_->configured = false;
  impl_->resetEndOfStreamLocked();
  impl_->awaitingKeyFrame = true;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = nullptr;
    impl_->async->discarding = true;
  }
  if (impl_->formatDescription != nullptr) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
  }

  const OSStatus descriptionStatus =
      createFormatDescription(configuration, &impl_->formatDescription);
  if (descriptionStatus != noErr || impl_->formatDescription == nullptr) {
    assignError(error, statusError("CMVideoFormatDescriptionCreate",
                                   descriptionStatus));
    return false;
  }

  const std::optional<CodecReorderDepth> codecReorderDepth =
      deriveCodecReorderDepth(configuration);
  if (!codecReorderDepth) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    assignError(error,
                "could not derive a bounded presentation-reorder depth from "
                "the codec SPS");
    return false;
  }
  // A DECLARED depth above the bound is a refusal: the stream is entitled to
  // every frame it asked for, honouring it would overrun the route's
  // decoded-surface budget, and clamping it would reorder that stream's
  // output. An INFERRED depth above the bound is not a demand at all, only the
  // ceiling the specification substitutes for a statement the stream never
  // made, so it is clamped to the bound instead of refused. Understating a
  // stream that really did need more cannot present frames out of order:
  // collectCompletedDecodes() compares every completed frame against the last
  // one delivered and fails the decoder closed before publishing an older one.
  // See CodecReorderDepthOrigin for why the inference is unusable as a refusal
  // criterion in the first place.
  std::size_t admittedReorderFrames = codecReorderDepth->frames;
  if (admittedReorderFrames > impl_->options.maxPendingPresentationFrames) {
    if (codecReorderDepth->origin == CodecReorderDepthOrigin::Declared) {
      CFRelease(impl_->formatDescription);
      impl_->formatDescription = nullptr;
      assignError(error,
                  "codec SPS requires " +
                      std::to_string(codecReorderDepth->frames) +
                      " presentation-reorder frames, exceeding the configured "
                      "bound of " +
                      std::to_string(
                          impl_->options.maxPendingPresentationFrames));
      return false;
    }
    admittedReorderFrames = impl_->options.maxPendingPresentationFrames;
  }
  if (admittedReorderFrames >
      std::numeric_limits<std::size_t>::max() -
          impl_->options.maxInFlightFrames) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    assignError(error, "VideoToolbox retained-frame bound overflows size_t");
    return false;
  }
  if (!reserveCallbackStorage(impl_->async, impl_->options.maxInFlightFrames,
                              impl_->options.maxPendingPresentationFrames,
                              error)) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    return false;
  }

  impl_->preferHardware = configuration.preferHardwareDecode;
  impl_->requireHardware = configuration.requireHardwareDecode;
  impl_->outputPixelFormat = requestedPixelFormat(configuration);
  // Only a WIDENED request needs the pin. A stream that is already 10-bit
  // gets a 10-bit surface from an unpinned session anyway, and pinning it
  // would cost that session the lossless-compressed surface forms the
  // display-layer interop is deliberately left free to use.
  impl_->hdrOutputSurfaceRequired = configuration.highDynamicRangeTransfer &&
                                    !codedDepthIsTenBit(configuration);
  impl_->codecReorderFrames = admittedReorderFrames;
  impl_->resetEndOfStreamLocked();
  impl_->awaitingKeyFrame = true;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = &sink;
    impl_->async->generation = configuration.generation;
    impl_->async->discarding = false;
    impl_->async->inFlight = 0;
    impl_->async->activeCallbacks = 0;
    impl_->async->submitted = 0;
    impl_->async->directSampleBufferSubmissions = 0;
    impl_->async->directSampleBufferBytes = 0;
    impl_->async->copiedSpanSubmissions = 0;
    impl_->async->copiedSpanBytes = 0;
    impl_->async->currentDirectCompressedBytes = 0;
    impl_->async->peakDirectCompressedBytes = 0;
    impl_->async->currentCopiedCompressedBytes = 0;
    impl_->async->peakCopiedCompressedBytes = 0;
    impl_->async->currentCompressedBytes = 0;
    impl_->async->peakCompressedBytes = 0;
    impl_->async->delivered = 0;
    impl_->async->dropped = 0;
    impl_->async->backpressuredSubmissions = 0;
    impl_->async->sinkBackpressureDrops = 0;
    impl_->async->sinkBackpressureRetries = 0;
    impl_->async->endOfStreamBackpressureRetries = 0;
    impl_->async->surfaceBudgetRejections = 0;
    impl_->async->outOfOrderDrops = 0;
    impl_->async->codecReorderFrames = impl_->codecReorderFrames;
    impl_->async->maxRetainedFrames =
        impl_->options.maxInFlightFrames + impl_->codecReorderFrames;
    impl_->async->peakPendingPresentationFrames = 0;
    impl_->async->nextSubmissionSequence = 0;
    impl_->async->nextCompletionSequence = 0;
    for (AsyncDecodeState::FrameRefConSlot &slot :
         impl_->async->frameRefConSlots) {
      slot.state = AsyncDecodeState::FrameRefConSlotState::Available;
      slot.submissionSequence = 0;
      slot.timing = {};
      slot.compressedBytes = 0;
      slot.directCompressedStorage = false;
    }
    impl_->async->completedDecodes.clear();
    impl_->async->pendingPresentationFrames.clear();
    impl_->async->outputInterop = impl_->options.outputInterop;
    impl_->async->expectedOutputPixelFormat = impl_->outputPixelFormat;
    impl_->async->actualOutputPixelFormat = 0;
    impl_->async->expectedCodedDimensions = configuration.codedSize;
    impl_->async->lastDeliveredPresentationTime = kCMTimeInvalid;
    impl_->async->callbackFailedClosed = false;
    impl_->async->endOfStreamBegun = false;
    impl_->async->lastError.reset();
#if defined(WAM_NATIVE_VIDEO_TESTING)
    impl_->async->failNextAllocationPoint.reset();
    impl_->async->permitSyntheticCallbackFrame = false;
    impl_->async->permitSyntheticOutputSurface = false;
#endif
  }
  sink.flush(configuration.generation);

  if (!impl_->createSessionLocked(error)) {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = nullptr;
    impl_->async->discarding = true;
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    return false;
  }
  impl_->configured = true;
  return true;
}

VideoDecodeSubmitResult
VideoToolboxDecoder::submit(const CompressedVideoPacket &packet,
                            std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (!impl_->configured) {
    assignError(error, "VideoToolbox decoder is not configured");
    return VideoDecodeSubmitResult::Rejected;
  }

  std::uint64_t generation = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    generation = impl_->async->generation;
  }
  if (packet.generation != generation) {
    assignError(error, "compressed packet belongs to a stale generation");
    return VideoDecodeSubmitResult::Rejected;
  }

  if (packet.endOfStream) {
    const VideoDecodeDrainProgress begun =
        impl_->beginEndOfStreamLocked(generation, error);
    if (begun == VideoDecodeDrainProgress::Failed ||
        begun == VideoDecodeDrainProgress::StaleGeneration) {
      return VideoDecodeSubmitResult::Rejected;
    }
    if (begun == VideoDecodeDrainProgress::Done) {
      return VideoDecodeSubmitResult::Accepted;
    }
    const VideoDecodeDrainProgress drained =
        impl_->drainEndOfStreamLocked(generation, error);
    switch (drained) {
    case VideoDecodeDrainProgress::Done:
      return VideoDecodeSubmitResult::Accepted;
    case VideoDecodeDrainProgress::Progress:
    case VideoDecodeDrainProgress::Quiescing:
      // Resubmitting the exact EOS packet performs at most one more bounded
      // owner drain attempt; the retained frame is never silently consumed.
      return VideoDecodeSubmitResult::Backpressure;
    case VideoDecodeDrainProgress::StaleGeneration:
    case VideoDecodeDrainProgress::Failed:
      return VideoDecodeSubmitResult::Rejected;
    }
  }

  if (impl_->ended) {
    assignError(error, "cannot submit compressed data after end of stream");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (packet.bytes.empty()) {
    assignError(error, "compressed video packet is empty");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!native_video_limits::acceptsCompressedVideoAccessUnitSize(
          packet.bytes.size())) {
    assignError(error,
                "compressed video packet exceeds the 8 MiB decoder memory "
                "bound");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl_->awaitingKeyFrame && !packet.keyFrame) {
    assignError(error, "decoder requires a key frame after configure or flush");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (auto asyncError = impl_->takeAsyncErrorLocked()) {
    assignError(error, std::move(*asyncError));
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!impl_->createSessionLocked(error)) {
    return VideoDecodeSubmitResult::Rejected;
  }

  // Reserve bounded decode capacity before allocating or copying compressed
  // packet storage. Backpressure therefore has constant cost and never grows
  // memory just to discover that the pipeline is already saturated.
  AsyncDecodeState::FrameRefConSlot *slot =
      impl_->reserveDecodeCapacityLocked();
  if (slot == nullptr) {
    return VideoDecodeSubmitResult::Backpressure;
  }

  CMSampleBufferRef sample = nullptr;
  const OSStatus sampleStatus =
      createCompressedSampleBuffer(impl_->formatDescription, packet, &sample);
  if (sampleStatus != noErr || sample == nullptr) {
    releaseReservedDecodeCapacity(impl_->async, slot);
    notifyProgress(impl_->async);
    assignError(error, statusError("CMSampleBufferCreateReady", sampleStatus));
    return VideoDecodeSubmitResult::Rejected;
  }

  const FrameTiming timing{packet.presentationTime, packet.duration,
                           packet.generation, packet.keyFrame};
  const VideoDecodeSubmitResult result = impl_->submitPreparedSampleLocked(
      sample, slot, timing, CompressedSubmissionStorage::CopiedSpan,
      packet.bytes.size(), error);
  CFRelease(sample);
  return result;
}

VideoDecodeSubmitResult VideoToolboxDecoder::submitCMSampleBuffer(
    CMSampleBufferRef sample, std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (!impl_->configured) {
    assignError(error, "VideoToolbox decoder is not configured");
    return VideoDecodeSubmitResult::Rejected;
  }

  std::uint64_t activeGeneration = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    activeGeneration = impl_->async->generation;
  }
  if (generation != activeGeneration) {
    assignError(error,
                "compressed CoreMedia sample belongs to a stale generation");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl_->ended) {
    assignError(error, "cannot submit compressed data after end of stream");
    return VideoDecodeSubmitResult::Rejected;
  }

  DirectCompressedSampleMetadata metadata;
  if (!inspectDirectCompressedSample(sample, metadata, error)) {
    return VideoDecodeSubmitResult::Rejected;
  }
  const CMVideoDimensions sampleDimensions =
      CMVideoFormatDescriptionGetDimensions(metadata.formatDescription);
  const CMVideoDimensions configuredDimensions =
      CMVideoFormatDescriptionGetDimensions(impl_->formatDescription);
  if (CMFormatDescriptionGetMediaSubType(metadata.formatDescription) !=
          CMFormatDescriptionGetMediaSubType(impl_->formatDescription) ||
      sampleDimensions.width != configuredDimensions.width ||
      sampleDimensions.height != configuredDimensions.height) {
    assignError(error,
                "compressed CoreMedia sample does not match the configured "
                "codec and coded dimensions");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl_->awaitingKeyFrame && !metadata.keyFrame) {
    assignError(error, "decoder requires a key frame after configure or flush");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (auto asyncError = impl_->takeAsyncErrorLocked()) {
    assignError(error, std::move(*asyncError));
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!impl_->adoptDirectFormatLocked(metadata, error)) {
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!impl_->createSessionLocked(error)) {
    return VideoDecodeSubmitResult::Rejected;
  }
  if (!impl_->acceptsDirectFormatLocked(metadata, error)) {
    return VideoDecodeSubmitResult::Rejected;
  }

  // Preserve the same finite admission gate as generic packet submission.
  // All inspection above is metadata-only; the compressed payload has not
  // been flattened, allocated, or copied when Backpressure is returned.
  AsyncDecodeState::FrameRefConSlot *slot =
      impl_->reserveDecodeCapacityLocked();
  if (slot == nullptr) {
    return VideoDecodeSubmitResult::Backpressure;
  }

  const FrameTiming timing{metadata.presentationTime, metadata.duration,
                           generation, metadata.keyFrame};
  return impl_->submitPreparedSampleLocked(
      sample, slot, timing,
      CompressedSubmissionStorage::DirectSampleBuffer,
      metadata.dataLength, error);
}

VideoDecodeDrainProgress VideoToolboxDecoder::beginEndOfStream(
    std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  return impl_->beginEndOfStreamLocked(generation, error);
}

VideoDecodeDrainProgress VideoToolboxDecoder::drainPresentation(
    std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  return impl_->drainPresentationLocked(generation, false, error);
}

VideoDecodeDrainProgress VideoToolboxDecoder::drainEndOfStream(
    std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(impl_->operationMutex);
  return impl_->drainEndOfStreamLocked(generation, error);
}

void VideoToolboxDecoder::flush(std::uint64_t nextGeneration) noexcept {
  std::lock_guard operationLock(impl_->operationMutex);
  if (impl_->retirementStarted) {
    return;
  }
  DecodedFrameSink *sink = nullptr;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->generation = nextGeneration;
    impl_->async->discarding = true;
    impl_->async->lastError.reset();
    sink = impl_->async->sink;
  }
  impl_->waitAndInvalidateSessionLocked();
  resetPresentationState(impl_->async);
  if (sink != nullptr) {
    sink->flush(nextGeneration);
  }
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->discarding = !impl_->configured;
  }
  impl_->resetEndOfStreamLocked();
  impl_->awaitingKeyFrame = true;
  notifyProgress(impl_->async);
}

VideoDecoderRetireProgress VideoToolboxDecoder::retire(
    std::uint64_t retiredGeneration,
    std::uint64_t invalidationGeneration) noexcept {
  if (!impl_) {
    return VideoDecoderRetireProgress::Failed;
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (impl_->retirementStarted) {
    if (impl_->retirementRetiredGeneration != retiredGeneration ||
        impl_->retirementInvalidationGeneration != invalidationGeneration) {
      return VideoDecoderRetireProgress::StaleGeneration;
    }
    return impl_->retirementDone ? VideoDecoderRetireProgress::Done
                                 : VideoDecoderRetireProgress::Failed;
  }
  std::uint64_t exposedGeneration = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    exposedGeneration = impl_->async->generation;
  }
  if (retiredGeneration != exposedGeneration ||
      invalidationGeneration == 0 ||
      invalidationGeneration <= retiredGeneration) {
    return retiredGeneration != exposedGeneration
               ? VideoDecoderRetireProgress::StaleGeneration
               : VideoDecoderRetireProgress::Failed;
  }
  impl_->retirementStarted = true;
  impl_->retirementRetiredGeneration = retiredGeneration;
  impl_->retirementInvalidationGeneration = invalidationGeneration;

  DecodedFrameSink *sink = nullptr;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->generation = invalidationGeneration;
    impl_->async->discarding = true;
    sink = impl_->async->sink;
  }
  impl_->waitAndInvalidateSessionLocked();
  resetPresentationState(impl_->async);
  if (sink != nullptr) {
    sink->flush(invalidationGeneration);
  }
  if (impl_->formatDescription != nullptr) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
  }
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = nullptr;
  }
  impl_->configured = false;
  impl_->resetEndOfStreamLocked();
  impl_->awaitingKeyFrame = true;
  impl_->usingHardware = false;
  impl_->retirementDone = true;
  notifyProgress(impl_->async);
  return VideoDecoderRetireProgress::Done;
}

void VideoToolboxDecoder::close() noexcept {
  if (!impl_) {
    return;
  }
  std::lock_guard operationLock(impl_->operationMutex);
  if (impl_->retirementStarted) {
    return;
  }
  if (!impl_->configured && impl_->session == nullptr &&
      impl_->formatDescription == nullptr) {
    return;
  }

  DecodedFrameSink *sink = nullptr;
  std::uint64_t retiredGeneration = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    retiredGeneration = impl_->async->generation + 1;
    impl_->async->generation = retiredGeneration;
    impl_->async->discarding = true;
    sink = impl_->async->sink;
  }
  impl_->waitAndInvalidateSessionLocked();
  resetPresentationState(impl_->async);
  if (sink != nullptr) {
    sink->flush(retiredGeneration);
  }
  if (impl_->formatDescription != nullptr) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
  }
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = nullptr;
  }
  impl_->configured = false;
  impl_->resetEndOfStreamLocked();
  impl_->awaitingKeyFrame = true;
  impl_->usingHardware = false;
  notifyProgress(impl_->async);
}

VideoToolboxDecoderStats VideoToolboxDecoder::stats() const noexcept {
  std::lock_guard operationLock(impl_->operationMutex);
  VideoToolboxDecoderStats result;
  result.configured = impl_->configured;
  result.usingHardwareAcceleratedDecoder = impl_->usingHardware;
  result.awaitingKeyFrame = impl_->awaitingKeyFrame;
  result.maxInFlightFrames = impl_->options.maxInFlightFrames;
  result.outputInterop = impl_->options.outputInterop;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    result.inFlightFrames = impl_->async->inFlight;
    result.retainedPresentationFrames =
        impl_->async->pendingPresentationFrames.size();
    result.acceptsCompressedSample =
        impl_->configured && !impl_->ended && !impl_->async->discarding &&
        impl_->async->inFlight < impl_->options.maxInFlightFrames &&
        impl_->async->pendingPresentationFrames.size() <
            impl_->async->maxRetainedFrames &&
        impl_->async->inFlight <
            impl_->async->maxRetainedFrames -
                impl_->async->pendingPresentationFrames.size();
    result.codecReorderFrames = impl_->async->codecReorderFrames;
    result.generation = impl_->async->generation;
    result.submittedFrames = impl_->async->submitted;
    result.directSampleBufferSubmissions =
        impl_->async->directSampleBufferSubmissions;
    result.directSampleBufferBytes = impl_->async->directSampleBufferBytes;
    result.copiedSpanSubmissions = impl_->async->copiedSpanSubmissions;
    result.copiedSpanBytes = impl_->async->copiedSpanBytes;
    result.deliveredFrames = impl_->async->delivered;
    result.droppedFrames = impl_->async->dropped;
    result.backpressuredSubmissions = impl_->async->backpressuredSubmissions;
    result.sinkBackpressureDrops = impl_->async->sinkBackpressureDrops;
    result.sinkBackpressureRetries = impl_->async->sinkBackpressureRetries;
    result.endOfStreamBackpressureRetries =
        impl_->async->endOfStreamBackpressureRetries;
    result.surfaceBudgetRejections =
        impl_->async->surfaceBudgetRejections;
    result.outOfOrderDrops = impl_->async->outOfOrderDrops;
    result.pendingPresentationFrames =
        impl_->async->pendingPresentationFrames.size();
    result.peakPendingPresentationFrames =
        impl_->async->peakPendingPresentationFrames;
    result.endOfStreamBegun = impl_->ended;
    result.endOfStreamCallbacksFinalized =
        impl_->endOfStreamCallbacksFinalized;
    result.endOfStreamSinkNotified = impl_->endOfStreamSinkNotified;
    result.requestedOutputPixelFormat = impl_->outputPixelFormat;
    result.actualOutputPixelFormat = impl_->async->actualOutputPixelFormat;
  }
  return result;
}

VideoToolboxDecoderMemoryFacts
VideoToolboxDecoder::memoryFacts() const noexcept {
  VideoToolboxDecoderMemoryFacts result;
  std::lock_guard operationLock(impl_->operationMutex);
  std::lock_guard stateLock(impl_->async->mutex);
  result.inFlightFrames = impl_->async->inFlight;
  result.presentationFrames =
      impl_->async->pendingPresentationFrames.size();
  result.currentDirectCompressedBytes =
      impl_->async->currentDirectCompressedBytes;
  result.peakDirectCompressedBytes =
      impl_->async->peakDirectCompressedBytes;
  result.currentCopiedCompressedBytes =
      impl_->async->currentCopiedCompressedBytes;
  result.peakCopiedCompressedBytes =
      impl_->async->peakCopiedCompressedBytes;
  result.currentCompressedBytes = impl_->async->currentCompressedBytes;
  result.peakCompressedBytes = impl_->async->peakCompressedBytes;
  return result;
}

std::optional<std::string> VideoToolboxDecoder::takeLastError() {
  return impl_->takeAsyncErrorLocked();
}

#if defined(WAM_NATIVE_VIDEO_TESTING)
bool VideoToolboxDecoderTestAccess::admitsConfigurationMetadata(
    const VideoStreamConfiguration &configuration) noexcept {
  return admitsCodecConfigurationMetadata(configuration);
}

bool VideoToolboxDecoderTestAccess::copyFormatDescription(
    const VideoStreamConfiguration &configuration,
    CMVideoFormatDescriptionRef *descriptionOut, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (descriptionOut == nullptr) {
    assignError(error, "test format-description output is null");
    return false;
  }
  *descriptionOut = nullptr;
  const OSStatus status = createFormatDescription(configuration, descriptionOut);
  if (status != noErr || *descriptionOut == nullptr) {
    assignError(error,
                statusError("CMVideoFormatDescriptionCreate", status));
    return false;
  }
  return true;
}

bool VideoToolboxDecoderTestAccess::inspectDirectSampleMetadata(
    CMSampleBufferRef sample, std::size_t *dataLength,
    std::size_t *configurationLength, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (dataLength == nullptr || configurationLength == nullptr) {
    assignError(error, "test direct-sample metadata output is null");
    return false;
  }
  *dataLength = 0;
  *configurationLength = 0;
  DirectCompressedSampleMetadata metadata;
  if (!inspectDirectCompressedSample(sample, metadata, error)) {
    return false;
  }
  *dataLength = metadata.dataLength;
  *configurationLength = metadata.configurationLength;
  return true;
}

bool VideoToolboxDecoderTestAccess::inspectDirectConfigurationExtensions(
    CMVideoCodecType codec, CFDictionaryRef extensions,
    std::size_t *configurationLength, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (configurationLength == nullptr) {
    assignError(error, "test direct-configuration length output is null");
    return false;
  }
  *configurationLength = 0;
  CodecConfigurationAtomMetadata metadata;
  if (!inspectCodecConfigurationExtensions(codec, extensions, metadata,
                                           error)) {
    return false;
  }
  *configurationLength = metadata.byteLength;
  return true;
}

bool VideoToolboxDecoderTestAccess::equivalentFormatConfigurations(
    CMVideoFormatDescriptionRef configuredFormat,
    CMVideoFormatDescriptionRef directFormat, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  return equivalentFormatCodecConfigurations(configuredFormat, directFormat,
                                             error);
}

bool VideoToolboxDecoderTestAccess::occupyInFlightCapacity(
    VideoToolboxDecoder &decoder, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  if (decoder.impl_->testReservedInFlight != 0 ||
      decoder.impl_->async->inFlight != 0) {
    assignError(error, "test decoder already has in-flight work");
    return false;
  }
  decoder.impl_->testReservedInFlight =
      decoder.impl_->options.maxInFlightFrames;
  decoder.impl_->async->inFlight = decoder.impl_->testReservedInFlight;
  return true;
}

bool VideoToolboxDecoderTestAccess::releaseInFlightCapacity(
    VideoToolboxDecoder &decoder, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    if (decoder.impl_->testReservedInFlight == 0 ||
        decoder.impl_->async->inFlight !=
            decoder.impl_->testReservedInFlight) {
      assignError(error, "test decoder has no isolated capacity reservation");
      return false;
    }
    decoder.impl_->async->inFlight = 0;
    decoder.impl_->testReservedInFlight = 0;
    decoder.impl_->async->completion.notify_all();
  }
  notifyProgress(decoder.impl_->async);
  return true;
}

std::uint32_t VideoToolboxDecoderTestAccess::decodeFlags(
    const VideoToolboxDecoder &decoder) noexcept {
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  return static_cast<std::uint32_t>(finiteAdmissionDecodeFlags(
      decoder.impl_->options.enableAsynchronousDecompression));
}

std::optional<std::size_t> VideoToolboxDecoderTestAccess::codecReorderFrames(
    const VideoStreamConfiguration &configuration) {
  const auto depth = deriveCodecReorderDepth(configuration);
  if (!depth) {
    return std::nullopt;
  }
  return depth->frames;
}

std::optional<CodecReorderDepth>
VideoToolboxDecoderTestAccess::codecReorderDepth(
    const VideoStreamConfiguration &configuration) {
  return deriveCodecReorderDepth(configuration);
}

bool VideoToolboxDecoderTestAccess::setPresentationReorderDepth(
    VideoToolboxDecoder &decoder, std::size_t reorderFrames,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard deliveryLock(decoder.impl_->async->deliveryMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  if (reorderFrames > decoder.impl_->options.maxPendingPresentationFrames) {
    assignError(error, "test reorder depth exceeds the decoder bound");
    return false;
  }
  if (decoder.impl_->async->inFlight != 0 ||
      !decoder.impl_->async->completedDecodes.empty() ||
      !decoder.impl_->async->pendingPresentationFrames.empty()) {
    assignError(error, "test decoder ordering state is not empty");
    return false;
  }
  decoder.impl_->codecReorderFrames = reorderFrames;
  if (reorderFrames >
      std::numeric_limits<std::size_t>::max() -
          decoder.impl_->options.maxInFlightFrames) {
    assignError(error, "test retained-frame bound overflows size_t");
    return false;
  }
  decoder.impl_->async->codecReorderFrames = reorderFrames;
  decoder.impl_->async->maxRetainedFrames =
      decoder.impl_->options.maxInFlightFrames + reorderFrames;
  decoder.impl_->async->nextSubmissionSequence = 0;
  decoder.impl_->async->nextCompletionSequence = 0;
  decoder.impl_->async->lastDeliveredPresentationTime = kCMTimeInvalid;
  return true;
}

bool VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
    VideoToolboxDecoder &decoder, std::size_t count, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  if (count == 0 || count > decoder.impl_->options.maxInFlightFrames) {
    assignError(error, "test submission reservation exceeds admission");
    return false;
  }
  if (decoder.impl_->async->inFlight != 0 ||
      decoder.impl_->async->nextSubmissionSequence != 0 ||
      decoder.impl_->async->nextCompletionSequence != 0 ||
      !decoder.impl_->async->completedDecodes.empty()) {
    assignError(error, "test decoder already has submitted work");
    return false;
  }
  decoder.impl_->async->inFlight = count;
  decoder.impl_->async->nextSubmissionSequence = count;
  for (std::size_t index = 0; index < count; ++index) {
    AsyncDecodeState::FrameRefConSlot &slot =
        decoder.impl_->async->frameRefConSlots[index];
    slot.state = AsyncDecodeState::FrameRefConSlotState::Submitted;
    slot.submissionSequence = index;
    slot.timing = {};
  }
  return true;
}

VideoDecodeSubmitResult
VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
    VideoToolboxDecoder &decoder, FrameTiming timing,
    std::uint64_t *submissionSequence, std::string *error,
    std::size_t compressedBytes, bool directCompressedStorage) {
  if (error != nullptr) {
    error->clear();
  }
  if (submissionSequence == nullptr) {
    assignError(error, "test submission-sequence output is null");
    return VideoDecodeSubmitResult::Rejected;
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return VideoDecodeSubmitResult::Rejected;
  }
  AsyncDecodeState::FrameRefConSlot *slot =
      decoder.impl_->reserveDecodeCapacityLocked();
  if (slot == nullptr) {
    return VideoDecodeSubmitResult::Backpressure;
  }
  if (!decoder.impl_->armFrameRefConSlotLocked(
          slot, timing,
          directCompressedStorage
              ? CompressedSubmissionStorage::DirectSampleBuffer
              : CompressedSubmissionStorage::CopiedSpan,
          compressedBytes, submissionSequence, error)) {
    return VideoDecodeSubmitResult::Rejected;
  }
  return VideoDecodeSubmitResult::Accepted;
}

bool VideoToolboxDecoderTestAccess::rejectInjectedSubmission(
    VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
    std::int32_t decodeStatus, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (decodeStatus == noErr) {
    assignError(error, "test synchronous rejection status must fail");
    return false;
  }
  AsyncDecodeState::FrameRefConSlot *slot = nullptr;
  FrameTiming timing;
  {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    const auto matching = std::find_if(
        decoder.impl_->async->frameRefConSlots.begin(),
        decoder.impl_->async->frameRefConSlots.end(),
        [submissionSequence](const AsyncDecodeState::FrameRefConSlot &entry) {
          return entry.state ==
                     AsyncDecodeState::FrameRefConSlotState::Submitted &&
                 entry.submissionSequence == submissionSequence;
        });
    if (matching == decoder.impl_->async->frameRefConSlots.end()) {
      assignError(error,
                  "test rejection has no submitted frame-refcon slot");
      return false;
    }
    slot = &*matching;
    timing = slot->timing;
  }
  // The VideoToolbox contract guarantees no output callback after an
  // immediate DecodeFrame error. Production closes that ordering gap with the
  // same no-frame completion, without entering the persistent callback.
  deliverDecodedFrame(decoder.impl_->async, slot, submissionSequence, timing,
                      static_cast<OSStatus>(decodeStatus), 0, nullptr,
                      kCMTimeInvalid, kCMTimeInvalid);
  return true;
}

VideoToolboxDecoderFrameRefConSlotStats
VideoToolboxDecoderTestAccess::frameRefConSlotStats(
    const VideoToolboxDecoder &decoder) noexcept {
  VideoToolboxDecoderFrameRefConSlotStats result;
  try {
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    result.capacity = decoder.impl_->async->frameRefConSlots.size();
    result.inFlight = decoder.impl_->async->inFlight;
    result.activeCallbacks = decoder.impl_->async->activeCallbacks;
    result.generation = decoder.impl_->async->generation;
    for (const AsyncDecodeState::FrameRefConSlot &slot :
         decoder.impl_->async->frameRefConSlots) {
      switch (slot.state) {
      case AsyncDecodeState::FrameRefConSlotState::Available:
        ++result.available;
        break;
      case AsyncDecodeState::FrameRefConSlotState::Reserved:
        ++result.reserved;
        break;
      case AsyncDecodeState::FrameRefConSlotState::Submitted:
        ++result.submitted;
        break;
      case AsyncDecodeState::FrameRefConSlotState::CallbackComplete:
        ++result.callbackComplete;
        break;
      }
    }
  } catch (...) {
    return {};
  }
  return result;
}

bool VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
    VideoToolboxDecoder &decoder, DecodedFrameSink &sink,
    std::uint64_t generation, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  if (decoder.impl_->session != nullptr ||
      decoder.impl_->formatDescription != nullptr) {
    assignError(error, "test decoder owns a production decode session");
    return false;
  }
  if (decoder.impl_->configured) {
    DecodedFrameSink *oldSink = nullptr;
    std::uint64_t invalidationGeneration = 0;
    {
      std::lock_guard stateLock(decoder.impl_->async->mutex);
      decoder.impl_->async->discarding = true;
      invalidationGeneration = ++decoder.impl_->async->generation;
      oldSink = decoder.impl_->async->sink;
    }
    decoder.impl_->waitAndInvalidateSessionLocked();
    resetPresentationState(decoder.impl_->async);
    if (oldSink != nullptr) {
      oldSink->flush(invalidationGeneration);
    }
    decoder.impl_->configured = false;
    {
      std::lock_guard stateLock(decoder.impl_->async->mutex);
      decoder.impl_->async->sink = nullptr;
    }
    notifyProgress(decoder.impl_->async);
  }
  if (!reserveCallbackStorage(
          decoder.impl_->async, decoder.impl_->options.maxInFlightFrames,
          decoder.impl_->options.maxPendingPresentationFrames, error)) {
    return false;
  }

  {
    std::lock_guard deliveryLock(decoder.impl_->async->deliveryMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    decoder.impl_->configured = true;
    decoder.impl_->resetEndOfStreamLocked();
    decoder.impl_->awaitingKeyFrame = false;
    decoder.impl_->outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    decoder.impl_->codecReorderFrames = 0;
    decoder.impl_->async->sink = &sink;
    decoder.impl_->async->generation = generation;
    decoder.impl_->async->inFlight = 0;
    decoder.impl_->async->activeCallbacks = 0;
    decoder.impl_->async->codecReorderFrames = 0;
    decoder.impl_->async->maxRetainedFrames =
        decoder.impl_->options.maxInFlightFrames;
    decoder.impl_->async->nextSubmissionSequence = 0;
    decoder.impl_->async->nextCompletionSequence = 0;
    decoder.impl_->async->currentDirectCompressedBytes = 0;
    decoder.impl_->async->peakDirectCompressedBytes = 0;
    decoder.impl_->async->currentCopiedCompressedBytes = 0;
    decoder.impl_->async->peakCopiedCompressedBytes = 0;
    decoder.impl_->async->currentCompressedBytes = 0;
    decoder.impl_->async->peakCompressedBytes = 0;
    for (AsyncDecodeState::FrameRefConSlot &slot :
         decoder.impl_->async->frameRefConSlots) {
      slot.state = AsyncDecodeState::FrameRefConSlotState::Available;
      slot.submissionSequence = 0;
      slot.timing = {};
      slot.compressedBytes = 0;
      slot.directCompressedStorage = false;
    }
    decoder.impl_->async->completedDecodes.clear();
    decoder.impl_->async->pendingPresentationFrames.clear();
    decoder.impl_->async->outputInterop = decoder.impl_->options.outputInterop;
    decoder.impl_->async->expectedOutputPixelFormat =
        decoder.impl_->outputPixelFormat;
    decoder.impl_->async->actualOutputPixelFormat = 0;
    decoder.impl_->async->expectedCodedDimensions = {64, 32};
    decoder.impl_->async->lastDeliveredPresentationTime = kCMTimeInvalid;
    decoder.impl_->async->discarding = false;
    decoder.impl_->async->callbackFailedClosed = false;
    decoder.impl_->async->endOfStreamBegun = false;
    decoder.impl_->async->endOfStreamBackpressureRetries = 0;
    decoder.impl_->async->sinkBackpressureRetries = 0;
    decoder.impl_->async->surfaceBudgetRejections = 0;
    decoder.impl_->async->lastError.reset();
#if defined(WAM_NATIVE_VIDEO_TESTING)
    decoder.impl_->async->failNextAllocationPoint.reset();
    decoder.impl_->async->permitSyntheticCallbackFrame = true;
    decoder.impl_->async->permitSyntheticOutputSurface = false;
#endif
  }
  sink.flush(generation);
  return true;
}

bool VideoToolboxDecoderTestAccess::injectDecodedFrame(
    VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
    CVPixelBufferRef pixelBuffer, FrameTiming timing, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  return injectDecodedFrameResult(decoder, submissionSequence, pixelBuffer,
                                  timing, noErr, 0, error);
}

bool VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
    VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
    CVPixelBufferRef pixelBuffer, FrameTiming timing,
    std::int32_t callbackStatus, std::uint32_t callbackInfoFlags,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  AsyncDecodeState::FrameRefConSlot *slot = nullptr;
  {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    if (!decoder.impl_->configured) {
      assignError(error, "test decoder is not configured");
      return false;
    }
    if (pixelBuffer == nullptr &&
        !decoder.impl_->async->permitSyntheticCallbackFrame) {
      assignError(error, "test decoded frame has no pixel buffer");
      return false;
    }
    const auto matching = std::find_if(
        decoder.impl_->async->frameRefConSlots.begin(),
        decoder.impl_->async->frameRefConSlots.end(),
        [submissionSequence](const AsyncDecodeState::FrameRefConSlot &entry) {
          return entry.state ==
                     AsyncDecodeState::FrameRefConSlotState::Submitted &&
                 entry.submissionSequence == submissionSequence;
        });
    if (matching == decoder.impl_->async->frameRefConSlots.end()) {
      assignError(error, "test callback has no submitted frame-refcon slot");
      return false;
    }
    slot = &*matching;
    slot->timing = timing;
  }
  decoder.impl_->decompressionOutputCallback(
      decoder.impl_.get(), slot, static_cast<OSStatus>(callbackStatus),
      static_cast<VTDecodeInfoFlags>(callbackInfoFlags), pixelBuffer,
      timing.presentationTime, timing.duration);
  return true;
}

bool VideoToolboxDecoderTestAccess::inspectProgressState(
    VideoToolboxDecoder &decoder, std::size_t *inFlight) noexcept {
  if (inFlight == nullptr) {
    return false;
  }
  try {
    std::unique_lock deliveryLock(decoder.impl_->async->deliveryMutex,
                                  std::try_to_lock);
    if (!deliveryLock.owns_lock()) {
      return false;
    }
    std::unique_lock stateLock(decoder.impl_->async->mutex,
                               std::try_to_lock);
    if (!stateLock.owns_lock()) {
      return false;
    }
    *inFlight = decoder.impl_->async->inFlight;
    return true;
  } catch (...) {
    return false;
  }
}

void VideoToolboxDecoderTestAccess::failNextCallbackAllocation(
    VideoToolboxDecoder &decoder,
    VideoToolboxDecoderTestAllocationPoint point) noexcept {
  try {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    decoder.impl_->async->failNextAllocationPoint = point;
  } catch (...) {
  }
}

void VideoToolboxDecoderTestAccess::failNextCFAllocation(
    VideoToolboxDecoderTestCFAllocationPoint point) noexcept {
  gFailNextCFAllocationPoint = point;
}

bool VideoToolboxDecoderTestAccess::setPermitSyntheticOutputSurface(
    VideoToolboxDecoder &decoder, bool permit, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  decoder.impl_->async->permitSyntheticOutputSurface = permit;
  return true;
}

bool VideoToolboxDecoderTestAccess::validateDecodedColorAttachments(
    CVPixelBufferRef pixelBuffer, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  return validateDecodedSdrColorAttachments(pixelBuffer, error);
}

bool VideoToolboxDecoderTestAccess::setSurfaceBudgetRejections(
    VideoToolboxDecoder &decoder, std::uint64_t count,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  std::lock_guard operationLock(decoder.impl_->operationMutex);
  std::lock_guard stateLock(decoder.impl_->async->mutex);
  if (!decoder.impl_->configured) {
    assignError(error, "test decoder is not configured");
    return false;
  }
  decoder.impl_->async->surfaceBudgetRejections = count;
  return true;
}

bool VideoToolboxDecoderTestAccess::validateOutputSurface(
    CVPixelBufferRef pixelBuffer, OSType expectedPixelFormat,
    VideoToolboxOutputInterop outputInterop, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  return validateOutputSurfaceContract(pixelBuffer, expectedPixelFormat,
                                       outputInterop, error);
}

bool VideoToolboxDecoderTestAccess::admitsDecodedOutputPixelFormat(
    OSType pixelFormat, OSType expectedPixelFormat,
    VideoToolboxOutputInterop outputInterop) noexcept {
  return admitsOutputPixelFormat(pixelFormat, expectedPixelFormat,
                                 outputInterop);
}

#endif

} // namespace wam::macos
