#pragma once

#if defined(WAM_NATIVE_VIDEO_TESTING)
#include <cstddef>
#include <mutex>

namespace wam::macos {
struct NativeVideoCallbackAudit {
  std::size_t allocations{0};
  std::size_t locks{0};
};
inline thread_local NativeVideoCallbackAudit* activeVideoCallbackAudit = nullptr;

class VideoDecoderMutex final {
 public:
  void lock() {
    if (activeVideoCallbackAudit != nullptr) {
      ++activeVideoCallbackAudit->locks;
    }
    mutex_.lock();
  }
  bool try_lock() {
    if (activeVideoCallbackAudit != nullptr) {
      ++activeVideoCallbackAudit->locks;
    }
    return mutex_.try_lock();
  }
  void unlock() { mutex_.unlock(); }
 private:
  std::mutex mutex_;
};
}  // namespace wam::macos
#endif
