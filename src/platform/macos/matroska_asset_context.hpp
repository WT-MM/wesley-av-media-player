#pragma once

#include "media/matroska_demuxer.hpp"
#include "platform/macos/custom_asset_context.hpp"

namespace wam::macos {

// An audio-less Matroska plays on the silent timebase and a video-less one
// (MKA, audio-only MKV/WebM) plays on the audio clock, so neither selection is
// individually mandatory.
using MatroskaAssetContext =
    CustomAssetContext<media::matroska::MatroskaPreparedAsset,
                       media::MediaSourceBackendKind::Matroska, false>;

}  // namespace wam::macos
