#pragma once

#include "native_video_presenter.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

#if defined(WAM_NATIVE_VIDEO_TESTING)
struct VideoToolboxDecoderTestAccess;
#endif

// Selects the zero-copy GPU import contract requested from CoreVideo. OpenGL
// adds CGL IOSurface texture compatibility while retaining Metal compatibility,
// so an opt-in native OpenGL presenter can fail back without changing the
// decoded-frame ownership contract.
enum class VideoToolboxOutputInterop : std::uint8_t {
  Metal,
  OpenGL,
};

struct VideoToolboxDecoderOptions {
  // Counts frames accepted by VideoToolbox whose output has not yet been
  // retired in submission order. This deliberately includes callbacks that
  // completed out of order, so callback scheduling cannot bypass the bound.
  // submit() returns typed backpressure before allocating or copying compressed
  // packet storage when this bound is reached.
  std::size_t maxInFlightFrames{3};
  // Hard ceiling for the codec-derived presentation reorder depth. configure()
  // rejects a stream whose SPS requires more retained IOSurfaces, allowing the
  // caller to fall back without silently corrupting presentation order.
  std::size_t maxPendingPresentationFrames{8};
  // Metal is the established decoder output contract. The dormant OpenGL mode
  // additionally guarantees CGLTexImageIOSurface2D-compatible IOSurfaces and
  // validates the exact two-plane NV12/P010 layout before delivery.
  VideoToolboxOutputInterop outputInterop{VideoToolboxOutputInterop::Metal};
#if defined(WAM_NATIVE_VIDEO_TESTING)
  // VideoToolbox is allowed to invoke an output handler before submit()
  // returns even when asynchronous decompression is enabled. This test-only
  // switch exercises both legal callback modes. Temporal processing is never
  // enabled: Apple permits it to retain frames indefinitely until EOS, which
  // is incompatible with finite pre-EOS admission.
  bool enableAsynchronousDecompression{true};
#endif
};

struct VideoToolboxDecoderStats {
  bool configured{false};
  bool usingHardwareAcceleratedDecoder{false};
  bool awaitingKeyFrame{true};
  std::size_t maxInFlightFrames{0};
  std::size_t inFlightFrames{0};
  std::size_t codecReorderFrames{0};
  std::uint64_t generation{0};
  std::uint64_t submittedFrames{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t droppedFrames{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t sinkBackpressureDrops{0};
  std::uint64_t outOfOrderDrops{0};
  std::size_t pendingPresentationFrames{0};
  std::size_t peakPendingPresentationFrames{0};
  VideoToolboxOutputInterop outputInterop{VideoToolboxOutputInterop::Metal};
  OSType requestedOutputPixelFormat{0};
  OSType actualOutputPixelFormat{0};
};

// H.264/HEVC VideoToolbox decoder. Input packets must use the length-prefixed
// NAL representation described by the supplied avcC/hvcC configuration atom.
// Packet/configuration byte spans are copied before API calls return and are
// rejected above fixed 32 MiB / 1 MiB bounds. Decoded frames must exactly match
// the requested IOSurface-backed NV12/P010 format; VideoToolbox substitutions
// are treated as an asynchronous stream-contract error.
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
#if defined(WAM_NATIVE_VIDEO_TESTING)
  friend struct VideoToolboxDecoderTestAccess;
#endif
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#if defined(WAM_NATIVE_VIDEO_TESTING)
// Compiled only into the native decoder test's private source copy. This seam
// establishes a saturated admission state without relying on VideoToolbox's
// architecture-dependent callback scheduling.
struct VideoToolboxDecoderTestAccess {
  [[nodiscard]] static bool
  occupyInFlightCapacity(VideoToolboxDecoder &decoder, std::string *error);
  [[nodiscard]] static bool
  releaseInFlightCapacity(VideoToolboxDecoder &decoder, std::string *error);
  [[nodiscard]] static std::uint32_t
  decodeFlags(const VideoToolboxDecoder &decoder) noexcept;
  [[nodiscard]] static std::optional<std::size_t>
  codecReorderFrames(const VideoStreamConfiguration &configuration);
  [[nodiscard]] static bool setPresentationReorderDepth(
      VideoToolboxDecoder &decoder, std::size_t reorderFrames,
      std::string *error);
  [[nodiscard]] static bool reserveInjectedSubmissions(
      VideoToolboxDecoder &decoder, std::size_t count, std::string *error);
  [[nodiscard]] static bool injectDecodedFrame(
      VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
      CVPixelBufferRef pixelBuffer, FrameTiming timing, std::string *error);
  [[nodiscard]] static bool validateOutputSurface(
      CVPixelBufferRef pixelBuffer, OSType expectedPixelFormat,
      VideoToolboxOutputInterop outputInterop, std::string *error);
  static void drainPresentationFrames(VideoToolboxDecoder &decoder) noexcept;
};
#endif

} // namespace wam::macos
