#pragma once

#include <memory>
#include <string>

namespace wam::macos {

// Owns the NSView that carries the AVSampleBufferDisplayLayer, installed
// directly beneath Qt's own NSView in the window's content view.
//
// This is option S1 from DESIGN.md section 2, chosen over reaching into Qt's
// private layer tree:
//
//   NSWindow (full-size content view, transparent titlebar)
//   |__ contentView
//       |__ hostView   (layer-hosted, layer = AVSampleBufferDisplayLayer)  BELOW
//       |__ QNSView    (Qt Quick, OpenGL, clear background, alpha 8)       ABOVE
//
// WindowServer composites the layer's IOSurface directly, so this process
// issues no render pass for video. Qt renders only chrome and is transparent
// wherever the chrome does not paint, which is what lets the video show
// through. Geometry tracks the window through the host view's autoresizing
// mask, and letterboxing happens inside the layer via
// AVLayerVideoGravityResizeAspect -- so the existing aspect/snap/actual-size
// geometry code in macos_window_chrome keeps working untouched: the layer is
// simply one more thing that follows the content view.
//
// All members must be called on the main/GUI thread.
class NativeLayerHostView final {
 public:
  // qtViewHandle is the NSView* behind QWindow::winId() for the Qt window that
  // should host the video, bridged to void*. Returns null with error set when
  // the handle is not a view, has no window, or the layer cannot be created.
  static std::shared_ptr<NativeLayerHostView> create(void* qtViewHandle,
                                                     std::string* error);

  NativeLayerHostView(const NativeLayerHostView&) = delete;
  NativeLayerHostView& operator=(const NativeLayerHostView&) = delete;
  ~NativeLayerHostView();

  // The AVSampleBufferDisplayLayer, bridged to void* at +0. Hand this to
  // NativeLayerVideoOutput::createTracked.
  [[nodiscard]] void* displayLayer() const noexcept;

  // Removes the host view from the window. Idempotent; called from the
  // destructor.
  void detach() noexcept;

 private:
  struct Impl;
  explicit NativeLayerHostView(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
};

}  // namespace wam::macos
