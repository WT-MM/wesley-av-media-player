#include "platform/macos/avfoundation_media_source.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace wam::macos::avfoundation_media_source_testing {
media::MediaVideoSampleFormat parseHevcSampleFormatForTesting(
    std::span<const std::byte> configuration) noexcept;
bool exactIdentityVideoTransformForTesting(
    CGAffineTransform transform) noexcept;
bool selectedFormatsRebindBeforeReaderForTesting(
    CMVideoFormatDescriptionRef videoFormat, std::size_t videoFormatCount,
    CGAffineTransform videoTransform,
    CMAudioFormatDescriptionRef audioFormat, std::size_t audioFormatCount,
    const media::MediaSourceDescriptor& descriptor,
    const media::MediaSourceLimits& limits,
    std::size_t* readerCreationAttempts, std::string* error) noexcept;
}

namespace {

using namespace wam::macos;
using namespace wam::media;

int failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

class OwnedFormat final {
 public:
  explicit OwnedFormat(CMFormatDescriptionRef value = nullptr) noexcept
      : value_(value) {}
  OwnedFormat(const OwnedFormat&) = delete;
  OwnedFormat& operator=(const OwnedFormat&) = delete;
  OwnedFormat(OwnedFormat&& other) noexcept
      : value_(std::exchange(other.value_, nullptr)) {}
  ~OwnedFormat() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }
  [[nodiscard]] CMFormatDescriptionRef get() const noexcept { return value_; }

 private:
  CMFormatDescriptionRef value_{nullptr};
};

class OwnedSample final {
 public:
  explicit OwnedSample(CMSampleBufferRef value = nullptr) noexcept
      : value_(value) {}
  OwnedSample(const OwnedSample&) = delete;
  OwnedSample& operator=(const OwnedSample&) = delete;
  OwnedSample(OwnedSample&& other) noexcept
      : value_(std::exchange(other.value_, nullptr)) {}
  ~OwnedSample() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }
  [[nodiscard]] CMSampleBufferRef get() const noexcept { return value_; }

 private:
  CMSampleBufferRef value_{nullptr};
};

constexpr std::array<std::uint8_t, 22> kFixtureFreeAvcC{
    0x01, 0x42, 0x00, 0x1e, 0xff, 0xe1, 0x00, 0x08, 0x67, 0x42, 0x00,
    0x1e, 0x80, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x68, 0x00, 0x00};

// Complete VPS/SPS/PPS records produced by x265 for a 16x16 progressive
// hvc1 stream. The encoder SEI array is intentionally omitted; the remaining
// three complete arrays are sufficient for CoreMedia to reconstruct and
// validate a decoder-ready HEVC format description without a media fixture.
constexpr std::array<std::uint8_t, 108> kFixtureFreeMainHvcC{
    0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x1e, 0xf0, 0x00, 0xfc, 0xfd, 0xf8, 0xf8, 0x00, 0x00, 0x0f, 0x03, 0xa0,
    0x00, 0x01, 0x00, 0x18, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
    0x1e, 0x95, 0x94, 0x09, 0xa1, 0x00, 0x01, 0x00, 0x28, 0x42, 0x01, 0x01,
    0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00,
    0x03, 0x00, 0x1e, 0xa0, 0x88, 0x45, 0x96, 0x56, 0x55, 0xbc, 0x2f, 0x01,
    0x68, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08,
    0x40, 0xa2, 0x00, 0x01, 0x00, 0x06, 0x44, 0x01, 0xc0, 0x73, 0xc0, 0x89};

constexpr std::array<std::uint8_t, 108> kFixtureFreeMain10HvcC{
    0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x1e, 0xf0, 0x00, 0xfc, 0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x03, 0xa0,
    0x00, 0x01, 0x00, 0x18, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x02, 0x20,
    0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
    0x1e, 0x95, 0x94, 0x09, 0xa1, 0x00, 0x01, 0x00, 0x28, 0x42, 0x01, 0x01,
    0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00,
    0x03, 0x00, 0x1e, 0xa0, 0x88, 0x44, 0xd9, 0x65, 0x65, 0x5b, 0xc2, 0xf0,
    0x16, 0x80, 0x80, 0x00, 0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x03, 0x00,
    0x84, 0xa2, 0x00, 0x01, 0x00, 0x06, 0x44, 0x01, 0xc0, 0x73, 0xc0, 0x89};

std::vector<std::uint8_t> fixtureFreeHvcC(
    std::uint8_t depthMinusEight, bool includeVps = true,
    bool includeSps = true, bool includePps = true,
    std::optional<std::uint8_t> spsProfileIdc = std::nullopt,
    std::optional<std::uint8_t> vpsProfileIdc = std::nullopt) {
  const auto& source = depthMinusEight == 2 ? kFixtureFreeMain10HvcC
                                            : kFixtureFreeMainHvcC;
  std::vector<std::uint8_t> complete(source.begin(), source.end());
  if (vpsProfileIdc) {
    complete[34] = *vpsProfileIdc;
  }
  if (spsProfileIdc) {
    complete[60] = *spsProfileIdc;
  }
  std::vector<std::uint8_t> result(complete.begin(), complete.begin() + 23);
  result[22] = static_cast<std::uint8_t>(
      static_cast<unsigned>(includeVps) + static_cast<unsigned>(includeSps) +
      static_cast<unsigned>(includePps));
  const auto append = [&result, &complete](std::size_t first,
                                            std::size_t last) {
    result.insert(result.end(), complete.begin() + first,
                  complete.begin() + last);
  };
  if (includeVps) {
    append(23, 52);
  }
  if (includeSps) {
    append(52, 97);
  }
  if (includePps) {
    append(97, 108);
  }
  return result;
}

bool coreMediaAcceptsFixtureFreeHevcParameterSets(
    std::span<const std::uint8_t> configuration) {
  if (configuration.size() != 108) {
    return false;
  }
  const std::array<const std::uint8_t*, 3> parameterSets{
      configuration.data() + 28, configuration.data() + 57,
      configuration.data() + 102};
  constexpr std::array<std::size_t, 3> sizes{24, 40, 6};
  CMVideoFormatDescriptionRef format = nullptr;
  const OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
      kCFAllocatorDefault, parameterSets.size(), parameterSets.data(),
      sizes.data(), 4, nullptr, &format);
  if (format != nullptr) {
    CFRelease(format);
  }
  return status == noErr;
}

struct VideoFormatOptions {
  bool fractionalCrop{false};
  bool nonSquarePixels{false};
  bool pqTransfer{false};
  bool dolbyVision{false};
  bool interlaced{false};
  bool ambientViewingEnvironment{false};
  bool bt709Primaries{false};
  bool bt709Transfer{false};
  bool bt709Matrix{false};
  bool centeredTopChroma{false};
  std::optional<std::uint32_t> bitsPerComponent;
  std::span<const std::uint8_t> configuration;
};

CFNumberRef makeSInt64Number(std::int64_t value) {
  return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
}

CFArrayRef makeRationalArray(std::int64_t numerator,
                             std::int64_t denominator) {
  CFNumberRef numeratorNumber = makeSInt64Number(numerator);
  CFNumberRef denominatorNumber = makeSInt64Number(denominator);
  const void* values[]{numeratorNumber, denominatorNumber};
  CFArrayRef result = CFArrayCreate(kCFAllocatorDefault, values, 2,
                                    &kCFTypeArrayCallBacks);
  CFRelease(numeratorNumber);
  CFRelease(denominatorNumber);
  return result;
}

OwnedFormat makeVideoFormat(OSType codec = kCMVideoCodecType_H264,
                            std::int32_t width = 16,
                            std::int32_t height = 16,
                            VideoFormatOptions options = {}) {
  std::vector<std::uint8_t> defaultHevcConfiguration;
  std::span<const std::uint8_t> configuration = options.configuration;
  if (configuration.empty()) {
    if (codec == kCMVideoCodecType_H264) {
      configuration = kFixtureFreeAvcC;
    } else {
      defaultHevcConfiguration = fixtureFreeHvcC(0);
      configuration = defaultHevcConfiguration;
    }
  }
  CFDataRef atom = CFDataCreate(kCFAllocatorDefault, configuration.data(),
                                static_cast<CFIndex>(configuration.size()));
  const void* atomKey = codec == kCMVideoCodecType_H264
                            ? static_cast<const void*>(CFSTR("avcC"))
                            : static_cast<const void*>(CFSTR("hvcC"));
  const void* atomValue = atom;
  CFMutableDictionaryRef atoms = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(atoms, atomKey, atomValue);
  if (options.dolbyVision) {
    CFDictionarySetValue(atoms, CFSTR("dvcC"), atomValue);
  }
  CFMutableDictionaryRef extensions = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms, atoms);

  if (options.fractionalCrop) {
    CFMutableDictionaryRef aperture = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFArrayRef apertureWidth = makeRationalArray(31, 2);
    CFArrayRef apertureHeight = makeRationalArray(height, 1);
    CFArrayRef zero = makeRationalArray(0, 1);
    CFDictionarySetValue(
        aperture, kCMFormatDescriptionKey_CleanApertureWidthRational,
        apertureWidth);
    CFDictionarySetValue(
        aperture, kCMFormatDescriptionKey_CleanApertureHeightRational,
        apertureHeight);
    CFDictionarySetValue(
        aperture,
        kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational, zero);
    CFDictionarySetValue(
        aperture, kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational,
        zero);
    CFDictionarySetValue(extensions,
                         kCMFormatDescriptionExtension_CleanAperture,
                         aperture);
    CFRelease(apertureWidth);
    CFRelease(apertureHeight);
    CFRelease(zero);
    CFRelease(aperture);
  }
  if (options.nonSquarePixels) {
    CFMutableDictionaryRef aspect = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFNumberRef horizontal = makeSInt64Number(2);
    CFNumberRef vertical = makeSInt64Number(1);
    CFDictionarySetValue(
        aspect, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing,
        horizontal);
    CFDictionarySetValue(
        aspect, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing,
        vertical);
    CFDictionarySetValue(extensions,
                         kCMFormatDescriptionExtension_PixelAspectRatio,
                         aspect);
    CFRelease(horizontal);
    CFRelease(vertical);
    CFRelease(aspect);
  }
  if (options.pqTransfer) {
    CFDictionarySetValue(
        extensions, kCMFormatDescriptionExtension_TransferFunction,
        kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
  }
  if (options.bt709Primaries) {
    CFDictionarySetValue(
        extensions, kCMFormatDescriptionExtension_ColorPrimaries,
        kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
  }
  if (options.bt709Transfer) {
    CFDictionarySetValue(
        extensions, kCMFormatDescriptionExtension_TransferFunction,
        kCMFormatDescriptionTransferFunction_ITU_R_709_2);
  }
  if (options.bt709Matrix) {
    CFDictionarySetValue(
        extensions, kCMFormatDescriptionExtension_YCbCrMatrix,
        kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
  }
  if (options.centeredTopChroma) {
    CFDictionarySetValue(
        extensions, kCMFormatDescriptionExtension_ChromaLocationTopField,
        kCMFormatDescriptionChromaLocation_Center);
  }
  if (options.bitsPerComponent) {
    CFNumberRef componentBits =
        makeSInt64Number(static_cast<std::int64_t>(*options.bitsPerComponent));
    CFDictionarySetValue(extensions,
                         kCMFormatDescriptionExtension_BitsPerComponent,
                         componentBits);
    CFRelease(componentBits);
  }
  if (options.interlaced) {
    CFNumberRef fieldCount = makeSInt64Number(2);
    CFDictionarySetValue(extensions,
                         kCMFormatDescriptionExtension_FieldCount,
                         fieldCount);
    CFRelease(fieldCount);
  }
  if (options.ambientViewingEnvironment) {
    if (@available(macOS 12.0, *)) {
      const std::array<std::uint8_t, 8> ambientBytes{};
      CFDataRef ambient = CFDataCreate(
          kCFAllocatorDefault, ambientBytes.data(),
          static_cast<CFIndex>(ambientBytes.size()));
      CFDictionarySetValue(
          extensions,
          kCMFormatDescriptionExtension_AmbientViewingEnvironment, ambient);
      CFRelease(ambient);
    }
  }
  CMVideoFormatDescriptionRef format = nullptr;
  const OSStatus status = CMVideoFormatDescriptionCreate(
      kCFAllocatorDefault, codec, width, height, extensions, &format);
  CFRelease(extensions);
  CFRelease(atoms);
  CFRelease(atom);
  expect(status == noErr && format != nullptr,
         "synthetic video format should be created");
  return OwnedFormat(format);
}

OwnedFormat makeAudioFormat(
    std::uint32_t channels = 2,
    std::optional<AudioChannelLayoutTag> layoutTag = std::nullopt,
    std::optional<std::uint32_t> descriptionCount = std::nullopt,
    std::optional<AudioChannelBitmap> channelBitmap = std::nullopt,
    bool compactTagOnly = false,
    std::span<const std::uint8_t> suppliedCookie = {}) {
  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = 48'000.0;
  asbd.mFormatID = kAudioFormatMPEG4AAC;
  asbd.mFramesPerPacket = 1024;
  asbd.mChannelsPerFrame = channels;
  constexpr std::array<std::uint8_t, 2> defaultCookie{0x12, 0x10};
  const std::span<const std::uint8_t> cookie =
      suppliedCookie.empty() ? std::span<const std::uint8_t>(defaultCookie)
                             : suppliedCookie;

  std::vector<std::uint64_t> layoutStorage;
  std::size_t layoutSize = 0;
  AudioChannelLayout* layout = nullptr;
  if (layoutTag) {
    const std::size_t prefix =
        offsetof(AudioChannelLayout, mChannelDescriptions);
    const std::uint32_t descriptions = descriptionCount.value_or(0);
    layoutSize = descriptions == 0
                     ? (compactTagOnly ? prefix
                                       : sizeof(AudioChannelLayout))
                     : prefix + static_cast<std::size_t>(descriptions) *
                                    sizeof(AudioChannelDescription);
    const std::size_t storageBytes = std::max(layoutSize,
                                              sizeof(AudioChannelLayout));
    layoutStorage.resize(
        (storageBytes + sizeof(std::uint64_t) - 1) /
        sizeof(std::uint64_t));
    layout = ::new (layoutStorage.data()) AudioChannelLayout{};
    layout->mChannelLayoutTag = *layoutTag;
    layout->mChannelBitmap = channelBitmap.value_or(0);
    layout->mNumberChannelDescriptions = descriptions;
    for (std::uint32_t index = 0; index < descriptions; ++index) {
      layout->mChannelDescriptions[index].mChannelLabel =
          index == 0 ? kAudioChannelLabel_Left : kAudioChannelLabel_Right;
    }
  }
  CMAudioFormatDescriptionRef format = nullptr;
  const OSStatus status = CMAudioFormatDescriptionCreate(
      kCFAllocatorDefault, &asbd, layoutSize, layout, cookie.size(),
      cookie.data(), nullptr, &format);
  expect(status == noErr && format != nullptr,
         "synthetic audio format should be created");
  return OwnedFormat(format);
}

OwnedSample makeSample(CMFormatDescriptionRef format, CMTime pts, CMTime dts,
                       std::size_t byteCount, std::size_t sampleCount,
                       bool keyFrame = true,
                       CMTime duration = CMTimeMake(1, 60)) {
  expect(byteCount > 0 && sampleCount > 0 && byteCount % sampleCount == 0,
         "synthetic sample shape should be exact");
  expect(sampleCount <=
             static_cast<std::size_t>(std::numeric_limits<CMItemCount>::max()),
         "synthetic sample count should fit CoreMedia");
  CMBlockBufferRef block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, byteCount, kCFAllocatorDefault, nullptr, 0,
      byteCount, 0, &block);
  expect(status == noErr && block != nullptr,
         "synthetic block buffer should be created");
  const std::vector<std::byte> bytes(byteCount, std::byte{0x5a});
  status = CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, bytes.size());
  expect(status == noErr, "synthetic block bytes should be initialized");
  CMSampleTimingInfo timing{duration, pts, dts};
  const std::size_t perSampleBytes = byteCount / sampleCount;
  CMSampleBufferRef sample = nullptr;
  status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, format,
      static_cast<CMItemCount>(sampleCount), 1, &timing, 1,
      &perSampleBytes, &sample);
  CFRelease(block);
  expect(status == noErr && sample != nullptr,
         "synthetic sample buffer should be created");
  if (!keyFrame && sample != nullptr) {
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sample, true);
    auto dictionary = static_cast<CFMutableDictionaryRef>(
        const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_NotSync,
                         kCFBooleanTrue);
  }
  return OwnedSample(sample);
}

// A compressed-audio sample buffer carrying `sampleCount` access units whose
// timing is stated exactly as `timing` -- either one entry per access unit or
// a single entry shared by all of them, which is precisely the distinction the
// media-grid restating has to respect.
OwnedSample makeCompressedAudioSample(
    CMFormatDescriptionRef format, std::span<const CMSampleTimingInfo> timing,
    std::size_t sampleCount, std::size_t perSampleBytes) {
  expect(sampleCount > 0 && perSampleBytes > 0 &&
             (timing.size() == 1 || timing.size() == sampleCount),
         "synthetic compressed audio shape should be exact");
  const std::size_t byteCount = perSampleBytes * sampleCount;
  CMBlockBufferRef block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, byteCount, kCFAllocatorDefault, nullptr, 0,
      byteCount, 0, &block);
  expect(status == noErr && block != nullptr,
         "synthetic compressed audio block should be created");
  const std::vector<std::byte> bytes(byteCount, std::byte{0x27});
  status = CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, bytes.size());
  expect(status == noErr,
         "synthetic compressed audio bytes should be initialized");
  const std::size_t sizeEntry = perSampleBytes;
  CMSampleBufferRef sample = nullptr;
  status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, format,
      static_cast<CMItemCount>(sampleCount),
      static_cast<CMItemCount>(timing.size()), timing.data(), 1, &sizeEntry,
      &sample);
  CFRelease(block);
  expect(status == noErr && sample != nullptr,
         "synthetic compressed audio sample should be created");
  return OwnedSample(sample);
}

OwnedSample makeDiscontinuity(CMTime pts) {
  const CMSampleTimingInfo timing{kCMTimeInvalid, pts, kCMTimeInvalid};
  CMSampleBufferRef sample = nullptr;
  const OSStatus status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, nullptr, nullptr, 0, 1, &timing, 0, nullptr,
      &sample);
  expect(status == noErr && sample != nullptr &&
             CMSampleBufferIsValid(sample) &&
             CMSampleBufferDataIsReady(sample) &&
             CMSampleBufferGetNumSamples(sample) == 0 &&
             CMSampleBufferGetDataBuffer(sample) == nullptr &&
             CMSampleBufferGetFormatDescription(sample) == nullptr,
         "synthetic discontinuity marker should be valid and formatless");
  return OwnedSample(sample);
}

MediaTrackDescriptor videoTrack(MediaTime duration) {
  MediaTrackDescriptor track;
  track.id = 1;
  track.kind = MediaTrackKind::Video;
  track.codec = MediaCodec::H264;
  track.timeBase = {1, 60};
  track.duration = duration;
  track.codecConfigurationKind = MediaCodecConfigurationKind::AvcC;
  track.codecConfiguration.resize(kFixtureFreeAvcC.size());
  std::memcpy(track.codecConfiguration.data(), kFixtureFreeAvcC.data(),
              kFixtureFreeAvcC.size());
  MediaVideoFormat video;
  video.codedWidth = 16;
  video.codedHeight = 16;
  video.displayWidth = 16;
  video.displayHeight = 16;
  track.video = video;
  track.video->cleanAperture =
      MediaCleanAperture{{16, 1}, {16, 1}, {0, 1}, {0, 1}};
  track.video->sampleFormat = MediaVideoSampleFormat::Yuv420EightBit;
  return track;
}

MediaTrackDescriptor audioTrack(MediaTime duration) {
  MediaTrackDescriptor track;
  track.id = 2;
  track.kind = MediaTrackKind::Audio;
  track.codec = MediaCodec::Aac;
  track.timeBase = {1, 48'000};
  track.duration = duration;
  track.codecConfigurationKind =
      MediaCodecConfigurationKind::AudioMagicCookie;
  track.codecConfiguration = {std::byte{0x12}, std::byte{0x10}};
  track.audio =
      MediaAudioFormat{48'000.0, 2, kAudioFormatMPEG4AAC, 0, 1024};
  return track;
}

std::shared_ptr<const MediaSourceDescriptor> descriptor() {
  auto result = std::make_shared<MediaSourceDescriptor>();
  result->duration = {std::numeric_limits<std::int64_t>::max(), 1};
  result->inventory = {.video = 1, .audio = 1, .total = 2};
  result->tracks = {videoTrack(result->duration), audioTrack(result->duration)};
  result->selectedVideo = 1;
  result->selectedAudio = 2;
  return result;
}

struct StartGate {
  std::mutex mutex;
  std::condition_variable changed;
  bool entered{false};
  bool resume{false};
};

struct PullGate {
  std::mutex mutex;
  std::condition_variable changed;
  std::size_t blockOnCall{2};
  bool entered{false};
  bool resume{false};
};

struct GenerationPlan {
  MediaGeneration generation{0};
  std::shared_ptr<const MediaSourceDescriptor> sourceDescriptor;
  MediaTime actualStart{0, 1};
  std::vector<CMSampleBufferRef> video;
  std::vector<CMSampleBufferRef> audio;
  std::shared_ptr<StartGate> startGate;
  std::shared_ptr<StartGate> cancelGate;
  bool throwOnStart{false};
  // Kept behind the existing aggregate fields so older fixtures retain their
  // layout; tests that need a context assign it by name after construction.
  std::shared_ptr<const AVFoundationAssetContext> assetContext{};
  std::shared_ptr<PullGate> videoPullGate{};
  std::shared_ptr<PullGate> audioPullGate{};
  std::size_t videoFailureOnCall{0};
  std::size_t audioFailureOnCall{0};
};

class FakeGeneration final : public AVFoundationGeneration {
 public:
  explicit FakeGeneration(GenerationPlan plan) : plan_(std::move(plan)) {
    for (CMSampleBufferRef sample : plan_.video) {
      if (sample == nullptr) {
        fixtureValid_ = false;
      } else {
        CFRetain(sample);
      }
    }
    for (CMSampleBufferRef sample : plan_.audio) {
      if (sample == nullptr) {
        fixtureValid_ = false;
      } else {
        CFRetain(sample);
      }
    }
  }
  ~FakeGeneration() override {
    for (CMSampleBufferRef sample : plan_.video) {
      if (sample != nullptr) {
        CFRelease(sample);
      }
    }
    for (CMSampleBufferRef sample : plan_.audio) {
      if (sample != nullptr) {
        CFRelease(sample);
      }
    }
  }

  [[nodiscard]] MediaGeneration generation() const noexcept override {
    return plan_.generation;
  }

  [[nodiscard]] AVFoundationGenerationStart start() override {
    starts.fetch_add(1, std::memory_order_relaxed);
    if (plan_.throwOnStart) {
      throw std::runtime_error("injected start exception");
    }
    if (!fixtureValid_) {
      AVFoundationGenerationStart invalid;
      invalid.status = AVFoundationGenerationStatus::Failed;
      invalid.error = "synthetic CoreMedia fixture could not be created";
      return invalid;
    }
    if (plan_.startGate) {
      std::unique_lock lock(plan_.startGate->mutex);
      plan_.startGate->entered = true;
      plan_.startGate->changed.notify_all();
      plan_.startGate->changed.wait(lock, [this] {
        return plan_.startGate->resume ||
               cancelled_.load(std::memory_order_acquire);
      });
    }
    if (cancelled_.load(std::memory_order_acquire)) {
      AVFoundationGenerationStart cancelled;
      cancelled.status = AVFoundationGenerationStatus::Cancelled;
      return cancelled;
    }
    AVFoundationGenerationStart result;
    result.status = AVFoundationGenerationStatus::Ready;
    result.actualDecodeStart = plan_.actualStart;
    result.descriptor = plan_.sourceDescriptor;
    result.assetContext = plan_.assetContext;
    return result;
  }

  [[nodiscard]] AVFoundationCopiedSample
  copyNextVideoSample() override {
    return copy(plan_.video, videoIndex, videoCopies, plan_.videoPullGate,
                plan_.videoFailureOnCall);
  }
  [[nodiscard]] AVFoundationCopiedSample
  copyNextAudioSample() override {
    return copy(plan_.audio, audioIndex, audioCopies, plan_.audioPullGate,
                plan_.audioFailureOnCall);
  }

  void cancel() noexcept override {
    cancelled_.store(true, std::memory_order_release);
    cancels.fetch_add(1, std::memory_order_relaxed);
    if (plan_.videoPullGate) {
      std::lock_guard lock(plan_.videoPullGate->mutex);
      plan_.videoPullGate->changed.notify_all();
    }
    if (plan_.audioPullGate) {
      std::lock_guard lock(plan_.audioPullGate->mutex);
      plan_.audioPullGate->changed.notify_all();
    }
    if (plan_.startGate) {
      std::lock_guard lock(plan_.startGate->mutex);
      plan_.startGate->changed.notify_all();
    }
    if (plan_.cancelGate) {
      std::unique_lock lock(plan_.cancelGate->mutex);
      plan_.cancelGate->entered = true;
      plan_.cancelGate->changed.notify_all();
      plan_.cancelGate->changed.wait(
          lock, [this] { return plan_.cancelGate->resume; });
    }
  }

  std::atomic<int> starts{0};
  std::atomic<int> cancels{0};
  std::atomic<int> videoCopies{0};
  std::atomic<int> audioCopies{0};

 private:
  AVFoundationCopiedSample copy(const std::vector<CMSampleBufferRef>& samples,
                                std::size_t& index,
                                std::atomic<int>& copies,
                                const std::shared_ptr<PullGate>& gate,
                                std::size_t failureOnCall) {
    const std::size_t call = static_cast<std::size_t>(
        copies.fetch_add(1, std::memory_order_relaxed) + 1);
    if (gate && call == gate->blockOnCall) {
      std::unique_lock lock(gate->mutex);
      gate->entered = true;
      gate->changed.notify_all();
      gate->changed.wait(lock, [this, &gate] {
        return gate->resume || cancelled_.load(std::memory_order_acquire);
      });
    }
    if (cancelled_.load(std::memory_order_acquire)) {
      return {nullptr, AVFoundationSampleReadStatus::Cancelled, {}};
    }
    if (failureOnCall != 0 && call == failureOnCall) {
      return {nullptr, AVFoundationSampleReadStatus::Failed,
              "injected replacement pull failure"};
    }
    if (index == samples.size()) {
      return {nullptr, AVFoundationSampleReadStatus::EndOfStream, {}};
    }
    CMSampleBufferRef sample = samples[index++];
    if (sample == nullptr) {
      return {nullptr, AVFoundationSampleReadStatus::Failed,
              "synthetic CoreMedia fixture is null"};
    }
    CFRetain(sample);
    return {sample, AVFoundationSampleReadStatus::Sample, {}};
  }

  GenerationPlan plan_;
  bool fixtureValid_{true};
  std::atomic<bool> cancelled_{false};
  std::size_t videoIndex{0};
  std::size_t audioIndex{0};
};

class FakeBackend final : public AVFoundationBackend {
 public:
  [[nodiscard]] std::shared_ptr<AVFoundationGeneration> makeGeneration(
      AVFoundationGenerationRequest request) override {
    makes.fetch_add(1, std::memory_order_relaxed);
    (request.assetContext == nullptr ? coldContextRequests
                                     : reusedContextRequests)
        .fetch_add(1, std::memory_order_relaxed);
    requests.push_back(request);
    expect(!plans.empty(), "fake backend should have a generation plan");
    GenerationPlan plan = std::move(plans.front());
    plans.pop_front();
    expect(plan.generation == request.generation,
           "fake generation should exact-match request generation");
    if (plan.assetContext == nullptr) {
      if (request.assetContext != nullptr) {
        plan.assetContext = request.assetContext;
        plan.sourceDescriptor = request.assetContext->descriptor();
      } else {
        plan.assetContext = makeAVFoundationAssetContextForTesting(
            request.path, request.options, plan.sourceDescriptor);
      }
    }
    auto generation = std::make_shared<FakeGeneration>(std::move(plan));
    made.push_back(generation);
    return generation;
  }

  std::deque<GenerationPlan> plans;
  std::vector<std::shared_ptr<FakeGeneration>> made;
  std::vector<AVFoundationGenerationRequest> requests;
  std::atomic<int> makes{0};
  std::atomic<int> coldContextRequests{0};
  std::atomic<int> reusedContextRequests{0};
};

MediaSourceOpenOptions options() {
  MediaSourceOpenOptions result;
  result.selection.requireVideo = true;
  result.selection.requireAudio = true;
  return result;
}

struct AccurateHeadObservation {
  MediaSourceOpenStatus status{MediaSourceOpenStatus::Failed};
  std::optional<bool> videoDecodeOnly;
  std::string error;
};

AccurateHeadObservation observeAccurateVideoHead(CMTime pts, CMTime duration,
                                                 MediaTime target,
                                                 MediaSeekMode mode =
                                                     MediaSeekMode::Accurate) {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video = makeSample(videoFormat.get(), pts, kCMTimeInvalid, 16, 1,
                          true, duration);
  auto audio = makeSample(audioFormat.get(),
                          CMTimeMake(target.value, target.timescale),
                          kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(
      GenerationPlan{1, descriptor(), {0, 1}, {video.get()}, {audio.get()},
                     nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  MediaSourceOpenOptions positioned = options();
  positioned.initialPosition =
      MediaSourceInitialPosition{target, mode};
  expect(source.armOperation(1),
         "accurate video interval observation should arm");
  MediaSourceOpenOutcome opened =
      source.openLocalFile("interval.mov", positioned, 1);
  AccurateHeadObservation result{opened.status, std::nullopt,
                                 std::move(opened.error)};
  if (opened.status != MediaSourceOpenStatus::Ready) {
    return result;
  }
  MediaSourceReadResult read = source.readNext(1);
  if (std::holds_alternative<MediaSample>(read) &&
      std::get<MediaSample>(read).track == 1) {
    result.videoDecodeOnly = std::get<MediaSample>(read).decodeOnly;
  }
  return result;
}

void testAccurateVideoUsesWholeExactInterval() {
  const AccurateHeadObservation targetAtStart = observeAccurateVideoHead(
      CMTimeMake(5, 1), CMTimeMake(1, 1), {5, 1});
  expect(targetAtStart.status == MediaSourceOpenStatus::Ready &&
             targetAtStart.videoDecodeOnly == false,
         "a frame beginning exactly at the target remains presentable");

  const AccurateHeadObservation targetAtEnd = observeAccurateVideoHead(
      CMTimeMake(4, 1), CMTimeMake(1, 1), {5, 1});
  expect(targetAtEnd.status == MediaSourceOpenStatus::Ready &&
             targetAtEnd.videoDecodeOnly == true,
         "a frame ending exactly at the target is wholly preroll");

  const AccurateHeadObservation targetInside = observeAccurateVideoHead(
      CMTimeMake(4, 1), CMTimeMake(2, 1), {5, 1});
  expect(targetInside.status == MediaSourceOpenStatus::Ready &&
             targetInside.videoDecodeOnly == false,
         "a frame covering the target remains presentable");

  const AccurateHeadObservation mixedEnd = observeAccurateVideoHead(
      CMTimeMake(1, 3), CMTimeMake(1, 6), {1, 2});
  expect(mixedEnd.status == MediaSourceOpenStatus::Ready &&
             mixedEnd.videoDecodeOnly == true,
         "mixed-timescale interval end is classified exactly");

  const AccurateHeadObservation mixedInside = observeAccurateVideoHead(
      CMTimeMake(1, 3), CMTimeMake(1, 3), {1, 2});
  expect(mixedInside.status == MediaSourceOpenStatus::Ready &&
             mixedInside.videoDecodeOnly == false,
         "mixed-timescale covering interval remains presentable");

  constexpr std::int64_t beyondDouble = 9'007'199'254'740'993LL;
  const AccurateHeadObservation largeInside = observeAccurateVideoHead(
      CMTimeMake(beyondDouble, 1), CMTimeMake(2, 3),
      {beyondDouble * 3 + 1, 3});
  expect(largeInside.status == MediaSourceOpenStatus::Ready &&
             largeInside.videoDecodeOnly == false,
         "adjacent ticks above 2^53 are not rounded out of the interval");

  const AccurateHeadObservation largeEnd = observeAccurateVideoHead(
      CMTimeMake(beyondDouble, 1), CMTimeMake(1, 3),
      {beyondDouble * 3 + 1, 3});
  expect(largeEnd.status == MediaSourceOpenStatus::Ready &&
             largeEnd.videoDecodeOnly == true,
         "an exact interval end above 2^53 remains wholly preroll");

  const AccurateHeadObservation negativeInside = observeAccurateVideoHead(
      CMTimeMake(-1, 2), CMTimeMake(1, 1), {0, 1});
  expect(negativeInside.status == MediaSourceOpenStatus::Unsupported &&
             !negativeInside.videoDecodeOnly,
         "negative edit-list preroll fails closed before source Ready");

  const AccurateHeadObservation negativeEnd = observeAccurateVideoHead(
      CMTimeMake(-1, 2), CMTimeMake(1, 2), {0, 1});
  expect(negativeEnd.status == MediaSourceOpenStatus::Unsupported &&
             !negativeEnd.videoDecodeOnly,
         "negative preroll ending at zero remains a compatibility fallback");

  const AccurateHeadObservation keyFrameMode = observeAccurateVideoHead(
      CMTimeMake(4, 1), CMTimeMake(1, 60), {5, 1},
      MediaSeekMode::KeyFrame);
  expect(keyFrameMode.status == MediaSourceOpenStatus::Ready &&
             keyFrameMode.videoDecodeOnly == false,
         "key-frame positioning does not apply accurate-preroll marking");
}

void testAccurateVideoRejectsInexactOrUnrepresentableIntervals() {
  using namespace wam::macos::avfoundation_media_source_testing;
  std::string error;
  expect(accurateVideoDecodeOnly(CMTimeMake(-1, 2), CMTimeMake(1, 1),
                                 {0, 1}, &error) == false &&
             accurateVideoDecodeOnly(CMTimeMake(-1, 2), CMTimeMake(1, 2),
                                     {0, 1}, &error) == true,
         "the exact interval helper still classifies negative preroll independently of admission policy");
  expect(!accurateVideoDecodeOnly(CMTimeMake(4, 1), kCMTimeInvalid,
                                  {5, 1}, &error),
         "accurate video rejects an unknown duration");
  expect(!accurateVideoDecodeOnly(CMTimeMake(4, 1), kCMTimeZero, {5, 1},
                                  &error),
         "accurate video rejects a zero duration");
  expect(!accurateVideoDecodeOnly(CMTimeMake(4, 1), CMTimeMake(-1, 60),
                                  {5, 1}, &error),
         "accurate video rejects a negative duration");

  CMTime roundedDuration = CMTimeMake(1, 60);
  roundedDuration.flags |= kCMTimeFlags_HasBeenRounded;
  expect(!accurateVideoDecodeOnly(CMTimeMake(4, 1), roundedDuration,
                                  {5, 1}, &error),
         "accurate video rejects a rounded duration");
  expect(!accurateVideoDecodeOnly(
             CMTimeMake(std::numeric_limits<std::int64_t>::max(), 1),
             CMTimeMake(1, 1),
             {std::numeric_limits<std::int64_t>::max(), 1}, &error),
         "accurate video rejects interval-end numerator overflow");
  expect(!accurateVideoDecodeOnly(
             CMTimeMake(1, std::numeric_limits<std::int32_t>::max()),
             CMTimeMake(1, std::numeric_limits<std::int32_t>::max() - 1),
             {1, 1}, &error),
         "accurate video rejects an unrepresentable exact denominator");
}

void testAdmissionHeadsExactMergeAndEos() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  // Both PTS values round to the same double. Exact DTS ordering must still
  // choose audio first, while the video head retains its original pointer.
  auto video = makeSample(videoFormat.get(),
                          CMTimeMake(9'007'199'254'740'993LL, 1),
                          CMTimeMake(9'007'199'254'740'994LL, 1), 32, 1);
  auto audio = makeSample(audioFormat.get(),
                          CMTimeMake(9'007'199'254'740'994LL, 1),
                          CMTimeMake(9'007'199'254'740'993LL, 1), 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(
      GenerationPlan{1, descriptor(), {0, 1}, {video.get()}, {audio.get()},
                     nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(1), "admission generation should arm");
  MediaSourceOpenOutcome opened = source.openLocalFile("fake.mov", options(), 1);
  expect(opened.status == MediaSourceOpenStatus::Ready &&
             opened.preparedContext.get() == source.assetContext().get() &&
             opened.preparedContext->backendKind() ==
                 MediaSourceBackendKind::AVFoundation &&
             opened.preparedContext->descriptor().get() ==
                 opened.descriptor.get(),
         "fake source should open ready");
  expect(backend->makes.load() == 1 && backend->made[0]->starts.load() == 1,
         "open should create and start exactly one generation");
  const MediaSourceStats admitted = source.stats();
  expect(admitted.stagedGeneration == 1 &&
             admitted.stagedVideoHeads == 1 &&
             admitted.stagedAudioHeads == 1 &&
             admitted.stagedPayloadBytes == 48 &&
             admitted.peakStagedPayloadBytes == 48,
         "ready admission should retain exactly one head per selected output");
  expect(backend->made[0]->videoCopies.load() == 1 &&
             backend->made[0]->audioCopies.load() == 1,
         "admission must read each first head once without a probe reader");

  MediaSourceReadResult first = source.readNext(1);
  expect(std::holds_alternative<MediaSample>(first) &&
             std::get<MediaSample>(first).track == 2,
         "exact DTS merge should emit audio before later video DTS");
  auto audioBorrow = std::get<MediaSample>(first)
                         .payload.borrowNative<
                             NativePayloadKind::CoreMediaSampleBuffer>();
  expect(audioBorrow && audioBorrow->opaqueAddress() == audio.get(),
         "first audio read should expose the exact admission CMSampleBuffer");

  MediaSourceReadResult second = source.readNext(1);
  expect(std::holds_alternative<MediaSample>(second) &&
             std::get<MediaSample>(second).track == 1,
         "second merged result should be video");
  auto videoBorrow = std::get<MediaSample>(second)
                         .payload.borrowNative<
                             NativePayloadKind::CoreMediaSampleBuffer>();
  expect(videoBorrow && videoBorrow->opaqueAddress() == video.get(),
         "first video read should expose the exact admission CMSampleBuffer");
  expect(std::holds_alternative<MediaEndOfStream>(source.readNext(1)),
         "video EOS should be emitted once");
  expect(std::holds_alternative<MediaEndOfStream>(source.readNext(1)),
         "audio EOS should be emitted once");
  expect(std::holds_alternative<MediaSourceExhausted>(source.readNext(1)) &&
             std::holds_alternative<MediaSourceExhausted>(source.readNext(1)),
         "post-EOS reads should be idempotently exhausted");
}

MediaSourceOpenStatus observeAdmissionVideoHead(
    CMFormatDescriptionRef sampleFormat, CMTime pts, CMTime duration,
    bool keyFrame, std::shared_ptr<const MediaSourceDescriptor> admitted,
    int* videoCopies = nullptr, int* audioCopies = nullptr) {
  auto audioFormat = makeAudioFormat();
  auto video = makeSample(sampleFormat, pts, kCMTimeInvalid, 16, 1, keyFrame,
                          duration);
  auto audio = makeSample(audioFormat.get(), CMTimeMake(0, 1),
                          kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(GenerationPlan{
      90, std::move(admitted), {0, 1}, {video.get()}, {audio.get()}, nullptr,
      nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(90), "admission-head fixture should arm");
  const MediaSourceOpenOutcome opened =
      source.openLocalFile("admission-head.mov", options(), 90);
  if (videoCopies != nullptr) {
    *videoCopies = backend->made[0]->videoCopies.load();
  }
  if (audioCopies != nullptr) {
    *audioCopies = backend->made[0]->audioCopies.load();
  }
  return opened.status;
}

void testAdmissionVideoHeadMustBeConsumerReady() {
  auto format = makeVideoFormat();
  int videoCopies = 0;
  int audioCopies = 0;
  expect(observeAdmissionVideoHead(format.get(), CMTimeMake(0, 1),
                                   CMTimeMake(1, 60), true, descriptor()) ==
             MediaSourceOpenStatus::Ready,
         "a key nonnegative positive-duration admission video head is ready");
  expect(observeAdmissionVideoHead(format.get(), CMTimeMake(0, 1),
                                   CMTimeMake(1, 60), false, descriptor(),
                                   &videoCopies, &audioCopies) ==
             MediaSourceOpenStatus::Unsupported &&
             videoCopies == 1 && audioCopies == 0,
         "a non-key admission video head fails before any audio admission copy");
  expect(observeAdmissionVideoHead(format.get(), CMTimeMake(-1, 60),
                                   CMTimeMake(1, 60), true, descriptor()) ==
             MediaSourceOpenStatus::Unsupported,
         "a negative admission PTS fails closed before Ready");
  expect(observeAdmissionVideoHead(format.get(), CMTimeMake(0, 1),
                                   kCMTimeInvalid, true, descriptor()) ==
             MediaSourceOpenStatus::Unsupported &&
             observeAdmissionVideoHead(format.get(), CMTimeMake(0, 1),
                                       kCMTimeZero, true, descriptor()) ==
                 MediaSourceOpenStatus::Unsupported,
         "unknown and zero admission video durations fail closed");
  CMTime roundedDuration = CMTimeMake(1, 60);
  roundedDuration.flags |= kCMTimeFlags_HasBeenRounded;
  expect(observeAdmissionVideoHead(format.get(), CMTimeMake(0, 1),
                                   roundedDuration, true, descriptor()) ==
             MediaSourceOpenStatus::Unsupported,
         "rounded admission video duration is not an exact positive proof");
  auto changedDimensions = makeVideoFormat(kCMVideoCodecType_H264, 17, 16);
  expect(observeAdmissionVideoHead(changedDimensions.get(), CMTimeMake(0, 1),
                                   CMTimeMake(1, 60), true, descriptor()) ==
             MediaSourceOpenStatus::Unsupported,
         "an admission sample whose coded dimensions drift fails closed");
}

void testDemandDrivenRefillPreservesExactMergeAndCapacity() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video0 = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                           kCMTimeInvalid, 32, 1);
  auto video1 = makeSample(videoFormat.get(), CMTimeMake(4, 1),
                           kCMTimeInvalid, 32, 1);
  auto audio0 = makeSample(audioFormat.get(), CMTimeMake(2, 1),
                           kCMTimeInvalid, 16, 1);
  auto audio1 = makeSample(audioFormat.get(), CMTimeMake(6, 1),
                           kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(GenerationPlan{
      3, descriptor(), {0, 1}, {video0.get(), video1.get()},
      {audio0.get(), audio1.get()}, nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(3), "deferred-refill generation should arm");
  expect(source.openLocalFile("deferred-refill.mov", options(), 3).status ==
             MediaSourceOpenStatus::Ready,
         "deferred-refill fixture should open ready");
  const auto generation = backend->made[0];
  expect(generation->videoCopies.load() == 1 &&
             generation->audioCopies.load() == 1 &&
             source.stats().stagedGeneration == 3 &&
             source.stats().stagedPayloadBytes == 48,
         "admission should own one bounded head per selected lane");

  MediaSourceReadResult first = source.readNext(3);
  expect(std::holds_alternative<MediaSample>(first) &&
             std::get<MediaSample>(first).track == 1 &&
             std::get<MediaSample>(first).presentationTime == MediaTime{0, 1},
         "the exact earliest admission head should be returned first");
  expect(generation->videoCopies.load() == 1 &&
             generation->audioCopies.load() == 1,
         "the first read must perform zero replacement pulls");
  expect(source.stats().stagedGeneration == 3 &&
             source.stats().stagedVideoHeads == 0 &&
             source.stats().stagedAudioHeads == 1 &&
             source.stats().stagedPayloadBytes == 16 &&
             source.stats().peakStagedPayloadBytes == 48,
         "consumption should expose the exact empty lane without inflating byte stats");

  MediaSourceReadResult second = source.readNext(3);
  expect(generation->videoCopies.load() == 2 &&
             generation->audioCopies.load() == 1,
         "the next demand should refill only the missing video lane");
  expect(std::holds_alternative<MediaSample>(second) &&
             std::get<MediaSample>(second).track == 2 &&
             std::get<MediaSample>(second).presentationTime == MediaTime{2, 1},
         "refill must precede ordering so an earlier retained audio head wins");
  expect(source.stats().stagedGeneration == 3 &&
             source.stats().stagedVideoHeads == 1 &&
             source.stats().stagedAudioHeads == 0 &&
             source.stats().stagedPayloadBytes == 32 &&
             source.stats().peakStagedPayloadBytes == 48,
         "refill should retain at most one replacement head per lane");

  MediaSourceReadResult third = source.readNext(3);
  MediaSourceReadResult fourth = source.readNext(3);
  expect(generation->videoCopies.load() == 3 &&
             generation->audioCopies.load() == 2,
         "each later demand should pull only the exact lane needed for merge proof");
  expect(std::holds_alternative<MediaSample>(third) &&
             std::get<MediaSample>(third).track == 1 &&
             std::get<MediaSample>(third).presentationTime == MediaTime{4, 1} &&
             std::holds_alternative<MediaSample>(fourth) &&
             std::get<MediaSample>(fourth).track == 2 &&
             std::get<MediaSample>(fourth).presentationTime == MediaTime{6, 1},
         "deferred refill must emit every interleaved A/V sample once in exact order");

  MediaSourceReadResult videoEnd = source.readNext(3);
  MediaSourceReadResult audioEnd = source.readNext(3);
  expect(generation->videoCopies.load() == 3 &&
             generation->audioCopies.load() == 3,
         "EOS discovery should also occur only on a later downstream demand");
  expect(std::holds_alternative<MediaEndOfStream>(videoEnd) &&
             std::get<MediaEndOfStream>(videoEnd).track == 1 &&
             std::holds_alternative<MediaEndOfStream>(audioEnd) &&
             std::get<MediaEndOfStream>(audioEnd).track == 2 &&
             std::holds_alternative<MediaSourceExhausted>(source.readNext(3)) &&
             source.stats().stagedGeneration == 0 &&
             source.stats().stagedVideoHeads == 0 &&
             source.stats().stagedAudioHeads == 0 &&
             source.stats().stagedPayloadBytes == 0 &&
             source.stats().peakStagedPayloadBytes == 48,
         "deferred lane terminals should preserve one EOS marker per selected track");
}

void testDeferredRefillPreservesRuntimeDiscontinuityAndFailurePrecedence() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video0 = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                           kCMTimeInvalid, 32, 1);
  auto marker = makeDiscontinuity(CMTimeMake(1, 1));
  auto video1 = makeSample(videoFormat.get(), CMTimeMake(4, 1),
                           kCMTimeInvalid, 32, 1);
  auto audio0 = makeSample(audioFormat.get(), CMTimeMake(2, 1),
                           kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(GenerationPlan{
      4, descriptor(), {0, 1}, {video0.get(), marker.get(), video1.get()},
      {audio0.get()}, nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(4), "runtime-marker generation should arm");
  expect(source.openLocalFile("runtime-marker.mov", options(), 4).status ==
             MediaSourceOpenStatus::Ready,
         "runtime-marker fixture should open ready");
  expect(std::holds_alternative<MediaSample>(source.readNext(4)),
         "the first encoded head should precede its later marker");
  MediaSourceReadResult discontinuity = source.readNext(4);
  expect(std::holds_alternative<MediaDiscontinuity>(discontinuity) &&
             std::get<MediaDiscontinuity>(discontinuity).track == 1 &&
             std::get<MediaDiscontinuity>(discontinuity).time ==
                 MediaTime{1, 1},
         "a deferred replacement discontinuity must participate in exact merge order");
  MediaSourceReadResult audio = source.readNext(4);
  MediaSourceReadResult video = source.readNext(4);
  expect(std::holds_alternative<MediaSample>(audio) &&
             std::get<MediaSample>(audio).track == 2 &&
             std::get<MediaSample>(audio).presentationTime == MediaTime{2, 1} &&
             std::holds_alternative<MediaSample>(video) &&
             std::get<MediaSample>(video).track == 1 &&
             std::get<MediaSample>(video).presentationTime == MediaTime{4, 1},
         "runtime markers must not duplicate or lose adjacent encoded samples");

  auto failingVideo0 = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                                  kCMTimeInvalid, 32, 1);
  auto retainedAudio = makeSample(audioFormat.get(), CMTimeMake(1, 1),
                                  kCMTimeInvalid, 16, 1);
  auto failingBackend = std::make_shared<FakeBackend>();
  GenerationPlan failing{5, descriptor(), {0, 1}, {failingVideo0.get()},
                         {retainedAudio.get()}, nullptr, nullptr, false};
  failing.videoFailureOnCall = 2;
  failingBackend->plans.push_back(std::move(failing));
  AVFoundationMediaSource failingSource(failingBackend);
  expect(failingSource.armOperation(5), "replacement-failure generation should arm");
  expect(failingSource.openLocalFile("replacement-failure.mov", options(), 5)
                 .status == MediaSourceOpenStatus::Ready,
         "replacement-failure fixture should admit its real heads");
  expect(std::holds_alternative<MediaSample>(failingSource.readNext(5)),
         "the first head must return before its replacement failure is observed");
  MediaSourceReadResult retained = failingSource.readNext(5);
  MediaSourceReadResult failure = failingSource.readNext(5);
  expect(std::holds_alternative<MediaSample>(retained) &&
             std::get<MediaSample>(retained).track == 2 &&
             failingBackend->made[0]->videoCopies.load() == 2 &&
             failingBackend->made[0]->audioCopies.load() == 1,
         "a refill failure should not discard or overread the other staged head");
  expect(std::holds_alternative<MediaSourceFailure>(failure) &&
             std::get<MediaSourceFailure>(failure).error ==
                 "injected replacement pull failure",
         "the sticky refill failure must precede terminal markers after staged data drains");
}

void testExactCancellationDuringDeferredRefill() {
  auto gate = std::make_shared<PullGate>();
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video0 = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                           kCMTimeInvalid, 32, 1);
  auto video1 = makeSample(videoFormat.get(), CMTimeMake(2, 1),
                           kCMTimeInvalid, 32, 1);
  auto audio0 = makeSample(audioFormat.get(), CMTimeMake(1, 1),
                           kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  GenerationPlan plan{6, descriptor(), {0, 1},
                      {video0.get(), video1.get()}, {audio0.get()}, nullptr,
                      nullptr, false};
  plan.videoPullGate = gate;
  backend->plans.push_back(std::move(plan));
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(6), "refill-cancellation generation should arm");
  expect(source.openLocalFile("refill-cancel.mov", options(), 6).status ==
             MediaSourceOpenStatus::Ready,
         "refill-cancellation fixture should open ready");
  expect(std::holds_alternative<MediaSample>(source.readNext(6)) &&
             backend->made[0]->videoCopies.load() == 1,
         "first delivery should leave its replacement pull pending");

  MediaSourceReadResult cancelled;
  std::thread worker([&] { cancelled = source.readNext(6); });
  {
    std::unique_lock lock(gate->mutex);
    gate->changed.wait(lock, [&] { return gate->entered; });
  }
  source.requestCancel(5);
  expect(!source.stats().cancelled,
         "stale cancellation must remain inert during a blocked refill");
  source.requestCancel(6);
  worker.join();
  expect(std::holds_alternative<MediaSourceCancelled>(cancelled) &&
             std::get<MediaSourceCancelled>(cancelled).generation == 6,
         "exact cancellation must wake and terminate the blocked refill");
  expect(backend->made[0]->videoCopies.load() == 2 &&
             backend->made[0]->audioCopies.load() == 1 &&
             !source.stats().open && source.stats().stagedGeneration == 0 &&
             source.stats().stagedVideoHeads == 0 &&
             source.stats().stagedAudioHeads == 0 &&
             source.stats().stagedPayloadBytes == 0,
         "cancelled refill must retire all heads without a duplicate or speculative pull");
}

void testFormatlessDiscontinuityPrecedesImmutableFormatCheck() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto marker = makeDiscontinuity(CMTimeMake(0, 1));
  auto video = makeSample(videoFormat.get(), CMTimeMake(1, 60),
                          kCMTimeInvalid, 32, 1);
  auto audio = makeSample(audioFormat.get(), CMTimeMake(1, 120),
                          kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(GenerationPlan{
      2, descriptor(), {0, 1}, {marker.get(), video.get()}, {audio.get()},
      nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(2),
         "formatless discontinuity generation should arm");
  const MediaSourceOpenOutcome opened =
      source.openLocalFile("discontinuity.mov", options(), 2);
  expect(opened.status == MediaSourceOpenStatus::Ready,
         "a valid formatless discontinuity must not be mistaken for format change");
  MediaSourceReadResult first = source.readNext(2);
  expect(std::holds_alternative<MediaSample>(first) &&
             std::get<MediaSample>(first).track == 2,
         "a validated admission marker is consumed before publication");
  MediaSourceReadResult second = source.readNext(2);
  expect(std::holds_alternative<MediaSample>(second) &&
             std::get<MediaSample>(second).track == 1 &&
             std::get<MediaSample>(second).generation == 2 &&
             std::get<MediaSample>(second).presentationTime ==
                 MediaTime{1, 60},
         "the first encoded video sample is still format-checked after the marker");
}

// AVFoundation closes every track output with a payload-free marker tail: an
// untimed decoder-control buffer (DrainAfterDecoding,
// PostNotificationWhenConsumed) and the edit list's empty-media terminator,
// whose timestamp is the asset's edited duration rather than a media-timeline
// position. Neither states media the backend can publish. A payload-free
// buffer that states an exact time and claims no empty media is an ordinary
// discontinuity marker and must survive to the staging path.
void testMediaFreeMarkersAreDistinguishedFromDiscontinuities() {
  CMSampleBufferRef raw = nullptr;
  const OSStatus status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, nullptr, nullptr, 0, 0, nullptr, 0, nullptr, &raw);
  expect(status == noErr && raw != nullptr,
         "synthetic decoder-control marker should be created");
  OwnedSample drain(raw);
  if (drain.get() != nullptr) {
    CMSetAttachment(drain.get(),
                    kCMSampleBufferAttachmentKey_DrainAfterDecoding,
                    kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    expect(CMSampleBufferGetNumSamples(drain.get()) == 0 &&
               CMSampleBufferGetDataBuffer(drain.get()) == nullptr &&
               !CMTIME_IS_NUMERIC(
                   CMSampleBufferGetPresentationTimeStamp(drain.get())),
           "synthetic decoder-control marker should carry no media or time");
    expect(avfoundation_media_source_testing::mediaFreeMarkerForTesting(
               drain.get()),
           "an untimed payload-free buffer states no media");
  }

  auto emptyMedia = makeDiscontinuity(CMTimeMake(72'000, 1000));
  CMSetAttachment(emptyMedia.get(), kCMSampleBufferAttachmentKey_EmptyMedia,
                  kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
  expect(avfoundation_media_source_testing::mediaFreeMarkerForTesting(
             emptyMedia.get()),
         "an edit-list empty-media terminator states no media");

  auto permanentEmptyMedia = makeDiscontinuity(CMTimeMake(72'000, 1000));
  CMSetAttachment(permanentEmptyMedia.get(),
                  kCMSampleBufferAttachmentKey_PermanentEmptyMedia,
                  kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
  expect(avfoundation_media_source_testing::mediaFreeMarkerForTesting(
             permanentEmptyMedia.get()),
         "a permanent empty-media terminator states no media");

  auto discontinuity = makeDiscontinuity(CMTimeMake(3, 60));
  expect(!avfoundation_media_source_testing::mediaFreeMarkerForTesting(
             discontinuity.get()),
         "a timed formatless marker stays a publishable discontinuity");

  auto audioFormat = makeAudioFormat();
  auto audio = makeSample(audioFormat.get(), CMTimeMake(0, 1), kCMTimeInvalid,
                          16, 1);
  expect(!avfoundation_media_source_testing::mediaFreeMarkerForTesting(
             audio.get()),
         "an ordinary access unit always states media");
  expect(!avfoundation_media_source_testing::mediaFreeMarkerForTesting(nullptr),
         "a null buffer is not a marker");
}

void testAdmissionDiscontinuityPrefixIsBounded() {
  auto audioFormat = makeAudioFormat();
  auto audio = makeSample(audioFormat.get(), CMTimeMake(0, 1),
                          kCMTimeInvalid, 16, 1);
  std::vector<OwnedSample> markers;
  std::vector<CMSampleBufferRef> videoSamples;
  markers.reserve(64);
  videoSamples.reserve(64);
  for (std::size_t index = 0; index < 64; ++index) {
    markers.push_back(makeDiscontinuity(
        CMTimeMake(static_cast<std::int64_t>(index), 60)));
    videoSamples.push_back(markers.back().get());
  }
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(GenerationPlan{
      3, descriptor(), {0, 1}, std::move(videoSamples), {audio.get()},
      nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(3),
         "discontinuity flood generation should arm");
  const MediaSourceOpenOutcome opened =
      source.openLocalFile("marker-flood.mov", options(), 3);
  expect(opened.status == MediaSourceOpenStatus::Unsupported &&
             opened.error ==
                 "selected AVFoundation output exceeds the bounded admission "
                 "discontinuity prefix" &&
             backend->made[0]->videoCopies.load() == 64 &&
             backend->made[0]->audioCopies.load() == 0 &&
             !source.stats().open,
         "an admission marker flood fails closed at the exact finite cap");
}

void testExactCancellationWhileStartBlocks() {
  auto gate = std::make_shared<StartGate>();
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video = makeSample(videoFormat.get(), CMTimeMake(0, 1), kCMTimeInvalid,
                          16, 1);
  auto audio = makeSample(audioFormat.get(), CMTimeMake(0, 1), kCMTimeInvalid,
                          16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(GenerationPlan{7, descriptor(), {0, 1},
                                          {video.get()}, {audio.get()}, gate,
                                          nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(7), "blocking generation should arm");
  MediaSourceOpenOutcome opened;
  std::thread worker([&] {
    opened = source.openLocalFile("blocking.mov", options(), 7);
  });
  {
    std::unique_lock lock(gate->mutex);
    gate->changed.wait(lock, [&] { return gate->entered; });
  }
  expect(source.stats().operationGeneration == 7,
         "blocking open should publish its generation before work");
  source.requestCancel(6);
  expect(backend->made[0]->cancels.load() == 0,
         "stale cancellation must be inert");
  source.requestCancel(7);
  worker.join();
  expect(opened.status == MediaSourceOpenStatus::Cancelled,
         "exact generation should cancel blocked open");
  expect(source.stats().operationGeneration == 0 && !source.stats().open,
         "cancelled open should withdraw publication and remain closed");
}

void testMetadataLoadsOverlapAndValidateInSourceOrder() {
  using namespace wam::macos::avfoundation_media_source_testing;
  struct LoadHarness {
    std::mutex mutex;
    std::condition_variable changed;
    std::array<std::function<void()>, 2> completions;
    std::size_t issued{0};
    std::size_t inFlight{0};
    std::size_t peakInFlight{0};
    std::vector<std::size_t> validationOrder;
  } harness;

  std::array<ConcurrentMetadataLoadRequest, 2> requests;
  for (std::size_t index = 0; index < requests.size(); ++index) {
    requests[index].issue = [&, index](std::function<void()> completion) {
      std::lock_guard lock(harness.mutex);
      ++harness.issued;
      ++harness.inFlight;
      harness.peakInFlight =
          std::max(harness.peakInFlight, harness.inFlight);
      harness.completions[index] = [&, completion = std::move(completion)] {
        {
          std::lock_guard completionLock(harness.mutex);
          --harness.inFlight;
        }
        completion();
      };
      harness.changed.notify_all();
    };
    requests[index].validate = [&, index](std::string*) {
      harness.validationOrder.push_back(index);
      return true;
    };
  }

  ConcurrentMetadataLoadCancellation cancellation;
  ConcurrentMetadataLoadObservation observation;
  std::string error;
  bool loaded = false;
  std::thread worker([&] {
    loaded = waitForConcurrentMetadataLoads(
        requests, cancellation, &observation, &error);
  });

  bool bothIssued = false;
  {
    std::unique_lock lock(harness.mutex);
    bothIssued = harness.changed.wait_for(
        lock, std::chrono::seconds(1),
        [&] { return harness.issued == requests.size(); });
  }
  expect(bothIssued && harness.peakInFlight == 2,
         "selected video/audio metadata loads must overlap before either completes");
  if (bothIssued) {
    // Complete audio first to prove completion order does not alter the
    // deterministic video-then-audio validation order.
    harness.completions[1]();
    harness.completions[0]();
  } else {
    cancellation.cancel();
  }
  worker.join();
  expect(loaded && error.empty() && observation.issued == 2 &&
             observation.validated == 2 &&
             observation.wake ==
                 ConcurrentMetadataLoadWake::AllCompleted &&
             harness.validationOrder == std::vector<std::size_t>({0, 1}),
         "metadata completion order must preserve source-first validation");

  std::vector<std::size_t> failureOrder;
  std::array<ConcurrentMetadataLoadRequest, 2> failingRequests;
  for (std::size_t index = 0; index < failingRequests.size(); ++index) {
    failingRequests[index].issue = [](std::function<void()> completion) {
      completion();
    };
    failingRequests[index].validate =
        [&, index](std::string* validationError) {
          failureOrder.push_back(index);
          if (validationError != nullptr) {
            *validationError = index == 0 ? "video metadata failed"
                                          : "audio metadata failed";
          }
          return false;
        };
  }
  ConcurrentMetadataLoadCancellation failureCancellation;
  ConcurrentMetadataLoadObservation failureObservation;
  error.clear();
  expect(!waitForConcurrentMetadataLoads(
             failingRequests, failureCancellation, &failureObservation,
             &error) &&
             error == "video metadata failed" &&
             failureOrder == std::vector<std::size_t>({0}) &&
             failureObservation.issued == 2 &&
             failureObservation.validated == 1,
         "concurrent metadata failure attribution must remain video-first");
}

void testMetadataCancellationUsesExactWakeEdge() {
  using namespace wam::macos::avfoundation_media_source_testing;
  struct CancellationHarness {
    std::mutex mutex;
    std::condition_variable changed;
    std::array<std::function<void()>, 2> retainedCompletions;
    std::size_t issued{0};
    std::size_t validated{0};
  } harness;
  std::array<ConcurrentMetadataLoadRequest, 2> requests;
  for (std::size_t index = 0; index < requests.size(); ++index) {
    requests[index].issue = [&, index](std::function<void()> completion) {
      std::lock_guard lock(harness.mutex);
      harness.retainedCompletions[index] = std::move(completion);
      ++harness.issued;
      harness.changed.notify_all();
    };
    requests[index].validate = [&](std::string*) {
      ++harness.validated;
      return true;
    };
  }

  ConcurrentMetadataLoadCancellation cancellation;
  ConcurrentMetadataLoadObservation observation;
  std::string error;
  bool loaded = true;
  std::thread worker([&] {
    loaded = waitForConcurrentMetadataLoads(
        requests, cancellation, &observation, &error);
  });
  {
    std::unique_lock lock(harness.mutex);
    const bool issued = harness.changed.wait_for(
        lock, std::chrono::seconds(1),
        [&] { return harness.issued == requests.size(); });
    expect(issued,
           "cancellation fixture must reach one shared metadata wait");
  }
  // No completion callback is fired. Returning therefore requires the exact
  // cancellation notification edge rather than a completion or polling tick.
  cancellation.cancel();
  worker.join();
  expect(!loaded &&
             observation.wake ==
                 ConcurrentMetadataLoadWake::CancellationEdge &&
             observation.issued == 2 && observation.validated == 0 &&
             harness.validated == 0 &&
             error == "AVFoundation generation was cancelled",
         "metadata cancellation must wake immediately without polling or validation");
}

void testSeekRecreatesOnceAndPreservesCoveringFrame() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto firstVideo = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                               kCMTimeInvalid, 16, 1);
  auto firstAudio = makeSample(audioFormat.get(), CMTimeMake(0, 1),
                               kCMTimeInvalid, 16, 1);
  auto seekVideo = makeSample(videoFormat.get(), CMTimeMake(4, 1),
                              kCMTimeInvalid, 16, 1, true,
                              CMTimeMake(2, 1));
  auto seekAudio = makeSample(audioFormat.get(), CMTimeMake(5, 1),
                              kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(GenerationPlan{10, descriptor(), {0, 1},
                                          {firstVideo.get()},
                                          {firstAudio.get()}, nullptr, nullptr,
                                          false});
  backend->plans.push_back(GenerationPlan{11, descriptor(), {4, 1},
                                          {seekVideo.get()},
                                          {seekAudio.get()}, nullptr, nullptr,
                                          false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(10), "pre-seek open generation should arm");
  expect(source.openLocalFile("seek.mov", options(), 10).status ==
             MediaSourceOpenStatus::Ready,
         "pre-seek source should open");
  expect(source.armOperation(11), "seek generation should arm");
  const MediaSourceStats armed = source.stats();
  expect(armed.generation == 11 && armed.operationGeneration == 11 &&
             armed.stagedGeneration == 10 &&
             armed.stagedVideoHeads == 1 &&
             armed.stagedAudioHeads == 1 &&
             armed.stagedPayloadBytes == 32,
         "arming seek advances operation high water without relabeling the "
         "still-owned prior-generation heads");
  const MediaSourceSeekOutcome sought =
      source.seek({11, {5, 1}, MediaSeekMode::Accurate});
  const MediaSourceStats soughtStats = source.stats();
  expect(sought.accepted && sought.actualDecodeStart == MediaTime{4, 1} &&
             soughtStats.stagedGeneration == 11 &&
             soughtStats.stagedVideoHeads == 1 &&
             soughtStats.stagedAudioHeads == 1 &&
             soughtStats.stagedPayloadBytes == 32,
         "seek should report the actual preceding sync start");
  expect(backend->makes.load() == 2 && backend->made.size() == 2,
         "seek should recreate exactly one asset/reader generation");
  MediaSourceReadResult result = source.readNext(11);
  expect(std::holds_alternative<MediaSample>(result) &&
             std::get<MediaSample>(result).track == 1 &&
             !std::get<MediaSample>(result).decodeOnly,
         "accurate seek keeps a video frame covering its target presentable");
}

void testSeekAdmissionRejectsNonKeyVideoHead() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto firstVideo = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                               kCMTimeInvalid, 16, 1);
  auto firstAudio = makeSample(audioFormat.get(), CMTimeMake(0, 1),
                               kCMTimeInvalid, 16, 1);
  auto seekVideo = makeSample(videoFormat.get(), CMTimeMake(4, 1),
                              kCMTimeInvalid, 16, 1, false,
                              CMTimeMake(1, 1));
  auto seekAudio = makeSample(audioFormat.get(), CMTimeMake(5, 1),
                              kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(GenerationPlan{91, descriptor(), {0, 1},
                                          {firstVideo.get()},
                                          {firstAudio.get()}, nullptr, nullptr,
                                          false});
  backend->plans.push_back(GenerationPlan{92, descriptor(), {4, 1},
                                          {seekVideo.get()},
                                          {seekAudio.get()}, nullptr, nullptr,
                                          false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(91) &&
             source.openLocalFile("seek-admission.mov", options(), 91).status ==
                 MediaSourceOpenStatus::Ready &&
             source.armOperation(92),
         "seek admission fixture should open and arm");
  const MediaSourceSeekOutcome sought =
      source.seek({92, {5, 1}, MediaSeekMode::Accurate});
  expect(!sought.accepted && backend->made[1]->videoCopies.load() == 1 &&
             backend->made[1]->audioCopies.load() == 0 &&
             !source.stats().open,
         "a non-key seek admission head fails before audio staging and closes the source");
}

void testSeekReusesExactImmutableAssetContext() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto firstVideo = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                               kCMTimeInvalid, 16, 1);
  auto firstAudio = makeSample(audioFormat.get(), CMTimeMake(0, 1),
                               kCMTimeInvalid, 16, 1);
  auto seekVideo = makeSample(videoFormat.get(), CMTimeMake(2, 1),
                              kCMTimeInvalid, 16, 1, true,
                              CMTimeMake(2, 1));
  auto seekAudio = makeSample(audioFormat.get(), CMTimeMake(3, 1),
                              kCMTimeInvalid, 16, 1);
  const auto admitted = descriptor();
  auto lifetime = std::make_shared<int>(7);
  std::weak_ptr<int> lifetimeWeak = lifetime;
  const std::filesystem::path path{"context.mov"};
  auto context = makeAVFoundationAssetContextForTesting(
      path, options(), admitted, lifetime);
  expect(context != nullptr &&
             context->backendKind() ==
                 MediaSourceBackendKind::AVFoundation &&
             context->descriptor().get() == admitted.get() &&
             context->matchesMainRequest(path, options(), admitted) &&
             context->facts().assetMetadataLoadBatches == 1 &&
             context->facts().selectedTrackMetadataLoadBatches == 1,
         "cold admission should create one exact immutable asset context");
  lifetime.reset();

  auto backend = std::make_shared<FakeBackend>();
  GenerationPlan cold{60, admitted, {0, 1}, {firstVideo.get()},
                      {firstAudio.get()}, nullptr, nullptr, false};
  cold.assetContext = context;
  backend->plans.push_back(std::move(cold));
  GenerationPlan seek{61, admitted, {2, 1}, {seekVideo.get()},
                      {seekAudio.get()}, nullptr, nullptr, false};
  seek.assetContext = context;
  backend->plans.push_back(std::move(seek));

  AVFoundationMediaSource source(backend);
  expect(source.armOperation(60), "context cold generation should arm");
  auto opened = source.openLocalFile(path, options(), 60);
  expect(opened.status == MediaSourceOpenStatus::Ready &&
             opened.preparedContext.get() == context.get() &&
             opened.preparedContext->descriptor().get() ==
                 opened.descriptor.get() &&
             source.assetContext().get() == context.get() &&
             backend->coldContextRequests.load() == 1 &&
             backend->reusedContextRequests.load() == 0,
         "cold open should publish the generation-provided context once");
  expect(source.armOperation(61), "context seek generation should arm");
  auto sought = source.seek({61, {3, 1}, MediaSeekMode::Accurate});
  expect(sought.accepted && backend->makes.load() == 2 &&
             sought.preparedContext.get() == context.get() &&
             backend->coldContextRequests.load() == 1 &&
             backend->reusedContextRequests.load() == 1 &&
             backend->requests[1].assetContext.get() == context.get() &&
             source.assetContext().get() == context.get(),
         "seek should reuse exact context while creating one fresh generation");

  source.close();
  expect(source.assetContext() == nullptr &&
             source.stats().operationGeneration == 0 &&
             source.stats().stagedGeneration == 0 &&
             source.stats().stagedVideoHeads == 0 &&
             source.stats().stagedAudioHeads == 0 &&
             source.stats().stagedPayloadBytes == 0 &&
             !lifetimeWeak.expired(),
         "source close should release its context but not an external preview lease");
  backend->made.clear();
  backend->requests.clear();
  opened.preparedContext.reset();
  sought.preparedContext.reset();
  context.reset();
  expect(lifetimeWeak.expired(),
         "asset context lifetime should end after both main and preview leases retire");
}

void testAssetContextIdentityFailsClosedBeforeAdmissionCopies() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                          kCMTimeInvalid, 16, 1);
  auto audio = makeSample(audioFormat.get(), CMTimeMake(0, 1),
                          kCMTimeInvalid, 16, 1);
  const auto admitted = descriptor();
  auto context = makeAVFoundationAssetContextForTesting(
      "identity.mov", options(), admitted);
  expect(context != nullptr &&
             !context->matchesMainRequest("other.mov", options(), admitted),
         "asset context must reject a different source path");
  auto copiedDescriptor =
      std::make_shared<MediaSourceDescriptor>(*admitted);
  expect(!context->matchesMainRequest("identity.mov", options(),
                                      copiedDescriptor),
         "equal descriptor bytes cannot forge context instance identity");
  auto tightened = options();
  tightened.limits.maximumAudioSampleBytes = 1024;
  expect(!context->matchesMainRequest("identity.mov", tightened, admitted),
         "asset context must reject changed effective limits");

  auto backend = std::make_shared<FakeBackend>();
  GenerationPlan cold{70, admitted, {0, 1}, {video.get()}, {audio.get()},
                      nullptr, nullptr, false};
  cold.assetContext = context;
  backend->plans.push_back(std::move(cold));
  GenerationPlan forged{71, copiedDescriptor, {0, 1}, {video.get()},
                        {audio.get()}, nullptr, nullptr, false};
  forged.assetContext = context;
  backend->plans.push_back(std::move(forged));
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(70), "identity cold generation should arm");
  expect(source.openLocalFile("identity.mov", options(), 70).status ==
             MediaSourceOpenStatus::Ready,
         "identity fixture should open with its original context");
  expect(source.armOperation(71), "forged context seek should arm");
  const auto rejected = source.seek({71, {1, 1}, MediaSeekMode::Accurate});
  expect(!rejected.accepted && rejected.preparedContext == nullptr &&
             backend->made[1]->videoCopies.load() == 0 &&
             backend->made[1]->audioCopies.load() == 0,
         "generation cannot pair the retained context with a copied descriptor before head copies");
}

void testSeekPublishesBeforePriorRetirement() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video = makeSample(videoFormat.get(), CMTimeMake(0, 1), kCMTimeInvalid,
                          16, 1);
  auto audio = makeSample(audioFormat.get(), CMTimeMake(0, 1), kCMTimeInvalid,
                          16, 1);
  auto retirementGate = std::make_shared<StartGate>();
  auto backend = std::make_shared<FakeBackend>();
  GenerationPlan initial{30, descriptor(), {0, 1}, {video.get()},
                         {audio.get()}, nullptr, nullptr, false};
  initial.cancelGate = retirementGate;
  backend->plans.push_back(std::move(initial));
  backend->plans.push_back(
      GenerationPlan{31, descriptor(), {1, 1}, {video.get()}, {audio.get()},
                     nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(30), "retirement fixture open should arm");
  expect(source.openLocalFile("retire.mov", options(), 30).status ==
             MediaSourceOpenStatus::Ready,
         "retirement-race source should open");

  MediaSourceSeekOutcome outcome;
  expect(source.armOperation(31), "retirement seek should arm");
  std::thread worker([&] {
    outcome = source.seek({31, {1, 1}, MediaSeekMode::Accurate});
  });
  {
    std::unique_lock lock(retirementGate->mutex);
    retirementGate->changed.wait(lock,
                                 [&] { return retirementGate->entered; });
  }
  expect(source.stats().operationGeneration == 31,
         "seek must publish the new generation before prior retirement");
  source.requestCancel(31);
  {
    std::lock_guard lock(retirementGate->mutex);
    retirementGate->resume = true;
    retirementGate->changed.notify_all();
  }
  worker.join();
  expect(!outcome.accepted && backend->makes.load() == 1,
         "cancel during retirement must prevent creation of the new reader");
}

void testInitialPositionUsesOneReaderAndPreservesAudioPreroll() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video = makeSample(videoFormat.get(), CMTimeMake(4, 1),
                          kCMTimeInvalid, 16, 1, true);
  auto audio = makeSample(audioFormat.get(), CMTimeMake(4, 1),
                          kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(
      GenerationPlan{12, descriptor(), {4, 1}, {video.get()}, {audio.get()},
                     nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  MediaSourceOpenOptions positioned = options();
  positioned.initialPosition =
      MediaSourceInitialPosition{{5, 1}, MediaSeekMode::Accurate};
  expect(source.armOperation(12), "positioned open generation should arm");
  const MediaSourceOpenOutcome opened =
      source.openLocalFile("positioned.mov", positioned, 12);
  expect(opened.status == MediaSourceOpenStatus::Ready &&
             opened.actualDecodeStart == MediaTime{4, 1} &&
             backend->makes.load() == 1 && backend->requests.size() == 1 &&
             backend->requests[0].target == MediaTime{5, 1} &&
             backend->requests[0].seekMode == MediaSeekMode::Accurate &&
             backend->requests[0].options.initialPosition ==
                 positioned.initialPosition &&
             source.stats().seeksAccepted == 0,
         "initial position is carried into exactly one first generation");

  MediaSourceReadResult videoResult = source.readNext(12);
  MediaSourceReadResult audioResult = source.readNext(12);
  expect(std::holds_alternative<MediaSample>(videoResult) &&
             std::get<MediaSample>(videoResult).track == 1 &&
             std::get<MediaSample>(videoResult).decodeOnly,
         "accurate initial positioning marks only video sync preroll decode-only");
  expect(std::holds_alternative<MediaSample>(audioResult) &&
             std::get<MediaSample>(audioResult).track == 2 &&
             !std::get<MediaSample>(audioResult).decodeOnly,
         "accurate audio preroll remains decodable for exact PCM trimming");

  auto invalidBackend = std::make_shared<FakeBackend>();
  AVFoundationMediaSource invalid(invalidBackend);
  MediaSourceOpenOptions invalidOptions = options();
  invalidOptions.initialPosition =
      MediaSourceInitialPosition{{-1, 1}, MediaSeekMode::Accurate};
  expect(invalid.armOperation(13), "invalid positioned open still arms");
  const MediaSourceOpenOutcome invalidOutcome =
      invalid.openLocalFile("invalid-position.mov", invalidOptions, 13);
  expect(invalidOutcome.status == MediaSourceOpenStatus::Failed &&
             invalidOutcome.preparedContext == nullptr &&
             invalidBackend->makes.load() == 0,
         "negative initial position is rejected before backend work");

  auto boundedDescriptor =
      std::make_shared<MediaSourceDescriptor>(*descriptor());
  boundedDescriptor->duration = {10, 1};
  boundedDescriptor->tracks[0].duration = {10, 1};
  boundedDescriptor->tracks[1].duration = {10, 1};
  auto boundedBackend = std::make_shared<FakeBackend>();
  boundedBackend->plans.push_back(GenerationPlan{
      14, boundedDescriptor, {0, 1}, {video.get()}, {audio.get()}, nullptr,
      nullptr, false});
  AVFoundationMediaSource beyond(boundedBackend);
  MediaSourceOpenOptions beyondOptions = options();
  beyondOptions.initialPosition =
      MediaSourceInitialPosition{{11, 1}, MediaSeekMode::Accurate};
  expect(beyond.armOperation(14), "past-duration open should arm");
  const MediaSourceOpenOutcome beyondOutcome =
      beyond.openLocalFile("past-duration.mov", beyondOptions, 14);
  expect(beyondOutcome.status == MediaSourceOpenStatus::Unsupported &&
             beyondOutcome.preparedContext == nullptr &&
             boundedBackend->makes.load() == 1 &&
             boundedBackend->made[0]->videoCopies.load() == 0 &&
             boundedBackend->made[0]->audioCopies.load() == 0,
         "injected target beyond exact duration cannot reach admission heads");
}

void testPreEntryCancellationArm() {
  auto unopenedBackend = std::make_shared<FakeBackend>();
  AVFoundationMediaSource unopened(unopenedBackend);
  expect(unopened.armOperation(40),
         "pre-entry open should reserve its generation");
  unopened.requestCancel(39);
  unopened.requestCancel(41);
  unopened.requestCancel(40);
  const MediaSourceOpenOutcome cancelledOpen =
      unopened.openLocalFile("pre-entry-open.mov", options(), 40);
  expect(cancelledOpen.status == MediaSourceOpenStatus::Cancelled &&
             cancelledOpen.preparedContext == nullptr &&
             unopenedBackend->makes.load() == 0 &&
             unopened.stats().generation == 40 &&
             unopened.stats().operationGeneration == 0,
         "exact pre-entry cancel prevents all open backend work");

  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video = makeSample(videoFormat.get(), CMTimeMake(0, 1),
                          kCMTimeInvalid, 16, 1);
  auto audio = makeSample(audioFormat.get(), CMTimeMake(0, 1),
                          kCMTimeInvalid, 16, 1);
  auto backend = std::make_shared<FakeBackend>();
  backend->plans.push_back(
      GenerationPlan{50, descriptor(), {0, 1}, {video.get()}, {audio.get()},
                     nullptr, nullptr, false});
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(50), "pre-entry seek fixture open should arm");
  expect(source.openLocalFile("pre-entry-seek.mov", options(), 50).status ==
             MediaSourceOpenStatus::Ready,
         "pre-entry seek fixture should open");
  expect(source.armOperation(51),
         "pre-entry seek should reserve its generation");
  source.requestCancel(51);
  const MediaSourceSeekOutcome cancelledSeek =
      source.seek({51, {1, 1}, MediaSeekMode::Accurate});
  expect(!cancelledSeek.accepted &&
             cancelledSeek.preparedContext == nullptr &&
             backend->makes.load() == 1 &&
             !source.stats().open && source.stats().generation == 51,
         "exact pre-entry cancel prevents creation of a seek generation");
}

void testDescriptorExtractionAndBounds() {
  using namespace wam::macos::avfoundation_media_source_testing;
  auto h264 = makeVideoFormat();
  std::string error;
  auto video = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(h264.get()), 9, {60, 1},
      MediaSourceLimits{}, &error);
  expect(video && video->codec == MediaCodec::H264 &&
             video->codecConfigurationKind ==
                 MediaCodecConfigurationKind::AvcC &&
             video->codecConfiguration.size() == kFixtureFreeAvcC.size() &&
             video->video &&
             video->video->cleanAperture ==
                 MediaCleanAperture{{16, 1}, {16, 1}, {0, 1}, {0, 1}} &&
             video->video->sampleFormat ==
                 MediaVideoSampleFormat::Yuv420EightBit,
         "video inspection should copy the exact bounded avcC atom");

  auto audioFormat = makeAudioFormat();
  auto audio = inspectAudioFormat(
      static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()), 10,
      {60, 1}, MediaSourceLimits{}, &error);
  expect(audio && audio->audio &&
             audio->audio->formatTag == kAudioFormatMPEG4AAC &&
             audio->audio->sampleRate == 48'000.0 &&
             !audio->audio->channelLayoutPresent &&
             audio->audio->channelLayoutTag == 0 &&
             audio->codecConfiguration ==
                 std::vector<std::byte>({std::byte{0x12}, std::byte{0x10}}),
         "audio inspection should preserve ASBD identity, cookie, and layout absence");

  auto describedAudioFormat = makeAudioFormat(
      2, kAudioChannelLayoutTag_UseChannelDescriptions, 2);
  auto describedAudio = inspectAudioFormat(
      static_cast<CMAudioFormatDescriptionRef>(describedAudioFormat.get()),
      14, {60, 1}, MediaSourceLimits{}, &error);
  expect(!describedAudio,
         "a present tag-zero description layout fails closed in native v1");

  auto stereoAudioFormat =
      makeAudioFormat(2, kAudioChannelLayoutTag_Stereo);
  auto stereoAudio = inspectAudioFormat(
      static_cast<CMAudioFormatDescriptionRef>(stereoAudioFormat.get()), 15,
      {60, 1}, MediaSourceLimits{}, &error);
  expect(stereoAudio && stereoAudio->audio &&
             stereoAudio->audio->channelLayoutPresent &&
             stereoAudio->audio->channelLayoutTag ==
                 kAudioChannelLayoutTag_Stereo,
         "a present canonical stereo layout preserves its exact tag");

  auto monoAudioFormat = makeAudioFormat(1, kAudioChannelLayoutTag_Mono);
  auto monoAudio = inspectAudioFormat(
      static_cast<CMAudioFormatDescriptionRef>(monoAudioFormat.get()), 16,
      {60, 1}, MediaSourceLimits{}, &error);
  expect(monoAudio && monoAudio->audio &&
             monoAudio->audio->channelLayoutPresent &&
             monoAudio->audio->channelLayoutTag == kAudioChannelLayoutTag_Mono,
         "a present canonical mono layout preserves its exact tag");

  auto compactMonoAudioFormat = makeAudioFormat(
      1, kAudioChannelLayoutTag_Mono, 0, std::nullopt, true);
  std::size_t compactLayoutSize = 0;
  const AudioChannelLayout* compactLayout =
      CMAudioFormatDescriptionGetChannelLayout(
          static_cast<CMAudioFormatDescriptionRef>(
              compactMonoAudioFormat.get()),
          &compactLayoutSize);
  auto compactMonoAudio = inspectAudioFormat(
      static_cast<CMAudioFormatDescriptionRef>(compactMonoAudioFormat.get()),
      19, {60, 1}, MediaSourceLimits{}, &error);
  expect(compactLayout != nullptr &&
             compactLayoutSize ==
                 offsetof(AudioChannelLayout, mChannelDescriptions) &&
             compactMonoAudio && compactMonoAudio->audio &&
             compactMonoAudio->audio->channels == 1 &&
             compactMonoAudio->audio->channelLayoutPresent &&
             compactMonoAudio->audio->channelLayoutTag ==
                 kAudioChannelLayoutTag_Mono,
         "a compact 12-byte tag-only mono layout is admitted exactly");

  auto headphoneAudioFormat =
      makeAudioFormat(2, kAudioChannelLayoutTag_StereoHeadphones);
  expect(!inspectAudioFormat(
             static_cast<CMAudioFormatDescriptionRef>(
                 headphoneAudioFormat.get()),
             17, {60, 1}, MediaSourceLimits{}, &error),
         "a noncanonical predefined stereo layout fails closed");

  auto bitmapAudioFormat = makeAudioFormat(
      2, kAudioChannelLayoutTag_UseChannelBitmap, 0,
      kAudioChannelBit_Left | kAudioChannelBit_Right);
  expect(!inspectAudioFormat(
             static_cast<CMAudioFormatDescriptionRef>(bitmapAudioFormat.get()),
             18, {60, 1}, MediaSourceLimits{}, &error),
         "a bitmap-defined layout fails closed without stored bitmap identity");

  constexpr std::size_t compactPrefixBytes =
      offsetof(AudioChannelLayout, mChannelDescriptions);
  alignas(AudioChannelLayout)
      std::array<std::byte, compactPrefixBytes> exactCompactBytes{};
  const AudioChannelLayoutTag exactCompactTag =
      kAudioChannelLayoutTag_Mono;
  const AudioChannelBitmap exactCompactBitmap = 0;
  const std::uint32_t exactCompactDescriptionCount = 0;
  std::memcpy(exactCompactBytes.data() +
                  offsetof(AudioChannelLayout, mChannelLayoutTag),
              &exactCompactTag, sizeof(exactCompactTag));
  std::memcpy(exactCompactBytes.data() +
                  offsetof(AudioChannelLayout, mChannelBitmap),
              &exactCompactBitmap, sizeof(exactCompactBitmap));
  std::memcpy(exactCompactBytes.data() +
                  offsetof(AudioChannelLayout,
                           mNumberChannelDescriptions),
              &exactCompactDescriptionCount,
              sizeof(exactCompactDescriptionCount));
  expect(validAudioChannelLayoutForTesting(
             reinterpret_cast<const AudioChannelLayout*>(
                 exactCompactBytes.data()),
             exactCompactBytes.size(), 1),
         "an allocation containing exactly the 12-byte mono prefix is safe and valid");

  alignas(AudioChannelLayout) std::array<std::byte, 128> layoutBytes{};
  auto* malformedLayout =
      ::new (layoutBytes.data()) AudioChannelLayout{};
  malformedLayout->mChannelLayoutTag =
      kAudioChannelLayoutTag_UseChannelDescriptions;
  malformedLayout->mNumberChannelDescriptions = 2;
  const std::size_t describedLayoutSize =
      offsetof(AudioChannelLayout, mChannelDescriptions) +
      2 * sizeof(AudioChannelDescription);
  expect(!validAudioChannelLayoutForTesting(
             malformedLayout, describedLayoutSize - 1, 2) &&
             !validAudioChannelLayoutForTesting(
                 malformedLayout, describedLayoutSize, 1),
         "truncated and channel-count-inconsistent layout descriptors fail closed");

  malformedLayout->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
  malformedLayout->mNumberChannelDescriptions = 0;
  expect(!validAudioChannelLayoutForTesting(
             malformedLayout,
             offsetof(AudioChannelLayout, mChannelDescriptions), 1),
         "a predefined layout tag inconsistent with the ASBD fails closed");

  malformedLayout->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
  expect(validAudioChannelLayoutForTesting(malformedLayout,
                                           compactPrefixBytes, 2) &&
             !validAudioChannelLayoutForTesting(malformedLayout,
                                                compactPrefixBytes - 1, 2) &&
             !validAudioChannelLayoutForTesting(malformedLayout,
                                                compactPrefixBytes + 1, 2),
         "a compact tag-only layout is exact while truncated and stray-tail encodings fail closed");

  malformedLayout->mChannelLayoutTag =
      kAudioChannelLayoutTag_UseChannelDescriptions;
  malformedLayout->mNumberChannelDescriptions =
      std::numeric_limits<std::uint32_t>::max();
  expect(!validAudioChannelLayoutForTesting(malformedLayout,
                                            describedLayoutSize, 2),
         "a forged description count cannot overrun its bounded payload");

  malformedLayout->mChannelLayoutTag =
      kAudioChannelLayoutTag_DiscreteInOrder;
  expect(!validAudioChannelLayoutForTesting(
             malformedLayout,
             offsetof(AudioChannelLayout, mChannelDescriptions), 2),
         "a variable-count layout without its encoded channel count fails closed");

  malformedLayout->mChannelLayoutTag =
      static_cast<AudioChannelLayoutTag>(0xffff0002U);
  expect(!validAudioChannelLayoutForTesting(
             malformedLayout,
             offsetof(AudioChannelLayout, mChannelDescriptions), 2),
         "an unrecognized tag fails closed even when its low bits say stereo");

  const CMTimeRange trackRange =
      CMTimeRangeMake(kCMTimeZero, CMTimeMake(60, 1));
  expect(preservesZeroBasedTrackTimeline(trackRange, &error),
         "one exact zero-based track range is supported");
  CMTimeRange offsetRange = trackRange;
  offsetRange.start = CMTimeMake(1024, 48'000);
  CMTimeRange roundedRange = trackRange;
  roundedRange.duration.flags |= kCMTimeFlags_HasBeenRounded;
  expect(!preservesZeroBasedTrackTimeline(offsetRange, &error) &&
             !preservesZeroBasedTrackTimeline(roundedRange, &error),
         "offset and rounded track timelines fail closed without loading edits");

  const auto exactRange = exactReaderTimeRange(
      CMTimeMake(60, 1), CMTimeMake(5, 1));
  CMTime roundedStart = CMTimeMake(5, 1);
  roundedStart.flags |= kCMTimeFlags_HasBeenRounded;
  expect(exactRange && CMTimeCompare(exactRange->start, CMTimeMake(5, 1)) == 0 &&
             CMTimeCompare(exactRange->duration, CMTimeMake(55, 1)) == 0 &&
             !exactReaderTimeRange(CMTimeMake(60, 1), roundedStart) &&
             !exactReaderTimeRange(CMTimeMake(60, 1), CMTimeMake(61, 1)),
         "reader range preserves exact subtraction and rejects rounded or past-end starts");

  auto oversized = makeVideoFormat(kCMVideoCodecType_H264, 1921, 1080);
  expect(!inspectVideoFormat(
              static_cast<CMVideoFormatDescriptionRef>(oversized.get()), 11,
              {60, 1}, MediaSourceLimits{}, &error),
         "descriptor extraction should reject coded dimensions above limits");

  auto croppedFormat = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.fractionalCrop = true});
  auto croppedTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(croppedFormat.get()), 12,
      {60, 1}, MediaSourceLimits{}, &error);
  expect(croppedTrack && croppedTrack->video &&
             croppedTrack->video->cleanAperture->width ==
                 MediaRational{31, 2} &&
             !mediaVideoHasFullCodedAperture(*croppedTrack->video),
         "fractional clean aperture must remain exact and visibly cropped");

  auto nonSquareFormat = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.nonSquarePixels = true});
  auto nonSquareTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(nonSquareFormat.get()), 13,
      {60, 1}, MediaSourceLimits{}, &error);
  expect(nonSquareTrack && nonSquareTrack->video &&
             nonSquareTrack->video->pixelAspectNumerator == 2 &&
             nonSquareTrack->video->pixelAspectDenominator == 1 &&
             !mediaVideoHasSquarePixels(*nonSquareTrack->video),
         "non-square pixel aspect ratio must remain exact");

  auto pqFormat = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.pqTransfer = true});
  auto pqTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(pqFormat.get()), 14, {60, 1},
      MediaSourceLimits{}, &error);
  expect(pqTrack && pqTrack->video &&
             pqTrack->video->transferFunction == MediaTransferFunction::Pq &&
             pqTrack->video->unsupportedColorMetadataPresent,
         "PQ transfer must remain explicit and fail closed for SDR v1");

  auto dolbyFormat = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.dolbyVision = true});
  auto dolbyTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(dolbyFormat.get()), 15,
      {60, 1}, MediaSourceLimits{}, &error);
  expect(dolbyTrack && dolbyTrack->video &&
             dolbyTrack->video->dolbyVisionConfigurationPresent,
         "Dolby Vision atoms must remain an explicit fallback proof");

  auto interlacedFormat = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.interlaced = true});
  auto interlacedTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(interlacedFormat.get()), 16,
      {60, 1}, MediaSourceLimits{}, &error);
  expect(interlacedTrack && interlacedTrack->video &&
             interlacedTrack->video->fieldCount == 2 &&
             !interlacedTrack->video->progressive,
         "field count must preserve the current interlace fallback gate");

  if (@available(macOS 12.0, *)) {
    auto ambientFormat = makeVideoFormat(
        kCMVideoCodecType_H264, 16, 16,
        VideoFormatOptions{.ambientViewingEnvironment = true});
    auto ambientTrack = inspectVideoFormat(
        static_cast<CMVideoFormatDescriptionRef>(ambientFormat.get()), 17,
        {60, 1}, MediaSourceLimits{}, &error);
    expect(ambientTrack && ambientTrack->video &&
               ambientTrack->video->unsupportedColorMetadataPresent,
           "ambient-viewing HDR metadata must fail closed for SDR v1");
  }

  MediaSourceDescriptor admitted = *descriptor();
  expect(preservesLegacyNativeAdmission(admitted, &error),
         "selected A/V inventory should preserve legacy native admission");
  MediaSourceDescriptor multipleVideo = admitted;
  multipleVideo.inventory.video = 2;
  multipleVideo.inventory.total = 3;
  expect(!preservesLegacyNativeAdmission(multipleVideo, &error),
         "a second unselected video track must preserve fallback behavior");
  MediaSourceDescriptor embeddedText = admitted;
  embeddedText.inventory.subtitle = 1;
  embeddedText.inventory.total = 3;
  expect(!preservesLegacyNativeAdmission(embeddedText, &error),
         "embedded subtitle inventory must preserve fallback behavior");
  MediaSourceDescriptor cropped = admitted;
  cropped.tracks[0].video->cleanAperture->width = {31, 2};
  expect(!preservesLegacyNativeAdmission(cropped, &error),
         "fractional clean aperture must preserve fallback behavior");
  MediaSourceDescriptor hdr = admitted;
  hdr.tracks[0].video->transferFunction = MediaTransferFunction::Pq;
  hdr.tracks[0].video->unsupportedColorMetadataPresent = true;
  expect(!preservesLegacyNativeAdmission(hdr, &error),
         "explicit HDR metadata must preserve fallback behavior");
  MediaSourceDescriptor dolbyVision = admitted;
  dolbyVision.tracks[0].video->dolbyVisionConfigurationPresent = true;
  expect(!preservesLegacyNativeAdmission(dolbyVision, &error),
         "Dolby Vision configuration must preserve fallback behavior");

  MediaSourceDescriptor describedAudioDescriptor = admitted;
  describedAudioDescriptor.tracks[1].audio->channelLayoutPresent = true;
  describedAudioDescriptor.tracks[1].audio->channelLayoutTag =
      kAudioChannelLayoutTag_UseChannelDescriptions;
  expect(!preservesLegacyNativeAdmission(describedAudioDescriptor, &error),
         "injected tag-zero descriptions cannot bypass native v1 admission");

  MediaSourceDescriptor canonicalStereo = admitted;
  canonicalStereo.tracks[1].audio->channelLayoutPresent = true;
  canonicalStereo.tracks[1].audio->channelLayoutTag =
      kAudioChannelLayoutTag_Stereo;
  expect(preservesLegacyNativeAdmission(canonicalStereo, &error),
         "injected exact canonical stereo remains native-admissible");

  MediaSourceDescriptor headphoneStereo = canonicalStereo;
  headphoneStereo.tracks[1].audio->channelLayoutTag =
      kAudioChannelLayoutTag_StereoHeadphones;
  expect(!preservesLegacyNativeAdmission(headphoneStereo, &error),
         "injected noncanonical stereo cannot bypass native v1 admission");
}

void testImmutableAudioLayoutIdentity() {
  using namespace wam::macos::avfoundation_media_source_testing;
  auto absentFormat = makeAudioFormat();
  auto describedFormat = makeAudioFormat(
      2, kAudioChannelLayoutTag_UseChannelDescriptions, 2);
  auto stereoFormat = makeAudioFormat(2, kAudioChannelLayoutTag_Stereo);
  auto headphoneFormat =
      makeAudioFormat(2, kAudioChannelLayoutTag_StereoHeadphones);
  auto absentSample = makeSample(absentFormat.get(), CMTimeMake(0, 1),
                                 kCMTimeInvalid, 16, 1);
  auto describedSample = makeSample(describedFormat.get(), CMTimeMake(0, 1),
                                    kCMTimeInvalid, 16, 1);
  auto stereoSample = makeSample(stereoFormat.get(), CMTimeMake(0, 1),
                                 kCMTimeInvalid, 16, 1);
  auto headphoneSample = makeSample(headphoneFormat.get(), CMTimeMake(0, 1),
                                    kCMTimeInvalid, 16, 1);

  MediaTrackDescriptor absentTrack = audioTrack({60, 1});
  expect(sampleFormatMatchesTrackForTesting(absentSample.get(), absentTrack) &&
             !sampleFormatMatchesTrackForTesting(describedSample.get(),
                                                 absentTrack),
         "immutable audio format rejects content-defined layout samples");

  MediaTrackDescriptor describedTrack = absentTrack;
  describedTrack.audio->channelLayoutPresent = true;
  describedTrack.audio->channelLayoutTag =
      kAudioChannelLayoutTag_UseChannelDescriptions;
  expect(!sampleFormatMatchesTrackForTesting(describedSample.get(),
                                             describedTrack) &&
             !sampleFormatMatchesTrackForTesting(absentSample.get(),
                                                 describedTrack),
         "an injected content-defined descriptor cannot create a matchable sample identity");

  MediaTrackDescriptor stereoTrack = absentTrack;
  stereoTrack.audio->channelLayoutPresent = true;
  stereoTrack.audio->channelLayoutTag = kAudioChannelLayoutTag_Stereo;
  expect(sampleFormatMatchesTrackForTesting(stereoSample.get(), stereoTrack) &&
             !sampleFormatMatchesTrackForTesting(headphoneSample.get(),
                                                 stereoTrack),
         "immutable audio format requires the exact admitted canonical layout tag");
}

void testHevcDescriptorHardening() {
  using namespace wam::macos::avfoundation_media_source_testing;
  std::string error;
  const std::vector<std::uint8_t> main = fixtureFreeHvcC(0);
  expect(coreMediaAcceptsFixtureFreeHevcParameterSets(main),
         "CoreMedia should validate the complete fixture-free Main parameter sets");
  auto mainWithoutBitsFormat = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.configuration = main});
  auto mainFormat = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bitsPerComponent = 8, .configuration = main});
  auto mainTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(mainFormat.get()), 30,
      {60, 1}, MediaSourceLimits{}, &error);
  auto mainWithoutBitsTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(mainWithoutBitsFormat.get()),
      29, {60, 1}, MediaSourceLimits{}, &error);
  expect(mainTrack && mainWithoutBitsTrack && mainWithoutBitsTrack->video &&
             mainTrack->codec == MediaCodec::Hevc &&
             mainTrack->codecConfigurationKind ==
                 MediaCodecConfigurationKind::HvcC &&
             mainTrack->video &&
             mainTrack->video->sampleFormat ==
                 MediaVideoSampleFormat::Yuv420EightBit &&
             mainTrack->video->bitsPerComponent == 8 &&
             mainWithoutBitsTrack->video->bitsPerComponent == 0,
         "fixture-free complete Main hvcC admits absent or matching component depth");

  const std::vector<std::uint8_t> main10 = fixtureFreeHvcC(2);
  expect(coreMediaAcceptsFixtureFreeHevcParameterSets(main10),
         "CoreMedia should validate the complete fixture-free Main10 parameter sets");
  auto main10Format = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bitsPerComponent = 10,
                         .configuration = main10});
  auto main10Track = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(main10Format.get()), 31,
      {60, 1}, MediaSourceLimits{}, &error);
  auto main10WithoutBitsFormat = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .configuration = main10});
  auto main10WithoutBitsTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(
          main10WithoutBitsFormat.get()),
      37, {60, 1}, MediaSourceLimits{}, &error);
  expect(main10Track && main10Track->video &&
             main10WithoutBitsTrack && main10WithoutBitsTrack->video &&
             main10Track->video->sampleFormat ==
                 MediaVideoSampleFormat::Yuv420TenBit &&
             main10Track->video->colorPrimaries ==
                 MediaColorPrimaries::Bt709 &&
             main10Track->video->transferFunction ==
                 MediaTransferFunction::Bt709 &&
             main10WithoutBitsTrack->video->bitsPerComponent == 0,
         "fixture-free Main10 preserves explicit SDR BT.709 and optional depth");
  if (main10Track) {
    MediaSourceDescriptor injected = *descriptor();
    MediaTrackDescriptor injectedHevc = *main10Track;
    injectedHevc.id = 1;
    injectedHevc.duration = injected.duration;
    injected.tracks[0] = std::move(injectedHevc);
    expect(preservesLegacyNativeAdmission(injected, &error),
           "an injected exact Main10 descriptor passes the common SDR gate");
    injected.tracks[0].video->colorPrimaries = MediaColorPrimaries::Unknown;
    injected.tracks[0].video->transferFunction = MediaTransferFunction::Unknown;
    expect(preservesLegacyNativeAdmission(injected, &error),
           "an injected untagged Main10 descriptor is admitted as SDR");
    injected.tracks[0].video->transferFunction = MediaTransferFunction::Pq;
    expect(!preservesLegacyNativeAdmission(injected, &error),
           "an injected Main10 descriptor with a PQ transfer stays non-native");
    injected.tracks[0].video->transferFunction = MediaTransferFunction::Bt709;
    injected.tracks[0].video->colorPrimaries = MediaColorPrimaries::Bt2020;
    expect(!preservesLegacyNativeAdmission(injected, &error),
           "an injected Main10 descriptor with BT.2020 primaries stays non-native");
    injected.tracks[0].video->colorPrimaries = MediaColorPrimaries::Bt709;
    injected.tracks[0].video->bitsPerComponent = 8;
    expect(!preservesLegacyNativeAdmission(injected, &error),
           "an injected Main10 descriptor cannot contradict hvcC depth");
  }

  auto main10WithoutColor = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bitsPerComponent = 10,
                         .configuration = main10});
  auto main10WithoutTransfer = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bitsPerComponent = 10,
                         .configuration = main10});
  auto main10WrongBits = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bitsPerComponent = 8,
                         .configuration = main10});
  auto mainWrongBits = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bitsPerComponent = 10, .configuration = main});
  auto main10PqTransfer = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.pqTransfer = true,
                         .bt709Primaries = true,
                         .bitsPerComponent = 10,
                         .configuration = main10});
  // Untagged Main 10 colour now resolves to SDR exactly as untagged Main does.
  expect(inspectVideoFormat(
             static_cast<CMVideoFormatDescriptionRef>(
                 main10WithoutColor.get()),
             32, {60, 1}, MediaSourceLimits{}, &error) &&
             inspectVideoFormat(
                 static_cast<CMVideoFormatDescriptionRef>(
                     main10WithoutTransfer.get()),
                 33, {60, 1}, MediaSourceLimits{}, &error),
         "Main10 with unspecified primaries or transfer is admitted as SDR");
  expect(!inspectVideoFormat(
             static_cast<CMVideoFormatDescriptionRef>(main10PqTransfer.get()),
             38, {60, 1}, MediaSourceLimits{}, &error) &&
             !inspectVideoFormat(
                 static_cast<CMVideoFormatDescriptionRef>(
                     main10WrongBits.get()),
                 34, {60, 1}, MediaSourceLimits{}, &error) &&
             !inspectVideoFormat(
                 static_cast<CMVideoFormatDescriptionRef>(mainWrongBits.get()),
                 35, {60, 1}, MediaSourceLimits{}, &error),
         "Main10 HDR transfer or contradictory hvcC depth fails closed");

  const auto rejectsConfiguration = [&error](
                                        const std::vector<std::uint8_t>& bytes) {
    (void)error;
    return parseHevcSampleFormatForTesting(std::span<const std::byte>(
               reinterpret_cast<const std::byte*>(bytes.data()),
               bytes.size())) == MediaVideoSampleFormat::Unsupported;
  };
  expect(rejectsConfiguration(fixtureFreeHvcC(0, false, true, true)) &&
             rejectsConfiguration(fixtureFreeHvcC(0, true, false, true)) &&
             rejectsConfiguration(fixtureFreeHvcC(0, true, true, false)),
         "hvcC requires complete VPS, SPS, and PPS arrays");

  std::vector<std::uint8_t> reserved = main;
  reserved[13] &= 0x0fU;
  std::vector<std::uint8_t> arrayReserved = main;
  arrayReserved[23] |= 0x40U;
  std::vector<std::uint8_t> incompleteParameterSet = main;
  incompleteParameterSet[23] &= 0x7fU;
  std::vector<std::uint8_t> duplicateVps = main;
  duplicateVps[22] = 4;
  duplicateVps.insert(duplicateVps.end(), main.begin() + 23,
                      main.begin() + 52);
  std::vector<std::uint8_t> headerOnlyVps = main;
  headerOnlyVps[26] = 0;
  headerOnlyVps[27] = 2;
  headerOnlyVps.erase(headerOnlyVps.begin() + 30,
                      headerOnlyVps.begin() + 52);
  std::vector<std::uint8_t> forbiddenBit = main;
  forbiddenBit[28] |= 0x80U;
  std::vector<std::uint8_t> temporalIdZero = main;
  temporalIdZero[29] &= 0xf8U;
  std::vector<std::uint8_t> typeMismatch = main;
  typeMismatch[28] = 0x42U;
  std::vector<std::uint8_t> truncated = main;
  truncated.pop_back();
  std::vector<std::uint8_t> trailing = main;
  trailing.push_back(0);
  expect(rejectsConfiguration(reserved) &&
             rejectsConfiguration(arrayReserved) &&
             rejectsConfiguration(incompleteParameterSet) &&
             rejectsConfiguration(duplicateVps) &&
             rejectsConfiguration(headerOnlyVps) &&
             rejectsConfiguration(forbiddenBit) &&
             rejectsConfiguration(temporalIdZero) &&
             rejectsConfiguration(typeMismatch) &&
             rejectsConfiguration(truncated) &&
             rejectsConfiguration(trailing),
         "malformed hvcC reserved bits, NAL headers, lengths, and tails fail closed");

  std::vector<std::uint8_t> wrongConfigurationProfile = main;
  wrongConfigurationProfile[1] = 2;
  const std::vector<std::uint8_t> wrongSpsProfile =
      fixtureFreeHvcC(0, true, true, true, 2);
  const std::vector<std::uint8_t> wrongVpsProfile =
      fixtureFreeHvcC(0, true, true, true, std::nullopt, 2);
  expect(rejectsConfiguration(wrongConfigurationProfile) &&
             rejectsConfiguration(wrongSpsProfile) &&
             rejectsConfiguration(wrongVpsProfile),
         "hvcC, VPS, and SPS PTLs must prove the same Main/Main10 profile");

  std::vector<std::uint8_t> summaryDepthMutation = main10;
  summaryDepthMutation[17] = 0xf8;
  summaryDepthMutation[18] = 0xf8;
  std::copy(main.begin() + 1, main.begin() + 13,
            summaryDepthMutation.begin() + 1);
  std::copy(main.begin() + 34, main.begin() + 46,
            summaryDepthMutation.begin() + 34);
  std::copy(main.begin() + 60, main.begin() + 72,
            summaryDepthMutation.begin() + 60);
  expect(rejectsConfiguration(summaryDepthMutation),
         "hvcC summary depth cannot contradict its SPS");
}

void testImmutableVideoFormatIdentity() {
  using namespace wam::macos::avfoundation_media_source_testing;
  std::string error;
  auto admittedFormat = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  auto track = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(admittedFormat.get()), 40,
      {60, 1}, MediaSourceLimits{}, &error);
  expect(track && track->video,
         "immutable video identity fixture should be admitted");
  if (!track || !track->video) {
    return;
  }
  auto identical = makeSample(admittedFormat.get(), CMTimeMake(0, 1),
                              kCMTimeInvalid, 16, 1);
  auto dimensions = makeVideoFormat(
      kCMVideoCodecType_H264, 17, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  auto aperture = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.fractionalCrop = true,
                         .bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  auto aspect = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.nonSquarePixels = true,
                         .bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  auto color = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  auto primaries = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.bt709Transfer = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  auto matrix = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bitsPerComponent = 8});
  auto componentDepth = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true});
  auto chroma = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true,
                         .centeredTopChroma = true,
                         .bitsPerComponent = 8});
  auto field = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.interlaced = true,
                         .bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  auto hdr = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.pqTransfer = true,
                         .bt709Primaries = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  auto dolby = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.dolbyVision = true,
                         .bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8});
  std::vector<std::uint8_t> mutatedAvcC(kFixtureFreeAvcC.begin(),
                                        kFixtureFreeAvcC.end());
  mutatedAvcC[3] ^= 1U;
  auto configuration = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bt709Matrix = true,
                         .bitsPerComponent = 8,
                         .configuration = mutatedAvcC});
  const auto mismatches = [&track](CMFormatDescriptionRef format) {
    auto sample = makeSample(format, CMTimeMake(0, 1), kCMTimeInvalid, 16, 1);
    return !sampleFormatMatchesTrackForTesting(sample.get(), *track);
  };
  expect(sampleFormatMatchesTrackForTesting(identical.get(), *track) &&
             mismatches(dimensions.get()) && mismatches(aperture.get()) &&
             mismatches(aspect.get()) && mismatches(color.get()) &&
             mismatches(primaries.get()) && mismatches(matrix.get()) &&
             mismatches(componentDepth.get()) &&
             mismatches(chroma.get()) && mismatches(field.get()) &&
             mismatches(hdr.get()) && mismatches(dolby.get()) &&
             mismatches(configuration.get()),
         "every modeled CM video identity fact and exact avcC stay immutable per sample");

  const std::vector<std::uint8_t> main10 = fixtureFreeHvcC(2);
  auto hevcFormat = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bitsPerComponent = 10,
                         .configuration = main10});
  auto hevcTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(hevcFormat.get()), 41,
      {60, 1}, MediaSourceLimits{}, &error);
  std::vector<std::uint8_t> changedHvcC = main10;
  changedHvcC[19] = 0;
  changedHvcC[20] = 1;
  const bool changedHvcCStillValid =
      parseHevcSampleFormatForTesting(std::span<const std::byte>(
          reinterpret_cast<const std::byte*>(changedHvcC.data()),
          changedHvcC.size())) == MediaVideoSampleFormat::Yuv420TenBit;
  auto changedHevcFormat = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.bt709Primaries = true,
                         .bt709Transfer = true,
                         .bitsPerComponent = 10,
                         .configuration = changedHvcC});
  auto changedHevcColor = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.pqTransfer = true,
                         .bt709Primaries = true,
                         .bitsPerComponent = 10,
                         .configuration = main10});
  auto changedHevcSample = makeSample(changedHevcFormat.get(),
                                      CMTimeMake(0, 1), kCMTimeInvalid, 16, 1);
  auto changedHevcColorSample = makeSample(
      changedHevcColor.get(), CMTimeMake(0, 1), kCMTimeInvalid, 16, 1);
  expect(hevcTrack && changedHvcCStillValid &&
             !sampleFormatMatchesTrackForTesting(changedHevcSample.get(),
                                                 *hevcTrack) &&
             !sampleFormatMatchesTrackForTesting(
                 changedHevcColorSample.get(), *hevcTrack),
         "exact hvcC and HEVC color/HDR drift are rejected per sample");
}

void testPreReaderSelectedFormatRebind() {
  using namespace wam::macos::avfoundation_media_source_testing;
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  const auto admitted = descriptor();
  std::size_t readerCreationAttempts = 0;
  std::string error;
  const auto rebind = [&](CMVideoFormatDescriptionRef video,
                          std::size_t videoCount,
                          CGAffineTransform transform,
                          CMAudioFormatDescriptionRef audio,
                          std::size_t audioCount,
                          const MediaSourceDescriptor& expected) {
    return selectedFormatsRebindBeforeReaderForTesting(
        video, videoCount, transform, audio, audioCount, expected,
        MediaSourceLimits{}, &readerCreationAttempts, &error);
  };

  expect(rebind(static_cast<CMVideoFormatDescriptionRef>(videoFormat.get()),
                1, CGAffineTransformIdentity,
                static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                1, *admitted) &&
             rebind(
                 static_cast<CMVideoFormatDescriptionRef>(videoFormat.get()),
                 1, CGAffineTransformIdentity,
                 static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                 1, *admitted) &&
             readerCreationAttempts == 2,
         "cold open and reused-context seek both rebind exact selected formats before reader attempts");

  const std::size_t admittedAttempts = readerCreationAttempts;
  auto changedDimensions = makeVideoFormat(kCMVideoCodecType_H264, 17, 16);
  auto changedColor = makeVideoFormat(
      kCMVideoCodecType_H264, 16, 16,
      VideoFormatOptions{.pqTransfer = true});
  auto changedAudioChannels = makeAudioFormat(1);
  constexpr std::array<std::uint8_t, 2> changedCookie{0x12, 0x11};
  auto changedAudioCookie = makeAudioFormat(
      2, std::nullopt, std::nullopt, std::nullopt, false, changedCookie);
  expect(!rebind(nullptr, 0, CGAffineTransformIdentity,
                 static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                 1, *admitted) &&
             !rebind(
                 static_cast<CMVideoFormatDescriptionRef>(videoFormat.get()),
                 2, CGAffineTransformIdentity,
                 static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                 1, *admitted) &&
             !rebind(
                 static_cast<CMVideoFormatDescriptionRef>(videoFormat.get()),
                 1, CGAffineTransformIdentity, nullptr, 0, *admitted) &&
             !rebind(
                 static_cast<CMVideoFormatDescriptionRef>(videoFormat.get()),
                 1, CGAffineTransformIdentity,
                 static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                 2, *admitted) &&
             !rebind(
                 static_cast<CMVideoFormatDescriptionRef>(
                     changedDimensions.get()),
                 1, CGAffineTransformIdentity,
                 static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                 1, *admitted) &&
             !rebind(
                 static_cast<CMVideoFormatDescriptionRef>(changedColor.get()),
                 1, CGAffineTransformIdentity,
                 static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                 1, *admitted) &&
             !rebind(
                 static_cast<CMVideoFormatDescriptionRef>(videoFormat.get()),
                 1, CGAffineTransformIdentity,
                 static_cast<CMAudioFormatDescriptionRef>(
                     changedAudioChannels.get()),
                 1, *admitted) &&
             !rebind(
                 static_cast<CMVideoFormatDescriptionRef>(videoFormat.get()),
                 1, CGAffineTransformIdentity,
                 static_cast<CMAudioFormatDescriptionRef>(
                     changedAudioCookie.get()),
                 1, *admitted) &&
             readerCreationAttempts == admittedAttempts,
         "missing, multiple, or mutated selected formats fail before reader-attempt accounting");

  CGAffineTransform signedZeroIdentity = CGAffineTransformIdentity;
  signedZeroIdentity.b = -0.0;
  signedZeroIdentity.tx = -0.0;
  const CGAffineTransform rotated =
      CGAffineTransformMake(0, 1, -1, 0, 16, 0);
  const CGAffineTransform mirrored =
      CGAffineTransformMake(-1, 0, 0, 1, 16, 0);
  const CGAffineTransform sheared =
      CGAffineTransformMake(1, 0, 0.01, 1, 0, 0);
  CGAffineTransform nonfinite = CGAffineTransformIdentity;
  nonfinite.a = std::numeric_limits<CGFloat>::quiet_NaN();
  expect(exactIdentityVideoTransformForTesting(CGAffineTransformIdentity) &&
             exactIdentityVideoTransformForTesting(signedZeroIdentity) &&
             !exactIdentityVideoTransformForTesting(rotated) &&
             !exactIdentityVideoTransformForTesting(mirrored) &&
             !exactIdentityVideoTransformForTesting(sheared) &&
             !exactIdentityVideoTransformForTesting(nonfinite) &&
             !rebind(
                 static_cast<CMVideoFormatDescriptionRef>(videoFormat.get()),
                 1, rotated,
                 static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                 1, *admitted) &&
             readerCreationAttempts == admittedAttempts,
         "current ship keeps rotations, mirrors, non-axis, and nonfinite transforms as explicit pre-reader fallback");

  const std::vector<std::uint8_t> main = fixtureFreeHvcC(0);
  auto hevcFormat = makeVideoFormat(
      kCMVideoCodecType_HEVC, 16, 16,
      VideoFormatOptions{.configuration = main});
  auto hevcTrack = inspectVideoFormat(
      static_cast<CMVideoFormatDescriptionRef>(hevcFormat.get()), 1,
      admitted->duration, MediaSourceLimits{}, &error);
  const bool hevcInspected = hevcTrack.has_value();
  MediaSourceDescriptor hevcDescriptor = *admitted;
  if (hevcTrack) {
    hevcDescriptor.tracks[0] = std::move(*hevcTrack);
  }
  expect(hevcInspected &&
             rebind(static_cast<CMVideoFormatDescriptionRef>(hevcFormat.get()),
                    1, CGAffineTransformIdentity,
                    static_cast<CMAudioFormatDescriptionRef>(audioFormat.get()),
                    1, hevcDescriptor) &&
             readerCreationAttempts == admittedAttempts + 1,
         "HEVC plus AAC rebinds through the same exact pre-reader gate");
}

void testWorkerExceptionsStayInsideSourceBoundary() {
  auto backend = std::make_shared<FakeBackend>();
  GenerationPlan plan;
  plan.generation = 20;
  plan.sourceDescriptor = descriptor();
  plan.throwOnStart = true;
  backend->plans.push_back(std::move(plan));
  AVFoundationMediaSource source(backend);
  expect(source.armOperation(20), "throwing generation should arm");
  const MediaSourceOpenOutcome outcome =
      source.openLocalFile("throw.mov", options(), 20);
  expect(outcome.status == MediaSourceOpenStatus::Failed &&
             outcome.error == "injected start exception",
         "worker-facing open should contain C++ exceptions");
}

void testInjectedBackendCannotBypassLegacyAdmission() {
  auto videoFormat = makeVideoFormat();
  auto audioFormat = makeAudioFormat();
  auto video = makeSample(videoFormat.get(), CMTimeMake(0, 1), kCMTimeInvalid,
                          16, 1);
  auto audio = makeSample(audioFormat.get(), CMTimeMake(0, 1), kCMTimeInvalid,
                          16, 1);
  MediaGeneration generation = 21;
  const auto expectRejected = [&](std::shared_ptr<MediaSourceDescriptor> input,
                                  const char* message) {
    auto backend = std::make_shared<FakeBackend>();
    backend->plans.push_back(GenerationPlan{
        generation, std::move(input), {0, 1}, {video.get()}, {audio.get()},
        nullptr, nullptr, false});
    AVFoundationMediaSource source(backend);
    expect(source.armOperation(generation),
           "injected admission generation should arm");
    const MediaSourceOpenOutcome outcome =
        source.openLocalFile("bypass.mov", options(), generation++);
    expect(outcome.status == MediaSourceOpenStatus::Unsupported &&
               backend->made[0]->videoCopies.load() == 0 &&
               backend->made[0]->audioCopies.load() == 0,
           message);
  };

  auto invalidInventory =
      std::make_shared<MediaSourceDescriptor>(*descriptor());
  invalidInventory->inventory.video = 2;
  invalidInventory->inventory.total = 3;
  expectRejected(std::move(invalidInventory),
                 "common owner gate must reject injected inventory before heads");

  auto inconsistentPq = std::make_shared<MediaSourceDescriptor>(*descriptor());
  inconsistentPq->tracks[0].video->transferFunction =
      MediaTransferFunction::Pq;
  inconsistentPq->tracks[0].video->unsupportedColorMetadataPresent = false;
  expectRejected(std::move(inconsistentPq),
                 "common owner gate must independently reject injected PQ");

  auto inconsistentBt2020 =
      std::make_shared<MediaSourceDescriptor>(*descriptor());
  inconsistentBt2020->tracks[0].video->colorPrimaries =
      MediaColorPrimaries::Bt2020;
  inconsistentBt2020->tracks[0].video->unsupportedColorMetadataPresent = false;
  expectRejected(
      std::move(inconsistentBt2020),
      "common owner gate must independently reject injected BT.2020");

  auto inconsistentMatrix =
      std::make_shared<MediaSourceDescriptor>(*descriptor());
  inconsistentMatrix->tracks[0].video->matrixCoefficients =
      MediaMatrixCoefficients::Bt2020Ncl;
  inconsistentMatrix->tracks[0].video->unsupportedColorMetadataPresent = false;
  expectRejected(
      std::move(inconsistentMatrix),
      "common owner gate must independently reject an injected BT.2020 matrix");

  auto inconsistentChroma =
      std::make_shared<MediaSourceDescriptor>(*descriptor());
  inconsistentChroma->tracks[0].video->topFieldChromaLocation =
      MediaChromaLocation::OtherExplicit;
  inconsistentChroma->tracks[0].video->unsupportedColorMetadataPresent = false;
  expectRejected(
      std::move(inconsistentChroma),
      "common owner gate must independently reject explicit unsupported chroma");

  auto inconsistentDepth =
      std::make_shared<MediaSourceDescriptor>(*descriptor());
  inconsistentDepth->tracks[0].video->bitsPerComponent = 12;
  inconsistentDepth->tracks[0].video->unsupportedColorMetadataPresent = false;
  expectRejected(
      std::move(inconsistentDepth),
      "common owner gate must independently reject injected 12-bit depth");
}

void testRealCompactAudioLayoutFixture(const std::filesystem::path& path) {
  using namespace wam::macos::avfoundation_media_source_testing;
  resetInspectedAudioChannelLayoutSizeForTesting();
  AVFoundationMediaSource source;
  expect(source.armOperation(90), "real compact-layout fixture should arm");
  const MediaSourceOpenOutcome opened =
      source.openLocalFile(path, options(), 90);
  if (opened.descriptor == nullptr) {
    std::cerr << "real compact-layout fixture admission error: "
              << opened.error << '\n';
    expect(false, "the real compact mono layout should pass cold admission");
    return;
  }

  const auto selectedAudio = opened.descriptor->selectedAudio;
  const auto selected =
      std::find_if(opened.descriptor->tracks.begin(),
                   opened.descriptor->tracks.end(), [&](const auto& track) {
                     return selectedAudio && track.id == *selectedAudio;
                   });
  expect(selected != opened.descriptor->tracks.end() && selected->audio &&
             selected->audio->channels == 1 &&
             selected->audio->channelLayoutPresent &&
             selected->audio->channelLayoutTag ==
                 kAudioChannelLayoutTag_Mono &&
             inspectedAudioChannelLayoutSizeForTesting() ==
                 offsetof(AudioChannelLayout, mChannelDescriptions),
         "the real fixture preserves its observed 12-byte compact mono layout identity");
  if (opened.status != MediaSourceOpenStatus::Ready) {
    std::cerr << "NOTE: real fixture passed compact audio admission but its "
                 "full source open stopped later: "
              << opened.error << '\n';
  }
  source.close();
}

// Reads a real edit-list asset to exhaustion through the production backend.
// Both track outputs end in AVFoundation's payload-free marker tail, so this
// is the regression guard for the intermittent mid-playback Decode failure:
// the source must reach end of stream on both lanes and exhaustion, without a
// failure and without publishing any marker as a discontinuity.
void testRealSourceDrainsMarkerTailToExhaustion(
    const std::filesystem::path& path) {
  AVFoundationMediaSource source;
  expect(source.armOperation(91), "real drain fixture should arm");
  const MediaSourceOpenOutcome opened =
      source.openLocalFile(path, options(), 91);
  if (opened.status != MediaSourceOpenStatus::Ready) {
    std::cerr << "real drain fixture admission error: " << opened.error << '\n';
    expect(false, "the real drain fixture should pass cold admission");
    return;
  }

  std::size_t samples = 0;
  std::size_t discontinuities = 0;
  std::size_t endsOfStream = 0;
  bool exhausted = false;
  std::string failure;
  // Every buffer of a 72 s two-track asset plus its terminal facts fits far
  // inside this bound; overrunning it is itself a failure of the drain.
  constexpr std::size_t kMaximumReads = 200'000;
  for (std::size_t read = 0; read != kMaximumReads && !exhausted; ++read) {
    MediaSourceReadResult result = source.readNext(91);
    if (std::holds_alternative<MediaSample>(result)) {
      ++samples;
    } else if (std::holds_alternative<MediaDiscontinuity>(result)) {
      ++discontinuities;
    } else if (std::holds_alternative<MediaEndOfStream>(result)) {
      ++endsOfStream;
    } else if (std::holds_alternative<MediaSourceExhausted>(result)) {
      exhausted = true;
    } else if (std::holds_alternative<MediaSourceFailure>(result)) {
      failure = std::get<MediaSourceFailure>(result).error;
      break;
    } else {
      failure = "the real drain fixture was cancelled";
      break;
    }
  }
  if (!failure.empty()) {
    std::cerr << "real drain fixture failure after " << samples
              << " samples: " << failure << '\n';
  }
  expect(failure.empty(),
         "draining a real edit-list asset must not fail the source");
  expect(exhausted, "draining a real edit-list asset must reach exhaustion");
  expect(endsOfStream == 2,
         "both selected lanes must reach end of stream exactly once");
  expect(discontinuities == 0,
         "no terminal marker may be published as a discontinuity");
  expect(samples > 1'000, "the real drain fixture should deliver its samples");
  std::cout << "AVFoundation real source drain: samples=" << samples
            << " endsOfStream=" << endsOfStream
            << " discontinuities=" << discontinuities << '\n';
  source.close();
}

void testRealDeferredFirstReadTiming(const std::filesystem::path& path) {
  AVFoundationMediaSource source;
  expect(source.armOperation(89), "real timing fixture should arm");
  const auto openBegin = std::chrono::steady_clock::now();
  const MediaSourceOpenOutcome opened =
      source.openLocalFile(path, options(), 89);
  const auto openEnd = std::chrono::steady_clock::now();
  if (opened.status != MediaSourceOpenStatus::Ready) {
    std::cerr << "real timing fixture admission error: " << opened.error
              << '\n';
    expect(false, "the real timing fixture should pass cold admission");
    return;
  }

  const auto firstBegin = std::chrono::steady_clock::now();
  MediaSourceReadResult first = source.readNext(89);
  const auto firstEnd = std::chrono::steady_clock::now();
  MediaSourceReadResult second = source.readNext(89);
  const auto secondEnd = std::chrono::steady_clock::now();
  expect(std::holds_alternative<MediaSample>(first) &&
             std::holds_alternative<MediaSample>(second),
         "the real timing fixture should deliver two encoded samples");

  const auto openMicros =
      std::chrono::duration_cast<std::chrono::microseconds>(openEnd - openBegin)
          .count();
  const auto firstNanos =
      std::chrono::duration_cast<std::chrono::nanoseconds>(firstEnd - firstBegin)
          .count();
  const auto secondNanos =
      std::chrono::duration_cast<std::chrono::nanoseconds>(secondEnd - firstEnd)
          .count();
  std::cout << "AVFoundation real source timing: cold_open_us=" << openMicros
            << " first_read_ns=" << firstNanos
            << " refill_read_ns=" << secondNanos << '\n';
  source.close();
}

}  // namespace

// Pins the EOF shape of every clip whose audio does not land on an exact
// 1024-frame AAC boundary -- the common case, and the exact shape that dropped
// h264-44k.mp4 to the fallback with a Decode failure at end of stream.
//
// The muxer folds the edit's end trim into the container: the final access
// unit's stts duration is shortened so that the track's declared media
// duration lands on the edited end (2585 access units for 60 s at 44.1 kHz,
// the last stated as 1008 of 1024 frames). CoreMedia repeats that shortfall as
// a TrimDurationAtEnd attachment, which this backend removes. Publishing the
// truncated duration alongside the removed attachment leaves an edit in the
// timing: the unit claims fewer frames on the media timeline than its own
// packet decodes to, and the frozen converter correctly refuses it. A
// legitimate CoreMedia EOF tail must drain to end of stream, so the truncated
// unit is restated on the codec's ordinal packet grid instead.
void testTruncatedFinalAudioPacketIsRestatedOnTheMediaGrid() {
  using namespace wam::macos::avfoundation_media_source_testing;
  constexpr std::int32_t kRate = 48'000;
  constexpr std::int64_t kPacketFrames = 1024;
  const OwnedFormat format = makeAudioFormat();

  const auto durationOf = [](const CMSampleTimingInfo& entry) {
    return entry.duration;
  };
  const auto isExactly = [](CMTime time, std::int64_t frames) {
    return CMTIME_IS_NUMERIC(time) && time.timescale == kRate &&
           time.value == frames && time.epoch == 0;
  };

  // One timing entry per access unit: only the truncated tail moves.
  {
    std::array<CMSampleTimingInfo, 4> timing{};
    for (std::size_t index = 0; index < timing.size(); ++index) {
      timing[index].presentationTimeStamp = CMTimeMake(
          3'452'928 + static_cast<std::int64_t>(index) * kPacketFrames, kRate);
      timing[index].decodeTimeStamp = kCMTimeInvalid;
      timing[index].duration = CMTimeMake(kPacketFrames, kRate);
    }
    timing[3].duration = CMTimeMake(1'008, kRate);
    const OwnedSample sample =
        makeCompressedAudioSample(format.get(), timing, timing.size(), 344);
    const std::size_t restated =
        restateCompressedAudioPacketDurationsForTesting(
            sample.get(), timing.data(), timing.size());
    expect(restated == 1,
           "only the truncated final access unit should be restated");
    for (std::size_t index = 0; index < timing.size(); ++index) {
      expect(isExactly(durationOf(timing[index]), kPacketFrames),
             "every access unit should occupy exactly one packet on the grid");
    }
    // The restated tail is contiguous with its own presentation time and ends
    // one whole packet later, which is exactly what the packet decodes to.
    const CMTime end = CMTimeAdd(timing[3].presentationTimeStamp,
                                 timing[3].duration);
    expect(CMTIME_IS_NUMERIC(end) &&
               CMTimeCompare(end, CMTimeMake(3'457'024, kRate)) == 0,
           "the restated tail should end on the exact packet grid");
  }

  // A single shared timing entry describes every access unit; the stream's
  // fixed packet size is the only thing that can speak for it.
  {
    std::array<CMSampleTimingInfo, 1> timing{};
    timing[0].presentationTimeStamp = CMTimeMake(3'452'928, kRate);
    timing[0].decodeTimeStamp = kCMTimeInvalid;
    timing[0].duration = CMTimeMake(1'008, kRate);
    const OwnedSample sample =
        makeCompressedAudioSample(format.get(), timing, 4, 344);
    const std::size_t restated =
        restateCompressedAudioPacketDurationsForTesting(
            sample.get(), timing.data(), timing.size());
    expect(restated == 1 && isExactly(timing[0].duration, kPacketFrames),
           "a shared short timing entry should be restated on the grid");
  }

  // The rule only ever lengthens, and only up to one whole packet. A unit the
  // container already states in full -- or states longer than a packet, or
  // states with no positive duration at all -- is left exactly as it is, so a
  // genuinely malformed grid still reaches the converter unchanged.
  {
    std::array<CMSampleTimingInfo, 3> timing{};
    for (auto& entry : timing) {
      entry.presentationTimeStamp = CMTimeMake(3'452'928, kRate);
      entry.decodeTimeStamp = kCMTimeInvalid;
    }
    timing[0].duration = CMTimeMake(kPacketFrames, kRate);
    timing[1].duration = CMTimeMake(2 * kPacketFrames, kRate);
    timing[2].duration = kCMTimeInvalid;
    const OwnedSample sample =
        makeCompressedAudioSample(format.get(), timing, timing.size(), 344);
    const std::size_t restated =
        restateCompressedAudioPacketDurationsForTesting(
            sample.get(), timing.data(), timing.size());
    expect(restated == 0, "a full or over-long access unit should not move");
    expect(isExactly(timing[0].duration, kPacketFrames) &&
               isExactly(timing[1].duration, 2 * kPacketFrames) &&
               !CMTIME_IS_NUMERIC(timing[2].duration),
           "non-truncated durations should survive byte-exactly");
  }

  // A zero duration states no extent at all rather than a trimmed one, so it
  // is never manufactured into a whole packet.
  {
    std::array<CMSampleTimingInfo, 1> timing{};
    timing[0].presentationTimeStamp = CMTimeMake(3'452'928, kRate);
    timing[0].decodeTimeStamp = kCMTimeInvalid;
    timing[0].duration = CMTimeMake(0, kRate);
    const OwnedSample sample =
        makeCompressedAudioSample(format.get(), timing, 1, 344);
    const std::size_t restated =
        restateCompressedAudioPacketDurationsForTesting(
            sample.get(), timing.data(), timing.size());
    expect(restated == 0 && timing[0].duration.value == 0,
           "a zero-duration entry should not be restated");
  }

  // Video is not on an audio packet grid; the rule must not touch it.
  {
    const OwnedFormat videoFormat = makeVideoFormat();
    std::array<CMSampleTimingInfo, 1> timing{};
    timing[0].presentationTimeStamp = CMTimeMake(1'024, 15'360);
    timing[0].decodeTimeStamp = kCMTimeInvalid;
    timing[0].duration = CMTimeMake(256, 15'360);
    const OwnedSample sample =
        makeSample(videoFormat.get(), timing[0].presentationTimeStamp,
                   kCMTimeInvalid, 4'096, 1, true, timing[0].duration);
    const std::size_t restated =
        restateCompressedAudioPacketDurationsForTesting(
            sample.get(), timing.data(), timing.size());
    expect(restated == 0 &&
               CMTimeCompare(timing[0].duration, CMTimeMake(256, 15'360)) == 0,
           "a video sample should never be restated on an audio packet grid");
  }

  // A null sample or a null timing array is inert rather than a fault.
  {
    std::array<CMSampleTimingInfo, 1> timing{};
    timing[0].duration = CMTimeMake(1'008, kRate);
    expect(restateCompressedAudioPacketDurationsForTesting(
               nullptr, timing.data(), timing.size()) == 0,
           "a null sample should restate nothing");
    const OwnedSample sample =
        makeCompressedAudioSample(format.get(), timing, 1, 344);
    expect(restateCompressedAudioPacketDurationsForTesting(sample.get(),
                                                           nullptr, 1) == 0,
           "a null timing array should restate nothing");
  }
}

int main(int argc, char** argv) {
  @autoreleasepool {
    const bool timingOnly =
        argc == 3 && std::string(argv[1]) == "--timing-only";
    if (timingOnly || argc == 2) {
      testRealDeferredFirstReadTiming(argv[timingOnly ? 2 : 1]);
    } else {
      expect(argc == 1,
             "AVFoundation media source test accepts a fixture or --timing-only fixture");
    }
    if (timingOnly) {
      if (failures != 0) {
        std::cerr << failures << " AVFoundation timing check(s) failed\n";
        return 1;
      }
      return 0;
    }
    testAccurateVideoUsesWholeExactInterval();
    testAccurateVideoRejectsInexactOrUnrepresentableIntervals();
    testAdmissionHeadsExactMergeAndEos();
    testAdmissionVideoHeadMustBeConsumerReady();
    testDemandDrivenRefillPreservesExactMergeAndCapacity();
    testDeferredRefillPreservesRuntimeDiscontinuityAndFailurePrecedence();
    testExactCancellationDuringDeferredRefill();
    testFormatlessDiscontinuityPrecedesImmutableFormatCheck();
    testMediaFreeMarkersAreDistinguishedFromDiscontinuities();
    testTruncatedFinalAudioPacketIsRestatedOnTheMediaGrid();
    testAdmissionDiscontinuityPrefixIsBounded();
    testExactCancellationWhileStartBlocks();
    testMetadataLoadsOverlapAndValidateInSourceOrder();
    testMetadataCancellationUsesExactWakeEdge();
    testSeekRecreatesOnceAndPreservesCoveringFrame();
    testSeekAdmissionRejectsNonKeyVideoHead();
    testSeekReusesExactImmutableAssetContext();
    testAssetContextIdentityFailsClosedBeforeAdmissionCopies();
    testSeekPublishesBeforePriorRetirement();
    testInitialPositionUsesOneReaderAndPreservesAudioPreroll();
    testPreEntryCancellationArm();
    testDescriptorExtractionAndBounds();
    testHevcDescriptorHardening();
    testImmutableVideoFormatIdentity();
    testImmutableAudioLayoutIdentity();
    testPreReaderSelectedFormatRebind();
    testWorkerExceptionsStayInsideSourceBoundary();
    testInjectedBackendCannotBypassLegacyAdmission();
    if (argc == 2) {
      testRealCompactAudioLayoutFixture(argv[1]);
      testRealSourceDrainsMarkerTailToExhaustion(argv[1]);
    }
  }
  if (failures != 0) {
    std::cerr << failures << " AVFoundation media source check(s) failed\n";
    return 1;
  }
  std::cout << "AVFoundation media source checks passed\n";
  return 0;
}
