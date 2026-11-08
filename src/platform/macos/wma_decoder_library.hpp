#pragma once

#include "wam_wmcodecs.h"

namespace wam::macos {

inline constexpr char kWmaDecoderLibraryName[] = "libwam-wmcodecs.dylib";

// The LGPL WMA decoder, which WAM's code reaches only through dlopen. Bound
// once from the bundle's own library directory; null when it is missing,
// outside the bundle, or lacks a symbol.
struct WmaDecoderLibrary {
  decltype(&wam_wma_create) create{};
  decltype(&wam_wma_destroy) destroy{};
  decltype(&wam_wma_frame_length) frameLength{};
  decltype(&wam_wma_max_samples) maxSamples{};
  decltype(&wam_wma_decode) decode{};
  decltype(&wam_wma_drain) drain{};
  decltype(&wam_wma_flush) flush{};
  decltype(&wam_wma_superframe_frames) superframeFrames{};
  decltype(&wam_wma_uses_noise_coding) usesNoiseCoding{};
};
[[nodiscard]] const WmaDecoderLibrary *wmaDecoderLibrary() noexcept;

} // namespace wam::macos
