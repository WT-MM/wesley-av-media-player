#include "platform/macos/native_surface_budget.hpp"
#include "support/expect.hpp"

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

namespace {

using wam::macos::NativeSurfaceBudget;
using wam::macos::NativeSurfaceBudgetStats;
using wam::macos::NativeSurfaceBudgetTestAccess;
using wam::macos::NativeSurfaceBudgetTestInterleavePoint;
using wam::macos::NativeSurfaceBudgetToken;
using wam::macos::kNativeSurfaceBudgetMaximumBytes;
using wam::macos::kNativeSurfaceBudgetMaximumSurfaces;
using wam::macos::kNativeSurfaceBudgetProcessMaximumBytes;
using wam::macos::kNativeSurfaceBudgetProcessMaximumSurfaces;

void checkStats(std::uint64_t currentSurfaces, std::uint64_t currentBytes,
                std::uint64_t peakSurfaces, std::uint64_t peakBytes,
                std::uint64_t rejections) {
  const NativeSurfaceBudgetStats stats = NativeSurfaceBudget::stats();
  EXPECT(stats.currentSurfaces == currentSurfaces);
  EXPECT(stats.currentBytes == currentBytes);
  EXPECT(stats.peakSurfaces == peakSurfaces);
  EXPECT(stats.peakBytes == peakBytes);
  EXPECT(stats.rejections == rejections);
}

void resetBudget() { EXPECT(NativeSurfaceBudgetTestAccess::reset()); }

void testInvalidIdentitiesFailClosed() {
  EXPECT(kNativeSurfaceBudgetMaximumBytes == 384ULL * 1024 * 1024);
  EXPECT(wam::macos::kNativeSurfaceBudgetWorstCaseSurfaceBytes == 40'132'608);
  EXPECT(wam::macos::kNativeSurfaceBudget420SurfaceBytes == 30'107'648);

  resetBudget();
  EXPECT(!NativeSurfaceBudgetTestAccess::tryAcquire(0, 1));
  EXPECT(!NativeSurfaceBudgetTestAccess::tryAcquire(1, 0));
  EXPECT(!NativeSurfaceBudgetTestAccess::tryAcquire(
      1, std::numeric_limits<std::uint64_t>::max()));
  EXPECT(!NativeSurfaceBudget::tryAcquire(nullptr));
  checkStats(0, 0, 0, 0, 4);
}

void testAliasesChargeExactlyOnce() {
  resetBudget();
  auto first = NativeSurfaceBudgetTestAccess::tryAcquire(11, 4096);
  auto alias = NativeSurfaceBudgetTestAccess::tryAcquire(11, 4096);
  EXPECT(first);
  EXPECT(alias);
  EXPECT(first.surfaceID() == 11);
  EXPECT(first.bytes() == 4096);
  checkStats(1, 4096, 1, 4096, 0);

  auto inconsistent = NativeSurfaceBudgetTestAccess::tryAcquire(11, 8192);
  EXPECT(!inconsistent);
  checkStats(1, 4096, 1, 4096, 1);
  first.reset();
  checkStats(1, 4096, 1, 4096, 1);
  alias.reset();
  checkStats(0, 0, 1, 4096, 1);

  // The same numeric IOSurfaceID may eventually be recycled by the OS. Once
  // every prior token is gone, a new publication with a new size is legal and
  // must be charged as a fresh unique surface.
  auto recycled = NativeSurfaceBudgetTestAccess::tryAcquire(11, 8192);
  EXPECT(recycled);
  checkStats(1, 8192, 1, 8192, 1);
  recycled.reset();
}

void testUniqueSurfaceLimitAndReuse() {
  // The pool the ledger enforces is the PROCESS pool -- N player windows'
  // worth of per-session complements -- so filling it takes that many unique
  // surfaces, not one session's ten. The per-session complement is still what
  // each session's own lease ledgers bound it to; that is asserted in
  // native_video_consumer, not here.
  resetBudget();
  constexpr std::uint64_t kPool = kNativeSurfaceBudgetProcessMaximumSurfaces;
  static_assert(kPool >= kNativeSurfaceBudgetMaximumSurfaces,
                "the process pool must hold at least one session's share");
  NativeSurfaceBudgetToken tokens[kPool];
  for (std::uint64_t index = 0; index < kPool; ++index) {
    tokens[index] = NativeSurfaceBudgetTestAccess::tryAcquire(
        static_cast<std::uint32_t>(100 + index), 1024);
    EXPECT(tokens[index]);
  }
  checkStats(kPool, kPool * 1024, kPool, kPool * 1024, 0);
  EXPECT(!NativeSurfaceBudgetTestAccess::tryAcquire(999, 1024));
  checkStats(kPool, kPool * 1024, kPool, kPool * 1024, 1);

  tokens[4].reset();
  auto replacement = NativeSurfaceBudgetTestAccess::tryAcquire(1000, 2048);
  EXPECT(replacement);
  checkStats(kPool, (kPool + 1) * 1024, kPool, (kPool + 1) * 1024, 1);
  replacement.reset();
  for (auto &token : tokens) {
    token.reset();
  }
  checkStats(0, 0, kPool, (kPool + 1) * 1024, 1);
}

void testExactByteBoundary() {
  resetBudget();
  auto first = NativeSurfaceBudgetTestAccess::tryAcquire(
      201, kNativeSurfaceBudgetProcessMaximumBytes - 1024);
  auto last = NativeSurfaceBudgetTestAccess::tryAcquire(202, 1024);
  EXPECT(first);
  EXPECT(last);
  checkStats(2, kNativeSurfaceBudgetProcessMaximumBytes, 2,
             kNativeSurfaceBudgetProcessMaximumBytes, 0);
  EXPECT(!NativeSurfaceBudgetTestAccess::tryAcquire(203, 1));
  checkStats(2, kNativeSurfaceBudgetProcessMaximumBytes, 2,
             kNativeSurfaceBudgetProcessMaximumBytes, 1);
  first.reset();
  last.reset();
  checkStats(0, 0, 2, kNativeSurfaceBudgetProcessMaximumBytes, 1);

  resetBudget();
  auto whole = NativeSurfaceBudgetTestAccess::tryAcquire(
      204, kNativeSurfaceBudgetProcessMaximumBytes);
  EXPECT(whole);
  checkStats(1, kNativeSurfaceBudgetProcessMaximumBytes, 1,
             kNativeSurfaceBudgetProcessMaximumBytes, 0);
  whole.reset();
  checkStats(0, 0, 1, kNativeSurfaceBudgetProcessMaximumBytes, 0);
}

void testCopyMoveAndReferenceOverflow() {
  resetBudget();
  auto original = NativeSurfaceBudgetTestAccess::tryAcquire(301, 16384);
  EXPECT(original);
  NativeSurfaceBudgetToken copy(original);
  EXPECT(copy);
  NativeSurfaceBudgetToken assigned;
  assigned = copy;
  EXPECT(assigned);
  NativeSurfaceBudgetToken moved(std::move(copy));
  EXPECT(moved);
  EXPECT(!copy);
  NativeSurfaceBudgetToken moveAssigned;
  moveAssigned = std::move(assigned);
  EXPECT(moveAssigned);
  EXPECT(!assigned);
  checkStats(1, 16384, 1, 16384, 0);

  original.reset();
  moved.reset();
  checkStats(1, 16384, 1, 16384, 0);
  EXPECT(NativeSurfaceBudgetTestAccess::forceReferenceCount(
      moveAssigned, std::numeric_limits<std::uint32_t>::max()));
  NativeSurfaceBudgetToken overflowCopy(moveAssigned);
  EXPECT(!overflowCopy);
  EXPECT(!NativeSurfaceBudgetTestAccess::tryAcquire(301, 16384));
  checkStats(1, 16384, 1, 16384, 2);

  auto destination =
      NativeSurfaceBudgetTestAccess::tryAcquire(302, 8192);
  EXPECT(destination);
  destination = moveAssigned;
  EXPECT(destination);
  EXPECT(destination.surfaceID() == 302);
  EXPECT(destination.bytes() == 8192);
  checkStats(2, 24576, 2, 24576, 3);

  EXPECT(
      NativeSurfaceBudgetTestAccess::forceReferenceCount(moveAssigned, 1));
  moveAssigned.reset();
  destination.reset();
  checkStats(0, 0, 2, 24576, 3);
}

struct AbaInterleave final {
  std::atomic<std::uint32_t> phase{0};
  std::atomic<std::uint32_t> permission{0};
};

void abaInterleaveHook(NativeSurfaceBudgetTestInterleavePoint point,
                       void *context) noexcept {
  auto &interleave = *static_cast<AbaInterleave *>(context);
  const std::uint32_t phase =
      point == NativeSurfaceBudgetTestInterleavePoint::
                   BeforeRetainCompareExchange
          ? 1
          : 2;
  interleave.phase.store(phase, std::memory_order_release);
  interleave.phase.notify_one();
  while (interleave.permission.load(std::memory_order_acquire) < phase) {
    interleave.permission.wait(phase - 1, std::memory_order_relaxed);
  }
}

void waitForPhase(AbaInterleave &interleave, std::uint32_t phase) {
  while (interleave.phase.load(std::memory_order_acquire) < phase) {
    interleave.phase.wait(phase - 1, std::memory_order_relaxed);
  }
}

void permitPhase(AbaInterleave &interleave, std::uint32_t phase) {
  interleave.permission.store(phase, std::memory_order_release);
  interleave.permission.notify_one();
}

void testReusedPublicationAbaRefundsExactlyOnce() {
  resetBudget();
  auto firstPublication =
      NativeSurfaceBudgetTestAccess::tryAcquire(601, 4096);
  EXPECT(firstPublication);

  AbaInterleave interleave;
  NativeSurfaceBudgetTestAccess::setInterleaveHook(abaInterleaveHook,
                                                    &interleave);
  NativeSurfaceBudgetToken staleAcquisition;
  std::thread scanner([&] {
    staleAcquisition =
        NativeSurfaceBudgetTestAccess::tryAcquire(601, 4096);
  });

  waitForPhase(interleave, 1);
  firstPublication.reset();
  auto reusedPublication =
      NativeSurfaceBudgetTestAccess::tryAcquire(602, 8192);
  EXPECT(reusedPublication);
  permitPhase(interleave, 1);

  waitForPhase(interleave, 2);
  reusedPublication.reset();
  // The scanner still owns its provisional reference to publication 602.
  checkStats(1, 8192, 1, 8192, 0);
  permitPhase(interleave, 2);
  scanner.join();
  NativeSurfaceBudgetTestAccess::setInterleaveHook(nullptr, nullptr);

  EXPECT(!staleAcquisition);
  checkStats(0, 0, 1, 8192, 1);
  auto afterRefund =
      NativeSurfaceBudgetTestAccess::tryAcquire(603, 16384);
  EXPECT(afterRefund);
  checkStats(1, 16384, 1, 16384, 1);
  afterRefund.reset();
}

void testPublicationExhaustionFailsClosed() {
  resetBudget();
  EXPECT(NativeSurfaceBudgetTestAccess::forceNextPublication(
      std::numeric_limits<std::uint64_t>::max()));
  EXPECT(!NativeSurfaceBudgetTestAccess::tryAcquire(701, 1024));
  checkStats(0, 0, 0, 0, 1);

  resetBudget();
  auto recovered = NativeSurfaceBudgetTestAccess::tryAcquire(702, 1024);
  EXPECT(recovered);
  recovered.reset();
}

void testInsertionContentionFailsClosedButAliasesRemainAvailable() {
  resetBudget();
  auto anchor = NativeSurfaceBudgetTestAccess::tryAcquire(401, 32768);
  EXPECT(anchor);
  EXPECT(NativeSurfaceBudgetTestAccess::holdInsertionReservation());
  auto alias = NativeSurfaceBudgetTestAccess::tryAcquire(401, 32768);
  auto blocked = NativeSurfaceBudgetTestAccess::tryAcquire(402, 32768);
  EXPECT(alias);
  EXPECT(!blocked);
  NativeSurfaceBudgetTestAccess::releaseInsertionReservation();
  checkStats(1, 32768, 1, 32768, 1);
  alias.reset();
  anchor.reset();
}

void testConcurrentAliasesNeverDoubleCharge() {
  resetBudget();
  auto anchor = NativeSurfaceBudgetTestAccess::tryAcquire(501, 65536);
  EXPECT(anchor);

  constexpr std::size_t kThreads = 8;
  constexpr std::size_t kIterations = 2000;
  std::atomic<bool> start{false};
  std::atomic<std::uint64_t> successes{0};
  std::vector<std::thread> threads;
  threads.reserve(kThreads);
  for (std::size_t threadIndex = 0; threadIndex < kThreads; ++threadIndex) {
    threads.emplace_back([&] {
      while (!start.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
      for (std::size_t iteration = 0; iteration < kIterations; ++iteration) {
        auto acquired =
            NativeSurfaceBudgetTestAccess::tryAcquire(501, 65536);
        if (acquired) {
          NativeSurfaceBudgetToken copied(acquired);
          if (copied) {
            successes.fetch_add(1, std::memory_order_relaxed);
          }
        }
      }
    });
  }
  start.store(true, std::memory_order_release);
  for (std::thread &thread : threads) {
    thread.join();
  }
  EXPECT(successes.load(std::memory_order_relaxed) > 0);
  const NativeSurfaceBudgetStats stats = NativeSurfaceBudget::stats();
  EXPECT(stats.currentSurfaces == 1);
  EXPECT(stats.currentBytes == 65536);
  EXPECT(stats.peakSurfaces == 1);
  EXPECT(stats.peakBytes == 65536);
  anchor.reset();
  EXPECT(NativeSurfaceBudget::stats().currentSurfaces == 0);
  EXPECT(NativeSurfaceBudget::stats().currentBytes == 0);
}

} // namespace

int main() {
  static_assert(std::is_nothrow_default_constructible_v<
                NativeSurfaceBudgetToken>);
  static_assert(
      std::is_nothrow_copy_constructible_v<NativeSurfaceBudgetToken>);
  static_assert(std::is_nothrow_copy_assignable_v<NativeSurfaceBudgetToken>);
  static_assert(
      std::is_nothrow_move_constructible_v<NativeSurfaceBudgetToken>);
  static_assert(std::is_nothrow_move_assignable_v<NativeSurfaceBudgetToken>);
  static_assert(std::is_nothrow_destructible_v<NativeSurfaceBudgetToken>);

  testInvalidIdentitiesFailClosed();
  testAliasesChargeExactlyOnce();
  testUniqueSurfaceLimitAndReuse();
  testExactByteBoundary();
  testCopyMoveAndReferenceOverflow();
  testReusedPublicationAbaRefundsExactlyOnce();
  testPublicationExhaustionFailsClosed();
  testInsertionContentionFailsClosedButAliasesRemainAvailable();
  testConcurrentAliasesNeverDoubleCharge();
  if (failures == 0) {
    std::cout << "native surface budget tests passed\n";
  }
  return failures == 0 ? 0 : 1;
}
