#pragma once

#include "native_audio_converter.hpp"

#include <memory>

namespace wam::macos {

// The production decoder for one admitted audio codec: the WAM ADPCM decoder
// for IMA/MS ADPCM, libavcodec for the software codecs when
// WAM_ENABLE_AVCODEC_STAGE is built, AudioToolbox for everything else. Empty
// for a software codec in a build without that stage. The wake reaches only a
// backend that decodes asynchronously.
[[nodiscard]] std::unique_ptr<NativeAudioConverterBackend>
makeNativeAudioConverterBackend(media::MediaCodec codec,
                                NativeAudioBackendWake wake);

} // namespace wam::macos
