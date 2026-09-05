#include "platform/macos/mpegts_media_source.hpp"

#include "platform/macos/mpegts_sample_builder.hpp"
#include "platform/macos/native_custom_source_core.hpp"

#include "media/media_codec_facts.hpp"

#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <numeric>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

using media::MediaCodec;
using media::MediaSample;
using media::MediaSampleKind;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackId;
using media::mpegts::MpegTsCompressedSample;
using media::mpegts::MpegTsGenerationPlan;

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
// refused. AAC swallows nothing -- its encoder priming is real audio at the
// head of the elementary stream that the PES timestamps already describe.
[[nodiscard]] std::int64_t audioDecoderLeadInFrames(MediaCodec codec) noexcept {
  return media::mediaCodecFacts(codec).decoderLeadInFrames;
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

}  // namespace

// ---- Traits ---------------------------------------------------------------

MpegTsSourceTraits::PrepareOutcome MpegTsSourceTraits::prepare(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options,
    CancellationToken cancellation) noexcept {
  return media::mpegts::prepareMpegTsLocalFile(path, options, cancellation);
}

std::shared_ptr<const MpegTsAssetContext> MpegTsSourceTraits::adoptContext(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const PreparedAsset> asset) noexcept {
  return adoptPreparedMpegTsAssetContext(path, options, std::move(asset));
}

void MpegTsSourceTraits::noteCursorCreationAttempt(
    const MpegTsAssetContext& context) noexcept {
  noteMpegTsAssetContextCursorCreationAttempt(context);
}

void MpegTsSourceTraits::noteCursorStarted(
    const MpegTsAssetContext& context) noexcept {
  noteMpegTsAssetContextCursorStarted(context);
}

std::optional<MediaTime> MpegTsSourceTraits::videoOrigin(
    const PreparedAsset& asset) noexcept {
  const MediaTime origin = asset.videoOriginTime();
  if (!origin.valid()) {
    return std::nullopt;
  }
  return origin;
}

CMVideoFormatDescriptionRef MpegTsSourceTraits::createVideoFormatDescription(
    const MediaTrackDescriptor& track) noexcept {
  return createMpegTsVideoFormatDescription(track);
}

std::string MpegTsSourceTraits::demuxErrorMessage(const char* what,
                                                  DemuxError error) {
  return mpegTsDemuxErrorMessage(what, error);
}

MediaTime MpegTsSourceTraits::mergeOrderKey(const MediaSample& sample) noexcept {
  return sample.decodeTime.valid() ? sample.decodeTime
                                   : sample.presentationTime;
}

// ---- Impl -----------------------------------------------------------------

struct MpegTsMediaSource::Impl final
    : NativeCustomSourceCore<Impl, MpegTsSourceTraits> {
  using Base = NativeCustomSourceCore<Impl, MpegTsSourceTraits>;
  using typename Base::StagedSample;
  using Base::assetContext;
  using Base::audioDecodeStart;
  using Base::audioFormat;
  using Base::audioFramesPerPacket;
  using Base::audioHead;
  using Base::audioProofCeiling;
  using Base::audioSampleRate;
  using Base::cancellation;
  using Base::descriptor;
  using Base::generation;
  using Base::kAudioPrimingAccessUnits;
  using Base::kMaximumAudioFramesPerPacket;
  using Base::limits;
  using Base::publishCancellation;
  using Base::requestedTarget;
  using Base::resetAudioFacts;
  using Base::sealSample;
  using Base::stateAudioPlayoutProofOnce;
  using Base::videoFormat;

  MediaCodec videoCodec{MediaCodec::Unknown};
  MediaCodec audioCodec{MediaCodec::Unknown};
  // Borrowed from the prepared asset, which owns it and outlives this source.
  // Non-null selects LOAS/LATM framing for the AAC frame walk.
  const media::mpegts::LatmStreamMuxConfig* latmConfig{nullptr};
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
    // Matroska, and the window proof is what bounds it.
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
        // frame lands exactly on the presentation floor.
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
    ScopedSampleBuffer owned;
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
      stateAudioPlayoutProofOnce(audioPresentation, owned.get());
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
    auto storage = std::make_shared<CoreMediaSampleStorage>(owned.release(),
                                                            retainedBytes);
    MediaSample sample;
    sample.generation = generation;
    sample.track = *selected;
    sample.kind = kind;
    sample.presentationTime = video ? raw.presentationTime : audioPresentation;
    // Transport Stream carries a REAL decode timestamp on video. Publishing it
    // is what lets the merge key on decode order without the synthetic
    // ordering lead the Matroska source has to invent.
    sample.decodeTime = video ? raw.decodeTime : MediaTime{};
    sample.duration = duration;
    sample.keyFrame = video ? raw.keyFrame : true;
    sample.discontinuity = false;
    sample.sampleCount = static_cast<std::uint32_t>(sampleCount);
    sample.payload = media::MediaPayloadLease(std::move(storage));
    if (!sealSample(sample, video, error)) {
      return std::nullopt;
    }
    if (!video) {
      audioNextFrame += static_cast<std::int64_t>(audioLayout.decodedFrames);
    }
    return StagedSample{*selected, MediaTime{}, std::move(sample),
                        retainedBytes};
  }

  [[nodiscard]] bool prepareTrackFacts(const MpegTsGenerationPlan& plan,
                                       std::string* error) {
    static_cast<void>(plan);
    resetAudioFacts();
    audioChannels = 0;
    audioNextFrame = 0;
    audioAnchored = false;
    audioCodec = MediaCodec::Unknown;
    latmConfig = nullptr;
    videoCodec = MediaCodec::Unknown;
    if (descriptor->selectedVideo) {
      const MediaTrackDescriptor* video =
          media::findMediaTrack(*descriptor, *descriptor->selectedVideo);
      if (video != nullptr) {
        videoCodec = video->codec;
      }
    }
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
  [[nodiscard]] bool stateAudioWindow(const MpegTsGenerationPlan& plan,
                                      media::MediaAudioGenerationWindow& window,
                                      std::string* error) {
    static_cast<void>(plan);
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

  void resetContainerFacts() noexcept {
    audioAnchored = false;
    audioNextFrame = 0;
  }
};

MpegTsMediaSource::MpegTsMediaSource() : impl_(std::make_unique<Impl>()) {}

MpegTsMediaSource::~MpegTsMediaSource() { close(); }

bool MpegTsMediaSource::armOperation(
    media::MediaGeneration generation) noexcept {
  return impl_ != nullptr && impl_->arm(generation);
}

media::MediaSourceOpenOutcome MpegTsMediaSource::openLocalFile(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options,
    media::MediaGeneration generation) {
  return impl_->openLocalFile(path, options, generation);
}

media::MediaSourceSeekOutcome MpegTsMediaSource::seek(
    const media::MediaSourceSeekRequest& request) {
  return impl_->seek(request);
}

media::MediaSourceReadResult MpegTsMediaSource::readNext(
    media::MediaGeneration expectedGeneration) {
  return impl_->readNext(expectedGeneration);
}

void MpegTsMediaSource::requestCancel(
    media::MediaGeneration generation) noexcept {
  impl_->requestCancel(generation);
}

void MpegTsMediaSource::close() noexcept {
  if (impl_ != nullptr) {
    impl_->close();
  }
}

media::MediaSourceStats MpegTsMediaSource::stats() const noexcept {
  return impl_->stats();
}

std::shared_ptr<const MpegTsAssetContext> MpegTsMediaSource::assetContext()
    const noexcept {
  return impl_ == nullptr ? nullptr : impl_->assetContext;
}

}  // namespace wam::macos
