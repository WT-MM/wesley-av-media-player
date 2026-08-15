#pragma once

#include "media/playback_router.hpp"
#include "platform/macos/native_media_session.hpp"
#include "qt/playback_policy.hpp"

#include <QString>
#include <QUrl>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>

namespace wam::qt {

struct NativeOpenPreflightState;

// Immutable GUI-thread snapshot for one open intent. Slow path resolution and
// mounted-filesystem classification happen only after this value crosses the
// worker edge. nativeAdmissionAllowed contains the cheap, exact GUI snapshot
// (surface present, ordinary playback rate) and is never recomputed off-thread.
struct NativeOpenPreflightRequest final {
  media::native_playback::SourceKey sourceKey{};
  QUrl source;
  double initialPositionSeconds{0.0};
  bool paused{true};
  bool nativeAdmissionAllowed{false};
};

// Exact result retained by the route owner. The initial-position token is the
// same rational conversion later consumed by NativeMediaSession::prepare(); it
// must not be reconstructed from initialPositionSeconds on the GUI thread.
struct NativeOpenPreflightResult final {
  std::uint64_t requestId{0};
  media::native_playback::SourceKey sourceKey{};
  QUrl source;
  // Canonical display/source identity resolved together with the absolute
  // path. For a relative filesystem request this is its absolute file URL;
  // protocol and already-local URLs retain their exact URL identity.
  QUrl canonicalSource;
  std::filesystem::path absoluteLocalPath;
  PlaybackSourceClass sourceClass{PlaybackSourceClass::Network};
  media::playback_router::Route route{
      media::playback_router::Route::FallbackOnly};
  double initialPositionSeconds{0.0};
  bool paused{true};
  // Resource-free worker admission can fail exceptionally; in that case the
  // exact request lineage still completes on the GUI edge with FallbackOnly.
  bool preflightFailed{false};
  std::optional<macos::NativeMediaSessionInitialPosition> initialPosition;
};

// Capacity-one asynchronous admission edge for macOS opens. At most one
// request is executing, one newer request is pending, and one exact result is
// waiting for its queued GUI delivery. New requests replace only the pending
// request/result; they never interrupt an executing filesystem call. The
// destructor invalidates shared state and returns without joining the worker.
// Construction, public methods, destruction, and Completion are confined to
// one GUI-owner thread; only immutable request values and shared State cross
// the worker edge. This keeps invalidation non-blocking while a filesystem
// call remains blocked and prevents a completion from racing its owner.
class NativeOpenPreflight final {
public:
  using RequestId = std::uint64_t;
  using Completion = std::function<void(NativeOpenPreflightResult)>;

  // Injectable boundaries keep concurrency, cancellation, and route mapping
  // deterministic in the focused headless test. Production leaves all three
  // empty and uses the real filesystem plus the main dispatch queue. The
  // injected queue must accept the closure and must not throw, matching
  // dispatch_async's required-delivery contract.
  struct Dependencies final {
    std::function<void(RequestId)> beforeEvaluate;
    std::function<PlaybackSourceClass(const QUrl &, const QString &)>
        classifySource;
    std::function<void(std::function<void()>)> queueCompletion;
  };

  explicit NativeOpenPreflight(Completion completion);
  NativeOpenPreflight(Completion completion, Dependencies dependencies);
  ~NativeOpenPreflight();

  NativeOpenPreflight(const NativeOpenPreflight &) = delete;
  NativeOpenPreflight &operator=(const NativeOpenPreflight &) = delete;
  NativeOpenPreflight(NativeOpenPreflight &&) = delete;
  NativeOpenPreflight &operator=(NativeOpenPreflight &&) = delete;

  // Returns the monotonic request identity only after the capacity-one intent
  // was retained and its single worker drain was (or already is) scheduled.
  [[nodiscard]] std::optional<RequestId>
  enqueue(NativeOpenPreflightRequest request) noexcept;

  // cancel() keeps the edge reusable while invalidating the running request,
  // pending request, and queued result. stop() is permanent and is also used
  // by the non-blocking destructor.
  void cancel() noexcept;
  void stop() noexcept;

private:
  std::shared_ptr<NativeOpenPreflightState> state_;
};

} // namespace wam::qt
