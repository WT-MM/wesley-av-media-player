#include "native_retirement.hpp"
#include "native_concurrency_limits.hpp"
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <array>
#include <cassert>

namespace wam::macos {
namespace {
std::array<std::atomic<bool>, kMaximumConcurrentPlayerWindows> slots{};
std::atomic<bool> testPaused{false};
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
void NativeRetirement::setTestPaused(bool paused) noexcept {
  testPaused.store(paused, std::memory_order_release);
  if (!paused) testPaused.notify_all();
}
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
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    while (testPaused.load(std::memory_order_acquire)) testPaused.wait(true);
    retained->graph_.reset();
    retained->complete_.store(true, std::memory_order_release);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion) completion(lifetime);
    });
  });
}
}
