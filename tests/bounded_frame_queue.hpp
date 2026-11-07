#pragma once

// A thread-safe, bounded DecodedFrameSink for decoder tests. It rejects
// over-capacity and stale-generation frames instead of accumulating them.

#include "platform/macos/video_decoder_contract.hpp"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace wam::test {

class BoundedFrameQueue final : public wam::macos::DecodedFrameSink {
 public:
  explicit BoundedFrameQueue(std::size_t capacity,
                             std::uint64_t initialGeneration = 0)
      : capacity_(capacity), generation_(initialGeneration) {}

  [[nodiscard]] wam::macos::FrameEnqueueResult enqueue(
      wam::macos::FrameLease frame, std::string* error) override {
    using wam::macos::FrameEnqueueResult;
    const auto fail = [error](const char* message, FrameEnqueueResult result) {
      if (error != nullptr) {
        *error = message;
      }
      return result;
    };
    if (error != nullptr) {
      error->clear();
    }
    if (!frame) {
      return fail("cannot enqueue an empty frame lease",
                  FrameEnqueueResult::Rejected);
    }
    std::lock_guard lock(mutex_);
    if (frame.timing().generation != generation_) {
      return fail("rejecting a stale decoded-frame generation",
                  FrameEnqueueResult::Rejected);
    }
    if (endOfStream_) {
      return fail("cannot enqueue after end of stream",
                  FrameEnqueueResult::Rejected);
    }
    if (frames_.size() >= capacity_) {
      return fail("decoded-frame queue is full",
                  FrameEnqueueResult::Backpressure);
    }
    frames_.push_back(std::move(frame));
    return FrameEnqueueResult::Accepted;
  }

  void endOfStream(std::uint64_t generation) override {
    std::lock_guard lock(mutex_);
    if (generation == generation_) {
      endOfStream_ = true;
    }
  }

  void flush(std::uint64_t nextGeneration) noexcept override {
    std::deque<wam::macos::FrameLease> retired;
    std::lock_guard lock(mutex_);
    retired.swap(frames_);
    generation_ = nextGeneration;
    endOfStream_ = false;
  }

  [[nodiscard]] std::optional<wam::macos::FrameLease> tryTake() {
    std::lock_guard lock(mutex_);
    if (frames_.empty()) {
      return std::nullopt;
    }
    wam::macos::FrameLease frame = std::move(frames_.front());
    frames_.pop_front();
    return frame;
  }
  [[nodiscard]] std::size_t size() const noexcept {
    std::lock_guard lock(mutex_);
    return frames_.size();
  }
  [[nodiscard]] std::size_t capacity() const noexcept { return capacity_; }
  [[nodiscard]] std::uint64_t generation() const noexcept {
    std::lock_guard lock(mutex_);
    return generation_;
  }
  [[nodiscard]] bool reachedEndOfStream() const noexcept {
    std::lock_guard lock(mutex_);
    return endOfStream_ && frames_.empty();
  }

 private:
  const std::size_t capacity_;
  std::uint64_t generation_;
  bool endOfStream_{false};
  mutable std::mutex mutex_;
  std::deque<wam::macos::FrameLease> frames_;
};

}  // namespace wam::test
