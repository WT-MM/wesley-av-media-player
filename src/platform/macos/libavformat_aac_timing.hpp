#pragma once
#include "media/libavformat_cursor.hpp"
namespace wam::macos {
struct LibavformatAacTiming {
  media::MediaTime origin, demuxOrigin, end;
};
std::optional<LibavformatAacTiming> proveLibavformatAacTiming(
    const std::filesystem::path&, int trackId,
    const media::LibavformatCursor::Packet&);
}
