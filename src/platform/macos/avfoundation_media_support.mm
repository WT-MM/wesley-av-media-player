#include "platform/macos/avfoundation_media_support.hpp"

#include "media/media_codec_facts.hpp"
#include "media/rbsp_bit_reader.hpp"
#include "media/video_codec_configuration.hpp"
#include "platform/macos/core_media_codec_facts.hpp"
#include "platform/macos/native_video_codec_capability.hpp"
#include "platform/macos/native_video_color.hpp"

#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>

namespace wam::macos {

using media::MediaCodec;
using media::MediaSourceLimits;
using media::MediaTrackDescriptor;
using media::MediaTrackId;
using media::MediaTrackKind;

std::string describeNSError(NSError* error, const char* fallback) {
  if (error == nil || error.localizedDescription == nil) {
    return fallback;
  }
  const char* text = error.localizedDescription.UTF8String;
  return text == nullptr ? fallback : std::string(text);
}

[[nodiscard]] MediaTrackId stableTrackId(AVAssetTrack* track,
                                         MediaTrackId fallback) noexcept {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  const CMPersistentTrackID raw = track.trackID;
#pragma clang diagnostic pop
  return raw > 0 ? static_cast<MediaTrackId>(raw) : fallback;
}

[[nodiscard]] std::optional<CMTimeRange> exactReaderTimeRangeFacts(
    CMTime duration, CMTime decodeStart) noexcept {
  if (!CMTIME_IS_NUMERIC(duration) || !CMTIME_IS_NUMERIC(decodeStart) ||
      (duration.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
      (decodeStart.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
      duration.epoch != 0 || decodeStart.epoch != 0 ||
      duration.timescale <= 0 || decodeStart.timescale <= 0 ||
      CMTimeCompare(duration, kCMTimeZero) < 0 ||
      CMTimeCompare(decodeStart, kCMTimeZero) < 0 ||
      CMTimeCompare(decodeStart, duration) > 0) {
    return std::nullopt;
  }
  const CMTime remaining = CMTimeSubtract(duration, decodeStart);
  if (!CMTIME_IS_NUMERIC(remaining) ||
      (remaining.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
      remaining.epoch != 0 || remaining.timescale <= 0 ||
      CMTimeCompare(remaining, kCMTimeZero) < 0) {
    return std::nullopt;
  }
  const CMTimeRange range = CMTimeRangeMake(decodeStart, remaining);
  if (!CMTIMERANGE_IS_VALID(range) ||
      (range.start.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
      (range.duration.flags & kCMTimeFlags_HasBeenRounded) != 0) {
    return std::nullopt;
  }
  return range;
}

[[nodiscard]] bool exactEditTime(CMTime time) noexcept {
  return CMTIME_IS_NUMERIC(time) &&
         (time.flags & kCMTimeFlags_HasBeenRounded) == 0 && time.epoch == 0 &&
         time.timescale > 0;
}

std::optional<CMTimeMapping> singleMediaEditMapping(
    NSArray* segments) noexcept {
  AVAssetTrackSegment* media = nil;
  NSUInteger index = 0;
  for (AVAssetTrackSegment* segment in segments) {
    if (segment.empty) {
      if (index != 0 || media != nil) {
        return std::nullopt;
      }
    } else {
      if (media != nil) {
        return std::nullopt;
      }
      media = segment;
    }
    ++index;
  }
  // A track with no media edit cannot be restated; a track with no edit list
  // reports one identity segment.
  if (media == nil) {
    return std::nullopt;
  }
  const CMTimeMapping mapping = media.timeMapping;
  if (!exactEditTime(mapping.target.start) ||
      !exactEditTime(mapping.source.start) ||
      !exactEditTime(mapping.target.duration) ||
      !exactEditTime(mapping.source.duration) ||
      CMTimeCompare(mapping.target.start, kCMTimeZero) < 0 ||
      // Rate 1.0 only. A stretched edit would make the shift a function of
      // time.
      CMTimeCompare(mapping.target.duration, mapping.source.duration) != 0) {
    return std::nullopt;
  }
  return mapping;
}

std::optional<AudioMovieTimelineFacts> audioMovieTimelineFactsFor(
    NSArray* segments) noexcept {
  const auto mapping = singleMediaEditMapping(segments);
  if (!mapping || CMTimeCompare(mapping->source.start, kCMTimeZero) < 0) {
    return std::nullopt;
  }
  const CMTime shift =
      CMTimeSubtract(mapping->target.start, mapping->source.start);
  if (!CMTIME_IS_NUMERIC(shift) ||
      (shift.flags & kCMTimeFlags_HasBeenRounded) != 0 || shift.epoch != 0 ||
      shift.timescale <= 0) {
    return std::nullopt;
  }
  return AudioMovieTimelineFacts{shift, mapping->target.start};
}

// The movie time at which a track's MEDIA begins, or the origin when it begins
// there. Nonzero exactly when the track carries a leading EMPTY EDIT.
//
// Fails safe to the origin.
[[nodiscard]] CMTime trackMediaStartOnMovieTimeline(NSArray* segments) noexcept {
  const auto facts = audioMovieTimelineFactsFor(segments);
  if (!facts || !exactEditTime(facts->mediaStart) ||
      CMTimeCompare(facts->mediaStart, kCMTimeZero) <= 0) {
    return kCMTimeZero;
  }
  return facts->mediaStart;
}

// The movie time a sync search must run from when the requested target lands
// inside a track's leading EMPTY EDIT, or empty to fail closed.
//
// Engaged for exactly one shape: a track whose media begins strictly after the
// movie origin (mediaStart > 0, i.e. it carries a leading empty edit) and a
// target that falls strictly inside that span. Every other invalid answer from
// samplePresentationTimeForTrackTime: -- a mid-stream hole, an unreadable or
// rate-stretched edit list, a track with no media edit -- still fails closed,
// which is why this takes the already-validated mediaStart rather than
// re-deciding admissibility.
[[nodiscard]] std::optional<CMTime> syncSearchTargetWithinLeadingEmptyEdit(
    CMTime target, CMTime mediaStart) noexcept {
  if (!CMTIME_IS_NUMERIC(target) || !CMTIME_IS_NUMERIC(mediaStart) ||
      CMTimeCompare(mediaStart, kCMTimeZero) <= 0 ||
      CMTimeCompare(target, mediaStart) >= 0) {
    return std::nullopt;
  }
  return mediaStart;
}

// Sample cursors are positioned and report timestamps in the track's own
// media timeline, while the seek target, the descriptor duration and the
// reader time range are all stated in the asset timeline. An edit list that
// offsets the media - which every composition-delayed H.264/HEVC track
// carries - separates the two, so map the target into media time before
// walking, and map the located full-sync sample back out of it. Both maps
// are exact or the caller fails closed on a non-numeric decode start.
CMTime fullSyncStart(AVAssetTrack* track, CMTime target,
                   const std::atomic<bool>* cancelled) noexcept {
  // A leading EMPTY EDIT declares a span of movie time before any of this
  // track's media exists, and AVFoundation answers
  // samplePresentationTimeForTrackTime: with kCMTimeInvalid inside it --
  // correctly, because no sample is mapped there. Every cold open asks for
  // exactly track time 0 (native_media_session.mm states an initial position
  // unconditionally), and such a file is spec-legal and plays in QuickTime.
  // The span is not a seek failure: it is the container saying the first
  // picture arrives a little after the origin. Search from the first movie
  // time this track actually has media at; the caller then clamps the result
  // back into the timeline contract's window.
  CMTime searchTarget = target;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CMTime mediaTarget =
      [track samplePresentationTimeForTrackTime:searchTarget];
  if (!CMTIME_IS_NUMERIC(mediaTarget)) {
    const auto retry = syncSearchTargetWithinLeadingEmptyEdit(
        target, trackMediaStartOnMovieTimeline(track.segments));
    if (!retry) {
      return kCMTimeInvalid;
    }
    searchTarget = *retry;
    mediaTarget = [track samplePresentationTimeForTrackTime:searchTarget];
  }
#pragma clang diagnostic pop
  if (!CMTIME_IS_NUMERIC(mediaTarget)) {
    return kCMTimeInvalid;
  }
  const CMTime mediaOffset = CMTimeSubtract(mediaTarget, searchTarget);
  AVSampleCursor* cursor =
      [track makeSampleCursorWithPresentationTimeStamp:mediaTarget];
  if (cursor == nil) {
    cursor = [track makeSampleCursorAtLastSampleInDecodeOrder];
  }
  bool everySampleLater = true;
  for (std::size_t step = 0;
       cursor != nil && step < kMaximumSyncCursorSteps; ++step) {
    // Decode order is not presentation order, and an open-GOP random-access
    // point proves it: the pictures that present just before a CRA are its
    // leading pictures, which follow it in decode order. Stepping back from
    // one therefore lands on a sync sample that presents *after* the point
    // the caller asked to start from -- 50.000 s for a 49.957 s request on
    // x265 output. Every caller needs a decode start at or before its
    // request (the audio priming window is measured from it, and the video
    // preroll is defined by it), so keep walking until presentation order
    // agrees. Closed-GOP H.264 satisfies this on the first full-sync
    // sample.
    if (cancelled != nullptr &&
        cancelled->load(std::memory_order_acquire)) {
      return kCMTimeInvalid;
    }
    const bool presentsByTarget =
        CMTimeCompare(cursor.presentationTimeStamp, mediaTarget) <= 0;
    if (cursor.currentSampleSyncInfo.sampleIsFullSync && presentsByTarget) {
      return CMTimeSubtract(cursor.presentationTimeStamp, mediaOffset);
    }
    everySampleLater = everySampleLater && !presentsByTarget;
    if ([cursor stepInDecodeOrderByCount:-1] == 0) {
      // The track's first sample, and nothing up to here presents at or
      // before the target: the media begins after it. Without an edit list,
      // H.264 composition offsets put the first picture after time 0 (ctts
      // 2000 on a 30000 timescale) -- the same shape as a leading empty edit,
      // so the first sync sample is the video origin. Samples decoded before
      // it (a stray SEI-only access unit) cannot present without it.
      for (; everySampleLater && step < kMaximumSyncCursorSteps; ++step) {
        if (CMTimeCompare(cursor.presentationTimeStamp, mediaTarget) <= 0) {
          break;
        }
        if (cursor.currentSampleSyncInfo.sampleIsFullSync) {
          return CMTimeSubtract(cursor.presentationTimeStamp, mediaOffset);
        }
        if ([cursor stepInDecodeOrderByCount:1] == 0) {
          break;
        }
      }
      break;
    }
  }
  return kCMTimeInvalid;
}


[[nodiscard]] static bool numberToUInt32(CFTypeRef value,
                                  std::uint32_t* result) noexcept {
  if (value == nullptr || result == nullptr ||
      CFGetTypeID(value) != CFNumberGetTypeID()) {
    return false;
  }
  std::int64_t converted = 0;
  if (!CFNumberGetValue(static_cast<CFNumberRef>(value),
                        kCFNumberSInt64Type, &converted) ||
      converted <= 0 ||
      static_cast<std::uint64_t>(converted) >
          std::numeric_limits<std::uint32_t>::max()) {
    return false;
  }
  *result = static_cast<std::uint32_t>(converted);
  return true;
}

[[nodiscard]] static bool numberToInt64Exact(CFTypeRef value,
                                      std::int64_t* result) noexcept {
  if (value == nullptr || result == nullptr ||
      CFGetTypeID(value) != CFNumberGetTypeID()) {
    return false;
  }
  auto number = static_cast<CFNumberRef>(value);
  if (CFNumberIsFloatType(number)) {
    double converted = 0.0;
    const double signedLimit = std::ldexp(1.0, 63);
    if (!CFNumberGetValue(number, kCFNumberFloat64Type, &converted) ||
        !std::isfinite(converted) || std::trunc(converted) != converted ||
        converted < -signedLimit || converted >= signedLimit) {
      return false;
    }
    const auto exact = static_cast<std::int64_t>(converted);
    if (static_cast<double>(exact) != converted) {
      return false;
    }
    *result = exact;
    return true;
  }
  return CFNumberGetValue(number, kCFNumberSInt64Type, result);
}

[[nodiscard]] static std::uint64_t unsignedMagnitude(std::int64_t value) noexcept {
  if (value >= 0) {
    return static_cast<std::uint64_t>(value);
  }
  return static_cast<std::uint64_t>(-(value + 1)) + 1;
}

[[nodiscard]] static std::optional<media::MediaRational> normalizedRational(
    std::int64_t numerator, std::int64_t signedDenominator) noexcept {
  if (signedDenominator <= 0) {
    return std::nullopt;
  }
  const std::uint64_t denominator =
      static_cast<std::uint64_t>(signedDenominator);
  const std::uint64_t divisor =
      std::gcd(unsignedMagnitude(numerator), denominator);
  return media::MediaRational{
      numerator / static_cast<std::int64_t>(divisor), denominator / divisor};
}

[[nodiscard]] static std::optional<media::MediaRational> copyExactRational(
    CFDictionaryRef dictionary, CFStringRef rationalKey,
    CFStringRef scalarKey) noexcept {
  CFTypeRef rationalValue = CFDictionaryGetValue(dictionary, rationalKey);
  if (rationalValue != nullptr) {
    if (CFGetTypeID(rationalValue) != CFArrayGetTypeID()) {
      return std::nullopt;
    }
    auto values = static_cast<CFArrayRef>(rationalValue);
    if (CFArrayGetCount(values) != 2) {
      return std::nullopt;
    }
    std::int64_t numerator = 0;
    std::int64_t denominator = 0;
    if (!numberToInt64Exact(CFArrayGetValueAtIndex(values, 0), &numerator) ||
        !numberToInt64Exact(CFArrayGetValueAtIndex(values, 1), &denominator)) {
      return std::nullopt;
    }
    return normalizedRational(numerator, denominator);
  }
  std::int64_t integer = 0;
  if (!numberToInt64Exact(CFDictionaryGetValue(dictionary, scalarKey),
                          &integer)) {
    return std::nullopt;
  }
  return media::MediaRational{integer, 1};
}

[[nodiscard]] static std::optional<media::MediaCleanAperture> copyCleanAperture(
    CMVideoFormatDescriptionRef format, std::uint32_t codedWidth,
    std::uint32_t codedHeight) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_CleanAperture);
  if (value == nullptr) {
    return media::MediaCleanAperture{
        {static_cast<std::int64_t>(codedWidth), 1},
        {static_cast<std::int64_t>(codedHeight), 1}, {0, 1}, {0, 1}};
  }
  if (CFGetTypeID(value) != CFDictionaryGetTypeID()) {
    return std::nullopt;
  }
  auto dictionary = static_cast<CFDictionaryRef>(value);
  const auto width = copyExactRational(
      dictionary, kCMFormatDescriptionKey_CleanApertureWidthRational,
      kCMFormatDescriptionKey_CleanApertureWidth);
  const auto height = copyExactRational(
      dictionary, kCMFormatDescriptionKey_CleanApertureHeightRational,
      kCMFormatDescriptionKey_CleanApertureHeight);
  const auto horizontal = copyExactRational(
      dictionary,
      kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational,
      kCMFormatDescriptionKey_CleanApertureHorizontalOffset);
  const auto vertical = copyExactRational(
      dictionary, kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational,
      kCMFormatDescriptionKey_CleanApertureVerticalOffset);
  if (!width || !height || !horizontal || !vertical ||
      width->numerator <= 0 || height->numerator <= 0) {
    return std::nullopt;
  }
  return media::MediaCleanAperture{*width, *height, *horizontal, *vertical};
}

[[nodiscard]] static bool extensionPresent(CMFormatDescriptionRef format,
                                    CFStringRef key) noexcept {
  return CMFormatDescriptionGetExtension(format, key) != nullptr;
}

[[nodiscard]] static bool stringEquals(CFTypeRef value,
                                CFStringRef expected) noexcept {
  return value != nullptr && expected != nullptr &&
         CFGetTypeID(value) == CFStringGetTypeID() &&
         CFEqual(value, expected);
}

[[nodiscard]] static media::MediaColorPrimaries copyColorPrimaries(
    CMVideoFormatDescriptionRef format, bool* unsupported) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_ColorPrimaries);
  if (value == nullptr) {
    return media::MediaColorPrimaries::Unknown;
  }
  // BT.2020 primaries are a MODELLED fact, not an opaque "unsupported
  // metadata" bit. mediaVideoColorAdmitted() owns the decision.
  //
  // SD-era primaries are a modelled fact on THIS route, not an opaque bit.
  // VideoToolbox attaches SMPTE_C / EBU_3213 verbatim to the decoded surface
  // (measured), the decoded-surface validator admits both, and the display
  // layer converts from the surface's own tag -- so the primaries the
  // container declares are the primaries WindowServer presents.
  //
  // SMPTE-C only, and the asymmetry is deliberate. The frozen contract has ONE
  // BT.601 primaries enumerator, but SMPTE-C (525) and EBU 3213 (625) are
  // different chromaticities. Every route that reaches VideoToolbox rebuilds
  // its format description from this model -- createFormatDescription() in
  // video_toolbox_decoder.mm, not CoreMedia's original -- so whatever this
  // returns must be spellable EXACTLY on the way back out, or the decoded
  // surface carries primaries the container never declared.
  //
  // Binding the one enumerator to SMPTE-C keeps colorPrimariesExtension() an
  // exact inverse. EBU 3213 therefore keeps its named refusal and falls back:
  // admitting it would mean emitting SMPTE-C for a stream that said 625, which
  // is a wrong-colour failure. Distinguishing them needs an appended
  // enumerator.
  if (const auto modelled = wam::macos::colorPrimariesForExtension(value)) {
    return *modelled;
  }
  *unsupported = true;
  if (stringEquals(value, kCMFormatDescriptionColorPrimaries_EBU_3213)) {
    return media::MediaColorPrimaries::Bt601;
  }
  return media::MediaColorPrimaries::OtherExplicit;
}

[[nodiscard]] static media::MediaTransferFunction copyTransferFunction(
    CMVideoFormatDescriptionRef format, bool* unsupported) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_TransferFunction);
  if (value == nullptr) {
    return media::MediaTransferFunction::Unknown;
  }
  // PQ and HLG are modelled facts. VideoToolbox resolves each to
  // a real CGColorSpace on the decoded surface ("Rec. ITU-R BT.2100 PQ" /
  // "... HLG", measured), which is what the display layer presents from.
  if (const auto modelled = wam::macos::transferFunctionForExtension(value)) {
    return *modelled;
  }
  *unsupported = true;
  if (stringEquals(value, kCMFormatDescriptionTransferFunction_sRGB)) {
    return media::MediaTransferFunction::Srgb;
  }
  return media::MediaTransferFunction::OtherExplicit;
}

[[nodiscard]] static media::MediaMatrixCoefficients copyMatrixCoefficients(
    CMVideoFormatDescriptionRef format, bool* unsupported) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_YCbCrMatrix);
  if (value == nullptr) {
    return media::MediaMatrixCoefficients::Unknown;
  }
  if (const auto modelled = wam::macos::ycbcrMatrixForExtension(value)) {
    return *modelled;
  }
  *unsupported = true;
  return media::MediaMatrixCoefficients::OtherExplicit;
}

[[nodiscard]] static media::MediaChromaLocation copyChromaLocation(
    CMVideoFormatDescriptionRef format, CFStringRef key,
    bool* unsupported) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(format, key);
  if (value == nullptr) {
    return media::MediaChromaLocation::Unspecified;
  }
  if (stringEquals(value, kCMFormatDescriptionChromaLocation_Left)) {
    return media::MediaChromaLocation::Left;
  }
  if (stringEquals(value, kCMFormatDescriptionChromaLocation_Center)) {
    return media::MediaChromaLocation::Center;
  }
  *unsupported = true;
  return media::MediaChromaLocation::OtherExplicit;
}

[[nodiscard]] static bool hasDolbyVisionConfiguration(
    CMVideoFormatDescriptionRef format) noexcept {
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
  if (extensions == nullptr) {
    return false;
  }
  CFTypeRef atoms = CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
  if (atoms == nullptr || CFGetTypeID(atoms) != CFDictionaryGetTypeID()) {
    return false;
  }
  auto dictionary = static_cast<CFDictionaryRef>(atoms);
  return CFDictionaryContainsKey(dictionary, CFSTR("dvcC")) ||
         CFDictionaryContainsKey(dictionary, CFSTR("dvvC")) ||
         CFDictionaryContainsKey(dictionary, CFSTR("dvwC"));
}

[[nodiscard]] static media::MediaVideoSampleFormat parseH264SampleFormat(
    std::span<const std::byte> configuration) noexcept {
  if (configuration.size() > 1 &&
      (configuration[1] == std::byte{110} || configuration[1] == std::byte{122} ||
       configuration[1] == std::byte{244})) {
    media::VideoCodecConfigurationLimits limits;
    limits.admitHighDynamicRangeColor = true;
    limits.admitHardwareH264Profiles = true;
    const auto result = media::inspectVideoCodecConfiguration(
        MediaCodec::H264, media::MediaCodecConfigurationKind::AvcC,
        configuration, limits);
    return result.admitted() ? result.facts->sampleFormat
                            : media::MediaVideoSampleFormat::Unsupported;
  }
  const auto bytes = std::span<const std::uint8_t>(
      reinterpret_cast<const std::uint8_t*>(configuration.data()),
      configuration.size());
  if (bytes.size() < 8 || bytes[0] != 1) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  const std::size_t spsCount = bytes[5] & 0x1fU;
  std::size_t offset = 6;
  if (spsCount == 0) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  for (std::size_t index = 0; index < spsCount; ++index) {
    if (offset + 2 > bytes.size()) {
      return media::MediaVideoSampleFormat::Unsupported;
    }
    const std::size_t length =
        (static_cast<std::size_t>(bytes[offset]) << 8U) | bytes[offset + 1];
    offset += 2;
    if (length < 5 || length > bytes.size() - offset ||
        (bytes[offset] & 0x1fU) != 7U) {
      return media::MediaVideoSampleFormat::Unsupported;
    }
    media::RbspBitReader bits(bytes.subspan(offset + 1, length - 1));
    const std::uint32_t profile = bits.readBits(8);
    bits.skipBits(16);       // constraint flags, level_idc
    bits.skipExpGolomb(1);   // seq_parameter_set_id
    if (!bits.ok() || profile != bytes[1] ||
        (profile != 66 && profile != 77 && profile != 88 && profile != 100)) {
      return media::MediaVideoSampleFormat::Unsupported;
    }
    if (profile == 100) {
      const std::uint32_t chromaFormat = bits.readUnsignedExpGolomb();
      const std::uint32_t lumaDepthMinusEight = bits.readUnsignedExpGolomb();
      const std::uint32_t chromaDepthMinusEight = bits.readUnsignedExpGolomb();
      if (!bits.ok() || chromaFormat != 1 || lumaDepthMinusEight != 0 ||
          chromaDepthMinusEight != 0) {
        return media::MediaVideoSampleFormat::Unsupported;
      }
    }
    offset += length;
  }
  return media::MediaVideoSampleFormat::Yuv420EightBit;
}

// vpcC (VPCodecConfigurationRecord, a full box):
//   0      version (must be 1)
//   1..3   flags
//   4      profile
//   5      level
//   6      bitDepth(4) | chromaSubsampling(3) | videoFullRangeFlag(1)
//   7..9   colourPrimaries / transferCharacteristics / matrixCoefficients
//   10..11 codecInitializationDataSize
// chromaSubsampling 0 and 1 are the two 4:2:0 chroma sitings; 2 (4:2:2) and
// 3 (4:4:4) have no bi-planar output surface in this lane.
[[nodiscard]] static media::MediaVideoSampleFormat parseVp9SampleFormat(
    std::span<const std::byte> configuration) noexcept {
  const auto bytes = std::span<const std::uint8_t>(
      reinterpret_cast<const std::uint8_t*>(configuration.data()),
      configuration.size());
  if (bytes.size() < 12 || bytes[0] != 1) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  const std::uint8_t bitDepth = static_cast<std::uint8_t>(bytes[6] >> 4U);
  const std::uint8_t chromaSubsampling =
      static_cast<std::uint8_t>((bytes[6] >> 1U) & 0x07U);
  if (chromaSubsampling > 1U) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  if (bitDepth == 8U) {
    return media::MediaVideoSampleFormat::Yuv420EightBit;
  }
  if (bitDepth == 10U) {
    return media::MediaVideoSampleFormat::Yuv420TenBit;
  }
  return media::MediaVideoSampleFormat::Unsupported;
}

// av1C (AV1CodecConfigurationRecord):
//   0 marker(1) | version(7)
//   1 seq_profile(3) | seq_level_idx_0(5)
//   2 seq_tier_0(1) | high_bitdepth(1) | twelve_bit(1) | monochrome(1) |
//     chroma_subsampling_x(1) | chroma_subsampling_y(1) |
//     chroma_sample_position(2)
//   3 reserved(3) | initial_presentation_delay_present(1) |
//     initial_presentation_delay_minus_one(4)
[[nodiscard]] static media::MediaVideoSampleFormat parseAv1SampleFormat(
    std::span<const std::byte> configuration) noexcept {
  const auto bytes = std::span<const std::uint8_t>(
      reinterpret_cast<const std::uint8_t*>(configuration.data()),
      configuration.size());
  if (bytes.size() < 4 || (bytes[0] & 0x80U) == 0U ||
      (bytes[0] & 0x7fU) != 1U) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  const bool highBitDepth = ((bytes[2] >> 6U) & 0x01U) != 0U;
  const bool twelveBit = ((bytes[2] >> 5U) & 0x01U) != 0U;
  const bool monochrome = ((bytes[2] >> 4U) & 0x01U) != 0U;
  const bool subsamplingX = ((bytes[2] >> 3U) & 0x01U) != 0U;
  const bool subsamplingY = ((bytes[2] >> 2U) & 0x01U) != 0U;
  if (monochrome || !subsamplingX || !subsamplingY || twelveBit) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  return highBitDepth ? media::MediaVideoSampleFormat::Yuv420TenBit
                      : media::MediaVideoSampleFormat::Yuv420EightBit;
}

[[nodiscard]] media::MediaVideoSampleFormat parseHevcSampleFormat(
    std::span<const std::byte> configuration) noexcept {
  media::VideoCodecConfigurationLimits limits;
  limits.admitHighDynamicRangeColor = true;
  const auto result = media::inspectVideoCodecConfiguration(
      MediaCodec::Hevc, media::MediaCodecConfigurationKind::HvcC,
      configuration, limits);
  return result.admitted() ? result.facts->sampleFormat
                : media::MediaVideoSampleFormat::Unsupported;
}

[[nodiscard]] CFDataRef borrowAtom(CMFormatDescriptionRef format,
                                   CFStringRef atomName) noexcept {
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
  if (extensions == nullptr) {
    return nullptr;
  }
  CFTypeRef atomsValue = CFDictionaryGetValue(
      extensions,
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
  if (atomsValue == nullptr ||
      CFGetTypeID(atomsValue) != CFDictionaryGetTypeID()) {
    return nullptr;
  }
  CFTypeRef atomValue = CFDictionaryGetValue(
      static_cast<CFDictionaryRef>(atomsValue), atomName);
  if (atomValue == nullptr || CFGetTypeID(atomValue) != CFDataGetTypeID()) {
    return nullptr;
  }
  return static_cast<CFDataRef>(atomValue);
}

[[nodiscard]] std::optional<std::vector<std::byte>> copyAtom(
    CMFormatDescriptionRef format, CFStringRef atomName,
    std::size_t maximumBytes) {
  CFDataRef data = borrowAtom(format, atomName);
  if (data == nullptr) {
    return std::nullopt;
  }
  const CFIndex signedLength = CFDataGetLength(data);
  if (signedLength <= 0 ||
      static_cast<std::uint64_t>(signedLength) > maximumBytes ||
      CFDataGetBytePtr(data) == nullptr) {
    return std::nullopt;
  }
  std::vector<std::byte> bytes(static_cast<std::size_t>(signedLength));
  std::memcpy(bytes.data(), CFDataGetBytePtr(data), bytes.size());
  return bytes;
}

// The codec a CoreMedia video subtype names, on THIS route.
//
// The four-character codes and the ProRes family live in the shared facts
// table; what this function adds is the AVFoundation route's own admission.
// Three video codecs the table knows reach this player only through its own
// demuxers -- VP8 and MPEG-4 Part 2 from Matroska, MPEG-2 from a transport
// stream -- and 'mp4v' in particular must stay Unknown here: AVFoundation
// reproduces VideoToolbox's Advanced Simple Profile failure on a plain mp4v
// MP4, so admitting it would fail mid-startup instead of falling back cleanly.
//
[[nodiscard]] MediaCodec videoCodec(CMVideoCodecType codec) noexcept {
  const MediaCodec named =
      media::mediaCodecForCoreMediaType(static_cast<std::uint32_t>(codec));
  if (!media::mediaCodecFacts(named).avfoundationVideoAdmitted) {
    return MediaCodec::Unknown;
  }
  // AV1 and VP9 are additionally gated on this machine: AVFoundation demuxes
  // and hardware-decodes av01-in-MP4 natively only on machines with an AV1
  // block, and VP9's supplemental decoder must be registered and reported
  // before the track is admitted. Without the block the codec stays Unknown so
  // the whole asset falls back.
  if (named == MediaCodec::Av1 && !nativeVideoToolboxSupportsAv1()) {
    return MediaCodec::Unknown;
  }
  if (named == MediaCodec::Vp9 && !nativeVp9StageAdmitted()) {
    return MediaCodec::Unknown;
  }
  return named;
}

// The coded sample format a video track's configuration record states, or empty
// for a codec this route cannot answer the question for.
//
// The switch is exhaustive and has no fall-through arm on purpose. An
// if-chain ending in parseHevcSampleFormat() hands whatever record an unnamed
// codec carries -- or its empty one -- to the hvcC parser; refusing is the only
// honest answer for a codec this route cannot classify.
//
// Recordless coded chroma remains Unknown; the decoder validates its explicit
// output surface contract independently.
[[nodiscard]] static std::optional<media::MediaVideoSampleFormat> parseSampleFormat(
    MediaCodec codec, std::span<const std::byte> configuration) noexcept {
  switch (codec) {
    case MediaCodec::H264:
      return parseH264SampleFormat(configuration);
    case MediaCodec::Hevc:
      return parseHevcSampleFormat(configuration);
    case MediaCodec::Vp9:
      return parseVp9SampleFormat(configuration);
    case MediaCodec::Av1:
      return parseAv1SampleFormat(configuration);
    case MediaCodec::ProRes4444:
    case MediaCodec::ProRes:
    case MediaCodec::Mjpeg:
      return media::MediaVideoSampleFormat::Unknown;
    // Every remaining enumerator is a codec videoCodec() never returns on this
    // route -- the three demuxer-only video codecs, every audio codec, and
    // Unknown itself -- so reaching here at all is a caller error rather than a
    // property of the stream, and it refuses.
    case MediaCodec::Vp8:
    case MediaCodec::Mpeg2Video:
    case MediaCodec::Mpeg4Visual:
    case MediaCodec::Aac:
    case MediaCodec::Alac:
    case MediaCodec::Mp3:
    case MediaCodec::Opus:
    case MediaCodec::Vorbis:
    case MediaCodec::Pcm:
    case MediaCodec::Ac3:
    case MediaCodec::Eac3:
    case MediaCodec::Flac:
    case MediaCodec::AdpcmIma:
    case MediaCodec::AdpcmMs:
    case MediaCodec::Dts:
    case MediaCodec::TrueHd:
    case MediaCodec::Mlp:
    case MediaCodec::Wma2:
    case MediaCodec::Unknown:
      return std::nullopt;
  }
  return std::nullopt;
}

[[nodiscard]] std::optional<media::MediaVideoFormat>
inspectVideoFormatFacts(
    CMVideoFormatDescriptionRef format, MediaCodec codec,
    std::span<const std::byte> configuration,
    const MediaSourceLimits& limits) noexcept {
  if (format == nullptr ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video ||
      videoCodec(CMFormatDescriptionGetMediaSubType(format)) != codec) {
    return std::nullopt;
  }

  const CMVideoDimensions dimensions =
      CMVideoFormatDescriptionGetDimensions(format);
  if (dimensions.width <= 0 || dimensions.height <= 0) {
    return std::nullopt;
  }
  const std::uint64_t width = static_cast<std::uint64_t>(dimensions.width);
  const std::uint64_t height = static_cast<std::uint64_t>(dimensions.height);
  if (!limits.codedDimensionsAdmitted(width, height)) {
    return std::nullopt;
  }

  const CGSize presentation =
      CMVideoFormatDescriptionGetPresentationDimensions(format, true, true);
  if (!std::isfinite(presentation.width) ||
      !std::isfinite(presentation.height) || presentation.width <= 0.0 ||
      presentation.height <= 0.0 ||
      presentation.width > std::numeric_limits<std::uint32_t>::max() ||
      presentation.height > std::numeric_limits<std::uint32_t>::max()) {
    return std::nullopt;
  }

  std::uint32_t pixelAspectNumerator = 1;
  std::uint32_t pixelAspectDenominator = 1;
  CFTypeRef pixelAspect = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_PixelAspectRatio);
  if (pixelAspect != nullptr) {
    if (CFGetTypeID(pixelAspect) != CFDictionaryGetTypeID() ||
        !numberToUInt32(CFDictionaryGetValue(
                            static_cast<CFDictionaryRef>(pixelAspect),
                            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing),
                        &pixelAspectNumerator) ||
        !numberToUInt32(CFDictionaryGetValue(
                            static_cast<CFDictionaryRef>(pixelAspect),
                            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing),
                        &pixelAspectDenominator)) {
      return std::nullopt;
    }
  }
  const std::uint32_t pixelAspectDivisor =
      std::gcd(pixelAspectNumerator, pixelAspectDenominator);
  pixelAspectNumerator /= pixelAspectDivisor;
  pixelAspectDenominator /= pixelAspectDivisor;

  auto cleanAperture = copyCleanAperture(
      format, static_cast<std::uint32_t>(width),
      static_cast<std::uint32_t>(height));
  if (!cleanAperture) {
    return std::nullopt;
  }

  std::uint8_t bitsPerComponent = 0;
  bool unsupportedColorMetadata = false;
  if (codec == MediaCodec::ProRes || codec == MediaCodec::ProRes4444) {
    // The opaque presentation contract retains ten bits per component.
    // Container BitsPerComponent may describe wider storage than coded samples.
    bitsPerComponent = 10;
  } else {
    CFTypeRef bits = CMFormatDescriptionGetExtension(
        format, kCMFormatDescriptionExtension_BitsPerComponent);
    if (bits != nullptr) {
      std::uint32_t exactBits = 0;
      if (!numberToUInt32(bits, &exactBits) || exactBits > 16) {
        return std::nullopt;
      }
      bitsPerComponent = static_cast<std::uint8_t>(exactBits);
      unsupportedColorMetadata = exactBits != 8 && exactBits != 10;
    }
  }

  std::uint8_t fieldCount = 0;
  CFTypeRef fieldCountValue = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_FieldCount);
  if (fieldCountValue != nullptr) {
    std::uint32_t exactFieldCount = 0;
    if (!numberToUInt32(fieldCountValue, &exactFieldCount) ||
        exactFieldCount > 2) {
      return std::nullopt;
    }
    fieldCount = static_cast<std::uint8_t>(exactFieldCount);
  }
  const bool fieldDetailPresent = extensionPresent(
      format, kCMFormatDescriptionExtension_FieldDetail);

  const media::MediaColorPrimaries colorPrimaries =
      copyColorPrimaries(format, &unsupportedColorMetadata);
  const media::MediaTransferFunction transferFunction =
      copyTransferFunction(format, &unsupportedColorMetadata);
  const media::MediaMatrixCoefficients matrixCoefficients =
      copyMatrixCoefficients(format, &unsupportedColorMetadata);
  const media::MediaChromaLocation topFieldChroma = copyChromaLocation(
      format, kCMFormatDescriptionExtension_ChromaLocationTopField,
      &unsupportedColorMetadata);
  const media::MediaChromaLocation bottomFieldChroma = copyChromaLocation(
      format, kCMFormatDescriptionExtension_ChromaLocationBottomField,
      &unsupportedColorMetadata);

  // The two HDR volume/light descriptions (and ambient viewing) are modelled
  // PRESENCE facts rather than the opaque "unsupported" bit, because
  // VideoToolbox copies them verbatim onto the decoded surface and the layer's
  // derived format description reproduces them byte for byte -- so they are
  // metadata this route delivers. Everything else below stays refused.
  const bool masteringDisplayPresent = extensionPresent(
      format, kCMFormatDescriptionExtension_MasteringDisplayColorVolume);
  const bool contentLightPresent = extensionPresent(
      format, kCMFormatDescriptionExtension_ContentLightLevelInfo);
  bool ambientViewingPresent = false;
  if (@available(macOS 12.0, *)) {
    ambientViewingPresent = extensionPresent(
        format, kCMFormatDescriptionExtension_AmbientViewingEnvironment);
  }

  unsupportedColorMetadata =
      unsupportedColorMetadata ||
      extensionPresent(format, kCMFormatDescriptionExtension_GammaLevel) ||
      extensionPresent(format, kCMFormatDescriptionExtension_ICCProfile) ||
      extensionPresent(
          format,
          kCMFormatDescriptionExtension_AlternativeTransferCharacteristics) ||
      (codec != MediaCodec::ProRes4444 &&
       (extensionPresent(format, kCMFormatDescriptionExtension_AlphaChannelMode) ||
        extensionPresent(format, kCMFormatDescriptionExtension_ContainsAlphaChannel)));
  if (@available(macOS 14.0, *)) {
    unsupportedColorMetadata =
        unsupportedColorMetadata ||
        extensionPresent(format,
                         kCMFormatDescriptionExtension_ContentColorVolume);
  }
  if (@available(macOS 14.2, *)) {
    unsupportedColorMetadata =
        unsupportedColorMetadata ||
        extensionPresent(format,
                         kCMFormatDescriptionExtension_LogTransferFunction);
  }

  const std::optional<media::MediaVideoSampleFormat> sampleFormatOrRefusal =
      parseSampleFormat(codec, configuration);
  if (!sampleFormatOrRefusal) {
    return std::nullopt;
  }
  const media::MediaVideoSampleFormat sampleFormat = *sampleFormatOrRefusal;
  // VP9 Profile 2 and AV1 Main 10 reach the same 10-bit bi-planar output
  // surface as HEVC Main 10, so they carry the identical contract: the parsed
  // depth must agree with the container's.
  if (codec == MediaCodec::Hevc || codec == MediaCodec::Vp9 ||
      codec == MediaCodec::Av1) {
    if (sampleFormat == media::MediaVideoSampleFormat::Unsupported) {
      return std::nullopt;
    }
    const std::uint8_t parsedBits =
        static_cast<std::uint8_t>(media::mediaSampleFormatDepth(sampleFormat));
    // Main 10 carries the same colour contract as Main (including
    // BT.2020/PQ/HLG), decided once by mediaVideoColorAdmitted(): no colour
    // question depends on the depth, so this check asks only the depth
    // question. VideoToolbox's decoded-frame attachments are still validated
    // again before any frame is leased.
    if (bitsPerComponent != 0 && bitsPerComponent != parsedBits) {
      return std::nullopt;
    }
  }

  media::MediaVideoFormat video;
  video.codedWidth = static_cast<std::uint32_t>(width);
  video.codedHeight = static_cast<std::uint32_t>(height);
  video.displayWidth =
      static_cast<std::uint32_t>(std::llround(presentation.width));
  video.displayHeight =
      static_cast<std::uint32_t>(std::llround(presentation.height));
  video.pixelAspectNumerator = pixelAspectNumerator;
  video.pixelAspectDenominator = pixelAspectDenominator;
  video.bitsPerComponent = bitsPerComponent;
  video.progressive =
      !fieldDetailPresent && (fieldCount == 0 || fieldCount == 1);
  video.fieldCount = fieldCount;
  video.fieldDetailPresent = fieldDetailPresent;
  video.cleanAperture = *cleanAperture;
  video.colorPrimaries = colorPrimaries;
  video.transferFunction = transferFunction;
  video.matrixCoefficients = matrixCoefficients;
  video.topFieldChromaLocation = topFieldChroma;
  video.bottomFieldChromaLocation = bottomFieldChroma;
  video.unsupportedColorMetadataPresent = unsupportedColorMetadata;
  CFTypeRef range = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_FullRangeVideo);
  video.fullRangeVideo = range && CFEqual(range, kCFBooleanTrue);

  video.masteringDisplayColorVolumePresent = masteringDisplayPresent;
  video.contentLightLevelInfoPresent = contentLightPresent;
  video.ambientViewingEnvironmentPresent = ambientViewingPresent;
  if (@available(macOS 12.0, *)) {
    video.ambientViewingEnvironmentPayload = ambientViewingEnvironmentPayload(
        CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_AmbientViewingEnvironment));
  }
  video.dolbyVisionConfigurationPresent =
      hasDolbyVisionConfiguration(format);
  video.sampleFormat = sampleFormat;
  return video;
}

[[nodiscard]] bool videoFormatMatchesTrack(
    CMVideoFormatDescriptionRef format, const MediaTrackDescriptor& track,
    const MediaSourceLimits& requestedLimits) noexcept {
  if (format == nullptr || track.kind != MediaTrackKind::Video ||
      !track.video ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video ||
      videoCodec(CMFormatDescriptionGetMediaSubType(format)) != track.codec) {
    return false;
  }
  // A record-less codec has no atom to borrow or compare, so the record
  // equality below is vacuous for it and the codec-plus-facts comparison is the
  // whole check. Its descriptor's record is empty by contract (proven at
  // admission and re-proven by supportedVideoTrack), so an EMPTY span is the
  // honest thing to hand inspectVideoFormatFacts -- exactly what admission
  // handed it.
  //
  // The atom NAME comes from the shared facts table, so AV1 and VP9 (which
  // videoCodec() admits on a capable machine) compare their own av1C/vpcC
  // rather than an assumed avcC/hvcC.
  const media::MediaCodecFacts& facts = media::mediaCodecFacts(track.codec);
  std::span<const std::byte> configuration;
  if (!facts.carriesConfigurationRecord) {
    if (!track.codecConfiguration.empty()) {
      return false;
    }
  } else {
    const CFStringRef atomName = coreMediaConfigurationAtomName(track.codec);
    if (atomName == nullptr) {
      return false;
    }
    CFDataRef data = borrowAtom(format, atomName);
    if (data == nullptr) {
      return false;
    }
    const CFIndex length = CFDataGetLength(data);
    const UInt8* bytes = CFDataGetBytePtr(data);
    if (length <= 0 || bytes == nullptr ||
        static_cast<std::uint64_t>(length) !=
            track.codecConfiguration.size() ||
        std::memcmp(bytes, track.codecConfiguration.data(),
                    track.codecConfiguration.size()) != 0) {
      return false;
    }
    configuration = std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(bytes),
        static_cast<std::size_t>(length));
  }
  const MediaSourceLimits limits =
      media::clampMediaSourceLimits(requestedLimits);
  const auto video = inspectVideoFormatFacts(format, track.codec,
                                             configuration, limits);
  if (!video) {
    return false;
  }
  // Rotation is a TRACK fact, not a format fact. inspectVideoFormatFacts reads
  // only the CMVideoFormatDescription, which carries no container transform,
  // so it always reports the unrotated defaults; comparing those against a
  // rotated descriptor would fail every rotated file here and report it as
  // "the format changed".
  //
  // So the two rotation fields are excluded from THIS comparison and proven
  // where they actually live: selectedFormatsRebindBeforeReader re-reads the
  // track's preferredTransform and requires it to still state exactly the
  // angle the descriptor recorded. Between the two, every field is still
  // checked exactly once, and the equality below stays total over everything
  // the format description does describe.
  media::MediaVideoFormat expected = *track.video;
  expected.rotationDegrees = video->rotationDegrees;
  expected.identityTransform = video->identityTransform;
  return *video == expected;
}

}  // namespace wam::macos
