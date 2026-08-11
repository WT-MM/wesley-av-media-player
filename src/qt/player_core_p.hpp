#pragma once

#include <QString>

#include <atomic>
#include <memory>
#include <mutex>

#include <mpv/client.h>
#include <mpv/render.h>

namespace wam::qt {

class PlayerController;

// Private, shared lifetime boundary between the GUI controller and scene-graph
// render node. It ensures the mpv core cannot disappear while Qt is rendering.
class PlayerCore final {
 public:
  explicit PlayerCore(PlayerController* owner);
  ~PlayerCore();

  PlayerCore(const PlayerCore&) = delete;
  PlayerCore& operator=(const PlayerCore&) = delete;

  [[nodiscard]] bool available() const { return handle_ != nullptr; }
  [[nodiscard]] QString initializationError() const {
    return initialization_error_;
  }
  [[nodiscard]] mpv_handle* handle() const { return handle_; }
  [[nodiscard]] bool renderingReady() const {
    return rendering_ready_.load(std::memory_order_acquire);
  }

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
  void notifyRenderingReady();
  void postInitializationError(const QString& error);

  mutable std::mutex owner_mutex_;
  PlayerController* owner_ = nullptr;
  std::mutex render_mutex_;
  mpv_handle* handle_ = nullptr;
  mpv_render_context* render_context_ = nullptr;
  std::atomic<bool> event_drain_queued_{false};
  std::atomic<bool> video_update_queued_{false};
  std::atomic<bool> rendering_ready_{false};
  QString initialization_error_;
};

}  // namespace wam::qt
