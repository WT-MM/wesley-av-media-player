#pragma once

#include "media/matroska_demuxer.hpp"
#include "media/native_media_source.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
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

// Exact sum of two container rationals. The intermediate product needs the full
// 128-bit range: adjacent media ticks at a nanosecond timescale are already
// above 2^53, so converting through double would silently move a sample across
// the accurate-seek boundary. Copied verbatim from the AVFoundation backend so
// both sources answer decodeOnly identically for the same interval, and shared
// from here so the main and preview Matroska sources cannot drift apart.
[[nodiscard]] std::optional<media::MediaTime> matroskaCheckedExactTimeSum(
    media::MediaTime lhs, media::MediaTime rhs) noexcept;

// True when the sample's whole presentation interval closes at or before the
// accurate-seek target, which is exactly the decodeOnly predicate. Empty when
// the interval is not exactly representable or comparable, with the reason
// written through `error`.
[[nodiscard]] std::optional<bool> matroskaAccurateVideoDecodeOnly(
    media::MediaTime presentationTime, media::MediaTime duration,
    media::MediaTime target, std::string* error) noexcept;

// Owns the +1 on one retained CoreMedia buffer. The name carries the backend
// prefix because it is now a namespace-scope type sharing `wam::macos` with the
// AVFoundation backend's own file-local guard of the same shape.
class MatroskaScopedSampleBuffer final {
 public:
  MatroskaScopedSampleBuffer() noexcept = default;
  explicit MatroskaScopedSampleBuffer(CMSampleBufferRef owned) noexcept
      : value_(owned) {}
  ~MatroskaScopedSampleBuffer() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }

  MatroskaScopedSampleBuffer(MatroskaScopedSampleBuffer&& other) noexcept
      : value_(other.value_) {
    other.value_ = nullptr;
  }
  MatroskaScopedSampleBuffer& operator=(
      MatroskaScopedSampleBuffer&& other) noexcept {
    if (this != &other) {
      if (value_ != nullptr) {
        CFRelease(value_);
      }
      value_ = other.value_;
      other.value_ = nullptr;
    }
    return *this;
  }
  MatroskaScopedSampleBuffer(const MatroskaScopedSampleBuffer&) = delete;
  MatroskaScopedSampleBuffer& operator=(const MatroskaScopedSampleBuffer&) =
      delete;

  [[nodiscard]] CMSampleBufferRef get() const noexcept { return value_; }
  [[nodiscard]] CMSampleBufferRef release() noexcept {
    CMSampleBufferRef owned = value_;
    value_ = nullptr;
    return owned;
  }

 private:
  CMSampleBufferRef value_{nullptr};
};

// Owns the +1 on one retained CoreMedia buffer for the lifetime of every lease
// taken against it. Shape copied from the AVFoundation backend's storage so the
// native video consumer, the audio converter, and the preview decoder accept
// Matroska samples unchanged.
class MatroskaCoreMediaSampleStorage final : public media::MediaPayloadStorage {
 public:
  MatroskaCoreMediaSampleStorage(CMSampleBufferRef ownedSample,
                                 std::size_t byteSize) noexcept;
  ~MatroskaCoreMediaSampleStorage() override;

  MatroskaCoreMediaSampleStorage(const MatroskaCoreMediaSampleStorage&) =
      delete;
  MatroskaCoreMediaSampleStorage& operator=(
      const MatroskaCoreMediaSampleStorage&) = delete;

  [[nodiscard]] std::size_t byteSize() const noexcept override;
  [[nodiscard]] std::span<const std::byte>
  contiguousBytes() const noexcept override;
  [[nodiscard]] bool copyBytes(
      std::size_t offset,
      std::span<std::byte> destination) const noexcept override;

 protected:
  [[nodiscard]] std::optional<media::NativePayloadKind>
  nativePayloadKind() const noexcept override;
  [[nodiscard]] const void* borrowedNativePayload() const noexcept override;

 private:
  CMSampleBufferRef sample_{nullptr};
  std::size_t byte_size_{0};
};

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
    MatroskaScopedSampleBuffer* out, std::string* error);

[[nodiscard]] const char* matroskaDemuxErrorName(
    media::matroska::MatroskaDemuxError error) noexcept;

// The neutral header owns no FileChanged status, so a mid-stream identity
// change has to travel as a MediaSourceFailure. Naming the demuxer error inside
// the message keeps that fact recoverable by an owner that must distinguish a
// swapped file from an ordinary read error.
[[nodiscard]] std::string matroskaDemuxErrorMessage(
    const char* what, media::matroska::MatroskaDemuxError error);

}  // namespace wam::macos
