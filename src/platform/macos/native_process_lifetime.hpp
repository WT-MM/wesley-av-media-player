#pragma once
#include <cstddef>
#include <memory>
#include <new>
#include <type_traits>

namespace wam::macos {
// Process registries must outlive global teardown and deferred retirement.
// Construction must not allocate; entries retire through bounded workers.
template<class T> class NativeProcessLifetime final {
 public:
  NativeProcessLifetime() noexcept(std::is_nothrow_default_constructible_v<T>) {
    std::construct_at(reinterpret_cast<T*>(storage_));
  }
  NativeProcessLifetime(const NativeProcessLifetime&) = delete;
  NativeProcessLifetime& operator=(const NativeProcessLifetime&) = delete;
  T& get() noexcept { return *std::launder(reinterpret_cast<T*>(storage_)); }
 private:
  alignas(T) std::byte storage_[sizeof(T)];
};
static_assert(std::is_trivially_destructible_v<NativeProcessLifetime<int>>);
}
