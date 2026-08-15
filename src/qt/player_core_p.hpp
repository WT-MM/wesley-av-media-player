#pragma once

#include "playback/mpv/mpv_runtime.hpp"
#include "render_lifecycle.hpp"

#include <QPointer>
#include <QString>
#include <QtGlobal>

#include <atomic>
#include <cstdint>
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
#include <functional>
#endif
#include <memory>
#include <mutex>
#include <optional>

#include <mpv/client.h>
#include <mpv/render.h>

class QOpenGLContext;

namespace wam::qt {

class PlayerController;
class PlayerControllerTestAccess;

// Private, shared lifetime boundary between the GUI controller and scene-graph
// render node. It ensures the mpv core cannot disappear while Qt is rendering.
class PlayerCore final : public std::enable_shared_from_this<PlayerCore> {
  friend class PlayerControllerTestAccess;

 private:
  enum class State : unsigned char { Dormant, Initializing, Ready, Failed };

 public:
  explicit PlayerCore(PlayerController* owner);
  ~PlayerCore();

  PlayerCore(const PlayerCore&) = delete;
  PlayerCore& operator=(const PlayerCore&) = delete;

  // Initializes libmpv on the controller's GUI thread. The render thread may
  // retain this wrapper while dormant, but it never initializes the engine.
  bool initialize(
      std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime);
  [[nodiscard]] bool ready() const {
    return state_.load(std::memory_order_acquire) == State::Ready;
  }
  [[nodiscard]] bool failed() const {
    return state_.load(std::memory_order_acquire) == State::Failed;
  }
  [[nodiscard]] QString initializationError() const {
    return initialization_error_;
  }
  [[nodiscard]] mpv_handle* handle() const {
    return ready() ? handle_ : nullptr;
  }
  [[nodiscard]] const ::wam::playback::mpv::MpvApi* readyApi() const noexcept {
    return ready() && runtime_ ? &runtime_->api() : nullptr;
  }
  [[nodiscard]] const ::wam::playback::mpv::MpvApi& api() const noexcept {
    const auto* const ready_api = readyApi();
    Q_ASSERT(ready_api != nullptr);
    return *ready_api;
  }
  [[nodiscard]] std::optional<RenderTicket> readyRenderTicket() const {
    if (!renderContextAllowed())
      return std::nullopt;
    const auto ticket = render_lifecycle_.readyTicket();
    return renderContextAllowed() ? ticket : std::nullopt;
  }
  [[nodiscard]] bool validateRenderTicket(RenderTicket ticket) const {
    if (!renderContextAllowed() ||
        !render_lifecycle_.validatesReady(ticket)) {
      return false;
    }
    return renderContextAllowed();
  }
  [[nodiscard]] bool renderFailureIsCurrent(RenderTicket ticket) const {
    if (!renderContextAllowed() ||
        !render_lifecycle_.validatesFailed(ticket)) {
      return false;
    }
    return renderContextAllowed();
  }
  bool retryFailedRenderContext();

  // Nonblocking ownership handshake for a future native presenter. Revoking
  // permission prevents new libmpv OpenGL contexts immediately. An in-flight
  // creation or active context remains Busy until the render thread discards
  // or releases it in its current OpenGL context. revokeRenderContext() does
  // not queue or wait for a Qt frame; a future activating controller must
  // schedule a scene-graph pass and observe Busy becoming false. Re-allowing
  // while Busy restores that sole reserved/active context; render_mutex_
  // prevents a second context from being created alongside it.
  void allowRenderContext() noexcept;
  void revokeRenderContext() noexcept;
  [[nodiscard]] bool renderContextAllowed() const noexcept;
  [[nodiscard]] bool renderContextBusy() const noexcept;
  [[nodiscard]] std::uint64_t renderContextCreateCount() const noexcept {
    return render_context_create_count_.load(std::memory_order_acquire);
  }
  // One acquire-load captures an exact lifecycle stamp. Callers must derive
  // both RenderLifecycle::phase() and generation() from this returned ticket
  // so admission/revocation decisions cannot mix two lifecycle states.
  // Observation never starts, retries, or invalidates a render context.
  [[nodiscard]] RenderTicket renderLifecycleSnapshot() const noexcept {
    return render_lifecycle_.snapshot();
  }

#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  // Exercises only the notification gate at ensureRenderContext() entry. The
  // shipping render path uses the same private predicate in full.
  [[nodiscard]] bool renderNotificationAllowsCreationForTesting() noexcept;
#endif

  void detachOwner(PlayerController* owner);

  // GUI-thread terminal fallback recovery. This is admitted only after
  // renderer permission is revoked and the exact GL lifecycle is Empty and
  // not Busy. Returning true means the mpv wakeup callback was cleared and
  // mpv_terminate_destroy returned; the wrapper is then detached/dormant and
  // may be replaced without waiting for a scene-graph-held shared reference.
  [[nodiscard]] bool retireFallbackAfterRenderRelease(
      PlayerController* owner) noexcept;

  // These methods are called only from Qt Quick's OpenGL render thread.
  bool ensureRenderContext();
  void render(int framebuffer, int width, int height, bool flip_y);
  // Returns false only when a retained renderer belongs to a different or
  // already-destroyed OpenGL context. That fail-closed path invokes no
  // mpv_render_* function and keeps Busy/resources alive for an exact-owner
  // release (or process-lifetime quarantine if the owner was destroyed).
  bool releaseRenderContext();

 private:
  static void onMpvWakeup(void* context) noexcept;
  static void onRenderUpdate(void* context) noexcept;
  static void* getOpenGlProcAddress(void* context, const char* name) noexcept;

  void queueEventDrain() noexcept;
  void queueVideoUpdate() noexcept;
  void notifyRenderingReady(RenderTicket ticket) noexcept;
  void notifyRenderInvalidated(RenderTicket retired_ticket) noexcept;
  void queueRenderNotificationDrain() noexcept;
  void drainRenderNotifications(PlayerController* expected_owner) noexcept;
  [[nodiscard]] bool hasPendingRenderInvalidation() noexcept;
  void postInitializationError(const QString& error,
                               RenderTicket ticket) noexcept;
  void postRenderInitializationErrorBestEffort(
      int result, bool missing_opengl_context,
      RenderTicket ticket) noexcept;
  [[nodiscard]] QOpenGLContext* currentOpenGlContext() const noexcept;
  [[nodiscard]] bool renderContextOwnerIsCurrentLocked() const noexcept;
  [[nodiscard]] bool commitRenderContextPermission(bool keep_busy) noexcept;
  void setRenderContextUpdateCallback(mpv_render_context* context,
                                      mpv_render_update_fn callback,
                                      void* callback_context) noexcept;
  void freeRenderContext(mpv_render_context* context) noexcept;
  [[nodiscard]] bool freeRenderContextResourceLocked(
      std::shared_ptr<PlayerCore>& deferred_keepalive) noexcept;
  [[nodiscard]] bool invalidateAndFreeRenderContextLocked(
      std::optional<RenderTicket>& retired_ticket,
      std::shared_ptr<PlayerCore>& deferred_keepalive) noexcept;
  void clearRenderContextBusy() noexcept;
  void terminateMpvHandle(mpv_handle* handle) noexcept;

  static constexpr std::uint8_t kRenderContextAllowed = 1U << 0;
  static constexpr std::uint8_t kRenderContextBusy = 1U << 1;

  mutable std::mutex owner_mutex_;
  PlayerController* owner_ = nullptr;
  std::mutex render_mutex_;
  // Set exactly once before the first client handle is created and retained
  // through every render-context keepalive. No libmpv object can outlive the
  // immutable table or the dynamically loaded image that implements it.
  std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime_;
  mpv_handle* handle_ = nullptr;
  mpv_render_context* render_context_ = nullptr;
  QPointer<QOpenGLContext> render_context_owner_;
  bool render_context_callback_installed_ = false;
  // A render context may be destroyed only with its exact creating GL context
  // current. Keep the entire callback target alive until that release; losing
  // the GL owner intentionally quarantines this cycle instead of invoking
  // undefined libmpv teardown or leaving callbacks aimed at freed memory.
  std::shared_ptr<PlayerCore> render_context_keepalive_;
  RenderLifecycle render_lifecycle_;
  std::atomic<std::uint8_t> render_context_permission_{
      kRenderContextAllowed};
  std::atomic<std::uint64_t> render_context_create_count_{0};
  std::atomic<State> state_{State::Dormant};
  std::atomic<bool> event_drain_queued_{false};
  std::atomic<bool> video_update_queued_{false};
  QString initialization_error_;

  // Render lifecycle transitions happen on Qt's scene-graph thread, while
  // their controller effects belong to the GUI thread. Keep the exact facts
  // until controller work succeeds: QMetaObject queueing may return false or
  // throw while allocating its functor, and a Ready lifecycle otherwise has
  // no reason to notify again. An undelivered invalidation gates replacement
  // creation, preserving invalidation-before-Ready ordering and bounding the
  // fixed-capacity state to one transition of each kind.
  std::mutex render_notification_mutex_;
  std::uint64_t pending_render_ready_stamp_ = 0;
  std::uint64_t pending_render_invalidation_stamp_ = 0;
  bool render_notification_drain_queued_ = false;

#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  std::function<void()> before_render_context_create_for_testing_;
  std::function<void()> after_render_context_api_for_testing_;
  std::function<void()> after_render_context_create_for_testing_;
  std::function<void()>
      before_render_context_error_diagnostic_for_testing_;
  std::function<int(mpv_render_context**, mpv_handle*, mpv_render_param*)>
      render_context_create_for_testing_;
  std::function<bool()> has_current_opengl_context_for_testing_;
  std::function<void(mpv_render_context*, mpv_render_update_fn, void*)>
      render_context_set_update_callback_for_testing_;
  std::function<void(mpv_render_context*)>
      render_context_free_for_testing_;
  std::function<void(mpv_handle*)> before_terminate_destroy_for_testing_;
  // Deterministic substitutes for QMetaObject::invokeMethod(). They model
  // both its false return and exceptions while copying/allocating a functor;
  // neither seam exists in the shipping target.
  std::function<bool()> queue_event_drain_for_testing_;
  std::function<bool()> queue_video_update_for_testing_;
  std::function<void()> drain_events_for_testing_;
  std::function<void()> request_video_update_for_testing_;
  std::function<bool()> queue_render_notification_for_testing_;
  std::function<void(std::uint64_t)>
      render_ready_work_for_testing_;
  std::function<void(std::uint64_t)>
      render_invalidation_work_for_testing_;
  std::atomic<std::uint64_t> render_context_free_count_for_testing_{0};
  std::atomic<std::uint64_t>
      render_context_ready_notify_count_for_testing_{0};
  std::atomic<std::uint64_t>
      render_context_invalidation_notify_count_for_testing_{0};
  std::atomic<std::uint64_t>
      render_context_error_notify_count_for_testing_{0};
#endif
};

}  // namespace wam::qt
