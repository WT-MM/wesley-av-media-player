#include "mpv_engine.hpp"

#include "media/startup_benchmark.hpp"
#include "player_core_p.hpp"
#include "playback/mpv/mpv_runtime.hpp"

#include <QCoreApplication>

#include <new>

namespace wam::qt {

MpvEngine::MpvEngine(PlayerController *owner)
    : core(std::make_shared<PlayerCore>(owner)), owner_(owner) {}

MpvEngine::~MpvEngine() = default;

bool MpvEngine::ready() const { return core && core->ready(); }

bool MpvEngine::provision(
    std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime) {
  if (!runtime || !runtime->api().complete() || ready() || runtime_)
    return false;
  runtime_ = std::move(runtime);
  return true;
}

QString MpvEngine::provisionRuntime() {
  if (runtime_)
    return {};
  WAM_STARTUP_STAMP(FallbackLoadBegin);
#if defined(__APPLE__)
  auto loaded = ::wam::playback::mpv::MpvRuntime::load(
      QCoreApplication::applicationDirPath());
#else
  // libmpv supports many mpv_create() handles from one library image, and
  // the runtime is the immutable, process-lifetime API table -- not a
  // handle -- so every window sharing it is its intended use.
  auto loaded = ::wam::playback::mpv::MpvLinkedRuntimeFactory::create();
#endif
  WAM_STARTUP_STAMP(FallbackLoadEnd);
  if (!loaded || !provision(loaded.runtime)) {
    return loaded.detail.isEmpty()
               ? QStringLiteral(
                     "A playback component is missing. Reinstall WAM to restore it.")
               : loaded.detail;
  }
  return {};
}

bool MpvEngine::initialize() {
  WAM_STARTUP_STAMP(FallbackInitializeBegin);
  const bool initialized = core->initialize(runtime_);
  WAM_STARTUP_STAMP(FallbackInitializeEnd);
  return initialized;
}

bool MpvEngine::reserveReplacement() {
  if (replacement_)
    return true;
  try {
    replacement_ = std::make_shared<PlayerCore>(owner_);
  } catch (...) {
    return false;
  }
  return true;
}

bool MpvEngine::replaceAfterRenderRelease(
    const std::shared_ptr<PlayerCore> &expected) {
  if (!expected || core != expected || !replacement_)
    return false;
  if (!expected->retireFallbackAfterRenderRelease(owner_))
    return false;
  core = std::move(replacement_);
  lineage = {};
  return true;
}

bool MpvEngine::setPausedNow(bool paused) {
  if (!ready())
    return false;
  int flag = paused ? 1 : 0;
  return core->api().mpv_set_property(core->handle(), "pause",
                                      MPV_FORMAT_FLAG, &flag) >= 0;
}

bool MpvEngine::submitStop(std::uint64_t reply_userdata) {
  if (!ready())
    return false;
  const char *arguments[] = {"stop", nullptr};
  return core->api().mpv_command_async(core->handle(), reply_userdata,
                                       arguments) >= 0;
}

bool MpvEngine::idle() const {
  int idle = 0;
  return ready() &&
         core->api().mpv_get_property(core->handle(), "idle-active",
                                      MPV_FORMAT_FLAG, &idle) >= 0 &&
         idle != 0;
}

void MpvEngine::revokeRendering() {
  core->revokeRenderContext();
  if (!core->renderContextBusy() &&
      RenderLifecycle::phase(core->renderLifecycleSnapshot()) ==
          RenderPhase::Failed) {
    static_cast<void>(core->retryFailedRenderContext());
  }
}

bool MpvEngine::renderingReleased() const {
  return core && !core->renderContextBusy() &&
         RenderLifecycle::phase(core->renderLifecycleSnapshot()) ==
             RenderPhase::Empty;
}

NativePlaybackMetricsSample MpvEngine::metrics() const {
  return core ? core->fallbackMetrics() : NativePlaybackMetricsSample{};
}

void MpvEngine::detachOwner() {
  if (core)
    core->detachOwner(owner_);
  core.reset();
}

} // namespace wam::qt
