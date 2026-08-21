#pragma once

#include <atomic>

namespace wam::macos {

// Test-only silent output (the WAM_TEST_MUTED launch seam).
//
// Automated GUI verification runs on the user's own machine, with the user's
// own speakers: a correctness round that opens a clip blasts audio at whoever
// happens to be sitting there. This gate lets such a round render normally and
// hear nothing.
//
// It is a MUTE AT THE OUTPUT COPY, not a volume change, and that distinction is
// the whole point. Everything the benchmark stream measures -- callback
// entries, admitted/rendered callback counts, requested frames, the stream
// frame cursor, the media clock's rate and position, underrun edges, the
// OutputIsSilence action flag, the wake edges -- is produced by the render core
// and its counters, all of which run exactly as they would unmuted. Only the
// float samples already written into the AudioUnit's buffer are overwritten
// with zeros, after the render core has finished with them. A muted run and an
// unmuted run are therefore metric-identical by construction rather than by
// measurement, which is what makes the seam safe to leave in a measurement
// path.
//
// Rejected alternatives, and why:
//   * kHALOutputParam_Volume / AudioUnitSetParameter on the output unit --
//     lives inside the unit, below the callback, so it would also be silent;
//     but it changes what the unit's own render pass does per callback (a gain
//     ramp over the slice) and is a device-graph parameter whose cost and
//     scheduling this code does not control. "Provably does not alter callback
//     timing" is not a claim that can be made about it.
//   * PlayerController::setVolume(0) -- routes through the render core's gain,
//     so the samples the core produces differ from an unmuted run's, and it is
//     PERSISTED: main.cpp writes player.volume() into the state store at every
//     checkpoint, so a muted test run would silently reset the user's saved
//     volume to zero. Disqualifying on its own.
//   * kAudioUnitRenderAction_OutputIsSilence on every callback -- the flag is a
//     hint the HAL may act on (skipping downstream work), so it can change what
//     the device does; and render() already uses that flag to report a real
//     all-silent slice, which a mute must not counterfeit.
//
// A process-global rather than a constructor argument for the same reason
// native_layer_presentation_state.hpp is one: the producer (main.cpp, in the Qt
// layer) and the consumer (NativeAudioOutput, in the macOS backend library)
// have no dependency edge, and adding one to carry a single bool would be a
// worse trade than a header-only inline. Header-only with a function-local
// static gives exactly one instance per binary and no link dependency.
//
// Written once, on the main thread, before any playback session exists;
// NativeAudioOutput snapshots it into a const member at construction, so the
// render callback reads a plain bool and never touches this atomic.
[[nodiscard]] inline std::atomic<bool> &
nativeAudioOutputTestMuteGate() noexcept {
  static std::atomic<bool> muted{false};
  return muted;
}

inline void setNativeAudioOutputTestMuted(bool muted) noexcept {
  nativeAudioOutputTestMuteGate().store(muted, std::memory_order_release);
}

[[nodiscard]] inline bool nativeAudioOutputTestMuted() noexcept {
  return nativeAudioOutputTestMuteGate().load(std::memory_order_acquire);
}

}  // namespace wam::macos
