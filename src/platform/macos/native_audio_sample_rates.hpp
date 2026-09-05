#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <cmath>
#include <cstdint>

namespace wam::macos {

// The sample rates the native audio route admits, stated once for the session
// preflight, the converter and the source admission gate. The set is bound by
// the OUTPUT unit, not the decoders: the render path runs the output at the
// track's own rate, and the device accepts exactly this family (measured: 96
// kHz configures, 64 kHz and everything below 44.1 kHz are refused by the
// output). Content at any other rate needs a resampling stage before it can
// be admitted, so it is refused at admission, by name, before any resource
// is entered.
inline constexpr std::array<std::uint32_t, 4> kNativeAudioSampleRates{
    44'100, 48'000, 96'000, 192'000};

// Whether `rate` is exactly one of the admitted rates; on success the exact
// integer rate is written to `exactRate` when it is non-null.
[[nodiscard]] inline bool nativeAudioSampleRateSupported(
    double rate, std::uint32_t* exactRate = nullptr) noexcept {
  if (!std::isfinite(rate) || rate <= 0.0 ||
      rate > media::MediaSourceLimits::kHardMaximumAudioSampleRate) {
    return false;
  }
  for (const std::uint32_t candidate : kNativeAudioSampleRates) {
    if (rate == static_cast<double>(candidate)) {
      if (exactRate != nullptr) {
        *exactRate = candidate;
      }
      return true;
    }
  }
  return false;
}

}  // namespace wam::macos
