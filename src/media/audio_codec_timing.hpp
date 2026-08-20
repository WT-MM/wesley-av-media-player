#pragma once

#include "media/native_media_source.hpp"

namespace wam::media {

// True for audio codecs whose first access unit legitimately presents BEFORE
// media time zero.
//
// Matroska stores an audio Block's timestamp on the codec grid and states the
// encoder's lead-in separately as CodecDelay, which a reader must subtract to
// obtain the presentation time. Opus always has such a lead-in -- the OpusHead
// pre-skip -- so access unit 0 of every real Opus mux starts pre-skip frames
// early and the generation decodes a bounded preroll it must not publish.
//
// Every other admitted codec starts exactly at zero, and the nonnegative
// guards those codecs are checked against stay in force. This predicate exists
// so the exception is stated once instead of being re-derived at each of the
// layers that has to relax for it.
[[nodiscard]] constexpr bool
audioCodecPrecedesStreamOrigin(MediaCodec codec) noexcept {
  return codec == MediaCodec::Opus;
}

} // namespace wam::media
