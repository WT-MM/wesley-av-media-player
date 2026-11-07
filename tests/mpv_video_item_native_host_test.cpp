#include "qt/mpv_video_item.hpp"

#if !defined(Q_OS_MACOS)
#error "mpv_video_item_native_host_test is a macOS-only contract gate"
#endif

#include "qt/macos/qt_gl_video_item.hpp"

#include <QGuiApplication>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>

#include "support/expect.hpp"

#include <memory>
#include <type_traits>

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

  EXPECT(wam::qt::MpvVideoItem::staticMetaObject.indexOfMethod(
                "nativeVideoItem()") == -1);
  EXPECT(wam::qt::MpvVideoItem::staticMetaObject.indexOfProperty(
                "nativeVideoItem") == -1);
  EXPECT(native.parent() == stage.get());
  EXPECT(native.parentItem() == stage.get());
  REQUIRE(stage->childItems().size() == 1);
  EXPECT(stage->childItems().front() == &native);
  EXPECT(native.position() == QPointF{});
  EXPECT(native.z() == 0.0);

  stage->setSize(QSizeF(1280.0, 720.0));
  EXPECT(native.position() == QPointF{});
  EXPECT(native.size() == stage->size());

  // Effective visibility is meaningful only inside a Qt Quick visual tree.
  // The window remains unshown, so this exercises parent propagation without
  // creating a native screen surface in the headless gate.
  stage->setParentItem(window.contentItem());
  EXPECT(stage->window() == &window);
  EXPECT(native.window() == &window);
  stage->setVisible(false);
  EXPECT(!stage->isVisible());
  EXPECT(!native.isVisible());
  stage->setVisible(true);
  EXPECT(native.isVisible() == stage->isVisible());
  stage->setParentItem(nullptr);
  EXPECT(stage->window() == nullptr);
  EXPECT(native.window() == nullptr);

  stage->setParentItem(secondWindow.contentItem());
  EXPECT(stage->window() == &secondWindow);
  EXPECT(native.window() == &secondWindow);
  REQUIRE(stage->childItems().size() == 1);
  EXPECT(stage->childItems().front() == &native);
  stage->setParentItem(nullptr);

  stage->setParentItem(window.contentItem());
  QQuickItem overlay(window.contentItem());
  const QList<QQuickItem*> siblings = window.contentItem()->childItems();
  EXPECT(siblings.indexOf(stage.get()) < siblings.indexOf(&overlay));
  EXPECT(stage->z() == 0.0);
  EXPECT(overlay.z() == 0.0);
  REQUIRE(stage->childItems().size() == 1);
  EXPECT(stage->childItems().front() == &native);

  stage->setParentItem(nullptr);
  stage.reset();
  EXPECT(nativeGuard.isNull());

  std::cout << "mpv video item native host contract passed\n";
  return failures == 0 ? 0 : 1;
}
