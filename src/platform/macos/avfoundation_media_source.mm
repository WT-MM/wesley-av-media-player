#include "avfoundation_media_source.hpp"
#include "native_layer_presentation_state.hpp"

#include "media/audio_codec_timing.hpp"
#include "media/matroska_ac3.hpp"
#include "media/matroska_mpeg_audio.hpp"
#include "media/video_codec_configuration.hpp"
#include "native_audio_channel_map.hpp"
#include "native_video_codec_capability.hpp"
#include "native_video_color.hpp"

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

constexpr std::size_t kMaximumSyncCursorSteps{100'000};
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

// Decoder preroll this backend guarantees ahead of the first audible frame of
// an accurate-seek generation, stated in whole compressed access units.
//
// AAC-LC carries no inter-frame dependency beyond the MDCT overlap-add window:
// each 1024-frame access unit is reconstructed from its own spectral data plus
// the second half of the previous unit's window, so one decoded predecessor
// already makes a unit exact. Two units is the conventional decoder preroll
// and the value used here, which also covers the same overlap structure at the
// 2048-frame HE-AAC grid and the block-switch history of MP3.
constexpr std::int64_t kAudioPrimingAccessUnits{2};
// Additional units by which the reader time range is placed early. Given a
// range start, AVFoundation may begin an audio track output at the access unit
// boundary at or after it rather than at the unit containing it (observed up
// to one unit late on edited MP4 assets). The slack keeps the guarantee above
// intact; it is never assumed - the staged unit is always measured against the
// exact priming ceiling before any proof is stated.
constexpr std::int64_t kAudioReaderStartSlackAccessUnits{2};
// Guards the priming arithmetic below against a pathological packet grid.
constexpr std::int64_t kMaximumAudioFramesPerPacket{65'536};

// Exact audio boundaries an accurate-seek generation needs before it reads.
// searchFloor is the latest media time the reader may start at; proofCeiling
// is the latest first-access-unit timestamp that still leaves the full
// kAudioPrimingAccessUnits of decoded-and-discarded audio ahead of the
// generation's first audible frame A = ceil(T*R)/R.
struct AudioPrimingPlan {
  MediaTime searchFloor{};
  MediaTime proofCeiling{};
};

[[nodiscard]] std::optional<AudioPrimingPlan> audioPrimingPlanFacts(
    const MediaTrackDescriptor& audio, MediaTime target) noexcept {
  if (!audio.audio || !std::isfinite(audio.audio->sampleRate) ||
      audio.audio->sampleRate <= 0.0 ||
      audio.audio->sampleRate >
          static_cast<double>(std::numeric_limits<std::uint32_t>::max())) {
    return std::nullopt;
  }
  const auto sampleRate = static_cast<std::uint32_t>(audio.audio->sampleRate);
  // A codec whose packets carry no fixed frame count declares zero here and
  // states the count per packet instead. Bound it rather than refusing the
  // generation; see kMaximumVariableAccessUnitFrames.
  const auto framesPerPacket =
      audio.audio->framesPerPacket == 0
          ? kMaximumVariableAccessUnitFrames
          : static_cast<std::int64_t>(audio.audio->framesPerPacket);
  if (static_cast<double>(sampleRate) != audio.audio->sampleRate ||
      sampleRate == 0 || framesPerPacket <= 0 ||
      framesPerPacket > kMaximumAudioFramesPerPacket) {
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
  const std::int64_t priming = kAudioPrimingAccessUnits * framesPerPacket;
  const std::int64_t searchBackoff =
      priming + kAudioReaderStartSlackAccessUnits * framesPerPacket;
  const auto floorFrame = static_cast<std::int64_t>(
      std::max<std::int64_t>(*presentationFrame - searchBackoff, 0));
  const auto ceilingFrame = static_cast<std::int64_t>(
      std::max<std::int64_t>(*presentationFrame - priming, 0));
  const auto scale = static_cast<std::int32_t>(sampleRate);
  return AudioPrimingPlan{MediaTime{floorFrame, scale},
                          MediaTime{ceilingFrame, scale}};
}

// The converter admits the first compressed access unit of a generation that
// does not begin at the stream origin only when that unit is an
// ImmediatePlayoutFrame, proved by a per-sample
// kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount of exactly
// zero. AVFoundation never states that attachment for AAC-LC - it leaves the
// per-sample attachment array absent - so this backend states it itself, and
// only once it has MADE it true: the generation's reader range was placed at
// least kAudioPrimingAccessUnits whole access units before the first audible
// frame A, and the converter discards every decoded PCM frame in [D, A)
// without relabeling. With that much decoded-and-discarded audio ahead of it,
// the frame at A is fully primed, which is exactly the property the proof
// asserts. Callers verify the unit against the priming ceiling first; an
// unproved unit is left untouched so the converter fails the generation
// closed rather than publishing un-primed PCM.
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
  CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type,
                                     &refreshCount);
  if (value == nullptr) {
    return false;
  }
  CFDictionarySetValue(
      static_cast<CFMutableDictionaryRef>(const_cast<void*>(entry)),
      kCMSampleAttachmentKey_AudioIndependentSampleDecoderRefreshCount, value);
  CFRelease(value);
  return true;
}

[[nodiscard]] bool trueAttachment(CMSampleBufferRef sample,
                                  CFStringRef key) noexcept {
  CFTypeRef raw = CMGetAttachment(sample, key, nullptr);
  return raw != nullptr && CFGetTypeID(raw) == CFBooleanGetTypeID() &&
         CFBooleanGetValue(static_cast<CFBooleanRef>(raw));
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
  if (asbd == nullptr || !(asbd->mSampleRate > 0.0) ||
      asbd->mSampleRate >
          static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
    return kCMTimeInvalid;
  }
  const auto timescale = static_cast<std::int32_t>(asbd->mSampleRate);
  if (static_cast<double>(timescale) != asbd->mSampleRate) {
    return kCMTimeInvalid;
  }
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

// The most media time one staged audio sample may carry.
//
// Chosen against the PCM ring, which is what has to absorb the event:
// NativePcmRing is kSlabCount(16) * kFramesPerSlab(4096) == 65,536 frames,
// ~1.365 s at 48 kHz. A staged event must fit that with room to spare, and it
// must be short enough that the merged read gate reopens well within the video
// lane's own read-ahead (kLaneReadAheadEvents == 24 events, ~0.8 s at 30 fps),
// so the video decoder is never starved between two audio events. 256 ms is
// about a fifth of the ring and about a third of the video read-ahead, and it
// is ~12 AAC access units -- the same order as the 1-2 units a normally
// interleaved container already vends, so the healthy path is unchanged.
constexpr double kMaximumStagedAudioSeconds = 0.256;

// How many access units of the given per-unit duration fit inside
// kMaximumStagedAudioSeconds. Returns 0 when the duration is not usable, and
// the caller then applies no time bound at all, so behaviour is exactly what it
// was before the bound existed.
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
// so the reader's batch is re-cut to fit before anything else touches it. That
// bound is what refused .wav and .aiff at admission with "compressed sample
// exceeds native memory bounds"; nothing about LPCM was ever the problem.
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
// than twice the ring's guaranteed capacity. Measured on such a file, video went
// dark for ~1.5 s out of every 2.9867 s and 58% of frames were retired late
// while the audio clock ran perfectly. Bounding the staged duration is what
// makes the capacity-one rule's own precondition true.
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
  // MULTICHANNEL (2026-08-27). Wider layouts are admitted exactly when the
  // shared downmix stage can state the fold for them. This is the same
  // predicate the converter already applies (native_audio_converter.mm
  // supportedChannelLayout) and the same one the Matroska route has used since
  // v0.4.4, so both container routes now agree by construction instead of by
  // coincidence. The decision is made on the TAG'S EXPANSION -- label by
  // label, never by channel index -- because AudioToolbox emits a different
  // channel ORDER per codec family for the identical 5.1 content (see the
  // table in native_audio_channel_map.hpp). Nothing here folds anything: the
  // backend still decodes the FULL native width and the converter applies
  // media::applyStereoDownmix using the decoder's OWN reported output layout,
  // which is the only description of the bytes it actually writes. A tag whose
  // expansion contains any unmapped label is refused whole, which is a clean
  // mpv fallback rather than a silently dropped channel.
  const bool accepted =
      channels == 1   ? tag == kAudioChannelLayoutTag_Mono
      : channels == 2 ? tag == kAudioChannelLayoutTag_Stereo
                      : multichannelLayoutTagAdmitted(tag, channels);
  if (accepted && acceptedTag != nullptr) {
    *acceptedTag = tag;
  }
  return accepted;
}

class ScopedSampleBuffer final {
 public:
  explicit ScopedSampleBuffer(CMSampleBufferRef sample = nullptr) noexcept
      : sample_(sample) {}
  ScopedSampleBuffer(const ScopedSampleBuffer&) = delete;
  ScopedSampleBuffer& operator=(const ScopedSampleBuffer&) = delete;
  ScopedSampleBuffer(ScopedSampleBuffer&& other) noexcept
      : sample_(std::exchange(other.sample_, nullptr)) {}
  ~ScopedSampleBuffer() {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

  [[nodiscard]] CMSampleBufferRef get() const noexcept { return sample_; }
  [[nodiscard]] CMSampleBufferRef release() noexcept {
    return std::exchange(sample_, nullptr);
  }
  // Adopts a +1 reference, releasing whatever was held. Assignment stays
  // deleted: a retained batch is only ever replaced deliberately.
  void reset(CMSampleBufferRef sample = nullptr) noexcept {
    CMSampleBufferRef prior = std::exchange(sample_, sample);
    if (prior != nullptr && prior != sample) {
      CFRelease(prior);
    }
  }

 private:
  CMSampleBufferRef sample_{nullptr};
};

std::string describeNSError(NSError* error, const char* fallback) {
  if (error == nil || error.localizedDescription == nil) {
    return fallback;
  }
  const char* text = error.localizedDescription.UTF8String;
  return text == nullptr ? fallback : std::string(text);
}

void assignError(std::string* error, const char* message) {
  if (error != nullptr) {
    *error = message;
  }
}

[[nodiscard]] std::optional<MediaTime> exactMediaTime(CMTime time) noexcept {
  if (!CMTIME_IS_NUMERIC(time) ||
      (time.flags & kCMTimeFlags_HasBeenRounded) != 0 || time.epoch != 0 ||
      time.timescale <= 0) {
    return std::nullopt;
  }
  return MediaTime{time.value, time.timescale};
}

[[nodiscard]] MediaTime optionalMediaTime(CMTime time) noexcept {
  const auto converted = exactMediaTime(time);
  return converted.value_or(MediaTime{});
}

[[nodiscard]] std::optional<CMTime> exactCMTime(MediaTime time) noexcept {
  if (!time.valid()) {
    return std::nullopt;
  }
  return CMTimeMake(time.value, time.timescale);
}

[[nodiscard]] std::optional<MediaTime> canonicalDuration(CMTime time) noexcept {
  const auto converted = exactMediaTime(time);
  if (!converted || converted->value < 0) {
    return std::nullopt;
  }
  return converted;
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
      numerator < 0
          ? static_cast<WideUnsigned>(-(numerator + 1)) + 1
          : static_cast<WideUnsigned>(numerator);
  const std::uint64_t common =
      std::gcd(denominator,
               static_cast<std::uint64_t>(magnitude % denominator));
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
  return MediaTime{static_cast<std::int64_t>(reducedNumerator),
                   static_cast<std::int32_t>(reducedDenominator)};
}

[[nodiscard]] std::optional<bool> accurateVideoDecodeOnlyFacts(
    MediaTime presentationTime, MediaTime duration, MediaTime target,
    std::string* error) noexcept {
  if (!presentationTime.valid() || !duration.valid() || duration.value <= 0) {
    assignError(error,
                "accurate video sample has no exact positive interval");
    return std::nullopt;
  }
  const auto intervalEnd = checkedExactTimeSum(presentationTime, duration);
  if (!intervalEnd) {
    assignError(error,
                "accurate video sample interval is not exactly representable");
    return std::nullopt;
  }
  const auto endAgainstTarget =
      media::compareMediaTime(*intervalEnd, target);
  if (!endAgainstTarget) {
    assignError(error,
                "video sample interval and seek target have incomparable time");
    return std::nullopt;
  }
  return *endAgainstTarget != MediaTimeOrder::Greater;
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

// The exact movie-timeline restatement facts of a selected audio track.
//
// AVFoundation states every audio access unit on the track's own MEDIA
// timeline, while the container's edit list says where that media belongs on
// the MOVIE timeline -- which is the timeline the video lane already presents
// on (VideoToolbox propagates each sample's OutputPresentationTimeStamp to the
// decoded frame), and the one the seek targets, the reader time range and the
// descriptor duration are all stated in. The difference is a constant per
// track: `shift = target.start - source.start` of the single media edit.
//
// `mediaStart` is the movie time at which audio media begins. It is nonzero
// exactly when the track carries a leading EMPTY EDIT (elst media_time == -1),
// i.e. a span of container-declared silence before any audio media exists.
//
// Admissible shape for native v1: at most one empty edit, at the head,
// followed by exactly one media edit at rate 1.0. Anything else fails closed.
struct AudioMovieTimelineFacts {
  CMTime shift{kCMTimeZero};
  CMTime mediaStart{kCMTimeZero};
};

[[nodiscard]] bool exactEditTime(CMTime time) noexcept {
  return CMTIME_IS_NUMERIC(time) &&
         (time.flags & kCMTimeFlags_HasBeenRounded) == 0 && time.epoch == 0 &&
         time.timescale > 0;
}

[[nodiscard]] std::optional<AudioMovieTimelineFacts>
audioMovieTimelineFactsFor(NSArray* segments) noexcept {
  AudioMovieTimelineFacts facts;
  AVAssetTrackSegment* media = nil;
  NSUInteger index = 0;
  for (AVAssetTrackSegment* segment in segments) {
    if (segment.empty) {
      // At most one empty edit, and only at the head. An empty edit anywhere
      // else is a mid-stream silence hole, which is not a constant shift.
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
  if (media == nil) {
    // A track with no media edit at all cannot be restated; a track with no
    // edit list reports one identity segment and is handled above.
    return std::nullopt;
  }
  const CMTimeMapping mapping = media.timeMapping;
  if (!exactEditTime(mapping.target.start) ||
      !exactEditTime(mapping.source.start) ||
      !exactEditTime(mapping.target.duration) ||
      !exactEditTime(mapping.source.duration) ||
      CMTimeCompare(mapping.target.start, kCMTimeZero) < 0 ||
      CMTimeCompare(mapping.source.start, kCMTimeZero) < 0) {
    return std::nullopt;
  }
  // Rate 1.0 only. A stretched edit would make the shift a function of time.
  if (CMTimeCompare(mapping.target.duration, mapping.source.duration) != 0) {
    return std::nullopt;
  }
  const CMTime shift =
      CMTimeSubtract(mapping.target.start, mapping.source.start);
  if (!CMTIME_IS_NUMERIC(shift) ||
      (shift.flags & kCMTimeFlags_HasBeenRounded) != 0 || shift.epoch != 0 ||
      shift.timescale <= 0) {
    return std::nullopt;
  }
  facts.shift = shift;
  facts.mediaStart = mapping.target.start;
  return facts;
}

// The movie time at which a track's MEDIA begins, or the origin when it begins
// there. Nonzero exactly when the track carries a leading EMPTY EDIT.
//
// audioMovieTimelineFactsFor above analyses the SHAPE of a segment list and
// nothing audio-specific, so it answers this for a video track too. It is
// spelled out separately because the video lane wants only this one fact: the
// first movie time at which a picture exists. Fails safe to the origin, which
// makes every caller behave exactly as it did before this existed.
[[nodiscard]] CMTime trackMediaStartOnMovieTimeline(NSArray* segments) noexcept {
  const auto facts = audioMovieTimelineFactsFor(segments);
  if (!facts || !exactEditTime(facts->mediaStart) ||
      CMTimeCompare(facts->mediaStart, kCMTimeZero) <= 0) {
    return kCMTimeZero;
  }
  return facts->mediaStart;
}

// The exact constant that carries a track's MEDIA-timeline stamps onto the
// MOVIE timeline: the `target.start - source.start` of its one media edit.
//
// Same shape analysis and the same reason as trackMediaStartOnMovieTimeline
// above. Fails SAFE to the zero shift: a multi-segment or rate-stretched edit
// list is not a constant displacement, and for those shapes this backend keeps
// stating exactly what it stated before this existed rather than refusing a
// file that plays today. Zero is also the honest answer for a container with
// no edit list at all, where the two timelines are the same timeline.
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
// and the shift is zero only when the container carries no edit list -- which
// is why an ordinary no-edit file never showed the defect, and why a
// head-trimmed edit list (measured: -0.801917 s on a 24000-timescale file)
// lands decoded frames at negative movie times the consumer then refuses.
//
// Every other quantity a compressed sample is measured against is already the
// MOVIE timeline -- the seek target, the presentation floor, the reader's time
// range, the descriptor duration -- so the input stamp was the one statement in
// this route on the wrong clock.
//
// The shift is the container's own exact rational, so a stamp that cannot carry
// it exactly is refused rather than rounded: that is what keeps the frame grid
// exact. A non-numeric stamp (a compressed access unit legitimately carries no
// decode stamp) and a stamp in a later epoch are both returned unchanged, so
// the exactness gates downstream still see precisely what they saw before.
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
// still the container's own. Measured across 59 access units of four files
// (two head-trimmed specimens and two ordinary ffmpeg controls): attachment
// presence, sync flag, payload length, format identity, duration and sample
// count all identical to the source buffer, with PTS == OutputPTS on every
// restated buffer.
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
  // array, so it is passed through as it always was rather than manufactured.
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
  const auto presentation =
      restatedOnMovieTimeline(timing.presentationTimeStamp, shift);
  // The decode stamp moves with the presentation stamp or not at all: their
  // displacement is the codec's reorder distance, which the edit list does not
  // touch and which VideoToolbox reads to order its output.
  const auto decode = restatedOnMovieTimeline(timing.decodeTimeStamp, shift);
  if (!presentation || !decode) {
    return nullptr;
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

// Clamps a located sync start into the neutral timeline contract's window.
//
// That contract is `0 <= actualDecodeStart <= requestedTarget` -- stated by
// native_media_dispatcher.cpp deriveTimeline and re-proved independently by
// native_video_consumer.mm validTimeline and native_audio_session.mm. A
// container edit list can legitimately put the located random-access point
// outside the window at EITHER end, and neither shape is a malformation:
//
//   * a head-TRIMMED edit (elst media_time > 0) hides media before the movie
//     origin, so the RAP that decodes the picture at movie time 0 restates to
//     a NEGATIVE movie time (measured: -0.801917 s on a 24000-timescale file
//     whose video edit starts at media 19246);
//   * a leading EMPTY EDIT (elst media_time == -1) declares blank movie time
//     before any picture exists, so the first RAP presents AFTER the target
//     (measured: +0.023 s on an ffmpeg-muxed file whose video edit is
//     [(23, -1), (N, 1024)]).
//
// Nothing is lost by clamping. AVAssetReader walks back to the random-access
// point at or before its own range start by itself -- measured: given range
// start 0 on the head-trimmed file it still delivers the RAP at media 0, with
// outputPresentationTimeStamp -0.801917 -- and pictures presenting before the
// generation start are already retired as compressed preroll by the consumer.
//
// This is the same floor matroska_demuxer.cpp applies to the Opus pre-skip
// ("the downstream timeline contract requires 0 <= actualDecodeStart <=
// target"), and the origin floor matroska_media_source, mpegts_media_source
// and both preview sources already carry. This route was the only one of the
// four without it.
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

[[nodiscard]] CMTime clampedSyncStartWithinTimelineContract(
    CMTime decodeStart, CMTime target) noexcept {
  if (!CMTIME_IS_NUMERIC(decodeStart) || !CMTIME_IS_NUMERIC(target)) {
    return decodeStart;
  }
  if (CMTimeCompare(decodeStart, kCMTimeZero) < 0) {
    return kCMTimeZero;
  }
  if (CMTimeCompare(decodeStart, target) > 0) {
    return target;
  }
  return decodeStart;
}

// Frames Apple's decoder swallows at the head of a track before it emits its
// first PCM frame. This MUST stay identical to native_audio_converter.mm's
// decoderLeadInFrames() and to mpegts_media_source.mm's own copy of this
// function, because the session proves a generation by checking that the
// converter's first published frame lands exactly on the presentation floor:
// the source states the decode start, the converter adds its lead-in, and the
// two have to meet. The shared constants are named rather than copied so a
// future measurement moves every side of the proof together.
[[nodiscard]] std::int64_t audioDecoderLeadInFrames(MediaCodec codec) noexcept {
  switch (codec) {
    case MediaCodec::Ac3:
    case MediaCodec::Eac3:
      return media::matroska::kAc3DecoderDelayFrames;
    case MediaCodec::Mp3:
      return media::matroska::kMpegLayer3DecoderDelayFrames;
    // AAC, FLAC, ALAC and LPCM swallow nothing; Opus and Vorbis do, but neither
    // is admitted on this route (see preservesLegacyNativeAdmission).
    default:
      return 0;
  }
}

// True for a path that is the codec's OWN bare elementary stream rather than a
// container. See audioDecoderLeadInShift for what turns on it. Kept to the
// three codecs that state a nonzero decoder lead-in, because it is only their
// arithmetic this decides; every other extension is a container and answers
// false. This is the same extension-only discrimination the route selection in
// native_media_session.mm already makes.
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
// MEASURED, by reading the media edit AVFoundation reports for the same 20 s
// content in four carriers (scratchpad/aprobe.mm):
//
//   beep.mp3      raw MPEG stream   src.start =  576  -- LAME encoder delay
//   mp3in.mov     QuickTime movie   src.start = 1105  -- 576 encoder + 529
//                                                        DECODER, i.e. exactly
//                                                        the CodecDelay ffmpeg
//                                                        writes to Matroska
//   beep.ac3      raw AC-3 stream   src.start =    0  -- nothing stated
//   av_ac3.mov    QuickTime movie   src.start =  256  -- the AC-3 decoder delay
//
// So a REAL container edit already expresses the whole offset from the packet
// grid to the presentation timeline, decoder delay included, and must be left
// exactly alone. A bare elementary stream has no edit list at all: what
// AVFoundation reports for one is either nothing, or -- for MP3 -- a segment it
// synthesises from the file's own Xing/LAME tag, which describes the ENCODER
// and nothing else. That is the case, and the only case, where the decoder
// lead-in still has to be subtracted here.
//
// Proved with scratchpad/syncproof.mm against a fixture whose first 1 kHz beep
// starts at exactly frame 48000. Before: the beep published at 48529 on a raw
// stereo MP3 (529 late) and a raw AC-3 was refused outright as "audio session:
// Converter" because its first published frame landed 256 frames past the
// floor. After: 48000 on both, and both .mov carriers unchanged at 48000.
// FLAC, LPCM and AAC state a zero lead-in and are untouched by construction.
//
// Empty means the arithmetic is not exactly representable, which fails closed.
[[nodiscard]] std::optional<CMTime> audioDecoderLeadInShift(
    const MediaTrackDescriptor& audio,
    const std::filesystem::path& path) noexcept {
  const std::int64_t leadIn = audioDecoderLeadInFrames(audio.codec);
  if (leadIn == 0 || !bareAudioElementaryStream(path)) {
    return kCMTimeZero;
  }
  if (!audio.audio) {
    return std::nullopt;
  }
  const double rate = audio.audio->sampleRate;
  if (!std::isfinite(rate) || rate <= 0.0 ||
      rate > static_cast<double>(std::numeric_limits<std::int32_t>::max())) {
    return std::nullopt;
  }
  const auto scale = static_cast<std::int32_t>(rate);
  if (static_cast<double>(scale) != rate) {
    return std::nullopt;
  }
  return CMTimeMake(leadIn, scale);
}

[[nodiscard]] bool preservesZeroBasedTrackTimeline(
    AVAssetTrack* track, std::string* error) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  const CMTimeRange trackRange = track.timeRange;
#pragma clang diagnostic pop
  return preservesZeroBasedTrackTimelineFacts(trackRange, error);
}

[[nodiscard]] bool numberToUInt32(CFTypeRef value,
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

[[nodiscard]] bool numberToInt64Exact(CFTypeRef value,
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

[[nodiscard]] std::uint64_t unsignedMagnitude(std::int64_t value) noexcept {
  if (value >= 0) {
    return static_cast<std::uint64_t>(value);
  }
  return static_cast<std::uint64_t>(-(value + 1)) + 1;
}

[[nodiscard]] std::optional<media::MediaRational> normalizedRational(
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

[[nodiscard]] std::optional<media::MediaRational> copyExactRational(
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

[[nodiscard]] std::optional<media::MediaCleanAperture> copyCleanAperture(
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

[[nodiscard]] bool extensionPresent(CMFormatDescriptionRef format,
                                    CFStringRef key) noexcept {
  return CMFormatDescriptionGetExtension(format, key) != nullptr;
}

[[nodiscard]] bool stringEquals(CFTypeRef value,
                                CFStringRef expected) noexcept {
  return value != nullptr && expected != nullptr &&
         CFGetTypeID(value) == CFStringGetTypeID() &&
         CFEqual(value, expected);
}

[[nodiscard]] media::MediaColorPrimaries copyColorPrimaries(
    CMVideoFormatDescriptionRef format, bool* unsupported) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_ColorPrimaries);
  if (value == nullptr) {
    return media::MediaColorPrimaries::Unknown;
  }
  if (stringEquals(value, kCMFormatDescriptionColorPrimaries_ITU_R_709_2)) {
    return media::MediaColorPrimaries::Bt709;
  }
  // Amendment 6: BT.2020 primaries are a MODELLED fact now, not an opaque
  // "unsupported metadata" bit. mediaVideoColorAdmitted() owns the decision.
  if (stringEquals(value, kCMFormatDescriptionColorPrimaries_ITU_R_2020)) {
    return media::MediaColorPrimaries::Bt2020;
  }
  // SD-era primaries are a modelled fact on THIS route, not an opaque bit.
  // VideoToolbox attaches SMPTE_C / EBU_3213 verbatim to the decoded surface
  // (measured on the user's corpus), the decoded-surface validator already
  // admits both, and the display layer converts from the surface's own tag --
  // so the primaries the container declares are the primaries WindowServer
  // presents. Setting the fail-closed bit here was the whole reason legacy
  // 4:2:0 SD content fell back to mpv.
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
  // is the wrong-colour failure this widening exists to avoid. Distinguishing
  // them needs an appended enumerator -- see scratchpad/sd_color_report.md.
  if (stringEquals(value, kCMFormatDescriptionColorPrimaries_SMPTE_C)) {
    return media::MediaColorPrimaries::Bt601;
  }
  *unsupported = true;
  if (stringEquals(value, kCMFormatDescriptionColorPrimaries_EBU_3213)) {
    return media::MediaColorPrimaries::Bt601;
  }
  return media::MediaColorPrimaries::OtherExplicit;
}

[[nodiscard]] media::MediaTransferFunction copyTransferFunction(
    CMVideoFormatDescriptionRef format, bool* unsupported) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_TransferFunction);
  if (value == nullptr) {
    return media::MediaTransferFunction::Unknown;
  }
  if (stringEquals(value, kCMFormatDescriptionTransferFunction_ITU_R_709_2)) {
    return media::MediaTransferFunction::Bt709;
  }
  // Amendment 6: PQ and HLG are modelled facts. VideoToolbox resolves each to
  // a real CGColorSpace on the decoded surface ("Rec. ITU-R BT.2100 PQ" /
  // "... HLG", measured), which is what the display layer presents from.
  if (stringEquals(value,
                   kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)) {
    return media::MediaTransferFunction::Pq;
  }
  if (stringEquals(value,
                   kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG)) {
    return media::MediaTransferFunction::Hlg;
  }
  *unsupported = true;
  if (stringEquals(value, kCMFormatDescriptionTransferFunction_sRGB)) {
    return media::MediaTransferFunction::Srgb;
  }
  return media::MediaTransferFunction::OtherExplicit;
}

[[nodiscard]] media::MediaMatrixCoefficients copyMatrixCoefficients(
    CMVideoFormatDescriptionRef format, bool* unsupported) noexcept {
  CFTypeRef value = CMFormatDescriptionGetExtension(
      format, kCMFormatDescriptionExtension_YCbCrMatrix);
  if (value == nullptr) {
    return media::MediaMatrixCoefficients::Unknown;
  }
  if (stringEquals(value, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)) {
    return media::MediaMatrixCoefficients::Bt709;
  }
  if (stringEquals(value, kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4)) {
    return media::MediaMatrixCoefficients::Bt601;
  }
  // Amendment 6: the BT.2020 non-constant-luminance matrix is a modelled fact.
  if (stringEquals(value, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)) {
    return media::MediaMatrixCoefficients::Bt2020Ncl;
  }
  // matrix_coefficients 5 is the same matrix as 6, spelled the way CoreMedia
  // spells a value it has no constant for. See bt470bgYCbCrMatrixSpelling().
  if (stringEquals(value, wam::macos::bt470bgYCbCrMatrixSpelling())) {
    return media::MediaMatrixCoefficients::Bt601;
  }
  *unsupported = true;
  return media::MediaMatrixCoefficients::OtherExplicit;
}

[[nodiscard]] media::MediaChromaLocation copyChromaLocation(
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

[[nodiscard]] bool hasDolbyVisionConfiguration(
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

class CodecRbspBitReader final {
 public:
  explicit CodecRbspBitReader(
      std::span<const std::uint8_t> escapedBytes) noexcept
      : bytes_(escapedBytes) {}

  [[nodiscard]] bool readBits(std::size_t count,
                              std::uint32_t* value) noexcept {
    if (value == nullptr || count > 32) {
      return false;
    }
    *value = 0;
    for (std::size_t index = 0; index < count; ++index) {
      if (bits_remaining_ == 0 && !loadByte()) {
        return false;
      }
      *value = (*value << 1U) |
               ((current_byte_ >> (bits_remaining_ - 1U)) & 1U);
      --bits_remaining_;
    }
    return true;
  }

  [[nodiscard]] bool readUnsignedExpGolomb(
      std::uint32_t* value) noexcept {
    std::size_t leadingZeroBits = 0;
    std::uint32_t bit = 0;
    while (true) {
      if (!readBits(1, &bit)) {
        return false;
      }
      if (bit != 0) {
        break;
      }
      if (++leadingZeroBits > 31) {
        return false;
      }
    }
    std::uint32_t suffix = 0;
    if (!readBits(leadingZeroBits, &suffix)) {
      return false;
    }
    const std::uint64_t decoded =
        ((std::uint64_t{1} << leadingZeroBits) - 1U) + suffix;
    if (decoded > std::numeric_limits<std::uint32_t>::max()) {
      return false;
    }
    *value = static_cast<std::uint32_t>(decoded);
    return true;
  }

 private:
  [[nodiscard]] bool loadByte() noexcept {
    while (offset_ < bytes_.size()) {
      const std::uint8_t value = bytes_[offset_++];
      if (zero_count_ >= 2 && value == 0x03U) {
        if (offset_ >= bytes_.size() || bytes_[offset_] > 0x03U) {
          return false;
        }
        zero_count_ = 0;
        continue;
      }
      zero_count_ = value == 0 ? zero_count_ + 1 : 0;
      current_byte_ = value;
      bits_remaining_ = 8;
      return true;
    }
    return false;
  }

  std::span<const std::uint8_t> bytes_;
  std::size_t offset_{0};
  std::size_t zero_count_{0};
  std::uint8_t current_byte_{0};
  std::size_t bits_remaining_{0};
};

[[nodiscard]] media::MediaVideoSampleFormat parseH264SampleFormat(
    std::span<const std::byte> configuration) noexcept {
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
    CodecRbspBitReader bits(bytes.subspan(offset + 1, length - 1));
    std::uint32_t profile = 0;
    std::uint32_t ignored = 0;
    if (!bits.readBits(8, &profile) || !bits.readBits(8, &ignored) ||
        !bits.readBits(8, &ignored) ||
        !bits.readUnsignedExpGolomb(&ignored) || profile != bytes[1] ||
        (profile != 66 && profile != 77 && profile != 88 && profile != 100)) {
      return media::MediaVideoSampleFormat::Unsupported;
    }
    if (profile == 100) {
      std::uint32_t chromaFormat = 0;
      std::uint32_t lumaDepthMinusEight = 0;
      std::uint32_t chromaDepthMinusEight = 0;
      if (!bits.readUnsignedExpGolomb(&chromaFormat) || chromaFormat != 1 ||
          !bits.readUnsignedExpGolomb(&lumaDepthMinusEight) ||
          !bits.readUnsignedExpGolomb(&chromaDepthMinusEight) ||
          lumaDepthMinusEight != 0 || chromaDepthMinusEight != 0) {
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
[[nodiscard]] media::MediaVideoSampleFormat parseVp9SampleFormat(
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
[[nodiscard]] media::MediaVideoSampleFormat parseAv1SampleFormat(
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
  const auto bytes = std::span<const std::uint8_t>(
      reinterpret_cast<const std::uint8_t*>(configuration.data()),
      configuration.size());
  if (bytes.size() < 23 || bytes[0] != 1 ||
      (bytes[13] & 0xf0U) != 0xf0U ||
      (bytes[15] & 0xfcU) != 0xfcU ||
      (bytes[16] & 0xfcU) != 0xfcU ||
      (bytes[17] & 0xf8U) != 0xf8U ||
      (bytes[18] & 0xf8U) != 0xf8U ||
      (bytes[16] & 0x03U) != 1U) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  const std::uint8_t lumaDepthMinusEight = bytes[17] & 0x07U;
  const std::uint8_t chromaDepthMinusEight = bytes[18] & 0x07U;
  if (lumaDepthMinusEight != chromaDepthMinusEight ||
      (lumaDepthMinusEight != 0 && lumaDepthMinusEight != 2)) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  const std::uint8_t expectedProfileIdc =
      lumaDepthMinusEight == 2 ? 2U : 1U;
  const std::uint8_t configurationProfile = bytes[1];
  if ((configurationProfile & 0xc0U) != 0 ||
      (configurationProfile & 0x1fU) != expectedProfileIdc) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  const std::uint32_t configurationCompatibility =
      (static_cast<std::uint32_t>(bytes[2]) << 24U) |
      (static_cast<std::uint32_t>(bytes[3]) << 16U) |
      (static_cast<std::uint32_t>(bytes[4]) << 8U) | bytes[5];
  const std::uint32_t configurationConstraintHigh =
      (static_cast<std::uint32_t>(bytes[6]) << 24U) |
      (static_cast<std::uint32_t>(bytes[7]) << 16U) |
      (static_cast<std::uint32_t>(bytes[8]) << 8U) | bytes[9];
  const std::uint16_t configurationConstraintLow =
      static_cast<std::uint16_t>(
          (static_cast<std::uint16_t>(bytes[10]) << 8U) | bytes[11]);
  const std::uint8_t configurationLevel = bytes[12];
  const auto skipProfileTierLevel = [](CodecRbspBitReader* bits,
                                       std::uint32_t subLayers,
                                       std::uint8_t expectedProfileByte,
                                       std::uint32_t expectedCompatibility,
                                       std::uint32_t expectedConstraintHigh,
                                       std::uint16_t expectedConstraintLow,
                                       std::uint8_t expectedLevel) noexcept {
    std::uint32_t profileByte = 0;
    std::uint32_t compatibility = 0;
    std::uint32_t constraintHigh = 0;
    std::uint32_t constraintLow = 0;
    std::uint32_t level = 0;
    std::uint32_t ignored = 0;
    if (!bits->readBits(8, &profileByte) ||
        profileByte != expectedProfileByte ||
        !bits->readBits(32, &compatibility) ||
        compatibility != expectedCompatibility ||
        !bits->readBits(32, &constraintHigh) ||
        constraintHigh != expectedConstraintHigh ||
        !bits->readBits(16, &constraintLow) ||
        constraintLow != expectedConstraintLow ||
        !bits->readBits(8, &level) || level != expectedLevel) {
      return false;
    }
    std::array<std::uint32_t, 8> profilePresent{};
    std::array<std::uint32_t, 8> levelPresent{};
    for (std::uint32_t layer = 0; layer < subLayers; ++layer) {
      if (!bits->readBits(1, &profilePresent[layer]) ||
          !bits->readBits(1, &levelPresent[layer])) {
        return false;
      }
    }
    if (subLayers > 0) {
      for (std::uint32_t layer = subLayers; layer < 8; ++layer) {
        if (!bits->readBits(2, &ignored)) {
          return false;
        }
      }
    }
    for (std::uint32_t layer = 0; layer < subLayers; ++layer) {
      if (profilePresent[layer]) {
        std::uint32_t subLayerProfileByte = 0;
        if (!bits->readBits(8, &subLayerProfileByte) ||
            (subLayerProfileByte & 0xc0U) != 0 ||
            (subLayerProfileByte & 0x1fU) !=
                (expectedProfileByte & 0x1fU) ||
            !bits->readBits(32, &ignored) ||
            !bits->readBits(32, &ignored) ||
            !bits->readBits(16, &ignored)) {
          return false;
        }
      }
      if (levelPresent[layer] && !bits->readBits(8, &ignored)) {
        return false;
      }
    }
    return true;
  };

  std::size_t offset = 23;
  bool foundVps = false;
  bool foundSps = false;
  bool foundPps = false;
  std::array<bool, 3> parameterSetArrays{};
  for (std::size_t array = 0; array < bytes[22]; ++array) {
    if (offset + 3 > bytes.size()) {
      return media::MediaVideoSampleFormat::Unsupported;
    }
    const std::uint8_t arrayHeader = bytes[offset];
    if ((arrayHeader & 0x40U) != 0) {
      return media::MediaVideoSampleFormat::Unsupported;
    }
    const std::uint8_t nalType = arrayHeader & 0x3fU;
    if (nalType >= 32U && nalType <= 34U &&
        (arrayHeader & 0x80U) == 0) {
      return media::MediaVideoSampleFormat::Unsupported;
    }
    if (nalType >= 32U && nalType <= 34U) {
      const std::size_t parameterSetIndex = nalType - 32U;
      if (parameterSetArrays[parameterSetIndex]) {
        return media::MediaVideoSampleFormat::Unsupported;
      }
      parameterSetArrays[parameterSetIndex] = true;
    }
    const std::size_t nalCount =
        (static_cast<std::size_t>(bytes[offset + 1]) << 8U) |
        bytes[offset + 2];
    offset += 3;
    for (std::size_t index = 0; index < nalCount; ++index) {
      if (offset + 2 > bytes.size()) {
        return media::MediaVideoSampleFormat::Unsupported;
      }
      const std::size_t length =
          (static_cast<std::size_t>(bytes[offset]) << 8U) |
          bytes[offset + 1];
      offset += 2;
      if (length < 2 || length > bytes.size() - offset) {
        return media::MediaVideoSampleFormat::Unsupported;
      }
      const std::uint8_t nalHeader0 = bytes[offset];
      const std::uint8_t nalHeader1 = bytes[offset + 1];
      const std::uint8_t layerId = static_cast<std::uint8_t>(
          ((nalHeader0 & 0x01U) << 5U) | (nalHeader1 >> 3U));
      if ((nalHeader0 & 0x80U) != 0 ||
          ((nalHeader0 >> 1U) & 0x3fU) != nalType ||
          (nalHeader1 & 0x07U) == 0) {
        return media::MediaVideoSampleFormat::Unsupported;
      }
      if (nalType >= 32U && nalType <= 34U &&
          (length < 3 || layerId != 0 || (nalHeader1 & 0x07U) != 1U)) {
        return media::MediaVideoSampleFormat::Unsupported;
      }
      if (nalType == 32U) {
        CodecRbspBitReader bits(bytes.subspan(offset + 2, length - 2));
        std::uint32_t ignored = 0;
        std::uint32_t subLayers = 0;
        std::uint32_t reserved = 0;
        if (!bits.readBits(4, &ignored) || !bits.readBits(1, &ignored) ||
            !bits.readBits(1, &ignored) || !bits.readBits(6, &ignored) ||
            !bits.readBits(3, &subLayers) || subLayers > 6 ||
            !bits.readBits(1, &ignored) || !bits.readBits(16, &reserved) ||
            reserved != 0xffffU ||
            !skipProfileTierLevel(
                &bits, subLayers, configurationProfile,
                configurationCompatibility, configurationConstraintHigh,
                configurationConstraintLow, configurationLevel)) {
          return media::MediaVideoSampleFormat::Unsupported;
        }
        foundVps = true;
      } else if (nalType == 34U) {
        foundPps = true;
      }
      if (nalType == 33U) {
        CodecRbspBitReader bits(bytes.subspan(offset + 2, length - 2));
        std::uint32_t ignored = 0;
        std::uint32_t subLayers = 0;
        std::uint32_t chromaFormat = 0;
        std::uint32_t spsLumaDepthMinusEight = 0;
        std::uint32_t spsChromaDepthMinusEight = 0;
        if (!bits.readBits(4, &ignored) ||
            !bits.readBits(3, &subLayers) || subLayers > 6 ||
            !bits.readBits(1, &ignored) ||
            !skipProfileTierLevel(
                &bits, subLayers, configurationProfile,
                configurationCompatibility, configurationConstraintHigh,
                configurationConstraintLow, configurationLevel) ||
            !bits.readUnsignedExpGolomb(&ignored) ||
            !bits.readUnsignedExpGolomb(&chromaFormat) || chromaFormat != 1 ||
            !bits.readUnsignedExpGolomb(&ignored) ||
            !bits.readUnsignedExpGolomb(&ignored) ||
            !bits.readBits(1, &ignored)) {
          return media::MediaVideoSampleFormat::Unsupported;
        }
        if (ignored != 0) {
          for (std::size_t windowOffset = 0; windowOffset < 4;
               ++windowOffset) {
            if (!bits.readUnsignedExpGolomb(&ignored)) {
              return media::MediaVideoSampleFormat::Unsupported;
            }
          }
        }
        if (!bits.readUnsignedExpGolomb(&spsLumaDepthMinusEight) ||
            !bits.readUnsignedExpGolomb(&spsChromaDepthMinusEight) ||
            spsLumaDepthMinusEight != lumaDepthMinusEight ||
            spsChromaDepthMinusEight != chromaDepthMinusEight) {
          return media::MediaVideoSampleFormat::Unsupported;
        }
        foundSps = true;
      }
      offset += length;
    }
  }
  if (!foundVps || !foundSps || !foundPps || offset != bytes.size()) {
    return media::MediaVideoSampleFormat::Unsupported;
  }
  return lumaDepthMinusEight == 2
             ? media::MediaVideoSampleFormat::Yuv420TenBit
             : media::MediaVideoSampleFormat::Yuv420EightBit;
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

[[nodiscard]] MediaCodec videoCodec(CMVideoCodecType codec) noexcept {
  switch (codec) {
    case kCMVideoCodecType_H264:
      return MediaCodec::H264;
    case kCMVideoCodecType_HEVC:
      return MediaCodec::Hevc;
    case kCMVideoCodecType_AV1:
      // AVFoundation demuxes and hardware-decodes av01-in-MP4 natively on
      // machines with an AV1 block; on machines without one the capability
      // gate keeps the codec Unknown so the whole asset falls back.
      return nativeVideoToolboxSupportsAv1() ? MediaCodec::Av1
                                             : MediaCodec::Unknown;
    case kCMVideoCodecType_VP9:
      // VP9-in-MP4 is rare, but the same gate applies: the supplemental
      // decoder must be registered and reported before the track is admitted.
      return nativeVideoToolboxSupportsVp9() ? MediaCodec::Vp9
                                             : MediaCodec::Unknown;
    default:
      return MediaCodec::Unknown;
  }
}

[[nodiscard]] CFStringRef videoCodecConfigurationAtomName(
    CMVideoCodecType codec) noexcept {
  switch (codec) {
    case kCMVideoCodecType_H264:
      return CFSTR("avcC");
    case kCMVideoCodecType_HEVC:
      return CFSTR("hvcC");
    case kCMVideoCodecType_AV1:
      return CFSTR("av1C");
    case kCMVideoCodecType_VP9:
      return CFSTR("vpcC");
    default:
      return nullptr;
  }
}

[[nodiscard]] MediaCodecConfigurationKind videoCodecConfigurationKind(
    CMVideoCodecType codec) noexcept {
  switch (codec) {
    case kCMVideoCodecType_H264:
      return MediaCodecConfigurationKind::AvcC;
    case kCMVideoCodecType_HEVC:
      return MediaCodecConfigurationKind::HvcC;
    case kCMVideoCodecType_AV1:
      return MediaCodecConfigurationKind::Av1C;
    case kCMVideoCodecType_VP9:
      return MediaCodecConfigurationKind::VpcC;
    default:
      return MediaCodecConfigurationKind::None;
  }
}

[[nodiscard]] MediaCodec audioCodec(AudioFormatID codec) noexcept {
  switch (codec) {
    case kAudioFormatMPEG4AAC:
    case kAudioFormatMPEG4AAC_HE:
    case kAudioFormatMPEG4AAC_HE_V2:
      return MediaCodec::Aac;
    case kAudioFormatAppleLossless:
      return MediaCodec::Alac;
    case kAudioFormatMPEGLayer3:
      return MediaCodec::Mp3;
    case kAudioFormatLinearPCM:
      return MediaCodec::Pcm;
    // Reachable only now that a video-less asset is admitted: these are the
    // formats a standalone music file carries, and AVFoundation demuxes all of
    // them (verified by probe against .flac/.opus/.ac3 assets). Every
    // enumerator already existed for the Matroska sweep -- nothing is appended
    // to the frozen MediaCodec enumeration here.
    case kAudioFormatFLAC:
      return MediaCodec::Flac;
    case kAudioFormatOpus:
      return MediaCodec::Opus;
    case kAudioFormatAC3:
      return MediaCodec::Ac3;
    case kAudioFormatEnhancedAC3:
      return MediaCodec::Eac3;
    default:
      return MediaCodec::Unknown;
  }
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

  // Amendment 6 splits this list. The two HDR volume/light descriptions leave
  // the opaque "unsupported" bit and become modelled PRESENCE facts, because
  // VideoToolbox copies them verbatim onto the decoded surface and the layer's
  // derived format description reproduces them byte for byte -- so they are
  // metadata this route now delivers rather than metadata it cannot honour.
  // Everything else on the list stays refused exactly as before.
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
      extensionPresent(format,
                       kCMFormatDescriptionExtension_AlphaChannelMode) ||
      extensionPresent(format,
                       kCMFormatDescriptionExtension_ContainsAlphaChannel);
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

  const media::MediaVideoSampleFormat sampleFormat =
      codec == MediaCodec::H264  ? parseH264SampleFormat(configuration)
      : codec == MediaCodec::Vp9 ? parseVp9SampleFormat(configuration)
      : codec == MediaCodec::Av1 ? parseAv1SampleFormat(configuration)
                                 : parseHevcSampleFormat(configuration);
  // VP9 Profile 2 and AV1 Main 10 reach the same 10-bit bi-planar output
  // surface as HEVC Main 10, so they carry the identical SDR contract: the
  // parsed depth must agree with the container's, and a 10-bit stream tagged
  // outside BT.709/unspecified is refused here rather than at frame delivery.
  if (codec == MediaCodec::Hevc || codec == MediaCodec::Vp9 ||
      codec == MediaCodec::Av1) {
    if (sampleFormat == media::MediaVideoSampleFormat::Unsupported) {
      return std::nullopt;
    }
    const std::uint8_t parsedBits =
        sampleFormat == media::MediaVideoSampleFormat::Yuv420TenBit ? 10 : 8;
    // Main 10 carries the same colour contract as Main -- and under amendment
    // 6 that contract now includes BT.2020/PQ/HLG. This gate used to hold a
    // SECOND, 10-bit-only copy of the colour rule, which is exactly the kind
    // of drift the single mediaVideoColorAdmitted() predicate exists to end:
    // there is no colour question that depends on the depth, so the depth
    // check keeps only the depth question. VideoToolbox's decoded-frame
    // attachments are still validated again before any frame is leased.
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
  video.masteringDisplayColorVolumePresent = masteringDisplayPresent;
  video.contentLightLevelInfoPresent = contentLightPresent;
  video.ambientViewingEnvironmentPresent = ambientViewingPresent;
  video.dolbyVisionConfigurationPresent =
      hasDolbyVisionConfiguration(format);
  video.sampleFormat = sampleFormat;
  return video;
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
  const CFStringRef atomName = videoCodecConfigurationAtomName(subtype);
  if (atomName == nullptr) {
    assignError(error, "AVFoundation video codec is outside native v1");
    return std::nullopt;
  }
  auto configuration =
      copyAtom(format, atomName, limits.maximumCodecConfigurationBytes);
  if (!configuration) {
    assignError(error,
                "video format lacks a bounded avcC/hvcC/vpcC/av1C atom");
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
  track.codecConfigurationKind = videoCodecConfigurationKind(subtype);
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

class CoreMediaSampleStorage final : public MediaPayloadStorage {
 public:
  CoreMediaSampleStorage(CMSampleBufferRef ownedSample,
                         std::size_t byteSize) noexcept
      : sample_(ownedSample), byte_size_(byteSize) {}
  ~CoreMediaSampleStorage() override {
    if (sample_ != nullptr) {
      CFRelease(sample_);
    }
  }

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
  return waitForConcurrentLoadBatch(
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
}

[[nodiscard]] MediaTrackId stableTrackId(AVAssetTrack* track,
                                         MediaTrackId fallback) noexcept {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  const CMPersistentTrackID raw = track.trackID;
#pragma clang diagnostic pop
  return raw > 0 ? static_cast<MediaTrackId>(raw) : fallback;
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
  // Kept deliberately identical to native_audio_converter.mm's
  // supportedChannelLayout: this is the descriptor-level restatement of the
  // same rule, and the two disagreeing would admit a descriptor the converter
  // then refuses at configure time -- a Startup failure instead of a clean
  // Unsupported verdict.
  const bool supportedLayout =
      !audio.channelLayoutPresent
          ? audio.channelLayoutTag == 0
      : audio.channels == 1
          ? audio.channelLayoutTag == kAudioChannelLayoutTag_Mono
      : audio.channels == 2
          ? audio.channelLayoutTag == kAudioChannelLayoutTag_Stereo
          : multichannelLayoutTagAdmitted(audio.channelLayoutTag,
                                          audio.channels);
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
// Only the LINEAR part (a, b, c, d) classifies. tx/ty are the translation
// that keeps the rotated rectangle in positive coordinates -- for a portrait
// 1920x1080 track, tx is 1080 -- so demanding zero translation is exactly the
// bug that refused these files in the first place. The translation is implied
// by the rotation and the coded size, and the presentation layer recomputes
// it from the rectangle it is drawing into rather than trusting it.
//
// Degrees are CLOCKWISE in screen terms (y down), which is the convention
// mediaVideoDisplaySize already reads when it swaps the rectangle for 90/270,
// and the convention the presentation layer's CATransform3D matches. The
// matrices are stated in Core Graphics' y-up algebra, where (x,y) maps to
// (a*x + c*y, b*x + d*y):
//
//     0 deg    a= 1 b= 0 c= 0 d= 1     identity
//    90 deg    a= 0 b= 1 c=-1 d= 0     +x -> +y   (clockwise on screen)
//   180 deg    a=-1 b= 0 c= 0 d=-1
//   270 deg    a= 0 b=-1 c= 1 d= 0
//
// Exact comparison, not a tolerance: these values are written as exact small
// integers by every muxer, and a matrix that is merely NEAR a quarter turn is
// a shear this player would silently render wrong. A near-miss is refused and
// says so, which is the honest outcome.
[[nodiscard]] bool quarterTurnVideoTransform(CGAffineTransform transform,
                                             int* degrees) noexcept {
  if (!std::isfinite(transform.a) || !std::isfinite(transform.b) ||
      !std::isfinite(transform.c) || !std::isfinite(transform.d) ||
      !std::isfinite(transform.tx) || !std::isfinite(transform.ty)) {
    return false;
  }
  const auto classify = [&](double a, double b, double c, double d,
                            int turn) noexcept -> bool {
    if (transform.a != a || transform.b != b || transform.c != c ||
        transform.d != d) {
      return false;
    }
    if (degrees != nullptr) {
      *degrees = turn;
    }
    return true;
  };
  return classify(1.0, 0.0, 0.0, 1.0, 0) ||
         classify(0.0, 1.0, -1.0, 0.0, 90) ||
         classify(-1.0, 0.0, 0.0, -1.0, 180) ||
         classify(0.0, -1.0, 1.0, 0.0, 270);
}

// The rebind proof's question: does this live transform still say exactly the
// angle the immutable descriptor recorded? A track whose transform changed
// under the reader is refused exactly as it always was.
[[nodiscard]] bool videoTransformMatchesRotation(
    CGAffineTransform transform, std::int16_t expectedDegrees) noexcept {
  int degrees = 0;
  if (!quarterTurnVideoTransform(transform, &degrees)) {
    return false;
  }
  return degrees == static_cast<int>(expectedDegrees);
}

// The descriptor's own statement of the same fact, so the admission gates and
// the rebind proof ask one question rather than three similar ones.
[[nodiscard]] bool quarterTurnRotationAdmitted(
    const media::MediaVideoFormat& video) noexcept {
  const int rotation = ((video.rotationDegrees % 360) + 360) % 360;
  const bool quarterTurn = rotation == 0 || rotation == 90 ||
                           rotation == 180 || rotation == 270;
  // identityTransform and rotationDegrees must agree. A descriptor claiming
  // an identity transform with a nonzero rotation (or the reverse) is not a
  // rotated file, it is a corrupted fact, and it is refused as one.
  return quarterTurn && video.identityTransform == (rotation == 0);
}

[[nodiscard]] bool preservesLegacyNativeAdmission(
    const MediaSourceDescriptor& descriptor, std::string* error) {
  const auto& inventory = descriptor.inventory;
  // Native v1 is a video contract, so exactly one video track and its
  // selection stay mandatory. Audio is optional: an audio-less asset (a
  // GIF-to-MP4 conversion, for instance) enumerates zero audio tracks and
  // leaves selectedAudio unset. The two must agree in both directions - an
  // inventory with audio that selected none, or a selection with no audio in
  // the inventory, is a descriptor this backend never builds.
  if (inventory.video > 1 || inventory.subtitle != 0 ||
      inventory.text != 0 || inventory.closedCaption != 0 ||
      descriptor.selectedVideo.has_value() != (inventory.video != 0) ||
      descriptor.selectedAudio.has_value() != (inventory.audio != 0) ||
      (!descriptor.selectedVideo && !descriptor.selectedAudio)) {
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
    //   .m4a  (AAC)   959488 frames, clock 1.000000. Unchanged; it was the
    //                 only admission before this sweep.
    //   .mp3          960000 frames -- exact -- CBR and VBR, stereo and mono.
    //   .flac         960000 frames -- exact -- 16-bit.
    //   .wav / .aiff  960000 frames -- exact -- 16- and 24-bit, 0 underruns,
    //                 clock exactly 1.000000.
    //   .ac3 / .eac3  959712 frames: the codec's own 256-frame decoder lead-in
    //                 and 32-frame withheld MDCT ring-down, the same envelope
    //                 the Matroska route publishes for them.
    //
    // Two codecs AVAsset does demux are deliberately NOT here, and both keep
    // the mpv fallback they already had:
    //
    //   Opus (.opus/.ogg)  AVFoundation states mFramesPerPacket = 0 and carries
    //                 the count per packet instead. The audio session's
    //                 preflight and the converter's whole frame-grid
    //                 arithmetic key on a nonzero declared framesPerPacket, so
    //                 admitting it would mean reworking the frozen converter
    //                 for a codec that already plays natively from Matroska.
    //   ALAC          Admitted by the converter, but a standalone ALAC .m4a
    //                 drained 1.9 s before its declared timeline ended
    //                 ("audio backend drained before its exact timeline
    //                 ended"). Its stated duration is not the decoded sample
    //                 count and its final packet is short; that is a duration
    //                 fact this route does not yet state exactly.
    //
    // The Matroska route carries its own codec sweep and is unaffected by this.
    switch (onlyAudio->codec) {
      case MediaCodec::Aac:
      case MediaCodec::Mp3:
      case MediaCodec::Flac:
      case MediaCodec::Pcm:
      case MediaCodec::Ac3:
      case MediaCodec::Eac3:
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
  if (track == nullptr || track->kind != MediaTrackKind::Video ||
      !track->video ||
      (track->codec != MediaCodec::H264 && track->codec != MediaCodec::Hevc &&
       track->codec != MediaCodec::Av1 && track->codec != MediaCodec::Vp9) ||
      track->codecConfiguration.empty() ||
      (track->codec == MediaCodec::H264 &&
       track->codecConfigurationKind != MediaCodecConfigurationKind::AvcC) ||
      (track->codec == MediaCodec::Hevc &&
       track->codecConfigurationKind != MediaCodecConfigurationKind::HvcC) ||
      (track->codec == MediaCodec::Av1 &&
       track->codecConfigurationKind != MediaCodecConfigurationKind::Av1C) ||
      (track->codec == MediaCodec::Vp9 &&
       track->codecConfigurationKind != MediaCodecConfigurationKind::VpcC)) {
    assignError(error,
                "selected video codec is outside the native v1 contract");
    return false;
  }
  const media::MediaVideoFormat& video = *track->video;
  // ONE colour rule, shared with native_video_consumer.mm. See
  // mediaVideoColorAdmitted() in native_media_source.hpp for what it admits
  // and what keeps a named refusal.
  const bool supportedModeledColor = media::mediaVideoColorAdmitted(video);
  const bool hevcDepthMatches =
      track->codec != MediaCodec::Hevc || video.bitsPerComponent == 0 ||
      (video.sampleFormat == media::MediaVideoSampleFormat::Yuv420EightBit &&
       video.bitsPerComponent == 8) ||
      (video.sampleFormat == media::MediaVideoSampleFormat::Yuv420TenBit &&
       video.bitsPerComponent == 10);
  // Main 10 shares the 8-bit colour contract: supportedModeledColor above is
  // the one rule for both depths, so an untagged Main 10 stream is admitted
  // exactly like an untagged Main one, and a BT.2020/PQ/HLG stream is admitted
  // at either depth. The opaque-metadata, Dolby Vision and ambient-viewing
  // refusals now live inside that predicate rather than being restated here,
  // so there is exactly one place a colour refusal can come from.
  // Quarter turns are presentable (the presentation layer rotates); anything
  // else was already refused at describeVideo and cannot reach here. This term
  // must stay in lockstep with supportedVideoTrack() in
  // native_video_consumer.mm -- if one admits a rotation the other refuses,
  // a clean Unsupported becomes a mid-startup Failed.
  // Named individually rather than folded into one verdict. This predicate has
  // seven independent reasons to refuse and they are not equally likely; a
  // single message meant a field report (and an agent bisecting a real file)
  // could not tell a rotation refusal from a chroma-siting one without a
  // rebuild. The terms and their order are unchanged -- only the diagnostic
  // is.
  const char* geometryRefusal = nullptr;
  if (!quarterTurnRotationAdmitted(video)) {
    geometryRefusal =
        "selected video rotation is outside the native v1 presentation "
        "contract";
  } else if (video.rotationDegrees != 0 &&
             !layerPresentationRouteSelected()) {
    // The scene-graph route has no rotation stage, so a rotated file must be
    // refused -- but it has to be refused HERE, at source admission, where a
    // refusal is a clean UnsupportedSource that opens the file on the
    // compatibility renderer with the friendly notice. NativeVideoConsumer
    // asks its output the same question and would also refuse, but that late
    // refusal surfaces as "native playback rejected an internal command",
    // which reads like a defect rather than a supported format falling back.
    // The consumer's check stays as the backstop that keeps the two honest.
    geometryRefusal =
        "rotated video needs the layer presentation route; the compatibility "
        "renderer will present it upright";
  } else if (!video.progressive) {
    geometryRefusal = "interlaced video is outside native v1";
  } else if (!supportedModeledColor) {
    geometryRefusal =
        "selected video color is outside the native v1 presentation contract";
  } else if (!hevcDepthMatches) {
    geometryRefusal =
        "HEVC bit depth disagrees with the decoded sample format";
  } else if (video.sampleFormat !=
                 media::MediaVideoSampleFormat::Yuv420EightBit &&
             video.sampleFormat !=
                 media::MediaVideoSampleFormat::Yuv420TenBit) {
    geometryRefusal = "selected video sample format is outside native v1";
  } else if (!media::mediaVideoHasFullCodedAperture(video)) {
    geometryRefusal =
        "selected video has a clean aperture smaller than its coded frame";
  } else if (!media::mediaVideoHasSquarePixels(video)) {
    geometryRefusal = "selected video has non-square pixels (anamorphic)";
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


[[nodiscard]] bool videoFormatMatchesTrack(
    CMVideoFormatDescriptionRef format, const MediaTrackDescriptor& track,
    const MediaSourceLimits& requestedLimits) noexcept {
  if (format == nullptr || track.kind != MediaTrackKind::Video ||
      !track.video ||
      CMFormatDescriptionGetMediaType(format) != kCMMediaType_Video ||
      videoCodec(CMFormatDescriptionGetMediaSubType(format)) != track.codec) {
    return false;
  }
  const CFStringRef atomName = track.codec == MediaCodec::H264
                                   ? CFSTR("avcC")
                                   : track.codec == MediaCodec::Hevc
                                         ? CFSTR("hvcC")
                                         : nullptr;
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
  const auto configuration = std::span<const std::byte>(
      reinterpret_cast<const std::byte*>(bytes),
      static_cast<std::size_t>(length));
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
  // "the format changed", which is untrue -- the format did not change, and
  // this function never saw the rotation in the first place.
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
  // exist. A descriptor that did select audio owes the original proof
  // unchanged, in the original order.
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
      // The rebind proof is unchanged in strength: the track's transform must
      // still be exactly what the immutable descriptor recorded. What changed
      // is that the admitted value is a quarter turn rather than only
      // identity, so the proof compares the classified angle against the
      // descriptor's instead of demanding zero from both.
      (videoSelected &&
       (!expectedVideo->video ||
        !quarterTurnRotationAdmitted(*expectedVideo->video) ||
        !videoTransformMatchesRotation(
            videoTransform, expectedVideo->video->rotationDegrees) ||
        !videoFormatMatchesTrack(videoFormat, *expectedVideo,
                                 requestedLimits))) ||
      (audioSelected &&
       !audioFormatMatchesTrack(audioFormat, *expectedAudio))) {
    // Say WHICH thing changed. This proof has six independent ways to fail and
    // reported all of them as one sentence; when the admitted transform set
    // widened, that sentence could no longer distinguish "the file really did
    // change under us" from "this proof does not yet understand the file",
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
      : request_(std::move(request)) {}

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
        if (!asset.playable || asset.hasProtectedContent) {
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
        // Native v1 admits exactly one video track and no timed-text tracks.
        // Audio is optional: an asset that enumerates no audio track (a
        // GIF-to-MP4 conversion, for instance) is admitted video-only and
        // leaves selectedAudio unset. An enumerated audio track that could not
        // be resolved to a selection - or a resolved track the inventory never
        // counted - stays a rejection, so the two must agree exactly.
        if (inventory.video > 1 || inventory.subtitle != 0 ||
            inventory.text != 0 || inventory.closedCaption != 0 ||
            (videoTrack != nil) != (inventory.video != 0) ||
            (audioTrack != nil) != (inventory.audio != 0) ||
            (videoTrack == nil && audioTrack == nil)) {
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
        const std::array selectedTrackLoadStorage{
            AsyncLoadRequest{videoTrack != nil ? videoTrack : audioTrack,
                             trackKeys},
            AsyncLoadRequest{videoTrack != nil ? audioTrack : nil, trackKeys}};
        const std::span<const AsyncLoadRequest> selectedTrackLoadRequests(
            selectedTrackLoadStorage.data(),
            static_cast<std::size_t>(videoTrack != nil ? 1u : 0u) +
                static_cast<std::size_t>(audioTrack != nil ? 1u : 0u));
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
        if (audioTrack != nil) {
          if (!preservesZeroBasedTrackTimeline(audioTrack, &result.error)) {
            result.status = AVFoundationGenerationStatus::Unsupported;
            return result;
          }
          MediaTrackId audioId = stableTrackId(audioTrack, 2);
          if (mutableDescriptor->selectedVideo &&
              audioId == *mutableDescriptor->selectedVideo) {
            audioId = *mutableDescriptor->selectedVideo == 1 ? 2 : 1;
          }
          auto audioDescriptor =
              describeAudio(audioTrack, audioId, limits, &result.error);
          if (!audioDescriptor) {
            result.status = AVFoundationGenerationStatus::Unsupported;
            return result;
          }
          mutableDescriptor->selectedAudio = audioDescriptor->id;
          mutableDescriptor->tracks.push_back(std::move(*audioDescriptor));
        }
        if (!media::validateMediaSourceDescriptor(
                *mutableDescriptor, limits, &result.error)) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          return result;
        }
        if (!preservesLegacyNativeAdmission(*mutableDescriptor,
                                            &result.error)) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          return result;
        }
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
                (__bridge const void*)audioTrack},
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
          const MediaTrackDescriptor* audio =
              media::findMediaTrack(*descriptor, *descriptor->selectedAudio);
          const std::optional<AudioPrimingPlan> priming =
              audio == nullptr
                  ? std::optional<AudioPrimingPlan>{}
                  : audioPrimingPlanFacts(*audio, *request_.target);
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
          audio_playout_proof_ceiling_ = priming->proofCeiling;
        }
        decodeStart = videoTrack == nil ? searchStart
                                        : syncStart(videoTrack, searchStart);
        if (!CMTIME_IS_NUMERIC(decodeStart)) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error = "AVFoundation could not locate a bounded sync start";
          return result;
        }
        // See clampedSyncStartWithinTimelineContract: an edit list can put the
        // located random-access point outside `0 <= start <= target` at either
        // end without being malformed, and this route was the only one of the
        // four sources with no origin floor at all.
        decodeStart = clampedSyncStartWithinTimelineContract(decodeStart,
                                                             *target);
        const CMTime preroll = CMTimeSubtract(*target, decodeStart);
        const CMTime maximumPreroll = CMTimeMakeWithSeconds(
            limits.maximumVideoSeekPrerollSeconds, 60'000);
        if (CMTimeCompare(preroll, kCMTimeZero) < 0 ||
            CMTimeCompare(preroll, maximumPreroll) > 0) {
          result.status = AVFoundationGenerationStatus::Unsupported;
          result.error = "native seek exceeds its bounded sync preroll";
          return result;
        }
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
      // The video lane's restatement was long believed unnecessary because the
      // decoded frame already arrives on the movie timeline (VideoToolbox
      // reports each frame at its sample's OUTPUT stamp). That is true, and it
      // is exactly the defect: only the DECODED half had moved. The compressed
      // half stayed on the media timeline, so the two halves of one lane were
      // stated on two different clocks, and they diverge by precisely the edit
      // shift -- invisible on a no-edit file, and a refused negative decoded
      // frame on a head-trimmed one.
      video_movie_shift_ = kCMTimeZero;
      if (videoTrack != nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray* videoSegments = videoTrack.segments;
#pragma clang diagnostic pop
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
        // Place access unit 0 the decoder's own lead-in before the origin, the
        // way every other route already does. See audioDecoderLeadInShift:
        // zero for AAC, FLAC, ALAC and LPCM, and zero for every real container,
        // so this is inert for every track this route admitted before the
        // standalone-audio sweep.
        {
          const MediaTrackDescriptor* selectedAudio =
              descriptor->selectedAudio
                  ? media::findMediaTrack(*descriptor,
                                          *descriptor->selectedAudio)
                  : nullptr;
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
        // A leading empty edit declares silence on the movie timeline before
        // any audio media exists; a selected video that runs past the end of
        // the selected audio declares it at the other end. Both are stated to
        // the neutral contract as facts of the audio window -- mediaStart and
        // presentationEnd -- and the audio-authoritative clock advances across
        // them at rate 1.0 with the renderer emitting zeros. Neither is a
        // refusal any more, and neither is an underrun: the source says the
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
          // simply keeps today's behaviour rather than guessing one.
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
        const auto range = exactReaderTimeRangeFacts(assetDuration,
                                                     decodeStart);
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
        [reader cancelReading];
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
    provedImmediatePlayoutOnFirstUnit(copied.sample);
    return copied;
  }

  void cancel() noexcept override {
    try {
      cancelled_.store(true, std::memory_order_release);
      metadata_load_signal_->cancel();
      @autoreleasepool {
        AVURLAsset* loadingAsset = nil;
        AVAssetReader* reader = nil;
        {
          std::lock_guard lock(objects_mutex_);
          loadingAsset = loading_asset_;
          reader = reader_;
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
    int rotationDegrees = 0;
    if (!quarterTurnVideoTransform(transform, &rotationDegrees)) {
      // Still refused, and still by name -- but now only for the transforms
      // this player genuinely cannot present: shears, flips, and arbitrary
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
      const std::string refusal =
          media::codedDimensionRefusalMessage(
              static_cast<std::uint64_t>(coded.width),
              static_cast<std::uint64_t>(coded.height)) +
          " (CodedDimensionLimit)";
      assignError(error, refusal.c_str());
      return std::nullopt;
    }
    auto result = inspectVideoFormatImpl(
        format, stableTrackId(track, 1), *duration, limits, error);
    if (result && naturalTimeScale > 0) {
      result->timeBase = {1, naturalTimeScale};
    }
    if (result) {
      result->video->identityTransform = rotationDegrees == 0;
      result->video->rotationDegrees =
          static_cast<std::int16_t>(rotationDegrees);
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

  // Sample cursors are positioned and report timestamps in the track's own
  // media timeline, while the seek target, the descriptor duration and the
  // reader time range are all stated in the asset timeline. An edit list that
  // offsets the media - which every composition-delayed H.264/HEVC track
  // carries - separates the two, so map the target into media time before
  // walking, and map the located full-sync sample back out of it. Both maps
  // are exact or the caller fails closed on a non-numeric decode start.
  [[nodiscard]] CMTime syncStart(AVAssetTrack* track,
                                 CMTime target) noexcept {
    // A leading EMPTY EDIT declares a span of movie time before any of this
    // track's media exists, and AVFoundation answers
    // samplePresentationTimeForTrackTime: with kCMTimeInvalid inside it --
    // correctly, because no sample is mapped there. Every cold open asks for
    // exactly track time 0 (native_media_session.mm states an initial position
    // unconditionally), so a file carrying one was refused outright with "could
    // not locate a bounded sync start" even though it is spec-legal, plays in
    // QuickTime, and differs from its admitted siblings only by that edit.
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
      // agrees. Closed-GOP H.264 satisfies this on the first full-sync sample
      // and is unchanged.
      if (cursor.currentSampleSyncInfo.sampleIsFullSync &&
          CMTimeCompare(cursor.presentationTimeStamp, mediaTarget) <= 0) {
        return CMTimeSubtract(cursor.presentationTimeStamp, mediaOffset);
      }
      if ([cursor stepInDecodeOrderByCount:-1] == 0) {
        break;
      }
    }
    return kCMTimeInvalid;
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
  // priming trim and the AAC decoder refresh count). Native v1 consumes the
  // media timeline and owns its decode-versus-presentation window itself, so
  // republish each unit on its input timing alone before it leaves this
  // backend. Compressed audio decode order is presentation order, so the
  // redundant decode stamp is dropped rather than reconciled. The container's
  // end trim, folded into the final access unit's duration, is restated on the
  // codec's ordinal packet grid for the same reason. Returns a +1 reference,
  // or null when the unit cannot be restated exactly.
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
    static_cast<void>(restateCompressedAudioPacketDurations(
        sample, audio_timing_.data(), static_cast<std::size_t>(entries)));
    for (CMItemCount index = 0; index < entries; ++index) {
      CMSampleTimingInfo& timing =
          audio_timing_[static_cast<std::size_t>(index)];
      // Compressed audio decode order is presentation order, so the redundant
      // decode stamp is dropped rather than reconciled.
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
    // Now redundant rather than merely ignored: the offset this attachment
    // annotated has been applied to the timestamps above, so the silence it
    // asked the consumer to fill is already accounted for on the movie
    // timeline. Stripping it before that shift existed would have been a ~1 s
    // desync; stripping it after is the restatement completing.
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
    return restated;
  }

  // One staged sample's worth of audio access units, drawn from the reader's
  // own batch and re-cut to the native bound when the batch is larger than it.
  // The steady state is a pass-through: every compressed batch this backend has
  // been measured against (84 MP3 / 21 FLAC / 140 AAC / 101 Opus units) already
  // fits, so nothing is copied and nothing is retained. Only LPCM, whose batch
  // is the reader's whole 2 s read, ever enters the re-cut path.
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
    // v1 reads the media timeline and owns its decoder lifecycle and its own
    // end of stream, so none of these are publishable and none of them are
    // faults. Drop them and read on; the read after the tail reports the
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
  // constant displacement -- both of which leave the video statement exactly
  // where it was before the restatement existed.
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

[[nodiscard]] bool sampleIsKeyFrame(CMSampleBufferRef sample,
                                    bool* keyFrame) noexcept {
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

struct StagedSample {
  MediaTrackId track{0};
  MediaTime orderTime{};
  std::variant<MediaSample, media::MediaDiscontinuity> value;
  std::size_t payloadBytes{0};
};

[[nodiscard]] std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
  return value == std::numeric_limits<std::uint64_t>::max() ? value
                                                            : value + 1;
}

}  // namespace

struct AVFoundationMediaSource::Impl {
  explicit Impl(std::shared_ptr<AVFoundationBackend> suppliedBackend)
      : backend(suppliedBackend != nullptr
                    ? std::move(suppliedBackend)
                    : std::make_shared<ProductionBackend>()) {}

  std::shared_ptr<AVFoundationBackend> backend;
  std::filesystem::path path;
  media::MediaSourceOpenOptions options;
  MediaSourceLimits limits;
  std::shared_ptr<const MediaSourceDescriptor> descriptor;
  std::shared_ptr<const AVFoundationAssetContext> assetContext;
  std::shared_ptr<AVFoundationGeneration> ownerGeneration;
  // Apple libc++ deployments supported by WAM do not all provide the C++20
  // atomic<shared_ptr> specialization. The standard shared_ptr atomic free
  // functions provide the same lifetime-safe publication on those runtimes.
  std::shared_ptr<AVFoundationGeneration> publishedGeneration;
  std::optional<StagedSample> videoHead;
  std::optional<StagedSample> audioHead;
  std::optional<MediaTime> requestedTarget;
  media::MediaSeekMode seekMode{media::MediaSeekMode::Accurate};
  std::string failure;

  // Per-generation admission cache for the compressed sample's format
  // description. sampleFormatMatchesTrack walks roughly two dozen
  // CoreFoundation dictionary lookups and, for H.264/HEVC, an exp-Golomb walk
  // of the SPS -- 2-10 us on EVERY frame, spent re-deriving an answer that
  // cannot change while the format description object is the same one. This is
  // the single largest per-frame cost the 2026-08-17 audit found anywhere in
  // the pipeline, and it is per-open work executed per sample: the exact shape
  // the "dispatch at the top, not in the loop" rule exists to catch.
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

  MediaGeneration generation{0};
  MediaGeneration armedGeneration{0};
  bool open{false};
  bool videoTerminal{true};
  bool audioTerminal{true};
  // A consumed capacity-one head is refilled only when the downstream owner
  // asks for another result.  Keeping the lane identity explicit prevents the
  // first delivered sample from waiting on a speculative replacement pull.
  bool videoRefillPending{false};
  bool audioRefillPending{false};
  bool videoEosEmitted{false};
  bool audioEosEmitted{false};

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
    operationGeneration.store(open ? generation : 0,
                              std::memory_order_release);
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
    auto active = std::atomic_load_explicit(&publishedGeneration,
                                            std::memory_order_acquire);
    if (active != nullptr && active->generation() == requested) {
      active->cancel();
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

  void retireActive() noexcept {
    auto active = std::atomic_exchange_explicit(
        &publishedGeneration, std::shared_ptr<AVFoundationGeneration>{},
        std::memory_order_acq_rel);
    if (active != nullptr) {
      active->cancel();
    }
    ownerGeneration.reset();
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

  void updatePeak(std::size_t total) noexcept {
    std::size_t peak = peakStagedPayloadBytes.load(std::memory_order_relaxed);
    while (peak < total &&
           !peakStagedPayloadBytes.compare_exchange_weak(
               peak, total, std::memory_order_relaxed,
               std::memory_order_relaxed)) {
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
    const auto pts =
        exactMediaTime(CMSampleBufferGetPresentationTimeStamp(sample));
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
      const auto decodeOnly = accurateVideoDecodeOnlyFacts(
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
      (video ? videoHead : audioHead) = std::move(head);
      publishHeadFacts();
      return true;
    }
  }

  [[nodiscard]] bool refillPendingLane(bool video, std::string* error) {
    bool& pending = video ? videoRefillPending : audioRefillPending;
    std::optional<StagedSample>& head = video ? videoHead : audioHead;
    const bool terminal = video ? videoTerminal : audioTerminal;
    if (!pending) {
      return true;
    }

    // Consume the demand edge before entering AVFoundation.  A read failure is
    // sticky and must not turn later readNext() calls into implicit retries.
    pending = false;
    if (head || terminal) {
      return true;
    }
    return stage(video, false, error);
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
    const double rate = track->audio->sampleRate;
    if (!std::isfinite(rate) || rate <= 0.0 ||
        rate > static_cast<double>(
                   std::numeric_limits<std::uint32_t>::max())) {
      return std::nullopt;
    }
    const auto sampleRate = static_cast<std::uint32_t>(rate);
    if (static_cast<double>(sampleRate) != rate) {
      return std::nullopt;
    }
    const MediaTime decodeStart = head->presentationTime;
    const auto decodeFrame =
        media::exactAudioFrameIndex(decodeStart, sampleRate);
    // On the movie timeline the codec's own priming access unit legitimately
    // sits BEFORE media time zero -- an edit list that trims AAC-LC encoder
    // priming says exactly that. This is the case the neutral timeline already
    // models as audioCodecPrecedesStreamOrigin/trimBeforeFloor; it only became
    // reachable on this route once audio moved onto the movie timeline.
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
      // grid cannot name a sample-exact boundary, so the generation keeps
      // today's behaviour (it ends at its own audio end) rather than guessing.
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

  [[nodiscard]] bool refillPendingHeads(std::string* error) {
    // Keep the source's established deterministic lane precedence.  In normal
    // operation exactly one lane is pending, but handling both makes recovery
    // from a terminal edge explicit without weakening the capacity-one bound.
    return refillPendingLane(true, error) &&
           refillPendingLane(false, error);
  }

  [[nodiscard]] AVFoundationGenerationStart begin(
      AVFoundationGenerationRequest request) {
    const std::filesystem::path requestedPath = request.path;
    const media::MediaSourceOpenOptions requestedOptions = request.options;
    const std::shared_ptr<const AVFoundationAssetContext> requestedContext =
        request.assetContext;
    generation = request.generation;
    limits = media::clampMediaSourceLimits(request.options.limits);
    requestedTarget = request.target;
    seekMode = request.seekMode;

    // armOperation() already published this exact cancellation slot before an
    // outer owner could expose the operation. Never clear that latch here.
    if (isCancelled()) {
      AVFoundationGenerationStart cancelled;
      cancelled.status = AVFoundationGenerationStatus::Cancelled;
      withdrawFailedOperation();
      return cancelled;
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
      AVFoundationGenerationStart cancelled;
      cancelled.status = AVFoundationGenerationStatus::Cancelled;
      withdrawFailedOperation();
      return cancelled;
    }

    ownerGeneration = backend->makeGeneration(std::move(request));
    if (ownerGeneration == nullptr ||
        ownerGeneration->generation() != generation) {
      AVFoundationGenerationStart invalid;
      invalid.error = "AVFoundation backend returned the wrong generation";
      withdrawFailedOperation();
      return invalid;
    }
    std::atomic_store_explicit(&publishedGeneration, ownerGeneration,
                               std::memory_order_release);
    if (isCancelled()) {
      ownerGeneration->cancel();
    }
    AVFoundationGenerationStart started = ownerGeneration->start();
    if (isCancelled() ||
        started.status == AVFoundationGenerationStatus::Cancelled) {
      started.status = AVFoundationGenerationStatus::Cancelled;
      withdrawFailedOperation();
      return started;
    }
    if (started.status != AVFoundationGenerationStatus::Ready ||
        started.descriptor == nullptr || !started.actualDecodeStart.valid()) {
      if (started.status == AVFoundationGenerationStatus::Ready) {
        started.status = AVFoundationGenerationStatus::Failed;
        started.error = "AVFoundation ready proof is incomplete";
      }
      withdrawFailedOperation();
      return started;
    }
    if (!media::validateMediaSourceDescriptor(*started.descriptor, limits,
                                              &started.error)) {
      started.status = AVFoundationGenerationStatus::Unsupported;
      withdrawFailedOperation();
      return started;
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
      return started;
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
        return started;
      }
    }
    if (!preservesLegacyNativeAdmission(*started.descriptor,
                                        &started.error)) {
      started.status = AVFoundationGenerationStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }
    if ((options.selection.requireVideo &&
         !started.descriptor->selectedVideo) ||
        (options.selection.requireAudio &&
         !started.descriptor->selectedAudio)) {
      started.status = AVFoundationGenerationStatus::Unsupported;
      started.error = "AVFoundation did not select every required track";
      withdrawFailedOperation();
      return started;
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
      return started;
    }
    started.audioWindow =
        audioGenerationWindow(started.actualDecodeStart,
                              started.declaredAudioMediaStart,
                              started.declaredPresentationEnd,
                              started.declaredAudioEnd)
            .value_or(media::MediaAudioGenerationWindow{});
    open = true;
    openSnapshot.store(true, std::memory_order_release);
    return started;
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
  media::MediaSourceOpenOutcome outcome;
  outcome.generation = generation;
  try {
    if (!impl_->consumeArm(generation)) {
      outcome.error = "AVFoundation open generation was not armed";
      return outcome;
    }
    if (impl_->operationCancelled(generation)) {
      impl_->generation = generation;
      impl_->withdrawFailedOperation();
      outcome.status = media::MediaSourceOpenStatus::Cancelled;
      outcome.error = "AVFoundation open was cancelled before entry";
      return outcome;
    }
    if (path.empty() || impl_->open ||
        !media::validateMediaSourceInitialPosition(options.initialPosition,
                                                   &outcome.error)) {
      if (outcome.error.empty()) {
        outcome.error = "invalid AVFoundation open path or state";
      }
      impl_->restoreCurrentPublicationAfterRejectedOperation();
      return outcome;
    }
    impl_->path = path;
    impl_->options = options;
    AVFoundationGenerationRequest request;
    request.path = path;
    request.options = options;
    request.generation = generation;
    if (options.initialPosition) {
      request.target = options.initialPosition->target;
      request.seekMode = options.initialPosition->mode;
    }
    AVFoundationGenerationStart started = impl_->begin(std::move(request));
    switch (started.status) {
      case AVFoundationGenerationStatus::Ready:
        outcome.status = media::MediaSourceOpenStatus::Ready;
        break;
      case AVFoundationGenerationStatus::Unsupported:
        outcome.status = media::MediaSourceOpenStatus::Unsupported;
        break;
      case AVFoundationGenerationStatus::Cancelled:
        outcome.status = media::MediaSourceOpenStatus::Cancelled;
        break;
      case AVFoundationGenerationStatus::Failed:
        outcome.status = media::MediaSourceOpenStatus::Failed;
        break;
    }
    outcome.actualDecodeStart = started.actualDecodeStart;
    outcome.descriptor = std::move(started.descriptor);
    outcome.error = std::move(started.error);
    if (outcome.status == media::MediaSourceOpenStatus::Ready) {
      outcome.preparedContext = std::move(started.assetContext);
      outcome.audioWindow = started.audioWindow;
    }
  } catch (const std::exception& exception) {
    impl_->withdrawFailedOperation();
    outcome.error = exception.what();
  } catch (...) {
    impl_->withdrawFailedOperation();
    outcome.error = "AVFoundation open raised an unknown exception";
  }
  return outcome;
}

media::MediaSourceSeekOutcome AVFoundationMediaSource::seek(
    const media::MediaSourceSeekRequest& request) {
  media::MediaSourceSeekOutcome outcome;
  outcome.generation = request.generation;
  try {
    if (!impl_->consumeArm(request.generation)) {
      outcome.error = "AVFoundation seek generation was not armed";
      return outcome;
    }
    if (impl_->operationCancelled(request.generation)) {
      impl_->generation = request.generation;
      impl_->withdrawFailedOperation();
      outcome.error = "AVFoundation seek was cancelled before entry";
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
        outcome.error = "invalid AVFoundation seek request";
      }
      impl_->restoreCurrentPublicationAfterRejectedOperation();
      return outcome;
    }
    const auto priorDescriptor = impl_->descriptor;
    const auto priorContext = impl_->assetContext;
    AVFoundationGenerationRequest generationRequest;
    generationRequest.path = impl_->path;
    generationRequest.options = impl_->options;
    generationRequest.generation = request.generation;
    generationRequest.target = request.target;
    generationRequest.seekMode = request.mode;
    generationRequest.assetContext = impl_->assetContext;
    AVFoundationGenerationStart started =
        impl_->begin(std::move(generationRequest));
    if (started.status != AVFoundationGenerationStatus::Ready) {
      outcome.error = std::move(started.error);
      return outcome;
    }
    if (priorDescriptor == nullptr || priorContext == nullptr ||
        impl_->descriptor.get() != priorDescriptor.get() ||
        impl_->assetContext.get() != priorContext.get()) {
      outcome.error =
          "AVFoundation prepared identity changed across seek";
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
    outcome.error = "AVFoundation seek raised an unknown exception";
  }
  return outcome;
}

media::MediaSourceReadResult AVFoundationMediaSource::readNext(
    MediaGeneration expectedGeneration) {
  try {
    if (!impl_->open || expectedGeneration != impl_->generation ||
        impl_->isCancelled()) {
      if (impl_->isCancelled()) {
        impl_->withdrawFailedOperation();
      }
      return media::MediaSourceCancelled{expectedGeneration};
    }

    // Admission already owns one exact head per selected output.  Once a head
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
        refillError = "AVFoundation staging raised an unknown exception";
      }
      if (!refilled) {
        if (impl_->isCancelled()) {
          impl_->withdrawFailedOperation();
          return media::MediaSourceCancelled{expectedGeneration};
        }
        impl_->failure =
            refillError.empty()
                ? "AVFoundation could not stage the next sample"
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
      if (std::holds_alternative<MediaSample>(emitted.value)) {
        impl_->samplesEmitted.store(
            saturatingIncrement(
                impl_->samplesEmitted.load(std::memory_order_relaxed)),
            std::memory_order_relaxed);
        return std::get<MediaSample>(std::move(emitted.value));
      }
      return std::get<media::MediaDiscontinuity>(std::move(emitted.value));
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
    return media::MediaSourceFailure{
        expectedGeneration, "AVFoundation read raised an unknown exception"};
  }
}

void AVFoundationMediaSource::requestCancel(MediaGeneration generation) noexcept {
  try {
    impl_->publishCancellation(generation);
  } catch (...) {
  }
}

void AVFoundationMediaSource::close() noexcept {
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
  } catch (...) {
  }
}

media::MediaSourceStats AVFoundationMediaSource::stats() const noexcept {
  media::MediaSourceStats result;
  result.open = impl_->openSnapshot.load(std::memory_order_acquire);
  result.operationGeneration =
      impl_->operationGeneration.load(std::memory_order_acquire);
  result.generation = impl_->generationHighWater.load(std::memory_order_acquire);
  result.cancelled = result.operationGeneration != 0 &&
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
  result.peakStagedPayloadBytes = std::max(
      impl_->peakStagedPayloadBytes.load(std::memory_order_relaxed),
      result.stagedPayloadBytes);
  result.samplesEmitted = impl_->samplesEmitted.load(std::memory_order_relaxed);
  result.seeksAccepted = impl_->seeksAccepted.load(std::memory_order_relaxed);
  return result;
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

CMTime clampedSyncStartWithinTimelineContractForTesting(
    CMTime decodeStart, CMTime target) noexcept {
  return clampedSyncStartWithinTimelineContract(decodeStart, target);
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
  return accurateVideoDecodeOnlyFacts(
      *exactPresentationTime, exactDuration.value_or(media::MediaTime{}),
      target, error);
}

}  // namespace avfoundation_media_source_testing
#endif

}  // namespace wam::macos
