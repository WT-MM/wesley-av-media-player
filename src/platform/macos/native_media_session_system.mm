#include "native_media_session_system.hpp"

#include "native_audio_output.hpp"
#include "native_tracked_video_arbiter.hpp"


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
  const auto integral = static_cast<std::uint64_t>(frequency);
  if (integral == 0 || integral > kMaximumExactDoubleInteger ||
      static_cast<double>(integral) != frequency) {
    return false;
  }
  *result = integral;
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
    dependencies.externalLifetime = std::move(retained);
    dependencies.wake = std::move(wake);
    dependencies.videoOutput = std::move(videoOutput);
    dependencies.previewOutput = std::move(previewOutput);
    dependencies.hostClock = {
        &readSystemHostTicks, nullptr, ticksPerSecond};
    dependencies.audioUnitCalls = nativeAudioUnitSystemCallTable();
    // A null injection is the existing production selector: NativeAudioConverter
    // constructs its private CoreAudioConverterBackend lazily on the session
    // worker. The factory deliberately does not duplicate that backend.
    dependencies.audioConverterBackend.reset();
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
