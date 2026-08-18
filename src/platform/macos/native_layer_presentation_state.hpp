#pragma once

#include <atomic>
#include <cassert>
#include <cstdlib>
#include <cstring>

namespace wam::macos {

// The one authority on which presentation route this process runs. Two
// consumers with no dependency edge between them read it -- the native session
// factory (constructs the presenter) and main.cpp (tells QML whether to drop
// its opaque background) -- and they must be incapable of disagreeing: a
// factory on the layer route under QML that still paints opaque black shows no
// video, and the reverse shows no chrome.
//
// The layer route is the default as of 2026-08-18: it passed the full
// verification ladder (teardown, occlusion, chrome compositing, aspect snap,
// harness, contract test, seeks) and measured at QuickTime-parity CPU/energy
// with zero GPU work, where the scene-graph route pays ~4.4% GPU and retires
// 60-82% of post-seek frames late. WAM_PRESENTATION=scenegraph opts back to
// the GL route, so a field problem is a relaunch away from the previous
// behavior rather than a rebuild. Any other value (including junk) selects the
// default: an unrecognized opt-out is no opt-out.
[[nodiscard]] inline bool layerPresentationRouteSelected() noexcept {
  const char* value = std::getenv("WAM_PRESENTATION");
  if (value == nullptr) {
    return true;
  }
  return std::strcmp(value, "scenegraph") != 0;
}

// True exactly while at least one NativeLayerVideoOutput owns presentation.
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
// It is a process-global gate rather than a controller property because the
// producer (the native session factory, in the macOS backend library) and the
// consumer (PlayerController, in the Qt layer) are in libraries with no
// dependency edge between them, and adding one to carry a single flag would be
// a worse trade than a header-only inline. Header-only with a function-local
// static gives exactly one instance per binary and no link dependency.
//
// It is a COUNTER, not a bool, and that is load-bearing. A route swap that
// builds its replacement output before dropping the old one puts two presenting
// outputs briefly alive at once; with a bare bool the old one's teardown clears
// the flag while the new one is presenting, Qt silently resumes per-frame
// update() for the rest of the session, and the pivot's entire win is gone with
// nothing anywhere to notice. Retain/release makes the overlap correct by
// construction, and the asserted invariants below make an unbalanced call a
// debug-build failure instead of a silent performance regression.
//
// Every retain is released exactly once -- by closeProgress() or by the
// destructor, whichever runs first (NativeLayerVideoOutput::State owns that
// once-only latch) -- so a fallback from the layer route to libmpv restores the
// video item's per-frame update and the fallback keeps painting normally.
[[nodiscard]] inline std::atomic<int>&
nativeLayerPresentationCounter() noexcept {
  static std::atomic<int> counter{0};
  return counter;
}

// Bounded invariant: one presenting output per route, and at most two across
// the overlap of a route swap that builds before it drops. Anything above that
// is a missing release, not a legitimate topology.
inline constexpr int kMaxConcurrentLayerPresentations = 2;

[[nodiscard]] inline bool nativeLayerPresentationActive() noexcept {
  return nativeLayerPresentationCounter().load(std::memory_order_acquire) > 0;
}

inline void retainNativeLayerPresentation() noexcept {
  const int previous =
      nativeLayerPresentationCounter().fetch_add(1, std::memory_order_acq_rel);
  assert(previous >= 0 &&
         previous < kMaxConcurrentLayerPresentations &&
         "layer presentation retained beyond the route-swap overlap bound");
  (void)previous;
}

inline void releaseNativeLayerPresentation() noexcept {
  const int previous =
      nativeLayerPresentationCounter().fetch_sub(1, std::memory_order_acq_rel);
  assert(previous > 0 &&
         "layer presentation released without a matching retain");
  (void)previous;
}

}  // namespace wam::macos
