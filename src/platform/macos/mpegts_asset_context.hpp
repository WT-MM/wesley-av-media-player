#pragma once

#include "media/mpegts_demuxer.hpp"
#include "platform/macos/custom_asset_context.hpp"

namespace wam::macos {

// A selected video track is mandatory. A selected audio track is not: a
// transport stream whose only audio elementary stream is outside the routable
// envelope is admitted with selectedAudio left unset (the demuxer's recorded
// downgrade).
using MpegTsAssetContext =
    CustomAssetContext<media::mpegts::MpegTsPreparedAsset,
                       media::MediaSourceBackendKind::MpegTs, true>;

}  // namespace wam::macos
