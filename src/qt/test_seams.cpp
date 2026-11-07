#include "test_seams.hpp"

#include "macos_window_chrome.hpp"
#include "native_benchmark_telemetry.hpp"
#include "qt/native_playback_owner.hpp"
#include "platform/macos/native_embedding_support.hpp"
#include "player_controller.hpp"
#include "window_manager.hpp"

#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QKeySequence>
#include <QQmlListReference>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QTimer>
#include <QVariantMap>
#include <QWheelEvent>
#include <qpa/qwindowsysteminterface.h>

#include <algorithm>
#include <cmath>
#include <functional>
#include <memory>
#include <utility>

namespace wam::qt {

// Fault injection through the real owner/router notification and recovery
// boundaries (the `nativefail` verb).
struct NativePlaybackOwnerTestAccess {
  static void fail(NativePlaybackOwner &owner) {
    const auto snapshot = owner.routeSnapshot();
    owner.consumeLifecycle(native_protocol::Failed{
        {snapshot.attempt, snapshot.serial}, native_protocol::FailureReason::Protocol}, false);
  }
};
class PlayerControllerTestAccess {
public:
  static void failNative(PlayerController &player) {
    if (player.native_)
      NativePlaybackOwnerTestAccess::fail(static_cast<NativePlaybackOwner &>(*player.native_));
  }
};

namespace {

// One report line in two renderings: the `WAM_TEST_<TAG> key=value ...` text
// line existing harnesses parse, then the same fields as one JSON record
// ({"record":"test_<tag>", ...}) for tests/support/wam_launch.py.
class Report {
public:
  explicit Report(QLatin1StringView tag) : tag_(tag) {}
  Report(const Report &) = delete;
  Report &operator=(const Report &) = delete;
  ~Report() {
    QString line = QStringLiteral("WAM_TEST_") + tag_;
    QJsonObject record{{QStringLiteral("record"), QStringLiteral("test_") + QString(tag_).toLower()}};
    for (const auto &[key, text, json] : fields_) {
      line += QLatin1Char(' ') + key + QLatin1Char('=') + text;
      record.insert(key, json);
    }
    qInfo().noquote() << line;
    qInfo().noquote() << QJsonDocument(record).toJson(QJsonDocument::Compact);
  }

  Report &add(const char *key, const QString &text, const QJsonValue &json) {
    fields_.push_back({QString::fromLatin1(key), text, json});
    return *this;
  }
  Report &add(const char *key, const QString &value) { return add(key, value, value); }
  Report &add(const char *key, int value) { return add(key, QString::number(value), value); }
  Report &add(const char *key, qint64 value) { return add(key, QString::number(value), value); }
  Report &add(const char *key, bool value) { return add(key, value ? 1 : 0); }
  // QString::arg's default rendering, which the text format has always used.
  Report &add(const char *key, double value) { return add(key, QStringLiteral("%1").arg(value), value); }
  Report &add(const char *key, double value, int decimals) {
    return add(key, QString::number(value, 'f', decimals), value);
  }

private:
  struct Field {
    QString key;
    QString text;
    QJsonValue json;
  };
  QLatin1StringView tag_;
  std::vector<Field> fields_;
};

// QML state read by name. -1 when the window, object or property is missing.
int rootFlag(const PlayerWindow *window, const char *name) {
  const QObject *root = window != nullptr ? window->qmlRoot() : nullptr;
  if (root == nullptr)
    return -1;
  const QVariant value = root->property(name);
  return value.isValid() ? (value.toBool() ? 1 : 0) : -1;
}

int childFlag(const PlayerWindow *window, const char *child, const char *name) {
  const QObject *root = window != nullptr ? window->qmlRoot() : nullptr;
  const QObject *item = root != nullptr ? root->findChild<QObject *>(QString::fromLatin1(child)) : nullptr;
  if (item == nullptr)
    return -1;
  const QVariant value = item->property(name);
  return value.isValid() ? (value.toBool() ? 1 : 0) : -1;
}

// The exact display size the controller holds, as its own line.
void reportExactGeometry(const PlayerController &player) {
  const auto exact = player.exactVideoDisplaySize();
  if (exact.empty())
    return;
  const auto aspect = media::displayAspect(exact);
  const auto ratio = [](auto numerator, auto denominator) {
    return QStringLiteral("%1/%2").arg(numerator).arg(denominator);
  };
  const QString width = ratio(exact.width.numerator, exact.width.denominator);
  const QString height = ratio(exact.height.numerator, exact.height.denominator);
  const QString aspectText = ratio(aspect.numerator, aspect.denominator);
  const QString physical = QStringLiteral("%1x%2")
                               .arg(media::displayPhysicalPixels(exact.width))
                               .arg(media::displayPhysicalPixels(exact.height));
  Report(QLatin1StringView("EXACT_GEOMETRY"))
      .add("width", width).add("height", height).add("aspect", aspectText)
      .add("actual_physical", physical);
}

// The video size the window's geometry works from, read off the QML root, so
// a round can prove the number reached the aspect lock even while QML
// suppresses the aspect snap (windowChrome.benchmarkMode).
QString videoNaturalSize(const PlayerWindow *window) {
  const QObject *root = window != nullptr ? window->qmlRoot() : nullptr;
  const QVariant value = root != nullptr ? root->property("videoNaturalSize") : QVariant();
  if (!value.isValid())
    return QStringLiteral("?");
  const QSizeF size = value.toSizeF();
  return QStringLiteral("%1x%2").arg(size.width(), 0, 'f', 0).arg(size.height(), 0, 'f', 0);
}

// Qt.labs.platform exposes `menus` and `items` only as QQmlListProperty, so
// the walk goes through QQmlListReference.
void reportMenus(const WindowManager &windows) {
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
    for (qsizetype itemIndex = 0; entries.isValid() && itemIndex < entries.count(); ++itemIndex) {
      QObject *item = entries.at(itemIndex);
      if (item == nullptr)
        continue;
      const QVariant text = item->property("text");
      if (!text.isValid() || !item->property("visible").toBool())
        continue;
      QString label = text.toString();
      if (label.isEmpty())
        label = QStringLiteral("-");
      if (item->property("checkable").toBool())
        label = (item->property("checked").toBool() ? QStringLiteral("[x] ") : QStringLiteral("[ ] ")) + label;
      if (!item->property("enabled").toBool())
        label += QStringLiteral(" (disabled)");
      items.append(label);
    }
    Report(QLatin1StringView("MENU"))
        .add("title", menu->property("title").toString())
        .add("items", QLatin1Char('[') + items.join(QStringLiteral(" | ")) + QLatin1Char(']'),
             QJsonArray::fromStringList(items));
  }
}

void reportWindows(const WindowManager &windows) {
  const auto workers = macos::NativeEmbeddingSupport::softwareWorkers();
  Report(QLatin1StringView("SOFTWARE_WORKERS"))
      .add("active", qint64(workers.active)).add("pending", qint64(workers.pending))
      .add("peak", qint64(workers.peak)).add("bytes", qint64(workers.bytes));
  const QList<PlayerWindow *> &open = windows.windows();
  Report(QLatin1StringView("WINDOWS")).add("count", int(open.size()));
  for (qsizetype position = 0; position < open.size(); ++position) {
    const PlayerWindow *window = open.at(position);
    const PlayerController *player = window->controller();
    if (player == nullptr)
      continue;
    const int index = int(position);
    QQuickWindow *quick = window->window();
    const QRect frame = quick != nullptr ? quick->geometry() : QRect();
    reportExactGeometry(*player);
    // vivid/theater are what QML believes; vboost and dims are what AppKit
    // and CoreAnimation hold. A disagreement between them is the defect a
    // round has to see: vboost reads the display layer's attached filter (0 =
    // no display layer, i.e. the libmpv route), dims counts the overlay
    // windows on screen. `source` stays last: it is free text.
    Report(QLatin1StringView("WINDOW"))
        .add("idx", index)
        .add("media", player->hasMedia())
        .add("paused", player->paused())
        .add("playing", player->playing())
        .add("rate", player->rate())
        .add("step", windows.settings().seekStepSeconds())
        .add("hugs", windows.settings().windowHugsVideo())
        .add("pitch", player->preservePitch())
        .add("geom", QStringLiteral("%1x%2+%3+%4").arg(frame.width()).arg(frame.height())
                         .arg(frame.x()).arg(frame.y()))
        .add("volume", player->volume(), 4)
        .add("muted", player->muted())
        .add("gestures", windows.settings().scrollGesturesEnabled())
        .add("pos", player->position(), 4)
        .add("dur", player->duration(), 4)
        .add("chrome", rootFlag(window, "controlsRevealed"))
        .add("vfeedback", childFlag(window, "transport", "volumeFeedback"))
        .add("vnat", videoNaturalSize(window))
        .add("vmax", player->maximumVolume(), 4)
        .add("padded", rootFlag(window, "fillScreenPadded"))
        .add("fullscreen", quick != nullptr ? (quick->visibility() == QWindow::FullScreen ? 1 : 0) : -1)
        .add("osd", childFlag(window, "volumeOsd", "shown"))
        .add("tlalpha", quick != nullptr ? macos_window_chrome::titlebarControlsAlpha(quick) : -1.0, 3)
        .add("nsfs", quick != nullptr ? (macos_window_chrome::nativeFullScreen(quick) ? 1 : 0) : -1)
        .add("vivid", rootFlag(window, "vividActive"))
        .add("vboost", quick != nullptr ? macos_window_chrome::appliedVividBoost(quick) : -1.0, 3)
        .add("hdr", rootFlag(window, "sourceIsHdr"))
        .add("edr", quick != nullptr ? macos_window_chrome::screenEdrHeadroom(quick) : -1.0, 3)
        .add("theater", rootFlag(window, "theaterDimEnabled"))
        .add("dims", macos_window_chrome::theaterDimOverlayCount())
        .add("source", QFileInfo(player->source().toLocalFile()).fileName());

    Report(QLatin1StringView("DIALOG"))
        .add("idx", index).add("visible", rootFlag(window, "nativeDialogVisible"));

    // Subtitles get their own line: track labels are free text. `text` is the
    // line on screen, read from the property the overlay binds.
    QStringList trackSummary;
    QJsonArray trackRecords;
    const QVariantList tracks = player->subtitleTracks();
    for (const QVariant &entry : tracks) {
      const QVariantMap track = entry.toMap();
      const int id = track.value(QStringLiteral("id")).toInt();
      const QString origin = track.value(QStringLiteral("origin")).toString();
      const QString label = track.value(QStringLiteral("label")).toString();
      trackSummary.append(QStringLiteral("%1:%2:%3").arg(id).arg(origin, label));
      trackRecords.append(QJsonObject{{QStringLiteral("id"), id},
                                      {QStringLiteral("origin"), origin},
                                      {QStringLiteral("label"), label}});
    }
    QString text = player->subtitleText();
    const QString escaped = QString(text).replace(QLatin1Char('\n'), QStringLiteral("\\n"));
    Report(QLatin1StringView("SUBTITLES"))
        .add("idx", index)
        .add("active", player->activeSubtitleTrack())
        .add("visible", player->captionsVisible())
        .add("count", int(tracks.size()))
        .add("text", QLatin1Char('[') + escaped + QLatin1Char(']'), text)
        .add("tracks", QLatin1Char('[') + trackSummary.join(QLatin1Char('|')) + QLatin1Char(']'), trackRecords)
        .add("bitmap", player->subtitleBitmapVisible())
        .add("bitmaprect",
             QStringLiteral("%1,%2,%3,%4")
                 .arg(player->subtitleBitmapX(), 0, 'f', 4).arg(player->subtitleBitmapY(), 0, 'f', 4)
                 .arg(player->subtitleBitmapWidth(), 0, 'f', 4).arg(player->subtitleBitmapHeight(), 0, 'f', 4),
             QJsonArray{player->subtitleBitmapX(), player->subtitleBitmapY(),
                        player->subtitleBitmapWidth(), player->subtitleBitmapHeight()});
  }
}

// One synthetic wheel event per count through Qt's ordinary delivery, in the
// shape Qt's cocoa plugin delivers for a trackpad (angleDelta = 2 x
// pixelDelta; see src/qt/scroll_gesture.hpp).
void deliverWheel(QQuickWindow *window, QPointF fraction, QPoint pixelDelta, bool inverted,
                  Qt::ScrollPhase phase, int count) {
  if (window == nullptr || count <= 0)
    return;
  const QPointF local(window->width() * fraction.x(), window->height() * fraction.y());
  const QPointF global = window->position() + local;
  for (int emitted = 0; emitted < count; ++emitted) {
    // A real gesture carries ScrollBegin once and ScrollUpdate after it.
    const Qt::ScrollPhase step = (phase == Qt::ScrollBegin && emitted > 0) ? Qt::ScrollUpdate : phase;
    QWheelEvent event(local, global, pixelDelta, pixelDelta * 2, Qt::NoButton, Qt::NoModifier, step,
                      inverted, Qt::MouseEventSynthesizedByApplication);
    QCoreApplication::sendEvent(window, &event);
  }
}

struct VerbContext {
  WindowManager &windows;
  UrlResolver resolve;
  const QStringList &fields;

  [[nodiscard]] PlayerWindow *window() const {
    const QList<PlayerWindow *> &open = windows.windows();
    const int index = fields.size() > 1 ? fields.at(1).toInt() : 0;
    return index >= 0 && index < open.size() ? open.at(index) : nullptr;
  }
  [[nodiscard]] int index() const { return fields.size() > 1 ? fields.at(1).toInt() : 0; }
  // Everything after the first `skip` fields, rejoined so a path keeps its ':'.
  [[nodiscard]] QString tail(qsizetype skip) const { return fields.mid(skip).join(QLatin1Char(':')); }
  [[nodiscard]] double number(qsizetype field) const { return fields.value(field).toDouble(); }
};

void triggerAction(const VerbContext &c, const QString &name) {
  PlayerWindow *window = c.window();
  QVariant taken;
  if (window == nullptr ||
      !QMetaObject::invokeMethod(window->qmlRoot(), "triggerAction", Q_RETURN_ARG(QVariant, taken),
                                 Q_ARG(QVariant, name)) ||
      !taken.toBool())
    qCritical().noquote() << "WAM_TEST_WINDOW_SCRIPT: command not taken:" << name;
}

struct Verb {
  QLatin1StringView name;
  void (*run)(const VerbContext &);
};

// WAM_TEST_WINDOW_SCRIPT verbs. `<i>` is a window's position in creation
// order. They drive the public WindowManager / controller / QML boundaries
// from inside the process, because driving them from outside means System
// Events and an accessibility grant, which steal focus and reset HIDIdleTime.
constexpr Verb kVerbs[] = {
    // new: create an empty window.
    {QLatin1StringView("new"), [](const VerbContext &c) { static_cast<void>(c.windows.createWindow()); }},
    // open:<path>: WindowManager::openUrl (claims an empty window or makes one).
    {QLatin1StringView("open"), [](const VerbContext &c) {
       const QUrl target = c.resolve(c.tail(1));
       if (target.isValid()) static_cast<void>(c.windows.openUrl(target));
     }},
    // load:<i>:<path>: the drag-and-drop gesture into that window.
    {QLatin1StringView("load"), [](const VerbContext &c) {
       if (PlayerWindow *window = c.window()) {
         const QUrl target = c.resolve(c.tail(2));
         if (target.isValid()) static_cast<void>(window->controller()->open(target));
       }
     }},
    // close:<i>: the user close path, including playback teardown.
    {QLatin1StringView("close"), [](const VerbContext &c) {
       if (PlayerWindow *window = c.window())
         if (QQuickWindow *quick = window->window()) quick->close();
     }},
    // nativefail:<i>: inject a current Protocol refusal through the owner.
    {QLatin1StringView("nativefail"), [](const VerbContext &c) {
       if (PlayerWindow *window = c.window()) PlayerControllerTestAccess::failNative(*window->controller());
     }},
    // action:<i>:<name>: trigger that window's PlayerActions command (qml/PlayerActions.qml).
    {QLatin1StringView("action"), [](const VerbContext &c) { triggerAction(c, c.fields.value(2)); }},
    // edit:<i>: the Quick Edit command, without activating the window.
    {QLatin1StringView("edit"), [](const VerbContext &c) { triggerAction(c, QStringLiteral("quickEdit")); }},
    // controls:<i>:<0|1>: set chrome visibility, modelling the foreground
    // chrome without activating the window.
    {QLatin1StringView("controls"), [](const VerbContext &c) {
       if (PlayerWindow *window = c.window()) {
         QMetaObject::invokeMethod(window->qmlRoot(), "setChromeState",
                                   Q_ARG(QVariant, c.fields.value(2).toInt() != 0 ? QStringLiteral("held")
                                                                                  : QStringLiteral("hidden")));
         if (auto *bar = window->qmlRoot()->findChild<QQuickItem *>(QStringLiteral("transport")))
           bar->setProperty("suppressed", false);
       }
     }},
    // key:<i>:<K>: deliver a bare key to the QML stage.
    {QLatin1StringView("key"), [](const VerbContext &c) {
       if (PlayerWindow *window = c.window())
         if (auto *stage = window->qmlRoot()->findChild<QQuickItem *>(QStringLiteral("videoStage"))) {
           QKeyEvent event(QEvent::KeyPress, c.fields.value(2).at(0).unicode(), Qt::NoModifier);
           QCoreApplication::sendEvent(stage, &event);
         }
     }},
    // windowkey:<i>:<Key>: a key through the window's shortcut map, the way
    // the Cocoa plugin delivers one (e.g. windowkey:0:Space). The window gets
    // Qt's focus only; the app is never activated.
    {QLatin1StringView("windowkey"), [](const VerbContext &c) {
       PlayerWindow *window = c.window();
       const QKeyCombination key = QKeySequence::fromString(c.fields.value(2))[0];
       if (window == nullptr || window->window() == nullptr) return;
       QWindowSystemInterface::handleFocusWindowChanged<QWindowSystemInterface::SynchronousDelivery>(window->window());
       const QString text = key.key() == Qt::Key_Space ? QStringLiteral(" ") : c.fields.value(2);
       if (!QWindowSystemInterface::handleShortcutEvent(window->window(), 0, key.key(), key.keyboardModifiers(),
                                                        0, 0, 0, text))
         qCritical().noquote() << "WAM_TEST_WINDOW_SCRIPT: no shortcut took" << c.fields.value(2);
     }},
    // focus:<i>:<0|1>: give the window Qt's focus (so `active` turns true) or
    // take it away; the app is never activated.
    {QLatin1StringView("focus"), [](const VerbContext &c) {
       if (PlayerWindow *window = c.window())
         QWindowSystemInterface::handleFocusWindowChanged<QWindowSystemInterface::SynchronousDelivery>(
             c.fields.value(2).toInt() != 0 ? window->window() : nullptr);
     }},
    // layout:<i>: report named overlay/control geometry and the loading title.
    {QLatin1StringView("layout"), [](const VerbContext &c) {
       PlayerWindow *window = c.window();
       if (window == nullptr) return;
       for (const char *name : {"subtitleLayer", "transport", "playCluster", "utilityCluster", "volumeOsd", "loadingLabel"}) {
         if (auto *item = window->qmlRoot()->findChild<QQuickItem *>(QString::fromLatin1(name))) {
           const QPointF origin = item->mapToScene(QPointF());
           Report(QLatin1StringView("LAYOUT"))
               .add("name", QString::fromLatin1(name)).add("x", origin.x()).add("y", origin.y())
               .add("w", item->width()).add("h", item->height()).add("visible", item->isVisible())
               .add("opacity", item->opacity());
         }
       }
       const PlayerController *player = window->controller();
       qInfo().noquote() << "WAM_TEST_LOADING" << player->loading() << player->mediaTitle();
       qInfo().noquote() << QJsonDocument(QJsonObject{{QStringLiteral("record"), QStringLiteral("test_loading")},
                                                      {QStringLiteral("loading"), player->loading()},
                                                      {QStringLiteral("title"), player->mediaTitle()}})
                                .toJson(QJsonDocument::Compact);
     }},
    // pause:<i> / play:<i> / rate:<i>:<value>.
    {QLatin1StringView("pause"), [](const VerbContext &c) { if (PlayerWindow *w = c.window()) w->controller()->pause(); }},
    {QLatin1StringView("play"), [](const VerbContext &c) { if (PlayerWindow *w = c.window()) w->controller()->play(); }},
    {QLatin1StringView("rate"), [](const VerbContext &c) { if (PlayerWindow *w = c.window()) w->controller()->setRate(c.number(2)); }},
    // seekstep:<value>: set the app-level seek step every window follows.
    {QLatin1StringView("seekstep"), [](const VerbContext &c) {
       c.windows.settings().setSeekStepSeconds(static_cast<int>(std::lround(c.number(1))));
     }},
    // skip:<i>:<seconds>: the keyboard skip path (seekRelative), as opposed
    // to WAM_TEST_SEEK_SCRIPT's scrubber gestures.
    {QLatin1StringView("skip"), [](const VerbContext &c) { if (PlayerWindow *w = c.window()) w->controller()->seekRelative(c.number(2)); }},
    // volume:<i>:<v>: normalized volume (0..maximum).
    {QLatin1StringView("volume"), [](const VerbContext &c) { if (PlayerWindow *w = c.window()) w->controller()->setVolume(c.number(2)); }},
    // grab:<i>:<path>: the window's QML SCENE to a PNG. A screen capture is
    // spoiled by anything the live user raises; this is what WAM drew. On the
    // layer route the video is composited below Qt's view and is not in it.
    {QLatin1StringView("grab"), [](const VerbContext &c) {
       PlayerWindow *window = c.window();
       QQuickWindow *quick = window != nullptr ? window->window() : nullptr;
       if (quick == nullptr) return;
       const QImage image = quick->grabWindow();
       const QString path = c.tail(2);
       Report(QLatin1StringView("GRAB"))
           .add("idx", c.index()).add("size", QStringLiteral("%1x%2").arg(image.width()).arg(image.height()))
           .add("saved", !image.isNull() && image.save(path)).add("path", path);
     }},
    // videograb:<i>:<path>: the window AS COMPOSITED, video included, read
    // back from the window server. Needs Screen Recording.
    {QLatin1StringView("videograb"), [](const VerbContext &c) {
       PlayerWindow *window = c.window();
       QQuickWindow *quick = window != nullptr ? window->window() : nullptr;
       if (quick == nullptr) return;
       const QString path = c.tail(2);
       const bool saved = macos_window_chrome::captureWindowToFile(quick, path);
       Report(QLatin1StringView("VIDEOGRAB")).add("idx", c.index()).add("saved", saved).add("path", path);
     }},
    // mute:<i>: the Mute command.
    {QLatin1StringView("mute"), [](const VerbContext &c) { triggerAction(c, QStringLiteral("mute")); }},
    // scroll:<i>:<dx>:<dy>:<count>[:<phase>[:<inverted>[:<fx>:<fy>]]]: <count>
    // wheel events with PIXEL deltas; phase 0..4 = Qt::ScrollPhase; fx/fy are
    // fractions of the window, default (0.5, 0.35): over the picture, clear of
    // the transport.
    {QLatin1StringView("scroll"), [](const VerbContext &c) {
       PlayerWindow *window = c.window();
       if (window == nullptr) return;
       const int phaseField = c.fields.value(5).toInt();
       bool fxOk = false;
       bool fyOk = false;
       const double fx = c.fields.value(7).toDouble(&fxOk);
       const double fy = c.fields.value(8).toDouble(&fyOk);
       deliverWheel(window->window(), QPointF(fxOk ? fx : 0.5, fyOk ? fy : 0.35),
                    QPoint(c.fields.value(2).toInt(), c.fields.value(3).toInt()),
                    c.fields.value(6).toInt() != 0,
                    phaseField >= 0 && phaseField <= 4 ? static_cast<Qt::ScrollPhase>(phaseField) : Qt::NoScrollPhase,
                    std::max(1, c.fields.value(4).toInt()));
     }},
    // subsload:<i>:<path>: Load Subtitle File without the native open panel.
    {QLatin1StringView("subsload"), [](const VerbContext &c) {
       if (PlayerWindow *window = c.window()) {
         const QUrl target = c.resolve(c.tail(2));
         if (target.isValid()) static_cast<void>(window->controller()->loadSubtitleFile(target));
       }
     }},
    // captions:<i>:<path>: generate captions into <path> without the Save panel.
    {QLatin1StringView("captions"), [](const VerbContext &c) {
       if (PlayerWindow *window = c.window()) {
         const QString path = c.tail(2);
         if (!path.isEmpty()) window->controller()->generateCaptionsTo(QUrl::fromLocalFile(path));
       }
     }},
    // menu: one WAM_TEST_MENU line per top-level menu, read off the real
    // Qt.labs.platform menu bar (a screenshot cannot see an auto-hidden bar).
    {QLatin1StringView("menu"), [](const VerbContext &c) { reportMenus(c.windows); }},
    // menuclick:<label>: activate the first menu item whose title starts
    // with <label>, as a click does (a checkable item flips its own check
    // mark before it triggers).
    {QLatin1StringView("menuclick"), [](const VerbContext &c) {
       QObject *bar = c.windows.menuBarObject();
       const QQmlListReference menus(bar, "menus");
       const QString label = c.tail(1);
       for (qsizetype m = 0; menus.isValid() && m < menus.count(); ++m) {
         const QQmlListReference items(menus.at(m), "items");
         for (qsizetype i = 0; items.isValid() && i < items.count(); ++i) {
           QObject *item = items.at(i);
           if (item->property("text").toString().startsWith(label)) {
             QMetaObject::invokeMethod(item, "activate");
             return;
           }
         }
       }
       qCritical().noquote() << "WAM_TEST_WINDOW_SCRIPT: no menu item" << label;
     }},
    // report: WAM_TEST_WINDOWS, then WINDOW / DIALOG / SUBTITLES per window.
    {QLatin1StringView("report"), [](const VerbContext &c) { reportWindows(c.windows); }},
};

const Verb *findVerb(QStringView text) {
  const qsizetype colon = text.indexOf(QLatin1Char(':'));
  const QStringView head = colon < 0 ? text : text.first(colon);
  for (const Verb &verb : kVerbs)
    if (head == verb.name)
      return &verb;
  return nullptr;
}

// Reads the scripts. Every malformed entry is printed; any one fails the load.
struct ScriptParser {
  bool failed = false;

  void reject(const char *name, const QByteArray &entry, const char *why) {
    qCritical().noquote() << QStringLiteral("%1: %2 in entry '%3'")
                                 .arg(QLatin1StringView(name), QLatin1StringView(why), QString::fromUtf8(entry));
    failed = true;
  }

  // `name`'s comma-separated entries as (text, number), split at the '@'
  // next to the number. Empty entries are skipped.
  std::vector<std::pair<QByteArray, QByteArray>> entries(const char *name, bool numberFirst) {
    std::vector<std::pair<QByteArray, QByteArray>> result;
    for (const QByteArray &raw : qgetenv(name).split(',')) {
      const QByteArray entry = raw.trimmed();
      if (entry.isEmpty())
        continue;
      const qsizetype at = numberFirst ? entry.indexOf('@') : entry.lastIndexOf('@');
      if (at <= 0 || at == entry.size() - 1) {
        reject(name, entry, "expected <a>@<b>");
        continue;
      }
      QByteArray text = entry.left(at).trimmed();
      QByteArray number = entry.sliced(at + 1).trimmed();
      if (numberFirst)
        std::swap(text, number);
      result.emplace_back(text, number);
    }
    return result;
  }

  std::vector<TestSeams::SeekStep> seeks(const char *name) {
    std::vector<TestSeams::SeekStep> steps;
    for (const auto &[target, when] : entries(name, false)) {
      bool targetOk = false;
      bool whenOk = false;
      const TestSeams::SeekStep step{target.toDouble(&targetOk), when.toDouble(&whenOk)};
      if (!targetOk || !whenOk || !std::isfinite(step.target) || !std::isfinite(step.when) ||
          step.target < 0.0 || step.when < 0.0)
        reject(name, target + '@' + when, "expected non-negative seconds");
      else
        steps.push_back(step);
    }
    return steps;
  }

  std::vector<TestSeams::TimedStep> timed(const char *name, bool delayFirst) {
    std::vector<TestSeams::TimedStep> steps;
    for (const auto &[text, delay] : entries(name, delayFirst)) {
      bool ok = false;
      const int milliseconds = delay.toInt(&ok);
      if (!ok || milliseconds < 0)
        reject(name, text + '@' + delay, "expected a non-negative millisecond delay");
      else
        steps.push_back({QString::fromUtf8(text), milliseconds});
    }
    return steps;
  }
};

std::optional<QRect> parseGeometry(const QByteArray &value) {
  static const QRegularExpression pattern(QStringLiteral("^(\\d+)x(\\d+)\\+(-?\\d+)\\+(-?\\d+)$"));
  const QRegularExpressionMatch match = pattern.match(QString::fromLatin1(value).trimmed());
  if (!match.hasMatch())
    return std::nullopt;
  const QRect rect(match.captured(3).toInt(), match.captured(4).toInt(), match.captured(1).toInt(),
                   match.captured(2).toInt());
  if (rect.width() < 64 || rect.height() < 64)
    return std::nullopt;
  return rect;
}

std::optional<TestSeams> &storage() {
  static std::optional<TestSeams> seams;
  return seams;
}

// Cumulative delays from now. Precise timers: coarse ones merge short
// successive steps into bursts.
void schedule(QObject *context, const std::vector<TestSeams::TimedStep> &steps,
              const std::function<void(const QString &)> &run) {
  int cumulative = 0;
  for (const TestSeams::TimedStep &step : steps) {
    cumulative += step.delayMilliseconds;
    QTimer::singleShot(cumulative, Qt::PreciseTimer, context, [run, text = step.text] { run(text); });
  }
}

// WAM_TEST_SEEK_SCRIPT "target@when,...": once playback first reaches `when`
// seconds, replay one scrubber drag to `target` on the first window through
// beginScrub / previewSeekTo / endScrub, so both the preview lane and the
// exact commit are exercised.
void startSeekScript(PlayerController *player, std::vector<TestSeams::SeekStep> script) {
  struct State {
    std::vector<TestSeams::SeekStep> script;
    std::size_t index = 0;
    int attempts = 0;
    bool busy = false;
    bool awaiting = false;
    double target = 0.0;
    QElapsedTimer clock;
    qint64 issuedMs = 0;
  };
  auto state = std::make_shared<State>();
  state->script = std::move(script);
  state->clock.start();
  QObject::connect(player, &PlayerController::positionChanged, player, [player, state] {
    if (state->index >= state->script.size())
      return;
    // A commit is admitted only while the session is prepared with no commit
    // in flight, so a gesture can be refused for reasons that clear on their
    // own: confirm each seek by arrival and retry a bounded number of times.
    if (state->awaiting) {
      if (std::abs(player->position() - state->target) <= 1.0) {
        state->awaiting = false;
        state->attempts = 0;
        ++state->index;
      } else if (state->clock.elapsed() - state->issuedMs > 2500) {
        state->awaiting = false;
        if (++state->attempts >= 5) {
          state->attempts = 0;
          ++state->index;
        }
      }
      return;
    }
    if (state->busy)
      return;
    const double duration = player->duration();
    const TestSeams::SeekStep &next = state->script[state->index];
    if (duration <= 0.0 || !player->playing() || player->position() < next.when)
      return;
    const double target = std::min(next.target, duration);
    state->busy = true;
    // Press, three motion previews, release-commit, at a real drag's pacing
    // so the preview lane decodes before the commit lands.
    player->beginScrub();
    player->previewSeekTo(std::max(0.0, target - 0.5));
    QTimer::singleShot(120, player, [player, target] { player->previewSeekTo(std::max(0.0, target - 0.25)); });
    QTimer::singleShot(240, player, [player, target] { player->previewSeekTo(target); });
    QTimer::singleShot(360, player, [player, state, target] {
      player->endScrub(target);
      state->target = target;
      state->issuedMs = state->clock.elapsed();
      state->awaiting = true;
      state->busy = false;
    });
  });
}

// WAM_TEST_CAPTION_OUTPUT: request captions on the first window one second
// in, and report when a live and then a committed cue is stably on screen.
void startCaptionReceipt(PlayerWindow &first, const QString &output) {
  PlayerController *player = first.controller();
  QQuickWindow *window = first.window();
  struct LiveReceipt {
    QElapsedTimer clock;
    bool live = false;
    bool committed = false;
    QString previous;
  };
  auto receipt = std::make_shared<LiveReceipt>();
  QObject::connect(window, &QQuickWindow::frameSwapped, player, [player, window, receipt] {
    if (!receipt->clock.isValid()) return;
    auto *item = window->findChild<QQuickItem *>(QStringLiteral("subtitleText"));
    if (!item || !item->isVisible()) return;
    const auto text = item->property("text").toString();
    const bool stable = !text.isEmpty() && text == receipt->previous;
    receipt->previous = text;
    if (!stable) {
      if (!text.isEmpty()) window->update();
      return;
    }
    if (!receipt->live && player->captionTranscribing() && !player->captionTrackCommitted()) {
      receipt->live = true;
      qInfo() << "caption-screen: live_ms=" << receipt->clock.elapsed() << "position=" << player->position()
              << "text=" << text;
    }
    if (!receipt->committed && player->captionTrackCommitted()) {
      receipt->committed = true;
      qInfo() << "caption-screen: committed_ms=" << receipt->clock.elapsed() << "position=" << player->position()
              << "text=" << text;
    }
  }, Qt::QueuedConnection);
  QObject::connect(player, &PlayerController::subtitleTracksChanged, window, [window] { window->update(); });
  QTimer::singleShot(1000, player, [player, output, receipt] {
    receipt->clock.start();
    qInfo() << "caption-screen: request playing=" << player->playing();
    player->generateCaptionsTo(QUrl::fromLocalFile(output));
  });
  QObject::connect(player, &PlayerController::captionStatusChanged, player,
                   [player] { qInfo().noquote() << "caption-proof:" << player->captionStatus(); });
}

// WAM_TEST_CAPTION_METRICS: the worst UI-thread gap while captions run.
void startCaptionHeartbeat(QGuiApplication &app, PlayerController *player) {
  struct Heartbeat {
    QElapsedTimer clock;
    qint64 last = 0;
    qint64 maximum = 0;
    unsigned samples = 0;
  };
  auto heartbeat = std::make_shared<Heartbeat>();
  heartbeat->clock.start();
  auto *timer = new QTimer(player);
  timer->setInterval(10);
  QObject::connect(timer, &QTimer::timeout, player, [heartbeat] {
    const auto now = heartbeat->clock.elapsed();
    heartbeat->maximum = std::max(heartbeat->maximum, now - heartbeat->last);
    heartbeat->last = now;
    ++heartbeat->samples;
  });
  QObject::connect(&app, &QCoreApplication::aboutToQuit, player, [heartbeat] {
    qInfo() << "caption-heartbeat max_gap_ms=" << heartbeat->maximum << "samples=" << heartbeat->samples;
  });
  timer->start();
}

} // namespace

bool loadTestSeams() {
  if (!NativeBenchmarkTelemetry::instance().enabled())
    return true;
  TestSeams seams;
  seams.background = wamEnvironmentTruth("WAM_TEST_BACKGROUND");
  seams.muted = wamEnvironmentTruth("WAM_TEST_MUTED");
  seams.noVideoHardware = wamEnvironmentTruth("WAM_TEST_NO_VIDEO_HARDWARE");
  seams.geometry = parseGeometry(qgetenv("WAM_TEST_GEOMETRY"));
  seams.allWindowGeometry = wamEnvironmentTruth("WAM_TEST_ALL_WINDOW_GEOMETRY");
  seams.noticeTrace = qEnvironmentVariableIsSet("WAM_TEST_NOTICE_TRACE");
  seams.captionMetrics = qEnvironmentVariableIsSet("WAM_TEST_CAPTION_METRICS");
  seams.captionEngineWhisper = qgetenv("WAM_TEST_CAPTION_ENGINE") == "whisper";
  seams.captionOutput = qEnvironmentVariable("WAM_TEST_CAPTION_OUTPUT");
  seams.capturePhysical = qEnvironmentVariableIntValue("WAM_TEST_CAPTURE_PHYSICAL") == 1;
  seams.openDelayMilliseconds = std::min(qEnvironmentVariableIntValue("WAM_TEST_OPEN_DELAY_MS"), 15000);
  seams.quitAfterMilliseconds = std::max(qEnvironmentVariableIntValue("WAM_TEST_QUIT_AFTER_MS"), 0);
  seams.quitThroughMenu = qEnvironmentVariable("WAM_TEST_QUIT_MODE") == QStringLiteral("menu");
  ScriptParser parser;
  seams.seekScript = parser.seeks("WAM_TEST_SEEK_SCRIPT");
  seams.reopenScript = parser.timed("WAM_TEST_REOPEN_SCRIPT", true);
  seams.windowScript = parser.timed("WAM_TEST_WINDOW_SCRIPT", false);
  for (const TestSeams::TimedStep &step : seams.windowScript)
    if (findVerb(step.text) == nullptr)
      parser.reject("WAM_TEST_WINDOW_SCRIPT", step.text.toUtf8(), "unknown verb");
  if (parser.failed)
    return false;
  storage() = std::move(seams);
  return true;
}

const TestSeams *testSeams() noexcept {
  const std::optional<TestSeams> &seams = storage();
  return seams ? &*seams : nullptr;
}

void armTestSeamsBeforeApplication() {
  const TestSeams *seams = testSeams();
  if (seams == nullptr)
    return;
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  if (seams->noVideoHardware)
    macos::NativeEmbeddingSupport::setTestNoVideoHardware(true);
#endif
  // The Qt cocoa plugin's own guard on the activateIgnoringOtherApps: it
  // performs "to avoid launching behind the terminal" -- the focus steal
  // WAM_TEST_BACKGROUND exists to stop. Only if the environment is silent.
  if (seams->background && !qEnvironmentVariableIsSet("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM"))
    qputenv("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM", "1");
  if (seams->muted)
    macos::NativeEmbeddingSupport::setTestMuted(true);
}

void armTestSeamsAfterApplication() {
  // NSApp exists and no window is shown: the accessory policy costs no
  // visible activation flicker here.
  if (const TestSeams *seams = testSeams(); seams != nullptr && seams->background)
    macos_window_chrome::adoptBackgroundLaunchPolicy();
}

void startTestSeams(QGuiApplication &app, WindowManager &windows, PlayerWindow &first, UrlResolver resolve) {
  const TestSeams *seams = testSeams();
  if (seams == nullptr)
    return;
  PlayerController *player = first.controller();
  if (seams->noticeTrace) {
    const auto reportNotice = [player] {
      const QJsonObject record{{"record", "notice_state"}, {"notice", player->lastNotice()}, {"error", player->lastError()}};
      qInfo().noquote() << QJsonDocument(record).toJson(QJsonDocument::Compact);
    };
    QObject::connect(player, &PlayerController::lastNoticeChanged, player, reportNotice);
    QObject::connect(player, &PlayerController::lastErrorChanged, player, reportNotice);
    reportNotice();
  }
  // The seek and reopen drivers are bound to the FIRST window: they are
  // single-session measurement tools. A reopen replaces that window's media
  // so its lineage is a warm open, with no launch or window startup in it.
  if (!seams->seekScript.empty())
    startSeekScript(player, seams->seekScript);
  if (seams->captionMetrics)
    startCaptionHeartbeat(app, player);
  if (!seams->captionOutput.isEmpty())
    startCaptionReceipt(first, seams->captionOutput);
  schedule(player, seams->reopenScript, [player, resolve](const QString &path) {
    const QUrl target = resolve(path);
    if (target.isValid())
      player->open(target);
  });
  schedule(&windows, seams->windowScript, [&windows, resolve](const QString &verb) {
    const QStringList fields = verb.split(QLatin1Char(':'));
    findVerb(verb)->run(VerbContext{windows, resolve, fields});
  });
  // Orderly quit: telemetry commits its buffered facts at the terminal drain,
  // which only runs when the event loop quits (a signal loses them).
  if (seams->quitAfterMilliseconds > 0) {
    QTimer::singleShot(seams->quitAfterMilliseconds, &app, [&windows, menu = seams->quitThroughMenu] {
      if (menu) {
        if (QObject *item = windows.findChild<QObject *>(QStringLiteral("wamQuitMenuItem"))) {
          QMetaObject::invokeMethod(item, "triggered", Qt::DirectConnection);
          return;
        }
        qFatal("Quit menu item was not found");
      }
      QCoreApplication::quit();
    });
  }
}

} // namespace wam::qt
