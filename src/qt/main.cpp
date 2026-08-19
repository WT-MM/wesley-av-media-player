#include "mpv_video_item.hpp"
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include "native_benchmark_telemetry.hpp"
#include "platform/macos/native_layer_presentation_state.hpp"
#endif
#if defined(Q_OS_MACOS)
#include "macos_window_chrome.hpp"
#endif
#include "playback/mpv/mpv_runtime.hpp"
#include "player_controller.hpp"
#include "state_store.hpp"

#include <QByteArrayView>
#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
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
#include <QStyleHints>
#include <QSurfaceFormat>
#include <QTimer>
#include <QUrl>

#include <algorithm>
#include <array>
#include <chrono>
#include <clocale>
#include <cmath>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// Scripted seek driver (test/benchmark seam).
//
// WAM_TEST_SEEK_SCRIPT="target@when[,target@when...]" replays scrubber gestures
// without a pointer, so seek verification and the scrub benchmark campaign can
// run against a parked, non-frontmost window. "40.5@6,12@14" seeks to 40.5 s
// once playback first reaches 6 s, then to 12 s once it reaches 14 s. It is
// parsed only when WAM_NATIVE_BENCHMARK_TELEMETRY is also enabled, so a
// shipping run can never observe it, and the telemetry stream is what proves
// each scripted seek anyway.
//
// The driver drives the same public boundary the QML Scrubber does --
// beginScrub / previewSeekTo / endScrub -- rather than a bare seekTo, so both
// the preview lane and the exact commit are exercised. Targets are floored onto
// the 1/64 s dyadic grid for the same reason auto-resume is: native commit
// preflight admits only an exactly representable double.
// ---------------------------------------------------------------------------
struct ScriptedSeek {
  double target{0.0};
  double when{0.0};
};

constexpr double kSeekScriptGrid = 64.0;

double onSeekScriptGrid(double seconds) {
  if (!std::isfinite(seconds) || seconds <= 0.0)
    return 0.0;
  return std::floor(seconds * kSeekScriptGrid) / kSeekScriptGrid;
}

// ---------------------------------------------------------------------------
// Scripted playback-rate driver (test/benchmark seam).
//
// WAM_TEST_RATE_SCRIPT="entry@delayMs[,entry@delayMs...]" replays speed and
// transport gestures without a pointer, so pitch-preserved rate verification
// can run against a parked, non-frontmost window exactly the way the scrubber
// campaign does. An entry is either a speed ("1.5") or a transport letter
// ("p" to pause, "r" to resume). Delays are cumulative from process start,
// matching WAM_TEST_REOPEN_SCRIPT. Like the seek script, it is parsed only
// when WAM_NATIVE_BENCHMARK_TELEMETRY is enabled, so a shipping run can never
// observe it.
//
// It drives PlayerController::setRate / setPaused -- the same public boundary
// the QML speed control and the play button use -- rather than reaching into
// the engine, so the routing, admission and notice paths are all exercised.
// ---------------------------------------------------------------------------
struct ScriptedRate {
  double rate{0.0};
  int delayMilliseconds{0};
  bool pause{false};
  bool resume{false};
};

std::vector<ScriptedRate> parseRateScript(const QByteArray &raw) {
  std::vector<ScriptedRate> entries;
  const QString text = QString::fromUtf8(raw).trimmed();
  if (text.isEmpty())
    return entries;
  const QStringList parts = text.split(QLatin1Char(','), Qt::SkipEmptyParts);
  for (const QString &part : parts) {
    const QStringList fields = part.split(QLatin1Char('@'));
    if (fields.size() != 2)
      continue;
    const QString token = fields.at(0).trimmed();
    bool delayOk = false;
    const int delay = fields.at(1).trimmed().toInt(&delayOk);
    if (!delayOk || delay < 0)
      continue;
    ScriptedRate entry;
    entry.delayMilliseconds = delay;
    if (token.compare(QStringLiteral("p"), Qt::CaseInsensitive) == 0) {
      entry.pause = true;
    } else if (token.compare(QStringLiteral("r"), Qt::CaseInsensitive) == 0) {
      entry.resume = true;
    } else {
      bool rateOk = false;
      entry.rate = token.toDouble(&rateOk);
      if (!rateOk || !std::isfinite(entry.rate) || entry.rate <= 0.0)
        continue;
    }
    entries.push_back(entry);
  }
  return entries;
}

// Scripted warm-open driver. A cold process open pays QML, window, and GL
// startup on the main queue, so its open-to-first-draw span is dominated by
// launch work a warm open never repeats. The benchmark target is the warm
// open -- the switch to another file inside a running player -- which a fresh
// launch per measurement can never observe. Telemetry already accepts a
// second in-process open/native/draw lineage; this only supplies the driver
// for one, on the same opt-in as the scripted seek.
struct ScriptedOpen {
  QString path;
  int delayMilliseconds{0};
};

std::vector<ScriptedOpen> parseOpenScript(const QByteArray &value) {
  std::vector<ScriptedOpen> script;
  for (const QByteArray &entry : value.split(',')) {
    const QByteArray trimmed = entry.trimmed();
    if (trimmed.isEmpty())
      continue;
    const qsizetype separator = trimmed.indexOf('@');
    if (separator <= 0)
      continue;
    bool delay_ok = false;
    const int delay =
        QString::fromLatin1(trimmed.left(separator)).toInt(&delay_ok);
    const QString path =
        QString::fromUtf8(trimmed.sliced(separator + 1)).trimmed();
    if (!delay_ok || delay < 0 || path.isEmpty())
      continue;
    script.push_back({path, delay});
  }
  return script;
}

std::vector<ScriptedSeek> parseSeekScript(const QByteArray &value) {
  std::vector<ScriptedSeek> script;
  for (const QByteArray &entry : value.split(',')) {
    const QByteArray trimmed = entry.trimmed();
    if (trimmed.isEmpty())
      continue;
    const qsizetype separator = trimmed.indexOf('@');
    if (separator <= 0)
      continue;
    bool target_ok = false;
    bool when_ok = false;
    const double target =
        QString::fromLatin1(trimmed.left(separator)).toDouble(&target_ok);
    const double when =
        QString::fromLatin1(trimmed.sliced(separator + 1)).toDouble(&when_ok);
    if (!target_ok || !when_ok || !std::isfinite(target) ||
        !std::isfinite(when) || target < 0.0 || when < 0.0)
      continue;
    script.push_back({onSeekScriptGrid(target), when});
  }
  return script;
}

bool hasArgument(const QCoreApplication &app, const QString &argument) {
  const auto arguments = app.arguments();
  return std::find(arguments.cbegin(), arguments.cend(), argument) !=
         arguments.cend();
}

QUrl mediaUrlFromArgument(const QString &argument) {
  QString local_argument = argument;
  if (local_argument == QStringLiteral("~")) {
    local_argument = QDir::homePath();
  } else if (local_argument.startsWith(QStringLiteral("~/")) ||
             local_argument.startsWith(QStringLiteral("~\\"))) {
    local_argument = QDir::homePath() + local_argument.sliced(1);
  }

  // QUrl::fromUserInput treats an unqualified relative path as an HTTP host.
  // Resolve local/path-shaped arguments first, including typos, so WAM can
  // report a local-file error without making an unexpected network request.
  const QFileInfo local_candidate(local_argument);
  if (local_candidate.exists() || QDir::isAbsolutePath(local_argument))
    return QUrl::fromLocalFile(local_candidate.absoluteFilePath());

  const QUrl explicit_url(argument);
  if (!explicit_url.scheme().isEmpty())
    return QUrl::fromUserInput(argument);

  constexpr std::array<std::string_view, 31> media_extensions = {
      "3g2", "3gp",  "aac",  "ac3",  "aif",  "aiff", "alac", "amr",
      "avi", "dts",  "eac3", "flac", "flv",  "m2ts", "m4a",  "m4v",
      "mkv", "mov",  "mp3",  "mp4",  "mpeg", "mpg",  "oga",  "ogg",
      "ogv", "opus", "spx",  "ts",   "vob",  "wav",  "wmv",
  };
  const QByteArray suffix = local_candidate.suffix().toLatin1().toLower();
  const bool known_media_extension =
      std::ranges::any_of(media_extensions, [&suffix](std::string_view value) {
        return suffix == QByteArrayView(value.data(),
                                        static_cast<qsizetype>(value.size()));
      });
  const qsizetype forward_slash = local_argument.indexOf(QLatin1Char('/'));
  const qsizetype back_slash = local_argument.indexOf(QLatin1Char('\\'));
  qsizetype first_separator = -1;
  if (forward_slash >= 0 && back_slash >= 0)
    first_separator = std::min(forward_slash, back_slash);
  else
    first_separator = std::max(forward_slash, back_slash);

  const QString authority = first_separator >= 0
                                ? local_argument.first(first_separator)
                                : local_argument;
  const bool unmistakable_web_host =
      authority.startsWith(QStringLiteral("www."), Qt::CaseInsensitive) ||
      authority.compare(QStringLiteral("localhost"), Qt::CaseInsensitive) ==
          0 ||
      (first_separator >= 0 && authority.contains(QLatin1Char('.')));
  if (unmistakable_web_host)
    return QUrl::fromUserInput(QStringLiteral("http://") + local_argument);

  // A bare missing media filename must remain local. QUrl::fromUserInput can
  // otherwise mistake its extension (for example, ".mp4") for a web TLD.
  if (first_separator >= 0 || known_media_extension) {
    return QUrl::fromLocalFile(local_candidate.absoluteFilePath());
  }

  const QUrl inferred_url = QUrl::fromUserInput(argument);
  if (inferred_url.isValid())
    return inferred_url;
  return {};
}

// Finder's "Open in WAM" (and any LaunchServices open) arrives as an Apple
// Event that Qt surfaces as a QFileOpenEvent on the application object --
// there is no argv. On a cold start the event is delivered once the event
// loop first spins, which can precede the QML engine finishing its load, so
// URLs are buffered until the player is attached and drained in arrival
// order. Opens are dispatched through the event loop either way, matching
// how the argv open is staged below.
class FileOpenRelay final : public QObject {
 public:
  void attach(wam::qt::PlayerController *player) {
    player_ = player;
    for (const QUrl &url : pending_)
      dispatch(url);
    pending_.clear();
  }

 protected:
  bool eventFilter(QObject *watched, QEvent *event) override {
    if (event->type() != QEvent::FileOpen) {
      return QObject::eventFilter(watched, event);
    }
    const auto *open_event = static_cast<QFileOpenEvent *>(event);
    QUrl url = open_event->url();
    if (url.isEmpty() && !open_event->file().isEmpty())
      url = QUrl::fromLocalFile(open_event->file());
    if (url.isEmpty())
      return true;
    if (player_ != nullptr)
      dispatch(url);
    else
      pending_.append(url);
    return true;
  }

 private:
  void dispatch(const QUrl &url) {
    wam::qt::PlayerController *player = player_;
    QTimer::singleShot(0, player, [player, url] { player->open(url); });
  }

  wam::qt::PlayerController *player_ = nullptr;
  QList<QUrl> pending_;
};

QUrl initialMediaUrl(const QCoreApplication &app) {
  const QStringList arguments = app.arguments();
  for (qsizetype index = 1; index < arguments.size(); ++index) {
    const QString &argument = arguments.at(index);
    if (argument.startsWith(QLatin1Char('-')))
      continue;

    const QUrl candidate = mediaUrlFromArgument(argument);
    if (candidate.isValid())
      return candidate;
  }
  return {};
}

std::optional<double> initialPlaybackRate(const QCoreApplication &app) {
  constexpr auto prefix = "--rate=";
  const QStringList arguments = app.arguments();
  for (qsizetype index = 1; index < arguments.size(); ++index) {
    const QString &argument = arguments.at(index);
    if (!argument.startsWith(QLatin1StringView(prefix)))
      continue;
    bool valid = false;
    const double value = argument.sliced(sizeof(prefix) - 1).toDouble(&valid);
    if (valid && std::isfinite(value))
      return value;
  }
  return std::nullopt;
}

int appearanceValue(wam::AppearanceTheme theme) {
  return static_cast<int>(theme);
}

wam::AppearanceTheme appearanceTheme(int appearance) {
  switch (appearance) {
  case 1:
    return wam::AppearanceTheme::Dark;
  case 2:
    return wam::AppearanceTheme::System;
  case 0:
  default:
    return wam::AppearanceTheme::Light;
  }
}

void applyColorScheme(QStyleHints *style_hints, int appearance) {
  if (!style_hints)
    return;
  switch (appearanceTheme(appearance)) {
  case wam::AppearanceTheme::Dark:
    style_hints->setColorScheme(Qt::ColorScheme::Dark);
    break;
  case wam::AppearanceTheme::System:
    style_hints->setColorScheme(Qt::ColorScheme::Unknown);
    break;
  case wam::AppearanceTheme::Light:
  default:
    style_hints->setColorScheme(Qt::ColorScheme::Light);
    break;
  }
}

QString localStateKey(const QUrl &source) {
  if (!source.isLocalFile())
    return {};
  return QFileInfo(source.toLocalFile()).absoluteFilePath();
}

std::string persistentKey(const QString &local_path) {
  return local_path.toUtf8().toStdString();
}

struct ResumeSnapshot {
  QString local_source;
  double position = 0.0;
  double duration = 0.0;
  bool position_observed = false;
};

class ResumeTracker {
public:
  const ResumeSnapshot &snapshot() const { return snapshot_; }
  quint64 generation() const { return generation_; }

  void observePosition(double position) {
    if (std::isfinite(position) && position > 0.0) {
      snapshot_.position = position;
      snapshot_.position_observed = true;
    }
  }

  void observeDuration(double duration) {
    if (std::isfinite(duration) && duration > 0.0)
      snapshot_.duration = duration;
  }

  void commitZeroPosition(quint64 generation) {
    if (generation == generation_) {
      snapshot_.position = 0.0;
      snapshot_.position_observed = true;
    }
  }

  ResumeSnapshot transitionTo(const QString &local_source) {
    ResumeSnapshot previous = snapshot_;
    snapshot_ = ResumeSnapshot{local_source, 0.0, 0.0};
    ++generation_;
    return previous;
  }

private:
  ResumeSnapshot snapshot_;
  quint64 generation_ = 0;
};

bool verifyResumeTracker() {
  ResumeTracker tracker;

  // Merely opening a source is not evidence that playback reached zero. A
  // second open (or quit/load failure) before mpv reports time-pos must leave
  // any previously persisted resume point untouched.
  tracker.transitionTo(QStringLiteral("/media/unobserved.mp4"));
  const ResumeSnapshot unobserved_snapshot =
      tracker.transitionTo(QStringLiteral("/media/first.mp4"));
  if (unobserved_snapshot.position_observed)
    return false;

  tracker.observeDuration(120.0);
  tracker.observePosition(42.0);

  // PlayerController::open resets the old timeline before sourceChanged.
  tracker.observePosition(0.0);
  tracker.observeDuration(0.0);
  const ResumeSnapshot open_snapshot =
      tracker.transitionTo(QStringLiteral("/media/second.mp4"));
  if (open_snapshot.local_source != QStringLiteral("/media/first.mp4") ||
      open_snapshot.position != 42.0 || open_snapshot.duration != 120.0 ||
      !open_snapshot.position_observed)
    return false;

  tracker.observeDuration(90.0);
  tracker.observePosition(27.0);

  // PlayerController::stop changes source before resetting the timeline.
  const ResumeSnapshot stop_snapshot = tracker.transitionTo({});
  tracker.observePosition(0.0);
  tracker.observeDuration(0.0);
  if (stop_snapshot.local_source != QStringLiteral("/media/second.mp4") ||
      stop_snapshot.position != 27.0 || stop_snapshot.duration != 90.0 ||
      !stop_snapshot.position_observed ||
      !tracker.snapshot().local_source.isEmpty())
    return false;

  // A deliberate seek to the beginning still clears the stable position.
  tracker.transitionTo(QStringLiteral("/media/third.mp4"));
  tracker.observePosition(18.0);
  tracker.commitZeroPosition(tracker.generation());
  return tracker.snapshot().position == 0.0 &&
         tracker.snapshot().position_observed;
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
  const QUrl missing_relative =
      mediaUrlFromArgument(QStringLiteral("videos/definitely-missing.mp4"));
  const QUrl missing_filename =
      mediaUrlFromArgument(QStringLiteral("definitely-missing.mp4"));
  const QUrl explicit_remote =
      mediaUrlFromArgument(QStringLiteral("https://example.invalid/video.mp4"));
  const QUrl inferred_remote =
      mediaUrlFromArgument(QStringLiteral("www.example.invalid/video.mp4"));
  if (!missing_relative.isLocalFile() || !missing_filename.isLocalFile() ||
      explicit_remote.isLocalFile() ||
      explicit_remote.scheme() != QStringLiteral("https") ||
      inferred_remote.isLocalFile() ||
      inferred_remote.scheme() != QStringLiteral("http")) {
    return runtimeVerificationFailure(
        6, QStringLiteral("WAM runtime verification failed: media path "
                          "resolution is invalid."));
  }

  if (!verifyResumeTracker()) {
    return runtimeVerificationFailure(
        5, QStringLiteral(
               "WAM runtime verification failed: resume tracking is invalid."));
  }

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

int main(int argc, char *argv[]) {
  // libmpv's public high-performance render API is OpenGL. Keep Qt Quick on
  // the same device so video can render directly into the scene graph target,
  // without a full-frame intermediate texture or CPU readback.
  QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

  // Qt Quick sizes its texture atlas from the *screen*, not from what the
  // scene actually contains: on a 16" M3 Max that is a 4096x2048 RGBA8 atlas,
  // 32 MiB of GPU memory allocated the first time anything small is atlassed
  // and held for the window's whole lifetime. Nothing reclaims it --
  // QQuickWindow::releaseResources() only clears CPU-side caches (measured:
  // IOAccelerator unchanged at 33 MB with and without it), and the atlas is
  // freed only by scene-graph invalidation, which on the basic render loop
  // macOS+OpenGL selects happens once, at window destruction.
  //
  // WAM's entire scene-graph content is the chrome: a title string (which goes
  // to the glyph cache, not here) and a few Canvas-drawn transport icons, none
  // wider than ~60 device pixels. 512x512 is 1 MiB and still atlasses anything
  // up to 128px (Qt's limit is a quarter of the atlas width). Anything larger
  // transparently gets its own texture, so this trades batching, never
  // correctness. Measured on h264-high.mp4, layer route, window parked
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

  QGuiApplication app(argc, argv);

  // Installed before the event loop ever spins so a cold-start Finder open
  // cannot slip past; attached to the player once the engine has loaded.
  FileOpenRelay file_open_relay;
  app.installEventFilter(&file_open_relay);

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

  wam::qt::PlayerController player;
#ifndef Q_OS_MACOS
  const auto linked_runtime =
      wam::playback::mpv::MpvLinkedRuntimeFactory::create();
  if (!linked_runtime ||
      !player.provisionMpvFallbackRuntime(linked_runtime.runtime)) {
    const QString detail =
        linked_runtime.detail.isEmpty()
            ? QStringLiteral("cannot retain the linked libmpv runtime")
            : linked_runtime.detail;
    return runtimeVerificationFailure(
        3, QStringLiteral("WAM could not initialize its media engine: %1.")
               .arg(detail));
  }
#endif
  if (const auto rate = initialPlaybackRate(app))
    player.setRate(*rate);
  const int saved_appearance =
      appearanceValue(state_store.state().appearance_theme);
  player.setAppearance(saved_appearance);
  player.setVolume(
      static_cast<double>(std::clamp(state_store.state().volume, 0, 100)) /
      100.0);
  player.setSeekStepSeconds(
      static_cast<double>(std::clamp(state_store.state().seek_step_seconds,
                                     1, 60)));
  player.setWindowHugsVideo(state_store.state().window_hugs_video);
  applyColorScheme(app.styleHints(), saved_appearance);

  QTimer persistence_timer;
  persistence_timer.setInterval(static_cast<int>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          wam::StateCheckpointGate::kInterval)
          .count()));
  persistence_timer.setSingleShot(true);
  // A precise one-shot is never delivered early, preserving the ten-second
  // minimum between writes without any cost while the timer is inactive.
  persistence_timer.setTimerType(Qt::PreciseTimer);
  wam::StateCheckpointGate persistence_checkpoint;
  const auto request_checkpoint = [&] {
    if (persistence_checkpoint.request()) persistence_timer.start();
  };

  QObject::connect(
      &player, &wam::qt::PlayerController::appearanceChanged, &app, [&] {
        applyColorScheme(app.styleHints(), player.appearance());
        request_checkpoint();
      });
  QObject::connect(&player, &wam::qt::PlayerController::volumeChanged, &app,
                   request_checkpoint);
  QObject::connect(&player, &wam::qt::PlayerController::seekStepSecondsChanged,
                   &app, request_checkpoint);
  QObject::connect(&player,
                   &wam::qt::PlayerController::windowHugsVideoChanged, &app,
                   request_checkpoint);

  ResumeTracker resume_tracker;
  double resume_position = 0.0;
  bool resume_pending = false;

  const auto remember_position = [&](const ResumeSnapshot &snapshot) {
    if (snapshot.local_source.isEmpty() || !snapshot.position_observed)
      return;
    const std::string key = persistentKey(snapshot.local_source);
    if (snapshot.position < 5.0 ||
        (snapshot.duration > 0.0 &&
         snapshot.position >= snapshot.duration - 5.0)) {
      state_store.forget(key);
      return;
    }
    state_store.remember(key, snapshot.position);
  };

  const auto remember_tracked_position = [&] {
    remember_position(resume_tracker.snapshot());
  };

  const auto apply_pending_resume = [&] {
    const QString &tracked_local_source =
        resume_tracker.snapshot().local_source;
    if (!resume_pending || tracked_local_source.isEmpty() ||
        player.duration() <= 0.0)
      return;
    // Wait for the transport to actually be running. Duration and source both
    // arrive while the engine is still starting, and a seek issued into that
    // window replaces the pending start instead of following it, which left a
    // resumed open parked on its first frame. The request stays pending until
    // a start it can follow, so a paused open simply keeps its position.
    if (!player.playing() || player.position() <= 0.0)
      return;

    resume_pending = false;
    if (resume_position < 5.0 || resume_position >= player.duration() - 5.0) {
      state_store.forget(persistentKey(tracked_local_source));
      if (state_store.dirty()) request_checkpoint();
      return;
    }
    // Native seeking admits only an exactly representable target, and a
    // remembered position is a decimal that has been through text. Floor it
    // onto a binary grid, which every such value converts to exactly, so the
    // restore seek is never rejected for its last fractional digits. A 1/64 s
    // grid is finer than one video frame at any admitted rate.
    constexpr double kResumeGrid = 64.0;
    const double bounded = std::min(resume_position, player.duration());
    player.seekTo(std::max(0.0, std::floor(bounded * kResumeGrid) / kResumeGrid));
  };

  QObject::connect(
      &player, &wam::qt::PlayerController::positionChanged, &app, [&] {
        const double position = player.position();
        if (position > 0.0) {
          apply_pending_resume();
          resume_tracker.observePosition(position);
          if (!resume_tracker.snapshot().local_source.isEmpty())
            request_checkpoint();
          return;
        }

        // open() resets position and duration before sourceChanged,
        // while stop() emits sourceChanged first. Delay a zero so
        // either ordering can preserve the source being left. A
        // real seek to zero keeps its source and positive duration.
        const quint64 generation = resume_tracker.generation();
        QTimer::singleShot(0, &app, [&, generation] {
          const ResumeSnapshot &snapshot = resume_tracker.snapshot();
          if (generation != resume_tracker.generation() ||
              snapshot.local_source.isEmpty() ||
              localStateKey(player.source()) != snapshot.local_source ||
              player.position() > 0.0 || player.duration() <= 0.0)
            return;
          resume_tracker.commitZeroPosition(generation);
          request_checkpoint();
        });
      });
  QObject::connect(&player, &wam::qt::PlayerController::durationChanged, &app,
                   [&] {
                     resume_tracker.observeDuration(player.duration());
                     apply_pending_resume();
                   });
  QObject::connect(&player, &wam::qt::PlayerController::playingChanged, &app,
                   [&] { apply_pending_resume(); });
  QObject::connect(
      &player, &wam::qt::PlayerController::sourceChanged, &app, [&] {
        const ResumeSnapshot previous =
            resume_tracker.transitionTo(localStateKey(player.source()));
        remember_position(previous);
        if (state_store.dirty()) request_checkpoint();
        const QString &tracked_local_source =
            resume_tracker.snapshot().local_source;
        resume_position =
            tracked_local_source.isEmpty()
                ? 0.0
                : state_store.positionFor(persistentKey(tracked_local_source));
        // Native accurate seek now serves AAC, so the restore seek keeps the
        // native session instead of retiring it and a resumed open plays.
        constexpr bool kAutoResumeEnabled = true;
        resume_pending = kAutoResumeEnabled && resume_position >= 5.0;
        if (resume_pending)
          apply_pending_resume();
      });

  // Scripted seek driver. See ScriptedSeek above: telemetry-gated, replays the
  // public scrubber gesture so a parked window needs no pointer.
  std::vector<ScriptedSeek> seek_script;
  std::size_t seek_script_index = 0;
  int seek_script_attempts = 0;
  bool seek_script_busy = false;
  bool seek_script_awaiting = false;
  double seek_script_target = 0.0;
  QElapsedTimer seek_script_clock;
  seek_script_clock.start();
  qint64 seek_script_issued_ms = 0;
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  if (wam::qt::NativeBenchmarkTelemetry::instance().enabled()) {
    seek_script = parseSeekScript(qgetenv("WAM_TEST_SEEK_SCRIPT"));
  }
#endif
  const auto advance_seek_script = [&] {
    if (seek_script_index >= seek_script.size())
      return;
    // A commit target is admitted only while the session is prepared and has
    // no commit already in flight, so a gesture can be refused for reasons
    // that clear on their own. Confirm each scripted seek by arrival and
    // retry a bounded number of times rather than silently skipping it.
    if (seek_script_awaiting) {
      if (std::abs(player.position() - seek_script_target) <= 1.0) {
        seek_script_awaiting = false;
        seek_script_attempts = 0;
        ++seek_script_index;
      } else if (seek_script_clock.elapsed() - seek_script_issued_ms > 2500) {
        seek_script_awaiting = false;
        if (++seek_script_attempts >= 5) {
          seek_script_attempts = 0;
          ++seek_script_index;
        }
      }
      return;
    }
    if (seek_script_busy)
      return;
    const double position = player.position();
    const double duration = player.duration();
    const ScriptedSeek &next = seek_script[seek_script_index];
    if (duration <= 0.0 || !player.playing() || position < next.when)
      return;
    const double target = onSeekScriptGrid(std::min(next.target, duration));
    seek_script_busy = true;
    // One pointer gesture: press, three motion previews, release-commit. The
    // delays are the pacing a real drag has, which is what lets the preview
    // lane actually decode before the exact commit lands.
    player.beginScrub();
    player.previewSeekTo(onSeekScriptGrid(std::max(0.0, target - 0.5)));
    QTimer::singleShot(120, &app, [&, target] {
      player.previewSeekTo(onSeekScriptGrid(std::max(0.0, target - 0.25)));
    });
    QTimer::singleShot(240, &app, [&, target] {
      player.previewSeekTo(target);
    });
    QTimer::singleShot(360, &app, [&, target] {
      player.endScrub(target);
      seek_script_target = target;
      seek_script_issued_ms = seek_script_clock.elapsed();
      seek_script_awaiting = true;
      seek_script_busy = false;
    });
  };
  if (!seek_script.empty()) {
    QObject::connect(&player, &wam::qt::PlayerController::positionChanged, &app,
                     [&] { advance_seek_script(); });
  }

  const auto save_if_dirty = [&] {
    remember_tracked_position();
    state_store.state().volume = std::clamp(
        static_cast<int>(std::lround(player.volume() * 100.0)), 0, 100);
    state_store.state().appearance_theme = appearanceTheme(player.appearance());
    state_store.state().seek_step_seconds = std::clamp(
        static_cast<int>(std::lround(player.seekStepSeconds())), 1, 60);
    state_store.state().window_hugs_video = player.windowHugsVideo();
    return !state_store.dirty() || state_store.save();
  };

  QObject::connect(&persistence_timer, &QTimer::timeout, &app, [&] {
    if (persistence_checkpoint.checkpoint(save_if_dirty))
      persistence_timer.start();
  });
  QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, [&] {
    persistence_timer.stop();
    (void)persistence_checkpoint.flushNow(save_if_dirty);
  });

  int exit_code = 0;
  {
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("player"), &player);
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    // On the CALayer presentation route the video is an
    // AVSampleBufferDisplayLayer sitting *below* Qt's view, so the QML
    // background must stop painting opaque black over it. The route decision
    // is shared with the session factory (native_layer_presentation_state.hpp)
    // so the two cannot disagree.
    engine.rootContext()->setContextProperty(
        QStringLiteral("layerPresentation"),
        wam::macos::layerPresentationRouteSelected());
#else
    engine.rootContext()->setContextProperty(
        QStringLiteral("layerPresentation"), false);
#endif
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        [] { QCoreApplication::exit(2); }, Qt::QueuedConnection);
    engine.loadFromModule(QStringLiteral("Wam"), QStringLiteral("Main"));

    if (engine.rootObjects().isEmpty())
      return 2;
    if (!player.available())
      return 3;

#if defined(Q_OS_MACOS)
    // The bridge installs the transparent full-size-content titlebar on
    // construction and stays alive for the QML root window's lifetime so
    // Main.qml can drive its fade/aspect-ratio/actual-size calls afterward.
    std::unique_ptr<wam::qt::MacWindowChrome> window_chrome;
    if (auto *root_window =
            qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst())) {
      window_chrome = std::make_unique<wam::qt::MacWindowChrome>(root_window);
      engine.rootContext()->setContextProperty(
          QStringLiteral("windowChrome"), window_chrome.get());
    }
#endif

    // A malformed on-disk state is dirty so it can be rewritten canonically.
    // A missing/default state stays completely idle: no timer and no save.
    if (state_store.dirty()) request_checkpoint();

    const QUrl media = initialMediaUrl(app);
    if (!media.isEmpty()) {
      QTimer::singleShot(0, &player, [&player, media] { player.open(media); });
    }
    file_open_relay.attach(&player);

#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    // Warm-open measurement, on the scripted-seek opt-in. Each entry reopens
    // in the already-running process, so its telemetry lineage is a warm open
    // with no launch work in the span. Delays are cumulative from the initial
    // open, which keeps each reopen clear of the previous one's first draw.
    if (wam::qt::NativeBenchmarkTelemetry::instance().enabled()) {
      const std::vector<ScriptedOpen> open_script =
          parseOpenScript(qgetenv("WAM_TEST_REOPEN_SCRIPT"));
      int cumulative = 0;
      for (const ScriptedOpen &entry : open_script) {
        cumulative += entry.delayMilliseconds;
        const QString path = entry.path;
        QTimer::singleShot(cumulative, &player, [&player, path] {
          const QUrl target = mediaUrlFromArgument(path);
          if (target.isValid())
            player.open(target);
        });
      }

      const std::vector<ScriptedRate> rate_script =
          parseRateScript(qgetenv("WAM_TEST_RATE_SCRIPT"));
      int rateCumulative = 0;
      for (const ScriptedRate &entry : rate_script) {
        rateCumulative += entry.delayMilliseconds;
        const ScriptedRate scheduled = entry;
        QTimer::singleShot(rateCumulative, &player, [&player, scheduled] {
          if (scheduled.pause) {
            player.pause();
          } else if (scheduled.resume) {
            player.play();
          } else {
            player.setRate(scheduled.rate);
          }
        });
      }

      // Orderly quit for the benchmark harness. Telemetry buffers facts in
      // memory and commits them at a checkpoint or at the terminal drain, so
      // a signal-killed process loses every fact recorded after the last
      // first draw. Quitting through the event loop lets that drain run.
      bool quit_after_ok = false;
      const int quit_after =
          QString::fromLatin1(qgetenv("WAM_TEST_QUIT_AFTER_MS"))
              .toInt(&quit_after_ok);
      if (quit_after_ok && quit_after > 0) {
        QTimer::singleShot(quit_after, &app, [] { QCoreApplication::quit(); });
      }
    }
#endif

    exit_code = app.exec();
  }

#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  // The event loop and QML surface are gone, so no later production callsite
  // can append a playback fact after this terminal stream commit.
  (void)wam::qt::NativeBenchmarkTelemetry::instance().finish();
#endif
  return exit_code;
}
