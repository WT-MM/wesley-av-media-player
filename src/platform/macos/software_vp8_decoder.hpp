#pragma once

#include "video_toolbox_decoder.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

// VP8 has no CoreMedia codec type: `kCMVideoCodecType_VP8` does not exist and
// no Apple decoder has ever decoded VP8. The Matroska sample factory still
// carries VP8 access units as CMSampleBuffers so that the merge lane, the
// timing proofs and the dispatcher's compressed read-ahead stay byte-identical
// to every other codec, which needs *a* four-character code in the format
// description. This is the ISO Media File Format binding's own VP8 sample
// entry name, so it is a real identifier rather than an invented one, and
// VideoToolbox refuses it -- which is exactly the property that keeps a VP8
// stream from ever reaching a decompression session.
inline constexpr CMVideoCodecType kWamVideoCodecTypeVp8 =
    static_cast<CMVideoCodecType>('vp08');

// Decoded surfaces this stage owns at one instant. libvpx decodes
// synchronously on the calling thread, so there is no in-flight submission
// window at all: at most one converted frame waits for drainPresentation() to
// hand it to the sink.
inline constexpr std::size_t kSoftwareVp8DecoderOwnedSurfaces = 1;

// Decoded surfaces the AVSampleBufferVideoRenderer holds beyond WAM's own
// leases. This is not a lease count and no lease count can observe it: WAM
// releases its retiring lease one enqueue after a frame stops being newest,
// but CoreAnimation keeps its own reference on the CVPixelBuffer until the
// surface leaves the compositor, and a pool recycles a buffer only when that
// last reference is gone.
//
// MEASURED 2026-08-20, live, 1920x1080 at 30 fps, 1800 delivered frames on the
// default CALayer route. The instrument is the pool's own allocation
// threshold, which is exact: CVPixelBufferPoolCreatePixelBufferWithAux-
// Attributes refuses when the pool has already ALLOCATED that many buffers,
// and recycling a free one is not an allocation -- so an ascending probe
// reports precisely how many buffers the pool has ever had to hold at once.
//
//   threshold that satisfied the request : 1:1795  2:1  3:1  4:1  5:1  6:1
//                                          7:0     8:0
//
// That is a five-step warm-up ramp to six buffers and then 1795 pure
// recycles: the pool needed a SIXTH buffer exactly once, needed a seventh
// never, and allocated nothing at all after the ramp. One surface beyond
// WAM's five leases is also exactly what native_video_consumer.hpp's
// kMaximumTrackedOutputSurfaceOwnership note already records from the other
// direction ("Phase A measured renderer retention at max 1 (median 1) in
// decoded mode"), so the two independent measurements agree.
//
// (An earlier depth-5 run confirmed the same fact destructively: it played
// cleanly for 1482 frames and then could not vend a sixth surface.)
inline constexpr std::size_t kSoftwareVp8RendererRetainedSurfaces = 1;

// Every VP8 surface in the process comes from this one pool, so the pool's
// depth is this route's whole decoded-surface footprint. It is a hard cap, not
// a starting size: allocation carries kCVPixelBufferPoolAllocationThresholdKey,
// so an accounting error surfaces as a bounded refusal on the next frame
// instead of as unbounded IOSurface growth behind NativeSurfaceBudget's back.
// A refusal is typed backpressure, not a failure -- the compressed sample
// stays in the dispatcher's lane and is offered again after the output
// releases a surface -- so this depth paces the route rather than deciding
// whether it works. That is what lets it be set to the measured minimum
// instead of to a guessed margin.
//
//   1  the frame this stage holds between decode and drainPresentation()
// + 1  the decoded queue's one lease (kDecodedQueueCapacity)
// + 1  the scheduler-held lease
// + 2  the tracked output's admitted lease plus its retiring predecessor
//      (kMaximumTrackedOutputSurfaceOwnership)
// + 1  the renderer's own retention, measured above
// = 6
//
// native_video_consumer.hpp restates that arithmetic against its own constants
// in a static_assert, so the two cannot drift apart silently.
inline constexpr std::size_t kSoftwareVp8PoolDepth = 6;

// MEMORY, stated because these buffers are app-attributable and the surface
// budget is a contract rather than a knob. The DEPTH above is a count and does
// not move with the coded ceiling; the BYTES behind it do, so they are
// re-derived here whenever the ceiling changes rather than carried forward.
//
// NV12 is 1.5 bytes per pixel (VP8 is 8-bit only: RFC 6386 defines no
// high-bit-depth profile, so this route never allocates P010). Sizes are
// stated at the v1 coded ceiling AND at the resolutions that actually occur,
// because the pool allocates for the stream it is configured with, not for the
// ceiling:
//
//   1920x1080  (2,073,600 px)   surface  3,110,400 B   pool (x6)   18.7 MB
//   3418x1843  (6,299,374 px)   surface  9,449,061 B   pool (x6)   56.7 MB
//   3840x2160  (8,294,400 px)   surface 12,441,600 B   pool (x6)   74.6 MB
//   4096x2320  (9,502,720 px)   surface 14,254,080 B   pool (x6)   85.5 MB
//
// The ceiling row plus IOSurface stride/page alignment is what
// native_video_consumer.hpp asserts against kNativeSurfaceBudgetMaximumBytes:
// 6 * (14,254,080 + 920,168) = 91,045,488 B against 288 MiB, leaving 210.9 MB.
// Against kNativeSurfaceBudgetMaximumSurfaces (10) the depth still leaves four
// surfaces -- that half of the accounting is a count and did not move.
//
// That is the entire decoded-surface cost of a VP8 generation -- VideoToolbox
// holds nothing at all while VP8 plays, so this route's share of the
// process-wide budget is not shared with anything.
//
// Only the five WAM-held leases ever take a NativeSurfaceBudget token; the
// renderer's one is a CoreVideo reference this process no longer leases, which
// is exactly why it has to be provisioned here instead of accounted there.

// Software VP8 decode stage. It presents exactly the surface
// NativeVideoConsumer drives on VideoToolboxDecoder, including that class's
// stats record, so the consumer's state machine is unchanged and the two
// backends are interchangeable behind VideoDecodeLane.
//
// Every method is confined to the one dispatcher worker thread. libvpx is
// called synchronously from submitCMSampleBuffer(), there is no callback
// thread, and nothing here takes a lock.
//
// Decoded output is converted from libvpx's CPU-backed planar I420 into
// IOSurface-backed NV12 drawn from a bounded CVPixelBufferPool. NV12 rather
// than the planar y420 CoreVideo also accepts (measured: an
// AVSampleBufferDisplayLayer displays both correctly, and the 3-plane copy is
// ~2.5 us/frame cheaper at 1080p) because NV12 is the only 4:2:0 layout every
// one of WAM's presentation routes can sample -- the Metal and OpenGL items
// and metal_layer_presenter all hard-assume two planes.
class SoftwareVp8Decoder final : public VideoDecodeBackend {
public:
  explicit SoftwareVp8Decoder(VideoToolboxDecoderOptions options = {});
  ~SoftwareVp8Decoder() override;

  SoftwareVp8Decoder(const SoftwareVp8Decoder &) = delete;
  SoftwareVp8Decoder &operator=(const SoftwareVp8Decoder &) = delete;
  SoftwareVp8Decoder(SoftwareVp8Decoder &&) = delete;
  SoftwareVp8Decoder &operator=(SoftwareVp8Decoder &&) = delete;

  [[nodiscard]] bool configure(const VideoStreamConfiguration &configuration,
                               DecodedFrameSink &sink,
                               std::string *error) override;
  [[nodiscard]] VideoDecodeSubmitResult
  submit(const CompressedVideoPacket &packet, std::string *error) override;
  [[nodiscard]] VideoDecodeSubmitResult
  submitCMSampleBuffer(CMSampleBufferRef sample, std::uint64_t generation,
                       std::string *error);

  [[nodiscard]] VideoDecodeDrainProgress
  beginEndOfStream(std::uint64_t generation, std::string *error);
  [[nodiscard]] VideoDecodeDrainProgress
  drainPresentation(std::uint64_t generation, std::string *error);
  [[nodiscard]] VideoDecodeDrainProgress
  drainEndOfStream(std::uint64_t generation, std::string *error);
  void flush(std::uint64_t nextGeneration) noexcept override;
  [[nodiscard]] VideoDecoderRetireProgress
  retire(std::uint64_t retiredGeneration,
         std::uint64_t invalidationGeneration) noexcept;
  void close() noexcept override;

  [[nodiscard]] VideoToolboxDecoderStats stats() const noexcept;
  [[nodiscard]] VideoToolboxDecoderMemoryFacts memoryFacts() const noexcept;
  [[nodiscard]] std::optional<std::string> takeLastError();

  // True when this build linked libvpx. When false, configure() always fails
  // and the admission sites never name VP8, so a source falls back instead.
  [[nodiscard]] static bool available() noexcept;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#if defined(WAM_SOFTWARE_VP8_TESTING)
// Fixture-free access to the two pieces that are pure functions of memory
// layout: the bounded pool and the I420 -> NV12 conversion. Absent from
// shipping objects.
struct SoftwareVp8DecoderTestAccess {
  // Creates the same bounded, IOSurface-backed NV12 pool production uses.
  // Returns nullptr on failure; the caller owns a +1 reference.
  [[nodiscard]] static CVPixelBufferPoolRef
  createPool(std::int32_t width, std::int32_t height, std::size_t depth,
             std::string *error);
  // Exactly the production conversion, against caller-owned planar input.
  // Returns false when the destination is not a two-plane NV12 buffer of the
  // stated size.
  [[nodiscard]] static bool
  convertI420ToNv12(CVPixelBufferRef destination, const std::uint8_t *y,
                    std::size_t yStride, const std::uint8_t *u,
                    std::size_t uStride, const std::uint8_t *v,
                    std::size_t vStride, std::size_t width,
                    std::size_t height) noexcept;
};
#endif

} // namespace wam::macos
