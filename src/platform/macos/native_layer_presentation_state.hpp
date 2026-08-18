#pragma once

#include <atomic>

namespace wam::macos {

// True exactly while a NativeLayerVideoOutput owns presentation.
//
// This exists for one reason: on the layer route the video is composited by
// WindowServer from an AVSampleBufferDisplayLayer, so the Qt video item has
// nothing to paint, and the per-frame QQuickItem::update() that drives the GL
// route becomes pure cost. Phase B's gate measured that update() to be the
// *only* thing dirtying the scene graph once the chrome is hidden -- suppress
// it and Qt issues zero render passes over a full minute of playback, keep it
// and Qt issues ~30 per second. Leaving it in place on the layer route would
// pay the scene graph's render+swap cost for frames nobody draws, which is
// exactly the cost the pivot exists to remove.
//
// It is a process-global flag rather than a controller property because the
// producer (the native session factory, in the macOS backend library) and the
// consumer (PlayerController, in the Qt layer) are in libraries with no
// dependency edge between them, and adding one to carry a single bool would be
// a worse trade than a header-only inline. Header-only with a function-local
// static gives exactly one instance per binary and no link dependency.
//
// The flag is cleared on close/teardown, so a fallback from the layer route to
// libmpv restores the video item's per-frame update and the fallback keeps
// painting normally.
[[nodiscard]] inline std::atomic<bool>&
nativeLayerPresentationActiveFlag() noexcept {
  static std::atomic<bool> flag{false};
  return flag;
}

[[nodiscard]] inline bool nativeLayerPresentationActive() noexcept {
  return nativeLayerPresentationActiveFlag().load(std::memory_order_acquire);
}

inline void setNativeLayerPresentationActive(bool active) noexcept {
  nativeLayerPresentationActiveFlag().store(active, std::memory_order_release);
}

}  // namespace wam::macos
