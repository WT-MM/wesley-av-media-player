#pragma once

#include "media/native_media_source.hpp"
#include "media/media_codec_facts.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <numeric>
#include <optional>
#include <span>
#include <string>
#include <utility>

namespace wam::macos {

// Container-agnostic leaves shared by every macOS media source that publishes
// CoreMedia sample buffers through the neutral MediaSource contract. Nothing
// here names a container: each routine is a pure function of neutral types or
// of one CMSampleBuffer, and every backend must answer it identically, because
// the consumers downstream (the video consumer, the audio converter, the
// preview decoder) compare what one backend published against what another
// backend would have published for the same bytes.
//
// Everything is `inline` on purpose: the header is included only by macOS
// backend translation units, and a definition per unit is what keeps this out
// of every CMake source list a backend must be linked into.

inline void assignError(std::string* error, const char* message) {
  if (error != nullptr) {
    *error = message;
  }
}

[[nodiscard]] inline std::uint64_t saturatingIncrement(
    std::uint64_t value) noexcept {
  return value == std::numeric_limits<std::uint64_t>::max() ? value
                                                            : value + 1;
}

[[nodiscard]] inline bool exactNonnegativeTimeWithinDuration(
    media::MediaTime target, media::MediaTime duration) noexcept {
  if (!target.valid() || target.value < 0 || !duration.valid() ||
      duration.value < 0) {
    return false;
  }
  const auto order = media::compareMediaTime(target, duration);
  return order && *order != media::MediaTimeOrder::Greater;
}

// Exact integer sample rate of a selected audio track, or empty when the
// container declared a rate that cannot be placed on an integer PCM grid.
[[nodiscard]] inline std::optional<std::uint32_t> exactAudioSampleRate(
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

// Exact sum of two container rationals. The intermediate product needs the
// full 128-bit range: adjacent media ticks at a nanosecond timescale are
// already above 2^53, so converting through double would silently move a
// sample across the accurate-seek boundary.
[[nodiscard]] inline std::optional<media::MediaTime> checkedExactTimeSum(
    media::MediaTime lhs, media::MediaTime rhs) noexcept {
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

// True when the sample's whole presentation interval closes at or before the
// accurate-seek target, which is exactly the decodeOnly predicate. Empty when
// the interval is not exactly representable or comparable, with the reason
// written through `error`.
[[nodiscard]] inline std::optional<bool> accurateVideoDecodeOnly(
    media::MediaTime presentationTime, media::MediaTime duration,
    media::MediaTime target, std::string* error) noexcept {
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
  return *endAgainstTarget != media::MediaTimeOrder::Greater;
}

// Owns the +1 on one retained CoreMedia buffer.
class ScopedSampleBuffer final {
 public:
  explicit ScopedSampleBuffer(CMSampleBufferRef sample = nullptr) noexcept
      : sample_(sample) {}
  ScopedSampleBuffer(const ScopedSampleBuffer&) = delete;
  ScopedSampleBuffer& operator=(const ScopedSampleBuffer&) = delete;
  ScopedSampleBuffer(ScopedSampleBuffer&& other) noexcept
      : sample_(std::exchange(other.sample_, nullptr)) {}
  ScopedSampleBuffer& operator=(ScopedSampleBuffer&& other) noexcept {
    if (this != &other) {
      reset(std::exchange(other.sample_, nullptr));
    }
    return *this;
  }
  ~ScopedSampleBuffer() {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

  [[nodiscard]] CMSampleBufferRef get() const noexcept { return sample_; }
  [[nodiscard]] CMSampleBufferRef release() noexcept {
    return std::exchange(sample_, nullptr);
  }
  // Adopts a +1 reference, releasing whatever was held.
  void reset(CMSampleBufferRef sample = nullptr) noexcept {
    CMSampleBufferRef prior = std::exchange(sample_, sample);
    if (prior != nullptr && prior != sample) {
      CFRelease(prior);
    }
  }

 private:
  CMSampleBufferRef sample_{nullptr};
};

// Owns the +1 on one retained CoreMedia buffer for the lifetime of every lease
// taken against it. One definition for every backend: the native video
// consumer, the audio converter and the preview decoder borrow the buffer
// through the neutral payload seam and must see the same shape whichever
// container produced it.
class CoreMediaSampleStorage final : public media::MediaPayloadStorage {
 public:
  CoreMediaSampleStorage(CMSampleBufferRef ownedSample,
                         std::size_t byteSize) noexcept
      : sample_(ownedSample), byte_size_(byteSize) {}
  ~CoreMediaSampleStorage() override {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

  CoreMediaSampleStorage(const CoreMediaSampleStorage&) = delete;
  CoreMediaSampleStorage& operator=(const CoreMediaSampleStorage&) = delete;

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

// The converter compares every ASBD field, the magic cookie bytes, and the
// channel layout tag against the admitted descriptor, so all three are
// restated from the descriptor rather than re-derived from the cookie.
//
// Two shapes are admitted, and exactly two: a codec that HAS a magic cookie
// must present it as one, and a codec that has none (AC-3, E-AC-3 and MPEG
// audio restate every parameter in each frame header) must present nothing
// at all.
[[nodiscard]] inline CMAudioFormatDescriptionRef createAudioFormatDescription(
    const media::MediaTrackDescriptor& track) noexcept {
  const bool cookiePresent =
      track.codecConfigurationKind ==
          media::MediaCodecConfigurationKind::AudioMagicCookie &&
      !track.codecConfiguration.empty();
  const bool raw = media::softwareAudioCodec(track.codec) &&
      track.codecConfigurationKind == media::MediaCodecConfigurationKind::CodecPrivate;
  const bool cookieAbsent =
      track.codecConfigurationKind == media::MediaCodecConfigurationKind::None &&
      track.codecConfiguration.empty();
  if (!track.audio || track.kind != media::MediaTrackKind::Audio ||
      (!cookiePresent && !cookieAbsent && !raw)) {
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
      cookiePresent ? track.codecConfiguration.size() : 0,
      cookiePresent ? track.codecConfiguration.data() : nullptr, nullptr,
      &description);
  if (status != noErr && description != nullptr) {
    CFRelease(description);
    description = nullptr;
  }
  return status == noErr ? description : nullptr;
}

// States the ImmediatePlayoutFrame proof the converter requires before it will
// admit a generation that does not begin at the stream origin. Neither
// AVFoundation nor CoreMedia states the attachment for a compressed audio unit,
// so the source states it itself -- and only after it has MADE it true by
// placing the generation's decode start a full priming window ahead of the
// first audible frame. An unproved unit is left untouched so the converter
// refuses the generation instead of publishing un-primed PCM.
[[nodiscard]] inline bool statedImmediatePlayoutFrame(
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

}  // namespace wam::macos
