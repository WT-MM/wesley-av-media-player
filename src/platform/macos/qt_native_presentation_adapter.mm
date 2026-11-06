#include "qt/native_media_session_adapter.hpp"
#include "platform/macos/native_layer_host_view.hpp"
#include "platform/macos/native_layer_presentation_state.hpp"
#include "platform/macos/native_layer_video_output.hpp"
#include "platform/macos/native_qt_gl_output.hpp"
#include <QQuickItem>
#include <QQuickWindow>

#include <cstdio>

namespace wam::macos {
namespace {
void assignError(std::string* error, const char* message) noexcept {
  if (error && error->empty()) { try { *error = message; } catch (...) {} }
}
// The layer is installed beneath the content view of the window that hosts
// the video item's scene.
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
    // The route decision lives in native_layer_presentation_state.hpp so this
    // factory and main.cpp's QML transparency flag cannot disagree. The GL
    // path stays a full implementation behind WAM_PRESENTATION=scenegraph.
    if (layerPresentationRouteSelected()) {
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
        // GL path is a full implementation and stays the fallback. It costs
        // GPU time and stops on occlusion, so the loss is logged.
        layerHost.reset();
        std::fprintf(stderr,
                     "WAM: layer presentation unavailable, using scene graph: "
                     "%s\n",
                     layerError.empty() ? "unknown" : layerError.c_str());
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
