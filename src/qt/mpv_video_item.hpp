#pragma once

#include <QPointer>
#include <QQuickItem>

#include "player_controller.hpp"

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

 signals:
  void controllerChanged();

 protected:
  QSGNode* updatePaintNode(QSGNode* old_node,
                           UpdatePaintNodeData* data) override;

 private:
  QPointer<PlayerController> controller_;
};

// Call once before loading QML. Registers Wam 1.0 names `MpvVideo` and the
// compatibility alias `VideoSurface`.
void registerWamQtTypes();

}  // namespace wam::qt
