#include "qt/native_media_session_adapter.hpp"
#include "platform/macos/native_layer_host_view.hpp"
#include "platform/macos/native_layer_presentation_state.hpp"
#include "platform/macos/native_layer_video_output.hpp"
#include "platform/macos/native_qt_gl_output.hpp"
#include <QQuickItem>
#include <QQuickWindow>

namespace wam::macos {
namespace {
void assignError(std::string* error, const char* message) noexcept {
  if (error && error->empty()) { try { *error = message; } catch (...) {} }
}
// Runtime presentation selection. The decision itself lives in
// native_layer_presentation_state.hpp so this factory and main.cpp's QML
// transparency flag cannot disagree; see the rationale and the default there.
// The GL path stays a full implementation behind WAM_PRESENTATION=scenegraph.
enum class PresentationRoute : std::uint8_t { SceneGraph, Layer };

[[nodiscard]] PresentationRoute selectedPresentationRoute() noexcept {
  return layerPresentationRouteSelected() ? PresentationRoute::Layer
                                          : PresentationRoute::SceneGraph;
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


NativeMediaSessionPresentation createPresentation(
    void* context, NativeTrackedVideoOutputWakeSeam wake,
    std::string* error) noexcept {
  try {
    auto* videoItem = static_cast<QtGlVideoItem*>(context);
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
            layerHost->displayLayer(), wake, &layerError);
      }
      if (trackedOutput == nullptr) {
        // A layer route that cannot be installed is not a session failure: the
        // GL path is a full implementation and stays the fallback.
        layerHost.reset();
      }
    }
    if (trackedOutput == nullptr) {
      std::shared_ptr<NativeQtGlOutput> concreteOutput =
          NativeQtGlOutput::createTracked(videoItem, wake,
                                          error);
      if (concreteOutput == nullptr) {
        assignError(error,
                    "system tracked native video output creation failed");
        return {};
      }
      trackedOutput = concreteOutput;
    }
    return {std::move(trackedOutput), std::move(layerHost)};
  } catch (...) {
    assignError(error, "Qt presentation construction threw");
    return {};
  }
}
}
NativeMediaSessionPresentationFactory qtNativePresentationFactory(QtGlVideoItem* item) noexcept {
  return {item, &createPresentation};
}
}
