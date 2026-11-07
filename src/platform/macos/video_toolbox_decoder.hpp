#pragma once

#include "native_video_presenter.hpp"
#include "video_decoder_contract.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <type_traits>

namespace wam::macos {

#if defined(WAM_NATIVE_TEST_SEAMS)
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

// VideoToolbox decoder for every video codec the facts table names except VP8.
// Input samples must match the supplied codec configuration record
// (length-prefixed NAL units for avcC/hvcC); record-less codecs carry none.
// The configuration span is copied before configure() returns and is rejected
// above a fixed 256 KiB bound. Compressed input is a ready, single-access-unit
// CMSampleBuffer; the decoder retains the caller's compressed storage only for
// the duration required by VideoToolbox and performs no application-level
// payload copy. Decoded frames must exactly match the requested IOSurface-backed
// NV12/P010 format; VideoToolbox substitutions are treated as an asynchronous
// stream-contract error.
//
// The configured DecodedFrameSink must outlive this object or be retained until
// retire()/close() returns. retire(), close(), and flush() wait for every
// asynchronous callback and invalidate the VT session before returning.
class VideoToolboxDecoder final {
public:
  explicit VideoToolboxDecoder(VideoDecoderOptions options = {});
  ~VideoToolboxDecoder();

  VideoToolboxDecoder(const VideoToolboxDecoder &) = delete;
  VideoToolboxDecoder &operator=(const VideoToolboxDecoder &) = delete;
  VideoToolboxDecoder(VideoToolboxDecoder &&) = delete;
  VideoToolboxDecoder &operator=(VideoToolboxDecoder &&) = delete;

  [[nodiscard]] bool configure(const VideoStreamConfiguration &configuration,
                               DecodedFrameSink &sink,
                               std::string *error);
  // Zero-copy compressed ingress. `sample` must be a
  // ready, single-sample CMSampleBuffer whose block buffer is no larger than
  // 8 MiB. Its configuration atom must be nonempty, no larger than 256 KiB,
  // and byte-for-byte equal to the configured atom (an avcC may differ only
  // in its hint-only extension; record-less codecs carry none); compatible
  // direct formats reuse the configured VideoToolbox session and are not
  // retained as a second decoder-owned format description. The caller keeps
  // the +1 sample reference alive until this method returns and may release it
  // immediately afterward, including after Backpressure.
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
  // is signalled by VideoDecoderProgressHandler.
  [[nodiscard]] VideoDecodeDrainProgress
  drainEndOfStream(std::uint64_t generation, std::string *error);
  void flush(std::uint64_t nextGeneration) noexcept;
  // Synchronously retires the exact exposed generation without inventing a
  // successor. The first valid pair is immutable; exact retries are
  // idempotent and a different pair is stale and inert. Done proves every VT
  // callback and retained presentation lease is gone, the sink was flushed to
  // invalidationGeneration and detached, and stats().generation equals it.
  [[nodiscard]] VideoDecoderRetireProgress retire(
      std::uint64_t retiredGeneration,
      std::uint64_t invalidationGeneration) noexcept;
  void close() noexcept;

  [[nodiscard]] VideoDecoderStats stats() const noexcept;
  // Allocation-free and owner-thread confined. Callback-owned fields are
  // copied while holding the decoder's existing state lock; callers must not
  // sample this from a VideoToolbox callback or progress handler.
  [[nodiscard]] VideoDecoderMemoryFacts memoryFacts() const noexcept;
  [[nodiscard]] std::optional<std::string> takeLastError();

private:
#if defined(WAM_NATIVE_TEST_SEAMS)
  friend struct VideoToolboxDecoderTestAccess;
#endif
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#if defined(WAM_NATIVE_TEST_SEAMS)
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
  // Temporal processing is never enabled in either mode: Apple permits it to
  // retain frames indefinitely until EOS, defeating finite pre-EOS admission.
  static void setAsynchronousDecompression(VideoToolboxDecoder &decoder,
                                           bool enabled) noexcept;
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
      std::size_t compressedBytes = 0);
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
      VideoDecoderOutputInterop outputInterop, std::string *error);
  // The pure output-format admission predicate, with no surface required.
  // A decoded IOSurface cannot be manufactured in every form VideoToolbox
  // legitimately returns -- the lossless-compressed fourccs in particular are
  // decoder-only and CVPixelBufferCreate refuses them -- so the range/lossless
  // admission rule is pinned here directly.
  [[nodiscard]] static OSType requestedOutputFormat(
      const VideoStreamConfiguration& configuration) noexcept;
  [[nodiscard]] static bool admitsDecodedOutputPixelFormat(
      OSType pixelFormat, OSType expectedPixelFormat,
      VideoDecoderOutputInterop outputInterop) noexcept;
};
#endif

} // namespace wam::macos
