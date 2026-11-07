#pragma once

#include <atomic>

// The native layer's test seams, and the one switch that compiles them in.
//
// WAM_NATIVE_TEST_SEAMS is defined only on the seam-enabled twins of the
// production libraries (cmake/TestSeams.cmake) and whatever links them: the
// native tests, and WAMKit configured with WAMKIT_ENABLE_TEST_SUPPORT (whose
// identity-gated environment variables are the only production-binary
// producers of these seams). Shipping builds compile none of it: no hook
// storage, no hook call on the real-time path, no test-only global. The Qt
// layer's one equivalent switch is WAM_QT_TEST_SEAMS (wam_app_test_seams in
// tests/CMakeLists.txt).
//
// Seams that stay compiled in shipping builds, deliberately:
//   * WAM_TEST_MUTED (native_audio_test_mute.hpp): output-copy mute for
//     automated GUI rounds on the user's own speakers.
//   * WAM_AUDIO_IO_FRAMES (NativeAudioOutput, requestedDeviceBufferFrames()):
//     selects the device IO buffer size so one binary can serve both arms of a
//     paired wake-rate measurement. Read once per process and admitted only if
//     it satisfies the same ring-headroom inequalities as
//     NativeAudioOutput::kDeviceBufferFrames.

namespace wam::macos {

#if defined(WAM_NATIVE_TEST_SEAMS)

// A test callback a production path calls at one named point.
struct NativeTestHook {
  using Function = void (*)(void* context) noexcept;
  Function function{nullptr};
  void* context{nullptr};

  void operator()() const noexcept {
    if (function != nullptr) {
      function(context);
    }
  }
};

// Set by WAMKit (WAM_TEST_DEVICE_RECOVERY_SEEK) before a seek; the next
// NativeAudioOutput::activate() consumes it and replays a StreamFormat
// notification, so a device recovery overlaps the seek's activation.
[[nodiscard]] inline std::atomic<bool>&
nativeAudioDeviceRecoverySeekTestGate() noexcept {
  static std::atomic<bool> pending{false};
  return pending;
}

#define WAM_NATIVE_TEST_HOOK(hook) (hook)()

#else

#define WAM_NATIVE_TEST_HOOK(hook) static_cast<void>(0)

#endif

}  // namespace wam::macos
