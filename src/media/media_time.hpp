#pragma once

#include <cstdint>
#include <limits>
#include <numeric>
#include <optional>

// The one home of exact rational media time. Nothing here rounds through
// floating point: adjacent ticks at a nanosecond timescale are already above
// 2^53. Out-of-line definitions live in native_media_source.cpp.
namespace wam::media {

// Container timestamps remain exact across demux backends. A zero timescale
// denotes an invalid/unknown timestamp; negative values are valid (for
// example, edit-list and preroll timestamps).
struct MediaTime {
  std::int64_t value{0};
  std::int32_t timescale{0};

  [[nodiscard]] constexpr bool valid() const noexcept {
    return timescale > 0;
  }

  friend constexpr bool operator==(const MediaTime&, const MediaTime&) =
      default;
};

// Returns the canonical MediaTime representation of a finite, nonnegative
// binary64 value when that exact rational fits the MediaTime domain. The
// conversion decodes the binary64 representation directly: it never rounds
// through floating-point arithmetic. Both signed zero encodings normalize to
// {0, 1}; negative nonzero values and unrepresentable rationals fail closed.
[[nodiscard]] std::optional<MediaTime>
exactNonnegativeMediaTime(double seconds) noexcept;

enum class MediaTimeOrder : std::int8_t {
  Less = -1,
  Equal = 0,
  Greater = 1,
};

[[nodiscard]] std::optional<double> mediaTimeSeconds(MediaTime time) noexcept;
// Canonical checked conversion for an exact media origin plus an unsigned
// audio-frame offset. The intermediate rational never rounds through double;
// all callers receive the same final binary64 result for clock publication
// and validation. Negative resulting positions and non-finite results are
// rejected because the native media clock admits only nonnegative time.
[[nodiscard]] std::optional<double> mediaTimeSecondsAtFrame(
    MediaTime origin, std::uint64_t frame,
    std::uint32_t sampleRate) noexcept;
// Returns the signed PCM-frame ordinal only when time lies exactly on the
// sample-rate grid. The multiplication and division are checked without
// converting through floating point.
[[nodiscard]] std::optional<std::int64_t> exactAudioFrameIndex(
    MediaTime time, std::uint32_t sampleRate) noexcept;
// Returns the canonical timestamp of the first PCM-frame boundary at or after
// time. Signed inputs use mathematical ceiling (toward positive infinity).
[[nodiscard]] std::optional<MediaTime> audioFrameAtOrAfter(
    MediaTime time, std::uint32_t sampleRate) noexcept;
// Exact ordering for timestamps from different time bases. Implementations
// must not round through double: adjacent media ticks can be above 2^53.
[[nodiscard]] std::optional<MediaTimeOrder>
compareMediaTime(MediaTime lhs, MediaTime rhs) noexcept;

// Reduces ticks/timescale to the canonical MediaTime. Empty for a zero
// timescale or when the reduced rational does not fit MediaTime.
[[nodiscard]] constexpr std::optional<MediaTime> mediaTimeFromTicks(
    __int128_t ticks, __uint128_t timescale) noexcept {
  using Wide = __uint128_t;
  if (timescale == 0) {
    return std::nullopt;
  }
  const bool negative = ticks < 0;
  const Wide magnitude = negative ? static_cast<Wide>(-(ticks + 1)) + 1
                                  : static_cast<Wide>(ticks);
  Wide divisor = 0;
  if (((magnitude | timescale) >> 64U) == 0) {
    divisor = std::gcd(static_cast<std::uint64_t>(magnitude),
                       static_cast<std::uint64_t>(timescale));
  } else {
    Wide left = magnitude;
    Wide right = timescale;
    while (right != 0) {
      const Wide remainder = left % right;
      left = right;
      right = remainder;
    }
    divisor = left;
  }
  const Wide numerator = magnitude / divisor;
  const Wide denominator = timescale / divisor;
  constexpr Wide kMaximumValue = std::numeric_limits<std::int64_t>::max();
  if (denominator > static_cast<Wide>(std::numeric_limits<std::int32_t>::max()) ||
      numerator > kMaximumValue + (negative ? 1U : 0U)) {
    return std::nullopt;
  }
  const std::int64_t value =
      negative ? static_cast<std::int64_t>(-static_cast<__int128_t>(numerator))
               : static_cast<std::int64_t>(numerator);
  return MediaTime{value, static_cast<std::int32_t>(denominator)};
}

// Exact lhs + rhs, reduced; empty when either is invalid or the result does
// not fit MediaTime.
[[nodiscard]] constexpr std::optional<MediaTime> addMediaTime(
    MediaTime lhs, MediaTime rhs) noexcept {
  if (!lhs.valid() || !rhs.valid()) {
    return std::nullopt;
  }
  return mediaTimeFromTicks(
      static_cast<__int128_t>(lhs.value) * rhs.timescale +
          static_cast<__int128_t>(rhs.value) * lhs.timescale,
      static_cast<__uint128_t>(lhs.timescale) *
          static_cast<std::uint32_t>(rhs.timescale));
}

// Exact lhs - rhs, reduced; empty when either is invalid or the result does
// not fit MediaTime.
[[nodiscard]] constexpr std::optional<MediaTime> subtractMediaTime(
    MediaTime lhs, MediaTime rhs) noexcept {
  if (!lhs.valid() || !rhs.valid()) {
    return std::nullopt;
  }
  return mediaTimeFromTicks(
      static_cast<__int128_t>(lhs.value) * rhs.timescale -
          static_cast<__int128_t>(rhs.value) * lhs.timescale,
      static_cast<__uint128_t>(lhs.timescale) *
          static_cast<std::uint32_t>(rhs.timescale));
}

}  // namespace wam::media
