#include "playback/mpv/mpv_runtime.hpp"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLibrary>
#include <QProcess>
#include <QTemporaryDir>

#include <future>
#include <iostream>
#include <memory>
#include <string>
#include <type_traits>
#include <vector>

#include <unistd.h>

namespace wam::playback::mpv {

class MpvRuntimeTestAccess final {
 public:
  [[nodiscard]] static MpvRuntimeLoadResult load(
      const QString& applicationDirectory) {
    return MpvRuntime::load(applicationDirectory);
  }
};

}  // namespace wam::playback::mpv

namespace {

using wam::playback::mpv::MpvApi;
using wam::playback::mpv::MpvRuntime;
using wam::playback::mpv::MpvRuntimeLoadError;
using wam::playback::mpv::MpvRuntimeLoadResult;
using wam::playback::mpv::MpvRuntimeTestAccess;

static_assert(std::is_same_v<
              std::remove_const_t<decltype(MpvApi::mpv_create)>,
              decltype(&::mpv_create)>);
static_assert(std::is_same_v<
              std::remove_const_t<decltype(MpvApi::mpv_wait_event)>,
              decltype(&::mpv_wait_event)>);
static_assert(std::is_same_v<
              std::remove_const_t<
                  decltype(MpvApi::mpv_render_context_render)>,
              decltype(&::mpv_render_context_render)>);

int g_failures = 0;

void expect(bool condition, const std::string& message) {
  if (condition) {
    return;
  }
  std::cerr << "FAIL: " << message << '\n';
  ++g_failures;
}

struct Bundle final {
  QString applicationDirectory;
  QString frameworksDirectory;
  QString libraryPath;
};

[[nodiscard]] Bundle makeBundle(const QString& root, const QString& name) {
  const QString contents =
      QDir(root).filePath(name + QStringLiteral(".app/Contents"));
  Bundle bundle{
      QDir(contents).filePath(QStringLiteral("MacOS")),
      QDir(contents).filePath(QStringLiteral("Frameworks")),
      QDir(contents).filePath(
          QStringLiteral("Frameworks/WAMMpvFallback.dylib")),
  };
  expect(QDir().mkpath(bundle.applicationDirectory),
         "create bundle MacOS directory");
  expect(QDir().mkpath(bundle.frameworksDirectory),
         "create bundle Frameworks directory");
  bundle.applicationDirectory =
      QFileInfo(bundle.applicationDirectory).canonicalFilePath();
  bundle.frameworksDirectory =
      QFileInfo(bundle.frameworksDirectory).canonicalFilePath();
  bundle.libraryPath = QDir(bundle.frameworksDirectory)
                           .filePath(QStringLiteral("WAMMpvFallback.dylib"));
  return bundle;
}

void installLibrary(const QString& source, const QString& destination) {
  if (QFileInfo::exists(destination)) {
    expect(QFile::remove(destination), "remove prior fake fallback");
  }
  expect(QFile::copy(source, destination), "copy fake fallback into bundle");
}

void expectFailure(const MpvRuntimeLoadResult& result,
                   MpvRuntimeLoadError expected, const std::string& message) {
  expect(!result, message + " has no published runtime");
  expect(result.runtime == nullptr, message + " returns a null runtime");
  if (result.error != expected) {
    std::cerr << "  actual error=" << static_cast<int>(result.error)
              << " detail=" << result.detail.toStdString() << '\n';
  }
  expect(result.error == expected, message + " reports the exact error");
}

void testPathRejections(const QString& root, const QString& validLibrary) {
  expectFailure(MpvRuntimeTestAccess::load(
                    QDir(root).filePath(QStringLiteral("missing/MacOS"))),
                MpvRuntimeLoadError::InvalidApplicationDirectory,
                "missing application directory");

  const Bundle absent = makeBundle(root, QStringLiteral("Absent"));
  expectFailure(MpvRuntimeTestAccess::load(absent.applicationDirectory),
                MpvRuntimeLoadError::InvalidBundlePath,
                "missing fallback file");

  const Bundle directory = makeBundle(root, QStringLiteral("Directory"));
  expect(QDir().mkpath(directory.libraryPath),
         "create non-regular fallback directory");
  expectFailure(MpvRuntimeTestAccess::load(directory.applicationDirectory),
                MpvRuntimeLoadError::InvalidBundlePath,
                "non-regular fallback");

  const Bundle fileSymlink = makeBundle(root, QStringLiteral("FileSymlink"));
  const QString real_library = QDir(fileSymlink.frameworksDirectory)
                                   .filePath(QStringLiteral("Real.dylib"));
  installLibrary(validLibrary, real_library);
  expect(QFile::link(real_library, fileSymlink.libraryPath),
         "create fallback symlink");
  expectFailure(MpvRuntimeTestAccess::load(fileSymlink.applicationDirectory),
                MpvRuntimeLoadError::InvalidBundlePath,
                "symlink fallback");

  const QString linked_contents =
      QDir(root).filePath(QStringLiteral("ParentSymlink.app/Contents"));
  const QString linked_app =
      QDir(linked_contents).filePath(QStringLiteral("MacOS"));
  expect(QDir().mkpath(linked_app), "create parent-symlink MacOS directory");
  const QString canonical_linked_app =
      QFileInfo(linked_app).canonicalFilePath();
  const QString external_frameworks =
      QDir(root).filePath(QStringLiteral("ExternalFrameworks"));
  expect(QDir().mkpath(external_frameworks),
         "create external Frameworks target");
  installLibrary(validLibrary,
                 QDir(external_frameworks)
                     .filePath(QStringLiteral("WAMMpvFallback.dylib")));
  expect(QFile::link(external_frameworks,
                     QDir(linked_contents)
                         .filePath(QStringLiteral("Frameworks"))),
         "create Frameworks symlink");
  expectFailure(MpvRuntimeTestAccess::load(canonical_linked_app),
                MpvRuntimeLoadError::InvalidBundlePath,
                "symlink Frameworks parent");

  const Bundle wrongPlacement =
      makeBundle(root, QStringLiteral("WrongPlacement"));
  const QString resources = QFileInfo(wrongPlacement.frameworksDirectory)
                                .dir()
                                .filePath(QStringLiteral("Resources"));
  expect(QDir().mkpath(resources), "create Resources directory");
  installLibrary(validLibrary,
                 QDir(resources)
                     .filePath(QStringLiteral("WAMMpvFallback.dylib")));
  expectFailure(MpvRuntimeTestAccess::load(
                    wrongPlacement.applicationDirectory),
                MpvRuntimeLoadError::InvalidBundlePath,
                "fallback outside Frameworks");
}

void testVersionAndSymbolFailures(const QString& root,
                                  const QString& missingLibrary,
                                  const QString& wrongMajorLibrary,
                                  const QString& oldMinorLibrary) {
  const Bundle missing = makeBundle(root, QStringLiteral("MissingSymbol"));
  installLibrary(missingLibrary, missing.libraryPath);
  const MpvRuntimeLoadResult missing_result =
      MpvRuntimeTestAccess::load(missing.applicationDirectory);
  expectFailure(missing_result, MpvRuntimeLoadError::MissingSymbol,
                "missing-symbol library");
  expect(missing_result.detail.contains(QStringLiteral("mpv_wait_event")),
         "missing-symbol failure names the absent entry");

  const Bundle wrongMajor = makeBundle(root, QStringLiteral("WrongMajor"));
  installLibrary(wrongMajorLibrary, wrongMajor.libraryPath);
  expectFailure(MpvRuntimeTestAccess::load(wrongMajor.applicationDirectory),
                MpvRuntimeLoadError::IncompatibleVersion,
                "wrong-major library");

  const Bundle oldMinor = makeBundle(root, QStringLiteral("OldMinor"));
  installLibrary(oldMinorLibrary, oldMinor.libraryPath);
  expectFailure(MpvRuntimeTestAccess::load(oldMinor.applicationDirectory),
                MpvRuntimeLoadError::IncompatibleVersion,
                "old-minor library");
}

void testPermissionsAndLinks(const QString& root,
                             const QString& validLibrary) {
  const Bundle writableFile =
      makeBundle(root, QStringLiteral("WritableFile"));
  installLibrary(validLibrary, writableFile.libraryPath);
  expect(QFile::setPermissions(
             writableFile.libraryPath,
             QFile::permissions(writableFile.libraryPath) |
                 QFileDevice::WriteGroup),
         "make fake fallback group-writable");
  expectFailure(MpvRuntimeTestAccess::load(writableFile.applicationDirectory),
                MpvRuntimeLoadError::InvalidBundlePath,
                "group-writable fallback");

  const Bundle writableParent =
      makeBundle(root, QStringLiteral("WritableParent"));
  installLibrary(validLibrary, writableParent.libraryPath);
  expect(QFile::setPermissions(
             writableParent.frameworksDirectory,
             QFile::permissions(writableParent.frameworksDirectory) |
                 QFileDevice::WriteGroup),
         "make Frameworks directory group-writable");
  expectFailure(MpvRuntimeTestAccess::load(
                    writableParent.applicationDirectory),
                MpvRuntimeLoadError::InvalidBundlePath,
                "group-writable Frameworks directory");

  const Bundle hardLinked = makeBundle(root, QStringLiteral("HardLinked"));
  const QString outside =
      QDir(root).filePath(QStringLiteral("hard-link-source.dylib"));
  installLibrary(validLibrary, outside);
  expect(::link(QFile::encodeName(outside).constData(),
                QFile::encodeName(hardLinked.libraryPath).constData()) == 0,
         "create hard-linked fallback");
  expectFailure(MpvRuntimeTestAccess::load(hardLinked.applicationDirectory),
                MpvRuntimeLoadError::InvalidBundlePath,
                "multiply-linked fallback");
}

int runPreloadedCollisionChild(const QString& collisionLibrary,
                               const QString& validLibrary) {
  QTemporaryDir temporary;
  expect(temporary.isValid(), "create collision child bundle root");
  if (!temporary.isValid()) {
    return 1;
  }

  QLibrary collision(collisionLibrary);
  collision.setLoadHints(QLibrary::ResolveAllSymbolsHint);
  expect(collision.load(), "preload same-install-name collision dylib");

  const Bundle bundle =
      makeBundle(temporary.path(), QStringLiteral("Collision"));
  installLibrary(validLibrary, bundle.libraryPath);
  const MpvRuntimeLoadResult result =
      MpvRuntimeTestAccess::load(bundle.applicationDirectory);
  if (result) {
    expect(std::string(result.runtime->api().mpv_error_string(0)) ==
               "fake mpv error",
           "a successful collision probe resolves the exact bundled image");
  } else {
    if (result.error != MpvRuntimeLoadError::LoadedImageMismatch) {
      std::cerr << "  collision actual error="
                << static_cast<int>(result.error)
                << " detail=" << result.detail.toStdString() << '\n';
    }
    expect(result.error == MpvRuntimeLoadError::LoadedImageMismatch,
           "a dyld install-name collision fails as an image mismatch");
  }
  return g_failures == 0 ? 0 : 1;
}

void testPreloadedCollision(const QString& collisionLibrary,
                            const QString& validLibrary) {
  QProcess child;
  child.setProgram(QCoreApplication::applicationFilePath());
  child.setArguments({QStringLiteral("--collision"), collisionLibrary,
                      validLibrary});
  child.start();
  expect(child.waitForStarted(5000), "start preloaded-collision child");
  if (child.state() == QProcess::NotRunning) {
    return;
  }
  if (!child.waitForFinished(10000)) {
    child.kill();
    static_cast<void>(child.waitForFinished(5000));
    expect(false, "preloaded-collision child completes within ten seconds");
    return;
  }
  if (child.exitStatus() != QProcess::NormalExit || child.exitCode() != 0) {
    std::cerr << child.readAllStandardError().constData();
    expect(false, "preloaded-collision identity probe passes");
  }
}

void testRetryCacheAndLifetime(const QString& root,
                               const QString& missingLibrary,
                               const QString& validLibrary) {
  const Bundle retry = makeBundle(root, QStringLiteral("Retry"));
  installLibrary(missingLibrary, retry.libraryPath);
  expectFailure(MpvRuntimeTestAccess::load(retry.applicationDirectory),
                MpvRuntimeLoadError::MissingSymbol,
                "first retryable load");

  const QByteArray prior_dyld_path = qgetenv("DYLD_LIBRARY_PATH");
  const bool had_dyld_path = qEnvironmentVariableIsSet("DYLD_LIBRARY_PATH");
  expect(qputenv("DYLD_LIBRARY_PATH", root.toUtf8()),
         "set hostile dynamic-loader environment for rejection test");
  expectFailure(MpvRuntimeTestAccess::load(retry.applicationDirectory),
                MpvRuntimeLoadError::UnsafeDynamicLoaderEnvironment,
                "dynamic-loader environment override");
  if (had_dyld_path) {
    expect(qputenv("DYLD_LIBRARY_PATH", prior_dyld_path),
           "restore prior dynamic-loader environment");
  } else {
    qunsetenv("DYLD_LIBRARY_PATH");
  }

  installLibrary(validLibrary, retry.libraryPath);
  std::vector<std::future<MpvRuntimeLoadResult>> futures;
  for (int index = 0; index < 4; ++index) {
    futures.emplace_back(std::async(
        std::launch::async, [directory = retry.applicationDirectory] {
          return MpvRuntimeTestAccess::load(directory);
        }));
  }
  std::vector<MpvRuntimeLoadResult> concurrent_results;
  for (auto& future : futures) {
    concurrent_results.push_back(future.get());
  }
  MpvRuntimeLoadResult loaded = concurrent_results.front();
  expect(static_cast<bool>(loaded),
         "corrected bundle succeeds after an uncached failure");
  if (!loaded) {
    return;
  }

  expect(loaded.error == MpvRuntimeLoadError::None,
         "successful load has no error");
  expect(loaded.runtime->api().complete(),
         "successful runtime publishes all 24 symbols");
  expect((loaded.runtime->clientApiVersion() >> 16U) ==
             (MPV_CLIENT_API_VERSION >> 16U),
         "successful runtime has the exact header API major");
  expect(loaded.runtime->clientApiVersion() >= MPV_CLIENT_API_VERSION,
         "successful runtime is at least the header API version");
  expect(loaded.runtime->loadedPath() ==
             QFileInfo(retry.libraryPath).canonicalFilePath(),
         "runtime records the exact canonical bundled path");

  const MpvRuntime* const identity = loaded.runtime.get();
  for (const MpvRuntimeLoadResult& concurrent : concurrent_results) {
    expect(static_cast<bool>(concurrent),
           "every concurrent load returns a runtime");
    expect(concurrent.runtime.get() == identity,
           "concurrent loads publish one immutable runtime");
  }
  std::weak_ptr<const MpvRuntime> weak = loaded.runtime;
  loaded.runtime.reset();
  expect(!weak.expired(), "success cache retains the library owner");

  const MpvRuntimeLoadResult cached =
      MpvRuntimeTestAccess::load(retry.applicationDirectory);
  expect(static_cast<bool>(cached), "same bundle returns cached runtime");
  expect(cached.runtime.get() == identity,
         "success cache returns the same immutable runtime");

  const Bundle other = makeBundle(root, QStringLiteral("OtherSuccess"));
  installLibrary(validLibrary, other.libraryPath);
  expectFailure(MpvRuntimeTestAccess::load(other.applicationDirectory),
                MpvRuntimeLoadError::DifferentRuntimeAlreadyLoaded,
                "second app bundle after publication");
}

}  // namespace

int main(int argc, char** argv) {
  QCoreApplication application(argc, argv);
  if (argc == 4 && QString::fromLocal8Bit(argv[1]) ==
                       QStringLiteral("--collision")) {
    return runPreloadedCollisionChild(QString::fromLocal8Bit(argv[2]),
                                      QString::fromLocal8Bit(argv[3]));
  }
  if (argc != 6) {
    std::cerr << "usage: mpv_runtime_test VALID MISSING WRONG_MAJOR OLD_MINOR "
                 "COLLISION\n";
    return 2;
  }

  const QString valid = QFileInfo(QString::fromLocal8Bit(argv[1]))
                            .canonicalFilePath();
  const QString missing = QFileInfo(QString::fromLocal8Bit(argv[2]))
                              .canonicalFilePath();
  const QString wrong_major = QFileInfo(QString::fromLocal8Bit(argv[3]))
                                  .canonicalFilePath();
  const QString old_minor = QFileInfo(QString::fromLocal8Bit(argv[4]))
                                .canonicalFilePath();
  const QString collision = QFileInfo(QString::fromLocal8Bit(argv[5]))
                                .canonicalFilePath();
  expect(!valid.isEmpty() && !missing.isEmpty() && !wrong_major.isEmpty() &&
             !old_minor.isEmpty() && !collision.isEmpty(),
         "all fake libraries exist");

  QTemporaryDir temporary;
  expect(temporary.isValid(), "create isolated bundle root");
  if (g_failures == 0) {
    testPathRejections(temporary.path(), valid);
    testVersionAndSymbolFailures(temporary.path(), missing, wrong_major,
                                 old_minor);
    testPermissionsAndLinks(temporary.path(), valid);
    testPreloadedCollision(collision, valid);
    testRetryCacheAndLifetime(temporary.path(), missing, valid);
  }

  if (g_failures != 0) {
    std::cerr << g_failures << " mpv runtime test(s) failed\n";
    return 1;
  }
  std::cout << "mpv runtime tests passed\n";
  return 0;
}
