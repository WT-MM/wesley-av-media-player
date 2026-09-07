#include "native_open_preflight.hpp"

#import <Foundation/Foundation.h>
#include <cassert>
#include <thread>

#include <dispatch/dispatch.h>
#include <sys/mount.h>

#include <limits>
#include <mutex>
#include <utility>

namespace wam::macos {
namespace {

struct LocalSourceSnapshot final {
  std::string displaySource;
  std::string absolutePath;
  std::filesystem::path filesystemPath;
};

[[nodiscard]] LocalSourceSnapshot snapshotLocalSource(const std::string& source) {
  @autoreleasepool {
    NSString* text = [[NSString alloc] initWithBytes:source.data() length:source.size()
                                          encoding:NSUTF8StringEncoding];
    if (!text) return {source, {}, {}};
    NSURL* url = [NSURL URLWithString:text];
    NSString* localPath = nil;
    if (url.isFileURL) {
      localPath = url.path;
      if (!localPath && [text hasPrefix:@"file:"] && ![text hasPrefix:@"file://"])
        localPath = [[text substringFromIndex:5] stringByRemovingPercentEncoding];
    }
    else if (url.scheme.length == 0) localPath = [text stringByRemovingPercentEncoding];
    if (!localPath.length) return {source, {}, {}};
    const auto path = std::filesystem::absolute(
        std::filesystem::path(localPath.fileSystemRepresentation)).lexically_normal();
    NSURL* absoluteURL = [NSURL fileURLWithPath:
        [[NSString alloc] initWithUTF8String:path.c_str()]];
    return {absoluteURL.absoluteString.UTF8String, path.string(), path};
  }
}

[[nodiscard]] NativeSourceClass classifySource(const std::string&,
                                                const std::string& absolutePath) {
  if (absolutePath.empty()) return NativeSourceClass::Network;
  struct statfs mountInformation{};
  if (::statfs(absolutePath.c_str(), &mountInformation) != 0 ||
      (mountInformation.f_flags & MNT_LOCAL) == 0)
    return NativeSourceClass::BufferedLocal;
  return NativeSourceClass::FastLocal;
}

} // namespace

struct NativeOpenPreflightState final {
  using RequestId = NativeOpenPreflight::RequestId;

  struct Work final {
    RequestId id{0};
    NativeOpenPreflightRequest request;
  };

  explicit NativeOpenPreflightState(
      NativeOpenPreflight::Completion suppliedCompletion,
      NativeOpenPreflight::Dependencies suppliedDependencies)
      : ownerThread(std::this_thread::get_id()),
        completion(std::move(suppliedCompletion)),
        dependencies(std::move(suppliedDependencies)) {
    dispatch_queue_attr_t attributes =
        dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    workerQueue = dispatch_queue_create(
        "com.wesleymaa.wam.native-open-preflight", attributes);
  }

  ~NativeOpenPreflightState() {
#if !OS_OBJECT_USE_OBJC
    if (workerQueue != nullptr) {
      dispatch_release(workerQueue);
    }
#endif
  }

  std::mutex mutex;
  // Serializes the final validate-and-call edge against enqueue/cancel/stop.
  // It is recursive so a GUI completion may immediately enqueue or cancel a
  // request without deadlocking itself.
  std::recursive_mutex callbackMutex;
  const std::thread::id ownerThread;
  NativeOpenPreflight::Completion completion;
  NativeOpenPreflight::Dependencies dependencies;
  dispatch_queue_t workerQueue{nullptr};
  std::optional<Work> pending;
  std::optional<NativeOpenPreflightResult> result;
  RequestId nextId{0};
  RequestId latestId{0};
  bool workerScheduled{false};
  bool completionQueued{false};
  bool stopped{false};
};

namespace {

[[nodiscard]] NativeOpenPreflightResult
evaluate(const NativeOpenPreflightState::Work &work,
         const NativeOpenPreflight::Dependencies &dependencies) {
  if (dependencies.beforeEvaluate) {
    dependencies.beforeEvaluate(work.id);
  }

  LocalSourceSnapshot snapshot = snapshotLocalSource(work.request.source);
  const NativeSourceClass sourceClass =
      dependencies.classifySource
          ? dependencies.classifySource(snapshot.displaySource,
                                        snapshot.absolutePath)
          : classifySource(snapshot.displaySource, snapshot.absolutePath);
  auto initialPosition = macos::NativeMediaSession::preflightInitialPosition(
      work.request.initialPositionSeconds);
  const bool nativeEligible = work.request.nativeAdmissionAllowed &&
                              initialPosition.has_value() &&
                              !snapshot.filesystemPath.empty() &&
                              snapshot.filesystemPath.is_absolute() &&
                              (sourceClass == NativeSourceClass::FastLocal
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
                               || sourceClass == NativeSourceClass::BufferedLocal
#endif
                              );

  NativeOpenPreflightResult result;
  result.requestId = work.id;
  result.sourceKey = work.request.sourceKey;
  result.source = work.request.source;
  result.canonicalSource = std::move(snapshot.displaySource);
  result.absoluteLocalPath = std::move(snapshot.filesystemPath);
  result.sourceClass = sourceClass;
  result.route = nativeEligible
                     ? media::playback_router::Route::NativeEligibleLocal
                     : media::playback_router::Route::FallbackOnly;
  result.initialPositionSeconds = work.request.initialPositionSeconds;
  result.paused = work.request.paused;
  result.initialPosition = std::move(initialPosition);
  return result;
}

void deliver(const std::shared_ptr<NativeOpenPreflightState> &state) {
  assert(std::this_thread::get_id() == state->ownerThread);
  std::lock_guard callbackLock(state->callbackMutex);
  NativeOpenPreflight::Completion *completion = nullptr;
  std::optional<NativeOpenPreflightResult> result;
  try {
    {
      std::lock_guard lock(state->mutex);
      state->completionQueued = false;
      if (state->stopped || !state->result.has_value() ||
          state->result->requestId != state->latestId) {
        state->result.reset();
        return;
      }
      completion = &state->completion;
      result = std::move(state->result);
      state->result.reset();
    }
  } catch (...) {
    std::lock_guard lock(state->mutex);
    state->result.reset();
    return;
  }

  if (completion != nullptr && *completion && result.has_value()) {
    try {
      (*completion)(std::move(*result));
    } catch (...) {
      // A GUI completion cannot be allowed to unwind through libdispatch.
    }
  }
}

void queueDelivery(const std::shared_ptr<NativeOpenPreflightState> &state) {
  if (state->dependencies.queueCompletion) {
    std::function<void()> delivery = [state] { deliver(state); };
    state->dependencies.queueCompletion(std::move(delivery));
  } else {
    // Blocks capture reference-typed variables by reference, not by value, so
    // the shared State must first be copied into a non-reference local; the
    // copied block then retains that copy for the lifetime of the dispatch.
    const std::shared_ptr<NativeOpenPreflightState> retained = state;
    dispatch_async(dispatch_get_main_queue(), ^{
      deliver(retained);
    });
  }
}

void drain(const std::shared_ptr<NativeOpenPreflightState> &state) {
  for (;;) {
    std::optional<NativeOpenPreflightState::Work> work;
    {
      std::lock_guard lock(state->mutex);
      if (state->stopped || !state->pending.has_value()) {
        state->workerScheduled = false;
        return;
      }
      work = std::move(state->pending);
      state->pending.reset();
    }

    std::optional<NativeOpenPreflightResult> evaluated;
    try {
      evaluated = evaluate(*work, state->dependencies);
    } catch (...) {
      NativeOpenPreflightResult failure;
      failure.requestId = work->id;
      failure.sourceKey = work->request.sourceKey;
      failure.source = work->request.source;
      failure.canonicalSource = work->request.source;
      failure.initialPositionSeconds = work->request.initialPositionSeconds;
      failure.paused = work->request.paused;
      failure.preflightFailed = true;
      evaluated = std::move(failure);
    }

    bool shouldQueue = false;
    {
      std::lock_guard lock(state->mutex);
      if (!state->stopped && evaluated.has_value() &&
          work->id == state->latestId) {
        state->result = std::move(evaluated);
        if (!state->completionQueued) {
          state->completionQueued = true;
          shouldQueue = true;
        }
      }
    }
    if (shouldQueue) {
      queueDelivery(state);
    }
  }
}

} // namespace

NativeOpenPreflight::NativeOpenPreflight(Completion completion)
    : NativeOpenPreflight(std::move(completion), {}) {}

NativeOpenPreflight::NativeOpenPreflight(Completion completion,
                                         Dependencies dependencies) {
  try {
    state_ = std::make_shared<NativeOpenPreflightState>(
        std::move(completion), std::move(dependencies));
    if (state_->workerQueue == nullptr) {
      state_.reset();
    }
  } catch (...) {
    state_.reset();
  }
}

NativeOpenPreflight::~NativeOpenPreflight() { stop(); }

std::optional<NativeOpenPreflight::RequestId>
NativeOpenPreflight::enqueue(NativeOpenPreflightRequest request) noexcept {
  const std::shared_ptr<NativeOpenPreflightState> state = state_;
  if (!state) {
    return std::nullopt;
  }
  assert(std::this_thread::get_id() == state->ownerThread);

  bool schedule = false;
  RequestId id = 0;
  try {
    std::lock_guard callbackLock(state->callbackMutex);
    {
      std::lock_guard lock(state->mutex);
      if (state->stopped ||
          state->nextId == std::numeric_limits<RequestId>::max()) {
        return std::nullopt;
      }
      id = ++state->nextId;
      state->latestId = id;
      state->pending = NativeOpenPreflightState::Work{id, std::move(request)};
      state->result.reset();
      if (!state->workerScheduled) {
        state->workerScheduled = true;
        schedule = true;
      }
    }

    if (schedule) {
      dispatch_async(state->workerQueue, ^{
        @autoreleasepool {
          drain(state);
        }
      });
    }
  } catch (...) {
    if (schedule) {
      std::lock_guard lock(state->mutex);
      state->workerScheduled = false;
      state->pending.reset();
      state->result.reset();
      state->latestId = 0;
    }
    return std::nullopt;
  }
  return id;
}

void NativeOpenPreflight::cancel() noexcept {
  const std::shared_ptr<NativeOpenPreflightState> state = state_;
  if (!state) {
    return;
  }
  assert(std::this_thread::get_id() == state->ownerThread);
  std::lock_guard callbackLock(state->callbackMutex);
  std::lock_guard lock(state->mutex);
  state->latestId = 0;
  state->pending.reset();
  state->result.reset();
}

void NativeOpenPreflight::stop() noexcept {
  const std::shared_ptr<NativeOpenPreflightState> state = state_;
  if (!state) {
    return;
  }
  assert(std::this_thread::get_id() == state->ownerThread);
  std::lock_guard callbackLock(state->callbackMutex);
  std::lock_guard lock(state->mutex);
  state->stopped = true;
  state->latestId = 0;
  state->pending.reset();
  state->result.reset();
  state->completion = {};
}

} // namespace wam::qt
