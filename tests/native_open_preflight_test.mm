#include "qt/native_open_preflight.hpp"

#include <QCoreApplication>
#include <QUrl>

#include <algorithm>
#include <atomic>
#include <bit>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using wam::media::playback_router::Route;
using wam::qt::NativeOpenPreflight;
using wam::qt::NativeOpenPreflightRequest;
using wam::qt::NativeOpenPreflightResult;
using wam::qt::PlaybackSourceClass;

void expect(bool condition, const char *detail) {
  if (!condition) {
    throw std::runtime_error(detail);
  }
}

class ManualCompletionQueue final {
public:
  bool enqueue(std::function<void()> task) {
    {
      std::lock_guard lock(mutex_);
      tasks_.push_back(std::move(task));
    }
    condition_.notify_all();
    return true;
  }

  bool waitForTask(std::chrono::milliseconds timeout) {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, timeout,
                               [this] { return !tasks_.empty(); });
  }

  void drain() {
    std::vector<std::function<void()>> tasks;
    {
      std::lock_guard lock(mutex_);
      tasks.swap(tasks_);
    }
    for (auto &task : tasks) {
      task();
    }
  }

  [[nodiscard]] bool empty() const {
    std::lock_guard lock(mutex_);
    return tasks_.empty();
  }

private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::vector<std::function<void()>> tasks_;
};

class BlockingEvaluation final {
public:
  explicit BlockingEvaluation(std::uint64_t blockedId = 1)
      : blockedId_(blockedId) {}

  void enter(std::uint64_t id) {
    const unsigned active = active_.fetch_add(1, std::memory_order_acq_rel) + 1;
    unsigned observed = maximumActive_.load(std::memory_order_relaxed);
    while (observed < active && !maximumActive_.compare_exchange_weak(
                                    observed, active, std::memory_order_release,
                                    std::memory_order_relaxed)) {
    }
    {
      std::lock_guard lock(mutex_);
      evaluated_.push_back(id);
      if (id == blockedId_) {
        entered_ = true;
      }
    }
    condition_.notify_all();

    if (id == blockedId_) {
      std::unique_lock lock(mutex_);
      condition_.wait(lock, [this] { return released_; });
    }

    active_.fetch_sub(1, std::memory_order_acq_rel);
    {
      std::lock_guard lock(mutex_);
      if (id == blockedId_) {
        exited_ = true;
      }
    }
    condition_.notify_all();
  }

  bool waitUntilEntered(std::chrono::milliseconds timeout) {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, timeout, [this] { return entered_; });
  }

  bool waitUntilExited(std::chrono::milliseconds timeout) {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, timeout, [this] { return exited_; });
  }

  bool waitForEvaluationCount(std::size_t count,
                              std::chrono::milliseconds timeout) {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(
        lock, timeout, [this, count] { return evaluated_.size() >= count; });
  }

  void release() {
    {
      std::lock_guard lock(mutex_);
      released_ = true;
    }
    condition_.notify_all();
  }

  [[nodiscard]] unsigned maximumActive() const noexcept {
    return maximumActive_.load(std::memory_order_acquire);
  }

  [[nodiscard]] std::vector<std::uint64_t> evaluated() const {
    std::lock_guard lock(mutex_);
    return evaluated_;
  }

private:
  const std::uint64_t blockedId_;
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::atomic<unsigned> active_{0};
  std::atomic<unsigned> maximumActive_{0};
  std::vector<std::uint64_t> evaluated_;
  bool entered_{false};
  bool released_{false};
  bool exited_{false};
};

NativeOpenPreflight::Dependencies
dependencies(ManualCompletionQueue &queue,
             BlockingEvaluation *blocker = nullptr) {
  NativeOpenPreflight::Dependencies result;
  if (blocker != nullptr) {
    result.beforeEvaluate = [blocker](std::uint64_t id) { blocker->enter(id); };
  }
  result.classifySource = [](const QUrl &displaySource,
                             const QString &absolutePath) {
    if (!displaySource.isLocalFile()) {
      return PlaybackSourceClass::Network;
    }
    if (absolutePath.contains(QStringLiteral("buffered"))) {
      return PlaybackSourceClass::BufferedLocal;
    }
    return PlaybackSourceClass::FastLocal;
  };
  result.queueCompletion = [&queue](std::function<void()> completion) {
    static_cast<void>(queue.enqueue(std::move(completion)));
  };
  return result;
}

NativeOpenPreflight::Dependencies
productionClassificationDependencies(ManualCompletionQueue &queue) {
  NativeOpenPreflight::Dependencies result;
  result.queueCompletion = [&queue](std::function<void()> completion) {
    static_cast<void>(queue.enqueue(std::move(completion)));
  };
  return result;
}

NativeOpenPreflightRequest localRequest(const char *path,
                                        double initialPosition, bool paused,
                                        bool nativeAllowed = true) {
  return {{77},
          QUrl::fromLocalFile(QString::fromUtf8(path)),
          initialPosition,
          paused,
          nativeAllowed};
}

void capacityOneLatestRequestWins() {
  ManualCompletionQueue queue;
  BlockingEvaluation blocker;
  std::vector<NativeOpenPreflightResult> results;
  NativeOpenPreflight preflight(
      [&results](NativeOpenPreflightResult result) {
        results.push_back(std::move(result));
      },
      dependencies(queue, &blocker));

  const auto a = preflight.enqueue(
      localRequest("/private/tmp/wam-preflight-a.mp4", 0.125, true));
  expect(a == 1, "A receives the first monotonic identity");
  expect(blocker.waitUntilEntered(std::chrono::seconds(2)),
         "A enters the worker before replacement");

  const auto b = preflight.enqueue(
      localRequest("/private/tmp/wam-preflight-b.mp4", 1.25, true));
  const double exactInitial = 3.140625;
  const auto c = preflight.enqueue(
      localRequest("/private/tmp/wam-preflight-c.mp4", exactInitial, false));
  expect(b == 2 && c == 3, "replacement identities remain monotonic");

  blocker.release();
  expect(queue.waitForTask(std::chrono::seconds(2)),
         "latest result reaches one queued completion edge");
  expect(results.empty(), "completion is never invoked inline by the worker");
  queue.drain();

  expect(results.size() == 1 && results.front().requestId == *c,
         "blocked A and superseded B publish only exact C");
  expect(results.front().source == QUrl::fromLocalFile(QStringLiteral(
                                       "/private/tmp/wam-preflight-c.mp4")),
         "latest source identity survives the worker edge");
  expect(results.front().canonicalSource == results.front().source,
         "already-local source preserves exact canonical identity");
  const bool exactSecondsIdentity =
      std::bit_cast<std::uint64_t>(results.front().initialPositionSeconds) ==
      std::bit_cast<std::uint64_t>(exactInitial);
  const bool exactTokenIdentity =
      results.front().initialPosition.has_value() &&
      std::bit_cast<std::uint64_t>(
          results.front().initialPosition->seconds()) ==
          std::bit_cast<std::uint64_t>(exactInitial);
  expect(exactSecondsIdentity && exactTokenIdentity,
         "binary64 initial position and exact preflight token stay identical");
  expect(!results.front().paused,
         "latest paused intent crosses preflight without reconstruction");
  expect(results.front().route == Route::NativeEligibleLocal,
         "fast absolute local C maps to the native route");
  expect(results.front().absoluteLocalPath.is_absolute(),
         "local path is made absolute on the worker");

  const std::vector<std::uint64_t> evaluated = blocker.evaluated();
  expect(evaluated == std::vector<std::uint64_t>({1, 3}),
         "B is replaced in the sole pending slot before evaluation");
  expect(blocker.maximumActive() == 1,
         "one serial worker permits no concurrent classification");
}

void routeMappingIsExact() {
  ManualCompletionQueue queue;
  std::vector<NativeOpenPreflightResult> results;
  NativeOpenPreflight preflight(
      [&results](NativeOpenPreflightResult result) {
        results.push_back(std::move(result));
      },
      dependencies(queue));

  auto submitAndTake = [&](NativeOpenPreflightRequest request) {
    expect(preflight.enqueue(std::move(request)).has_value(),
           "route fixture is accepted");
    expect(queue.waitForTask(std::chrono::seconds(2)),
           "route fixture produces a queued result");
    queue.drain();
    expect(!results.empty(), "route fixture completion runs");
    NativeOpenPreflightResult result = std::move(results.back());
    results.clear();
    return result;
  };

  NativeOpenPreflightResult fast =
      submitAndTake(localRequest("relative-fast.mp4", 0.0, true));
  expect(fast.sourceClass == PlaybackSourceClass::FastLocal &&
             fast.route == Route::NativeEligibleLocal &&
             fast.absoluteLocalPath.is_absolute() &&
             fast.canonicalSource.isLocalFile() &&
             fast.canonicalSource.toLocalFile() ==
                 QString::fromStdString(fast.absoluteLocalPath.string()),
         "relative local path snapshots to absolute fast-native admission");

  NativeOpenPreflightResult buffered = submitAndTake(
      localRequest("/private/tmp/buffered-media.mp4", 0.0, false));
  expect(buffered.sourceClass == PlaybackSourceClass::BufferedLocal &&
             buffered.route == Route::FallbackOnly,
         "mounted/buffered local media maps to compatibility playback");

  NativeOpenPreflightResult network =
      submitAndTake({{77},
                     QUrl(QStringLiteral("https://example.invalid/media.mp4")),
                     7.0,
                     true,
                     true});
  expect(network.sourceClass == PlaybackSourceClass::Network &&
             network.route == Route::FallbackOnly &&
             network.absoluteLocalPath.empty(),
         "network media never manufactures a local path or native route");

  NativeOpenPreflightResult unavailable = submitAndTake(
      localRequest("/private/tmp/no-surface.mp4", 0.0, true, false));
  expect(unavailable.route == Route::FallbackOnly,
         "exact GUI admission snapshot can only demote native routing");

  NativeOpenPreflightResult invalid =
      submitAndTake(localRequest("/private/tmp/invalid-time.mp4", -1.0, true));
  expect(!invalid.initialPosition.has_value() &&
             invalid.route == Route::FallbackOnly,
         "invalid exact time preflight maps to fallback without rebuilding it");
}

void productionMountClassificationIsFailClosed() {
  ManualCompletionQueue queue;
  std::vector<NativeOpenPreflightResult> results;
  NativeOpenPreflight preflight(
      [&results](NativeOpenPreflightResult result) {
        results.push_back(std::move(result));
      },
      productionClassificationDependencies(queue));

  auto submitAndTake = [&](NativeOpenPreflightRequest request) {
    expect(preflight.enqueue(std::move(request)).has_value(),
           "production classification fixture is accepted");
    expect(queue.waitForTask(std::chrono::seconds(2)),
           "production classification produces a queued result");
    queue.drain();
    expect(results.size() == 1,
           "production classification publishes exactly one result");
    NativeOpenPreflightResult result = std::move(results.front());
    results.clear();
    return result;
  };

  const QString executablePath = QCoreApplication::applicationFilePath();
  expect(!executablePath.isEmpty(),
         "test executable supplies a real local mount path");
  NativeOpenPreflightResult local = submitAndTake(localRequest(
      executablePath.toUtf8().constData(), 0.0, true));
  expect(local.sourceClass == PlaybackSourceClass::FastLocal &&
             local.route == Route::NativeEligibleLocal &&
             local.canonicalSource.isLocalFile() &&
             local.absoluteLocalPath.is_absolute(),
         "a real local path is admitted from the native mount authority");

  const QString uninspectablePath =
      executablePath + QStringLiteral("/missing-media.mp4");
  NativeOpenPreflightResult uninspectable = submitAndTake(localRequest(
      uninspectablePath.toUtf8().constData(), 0.0, true));
  expect(uninspectable.sourceClass == PlaybackSourceClass::BufferedLocal &&
             uninspectable.route == Route::FallbackOnly &&
             uninspectable.canonicalSource.isLocalFile() &&
             uninspectable.absoluteLocalPath.is_absolute(),
         "an uninspectable local path fails closed to compatibility playback");
}

void queuedResultSlotKeepsOnlyLatestIdentity() {
  ManualCompletionQueue queue;
  BlockingEvaluation blocker(2);
  std::vector<NativeOpenPreflightResult> results;
  NativeOpenPreflight preflight(
      [&results](NativeOpenPreflightResult result) {
        results.push_back(std::move(result));
      },
      dependencies(queue, &blocker));

  expect(preflight.enqueue(localRequest("/private/tmp/result-a.mp4", 1.0, true))
             .has_value(),
         "first result-slot fixture is accepted");
  expect(queue.waitForTask(std::chrono::seconds(2)),
         "first exact result occupies the queued delivery slot");

  const auto latest =
      preflight.enqueue(localRequest("/private/tmp/result-b.mp4", 2.0, false));
  expect(latest == 2, "new result-slot intent has the next identity");
  expect(blocker.waitUntilEntered(std::chrono::seconds(2)),
         "B blocks before replacing the stale queued result");
  queue.drain();
  expect(results.empty(), "stale A edge publishes nothing while B evaluates");
  blocker.release();
  expect(blocker.waitUntilExited(std::chrono::seconds(2)),
         "B evaluation retires after the stale edge drains");
  expect(queue.waitForTask(std::chrono::seconds(2)),
         "B retention schedules a fresh exact delivery edge");
  queue.drain();

  expect(results.size() == 1 && results.front().requestId == *latest &&
             results.front().initialPositionSeconds == 2.0 &&
             !results.front().paused,
         "one queued result slot delivers only the exact newest identity");
}

void cancelIsReusableAndStopIsPermanent() {
  ManualCompletionQueue queue;
  BlockingEvaluation blocker;
  std::vector<NativeOpenPreflightResult> results;
  NativeOpenPreflight preflight(
      [&results](NativeOpenPreflightResult result) {
        results.push_back(std::move(result));
      },
      dependencies(queue, &blocker));

  expect(preflight.enqueue(localRequest("/private/tmp/cancel-a.mp4", 0.0, true))
             .has_value(),
         "cancel fixture is accepted");
  expect(blocker.waitUntilEntered(std::chrono::seconds(2)),
         "cancel fixture blocks in evaluation");
  preflight.cancel();
  blocker.release();
  expect(blocker.waitUntilExited(std::chrono::seconds(2)),
         "cancelled filesystem work is allowed to retire naturally");

  expect(
      preflight.enqueue(localRequest("/private/tmp/cancel-b.mp4", 2.0, false))
          .has_value(),
      "cancelled edge accepts a newer request");
  expect(queue.waitForTask(std::chrono::seconds(2)),
         "new post-cancel result is queued");
  queue.drain();
  expect(results.size() == 1 && results.front().requestId == 2 &&
             !results.front().paused,
         "cancelled result stays silent and the newer exact intent publishes");

  preflight.stop();
  expect(
      !preflight.enqueue(localRequest("/private/tmp/after-stop.mp4", 0.0, true))
           .has_value(),
      "permanent stop rejects later work");
}

void destructionNeverWaitsForFilesystemWork() {
  ManualCompletionQueue queue;
  BlockingEvaluation blocker;
  std::atomic<unsigned> completions{0};
  auto preflight = std::make_unique<NativeOpenPreflight>(
      [&completions](NativeOpenPreflightResult) {
        completions.fetch_add(1, std::memory_order_relaxed);
      },
      dependencies(queue, &blocker));
  expect(preflight
             ->enqueue(localRequest("/private/tmp/destruction.mp4", 0.0, true))
             .has_value(),
         "destruction fixture is accepted");
  expect(blocker.waitUntilEntered(std::chrono::seconds(2)),
         "destruction fixture is physically blocked off-thread");

  const auto started = std::chrono::steady_clock::now();
  preflight.reset();
  const auto elapsed = std::chrono::steady_clock::now() - started;
  expect(elapsed < std::chrono::milliseconds(100),
         "destructor invalidates state without joining blocked work");

  blocker.release();
  expect(blocker.waitUntilExited(std::chrono::seconds(2)),
         "detached blocked evaluation retires after owner destruction");
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  queue.drain();
  expect(completions.load(std::memory_order_acquire) == 0,
         "destroyed owner receives no late completion");
}

void evaluationExceptionCompletesAsFailure() {
  ManualCompletionQueue queue;
  std::vector<NativeOpenPreflightResult> results;
  NativeOpenPreflight::Dependencies dependencies;
  dependencies.classifySource = [](const QUrl &,
                                   const QString &) -> PlaybackSourceClass {
    throw std::runtime_error("injected classifier failure");
  };
  dependencies.queueCompletion = [&queue](std::function<void()> completion) {
    static_cast<void>(queue.enqueue(std::move(completion)));
  };
  NativeOpenPreflight preflight(
      [&results](NativeOpenPreflightResult result) {
        results.push_back(std::move(result));
      },
      std::move(dependencies));

  const auto accepted = preflight.enqueue(
      localRequest("/private/tmp/throwing-classifier.mp4", 4.0, false));
  expect(accepted.has_value(), "throwing classifier request is retained");
  expect(queue.waitForTask(std::chrono::seconds(2)),
         "evaluation exception still queues terminal completion");
  queue.drain();
  expect(results.size() == 1 && results.front().requestId == *accepted &&
             results.front().sourceKey.value == 77 &&
             results.front().source ==
                 QUrl::fromLocalFile(
                     QStringLiteral("/private/tmp/throwing-classifier.mp4")) &&
             results.front().initialPositionSeconds == 4.0 &&
             !results.front().paused && results.front().preflightFailed &&
             results.front().route == Route::FallbackOnly,
         "evaluation exception preserves exact lineage in one failure result");
}

} // namespace

int main(int argc, char **argv) {
  QCoreApplication application(argc, argv);
  try {
    capacityOneLatestRequestWins();
    routeMappingIsExact();
    productionMountClassificationIsFailClosed();
    queuedResultSlotKeepsOnlyLatestIdentity();
    cancelIsReusableAndStopIsPermanent();
    destructionNeverWaitsForFilesystemWork();
    evaluationExceptionCompletesAsFailure();
  } catch (const std::exception &error) {
    std::cerr << "native_open_preflight_test: " << error.what() << '\n';
    return 1;
  }
  std::cout << "native_open_preflight_test: passed\n";
  return 0;
}
