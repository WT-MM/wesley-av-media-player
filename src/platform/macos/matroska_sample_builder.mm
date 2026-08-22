#include "platform/macos/matroska_sample_builder.hpp"

#include "platform/macos/native_video_codec_capability.hpp"
#include "platform/macos/software_vp8_decoder.hpp"

#import <CoreMedia/CoreMedia.h>

#include <array>
#include <limits>
#include <numeric>

namespace wam::macos {
namespace {

using media::MediaCodec;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaCodecConfigurationKind;
using media::MediaTrackDescriptor;
using media::MediaTrackKind;
using media::matroska::MatroskaCompressedSample;
using media::matroska::MatroskaDemuxError;

constexpr std::size_t kMaximumLaceFrames{
    media::matroska::ParseOptions::kHardMaximumLaceFrames};

void assignError(std::string* error, const char* message) {
  if (error != nullptr) {
    *error = message;
  }
}

}  // namespace

MatroskaCoreMediaSampleStorage::MatroskaCoreMediaSampleStorage(
    CMSampleBufferRef ownedSample, std::size_t byteSize) noexcept
    : sample_(ownedSample), byte_size_(byteSize) {}

MatroskaCoreMediaSampleStorage::~MatroskaCoreMediaSampleStorage() {
  if (sample_ != nullptr) {
    CFRelease(sample_);
  }
}

std::size_t MatroskaCoreMediaSampleStorage::byteSize() const noexcept {
  return byte_size_;
}

std::span<const std::byte>
MatroskaCoreMediaSampleStorage::contiguousBytes() const noexcept {
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_);
  if (block == nullptr) {
    return {};
  }
  char* data = nullptr;
  std::size_t contiguousLength = 0;
  std::size_t totalLength = 0;
  const OSStatus status = CMBlockBufferGetDataPointer(
      block, 0, &contiguousLength, &totalLength, &data);
  if (status != noErr || data == nullptr || totalLength != byte_size_ ||
      contiguousLength != totalLength) {
    return {};
  }
  return {reinterpret_cast<const std::byte*>(data), totalLength};
}

bool MatroskaCoreMediaSampleStorage::copyBytes(
    std::size_t offset, std::span<std::byte> destination) const noexcept {
  if (offset > byte_size_ || destination.size() > byte_size_ - offset) {
    return false;
  }
  if (destination.empty()) {
    return true;
  }
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample_);
  return block != nullptr &&
         CMBlockBufferCopyDataBytes(block, offset, destination.size(),
                                    destination.data()) == noErr;
}

std::optional<media::NativePayloadKind>
MatroskaCoreMediaSampleStorage::nativePayloadKind() const noexcept {
  return media::NativePayloadKind::CoreMediaSampleBuffer;
}

const void* MatroskaCoreMediaSampleStorage::borrowedNativePayload()
    const noexcept {
  return sample_;
}

// Exact Matroska tick -> MediaTime. A tick is timestampScaleNanoseconds
// nanoseconds, so the reduced nanosecond rational is exact and never rounds
// through double the way a seconds conversion would.
std::optional<media::MediaTime> matroskaTickTime(
    std::int64_t tick, std::uint64_t timestampScaleNanoseconds) noexcept {
  if (timestampScaleNanoseconds == 0) {
    return std::nullopt;
  }
  constexpr std::int64_t kNanosecondsPerSecond{1'000'000'000};
  const auto scale =
      static_cast<__int128>(timestampScaleNanoseconds);
  const auto nanoseconds = static_cast<__int128>(tick) * scale;
  if (nanoseconds > static_cast<__int128>(
                        std::numeric_limits<std::int64_t>::max()) ||
      nanoseconds < static_cast<__int128>(
                        std::numeric_limits<std::int64_t>::min())) {
    return std::nullopt;
  }
  auto numerator = static_cast<std::int64_t>(nanoseconds);
  auto denominator = kNanosecondsPerSecond;
  const std::int64_t divisor =
      std::gcd(numerator == 0 ? denominator : numerator, denominator);
  if (divisor > 0) {
    numerator /= divisor;
    denominator /= divisor;
  }
  if (denominator <= 0 ||
      denominator > std::numeric_limits<std::int32_t>::max()) {
    return std::nullopt;
  }
  return media::MediaTime{numerator, static_cast<std::int32_t>(denominator)};
}

// Exact sum of two container rationals. The intermediate product needs the full
// 128-bit range: adjacent media ticks at a nanosecond timescale are already
// above 2^53, so converting through double would silently move a sample across
// the accurate-seek boundary. Copied verbatim from the AVFoundation backend so
// both sources answer decodeOnly identically for the same interval.
std::optional<media::MediaTime> matroskaCheckedExactTimeSum(
    MediaTime lhs, MediaTime rhs) noexcept {
  if (!lhs.valid() || !rhs.valid()) {
    return std::nullopt;
  }

  using WideSigned = __int128_t;
  using WideUnsigned = __uint128_t;
  const WideSigned numerator =
      static_cast<WideSigned>(lhs.value) *
          static_cast<WideSigned>(rhs.timescale) +
      static_cast<WideSigned>(rhs.value) *
          static_cast<WideSigned>(lhs.timescale);
  const std::uint64_t denominator =
      static_cast<std::uint64_t>(static_cast<std::uint32_t>(lhs.timescale)) *
      static_cast<std::uint64_t>(static_cast<std::uint32_t>(rhs.timescale));
  if (denominator == 0) {
    return std::nullopt;
  }

  const WideUnsigned magnitude =
      numerator < 0 ? static_cast<WideUnsigned>(-(numerator + 1)) + 1
                    : static_cast<WideUnsigned>(numerator);
  const std::uint64_t common = std::gcd(
      denominator, static_cast<std::uint64_t>(magnitude % denominator));
  const WideSigned reducedNumerator =
      numerator / static_cast<WideSigned>(common);
  const std::uint64_t reducedDenominator = denominator / common;
  if (reducedNumerator <
          static_cast<WideSigned>(std::numeric_limits<std::int64_t>::min()) ||
      reducedNumerator >
          static_cast<WideSigned>(std::numeric_limits<std::int64_t>::max()) ||
      reducedDenominator >
          static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  return media::MediaTime{static_cast<std::int64_t>(reducedNumerator),
                   static_cast<std::int32_t>(reducedDenominator)};
}

std::optional<bool> matroskaAccurateVideoDecodeOnly(
    MediaTime presentationTime, MediaTime duration, MediaTime target,
    std::string* error) noexcept {
  if (!presentationTime.valid() || !duration.valid() || duration.value <= 0) {
    assignError(error, "accurate video sample has no exact positive interval");
    return std::nullopt;
  }
  const auto intervalEnd =
      matroskaCheckedExactTimeSum(presentationTime, duration);
  if (!intervalEnd) {
    assignError(error,
                "accurate video sample interval is not exactly representable");
    return std::nullopt;
  }
  const auto endAgainstTarget = media::compareMediaTime(*intervalEnd, target);
  if (!endAgainstTarget) {
    assignError(error,
                "video sample interval and seek target have incomparable time");
    return std::nullopt;
  }
  return *endAgainstTarget != MediaTimeOrder::Greater;
}

const char* matroskaDemuxErrorName(MatroskaDemuxError error) noexcept {
  switch (error) {
  case MatroskaDemuxError::None:
    return "None";
  case MatroskaDemuxError::InvalidRequest:
    return "InvalidRequest";
  case MatroskaDemuxError::InvalidContainer:
    return "InvalidContainer";
  case MatroskaDemuxError::UnsupportedContainer:
    return "UnsupportedContainer";
  case MatroskaDemuxError::TrackSelection:
    return "TrackSelection";
  case MatroskaDemuxError::UnsupportedTrack:
    return "UnsupportedTrack";
  case MatroskaDemuxError::CodecConfiguration:
    return "CodecConfiguration";
  case MatroskaDemuxError::InvalidTimeline:
    return "InvalidTimeline";
  case MatroskaDemuxError::MissingCues:
    return "MissingCues";
  case MatroskaDemuxError::InvalidCue:
    return "InvalidCue";
  case MatroskaDemuxError::IndexLimit:
    return "IndexLimit";
  case MatroskaDemuxError::SampleLimit:
    return "SampleLimit";
  case MatroskaDemuxError::FileChanged:
    return "FileChanged";
  case MatroskaDemuxError::Io:
    return "Io";
  case MatroskaDemuxError::Cancelled:
    return "Cancelled";
  case MatroskaDemuxError::CodedDimensionLimit:
    return "CodedDimensionLimit";
  }
  return "Unknown";
}

std::string matroskaDemuxErrorMessage(const char* what,
                                      MatroskaDemuxError error) {
  std::string message(what);
  message += " (";
  message += matroskaDemuxErrorName(error);
  message += ")";
  return message;
}

CMVideoFormatDescriptionRef createMatroskaVideoFormatDescription(
    const MediaTrackDescriptor& track) noexcept {
  if (!track.video || track.kind != MediaTrackKind::Video ||
      track.codecConfiguration.empty() ||
      track.codecConfiguration.size() >
          static_cast<std::size_t>(std::numeric_limits<CFIndex>::max())) {
    return nullptr;
  }
  CMVideoCodecType codec = 0;
  CFStringRef atomName = nullptr;
  if (track.codec == MediaCodec::H264 &&
      track.codecConfigurationKind == MediaCodecConfigurationKind::AvcC) {
    codec = kCMVideoCodecType_H264;
    atomName = CFSTR("avcC");
  } else if (track.codec == MediaCodec::Hevc &&
             track.codecConfigurationKind ==
                 MediaCodecConfigurationKind::HvcC) {
    codec = kCMVideoCodecType_HEVC;
    atomName = CFSTR("hvcC");
  } else if (track.codec == MediaCodec::Av1 &&
             track.codecConfigurationKind ==
                 MediaCodecConfigurationKind::Av1C &&
             nativeVideoToolboxSupportsAv1()) {
    codec = kCMVideoCodecType_AV1;
    atomName = CFSTR("av1C");
  } else if (track.codec == MediaCodec::Vp9 &&
             track.codecConfigurationKind ==
                 MediaCodecConfigurationKind::VpcC &&
             nativeVideoToolboxSupportsVp9()) {
    // Matroska rarely carries VP9 CodecPrivate, so the demuxer synthesizes the
    // 12-byte vpcC from the keyframe bitstream. The non-empty guard above
    // therefore still holds for VP9, and the record is handed to CoreMedia
    // verbatim exactly like avcC/hvcC.
    codec = kCMVideoCodecType_VP9;
    atomName = CFSTR("vpcC");
  } else if (track.codec == MediaCodec::Vp8 &&
             track.codecConfigurationKind ==
                 MediaCodecConfigurationKind::VpcC &&
             SoftwareVp8Decoder::available()) {
    // VP8 has no CoreMedia codec type and no Apple decoder. This description
    // exists so the compressed access unit travels the same CMSampleBuffer
    // carriage every other codec uses; NativeVideoConsumer keys the libvpx
    // stage on exactly this four-character code, and VideoToolbox refuses it,
    // so the sample can never reach a decompression session. The 12-byte
    // vpcC the demuxer synthesized from the key frame rides along unread --
    // libvpx needs no configuration record at all.
    codec = kWamVideoCodecTypeVp8;
    atomName = CFSTR("vpcC");
  } else if (track.codec == MediaCodec::Mpeg4Visual &&
             track.codecConfigurationKind ==
                 MediaCodecConfigurationKind::CodecPrivate) {
    // MPEG-4 Part 2 Simple Profile. The demuxer already turned the Matroska
    // CodecPrivate headers into the ES_Descriptor CoreMedia demands, so the
    // record travels verbatim exactly like avcC and hvcC. Measured: the raw
    // headers in band, and an ES_Descriptor without the esds box's four
    // version/flags bytes, both fail VTDecompressionSessionCreate with
    // kVTVideoDecoderBadDataErr; this shape decodes.
    codec = kCMVideoCodecType_MPEG4Video;
    atomName = CFSTR("esds");
  } else {
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
  CFDictionaryRef extensions = nullptr;
  if (atoms != nullptr) {
    const void* extensionKeys[] = {
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms};
    const void* extensionValues[] = {atoms};
    extensions = CFDictionaryCreate(
        kCFAllocatorDefault, extensionKeys, extensionValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  }
  CMVideoFormatDescriptionRef description = nullptr;
  if (extensions != nullptr) {
    const OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, codec, static_cast<std::int32_t>(width),
        static_cast<std::int32_t>(height), extensions, &description);
    if (status != noErr && description != nullptr) {
      CFRelease(description);
      description = nullptr;
    }
    CFRelease(extensions);
  }
  if (atoms != nullptr) {
    CFRelease(atoms);
  }
  CFRelease(atomData);
  return description;
}

MatroskaSampleBuildStatus buildMatroskaCompressedSampleBuffer(
    const MatroskaSampleBuildInputs& inputs,
    const MatroskaCompressedSample& sample, MatroskaScopedSampleBuffer* out,
    std::string* error) {
  if (out == nullptr || inputs.asset == nullptr || inputs.format == nullptr) {
    assignError(error, "matroska sample factory has no admitted format");
    return MatroskaSampleBuildStatus::Failed;
  }
  const std::size_t bytes = sample.aggregateBytes;
  const std::size_t frameCount = sample.frameCount;
  if (bytes == 0 || frameCount == 0 || frameCount > kMaximumLaceFrames ||
      (inputs.video && frameCount != 1)) {
    assignError(error, "matroska sample has an inconsistent frame layout");
    return MatroskaSampleBuildStatus::Failed;
  }
  if (!inputs.video &&
      (inputs.audioSampleRate <= 0 || inputs.audioFramesPerPacket <= 0)) {
    assignError(error, "matroska audio sample has no exact packet grid");
    return MatroskaSampleBuildStatus::Failed;
  }

  // The CoreMedia block is allocated first and the demuxer writes payload
  // bytes straight into it. Staging through a reusable member vector and then
  // CMBlockBufferReplaceDataBytes moved every byte TWICE -- a copy this
  // project's own performance document had recorded as a single copy, which is
  // how a duplicated memcpy survives a careful review. The demuxer already
  // takes an exactly sized destination span and allocates nothing, so the
  // block's own memory is a legal destination and the scratch vector is gone.
  // kCMBlockBufferAssureMemoryNowFlag makes the backing store real before the
  // data pointer is taken.
  CMBlockBufferRef block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, bytes, kCFAllocatorDefault, nullptr, 0,
      bytes, kCMBlockBufferAssureMemoryNowFlag, &block);
  if (status != noErr || block == nullptr) {
    if (block != nullptr) {
      CFRelease(block);
    }
    assignError(error, "matroska payload block allocation failed");
    return MatroskaSampleBuildStatus::Failed;
  }
  std::size_t lengthAtOffset = 0;
  std::size_t totalLength = 0;
  char* raw = nullptr;
  status = CMBlockBufferGetDataPointer(block, 0, &lengthAtOffset, &totalLength,
                                       &raw);
  if (status != noErr || raw == nullptr || lengthAtOffset < bytes) {
    CFRelease(block);
    assignError(error, "matroska payload block is not contiguous");
    return MatroskaSampleBuildStatus::Failed;
  }
  const std::span<std::byte> destination(reinterpret_cast<std::byte*>(raw),
                                         bytes);
  MatroskaDemuxError copyError = MatroskaDemuxError::None;
  if (!inputs.asset->copyRanges({sample.frames.data(), frameCount}, destination,
                                inputs.cancellation, &copyError)) {
    // A failed or cancelled copy leaves a partially written block that no
    // caller ever sees; releasing it here is the whole cleanup.
    CFRelease(block);
    if (copyError == MatroskaDemuxError::Cancelled) {
      return MatroskaSampleBuildStatus::Cancelled;
    }
    if (error != nullptr) {
      *error =
          matroskaDemuxErrorMessage("matroska payload copy failed", copyError);
    }
    return MatroskaSampleBuildStatus::Failed;
  }

  CMSampleTimingInfo timing{};
  timing.presentationTimeStamp = CMTimeMake(sample.presentationTime.value,
                                            sample.presentationTime.timescale);
  timing.decodeTimeStamp = kCMTimeInvalid;
  if (inputs.video) {
    timing.duration = sample.duration.valid()
                          ? CMTimeMake(sample.duration.value,
                                       sample.duration.timescale)
                          : kCMTimeInvalid;
  } else {
    // One timing entry whose duration is a single access unit. CoreMedia then
    // derives each laced unit's own stamp, which is what the converter's
    // per-packet timeline walk validates against the packet frame counts.
    timing.duration =
        CMTimeMake(inputs.audioFramesPerPacket, inputs.audioSampleRate);
  }

  // Deliberately not value-initialised. This is kMaximumLaceFrames * 8 B of
  // stack (2 KiB) that a `{}` would zero on every single sample to describe a
  // Block carrying one frame (video) or a handful (laced AAC). Every entry
  // below frameCount is written before it is read -- video writes sizes[0],
  // audio writes exactly frameCount entries -- and CoreMedia is handed the
  // same frameCount as the entry count, so nothing ever reads past it.
  std::array<std::size_t, kMaximumLaceFrames> sizes;
  CMItemCount numSamples = 1;
  CMItemCount sizeEntries = 1;
  if (inputs.video) {
    sizes[0] = bytes;
  } else {
    std::size_t total = 0;
    for (std::size_t index = 0; index < frameCount; ++index) {
      const std::uint64_t frameBytes = sample.frames[index].bytes.size;
      if (frameBytes == 0 || frameBytes > bytes - total) {
        CFRelease(block);
        assignError(error, "matroska laced access unit sizes are inconsistent");
        return MatroskaSampleBuildStatus::Failed;
      }
      sizes[index] = static_cast<std::size_t>(frameBytes);
      total += sizes[index];
    }
    if (total != bytes) {
      CFRelease(block);
      assignError(error,
                  "matroska laced access units do not span the payload");
      return MatroskaSampleBuildStatus::Failed;
    }
    numSamples = static_cast<CMItemCount>(frameCount);
    sizeEntries = numSamples;
  }

  CMSampleBufferRef created = nullptr;
  status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, inputs.format,
                                     numSamples, 1, &timing, sizeEntries,
                                     sizes.data(), &created);
  CFRelease(block);
  if (status != noErr || created == nullptr) {
    if (created != nullptr) {
      CFRelease(created);
    }
    assignError(error, "matroska sample buffer creation failed");
    return MatroskaSampleBuildStatus::Failed;
  }
  MatroskaScopedSampleBuffer owned(created);
  if (CMSampleBufferGetNumSamples(created) != numSamples ||
      !CMSampleBufferDataIsReady(created) || !CMSampleBufferIsValid(created)) {
    assignError(error, "matroska sample buffer did not admit its access units");
    return MatroskaSampleBuildStatus::Failed;
  }

  if (inputs.video) {
    // Video only. The demuxer reports keyFrame == false for every AAC access
    // unit because Matroska states audio blocks that way by convention, not
    // because the unit depends on another one; marking audio NotSync would
    // publish a decode dependency the codec does not have. The audio
    // attachment array is therefore left exactly as CoreMedia created it,
    // apart from the one-shot playout proof the source states separately.
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(created, true);
    if (attachments == nullptr || CFArrayGetCount(attachments) != 1) {
      assignError(error, "matroska video sample has no sync attachment slot");
      return MatroskaSampleBuildStatus::Failed;
    }
    auto* attachment = static_cast<CFMutableDictionaryRef>(
        const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync,
                         sample.keyFrame ? kCFBooleanFalse : kCFBooleanTrue);
    if (sample.keyFrame) {
      CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers,
                           kCFBooleanFalse);
    }
  }

  *out = std::move(owned);
  return MatroskaSampleBuildStatus::Built;
}

}  // namespace wam::macos
