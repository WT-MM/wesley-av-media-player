#include "platform/macos/matroska_sample_builder.hpp"


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
using media::MediaRefusalClass;

constexpr std::size_t kMaximumLaceFrames{
    media::matroska::ParseOptions::kHardMaximumLaceFrames};

}  // namespace

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

MatroskaSampleBuildStatus buildMatroskaCompressedSampleBuffer(
    const MatroskaSampleBuildInputs& inputs,
    const MatroskaCompressedSample& sample, ScopedSampleBuffer* out,
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

  // The demuxer writes payload bytes straight into the CoreMedia block, so
  // each byte is copied exactly once; do not stage through a scratch vector.
  CMBlockBufferRef block = nullptr;
  std::span<std::byte> destination;
  if (!allocateSampleBlock(bytes, "matroska", &block, &destination, error)) {
    return MatroskaSampleBuildStatus::Failed;
  }
  MediaRefusalClass copyError = MediaRefusalClass::None;
  if (!inputs.asset->copyRanges({sample.frames.data(), frameCount}, destination,
                                inputs.cancellation, &copyError)) {
    // A failed or cancelled copy leaves a partially written block that no
    // caller ever sees; releasing it here is the whole cleanup.
    CFRelease(block);
    if (copyError == MediaRefusalClass::Cancelled) {
      return MatroskaSampleBuildStatus::Cancelled;
    }
    if (error != nullptr) {
      *error =
          media::refusalMessage("matroska payload copy failed", copyError);
    }
    return MatroskaSampleBuildStatus::Failed;
  }

  CMSampleTimingInfo timing{};
  if (!sample.presentationTime.valid()) {
    CFRelease(block);
    assignError(error, "matroska sample has no exact presentation time");
    return MatroskaSampleBuildStatus::Failed;
  }
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

  if (!inputs.video) {
    const auto* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(inputs.format);
    if (asbd && asbd->mFormatID == kAudioFormatLinearPCM) {
      if (asbd->mBytesPerFrame == 0 || bytes % asbd->mBytesPerFrame != 0) {
        CFRelease(block);
        assignError(error, "Matroska PCM block is not frame aligned");
        return MatroskaSampleBuildStatus::Failed;
      }
      numSamples = static_cast<CMItemCount>(bytes / asbd->mBytesPerFrame);
      sizeEntries = 1;
      sizes[0] = asbd->mBytesPerFrame;
      timing.duration = CMTimeMake(1, inputs.audioSampleRate);
    }
  }
  // Video only: Matroska states every audio block as non-key by convention,
  // not because the unit depends on another one.
  CompressedSampleShape shape;
  shape.timing = timing;
  shape.sampleCount = numSamples;
  shape.sizeEntryCount = sizeEntries;
  shape.sizes = sizes.data();
  if (inputs.video) {
    shape.videoKeyFrame = sample.keyFrame;
  }
  if (!buildCompressedSampleBuffer(block, inputs.format, shape, "matroska",
                                   out, error)) {
    return MatroskaSampleBuildStatus::Failed;
  }
  return MatroskaSampleBuildStatus::Built;
}

}  // namespace wam::macos
