#include "platform/macos/video_toolbox_decoder.hpp"
#include "platform/macos/native_video_limits.hpp"

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

// Valid Main-profile hvcC containing VPS/SPS/PPS. Keeping this metadata in the
// binary makes the limits-only gate independent of external or cloud-backed
// media fixtures.
constexpr std::uint8_t kFixtureFreeHvcC[] = {
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

void testSharedLimitBoundaries() {
  using namespace wam::macos::native_video_limits;
  static_assert(kMaximumCompressedVideoAccessUnitBytes ==
                8ULL * 1024ULL * 1024ULL);
  static_assert(kMaximumVideoCodecConfigurationBytes ==
                256ULL * 1024ULL);
  static_assert(kMaximumTransientVideoCodecConfigurationBytes ==
                768ULL * 1024ULL);
  static_assert(kMaximumRetainedVideoCodecConfigurationBytes ==
                256ULL * 1024ULL);
  static_assert(acceptsCompressedVideoAccessUnitSize(
      kMaximumCompressedVideoAccessUnitBytes));
  static_assert(!acceptsCompressedVideoAccessUnitSize(
      kMaximumCompressedVideoAccessUnitBytes + 1));
  static_assert(acceptsVideoCodecConfigurationSize(
      kMaximumVideoCodecConfigurationBytes));
  static_assert(!acceptsVideoCodecConfigurationSize(
      kMaximumVideoCodecConfigurationBytes + 1));

  WAM_CHECK(acceptsCompressedVideoAccessUnitSize(
      kMaximumCompressedVideoAccessUnitBytes));
  WAM_CHECK(!acceptsCompressedVideoAccessUnitSize(
      kMaximumCompressedVideoAccessUnitBytes + 1));
  WAM_CHECK(acceptsVideoCodecConfigurationSize(
      kMaximumVideoCodecConfigurationBytes));
  WAM_CHECK(!acceptsVideoCodecConfigurationSize(
      kMaximumVideoCodecConfigurationBytes + 1));
}

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
  bool callbackAllocationOnly{false};
  bool directSampleOnly{false};
};

class ScopedCMSampleBuffer final {
public:
  explicit ScopedCMSampleBuffer(CMSampleBufferRef sample = nullptr) noexcept
      : sample_(sample) {}
  ScopedCMSampleBuffer(const ScopedCMSampleBuffer &) = delete;
  ScopedCMSampleBuffer &operator=(const ScopedCMSampleBuffer &) = delete;
  ScopedCMSampleBuffer(ScopedCMSampleBuffer &&other) noexcept
      : sample_(std::exchange(other.sample_, nullptr)) {}
  ScopedCMSampleBuffer &operator=(ScopedCMSampleBuffer &&) = delete;
  ~ScopedCMSampleBuffer() {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

  [[nodiscard]] CMSampleBufferRef get() const noexcept { return sample_; }
  [[nodiscard]] explicit operator bool() const noexcept {
    return sample_ != nullptr;
  }
  void reset() noexcept {
    if (sample_ != nullptr) {
      CFRelease(sample_);
      sample_ = nullptr;
    }
  }

private:
  CMSampleBufferRef sample_{nullptr};
};

ScopedCMSampleBuffer makeGuardedCompressedSample(
    void *inaccessibleBytes, std::size_t byteCount,
    CMVideoFormatDescriptionRef format) {
  WAM_CHECK(inaccessibleBytes != nullptr);
  WAM_CHECK(byteCount != 0);
  WAM_CHECK(format != nullptr);

  CMBlockBufferRef block = nullptr;
  const OSStatus blockStatus = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, inaccessibleBytes, byteCount, kCFAllocatorNull,
      nullptr, 0, byteCount, 0, &block);
  WAM_CHECK(blockStatus == noErr);
  WAM_CHECK(block != nullptr);

  const CMSampleTimingInfo timing{CMTimeMake(1, 30), kCMTimeZero,
                                  kCMTimeInvalid};
  CMSampleBufferRef sample = nullptr;
  const OSStatus sampleStatus = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, format, 1, 1, &timing, 1, &byteCount,
      &sample);
  CFRelease(block);
  WAM_CHECK(sampleStatus == noErr);
  WAM_CHECK(sample != nullptr);
  return ScopedCMSampleBuffer(sample);
}

wam::macos::VideoStreamConfiguration fixtureFreeStreamConfiguration(
    std::uint64_t generation) {
  wam::macos::VideoStreamConfiguration configuration;
  configuration.codec = kCMVideoCodecType_HEVC;
  configuration.codedSize = {3840, 2160};
  configuration.codecConfiguration = std::span<const std::byte>(
      reinterpret_cast<const std::byte *>(kFixtureFreeHvcC),
      sizeof(kFixtureFreeHvcC));
  configuration.preferHardwareDecode = false;
  configuration.requireHardwareDecode = false;
  configuration.generation = generation;
  return configuration;
}

void testFixtureFreeProductionLimitAdmission() {
  using wam::macos::VideoToolboxDecoderTestAccess;
  using namespace wam::macos::native_video_limits;
  constexpr std::uint64_t generation = 61;

  std::string error;
  CMVideoFormatDescriptionRef format = nullptr;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::copyFormatDescription(
                       fixtureFreeStreamConfiguration(generation), &format,
                       &error),
                   error);
  WAM_CHECK(format != nullptr);
  CMVideoFormatDescriptionRef equivalentFormat = nullptr;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::copyFormatDescription(
                       fixtureFreeStreamConfiguration(generation),
                       &equivalentFormat, &error),
                   error);
  WAM_CHECK(equivalentFormat != nullptr);
  WAM_CHECK_DETAIL(
      VideoToolboxDecoderTestAccess::equivalentFormatConfigurations(
          format, equivalentFormat, &error),
      error);

  // Exercise the exact production selector used on a direct sample's
  // format-description extensions. The atom bytes remain PROT_NONE: the
  // boundary decision must use only CFData metadata, and cap+1 must reject
  // before byte equality or codec parsing can touch the guarded address.
  constexpr std::size_t guardedConfigurationBytes =
      kMaximumVideoCodecConfigurationBytes + 1;
  void *guardedConfiguration =
      mmap(nullptr, guardedConfigurationBytes, PROT_NONE,
           MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(guardedConfiguration != MAP_FAILED);
  const auto exerciseDirectConfiguration =
      [&](std::size_t byteCount, bool expectedAdmission) {
        CFDataRef atom = CFDataCreateWithBytesNoCopy(
            kCFAllocatorDefault,
            static_cast<const UInt8 *>(guardedConfiguration),
            static_cast<CFIndex>(byteCount), kCFAllocatorNull);
        WAM_CHECK(atom != nullptr);
        const void *atomKeys[] = {CFSTR("hvcC")};
        const void *atomValues[] = {atom};
        CFDictionaryRef atoms = CFDictionaryCreate(
            kCFAllocatorDefault, atomKeys, atomValues, 1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        WAM_CHECK(atoms != nullptr);
        const void *extensionKeys[] = {
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms};
        const void *extensionValues[] = {atoms};
        CFDictionaryRef extensions = CFDictionaryCreate(
            kCFAllocatorDefault, extensionKeys, extensionValues, 1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        WAM_CHECK(extensions != nullptr);

        std::size_t admittedBytes = 0;
        const bool admitted =
            VideoToolboxDecoderTestAccess::inspectDirectConfigurationExtensions(
                kCMVideoCodecType_HEVC, extensions, &admittedBytes, &error);
        WAM_CHECK(admitted == expectedAdmission);
        if (expectedAdmission) {
          WAM_CHECK(error.empty());
          WAM_CHECK(admittedBytes == byteCount);
        } else {
          WAM_CHECK(error.find("256 KiB") != std::string::npos);
          WAM_CHECK(admittedBytes == 0);
        }
        CFRelease(extensions);
        CFRelease(atoms);
        CFRelease(atom);
      };
  exerciseDirectConfiguration(kMaximumVideoCodecConfigurationBytes, true);
  exerciseDirectConfiguration(kMaximumVideoCodecConfigurationBytes + 1,
                              false);
  WAM_CHECK(munmap(guardedConfiguration, guardedConfigurationBytes) == 0);

  // The production metadata gate admits the exact boundary without touching
  // it. The full production builder must reject cap+1 before CFDataCreate can
  // touch the media-controlled address.
  constexpr std::size_t oversizedConfigurationBytes =
      kMaximumVideoCodecConfigurationBytes + 1;
  void *inaccessibleConfiguration =
      mmap(nullptr, oversizedConfigurationBytes, PROT_NONE,
           MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(inaccessibleConfiguration != MAP_FAILED);
  auto boundaryConfiguration = fixtureFreeStreamConfiguration(generation);
  boundaryConfiguration.codecConfiguration = std::span<const std::byte>(
      static_cast<const std::byte *>(inaccessibleConfiguration),
      kMaximumVideoCodecConfigurationBytes);
  WAM_CHECK(VideoToolboxDecoderTestAccess::admitsConfigurationMetadata(
      boundaryConfiguration));
  auto oversizedConfiguration = fixtureFreeStreamConfiguration(generation);
  oversizedConfiguration.codecConfiguration = std::span<const std::byte>(
      static_cast<const std::byte *>(inaccessibleConfiguration),
      oversizedConfigurationBytes);
  WAM_CHECK(!VideoToolboxDecoderTestAccess::admitsConfigurationMetadata(
      oversizedConfiguration));
  CMVideoFormatDescriptionRef rejectedFormat = nullptr;
  WAM_CHECK(!VideoToolboxDecoderTestAccess::copyFormatDescription(
      oversizedConfiguration, &rejectedFormat, &error));
  WAM_CHECK(rejectedFormat == nullptr);
  WAM_CHECK(munmap(inaccessibleConfiguration,
                   oversizedConfigurationBytes) == 0);

  const auto exerciseDirectMetadata =
      [&](std::size_t byteCount, bool expectedAdmission) {
        void *inaccessibleBytes =
            mmap(nullptr, byteCount, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        WAM_CHECK(inaccessibleBytes != MAP_FAILED);
        {
          ScopedCMSampleBuffer sample = makeGuardedCompressedSample(
              inaccessibleBytes, byteCount, format);
          std::size_t admittedBytes = 0;
          std::size_t admittedConfigurationBytes = 0;
          const bool admitted =
              VideoToolboxDecoderTestAccess::inspectDirectSampleMetadata(
                  sample.get(), &admittedBytes,
                  &admittedConfigurationBytes, &error);
          WAM_CHECK(admitted == expectedAdmission);
          if (expectedAdmission) {
            WAM_CHECK(error.empty());
            WAM_CHECK(admittedBytes == byteCount);
            WAM_CHECK(admittedConfigurationBytes ==
                      sizeof(kFixtureFreeHvcC));
          } else {
            WAM_CHECK(error.find("8 MiB") != std::string::npos);
            WAM_CHECK(admittedBytes == 0);
            WAM_CHECK(admittedConfigurationBytes == 0);
          }
        }
        WAM_CHECK(munmap(inaccessibleBytes, byteCount) == 0);
      };

  // Both calls traverse the real direct-CMSampleBuffer metadata validator.
  // PROT_NONE makes any accidental flatten/copy/payload read deterministic.
  exerciseDirectMetadata(kMaximumCompressedVideoAccessUnitBytes, true);
  exerciseDirectMetadata(kMaximumCompressedVideoAccessUnitBytes + 1, false);
  CFRelease(equivalentFormat);
  CFRelease(format);
}

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
    } else if (argument == "--callback-allocation-only") {
      WAM_CHECK_DETAIL(!result.callbackAllocationOnly,
                       "--callback-allocation-only was supplied more than once");
      result.callbackAllocationOnly = true;
    } else if (argument == "--direct-sample-only") {
      WAM_CHECK_DETAIL(!result.directSampleOnly,
                       "--direct-sample-only was supplied more than once");
      result.directSampleOnly = true;
    } else {
      WAM_CHECK_DETAIL(!argument.starts_with("--"),
                       "unknown VideoToolbox test option");
      mediaPaths.push_back(argv[index]);
    }
  }

  WAM_CHECK_DETAIL(mediaPaths.size() == 1 || mediaPaths.size() == 2,
                   "usage: wam_video_toolbox_decoder_test "
                   "[--require-hardware] [--callback-allocation-only | "
                   "--direct-sample-only] "
                   "sample-h264.mp4 "
                   "[sample-main10-hevc.mp4]");
  WAM_CHECK_DETAIL(!(result.callbackAllocationOnly && result.directSampleOnly),
                   "isolated decoder test modes are mutually exclusive");
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
                                 std::size_t minimumPackets,
                                 std::size_t maximumPackets) {
  WAM_CHECK(maximumPackets >= minimumPackets);
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
       readAttempt < 64 && video.packets.size() < maximumPackets;
       ++readAttempt) {
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

ScopedCMSampleBuffer copyFirstCompressedKeySample(
    const char *path, CMVideoCodecType expectedCodec) {
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

  for (std::size_t readAttempt = 0; readAttempt < 64; ++readAttempt) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == nullptr) {
      break;
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    CMFormatDescriptionRef format =
        CMSampleBufferGetFormatDescription(sample);
    const bool usable =
        block != nullptr && CMBlockBufferGetDataLength(block) != 0 &&
        CMSampleBufferGetNumSamples(sample) == 1 && format != nullptr &&
        CMFormatDescriptionGetMediaSubType(format) == expectedCodec &&
        sampleIsKeyFrame(sample);
    if (usable) {
      [reader cancelReading];
      return ScopedCMSampleBuffer(sample);
    }
    CFRelease(sample);
  }
  const std::string diagnostic =
      reader.error == nil
          ? std::string("AVAssetReader did not yield a compressed key sample")
          : std::string(reader.error.localizedDescription.UTF8String);
  [reader cancelReading];
  WAM_CHECK_DETAIL(false, diagnostic);
  return ScopedCMSampleBuffer();
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

class CGLInteropContext final {
public:
  explicit CGLInteropContext(bool forceCoreProfileFallback = false) {
    const CGLPixelFormatAttribute acceleratedAttributes[] = {
        kCGLPFAAccelerated,
        kCGLPFAOpenGLProfile,
        static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_3_2_Core),
        static_cast<CGLPixelFormatAttribute>(0)};
    const CGLPixelFormatAttribute coreProfileAttributes[] = {
        kCGLPFAOpenGLProfile,
        static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_3_2_Core),
        static_cast<CGLPixelFormatAttribute>(0)};

    if (!forceCoreProfileFallback &&
        choosePixelFormat(acceleratedAttributes, &pixelFormat_)) {
      usedCoreProfileFallback_ = false;
    } else {
      usedCoreProfileFallback_ = true;
      WAM_CHECK_DETAIL(choosePixelFormat(coreProfileAttributes, &pixelFormat_),
                       "no OpenGL 3.2 core CGL pixel format is available");
    }

    GLint profile = 0;
    const CGLError profileStatus = CGLDescribePixelFormat(
        pixelFormat_, 0, kCGLPFAOpenGLProfile, &profile);
    WAM_CHECK_DETAIL(profileStatus == kCGLNoError,
                     CGLErrorString(profileStatus));
    WAM_CHECK_DETAIL(
        profile == static_cast<GLint>(kCGLOGLPVersion_3_2_Core),
        "CGL selected a pixel format outside the OpenGL 3.2 core contract");
    GLint accelerated = 0;
    const CGLError describeStatus = CGLDescribePixelFormat(
        pixelFormat_, 0, kCGLPFAAccelerated, &accelerated);
    WAM_CHECK_DETAIL(describeStatus == kCGLNoError,
                     CGLErrorString(describeStatus));
    accelerated_ = accelerated != 0;
    WAM_CHECK_DETAIL(usedCoreProfileFallback_ || accelerated_,
                     "the acceleration-constrained CGL selection was not "
                     "accelerated");
    const CGLError createStatus =
        CGLCreateContext(pixelFormat_, nullptr, &context_);
    WAM_CHECK_DETAIL(createStatus == kCGLNoError,
                     CGLErrorString(createStatus));
    WAM_CHECK(context_ != nullptr);
  }

  CGLInteropContext(const CGLInteropContext &) = delete;
  CGLInteropContext &operator=(const CGLInteropContext &) = delete;

  ~CGLInteropContext() {
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
  [[nodiscard]] bool accelerated() const noexcept { return accelerated_; }
  [[nodiscard]] bool usedCoreProfileFallback() const noexcept {
    return usedCoreProfileFallback_;
  }

private:
  static bool choosePixelFormat(const CGLPixelFormatAttribute *attributes,
                                CGLPixelFormatObj *pixelFormat) {
    CGLPixelFormatObj candidate = nullptr;
    GLint count = 0;
    const CGLError status =
        CGLChoosePixelFormat(attributes, &candidate, &count);
    if (status != kCGLNoError || candidate == nullptr || count <= 0) {
      if (candidate != nullptr) {
        CGLDestroyPixelFormat(candidate);
      }
      return false;
    }
    *pixelFormat = candidate;
    return true;
  }

  CGLPixelFormatObj pixelFormat_{nullptr};
  CGLContextObj context_{nullptr};
  bool accelerated_{false};
  bool usedCoreProfileFallback_{false};
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

void testForcedCGLCoreProfileFallback() {
  CGLInteropContext fallbackContext(true);
  WAM_CHECK(fallbackContext.usedCoreProfileFallback());
  CVPixelBufferRef nv12 = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 128, 64,
      wam::macos::VideoToolboxOutputInterop::OpenGL);
  bindIOSurfacePlanesWithCGL(fallbackContext.get(), nv12);
  CVPixelBufferRelease(nv12);
  std::cout << "Forced CGL 3.2-core fallback import passed ("
            << (fallbackContext.accelerated() ? "accelerated"
                                              : "non-accelerated")
            << " renderer)\n";
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

void testPersistentFrameRefConSlotLifecycle() {
  using wam::macos::BoundedFrameQueue;
  using wam::macos::FrameTiming;
  using wam::macos::VideoDecodeSubmitResult;
  using wam::macos::VideoToolboxDecoder;
  using wam::macos::VideoToolboxDecoderOptions;
  using wam::macos::VideoToolboxDecoderTestAccess;

  constexpr std::uint64_t firstGeneration = 301;
  constexpr std::uint64_t secondGeneration = 302;
  constexpr std::size_t capacity = 3;
  BoundedFrameQueue firstSink(capacity, firstGeneration);
  VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = capacity;
  options.maxPendingPresentationFrames = 1;
  VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, firstSink, firstGeneration, &error),
                   error);

  auto slots = VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(slots.capacity == capacity);
  WAM_CHECK(slots.available == capacity);
  WAM_CHECK(slots.submitted == 0);
  WAM_CHECK(slots.callbackComplete == 0);
  WAM_CHECK(slots.inFlight == 0);

  std::array<std::uint64_t, capacity> sequences{};
  constexpr std::array<std::size_t, capacity> compressedBytes{11, 17, 19};
  constexpr std::array<bool, capacity> directStorage{true, false, true};
  for (std::size_t index = 0; index < capacity; ++index) {
    const FrameTiming timing{CMTimeMake(static_cast<std::int64_t>(index), 30),
                             CMTimeMake(1, 30), firstGeneration, index == 0};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
                         decoder, timing, &sequences[index], &error,
                         compressedBytes[index], directStorage[index]) ==
                         VideoDecodeSubmitResult::Accepted,
                     error);
    WAM_CHECK(sequences[index] == index);
  }
  slots = VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(slots.available == 0);
  WAM_CHECK(slots.submitted == capacity);
  WAM_CHECK(slots.inFlight == capacity);
  auto memory = decoder.memoryFacts();
  WAM_CHECK(memory.inFlightFrames == capacity);
  WAM_CHECK(memory.presentationFrames == 0);
  WAM_CHECK(memory.currentDirectCompressedBytes == 30);
  WAM_CHECK(memory.peakDirectCompressedBytes == 30);
  WAM_CHECK(memory.currentCopiedCompressedBytes == 17);
  WAM_CHECK(memory.peakCopiedCompressedBytes == 17);
  WAM_CHECK(memory.currentCompressedBytes == 47);
  WAM_CHECK(memory.peakCompressedBytes == 47);
  std::uint64_t rejectedSequence = 0;
  WAM_CHECK(VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
                decoder,
                FrameTiming{CMTimeMake(3, 30), CMTimeMake(1, 30),
                            firstGeneration, false},
                &rejectedSequence, &error) ==
            VideoDecodeSubmitResult::Backpressure);

  // The later persistent callback becomes CallbackComplete but cannot free
  // its slot or admission credit before the missing earlier sequence.
  const FrameTiming secondTiming{CMTimeMake(1, 30), CMTimeMake(1, 30),
                                 firstGeneration, false};
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                       decoder, sequences[1], nullptr, secondTiming, noErr,
                       kVTDecodeInfo_FrameDropped, &error),
                   error);
  slots = VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(slots.submitted == capacity - 1);
  WAM_CHECK(slots.callbackComplete == 1);
  WAM_CHECK(slots.available == 0);
  WAM_CHECK(slots.inFlight == capacity);
  memory = decoder.memoryFacts();
  WAM_CHECK(memory.inFlightFrames == capacity);
  WAM_CHECK(memory.currentDirectCompressedBytes == 30);
  WAM_CHECK(memory.currentCopiedCompressedBytes == 17);
  WAM_CHECK(memory.currentCompressedBytes == 47);

  // An immediate DecodeFrame API rejection is guaranteed not to receive a
  // callback. Its synthetic tombstone owns and retires the same slot exactly
  // once, but remains ordered behind sequence zero.
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::rejectInjectedSubmission(
                       decoder, sequences[2], paramErr, &error),
                   error);
  slots = VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(slots.submitted == 1);
  WAM_CHECK(slots.callbackComplete == 2);
  WAM_CHECK(slots.inFlight == capacity);
  memory = decoder.memoryFacts();
  WAM_CHECK(memory.inFlightFrames == capacity);
  WAM_CHECK(memory.currentDirectCompressedBytes == 30);
  WAM_CHECK(memory.currentCopiedCompressedBytes == 17);
  WAM_CHECK(memory.currentCompressedBytes == 47);

  const FrameTiming firstTiming{CMTimeMake(0, 30), CMTimeMake(1, 30),
                                firstGeneration, true};
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                       decoder, sequences[0], nullptr, firstTiming, noErr,
                       kVTDecodeInfo_FrameDropped, &error),
                   error);
  slots = VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(slots.available == capacity);
  WAM_CHECK(slots.submitted == 0);
  WAM_CHECK(slots.callbackComplete == 0);
  WAM_CHECK(slots.inFlight == 0);
  WAM_CHECK(slots.activeCallbacks == 0);
  memory = decoder.memoryFacts();
  WAM_CHECK(memory.inFlightFrames == 0);
  WAM_CHECK(memory.currentDirectCompressedBytes == 0);
  WAM_CHECK(memory.currentCopiedCompressedBytes == 0);
  WAM_CHECK(memory.currentCompressedBytes == 0);
  WAM_CHECK(memory.peakDirectCompressedBytes == 30);
  WAM_CHECK(memory.peakCopiedCompressedBytes == 17);
  WAM_CHECK(memory.peakCompressedBytes == 47);
  WAM_CHECK(decoder.takeLastError().has_value());

  // Reconfiguration is a generation barrier and reuses, rather than grows,
  // the same fixed slot pool. Closing returns with every slot available.
  BoundedFrameQueue secondSink(capacity, secondGeneration);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, secondSink, secondGeneration, &error),
                   error);
  slots = VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(slots.capacity == capacity);
  WAM_CHECK(slots.available == capacity);
  WAM_CHECK(slots.generation == secondGeneration);
  memory = decoder.memoryFacts();
  WAM_CHECK(memory.inFlightFrames == 0);
  WAM_CHECK(memory.presentationFrames == 0);
  WAM_CHECK(memory.currentCompressedBytes == 0);
  WAM_CHECK(memory.peakCompressedBytes == 0);
  std::uint64_t oldSequence = 0;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
                       decoder,
                       FrameTiming{CMTimeMake(0, 1), CMTimeMake(1, 30),
                                   firstGeneration, true},
                       &oldSequence, &error) ==
                       VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                       decoder, oldSequence, nullptr,
                       FrameTiming{CMTimeMake(0, 1), CMTimeMake(1, 30),
                                   firstGeneration, true},
                       noErr, kVTDecodeInfo_FrameDropped, &error),
                   error);
  WAM_CHECK(decoder.stats().droppedFrames >= 1);
  decoder.close();
  slots = VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(slots.available == capacity);
  WAM_CHECK(slots.submitted == 0);
  WAM_CHECK(slots.callbackComplete == 0);
  WAM_CHECK(slots.inFlight == 0);
  WAM_CHECK(slots.activeCallbacks == 0);
}

class BlockingProgressProbe final {
public:
  [[nodiscard]] wam::macos::VideoToolboxDecoderProgressHandler
  handler() noexcept {
    return {&BlockingProgressProbe::notify, this};
  }

  bool waitUntilEntered() {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, std::chrono::seconds(5),
                               [this] { return entered_; });
  }

  void release() {
    std::lock_guard lock(mutex_);
    released_ = true;
    condition_.notify_all();
  }

private:
  static void notify(void *context) noexcept {
    // Deliberately blocking test-only handler: production handlers obey the
    // nonblocking contract. This gate makes the post-notification callback
    // tail observable so close() can prove it waits through callback return.
    auto &probe = *static_cast<BlockingProgressProbe *>(context);
    std::unique_lock lock(probe.mutex_);
    probe.entered_ = true;
    probe.condition_.notify_all();
    probe.condition_.wait(lock, [&probe] { return probe.released_; });
  }

  std::mutex mutex_;
  std::condition_variable condition_;
  bool entered_{false};
  bool released_{false};
};

void testPersistentCallbackTailBlocksClose() {
  constexpr std::uint64_t generation = 311;
  BlockingProgressProbe probe;
  wam::macos::BoundedFrameQueue sink(1, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.maxPendingPresentationFrames = 1;
  options.progressHandler = probe.handler();
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
          decoder, sink, generation, &error),
      error);
  std::uint64_t sequence = 0;
  const wam::macos::FrameTiming timing{
      CMTimeMake(0, 1), CMTimeMake(1, 30), generation, true};
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
          decoder, timing, &sequence, &error) ==
          wam::macos::VideoDecodeSubmitResult::Accepted,
      error);

  std::atomic<bool> callbackReturned{false};
  std::atomic<bool> closeEntered{false};
  std::atomic<bool> closeReturned{false};
  std::thread callback([&] {
    std::string callbackError;
    WAM_CHECK_DETAIL(
        wam::macos::VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
            decoder, sequence, nullptr, timing, noErr,
            kVTDecodeInfo_FrameDropped, &callbackError),
        callbackError);
    callbackReturned.store(true, std::memory_order_release);
  });
  WAM_CHECK_DETAIL(probe.waitUntilEntered(),
                   "persistent callback did not reach progress tail");
  auto active =
      wam::macos::VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(active.inFlight == 0);
  WAM_CHECK(active.activeCallbacks == 1);
  WAM_CHECK(active.available == 1);

  std::thread closer([&] {
    closeEntered.store(true, std::memory_order_release);
    decoder.close();
    closeReturned.store(true, std::memory_order_release);
  });
  const auto closeDeadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!closeEntered.load(std::memory_order_acquire) &&
         std::chrono::steady_clock::now() < closeDeadline) {
    std::this_thread::yield();
  }
  WAM_CHECK(closeEntered.load(std::memory_order_acquire));
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  WAM_CHECK(!callbackReturned.load(std::memory_order_acquire));
  WAM_CHECK(!closeReturned.load(std::memory_order_acquire));
  probe.release();
  callback.join();
  closer.join();
  WAM_CHECK(callbackReturned.load(std::memory_order_acquire));
  WAM_CHECK(closeReturned.load(std::memory_order_acquire));
  const auto closed =
      wam::macos::VideoToolboxDecoderTestAccess::frameRefConSlotStats(decoder);
  WAM_CHECK(closed.available == 1);
  WAM_CHECK(closed.inFlight == 0);
  WAM_CHECK(closed.activeCallbacks == 0);
}

class SurfaceBudgetTrackingSink final : public wam::macos::DecodedFrameSink {
public:
  wam::macos::FrameEnqueueResult enqueue(wam::macos::FrameLease frame,
                                         std::string *error) override {
    if (error != nullptr) {
      error->clear();
    }
    ++enqueueCalls;
    heldFrame = std::move(frame);
    return wam::macos::FrameEnqueueResult::Accepted;
  }

  void endOfStream(std::uint64_t) override {}

  void flush(std::uint64_t nextGeneration) noexcept override {
    ++flushCalls;
    lastFlushGeneration = nextGeneration;
    if (!heldFrame) {
      return;
    }
    surfaceCountAtHeldFlush =
        wam::macos::NativeSurfaceBudget::stats().currentSurfaces;
    bufferAliveAtHeldFlush = heldFrame.pixelBuffer() != nullptr &&
                             heldFrame.ioSurface() != nullptr;
    heldFrame.reset();
    surfaceCountAfterHeldFlush =
        wam::macos::NativeSurfaceBudget::stats().currentSurfaces;
  }

  std::size_t enqueueCalls{0};
  std::size_t flushCalls{0};
  std::uint64_t lastFlushGeneration{0};
  std::uint64_t surfaceCountAtHeldFlush{0};
  std::uint64_t surfaceCountAfterHeldFlush{0};
  bool bufferAliveAtHeldFlush{false};
  wam::macos::FrameLease heldFrame;
};

class ProgressWakeProbe final {
public:
  [[nodiscard]] wam::macos::VideoToolboxDecoderProgressHandler
  handler() noexcept {
    return {&ProgressWakeProbe::notify, this};
  }

  wam::macos::VideoToolboxDecoder *decoder{nullptr};
  std::atomic<std::uint64_t> calls{0};
  std::atomic<std::size_t> lastInFlight{
      std::numeric_limits<std::size_t>::max()};
  std::atomic<bool> callbackLocksWereAvailable{true};

private:
  static void notify(void *context) noexcept {
    auto &probe = *static_cast<ProgressWakeProbe *>(context);
    std::size_t inFlight = std::numeric_limits<std::size_t>::max();
    const bool locksAvailable =
        probe.decoder != nullptr &&
        wam::macos::VideoToolboxDecoderTestAccess::inspectProgressState(
            *probe.decoder, &inFlight);
    if (!locksAvailable) {
      probe.callbackLocksWereAvailable.store(false,
                                              std::memory_order_release);
    } else {
      probe.lastInFlight.store(inFlight, std::memory_order_release);
    }
    probe.calls.fetch_add(1, std::memory_order_release);
  }
};

void testEventDrivenDecoderProgressWake() {
  using wam::macos::BoundedFrameQueue;
  using wam::macos::FrameLease;
  using wam::macos::FrameTiming;
  using wam::macos::NativeSurfaceBudget;
  using wam::macos::VideoDecodeSubmitResult;
  using wam::macos::VideoToolboxDecoder;
  using wam::macos::VideoToolboxDecoderOptions;
  using wam::macos::VideoToolboxDecoderTestAccess;
  using wam::macos::kNativeSurfaceBudgetMaximumSurfaces;

  // A no-frame completion is an ordered tombstone. Its callback must publish
  // the 2 -> 1 admission-credit transition before signalling the owner, and
  // the signal must run after both callback-owned locks have been released.
  {
    constexpr std::uint64_t generation = 81;
    ProgressWakeProbe probe;
    BoundedFrameQueue sink(2, generation);
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 2;
    options.maxPendingPresentationFrames = 1;
    options.progressHandler = probe.handler();
    VideoToolboxDecoder decoder(options);
    probe.decoder = &decoder;
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 2, &error),
                     error);
    const FrameTiming timing{CMTimeMake(0, 1), CMTimeMake(1, 30), generation,
                             true};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                         decoder, 0, nullptr, timing, noErr,
                         kVTDecodeInfo_FrameDropped, &error),
                     error);
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 1);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 1);
    WAM_CHECK(probe.callbackLocksWereAvailable.load(
        std::memory_order_acquire));
    WAM_CHECK(decoder.stats().inFlightFrames == 1);

    const FrameTiming secondTiming{CMTimeMake(1, 30), CMTimeMake(1, 30),
                                   generation, false};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                         decoder, 1, nullptr, secondTiming, noErr,
                         kVTDecodeInfo_FrameDropped, &error),
                     error);
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 2);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 0);
    decoder.close();
  }

  // A successfully delivered zero-copy frame follows the same edge contract.
  // The injected callback is synchronous, matching VideoToolbox's legal
  // inline-before-submit-returns scheduling mode.
  {
    constexpr std::uint64_t generation = 87;
    ProgressWakeProbe probe;
    BoundedFrameQueue sink(1, generation);
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 1;
    options.maxPendingPresentationFrames = 1;
    options.progressHandler = probe.handler();
    VideoToolboxDecoder decoder(options);
    probe.decoder = &decoder;
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 1, &error),
                     error);
    CVPixelBufferRef surface = createIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
    const FrameTiming timing{CMTimeMake(0, 1), CMTimeMake(1, 30), generation,
                             true};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                         decoder, 0, surface, timing, noErr, 0, &error),
                     error);
    CVPixelBufferRelease(surface);
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 1);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 0);
    WAM_CHECK(probe.callbackLocksWereAvailable.load(
        std::memory_order_acquire));
    WAM_CHECK(decoder.drainPresentation(generation, &error) ==
              wam::macos::VideoDecodeDrainProgress::Progress);
    WAM_CHECK(sink.tryTake().has_value());
    decoder.close();
  }

  // The callback's allocation-failure fail-closed path must also retire its
  // sequence and wake exactly after the error and credit are observable.
  {
    constexpr std::uint64_t generation = 88;
    ProgressWakeProbe probe;
    BoundedFrameQueue sink(1, generation);
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 1;
    options.maxPendingPresentationFrames = 1;
    options.progressHandler = probe.handler();
    VideoToolboxDecoder decoder(options);
    probe.decoder = &decoder;
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 1, &error),
                     error);
    VideoToolboxDecoderTestAccess::failNextCallbackAllocation(
        decoder,
        wam::macos::VideoToolboxDecoderTestAllocationPoint::CompletedDecode);
    const FrameTiming timing{CMTimeMake(0, 1), CMTimeMake(1, 30), generation,
                             true};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                         decoder, 0, nullptr, timing, noErr, 0, &error),
                     error);
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 1);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 0);
    WAM_CHECK(probe.callbackLocksWereAvailable.load(
        std::memory_order_acquire));
    WAM_CHECK(decoder.stats().inFlightFrames == 0);
    const auto callbackError = decoder.takeLastError();
    WAM_CHECK(callbackError.has_value());
    WAM_CHECK(callbackError->find("exhausted bounded storage") !=
              std::string::npos);
    decoder.close();
  }

  // Flush is itself a progress edge, and the immutable callback context must
  // remain usable by a stale callback observed after the generation change.
  {
    constexpr std::uint64_t generation = 82;
    constexpr std::uint64_t nextGeneration = 83;
    ProgressWakeProbe probe;
    BoundedFrameQueue sink(1, generation);
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 1;
    options.maxPendingPresentationFrames = 1;
    options.progressHandler = probe.handler();
    VideoToolboxDecoder decoder(options);
    probe.decoder = &decoder;
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    decoder.flush(nextGeneration);
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 1);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 0);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 1, &error),
                     error);
    const FrameTiming staleTiming{CMTimeMake(0, 1), CMTimeMake(1, 30),
                                  generation, true};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                         decoder, 0, nullptr, staleTiming, noErr, 0, &error),
                     error);
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 2);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 0);
    WAM_CHECK(probe.callbackLocksWereAvailable.load(
        std::memory_order_acquire));
    WAM_CHECK(decoder.stats().droppedFrames == 1);
    decoder.close();
  }

  // Codec failure and output-format failure both retire their sequence and
  // wake the owner; neither error path may strand the admission credit.
  for (const bool formatFailure : {false, true}) {
    constexpr std::uint64_t generation = 84;
    ProgressWakeProbe probe;
    BoundedFrameQueue sink(1, generation);
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 1;
    options.maxPendingPresentationFrames = 1;
    options.progressHandler = probe.handler();
    VideoToolboxDecoder decoder(options);
    probe.decoder = &decoder;
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 1, &error),
                     error);
    CVPixelBufferRef mismatchedSurface = nullptr;
    if (formatFailure) {
      mismatchedSurface = createIOSurfacePixelBuffer(
          kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 64, 32);
    }
    const FrameTiming timing{CMTimeMake(0, 1), CMTimeMake(1, 30), generation,
                             true};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                         decoder, 0, mismatchedSurface, timing,
                         formatFailure ? noErr : -1, 0, &error),
                     error);
    if (mismatchedSurface != nullptr) {
      CVPixelBufferRelease(mismatchedSurface);
    }
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 1);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 0);
    WAM_CHECK(probe.callbackLocksWereAvailable.load(
        std::memory_order_acquire));
    WAM_CHECK(decoder.stats().inFlightFrames == 0);
    WAM_CHECK(decoder.takeLastError().has_value());
    // close() is a separate lifecycle-capacity edge.
    const std::uint64_t callbackCalls =
        probe.calls.load(std::memory_order_acquire);
    decoder.close();
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) ==
              callbackCalls + 1);
  }

  // Surface-budget denial is a recoverable ordered no-frame completion and
  // therefore has the same event-driven retry edge as every other callback.
  {
    WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
    std::array<FrameLease,
               static_cast<std::size_t>(
                   kNativeSurfaceBudgetMaximumSurfaces)>
        occupants;
    for (FrameLease &occupant : occupants) {
      CVPixelBufferRef pixelBuffer = createIOSurfacePixelBuffer(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
      occupant = FrameLease(pixelBuffer);
      CVPixelBufferRelease(pixelBuffer);
      WAM_CHECK(occupant);
    }

    constexpr std::uint64_t generation = 85;
    ProgressWakeProbe probe;
    BoundedFrameQueue sink(1, generation);
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 1;
    options.maxPendingPresentationFrames = 1;
    options.progressHandler = probe.handler();
    VideoToolboxDecoder decoder(options);
    probe.decoder = &decoder;
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 1, &error),
                     error);
    CVPixelBufferRef deniedSurface = createIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
    const FrameTiming timing{CMTimeMake(0, 1), CMTimeMake(1, 30), generation,
                             true};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                         decoder, 0, deniedSurface, timing, noErr, 0, &error),
                     error);
    CVPixelBufferRelease(deniedSurface);
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 1);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 0);
    WAM_CHECK(probe.callbackLocksWereAvailable.load(
        std::memory_order_acquire));
    WAM_CHECK(decoder.stats().surfaceBudgetRejections == 1);
    const std::uint64_t callbackCalls =
        probe.calls.load(std::memory_order_acquire);
    decoder.close();
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) ==
              callbackCalls + 1);
    for (FrameLease &occupant : occupants) {
      occupant.reset();
    }
    WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
  }

  // End-of-stream can release presentation-reorder capacity without another
  // decode callback, so it publishes its own retry edge.
  {
    constexpr std::uint64_t generation = 86;
    ProgressWakeProbe probe;
    BoundedFrameQueue sink(1, generation);
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 1;
    options.maxPendingPresentationFrames = 1;
    options.progressHandler = probe.handler();
    VideoToolboxDecoder decoder(options);
    probe.decoder = &decoder;
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                         VideoDecodeSubmitResult::Accepted,
                     error);
    // Compatibility submit performs two bounded owner-visible transitions:
    // EOS begins, then the zero-frame tail is finalized at the sink.
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == 2);
    WAM_CHECK(probe.lastInFlight.load(std::memory_order_acquire) == 0);
    WAM_CHECK(sink.reachedEndOfStream());
    const std::uint64_t eosCalls = probe.calls.load(std::memory_order_acquire);
    decoder.close();
    WAM_CHECK(probe.calls.load(std::memory_order_acquire) == eosCalls + 1);
  }
}

void testExactDecoderRetirement() {
  using wam::macos::BoundedFrameQueue;
  using wam::macos::VideoDecoderRetireProgress;
  using wam::macos::VideoToolboxDecoder;
  using wam::macos::VideoToolboxDecoderOptions;
  using wam::macos::VideoToolboxDecoderTestAccess;

  constexpr std::uint64_t generation = 121;
  constexpr std::uint64_t invalidation = 130;
  ProgressWakeProbe probe;
  BoundedFrameQueue sink(1, generation);
  VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.maxPendingPresentationFrames = 1;
  options.progressHandler = probe.handler();
  VideoToolboxDecoder decoder(options);
  probe.decoder = &decoder;
  std::string error;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, sink, generation, &error),
                   error);
  WAM_CHECK(decoder.retire(generation - 1, invalidation) ==
            VideoDecoderRetireProgress::StaleGeneration);
  WAM_CHECK(decoder.stats().configured);
  WAM_CHECK(decoder.stats().generation == generation);
  WAM_CHECK(decoder.retire(generation, generation) ==
            VideoDecoderRetireProgress::Failed);
  WAM_CHECK(decoder.stats().generation == generation);

  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                       decoder, 1, &error),
                   error);
  CVPixelBufferRef surface = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  const wam::macos::FrameTiming timing{
      CMTimeMake(0, 1), CMTimeMake(1, 30), generation, true};
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, 0, surface, timing, &error),
                   error);
  CVPixelBufferRelease(surface);
  WAM_CHECK(decoder.stats().pendingPresentationFrames == 1);

  const std::uint64_t callsBefore =
      probe.calls.load(std::memory_order_acquire);
  WAM_CHECK(decoder.retire(generation, invalidation) ==
            VideoDecoderRetireProgress::Done);
  const auto retired = decoder.stats();
  WAM_CHECK(!retired.configured);
  WAM_CHECK(retired.generation == invalidation);
  WAM_CHECK(retired.inFlightFrames == 0);
  WAM_CHECK(retired.retainedPresentationFrames == 0);
  WAM_CHECK(retired.pendingPresentationFrames == 0);
  WAM_CHECK(!retired.acceptsCompressedSample);
  WAM_CHECK(sink.generation() == invalidation);
  WAM_CHECK(probe.calls.load(std::memory_order_acquire) == callsBefore + 1);
  WAM_CHECK(decoder.retire(generation, invalidation) ==
            VideoDecoderRetireProgress::Done);
  WAM_CHECK(decoder.retire(generation, invalidation + 1) ==
            VideoDecoderRetireProgress::StaleGeneration);
  WAM_CHECK(decoder.stats().generation == invalidation);
  decoder.flush(invalidation + 10);
  WAM_CHECK(decoder.stats().generation == invalidation);
  WAM_CHECK(!decoder.configure(fixtureFreeStreamConfiguration(140), sink,
                               &error));
  WAM_CHECK(error == "VideoToolbox decoder was terminally retired");
  decoder.close();
  WAM_CHECK(decoder.stats().generation == invalidation);
}

void testDecodedSurfaceBudgetTombstoneAndGenerationFlush() {
  using wam::macos::FrameLease;
  using wam::macos::NativeSurfaceBudget;
  using wam::macos::VideoToolboxDecoder;
  using wam::macos::VideoToolboxDecoderOptions;
  using wam::macos::VideoToolboxDecoderTestAccess;
  using wam::macos::kNativeSurfaceBudgetMaximumSurfaces;

  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
  WAM_CHECK(NativeSurfaceBudget::stats().currentBytes == 0);

  // A delivered old-generation frame remains accounted and keeps its
  // IOSurface alive until the sink's generation flush explicitly releases it.
  {
    constexpr std::uint64_t generation = 71;
    constexpr std::uint64_t nextGeneration = 72;
    SurfaceBudgetTrackingSink sink;
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 1;
    options.maxPendingPresentationFrames = 1;
    VideoToolboxDecoder decoder(options);
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 1, &error),
                     error);
    CVPixelBufferRef pixelBuffer = createIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
    const wam::macos::FrameTiming timing{
        CMTimeMake(0, 1), CMTimeMake(1, 30), generation, true};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                         decoder, 0, pixelBuffer, timing, &error),
                     error);
    CVPixelBufferRelease(pixelBuffer);

    WAM_CHECK(decoder.drainPresentation(generation, &error) ==
              wam::macos::VideoDecodeDrainProgress::Progress);
    WAM_CHECK(sink.enqueueCalls == 1);
    WAM_CHECK(sink.heldFrame);
    WAM_CHECK(decoder.stats().inFlightFrames == 0);
    WAM_CHECK(decoder.stats().surfaceBudgetRejections == 0);
    WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 1);
    decoder.flush(nextGeneration);
    WAM_CHECK(sink.flushCalls == 2);
    WAM_CHECK(sink.lastFlushGeneration == nextGeneration);
    WAM_CHECK(sink.bufferAliveAtHeldFlush);
    WAM_CHECK(sink.surfaceCountAtHeldFlush == 1);
    WAM_CHECK(sink.surfaceCountAfterHeldFlush == 0);
    WAM_CHECK(!sink.heldFrame);
    WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
    decoder.close();
  }

  // If a callback-owned container operation fails after admission, unwinding
  // must release both the FrameLease token and its retained pixel buffer while
  // the ordered fail-closed path retires the submission credit.
  {
    constexpr std::uint64_t generation = 74;
    SurfaceBudgetTrackingSink sink;
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 1;
    options.maxPendingPresentationFrames = 1;
    VideoToolboxDecoder decoder(options);
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 1, &error),
                     error);
    VideoToolboxDecoderTestAccess::failNextCallbackAllocation(
        decoder,
        wam::macos::VideoToolboxDecoderTestAllocationPoint::
            PendingPresentation);
    CVPixelBufferRef pixelBuffer = createIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
    const wam::macos::FrameTiming timing{
        CMTimeMake(0, 1), CMTimeMake(1, 30), generation, true};
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                         decoder, 0, pixelBuffer, timing, &error),
                     error);
    CVPixelBufferRelease(pixelBuffer);
    WAM_CHECK(decoder.stats().inFlightFrames == 0);
    WAM_CHECK(decoder.stats().deliveredFrames == 0);
    WAM_CHECK(sink.enqueueCalls == 0);
    WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
    WAM_CHECK(NativeSurfaceBudget::stats().currentBytes == 0);
    const auto callbackError = decoder.takeLastError();
    WAM_CHECK(callbackError.has_value());
    WAM_CHECK(callbackError->find("exhausted bounded storage") !=
              std::string::npos);
    decoder.close();
  }

  // Ten small, unique decoded leases fill the count ceiling without using a
  // large fixture. The next otherwise-valid callback must become an ordered
  // tombstones: two drops, two budget rejections, zero sink calls, and zero
  // residual in-flight credit after the earlier sequence closes the gap.
  {
    constexpr std::uint64_t generation = 73;
    std::array<FrameLease,
               static_cast<std::size_t>(
                   kNativeSurfaceBudgetMaximumSurfaces)>
        occupants;
    for (FrameLease &occupant : occupants) {
      CVPixelBufferRef pixelBuffer = createIOSurfacePixelBuffer(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
      occupant = FrameLease(pixelBuffer);
      CVPixelBufferRelease(pixelBuffer);
      WAM_CHECK(occupant);
    }
    WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces ==
              kNativeSurfaceBudgetMaximumSurfaces);

    SurfaceBudgetTrackingSink sink;
    VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 2;
    options.maxPendingPresentationFrames = 1;
    VideoToolboxDecoder decoder(options);
    std::string error;
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         decoder, sink, generation, &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         decoder, 2, &error),
                     error);
    CVPixelBufferRef firstDeniedBuffer = createIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
    CVPixelBufferRef secondDeniedBuffer = createIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
    const wam::macos::FrameTiming firstTiming{
        CMTimeMake(0, 1), CMTimeMake(1, 30), generation, true};
    const wam::macos::FrameTiming secondTiming{
        CMTimeMake(1, 30), CMTimeMake(1, 30), generation, false};

    // The later denial must remain behind the missing earlier callback and
    // may not prematurely retire its own admission credit.
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                         decoder, 1, secondDeniedBuffer, secondTiming, &error),
                     error);
    WAM_CHECK(decoder.stats().inFlightFrames == 2);
    WAM_CHECK(sink.enqueueCalls == 0);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                         decoder, 0, firstDeniedBuffer, firstTiming, &error),
                     error);
    CVPixelBufferRelease(firstDeniedBuffer);
    CVPixelBufferRelease(secondDeniedBuffer);

    const auto stats = decoder.stats();
    WAM_CHECK(stats.inFlightFrames == 0);
    WAM_CHECK(stats.deliveredFrames == 0);
    WAM_CHECK(stats.droppedFrames == 2);
    WAM_CHECK(stats.surfaceBudgetRejections == 2);
    WAM_CHECK(stats.pendingPresentationFrames == 0);
    WAM_CHECK(sink.enqueueCalls == 0);
    WAM_CHECK(!sink.heldFrame);
    WAM_CHECK(!decoder.takeLastError().has_value());
    decoder.close();

    // The public statistic is saturating: another denied callback at the
    // numeric ceiling cannot wrap the counter to zero.
    SurfaceBudgetTrackingSink saturationSink;
    VideoToolboxDecoder saturationDecoder(options);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                         saturationDecoder, saturationSink, generation,
                         &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::setSurfaceBudgetRejections(
                         saturationDecoder,
                         std::numeric_limits<std::uint64_t>::max(), &error),
                     error);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                         saturationDecoder, 1, &error),
                     error);
    CVPixelBufferRef saturationDeniedBuffer = createIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
    WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                         saturationDecoder, 0, saturationDeniedBuffer,
                         firstTiming, &error),
                     error);
    CVPixelBufferRelease(saturationDeniedBuffer);
    WAM_CHECK(saturationDecoder.stats().inFlightFrames == 0);
    WAM_CHECK(saturationDecoder.stats().surfaceBudgetRejections ==
              std::numeric_limits<std::uint64_t>::max());
    WAM_CHECK(saturationSink.enqueueCalls == 0);
    saturationDecoder.close();
    for (FrameLease &occupant : occupants) {
      occupant.reset();
    }
  }

  WAM_CHECK(NativeSurfaceBudget::stats().currentSurfaces == 0);
  WAM_CHECK(NativeSurfaceBudget::stats().currentBytes == 0);
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
  while (decoder.drainPresentation(generation, &error) ==
         wam::macos::VideoDecodeDrainProgress::Progress) {
  }

  std::vector<std::int64_t> deliveredPts;
  while (auto frame = queue.tryTake()) {
    deliveredPts.push_back(frame->timing().presentationTime.value);
  }
  WAM_CHECK((deliveredPts == std::vector<std::int64_t>{0, 1, 2, 3}));
  const auto stats = decoder.stats();
  WAM_CHECK(stats.codecReorderFrames == reorderDepth);
  WAM_CHECK(stats.peakPendingPresentationFrames <=
            reorderDepth + options.maxInFlightFrames);
  WAM_CHECK(stats.deliveredFrames == 4);
  WAM_CHECK(stats.droppedFrames == 0);
  WAM_CHECK(stats.outOfOrderDrops == 0);
  WAM_CHECK(stats.inFlightFrames == 0);
  WAM_CHECK(!decoder.takeLastError().has_value());
  decoder.close();
}

class OneSlotIdentitySink final : public wam::macos::DecodedFrameSink {
public:
  wam::macos::FrameEnqueueResult enqueue(wam::macos::FrameLease frame,
                                         std::string *error) override {
    if (error != nullptr) {
      error->clear();
    }
    attemptedBuffers.push_back(frame.pixelBuffer());
    attemptedTimes.push_back(frame.timing().presentationTime.value);
    if (held) {
      return wam::macos::FrameEnqueueResult::Backpressure;
    }
    held.emplace(std::move(frame));
    return wam::macos::FrameEnqueueResult::Accepted;
  }

  void endOfStream(std::uint64_t eosGeneration) override {
    ++endCalls;
    endGeneration = eosGeneration;
  }

  void flush(std::uint64_t nextGeneration) noexcept override {
    generation = nextGeneration;
    held.reset();
  }

  std::optional<wam::macos::FrameLease> take() {
    return std::exchange(held, std::nullopt);
  }

  std::uint64_t generation{0};
  std::uint64_t endGeneration{0};
  std::size_t endCalls{0};
  std::optional<wam::macos::FrameLease> held;
  std::vector<CVPixelBufferRef> attemptedBuffers;
  std::vector<std::int64_t> attemptedTimes;
};

void testOwnerProgressiveDeliveryRetainsBackpressureIdentity() {
  using wam::macos::FrameTiming;
  using wam::macos::VideoDecodeDrainProgress;
  using wam::macos::VideoToolboxDecoder;
  using wam::macos::VideoToolboxDecoderOptions;
  using wam::macos::VideoToolboxDecoderTestAccess;
  constexpr std::uint64_t generation = 101;

  OneSlotIdentitySink sink;
  VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 2;
  options.maxPendingPresentationFrames = 2;
  VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, sink, generation, &error),
                   error);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                       decoder, 2, &error),
                   error);

  CVPixelBufferRef first = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  CVPixelBufferRef second = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, 0, first,
                       FrameTiming{CMTimeMake(0, 1), CMTimeMake(1, 1),
                                   generation, true},
                       &error),
                   error);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, 1, second,
                       FrameTiming{CMTimeMake(1, 1), CMTimeMake(1, 1),
                                   generation, false},
                       &error),
                   error);
  CVPixelBufferRelease(first);
  CVPixelBufferRelease(second);

  WAM_CHECK(sink.attemptedBuffers.empty());
  WAM_CHECK(decoder.stats().pendingPresentationFrames == 2);
  WAM_CHECK(!decoder.stats().acceptsCompressedSample);
  WAM_CHECK(decoder.drainPresentation(generation, &error) ==
            VideoDecodeDrainProgress::Progress);
  WAM_CHECK(sink.held.has_value());
  WAM_CHECK(sink.held->timing().presentationTime.value == 0);
  WAM_CHECK(decoder.drainPresentation(generation, &error) ==
            VideoDecodeDrainProgress::Quiescing);
  WAM_CHECK(decoder.drainPresentation(generation, &error) ==
            VideoDecodeDrainProgress::Quiescing);
  WAM_CHECK(sink.attemptedBuffers.size() == 3);
  WAM_CHECK(sink.attemptedBuffers[1] == sink.attemptedBuffers[2]);
  WAM_CHECK(sink.attemptedTimes[1] == 1);
  WAM_CHECK(sink.attemptedTimes[2] == 1);
  WAM_CHECK(decoder.stats().pendingPresentationFrames == 1);
  WAM_CHECK(decoder.stats().droppedFrames == 0);
  WAM_CHECK(decoder.stats().sinkBackpressureDrops == 0);
  WAM_CHECK(decoder.stats().sinkBackpressureRetries == 2);

  auto firstTaken = sink.take();
  WAM_CHECK(firstTaken.has_value());
  firstTaken.reset();
  WAM_CHECK(decoder.drainPresentation(generation, &error) ==
            VideoDecodeDrainProgress::Progress);
  WAM_CHECK(decoder.drainPresentation(generation, &error) ==
            VideoDecodeDrainProgress::Quiescing);
  auto secondTaken = sink.take();
  WAM_CHECK(secondTaken.has_value());
  WAM_CHECK(secondTaken->timing().presentationTime.value == 1);
  secondTaken.reset();

  WAM_CHECK(decoder.beginEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Progress);
  WAM_CHECK(decoder.drainEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Done);
  WAM_CHECK(sink.endCalls == 1);
  WAM_CHECK(sink.endGeneration == generation);
  WAM_CHECK(decoder.drainEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Done);
  WAM_CHECK(sink.endCalls == 1);
  decoder.close();
}

void testOwnerProgressiveCallbacksStraddleEndOfStream() {
  using wam::macos::FrameTiming;
  using wam::macos::VideoDecodeDrainProgress;
  using wam::macos::VideoToolboxDecoder;
  using wam::macos::VideoToolboxDecoderOptions;
  using wam::macos::VideoToolboxDecoderTestAccess;
  constexpr std::uint64_t generation = 104;
  OneSlotIdentitySink sink;
  VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 2;
  options.maxPendingPresentationFrames = 2;
  VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, sink, generation, &error), error);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                       decoder, 2, &error), error);

  CVPixelBufferRef first = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  CVPixelBufferRef second = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, 0, first,
                       FrameTiming{CMTimeMake(0, 1), CMTimeMake(1, 1),
                                   generation, true},
                       &error), error);
  WAM_CHECK(decoder.beginEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Quiescing);
  WAM_CHECK(decoder.drainEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Quiescing);
  WAM_CHECK(sink.attemptedBuffers.empty());

  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, 1, second,
                       FrameTiming{CMTimeMake(1, 1), CMTimeMake(1, 1),
                                   generation, false},
                       &error), error);
  CVPixelBufferRelease(first);
  CVPixelBufferRelease(second);
  WAM_CHECK(decoder.drainEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Progress);
  auto firstTaken = sink.take();
  WAM_CHECK(firstTaken.has_value());
  WAM_CHECK(firstTaken->timing().presentationTime.value == 0);
  firstTaken.reset();
  WAM_CHECK(decoder.drainEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Done);
  auto secondTaken = sink.take();
  WAM_CHECK(secondTaken.has_value());
  WAM_CHECK(secondTaken->timing().presentationTime.value == 1);
  secondTaken.reset();
  WAM_CHECK(sink.endCalls == 1);
  WAM_CHECK(decoder.stats().pendingPresentationFrames == 0);
  WAM_CHECK(decoder.stats().droppedFrames == 0);
  decoder.close();
}

void testOwnerProgressiveTailFlushInvalidatesRetainedFrame() {
  using wam::macos::FrameTiming;
  using wam::macos::VideoDecodeDrainProgress;
  using wam::macos::VideoToolboxDecoder;
  using wam::macos::VideoToolboxDecoderOptions;
  using wam::macos::VideoToolboxDecoderTestAccess;
  constexpr std::uint64_t generation = 102;
  constexpr std::uint64_t nextGeneration = 103;
  OneSlotIdentitySink sink;
  VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.maxPendingPresentationFrames = 2;
  VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, sink, generation, &error), error);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                       decoder, 1, &error), error);
  CVPixelBufferRef frame = createIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, 0, frame,
                       FrameTiming{CMTimeMake(7, 1), CMTimeMake(1, 1),
                                   generation, true},
                       &error), error);
  CVPixelBufferRelease(frame);
  WAM_CHECK(decoder.beginEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Progress);
  WAM_CHECK(decoder.stats().pendingPresentationFrames == 1);
  decoder.flush(nextGeneration);
  WAM_CHECK(decoder.stats().pendingPresentationFrames == 0);
  WAM_CHECK(decoder.drainEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::StaleGeneration);
  WAM_CHECK(sink.attemptedBuffers.empty());
  decoder.close();
}

void testOwnerProgressiveZeroFrameEndOfStream() {
  using wam::macos::VideoDecodeDrainProgress;
  using wam::macos::VideoToolboxDecoder;
  using wam::macos::VideoToolboxDecoderOptions;
  using wam::macos::VideoToolboxDecoderTestAccess;
  constexpr std::uint64_t generation = 105;
  OneSlotIdentitySink sink;
  VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.maxPendingPresentationFrames = 1;
  VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, sink, generation, &error), error);
  WAM_CHECK(decoder.beginEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Progress);
  WAM_CHECK(decoder.drainEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Done);
  WAM_CHECK(decoder.drainEndOfStream(generation, &error) ==
            VideoDecodeDrainProgress::Done);
  WAM_CHECK(sink.endCalls == 1);
  WAM_CHECK(sink.attemptedBuffers.empty());
  decoder.close();

  OneSlotIdentitySink failingSink;
  VideoToolboxDecoder failingDecoder(options);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       failingDecoder, failingSink, generation + 1, &error),
                   error);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
                       failingDecoder, 1, &error), error);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrameResult(
                       failingDecoder, 0, nullptr,
                       wam::macos::FrameTiming{CMTimeMake(0, 1),
                                               CMTimeMake(1, 1),
                                               generation + 1, true},
                       -1, 0, &error), error);
  WAM_CHECK(failingDecoder.beginEndOfStream(generation + 1, &error) ==
            VideoDecodeDrainProgress::Failed);
  WAM_CHECK(!error.empty());
  WAM_CHECK(failingSink.endCalls == 0);
  failingDecoder.close();
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
  WAM_CHECK(decoder.drainPresentation(generation, &error) ==
            wam::macos::VideoDecodeDrainProgress::Progress);
  WAM_CHECK(decoder.drainPresentation(generation, &error) ==
            wam::macos::VideoDecodeDrainProgress::Progress);
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

void testCallbackAllocationFailureFailsClosedAndRetiresInOrder() {
  using AllocationPoint =
      wam::macos::VideoToolboxDecoderTestAllocationPoint;

  auto exercise = [&](AllocationPoint point, std::uint64_t generation,
                      std::uint64_t failingSequence,
                      std::size_t expectedAfterFailure) {
    wam::macos::BoundedFrameQueue queue(2, generation);
    wam::macos::VideoToolboxDecoderOptions options;
    options.maxInFlightFrames = 2;
    options.maxPendingPresentationFrames = 2;
    wam::macos::VideoToolboxDecoder decoder(options);
    std::string error;
    WAM_CHECK_DETAIL(
        wam::macos::VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
            decoder, queue, generation, &error),
        error);
    WAM_CHECK_DETAIL(
        wam::macos::VideoToolboxDecoderTestAccess::reserveInjectedSubmissions(
            decoder, 2, &error),
        error);

    const std::array<wam::macos::FrameTiming, 2> timings{
        wam::macos::FrameTiming{CMTimeMake(0, 1), CMTimeMake(1, 1),
                                generation, true},
        wam::macos::FrameTiming{CMTimeMake(1, 1), CMTimeMake(1, 1),
                                generation, false}};
    wam::macos::VideoToolboxDecoderTestAccess::failNextCallbackAllocation(
        decoder, point);
    WAM_CHECK_DETAIL(
        wam::macos::VideoToolboxDecoderTestAccess::injectDecodedFrame(
            decoder, failingSequence, nullptr, timings[failingSequence],
            &error),
        error);
    WAM_CHECK(decoder.stats().inFlightFrames == expectedAfterFailure);

    const std::uint64_t remainingSequence = failingSequence == 0 ? 1 : 0;
    WAM_CHECK_DETAIL(
        wam::macos::VideoToolboxDecoderTestAccess::injectDecodedFrame(
            decoder, remainingSequence, nullptr,
            timings[remainingSequence], &error),
        error);

    const auto stats = decoder.stats();
    WAM_CHECK(stats.inFlightFrames == 0);
    WAM_CHECK(stats.deliveredFrames == 0);
    WAM_CHECK(stats.pendingPresentationFrames == 0);
    WAM_CHECK(!queue.tryTake().has_value());
    const auto callbackError = decoder.takeLastError();
    WAM_CHECK(callbackError.has_value());
    WAM_CHECK(callbackError->find("exhausted bounded storage") !=
              std::string::npos);
    decoder.close();
  };

  // Sequence one fails before it can enter completedDecodes. Its tombstone
  // must remain behind sequence zero rather than prematurely releasing credit.
  exercise(AllocationPoint::CompletedDecode, 43, 1, 2);
  // Sequence zero reaches the presentation insertion before allocation fails;
  // its one credit retires exactly once, and the later callback closes the gap.
  exercise(AllocationPoint::PendingPresentation, 44, 0, 1);
}

void testCoreFoundationAllocationFailuresFailClosed() {
  using AllocationPoint =
      wam::macos::VideoToolboxDecoderTestCFAllocationPoint;
  using TestAccess = wam::macos::VideoToolboxDecoderTestAccess;

  constexpr std::array<AllocationPoint, 3> formatAllocationPoints{
      AllocationPoint::CodecAtomData,
      AllocationPoint::CodecAtomsDictionary,
      AllocationPoint::FormatExtensionsDictionary};
  for (const AllocationPoint point : formatAllocationPoints) {
    TestAccess::failNextCFAllocation(point);
    CMVideoFormatDescriptionRef format = nullptr;
    std::string error;
    WAM_CHECK(!TestAccess::copyFormatDescription(
        fixtureFreeStreamConfiguration(451), &format, &error));
    WAM_CHECK(format == nullptr);
    WAM_CHECK(!error.empty());

    // Every injected fault is one-shot. The same production builder must be
    // usable immediately afterward and must not retain a partial CF object.
    WAM_CHECK_DETAIL(TestAccess::copyFormatDescription(
                         fixtureFreeStreamConfiguration(452), &format, &error),
                     error);
    WAM_CHECK(format != nullptr);
    CFRelease(format);
  }

  constexpr std::array<AllocationPoint, 4> sessionAllocationPoints{
      AllocationPoint::DecoderSpecificationDictionary,
      AllocationPoint::IOSurfacePropertiesDictionary,
      AllocationPoint::ImageAttributesDictionary,
      AllocationPoint::PixelFormatNumber};
  std::uint64_t generation = 453;
  for (const AllocationPoint point : sessionAllocationPoints) {
    wam::macos::BoundedFrameQueue queue(1, generation);
    wam::macos::VideoToolboxDecoder decoder;
    TestAccess::failNextCFAllocation(point);
    std::string error;
    WAM_CHECK(!decoder.configure(fixtureFreeStreamConfiguration(generation),
                                 queue, &error));
    WAM_CHECK(!decoder.stats().configured);
    WAM_CHECK(error.find("allocate") != std::string::npos);
    decoder.close();
    ++generation;
  }
}

void testDecodedDimensionMismatchFailsBeforeSurfaceAdmission() {
  using wam::macos::FrameTiming;
  using wam::macos::NativeSurfaceBudget;
  using wam::macos::VideoDecodeSubmitResult;
  using wam::macos::VideoToolboxDecoderTestAccess;

  constexpr std::uint64_t generation = 461;
  wam::macos::BoundedFrameQueue queue(1, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.maxPendingPresentationFrames = 1;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, queue, generation, &error),
                   error);

  const auto budgetBefore = NativeSurfaceBudget::stats();
  std::uint64_t sequence = 0;
  const FrameTiming timing{CMTimeMake(0, 1), CMTimeMake(1, 30), generation,
                           true};
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
                       decoder, timing, &sequence, &error) ==
                       VideoDecodeSubmitResult::Accepted,
                   error);
  CVPixelBufferRef malformedDimensions = nullptr;
  const CVReturn createStatus = CVPixelBufferCreate(
      kCFAllocatorDefault, 128, 64, kCVPixelFormatType_32BGRA, nullptr,
      &malformedDimensions);
  WAM_CHECK(createStatus == kCVReturnSuccess);
  WAM_CHECK(malformedDimensions != nullptr);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, sequence, malformedDimensions, timing, &error),
                   error);
  CVPixelBufferRelease(malformedDimensions);

  const auto rejected = decoder.stats();
  WAM_CHECK(rejected.inFlightFrames == 0);
  WAM_CHECK(rejected.deliveredFrames == 0);
  WAM_CHECK(rejected.droppedFrames == 1);
  WAM_CHECK(rejected.pendingPresentationFrames == 0);
  WAM_CHECK(rejected.actualOutputPixelFormat == 0);
  WAM_CHECK(!queue.tryTake().has_value());
  const auto budgetAfter = NativeSurfaceBudget::stats();
  WAM_CHECK(budgetAfter.currentSurfaces == budgetBefore.currentSurfaces);
  WAM_CHECK(budgetAfter.currentBytes == budgetBefore.currentBytes);
  const auto callbackError = decoder.takeLastError();
  WAM_CHECK(callbackError.has_value());
  WAM_CHECK(callbackError->find("dimensions") != std::string::npos);
  decoder.close();
}

void testDecodedSdrColorAttachmentMatrix() {
  using TestAccess = wam::macos::VideoToolboxDecoderTestAccess;

  CVPixelBufferRef pixelBuffer = nullptr;
  WAM_CHECK(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32,
                                kCVPixelFormatType_32BGRA, nullptr,
                                &pixelBuffer) == kCVReturnSuccess);
  WAM_CHECK(pixelBuffer != nullptr);
  std::string error;
  const auto validates = [&](bool expected) {
    const bool result =
        TestAccess::validateDecodedColorAttachments(pixelBuffer, &error);
    WAM_CHECK(result == expected);
    WAM_CHECK(expected ? error.empty() : !error.empty());
  };
  const auto resetAttachments = [&] {
    CVBufferRemoveAllAttachments(pixelBuffer);
    error.clear();
  };

  validates(true);
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_709_2,
                        kCVAttachmentMode_ShouldNotPropagate);
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_ITU_R_709_2,
                        kCVAttachmentMode_ShouldNotPropagate);
  validates(true);

  resetAttachments();
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                        kCFBooleanTrue,
                        kCVAttachmentMode_ShouldNotPropagate);
  validates(false);
  resetAttachments();
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_2020,
                        kCVAttachmentMode_ShouldNotPropagate);
  validates(false);
  resetAttachments();
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                        kCFBooleanTrue,
                        kCVAttachmentMode_ShouldNotPropagate);
  validates(false);
  resetAttachments();
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                        kCVAttachmentMode_ShouldNotPropagate);
  validates(false);

  const std::uint8_t metadataByte = 1;
  CFDataRef metadata = CFDataCreate(kCFAllocatorDefault, &metadataByte, 1);
  WAM_CHECK(metadata != nullptr);
  const std::int32_t metadataInteger = 1;
  CFNumberRef number = CFNumberCreate(
      kCFAllocatorDefault, kCFNumberSInt32Type, &metadataInteger);
  WAM_CHECK(number != nullptr);
  CFDictionaryRef dictionary = CFDictionaryCreate(
      kCFAllocatorDefault, nullptr, nullptr, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  WAM_CHECK(dictionary != nullptr);
  const auto rejectsPresence = [&](CFStringRef key, CFTypeRef value) {
    resetAttachments();
    CVBufferSetAttachment(pixelBuffer, key, value,
                          kCVAttachmentMode_ShouldNotPropagate);
    validates(false);
  };
  rejectsPresence(kCVImageBufferGammaLevelKey, number);
  rejectsPresence(kCVImageBufferICCProfileKey, metadata);
  rejectsPresence(kCVImageBufferMasteringDisplayColorVolumeKey, metadata);
  rejectsPresence(kCVImageBufferContentLightLevelInfoKey, metadata);
  rejectsPresence(
      kCMFormatDescriptionExtension_AlternativeTransferCharacteristics,
      kCVImageBufferTransferFunction_ITU_R_2100_HLG);
#if defined(__MAC_12_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_12_0
  if (@available(macOS 12.0, *)) {
    rejectsPresence(kCVImageBufferAmbientViewingEnvironmentKey, metadata);
  }
#endif
#if defined(__MAC_14_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_0
  if (@available(macOS 14.0, *)) {
    rejectsPresence(kCMFormatDescriptionExtension_ContentColorVolume,
                    metadata);
  }
#endif
#if defined(__MAC_14_2) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_14_2
  if (@available(macOS 14.2, *)) {
    rejectsPresence(kCVImageBufferLogTransferFunctionKey, CFSTR("test.log"));
  }
#endif
#if defined(__MAC_15_0) &&                                                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_15_0
  if (@available(macOS 15.0, *)) {
    rejectsPresence(kCVImageBufferSceneIlluminationKey, number);
    rejectsPresence(kCVImageBufferPostDecodeProcessingSequenceMetadataKey,
                    dictionary);
    rejectsPresence(kCVImageBufferPostDecodeProcessingFrameMetadataKey,
                    dictionary);
  }
#endif
  CFRelease(dictionary);
  CFRelease(number);
  CFRelease(metadata);
  CVPixelBufferRelease(pixelBuffer);
}

void testDecodedColorCallbackRejectsHdrBeforeLease() {
  using wam::macos::FrameTiming;
  using wam::macos::NativeSurfaceBudget;
  using wam::macos::VideoDecodeDrainProgress;
  using wam::macos::VideoDecodeSubmitResult;
  using wam::macos::VideoToolboxDecoderTestAccess;

  constexpr std::uint64_t generation = 462;
  wam::macos::BoundedFrameQueue queue(1, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.maxPendingPresentationFrames = 1;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::prepareInjectedCallbacks(
                       decoder, queue, generation, &error),
                   error);
  WAM_CHECK_DETAIL(
      VideoToolboxDecoderTestAccess::setPermitSyntheticOutputSurface(
          decoder, true, &error),
      error);

  const auto createColorBuffer = [](CFStringRef transfer) {
    CVPixelBufferRef result = nullptr;
    WAM_CHECK(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32,
                                  kCVPixelFormatType_32BGRA, nullptr,
                                  &result) == kCVReturnSuccess);
    WAM_CHECK(result != nullptr);
    CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldNotPropagate);
    CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, transfer,
                          kCVAttachmentMode_ShouldNotPropagate);
    return result;
  };

  const auto budgetBefore = NativeSurfaceBudget::stats();
  std::uint64_t sequence = 0;
  const FrameTiming hdrTiming{CMTimeMake(0, 1), CMTimeMake(1, 30), generation,
                              true};
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
                       decoder, hdrTiming, &sequence, &error) ==
                       VideoDecodeSubmitResult::Accepted,
                   error);
  CVPixelBufferRef pq = createColorBuffer(
      kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, sequence, pq, hdrTiming, &error),
                   error);
  CVPixelBufferRelease(pq);
  const auto rejected = decoder.stats();
  WAM_CHECK(rejected.inFlightFrames == 0);
  WAM_CHECK(rejected.deliveredFrames == 0);
  WAM_CHECK(rejected.droppedFrames == 1);
  WAM_CHECK(rejected.pendingPresentationFrames == 0);
  WAM_CHECK(rejected.actualOutputPixelFormat == 0);
  WAM_CHECK(!queue.tryTake().has_value());
  const auto budgetAfterHdr = NativeSurfaceBudget::stats();
  WAM_CHECK(budgetAfterHdr.currentSurfaces == budgetBefore.currentSurfaces);
  WAM_CHECK(budgetAfterHdr.currentBytes == budgetBefore.currentBytes);
  const auto callbackError = decoder.takeLastError();
  WAM_CHECK(callbackError.has_value());
  WAM_CHECK(callbackError->find("color or HDR") != std::string::npos);

  const FrameTiming sdrTiming{
      CMTimeMake(1, 30), CMTimeMake(1, 30), generation, false};
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::reserveInjectedSubmission(
                       decoder, sdrTiming, &sequence, &error) ==
                       VideoDecodeSubmitResult::Accepted,
                   error);
  CVPixelBufferRef bt709 =
      createColorBuffer(kCVImageBufferTransferFunction_ITU_R_709_2);
  WAM_CHECK_DETAIL(VideoToolboxDecoderTestAccess::injectDecodedFrame(
                       decoder, sequence, bt709, sdrTiming, &error),
                   error);
  CVPixelBufferRelease(bt709);
  WAM_CHECK(decoder.stats().pendingPresentationFrames == 1);
  WAM_CHECK(decoder.drainPresentation(generation, &error) ==
            VideoDecodeDrainProgress::Progress);
  WAM_CHECK(queue.tryTake().has_value());
  WAM_CHECK(decoder.stats().deliveredFrames == 1);
  WAM_CHECK(!decoder.takeLastError().has_value());
  const auto budgetAfterSdr = NativeSurfaceBudget::stats();
  WAM_CHECK(budgetAfterSdr.currentSurfaces == budgetBefore.currentSurfaces);
  WAM_CHECK(budgetAfterSdr.currentBytes == budgetBefore.currentBytes);
  decoder.close();
}

void testConfigurationByteBound(const DemuxedVideo &video) {
  constexpr std::uint64_t generation = 5;
  constexpr std::size_t oversizedConfigurationBytes =
      wam::macos::native_video_limits::
          kMaximumVideoCodecConfigurationBytes +
      1ULL;
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
    while (true) {
      const auto submitted = decoder.submit(
          packetView(video.packets[index], firstGeneration), &error);
      if (submitted == wam::macos::VideoDecodeSubmitResult::Accepted) {
        break;
      }
      WAM_CHECK_DETAIL(
          submitted == wam::macos::VideoDecodeSubmitResult::Backpressure,
          error);
      (void)decoder.drainPresentation(firstGeneration, &error);
      if (auto frame = queue.tryTake()) {
      }
    }
  }
  WAM_CHECK(decoder.beginEndOfStream(firstGeneration, &error) !=
            wam::macos::VideoDecodeDrainProgress::Failed);
  while (decoder.drainEndOfStream(firstGeneration, &error) !=
         wam::macos::VideoDecodeDrainProgress::Done) {
    (void)queue.tryTake();
  }
  WAM_CHECK(decoder.stats().sinkBackpressureDrops == 0);
  WAM_CHECK(decoder.stats().droppedFrames == 0);
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
  // a deterministic safety assertion without allocating 8 MiB of resident RAM.
  constexpr std::size_t oversizedPacketBytes =
      wam::macos::native_video_limits::
          kMaximumCompressedVideoAccessUnitBytes +
      1ULL;
  void *oversizedBytes = mmap(nullptr, oversizedPacketBytes, PROT_NONE,
                              MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(oversizedBytes != MAP_FAILED);
  auto oversizedPacket = packetView(video.packets[keyIndex], generation);
  oversizedPacket.bytes = std::span<const std::byte>(
      static_cast<const std::byte *>(oversizedBytes), oversizedPacketBytes);
  WAM_CHECK(decoder.submit(oversizedPacket, &error) ==
            wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error.find("8 MiB") != std::string::npos);
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

void testDirectCMSampleBufferSubmission(
    const char *path, const DemuxedVideo &video, std::size_t keyIndex,
    bool requireHardware) {
  constexpr std::uint64_t generation = 51;
  ScopedCMSampleBuffer sample =
      copyFirstCompressedKeySample(path, video.codec);
  WAM_CHECK(sample);
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample.get());
  WAM_CHECK(block != nullptr);
  const std::size_t sampleBytes = CMBlockBufferGetDataLength(block);
  WAM_CHECK(sampleBytes != 0);

  wam::macos::BoundedFrameQueue queue(4, generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  wam::macos::VideoToolboxDecoder decoder(options);
  std::string error;
  WAM_CHECK_DETAIL(
      decoder.configure(streamConfiguration(video, generation, requireHardware),
                        queue, &error),
      error);

  // The direct path must inspect only CoreMedia metadata before enforcing the
  // AU cap. A PROT_NONE block proves cap+1 rejection does not dereference,
  // flatten, or copy the media-controlled payload.
  constexpr std::size_t oversizedDirectBytes =
      wam::macos::native_video_limits::
          kMaximumCompressedVideoAccessUnitBytes +
      1ULL;
  void *inaccessibleDirectBytes =
      mmap(nullptr, oversizedDirectBytes, PROT_NONE,
           MAP_PRIVATE | MAP_ANON, -1, 0);
  WAM_CHECK(inaccessibleDirectBytes != MAP_FAILED);
  {
    ScopedCMSampleBuffer oversizedDirect = makeGuardedCompressedSample(
        inaccessibleDirectBytes, oversizedDirectBytes,
        CMSampleBufferGetFormatDescription(sample.get()));
    WAM_CHECK(decoder.submitCMSampleBuffer(oversizedDirect.get(), generation,
                                           &error) ==
              wam::macos::VideoDecodeSubmitResult::Rejected);
    WAM_CHECK(error.find("8 MiB") != std::string::npos);
    const auto oversizedStats = decoder.stats();
    WAM_CHECK(oversizedStats.submittedFrames == 0);
    WAM_CHECK(oversizedStats.directSampleBufferSubmissions == 0);
    WAM_CHECK(oversizedStats.directSampleBufferBytes == 0);
    WAM_CHECK(oversizedStats.copiedSpanSubmissions == 0);
    WAM_CHECK(oversizedStats.copiedSpanBytes == 0);
  }
  WAM_CHECK(munmap(inaccessibleDirectBytes, oversizedDirectBytes) == 0);

  // Generation rejection is metadata-only and cannot consume or retain this
  // caller-owned sample.
  WAM_CHECK(decoder.submitCMSampleBuffer(sample.get(), generation + 1,
                                         &error) ==
            wam::macos::VideoDecodeSubmitResult::Rejected);
  WAM_CHECK(error.find("stale generation") != std::string::npos);
  WAM_CHECK(decoder.stats().directSampleBufferSubmissions == 0);

  // A saturated decoder must return typed backpressure without accepting the
  // sample or accounting any copied/direct bytes. The same retained sample is
  // then safe to retry after capacity is released.
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::occupyInFlightCapacity(
          decoder, &error),
      error);
  WAM_CHECK(decoder.submitCMSampleBuffer(sample.get(), generation, &error) ==
            wam::macos::VideoDecodeSubmitResult::Backpressure);
  WAM_CHECK(error.empty());
  auto stats = decoder.stats();
  WAM_CHECK(stats.directSampleBufferSubmissions == 0);
  WAM_CHECK(stats.directSampleBufferBytes == 0);
  WAM_CHECK(stats.copiedSpanSubmissions == 0);
  WAM_CHECK(stats.copiedSpanBytes == 0);
  WAM_CHECK_DETAIL(
      wam::macos::VideoToolboxDecoderTestAccess::releaseInFlightCapacity(
          decoder, &error),
      error);

  WAM_CHECK_DETAIL(
      decoder.submitCMSampleBuffer(sample.get(), generation, &error) ==
          wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  stats = decoder.stats();
  WAM_CHECK(stats.submittedFrames == 1);
  WAM_CHECK(stats.directSampleBufferSubmissions == 1);
  WAM_CHECK(stats.directSampleBufferBytes == sampleBytes);
  WAM_CHECK(stats.copiedSpanSubmissions == 0);
  WAM_CHECK(stats.copiedSpanBytes == 0);
  // VideoToolbox must own everything it needs after Accepted. Match the
  // AVAssetReader worker contract by releasing the caller's +1 immediately,
  // before asynchronous completion or end-of-stream draining.
  sample.reset();
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(generation), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  WAM_CHECK(queue.tryTake().has_value());

  // The generic backend contract remains available and truthfully accounts
  // its one required payload copy after a generation-changing flush.
  constexpr std::uint64_t copiedGeneration = generation + 1;
  decoder.flush(copiedGeneration);
  WAM_CHECK_DETAIL(
      decoder.submit(packetView(video.packets[keyIndex], copiedGeneration),
                     &error) ==
          wam::macos::VideoDecodeSubmitResult::Accepted,
      error);
  WAM_CHECK_DETAIL(decoder.submit(endOfStream(copiedGeneration), &error) ==
                       wam::macos::VideoDecodeSubmitResult::Accepted,
                   error);
  stats = decoder.stats();
  WAM_CHECK(stats.directSampleBufferSubmissions == 1);
  WAM_CHECK(stats.directSampleBufferBytes == sampleBytes);
  WAM_CHECK(stats.copiedSpanSubmissions == 1);
  WAM_CHECK(stats.copiedSpanBytes == video.packets[keyIndex].bytes.size());
  WAM_CHECK(queue.tryTake().has_value());
  decoder.close();
}

class GatedSink final : public wam::macos::DecodedFrameSink {
public:
  explicit GatedSink(std::uint64_t generation) : queue_(4, generation) {}

  wam::macos::FrameEnqueueResult enqueue(wam::macos::FrameLease frame,
                                         std::string *error) override {
    return queue_.enqueue(std::move(frame), error);
  }

  void endOfStream(std::uint64_t generation) override {
    queue_.endOfStream(generation);
  }

  void flush(std::uint64_t nextGeneration) noexcept override {
    queue_.flush(nextGeneration);
  }

  std::optional<wam::macos::FrameLease> tryTake() { return queue_.tryTake(); }

private:
  wam::macos::BoundedFrameQueue queue_;
};

class CallbackSchedulingProbe final {
public:
  explicit CallbackSchedulingProbe(std::atomic<bool> &submissionActive)
      : submissionActive_(submissionActive) {}

  [[nodiscard]] wam::macos::VideoToolboxDecoderProgressHandler
  handler() noexcept {
    return {&CallbackSchedulingProbe::notify, this};
  }

  bool waitForCalls(std::uint64_t minimum) {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, std::chrono::seconds(5), [&] {
      return calls_ >= minimum;
    });
  }

  [[nodiscard]] bool overlappedSubmit() const noexcept {
    return overlappedSubmit_.load(std::memory_order_acquire);
  }

private:
  static void notify(void *context) noexcept {
    auto &probe = *static_cast<CallbackSchedulingProbe *>(context);
    if (probe.submissionActive_.load(std::memory_order_acquire)) {
      probe.overlappedSubmit_.store(true, std::memory_order_release);
    }
    {
      std::lock_guard lock(probe.mutex_);
      ++probe.calls_;
    }
    probe.condition_.notify_all();
  }

  std::atomic<bool> &submissionActive_;
  std::atomic<bool> overlappedSubmit_{false};
  std::mutex mutex_;
  std::condition_variable condition_;
  std::uint64_t calls_{0};
};

void testCallbackScheduling(const DemuxedVideo &video, std::size_t keyIndex,
                            bool requireHardware,
                            bool allowAsynchronousDecode) {
  constexpr std::uint64_t generation = 7;
  std::atomic<bool> submissionActive{false};
  CallbackSchedulingProbe callbackProbe(submissionActive);
  GatedSink sink(generation);
  wam::macos::VideoToolboxDecoderOptions options;
  options.maxInFlightFrames = 1;
  options.enableAsynchronousDecompression = allowAsynchronousDecode;
  options.progressHandler = callbackProbe.handler();
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
      if (decoder.drainPresentation(generation, &results.error) !=
          wam::macos::VideoDecodeDrainProgress::Progress) {
        if (results.error.empty()) {
          results.error = "first decoded frame was not presentable";
        }
        return;
      }
      results.second =
          trackedSubmit(packetView(video.packets[deliveryIndex], generation));
    }
  });

  const bool callbackArrived = callbackProbe.waitForCalls(1);
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
        callbackProbe.overlappedSubmit(),
        "synchronous VideoToolbox mode returned before its output callback");
  }
  WAM_CHECK(!decoder.takeLastError().has_value());

  std::string error;
  wam::macos::VideoDecodeSubmitResult eosResult =
      wam::macos::VideoDecodeSubmitResult::Backpressure;
  const auto eosDeadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (eosResult == wam::macos::VideoDecodeSubmitResult::Backpressure &&
         std::chrono::steady_clock::now() < eosDeadline) {
    eosResult = decoder.submit(endOfStream(generation), &error);
    if (eosResult == wam::macos::VideoDecodeSubmitResult::Backpressure) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  WAM_CHECK_DETAIL(
      eosResult == wam::macos::VideoDecodeSubmitResult::Accepted, error);
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
  constexpr std::uint64_t generation = 30;
  wam::macos::BoundedFrameQueue queue(2, generation);
  wam::macos::VideoToolboxDecoder decoder({2});
  auto configuration = fixtureFreeStreamConfiguration(generation);
  configuration.preferHardwareDecode = true;
  configuration.requireHardwareDecode = requireHardware;
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
  testSharedLimitBoundaries();
  testPersistentFrameRefConSlotLifecycle();
  testPersistentCallbackTailBlocksClose();
  testCoreFoundationAllocationFailuresFailClosed();
  testDecodedDimensionMismatchFailsBeforeSurfaceAdmission();
  testDecodedSdrColorAttachmentMatrix();
  testDecodedColorCallbackRejectsHdrBeforeLease();
  if (argc == 2 && std::string_view(argv[1]) == "--progress-wake-only") {
    testEventDrivenDecoderProgressWake();
    testExactDecoderRetirement();
    std::cout << "VideoToolbox event-driven progress wakes passed\n";
    return EXIT_SUCCESS;
  }
  if (argc == 2 && std::string_view(argv[1]) == "--limits-only") {
    testFixtureFreeProductionLimitAdmission();
    std::cout << "VideoToolbox shared compressed/configuration limits passed\n";
    return EXIT_SUCCESS;
  }
  if (argc == 2 &&
      std::string_view(argv[1]) == "--surface-budget-only") {
    testDecodedSurfaceBudgetTombstoneAndGenerationFlush();
    std::cout << "VideoToolbox decoded-surface budget handling passed\n";
    return EXIT_SUCCESS;
  }
  if (argc == 2 &&
      std::string_view(argv[1]) == "--progressive-drain-only") {
    testOwnerProgressiveDeliveryRetainsBackpressureIdentity();
    testOwnerProgressiveCallbacksStraddleEndOfStream();
    testOwnerProgressiveTailFlushInvalidatesRetainedFrame();
    testOwnerProgressiveZeroFrameEndOfStream();
    std::cout << "VideoToolbox owner-progressive delivery passed\n";
    return EXIT_SUCCESS;
  }
  const TestInputs inputs = parseTestInputs(argc, argv);
  DemuxedVideo video =
      readCompressedVideo(inputs.h264Path, kCMVideoCodecType_H264, 3, 4);
  const std::size_t keyIndex = firstKeyFrame(video);
  WAM_CHECK(keyIndex < video.packets.size());
  DemuxedVideo main10Video;
  std::size_t main10KeyIndex = 0;
  const bool hasMain10Fixture = inputs.main10Path != nullptr;
  if (hasMain10Fixture) {
    main10Video =
        readCompressedVideo(inputs.main10Path, kCMVideoCodecType_HEVC, 1, 2);
    main10KeyIndex = firstKeyFrame(main10Video);
    WAM_CHECK(main10KeyIndex < main10Video.packets.size());
  }

  if (inputs.requireHardware) {
    WAM_CHECK_DETAIL(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
                     "this runner reports no hardware H.264 decoder");
    WAM_CHECK_DETAIL(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                     "this runner reports no hardware HEVC decoder");
  }
  if (inputs.callbackAllocationOnly) {
    testCallbackAllocationFailureFailsClosedAndRetiresInOrder();
    std::cout << "VideoToolbox callback allocation-failure handling passed\n";
    return EXIT_SUCCESS;
  }
  if (inputs.directSampleOnly) {
    testDirectCMSampleBufferSubmission(inputs.h264Path, video, keyIndex,
                                       inputs.requireHardware);
    std::cout << "VideoToolbox direct CMSampleBuffer submission passed\n";
    return EXIT_SUCCESS;
  }
  CGLInteropContext cglContext;
  std::cout << "Decoded-frame CGL import context: OpenGL 3.2 core, "
            << (cglContext.accelerated() ? "accelerated" : "non-accelerated")
            << ", "
            << (cglContext.usedCoreProfileFallback()
                    ? "available-core fallback"
                    : "accelerated preference")
            << '\n';
  testForcedCGLCoreProfileFallback();
  testFiniteAdmissionNeverEnablesTemporalProcessing();
  testDecodedSurfaceBudgetTombstoneAndGenerationFlush();
  testOwnerProgressiveDeliveryRetainsBackpressureIdentity();
  testOwnerProgressiveCallbacksStraddleEndOfStream();
  testOwnerProgressiveTailFlushInvalidatesRetainedFrame();
  testOwnerProgressiveZeroFrameEndOfStream();
  testConfigurationByteBound(video);
  testCodecParserAndDeclaredReorderBound(video);
  testAdmissionBeforeCopy(video, keyIndex, inputs.requireHardware);
  testDirectCMSampleBufferSubmission(inputs.h264Path, video, keyIndex,
                                     inputs.requireHardware);
  testDefaultBoundMakesProgressBeforeEndOfStream(video, keyIndex,
                                                 inputs.requireHardware);
  testCallbackScheduling(video, keyIndex, inputs.requireHardware, true);
  testCallbackScheduling(video, keyIndex, inputs.requireHardware, false);
  testLifecycleAndGeneration(video, keyIndex, inputs.requireHardware);
  testInjectedCallbackOrderUsesDecodeSequence(video, inputs.requireHardware);
  testInjectedCompletionGapPreservesAdmissionAndMakesProgress(
      video, keyIndex, inputs.requireHardware);
  testCallbackAllocationFailureFailsClosedAndRetiresInOrder();
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
