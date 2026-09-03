#pragma once

#include <memory>
#include <string>

namespace wam::macos {

// Owns the NSView that carries the AVSampleBufferDisplayLayer, installed as
// Qt's own NSView's immediately-lower SIBLING.
//
// This is option S1 from DESIGN.md section 2, chosen over reaching into Qt's
// private layer tree. On Qt 6 the QNSView is itself the window's content view,
// so the shared parent is the window's frame view:
//
//   NSWindow (full-size content view, transparent titlebar)
//   |__ frameView
//       |__ hostView   (layer-hosted, layer = AVSampleBufferDisplayLayer)  BELOW
//       |__ QNSView    (Qt Quick, OpenGL, clear background, alpha 8)       ABOVE
//       |__ titlebar container (AppKit traffic lights)                     ABOVE
//
// Sibling, not child: a subview always composites above its superview's own
// content, so hosting the layer *inside* Qt's view hides every pixel Qt draws.
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

// ---------------------------------------------------------------------------
// Vivid boost: SDR video presented into the display's extended dynamic range.
//
// A CoreImage exposure filter is attached to the display layer and the layer's
// EDR opt-in is turned on. That combination -- and NOT a retag of the surface,
// which was measured to do nothing at all -- is what makes the picture render
// above SDR white while the desktop around it stays where it was.
//
// The filter is why this costs no per-frame work in this process. CoreAnimation
// applies it during the compositing pass WindowServer was already running for
// this window, so the layer route's defining property -- WAM issues zero render
// passes for video -- survives the mode being on. The presentation path is
// otherwise untouched: no second surface, no extra IOSurface against
// NativeSurfaceBudget, no change to the decode or lease accounting.
//
// Correctness comes from CoreImage rather than from arithmetic here: it decodes
// the surface through its own tagged transfer function into linear light,
// multiplies there, and re-encodes into the extended-range compositing space.
// Measured against a ScreenCaptureKit half-float extended-linear readback, a
// boost of 1.0 is bit-identical to no filter at all and every boost above it is
// a uniform luminance scale with no hue or gamma shift.
//
// The boost is a MULTIPLE of SDR white: 1.0 (or anything below it) means off.
// The caller is responsible for clamping to the screen's live EDR headroom and
// for keeping HDR sources out -- boosting content that already occupies the
// extended range only clips its highlights.
//
// Main/GUI thread only.

// Sets the boost for every display layer this process has installed in
// `nsWindow` (an NSWindow*, bridged to void*), and remembers it ON that window
// so a layer created later -- opening a second file rebuilds the layer from
// scratch -- comes up already boosted. A null window, or a window with no
// display layer yet, records the value and does nothing else.
void setNativeLayerVividBoost(void* nsWindow, double boost) noexcept;

// The boost recorded for `nsWindow`, or 1.0 (off) if none is.
[[nodiscard]] double nativeLayerVividBoost(void* nsWindow) noexcept;

// The boost the display layer is ACTUALLY carrying, recovered from the layer's
// own attached filter and its EDR opt-in rather than from the recorded
// request -- so a verification round can state what the compositor was handed,
// not what somebody asked for. Returns 0.0 when the window has no display layer
// at all (the libmpv fallback route, or nothing open yet), and 1.0 for a layer
// with no boost on it.
[[nodiscard]] double nativeLayerAppliedVividBoost(void* nsWindow) noexcept;

// ---------------------------------------------------------------------------
// Presentation rotation.
//
// `displayLayer` is the AVSampleBufferDisplayLayer bridged to void* -- the
// same pointer NativeLayerHostView::displayLayer() returns and the same one
// NativeLayerVideoOutput already holds, which is why this is addressed by
// layer rather than by window: the output that needs to ask has the layer and
// nothing else.
//
// `degrees` is clockwise as a viewer sees it and must be 0, 90, 180 or 270 --
// the media source refuses every other transform long before a frame exists.
// Returns whether the rotation was applied; false only for a null or
// non-layer pointer or an unsupported angle.
//
// Applying it costs one CoreAnimation transform on a layer WindowServer is
// already compositing. There is no per-frame work, no second surface and no
// render pass in this process -- the route's defining property survives a
// rotated file, which is the whole reason rotation is done here rather than by
// turning pixels somewhere upstream.
//
// Callable from ANY thread, unlike the vivid-boost calls above: the consumer
// settles rotation on the session worker while configuring a generation. The
// value is recorded on the layer synchronously and the CoreAnimation update
// hops to the main queue when it has to.
[[nodiscard]] bool setNativeLayerPresentationRotation(void* displayLayer,
                                                      int degrees) noexcept;

// The rotation the layer is actually carrying, for verification. Returns 0 for
// an unrotated layer and for anything that is not a display layer.
[[nodiscard]] int nativeLayerPresentationRotation(void* displayLayer) noexcept;

}  // namespace wam::macos
