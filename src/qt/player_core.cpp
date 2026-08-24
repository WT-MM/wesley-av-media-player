#include "player_core_p.hpp"

#include "mpv_hwdec_interop_policy.hpp"
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

using ::wam::playback::mpv::MpvApi;

constexpr unsigned kRenderNotificationQueueAttempts = 3;
constexpr unsigned kRenderNotificationDrainBatch = 4;

class CoalescingFlagRollback final {
public:
  explicit CoalescingFlagRollback(std::atomic<bool> &flag) noexcept
      : flag_(flag) {}

  CoalescingFlagRollback(const CoalescingFlagRollback &) = delete;
  CoalescingFlagRollback &operator=(const CoalescingFlagRollback &) = delete;

  ~CoalescingFlagRollback() noexcept {
    if (armed_)
      flag_.store(false, std::memory_order_release);
  }

  void dismiss() noexcept { armed_ = false; }

private:
  std::atomic<bool> &flag_;
  bool armed_ = true;
};

bool setOption(const MpvApi &api, mpv_handle *handle, const char *name,
               const char *value) {
  const int result = api.mpv_set_option_string(handle, name, value);
  if (result < 0) {
    qWarning().nospace() << "WAM: unable to set mpv option " << name << '='
                         << value << ": " << api.mpv_error_string(result);
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

void applyRendererExperiments(const MpvApi &api, mpv_handle *handle) {
  if (qEnvironmentVariableIsSet("WAM_RENDER_PROFILE")) {
    const QByteArray profile = experimentValue("WAM_RENDER_PROFILE");
    if (profile == "fast" || profile == "efficient") {
      bool applied = true;
      applied &= setOption(api, handle, "scale", "bilinear");
      applied &= setOption(api, handle, "dscale", "bilinear");
      applied &= setOption(api, handle, "correct-downscaling", "no");
      applied &= setOption(api, handle, "linear-downscaling", "no");
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
      applied &= setOption(api, handle, "scale", "spline36");
      applied &= setOption(api, handle, "dscale", "mitchell");
      applied &= setOption(api, handle, "correct-downscaling", "yes");
      applied &= setOption(api, handle, "linear-downscaling", "yes");
      applied &= setOption(api, handle, "sigmoid-upscaling", "yes");
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
      if (setOption(api, handle, "video-sync", "audio")) {
        qInfo() << "WAM: active renderer experiment WAM_VIDEO_SYNC=audio:"
                   " video-sync=audio.";
      } else {
        qWarning() << "WAM: WAM_VIDEO_SYNC=audio was not applied.";
      }
    } else if (video_sync == "display-resample") {
      if (setOption(api, handle, "video-sync", "display-resample")) {
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
      if (setOption(api, handle, "fbo-format", fbo_format.constData())) {
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

bool PlayerCore::initialize(
    std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime) {
  Q_ASSERT(!owner_ || QThread::currentThread() == owner_->thread());
  State expected = State::Dormant;
  if (!state_.compare_exchange_strong(expected, State::Initializing,
                                      std::memory_order_acq_rel))
    return expected == State::Ready;

  if (!runtime || !runtime->api().complete()) {
    initialization_error_ =
        QStringLiteral("The compatibility media engine is unavailable.");
    state_.store(State::Failed, std::memory_order_release);
    return false;
  }
  runtime_ = std::move(runtime);
  const MpvApi &api = runtime_->api();

  mpv_handle *candidate = api.mpv_create();
  if (!candidate) {
    initialization_error_ =
        QStringLiteral("Unable to create the media engine.");
    state_.store(State::Failed, std::memory_order_release);
    return false;
  }

  // The packaged application must behave identically regardless of a user's
  // standalone mpv configuration. Avoid loading user scripts, profiles, and
  // built-in overlays that WAM neither displays nor controls.
  setOption(api, candidate, "config", "no");
  setOption(api, candidate, "load-scripts", "no");
  setOption(api, candidate, "load-auto-profiles", "no");
  setOption(api, candidate, "load-stats-overlay", "no");
  setOption(api, candidate, "load-console", "no");
  setOption(api, candidate, "load-select", "no");
  setOption(api, candidate, "load-context-menu", "no");
  setOption(api, candidate, "load-commands", "no");
  setOption(api, candidate, "load-positioning", "no");

  // Keep mpv's own UI/input disabled: QML is the single UX layer. The render
  // API and hardware interop let supported decoders provide GPU-backed frames
  // instead of round-tripping them through CPU memory.
#ifdef __APPLE__
  // Qt owns the process-wide application/menu lifecycle. Prevent mpv's macOS
  // AppHub from installing its standalone-player activation policy, menu
  // shortcuts, and Touch Bar while initializing inside the Qt host.
  setOption(api, candidate, "macos-app-activation-policy", "prohibited");
  setOption(api, candidate, "macos-menu-shortcuts", "no");
#endif
  setOption(api, candidate, "vo", "libmpv");
  setOption(api, candidate, "hwdec", "auto-safe");
  setOption(api, candidate, "vd-lavc-dr", "auto");
  setOption(api, candidate, "gpu-hwdec-interop",
            mpvGpuHwdecInterop(kMpvHwdecInteropHostPlatform));
  // Keep mpv's backend-specific hardware-frame reserve. A globally reduced
  // pool can starve fixed-allocation decoders such as D3D11VA and VAAPI even
  // when it happens to work with VideoToolbox's dynamic allocation path.
  // Audio-clock sync is mpv's lean, robust default. Display-resample remains
  // opt-in for viewers who prefer cadence correction over power efficiency.
  setOption(api, candidate, "video-sync", "audio");
  setOption(api, candidate, "audio-pitch-correction", "yes");
  // The compatibility route must reach the same 400% ceiling the native gain
  // stage does (kMaximumGain, +12 dB), or a boosted window would play quieter
  // the moment it fell back. mpv's own default volume-max is 130 and `config
  // no` above means a user's mpv.conf can never supply it, so this option is
  // the only lever. This is the ENGINE's ceiling, not the user's: how much of
  // it any window may reach is PlayerController's maximumVolume preference,
  // which clamps every level before it is ever sent here.
  setOption(api, candidate, "volume-max", "400");
  setOption(api, candidate, "keep-open", "yes");
  setOption(api, candidate, "osc", "no");
  setOption(api, candidate, "osd-level", "0");
  setOption(api, candidate, "osd-bar", "no");
  setOption(api, candidate, "osd-on-seek", "no");
  setOption(api, candidate, "input-default-bindings", "no");
  setOption(api, candidate, "input-builtin-bindings", "no");
  setOption(api, candidate, "input-vo-keyboard", "no");
  setOption(api, candidate, "input-cursor", "no");
  setOption(api, candidate, "terminal", "no");
  setOption(api, candidate, "msg-level", "all=warn");
  setOption(api, candidate, "resume-playback", "no");
  setOption(api, candidate, "autoload-files", "no");
  setOption(api, candidate, "cover-art-auto", "no");

  // These are conservative fallbacks for a source that bypasses WAM's normal
  // loadfile path. PlayerController supplies tighter per-file limits for local
  // files and bounded network limits for URLs.
  setOption(api, candidate, "cache", "auto");
  setOption(api, candidate, "cache-secs", "8");
  setOption(api, candidate, "demuxer-readahead-secs", "3");
  setOption(api, candidate, "demuxer-max-bytes", "32MiB");
  setOption(api, candidate, "demuxer-max-back-bytes", "8MiB");
  setOption(api, candidate, "demuxer-hysteresis-secs", "2");

  // Prefer the renderer's direct sampler path. Unlike forcing gpu-dumb-mode,
  // these settings still let mpv engage an advanced pipeline when HDR/color
  // conversion requires it, while ordinary SDR playback avoids intermediate
  // full-frame FBOs and multi-tap scaling shaders.
  setOption(api, candidate, "scale", "bilinear");
  setOption(api, candidate, "dscale", "bilinear");
  setOption(api, candidate, "correct-downscaling", "no");
  setOption(api, candidate, "linear-downscaling", "no");
  setOption(api, candidate, "sigmoid-upscaling", "no");
  setOption(api, candidate, "deband", "no");
  setOption(api, candidate, "interpolation", "no");
  applyRendererExperiments(api, candidate);

  const int result = api.mpv_initialize(candidate);
  if (result < 0) {
    initialization_error_ =
        QStringLiteral("Unable to initialize the media engine: %1")
            .arg(QString::fromUtf8(api.mpv_error_string(result)));
    api.mpv_terminate_destroy(candidate);
    state_.store(State::Failed, std::memory_order_release);
    return false;
  }

  // mpv's terminal output is disabled for a GUI app, but warning-level engine
  // diagnostics still need to reach WAM's log so playback failures can be
  // diagnosed instead of collapsing into the generic end-file error alone.
  const int log_result = api.mpv_request_log_messages(candidate, "warn");
  if (log_result < 0) {
    qWarning() << "WAM: unable to enable media-engine diagnostics:"
               << api.mpv_error_string(log_result);
  }

  api.mpv_set_wakeup_callback(candidate, &PlayerCore::onMpvWakeup, this);
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

  revokeRenderContext();
  {
    std::scoped_lock lock(render_mutex_);
    // An admitted render context owns a shared reference back to this object.
    // Consequently the destructor cannot be entered until an exact-context
    // release has freed the renderer and broken that cycle. This assertion is
    // a guard against ever reintroducing an unsafe destructor fallback:
    // libmpv forbids every mpv_render_* call from a different/no GL context.
    Q_ASSERT(!render_context_);
    Q_ASSERT(render_context_owner_.isNull());
    Q_ASSERT(!render_context_callback_installed_);
    Q_ASSERT(!render_context_keepalive_);
    Q_ASSERT(!renderContextBusy());
    static_cast<void>(render_lifecycle_.invalidate());
  }
  api().mpv_set_wakeup_callback(handle_, nullptr, nullptr);
  terminateMpvHandle(handle_);
}

void PlayerCore::detachOwner(PlayerController *owner) {
  bool detached = false;
  {
    std::scoped_lock lock(owner_mutex_);
    if (owner_ == owner) {
      owner_ = nullptr;
      event_drain_queued_.store(false, std::memory_order_release);
      video_update_queued_.store(false, std::memory_order_release);
      detached = true;
    }
  }
  if (detached) {
    // Queued functors are context-bound to `owner` and Qt discards them when
    // it is destroyed. Clear their retained facts as part of the same logical
    // detach so a render-node keepalive cannot preserve stale GUI work.
    std::scoped_lock notification_lock(render_notification_mutex_);
    pending_render_ready_stamp_ = 0;
    pending_render_invalidation_stamp_ = 0;
    render_notification_drain_queued_ = false;
  }
}

bool PlayerCore::retireFallbackAfterRenderRelease(
    PlayerController *owner) noexcept {
  Q_ASSERT(!owner || QThread::currentThread() == owner->thread());
  revokeRenderContext();
  if (renderContextBusy() ||
      RenderLifecycle::phase(renderLifecycleSnapshot()) !=
          RenderPhase::Empty) {
    return false;
  }

  mpv_handle *retired = nullptr;
  {
    std::scoped_lock lock(render_mutex_);
    if (renderContextAllowed() || renderContextBusy() || render_context_ ||
        !render_context_owner_.isNull() || render_context_callback_installed_ ||
        render_context_keepalive_ ||
        RenderLifecycle::phase(render_lifecycle_.snapshot()) !=
            RenderPhase::Empty) {
      return false;
    }
    retired = handle_;
    handle_ = nullptr;
  }

  detachOwner(owner);

  if (retired) {
    // state remains Ready until both calls return so the immutable runtime is
    // available to the existing exact teardown helper.
    api().mpv_set_wakeup_callback(retired, nullptr, nullptr);
    terminateMpvHandle(retired);
  }
  {
    std::scoped_lock lock(render_mutex_);
    runtime_.reset();
    initialization_error_.clear();
    state_.store(State::Dormant, std::memory_order_release);
  }
  return true;
}

void PlayerCore::allowRenderContext() noexcept {
  render_context_permission_.fetch_or(kRenderContextAllowed,
                                      std::memory_order_acq_rel);
}

void PlayerCore::revokeRenderContext() noexcept {
  render_context_permission_.fetch_and(
      static_cast<std::uint8_t>(~kRenderContextAllowed),
      std::memory_order_acq_rel);
}

bool PlayerCore::renderContextAllowed() const noexcept {
  return (render_context_permission_.load(std::memory_order_acquire) &
          kRenderContextAllowed) != 0;
}

bool PlayerCore::renderContextBusy() const noexcept {
  return (render_context_permission_.load(std::memory_order_acquire) &
          kRenderContextBusy) != 0;
}

#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
bool PlayerCore::renderNotificationAllowsCreationForTesting() noexcept {
  queueRenderNotificationDrain();
  return !hasPendingRenderInvalidation();
}
#endif

void PlayerCore::clearRenderContextBusy() noexcept {
  render_context_permission_.fetch_and(
      static_cast<std::uint8_t>(~kRenderContextBusy),
      std::memory_order_acq_rel);
}

QOpenGLContext *PlayerCore::currentOpenGlContext() const noexcept {
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  if (has_current_opengl_context_for_testing_) {
    try {
      if (!has_current_opengl_context_for_testing_())
        return nullptr;
    } catch (...) {
      return nullptr;
    }
  }
#endif
  return QOpenGLContext::currentContext();
}

bool PlayerCore::renderContextOwnerIsCurrentLocked() const noexcept {
  return render_context_ && !render_context_owner_.isNull() &&
         currentOpenGlContext() == render_context_owner_.data();
}

bool PlayerCore::commitRenderContextPermission(bool keep_busy) noexcept {
  std::uint8_t expected = static_cast<std::uint8_t>(
      kRenderContextAllowed | kRenderContextBusy);
  const std::uint8_t desired =
      keep_busy ? expected : kRenderContextAllowed;
  return render_context_permission_.compare_exchange_strong(
      expected, desired, std::memory_order_acq_rel,
      std::memory_order_acquire);
}

void PlayerCore::setRenderContextUpdateCallback(
    mpv_render_context *context, mpv_render_update_fn callback,
    void *callback_context) noexcept {
  if (!context)
    return;
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  if (render_context_set_update_callback_for_testing_) {
    try {
      render_context_set_update_callback_for_testing_(
          context, callback, callback_context);
    } catch (...) {
      // A test seam must not escape this production noexcept cleanup path.
    }
    return;
  }
#endif
  api().mpv_render_context_set_update_callback(context, callback,
                                               callback_context);
}

void PlayerCore::freeRenderContext(mpv_render_context *context) noexcept {
  if (!context)
    return;
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  render_context_free_count_for_testing_.fetch_add(
      1, std::memory_order_relaxed);
  if (render_context_free_for_testing_) {
    try {
      render_context_free_for_testing_(context);
    } catch (...) {
      // A test seam must not escape this production noexcept cleanup path.
    }
    return;
  }
#endif
  api().mpv_render_context_free(context);
}

void PlayerCore::terminateMpvHandle(mpv_handle *handle) noexcept {
  if (!handle)
    return;
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  if (before_terminate_destroy_for_testing_) {
    try {
      before_terminate_destroy_for_testing_(handle);
    } catch (...) {
      // A test seam must not escape this production noexcept teardown path.
    }
  }
#endif
  api().mpv_terminate_destroy(handle);
}

bool PlayerCore::freeRenderContextResourceLocked(
    std::shared_ptr<PlayerCore> &deferred_keepalive) noexcept {
  if (!render_context_) {
    deferred_keepalive = std::move(render_context_keepalive_);
    render_context_owner_.clear();
    render_context_callback_installed_ = false;
    return true;
  }
  if (!renderContextOwnerIsCurrentLocked())
    return false;

  // Move the self-owner first, but retain the local reference through the
  // entire mpv free, lifecycle notification, and caller return path.
  deferred_keepalive = std::move(render_context_keepalive_);
  if (render_context_callback_installed_) {
    setRenderContextUpdateCallback(render_context_, nullptr, nullptr);
  }
  freeRenderContext(render_context_);
  render_context_ = nullptr;
  render_context_callback_installed_ = false;
  render_context_owner_.clear();
  return true;
}

bool PlayerCore::invalidateAndFreeRenderContextLocked(
    std::optional<RenderTicket> &retired_ticket,
    std::shared_ptr<PlayerCore> &deferred_keepalive) noexcept {
  // Check the exact live owner before invalidating. On mismatch the retained
  // renderer, lifecycle, Busy bit, and self-owner remain intact, and no
  // mpv_render_* API is invoked.
  if (render_context_ && !renderContextOwnerIsCurrentLocked())
    return false;

  retired_ticket = render_lifecycle_.invalidate();
  if (!freeRenderContextResourceLocked(deferred_keepalive))
    return false;
  // Busy covers both the API call and the full installed-context lifetime.
  // Publish its release only after libmpv has returned from free().
  clearRenderContextBusy();
  video_update_queued_.store(false, std::memory_order_release);
  return true;
}

void *PlayerCore::getOpenGlProcAddress(void *, const char *name) noexcept {
  if (!name)
    return nullptr;
  try {
    QOpenGLContext *context = QOpenGLContext::currentContext();
    if (!context)
      return nullptr;
    return reinterpret_cast<void *>(context->getProcAddress(QByteArray(name)));
  } catch (...) {
    // This function is invoked through libmpv's C callback boundary. A failed
    // QByteArray allocation is equivalent to an unavailable GL entry point.
    return nullptr;
  }
}

bool PlayerCore::ensureRenderContext() {
  // A queue failure leaves the exact lifecycle fact pending. Every later
  // scene-graph pass retries it before observing or changing renderer state.
  // Invalidation must reach the controller before a replacement Ready can be
  // created, otherwise recovery could bind to the new generation first.
  queueRenderNotificationDrain();
  if (hasPendingRenderInvalidation())
    return false;

  std::shared_ptr<PlayerCore> deferred_keepalive;
  std::optional<RenderTicket> retired_ticket;
  std::unique_lock lock(render_mutex_);
  if (!handle_)
    return false;

  if (const auto ready = render_lifecycle_.readyTicket()) {
    if (render_context_ && renderContextAllowed()) {
      return renderContextOwnerIsCurrentLocked();
    }
    if (!renderContextAllowed()) {
      const bool released = invalidateAndFreeRenderContextLocked(
          retired_ticket, deferred_keepalive);
      lock.unlock();
      if (released && retired_ticket)
        notifyRenderInvalidated(*retired_ticket);
    }
    return false;
  }

  // A denied, context-free render pass is a pure no-op. In particular it must
  // not churn RenderLifecycle generations or queue invalidation callbacks.
  if (!renderContextAllowed())
    return false;

  const auto creating = render_lifecycle_.beginCreation();
  if (!creating)
    return false;

  QOpenGLContext *const creating_context = currentOpenGlContext();
  if (!creating_context) {
    // No Busy reservation was needed because the API will not be called, but
    // failure publication must still linearize against revoke().
    std::uint8_t expected = kRenderContextAllowed;
    if (!render_context_permission_.compare_exchange_strong(
            expected, kRenderContextAllowed, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      const auto retired = render_lifecycle_.invalidate();
      lock.unlock();
      if (retired)
        notifyRenderInvalidated(*retired);
      return false;
    }
    const auto failed = render_lifecycle_.completeCreation(*creating, false);
    lock.unlock();
    if (failed)
      postRenderInitializationErrorBestEffort(
          MPV_ERROR_GENERIC, true, *failed);
    return false;
  }

  std::uint8_t expected = kRenderContextAllowed;
  if (!render_context_permission_.compare_exchange_strong(
          expected,
          static_cast<std::uint8_t>(kRenderContextAllowed |
                                    kRenderContextBusy),
          std::memory_order_acq_rel, std::memory_order_acquire)) {
    const auto retired = render_lifecycle_.invalidate();
    lock.unlock();
    if (retired)
      notifyRenderInvalidated(*retired);
    return false;
  }

  // Busy admits only shared PlayerCore instances. The retained self-owner is
  // the fail-safe lifetime boundary for libmpv's callback target: if the
  // creating QOpenGLContext disappears before release, the entire core is
  // intentionally quarantined instead of running undefined render teardown.
  auto admitted_keepalive = weak_from_this().lock();
  if (!admitted_keepalive) {
    retired_ticket = render_lifecycle_.invalidate();
    clearRenderContextBusy();
    lock.unlock();
    if (retired_ticket)
      notifyRenderInvalidated(*retired_ticket);
    return false;
  }
  render_context_keepalive_ = std::move(admitted_keepalive);
  render_context_owner_ = creating_context;
  render_context_callback_installed_ = false;

#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  if (before_render_context_create_for_testing_)
    before_render_context_create_for_testing_();
#endif

  // The hook may model a context switch or destruction. Never call the API
  // unless the exact captured owner is still live and current.
  if (render_context_owner_.isNull() ||
      currentOpenGlContext() != render_context_owner_.data()) {
    retired_ticket = render_lifecycle_.invalidate();
    deferred_keepalive = std::move(render_context_keepalive_);
    render_context_owner_.clear();
    clearRenderContextBusy();
    lock.unlock();
    if (retired_ticket)
      notifyRenderInvalidated(*retired_ticket);
    return false;
  }

  // This no-op RMW is the API admission linearization against revoke(). A
  // revoke that won while Busy skips the actual mpv call and create counter.
  if (!commitRenderContextPermission(true)) {
    retired_ticket = render_lifecycle_.invalidate();
    deferred_keepalive = std::move(render_context_keepalive_);
    render_context_owner_.clear();
    clearRenderContextBusy();
    lock.unlock();
    if (retired_ticket)
      notifyRenderInvalidated(*retired_ticket);
    return false;
  }

  mpv_opengl_init_params gl_init{&PlayerCore::getOpenGlProcAddress, nullptr};
  mpv_render_param parameters[] = {
      {MPV_RENDER_PARAM_API_TYPE,
       const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };

  mpv_render_context *candidate = nullptr;
  render_context_create_count_.fetch_add(1, std::memory_order_relaxed);
  int result = 0;
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  if (render_context_create_for_testing_) {
    try {
      result = render_context_create_for_testing_(&candidate, handle_,
                                                  parameters);
    } catch (...) {
      candidate = nullptr;
      result = MPV_ERROR_GENERIC;
    }
  } else
#endif
  {
    result = api().mpv_render_context_create(&candidate, handle_, parameters);
  }

#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  if (after_render_context_api_for_testing_)
    after_render_context_api_for_testing_();
  if (result >= 0 && candidate &&
      after_render_context_create_for_testing_) {
    after_render_context_create_for_testing_();
  }
#endif

  if (candidate)
    render_context_ = candidate;

  // libmpv requires the exact creating GL context for every render API call,
  // including callback installation and free. A post-API context switch keeps
  // even a partial failure candidate retained under Busy+self for later
  // exact-owner retirement; it must not publish Ready/Failed or be destroyed
  // through the wrong context.
  if (candidate && !renderContextOwnerIsCurrentLocked()) {
    try {
      qWarning()
          << "WAM: retaining an mpv render candidate after its creating"
             " OpenGL context stopped being current";
    } catch (...) {
      // Diagnostics are best-effort; ownership remains safely quarantined.
    }
    return false;
  }

  if (result < 0 || !candidate) {
    // A failed API is allowed to return a partial candidate. Its exact owner
    // was verified above. Finish every resource/lifecycle transition before
    // allocating a detailed diagnostic so bad_alloc cannot strand Creating,
    // Busy, the self-owner, or a partial candidate on the render thread.
    if (!freeRenderContextResourceLocked(deferred_keepalive))
      return false;
    if (!commitRenderContextPermission(false)) {
      retired_ticket = render_lifecycle_.invalidate();
      clearRenderContextBusy();
      lock.unlock();
      if (retired_ticket)
        notifyRenderInvalidated(*retired_ticket);
      return false;
    }
    const auto failed = render_lifecycle_.completeCreation(*creating, false);
    lock.unlock();
    if (failed)
      postRenderInitializationErrorBestEffort(result, false, *failed);
    return false;
  }

  // Installation has its own exact permission linearization after the API
  // and adversarial barrier. A revoke that won frees the uninstalled candidate
  // and returns the lifecycle to Empty without reporting an error.
  if (!commitRenderContextPermission(true)) {
    const bool released = invalidateAndFreeRenderContextLocked(
        retired_ticket, deferred_keepalive);
    lock.unlock();
    if (released && retired_ticket)
      notifyRenderInvalidated(*retired_ticket);
    return false;
  }

  setRenderContextUpdateCallback(
      render_context_, &PlayerCore::onRenderUpdate, this);
  render_context_callback_installed_ = true;

  // This RMW is the Ready commit point. If it succeeds, a later revoke is an
  // active-context revocation: lifecycle publication may finish, but ticket
  // readers observe the denied gate and the node releases on its next pass.
  if (!commitRenderContextPermission(true)) {
    const bool released = invalidateAndFreeRenderContextLocked(
        retired_ticket, deferred_keepalive);
    lock.unlock();
    if (released && retired_ticket)
      notifyRenderInvalidated(*retired_ticket);
    return false;
  }

  const auto ready = render_lifecycle_.completeCreation(*creating, true);
  if (!ready) {
    // Defensive only: creation and release are serialized on Qt's render
    // thread, so this transition should not be invalidated in production.
    static_cast<void>(invalidateAndFreeRenderContextLocked(
        retired_ticket, deferred_keepalive));
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
  if (!render_context_ || !renderContextAllowed() ||
      !renderContextOwnerIsCurrentLocked()) {
    return;
  }

  // Keep the render callback coalesced until Qt actually consumes the update,
  // rather than only until the GUI thread asks the scene graph for a frame.
  // The latter can be a full vsync later (or indefinitely later while the
  // window is hidden), which otherwise permits redundant queued GUI updates.
  // Clear before update(): a callback racing with this render then schedules
  // the following frame instead of being lost.
  video_update_queued_.store(false, std::memory_order_release);

  // Rendering the current frame is also correct for redraws caused by an
  // expose or resize even when MPV_RENDER_UPDATE_FRAME is not set.
  api().mpv_render_context_update(render_context_);
  mpv_opengl_fbo target{framebuffer, width, height, 0};
  int flip = flip_y ? 1 : 0;
  mpv_render_param parameters[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &target},
      {MPV_RENDER_PARAM_FLIP_Y, &flip},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  api().mpv_render_context_render(render_context_, parameters);
}

bool PlayerCore::releaseRenderContext() {
  std::optional<RenderTicket> retired_ticket;
  std::shared_ptr<PlayerCore> deferred_keepalive;
  bool released = false;
  {
    std::scoped_lock lock(render_mutex_);
    // Invalidate GUI-thread tickets before freeing the context. An
    // asynchronous load command that races teardown therefore cannot be
    // mistaken for a load submitted against the replacement generation.
    released = invalidateAndFreeRenderContextLocked(
        retired_ticket, deferred_keepalive);
  }
  if (released && retired_ticket)
    notifyRenderInvalidated(*retired_ticket);
  return released;
}

bool PlayerCore::retryFailedRenderContext() {
  return render_lifecycle_.retryFailure();
}

void PlayerCore::onMpvWakeup(void *context) noexcept {
  if (!context)
    return;
  try {
    static_cast<PlayerCore *>(context)->queueEventDrain();
  } catch (...) {
    // libmpv forbids exceptions from crossing this foreign callback boundary.
  }
}

void PlayerCore::onRenderUpdate(void *context) noexcept {
  if (!context)
    return;
  try {
    static_cast<PlayerCore *>(context)->queueVideoUpdate();
  } catch (...) {
    // libmpv forbids exceptions from crossing this foreign callback boundary.
  }
}

void PlayerCore::queueEventDrain() noexcept {
  if (event_drain_queued_.exchange(true, std::memory_order_acq_rel))
    return;

  CoalescingFlagRollback rollback(event_drain_queued_);
  try {
    std::scoped_lock lock(owner_mutex_);
    if (!owner_)
      return;
    PlayerController *owner = owner_;
    bool queued = false;
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
    if (queue_event_drain_for_testing_) {
      queued = queue_event_drain_for_testing_();
    } else
#endif
    {
      auto keepalive = weak_from_this().lock();
      if (!keepalive)
        return;
      queued = QMetaObject::invokeMethod(
          owner,
          [keepalive = std::move(keepalive), owner] {
            keepalive->event_drain_queued_.store(false,
                                                  std::memory_order_release);
            try {
              {
                std::scoped_lock owner_lock(keepalive->owner_mutex_);
                if (keepalive->owner_ != owner ||
                    owner->core_.get() != keepalive.get())
                  return;
              }

              // mpv may invoke its wakeup callback while holding an internal
              // client lock. Never retain owner_mutex_ while entering
              // mpv_wait_event(), or the GUI and mpv core threads can acquire
              // those locks in opposite orders and deadlock. This functor is
              // context-bound to `owner`, so Qt guarantees the QObject remains
              // alive for the duration of the call.
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
              if (keepalive->drain_events_for_testing_) {
                keepalive->drain_events_for_testing_();
              } else
#endif
              {
                owner->drainMpvEvents();
              }
            } catch (...) {
              // No exception may escape Qt's event dispatch. The bit was
              // cleared before work began, so a later wakeup can retry.
            }
          },
          Qt::QueuedConnection);
    }
    if (!queued)
      return;
    rollback.dismiss();
  } catch (...) {
    // Rollback clears the bit so a later wakeup can retry. In particular, an
    // allocation failure while Qt copies the functor must not silence events.
  }
}

void PlayerCore::queueVideoUpdate() noexcept {
  if (video_update_queued_.exchange(true, std::memory_order_acq_rel))
    return;

  CoalescingFlagRollback rollback(video_update_queued_);
  try {
    std::scoped_lock lock(owner_mutex_);
    if (!owner_)
      return;
    PlayerController *owner = owner_;
    bool queued = false;
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
    if (queue_video_update_for_testing_) {
      queued = queue_video_update_for_testing_();
    } else
#endif
    {
      auto keepalive = weak_from_this().lock();
      if (!keepalive)
        return;
      queued = QMetaObject::invokeMethod(
          owner,
          [keepalive = std::move(keepalive), owner] {
            try {
              {
                std::scoped_lock owner_lock(keepalive->owner_mutex_);
                if (keepalive->owner_ != owner ||
                    owner->core_.get() != keepalive.get()) {
                  keepalive->video_update_queued_.store(
                      false, std::memory_order_release);
                  return;
                }
              }
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
              if (keepalive->request_video_update_for_testing_) {
                keepalive->request_video_update_for_testing_();
              } else
#endif
              {
                owner->requestVideoUpdate();
              }
            } catch (...) {
              // Rendering normally consumes this reservation. Failed owner
              // work did not request a frame, so make the callback retryable.
              keepalive->video_update_queued_.store(
                  false, std::memory_order_release);
            }
          },
          Qt::QueuedConnection);
    }
    if (!queued)
      return;
    rollback.dismiss();
  } catch (...) {
    // Rollback clears the bit so a later frame notification can retry.
  }
}

void PlayerCore::notifyRenderingReady(RenderTicket ticket) noexcept {
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  render_context_ready_notify_count_for_testing_.fetch_add(
      1, std::memory_order_relaxed);
#endif
  try {
    {
      std::scoped_lock lock(render_notification_mutex_);
      pending_render_ready_stamp_ = ticket.stamp;
    }
    queueRenderNotificationDrain();
  } catch (...) {
    // No exception may leave Qt's render pass. The state mutation itself is
    // allocation-free; this is a final barrier for platform mutex failures.
  }
}

void PlayerCore::notifyRenderInvalidated(RenderTicket retired_ticket) noexcept {
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  render_context_invalidation_notify_count_for_testing_.fetch_add(
      1, std::memory_order_relaxed);
#endif
  try {
    {
      std::scoped_lock lock(render_notification_mutex_);
      // If Ready never reached the GUI, its retirement supersedes that pending
      // handoff. If it is already executing, the drain clears by exact stamp
      // and then observes this invalidation in the same ordered batch.
      if (pending_render_ready_stamp_ == retired_ticket.stamp)
        pending_render_ready_stamp_ = 0;
      if (pending_render_invalidation_stamp_ == 0 ||
          pending_render_invalidation_stamp_ == retired_ticket.stamp) {
        pending_render_invalidation_stamp_ = retired_ticket.stamp;
      }
    }
    queueRenderNotificationDrain();
  } catch (...) {
    // Render release and render-node destruction are noexcept boundaries in
    // practice even where Qt's virtual API cannot express that contract.
  }
}

bool PlayerCore::hasPendingRenderInvalidation() noexcept {
  try {
    std::scoped_lock lock(render_notification_mutex_);
    return pending_render_invalidation_stamp_ != 0;
  } catch (...) {
    // If the barrier itself is unusable, fail closed rather than creating a
    // replacement whose Ready could overtake an unobserved invalidation.
    return true;
  }
}

void PlayerCore::queueRenderNotificationDrain() noexcept {
  bool exhausted = false;
  for (unsigned attempt = 0; attempt < kRenderNotificationQueueAttempts;
       ++attempt) {
    try {
      {
        std::scoped_lock lock(render_notification_mutex_);
        if (render_notification_drain_queued_ ||
            (pending_render_invalidation_stamp_ == 0 &&
             pending_render_ready_stamp_ == 0)) {
          return;
        }
        render_notification_drain_queued_ = true;
      }

      bool has_owner = false;
      bool queued = false;
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
      std::function<bool()> queue_seam;
      bool use_qt_queue = true;
#endif
      {
        // detachOwner() takes this same lock before clearing notification
        // state, so the QObject remains a valid invokeMethod context through
        // the complete queue call. Controller work runs only in the functor.
        std::scoped_lock owner_lock(owner_mutex_);
        PlayerController *const owner = owner_;
        if (owner) {
          has_owner = true;
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
          queue_seam = queue_render_notification_for_testing_;
          use_qt_queue = !queue_seam;
#endif
          if (
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
              use_qt_queue
#else
              true
#endif
          ) {
            auto keepalive = weak_from_this().lock();
            if (keepalive) {
              queued = QMetaObject::invokeMethod(
                  owner,
                  [keepalive = std::move(keepalive), owner] {
                    keepalive->drainRenderNotifications(owner);
                  },
                  Qt::QueuedConnection);
            }
          }
        }
      }

#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
      // Test/user work is deliberately outside owner_mutex_. The production
      // QMetaObject queue call stays under it solely to linearize QObject
      // lifetime with detachOwner().
      if (has_owner && queue_seam)
        queued = queue_seam();
#endif

      if (queued)
        return;

      {
        std::scoped_lock lock(render_notification_mutex_);
        // invokeMethod did not take ownership of a functor. Roll back the
        // reservation so this loop or a later render pass can retry.
        render_notification_drain_queued_ = false;
        if (!has_owner) {
          pending_render_ready_stamp_ = 0;
          pending_render_invalidation_stamp_ = 0;
          return;
        }
      }
    } catch (...) {
      // Functor copying/allocation and deterministic test seams can throw.
      // Restore queue admission without touching either exact lifecycle fact.
      try {
        std::scoped_lock lock(render_notification_mutex_);
        render_notification_drain_queued_ = false;
      } catch (...) {
        return;
      }
    }
    exhausted = true;
  }

  if (exhausted) {
    // A bounded immediate retry handles transient allocation pressure. Keep
    // the facts pending and request another scene-graph pass as the natural
    // liveness trigger; queueVideoUpdate() has its own noexcept rollback.
    queueVideoUpdate();
  }
}

void PlayerCore::drainRenderNotifications(
    PlayerController *expected_owner) noexcept {
  for (unsigned delivered = 0; delivered < kRenderNotificationDrainBatch;
       ++delivered) {
    std::uint64_t stamp = 0;
    bool invalidation = false;
    try {
      {
        std::scoped_lock lock(render_notification_mutex_);
        if (pending_render_invalidation_stamp_ != 0) {
          stamp = pending_render_invalidation_stamp_;
          invalidation = true;
        } else if (pending_render_ready_stamp_ != 0) {
          stamp = pending_render_ready_stamp_;
        } else {
          render_notification_drain_queued_ = false;
          return;
        }
      }

      {
        std::scoped_lock owner_lock(owner_mutex_);
        if (owner_ != expected_owner) {
          std::scoped_lock notification_lock(render_notification_mutex_);
          pending_render_ready_stamp_ = 0;
          pending_render_invalidation_stamp_ = 0;
          render_notification_drain_queued_ = false;
          return;
        }
      }

      // The functor is context-bound to expected_owner, so QObject teardown
      // cannot race this GUI-thread work. Do not hold either internal mutex
      // across controller code: it may synchronously request another frame.
      if (invalidation) {
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
        if (render_invalidation_work_for_testing_)
          render_invalidation_work_for_testing_(stamp);
        else
#endif
          expected_owner->handleRenderInvalidated(stamp);
      } else {
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
        if (render_ready_work_for_testing_)
          render_ready_work_for_testing_(stamp);
        else
#endif
          static_cast<void>(expected_owner->flushPendingOpen(stamp));
      }

      {
        std::scoped_lock lock(render_notification_mutex_);
        std::uint64_t &pending =
            invalidation ? pending_render_invalidation_stamp_
                         : pending_render_ready_stamp_;
        if (pending == stamp)
          pending = 0;
      }

      if (invalidation) {
        // handleRenderInvalidated() normally requests the replacement frame,
        // but the render thread may consume that update before this barrier
        // clears. Queue once more after acknowledgement so replacement
        // creation cannot remain parked behind the just-delivered gate.
        try {
          expected_owner->requestVideoUpdate();
        } catch (...) {
          queueVideoUpdate();
        }
      }
    } catch (...) {
      // Leave the exact fact pending. Roll back the consumed queue reservation
      // before scheduling a fresh bounded attempt; no exception escapes Qt.
      try {
        std::scoped_lock lock(render_notification_mutex_);
        render_notification_drain_queued_ = false;
      } catch (...) {
        return;
      }
      queueRenderNotificationDrain();
      return;
    }
  }

  // Bound one GUI event even if adversarial hooks continuously publish facts.
  // Release its reservation and let the same guarded queue path continue.
  try {
    std::scoped_lock lock(render_notification_mutex_);
    render_notification_drain_queued_ = false;
  } catch (...) {
    return;
  }
  queueRenderNotificationDrain();
}

void PlayerCore::postRenderInitializationErrorBestEffort(
    int result, bool missing_opengl_context,
    RenderTicket ticket) noexcept {
  try {
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
    if (before_render_context_error_diagnostic_for_testing_)
      before_render_context_error_diagnostic_for_testing_();
#endif
    if (missing_opengl_context) {
      postInitializationError(
          QStringLiteral(
              "The video renderer requires an active OpenGL context."),
          ticket);
    } else if (result < 0) {
      postInitializationError(
          QStringLiteral("Unable to initialize video rendering: %1")
              .arg(QString::fromUtf8(api().mpv_error_string(result))),
          ticket);
    } else {
      postInitializationError(
          QStringLiteral("Unable to initialize video rendering."), ticket);
    }
    return;
  } catch (...) {
    // The render-resource and lifecycle transaction has already completed.
    // Fall through to a static, allocation-free diagnostic if constructing
    // the detailed QString (or a deterministic test seam) failed.
  }
  postInitializationError(
      QStringLiteral("Unable to initialize video rendering."), ticket);
}

void PlayerCore::postInitializationError(const QString &error,
                                         RenderTicket ticket) noexcept {
#if defined(WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING)
  render_context_error_notify_count_for_testing_.fetch_add(
      1, std::memory_order_relaxed);
#endif
  try {
    std::scoped_lock lock(owner_mutex_);
    if (!owner_)
      return;
    PlayerController *owner = owner_;
    auto keepalive = weak_from_this().lock();
    if (!keepalive)
      return;
    QMetaObject::invokeMethod(
        owner,
        [keepalive = std::move(keepalive), owner, error, ticket] {
          {
            std::scoped_lock owner_lock(keepalive->owner_mutex_);
            if (keepalive->owner_ != owner ||
                owner->core_.get() != keepalive.get()) {
              return;
            }
          }
          owner->handleRenderInitializationFailure(error, ticket.stamp);
        },
        Qt::QueuedConnection);
  } catch (...) {
    // Renderer failure reporting must never throw through Qt's render pass.
  }
}

} // namespace wam::qt
