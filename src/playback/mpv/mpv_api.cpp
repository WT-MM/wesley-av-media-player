#include "playback/mpv/mpv_api.hpp"

namespace wam::playback::mpv {

bool MpvApi::complete() const noexcept {
#define WAM_REQUIRE_MPV_SYMBOL(name)                                         \
  if (name == nullptr) {                                                     \
    return false;                                                            \
  }
  WAM_REQUIRE_MPV_SYMBOL(mpv_abort_async_command);
  WAM_REQUIRE_MPV_SYMBOL(mpv_client_api_version);
  WAM_REQUIRE_MPV_SYMBOL(mpv_command);
  WAM_REQUIRE_MPV_SYMBOL(mpv_command_async);
  WAM_REQUIRE_MPV_SYMBOL(mpv_create);
  WAM_REQUIRE_MPV_SYMBOL(mpv_error_string);
  WAM_REQUIRE_MPV_SYMBOL(mpv_free);
  WAM_REQUIRE_MPV_SYMBOL(mpv_get_property);
  WAM_REQUIRE_MPV_SYMBOL(mpv_get_property_string);
  WAM_REQUIRE_MPV_SYMBOL(mpv_initialize);
  WAM_REQUIRE_MPV_SYMBOL(mpv_observe_property);
  WAM_REQUIRE_MPV_SYMBOL(mpv_render_context_create);
  WAM_REQUIRE_MPV_SYMBOL(mpv_render_context_free);
  WAM_REQUIRE_MPV_SYMBOL(mpv_render_context_render);
  WAM_REQUIRE_MPV_SYMBOL(mpv_render_context_set_update_callback);
  WAM_REQUIRE_MPV_SYMBOL(mpv_render_context_update);
  WAM_REQUIRE_MPV_SYMBOL(mpv_request_log_messages);
  WAM_REQUIRE_MPV_SYMBOL(mpv_set_option_string);
  WAM_REQUIRE_MPV_SYMBOL(mpv_set_property);
  WAM_REQUIRE_MPV_SYMBOL(mpv_set_property_async);
  WAM_REQUIRE_MPV_SYMBOL(mpv_set_property_string);
  WAM_REQUIRE_MPV_SYMBOL(mpv_set_wakeup_callback);
  WAM_REQUIRE_MPV_SYMBOL(mpv_terminate_destroy);
  WAM_REQUIRE_MPV_SYMBOL(mpv_wait_event);
#undef WAM_REQUIRE_MPV_SYMBOL
  return true;
}

}  // namespace wam::playback::mpv
