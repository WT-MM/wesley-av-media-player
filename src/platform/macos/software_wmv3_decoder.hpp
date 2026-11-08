#pragma once

#include "video_decoder_contract.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>

namespace wam::macos {

// WMV3 (SMPTE 421M VC-1 Simple/Main profile) has no CoreMedia codec type and
// no Apple decoder. 'WMV3' is the stream's own BITMAPINFOHEADER compression
// FourCC; VideoToolbox refuses it, so a WMV3 stream never reaches a
// decompression session.
inline constexpr CMVideoCodecType kWamVideoCodecTypeWmv3 =
    static_cast<CMVideoCodecType>('WMV3');

// Software WMV3 decode stage, one implementation of the backend contract in
// video_decoder_contract.hpp behind VideoDecodeLane.
//
// The decoder is the WMV3 half of WAM's LGPL libwam-wmcodecs, loaded with
// dlopen from the bundle's private Frameworks directory (the libavcodec
// stage's rule) so the MIT application never links it. It decodes synchronously on the calling
// dispatcher worker; like the VP8 stage it owns at most one converted frame
// waiting for drainPresentation(), so it draws from the shared
// SoftwarePresentationPool at the depth VP8 established.
//
// A skipped frame (a 1-byte packet) repeats the previous picture: the decoder
// keeps it, and it is copied into a fresh surface with the skipped packet's
// timing.
class SoftwareWmv3Decoder final {
public:
  explicit SoftwareWmv3Decoder(VideoDecoderOptions options = {});
  ~SoftwareWmv3Decoder();

  SoftwareWmv3Decoder(const SoftwareWmv3Decoder &) = delete;
  SoftwareWmv3Decoder &operator=(const SoftwareWmv3Decoder &) = delete;
  SoftwareWmv3Decoder(SoftwareWmv3Decoder &&) = delete;
  SoftwareWmv3Decoder &operator=(SoftwareWmv3Decoder &&) = delete;

  [[nodiscard]] bool configure(const VideoStreamConfiguration &configuration,
                               DecodedFrameSink &sink, std::string *error);
  [[nodiscard]] VideoDecodeSubmitResult
  submitCMSampleBuffer(CMSampleBufferRef sample, std::uint64_t generation,
                       std::string *error);

  [[nodiscard]] VideoDecodeDrainProgress
  beginEndOfStream(std::uint64_t generation, std::string *error);
  [[nodiscard]] VideoDecodeDrainProgress
  drainPresentation(std::uint64_t generation, std::string *error);
  [[nodiscard]] VideoDecodeDrainProgress
  drainEndOfStream(std::uint64_t generation, std::string *error);
  void flush(std::uint64_t nextGeneration) noexcept;
  [[nodiscard]] VideoDecoderRetireProgress
  retire(std::uint64_t retiredGeneration,
         std::uint64_t invalidationGeneration) noexcept;
  void close() noexcept;

  [[nodiscard]] VideoDecoderStats stats() const noexcept;
  [[nodiscard]] VideoDecoderMemoryFacts memoryFacts() const noexcept;
  [[nodiscard]] std::optional<std::string> takeLastError();

  // True when the decoder library loaded. When false the admission sites
  // refuse WMV3, so a source falls back instead.
  [[nodiscard]] static bool available() noexcept;
  // True when the library implements every tool this STRUCT_C sequence header
  // enables. B/BI pictures, in-loop deblocking, range reduction, multires and
  // the Advanced profile (the only one with interlace) are refused, so those
  // streams fall back at admission rather than failing mid-playback.
  [[nodiscard]] static bool supportsSequence(
      std::span<const std::byte> sequenceHeader) noexcept;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace wam::macos
