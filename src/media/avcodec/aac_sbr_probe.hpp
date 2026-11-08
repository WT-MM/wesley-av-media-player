#pragma once
namespace wam::media::avcodec {
// Installs the bundled-libavcodec implicit-SBR detector for every AAC route
// (codec::installAacSbrDetector). Idempotent.
void installAacSbrDetector() noexcept;
}
