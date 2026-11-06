#pragma once

#include "media/matroska_demuxer.hpp"
#include "media/native_media_source.hpp"
#include "platform/macos/core_media_carriage.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

namespace wam::macos {

// Internal boundary shared by the two Matroska CoreMedia consumers: the main
// media source and the scrub preview source. The format description and the
// sample-buffer assembly itself are the shared carriage in
// core_media_carriage.hpp.
//
// Nothing here is part of the shipping surface of `matroska_media_source.hpp`;
// this header is included only by Matroska backend translation units.

// Exact Matroska tick -> MediaTime. A tick is timestampScaleNanoseconds
// nanoseconds, so the reduced nanosecond rational is exact and never rounds
// through double the way a seconds conversion would.
[[nodiscard]] std::optional<media::MediaTime> matroskaTickTime(
    std::int64_t tick, std::uint64_t timestampScaleNanoseconds) noexcept;

using MatroskaSampleBuildStatus = CompressedSampleBuildStatus;

struct MatroskaSampleBuildInputs {
  const media::matroska::MatroskaPreparedAsset* asset{nullptr};
  media::CancellationToken cancellation{};
  CMFormatDescriptionRef format{nullptr};
  bool video{true};
  // Only meaningful for audio: the exact media-timeline extent of one access
  // unit, which CoreMedia expands into the per-unit stamps the converter reads.
  std::int64_t audioFramesPerPacket{0};
  std::int32_t audioSampleRate{0};
};

// Materializes one payload-free cursor sample into a retained CMSampleBuffer.
//
// Timing is the load-bearing decision here. Container rationals are carried
// straight into CMTimeMake as {value, timescale}; converting through seconds
// would reintroduce exactly the rounding the demuxer was built to avoid. The
// decode stamp is always invalid because Matroska carries no DTS and the
// demuxer refuses to invent one - VideoToolbox then decodes in submission
// order, which is the storage order the cursor emits in.
[[nodiscard]] MatroskaSampleBuildStatus buildMatroskaCompressedSampleBuffer(
    const MatroskaSampleBuildInputs& inputs,
    const media::matroska::MatroskaCompressedSample& sample,
    ScopedSampleBuffer* out, std::string* error);

}  // namespace wam::macos
