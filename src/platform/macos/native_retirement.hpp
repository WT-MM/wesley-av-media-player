#pragma once

#include "native_test_seams.hpp"

#include <atomic>
#include <cstdint>
#include <memory>

namespace wam::macos {

// Reserve before constructing a graph. A retiring or stalled graph keeps its
// slot until destruction completes; destruction never runs on the main thread.
class NativeRetirement final : public std::enable_shared_from_this<NativeRetirement> {
public:
  static std::shared_ptr<NativeRetirement> reserve() noexcept;
  static unsigned charged() noexcept;
  // Process-exit barrier: call only after all owners have retired their graphs.
  // Normal window close remains asynchronous. No main-queue callback is needed.
  static void drainForProcessExit() noexcept;
#if defined(WAM_NATIVE_TEST_SEAMS)
  // Holds every retirement worker before it destroys its graph, so a test can
  // observe a window whose teardown has not finished.
  static void setTestPaused(bool) noexcept;
#endif
  ~NativeRetirement();
  NativeRetirement(const NativeRetirement&) = delete;
  NativeRetirement& operator=(const NativeRetirement&) = delete;
  using Completion = void (*)(std::shared_ptr<void>) noexcept;
  void retire(std::shared_ptr<void> graph, std::shared_ptr<void> lifetime,
              Completion completion) noexcept;
  bool started() const noexcept {
    return phase_.load(std::memory_order_acquire) != Phase::Reserved;
  }
  bool complete() const noexcept {
    return phase_.load(std::memory_order_acquire) == Phase::Complete;
  }
private:
  // Reserved -> Retiring (retire(), main thread) -> Complete (the destruction
  // worker, once the graph is gone).
  enum class Phase : std::uint8_t { Reserved, Retiring, Complete };
  explicit NativeRetirement(unsigned slot) noexcept : slot_(slot) {}
  unsigned slot_;
  std::atomic<Phase> phase_{Phase::Reserved};
  std::shared_ptr<void> graph_;
};
}
