#pragma once

#include "media/audio_codec_timing.hpp"
#include "platform/macos/native_primitives.hpp"
#include "media/native_media_source.hpp"
#include "media/media_codec_facts.hpp"
#include "platform/macos/core_media_time.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
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

[[nodiscard]] inline bool exactNonnegativeTimeWithinDuration(
    media::MediaTime target, media::MediaTime duration) noexcept {
  if (!target.valid() || target.value < 0 || !duration.valid() ||
      duration.value < 0) {
    return false;
  }
  const auto order = media::compareMediaTime(target, duration);
  return order && *order != media::MediaTimeOrder::Greater;
}

[[nodiscard]] inline media::MediaTime optionalMediaTime(CMTime time) noexcept {
  return exactMediaTime(time).value_or(media::MediaTime{});
}

// The neutral timeline window `0 <= actualDecodeStart <= target`, stated by
// native_media_dispatcher.cpp deriveTimeline and re-proved by the video
// consumer and the audio session. `located` is the random-access point a route
// found for `target` (no target: a cold open from the origin). Returns the
// decode start to report, or empty when the located start skipped content.
//
//   * Before 0: a head-trimmed edit list (elst media_time > 0) hides media
//     before the movie origin, so the RAP that decodes the picture at 0
//     restates to a negative movie time. Reported as 0; pictures before the
//     generation start are retired as compressed preroll by the consumer.
//   * After the target: legitimate only when the located start IS the first
//     video access unit -- a leading empty edit, a stream-copied Matroska whose
//     video starts a few milliseconds in, a transport stream whose audio leads
//     its video. Reported as the target (0 without one): audio decodes from
//     there and the first picture simply arrives later. Any other late start
//     has skipped content and is refused.
[[nodiscard]] inline std::optional<media::MediaTime> timelineWindowDecodeStart(
    media::MediaTime located, const std::optional<media::MediaTime>& target,
    const std::optional<media::MediaTime>& videoOrigin) noexcept {
  if (!located.valid()) {
    return std::nullopt;
  }
  if (located.value < 0) {
    return media::MediaTime{0, 1};
  }
  const media::MediaTime ceiling = target.value_or(media::MediaTime{0, 1});
  const auto againstCeiling = media::compareMediaTime(located, ceiling);
  if (!againstCeiling) {
    return std::nullopt;
  }
  if (*againstCeiling != media::MediaTimeOrder::Greater) {
    return located;
  }
  const bool atVideoOrigin =
      videoOrigin.has_value() &&
      media::compareMediaTime(located, *videoOrigin) ==
          std::optional<media::MediaTimeOrder>{media::MediaTimeOrder::Equal};
  if (atVideoOrigin) {
    return ceiling;
  }
  // Without a target the origin itself is the request, so a later first RAP
  // is the start there is.
  if (!target) {
    return located;
  }
  return std::nullopt;
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
  const auto intervalEnd = media::addMediaTime(presentationTime, duration);
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

// The guard keeps the +1 until allocation has succeeded: passing
// owned.release() straight to make_shared would leak it on bad_alloc.
[[nodiscard]] inline std::shared_ptr<CoreMediaSampleStorage>
leaseSampleBuffer(ScopedSampleBuffer&& owned, std::size_t byteSize) {
  auto storage =
      std::make_shared<CoreMediaSampleStorage>(owned.get(), byteSize);
  static_cast<void>(owned.release());
  return storage;
}

// The converter compares every ASBD field, the magic cookie bytes, and the
// channel layout tag against the admitted descriptor, so all three are
// restated from the descriptor rather than re-derived from the cookie.
//
// Three shapes are admitted: a codec that HAS a magic cookie must present it
// as one; a codec that has none (AC-3, E-AC-3 and MPEG audio restate every
// parameter in each frame header) must present nothing at all; and a
// software-decoded codec may carry its raw CodecPrivate record, which is never
// handed to CoreMedia as a cookie.
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
  if (!media::exactAudioSampleRate(audio.sampleRate) || audio.channels == 0) {
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
