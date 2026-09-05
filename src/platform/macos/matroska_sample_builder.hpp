#pragma once

#include "media/matroska_demuxer.hpp"
#include "media/native_media_source.hpp"
#include "platform/macos/core_media_source_support.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

namespace wam::macos {

// Internal boundary shared by the two Matroska CoreMedia consumers: the main
// media source and the scrub preview source. Both must hand VideoToolbox the
// byte-identical format description and the identically assembled sample
// buffer, because the decoder compares the description it was configured with
// against the one every sample carries. A second, differently-built copy of
// either routine would be a decoder reconfiguration waiting to happen, so
// these live here rather than in either owner's anonymous namespace.
//
// Nothing here is part of the shipping surface of `matroska_media_source.hpp`;
// this header is included only by Matroska backend translation units.

// Exact Matroska tick -> MediaTime. A tick is timestampScaleNanoseconds
// nanoseconds, so the reduced nanosecond rational is exact and never rounds
// through double the way a seconds conversion would.
[[nodiscard]] std::optional<media::MediaTime> matroskaTickTime(
    std::int64_t tick, std::uint64_t timestampScaleNanoseconds) noexcept;

enum class MatroskaSampleBuildStatus : std::uint8_t {
  Built,
  Cancelled,
  Failed,
};

struct MatroskaSampleBuildInputs {
  const media::matroska::MatroskaPreparedAsset* asset{nullptr};
  media::matroska::CancellationToken cancellation{};
  CMFormatDescriptionRef format{nullptr};
  bool video{true};
  // Only meaningful for audio: the exact media-timeline extent of one access
  // unit, which CoreMedia expands into the per-unit stamps the converter reads.
  std::int64_t audioFramesPerPacket{0};
  std::int32_t audioSampleRate{0};
};

// The decoder builds its own format description from exactly these inputs, so
// building this one identically is what lets VideoToolbox adopt the sample's
// description instead of rejecting a second, differently-encoded one. The
// configuration record is handed to CoreMedia verbatim: rewriting, reordering,
// or re-emitting an avcC/hvcC atom would change bytes the decoder compares.
[[nodiscard]] CMVideoFormatDescriptionRef createMatroskaVideoFormatDescription(
    const media::MediaTrackDescriptor& track) noexcept;

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

[[nodiscard]] const char* matroskaDemuxErrorName(
    media::matroska::MatroskaDemuxError error) noexcept;

// The neutral header owns no FileChanged status, so a mid-stream identity
// change has to travel as a MediaSourceFailure. Naming the demuxer error inside
// the message keeps that fact recoverable by an owner that must distinguish a
// swapped file from an ordinary read error.
[[nodiscard]] std::string matroskaDemuxErrorMessage(
    const char* what, media::matroska::MatroskaDemuxError error);

}  // namespace wam::macos
