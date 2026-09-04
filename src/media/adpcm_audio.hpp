#pragma once

#include <cstdint>

namespace wam::media {

// 'ms\0\x02', Microsoft ADPCM. AudioToolbox decodes this format --
// kAudioFormatProperty_DecodeFormatIDs reports it, and a converter created with
// this mFormatID and the WAV fmt chunk's magic cookie decodes a real file to
// its exact declared frame count -- but CoreAudio publishes no
// kAudioFormatMicrosoftADPCM constant for it. CoreAudioBaseTypes.h names only
// its neighbours in the same 'ms\0\0'+wFormatTag family
// (kAudioFormatDVIIntelIMA = 0x6D730011, kAudioFormatMicrosoftGSM =
// 0x6D730031), so the value is stated here once and shared by the AVFoundation
// source, the converter and the audio session rather than spelled three times
// as a bare literal.
//
// The encoding is the Microsoft convention CoreAudio uses for every WAVE
// format it has no dedicated fourcc for: the two ASCII bytes 'm', 's' followed
// by the 16-bit wFormatTag from the file's fmt chunk, big-endian. WAVE_FORMAT_
// ADPCM is wFormatTag 0x0002, hence 0x6D730002.
inline constexpr std::uint32_t kMicrosoftAdpcmAudioFormatTag{0x6D730002U};

} // namespace wam::media
