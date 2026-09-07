#include "platform/macos/native_retirement.hpp"
#include "platform/macos/native_concurrency_limits.hpp"
#import <Foundation/Foundation.h>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <vector>

using wam::macos::NativeRetirement;
namespace {
void expect(bool value, const char* message) {
  if (!value) { std::cerr << message << '\n'; std::exit(1); }
}
struct Probe {
  std::atomic<bool> entered{false};
  std::atomic<bool> release{false};
  bool completed{false};
};
void complete(std::shared_ptr<void> opaque) noexcept {
  auto probe = std::static_pointer_cast<Probe>(opaque);
  expect([NSThread isMainThread], "retirement completion is on main");
  probe->completed = true;
}
}
int main() {
  @autoreleasepool {
    std::vector<std::shared_ptr<NativeRetirement>> tickets;
    for (int i = 0; i < wam::macos::kMaximumConcurrentPlayerWindows; ++i) {
      tickets.push_back(NativeRetirement::reserve());
      expect(bool(tickets.back()), "each admitted graph reserves retirement");
    }
    expect(!NativeRetirement::reserve(), "graph seventeen is refused before construction");
    auto probe = std::make_shared<Probe>();
    auto graph = std::shared_ptr<void>(new int(1), [probe](void* value) {
      expect(![NSThread isMainThread], "graph destruction is off main");
      probe->entered.store(true, std::memory_order_release);
      while (!probe->release.load(std::memory_order_acquire)) std::this_thread::yield();
      delete static_cast<int*>(value);
    });
    auto retiring = tickets.back();
    retiring->retire(std::move(graph), probe, &complete);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (!probe->entered.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < deadline)
      std::this_thread::yield();
    expect(probe->entered, "background destruction entered");
    expect(!retiring->complete() && !probe->completed, "close does not counterfeit retirement");
    expect(!NativeRetirement::reserve(), "blocked retirement remains charged");
    probe->release.store(true, std::memory_order_release);
    while (!probe->completed && std::chrono::steady_clock::now() < deadline)
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    expect(probe->completed && retiring->complete(), "close completes after graph destruction");
    tickets.clear();
    retiring.reset();
    expect(NativeRetirement::charged() == 0, "completed graphs release all reservations");
  }
}
