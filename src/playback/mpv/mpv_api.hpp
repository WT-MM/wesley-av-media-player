#pragma once

#include <mpv/client.h>
#include <mpv/render.h>

namespace wam::playback::mpv {

// The complete libmpv surface used by WAM's compatibility player, in table
// order. Every list of these symbols is generated from this one.
#define WAM_MPV_API(X) \
  X(mpv_abort_async_command) \
  X(mpv_client_api_version) \
  X(mpv_command) \
  X(mpv_command_async) \
  X(mpv_create) \
  X(mpv_error_string) \
  X(mpv_free) \
  X(mpv_get_property) \
  X(mpv_get_property_string) \
  X(mpv_initialize) \
  X(mpv_observe_property) \
  X(mpv_render_context_create) \
  X(mpv_render_context_free) \
  X(mpv_render_context_get_info) \
  X(mpv_render_context_render) \
  X(mpv_render_context_set_update_callback) \
  X(mpv_render_context_update) \
  X(mpv_request_log_messages) \
  X(mpv_set_option_string) \
  X(mpv_set_property) \
  X(mpv_set_property_async) \
  X(mpv_set_property_string) \
  X(mpv_set_wakeup_callback) \
  X(mpv_terminate_destroy) \
  X(mpv_wait_event)

// Keeping the entries const makes a successfully resolved table immutable;
// callers can retain it only through the MpvRuntime that owns the loaded
// library.
struct MpvApi final {
#define WAM_MPV_API_MEMBER(name) const decltype(&::name) name;
  WAM_MPV_API(WAM_MPV_API_MEMBER)
#undef WAM_MPV_API_MEMBER

  [[nodiscard]] bool complete() const noexcept;
};

}  // namespace wam::playback::mpv
