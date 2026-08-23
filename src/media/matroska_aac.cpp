#include "media/matroska_aac.hpp"

#include <algorithm>
#include <limits>

namespace wam::media::matroska {
namespace {

constexpr std::uint32_t kAacLcAudioObjectType{2};
constexpr std::uint32_t kSbrAudioObjectType{5};
constexpr std::uint32_t kSyncExtensionType{0x2B7};
constexpr std::uint32_t kSamplingFrequencyIndex48000{3};
constexpr std::uint32_t kSamplingFrequencyIndex44100{4};
constexpr std::uint64_t kNanosecondsPerSecond{1'000'000'000ULL};

class BitReader final {
public:
  explicit BitReader(std::span<const std::byte> bytes) noexcept
      : bytes_(bytes) {}

  [[nodiscard]] bool read(std::size_t count, std::uint32_t *value) noexcept {
    if (value == nullptr || count > 32 || count > remaining()) {
      return false;
    }
    std::uint32_t result = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const std::size_t byteIndex = bitOffset_ / 8U;
      const std::size_t bitInByte = 7U - (bitOffset_ % 8U);
      const auto byte = std::to_integer<std::uint8_t>(bytes_[byteIndex]);
      result = static_cast<std::uint32_t>((result << 1U) |
                                          ((byte >> bitInByte) & 1U));
      ++bitOffset_;
    }
    *value = result;
    return true;
  }

  [[nodiscard]] std::size_t remaining() const noexcept {
    return bytes_.size() * 8U - bitOffset_;
  }

private:
  std::span<const std::byte> bytes_;
  std::size_t bitOffset_{0};
};

[[nodiscard]] AacLcAdmission rejected(AacLcAdmissionError error) noexcept {
  return {error, std::nullopt};
}

[[nodiscard]] bool supportedSampleRate(std::uint32_t sampleRate) noexcept {
  return sampleRate == 44'100U || sampleRate == 48'000U;
}

using WideSigned = __int128_t;
using WideUnsigned = __uint128_t;

constexpr WideUnsigned kWideSignedNegativeLimit = static_cast<WideUnsigned>(1U)
                                                  << 127U;
constexpr WideUnsigned kWideSignedPositiveLimit =
    kWideSignedNegativeLimit - static_cast<WideUnsigned>(1U);
constexpr WideUnsigned kWideUnsignedLimit = ~static_cast<WideUnsigned>(0U);

[[nodiscard]] constexpr WideUnsigned
unsignedMagnitude(WideSigned value) noexcept {
  if (value >= 0) {
    return static_cast<WideUnsigned>(value);
  }
  return static_cast<WideUnsigned>(-(value + 1)) + 1U;
}

[[nodiscard]] constexpr WideUnsigned wideGcd(WideUnsigned left,
                                             WideUnsigned right) noexcept {
  while (right != 0) {
    const WideUnsigned remainder = left % right;
    left = right;
    right = remainder;
  }
  return left;
}

[[nodiscard]] bool signedFromMagnitude(WideUnsigned magnitude, bool negative,
                                       WideSigned *result) noexcept {
  if (result == nullptr) {
    return false;
  }
  const WideUnsigned limit =
      negative ? kWideSignedNegativeLimit : kWideSignedPositiveLimit;
  if (magnitude > limit) {
    return false;
  }
  if (!negative) {
    *result = static_cast<WideSigned>(magnitude);
  } else if (magnitude == kWideSignedNegativeLimit) {
    *result = -static_cast<WideSigned>(magnitude - 1U) - 1;
  } else {
    *result = -static_cast<WideSigned>(magnitude);
  }
  return true;
}

[[nodiscard]] bool checkedMultiply(WideSigned value, WideUnsigned factor,
                                   WideSigned *result) noexcept {
  const bool negative = value < 0;
  const WideUnsigned magnitude = unsignedMagnitude(value);
  const WideUnsigned limit =
      negative ? kWideSignedNegativeLimit : kWideSignedPositiveLimit;
  if (factor != 0U && magnitude > limit / factor) {
    return false;
  }
  return signedFromMagnitude(magnitude * factor, negative, result);
}

[[nodiscard]] bool checkedMultiply(WideUnsigned left, WideUnsigned right,
                                   WideUnsigned *result) noexcept {
  if (result == nullptr || (right != 0U && left > kWideUnsignedLimit / right)) {
    return false;
  }
  *result = left * right;
  return true;
}

[[nodiscard]] bool checkedSubtract(WideSigned left, WideSigned right,
                                   WideSigned *result) noexcept {
  if (result == nullptr) {
    return false;
  }
  const WideSigned minimum =
      -static_cast<WideSigned>(kWideSignedNegativeLimit - 1U) - 1;
  const WideSigned maximum = static_cast<WideSigned>(kWideSignedPositiveLimit);
  if ((right > 0 && left < minimum + right) ||
      (right < 0 && left > maximum + right)) {
    return false;
  }
  *result = left - right;
  return true;
}

void reduceRational(WideSigned *numerator, WideUnsigned *denominator) noexcept {
  if (numerator == nullptr || denominator == nullptr || *denominator == 0U) {
    return;
  }
  const WideUnsigned divisor =
      wideGcd(unsignedMagnitude(*numerator), *denominator);
  if (divisor > 1U) {
    *numerator /= static_cast<WideSigned>(divisor);
    *denominator /= divisor;
  }
}

struct RoundedSignedInteger {
  WideUnsigned magnitude{0};
  bool negative{false};
};

[[nodiscard]] std::optional<RoundedSignedInteger>
roundTiesToEven(WideSigned numerator, WideUnsigned denominator) noexcept {
  if (denominator == 0U) {
    return std::nullopt;
  }
  const WideUnsigned magnitude = unsignedMagnitude(numerator);
  WideUnsigned quotient = magnitude / denominator;
  const WideUnsigned remainder = magnitude % denominator;
  const WideUnsigned halfDenominator = denominator / 2U;
  const bool exactHalf =
      (denominator & 1U) == 0U && remainder == halfDenominator;
  if (remainder > halfDenominator ||
      (exactHalf && (quotient & static_cast<WideUnsigned>(1U)) != 0U)) {
    ++quotient;
  }
  return RoundedSignedInteger{quotient, numerator < 0 && quotient != 0U};
}

} // namespace

AacLcAdmission
parseAacLcAudioSpecificConfig(std::span<const std::byte> bytes) noexcept {
  if (bytes.size() != 2U && bytes.size() != 5U) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }

  BitReader reader(bytes);
  std::uint32_t value = 0;
  if (!reader.read(5, &value) || value != kAacLcAudioObjectType) {
    return rejected(AacLcAdmissionError::UnsupportedAudioObjectType);
  }

  if (!reader.read(4, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value == 15U) {
    return rejected(AacLcAdmissionError::ExplicitSamplingFrequency);
  }
  std::uint32_t sampleRate = 0;
  if (value == kSamplingFrequencyIndex48000) {
    sampleRate = 48'000U;
  } else if (value == kSamplingFrequencyIndex44100) {
    sampleRate = 44'100U;
  } else {
    return rejected(AacLcAdmissionError::UnsupportedSamplingFrequency);
  }

  if (!reader.read(4, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value == 0U) {
    return rejected(AacLcAdmissionError::ProgramConfigElement);
  }
  // ISO/IEC 14496-3 Table 1.19: channelConfiguration 1..6 name 1, 2, 3, 4, 5
  // and 6 channels respectively, so the index IS the count over that range.
  // Configuration 7 is the only other defined value and it means EIGHT
  // channels in the front-wide 3/4.1 arrangement whose two extra channels are
  // front-left-of-centre and front-right-of-centre. Those two labels have no
  // measured downmix coefficient in this player, so 7 is a named deferral
  // rather than an admission with a guessed matrix -- and it is not the
  // arrangement movie 7.1 uses in any case (that needs a program config
  // element, which is refused above).
  if (value > 6U) {
    return rejected(AacLcAdmissionError::UnsupportedChannelConfiguration);
  }
  const auto channelCount = static_cast<std::uint8_t>(value);

  if (!reader.read(1, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value != 0U) {
    return rejected(AacLcAdmissionError::UnsupportedFrameLength);
  }
  if (!reader.read(1, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value != 0U) {
    return rejected(AacLcAdmissionError::CoreCoderDependency);
  }
  if (!reader.read(1, &value)) {
    return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
  }
  if (value != 0U) {
    return rejected(AacLcAdmissionError::UnsupportedExtensionFlag);
  }

  const bool hasSyncExtension = bytes.size() == 5U;
  if (hasSyncExtension) {
    if (!reader.read(11, &value) || value != kSyncExtensionType) {
      return rejected(AacLcAdmissionError::InvalidSyncExtension);
    }
    if (!reader.read(5, &value) || value != kSbrAudioObjectType) {
      return rejected(AacLcAdmissionError::UnsupportedExtensionAudioObjectType);
    }
    if (!reader.read(1, &value)) {
      return rejected(AacLcAdmissionError::InvalidAudioSpecificConfigSize);
    }
    if (value != 0U) {
      return rejected(AacLcAdmissionError::SbrPresent);
    }
    if (!reader.read(reader.remaining(), &value) || value != 0U) {
      return rejected(AacLcAdmissionError::NonzeroTrailingBits);
    }
  }

  if (reader.remaining() != 0U) {
    return rejected(AacLcAdmissionError::NonzeroTrailingBits);
  }

  AacLcConfiguration configuration;
  std::copy(bytes.begin(), bytes.end(),
            configuration.audioSpecificConfig.begin());
  configuration.audioSpecificConfigSize =
      static_cast<std::uint8_t>(bytes.size());
  configuration.sampleRate = sampleRate;
  configuration.channelCount = channelCount;
  configuration.ffmpegSyncExtensionPresent = hasSyncExtension;
  return {AacLcAdmissionError::None, configuration};
}

std::optional<AacLcEsDescriptorCookie>
buildAacLcEsDescriptorCookie(const AacLcConfiguration &configuration) noexcept {
  const std::size_t configSize = configuration.audioSpecificConfigSize;
  if (configSize > configuration.audioSpecificConfig.size()) {
    return std::nullopt;
  }
  const auto reparsed = parseAacLcAudioSpecificConfig(
      {configuration.audioSpecificConfig.data(), configSize});
  if (!reparsed.admitted() || *reparsed.configuration != configuration) {
    return std::nullopt;
  }

  AacLcEsDescriptorCookie cookie;
  std::size_t offset = 0;
  const auto append = [&cookie, &offset](std::uint8_t value) noexcept {
    if (offset >= cookie.bytes.size()) {
      return false;
    }
    cookie.bytes[offset++] = static_cast<std::byte>(value);
    return true;
  };
  const auto appendExpandableLength = [&append](std::uint32_t value) noexcept {
    if (value > 0x0FFF'FFFFU) {
      return false;
    }
    return append(
               static_cast<std::uint8_t>(0x80U | ((value >> 21U) & 0x7FU))) &&
           append(
               static_cast<std::uint8_t>(0x80U | ((value >> 14U) & 0x7FU))) &&
           append(static_cast<std::uint8_t>(0x80U | ((value >> 7U) & 0x7FU))) &&
           append(static_cast<std::uint8_t>(value & 0x7FU));
  };

  const auto descriptorBytes = static_cast<std::uint32_t>(configSize);
  if (!append(0x03U) || !appendExpandableLength(32U + descriptorBytes) ||
      !append(0x00U) || !append(0x01U) || !append(0x00U) || !append(0x04U) ||
      !appendExpandableLength(18U + descriptorBytes) || !append(0x40U) ||
      !append(0x15U) || !append(0x00U) || !append(0x00U) || !append(0x00U) ||
      !append(0x00U) || !append(0x00U) || !append(0x00U) || !append(0x00U) ||
      !append(0x00U) || !append(0x00U) || !append(0x00U) || !append(0x00U) ||
      !append(0x05U) || !appendExpandableLength(descriptorBytes)) {
    return std::nullopt;
  }
  for (std::size_t index = 0; index < configSize; ++index) {
    if (!append(std::to_integer<std::uint8_t>(
            configuration.audioSpecificConfig[index]))) {
      return std::nullopt;
    }
  }
  if (!append(0x06U) || !appendExpandableLength(1U) || !append(0x02U)) {
    return std::nullopt;
  }

  const std::size_t expectedSize = 37U + configSize;
  if (offset != expectedSize || offset > cookie.bytes.size() ||
      offset > std::numeric_limits<std::uint8_t>::max()) {
    return std::nullopt;
  }
  cookie.size = static_cast<std::uint8_t>(offset);
  return cookie;
}

std::optional<MediaTime>
aacAccessUnitGridTime(AacFrameGridPosition position) noexcept {
  if (!position.origin.valid() || !supportedSampleRate(position.sampleRate) ||
      position.samplesPerAccessUnit == 0U) {
    return std::nullopt;
  }

  const WideSigned originNumerator =
      static_cast<WideSigned>(position.origin.value) *
      static_cast<WideSigned>(position.sampleRate);
  const WideUnsigned ordinalNumerator =
      static_cast<WideUnsigned>(position.accessUnitOrdinal) *
      static_cast<WideUnsigned>(position.samplesPerAccessUnit) *
      static_cast<WideUnsigned>(
          static_cast<std::uint32_t>(position.origin.timescale));
  // The largest supported operands require at most 106 signed bits.
  const WideSigned numerator =
      originNumerator + static_cast<WideSigned>(ordinalNumerator);
  const WideUnsigned denominator =
      static_cast<WideUnsigned>(
          static_cast<std::uint32_t>(position.origin.timescale)) *
      static_cast<WideUnsigned>(position.sampleRate);
  const WideUnsigned divisor =
      wideGcd(unsignedMagnitude(numerator), denominator);
  if (divisor == 0U) {
    return std::nullopt;
  }

  const WideSigned reducedNumerator =
      numerator / static_cast<WideSigned>(divisor);
  const WideUnsigned reducedDenominator = denominator / divisor;
  if (reducedNumerator <
          static_cast<WideSigned>(std::numeric_limits<std::int64_t>::min()) ||
      reducedNumerator >
          static_cast<WideSigned>(std::numeric_limits<std::int64_t>::max()) ||
      reducedDenominator >
          static_cast<WideUnsigned>(std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }

  return MediaTime{static_cast<std::int64_t>(reducedNumerator),
                   static_cast<std::int32_t>(reducedDenominator)};
}

std::optional<std::int64_t>
nearestMatroskaTick(AacFrameGridPosition position,
                    std::uint64_t timestampScaleNanoseconds) noexcept {
  if (timestampScaleNanoseconds == 0U) {
    return std::nullopt;
  }
  const auto exactTime = aacAccessUnitGridTime(position);
  if (!exactTime) {
    return std::nullopt;
  }

  const WideSigned numerator = static_cast<WideSigned>(exactTime->value) *
                               static_cast<WideSigned>(kNanosecondsPerSecond);
  const WideUnsigned denominator =
      static_cast<WideUnsigned>(
          static_cast<std::uint32_t>(exactTime->timescale)) *
      static_cast<WideUnsigned>(timestampScaleNanoseconds);
  const WideUnsigned magnitude = unsignedMagnitude(numerator);
  WideUnsigned roundedMagnitude = magnitude / denominator;
  const WideUnsigned remainder = magnitude % denominator;
  const WideUnsigned halfDenominator = denominator / 2U;
  const bool exactHalf =
      (denominator & 1U) == 0U && remainder == halfDenominator;
  if (remainder > halfDenominator ||
      (exactHalf && (roundedMagnitude & static_cast<WideUnsigned>(1U)) != 0U)) {
    ++roundedMagnitude;
  }

  if (numerator >= 0) {
    if (roundedMagnitude >
        static_cast<WideUnsigned>(std::numeric_limits<std::int64_t>::max())) {
      return std::nullopt;
    }
    return static_cast<std::int64_t>(roundedMagnitude);
  }

  const WideUnsigned negativeLimit = static_cast<WideUnsigned>(1U) << 63U;
  if (roundedMagnitude > negativeLimit) {
    return std::nullopt;
  }
  if (roundedMagnitude == negativeLimit) {
    return std::numeric_limits<std::int64_t>::min();
  }
  return -static_cast<std::int64_t>(roundedMagnitude);
}

bool matroskaTickMatchesAacAccessUnit(
    std::int64_t observedTick, AacFrameGridPosition position,
    std::uint64_t timestampScaleNanoseconds) noexcept {
  const auto expected =
      nearestMatroskaTick(position, timestampScaleNanoseconds);
  return expected.has_value() && *expected == observedTick;
}

std::optional<AacTickGridProjection> nearestAacAccessUnitForMatroskaTick(
    std::int64_t observedTick, MediaTime origin, std::uint32_t sampleRate,
    std::uint64_t timestampScaleNanoseconds,
    std::uint32_t samplesPerAccessUnitValue) noexcept {
  if (!origin.valid() || !supportedSampleRate(sampleRate) ||
      timestampScaleNanoseconds == 0U || samplesPerAccessUnitValue == 0U) {
    return std::nullopt;
  }

  // Form observedTick * scale / 1e9 and origin.value / origin.timescale as
  // reduced rationals before finding their difference. Reducing first keeps
  // ordinary long streams far below the 128-bit ceiling; oversized adversarial
  // coordinates fail at the checked cross-products instead of wrapping.
  WideSigned observedNumerator = 0;
  if (!checkedMultiply(static_cast<WideSigned>(observedTick),
                       static_cast<WideUnsigned>(timestampScaleNanoseconds),
                       &observedNumerator)) {
    return std::nullopt;
  }
  WideUnsigned observedDenominator = kNanosecondsPerSecond;
  reduceRational(&observedNumerator, &observedDenominator);

  WideSigned originNumerator = static_cast<WideSigned>(origin.value);
  WideUnsigned originDenominator =
      static_cast<WideUnsigned>(static_cast<std::uint32_t>(origin.timescale));
  reduceRational(&originNumerator, &originDenominator);

  const WideUnsigned denominatorGcd =
      wideGcd(observedDenominator, originDenominator);
  const WideUnsigned observedFactor = originDenominator / denominatorGcd;
  const WideUnsigned originFactor = observedDenominator / denominatorGcd;
  WideSigned observedTerm = 0;
  WideSigned originTerm = 0;
  WideSigned elapsedNumerator = 0;
  WideUnsigned elapsedDenominator = 0;
  if (!checkedMultiply(observedNumerator, observedFactor, &observedTerm) ||
      !checkedMultiply(originNumerator, originFactor, &originTerm) ||
      !checkedSubtract(observedTerm, originTerm, &elapsedNumerator) ||
      !checkedMultiply(observedDenominator, observedFactor,
                       &elapsedDenominator)) {
    return std::nullopt;
  }
  reduceRational(&elapsedNumerator, &elapsedDenominator);

  // ordinal = elapsedSeconds * sampleRate / 1024. Cross-cancel before the
  // checked products so the one ties-to-even division sees the exact ratio.
  WideUnsigned samplesPerAccessUnit = samplesPerAccessUnitValue;
  WideUnsigned rate = sampleRate;
  const WideUnsigned numeratorCancellation =
      wideGcd(unsignedMagnitude(elapsedNumerator), samplesPerAccessUnit);
  if (numeratorCancellation > 1U) {
    elapsedNumerator /= static_cast<WideSigned>(numeratorCancellation);
    samplesPerAccessUnit /= numeratorCancellation;
  }
  const WideUnsigned denominatorCancellation =
      wideGcd(elapsedDenominator, rate);
  elapsedDenominator /= denominatorCancellation;
  rate /= denominatorCancellation;

  WideSigned ordinalNumerator = 0;
  WideUnsigned ordinalDenominator = 0;
  if (!checkedMultiply(elapsedNumerator, rate, &ordinalNumerator) ||
      !checkedMultiply(elapsedDenominator, samplesPerAccessUnit,
                       &ordinalDenominator)) {
    return std::nullopt;
  }
  const auto roundedOrdinal =
      roundTiesToEven(ordinalNumerator, ordinalDenominator);
  if (!roundedOrdinal || roundedOrdinal->negative ||
      roundedOrdinal->magnitude >
          static_cast<WideUnsigned>(
              std::numeric_limits<std::uint64_t>::max())) {
    return std::nullopt;
  }

  const auto ordinal = static_cast<std::uint64_t>(roundedOrdinal->magnitude);
  const AacFrameGridPosition grid{origin, ordinal, sampleRate,
                                  samplesPerAccessUnitValue};
  const auto exactPresentationTime = aacAccessUnitGridTime(grid);
  const auto quantizedGridTick =
      nearestMatroskaTick(grid, timestampScaleNanoseconds);
  if (!exactPresentationTime || !quantizedGridTick) {
    return std::nullopt;
  }
  const WideSigned residual = static_cast<WideSigned>(observedTick) -
                              static_cast<WideSigned>(*quantizedGridTick);
  if (residual <
          static_cast<WideSigned>(std::numeric_limits<std::int64_t>::min()) ||
      residual >
          static_cast<WideSigned>(std::numeric_limits<std::int64_t>::max())) {
    return std::nullopt;
  }

  const auto signedResidual = static_cast<std::int64_t>(residual);
  return AacTickGridProjection{ordinal, *exactPresentationTime,
                               *quantizedGridTick, signedResidual,
                               signedResidual == 0};
}

} // namespace wam::media::matroska
