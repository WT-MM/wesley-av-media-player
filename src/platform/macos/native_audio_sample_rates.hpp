#pragma once

#include "media/native_media_source.hpp"

#include <array>
#include <cmath>
#include <cstdint>

namespace wam::macos {

// The sample rates the native audio route admits, stated once for the session
// preflight, the converter, the output unit and the source admission gate.
//
// The render path runs the output unit's CLIENT format at the track's own
// rate; the device keeps its nominal rate and the output unit's own sample-rate
// converter bridges the two at the input-scope boundary. That converter is the
// stage every 44.1 kHz file already plays through on a 48 kHz device, and it
// was measured (2026-09-05, scratchpad/resample) to carry every rate below:
// the DefaultOutput unit accepts the client format, pulls the client domain
// contiguously (sampleTime 0, 160, 320 ... at 8 kHz), and declares a constant
// 16-client-frame group delay that chirp alignment against ffmpeg's aresample
// reproduces to within 0.01 output frames at every rate. The output shifts its
// host endpoints by that declared delay (NativeAudioRenderCore's group-delay
// shift), so the clock still describes when audio is HEARD.
//
// The set is exactly what was proven end to end, sample-exact, and nothing
// else: 88.2 and 64 kHz are integral rates that were NOT proven and stay
// refused (the frozen converter test pins 88.2 kHz as unsupported). A rate
// outside this family is refused at admission, by name, before any resource
// is entered.
inline constexpr std::array<std::uint32_t, 11> kNativeAudioSampleRates{
    8'000,  11'025, 12'000, 16'000, 22'050,  24'000,
    32'000, 44'100, 48'000, 96'000, 192'000};

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
