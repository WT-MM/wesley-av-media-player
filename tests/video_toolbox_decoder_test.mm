#include "platform/macos/video_toolbox_decoder.hpp"

#import <AVFoundation/AVFoundation.h>
#import <OpenGL/CGLIOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <VideoToolbox/VideoToolbox.h>

#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <initializer_list>
#include <limits>
#include <mutex>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace {

void check(bool condition, const char *expression, int line,
           const std::string &detail = {}) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression;
    if (!detail.empty()) {
      std::cerr << " (" << detail << ')';
    }
    std::cerr << '\n';
    std::exit(EXIT_FAILURE);
  }
}

#define WAM_CHECK(expression)                                                  \
  check(static_cast<bool>(expression), #expression, __LINE__)
#define WAM_CHECK_DETAIL(expression, detail)                                   \
  check(static_cast<bool>(expression), #expression, __LINE__, (detail))

struct OwnedPacket {
  std::vector<std::byte> bytes;
  CMTime presentationTime{kCMTimeInvalid};
  CMTime decodeTime{kCMTimeInvalid};
  CMTime duration{kCMTimeInvalid};
  bool keyFrame{false};
};

struct DemuxedVideo {
  CMVideoCodecType codec{0};
  CMVideoDimensions dimensions{0, 0};
  std::vector<std::byte> configuration;
  std::vector<OwnedPacket> packets;
};

struct TestInputs {
  const char *h264Path{nullptr};
  const char *main10Path{nullptr};
  bool requireHardware{false};
};

TestInputs parseTestInputs(int argc, char **argv) {
  TestInputs result;
  std::vector<const char *> mediaPaths;
  mediaPaths.reserve(2);
  for (int index = 1; index < argc; ++index) {
    const std::string_view argument(argv[index]);
    if (argument == "--require-hardware") {
      WAM_CHECK_DETAIL(!result.requireHardware,
                       "--require-hardware was supplied more than once");
      result.requireHardware = true;
    } else {
      WAM_CHECK_DETAIL(!argument.starts_with("--"),
                       "unknown VideoToolbox test option");
      mediaPaths.push_back(argv[index]);
    }
  }

  WAM_CHECK_DETAIL(mediaPaths.size() == 1 || mediaPaths.size() == 2,
                   "usage: wam_video_toolbox_decoder_test "
                   "[--require-hardware] sample-h264.mp4 "
                   "[sample-main10-hevc.mp4]");
  WAM_CHECK_DETAIL(!result.requireHardware || mediaPaths.size() == 2,
                   "--require-hardware requires both H.264 and Main 10 HEVC "
                   "fixtures");
  result.h264Path = mediaPaths[0];
  result.main10Path = mediaPaths.size() == 2 ? mediaPaths[1] : nullptr;
  return result;
}

bool sampleIsKeyFrame(CMSampleBufferRef sample) {
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    return true;
  }
  auto attachment =
      static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  auto notSync = static_cast<CFBooleanRef>(
      CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_NotSync));
  return notSync == nullptr || !CFBooleanGetValue(notSync);
}

DemuxedVideo readCompressedVideo(const char *path,
                                 CMVideoCodecType expectedCodec,
                                 std::size_t minimumPackets) {
  NSString *filePath = [NSString stringWithUTF8String:path];
  NSURL *url = [NSURL fileURLWithPath:filePath];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSArray<AVAssetTrack *> *tracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
  WAM_CHECK(tracks.count > 0);
  AVAssetTrack *track = tracks.firstObject;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSArray *formatDescriptions = track.formatDescriptions;
#pragma clang diagnostic pop
  WAM_CHECK(formatDescriptions.count > 0);
  CMVideoFormatDescriptionRef sourceFormat =
      (__bridge CMVideoFormatDescriptionRef)formatDescriptions.firstObject;
  WAM_CHECK(sourceFormat != nullptr);

  DemuxedVideo video;
  video.codec = CMFormatDescriptionGetMediaSubType(sourceFormat);
  video.dimensions = CMVideoFormatDescriptionGetDimensions(sourceFormat);
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(sourceFormat);
  auto atoms = static_cast<CFDictionaryRef>(CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
  const CFStringRef atomName =
      video.codec == kCMVideoCodecType_H264   ? CFSTR("avcC")
      : video.codec == kCMVideoCodecType_HEVC ? CFSTR("hvcC")
                                               : nullptr;
  WAM_CHECK(atomName != nullptr);
  auto atom = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, atomName));
  WAM_CHECK(atom != nullptr);
  const CFIndex configurationLength = CFDataGetLength(atom);
  video.configuration.resize(static_cast<std::size_t>(configurationLength));
  std::memcpy(video.configuration.data(), CFDataGetBytePtr(atom),
              video.configuration.size());

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  WAM_CHECK_DETAIL(
      reader != nil,
      readerError == nil
          ? std::string("unknown AVAssetReader error")
          : std::string(readerError.localizedDescription.UTF8String));
  AVAssetReaderTrackOutput *output =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
  output.alwaysCopiesSampleData = NO;
  WAM_CHECK([reader canAddOutput:output]);
  [reader addOutput:output];
  WAM_CHECK([reader startReading]);

  for (std::size_t readAttempt = 0;
       readAttempt < 64 && video.packets.size() < 24; ++readAttempt) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == nullptr) {
      break;
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    // AVAssetReader may emit format/discontinuity samples without media data.
    if (block == nullptr || CMBlockBufferGetDataLength(block) == 0) {
      CFRelease(sample);
      continue;
    }
    OwnedPacket packet;
    packet.bytes.resize(CMBlockBufferGetDataLength(block));
    const OSStatus copyStatus = CMBlockBufferCopyDataBytes(
        block, 0, packet.bytes.size(), packet.bytes.data());
    WAM_CHECK(copyStatus == noErr);
    packet.presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
    packet.decodeTime = CMSampleBufferGetDecodeTimeStamp(sample);
    packet.duration = CMSampleBufferGetDuration(sample);
    packet.keyFrame = sampleIsKeyFrame(sample);
    video.packets.push_back(std::move(packet));
    CFRelease(sample);
  }

  WAM_CHECK(reader.status == AVAssetReaderStatusReading ||
            reader.status == AVAssetReaderStatusCompleted);
  WAM_CHECK(video.codec == expectedCodec);
  WAM_CHECK(video.dimensions.width > 0 && video.dimensions.height > 0);
  WAM_CHECK(!video.configuration.empty());
  WAM_CHECK(video.packets.size() >= minimumPackets);
  return video;
}

wam::macos::VideoStreamConfiguration
streamConfiguration(const DemuxedVideo &video, std::uint64_t generation,
                    bool requireHardware) {
  return {video.codec,
          video.dimensions,
          std::span<const std::byte>(video.configuration),
          true,
          requireHardware,
          generation};
}

wam::macos::CompressedVideoPacket packetView(const OwnedPacket &packet,
                                             std::uint64_t generation) {
  return {std::span<const std::byte>(packet.bytes),
          packet.presentationTime,
          packet.decodeTime,
          packet.duration,
          generation,
          packet.keyFrame,
          false};
}

wam::macos::CompressedVideoPacket endOfStream(std::uint64_t generation) {
  wam::macos::CompressedVideoPacket packet;
  packet.generation = generation;
  packet.endOfStream = true;
  return packet;
}

std::size_t firstKeyFrame(const DemuxedVideo &video) {
  for (std::size_t index = 0; index < video.packets.size(); ++index) {
    if (video.packets[index].keyFrame) {
      return index;
    }
  }
  return video.packets.size();
}

bool earlier(CMTime left, CMTime right) {
  return CMTIME_IS_VALID(left) && CMTIME_IS_VALID(right) &&
         CMTimeCompare(left, right) < 0;
}

CVPixelBufferRef createIOSurfacePixelBuffer(OSType format,
                                             std::size_t width,
                                             std::size_t height,
                                             wam::macos::VideoToolboxOutputInterop
                                                 outputInterop = wam::macos::
                                                     VideoToolboxOutputInterop::
                                                         Metal) {
  CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionaryRef empty = CFDictionaryCreate(
      kCFAllocatorDefault, nullptr, nullptr, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey, empty);
  CFDictionarySetValue(attributes, kCVPixelBufferMetalCompatibilityKey,
                       kCFBooleanTrue);
  if (outputInterop == wam::macos::VideoToolboxOutputInterop::OpenGL) {
    CFDictionarySetValue(
        attributes, kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey,
        kCFBooleanTrue);
  }
  CVPixelBufferRef result = nullptr;
  const CVReturn status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, format, attributes, &result);
  CFRelease(empty);
  CFRelease(attributes);
  WAM_CHECK(status == kCVReturnSuccess);
  WAM_CHECK(result != nullptr);
  return result;
}

class AcceleratedCGLContext final {
public:
  AcceleratedCGLContext() {
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAAccelerated,
        kCGLPFAOpenGLProfile,
        static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_3_2_Core),
        static_cast<CGLPixelFormatAttribute>(0)};
    GLint count = 0;
    const CGLError chooseStatus =
        CGLChoosePixelFormat(attributes, &pixelFormat_, &count);
    WAM_CHECK_DETAIL(chooseStatus == kCGLNoError,
                     CGLErrorString(chooseStatus));
    WAM_CHECK(pixelFormat_ != nullptr);
    WAM_CHECK(count > 0);
    GLint accelerated = 0;
    const CGLError describeStatus = CGLDescribePixelFormat(
        pixelFormat_, 0, kCGLPFAAccelerated, &accelerated);
    WAM_CHECK_DETAIL(describeStatus == kCGLNoError,
                     CGLErrorString(describeStatus));
    WAM_CHECK_DETAIL(accelerated != 0,
                     "CGL selected a non-accelerated pixel format");
    const CGLError createStatus =
        CGLCreateContext(pixelFormat_, nullptr, &context_);
    WAM_CHECK_DETAIL(createStatus == kCGLNoError,
                     CGLErrorString(createStatus));
    WAM_CHECK(context_ != nullptr);
  }

  AcceleratedCGLContext(const AcceleratedCGLContext &) = delete;
  AcceleratedCGLContext &operator=(const AcceleratedCGLContext &) = delete;

  ~AcceleratedCGLContext() {
    if (CGLGetCurrentContext() == context_) {
      CGLSetCurrentContext(nullptr);
    }
    if (context_ != nullptr) {
      CGLDestroyContext(context_);
    }
    if (pixelFormat_ != nullptr) {
      CGLDestroyPixelFormat(pixelFormat_);
    }
  }

  [[nodiscard]] CGLContextObj get() const noexcept { return context_; }

private:
  CGLPixelFormatObj pixelFormat_{nullptr};
  CGLContextObj context_{nullptr};
};

void bindIOSurfacePlanesWithCGL(CGLContextObj context,
                                CVPixelBufferRef pixelBuffer) {
  WAM_CHECK(context != nullptr);
  WAM_CHECK(pixelBuffer != nullptr);
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
  WAM_CHECK(surface != nullptr);
  WAM_CHECK(CGLSetCurrentContext(context) == kCGLNoError);

  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  const bool tenBit =
      format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  WAM_CHECK(tenBit ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
  const std::array<GLenum, 2> internalFormats{
      static_cast<GLenum>(tenBit ? GL_R16 : GL_R8),
      static_cast<GLenum>(tenBit ? GL_RG16 : GL_RG8)};
  const std::array<GLenum, 2> externalFormats{GL_RED, GL_RG};
  const GLenum type = tenBit ? GL_UNSIGNED_SHORT : GL_UNSIGNED_BYTE;

  std::array<GLuint, 2> textures{};
  glGenTextures(static_cast<GLsizei>(textures.size()), textures.data());
  WAM_CHECK(textures[0] != 0);
  WAM_CHECK(textures[1] != 0);
  for (std::size_t plane = 0; plane < textures.size(); ++plane) {
    glBindTexture(GL_TEXTURE_RECTANGLE, textures[plane]);
    const CGLError importStatus = CGLTexImageIOSurface2D(
        context, GL_TEXTURE_RECTANGLE, internalFormats[plane],
        static_cast<GLsizei>(CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)),
        static_cast<GLsizei>(
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)),
        externalFormats[plane], type, surface, static_cast<GLuint>(plane));
    WAM_CHECK_DETAIL(importStatus == kCGLNoError,
                     CGLErrorString(importStatus));
    WAM_CHECK(glGetError() == GL_NO_ERROR);
  }
  glBindTexture(GL_TEXTURE_RECTANGLE, 0);
  glDeleteTextures(static_cast<GLsizei>(textures.size()), textures.data());
  WAM_CHECK(glGetError() == GL_NO_ERROR);
}

void testFiniteAdmissionNeverEnablesTemporalProcessing() {
  wam::macos::VideoToolboxDecoder asynchronous;
  WAM_CHECK(asynchronous.stats().outputInterop ==
            wam::macos::VideoToolboxOutputInterop::Metal);
  const std::uint32_t asynchronousFlags =
      wam::macos::VideoToolboxDecoderTestAccess::decodeFlags(asynchronous);
  WAM_CHECK((asynchronousFlags &
             kVTDecodeFrame_EnableAsynchronousDecompression) != 0);
  WAM_CHECK((asynchronousFlags & kVTDecodeFrame_EnableTemporalProcessing) == 0);

  wam::macos::VideoToolboxDecoderOptions synchronousOptions;
  synchronousOptions.enableAsynchronousDecompression = false;
  wam::macos::VideoToolboxDecoder synchronous(synchronousOptions);
  const std::uint32_t synchronousFlags =
      wam::macos::VideoToolboxDecoderTestAccess::decodeFlags(synchronous);
  WAM_CHECK((synchronousFlags &
             kVTDecodeFrame_EnableAsynchronousDecompression) == 0);
  WAM_CHECK((synchronousFlags & kVTDecodeFrame_EnableTemporalProcessing) == 0);

  wam::macos::VideoToolboxDecoderOptions openGLOptions;
  openGLOptions.outputInterop =
      wam::macos::VideoToolboxOutputInterop::OpenGL;
  wam::macos::VideoToolboxDecoder openGL(openGLOptions);
  WAM_CHECK(openGL.stats().outputInterop ==
            wam::macos::VideoToolboxOutputInterop::OpenGL);
}

void testInjectedCallbackOrderUsesDecodeSequence(
    const DemuxedVideo &video, bool requireHardware) {
  constexpr std::uint64_t generation = 41;
  constexpr std::size_t reorderDepth = 2;
  wam::macos::BoundedFrameQueue queue(4, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 4;
  options.maxPendingPresentationFrames = 4;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::setPresentationReorderDepth(
          decoder, reorderDepth, &error),
      error);

  // Decode order 0,3,1,2 is legal at reorder depth two. VideoToolbox's async
  // handlers arrive as 0,2,3,1 below: the former PTS high-water heuristic
  // emitted 2 before the final 1 callback and then dropped that legal frame.
  constexpr std::array<std::int64_t, 4> decodeOrderPts{0, 3, 1, 2};
  constexpr std::array<std::uint64_t, 4> callbackOrder{0, 3, 1, 2};
  std::array<CVPixelBufferRef, 4> buffers{};
  for (CVPixelBufferRef &buffer : buffers) {
    buffer = createIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  }
  for (const std::uint64_t sequence : callbackOrder) {
    const wam::macos::FrameTiming timing{
        CMTimeMake(decodeOrderPts[sequence], 1), CMTimeMake(1, 1), generation,
        sequence == 0};
    WAM_CHECK_DETAIL(
        wam::macos::VideoToolboxDecoderTestAccess::injectDecodedFrame(
            decoder, sequence, buffers[sequence], timing, &error),
        error);
  }
  for (CVPixelBufferRef buffer : buffers) {
    CVPixelBufferRelease(buffer);
  }
  wam::macos::VideoToolboxDecoderTestAccess::drainPresentationFrames(decoder);

  std::vector<std::int64_t> deliveredPts;
  while (auto frame = queue.tryTake()) {
    deliveredPts.push_back(frame->timing().presentationTime.value);
  }
  WAM_CHECK((deliveredPts == std::vector<std::int64_t>{0, 1, 2, 3}));
  const auto stats = decoder.stats();
  WAM_CHECK(stats.codecReorderFrames == reorderDepth);
  WAM_CHECK(stats.peakPendingPresentationFrames <= reorderDepth);
  WAM_CHECK(stats.deliveredFrames == 4);
  WAM_CHECK(stats.droppedFrames == 0);
  WAM_CHECK(stats.outOfOrderDrops == 0);
  WAM_CHECK(stats.inFlightFrames == 0);
  WAM_CHECK(!decoder.takeLastError().has_value());
  decoder.close();
}

void testInjectedCompletionGapPreservesAdmissionAndMakesProgress(
    const DemuxedVideo &video, std::size_t keyIndex, bool requireHardware) {
  constexpr std::uint64_t generation = 42;
  wam::macos::BoundedFrameQueue queue(2, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 2;
  options.maxPendingPresentationFrames = 2;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::setPresentationReorderDepth(
          decoder, 0, &error),
      error);
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
          decoder, 2, &error),
      error);

  CVPixelBufferRef first = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  CVPixelBufferRef second = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  const wam::macos::FrameTiming secondTiming{
      CMTimeMake(1, 1), CMTimeMake(1, 1), generation, false};
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::injectDecodedFrame(
          decoder, 1, second, secondTiming, &error),
      error);

  // A later callback must not free its admission credit while sequence zero is
  // still missing. PROT_NONE makes a premature packet copy fail deterministically.
  WAM_CHECK(decoder.stats().inFlightFrames == 2);
  const long pageSize = sysconf(_SC_PAGESIZE);
  WAM_CHECK(pageSize > 0);
  void *inaccessibleBytes = mmap(nullptr, static_cast<std::size_t>(pageSize),
                                 PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(inaccessibleBytes != MAP_FAILED);
  auto guardedPacket = packetView(video.packets[keyIndex], generation);
  guardedPacket.bytes = std::span<const std::byte>(
      static_cast<const std::byte *>(inaccessibleBytes),
      static_cast<std::size_t>(pageSize));
  WAM_CHECK(decoder.submit(guardedPacket, &error) ==
            wam::macos::VideoDecodeSubmitResult::Backpressure);
  WAM_CHECK(munmap(inaccessibleBytes, static_cast<std::size_t>(pageSize)) == 0);

  const wam::macos::FrameTiming firstTiming{
      CMTimeMake(0, 1), CMTimeMake(1, 1), generation, true};
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::injectDecodedFrame(
          decoder, 0, first, firstTiming, &error),
      error);
  CVPixelBufferRelease(first);
  CVPixelBufferRelease(second);

  WAM_CHECK(decoder.stats().inFlightFrames == 0);
  auto firstOutput = queue.tryTake();
  auto secondOutput = queue.tryTake();
  WAM_CHECK(firstOutput.has_value());
  WAM_CHECK(secondOutput.has_value());
  WAM_CHECK(CMTimeCompare(firstOutput->timing().presentationTime,
                          CMTimeMake(0, 1)) == 0);
  WAM_CHECK(CMTimeCompare(secondOutput->timing().presentationTime,
                          CMTimeMake(1, 1)) == 0);
  WAM_CHECK(decoder.stats().backpressuredSubmissions == 1);
  WAM_CHECK(!decoder.takeLastError().has_value());
  decoder.close();
}

void testConfigurationByteBound(const DemuxedVideo &video) {
  constexpr std::uint64_t generation = 5;
  constexpr std::size_t oversizedConfigurationBytes = 1024ULL * 1024ULL + 1ULL;
  void *inaccessibleBytes =
      mmap(nullptr, oversizedConfigurationBytes, PROT_NONE,
           MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(inaccessibleBytes != MAP_FAILED);

  wam::macos::BoundedFrameQueue queue(1, generation);
  wam::macos::VideoToolboxDecoder decoder;
  auto configuration = streamConfiguration(video, generation, false);
  configuration.codecConfiguration = std::span<const std::byte>(
      static_cast<const std::byte *>(inaccessibleBytes),
      oversizedConfigurationBytes);
  std::string error;
  WAM_CHECK(!decoder.configure(configuration, queue, &error));
  WAM_CHECK(!error.empty());
  WAM_CHECK(munmap(inaccessibleBytes, oversizedConfigurationBytes) == 0);
}

void testCodecParserAndDeclaredReorderBound(const DemuxedVideo &video) {
  constexpr std::uint64_t generation = 8;
  const auto configuration = streamConfiguration(video, generation, false);
  const auto reorderFrames =
      wam::macos::VideoToolboxDecoderTestAccess::codecReorderFrames(
          configuration);
  WAM_CHECK(reorderFrames.has_value());
  WAM_CHECK(*reorderFrames > 0);
  WAM_CHECK(*reorderFrames <= 8);

  auto appendToFirstSps = [&](std::initializer_list<std::byte> suffix) {
    std::vector<std::byte> malformed = video.configuration;
    WAM_CHECK(malformed.size() >= 8);
    const std::size_t spsLength =
        (static_cast<std::size_t>(std::to_integer<std::uint8_t>(malformed[6]))
         << 8U) |
        std::to_integer<std::uint8_t>(malformed[7]);
    WAM_CHECK(spsLength <= malformed.size() - 8);
    const std::size_t expandedLength = spsLength + suffix.size();
    WAM_CHECK(expandedLength <= std::numeric_limits<std::uint16_t>::max());
    malformed.insert(malformed.begin() + static_cast<std::ptrdiff_t>(8 + spsLength),
                     suffix.begin(), suffix.end());
    malformed[6] =
        static_cast<std::byte>((expandedLength >> 8U) & 0xffU);
    malformed[7] = static_cast<std::byte>(expandedLength & 0xffU);
    return malformed;
  };

  for (std::vector<std::byte> malformed : {
           appendToFirstSps(
               {std::byte{0x00}, std::byte{0x00}, std::byte{0x03}}),
           appendToFirstSps({std::byte{0x00}, std::byte{0x00},
                             std::byte{0x03}, std::byte{0x04}})}) {
    auto malformedConfiguration = configuration;
    malformedConfiguration.codecConfiguration = malformed;
    WAM_CHECK(
        !wam::macos::VideoToolboxDecoderTestAccess::codecReorderFrames(
             malformedConfiguration)
             .has_value());
  }

  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 2;
  options.maxPendingPresentationFrames = *reorderFrames - 1;
  wam::macos::VideoToolboxDecoder decoder(options);
  wam::macos::BoundedFrameQueue queue(2, generation);
  std::string error;
  WAM_CHECK(!decoder.configure(configuration, queue, &error));
  WAM_CHECK(error.find("exceeding the configured bound") != std::string::npos);
}

void testDefaultBoundMakesProgressBeforeEndOfStream(
    const DemuxedVideo &video, std::size_t keyIndex, bool requireHardware) {
  constexpr std::uint64_t generation = 9;
  const std::size_t packetCount = video.packets.size() - keyIndex;
  wam::macos::BoundedFrameQueue queue(packetCount + 1, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 2;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);

  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (true) {
      const auto result =
          decoder.submit(packetView(video.packets[index], generation), &error);
      if (result == wam::macos::VideoDecodeSubmitResult::Accepted) {
        break;
      }
      WAM_CHECK_DETAIL(result ==
                           wam::macos::VideoDecodeSubmitResult::Backpressure,
                       error);
      WAM_CHECK_DETAIL(std::chrono::steady_clock::now() < deadline,
                       "finite decoder admission stalled before EOS");
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  const auto stats = decoder.stats();
  WAM_CHECK(stats.submittedFrames == packetCount);
  WAM_CHECK(stats.deliveredFrames == packetCount);
  WAM_CHECK(stats.droppedFrames == 0);
  if (requireHardware) {
    WAM_CHECK(stats.usingHardwareAcceleratedDecoder);
  }
  WAM_CHECK(stats.inFlightFrames == 0);
  decoder.close();
}

void testBFramePresentationOrderAndMetalImport(const DemuxedVideo &video,
                                               std::size_t keyIndex,
                                               bool requireHardware) {
  constexpr std::uint64_t generation = 40;
  const std::size_t packetCount = video.packets.size() - keyIndex;
  WAM_CHECK(packetCount >= 3);

  bool decodeOrderDiffersFromPresentationOrder = false;
  for (std::size_t index = keyIndex + 1; index < video.packets.size();
       ++index) {
    decodeOrderDiffersFromPresentationOrder |=
        earlier(video.packets[index].presentationTime,
                video.packets[index - 1].presentationTime);
  }
  WAM_CHECK_DETAIL(decodeOrderDiffersFromPresentationOrder,
                   "H.264 fixture must contain B-frame PTS reordering");

  wam::macos::BoundedFrameQueue queue(packetCount + 1, generation);
  wam::macos::VideoToolboxDecoder decoder({packetCount + 1});
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);

  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    WAM_CHECK_DETAIL(
        decoder.submit(packetView(video.packets[index], generation), &error) ==
            wam::macos::VideoDecodeSubmitResult::Accepted,
        error);
  }
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);

  const wam::macos::VideoToolboxDecoderStats stats = decoder.stats();
  WAM_CHECK(stats.submittedFrames == packetCount);
  WAM_CHECK(stats.deliveredFrames == packetCount);
  WAM_CHECK(stats.droppedFrames == 0);
  WAM_CHECK(stats.outOfOrderDrops == 0);
  WAM_CHECK(stats.codecReorderFrames > 0);
  WAM_CHECK(stats.codecReorderFrames <= 8);
  WAM_CHECK(stats.requestedOutputPixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  WAM_CHECK(stats.actualOutputPixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);

  auto metalCache = wam::macos::MetalTextureCache::create(nullptr, &error);
  WAM_CHECK_DETAIL(metalCache != nullptr, error);

  std::vector<CMTime> outputTimes;
  outputTimes.reserve(packetCount);
  while (auto frame = queue.tryTake()) {
    WAM_CHECK(frame->isIOSurfaceBacked());
    WAM_CHECK(frame->pixelFormat() == stats.actualOutputPixelFormat);
    WAM_CHECK(CMTIME_IS_VALID(frame->timing().presentationTime));
    WAM_CHECK(CMTIME_IS_VALID(frame->timing().duration));
    if (!outputTimes.empty()) {
      WAM_CHECK(!earlier(frame->timing().presentationTime, outputTimes.back()));
    }
    outputTimes.push_back(frame->timing().presentationTime);

    auto metalFrame = metalCache->importFrame(*frame, &error);
    WAM_CHECK_DETAIL(metalFrame.has_value(), error);
    WAM_CHECK(metalFrame->planeCount() == 2);
    WAM_CHECK(metalFrame->nativeTexture(0) != nullptr);
    WAM_CHECK(metalFrame->nativeTexture(1) != nullptr);
  }
  WAM_CHECK(outputTimes.size() == packetCount);

  std::vector<CMTime> expectedTimes;
  expectedTimes.reserve(packetCount);
  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    expectedTimes.push_back(video.packets[index].presentationTime);
  }
  std::sort(expectedTimes.begin(), expectedTimes.end(),
            [](CMTime left, CMTime right) { return earlier(left, right); });
  for (std::size_t index = 0; index < expectedTimes.size(); ++index) {
    WAM_CHECK(CMTimeCompare(outputTimes[index], expectedTimes[index]) == 0);
  }
  WAM_CHECK(queue.reachedEndOfStream());
  decoder.close();
}

void testDecodedNV12OpenGLInterop(const DemuxedVideo &video,
                                  std::size_t keyIndex,
                                  bool requireHardware,
                                  CGLContextObj cglContext) {
  constexpr std::uint64_t generation = 45;
  const std::size_t packetCount = video.packets.size() - keyIndex;
  wam::macos::BoundedFrameQueue queue(packetCount + 1, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = packetCount + 1;
  options.outputInterop = wam::macos::VideoToolboxOutputInterop::OpenGL;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);
  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    WAM_CHECK_DETAIL(
        decoder.submit(packetView(video.packets[index], generation), &error) ==
            wam::macos::VideoDecodeSubmitResult::Accepted,
        error);
  }
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);

  const auto stats = decoder.stats();
  WAM_CHECK(stats.outputInterop ==
            wam::macos::VideoToolboxOutputInterop::OpenGL);
  WAM_CHECK(stats.requestedOutputPixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  WAM_CHECK(stats.actualOutputPixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  WAM_CHECK(stats.deliveredFrames == packetCount);
  WAM_CHECK(stats.droppedFrames == 0);
  if (requireHardware) {
    WAM_CHECK(stats.usingHardwareAcceleratedDecoder);
  }

  std::size_t importedFrames = 0;
  while (auto frame = queue.tryTake()) {
    WAM_CHECK_DETAIL(
        wam::macos::VideoToolboxDecoderTestAccess::validateOutputSurface(
            frame->pixelBuffer(), stats.requestedOutputPixelFormat,
            wam::macos::VideoToolboxOutputInterop::OpenGL, &error),
        error);
    bindIOSurfacePlanesWithCGL(cglContext, frame->pixelBuffer());
    ++importedFrames;
  }
  WAM_CHECK(importedFrames == packetCount);
  WAM_CHECK(queue.reachedEndOfStream());
  WAM_CHECK(!decoder.takeLastError().has_value());
  std::cout << "NV12 VT-to-CGL decode passed ("
            << (stats.usingHardwareAcceleratedDecoder ? "hardware" : "software")
            << " VideoToolbox)\n";
  decoder.close();
}

void testDecodedP010OpenGLInterop(const DemuxedVideo &video,
                                  std::size_t keyIndex,
                                  bool requireHardware,
                                  CGLContextObj cglContext) {
  constexpr std::uint64_t generation = 46;
  const std::size_t packetCount = video.packets.size() - keyIndex;
  WAM_CHECK(packetCount > 0);
  wam::macos::BoundedFrameQueue queue(packetCount + 1, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = packetCount + 1;
  options.outputInterop = wam::macos::VideoToolboxOutputInterop::OpenGL;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);
  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    WAM_CHECK_DETAIL(
        decoder.submit(packetView(video.packets[index], generation), &error) ==
            wam::macos::VideoDecodeSubmitResult::Accepted,
        error);
  }
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);

  const auto stats = decoder.stats();
  WAM_CHECK(stats.outputInterop ==
            wam::macos::VideoToolboxOutputInterop::OpenGL);
  WAM_CHECK(stats.requestedOutputPixelFormat ==
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
  WAM_CHECK(stats.actualOutputPixelFormat ==
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
  WAM_CHECK(stats.deliveredFrames == packetCount);
  WAM_CHECK(stats.droppedFrames == 0);
  if (requireHardware) {
    WAM_CHECK(stats.usingHardwareAcceleratedDecoder);
  }

  std::size_t importedFrames = 0;
  while (auto frame = queue.tryTake()) {
    WAM_CHECK_DETAIL(
        wam::macos::VideoToolboxDecoderTestAccess::validateOutputSurface(
            frame->pixelBuffer(), stats.requestedOutputPixelFormat,
            wam::macos::VideoToolboxOutputInterop::OpenGL, &error),
        error);
    bindIOSurfacePlanesWithCGL(cglContext, frame->pixelBuffer());
    ++importedFrames;
  }
  WAM_CHECK(importedFrames == packetCount);
  WAM_CHECK(queue.reachedEndOfStream());
  WAM_CHECK(!decoder.takeLastError().has_value());
  std::cout << "P010 VT-to-CGL decode passed ("
            << (stats.usingHardwareAcceleratedDecoder ? "hardware" : "software")
            << " VideoToolbox)\n";
  decoder.close();
}

void testSyntheticP010LayoutRejection(CGLContextObj cglContext) {
  CVPixelBufferRef p010 = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 128, 64,
      wam::macos::VideoToolboxOutputInterop::OpenGL);
  std::string error;
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::validateOutputSurface(
          p010, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
          wam::macos::VideoToolboxOutputInterop::OpenGL, &error),
      error);
  bindIOSurfacePlanesWithCGL(cglContext, p010);

  WAM_CHECK(!wam::macos::VideoToolboxDecoderTestAccess::validateOutputSurface(
      p010, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      wam::macos::VideoToolboxOutputInterop::OpenGL, &error));
  WAM_CHECK(error.find("pixel format") != std::string::npos);
  CVPixelBufferRelease(p010);
}

void testSinkBackpressureIsRecoverable(const DemuxedVideo &video,
                                       std::size_t keyIndex,
                                       bool requireHardware) {
  constexpr std::uint64_t firstGeneration = 50;
  constexpr std::uint64_t secondGeneration = 51;
  wam::macos::BoundedFrameQueue queue(1, firstGeneration);
  wam::macos::VideoToolboxDecoder decoder({video.packets.size() + 1});
  std::string error;
  WAM_CHECK_DETAIL(decoder.configure(streamConfiguration(video, firstGeneration,
                                                         requireHardware),
                                     queue, &error),
                   error);
  for (std::size_t index = keyIndex; index < video.packets.size(); ++index) {
    WAM_CHECK_DETAIL(
        decoder.submit(packetView(video.packets[index], firstGeneration),
                       &error) == wam::macos::VideoDecodeSubmitResult::Accepted,
        error);
  }
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(firstGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(decoder.stats().sinkBackpressureDrops > 0);
  WAM_CHECK(decoder.stats().droppedFrames ==
            decoder.stats().sinkBackpressureDrops);
  WAM_CHECK(!decoder.takeLastError().has_value());

  decoder.flush(secondGeneration);
  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], secondGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(secondGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(queue.tryTake().has_value());
  WAM_CHECK(!decoder.takeLastError().has_value());
  decoder.close();
}

void testAdmissionBeforeCopy(const DemuxedVideo &video, std::size_t keyIndex,
                             bool requireHardware) {
  constexpr std::uint64_t generation = 6;
  wam::macos::BoundedFrameQueue queue(2, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);

  // The test-only source build can reserve the decoder's one real admission
  // slot without depending on whether VideoToolbox invokes callbacks inline.
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::occupyInFlightCapacity(
          decoder, &error),
      error);
  WAM_CHECK(decoder.stats().inFlightFrames == 1);

  wam::macos::CompressedVideoPacket guardedPacket =
      packetView(video.packets[keyIndex], generation);
  const long pageSize = sysconf(_SC_PAGESIZE);
  WAM_CHECK(pageSize > 0);
  void *inaccessibleBytes = mmap(nullptr, static_cast<std::size_t>(pageSize),
                                 PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(inaccessibleBytes != MAP_FAILED);
  guardedPacket.bytes = std::span<const std::byte>(
      static_cast<const std::byte *>(inaccessibleBytes),
      static_cast<std::size_t>(pageSize));
  WAM_CHECK(decoder.submit(guardedPacket, &error) ==
            wam::macos::VideoDecodeSubmitResult::Backpressure);
  WAM_CHECK(munmap(inaccessibleBytes, static_cast<std::size_t>(pageSize)) == 0);
  WAM_CHECK(error.empty());
  WAM_CHECK(decoder.stats().inFlightFrames == 1);
  WAM_CHECK(decoder.stats().backpressuredSubmissions == 1);
  WAM_CHECK(!decoder.takeLastError().has_value());

  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::releaseInFlightCapacity(
          decoder, &error),
      error);
  WAM_CHECK(decoder.stats().inFlightFrames == 0);

  // A media-controlled packet larger than the decoder contract must reject
  // before touching or copying its payload. PROT_NONE turns that ordering into
  // a deterministic safety assertion without allocating 32 MiB of resident RAM.
  constexpr std::size_t oversizedPacketBytes =
      32ULL * 1024ULL * 1024ULL + 1ULL;
  void *oversizedBytes = mmap(nullptr, oversizedPacketBytes, PROT_NONE,
                              MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(oversizedBytes != MAP_FAILED);
  auto oversizedPacket = packetView(video.packets[keyIndex], generation);
  oversizedPacket.bytes = std::span<const std::byte>(
      static_cast<const std::byte *>(oversizedBytes), oversizedPacketBytes);
  WAM_CHECK(decoder.submit(oversizedPacket, &error) ==
            wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error.find("32 MiB") != std::string::npos);
  WAM_CHECK(munmap(oversizedBytes, oversizedPacketBytes) == 0);

  // Removing the synthetic reservation must leave the real decode lifecycle
  // usable; this catches a seam that accidentally poisons production state.
  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], generation), &error) ==
          wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(decoder.stats().submittedFrames == 1);
  WAM_CHECK(decoder.stats().inFlightFrames == 0);
  WAM_CHECK(queue.tryTake().has_value());
  decoder.close();
}

class GatedSink final : public wam::macos::DecodedFrameSink {
public:
  GatedSink(std::atomic<bool> &submissionActive, std::uint64_t generation)
      : submissionActive_(submissionActive), queue_(4, generation) {}

  wam::macos::FrameEnqueueResult enqueue(wam::macos::FrameLease frame,
                                         std::string *error) override {
    {
      std::unique_lock lock(mutex_);
      callbackEntered_ = true;
      callbackOverlappedSubmit_ =
          submissionActive_.load(std::memory_order_acquire);
      condition_.notify_all();
      condition_.wait(lock, [this] { return released_; });
    }
    return queue_.enqueue(std::move(frame), error);
  }

  void endOfStream(std::uint64_t generation) override {
    queue_.endOfStream(generation);
  }

  void flush(std::uint64_t nextGeneration) noexcept override {
    queue_.flush(nextGeneration);
  }

  bool waitForCallback() {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, std::chrono::seconds(5),
                               [this] { return callbackEntered_; });
  }

  bool callbackOverlappedSubmit() {
    std::lock_guard lock(mutex_);
    return callbackOverlappedSubmit_;
  }

  void release() {
    std::lock_guard lock(mutex_);
    released_ = true;
    condition_.notify_all();
  }

  std::optional<wam::macos::FrameLease> tryTake() { return queue_.tryTake(); }

private:
  std::atomic<bool> &submissionActive_;
  wam::macos::BoundedFrameQueue queue_;
  std::mutex mutex_;
  std::condition_variable condition_;
  bool callbackEntered_{false};
  bool callbackOverlappedSubmit_{false};
  bool released_{false};
};

void testCallbackScheduling(const DemuxedVideo &video, std::size_t keyIndex,
                            bool requireHardware,
                            bool allowAsynchronousDecode) {
  constexpr std::uint64_t generation = 7;
  std::atomic<bool> submissionActive{false};
  GatedSink sink(submissionActive, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.enableAsynchronousDecompression = allowAsynchronousDecode;
  // Temporal processing is disabled in every build because it may retain a
  // frame indefinitely until EOS, defeating finite admission. This test only
  // varies whether the callback may run asynchronously.
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string configurationError;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        sink, &configurationError),
      configurationError);
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::setPresentationReorderDepth(
          decoder, 0, &configurationError),
      configurationError);

  const std::size_t deliveryIndex = keyIndex + 1;
  WAM_CHECK(deliveryIndex < video.packets.size());

  struct SubmissionResults {
    wam::macos::VideoDecodeSubmitResult first{
        wam::macos::VideoDecodeSubmitResult::Rejected};
    wam::macos::VideoDecodeSubmitResult second{
        wam::macos::VideoDecodeSubmitResult::Rejected};
    std::string error;
  } results;

  std::thread submitter([&] {
    @autoreleasepool {
      auto trackedSubmit = [&](const wam::macos::CompressedVideoPacket &packet) {
        submissionActive.store(true, std::memory_order_release);
        const auto result = decoder.submit(packet, &results.error);
        submissionActive.store(false, std::memory_order_release);
        return result;
      };

      results.first =
          trackedSubmit(packetView(video.packets[keyIndex], generation));
      if (results.first != wam::macos::VideoDecodeSubmitResult::Accepted) {
        return;
      }

      // With temporal processing disabled the first output callback cannot be
      // retained indefinitely. Waiting for it here makes the second accepted
      // packet the sole in-flight frame, regardless of decoder speed.
      const auto callbackDeadline =
          std::chrono::steady_clock::now() + std::chrono::seconds(5);
      while (decoder.stats().inFlightFrames != 0 &&
             std::chrono::steady_clock::now() < callbackDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      if (decoder.stats().inFlightFrames != 0) {
        results.error = "first non-temporal callback did not complete";
        return;
      }
      results.second =
          trackedSubmit(packetView(video.packets[deliveryIndex], generation));
    }
  });

  const bool callbackArrived = sink.waitForCallback();
  const bool callbackOverlappedSubmit =
      callbackArrived && sink.callbackOverlappedSubmit();

  // Always release before joining: a conforming decoder may invoke the output
  // handler inline, in which case submitter owns operationMutex until enqueue()
  // returns. The former main-thread wait was the Intel CI deadlock.
  sink.release();
  submitter.join();
  WAM_CHECK_DETAIL(callbackArrived, "decoded-frame callback did not arrive");
  WAM_CHECK_DETAIL(
      results.first == wam::macos::VideoDecodeSubmitResult::Accepted,
      results.error);
  WAM_CHECK_DETAIL(
      results.second == wam::macos::VideoDecodeSubmitResult::Accepted,
      results.error);
  if (!allowAsynchronousDecode) {
    WAM_CHECK_DETAIL(
        callbackOverlappedSubmit,
        "synchronous VideoToolbox mode returned before its output callback");
  }
  WAM_CHECK(!decoder.takeLastError().has_value());

  std::string error;
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(decoder.stats().inFlightFrames == 0);
  auto frame = sink.tryTake();
  WAM_CHECK(frame.has_value());
  WAM_CHECK(frame->isIOSurfaceBacked());
  WAM_CHECK(frame->timing().generation == generation);
  decoder.close();
  decoder.close();
  WAM_CHECK(!decoder.stats().configured);
}

void testLifecycleAndGeneration(const DemuxedVideo &video, std::size_t keyIndex,
                                bool requireHardware) {
  constexpr std::uint64_t firstGeneration = 20;
  constexpr std::uint64_t secondGeneration = 21;
  wam::macos::BoundedFrameQueue queue(8, firstGeneration);
  wam::macos::VideoToolboxDecoder decoder({4});
  std::string error;
  WAM_CHECK_DETAIL(decoder.configure(streamConfiguration(video, firstGeneration,
                                                         requireHardware),
                                     queue, &error),
                   error);
  WAM_CHECK(decoder.stats().configured);
  if (requireHardware) {
    WAM_CHECK(decoder.stats().usingHardwareAcceleratedDecoder);
  }
  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], firstGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(firstGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  auto firstFrame = queue.tryTake();
  WAM_CHECK(firstFrame.has_value());
  WAM_CHECK(firstFrame->isIOSurfaceBacked());
  WAM_CHECK(firstFrame->timing().generation == firstGeneration);

  decoder.flush(secondGeneration);
  WAM_CHECK(queue.generation() == secondGeneration);
  WAM_CHECK(decoder.stats().generation == secondGeneration);
  WAM_CHECK(decoder.stats().awaitingKeyFrame);
  WAM_CHECK(decoder.submit(packetView(video.packets[keyIndex], firstGeneration),
                           &error) ==
            wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error == "compressed packet belongs to a stale generation");

  std::size_t nonKeyIndex = keyIndex + 1;
  while (nonKeyIndex < video.packets.size() &&
         video.packets[nonKeyIndex].keyFrame) {
    ++nonKeyIndex;
  }
  WAM_CHECK(nonKeyIndex < video.packets.size());
  WAM_CHECK(
      decoder.submit(packetView(video.packets[nonKeyIndex], secondGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error == "decoder requires a key frame after configure or flush");

  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], secondGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(secondGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  auto secondFrame = queue.tryTake();
  WAM_CHECK(secondFrame.has_value());
  WAM_CHECK(secondFrame->isIOSurfaceBacked());
  WAM_CHECK(secondFrame->timing().generation == secondGeneration);
  WAM_CHECK(decoder.stats().inFlightFrames == 0);
  WAM_CHECK(!decoder.takeLastError().has_value());

  decoder.close();
  WAM_CHECK(!decoder.stats().configured);
  WAM_CHECK(
      decoder.submit(packetView(video.packets[keyIndex], secondGeneration),
                     &error) == wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error == "VideoToolbox decoder is not configured");
}

void testHevcConfiguration(bool requireHardware) {
  // Valid Main-profile hvcC containing VPS/SPS/PPS (the optional SEI array was
  // removed from the source configuration record).
  static const std::uint8_t hvcC[] = {
      0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x96, 0xf0, 0x00, 0xfc, 0xfd, 0xf8, 0xf8, 0x00, 0x00, 0x0f, 0x03, 0xa0,
      0x00, 0x01, 0x00, 0x18, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60,
      0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
      0x96, 0x95, 0x98, 0x09, 0xa1, 0x00, 0x01, 0x00, 0x2f, 0x42, 0x01, 0x01,
      0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00,
      0x03, 0x00, 0x96, 0xa0, 0x01, 0xe0, 0x20, 0x02, 0x1c, 0x59, 0x65, 0x66,
      0x92, 0x4c, 0xaf, 0xff, 0x04, 0x38, 0x03, 0x59, 0x01, 0x00, 0x00, 0x03,
      0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x18, 0x08, 0xa2, 0x00, 0x01, 0x00,
      0x07, 0x44, 0x01, 0xc1, 0x72, 0xb4, 0x62, 0x40};

  constexpr std::uint64_t generation = 30;
  wam::macos::BoundedFrameQueue queue(2, generation);
  wam::macos::VideoToolboxDecoder decoder({2});
  wam::macos::VideoStreamConfiguration configuration;
  configuration.codec = kCMVideoCodecType_HEVC;
  configuration.codedSize = {3840, 2160};
  configuration.codecConfiguration = std::span<const std::byte>(
      reinterpret_cast<const std::byte *>(hvcC), sizeof(hvcC));
  configuration.preferHardwareDecode = true;
  configuration.requireHardwareDecode = requireHardware;
  configuration.generation = generation;
  std::string error;
  WAM_CHECK_DETAIL(decoder.configure(configuration, queue, &error), error);
  WAM_CHECK(decoder.stats().configured);
  WAM_CHECK(decoder.stats().codecReorderFrames <= 8);
  if (requireHardware) {
    WAM_CHECK(decoder.stats().usingHardwareAcceleratedDecoder);
  }
  decoder.close();
  WAM_CHECK(!decoder.stats().configured);
}

} // namespace

int main(int argc, char **argv) {
  const TestInputs inputs = parseTestInputs(argc, argv);
  DemuxedVideo video =
      readCompressedVideo(inputs.h264Path, kCMVideoCodecType_H264, 3);
  const std::size_t keyIndex = firstKeyFrame(video);
  WAM_CHECK(keyIndex < video.packets.size());
  DemuxedVideo main10Video;
  std::size_t main10KeyIndex = 0;
  const bool hasMain10Fixture = inputs.main10Path != nullptr;
  if (hasMain10Fixture) {
    main10Video =
        readCompressedVideo(inputs.main10Path, kCMVideoCodecType_HEVC, 1);
    main10KeyIndex = firstKeyFrame(main10Video);
    WAM_CHECK(main10KeyIndex < main10Video.packets.size());
  }

  if (inputs.requireHardware) {
    WAM_CHECK_DETAIL(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
                     "this runner reports no hardware H.264 decoder");
    WAM_CHECK_DETAIL(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                     "this runner reports no hardware HEVC decoder");
  }
  AcceleratedCGLContext cglContext;
  testFiniteAdmissionNeverEnablesTemporalProcessing();
  testConfigurationByteBound(video);
  testCodecParserAndDeclaredReorderBound(video);
  testAdmissionBeforeCopy(video, keyIndex, inputs.requireHardware);
  testDefaultBoundMakesProgressBeforeEndOfStream(video, keyIndex,
                                                 inputs.requireHardware);
  testCallbackScheduling(video, keyIndex, inputs.requireHardware, true);
  testCallbackScheduling(video, keyIndex, inputs.requireHardware, false);
  testLifecycleAndGeneration(video, keyIndex, inputs.requireHardware);
  testInjectedCallbackOrderUsesDecodeSequence(video, inputs.requireHardware);
  testInjectedCompletionGapPreservesAdmissionAndMakesProgress(
      video, keyIndex, inputs.requireHardware);
  testBFramePresentationOrderAndMetalImport(video, keyIndex,
                                            inputs.requireHardware);
  testDecodedNV12OpenGLInterop(video, keyIndex, inputs.requireHardware,
                               cglContext.get());
  if (hasMain10Fixture) {
    testDecodedP010OpenGLInterop(main10Video, main10KeyIndex,
                                 inputs.requireHardware, cglContext.get());
  } else {
    std::cout << "Real P010 VideoToolbox decode was not exercised: no Main 10 "
                 "HEVC fixture was supplied\n";
  }
  testSyntheticP010LayoutRejection(cglContext.get());
  testSinkBackpressureIsRecoverable(video, keyIndex, inputs.requireHardware);
  testHevcConfiguration(inputs.requireHardware);

  std::cout << "VideoToolbox H.264 B-frame ordering, zero-copy Metal/CGL "
               "NV12 and P010 import, HEVC configuration, bounded "
               "backpressure, flush, and shutdown passed\n";
  return EXIT_SUCCESS;
}
