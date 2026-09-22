#pragma once

#include <cstdint>

namespace wam::media {

// CoreAudio's 'ms' plus big-endian WAVE_FORMAT_ADPCM (0x0002) identity.
inline constexpr std::uint32_t kMicrosoftAdpcmAudioFormatTag{0x6D730002U};

} // namespace wam::media
