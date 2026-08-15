#pragma once

#if !defined(WAM_MPV_RUNTIME_TESTING)
#error "injected_mpv_runtime.hpp is test-only"
#endif

#include "playback/mpv/mpv_runtime.hpp"

#include <memory>
#include <utility>

namespace wam::playback::mpv {

class MpvRuntimeTestAccess final {
 public:
  [[nodiscard]] static std::shared_ptr<const MpvRuntime> create(MpvApi api) {
    return std::shared_ptr<const MpvRuntime>(new MpvRuntime(
        std::move(api), MPV_CLIENT_API_VERSION,
        QStringLiteral("injected-test-mpv")));
  }
};

// The current render/controller tests intentionally exercise a real client
// through an explicitly injected immutable table. They perform no QLibrary
// load and therefore test PlayerCore's ownership/dispatch boundary separately
// from MpvRuntime's dedicated fake-dylib loader tests.
[[nodiscard]] inline std::shared_ptr<const MpvRuntime>
makeInjectedLinkedMpvRuntime() {
  return MpvRuntimeTestAccess::create(MpvApi{
      &::mpv_abort_async_command,
      &::mpv_client_api_version,
      &::mpv_command,
      &::mpv_command_async,
      &::mpv_create,
      &::mpv_error_string,
      &::mpv_free,
      &::mpv_get_property,
      &::mpv_get_property_string,
      &::mpv_initialize,
      &::mpv_observe_property,
      &::mpv_render_context_create,
      &::mpv_render_context_free,
      &::mpv_render_context_render,
      &::mpv_render_context_set_update_callback,
      &::mpv_render_context_update,
      &::mpv_request_log_messages,
      &::mpv_set_option_string,
      &::mpv_set_property,
      &::mpv_set_property_async,
      &::mpv_set_property_string,
      &::mpv_set_wakeup_callback,
      &::mpv_terminate_destroy,
      &::mpv_wait_event,
  });
}

}  // namespace wam::playback::mpv
