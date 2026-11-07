#pragma once

#include "native_video_presenter.hpp"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <type_traits>

namespace wam::macos {

// The decoder boundary: what a decoder is configured with, and the sink it
// delivers decoded frames to.
struct VideoStreamConfiguration {
  CMVideoCodecType codec{0};
  CMVideoDimensions codedSize{0, 0};
  std::span<const std::byte> codecConfiguration{};
  bool preferHardwareDecode{true};
  bool requireHardwareDecode{false};
  std::uint64_t generation{0};
  // True when the stream's transfer function is PQ (ST 2084) or HLG, i.e.
  // when the decoded surface must be presented through the system's HDR path
  // rather than as SDR.
  //
  // The decode OUTPUT DEPTH is what switches that path on, and the coded depth
  // is not the same question: an 8-bit BT.2020/PQ H.264 stream decodes to an
  // 8-bit `420v` surface that carries every correct colour attachment --
  // primaries, transfer, and a resolved "Rec. ITU-R BT.2100 PQ" CGColorSpace --
  // and AVSampleBufferDisplayLayer still presents it as SDR. The tag is not
  // what engages the HDR path; a >=10-bit surface is. So an HDR-tagged 8-bit
  // stream asks VideoToolbox for a 10-bit output surface and is presented
  // correctly. 8-bit yuv420p tagged bt2020nc/bt2020/smpte2084 is a common
  // shape, not an edge case.
  bool highDynamicRangeTransfer{false};

  // The colour description the session's format description must carry, as
  // the CoreMedia extension values, or nullptr for "write no key" -- see
  // applyColorExtensions() in native_video_color.hpp, which is where these
  // come from.
  //
  // Why the DECODER needs them and the sample buffer's own description is not
  // enough. createFormatDescription() reconstructs its description from the
  // codec configuration atom alone, and that is the description
  // VTDecompressionSessionCreate is called with. adoptDirectFormatLocked()
  // does swap in a directly submitted sample's richer description -- but only
  // when the live session cannot already accept it, so for a codec whose
  // acceptance test is lenient the colr-less reconstruction simply stays.
  //
  // With the colour on the sample buffer alone, 10-bit PQ HEVC in Matroska
  // renders as SDR. 8-bit PQ H.264 comes out right only because an HDR-tagged
  // 8-bit stream PINS its output format, and the pin routes every frame
  // through a pixel transfer that re-tags it. Carrying the colour here fixes
  // the class directly instead of relying on a side effect of the pin.
  CFStringRef colorPrimaries{nullptr};
  CFStringRef transferFunction{nullptr};
  CFStringRef ycbcrMatrix{nullptr};
  // Container-resolved range. Absent for isolated codec-record callers;
  // MPEG-4 Visual in particular has no VOL field carrying this information.
  std::optional<bool> fullRangeVideo;
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
// enqueue() inline before a submission returns even when asynchronous decode was
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


// The contract every video decode backend (VideoToolboxDecoder,
// SoftwareVp8Decoder, SoftwareAvcodecVideoDecoder) implements for
// VideoDecodeLane, so the consumer and the preview lane drive all of them
// identically:
//
// - configure() flushes the sink to the configured generation. Until the
//   first key frame after configure or flush, a non-key submission is
//   Rejected with an error; it is never decoded against a retired reference
//   set.
// - Every Rejected submission and Failed drain carries a diagnostic, and the
//   first one is also latched for takeLastError(), which hands it over once.
// - beginEndOfStream() never drains a presentation frame and is idempotent:
//   once begun, repeated calls report the current progress without starting
//   the lifecycle again.
// - retire() is idempotent for its first valid (retired, invalidation) pair;
//   a different pair is StaleGeneration. Once retired, flush() and close()
//   are inert.
// Selects the zero-copy GPU import contract requested from CoreVideo. OpenGL
// adds CGL IOSurface texture compatibility while retaining Metal compatibility,
// so the Qt GL presenter and the preview lane share the decoded-frame
// ownership contract.
//
// DisplayLayer is for presenters that hand the decoded surface straight to a
// CoreAnimation display layer and never sample it from this process. That
// contract is what lets the decoder stop pinning its output pixel format.
// Measured on an M3 Max (macOS 26.3.1): the AVD block natively produces
// AGX lossless-compressed biplanar surfaces ('&8v0'), and pinning the
// uncompressed '420v' fourcc makes VideoToolbox run a VTPixelTransferSession
// through IOSurfaceAcceleratorTransformSurface over *every decoded frame* --
// which cost WAM's VTDecoderXPCService 5.60 % of one core against QuickTime's
// 2.77 % for the same clip. Metal and OpenGL keep the pin because an
// in-process sampler cannot read a lossless surface; a display layer can.
enum class VideoDecoderOutputInterop : std::uint8_t {
  Metal,
  OpenGL,
  DisplayLayer,
};

// Owner-driven presentation/EOS progress. Progress means one frame was
// accepted by the sink or one bounded lifecycle transition completed, so the
// owner should continue its state machine without a timer. Quiescing
// means this call could not present a frame: it may be waiting for an
// outstanding callback, sink credit, or enough decoded frames to cross the
// codec reorder floor. `stats().acceptsCompressedSample` tells the owner
// whether to feed another access unit in the last case. Callback edges are
// published through the progress handler; sink credit uses the sink/output's
// shared owner wake. Done is
// returned only after every ordered tail frame has been accepted by the sink
// and the sink has received its generation-matching end marker.
enum class VideoDecodeDrainProgress : std::uint8_t {
  Done,
  Progress,
  Quiescing,
  StaleGeneration,
  Failed,
};

enum class VideoDecoderRetireProgress : std::uint8_t {
  Done,
  StaleGeneration,
  Failed,
};

// Allocation-free edge notification used by WAM's media owner to retry work
// when asynchronous decode capacity or lifecycle state changes. `function`
// may run on a VideoToolbox callback thread or synchronously inside
// submitCMSampleBuffer(), flush(), retire(), or close(); it must not block, allocate, throw, or
// re-enter this decoder. `context` must remain valid until retire()/close() has
// returned Done. The decoder snapshots this pair at construction, and the
// callback-owned state retains that immutable snapshot until every
// VideoToolbox callback has retired.
struct VideoDecoderProgressHandler {
  using Function = void (*)(void *context) noexcept;

  Function function{nullptr};
  void *context{nullptr};
};

struct VideoDecoderOptions {
  // Counts frames accepted by VideoToolbox whose output has not yet been
  // retired in submission order. This deliberately includes callbacks that
  // completed out of order, so callback scheduling cannot bypass the bound.
  // submitCMSampleBuffer() returns typed backpressure before reading the
  // compressed payload when this bound is reached.
  std::size_t maxInFlightFrames{3};
  // Hard ceiling for the codec-derived presentation reorder depth. configure()
  // rejects a stream whose SPS DECLARES a depth above this, allowing the caller
  // to fall back without silently corrupting presentation order; an INFERRED
  // depth above it is clamped to it instead. See CodecReorderDepthOrigin.
  std::size_t maxPendingPresentationFrames{8};
  // Metal is only the default; production constructs OpenGL (the GL presenter
  // and the preview lane) or DisplayLayer (the layer presenter). OpenGL
  // additionally guarantees CGLTexImageIOSurface2D-compatible IOSurfaces and
  // validates the exact two-plane NV12/P010 layout before delivery.
  VideoDecoderOutputInterop outputInterop{VideoDecoderOutputInterop::Metal};
  VideoDecoderProgressHandler progressHandler{};
};

struct VideoDecoderStats {
  bool configured{false};
  bool usingHardwareAcceleratedDecoder{false};
  bool awaitingKeyFrame{true};
  std::size_t maxInFlightFrames{0};
  std::size_t inFlightFrames{0};
  std::size_t retainedPresentationFrames{0};
  bool acceptsCompressedSample{false};
  std::size_t codecReorderFrames{0};
  std::uint64_t generation{0};
  std::uint64_t submittedFrames{0};
  // Accepted submissions whose compressed storage was supplied directly by
  // a retained CoreMedia sample buffer. This path performs no
  // application-level payload-sized copy.
  std::uint64_t directSampleBufferSubmissions{0};
  std::uint64_t directSampleBufferBytes{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t droppedFrames{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t sinkBackpressureRetries{0};
  // EOS tail backpressure is lossless: the decoder retains the canonical
  // ordered lease and retries it only when its owner calls drainEndOfStream().
  std::uint64_t endOfStreamBackpressureRetries{0};
  // Valid decoded IOSurfaces rejected by WAM's process-wide decoded-surface
  // count/byte budget. These become ordered no-frame completions rather than
  // reaching the sink or stalling a later submission behind their sequence.
  std::uint64_t surfaceBudgetRejections{0};
  std::uint64_t outOfOrderDrops{0};
  std::size_t pendingPresentationFrames{0};
  std::size_t peakPendingPresentationFrames{0};
  bool endOfStreamBegun{false};
  bool endOfStreamCallbacksFinalized{false};
  bool endOfStreamSinkNotified{false};
  VideoDecoderOutputInterop outputInterop{VideoDecoderOutputInterop::Metal};
  OSType requestedOutputPixelFormat{0};
  OSType actualOutputPixelFormat{0};
};

// Owner-thread snapshot of compressed storage retained by accepted decode
// submissions. Each byte belongs to exactly one stable frame-refcon slot until
// that slot returns to Available in submission order. Direct and copied are
// disjoint; current/peakCompressedBytes are their combined concurrent totals,
// not cumulative traffic counters.
struct VideoDecoderMemoryFacts {
  std::size_t inFlightFrames{0};
  std::size_t presentationFrames{0};
  std::uint64_t currentDirectCompressedBytes{0};
  std::uint64_t peakDirectCompressedBytes{0};
  std::uint64_t currentCopiedCompressedBytes{0};
  std::uint64_t peakCopiedCompressedBytes{0};
  std::uint64_t currentCompressedBytes{0};
  std::uint64_t peakCompressedBytes{0};
};
static_assert(std::is_trivially_copyable_v<VideoDecoderMemoryFacts>);

// A sample is a key frame unless its first attachment says NotSync; no
// attachment array at all conventionally means "sync sample".
[[nodiscard]] inline bool sampleIsSyncSample(CMSampleBufferRef sample) noexcept {
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    return true;
  }
  auto entry =
      static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  const void* notSync = nullptr;
  if (entry == nullptr ||
      !CFDictionaryGetValueIfPresent(entry, kCMSampleAttachmentKey_NotSync,
                                     &notSync) ||
      notSync == nullptr) {
    return true;
  }
  return !CFBooleanGetValue(static_cast<CFBooleanRef>(notSync));
}

}  // namespace wam::macos
