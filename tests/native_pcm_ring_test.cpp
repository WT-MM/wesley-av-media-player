#include "platform/macos/native_pcm_ring.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <span>
#include <thread>
#include <type_traits>
#include <utility>

namespace wam::macos {

struct NativePcmRingTestAccess {
  static void setGenerationWithoutFlush(NativePcmRing &ring,
                                        std::uint64_t generation) noexcept {
    ring.generation_.store(generation, std::memory_order_relaxed);
  }

  static void setCursorsQuiescent(NativePcmRing &ring, std::uint64_t read,
                                  std::uint64_t write) noexcept {
    ring.readCursor_.store(read, std::memory_order_relaxed);
    ring.writeCursor_.store(write, std::memory_order_relaxed);
    ring.consumerOffsetFrames_ = 0;
  }

  static void setPublishedSlabMetadata(NativePcmRing &ring,
                                       std::size_t physicalSlot,
                                       std::uint64_t generation,
                                       std::uint32_t frames) noexcept {
    ring.slabGenerations_[physicalSlot] = generation;
    ring.slabFrames_[physicalSlot] = frames;
  }

  static void setAllCounters(NativePcmRing &ring,
                             std::uint64_t value) noexcept {
    ring.producerCounters_.publishedSlabs.store(value,
                                                std::memory_order_relaxed);
    ring.producerCounters_.publishedFrames.store(value,
                                                 std::memory_order_relaxed);
    ring.producerCounters_.fullPublishes.store(value,
                                               std::memory_order_relaxed);
    ring.producerCounters_.stalePublishes.store(value,
                                                std::memory_order_relaxed);
    ring.producerCounters_.invalidPublishes.store(value,
                                                  std::memory_order_relaxed);
    ring.producerCounters_.successfulFlushes.store(value,
                                                   std::memory_order_relaxed);
    ring.producerCounters_.invalidFlushes.store(value,
                                                std::memory_order_relaxed);
    ring.consumerCounters_.consumedFrames.store(value,
                                                std::memory_order_relaxed);
    ring.consumerCounters_.silentFrames.store(value, std::memory_order_relaxed);
    ring.consumerCounters_.underrunCallbacks.store(value,
                                                   std::memory_order_relaxed);
    ring.consumerCounters_.staleConsumers.store(value,
                                                std::memory_order_relaxed);
    ring.consumerCounters_.staleSlabs.store(value, std::memory_order_relaxed);
    ring.consumerCounters_.invalidConsumers.store(value,
                                                  std::memory_order_relaxed);
  }
};

} // namespace wam::macos

namespace {

using wam::macos::NativePcmRing;
using wam::macos::NativePcmRingTestAccess;

int failures = 0;

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

template <typename Range> bool allEqual(const Range &values, float expected) {
  return std::all_of(values.begin(), values.end(),
                     [expected](float value) { return value == expected; });
}

void testValidationAndStaleConsumerSilence() {
  NativePcmRing defaultedGeneration(0);
  expect(defaultedGeneration.generation() == 1,
         "zero initial generation is normalized to one");

  NativePcmRing ring(7);
  const std::array<float, 2> oneFrame{1.0F, -1.0F};
  const std::array<float, 3> overlongFrame{1.0F, -1.0F, 2.0F};
  const std::span<const float> emptyInput;

  expect(ring.publish(7, emptyInput, 0) ==
             NativePcmRing::PublishResult::Invalid,
         "zero-frame publish is invalid");
  expect(ring.publish(7, oneFrame, NativePcmRing::kFramesPerSlab + 1) ==
             NativePcmRing::PublishResult::Invalid,
         "oversized publish is invalid before sample arithmetic");
  expect(ring.publish(7, oneFrame, std::numeric_limits<std::size_t>::max()) ==
             NativePcmRing::PublishResult::Invalid,
         "SIZE_MAX frame count cannot overflow validation");
  expect(ring.publish(7, std::span<const float>(oneFrame).first(1), 1) ==
             NativePcmRing::PublishResult::Invalid,
         "truncated stereo input is invalid");
  expect(ring.publish(7, overlongFrame, 1) ==
             NativePcmRing::PublishResult::Invalid,
         "overlong non-stereo input is invalid");
  expect(ring.publish(0, oneFrame, 1) == NativePcmRing::PublishResult::Invalid,
         "zero producer generation is invalid");
  expect(ring.publish(6, oneFrame, 1) ==
             NativePcmRing::PublishResult::StaleGeneration,
         "stale producer generation is rejected");

  const std::span<float> emptyOutput;
  const auto empty = ring.consume(7, emptyOutput);
  expect(empty.invalidInput, "empty consumer output is invalid");

  std::array<float, 3> oddOutput{19.0F, 19.0F, 19.0F};
  const auto odd = ring.consume(7, oddOutput);
  expect(odd.invalidInput && allEqual(oddOutput, 19.0F),
         "odd consumer output is rejected untouched");

  std::array<float, NativePcmRing::kSamplesPerSlab + 2> oversizedOutput{};
  oversizedOutput.fill(23.0F);
  const auto oversized = ring.consume(7, oversizedOutput);
  expect(oversized.invalidInput && allEqual(oversizedOutput, 23.0F),
         "oversized consumer output is rejected untouched");

  std::array<float, 4> staleOutput{31.0F, 31.0F, 31.0F, 31.0F};
  const auto zeroGeneration = ring.consume(0, staleOutput);
  expect(zeroGeneration.staleConsumer && !zeroGeneration.invalidInput &&
             !zeroGeneration.underrun && zeroGeneration.pcmFrames == 0 &&
             zeroGeneration.silentFrames == 2 && allEqual(staleOutput, 0.0F),
         "valid zero-generation callback receives bounded silence");

  staleOutput.fill(37.0F);
  const auto wrongGeneration = ring.consume(8, staleOutput);
  expect(wrongGeneration.staleConsumer && wrongGeneration.generation == 7 &&
             wrongGeneration.silentFrames == 2 && allEqual(staleOutput, 0.0F),
         "valid mismatched callback receives silence and active generation");

  const auto stats = ring.stats();
  expect(stats.invalidPublishes == 6 && stats.stalePublishes == 1,
         "producer validation counters are exact");
  expect(stats.invalidConsumers == 3 && stats.staleConsumers == 2 &&
             stats.silentFrames == 4 && stats.underrunCallbacks == 0,
         "invalid and stale consumer counters remain distinct");
  expect(stats.queuedSlabs == 0 &&
             stats.queuedSlabs <= NativePcmRing::kSlabCount,
         "empty statistics snapshot remains bounded");
}

void testPartialReadsAndExactUnderrunTail() {
  NativePcmRing ring(11);
  const std::array<float, 10> first{1.0F,   101.0F, 2.0F,   102.0F, 3.0F,
                                    103.0F, 4.0F,   104.0F, 5.0F,   105.0F};
  const std::array<float, 6> second{6.0F, 106.0F, 7.0F, 107.0F, 8.0F, 108.0F};
  expect(ring.publish(11, first, 5) ==
                 NativePcmRing::PublishResult::Published &&
             ring.publish(11, second, 3) ==
                 NativePcmRing::PublishResult::Published,
         "two variable-sized slabs publish");

  std::array<float, 4> head{};
  const auto headResult = ring.consume(11, head);
  const std::array<float, 4> expectedHead{1.0F, 101.0F, 2.0F, 102.0F};
  expect(headResult.pcmFrames == 2 && !headResult.underrun &&
             head == expectedHead && ring.queuedSlabs() == 2,
         "partial read retains its slab and frame offset");

  std::array<float, 8> crossing{};
  const auto crossingResult = ring.consume(11, crossing);
  const std::array<float, 8> expectedCrossing{3.0F, 103.0F, 4.0F, 104.0F,
                                              5.0F, 105.0F, 6.0F, 106.0F};
  expect(crossingResult.pcmFrames == 4 && !crossingResult.underrun &&
             crossing == expectedCrossing && ring.queuedSlabs() == 1,
         "one callback crosses a slab boundary without losing its tail");

  std::array<float, 8> guardedTail{};
  guardedTail.fill(55.0F);
  std::span<float> requestedTail(guardedTail.data(), 6);
  const auto tailResult = ring.consume(11, requestedTail);
  const std::array<float, 6> expectedTail{7.0F,   107.0F, 8.0F,
                                          108.0F, 0.0F,   0.0F};
  expect(tailResult.pcmFrames == 2 && tailResult.silentFrames == 1 &&
             tailResult.underrun &&
             std::equal(requestedTail.begin(), requestedTail.end(),
                        expectedTail.begin()) &&
             guardedTail[6] == 55.0F && guardedTail[7] == 55.0F,
         "underrun zeros exactly the requested missing tail");

  const auto stats = ring.stats();
  expect(stats.publishedSlabs == 2 && stats.publishedFrames == 8 &&
             stats.consumedFrames == 8 && stats.silentFrames == 1 &&
             stats.underrunCallbacks == 1 && stats.queuedSlabs == 0,
         "partial and underrun accounting is exact");
}

void testReadableFramesPreflight() {
  NativePcmRing emptyRing(12);
  const auto empty = emptyRing.readableFrames(12);
  expect(empty.frames == 0 && empty.staleSlabs == 0 && empty.generation == 12 &&
             !empty.staleConsumer,
         "preflight distinguishes an empty current generation");
  const auto stale = emptyRing.readableFrames(11);
  const auto zero = emptyRing.readableFrames(0);
  expect(stale.frames == 0 && stale.generation == 12 && stale.staleConsumer &&
             zero.frames == 0 && zero.staleConsumer,
         "stale and zero-generation preflights report no readable PCM");
  const auto emptyStats = emptyRing.stats();
  expect(emptyStats.staleConsumers == 0 && emptyStats.staleSlabs == 0,
         "non-destructive preflight does not alter lifetime counters");

  NativePcmRing partialRing(13);
  const std::array<float, 10> first{1.0F,   101.0F, 2.0F,   102.0F, 3.0F,
                                    103.0F, 4.0F,   104.0F, 5.0F,   105.0F};
  const std::array<float, 8> second{6.0F, 106.0F, 7.0F, 107.0F,
                                    8.0F, 108.0F, 9.0F, 109.0F};
  expect(partialRing.publish(13, first, 5) ==
             NativePcmRing::PublishResult::Published,
         "partial-preflight fixture publishes its first slab");
  std::array<float, 4> head{};
  expect(partialRing.consume(13, head).pcmFrames == 2,
         "partial-preflight fixture consumes a slab prefix");
  const auto partial = partialRing.readableFrames(13);
  expect(partial.frames == 3 && partial.staleSlabs == 0,
         "preflight incorporates the current slab frame offset");
  expect(partialRing.publish(13, second, 4) ==
             NativePcmRing::PublishResult::Published,
         "cross-slab preflight fixture appends a second slab");
  const auto crossing = partialRing.readableFrames(13);
  expect(crossing.frames == 7 && crossing.staleSlabs == 0,
         "preflight totals the exact readable frames across slabs");
  std::array<float, 14> crossingOutput{};
  const auto crossingConsume = partialRing.consume(13, crossingOutput);
  const std::array<float, 14> expectedCrossing{
      3.0F,   103.0F, 4.0F,   104.0F, 5.0F,   105.0F, 6.0F,
      106.0F, 7.0F,   107.0F, 8.0F,   108.0F, 9.0F,   109.0F};
  expect(crossingConsume.pcmFrames == crossing.frames &&
             !crossingConsume.underrun && crossingOutput == expectedCrossing,
         "consume satisfies the exact cross-slab preflight lower bound");

  NativePcmRing malformedRing(14);
  std::array<float, 2> frame{};
  for (std::size_t index = 0; index < NativePcmRing::kSlabCount; ++index) {
    frame.fill(static_cast<float>(index + 1));
    expect(malformedRing.publish(14, frame, 1) ==
               NativePcmRing::PublishResult::Published,
           "malformed-preflight fixture fills one physical slab");
  }
  NativePcmRingTestAccess::setPublishedSlabMetadata(malformedRing, 0, 13, 1);
  NativePcmRingTestAccess::setPublishedSlabMetadata(malformedRing, 1, 14, 0);
  NativePcmRingTestAccess::setPublishedSlabMetadata(
      malformedRing, 2, 14,
      static_cast<std::uint32_t>(NativePcmRing::kFramesPerSlab + 1));
  const auto malformed = malformedRing.readableFrames(14);
  expect(malformed.frames == 1 && malformed.staleSlabs == 1 &&
             malformedRing.queuedSlabs() == NativePcmRing::kSlabCount,
         "preflight logically skips stale, zero, and oversized metadata");
  std::array<float, 2> survivingOutput{};
  const auto malformedConsume = malformedRing.consume(14, survivingOutput);
  expect(malformedConsume.pcmFrames == malformed.frames &&
             malformedConsume.staleSlabs == malformed.staleSlabs &&
             !malformedConsume.underrun && allEqual(survivingOutput, 4.0F) &&
             malformedRing.queuedSlabs() == 0 &&
             malformedRing.stats().unreadPcmBytes == 0,
         "preflight metadata filtering exactly matches destructive consume");

  NativePcmRing appendedRing(15);
  const std::array<float, 4> prefix{1.0F, -1.0F, 2.0F, -2.0F};
  const std::array<float, 6> appended{3.0F, -3.0F, 4.0F, -4.0F, 5.0F, -5.0F};
  expect(appendedRing.publish(15, prefix, 2) ==
             NativePcmRing::PublishResult::Published,
         "append-preflight fixture publishes its stable prefix");
  const auto beforeAppend = appendedRing.readableFrames(15);
  std::atomic<bool> appendSucceeded{false};
  std::thread producer([&] {
    appendSucceeded.store(appendedRing.publish(15, appended, 3) ==
                              NativePcmRing::PublishResult::Published,
                          std::memory_order_release);
  });
  producer.join();
  std::array<float, 10> appendedOutput{};
  const auto appendedConsume = appendedRing.consume(15, appendedOutput);
  const std::array<float, 10> expectedAppended{
      1.0F, -1.0F, 2.0F, -2.0F, 3.0F, -3.0F, 4.0F, -4.0F, 5.0F, -5.0F};
  expect(beforeAppend.frames == 2 &&
             appendSucceeded.load(std::memory_order_acquire) &&
             appendedConsume.pcmFrames == 5 && !appendedConsume.underrun &&
             appendedOutput == expectedAppended,
         "producer append between preflight and consume only increases PCM");
}

void testFixedCapacityPhysicalAndCursorWraparound() {
  NativePcmRing ring(17);
  std::array<float, 2> frame{};
  for (std::size_t index = 0; index < NativePcmRing::kSlabCount; ++index) {
    frame.fill(static_cast<float>(index + 1));
    expect(ring.publish(17, frame, 1) ==
               NativePcmRing::PublishResult::Published,
           "each of four physical slabs publishes");
  }
  expect(ring.publish(17, frame, 1) == NativePcmRing::PublishResult::Full &&
             ring.queuedSlabs() == NativePcmRing::kSlabCount,
         "fifth slab is explicit bounded backpressure");

  std::array<float, 8> firstCycle{};
  const auto firstCycleResult = ring.consume(17, firstCycle);
  const std::array<float, 8> expectedFirstCycle{1.0F, 1.0F, 2.0F, 2.0F,
                                                3.0F, 3.0F, 4.0F, 4.0F};
  expect(firstCycleResult.pcmFrames == 4 && !firstCycleResult.underrun &&
             firstCycle == expectedFirstCycle && ring.queuedSlabs() == 0,
         "full ring drains in FIFO order within four slab visits");

  std::array<float, 2> output{};
  for (std::size_t index = 0; index < 37; ++index) {
    frame.fill(static_cast<float>(100 + index));
    expect(ring.publish(17, frame, 1) ==
               NativePcmRing::PublishResult::Published,
           "physical wrap publish succeeds after release");
    const auto consumed = ring.consume(17, output);
    expect(consumed.pcmFrames == 1 && !consumed.underrun && output == frame,
           "physical wrap preserves FIFO samples");
  }

  // Unsigned cursors deliberately support their natural 64-bit wrap while the
  // live distance stays within the four-slot invariant.
  NativePcmRing cursorWrap(19);
  const std::uint64_t nearEnd = std::numeric_limits<std::uint64_t>::max() - 1;
  NativePcmRingTestAccess::setCursorsQuiescent(cursorWrap, nearEnd, nearEnd);
  for (std::size_t index = 0; index < NativePcmRing::kSlabCount; ++index) {
    frame.fill(static_cast<float>(20 + index));
    expect(cursorWrap.publish(19, frame, 1) ==
               NativePcmRing::PublishResult::Published,
           "cursor wrap publish stays within capacity");
  }
  std::array<float, 8> wrappedOutput{};
  const auto wrappedReadable = cursorWrap.readableFrames(19);
  const auto wrapped = cursorWrap.consume(19, wrappedOutput);
  const std::array<float, 8> expectedWrapped{20.0F, 20.0F, 21.0F, 21.0F,
                                             22.0F, 22.0F, 23.0F, 23.0F};
  expect(wrappedReadable.frames == 4 && wrappedReadable.staleSlabs == 0 &&
             wrapped.pcmFrames == wrappedReadable.frames &&
             wrappedOutput == expectedWrapped && cursorWrap.queuedSlabs() == 0,
         "preflight and consume preserve modular cursor-wrap ordering");

  NativePcmRing snapshot(20);
  NativePcmRingTestAccess::setCursorsQuiescent(snapshot, 10, 5);
  expect(snapshot.queuedSlabs() == 0,
         "incoherent cursor snapshot cannot underflow to a false full ring");

  const auto stats = ring.stats();
  expect(stats.publishedSlabs == 41 && stats.fullPublishes == 1 &&
             stats.consumedFrames == 41,
         "capacity and physical-wrap statistics are exact");
}

void testFullSizedSlab() {
  NativePcmRing ring(31);
  std::array<float, NativePcmRing::kSamplesPerSlab> input{};
  std::array<float, NativePcmRing::kSamplesPerSlab> output{};
  for (std::size_t sample = 0; sample < input.size(); ++sample) {
    input[sample] = static_cast<float>(sample % 257U) - 128.0F;
  }

  expect(ring.publish(31, input, NativePcmRing::kFramesPerSlab) ==
             NativePcmRing::PublishResult::Published,
         "maximum 4096-frame slab publishes");
  const auto consumed = ring.consume(31, output);
  expect(consumed.pcmFrames == NativePcmRing::kFramesPerSlab &&
             consumed.silentFrames == 0 && !consumed.underrun &&
             output == input,
         "maximum slab round-trips exactly");
}

void testExactUnreadPcmByteAccounting() {
  NativePcmRing ring(37);
  constexpr std::size_t kFrameBytes =
      NativePcmRing::kChannels * sizeof(float);
  const auto empty = ring.stats();
  expect(empty.unreadPcmBytes == 0 && empty.peakUnreadPcmBytes == 0,
         "new ring owns no logical PCM despite its fixed storage capacity");

  const std::array<float, 10> first{};
  const std::array<float, 6> second{};
  expect(ring.publish(37, first, 5) ==
             NativePcmRing::PublishResult::Published &&
             ring.publish(37, second, 3) ==
                 NativePcmRing::PublishResult::Published,
         "memory fixture publishes two logical payloads");
  auto stats = ring.stats();
  expect(stats.unreadPcmBytes == 8 * kFrameBytes &&
             stats.peakUnreadPcmBytes == 8 * kFrameBytes &&
             stats.unreadPcmBytes != NativePcmRing::kPcmPayloadBytes,
         "current and HWM count exact unread bytes rather than ring capacity");

  std::array<float, 4> prefix{};
  expect(ring.consume(37, prefix).pcmFrames == 2,
         "memory fixture consumes a partial slab");
  stats = ring.stats();
  expect(stats.unreadPcmBytes == 6 * kFrameBytes &&
             stats.peakUnreadPcmBytes == 8 * kFrameBytes,
         "partial consumption subtracts only the copied logical frames");
  expect(!ring.resetUnreadPcmByteHighWater(0) &&
             !ring.resetUnreadPcmByteHighWater(38),
         "memory HWM reset rejects zero and mismatched generations");
  stats = ring.stats();
  expect(stats.unreadPcmBytes == 6 * kFrameBytes &&
             stats.peakUnreadPcmBytes == 8 * kFrameBytes,
         "rejected HWM resets leave both current and peak unchanged");
  expect(ring.resetUnreadPcmByteHighWater(37),
         "stopped owner can reset the generation-local diagnostic HWM");
  stats = ring.stats();
  expect(stats.unreadPcmBytes == 6 * kFrameBytes &&
             stats.peakUnreadPcmBytes == 6 * kFrameBytes,
         "HWM reset seeds from current unread ownership rather than zero");

  std::array<float, 12> remainder{};
  expect(ring.consume(37, remainder).pcmFrames == 6,
         "memory fixture drains its remaining logical frames");
  stats = ring.stats();
  expect(stats.unreadPcmBytes == 0 &&
             stats.peakUnreadPcmBytes == 6 * kFrameBytes,
         "drain clears current ownership while preserving its diagnostic HWM");

  expect(ring.publish(37, first, 5) ==
             NativePcmRing::PublishResult::Published &&
             ring.flush(38),
         "generation transition discards a queued logical payload");
  stats = ring.stats();
  expect(stats.generation == 38 && stats.unreadPcmBytes == 0 &&
             stats.peakUnreadPcmBytes == 0,
         "flush publishes a coherent empty current/HWM seed for the new generation");
}

void testGenerationResetAndStaleSlabs() {
  NativePcmRing ring(41);
  const std::array<float, 8> oldAudio{1.0F, -1.0F, 2.0F, -2.0F,
                                      3.0F, -3.0F, 4.0F, -4.0F};
  expect(ring.publish(41, oldAudio, 4) ==
             NativePcmRing::PublishResult::Published,
         "old generation audio publishes");
  std::array<float, 2> partial{};
  expect(ring.consume(41, partial).pcmFrames == 1 && ring.queuedSlabs() == 1,
         "old generation retains a partial slab offset");

  expect(!ring.flush(0) && !ring.flush(41) && !ring.flush(40),
         "flush rejects zero, reused, and lower generations");
  expect(ring.flush(42) && ring.generation() == 42 && ring.queuedSlabs() == 0,
         "quiescent flush advances and drops queued plus partial state");
  expect(ring.publish(41, oldAudio, 4) ==
             NativePcmRing::PublishResult::StaleGeneration,
         "old producer cannot republish after a seek");

  const std::array<float, 4> freshAudio{8.0F, -8.0F, 9.0F, -9.0F};
  expect(ring.publish(42, freshAudio, 2) ==
             NativePcmRing::PublishResult::Published,
         "fresh generation publishes after reset");
  std::array<float, 4> staleCallbackOutput{};
  staleCallbackOutput.fill(73.0F);
  const auto staleCallback = ring.consume(41, staleCallbackOutput);
  expect(staleCallback.staleConsumer && allEqual(staleCallbackOutput, 0.0F) &&
             ring.queuedSlabs() == 1,
         "stale callback receives silence without draining fresh audio");

  std::array<float, 4> freshOutput{};
  const auto fresh = ring.consume(42, freshOutput);
  expect(fresh.pcmFrames == 2 && !fresh.underrun && freshOutput == freshAudio,
         "fresh callback sees only fresh audio from frame zero");
  expect(ring.flush(43) && !ring.flush(42) && !ring.flush(43),
         "repeated reset advances strictly and rejects reuse");

  NativePcmRing exhausted(std::numeric_limits<std::uint64_t>::max());
  expect(!exhausted.flush(std::numeric_limits<std::uint64_t>::max()) &&
             !exhausted.flush(1),
         "maximum generation fails closed instead of wrapping");

  // Normal flush discards old slabs. This seam deliberately leaves one queued
  // while changing the epoch to prove the consumer's per-slab tag check.
  NativePcmRing injectedStale(51);
  const std::array<float, 2> staleFrame{6.0F, -6.0F};
  expect(injectedStale.publish(51, staleFrame, 1) ==
             NativePcmRing::PublishResult::Published,
         "stale-slab fixture publishes");
  NativePcmRingTestAccess::setGenerationWithoutFlush(injectedStale, 52);
  std::array<float, 2> rejectedStale{81.0F, 81.0F};
  const auto staleSlab = injectedStale.consume(52, rejectedStale);
  expect(staleSlab.staleSlabs == 1 && staleSlab.pcmFrames == 0 &&
             staleSlab.silentFrames == 1 && staleSlab.underrun &&
             allEqual(rejectedStale, 0.0F) &&
             injectedStale.queuedSlabs() == 0 &&
             injectedStale.stats().staleSlabs == 1,
         "consumer drops tagged stale slab before rendering silence");

  const auto stats = ring.stats();
  expect(stats.successfulFlushes == 2 && stats.invalidFlushes == 5 &&
             stats.stalePublishes == 1 && stats.staleConsumers == 1,
         "epoch/reset statistics are exact");
}

void testSaturatingStatistics() {
  NativePcmRing ring(100);
  const std::uint64_t almostMaximum =
      std::numeric_limits<std::uint64_t>::max() - 1;
  NativePcmRingTestAccess::setAllCounters(ring, almostMaximum);

  std::array<float, 2> frame{1.0F, -1.0F};
  expect(ring.publish(100, frame, 1) == NativePcmRing::PublishResult::Published,
         "saturation fixture publishes first frame");
  expect(ring.publish(100, std::span<const float>(frame).first(1), 1) ==
             NativePcmRing::PublishResult::Invalid,
         "saturation fixture increments invalid producer counter");
  for (std::size_t index = 1; index < NativePcmRing::kSlabCount; ++index) {
    expect(ring.publish(100, frame, 1) ==
               NativePcmRing::PublishResult::Published,
           "saturation fixture fills remaining slabs");
  }
  expect(ring.publish(100, frame, 1) == NativePcmRing::PublishResult::Full,
         "saturation fixture increments full counter");
  expect(ring.publish(99, frame, 1) ==
             NativePcmRing::PublishResult::StaleGeneration,
         "saturation fixture increments stale producer counter");
  expect(ring.flush(101) && !ring.flush(101),
         "saturation fixture exercises both flush counters");

  expect(ring.publish(101, frame, 1) == NativePcmRing::PublishResult::Published,
         "saturation fixture publishes consumable frame");
  std::array<float, 4> underrunOutput{};
  const auto underrun = ring.consume(101, underrunOutput);
  expect(underrun.pcmFrames == 1 && underrun.silentFrames == 1 &&
             underrun.underrun,
         "saturation fixture exercises consume, silence, and underrun");

  std::array<float, 2> staleConsumerOutput{};
  expect(ring.consume(100, staleConsumerOutput).staleConsumer,
         "saturation fixture exercises stale consumer counter");
  expect(ring.publish(101, frame, 1) == NativePcmRing::PublishResult::Published,
         "saturation fixture publishes tagged stale slab");
  NativePcmRingTestAccess::setGenerationWithoutFlush(ring, 102);
  std::array<float, 2> staleSlabOutput{};
  expect(ring.consume(102, staleSlabOutput).staleSlabs == 1,
         "saturation fixture exercises stale slab counter");
  std::array<float, 3> invalidOutput{};
  expect(ring.consume(102, invalidOutput).invalidInput,
         "saturation fixture exercises invalid consumer counter");

  const auto stats = ring.stats();
  const std::uint64_t maximum = std::numeric_limits<std::uint64_t>::max();
  expect(
      stats.publishedSlabs == maximum && stats.publishedFrames == maximum &&
          stats.fullPublishes == maximum && stats.stalePublishes == maximum &&
          stats.invalidPublishes == maximum &&
          stats.successfulFlushes == maximum &&
          stats.invalidFlushes == maximum && stats.consumedFrames == maximum &&
          stats.silentFrames == maximum && stats.underrunCallbacks == maximum &&
          stats.staleConsumers == maximum && stats.staleSlabs == maximum &&
          stats.invalidConsumers == maximum,
      "every lifetime statistic saturates instead of wrapping");
}

void testConcurrentProducerConsumerStress() {
  constexpr std::size_t kFramesPerTransfer = 64;
  constexpr std::size_t kTransfers = 20000;
  NativePcmRing ring(71);
  std::atomic<bool> failed{false};
  std::atomic<bool> producerFinished{false};
  std::atomic<bool> consumerFinished{false};

  std::thread producer([&] {
    std::array<float, kFramesPerTransfer * NativePcmRing::kChannels> input{};
    for (std::size_t transfer = 0; transfer < kTransfers; ++transfer) {
      const float value = static_cast<float>((transfer % 1024U) + 1U);
      input.fill(value);
      for (;;) {
        const auto published = ring.publish(71, input, kFramesPerTransfer);
        if (published == NativePcmRing::PublishResult::Published) {
          break;
        }
        if (published != NativePcmRing::PublishResult::Full) {
          failed.store(true, std::memory_order_relaxed);
          producerFinished.store(true, std::memory_order_release);
          return;
        }
        if (failed.load(std::memory_order_relaxed)) {
          producerFinished.store(true, std::memory_order_release);
          return;
        }
        std::this_thread::yield();
      }
    }
    producerFinished.store(true, std::memory_order_release);
  });

  std::thread consumer([&] {
    std::array<float, kFramesPerTransfer * NativePcmRing::kChannels> output{};
    for (std::size_t transfer = 0; transfer < kTransfers; ++transfer) {
      for (;;) {
        const auto consumed = ring.consume(71, output);
        if (consumed.pcmFrames == 0 && consumed.underrun) {
          if (failed.load(std::memory_order_relaxed)) {
            consumerFinished.store(true, std::memory_order_release);
            return;
          }
          std::this_thread::yield();
          continue;
        }
        if (consumed.pcmFrames != kFramesPerTransfer || consumed.underrun ||
            consumed.invalidInput || consumed.staleConsumer) {
          failed.store(true, std::memory_order_relaxed);
          consumerFinished.store(true, std::memory_order_release);
          return;
        }
        break;
      }

      const float expected = static_cast<float>((transfer % 1024U) + 1U);
      if (!allEqual(output, expected)) {
        failed.store(true, std::memory_order_relaxed);
        consumerFinished.store(true, std::memory_order_release);
        return;
      }
    }
    consumerFinished.store(true, std::memory_order_release);
  });

  while (!producerFinished.load(std::memory_order_acquire) ||
         !consumerFinished.load(std::memory_order_acquire)) {
    if (ring.stats().queuedSlabs > NativePcmRing::kSlabCount) {
      failed.store(true, std::memory_order_relaxed);
      break;
    }
    std::this_thread::yield();
  }

  producer.join();
  consumer.join();
  const auto stats = ring.stats();
  expect(!failed.load(std::memory_order_relaxed),
         "concurrent SPSC stress preserves every transfer");
  expect(stats.queuedSlabs == 0 && stats.publishedSlabs == kTransfers &&
             stats.publishedFrames == kTransfers * kFramesPerTransfer &&
             stats.consumedFrames == kTransfers * kFramesPerTransfer &&
             stats.stalePublishes == 0 && stats.invalidPublishes == 0 &&
             stats.staleConsumers == 0 && stats.staleSlabs == 0 &&
             stats.invalidConsumers == 0 && stats.unreadPcmBytes == 0 &&
             stats.peakUnreadPcmBytes > 0 &&
             stats.peakUnreadPcmBytes <= NativePcmRing::kPcmPayloadBytes,
         "concurrent stress ends drained with exact PCM accounting");
}

} // namespace

int main() {
  static_assert(NativePcmRing::kChannels == 2);
  static_assert(NativePcmRing::kFramesPerSlab == 4096);
  static_assert(NativePcmRing::kSlabCount == 4);
  static_assert(4U * 4096U * 2U * sizeof(float) == 131072U);
  static_assert(NativePcmRing::kPcmPayloadBytes == 128U * 1024U);
  static_assert(!std::is_copy_constructible_v<NativePcmRing>);
  static_assert(!std::is_move_constructible_v<NativePcmRing>);
  static_assert(
      std::is_trivially_copyable_v<NativePcmRing::ReadableFramesResult>);
  static_assert(std::is_standard_layout_v<NativePcmRing::ReadableFramesResult>);
  static_assert(std::is_trivially_copyable_v<NativePcmRing::ConsumeResult>);
  static_assert(std::is_standard_layout_v<NativePcmRing::ConsumeResult>);
  static_assert(std::is_trivially_copyable_v<NativePcmRing::Stats>);
  static_assert(std::is_standard_layout_v<NativePcmRing::Stats>);
  static_assert(noexcept(std::declval<NativePcmRing &>().consume(
      std::uint64_t{}, std::declval<std::span<float>>())));
  static_assert(noexcept(
      std::declval<const NativePcmRing &>().readableFrames(std::uint64_t{})));
  static_assert(noexcept(std::declval<NativePcmRing &>().publish(
      std::uint64_t{}, std::declval<std::span<const float>>(), std::size_t{})));
  static_assert(
      noexcept(std::declval<NativePcmRing &>().flush(std::uint64_t{})));
  static_assert(noexcept(std::declval<const NativePcmRing &>().stats()));
  static_assert(noexcept(
      std::declval<NativePcmRing &>().resetUnreadPcmByteHighWater(
          std::uint64_t{})));

  testValidationAndStaleConsumerSilence();
  testPartialReadsAndExactUnderrunTail();
  testReadableFramesPreflight();
  testFixedCapacityPhysicalAndCursorWraparound();
  testFullSizedSlab();
  testExactUnreadPcmByteAccounting();
  testGenerationResetAndStaleSlabs();
  testSaturatingStatistics();
  testConcurrentProducerConsumerStress();

  if (failures != 0) {
    std::cerr << failures << " native PCM ring checks failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "native PCM ring checks passed\n";
  return EXIT_SUCCESS;
}
