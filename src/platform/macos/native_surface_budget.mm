#include "native_surface_budget.hpp"

#include <IOSurface/IOSurface.h>

#include <array>
#include <atomic>
#include <limits>
#include <utility>

namespace wam::macos {
namespace {

constexpr std::uint64_t kFreePublication = 0;
constexpr std::uint64_t kReservingPublication = 1;
constexpr std::uint64_t kFirstPublishedGeneration = 2;
// One record per surface the whole PROCESS may hold, which with N player
// windows is N per-session complements. Still a fixed, statically sized table:
// nothing here allocates.
constexpr std::size_t kRecordCapacity =
    static_cast<std::size_t>(kNativeSurfaceBudgetProcessMaximumSurfaces);
constexpr std::size_t kMaximumAtomicAttempts = 64;

static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);

struct SurfaceRecord final {
  // Publication is the sole visibility boundary for the immutable identity
  // and byte fields. Values >= kFirstPublishedGeneration are never reused.
  std::atomic<std::uint64_t> publication{kFreePublication};
  std::atomic<std::uint32_t> surfaceID{0};
  std::atomic<std::uint64_t> bytes{0};
  std::atomic<std::uint32_t> references{0};
};

struct SurfaceBudgetState final {
  std::array<SurfaceRecord, kRecordCapacity> records{};
  // Serializes only the rare creation of a new unique record. It is a
  // nonblocking reservation, not a spin lock: contention rejects immediately.
  std::atomic<std::uint32_t> insertionReservation{0};
  std::atomic<std::uint64_t> nextPublication{kFirstPublishedGeneration};
  std::atomic<std::uint64_t> currentSurfaces{0};
  std::atomic<std::uint64_t> peakSurfaces{0};
  std::atomic<std::uint64_t> currentBytes{0};
  std::atomic<std::uint64_t> peakBytes{0};
  std::atomic<std::uint64_t> rejections{0};
};

constinit SurfaceBudgetState gSurfaceBudget;

#if defined(WAM_NATIVE_SURFACE_BUDGET_TESTING)
NativeSurfaceBudgetTestInterleaveHook gInterleaveHook = nullptr;
void *gInterleaveContext = nullptr;

void testInterleave(NativeSurfaceBudgetTestInterleavePoint point) noexcept {
  if (gInterleaveHook != nullptr) {
    gInterleaveHook(point, gInterleaveContext);
  }
}
#endif

enum class MatchResult : std::uint8_t {
  NotFound,
  Acquired,
  Rejected,
};

struct RawAcquisition final {
  SurfaceRecord *record{nullptr};
  std::uint64_t publication{0};
  std::uint32_t surfaceID{0};
  std::uint64_t bytes{0};
};

void saturatingIncrement(std::atomic<std::uint64_t> &value) noexcept {
  std::uint64_t current = value.load(std::memory_order_relaxed);
  for (std::size_t attempt = 0; attempt < kMaximumAtomicAttempts; ++attempt) {
    if (current == std::numeric_limits<std::uint64_t>::max()) {
      return;
    }
    if (value.compare_exchange_strong(current, current + 1,
                                      std::memory_order_relaxed,
                                      std::memory_order_relaxed)) {
      return;
    }
  }
}

void reject() noexcept { saturatingIncrement(gSurfaceBudget.rejections); }

void updatePeak(std::atomic<std::uint64_t> &peak,
                std::uint64_t candidate) noexcept {
  std::uint64_t observed = peak.load(std::memory_order_relaxed);
  for (std::size_t attempt = 0;
       attempt < kMaximumAtomicAttempts && observed < candidate; ++attempt) {
    if (peak.compare_exchange_strong(observed, candidate,
                                     std::memory_order_relaxed,
                                     std::memory_order_relaxed)) {
      return;
    }
  }
}

void releaseRetainedPublication(SurfaceRecord &record,
                                std::uint64_t publication) noexcept;

bool tryRetainPublication(SurfaceRecord &record,
                          std::uint64_t publication) noexcept {
  if (publication < kFirstPublishedGeneration ||
      record.publication.load(std::memory_order_acquire) != publication) {
    return false;
  }

  std::uint32_t references =
      record.references.load(std::memory_order_relaxed);
  for (std::size_t attempt = 0; attempt < kMaximumAtomicAttempts; ++attempt) {
    if (references == 0 ||
        references == std::numeric_limits<std::uint32_t>::max()) {
      return false;
    }
#if defined(WAM_NATIVE_SURFACE_BUDGET_TESTING)
    testInterleave(
        NativeSurfaceBudgetTestInterleavePoint::BeforeRetainCompareExchange);
#endif
    if (record.references.compare_exchange_strong(
            references, references + 1, std::memory_order_acq_rel,
            std::memory_order_relaxed)) {
      // A source token makes this check invariantly true for token copies.
      // A source-less table scan can race final retirement and slot reuse, so
      // it must verify the never-reused generation after taking its reference.
      if (record.publication.load(std::memory_order_acquire) == publication) {
        return true;
      }

      // The CAS landed on a later publication after an ABA of `references`.
      // Its exact publication is stable because our newly acquired reference
      // prevents that record from retiring. Roll it back through the same
      // final-release path as a real token, so an intervening release of the
      // new publication's source token cannot strand a zero-reference charge.
      const std::uint64_t retainedPublication =
          record.publication.load(std::memory_order_acquire);
      if (retainedPublication >= kFirstPublishedGeneration) {
#if defined(WAM_NATIVE_SURFACE_BUDGET_TESTING)
        testInterleave(NativeSurfaceBudgetTestInterleavePoint::
                           BeforeMismatchedRetainRelease);
#endif
        releaseRetainedPublication(record, retainedPublication);
      } else {
        // New records publish their generation before changing references from
        // zero to one. Therefore a successful 1->2 CAS cannot observe either
        // sentinel here. Preserve the charge if that invariant is ever broken.
        reject();
      }
      return false;
    }
  }
  return false;
}

MatchResult tryAcquirePublished(std::uint32_t surfaceID, std::uint64_t bytes,
                                RawAcquisition &acquisition) noexcept {
  for (SurfaceRecord &record : gSurfaceBudget.records) {
    const std::uint64_t publication =
        record.publication.load(std::memory_order_acquire);
    if (publication < kFirstPublishedGeneration) {
      continue;
    }
    if (record.surfaceID.load(std::memory_order_relaxed) != surfaceID) {
      continue;
    }

    const std::uint64_t publishedBytes =
        record.bytes.load(std::memory_order_relaxed);
    if (record.publication.load(std::memory_order_acquire) != publication) {
      continue;
    }
    if (publishedBytes != bytes) {
      return MatchResult::Rejected;
    }
    if (!tryRetainPublication(record, publication)) {
      // The record was saturated, retired, or contended. Retrying through a
      // new record could double-charge the same live IOSurface, so fail closed.
      return MatchResult::Rejected;
    }

    acquisition = RawAcquisition{&record, publication, surfaceID, bytes};
    return MatchResult::Acquired;
  }
  return MatchResult::NotFound;
}

bool tryHoldInsertionReservation() noexcept {
  std::uint32_t expected = 0;
  return gSurfaceBudget.insertionReservation.compare_exchange_strong(
      expected, 1, std::memory_order_acquire, std::memory_order_relaxed);
}

void releaseInsertionReservation() noexcept {
  gSurfaceBudget.insertionReservation.store(0, std::memory_order_release);
}

bool takeNextPublication(std::uint64_t &publication) noexcept {
  const std::uint64_t next =
      gSurfaceBudget.nextPublication.load(std::memory_order_relaxed);
  if (next < kFirstPublishedGeneration ||
      next == std::numeric_limits<std::uint64_t>::max()) {
    return false;
  }
  publication = next;
  gSurfaceBudget.nextPublication.store(next + 1, std::memory_order_relaxed);
  return true;
}

bool hasBudgetFor(std::uint64_t bytes) noexcept {
  const std::uint64_t surfaces =
      gSurfaceBudget.currentSurfaces.load(std::memory_order_relaxed);
  const std::uint64_t currentBytes =
      gSurfaceBudget.currentBytes.load(std::memory_order_relaxed);
  return surfaces < kNativeSurfaceBudgetProcessMaximumSurfaces &&
         currentBytes <= kNativeSurfaceBudgetProcessMaximumBytes &&
         bytes <= kNativeSurfaceBudgetProcessMaximumBytes - currentBytes;
}

RawAcquisition tryAcquireIdentityRaw(std::uint32_t surfaceID,
                                     std::uint64_t bytes) noexcept {
  RawAcquisition acquisition;
  if (surfaceID == 0 || bytes == 0 ||
      bytes > kNativeSurfaceBudgetProcessMaximumBytes) {
    reject();
    return acquisition;
  }

  MatchResult match = tryAcquirePublished(surfaceID, bytes, acquisition);
  if (match == MatchResult::Acquired) {
    return acquisition;
  }
  if (match == MatchResult::Rejected) {
    reject();
    return {};
  }

  if (!tryHoldInsertionReservation()) {
    reject();
    return {};
  }

  // A competing creator may have published this identity immediately before
  // we acquired the reservation. Rescan before charging a new unique record.
  match = tryAcquirePublished(surfaceID, bytes, acquisition);
  if (match == MatchResult::Acquired) {
    releaseInsertionReservation();
    return acquisition;
  }
  if (match == MatchResult::Rejected || !hasBudgetFor(bytes)) {
    releaseInsertionReservation();
    reject();
    return {};
  }

  SurfaceRecord *freeRecord = nullptr;
  for (SurfaceRecord &record : gSurfaceBudget.records) {
    std::uint64_t expected = kFreePublication;
    if (record.publication.compare_exchange_strong(
            expected, kReservingPublication, std::memory_order_acq_rel,
            std::memory_order_relaxed)) {
      freeRecord = &record;
      break;
    }
  }
  if (freeRecord == nullptr) {
    releaseInsertionReservation();
    reject();
    return {};
  }

  std::uint64_t publication = 0;
  if (!takeNextPublication(publication)) {
    freeRecord->publication.store(kFreePublication, std::memory_order_release);
    releaseInsertionReservation();
    reject();
    return {};
  }

  freeRecord->surfaceID.store(surfaceID, std::memory_order_relaxed);
  freeRecord->bytes.store(bytes, std::memory_order_relaxed);

  // Only new-record creators add to these totals, and they are serialized by
  // insertionReservation. Concurrent final releases can only reduce them, so
  // the preflight cap remains conservative through these fetch-adds.
  const std::uint64_t currentBytes =
      gSurfaceBudget.currentBytes.fetch_add(bytes, std::memory_order_relaxed) +
      bytes;
  const std::uint64_t currentSurfaces =
      gSurfaceBudget.currentSurfaces.fetch_add(1, std::memory_order_relaxed) +
      1;
  updatePeak(gSurfaceBudget.peakBytes, currentBytes);
  updatePeak(gSurfaceBudget.peakSurfaces, currentSurfaces);

  // Publication must precede the transition from zero to one reference. An
  // old scanner can then either fail against zero or retain the fully
  // identifiable new publication and roll it back exactly; it can never CAS
  // an unpublished generation from one reference to two.
  freeRecord->publication.store(publication, std::memory_order_release);
  freeRecord->references.store(1, std::memory_order_release);
  releaseInsertionReservation();
  return RawAcquisition{freeRecord, publication, surfaceID, bytes};
}

void releaseRetainedPublication(SurfaceRecord &record,
                                std::uint64_t publication) noexcept {
  if (record.publication.load(std::memory_order_acquire) != publication) {
    reject();
    return;
  }

  // A valid token owns exactly one reference, so a single lock-free fetch_sub
  // cannot strand that reference under CAS contention. The final token
  // therefore performs the one and only budget refund.
  const std::uint32_t references =
      record.references.fetch_sub(1, std::memory_order_acq_rel);
  if (references == 0) {
    // Test-only corruption or a broken private invariant. Restore saturation
    // rather than allowing unsigned underflow to make the record reusable.
    record.references.store(std::numeric_limits<std::uint32_t>::max(),
                            std::memory_order_relaxed);
    reject();
    return;
  }
  if (references > 1) {
    return;
  }

  std::uint64_t expectedPublication = publication;
  if (!record.publication.compare_exchange_strong(
          expectedPublication, kReservingPublication,
          std::memory_order_acq_rel, std::memory_order_relaxed)) {
    // Preserve (rather than double-refund) accounting if an invariant is
    // violated. Correctly formed tokens cannot reach this branch.
    reject();
    return;
  }

  const std::uint64_t bytes = record.bytes.load(std::memory_order_relaxed);
  record.surfaceID.store(0, std::memory_order_relaxed);
  record.bytes.store(0, std::memory_order_relaxed);
  gSurfaceBudget.currentBytes.fetch_sub(bytes, std::memory_order_relaxed);
  gSurfaceBudget.currentSurfaces.fetch_sub(1, std::memory_order_relaxed);
  record.publication.store(kFreePublication, std::memory_order_release);
}

void releaseToken(void *opaqueRecord, std::uint64_t publication) noexcept {
  if (opaqueRecord == nullptr || publication < kFirstPublishedGeneration) {
    return;
  }
  releaseRetainedPublication(*static_cast<SurfaceRecord *>(opaqueRecord),
                             publication);
}

} // namespace

NativeSurfaceBudgetToken::NativeSurfaceBudgetToken(
    void *record, std::uint64_t publication, std::uint32_t surfaceID,
    std::uint64_t bytes) noexcept
    : record_(record), publication_(publication), surface_id_(surfaceID),
      bytes_(bytes) {}

NativeSurfaceBudgetToken::~NativeSurfaceBudgetToken() noexcept { reset(); }

NativeSurfaceBudgetToken::NativeSurfaceBudgetToken(
    const NativeSurfaceBudgetToken &other) noexcept {
  retain(other);
}

NativeSurfaceBudgetToken &NativeSurfaceBudgetToken::operator=(
    const NativeSurfaceBudgetToken &other) noexcept {
  if (this == &other) {
    return *this;
  }
  if (!other) {
    reset();
    return *this;
  }
  NativeSurfaceBudgetToken replacement(other);
  if (!replacement) {
    return *this;
  }
  std::swap(record_, replacement.record_);
  std::swap(publication_, replacement.publication_);
  std::swap(surface_id_, replacement.surface_id_);
  std::swap(bytes_, replacement.bytes_);
  return *this;
}

NativeSurfaceBudgetToken::NativeSurfaceBudgetToken(
    NativeSurfaceBudgetToken &&other) noexcept
    : record_(std::exchange(other.record_, nullptr)),
      publication_(std::exchange(other.publication_, 0)),
      surface_id_(std::exchange(other.surface_id_, 0)),
      bytes_(std::exchange(other.bytes_, 0)) {}

NativeSurfaceBudgetToken &NativeSurfaceBudgetToken::operator=(
    NativeSurfaceBudgetToken &&other) noexcept {
  if (this == &other) {
    return *this;
  }
  reset();
  record_ = std::exchange(other.record_, nullptr);
  publication_ = std::exchange(other.publication_, 0);
  surface_id_ = std::exchange(other.surface_id_, 0);
  bytes_ = std::exchange(other.bytes_, 0);
  return *this;
}

void NativeSurfaceBudgetToken::retain(
    const NativeSurfaceBudgetToken &source) noexcept {
  if (source.record_ == nullptr) {
    return;
  }
  auto &record = *static_cast<SurfaceRecord *>(source.record_);
  // The source token's own reference guarantees that this publication cannot
  // reach zero and be recycled while its copy constructor is executing.
  if (!tryRetainPublication(record, source.publication_)) {
    reject();
    return;
  }
  record_ = source.record_;
  publication_ = source.publication_;
  surface_id_ = source.surface_id_;
  bytes_ = source.bytes_;
}

void NativeSurfaceBudgetToken::reset() noexcept {
  void *record = std::exchange(record_, nullptr);
  const std::uint64_t publication = std::exchange(publication_, 0);
  surface_id_ = 0;
  bytes_ = 0;
  releaseToken(record, publication);
}

NativeSurfaceBudgetToken
NativeSurfaceBudget::tryAcquire(CVPixelBufferRef pixelBuffer) noexcept {
  if (pixelBuffer == nullptr) {
    reject();
    return {};
  }
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
  if (surface == nullptr) {
    reject();
    return {};
  }
  const IOSurfaceID surfaceID = IOSurfaceGetID(surface);
  const std::size_t allocationSize = IOSurfaceGetAllocSize(surface);
  static_assert(sizeof(allocationSize) <= sizeof(std::uint64_t));
  return tryAcquireIdentity(static_cast<std::uint32_t>(surfaceID),
                            static_cast<std::uint64_t>(allocationSize));
}

NativeSurfaceBudgetToken NativeSurfaceBudget::tryAcquireIdentity(
    std::uint32_t surfaceID, std::uint64_t bytes) noexcept {
  const RawAcquisition acquisition =
      tryAcquireIdentityRaw(surfaceID, bytes);
  return NativeSurfaceBudgetToken(acquisition.record, acquisition.publication,
                                  acquisition.surfaceID, acquisition.bytes);
}

NativeSurfaceBudgetStats NativeSurfaceBudget::stats() noexcept {
  return NativeSurfaceBudgetStats{
      gSurfaceBudget.currentSurfaces.load(std::memory_order_relaxed),
      gSurfaceBudget.peakSurfaces.load(std::memory_order_relaxed),
      gSurfaceBudget.currentBytes.load(std::memory_order_relaxed),
      gSurfaceBudget.peakBytes.load(std::memory_order_relaxed),
      gSurfaceBudget.rejections.load(std::memory_order_relaxed),
  };
}

#if defined(WAM_NATIVE_SURFACE_BUDGET_TESTING)
NativeSurfaceBudgetToken NativeSurfaceBudgetTestAccess::tryAcquire(
    std::uint32_t surfaceID, std::uint64_t bytes) noexcept {
  return NativeSurfaceBudget::tryAcquireIdentity(surfaceID, bytes);
}

bool NativeSurfaceBudgetTestAccess::reset() noexcept {
  if (gSurfaceBudget.insertionReservation.load(std::memory_order_acquire) !=
      0) {
    return false;
  }
  for (SurfaceRecord &record : gSurfaceBudget.records) {
    if (record.publication.load(std::memory_order_acquire) !=
            kFreePublication ||
        record.references.load(std::memory_order_relaxed) != 0) {
      return false;
    }
  }
  if (gSurfaceBudget.currentSurfaces.load(std::memory_order_relaxed) != 0 ||
      gSurfaceBudget.currentBytes.load(std::memory_order_relaxed) != 0) {
    return false;
  }
  gSurfaceBudget.nextPublication.store(kFirstPublishedGeneration,
                                       std::memory_order_relaxed);
  gSurfaceBudget.currentSurfaces.store(0, std::memory_order_relaxed);
  gSurfaceBudget.peakSurfaces.store(0, std::memory_order_relaxed);
  gSurfaceBudget.currentBytes.store(0, std::memory_order_relaxed);
  gSurfaceBudget.peakBytes.store(0, std::memory_order_relaxed);
  gSurfaceBudget.rejections.store(0, std::memory_order_relaxed);
  return true;
}

bool NativeSurfaceBudgetTestAccess::holdInsertionReservation() noexcept {
  return tryHoldInsertionReservation();
}

void NativeSurfaceBudgetTestAccess::releaseInsertionReservation() noexcept {
  ::wam::macos::releaseInsertionReservation();
}

bool NativeSurfaceBudgetTestAccess::forceReferenceCount(
    NativeSurfaceBudgetToken &token,
    std::uint32_t referenceCount) noexcept {
  if (token.record_ == nullptr || referenceCount == 0) {
    return false;
  }
  auto &record = *static_cast<SurfaceRecord *>(token.record_);
  if (record.publication.load(std::memory_order_acquire) !=
      token.publication_) {
    return false;
  }
  record.references.store(referenceCount, std::memory_order_relaxed);
  return true;
}

bool NativeSurfaceBudgetTestAccess::forceNextPublication(
    std::uint64_t publication) noexcept {
  if (gSurfaceBudget.insertionReservation.load(std::memory_order_acquire) !=
      0) {
    return false;
  }
  for (SurfaceRecord &record : gSurfaceBudget.records) {
    if (record.publication.load(std::memory_order_acquire) !=
            kFreePublication ||
        record.references.load(std::memory_order_relaxed) != 0) {
      return false;
    }
  }
  if (gSurfaceBudget.currentSurfaces.load(std::memory_order_relaxed) != 0 ||
      gSurfaceBudget.currentBytes.load(std::memory_order_relaxed) != 0) {
    return false;
  }
  gSurfaceBudget.nextPublication.store(publication,
                                       std::memory_order_relaxed);
  return true;
}

void NativeSurfaceBudgetTestAccess::setInterleaveHook(
    NativeSurfaceBudgetTestInterleaveHook hook, void *context) noexcept {
  gInterleaveContext = context;
  gInterleaveHook = hook;
}
#endif

} // namespace wam::macos
