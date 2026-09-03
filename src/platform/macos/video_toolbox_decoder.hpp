#pragma once

#include "native_video_presenter.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <type_traits>

namespace wam::macos {

#if defined(WAM_NATIVE_VIDEO_TESTING)
struct VideoToolboxDecoderTestAccess;

// Test-only fault locations at the two callback-owned container insertion
// boundaries. Production builds neither expose nor evaluate these seams.
enum class VideoToolboxDecoderTestAllocationPoint : std::uint8_t {
  CompletedDecode,
  PendingPresentation,
};

// Test-only fault locations for the Core Foundation objects built while
// creating the format description and VideoToolbox session. Production builds
// call Core Foundation directly and do not contain this fault state.
enum class VideoToolboxDecoderTestCFAllocationPoint : std::uint8_t {
  CodecAtomData,
  CodecAtomsDictionary,
  FormatExtensionsDictionary,
  DecoderSpecificationDictionary,
  IOSurfacePropertiesDictionary,
  ImageAttributesDictionary,
  PixelFormatNumber,
};

struct VideoToolboxDecoderFrameRefConSlotStats {
  std::size_t capacity{0};
  std::size_t available{0};
  std::size_t reserved{0};
  std::size_t submitted{0};
  std::size_t callbackComplete{0};
  std::size_t inFlight{0};
  std::size_t activeCallbacks{0};
  std::uint64_t generation{0};
};
#endif

// Selects the zero-copy GPU import contract requested from CoreVideo. OpenGL
// adds CGL IOSurface texture compatibility while retaining Metal compatibility,
// so an opt-in native OpenGL presenter can fail back without changing the
// decoded-frame ownership contract.
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
enum class VideoToolboxOutputInterop : std::uint8_t {
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
// may run on a VideoToolbox callback thread or synchronously inside submit(),
// flush(), retire(), or close(); it must not block, allocate, throw, or
// re-enter this decoder. `context` must remain valid until retire()/close() has
// returned Done. The decoder snapshots this pair at construction, and the
// callback-owned state retains that immutable snapshot until every
// VideoToolbox callback has retired.
struct VideoToolboxDecoderProgressHandler {
  using Function = void (*)(void *context) noexcept;

  Function function{nullptr};
  void *context{nullptr};
};

// Where a stream's presentation-reorder depth came from. The two origins carry
// different authority, and configure()'s admission policy differs accordingly.
enum class CodecReorderDepthOrigin : std::uint8_t {
  // The stream states the depth outright, or the codec's reorder model is
  // fixed and needs no statement: H.264's VUI bitstream_restriction
  // max_num_reorder_frames, HEVC's sps_max_num_reorder_pics, av1C's initial
  // presentation delay, and the constant models of MPEG-2, MPEG-4 Part 2,
  // and VP9. A stream is entitled to every frame of a declared depth, so a
  // declared depth above the route's bound is a genuine refusal: honouring it
  // would overrun the decoded-surface budget, and clamping it would reorder
  // that stream's output.
  Declared,
  // Nothing in the stream states a depth, so the value is the ceiling the
  // specification infers in its place. For H.264 without bitstream_restriction
  // that is ISO/IEC 14496-10 E.2.1's inference, MaxDpbFrames for the level and
  // picture size -- what the stream COULD require, not what it does require.
  // The inference is blind to content: a screen recording with no B pictures
  // at all and max_num_ref_frames = 1 still infers the full DPB, and the
  // inference GROWS as the picture shrinks (MaxDpbMbs / PicSizeInMbs), so at
  // level 5.0 every stream under ~7 MP infers 5 or more. Refusing on that
  // inference sent whole classes of ordinary recordings to compatibility
  // playback, so configure() clamps an inferred depth to the route's bound
  // instead. Truth is still enforced exactly, one layer down: the ordered
  // drain's out-of-order check fails a stream closed the moment it actually
  // delivers a frame older than one already presented, so a clamp that was
  // too small can never present frames in the wrong order.
  Inferred,
};

// A stream's presentation-reorder depth together with the authority behind it.
struct CodecReorderDepth {
  std::size_t frames{0};
  CodecReorderDepthOrigin origin{CodecReorderDepthOrigin::Declared};

  friend constexpr bool operator==(const CodecReorderDepth &,
                                   const CodecReorderDepth &) = default;
};

struct VideoToolboxDecoderOptions {
  // Counts frames accepted by VideoToolbox whose output has not yet been
  // retired in submission order. This deliberately includes callbacks that
  // completed out of order, so callback scheduling cannot bypass the bound.
  // submit() returns typed backpressure before allocating or copying compressed
  // packet storage when this bound is reached.
  std::size_t maxInFlightFrames{3};
  // Hard ceiling for the codec-derived presentation reorder depth. configure()
  // rejects a stream whose SPS DECLARES a depth above this, allowing the caller
  // to fall back without silently corrupting presentation order; an INFERRED
  // depth above it is clamped to it instead. See CodecReorderDepthOrigin.
  std::size_t maxPendingPresentationFrames{8};
  // Metal is the established decoder output contract. The dormant OpenGL mode
  // additionally guarantees CGLTexImageIOSurface2D-compatible IOSurfaces and
  // validates the exact two-plane NV12/P010 layout before delivery.
  VideoToolboxOutputInterop outputInterop{VideoToolboxOutputInterop::Metal};
  VideoToolboxDecoderProgressHandler progressHandler{};
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
  // Accepted generic packet-span submissions. VideoToolboxDecoder must copy
  // these caller-owned bytes into a CoreMedia block before submit() returns.
  std::uint64_t copiedSpanSubmissions{0};
  std::uint64_t copiedSpanBytes{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t droppedFrames{0};
  std::uint64_t backpressuredSubmissions{0};
  // Retained for source compatibility with the former lossy callback path.
  // Owner-progressive delivery never increments this counter.
  std::uint64_t sinkBackpressureDrops{0};
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
  VideoToolboxOutputInterop outputInterop{VideoToolboxOutputInterop::Metal};
  OSType requestedOutputPixelFormat{0};
  OSType actualOutputPixelFormat{0};
};

// Owner-thread snapshot of compressed storage retained by accepted decode
// submissions. Each byte belongs to exactly one stable frame-refcon slot until
// that slot returns to Available in submission order. Direct and copied are
// disjoint; current/peakCompressedBytes are their combined concurrent totals,
// not cumulative traffic counters.
struct VideoToolboxDecoderMemoryFacts {
  std::size_t inFlightFrames{0};
  std::size_t presentationFrames{0};
  std::uint64_t currentDirectCompressedBytes{0};
  std::uint64_t peakDirectCompressedBytes{0};
  std::uint64_t currentCopiedCompressedBytes{0};
  std::uint64_t peakCopiedCompressedBytes{0};
  std::uint64_t currentCompressedBytes{0};
  std::uint64_t peakCompressedBytes{0};
};
static_assert(std::is_trivially_copyable_v<VideoToolboxDecoderMemoryFacts>);

// H.264/HEVC VideoToolbox decoder. Input packets must use the length-prefixed
// NAL representation described by the supplied avcC/hvcC configuration atom.
// Generic packet/configuration byte spans are copied before API calls return
// and are rejected above fixed 8 MiB / 256 KiB bounds. AVFoundation callers may
// instead submit a ready, single-access-unit CMSampleBuffer directly; that
// platform-specific path retains the caller's compressed storage only for the
// duration required by VideoToolbox and performs no application-level payload
// copy. Decoded frames must exactly match the requested IOSurface-backed
// NV12/P010 format; VideoToolbox substitutions are treated as an asynchronous
// stream-contract error.
//
// The configured DecodedFrameSink must outlive this object or be retained until
// retire()/close() returns. retire(), close(), and flush() wait for every
// asynchronous callback and invalidate the VT session before returning.
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
  // Platform-specific zero-copy ingress for AVAssetReader. `sample` must be a
  // ready, single-sample H.264/HEVC CMSampleBuffer whose block buffer is no
  // larger than 8 MiB. Its selected avcC/hvcC atom must be nonempty, no larger
  // than 256 KiB, and byte-for-byte equal to the configured atom; compatible
  // direct formats reuse the configured VideoToolbox session and are not
  // retained as a second decoder-owned format description. The caller keeps
  // the +1 sample reference alive until this method returns and may release it
  // immediately afterward, including after Backpressure. End-of-stream
  // remains expressed through submit().
  [[nodiscard]] VideoDecodeSubmitResult
  submitCMSampleBuffer(CMSampleBufferRef sample, std::uint64_t generation,
                       std::string *error);

  // Starts the exact generation's EOS lifecycle and asks VideoToolbox to emit
  // delayed output. This never drains a presentation frame. Once begun, new
  // compressed samples are rejected and repeated calls are idempotent.
  [[nodiscard]] VideoDecodeDrainProgress
  beginEndOfStream(std::uint64_t generation, std::string *error);

  // Delivers at most one currently presentable frame on the owner thread.
  // Before EOS, the codec reorder floor remains retained. After EOS, this is
  // equivalent to drainEndOfStream() and can eventually return Done. The sink
  // enqueue occurs synchronously inside this call and must not re-enter this
  // decoder.
  [[nodiscard]] VideoDecodeDrainProgress
  drainPresentation(std::uint64_t generation, std::string *error);

  // Performs at most one sink enqueue attempt. Backpressure retains the same
  // decoder-owned frame lease and returns Quiescing; the owner calls again
  // only after the sink/output's capacity wake. A callback-capacity transition
  // is signalled by VideoToolboxDecoderProgressHandler.
  [[nodiscard]] VideoDecodeDrainProgress
  drainEndOfStream(std::uint64_t generation, std::string *error);
  void flush(std::uint64_t nextGeneration) noexcept override;
  // Synchronously retires the exact exposed generation without inventing a
  // successor. The first valid pair is immutable; exact retries are
  // idempotent and a different pair is stale and inert. Done proves every VT
  // callback and retained presentation lease is gone, the sink was flushed to
  // invalidationGeneration and detached, and stats().generation equals it.
  [[nodiscard]] VideoDecoderRetireProgress retire(
      std::uint64_t retiredGeneration,
      std::uint64_t invalidationGeneration) noexcept;
  void close() noexcept override;

  [[nodiscard]] VideoToolboxDecoderStats stats() const noexcept;
  // Allocation-free and owner-thread confined. Callback-owned fields are
  // copied while holding the decoder's existing state lock; callers must not
  // sample this from a VideoToolbox callback or progress handler.
  [[nodiscard]] VideoToolboxDecoderMemoryFacts memoryFacts() const noexcept;
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
  // Test-only entry points into the same configuration and direct-sample
  // metadata admission used by production. They let fixture-free tests prove
  // oversized spans are rejected before their payload is read. A successful
  // copyFormatDescription() gives the caller a +1 reference.
  [[nodiscard]] static bool admitsConfigurationMetadata(
      const VideoStreamConfiguration &configuration) noexcept;
  [[nodiscard]] static bool copyFormatDescription(
      const VideoStreamConfiguration &configuration,
      CMVideoFormatDescriptionRef *descriptionOut, std::string *error);
  [[nodiscard]] static bool inspectDirectSampleMetadata(
      CMSampleBufferRef sample, std::size_t *dataLength,
      std::size_t *configurationLength, std::string *error);
  [[nodiscard]] static bool inspectDirectConfigurationExtensions(
      CMVideoCodecType codec, CFDictionaryRef extensions,
      std::size_t *configurationLength, std::string *error);
  [[nodiscard]] static bool equivalentFormatConfigurations(
      CMVideoFormatDescriptionRef configuredFormat,
      CMVideoFormatDescriptionRef directFormat, std::string *error);
  [[nodiscard]] static bool
  occupyInFlightCapacity(VideoToolboxDecoder &decoder, std::string *error);
  [[nodiscard]] static bool
  releaseInFlightCapacity(VideoToolboxDecoder &decoder, std::string *error);
  [[nodiscard]] static std::uint32_t
  decodeFlags(const VideoToolboxDecoder &decoder) noexcept;
  [[nodiscard]] static std::optional<std::size_t>
  codecReorderFrames(const VideoStreamConfiguration &configuration);
  // The same derivation with its authority intact. codecReorderFrames() above
  // is this value's `frames` half and stays for the callers that only need the
  // depth.
  [[nodiscard]] static std::optional<CodecReorderDepth>
  codecReorderDepth(const VideoStreamConfiguration &configuration);
  [[nodiscard]] static bool setPresentationReorderDepth(
      VideoToolboxDecoder &decoder, std::size_t reorderFrames,
      std::string *error);
  [[nodiscard]] static bool reserveInjectedSubmissions(
      VideoToolboxDecoder &decoder, std::size_t count, std::string *error);
  [[nodiscard]] static VideoDecodeSubmitResult reserveInjectedSubmission(
      VideoToolboxDecoder &decoder, FrameTiming timing,
      std::uint64_t *submissionSequence, std::string *error,
      std::size_t compressedBytes = 0,
      bool directCompressedStorage = false);
  [[nodiscard]] static bool rejectInjectedSubmission(
      VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
      std::int32_t decodeStatus, std::string *error);
  [[nodiscard]] static VideoToolboxDecoderFrameRefConSlotStats
  frameRefConSlotStats(const VideoToolboxDecoder &decoder) noexcept;
  [[nodiscard]] static bool prepareInjectedCallbacks(
      VideoToolboxDecoder &decoder, DecodedFrameSink &sink,
      std::uint64_t generation, std::string *error);
  [[nodiscard]] static bool injectDecodedFrame(
      VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
      CVPixelBufferRef pixelBuffer, FrameTiming timing, std::string *error);
  [[nodiscard]] static bool injectDecodedFrameResult(
      VideoToolboxDecoder &decoder, std::uint64_t submissionSequence,
      CVPixelBufferRef pixelBuffer, FrameTiming timing,
      std::int32_t callbackStatus, std::uint32_t callbackInfoFlags,
      std::string *error);
  // Nonblocking proof seam for progress-handler tests. Success means both
  // callback-owned mutexes were available and returns the credit visible at
  // the instant the handler ran.
  [[nodiscard]] static bool inspectProgressState(
      VideoToolboxDecoder &decoder, std::size_t *inFlight) noexcept;
  static void failNextCallbackAllocation(
      VideoToolboxDecoder &decoder,
      VideoToolboxDecoderTestAllocationPoint point) noexcept;
  static void failNextCFAllocation(
      VideoToolboxDecoderTestCFAllocationPoint point) noexcept;
  [[nodiscard]] static bool setPermitSyntheticOutputSurface(
      VideoToolboxDecoder &decoder, bool permit, std::string *error);
  [[nodiscard]] static bool validateDecodedColorAttachments(
      CVPixelBufferRef pixelBuffer, std::string *error);
  [[nodiscard]] static bool setSurfaceBudgetRejections(
      VideoToolboxDecoder &decoder, std::uint64_t count,
      std::string *error);
  [[nodiscard]] static bool validateOutputSurface(
      CVPixelBufferRef pixelBuffer, OSType expectedPixelFormat,
      VideoToolboxOutputInterop outputInterop, std::string *error);
  // The pure output-format admission predicate, with no surface required.
  // A decoded IOSurface cannot be manufactured in every form VideoToolbox
  // legitimately returns -- the lossless-compressed fourccs in particular are
  // decoder-only and CVPixelBufferCreate refuses them -- so the range/lossless
  // admission rule is pinned here directly.
  [[nodiscard]] static bool admitsDecodedOutputPixelFormat(
      OSType pixelFormat, OSType expectedPixelFormat,
      VideoToolboxOutputInterop outputInterop) noexcept;
};
#endif

} // namespace wam::macos
