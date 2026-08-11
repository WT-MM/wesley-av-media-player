#include "player_core_p.hpp"

#include "player_controller.hpp"

#include <QByteArray>
#include <QDebug>
#include <QMetaObject>
#include <QOpenGLContext>
#include <QThread>
#include <QtGlobal>

#include <mpv/render_gl.h>

namespace wam::qt {
namespace {

bool setOption(mpv_handle *handle, const char *name, const char *value) {
  const int result = mpv_set_option_string(handle, name, value);
  if (result < 0) {
    qWarning().nospace() << "WAM: unable to set mpv option " << name << '='
                         << value << ": " << mpv_error_string(result);
    return false;
  }
  return true;
}

QByteArray experimentValue(const char *name) {
  return qgetenv(name).trimmed().toLower();
}

void warnUnknownExperimentValue(const char *name, const QByteArray &value,
                                const char *expected) {
  qWarning().noquote().nospace()
      << "WAM: ignoring " << name << "=\"" << QString::fromUtf8(value)
      << "\"; expected " << expected
      << ". Existing renderer defaults remain active.";
}

void logDefaultExperimentValue(const char *name) {
  qInfo().nospace() << "WAM: renderer experiment " << name
                    << "=default; no option override applied.";
}

void applyRendererExperiments(mpv_handle *handle) {
  if (qEnvironmentVariableIsSet("WAM_RENDER_PROFILE")) {
    const QByteArray profile = experimentValue("WAM_RENDER_PROFILE");
    if (profile == "fast" || profile == "efficient") {
      bool applied = true;
      applied &= setOption(handle, "scale", "bilinear");
      applied &= setOption(handle, "dscale", "bilinear");
      applied &= setOption(handle, "correct-downscaling", "no");
      applied &= setOption(handle, "linear-downscaling", "no");
      if (applied) {
        qInfo().noquote().nospace()
            << "WAM: active renderer selection WAM_RENDER_PROFILE="
            << QString::fromUtf8(profile)
            << ": scale=bilinear, dscale=bilinear,"
               " correct-downscaling=no, linear-downscaling=no.";
      } else {
        qWarning().noquote().nospace()
            << "WAM: WAM_RENDER_PROFILE=" << QString::fromUtf8(profile)
            << " was not fully applied.";
      }
    } else if (profile == "quality") {
      bool applied = true;
      applied &= setOption(handle, "scale", "spline36");
      applied &= setOption(handle, "dscale", "mitchell");
      applied &= setOption(handle, "correct-downscaling", "yes");
      applied &= setOption(handle, "linear-downscaling", "yes");
      applied &= setOption(handle, "sigmoid-upscaling", "yes");
      if (applied) {
        qInfo() << "WAM: active renderer selection"
                   " WAM_RENDER_PROFILE=quality: scale=spline36,"
                   " dscale=mitchell, correct-downscaling=yes,"
                   " linear-downscaling=yes, sigmoid-upscaling=yes.";
      } else {
        qWarning() << "WAM: WAM_RENDER_PROFILE=quality was not fully applied.";
      }
    } else if (profile == "default") {
      logDefaultExperimentValue("WAM_RENDER_PROFILE");
    } else {
      warnUnknownExperimentValue(
          "WAM_RENDER_PROFILE", profile,
          R"("default", "efficient", "fast", or "quality")");
    }
  }

  if (qEnvironmentVariableIsSet("WAM_VIDEO_SYNC")) {
    const QByteArray video_sync = experimentValue("WAM_VIDEO_SYNC");
    if (video_sync == "audio") {
      if (setOption(handle, "video-sync", "audio")) {
        qInfo() << "WAM: active renderer experiment WAM_VIDEO_SYNC=audio:"
                   " video-sync=audio.";
      } else {
        qWarning() << "WAM: WAM_VIDEO_SYNC=audio was not applied.";
      }
    } else if (video_sync == "display-resample") {
      if (setOption(handle, "video-sync", "display-resample")) {
        qInfo() << "WAM: active renderer selection"
                   " WAM_VIDEO_SYNC=display-resample.";
      } else {
        qWarning() << "WAM: WAM_VIDEO_SYNC=display-resample was not applied.";
      }
    } else if (video_sync == "default") {
      logDefaultExperimentValue("WAM_VIDEO_SYNC");
    } else {
      warnUnknownExperimentValue(
          "WAM_VIDEO_SYNC", video_sync,
          R"("default", "audio", or "display-resample")");
    }
  }

  if (qEnvironmentVariableIsSet("WAM_SDR_FBO_FORMAT")) {
    const QByteArray fbo_format = experimentValue("WAM_SDR_FBO_FORMAT");
    if (fbo_format == "rgb10_a2" || fbo_format == "rgba8") {
      if (setOption(handle, "fbo-format", fbo_format.constData())) {
        qInfo().noquote().nospace()
            << "WAM: active SDR-only renderer experiment "
               "WAM_SDR_FBO_FORMAT="
            << QString::fromUtf8(fbo_format)
            << ": fbo-format=" << QString::fromUtf8(fbo_format) << '.';
        qWarning() << "WAM: the SDR FBO experiment is process-wide; do not"
                      " use it to evaluate HDR media or output quality.";
      } else {
        qWarning().noquote().nospace()
            << "WAM: WAM_SDR_FBO_FORMAT=" << QString::fromUtf8(fbo_format)
            << " was not applied.";
      }
    } else if (fbo_format == "default") {
      logDefaultExperimentValue("WAM_SDR_FBO_FORMAT");
    } else {
      warnUnknownExperimentValue("WAM_SDR_FBO_FORMAT", fbo_format,
                                 R"("default", "rgb10_a2", or "rgba8")");
    }
  }
}

} // namespace

PlayerCore::PlayerCore(PlayerController *owner) : owner_(owner) {}

bool PlayerCore::initialize() {
  Q_ASSERT(!owner_ || QThread::currentThread() == owner_->thread());
  State expected = State::Dormant;
  if (!state_.compare_exchange_strong(expected, State::Initializing,
                                      std::memory_order_acq_rel))
    return expected == State::Ready;

  mpv_handle *candidate = mpv_create();
  if (!candidate) {
    initialization_error_ =
        QStringLiteral("Unable to create the media engine.");
    state_.store(State::Failed, std::memory_order_release);
    return false;
  }

  // The packaged application must behave identically regardless of a user's
  // standalone mpv configuration. Avoid loading user scripts, profiles, and
  // built-in overlays that WAM neither displays nor controls.
  setOption(candidate, "config", "no");
  setOption(candidate, "load-scripts", "no");
  setOption(candidate, "load-auto-profiles", "no");
  setOption(candidate, "load-stats-overlay", "no");
  setOption(candidate, "load-console", "no");
  setOption(candidate, "load-select", "no");
  setOption(candidate, "load-context-menu", "no");
  setOption(candidate, "load-commands", "no");
  setOption(candidate, "load-positioning", "no");

  // Keep mpv's own UI/input disabled: QML is the single UX layer. The render
  // API and hardware interop let supported decoders provide GPU-backed frames
  // instead of round-tripping them through CPU memory.
#ifdef __APPLE__
  // Qt owns the process-wide application/menu lifecycle. Prevent mpv's macOS
  // AppHub from installing its standalone-player activation policy, menu
  // shortcuts, and Touch Bar while initializing inside the Qt host.
  setOption(candidate, "macos-app-activation-policy", "prohibited");
  setOption(candidate, "macos-menu-shortcuts", "no");
#endif
  setOption(candidate, "vo", "libmpv");
  setOption(candidate, "hwdec", "auto-safe");
  setOption(candidate, "vd-lavc-dr", "auto");
  setOption(candidate, "gpu-hwdec-interop", "auto");
  // Keep mpv's backend-specific hardware-frame reserve. A globally reduced
  // pool can starve fixed-allocation decoders such as D3D11VA and VAAPI even
  // when it happens to work with VideoToolbox's dynamic allocation path.
  // Audio-clock sync is mpv's lean, robust default. Display-resample remains
  // opt-in for viewers who prefer cadence correction over power efficiency.
  setOption(candidate, "video-sync", "audio");
  setOption(candidate, "audio-pitch-correction", "yes");
  setOption(candidate, "keep-open", "yes");
  setOption(candidate, "osc", "no");
  setOption(candidate, "osd-level", "0");
  setOption(candidate, "osd-bar", "no");
  setOption(candidate, "osd-on-seek", "no");
  setOption(candidate, "input-default-bindings", "no");
  setOption(candidate, "input-builtin-bindings", "no");
  setOption(candidate, "input-vo-keyboard", "no");
  setOption(candidate, "input-cursor", "no");
  setOption(candidate, "terminal", "no");
  setOption(candidate, "msg-level", "all=warn");
  setOption(candidate, "resume-playback", "no");
  setOption(candidate, "autoload-files", "no");
  setOption(candidate, "cover-art-auto", "no");

  // These are conservative fallbacks for a source that bypasses WAM's normal
  // loadfile path. PlayerController supplies tighter per-file limits for local
  // files and bounded network limits for URLs.
  setOption(candidate, "cache", "auto");
  setOption(candidate, "cache-secs", "8");
  setOption(candidate, "demuxer-readahead-secs", "3");
  setOption(candidate, "demuxer-max-bytes", "32MiB");
  setOption(candidate, "demuxer-max-back-bytes", "8MiB");
  setOption(candidate, "demuxer-hysteresis-secs", "2");

  // Prefer the renderer's direct sampler path. Unlike forcing gpu-dumb-mode,
  // these settings still let mpv engage an advanced pipeline when HDR/color
  // conversion requires it, while ordinary SDR playback avoids intermediate
  // full-frame FBOs and multi-tap scaling shaders.
  setOption(candidate, "scale", "bilinear");
  setOption(candidate, "dscale", "bilinear");
  setOption(candidate, "correct-downscaling", "no");
  setOption(candidate, "linear-downscaling", "no");
  setOption(candidate, "sigmoid-upscaling", "no");
  setOption(candidate, "deband", "no");
  setOption(candidate, "interpolation", "no");
  applyRendererExperiments(candidate);

  const int result = mpv_initialize(candidate);
  if (result < 0) {
    initialization_error_ =
        QStringLiteral("Unable to initialize the media engine: %1")
            .arg(QString::fromUtf8(mpv_error_string(result)));
    mpv_terminate_destroy(candidate);
    state_.store(State::Failed, std::memory_order_release);
    return false;
  }

  // mpv's terminal output is disabled for a GUI app, but warning-level engine
  // diagnostics still need to reach WAM's log so playback failures can be
  // diagnosed instead of collapsing into the generic end-file error alone.
  const int log_result = mpv_request_log_messages(candidate, "warn");
  if (log_result < 0) {
    qWarning() << "WAM: unable to enable media-engine diagnostics:"
               << mpv_error_string(log_result);
  }

  mpv_set_wakeup_callback(candidate, &PlayerCore::onMpvWakeup, this);
  {
    std::scoped_lock lock(render_mutex_);
    handle_ = candidate;
    state_.store(State::Ready, std::memory_order_release);
  }
  return true;
}

PlayerCore::~PlayerCore() {
  if (!handle_)
    return;

  mpv_set_wakeup_callback(handle_, nullptr, nullptr);
  {
    std::scoped_lock lock(render_mutex_);
    if (render_context_) {
      // Make every outstanding GUI-thread ticket stale before the fallback
      // destroys the context.
      static_cast<void>(render_lifecycle_.invalidate());
      // A MpvRenderNode normally releases this while its OpenGL context is
      // current. This fallback is only for an abnormal scene-graph teardown.
      qWarning() << "WAM: mpv render context outlived its scene-graph node";
      mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
      mpv_render_context_free(render_context_);
      render_context_ = nullptr;
    }
  }
  mpv_terminate_destroy(handle_);
}

void PlayerCore::detachOwner(PlayerController *owner) {
  std::scoped_lock lock(owner_mutex_);
  if (owner_ == owner) {
    owner_ = nullptr;
    event_drain_queued_.store(false, std::memory_order_release);
    video_update_queued_.store(false, std::memory_order_release);
  }
}

void *PlayerCore::getOpenGlProcAddress(void *, const char *name) {
  QOpenGLContext *context = QOpenGLContext::currentContext();
  if (!context || !name)
    return nullptr;
  return reinterpret_cast<void *>(context->getProcAddress(QByteArray(name)));
}

bool PlayerCore::ensureRenderContext() {
  std::unique_lock lock(render_mutex_);
  if (!handle_)
    return false;

  if (const auto ready = render_lifecycle_.readyTicket())
    return render_context_ != nullptr;

  const auto creating = render_lifecycle_.beginCreation();
  if (!creating)
    return false;

  QString error;
  if (!QOpenGLContext::currentContext()) {
    error = QStringLiteral(
        "The video renderer requires an active OpenGL context.");
  } else {
    mpv_opengl_init_params gl_init{&PlayerCore::getOpenGlProcAddress, nullptr};
    mpv_render_param parameters[] = {
        {MPV_RENDER_PARAM_API_TYPE,
         const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };

    mpv_render_context *candidate = nullptr;
    const int result =
        mpv_render_context_create(&candidate, handle_, parameters);
    if (result < 0) {
      error = QStringLiteral("Unable to initialize video rendering: %1")
                  .arg(QString::fromUtf8(mpv_error_string(result)));
    } else {
      render_context_ = candidate;
      mpv_render_context_set_update_callback(
          render_context_, &PlayerCore::onRenderUpdate, this);
    }
  }

  if (!error.isEmpty()) {
    const auto failed = render_lifecycle_.completeCreation(*creating, false);
    lock.unlock();
    if (failed)
      postInitializationError(error, *failed);
    return false;
  }

  const auto ready = render_lifecycle_.completeCreation(*creating, true);
  if (!ready) {
    // Defensive only: creation and release are serialized on Qt's render
    // thread, so this transition should not be invalidated in production.
    mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
    mpv_render_context_free(render_context_);
    render_context_ = nullptr;
    return false;
  }
  lock.unlock();
  notifyRenderingReady(*ready);
  return true;
}

void PlayerCore::render(int framebuffer, int width, int height, bool flip_y) {
  if (width <= 0 || height <= 0)
    return;
  std::scoped_lock lock(render_mutex_);
  if (!render_context_)
    return;

  // Keep the render callback coalesced until Qt actually consumes the update,
  // rather than only until the GUI thread asks the scene graph for a frame.
  // The latter can be a full vsync later (or indefinitely later while the
  // window is hidden), which otherwise permits redundant queued GUI updates.
  // Clear before update(): a callback racing with this render then schedules
  // the following frame instead of being lost.
  video_update_queued_.store(false, std::memory_order_release);

  // Rendering the current frame is also correct for redraws caused by an
  // expose or resize even when MPV_RENDER_UPDATE_FRAME is not set.
  mpv_render_context_update(render_context_);
  mpv_opengl_fbo target{framebuffer, width, height, 0};
  int flip = flip_y ? 1 : 0;
  mpv_render_param parameters[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &target},
      {MPV_RENDER_PARAM_FLIP_Y, &flip},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  mpv_render_context_render(render_context_, parameters);
}

void PlayerCore::releaseRenderContext() {
  std::optional<RenderTicket> retired_ticket;
  {
    std::scoped_lock lock(render_mutex_);
    // Invalidate GUI-thread tickets before freeing the context. An
    // asynchronous load command that races teardown therefore cannot be
    // mistaken for a load submitted against the replacement generation.
    retired_ticket = render_lifecycle_.invalidate();
    if (render_context_) {
      mpv_render_context_set_update_callback(render_context_, nullptr,
                                             nullptr);
      mpv_render_context_free(render_context_);
      render_context_ = nullptr;
    }
    // A queued update may have been delivered while the scene graph was
    // hidden and therefore never consumed by render(). A replacement context
    // must be able to schedule its first frame instead of inheriting that
    // stale gate.
    video_update_queued_.store(false, std::memory_order_release);
  }
  if (retired_ticket)
    notifyRenderInvalidated(*retired_ticket);
}

bool PlayerCore::retryFailedRenderContext() {
  return render_lifecycle_.retryFailure();
}

void PlayerCore::onMpvWakeup(void *context) {
  static_cast<PlayerCore *>(context)->queueEventDrain();
}

void PlayerCore::onRenderUpdate(void *context) {
  static_cast<PlayerCore *>(context)->queueVideoUpdate();
}

void PlayerCore::queueEventDrain() {
  if (event_drain_queued_.exchange(true, std::memory_order_acq_rel))
    return;

  std::scoped_lock lock(owner_mutex_);
  if (!owner_) {
    event_drain_queued_.store(false, std::memory_order_release);
    return;
  }
  PlayerController *owner = owner_;
  QMetaObject::invokeMethod(
      owner,
      [this, owner] {
        event_drain_queued_.store(false, std::memory_order_release);
        {
          std::scoped_lock owner_lock(owner_mutex_);
          if (owner_ != owner)
            return;
        }

        // mpv may invoke its wakeup callback while holding an internal client
        // lock. Never retain owner_mutex_ while entering mpv_wait_event(), or
        // the GUI and mpv core threads can acquire those locks in opposite
        // orders and deadlock. This functor is context-bound to `owner`, so Qt
        // guarantees the QObject remains alive for the duration of the call.
        owner->drainMpvEvents();
      },
      Qt::QueuedConnection);
}

void PlayerCore::queueVideoUpdate() {
  if (video_update_queued_.exchange(true, std::memory_order_acq_rel))
    return;

  std::scoped_lock lock(owner_mutex_);
  if (!owner_) {
    video_update_queued_.store(false, std::memory_order_release);
    return;
  }
  PlayerController *owner = owner_;
  const bool queued = QMetaObject::invokeMethod(
      owner,
      [this, owner] {
        {
          std::scoped_lock owner_lock(owner_mutex_);
          if (owner_ != owner) {
            video_update_queued_.store(false, std::memory_order_release);
            return;
          }
        }
        owner->requestVideoUpdate();
      },
      Qt::QueuedConnection);
  if (!queued)
    video_update_queued_.store(false, std::memory_order_release);
}

void PlayerCore::notifyRenderingReady(RenderTicket ticket) {
  std::scoped_lock lock(owner_mutex_);
  if (!owner_)
    return;
  PlayerController *owner = owner_;
  QMetaObject::invokeMethod(
      owner, [owner, ticket] { owner->flushPendingOpen(ticket.stamp); },
      Qt::QueuedConnection);
}

void PlayerCore::notifyRenderInvalidated(RenderTicket retired_ticket) {
  std::scoped_lock lock(owner_mutex_);
  if (!owner_)
    return;
  PlayerController *owner = owner_;
  QMetaObject::invokeMethod(
      owner,
      [owner, retired_ticket] {
        owner->handleRenderInvalidated(retired_ticket.stamp);
      },
      Qt::QueuedConnection);
}

void PlayerCore::postInitializationError(const QString &error,
                                         RenderTicket ticket) {
  std::scoped_lock lock(owner_mutex_);
  if (!owner_)
    return;
  PlayerController *owner = owner_;
  QMetaObject::invokeMethod(
      owner,
      [owner, error, ticket] {
        owner->handleRenderInitializationFailure(error, ticket.stamp);
      },
      Qt::QueuedConnection);
}

} // namespace wam::qt
