#include "platform/macos/matroska_media_source.hpp"

#include "platform/macos/matroska_sample_builder.hpp"
#include "platform/macos/native_custom_source_core.hpp"

#import <CoreMedia/CoreMedia.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>

namespace wam::macos {
namespace {

using media::MediaSample;
using media::MediaSampleKind;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackId;
using media::matroska::MatroskaCompressedSample;
using media::matroska::MatroskaGenerationPlan;

constexpr std::size_t kMaximumLaceFrames{
    media::matroska::ParseOptions::kHardMaximumLaceFrames};

// Exact: the lead converted into the presentation timestamp's own timescale,
// rounded UP so the key never lands short of the reorder window, computed in
// 128 bits so the intermediate cannot overflow (a timescale is at most
// INT32_MAX, so the product is at most 2.5e8 x 2.1e9 = 5.4e17, and the quotient
// at most 5.4e8 ticks).
[[nodiscard]] constexpr MediaTime videoMergeOrderKey(
    MediaTime presentation) noexcept {
  if (!presentation.valid()) {
    return presentation;
  }
  const __int128 ticks =
      (static_cast<__int128>(
           MatroskaSourceTraits::kVideoMergeLeadNanoseconds) *
           static_cast<__int128>(presentation.timescale) +
       999'999'999) /
      1'000'000'000;
  return MediaTime{presentation.value - static_cast<std::int64_t>(ticks),
                   presentation.timescale};
}

}  // namespace

// ---- Traits ---------------------------------------------------------------

MatroskaSourceTraits::PrepareOutcome MatroskaSourceTraits::prepare(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options,
    CancellationToken cancellation) noexcept {
  return media::matroska::prepareMatroskaLocalFile(path, options,
                                                   cancellation);
}

std::shared_ptr<const MatroskaAssetContext> MatroskaSourceTraits::adoptContext(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options,
    std::shared_ptr<const PreparedAsset> asset) noexcept {
  return adoptPreparedMatroskaAssetContext(path, options, std::move(asset));
}

void MatroskaSourceTraits::noteCursorCreationAttempt(
    const MatroskaAssetContext& context) noexcept {
  noteMatroskaAssetContextCursorCreationAttempt(context);
}

void MatroskaSourceTraits::noteCursorStarted(
    const MatroskaAssetContext& context) noexcept {
  noteMatroskaAssetContextCursorStarted(context);
}

std::optional<MediaTime> MatroskaSourceTraits::videoOrigin(
    const PreparedAsset& asset) noexcept {
  const auto cues = asset.cues();
  if (cues.empty()) {
    return std::nullopt;
  }
  return matroskaTickTime(
      static_cast<std::int64_t>(cues.front().timestampTick),
      asset.timestampScaleNanoseconds());
}

CMVideoFormatDescriptionRef MatroskaSourceTraits::createVideoFormatDescription(
    const MediaTrackDescriptor& track) noexcept {
  return createMatroskaVideoFormatDescription(track);
}

std::string MatroskaSourceTraits::demuxErrorMessage(const char* what,
                                                    DemuxError error) {
  return matroskaDemuxErrorMessage(what, error);
}

MediaTime MatroskaSourceTraits::mergeOrderKey(
    const MediaSample& sample) noexcept {
  return sample.kind == MediaSampleKind::EncodedVideo
             ? videoMergeOrderKey(sample.presentationTime)
             : sample.presentationTime;
}

// ---- Impl -----------------------------------------------------------------

struct MatroskaMediaSource::Impl final
    : NativeCustomSourceCore<Impl, MatroskaSourceTraits> {
  using Base = NativeCustomSourceCore<Impl, MatroskaSourceTraits>;
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
  using Base::resetAudioFacts;
  using Base::sealSample;
  using Base::stateAudioPlayoutProofOnce;
  using Base::videoFormat;

  [[nodiscard]] std::optional<StagedSample> makeHead(
      const MatroskaCompressedSample& raw, bool video, std::string* error) {
    const std::optional<MediaTrackId> selected =
        video ? descriptor->selectedVideo : descriptor->selectedAudio;
    const MediaSampleKind kind = video ? MediaSampleKind::EncodedVideo
                                       : MediaSampleKind::EncodedAudio;
    if (!selected || raw.track != *selected || raw.kind != kind) {
      assignError(error, "matroska cursor emitted an unselected track");
      return std::nullopt;
    }
    if (media::findMediaTrack(*descriptor, *selected) == nullptr) {
      assignError(error, "matroska sample refers to an unknown track");
      return std::nullopt;
    }
    // Video timing is always nonnegative. Audio is not: Matroska stores an
    // audio Block's timestamp on the codec grid and states CodecDelay
    // separately, so the first access unit of an Opus track legitimately
    // presents before media time zero. The demuxer bounds that lead-in at
    // admission (the pre-skip ceiling) and the window's decodeStart names it
    // exactly, so the negative window is proved rather than tolerated: it must
    // be exactly the planned decode start, which the check below enforces for
    // the first staged unit and ordinal continuity enforces thereafter.
    const bool negativeStartAllowed =
        !video && audioDecodeStart.valid() && audioDecodeStart.value < 0;
    if (!raw.presentationTime.valid() ||
        (raw.presentationTime.value < 0 && !negativeStartAllowed) ||
        (raw.duration.valid() && raw.duration.value < 0)) {
      assignError(error, "matroska sample has no exact nonnegative timing");
      return std::nullopt;
    }
    if (raw.presentationTime.value < 0 &&
        media::compareMediaTime(raw.presentationTime, audioDecodeStart) !=
            MediaTimeOrder::Equal) {
      assignError(error,
                  "matroska audio access unit precedes its planned window");
      return std::nullopt;
    }
    // The demuxer never invents a decode timestamp; a cursor that produced one
    // would mean this source is reading a container it does not understand.
    if (raw.decodeTime.valid()) {
      assignError(error, "matroska sample fabricated a decode timestamp");
      return std::nullopt;
    }
    const std::size_t bytes = raw.aggregateBytes;
    const std::size_t frameCount = raw.frameCount;
    if (bytes == 0 || frameCount == 0 ||
        (video && (frameCount != 1 || bytes > limits.maximumVideoSampleBytes)) ||
        (!video && (frameCount > limits.maximumAudioSampleCount ||
                    frameCount > kMaximumLaceFrames ||
                    bytes > limits.maximumAudioSampleBytes))) {
      assignError(error, "matroska sample exceeds native memory bounds");
      return std::nullopt;
    }

    MatroskaSampleBuildInputs inputs;
    inputs.asset = assetContext->asset().get();
    inputs.cancellation = cancellation();
    inputs.format = video ? static_cast<CMFormatDescriptionRef>(videoFormat)
                          : static_cast<CMFormatDescriptionRef>(audioFormat);
    inputs.video = video;
    inputs.audioFramesPerPacket = audioFramesPerPacket;
    inputs.audioSampleRate = audioSampleRate;
    ScopedSampleBuffer owned;
    const MatroskaSampleBuildStatus built =
        buildMatroskaCompressedSampleBuffer(inputs, raw, &owned, error);
    if (built != MatroskaSampleBuildStatus::Built) {
      if (built == MatroskaSampleBuildStatus::Cancelled) {
        publishCancellation(generation);
        assignError(error, "matroska payload copy was cancelled");
      }
      return std::nullopt;
    }
    if (!video) {
      stateAudioPlayoutProofOnce(raw.presentationTime, owned.get());
    }

    const std::size_t sampleCount = video ? 1 : frameCount;
    auto storage =
        std::make_shared<CoreMediaSampleStorage>(owned.release(), bytes);
    MediaSample sample;
    sample.generation = generation;
    sample.track = *selected;
    sample.kind = kind;
    sample.presentationTime = raw.presentationTime;
    // Left invalid on purpose. Fabricating a decode stamp here would be the
    // one lie that makes every downstream timeline check meaningless.
    sample.decodeTime = MediaTime{};
    sample.duration = raw.duration;
    sample.keyFrame = raw.keyFrame;
    sample.sampleCount = static_cast<std::uint32_t>(sampleCount);
    sample.payload = media::MediaPayloadLease(std::move(storage));
    if (!sealSample(sample, video, error)) {
      return std::nullopt;
    }
    return StagedSample{*selected, MediaTime{}, std::move(sample), bytes};
  }

  [[nodiscard]] bool prepareTrackFacts(const MatroskaGenerationPlan& plan,
                                       std::string* error) {
    resetAudioFacts();
    if (!descriptor->selectedAudio) {
      return true;
    }
    const MediaTrackDescriptor* track =
        media::findMediaTrack(*descriptor, *descriptor->selectedAudio);
    if (track == nullptr || !track->audio) {
      assignError(error, "selected matroska audio track has no format");
      return false;
    }
    const auto rate = exactAudioSampleRate(*track->audio);
    const auto framesPerPacket =
        static_cast<std::int64_t>(track->audio->framesPerPacket);
    if (!rate || framesPerPacket <= 0 ||
        framesPerPacket > kMaximumAudioFramesPerPacket) {
      assignError(error, "matroska audio has no exact integer packet grid");
      return false;
    }
    audioSampleRate = static_cast<std::int32_t>(*rate);
    audioFramesPerPacket = framesPerPacket;
    audioDecodeStart = plan.audioWindow.decodeStart;
    if (!audioDecodeStart.valid() ||
        !plan.audioWindow.presentationStart.valid()) {
      assignError(error, "matroska plan produced no exact audio window");
      return false;
    }
    if (plan.audioWindow.startsAtStreamOrigin) {
      // A generation that begins at the stream origin needs no proof: there is
      // no earlier audio the decoder could have been missing.
      return true;
    }
    const auto presentationFrame = media::exactAudioFrameIndex(
        plan.audioWindow.presentationStart, *rate);
    if (!presentationFrame || *presentationFrame < 0) {
      assignError(error,
                  "matroska audio presentation start is off the frame grid");
      return false;
    }
    const std::int64_t ceilingFrame = std::max<std::int64_t>(
        *presentationFrame - kAudioPrimingAccessUnits * framesPerPacket, 0);
    audioProofCeiling = MediaTime{ceilingFrame, audioSampleRate};
    return true;
  }

  // The plan states the window, because Matroska's Cues make the first audio
  // Block of a generation knowable before it is read. The window is then
  // proved against the bytes rather than trusted: a window that disagrees with
  // the first staged access unit would make every converter trim decision
  // wrong by a whole access unit.
  [[nodiscard]] bool stateAudioWindow(const MatroskaGenerationPlan& plan,
                                      media::MediaAudioGenerationWindow& window,
                                      std::string* error) const {
    window = media::MediaAudioGenerationWindow{};
    if (!descriptor->selectedAudio) {
      return true;
    }
    if (!audioHead || !audioDecodeStart.valid() ||
        audioHead->value.presentationTime != audioDecodeStart) {
      assignError(error,
                  "first staged audio access unit does not begin at the "
                  "planned audio window decode start");
      return false;
    }
    window = plan.audioWindow;
    return true;
  }
};

MatroskaMediaSource::MatroskaMediaSource()
    : impl_(std::make_unique<Impl>()) {}

MatroskaMediaSource::~MatroskaMediaSource() { close(); }

bool MatroskaMediaSource::armOperation(
    media::MediaGeneration generation) noexcept {
  return impl_ != nullptr && impl_->arm(generation);
}

media::MediaSourceOpenOutcome MatroskaMediaSource::openLocalFile(
    const std::filesystem::path& path,
    const media::MediaSourceOpenOptions& options,
    media::MediaGeneration generation) {
  return impl_->openLocalFile(path, options, generation);
}

media::MediaSourceSeekOutcome MatroskaMediaSource::seek(
    const media::MediaSourceSeekRequest& request) {
  return impl_->seek(request);
}

media::MediaSourceReadResult MatroskaMediaSource::readNext(
    media::MediaGeneration expectedGeneration) {
  return impl_->readNext(expectedGeneration);
}

void MatroskaMediaSource::requestCancel(
    media::MediaGeneration generation) noexcept {
  impl_->requestCancel(generation);
}

void MatroskaMediaSource::close() noexcept {
  if (impl_ != nullptr) {
    impl_->close();
  }
}

media::MediaSourceStats MatroskaMediaSource::stats() const noexcept {
  return impl_->stats();
}

std::shared_ptr<const MatroskaAssetContext>
MatroskaMediaSource::assetContext() const noexcept {
  return impl_ == nullptr ? nullptr : impl_->assetContext;
}

}  // namespace wam::macos
