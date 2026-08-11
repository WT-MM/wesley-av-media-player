#pragma once

#include <atomic>

namespace wam::detail {

// A small cooperative-cancellation primitive for toolchains whose C++20
// library does not yet provide std::stop_token/std::jthread. The source owns
// this flag until its worker has been joined, so a borrowed reference is safe
// for the complete operation lifetime.
class CancellationFlag final {
public:
  void reset() noexcept { requested_.store(false, std::memory_order_release); }

  void request() noexcept { requested_.store(true, std::memory_order_release); }

  [[nodiscard]] bool requested() const noexcept {
    return requested_.load(std::memory_order_acquire);
  }

private:
  std::atomic<bool> requested_{false};
};

} // namespace wam::detail
