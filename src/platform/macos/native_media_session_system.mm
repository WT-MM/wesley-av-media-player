#include "native_media_session_system.hpp"

#include "native_audio_output.hpp"
#include "native_layer_host_view.hpp"
#include "native_layer_video_output.hpp"
#include "native_qt_gl_output.hpp"
#include "native_tracked_video_arbiter.hpp"

#include <QQuickItem>
#include <QQuickWindow>

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
  std::shared_ptr<NativeMediaSessionWake> wake;
  std::shared_ptr<NativeTrackedVideoArbiter> videoArbiter;
  // Non-null only on the layer route. Outlives the output it feeds, so the
  // host view is removed from the window after the presenter has closed.
  std::shared_ptr<NativeLayerHostView> layerHost;
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

// Runtime presentation selection, mirroring the existing
// WAM_NATIVE_BENCHMARK_TELEMETRY env opt-in rather than inventing a mechanism.
// WAM_PRESENTATION=layer selects the AVSampleBufferDisplayLayer presenter,
// WAM_PRESENTATION=scenegraph selects the Qt OpenGL one. The GL path stays a
// full implementation and remains the default until the layer route has been
// verified on the full clip matrix, so a field problem is a relaunch away from
// the known-good path rather than a rebuild (DESIGN.md section 8).
enum class PresentationRoute : std::uint8_t { SceneGraph, Layer };

[[nodiscard]] PresentationRoute selectedPresentationRoute() noexcept {
  const char* value = std::getenv("WAM_PRESENTATION");
  if (value == nullptr) {
    return PresentationRoute::SceneGraph;
  }
  if (std::strcmp(value, "layer") == 0) {
    return PresentationRoute::Layer;
  }
  return PresentationRoute::SceneGraph;
}

// The Qt view handle the layer must be installed beneath. Derived from the
// video item's own window, so no change to main.cpp's window plumbing is
// needed: the item already lives in the window whose content view hosts the
// scene.
[[nodiscard]] void* qtViewHandleForItem(QtGlVideoItem* videoItem) noexcept {
  if (videoItem == nullptr) {
    return nullptr;
  }
  QQuickWindow* window = videoItem->window();
  if (window == nullptr) {
    return nullptr;
  }
  return reinterpret_cast<void*>(window->winId());
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
    QtGlVideoItem* videoItem,
    std::string* error) noexcept {
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
  if (videoItem == nullptr) {
    assignError(error,
                "system native media session requires a Qt video item");
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

    std::shared_ptr<NativeTrackedVideoOutput> trackedOutput;
    std::shared_ptr<NativeLayerHostView> layerHost;
    if (selectedPresentationRoute() == PresentationRoute::Layer) {
      // The layer presenter issues no in-process render pass, which is the
      // whole objective (DESIGN.md section 6). Everything downstream of this
      // pointer -- consumer, arbiter, session, owner, telemetry, commit-seek,
      // preview -- is typed on the interface and is unchanged by the choice.
      std::string layerError;
      layerHost = NativeLayerHostView::create(qtViewHandleForItem(videoItem),
                                              &layerError);
      if (layerHost != nullptr) {
        trackedOutput = NativeLayerVideoOutput::createTracked(
            layerHost->displayLayer(), wake->trackedVideo(), &layerError);
      }
      if (trackedOutput == nullptr) {
        // A layer route that cannot be installed is not a session failure: the
        // GL path is a full implementation and stays the fallback.
        layerHost.reset();
      }
    }
    if (trackedOutput == nullptr) {
      std::shared_ptr<NativeQtGlOutput> concreteOutput =
          NativeQtGlOutput::createTracked(videoItem, wake->trackedVideo(),
                                          error);
      if (concreteOutput == nullptr) {
        assignError(error,
                    "system tracked native video output creation failed");
        return {};
      }
      trackedOutput = concreteOutput;
    }
    std::shared_ptr<NativeTrackedVideoArbiter> videoArbiter =
        NativeTrackedVideoArbiter::create(std::move(trackedOutput), error);
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
        NativeMediaSessionSystemLifetime{std::move(externalLifetime), wake,
                                         videoArbiter, std::move(layerHost)});

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
