#define WAM_MPV_RUNTIME_TESTING 1

#include "fakes/mpv_runtime/injected_mpv_runtime.hpp"
#include "qt/mpv_render_context_policy.hpp"
#include "qt/player_controller.hpp"
#include "qt/player_core_p.hpp"

#include <QGuiApplication>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QSurfaceFormat>

#include <mpv/client.h>
#include <mpv/render.h>

#include <atomic>
#include <chrono>
#include <clocale>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <memory>
#include <new>
#include <semaphore>
#include <thread>
#include <utility>

namespace wam::qt {

// PlayerCore intentionally keeps its render ownership internals private. This
// target is compiled with the test-only seam while the shipping target is not.
class PlayerControllerTestAccess final {
public:
  static void setBeforeCreate(PlayerCore &core, std::function<void()> hook) {
    core.before_render_context_create_for_testing_ = std::move(hook);
  }

  static void setAfterCreate(PlayerCore &core, std::function<void()> hook) {
    core.after_render_context_create_for_testing_ = std::move(hook);
  }

  static void setAfterApi(PlayerCore &core, std::function<void()> hook) {
    core.after_render_context_api_for_testing_ = std::move(hook);
  }

  static void injectCreate(PlayerCore &core,
                           std::function<int(mpv_render_context **,
                                             mpv_handle *, mpv_render_param *)>
                               create) {
    core.render_context_create_for_testing_ = std::move(create);
  }

  static void
  injectFree(PlayerCore &core,
             std::function<void(mpv_render_context *)> free_context) {
    core.render_context_free_for_testing_ = std::move(free_context);
  }

  static void setBeforeTerminate(PlayerCore &core,
                                 std::function<void(mpv_handle *)> hook) {
    core.before_terminate_destroy_for_testing_ = std::move(hook);
  }

  static void setBeforeErrorDiagnostic(PlayerCore &core,
                                       std::function<void()> hook) {
    core.before_render_context_error_diagnostic_for_testing_ = std::move(hook);
  }

  static std::shared_ptr<PlayerCore> core(PlayerController &owner) {
    return owner.core_;
  }

  static void injectEventQueue(PlayerCore &core, std::function<bool()> queue) {
    core.queue_event_drain_for_testing_ = std::move(queue);
  }

  static void injectVideoQueue(PlayerCore &core, std::function<bool()> queue) {
    core.queue_video_update_for_testing_ = std::move(queue);
  }

  static void injectEventWork(PlayerCore &core, std::function<void()> work) {
    core.drain_events_for_testing_ = std::move(work);
  }

  static void injectVideoWork(PlayerCore &core, std::function<void()> work) {
    core.request_video_update_for_testing_ = std::move(work);
  }

  static void injectRenderNotificationQueue(PlayerCore &core,
                                            std::function<bool()> queue) {
    core.queue_render_notification_for_testing_ = std::move(queue);
  }

  static void injectReadyNotificationWork(
      PlayerCore &core, std::function<void(std::uint64_t)> work) {
    core.render_ready_work_for_testing_ = std::move(work);
  }

  static void injectInvalidationNotificationWork(
      PlayerCore &core, std::function<void(std::uint64_t)> work) {
    core.render_invalidation_work_for_testing_ = std::move(work);
  }

  static void notifyReady(PlayerCore &core, RenderTicket ticket) noexcept {
    core.notifyRenderingReady(ticket);
  }

  static void notifyInvalidated(PlayerCore &core,
                                RenderTicket ticket) noexcept {
    core.notifyRenderInvalidated(ticket);
  }

  static void retryRenderNotifications(PlayerCore &core) noexcept {
    core.queueRenderNotificationDrain();
  }

  static void drainRenderNotifications(PlayerCore &core,
                                       PlayerController &owner) noexcept {
    core.drainRenderNotifications(&owner);
  }

  [[nodiscard]] static bool renderNotificationQueued(PlayerCore &core) {
    std::scoped_lock lock(core.render_notification_mutex_);
    return core.render_notification_drain_queued_;
  }

  [[nodiscard]] static std::uint64_t pendingReadyNotification(
      PlayerCore &core) {
    std::scoped_lock lock(core.render_notification_mutex_);
    return core.pending_render_ready_stamp_;
  }

  [[nodiscard]] static std::uint64_t pendingInvalidationNotification(
      PlayerCore &core) {
    std::scoped_lock lock(core.render_notification_mutex_);
    return core.pending_render_invalidation_stamp_;
  }

  [[nodiscard]] static bool notificationAllowsCreation(PlayerCore &core) {
    return core.renderNotificationAllowsCreationForTesting();
  }

  static void invokeWakeupCallback(PlayerCore &core) {
    PlayerCore::onMpvWakeup(&core);
  }

  static void invokeRenderUpdateCallback(PlayerCore &core) {
    PlayerCore::onRenderUpdate(&core);
  }

  [[nodiscard]] static constexpr bool callbacksAreNoexcept() {
    return noexcept(PlayerCore::onMpvWakeup(nullptr)) &&
           noexcept(PlayerCore::onRenderUpdate(nullptr)) &&
           noexcept(PlayerCore::getOpenGlProcAddress(nullptr, nullptr)) &&
           noexcept(std::declval<PlayerCore &>().notifyRenderingReady({})) &&
           noexcept(std::declval<PlayerCore &>().notifyRenderInvalidated({}));
  }

  [[nodiscard]] static bool eventDrainQueued(const PlayerCore &core) {
    return core.event_drain_queued_.load(std::memory_order_acquire);
  }

  [[nodiscard]] static bool videoUpdateQueued(const PlayerCore &core) {
    return core.video_update_queued_.load(std::memory_order_acquire);
  }

  static void clearHooks(PlayerCore &core) {
    core.before_render_context_create_for_testing_ = {};
    core.after_render_context_api_for_testing_ = {};
    core.after_render_context_create_for_testing_ = {};
    core.render_context_create_for_testing_ = {};
    core.has_current_opengl_context_for_testing_ = {};
    core.render_context_set_update_callback_for_testing_ = {};
    core.render_context_free_for_testing_ = {};
    core.before_terminate_destroy_for_testing_ = {};
    core.before_render_context_error_diagnostic_for_testing_ = {};
    core.queue_event_drain_for_testing_ = {};
    core.queue_video_update_for_testing_ = {};
    core.drain_events_for_testing_ = {};
    core.request_video_update_for_testing_ = {};
    core.queue_render_notification_for_testing_ = {};
    core.render_ready_work_for_testing_ = {};
    core.render_invalidation_work_for_testing_ = {};
  }

  [[nodiscard]] static bool hasRenderContext(const PlayerCore &core) {
    return core.render_context_ != nullptr;
  }

  [[nodiscard]] static QOpenGLContext *
  renderContextOwner(const PlayerCore &core) {
    return core.render_context_owner_.data();
  }

  [[nodiscard]] static bool callbackInstalled(const PlayerCore &core) {
    return core.render_context_callback_installed_;
  }

  [[nodiscard]] static bool hasSelfKeepalive(const PlayerCore &core) {
    return static_cast<bool>(core.render_context_keepalive_);
  }

  [[nodiscard]] static RenderTicket lifecycle(const PlayerCore &core) {
    return core.renderLifecycleSnapshot();
  }

  [[nodiscard]] static std::uint64_t freeCount(const PlayerCore &core) {
    return core.render_context_free_count_for_testing_.load(
        std::memory_order_acquire);
  }

  [[nodiscard]] static std::uint64_t invalidationCount(const PlayerCore &core) {
    return core.render_context_invalidation_notify_count_for_testing_.load(
        std::memory_order_acquire);
  }

  [[nodiscard]] static std::uint64_t readyCount(const PlayerCore &core) {
    return core.render_context_ready_notify_count_for_testing_.load(
        std::memory_order_acquire);
  }

  [[nodiscard]] static std::uint64_t errorCount(const PlayerCore &core) {
    return core.render_context_error_notify_count_for_testing_.load(
        std::memory_order_acquire);
  }
};

} // namespace wam::qt

namespace {

using namespace std::chrono_literals;
using Access = wam::qt::PlayerControllerTestAccess;

int failures = 0;

void expect(bool condition, const char *message) {
  if (condition) {
    return;
  }
  std::cerr << "FAIL: " << message << '\n';
  ++failures;
}

class TimedHookBarrier final {
public:
  void pauseInHook() {
    reached_.release();
    hook_resumed_.store(resume_.try_acquire_for(5s), std::memory_order_release);
  }

  [[nodiscard]] bool waitUntilReached() {
    const bool reached = reached_.try_acquire_for(5s);
    observer_reached_.store(reached, std::memory_order_release);
    return reached;
  }

  void resumeHook() { resume_.release(); }

  [[nodiscard]] bool completed() const {
    return observer_reached_.load(std::memory_order_acquire) &&
           hook_resumed_.load(std::memory_order_acquire);
  }

private:
  std::binary_semaphore reached_{0};
  std::binary_semaphore resume_{0};
  std::atomic<bool> observer_reached_{false};
  std::atomic<bool> hook_resumed_{false};
};

struct RevokeObservation {
  bool reached{false};
  bool busyBeforeRevoke{false};
  bool allowedAfterRevoke{true};
  bool allowedAfterReallow{false};
  wam::qt::RenderTicket lifecycleBeforeRevoke;
};

RevokeObservation revokeAtBarrier(wam::qt::PlayerCore &core,
                                  TimedHookBarrier &barrier) {
  RevokeObservation result;
  result.reached = barrier.waitUntilReached();
  if (!result.reached) {
    // Avoid stranding a hook that reached its pause at the timeout boundary.
    barrier.resumeHook();
    return result;
  }
  result.busyBeforeRevoke = core.renderContextBusy();
  result.lifecycleBeforeRevoke = core.renderLifecycleSnapshot();
  core.revokeRenderContext();
  result.allowedAfterRevoke = core.renderContextAllowed();
  barrier.resumeHook();
  return result;
}

RevokeObservation revokeAndReallowAtBarrier(wam::qt::PlayerCore &core,
                                            TimedHookBarrier &barrier) {
  RevokeObservation result;
  result.reached = barrier.waitUntilReached();
  if (!result.reached) {
    barrier.resumeHook();
    return result;
  }
  result.busyBeforeRevoke = core.renderContextBusy();
  result.lifecycleBeforeRevoke = core.renderLifecycleSnapshot();
  core.revokeRenderContext();
  result.allowedAfterRevoke = core.renderContextAllowed();
  core.allowRenderContext();
  result.allowedAfterReallow = core.renderContextAllowed();
  barrier.resumeHook();
  return result;
}

bool makeCurrentOffscreen(QOpenGLContext &context, QOffscreenSurface &surface,
                          QOpenGLContext *share_context = nullptr) {
  QSurfaceFormat format;
  format.setRenderableType(QSurfaceFormat::OpenGL);
#if defined(Q_OS_MACOS)
  format.setProfile(QSurfaceFormat::CoreProfile);
  format.setVersion(3, 2);
#endif
  context.setFormat(format);
  if (share_context)
    context.setShareContext(share_context);
  if (!context.create()) {
    return false;
  }
  surface.setFormat(context.format());
  surface.create();
  return surface.isValid() && context.makeCurrent(&surface);
}

} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  const bool notification_only =
      argc == 2 && std::strcmp(argv[1], "--notification-only") == 0;
  expect(std::setlocale(LC_NUMERIC, "C") != nullptr,
         "LC_NUMERIC can be restored for libmpv");

  // libmpv invokes these callbacks on foreign threads and explicitly forbids
  // exceptions from leaving them. A failed Qt dispatch must also release its
  // coalescing reservation so the next callback can retry.
  expect(Access::callbacksAreNoexcept(),
         "every libmpv callback entry point is declared noexcept");
  {
    wam::qt::PlayerController callback_owner;
    const auto callback_core = Access::core(callback_owner);
    expect(static_cast<bool>(callback_core),
           "the callback test owns a dormant PlayerCore");

    int event_retry_count = 0;
    Access::injectEventQueue(*callback_core,
                             []() -> bool { throw std::bad_alloc{}; });
    Access::invokeWakeupCallback(*callback_core);
    expect(!Access::eventDrainQueued(*callback_core),
           "a throwing event dispatch rolls back its coalescing bit");
    Access::injectEventQueue(*callback_core, [&] {
      ++event_retry_count;
      return false;
    });
    Access::invokeWakeupCallback(*callback_core);
    expect(event_retry_count == 1 && !Access::eventDrainQueued(*callback_core),
           "a failed event dispatch remains retryable and rolls back");

    int video_retry_count = 0;
    Access::injectVideoQueue(*callback_core,
                             []() -> bool { throw std::bad_alloc{}; });
    Access::invokeRenderUpdateCallback(*callback_core);
    expect(!Access::videoUpdateQueued(*callback_core),
           "a throwing video dispatch rolls back its coalescing bit");
    Access::injectVideoQueue(*callback_core, [&] {
      ++video_retry_count;
      return false;
    });
    Access::invokeRenderUpdateCallback(*callback_core);
    expect(video_retry_count == 1 && !Access::videoUpdateQueued(*callback_core),
           "a failed video dispatch remains retryable and rolls back");

    Access::clearHooks(*callback_core);

    Access::injectEventWork(*callback_core, [] { throw std::bad_alloc{}; });
    Access::invokeWakeupCallback(*callback_core);
    QCoreApplication::sendPostedEvents(&callback_owner);
    expect(!Access::eventDrainQueued(*callback_core),
           "throwing queued event work escapes neither Qt nor coalescing");

    Access::injectVideoWork(*callback_core, [] { throw std::bad_alloc{}; });
    Access::invokeRenderUpdateCallback(*callback_core);
    QCoreApplication::sendPostedEvents(&callback_owner);
    expect(!Access::videoUpdateQueued(*callback_core),
           "throwing queued video work rolls back its coalescing bit");

    Access::clearHooks(*callback_core);

    // Ready and invalidation are one-shot lifecycle facts. A failed Qt queue
    // must retain the exact stamp, roll back queue admission, and allow a
    // later bounded retry. Controller work is likewise exception-contained:
    // it is acknowledged only after returning successfully.
    wam::qt::RenderLifecycle notification_lifecycle;
    const auto notification_creating =
        notification_lifecycle.beginCreation();
    const auto notification_ready =
        notification_creating
            ? notification_lifecycle.completeCreation(*notification_creating,
                                                       true)
            : std::nullopt;
    expect(notification_ready.has_value(),
           "notification test creates an exact synthetic Ready ticket");
    const wam::qt::RenderTicket ready_ticket =
        notification_ready.value_or(wam::qt::RenderTicket{});

    // Persistent notification queue failure must request a later frame as its
    // liveness trigger. The video queue seam proves that trigger without
    // entering Qt's event loop.
    int retry_frame_requests = 0;
    Access::injectVideoQueue(*callback_core, [&] {
      ++retry_frame_requests;
      return false;
    });
    int ready_queue_attempts = 0;
    Access::injectRenderNotificationQueue(*callback_core, [&] {
      ++ready_queue_attempts;
      return false;
    });
    Access::notifyReady(*callback_core, ready_ticket);
    expect(ready_queue_attempts == 3 && retry_frame_requests == 1 &&
               !Access::renderNotificationQueued(*callback_core) &&
               Access::pendingReadyNotification(*callback_core) ==
                   ready_ticket.stamp,
           "three failed Ready queue attempts retain one retryable exact fact");

    int ready_work_attempts = 0;
    Access::injectRenderNotificationQueue(*callback_core,
                                          [] { return true; });
    Access::injectReadyNotificationWork(
        *callback_core, [&](std::uint64_t stamp) {
          ++ready_work_attempts;
          expect(stamp == ready_ticket.stamp,
                 "Ready work receives the exact retained stamp");
          if (ready_work_attempts == 1)
            throw std::bad_alloc{};
        });
    Access::retryRenderNotifications(*callback_core);
    expect(Access::renderNotificationQueued(*callback_core),
           "a later Ready retry reserves one notification drain");
    Access::drainRenderNotifications(*callback_core, callback_owner);
    expect(ready_work_attempts == 1 &&
               Access::renderNotificationQueued(*callback_core) &&
               Access::pendingReadyNotification(*callback_core) ==
                   ready_ticket.stamp,
           "throwing Ready work remains pending and is requeued");
    Access::drainRenderNotifications(*callback_core, callback_owner);
    expect(ready_work_attempts == 2 &&
               !Access::renderNotificationQueued(*callback_core) &&
               Access::pendingReadyNotification(*callback_core) == 0,
           "successful Ready retry consumes the exact fact once");

    const auto retired_ticket = notification_lifecycle.invalidate();
    expect(retired_ticket && *retired_ticket == ready_ticket,
           "notification invalidation retires the synthetic Ready ticket");
    int invalidation_queue_attempts = 0;
    Access::injectRenderNotificationQueue(*callback_core, [&]() -> bool {
      ++invalidation_queue_attempts;
      throw std::bad_alloc{};
    });
    Access::notifyInvalidated(
        *callback_core,
        retired_ticket.value_or(wam::qt::RenderTicket{}));
    expect(invalidation_queue_attempts == 3 && retry_frame_requests == 2 &&
               !Access::renderNotificationQueued(*callback_core) &&
               Access::pendingInvalidationNotification(*callback_core) ==
                   ready_ticket.stamp,
           "throwing invalidation queues escape neither release nor recovery");
    expect(!Access::notificationAllowsCreation(*callback_core) &&
               invalidation_queue_attempts == 6 &&
               retry_frame_requests == 3 &&
               Access::pendingInvalidationNotification(*callback_core) ==
                   ready_ticket.stamp,
           "pending invalidation blocks replacement creation and retries");

    int invalidation_work_attempts = 0;
    Access::injectRenderNotificationQueue(*callback_core,
                                          [] { return true; });
    Access::injectInvalidationNotificationWork(
        *callback_core, [&](std::uint64_t stamp) {
          ++invalidation_work_attempts;
          expect(stamp == ready_ticket.stamp,
                 "invalidation work receives the exact retained stamp");
          if (invalidation_work_attempts == 1)
            throw std::bad_alloc{};
        });
    Access::retryRenderNotifications(*callback_core);
    Access::drainRenderNotifications(*callback_core, callback_owner);
    expect(invalidation_work_attempts == 1 &&
               Access::renderNotificationQueued(*callback_core) &&
               Access::pendingInvalidationNotification(*callback_core) ==
                   ready_ticket.stamp,
           "throwing invalidation work retains fail-closed recovery");
    Access::drainRenderNotifications(*callback_core, callback_owner);
    expect(invalidation_work_attempts == 2 &&
               !Access::renderNotificationQueued(*callback_core) &&
               Access::pendingInvalidationNotification(*callback_core) == 0,
           "successful invalidation retry consumes recovery exactly once");
    expect(Access::notificationAllowsCreation(*callback_core),
           "delivered invalidation reopens exact replacement creation");

    Access::clearHooks(*callback_core);
  }

  // A real context-bound Qt functor owns a PlayerCore keepalive, while owner
  // detach clears retained facts. Destroying the controller before dispatch
  // must therefore discard the callback without dereferencing either object.
  {
    auto retiring_owner = std::make_unique<wam::qt::PlayerController>();
    const auto retiring_core = Access::core(*retiring_owner);
    wam::qt::RenderLifecycle lifecycle;
    const auto creating = lifecycle.beginCreation();
    const auto ready = creating
                           ? lifecycle.completeCreation(*creating, true)
                           : std::nullopt;
    expect(retiring_core && ready,
           "owner-retirement test has a shared core and Ready ticket");
    if (retiring_core && ready)
      Access::notifyReady(*retiring_core, *ready);
    expect(retiring_core &&
               Access::renderNotificationQueued(*retiring_core),
           "a real context-bound Ready callback is queued before teardown");
    retiring_owner.reset();
    QCoreApplication::sendPostedEvents(nullptr);
    expect(retiring_core &&
               !Access::renderNotificationQueued(*retiring_core) &&
               Access::pendingReadyNotification(*retiring_core) == 0 &&
               Access::pendingInvalidationNotification(*retiring_core) == 0,
           "owner detach discards queued notification state safely");
  }

  if (notification_only) {
    if (failures != 0) {
      std::cerr << failures
                << " PlayerCore notification barrier check(s) failed\n";
      return EXIT_FAILURE;
    }
    std::cout << "PlayerCore notification barrier passed: noexcept queue "
                 "rollback, bounded retry, exact Ready/invalidation work, "
                 "and owner teardown\n";
    return EXIT_SUCCESS;
  }

  QOpenGLContext gl_context;
  QOffscreenSurface gl_surface;
  if (!makeCurrentOffscreen(gl_context, gl_surface)) {
    std::cerr
        << "FAIL: Qt could not create a current offscreen OpenGL context\n";
    return EXIT_FAILURE;
  }

  auto core_owner = std::make_shared<wam::qt::PlayerCore>(nullptr);
  wam::qt::PlayerCore &core = *core_owner;
  const auto runtime =
      wam::playback::mpv::makeInjectedLinkedMpvRuntime();
  expect(core.initialize(runtime),
         "PlayerCore initializes through the injected mpv table");
  if (!core.ready()) {
    std::cerr << "FAIL: " << core.initializationError().toStdString() << '\n';
    return EXIT_FAILURE;
  }

  expect(core.renderContextAllowed(), "render permission starts enabled");
  expect(!core.renderContextBusy(), "a fresh core is not Busy");
  expect(core.renderContextCreateCount() == 0,
         "a fresh core has not called the render API");
  expect(Access::freeCount(core) == 0,
         "a fresh core has not freed a render context");
  expect(Access::invalidationCount(core) == 0,
         "a fresh core has no invalidation notification");
  expect(Access::readyCount(core) == 0,
         "a fresh core has no Ready notification");
  expect(Access::errorCount(core) == 0,
         "a fresh core has no render error notification");
  const wam::qt::RenderTicket fresh_lifecycle =
      core.renderLifecycleSnapshot();
  expect(wam::qt::RenderLifecycle::phase(fresh_lifecycle) ==
             wam::qt::RenderPhase::Empty,
         "the public lifecycle snapshot reports fresh Empty phase");
  expect(wam::qt::RenderLifecycle::generation(fresh_lifecycle) == 1,
         "the public lifecycle snapshot reports the fresh generation");
  expect(core.renderLifecycleSnapshot() == fresh_lifecycle,
         "repeated public snapshots never mutate an Empty lifecycle");

  // Permission denied before entry must prevent the expensive API call.
  core.revokeRenderContext();
  expect(!core.ensureRenderContext(), "deny-before-create rejects creation");
  expect(core.renderContextCreateCount() == 0,
         "deny-before-create never calls mpv_render_context_create");
  expect(!core.renderContextBusy(),
         "deny-before-create leaves no Busy reservation");
  expect(!Access::hasRenderContext(core),
         "deny-before-create installs no context");
  expect(Access::errorCount(core) == 0,
         "permission denial is not a renderer error");
  const std::uint64_t after_deny_invalidations =
      Access::invalidationCount(core);
  expect(after_deny_invalidations == 0,
         "deny-before-create does not churn the Empty lifecycle");

  // Revoke after Busy admission but before the API boundary. The observer
  // thread never touches Qt/GL; the current-context thread remains the caller.
  core.allowRenderContext();
  TimedHookBarrier before_api;
  Access::setBeforeCreate(core, [&] { before_api.pauseInHook(); });
  RevokeObservation before_api_observation;
  std::thread before_api_revoker(
      [&] { before_api_observation = revokeAtBarrier(core, before_api); });
  const bool created_before_api = core.ensureRenderContext();
  before_api_revoker.join();
  Access::setBeforeCreate(core, {});
  expect(before_api.completed() && before_api_observation.reached,
         "the pre-API revocation barrier completed");
  expect(before_api_observation.busyBeforeRevoke,
         "Busy is visible before API admission");
  expect(wam::qt::RenderLifecycle::phase(
             before_api_observation.lifecycleBeforeRevoke) ==
             wam::qt::RenderPhase::Creating,
         "the public lifecycle snapshot observes in-flight Creating phase");
  expect(wam::qt::RenderLifecycle::generation(
             before_api_observation.lifecycleBeforeRevoke) ==
             wam::qt::RenderLifecycle::generation(fresh_lifecycle),
         "Creating preserves the exact fresh lifecycle generation");
  expect(!before_api_observation.allowedAfterRevoke,
         "revocation clears Allowed without waiting for render_mutex");
  expect(!created_before_api,
         "revocation during Busy prevents context publication");
  expect(core.renderContextCreateCount() == 0,
         "revocation before the API still makes zero create calls");
  expect(!core.renderContextBusy() && !Access::hasRenderContext(core),
         "pre-API revocation clears Busy and installs nothing");
  expect(Access::invalidationCount(core) == after_deny_invalidations + 1,
         "pre-API revocation emits one invalidation");
  expect(Access::errorCount(core) == 0,
         "pre-API revocation emits no initialization error");

  // Let real libmpv create a candidate, then revoke before it can be installed.
  core.allowRenderContext();
  TimedHookBarrier after_api;
  Access::setAfterCreate(core, [&] { after_api.pauseInHook(); });
  RevokeObservation after_api_observation;
  std::thread after_api_revoker(
      [&] { after_api_observation = revokeAtBarrier(core, after_api); });
  const bool installed_after_api = core.ensureRenderContext();
  after_api_revoker.join();
  Access::setAfterCreate(core, {});
  expect(after_api.completed() && after_api_observation.reached,
         "the post-create revocation barrier completed");
  expect(after_api_observation.busyBeforeRevoke,
         "Busy remains set while a real candidate is uninstalled");
  expect(!installed_after_api,
         "post-create revocation prevents candidate installation");
  expect(core.renderContextCreateCount() == 1,
         "post-create revocation makes exactly one real create call");
  expect(Access::freeCount(core) == 1,
         "the revoked real candidate is freed in the current GL context");
  expect(!core.renderContextBusy() && !Access::hasRenderContext(core),
         "discarding the revoked candidate clears Busy");
  expect(Access::invalidationCount(core) == after_deny_invalidations + 2,
         "post-create revocation emits one invalidation");
  expect(Access::errorCount(core) == 0,
         "a successfully created but revoked candidate is not an error");
  expect(Access::readyCount(core) == 0,
         "a revoked candidate never publishes Ready");

  // Latest intent wins while Busy: revoke and re-allow after a successful API
  // call, before publication, and retain that exact candidate as Ready.
  core.allowRenderContext();
  TimedHookBarrier latest_intent;
  Access::setAfterCreate(core, [&] { latest_intent.pauseInHook(); });
  RevokeObservation latest_intent_observation;
  std::thread latest_intent_observer([&] {
    latest_intent_observation = revokeAndReallowAtBarrier(core, latest_intent);
  });
  const bool installed_latest_intent = core.ensureRenderContext();
  latest_intent_observer.join();
  Access::setAfterCreate(core, {});
  expect(latest_intent.completed() && latest_intent_observation.reached,
         "the latest-intent barrier completed");
  expect(latest_intent_observation.busyBeforeRevoke &&
             !latest_intent_observation.allowedAfterRevoke &&
             latest_intent_observation.allowedAfterReallow,
         "re-allow restores permission while the sole candidate is Busy");
  expect(installed_latest_intent,
         "the latest re-allow publishes the exact candidate as Ready");
  const auto first_ready = core.readyRenderTicket();
  expect(first_ready.has_value(), "the first installed context has a ticket");
  const wam::qt::RenderTicket first_ready_snapshot =
      core.renderLifecycleSnapshot();
  expect(first_ready && first_ready_snapshot == *first_ready,
         "the public lifecycle snapshot returns the exact Ready ticket");
  expect(wam::qt::RenderLifecycle::phase(first_ready_snapshot) ==
             wam::qt::RenderPhase::Ready,
         "the public lifecycle snapshot exposes Ready phase");
  expect(Access::readyCount(core) == 1,
         "the first installed context publishes Ready exactly once");
  expect(core.renderContextCreateCount() == 2,
         "the first active context is the second create call");
  expect(core.renderContextBusy() && Access::hasRenderContext(core),
         "an installed context retains Busy ownership");

  // An installed context remains Busy after GUI-thread revoke until the
  // render thread frees it with the owning GL context current.
  RevokeObservation active_revoke_observation;
  std::thread active_revoker([&] {
    active_revoke_observation.busyBeforeRevoke = core.renderContextBusy();
    core.revokeRenderContext();
    active_revoke_observation.allowedAfterRevoke = core.renderContextAllowed();
  });
  active_revoker.join();
  expect(active_revoke_observation.busyBeforeRevoke,
         "the observer sees active Busy ownership before revocation");
  expect(!active_revoke_observation.allowedAfterRevoke &&
             !core.renderContextAllowed() && core.renderContextBusy(),
         "active revoke is nonblocking and leaves release to render thread");
  const std::uint64_t before_active_release_invalidations =
      Access::invalidationCount(core);
  expect(core.releaseRenderContext(),
         "the owning render context accepts active release");
  expect(!core.renderContextBusy() && !Access::hasRenderContext(core),
         "render-thread release frees the revoked active context");
  expect(Access::freeCount(core) == 2,
         "active release performs exactly one additional free");
  expect(Access::invalidationCount(core) ==
             before_active_release_invalidations + 1,
         "active release emits exactly one invalidation");
  const wam::qt::RenderTicket after_active_release_snapshot =
      core.renderLifecycleSnapshot();
  expect(wam::qt::RenderLifecycle::phase(after_active_release_snapshot) ==
             wam::qt::RenderPhase::Empty,
         "the public lifecycle snapshot observes revoked Empty phase");
  expect(first_ready &&
             wam::qt::RenderLifecycle::generation(
                 after_active_release_snapshot) ==
                 wam::qt::RenderLifecycle::generation(*first_ready) + 1,
         "revoked Empty snapshot advances the Ready generation exactly once");
  expect(core.renderLifecycleSnapshot() == after_active_release_snapshot,
         "snapshot observation does not advance revoked Empty lifecycle");
  const std::uint64_t after_active_release_invalidations =
      Access::invalidationCount(core);
  expect(core.releaseRenderContext() && core.releaseRenderContext(),
         "empty repeated release is successful and idempotent");
  expect(Access::freeCount(core) == 2, "repeated release never double-frees");
  expect(Access::invalidationCount(core) == after_active_release_invalidations,
         "repeated release never duplicates invalidation");

  // Re-enable starts a new lifecycle generation and exactly one new create.
  core.allowRenderContext();
  expect(core.ensureRenderContext(), "re-enable permits a replacement context");
  const auto second_ready = core.readyRenderTicket();
  expect(second_ready.has_value(),
         "the replacement context publishes a Ready ticket");
  expect(first_ready && second_ready &&
             wam::qt::RenderLifecycle::generation(*second_ready) ==
                 wam::qt::RenderLifecycle::generation(*first_ready) + 1,
         "replacement Ready advances the lifecycle by exactly one generation");
  expect(core.renderContextCreateCount() == 3,
         "re-enable makes exactly one replacement create call");
  expect(core.ensureRenderContext(),
         "ensuring an already active context is idempotent");
  expect(core.renderContextCreateCount() == 3,
         "an active Ready context is never created twice");
  expect(Access::readyCount(core) == 2,
         "replacement creation publishes one additional Ready event");

  // The exact helper called by MpvRenderNode releases when presentation is
  // suppressed, and repeated suppressed passes remain idempotent.
  const std::uint64_t before_node_release_invalidations =
      Access::invalidationCount(core);
  expect(!wam::qt::retainMpvRenderContextForPass(core, false),
         "render_requested=false rejects the node render pass");
  expect(!core.renderContextBusy() && !Access::hasRenderContext(core),
         "render_requested=false releases the active context");
  expect(Access::freeCount(core) == 3,
         "node suppression frees exactly one active context");
  expect(Access::invalidationCount(core) ==
             before_node_release_invalidations + 1,
         "node suppression emits exactly one invalidation");
  expect(!wam::qt::retainMpvRenderContextForPass(core, false),
         "a repeated suppressed pass remains rejected");
  expect(Access::freeCount(core) == 3 &&
             Access::invalidationCount(core) ==
                 before_node_release_invalidations + 1,
         "repeated node suppression neither frees nor invalidates twice");

  core.allowRenderContext();
  expect(core.ensureRenderContext(),
         "node retain test creates a fresh allowed context");
  expect(wam::qt::retainMpvRenderContextForPass(core, true),
         "render_requested=true retains an allowed context");
  expect(core.renderContextBusy() && Access::hasRenderContext(core),
         "the retained node context remains active");
  expect(core.renderContextCreateCount() == 4,
         "the retained node context adds one create call");
  expect(Access::readyCount(core) == 3,
         "the retained node context publishes one Ready event");
  const std::uint64_t before_node_revoke_invalidations =
      Access::invalidationCount(core);
  core.revokeRenderContext();
  expect(!wam::qt::retainMpvRenderContextForPass(core, true),
         "a revoked permission releases even a requested node context");
  expect(Access::freeCount(core) == 4 && !core.renderContextBusy(),
         "revoked node release frees once and clears Busy");
  expect(Access::invalidationCount(core) ==
             before_node_revoke_invalidations + 1,
         "revoked requested pass invalidates exactly once");

  // A genuine API failure is Failed+error, unlike every revocation path.
  core.allowRenderContext();
  Access::injectCreate(core, [](mpv_render_context **candidate, mpv_handle *,
                                mpv_render_param *) {
    *candidate = nullptr;
    return MPV_ERROR_GENERIC;
  });
  const std::uint64_t before_failure_errors = Access::errorCount(core);
  const std::uint64_t before_failure_invalidations =
      Access::invalidationCount(core);
  expect(!core.ensureRenderContext(),
         "an injected mpv create failure is rejected");
  const wam::qt::RenderTicket failed_ticket = Access::lifecycle(core);
  expect(wam::qt::RenderLifecycle::phase(failed_ticket) ==
             wam::qt::RenderPhase::Failed,
         "a genuine create error latches Failed");
  expect(core.renderContextCreateCount() == 5,
         "the injected failure is one accounted create attempt");
  expect(Access::errorCount(core) == before_failure_errors + 1,
         "a genuine create failure emits one error");
  expect(Access::invalidationCount(core) == before_failure_invalidations,
         "a genuine create failure is not mislabeled as revocation");
  expect(!core.renderContextBusy() && !Access::hasRenderContext(core),
         "a failed create leaves no Busy context");
  expect(!core.ensureRenderContext(),
         "a latched Failed generation does not retry itself");
  expect(core.renderContextCreateCount() == 5 &&
             Access::errorCount(core) == before_failure_errors + 1,
         "repeated Failed renders duplicate neither create nor error");
  expect(core.retryFailedRenderContext(),
         "explicit retry rearms a failed render generation");

  // Contrast the genuine failure above with the same failed API result when
  // revocation wins after the call but before Failed can be published.
  TimedHookBarrier failed_api_revoke;
  Access::setAfterApi(core, [&] { failed_api_revoke.pauseInHook(); });
  RevokeObservation failed_api_observation;
  std::thread failed_api_revoker([&] {
    failed_api_observation = revokeAtBarrier(core, failed_api_revoke);
  });
  const std::uint64_t before_final_revoke_errors = Access::errorCount(core);
  const std::uint64_t before_final_revoke_creates =
      core.renderContextCreateCount();
  const std::uint64_t before_final_revoke_invalidations =
      Access::invalidationCount(core);
  const bool installed_failed_api = core.ensureRenderContext();
  failed_api_revoker.join();
  Access::setAfterApi(core, {});
  expect(failed_api_revoke.completed() && failed_api_observation.reached,
         "the failed-API revocation barrier completed");
  expect(failed_api_observation.busyBeforeRevoke,
         "a failed API result remains Busy until publication decision");
  expect(!installed_failed_api,
         "a revoked failed API result installs no context");
  expect(core.renderContextCreateCount() == before_final_revoke_creates + 1,
         "the revoked failure reached exactly one API call");
  expect(Access::errorCount(core) == before_final_revoke_errors,
         "revocation suppresses the failed API renderer error");
  expect(Access::invalidationCount(core) ==
             before_final_revoke_invalidations + 1,
         "revoked API failure retires exactly one Creating generation");
  expect(Access::readyCount(core) == 3,
         "neither genuine nor revoked create failure publishes Ready");
  expect(!core.renderContextBusy() && !Access::hasRenderContext(core),
         "revoked API failure leaves no context ownership");

  Access::clearHooks(core);
  core_owner.reset();

  // Exact-context ownership is stricter than share-group compatibility. A
  // second context shares A's objects but must still be unable to release A's
  // libmpv renderer.
  QOpenGLContext wrong_context;
  QOffscreenSurface wrong_surface;
  expect(makeCurrentOffscreen(wrong_context, wrong_surface, &gl_context),
         "a second shared offscreen context becomes current");
  expect(wrong_context.shareGroup() == gl_context.shareGroup(),
         "context B shares context A's OpenGL object namespace");
  expect(gl_context.makeCurrent(&gl_surface),
         "the exact owner context can be restored after creating B");

  std::atomic<std::uint64_t> exact_terminations{0};
  auto exact_core = std::make_shared<wam::qt::PlayerCore>(nullptr);
  Access::setBeforeTerminate(*exact_core, [&](mpv_handle *) {
    exact_terminations.fetch_add(1, std::memory_order_relaxed);
  });
  expect(exact_core->initialize(runtime),
         "the exact-context core initializes through the injected table");
  expect(exact_core->ensureRenderContext(),
         "context A creates and publishes the exact-owned renderer");
  expect(Access::renderContextOwner(*exact_core) == &gl_context &&
             Access::callbackInstalled(*exact_core) &&
             Access::hasSelfKeepalive(*exact_core),
         "Ready retains context A, its callback, and a self-keepalive");
  expect(Access::freeCount(*exact_core) == 0,
         "the exact-owned renderer begins with no free calls");
  const std::uint64_t exact_ready_invalidations =
      Access::invalidationCount(*exact_core);

  expect(wrong_context.makeCurrent(&wrong_surface),
         "shared context B becomes current for the wrong-owner release");
  expect(!exact_core->releaseRenderContext(),
         "shared context B cannot release context A's renderer");
  expect(
      Access::freeCount(*exact_core) == 0 &&
          Access::invalidationCount(*exact_core) == exact_ready_invalidations &&
          exact_core->renderContextBusy() &&
          Access::hasRenderContext(*exact_core) &&
          Access::callbackInstalled(*exact_core) &&
          Access::hasSelfKeepalive(*exact_core),
      "wrong-context release preserves resources, lifecycle, Busy, and self");

  wrong_context.doneCurrent();
  expect(QOpenGLContext::currentContext() == nullptr,
         "the no-current release seam has no ambient Qt GL context");
  expect(!exact_core->releaseRenderContext(),
         "no-current release cannot free an exact-owned renderer");
  expect(Access::freeCount(*exact_core) == 0 &&
             exact_core->renderContextBusy() &&
             Access::renderContextOwner(*exact_core) == &gl_context &&
             Access::callbackInstalled(*exact_core),
         "no-current release leaves the exact owner and renderer intact");

  expect(wrong_context.makeCurrent(&wrong_surface),
         "context B is current while the last external owner is dropped");
  std::weak_ptr<wam::qt::PlayerCore> exact_weak = exact_core;
  exact_core.reset();
  expect(!exact_weak.expired() &&
             exact_terminations.load(std::memory_order_acquire) == 0,
         "the self-keepalive prevents destruction under the wrong context");
  auto exact_survivor = exact_weak.lock();
  expect(exact_survivor && exact_survivor->renderContextBusy() &&
             Access::freeCount(*exact_survivor) == 0,
         "the retained core remains observable without an unsafe free");

  wrong_context.doneCurrent();
  expect(gl_context.makeCurrent(&gl_surface),
         "context A is restored for exact retirement");
  expect(exact_survivor && exact_survivor->releaseRenderContext(),
         "the exact owner releases its renderer successfully");
  expect(exact_survivor && Access::freeCount(*exact_survivor) == 1 &&
             !exact_survivor->renderContextBusy() &&
             !Access::hasRenderContext(*exact_survivor) &&
             Access::renderContextOwner(*exact_survivor) == nullptr &&
             !Access::callbackInstalled(*exact_survivor) &&
             !Access::hasSelfKeepalive(*exact_survivor),
         "exact release frees once and clears every retained ownership field");
  const std::uint64_t exact_released_invalidations =
      Access::invalidationCount(*exact_survivor);
  expect(exact_released_invalidations == exact_ready_invalidations + 1,
         "exact release invalidates the Ready generation exactly once");
  expect(exact_survivor->releaseRenderContext(),
         "a second exact-context release is successful and idempotent");
  expect(Access::freeCount(*exact_survivor) == 1 &&
             Access::invalidationCount(*exact_survivor) ==
                 exact_released_invalidations,
         "idempotent exact release duplicates neither free nor invalidation");
  exact_survivor.reset();
  expect(
      exact_weak.expired() &&
          exact_terminations.load(std::memory_order_acquire) == 1,
      "breaking the self-cycle destroys and terminates the core exactly once");

  // A successful mpv API result that loses its creating context before
  // adoption remains retained, without a callback, until A is current again.
  std::atomic<std::uint64_t> switched_success_terminations{0};
  auto switched_success = std::make_shared<wam::qt::PlayerCore>(nullptr);
  Access::setBeforeTerminate(*switched_success, [&](mpv_handle *) {
    switched_success_terminations.fetch_add(1, std::memory_order_relaxed);
  });
  expect(switched_success->initialize(runtime),
         "the post-API success core initializes through the injected table");
  expect(gl_context.makeCurrent(&gl_surface),
         "context A is current before the post-API success switch");
  bool switched_success_to_b = false;
  Access::setAfterApi(*switched_success, [&] {
    switched_success_to_b = wrong_context.makeCurrent(&wrong_surface);
  });
  expect(!switched_success->ensureRenderContext(),
         "a post-API switch prevents success publication under context B");
  Access::setAfterApi(*switched_success, {});
  expect(switched_success_to_b &&
             QOpenGLContext::currentContext() == &wrong_context &&
             Access::hasRenderContext(*switched_success) &&
             Access::renderContextOwner(*switched_success) == &gl_context &&
             !Access::callbackInstalled(*switched_success) &&
             Access::hasSelfKeepalive(*switched_success) &&
             switched_success->renderContextBusy() &&
             wam::qt::RenderLifecycle::phase(Access::lifecycle(
                 *switched_success)) == wam::qt::RenderPhase::Creating,
         "post-API success retains its candidate under exact owner A");
  expect(Access::freeCount(*switched_success) == 0 &&
             Access::readyCount(*switched_success) == 0 &&
             Access::errorCount(*switched_success) == 0 &&
             Access::invalidationCount(*switched_success) == 0,
         "context loss publishes no false free, Ready, error, or invalidation");
  expect(!switched_success->releaseRenderContext(),
         "context B cannot retire the retained post-API success");
  expect(gl_context.makeCurrent(&gl_surface),
         "context A is restored for retained success retirement");
  expect(switched_success->releaseRenderContext(),
         "context A retires the retained post-API success");
  expect(Access::freeCount(*switched_success) == 1 &&
             Access::invalidationCount(*switched_success) == 1 &&
             !switched_success->renderContextBusy(),
         "retained success retires exactly once without Ready publication");
  switched_success.reset();
  expect(switched_success_terminations.load(std::memory_order_acquire) == 1,
         "the retired post-API success terminates exactly once");

  // The same owner rule applies to a failed API that returns a partial
  // candidate. A synthetic candidate makes any wrong-context free observable.
  std::atomic<std::uint64_t> partial_terminations{0};
  auto partial_core = std::make_shared<wam::qt::PlayerCore>(nullptr);
  Access::setBeforeTerminate(*partial_core, [&](mpv_handle *) {
    partial_terminations.fetch_add(1, std::memory_order_relaxed);
  });
  expect(partial_core->initialize(runtime),
         "the partial-failure core initializes through the injected table");
  auto *const partial_candidate = reinterpret_cast<mpv_render_context *>(
      static_cast<std::uintptr_t>(0x51AFC0DEU));
  bool partial_freed_exact_candidate = false;
  Access::injectCreate(*partial_core, [&](mpv_render_context **candidate,
                                          mpv_handle *, mpv_render_param *) {
    *candidate = partial_candidate;
    return MPV_ERROR_GENERIC;
  });
  Access::injectFree(*partial_core, [&](mpv_render_context *candidate) {
    partial_freed_exact_candidate = candidate == partial_candidate;
  });
  expect(gl_context.makeCurrent(&gl_surface),
         "context A is current before the partial-failure switch");
  bool switched_partial_to_b = false;
  Access::setAfterApi(*partial_core, [&] {
    switched_partial_to_b = wrong_context.makeCurrent(&wrong_surface);
  });
  expect(!partial_core->ensureRenderContext(),
         "a failed API's partial candidate is not published under context B");
  Access::setAfterApi(*partial_core, {});
  expect(switched_partial_to_b && Access::hasRenderContext(*partial_core) &&
             Access::renderContextOwner(*partial_core) == &gl_context &&
             !Access::callbackInstalled(*partial_core) &&
             Access::hasSelfKeepalive(*partial_core) &&
             partial_core->renderContextBusy() &&
             wam::qt::RenderLifecycle::phase(Access::lifecycle(
                 *partial_core)) == wam::qt::RenderPhase::Creating,
         "partial failure retains candidate, exact owner, Busy, and self");
  expect(Access::freeCount(*partial_core) == 0 &&
             Access::readyCount(*partial_core) == 0 &&
             Access::errorCount(*partial_core) == 0,
         "wrong-context partial failure emits no free, Ready, or error");
  expect(!partial_core->releaseRenderContext(),
         "context B cannot free the partial candidate");
  expect(gl_context.makeCurrent(&gl_surface),
         "context A is restored for partial-candidate retirement");
  expect(partial_core->releaseRenderContext(),
         "context A retires the partial candidate");
  expect(partial_freed_exact_candidate &&
             Access::freeCount(*partial_core) == 1 &&
             Access::invalidationCount(*partial_core) == 1 &&
             !partial_core->renderContextBusy(),
         "partial candidate is freed exactly once by its exact owner");
  partial_core.reset();
  expect(partial_terminations.load(std::memory_order_acquire) == 1,
         "the retired partial-failure core terminates exactly once");

  // Error text allocation happens only after exact-owner cleanup and Failed
  // publication. Even a deterministic bad_alloc must escape neither cleanup
  // nor the static fallback error notification.
  std::atomic<std::uint64_t> allocation_failure_terminations{0};
  auto allocation_failure = std::make_shared<wam::qt::PlayerCore>(nullptr);
  Access::setBeforeTerminate(*allocation_failure, [&](mpv_handle *) {
    allocation_failure_terminations.fetch_add(1, std::memory_order_relaxed);
  });
  expect(allocation_failure->initialize(runtime),
         "the allocation-failure core initializes through the injected table");
  auto *const allocation_failure_candidate =
      reinterpret_cast<mpv_render_context *>(
          static_cast<std::uintptr_t>(0xA110CA7EU));
  bool allocation_failure_freed_exact_candidate = false;
  Access::injectCreate(
      *allocation_failure,
      [&](mpv_render_context **candidate, mpv_handle *, mpv_render_param *) {
        *candidate = allocation_failure_candidate;
        return MPV_ERROR_GENERIC;
      });
  Access::injectFree(*allocation_failure, [&](mpv_render_context *candidate) {
    allocation_failure_freed_exact_candidate =
        candidate == allocation_failure_candidate;
  });
  Access::setBeforeErrorDiagnostic(*allocation_failure,
                                   [] { throw std::bad_alloc{}; });
  expect(gl_context.makeCurrent(&gl_surface),
         "context A is current for allocation-failure cleanup");
  bool allocation_exception_escaped = false;
  bool allocation_failure_installed = true;
  try {
    allocation_failure_installed = allocation_failure->ensureRenderContext();
  } catch (...) {
    allocation_exception_escaped = true;
  }
  expect(!allocation_exception_escaped && !allocation_failure_installed,
         "diagnostic bad_alloc is caught and cannot publish a renderer");
  expect(
      allocation_failure_freed_exact_candidate &&
          Access::freeCount(*allocation_failure) == 1 &&
          wam::qt::RenderLifecycle::phase(Access::lifecycle(
              *allocation_failure)) == wam::qt::RenderPhase::Failed &&
          !allocation_failure->renderContextBusy() &&
          !Access::hasRenderContext(*allocation_failure) &&
          Access::renderContextOwner(*allocation_failure) == nullptr &&
          !Access::callbackInstalled(*allocation_failure) &&
          !Access::hasSelfKeepalive(*allocation_failure),
      "bad_alloc follows exact free, Failed publication, and ownership clear");
  expect(
      Access::readyCount(*allocation_failure) == 0 &&
          Access::errorCount(*allocation_failure) == 1 &&
          Access::invalidationCount(*allocation_failure) == 0,
      "allocation fallback posts one error without false Ready/invalidation");
  expect(allocation_failure->releaseRenderContext(),
         "allocation-failure cleanup leaves idempotent empty release");
  allocation_failure.reset();
  expect(allocation_failure_terminations.load(std::memory_order_acquire) == 1,
         "the allocation-failure core terminates exactly once");

  // Admission without shared ownership cannot establish the callback
  // lifetime boundary and is rejected before the render API.
  std::atomic<std::uint64_t> stack_terminations{0};
  {
    wam::qt::PlayerCore stack_core(nullptr);
    Access::setBeforeTerminate(stack_core, [&](mpv_handle *) {
      stack_terminations.fetch_add(1, std::memory_order_relaxed);
    });
    expect(stack_core.initialize(runtime),
           "the non-shared core initializes through the injected table");
    expect(gl_context.makeCurrent(&gl_surface),
           "context A is current for non-shared admission rejection");
    expect(!stack_core.ensureRenderContext(),
           "non-shared PlayerCore cannot admit a render context");
    expect(stack_core.renderContextCreateCount() == 0 &&
               !stack_core.renderContextBusy() &&
               !Access::hasRenderContext(stack_core) &&
               Access::renderContextOwner(stack_core) == nullptr &&
               !Access::hasSelfKeepalive(stack_core) &&
               Access::invalidationCount(stack_core) == 1 &&
               Access::errorCount(stack_core) == 0,
           "non-shared rejection occurs before API and clears reservation");
    expect(stack_core.releaseRenderContext(),
           "non-shared empty release remains safely idempotent");
  }
  expect(stack_terminations.load(std::memory_order_acquire) == 1,
         "the rejected non-shared core terminates exactly once");

  // Destroying the exact QOpenGLContext makes safe release impossible. This
  // intentionally quarantined cycle is last: it must retain the callback
  // target for process lifetime rather than free through a wrong context.
  auto quarantined_terminations =
      std::make_shared<std::atomic<std::uint64_t>>(0);
  std::weak_ptr<wam::qt::PlayerCore> quarantined_weak;
  {
    QOpenGLContext doomed_context;
    QOffscreenSurface doomed_surface;
    expect(makeCurrentOffscreen(doomed_context, doomed_surface),
           "the doomed exact-owner context becomes current");
    auto quarantined_core = std::make_shared<wam::qt::PlayerCore>(nullptr);
    Access::setBeforeTerminate(
        *quarantined_core, [quarantined_terminations](mpv_handle *) {
          quarantined_terminations->fetch_add(1, std::memory_order_relaxed);
        });
    expect(quarantined_core->initialize(runtime),
           "the quarantine core initializes through the injected table");
    expect(quarantined_core->ensureRenderContext(),
           "the doomed owner creates an active renderer");
    quarantined_weak = quarantined_core;
    quarantined_core.reset();
    expect(!quarantined_weak.expired(),
           "self-keepalive retains the core before owner destruction");
    doomed_context.doneCurrent();
  }
  auto quarantined_survivor = quarantined_weak.lock();
  expect(quarantined_survivor &&
             Access::renderContextOwner(*quarantined_survivor) == nullptr &&
             Access::hasRenderContext(*quarantined_survivor) &&
             Access::callbackInstalled(*quarantined_survivor) &&
             Access::hasSelfKeepalive(*quarantined_survivor) &&
             quarantined_survivor->renderContextBusy() &&
             Access::readyCount(*quarantined_survivor) == 1 &&
             Access::invalidationCount(*quarantined_survivor) == 0,
         "destroyed QPointer owner leaves renderer and self quarantined");
  expect(quarantined_survivor && !quarantined_survivor->releaseRenderContext(),
         "a destroyed exact owner cannot be replaced by no current context");
  expect(quarantined_survivor &&
             Access::freeCount(*quarantined_survivor) == 0 &&
             quarantined_terminations->load(std::memory_order_acquire) == 0,
         "destroyed-owner quarantine invokes neither free nor terminate");
  quarantined_survivor.reset();
  expect(!quarantined_weak.expired() &&
             quarantined_terminations->load(std::memory_order_acquire) == 0,
         "process-lifetime quarantine outlives every external owner");

  gl_context.doneCurrent();

  if (failures != 0) {
    std::cerr << failures
              << " PlayerCore render-context permission check(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout
      << "PlayerCore render-context permission gate passed: "
         "deny-before-create, "
         "Busy pre-API revoke, post-create discard, active render-thread "
         "release, idempotent teardown, generation reuse, node suppression, "
         "latest-intent publication, exact-context self-keepalive, retained "
         "post-API candidates, and destroyed-owner quarantine\n";
  return EXIT_SUCCESS;
}
