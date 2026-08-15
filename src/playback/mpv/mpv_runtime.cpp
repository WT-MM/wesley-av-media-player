#include "playback/mpv/mpv_runtime.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLibrary>

#include <cerrno>
#include <climits>
#include <cstring>
#include <memory>
#include <mutex>
#include <utility>

#if !defined(__APPLE__)
#error "The WAM bundled mpv fallback runtime is macOS-only"
#endif

#include <crt_externs.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace wam::playback::mpv {
namespace {

constexpr auto kFallbackLibraryName = "WAMMpvFallback.dylib";

class UniqueFd final {
 public:
  UniqueFd() = default;
  explicit UniqueFd(int fd) noexcept : fd_(fd) {}
  ~UniqueFd() {
    if (fd_ >= 0) {
      static_cast<void>(::close(fd_));
    }
  }

  UniqueFd(const UniqueFd&) = delete;
  UniqueFd& operator=(const UniqueFd&) = delete;

  UniqueFd(UniqueFd&& other) noexcept
      : fd_(std::exchange(other.fd_, -1)) {}
  UniqueFd& operator=(UniqueFd&& other) noexcept {
    if (this == &other) {
      return *this;
    }
    if (fd_ >= 0) {
      static_cast<void>(::close(fd_));
    }
    fd_ = std::exchange(other.fd_, -1);
    return *this;
  }

  [[nodiscard]] int get() const noexcept { return fd_; }
  [[nodiscard]] explicit operator bool() const noexcept { return fd_ >= 0; }

 private:
  int fd_{-1};
};

struct RuntimeCache final {
  std::mutex mutex;
  std::shared_ptr<const MpvRuntime> runtime;
};

// Intentionally process-lifetime: successful runtimes and their QLibrary
// owners must survive every client handle and render context.
RuntimeCache& runtimeCache() {
  static RuntimeCache* const cache = new RuntimeCache;
  return *cache;
}

struct ValidatedBundlePath final {
  UniqueFd libraryDescriptor;
  QString canonicalLibrary;
  struct stat libraryIdentity {};
  MpvRuntimeLoadError error{MpvRuntimeLoadError::None};
  QString detail;

  [[nodiscard]] explicit operator bool() const noexcept {
    return error == MpvRuntimeLoadError::None;
  }
};

[[nodiscard]] QString errnoDetail(const QString& prefix) {
  return prefix + QStringLiteral(": ") +
         QString::fromLocal8Bit(std::strerror(errno));
}

[[nodiscard]] QString pathForDescriptor(int fd) {
  char path[PATH_MAX]{};
  if (::fcntl(fd, F_GETPATH, path) == -1) {
    return {};
  }
  return QDir::cleanPath(QString::fromUtf8(path));
}

[[nodiscard]] bool secureModeAndOwner(const struct stat& value,
                                      uid_t expectedOwner) noexcept {
  return value.st_uid == expectedOwner &&
         (value.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

[[nodiscard]] bool unsafeDynamicLoaderEnvironment() noexcept {
  char*** const environment_pointer = _NSGetEnviron();
  if (environment_pointer == nullptr || *environment_pointer == nullptr) {
    return false;
  }
  for (char** entry = *environment_pointer; *entry != nullptr; ++entry) {
    // macOS dyld's path overrides are all in the DYLD_* namespace.
    // LD_LIBRARY_PATH is not consulted by dyld and is commonly injected by
    // unrelated development runtimes, so it is not a loader override here.
    if (std::strncmp(*entry, "DYLD_", 5) == 0) {
      return true;
    }
  }
  return false;
}

[[nodiscard]] ValidatedBundlePath validateBundlePath(
    const QString& applicationDirectory) {
  const QFileInfo requested_application(applicationDirectory);
  if (applicationDirectory.isEmpty() ||
      !requested_application.isAbsolute()) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidApplicationDirectory,
            QStringLiteral("application directory is not a real directory")};
  }

  const QString requested_path = QDir::cleanPath(applicationDirectory);
  UniqueFd application(::open(QFile::encodeName(requested_path).constData(),
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                  O_CLOEXEC));
  if (!application) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidApplicationDirectory,
            errnoDetail(QStringLiteral("cannot open application directory"))};
  }

  struct stat application_stat {};
  if (::fstat(application.get(), &application_stat) == -1 ||
      !S_ISDIR(application_stat.st_mode) ||
      !secureModeAndOwner(application_stat, application_stat.st_uid)) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidApplicationDirectory,
            QStringLiteral("application directory is not a directory")};
  }
  const QString canonical_application = pathForDescriptor(application.get());
  if (canonical_application.isEmpty() ||
      canonical_application != requested_path) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidApplicationDirectory,
            QStringLiteral("application directory is not an exact canonical path")};
  }

  UniqueFd contents(::openat(application.get(), "..",
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (!contents) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidBundlePath,
            errnoDetail(QStringLiteral("cannot open bundle Contents directory"))};
  }
  struct stat contents_stat {};
  const QString expected_contents =
      QDir::cleanPath(QDir(canonical_application).filePath(QStringLiteral("..")));
  if (::fstat(contents.get(), &contents_stat) == -1 ||
      !S_ISDIR(contents_stat.st_mode) ||
      pathForDescriptor(contents.get()) != expected_contents ||
      !secureModeAndOwner(contents_stat, application_stat.st_uid)) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidBundlePath,
            QStringLiteral("bundle Contents directory is not exact and secure")};
  }

  UniqueFd frameworks(::openat(contents.get(), "Frameworks",
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                                   O_CLOEXEC));
  if (!frameworks) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidBundlePath,
            errnoDetail(QStringLiteral("cannot open exact Frameworks directory"))};
  }
  struct stat frameworks_stat {};
  const QString expected_frameworks = QDir::cleanPath(
      QDir(expected_contents).filePath(QStringLiteral("Frameworks")));
  if (::fstat(frameworks.get(), &frameworks_stat) == -1 ||
      !S_ISDIR(frameworks_stat.st_mode) ||
      pathForDescriptor(frameworks.get()) != expected_frameworks ||
      !secureModeAndOwner(frameworks_stat, application_stat.st_uid)) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidBundlePath,
            QStringLiteral("Frameworks directory is not exact and secure")};
  }

  UniqueFd library(::openat(frameworks.get(), kFallbackLibraryName,
                            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC));
  if (!library) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidBundlePath,
            errnoDetail(QStringLiteral("cannot open exact bundled fallback"))};
  }
  struct stat library_stat {};
  const QString expected_library = QDir(expected_frameworks)
                                       .filePath(QString::fromLatin1(
                                           kFallbackLibraryName));
  if (::fstat(library.get(), &library_stat) == -1 ||
      !S_ISREG(library_stat.st_mode) || library_stat.st_nlink != 1 ||
      pathForDescriptor(library.get()) != expected_library ||
      !secureModeAndOwner(library_stat, application_stat.st_uid)) {
    return {{}, {}, {}, MpvRuntimeLoadError::InvalidBundlePath,
            QStringLiteral("bundled fallback is not an exact secure regular file")};
  }

  return {std::move(library), expected_library, library_stat,
          MpvRuntimeLoadError::None, {}};
}

[[nodiscard]] bool sameFileIdentity(const struct stat& left,
                                    const struct stat& right) noexcept {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
         left.st_mode == right.st_mode && left.st_nlink == right.st_nlink &&
         left.st_uid == right.st_uid && left.st_gid == right.st_gid &&
         left.st_size == right.st_size &&
         left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
         left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec &&
         left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec &&
         left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

struct LoadedImageIdentity final {
  const void* base{nullptr};
};

template <typename Function>
[[nodiscard]] bool verifyResolvedSymbol(
    Function function, const struct stat& expected,
    LoadedImageIdentity& loadedImage, QString& detail,
    const char* symbol) noexcept {
  Dl_info image_info{};
  if (function == nullptr ||
      ::dladdr(reinterpret_cast<const void*>(function), &image_info) == 0 ||
      image_info.dli_fbase == nullptr || image_info.dli_fname == nullptr) {
    detail = QStringLiteral("cannot identify resolved symbol image: ") +
             QString::fromLatin1(symbol);
    return false;
  }

  if (loadedImage.base != nullptr) {
    if (loadedImage.base != image_info.dli_fbase) {
      detail = QStringLiteral("resolved symbols span multiple images: ") +
               QString::fromLatin1(symbol);
      return false;
    }
    return true;
  }

  UniqueFd loaded_descriptor(
      ::open(image_info.dli_fname,
             O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC));
  struct stat loaded_stat {};
  if (!loaded_descriptor ||
      ::fstat(loaded_descriptor.get(), &loaded_stat) == -1 ||
      !sameFileIdentity(expected, loaded_stat)) {
    detail = QStringLiteral("resolved image is not the validated fallback vnode");
    return false;
  }

  loadedImage.base = image_info.dli_fbase;
  return true;
}

[[nodiscard]] bool verifyResolvedApiImage(const MpvApi& api,
                                          const struct stat& expected,
                                          QString& detail) noexcept {
  LoadedImageIdentity loaded_image;
#define WAM_VERIFY_MPV_SYMBOL(symbol)                                      \
  if (!verifyResolvedSymbol(api.symbol, expected, loaded_image, detail,    \
                            #symbol))                                      \
    return false
  WAM_VERIFY_MPV_SYMBOL(mpv_client_api_version);
  WAM_VERIFY_MPV_SYMBOL(mpv_abort_async_command);
  WAM_VERIFY_MPV_SYMBOL(mpv_command);
  WAM_VERIFY_MPV_SYMBOL(mpv_command_async);
  WAM_VERIFY_MPV_SYMBOL(mpv_create);
  WAM_VERIFY_MPV_SYMBOL(mpv_error_string);
  WAM_VERIFY_MPV_SYMBOL(mpv_free);
  WAM_VERIFY_MPV_SYMBOL(mpv_get_property);
  WAM_VERIFY_MPV_SYMBOL(mpv_get_property_string);
  WAM_VERIFY_MPV_SYMBOL(mpv_initialize);
  WAM_VERIFY_MPV_SYMBOL(mpv_observe_property);
  WAM_VERIFY_MPV_SYMBOL(mpv_render_context_create);
  WAM_VERIFY_MPV_SYMBOL(mpv_render_context_free);
  WAM_VERIFY_MPV_SYMBOL(mpv_render_context_render);
  WAM_VERIFY_MPV_SYMBOL(mpv_render_context_set_update_callback);
  WAM_VERIFY_MPV_SYMBOL(mpv_render_context_update);
  WAM_VERIFY_MPV_SYMBOL(mpv_request_log_messages);
  WAM_VERIFY_MPV_SYMBOL(mpv_set_option_string);
  WAM_VERIFY_MPV_SYMBOL(mpv_set_property);
  WAM_VERIFY_MPV_SYMBOL(mpv_set_property_async);
  WAM_VERIFY_MPV_SYMBOL(mpv_set_property_string);
  WAM_VERIFY_MPV_SYMBOL(mpv_set_wakeup_callback);
  WAM_VERIFY_MPV_SYMBOL(mpv_terminate_destroy);
  WAM_VERIFY_MPV_SYMBOL(mpv_wait_event);
#undef WAM_VERIFY_MPV_SYMBOL
  return true;
}

template <typename Function>
[[nodiscard]] Function resolve(QLibrary& library, const char* symbol) noexcept {
  return reinterpret_cast<Function>(library.resolve(symbol));
}

[[nodiscard]] MpvApi resolveApi(QLibrary& library) noexcept {
  return {
      resolve<decltype(&::mpv_abort_async_command)>(
          library, "mpv_abort_async_command"),
      resolve<decltype(&::mpv_client_api_version)>(
          library, "mpv_client_api_version"),
      resolve<decltype(&::mpv_command)>(library, "mpv_command"),
      resolve<decltype(&::mpv_command_async)>(library, "mpv_command_async"),
      resolve<decltype(&::mpv_create)>(library, "mpv_create"),
      resolve<decltype(&::mpv_error_string)>(library, "mpv_error_string"),
      resolve<decltype(&::mpv_free)>(library, "mpv_free"),
      resolve<decltype(&::mpv_get_property)>(library, "mpv_get_property"),
      resolve<decltype(&::mpv_get_property_string)>(
          library, "mpv_get_property_string"),
      resolve<decltype(&::mpv_initialize)>(library, "mpv_initialize"),
      resolve<decltype(&::mpv_observe_property)>(
          library, "mpv_observe_property"),
      resolve<decltype(&::mpv_render_context_create)>(
          library, "mpv_render_context_create"),
      resolve<decltype(&::mpv_render_context_free)>(
          library, "mpv_render_context_free"),
      resolve<decltype(&::mpv_render_context_render)>(
          library, "mpv_render_context_render"),
      resolve<decltype(&::mpv_render_context_set_update_callback)>(
          library, "mpv_render_context_set_update_callback"),
      resolve<decltype(&::mpv_render_context_update)>(
          library, "mpv_render_context_update"),
      resolve<decltype(&::mpv_request_log_messages)>(
          library, "mpv_request_log_messages"),
      resolve<decltype(&::mpv_set_option_string)>(
          library, "mpv_set_option_string"),
      resolve<decltype(&::mpv_set_property)>(library, "mpv_set_property"),
      resolve<decltype(&::mpv_set_property_async)>(
          library, "mpv_set_property_async"),
      resolve<decltype(&::mpv_set_property_string)>(
          library, "mpv_set_property_string"),
      resolve<decltype(&::mpv_set_wakeup_callback)>(
          library, "mpv_set_wakeup_callback"),
      resolve<decltype(&::mpv_terminate_destroy)>(
          library, "mpv_terminate_destroy"),
      resolve<decltype(&::mpv_wait_event)>(library, "mpv_wait_event"),
  };
}

[[nodiscard]] const char* firstMissingSymbol(const MpvApi& api) noexcept {
#define WAM_REQUIRE_MPV_SYMBOL(symbol) \
  if (api.symbol == nullptr)           \
    return #symbol
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
  return nullptr;
}

[[nodiscard]] MpvRuntimeLoadResult unloadFailure(
    std::unique_ptr<QLibrary> library, MpvRuntimeLoadError error,
    QString detail) {
  if (library != nullptr && library->isLoaded() && !library->unload()) {
    detail += QStringLiteral("; candidate unload failed: ") +
              library->errorString();
  }
  return {{}, error, std::move(detail)};
}

}  // namespace

MpvRuntimeLoadResult MpvRuntime::load(
    const QString& applicationDirectory) {
  const ValidatedBundlePath path = validateBundlePath(applicationDirectory);
  if (!path) {
    return {{}, path.error, path.detail};
  }

  RuntimeCache& cache = runtimeCache();
  const std::lock_guard lock(cache.mutex);
  if (cache.runtime != nullptr) {
    if (cache.runtime->loadedPath() == path.canonicalLibrary) {
      return {cache.runtime, MpvRuntimeLoadError::None, {}};
    }
    return {{}, MpvRuntimeLoadError::DifferentRuntimeAlreadyLoaded,
            QStringLiteral("a fallback from a different app bundle is already loaded")};
  }

  if (unsafeDynamicLoaderEnvironment()) {
    return {{}, MpvRuntimeLoadError::UnsafeDynamicLoaderEnvironment,
            QStringLiteral("dynamic-loader environment overrides are forbidden")};
  }

  // Loading through the already-open descriptor closes the validation/load
  // rename race. No pathname is reopened by dyld, and the numeric path has a
  // slash so it cannot fall back to cwd, Homebrew, or a bare-name search.
  const QString descriptor_path =
      QStringLiteral("/dev/fd/%1").arg(path.libraryDescriptor.get());
  auto library = std::make_unique<QLibrary>(descriptor_path);
  library->setLoadHints(QLibrary::ResolveAllSymbolsHint);
  if (!library->load()) {
    const QString load_error = library->errorString();
    return unloadFailure(std::move(library),
                         MpvRuntimeLoadError::LibraryLoadFailed,
                         QStringLiteral("cannot load bundled fallback: ") +
                             load_error);
  }

  const MpvApi candidate = resolveApi(*library);
  if (const char* const missing = firstMissingSymbol(candidate);
      missing != nullptr) {
    return unloadFailure(
        std::move(library), MpvRuntimeLoadError::MissingSymbol,
        QStringLiteral("bundled fallback is missing symbol: ") +
            QString::fromLatin1(missing));
  }

  struct stat descriptor_after_load {};
  QString identity_detail;
  if (::fstat(path.libraryDescriptor.get(), &descriptor_after_load) == -1 ||
      !sameFileIdentity(path.libraryIdentity, descriptor_after_load) ||
      !verifyResolvedApiImage(candidate, path.libraryIdentity,
                              identity_detail)) {
    if (identity_detail.isEmpty()) {
      identity_detail =
          QStringLiteral("validated fallback changed while it was loaded");
    }
    return unloadFailure(std::move(library),
                         MpvRuntimeLoadError::LoadedImageMismatch,
                         std::move(identity_detail));
  }

  // This is deliberately an indirect call through the resolved table. The
  // loader itself has no link-time dependency on libmpv.
  const unsigned long runtime_version = candidate.mpv_client_api_version();
  constexpr unsigned long header_version = MPV_CLIENT_API_VERSION;
  constexpr unsigned long header_major = header_version >> 16U;
  const unsigned long runtime_major = runtime_version >> 16U;
  if (runtime_major != header_major || runtime_version < header_version) {
    return unloadFailure(
        std::move(library), MpvRuntimeLoadError::IncompatibleVersion,
        QStringLiteral("bundled fallback has an incompatible client API version"));
  }

  std::shared_ptr<const MpvRuntime> runtime(new MpvRuntime(
      std::move(library), candidate, runtime_version, path.canonicalLibrary));
  cache.runtime = runtime;
  return {std::move(runtime), MpvRuntimeLoadError::None, {}};
}

MpvRuntimeLoadResult MpvFallbackFactory::load(
    const QString& applicationDirectory) {
  return MpvRuntime::load(applicationDirectory);
}

}  // namespace wam::playback::mpv
