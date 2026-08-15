#include "native_pcm_ring.hpp"

#include <algorithm>
#include <limits>

namespace wam::macos {

NativePcmRing::NativePcmRing(std::uint64_t initialGeneration) noexcept
    : generation_(initialGeneration == 0 ? 1 : initialGeneration) {}

void NativePcmRing::saturatingAdd(std::atomic<std::uint64_t> &counter,
                                  std::uint64_t amount) noexcept {
  // Serialized endpoint/control ownership permits at most one counter writer.
  // A relaxed load/store pair is therefore bounded and sufficient; stats() is
  // an observer only.
  const std::uint64_t current = counter.load(std::memory_order_relaxed);
  const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
  counter.store(amount > maximum - current ? maximum : current + amount,
                std::memory_order_relaxed);
}

void NativePcmRing::addUnreadPcmBytes(std::size_t bytes) noexcept {
  const std::size_t current =
      unreadPcmBytes_.fetch_add(bytes, std::memory_order_acq_rel) + bytes;
  std::size_t peak = peakUnreadPcmBytes_.load(std::memory_order_relaxed);
  while (peak < current &&
         !peakUnreadPcmBytes_.compare_exchange_weak(
             peak, current, std::memory_order_release,
             std::memory_order_relaxed)) {
  }
}

void NativePcmRing::removeUnreadPcmBytes(std::size_t bytes) noexcept {
  static_cast<void>(
      unreadPcmBytes_.fetch_sub(bytes, std::memory_order_acq_rel));
}

bool NativePcmRing::readableSlab(std::uint64_t slabGeneration,
                                 std::size_t slabFrames,
                                 std::size_t frameOffset,
                                 std::uint64_t activeGeneration) noexcept {
  return slabGeneration == activeGeneration && slabFrames != 0 &&
         slabFrames <= kFramesPerSlab && frameOffset < slabFrames;
}

NativePcmRing::PublishResult
NativePcmRing::publish(std::uint64_t generation,
                       std::span<const float> interleaved,
                       std::size_t frameCount) noexcept {
  if (generation == 0 || frameCount == 0 || frameCount > kFramesPerSlab) {
    saturatingAdd(producerCounters_.invalidPublishes, 1);
    return PublishResult::Invalid;
  }

  // frameCount is bounded before multiplication, so this cannot overflow.
  const std::size_t expectedSamples = frameCount * kChannels;
  if (interleaved.size() != expectedSamples) {
    saturatingAdd(producerCounters_.invalidPublishes, 1);
    return PublishResult::Invalid;
  }
  if (generation_.load(std::memory_order_acquire) != generation) {
    saturatingAdd(producerCounters_.stalePublishes, 1);
    return PublishResult::StaleGeneration;
  }

  const std::uint64_t write = writeCursor_.load(std::memory_order_relaxed);
  const std::uint64_t read = readCursor_.load(std::memory_order_acquire);
  if (write - read >= kSlabCount) {
    saturatingAdd(producerCounters_.fullPublishes, 1);
    return PublishResult::Full;
  }

  const std::size_t slot = static_cast<std::size_t>(write % kSlabCount);
  std::copy_n(interleaved.data(), expectedSamples, pcm_[slot].data());
  slabGenerations_[slot] = generation;
  slabFrames_[slot] = static_cast<std::uint32_t>(frameCount);

  // A generation can change while the copy is in progress. Do not publish
  // those bytes; the next producer call may safely overwrite the same slot.
  if (generation_.load(std::memory_order_acquire) != generation) {
    saturatingAdd(producerCounters_.stalePublishes, 1);
    return PublishResult::StaleGeneration;
  }
  // Charge ownership before the release-published cursor makes the slab
  // consumable. The consumer therefore cannot subtract bytes which the ring
  // has not first acquired.
  const std::size_t payloadBytes = expectedSamples * sizeof(float);
  slabUnreadPcmBytes_[slot] = payloadBytes;
  addUnreadPcmBytes(payloadBytes);
  writeCursor_.store(write + 1, std::memory_order_release);
  saturatingAdd(producerCounters_.publishedSlabs, 1);
  saturatingAdd(producerCounters_.publishedFrames, frameCount);
  return PublishResult::Published;
}

NativePcmRing::ReadableFramesResult
NativePcmRing::readableFrames(std::uint64_t expectedGeneration) const noexcept {
  const std::uint64_t activeGeneration =
      generation_.load(std::memory_order_acquire);
  ReadableFramesResult result;
  result.generation = activeGeneration;
  if (expectedGeneration == 0 || expectedGeneration != activeGeneration) {
    result.staleConsumer = true;
    return result;
  }

  std::uint64_t read = readCursor_.load(std::memory_order_relaxed);
  const std::uint64_t write = writeCursor_.load(std::memory_order_acquire);
  std::size_t frameOffset = consumerOffsetFrames_;
  std::size_t visitedSlabs = 0;
  while (read != write && visitedSlabs < kSlabCount) {
    const std::size_t slot = static_cast<std::size_t>(read % kSlabCount);
    const std::size_t slabFrames = slabFrames_[slot];
    if (readableSlab(slabGenerations_[slot], slabFrames, frameOffset,
                     activeGeneration)) {
      result.frames += slabFrames - frameOffset;
    } else if (slabGenerations_[slot] != activeGeneration) {
      ++result.staleSlabs;
    }
    frameOffset = 0;
    ++read;
    ++visitedSlabs;
  }
  return result;
}

NativePcmRing::ConsumeResult
NativePcmRing::consume(std::uint64_t expectedGeneration,
                       std::span<float> output) noexcept {
  const std::uint64_t activeGeneration =
      generation_.load(std::memory_order_acquire);
  ConsumeResult result;
  result.generation = activeGeneration;

  if (output.empty() || output.size() % kChannels != 0 ||
      output.size() / kChannels > kFramesPerSlab) {
    result.invalidInput = true;
    saturatingAdd(consumerCounters_.invalidConsumers, 1);
    return result;
  }

  const std::size_t requestedFrames = output.size() / kChannels;
  if (expectedGeneration == 0 || expectedGeneration != activeGeneration) {
    std::fill(output.begin(), output.end(), 0.0F);
    result.silentFrames = requestedFrames;
    result.staleConsumer = true;
    saturatingAdd(consumerCounters_.silentFrames, requestedFrames);
    saturatingAdd(consumerCounters_.staleConsumers, 1);
    return result;
  }

  std::uint64_t read = readCursor_.load(std::memory_order_relaxed);
  const std::uint64_t write = writeCursor_.load(std::memory_order_acquire);
  std::size_t visitedSlabs = 0;
  while (result.pcmFrames < requestedFrames && read != write &&
         visitedSlabs < kSlabCount) {
    const std::size_t slot = static_cast<std::size_t>(read % kSlabCount);
    const std::size_t slabFrames = slabFrames_[slot];
    if (!readableSlab(slabGenerations_[slot], slabFrames, consumerOffsetFrames_,
                      activeGeneration)) {
      removeUnreadPcmBytes(slabUnreadPcmBytes_[slot]);
      slabUnreadPcmBytes_[slot] = 0;
      if (slabGenerations_[slot] != activeGeneration) {
        ++result.staleSlabs;
        saturatingAdd(consumerCounters_.staleSlabs, 1);
      }
      consumerOffsetFrames_ = 0;
      ++read;
      ++visitedSlabs;
      readCursor_.store(read, std::memory_order_release);
      continue;
    }

    const std::size_t available = slabFrames - consumerOffsetFrames_;
    const std::size_t count =
        std::min(available, requestedFrames - result.pcmFrames);
    std::copy_n(pcm_[slot].data() + consumerOffsetFrames_ * kChannels,
                count * kChannels,
                output.data() + result.pcmFrames * kChannels);
    const std::size_t consumedBytes = count * kChannels * sizeof(float);
    removeUnreadPcmBytes(consumedBytes);
    slabUnreadPcmBytes_[slot] -= consumedBytes;
    result.pcmFrames += count;
    consumerOffsetFrames_ += count;
    if (consumerOffsetFrames_ == slabFrames) {
      consumerOffsetFrames_ = 0;
      slabUnreadPcmBytes_[slot] = 0;
      ++read;
      ++visitedSlabs;
      readCursor_.store(read, std::memory_order_release);
    }
  }

  saturatingAdd(consumerCounters_.consumedFrames, result.pcmFrames);
  result.silentFrames = requestedFrames - result.pcmFrames;
  if (result.silentFrames != 0) {
    std::fill_n(output.data() + result.pcmFrames * kChannels,
                result.silentFrames * kChannels, 0.0F);
    result.underrun = true;
    saturatingAdd(consumerCounters_.silentFrames, result.silentFrames);
    saturatingAdd(consumerCounters_.underrunCallbacks, 1);
  }
  return result;
}

std::size_t NativePcmRing::discard(std::uint64_t expectedGeneration,
                                   std::size_t frames) noexcept {
  const std::uint64_t activeGeneration =
      generation_.load(std::memory_order_acquire);
  if (frames == 0 || expectedGeneration == 0 ||
      expectedGeneration != activeGeneration) {
    return 0;
  }

  std::size_t retired = 0;
  std::uint64_t read = readCursor_.load(std::memory_order_relaxed);
  const std::uint64_t write = writeCursor_.load(std::memory_order_acquire);
  std::size_t visitedSlabs = 0;
  while (retired < frames && read != write && visitedSlabs < kSlabCount) {
    const std::size_t slot = static_cast<std::size_t>(read % kSlabCount);
    const std::size_t slabFrames = slabFrames_[slot];
    if (!readableSlab(slabGenerations_[slot], slabFrames,
                      consumerOffsetFrames_, activeGeneration)) {
      removeUnreadPcmBytes(slabUnreadPcmBytes_[slot]);
      slabUnreadPcmBytes_[slot] = 0;
      if (slabGenerations_[slot] != activeGeneration) {
        saturatingAdd(consumerCounters_.staleSlabs, 1);
      }
      consumerOffsetFrames_ = 0;
      ++read;
      ++visitedSlabs;
      readCursor_.store(read, std::memory_order_release);
      continue;
    }

    const std::size_t available = slabFrames - consumerOffsetFrames_;
    const std::size_t count = std::min(available, frames - retired);
    const std::size_t retiredBytes = count * kChannels * sizeof(float);
    removeUnreadPcmBytes(retiredBytes);
    slabUnreadPcmBytes_[slot] -= retiredBytes;
    retired += count;
    consumerOffsetFrames_ += count;
    if (consumerOffsetFrames_ == slabFrames) {
      consumerOffsetFrames_ = 0;
      slabUnreadPcmBytes_[slot] = 0;
      ++read;
      ++visitedSlabs;
      readCursor_.store(read, std::memory_order_release);
    }
  }

  saturatingAdd(consumerCounters_.consumedFrames, retired);
  return retired;
}

bool NativePcmRing::flush(std::uint64_t nextGeneration) noexcept {
  const std::uint64_t activeGeneration =
      generation_.load(std::memory_order_acquire);
  if (nextGeneration == 0 || nextGeneration <= activeGeneration) {
    saturatingAdd(producerCounters_.invalidFlushes, 1);
    return false;
  }
  const std::uint64_t write = writeCursor_.load(std::memory_order_acquire);
  consumerOffsetFrames_ = 0;
  readCursor_.store(write, std::memory_order_release);
  slabUnreadPcmBytes_.fill(0);
  unreadPcmBytes_.store(0, std::memory_order_release);
  peakUnreadPcmBytes_.store(0, std::memory_order_release);
  // Publish the new generation last. An acquiring observer which sees it also
  // sees the empty current/HWM seed installed at this stopped boundary.
  generation_.store(nextGeneration, std::memory_order_release);
  saturatingAdd(producerCounters_.successfulFlushes, 1);
  return true;
}

std::uint64_t NativePcmRing::generation() const noexcept {
  return generation_.load(std::memory_order_acquire);
}

std::size_t NativePcmRing::queuedSlabs() const noexcept {
  // Loading the consumer cursor first prevents a newly advanced read cursor
  // from being subtracted from an older write snapshot. The result may be
  // conservatively stale during concurrent traffic, but is always bounded.
  const std::uint64_t read = readCursor_.load(std::memory_order_acquire);
  const std::uint64_t write = writeCursor_.load(std::memory_order_acquire);
  const std::uint64_t distance = write - read;
  return distance <= kSlabCount ? static_cast<std::size_t>(distance) : 0;
}

NativePcmRing::Stats NativePcmRing::stats() const noexcept {
  Stats result;
  result.generation = generation_.load(std::memory_order_acquire);
  result.queuedSlabs = queuedSlabs();
  result.unreadPcmBytes = unreadPcmBytes_.load(std::memory_order_acquire);
  result.peakUnreadPcmBytes = std::max(
      peakUnreadPcmBytes_.load(std::memory_order_acquire),
      result.unreadPcmBytes);

  result.publishedSlabs =
      producerCounters_.publishedSlabs.load(std::memory_order_relaxed);
  result.publishedFrames =
      producerCounters_.publishedFrames.load(std::memory_order_relaxed);
  result.fullPublishes =
      producerCounters_.fullPublishes.load(std::memory_order_relaxed);
  result.stalePublishes =
      producerCounters_.stalePublishes.load(std::memory_order_relaxed);
  result.invalidPublishes =
      producerCounters_.invalidPublishes.load(std::memory_order_relaxed);
  result.successfulFlushes =
      producerCounters_.successfulFlushes.load(std::memory_order_relaxed);
  result.invalidFlushes =
      producerCounters_.invalidFlushes.load(std::memory_order_relaxed);

  result.consumedFrames =
      consumerCounters_.consumedFrames.load(std::memory_order_relaxed);
  result.silentFrames =
      consumerCounters_.silentFrames.load(std::memory_order_relaxed);
  result.underrunCallbacks =
      consumerCounters_.underrunCallbacks.load(std::memory_order_relaxed);
  result.staleConsumers =
      consumerCounters_.staleConsumers.load(std::memory_order_relaxed);
  result.staleSlabs =
      consumerCounters_.staleSlabs.load(std::memory_order_relaxed);
  result.invalidConsumers =
      consumerCounters_.invalidConsumers.load(std::memory_order_relaxed);
  return result;
}

bool NativePcmRing::resetUnreadPcmByteHighWater(
    std::uint64_t expectedGeneration) noexcept {
  if (expectedGeneration == 0 ||
      generation_.load(std::memory_order_acquire) != expectedGeneration) {
    return false;
  }
  const std::size_t current =
      unreadPcmBytes_.load(std::memory_order_acquire);
  peakUnreadPcmBytes_.store(current, std::memory_order_release);
  return true;
}

} // namespace wam::macos
