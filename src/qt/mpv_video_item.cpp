#include "mpv_video_item.hpp"

#include "player_controller.hpp"
#include "player_core_p.hpp"

#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QQmlEngine>
#include <QQuickOpenGLUtils>
#include <QQuickWindow>
#include <QSGRenderNode>

#include <mutex>

namespace wam::qt {
namespace {

class MpvRenderNode final : public QSGRenderNode {
 public:
  ~MpvRenderNode() override { releaseCore(); }

  void synchronize(std::shared_ptr<PlayerCore> core, QQuickWindow* window,
                   const QRectF& rect, bool has_media) {
    if (core_ != core) {
      releaseCore();
      core_ = std::move(core);
    }
    window_ = window;
    rect_ = rect;
    has_media_ = has_media;
  }

  QRectF rect() const override { return rect_; }

  RenderingFlags flags() const override {
    // This external node is a strict ordering barrier between the stage's
    // black clear and the QML overlay. Do not claim OpaqueRendering: that
    // permits the scene graph to reorder the stage fill over the video.
    return {};
  }

  StateFlags changedStates() const override {
    // mpv owns GL state for the duration of render(). Tell Qt to restore the
    // two state groups that remain meaningful for render nodes in Qt 6.
    return ViewportState | ScissorState;
  }

  void render(const RenderState*) override {
    if (!core_ || !window_) return;
    if (window_->rendererInterface()->graphicsApi() !=
        QSGRendererInterface::OpenGL)
      return;

    QOpenGLContext* context = QOpenGLContext::currentContext();
    if (!context) return;
    QOpenGLFunctions* gl = context->functions();
    if (!gl) return;

    GLint framebuffer = 0;
    GLint viewport[4] = {0, 0, 0, 0};
    gl->glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer);
    gl->glGetIntegerv(GL_VIEWPORT, viewport);
    if (viewport[0] != 0 || viewport[1] != 0 || viewport[2] <= 0 ||
        viewport[3] <= 0)
      return;

    QQuickOpenGLUtils::resetOpenGLState();
    if (core_->ensureRenderContext()) {
      // Direct rendering to Qt's active target avoids a full-size intermediate
      // texture and composite pass. Default framebuffer coordinates need the
      // vertical flip described by libmpv's render API.
      if (has_media_)
        core_->render(framebuffer, viewport[2], viewport[3], true);
    }
    QQuickOpenGLUtils::resetOpenGLState();
  }

  void releaseResources() override {
    // Qt may reuse this node after scene-graph invalidation. Release the GL
    // context while it is current, but retain the shared mpv client core.
    if (core_) core_->releaseRenderContext();
  }

 private:
  void releaseCore() {
    if (core_) core_->releaseRenderContext();
    core_.reset();
  }

  std::shared_ptr<PlayerCore> core_;
  QQuickWindow* window_ = nullptr;
  QRectF rect_;
  bool has_media_ = false;
};

}  // namespace

MpvVideoItem::MpvVideoItem(QQuickItem* parent) : QQuickItem(parent) {
  setFlag(ItemHasContents, true);
}

MpvVideoItem::~MpvVideoItem() {
  if (controller_) controller_->detachVideoItem(this);
}

void MpvVideoItem::setController(PlayerController* controller) {
  if (controller_ == controller) return;
  if (controller_) controller_->detachVideoItem(this);
  controller_ = controller;
  if (controller_) controller_->attachVideoItem(this);
  emit controllerChanged();
  update();
}

QSGNode* MpvVideoItem::updatePaintNode(QSGNode* old_node,
                                       UpdatePaintNodeData*) {
  auto* node = static_cast<MpvRenderNode*>(old_node);
  if (!node) node = new MpvRenderNode;
  node->synchronize(controller_ ? controller_->coreForRendering() : nullptr,
                    window(), boundingRect(),
                    controller_ && controller_->hasMedia());
  return node;
}

void registerWamQtTypes() {
  static std::once_flag once;
  std::call_once(once, [] {
    qmlRegisterUncreatableType<PlayerController>(
        "Wam", 1, 0, "PlayerController",
        "PlayerController is provided by the WAM application");
    qmlRegisterType<MpvVideoItem>("Wam", 1, 0, "MpvVideo");
    qmlRegisterType<MpvVideoItem>("Wam", 1, 0, "VideoSurface");
  });
}

}  // namespace wam::qt
