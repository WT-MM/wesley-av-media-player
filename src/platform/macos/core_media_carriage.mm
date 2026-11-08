#include "platform/macos/core_media_carriage.hpp"

#include "media/media_codec_facts.hpp"
#include "platform/macos/core_media_codec_facts.hpp"
#include "platform/macos/native_video_codec_capability.hpp"
#include "platform/macos/native_video_color.hpp"
#include "platform/macos/software_vp8_decoder.hpp"

#import <CoreMedia/CoreMedia.h>

#include <limits>

namespace wam::macos {
namespace {

void assignNamedError(std::string* error, const char* name,
                      const char* message) {
  if (error != nullptr) {
    *error = std::string(name) + message;
  }
}

[[nodiscard]] bool machineAdmits(media::MediaCodec codec) noexcept {
  switch (codec) {
  case media::MediaCodec::Av1:
    return nativeVideoToolboxSupportsAv1();
  case media::MediaCodec::Vp9:
    return nativeVp9StageAdmitted();
  case media::MediaCodec::Vp8:
    // VP8 has no Apple decoder. The description exists only so the access
    // unit travels the same CMSampleBuffer carriage every other codec uses;
    // NativeVideoConsumer keys the libvpx stage on this four-character code
    // and VideoToolbox refuses it.
    return SoftwareVp8Decoder::available();
  default:
    return true;
  }
}

// Sets the two pixel-aspect spacing keys when the container states a
// non-square sample aspect, so the decoded surface and the window agree.
[[nodiscard]] bool applyPixelAspect(CFMutableDictionaryRef extensions,
                                    const media::MediaVideoFormat& video) {
  const std::int64_t horizontal = video.pixelAspectNumerator;
  const std::int64_t vertical = video.pixelAspectDenominator;
  if (horizontal == vertical) {
    return true;
  }
  CFNumberRef h =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &horizontal);
  CFNumberRef v =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &vertical);
  const void* keys[] = {kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing,
                        kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing};
  const void* values[] = {h, v};
  CFDictionaryRef aspect =
      h && v ? CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                  &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks)
             : nullptr;
  if (h) CFRelease(h);
  if (v) CFRelease(v);
  if (!aspect) {
    return false;
  }
  CFDictionarySetValue(extensions,
                       kCMFormatDescriptionExtension_PixelAspectRatio, aspect);
  CFRelease(aspect);
  return true;
}

}  // namespace

CMVideoFormatDescriptionRef createVideoFormatDescription(
    const media::MediaTrackDescriptor& track) noexcept {
  const media::MediaCodecFacts& facts = media::mediaCodecFacts(track.codec);
  if (!track.video || track.kind != media::MediaTrackKind::Video ||
      facts.kind != media::MediaCodecKind::Video || facts.coreMediaType == 0 ||
      track.codecConfigurationKind != facts.configurationKind ||
      !machineAdmits(track.codec)) {
    return nullptr;
  }
  const std::uint32_t width = track.video->codedWidth;
  const std::uint32_t height = track.video->codedHeight;
  const auto dimensionCeiling =
      static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max());
  if (width == 0 || height == 0 || width > dimensionCeiling ||
      height > dimensionCeiling) {
    return nullptr;
  }
  const CMVideoCodecType codec = coreMediaCodecType(track.codec);

  CMVideoFormatDescriptionRef description = nullptr;
  if (!facts.carriesConfigurationRecord) {
    // The sequence header is in band: the descriptor's empty record and a
    // null (not empty) extensions dictionary are the two halves of one fact.
    if (!track.codecConfiguration.empty()) {
      return nullptr;
    }
    const OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, codec, static_cast<std::int32_t>(width),
        static_cast<std::int32_t>(height), nullptr, &description);
    if (status != noErr && description != nullptr) {
      CFRelease(description);
      description = nullptr;
    }
    return status == noErr ? description : nullptr;
  }

  // VP8's record never reaches a decoder (the facts table states no atom for
  // it), but its vpcC rides along in the description unread, as it always has.
  const CFStringRef atomName = track.codec == media::MediaCodec::Vp8
                                   ? CFSTR("vpcC")
                                   : coreMediaConfigurationAtomName(track.codec);
  if (atomName == nullptr || track.codecConfiguration.empty() ||
      track.codecConfiguration.size() >
          static_cast<std::size_t>(std::numeric_limits<CFIndex>::max())) {
    return nullptr;
  }
  CFDataRef atomData = CFDataCreate(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8*>(track.codecConfiguration.data()),
      static_cast<CFIndex>(track.codecConfiguration.size()));
  if (atomData == nullptr) {
    return nullptr;
  }
  const void* atomKeys[] = {atomName};
  const void* atomValues[] = {atomData};
  CFDictionaryRef atoms = CFDictionaryCreate(
      kCFAllocatorDefault, atomKeys, atomValues, 1,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFMutableDictionaryRef extensions =
      atoms == nullptr ? nullptr
                       : CFDictionaryCreateMutable(
                             kCFAllocatorDefault, 4,
                             &kCFTypeDictionaryKeyCallBacks,
                             &kCFTypeDictionaryValueCallBacks);
  if (extensions != nullptr) {
    CFDictionarySetValue(
        extensions, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
        atoms);
    // Without the colour keys VideoToolbox has nothing to attach to the
    // decoded surface and a PQ stream renders as SDR. Each key is set only
    // when the fact is modelled; omitting it is how "untagged" is spelled.
    applyColorExtensions(extensions, track.video->colorPrimaries,
                         track.video->transferFunction,
                         track.video->matrixCoefficients);
    if (applyPixelAspect(extensions, *track.video)) {
      const OSStatus status = CMVideoFormatDescriptionCreate(
          kCFAllocatorDefault, codec, static_cast<std::int32_t>(width),
          static_cast<std::int32_t>(height), extensions, &description);
      if (status != noErr && description != nullptr) {
        CFRelease(description);
        description = nullptr;
      }
    }
    CFRelease(extensions);
  }
  if (atoms != nullptr) {
    CFRelease(atoms);
  }
  CFRelease(atomData);
  return description;
}

bool allocateSampleBlock(std::size_t bytes, const char* name,
                         CMBlockBufferRef* block,
                         std::span<std::byte>* destination,
                         std::string* error) {
  *block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, bytes, kCFAllocatorDefault, nullptr, 0,
      bytes, kCMBlockBufferAssureMemoryNowFlag, block);
  if (status != noErr || *block == nullptr) {
    if (*block != nullptr) {
      CFRelease(*block);
      *block = nullptr;
    }
    assignNamedError(error, name, " payload block allocation failed");
    return false;
  }
  std::size_t lengthAtOffset = 0;
  std::size_t totalLength = 0;
  char* raw = nullptr;
  status = CMBlockBufferGetDataPointer(*block, 0, &lengthAtOffset,
                                       &totalLength, &raw);
  if (status != noErr || raw == nullptr || lengthAtOffset < bytes) {
    CFRelease(*block);
    *block = nullptr;
    assignNamedError(error, name, " payload block is not contiguous");
    return false;
  }
  *destination =
      std::span<std::byte>(reinterpret_cast<std::byte*>(raw), bytes);
  return true;
}

bool buildCompressedSampleBuffer(CMBlockBufferRef block,
                                 CMFormatDescriptionRef format,
                                 const CompressedSampleShape& shape,
                                 const char* name, ScopedSampleBuffer* out,
                                 std::string* error) {
  CMSampleBufferRef created = nullptr;
  const OSStatus status =
      shape.packets != nullptr
          ? CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                kCFAllocatorDefault, block, format, shape.sampleCount,
                shape.timing.presentationTimeStamp, shape.packets, &created)
          : CMSampleBufferCreateReady(kCFAllocatorDefault, block, format,
                                      shape.sampleCount, 1, &shape.timing,
                                      shape.sizeEntryCount, shape.sizes,
                                      &created);
  CFRelease(block);
  if (status != noErr || created == nullptr) {
    if (created != nullptr) {
      CFRelease(created);
    }
    assignNamedError(error, name, " sample buffer creation failed");
    return false;
  }
  ScopedSampleBuffer owned(created);
  if (CMSampleBufferGetNumSamples(created) != shape.sampleCount ||
      !CMSampleBufferDataIsReady(created) || !CMSampleBufferIsValid(created)) {
    assignNamedError(error, name,
                     " sample buffer did not admit its access units");
    return false;
  }
  if (shape.videoKeyFrame) {
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(created, true);
    if (attachments == nullptr || CFArrayGetCount(attachments) != 1) {
      assignNamedError(error, name,
                       " video sample has no sync attachment slot");
      return false;
    }
    auto* attachment = static_cast<CFMutableDictionaryRef>(
        const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync,
                         *shape.videoKeyFrame ? kCFBooleanFalse
                                              : kCFBooleanTrue);
    if (*shape.videoKeyFrame) {
      CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers,
                           kCFBooleanFalse);
    }
  }
  *out = std::move(owned);
  return true;
}

}  // namespace wam::macos
