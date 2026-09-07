#pragma once
#include "media/native_media_source.hpp"
#include <cstdint>
#include <limits>
#include <numeric>
#include <optional>

namespace wam::media {
// The reduced product is bounded before narrowing; unknown stamps remain unknown.
[[nodiscard]] constexpr std::optional<MediaTime> avcodecExactTime(
    std::int64_t pts, std::int32_t numerator, std::int32_t denominator) noexcept {
  if (pts == std::numeric_limits<std::int64_t>::min() || numerator <= 0 || denominator <= 0)
    return std::nullopt;
  const auto divisor = std::gcd(numerator, denominator);
  numerator /= divisor;
  denominator /= divisor;
  const auto magnitude = pts < 0 ? std::uint64_t(-(pts + 1)) + 1U : std::uint64_t(pts);
  const auto reduction = std::gcd(magnitude, std::uint64_t(denominator));
  const auto value = __int128(pts / static_cast<std::int64_t>(reduction)) * numerator;
  if (value < std::numeric_limits<std::int64_t>::min() ||
      value > std::numeric_limits<std::int64_t>::max()) return std::nullopt;
  return MediaTime{static_cast<std::int64_t>(value),
                   denominator / static_cast<std::int32_t>(reduction)};
}
}
