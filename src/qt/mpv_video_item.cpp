#include "mpv_video_item.hpp"

#include "mpv_render_context_policy.hpp"
#include "player_controller.hpp"
#include "player_core_p.hpp"

#if defined(Q_OS_MACOS)
#include "platform/macos/qt_gl_video_item.hpp"
#endif

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
                   const QRectF& rect, bool render_requested,
                   bool has_media) {
    if (core_ != core) {
      releaseCore();
      core_ = std::move(core);
    }
    window_ = window;
    rect_ = rect;
    render_requested_ = render_requested;
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
    if (!core_) return;
    // Releasing here keeps mpv's free call in the scene graph's current GL
    // context. Do this before every other early return: native-path revocation
    // and controller render suppression must not leave an invisible libmpv
    // context resident indefinitely.
    if (!retainMpvRenderContextForPass(*core_, render_requested_)) return;
    if (!window_) return;
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
  bool render_requested_ = false;
  bool has_media_ = false;
};

}  // namespace

MpvVideoItem::MpvVideoItem(QQuickItem* parent)
    : QQuickItem(parent)
#if defined(Q_OS_MACOS)
      , native_video_item_(new macos::QtGlVideoItem(this))
#endif
{
  setFlag(ItemHasContents, true);
#if defined(Q_OS_MACOS)
  // A parent's content node is below its zero-z children. Consequently the
  // native frame covers the independently suppressible mpv node, while QML
  // controls declared after this stage remain above the complete subtree.
  native_video_item_->setPosition(QPointF{});
  native_video_item_->setSize(size());
  native_video_item_->setZ(0.0);
#endif
}

MpvVideoItem::~MpvVideoItem() {
  if (controller_) controller_->detachVideoItem(this);
#if defined(Q_OS_MACOS)
  // Destroy the native presenter while this most-derived stage still owns a
  // valid Qt Quick identity. Its QSG node may queue context-bound retirement;
  // no controller/session may borrow the accessor beyond this point.
  delete native_video_item_;
#endif
}

void MpvVideoItem::setController(PlayerController* controller) {
  if (controller_ == controller) return;
  if (controller_) controller_->detachVideoItem(this);
  controller_ = controller;
  if (controller_) controller_->attachVideoItem(this);
  emit controllerChanged();
  update();
}

#if defined(Q_OS_MACOS)
macos::QtGlVideoItem& MpvVideoItem::nativeVideoItem() noexcept {
  return *native_video_item_;
}

void MpvVideoItem::geometryChange(const QRectF& new_geometry,
                                  const QRectF& old_geometry) {
  QQuickItem::geometryChange(new_geometry, old_geometry);
  native_video_item_->setPosition(QPointF{});
  native_video_item_->setSize(new_geometry.size());
}
#endif

QSGNode* MpvVideoItem::updatePaintNode(QSGNode* old_node,
                                       UpdatePaintNodeData*) {
  auto* node = static_cast<MpvRenderNode*>(old_node);
  if (!node) node = new MpvRenderNode;
  PlayerController *controller = controller_.data();
  node->synchronize(controller ? controller->coreForRendering() : nullptr,
                    window(), boundingRect(),
                    controller && controller->needsRenderContext(),
                    controller && controller->hasMedia());
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
