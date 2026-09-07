#pragma once

#include <atomic>
#include <memory>

namespace wam::macos {

// Reserve before constructing a graph. A retiring or stalled graph keeps its
// slot until destruction completes; destruction never runs on the main thread.
class NativeRetirement final : public std::enable_shared_from_this<NativeRetirement> {
public:
  static std::shared_ptr<NativeRetirement> reserve() noexcept;
  static unsigned charged() noexcept;
  static void setTestPaused(bool) noexcept;
  ~NativeRetirement();
  NativeRetirement(const NativeRetirement&) = delete;
  NativeRetirement& operator=(const NativeRetirement&) = delete;
  using Completion = void (*)(std::shared_ptr<void>) noexcept;
  void retire(std::shared_ptr<void> graph, std::shared_ptr<void> lifetime,
              Completion completion) noexcept;
  bool started() const noexcept { return started_; }
  bool complete() const noexcept { return complete_.load(std::memory_order_acquire); }
private:
  explicit NativeRetirement(unsigned slot) noexcept : slot_(slot) {}
  unsigned slot_;
  bool started_{false};
  std::atomic<bool> complete_{false};
  std::shared_ptr<void> graph_;
};
}
