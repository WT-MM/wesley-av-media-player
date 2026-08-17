#include "platform/macos/matroska_media_source.hpp"

#include "platform/macos/native_video_codec_capability.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <numeric>
#include <optional>
#include <span>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace wam::macos {
namespace {

using media::MediaCodec;
using media::MediaCodecConfigurationKind;
using media::MediaGeneration;
using media::MediaPayloadLease;
using media::MediaPayloadStorage;
using media::MediaSample;
using media::MediaSampleKind;
using media::MediaSourceDescriptor;
using media::MediaSourceLimits;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackId;
using media::MediaTrackKind;
using media::matroska::CancellationToken;
using media::matroska::MatroskaCompressedSample;
using media::matroska::MatroskaCursor;
using media::matroska::MatroskaCursorCancelled;
using media::matroska::MatroskaCursorEnd;
using media::matroska::MatroskaCursorFailure;
using media::matroska::MatroskaDemuxError;
using media::matroska::MatroskaDemuxStatus;
using media::matroska::MatroskaGenerationPlan;
using media::matroska::MatroskaPreparedAsset;

constexpr std::size_t kMaximumLaceFrames{
    media::matroska::ParseOptions::kHardMaximumLaceFrames};

// Exact Matroska tick -> MediaTime. A tick is timestampScaleNanoseconds
// nanoseconds, so the reduced nanosecond rational is exact and never rounds
// through double the way a seconds conversion would.
[[nodiscard]] std::optional<MediaTime> matroskaTickTime(
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
  return MediaTime{numerator, static_cast<std::int32_t>(denominator)};
}

// Decoder preroll the audio converter demands ahead of the first audible frame
// of a generation that does not begin at the stream origin, stated in whole
// compressed access units. This is the same constant the AVFoundation backend
// uses and for the same reason: AAC-LC reconstructs each 1024-frame unit from
// its own spectral data plus the second half of the previous unit's MDCT
// window, so two decoded predecessors is the conventional full priming.
constexpr std::int64_t kAudioPrimingAccessUnits{2};
constexpr std::int64_t kMaximumAudioFramesPerPacket{65'536};

void assignError(std::string* error, const char* message) {
  if (error != nullptr) {
    *error = message;
  }
}

[[nodiscard]] std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
  return value == std::numeric_limits<std::uint64_t>::max() ? value
                                                            : value + 1;
}

[[nodiscard]] const char* matroskaErrorName(MatroskaDemuxError error) noexcept {
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
  }
  return "Unknown";
}

// The neutral header owns no FileChanged status, so a mid-stream identity
// change has to travel as a MediaSourceFailure. Naming the demuxer error inside
// the message keeps that fact recoverable by an owner that must distinguish a
// swapped file from an ordinary read error.
[[nodiscard]] std::string demuxErrorMessage(const char* what,
                                            MatroskaDemuxError error) {
  std::string message(what);
  message += " (";
  message += matroskaErrorName(error);
  message += ")";
  return message;
}

// Exact sum of two container rationals. The intermediate product needs the full
// 128-bit range: adjacent media ticks at a nanosecond timescale are already
// above 2^53, so converting through double would silently move a sample across
// the accurate-seek boundary. Copied verbatim from the AVFoundation backend so
// both sources answer decodeOnly identically for the same interval.
[[nodiscard]] std::optional<MediaTime> checkedExactTimeSum(
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
  return MediaTime{static_cast<std::int64_t>(reducedNumerator),
                   static_cast<std::int32_t>(reducedDenominator)};
}

[[nodiscard]] std::optional<bool> accurateVideoDecodeOnlyFacts(
    MediaTime presentationTime, MediaTime duration, MediaTime target,
    std::string* error) noexcept {
  if (!presentationTime.valid() || !duration.valid() || duration.value <= 0) {
    assignError(error, "accurate video sample has no exact positive interval");
    return std::nullopt;
  }
  const auto intervalEnd = checkedExactTimeSum(presentationTime, duration);
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

[[nodiscard]] bool exactNonnegativeTimeWithinDuration(
    MediaTime target, MediaTime duration) noexcept {
  if (!target.valid() || target.value < 0 || !duration.valid() ||
      duration.value < 0) {
    return false;
  }
  const auto order = media::compareMediaTime(target, duration);
  return order && *order != MediaTimeOrder::Greater;
}

// Exact integer sample rate of a selected audio track, or empty when the
// container declared a rate this backend cannot place on an integer PCM grid.
[[nodiscard]] std::optional<std::uint32_t> exactAudioSampleRate(
    const media::MediaAudioFormat& audio) noexcept {
  const double rate = audio.sampleRate;
  if (!std::isfinite(rate) || rate <= 0.0 ||
      rate > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  const auto integral = static_cast<std::uint32_t>(rate);
  if (static_cast<double>(integral) != rate || integral == 0) {
    return std::nullopt;
  }
  return integral;
}

class ScopedSampleBuffer final {
 public:
  ScopedSampleBuffer() noexcept = default;
  explicit ScopedSampleBuffer(CMSampleBufferRef owned) noexcept
      : value_(owned) {}
  ~ScopedSampleBuffer() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }

  ScopedSampleBuffer(ScopedSampleBuffer&& other) noexcept
      : value_(other.value_) {
    other.value_ = nullptr;
  }
  ScopedSampleBuffer& operator=(ScopedSampleBuffer&& other) noexcept {
    if (this != &other) {
      if (value_ != nullptr) {
        CFRelease(value_);
      }
      value_ = other.value_;
      other.value_ = nullptr;
    }
    return *this;
  }
  ScopedSampleBuffer(const ScopedSampleBuffer&) = delete;
  ScopedSampleBuffer& operator=(const ScopedSampleBuffer&) = delete;

  [[nodiscard]] CMSampleBufferRef get() const noexcept { return value_; }
  [[nodiscard]] CMSampleBufferRef release() noexcept {
    CMSampleBufferRef owned = value_;
    value_ = nullptr;
    return owned;
  }

 private:
  CMSampleBufferRef value_{nullptr};
};

// Owns the +1 on one retained CoreMedia buffer for the lifetime of every lease
// taken against it. Shape copied from the AVFoundation backend's storage so the
// native video consumer and audio converter accept Matroska samples unchanged.
class MatroskaCoreMediaSampleStorage final : public MediaPayloadStorage {
 public:
  MatroskaCoreMediaSampleStorage(CMSampleBufferRef ownedSample,
                                 std::size_t byteSize) noexcept
      : sample_(ownedSample), byte_size_(byteSize) {}
  ~MatroskaCoreMediaSampleStorage() override {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

  MatroskaCoreMediaSampleStorage(const MatroskaCoreMediaSampleStorage&) =
      delete;
  MatroskaCoreMediaSampleStorage& operator=(
      const MatroskaCoreMediaSampleStorage&) = delete;

  [[nodiscard]] std::size_t byteSize() const noexcept override {
    return byte_size_;
  }

  [[nodiscard]] std::span<const std::byte>
  contiguousBytes() const noexcept override {
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

  [[nodiscard]] bool copyBytes(
      std::size_t offset,
      std::span<std::byte> destination) const noexcept override {
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

 protected:
  [[nodiscard]] std::optional<media::NativePayloadKind>
  nativePayloadKind() const noexcept override {
    return media::NativePayloadKind::CoreMediaSampleBuffer;
  }
  [[nodiscard]] const void* borrowedNativePayload() const noexcept override {
    return sample_;
  }

 private:
  CMSampleBufferRef sample_{nullptr};
  std::size_t byte_size_{0};
};

// The decoder builds its own format description from exactly these inputs, so
// building this one identically is what lets VideoToolbox adopt the sample's
// description instead of rejecting a second, differently-encoded one. The
// configuration record is handed to CoreMedia verbatim: rewriting, reordering,
// or re-emitting an avcC/hvcC atom would change bytes the decoder compares.
[[nodiscard]] CMVideoFormatDescriptionRef
createVideoFormatDescription(const MediaTrackDescriptor& track) noexcept {
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

// The converter compares every ASBD field, the magic cookie bytes, and the
// channel layout tag against the admitted descriptor, so all three are restated
// from the descriptor rather than re-derived from the cookie.
[[nodiscard]] CMAudioFormatDescriptionRef
createAudioFormatDescription(const MediaTrackDescriptor& track) noexcept {
  if (!track.audio || track.kind != MediaTrackKind::Audio ||
      track.codecConfigurationKind !=
          MediaCodecConfigurationKind::AudioMagicCookie ||
      track.codecConfiguration.empty()) {
    return nullptr;
  }
  const media::MediaAudioFormat& audio = *track.audio;
  if (!exactAudioSampleRate(audio) || audio.channels == 0) {
    return nullptr;
  }
  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = audio.sampleRate;
  asbd.mFormatID = audio.formatTag;
  asbd.mFormatFlags = audio.formatFlags;
  asbd.mBytesPerPacket = audio.bytesPerPacket;
  asbd.mFramesPerPacket = audio.framesPerPacket;
  asbd.mBytesPerFrame = audio.bytesPerFrame;
  asbd.mChannelsPerFrame = audio.channels;
  asbd.mBitsPerChannel = audio.bitsPerChannel;

  // A tag-only layout is the exact shape the converter admits: no channel
  // descriptions, no bitmap, and the prefix length rather than the full struct.
  AudioChannelLayout layout{};
  layout.mChannelLayoutTag = audio.channelLayoutTag;
  const AudioChannelLayout* layoutPointer =
      audio.channelLayoutPresent ? &layout : nullptr;
  const std::size_t layoutSize =
      audio.channelLayoutPresent
          ? offsetof(AudioChannelLayout, mChannelDescriptions)
          : 0;

  CMAudioFormatDescriptionRef description = nullptr;
  const OSStatus status = CMAudioFormatDescriptionCreate(
      kCFAllocatorDefault, &asbd, layoutSize, layoutPointer,
      track.codecConfiguration.size(), track.codecConfiguration.data(), nullptr,
      &description);
  if (status != noErr && description != nullptr) {
    CFRelease(description);
    description = nullptr;
  }
  return status == noErr ? description : nullptr;
}

enum class SampleBuildStatus : std::uint8_t {
  Built,
  Cancelled,
  Failed,
};

struct SampleBuildInputs {
  const MatroskaPreparedAsset* asset{nullptr};
  CancellationToken cancellation{};
  CMFormatDescriptionRef format{nullptr};
  bool video{true};
  // Only meaningful for audio: the exact media-timeline extent of one access
  // unit, which CoreMedia expands into the per-unit stamps the converter reads.
  std::int64_t audioFramesPerPacket{0};
  std::int32_t audioSampleRate{0};
};

// Materializes one payload-free cursor sample into a retained CMSampleBuffer.
//
// Timing is the load-bearing decision here. Container rationals are carried
// straight into CMTimeMake as {value, timescale}; converting through seconds
// would reintroduce exactly the rounding the demuxer was built to avoid. The
// decode stamp is always invalid because Matroska carries no DTS and the
// demuxer refuses to invent one - VideoToolbox then decodes in submission
// order, which is the storage order the cursor emits in.
[[nodiscard]] SampleBuildStatus buildCompressedSampleBuffer(
    const SampleBuildInputs& inputs, const MatroskaCompressedSample& sample,
    ScopedSampleBuffer* out,
    std::string* error) {
  if (out == nullptr || inputs.asset == nullptr || inputs.format == nullptr) {
    assignError(error, "matroska sample factory has no admitted format");
    return SampleBuildStatus::Failed;
  }
  const std::size_t bytes = sample.aggregateBytes;
  const std::size_t frameCount = sample.frameCount;
  if (bytes == 0 || frameCount == 0 || frameCount > kMaximumLaceFrames ||
      (inputs.video && frameCount != 1)) {
    assignError(error, "matroska sample has an inconsistent frame layout");
    return SampleBuildStatus::Failed;
  }
  if (!inputs.video &&
      (inputs.audioSampleRate <= 0 || inputs.audioFramesPerPacket <= 0)) {
    assignError(error, "matroska audio sample has no exact packet grid");
    return SampleBuildStatus::Failed;
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
    return SampleBuildStatus::Failed;
  }
  std::size_t lengthAtOffset = 0;
  std::size_t totalLength = 0;
  char* raw = nullptr;
  status = CMBlockBufferGetDataPointer(block, 0, &lengthAtOffset, &totalLength,
                                       &raw);
  if (status != noErr || raw == nullptr || lengthAtOffset < bytes) {
    CFRelease(block);
    assignError(error, "matroska payload block is not contiguous");
    return SampleBuildStatus::Failed;
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
      return SampleBuildStatus::Cancelled;
    }
    if (error != nullptr) {
      *error = demuxErrorMessage("matroska payload copy failed", copyError);
    }
    return SampleBuildStatus::Failed;
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
        return SampleBuildStatus::Failed;
      }
      sizes[index] = static_cast<std::size_t>(frameBytes);
      total += sizes[index];
    }
    if (total != bytes) {
      CFRelease(block);
      assignError(error,
                  "matroska laced access units do not span the payload");
      return SampleBuildStatus::Failed;
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
    return SampleBuildStatus::Failed;
  }
  ScopedSampleBuffer owned(created);
  if (CMSampleBufferGetNumSamples(created) != numSamples ||
      !CMSampleBufferDataIsReady(created) || !CMSampleBufferIsValid(created)) {
    assignError(error, "matroska sample buffer did not admit its access units");
    return SampleBuildStatus::Failed;
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
      return SampleBuildStatus::Failed;
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
  return SampleBuildStatus::Built;
}

// States the ImmediatePlayoutFrame proof the converter requires before it will
// admit a generation that does not begin at the stream origin. AVFoundation
// never states the attachment for AAC-LC and neither does CoreMedia for a
// buffer this backend assembles, so the source states it itself - and only
// after measuring that it is true.
[[nodiscard]] bool statedImmediatePlayoutFrame(
    CMSampleBufferRef sample) noexcept {
  if (sample == nullptr || CMSampleBufferGetNumSamples(sample) <= 0) {
    return false;
  }
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, true);
  if (attachments == nullptr || CFArrayGetCount(attachments) <= 0) {
    return false;
  }
  CFTypeRef entry = CFArrayGetValueAtIndex(attachments, 0);
  if (entry == nullptr || CFGetTypeID(entry) != CFDictionaryGetTypeID()) {
    return false;
  }
  const std::int64_t refreshCount = 0;
  CFNumberRef value =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &refreshCount);
  if (value == nullptr) {
    return false;
  }
  CFDictionarySetValue(
      static_cast<CFMutableDictionaryRef>(const_cast<void*>(entry)),
      kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount, value);
  CFRelease(value);
  return true;
}

struct StagedSample {
  MediaTrackId track{0};
  MediaTime orderTime{};
  MediaSample value;
  std::size_t payloadBytes{0};
};

struct GenerationStart {
  media::MediaSourceOpenStatus status{media::MediaSourceOpenStatus::Failed};
  MediaTime actualDecodeStart{};
  std::shared_ptr<const MediaSourceDescriptor> descriptor;
  std::shared_ptr<const MatroskaAssetContext> context;
  media::MediaAudioGenerationWindow audioWindow{};
  std::string error;
};

}  // namespace

struct MatroskaMediaSource::Impl {
  Impl() = default;
  ~Impl() { releaseFormats(); }

  Impl(const Impl&) = delete;
  Impl& operator=(const Impl&) = delete;

  std::filesystem::path path;
  media::MediaSourceOpenOptions options;
  MediaSourceLimits limits;
  std::shared_ptr<const MediaSourceDescriptor> descriptor;
  std::shared_ptr<const MatroskaAssetContext> assetContext;
  std::unique_ptr<MatroskaCursor> videoCursor;
  std::unique_ptr<MatroskaCursor> audioCursor;
  CMVideoFormatDescriptionRef videoFormat{nullptr};
  CMAudioFormatDescriptionRef audioFormat{nullptr};
  std::optional<StagedSample> videoHead;
  std::optional<StagedSample> audioHead;
  std::optional<MediaTime> requestedTarget;
  media::MediaSeekMode seekMode{media::MediaSeekMode::Accurate};
  std::string failure;
  MediaGeneration generation{0};
  MediaGeneration armedGeneration{0};
  bool open{false};
  bool videoTerminal{true};
  bool audioTerminal{true};
  bool videoRefillPending{false};
  bool audioRefillPending{false};
  bool videoEosEmitted{false};
  bool audioEosEmitted{false};
  // One-shot latch per generation: the converter reads the playout proof from
  // the first access unit it ever sees and never looks again.
  bool audioProofStated{false};
  std::optional<MediaTime> audioProofCeiling;
  MediaTime audioDecodeStart{};
  std::int64_t audioFramesPerPacket{0};
  std::int32_t audioSampleRate{0};

  std::atomic<MediaGeneration> operationGeneration{0};
  std::atomic<MediaGeneration> cancelledGeneration{0};
  std::atomic<MediaGeneration> generationHighWater{0};
  std::atomic<MediaGeneration> stagedGeneration{0};
  std::atomic<std::size_t> stagedVideoHeads{0};
  std::atomic<std::size_t> stagedAudioHeads{0};
  std::atomic<std::size_t> stagedPayloadBytes{0};
  std::atomic<std::size_t> peakStagedPayloadBytes{0};
  std::atomic<std::uint64_t> samplesEmitted{0};
  std::atomic<std::uint64_t> seeksAccepted{0};
  std::atomic<bool> openSnapshot{false};

  // ---- generation algebra -------------------------------------------------

  [[nodiscard]] bool arm(MediaGeneration requested) noexcept {
    if (requested == 0 || armedGeneration != 0) {
      return false;
    }
    MediaGeneration observed =
        generationHighWater.load(std::memory_order_acquire);
    while (observed < requested) {
      if (generationHighWater.compare_exchange_weak(
              observed, requested, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        cancelledGeneration.store(0, std::memory_order_release);
        armedGeneration = requested;
        operationGeneration.store(requested, std::memory_order_release);
        return true;
      }
    }
    return false;
  }

  [[nodiscard]] bool consumeArm(MediaGeneration requested) noexcept {
    if (armedGeneration != requested ||
        operationGeneration.load(std::memory_order_acquire) != requested) {
      return false;
    }
    armedGeneration = 0;
    return true;
  }

  [[nodiscard]] bool operationCancelled(
      MediaGeneration requested) const noexcept {
    return requested != 0 &&
           cancelledGeneration.load(std::memory_order_acquire) == requested;
  }

  void restoreCurrentPublicationAfterRejectedOperation() noexcept {
    operationGeneration.store(open ? generation : 0, std::memory_order_release);
  }

  [[nodiscard]] bool isCancelled() const noexcept {
    return cancelledGeneration.load(std::memory_order_acquire) == generation &&
           generation != 0;
  }

  void publishCancellation(MediaGeneration requested) noexcept {
    if (requested == 0 ||
        operationGeneration.load(std::memory_order_acquire) != requested) {
      return;
    }
    MediaGeneration observed =
        cancelledGeneration.load(std::memory_order_relaxed);
    while (observed < requested &&
           !cancelledGeneration.compare_exchange_weak(
               observed, requested, std::memory_order_release,
               std::memory_order_relaxed)) {
    }
  }

  // The demuxer's cancellation seam is a POD probe rather than an object, so
  // the source's own latch is what every plan, cursor read, and payload copy
  // observes. Only the owner thread dereferences the context.
  [[nodiscard]] static bool cancellationProbe(const void* context) noexcept {
    const auto* impl = static_cast<const Impl*>(context);
    return impl != nullptr && impl->isCancelled();
  }

  [[nodiscard]] CancellationToken cancellation() const noexcept {
    return CancellationToken{this, &Impl::cancellationProbe};
  }

  // ---- staged-head accounting --------------------------------------------

  void updatePeak(std::size_t total) noexcept {
    std::size_t peak = peakStagedPayloadBytes.load(std::memory_order_relaxed);
    while (peak < total && !peakStagedPayloadBytes.compare_exchange_weak(
                               peak, total, std::memory_order_relaxed,
                               std::memory_order_relaxed)) {
    }
  }

  void publishHeadFacts() noexcept {
    const std::size_t videoCount = videoHead ? 1 : 0;
    const std::size_t audioCount = audioHead ? 1 : 0;
    const std::size_t videoBytes = videoHead ? videoHead->payloadBytes : 0;
    const std::size_t audioBytes = audioHead ? audioHead->payloadBytes : 0;
    const std::size_t total = videoBytes + audioBytes;
    stagedVideoHeads.store(videoCount, std::memory_order_relaxed);
    stagedAudioHeads.store(audioCount, std::memory_order_relaxed);
    stagedPayloadBytes.store(total, std::memory_order_relaxed);
    updatePeak(total);
    stagedGeneration.store(videoCount + audioCount == 0 ? 0 : generation,
                           std::memory_order_release);
  }

  void clearHead(std::optional<StagedSample>& head) noexcept {
    head.reset();
    publishHeadFacts();
  }

  void clearHeads() noexcept {
    videoHead.reset();
    audioHead.reset();
    videoRefillPending = false;
    audioRefillPending = false;
    publishHeadFacts();
  }

  void releaseFormats() noexcept {
    if (videoFormat != nullptr) {
      CFRelease(videoFormat);
      videoFormat = nullptr;
    }
    if (audioFormat != nullptr) {
      CFRelease(audioFormat);
      audioFormat = nullptr;
    }
  }

  void retireActive() noexcept {
    videoCursor.reset();
    audioCursor.reset();
    releaseFormats();
  }

  void withdrawFailedOperation() noexcept {
    operationGeneration.store(0, std::memory_order_release);
    retireActive();
    clearHeads();
    descriptor.reset();
    assetContext.reset();
    open = false;
    openSnapshot.store(false, std::memory_order_release);
  }

  // ---- staging ------------------------------------------------------------

  [[nodiscard]] std::optional<StagedSample> makeHead(
      const MatroskaCompressedSample& raw, bool video, std::string* error) {
    const std::optional<MediaTrackId> selected =
        video ? descriptor->selectedVideo : descriptor->selectedAudio;
    const MediaSampleKind kind = video ? MediaSampleKind::EncodedVideo
                                       : MediaSampleKind::EncodedAudio;
    if (!selected || raw.track != *selected || raw.kind != kind) {
      assignError(error, "matroska cursor emitted an unselected track");
      return std::nullopt;
    }
    const MediaTrackDescriptor* track =
        media::findMediaTrack(*descriptor, *selected);
    if (track == nullptr) {
      assignError(error, "matroska sample refers to an unknown track");
      return std::nullopt;
    }
    if (!raw.presentationTime.valid() || raw.presentationTime.value < 0 ||
        (raw.duration.valid() && raw.duration.value < 0)) {
      assignError(error, "matroska sample has no exact nonnegative timing");
      return std::nullopt;
    }
    // The demuxer never invents a decode timestamp; a cursor that produced one
    // would mean this source is reading a container it does not understand.
    if (raw.decodeTime.valid()) {
      assignError(error, "matroska sample fabricated a decode timestamp");
      return std::nullopt;
    }
    const std::size_t bytes = raw.aggregateBytes;
    const std::size_t frameCount = raw.frameCount;
    if (bytes == 0 || frameCount == 0 ||
        (video && (frameCount != 1 || bytes > limits.maximumVideoSampleBytes)) ||
        (!video && (frameCount > limits.maximumAudioSampleCount ||
                    frameCount > kMaximumLaceFrames ||
                    bytes > limits.maximumAudioSampleBytes))) {
      assignError(error, "matroska sample exceeds native memory bounds");
      return std::nullopt;
    }

    SampleBuildInputs inputs;
    inputs.asset = assetContext->asset().get();
    inputs.cancellation = cancellation();
    inputs.format = video ? static_cast<CMFormatDescriptionRef>(videoFormat)
                          : static_cast<CMFormatDescriptionRef>(audioFormat);
    inputs.video = video;
    inputs.audioFramesPerPacket = audioFramesPerPacket;
    inputs.audioSampleRate = audioSampleRate;
    ScopedSampleBuffer owned;
    const SampleBuildStatus built =
        buildCompressedSampleBuffer(inputs, raw, &owned, error);
    if (built != SampleBuildStatus::Built) {
      if (built == SampleBuildStatus::Cancelled) {
        publishCancellation(generation);
        assignError(error, "matroska payload copy was cancelled");
      }
      return std::nullopt;
    }

    if (!video && !audioProofStated) {
      audioProofStated = true;
      // Measured, never assumed: the attachment asserts that the decoder has
      // already consumed the full priming window ahead of the first audible
      // frame. An unproved unit is left untouched on purpose so the converter
      // rejects the generation instead of publishing un-primed PCM.
      if (audioProofCeiling) {
        const auto order = media::compareMediaTime(raw.presentationTime,
                                                   *audioProofCeiling);
        if (order && *order != MediaTimeOrder::Greater) {
          static_cast<void>(statedImmediatePlayoutFrame(owned.get()));
        }
      }
    }

    const std::size_t sampleCount = video ? 1 : frameCount;
    auto storage = std::make_shared<MatroskaCoreMediaSampleStorage>(
        owned.release(), bytes);
    MediaSample sample;
    sample.generation = generation;
    sample.track = *selected;
    sample.kind = kind;
    sample.presentationTime = raw.presentationTime;
    // Left invalid on purpose. Fabricating a decode stamp here would be the
    // one lie that makes every downstream timeline check meaningless.
    sample.decodeTime = MediaTime{};
    sample.duration = raw.duration;
    sample.keyFrame = raw.keyFrame;
    sample.sampleCount = static_cast<std::uint32_t>(sampleCount);
    sample.payload = MediaPayloadLease(std::move(storage));
    if (video && requestedTarget &&
        seekMode == media::MediaSeekMode::Accurate) {
      const auto decodeOnly = accurateVideoDecodeOnlyFacts(
          raw.presentationTime, raw.duration, *requestedTarget, error);
      if (!decodeOnly) {
        return std::nullopt;
      }
      sample.decodeOnly = *decodeOnly;
    }
    if (!media::validateMediaSample(sample, *descriptor, limits, error)) {
      return std::nullopt;
    }
    // Matroska cursors emit in storage order, which is decode order, and never
    // produce a payload-free marker, so the merge key is simply the exact
    // presentation time. Video wins ties because no DTS exists to break them.
    return StagedSample{*selected, raw.presentationTime, std::move(sample),
                        bytes};
  }

  [[nodiscard]] bool stage(bool video, bool admission, std::string* error) {
    const std::optional<MediaTrackId> selected =
        video ? descriptor->selectedVideo : descriptor->selectedAudio;
    MatroskaCursor* cursor =
        video ? videoCursor.get() : audioCursor.get();
    if (!selected) {
      (video ? videoTerminal : audioTerminal) = true;
      return true;
    }
    if (cursor == nullptr) {
      assignError(error, "selected matroska output has no cursor");
      return false;
    }
    const media::matroska::MatroskaCursorReadResult result =
        cursor->readNext(cancellation());
    if (std::holds_alternative<MatroskaCursorCancelled>(result) ||
        isCancelled()) {
      publishCancellation(generation);
      assignError(error, "matroska generation was cancelled");
      return false;
    }
    if (const auto* failed = std::get_if<MatroskaCursorFailure>(&result)) {
      if (error != nullptr) {
        *error = demuxErrorMessage(failed->message.empty()
                                       ? "matroska cursor read failed"
                                       : failed->message.c_str(),
                                   failed->error);
      }
      return false;
    }
    if (std::holds_alternative<MatroskaCursorEnd>(result)) {
      (video ? videoTerminal : audioTerminal) = true;
      if (admission) {
        assignError(error, "selected matroska output has no admission sample");
        return false;
      }
      return true;
    }
    auto head =
        makeHead(std::get<MatroskaCompressedSample>(result), video, error);
    if (!head) {
      return false;
    }
    if (admission && video) {
      // The plan always starts video at a random access point; restating it
      // here keeps a malformed Cue from admitting a generation that can never
      // decode. A positive duration is required because every downstream video
      // consumer compares the sample's exact interval against the timeline.
      if (!head->value.keyFrame || head->value.presentationTime.value < 0 ||
          !head->value.duration.valid() || head->value.duration.value <= 0) {
        assignError(error,
                    "first video sample is not a nonnegative positive-duration "
                    "sync access unit");
        return false;
      }
    }
    if (admission && !video) {
      // The neutral window states that decodeStart is the timestamp of the
      // first staged compressed access unit. Prove it rather than trust it: a
      // window that disagrees with the bytes would make every converter trim
      // decision wrong by a whole access unit.
      if (!audioDecodeStart.valid() ||
          head->value.presentationTime != audioDecodeStart) {
        assignError(error,
                    "first staged audio access unit does not begin at the "
                    "planned audio window decode start");
        return false;
      }
    }
    (video ? videoHead : audioHead) = std::move(head);
    publishHeadFacts();
    return true;
  }

  [[nodiscard]] bool refillPendingLane(bool video, std::string* error) {
    bool& pending = video ? videoRefillPending : audioRefillPending;
    std::optional<StagedSample>& head = video ? videoHead : audioHead;
    const bool terminal = video ? videoTerminal : audioTerminal;
    if (!pending) {
      return true;
    }
    // Consume the demand edge before entering the demuxer. A read failure is
    // sticky and must not turn later readNext() calls into implicit retries.
    pending = false;
    if (head || terminal) {
      return true;
    }
    return stage(video, false, error);
  }

  [[nodiscard]] bool refillPendingHeads(std::string* error) {
    return refillPendingLane(true, error) && refillPendingLane(false, error);
  }

  // ---- generation start ---------------------------------------------------

  [[nodiscard]] bool prepareAudioFacts(const MatroskaGenerationPlan& plan,
                                       std::string* error) {
    audioProofStated = false;
    audioProofCeiling.reset();
    audioDecodeStart = MediaTime{};
    audioFramesPerPacket = 0;
    audioSampleRate = 0;
    if (!descriptor->selectedAudio) {
      return true;
    }
    const MediaTrackDescriptor* track =
        media::findMediaTrack(*descriptor, *descriptor->selectedAudio);
    if (track == nullptr || !track->audio) {
      assignError(error, "selected matroska audio track has no format");
      return false;
    }
    const auto rate = exactAudioSampleRate(*track->audio);
    const auto framesPerPacket =
        static_cast<std::int64_t>(track->audio->framesPerPacket);
    if (!rate || framesPerPacket <= 0 ||
        framesPerPacket > kMaximumAudioFramesPerPacket) {
      assignError(error, "matroska audio has no exact integer packet grid");
      return false;
    }
    audioSampleRate = static_cast<std::int32_t>(*rate);
    audioFramesPerPacket = framesPerPacket;
    audioDecodeStart = plan.audioWindow.decodeStart;
    if (!audioDecodeStart.valid() ||
        !plan.audioWindow.presentationStart.valid()) {
      assignError(error, "matroska plan produced no exact audio window");
      return false;
    }
    if (plan.audioWindow.startsAtStreamOrigin) {
      // A generation that begins at the stream origin needs no proof: there is
      // no earlier audio the decoder could have been missing.
      return true;
    }
    const auto presentationFrame = media::exactAudioFrameIndex(
        plan.audioWindow.presentationStart, *rate);
    if (!presentationFrame || *presentationFrame < 0) {
      assignError(error,
                  "matroska audio presentation start is off the frame grid");
      return false;
    }
    const std::int64_t ceilingFrame = std::max<std::int64_t>(
        *presentationFrame - kAudioPrimingAccessUnits * framesPerPacket, 0);
    audioProofCeiling = MediaTime{ceilingFrame, audioSampleRate};
    return true;
  }

  [[nodiscard]] GenerationStart begin(
      const std::filesystem::path& requestedPath,
      const media::MediaSourceOpenOptions& requestedOptions,
      MediaGeneration requestedGeneration,
      const std::optional<MediaTime>& target, media::MediaSeekMode mode,
      const std::shared_ptr<const MatroskaAssetContext>& existingContext) {
    GenerationStart started;
    generation = requestedGeneration;
    limits = media::clampMediaSourceLimits(requestedOptions.limits);
    requestedTarget = target;
    seekMode = mode;

    // armOperation() already published this exact cancellation slot before an
    // outer owner could expose the operation. Never clear that latch here.
    if (isCancelled()) {
      started.status = media::MediaSourceOpenStatus::Cancelled;
      withdrawFailedOperation();
      return started;
    }
    retireActive();

    videoTerminal = false;
    audioTerminal = false;
    videoRefillPending = false;
    audioRefillPending = false;
    videoEosEmitted = false;
    audioEosEmitted = false;
    failure.clear();
    clearHeads();
    descriptor.reset();
    assetContext.reset();
    open = false;
    openSnapshot.store(false, std::memory_order_release);

    if (isCancelled()) {
      started.status = media::MediaSourceOpenStatus::Cancelled;
      withdrawFailedOperation();
      return started;
    }

    // A seek reuses the exact asset admitted by open. Only a cold open pays for
    // container parsing, and only a cold open may produce a new context.
    std::shared_ptr<const MatroskaAssetContext> context = existingContext;
    if (context == nullptr) {
      const media::matroska::MatroskaPrepareOutcome prepared =
          media::matroska::prepareMatroskaLocalFile(requestedPath,
                                                    requestedOptions,
                                                    cancellation());
      switch (prepared.status) {
      case MatroskaDemuxStatus::Ready:
        started.status = media::MediaSourceOpenStatus::Ready;
        break;
      case MatroskaDemuxStatus::Unsupported:
        started.status = media::MediaSourceOpenStatus::Unsupported;
        break;
      case MatroskaDemuxStatus::Cancelled:
        started.status = media::MediaSourceOpenStatus::Cancelled;
        break;
      case MatroskaDemuxStatus::Failed:
        started.status = media::MediaSourceOpenStatus::Failed;
        break;
      }
      if (prepared.status != MatroskaDemuxStatus::Ready ||
          prepared.asset == nullptr) {
        started.error = demuxErrorMessage(
            prepared.message.empty() ? "matroska preparation failed"
                                     : prepared.message.c_str(),
            prepared.error);
        if (prepared.status == MatroskaDemuxStatus::Ready) {
          started.status = media::MediaSourceOpenStatus::Failed;
        }
        withdrawFailedOperation();
        return started;
      }
      context = adoptPreparedMatroskaAssetContext(
          requestedPath, requestedOptions, prepared.asset);
      if (context == nullptr ||
          !context->matchesMainRequest(requestedPath, requestedOptions,
                                       prepared.asset->descriptor())) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error = "matroska asset context did not admit its own identity";
        withdrawFailedOperation();
        return started;
      }
    }

    const std::shared_ptr<const MatroskaPreparedAsset>& asset =
        context->asset();
    if (asset == nullptr || context->descriptor() == nullptr ||
        context->descriptor().get() != asset->descriptor().get()) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error = "matroska context changed its immutable asset identity";
      withdrawFailedOperation();
      return started;
    }
    started.descriptor = context->descriptor();
    started.context = context;
    if (!media::validateMediaSourceDescriptor(*started.descriptor, limits,
                                              &started.error)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }
    if ((requestedOptions.selection.requireVideo &&
         !started.descriptor->selectedVideo) ||
        (requestedOptions.selection.requireAudio &&
         !started.descriptor->selectedAudio)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error = "matroska did not select every required track";
      withdrawFailedOperation();
      return started;
    }
    if (requestedTarget &&
        (requestedTarget->value < 0 ||
         !exactNonnegativeTimeWithinDuration(*requestedTarget,
                                             started.descriptor->duration))) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error = "requested position is outside the exact source timeline";
      withdrawFailedOperation();
      return started;
    }

    const media::matroska::MatroskaPlanOutcome planned = asset->planGeneration(
        requestedTarget.value_or(MediaTime{0, 1}), seekMode, cancellation());
    if (planned.status != MatroskaDemuxStatus::Ready || !planned.plan) {
      switch (planned.status) {
      case MatroskaDemuxStatus::Cancelled:
        started.status = media::MediaSourceOpenStatus::Cancelled;
        break;
      case MatroskaDemuxStatus::Unsupported:
        started.status = media::MediaSourceOpenStatus::Unsupported;
        break;
      default:
        started.status = media::MediaSourceOpenStatus::Failed;
        break;
      }
      started.error =
          demuxErrorMessage(planned.message.empty()
                                ? "matroska generation planning failed"
                                : planned.message.c_str(),
                            planned.error);
      withdrawFailedOperation();
      return started;
    }
    const MatroskaGenerationPlan& plan = *planned.plan;
    const auto startAgainstTarget =
        requestedTarget
            ? media::compareMediaTime(plan.actualDecodeStart, *requestedTarget)
            : std::optional<MediaTimeOrder>{MediaTimeOrder::Less};
    // A plan may legitimately begin after its target in exactly one case: the
    // requested position lies at or before the first video keyframe, so the
    // demuxer clamps to cue zero. A stream-copied Matroska commonly starts its
    // video a few milliseconds in while audio starts at zero, and that first
    // cue is the true video origin rather than a skipped seek target. Any plan
    // that starts late anywhere else really has skipped content and stays
    // rejected.
    bool clampedToVideoOrigin = false;
    if (startAgainstTarget && *startAgainstTarget == MediaTimeOrder::Greater) {
      const auto cues = asset->cues();
      if (!cues.empty()) {
        const auto firstCueTime = matroskaTickTime(
            static_cast<std::int64_t>(cues.front().timestampTick),
            asset->timestampScaleNanoseconds());
        clampedToVideoOrigin =
            firstCueTime.has_value() &&
            media::compareMediaTime(plan.actualDecodeStart, *firstCueTime) ==
                std::optional<MediaTimeOrder>{MediaTimeOrder::Equal};
      }
    }
    if (!plan.actualDecodeStart.valid() || plan.actualDecodeStart.value < 0 ||
        !startAgainstTarget ||
        (*startAgainstTarget == MediaTimeOrder::Greater &&
         !clampedToVideoOrigin)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error = "matroska plan starts after its own requested position";
      withdrawFailedOperation();
      return started;
    }

    descriptor = started.descriptor;
    assetContext = context;
    videoTerminal = !descriptor->selectedVideo;
    audioTerminal = !descriptor->selectedAudio;

    // One format description per generation, retained for every sample of it.
    // Rebuilding per sample would hand VideoToolbox a second, distinct
    // description object and force a decoder reconfiguration mid-stream.
    if (descriptor->selectedVideo) {
      const MediaTrackDescriptor* video =
          media::findMediaTrack(*descriptor, *descriptor->selectedVideo);
      videoFormat = video == nullptr ? nullptr
                                     : createVideoFormatDescription(*video);
      if (videoFormat == nullptr) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error = "matroska video track has no admissible CoreMedia "
                        "format description";
        withdrawFailedOperation();
        return started;
      }
    }
    if (descriptor->selectedAudio) {
      const MediaTrackDescriptor* audio =
          media::findMediaTrack(*descriptor, *descriptor->selectedAudio);
      audioFormat = audio == nullptr ? nullptr
                                     : createAudioFormatDescription(*audio);
      if (audioFormat == nullptr) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error = "matroska audio track has no admissible CoreMedia "
                        "format description";
        withdrawFailedOperation();
        return started;
      }
    }
    if (!prepareAudioFacts(plan, &started.error)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }

    noteMatroskaAssetContextCursorCreationAttempt(*context);
    videoCursor = asset->makeVideoCursor(plan);
    if (videoCursor == nullptr) {
      started.status = media::MediaSourceOpenStatus::Failed;
      started.error = "matroska video cursor could not be created";
      withdrawFailedOperation();
      return started;
    }
    noteMatroskaAssetContextCursorStarted(*context);
    if (descriptor->selectedAudio) {
      noteMatroskaAssetContextCursorCreationAttempt(*context);
      audioCursor = asset->makeAudioCursor(plan);
      if (audioCursor == nullptr) {
        started.status = media::MediaSourceOpenStatus::Failed;
        started.error = "matroska audio cursor could not be created";
        withdrawFailedOperation();
        return started;
      }
      noteMatroskaAssetContextCursorStarted(*context);
    }

    // Admission proof: one real head retained from every selected output. The
    // contract forbids probing and reopening, so these exact heads are what the
    // first readNext() calls deliver.
    if ((!videoTerminal && !stage(true, true, &started.error)) ||
        (!audioTerminal && !stage(false, true, &started.error)) ||
        isCancelled()) {
      started.status = isCancelled() ? media::MediaSourceOpenStatus::Cancelled
                                     : media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }

    started.status = media::MediaSourceOpenStatus::Ready;
    // When the plan was clamped to the video origin the generation still
    // begins at the requested position: audio decodes from there, and the
    // first video sample simply arrives a few milliseconds later, exactly as
    // it does for an MP4 carrying an edit-list offset. Reporting the video
    // RAP time here instead would state a decode start after the target,
    // which the whole downstream timeline contract forbids.
    started.actualDecodeStart = clampedToVideoOrigin && requestedTarget
                                    ? *requestedTarget
                                    : plan.actualDecodeStart;
    started.audioWindow = descriptor->selectedAudio
                              ? plan.audioWindow
                              : media::MediaAudioGenerationWindow{};
    started.error.clear();
    open = true;
    openSnapshot.store(true, std::memory_order_release);
    return started;
  }
};

MatroskaMediaSource::MatroskaMediaSource()
    : impl_(std::make_unique<Impl>()) {}

MatroskaMediaSource::~MatroskaMediaSource() { close(); }

bool MatroskaMediaSource::armOperation(MediaGeneration generation) noexcept {
  return impl_ != nullptr && impl_->arm(generation);
}

media::MediaSourceOpenOutcome MatroskaMediaSource::openLocalFile(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options, MediaGeneration generation) {
  media::MediaSourceOpenOutcome outcome;
  outcome.generation = generation;
  try {
    if (!impl_->consumeArm(generation)) {
      outcome.error = "matroska open generation was not armed";
      return outcome;
    }
    if (impl_->operationCancelled(generation)) {
      impl_->generation = generation;
      impl_->withdrawFailedOperation();
      outcome.status = media::MediaSourceOpenStatus::Cancelled;
      outcome.error = "matroska open was cancelled before entry";
      return outcome;
    }
    if (path.empty() || impl_->open ||
        !media::validateMediaSourceInitialPosition(options.initialPosition,
                                                   &outcome.error)) {
      if (outcome.error.empty()) {
        outcome.error = "invalid matroska open path or state";
      }
      impl_->restoreCurrentPublicationAfterRejectedOperation();
      return outcome;
    }
    impl_->path = path;
    impl_->options = options;
    std::optional<MediaTime> target;
    media::MediaSeekMode mode = media::MediaSeekMode::Accurate;
    if (options.initialPosition) {
      target = options.initialPosition->target;
      mode = options.initialPosition->mode;
    }
    GenerationStart started =
        impl_->begin(path, options, generation, target, mode, nullptr);
    outcome.status = started.status;
    outcome.actualDecodeStart = started.actualDecodeStart;
    outcome.descriptor = std::move(started.descriptor);
    outcome.error = std::move(started.error);
    if (outcome.status == media::MediaSourceOpenStatus::Ready) {
      outcome.preparedContext = std::move(started.context);
      outcome.audioWindow = started.audioWindow;
    }
  } catch (const std::exception& exception) {
    impl_->withdrawFailedOperation();
    outcome.status = media::MediaSourceOpenStatus::Failed;
    outcome.error = exception.what();
  } catch (...) {
    impl_->withdrawFailedOperation();
    outcome.status = media::MediaSourceOpenStatus::Failed;
    outcome.error = "matroska open raised an unknown exception";
  }
  return outcome;
}

media::MediaSourceSeekOutcome MatroskaMediaSource::seek(
    const media::MediaSourceSeekRequest& request) {
  media::MediaSourceSeekOutcome outcome;
  outcome.generation = request.generation;
  try {
    if (!impl_->consumeArm(request.generation)) {
      outcome.error = "matroska seek generation was not armed";
      return outcome;
    }
    if (impl_->operationCancelled(request.generation)) {
      impl_->generation = request.generation;
      impl_->withdrawFailedOperation();
      outcome.error = "matroska seek was cancelled before entry";
      return outcome;
    }
    const std::optional<media::MediaSourceInitialPosition> position{
        media::MediaSourceInitialPosition{request.target, request.mode}};
    if (!impl_->open || request.generation == 0 ||
        request.generation <= impl_->generation ||
        !media::validateMediaSourceInitialPosition(position, &outcome.error) ||
        impl_->descriptor == nullptr ||
        !exactNonnegativeTimeWithinDuration(request.target,
                                            impl_->descriptor->duration)) {
      if (outcome.error.empty()) {
        outcome.error = "invalid matroska seek request";
      }
      impl_->restoreCurrentPublicationAfterRejectedOperation();
      return outcome;
    }
    const auto priorDescriptor = impl_->descriptor;
    const auto priorContext = impl_->assetContext;
    GenerationStart started = impl_->begin(
        impl_->path, impl_->options, request.generation,
        std::optional<MediaTime>{request.target}, request.mode, priorContext);
    if (started.status != media::MediaSourceOpenStatus::Ready) {
      outcome.error = std::move(started.error);
      return outcome;
    }
    // The dispatcher rejects a generation whose context pointer moved, so the
    // exact instance admitted by open is the only acceptable answer here.
    if (priorDescriptor == nullptr || priorContext == nullptr ||
        impl_->descriptor.get() != priorDescriptor.get() ||
        impl_->assetContext.get() != priorContext.get()) {
      outcome.error = "matroska prepared identity changed across seek";
      impl_->withdrawFailedOperation();
      return outcome;
    }
    outcome.accepted = true;
    outcome.actualDecodeStart = started.actualDecodeStart;
    outcome.preparedContext = impl_->assetContext;
    outcome.audioWindow = started.audioWindow;
    impl_->seeksAccepted.store(
        saturatingIncrement(
            impl_->seeksAccepted.load(std::memory_order_relaxed)),
        std::memory_order_relaxed);
  } catch (const std::exception& exception) {
    impl_->withdrawFailedOperation();
    outcome.error = exception.what();
  } catch (...) {
    impl_->withdrawFailedOperation();
    outcome.error = "matroska seek raised an unknown exception";
  }
  return outcome;
}

media::MediaSourceReadResult MatroskaMediaSource::readNext(
    MediaGeneration expectedGeneration) {
  try {
    if (!impl_->open || expectedGeneration != impl_->generation ||
        impl_->isCancelled()) {
      if (impl_->isCancelled()) {
        impl_->withdrawFailedOperation();
      }
      return media::MediaSourceCancelled{expectedGeneration};
    }

    // Admission already owns one exact head per selected output. Once a head
    // has been consumed, replenish that lane only on the next downstream pull,
    // then restore the complete A/V merge frontier before comparing times.
    if (impl_->failure.empty()) {
      std::string refillError;
      bool refilled = false;
      try {
        refilled = impl_->refillPendingHeads(&refillError);
      } catch (const std::exception& exception) {
        refillError = exception.what();
      } catch (...) {
        refillError = "matroska staging raised an unknown exception";
      }
      if (!refilled) {
        if (impl_->isCancelled()) {
          impl_->withdrawFailedOperation();
          return media::MediaSourceCancelled{expectedGeneration};
        }
        impl_->failure = refillError.empty()
                             ? "matroska could not stage the next sample"
                             : std::move(refillError);
      }
    }

    std::optional<StagedSample>* chosen = nullptr;
    bool chosenVideo = false;
    if (impl_->videoHead && impl_->audioHead) {
      const auto order = media::compareMediaTime(impl_->videoHead->orderTime,
                                                 impl_->audioHead->orderTime);
      if (!order) {
        impl_->failure = "staged samples have incomparable timestamps";
      } else {
        chosenVideo = *order != MediaTimeOrder::Greater;
        chosen = chosenVideo ? &impl_->videoHead : &impl_->audioHead;
      }
    } else if (impl_->videoHead) {
      chosenVideo = true;
      chosen = &impl_->videoHead;
    } else if (impl_->audioHead) {
      chosen = &impl_->audioHead;
    }
    if (chosen != nullptr) {
      StagedSample emitted = std::move(**chosen);
      impl_->clearHead(*chosen);
      (chosenVideo ? impl_->videoRefillPending
                   : impl_->audioRefillPending) = true;
      impl_->samplesEmitted.store(
          saturatingIncrement(
              impl_->samplesEmitted.load(std::memory_order_relaxed)),
          std::memory_order_relaxed);
      return std::move(emitted.value);
    }
    if (!impl_->failure.empty()) {
      return media::MediaSourceFailure{impl_->generation, impl_->failure};
    }
    if (impl_->videoTerminal && !impl_->videoEosEmitted &&
        impl_->descriptor->selectedVideo) {
      impl_->videoEosEmitted = true;
      return media::MediaEndOfStream{impl_->generation,
                                     *impl_->descriptor->selectedVideo};
    }
    if (impl_->audioTerminal && !impl_->audioEosEmitted &&
        impl_->descriptor->selectedAudio) {
      impl_->audioEosEmitted = true;
      return media::MediaEndOfStream{impl_->generation,
                                     *impl_->descriptor->selectedAudio};
    }
    return media::MediaSourceExhausted{impl_->generation};
  } catch (const std::exception& exception) {
    return media::MediaSourceFailure{expectedGeneration, exception.what()};
  } catch (...) {
    return media::MediaSourceFailure{expectedGeneration,
                                     "matroska read raised an unknown "
                                     "exception"};
  }
}

void MatroskaMediaSource::requestCancel(MediaGeneration generation) noexcept {
  try {
    impl_->publishCancellation(generation);
  } catch (...) {
  }
}

void MatroskaMediaSource::close() noexcept {
  if (impl_ == nullptr) {
    return;
  }
  try {
    impl_->operationGeneration.store(0, std::memory_order_release);
    impl_->retireActive();
    impl_->clearHeads();
    impl_->descriptor.reset();
    impl_->assetContext.reset();
    impl_->path.clear();
    impl_->open = false;
    impl_->openSnapshot.store(false, std::memory_order_release);
    impl_->armedGeneration = 0;
    impl_->requestedTarget.reset();
    impl_->failure.clear();
    impl_->audioProofStated = false;
    impl_->audioProofCeiling.reset();
    impl_->audioDecodeStart = MediaTime{};
  } catch (...) {
  }
}

media::MediaSourceStats MatroskaMediaSource::stats() const noexcept {
  media::MediaSourceStats result;
  result.open = impl_->openSnapshot.load(std::memory_order_acquire);
  result.operationGeneration =
      impl_->operationGeneration.load(std::memory_order_acquire);
  result.generation =
      impl_->generationHighWater.load(std::memory_order_acquire);
  result.cancelled =
      result.operationGeneration != 0 &&
      impl_->cancelledGeneration.load(std::memory_order_acquire) ==
          result.operationGeneration;
  result.stagedGeneration =
      impl_->stagedGeneration.load(std::memory_order_acquire);
  result.stagedVideoHeads =
      impl_->stagedVideoHeads.load(std::memory_order_relaxed);
  result.stagedAudioHeads =
      impl_->stagedAudioHeads.load(std::memory_order_relaxed);
  result.stagedPayloadBytes =
      impl_->stagedPayloadBytes.load(std::memory_order_relaxed);
  result.peakStagedPayloadBytes =
      std::max(impl_->peakStagedPayloadBytes.load(std::memory_order_relaxed),
               result.stagedPayloadBytes);
  result.samplesEmitted =
      impl_->samplesEmitted.load(std::memory_order_relaxed);
  result.seeksAccepted = impl_->seeksAccepted.load(std::memory_order_relaxed);
  return result;
}

std::shared_ptr<const MatroskaAssetContext>
MatroskaMediaSource::assetContext() const noexcept {
  return impl_ == nullptr ? nullptr : impl_->assetContext;
}

}  // namespace wam::macos
