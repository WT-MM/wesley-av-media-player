#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/core_media_source_support.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>

namespace wam::macos {

// The one CoreMedia carriage shared by every backend that builds its own
// sample buffers from a demuxer (Matroska, MPEG-TS, libavformat), main and
// preview alike. VideoToolbox compares the description it was configured with
// against the one every sample carries, so a second, differently-built copy of
// either routine would be a decoder reconfiguration waiting to happen.

enum class CompressedSampleBuildStatus : std::uint8_t {
  Built,
  Cancelled,
  Failed,
};

// The video format description for an admitted track, driven by the codec
// facts table: its CoreMedia codec type, its configuration atom (handed to
// CoreMedia verbatim -- re-emitting an avcC/hvcC would change bytes the decoder
// compares), the machine gates for AV1, VP9 and VP8, the colour keys, and the
// pixel aspect. A codec that carries no configuration record (MPEG-2, whose
// sequence header is in band) gets a null extensions dictionary, exactly as
// the decoder builds its own. Null for a track this carriage cannot describe.
[[nodiscard]] CMVideoFormatDescriptionRef createVideoFormatDescription(
    const media::MediaTrackDescriptor& track) noexcept;

// One contiguous CoreMedia block whose memory is real before its writable span
// is handed back, so a demuxer can copy payload bytes straight into it.
// `name` opens the error text.
[[nodiscard]] bool allocateSampleBlock(std::size_t bytes, const char* name,
                                       CMBlockBufferRef* block,
                                       std::span<std::byte>* destination,
                                       std::string* error);

struct CompressedSampleShape {
  CMSampleTimingInfo timing{};
  CMItemCount sampleCount{1};
  CMItemCount sizeEntryCount{1};
  const std::size_t* sizes{nullptr};
  // Audio whose packets differ in frame count: one description per packet,
  // and CoreMedia derives each packet's stamp from them and timing's start.
  const AudioStreamPacketDescription* packets{nullptr};
  // Video only. Audio leaves the attachment array as CoreMedia created it: a
  // container may state audio units as non-key by convention, and NotSync
  // would publish a decode dependency the codec does not have.
  std::optional<bool> videoKeyFrame;
};

// Wraps `block` (its +1 is consumed) into a ready sample buffer, proves the
// buffer admitted every access unit, and states the video sync attachments:
// NotSync, plus DependsOnOthers=false on a key frame.
[[nodiscard]] bool buildCompressedSampleBuffer(CMBlockBufferRef block,
                                               CMFormatDescriptionRef format,
                                               const CompressedSampleShape& shape,
                                               const char* name,
                                               ScopedSampleBuffer* out,
                                               std::string* error);

}  // namespace wam::macos
