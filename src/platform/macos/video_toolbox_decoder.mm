#include "video_toolbox_decoder.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <array>
#include <condition_variable>
#include <exception>
#include <limits>
#include <mutex>
#include <span>
#include <stdexcept>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

constexpr std::size_t kMaximumCodecConfigurationBytes = 1024ULL * 1024ULL;
constexpr std::size_t kMaximumCompressedPacketBytes =
    32ULL * 1024ULL * 1024ULL;
constexpr std::size_t kMaximumCodecReorderFrames = 16;

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

std::optional<std::size_t>
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
  if (vui.present) {
    if (vui.reorderFrames > vui.decodedFrameBuffering ||
        vui.decodedFrameBuffering > maxDpbFrames ||
        vui.decodedFrameBuffering < maxReferenceFrames) {
      return std::nullopt;
    }
    return static_cast<std::size_t>(vui.reorderFrames);
  }
  return constraintSet3 && h264ConstraintSet3ImpliesZeroReorder(
                               profileIdc)
             ? 0
             : maxDpbFrames;
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

std::optional<std::size_t>
deriveCodecReorderFrameCount(const VideoStreamConfiguration &configuration) {
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
    std::optional<std::size_t> maximum;
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
      maximum = std::max(maximum.value_or(0), *reorder);
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
    return maximum;
  }
  return std::nullopt;
}

struct AsyncDecodeState {
  struct CompletedDecode {
    std::uint64_t submissionSequence{0};
    std::optional<FrameLease> frame;
  };

  mutable std::mutex mutex;
  std::mutex deliveryMutex;
  std::condition_variable completion;
  DecodedFrameSink *sink{nullptr};
  std::uint64_t generation{0};
  std::size_t inFlight{0};
  std::uint64_t submitted{0};
  std::uint64_t delivered{0};
  std::uint64_t dropped{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t sinkBackpressureDrops{0};
  std::uint64_t outOfOrderDrops{0};
  std::size_t codecReorderFrames{0};
  std::size_t peakPendingPresentationFrames{0};
  std::uint64_t nextSubmissionSequence{0};
  std::uint64_t nextCompletionSequence{0};
  std::vector<CompletedDecode> completedDecodes;
  std::vector<FrameLease> pendingPresentationFrames;
  OSType expectedOutputPixelFormat{0};
  OSType actualOutputPixelFormat{0};
  CMTime lastDeliveredPresentationTime{kCMTimeInvalid};
  bool discarding{false};
  std::optional<std::string> lastError;
};

void finishCallbacks(const std::shared_ptr<AsyncDecodeState> &state,
                     std::size_t retiredCount = 1) noexcept {
  std::lock_guard lock(state->mutex);
  state->inFlight = retiredCount < state->inFlight
                        ? state->inFlight - retiredCount
                        : 0;
  state->completion.notify_all();
}

void recordAsyncError(const std::shared_ptr<AsyncDecodeState> &state,
                      std::string message) noexcept {
  std::lock_guard lock(state->mutex);
  state->lastError = std::move(message);
}

bool timeBefore(CMTime left, CMTime right) noexcept {
  return CMTIME_IS_NUMERIC(left) && CMTIME_IS_NUMERIC(right) &&
         CMTimeCompare(left, right) < 0;
}

void collectPresentableFramesLocked(AsyncDecodeState &state, bool drainAll,
                                    std::vector<FrameLease> &output) {
  while (!state.pendingPresentationFrames.empty()) {
    FrameLease &candidate = state.pendingPresentationFrames.front();
    if (!drainAll && state.pendingPresentationFrames.size() <=
                         state.codecReorderFrames) {
      break;
    }
    if (timeBefore(candidate.timing().presentationTime,
                   state.lastDeliveredPresentationTime)) {
      state.pendingPresentationFrames.erase(
          state.pendingPresentationFrames.begin());
      ++state.dropped;
      ++state.outOfOrderDrops;
      state.lastError =
          "VideoToolbox returned a frame older than the presentation floor";
      continue;
    }
    state.lastDeliveredPresentationTime = candidate.timing().presentationTime;
    output.push_back(std::move(candidate));
    state.pendingPresentationFrames.erase(
        state.pendingPresentationFrames.begin());
  }
}

std::size_t collectCompletedDecodesLocked(
    AsyncDecodeState &state, std::vector<FrameLease> &output) {
  std::size_t retiredCount = 0;
  while (!state.completedDecodes.empty() &&
         state.completedDecodes.front().submissionSequence ==
             state.nextCompletionSequence) {
    AsyncDecodeState::CompletedDecode completed =
        std::move(state.completedDecodes.front());
    state.completedDecodes.erase(state.completedDecodes.begin());
    ++state.nextCompletionSequence;
    ++retiredCount;

    if (!completed.frame) {
      continue;
    }
    if (timeBefore(completed.frame->timing().presentationTime,
                   state.lastDeliveredPresentationTime)) {
      ++state.dropped;
      ++state.outOfOrderDrops;
      state.lastError =
          "decoded stream exceeded its SPS presentation-reorder bound";
      continue;
    }
    auto insertion = std::upper_bound(
        state.pendingPresentationFrames.begin(),
        state.pendingPresentationFrames.end(), *completed.frame,
        [](const FrameLease &left, const FrameLease &right) {
          return timeBefore(left.timing().presentationTime,
                            right.timing().presentationTime);
        });
    state.pendingPresentationFrames.insert(insertion,
                                           std::move(*completed.frame));
    collectPresentableFramesLocked(state, false, output);
    state.peakPendingPresentationFrames =
        std::max(state.peakPendingPresentationFrames,
                 state.pendingPresentationFrames.size());
  }
  return retiredCount;
}

void deliverBatch(const std::shared_ptr<AsyncDecodeState> &state,
                  DecodedFrameSink &sink,
                  std::vector<FrameLease> frames) noexcept {
  for (FrameLease &frame : frames) {
    try {
      std::string sinkError;
      const FrameEnqueueResult result =
          sink.enqueue(std::move(frame), &sinkError);
      std::lock_guard lock(state->mutex);
      if (result == FrameEnqueueResult::Accepted) {
        ++state->delivered;
      } else if (result == FrameEnqueueResult::Backpressure) {
        // Saturation is an expected bounded-memory outcome. Account for the
        // intentional drop without poisoning subsequent decoder submissions.
        ++state->dropped;
        ++state->sinkBackpressureDrops;
      } else {
        ++state->dropped;
        state->lastError =
            sinkError.empty()
                ? "decoded frame sink rejected a frame"
                : "decoded frame sink rejected a frame: " + sinkError;
      }
    } catch (const std::exception &exception) {
      recordAsyncError(state, std::string("decoded frame delivery threw: ") +
                                  exception.what());
      std::lock_guard lock(state->mutex);
      ++state->dropped;
    } catch (...) {
      recordAsyncError(state, "decoded frame delivery threw an unknown error");
      std::lock_guard lock(state->mutex);
      ++state->dropped;
    }
  }
}

void drainAllPresentationFrames(
    const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  std::lock_guard deliveryLock(state->deliveryMutex);
  DecodedFrameSink *sink = nullptr;
  std::vector<FrameLease> readyFrames;
  {
    std::lock_guard lock(state->mutex);
    sink = state->sink;
    collectPresentableFramesLocked(*state, true, readyFrames);
  }
  if (sink != nullptr && !readyFrames.empty()) {
    deliverBatch(state, *sink, std::move(readyFrames));
  }
}

void resetPresentationState(
    const std::shared_ptr<AsyncDecodeState> &state) noexcept {
  std::vector<FrameLease> retiredFrames;
  {
    std::lock_guard deliveryLock(state->deliveryMutex);
    std::lock_guard lock(state->mutex);
    retiredFrames.swap(state->pendingPresentationFrames);
    state->completedDecodes.clear();
    state->nextSubmissionSequence = 0;
    state->nextCompletionSequence = 0;
    state->lastDeliveredPresentationTime = kCMTimeInvalid;
  }
  // Release decoder surfaces after leaving both pipeline locks.
}

void deliverDecodedFrame(const std::shared_ptr<AsyncDecodeState> &state,
                         std::uint64_t submissionSequence, FrameTiming timing,
                         OSStatus status,
                         VTDecodeInfoFlags infoFlags,
                         CVImageBufferRef imageBuffer, CMTime presentationTime,
                         CMTime presentationDuration) noexcept {
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

  DecodedFrameSink *sink = nullptr;
  std::vector<FrameLease> readyFrames;
  std::size_t retiredCount = 0;
  {
    std::lock_guard lock(state->mutex);
    sink = state->sink;
    std::optional<FrameLease> decodedFrame;
    if (status != noErr) {
      state->lastError = statusError("VideoToolbox output callback", status);
      ++state->dropped;
    } else if ((infoFlags & kVTDecodeInfo_FrameDropped) != 0 ||
               imageBuffer == nullptr) {
      ++state->dropped;
      if (imageBuffer == nullptr &&
          (infoFlags & kVTDecodeInfo_FrameDropped) == 0) {
        state->lastError =
            "VideoToolbox returned success without a decoded pixel buffer";
      }
    } else if (state->discarding || timing.generation != state->generation) {
      // A flush advances the generation before waiting for callbacks, so an
      // old frame is released here without ever reaching the new timeline.
      ++state->dropped;
    } else if (CVPixelBufferGetIOSurface(
                   static_cast<CVPixelBufferRef>(imageBuffer)) == nullptr) {
      state->lastError = "VideoToolbox produced a frame without an IOSurface";
      ++state->dropped;
    } else {
      const OSType pixelFormat = CVPixelBufferGetPixelFormatType(
          static_cast<CVPixelBufferRef>(imageBuffer));
      if (pixelFormat != state->expectedOutputPixelFormat) {
        state->lastError =
            "VideoToolbox output pixel format " +
            std::to_string(pixelFormat) + " did not match the bounded native "
            "decode contract " +
            std::to_string(state->expectedOutputPixelFormat);
        ++state->dropped;
      } else if (!CMTIME_IS_NUMERIC(timing.presentationTime)) {
        state->lastError =
            "VideoToolbox returned a decoded frame without a finite numeric "
            "presentation timestamp";
        ++state->dropped;
      } else {
        state->actualOutputPixelFormat = pixelFormat;
        if (sink == nullptr) {
          state->lastError = "decoded frame has no configured output sink";
          ++state->dropped;
        } else {
          decodedFrame.emplace(static_cast<CVPixelBufferRef>(imageBuffer),
                               timing);
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
      state->lastError =
          "VideoToolbox invoked a duplicate decoded-frame callback";
    } else {
      state->completedDecodes.insert(
          duplicate, AsyncDecodeState::CompletedDecode{
                         submissionSequence, std::move(decodedFrame)});
      retiredCount = collectCompletedDecodesLocked(*state, readyFrames);
    }
  }

  if (sink != nullptr && !readyFrames.empty()) {
    deliverBatch(state, *sink, std::move(readyFrames));
  }

  if (retiredCount != 0) {
    finishCallbacks(state, retiredCount);
  }
}

OSStatus createFormatDescription(const VideoStreamConfiguration &configuration,
                                 CMVideoFormatDescriptionRef *descriptionOut) {
  if (descriptionOut == nullptr) {
    return paramErr;
  }
  *descriptionOut = nullptr;

  const CFStringRef atomName =
      configuration.codec == kCMVideoCodecType_H264   ? CFSTR("avcC")
      : configuration.codec == kCMVideoCodecType_HEVC ? CFSTR("hvcC")
                                                      : nullptr;
  if (atomName == nullptr || configuration.codecConfiguration.empty() ||
      configuration.codecConfiguration.size() >
          kMaximumCodecConfigurationBytes ||
      configuration.codecConfiguration.size() >
          static_cast<std::size_t>(std::numeric_limits<CFIndex>::max())) {
    return paramErr;
  }

  CFDataRef atomData = CFDataCreate(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8 *>(configuration.codecConfiguration.data()),
      static_cast<CFIndex>(configuration.codecConfiguration.size()));
  if (atomData == nullptr) {
    return memFullErr;
  }

  const void *atomKeys[] = {atomName};
  const void *atomValues[] = {atomData};
  CFDictionaryRef atoms = CFDictionaryCreate(
      kCFAllocatorDefault, atomKeys, atomValues, 1,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  const void *extensionKeys[] = {
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms};
  const void *extensionValues[] = {atoms};
  CFDictionaryRef extensions =
      atoms == nullptr ? nullptr
                       : CFDictionaryCreate(kCFAllocatorDefault, extensionKeys,
                                            extensionValues, 1,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);

  OSStatus status = memFullErr;
  if (extensions != nullptr) {
    status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, configuration.codec, configuration.codedSize.width,
        configuration.codedSize.height, extensions, descriptionOut);
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

OSType
requestedPixelFormat(const VideoStreamConfiguration &configuration) noexcept {
  // hvcC stores bit_depth_luma_minus8 in the low three bits of byte 17.
  // The common H.264 High 10 profile uses profile_idc 110. Both map directly
  // to the presenter's supported 10-bit bi-planar Metal import path.
  const auto *bytes = reinterpret_cast<const std::uint8_t *>(
      configuration.codecConfiguration.data());
  bool tenBit = false;
  if (configuration.codec == kCMVideoCodecType_HEVC &&
      configuration.codecConfiguration.size() > 17) {
    tenBit = (bytes[17] & 0x07U) > 0;
  } else if (configuration.codec == kCMVideoCodecType_H264 &&
             configuration.codecConfiguration.size() > 1) {
    tenBit = bytes[1] == 110;
  }
  return tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
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

} // namespace

struct VideoToolboxDecoder::Impl {
  explicit Impl(VideoToolboxDecoderOptions decoderOptions)
      : options(decoderOptions), async(std::make_shared<AsyncDecodeState>()) {}

  VideoToolboxDecoderOptions options;
  mutable std::mutex operationMutex;
  std::shared_ptr<AsyncDecodeState> async;
  CMVideoFormatDescriptionRef formatDescription{nullptr};
  VTDecompressionSessionRef session{nullptr};
  bool configured{false};
  bool ended{false};
  bool awaitingKeyFrame{true};
  bool usingHardware{false};
  bool preferHardware{true};
  bool requireHardware{false};
  OSType outputPixelFormat{0};
  std::size_t codecReorderFrames{0};
#if defined(WAM_NATIVE_VIDEO_TESTING)
  std::size_t testReservedInFlight{0};
#endif

  ~Impl() {
    if (session != nullptr) {
      VTDecompressionSessionInvalidate(session);
      CFRelease(session);
    }
    if (formatDescription != nullptr) {
      CFRelease(formatDescription);
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

    CFMutableDictionaryRef decoderSpecification = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
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

    CFDictionaryRef emptyIOSurfaceProperties = CFDictionaryCreate(
        kCFAllocatorDefault, nullptr, nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef imageAttributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(imageAttributes, kCVPixelBufferIOSurfacePropertiesKey,
                         emptyIOSurfaceProperties);
    CFDictionarySetValue(imageAttributes, kCVPixelBufferMetalCompatibilityKey,
                         kCFBooleanTrue);
    const std::int32_t pixelFormatValue =
        static_cast<std::int32_t>(outputPixelFormat);
    CFNumberRef pixelFormatNumber = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormatValue);
    if (pixelFormatNumber == nullptr) {
      CFRelease(imageAttributes);
      CFRelease(emptyIOSurfaceProperties);
      CFRelease(decoderSpecification);
      assignError(error, "could not allocate the output pixel-format request");
      return false;
    }
    CFDictionarySetValue(imageAttributes, kCVPixelBufferPixelFormatTypeKey,
                         pixelFormatNumber);

    const OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault, formatDescription, decoderSpecification,
        imageAttributes, nullptr, &session);
    CFRelease(pixelFormatNumber);
    CFRelease(imageAttributes);
    CFRelease(emptyIOSurfaceProperties);
    CFRelease(decoderSpecification);
    if (status != noErr || session == nullptr) {
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

  void waitAndInvalidateSessionLocked() noexcept {
    if (session == nullptr) {
      return;
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session);
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    session = nullptr;
    usingHardware = false;

    std::unique_lock lock(async->mutex);
    async->completion.wait(lock, [this] { return async->inFlight == 0; });
  }

  std::optional<std::string> takeAsyncErrorLocked() {
    std::lock_guard lock(async->mutex);
    std::optional<std::string> result = std::move(async->lastError);
    async->lastError.reset();
    return result;
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
}

VideoToolboxDecoder::~VideoToolboxDecoder() { close(); }

bool VideoToolboxDecoder::configure(
    const VideoStreamConfiguration &configuration, DecodedFrameSink &sink,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if ((configuration.codec != kCMVideoCodecType_H264 &&
       configuration.codec != kCMVideoCodecType_HEVC) ||
      configuration.codedSize.width <= 0 ||
      configuration.codedSize.height <= 0 ||
      configuration.codecConfiguration.empty()) {
    assignError(error,
                "VideoToolbox requires H.264/HEVC, positive dimensions, and "
                "an avcC/hvcC configuration atom");
    return false;
  }

  std::lock_guard operationLock(impl_->operationMutex);

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
  }
  impl_->configured = false;
  impl_->ended = false;
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

  const std::optional<std::size_t> codecReorderFrames =
      deriveCodecReorderFrameCount(configuration);
  if (!codecReorderFrames) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    assignError(error,
                "could not derive a bounded presentation-reorder depth from "
                "the codec SPS");
    return false;
  }
  if (*codecReorderFrames > impl_->options.maxPendingPresentationFrames) {
    CFRelease(impl_->formatDescription);
    impl_->formatDescription = nullptr;
    assignError(error,
                "codec SPS requires " +
                    std::to_string(*codecReorderFrames) +
                    " presentation-reorder frames, exceeding the configured "
                    "bound of " +
                    std::to_string(
                        impl_->options.maxPendingPresentationFrames));
    return false;
  }

  impl_->preferHardware = configuration.preferHardwareDecode;
  impl_->requireHardware = configuration.requireHardwareDecode;
  impl_->outputPixelFormat = requestedPixelFormat(configuration);
  impl_->codecReorderFrames = *codecReorderFrames;
  impl_->ended = false;
  impl_->awaitingKeyFrame = true;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    impl_->async->sink = &sink;
    impl_->async->generation = configuration.generation;
    impl_->async->discarding = false;
    impl_->async->inFlight = 0;
    impl_->async->submitted = 0;
    impl_->async->delivered = 0;
    impl_->async->dropped = 0;
    impl_->async->backpressuredSubmissions = 0;
    impl_->async->sinkBackpressureDrops = 0;
    impl_->async->outOfOrderDrops = 0;
    impl_->async->codecReorderFrames = impl_->codecReorderFrames;
    impl_->async->peakPendingPresentationFrames = 0;
    impl_->async->nextSubmissionSequence = 0;
    impl_->async->nextCompletionSequence = 0;
    impl_->async->completedDecodes.clear();
    impl_->async->pendingPresentationFrames.clear();
    impl_->async->expectedOutputPixelFormat = impl_->outputPixelFormat;
    impl_->async->actualOutputPixelFormat = 0;
    impl_->async->lastDeliveredPresentationTime = kCMTimeInvalid;
    impl_->async->lastError.reset();
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
    if (impl_->ended) {
      assignError(error, "end of stream was already submitted");
      return VideoDecodeSubmitResult::Rejected;
    }
    OSStatus finishStatus = noErr;
    OSStatus waitStatus = noErr;
    if (impl_->session != nullptr) {
      // Temporal processing is intentionally disabled for bounded pre-EOS
      // liveness. FinishDelayedFrames remains required by the VideoToolbox
      // lifecycle and safely releases any codec-internal tail state.
      finishStatus = VTDecompressionSessionFinishDelayedFrames(impl_->session);
      waitStatus =
          VTDecompressionSessionWaitForAsynchronousFrames(impl_->session);
    }
    drainAllPresentationFrames(impl_->async);
    impl_->ended = true;
    DecodedFrameSink *sink = nullptr;
    {
      std::lock_guard stateLock(impl_->async->mutex);
      sink = impl_->async->sink;
    }
    if (sink != nullptr) {
      sink->endOfStream(generation);
    }
    if (finishStatus != noErr) {
      assignError(error,
                  statusError("VTDecompressionSessionFinishDelayedFrames",
                              finishStatus));
      return VideoDecodeSubmitResult::Rejected;
    }
    if (waitStatus != noErr) {
      assignError(error,
                  statusError("VTDecompressionSessionWaitForAsynchronousFrames",
                              waitStatus));
      return VideoDecodeSubmitResult::Rejected;
    }
    if (auto asyncError = impl_->takeAsyncErrorLocked()) {
      assignError(error, std::move(*asyncError));
      return VideoDecodeSubmitResult::Rejected;
    }
    return VideoDecodeSubmitResult::Accepted;
  }

  if (impl_->ended) {
    assignError(error, "cannot submit compressed data after end of stream");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (packet.bytes.empty()) {
    assignError(error, "compressed video packet is empty");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (packet.bytes.size() > kMaximumCompressedPacketBytes) {
    assignError(error,
                "compressed video packet exceeds the 32 MiB decoder memory "
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
  {
    std::lock_guard stateLock(impl_->async->mutex);
    if (impl_->async->inFlight >= impl_->options.maxInFlightFrames) {
      ++impl_->async->backpressuredSubmissions;
      return VideoDecodeSubmitResult::Backpressure;
    }
    ++impl_->async->inFlight;
  }

  CMSampleBufferRef sample = nullptr;
  const OSStatus sampleStatus =
      createCompressedSampleBuffer(impl_->formatDescription, packet, &sample);
  if (sampleStatus != noErr || sample == nullptr) {
    finishCallbacks(impl_->async);
    assignError(error, statusError("CMSampleBufferCreateReady", sampleStatus));
    return VideoDecodeSubmitResult::Rejected;
  }

  const FrameTiming timing{packet.presentationTime, packet.duration,
                           packet.generation, packet.keyFrame};
  const std::shared_ptr<AsyncDecodeState> callbackState = impl_->async;
  std::uint64_t submissionSequence = 0;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    submissionSequence = impl_->async->nextSubmissionSequence++;
  }
  VTDecodeInfoFlags infoFlags = 0;
#if defined(WAM_NATIVE_VIDEO_TESTING)
  const VTDecodeFrameFlags decodeFlags = finiteAdmissionDecodeFlags(
      impl_->options.enableAsynchronousDecompression);
#else
  constexpr VTDecodeFrameFlags decodeFlags = kProductionDecodeFrameFlags;
#endif
  const OSStatus decodeStatus =
      VTDecompressionSessionDecodeFrameWithOutputHandler(
          impl_->session, sample, decodeFlags, &infoFlags,
          ^(OSStatus status, VTDecodeInfoFlags callbackFlags,
            CVImageBufferRef imageBuffer, CMTime presentationTime,
            CMTime presentationDuration) {
            deliverDecodedFrame(callbackState, submissionSequence, timing,
                                status, callbackFlags, imageBuffer,
                                presentationTime, presentationDuration);
          });
  CFRelease(sample);
  if (decodeStatus != noErr) {
    // Retire the assigned sequence through the same ordering gate. Otherwise a
    // recoverable caller could leave every later callback waiting behind a
    // sequence that VideoToolbox never accepted.
    deliverDecodedFrame(callbackState, submissionSequence, timing,
                        decodeStatus, 0, nullptr, kCMTimeInvalid,
                        kCMTimeInvalid);
    assignError(error,
                statusError("VTDecompressionSessionDecodeFrame", decodeStatus));
    return VideoDecodeSubmitResult::Rejected;
  }
  {
    std::lock_guard stateLock(impl_->async->mutex);
    ++impl_->async->submitted;
  }
  impl_->awaitingKeyFrame = false;
  return VideoDecodeSubmitResult::Accepted;
}

void VideoToolboxDecoder::flush(std::uint64_t nextGeneration) noexcept {
  std::lock_guard operationLock(impl_->operationMutex);
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
  impl_->ended = false;
  impl_->awaitingKeyFrame = true;
}

void VideoToolboxDecoder::close() noexcept {
  if (!impl_) {
    return;
  }
  std::lock_guard operationLock(impl_->operationMutex);
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
  impl_->ended = false;
  impl_->awaitingKeyFrame = true;
  impl_->usingHardware = false;
}

VideoToolboxDecoderStats VideoToolboxDecoder::stats() const noexcept {
  std::lock_guard operationLock(impl_->operationMutex);
  VideoToolboxDecoderStats result;
  result.configured = impl_->configured;
  result.usingHardwareAcceleratedDecoder = impl_->usingHardware;
  result.awaitingKeyFrame = impl_->awaitingKeyFrame;
  result.maxInFlightFrames = impl_->options.maxInFlightFrames;
  {
    std::lock_guard stateLock(impl_->async->mutex);
    result.inFlightFrames = impl_->async->inFlight;
    result.codecReorderFrames = impl_->async->codecReorderFrames;
    result.generation = impl_->async->generation;
    result.submittedFrames = impl_->async->submitted;
    result.deliveredFrames = impl_->async->delivered;
    result.droppedFrames = impl_->async->dropped;
    result.backpressuredSubmissions = impl_->async->backpressuredSubmissions;
    result.sinkBackpressureDrops = impl_->async->sinkBackpressureDrops;
    result.outOfOrderDrops = impl_->async->outOfOrderDrops;
    result.pendingPresentationFrames =
        impl_->async->pendingPresentationFrames.size();
    result.peakPendingPresentationFrames =
        impl_->async->peakPendingPresentationFrames;
    result.requestedOutputPixelFormat = impl_->outputPixelFormat;
    result.actualOutputPixelFormat = impl_->async->actualOutputPixelFormat;
  }
  return result;
}

std::optional<std::string> VideoToolboxDecoder::takeLastError() {
  return impl_->takeAsyncErrorLocked();
}

#if defined(WAM_NATIVE_VIDEO_TESTING)
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
  return deriveCodecReorderFrameCount(configuration);
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
  decoder.impl_->async->codecReorderFrames = reorderFrames;
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
  return true;
}

bool VideoToolboxDecoderTestAccess::injectDecodedFrame(
    VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
    CVPixelBufferRef pixelBuffer, FrameTiming timing, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  {
    std::lock_guard operationLock(decoder.impl_->operationMutex);
    std::lock_guard stateLock(decoder.impl_->async->mutex);
    if (!decoder.impl_->configured) {
      assignError(error, "test decoder is not configured");
      return false;
    }
    if (pixelBuffer == nullptr) {
      assignError(error, "test decoded frame has no pixel buffer");
      return false;
    }
    decoder.impl_->async->nextSubmissionSequence =
        std::max(decoder.impl_->async->nextSubmissionSequence,
                 submissionSequence + 1);
  }
  deliverDecodedFrame(decoder.impl_->async, submissionSequence, timing, noErr,
                      0, pixelBuffer, timing.presentationTime,
                      timing.duration);
  return true;
}

void VideoToolboxDecoderTestAccess::drainPresentationFrames(
    VideoToolboxDecoder &decoder) noexcept {
  drainAllPresentationFrames(decoder.impl_->async);
}
#endif

} // namespace wam::macos
