#include "media/native_late_frame_trace.hpp"
#include "media/startup_benchmark.hpp"
#include <fstream>
#include "media/audio_track_admission.hpp"
#include "native_audio_admission.hpp"
#include "media/mjpeg_admission.hpp"
#include "avfoundation_media_source.hpp"
#include "avfoundation_media_support.hpp"

#include "media/adpcm_audio.hpp"
#include "media/adpcm_decoder.hpp"
#include "media/matroska_apple_audio.hpp"
#include "media/audio_codec_timing.hpp"
#include "media/codec/aac.hpp"
#include "media/codec/mpeg_audio.hpp"
#include "media/media_codec_facts.hpp"
#include "media/video_codec_configuration.hpp"
#include "core_media_codec_facts.hpp"
#include "core_media_source_support.hpp"
#include "native_custom_source_core.hpp"
#include "native_audio_channel_map.hpp"
#include "native_video_codec_capability.hpp"
#include "native_video_color.hpp"
#include "video_quarter_turn.hpp"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <mutex>
#include <numeric>
#include <span>
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

constexpr std::size_t kMaximumAdmissionPrefixBuffers{64};
// AVFoundation closes each track output with a short marker tail: two or three
// payload-free buffers per lane. The bound only keeps a hypothetical marker
// storm from turning one read into an unbounded loop.
constexpr std::size_t kMaximumMediaFreeMarkers{64};

// Frames one access unit of a codec whose ASBD declares no fixed packet size
// may decode to. AVFoundation states mFramesPerPacket = 0 for a variable-frame
// codec and carries the real count per packet instead
// (mVariableFramesInPacket), which the converter already reads. The priming
// arithmetic below runs BEFORE any packet is read, so it needs a bound rather
// than the count: Opus's largest legal packet is 120 ms, which is 5760 frames
// at its fixed 48 kHz internal rate and the largest such packet at any admitted
// rate. Using the bound only ever places the reader earlier and the proof
// ceiling stricter, both of which fail closed.
constexpr std::int64_t kMaximumVariableAccessUnitFrames{5'760};

// Additional units by which the reader time range is placed early. Given a
// range start, AVFoundation may begin an audio track output at the access unit
// boundary at or after it rather than at the unit containing it (observed up
// to one unit late on edited MP4 assets). The slack keeps the guarantee above
// intact; it is never assumed - the staged unit is always measured against the
// exact priming ceiling before any proof is stated.
constexpr std::int64_t kAudioReaderStartSlackAccessUnits{2};

// Exact audio boundaries an accurate-seek generation needs before it reads.
// searchFloor is the latest media time the reader may start at; proofCeiling
// is the latest first-access-unit timestamp that still leaves the full
// media::kAudioPrimingAccessUnits of decoded-and-discarded audio ahead of the
// generation's first audible frame A = ceil(T*R)/R.
struct AudioPrimingPlan {
  MediaTime searchFloor{};
  MediaTime proofCeiling{};
};

[[nodiscard]] std::optional<AudioPrimingPlan> audioPrimingPlanFacts(
    const MediaTrackDescriptor& audio, MediaTime target) noexcept {
  const auto exactRate =
      audio.audio ? media::exactAudioSampleRate(audio.audio->sampleRate)
                  : std::nullopt;
  if (!exactRate) {
    return std::nullopt;
  }
  const std::uint32_t sampleRate = *exactRate;
  // A codec whose packets carry no fixed frame count declares zero here and
  // states the count per packet instead. Bound it rather than refusing the
  // generation; see kMaximumVariableAccessUnitFrames.
  const auto framesPerPacket =
      audio.audio->framesPerPacket == 0
          ? kMaximumVariableAccessUnitFrames
          : static_cast<std::int64_t>(audio.audio->framesPerPacket);
  if (framesPerPacket <= 0 ||
      framesPerPacket > media::kMaximumAudioFramesPerPacket) {
    return std::nullopt;
  }
  // A stays exactly the accurate-seek ceiling frame; only the decode start
  // moves earlier, which is precisely the window the converter discards.
  const auto presentationStart = media::audioFrameAtOrAfter(target, sampleRate);
  const std::optional<std::int64_t> presentationFrame =
      presentationStart
          ? media::exactAudioFrameIndex(*presentationStart, sampleRate)
          : std::optional<std::int64_t>{};
  if (!presentationFrame || *presentationFrame < 0) {
    return std::nullopt;
  }
  const std::int64_t searchBackoff =
      media::audioPrimingFrames(framesPerPacket) +
      kAudioReaderStartSlackAccessUnits * framesPerPacket;
  const auto floorFrame = static_cast<std::int64_t>(
      std::max<std::int64_t>(*presentationFrame - searchBackoff, 0));
  const std::int64_t ceilingFrame =
      media::audioPrimingCeilingFrame(*presentationFrame, framesPerPacket);
  const auto scale = static_cast<std::int32_t>(sampleRate);
  return AudioPrimingPlan{MediaTime{floorFrame, scale},
                          MediaTime{ceilingFrame, scale}};
}

[[nodiscard]] bool trueAttachment(CMSampleBufferRef sample,
                                  CFStringRef key) noexcept {
  CFTypeRef raw = CMGetAttachment(sample, key, nullptr);
  return raw != nullptr && CFGetTypeID(raw) == CFBooleanGetTypeID() &&
         CFBooleanGetValue(static_cast<CFBooleanRef>(raw));
}

// The exact media-timeline extent of one compressed audio access unit: the
// frame count its own packet decodes to, over the stream's sample rate. An
// invalid time means the sample does not state one unambiguously (not audio,
// no stream description, a non-integral rate, or a codec whose packets carry
// no fixed frame count and no per-packet count for this exact entry).
[[nodiscard]] CMTime naturalAudioPacketDuration(CMSampleBufferRef sample,
                                                CMItemCount entries,
                                                CMItemCount index) noexcept {
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
  if (format == nullptr ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio) {
    return kCMTimeInvalid;
  }
  const AudioStreamBasicDescription* asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(
          static_cast<CMAudioFormatDescriptionRef>(format));
  const auto exactRate =
      asbd ? media::exactAudioSampleRate(asbd->mSampleRate) : std::nullopt;
  if (!exactRate) {
    return kCMTimeInvalid;
  }
  const auto timescale = static_cast<std::int32_t>(*exactRate);
  std::uint32_t frames = asbd->mFramesPerPacket;
  // A per-packet frame count only names one access unit when the timing array
  // states one entry per access unit; a single shared entry describes them all
  // and only the stream's fixed packet size can speak for it.
  const CMItemCount samples = CMSampleBufferGetNumSamples(sample);
  if (entries == samples && index >= 0 && index < samples) {
    const AudioStreamPacketDescription* packets = nullptr;
    std::size_t packetBytes = 0;
    if (CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
            sample, &packets, &packetBytes) == noErr &&
        packets != nullptr &&
        static_cast<std::size_t>(index) <
            packetBytes / sizeof(AudioStreamPacketDescription) &&
        packets[static_cast<std::size_t>(index)].mVariableFramesInPacket != 0) {
      frames =
          packets[static_cast<std::size_t>(index)].mVariableFramesInPacket;
    }
  }
  if (frames == 0) {
    return kCMTimeInvalid;
  }
  return CMTimeMake(static_cast<std::int64_t>(frames), timescale);
}

// Restates a compressed audio sample's per-access-unit durations on the
// codec's own ordinal media grid, and returns how many entries it restated.
//
// A muxer folds an edit's end trim into the container: it shortens the final
// access unit's stts duration so that the track's declared media duration
// lands exactly on the edited end. CoreMedia surfaces that shortfall twice --
// once as the short input duration and once as the TrimDurationAtEnd
// attachment this backend removes. Dropping only the attachment would publish
// an access unit whose stated media-timeline extent is smaller than the frames
// its own packet decodes to, which is an edit left in the timing, not a
// media-timeline fact.
//
// On its own media timeline compressed audio occupies an exact ordinal grid:
// every access unit is exactly its packet's frame count long. So a truncated
// unit is republished at that exact natural extent. This only ever lengthens a
// unit, only up to the size its own packet description already declares, and
// never touches a unit the container states in full -- it cannot turn a
// genuinely malformed grid into a well-formed one, and it cannot hide a
// decoder fault.
[[nodiscard]] std::size_t restateCompressedAudioPacketDurations(
    CMSampleBufferRef sample, CMSampleTimingInfo* timing,
    std::size_t entries) noexcept {
  if (sample == nullptr || timing == nullptr) {
    return 0;
  }
  std::size_t restated = 0;
  for (std::size_t index = 0; index < entries; ++index) {
    CMSampleTimingInfo& entry = timing[index];
    if (!CMTIME_IS_NUMERIC(entry.duration) || entry.duration.value <= 0) {
      continue;
    }
    const CMTime natural = naturalAudioPacketDuration(
        sample, static_cast<CMItemCount>(entries),
        static_cast<CMItemCount>(index));
    if (!CMTIME_IS_NUMERIC(natural) || natural.value <= 0 ||
        CMTimeCompare(entry.duration, natural) >= 0) {
      continue;
    }
    entry.duration = natural;
    ++restated;
  }
  return restated;
}

// The open-time cursor proof below establishes the ordinal grid over ALL
// packets. Here the nearest ordinal locates a packet after an arbitrary seek;
// it is not itself the continuity proof. Edits are applied only afterwards.
[[nodiscard]] std::size_t projectCompressedAudioPacketTiming(
    CMSampleBufferRef sample, CMSampleTimingInfo* timing,
    std::size_t entries) noexcept {
  if (!sample || !timing) return 0;
  const auto format = CMSampleBufferGetFormatDescription(sample);
  if (!format || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio) return 0;
  const auto* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
  constexpr std::uint32_t kAacFrames = media::codec::kAacLcSamplesPerAccessUnit;
  if (!asbd || asbd->mFormatID != kAudioFormatMPEG4AAC ||
      asbd->mFramesPerPacket != kAacFrames) return 0;
  const auto exactRate = media::exactAudioSampleRate(asbd->mSampleRate);
  if (!exactRate) return 0;
  const std::uint32_t rate = *exactRate;
  std::size_t changed = 0;
  for (std::size_t i = 0; i < entries; ++i) {
    auto& entry = timing[i];
    const auto pts = entry.presentationTimeStamp;
    if (!CMTIME_IS_NUMERIC(pts) || pts.value < 0 || static_cast<std::uint32_t>(pts.timescale) != rate) continue;
    const auto ordinal =
        (static_cast<std::uint64_t>(pts.value) + kAacFrames / 2) / kAacFrames;
    const auto projected = media::projectAacPacketGrid({pts.value, pts.timescale}, 0, ordinal, rate);
    if (!projected) continue;
    if (pts.value != projected->value || CMTimeCompare(entry.duration, CMTimeMake(kAacFrames, rate))) ++changed;
    entry.presentationTimeStamp = CMTimeMake(projected->value, rate);
    entry.duration = CMTimeMake(kAacFrames, rate);
  }
  return changed;
}

// The most media time one staged audio sample may carry.
//
// Chosen against the PCM ring, which is what has to absorb the event:
// NativePcmRing is kSlabCount(16) * kFramesPerSlab(4096) == 65,536 frames,
// ~1.365 s at 48 kHz. A staged event must fit that with room to spare, and it
// must be short enough that the merged read gate reopens well within the video
// lane's own read-ahead (kLaneReadAheadEvents == 24 events, ~0.8 s at 30 fps),
// so the video decoder is never starved between two audio events. 256 ms is
// about a fifth of the ring and about a third of the video read-ahead, and it
// is ~12 AAC access units, well above the 1-2 units a normally interleaved
// container vends.
constexpr double kMaximumStagedAudioSeconds = 0.256;

// How many access units of the given per-unit duration fit inside
// kMaximumStagedAudioSeconds. Returns 0 when the duration is not usable, and
// the caller then applies no time bound at all.
[[nodiscard]] CMItemCount audioUnitsWithinStagedDuration(
    CMTime perUnitDuration) noexcept {
  if (!CMTIME_IS_NUMERIC(perUnitDuration)) {
    return 0;
  }
  const double perUnit = CMTimeGetSeconds(perUnitDuration);
  if (!(perUnit > 0.0)) {
    return 0;
  }
  const double fitting = kMaximumStagedAudioSeconds / perUnit;
  if (!(fitting >= 1.0)) {
    // A single access unit already exceeds the bound. One unit is still the
    // smallest publishable sample, so publish it rather than stalling.
    return 1;
  }
  return static_cast<CMItemCount>(fitting);
}

// The same bound applied to a batch. Audio access units are constant-duration
// within a batch for every codec this backend admits, so unit 0's duration is
// the batch's per-unit duration.
[[nodiscard]] CMItemCount audioBatchUnitsWithinStagedDuration(
    CMSampleBufferRef sample) noexcept {
  if (sample == nullptr) {
    return 0;
  }
  CMSampleTimingInfo timing{};
  if (CMSampleBufferGetSampleTimingInfo(sample, 0, &timing) != noErr) {
    return 0;
  }
  return audioUnitsWithinStagedDuration(timing.duration);
}

// How many access units of an audio batch this backend may publish as one
// staged sample, starting at cursor.
//
// AVFoundation batches a track output into CMSampleBuffers of whatever size its
// reader chose, and the size is a property of the container rather than of the
// codec: 84 MPEG frames (48 KiB), 21 FLAC blocks (27 KiB), 140 AAC units
// (70 KiB) -- and, for standalone LPCM, 96001 whole frames in ONE buffer of
// 384004 bytes. Native v1 states its own bound on both counts
// (MediaSourceLimits::maximumAudioSampleCount / maximumAudioSampleBytes)
// because a staged sample is one unit of backpressure and one converter fill,
// so the reader's batch is re-cut to fit before anything else touches it.
//
// This states a LENGTH only. Nothing here computes a timestamp: the actual cut
// is CMSampleBufferCopySampleBufferForRange, which re-bases the packet
// descriptions and the timing itself (measured: an LPCM asset re-cut at 1024
// reproduces 960000 units and 3840000 bytes exactly, and an MP3 asset re-cut at
// 32 reproduces every packet offset and per-unit duration).
//
// The bound is stated in MEDIA TIME as well as in memory, because a staged
// sample is one unit of backpressure and the dispatcher's audio lane is
// capacity-one: a backpressured audio consumer closes the MERGED read gate
// (native_media_dispatcher.cpp, "the audio lane keeps capacity-one semantics on
// purpose ... resolved by the output's own slab-retirement wake within one
// buffer period"), and this backend reads both tracks through ONE AVAssetReader,
// so an audio event the PCM ring cannot absorb starves the VIDEO lane for as
// long as it takes to drain. A batch's size in media time is a property of the
// container's interleaving, not of the codec: a normally interleaved MP4 vends
// 1-2 AAC units (~21-43 ms), but a NON-interleaved one -- the whole audio track
// written as a single contiguous run -- vends 140 units at once, 2.9867 s, more
// than twice the ring's guaranteed capacity, and video starves while the audio
// clock runs on. Bounding the staged duration is what makes the capacity-one
// rule's own precondition true.
//
// Returns zero when the batch cannot be cut exactly -- a variable-size codec
// whose packet descriptions are missing, or a single access unit already over
// the byte bound -- and the caller then fails the generation closed rather than
// publishing a sample the staging bounds would reject anyway.
[[nodiscard]] CMItemCount audioBatchChunkLength(
    CMSampleBufferRef sample, CMItemCount cursor, CMItemCount units,
    const MediaSourceLimits& limits) noexcept {
  if (sample == nullptr || cursor < 0 || units <= 0 || cursor >= units) {
    return 0;
  }
  const auto maximumUnits =
      static_cast<CMItemCount>(limits.maximumAudioSampleCount);
  if (maximumUnits <= 0) {
    return 0;
  }
  const CMItemCount remaining = units - cursor;
  CMItemCount length = remaining < maximumUnits ? remaining : maximumUnits;
  const CMItemCount timeBound = audioBatchUnitsWithinStagedDuration(sample);
  if (timeBound > 0 && length > timeBound) {
    length = timeBound;
  }

  const AudioStreamPacketDescription* packets = nullptr;
  std::size_t packetBytes = 0;
  const bool described =
      CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
          sample, &packets, &packetBytes) == noErr &&
      packets != nullptr &&
      packetBytes / sizeof(AudioStreamPacketDescription) ==
          static_cast<std::size_t>(units);
  if (!described) {
    // No per-packet description means a fixed packet size, which the format
    // must then declare. LPCM is this case and states four bytes a frame.
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    const AudioStreamBasicDescription* asbd =
        format != nullptr &&
                CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio
            ? CMAudioFormatDescriptionGetStreamBasicDescription(
                  static_cast<CMAudioFormatDescriptionRef>(format))
            : nullptr;
    if (asbd == nullptr || asbd->mBytesPerPacket == 0) {
      return 0;
    }
    const auto fitting = static_cast<CMItemCount>(
        limits.maximumAudioSampleBytes / asbd->mBytesPerPacket);
    if (fitting <= 0) {
      return 0;
    }
    return length < fitting ? length : fitting;
  }

  std::size_t bytes = 0;
  CMItemCount fitting = 0;
  for (CMItemCount index = 0; index < length; ++index) {
    const auto& packet = packets[static_cast<std::size_t>(cursor + index)];
    if (packet.mDataByteSize == 0 ||
        packet.mDataByteSize > limits.maximumAudioSampleBytes - bytes) {
      break;
    }
    bytes += packet.mDataByteSize;
    ++fitting;
  }
  return fitting;
}

// True exactly for a CMSampleBuffer that carries no media this backend can
// publish on the track's own timeline. Two shapes qualify, and AVFoundation
// emits both as the terminal marker tail of every track output of an
// edit-list asset:
//
//   * No access units, no payload and no presentation time at all. These
//     carry only decoder control (DrainAfterDecoding,
//     PostNotificationWhenConsumed) for the reader-owned decoder native v1
//     does not use.
//   * No access units, no payload, and an EmptyMedia/PermanentEmptyMedia flag.
//     These state the end of the *edited* timeline: their timestamp is the
//     asset's edited duration in the movie timescale, which is not a position
//     on the track's media timeline at all.
//
// A payload-free buffer that states an exact time and claims no empty media is
// an ordinary discontinuity marker and is deliberately excluded, so the
// staging path keeps owning format-change detection.
[[nodiscard]] bool mediaFreeMarker(CMSampleBufferRef sample) noexcept {
  if (sample == nullptr) {
    return false;
  }
  if (CMSampleBufferGetNumSamples(sample) != 0 ||
      CMSampleBufferGetDataBuffer(sample) != nullptr) {
    return false;
  }
  return !CMTIME_IS_NUMERIC(CMSampleBufferGetPresentationTimeStamp(sample)) ||
         trueAttachment(sample, kCMSampleBufferAttachmentKey_EmptyMedia) ||
         trueAttachment(sample,
                        kCMSampleBufferAttachmentKey_PermanentEmptyMedia);
}


#if defined(WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING)
std::atomic<std::size_t> g_inspectedAudioChannelLayoutSize{
    std::numeric_limits<std::size_t>::max()};
#endif

[[nodiscard]] bool validAudioChannelLayout(
    const AudioChannelLayout* layout, std::size_t layoutSize,
    std::uint32_t channels,
    AudioChannelLayoutTag* acceptedTag = nullptr) noexcept {
  if (acceptedTag != nullptr) {
    *acceptedTag = 0;
  }
  if (layout == nullptr) {
    return layoutSize == 0;
  }

  // AudioChannelLayout is a variable-length wire structure. In particular,
  // CoreMedia may expose a tag-only layout as just the 12-byte prefix even
  // though the C declaration includes one trailing placeholder description.
  // Read only fields proven present by the byte count, then validate the
  // count-derived payload size before interpreting the layout identity.
  constexpr std::size_t prefixSize =
      offsetof(AudioChannelLayout, mChannelDescriptions);
  if (layoutSize < prefixSize) {
    return false;
  }

  const auto* bytes = reinterpret_cast<const std::byte*>(layout);
  AudioChannelLayoutTag tag{0};
  AudioChannelBitmap bitmap{0};
  std::uint32_t descriptionCount{0};
  std::memcpy(&tag, bytes + offsetof(AudioChannelLayout, mChannelLayoutTag),
              sizeof(tag));
  std::memcpy(&bitmap, bytes + offsetof(AudioChannelLayout, mChannelBitmap),
              sizeof(bitmap));
  std::memcpy(&descriptionCount,
              bytes + offsetof(AudioChannelLayout,
                               mNumberChannelDescriptions),
              sizeof(descriptionCount));

  constexpr std::size_t descriptionSize = sizeof(AudioChannelDescription);
  const std::size_t descriptionsSize =
      static_cast<std::size_t>(descriptionCount) * descriptionSize;
  if ((descriptionCount != 0 &&
       descriptionsSize / descriptionSize != descriptionCount) ||
      descriptionsSize >
          std::numeric_limits<std::size_t>::max() - prefixSize) {
    return false;
  }
  const std::size_t describedSize =
      prefixSize + descriptionsSize;
  // Accept both encodings emitted by Apple APIs for a zero-description
  // canonical tag: the compact prefix and the declared one-placeholder C
  // object. Every other payload must exactly match its declared count.
  const bool exactStorage =
      descriptionCount == 0
          ? (layoutSize == prefixSize ||
             layoutSize == sizeof(AudioChannelLayout))
          : layoutSize == describedSize;
  if (!exactStorage || descriptionCount != 0 || bitmap != 0) {
    return false;
  }

  // Native audio v1 carries only the scalar tag, so layouts whose identity
  // depends on a bitmap or description payload cannot be compared exactly on
  // later samples. Mono and stereo are the two fixed layouts the output chain
  // consumes directly; aliases, custom, reserved, and variable-count layouts
  // still fail closed above.
  //
  // Wider layouts are admitted exactly when the shared downmix stage can state
  // the fold for them; the tag goes through audioChannelLayoutAdmitted, the
  // predicate the converter and the other routes apply. The decision is made on the TAG'S EXPANSION -- label by
  // label, never by channel index -- because AudioToolbox emits a different
  // channel ORDER per codec family for the identical 5.1 content (see the
  // table in native_audio_channel_map.hpp). Nothing here folds anything: the
  // backend still decodes the FULL native width and the converter applies
  // media::applyStereoDownmix using the decoder's OWN reported output layout,
  // which is the only description of the bytes it actually writes. A tag whose
  // expansion contains any unmapped label is refused whole, which is a clean
  // mpv fallback rather than a silently dropped channel.
  media::MediaAudioFormat format;
  format.channels = channels;
  format.channelLayoutPresent = true;
  format.channelLayoutTag = tag;
  const bool accepted = audioChannelLayoutAdmitted(format);
  if (accepted && acceptedTag != nullptr) {
    *acceptedTag = tag;
  }
  return accepted;
}

[[nodiscard]] std::optional<MediaTime> canonicalDuration(CMTime time) noexcept {
  const auto converted = exactMediaTime(time);
  if (!converted || converted->value < 0) {
    return std::nullopt;
  }
  return converted;
}

[[nodiscard]] bool exactZero(CMTime time) noexcept {
  return CMTIME_IS_NUMERIC(time) &&
         (time.flags & kCMTimeFlags_HasBeenRounded) == 0 && time.epoch == 0 &&
         time.timescale > 0 && time.value == 0;
}

[[nodiscard]] bool preservesZeroBasedTrackTimelineFacts(
    CMTimeRange trackRange, std::string* error) {
  if (!CMTIMERANGE_IS_VALID(trackRange) || !exactZero(trackRange.start) ||
      !CMTIME_IS_NUMERIC(trackRange.duration) ||
      (trackRange.duration.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
      trackRange.duration.epoch != 0 || trackRange.duration.timescale <= 0 ||
      CMTimeCompare(trackRange.duration, kCMTimeZero) < 0) {
    assignError(error,
                "offset or inexact track timeline is outside native v1");
    return false;
  }
  return true;
}

// The first whole audio frame at or after `time`, as an exact rational whose
// timescale IS the sample rate. std::nullopt when the input is not an exact
// edit time or the count does not fit.
//
// WHY THIS EXISTS. Every audio access unit's movie stamp is its media stamp
// plus one constant shift, and the entire audio path -- window, converter,
// clock, IPF proof -- is stated in exact whole frames at the track's sample
// rate. A container may legitimately declare an edit whose start is not a whole
// number of audio frames, because its movie timescale need not divide the
// sample rate: Android writes a movie timescale of 10000, so a leading empty
// edit of 192 units is 19.2 ms, and 19.2 ms * 48000 Hz = 921.6 frames. Left
// alone that puts EVERY audio stamp of the track six tenths of a sample off the
// grid, exactAudioFrameIndex refuses the window, audioGenerationWindow returns
// no window at all, and the generation timeline cannot be derived -- which is
// the whole file falling back for a fifth of a millisecond of arithmetic.
//
// The restatement is the first whole frame AT OR AFTER the declared time. That
// is the same boundary audioFrameAtOrAfter already picks for the window's
// presentation start, so decode start, presentation start and media start
// agree by construction instead of by luck. The motion is bounded by one
// sample (20.8 us at 48 kHz), it is applied only when the declared time is not
// already on the grid, and it is exact -- an integer frame count over the
// sample rate, with no floating point and nothing else rounded.
// The arithmetic itself is the neutral contract's audioFrameAtOrAfter, reused
// rather than restated: it is the function whose answer this has to match, and
// duplicating a rounding rule is how two of them drift apart.
[[nodiscard]] std::optional<CMTime> audioFrameAlignedEditTime(
    CMTime time, std::uint32_t sampleRate) noexcept {
  if (!exactEditTime(time) || sampleRate == 0) {
    return std::nullopt;
  }
  const auto exact = exactMediaTime(time);
  if (!exact) {
    return std::nullopt;
  }
  const auto aligned = media::audioFrameAtOrAfter(*exact, sampleRate);
  if (!aligned) {
    return std::nullopt;
  }
  return exactCMTime(*aligned);
}

// The exact constant that carries a track's MEDIA-timeline stamps onto the
// MOVIE timeline: the `target.start - source.start` of its one media edit.
//
// Same shape analysis and the same reason as trackMediaStartOnMovieTimeline
// above. Zero for a container with no edit list at all, where the two
// timelines are the same timeline. A multi-segment or rate-stretched list is
// not a constant displacement and is refused at admission before this is
// asked (see the video edit-list gate at generation start).
[[nodiscard]] CMTime trackMovieTimelineShift(NSArray* segments) noexcept {
  const auto facts = audioMovieTimelineFactsFor(segments);
  if (!facts || !exactEditTime(facts->shift)) {
    return kCMTimeZero;
  }
  return facts->shift;
}

// Carries one MEDIA-timeline stamp onto the MOVIE timeline.
//
// AVFoundation states every compressed sample twice: the track's own MEDIA
// timeline as its input timing, and the asset's edited MOVIE timeline as its
// OUTPUT timing. VideoToolbox decodes whichever buffer it is handed but reports
// each decoded frame at that buffer's OUTPUT stamp, so a video lane that
// publishes the input stamp states its compressed samples on one timeline and
// receives its decoded frames on another. The two differ by exactly this shift,
// which is zero only when the container carries no edit list; on a
// head-trimmed edit list the input stamps would land decoded frames at
// negative movie times the consumer refuses.
//
// Every other quantity a compressed sample is measured against is already the
// MOVIE timeline -- the seek target, the presentation floor, the reader's time
// range, the descriptor duration -- so compressed samples are restated onto it
// too.
//
// The shift is the container's own exact rational, so a stamp that cannot carry
// it exactly is refused rather than rounded: that is what keeps the frame grid
// exact. A non-numeric stamp (a compressed access unit legitimately carries no
// decode stamp) and a stamp in a later epoch are both returned unchanged.
[[nodiscard]] std::optional<CMTime> restatedOnMovieTimeline(
    CMTime stamp, CMTime shift) noexcept {
  if (!CMTIME_IS_NUMERIC(stamp) || stamp.epoch != 0) {
    return stamp;
  }
  if (!CMTIME_IS_NUMERIC(shift) || shift.epoch != 0) {
    return std::nullopt;
  }
  const CMTime moved = CMTimeAdd(stamp, shift);
  if (!CMTIME_IS_NUMERIC(moved) ||
      (moved.flags & kCMTimeFlags_HasBeenRounded) != 0 || moved.epoch != 0 ||
      moved.timescale <= 0) {
    return std::nullopt;
  }
  return moved;
}

// Republishes one compressed video access unit on the MOVIE timeline, so that
// the statement this backend makes about a picture is on the same clock as the
// decoded frame VideoToolbox will hand back for it. Returns a +1 reference, or
// null when the unit cannot be restated exactly.
//
// The retimed copy is a TIMING copy only: the block buffer, the format
// description and the sample attachments are carried across by CoreMedia, so
// the sync attachment that both the decoder and native_video_consumer read is
// still the container's own. The copy is load-bearing rather than a
// convenience: the consumer hands this very buffer to VideoToolbox and proves
// its stamps against the staged sample facts, so the buffer itself must state
// the movie timeline.
[[nodiscard]] CMSampleBufferRef restatedVideoOnMovieTimeline(
    CMSampleBufferRef sample, CMTime shift) noexcept {
  if (sample == nullptr) {
    return nullptr;
  }
  // The zero shift is every container whose media and movie timelines are the
  // same timeline. Nothing to restate, and the hot path keeps its pass-through:
  // no copy, no allocation, no retiming.
  //
  // A buffer that is not exactly one access unit is a timed discontinuity
  // marker that survived the marker tail. It carries no picture and no timing
  // array, so it passes through here and the staging lane restates its one
  // stamp (makeHead).
  if (CMTimeCompare(shift, kCMTimeZero) == 0 ||
      CMSampleBufferGetNumSamples(sample) != 1) {
    CFRetain(sample);
    return sample;
  }
  CMSampleTimingInfo timing{};
  CMItemCount entries = 0;
  if (CMSampleBufferGetSampleTimingInfoArray(sample, 1, &timing, &entries) !=
          noErr ||
      entries != 1) {
    return nullptr;
  }
  auto presentation =
      restatedOnMovieTimeline(timing.presentationTimeStamp, shift);
  // The decode stamp moves with the presentation stamp or not at all: their
  // displacement is the codec's reorder distance, which the edit list does not
  // touch and which VideoToolbox reads to order its output.
  const auto decode = restatedOnMovieTimeline(timing.decodeTimeStamp, shift);
  if (!presentation || !decode) {
    return nullptr;
  }
  // An edit that begins INSIDE a frame reaches this route as a trim
  // attachment: the picture covering the movie origin is stated at its own
  // media start with the leading part trimmed, and the duration the timing
  // array carries is already the trimmed one. The presented interval on the
  // movie timeline therefore begins at the restated stamp PLUS the trim --
  // AVFoundation's own output statement of the same frame -- and without the
  // trim the frame would be stated as ending exactly at the origin, covering
  // nothing, and a seek to the origin could never be satisfied.
  if (CFTypeRef trim = CMGetAttachment(
          sample, kCMSampleBufferAttachmentKey_TrimDurationAtStart, nullptr);
      trim != nullptr && CFGetTypeID(trim) == CFDictionaryGetTypeID()) {
    const CMTime trimStart =
        CMTimeMakeFromDictionary(static_cast<CFDictionaryRef>(trim));
    if (CMTIME_IS_NUMERIC(trimStart) &&
        CMTimeCompare(trimStart, kCMTimeZero) > 0) {
      presentation = restatedOnMovieTimeline(*presentation, trimStart);
      if (!presentation) {
        return nullptr;
      }
    }
  }
  timing.presentationTimeStamp = *presentation;
  timing.decodeTimeStamp = *decode;
  CMSampleBufferRef restated = nullptr;
  if (CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sample, 1,
                                            &timing, &restated) != noErr ||
      restated == nullptr) {
    if (restated != nullptr) {
      CFRelease(restated);
    }
    return nullptr;
  }
  // The trim is now applied to the stamps, so the attachments that annotated
  // it are redundant and are dropped rather than left for a downstream reader
  // to apply a second time.
  CMRemoveAttachment(restated, kCMSampleBufferAttachmentKey_TrimDurationAtStart);
  CMRemoveAttachment(restated, kCMSampleBufferAttachmentKey_TrimDurationAtEnd);
  // The decoded frame's timestamp is the OUTPUT stamp VideoToolbox reports
  // back, so state it explicitly as the restated presentation stamp instead of
  // inheriting whatever the copy carried forward. After this the buffer states
  // one timeline in both of its voices, which is the whole point.
  if (CMSampleBufferSetOutputPresentationTimeStamp(
          restated, CMSampleBufferGetPresentationTimeStamp(restated)) !=
      noErr) {
    CFRelease(restated);
    return nullptr;
  }
  return restated;
}

// True for a path that is the codec's OWN bare elementary stream rather than a
// container. See audioDecoderLeadInShift for what turns on it. Kept to the
// three codecs that state a nonzero decoder lead-in, because it is only their
// arithmetic this decides; every other extension is a container and answers
// false.
[[nodiscard]] bool bareAudioElementaryStream(
    const std::filesystem::path& path) noexcept {
  std::string extension = path.extension().string();
  for (char& character : extension) {
    character = static_cast<char>(
        std::tolower(static_cast<unsigned char>(character)));
  }
  return extension == ".mp3" || extension == ".ac3" || extension == ".eac3" ||
         extension == ".ec3";
}

// CoreMedia omits WAV ADPCM coefficient cookies; inspect bounded RIFF chunks
// at admission, before any packet or callback can observe the format.
[[nodiscard]] bool validateWaveAdpcm(const MediaTrackDescriptor &track,
                                     const std::filesystem::path &path,
                                     std::string *error) {
  if (track.codec != MediaCodec::AdpcmIma && track.codec != MediaCodec::AdpcmMs)
    return true;
  auto refuse = [&](const char *reason) {
    assignError(error, reason);
    return false;
  };
  std::ifstream file(path, std::ios::binary);
  std::array<std::byte, 50> bytes{};
  file.read(reinterpret_cast<char *>(bytes.data()), 12);
  if (file.gcount() != 12 || std::memcmp(bytes.data(), "RIFF", 4) != 0 ||
      std::memcmp(bytes.data() + 8, "WAVE", 4) != 0)
    return refuse("AdpcmWaveFormatFactsUnavailable");
  const auto read32 = [&](unsigned offset) {
    return media::matroska::appleAudioInteger(bytes, offset, 4, true);
  };
  const std::uint64_t end = std::uint64_t(read32(4)) + 8;
  std::error_code ec;
  if (end > std::filesystem::file_size(path, ec) || ec)
    return refuse("AdpcmWaveBoundsInvalid");
  std::uint64_t offset = 12;
  for (unsigned chunks = 0; chunks < 4096 && offset + 8 <= end; ++chunks) {
    file.seekg(static_cast<std::streamoff>(offset));
    file.read(reinterpret_cast<char *>(bytes.data()), 8);
    if (file.gcount() != 8)
      return refuse("AdpcmWaveBoundsInvalid");
    const auto size = read32(4);
    if (size > end - offset - 8)
      return refuse("AdpcmWaveBoundsInvalid");
    if (std::memcmp(bytes.data(), "fmt ", 4) == 0) {
      if (size != 20 && size != 50)
        return refuse("AdpcmWaveFormatUnsupported");
      file.read(reinterpret_cast<char *>(bytes.data()), size);
      if (file.gcount() != size)
        return refuse("AdpcmWaveBoundsInvalid");
      const auto &f = *track.audio;
      const auto parsed = media::matroska::appleAudioPacketFormat(
          "A_MS/ACM", std::span(bytes).first(size),
          static_cast<std::uint32_t>(f.sampleRate), f.channels, 4);
      if (parsed.codec != track.codec ||
          parsed.format.bytesPerPacket != f.bytesPerPacket ||
          parsed.blockFrames != f.framesPerPacket)
        return refuse("AdpcmWaveFormatMismatch");
      const media::AdpcmFormat format{
          static_cast<std::uint16_t>(f.formatTag & 0xffffU), f.channels,
          f.bytesPerPacket, f.framesPerPacket};
      if (const auto e = media::validateAdpcmFormat(format))
        return refuse(e);
      return true;
    }
    offset += 8 + std::uint64_t(size) + (size & 1U);
  }
  return refuse("AdpcmWaveFormatFactsUnavailable");
}

[[nodiscard]] std::optional<media::codec::Mp3LameGapless> mp3LsfGapless(
    const MediaTrackDescriptor& audio, const std::filesystem::path& path) {
  if (audio.codec != MediaCodec::Mp3 || !audio.audio ||
      audio.audio->framesPerPacket != 576 || !bareAudioElementaryStream(path)) {
    return {};
  }
  std::ifstream input(path, std::ios::binary);
  std::array<std::byte, 4096> bytes{};
  input.read(reinterpret_cast<char*>(bytes.data()), 10);
  if (input.gcount() != 10) return {};
  std::uint32_t offset = 0;
  if (bytes[0] == std::byte{'I'} && bytes[1] == std::byte{'D'} &&
      bytes[2] == std::byte{'3'}) {
    for (std::size_t i = 6; i < 10; ++i) {
      const auto value = std::to_integer<std::uint32_t>(bytes[i]);
      if (value > 127) return {};
      offset = (offset << 7U) | value;
    }
    offset += 10;
    if ((std::to_integer<unsigned>(bytes[5]) & 16U) != 0) offset += 10;
  }
  input.seekg(offset);
  input.read(reinterpret_cast<char*>(bytes.data()), bytes.size());
  auto result = media::codec::inspectMp3LsfGapless(
      std::span(bytes).first(static_cast<std::size_t>(input.gcount())));
  if (result && result->sampleRate != audio.audio->sampleRate) return {};
  return result;
}

// The EXTRA movie-timeline shift a selected audio track needs, on top of the
// one its container's edit list already states, so that the DECODER's output
// lands where the container says the content is.
//
// Every route that reaches this converter has to place access unit 0 exactly
// `leadIn` frames BEFORE the presentation origin, because the converter labels
// the decoder's first output frame `packet0 + leadIn` and the session then
// proves the first published frame against the presentation floor. Matroska
// gets it for free from CodecDelay; MPEG-TS applies it itself in
// mpegts_media_source.mm. AVFoundation is the third case, and it is the only
// one where the answer depends on what the file IS.
//
// MEASURED, by reading the media edit AVFoundation reports for the same
// content in different carriers: a raw MPEG audio stream states
// src.start = 576 (the LAME encoder delay); the same audio in a QuickTime
// movie states 1105 (576 encoder + 529 DECODER, exactly the CodecDelay ffmpeg
// writes to Matroska); a raw AC-3 stream states 0; AC-3 in a QuickTime movie
// states 256 (the AC-3 decoder delay).
//
// So a REAL container edit already expresses the whole offset from the packet
// grid to the presentation timeline, decoder delay included, and must be left
// exactly alone. A bare elementary stream has no edit list at all: what
// AVFoundation reports for one is either nothing, or -- for MP3 -- a segment it
// synthesises from the file's own Xing/LAME tag, which describes the ENCODER
// and nothing else. That is the case, and the only case, where the decoder
// lead-in still has to be subtracted here. FLAC, LPCM and AAC state a zero
// lead-in and are untouched by construction.
//
// Empty means the arithmetic is not exactly representable, which fails closed.
[[nodiscard]] std::optional<CMTime> audioDecoderLeadInShift(
    const MediaTrackDescriptor& audio,
    const std::filesystem::path& path) noexcept {
  const std::int64_t leadIn =
      media::mediaCodecFacts(audio.codec).decoderLeadInFrames;
  if (leadIn == 0 || !bareAudioElementaryStream(path)) {
    return kCMTimeZero;
  }
  if (!audio.audio) {
    return std::nullopt;
  }
  const auto rate = media::exactAudioSampleRate(audio.audio->sampleRate);
  if (!rate) {
    return std::nullopt;
  }
  return CMTimeMake(leadIn, static_cast<std::int32_t>(*rate));
}

[[nodiscard]] bool preservesZeroBasedTrackTimeline(
    AVAssetTrack* track, std::string* error) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  const CMTimeRange trackRange = track.timeRange;
#pragma clang diagnostic pop
  return preservesZeroBasedTrackTimelineFacts(trackRange, error);
}

// The codec an AudioFormatID names on this route: the shared admitted-tag
// table, minus the two flavours AVFoundation is not measured for here. MPEG
// Layer II and Vorbis reach this player only through its own demuxers.
[[nodiscard]] MediaCodec audioCodec(AudioFormatID codec) noexcept {
  if (codec == kAudioFormatMPEGLayer2) {
    return MediaCodec::Unknown;
  }
  for (const AdmittedAudioFormatTag& entry : kAdmittedAudioFormatTags) {
    if (entry.formatTag == codec && entry.codec != MediaCodec::Vorbis) {
      return entry.codec;
    }
  }
  return MediaCodec::Unknown;
}

[[nodiscard]] std::optional<MediaTrackDescriptor> inspectVideoFormatImpl(
    CMVideoFormatDescriptionRef format, MediaTrackId trackId,
    MediaTime duration, const MediaSourceLimits& requestedLimits,
    std::string* error) {
  const MediaSourceLimits limits = media::clampMediaSourceLimits(requestedLimits);
  if (format == nullptr || trackId == 0 ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video) {
    assignError(error, "invalid CoreMedia video format");
    return std::nullopt;
  }
  const CMVideoCodecType subtype = CMFormatDescriptionGetMediaSubType(format);
  const MediaCodec codec = videoCodec(subtype);
  if (codec == MediaCodec::Unknown) {
    assignError(error, "AVFoundation video codec is outside native v1");
    return std::nullopt;
  }
  // "No atom name" is not a synonym for "unknown codec" here. A QuickTime
  // ProRes or JPEG sample description carries only descriptive extensions
  // (Depth, BitsPerComponent, Vendor); there is nothing to copy, and an empty
  // record is the correct descriptor rather than a missing one.
  const media::MediaCodecFacts& facts = media::mediaCodecFacts(codec);
  std::optional<std::vector<std::byte>> configuration;
  if (!facts.carriesConfigurationRecord) {
    configuration.emplace();
  } else {
    const CFStringRef atomName = coreMediaConfigurationAtomName(codec);
    if (atomName == nullptr) {
      assignError(error, "AVFoundation video codec is outside native v1");
      return std::nullopt;
    }
    configuration =
        copyAtom(format, atomName, limits.maximumCodecConfigurationBytes);
    if (!configuration) {
      assignError(error,
                  "video format lacks a bounded avcC/hvcC/vpcC/av1C atom");
      return std::nullopt;
    }
  }
  if (codec == MediaCodec::Hevc && configuration->size() > 16 &&
      (std::to_integer<unsigned>((*configuration)[16]) & 3U) == 3U) {
    assignError(error, "Hevc444SurfaceContractUnsupported");
    return std::nullopt;
  }
  auto video = inspectVideoFormatFacts(format, codec, *configuration, limits);
  if (!video) {
    assignError(error,
                "video format metadata/configuration is outside native v1");
    return std::nullopt;
  }

  MediaTrackDescriptor track;
  track.id = trackId;
  track.kind = MediaTrackKind::Video;
  track.codec = codec;
  track.timeBase = {1, 600};
  track.duration = duration;
  track.codecConfigurationKind = facts.configurationKind;
  track.codecConfiguration = std::move(*configuration);
  track.video = std::move(*video);
  return track;
}

[[nodiscard]] std::optional<MediaTrackDescriptor> inspectAudioFormatImpl(
    CMAudioFormatDescriptionRef format, MediaTrackId trackId,
    MediaTime duration, const MediaSourceLimits& requestedLimits,
    std::string* error) {
  const MediaSourceLimits limits = media::clampMediaSourceLimits(requestedLimits);
  if (format == nullptr || trackId == 0 ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio) {
    assignError(error, "invalid CoreMedia audio format");
    return std::nullopt;
  }
  const AudioStreamBasicDescription* asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(format);
  if (asbd == nullptr || !std::isfinite(asbd->mSampleRate) ||
      asbd->mSampleRate <= 0.0 ||
      asbd->mSampleRate > limits.maximumAudioSampleRate ||
      asbd->mChannelsPerFrame == 0 ||
      asbd->mChannelsPerFrame > limits.maximumAudioChannels ||
      asbd->mFormatID == 0) {
    assignError(error, "audio ASBD is outside native bounds");
    return std::nullopt;
  }
  const MediaCodec codec = audioCodec(asbd->mFormatID);

  std::size_t cookieSize = 0;
  const void* cookie = CMAudioFormatDescriptionGetMagicCookie(format,
                                                               &cookieSize);
  if (cookieSize > limits.maximumCodecConfigurationBytes ||
      (cookieSize != 0 && cookie == nullptr)) {
    assignError(error, "audio magic cookie exceeds native bounds");
    return std::nullopt;
  }

  if (asbd->mFormatID == kAudioFormatMPEG4AAC_HE ||
      asbd->mFormatID == kAudioFormatMPEG4AAC_HE_V2) {
    assignError(error, media::codec::kHeAacDecoderDelayRefusal);
    return std::nullopt;
  }
  if (codec == MediaCodec::Aac && cookieSize != 0) {
    AudioFormatInfo info{*asbd, cookie, static_cast<UInt32>(cookieSize)};
    std::array<AudioFormatListItem, 8> formats{};
    UInt32 size = sizeof(formats);
    if (AudioFormatGetProperty(kAudioFormatProperty_FormatList, sizeof(info),
                              &info, &size, formats.data()) == noErr &&
        size <= sizeof(formats) && size % sizeof(AudioFormatListItem) == 0) {
      for (std::size_t i = 0; i < size / sizeof(AudioFormatListItem); ++i) {
        if (formats[i].mASBD.mFormatID == kAudioFormatMPEG4AAC_HE ||
            formats[i].mASBD.mFormatID == kAudioFormatMPEG4AAC_HE_V2) {
          assignError(error, media::codec::kHeAacDecoderDelayRefusal);
          return std::nullopt;
        }
      }
    }
  }
  MediaTrackDescriptor track;
  track.id = trackId;
  track.kind = MediaTrackKind::Audio;
  track.codec = codec;
  const double roundedRate = std::round(asbd->mSampleRate);
  track.timeBase =
      roundedRate >= 1.0 &&
              roundedRate <= std::numeric_limits<std::int32_t>::max()
          ? MediaTime{1, static_cast<std::int32_t>(roundedRate)}
          : MediaTime{1, 1};
  track.duration = duration;
  if (cookieSize != 0) {
    track.codecConfigurationKind =
        MediaCodecConfigurationKind::AudioMagicCookie;
    track.codecConfiguration.resize(cookieSize);
    std::memcpy(track.codecConfiguration.data(), cookie, cookieSize);
  }

  media::MediaAudioFormat audio;
  audio.sampleRate = asbd->mSampleRate;
  audio.channels = asbd->mChannelsPerFrame;
  audio.formatTag = asbd->mFormatID;
  audio.formatFlags = asbd->mFormatFlags;
  audio.framesPerPacket = asbd->mFramesPerPacket;
  audio.bytesPerPacket = asbd->mBytesPerPacket;
  audio.bytesPerFrame = asbd->mBytesPerFrame;
  audio.bitsPerChannel = asbd->mBitsPerChannel;
  audio.interleaved =
      (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
  std::size_t layoutSize = 0;
  const AudioChannelLayout* layout =
      CMAudioFormatDescriptionGetChannelLayout(format, &layoutSize);
#if defined(WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING)
  g_inspectedAudioChannelLayoutSize.store(layoutSize,
                                          std::memory_order_relaxed);
#endif
  AudioChannelLayoutTag layoutTag{0};
  if (!validAudioChannelLayout(layout, layoutSize, audio.channels,
                               &layoutTag)) {
    assignError(error,
                "audio channel layout is outside the native v1 contract");
    return std::nullopt;
  }
  if (layout != nullptr) {
    audio.channelLayoutPresent = true;
    audio.channelLayoutTag = layoutTag;
  }
  track.audio = audio;
  return track;
}

enum class AsyncLoadWaitStatus : std::uint8_t {
  Complete,
  Cancelled,
  Invalid,
};

// A generation owns one signal for all of its serial metadata batches.  Each
// batch may contain up to the hard track cap, so completion bookkeeping stays
// scalar and callback completion never allocates.  Cancellation publishes an
// atomic fact, synchronizes with the wait mutex, and emits the exact edge that
// wakes the worker; there is no timed polling interval.
class AsyncLoadSignal final {
 public:
  struct BatchToken {
    std::uint64_t id{0};
    std::uint8_t expected{0};

    [[nodiscard]] bool valid() const noexcept {
      return id != 0 && expected != 0;
    }
  };

  [[nodiscard]] BatchToken begin(std::size_t requestCount) {
    std::lock_guard lock(mutex_);
    if (cancelled_.load(std::memory_order_acquire) || requestCount == 0 ||
        requestCount > MediaSourceLimits::kHardMaximumTracks ||
        active_batch_id_ != 0 ||
        next_batch_id_ == std::numeric_limits<std::uint64_t>::max()) {
      return {};
    }
    const BatchToken token{++next_batch_id_,
                           static_cast<std::uint8_t>(requestCount)};
    active_batch_id_ = token.id;
    expected_ = token.expected;
    completed_mask_ = 0;
    return token;
  }

  void complete(BatchToken token, std::size_t index) noexcept {
    try {
      {
        std::lock_guard lock(mutex_);
        if (!token.valid() || token.id != active_batch_id_ ||
            token.expected != expected_ || index >= expected_) {
          return;
        }
        completed_mask_ |= std::uint64_t{1} << index;
      }
      changed_.notify_all();
    } catch (...) {
      // Completion callbacks may outlive a cancelled generation and must not
      // allow a C++ exception to cross the Objective-C callback boundary.
    }
  }

  [[nodiscard]] AsyncLoadWaitStatus wait(BatchToken token) {
    if (!token.valid()) {
      return cancelled() ? AsyncLoadWaitStatus::Cancelled
                         : AsyncLoadWaitStatus::Invalid;
    }
    std::unique_lock lock(mutex_);
    const std::uint64_t completeMask =
        token.expected == MediaSourceLimits::kHardMaximumTracks
            ? std::numeric_limits<std::uint64_t>::max()
            : (std::uint64_t{1} << token.expected) - 1;
    changed_.wait(lock, [&] {
      return cancelled_.load(std::memory_order_acquire) ||
             active_batch_id_ != token.id ||
             (completed_mask_ & completeMask) == completeMask;
    });
    if (cancelled_.load(std::memory_order_acquire)) {
      return AsyncLoadWaitStatus::Cancelled;
    }
    return active_batch_id_ == token.id
               ? AsyncLoadWaitStatus::Complete
               : AsyncLoadWaitStatus::Invalid;
  }

  void finish(BatchToken token) noexcept {
    try {
      std::lock_guard lock(mutex_);
      if (active_batch_id_ == token.id) {
        active_batch_id_ = 0;
        expected_ = 0;
        completed_mask_ = 0;
      }
    } catch (...) {
    }
  }

  void cancel() noexcept {
    cancelled_.store(true, std::memory_order_release);
    try {
      // Taking the same mutex closes the lost-wakeup window between the
      // worker's predicate check and its atomic transition into cv.wait().
      std::lock_guard lock(mutex_);
    } catch (...) {
    }
    changed_.notify_all();
  }

  [[nodiscard]] bool cancelled() const noexcept {
    return cancelled_.load(std::memory_order_acquire);
  }

 private:
  std::atomic<bool> cancelled_{false};
  std::mutex mutex_;
  std::condition_variable changed_;
  std::uint64_t next_batch_id_{0};
  std::uint64_t active_batch_id_{0};
  std::uint64_t completed_mask_{0};
  std::uint8_t expected_{0};
};

struct ConcurrentLoadObservation {
  std::size_t issued{0};
  std::size_t validated{0};
  AsyncLoadWaitStatus wake{AsyncLoadWaitStatus::Invalid};
};

template <typename Issue, typename Validate>
[[nodiscard]] bool waitForConcurrentLoadBatch(
    const std::shared_ptr<AsyncLoadSignal>& signal,
    std::size_t requestCount, Issue&& issue, Validate&& validate,
    ConcurrentLoadObservation* observation, std::string* error) {
  if (observation != nullptr) {
    *observation = {};
  }
  const AsyncLoadSignal::BatchToken token = signal->begin(requestCount);
  if (!token.valid()) {
    assignError(error, signal->cancelled()
                           ? "AVFoundation generation was cancelled"
                           : "AVFoundation metadata batch is invalid");
    if (observation != nullptr) {
      observation->wake = signal->cancelled()
                              ? AsyncLoadWaitStatus::Cancelled
                              : AsyncLoadWaitStatus::Invalid;
    }
    return false;
  }
  try {
    for (std::size_t index = 0; index < requestCount; ++index) {
      if (signal->cancelled()) {
        break;
      }
      issue(index, std::function<void()>([signal, token, index] {
              signal->complete(token, index);
            }));
      if (observation != nullptr) {
        ++observation->issued;
      }
    }
  } catch (...) {
    signal->finish(token);
    throw;
  }
  const AsyncLoadWaitStatus wake = signal->wait(token);
  signal->finish(token);
  if (observation != nullptr) {
    observation->wake = wake;
  }
  if (wake != AsyncLoadWaitStatus::Complete) {
    assignError(error, wake == AsyncLoadWaitStatus::Cancelled
                           ? "AVFoundation generation was cancelled"
                           : "AVFoundation metadata batch lost its wait edge");
    return false;
  }
  // Validate in request order even though completion order is unconstrained.
  // This preserves deterministic source-first failure attribution.
  for (std::size_t index = 0; index < requestCount; ++index) {
    if (signal->cancelled()) {
      assignError(error, "AVFoundation generation was cancelled");
      return false;
    }
    if (observation != nullptr) {
      ++observation->validated;
    }
    if (!validate(index, error)) {
      return false;
    }
  }
  return true;
}

struct AsyncLoadRequest {
  __unsafe_unretained id<AVAsynchronousKeyValueLoading> object;
  __unsafe_unretained NSArray<NSString*>* keys;
};

// rejectedByAVFoundation, when non-null, is set only when AVFoundation itself
// refused to load a requested key. That is a verdict about the media, not an
// internal error: the container or its tracks are not readable by this
// backend, so the source is Unsupported and the open must fall back rather
// than be reported as a broken native command. A lost wait edge or a
// malformed batch leaves it false and stays a genuine failure.
[[nodiscard]] bool waitForLoadedValues(
    std::span<const AsyncLoadRequest> requests,
    const std::shared_ptr<AsyncLoadSignal>& signal,
    AVFoundationAssetContextMetadataLoadFacts& metadataLoads,
    AVFoundationAssetContextMetadataLoadBatch batch,
    std::string* error, bool* rejectedByAVFoundation = nullptr) {
  if (rejectedByAVFoundation != nullptr) {
    *rejectedByAVFoundation = false;
  }
  WAM_STARTUP_STAMP(AssetKeysBegin);
  const bool loaded = waitForConcurrentLoadBatch(
      signal, requests.size(),
      [&](std::size_t index, std::function<void()> completion) {
        id<AVAsynchronousKeyValueLoading> object = requests[index].object;
        NSArray<NSString*>* keys = requests[index].keys;
        if (index == 0) {
          noteAVFoundationAssetContextMetadataLoadBatch(metadataLoads,
                                                        batch);
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [object loadValuesAsynchronouslyForKeys:keys
                              completionHandler:^{ completion(); }];
#pragma clang diagnostic pop
      },
      [&](std::size_t index, std::string* validationError) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (NSString* key in requests[index].keys) {
          NSError* loadError = nil;
          const AVKeyValueStatus status =
              [requests[index].object statusOfValueForKey:key
                                                    error:&loadError];
          if (status != AVKeyValueStatusLoaded) {
            if (validationError != nullptr) {
              *validationError = describeNSError(
                  loadError, "AVFoundation metadata loading failed");
            }
            if (rejectedByAVFoundation != nullptr &&
                status == AVKeyValueStatusFailed) {
              *rejectedByAVFoundation = true;
            }
            return false;
          }
        }
#pragma clang diagnostic pop
        return true;
      },
      nullptr, error);
  WAM_STARTUP_STAMP(AssetKeysEnd);
  return loaded;
}

[[nodiscard]] MediaTrackKind trackKind(AVAssetTrack* track) noexcept {
  AVMediaType type = track.mediaType;
  if ([type isEqualToString:AVMediaTypeVideo]) {
    return MediaTrackKind::Video;
  }
  if ([type isEqualToString:AVMediaTypeAudio]) {
    return MediaTrackKind::Audio;
  }
  if ([type isEqualToString:AVMediaTypeSubtitle]) {
    return MediaTrackKind::Subtitle;
  }
  if ([type isEqualToString:AVMediaTypeText]) {
    return MediaTrackKind::Text;
  }
  if ([type isEqualToString:AVMediaTypeClosedCaption]) {
    return MediaTrackKind::ClosedCaption;
  }
  return MediaTrackKind::Metadata;
}

void incrementInventory(media::MediaTrackInventory* inventory,
                        MediaTrackKind kind) noexcept {
  switch (kind) {
  case MediaTrackKind::Video:
    ++inventory->video;
    break;
  case MediaTrackKind::Audio:
    ++inventory->audio;
    break;
  case MediaTrackKind::Subtitle:
    ++inventory->subtitle;
    break;
  case MediaTrackKind::Text:
    ++inventory->text;
    break;
  case MediaTrackKind::ClosedCaption:
    ++inventory->closedCaption;
    break;
  case MediaTrackKind::Metadata:
    ++inventory->metadata;
    break;
  }
}

[[nodiscard]] bool copyBoundedString(NSString* value,
                                     std::size_t maximumBytes,
                                     std::string* destination) {
  destination->clear();
  if (value == nil) {
    return true;
  }
  const NSUInteger bytes =
      [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if (bytes == NSNotFound || bytes > maximumBytes) {
    return false;
  }
  const char* utf8 = value.UTF8String;
  if (utf8 == nullptr) {
    return bytes == 0;
  }
  destination->assign(utf8, static_cast<std::size_t>(bytes));
  return true;
}

[[nodiscard]] bool audioLayoutSupported(const media::MediaAudioFormat& audio,
                                        std::string* error) {
  // The converter applies the same predicate; disagreeing would admit a
  // descriptor the converter then refuses at configure time.
  const bool supportedLayout = audioChannelLayoutAdmitted(audio);
  if (!supportedLayout) {
    assignError(error,
                "selected audio layout is outside the native v1 contract");
    return false;
  }
  return true;
}

// Classify a track's preferredTransform as one of the four quarter turns, or
// refuse it.
//
// Every portrait video a phone has ever produced arrives here. The transform
// is not decoration -- the frames really are stored landscape and really must
// be turned to be looked at -- but it is also not arbitrary: a container's
// rotation matrix is a quarter turn or it is something this player has no
// honest way to present. So the four exact matrices are admitted by name and
// everything else is still refused, out loud.
//
// Degrees are CLOCKWISE in screen terms (y down), which is the convention
// mediaVideoDisplaySize already reads when it swaps the rectangle for 90/270,
// and the convention the presentation layer's CATransform3D matches. The
// classifier itself (video_quarter_turn.hpp) reads the linear part only: the
// translation a portrait track carries is implied by the rotation and the
// coded size, and the presentation layer recomputes it from the rectangle it
// draws into rather than trusting it.
//
// The rebind proof's question: does this live transform still say exactly the
// angle the immutable descriptor recorded? A track whose transform changed
// under the reader is refused.
[[nodiscard]] bool videoTransformMatchesRotation(
    CGAffineTransform transform, std::int16_t expectedDegrees) noexcept {
  const std::optional<int> degrees = quarterTurnDegrees(transform);
  return degrees && *degrees == static_cast<int>(expectedDegrees);
}

// The A/V half of the track-inventory contract, stated ONCE so the cold-open
// gate and the descriptor's restatement of it cannot drift into two subtly
// different copies (the same reason the coded-dimension rule was centralized).
//
// Native v1 is a video contract: at most one video track, and the inventory
// and the selection must agree in both directions on each lane. Audio is
// optional (an audio-less GIF-to-MP4 conversion enumerates none).
//
// TIMED-TEXT TRACKS ARE ADMITTED. A tx3g/mov_text subtitle track, a legacy
// QuickTime 'text' track and a CEA-608 closed-caption track are all inert to
// this backend: none is ever selected, opened by the reader, or decoded, so
// none costs the video or audio lane a byte or a cycle, and a file's captions
// must never decide whether its picture plays. The count still rides the
// bounded kHardMaximumTracks total.
[[nodiscard]] bool trackInventoryAdmitted(
    const media::MediaTrackInventory& inventory, bool hasVideoSelection,
    bool hasAudioSelection) noexcept {
  return inventory.video <= 1 &&
         hasVideoSelection == (inventory.video != 0) &&
         hasAudioSelection == (inventory.audio != 0) &&
         (hasVideoSelection || hasAudioSelection);
}

[[nodiscard]] bool preservesLegacyNativeAdmission(
    const MediaSourceDescriptor& descriptor, std::string* error) {
  const auto& inventory = descriptor.inventory;
  if (!trackInventoryAdmitted(inventory, descriptor.selectedVideo.has_value(),
                              descriptor.selectedAudio.has_value())) {
    assignError(error,
                "track inventory is outside the native video v1 contract");
    return false;
  }
  // A video-less asset -- a standalone music file -- has no selected video
  // track to admit, so the whole video half of the contract is vacuously
  // satisfied and must not be dereferenced. This is the exact mirror of the
  // audio-less early return further down.
  if (!descriptor.selectedVideo) {
    if (!descriptor.selectedAudio) {
      assignError(error, "a source with neither lane admits no output");
      return false;
    }
    const MediaTrackDescriptor* onlyAudio =
        media::findMediaTrack(descriptor, *descriptor.selectedAudio);
    if (onlyAudio == nullptr || onlyAudio->kind != MediaTrackKind::Audio ||
        !onlyAudio->audio) {
      assignError(error,
                  "selected audio format is outside the native v1 contract");
      return false;
    }
    // MEASURED ENVELOPE, not a guess. With no video lane the audio track is the
    // whole generation, so a codec whose AVFoundation packetisation the native
    // converter cannot consume has nothing to hide behind. Every codec below
    // was played end to end from a standalone 20.000 s file at both 44.1 and
    // 48 kHz, and its rendered frame count read off the metrics stream:
    //
    //   .m4a  (AAC)   959488 frames, clock 1.000000.
    //   .mp3          960000 frames -- exact -- CBR and VBR, stereo and mono.
    //   .flac         960000 frames -- exact -- 16-bit.
    //   .wav / .aiff  960000 frames -- exact -- 16- and 24-bit, 0 underruns,
    //                 clock exactly 1.000000.
    //   .ac3 / .eac3  959712 frames: the codec's own 256-frame decoder lead-in
    //                 and 32-frame withheld MDCT ring-down, the same envelope
    //                 the Matroska route publishes for them.
    //
    // One codec AVAsset does demux is deliberately NOT here and keeps the mpv
    // fallback:
    //
    //   Opus (.opus/.ogg)  AVFoundation states mFramesPerPacket = 0 and carries
    //                 the count per packet instead. The audio session's
    //                 preflight and the converter's whole frame-grid
    //                 arithmetic key on a nonzero declared framesPerPacket, so
    //                 admitting it would mean reworking the frozen converter
    //                 for a codec that already plays natively from Matroska.
    //
    // ALAC: restateCompressedAudioPacketDurations above lengthens a short
    // trailing unit back to mFramesPerPacket -- right for AAC, whose packet
    // really does decode a full 1024 and whose trim really is an edit; wrong
    // for ALAC, whose final packet really does hold fewer frames (stated by the
    // MP4 sample table and again in the ALAC frame header, which is how
    // AudioToolbox decodes it exactly). The converter therefore carries FLAC's
    // tail-shortfall bound and FLAC's exact decoded duration for ALAC.
    //
    // The Matroska route admits its own codec set independently of this.
    switch (onlyAudio->codec) {
      case MediaCodec::Aac:
      case MediaCodec::Mp3:
      case MediaCodec::Flac:
      case MediaCodec::Pcm:
      case MediaCodec::Ac3:
      case MediaCodec::Eac3:
      //   ADPCM WAV     176,958-177,567 frames exact on 4-second IMA and MS
      //                 chirp fixtures, mono and stereo, 44.1 kHz: produced
      //                 frames equal the declared count (delta 0), cross-
      //                 correlation lag against ffmpeg 0 frames, and every
      //                 decoded frame bit-identical to ffmpeg's.
      case MediaCodec::AdpcmIma:
      case MediaCodec::AdpcmMs:
      //   ALAC          176,400 frames exact on a 4.000 s 44.1 kHz stereo
      //                 fixture whose final packet holds 272 of 4096; EOF at
      //                 the declared duration with the tail bound above.
      case MediaCodec::Alac:
        break;
      default:
        assignError(error,
                    "this audio codec is outside the measured video-less "
                    "AVFoundation envelope of native v1");
        return false;
    }
    return audioLayoutSupported(*onlyAudio->audio, error);
  }
  const MediaTrackDescriptor* track =
      media::findMediaTrack(descriptor, *descriptor.selectedVideo);
  const media::MediaCodecFacts& videoFacts =
      track == nullptr ? media::mediaCodecFacts(MediaCodec::Unknown)
                       : media::mediaCodecFacts(track->codec);
  if (track == nullptr || track->kind != MediaTrackKind::Video ||
      !track->video || !videoFacts.avfoundationVideoAdmitted ||
      // The nonempty-record requirement is INVERTED for the codecs that have no
      // record, exactly as supportedVideoTrack() inverts it in
      // native_video_consumer.mm. Both read the same field so a shape this
      // route admits and the consumer refuses -- which turns a clean
      // Unsupported into a mid-startup Failed -- is not expressible.
      (videoFacts.carriesConfigurationRecord
           ? track->codecConfiguration.empty()
           : !track->codecConfiguration.empty()) ||
      track->codecConfigurationKind != videoFacts.configurationKind) {
    assignError(error,
                "selected video codec is outside the native v1 contract");
    return false;
  }
  const media::MediaVideoFormat& video = *track->video;
  // THE shared admission rule (media::nativeVideoTrackRefusal), plus the one
  // AVFoundation-only term: the format description's stated bit depth must
  // agree with the HEVC record it carries. Each refusal is named: the terms
  // are independent and not equally likely, and a field report must tell a
  // rotation refusal from a chroma-siting one without a rebuild.
  const media::NativeVideoRefusal shared =
      media::nativeVideoTrackRefusal(video, videoFacts);
  const bool hevcDepthMatches =
      track->codec != MediaCodec::Hevc || video.bitsPerComponent == 0 ||
      media::mediaSampleFormatDepth(video.sampleFormat) == video.bitsPerComponent;
  const char* geometryRefusal = nullptr;
  switch (shared) {
    case media::NativeVideoRefusal::None:
    case media::NativeVideoRefusal::SampleFormat:
    case media::NativeVideoRefusal::Aperture:
    case media::NativeVideoRefusal::DisplaySize:
      if (!hevcDepthMatches) {
        geometryRefusal =
            "HEVC bit depth disagrees with the decoded sample format";
      }
      break;
    default:
      break;
  }
  if (geometryRefusal == nullptr) {
    switch (shared) {
      case media::NativeVideoRefusal::None:
        break;
      case media::NativeVideoRefusal::Dimensions:
        geometryRefusal =
            "selected video dimensions are outside the native v1 ceiling";
        break;
      case media::NativeVideoRefusal::Rotation:
        geometryRefusal =
            "selected video rotation is outside the native v1 presentation "
            "contract";
        break;
      case media::NativeVideoRefusal::Interlaced:
        geometryRefusal = "interlaced video is outside native v1";
        break;
      case media::NativeVideoRefusal::Color:
        geometryRefusal = video.dolbyVisionConfigurationPresent
            ? "DolbyVisionDisplayOracleProofMissing"
            : video.ambientViewingEnvironmentPresent
                ? "AmbientViewingEnvironmentDisplayProofMissing"
                : "VideoColorDescriptorDisplayProofMissing";
        break;
      case media::NativeVideoRefusal::SampleFormat:
        geometryRefusal = "selected video sample format is outside native v1";
        break;
      case media::NativeVideoRefusal::Aperture:
        geometryRefusal =
            "selected video has a clean aperture smaller than its coded frame";
        break;
      case media::NativeVideoRefusal::DisplaySize:
        geometryRefusal = "AnamorphicExactRationalDisplaySizeProofMissing";
        break;
    }
  }
  if (geometryRefusal != nullptr) {
    assignError(error, geometryRefusal);
    return false;
  }
  // An audio-less asset has no selected audio track to admit, so the audio
  // half of the contract is vacuously satisfied and must not be dereferenced.
  if (!descriptor.selectedAudio) {
    return true;
  }
  const MediaTrackDescriptor* audioTrack =
      media::findMediaTrack(descriptor, *descriptor.selectedAudio);
  if (audioTrack == nullptr || audioTrack->kind != MediaTrackKind::Audio ||
      !audioTrack->audio) {
    assignError(error,
                "selected audio format is outside the native v1 contract");
    return false;
  }
  return audioLayoutSupported(*audioTrack->audio, error);
}

[[nodiscard]] bool exactIdentityVideoTransform(
    CGAffineTransform transform) noexcept {
  return std::isfinite(transform.a) && std::isfinite(transform.b) &&
         std::isfinite(transform.c) && std::isfinite(transform.d) &&
         std::isfinite(transform.tx) && std::isfinite(transform.ty) &&
         transform.a == 1.0 && transform.b == 0.0 && transform.c == 0.0 &&
         transform.d == 1.0 && transform.tx == 0.0 && transform.ty == 0.0;
}


[[nodiscard]] bool audioFormatMatchesTrack(
    CMAudioFormatDescriptionRef format,
    const MediaTrackDescriptor& track) noexcept {
  if (format == nullptr || track.kind != MediaTrackKind::Audio ||
      !track.audio ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio) {
    return false;
  }
  const AudioStreamBasicDescription* asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(format);
  if (asbd == nullptr || asbd->mSampleRate != track.audio->sampleRate ||
      asbd->mFormatID != track.audio->formatTag ||
      asbd->mFormatFlags != track.audio->formatFlags ||
      asbd->mBytesPerPacket != track.audio->bytesPerPacket ||
      asbd->mFramesPerPacket != track.audio->framesPerPacket ||
      asbd->mBytesPerFrame != track.audio->bytesPerFrame ||
      asbd->mChannelsPerFrame != track.audio->channels ||
      asbd->mBitsPerChannel != track.audio->bitsPerChannel) {
    return false;
  }
  std::size_t layoutSize = 0;
  const AudioChannelLayout* layout =
      CMAudioFormatDescriptionGetChannelLayout(format, &layoutSize);
  AudioChannelLayoutTag layoutTag{0};
  if (!validAudioChannelLayout(layout, layoutSize, track.audio->channels,
                               &layoutTag)) {
    return false;
  }
  const bool layoutPresent = layout != nullptr;
  if (layoutPresent != track.audio->channelLayoutPresent ||
      layoutTag != track.audio->channelLayoutTag) {
    return false;
  }
  std::size_t cookieSize = 0;
  const void* cookie =
      CMAudioFormatDescriptionGetMagicCookie(format, &cookieSize);
  return cookieSize == track.codecConfiguration.size() &&
         (cookieSize == 0 ||
          (cookie != nullptr &&
           std::memcmp(cookie, track.codecConfiguration.data(), cookieSize) ==
               0));
}

template <typename NoteReaderCreationAttempt>
[[nodiscard]] bool selectedFormatsRebindBeforeReader(
    CMVideoFormatDescriptionRef videoFormat, std::size_t videoFormatCount,
    CGAffineTransform videoTransform,
    CMAudioFormatDescriptionRef audioFormat, std::size_t audioFormatCount,
    const MediaSourceDescriptor& descriptor,
    const MediaSourceLimits& requestedLimits,
    NoteReaderCreationAttempt&& noteReaderCreationAttempt,
    std::string* error) {
  const MediaTrackDescriptor* expectedVideo =
      descriptor.selectedVideo
          ? media::findMediaTrack(descriptor, *descriptor.selectedVideo)
          : nullptr;
  const MediaTrackDescriptor* expectedAudio =
      descriptor.selectedAudio
          ? media::findMediaTrack(descriptor, *descriptor.selectedAudio)
          : nullptr;
  // An audio-less asset selected no audio track, so it owes no audio format:
  // the exactly-one-format proof becomes an exactly-zero-formats proof and the
  // format comparison is skipped rather than run against a track that does not
  // exist. A descriptor that did select audio owes the exactly-one-format
  // proof.
  const bool audioSelected = descriptor.selectedAudio.has_value();
  const std::size_t expectedAudioFormatCount = audioSelected ? 1 : 0;
  // The exact mirror for a video-less (audio-only) asset: it selected no video
  // track, owes no video format, and the exactly-one-format proof becomes an
  // exactly-zero-formats proof on that lane too.
  const bool videoSelected = descriptor.selectedVideo.has_value();
  const std::size_t expectedVideoFormatCount = videoSelected ? 1 : 0;
  if (videoFormatCount != expectedVideoFormatCount ||
      audioFormatCount != expectedAudioFormatCount ||
      (videoSelected && expectedVideo == nullptr) ||
      (audioSelected && expectedAudio == nullptr) ||
      // The track's transform must still be exactly what the immutable
      // descriptor recorded. The admitted value is a quarter turn, so the
      // proof compares the classified angle against the descriptor's.
      (videoSelected &&
       (!expectedVideo->video ||
        !quarterTurnRotationAdmitted(*expectedVideo->video) ||
        !videoTransformMatchesRotation(
            videoTransform, expectedVideo->video->rotationDegrees) ||
        !videoFormatMatchesTrack(videoFormat, *expectedVideo,
                                 requestedLimits))) ||
      (audioSelected &&
       !audioFormatMatchesTrack(audioFormat, *expectedAudio))) {
    // Say WHICH thing changed. This proof has six independent ways to fail,
    // and one sentence for all of them could not distinguish "the file really
    // did change under us" from "this proof does not understand the file",
    // which are opposite conclusions.
    const char* rebindRefusal =
        "selected track formats changed before reader creation";
    if (videoFormatCount != expectedVideoFormatCount) {
      rebindRefusal = "selected video format count changed before reader "
                      "creation";
    } else if (audioFormatCount != expectedAudioFormatCount) {
      rebindRefusal = "selected audio format count changed before reader "
                      "creation";
    } else if (videoSelected && expectedVideo != nullptr &&
               expectedVideo->video &&
               !videoTransformMatchesRotation(
                   videoTransform, expectedVideo->video->rotationDegrees)) {
      rebindRefusal = "selected video transform changed before reader "
                      "creation";
    } else if (videoSelected && expectedVideo != nullptr &&
               !videoFormatMatchesTrack(videoFormat, *expectedVideo,
                                        requestedLimits)) {
      rebindRefusal =
          "selected video format changed before reader creation";
    } else if (audioSelected && expectedAudio != nullptr &&
               !audioFormatMatchesTrack(audioFormat, *expectedAudio)) {
      rebindRefusal =
          "selected audio format changed before reader creation";
    }
    assignError(error, rebindRefusal);
    return false;
  }
  std::forward<NoteReaderCreationAttempt>(noteReaderCreationAttempt)();
  return true;
}

class ProductionGeneration final : public AVFoundationGeneration {
 public:
  explicit ProductionGeneration(AVFoundationGenerationRequest request)
      : request_(std::move(request)) {
    cancellation_queue_ = dispatch_queue_create("WAM.reader.cancel", DISPATCH_QUEUE_SERIAL);
    cancellation_done_ = dispatch_semaphore_create(0);
    cancellation_source_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0,
                                                 cancellation_queue_);
    dispatch_source_set_event_handler(cancellation_source_, ^{ cancelObjects(); });
    const auto done = cancellation_done_;
    dispatch_source_set_cancel_handler(cancellation_source_, ^{ dispatch_semaphore_signal(done); });
    dispatch_resume(cancellation_source_);
  }
  ~ProductionGeneration() override {
    // The source/retirement owner must outlive the cancellation handler.
    dispatch_source_cancel(cancellation_source_);
    dispatch_semaphore_wait(cancellation_done_, DISPATCH_TIME_FOREVER);
  }

  [[nodiscard]] MediaGeneration generation() const noexcept override {
    return request_.generation;
  }

  [[nodiscard]] AVFoundationGenerationStart start() override {
    @autoreleasepool {
      AVFoundationGenerationStart result;
      if (cancelled_.load(std::memory_order_acquire)) {
        result.status = AVFoundationGenerationStatus::Cancelled;
        return result;
      }
      const MediaSourceLimits limits =
          media::clampMediaSourceLimits(request_.options.limits);
      audio_limits_ = limits;
      releaseAudioBatch();
      std::shared_ptr<const AVFoundationAssetContext> assetContext =
          request_.assetContext;
      std::shared_ptr<const MediaSourceDescriptor> descriptor;
      AVURLAsset* asset = nil;
      AVAssetTrack* videoTrack = nil;
      AVAssetTrack* audioTrack = nil;
      CMTime assetDuration = kCMTimeInvalid;

      if (assetContext != nullptr) {
        descriptor = assetContext->descriptor();
        if (!assetContext->matchesMainRequest(
                request_.path, request_.options, descriptor)) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error =
              "AVFoundation asset context does not match the seek source";
          return result;
        }
        const AVFoundationAssetContextNativeHandles handles =
            borrowAVFoundationAssetContextNativeHandles(*assetContext);
        if (!handles.complete()) {
          result.error =
              "AVFoundation asset context has no production native handles";
          return result;
        }
        aac_timeline_ = handles.aacTimeline;
        mp3_gapless_ = handles.mp3Gapless;
        asset = (__bridge AVURLAsset*)(
            const_cast<void*>(handles.asset));
        videoTrack = (__bridge AVAssetTrack*)(
            const_cast<void*>(handles.selectedVideoTrack));
        audioTrack = (__bridge AVAssetTrack*)(
            const_cast<void*>(handles.selectedAudioTrack));
        const auto duration = exactCMTime(descriptor->duration);
        // The context's audio borrow is present exactly when the immutable
        // descriptor selected audio, so an audio-less asset legitimately warm
        // starts with a nil audioTrack. Requiring the two to agree keeps a
        // borrow that disagrees with the admitted descriptor a hard failure.
        if (asset == nil || !duration ||
            (videoTrack != nil) != descriptor->selectedVideo.has_value() ||
            (audioTrack != nil) != descriptor->selectedAudio.has_value()) {
          result.error = "AVFoundation asset context is incomplete";
          return result;
        }
        assetDuration = *duration;
      } else {
        AVFoundationAssetContextMetadataLoadFacts metadataLoads;
        std::error_code fileError;
        if (!std::filesystem::is_regular_file(request_.path, fileError)) {
          result.error =
              "AVFoundation source requires a readable local file";
          return result;
        }
        NSString* filePath =
            [NSString stringWithUTF8String:request_.path.string().c_str()];
        if (filePath == nil) {
          result.error = "media path is not valid UTF-8";
          return result;
        }
        asset = [AVURLAsset
            URLAssetWithURL:[NSURL fileURLWithPath:filePath]
                    options:@{
                      AVURLAssetPreferPreciseDurationAndTimingKey : @YES
                    }];
        {
          std::lock_guard lock(objects_mutex_);
          loading_asset_ = asset;
        }
        if (cancelled_.load(std::memory_order_acquire)) {
          [asset cancelLoading];
          result.status = AVFoundationGenerationStatus::Cancelled;
          return result;
        }

        NSArray<NSString*>* assetKeys =
            @[@"playable", @"hasProtectedContent", @"duration", @"tracks"];
        const std::array assetLoadRequests{
            AsyncLoadRequest{asset, assetKeys}};
        // A container AVFoundation cannot demux (Matroska, for example) fails
        // here: the asset keys never reach Loaded. That is an admissibility
        // verdict about the file, so it must route to compatibility playback
        // as Unsupported instead of being reported as an internal failure.
        bool assetRejected = false;
        if (!waitForLoadedValues(
                assetLoadRequests, metadata_load_signal_, metadataLoads,
                AVFoundationAssetContextMetadataLoadBatch::Asset,
                                 &result.error, &assetRejected)) {
          result.status = cancelled_.load(std::memory_order_acquire)
                              ? AVFoundationGenerationStatus::Cancelled
                          : assetRejected
                              ? AVFoundationGenerationStatus::Unsupported
                              : AVFoundationGenerationStatus::Failed;
          return result;
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        bool supplementalVp9Demuxable = false;
        if (!asset.playable && !asset.hasProtectedContent && nativeVideoToolboxSupportsVp9()) {
          for (AVAssetTrack* candidate in [asset tracksWithMediaType:AVMediaTypeVideo]) {
            for (id value in candidate.formatDescriptions) {
              auto description = (__bridge CMFormatDescriptionRef)value;
              supplementalVp9Demuxable |= CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_VP9;
            }
          }
        }
        if ((!asset.playable && !supplementalVp9Demuxable) || asset.hasProtectedContent) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error =
              "protected or unplayable media is not native-admissible";
          return result;
        }
        assetDuration = asset.duration;
        NSArray<AVAssetTrack*>* allTracks = asset.tracks;
#pragma clang diagnostic pop
        const std::size_t trackCount = allTracks.count;
        if (trackCount == 0 ||
            trackCount > MediaSourceLimits::kHardMaximumTracks ||
            trackCount > limits.maximumTracks) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error = "asset exceeds the bounded native track inventory";
          return result;
        }

        media::MediaTrackInventory inventory;
        inventory.total = static_cast<std::uint8_t>(trackCount);
        AVAssetTrack* firstVideoTrack = nil;
        AVAssetTrack* firstAudioTrack = nil;
        AVAssetTrack* preferredVideoTrack = nil;
        AVAssetTrack* preferredAudioTrack = nil;
        for (AVAssetTrack* track in allTracks) {
          const MediaTrackKind kind = trackKind(track);
          incrementInventory(&inventory, kind);
          const MediaTrackId id = stableTrackId(track, 0);
          if (kind == MediaTrackKind::Video) {
            if (firstVideoTrack == nil) {
              firstVideoTrack = track;
            }
            if (request_.options.selection.preferredVideo == id) {
              preferredVideoTrack = track;
            }
          } else if (kind == MediaTrackKind::Audio) {
            if (firstAudioTrack == nil) {
              firstAudioTrack = track;
            }
            if (request_.options.selection.preferredAudio == id) {
              preferredAudioTrack = track;
            }
          }
        }
        videoTrack = preferredVideoTrack != nil ? preferredVideoTrack
                                                : firstVideoTrack;
        audioTrack = preferredAudioTrack != nil ? preferredAudioTrack
                                                : firstAudioTrack;
        // One statement of the A/V inventory rule; see trackInventoryAdmitted.
        // Timed-text tracks are admitted here and carried to the subtitle lane.
        if (!trackInventoryAdmitted(inventory, videoTrack != nil,
                                    audioTrack != nil)) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error =
              "asset track inventory is outside the native video v1 contract";
          return result;
        }

        const auto sourceDuration = canonicalDuration(assetDuration);
        if (!sourceDuration) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error = "asset has no exact finite nonnegative duration";
          return result;
        }
        auto mutableDescriptor = std::make_shared<MediaSourceDescriptor>();
        mutableDescriptor->duration = *sourceDuration;
        mutableDescriptor->inventory = inventory;
        mutableDescriptor->tracks.reserve(
            static_cast<std::size_t>(videoTrack != nil ? 1 : 0) +
            static_cast<std::size_t>(audioTrack != nil ? 1 : 0));

        // Both selected tracks have the same immutable metadata key set.
        // Issue both loads before waiting, then validate video first. An
        // audio-less asset has one selected track, so the batch covers exactly
        // the tracks that exist and still counts as the single selected-track
        // metadata load the context requires.
        NSArray<NSString*>* trackKeys = @[
          @"formatDescriptions", @"naturalTimeScale", @"timeRange",
          @"preferredTransform", @"languageCode", @"extendedLanguageTag"
        ];
        std::array<AsyncLoadRequest, MediaSourceLimits::kHardMaximumTracks>
            selectedTrackLoadStorage{};
        std::size_t loadCount = 0;
        if (videoTrack != nil) {
          selectedTrackLoadStorage[loadCount++] = {videoTrack, trackKeys};
        }
        for (AVAssetTrack* candidate in allTracks) {
          if (trackKind(candidate) == MediaTrackKind::Audio) {
            selectedTrackLoadStorage[loadCount++] = {candidate, trackKeys};
          }
        }
        const std::span<const AsyncLoadRequest> selectedTrackLoadRequests(
            selectedTrackLoadStorage.data(), loadCount);
        bool trackRejected = false;
        if (!waitForLoadedValues(
                selectedTrackLoadRequests, metadata_load_signal_,
                metadataLoads,
                AVFoundationAssetContextMetadataLoadBatch::SelectedTracks,
                &result.error, &trackRejected)) {
          result.status = cancelled_.load(std::memory_order_acquire)
                              ? AVFoundationGenerationStatus::Cancelled
                          : trackRejected
                              ? AVFoundationGenerationStatus::Unsupported
                              : AVFoundationGenerationStatus::Failed;
          return result;
        }
        // A video-less asset -- a standalone music file -- contributes no
        // video track: no track timeline to prove zero-based, no format to
        // describe. selectedVideo stays unset, exactly mirroring the audio-less
        // case below.
        if (videoTrack != nil) {
          if (!preservesZeroBasedTrackTimeline(videoTrack, &result.error)) {
            result.status = AVFoundationGenerationStatus::Unsupported;
            return result;
          }
          auto videoDescriptor =
              describeVideo(videoTrack, limits, &result.error);
          if (!videoDescriptor) {
            result.status = AVFoundationGenerationStatus::Unsupported;
            return result;
          }
          mutableDescriptor->selectedVideo = videoDescriptor->id;
          mutableDescriptor->tracks.push_back(std::move(*videoDescriptor));
        }

        // An audio-less asset contributes no audio track: there is no track
        // timeline to prove zero-based, no identifier to disambiguate against
        // the video track, and no audio format to describe. selectedAudio
        // stays unset and descriptor->tracks holds the video track alone.
        mp3_gapless_.reset();
        if (audioTrack != nil) {
          std::array<media::AudioTrackCandidate,
                     MediaSourceLimits::kHardMaximumTracks> candidates{};
          for (std::size_t i = 0; i < trackCount; ++i) {
            AVAssetTrack* candidate = allTracks[i];
            candidates[i] = {stableTrackId(candidate, 0),
                             trackKind(candidate) == MediaTrackKind::Audio &&
                                 !request_.rejectedAudio.contains(stableTrackId(candidate, 0)),
                             candidate == firstAudioTrack};
          }
          const auto selected = media::selectAdmittedAudioTrack(
              std::span(candidates).first(trackCount),
              request_.options.selection.preferredAudio, [&](std::size_t i) {
                if (cancelled_.load(std::memory_order_acquire)) return false;
                AVAssetTrack* candidate = allTracks[i];
                if (!preservesZeroBasedTrackTimeline(candidate, &result.error)) {
                  return false;
                }
                MediaTrackId audioId = stableTrackId(candidate, 2);
                if (mutableDescriptor->selectedVideo &&
                    audioId == *mutableDescriptor->selectedVideo) {
                  audioId = *mutableDescriptor->selectedVideo == 1 ? 2 : 1;
                }
                auto proposed = describeAudio(candidate, audioId, limits,
                                               &result.error);
                if (!proposed || !admitAudioTrack(*proposed)) {
                  return false;
                }
                const auto previousDuration = mutableDescriptor->duration;
                const auto gapless = mp3LsfGapless(*proposed, request_.path);
                if (gapless) {
                  proposed->duration = {static_cast<std::int64_t>(gapless->retainedFrames),
                                        static_cast<std::int32_t>(gapless->sampleRate)};
                  if (videoTrack == nil) mutableDescriptor->duration = proposed->duration;
                }
                mutableDescriptor->selectedAudio = proposed->id;
                mutableDescriptor->tracks.push_back(std::move(*proposed));
                if (!media::validateMediaSourceDescriptor(
                        *mutableDescriptor, limits, &result.error) ||
                    !preservesLegacyNativeAdmission(*mutableDescriptor,
                                                    &result.error)) {
                  mutableDescriptor->tracks.pop_back();
                  mutableDescriptor->selectedAudio.reset();
                  mutableDescriptor->duration = previousDuration;
                  return false;
                }
                audioTrack = candidate;
                mp3_gapless_ = gapless;
                return true;
              });
          if (!selected) {
            result.status = cancelled_.load(std::memory_order_acquire)
                                ? AVFoundationGenerationStatus::Cancelled
                                : AVFoundationGenerationStatus::Unsupported;
            if (result.error.empty()) {
              result.error = "no selected audio candidate passed complete codec admission";
            }
            return result;
          }
          result.error.clear();
        }
        // The descriptor is validated once, below, for cold and warm
        // generations alike.
        if (cancelled_.load(std::memory_order_acquire)) {
          result.status = AVFoundationGenerationStatus::Cancelled;
          return result;
        }
        descriptor = std::move(mutableDescriptor);
        assetContext = adoptPreparedAVFoundationAssetContext(
            request_.path, request_.options, descriptor,
            AVFoundationAssetContextNativeHandles{
                (__bridge const void*)asset,
                (__bridge const void*)videoTrack,
                (__bridge const void*)audioTrack, aac_timeline_,
                mp3_gapless_},
            metadataLoads);
        if (assetContext == nullptr) {
          result.error =
              "AVFoundation could not retain its prepared asset context";
          return result;
        }
        {
          std::lock_guard lock(objects_mutex_);
          loading_asset_ = nil;
        }
      }

      if (descriptor == nullptr ||
          !media::validateMediaSourceDescriptor(*descriptor, limits,
                                                &result.error) ||
          !preservesLegacyNativeAdmission(*descriptor, &result.error)) {
        result.status = AVFoundationGenerationStatus::Unsupported;
        return result;
      }
      if (request_.target &&
          !exactNonnegativeTimeWithinDuration(*request_.target,
                                              descriptor->duration)) {
        result.status = AVFoundationGenerationStatus::Unsupported;
        result.error = "requested position exceeds the exact asset duration";
        return result;
      }

      const MediaTrackDescriptor* const selectedAudio =
          descriptor->selectedAudio
              ? media::findMediaTrack(*descriptor, *descriptor->selectedAudio)
              : nullptr;
      CMTime decodeStart = kCMTimeZero;
      audio_playout_proof_ceiling_.reset();
      audio_first_unit_restated_ = false;
      if (request_.target) {
        const auto target = exactCMTime(*request_.target);
        if (!target) {
          result.error = "seek target is not exact CoreMedia time";
          return result;
        }
        // An accurate generation that starts away from the stream origin must
        // hand the converter a primed first access unit. Walk the sync search
        // back to the audio priming floor so the located decode start is at
        // or before it; the declared audio window then keeps A exact while its
        // earlier decode start D makes [D, A) the discarded priming window.
        // KeyFrame keeps its strict A = D = RAP rule and is left untouched.
        CMTime searchStart = *target;
        if (request_.seekMode == media::MediaSeekMode::Accurate &&
            descriptor->selectedAudio) {
          const std::optional<AudioPrimingPlan> priming =
              selectedAudio == nullptr
                  ? std::optional<AudioPrimingPlan>{}
                  : audioPrimingPlanFacts(*selectedAudio, *request_.target);
          const auto primingFloor =
              priming ? exactCMTime(priming->searchFloor)
                      : std::optional<CMTime>{};
          if (!priming || !primingFloor) {
            result.status = AVFoundationGenerationStatus::Unsupported;
            result.error =
                "audio priming window is not exactly representable";
            return result;
          }
          if (CMTimeCompare(*primingFloor, searchStart) < 0) {
            searchStart = *primingFloor;
          }
          if (aac_timeline_ && audioTrack != nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            const auto edits = audioMovieTimelineFactsFor(audioTrack.segments);
#pragma clang diagnostic pop
            const auto shift = edits ? audioFrameAlignedEditTime(edits->shift,aac_timeline_->rate()) : std::nullopt;
            const auto frame = media::audioFrameAtOrAfter(*request_.target,aac_timeline_->rate());
            const auto targetFrame = frame ? media::exactAudioFrameIndex(*frame,aac_timeline_->rate()) : std::nullopt;
            if (!shift || !targetFrame) { result.error="AacSeekEditUnrepresentable"; return result; }
            const auto shiftFrame = media::exactAudioFrameIndex({shift->value,shift->timescale},aac_timeline_->rate());
            if (!shiftFrame) { result.error="AacSeekEditUnrepresentable"; return result; }
            const auto index = aac_timeline_->indexAtFrame(*targetFrame-*shiftFrame);
            const auto& packet = aac_timeline_->packets()[index > media::kAacSeekBackoffPackets ? index-media::kAacSeekBackoffPackets : 0];
            const auto packetFloor = CMTimeMake(std::max<std::int64_t>(0,packet.start+*shiftFrame),aac_timeline_->rate());
            if (CMTimeCompare(packetFloor,searchStart)<0) searchStart=packetFloor;
          }
          audio_playout_proof_ceiling_ = priming->proofCeiling;
        }
        decodeStart = videoTrack == nil ? searchStart
                                        : fullSyncStart(videoTrack, searchStart);
        if (!CMTIME_IS_NUMERIC(decodeStart)) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error = "AVFoundation could not locate a bounded sync start";
          return result;
        }
        decodeStart = syncStartWithinTimelineWindow(decodeStart,
                                                    *request_.target);

      }
      const auto exactStart = exactMediaTime(decodeStart);
      if (!exactStart) {
        result.error = "AVFoundation returned an inexact decode start";
        return result;
      }

      // Establish this generation's movie-timeline restatements before any
      // access unit is read. Both lanes need one, for the same reason: the
      // reader hands out MEDIA-timeline stamps while every quantity they are
      // measured against -- the seek target, the presentation floor, the reader
      // range, the descriptor duration -- is the MOVIE timeline.
      //
      // The decoded frame already arrives on the movie timeline (VideoToolbox
      // reports each frame at its sample's OUTPUT stamp), so the compressed
      // half must be restated too: otherwise the two halves of one lane are
      // stated on two clocks that diverge by precisely the edit shift --
      // invisible on a no-edit file, and a refused negative decoded frame on a
      // head-trimmed one.
      video_movie_shift_ = kCMTimeZero;
      if (videoTrack != nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray* videoSegments = videoTrack.segments;
#pragma clang diagnostic pop
        // The same shape rule the audio lane applies below: one media edit,
        // optionally behind one leading empty edit, at rate 1. A multi-segment,
        // mid-hole or rate-stretched video edit list is not a constant
        // displacement; admitting it draws a few frames and then fails
        // mid-play on the discontinuity, so it is refused here by name.
        if (!audioMovieTimelineFactsFor(videoSegments)) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error = "selected video edit list is outside native v1";
          return result;
        }
        video_movie_shift_ = trackMovieTimelineShift(videoSegments);
      }
      audio_movie_shift_ = kCMTimeZero;
      audio_media_start_ = kCMTimeZero;
      audio_presentation_end_ = kCMTimeInvalid;
      if (audioTrack != nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray* audioSegments = audioTrack.segments;
#pragma clang diagnostic pop
        const auto editFacts = audioMovieTimelineFactsFor(audioSegments);
        if (!editFacts) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error = "selected audio edit list is outside native v1";
          return result;
        }
        audio_movie_shift_ = editFacts->shift;
        audio_media_start_ = editFacts->mediaStart;
        if (selectedAudio != nullptr && CMTimeCompare(audio_movie_shift_, kCMTimeZero) == 0) {
          if (mp3_gapless_) {
            audio_movie_shift_ = CMTimeMake(-static_cast<std::int64_t>(mp3_gapless_->encoderDelay),
                                            static_cast<std::int32_t>(mp3_gapless_->sampleRate));
          }
        }
        // Place access unit 0 the decoder's own lead-in before the origin, as
        // the Matroska and MPEG-TS routes do. See audioDecoderLeadInShift:
        // zero for AAC, FLAC, ALAC and LPCM, and zero for every real container;
        // only a bare MP3/AC-3/E-AC-3 elementary stream moves.
        {
          const std::optional<CMTime> deficit =
              selectedAudio == nullptr
                  ? std::optional<CMTime>{kCMTimeZero}
                  : audioDecoderLeadInShift(*selectedAudio, request_.path);
          const CMTime shifted =
              deficit ? CMTimeSubtract(audio_movie_shift_, *deficit)
                      : kCMTimeInvalid;
          if (!deficit || !CMTIME_IS_NUMERIC(shifted) ||
              (shifted.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
              shifted.epoch != 0 || shifted.timescale <= 0) {
            result.status = AVFoundationGenerationStatus::Unsupported;
            result.error =
                "selected audio decoder lead-in is not exactly representable "
                "on the movie timeline";
            return result;
          }
          audio_movie_shift_ = shifted;
        }
        // Restate the shift, and the media start it carries, on the track's own
        // audio frame grid. See audioFrameAlignedEditTime: a movie timescale
        // that does not divide the sample rate can otherwise put every audio
        // stamp a fraction of a sample off the grid, which refuses the whole
        // generation. Both move by the same whole-frame ceiling, so the first
        // access unit's movie stamp still lands exactly on the media start and
        // the window keeps reporting that it starts at the stream origin.
        //
        // Applied ONLY when the declared time is not already frame-exact, so a
        // frame-exact edit is arithmetically untouched.
        {
          const double rate = selectedAudio && selectedAudio->audio
                                  ? selectedAudio->audio->sampleRate
                                  : 0.0;
          const auto sampleRate =
              media::exactAudioSampleRate(rate).value_or(0U);
          if (sampleRate != 0) {
            const auto exactShift = exactMediaTime(audio_movie_shift_);
            const bool shiftOnGrid =
                exactShift &&
                media::exactAudioFrameIndex(*exactShift, sampleRate)
                    .has_value();
            if (!shiftOnGrid) {
              const auto alignedShift =
                  audioFrameAlignedEditTime(audio_movie_shift_, sampleRate);
              const auto alignedMediaStart =
                  CMTimeCompare(audio_media_start_, kCMTimeZero) > 0
                      ? audioFrameAlignedEditTime(audio_media_start_,
                                                  sampleRate)
                      : std::optional<CMTime>{audio_media_start_};
              if (!alignedShift || !alignedMediaStart) {
                result.status = AVFoundationGenerationStatus::Unsupported;
                result.error =
                    "selected audio edit list is not representable on the "
                    "track's audio frame grid";
                return result;
              }
              audio_movie_shift_ = *alignedShift;
              audio_media_start_ = *alignedMediaStart;
            }
          }
        }
        // A leading empty edit declares silence on the movie timeline before
        // any audio media exists; a selected video that runs past the end of
        // the selected audio declares it at the other end. Both are stated to
        // the neutral contract as facts of the audio window -- mediaStart and
        // presentationEnd -- and the audio-authoritative clock advances across
        // them at rate 1.0 with the renderer emitting zeros. Neither is a
        // refusal, and neither is an underrun: the source says the
        // audio is absent, so nothing is owed for those frames.
        audio_presentation_end_ = kCMTimeInvalid;
        if (videoTrack != nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
          const CMTimeRange videoRange = videoTrack.timeRange;
          const CMTimeRange audioRange = audioTrack.timeRange;
#pragma clang diagnostic pop
          const CMTime videoEnd = CMTimeRangeGetEnd(videoRange);
          const CMTime audioEnd = CMTimeRangeGetEnd(audioRange);
          // Exactness is mandatory: an end that had to be rounded onto either
          // grid could not name a sample-exact boundary, so the generation
          // declares no presentation end rather than guessing one.
          if ((videoEnd.flags & kCMTimeFlags_Valid) != 0 &&
              (videoEnd.flags & kCMTimeFlags_HasBeenRounded) == 0 &&
              (audioEnd.flags & kCMTimeFlags_Valid) != 0 &&
              (audioEnd.flags & kCMTimeFlags_HasBeenRounded) == 0 &&
              CMTimeCompare(videoEnd, audioEnd) > 0) {
            audio_presentation_end_ = videoEnd;
            audio_media_end_ = audioEnd;
          }
        }
        if (CMTimeCompare(audio_media_start_, kCMTimeZero) > 0) {
          const auto exactMediaStart = exactMediaTime(audio_media_start_);
          if (!exactMediaStart) {
            result.status = AVFoundationGenerationStatus::Unsupported;
            result.error = "selected audio edit list is outside native v1";
            return result;
          }
          result.declaredAudioMediaStart = *exactMediaStart;
        }
        if ((audio_presentation_end_.flags & kCMTimeFlags_Valid) != 0) {
          const auto exactEnd = exactMediaTime(audio_presentation_end_);
          const auto exactAudioEnd = exactMediaTime(audio_media_end_);
          if (exactEnd && exactAudioEnd) {
            result.declaredPresentationEnd = *exactEnd;
            result.declaredAudioEnd = *exactAudioEnd;
          }
        }
      }

      // Re-read the already-loaded selected formats on every cold/seek
      // generation immediately before creating its reader. The context owns
      // tracks, not a promise that their mutable AVFoundation view is still
      // the one admitted into the immutable descriptor. An audio-less asset
      // has no audio track to re-read: the nil send states zero audio formats,
      // which is exactly the rebind proof its descriptor owes.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      NSArray* currentVideoFormats = videoTrack.formatDescriptions;
      const CGAffineTransform currentVideoTransform =
          videoTrack.preferredTransform;
      NSArray* currentAudioFormats = audioTrack.formatDescriptions;
#pragma clang diagnostic pop
      auto currentVideoFormat = currentVideoFormats.count == 1
                                    ? (__bridge CMVideoFormatDescriptionRef)
                                          currentVideoFormats.firstObject
                                    : nullptr;
      auto currentAudioFormat = currentAudioFormats.count == 1
                                    ? (__bridge CMAudioFormatDescriptionRef)
                                          currentAudioFormats.firstObject
                                    : nullptr;
      if (!selectedFormatsRebindBeforeReader(
              currentVideoFormat,
              static_cast<std::size_t>(currentVideoFormats.count),
              currentVideoTransform, currentAudioFormat,
              static_cast<std::size_t>(currentAudioFormats.count), *descriptor,
              limits,
              [&] {
                noteAVFoundationAssetContextReaderCreationAttempt(
                    *assetContext);
              },
              &result.error)) {
        result.status = AVFoundationGenerationStatus::Unsupported;
        return result;
      }

      NSError* readerError = nil;
      AVAssetReader* reader =
          [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
      if (reader == nil) {
        result.error = describeNSError(readerError,
                                       "AVAssetReader creation failed");
        return result;
      }
      AVAssetReaderTrackOutput* videoOutput = nil;
      AVAssetReaderTrackOutput* audioOutput = nil;
      if (videoTrack != nil &&
          !addOutput(reader, videoTrack, &videoOutput, &result.error)) {
        result.status = AVFoundationGenerationStatus::Unsupported;
        return result;
      }
      if (audioTrack != nil &&
          !addOutput(reader, audioTrack, &audioOutput, &result.error)) {
        result.status = AVFoundationGenerationStatus::Unsupported;
        return result;
      }
      if (request_.target) {
        CMTime readerEnd = assetDuration;
        // Compressed audio timestamps retain the priming edit. Its reader
        // extent must reach the media tail; publication remains movie-trimmed.
        if (audioTrack != nil &&
            CMTimeCompare(audio_movie_shift_, kCMTimeZero) < 0) {
          readerEnd = CMTimeSubtract(readerEnd, audio_movie_shift_);
        }
        if (aac_timeline_ && !aac_timeline_->packets().empty()) {
          const auto& last = aac_timeline_->packets().back();
          // Asset duration can end at the last picture before the audio tail.
          // AVAssetReader's explicit range otherwise silently omits those AUs.
          const auto audioEnd = CMTimeAdd(CMTimeMake(last.observed.value,last.observed.timescale),
                                         CMTimeMake(media::codec::kAacLcSamplesPerAccessUnit,aac_timeline_->rate()));
          if (CMTimeCompare(audioEnd,readerEnd)>0) readerEnd=audioEnd;
        }
        const auto range = exactReaderTimeRangeFacts(readerEnd, decodeStart);
        if (!range) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error = "native reader range is not exactly representable";
          return result;
        }
        reader.timeRange = *range;
      }
      {
        std::lock_guard lock(objects_mutex_);
        reader_ = reader;
        video_output_ = videoOutput;
        audio_output_ = audioOutput;
      }
      if (cancelled_.load(std::memory_order_acquire)) {
        cancel();
        result.status = AVFoundationGenerationStatus::Cancelled;
        return result;
      }
      if (![reader startReading]) {
        result.error = describeNSError(reader.error,
                                       "AVAssetReader could not start");
        return result;
      }
      noteAVFoundationAssetContextReaderStarted(*assetContext);
      result.status = AVFoundationGenerationStatus::Ready;
      result.actualDecodeStart = *exactStart;
      result.descriptor = std::move(descriptor);
      result.assetContext = std::move(assetContext);
      return result;
    }
  }

  [[nodiscard]] CMTime videoMovieTimelineShift() const noexcept override {
    return video_movie_shift_;
  }

  [[nodiscard]] AVFoundationCopiedSample
  copyNextVideoSample() override {
    AVFoundationCopiedSample copied = copyNext(video_output_);
    if (copied.status != AVFoundationSampleReadStatus::Sample ||
        copied.sample == nullptr) {
      return copied;
    }
    ScopedSampleBuffer read(copied.sample);
    copied.sample =
        restatedVideoOnMovieTimeline(read.get(), video_movie_shift_);
    if (copied.sample == nullptr) {
      copied.status = AVFoundationSampleReadStatus::Failed;
      copied.error =
          "AVFoundation video access unit is not exactly restatable on the "
          "movie timeline";
    }
    return copied;
  }
  [[nodiscard]] AVFoundationCopiedSample
  copyNextAudioSample() override {
    AVFoundationCopiedSample copied = nextAudioAccessUnits();
    if (copied.status != AVFoundationSampleReadStatus::Sample ||
        copied.sample == nullptr) {
      return copied;
    }
    ScopedSampleBuffer read(copied.sample);
    copied.sample = restatedOnMediaTimeline(read.get());
    if (copied.sample == nullptr) {
      copied.status = AVFoundationSampleReadStatus::Failed;
      copied.error =
          "AVFoundation audio access unit is not exactly restatable on its "
          "media timeline";
      return copied;
    }
    const auto format = CMSampleBufferGetFormatDescription(copied.sample);
    const auto* asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : nullptr;
    if (asbd && asbd->mFormatID == kAudioFormatMPEG4AAC && !audio_first_unit_restated_ &&
        (!request_.target || request_.target->value == 0) &&
        CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(copied.sample), audio_media_start_) > 0) {
      CFRelease(copied.sample);
      copied.sample = nullptr;
      copied.status = AVFoundationSampleReadStatus::Failed;
      copied.error = "AacEditedReaderOriginUnproven: reader omitted required priming packets";
      return copied;
    }
    provedImmediatePlayoutOnFirstUnit(copied.sample);
    return copied;
  }

  void cancel() noexcept override {
    cancelled_.store(true, std::memory_order_release);
    dispatch_source_merge_data(cancellation_source_, 1);
  }

 private:
  void cancelObjects() noexcept {
    try {
      metadata_load_signal_->cancel();
      @autoreleasepool {
        AVURLAsset* loadingAsset = nil;
        AVAssetReader* reader = nil;
        {
          std::lock_guard lock(objects_mutex_);
          loadingAsset = loading_asset_;
          loading_asset_ = nil;
          if (!reader_cancellation_issued_ && reader_ != nil) {
            reader = reader_;
            reader_cancellation_issued_ = true;
          }
        }
        [loadingAsset cancelLoading];
        [reader cancelReading];
      }
    } catch (...) {
      // Cancellation is best-effort at the Apple boundary, but the atomic
      // cancellation proof remains published even if platform cleanup fails.
    }
  }

 private:
  [[nodiscard]] std::optional<MediaTrackDescriptor> describeVideo(
      AVAssetTrack* track, const MediaSourceLimits& limits,
      std::string* error) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray* formats = track.formatDescriptions;
    const CMTimeScale naturalTimeScale = track.naturalTimeScale;
    const CMTime trackDuration = track.timeRange.duration;
    const CGAffineTransform transform = track.preferredTransform;
    NSString* language = track.extendedLanguageTag != nil
                             ? track.extendedLanguageTag
                             : track.languageCode;
#pragma clang diagnostic pop
    const auto duration = canonicalDuration(trackDuration);
    if (formats.count != 1 || !duration) {
      assignError(error, "video track lacks one immutable exact format");
      return std::nullopt;
    }
    const std::optional<int> rotationDegrees = quarterTurnDegrees(transform);
    if (!rotationDegrees) {
      // Refused by name, for the transforms this player genuinely cannot
      // present: shears, flips, and arbitrary
      // angles. A quarter turn is admitted and carried on the descriptor.
      assignError(error,
                  "video transform is not a quarter turn and is outside the "
                  "native v1 descriptor");
      return std::nullopt;
    }
    auto format =
        (__bridge CMVideoFormatDescriptionRef)formats.firstObject;
    // Name the coded-dimension refusal before the general inspection runs.
    // inspectVideoFormatFacts folds every unadmitted trait into one nullopt,
    // so a 4320p file and a Dolby Vision file arrive here indistinguishable;
    // the dimension case is the one that a user can act on and the one that a
    // field report has to be able to state, so it is checked first and said
    // out loud with both numbers.
    const CMVideoDimensions coded =
        CMVideoFormatDescriptionGetDimensions(format);
    if (coded.width > 0 && coded.height > 0 &&
        !media::codedDimensionsWithinV1Ceiling(
            static_cast<std::uint64_t>(coded.width),
            static_cast<std::uint64_t>(coded.height))) {
      const std::string refusal = media::refusalMessage(
          media::codedDimensionRefusalMessage(
              static_cast<std::uint64_t>(coded.width),
              static_cast<std::uint64_t>(coded.height)),
          media::MediaRefusalClass::CodedDimensionLimit);
      assignError(error, refusal.c_str());
      return std::nullopt;
    }
    auto result = inspectVideoFormatImpl(
        format, stableTrackId(track, 1), *duration, limits, error);
    if (result && naturalTimeScale > 0) {
      result->timeBase = {1, naturalTimeScale};
    }
    if (result) {
      result->video->identityTransform = *rotationDegrees == 0;
      result->video->rotationDegrees =
          static_cast<std::int16_t>(*rotationDegrees);
      // displayWidth/displayHeight stay in CODED orientation on purpose.
      // mediaVideoDisplaySize() is the one place the quarter turn is applied
      // to the rectangle, and it transposes these itself; transposing them
      // here as well would turn the portrait window back into a landscape
      // one, and would break mediaVideoHasSquarePixels/HasFullCodedAperture,
      // which compare the display rectangle against the coded one.
    }
    if (result && !copyBoundedString(language, limits.maximumTrackTextBytes,
                                     &result->language)) {
      assignError(error, "video language metadata exceeds native bounds");
      return std::nullopt;
    }
    return result;
  }

  [[nodiscard]] std::optional<MediaTrackDescriptor> describeAudio(
      AVAssetTrack* track, MediaTrackId id, const MediaSourceLimits& limits,
      std::string* error) {
    aac_timeline_.reset();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray* formats = track.formatDescriptions;
    const CMTimeScale naturalTimeScale = track.naturalTimeScale;
    const CMTime trackDuration = track.timeRange.duration;
    NSString* language = track.extendedLanguageTag != nil
                             ? track.extendedLanguageTag
                             : track.languageCode;
#pragma clang diagnostic pop
    const auto duration = canonicalDuration(trackDuration);
    if (formats.count != 1 || !duration) {
      assignError(error, "audio track lacks one immutable exact format");
      return std::nullopt;
    }
    auto format = (__bridge CMAudioFormatDescriptionRef)formats.firstObject;
    auto result = inspectAudioFormatImpl(format, id, *duration, limits, error);
    if (result && !validateWaveAdpcm(*result, request_.path, error)) return std::nullopt;
    if (result && result->codec == MediaCodec::Aac) {
      // AVSampleCursor walks the sample table, including packets outside an
      // edit. No compressed payload is read or retained by this open proof.
      if (result->audio->framesPerPacket !=
          media::codec::kAacLcSamplesPerAccessUnit) {
        assignError(error, "AacPacketFrameLengthUnsupported");
        return std::nullopt;
      }
      const auto aacProofStart = std::chrono::steady_clock::now();
      AVSampleCursor* cursor = [track makeSampleCursorAtFirstSampleInDecodeOrder];
      const auto exactRate = media::exactAudioSampleRate(result->audio->sampleRate);
      const std::uint32_t rate = exactRate.value_or(0U);
      std::uint64_t ordinal = 0;
      auto timeline = std::make_shared<media::AacPacketTimeline>(rate);
      if (!cursor || !exactRate) {
        assignError(error, "AacPacketTimelineProofUnavailable");
        return std::nullopt;
      }
      do {
        const auto pts = cursor.presentationTimeStamp;
        if (cancelled_.load(std::memory_order_acquire) || ordinal >= media::kMaximumAudioIndexScanPackets) {
          assignError(error, "AacPacketTimelineScanLimitOrCancelled");
          return std::nullopt;
        }
        if (ordinal == 0 && !exactZero(pts)) {
          assignError(error, "AacPacketMediaOriginUnproven");
          return std::nullopt;
        }
        if (!CMTIME_IS_NUMERIC(pts) ||
            !timeline->append({pts.value,pts.timescale},
                {cursor.currentSampleDuration.value,cursor.currentSampleDuration.timescale})) {
          assignError(error, "AacPacketTimelineDiscontinuity: unrepresentable piecewise grid");
          return std::nullopt;
        }
        ++ordinal;
      } while ([cursor stepInDecodeOrderByCount:1] == 1);
      if (media::late_trace::enabled) std::fprintf(stderr,
          "WAM: AAC packet table packets=%llu scan_ms=%.3f\n",ordinal,
          std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-aacProofStart).count());
      if (!timeline->finish()) { assignError(error,"AacPacketTailTrimUnproven"); return std::nullopt; }
      aac_timeline_ = timeline;
      // The table separates the 1024-frame decode budget from each packet
      // presentation extent, including interior overlap trims and gaps.
      const auto tail = exactMediaTime(cursor.currentSampleDuration);
      const auto tailFrames = tail ? media::exactAudioFrameIndex(*tail,rate) : std::nullopt;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      const auto edits = audioMovieTimelineFactsFor(track.segments);
#pragma clang diagnostic pop
      if (!tailFrames || *tailFrames <= 0 || !edits) {
        assignError(error, "AacPacketTailTrimUnproven");
        return std::nullopt;
      }
      // Validate the reader's stream-origin witness even for an initial
      // nonzero target. Some edits make AVAssetReader silently omit priming
      // units; such an asset must choose the exact demux route at OPEN.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      NSError* originError = nil;
      AVAssetReader* originReader = [AVAssetReader assetReaderWithAsset:track.asset error:&originError];
#pragma clang diagnostic pop
      AVAssetReaderTrackOutput* originOutput = [AVAssetReaderTrackOutput
          assetReaderTrackOutputWithTrack:track outputSettings:nil];
      if (!originReader || ![originReader canAddOutput:originOutput]) {
        assignError(error, "AacEditedReaderOriginUnproven");
        return std::nullopt;
      }
      [originReader addOutput:originOutput];
      const bool reading = [originReader startReading];
      CMSampleBufferRef first = reading ? [originOutput copyNextSampleBuffer] : nullptr;
      const bool originProved = first &&
          CMTimeCompare(CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(first),edits->shift),edits->mediaStart) <= 0;
      if (first) CFRelease(first);
      [originReader cancelReading];
      if (!originProved) {
        assignError(error, "AacEditedReaderOriginUnproven: reader omitted required priming packets");
        return std::nullopt;
      }
      const auto shift = audioFrameAlignedEditTime(edits->shift,rate);
      const auto shiftFrames = shift ? media::exactAudioFrameIndex({shift->value,shift->timescale},rate) : std::nullopt;
      const auto editEnd = media::audioFrameAtOrAfter(result->duration,rate);
      if (!shiftFrames || !editEnd) return std::nullopt;
      const MediaTime packetEnd{timeline->packets().back().start +
          timeline->packets().back().duration + *shiftFrames,static_cast<std::int32_t>(rate)};
      result->duration = media::compareMediaTime(packetEnd,*editEnd)==MediaTimeOrder::Less ? packetEnd : *editEnd;
      if (media::late_trace::enabled) std::fprintf(stderr,
          "WAM: AAC proof packets=%llu total_ms=%.3f shift=%lld packet_end=%lld edit_end=%lld\n",
          ordinal, std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-aacProofStart).count(),
          *shiftFrames,packetEnd.value,editEnd->value);
    }

    if (result && naturalTimeScale > 0) {
      result->timeBase = {1, naturalTimeScale};
    }
    if (result && !copyBoundedString(language, limits.maximumTrackTextBytes,
                                     &result->language)) {
      assignError(error, "audio language metadata exceeds native bounds");
      return std::nullopt;
    }
    return result;
  }

  [[nodiscard]] bool addOutput(AVAssetReader* reader, AVAssetTrack* track,
                               AVAssetReaderTrackOutput** output,
                               std::string* error) {
    AVAssetReaderTrackOutput* created =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                                        outputSettings:nil];
    created.alwaysCopiesSampleData = NO;
    if (created == nil || ![reader canAddOutput:created]) {
      assignError(error, "AVAssetReader cannot expose original samples");
      return false;
    }
    [reader addOutput:created];
    *output = created;
    return true;
  }

  // States the ImmediatePlayoutFrame proof on the generation's first restated
  // audio access unit, and only there: the converter reads the attachment
  // exactly once, before its input timeline exists. The unit must first clear
  // the priming ceiling this generation's reader range was placed against, so
  // the proof is measured rather than assumed. A unit that does not clear it
  // is left unproved on purpose - the converter then rejects the generation
  // instead of publishing PCM whose decoder was never primed. Media-free
  // markers carry no access unit and never consume the first-unit slot.
  void provedImmediatePlayoutOnFirstUnit(CMSampleBufferRef sample) noexcept {
    if (audio_first_unit_restated_ || sample == nullptr ||
        CMSampleBufferGetNumSamples(sample) <= 0) {
      return;
    }
    audio_first_unit_restated_ = true;
    if (!audio_playout_proof_ceiling_) {
      return;
    }
    const auto ceiling = exactCMTime(*audio_playout_proof_ceiling_);
    // Measure the projected movie stamp, including a possible 256-frame
    // advance. The reader's two-unit slack covers that advance without
    // relaxing the priming ceiling or changing the first audible frame.
    const CMTime start = CMSampleBufferGetPresentationTimeStamp(sample);
    if (!ceiling || !CMTIME_IS_NUMERIC(start) ||
        CMTimeCompare(start, *ceiling) > 0) {
      return;
    }
    static_cast<void>(statedImmediatePlayoutFrame(sample));
  }

  // AVFoundation states every audio access unit twice: the track's own media
  // timeline as input timing, and the asset's edited timeline as output timing
  // together with the container attachments that describe the difference (edit
  // priming trim and the AAC decoder refresh count). Native v1 owns its
  // decode-versus-presentation window itself, so each unit's input (media)
  // timing is restated on the codec's ordinal packet grid -- including the
  // container's end trim folded into the final access unit's duration -- then
  // carried onto the MOVIE timeline by the track's exact edit shift, and the
  // trim attachments are dropped. Compressed audio decode order is
  // presentation order, so the redundant decode stamp is dropped rather than
  // reconciled. Returns a +1 reference, or null when the unit cannot be
  // restated exactly.
  [[nodiscard]] CMSampleBufferRef restatedOnMediaTimeline(
      CMSampleBufferRef sample) noexcept {
    CMItemCount entries = 0;
    if (sample == nullptr ||
        CMSampleBufferGetSampleTimingInfoArray(
            sample, static_cast<CMItemCount>(audio_timing_.size()),
            audio_timing_.data(), &entries) != noErr ||
        entries <= 0 ||
        static_cast<std::size_t>(entries) > audio_timing_.size()) {
      return nullptr;
    }
    if (aac_timeline_) {
      // AVAssetReader can compress equal timings into a single entry. Expand
      // before lookup so every access unit uses its open-time proof.
      const auto count = CMSampleBufferGetNumSamples(sample);
      if (count <= 0 || count > static_cast<CMItemCount>(audio_timing_.size())) return nullptr;
      if (entries == 1 && count > 1) {
        const auto first = audio_timing_[0];
        for (CMItemCount i = 1; i < count; ++i) {
          audio_timing_[i] = first;
          audio_timing_[i].presentationTimeStamp = CMTimeAdd(first.presentationTimeStamp,
              CMTimeMultiply(first.duration, static_cast<int32_t>(i)));
        }
        entries = count;
      }
      for (CMItemCount i = 0; i < entries; ++i) {
        auto& timing = audio_timing_[i];
        const auto* packet = aac_timeline_->find({timing.presentationTimeStamp.value,
                                                timing.presentationTimeStamp.timescale});
        if (!packet) return nullptr;
        timing.presentationTimeStamp = CMTimeMake(packet->start,aac_timeline_->rate());
        timing.duration = CMTimeMake(packet->duration,aac_timeline_->rate());
      }
    } else {
      static_cast<void>(restateCompressedAudioPacketDurations(
          sample, audio_timing_.data(), static_cast<std::size_t>(entries)));
      static_cast<void>(projectCompressedAudioPacketTiming(
          sample, audio_timing_.data(), static_cast<std::size_t>(entries)));
    }
    for (CMItemCount index = 0; index < entries; ++index) {
      CMSampleTimingInfo& timing =
          audio_timing_[static_cast<std::size_t>(index)];
      timing.decodeTimeStamp = kCMTimeInvalid;
      // A media timeline is one epoch. An access unit AVFoundation states in a
      // later epoch still occupies the same position on the track's own
      // timeline, so republish it there instead of rejecting it.
      timing.presentationTimeStamp.epoch = 0;
      timing.duration.epoch = 0;
      // Restate the unit on the MOVIE timeline. The shift is the container's
      // own exact rational; a unit that cannot carry it exactly is refused
      // rather than rounded, which is what keeps the frame grid exact.
      const CMTime moved =
          CMTimeAdd(timing.presentationTimeStamp, audio_movie_shift_);
      if (!CMTIME_IS_NUMERIC(moved) ||
          (moved.flags & kCMTimeFlags_HasBeenRounded) != 0 ||
          moved.timescale <= 0) {
        return nullptr;
      }
      timing.presentationTimeStamp = moved;
      timing.presentationTimeStamp.epoch = 0;
    }
    CMRemoveAttachment(sample,
                       kCMSampleBufferAttachmentKey_TrimDurationAtStart);
    CMRemoveAttachment(sample, kCMSampleBufferAttachmentKey_TrimDurationAtEnd);
    CMRemoveAttachment(sample,
                       kCMSampleBufferAttachmentKey_GradualDecoderRefresh);
    // Redundant: the offset this attachment annotated has been applied to the
    // timestamps above, so the silence it asked the consumer to fill is
    // already accounted for on the movie timeline. It must only be stripped
    // together with that shift, or audio desyncs by the shift.
    CMRemoveAttachment(
        sample, kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence);
    CMSampleBufferRef restated = nullptr;
    if (CMSampleBufferCreateCopyWithNewTiming(
            kCFAllocatorDefault, sample, entries, audio_timing_.data(),
            &restated) != noErr ||
        restated == nullptr) {
      if (restated != nullptr) {
        CFRelease(restated);
      }
      return nullptr;
    }
    if (CMSampleBufferSetOutputPresentationTimeStamp(
            restated, CMSampleBufferGetPresentationTimeStamp(restated)) !=
        noErr) {
      CFRelease(restated);
      return nullptr;
    }
    if (aac_timeline_) CMSetAttachment(restated, aacPiecewiseTimelineAttachmentKey(),
        kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    return restated;
  }

  // One staged sample's worth of audio access units, drawn from the reader's
  // own batch and re-cut to the native bound when the batch is larger than it.
  // The steady state is a pass-through: a batch from a normally interleaved
  // compressed track already fits, so nothing is copied and nothing is
  // retained. LPCM, whose batch is the reader's whole 2 s read, and a batch
  // that is long in media time (a non-interleaved track) enter the re-cut
  // path.
  [[nodiscard]] AVFoundationCopiedSample nextAudioAccessUnits() {
    if (audio_batch_.get() != nullptr) {
      return takeAudioBatchChunk();
    }
    AVFoundationCopiedSample copied = copyNext(audio_output_);
    if (copied.status != AVFoundationSampleReadStatus::Sample ||
        copied.sample == nullptr) {
      return copied;
    }
    const CMItemCount units = CMSampleBufferGetNumSamples(copied.sample);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(copied.sample);
    const std::size_t bytes =
        block == nullptr ? 0 : CMBlockBufferGetDataLength(block);
    // The pass-through test must ask the same three questions the re-cut
    // answers -- count, bytes AND media time -- or a batch that is small in
    // memory but long in time (140 AAC units, 70 KiB, 2.9867 s, which is what a
    // non-interleaved MP4 vends) would never enter the re-cut path at all.
    const CMItemCount timeBound =
        audioBatchUnitsWithinStagedDuration(copied.sample);
    if (units <= static_cast<CMItemCount>(
                     audio_limits_.maximumAudioSampleCount) &&
        bytes <= audio_limits_.maximumAudioSampleBytes &&
        (timeBound <= 0 || units <= timeBound)) {
      return copied;
    }
    audio_batch_.reset(copied.sample);
    audio_batch_units_ = units;
    audio_batch_cursor_ = 0;
    copied.sample = nullptr;
    return takeAudioBatchChunk();
  }

  // The next chunk of the retained batch, releasing the batch on its last one.
  [[nodiscard]] AVFoundationCopiedSample takeAudioBatchChunk() {
    AVFoundationCopiedSample result;
    const CMItemCount length =
        audioBatchChunkLength(audio_batch_.get(), audio_batch_cursor_,
                              audio_batch_units_, audio_limits_);
    CMSampleBufferRef chunk = nullptr;
    if (length <= 0 ||
        CMSampleBufferCopySampleBufferForRange(
            kCFAllocatorDefault, audio_batch_.get(),
            CFRangeMake(static_cast<CFIndex>(audio_batch_cursor_),
                        static_cast<CFIndex>(length)),
            &chunk) != noErr ||
        chunk == nullptr) {
      if (chunk != nullptr) {
        CFRelease(chunk);
      }
      releaseAudioBatch();
      result.status = AVFoundationSampleReadStatus::Failed;
      result.error =
          "AVFoundation audio batch is not exactly re-cuttable to the native "
          "access unit bound";
      return result;
    }
    audio_batch_cursor_ += length;
    if (audio_batch_cursor_ >= audio_batch_units_) {
      releaseAudioBatch();
    }
    result.sample = chunk;
    result.status = AVFoundationSampleReadStatus::Sample;
    return result;
  }

  void releaseAudioBatch() noexcept {
    audio_batch_.reset();
    audio_batch_units_ = 0;
    audio_batch_cursor_ = 0;
  }

  [[nodiscard]] AVFoundationCopiedSample copyNext(
      AVAssetReaderTrackOutput* output) {
    AVFoundationCopiedSample result;
    if (cancelled_.load(std::memory_order_acquire)) {
      result.status = AVFoundationSampleReadStatus::Cancelled;
      return result;
    }
    if (output == nil) {
      result.status = AVFoundationSampleReadStatus::EndOfStream;
      return result;
    }
    // Every AVFoundation track output ends in a marker tail that states no
    // media on the track's own timeline: a decoder-drain request, a consumed
    // notification request, and the edit list's empty-media terminator. Native
    // v1 owns its decoder lifecycle and its own end of stream, so none of these
    // are publishable and none of them are faults. Drop them and read on; the read after the tail reports the
    // terminal status. Timed discontinuity markers are not dropped here.
    bool exhausted = true;
    for (std::size_t marker = 0; marker != kMaximumMediaFreeMarkers; ++marker) {
      CMSampleBufferRef sample = [output copyNextSampleBuffer];
      if (sample == nullptr) {
        exhausted = false;
        break;
      }
      if (!mediaFreeMarker(sample)) {
        result.sample = sample;
        result.status = AVFoundationSampleReadStatus::Sample;
        return result;
      }
      CFRelease(sample);
      if (cancelled_.load(std::memory_order_acquire)) {
        result.status = AVFoundationSampleReadStatus::Cancelled;
        return result;
      }
    }
    if (exhausted) {
      result.status = AVFoundationSampleReadStatus::Failed;
      result.error = "AVFoundation output produced only media-free markers";
      return result;
    }
    const AVAssetReaderStatus status = reader_.status;
    if (cancelled_.load(std::memory_order_acquire) ||
        status == AVAssetReaderStatusCancelled) {
      result.status = AVFoundationSampleReadStatus::Cancelled;
    } else if (status == AVAssetReaderStatusFailed) {
      result.status = AVFoundationSampleReadStatus::Failed;
      result.error = describeNSError(reader_.error,
                                     "AVAssetReader sample read failed");
    } else {
      // An individual output may end while the shared reader is still Reading
      // because the other selected output has later timestamps.
      result.status = AVFoundationSampleReadStatus::EndOfStream;
    }
    return result;
  }

  std::shared_ptr<const media::AacPacketTimeline> aac_timeline_;
  std::optional<media::codec::Mp3LameGapless> mp3_gapless_;
  AVFoundationGenerationRequest request_;
  std::array<CMSampleTimingInfo,
             media::MediaSourceLimits::kHardMaximumAudioSampleCount>
      audio_timing_{};
  // Set by start() only for an accurate generation with selected audio: the
  // latest first-access-unit timestamp that still leaves the full priming
  // distance ahead of the generation's first audible frame.
  std::optional<MediaTime> audio_playout_proof_ceiling_;
  // This generation's exact audio media-to-movie timeline shift, and the movie
  // time at which audio media begins (nonzero only for a leading empty edit).
  CMTime audio_movie_shift_{kCMTimeZero};
  CMTime audio_media_start_{kCMTimeZero};
  // This generation's exact video media-to-movie timeline shift. Zero for a
  // container with no edit list, and for any edit shape that is not a single
  // constant displacement -- both of which leave video stamps unshifted.
  CMTime video_movie_shift_{kCMTimeZero};
  // Movie time at which this generation's presentation must end when the
  // selected video runs past the end of the selected audio. Invalid means the
  // generation ends at its own audio end, which is every ordinary source.
  CMTime audio_presentation_end_{kCMTimeInvalid};
  // Movie time at which the selected audio media ends, beside the above.
  CMTime audio_media_end_{kCMTimeInvalid};
  bool audio_first_unit_restated_{false};
  // This generation's clamped staging bounds, and the reader batch currently
  // being re-cut against them. The batch is null in the steady state.
  MediaSourceLimits audio_limits_{};
  ScopedSampleBuffer audio_batch_;
  CMItemCount audio_batch_units_{0};
  CMItemCount audio_batch_cursor_{0};
  std::atomic<bool> cancelled_{false};
  const std::shared_ptr<AsyncLoadSignal> metadata_load_signal_{
      std::make_shared<AsyncLoadSignal>()};
  dispatch_queue_t cancellation_queue_;
  dispatch_source_t cancellation_source_;
  dispatch_semaphore_t cancellation_done_;
  bool reader_cancellation_issued_{false};
  std::mutex objects_mutex_;
  // Non-null only during the cold metadata prepare. Once the immutable
  // context is published, cancellation touches readers but never the asset.
  __strong AVURLAsset* loading_asset_{nil};
  __strong AVAssetReader* reader_{nil};
  __strong AVAssetReaderTrackOutput* video_output_{nil};
  __strong AVAssetReaderTrackOutput* audio_output_{nil};
};

class ProductionBackend final : public AVFoundationBackend {
 public:
  [[nodiscard]] std::shared_ptr<AVFoundationGeneration> makeGeneration(
      AVFoundationGenerationRequest request) override {
    return std::make_shared<ProductionGeneration>(std::move(request));
  }
};

[[nodiscard]] bool sampleFormatMatchesTrack(
    CMSampleBufferRef sample, const MediaTrackDescriptor& track,
    const MediaSourceLimits& requestedLimits) noexcept {
  CMFormatDescriptionRef format =
      CMSampleBufferGetFormatDescription(sample);
  if (format == nullptr) {
    return false;
  }
  if (track.kind == MediaTrackKind::Video) {
    return videoFormatMatchesTrack(
        static_cast<CMVideoFormatDescriptionRef>(format), track,
        requestedLimits);
  }
  return audioFormatMatchesTrack(
      static_cast<CMAudioFormatDescriptionRef>(format), track);
}

struct AVFoundationSourceTraits {
  static constexpr const char* kName = "AVFoundation";
  using AssetContext = AVFoundationAssetContext;
};

[[nodiscard]] media::MediaSourceOpenStatus openStatus(
    AVFoundationGenerationStatus status) noexcept {
  switch (status) {
    case AVFoundationGenerationStatus::Ready:
      return media::MediaSourceOpenStatus::Ready;
    case AVFoundationGenerationStatus::Unsupported:
      return media::MediaSourceOpenStatus::Unsupported;
    case AVFoundationGenerationStatus::Cancelled:
      return media::MediaSourceOpenStatus::Cancelled;
    case AVFoundationGenerationStatus::Failed:
      break;
  }
  return media::MediaSourceOpenStatus::Failed;
}

}  // namespace

struct AVFoundationMediaSource::Impl final
    : NativeSourceCore<Impl, AVFoundationSourceTraits> {
  explicit Impl(std::shared_ptr<AVFoundationBackend> suppliedBackend)
      : backend(suppliedBackend != nullptr
                    ? std::move(suppliedBackend)
                    : std::make_shared<ProductionBackend>()) {}

  std::shared_ptr<AVFoundationBackend> backend;
  std::shared_ptr<AVFoundationGeneration> ownerGeneration;
  // Apple libc++ deployments supported by WAM do not all provide the C++20
  // atomic<shared_ptr> specialization. The standard shared_ptr atomic free
  // functions provide the same lifetime-safe publication on those runtimes.
  std::shared_ptr<AVFoundationGeneration> publishedGeneration;
  std::atomic<unsigned> cancellationReaders{0};

  // Per-generation admission cache for the compressed sample's format
  // description. sampleFormatMatchesTrack walks roughly two dozen
  // CoreFoundation dictionary lookups and, for H.264/HEVC, an exp-Golomb walk
  // of the SPS -- 2-10 us on EVERY frame, spent re-deriving an answer that
  // cannot change while the format description object is the same one: per-open
  // work that must not run per sample.
  //
  // CMFormatDescription is immutable, so pointer identity is a sound proof --
  // but only against a RETAINED reference, which is what stops a released
  // description's address from being recycled by a different one and silently
  // passing. A different pointer, or a different selected track, still takes
  // the full validation path and still fails closed.
  struct RetainedFormat {
    RetainedFormat() = default;
    RetainedFormat(const RetainedFormat&) = delete;
    RetainedFormat& operator=(const RetainedFormat&) = delete;
    ~RetainedFormat() {
      if (value != nullptr) {
        CFRelease(value);
      }
    }
    void reset(CMFormatDescriptionRef next) noexcept {
      if (next != nullptr) {
        CFRetain(next);
      }
      if (value != nullptr) {
        CFRelease(value);
      }
      value = next;
    }
    CMFormatDescriptionRef value{nullptr};
  };
  RetainedFormat admittedFormat;
  const MediaTrackDescriptor* admittedFormatTrack{nullptr};

  // The reader does not poll the cancellation latch, so a published
  // cancellation also cancels the live generation directly.
  void cancellationPublished(MediaGeneration requested) noexcept {
    struct Pin {
      std::atomic<unsigned>& readers;
      explicit Pin(std::atomic<unsigned>& value) : readers(value) { readers.fetch_add(1); }
      ~Pin() { readers.fetch_sub(1); readers.notify_all(); }
    } pin(cancellationReaders);
    auto active = std::atomic_load_explicit(&publishedGeneration,
                                            std::memory_order_seq_cst);
    if (active != nullptr && active->generation() == requested) {
      active->cancel();
    }
  }

  void retireActive() noexcept {
    auto active = std::atomic_exchange_explicit(
        &publishedGeneration, std::shared_ptr<AVFoundationGeneration>{},
        std::memory_order_seq_cst);
    if (active != nullptr) {
      active->cancel();
    }
    ownerGeneration.reset();
    // Generation destruction belongs to this source owner, never a cancelling caller.
    auto readers = cancellationReaders.load();
    while (readers != 0) {
      cancellationReaders.wait(readers);
      readers = cancellationReaders.load();
    }
  }

  [[nodiscard]] std::optional<StagedSample> makeHead(
      ScopedSampleBuffer owned, MediaTrackId trackId, MediaSampleKind kind,
      std::string* error) {
    CMSampleBufferRef sample = owned.get();
    if (sample == nullptr || !CMSampleBufferIsValid(sample) ||
        !CMSampleBufferDataIsReady(sample)) {
      assignError(error, "AVFoundation yielded an invalid sample buffer");
      return std::nullopt;
    }
    const MediaTrackDescriptor* track =
        media::findMediaTrack(*descriptor, trackId);
    CMTime presentation = CMSampleBufferGetPresentationTimeStamp(sample);
    // A video discontinuity marker still states its MEDIA-timeline stamp:
    // the per-buffer timing copy that restates every compressed video unit
    // has no timing array to work on for a marker. Its one stamp is carried
    // here, and only here -- a compressed unit is already restated and must
    // not be moved twice.
    if (kind == MediaSampleKind::EncodedVideo &&
        CMSampleBufferGetNumSamples(sample) == 0 && ownerGeneration) {
      const auto moved = restatedOnMovieTimeline(
          presentation, ownerGeneration->videoMovieTimelineShift());
      if (!moved) {
        assignError(error,
                    "video discontinuity marker is not exactly restatable "
                    "on the movie timeline");
        return std::nullopt;
      }
      presentation = *moved;
    }
    const auto pts = exactMediaTime(presentation);
    if (!pts) {
      assignError(error, "sample has no exact presentation timestamp");
      return std::nullopt;
    }
    const MediaTime dts =
        optionalMediaTime(CMSampleBufferGetDecodeTimeStamp(sample));
    const MediaTime duration = optionalMediaTime(CMSampleBufferGetDuration(sample));
    if (duration.valid() && duration.value < 0) {
      assignError(error, "sample has negative duration");
      return std::nullopt;
    }
    const CMItemCount signedCount = CMSampleBufferGetNumSamples(sample);
    if (signedCount < 0 ||
        static_cast<std::uint64_t>(signedCount) >
            std::numeric_limits<std::uint32_t>::max()) {
      assignError(error, "sample count is outside the native scalar range");
      return std::nullopt;
    }
    const std::uint32_t sampleCount = static_cast<std::uint32_t>(signedCount);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    const std::size_t bytes =
        block == nullptr ? 0 : CMBlockBufferGetDataLength(block);
    const MediaTime order = dts.valid() ? dts : *pts;
    if (sampleCount == 0 && bytes == 0) {
      media::MediaDiscontinuity discontinuity{generation, trackId, *pts};
      CMFormatDescriptionRef markerFormat =
          CMSampleBufferGetFormatDescription(sample);
      if (track == nullptr ||
          (markerFormat != nullptr &&
           !sampleFormatMatchesTrack(sample, *track, limits)) ||
          !media::validateMediaDiscontinuity(discontinuity, *descriptor,
                                             error)) {
        if (error != nullptr && error->empty()) {
          assignError(error,
                      "sample discontinuity changed immutable format");
        }
        return std::nullopt;
      }
      return StagedSample{trackId, order, std::move(discontinuity), 0};
    }
    if (sampleCount == 0 || bytes == 0) {
      assignError(error, "compressed sample has inconsistent empty payload");
      return std::nullopt;
    }
    if (track == nullptr) {
      assignError(error,
                  "sample format changed after immutable admission");
      return std::nullopt;
    }
    // Steady state is one pointer compare; see RetainedFormat above.
    CMFormatDescriptionRef sampleFormat =
        CMSampleBufferGetFormatDescription(sample);
    if (sampleFormat != admittedFormat.value || track != admittedFormatTrack) {
      if (!sampleFormatMatchesTrack(sample, *track, limits)) {
        assignError(error,
                    "sample format changed after immutable admission");
        return std::nullopt;
      }
      admittedFormat.reset(sampleFormat);
      admittedFormatTrack = track;
    }
    if ((kind == MediaSampleKind::EncodedVideo && sampleCount != 1) ||
        (kind == MediaSampleKind::EncodedAudio &&
         sampleCount > limits.maximumAudioSampleCount) ||
        (kind == MediaSampleKind::EncodedVideo &&
         bytes > limits.maximumVideoSampleBytes) ||
        (kind == MediaSampleKind::EncodedAudio &&
         bytes > limits.maximumAudioSampleBytes)) {
      assignError(error, "compressed sample exceeds native memory bounds");
      return std::nullopt;
    }
    bool keyFrame = true;
    if (kind == MediaSampleKind::EncodedVideo &&
        !sampleIsKeyFrame(sample, &keyFrame)) {
      assignError(error, "video sample has malformed sync attachments");
      return std::nullopt;
    }

    auto storage = std::make_shared<CoreMediaSampleStorage>(owned.release(), bytes);
    MediaSample mediaSample;
    mediaSample.generation = generation;
    mediaSample.track = trackId;
    mediaSample.kind = kind;
    mediaSample.presentationTime = *pts;
    mediaSample.decodeTime = dts;
    mediaSample.duration = duration;
    mediaSample.keyFrame = keyFrame;
    mediaSample.sampleCount = sampleCount;
    mediaSample.payload = MediaPayloadLease(std::move(storage));
    if (kind == MediaSampleKind::EncodedVideo && requestedTarget &&
        seekMode == media::MediaSeekMode::Accurate) {
      const auto decodeOnly = accurateVideoDecodeOnly(
          *pts, duration, *requestedTarget, error);
      if (!decodeOnly) {
        return std::nullopt;
      }
      mediaSample.decodeOnly = *decodeOnly;
    }
    if (!media::validateMediaSample(mediaSample, *descriptor, limits, error)) {
      return std::nullopt;
    }
    return StagedSample{trackId, order, std::move(mediaSample), bytes};
  }

  [[nodiscard]] bool stage(bool video, bool admission, std::string* error) {
    const std::optional<MediaTrackId> selected =
        video ? descriptor->selectedVideo : descriptor->selectedAudio;
    if (!selected) {
      (video ? videoTerminal : audioTerminal) = true;
      return true;
    }
    for (std::size_t skipped = 0;;) {
      AVFoundationCopiedSample copied =
          video ? ownerGeneration->copyNextVideoSample()
                : ownerGeneration->copyNextAudioSample();
      ScopedSampleBuffer owned(copied.sample);
      if (copied.status == AVFoundationSampleReadStatus::Cancelled ||
          isCancelled()) {
        publishCancellation(generation);
        if (error != nullptr) {
          *error = "AVFoundation generation was cancelled";
        }
        return false;
      }
      if (copied.status == AVFoundationSampleReadStatus::Failed ||
          (copied.status == AVFoundationSampleReadStatus::Sample &&
           copied.sample == nullptr)) {
        if (error != nullptr) {
          *error = copied.error.empty() ? "AVFoundation sample read failed"
                                       : std::move(copied.error);
        }
        return false;
      }
      if (copied.status == AVFoundationSampleReadStatus::EndOfStream) {
        (video ? videoTerminal : audioTerminal) = true;
        if (admission) {
          assignError(error,
                      "selected AVFoundation output has no admission sample");
          return false;
        }
        return true;
      }
      auto head = makeHead(std::move(owned), *selected,
                           video ? MediaSampleKind::EncodedVideo
                                 : MediaSampleKind::EncodedAudio,
                           error);
      if (!head) {
        return false;
      }
      if (admission &&
          std::holds_alternative<media::MediaDiscontinuity>(head->value)) {
        ++skipped;
        if (skipped >= kMaximumAdmissionPrefixBuffers) {
          assignError(error,
                      "selected AVFoundation output exceeds the bounded "
                      "admission discontinuity prefix");
          return false;
        }
        if (isCancelled()) {
          publishCancellation(generation);
          assignError(error, "AVFoundation generation was cancelled");
          return false;
        }
        continue;
      }
      if (admission && video) {
        const auto* sample = std::get_if<MediaSample>(&head->value);
        // Nonnegativity is deliberately NOT required of this sample. On the
        // movie timeline the random-access point a head-trimmed edit list
        // makes the reader walk back to legitimately precedes the origin --
        // it is the sample that decodes the picture AT the origin, and it is
        // preroll, marked decodeOnly and retired against the presentation
        // floor rather than presented. This is the video reading of the same
        // fact MediaTime already states for the audio lane's priming access
        // unit: "negative values are valid (for example, edit-list and preroll
        // timestamps)". What this generation must still begin on is a real,
        // positive-duration SYNC picture, and that is what is checked.
        if (sample == nullptr || !sample->keyFrame ||
            !sample->presentationTime.valid() ||
            !sample->duration.valid() || sample->duration.value <= 0) {
          assignError(
              error,
              "first video sample is not a positive-duration sync access "
              "unit");
          return false;
        }
      }
      if (admission && video) {
        const auto* track = media::findMediaTrack(*descriptor, *selected);
        if (track && media::mediaCodecFacts(track->codec).requiresMjpegHeaderInspection) {
          CMBlockBufferRef data = CMSampleBufferGetDataBuffer(copied.sample);
          const std::size_t size = data ? CMBlockBufferGetDataLength(data) : 0;
          if (size == 0 || size > limits.maximumVideoSampleBytes) {
            assignError(error, "Motion JPEG admission sample exceeds native bounds");
            return false;
          }
          std::vector<std::byte> bytes(size);
          if (CMBlockBufferCopyDataBytes(data, 0, size, bytes.data()) != noErr) {
            assignError(error, "Motion JPEG admission sample could not be read");
            return false;
          }
          const auto verdict = media::inspectMjpegHeader(bytes);
          if (verdict != media::MjpegAdmission::Yuv420) {
            assignError(error, media::mjpegAdmissionReason(verdict));
            return false;
          }
        }
      }
      (video ? videoHead : audioHead) = std::move(head);
      publishHeadFacts();
      return true;
    }
  }

  // The staged audio head is the first compressed access unit this generation
  // will ever deliver, so it is this source's own proof of the window decode
  // start D. Accurate keeps the exact ceiling frame A at the requested target;
  // KeyFrame keeps the strict A = D = RAP rule against the video decode start.
  // A window that is not exactly representable on the declared frame grid is
  // left empty, which the dispatcher rejects before any consumer is exposed.
  [[nodiscard]] std::optional<media::MediaAudioGenerationWindow>
  audioGenerationWindow(MediaTime actualDecodeStart,
                        MediaTime declaredMediaStart,
                        MediaTime declaredPresentationEnd,
                        MediaTime declaredAudioEnd) const noexcept {
    if (descriptor == nullptr || !descriptor->selectedAudio || !audioHead) {
      return std::nullopt;
    }
    const MediaTrackDescriptor* track =
        media::findMediaTrack(*descriptor, *descriptor->selectedAudio);
    const auto* head = std::get_if<MediaSample>(&audioHead->value);
    if (track == nullptr || !track->audio || head == nullptr) {
      return std::nullopt;
    }
    const auto exactRate =
        media::exactAudioSampleRate(track->audio->sampleRate);
    if (!exactRate) {
      return std::nullopt;
    }
    const std::uint32_t sampleRate = *exactRate;
    const MediaTime decodeStart = head->presentationTime;
    const auto decodeFrame =
        media::exactAudioFrameIndex(decodeStart, sampleRate);
    // On the movie timeline the codec's own priming access unit legitimately
    // sits BEFORE media time zero -- an edit list that trims AAC-LC encoder
    // priming says exactly that. This is the case the neutral timeline already
    // models as audioCodecPrecedesStreamOrigin/trimBeforeFloor.
    if (!decodeFrame ||
        (*decodeFrame < 0 &&
         !media::audioCodecPrecedesStreamOrigin(track->codec))) {
      return std::nullopt;
    }
    // Container-declared silence, as exact movie times. mediaStart is where
    // the audio media begins (later than the origin exactly for a leading
    // empty edit); presentationEnd is where the presentation must end when the
    // selected video runs past the audio. Both are inert defaults for an
    // ordinary source.
    MediaTime mediaStart{0, 1};
    if (declaredMediaStart.valid() && declaredMediaStart.value > 0) {
      mediaStart = declaredMediaStart;
    }
    MediaTime presentationEnd{};
    MediaTime audioEnd{};
    if (declaredPresentationEnd.valid() && declaredAudioEnd.valid()) {
      // A declared end that is not exactly representable on this track's frame
      // grid cannot name a sample-exact boundary, so the generation ends at
      // its own audio end rather than guessing.
      if (media::exactAudioFrameIndex(declaredPresentationEnd, sampleRate) &&
          media::exactAudioFrameIndex(declaredAudioEnd, sampleRate)) {
        presentationEnd = declaredPresentationEnd;
        audioEnd = declaredAudioEnd;
      }
    }
    std::optional<MediaTime> presentationStart;
    switch (seekMode) {
    case media::MediaSeekMode::Accurate: {
      // Audio presentation begins at the requested target, or at the movie
      // time the audio media begins -- whichever is later. A target inside the
      // declared silence is not moved: the clock still starts there, and the
      // frames between it and this floor are rendered as silence.
      const MediaTime target = requestedTarget.value_or(MediaTime{0, 1});
      const auto mediaStartAgainstTarget =
          media::compareMediaTime(mediaStart, target);
      if (!mediaStartAgainstTarget) {
        return std::nullopt;
      }
      presentationStart = media::audioFrameAtOrAfter(
          *mediaStartAgainstTarget == media::MediaTimeOrder::Greater
              ? mediaStart
              : target,
          sampleRate);
      break;
    }
    case media::MediaSeekMode::KeyFrame:
      presentationStart = actualDecodeStart;
      break;
    default:
      return std::nullopt;
    }
    if (!presentationStart) {
      return std::nullopt;
    }
    const auto presentationFrame =
        media::exactAudioFrameIndex(*presentationStart, sampleRate);
    if (!presentationFrame || *presentationFrame < *decodeFrame ||
        (seekMode == media::MediaSeekMode::KeyFrame &&
         *presentationFrame != *decodeFrame)) {
      return std::nullopt;
    }
    // "Starts at the stream origin" means there is nothing earlier in the
    // AUDIO STREAM for the window to be -- which is decodeStart <= 0 for an
    // ordinary source, and decodeStart <= mediaStart when the container
    // declares silence before its audio: the stream genuinely begins at
    // mediaStart on the movie timeline, and the first access unit there is the
    // first access unit there is. Reading it as movie zero would demand a
    // decoder-refresh proof of a sample that needs none.
    const auto decodeAgainstMediaStart =
        media::compareMediaTime(decodeStart, mediaStart);
    if (!decodeAgainstMediaStart) {
      return std::nullopt;
    }
    return media::MediaAudioGenerationWindow{
        decodeStart, *presentationStart,
        *decodeAgainstMediaStart != media::MediaTimeOrder::Greater, mediaStart,
        presentationEnd, audioEnd};
  }

  [[nodiscard]] GenerationStart generationStart(
      AVFoundationGenerationStart&& started) const {
    GenerationStart out;
    out.status = openStatus(started.status);
    out.actualDecodeStart = started.actualDecodeStart;
    out.descriptor = std::move(started.descriptor);
    out.context = std::move(started.assetContext);
    out.audioWindow = started.audioWindow;
    out.error = std::move(started.error);
    return out;
  }

  [[nodiscard]] GenerationStart begin(
      const std::filesystem::path& requestedPath,
      const media::MediaSourceOpenOptions& requestedOptions,
      MediaGeneration requestedGeneration,
      const std::optional<MediaTime>& target, media::MediaSeekMode mode,
      const std::shared_ptr<const AVFoundationAssetContext>& requestedContext) {
    if (!resetForGeneration(requestedOptions, requestedGeneration, target,
                            mode)) {
      GenerationStart cancelled;
      cancelled.status = media::MediaSourceOpenStatus::Cancelled;
      return cancelled;
    }
    AVFoundationGenerationRequest request;
    request.path = requestedPath;
    request.options = requestedOptions;
    request.generation = requestedGeneration;
    request.target = target;
    request.seekMode = mode;
    request.assetContext = requestedContext;
    // Rejected audio tracks steer only the cold open's track selection.
    if (requestedContext == nullptr) {
      request.rejectedAudio = rejectedAudio;
    }
    ownerGeneration = backend->makeGeneration(std::move(request));
    if (ownerGeneration == nullptr ||
        ownerGeneration->generation() != generation) {
      AVFoundationGenerationStart invalid;
      invalid.error = "AVFoundation backend returned the wrong generation";
      withdrawFailedOperation();
      return generationStart(std::move(invalid));
    }
    std::atomic_store_explicit(&publishedGeneration, ownerGeneration,
                               std::memory_order_seq_cst);
    if (isCancelled()) {
      ownerGeneration->cancel();
    }
    AVFoundationGenerationStart started = ownerGeneration->start();
    if (isCancelled() ||
        started.status == AVFoundationGenerationStatus::Cancelled) {
      started.status = AVFoundationGenerationStatus::Cancelled;
      withdrawFailedOperation();
      return generationStart(std::move(started));
    }
    if (started.status != AVFoundationGenerationStatus::Ready ||
        started.descriptor == nullptr || !started.actualDecodeStart.valid()) {
      if (started.status == AVFoundationGenerationStatus::Ready) {
        started.status = AVFoundationGenerationStatus::Failed;
        started.error = "AVFoundation ready proof is incomplete";
      }
      withdrawFailedOperation();
      return generationStart(std::move(started));
    }
    if (!media::validateMediaSourceDescriptor(*started.descriptor, limits,
                                              &started.error)) {
      started.status = AVFoundationGenerationStatus::Unsupported;
      withdrawFailedOperation();
      return generationStart(std::move(started));
    }
    if (started.assetContext == nullptr ||
        started.descriptor.get() !=
            started.assetContext->descriptor().get() ||
        (requestedContext != nullptr &&
         started.assetContext.get() != requestedContext.get()) ||
        (requestedContext == nullptr &&
         !started.assetContext->matchesMainRequest(
             requestedPath, requestedOptions, started.descriptor))) {
      started.status = AVFoundationGenerationStatus::Unsupported;
      started.error =
          "AVFoundation generation changed its immutable asset identity";
      withdrawFailedOperation();
      return generationStart(std::move(started));
    }
    if (requestedTarget) {
      const auto targetAgainstDuration = media::compareMediaTime(
          *requestedTarget, started.descriptor->duration);
      const auto startAgainstTarget = media::compareMediaTime(
          started.actualDecodeStart, *requestedTarget);
      if (requestedTarget->value < 0 || !targetAgainstDuration ||
          *targetAgainstDuration == MediaTimeOrder::Greater ||
          !startAgainstTarget ||
          *startAgainstTarget == MediaTimeOrder::Greater) {
        started.status = AVFoundationGenerationStatus::Unsupported;
        started.error =
            "requested position is outside the exact source timeline";
        withdrawFailedOperation();
        return generationStart(std::move(started));
      }
    }
    if (!preservesLegacyNativeAdmission(*started.descriptor,
                                        &started.error)) {
      started.status = AVFoundationGenerationStatus::Unsupported;
      withdrawFailedOperation();
      return generationStart(std::move(started));
    }
    if ((options.selection.requireVideo &&
         !started.descriptor->selectedVideo) ||
        (options.selection.requireAudio &&
         !started.descriptor->selectedAudio)) {
      started.status = AVFoundationGenerationStatus::Unsupported;
      started.error = "AVFoundation did not select every required track";
      withdrawFailedOperation();
      return generationStart(std::move(started));
    }
    descriptor = started.descriptor;
    assetContext = started.assetContext;
    videoTerminal = !descriptor->selectedVideo;
    audioTerminal = !descriptor->selectedAudio;
    if ((!videoTerminal && !stage(true, true, &started.error)) ||
        (!audioTerminal && !stage(false, true, &started.error)) ||
        isCancelled()) {
      started.status = isCancelled()
                           ? AVFoundationGenerationStatus::Cancelled
                           : AVFoundationGenerationStatus::Unsupported;
      withdrawFailedOperation();
      return generationStart(std::move(started));
    }
    started.audioWindow =
        audioGenerationWindow(started.actualDecodeStart,
                              started.declaredAudioMediaStart,
                              started.declaredPresentationEnd,
                              started.declaredAudioEnd)
            .value_or(media::MediaAudioGenerationWindow{});
    open = true;
    openSnapshot.store(true, std::memory_order_release);
    return generationStart(std::move(started));
  }
};

AVFoundationMediaSource::AVFoundationMediaSource()
    : impl_(std::make_unique<Impl>(nullptr)) {}

AVFoundationMediaSource::AVFoundationMediaSource(
    std::shared_ptr<AVFoundationBackend> backend)
    : impl_(std::make_unique<Impl>(std::move(backend))) {}

AVFoundationMediaSource::~AVFoundationMediaSource() { close(); }

bool AVFoundationMediaSource::armOperation(
    MediaGeneration generation) noexcept {
  return impl_ != nullptr && impl_->arm(generation);
}

media::MediaSourceOpenOutcome AVFoundationMediaSource::openLocalFile(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options,
    MediaGeneration generation) {
  return impl_->openLocalFile(path, options, generation);
}

media::MediaSourceOpenOutcome AVFoundationMediaSource::retryAudioTrack(
    const std::filesystem::path& path, const media::MediaSourceOpenOptions& options,
    media::MediaGeneration generation, media::MediaTrackId rejected) {
  return impl_->retryAudioTrack(path, options, generation, rejected);
}

media::MediaSourceSeekOutcome AVFoundationMediaSource::seek(
    const media::MediaSourceSeekRequest& request) {
  return impl_->seek(request);
}

media::MediaSourceReadResult AVFoundationMediaSource::readNext(
    MediaGeneration expectedGeneration) {
  return impl_->readNext(expectedGeneration);
}

void AVFoundationMediaSource::requestCancel(MediaGeneration generation) noexcept {
  impl_->requestCancel(generation);
}

void AVFoundationMediaSource::close() noexcept {
  if (impl_ != nullptr) {
    impl_->close();
  }
}

media::MediaSourceStats AVFoundationMediaSource::stats() const noexcept {
  return impl_->stats();
}

std::shared_ptr<const AVFoundationAssetContext>
AVFoundationMediaSource::assetContext() const noexcept {
  return impl_ == nullptr ? nullptr : impl_->assetContext;
}

#if defined(WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING)
namespace avfoundation_media_source_testing {

std::int64_t audioUnitsWithinStagedDurationForTest(
    std::int64_t perUnitValue, std::int32_t perUnitTimescale) noexcept {
  return static_cast<std::int64_t>(audioUnitsWithinStagedDuration(
      CMTimeMake(perUnitValue, perUnitTimescale)));
}

std::optional<CMTime> audioFrameAlignedEditTimeForTesting(
    CMTime time, std::uint32_t sampleRate) noexcept {
  return audioFrameAlignedEditTime(time, sampleRate);
}

struct ConcurrentMetadataLoadCancellation::Impl {
  std::shared_ptr<AsyncLoadSignal> signal{
      std::make_shared<AsyncLoadSignal>()};
};

ConcurrentMetadataLoadCancellation::ConcurrentMetadataLoadCancellation()
    : impl_(std::make_shared<Impl>()) {}

ConcurrentMetadataLoadCancellation::~ConcurrentMetadataLoadCancellation() =
    default;

void ConcurrentMetadataLoadCancellation::cancel() noexcept {
  if (impl_ != nullptr && impl_->signal != nullptr) {
    impl_->signal->cancel();
  }
}

bool waitForConcurrentMetadataLoads(
    std::span<const ConcurrentMetadataLoadRequest> requests,
    ConcurrentMetadataLoadCancellation& cancellation,
    ConcurrentMetadataLoadObservation* observation, std::string* error) {
  if (cancellation.impl_ == nullptr ||
      cancellation.impl_->signal == nullptr) {
    assignError(error, "metadata test cancellation has no signal");
    return false;
  }
  ConcurrentLoadObservation internal;
  const bool loaded = waitForConcurrentLoadBatch(
      cancellation.impl_->signal, requests.size(),
      [&](std::size_t index, std::function<void()> completion) {
        requests[index].issue(std::move(completion));
      },
      [&](std::size_t index, std::string* validationError) {
        return requests[index].validate(validationError);
      },
      &internal, error);
  if (observation != nullptr) {
    observation->issued = internal.issued;
    observation->validated = internal.validated;
    switch (internal.wake) {
    case AsyncLoadWaitStatus::Complete:
      observation->wake = ConcurrentMetadataLoadWake::AllCompleted;
      break;
    case AsyncLoadWaitStatus::Cancelled:
      observation->wake = ConcurrentMetadataLoadWake::CancellationEdge;
      break;
    case AsyncLoadWaitStatus::Invalid:
      observation->wake = ConcurrentMetadataLoadWake::None;
      break;
    }
  }
  return loaded;
}

bool validAudioChannelLayoutForTesting(const AudioChannelLayout* layout,
                                       std::size_t layoutSize,
                                       std::uint32_t channels) noexcept {
  return validAudioChannelLayout(layout, layoutSize, channels);
}

void resetInspectedAudioChannelLayoutSizeForTesting() noexcept {
  g_inspectedAudioChannelLayoutSize.store(
      std::numeric_limits<std::size_t>::max(), std::memory_order_relaxed);
}

std::size_t inspectedAudioChannelLayoutSizeForTesting() noexcept {
  return g_inspectedAudioChannelLayoutSize.load(std::memory_order_relaxed);
}

media::MediaVideoSampleFormat parseHevcSampleFormatForTesting(
    std::span<const std::byte> configuration) noexcept {
  return parseHevcSampleFormat(configuration);
}

bool exactIdentityVideoTransformForTesting(
    CGAffineTransform transform) noexcept {
  return exactIdentityVideoTransform(transform);
}

bool selectedFormatsRebindBeforeReaderForTesting(
    CMVideoFormatDescriptionRef videoFormat, std::size_t videoFormatCount,
    CGAffineTransform videoTransform,
    CMAudioFormatDescriptionRef audioFormat, std::size_t audioFormatCount,
    const MediaSourceDescriptor& descriptor,
    const MediaSourceLimits& limits, std::size_t* readerCreationAttempts,
    std::string* error) noexcept {
  try {
    return selectedFormatsRebindBeforeReader(
        videoFormat, videoFormatCount, videoTransform, audioFormat,
        audioFormatCount, descriptor, limits,
        [&] {
          if (readerCreationAttempts != nullptr &&
              *readerCreationAttempts !=
                  std::numeric_limits<std::size_t>::max()) {
            ++*readerCreationAttempts;
          }
        },
        error);
  } catch (...) {
    assignError(error, "selected format rebind raised an exception");
    return false;
  }
}

bool sampleFormatMatchesTrackForTesting(
    CMSampleBufferRef sample,
    const MediaTrackDescriptor& track) noexcept {
  return sampleFormatMatchesTrack(sample, track, MediaSourceLimits{});
}

bool mediaFreeMarkerForTesting(CMSampleBufferRef sample) noexcept {
  return mediaFreeMarker(sample);
}

std::optional<CMTime> syncSearchTargetWithinLeadingEmptyEditForTesting(
    CMTime target, CMTime mediaStart) noexcept {
  return syncSearchTargetWithinLeadingEmptyEdit(target, mediaStart);
}

std::size_t projectCompressedAudioPacketTimingForTesting(
    CMSampleBufferRef sample, CMSampleTimingInfo* timing,
    std::size_t entries) noexcept {
  return projectCompressedAudioPacketTiming(sample, timing, entries);
}

std::size_t restateCompressedAudioPacketDurationsForTesting(
    CMSampleBufferRef sample, CMSampleTimingInfo* timing,
    std::size_t entries) noexcept {
  return restateCompressedAudioPacketDurations(sample, timing, entries);
}

std::optional<CMTime> restatedOnMovieTimelineForTesting(
    CMTime stamp, CMTime shift) noexcept {
  return restatedOnMovieTimeline(stamp, shift);
}

CMSampleBufferRef restatedVideoOnMovieTimelineForTesting(
    CMSampleBufferRef sample, CMTime shift) noexcept {
  return restatedVideoOnMovieTimeline(sample, shift);
}

std::optional<MediaTrackDescriptor> inspectVideoFormat(
    CMVideoFormatDescriptionRef format, MediaTrackId trackId,
    MediaTime duration, const MediaSourceLimits& limits, std::string* error) {
  return inspectVideoFormatImpl(format, trackId, duration, limits, error);
}

std::optional<MediaTrackDescriptor> inspectAudioFormat(
    CMAudioFormatDescriptionRef format, MediaTrackId trackId,
    MediaTime duration, const MediaSourceLimits& limits, std::string* error) {
  return inspectAudioFormatImpl(format, trackId, duration, limits, error);
}

bool preservesLegacyNativeAdmission(
    const MediaSourceDescriptor& descriptor, std::string* error) {
  return ::wam::macos::preservesLegacyNativeAdmission(descriptor, error);
}

bool preservesZeroBasedTrackTimeline(CMTimeRange trackRange,
                                     std::string* error) {
  return preservesZeroBasedTrackTimelineFacts(trackRange, error);
}

std::optional<CMTimeRange> exactReaderTimeRange(CMTime duration,
                                               CMTime decodeStart) {
  return exactReaderTimeRangeFacts(duration, decodeStart);
}

std::optional<bool> accurateVideoDecodeOnly(
    CMTime presentationTime, CMTime duration, media::MediaTime target,
    std::string* error) {
  const auto exactPresentationTime = exactMediaTime(presentationTime);
  const auto exactDuration = exactMediaTime(duration);
  if (!exactPresentationTime) {
    assignError(error,
                "accurate video sample has no exact presentation timestamp");
    return std::nullopt;
  }
  return wam::macos::accurateVideoDecodeOnly(
      *exactPresentationTime, exactDuration.value_or(media::MediaTime{}),
      target, error);
}

}  // namespace avfoundation_media_source_testing
#endif

}  // namespace wam::macos
