#if defined(WAM_ENABLE_AVFORMAT_STAGE)
#include "platform/macos/routed_media_source.hpp"
#endif
#include "platform/macos/avfoundation_media_source.hpp"
#include "platform/macos/matroska_media_source.hpp"
#include "platform/macos/native_audio_converter.hpp"
#include <cstdio>
#include <filesystem>
#include <memory>
#include <variant>

// This offline harness runs the production source, converter and ring on one
// bounded worker. Its output is interleaved stereo float32 at the media rate.
int main(int argc, char **argv) {
  if (argc < 3 || argc > 5)
    return 2;
  const std::string targetText=argc>=4?argv[3]:"0";
  const auto slash=targetText.find('/');
  const wam::media::MediaTime target{std::strtoll(targetText.c_str(),nullptr,10),
      slash==std::string::npos?1:static_cast<std::int32_t>(std::strtol(targetText.c_str()+slash+1,nullptr,10))};
  if (!target.valid() || target.value < 0)
    return 2;
  using namespace wam::media;
  using namespace wam::macos;
  const std::filesystem::path path(argv[1]);
  std::unique_ptr<MediaSource> source;
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
  source=createRoutedMediaSource();
#else
  if (path.extension() == ".webm" || path.extension() == ".mka" ||
      path.extension() == ".mkv")
    source = std::make_unique<MatroskaMediaSource>();
  else
    source = std::make_unique<AVFoundationMediaSource>();
#endif
  MediaSourceOpenOptions options;
  options.selection.requireAudio = true;
  options.initialPosition =
      MediaSourceInitialPosition{argc==5?MediaTime{0,1}:target, MediaSeekMode::Accurate};
  options.selection.requireVideo = false;
  if (!source->armOperation(1))
    return 1;
  const auto opened = source->openLocalFile(path, options, 1);
  if (opened.status != MediaSourceOpenStatus::Ready || !opened.descriptor ||
      !opened.descriptor->selectedAudio) {
    std::fprintf(stderr, "open: %s\n", opened.error.c_str());
    return 1;
  }
  const auto *track =
      findMediaTrack(*opened.descriptor, *opened.descriptor->selectedAudio);
  if (!track || !track->audio)
    return 1;
  NativePcmRing ring(1);
  NativeAudioConverter converter(ring);
  NativeAudioGenerationTimeline timeline;
  timeline.trimBeforeFloor = true;
  timeline.presentationFloor = argc == 5 ? *audioFrameAtOrAfter(target,static_cast<std::uint32_t>(track->audio->sampleRate)) : opened.audioWindow.presentationStart;
  timeline.startsAtStreamOrigin = opened.audioWindow.startsAtStreamOrigin;
  timeline.presentationCeiling = track->duration;
  timeline.trimAfterCeiling = true;
  std::string error;
  if (!converter.configure(*track, 1, timeline, &error)) {
    std::fprintf(stderr, "configure: %s\n", error.c_str());
    return 1;
  }
  FILE *out = std::fopen(argv[2], "wb");
  if (!out)
    return 1;
  std::uint64_t frames = 0;
  const auto drainRing = [&] {
    std::array<float, NativePcmRing::kSamplesPerSlab> pcm{};
    while (const auto available = ring.readableFrames(1).frames) {
      const auto n = std::min(available, NativePcmRing::kFramesPerSlab);
      const auto consumed = ring.consume(1, std::span(pcm).first(n * 2));
      if (consumed.pcmFrames != n || consumed.silentFrames != 0 ||
          std::fwrite(pcm.data(), sizeof(float) * 2, n, out) != n)
        return false;
      frames += n;
    }
    return true;
  };
  bool eos = false, drained = false, failed = false;
  for (std::size_t iterations = 0;
       iterations < 1'000'000 && !drained && !failed; ++iterations) {
    auto progress = converter.pump(&error);
    if (!drainRing()) {
      failed = true;
      break;
    }
    if (progress == NativeAudioPumpResult::Failed) {
      failed = true;
      break;
    }
    if (progress == NativeAudioPumpResult::Drained) {
      drained = true;
      break;
    }
    if (progress != NativeAudioPumpResult::NeedsInput)
      continue;
    if (eos) {
      failed = true;
      error = "input requested after EOS";
      break;
    }
    auto next = source->readNext(1);
    if (auto *sample = std::get_if<MediaSample>(&next)) {
      if (sample->track == track->id &&
          converter.submit(std::move(*sample), &error) !=
              NativeAudioSubmitResult::Accepted)
        failed = true;
    } else if (auto *end = std::get_if<MediaEndOfStream>(&next)) {
      if (end->track == track->id) {
        eos = true;
        const auto endResult = converter.endOfStream(1, &error);
        failed = endResult == NativeAudioPumpResult::Failed;
        drained = endResult == NativeAudioPumpResult::Drained;
        if (!drainRing())
          failed = true;
      }
    } else if (auto *failure = std::get_if<MediaSourceFailure>(&next)) {
      failed = true;
      error = failure->error;
    } else if (!std::holds_alternative<MediaDiscontinuity>(next)) {
      failed = true;
      error = "source exhausted or cancelled before audio EOS";
    }
  }
  const auto stats = converter.stats();
  const auto targetFrame=*exactAudioFrameIndex(*audioFrameAtOrAfter(target,static_cast<std::uint32_t>(track->audio->sampleRate)),static_cast<std::uint32_t>(track->audio->sampleRate));
  const auto expected = static_cast<__int128>(track->duration.value) *
                        static_cast<std::uint32_t>(track->audio->sampleRate);
  const bool exact =
      track->duration.valid() && expected % track->duration.timescale == 0 &&
      expected / track->duration.timescale -
              targetFrame ==
          frames;
  std::fprintf(stderr,
               "track=%u rate=%.0f frames=%llu first=%lld decoded=%llu "
               "trim=%llu exact=%d drained=%d error=%s\n",
               track->id, track->audio->sampleRate, frames,
               stats.firstPublishedFrame, stats.decodedPcmFrames,
               stats.discardedTrimFrames, exact, drained, error.c_str());
  std::fclose(out);
  converter.close();
  source->close();
  return !failed && drained && exact && stats.firstPublishedFrameKnown &&
                 stats.firstPublishedFrame ==
                     targetFrame
             ? 0
             : 1;
}
