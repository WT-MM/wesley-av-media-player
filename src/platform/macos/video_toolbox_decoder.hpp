#pragma once

#include "native_video_presenter.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

struct VideoToolboxDecoderOptions {
  // Counts frames accepted by VideoToolbox whose output callback has not yet
  // completed. submit() returns typed backpressure before allocating or copying
  // compressed packet storage when this bound is reached.
  std::size_t maxInFlightFrames{3};
  // Bounds decoded IOSurfaces retained briefly to convert decode-order
  // callbacks into presentation order. Normal H.264/HEVC GOPs require only a
  // few frames; saturation intentionally drops instead of growing memory.
  std::size_t maxPendingPresentationFrames{8};
};

struct VideoToolboxDecoderStats {
  bool configured{false};
  bool usingHardwareAcceleratedDecoder{false};
  bool awaitingKeyFrame{true};
  std::size_t maxInFlightFrames{0};
  std::size_t inFlightFrames{0};
  std::uint64_t generation{0};
  std::uint64_t submittedFrames{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t droppedFrames{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t sinkBackpressureDrops{0};
  std::uint64_t presentationBackpressureDrops{0};
  std::uint64_t outOfOrderDrops{0};
  std::size_t pendingPresentationFrames{0};
  std::size_t peakPendingPresentationFrames{0};
  OSType requestedOutputPixelFormat{0};
  OSType actualOutputPixelFormat{0};
};

// H.264/HEVC VideoToolbox decoder. Input packets must use the length-prefixed
// NAL representation described by the supplied avcC/hvcC configuration atom.
// Packet/configuration byte spans are copied before API calls return.
//
// The configured DecodedFrameSink must outlive this object or be retained until
// close() returns. close() and flush() wait for every asynchronous callback and
// invalidate the VT session before returning.
class VideoToolboxDecoder final : public VideoDecodeBackend {
public:
  explicit VideoToolboxDecoder(VideoToolboxDecoderOptions options = {});
  ~VideoToolboxDecoder() override;

  VideoToolboxDecoder(const VideoToolboxDecoder &) = delete;
  VideoToolboxDecoder &operator=(const VideoToolboxDecoder &) = delete;
  VideoToolboxDecoder(VideoToolboxDecoder &&) = delete;
  VideoToolboxDecoder &operator=(VideoToolboxDecoder &&) = delete;

  [[nodiscard]] bool configure(const VideoStreamConfiguration &configuration,
                               DecodedFrameSink &sink,
                               std::string *error) override;
  [[nodiscard]] VideoDecodeSubmitResult
  submit(const CompressedVideoPacket &packet, std::string *error) override;
  void flush(std::uint64_t nextGeneration) noexcept override;
  void close() noexcept override;

  [[nodiscard]] VideoToolboxDecoderStats stats() const noexcept;
  [[nodiscard]] std::optional<std::string> takeLastError();

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace wam::macos
