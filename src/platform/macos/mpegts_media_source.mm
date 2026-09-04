#include "platform/macos/mpegts_media_source.hpp"

#include "platform/macos/mpegts_sample_builder.hpp"

#include "media/audio_codec_timing.hpp"
#include "media/matroska_ac3.hpp"
#include "media/matroska_mpeg_audio.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <algorithm>
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
using media::MediaSample;
using media::MediaSampleKind;
using media::MediaSourceDescriptor;
using media::MediaSourceLimits;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackId;
using media::MediaTrackKind;
using media::mpegts::CancellationToken;
using media::mpegts::MpegTsCompressedSample;
using media::mpegts::MpegTsCursor;
using media::mpegts::MpegTsCursorCancelled;
using media::mpegts::MpegTsCursorEnd;
using media::mpegts::MpegTsCursorFailure;
using media::mpegts::MpegTsDemuxError;
using media::mpegts::MpegTsDemuxStatus;
using media::mpegts::MpegTsGenerationPlan;
using media::mpegts::MpegTsPreparedAsset;

// Decoder preroll the audio converter demands ahead of the first audible frame
// of a generation that does not begin at the stream origin, stated in whole
// compressed access units. Identical to the AVFoundation and Matroska
// backends' constant and for the same reason: a transform codec reconstructs
// each access unit partly from its predecessor's window, so two decoded
// predecessors is the conventional full priming.
constexpr std::int64_t kAudioPrimingAccessUnits{2};
constexpr std::int64_t kMaximumAudioFramesPerPacket{65'536};

// Frames Apple's decoder swallows at the head of a track before it emits its
// first PCM frame. This MUST be the same number `native_audio_converter.mm`'s
// `decoderLeadInFrames()` uses, because the session proves the generation by
// checking that the converter's first published frame lands exactly on the
// presentation floor: the source states the decode start, the converter adds
// its lead-in, and the two have to meet.
//
// Matroska gets this for free -- it carries CodecDelay, and its demuxer places
// access unit 0 that many frames before the presentation origin. A transport
// stream states nothing of the kind: a PES header carries a presentation time
// and no delay field at all, so the shift has to be applied here or the first
// published frame lands `leadIn` frames late and the whole generation is
// refused with `audio session: Converter` (measured: AC-3 reported
// first=256 floor=0 before this existed).
//
// The values are the shared constants rather than copies, so a future
// measurement that moves one moves both sides of the proof together.
[[nodiscard]] std::int64_t audioDecoderLeadInFrames(MediaCodec codec) noexcept {
  switch (codec) {
  case MediaCodec::Ac3:
  case MediaCodec::Eac3:
    return media::matroska::kAc3DecoderDelayFrames;
  case MediaCodec::Mp3:
    return media::matroska::kMpegLayer3DecoderDelayFrames;
  // AAC swallows nothing -- measured deficit zero over whole tracks -- and its
  // encoder priming is real audio at the head of the elementary stream that
  // the PES timestamps already describe.
  default:
    return 0;
  }
}

void assignError(std::string* error, const char* message) {
  if (error != nullptr) {
    *error = message;
  }
}

[[nodiscard]] std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
  return value == std::numeric_limits<std::uint64_t>::max() ? value
                                                            : value + 1;
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

// Nearest audio frame ordinal to a container timestamp, computed in 128 bits.
//
// This exists because a transport stream states audio time on a 90 kHz grid
// and 90 kHz does not divide a 44.1 kHz frame grid: 1024 AAC frames are
// 2089.79... ticks, so a PES timestamp is ALWAYS a rounded value. The
// converter, meanwhile, requires audio samples to be exactly contiguous on the
// codec's own frame grid. Rounding to the nearest frame here is therefore not
// an approximation of the truth -- it RECOVERS the truth the muxer rounded,
// and the ordinal counter that follows never rounds again.
[[nodiscard]] std::optional<std::int64_t> nearestAudioFrame(
    MediaTime time, std::uint32_t sampleRate) noexcept {
  if (!time.valid() || sampleRate == 0) {
    return std::nullopt;
  }
  const auto scale = static_cast<__int128>(time.timescale);
  const __int128 numerator =
      static_cast<__int128>(time.value) * static_cast<__int128>(sampleRate);
  const __int128 rounded =
      numerator >= 0 ? (numerator * 2 + scale) / (scale * 2)
                     : -((-numerator * 2 + scale) / (scale * 2));
  if (rounded < std::numeric_limits<std::int64_t>::min() ||
      rounded > std::numeric_limits<std::int64_t>::max()) {
    return std::nullopt;
  }
  return static_cast<std::int64_t>(rounded);
}

// Exact frame ordinal -> MediaTime, reduced to lowest terms so comparisons
// against timestamps from the 90 kHz base stay exact and cheap.
[[nodiscard]] std::optional<MediaTime> audioFrameTime(
    std::int64_t frame, std::uint32_t sampleRate) noexcept {
  if (sampleRate == 0) {
    return std::nullopt;
  }
  auto numerator = frame;
  auto denominator = static_cast<std::int64_t>(sampleRate);
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

// The converter compares every ASBD field, the magic cookie bytes, and the
// channel layout tag against the admitted descriptor, so all three are
// restated from the descriptor rather than re-derived from the bitstream.
//
// Two shapes are admitted, and exactly two: a codec that HAS a magic cookie
// must present it as one (ADTS AAC, whose ES_Descriptor the demuxer
// synthesized through the shared builder so a TS-sourced AAC track is
// byte-identical downstream to a Matroska-sourced one), and a codec that has
// none must present nothing at all (AC-3, E-AC-3 and MPEG audio all restate
// every parameter in each frame header).
[[nodiscard]] CMAudioFormatDescriptionRef
createAudioFormatDescription(const MediaTrackDescriptor& track) noexcept {
  const bool cookiePresent =
      track.codecConfigurationKind ==
          MediaCodecConfigurationKind::AudioMagicCookie &&
      !track.codecConfiguration.empty();
  const bool cookieAbsent =
      track.codecConfigurationKind == MediaCodecConfigurationKind::None &&
      track.codecConfiguration.empty();
  if (!track.audio || track.kind != MediaTrackKind::Audio ||
      (!cookiePresent && !cookieAbsent)) {
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
      track.codecConfiguration.size(),
      cookiePresent ? track.codecConfiguration.data() : nullptr, nullptr,
      &description);
  if (status != noErr && description != nullptr) {
    CFRelease(description);
    description = nullptr;
  }
  return status == noErr ? description : nullptr;
}

// States the ImmediatePlayoutFrame proof the converter requires before it will
// admit a generation that does not begin at the stream origin.
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
  std::shared_ptr<const MpegTsAssetContext> context;
  media::MediaAudioGenerationWindow audioWindow{};
  std::string error;
};

}  // namespace

struct MpegTsMediaSource::Impl {
  Impl() = default;
  ~Impl() { releaseFormats(); }

  Impl(const Impl&) = delete;
  Impl& operator=(const Impl&) = delete;

  std::filesystem::path path;
  media::MediaSourceOpenOptions options;
  MediaSourceLimits limits;
  std::shared_ptr<const MediaSourceDescriptor> descriptor;
  std::shared_ptr<const MpegTsAssetContext> assetContext;
  std::unique_ptr<MpegTsCursor> videoCursor;
  std::unique_ptr<MpegTsCursor> audioCursor;
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
  bool audioProofStated{false};
  std::optional<MediaTime> audioProofCeiling;
  MediaCodec videoCodec{MediaCodec::Unknown};
  MediaCodec audioCodec{MediaCodec::Unknown};
  // Borrowed from the prepared asset, which owns it and outlives this source.
  // Non-null selects LOAS/LATM framing for the AAC frame walk.
  const media::mpegts::LatmStreamMuxConfig* latmConfig{nullptr};
  MediaTime audioDecodeStart{};
  std::int64_t audioFramesPerPacket{0};
  std::int32_t audioSampleRate{0};
  std::uint32_t audioChannels{0};
  // The exact frame ordinal of the NEXT audio access unit this generation will
  // publish. Seeded from the first staged PES timestamp and advanced by whole
  // access units thereafter; it is the only thing this source ever treats as
  // the audio timeline, and it never rounds after the seed.
  std::int64_t audioNextFrame{0};
  bool audioAnchored{false};

  // Reset-not-freed workspaces. `readNext` allocates only when a payload is
  // larger than everything before it in this generation.
  std::vector<std::byte> payloadWorkspace;
  MpegTsAudioFrameLayout audioLayout;

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
      const MpegTsCompressedSample& raw, bool video, std::string* error) {
    const std::optional<MediaTrackId> selected =
        video ? descriptor->selectedVideo : descriptor->selectedAudio;
    const MediaSampleKind kind = video ? MediaSampleKind::EncodedVideo
                                       : MediaSampleKind::EncodedAudio;
    if (!selected || raw.track != *selected || raw.kind != kind) {
      assignError(error, "mpeg-ts cursor emitted an unselected track");
      return std::nullopt;
    }
    if (media::findMediaTrack(*descriptor, *selected) == nullptr) {
      assignError(error, "mpeg-ts sample refers to an unknown track");
      return std::nullopt;
    }
    // The CONTAINER timestamp is always nonnegative -- the exported timeline is
    // rebased on the earliest first PTS across selected streams. The DERIVED
    // audio timeline is not: a lead-in codec's access unit 0 legitimately
    // presents before media time zero, exactly as an Opus track's does in
    // Matroska, and the window proof below is what bounds it.
    if (!raw.presentationTime.valid() || raw.presentationTime.value < 0) {
      assignError(error, "mpeg-ts sample has no exact nonnegative timing");
      return std::nullopt;
    }
    const std::size_t bytes = raw.payloadBytes;
    if (bytes == 0 ||
        (video && bytes > limits.maximumVideoSampleBytes) ||
        (!video && bytes > limits.maximumAudioSampleBytes)) {
      assignError(error, "mpeg-ts sample exceeds native memory bounds");
      return std::nullopt;
    }

    // The audio timeline is the source's own exact frame ordinal, never the
    // container's rounded 90 kHz stamp. The first unit of a generation seeds
    // the ordinal from that stamp; every later unit is checked against it and
    // published from the ordinal.
    MediaTime audioPresentation{};
    if (!video) {
      const auto pesFrame = nearestAudioFrame(
          raw.presentationTime, static_cast<std::uint32_t>(audioSampleRate));
      if (!pesFrame) {
        assignError(error, "mpeg-ts audio timestamp is not representable");
        return std::nullopt;
      }
      if (!audioAnchored) {
        audioAnchored = true;
        // The anchor is the PES timestamp MINUS the decoder lead-in, so that
        // once the converter has swallowed that lead-in its first published
        // frame lands exactly on the presentation floor. See
        // audioDecoderLeadInFrames.
        audioNextFrame = *pesFrame - audioDecoderLeadInFrames(audioCodec);
      } else {
        // Tolerance is one whole access unit. Anything larger is a dropped or
        // duplicated PES rather than muxer rounding, and continuing past it
        // would publish audio the converter's exact-contiguity check would
        // reject one sample later with a far less useful message.
        const std::int64_t drift = *pesFrame - audioDecoderLeadInFrames(audioCodec) -
                                   audioNextFrame;
        if (drift > audioFramesPerPacket || drift < -audioFramesPerPacket) {
          assignError(error,
                      "mpeg-ts audio access units are not contiguous on the "
                      "codec frame grid");
          return std::nullopt;
        }
      }
      const auto time = audioFrameTime(
          audioNextFrame, static_cast<std::uint32_t>(audioSampleRate));
      if (!time) {
        assignError(error, "mpeg-ts audio frame ordinal left the time domain");
        return std::nullopt;
      }
      audioPresentation = *time;
    }

    MpegTsSampleBuildInputs inputs;
    inputs.asset = assetContext->asset().get();
    inputs.cancellation = cancellation();
    inputs.format = video ? static_cast<CMFormatDescriptionRef>(videoFormat)
                          : static_cast<CMFormatDescriptionRef>(audioFormat);
    inputs.codec = video ? videoCodec : audioCodec;
    inputs.video = video;
    inputs.workspace = &payloadWorkspace;
    inputs.audioLayout = video ? nullptr : &audioLayout;
    inputs.audioSampleRate = static_cast<std::uint32_t>(audioSampleRate);
    inputs.audioChannels = audioChannels;
    inputs.audioFramesPerPacket =
        static_cast<std::uint32_t>(audioFramesPerPacket);
    // Non-null exactly when the selected audio stream is AAC in LOAS/LATM
    // framing. It is the config the DEMUXER proved at preparation, not one
    // rediscovered here, which is what lets a generation start on any LOAS
    // frame -- including the config-less one a seek almost always lands on.
    inputs.latmConfig = video ? nullptr : latmConfig;
    inputs.audioPresentationTime = audioPresentation;
    MpegTsScopedSampleBuffer owned;
    const MpegTsSampleBuildStatus built =
        buildMpegTsCompressedSampleBuffer(inputs, raw, &owned, error);
    if (built != MpegTsSampleBuildStatus::Built) {
      if (built == MpegTsSampleBuildStatus::Cancelled) {
        publishCancellation(generation);
        assignError(error, "mpeg-ts payload copy was cancelled");
      }
      return std::nullopt;
    }

    std::size_t sampleCount = 1;
    MediaTime duration = raw.duration;
    if (!video) {
      sampleCount = audioLayout.count;
      if (sampleCount == 0 || sampleCount > limits.maximumAudioSampleCount) {
        assignError(error, "mpeg-ts audio PES framed no admissible unit");
        return std::nullopt;
      }
      const auto extent = audioFrameTime(
          static_cast<std::int64_t>(audioLayout.decodedFrames),
          static_cast<std::uint32_t>(audioSampleRate));
      if (!extent) {
        assignError(error, "mpeg-ts audio extent is not representable");
        return std::nullopt;
      }
      duration = *extent;
    }

    if (!video && !audioProofStated) {
      audioProofStated = true;
      // Measured, never assumed: the attachment asserts the decoder has
      // already consumed the full priming window ahead of the first audible
      // frame. An unproved unit is left untouched on purpose so the converter
      // rejects the generation instead of publishing un-primed PCM.
      if (audioProofCeiling) {
        const auto order =
            media::compareMediaTime(audioPresentation, *audioProofCeiling);
        if (order && *order != MediaTimeOrder::Greater) {
          static_cast<void>(statedImmediatePlayoutFrame(owned.get()));
        }
      }
    }

    // The retained byte count is the CoreMedia BLOCK's, not the cursor's.
    //
    // For H.264 those two differ on purpose: the cursor reports Annex-B bytes
    // and the block holds the AVCC repack, which grows by one byte per
    // three-byte start code. For audio they differ too, because the ADTS
    // headers were stripped. The video consumer proves the lease against the
    // block with `CMBlockBufferGetDataLength(block) != payload.byteSize()`, so
    // reporting the cursor's number here is not a cosmetic error -- it rejects
    // every single sample.
    std::size_t retainedBytes = 0;
    if (CMBlockBufferRef block = CMSampleBufferGetDataBuffer(owned.get());
        block != nullptr) {
      retainedBytes = CMBlockBufferGetDataLength(block);
    }
    if (retainedBytes == 0 ||
        (video && retainedBytes > limits.maximumVideoSampleBytes) ||
        (!video && (retainedBytes > limits.maximumAudioSampleBytes ||
                    retainedBytes != audioLayout.outputBytes))) {
      assignError(error, "mpeg-ts CoreMedia block does not carry the unit");
      return std::nullopt;
    }
    auto storage = std::make_shared<MpegTsCoreMediaSampleStorage>(
        owned.release(), retainedBytes);
    MediaSample sample;
    sample.generation = generation;
    sample.track = *selected;
    sample.kind = kind;
    sample.presentationTime = video ? raw.presentationTime : audioPresentation;
    // Transport Stream carries a REAL decode timestamp on video. Publishing it
    // is what lets the merge below key on decode order without the synthetic
    // ordering lead the Matroska source has to invent.
    sample.decodeTime = video ? raw.decodeTime : MediaTime{};
    sample.duration = duration;
    sample.keyFrame = video ? raw.keyFrame : true;
    sample.discontinuity = false;
    sample.sampleCount = static_cast<std::uint32_t>(sampleCount);
    sample.payload = MediaPayloadLease(std::move(storage));
    if (video && requestedTarget &&
        seekMode == media::MediaSeekMode::Accurate) {
      const auto decodeOnly = mpegTsAccurateVideoDecodeOnly(
          raw.presentationTime, raw.duration, *requestedTarget, error);
      if (!decodeOnly) {
        return std::nullopt;
      }
      sample.decodeOnly = *decodeOnly;
    }
    if (!media::validateMediaSample(sample, *descriptor, limits, error)) {
      return std::nullopt;
    }
    if (!video) {
      audioNextFrame += static_cast<std::int64_t>(audioLayout.decodedFrames);
    }
    // THE MERGE KEY. Transport Stream states an explicit PES decode timestamp,
    // so the two lanes are ordered by the times the decoders will actually
    // consume them -- `dts.valid() ? dts : pts`, the AVFoundation shape.
    //
    // The Matroska source cannot do this and instead leads its video lane by a
    // synthetic 250 ms `kVideoMergeLeadNanoseconds`, because Matroska carries
    // no DTS and its cursor emits in storage (decode) order, so keying video on
    // its PRESENTATION time sorted every B-frame behind audio that had already
    // played past it. Copying that constant here would be the same defect in
    // the opposite direction: it would pull the video lane 250 ms ahead of a
    // decode order that is already correct, inflating the video read-ahead and
    // starving the audio lane for no reason at all. It is deliberately absent.
    const MediaTime orderTime = sample.decodeTime.valid()
                                    ? sample.decodeTime
                                    : sample.presentationTime;
    return StagedSample{*selected, orderTime, std::move(sample), retainedBytes};
  }

  [[nodiscard]] bool stage(bool video, bool admission, std::string* error) {
    const std::optional<MediaTrackId> selected =
        video ? descriptor->selectedVideo : descriptor->selectedAudio;
    MpegTsCursor* cursor = video ? videoCursor.get() : audioCursor.get();
    if (!selected) {
      (video ? videoTerminal : audioTerminal) = true;
      return true;
    }
    if (cursor == nullptr) {
      assignError(error, "selected mpeg-ts output has no cursor");
      return false;
    }
    const media::mpegts::MpegTsCursorReadResult result =
        cursor->readNext(cancellation());
    if (std::holds_alternative<MpegTsCursorCancelled>(result) || isCancelled()) {
      publishCancellation(generation);
      assignError(error, "mpeg-ts generation was cancelled");
      return false;
    }
    if (const auto* failed = std::get_if<MpegTsCursorFailure>(&result)) {
      if (error != nullptr) {
        *error = mpegTsDemuxErrorMessage(failed->message.empty()
                                             ? "mpeg-ts cursor read failed"
                                             : failed->message.c_str(),
                                         failed->error);
      }
      return false;
    }
    if (std::holds_alternative<MpegTsCursorEnd>(result)) {
      (video ? videoTerminal : audioTerminal) = true;
      if (admission) {
        assignError(error, "selected mpeg-ts output has no admission sample");
        return false;
      }
      return true;
    }
    auto head = makeHead(std::get<MpegTsCompressedSample>(result), video, error);
    if (!head) {
      return false;
    }
    if (admission && video) {
      // The plan always starts video at a random access point that a cold
      // decoder can begin from; restating it here keeps a malformed index from
      // admitting a generation that can never decode. A positive duration is
      // required because every downstream video consumer compares the sample's
      // exact interval against the timeline.
      if (!head->value.keyFrame || head->value.presentationTime.value < 0 ||
          !head->value.duration.valid() || head->value.duration.value <= 0) {
        assignError(error,
                    "first video sample is not a nonnegative positive-duration "
                    "sync access unit");
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

  [[nodiscard]] bool prepareAudioFormatFacts(std::string* error) {
    audioProofStated = false;
    audioProofCeiling.reset();
    audioDecodeStart = MediaTime{};
    audioFramesPerPacket = 0;
    audioSampleRate = 0;
    audioChannels = 0;
    audioNextFrame = 0;
    audioAnchored = false;
    audioCodec = MediaCodec::Unknown;
    latmConfig = nullptr;
    if (!descriptor->selectedAudio) {
      return true;
    }
    const MediaTrackDescriptor* track =
        media::findMediaTrack(*descriptor, *descriptor->selectedAudio);
    if (track == nullptr || !track->audio) {
      assignError(error, "selected mpeg-ts audio track has no format");
      return false;
    }
    const auto rate = exactAudioSampleRate(*track->audio);
    const auto framesPerPacket =
        static_cast<std::int64_t>(track->audio->framesPerPacket);
    if (!rate || framesPerPacket <= 0 ||
        framesPerPacket > kMaximumAudioFramesPerPacket ||
        track->audio->channels == 0) {
      assignError(error, "mpeg-ts audio has no exact integer packet grid");
      return false;
    }
    audioSampleRate = static_cast<std::int32_t>(*rate);
    audioFramesPerPacket = framesPerPacket;
    audioChannels = track->audio->channels;
    audioCodec = track->codec;
    // The asset owns this config and outlives every generation built from it,
    // so borrowing a pointer is safe; it is re-read on each generation rather
    // than cached across one, because a reopen may swap the asset.
    if (audioCodec == MediaCodec::Aac && assetContext != nullptr &&
        assetContext->asset() != nullptr) {
      latmConfig = assetContext->asset()->latmStreamMuxConfig();
    }
    return true;
  }

  // Derives the exact audio generation window from the first staged access
  // unit, then re-proves it against the neutral contract.
  //
  // This is where the TS source most visibly diverges from its Matroska
  // sibling: Matroska's plan states the window and the source proves the first
  // staged unit matches it, because Matroska's Cues make the first audio Block
  // of a generation knowable before it is read. A transport stream has no
  // index of its audio at all -- the audio cursor simply starts at the video
  // random access point's byte offset and reports whatever PES it finds first
  // -- so the window can only be stated AFTER that unit exists.
  [[nodiscard]] bool deriveAudioWindow(
      media::MediaAudioGenerationWindow& window, std::string* error) {
    window = media::MediaAudioGenerationWindow{};
    if (!descriptor->selectedAudio) {
      return true;
    }
    if (!audioHead || !audioAnchored) {
      assignError(error, "mpeg-ts audio generation staged no first unit");
      return false;
    }
    window.decodeStart = audioHead->value.presentationTime;
    audioDecodeStart = window.decodeStart;
    // The neutral contract fixes the presentation floor: in Accurate mode it
    // must be exactly the first audio frame boundary at or after the requested
    // target. Everything before it is decoded and trimmed.
    const MediaTime target = requestedTarget.value_or(MediaTime{0, 1});
    const auto floor = media::audioFrameAtOrAfter(
        target, static_cast<std::uint32_t>(audioSampleRate));
    if (!floor) {
      assignError(error, "mpeg-ts audio floor is off the exact frame grid");
      return false;
    }
    window.presentationStart = *floor;
    const auto decodeAgainstFloor =
        media::compareMediaTime(window.decodeStart, window.presentationStart);
    if (!decodeAgainstFloor ||
        *decodeAgainstFloor == MediaTimeOrder::Greater) {
      // The audio elementary stream begins after the position this generation
      // must make audible. Nothing this source can do recovers the missing
      // audio, so the generation is refused as an envelope verdict and the
      // session falls back rather than playing silent video.
      assignError(error,
                  "mpeg-ts audio begins after this generation's presentation "
                  "floor");
      return false;
    }
    // startsAtStreamOrigin is not a free choice: the neutral timeline check
    // requires it to be exactly `decodeStart <= 0`.
    const auto decodeAgainstOrigin =
        media::compareMediaTime(window.decodeStart, MediaTime{0, 1});
    if (!decodeAgainstOrigin) {
      assignError(error, "mpeg-ts audio decode start is not comparable");
      return false;
    }
    window.startsAtStreamOrigin =
        *decodeAgainstOrigin != MediaTimeOrder::Greater;
    if (!window.startsAtStreamOrigin) {
      const auto presentationFrame = media::exactAudioFrameIndex(
          window.presentationStart,
          static_cast<std::uint32_t>(audioSampleRate));
      if (!presentationFrame || *presentationFrame < 0) {
        assignError(error,
                    "mpeg-ts audio presentation start is off the frame grid");
        return false;
      }
      const std::int64_t ceilingFrame = std::max<std::int64_t>(
          *presentationFrame - kAudioPrimingAccessUnits * audioFramesPerPacket,
          0);
      audioProofCeiling = audioFrameTime(
          ceilingFrame, static_cast<std::uint32_t>(audioSampleRate));
      if (!audioProofCeiling) {
        assignError(error, "mpeg-ts audio priming ceiling is not exact");
        return false;
      }
      // The proof has to be stated on the FIRST unit, and it was already
      // staged above with no ceiling known. Re-prove it here against the
      // ceiling that now exists.
      const auto order = media::compareMediaTime(window.decodeStart,
                                                 *audioProofCeiling);
      if (!order || *order == MediaTimeOrder::Greater) {
        assignError(error,
                    "mpeg-ts audio does not begin a full priming window ahead "
                    "of its presentation floor");
        return false;
      }
      const auto borrowed =
          audioHead->value.payload
              .borrowNative<media::NativePayloadKind::CoreMediaSampleBuffer>();
      if (!borrowed ||
          !statedImmediatePlayoutFrame(static_cast<CMSampleBufferRef>(
              const_cast<void*>(borrowed->opaqueAddress())))) {
        assignError(error, "mpeg-ts audio playout proof could not be stated");
        return false;
      }
    }
    return true;
  }

  [[nodiscard]] GenerationStart begin(
      const std::filesystem::path& requestedPath,
      const media::MediaSourceOpenOptions& requestedOptions,
      MediaGeneration requestedGeneration,
      const std::optional<MediaTime>& target, media::MediaSeekMode mode,
      const std::shared_ptr<const MpegTsAssetContext>& existingContext) {
    GenerationStart started;
    generation = requestedGeneration;
    limits = media::clampMediaSourceLimits(requestedOptions.limits);
    requestedTarget = target;
    seekMode = mode;

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
    std::shared_ptr<const MpegTsAssetContext> context = existingContext;
    if (context == nullptr) {
      const media::mpegts::MpegTsPrepareOutcome prepared =
          media::mpegts::prepareMpegTsLocalFile(requestedPath, requestedOptions,
                                                cancellation());
      switch (prepared.status) {
      case MpegTsDemuxStatus::Ready:
        started.status = media::MediaSourceOpenStatus::Ready;
        break;
      case MpegTsDemuxStatus::Unsupported:
        started.status = media::MediaSourceOpenStatus::Unsupported;
        break;
      case MpegTsDemuxStatus::Cancelled:
        started.status = media::MediaSourceOpenStatus::Cancelled;
        break;
      case MpegTsDemuxStatus::Failed:
        started.status = media::MediaSourceOpenStatus::Failed;
        break;
      }
      if (prepared.status != MpegTsDemuxStatus::Ready ||
          prepared.asset == nullptr) {
        started.error = mpegTsDemuxErrorMessage(
            prepared.message.empty() ? "mpeg-ts preparation failed"
                                     : prepared.message.c_str(),
            prepared.error);
        if (prepared.status == MpegTsDemuxStatus::Ready) {
          started.status = media::MediaSourceOpenStatus::Failed;
        }
        withdrawFailedOperation();
        return started;
      }
      context = adoptPreparedMpegTsAssetContext(requestedPath, requestedOptions,
                                                prepared.asset);
      if (context == nullptr ||
          !context->matchesMainRequest(requestedPath, requestedOptions,
                                       prepared.asset->descriptor())) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error = "mpeg-ts asset context did not admit its own identity";
        withdrawFailedOperation();
        return started;
      }
    }

    const std::shared_ptr<const MpegTsPreparedAsset>& asset = context->asset();
    if (asset == nullptr || context->descriptor() == nullptr ||
        context->descriptor().get() != asset->descriptor().get()) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error = "mpeg-ts context changed its immutable asset identity";
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
      started.error = "mpeg-ts did not select every required track";
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

    const media::mpegts::MpegTsPlanOutcome planned = asset->planGeneration(
        requestedTarget.value_or(MediaTime{0, 1}), seekMode, cancellation());
    if (planned.status != MpegTsDemuxStatus::Ready || !planned.plan) {
      switch (planned.status) {
      case MpegTsDemuxStatus::Cancelled:
        started.status = media::MediaSourceOpenStatus::Cancelled;
        break;
      case MpegTsDemuxStatus::Unsupported:
        started.status = media::MediaSourceOpenStatus::Unsupported;
        break;
      default:
        started.status = media::MediaSourceOpenStatus::Failed;
        break;
      }
      started.error = mpegTsDemuxErrorMessage(
          planned.message.empty() ? "mpeg-ts generation planning failed"
                                  : planned.message.c_str(),
          planned.error);
      withdrawFailedOperation();
      return started;
    }
    const MpegTsGenerationPlan& plan = *planned.plan;

    // A plan may legitimately begin after its target in exactly one case: the
    // requested position lies at or before the FIRST video access unit, so the
    // scan has nothing earlier to land on. Real transport streams reach this
    // constantly -- ffmpeg's muxer emits audio ~23 ms ahead of video, and the
    // exported timeline is rebased on the earlier of the two, so a plain open
    // at zero starts its video a few milliseconds in. That first access unit is
    // the true video origin rather than a skipped seek target, exactly as it is
    // for a Matroska whose first Cue is not at zero or an MP4 carrying an edit
    // list. Any plan that starts late anywhere else really has skipped content
    // and stays rejected.
    const MediaTime videoOrigin = asset->videoOriginTime();
    const auto startAgainstTarget =
        requestedTarget
            ? media::compareMediaTime(plan.actualDecodeStart, *requestedTarget)
            : std::optional<MediaTimeOrder>{MediaTimeOrder::Less};
    bool clampedToVideoOrigin = false;
    if (startAgainstTarget && *startAgainstTarget == MediaTimeOrder::Greater) {
      clampedToVideoOrigin =
          videoOrigin.valid() &&
          media::compareMediaTime(plan.actualDecodeStart, videoOrigin) ==
              std::optional<MediaTimeOrder>{MediaTimeOrder::Equal};
    }
    if (!plan.actualDecodeStart.valid() || plan.actualDecodeStart.value < 0 ||
        !startAgainstTarget ||
        (*startAgainstTarget == MediaTimeOrder::Greater &&
         !clampedToVideoOrigin)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      started.error = "mpeg-ts plan starts after its own requested position";
      withdrawFailedOperation();
      return started;
    }
    // The same clamp applies to a generation with NO requested target: the
    // owner's timeline states target zero, and video that begins a few
    // milliseconds later must not be published as a late decode start.
    const bool clampedAtOrigin =
        !requestedTarget && videoOrigin.valid() &&
        media::compareMediaTime(plan.actualDecodeStart, videoOrigin) ==
            std::optional<MediaTimeOrder>{MediaTimeOrder::Equal} &&
        plan.actualDecodeStart.value > 0;

    descriptor = started.descriptor;
    assetContext = context;
    videoTerminal = !descriptor->selectedVideo;
    audioTerminal = !descriptor->selectedAudio;
    videoCodec = MediaCodec::Unknown;

    // One format description per generation, retained for every sample of it.
    // Rebuilding per sample would hand VideoToolbox a second, distinct
    // description object and force a decoder reconfiguration mid-stream.
    if (descriptor->selectedVideo) {
      const MediaTrackDescriptor* video =
          media::findMediaTrack(*descriptor, *descriptor->selectedVideo);
      videoFormat =
          video == nullptr ? nullptr : createMpegTsVideoFormatDescription(*video);
      if (videoFormat == nullptr) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error =
            "mpeg-ts video track has no admissible CoreMedia format description";
        withdrawFailedOperation();
        return started;
      }
      videoCodec = video->codec;
    }
    if (descriptor->selectedAudio) {
      const MediaTrackDescriptor* audio =
          media::findMediaTrack(*descriptor, *descriptor->selectedAudio);
      audioFormat = audio == nullptr ? nullptr
                                     : createAudioFormatDescription(*audio);
      if (audioFormat == nullptr) {
        started.status = media::MediaSourceOpenStatus::Unsupported;
        started.error =
            "mpeg-ts audio track has no admissible CoreMedia format description";
        withdrawFailedOperation();
        return started;
      }
    }
    if (!prepareAudioFormatFacts(&started.error)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }

    noteMpegTsAssetContextCursorCreationAttempt(*context);
    videoCursor = asset->makeVideoCursor(plan);
    if (videoCursor == nullptr) {
      started.status = media::MediaSourceOpenStatus::Failed;
      started.error = "mpeg-ts video cursor could not be created";
      withdrawFailedOperation();
      return started;
    }
    noteMpegTsAssetContextCursorStarted(*context);
    if (descriptor->selectedAudio) {
      noteMpegTsAssetContextCursorCreationAttempt(*context);
      audioCursor = asset->makeAudioCursor(plan);
      if (audioCursor == nullptr) {
        started.status = media::MediaSourceOpenStatus::Failed;
        started.error = "mpeg-ts audio cursor could not be created";
        withdrawFailedOperation();
        return started;
      }
      noteMpegTsAssetContextCursorStarted(*context);
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
    if (!deriveAudioWindow(started.audioWindow, &started.error)) {
      started.status = media::MediaSourceOpenStatus::Unsupported;
      withdrawFailedOperation();
      return started;
    }

    started.status = media::MediaSourceOpenStatus::Ready;
    started.actualDecodeStart =
        clampedToVideoOrigin && requestedTarget ? *requestedTarget
        : clampedAtOrigin                       ? MediaTime{0, 1}
                                                : plan.actualDecodeStart;
    started.error.clear();
    open = true;
    openSnapshot.store(true, std::memory_order_release);
    return started;
  }
};

MpegTsMediaSource::MpegTsMediaSource() : impl_(std::make_unique<Impl>()) {}

MpegTsMediaSource::~MpegTsMediaSource() { close(); }

bool MpegTsMediaSource::armOperation(MediaGeneration generation) noexcept {
  return impl_ != nullptr && impl_->arm(generation);
}

media::MediaSourceOpenOutcome MpegTsMediaSource::openLocalFile(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options, MediaGeneration generation) {
  media::MediaSourceOpenOutcome outcome;
  outcome.generation = generation;
  try {
    if (!impl_->consumeArm(generation)) {
      outcome.error = "mpeg-ts open generation was not armed";
      return outcome;
    }
    if (impl_->operationCancelled(generation)) {
      impl_->generation = generation;
      impl_->withdrawFailedOperation();
      outcome.status = media::MediaSourceOpenStatus::Cancelled;
      outcome.error = "mpeg-ts open was cancelled before entry";
      return outcome;
    }
    if (path.empty() || impl_->open ||
        !media::validateMediaSourceInitialPosition(options.initialPosition,
                                                   &outcome.error)) {
      if (outcome.error.empty()) {
        outcome.error = "invalid mpeg-ts open path or state";
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
    outcome.error = "mpeg-ts open raised an unknown exception";
  }
  return outcome;
}

media::MediaSourceSeekOutcome MpegTsMediaSource::seek(
    const media::MediaSourceSeekRequest& request) {
  media::MediaSourceSeekOutcome outcome;
  outcome.generation = request.generation;
  try {
    if (!impl_->consumeArm(request.generation)) {
      outcome.error = "mpeg-ts seek generation was not armed";
      return outcome;
    }
    if (impl_->operationCancelled(request.generation)) {
      impl_->generation = request.generation;
      impl_->withdrawFailedOperation();
      outcome.error = "mpeg-ts seek was cancelled before entry";
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
        outcome.error = "invalid mpeg-ts seek request";
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
    if (priorDescriptor == nullptr || priorContext == nullptr ||
        impl_->descriptor.get() != priorDescriptor.get() ||
        impl_->assetContext.get() != priorContext.get()) {
      outcome.error = "mpeg-ts prepared identity changed across seek";
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
    outcome.error = "mpeg-ts seek raised an unknown exception";
  }
  return outcome;
}

media::MediaSourceReadResult MpegTsMediaSource::readNext(
    MediaGeneration expectedGeneration) {
  try {
    if (!impl_->open || expectedGeneration != impl_->generation ||
        impl_->isCancelled()) {
      if (impl_->isCancelled()) {
        impl_->withdrawFailedOperation();
      }
      return media::MediaSourceCancelled{expectedGeneration};
    }

    if (impl_->failure.empty()) {
      std::string refillError;
      bool refilled = false;
      try {
        refilled = impl_->refillPendingHeads(&refillError);
      } catch (const std::exception& exception) {
        refillError = exception.what();
      } catch (...) {
        refillError = "mpeg-ts staging raised an unknown exception";
      }
      if (!refilled) {
        if (impl_->isCancelled()) {
          impl_->withdrawFailedOperation();
          return media::MediaSourceCancelled{expectedGeneration};
        }
        impl_->failure = refillError.empty()
                             ? "mpeg-ts could not stage the next sample"
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
        // Video wins ties. Both lanes are keyed on real decode time here, so a
        // tie means the two decoders want the data at the same instant and the
        // video path is the one with the longer pipeline ahead of it.
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
      (chosenVideo ? impl_->videoRefillPending : impl_->audioRefillPending) =
          true;
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
    return media::MediaSourceFailure{
        expectedGeneration, "mpeg-ts read raised an unknown exception"};
  }
}

void MpegTsMediaSource::requestCancel(MediaGeneration generation) noexcept {
  try {
    impl_->publishCancellation(generation);
  } catch (...) {
  }
}

void MpegTsMediaSource::close() noexcept {
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
    impl_->audioAnchored = false;
    impl_->audioNextFrame = 0;
  } catch (...) {
  }
}

media::MediaSourceStats MpegTsMediaSource::stats() const noexcept {
  media::MediaSourceStats result;
  result.open = impl_->openSnapshot.load(std::memory_order_acquire);
  result.operationGeneration =
      impl_->operationGeneration.load(std::memory_order_acquire);
  result.generation =
      impl_->generationHighWater.load(std::memory_order_acquire);
  result.cancelled = result.operationGeneration != 0 &&
                     impl_->cancelledGeneration.load(
                         std::memory_order_acquire) ==
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
  result.samplesEmitted = impl_->samplesEmitted.load(std::memory_order_relaxed);
  result.seeksAccepted = impl_->seeksAccepted.load(std::memory_order_relaxed);
  return result;
}

std::shared_ptr<const MpegTsAssetContext> MpegTsMediaSource::assetContext()
    const noexcept {
  return impl_ == nullptr ? nullptr : impl_->assetContext;
}

}  // namespace wam::macos
