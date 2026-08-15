#pragma once

#include <mpv/client.h>
#include <mpv/render.h>

namespace wam::playback::mpv {

// The complete libmpv surface used by WAM's compatibility player. Keeping
// the entries const makes a successfully resolved table immutable; callers
// can retain it only through the MpvRuntime that owns the loaded library.
struct MpvApi final {
  const decltype(&::mpv_abort_async_command) mpv_abort_async_command;
  const decltype(&::mpv_client_api_version) mpv_client_api_version;
  const decltype(&::mpv_command) mpv_command;
  const decltype(&::mpv_command_async) mpv_command_async;
  const decltype(&::mpv_create) mpv_create;
  const decltype(&::mpv_error_string) mpv_error_string;
  const decltype(&::mpv_free) mpv_free;
  const decltype(&::mpv_get_property) mpv_get_property;
  const decltype(&::mpv_get_property_string) mpv_get_property_string;
  const decltype(&::mpv_initialize) mpv_initialize;
  const decltype(&::mpv_observe_property) mpv_observe_property;
  const decltype(&::mpv_render_context_create) mpv_render_context_create;
  const decltype(&::mpv_render_context_free) mpv_render_context_free;
  const decltype(&::mpv_render_context_render) mpv_render_context_render;
  const decltype(&::mpv_render_context_set_update_callback)
      mpv_render_context_set_update_callback;
  const decltype(&::mpv_render_context_update) mpv_render_context_update;
  const decltype(&::mpv_request_log_messages) mpv_request_log_messages;
  const decltype(&::mpv_set_option_string) mpv_set_option_string;
  const decltype(&::mpv_set_property) mpv_set_property;
  const decltype(&::mpv_set_property_async) mpv_set_property_async;
  const decltype(&::mpv_set_property_string) mpv_set_property_string;
  const decltype(&::mpv_set_wakeup_callback) mpv_set_wakeup_callback;
  const decltype(&::mpv_terminate_destroy) mpv_terminate_destroy;
  const decltype(&::mpv_wait_event) mpv_wait_event;

  [[nodiscard]] bool complete() const noexcept;
};

}  // namespace wam::playback::mpv
