#include "playback/mpv/mpv_runtime.hpp"

#include <memory>
#include <utility>

namespace wam::playback::mpv {
namespace {

[[nodiscard]] MpvApi linkedApi() noexcept {
  return {
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
  };
}

}  // namespace

MpvRuntimeLoadResult MpvLinkedRuntimeFactory::create() {
  // Function-local initialization is thread-safe. The immutable result keeps
  // one process-wide identity while PlayerCore retains its own shared owner.
  static const MpvRuntimeLoadResult result = [] {
    const MpvApi api = linkedApi();
    if (!api.complete()) {
      return MpvRuntimeLoadResult{
          {}, MpvRuntimeLoadError::MissingSymbol,
          QStringLiteral("linked libmpv API table is incomplete")};
    }

    const unsigned long runtimeVersion = api.mpv_client_api_version();
    constexpr unsigned long headerVersion = MPV_CLIENT_API_VERSION;
    if ((runtimeVersion >> 16U) != (headerVersion >> 16U) ||
        runtimeVersion < headerVersion) {
      return MpvRuntimeLoadResult{
          {}, MpvRuntimeLoadError::IncompatibleVersion,
          QStringLiteral(
              "linked libmpv has an incompatible client API version")};
    }

    try {
      std::shared_ptr<const MpvRuntime> runtime(new MpvRuntime(
          api, runtimeVersion, QStringLiteral("linked-libmpv")));
      return MpvRuntimeLoadResult{std::move(runtime),
                                  MpvRuntimeLoadError::None, {}};
    } catch (...) {
      return MpvRuntimeLoadResult{
          {}, MpvRuntimeLoadError::LibraryLoadFailed,
          QStringLiteral("cannot retain the linked libmpv runtime")};
    }
  }();
  return result;
}

}  // namespace wam::playback::mpv
