// Bounds test for the multi-window resource envelope.
//
// WAM became a multi-window player: every open gets its own window, all of
// them playing at once. Every native per-session resource that used to be a
// strict one-per-process claim is now a bounded registry sized from ONE
// number, wam::macos::kMaximumConcurrentPlayerWindows. The individual
// registries are covered by their own suites (native_audio_output,
// native_video_consumer, native_audio_session); what this file pins is the
// arithmetic that ties them together, and the layer-presentation counter,
// which is a header-only inline with no suite of its own.
//
// The point of the runtime checks is that the derived constants are checked in
// a translation unit that is NOT the one that derives them, so a future edit
// that "just bumps" one of them fails here as well as at its own
// static_assert.

#include "platform/macos/native_concurrency_limits.hpp"
#include "platform/macos/native_layer_presentation_state.hpp"
#include "platform/macos/native_surface_budget.hpp"

#include <cstdio>
#include <cstdlib>

namespace {

int g_failures = 0;

void check(bool condition, const char *what) {
  if (!condition) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: %s\n", what);
  }
}

using namespace wam::macos;

// ---------------------------------------------------------------------------
// The cap itself, and the two ceilings it was chosen against.
// ---------------------------------------------------------------------------
void testWindowCap() {
  check(kMaximumConcurrentPlayerWindows == 16,
        "the window cap is 16 (raising it re-derives every bound below)");
  // The cap has to admit real multi-window use and still stay well inside the
  // ~1020-entry per-process IOSurface client ceiling that N sessions' worth of
  // VideoToolbox helpers consume.
  check(kMaximumConcurrentPlayerWindows >= 2,
        "the cap must admit at least two simultaneous windows");
  check(kMaximumConcurrentPlayerWindows <= 64,
        "the cap must stay far inside the per-process IOSurface client "
        "ceiling");
}

// ---------------------------------------------------------------------------
// Layer presentation: the bound is the per-window route-swap overlap times the
// window cap, and the counter must be able to reach it and come back to zero.
// ---------------------------------------------------------------------------
void testLayerPresentationBound() {
  check(kLayerPresentationsPerWindow == 2,
        "a window owns at most its steady-state output plus one route-swap "
        "overlap");
  check(kMaxConcurrentLayerPresentations ==
            kMaximumConcurrentPlayerWindows * kLayerPresentationsPerWindow,
        "the layer presentation bound is derived, never independently set");
  check(kMaxConcurrentLayerPresentations == 32,
        "the derived layer presentation bound is 32");

  check(!nativeLayerPresentationActive(),
        "the presentation counter starts at zero");
  for (int index = 0; index < kMaxConcurrentLayerPresentations; ++index) {
    retainNativeLayerPresentation();
    check(nativeLayerPresentationActive(),
          "any live retain keeps presentation active");
  }
  check(nativeLayerPresentationCounter().load() ==
            kMaxConcurrentLayerPresentations,
        "every window's worth of retains fits inside the bound");
  for (int index = 0; index < kMaxConcurrentLayerPresentations; ++index)
    releaseNativeLayerPresentation();
  check(!nativeLayerPresentationActive(),
        "a balanced release returns the counter to zero");
  check(nativeLayerPresentationCounter().load() == 0,
        "the counter is exactly zero after balanced release");
}

// ---------------------------------------------------------------------------
// Surface budget: the per-session complement is untouched, and the process
// pool is exactly the cap's worth of complements. N windows cost N budgets,
// and that is the statement being pinned here.
// ---------------------------------------------------------------------------
void testSurfaceBudgetSplit() {
  check(kNativeSurfaceBudgetMaximumSurfaces == 10,
        "the per-session surface complement is unchanged by multi-window");
  check(kNativeSurfaceBudgetProcessMaximumSurfaces ==
            kNativeSurfaceBudgetMaximumSurfaces *
                static_cast<std::uint64_t>(kMaximumConcurrentPlayerWindows),
        "the process surface pool is the cap's worth of per-session "
        "complements");
  check(kNativeSurfaceBudgetProcessMaximumBytes ==
            kNativeSurfaceBudgetMaximumBytes *
                static_cast<std::uint64_t>(kMaximumConcurrentPlayerWindows),
        "the process byte pool is the cap's worth of per-session budgets");
  // The byte pool must still cover a full complement of worst-case surfaces,
  // or the surface COUNT stops being the binding constraint and the route
  // starts refusing surfaces mid-playback instead of at admission.
  check(kNativeSurfaceBudgetProcessMaximumBytes >=
            kNativeSurfaceBudgetProcessMaximumSurfaces *
                kNativeSurfaceBudgetWorstCaseSurfaceBytes,
        "the process byte pool covers every window's full complement");
  // Two windows was the case that actually broke: one shared ten-surface pool
  // starved the second window to 4.6 fps. Pin the property that fixed it.
  check(kNativeSurfaceBudgetProcessMaximumSurfaces >=
            2ULL * kNativeSurfaceBudgetMaximumSurfaces,
        "two windows must each be able to hold a full complement at once");
}

} // namespace

int main() {
  testWindowCap();
  testLayerPresentationBound();
  testSurfaceBudgetSplit();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return EXIT_FAILURE;
  }
  std::printf("native concurrency limit checks passed\n");
  return EXIT_SUCCESS;
}
