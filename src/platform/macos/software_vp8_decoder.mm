#include "software_vp8_decoder.hpp"

#include "native_video_limits.hpp"

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

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define WAM_VP8_HAS_NEON 1
#endif

namespace wam::macos {
namespace {

void assignError(std::string *error, const char *message) {
  if (error != nullptr) {
    try {
      error->assign(message);
    } catch (...) {
      // The typed result is authoritative; the diagnostic string is optional.
    }
  }
}

// --------------------------------------------------------------------------
// Bounded, IOSurface-backed NV12 pool.
// --------------------------------------------------------------------------

CFDictionaryRef makeNumberDictionary(const void **keys, const std::int32_t *values,
                                     std::size_t count,
                                     const void *extraKey,
                                     CFTypeRef extraValue) {
  std::vector<CFTypeRef> cfValues;
  std::vector<const void *> cfKeys;
  try {
    cfValues.reserve(count + 1);
    cfKeys.reserve(count + 1);
  } catch (...) {
    return nullptr;
  }
  for (std::size_t index = 0; index < count; ++index) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault,
                                        kCFNumberSInt32Type, &values[index]);
    if (number == nullptr) {
      for (CFTypeRef value : cfValues) {
        CFRelease(value);
      }
      return nullptr;
    }
    cfValues.push_back(number);
    cfKeys.push_back(keys[index]);
  }
  bool ownsExtra = false;
  if (extraKey != nullptr && extraValue != nullptr) {
    cfKeys.push_back(extraKey);
    cfValues.push_back(extraValue);
    ownsExtra = true;
  }
  CFDictionaryRef dictionary = CFDictionaryCreate(
      kCFAllocatorDefault, cfKeys.data(), cfValues.data(),
      static_cast<CFIndex>(cfKeys.size()), &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  const std::size_t owned = ownsExtra ? cfValues.size() - 1 : cfValues.size();
  for (std::size_t index = 0; index < owned; ++index) {
    CFRelease(cfValues[index]);
  }
  return dictionary;
}

// The project's first CVPixelBufferPool. Depth is a hard cap rather than a
// hint: allocation goes through CVPixelBufferPoolCreatePixelBufferWithAux-
// Attributes with kCVPixelBufferPoolAllocationThresholdKey, so an accounting
// mistake surfaces as kCVReturnWouldExceedAllocationThreshold on the very next
// frame instead of as unbounded IOSurface growth behind NativeSurfaceBudget.
CVPixelBufferPoolRef createNv12Pool(std::int32_t width, std::int32_t height,
                                    std::size_t depth, std::string *error) {
  if (width <= 0 || height <= 0 || depth == 0) {
    assignError(error, "software VP8 pool geometry is invalid");
    return nullptr;
  }
  const std::int32_t poolKeysValues[] = {static_cast<std::int32_t>(depth)};
  const void *poolKeys[] = {kCVPixelBufferPoolMinimumBufferCountKey};
  CFDictionaryRef poolAttributes =
      makeNumberDictionary(poolKeys, poolKeysValues, 1, nullptr, nullptr);
  if (poolAttributes == nullptr) {
    assignError(error, "software VP8 pool attributes could not be built");
    return nullptr;
  }

  CFDictionaryRef ioSurfaceProperties =
      CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0,
                         &kCFTypeDictionaryKeyCallBacks,
                         &kCFTypeDictionaryValueCallBacks);
  if (ioSurfaceProperties == nullptr) {
    CFRelease(poolAttributes);
    assignError(error, "software VP8 IOSurface properties could not be built");
    return nullptr;
  }
  // 64-byte row alignment keeps every plane row NEON-aligned and matches what
  // VideoToolbox's own output surfaces use.
  const std::int32_t bufferValues[] = {
      static_cast<std::int32_t>(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      width, height, 64};
  const void *bufferKeys[] = {kCVPixelBufferPixelFormatTypeKey,
                              kCVPixelBufferWidthKey, kCVPixelBufferHeightKey,
                              kCVPixelBufferBytesPerRowAlignmentKey};
  CFDictionaryRef bufferAttributes =
      makeNumberDictionary(bufferKeys, bufferValues, 4,
                           kCVPixelBufferIOSurfacePropertiesKey,
                           ioSurfaceProperties);
  CFRelease(ioSurfaceProperties);
  if (bufferAttributes == nullptr) {
    CFRelease(poolAttributes);
    assignError(error, "software VP8 buffer attributes could not be built");
    return nullptr;
  }

  CVPixelBufferPoolRef pool = nullptr;
  const CVReturn status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault, poolAttributes, bufferAttributes, &pool);
  CFRelease(poolAttributes);
  CFRelease(bufferAttributes);
  if (status != kCVReturnSuccess || pool == nullptr) {
    assignError(error, "software VP8 pixel buffer pool could not be created");
    return nullptr;
  }
  return pool;
}

// Returns nullptr both for a genuine failure and for the bounded-depth
// refusal. The caller treats both as backpressure, because a decode stage that
// cannot obtain a surface right now has nothing to say beyond "not yet".
CVPixelBufferRef takeFromPool(CVPixelBufferPoolRef pool, std::size_t depth) {
  const std::int32_t threshold = static_cast<std::int32_t>(depth);
  CFNumberRef number =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &threshold);
  if (number == nullptr) {
    return nullptr;
  }
  const void *keys[] = {kCVPixelBufferPoolAllocationThresholdKey};
  const void *values[] = {number};
  CFDictionaryRef auxiliary = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFRelease(number);
  if (auxiliary == nullptr) {
    return nullptr;
  }
  CVPixelBufferRef buffer = nullptr;
  const CVReturn status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      kCFAllocatorDefault, pool, auxiliary, &buffer);
  CFRelease(auxiliary);
  if (status != kCVReturnSuccess || buffer == nullptr) {
    return nullptr;
  }
  return buffer;
}

// --------------------------------------------------------------------------
// I420 -> NV12.
// --------------------------------------------------------------------------

void copyPlaneRows(std::uint8_t *destination, std::size_t destinationStride,
                   const std::uint8_t *source, std::size_t sourceStride,
                   std::size_t width, std::size_t height) noexcept {
  if (destinationStride == sourceStride && destinationStride == width) {
    std::memcpy(destination, source, width * height);
    return;
  }
  for (std::size_t row = 0; row < height; ++row) {
    std::memcpy(destination + row * destinationStride,
                source + row * sourceStride, width);
  }
}

void interleaveChroma(std::uint8_t *destination, std::size_t destinationStride,
                      const std::uint8_t *u, std::size_t uStride,
                      const std::uint8_t *v, std::size_t vStride,
                      std::size_t width, std::size_t height) noexcept {
  for (std::size_t row = 0; row < height; ++row) {
    std::uint8_t *out = destination + row * destinationStride;
    const std::uint8_t *inU = u + row * uStride;
    const std::uint8_t *inV = v + row * vStride;
    std::size_t column = 0;
#if defined(WAM_VP8_HAS_NEON)
    for (; column + 16 <= width; column += 16) {
      uint8x16x2_t pair;
      pair.val[0] = vld1q_u8(inU + column);
      pair.val[1] = vld1q_u8(inV + column);
      vst2q_u8(out + 2 * column, pair);
    }
#endif
    for (; column < width; ++column) {
      out[2 * column] = inU[column];
      out[2 * column + 1] = inV[column];
    }
  }
}

[[nodiscard]] bool convertI420ToNv12(CVPixelBufferRef destination,
                                     const std::uint8_t *y,
                                     std::size_t yStride,
                                     const std::uint8_t *u,
                                     std::size_t uStride,
                                     const std::uint8_t *v,
                                     std::size_t vStride, std::size_t width,
                                     std::size_t height) noexcept {
  if (destination == nullptr || y == nullptr || u == nullptr || v == nullptr ||
      width == 0 || height == 0) {
    return false;
  }
  if (CVPixelBufferGetPixelFormatType(destination) !=
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      CVPixelBufferGetPlaneCount(destination) != 2 ||
      CVPixelBufferGetWidthOfPlane(destination, 0) != width ||
      CVPixelBufferGetHeightOfPlane(destination, 0) != height) {
    return false;
  }
  const std::size_t chromaWidth = (width + 1) / 2;
  const std::size_t chromaHeight = (height + 1) / 2;
  if (CVPixelBufferGetHeightOfPlane(destination, 1) != chromaHeight) {
    return false;
  }
  if (CVPixelBufferLockBaseAddress(destination, 0) != kCVReturnSuccess) {
    return false;
  }
  auto *luma = static_cast<std::uint8_t *>(
      CVPixelBufferGetBaseAddressOfPlane(destination, 0));
  auto *chroma = static_cast<std::uint8_t *>(
      CVPixelBufferGetBaseAddressOfPlane(destination, 1));
  const std::size_t lumaStride =
      CVPixelBufferGetBytesPerRowOfPlane(destination, 0);
  const std::size_t chromaStride =
      CVPixelBufferGetBytesPerRowOfPlane(destination, 1);
  bool ok = luma != nullptr && chroma != nullptr && lumaStride >= width &&
            chromaStride >= 2 * chromaWidth && yStride >= width &&
            uStride >= chromaWidth && vStride >= chromaWidth;
  if (ok) {
    copyPlaneRows(luma, lumaStride, y, yStride, width, height);
    interleaveChroma(chroma, chromaStride, u, uStride, v, vStride, chromaWidth,
                     chromaHeight);
  }
  CVPixelBufferUnlockBaseAddress(destination, 0);
  return ok;
}

// --------------------------------------------------------------------------
// Colour attachments.
// --------------------------------------------------------------------------

// VP8's bitstream states no colour description (RFC 6386 has exactly one
// colour space and no primaries or transfer syntax), and makeVideoDescriptor
// refuses any container Colour element that is not BT.709, so an admitted VP8
// track is either untagged or explicitly BT.709. This applies the same
// SD/HD convention metal_layer_presenter.mm already applies to an untagged
// surface, which is what makes the CALayer route and the Metal route agree on
// the same frame instead of each inventing its own default.
CFDictionaryRef createColorAttachments(std::int32_t width,
                                       std::int32_t height) {
  const bool standardDefinition = width <= 1024 && height <= 576;
  const void *keys[] = {kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferColorPrimariesKey,
                        kCVImageBufferTransferFunctionKey};
  const void *values[] = {
      standardDefinition
          ? static_cast<const void *>(kCVImageBufferYCbCrMatrix_ITU_R_601_4)
          : static_cast<const void *>(kCVImageBufferYCbCrMatrix_ITU_R_709_2),
      standardDefinition
          ? static_cast<const void *>(kCVImageBufferColorPrimaries_SMPTE_C)
          : static_cast<const void *>(kCVImageBufferColorPrimaries_ITU_R_709_2),
      standardDefinition
          ? static_cast<const void *>(kCVImageBufferTransferFunction_ITU_R_709_2)
          : static_cast<const void *>(
                kCVImageBufferTransferFunction_ITU_R_709_2)};
  return CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3,
                            &kCFTypeDictionaryKeyCallBacks,
                            &kCFTypeDictionaryValueCallBacks);
}

[[nodiscard]] bool sampleIsKeyFrame(CMSampleBufferRef sample) noexcept {
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    // No attachment array at all conventionally means "sync sample".
    return true;
  }
  auto entry = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  if (entry == nullptr) {
    return true;
  }
  const void *notSync = nullptr;
  if (!CFDictionaryGetValueIfPresent(entry, kCMSampleAttachmentKey_NotSync,
                                     &notSync) ||
      notSync == nullptr) {
    return true;
  }
  return !CFBooleanGetValue(static_cast<CFBooleanRef>(notSync));
}

} // namespace

// --------------------------------------------------------------------------

struct SoftwareVp8Decoder::Impl {
  explicit Impl(VideoToolboxDecoderOptions opts) : options(opts) {}

  VideoToolboxDecoderOptions options;
  DecodedFrameSink *sink{nullptr};
  CVPixelBufferPoolRef pool{nullptr};
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
  bool endOfStreamBegun{false};
  bool endOfStreamSinkNotified{false};
  bool retirementStarted{false};
  bool retirementDone{false};
  std::uint64_t retirementRetired{0};
  std::uint64_t retirementInvalidation{0};

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
    if (pool != nullptr) {
      CVPixelBufferPoolRelease(pool);
      pool = nullptr;
    }
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

SoftwareVp8Decoder::SoftwareVp8Decoder(VideoToolboxDecoderOptions options)
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
  if (impl.retirementStarted || impl.configured) {
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
  // ordinary ffmpeg-muxed stream carries one, so MEASURED 2026-08-20 over 1800
  // frames of 1920x1080 the threads=1 and threads=2 arms are identical: 1.69
  // and 1.72 ms per frame, alternated, inside run-to-run noise. A live-app
  // comparison did appear to favour threads=2 by 3-4 points of one core and
  // was rejected because the isolated arm disagreed and the difference sat
  // inside this machine's measured drift.
  //
  // The decode runs synchronously on the dispatcher worker. That thread's
  // audio lane has 16 ring slabs (>= 370 ms at 44.1 kHz) of producer
  // headroom, which absorbs a 1.7 ms per-frame stall without an underrun --
  // confirmed live at 0 clock underruns across every 60 s arm.
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

  impl.pool = createNv12Pool(configuration.codedSize.width,
                             configuration.codedSize.height,
                             kSoftwareVp8PoolDepth, error);
  if (impl.pool == nullptr) {
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
  impl.endOfStreamBegun = false;
  impl.endOfStreamSinkNotified = false;
  impl.lastError.reset();
  sink.flush(configuration.generation);
  return true;
#endif
}

VideoDecodeSubmitResult
SoftwareVp8Decoder::submit(const CompressedVideoPacket &packet,
                           std::string *error) {
  // The native lane only ever submits CoreMedia-owned VP8 access units. The
  // generic span entry point exists to satisfy VideoDecodeBackend and is
  // deliberately inert rather than a second, untested ingress.
  (void)packet;
  impl_->latch("software VP8 accepts only CoreMedia sample buffers", error);
  return VideoDecodeSubmitResult::Rejected;
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
  if (!impl.configured || impl.retirementStarted || sample == nullptr) {
    impl.latch("software VP8 decoder cannot accept a sample", error);
    return VideoDecodeSubmitResult::Rejected;
  }
  if (generation != impl.generation) {
    assignError(error, "software VP8 submission is stale");
    return VideoDecodeSubmitResult::Rejected;
  }
  if (impl.endOfStreamBegun) {
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

  const bool keyFrame = sampleIsKeyFrame(sample);
  if (impl.awaitingKeyFrame && !keyFrame) {
    // Same rule VideoToolboxDecoder applies after a flush: without the key
    // frame this decode began on, a delta frame would be reconstructed
    // against references that belong to a retired timeline.
    ++impl.droppedFrames;
    return VideoDecodeSubmitResult::Accepted;
  }

  // The pool buffer is taken BEFORE libvpx sees the packet. A VP8 delta frame
  // mutates the decoder's reference frames, so a packet that decoded and then
  // failed to find a surface could not simply be retried -- decoding it twice
  // would advance the reference state twice. Taking the surface first makes
  // exhaustion a pure, side-effect-free backpressure edge: the dispatcher
  // keeps the compressed sample in its lane and offers it again after the
  // output releases a surface.
  CVPixelBufferRef destination = takeFromPool(impl.pool, kSoftwareVp8PoolDepth);
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
  const bool converted = convertI420ToNv12(
      destination, image->planes[VPX_PLANE_Y],
      static_cast<std::size_t>(image->stride[VPX_PLANE_Y]),
      image->planes[VPX_PLANE_U],
      static_cast<std::size_t>(image->stride[VPX_PLANE_U]),
      image->planes[VPX_PLANE_V],
      static_cast<std::size_t>(image->stride[VPX_PLANE_V]),
      static_cast<std::size_t>(impl.width),
      static_cast<std::size_t>(impl.height));
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
  if (!impl.configured || impl.retirementStarted) {
    impl.latch("software VP8 decoder cannot begin end of stream", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (generation != impl.generation) {
    return VideoDecodeDrainProgress::StaleGeneration;
  }
  const bool first = !impl.endOfStreamBegun;
  impl.endOfStreamBegun = true;
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
  if (!impl.configured || impl.retirementStarted) {
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
  if (!impl.configured || impl.retirementStarted) {
    impl.latch("software VP8 decoder cannot drain end of stream", error);
    return VideoDecodeDrainProgress::Failed;
  }
  if (generation != impl.generation) {
    return VideoDecodeDrainProgress::StaleGeneration;
  }
  if (!impl.endOfStreamBegun) {
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
  if (!impl.endOfStreamSinkNotified) {
    impl.sink->endOfStream(generation);
    impl.endOfStreamSinkNotified = true;
  }
  return VideoDecodeDrainProgress::Done;
}

void SoftwareVp8Decoder::flush(std::uint64_t nextGeneration) noexcept {
  Impl &impl = *impl_;
  if (impl.retirementStarted) {
    return;
  }
  impl.pending.reset();
  impl.generation = nextGeneration;
  impl.awaitingKeyFrame = true;
  impl.endOfStreamBegun = false;
  impl.endOfStreamSinkNotified = false;
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
  if (impl.retirementStarted) {
    if (impl.retirementRetired != retiredGeneration ||
        impl.retirementInvalidation != invalidationGeneration) {
      return VideoDecoderRetireProgress::StaleGeneration;
    }
    return impl.retirementDone ? VideoDecoderRetireProgress::Done
                               : VideoDecoderRetireProgress::Failed;
  }
  if (retiredGeneration != impl.generation || invalidationGeneration == 0 ||
      invalidationGeneration <= retiredGeneration) {
    return retiredGeneration != impl.generation
               ? VideoDecoderRetireProgress::StaleGeneration
               : VideoDecoderRetireProgress::Failed;
  }
  impl.retirementStarted = true;
  impl.retirementRetired = retiredGeneration;
  impl.retirementInvalidation = invalidationGeneration;
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
  impl.endOfStreamBegun = false;
  impl.endOfStreamSinkNotified = false;
  impl.retirementDone = true;
  return VideoDecoderRetireProgress::Done;
}

void SoftwareVp8Decoder::close() noexcept {
  Impl &impl = *impl_;
  if (impl.retirementStarted) {
    return;
  }
  if (!impl.configured && impl.pool == nullptr && !impl.codecOpen) {
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
  impl.endOfStreamBegun = false;
  impl.endOfStreamSinkNotified = false;
}

VideoToolboxDecoderStats SoftwareVp8Decoder::stats() const noexcept {
  const Impl &impl = *impl_;
  VideoToolboxDecoderStats result;
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
      impl.configured && !impl.endOfStreamBegun && !impl.pending;
  // VP8 has no B-frames and never displays an alternate-reference frame, so
  // decode order is presentation order and the reorder floor is zero -- the
  // same value deriveCodecReorderFrameCount() returns for VP9.
  result.codecReorderFrames = 0;
  result.generation = impl.generation;
  result.submittedFrames = impl.submittedFrames;
  result.directSampleBufferSubmissions = impl.directSubmissions;
  result.directSampleBufferBytes = impl.directBytes;
  result.copiedSpanSubmissions = 0;
  result.copiedSpanBytes = 0;
  result.deliveredFrames = impl.deliveredFrames;
  result.droppedFrames = impl.droppedFrames;
  result.backpressuredSubmissions = impl.backpressuredSubmissions;
  result.endOfStreamBackpressureRetries = impl.endOfStreamBackpressureRetries;
  result.surfaceBudgetRejections = impl.surfaceBudgetRejections;
  result.outOfOrderDrops = 0;
  result.pendingPresentationFrames = impl.pending ? 1U : 0U;
  result.peakPendingPresentationFrames = impl.pending ? 1U : 0U;
  result.endOfStreamBegun = impl.endOfStreamBegun;
  result.endOfStreamCallbacksFinalized = impl.endOfStreamBegun;
  result.endOfStreamSinkNotified = impl.endOfStreamSinkNotified;
  result.outputInterop = impl.options.outputInterop;
  result.requestedOutputPixelFormat =
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  result.actualOutputPixelFormat =
      impl.configured ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : 0;
  return result;
}

VideoToolboxDecoderMemoryFacts
SoftwareVp8Decoder::memoryFacts() const noexcept {
  const Impl &impl = *impl_;
  VideoToolboxDecoderMemoryFacts result;
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

#if defined(WAM_SOFTWARE_VP8_TESTING)
CVPixelBufferPoolRef SoftwareVp8DecoderTestAccess::createPool(
    std::int32_t width, std::int32_t height, std::size_t depth,
    std::string *error) {
  return createNv12Pool(width, height, depth, error);
}

bool SoftwareVp8DecoderTestAccess::convertI420ToNv12(
    CVPixelBufferRef destination, const std::uint8_t *y, std::size_t yStride,
    const std::uint8_t *u, std::size_t uStride, const std::uint8_t *v,
    std::size_t vStride, std::size_t width, std::size_t height) noexcept {
  return wam::macos::convertI420ToNv12(destination, y, yStride, u, uStride, v,
                                       vStride, width, height);
}
#endif

} // namespace wam::macos
