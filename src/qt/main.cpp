#include "media/media_container_routing.hpp"
#include "media/native_playback_contract.hpp"
#include "media/startup_benchmark.hpp"
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
#include "media/libavformat_cursor.hpp"
#endif
#if defined(WAM_ENABLE_AVCODEC_STAGE)
#include "media/avcodec/runtime.hpp"
#endif
#include "media_url.hpp"
#include "mpv_video_item.hpp"
#include "subtitle_bitmap_provider.hpp"
#include "test_seams.hpp"
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include "native_benchmark_telemetry.hpp"
#include "platform/macos/native_embedding_support.hpp"
#endif
#if defined(Q_OS_MACOS)
#include "macos_window_chrome.hpp"
#include "termination_signal.hpp"
#include "macos_video_service_cleanup.hpp"
#endif
#include "playback/mpv/mpv_runtime.hpp"
#include "player_controller.hpp"
#include "state_store.hpp"
#include "window_manager.hpp"

#include <QByteArrayView>
#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QFileOpenEvent>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSurfaceFormat>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>
#include <QStringList>

#include <algorithm>
#include <clocale>
#include <cmath>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {

bool hasArgument(const QCoreApplication &app, const QString &argument) {
  const auto arguments = app.arguments();
  return std::find(arguments.cbegin(), arguments.cend(), argument) !=
         arguments.cend();
}

// Finder's "Open in WAM" (and any LaunchServices open) arrives as an Apple
// Event that Qt surfaces as a QFileOpenEvent on the application object --
// there is no argv. On a cold start the event is delivered once the event
// loop first spins, which can precede the QML engine finishing its load, so
// URLs are buffered until the player is attached and drained in arrival
// order before the first window exposure. Subsequent opens remain queued to
// avoid reentering window creation from a live Apple Event callback.
class FileOpenRelay final : public QObject {
 public:
  void attach(wam::qt::WindowManager *windows) {
    windows_ = windows;
    for (const QUrl &url : pending_)
      windows_->openUrl(url);
    pending_.clear();
  }

 protected:
  bool eventFilter(QObject *watched, QEvent *event) override {
    if (event->type() != QEvent::FileOpen) {
      return QObject::eventFilter(watched, event);
    }
    WAM_STARTUP_STAMP(FileOpenReceived);
    const auto *open_event = static_cast<QFileOpenEvent *>(event);
    QUrl url = open_event->url();
    if (url.isEmpty() && !open_event->file().isEmpty())
      url = QUrl::fromLocalFile(open_event->file());
    if (url.isEmpty())
      return true;
    if (windows_ != nullptr)
      dispatch(url);
    else
      pending_.append(url);
    return true;
  }

 private:
  void dispatch(const QUrl &url) {
    // Every Finder / LaunchServices open goes through the manager, which is
    // what decides between claiming an empty window and creating a new one.
    // Selecting three files in Finder therefore delivers three events and
    // produces three windows, exactly as QuickTime does.
    wam::qt::WindowManager *windows = windows_;
    QTimer::singleShot(0, windows, [windows, url] { windows->openUrl(url); });
  }

  wam::qt::WindowManager *windows_ = nullptr;
  QList<QUrl> pending_;
};

// Every media argument on the command line, in order. WAM opens a window per
// file the way `open -a WAM a.mp4 b.mp4` and Finder's multi-select do.
QList<QUrl> initialMediaUrls(const QCoreApplication &app) {
  QList<QUrl> media;
  const QStringList arguments = app.arguments();
  for (qsizetype index = 1; index < arguments.size(); ++index) {
    const QString &argument = arguments.at(index);
    if (argument.startsWith(QLatin1Char('-')))
      continue;

    const QUrl candidate = wam::qt::mediaUrlFromArgument(argument);
    if (candidate.isValid())
      media.append(candidate);
  }
  return media;
}

std::optional<double> initialPlaybackRate(const QCoreApplication &app) {
  constexpr QLatin1StringView prefix("--rate=");
  const QStringList arguments = app.arguments();
  for (qsizetype index = 1; index < arguments.size(); ++index) {
    const QString &argument = arguments.at(index);
    if (!argument.startsWith(prefix))
      continue;
    bool valid = false;
    const double value = argument.sliced(prefix.size()).toDouble(&valid);
    if (valid && std::isfinite(value))
      return value;
  }
  return std::nullopt;
}

int runtimeVerificationFailure(int exit_code, const QString &message) {
  qCritical().noquote() << message;
#ifdef Q_OS_WIN
  // WAM is a GUI-subsystem executable, so Qt's normal logger is not visible in
  // a Windows packaging shell. Write the same diagnostic to the inherited
  // stderr handle so CI reports the exact missing module or plugin.
  const QByteArray utf8 = message.toUtf8();
  std::fwrite(utf8.constData(), 1, static_cast<std::size_t>(utf8.size()),
              stderr);
  std::fputc('\n', stderr);
  std::fflush(stderr);
#endif
  return exit_code;
}

int verifyRuntime() {
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
  const auto demuxFailure = wam::media::LibavformatCursor::runtimeFailure();
  if (!demuxFailure.empty()) return runtimeVerificationFailure(7, QString::fromStdString(demuxFailure));
  qInfo().noquote() << "native_demux_stages version=1"
                    << QString::fromStdString(
                           wam::media::LibavformatCursor::runtimeDescription());
#endif
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  if (const char* failure = wam::media::avcodec::runtimeFailure())
    return runtimeVerificationFailure(7, QString::fromLatin1(failure));
  qInfo().noquote() << "native_codec_stages version=2 present=true"
                    << wam::media::avcodec::runtimeVersions()
                    << "loading=lazy lease_retirement=unload "
                       "license=LGPL-2.1-or-later required_decoders=present "
                       "audio_routing=disabled";
  qInfo().noquote() << "native_hardware_capabilities av1=" << wam::macos::NativeEmbeddingSupport::supportsAv1()
                   << "vp9=" << wam::macos::NativeEmbeddingSupport::supportsVp9();
#endif
#ifndef Q_OS_MACOS
  const auto linked_runtime =
      wam::playback::mpv::MpvLinkedRuntimeFactory::create();
  if (!linked_runtime) {
    return runtimeVerificationFailure(
        3, QStringLiteral("WAM runtime verification failed: %1.")
               .arg(linked_runtime.detail));
  }
#endif

  // Keep this check headless and side-effect free. Full PlayerController/mpv
  // initialization is exercised by the GUI smoke test; Homebrew's macOS mpv
  // build creates AppKit Touch Bar objects during mpv_initialize(), which is
  // invalid under Qt's offscreen platform plugin.
  QQmlEngine qml_engine;
  QQmlComponent component(&qml_engine);
  // Import and instantiate the same controls stack as the real shell. A plain
  // QtQuick Item does not load QtQuick.Controls' dynamic QML plugin, so it
  // cannot detect a rewritten-but-unsigned plugin in a packaged app.
  component.setData(
      QByteArrayLiteral("import QtQuick\n"
                        "import QtQuick.Controls\n"
                        "import QtQuick.Dialogs\n"
                        "ApplicationWindow { visible: false; Button {} }"),
      QUrl(QStringLiteral("qrc:/wam-runtime-check.qml")));
  std::unique_ptr<QObject> instance(component.create());
  if (!instance) {
    return runtimeVerificationFailure(
        2, QStringLiteral(
               "WAM runtime verification failed: Qt Quick is unavailable: %1")
               .arg(component.errorString()));
  }

  qInfo() << "WAM runtime verification passed.";
  return 0;
}

} // namespace

static int runApplication(int argc, char *argv[]) {
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK) && defined(WAM_NATIVE_BENCHMARK_TELEMETRY)
  (void)wam::qt::NativeBenchmarkTelemetry::instance();
#endif
  WAM_STARTUP_STAMP(MainEntered);
  // libmpv's public high-performance render API is OpenGL. Keep Qt Quick on
  // the same device so video can render directly into the scene graph target,
  // without a full-frame intermediate texture or CPU readback.
  QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

  // Qt Quick sizes its texture atlas from the *screen*, not from what the
  // scene actually contains: on a 16" M3 Max that is a 4096x2048 RGBA8 atlas,
  // 32 MiB of GPU memory allocated the first time anything small is atlassed
  // and held for the window's whole lifetime. Nothing reclaims it --
  // QQuickWindow::releaseResources() only clears CPU-side caches (IOAccelerator
  // is unchanged at 33 MB with and without it), and the atlas is
  // freed only by scene-graph invalidation, which on the basic render loop
  // macOS+OpenGL selects happens once, at window destruction.
  //
  // WAM's entire scene-graph content is the chrome: a title string (which goes
  // to the glyph cache, not here) and a few Canvas-drawn transport icons, none
  // wider than ~60 device pixels. 512x512 is 1 MiB and still atlasses anything
  // up to 128px (Qt's limit is a quarter of the atlas width). Anything larger
  // transparently gets its own texture, so this trades batching, never
  // correctness. With an H.264 clip on the layer route, window parked
  // 640x360: IOAccelerator (graphics) 33 MB -> 2.1 MB, process footprint
  // 117 MB -> 61 MB.
  //
  // Set only if the environment has not already spoken, so the knob stays
  // available for debugging without a rebuild.
  if (!qEnvironmentVariableIsSet("QSG_ATLAS_WIDTH"))
    qputenv("QSG_ATLAS_WIDTH", "512");
  if (!qEnvironmentVariableIsSet("QSG_ATLAS_HEIGHT"))
    qputenv("QSG_ATLAS_HEIGHT", "512");

  QSurfaceFormat format;
  format.setRenderableType(QSurfaceFormat::OpenGL);
  format.setProfile(QSurfaceFormat::CoreProfile);
  format.setVersion(3, 2);
  format.setDepthBufferSize(0);
  format.setStencilBufferSize(0);
  format.setAlphaBufferSize(8);
  format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
  format.setSwapInterval(1);
  QSurfaceFormat::setDefaultFormat(format);

  if (!wam::qt::loadTestSeams())
    return 2;
  wam::qt::armTestSeamsBeforeApplication();

  QGuiApplication app(argc, argv);
  WAM_STARTUP_STAMP(GuiApplicationConstructed);
#if defined(Q_OS_MACOS)
  wam::qt::TerminationSignal terminationSignal;
#endif

  wam::qt::armTestSeamsAfterApplication();

  // Installed before the event loop ever spins so a cold-start Finder open
  // cannot slip past; attached to the player once the engine has loaded.
  FileOpenRelay file_open_relay;
  app.installEventFilter(&file_open_relay);
  // Let LaunchServices deliver its initial QFileOpenEvent while the relay is
  // buffering, before QML/GL startup can hold the Cocoa event loop busy.
  QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);

  // QGuiApplication adopts the user's locale. libmpv explicitly requires the
  // numeric category to remain POSIX so option/property numbers always use a
  // decimal point, regardless of the UI language.
  if (!std::setlocale(LC_NUMERIC, "C")) {
    qCritical()
        << "WAM could not select the C numeric locale required by libmpv.";
    return 4;
  }

  QCoreApplication::setOrganizationName(QStringLiteral("Wesley Maa"));
  QCoreApplication::setOrganizationDomain(QStringLiteral("wesleymaa.com"));
  QCoreApplication::setApplicationName(QStringLiteral("WAM"));
  QCoreApplication::setApplicationVersion(QStringLiteral(WAM_VERSION));
  const bool verify_runtime =
      hasArgument(app, QStringLiteral("--verify-runtime"));

  // Custom QML owns visible control styling; Basic supplies stable control
  // behavior while native windows, dialogs, text, and accessibility remain.
  QQuickStyle::setStyle(QStringLiteral("Basic"));

  if (verify_runtime)
    return verifyRuntime();

  wam::qt::registerWamQtTypes();
  wam::StateStore state_store;
  (void)state_store.load();
  WAM_STARTUP_STAMP(StateStoreLoaded);

  // A player window is a document window: closing the last one leaves the app
  // running with its menu bar, the way every document-based macOS app behaves,
  // and Cmd-O / a Finder open / a Dock click then makes a fresh one. Qt's
  // default is the opposite -- quitOnLastWindowClosed is true -- so without
  // this line closing one video would silently terminate the process. Quit
  // stays on Cmd-Q, the app menu, and the orderly-quit seam
  // (WAM_TEST_QUIT_AFTER_MS); all three call QCoreApplication::quit() and are
  // unaffected by this.
#if defined(__APPLE__)
  app.setQuitOnLastWindowClosed(false);
#endif

  int exit_code = 0;
  {
    QQmlApplicationEngine engine;
    // The bitmap subtitle overlay's image path. One engine serves every
    // window, so the provider is registered once here and resolves each
    // window's caption by the key its URL carries.
    wam::qt::registerSubtitleBitmapProvider(engine);
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    // On the CALayer presentation route the video is an
    // AVSampleBufferDisplayLayer sitting *below* Qt's view, so the QML
    // background must stop painting opaque black over it. The route decision
    // is process-wide and shared with the session factory
    // (native_layer_presentation_state.hpp) so the two cannot disagree; it is
    // therefore an app-level context property, inherited by every window's
    // own child context.
    engine.rootContext()->setContextProperty(
        QStringLiteral("layerPresentation"),
        wam::macos::NativeEmbeddingSupport::layerRouteSelected());
#else
    engine.rootContext()->setContextProperty(
        QStringLiteral("layerPresentation"), false);
#endif
    // Whether the title band may offer its reveal-in-Finder caret: a platform
    // fact, so app-level like the route above. Set before anything is created,
    // rather than read off a per-window bridge in QML, because that bridge
    // only exists after the window does and a `typeof` test is not a
    // dependency any binding would be re-run for.
#if defined(Q_OS_MACOS)
    engine.rootContext()->setContextProperty(
        QStringLiteral("revealInFinderSupported"), true);
#else
    engine.rootContext()->setContextProperty(
        QStringLiteral("revealInFinderSupported"), false);
#endif
    // The open dialog's filter, from the one extension table.
    {
      QStringList patterns;
      for (const wam::media::MediaFileExtensionRow &row :
           wam::media::kMediaFileExtensions)
        patterns << QLatin1String("*") +
                        QLatin1String(row.extension.data(),
                                      qsizetype(row.extension.size()));
      engine.rootContext()->setContextProperty(
          QStringLiteral("mediaFileNameFilter"),
          QStringLiteral("Media files (%1)").arg(patterns.join(QLatin1Char(' '))));
    }

    // The rate window and grid every rate control snaps to (qml/RateSlider.qml).
    engine.rootContext()->setContextProperty(
        QStringLiteral("playbackRates"),
        QVariantMap{{QStringLiteral("minimum"), wam::media::native_playback::kMinimumNativeRate},
                    {QStringLiteral("maximum"), wam::media::native_playback::kMaximumNativeRate},
                    {QStringLiteral("grid"), wam::media::native_playback::kNativeRateGrid}});

    // The window factory. Everything app-level -- the state store and its
    // persistence checkpoint, the single desktop menu bar, the single
    // Preferences window, focus routing, and the settings mirror that makes
    // one Preferences change apply live to every window -- lives here; the
    // controller, chrome bridge, resume tracker and native playback session
    // are per window.
    wam::qt::WindowManager windows(engine, state_store);
    engine.rootContext()->setContextProperty(QStringLiteral("appHost"),
                                             &windows);

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        [] { QCoreApplication::exit(2); }, Qt::QueuedConnection);

    // The menu bar is installed before any window exists and outlives every
    // one of them, which is what lets the app keep its menus with zero windows
    // open.
    if (!windows.createMenuBar())
      return 2;

#if defined(Q_OS_MACOS)
    // Clicking the Dock icon with no windows open must present a window --
    // AppKit's applicationShouldHandleReopen: contract, and the behaviour a
    // macOS user expects from an app that stays alive without windows.
    wam::macos_window_chrome::installApplicationReopenHandler([&windows] {
      if (windows.windowCount() == 0)
        static_cast<void>(windows.createWindow());
    });
    // macOS hiding the app for ANY reason -- Cmd-H, Hide Others, the Dock
    // menu -- pauses every window, so the system gesture and WAM's own "h"
    // macro are indistinguishable. Pausing an already-paused player is a
    // no-op, so the two paths cannot double-pause.
    wam::macos_window_chrome::installApplicationHideObserver(
        [&windows] { windows.pauseAll(); });
#endif

    // A malformed on-disk state is dirty so it can be rewritten canonically.
    // A missing/default state stays completely idle: no timer and no save.
    if (state_store.dirty())
      windows.requestCheckpoint();

    // The menu bar's Quit item calls Qt.quit(), which emits QQmlEngine::quit
    // -- a signal with NO default receiver on this construction, so unwired
    // Cmd-Q does nothing ("emitted, but no receivers connected"). Wire it, and
    // its exit() sibling, explicitly. Queued, so the
    // quit unwinds from the event loop rather than from inside the menu
    // item's activation.
    QObject::connect(&engine, &QQmlEngine::quit, &app,
                     &QCoreApplication::quit, Qt::QueuedConnection);
    QObject::connect(
        &engine, &QQmlEngine::exit, &app,
        [](int code) { QCoreApplication::exit(code); }, Qt::QueuedConnection);

    QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, [&windows] {
      // Cmd-Q with N playing windows must retire N native sessions, not
      // abandon them at process exit: aboutToQuit is the last moment the event
      // loop is alive, so owner teardown runs here synchronously. Native
      // graphs retire off-thread and are drained after these owners are gone.
      windows.closeAllWindows();
      windows.flushPersistence();
    });

    wam::qt::PlayerWindow *first = windows.createWindow();
    if (first == nullptr)
      return 2;
    if (!first->controller()->available())
      return 3;
    wam::qt::startTestSeams(app, windows, *first, &wam::qt::mediaUrlFromArgument);

    if (const auto rate = initialPlaybackRate(app))
      first->controller()->setRate(*rate);

    const QList<QUrl> media = initialMediaUrls(app);
    // Queue the asynchronous preflight before entering the event loop, so it
    // can finish while Cocoa exposes the first window and Qt prepares GL.
    for (const QUrl &url : media)
      static_cast<void>(windows.openUrl(url));
    file_open_relay.attach(&windows);

    exit_code = app.exec();
  }

#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  wam::macos::NativeEmbeddingSupport::drainRetirementsForProcessExit();
  // The event loop and QML surface are gone, so no later production callsite
  // can append a playback fact after this terminal stream commit.
  (void)wam::qt::NativeBenchmarkTelemetry::instance().finish();
#endif
  return exit_code;
}

int main(int argc, char *argv[]) {
  const int result = runApplication(argc, argv);
#if defined(Q_OS_MACOS)
  wam::qt::finishMacosVideoServices();
#endif
  return result;
}
