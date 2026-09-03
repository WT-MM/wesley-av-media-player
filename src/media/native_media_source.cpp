#include "media/native_media_source.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <limits>
#include <numeric>
#include <utility>

namespace wam::media {
namespace {

void assignError(std::string* error, const char* message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
    // Error reporting is best-effort at this noexcept validation boundary.
  }
}

bool validOptionalTime(MediaTime time) noexcept {
  return time.timescale == 0 || time.valid();
}

bool validDuration(MediaTime time) noexcept {
  return time.valid() && time.value >= 0;
}

bool canonicalPositiveTimeBase(MediaTime time) noexcept {
  return time.valid() && time.value > 0 &&
         std::gcd(static_cast<std::uint64_t>(time.value),
                  static_cast<std::uint64_t>(time.timescale)) == 1;
}

std::uint64_t unsignedMagnitude(std::int64_t value) noexcept {
  if (value >= 0) {
    return static_cast<std::uint64_t>(value);
  }
  return static_cast<std::uint64_t>(-(value + 1)) + 1;
}

unsigned bitWidth(__uint128_t value) noexcept {
  const std::uint64_t high = static_cast<std::uint64_t>(value >> 64U);
  if (high != 0) {
    return 128U - static_cast<unsigned>(std::countl_zero(high));
  }
  const std::uint64_t low = static_cast<std::uint64_t>(value);
  return low == 0
             ? 0U
             : 64U - static_cast<unsigned>(std::countl_zero(low));
}

// Converts an unsigned 128-bit rational to binary64 with exact round-to-
// nearest, ties-to-even semantics. Integer-only normalization and rounding
// make the result independent of the process floating-point environment.
// The two callers below admit only a MediaTime magnitude or the checked
// MediaTime-plus-frame expression: numerator < 2^96 and denominator < 2^63.
// Their nonzero exponent is therefore in [-63, 64], so every scaling shift
// fits uint128 and every result is a normal finite binary64 value. Defensive
// shift checks fail closed if this private helper is ever reused outside that
// domain; subnormal and overflow encodings are unreachable for current calls.
std::optional<double> correctlyRoundedPositiveRational(
    __uint128_t numerator, __uint128_t denominator) noexcept {
  if (denominator == 0) {
    return std::nullopt;
  }
  if (numerator == 0) {
    return 0.0;
  }

  const unsigned numeratorBits = bitWidth(numerator);
  const unsigned denominatorBits = bitWidth(denominator);
  int exponent = static_cast<int>(numeratorBits) -
                 static_cast<int>(denominatorBits);
  if (exponent >= 0) {
    const unsigned shift = static_cast<unsigned>(exponent);
    if (numerator < (denominator << shift)) {
      --exponent;
    }
  } else {
    const unsigned shift = static_cast<unsigned>(-exponent);
    if ((numerator << shift) < denominator) {
      --exponent;
    }
  }

  constexpr __uint128_t maximum = ~static_cast<__uint128_t>(0);
  __uint128_t scaledNumerator = numerator;
  __uint128_t scaledDenominator = denominator;
  const int significandShift = 52 - exponent;
  if (significandShift >= 0) {
    const unsigned shift = static_cast<unsigned>(significandShift);
    if (shift >= 128U || numerator > (maximum >> shift)) {
      return std::nullopt;
    }
    scaledNumerator <<= shift;
  } else {
    const unsigned shift = static_cast<unsigned>(-significandShift);
    if (shift >= 128U || denominator > (maximum >> shift)) {
      return std::nullopt;
    }
    scaledDenominator <<= shift;
  }

  constexpr __uint128_t implicitBit = __uint128_t{1} << 52U;
  constexpr __uint128_t carryBit = __uint128_t{1} << 53U;
  __uint128_t significand = scaledNumerator / scaledDenominator;
  const __uint128_t remainder = scaledNumerator % scaledDenominator;
  if (significand < implicitBit || significand >= carryBit) {
    return std::nullopt;
  }

  const __uint128_t distanceToUpper = scaledDenominator - remainder;
  if (remainder > distanceToUpper ||
      (remainder == distanceToUpper && (significand & 1U) != 0)) {
    ++significand;
    if (significand == carryBit) {
      significand = implicitBit;
      ++exponent;
    }
  }

  if (exponent < -1022 || exponent > 1023) {
    return std::nullopt;
  }
  const std::uint64_t biasedExponent =
      static_cast<std::uint64_t>(exponent + 1023);
  const std::uint64_t fraction =
      static_cast<std::uint64_t>(significand - implicitBit);
  const std::uint64_t bits = (biasedExponent << 52U) | fraction;
  return std::bit_cast<double>(bits);
}

bool canonicalRational(MediaRational value) noexcept {
  return value.denominator != 0 &&
         std::gcd(unsignedMagnitude(value.numerator), value.denominator) == 1;
}

bool positiveRational(MediaRational value) noexcept {
  return canonicalRational(value) && value.numerator > 0;
}

bool rationalEqualsNonnegativeInteger(MediaRational value,
                                      std::uint32_t integer) noexcept {
  return value.denominator == 1 && value.numerator >= 0 &&
         static_cast<std::uint64_t>(value.numerator) == integer;
}

bool validVideoFormat(const MediaVideoFormat& video,
                      const MediaSourceLimits& limits) noexcept {
  // Orientation-agnostic since amendment 8; the zero-dimension refusal lives
  // inside the predicate now, so this no longer restates it.
  if (!limits.codedDimensionsAdmitted(video.codedWidth, video.codedHeight) ||
      video.displayWidth == 0 || video.displayHeight == 0 ||
      video.pixelAspectNumerator == 0 ||
      video.pixelAspectDenominator == 0 ||
      std::gcd(video.pixelAspectNumerator,
               video.pixelAspectDenominator) != 1 ||
      video.bitsPerComponent > 16 || video.fieldCount > 2 ||
      video.progressive !=
          (!video.fieldDetailPresent &&
           (video.fieldCount == 0 || video.fieldCount == 1))) {
    return false;
  }
  if (!video.cleanAperture) {
    return true;
  }
  return positiveRational(video.cleanAperture->width) &&
         positiveRational(video.cleanAperture->height) &&
         canonicalRational(video.cleanAperture->horizontalOffset) &&
         canonicalRational(video.cleanAperture->verticalOffset);
}

bool validAudioFormat(const MediaAudioFormat& audio,
                      const MediaSourceLimits& limits) noexcept {
  if (!std::isfinite(audio.sampleRate) || audio.sampleRate <= 0.0 ||
      audio.sampleRate > limits.maximumAudioSampleRate ||
      audio.channels == 0 ||
      audio.channels > limits.maximumAudioChannels || audio.formatTag == 0 ||
      (!audio.channelLayoutPresent && audio.channelLayoutTag != 0)) {
    return false;
  }

  if (!audio.channelLayoutPresent) {
    return true;
  }

  // Native audio v1 preserves only a scalar CoreAudio-compatible layout tag,
  // not bitmap/description payloads.
  //
  // MONO AND STEREO stay exactly as strict as they have always been: one
  // enumerated canonical tag each, so a reserved family (0xffff0002) or a
  // different two-channel layout (0x00660002 Headphones) is refused even
  // though its low bits do say two.  Both are pinned in
  // native_media_source_test.cpp and neither behaviour changes here.
  constexpr std::uint32_t kCanonicalMonoLayout = 0x00640001U;
  constexpr std::uint32_t kCanonicalStereoLayout = 0x00650002U;
  if (audio.channels == 1) {
    return audio.channelLayoutTag == kCanonicalMonoLayout;
  }
  if (audio.channels == 2) {
    return audio.channelLayoutTag == kCanonicalStereoLayout;
  }
  // MULTICHANNEL (2026-08-27).  Wider layouts have no single canonical tag to
  // enumerate -- 5.1 alone has four in common use (MPEG_5_1_A..D), one per
  // codec family -- so this layer checks the strongest property it can state
  // WITHOUT seeing channel labels, which a backend-neutral file deliberately
  // cannot: a predefined tag carries its channel count in its low sixteen bits
  // and a nonzero layout family in its high sixteen, so a tag whose count
  // agrees with the ASBD is a complete scalar identity, comparable exactly on
  // every later sample without retaining a payload.  That still fails closed
  // for tag 0x00000000 (UseChannelDescriptions, high half zero), tag
  // 0x00010000 (UseChannelBitmap, low half zero) and variable-count families
  // such as 0x00930000 (low half zero).
  //
  // This is NOT a claim that the layout can be rendered.  Whether a given wide
  // layout is one this player can fold to stereo -- including whether its
  // family is recognised by CoreAudio at all -- is a question about LABELS,
  // and it is answered one layer up by macos::multichannelLayoutTagAdmitted
  // (which expands the tag and maps it label by label) at both AVFoundation
  // admission sites, and again by NativeAudioConverter against the decoder's
  // own reported output layout.  An unrecognised or unfoldable wide layout is
  // refused there, as a clean fallback rather than a dropped channel.
  return (audio.channelLayoutTag >> 16U) != 0U &&
         (audio.channelLayoutTag & 0xFFFFU) == audio.channels;
}

bool validSelectedTrack(const MediaSourceDescriptor& descriptor,
                        std::optional<MediaTrackId> selected,
                        MediaTrackKind expected) noexcept {
  if (!selected) {
    return true;
  }
  const MediaTrackDescriptor* track = findMediaTrack(descriptor, *selected);
  return track != nullptr && track->kind == expected;
}

bool equalSelection(const MediaTrackSelection& lhs,
                    const MediaTrackSelection& rhs) noexcept {
  return lhs.preferredVideo == rhs.preferredVideo &&
         lhs.preferredAudio == rhs.preferredAudio &&
         lhs.preferredSubtitle == rhs.preferredSubtitle &&
         lhs.requireVideo == rhs.requireVideo &&
         lhs.requireAudio == rhs.requireAudio;
}

bool equalLimits(const MediaSourceLimits& lhs,
                 const MediaSourceLimits& rhs) noexcept {
  return lhs.maximumTracks == rhs.maximumTracks &&
         lhs.maximumCodecConfigurationBytes ==
             rhs.maximumCodecConfigurationBytes &&
         lhs.maximumVideoSampleBytes == rhs.maximumVideoSampleBytes &&
         lhs.maximumAudioSampleBytes == rhs.maximumAudioSampleBytes &&
         lhs.maximumAudioSampleCount == rhs.maximumAudioSampleCount &&
         lhs.maximumDecodedAudioFrames == rhs.maximumDecodedAudioFrames &&
         lhs.maximumDecodedAudioBytes == rhs.maximumDecodedAudioBytes &&
         lhs.maximumTrackTextBytes == rhs.maximumTrackTextBytes &&
         lhs.maximumCodedWidth == rhs.maximumCodedWidth &&
         lhs.maximumCodedHeight == rhs.maximumCodedHeight &&
         lhs.maximumCodedPixels == rhs.maximumCodedPixels &&
         lhs.maximumAudioChannels == rhs.maximumAudioChannels &&
         lhs.maximumAudioSampleRate == rhs.maximumAudioSampleRate &&
         lhs.maximumVideoSeekPrerollSeconds ==
             rhs.maximumVideoSeekPrerollSeconds &&
         lhs.maximumAudioSeekPrerollSeconds ==
             rhs.maximumAudioSeekPrerollSeconds;
}

std::size_t inventoryCount(const MediaTrackInventory& inventory,
                           MediaTrackKind kind) noexcept {
  switch (kind) {
  case MediaTrackKind::Video:
    return inventory.video;
  case MediaTrackKind::Audio:
    return inventory.audio;
  case MediaTrackKind::Subtitle:
    return inventory.subtitle;
  case MediaTrackKind::Text:
    return inventory.text;
  case MediaTrackKind::ClosedCaption:
    return inventory.closedCaption;
  case MediaTrackKind::Metadata:
    return inventory.metadata;
  }
  return 0;
}

}  // namespace

std::optional<MediaTime>
exactNonnegativeMediaTime(double seconds) noexcept {
  constexpr std::uint64_t kSignBit = UINT64_C(1) << 63U;
  constexpr std::uint64_t kFractionMask =
      (UINT64_C(1) << 52U) - UINT64_C(1);
  constexpr std::uint64_t kExponentMask = UINT64_C(0x7ff);
  constexpr std::uint64_t kImplicitBit = UINT64_C(1) << 52U;
  constexpr unsigned kMaximumTimescaleShift = 30U;

  const std::uint64_t bits = std::bit_cast<std::uint64_t>(seconds);
  const std::uint64_t exponentBits = (bits >> 52U) & kExponentMask;
  const std::uint64_t fraction = bits & kFractionMask;

  // Normalize both signed zero encodings before applying the sign rule.
  if (exponentBits == 0 && fraction == 0) {
    return MediaTime{0, 1};
  }
  if ((bits & kSignBit) != 0 || exponentBits == kExponentMask) {
    return std::nullopt;
  }

  // Every nonzero subnormal needs a denominator of at least 2^1023 after
  // reduction, far beyond the positive int32 MediaTime timescale domain.
  if (exponentBits == 0) {
    return std::nullopt;
  }

  std::uint64_t numerator = kImplicitBit | fraction;
  const int binaryExponent =
      static_cast<int>(exponentBits) - 1023 - 52;
  if (binaryExponent < 0) {
    unsigned denominatorShift =
        static_cast<unsigned>(-binaryExponent);
    const unsigned cancellation =
        std::min(static_cast<unsigned>(std::countr_zero(numerator)),
                 denominatorShift);
    numerator >>= cancellation;
    denominatorShift -= cancellation;
    if (denominatorShift > kMaximumTimescaleShift) {
      return std::nullopt;
    }

    const std::uint32_t timescale = UINT32_C(1) << denominatorShift;
    return MediaTime{static_cast<std::int64_t>(numerator),
                     static_cast<std::int32_t>(timescale)};
  }

  const unsigned numeratorShift = static_cast<unsigned>(binaryExponent);
  constexpr std::uint64_t kMaximumNumerator =
      static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
  if (numeratorShift >= 64U ||
      numerator > (kMaximumNumerator >> numeratorShift)) {
    return std::nullopt;
  }
  numerator <<= numeratorShift;
  return MediaTime{static_cast<std::int64_t>(numerator), 1};
}

std::optional<double> mediaTimeSeconds(MediaTime time) noexcept {
  if (!time.valid()) {
    return std::nullopt;
  }
  const auto magnitude = correctlyRoundedPositiveRational(
      static_cast<__uint128_t>(unsignedMagnitude(time.value)),
      static_cast<__uint128_t>(static_cast<std::uint32_t>(time.timescale)));
  if (!magnitude) {
    return std::nullopt;
  }
  if (time.value >= 0 || *magnitude == 0.0) {
    return magnitude;
  }
  const std::uint64_t bits =
      std::bit_cast<std::uint64_t>(*magnitude) |
      (std::uint64_t{1} << 63U);
  return std::bit_cast<double>(bits);
}

std::optional<double> mediaTimeSecondsAtFrame(
    MediaTime origin, std::uint64_t frame,
    std::uint32_t sampleRate) noexcept {
  if (!origin.valid() || sampleRate == 0) {
    return std::nullopt;
  }

  using WideSigned = __int128_t;
  using WideUnsigned = __uint128_t;
  const WideSigned numerator =
      static_cast<WideSigned>(origin.value) *
          static_cast<WideSigned>(sampleRate) +
      static_cast<WideSigned>(frame) *
          static_cast<WideSigned>(origin.timescale);
  if (numerator < 0) {
    return std::nullopt;
  }
  const WideUnsigned denominator =
      static_cast<WideUnsigned>(static_cast<std::uint32_t>(origin.timescale)) *
      static_cast<WideUnsigned>(sampleRate);
  if (denominator == 0) {
    return std::nullopt;
  }

  return correctlyRoundedPositiveRational(
      static_cast<WideUnsigned>(numerator), denominator);
}

std::optional<std::int64_t> exactAudioFrameIndex(
    MediaTime time, std::uint32_t sampleRate) noexcept {
  if (!time.valid() || sampleRate == 0) {
    return std::nullopt;
  }
  using Wide = __int128_t;
  const Wide scaled = static_cast<Wide>(time.value) *
                      static_cast<Wide>(sampleRate);
  const Wide denominator = static_cast<Wide>(time.timescale);
  if (scaled % denominator != 0) {
    return std::nullopt;
  }
  const Wide frame = scaled / denominator;
  if (frame < static_cast<Wide>(std::numeric_limits<std::int64_t>::min()) ||
      frame > static_cast<Wide>(std::numeric_limits<std::int64_t>::max())) {
    return std::nullopt;
  }
  return static_cast<std::int64_t>(frame);
}

std::optional<MediaTime> audioFrameAtOrAfter(
    MediaTime time, std::uint32_t sampleRate) noexcept {
  if (!time.valid() || sampleRate == 0) {
    return std::nullopt;
  }
  using Wide = __int128_t;
  const Wide scaled = static_cast<Wide>(time.value) *
                      static_cast<Wide>(sampleRate);
  const Wide denominator = static_cast<Wide>(time.timescale);
  Wide frame = scaled / denominator;
  if (scaled % denominator > 0) {
    ++frame;
  }
  if (frame < static_cast<Wide>(std::numeric_limits<std::int64_t>::min()) ||
      frame > static_cast<Wide>(std::numeric_limits<std::int64_t>::max())) {
    return std::nullopt;
  }

  const std::int64_t signedFrame = static_cast<std::int64_t>(frame);
  const std::uint64_t magnitude = unsignedMagnitude(signedFrame);
  const std::uint64_t divisor = std::gcd(
      magnitude, static_cast<std::uint64_t>(sampleRate));
  const std::uint64_t reducedScale =
      static_cast<std::uint64_t>(sampleRate) / divisor;
  if (reducedScale >
      static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  const Wide reducedValue = frame / static_cast<Wide>(divisor);
  if (reducedValue <
          static_cast<Wide>(std::numeric_limits<std::int64_t>::min()) ||
      reducedValue >
          static_cast<Wide>(std::numeric_limits<std::int64_t>::max())) {
    return std::nullopt;
  }
  return MediaTime{static_cast<std::int64_t>(reducedValue),
                   static_cast<std::int32_t>(reducedScale)};
}

std::optional<MediaTimeOrder> compareMediaTime(MediaTime lhs,
                                               MediaTime rhs) noexcept {
  if (!lhs.valid() || !rhs.valid()) {
    return std::nullopt;
  }
  using WideSigned = __int128_t;
  const WideSigned left = static_cast<WideSigned>(lhs.value) *
                          static_cast<WideSigned>(rhs.timescale);
  const WideSigned right = static_cast<WideSigned>(rhs.value) *
                           static_cast<WideSigned>(lhs.timescale);
  if (left < right) {
    return MediaTimeOrder::Less;
  }
  if (left > right) {
    return MediaTimeOrder::Greater;
  }
  return MediaTimeOrder::Equal;
}

std::optional<MediaGeneration>
nextMediaGeneration(MediaGeneration current) noexcept {
  if (current == std::numeric_limits<MediaGeneration>::max()) {
    return std::nullopt;
  }
  return current + 1;
}

MediaSourceLimits clampMediaSourceLimits(
    const MediaSourceLimits& requested) noexcept {
  MediaSourceLimits effective = requested;
  effective.maximumTracks =
      std::min(requested.maximumTracks,
               MediaSourceLimits::kHardMaximumTracks);
  effective.maximumCodecConfigurationBytes =
      std::min(requested.maximumCodecConfigurationBytes,
               MediaSourceLimits::kHardMaximumCodecConfigurationBytes);
  effective.maximumVideoSampleBytes =
      std::min(requested.maximumVideoSampleBytes,
               MediaSourceLimits::kHardMaximumVideoSampleBytes);
  effective.maximumAudioSampleBytes =
      std::min(requested.maximumAudioSampleBytes,
               MediaSourceLimits::kHardMaximumAudioSampleBytes);
  effective.maximumAudioSampleCount =
      std::min(requested.maximumAudioSampleCount,
               MediaSourceLimits::kHardMaximumAudioSampleCount);
  effective.maximumDecodedAudioFrames =
      std::min(requested.maximumDecodedAudioFrames,
               MediaSourceLimits::kHardMaximumDecodedAudioFrames);
  effective.maximumDecodedAudioBytes =
      std::min(requested.maximumDecodedAudioBytes,
               MediaSourceLimits::kHardMaximumDecodedAudioBytes);
  effective.maximumTrackTextBytes =
      std::min(requested.maximumTrackTextBytes,
               MediaSourceLimits::kHardMaximumTrackTextBytes);
  effective.maximumCodedWidth =
      std::min(requested.maximumCodedWidth,
               MediaSourceLimits::kHardMaximumCodedWidth);
  effective.maximumCodedHeight =
      std::min(requested.maximumCodedHeight,
               MediaSourceLimits::kHardMaximumCodedHeight);
  effective.maximumCodedPixels =
      std::min(requested.maximumCodedPixels,
               MediaSourceLimits::kHardMaximumCodedPixels);
  effective.maximumAudioChannels =
      std::min(requested.maximumAudioChannels,
               MediaSourceLimits::kHardMaximumAudioChannels);
  effective.maximumAudioSampleRate =
      std::isfinite(requested.maximumAudioSampleRate) &&
              requested.maximumAudioSampleRate >= 0.0
          ? std::min(requested.maximumAudioSampleRate,
                     MediaSourceLimits::kHardMaximumAudioSampleRate)
          : 0.0;
  effective.maximumVideoSeekPrerollSeconds =
      std::isfinite(requested.maximumVideoSeekPrerollSeconds) &&
              requested.maximumVideoSeekPrerollSeconds >= 0.0
          ? std::min(
                requested.maximumVideoSeekPrerollSeconds,
                MediaSourceLimits::kHardMaximumVideoSeekPrerollSeconds)
          : 0.0;
  effective.maximumAudioSeekPrerollSeconds = std::min(
      requested.maximumAudioSeekPrerollSeconds,
      MediaSourceLimits::kHardMaximumAudioSeekPrerollSeconds);
  return effective;
}

bool validateMediaSourceInitialPosition(
    const std::optional<MediaSourceInitialPosition>& position,
    std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (!position) {
    return true;
  }
  if (!position->target.valid() || position->target.value < 0) {
    assignError(error,
                "media source initial position must be exact and nonnegative");
    return false;
  }
  switch (position->mode) {
  case MediaSeekMode::Accurate:
  case MediaSeekMode::KeyFrame:
    return true;
  }
  assignError(error, "media source initial position has an invalid seek mode");
  return false;
}

MediaSourcePreparedContext::MediaSourcePreparedContext(
    MediaSourceBackendKind backendKind, std::filesystem::path path,
    const MediaSourceOpenOptions& options,
    std::shared_ptr<const MediaSourceDescriptor> descriptor) noexcept
    : backendKind_(backendKind), path_(std::move(path)),
      selection_(options.selection),
      limits_(clampMediaSourceLimits(options.limits)),
      descriptor_(std::move(descriptor)) {}

MediaSourcePreparedContext::~MediaSourcePreparedContext() = default;

MediaSourceBackendKind
MediaSourcePreparedContext::backendKind() const noexcept {
  return backendKind_;
}

const std::filesystem::path&
MediaSourcePreparedContext::localPath() const noexcept {
  return path_;
}

const MediaTrackSelection&
MediaSourcePreparedContext::selection() const noexcept {
  return selection_;
}

const MediaSourceLimits& MediaSourcePreparedContext::limits() const noexcept {
  return limits_;
}

const std::shared_ptr<const MediaSourceDescriptor>&
MediaSourcePreparedContext::descriptor() const noexcept {
  return descriptor_;
}

bool MediaSourcePreparedContext::matchesMainRequest(
    const std::filesystem::path& path,
    const MediaSourceOpenOptions& options,
    const std::shared_ptr<const MediaSourceDescriptor>& descriptor)
    const noexcept {
  try {
    return !path_.empty() && path == path_ && descriptor != nullptr &&
           descriptor.get() == descriptor_.get() &&
           equalSelection(options.selection, selection_) &&
           equalLimits(clampMediaSourceLimits(options.limits), limits_);
  } catch (...) {
    return false;
  }
}

bool MediaSourcePreparedContext::matchesPreviewBinding(
    const std::filesystem::path& path,
    const std::shared_ptr<const MediaSourceDescriptor>& descriptor)
    const noexcept {
  try {
    return !path_.empty() && path == path_ && descriptor != nullptr &&
           descriptor.get() == descriptor_.get();
  } catch (...) {
    return false;
  }
}

MediaPayloadLease::MediaPayloadLease(
    std::shared_ptr<const MediaPayloadStorage> storage) noexcept
    : storage_(std::move(storage)) {}

MediaPayloadLease::operator bool() const noexcept {
  return storage_ != nullptr;
}

std::size_t MediaPayloadLease::byteSize() const noexcept {
  return storage_ == nullptr ? 0 : storage_->byteSize();
}

std::span<const std::byte>
MediaPayloadLease::contiguousBytes() const noexcept {
  return storage_ == nullptr ? std::span<const std::byte>{}
                             : storage_->contiguousBytes();
}

bool MediaPayloadLease::copyBytes(
    std::size_t offset, std::span<std::byte> destination) const noexcept {
  return storage_ != nullptr && storage_->copyBytes(offset, destination);
}

const MediaTrackDescriptor* findMediaTrack(
    const MediaSourceDescriptor& descriptor, MediaTrackId id) noexcept {
  const auto found =
      std::find_if(descriptor.tracks.begin(), descriptor.tracks.end(),
                   [id](const MediaTrackDescriptor& track) {
                     return track.id == id;
                   });
  return found == descriptor.tracks.end() ? nullptr : &*found;
}

bool mediaVideoHasFullCodedAperture(
    const MediaVideoFormat& video) noexcept {
  if (!video.cleanAperture) {
    return true;
  }
  return rationalEqualsNonnegativeInteger(video.cleanAperture->width,
                                          video.codedWidth) &&
         rationalEqualsNonnegativeInteger(video.cleanAperture->height,
                                          video.codedHeight) &&
         video.cleanAperture->horizontalOffset == MediaRational{} &&
         video.cleanAperture->verticalOffset == MediaRational{};
}

bool mediaVideoHasSquarePixels(const MediaVideoFormat& video) noexcept {
  return video.pixelAspectNumerator == video.pixelAspectDenominator;
}

bool mediaVideoColorAdmitted(const MediaVideoFormat& video) noexcept {
  // BT.601 primaries admitted 2026-09-03. The BT.601 MATRIX was always
  // admitted below, so SD material was refused solely for declaring the
  // primaries that go with it -- while the identical stream with the primaries
  // tag ABSENT was admitted and then tagged SMPTE_C by VideoToolbox's own SD
  // inference anyway. The rule refused the honest file and passed the silent
  // one. Presentation carries them: the decoded-surface validator in
  // video_toolbox_decoder.mm admits SMPTE_C and EBU_3213, and the display
  // layer converts from the surface's own tag.
  const bool primaries =
      video.colorPrimaries == MediaColorPrimaries::Unknown ||
      video.colorPrimaries == MediaColorPrimaries::Bt601 ||
      video.colorPrimaries == MediaColorPrimaries::Bt709 ||
      video.colorPrimaries == MediaColorPrimaries::Bt2020;
  const bool transfer =
      video.transferFunction == MediaTransferFunction::Unknown ||
      video.transferFunction == MediaTransferFunction::Bt709 ||
      video.transferFunction == MediaTransferFunction::Pq ||
      video.transferFunction == MediaTransferFunction::Hlg;
  const bool matrix =
      video.matrixCoefficients == MediaMatrixCoefficients::Unknown ||
      video.matrixCoefficients == MediaMatrixCoefficients::Bt601 ||
      video.matrixCoefficients == MediaMatrixCoefficients::Bt709 ||
      video.matrixCoefficients == MediaMatrixCoefficients::Bt2020Ncl;
  const bool chroma =
      (video.topFieldChromaLocation == MediaChromaLocation::Unspecified ||
       video.topFieldChromaLocation == MediaChromaLocation::Left ||
       video.topFieldChromaLocation == MediaChromaLocation::Center) &&
      (video.bottomFieldChromaLocation == MediaChromaLocation::Unspecified ||
       video.bottomFieldChromaLocation == MediaChromaLocation::Left ||
       video.bottomFieldChromaLocation == MediaChromaLocation::Center);
  const bool depth = video.bitsPerComponent == 0 ||
                     video.bitsPerComponent == 8 ||
                     video.bitsPerComponent == 10;
  return primaries && transfer && matrix && chroma && depth &&
         !video.unsupportedColorMetadataPresent &&
         !video.dolbyVisionConfigurationPresent &&
         !video.ambientViewingEnvironmentPresent;
}

MediaDisplaySize mediaVideoDisplaySize(const MediaVideoFormat& video) noexcept {
  std::uint32_t width =
      video.displayWidth != 0 ? video.displayWidth : video.codedWidth;
  std::uint32_t height =
      video.displayHeight != 0 ? video.displayHeight : video.codedHeight;
  if (width == 0 || height == 0) {
    return {};
  }
  // Normalized before the test so a negative or over-turned value cannot slip
  // a swap decision past it; C++ integer remainder keeps the sign of the
  // dividend, which is why the second modulus is not redundant.
  const int rotation = ((video.rotationDegrees % 360) + 360) % 360;
  if (rotation == 90 || rotation == 270) {
    std::swap(width, height);
  }
  return {width, height};
}

MediaDisplaySize mediaSourceDisplaySize(
    const MediaSourceDescriptor& descriptor) noexcept {
  if (!descriptor.selectedVideo.has_value()) {
    return {};
  }
  const MediaTrackDescriptor* selected =
      findMediaTrack(descriptor, *descriptor.selectedVideo);
  if (selected == nullptr || !selected->video.has_value()) {
    return {};
  }
  return mediaVideoDisplaySize(*selected->video);
}

bool validateMediaSourceDescriptor(const MediaSourceDescriptor& descriptor,
                                   const MediaSourceLimits& limits,
                                   std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (!validDuration(descriptor.duration)) {
    assignError(error,
                "media source duration must be valid and nonnegative");
    return false;
  }
  const MediaSourceLimits effective = clampMediaSourceLimits(limits);
  const std::size_t inventorySum =
      static_cast<std::size_t>(descriptor.inventory.video) +
      static_cast<std::size_t>(descriptor.inventory.audio) +
      static_cast<std::size_t>(descriptor.inventory.subtitle) +
      static_cast<std::size_t>(descriptor.inventory.text) +
      static_cast<std::size_t>(descriptor.inventory.closedCaption) +
      static_cast<std::size_t>(descriptor.inventory.metadata);
  if (effective.maximumTracks == 0 || descriptor.inventory.total == 0 ||
      inventorySum != descriptor.inventory.total ||
      descriptor.inventory.total > effective.maximumTracks ||
      descriptor.tracks.size() > descriptor.inventory.total) {
    assignError(error, "media source exceeds the bounded track count");
    return false;
  }

  std::size_t aggregateConfigurationBytes = 0;
  std::array<std::size_t, 6> detailedKindCounts{};
  for (std::size_t index = 0; index < descriptor.tracks.size(); ++index) {
    const MediaTrackDescriptor& track = descriptor.tracks[index];
    if (track.id == 0 || !canonicalPositiveTimeBase(track.timeBase) ||
        !validDuration(track.duration)) {
      assignError(error, "media source contains an invalid track descriptor");
      return false;
    }
    const std::size_t kindIndex = static_cast<std::size_t>(track.kind);
    if (kindIndex >= detailedKindCounts.size() ||
        ++detailedKindCounts[kindIndex] >
            inventoryCount(descriptor.inventory, track.kind)) {
      assignError(error,
                  "detailed tracks exceed the enumerated track inventory");
      return false;
    }
    if (std::any_of(descriptor.tracks.begin() +
                        static_cast<std::ptrdiff_t>(index + 1),
                    descriptor.tracks.end(),
                    [&track](const MediaTrackDescriptor& candidate) {
                      return candidate.id == track.id;
                    })) {
      assignError(error, "media source contains duplicate track identifiers");
      return false;
    }
    if (track.language.size() > effective.maximumTrackTextBytes ||
        track.label.size() > effective.maximumTrackTextBytes) {
      assignError(error, "media source track text exceeds its memory bound");
      return false;
    }
    if (track.codecConfiguration.size() >
            effective.maximumCodecConfigurationBytes ||
        aggregateConfigurationBytes >
            effective.maximumCodecConfigurationBytes -
                track.codecConfiguration.size()) {
      assignError(error,
                  "media source codec configuration exceeds 256 KiB");
      return false;
    }
    aggregateConfigurationBytes += track.codecConfiguration.size();

    if ((track.codecConfiguration.empty() &&
         track.codecConfigurationKind !=
             MediaCodecConfigurationKind::None) ||
        (!track.codecConfiguration.empty() &&
         track.codecConfigurationKind ==
             MediaCodecConfigurationKind::None)) {
      assignError(error,
                  "media source codec configuration kind does not match its "
                  "bytes");
      return false;
    }

    switch (track.kind) {
    case MediaTrackKind::Video: {
      const bool selected = descriptor.selectedVideo == track.id;
      if (track.audio || (selected && !track.video) ||
          (track.video && !validVideoFormat(*track.video, effective))) {
        assignError(error, "media source contains an invalid video format");
        return false;
      }
      break;
    }
    case MediaTrackKind::Audio: {
      const bool selected = descriptor.selectedAudio == track.id;
      if (track.video || (selected && !track.audio) ||
          (track.audio && !validAudioFormat(*track.audio, effective))) {
        assignError(error, "media source contains an invalid audio format");
        return false;
      }
      break;
    }
    case MediaTrackKind::Subtitle:
    case MediaTrackKind::Text:
    case MediaTrackKind::ClosedCaption:
    case MediaTrackKind::Metadata:
      if (track.video || track.audio) {
        assignError(error,
                    "non-audiovisual track contains an audiovisual format");
        return false;
      }
      break;
    }
  }

  if (!validSelectedTrack(descriptor, descriptor.selectedVideo,
                          MediaTrackKind::Video) ||
      !validSelectedTrack(descriptor, descriptor.selectedAudio,
                          MediaTrackKind::Audio) ||
      !validSelectedTrack(descriptor, descriptor.selectedSubtitle,
                          MediaTrackKind::Subtitle)) {
    assignError(error, "media source selection does not match its track kind");
    return false;
  }
  return true;
}

bool validateMediaSample(const MediaSample& sample,
                         const MediaSourceDescriptor& descriptor,
                         const MediaSourceLimits& limits,
                         std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (sample.generation == 0 || sample.track == 0 ||
      !sample.presentationTime.valid() ||
      !validOptionalTime(sample.decodeTime) ||
      !validOptionalTime(sample.duration) ||
      (sample.duration.valid() && sample.duration.value < 0)) {
    assignError(error, "media sample has invalid identity or timing");
    return false;
  }
  const MediaTrackDescriptor* track =
      findMediaTrack(descriptor, sample.track);
  if (track == nullptr) {
    assignError(error, "media sample refers to an unknown track");
    return false;
  }
  const MediaSourceLimits effective = clampMediaSourceLimits(limits);

  switch (sample.kind) {
  case MediaSampleKind::EncodedVideo:
    if (track->kind != MediaTrackKind::Video || sample.sampleCount != 1 ||
        !sample.payload || sample.payload.byteSize() == 0 ||
        sample.payload.byteSize() > effective.maximumVideoSampleBytes) {
      assignError(error, "encoded video sample exceeds its stream contract");
      return false;
    }
    break;
  case MediaSampleKind::EncodedAudio:
    // A zero-sample CoreMedia marker is represented as a discontinuity event,
    // not as encoded audio. This keeps packet-description handling finite.
    if (track->kind != MediaTrackKind::Audio || !sample.payload ||
        sample.sampleCount == 0 ||
        sample.sampleCount > effective.maximumAudioSampleCount ||
        sample.payload.byteSize() == 0 ||
        sample.payload.byteSize() > effective.maximumAudioSampleBytes) {
      assignError(error, "encoded audio sample exceeds its stream contract");
      return false;
    }
    break;
  case MediaSampleKind::DecodedAudio:
    if (track->kind != MediaTrackKind::Audio || !sample.payload ||
        sample.sampleCount == 0 || sample.decodedAudioFrames == 0 ||
        sample.decodedAudioFrames > effective.maximumDecodedAudioFrames ||
        sample.payload.byteSize() == 0 ||
        sample.payload.byteSize() > effective.maximumDecodedAudioBytes) {
      assignError(error, "decoded audio sample exceeds its stream contract");
      return false;
    }
    break;
  }
  return true;
}

bool validateMediaDiscontinuity(
    const MediaDiscontinuity& discontinuity,
    const MediaSourceDescriptor& descriptor, std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (discontinuity.generation == 0 || discontinuity.track == 0 ||
      !discontinuity.time.valid() ||
      findMediaTrack(descriptor, discontinuity.track) == nullptr) {
    assignError(error, "media discontinuity has invalid identity or timing");
    return false;
  }
  return true;
}

}  // namespace wam::media
