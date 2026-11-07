#include "playback/mpv/mpv_runtime.hpp"

#include <memory>
#include <utility>

namespace wam::playback::mpv {
namespace {

[[nodiscard]] MpvApi linkedApi() noexcept {
#define WAM_LINKED_MPV_SYMBOL(name) &::name,
  return {WAM_MPV_API(WAM_LINKED_MPV_SYMBOL)};
#undef WAM_LINKED_MPV_SYMBOL
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
