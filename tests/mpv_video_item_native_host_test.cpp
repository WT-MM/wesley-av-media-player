#include "qt/mpv_video_item.hpp"

#if !defined(Q_OS_MACOS)
#error "mpv_video_item_native_host_test is a macOS-only contract gate"
#endif

#include "platform/macos/qt_gl_video_item.hpp"

#include <QGuiApplication>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>

#include <cstdlib>
#include <iostream>
#include <memory>
#include <type_traits>

namespace {

void check(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression
              << '\n';
    std::exit(EXIT_FAILURE);
  }
}

#define WAM_CHECK(expression)                                                \
  check(static_cast<bool>(expression), #expression, __LINE__)

}  // namespace

int main(int argc, char** argv) {
  static_assert(std::is_same_v<
                decltype(std::declval<wam::qt::MpvVideoItem&>()
                             .nativeVideoItem()),
                wam::macos::QtGlVideoItem&>);

  QGuiApplication application(argc, argv);
  static_cast<void>(application);
  QQuickWindow window;
  QQuickWindow secondWindow;
  auto stage = std::make_unique<wam::qt::MpvVideoItem>();
  wam::macos::QtGlVideoItem& native = stage->nativeVideoItem();
  QPointer<wam::macos::QtGlVideoItem> nativeGuard(&native);

  WAM_CHECK(wam::qt::MpvVideoItem::staticMetaObject.indexOfMethod(
                "nativeVideoItem()") == -1);
  WAM_CHECK(wam::qt::MpvVideoItem::staticMetaObject.indexOfProperty(
                "nativeVideoItem") == -1);
  WAM_CHECK(native.parent() == stage.get());
  WAM_CHECK(native.parentItem() == stage.get());
  WAM_CHECK(stage->childItems().size() == 1);
  WAM_CHECK(stage->childItems().front() == &native);
  WAM_CHECK(native.position() == QPointF{});
  WAM_CHECK(native.z() == 0.0);

  stage->setSize(QSizeF(1280.0, 720.0));
  WAM_CHECK(native.position() == QPointF{});
  WAM_CHECK(native.size() == stage->size());

  // Effective visibility is meaningful only inside a Qt Quick visual tree.
  // The window remains unshown, so this exercises parent propagation without
  // creating a native screen surface in the headless gate.
  stage->setParentItem(window.contentItem());
  WAM_CHECK(stage->window() == &window);
  WAM_CHECK(native.window() == &window);
  stage->setVisible(false);
  WAM_CHECK(!stage->isVisible());
  WAM_CHECK(!native.isVisible());
  stage->setVisible(true);
  WAM_CHECK(native.isVisible() == stage->isVisible());
  stage->setParentItem(nullptr);
  WAM_CHECK(stage->window() == nullptr);
  WAM_CHECK(native.window() == nullptr);

  stage->setParentItem(secondWindow.contentItem());
  WAM_CHECK(stage->window() == &secondWindow);
  WAM_CHECK(native.window() == &secondWindow);
  WAM_CHECK(stage->childItems().size() == 1);
  WAM_CHECK(stage->childItems().front() == &native);
  stage->setParentItem(nullptr);

  stage->setParentItem(window.contentItem());
  QQuickItem overlay(window.contentItem());
  const QList<QQuickItem*> siblings = window.contentItem()->childItems();
  WAM_CHECK(siblings.indexOf(stage.get()) < siblings.indexOf(&overlay));
  WAM_CHECK(stage->z() == 0.0);
  WAM_CHECK(overlay.z() == 0.0);
  WAM_CHECK(stage->childItems().size() == 1);
  WAM_CHECK(stage->childItems().front() == &native);

  stage->setParentItem(nullptr);
  stage.reset();
  WAM_CHECK(nativeGuard.isNull());

  std::cout << "mpv video item native host contract passed\n";
  return EXIT_SUCCESS;
}
