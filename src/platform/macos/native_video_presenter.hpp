#pragma once

#include "native_surface_budget.hpp"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurfaceRef.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>

namespace wam::macos {

#if defined(WAM_NATIVE_FRAME_LEASE_TESTING)
struct FrameLeaseTestAccess;
#endif

// Identifies a decode generation. Incrementing the generation on seek or load
// lets every asynchronous stage reject frames from the previous timeline.
struct FrameTiming {
  CMTime presentationTime{kCMTimeInvalid};
  CMTime duration{kCMTimeInvalid};
  std::uint64_t generation{0};
  bool keyFrame{false};
};

// A cheap, reference-counted lease on a VideoToolbox/CoreVideo output frame.
// CPU-backed buffers retain the borrowed CoreVideo reference directly.
// IOSurface-backed buffers are admitted through NativeSurfaceBudget before
// retaining that reference; a failed admission produces a wholly empty lease.
// Copies clone the existing accounting token and never reacquire by identity.
// No pixel bytes are copied.
class FrameLease final {
public:
  FrameLease() noexcept = default;
  explicit FrameLease(CVPixelBufferRef pixelBuffer,
                      FrameTiming timing = {}) noexcept;
  FrameLease(const FrameLease &other) noexcept;
  FrameLease &operator=(const FrameLease &other) noexcept;
  FrameLease(FrameLease &&other) noexcept;
  FrameLease &operator=(FrameLease &&other) noexcept;
  ~FrameLease();

  [[nodiscard]] explicit operator bool() const noexcept;
  [[nodiscard]] CVPixelBufferRef pixelBuffer() const noexcept;
  [[nodiscard]] IOSurfaceRef ioSurface() const noexcept;
  [[nodiscard]] bool isIOSurfaceBacked() const noexcept;
  [[nodiscard]] OSType pixelFormat() const noexcept;
  [[nodiscard]] std::size_t width() const noexcept;
  [[nodiscard]] std::size_t height() const noexcept;
  [[nodiscard]] const FrameTiming &timing() const noexcept;

  void reset() noexcept;

private:
#if defined(WAM_NATIVE_FRAME_LEASE_TESTING)
  friend struct FrameLeaseTestAccess;
#endif
  void swap(FrameLease &other) noexcept;

  CVPixelBufferRef pixelBuffer_{nullptr};
  FrameTiming timing_{};
  NativeSurfaceBudgetToken surface_budget_token_{};
};

#if defined(WAM_NATIVE_FRAME_LEASE_TESTING)
// Header-only access keeps every test-only symbol out of shipping objects.
// Tests may inspect the exact token clone used by FrameLease without adding a
// second acquisition path to the production API.
struct FrameLeaseTestAccess {
  [[nodiscard]] static NativeSurfaceBudgetToken &
  surfaceBudgetToken(FrameLease &frame) noexcept {
    return frame.surface_budget_token_;
  }
  [[nodiscard]] static const NativeSurfaceBudgetToken &
  surfaceBudgetToken(const FrameLease &frame) noexcept {
    return frame.surface_budget_token_;
  }
};
#endif

struct MetalPlane {
  std::size_t width{0};
  std::size_t height{0};
  std::size_t sourcePlane{0};
  std::uint64_t metalPixelFormat{0};
};

// Owns the CVMetalTexture views for one frame and keeps the source frame alive.
// nativeTexture() is a borrowed id<MTLTexture> encoded as void*. It remains
// valid only while this MetalFrameLease is alive.
class MetalFrameLease final {
public:
  MetalFrameLease() noexcept;
  MetalFrameLease(MetalFrameLease &&other) noexcept;
  MetalFrameLease &operator=(MetalFrameLease &&other) noexcept;
  ~MetalFrameLease();

  MetalFrameLease(const MetalFrameLease &) = delete;
  MetalFrameLease &operator=(const MetalFrameLease &) = delete;

  [[nodiscard]] explicit operator bool() const noexcept;
  [[nodiscard]] const FrameLease &frame() const noexcept;
  [[nodiscard]] std::size_t planeCount() const noexcept;
  [[nodiscard]] const MetalPlane &plane(std::size_t index) const;
  [[nodiscard]] void *nativeTexture(std::size_t index) const noexcept;

private:
  struct Storage;
  explicit MetalFrameLease(std::unique_ptr<Storage> storage) noexcept;

  std::unique_ptr<Storage> storage_;
  friend class MetalTextureCache;
};

// Owns one CVMetalTextureCache tied to a Metal device. Importing an
// IOSurface-backed FrameLease creates Metal texture views without a CPU copy.
class MetalTextureCache final {
public:
  // nativeMetalDevice may be null to use MTLCreateSystemDefaultDevice(). When
  // supplied it must be an id<MTLDevice> encoded as void*.
  static std::unique_ptr<MetalTextureCache>
  create(void *nativeMetalDevice = nullptr, std::string *error = nullptr);

  MetalTextureCache(const MetalTextureCache &) = delete;
  MetalTextureCache &operator=(const MetalTextureCache &) = delete;
  MetalTextureCache(MetalTextureCache &&) = delete;
  MetalTextureCache &operator=(MetalTextureCache &&) = delete;
  ~MetalTextureCache();

  [[nodiscard]] void *nativeDevice() const noexcept;
  [[nodiscard]] std::optional<MetalFrameLease>
  importFrame(const FrameLease &frame, std::string *error = nullptr);

  // Flushes cached texture metadata. Existing MetalFrameLeases remain valid.
  void flush() noexcept;

private:
  struct Impl;
  explicit MetalTextureCache(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
};

struct VideoStreamConfiguration {
  CMVideoCodecType codec{0};
  CMVideoDimensions codedSize{0, 0};
  std::span<const std::byte> codecConfiguration{};
  bool preferHardwareDecode{true};
  bool requireHardwareDecode{false};
  std::uint64_t generation{0};
  // APPENDED 2026-08-27 under amendment 6. True when the stream's transfer
  // function is PQ (ST 2084) or HLG, i.e. when the decoded surface must be
  // presented through the system's HDR path rather than as SDR.
  //
  // It exists because the decode OUTPUT DEPTH is what switches that path on,
  // and the coded depth is not the same question. MEASURED on this platform
  // 2026-08-27: an 8-bit BT.2020/PQ H.264 stream decodes to an 8-bit `420v`
  // surface that carries every correct colour attachment -- primaries,
  // transfer, and a resolved "Rec. ITU-R BT.2100 PQ" CGColorSpace -- and
  // AVSampleBufferDisplayLayer presents it as if it were SDR anyway. Screen-
  // captured against QuickTime Player on the identical file, that render was
  // off by 98/255 on the colour-bar means with a ramp histogram L1 of 0.65,
  // while the SAME pattern encoded as 10-bit PQ HEVC matched QuickTime to
  // 3.3/255 and 0.050. The tag is not what engages the HDR path; a >=10-bit
  // surface is. So an HDR-tagged 8-bit stream asks VideoToolbox for a 10-bit
  // output surface and is presented correctly.
  //
  // This is the shape of the user's own movie -- 8-bit yuv420p tagged
  // bt2020nc/bt2020/smpte2084 -- so it is the load-bearing case, not an edge.
  bool highDynamicRangeTransfer{false};

  // APPENDED 2026-08-27 (Matroska HDR). The colour description the session's
  // format description must carry, as the CoreMedia extension values, or
  // nullptr for "write no key" -- see applyColorExtensions() in
  // native_video_color.hpp, which is where these come from.
  //
  // Why the DECODER needs them and the sample buffer's own description is not
  // enough. createFormatDescription() reconstructs its description from the
  // codec configuration atom alone, and that is the description
  // VTDecompressionSessionCreate is called with. adoptDirectFormatLocked()
  // does swap in a directly submitted sample's richer description -- but only
  // when the live session cannot already accept it, so for a codec whose
  // acceptance test is lenient the colr-less reconstruction simply stays.
  //
  // MEASURED, and this is what made the case: with the colour on the sample
  // buffer alone, 8-bit PQ H.264 in Matroska matched QuickTime to 4.6/255
  // while 10-bit PQ HEVC in Matroska was off by 98.6/255 -- rendering as SDR.
  // The 8-bit case only came out right because an HDR-tagged 8-bit stream
  // PINS its output format, and the pin routes every frame through a pixel
  // transfer that re-tags it. The 10-bit case does not pin, so it presented
  // whatever the colr-less session produced. Carrying the colour here fixes
  // the class directly instead of relying on a side effect of the pin.
  CFStringRef colorPrimaries{nullptr};
  CFStringRef transferFunction{nullptr};
  CFStringRef ycbcrMatrix{nullptr};
};

struct CompressedVideoPacket {
  std::span<const std::byte> bytes{};
  CMTime presentationTime{kCMTimeInvalid};
  CMTime decodeTime{kCMTimeInvalid};
  CMTime duration{kCMTimeInvalid};
  std::uint64_t generation{0};
  bool keyFrame{false};
  bool endOfStream{false};
};

enum class FrameEnqueueResult : std::uint8_t {
  Accepted,
  Backpressure,
  Rejected,
};

enum class VideoDecodeSubmitResult : std::uint8_t {
  Accepted,
  Backpressure,
  Rejected,
};

// Boundary between a decoder and the presentation queue. VideoToolbox may call
// enqueue() inline before submit() returns even when asynchronous decode was
// requested, so implementations must return promptly and must not wait on the
// submitting thread. A sink takes ownership of the lease it accepts.
// Backpressure is explicit so decode cannot grow memory without bound when the
// display falls behind.
class DecodedFrameSink {
public:
  virtual ~DecodedFrameSink() = default;
  [[nodiscard]] virtual FrameEnqueueResult enqueue(FrameLease frame,
                                                   std::string *error) = 0;
  virtual void endOfStream(std::uint64_t generation) = 0;
  virtual void flush(std::uint64_t nextGeneration) noexcept = 0;
};

// A thread-safe, allocation-bounded handoff queue for decoder output. It
// rejects over-capacity and stale-generation frames instead of silently
// accumulating full-resolution pixel buffers.
class BoundedFrameQueue final : public DecodedFrameSink {
public:
  explicit BoundedFrameQueue(std::size_t capacity,
                             std::uint64_t initialGeneration = 0);
  ~BoundedFrameQueue() override;

  BoundedFrameQueue(const BoundedFrameQueue &) = delete;
  BoundedFrameQueue &operator=(const BoundedFrameQueue &) = delete;
  BoundedFrameQueue(BoundedFrameQueue &&) = delete;
  BoundedFrameQueue &operator=(BoundedFrameQueue &&) = delete;

  [[nodiscard]] FrameEnqueueResult enqueue(FrameLease frame,
                                           std::string *error) override;
  void endOfStream(std::uint64_t generation) override;
  void flush(std::uint64_t nextGeneration) noexcept override;

  [[nodiscard]] std::optional<FrameLease> tryTake();
  [[nodiscard]] std::size_t size() const noexcept;
  [[nodiscard]] std::size_t capacity() const noexcept;
  [[nodiscard]] std::uint64_t generation() const noexcept;
  [[nodiscard]] bool reachedEndOfStream() const noexcept;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

// Future demuxers can feed this interface without depending on VideoToolbox.
// Implementations must consume or copy packet/configuration spans before the
// call returns; the caller retains ownership of those byte ranges.
class VideoDecodeBackend {
public:
  virtual ~VideoDecodeBackend() = default;
  [[nodiscard]] virtual bool
  configure(const VideoStreamConfiguration &configuration,
            DecodedFrameSink &sink, std::string *error) = 0;
  [[nodiscard]] virtual VideoDecodeSubmitResult
  submit(const CompressedVideoPacket &packet, std::string *error) = 0;
  virtual void flush(std::uint64_t nextGeneration) noexcept = 0;
  virtual void close() noexcept = 0;
};

// Renderer-facing contract. It deliberately accepts decoded frame leases, not
// codec packets, so decode and presentation can be benchmarked or replaced
// independently.
class VideoPresentationBackend : public DecodedFrameSink {
public:
  ~VideoPresentationBackend() override = default;
  [[nodiscard]] virtual bool start(void *nativeMetalDevice,
                                   std::string *error) = 0;
  virtual void stop() noexcept = 0;
};

} // namespace wam::macos
