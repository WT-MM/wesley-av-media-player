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
  // Vorbis joins Opus for the same structural reason stated differently by the
  // format: its first packet carries only half an overlap-add window and
  // decodes to no samples, so access unit 0 presents one block before media
  // zero. Where Opus states the offset as a CodecDelay/pre-skip field, Vorbis
  // implies it, but it lands in exactly the same arithmetic.
  return codec == MediaCodec::Opus || codec == MediaCodec::Vorbis;
}

} // namespace wam::media
