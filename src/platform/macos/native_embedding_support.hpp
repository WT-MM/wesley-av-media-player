#pragma once
#include "native_concurrency_limits.hpp"

namespace wam::macos {
// Host policy calls require the main thread and expose no native graph ownership.
struct NativeEmbeddingSupport {
  static constexpr auto maximumWindows = kMaximumConcurrentPlayerWindows;
  static void setTestMuted(bool) noexcept;
  static bool testMuted() noexcept;
  static bool supportsAv1() noexcept;
  static bool supportsVp9() noexcept;
  static bool layerRouteSelected() noexcept;
  static bool layerActive() noexcept;
  static void setVividBoost(void* window, double) noexcept;
  static double vividBoost(void* window) noexcept;
  static double appliedVividBoost(void* window) noexcept;
};
}
