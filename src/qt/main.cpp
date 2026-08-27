#include "mpv_video_item.hpp"
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
#include "native_benchmark_telemetry.hpp"
#include "platform/macos/native_audio_test_mute.hpp"
#include "platform/macos/native_layer_presentation_state.hpp"
#endif
#if defined(Q_OS_MACOS)
#include "macos_window_chrome.hpp"
#endif
#include "playback/mpv/mpv_runtime.hpp"
#include "player_controller.hpp"
#include "state_store.hpp"
#include "window_manager.hpp"

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
#include <QImage>
#include <QQuickWindow>
#include <QRect>
#include <QPointF>
#include <QWheelEvent>
#include <QRegularExpression>
#include <QSGRendererInterface>
#include <QStyleHints>
#include <QSurfaceFormat>
#include <QTimer>
#include <QUrl>
#include <QStringList>
#include <QQmlListReference>
#include <QVariant>
#include <QVariantMap>

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

// Live state of the scripted seek driver. A struct rather than eight separate
// locals so the driver lambda can name it once; it lives for the whole run.
struct ScriptedSeekState {
  std::size_t index = 0;
  int attempts = 0;
  bool busy = false;
  bool awaiting = false;
  double target = 0.0;
  QElapsedTimer clock;
  qint64 issued_ms = 0;
};

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

// ---------------------------------------------------------------------------
// Scripted window driver (test seam).
//
// WAM_TEST_WINDOW_SCRIPT="verb@delayMs[,verb@delayMs...]" drives the
// multi-window lifecycle -- create, open, close, focus, transport, hide,
// report -- from inside the process, on cumulative delays from launch, exactly
// the way WAM_TEST_REOPEN_SCRIPT drives warm opens.
//
// It exists because the alternative is worse. Verifying "close window A
// mid-playback and prove B is unaffected", "close the last window and prove
// the app survives", or "a settings change reaches every window" from outside
// the process means System Events and an accessibility grant, which steals
// focus, defeats WAM_TEST_BACKGROUND, and resets HIDIdleTime -- all three of
// which corrupt the very measurements running alongside. Driving the public
// WindowManager boundary instead exercises the same code paths the menu bar
// and the traffic lights do.
//
// Verbs (index is a position in creation order):
//   new                 create an empty window
//   open:<path>         WindowManager::openUrl -- empty-claim or new window
//   load:<index>:<path> load into THAT window, the drag-and-drop gesture
//   close:<index>       QQuickWindow::close() on that window, i.e. the real
//                       user close path, including its playback teardown
//   focus:<index>       raise and focus
//   pause:<index>       play:<index>       rate:<index>:<value>
//   seekstep:<value>    set it on window 0, to observe the settings mirror
//   volume:<index>:<v>  set that window's normalized volume (0..maximum)
//   maxvolume:<v>       set the maximum-volume setting on window 0 (1..4),
//                       to observe it mirror onto every other window
//   padded:<index>      toggle that window's "Fill Screen (Padded)" mode --
//                       the View menu item's own QML entry point
//   vivid:<index>       toggle that window's Vivid EDR boost -- the same QML
//                       entry point the chrome toggle, the View menu item and
//                       the V key all call. A no-op for an HDR source, which
//                       is a real answer and not a failure: see `vboost` in
//                       the report line for what the display layer actually
//                       took
//   theater:<index>     toggle that window's Theater dim, likewise
//   mute:<index>        the transport's mute button (toggle + volume OSD)
//   fullscreen:<index>  toggle that window's fullscreen, the F key's own path
//   grab:<index>:<path> write that window's QML SCENE to a PNG (the video
//                       itself is not in it on the layer route -- see the
//                       implementation), so an overlay can be proved without
//                       a screen capture the machine's live user can spoil
//   gestures:<0|1>      set scrollGesturesEnabled on window 0 (mirrored)
//   scroll:<index>:<dx>:<dy>:<count>[:<phase>[:<inverted>[:<fx>:<fy>]]]
//                       deliver <count> synthetic QWheelEvents to that
//                       window. dx/dy are PIXEL deltas (angleDelta is derived
//                       as 2x, exactly as Qt's cocoa plugin does for a
//                       trackpad); pass dx=dy=0 with a non-zero notch count
//                       through the `wheel` verb instead for a real wheel.
//                       phase 0..4 = Qt::ScrollPhase. fx/fy are fractions of
//                       the window rect and default to (0.5, 0.35), i.e. over
//                       the picture and clear of the transport bar.
//   wheel:<index>:<nx>:<ny>:<count>[:<inverted>[:<fx>:<fy>]]
//                       the same, as a REAL wheel: null pixelDelta and
//                       angleDelta of nx/ny * 120 per event, no phase.
//   hide                pause every window and hide the app
//   prefs               show the single Preferences window
//   subs:<index>:<id>   select that window's subtitle source by id, or -1 for
//                       Off -- the same call the Subtitles menu makes
//   subsload:<index>:<path>
//                       load a subtitle file into that window, the
//                       Subtitles > Load Subtitle File gesture without the
//                       native open panel (which would steal focus and defeat
//                       WAM_TEST_BACKGROUND, exactly as the header explains
//                       for the window verbs)
//   substoggle:<index>  the transport captions button
//   captions:<index>:<path>
//                       generate captions for that window into <path>, the
//                       Quick Edit gesture without its Save panel
//   menu                write one WAM_TEST_MENU line per top-level menu,
//                       with each item's title and check mark, read off the
//                       real Qt.labs.platform menu bar
//   report              write one WAM_TEST_WINDOWS line plus one
//                       WAM_TEST_WINDOW line and one WAM_TEST_SUBTITLES line
//                       per window to stderr
//
// Telemetry-gated like every other WAM_TEST_* seam, so a shipping launch can
// never observe it.
// ---------------------------------------------------------------------------
// Defined below, next to the argv parsing it also serves.
QUrl mediaUrlFromArgument(const QString &argument);

struct ScriptedWindowStep {
  QString verb;
  int delayMilliseconds{0};
};

std::vector<ScriptedWindowStep> parseWindowScript(const QByteArray &value) {
  std::vector<ScriptedWindowStep> script;
  for (const QByteArray &entry : value.split(',')) {
    const QByteArray trimmed = entry.trimmed();
    if (trimmed.isEmpty())
      continue;
    const qsizetype separator = trimmed.lastIndexOf('@');
    if (separator <= 0)
      continue;
    bool delay_ok = false;
    const int delay =
        QString::fromLatin1(trimmed.sliced(separator + 1)).toInt(&delay_ok);
    const QString verb =
        QString::fromUtf8(trimmed.left(separator)).trimmed();
    if (!delay_ok || delay < 0 || verb.isEmpty())
      continue;
    script.push_back({verb, delay});
  }
  return script;
}

// Chrome state read straight off the QML root, so a verification round can
// prove "the scroll gesture revealed the volume UI" rather than infer it.
int chromeRevealed(const wam::qt::PlayerWindow *window) {
  const QObject *root = window != nullptr ? window->qmlRoot() : nullptr;
  if (root == nullptr)
    return -1;
  const QVariant value = root->property("controlsRevealed");
  return value.isValid() ? (value.toBool() ? 1 : 0) : -1;
}

// The QML root's own per-window "Fill Screen (Padded)" flag, and whether the
// volume OSD card is currently up. Both are read off the root rather than
// inferred, for the same reason chromeRevealed is: a verification round has to
// be able to state what the window IS in, not what it was asked to do.
int rootFlag(const wam::qt::PlayerWindow *window, const char *name) {
  const QObject *root = window != nullptr ? window->qmlRoot() : nullptr;
  if (root == nullptr)
    return -1;
  const QVariant value = root->property(name);
  return value.isValid() ? (value.toBool() ? 1 : 0) : -1;
}

int volumeOsdShown(const wam::qt::PlayerWindow *window) {
  const QObject *root = window != nullptr ? window->qmlRoot() : nullptr;
  if (root == nullptr)
    return -1;
  QObject *osd = root->findChild<QObject *>(QStringLiteral("volumeOsd"));
  if (osd == nullptr)
    return -1;
  const QVariant value = osd->property("shown");
  return value.isValid() ? (value.toBool() ? 1 : 0) : -1;
}

int volumeFeedbackActive(const wam::qt::PlayerWindow *window) {
  const QObject *root = window != nullptr ? window->qmlRoot() : nullptr;
  if (root == nullptr)
    return -1;
  QObject *transport = root->findChild<QObject *>(QStringLiteral("transport"));
  if (transport == nullptr)
    return -1;
  const QVariant value = transport->property("volumeFeedback");
  return value.isValid() ? (value.toBool() ? 1 : 0) : -1;
}

// The video size window geometry is actually working from, read off the QML
// root rather than recomputed, so a scripted round can prove the number
// reached the aspect lock. It is reported next to the frame because the two
// answer different questions and a run needs both: the frame is what the
// window did, and this is what it was told. That separation matters most under
// the benchmark telemetry every WAM_TEST_* seam is gated behind, which
// suppresses the aspect snap outright (MacWindowChrome::benchmarkMode_) -- the
// frame there proves nothing about geometry, while this still proves the
// container was measured.
QString videoNaturalSizeSummary(const wam::qt::PlayerWindow *window) {
  const QObject *root = window != nullptr ? window->qmlRoot() : nullptr;
  if (root == nullptr)
    return QStringLiteral("?");
  const QVariant value = root->property("videoNaturalSize");
  if (!value.isValid())
    return QStringLiteral("?");
  const QSizeF size = value.toSizeF();
  return QStringLiteral("%1x%2")
      .arg(size.width(), 0, 'f', 0)
      .arg(size.height(), 0, 'f', 0);
}

// Walks the live Qt.labs.platform MenuBar and prints what the user would see.
//
// Qt.labs.platform exposes `menus` and `items` only as QQmlListProperty -- no
// count/at invokables and nothing a QVariant can convert -- so the walk goes
// through QQmlListReference, which is the supported way to read one from C++.
void reportMenus(const wam::qt::WindowManager &windows) {
  QObject *bar = windows.menuBarObject();
  if (bar == nullptr) {
    qInfo().noquote() << QStringLiteral("WAM_TEST_MENU none");
    return;
  }
  const QQmlListReference menus(bar, "menus");
  if (!menus.isValid()) {
    qInfo().noquote() << QStringLiteral("WAM_TEST_MENU unreadable");
    return;
  }
  for (qsizetype menuIndex = 0; menuIndex < menus.count(); ++menuIndex) {
    QObject *menu = menus.at(menuIndex);
    if (menu == nullptr)
      continue;
    QStringList items;
    const QQmlListReference entries(menu, "items");
    for (qsizetype itemIndex = 0; entries.isValid() && itemIndex < entries.count();
         ++itemIndex) {
      QObject *item = entries.at(itemIndex);
      if (item == nullptr)
        continue;
      const QVariant text = item->property("text");
      if (!text.isValid())
        continue;
      if (!item->property("visible").toBool())
        continue;
      QString label = text.toString();
      if (label.isEmpty())
        label = QStringLiteral("-");
      if (item->property("checkable").toBool()) {
        label = (item->property("checked").toBool() ? QStringLiteral("[x] ")
                                                    : QStringLiteral("[ ] ")) +
                label;
      }
      if (!item->property("enabled").toBool())
        label += QStringLiteral(" (disabled)");
      items.append(label);
    }
    qInfo().noquote() << QStringLiteral("WAM_TEST_MENU title=%1 items=[%2]")
                             .arg(menu->property("title").toString(),
                                  items.join(QStringLiteral(" | ")));
  }
}

void reportWindows(const wam::qt::WindowManager &windows) {
  const QList<wam::qt::PlayerWindow *> &open = windows.windows();
  qInfo().noquote() << QStringLiteral("WAM_TEST_WINDOWS count=%1")
                           .arg(open.size());
  for (qsizetype index = 0; index < open.size(); ++index) {
    const wam::qt::PlayerController *player = open.at(index)->controller();
    if (player == nullptr)
      continue;
    const QQuickWindow *quick = open.at(index)->window();
    const QRect frame = quick != nullptr ? quick->geometry() : QRect();
    qInfo().noquote()
        << QStringLiteral(
               "WAM_TEST_WINDOW idx=%1 media=%2 paused=%3 playing=%4 rate=%5 "
               "step=%6 hugs=%7 pitch=%8 geom=%10x%11+%12+%13 "
               "volume=%14 muted=%15 gestures=%16 pos=%17 dur=%18 "
               "chrome=%19 vfeedback=%20 vnat=%21 vmax=%22 padded=%23 "
               "fullscreen=%24 osd=%25 tlalpha=%26 nsfs=%27 "
               "vivid=%28 vboost=%29 hdr=%30 edr=%31 theater=%32 dims=%33 "
               "source=%9")
               .arg(index)
               .arg(player->hasMedia() ? 1 : 0)
               .arg(player->paused() ? 1 : 0)
               .arg(player->playing() ? 1 : 0)
               .arg(player->rate())
               .arg(player->seekStepSeconds())
               .arg(player->windowHugsVideo() ? 1 : 0)
               .arg(player->preservePitch() ? 1 : 0)
               .arg(QFileInfo(player->source().toLocalFile()).fileName())
               .arg(frame.width())
               .arg(frame.height())
               .arg(frame.x())
               .arg(frame.y())
               .arg(player->volume(), 0, 'f', 4)
               .arg(player->muted() ? 1 : 0)
               .arg(player->scrollGesturesEnabled() ? 1 : 0)
               .arg(player->position(), 0, 'f', 4)
               .arg(player->duration(), 0, 'f', 4)
               .arg(chromeRevealed(open.at(index)))
               .arg(volumeFeedbackActive(open.at(index)))
               .arg(videoNaturalSizeSummary(open.at(index)))
               .arg(player->maximumVolume(), 0, 'f', 4)
               .arg(rootFlag(open.at(index), "fillScreenPadded"))
               .arg(quick != nullptr
                        ? (quick->visibility() == QWindow::FullScreen ? 1 : 0)
                        : -1)
               .arg(volumeOsdShown(open.at(index)))
               .arg(quick != nullptr
                        ? wam::macos_window_chrome::titlebarControlsAlpha(
                              const_cast<QQuickWindow *>(quick))
                        : -1.0,
                    0, 'f', 3)
               .arg(quick != nullptr
                        ? (wam::macos_window_chrome::nativeFullScreen(
                               const_cast<QQuickWindow *>(quick))
                               ? 1
                               : 0)
                        : -1)
               // vivid/theater are what QML believes; vboost and dims are what
               // AppKit and CoreAnimation actually hold. Both are reported
               // because a disagreement between them is exactly the defect
               // shape a verification round has to be able to see: vboost
               // reads the display layer's own attached filter (0 = no display
               // layer at all, i.e. the libmpv route), dims counts the overlay
               // windows genuinely on screen.
               .arg(rootFlag(open.at(index), "vividActive"))
               .arg(quick != nullptr
                        ? wam::macos_window_chrome::appliedVividBoost(
                              const_cast<QQuickWindow *>(quick))
                        : -1.0,
                    0, 'f', 3)
               .arg(rootFlag(open.at(index), "sourceIsHdr"))
               .arg(quick != nullptr
                        ? wam::macos_window_chrome::screenEdrHeadroom(
                              const_cast<QQuickWindow *>(quick))
                        : -1.0,
                    0, 'f', 3)
               .arg(rootFlag(open.at(index), "theaterDimEnabled"))
               .arg(wam::macos_window_chrome::theaterDimOverlayCount());

    // Subtitles get their own line rather than more fields on the one above:
    // the track labels are free text and would break any parser that splits
    // the WINDOW line on spaces. `text` is the line actually on screen, read
    // from the controller property the overlay binds, so a scripted round can
    // prove a cue is showing without a screenshot.
    QStringList track_summary;
    const QVariantList tracks = player->subtitleTracks();
    track_summary.reserve(tracks.size());
    for (const QVariant &entry : tracks) {
      const QVariantMap track = entry.toMap();
      track_summary.append(
          QStringLiteral("%1:%2:%3")
              .arg(track.value(QStringLiteral("id")).toInt())
              .arg(track.value(QStringLiteral("origin")).toString(),
                   track.value(QStringLiteral("label")).toString()));
    }
    QString line = player->subtitleText();
    line.replace(QLatin1Char('\n'), QStringLiteral("\\n"));
    qInfo().noquote()
        << QStringLiteral(
               "WAM_TEST_SUBTITLES idx=%1 active=%2 visible=%3 count=%4 "
               "text=[%5] tracks=[%6]")
               .arg(index)
               .arg(player->activeSubtitleTrack())
               .arg(player->captionsVisible() ? 1 : 0)
               .arg(tracks.size())
               .arg(line, track_summary.join(QLatin1Char('|')));
  }
}

// Delivers one synthetic wheel event to a window, through the ordinary Qt
// delivery path -- so the QML wheel blockers on the transport, the volume
// flyout and the Quick Edit panel are exercised exactly as a real trackpad
// would exercise them.
//
// The AppKit -> Qt half of the translation (which NSEvent field becomes
// pixelDelta, how `inverted` is set) is deliberately NOT re-implemented here:
// it is Qt's, it is fixed, and it is quoted from Qt's own source in
// src/qt/scroll_gesture.hpp. What this seam reproduces is the SHAPE Qt
// delivers -- a trackpad's angleDelta being exactly twice its pixelDelta, a
// real wheel's null pixelDelta and 120-unit notches -- so everything
// downstream of QWheelEvent is under test.
void deliverWheel(QQuickWindow *window, QPointF fraction, QPoint pixelDelta,
                  QPoint angleDelta, bool inverted, Qt::ScrollPhase phase,
                  int count) {
  if (window == nullptr || count <= 0)
    return;
  const QPointF local(window->width() * fraction.x(),
                      window->height() * fraction.y());
  const QPointF global = window->position() + local;
  for (int emitted = 0; emitted < count; ++emitted) {
    // A real gesture carries ScrollBegin exactly once and ScrollUpdate for
    // the rest; repeating Begin would restart the gesture on every event and
    // would never exercise the axis lock or the detent's charge.
    const Qt::ScrollPhase step =
        (phase == Qt::ScrollBegin && emitted > 0) ? Qt::ScrollUpdate : phase;
    QWheelEvent event(local, global, pixelDelta, angleDelta, Qt::NoButton,
                      Qt::NoModifier, step, inverted,
                      Qt::MouseEventSynthesizedByApplication);
    QCoreApplication::sendEvent(window, &event);
  }
}

void runWindowStep(wam::qt::WindowManager &windows, const QString &verb) {
  const QStringList fields = verb.split(QLatin1Char(':'));
  const QString head = fields.value(0);
  const auto windowAt = [&windows](int index) -> wam::qt::PlayerWindow * {
    const QList<wam::qt::PlayerWindow *> &open = windows.windows();
    if (index < 0 || index >= open.size())
      return nullptr;
    return open.at(index);
  };
  const int index = fields.size() > 1 ? fields.at(1).toInt() : 0;

  if (head == QStringLiteral("new")) {
    static_cast<void>(windows.createWindow());
  } else if (head == QStringLiteral("open")) {
    // Rejoin on ':' so a Windows-style or scheme-bearing path survives.
    const QString path = fields.mid(1).join(QLatin1Char(':'));
    const QUrl target = mediaUrlFromArgument(path);
    if (target.isValid())
      static_cast<void>(windows.openUrl(target));
  } else if (head == QStringLiteral("load")) {
    // The drag-and-drop gesture: qml/Main.qml's DropArea calls exactly this
    // on exactly this window's controller, so a warm replacement lands in the
    // window that was dropped on and nowhere else.
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      const QUrl target = mediaUrlFromArgument(fields.mid(2).join(QLatin1Char(':')));
      if (target.isValid())
        static_cast<void>(window->controller()->open(target));
    }
  } else if (head == QStringLiteral("close")) {
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      if (QQuickWindow *quick = window->window())
        quick->close();
    }
  } else if (head == QStringLiteral("focus")) {
    if (wam::qt::PlayerWindow *window = windowAt(index))
      window->raiseWindow();
  } else if (head == QStringLiteral("pause")) {
    if (wam::qt::PlayerWindow *window = windowAt(index))
      window->controller()->pause();
  } else if (head == QStringLiteral("play")) {
    if (wam::qt::PlayerWindow *window = windowAt(index))
      window->controller()->play();
  } else if (head == QStringLiteral("rate")) {
    if (wam::qt::PlayerWindow *window = windowAt(index))
      window->controller()->setRate(fields.value(2).toDouble());
  } else if (head == QStringLiteral("seekstep")) {
    if (wam::qt::PlayerWindow *window = windowAt(0))
      window->controller()->setSeekStepSeconds(fields.value(1).toDouble());
  } else if (head == QStringLiteral("volume")) {
    if (wam::qt::PlayerWindow *window = windowAt(index))
      window->controller()->setVolume(fields.value(2).toDouble());
  } else if (head == QStringLiteral("grab")) {
    // Grab that window's QML scene to a PNG.
    //
    // A screen capture cannot be trusted on a machine somebody is using: the
    // window is real and on screen (WAM_TEST_BACKGROUND orders it front
    // without activating), but anything the live user raises -- Mission
    // Control, a full-screen app -- lands in the frame instead. This reads the
    // scene out of the window itself, so what is proved is what WAM drew.
    //
    // It captures the QML SCENE only. On the layer-presentation route the
    // picture is an AVSampleBufferDisplayLayer composited by WindowServer
    // BELOW Qt's view, so the video is not in this image -- which is exactly
    // right for proving a QML overlay (the volume OSD, the transport, the
    // titlebar band) and useless for proving the picture.
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      if (QQuickWindow *quick = window->window()) {
        const QImage image = quick->grabWindow();
        const QString path = fields.mid(2).join(QLatin1Char(':'));
        qInfo().noquote()
            << QStringLiteral("WAM_TEST_GRAB idx=%1 size=%2x%3 saved=%4 path=%5")
                   .arg(index)
                   .arg(image.width())
                   .arg(image.height())
                   .arg(!image.isNull() && image.save(path) ? 1 : 0)
                   .arg(path);
      }
    }
  } else if (head == QStringLiteral("maxvolume")) {
    // Set on window 0 only, exactly like `seekstep` and `gestures`: it is an
    // app-level setting and the point of driving it from one window is to
    // observe the mirror land on the others.
    if (wam::qt::PlayerWindow *window = windowAt(0))
      window->controller()->setMaximumVolume(fields.value(1).toDouble());
  } else if (head == QStringLiteral("mute")) {
    // The transport's mute button, minus the button: the same
    // toggleMute() + volume-OSD pair the QML control fires.
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      window->controller()->toggleMute();
      if (QObject *root = window->qmlRoot())
        QMetaObject::invokeMethod(root, "showVolumeOsd");
    }
  } else if (head == QStringLiteral("fullscreen")) {
    // The F key / View menu gesture, driven at the controller signal both of
    // them raise, so the scripted round goes through the same QML handler.
    if (wam::qt::PlayerWindow *window = windowAt(index))
      window->controller()->toggleFullscreen();
  } else if (head == QStringLiteral("padded")) {
    // The View menu's "Fill Screen (Padded)" toggle, driven at the QML root
    // the menu item itself calls -- so the scripted round exercises the real
    // path and not a re-implementation of it.
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      if (QObject *root = window->qmlRoot())
        QMetaObject::invokeMethod(root, "toggleFillScreenPadded");
    }
  } else if (head == QStringLiteral("vivid")) {
    // The Vivid boost toggle, driven at the QML root the chrome button and the
    // View menu item both call -- so a scripted round exercises the real path
    // rather than a re-implementation of it. Same for `theater` below.
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      if (QObject *root = window->qmlRoot())
        QMetaObject::invokeMethod(root, "toggleVividBoost");
    }
  } else if (head == QStringLiteral("theater")) {
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      if (QObject *root = window->qmlRoot())
        QMetaObject::invokeMethod(root, "toggleTheaterDim");
    }
  } else if (head == QStringLiteral("gestures")) {
    if (wam::qt::PlayerWindow *window = windowAt(0))
      window->controller()->setScrollGesturesEnabled(fields.value(1).toInt() !=
                                                     0);
  } else if (head == QStringLiteral("scroll") ||
             head == QStringLiteral("wheel")) {
    wam::qt::PlayerWindow *window = windowAt(index);
    if (window != nullptr) {
      const bool trackpad = head == QStringLiteral("scroll");
      const int dx = fields.value(2).toInt();
      const int dy = fields.value(3).toInt();
      const int count = std::max(1, fields.value(4).toInt());
      const int phaseField = trackpad ? fields.value(5).toInt() : 0;
      const bool inverted =
          (trackpad ? fields.value(6) : fields.value(5)).toInt() != 0;
      const QString fxField = trackpad ? fields.value(7) : fields.value(6);
      const QString fyField = trackpad ? fields.value(8) : fields.value(7);
      bool fx_ok = false;
      bool fy_ok = false;
      const double fx = fxField.toDouble(&fx_ok);
      const double fy = fyField.toDouble(&fy_ok);
      const QPointF fraction(fx_ok ? fx : 0.5, fy_ok ? fy : 0.35);
      const Qt::ScrollPhase phase =
          phaseField >= 0 && phaseField <= 4
              ? static_cast<Qt::ScrollPhase>(phaseField)
              : Qt::NoScrollPhase;
      const QPoint pixels = trackpad ? QPoint(dx, dy) : QPoint(0, 0);
      const QPoint angles =
          trackpad ? QPoint(dx * 2, dy * 2) : QPoint(dx * 120, dy * 120);
      deliverWheel(window->window(), fraction, pixels, angles, inverted, phase,
                   count);
    }
  } else if (head == QStringLiteral("subs")) {
    if (wam::qt::PlayerWindow *window = windowAt(index))
      window->controller()->selectSubtitleTrack(fields.value(2).toInt());
  } else if (head == QStringLiteral("subsload")) {
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      const QUrl target = mediaUrlFromArgument(fields.mid(2).join(QLatin1Char(':')));
      if (target.isValid())
        static_cast<void>(window->controller()->loadSubtitleFile(target));
    }
  } else if (head == QStringLiteral("captions")) {
    if (wam::qt::PlayerWindow *window = windowAt(index)) {
      const QString path = fields.mid(2).join(QLatin1Char(':'));
      if (!path.isEmpty())
        window->controller()->generateCaptionsTo(QUrl::fromLocalFile(path));
    }
  } else if (head == QStringLiteral("substoggle")) {
    if (wam::qt::PlayerWindow *window = windowAt(index))
      window->controller()->toggleCaptions();
  } else if (head == QStringLiteral("hide")) {
    windows.hideAndPauseAll();
  } else if (head == QStringLiteral("prefs")) {
    windows.showPreferences();
  } else if (head == QStringLiteral("menu")) {
    reportMenus(windows);
  } else if (head == QStringLiteral("report")) {
    reportWindows(windows);
  }
}

// ---------------------------------------------------------------------------
// Quiet launch seams (test/benchmark).
//
// WAM_TEST_BACKGROUND=1 launches without ever becoming the frontmost
// application, and WAM_TEST_MUTED=1 launches with silent hardware output.
// Automated GUI verification runs on the developer's own machine: without
// these, every correctness round steals the keyboard mid-sentence and plays
// the clip's audio out loud. Both are gated on the same
// WAM_NATIVE_BENCHMARK_TELEMETRY opt-in every other WAM_TEST_* seam is, so a
// shipping launch can never observe either.
//
// Neither seam may change what a measurement sees. WAM_TEST_BACKGROUND leaves
// the window ON SCREEN and COMPOSITED (accessory activation policy, not a
// hidden or off-screen window) because an occluded window counterfeits
// starvation and would make every drawn-frame fact a lie. WAM_TEST_MUTED zeros
// only the samples copied into the AudioUnit buffer, after the render core has
// run, so callback cadence, counters, the audio-authoritative clock and every
// wake edge are bit-for-bit an unmuted run's.
//
// Vocabulary matches the telemetry opt-in itself rather than inventing a
// second one, so "1"/"true"/"yes"/"on" (and their upper-case forms) all read
// as enabled and anything else -- including junk -- reads as off.
// ---------------------------------------------------------------------------
// WAM_TEST_GEOMETRY="WxH+X+Y" parks the window at an exact logical rectangle.
//
// It exists so a verification round needs no pointer, no System Events, and no
// accessibility grant to get the window out of the way: with
// WAM_TEST_BACKGROUND the window is deliberately floated above ordinary
// windows so it cannot be occluded, and a full-size floating window is an
// unacceptable thing to leave on the user's screen. A small parked rectangle
// keeps the compositing proof and stops the window from being in the way.
//
// Telemetry-gated like every other WAM_TEST_* seam. The benchmark harness
// already suppresses the QuickTime aspect snap under the same opt-in (see
// MacWindowChrome::benchmarkMode), so a parked rectangle stays put.
struct ScriptedGeometry {
  int x{0};
  int y{0};
  int width{0};
  int height{0};
};

std::optional<ScriptedGeometry> parseGeometry(const QByteArray &value) {
  const QString text = QString::fromLatin1(value).trimmed();
  static const QRegularExpression pattern(
      QStringLiteral("^(\\d+)x(\\d+)\\+(-?\\d+)\\+(-?\\d+)$"));
  const QRegularExpressionMatch match = pattern.match(text);
  if (!match.hasMatch())
    return std::nullopt;
  ScriptedGeometry geometry;
  geometry.width = match.captured(1).toInt();
  geometry.height = match.captured(2).toInt();
  geometry.x = match.captured(3).toInt();
  geometry.y = match.captured(4).toInt();
  if (geometry.width < 64 || geometry.height < 64)
    return std::nullopt;
  return geometry;
}

bool testSeamEnabled(const char *name) {
  const QByteArray value = qgetenv(name);
  static constexpr std::array<QByteArrayView, 7> kTruths{
      QByteArrayView("1"),   QByteArrayView("true"), QByteArrayView("TRUE"),
      QByteArrayView("yes"), QByteArrayView("YES"),  QByteArrayView("on"),
      QByteArrayView("ON")};
  return std::any_of(kTruths.begin(), kTruths.end(),
                     [&value](QByteArrayView truth) {
                       return QByteArrayView(value) == truth;
                     });
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

  // Sorted, and kept a superset of every extension the open dialog offers.
  // "webm" being absent from this list meant `wam clip.webm` for a file that
  // does not exist under the working directory fell through to the web-host
  // heuristic below and was opened as a URL rather than reported as a missing
  // local file.
  constexpr std::array<std::string_view, 43> media_extensions = {
      "3g2",  "3gp",  "3gpp", "aac",  "ac3",  "aif",  "aiff", "alac",
      "amr",  "asf",  "avi",  "caf",  "dts",  "eac3", "flac", "flv",
      "m2ts", "m4a",  "m4b",  "m4v",  "mk3d", "mka",  "mkv",  "mov",
      "mp3",  "mp4",  "mpeg", "mpg",  "mts",  "oga",  "ogg",  "ogv",
      "opus", "qt",   "spx",  "ts",   "vob",  "w64",  "wav",  "webm",
      "wma",  "wmv",  "wv",
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
  void attach(wam::qt::WindowManager *windows) {
    windows_ = windows;
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
// file the way `open -a WAM a.mp4 b.mp4` and Finder's multi-select do; before
// multi-window it could only honour the first one.
QList<QUrl> initialMediaUrls(const QCoreApplication &app) {
  QList<QUrl> media;
  const QStringList arguments = app.arguments();
  for (qsizetype index = 1; index < arguments.size(); ++index) {
    const QString &argument = arguments.at(index);
    if (argument.startsWith(QLatin1Char('-')))
      continue;

    const QUrl candidate = mediaUrlFromArgument(argument);
    if (candidate.isValid())
      media.append(candidate);
  }
  return media;
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
  // A bare, nonexistent container filename must stay local for every
  // extension the app offers, not just the handful the list happened to
  // carry. webm and mkv are the two the open dialog leads with.
  const QUrl missing_webm =
      mediaUrlFromArgument(QStringLiteral("definitely-missing.webm"));
  const QUrl missing_mka =
      mediaUrlFromArgument(QStringLiteral("definitely-missing.mka"));
  if (!missing_relative.isLocalFile() || !missing_filename.isLocalFile() ||
      !missing_webm.isLocalFile() || !missing_mka.isLocalFile() ||
      explicit_remote.isLocalFile() ||
      explicit_remote.scheme() != QStringLiteral("https") ||
      inferred_remote.isLocalFile() ||
      inferred_remote.scheme() != QStringLiteral("http")) {
    return runtimeVerificationFailure(
        6, QStringLiteral("WAM runtime verification failed: media path "
                          "resolution is invalid."));
  }

  if (!wam::qt::verifyResumeTracker()) {
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

#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  // Quiet launch seams. See testSeamEnabled above. Both are decided here,
  // before QGuiApplication exists, because the Cocoa platform integration
  // performs its launch-time activation inside that constructor: the only
  // place to suppress it is before it runs.
  //
  // QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM is the Qt cocoa plugin's
  // own guard on that step -- the plugin transforms the process to a
  // foreground application and calls
  // -[NSApplication activateIgnoringOtherApps:YES] specifically "to avoid
  // launching behind the terminal", which is exactly the focus steal this seam
  // exists to stop. Set only if the environment has not already spoken, on the
  // same principle as the QSG atlas knobs above.
  //
  // The mute gate is armed before any playback session can exist, so every
  // NativeAudioOutput this process builds snapshots it at construction.
  const bool test_seams_admitted =
      wam::qt::NativeBenchmarkTelemetry::instance().enabled();
  const bool background_launch =
      test_seams_admitted && testSeamEnabled("WAM_TEST_BACKGROUND");
  if (background_launch &&
      !qEnvironmentVariableIsSet("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM"))
    qputenv("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM", "1");
  if (test_seams_admitted && testSeamEnabled("WAM_TEST_MUTED"))
    wam::macos::setNativeAudioOutputTestMuted(true);
#endif

  QGuiApplication app(argc, argv);

#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
  // NSApp now exists and no window has been shown yet: the one moment where
  // dropping to the accessory policy costs no visible activation flicker.
  if (background_launch)
    wam::macos_window_chrome::adoptBackgroundLaunchPolicy();
#endif

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

  // A player window is a document window: closing the last one leaves the app
  // running with its menu bar, the way every document-based macOS app behaves,
  // and Cmd-O / a Finder open / a Dock click then makes a fresh one. Qt's
  // default is the opposite -- quitOnLastWindowClosed is true -- so without
  // this line closing one video would silently terminate the process. Quit
  // stays on Cmd-Q, the app menu, and the orderly-quit seam
  // (WAM_TEST_QUIT_AFTER_MS); all three call QCoreApplication::quit() and are
  // unaffected by this.
  app.setQuitOnLastWindowClosed(false);

  int exit_code = 0;
  {
    QQmlApplicationEngine engine;
#if defined(Q_OS_MACOS) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    // On the CALayer presentation route the video is an
    // AVSampleBufferDisplayLayer sitting *below* Qt's view, so the QML
    // background must stop painting opaque black over it. The route decision
    // is process-wide and shared with the session factory
    // (native_layer_presentation_state.hpp) so the two cannot disagree; it is
    // therefore an app-level context property, inherited by every window's
    // own child context.
    engine.rootContext()->setContextProperty(
        QStringLiteral("layerPresentation"),
        wam::macos::layerPresentationRouteSelected());
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

    // The window factory. Everything app-level -- the state store and its
    // persistence checkpoint, the single desktop menu bar, the single
    // Preferences window, focus routing, and the settings mirror that makes
    // one Preferences change apply live to every window -- lives here; the
    // controller, chrome bridge, resume tracker and native playback session
    // are per window.
    wam::qt::WindowManager windows(engine, state_store);
    engine.rootContext()->setContextProperty(QStringLiteral("appHost"),
                                             &windows);
    windows.setBackgroundLaunch(background_launch);
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    // WAM_TEST_GEOMETRY parks the FIRST window at an exact rectangle. Later
    // windows cascade off it exactly as real ones do, so a multi-window
    // measurement still gets N findable, non-overlapping windows.
    if (test_seams_admitted) {
      if (const std::optional<ScriptedGeometry> parked =
              parseGeometry(qgetenv("WAM_TEST_GEOMETRY"))) {
        windows.setParkedGeometry(parked->x, parked->y, parked->width,
                                  parked->height);
      }
    }
#endif

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
    // -- a signal with NO default receiver on this construction (the runtime
    // warned "emitted, but no receivers connected" and Cmd-Q silently did
    // nothing). Wire it, and its exit() sibling, explicitly. Queued, so the
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
      // loop is alive, so the teardown runs here and synchronously.
      windows.closeAllWindows();
      windows.flushPersistence();
    });

    wam::qt::PlayerWindow *first = windows.createWindow();
    if (first == nullptr)
      return 2;
    if (!first->controller()->available())
      return 3;
    wam::qt::PlayerController *first_player = first->controller();

    if (const auto rate = initialPlaybackRate(app))
      first_player->setRate(*rate);

    // Scripted seek driver. See ScriptedSeek above: telemetry-gated, replays
    // the public scrubber gesture so a parked window needs no pointer. Bound
    // to the FIRST window only -- the scripted seams are single-session
    // measurement tools and a second window is not part of any trial they
    // describe.
    std::vector<ScriptedSeek> seek_script;
    ScriptedSeekState seek_state;
#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    if (wam::qt::NativeBenchmarkTelemetry::instance().enabled())
      seek_script = parseSeekScript(qgetenv("WAM_TEST_SEEK_SCRIPT"));
#endif
    seek_state.clock.start();
    const auto advance_seek_script = [first_player, &seek_script, &seek_state] {
      if (seek_state.index >= seek_script.size())
        return;
      // A commit target is admitted only while the session is prepared and has
      // no commit already in flight, so a gesture can be refused for reasons
      // that clear on their own. Confirm each scripted seek by arrival and
      // retry a bounded number of times rather than silently skipping it.
      if (seek_state.awaiting) {
        if (std::abs(first_player->position() - seek_state.target) <= 1.0) {
          seek_state.awaiting = false;
          seek_state.attempts = 0;
          ++seek_state.index;
        } else if (seek_state.clock.elapsed() - seek_state.issued_ms > 2500) {
          seek_state.awaiting = false;
          if (++seek_state.attempts >= 5) {
            seek_state.attempts = 0;
            ++seek_state.index;
          }
        }
        return;
      }
      if (seek_state.busy)
        return;
      const double position = first_player->position();
      const double duration = first_player->duration();
      const ScriptedSeek &next = seek_script[seek_state.index];
      if (duration <= 0.0 || !first_player->playing() || position < next.when)
        return;
      const double target = onSeekScriptGrid(std::min(next.target, duration));
      seek_state.busy = true;
      // One pointer gesture: press, three motion previews, release-commit. The
      // delays are the pacing a real drag has, which is what lets the preview
      // lane actually decode before the exact commit lands.
      first_player->beginScrub();
      first_player->previewSeekTo(onSeekScriptGrid(std::max(0.0, target - 0.5)));
      QTimer::singleShot(120, first_player, [first_player, target] {
        first_player->previewSeekTo(onSeekScriptGrid(std::max(0.0, target - 0.25)));
      });
      QTimer::singleShot(240, first_player,
                         [first_player, target] { first_player->previewSeekTo(target); });
      QTimer::singleShot(360, first_player, [first_player, &seek_state, target] {
        first_player->endScrub(target);
        seek_state.target = target;
        seek_state.issued_ms = seek_state.clock.elapsed();
        seek_state.awaiting = true;
        seek_state.busy = false;
      });
    };
    if (!seek_script.empty()) {
      QObject::connect(first_player, &wam::qt::PlayerController::positionChanged,
                       first_player, advance_seek_script);
    }

    const QList<QUrl> media = initialMediaUrls(app);
    if (!media.isEmpty()) {
      QTimer::singleShot(0, &windows, [&windows, media] {
        // The first window is empty, so it claims the first file; every
        // further argument creates its own window.
        for (const QUrl &url : media)
          static_cast<void>(windows.openUrl(url));
      });
    }
    file_open_relay.attach(&windows);

#if defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
    // Warm-open measurement, on the scripted-seek opt-in. Each entry reopens
    // in the already-running FIRST window, so its telemetry lineage is a warm
    // open with no launch work in the span -- and deliberately a replacement
    // rather than a new window, because a new window would pay window and
    // scene-graph startup and stop being a warm open at all.
    if (wam::qt::NativeBenchmarkTelemetry::instance().enabled()) {
      const std::vector<ScriptedOpen> open_script =
          parseOpenScript(qgetenv("WAM_TEST_REOPEN_SCRIPT"));
      int cumulative = 0;
      for (const ScriptedOpen &entry : open_script) {
        cumulative += entry.delayMilliseconds;
        const QString path = entry.path;
        QTimer::singleShot(cumulative, first_player, [first_player, path] {
          const QUrl target = mediaUrlFromArgument(path);
          if (target.isValid())
            first_player->open(target);
        });
      }

      const std::vector<ScriptedRate> rate_script =
          parseRateScript(qgetenv("WAM_TEST_RATE_SCRIPT"));
      int rateCumulative = 0;
      for (const ScriptedRate &entry : rate_script) {
        rateCumulative += entry.delayMilliseconds;
        const ScriptedRate scheduled = entry;
        QTimer::singleShot(rateCumulative, first_player,
                           [first_player, scheduled] {
                             if (scheduled.pause) {
                               first_player->pause();
                             } else if (scheduled.resume) {
                               first_player->play();
                             } else {
                               first_player->setRate(scheduled.rate);
                             }
                           });
      }

      // Scripted multi-window lifecycle. See ScriptedWindowStep above.
      const std::vector<ScriptedWindowStep> window_script =
          parseWindowScript(qgetenv("WAM_TEST_WINDOW_SCRIPT"));
      int windowCumulative = 0;
      for (const ScriptedWindowStep &step : window_script) {
        windowCumulative += step.delayMilliseconds;
        const QString verb = step.verb;
        QTimer::singleShot(windowCumulative, &windows,
                           [&windows, verb] { runWindowStep(windows, verb); });
      }

      // Orderly quit for the benchmark harness. Telemetry buffers facts in
      // memory and commits them at a checkpoint or at the terminal drain, so
      // a signal-killed process loses every fact recorded after the last
      // first draw. Quitting through the event loop lets that drain run --
      // and still works with quitOnLastWindowClosed off, because it is
      // QCoreApplication::quit(), not a window close.
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
