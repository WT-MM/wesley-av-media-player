#pragma once

namespace wam::macos {

// Process-wide cap on simultaneously open player windows, and therefore on
// every per-session native resource this process can hold at once.
//
// WAM became a multi-window player in 2026-08 (the QuickTime model: every open
// gets its own window, all of them playing at the same time). Before that, a
// handful of native chokepoints -- the audio output's AudioUnit callback
// bridge, the audio session, the video consumer graph, the layer-presentation
// gate -- were each written as a strict ONE-PER-PROCESS claim, because one
// window could only ever want one of each. Those claims are now bounded
// registries of exactly this many slots instead, which keeps every property
// the single claim had (a fixed, statically sized resource envelope; no
// unbounded leak on a quarantined teardown; a hard refusal rather than an
// overrun when the envelope is full) while admitting N windows.
//
// This header exists so that cap is stated ONCE. Every derived bound --
// kMaxConcurrentLayerPresentations, the audio-output slot table, the audio
// session and video consumer quarantine tables -- is computed from it and
// static_asserted, never bumped independently.
//
// 16 is chosen against the real ceilings, not as a round number:
//   * each native session holds its own decoded-surface working set, so N
//     windows cost N budgets -- a real, bounded, user-chosen memory cost;
//   * each session spins up VideoToolbox helper clients against the ~1020
//     entry per-process IOSurface client ceiling, which 16 sessions sit
//     comfortably inside and ~64 would not;
//   * nobody arranges 16 simultaneously playing videos by accident, so the cap
//     reads as a guard rail rather than a product limit.
//
// wam::qt::kMaximumPlayerWindows (src/qt/window_manager.hpp) is static_asserted
// equal to this in window_manager.cpp, so the window factory and the native
// resource envelope cannot drift apart.
inline constexpr int kMaximumConcurrentPlayerWindows = 16;

}  // namespace wam::macos
