#include "qt_metal_video_item.hpp"
#include "native_video_color.hpp"

#import <Metal/Metal.h>

#include <QMatrix4x4>
#include <QMutex>
#include <QMutexLocker>
#include <QQuickWindow>
#include <QSGGeometry>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSGNode>
#include <QSGRendererInterface>
#include <QSGTexture>
#include <QtQuick/qsgtexture_platform.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace wam::macos {
namespace {

constexpr int kMatrixOffset = 0;
constexpr int kOpacityOffset = 64;
constexpr int kRangeOffset = 80;
constexpr int kSitingOffset = 96;
constexpr int kRedOffset = 112;
constexpr int kGreenOffset = 128;
constexpr int kBlueOffset = 144;
constexpr int kUniformBytes = 160;

#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
std::atomic<bool> gFailNextSynchronizationTokenCopy{false};
std::atomic<bool> gFailNextImportTokenCopy{false};
std::atomic<std::uint64_t> gSynchronizationTokenCopyFailures{0};
std::atomic<std::uint64_t> gImportTokenCopyFailures{0};
#endif

struct ColorParameters {
  std::array<float, 4> range{};
  std::array<float, 4> siting{};
  std::array<float, 4> red{};
  std::array<float, 4> green{};
  std::array<float, 4> blue{};
};

std::optional<ColorParameters> colorParameters(CVPixelBufferRef pixelBuffer,
                                               QString* error) {
  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  const bool fullRange =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  const bool tenBit =
      format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;

  ColorParameters result{};
  if (fullRange) {
    if (tenBit) {
      // P010 stores each ten-bit code in the most-significant bits of a
      // 16-bit word. R16Unorm/RG16Unorm therefore normalize code * 64 by
      // 65535, not code by 1023.
      result.range = {0.0F, 65535.0F / (1023.0F * 64.0F),
                      (512.0F * 64.0F) / 65535.0F,
                      65535.0F / (1023.0F * 64.0F)};
    } else {
      result.range = {0.0F, 1.0F, 128.0F / 255.0F, 1.0F};
    }
  } else if (tenBit) {
    result.range = {(64.0F * 64.0F) / 65535.0F,
                    65535.0F / (876.0F * 64.0F),
                    (512.0F * 64.0F) / 65535.0F,
                    65535.0F / (896.0F * 64.0F)};
  } else {
    result.range = {16.0F / 255.0F, 255.0F / 219.0F,
                    128.0F / 255.0F, 255.0F / 224.0F};
  }

  CFTypeRef chromaLocation = CVBufferCopyAttachment(
      pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nullptr);
  const bool centered = chromaLocation != nullptr &&
                        CFEqual(chromaLocation,
                                kCVImageBufferChromaLocation_Center);
  const bool left = chromaLocation == nullptr ||
                    CFEqual(chromaLocation,
                            kCVImageBufferChromaLocation_Left);
  if (chromaLocation != nullptr) {
    CFRelease(chromaLocation);
  }
  if (!centered && !left) {
    if (error != nullptr) {
      *error = QStringLiteral(
          "Qt Metal item supports only absent, left, or center chroma "
          "siting");
    }
    return std::nullopt;
  }
  result.siting = centered
                      ? std::array<float, 4>{0.0F, 0.0F, 0.0F, 0.0F}
                      : std::array<float, 4>{
                            0.5F / static_cast<float>(
                                       CVPixelBufferGetWidth(pixelBuffer)),
                            0.0F, 0.0F, 0.0F};

  // One shared definition with metal_layer_presenter.mm and
  // qt_gl_video_item.mm -- see native_video_color.hpp. The fourth lane is
  // padding for the uniform buffer's float4 alignment and is always zero.
  YCbCrMatrixKind matrixKind = YCbCrMatrixKind::Bt709;
  if (!ycbcrMatrixForPixelBuffer(pixelBuffer, &matrixKind)) {
    if (error != nullptr) {
      *error = QStringLiteral(
          "Qt Metal item supports only absent, BT.601, BT.709, or BT.2020 "
          "YCbCr matrix metadata");
    }
    return std::nullopt;
  }
  const YCbCrMatrixRows rows = ycbcrMatrixRows(matrixKind);
  result.red = {rows.red[0], rows.red[1], rows.red[2], 0.0F};
  result.green = {rows.green[0], rows.green[1], rows.green[2], 0.0F};
  result.blue = {rows.blue[0], rows.blue[1], rows.blue[2], 0.0F};
  return result;
}

QRectF aspectFitRect(const QRectF& bounds, const FrameLease& frame) {
  if (bounds.isEmpty() || frame.width() == 0 || frame.height() == 0) {
    return {};
  }
  const qreal sourceAspect =
      static_cast<qreal>(frame.width()) / static_cast<qreal>(frame.height());
  const qreal destinationAspect = bounds.width() / bounds.height();
  if (sourceAspect > destinationAspect) {
    const qreal height = bounds.width() / sourceAspect;
    return {bounds.x(), bounds.y() + (bounds.height() - height) / 2.0,
            bounds.width(), height};
  }
  const qreal width = bounds.height() * sourceAspect;
  return {bounds.x() + (bounds.width() - width) / 2.0, bounds.y(), width,
          bounds.height()};
}

void copyVector(QByteArray* destination, int offset,
                const std::array<float, 4>& source) {
  std::memcpy(destination->data() + offset, source.data(),
              source.size() * sizeof(float));
}

}  // namespace

struct QtMetalVideoItem::SharedState {
  mutable QMutex mutex;
  // Keep the most recently submitted lease, not merely a one-shot pending
  // value. Qt can destroy and recreate scene-graph nodes while playback is
  // paused (hide/show, releaseResources(), or window migration); the new node
  // must be able to import the last frame without requiring another decode.
  std::optional<FrameLease> latestFrame;
  std::uint64_t latestSubmissionSerial{0};
  std::atomic<std::uint64_t> submittedFrames{0};
  std::atomic<std::uint64_t> importedFrames{0};
  std::atomic<std::uint64_t> destroyedResourceSets{0};
  std::atomic<std::size_t> activeResourceSets{0};
  std::atomic<int> framesInFlight{0};
  std::atomic<OSType> lastPixelFormat{0};
  std::atomic<bool> exactQtMetalDevice{false};
  std::atomic<bool> exactSourceIOSurface{false};
  QString lastError;

  void setError(QString error) {
    QMutexLocker lock(&mutex);
    lastError = std::move(error);
  }
};

namespace {

// QSGMaterial::compare() is process-wide renderer state. A per-node counter
// lets the first frame of two video items compare equal, which allows Qt to
// reuse one item's sampled textures for the other. Give every imported
// resource set a process-global identity instead.
std::atomic<std::uint64_t> gNextResourceSerial{1};

std::uint64_t nextResourceSerial() noexcept {
  // Exhausting 2^64 resource sets is not physically reachable. Reserve zero
  // as the empty-material identity and still defend against wraparound.
  std::uint64_t serial =
      gNextResourceSerial.fetch_add(1, std::memory_order_relaxed);
  if (serial == 0) {
    serial = gNextResourceSerial.fetch_add(1, std::memory_order_relaxed);
  }
  return serial;
}

struct FrameResources {
  FrameResources(MetalFrameLease importedFrame,
                 std::unique_ptr<QSGTexture> lumaTexture,
                 std::unique_ptr<QSGTexture> chromaTexture,
                 ColorParameters conversionParameters,
                 std::shared_ptr<QtMetalVideoItem::SharedState> sharedState,
                 std::uint64_t resourceSerial)
      : frame(std::move(importedFrame)),
        luma(std::move(lumaTexture)),
        chroma(std::move(chromaTexture)),
        color(conversionParameters),
        state(std::move(sharedState)),
        serial(resourceSerial) {
    state->activeResourceSets.fetch_add(1, std::memory_order_relaxed);
  }

  ~FrameResources() {
    state->activeResourceSets.fetch_sub(1, std::memory_order_relaxed);
    state->destroyedResourceSets.fetch_add(1, std::memory_order_relaxed);
  }

  // Declare the CoreVideo/Metal lease before the QSG wrappers so the wrappers
  // are destroyed first and never outlive the native texture views they borrow.
  MetalFrameLease frame;
  std::unique_ptr<QSGTexture> luma;
  std::unique_ptr<QSGTexture> chroma;
  ColorParameters color;
  std::shared_ptr<QtMetalVideoItem::SharedState> state;
  std::uint64_t serial{0};
};

class YuvMaterial;

class YuvShader final : public QSGMaterialShader {
 public:
  YuvShader() {
    setShaderFileName(VertexStage,
                      QStringLiteral(":/wam/native-video/shaders/"
                                     "native_video.vert.qsb"));
    setShaderFileName(FragmentStage,
                      QStringLiteral(":/wam/native-video/shaders/"
                                     "native_video.frag.qsb"));
  }

  bool updateUniformData(RenderState& state, QSGMaterial* newMaterial,
                         QSGMaterial*) override;
  void updateSampledImage(RenderState& state, int binding, QSGTexture** texture,
                          QSGMaterial* newMaterial, QSGMaterial*) override;
};

class YuvMaterial final : public QSGMaterial {
 public:
  explicit YuvMaterial(bool blending) : blending_(blending) {
    setFlag(NoBatching);
    setFlag(RequiresFullMatrix);
    setFlag(Blending, blending);
  }

  QSGMaterialType* type() const override {
    // Pipeline state is cached by material type. The blended and opaque paths
    // must not share a type or Qt may reuse the wrong blend pipeline.
    static QSGMaterialType blendedType;
    static QSGMaterialType opaqueType;
    return blending_ ? &blendedType : &opaqueType;
  }

  QSGMaterialShader* createShader(
      QSGRendererInterface::RenderMode) const override {
    return new YuvShader;
  }

  int compare(const QSGMaterial* other) const override {
    const auto* rhs = static_cast<const YuvMaterial*>(other);
    const std::uint64_t lhsSerial = resources_ ? resources_->serial : 0;
    const std::uint64_t rhsSerial = rhs->resources_ ? rhs->resources_->serial : 0;
    return lhsSerial < rhsSerial ? -1 : lhsSerial > rhsSerial ? 1 : 0;
  }

  void setResources(std::shared_ptr<FrameResources> resources) {
    resources_ = std::move(resources);
  }

  [[nodiscard]] const std::shared_ptr<FrameResources>& resources() const {
    return resources_;
  }

 private:
  bool blending_{false};
  std::shared_ptr<FrameResources> resources_;
};

bool YuvShader::updateUniformData(RenderState& state, QSGMaterial* newMaterial,
                                  QSGMaterial*) {
  QByteArray* uniformData = state.uniformData();
  if (uniformData == nullptr || uniformData->size() < kUniformBytes) {
    return false;
  }
  const auto* material = static_cast<YuvMaterial*>(newMaterial);
  if (!material->resources()) {
    return false;
  }
  const QMatrix4x4 matrix = state.combinedMatrix();
  std::memcpy(uniformData->data() + kMatrixOffset, matrix.constData(),
              16 * sizeof(float));
  const float opacity = state.opacity();
  std::memcpy(uniformData->data() + kOpacityOffset, &opacity, sizeof(opacity));
  const ColorParameters& color = material->resources()->color;
  copyVector(uniformData, kRangeOffset, color.range);
  copyVector(uniformData, kSitingOffset, color.siting);
  copyVector(uniformData, kRedOffset, color.red);
  copyVector(uniformData, kGreenOffset, color.green);
  copyVector(uniformData, kBlueOffset, color.blue);
  return true;
}

void YuvShader::updateSampledImage(RenderState& state, int binding,
                                   QSGTexture** texture,
                                   QSGMaterial* newMaterial, QSGMaterial*) {
  const auto* material = static_cast<YuvMaterial*>(newMaterial);
  if (!material->resources()) {
    *texture = nullptr;
    return;
  }
  QSGTexture* sampledTexture = nullptr;
  if (binding == 1) {
    sampledTexture = material->resources()->luma.get();
  } else if (binding == 2) {
    sampledTexture = material->resources()->chroma.get();
  }
  if (sampledTexture != nullptr) {
    // Native QSG textures may have deferred RHI transitions or uploads. Qt
    // requires custom materials to commit those operations before sampling.
    sampledTexture->commitTextureOperations(state.rhi(),
                                             state.resourceUpdateBatch());
  }
  *texture = sampledTexture;
}

class QtMetalVideoNode final : public QSGGeometryNode {
 public:
  QtMetalVideoNode(QQuickWindow* window,
                   std::shared_ptr<QtMetalVideoItem::SharedState> state)
      : window_(window), state_(std::move(state)) {
    geometry_ = new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(),
                                4);
    geometry_->setDrawingMode(QSGGeometry::DrawTriangleStrip);
    geometry_->setVertexDataPattern(QSGGeometry::DynamicPattern);
    setGeometry(geometry_);
    setFlag(OwnsGeometry);

    material_ = new YuvMaterial(true);
    opaqueMaterial_ = new YuvMaterial(false);
    setMaterial(material_);
    setOpaqueMaterial(opaqueMaterial_);
    setFlag(OwnsMaterial);
    setFlag(OwnsOpaqueMaterial);
    setFlag(UsePreprocess);
    geometry_->setVertexCount(0);
  }

  ~QtMetalVideoNode() override {
    // QSGGeometryNode owns and deletes the materials in its base destructor,
    // after derived members have already been destroyed. Drop their shared
    // FrameResources here so all borrowed QSG/native views and frame-slot
    // leases retire before this node's Metal texture cache.
    material_->setResources({});
    opaqueMaterial_->setResources({});
    slotRetainer_.clear();
    current_.reset();
    textureCache_.reset();
  }

  void preprocess() override {
    if (window_ == nullptr || !current_) {
      return;
    }
    const QQuickWindow::GraphicsStateInfo& info =
        window_->graphicsStateInfo();
    state_->framesInFlight.store(info.framesInFlight,
                                 std::memory_order_relaxed);
    const bool wasSafeToDraw = slotRetainer_.safeToDraw();
    if (!slotRetainer_.retain(info.currentFrameSlot, info.framesInFlight,
                              current_)) {
      updateGeometry();
      state_->setError(QStringLiteral("invalid Qt graphics frame-slot state"));
      return;
    }
    if (!wasSafeToDraw) {
      updateGeometry();
    }
  }

  void setBounds(const QRectF& bounds) {
    bounds_ = bounds;
    updateGeometry();
  }

  [[nodiscard]] bool hasProcessedSubmission(
      std::uint64_t submissionSerial) const noexcept {
    return processedSubmissionSerial_ == submissionSerial ||
           rejectedTokenCopySerial_ == submissionSerial;
  }

  void markSubmissionProcessed(std::uint64_t submissionSerial) noexcept {
    processedSubmissionSerial_ = submissionSerial;
  }

  void markTokenCopyRejected(std::uint64_t submissionSerial) noexcept {
    rejectedTokenCopySerial_ = submissionSerial;
  }

  bool import(FrameLease frame, QString* error, bool* tokenCopyFailed) {
    *tokenCopyFailed = false;
    if (!frame || !frame.isIOSurfaceBacked()) {
      *error = QStringLiteral("Qt Metal item requires an IOSurface frame");
      return false;
    }
    const CVPixelBufferRef sourcePixelBuffer = frame.pixelBuffer();
    FrameLease retainedFrame;
#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
    const bool injectCopyFailure =
        gFailNextImportTokenCopy.exchange(false, std::memory_order_relaxed);
#else
    constexpr bool injectCopyFailure = false;
#endif
    if (!injectCopyFailure) {
      retainedFrame = FrameLease(frame);
    }
    if (!retainedFrame ||
        retainedFrame.pixelBuffer() != sourcePixelBuffer) {
      *tokenCopyFailed = true;
#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
      gImportTokenCopyFailures.fetch_add(1, std::memory_order_relaxed);
#endif
      *error = injectCopyFailure
                   ? QStringLiteral(
                         "injected Qt Metal import accounting-token copy "
                         "failure")
                   : QStringLiteral(
                         "could not clone decoded-surface accounting token "
                         "for Qt Metal import");
      return false;
    }

    auto color = colorParameters(retainedFrame.pixelBuffer(), error);
    if (!color) {
      return false;
    }
    if (window_ == nullptr || window_->rendererInterface() == nullptr ||
        window_->rendererInterface()->graphicsApi() !=
            QSGRendererInterface::Metal) {
      *error = QStringLiteral("Qt Quick is not using its Metal backend");
      return false;
    }

    void* nativeDevice = window_->rendererInterface()->getResource(
        window_, QSGRendererInterface::DeviceResource);
    if (nativeDevice == nullptr) {
      *error = QStringLiteral("Qt did not expose its Metal device");
      return false;
    }
    if (textureCache_ && textureCache_->nativeDevice() != nativeDevice) {
      // Never release a frame-slot ring merely because a different device is
      // observed: the old RHI may still be sampling those textures. Qt must
      // invalidate and recreate this scene-graph node to drain that device.
      *error = QStringLiteral(
          "Qt Metal device changed without scene graph invalidation");
      return false;
    }
    if (!textureCache_) {
      std::string cacheError;
      textureCache_ = MetalTextureCache::create(nativeDevice, &cacheError);
      if (!textureCache_) {
        *error = QString::fromStdString(cacheError);
        return false;
      }
    }

    std::string importError;
    auto imported = textureCache_->importFrame(retainedFrame, &importError);
    if (!imported || imported->planeCount() != 2) {
      if (importError.find("accounting token") != std::string::npos) {
        *tokenCopyFailed = true;
#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
        gImportTokenCopyFailures.fetch_add(1, std::memory_order_relaxed);
#endif
      }
      *error = importError.empty()
                   ? QStringLiteral("Qt Metal item requires a two-plane frame")
                   : QString::fromStdString(importError);
      return false;
    }
    if (imported->frame().pixelBuffer() != sourcePixelBuffer) {
      *tokenCopyFailed = true;
#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
      gImportTokenCopyFailures.fetch_add(1, std::memory_order_relaxed);
#endif
      *error = QStringLiteral(
          "Qt Metal imported frame identity changed during token handoff");
      return false;
    }

    id<MTLDevice> qtDevice = (__bridge id<MTLDevice>)nativeDevice;
    id<MTLTexture> lumaNative =
        (__bridge id<MTLTexture>)imported->nativeTexture(0);
    id<MTLTexture> chromaNative =
        (__bridge id<MTLTexture>)imported->nativeTexture(1);
    if (lumaNative == nil || chromaNative == nil ||
        lumaNative.device != qtDevice || chromaNative.device != qtDevice) {
      *error = QStringLiteral("imported planes do not use Qt's Metal device");
      return false;
    }
    IOSurfaceRef sourceSurface = retainedFrame.ioSurface();
    if (lumaNative.iosurface != sourceSurface ||
        chromaNative.iosurface != sourceSurface ||
        lumaNative.iosurfacePlane != 0 || chromaNative.iosurfacePlane != 1) {
      *error = QStringLiteral("imported planes lost the source IOSurface");
      return false;
    }

    const MetalPlane& lumaPlane = imported->plane(0);
    const MetalPlane& chromaPlane = imported->plane(1);
    constexpr std::size_t kMaximumQtDimension =
        static_cast<std::size_t>(std::numeric_limits<int>::max());
    if (lumaPlane.width > kMaximumQtDimension ||
        lumaPlane.height > kMaximumQtDimension ||
        chromaPlane.width > kMaximumQtDimension ||
        chromaPlane.height > kMaximumQtDimension) {
      *error = QStringLiteral("Metal plane dimensions exceed Qt limits");
      return false;
    }
    std::unique_ptr<QSGTexture> luma(
        QNativeInterface::QSGMetalTexture::fromNative(
            lumaNative, window_,
            QSize(static_cast<int>(lumaPlane.width),
                  static_cast<int>(lumaPlane.height))));
    std::unique_ptr<QSGTexture> chroma(
        QNativeInterface::QSGMetalTexture::fromNative(
            chromaNative, window_,
            QSize(static_cast<int>(chromaPlane.width),
                  static_cast<int>(chromaPlane.height))));
    if (!luma || !chroma) {
      *error = QStringLiteral("Qt failed to wrap native Metal plane textures");
      return false;
    }
    luma->setFiltering(QSGTexture::Linear);
    chroma->setFiltering(QSGTexture::Linear);

    current_ = std::make_shared<FrameResources>(
        std::move(*imported), std::move(luma), std::move(chroma),
        *color, state_, nextResourceSerial());
    material_->setResources(current_);
    opaqueMaterial_->setResources(current_);
    markDirty(DirtyMaterial);
    state_->lastPixelFormat.store(retainedFrame.pixelFormat(),
                                  std::memory_order_relaxed);
    state_->exactQtMetalDevice.store(true, std::memory_order_relaxed);
    state_->exactSourceIOSurface.store(true, std::memory_order_relaxed);
    state_->importedFrames.fetch_add(1, std::memory_order_relaxed);
    updateGeometry();
    return true;
  }

 private:
  void updateGeometry() {
    if (!current_ || !slotRetainer_.safeToDraw()) {
      geometry_->setVertexCount(0);
      markDirty(DirtyGeometry);
      return;
    }
    geometry_->setVertexCount(4);
    QSGGeometry::updateTexturedRectGeometry(
        geometry_, aspectFitRect(bounds_, current_->frame.frame()),
        QRectF(0.0, 0.0, 1.0, 1.0));
    markDirty(DirtyGeometry);
  }

  QQuickWindow* window_{nullptr};
  std::shared_ptr<QtMetalVideoItem::SharedState> state_;
  QSGGeometry* geometry_{nullptr};
  YuvMaterial* material_{nullptr};
  YuvMaterial* opaqueMaterial_{nullptr};
  std::unique_ptr<MetalTextureCache> textureCache_;
  std::shared_ptr<FrameResources> current_;
  QtFrameSlotRetainer slotRetainer_;
  QRectF bounds_;
  std::uint64_t processedSubmissionSerial_{0};
  std::uint64_t rejectedTokenCopySerial_{0};
};

}  // namespace

#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
void failNextQtMetalSynchronizationTokenCopyForTesting() noexcept {
  gFailNextSynchronizationTokenCopy.store(true, std::memory_order_relaxed);
}

void failNextQtMetalImportTokenCopyForTesting() noexcept {
  gFailNextImportTokenCopy.store(true, std::memory_order_relaxed);
}

std::uint64_t qtMetalSynchronizationTokenCopyFailuresForTesting() noexcept {
  return gSynchronizationTokenCopyFailures.load(std::memory_order_relaxed);
}

std::uint64_t qtMetalImportTokenCopyFailuresForTesting() noexcept {
  return gImportTokenCopyFailures.load(std::memory_order_relaxed);
}

std::uint64_t qtMetalNextResourceSerialForTesting() noexcept {
  return gNextResourceSerial.load(std::memory_order_relaxed);
}
#endif

bool QtFrameSlotRetainer::retain(int currentSlot, int framesInFlight,
                                 std::shared_ptr<void> resource) noexcept {
  if (currentSlot < 0 || framesInFlight <= 0 ||
      framesInFlight > kMaximumSlots || currentSlot >= framesInFlight ||
      !resource) {
    safeToDraw_ = false;
    return false;
  }
  // A backend can report a smaller ring after reconfiguration while commands
  // from a former slot are still in flight. Keep those dormant slots until
  // scene-graph teardown instead of releasing borrowed native textures early.
  framesInFlight_ = std::max(framesInFlight_, framesInFlight);
  slots_[currentSlot] = std::move(resource);
  safeToDraw_ = true;
  return true;
}

void QtFrameSlotRetainer::clear() noexcept {
  for (auto& slot : slots_) {
    slot.reset();
  }
  framesInFlight_ = 0;
  safeToDraw_ = false;
}

std::size_t QtFrameSlotRetainer::retainedSlotCount() const noexcept {
  return static_cast<std::size_t>(std::count_if(
      slots_.begin(), slots_.end(),
      [](const std::shared_ptr<void>& resource) { return bool(resource); }));
}

bool QtFrameSlotRetainer::safeToDraw() const noexcept {
  return safeToDraw_;
}

QtMetalVideoItem::QtMetalVideoItem(QQuickItem* parent)
    : QQuickItem(parent), state_(std::make_shared<SharedState>()) {
  setFlag(ItemHasContents, true);
}

QtMetalVideoItem::~QtMetalVideoItem() = default;

void QtMetalVideoItem::submitFrame(FrameLease frame) {
  {
    QMutexLocker lock(&state_->mutex);
    state_->latestFrame = std::move(frame);
    ++state_->latestSubmissionSerial;
    if (state_->latestSubmissionSerial == 0) {
      ++state_->latestSubmissionSerial;
    }
  }
  state_->submittedFrames.fetch_add(1, std::memory_order_relaxed);
  update();
}

QtMetalVideoItemStats QtMetalVideoItem::stats() const {
  QtMetalVideoItemStats result;
  result.submittedFrames =
      state_->submittedFrames.load(std::memory_order_relaxed);
  result.importedFrames =
      state_->importedFrames.load(std::memory_order_relaxed);
  result.destroyedResourceSets =
      state_->destroyedResourceSets.load(std::memory_order_relaxed);
  result.activeResourceSets =
      state_->activeResourceSets.load(std::memory_order_relaxed);
  result.framesInFlight =
      state_->framesInFlight.load(std::memory_order_relaxed);
  result.lastPixelFormat =
      state_->lastPixelFormat.load(std::memory_order_relaxed);
  result.exactQtMetalDevice =
      state_->exactQtMetalDevice.load(std::memory_order_relaxed);
  result.exactSourceIOSurface =
      state_->exactSourceIOSurface.load(std::memory_order_relaxed);
  {
    QMutexLocker lock(&state_->mutex);
    result.lastError = state_->lastError;
  }
  return result;
}

QSGNode* QtMetalVideoItem::updatePaintNode(QSGNode* oldNode,
                                           UpdatePaintNodeData*) {
  auto* node = static_cast<QtMetalVideoNode*>(oldNode);
  std::optional<FrameLease> latest;
  std::uint64_t submissionSerial = 0;
  CVPixelBufferRef submittedPixelBuffer = nullptr;
  bool handoffCopyFailed = false;
  {
    QMutexLocker lock(&state_->mutex);
    submissionSerial = state_->latestSubmissionSerial;
    if (state_->latestFrame &&
        (node == nullptr || !node->hasProcessedSubmission(submissionSerial))) {
      submittedPixelBuffer = state_->latestFrame->pixelBuffer();
#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
      const bool injectCopyFailure =
          gFailNextSynchronizationTokenCopy.exchange(
              false, std::memory_order_relaxed);
#else
      constexpr bool injectCopyFailure = false;
#endif
      FrameLease handoff;
      if (!injectCopyFailure) {
        handoff = FrameLease(*state_->latestFrame);
      }
      if (!handoff || handoff.pixelBuffer() != submittedPixelBuffer) {
        handoffCopyFailed = true;
        // Keep the node's old processed/resource serial and current textures.
        // Removing only this failed mailbox entry also refunds its surface
        // charge without allowing a render-thread retry loop.
        state_->latestFrame.reset();
      } else {
        latest.emplace(std::move(handoff));
      }
    }
  }
  if (handoffCopyFailed) {
#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
    gSynchronizationTokenCopyFailures.fetch_add(1,
                                                 std::memory_order_relaxed);
#endif
    state_->setError(QStringLiteral(
        "Qt Metal scene-graph synchronization could not clone the "
        "decoded-surface accounting token"));
    return oldNode;
  }

  // Constructing a node is allowed only after the newest frame has a complete,
  // identity-checked render-thread lease. Blank items still create no native
  // texture cache or imported resources.
  if (node == nullptr) {
    node = new QtMetalVideoNode(window(), state_);
  }
  node->setBounds(boundingRect());

  if (latest) {
    QString error;
    bool tokenCopyFailed = false;
    if (!node->import(std::move(*latest), &error, &tokenCopyFailed)) {
      if (tokenCopyFailed) {
        node->markTokenCopyRejected(submissionSerial);
        QMutexLocker lock(&state_->mutex);
        if (state_->latestSubmissionSerial == submissionSerial &&
            state_->latestFrame &&
            state_->latestFrame->pixelBuffer() == submittedPixelBuffer) {
          state_->latestFrame.reset();
        }
      } else {
        // Ordinary metadata/device rejection is bounded for this node but a
        // recreated node intentionally retries the retained latest frame.
        node->markSubmissionProcessed(submissionSerial);
      }
      state_->setError(std::move(error));
    } else {
      node->markSubmissionProcessed(submissionSerial);
      state_->setError({});
    }
  }
  return node;
}

}  // namespace wam::macos
