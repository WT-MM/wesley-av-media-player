#pragma once
#include "media/libavformat_cursor.hpp"
namespace wam::macos {
struct LibavformatAacTiming {
  media::MediaTime origin, demuxOrigin, end;
};
// Validate a single rate-one edit (optionally following declared silence).
// Packet skip side data remains the exact priming authority for ordinary MP4.
struct LibavformatAacEdit { media::MediaTime start, end; };
std::optional<LibavformatAacEdit> inspectLibavformatAacEdit(
    const std::filesystem::path&, int trackId);
std::optional<LibavformatAacTiming> proveLibavformatAacTiming(
    const std::filesystem::path&, int trackId,
    const media::LibavformatCursor::Packet&);
}
