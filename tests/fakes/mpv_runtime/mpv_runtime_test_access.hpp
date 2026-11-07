#pragma once

#include "playback/mpv/mpv_runtime.hpp"

#include <QString>

#include <memory>
#include <utility>

namespace wam::playback::mpv {

// The one definition of MpvRuntime's test friend, shared by every test that
// loads the fallback runtime or injects an API table.
class MpvRuntimeTestAccess final {
 public:
  [[nodiscard]] static MpvRuntimeLoadResult load(
      const QString& applicationDirectory) {
    return MpvRuntime::load(applicationDirectory);
  }

  [[nodiscard]] static std::shared_ptr<const MpvRuntime> create(MpvApi api) {
    return std::shared_ptr<const MpvRuntime>(new MpvRuntime(
        std::move(api), MPV_CLIENT_API_VERSION,
        QStringLiteral("injected-test-mpv")));
  }
};

}  // namespace wam::playback::mpv
