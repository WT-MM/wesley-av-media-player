#include "software_vp8_decoder.hpp"
#include "platform/macos/native_primitives.hpp"

#include "native_video_color.hpp"
#include "native_video_limits.hpp"
#include "software_presentation_pool.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <vector>

#if defined(WAM_ENABLE_SOFTWARE_VP8)
#include <vpx/vp8dx.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_image.h>
#endif


namespace wam::macos {
namespace {

// --------------------------------------------------------------------------
// Colour attachments.
// --------------------------------------------------------------------------

// VP8's bitstream states no colour description (RFC 6386 has exactly one
// colour space and no primaries or transfer syntax), and makeVideoDescriptor
// refuses any container Colour element that is not BT.709, so an admitted VP8
// track is either untagged or explicitly BT.709. Tagging with the presenters'
// own untagged default makes the CALayer and scene-graph routes agree.
CFDictionaryRef createColorAttachments(std::int32_t width,
                                       std::int32_t height) {
  const UntaggedSurfaceTags tags = untaggedSurfaceTags(
      static_cast<std::size_t>(width), static_cast<std::size_t>(height));
  const void *keys[] = {kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferColorPrimariesKey,
                        kCVImageBufferTransferFunctionKey};
  const void *values[] = {tags.matrix, tags.primaries, tags.transfer};
  return CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3,
                            &kCFTypeDictionaryKeyCallBacks,
                            &kCFTypeDictionaryValueCallBacks);
}

} // namespace

// --------------------------------------------------------------------------

struct SoftwareVp8Decoder::Impl {
  explicit Impl(VideoDecoderOptions opts) : options(opts) {}

  VideoDecoderOptions options;
  DecodedFrameSink *sink{nullptr};
  SoftwarePresentationPool pool;
  CFDictionaryRef colorAttachments{nullptr};
  std::optional<FrameLease> pending;
  std::optional<std::string> lastError;
  // One reused staging buffer for the rare non-contiguous CMBlockBuffer. The
  // Matroska factory always produces a contiguous block, so this stays empty
  // in production; it exists so a fragmented block cannot allocate per frame.
  std::vector<std::uint8_t> contiguous;

  std::int32_t width{0};
  std::int32_t height{0};
  std::uint64_t generation{0};
  bool configured{false};
  bool codecOpen{false};
  bool awaitingKeyFrame{true};
  enum class EndOfStream : std::uint8_t { Streaming, Begun, SinkNotified };
  EndOfStream endOfStream{EndOfStream::Streaming};
  // A retired decoder is never configured again.
  std::optional<VideoDecoderRetirement> retirement;

  std::uint64_t submittedFrames{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t droppedFrames{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t endOfStreamBackpressureRetries{0};
  std::uint64_t surfaceBudgetRejections{0};
  // Submissions refused because the bounded pool had no surface to vend.
  // Nonzero means the depth in software_vp8_decoder.hpp is paced tighter than
  // this machine's renderer retention; it costs a retry, never a frame.
  std::uint64_t poolBackpressure{0};
  std::uint64_t directSubmissions{0};
  std::uint64_t directBytes{0};
  std::uint64_t currentCompressedBytes{0};
  std::uint64_t peakCompressedBytes{0};

#if defined(WAM_ENABLE_SOFTWARE_VP8)
  vpx_codec_ctx_t codec{};
#endif

  void latch(const char *message, std::string *error) {
    assignError(error, message);
    if (!lastError.has_value()) {
      try {
        lastError.emplace(message);
      } catch (...) {
      }
    }
  }

  void releaseCodec() noexcept {
#if defined(WAM_ENABLE_SOFTWARE_VP8)
    if (codecOpen) {
      vpx_codec_destroy(&codec);
      codecOpen = false;
    }
#endif
  }

  void releasePool() noexcept {
    pool.close();
    if (colorAttachments != nullptr) {
      CFRelease(colorAttachments);
      colorAttachments = nullptr;
    }
  }

  ~Impl() {
    releaseCodec();
    releasePool();
  }
};

SoftwareVp8Decoder::SoftwareVp8Decoder(VideoDecoderOptions options)
    : impl_(std::make_unique<Impl>(options)) {}

SoftwareVp8Decoder::~SoftwareVp8Decoder() = default;

bool SoftwareVp8Decoder::available() noexcept {
#if defined(WAM_ENABLE_SOFTWARE_VP8)
  return true;
#else
  return false;
#endif
}

bool SoftwareVp8Decoder::configure(const VideoStreamConfiguration &configuration,
                                   DecodedFrameSink &sink,
                                   std::string *error) {
#if !defined(WAM_ENABLE_SOFTWARE_VP8)
  (void)configuration;
  (void)sink;
  impl_->latch("this build has no software VP8 decoder", error);
  return false;
#else
  Impl &impl = *impl_;
  if (impl.retirement || impl.configured) {
    impl.latch("software VP8 decoder is already configured", error);
    return false;
  }
  if (configuration.codec != kWamVideoCodecTypeVp8 ||
      configuration.generation == 0 || configuration.codedSize.width <= 0 ||
      configuration.codedSize.height <= 0) {
    impl.latch("software VP8 configuration is outside the stage contract",
               error);
    return false;
  }
  // libvpx needs no configuration record at all. The demuxer synthesizes a
  // vpcC from the proven key frame so VP8 stays inside the pipeline's
  // "nonempty and bounded" codec-configuration envelope; it is checked for
  // that envelope here and then deliberately not parsed.
  if (!native_video_limits::acceptsVideoCodecConfigurationSize(
          configuration.codecConfiguration.size())) {
    impl.latch("software VP8 configuration record is outside its bound", error);
    return false;
  }

  vpx_codec_dec_cfg_t config{};
  // One thread, and the reasoning is a measurement rather than an argument.
  // VP8's multithreaded decode parallelises across token partitions, and an
  // ordinary ffmpeg-muxed stream carries one, so over 1800 frames of
  // 1920x1080 the threads=1 and threads=2 arms measure identical: 1.69 and
  // 1.72 ms per frame, alternated, inside run-to-run noise.
  //
  // The decode runs synchronously on the dispatcher worker. That thread's
  // audio lane has 16 ring slabs (>= 370 ms at 44.1 kHz) of producer
  // headroom, which absorbs a 1.7 ms per-frame stall without an underrun
  // (0 clock underruns measured live across 60 s runs).
  config.threads = 1;
  config.w = static_cast<unsigned int>(configuration.codedSize.width);
  config.h = static_cast<unsigned int>(configuration.codedSize.height);
  const vpx_codec_err_t opened = vpx_codec_dec_init(
      &impl.codec, vpx_codec_vp8_dx(), &config, 0);
  if (opened != VPX_CODEC_OK) {
    impl.latch("libvpx refused to open a VP8 decoder", error);
    return false;
  }
  impl.codecOpen = true;

  if (!impl.pool.configure(configuration.codedSize.width,
                           configuration.codedSize.height,
                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) {
    impl.releaseCodec();
    impl.latch("software VP8 surface pool could not be created", error);
    return false;
  }
  impl.colorAttachments = createColorAttachments(configuration.codedSize.width,
                                                 configuration.codedSize.height);
  if (impl.colorAttachments == nullptr) {
    impl.releaseCodec();
    impl.releasePool();
    impl.latch("software VP8 colour attachments could not be built", error);
    return false;
  }

  impl.sink = &sink;
  impl.width = configuration.codedSize.width;
  impl.height = configuration.codedSize.height;
  impl.generation = configuration.generation;
  impl.configured = true;
  impl.awaitingKeyFrame = true;
  impl.endOfStream = Impl::EndOfStream::Streaming;
  impl.lastError.reset();
  sink.flush(configuration.generation);
  return true;
#endif
}

VideoDecodeSubmitResult
SoftwareVp8Decoder::submitCMSampleBuffer(CMSampleBufferRef sample,
                                         std::uint64_t generation,
                                         std::string *error) {
#if !defined(WAM_ENABLE_SOFTWARE_VP8)
  (void)sample;
  (void)generation;
  impl_->latch("this build has no software VP8 decoder", error);
  return VideoDecodeSubmitResult::Rejected;
#else
  Impl &impl = *impl_;
  if (!impl.configured || sample == nullptr) {
    impl.latch("software VP8 decoder cannot accept a sample", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  if (generation != impl.generation) {
    assignError(error, "software VP8 submission is stale");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl.endOfStream != Impl::EndOfStream::Streaming) {
    impl.latch("software VP8 decoder already began end of stream", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl.pending) {
    ++impl.backpressuredSubmissions;
    return VideoDecodeSubmitResult::Backpressure;
  }

  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  if (block == nullptr) {
    impl.latch("software VP8 sample carries no block buffer", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  const std::size_t total = CMBlockBufferGetDataLength(block);
  if (!native_video_limits::acceptsCompressedVideoAccessUnitSize(total)) {
    impl.latch("software VP8 access unit is outside its size bound", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  std::size_t lengthAtOffset = 0;
  char *pointer = nullptr;
  const OSStatus mapped = CMBlockBufferGetDataPointer(
      block, 0, &lengthAtOffset, nullptr, &pointer);
  const std::uint8_t *bytes = nullptr;
  if (mapped == kCMBlockBufferNoErr && pointer != nullptr &&
      lengthAtOffset >= total) {
    bytes = reinterpret_cast<const std::uint8_t *>(pointer);
  } else {
    // Fragmented block: stage into the reused member buffer. The capacity is
    // never released mid-stream, so this allocates at most once per open.
    try {
      if (impl.contiguous.size() < total) {
        impl.contiguous.resize(total);
      }
    } catch (...) {
      impl.latch("software VP8 staging buffer could not grow", error);
      return VideoDecodeSubmitResult::Rejected;
    }
    if (CMBlockBufferCopyDataBytes(block, 0, total, impl.contiguous.data()) !=
        kCMBlockBufferNoErr) {
      impl.latch("software VP8 access unit could not be made contiguous",
                 error);
      return VideoDecodeSubmitResult::Rejected;
    }
    bytes = impl.contiguous.data();
  }

  const bool keyFrame = sampleIsSyncSample(sample);
  if (impl.awaitingKeyFrame && !keyFrame) {
    // Without the key frame this decode began on, a delta frame would be
    // reconstructed against references that belong to a retired timeline.
    impl.latch("decoder requires a key frame after configure or flush", error);
    return VideoDecodeSubmitResult::Rejected;
  }

  // The pool buffer is taken BEFORE libvpx sees the packet. A VP8 delta frame
  // mutates the decoder's reference frames, so a packet that decoded and then
  // failed to find a surface could not simply be retried -- decoding it twice
  // would advance the reference state twice. Taking the surface first makes
  // exhaustion a pure, side-effect-free backpressure edge: the dispatcher
  // keeps the compressed sample in its lane and offers it again after the
  // output releases a surface.
  CVPixelBufferRef destination = impl.pool.acquire();
  if (destination == nullptr) {
    ++impl.poolBackpressure;
    ++impl.backpressuredSubmissions;
    return VideoDecodeSubmitResult::Backpressure;
  }

  const vpx_codec_err_t decoded =
      vpx_codec_decode(&impl.codec, bytes, static_cast<unsigned int>(total),
                       nullptr, 0);
  if (decoded != VPX_CODEC_OK) {
    CVPixelBufferRelease(destination);
    impl.latch("libvpx failed to decode a VP8 access unit", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  ++impl.submittedFrames;
  ++impl.directSubmissions;
  impl.directBytes += total;
  impl.currentCompressedBytes = total;
  impl.peakCompressedBytes =
      std::max(impl.peakCompressedBytes, impl.currentCompressedBytes);
  impl.awaitingKeyFrame = false;

  vpx_codec_iter_t iterator = nullptr;
  const vpx_image_t *image = vpx_codec_get_frame(&impl.codec, &iterator);
  impl.currentCompressedBytes = 0;
  if (image == nullptr) {
    // A VP8 access unit that produces no displayable picture is an invisible
    // alternate-reference frame. It is legal, carries no presentation of its
    // own, and is simply not shown.
    CVPixelBufferRelease(destination);
    ++impl.droppedFrames;
    return VideoDecodeSubmitResult::Accepted;
  }
  if (image->fmt != VPX_IMG_FMT_I420 ||
      static_cast<std::int32_t>(image->d_w) != impl.width ||
      static_cast<std::int32_t>(image->d_h) != impl.height) {
    CVPixelBufferRelease(destination);
    impl.latch("libvpx produced an unexpected VP8 image format", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  const int strides[3] = {image->stride[VPX_PLANE_Y],
                          image->stride[VPX_PLANE_U],
                          image->stride[VPX_PLANE_V]};
  const bool converted = copySoftwarePlanes(
      destination, image->planes, strides, static_cast<unsigned>(impl.width),
      static_cast<unsigned>(impl.height), 8, false);
  if (!converted) {
    CVPixelBufferRelease(destination);
    impl.latch("software VP8 frame could not be converted to NV12", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  CVBufferSetAttachments(destination, impl.colorAttachments,
                         kCVAttachmentMode_ShouldPropagate);

  FrameTiming timing{};
  timing.presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
  timing.duration = CMSampleBufferGetDuration(sample);
  timing.generation = generation;
  timing.keyFrame = keyFrame;
  FrameLease lease(destination, timing);
  CVPixelBufferRelease(destination);
  if (!lease) {
    // The only way a pool-vended IOSurface fails to lease is a refused
    // NativeSurfaceBudget admission, which is an ordered no-frame completion
    // rather than a stream error.
    ++impl.surfaceBudgetRejections;
    ++impl.droppedFrames;
    return VideoDecodeSubmitResult::Accepted;
  }
  impl.pending.emplace(std::move(lease));
  return VideoDecodeSubmitResult::Accepted;
#endif
}

VideoDecodeDrainProgress
SoftwareVp8Decoder::beginEndOfStream(std::uint64_t generation,
                                     std::string *error) {
  Impl &impl = *impl_;
  if (!impl.configured) {
    impl.latch("software VP8 decoder cannot begin end of stream", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (generation != impl.generation) {
    return VideoDecodeDrainProgress::StaleGeneration;
  }
  const bool first = impl.endOfStream == Impl::EndOfStream::Streaming;
  if (first) {
    impl.endOfStream = Impl::EndOfStream::Begun;
  }
  // libvpx holds nothing back: every displayable frame was produced by the
  // decode call that consumed its access unit, so an EOS with no pending
  // frame is already finished.
  if (!impl.pending) {
    return drainEndOfStream(generation, error);
  }
  return first ? VideoDecodeDrainProgress::Progress
               : VideoDecodeDrainProgress::Quiescing;
}

VideoDecodeDrainProgress
SoftwareVp8Decoder::drainPresentation(std::uint64_t generation,
                                      std::string *error) {
  Impl &impl = *impl_;
  if (!impl.configured) {
    impl.latch("software VP8 decoder cannot drain", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (generation != impl.generation) {
    return VideoDecodeDrainProgress::StaleGeneration;
  }
  if (!impl.pending) {
    return VideoDecodeDrainProgress::Quiescing;
  }
  if (impl.sink == nullptr) {
    impl.latch("software VP8 decoder has no sink", error);
    return VideoDecodeDrainProgress::Failed;
  }
  switch (impl.sink->enqueue(*impl.pending, error)) {
  case FrameEnqueueResult::Accepted:
    impl.pending.reset();
    ++impl.deliveredFrames;
    return VideoDecodeDrainProgress::Progress;
  case FrameEnqueueResult::Backpressure:
    return VideoDecodeDrainProgress::Quiescing;
  case FrameEnqueueResult::Rejected:
    impl.latch("decoded VP8 frame was rejected by the sink", error);
    return VideoDecodeDrainProgress::Failed;
  }
  impl.latch("decoded VP8 frame produced an unrecognised sink result", error);
  return VideoDecodeDrainProgress::Failed;
}

VideoDecodeDrainProgress
SoftwareVp8Decoder::drainEndOfStream(std::uint64_t generation,
                                     std::string *error) {
  Impl &impl = *impl_;
  if (!impl.configured) {
    impl.latch("software VP8 decoder cannot drain end of stream", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (generation != impl.generation) {
    return VideoDecodeDrainProgress::StaleGeneration;
  }
  if (impl.endOfStream == Impl::EndOfStream::Streaming) {
    impl.latch("software VP8 end-of-stream drain before it began", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (impl.pending) {
    const VideoDecodeDrainProgress progress =
        drainPresentation(generation, error);
    if (progress == VideoDecodeDrainProgress::Quiescing) {
      ++impl.endOfStreamBackpressureRetries;
    }
    return progress;
  }
  if (impl.sink == nullptr) {
    impl.latch("software VP8 decoder has no sink", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (impl.endOfStream != Impl::EndOfStream::SinkNotified) {
    impl.sink->endOfStream(generation);
    impl.endOfStream = Impl::EndOfStream::SinkNotified;
  }
  return VideoDecodeDrainProgress::Done;
}

void SoftwareVp8Decoder::flush(std::uint64_t nextGeneration) noexcept {
  Impl &impl = *impl_;
  if (impl.retirement) {
    return;
  }
  impl.pending.reset();
  impl.generation = nextGeneration;
  impl.awaitingKeyFrame = true;
  impl.endOfStream = Impl::EndOfStream::Streaming;
  impl.lastError.reset();
  impl.currentCompressedBytes = 0;
  if (impl.sink != nullptr) {
    impl.sink->flush(nextGeneration);
  }
}

VideoDecoderRetireProgress
SoftwareVp8Decoder::retire(std::uint64_t retiredGeneration,
                           std::uint64_t invalidationGeneration) noexcept {
  Impl &impl = *impl_;
  if (impl.retirement) {
    return impl.retirement->replay(retiredGeneration, invalidationGeneration);
  }
  if (retiredGeneration != impl.generation || invalidationGeneration == 0 ||
      invalidationGeneration <= retiredGeneration) {
    return retiredGeneration != impl.generation
               ? VideoDecoderRetireProgress::StaleGeneration
               : VideoDecoderRetireProgress::Failed;
  }
  impl.retirement =
      VideoDecoderRetirement{retiredGeneration, invalidationGeneration};
  impl.pending.reset();
  if (impl.sink != nullptr) {
    impl.sink->flush(invalidationGeneration);
    impl.sink = nullptr;
  }
  impl.generation = invalidationGeneration;
  impl.releaseCodec();
  impl.releasePool();
  impl.configured = false;
  impl.awaitingKeyFrame = true;
  impl.endOfStream = Impl::EndOfStream::Streaming;
  return VideoDecoderRetireProgress::Done;
}

void SoftwareVp8Decoder::close() noexcept {
  Impl &impl = *impl_;
  if (impl.retirement) {
    return;
  }
  if (!impl.configured && !impl.pool.configured() && !impl.codecOpen) {
    return;
  }
  const std::uint64_t retired = impl.generation + 1;
  impl.pending.reset();
  if (impl.sink != nullptr) {
    impl.sink->flush(retired);
    impl.sink = nullptr;
  }
  impl.generation = retired;
  impl.releaseCodec();
  impl.releasePool();
  impl.configured = false;
  impl.awaitingKeyFrame = true;
  impl.endOfStream = Impl::EndOfStream::Streaming;
}

VideoDecoderStats SoftwareVp8Decoder::stats() const noexcept {
  const Impl &impl = *impl_;
  VideoDecoderStats result;
  result.configured = impl.configured;
  // libvpx runs on this thread. Reporting hardware acceleration would be a
  // lie, and the telemetry that reads this field is what proves VP8 is the
  // software route.
  result.usingHardwareAcceleratedDecoder = false;
  result.awaitingKeyFrame = impl.awaitingKeyFrame;
  // The configured admission window, reported for the same reason
  // VideoToolboxDecoder reports its option: the consumer proves the value it
  // asked for came back. The real bound is acceptsCompressedSample below,
  // which is one synchronous frame.
  result.maxInFlightFrames = impl.options.maxInFlightFrames;
  result.inFlightFrames = 0;
  result.retainedPresentationFrames = impl.pending ? 1U : 0U;
  result.acceptsCompressedSample =
      impl.configured &&
      impl.endOfStream == Impl::EndOfStream::Streaming && !impl.pending;
  // VP8 has no B-frames and never displays an alternate-reference frame, so
  // decode order is presentation order and the reorder floor is zero -- the
  // same value deriveCodecReorderDepth() returns for VP9.
  result.codecReorderFrames = 0;
  result.generation = impl.generation;
  result.submittedFrames = impl.submittedFrames;
  result.directSampleBufferSubmissions = impl.directSubmissions;
  result.directSampleBufferBytes = impl.directBytes;
  result.deliveredFrames = impl.deliveredFrames;
  result.droppedFrames = impl.droppedFrames;
  result.backpressuredSubmissions = impl.backpressuredSubmissions;
  result.endOfStreamBackpressureRetries = impl.endOfStreamBackpressureRetries;
  result.surfaceBudgetRejections = impl.surfaceBudgetRejections;
  result.outOfOrderDrops = 0;
  result.pendingPresentationFrames = impl.pending ? 1U : 0U;
  result.peakPendingPresentationFrames = impl.pending ? 1U : 0U;
  result.endOfStreamBegun = impl.endOfStream != Impl::EndOfStream::Streaming;
  result.endOfStreamCallbacksFinalized = result.endOfStreamBegun;
  result.endOfStreamSinkNotified =
      impl.endOfStream == Impl::EndOfStream::SinkNotified;
  result.outputInterop = impl.options.outputInterop;
  result.requestedOutputPixelFormat =
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  result.actualOutputPixelFormat =
      impl.configured ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : 0;
  return result;
}

VideoDecoderMemoryFacts
SoftwareVp8Decoder::memoryFacts() const noexcept {
  const Impl &impl = *impl_;
  VideoDecoderMemoryFacts result;
  result.inFlightFrames = 0;
  result.presentationFrames = impl.pending ? 1U : 0U;
  result.currentDirectCompressedBytes = impl.currentCompressedBytes;
  result.peakDirectCompressedBytes = impl.peakCompressedBytes;
  result.currentCopiedCompressedBytes = 0;
  result.peakCopiedCompressedBytes = 0;
  result.currentCompressedBytes = impl.currentCompressedBytes;
  result.peakCompressedBytes = impl.peakCompressedBytes;
  return result;
}

std::optional<std::string> SoftwareVp8Decoder::takeLastError() {
  std::optional<std::string> result = std::move(impl_->lastError);
  impl_->lastError.reset();
  return result;
}


} // namespace wam::macos
