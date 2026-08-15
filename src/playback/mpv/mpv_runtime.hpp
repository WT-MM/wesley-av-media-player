#pragma once

#include "playback/mpv/mpv_api.hpp"

#include <QString>

#include <memory>

class QLibrary;

namespace wam::playback::mpv {

class MpvRuntime;
class MpvRuntimeTestAccess;
class MpvLinkedRuntimeFactory;

enum class MpvRuntimeLoadError : unsigned char {
  None,
  InvalidApplicationDirectory,
  InvalidBundlePath,
  UnsafeDynamicLoaderEnvironment,
  LibraryLoadFailed,
  MissingSymbol,
  LoadedImageMismatch,
  IncompatibleVersion,
  DifferentRuntimeAlreadyLoaded,
};

struct MpvRuntimeLoadResult final {
  std::shared_ptr<const MpvRuntime> runtime;
  MpvRuntimeLoadError error{MpvRuntimeLoadError::None};
  QString detail;

  [[nodiscard]] explicit operator bool() const noexcept {
    return runtime != nullptr;
  }
};

// The macOS compatibility router's sole production entry point. Merely
// constructing WAM's controller or native player never loads libmpv; the
// router calls this only after it has selected the compatibility fallback.
class MpvFallbackFactory final {
 public:
  [[nodiscard]] static MpvRuntimeLoadResult load(
      const QString& applicationDirectory);
};

// Existing non-Apple builds link libmpv normally. This factory captures those
// linked functions in the same immutable dispatch table used by the lazy
// macOS fallback, without making dynamic-loader or bundle-security claims.
class MpvLinkedRuntimeFactory final {
 public:
  [[nodiscard]] static MpvRuntimeLoadResult create();
};

// Owns an immutable API table and, for the macOS compatibility fallback, the
// dynamically loaded library that implements it. A linked non-Apple runtime
// leaves library_ empty because its implementation is already process-owned.
class MpvRuntime final {
 public:
  ~MpvRuntime();

  MpvRuntime(const MpvRuntime&) = delete;
  MpvRuntime& operator=(const MpvRuntime&) = delete;
  MpvRuntime(MpvRuntime&&) = delete;
  MpvRuntime& operator=(MpvRuntime&&) = delete;

  [[nodiscard]] const MpvApi& api() const noexcept { return api_; }
  [[nodiscard]] unsigned long clientApiVersion() const noexcept {
    return client_api_version_;
  }
  [[nodiscard]] const QString& loadedPath() const noexcept {
    return loaded_path_;
  }

 private:
  friend class MpvFallbackFactory;
  friend class MpvLinkedRuntimeFactory;
  friend class MpvRuntimeTestAccess;

  MpvRuntime(std::unique_ptr<QLibrary> library, MpvApi api,
             unsigned long clientApiVersion, QString loadedPath);
  // Used by the linked non-Apple factory and by the uniquely named private
  // test access seam. It owns no dynamic library.
  MpvRuntime(MpvApi api, unsigned long clientApiVersion,
             QString loadedPath);

  // The factory is the sole production entry point. Failures are deliberately
  // not cached, allowing a corrected app bundle to retry in the same process.
  [[nodiscard]] static MpvRuntimeLoadResult load(
      const QString& applicationDirectory);

  // Declared first so it is destroyed last if process teardown ever reaches
  // this object. The success cache intentionally keeps the runtime alive.
  std::unique_ptr<QLibrary> library_;
  const MpvApi api_;
  const unsigned long client_api_version_;
  const QString loaded_path_;
};

}  // namespace wam::playback::mpv
