#include "native_retirement.hpp"
#include "native_concurrency_limits.hpp"
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <array>
#include <cassert>

namespace wam::macos {
namespace {
std::array<std::atomic<bool>, kMaximumConcurrentPlayerWindows> slots{};
#if defined(WAM_NATIVE_TEST_SEAMS)
std::atomic<bool> testPaused{false};
#endif
std::atomic<unsigned> pendingDestructions{0};
}
std::shared_ptr<NativeRetirement> NativeRetirement::reserve() noexcept {
  for (unsigned i = 0; i < slots.size(); ++i) {
    bool expected = false;
    if (!slots[i].compare_exchange_strong(expected, true, std::memory_order_acq_rel)) continue;
    try {
      return std::shared_ptr<NativeRetirement>(new NativeRetirement(i));
    } catch (...) {
      slots[i].store(false, std::memory_order_release);
      return {};
    }
  }
  return {};
}
void NativeRetirement::drainForProcessExit() noexcept {
  for (unsigned pending = pendingDestructions.load(std::memory_order_acquire);
       pending != 0; pending = pendingDestructions.load(std::memory_order_acquire)) {
    pendingDestructions.wait(pending, std::memory_order_acquire);
  }
}
#if defined(WAM_NATIVE_TEST_SEAMS)
void NativeRetirement::setTestPaused(bool paused) noexcept {
  testPaused.store(paused, std::memory_order_release);
  if (!paused) testPaused.notify_all();
}
#endif
unsigned NativeRetirement::charged() noexcept {
  unsigned result = 0;
  for (const auto& slot : slots) result += slot.load(std::memory_order_acquire);
  return result;
}
NativeRetirement::~NativeRetirement() {
  assert(!graph_);
  slots[slot_].store(false, std::memory_order_release);
}
void NativeRetirement::retire(std::shared_ptr<void> graph,
    std::shared_ptr<void> lifetime, Completion completion) noexcept {
  assert([NSThread isMainThread] && !started_);
  started_ = true;
  graph_ = std::move(graph);
  const auto retained = shared_from_this();
  pendingDestructions.fetch_add(1, std::memory_order_release);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
#if defined(WAM_NATIVE_TEST_SEAMS)
    while (testPaused.load(std::memory_order_acquire)) testPaused.wait(true);
#endif
    @autoreleasepool {
      retained->graph_.reset();
    }
    retained->complete_.store(true, std::memory_order_release);
    pendingDestructions.fetch_sub(1, std::memory_order_release);
    pendingDestructions.notify_all();
    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion) completion(lifetime);
    });
  });
}
}
