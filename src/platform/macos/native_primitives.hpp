#pragma once

#include <atomic>
#include <cstdint>
#include <limits>
#include <string>

// Small helpers every native platform file shares, so each states one rule.
namespace wam::macos {

// Diagnostic text is best-effort: the typed result is authoritative, so an
// allocation failure leaves the string unchanged instead of throwing.
inline void assignError(std::string* error, const char* message) noexcept {
  if (error == nullptr || message == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

inline void assignError(std::string* error,
                        const std::string& message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

// Saturating counters, named by who may write them.
//
// Owner-confined plain value.
[[nodiscard]] constexpr std::uint64_t saturatingSum(
    std::uint64_t value, std::uint64_t amount) noexcept {
  constexpr std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
  return amount > maximum - value ? maximum : value + amount;
}
inline void saturatingAdd(std::uint64_t& value, std::uint64_t amount) noexcept {
  value = saturatingSum(value, amount);
}
inline void saturatingIncrement(std::uint64_t& value) noexcept {
  saturatingAdd(value, 1);
}

// Any thread; never loses an increment.
inline void saturatingIncrement(std::atomic<std::uint64_t>& value) noexcept {
  std::uint64_t observed = value.load(std::memory_order_relaxed);
  while (observed != std::numeric_limits<std::uint64_t>::max() &&
         !value.compare_exchange_weak(observed, observed + 1,
                                      std::memory_order_relaxed,
                                      std::memory_order_relaxed)) {
  }
}

// Real-time callback: wait-free. The compare-exchange is tried at most twice,
// so a contended (or spuriously failed) pair of attempts drops the increment;
// these counters are a lower bound, never an overcount.
inline void saturatingAdd(std::atomic<std::uint64_t>& counter,
                          std::uint64_t amount) noexcept {
  std::uint64_t current = counter.load(std::memory_order_relaxed);
  for (unsigned attempt = 0; attempt != 2; ++attempt) {
    if (counter.compare_exchange_weak(current, saturatingSum(current, amount),
                                      std::memory_order_relaxed,
                                      std::memory_order_relaxed)) {
      return;
    }
  }
}

// 2^53: every integer up to it is exactly representable as a double.
inline constexpr std::uint64_t kMaximumExactDoubleInteger = std::uint64_t{1}
                                                            << 53U;

}  // namespace wam::macos
