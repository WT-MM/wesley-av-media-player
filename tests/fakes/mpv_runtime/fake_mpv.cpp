#include <mpv/client.h>
#include <mpv/render.h>

#include <cstdint>

namespace {

#if !defined(WAM_FAKE_MPV_OMIT_WAIT_EVENT)
mpv_event g_empty_event{};
#endif

}  // namespace

extern "C" {

MPV_EXPORT unsigned long mpv_client_api_version() {
#if defined(WAM_FAKE_MPV_WRONG_MAJOR)
  return MPV_MAKE_VERSION((MPV_CLIENT_API_VERSION >> 16U) + 1U, 0U);
#elif defined(WAM_FAKE_MPV_OLD_MINOR)
  return MPV_CLIENT_API_VERSION - 1UL;
#elif defined(WAM_FAKE_MPV_NEWER_MINOR)
  return MPV_CLIENT_API_VERSION + 1UL;
#else
  return MPV_CLIENT_API_VERSION;
#endif
}

MPV_EXPORT void mpv_abort_async_command(mpv_handle*, std::uint64_t) {}

MPV_EXPORT int mpv_command(mpv_handle*, const char**) { return 0; }

MPV_EXPORT int mpv_command_async(mpv_handle*, std::uint64_t, const char**) {
  return 0;
}

MPV_EXPORT mpv_handle* mpv_create() {
  return reinterpret_cast<mpv_handle*>(static_cast<std::uintptr_t>(1));
}

MPV_EXPORT const char* mpv_error_string(int) {
#if defined(WAM_FAKE_MPV_COLLISION)
  return "collision mpv error";
#else
  return "fake mpv error";
#endif
}

MPV_EXPORT void mpv_free(void*) {}

MPV_EXPORT int mpv_get_property(mpv_handle*, const char*, mpv_format, void*) {
  return 0;
}

MPV_EXPORT char* mpv_get_property_string(mpv_handle*, const char*) {
  return nullptr;
}

MPV_EXPORT int mpv_initialize(mpv_handle*) { return 0; }

MPV_EXPORT int mpv_observe_property(mpv_handle*, std::uint64_t, const char*,
                                    mpv_format) {
  return 0;
}

MPV_EXPORT int mpv_render_context_create(mpv_render_context** result,
                                         mpv_handle*, mpv_render_param*) {
  if (result != nullptr) {
    *result = reinterpret_cast<mpv_render_context*>(
        static_cast<std::uintptr_t>(1));
  }
  return 0;
}

MPV_EXPORT void mpv_render_context_free(mpv_render_context*) {}

MPV_EXPORT int mpv_render_context_render(mpv_render_context*,
                                         mpv_render_param*) {
  return 0;
}

MPV_EXPORT void mpv_render_context_set_update_callback(
    mpv_render_context*, mpv_render_update_fn, void*) {}

MPV_EXPORT std::uint64_t mpv_render_context_update(mpv_render_context*) {
  return 0;
}

MPV_EXPORT int mpv_request_log_messages(mpv_handle*, const char*) { return 0; }

MPV_EXPORT int mpv_set_option_string(mpv_handle*, const char*, const char*) {
  return 0;
}

MPV_EXPORT int mpv_set_property(mpv_handle*, const char*, mpv_format, void*) {
  return 0;
}

MPV_EXPORT int mpv_set_property_async(mpv_handle*, std::uint64_t, const char*,
                                      mpv_format, void*) {
  return 0;
}

MPV_EXPORT int mpv_set_property_string(mpv_handle*, const char*, const char*) {
  return 0;
}

MPV_EXPORT void mpv_set_wakeup_callback(mpv_handle*, void (*)(void*), void*) {}

MPV_EXPORT void mpv_terminate_destroy(mpv_handle*) {}

#if !defined(WAM_FAKE_MPV_OMIT_WAIT_EVENT)
MPV_EXPORT mpv_event* mpv_wait_event(mpv_handle*, double) {
  return &g_empty_event;
}
#endif

}  // extern "C"
