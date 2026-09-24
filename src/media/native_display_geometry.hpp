#pragma once

#include "media/native_media_source.hpp"

#include <limits>
#include <numeric>

namespace wam::media {

// Read-only retained geometry used by host diagnostics after final projection.
struct MediaDisplayProjection {
  MediaDisplaySize source;
  double width{}, height{}, x{}, y{}, scale{};
};

// Cold geometry arithmetic. All intermediates are exact and bounded; failure
// is empty rather than a rounded claim about container geometry.
inline MediaRational displayProduct(MediaRational a, MediaRational b) noexcept {
  if (a.numerator <= 0 || b.numerator <= 0 || !a.denominator || !b.denominator)
    return {};
  auto an = static_cast<std::uint64_t>(a.numerator);
  auto bn = static_cast<std::uint64_t>(b.numerator);
  auto ad = a.denominator, bd = b.denominator;
  const auto g1 = std::gcd(an, bd), g2 = std::gcd(bn, ad);
  an /= g1; bd /= g1; bn /= g2; ad /= g2;
  if (an > static_cast<std::uint64_t>(INT64_MAX) / bn || ad > UINT64_MAX / bd)
    return {};
  const auto n = an * bn, d = ad * bd, g = std::gcd(n, d);
  return {static_cast<std::int64_t>(n / g), d / g};
}

inline MediaRational displayAspect(MediaDisplaySize size) noexcept {
  if (size.empty() || size.height.denominator > INT64_MAX) return {};
  return displayProduct(size.width, {static_cast<std::int64_t>(size.height.denominator),
                                    static_cast<std::uint64_t>(size.height.numerator)});
}

inline MediaDisplaySize displayFit(MediaDisplaySize size,
                                  std::uint32_t width, std::uint32_t height) noexcept {
  const auto aspect = displayAspect(size);
  if (aspect.numerator <= 0 || !width || !height) return {};
  if (static_cast<__int128>(width) * aspect.denominator <=
      static_cast<__int128>(height) * aspect.numerator) {
    return {{width, 1}, displayProduct({width, 1},
        {static_cast<std::int64_t>(aspect.denominator),
         static_cast<std::uint64_t>(aspect.numerator)})};
  }
  return {displayProduct({height, 1}, aspect), {height, 1}};
}

inline std::int64_t displayPhysicalPixels(MediaRational value) noexcept {
  if (value.numerator <= 0 || !value.denominator) return 0;
  return static_cast<std::int64_t>((static_cast<__int128>(value.numerator) * 2 +
                                    value.denominator) / (2 * static_cast<__int128>(value.denominator)));
}

inline double displayScalar(MediaRational value) noexcept {
  return value.denominator ? static_cast<double>(value.numerator) / value.denominator : 0;
}

} // namespace wam::media
