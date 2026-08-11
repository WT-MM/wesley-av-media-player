#include "mpv_video_item.hpp"
#include "player_controller.hpp"
#include "state_store.hpp"

#include <QByteArrayView>
#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
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

#include <mpv/client.h>

#include <algorithm>
#include <array>
#include <clocale>
#include <cmath>
#include <memory>
#include <optional>
#include <string>

namespace {

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
    qCritical() << "WAM runtime verification failed: media path resolution "
                   "is invalid.";
    return 6;
  }

  if (!verifyResumeTracker()) {
    qCritical()
        << "WAM runtime verification failed: resume tracking is invalid.";
    return 5;
  }

  const uint64_t linked_api = mpv_client_api_version();
  const uint64_t compiled_api = MPV_CLIENT_API_VERSION;
  if (linked_api == 0 || (linked_api >> 16) != (compiled_api >> 16)) {
    qCritical().nospace()
        << "WAM runtime verification failed: incompatible libmpv client API "
        << (linked_api >> 16) << '.' << (linked_api & 0xffff) << ".";
    return 3;
  }

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
    qCritical().noquote()
        << "WAM runtime verification failed: Qt Quick is unavailable:"
        << component.errorString();
    return 2;
  }

  qInfo().nospace() << "WAM runtime verification passed (libmpv client API "
                    << (linked_api >> 16) << '.' << (linked_api & 0xffff)
                    << ").";
  return 0;
}

} // namespace

int main(int argc, char *argv[]) {
  // libmpv's public high-performance render API is OpenGL. Keep Qt Quick on
  // the same device so video can render directly into the scene graph target,
  // without a full-frame intermediate texture or CPU readback.
  QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

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
  if (const auto rate = initialPlaybackRate(app))
    player.setRate(*rate);
  const int saved_appearance =
      appearanceValue(state_store.state().appearance_theme);
  player.setAppearance(saved_appearance);
  player.setVolume(
      static_cast<double>(std::clamp(state_store.state().volume, 0, 100)) /
      100.0);
  applyColorScheme(app.styleHints(), saved_appearance);

  QObject::connect(&player, &wam::qt::PlayerController::appearanceChanged, &app,
                   [&app, &player] {
                     applyColorScheme(app.styleHints(), player.appearance());
                   });

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

    resume_pending = false;
    if (resume_position < 5.0 || resume_position >= player.duration() - 5.0) {
      state_store.forget(persistentKey(tracked_local_source));
      return;
    }
    player.seekTo(std::min(resume_position, player.duration()));
  };

  QTimer resume_timer;
  resume_timer.setInterval(250);
  resume_timer.setSingleShot(false);
  QObject::connect(&resume_timer, &QTimer::timeout, &app, [&] {
    apply_pending_resume();
    if (!resume_pending)
      resume_timer.stop();
  });

  QObject::connect(
      &player, &wam::qt::PlayerController::positionChanged, &app, [&] {
        const double position = player.position();
        if (position > 0.0) {
          resume_tracker.observePosition(position);
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
        });
      });
  QObject::connect(&player, &wam::qt::PlayerController::durationChanged, &app,
                   [&] {
                     resume_tracker.observeDuration(player.duration());
                     apply_pending_resume();
                   });
  QObject::connect(
      &player, &wam::qt::PlayerController::sourceChanged, &app, [&] {
        const ResumeSnapshot previous =
            resume_tracker.transitionTo(localStateKey(player.source()));
        remember_position(previous);
        const QString &tracked_local_source =
            resume_tracker.snapshot().local_source;
        resume_position =
            tracked_local_source.isEmpty()
                ? 0.0
                : state_store.positionFor(persistentKey(tracked_local_source));
        resume_pending = resume_position >= 5.0;
        if (resume_pending)
          resume_timer.start();
        else
          resume_timer.stop();
      });

  const auto persist_state = [&] {
    remember_tracked_position();
    state_store.state().volume = std::clamp(
        static_cast<int>(std::lround(player.volume() * 100.0)), 0, 100);
    state_store.state().appearance_theme = appearanceTheme(player.appearance());
    (void)state_store.save();
  };

  QTimer persistence_timer;
  persistence_timer.setInterval(10'000);
  QObject::connect(&persistence_timer, &QTimer::timeout, &app, persist_state);
  QObject::connect(&app, &QCoreApplication::aboutToQuit, &app, persist_state);

  QQmlApplicationEngine engine;
  engine.rootContext()->setContextProperty(QStringLiteral("player"), &player);
  QObject::connect(
      &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
      [] { QCoreApplication::exit(2); }, Qt::QueuedConnection);
  engine.loadFromModule(QStringLiteral("Wam"), QStringLiteral("Main"));

  if (engine.rootObjects().isEmpty())
    return 2;
  if (!player.available())
    return 3;

  persistence_timer.start();

  const QUrl media = initialMediaUrl(app);
  if (!media.isEmpty()) {
    QTimer::singleShot(0, &player, [&player, media] { player.open(media); });
  }

  return app.exec();
}
