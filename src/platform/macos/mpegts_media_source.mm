#include "platform/macos/mpegts_media_source.hpp"

#if defined(WAM_ENABLE_AVFORMAT_STAGE) || defined(WAM_ENABLE_AVCODEC_STAGE)
#include "media/avcodec/aac_sbr_probe.hpp"
#define WAM_INSTALL_AAC_SBR_DETECTOR() ::wam::media::avcodec::installAacSbrDetector()
#else
#define WAM_INSTALL_AAC_SBR_DETECTOR() static_cast<void>(0)
#endif

#include "media/codec/aac.hpp"

#include "platform/macos/mpegts_sample_builder.hpp"
#include "platform/macos/native_custom_source_core.hpp"

#include "media/audio_codec_timing.hpp"
#include "media/media_codec_facts.hpp"

#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
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
using media::MediaSample;
using media::MediaSampleKind;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackId;
using media::mpegts::MpegTsCompressedSample;
using media::mpegts::MpegTsGenerationPlan;

// Frames Apple's decoder swallows at the head of a track before it emits its
// first PCM frame. The session proves the generation by checking that the
// converter's first published frame lands exactly on the presentation floor:
// the source states the decode start, the converter adds its lead-in, and the
// two meet.
//
// A PES header carries a presentation time and no delay field, and for AC-3
// and E-AC-3 that time is where ffmpeg and mpv present the decoder's very first
// output -- the frames Apple's decoder swallows are presented media. So the
// anchor stays on the PES stamp and the stream-origin generation declares the
// swallowed span as silence (media::firstDecodableAudioTime). Only a lead-in
// that is NOT presented media would move the anchor
// (media::unstatedDecoderLeadInShiftFrames). AAC swallows nothing.

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
  return media::mediaTimeFromTicks(frame, sampleRate);
}

}  // namespace

// ---- Traits ---------------------------------------------------------------

MpegTsSourceTraits::PrepareOutcome MpegTsSourceTraits::prepare(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options,
    CancellationToken cancellation) noexcept {
  return media::mpegts::prepareMpegTsLocalFile(path, options, cancellation);
}

std::optional<MediaTime> MpegTsSourceTraits::videoOrigin(
    const PreparedAsset& asset) noexcept {
  const MediaTime origin = asset.videoOriginTime();
  if (!origin.valid()) {
    return std::nullopt;
  }
  return origin;
}

MediaTime MpegTsSourceTraits::mergeOrderKey(const MediaSample& sample) noexcept {
  return sample.decodeTime.valid() ? sample.decodeTime
                                   : sample.presentationTime;
}

// ---- Impl -----------------------------------------------------------------

struct MpegTsMediaSource::Impl final
    : NativeCustomSourceCore<Impl, MpegTsSourceTraits> {

  MediaCodec videoCodec{MediaCodec::Unknown};
  MediaCodec audioCodec{MediaCodec::Unknown};
  // Borrowed from the prepared asset, which owns it and outlives this source.
  // Non-null selects LOAS/LATM framing for the AAC frame walk.
  const media::mpegts::LatmStreamMuxConfig* latmConfig{nullptr};
  std::uint32_t audioChannels{0};
  // The exact frame ordinal of the NEXT audio access unit this generation will
  // publish. Seeded from the first staged PES timestamp and advanced by whole
  // access units thereafter; it is the only thing this source ever treats as
  // the audio timeline, and it never rounds after the seed. Empty until the
  // first audio unit anchors it.
  std::optional<std::int64_t> audioNextFrame;

  [[nodiscard]] std::int64_t audioAnchorShiftFrames() const noexcept {
    return media::unstatedDecoderLeadInShiftFrames(
        audioCodec, static_cast<std::uint32_t>(audioFramesPerPacket));
  }

  // Reset-not-freed workspaces. `readNext` allocates only when a payload is
  // larger than everything before it in this generation.
  std::vector<std::byte> payloadWorkspace;
  std::vector<std::byte> audioWorkspace;
  MpegTsAudioFrameLayout audioLayout;
  media::codec::AacImplicitSbrCheck aacSbrCheck;
  bool aacSbrCheckArmed{false};
  // The leading bytes of an ADTS access unit that commenced in an earlier PES
  // and continues in the next one. At most one partial frame.
  std::vector<std::byte> audioCarry;

  // Gathers the next whole audio access units, joining PES payloads where an
  // ADTS frame straddles a PES boundary, and states their exact presentation
  // time on the source's frame ordinal.
  //
  // The audio timeline is the source's own exact frame ordinal, never the
  // container's rounded 90 kHz stamp. The first access unit of a generation
  // seeds the ordinal from its PES timestamp; every later PES timestamp is
  // checked against the ordinal of the access unit it describes and the units
  // are published from the ordinal. 13818-1 2.4.3.7 says which unit that is:
  // the FIRST one COMMENCING in the PES, which is not the first one completed
  // in it when the PES opens with the rest of a carried frame.
  [[nodiscard]] bool gatherAudio(const MpegTsCompressedSample& first,
                                 MediaTime& presentation,
                                 std::span<const std::byte>& units,
                                 std::string* error) {
    const bool adts = audioCodec == MediaCodec::Aac && latmConfig == nullptr;
    const auto rate = static_cast<std::uint32_t>(audioSampleRate);
    const auto unitFrames = static_cast<std::uint32_t>(audioFramesPerPacket);
    MpegTsCompressedSample raw = first;
    while (true) {
      const std::size_t carried = audioCarry.size();
      if (raw.payloadBytes == 0 ||
          raw.payloadBytes > limits.maximumAudioSampleBytes) {
        assignError(error, "mpeg-ts sample exceeds native memory bounds");
        return false;
      }
      audioWorkspace.resize(carried + raw.payloadBytes);
      std::copy(audioCarry.begin(), audioCarry.end(), audioWorkspace.begin());
      media::MediaRefusalClass copyError = media::MediaRefusalClass::None;
      if (!assetContext->asset()->copyAccessUnit(
              raw, std::span(audioWorkspace).subspan(carried), cancellation(),
              &copyError)) {
        if (copyError == media::MediaRefusalClass::Cancelled) {
          publishCancellation(generation);
          assignError(error, "mpeg-ts payload copy was cancelled");
        } else if (error != nullptr) {
          *error = media::refusalMessage("mpeg-ts payload gather failed",
                                         copyError);
        }
        return false;
      }
      std::span<const std::byte> joined(audioWorkspace);
      if (adts && !audioNextFrame && carried == 0) {
        // A generation may open on a PES that begins inside an access unit it
        // never saw start. That fragment is not audio this generation can
        // decode; the first unit commencing after it is the anchor.
        const std::optional<std::size_t> start = findAdtsAccessUnitStart(
            joined, rate, audioChannels, unitFrames, audioLayout);
        joined = joined.subspan(start.value_or(joined.size()));
      }
      std::size_t tail = joined.size();
      audioLayout.reset();
      if (!joined.empty() &&
          !layOutMpegTsAudioFrames(joined, audioCodec, latmConfig, rate,
                                   audioChannels, unitFrames, audioLayout,
                                   error, adts ? &tail : nullptr)) {
        return false;
      }
      // Ordinal, within `joined`, of the first unit commencing in THIS PES:
      // everything before byte `carried` began in an earlier one.
      std::optional<std::size_t> commencing;
      for (std::size_t i = 0; i < audioLayout.count; ++i) {
        if (audioLayout.sourceOffset[i] >= carried) {
          commencing = i;
          break;
        }
      }
      if (!commencing && tail < joined.size() && tail >= carried) {
        commencing = audioLayout.count;
      }
      if (commencing) {
        if (!raw.presentationTime.valid() || raw.presentationTime.value < 0) {
          assignError(error, "mpeg-ts sample has no exact nonnegative timing");
          return false;
        }
        const auto pesFrame = nearestAudioFrame(raw.presentationTime, rate);
        if (!pesFrame) {
          assignError(error, "mpeg-ts audio timestamp is not representable");
          return false;
        }
        // The anchor is the PES timestamp, less any lead-in that is not
        // presented media (see the note at the top of this file).
        const std::int64_t stated = *pesFrame - audioAnchorShiftFrames();
        if (!audioNextFrame) {
          audioNextFrame = stated;
        } else {
          // Tolerance is one whole access unit. Anything larger is a dropped
          // or duplicated PES rather than muxer rounding, and continuing past
          // it would publish audio the converter's exact-contiguity check
          // would reject one sample later with a far less useful message.
          const std::int64_t drift =
              stated - *audioNextFrame -
              static_cast<std::int64_t>(*commencing) * audioFramesPerPacket;
          if (drift > audioFramesPerPacket || drift < -audioFramesPerPacket) {
            assignError(error,
                        "mpeg-ts audio access units are not contiguous on the "
                        "codec frame grid");
            return false;
          }
        }
      }
      audioCarry.assign(joined.begin() + static_cast<std::ptrdiff_t>(tail),
                        joined.end());
      if (audioLayout.count > 0) {
        units = joined.first(tail);
        break;
      }
      // No access unit completed yet: the next PES must finish it.
      const media::mpegts::MpegTsCursorReadResult next =
          audioCursor->readNext(cancellation());
      if (std::holds_alternative<media::mpegts::MpegTsCursorCancelled>(next) ||
          isCancelled()) {
        publishCancellation(generation);
        assignError(error, "mpeg-ts generation was cancelled");
        return false;
      }
      if (const auto* failed =
              std::get_if<media::mpegts::MpegTsCursorFailure>(&next)) {
        if (error != nullptr) {
          *error = media::refusalMessage(failed->message.c_str(),
                                         failed->error);
        }
        return false;
      }
      const auto* following = std::get_if<MpegTsCompressedSample>(&next);
      if (following == nullptr) {
        assignError(error, "mpeg-ts audio ends inside an access unit");
        return false;
      }
      if (following->track != first.track || following->kind != first.kind) {
        assignError(error, "mpeg-ts cursor emitted an unselected track");
        return false;
      }
      raw = *following;
    }
    const auto time = audioFrameTime(*audioNextFrame, rate);
    if (!time) {
      assignError(error, "mpeg-ts audio frame ordinal left the time domain");
      return false;
    }
    presentation = *time;
    return true;
  }

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
    MediaTime audioPresentation{};
    std::span<const std::byte> audioUnits;
    if (video) {
      if (!raw.presentationTime.valid() || raw.presentationTime.value < 0) {
        assignError(error, "mpeg-ts sample has no exact nonnegative timing");
        return std::nullopt;
      }
      if (raw.payloadBytes == 0 ||
          raw.payloadBytes > limits.maximumVideoSampleBytes) {
        assignError(error, "mpeg-ts sample exceeds native memory bounds");
        return std::nullopt;
      }
    } else if (!gatherAudio(raw, audioPresentation, audioUnits, error)) {
      return std::nullopt;
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
    inputs.audioPayload = audioUnits;
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
    if (!video && audioCodec == MediaCodec::Aac && !aacSbrCheckArmed) {
      aacSbrCheckArmed = true;
      const auto config = media::codec::aacLcAudioSpecificConfig(
          static_cast<std::uint32_t>(audioSampleRate), audioChannels);
      aacSbrCheck.reset(config ? std::span<const std::byte>(*config)
                               : std::span<const std::byte>{},
                        static_cast<std::uint32_t>(audioSampleRate));
    }
    inputs.aacSbrCheck = video ? nullptr : &aacSbrCheck;
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
    auto storage = leaseSampleBuffer(std::move(owned), retainedBytes);
    MediaSample sample;
    sample.generation = generation;
    sample.track = *selected;
    sample.kind = kind;
    sample.presentationTime = video ? raw.presentationTime : audioPresentation;
    // Transport Stream carries a REAL decode timestamp on video; see
    // MpegTsSourceTraits::mergeOrderKey.
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
      *audioNextFrame += static_cast<std::int64_t>(audioLayout.decodedFrames);
    }
    return StagedSample{*selected, MediaTime{}, std::move(sample),
                        retainedBytes};
  }

  [[nodiscard]] bool prepareTrackFacts(const MpegTsGenerationPlan& plan,
                                       std::string* error) {
    static_cast<void>(plan);
    resetAudioFacts();
    audioChannels = 0;
    audioNextFrame.reset();
    aacSbrCheckArmed = false;
    audioCarry.clear();
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
    const auto rate = media::exactAudioSampleRate(track->audio->sampleRate);
    const auto framesPerPacket =
        static_cast<std::int64_t>(track->audio->framesPerPacket);
    if (!rate || framesPerPacket <= 0 ||
        framesPerPacket > media::kMaximumAudioFramesPerPacket ||
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
    const auto* audioHead = this->audioLane.head();
    if (!audioHead || !audioNextFrame) {
      assignError(error, "mpeg-ts audio generation staged no first unit");
      return false;
    }
    window.decodeStart =
        std::get<MediaSample>(audioHead->value).presentationTime;
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
    // The stream-origin generation can publish nothing before the decoder's
    // first output; the span up to it is declared silence.
    const auto decodeAgainstZero =
        media::compareMediaTime(window.decodeStart, MediaTime{0, 1});
    if (decodeAgainstZero && *decodeAgainstZero != MediaTimeOrder::Greater) {
      const auto decodable = media::firstDecodableAudioTime(
          window.decodeStart, audioCodec,
          static_cast<std::uint32_t>(audioFramesPerPacket),
          static_cast<std::uint32_t>(audioSampleRate));
      if (!decodable) {
        assignError(error, "mpeg-ts audio decoder lead-in is not exact");
        return false;
      }
      if (decodable->value > 0) {
        window.mediaStart = *decodable;
        if (media::compareMediaTime(*decodable, window.presentationStart) ==
            MediaTimeOrder::Greater) {
          window.presentationStart = *decodable;
        }
      }
    }
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
      const std::int64_t ceilingFrame = media::audioPrimingCeilingFrame(
          *presentationFrame, audioCodec, audioFramesPerPacket);
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
          std::get<MediaSample>(audioHead->value).payload
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
    audioNextFrame.reset();
    audioCarry.clear();
  }
};

MpegTsMediaSource::MpegTsMediaSource() : impl_(std::make_unique<Impl>()) {
  WAM_INSTALL_AAC_SBR_DETECTOR();
}

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
