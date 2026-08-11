#pragma once

#include "render_lifecycle.hpp"

#include <QString>

#include <atomic>
#include <memory>
#include <mutex>
#include <optional>

#include <mpv/client.h>
#include <mpv/render.h>

namespace wam::qt {

class PlayerController;
class PlayerControllerTestAccess;

// Private, shared lifetime boundary between the GUI controller and scene-graph
// render node. It ensures the mpv core cannot disappear while Qt is rendering.
class PlayerCore final {
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
    return render_lifecycle_.readyTicket();
  }
  [[nodiscard]] bool validateRenderTicket(RenderTicket ticket) const {
    return render_lifecycle_.validatesReady(ticket);
  }
  [[nodiscard]] bool renderFailureIsCurrent(RenderTicket ticket) const {
    return render_lifecycle_.validatesFailed(ticket);
  }
  bool retryFailedRenderContext();

  void detachOwner(PlayerController* owner);

  // These methods are called only from Qt Quick's OpenGL render thread.
  bool ensureRenderContext();
  void render(int framebuffer, int width, int height, bool flip_y);
  void releaseRenderContext();

 private:
  static void onMpvWakeup(void* context);
  static void onRenderUpdate(void* context);
  static void* getOpenGlProcAddress(void* context, const char* name);

  void queueEventDrain();
  void queueVideoUpdate();
  void notifyRenderingReady(RenderTicket ticket);
  void notifyRenderInvalidated(RenderTicket retired_ticket);
  void postInitializationError(const QString& error, RenderTicket ticket);

  mutable std::mutex owner_mutex_;
  PlayerController* owner_ = nullptr;
  std::mutex render_mutex_;
  mpv_handle* handle_ = nullptr;
  mpv_render_context* render_context_ = nullptr;
  RenderLifecycle render_lifecycle_;
  std::atomic<State> state_{State::Dormant};
  std::atomic<bool> event_drain_queued_{false};
  std::atomic<bool> video_update_queued_{false};
  QString initialization_error_;
};

}  // namespace wam::qt
