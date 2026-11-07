#pragma once

#include "media/media_time.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstdint>
#include <optional>

namespace wam::macos {

// The one CoreMedia <-> MediaTime boundary. A CMTime is exact only when it is
// numeric, unrounded, in epoch zero and has a positive timescale; anything
// else has no MediaTime.
[[nodiscard]] inline std::optional<media::MediaTime> exactMediaTime(
    CMTime time) noexcept {
  if (!CMTIME_IS_NUMERIC(time) || time.timescale <= 0 || time.epoch != 0 ||
      (time.flags & kCMTimeFlags_HasBeenRounded) != 0) {
    return std::nullopt;
  }
  return media::MediaTime{time.value, time.timescale};
}

[[nodiscard]] inline std::optional<CMTime> exactCMTime(
    media::MediaTime time) noexcept {
  if (!time.valid()) {
    return std::nullopt;
  }
  return CMTimeMake(time.value, time.timescale);
}

// Field identity, not numeric equality: an event matches a submitted frame
// only when every CMTime field is the one that was submitted.
[[nodiscard]] inline bool sameExactCMTime(CMTime lhs, CMTime rhs) noexcept {
  return lhs.value == rhs.value && lhs.timescale == rhs.timescale &&
         lhs.flags == rhs.flags && lhs.epoch == rhs.epoch;
}

// The container's sync attachment; false when the attachments are malformed.
// No attachment array, or no NotSync key, means a sync sample.
[[nodiscard]] inline bool sampleIsKeyFrame(CMSampleBufferRef sample,
                                           bool* keyFrame) noexcept {
  if (sample == nullptr || keyFrame == nullptr) {
    return false;
  }
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    *keyFrame = true;
    return true;
  }
  if (CFArrayGetCount(attachments) != 1) {
    return false;
  }
  CFTypeRef value = CFArrayGetValueAtIndex(attachments, 0);
  if (value == nullptr || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
    return false;
  }
  CFTypeRef notSync = CFDictionaryGetValue(
      static_cast<CFDictionaryRef>(value), kCMSampleAttachmentKey_NotSync);
  if (notSync == nullptr) {
    *keyFrame = true;
    return true;
  }
  if (CFGetTypeID(notSync) != CFBooleanGetTypeID()) {
    return false;
  }
  *keyFrame = !CFBooleanGetValue(static_cast<CFBooleanRef>(notSync));
  return true;
}

// Identifies a decode generation. Incrementing the generation on seek or load
// lets every asynchronous stage reject frames from the previous timeline.
struct FrameTiming {
  CMTime presentationTime{kCMTimeInvalid};
  CMTime duration{kCMTimeInvalid};
  std::uint64_t generation{0};
  bool keyFrame{false};
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && WAM_NATIVE_BENCHMARK_TELEMETRY
  std::uint64_t decodeCompleteHostTicks{0};
  std::uint64_t surfaceLeaseHostTicks{0};
#endif
};

// Whether an output event refers to exactly the frame that was submitted.
[[nodiscard]] inline bool sameFrameTiming(const FrameTiming& lhs,
                                          const FrameTiming& rhs) noexcept {
  return lhs.generation == rhs.generation && lhs.keyFrame == rhs.keyFrame &&
         sameExactCMTime(lhs.presentationTime, rhs.presentationTime) &&
         sameExactCMTime(lhs.duration, rhs.duration);
}

}  // namespace wam::macos
