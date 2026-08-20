// Fixture-free gate for the libvpx VP8 decode stage: the bounded surface
// pool, the I420 -> NV12 conversion, and the stage's own lifecycle contract.
//
// The decode arm needs a real VP8 bitstream, so it encodes one here with
// libvpx's own encoder rather than embedding a binary fixture: the test then
// proves the round trip end to end and stays readable.

#include "platform/macos/software_vp8_decoder.hpp"
#include "platform/macos/video_decode_lane.hpp"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <vpx/vp8cx.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vpx_image.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

namespace {

using wam::macos::DecodedFrameSink;
using wam::macos::FrameEnqueueResult;
using wam::macos::FrameLease;
using wam::macos::kSoftwareVp8DecoderOwnedSurfaces;
using wam::macos::kSoftwareVp8PoolDepth;
using wam::macos::kSoftwareVp8RendererRetainedSurfaces;
using wam::macos::kWamVideoCodecTypeVp8;
using wam::macos::SoftwareVp8Decoder;
using wam::macos::SoftwareVp8DecoderTestAccess;
using wam::macos::VideoDecodeDrainProgress;
using wam::macos::VideoDecodeLane;
using wam::macos::VideoDecodeSubmitResult;
using wam::macos::VideoDecoderRetireProgress;
using wam::macos::VideoStreamConfiguration;

int failures = 0;

void expect(bool condition, const char *what) {
  if (!condition) {
    ++failures;
    std::cerr << "FAIL: " << what << "\n";
  }
}

// ---------------------------------------------------------------------------
// Bounds that must hold at compile time.
// ---------------------------------------------------------------------------

// The consumer restates the ownership arithmetic against its own constants;
// these are the parts that stand on their own.
static_assert(kSoftwareVp8DecoderOwnedSurfaces == 1U,
              "libvpx decodes synchronously, so the stage holds exactly the "
              "one frame waiting for drainPresentation()");
static_assert(kSoftwareVp8RendererRetainedSurfaces >= 1U,
              "the renderer keeps a CoreVideo reference past WAM's last lease "
              "and the pool must provision for it");
static_assert(kSoftwareVp8PoolDepth <=
                  static_cast<std::size_t>(
                      wam::macos::kNativeSurfaceBudgetMaximumSurfaces),
              "the pool depth must fit the process-wide surface budget");
// NV12 is 1.5 bytes per pixel. A full pool at the renderer's 1080p working
// point must fit the process-wide byte budget with real headroom, because it
// is charged to the application, not to a decoder service.
static_assert(kSoftwareVp8PoolDepth * (1920ULL * 1080ULL * 3ULL / 2ULL) <
                  wam::macos::kNativeSurfaceBudgetMaximumBytes,
              "a full 1080p VP8 pool must fit the process-wide byte budget");
static_assert(kSoftwareVp8PoolDepth * (1920ULL * 1080ULL * 3ULL / 2ULL) ==
                  18662400ULL,
              "state the pool's 1080p footprint in bytes so a depth change "
              "has to restate it");
static_assert(kWamVideoCodecTypeVp8 == static_cast<CMVideoCodecType>('vp08'),
              "the VP8 carriage fourcc is the ISO binding's vp08");

// ---------------------------------------------------------------------------
// Test sink.
// ---------------------------------------------------------------------------

class CountingSink final : public DecodedFrameSink {
public:
  FrameEnqueueResult enqueue(FrameLease frame, std::string *error) override {
    if (!frame || frame.timing().generation != generation) {
      if (error != nullptr) {
        *error = "stale or invalid frame";
      }
      return FrameEnqueueResult::Rejected;
    }
    if (held) {
      return FrameEnqueueResult::Backpressure;
    }
    held.emplace(std::move(frame));
    ++accepted;
    return FrameEnqueueResult::Accepted;
  }
  void endOfStream(std::uint64_t value) override {
    if (value == generation) {
      ended = true;
    }
  }
  void flush(std::uint64_t next) noexcept override {
    held.reset();
    generation = next;
    ended = false;
    ++flushes;
  }

  std::optional<FrameLease> held;
  std::uint64_t generation{0};
  std::uint64_t accepted{0};
  std::uint64_t flushes{0};
  bool ended{false};
};

// ---------------------------------------------------------------------------
// Pool.
// ---------------------------------------------------------------------------

CVPixelBufferRef vendWithThreshold(CVPixelBufferPoolRef pool,
                                   std::size_t threshold) {
  const std::int32_t value = static_cast<std::int32_t>(threshold);
  CFNumberRef number =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
  const void *keys[] = {kCVPixelBufferPoolAllocationThresholdKey};
  const void *values[] = {number};
  CFDictionaryRef auxiliary = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFRelease(number);
  CVPixelBufferRef buffer = nullptr;
  const CVReturn status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      kCFAllocatorDefault, pool, auxiliary, &buffer);
  CFRelease(auxiliary);
  return status == kCVReturnSuccess ? buffer : nullptr;
}

void testPool() {
  std::string error;
  CVPixelBufferPoolRef pool =
      SoftwareVp8DecoderTestAccess::createPool(640, 360, kSoftwareVp8PoolDepth,
                                               &error);
  expect(pool != nullptr, "the bounded NV12 pool is created");
  if (pool == nullptr) {
    return;
  }

  std::vector<CVPixelBufferRef> held;
  for (std::size_t index = 0; index < kSoftwareVp8PoolDepth; ++index) {
    CVPixelBufferRef buffer = vendWithThreshold(pool, kSoftwareVp8PoolDepth);
    expect(buffer != nullptr, "the pool vends up to its full depth");
    if (buffer == nullptr) {
      break;
    }
    held.push_back(buffer);
  }
  expect(held.size() == kSoftwareVp8PoolDepth,
         "the pool vends exactly its depth before refusing");

  // The bound is hard, not advisory: the depth+1 request is refused rather
  // than served by growing the pool behind NativeSurfaceBudget's back.
  CVPixelBufferRef overflow = vendWithThreshold(pool, kSoftwareVp8PoolDepth);
  expect(overflow == nullptr, "the pool refuses beyond its bounded depth");
  if (overflow != nullptr) {
    CVPixelBufferRelease(overflow);
  }

  if (!held.empty()) {
    CVPixelBufferRef buffer = held.front();
    expect(CVPixelBufferGetIOSurface(buffer) != nullptr,
           "pool buffers are IOSurface-backed, so a FrameLease can charge "
           "them against the process-wide surface budget");
    expect(CVPixelBufferGetPixelFormatType(buffer) ==
               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
           "pool buffers are video-range NV12");
    expect(CVPixelBufferGetPlaneCount(buffer) == 2,
           "pool buffers are biplanar, which is what every WAM presentation "
           "route can sample");
    expect(CVPixelBufferGetWidth(buffer) == 640 &&
               CVPixelBufferGetHeight(buffer) == 360,
           "pool buffers carry the configured geometry");
    expect(CVPixelBufferGetWidthOfPlane(buffer, 1) == 320 &&
               CVPixelBufferGetHeightOfPlane(buffer, 1) == 180,
           "the chroma plane is half resolution in both axes");
    expect(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) % 64 == 0,
           "rows are 64-byte aligned");
  }

  // Releasing returns buffers to the pool, and the next vend recycles rather
  // than allocating: the same threshold that just refused now succeeds.
  for (CVPixelBufferRef buffer : held) {
    CVPixelBufferRelease(buffer);
  }
  CVPixelBufferRef recycled = vendWithThreshold(pool, kSoftwareVp8PoolDepth);
  expect(recycled != nullptr, "released buffers are recycled by the pool");
  if (recycled != nullptr) {
    CVPixelBufferRelease(recycled);
  }

  expect(SoftwareVp8DecoderTestAccess::createPool(0, 360,
                                                  kSoftwareVp8PoolDepth,
                                                  &error) == nullptr &&
             SoftwareVp8DecoderTestAccess::createPool(
                 640, 0, kSoftwareVp8PoolDepth, &error) == nullptr &&
             SoftwareVp8DecoderTestAccess::createPool(640, 360, 0, &error) ==
                 nullptr,
         "the pool refuses degenerate geometry and a zero depth");

  CVPixelBufferPoolRelease(pool);
}

// ---------------------------------------------------------------------------
// I420 -> NV12.
// ---------------------------------------------------------------------------

struct PlanarImage {
  std::vector<std::uint8_t> y;
  std::vector<std::uint8_t> u;
  std::vector<std::uint8_t> v;
  std::size_t width{0};
  std::size_t height{0};
  std::size_t yStride{0};
  std::size_t cStride{0};
};

// `padding` reproduces libvpx's own strided output, whose stride exceeds the
// visible width by an alignment border. A conversion that assumed stride ==
// width would pass on a packed image and corrupt every real decoded frame.
PlanarImage makeCheckerboard(std::size_t width, std::size_t height,
                             std::size_t padding) {
  PlanarImage image;
  image.width = width;
  image.height = height;
  image.yStride = width + padding;
  const std::size_t chromaWidth = (width + 1) / 2;
  const std::size_t chromaHeight = (height + 1) / 2;
  image.cStride = chromaWidth + padding;
  image.y.assign(image.yStride * height, 0xEE);
  image.u.assign(image.cStride * chromaHeight, 0xEE);
  image.v.assign(image.cStride * chromaHeight, 0xEE);
  for (std::size_t row = 0; row < height; ++row) {
    for (std::size_t column = 0; column < width; ++column) {
      image.y[row * image.yStride + column] =
          ((row / 8 + column / 8) % 2 == 0) ? 235 : 16;
    }
  }
  for (std::size_t row = 0; row < chromaHeight; ++row) {
    for (std::size_t column = 0; column < chromaWidth; ++column) {
      // Distinct, non-symmetric ramps: a U/V swap or an off-by-one interleave
      // shows up as an exact byte mismatch rather than as a plausible image.
      image.u[row * image.cStride + column] =
          static_cast<std::uint8_t>((row * 7 + column * 3) & 0xFF);
      image.v[row * image.cStride + column] =
          static_cast<std::uint8_t>(255 - ((row * 5 + column * 11) & 0xFF));
    }
  }
  return image;
}

PlanarImage makeGradient(std::size_t width, std::size_t height,
                         std::size_t padding) {
  PlanarImage image = makeCheckerboard(width, height, padding);
  for (std::size_t row = 0; row < height; ++row) {
    for (std::size_t column = 0; column < width; ++column) {
      image.y[row * image.yStride + column] =
          static_cast<std::uint8_t>((row * width + column) & 0xFF);
    }
  }
  return image;
}

void checkConversion(const PlanarImage &image, const char *what) {
  std::string error;
  CVPixelBufferPoolRef pool = SoftwareVp8DecoderTestAccess::createPool(
      static_cast<std::int32_t>(image.width),
      static_cast<std::int32_t>(image.height), 2, &error);
  expect(pool != nullptr, "conversion fixture pool is created");
  if (pool == nullptr) {
    return;
  }
  CVPixelBufferRef buffer = vendWithThreshold(pool, 2);
  expect(buffer != nullptr, "conversion fixture buffer is vended");
  if (buffer == nullptr) {
    CVPixelBufferPoolRelease(pool);
    return;
  }
  // Poison the destination so an incompletely written plane cannot pass by
  // accidentally already holding the right bytes.
  CVPixelBufferLockBaseAddress(buffer, 0);
  for (std::size_t plane = 0; plane < 2; ++plane) {
    std::memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 0x5A,
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) *
                    CVPixelBufferGetHeightOfPlane(buffer, plane));
  }
  CVPixelBufferUnlockBaseAddress(buffer, 0);

  const bool converted = SoftwareVp8DecoderTestAccess::convertI420ToNv12(
      buffer, image.y.data(), image.yStride, image.u.data(), image.cStride,
      image.v.data(), image.cStride, image.width, image.height);
  expect(converted, what);

  if (converted) {
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto *luma = static_cast<const std::uint8_t *>(
        CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
    const std::size_t lumaStride =
        CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    std::size_t lumaMismatches = 0;
    for (std::size_t row = 0; row < image.height; ++row) {
      for (std::size_t column = 0; column < image.width; ++column) {
        if (luma[row * lumaStride + column] !=
            image.y[row * image.yStride + column]) {
          ++lumaMismatches;
        }
      }
    }
    const auto *chroma = static_cast<const std::uint8_t *>(
        CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
    const std::size_t chromaStride =
        CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    const std::size_t chromaWidth = (image.width + 1) / 2;
    const std::size_t chromaHeight = (image.height + 1) / 2;
    std::size_t chromaMismatches = 0;
    for (std::size_t row = 0; row < chromaHeight; ++row) {
      for (std::size_t column = 0; column < chromaWidth; ++column) {
        const std::uint8_t expectedU = image.u[row * image.cStride + column];
        const std::uint8_t expectedV = image.v[row * image.cStride + column];
        if (chroma[row * chromaStride + 2 * column] != expectedU ||
            chroma[row * chromaStride + 2 * column + 1] != expectedV) {
          ++chromaMismatches;
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    expect(lumaMismatches == 0,
           "every luma byte survives the conversion exactly");
    expect(chromaMismatches == 0,
           "U and V land in the exact interleaved order NV12 requires");
  }

  CVPixelBufferRelease(buffer);
  CVPixelBufferPoolRelease(pool);
}

void testConversion() {
  // A packed source, a libvpx-shaped padded source, a NEON-tail width that is
  // not a multiple of 16 chroma samples, and odd dimensions where the chroma
  // plane rounds up.
  checkConversion(makeCheckerboard(64, 64, 0), "packed checkerboard converts");
  checkConversion(makeCheckerboard(1920, 1080, 32),
                  "a padded 1080p checkerboard converts");
  checkConversion(makeGradient(1920, 1080, 32),
                  "a padded 1080p gradient converts");
  checkConversion(makeCheckerboard(50, 34, 16),
                  "a width whose chroma row is not a NEON multiple converts");
  checkConversion(makeGradient(17, 9, 7),
                  "odd dimensions convert with a rounded-up chroma plane");

  // Contract refusals.
  std::string error;
  CVPixelBufferPoolRef pool =
      SoftwareVp8DecoderTestAccess::createPool(64, 64, 2, &error);
  if (pool != nullptr) {
    CVPixelBufferRef buffer = vendWithThreshold(pool, 2);
    const PlanarImage image = makeCheckerboard(64, 64, 0);
    expect(!SoftwareVp8DecoderTestAccess::convertI420ToNv12(
               buffer, image.y.data(), image.yStride, image.u.data(),
               image.cStride, image.v.data(), image.cStride, 128, 64),
           "a geometry mismatch is refused rather than written past the plane");
    expect(!SoftwareVp8DecoderTestAccess::convertI420ToNv12(
               nullptr, image.y.data(), image.yStride, image.u.data(),
               image.cStride, image.v.data(), image.cStride, 64, 64),
           "a null destination is refused");
    expect(!SoftwareVp8DecoderTestAccess::convertI420ToNv12(
               buffer, nullptr, image.yStride, image.u.data(), image.cStride,
               image.v.data(), image.cStride, 64, 64),
           "a null source plane is refused");
    expect(!SoftwareVp8DecoderTestAccess::convertI420ToNv12(
               buffer, image.y.data(), 16, image.u.data(), image.cStride,
               image.v.data(), image.cStride, 64, 64),
           "a source stride narrower than the width is refused");
    if (buffer != nullptr) {
      CVPixelBufferRelease(buffer);
    }
    CVPixelBufferPoolRelease(pool);
  }
}

// ---------------------------------------------------------------------------
// Stage contract, against a real libvpx-encoded VP8 stream.
// ---------------------------------------------------------------------------

struct EncodedStream {
  std::vector<std::vector<std::uint8_t>> frames;
  std::vector<bool> keyFrames;
  int width{0};
  int height{0};
};

// Encodes `count` frames of a moving pattern. The first is a key frame.
EncodedStream encodeVp8(int width, int height, int count) {
  EncodedStream stream;
  stream.width = width;
  stream.height = height;

  vpx_codec_enc_cfg_t config{};
  if (vpx_codec_enc_config_default(vpx_codec_vp8_cx(), &config, 0) !=
      VPX_CODEC_OK) {
    return stream;
  }
  config.g_w = static_cast<unsigned int>(width);
  config.g_h = static_cast<unsigned int>(height);
  config.g_timebase.num = 1;
  config.g_timebase.den = 30;
  config.rc_target_bitrate = 500;
  config.g_lag_in_frames = 0;
  config.kf_max_dist = 30;
  config.g_threads = 1;

  vpx_codec_ctx_t encoder{};
  if (vpx_codec_enc_init(&encoder, vpx_codec_vp8_cx(), &config, 0) !=
      VPX_CODEC_OK) {
    return stream;
  }
  vpx_image_t image{};
  if (vpx_img_alloc(&image, VPX_IMG_FMT_I420,
                    static_cast<unsigned int>(width),
                    static_cast<unsigned int>(height), 32) == nullptr) {
    vpx_codec_destroy(&encoder);
    return stream;
  }

  for (int index = 0; index <= count; ++index) {
    const bool flush = index == count;
    if (!flush) {
      for (int row = 0; row < height; ++row) {
        for (int column = 0; column < width; ++column) {
          image.planes[VPX_PLANE_Y][row * image.stride[VPX_PLANE_Y] + column] =
              static_cast<unsigned char>(((row + column + index * 16) / 16) % 2
                                             ? 200
                                             : 40);
        }
      }
      for (int row = 0; row < height / 2; ++row) {
        for (int column = 0; column < width / 2; ++column) {
          image.planes[VPX_PLANE_U][row * image.stride[VPX_PLANE_U] + column] =
              static_cast<unsigned char>(90 + index);
          image.planes[VPX_PLANE_V][row * image.stride[VPX_PLANE_V] + column] =
              static_cast<unsigned char>(160 - index);
        }
      }
    }
    if (vpx_codec_encode(&encoder, flush ? nullptr : &image, index, 1, 0,
                         VPX_DL_GOOD_QUALITY) != VPX_CODEC_OK) {
      break;
    }
    vpx_codec_iter_t iterator = nullptr;
    const vpx_codec_cx_pkt_t *packet = nullptr;
    while ((packet = vpx_codec_get_cx_data(&encoder, &iterator)) != nullptr) {
      if (packet->kind != VPX_CODEC_CX_FRAME_PKT) {
        continue;
      }
      const auto *bytes =
          static_cast<const std::uint8_t *>(packet->data.frame.buf);
      stream.frames.emplace_back(bytes, bytes + packet->data.frame.sz);
      stream.keyFrames.push_back(
          (packet->data.frame.flags & VPX_FRAME_IS_KEY) != 0);
    }
  }
  vpx_img_free(&image);
  vpx_codec_destroy(&encoder);
  return stream;
}

CMVideoFormatDescriptionRef makeVp8FormatDescription(int width, int height) {
  CMVideoFormatDescriptionRef description = nullptr;
  if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                     kWamVideoCodecTypeVp8, width, height,
                                     nullptr, &description) != noErr) {
    return nullptr;
  }
  return description;
}

CMSampleBufferRef makeSample(const std::vector<std::uint8_t> &bytes,
                             CMVideoFormatDescriptionRef description,
                             std::int64_t frameIndex, bool keyFrame) {
  CMBlockBufferRef block = nullptr;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr,
                                         bytes.size(), kCFAllocatorDefault,
                                         nullptr, 0, bytes.size(), 0,
                                         &block) != kCMBlockBufferNoErr) {
    return nullptr;
  }
  if (CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, bytes.size()) !=
      kCMBlockBufferNoErr) {
    CFRelease(block);
    return nullptr;
  }
  CMSampleTimingInfo timing{CMTimeMake(1, 30), CMTimeMake(frameIndex, 30),
                            kCMTimeInvalid};
  const std::size_t size = bytes.size();
  CMSampleBufferRef sample = nullptr;
  const OSStatus status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, description, 1, 1, &timing, 1, &size,
      &sample);
  CFRelease(block);
  if (status != noErr) {
    return nullptr;
  }
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
  if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
    auto entry = static_cast<CFMutableDictionaryRef>(
        const_cast<void *>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(entry, kCMSampleAttachmentKey_NotSync,
                         keyFrame ? kCFBooleanFalse : kCFBooleanTrue);
  }
  return sample;
}

VideoStreamConfiguration vp8Configuration(int width, int height,
                                          std::uint64_t generation,
                                          std::span<const std::byte> record) {
  VideoStreamConfiguration configuration;
  configuration.codec = kWamVideoCodecTypeVp8;
  configuration.codedSize = {width, height};
  configuration.codecConfiguration = record;
  configuration.generation = generation;
  return configuration;
}

void testStage() {
  constexpr int kWidth = 320;
  constexpr int kHeight = 176;
  const EncodedStream stream = encodeVp8(kWidth, kHeight, 6);
  expect(stream.frames.size() >= 4,
         "libvpx produced a multi-frame VP8 stream for the decode arm");
  if (stream.frames.size() < 4) {
    return;
  }
  expect(stream.keyFrames.front(), "the first encoded frame is a key frame");

  CMVideoFormatDescriptionRef description =
      makeVp8FormatDescription(kWidth, kHeight);
  expect(description != nullptr,
         "CoreMedia accepts the private vp08 four-character code");
  if (description == nullptr) {
    return;
  }
  expect(CMFormatDescriptionGetMediaSubType(description) ==
             kWamVideoCodecTypeVp8,
         "the format description reports vp08");

  // A 12-byte synthesized vpcC stands in for what the demuxer builds. Nothing
  // parses it; the stage only proves it is inside the bounded envelope.
  const std::array<std::byte, 12> record{};

  SoftwareVp8Decoder decoder;
  CountingSink sink;
  std::string error;

  expect(SoftwareVp8Decoder::available(),
         "this build linked libvpx, so the stage reports itself available");

  expect(!decoder.configure(vp8Configuration(kWidth, kHeight, 0, record), sink,
                            &error),
         "generation zero is refused");
  expect(!decoder.configure(vp8Configuration(0, kHeight, 7, record), sink,
                            &error),
         "a degenerate coded size is refused");
  {
    VideoStreamConfiguration wrongCodec =
        vp8Configuration(kWidth, kHeight, 7, record);
    wrongCodec.codec = kCMVideoCodecType_H264;
    expect(!decoder.configure(wrongCodec, sink, &error),
           "a non-VP8 codec type is refused by the VP8 stage");
  }
  {
    VideoStreamConfiguration emptyRecord =
        vp8Configuration(kWidth, kHeight, 7, {});
    expect(!decoder.configure(emptyRecord, sink, &error),
           "an empty codec-configuration record is outside the envelope");
  }

  expect(decoder.configure(vp8Configuration(kWidth, kHeight, 7, record), sink,
                           &error),
         "the stage configures on a well-formed VP8 stream");

  auto stats = decoder.stats();
  expect(stats.configured && stats.generation == 7,
         "configure publishes the exact generation");
  expect(!stats.usingHardwareAcceleratedDecoder,
         "the stage never claims hardware acceleration");
  expect(stats.codecReorderFrames == 0,
         "VP8 states a zero reorder floor, so decode order is presentation "
         "order");
  expect(stats.awaitingKeyFrame, "a fresh configure awaits a key frame");
  expect(stats.acceptsCompressedSample,
         "a fresh configure accepts a compressed sample");
  expect(stats.inFlightFrames == 0,
         "synchronous decode means there is never an in-flight submission");
  expect(stats.requestedOutputPixelFormat ==
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
             stats.actualOutputPixelFormat ==
                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         "the stage requests and delivers video-range NV12");
  expect(sink.flushes == 1 && sink.generation == 7,
         "configure flushes the sink to the configured generation");

  {
    wam::macos::CompressedVideoPacket packet;
    expect(decoder.submit(packet, &error) == VideoDecodeSubmitResult::Rejected,
           "the generic span ingress is inert; only CoreMedia samples decode");
    expect(decoder.takeLastError().has_value(),
           "a rejected submission records a diagnostic");
  }

  // A delta frame before any key frame is accepted and discarded rather than
  // decoded against a retired reference set.
  {
    CMSampleBufferRef sample =
        makeSample(stream.frames[1], description, 1, false);
    expect(decoder.submitCMSampleBuffer(sample, 7, &error) ==
               VideoDecodeSubmitResult::Accepted,
           "a delta frame before the first key frame is accepted");
    expect(decoder.stats().droppedFrames == 1,
           "and is counted as dropped rather than decoded");
    expect(decoder.drainPresentation(7, &error) ==
               VideoDecodeDrainProgress::Quiescing,
           "no frame becomes presentable from a discarded delta frame");
    CFRelease(sample);
  }

  // The key frame decodes, converts and reaches the sink.
  {
    CMSampleBufferRef sample =
        makeSample(stream.frames[0], description, 0, true);
    expect(decoder.submitCMSampleBuffer(sample, 7, &error) ==
               VideoDecodeSubmitResult::Accepted,
           "the key frame is accepted");
    stats = decoder.stats();
    expect(!stats.awaitingKeyFrame, "the key frame clears the awaiting gate");
    expect(stats.retainedPresentationFrames == 1 &&
               !stats.acceptsCompressedSample,
           "one decoded frame is retained and admission closes behind it");

    // Submitting again before the drain is backpressure, not loss.
    CMSampleBufferRef second =
        makeSample(stream.frames[1], description, 1, false);
    expect(decoder.submitCMSampleBuffer(second, 7, &error) ==
               VideoDecodeSubmitResult::Backpressure,
           "a second submission before the drain is typed backpressure");
    expect(decoder.stats().backpressuredSubmissions == 1,
           "backpressure is counted");

    expect(decoder.drainPresentation(7, &error) ==
               VideoDecodeDrainProgress::Progress,
           "the retained frame drains to the sink");
    expect(sink.accepted == 1 && sink.held.has_value(),
           "the sink received exactly one frame");
    if (sink.held) {
      const FrameLease &frame = *sink.held;
      expect(frame.width() == kWidth && frame.height() == kHeight,
             "the decoded frame carries the stream's coded dimensions");
      expect(frame.pixelFormat() ==
                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             "the decoded frame is video-range NV12");
      expect(frame.isIOSurfaceBacked(),
             "the decoded frame is IOSurface-backed, which every downstream "
             "surface contract requires");
      expect(frame.timing().generation == 7 && frame.timing().keyFrame,
             "frame timing carries the generation and the key-frame flag");
      expect(CMTimeCompare(frame.timing().presentationTime, kCMTimeZero) == 0 &&
                 CMTimeCompare(frame.timing().duration, CMTimeMake(1, 30)) == 0,
             "frame timing is the sample's own presentation time and "
             "duration");
      CFTypeRef matrix = CVBufferCopyAttachment(
          frame.pixelBuffer(), kCVImageBufferYCbCrMatrixKey, nullptr);
      expect(matrix != nullptr,
             "the decoded surface carries an explicit YCbCr matrix, so the "
             "CALayer and Metal routes cannot disagree about it");
      if (matrix != nullptr) {
        expect(CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4),
               "a standard-definition VP8 surface states BT.601");
        CFRelease(matrix);
      }
    }
    expect(decoder.stats().deliveredFrames == 1, "delivery is counted");
    expect(decoder.stats().acceptsCompressedSample,
           "admission reopens once the frame leaves the stage");
    CFRelease(second);
    CFRelease(sample);
  }

  // The rest of the encoded stream decodes in order, one frame per access
  // unit, with no reordering anywhere.
  {
    std::uint64_t delivered = decoder.stats().deliveredFrames;
    for (std::size_t index = 1; index < stream.frames.size(); ++index) {
      sink.held.reset();
      CMSampleBufferRef sample =
          makeSample(stream.frames[index], description,
                     static_cast<std::int64_t>(index), stream.keyFrames[index]);
      expect(decoder.submitCMSampleBuffer(sample, 7, &error) ==
                 VideoDecodeSubmitResult::Accepted,
             "every subsequent access unit is accepted");
      expect(decoder.drainPresentation(7, &error) ==
                 VideoDecodeDrainProgress::Progress,
             "every access unit yields exactly one presentable frame");
      if (sink.held) {
        expect(CMTimeCompare(sink.held->timing().presentationTime,
                             CMTimeMake(static_cast<std::int64_t>(index), 30)) ==
                   0,
               "frames are delivered in presentation order, which for VP8 is "
               "coded order");
      }
      ++delivered;
      CFRelease(sample);
    }
    expect(decoder.stats().deliveredFrames == delivered,
           "one delivered frame per submitted access unit");
  }

  // Stale generations are inert.
  {
    CMSampleBufferRef sample =
        makeSample(stream.frames[0], description, 0, true);
    expect(decoder.submitCMSampleBuffer(sample, 9, &error) ==
               VideoDecodeSubmitResult::Rejected,
           "a stale-generation submission is rejected");
    expect(decoder.drainPresentation(9, &error) ==
               VideoDecodeDrainProgress::StaleGeneration,
           "a stale-generation drain is stale, not failed");
    CFRelease(sample);
  }

  // Flush retires the pending frame and re-arms the key-frame gate.
  {
    sink.held.reset();
    CMSampleBufferRef sample =
        makeSample(stream.frames[1], description, 1, false);
    expect(decoder.submitCMSampleBuffer(sample, 7, &error) ==
               VideoDecodeSubmitResult::Accepted,
           "a frame is staged before the flush");
    decoder.flush(11);
    stats = decoder.stats();
    expect(stats.generation == 11 && stats.awaitingKeyFrame &&
               stats.retainedPresentationFrames == 0 &&
               stats.acceptsCompressedSample,
           "flush moves to the next generation, drops the pending frame and "
           "requires a fresh key frame");
    expect(sink.generation == 11 && !sink.held,
           "flush carries the sink to the next generation");
    CFRelease(sample);
  }

  // End of stream: libvpx holds nothing back, so an EOS with no pending frame
  // completes immediately and the sink is told exactly once.
  {
    CMSampleBufferRef sample =
        makeSample(stream.frames[0], description, 0, true);
    expect(decoder.submitCMSampleBuffer(sample, 11, &error) ==
               VideoDecodeSubmitResult::Accepted,
           "a key frame is accepted at the new generation");
    expect(decoder.beginEndOfStream(11, &error) ==
               VideoDecodeDrainProgress::Progress,
           "end of stream begins while a frame is still pending");
    expect(decoder.submitCMSampleBuffer(sample, 11, &error) ==
               VideoDecodeSubmitResult::Rejected,
           "no compressed sample is admitted after end of stream begins");
    sink.held.reset();
    expect(decoder.drainEndOfStream(11, &error) ==
               VideoDecodeDrainProgress::Progress,
           "the tail frame drains first");
    expect(decoder.drainEndOfStream(11, &error) ==
               VideoDecodeDrainProgress::Done,
           "the drain then completes");
    expect(sink.ended, "the sink received its generation-matching end marker");
    expect(decoder.drainEndOfStream(11, &error) ==
               VideoDecodeDrainProgress::Done,
           "the completed drain is idempotent");
    CFRelease(sample);
  }

  // Retirement.
  {
    expect(decoder.retire(11, 11) == VideoDecoderRetireProgress::Failed,
           "an invalidation generation that does not advance is refused");
    expect(decoder.retire(5, 12) == VideoDecoderRetireProgress::StaleGeneration,
           "retiring a generation the stage does not expose is stale");
    expect(decoder.retire(11, 12) == VideoDecoderRetireProgress::Done,
           "retirement completes");
    expect(decoder.retire(11, 12) == VideoDecoderRetireProgress::Done,
           "an exact retirement retry is idempotent");
    expect(decoder.retire(11, 13) ==
               VideoDecoderRetireProgress::StaleGeneration,
           "a different retirement pair after the first is stale");
    stats = decoder.stats();
    expect(!stats.configured && stats.generation == 12,
           "retirement clears configuration and publishes the invalidation "
           "generation");
    expect(sink.generation == 12,
           "retirement flushes the sink to the invalidation generation");
  }

  CFRelease(description);
}

// ---------------------------------------------------------------------------
// The lane selects once, at configure.
// ---------------------------------------------------------------------------

void testLane() {
  expect(VideoDecodeLane::softwareVp8Available(),
         "the lane reports software VP8 as available in this build");

  VideoDecodeLane lane;
  expect(!lane.usesSoftwareDecode(),
         "a lane that has never configured holds no software backend, so a "
         "session that never plays VP8 pays nothing for it");

  const EncodedStream stream = encodeVp8(320, 176, 1);
  if (stream.frames.empty()) {
    return;
  }
  CMVideoFormatDescriptionRef description = makeVp8FormatDescription(320, 176);
  if (description == nullptr) {
    return;
  }
  const std::array<std::byte, 12> record{};
  CountingSink sink;
  std::string error;
  expect(lane.configure(vp8Configuration(320, 176, 3, record), sink, &error),
         "the lane configures a VP8 stream");
  expect(lane.usesSoftwareDecode(),
         "and selects the software backend, once, at configure");
  expect(lane.stats().configured && lane.stats().generation == 3 &&
             !lane.stats().usingHardwareAcceleratedDecoder,
         "the lane forwards the software backend's stats verbatim");

  CMSampleBufferRef sample = makeSample(stream.frames[0], description, 0, true);
  expect(lane.submitCMSampleBuffer(sample, 3, &error) ==
             VideoDecodeSubmitResult::Accepted,
         "the lane forwards a submission to the software backend");
  expect(lane.drainPresentation(3, &error) ==
             VideoDecodeDrainProgress::Progress,
         "the lane forwards the drain");
  expect(sink.accepted == 1, "and the frame reaches the sink through the lane");
  lane.close();
  CFRelease(sample);
  CFRelease(description);
}

} // namespace

int main() {
  testPool();
  testConversion();
  testStage();
  testLane();
  if (failures != 0) {
    std::cerr << failures << " software VP8 test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Software VP8 pool, conversion, stage and lane tests passed\n";
  return EXIT_SUCCESS;
}
