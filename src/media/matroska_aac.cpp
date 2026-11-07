#include "media/matroska_aac.hpp"

#include <algorithm>
#include <limits>

namespace wam::media::matroska {
namespace {

constexpr std::uint64_t kNanosecondsPerSecond{1'000'000'000ULL};

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

std::optional<MediaTime>
audioPacketGridTime(AacFrameGridPosition position) noexcept {
  if (!position.origin.valid() || position.sampleRate == 0 ||
      position.sampleRate > MediaSourceLimits::kHardMaximumAudioSampleRate ||
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
  // The ordinal product is below 2^127 by more than 2^95; the origin
  // term is below 2^82 at the source sample-rate ceiling.
  const WideSigned numerator =
      originNumerator + static_cast<WideSigned>(ordinalNumerator);
  const WideUnsigned denominator =
      static_cast<WideUnsigned>(
          static_cast<std::uint32_t>(position.origin.timescale)) *
      static_cast<WideUnsigned>(position.sampleRate);
  return mediaTimeFromTicks(numerator, denominator);
}

std::optional<std::int64_t>
nearestMatroskaTick(AacFrameGridPosition position,
                    std::uint64_t timestampScaleNanoseconds) noexcept {
  if (timestampScaleNanoseconds == 0U) {
    return std::nullopt;
  }
  const auto exactTime = audioPacketGridTime(position);
  if (!exactTime) {
    return std::nullopt;
  }

  const WideSigned numerator = static_cast<WideSigned>(exactTime->value) *
                               static_cast<WideSigned>(kNanosecondsPerSecond);
  const WideUnsigned denominator =
      static_cast<WideUnsigned>(
          static_cast<std::uint32_t>(exactTime->timescale)) *
      static_cast<WideUnsigned>(timestampScaleNanoseconds);
  const auto rounded = roundTiesToEven(numerator, denominator);
  if (!rounded) {
    return std::nullopt;
  }
  const WideUnsigned roundedMagnitude = rounded->magnitude;
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

std::optional<AacTickGridProjection> nearestAudioPacketForMatroskaTick(
    std::int64_t observedTick, MediaTime origin, std::uint32_t sampleRate,
    std::uint64_t timestampScaleNanoseconds,
    std::uint32_t samplesPerAccessUnitValue) noexcept {
  if (!origin.valid() || sampleRate == 0 ||
      sampleRate > MediaSourceLimits::kHardMaximumAudioSampleRate ||
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

  // ordinal = elapsedSeconds * sampleRate / samplesPerAccessUnit. Cross-cancel
  // before the checked products so the one ties-to-even division sees the
  // exact ratio.
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
  const auto exactPresentationTime = audioPacketGridTime(grid);
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
