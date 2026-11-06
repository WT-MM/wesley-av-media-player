#include "native_media_session_system.hpp"

#include "media/media_container_routing.hpp"
#include "avfoundation_media_source.hpp"
#include "matroska_media_source.hpp"
#include "mpegts_media_source.hpp"
#include "native_audio_output.hpp"
#include "native_tracked_video_arbiter.hpp"
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
#include "routed_media_source.hpp"
#endif


#include <CoreAudio/HostTime.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <utility>

namespace wam::macos {
namespace {

constexpr std::uint64_t kMaximumExactDoubleInteger =
    std::uint64_t{1} << 53U;

struct NativeMediaSessionSystemLifetime final {
  std::shared_ptr<void> caller;
  // Presenter destruction precedes release of its view and wake dependencies.
  std::shared_ptr<void> presentation;
  std::shared_ptr<NativeMediaSessionWake> wake;
  std::shared_ptr<NativeTrackedVideoArbiter> videoArbiter;
};

// NativeAudioSession as the authority of a generation with audio.
class AudioSessionAuthority final : public SessionClockAuthority {
 public:
  explicit AudioSessionAuthority(NativeAudioSession& session) noexcept
      : session_(session) {}
  NativeAudioSessionProgress start() noexcept override {
    return session_.start();
  }
  NativeAudioSessionProgress setPaused(bool paused) noexcept override {
    return session_.setPaused(paused);
  }
  NativeAudioSessionProgress setGain(float gain) noexcept override {
    return session_.setGain(gain);
  }
  NativeAudioSessionProgress setMuted(bool muted) noexcept override {
    return session_.setMuted(muted);
  }
  NativeAudioSessionProgress setRate(NativePlaybackRate rate,
                                     bool preservePitch) noexcept override {
    return session_.setRate(rate, preservePitch);
  }
  NativeAudioSessionProgress stop() noexcept override {
    return session_.stop();
  }
  NativeMediaClockSnapshot visibleClock() const noexcept override {
    return session_.visibleClock();
  }
  media::MediaGeneration highestExposedGeneration() const noexcept override {
    return session_.facts().highestExposedGeneration;
  }
  bool suspendsForPause() const noexcept override { return true; }
  NativeAudioSessionProgress suspendForPause() noexcept override {
    return session_.suspendOutputForPause();
  }
  // renderStats() reads only relaxed callback-owned atomics; it is still
  // sampled on the worker so one pass publishes the whole set.
  std::optional<NativeAudioRenderStats> renderStats() const noexcept override {
    return session_.renderStats();
  }

 private:
  NativeAudioSession& session_;
};

class ConsumerVideoPort final : public SessionVideoPort {
 public:
  explicit ConsumerVideoPort(NativeVideoConsumer& consumer) noexcept
      : consumer_(consumer) {}
  NativeVideoConsumerArmProgress armFirstGeneration(
      media::MediaGeneration generation) noexcept override {
    return consumer_.armFirstGeneration(generation);
  }
  media::MediaGeneration highestExposedGeneration() noexcept override {
    const NativeVideoConsumerFacts facts = consumer_.facts();
    return std::max({facts.generation, facts.armedGeneration,
                     facts.output.generation, facts.decoder.generation});
  }
  std::uint64_t lastOutputEventSequence() noexcept override {
    return consumer_.facts().lastOutputEventSequence;
  }
  std::uint64_t nextDueHostTicks() noexcept override {
    return consumer_.nextDueHostTicks();
  }
  std::optional<NativeTrackedVideoEvent> takeOutputEvent() noexcept override {
    return consumer_.takeOutputEvent();
  }
  NativeVideoConsumerPreviewProgress quiesceForPreview(
      media::MediaGeneration generation) noexcept override {
    return consumer_.quiesceForPreview(generation);
  }
  // NativeVideoConsumer::facts() is an owner-serialized read, so this runs
  // only on the session worker, which copies the result into its atomic
  // metrics slots.
  std::optional<SessionVideoMetrics> metrics() noexcept override {
    const NativeVideoConsumerFacts facts = consumer_.facts();
    return SessionVideoMetrics{facts.output.drawnFrames, facts.firstDrawPts,
                               facts.discardedPrerollFrames,
                               facts.output.submittedFrames,
                               facts.output.supersededFrames,
                               facts.discardedLateFrames};
  }

 private:
  NativeVideoConsumer& consumer_;
};

// The production children: a source chosen by container routing, the audio
// session and the video consumer.
NativeMediaSessionGraph buildSystemGraph(
    void*, NativeMediaSessionGraphRequest request) noexcept {
  NativeMediaSessionGraph graph;
  try {
    // Container routing (media/media_container_routing.hpp). AVFoundation
    // cannot demux Matroska at all, and routing a transport stream to the
    // neutral demuxer moves files AVFoundation could also have opened: both
    // are safe because the selected source still applies its own exact codec
    // envelope and reports Unsupported for anything outside it, which keeps
    // the fallback path as the single rejection route.
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
    graph.source = createRoutedMediaSource();
#else
    switch (media::containerBackendForExtension(request.localPath)
                .value_or(media::MediaSourceBackendKind::AVFoundation)) {
    case media::MediaSourceBackendKind::Matroska:
      graph.source = std::make_unique<MatroskaMediaSource>();
      break;
    case media::MediaSourceBackendKind::MpegTs:
      graph.source = std::make_unique<MpegTsMediaSource>();
      break;
    case media::MediaSourceBackendKind::Libavformat:
    case media::MediaSourceBackendKind::AVFoundation:
      graph.source = std::make_unique<AVFoundationMediaSource>();
      break;
    }
#endif
    NativeMediaSessionDependencies& dependencies = request.dependencies;
    NativeAudioSessionDependencies audioDependencies;
    audioDependencies.externalLifetime = request.childLifetime;
    audioDependencies.hostClock = dependencies.hostClock;
    audioDependencies.outputCalls = dependencies.audioUnitCalls;
    audioDependencies.outputWake = dependencies.wake->audio();
    audioDependencies.converterBackend =
        std::move(dependencies.audioConverterBackend);
    auto audio = NativeAudioSession::create(request.reservedGeneration,
                                            std::move(audioDependencies));
    auto video = NativeVideoConsumer::create(
        request.childLifetime, request.videoClock, dependencies.videoOutput,
        dependencies.wake->video(), nullptr, dependencies.captionFeed);
    if (audio == nullptr || video == nullptr) {
      return {};
    }
    graph.audioPort = std::make_unique<AudioSessionAuthority>(*audio);
    graph.videoPort = std::make_unique<ConsumerVideoPort>(*video);
    graph.audio = std::move(audio);
    graph.video = std::move(video);
  } catch (...) {
    return {};
  }
  return graph;
}

void assignError(std::string* error, const char* message) noexcept {
  if (error == nullptr || !error->empty() || message == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

[[nodiscard]] bool validBinding(
    const NativeMediaSessionSourceBinding& binding) noexcept {
  try {
    return media::native_playback::valid(binding.sourceKey) &&
           !binding.localPath.empty() && binding.localPath.is_absolute();
  } catch (...) {
    return false;
  }
}

[[nodiscard]] std::uint64_t readSystemHostTicks(void*) noexcept {
  return static_cast<std::uint64_t>(AudioGetCurrentHostTime());
}

[[nodiscard]] bool systemHostTicksPerSecond(
    std::uint64_t* result) noexcept {
  if (result == nullptr) {
    return false;
  }
  const double frequency = AudioGetHostClockFrequency();
  if (!std::isfinite(frequency) || frequency <= 0.0 ||
      frequency > static_cast<double>(kMaximumExactDoubleInteger) ||
      std::trunc(frequency) != frequency) {
    return false;
  }
  *result = static_cast<std::uint64_t>(frequency);
  return true;
}

}  // namespace

std::unique_ptr<NativeMediaSession> createNativeMediaSessionSystem(
    NativeMediaSessionSourceBinding binding,
    std::shared_ptr<void> externalLifetime,
    NativeMediaSessionPresentationFactory factory,
    std::string* error,
    std::shared_ptr<media::captions::LiveCaptionFeed> captionFeed) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (!validBinding(binding)) {
    assignError(error,
                "system native media session requires an absolute local "
                "source binding");
    return {};
  }
  if (externalLifetime == nullptr) {
    assignError(error,
                "system native media session requires an external lifetime");
    return {};
  }
  if (factory.create == nullptr) {
    assignError(error,
                "system native media session requires a presentation factory");
    return {};
  }

  std::uint64_t ticksPerSecond = 0;
  if (!systemHostTicksPerSecond(&ticksPerSecond)) {
    assignError(error,
                "system host clock has no exact integral frequency");
    return {};
  }

  try {
    std::shared_ptr<NativeMediaSessionWake> wake =
        NativeMediaSessionWake::create();
    if (wake == nullptr) {
      assignError(error, "system native media wake allocation failed");
      return {};
    }

    NativeMediaSessionPresentation presentation = factory.create(
        factory.context, wake->trackedVideo(), error);
    if (!presentation.output) {
      assignError(error, "PresentationUnavailable");
      return {};
    }
    std::shared_ptr<NativeTrackedVideoArbiter> videoArbiter =
        NativeTrackedVideoArbiter::create(std::move(presentation.output), error);
    if (videoArbiter == nullptr) {
      assignError(error,
                  "system tracked native video arbiter creation failed");
      return {};
    }
    std::shared_ptr<NativeTrackedVideoOutput> videoOutput =
        videoArbiter->mainOutput();
    std::shared_ptr<NativeTrackedVideoPreviewPort> previewOutput =
        videoArbiter->previewPort();
    if (videoOutput == nullptr || previewOutput == nullptr) {
      assignError(error,
                  "system tracked native video arbiter has no output views");
      return {};
    }

    auto retained = std::make_shared<NativeMediaSessionSystemLifetime>(
        NativeMediaSessionSystemLifetime{std::move(externalLifetime),
                                         std::move(presentation.lifetime), wake,
                                         videoArbiter});

    NativeMediaSessionDependencies dependencies;
    dependencies.graphFactory = &buildSystemGraph;
    dependencies.externalLifetime = std::move(retained);
    dependencies.wake = std::move(wake);
    dependencies.videoOutput = std::move(videoOutput);
    dependencies.previewOutput = std::move(previewOutput);
    dependencies.hostClock = {
        &readSystemHostTicks, nullptr, ticksPerSecond};
    dependencies.audioUnitCalls = nativeAudioUnitSystemCallTable();
    dependencies.captionFeed = std::move(captionFeed);

    std::unique_ptr<NativeMediaSession> session = NativeMediaSession::create(
        std::move(binding), std::move(dependencies));
    if (session == nullptr) {
      assignError(error, "system native media session creation failed");
    }
    return session;
  } catch (...) {
    assignError(error, "system native media session construction threw");
    return {};
  }
}

}  // namespace wam::macos
