#pragma once

#include <QPointer>
#include <QQuickItem>

#include "player_controller.hpp"

#if defined(Q_OS_MACOS)
namespace wam::macos {
class QtGlVideoItem;
}
#endif

namespace wam::qt {

// A full-window, zero-copy scene-graph item. mpv draws inline into Qt Quick's
// active OpenGL render target, so there is no video-sized intermediate FBO or
// additional texture composition pass. QML controls declared after this item
// are composited over the video normally.
class MpvVideoItem : public QQuickItem {
  Q_OBJECT
  Q_PROPERTY(PlayerController* controller READ controller WRITE setController
                 NOTIFY controllerChanged)

 public:
  explicit MpvVideoItem(QQuickItem* parent = nullptr);
  ~MpvVideoItem() override;

  [[nodiscard]] PlayerController* controller() const {
    return controller_.data();
  }
  void setController(PlayerController* controller);

#if defined(Q_OS_MACOS)
  // Non-null C++-only access to the native presenter owned by this stage.
  // This is deliberately neither a Q_PROPERTY nor Q_INVOKABLE: QML owns the
  // stage, while PlayerController passes this borrowed reference only to the
  // native session factory. Borrow and use it only on this item's GUI thread;
  // it is invalid as soon as stage destruction begins.
  [[nodiscard]] macos::QtGlVideoItem& nativeVideoItem() noexcept;
#endif

 signals:
  void controllerChanged();

 protected:
  QSGNode* updatePaintNode(QSGNode* old_node,
                           UpdatePaintNodeData* data) override;
#if defined(Q_OS_MACOS)
  void geometryChange(const QRectF& new_geometry,
                      const QRectF& old_geometry) override;
#endif

 private:
  QPointer<PlayerController> controller_;
#if defined(Q_OS_MACOS)
  // The visual/QObject parent and exclusive owner are this stage. Qt
  // propagates effective visibility and window changes without a second
  // lifecycle bridge. The stage destructor deletes it before QQuickItem's
  // base teardown so no native session can outlive the C++ accessor contract.
  macos::QtGlVideoItem* const native_video_item_;
#endif
};

// Call once before loading QML. Registers Wam 1.0 names `MpvVideo` and the
// compatibility alias `VideoSurface`.
void registerWamQtTypes();

}  // namespace wam::qt
