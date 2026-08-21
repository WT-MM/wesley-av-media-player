#include "platform/macos/mpegts_sample_builder.hpp"

#include "media/mpegts_packet.hpp"

#import <CoreMedia/CoreMedia.h>

#include <limits>
#include <numeric>

namespace wam::macos {
namespace {

using media::MediaCodec;
using media::MediaCodecConfigurationKind;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackKind;
using media::mpegts::Ac3SyncFrame;
using media::mpegts::AdtsHeader;
using media::mpegts::MpegAudioFrame;
using media::mpegts::MpegTsCompressedSample;
using media::mpegts::MpegTsDemuxError;

void assignError(std::string* error, const char* message) {
  if (error != nullptr) {
    *error = message;
  }
}

}  // namespace

MpegTsCoreMediaSampleStorage::MpegTsCoreMediaSampleStorage(
    CMSampleBufferRef ownedSample, std::size_t byteSize) noexcept
    : sample_(ownedSample), byte_size_(byteSize) {}

MpegTsCoreMediaSampleStorage::~MpegTsCoreMediaSampleStorage() {
  if (sample_ != nullptr) {
    CFRelease(sample_);
  }
}

std::size_t MpegTsCoreMediaSampleStorage::byteSize() const noexcept {
  return byte_size_;
}

std::span<const std::byte>
MpegTsCoreMediaSampleStorage::contiguousBytes() const noexcept {
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

bool MpegTsCoreMediaSampleStorage::copyBytes(
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
MpegTsCoreMediaSampleStorage::nativePayloadKind() const noexcept {
  return media::NativePayloadKind::CoreMediaSampleBuffer;
}

const void* MpegTsCoreMediaSampleStorage::borrowedNativePayload()
    const noexcept {
  return sample_;
}

std::optional<media::MediaTime> mpegTsCheckedExactTimeSum(
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
          static_cast<std::uint64_t>(
              std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  return media::MediaTime{static_cast<std::int64_t>(reducedNumerator),
                          static_cast<std::int32_t>(reducedDenominator)};
}

std::optional<bool> mpegTsAccurateVideoDecodeOnly(MediaTime presentationTime,
                                                  MediaTime duration,
                                                  MediaTime target,
                                                  std::string* error) noexcept {
  if (!presentationTime.valid() || !duration.valid() || duration.value <= 0) {
    assignError(error, "accurate video sample has no exact positive interval");
    return std::nullopt;
  }
  const auto intervalEnd = mpegTsCheckedExactTimeSum(presentationTime, duration);
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

const char* mpegTsDemuxErrorNameForMessage(MpegTsDemuxError error) noexcept {
  return media::mpegts::mpegTsDemuxErrorName(error);
}

std::string mpegTsDemuxErrorMessage(const char* what, MpegTsDemuxError error) {
  std::string message(what);
  message += " (";
  message += mpegTsDemuxErrorNameForMessage(error);
  message += ")";
  return message;
}

CMVideoFormatDescriptionRef createMpegTsVideoFormatDescription(
    const MediaTrackDescriptor& track) noexcept {
  if (!track.video || track.kind != MediaTrackKind::Video) {
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

  if (track.codec == MediaCodec::Mpeg2Video) {
    // The null extensions dictionary is the whole point: MPEG-2 carries its
    // sequence header in band and has no out-of-band record, so the descriptor
    // must state a None configuration kind and an empty configuration vector
    // for the two facts to agree.
    if (track.codecConfigurationKind != MediaCodecConfigurationKind::None ||
        !track.codecConfiguration.empty()) {
      return nullptr;
    }
    CMVideoFormatDescriptionRef description = nullptr;
    const OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, kCMVideoCodecType_MPEG2Video,
        static_cast<std::int32_t>(width), static_cast<std::int32_t>(height),
        nullptr, &description);
    if (status != noErr && description != nullptr) {
      CFRelease(description);
      description = nullptr;
    }
    return status == noErr ? description : nullptr;
  }

  if (track.codec != MediaCodec::H264 ||
      track.codecConfigurationKind != MediaCodecConfigurationKind::AvcC ||
      track.codecConfiguration.empty() ||
      track.codecConfiguration.size() >
          static_cast<std::size_t>(std::numeric_limits<CFIndex>::max())) {
    return nullptr;
  }

  // The record is handed to CoreMedia verbatim. Rewriting, reordering, or
  // re-emitting the atom would change bytes the decoder compares against the
  // description it was configured with.
  CFDataRef atomData = CFDataCreate(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8*>(track.codecConfiguration.data()),
      static_cast<CFIndex>(track.codecConfiguration.size()));
  if (atomData == nullptr) {
    return nullptr;
  }
  const void* atomKeys[] = {CFSTR("avcC")};
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
        kCFAllocatorDefault, kCMVideoCodecType_H264,
        static_cast<std::int32_t>(width), static_cast<std::int32_t>(height),
        extensions, &description);
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

bool layOutMpegTsAudioFrames(std::span<const std::byte> payload,
                             MediaCodec codec, std::uint32_t sampleRate,
                             std::uint32_t channels,
                             std::uint32_t framesPerPacket,
                             MpegTsAudioFrameLayout& layout,
                             std::string* error) noexcept {
  layout.reset();
  if (payload.empty() || sampleRate == 0 || channels == 0 ||
      framesPerPacket == 0) {
    assignError(error, "mpeg-ts audio payload has no admitted frame grid");
    return false;
  }
  std::size_t cursor = 0;
  while (cursor < payload.size()) {
    const std::span<const std::byte> rest = payload.subspan(cursor);
    std::uint32_t frameBytes = 0;
    std::uint32_t headerBytes = 0;
    std::uint32_t rate = 0;
    std::uint32_t frameChannels = 0;
    std::uint32_t decoded = 0;
    if (codec == MediaCodec::Aac) {
      AdtsHeader header{};
      if (!media::mpegts::parseAdtsHeader(rest, header)) {
        break;
      }
      frameBytes = header.frameBytes;
      // The ADTS header is stripped: the converter was configured from the
      // ES_Descriptor magic cookie the demuxer synthesized, and a cookie-bearing
      // AAC decoder expects raw access units, not re-framed ones.
      headerBytes = header.headerBytes;
      rate = header.sampleRate;
      frameChannels = header.channelConfiguration;
      decoded = framesPerPacket;
    } else if (codec == MediaCodec::Ac3 || codec == MediaCodec::Eac3) {
      Ac3SyncFrame frame{};
      if (!media::mpegts::parseAc3SyncFrame(rest, frame)) {
        break;
      }
      frameBytes = frame.frameBytes;
      headerBytes = 0;
      rate = frame.sampleRate;
      frameChannels =
          static_cast<std::uint32_t>(frame.channels) + (frame.lfe ? 1U : 0U);
      decoded = framesPerPacket;
    } else if (codec == MediaCodec::Mp3) {
      MpegAudioFrame frame{};
      if (!media::mpegts::parseMpegAudioFrame(rest, frame)) {
        break;
      }
      frameBytes = frame.frameBytes;
      headerBytes = 0;
      rate = frame.sampleRate;
      frameChannels = frame.channels;
      decoded = frame.samplesPerFrame;
    } else {
      assignError(error, "mpeg-ts audio codec has no admitted framing");
      return false;
    }

    if (frameBytes == 0 || frameBytes > rest.size() ||
        headerBytes >= frameBytes) {
      break;
    }
    // Every access unit in one generation must restate the SAME format. A
    // mid-stream rate or channel change is a format change this backend does
    // not implement, and letting one through would publish PCM the converter's
    // ASBD does not describe.
    if (rate != sampleRate || frameChannels != channels ||
        decoded != framesPerPacket) {
      assignError(error,
                  "mpeg-ts audio access unit changes its format mid-stream");
      return false;
    }
    if (layout.count >= kMaximumMpegTsAudioFrames) {
      assignError(error, "mpeg-ts PES carries more access units than admitted");
      return false;
    }
    layout.sourceOffset[layout.count] = static_cast<std::uint32_t>(cursor);
    layout.sourceSize[layout.count] = frameBytes;
    layout.outputSize[layout.count] = frameBytes - headerBytes;
    layout.outputBytes += frameBytes - headerBytes;
    layout.decodedFrames += framesPerPacket;
    ++layout.count;
    cursor += frameBytes;
  }
  if (layout.count == 0 || cursor != payload.size()) {
    // See the header: a trailing remainder is refused rather than dropped.
    assignError(error,
                "mpeg-ts audio PES does not divide into whole access units");
    layout.reset();
    return false;
  }
  return true;
}

namespace {

// Allocates one contiguous CoreMedia block and hands back its writable span.
[[nodiscard]] bool allocateBlock(std::size_t bytes, CMBlockBufferRef* block,
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
    assignError(error, "mpeg-ts payload block allocation failed");
    return false;
  }
  std::size_t lengthAtOffset = 0;
  std::size_t totalLength = 0;
  char* raw = nullptr;
  status =
      CMBlockBufferGetDataPointer(*block, 0, &lengthAtOffset, &totalLength, &raw);
  if (status != noErr || raw == nullptr || lengthAtOffset < bytes) {
    CFRelease(*block);
    *block = nullptr;
    assignError(error, "mpeg-ts payload block is not contiguous");
    return false;
  }
  *destination = std::span<std::byte>(reinterpret_cast<std::byte*>(raw), bytes);
  return true;
}

}  // namespace

MpegTsSampleBuildStatus buildMpegTsCompressedSampleBuffer(
    const MpegTsSampleBuildInputs& inputs, const MpegTsCompressedSample& sample,
    MpegTsScopedSampleBuffer* out, std::string* error) {
  if (out == nullptr || inputs.asset == nullptr || inputs.format == nullptr) {
    assignError(error, "mpeg-ts sample factory has no admitted format");
    return MpegTsSampleBuildStatus::Failed;
  }
  const std::size_t payloadBytes = sample.payloadBytes;
  if (payloadBytes == 0) {
    assignError(error, "mpeg-ts access unit is empty");
    return MpegTsSampleBuildStatus::Failed;
  }

  CMBlockBufferRef block = nullptr;
  std::span<std::byte> destination;
  std::size_t blockBytes = 0;
  CMItemCount numSamples = 1;
  CMItemCount sizeEntries = 1;
  std::array<std::size_t, 1> videoSizes{};
  const std::size_t* sizePointer = nullptr;

  if (inputs.video && inputs.codec == MediaCodec::H264) {
    // The one seam that costs an extra copy, recorded honestly. Annex-B to
    // AVCC cannot know its output size until the input is assembled -- a
    // three-byte start code grows by one byte and a four-byte one does not --
    // so the gather lands in a reusable workspace and the repack writes
    // straight into the CoreMedia block. That is two payload copies per video
    // sample against Matroska's one. The available optimization (when every
    // start code is four bytes the sizes are equal and the gather could go
    // straight into the block) is deliberately NOT taken here because it is
    // unmeasured, and this project's own performance record says page
    // residency moves this number 20x while staging shape moves it under 2x.
    if (inputs.workspace == nullptr) {
      assignError(error, "mpeg-ts video repack has no workspace");
      return MpegTsSampleBuildStatus::Failed;
    }
    std::vector<std::byte>& workspace = *inputs.workspace;
    if (workspace.size() < payloadBytes) {
      workspace.resize(payloadBytes);
    }
    const std::span<std::byte> gathered(workspace.data(), payloadBytes);
    MpegTsDemuxError copyError = MpegTsDemuxError::None;
    if (!inputs.asset->copyAccessUnit(sample, gathered, inputs.cancellation,
                                      &copyError)) {
      if (copyError == MpegTsDemuxError::Cancelled) {
        return MpegTsSampleBuildStatus::Cancelled;
      }
      if (error != nullptr) {
        *error = mpegTsDemuxErrorMessage("mpeg-ts payload gather failed",
                                         copyError);
      }
      return MpegTsSampleBuildStatus::Failed;
    }
    const std::size_t repacked =
        media::mpegts::annexBToAvccSize(gathered, MediaCodec::H264);
    if (repacked == 0) {
      assignError(error, "mpeg-ts access unit holds no complete NAL unit");
      return MpegTsSampleBuildStatus::Failed;
    }
    if (!allocateBlock(repacked, &block, &destination, error)) {
      return MpegTsSampleBuildStatus::Failed;
    }
    if (media::mpegts::annexBToAvcc(gathered, destination, MediaCodec::H264) !=
        repacked) {
      CFRelease(block);
      assignError(error, "mpeg-ts Annex-B to AVCC repack refused the unit");
      return MpegTsSampleBuildStatus::Failed;
    }
    blockBytes = repacked;
    videoSizes[0] = repacked;
    sizePointer = videoSizes.data();
  } else if (inputs.video) {
    // MPEG-2 needs no repack at all: the elementary stream bytes ARE what the
    // decoder wants, start codes included, so the gather goes straight into the
    // block and this path costs exactly one copy.
    if (!allocateBlock(payloadBytes, &block, &destination, error)) {
      return MpegTsSampleBuildStatus::Failed;
    }
    MpegTsDemuxError copyError = MpegTsDemuxError::None;
    if (!inputs.asset->copyAccessUnit(sample, destination, inputs.cancellation,
                                      &copyError)) {
      CFRelease(block);
      if (copyError == MpegTsDemuxError::Cancelled) {
        return MpegTsSampleBuildStatus::Cancelled;
      }
      if (error != nullptr) {
        *error = mpegTsDemuxErrorMessage("mpeg-ts payload gather failed",
                                         copyError);
      }
      return MpegTsSampleBuildStatus::Failed;
    }
    blockBytes = payloadBytes;
    videoSizes[0] = payloadBytes;
    sizePointer = videoSizes.data();
  } else {
    if (inputs.audioLayout == nullptr || inputs.workspace == nullptr) {
      assignError(error, "mpeg-ts audio framing has no workspace");
      return MpegTsSampleBuildStatus::Failed;
    }
    std::vector<std::byte>& workspace = *inputs.workspace;
    if (workspace.size() < payloadBytes) {
      workspace.resize(payloadBytes);
    }
    const std::span<std::byte> gathered(workspace.data(), payloadBytes);
    MpegTsDemuxError copyError = MpegTsDemuxError::None;
    if (!inputs.asset->copyAccessUnit(sample, gathered, inputs.cancellation,
                                      &copyError)) {
      if (copyError == MpegTsDemuxError::Cancelled) {
        return MpegTsSampleBuildStatus::Cancelled;
      }
      if (error != nullptr) {
        *error = mpegTsDemuxErrorMessage("mpeg-ts payload gather failed",
                                         copyError);
      }
      return MpegTsSampleBuildStatus::Failed;
    }
    MpegTsAudioFrameLayout& layout = *inputs.audioLayout;
    if (!layOutMpegTsAudioFrames(gathered, inputs.codec, inputs.audioSampleRate,
                                 inputs.audioChannels,
                                 inputs.audioFramesPerPacket, layout, error)) {
      return MpegTsSampleBuildStatus::Failed;
    }
    if (!allocateBlock(layout.outputBytes, &block, &destination, error)) {
      return MpegTsSampleBuildStatus::Failed;
    }
    std::size_t written = 0;
    for (std::size_t index = 0; index < layout.count; ++index) {
      const std::size_t skip =
          layout.sourceSize[index] - layout.outputSize[index];
      std::memcpy(destination.data() + written,
                  gathered.data() + layout.sourceOffset[index] + skip,
                  layout.outputSize[index]);
      written += layout.outputSize[index];
    }
    blockBytes = layout.outputBytes;
    numSamples = static_cast<CMItemCount>(layout.count);
    sizeEntries = numSamples;
    sizePointer = layout.outputSize.data();
  }

  CMSampleTimingInfo timing{};
  const MediaTime presentation =
      inputs.video ? sample.presentationTime : inputs.audioPresentationTime;
  if (!presentation.valid()) {
    CFRelease(block);
    assignError(error, "mpeg-ts sample has no exact presentation time");
    return MpegTsSampleBuildStatus::Failed;
  }
  timing.presentationTimeStamp =
      CMTimeMake(presentation.value, presentation.timescale);
  if (inputs.video) {
    // TS carries a REAL decode timestamp. Stating it is the whole difference
    // from the Matroska carriage, which must leave this invalid because
    // Matroska has no DTS and the demuxer refuses to invent one.
    timing.decodeTimeStamp =
        sample.decodeTime.valid()
            ? CMTimeMake(sample.decodeTime.value, sample.decodeTime.timescale)
            : kCMTimeInvalid;
    timing.duration = sample.duration.valid()
                          ? CMTimeMake(sample.duration.value,
                                       sample.duration.timescale)
                          : kCMTimeInvalid;
  } else {
    timing.decodeTimeStamp = kCMTimeInvalid;
    // One timing entry whose duration is a single access unit. CoreMedia then
    // derives each unit's own stamp, which is what the converter's per-packet
    // timeline walk validates against the packet frame counts.
    timing.duration =
        CMTimeMake(static_cast<std::int64_t>(inputs.audioFramesPerPacket),
                   static_cast<std::int32_t>(inputs.audioSampleRate));
  }

  CMSampleBufferRef created = nullptr;
  const OSStatus status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, inputs.format, numSamples, 1, &timing,
      sizeEntries, sizePointer, &created);
  CFRelease(block);
  if (status != noErr || created == nullptr) {
    if (created != nullptr) {
      CFRelease(created);
    }
    assignError(error, "mpeg-ts sample buffer creation failed");
    return MpegTsSampleBuildStatus::Failed;
  }
  MpegTsScopedSampleBuffer owned(created);
  if (CMSampleBufferGetNumSamples(created) != numSamples ||
      !CMSampleBufferDataIsReady(created) || !CMSampleBufferIsValid(created)) {
    assignError(error, "mpeg-ts sample buffer did not admit its access units");
    return MpegTsSampleBuildStatus::Failed;
  }
  static_cast<void>(blockBytes);

  if (inputs.video) {
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(created, true);
    if (attachments == nullptr || CFArrayGetCount(attachments) != 1) {
      assignError(error, "mpeg-ts video sample has no sync attachment slot");
      return MpegTsSampleBuildStatus::Failed;
    }
    auto* attachment = static_cast<CFMutableDictionaryRef>(
        const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
    // Transport Stream states no per-sample keyframe flag, so `keyFrame` here
    // is the demuxer's bitstream verdict corroborated by the adaptation field's
    // random_access_indicator -- not a container claim.
    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync,
                         sample.keyFrame ? kCFBooleanFalse : kCFBooleanTrue);
    if (sample.keyFrame) {
      CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers,
                           kCFBooleanFalse);
    }
  }

  *out = std::move(owned);
  return MpegTsSampleBuildStatus::Built;
}

}  // namespace wam::macos
