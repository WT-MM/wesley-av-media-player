#pragma once

#include "render_lifecycle.hpp"

#include <QPointer>
#include <QString>

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
  bool initialize();
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

  void detachOwner(PlayerController* owner);

  // These methods are called only from Qt Quick's OpenGL render thread.
  bool ensureRenderContext();
  void render(int framebuffer, int width, int height, bool flip_y);
  // Returns false only when a retained renderer belongs to a different or
  // already-destroyed OpenGL context. That fail-closed path invokes no
  // mpv_render_* function and keeps Busy/resources alive for an exact-owner
  // release (or process-lifetime quarantine if the owner was destroyed).
  bool releaseRenderContext();

 private:
  static void onMpvWakeup(void* context);
  static void onRenderUpdate(void* context);
  static void* getOpenGlProcAddress(void* context, const char* name);

  void queueEventDrain();
  void queueVideoUpdate();
  void notifyRenderingReady(RenderTicket ticket);
  void notifyRenderInvalidated(RenderTicket retired_ticket);
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
