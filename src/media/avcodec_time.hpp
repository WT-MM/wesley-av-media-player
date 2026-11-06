#pragma once
#include "media/native_media_source.hpp"
#include <cstdint>
#include <limits>
#include <optional>

namespace wam::media {
// INT64_MIN is AV_NOPTS_VALUE: unknown stamps remain unknown.
[[nodiscard]] constexpr std::optional<MediaTime> avcodecExactTime(
    std::int64_t pts, std::int32_t numerator, std::int32_t denominator) noexcept {
  if (pts == std::numeric_limits<std::int64_t>::min() || numerator <= 0 || denominator <= 0)
    return std::nullopt;
  return mediaTimeFromTicks(static_cast<__int128_t>(pts) * numerator,
                            static_cast<std::uint32_t>(denominator));
}
}
