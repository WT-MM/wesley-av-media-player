#include "software_wmv3_decoder.hpp"

#include "media/avcodec/library_directory.hpp"
#include "native_primitives.hpp"
#include "native_video_color.hpp"
#include "native_video_limits.hpp"
#include "software_presentation_pool.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <dlfcn.h>
#include <filesystem>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

// The C ABI of third_party/wam-wmcodecs/wmv3/wmv3dec.h, restated so this MIT
// file never includes or links the LGPL library.
struct Wmv3Frame {
  const std::uint8_t *data[3];
  int linesize[3];
  int width, height;
  int keyframe;
};
struct Wmv3Api {
  int (*sequenceSupported)(const std::uint8_t *, std::size_t){};
  void *(*open)(const std::uint8_t *, std::size_t, int, int){};
  void (*close)(void *){};
  int (*decode)(void *, const std::uint8_t *, std::size_t, Wmv3Frame *){};
};

constexpr const char *kWmv3Library = "libwam_wmv3.dylib";

// Loaded once and never unloaded. Like the libavformat stage, the library must
// sit in this image's own private library directory.
const Wmv3Api *loadWmv3() noexcept {
  static const Wmv3Api *const api = []() noexcept -> const Wmv3Api * {
    try {
      const auto libraries = media::avcodec::libraryDirectory(
          reinterpret_cast<const void *>(&loadWmv3));
      const auto path = libraries / kWmv3Library;
      if (!std::filesystem::is_regular_file(path) ||
          std::filesystem::canonical(path).parent_path() !=
              std::filesystem::canonical(libraries)) {
        return nullptr;
      }
      void *library = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
      if (library == nullptr) {
        return nullptr;
      }
      static Wmv3Api bound;
      bound.sequenceSupported = reinterpret_cast<decltype(bound.sequenceSupported)>(
          dlsym(library, "wmv3_sequence_supported"));
      bound.open = reinterpret_cast<decltype(bound.open)>(
          dlsym(library, "wmv3_decoder_open"));
      bound.close = reinterpret_cast<decltype(bound.close)>(
          dlsym(library, "wmv3_decoder_close"));
      bound.decode =
          reinterpret_cast<decltype(bound.decode)>(dlsym(library, "wmv3_decode"));
      if (!bound.sequenceSupported || !bound.open || !bound.close ||
          !bound.decode) {
        return nullptr;
      }
      return &bound;
    } catch (...) {
      return nullptr;
    }
  }();
  return api;
}

// The WMV3 bitstream states no colour description, so the surface carries the
// presenters' shared untagged default (BT.601 at SD, BT.709 above).
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

struct SoftwareWmv3Decoder::Impl {
  explicit Impl(VideoDecoderOptions opts) : options(opts) {}

  VideoDecoderOptions options;
  const Wmv3Api *api{nullptr};
  void *codec{nullptr};
  DecodedFrameSink *sink{nullptr};
  SoftwarePresentationPool pool;
  CFDictionaryRef colorAttachments{nullptr};
  std::optional<FrameLease> pending;
  std::optional<std::string> lastError;
  // Reused staging for a non-contiguous CMBlockBuffer; the libavformat source
  // always produces a contiguous one.
  std::vector<std::uint8_t> contiguous;
  // The decoder's current picture, valid while `codec` is open; a skipped
  // frame copies it again.
  Wmv3Frame picture{};
  bool havePicture{false};

  std::int32_t width{0};
  std::int32_t height{0};
  std::uint64_t generation{0};
  bool configured{false};
  bool awaitingKeyFrame{true};
  enum class EndOfStream : std::uint8_t { Streaming, Begun, SinkNotified };
  EndOfStream endOfStream{EndOfStream::Streaming};
  std::optional<VideoDecoderRetirement> retirement;

  std::uint64_t submittedFrames{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t droppedFrames{0};
  std::uint64_t backpressuredSubmissions{0};
  std::uint64_t endOfStreamBackpressureRetries{0};
  std::uint64_t surfaceBudgetRejections{0};
  std::uint64_t directSubmissions{0};
  std::uint64_t directBytes{0};
  std::uint64_t peakCompressedBytes{0};

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
    if (codec != nullptr) {
      api->close(codec);
      codec = nullptr;
    }
    havePicture = false;
  }

  void releasePool() noexcept {
    pool.close();
    if (colorAttachments != nullptr) {
      CFRelease(colorAttachments);
      colorAttachments = nullptr;
    }
  }

  // Leaves the stage unconfigured on `next` after invalidating the sink.
  void shutDown(std::uint64_t next) noexcept {
    pending.reset();
    if (sink != nullptr) {
      sink->flush(next);
      sink = nullptr;
    }
    generation = next;
    releaseCodec();
    releasePool();
    configured = false;
    awaitingKeyFrame = true;
    endOfStream = EndOfStream::Streaming;
  }

  ~Impl() {
    releaseCodec();
    releasePool();
  }
};

SoftwareWmv3Decoder::SoftwareWmv3Decoder(VideoDecoderOptions options)
    : impl_(std::make_unique<Impl>(options)) {}

SoftwareWmv3Decoder::~SoftwareWmv3Decoder() = default;

bool SoftwareWmv3Decoder::available() noexcept { return loadWmv3() != nullptr; }

bool SoftwareWmv3Decoder::supportsSequence(
    std::span<const std::byte> sequenceHeader) noexcept {
  const Wmv3Api *api = loadWmv3();
  return api != nullptr &&
         api->sequenceSupported(
             reinterpret_cast<const std::uint8_t *>(sequenceHeader.data()),
             sequenceHeader.size()) == 1;
}

bool SoftwareWmv3Decoder::configure(const VideoStreamConfiguration &configuration,
                                    DecodedFrameSink &sink, std::string *error) {
  Impl &impl = *impl_;
  if (impl.retirement || impl.configured) {
    impl.latch("software WMV3 decoder is already configured", error);
    return false;
  }
  if (configuration.codec != kWamVideoCodecTypeWmv3 ||
      configuration.generation == 0 || configuration.codedSize.width <= 0 ||
      configuration.codedSize.height <= 0 ||
      !native_video_limits::acceptsVideoCodecConfigurationSize(
          configuration.codecConfiguration.size())) {
    impl.latch("software WMV3 configuration is outside the stage contract",
               error);
    return false;
  }
  impl.api = loadWmv3();
  if (impl.api == nullptr) {
    impl.latch("the WMV3 decoder library is unavailable", error);
    return false;
  }
  const auto *header = reinterpret_cast<const std::uint8_t *>(
      configuration.codecConfiguration.data());
  if (impl.api->sequenceSupported(header,
                                  configuration.codecConfiguration.size()) != 1) {
    impl.latch("WMV3 sequence header enables a tool this decoder lacks", error);
    return false;
  }
  impl.codec = impl.api->open(header, configuration.codecConfiguration.size(),
                              configuration.codedSize.width,
                              configuration.codedSize.height);
  if (impl.codec == nullptr) {
    impl.latch("WMV3 decoder refused the stream geometry", error);
    return false;
  }
  if (!impl.pool.configure(configuration.codedSize.width,
                           configuration.codedSize.height,
                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) {
    impl.releaseCodec();
    impl.latch("software WMV3 surface pool could not be created", error);
    return false;
  }
  impl.colorAttachments = createColorAttachments(configuration.codedSize.width,
                                                 configuration.codedSize.height);
  if (impl.colorAttachments == nullptr) {
    impl.releaseCodec();
    impl.releasePool();
    impl.latch("software WMV3 colour attachments could not be built", error);
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
}

VideoDecodeSubmitResult
SoftwareWmv3Decoder::submitCMSampleBuffer(CMSampleBufferRef sample,
                                          std::uint64_t generation,
                                          std::string *error) {
  Impl &impl = *impl_;
  if (!impl.configured || sample == nullptr) {
    impl.latch("software WMV3 decoder cannot accept a sample", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  if (generation != impl.generation) {
    assignError(error, "software WMV3 submission is stale");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl.endOfStream != Impl::EndOfStream::Streaming) {
    impl.latch("software WMV3 decoder already began end of stream", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl.pending) {
    ++impl.backpressuredSubmissions;
    return VideoDecodeSubmitResult::Backpressure;
  }
  const bool keyFrame = sampleIsSyncSample(sample);
  if (impl.awaitingKeyFrame && !keyFrame) {
    impl.latch("decoder requires a key frame after configure or flush", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  if (block == nullptr) {
    impl.latch("software WMV3 sample carries no block buffer", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  const std::size_t total = CMBlockBufferGetDataLength(block);
  if (!native_video_limits::acceptsCompressedVideoAccessUnitSize(total)) {
    impl.latch("software WMV3 access unit is outside its size bound", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  std::size_t lengthAtOffset = 0;
  char *pointer = nullptr;
  const std::uint8_t *bytes = nullptr;
  if (CMBlockBufferGetDataPointer(block, 0, &lengthAtOffset, nullptr,
                                  &pointer) == kCMBlockBufferNoErr &&
      pointer != nullptr && lengthAtOffset >= total) {
    bytes = reinterpret_cast<const std::uint8_t *>(pointer);
  } else {
    try {
      if (impl.contiguous.size() < total) {
        impl.contiguous.resize(total);
      }
    } catch (...) {
      impl.latch("software WMV3 staging buffer could not grow", error);
      return VideoDecodeSubmitResult::Rejected;
    }
    if (CMBlockBufferCopyDataBytes(block, 0, total, impl.contiguous.data()) !=
        kCMBlockBufferNoErr) {
      impl.latch("software WMV3 access unit could not be made contiguous",
                 error);
      return VideoDecodeSubmitResult::Rejected;
    }
    bytes = impl.contiguous.data();
  }

  // The surface is taken before decoding: a decode advances the reference
  // picture, so exhaustion must be a side-effect-free backpressure edge.
  CVPixelBufferRef destination = impl.pool.acquire();
  if (destination == nullptr) {
    ++impl.backpressuredSubmissions;
    return VideoDecodeSubmitResult::Backpressure;
  }
  Wmv3Frame decoded{};
  const int result = impl.api->decode(impl.codec, bytes, total, &decoded);
  if (result < 0) {
    CVPixelBufferRelease(destination);
    impl.havePicture = false;
    impl.latch("WMV3 decoder failed to decode an access unit", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  if (result == 1) {
    impl.picture = decoded;
    impl.havePicture = true;
  }
  // A sync sample must be an I picture: anything else would be reconstructed
  // against the reference of a retired timeline.
  if (!impl.havePicture || (impl.awaitingKeyFrame && (result != 1 || !decoded.keyframe)) ||
      impl.picture.width != impl.width || impl.picture.height != impl.height) {
    CVPixelBufferRelease(destination);
    impl.latch("WMV3 key frame sample is not a decodable I picture", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  ++impl.submittedFrames;
  ++impl.directSubmissions;
  impl.directBytes += total;
  impl.peakCompressedBytes = std::max<std::uint64_t>(impl.peakCompressedBytes, total);
  impl.awaitingKeyFrame = false;

  if (!copySoftwarePlanes(destination, impl.picture.data, impl.picture.linesize,
                          static_cast<unsigned>(impl.width),
                          static_cast<unsigned>(impl.height), 8, false)) {
    CVPixelBufferRelease(destination);
    impl.latch("software WMV3 frame could not be converted to NV12", error);
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
    // A refused NativeSurfaceBudget admission: an ordered no-frame completion.
    ++impl.surfaceBudgetRejections;
    ++impl.droppedFrames;
    return VideoDecodeSubmitResult::Accepted;
  }
  impl.pending.emplace(std::move(lease));
  return VideoDecodeSubmitResult::Accepted;
}

VideoDecodeDrainProgress
SoftwareWmv3Decoder::beginEndOfStream(std::uint64_t generation,
                                      std::string *error) {
  Impl &impl = *impl_;
  if (!impl.configured) {
    impl.latch("software WMV3 decoder cannot begin end of stream", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (generation != impl.generation) {
    return VideoDecodeDrainProgress::StaleGeneration;
  }
  const bool first = impl.endOfStream == Impl::EndOfStream::Streaming;
  if (first) {
    impl.endOfStream = Impl::EndOfStream::Begun;
  }
  // Without B pictures every frame is produced by the decode that consumed
  // its access unit, so an EOS with no pending frame is already finished.
  if (!impl.pending) {
    return drainEndOfStream(generation, error);
  }
  return first ? VideoDecodeDrainProgress::Progress
               : VideoDecodeDrainProgress::Quiescing;
}

VideoDecodeDrainProgress
SoftwareWmv3Decoder::drainPresentation(std::uint64_t generation,
                                       std::string *error) {
  Impl &impl = *impl_;
  if (!impl.configured) {
    impl.latch("software WMV3 decoder cannot drain", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (generation != impl.generation) {
    return VideoDecodeDrainProgress::StaleGeneration;
  }
  if (!impl.pending) {
    return VideoDecodeDrainProgress::Quiescing;
  }
  switch (impl.sink->enqueue(*impl.pending, error)) {
  case FrameEnqueueResult::Accepted:
    impl.pending.reset();
    ++impl.deliveredFrames;
    return VideoDecodeDrainProgress::Progress;
  case FrameEnqueueResult::Backpressure:
    return VideoDecodeDrainProgress::Quiescing;
  case FrameEnqueueResult::Rejected:
    break;
  }
  impl.latch("decoded WMV3 frame was rejected by the sink", error);
  return VideoDecodeDrainProgress::Failed;
}

VideoDecodeDrainProgress
SoftwareWmv3Decoder::drainEndOfStream(std::uint64_t generation,
                                      std::string *error) {
  Impl &impl = *impl_;
  if (!impl.configured) {
    impl.latch("software WMV3 decoder cannot drain end of stream", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (generation != impl.generation) {
    return VideoDecodeDrainProgress::StaleGeneration;
  }
  if (impl.endOfStream == Impl::EndOfStream::Streaming) {
    impl.latch("software WMV3 end-of-stream drain before it began", error);
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
  if (impl.endOfStream != Impl::EndOfStream::SinkNotified) {
    impl.sink->endOfStream(generation);
    impl.endOfStream = Impl::EndOfStream::SinkNotified;
  }
  return VideoDecodeDrainProgress::Done;
}

void SoftwareWmv3Decoder::flush(std::uint64_t nextGeneration) noexcept {
  Impl &impl = *impl_;
  if (impl.retirement) {
    return;
  }
  impl.pending.reset();
  impl.generation = nextGeneration;
  impl.awaitingKeyFrame = true;
  impl.endOfStream = Impl::EndOfStream::Streaming;
  impl.lastError.reset();
  if (impl.sink != nullptr) {
    impl.sink->flush(nextGeneration);
  }
}

VideoDecoderRetireProgress
SoftwareWmv3Decoder::retire(std::uint64_t retiredGeneration,
                            std::uint64_t invalidationGeneration) noexcept {
  Impl &impl = *impl_;
  if (impl.retirement) {
    return impl.retirement->replay(retiredGeneration, invalidationGeneration);
  }
  if (retiredGeneration != impl.generation) {
    return VideoDecoderRetireProgress::StaleGeneration;
  }
  if (invalidationGeneration <= retiredGeneration) {
    return VideoDecoderRetireProgress::Failed;
  }
  impl.retirement =
      VideoDecoderRetirement{retiredGeneration, invalidationGeneration};
  impl.shutDown(invalidationGeneration);
  return VideoDecoderRetireProgress::Done;
}

void SoftwareWmv3Decoder::close() noexcept {
  Impl &impl = *impl_;
  if (impl.retirement ||
      (!impl.configured && !impl.pool.configured() && impl.codec == nullptr)) {
    return;
  }
  impl.shutDown(impl.generation + 1);
}

VideoDecoderStats SoftwareWmv3Decoder::stats() const noexcept {
  const Impl &impl = *impl_;
  VideoDecoderStats result;
  result.configured = impl.configured;
  result.usingHardwareAcceleratedDecoder = false;
  result.awaitingKeyFrame = impl.awaitingKeyFrame;
  result.maxInFlightFrames = impl.options.maxInFlightFrames;
  result.retainedPresentationFrames = impl.pending ? 1U : 0U;
  result.acceptsCompressedSample =
      impl.configured && impl.endOfStream == Impl::EndOfStream::Streaming &&
      !impl.pending;
  // B/BI pictures are refused at configure, so decode order is presentation
  // order.
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

VideoDecoderMemoryFacts SoftwareWmv3Decoder::memoryFacts() const noexcept {
  const Impl &impl = *impl_;
  VideoDecoderMemoryFacts result;
  result.presentationFrames = impl.pending ? 1U : 0U;
  // The decode is synchronous: no compressed bytes outlive a submission.
  result.peakDirectCompressedBytes = impl.peakCompressedBytes;
  result.peakCompressedBytes = impl.peakCompressedBytes;
  return result;
}

std::optional<std::string> SoftwareWmv3Decoder::takeLastError() {
  return std::exchange(impl_->lastError, std::nullopt);
}

} // namespace wam::macos
