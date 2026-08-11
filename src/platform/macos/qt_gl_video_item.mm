#include "qt_gl_video_item.hpp"

#import <OpenGL/CGLIOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>

#include <QMatrix4x4>
#include <QMutex>
#include <QMutexLocker>
#include <QQuickWindow>
#include <QSGRenderNode>
#include <QSGRendererInterface>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace wam::macos {
namespace {

constexpr std::size_t kSlotCount = 2;

struct ColorParameters {
  std::array<GLfloat, 4> range{};
  std::array<GLfloat, 3> red{};
  std::array<GLfloat, 3> green{};
  std::array<GLfloat, 3> blue{};
  GLfloat chromaOffsetX{0.0F};
};

struct GlCounters {
  std::atomic<std::uint64_t> submittedFrames{0};
  std::atomic<std::uint64_t> importedFrames{0};
  std::atomic<std::uint64_t> renderedFrames{0};
  std::atomic<std::uint64_t> lastRenderedGeneration{0};
  std::atomic<std::uint64_t> fatalErrorSerial{0};
  std::atomic<std::uint64_t> backpressuredImports{0};
  std::atomic<std::uint64_t> rejectedFrames{0};
  std::atomic<std::uint64_t> staleFrames{0};
  std::atomic<std::uint64_t> destroyedResourceSets{0};
  std::atomic<std::size_t> activeResourceSets{0};
  std::atomic<std::size_t> peakActiveResourceSets{0};
  std::atomic<std::size_t> pendingRetirements{0};
  std::atomic<OSType> lastPixelFormat{0};
  std::atomic<bool> exactSourceIOSurface{false};
  std::atomic<bool> textureRectangleSupported{false};
  std::atomic<bool> textureRgSupported{false};
  std::atomic<bool> acceleratedContext{false};
  std::atomic<bool> renderedIntoNonDefaultFramebuffer{false};
  std::atomic<bool> sawScissorClip{false};
  std::atomic<bool> sawStencilClip{false};
  std::atomic<bool> retirementFailed{false};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::atomic<bool> holdRetirements{false};
#endif
  mutable QMutex errorMutex;
  QString lastError;
  std::optional<QString> fatalError;

  void setError(QString error) {
    QMutexLocker lock(&errorMutex);
    lastError = std::move(error);
  }

  void latchFatalError(QString error) {
    QMutexLocker lock(&errorMutex);
    lastError = error;
    if (fatalError) {
      return;
    }
    fatalError.emplace(std::move(error));
    std::uint64_t observed = fatalErrorSerial.load(std::memory_order_relaxed);
    while (observed != std::numeric_limits<std::uint64_t>::max() &&
           !fatalErrorSerial.compare_exchange_weak(
               observed, observed + 1, std::memory_order_release,
               std::memory_order_relaxed)) {
    }
  }

  [[nodiscard]] std::optional<QString> takeFatalError() {
    QMutexLocker lock(&errorMutex);
    std::optional<QString> result = std::move(fatalError);
    fatalError.reset();
    return result;
  }
};

void updatePeak(std::atomic<std::size_t>& peak, std::size_t value) noexcept {
  std::size_t observed = peak.load(std::memory_order_relaxed);
  while (observed < value &&
         !peak.compare_exchange_weak(observed, value,
                                     std::memory_order_relaxed)) {
  }
}

void updateRenderedGeneration(
    std::atomic<std::uint64_t>& lastRenderedGeneration,
    std::uint64_t generation) noexcept {
  std::uint64_t observed =
      lastRenderedGeneration.load(std::memory_order_relaxed);
  while (observed < generation &&
         !lastRenderedGeneration.compare_exchange_weak(
             observed, generation, std::memory_order_release,
             std::memory_order_relaxed)) {
  }
}

std::optional<ColorParameters> colorParameters(CVPixelBufferRef pixelBuffer,
                                               QString* error) {
  if (pixelBuffer == nullptr) {
    *error = QStringLiteral("Qt OpenGL item received no pixel buffer");
    return std::nullopt;
  }
  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  const bool eightBit =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  const bool tenBit =
      format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  if (!eightBit && !tenBit) {
    *error = QStringLiteral("Qt OpenGL item requires NV12 or P010");
    return std::nullopt;
  }
  const bool fullRange =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;

  ColorParameters result;
  if (fullRange && tenBit) {
    result.range = {0.0F, 65535.0F / (1023.0F * 64.0F),
                    (512.0F * 64.0F) / 65535.0F,
                    65535.0F / (1023.0F * 64.0F)};
  } else if (fullRange) {
    result.range = {0.0F, 1.0F, 128.0F / 255.0F, 1.0F};
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
                    CFEqual(chromaLocation, kCVImageBufferChromaLocation_Left);
  if (chromaLocation != nullptr) {
    CFRelease(chromaLocation);
  }
  if (!centered && !left) {
    *error = QStringLiteral(
        "Qt OpenGL item supports only absent, left, or center chroma siting");
    return std::nullopt;
  }
  // GL_TEXTURE_RECTANGLE uses texel coordinates. Relative to centered 4:2:0
  // chroma, left siting shifts the sample by one quarter chroma texel.
  result.chromaOffsetX = left ? 0.25F : 0.0F;

  CFTypeRef matrix = CVBufferCopyAttachment(
      pixelBuffer, kCVImageBufferYCbCrMatrixKey, nullptr);
  const bool is601 = matrix != nullptr &&
                     CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4);
  const bool is709 = matrix != nullptr &&
                     CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  const bool inferMatrix = matrix == nullptr;
  if (matrix != nullptr) {
    CFRelease(matrix);
  }
  if (!inferMatrix && !is601 && !is709) {
    *error = QStringLiteral(
        "Qt OpenGL item supports only absent, BT.601, or BT.709 YCbCr "
        "matrix metadata");
    return std::nullopt;
  }
  const bool use601 = is601 ||
                      (inferMatrix && CVPixelBufferGetWidth(pixelBuffer) <= 1024 &&
                       CVPixelBufferGetHeight(pixelBuffer) <= 576);
  if (use601) {
    result.red = {1.0F, 0.0F, 1.4020F};
    result.green = {1.0F, -0.344136F, -0.714136F};
    result.blue = {1.0F, 1.7720F, 0.0F};
  } else {
    result.red = {1.0F, 0.0F, 1.5748F};
    result.green = {1.0F, -0.187324F, -0.468124F};
    result.blue = {1.0F, 1.8556F, 0.0F};
  }
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

void drainGlErrors() noexcept {
  while (glGetError() != GL_NO_ERROR) {
  }
}

bool deleteVertexArrayInExactOrigin(GLuint* vertexArray,
                                    CGLContextObj originContext,
                                    CGLContextObj currentContext) noexcept {
  if (vertexArray == nullptr || *vertexArray == 0) {
    return true;
  }
  if (originContext != nullptr && originContext == currentContext) {
    glDeleteVertexArrays(1, vertexArray);
    *vertexArray = 0;
    return true;
  }
  // VAOs are not share-group objects. Never issue a delete for an old name in
  // another context: the same GLuint may identify an unrelated Qt VAO there.
  // Dropping the numeric handle is safe because teardown of the exact origin
  // context owns its remaining context-local names.
  *vertexArray = 0;
  return false;
}

struct RetiredSlot {
  std::array<GLuint, 2> textures{};
  GLsync fence{nullptr};
  FrameLease frame;
  bool initialized{false};
};

struct RetirementJob {
  std::array<RetiredSlot, kSlotCount> retiredSlots;
  GLuint program{0};
  std::shared_ptr<GlCounters> counters;
  std::size_t initializedSlotCount{0};
  bool permanentlyUnsafe{false};
};

std::atomic<std::size_t> gQuarantinedRetirementJobs{0};

void quarantineRetirementJob(RetirementJob job) {
  // An initialized bundle without its exact share-group retirement context is
  // an invariant violation. Keep every texture name and FrameLease alive for
  // the process instead of returning an IOSurface to VideoToolbox while the
  // GPU may still reference it.
  static auto* mutex = new std::mutex;
  static auto* quarantined = new std::vector<RetirementJob>;
  std::lock_guard lock(*mutex);
  quarantined->push_back(std::move(job));
  gQuarantinedRetirementJobs.fetch_add(1, std::memory_order_relaxed);
}

class RetirementService final {
 public:
  static std::shared_ptr<RetirementService> create(CGLContextObj source,
                                                   QString* error) {
    if (source == nullptr || CGLGetPixelFormat(source) == nullptr) {
      *error = QStringLiteral("Qt did not expose a usable CGL context");
      return {};
    }
    CGLContextObj retirementContext = nullptr;
    const CGLError status = CGLCreateContext(CGLGetPixelFormat(source), source,
                                             &retirementContext);
    if (status != kCGLNoError || retirementContext == nullptr) {
      *error = QStringLiteral("failed to create a shared CGL retirement context: %1")
                   .arg(QString::fromLatin1(CGLErrorString(status)));
      return {};
    }
    return std::shared_ptr<RetirementService>(
        new RetirementService(CGLGetShareGroup(source), retirementContext));
  }

  RetirementService(const RetirementService&) = delete;
  RetirementService& operator=(const RetirementService&) = delete;

  ~RetirementService() {
    {
      std::lock_guard lock(mutex_);
      stopping_ = true;
      ++revision_;
    }
    condition_.notify_one();
    if (worker_.joinable()) {
      worker_.join();
    }
    if (context_ != nullptr) {
      CGLDestroyContext(context_);
    }
  }

  [[nodiscard]] CGLShareGroupObj shareGroup() const noexcept {
    return shareGroup_;
  }

  void retire(RetirementJob job) {
    if (job.counters) {
      job.counters->pendingRetirements.fetch_add(1,
                                                 std::memory_order_relaxed);
    }
    {
      std::lock_guard lock(mutex_);
      jobs_.push_back(std::move(job));
      ++revision_;
    }
    condition_.notify_one();
  }

  void wake() {
    {
      std::lock_guard lock(mutex_);
      ++revision_;
    }
    condition_.notify_one();
  }

  bool waitUntilReady(QString* error) {
    std::unique_lock lock(mutex_);
    if (!condition_.wait_for(lock, std::chrono::milliseconds(500),
                             [this] { return startupFinished_; })) {
      *error = QStringLiteral(
          "shared CGL retirement context startup timed out");
      return false;
    }
    if (!startupSucceeded_) {
      *error = QStringLiteral(
          "shared CGL retirement context could not become current");
    }
    return startupSucceeded_;
  }

 private:
  RetirementService(CGLShareGroupObj shareGroup, CGLContextObj context)
      : shareGroup_(shareGroup), context_(context),
        worker_([this] { run(); }) {}

  static bool jobHeldForTesting(const RetirementJob& job) noexcept {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    return job.counters &&
           job.counters->holdRetirements.load(std::memory_order_relaxed);
#else
    Q_UNUSED(job);
    return false;
#endif
  }

  bool readyToDestroy(RetirementJob& job) {
    if (job.permanentlyUnsafe || jobHeldForTesting(job)) {
      return false;
    }
    for (RetiredSlot& slot : job.retiredSlots) {
      if (slot.fence == nullptr) {
        continue;
      }
      const GLenum status = glClientWaitSync(slot.fence, 0, 0);
      if (status == GL_WAIT_FAILED) {
        job.permanentlyUnsafe = true;
        if (job.counters) {
          job.counters->retirementFailed.store(true,
                                                std::memory_order_relaxed);
          job.counters->latchFatalError(QStringLiteral(
              "shared CGL retirement fence failed; resources retained "
              "fail-closed"));
        }
        return false;
      }
      if (status != GL_ALREADY_SIGNALED &&
          status != GL_CONDITION_SATISFIED) {
        return false;
      }
    }
    return true;
  }

  static void destroyJob(RetirementJob& job) {
    for (RetiredSlot& slot : job.retiredSlots) {
      if (slot.fence != nullptr) {
        glDeleteSync(slot.fence);
        slot.fence = nullptr;
      }
      if (slot.initialized) {
        glDeleteTextures(static_cast<GLsizei>(slot.textures.size()),
                         slot.textures.data());
        slot.textures = {};
        slot.initialized = false;
      }
      slot.frame.reset();
    }
    if (job.program != 0) {
      glDeleteProgram(job.program);
      job.program = 0;
    }
    if (job.counters) {
      job.counters->activeResourceSets.fetch_sub(
          job.initializedSlotCount, std::memory_order_relaxed);
      job.counters->destroyedResourceSets.fetch_add(
          job.initializedSlotCount, std::memory_order_relaxed);
      job.counters->pendingRetirements.fetch_sub(1,
                                                 std::memory_order_relaxed);
    }
  }

  void run() {
    if (CGLSetCurrentContext(context_) != kCGLNoError) {
      {
        std::lock_guard lock(mutex_);
        startupFinished_ = true;
        startupSucceeded_ = false;
      }
      condition_.notify_all();
      return;
    }

    {
      std::lock_guard lock(mutex_);
      startupFinished_ = true;
      startupSucceeded_ = true;
    }
    condition_.notify_all();

    std::unique_lock lock(mutex_);
    while (!stopping_) {
      condition_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
      if (stopping_) {
        break;
      }
      bool madeProgress = false;
      for (auto iterator = jobs_.begin(); iterator != jobs_.end();) {
        if (readyToDestroy(*iterator)) {
          destroyJob(*iterator);
          iterator = jobs_.erase(iterator);
          madeProgress = true;
        } else {
          ++iterator;
        }
      }
      if (!jobs_.empty() && !stopping_) {
        const bool hasPollableJob = std::any_of(
            jobs_.begin(), jobs_.end(), [](const RetirementJob& job) {
              return !job.permanentlyUnsafe && !jobHeldForTesting(job);
            });
        const std::uint64_t observedRevision = revision_;
        if (hasPollableJob) {
          condition_.wait_for(
              lock, std::chrono::milliseconds(madeProgress ? 1 : 4),
              [this, observedRevision] {
                return stopping_ || revision_ != observedRevision;
              });
        } else {
          condition_.wait(lock, [this, observedRevision] {
            return stopping_ || revision_ != observedRevision;
          });
        }
      }
    }
    CGLSetCurrentContext(nullptr);
  }

  CGLShareGroupObj shareGroup_{nullptr};
  CGLContextObj context_{nullptr};
  std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<RetirementJob> jobs_;
  std::uint64_t revision_{0};
  bool stopping_{false};
  bool startupFinished_{false};
  bool startupSucceeded_{false};
  std::thread worker_;
};

void quarantineRetirementService(std::shared_ptr<RetirementService> service) {
  // A worker stuck inside platform context startup must not make the render
  // thread block again through std::thread::join. Preserve it for process
  // lifetime; it owns no decoded frame jobs because readiness is required
  // before the first import.
  static auto* mutex = new std::mutex;
  static auto* quarantined =
      new std::vector<std::shared_ptr<RetirementService>>;
  std::lock_guard lock(*mutex);
  quarantined->push_back(std::move(service));
}

class RetirementRegistry final {
 public:
  std::shared_ptr<RetirementService> serviceFor(CGLContextObj source,
                                                QString* error) {
    if (source == nullptr) {
      *error = QStringLiteral("no current CGL context");
      return {};
    }
    CGLShareGroupObj shareGroup = CGLGetShareGroup(source);
    if (shareGroup == nullptr) {
      *error = QStringLiteral("Qt's CGL context has no share group");
      return {};
    }
    std::lock_guard lock(mutex_);
    const auto found = services_.find(shareGroup);
    if (found != services_.end()) {
      return found->second;
    }
    auto service = RetirementService::create(source, error);
    if (service && service->waitUntilReady(error)) {
      services_.emplace(shareGroup, service);
    } else if (service) {
      quarantineRetirementService(service);
      service.reset();
    }
    return service;
  }

  void wakeAll() {
    std::lock_guard lock(mutex_);
    for (const auto& entry : services_) {
      entry.second->wake();
    }
  }

 private:
  std::mutex mutex_;
  std::unordered_map<CGLShareGroupObj, std::shared_ptr<RetirementService>>
      services_;
};

RetirementRegistry& retirementRegistry() {
  // The registry intentionally outlives QGuiApplication. Its worker contexts
  // keep old share groups alive until every submitted fence has retired; a Qt
  // window/context teardown can therefore never force a GUI-thread wait.
  static auto* registry = new RetirementRegistry;
  return *registry;
}

class RawGlState final {
 public:
  RawGlState() {
    glGetIntegerv(GL_CURRENT_PROGRAM, &program_);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertexArray_);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture_);
    for (std::size_t index = 0; index < textureBindings_.size(); ++index) {
      glActiveTexture(static_cast<GLenum>(GL_TEXTURE0 + index));
      glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &textureBindings_[index]);
      glGetIntegeri_v(GL_SAMPLER_BINDING, static_cast<GLuint>(index),
                      &samplerBindings_[index]);
    }
    glActiveTexture(static_cast<GLenum>(activeTexture_));

    blendEnabled_ = glIsEnabled(GL_BLEND);
    cullEnabled_ = glIsEnabled(GL_CULL_FACE);
    depthEnabled_ = glIsEnabled(GL_DEPTH_TEST);
    scissorEnabled_ = glIsEnabled(GL_SCISSOR_TEST);
    stencilEnabled_ = glIsEnabled(GL_STENCIL_TEST);
    rasterizerDiscardEnabled_ = glIsEnabled(GL_RASTERIZER_DISCARD);
    glGetBooleanv(GL_COLOR_WRITEMASK, colorMask_.data());
    glGetIntegerv(GL_SCISSOR_BOX, scissorBox_.data());
    glGetIntegerv(GL_BLEND_SRC_RGB, &blendSourceRgb_);
    glGetIntegerv(GL_BLEND_DST_RGB, &blendDestinationRgb_);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, &blendSourceAlpha_);
    glGetIntegerv(GL_BLEND_DST_ALPHA, &blendDestinationAlpha_);
    glGetIntegerv(GL_BLEND_EQUATION_RGB, &blendEquationRgb_);
    glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &blendEquationAlpha_);
    captureStencil(GL_FRONT, frontStencil_);
    captureStencil(GL_BACK, backStencil_);
  }

  RawGlState(const RawGlState&) = delete;
  RawGlState& operator=(const RawGlState&) = delete;

  ~RawGlState() {
    glUseProgram(static_cast<GLuint>(program_));
    glBindVertexArray(static_cast<GLuint>(vertexArray_));
    for (std::size_t index = 0; index < textureBindings_.size(); ++index) {
      glActiveTexture(static_cast<GLenum>(GL_TEXTURE0 + index));
      glBindTexture(GL_TEXTURE_RECTANGLE,
                    static_cast<GLuint>(textureBindings_[index]));
      glBindSampler(static_cast<GLuint>(index),
                    static_cast<GLuint>(samplerBindings_[index]));
    }
    glActiveTexture(static_cast<GLenum>(activeTexture_));
    restoreEnabled(GL_BLEND, blendEnabled_);
    restoreEnabled(GL_CULL_FACE, cullEnabled_);
    restoreEnabled(GL_DEPTH_TEST, depthEnabled_);
    restoreEnabled(GL_SCISSOR_TEST, scissorEnabled_);
    restoreEnabled(GL_STENCIL_TEST, stencilEnabled_);
    restoreEnabled(GL_RASTERIZER_DISCARD, rasterizerDiscardEnabled_);
    glColorMask(colorMask_[0], colorMask_[1], colorMask_[2], colorMask_[3]);
    glScissor(scissorBox_[0], scissorBox_[1], scissorBox_[2], scissorBox_[3]);
    glBlendFuncSeparate(static_cast<GLenum>(blendSourceRgb_),
                        static_cast<GLenum>(blendDestinationRgb_),
                        static_cast<GLenum>(blendSourceAlpha_),
                        static_cast<GLenum>(blendDestinationAlpha_));
    glBlendEquationSeparate(static_cast<GLenum>(blendEquationRgb_),
                            static_cast<GLenum>(blendEquationAlpha_));
    restoreStencil(GL_FRONT, frontStencil_);
    restoreStencil(GL_BACK, backStencil_);
  }

 private:
  struct StencilState {
    GLint function{GL_ALWAYS};
    GLint reference{0};
    GLint valueMask{-1};
    GLint writeMask{-1};
    GLint stencilFail{GL_KEEP};
    GLint depthFail{GL_KEEP};
    GLint depthPass{GL_KEEP};
  };

  static void captureStencil(GLenum face, StencilState& state) {
    const bool front = face == GL_FRONT;
    glGetIntegerv(front ? GL_STENCIL_FUNC : GL_STENCIL_BACK_FUNC,
                  &state.function);
    glGetIntegerv(front ? GL_STENCIL_REF : GL_STENCIL_BACK_REF,
                  &state.reference);
    glGetIntegerv(front ? GL_STENCIL_VALUE_MASK : GL_STENCIL_BACK_VALUE_MASK,
                  &state.valueMask);
    glGetIntegerv(front ? GL_STENCIL_WRITEMASK : GL_STENCIL_BACK_WRITEMASK,
                  &state.writeMask);
    glGetIntegerv(front ? GL_STENCIL_FAIL : GL_STENCIL_BACK_FAIL,
                  &state.stencilFail);
    glGetIntegerv(front ? GL_STENCIL_PASS_DEPTH_FAIL
                        : GL_STENCIL_BACK_PASS_DEPTH_FAIL,
                  &state.depthFail);
    glGetIntegerv(front ? GL_STENCIL_PASS_DEPTH_PASS
                        : GL_STENCIL_BACK_PASS_DEPTH_PASS,
                  &state.depthPass);
  }

  static void restoreStencil(GLenum face, const StencilState& state) {
    glStencilFuncSeparate(face, static_cast<GLenum>(state.function),
                          state.reference,
                          static_cast<GLuint>(state.valueMask));
    glStencilMaskSeparate(face, static_cast<GLuint>(state.writeMask));
    glStencilOpSeparate(face, static_cast<GLenum>(state.stencilFail),
                        static_cast<GLenum>(state.depthFail),
                        static_cast<GLenum>(state.depthPass));
  }

  static void restoreEnabled(GLenum capability, GLboolean enabled) {
    if (enabled == GL_TRUE) {
      glEnable(capability);
    } else {
      glDisable(capability);
    }
  }

  GLint program_{0};
  GLint vertexArray_{0};
  GLint activeTexture_{GL_TEXTURE0};
  std::array<GLint, 2> textureBindings_{};
  std::array<GLint, 2> samplerBindings_{};
  GLboolean blendEnabled_{GL_FALSE};
  GLboolean cullEnabled_{GL_FALSE};
  GLboolean depthEnabled_{GL_FALSE};
  GLboolean scissorEnabled_{GL_FALSE};
  GLboolean stencilEnabled_{GL_FALSE};
  GLboolean rasterizerDiscardEnabled_{GL_FALSE};
  std::array<GLboolean, 4> colorMask_{};
  std::array<GLint, 4> scissorBox_{};
  GLint blendSourceRgb_{GL_ONE};
  GLint blendDestinationRgb_{GL_ZERO};
  GLint blendSourceAlpha_{GL_ONE};
  GLint blendDestinationAlpha_{GL_ZERO};
  GLint blendEquationRgb_{GL_FUNC_ADD};
  GLint blendEquationAlpha_{GL_FUNC_ADD};
  StencilState frontStencil_;
  StencilState backStencil_;
};

GLuint compileShader(GLenum type, const char* source, QString* error) {
  const GLuint shader = glCreateShader(type);
  if (shader == 0) {
    *error = QStringLiteral("failed to allocate OpenGL shader");
    return 0;
  }
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);
  GLint compiled = GL_FALSE;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
  if (compiled == GL_TRUE) {
    return shader;
  }
  GLint length = 0;
  glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
  std::string log(static_cast<std::size_t>(std::max(length, 1)), '\0');
  glGetShaderInfoLog(shader, length, nullptr, log.data());
  glDeleteShader(shader);
  *error = QStringLiteral("OpenGL shader compilation failed: %1")
               .arg(QString::fromStdString(log));
  return 0;
}

constexpr const char* kVertexShader = R"GLSL(#version 150 core
uniform mat4 uMvp;
uniform vec4 uRect;
uniform vec2 uLumaSize;
out vec2 vLumaCoordinate;
void main() {
  vec2 corner;
  if (gl_VertexID == 0) corner = vec2(0.0, 0.0);
  else if (gl_VertexID == 1) corner = vec2(0.0, 1.0);
  else if (gl_VertexID == 2) corner = vec2(1.0, 0.0);
  else corner = vec2(1.0, 1.0);
  vec2 position = uRect.xy + corner * uRect.zw;
  gl_Position = uMvp * vec4(position, 0.0, 1.0);
  vLumaCoordinate = corner * uLumaSize;
}
)GLSL";

constexpr const char* kFragmentShader = R"GLSL(#version 150 core
uniform sampler2DRect uLuma;
uniform sampler2DRect uChroma;
uniform vec4 uRange;
uniform vec3 uRed;
uniform vec3 uGreen;
uniform vec3 uBlue;
uniform float uChromaOffsetX;
uniform float uOpacity;
in vec2 vLumaCoordinate;
out vec4 fragmentColor;
void main() {
  float y = (texture(uLuma, vLumaCoordinate).r - uRange.x) * uRange.y;
  vec2 chromaCoordinate = vLumaCoordinate * 0.5 +
                          vec2(uChromaOffsetX, 0.0);
  vec2 chroma = (texture(uChroma, chromaCoordinate).rg -
                 vec2(uRange.z)) * uRange.w;
  vec3 yuv = vec3(y, chroma.x, chroma.y);
  vec3 rgb = clamp(vec3(dot(uRed, yuv), dot(uGreen, yuv),
                        dot(uBlue, yuv)), 0.0, 1.0);
  fragmentColor = vec4(rgb * uOpacity, uOpacity);
}
)GLSL";

}  // namespace

struct QtGlVideoItem::SharedState {
  mutable QMutex mutex;
  std::optional<FrameLease> latestFrame;
  std::uint64_t acceptedGeneration{0};
  bool generationOpen{true};
  std::uint64_t timelineSerial{0};
  std::shared_ptr<GlCounters> counters{std::make_shared<GlCounters>()};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::atomic<bool> failNextImport{false};
  std::atomic<bool> failSecondPlaneImport{false};
  std::atomic<bool> failAfterRetirementServiceCreation{false};
  std::atomic<bool> strandRetirementService{false};
#endif
};

namespace {

class QtGlVideoNode final : public QSGRenderNode {
 public:
  explicit QtGlVideoNode(std::shared_ptr<QtGlVideoItem::SharedState> state)
      : state_(std::move(state)), counters_(state_->counters) {}

  ~QtGlVideoNode() override { retireAll(); }

  void synchronize(QQuickWindow* window, const QRectF& bounds,
                   std::optional<FrameLease> latestFrame,
                   std::uint64_t timelineSerial,
                   std::uint64_t acceptedGeneration) {
    window_ = window;
    bounds_ = bounds;
    synchronizedFrame_ = std::move(latestFrame);
    synchronizedSerial_ = timelineSerial;
    synchronizedGeneration_ = acceptedGeneration;
  }

  QRectF rect() const override { return bounds_; }

  RenderingFlags flags() const override {
    return BoundedRectRendering;
  }

  StateFlags changedStates() const override {
    return DepthState | StencilState | ScissorState | ColorState |
           BlendState | CullState;
  }

  void releaseResources() override {
    retireAll();
    fatalFailure_ = false;
  }

  void render(const RenderState* renderState) override {
    if (fatalFailure_) {
      return;
    }
    if (window_ == nullptr || renderState == nullptr ||
        window_->rendererInterface() == nullptr ||
        window_->rendererInterface()->graphicsApi() !=
            QSGRendererInterface::OpenGL) {
      fatalFailure_ = true;
      counters_->latchFatalError(
          QStringLiteral("Qt Quick is not using a current OpenGL context"));
      return;
    }

    CGLContextObj cglContext = CGLGetCurrentContext();
    if (cglContext == nullptr) {
      fatalFailure_ = true;
      counters_->latchFatalError(
          QStringLiteral("Qt did not make a CGL context current"));
      return;
    }
    DeferredRetirementGuard retirementGuard(this);
    std::optional<RawGlState> savedState;

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (state_->strandRetirementService.exchange(false,
                                                  std::memory_order_relaxed)) {
      savedState.emplace();
      service_.reset();
      deferredRetirement_ = true;
      fatalFailure_ = true;
      return;
    }
#endif
    if (counters_->retirementFailed.load(std::memory_order_relaxed)) {
      fatalFailure_ = true;
      return;
    }

    if (synchronizedGeneration_ != displayedGeneration_) {
      // A seek/load generation boundary suppresses the old frame before any
      // attempt to import the new one. In particular, retirement
      // backpressure can never make an old-timeline slot visible again.
      if (program_ != 0 || vertexArray_ != 0 || currentSlot_) {
        savedState.emplace();
      }
      deferredRetirement_ = true;
      currentSlot_.reset();
      displayedGeneration_ = synchronizedGeneration_;
      if (synchronizedFrame_) {
        requestAnotherFrame();
      }
      return;
    }

    if (synchronizedSerial_ != processedTimelineSerial_ &&
        !synchronizedFrame_) {
      // A generation flush must not leave the prior frame visible. Queue all
      // resources behind their already-flushed fences and begin with a clean
      // two-slot ring after retirement completes.
      if (program_ != 0 || vertexArray_ != 0 || currentSlot_) {
        savedState.emplace();
      }
      deferredRetirement_ = true;
      processedTimelineSerial_ = synchronizedSerial_;
      currentSlot_.reset();
      return;
    }

    // A blank/idle player allocates no CGL context, worker thread, shader,
    // VAO, or texture names. This is the common startup path and must remain
    // as lean as the shipping libmpv-lazy shell.
    if (!synchronizedFrame_ && !currentSlot_) {
      return;
    }

    savedState.emplace();

    QString error;
    bool retry = false;
    if (!ensureResources(cglContext, &error, &retry)) {
      if (!error.isEmpty()) {
        if (retry) {
          counters_->setError(std::move(error));
        } else {
          counters_->latchFatalError(std::move(error));
        }
      }
      if (retry) {
        if (synchronizedFrame_ &&
            synchronizedSerial_ != processedTimelineSerial_) {
          recordBackpressure();
        }
        requestAnotherFrame();
      } else {
        fatalFailure_ = true;
      }
      return;
    }
    reclaimSignaledSlots();
    if (fatalFailure_) {
      return;
    }

    if (synchronizedFrame_ &&
        synchronizedSerial_ != processedTimelineSerial_) {
      const ImportResult result = importLatest(*synchronizedFrame_, &error);
      if (result == ImportResult::Backpressure) {
        recordBackpressure();
        requestAnotherFrame();
      } else {
        processedTimelineSerial_ = synchronizedSerial_;
        if (result == ImportResult::Rejected) {
          counters_->rejectedFrames.fetch_add(1, std::memory_order_relaxed);
          counters_->setError(std::move(error));
        } else {
          counters_->setError({});
        }
      }
    }
    if (!currentSlot_) {
      return;
    }
    draw(*currentSlot_, renderState, &error);
    if (!error.isEmpty()) {
      counters_->latchFatalError(std::move(error));
      fatalFailure_ = true;
    }
  }

 private:
  enum class ImportResult { Imported, Backpressure, Rejected };

  class DeferredRetirementGuard final {
   public:
    explicit DeferredRetirementGuard(QtGlVideoNode* node) : node_(node) {}
    ~DeferredRetirementGuard() {
      if (node_->deferredRetirement_) {
        node_->deferredRetirement_ = false;
        node_->retireAll();
      }
    }

   private:
    QtGlVideoNode* node_;
  };

  struct Slot {
    std::array<GLuint, 2> textures{};
    GLsync fence{nullptr};
    FrameLease frame;
    ColorParameters color;
    bool initialized{false};
  };

  struct Uniforms {
    GLint mvp{-1};
    GLint rect{-1};
    GLint lumaSize{-1};
    GLint luma{-1};
    GLint chroma{-1};
    GLint range{-1};
    GLint red{-1};
    GLint green{-1};
    GLint blue{-1};
    GLint chromaOffsetX{-1};
    GLint opacity{-1};
  };

  bool ensureResources(CGLContextObj cglContext, QString* error,
                       bool* retry) {
    *retry = false;
    if (counters_->pendingRetirements.load(std::memory_order_acquire) != 0) {
      *retry = true;
      return false;
    }
    if (originContext_ != nullptr && originContext_ != cglContext) {
      // Even two contexts in one share group cannot share a VAO. Retire every
      // shareable object and rebuild a fresh context-local VAO on the next
      // render round.
      deferredRetirement_ = true;
      *retry = true;
      return false;
    }
    CGLShareGroupObj currentShareGroup = CGLGetShareGroup(cglContext);
    if (service_ && service_->shareGroup() != currentShareGroup) {
      deferredRetirement_ = true;
      *retry = true;
      return false;
    }
    if (!service_) {
      service_ = retirementRegistry().serviceFor(cglContext, error);
      if (!service_) {
        return false;
      }
    }
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (state_->failAfterRetirementServiceCreation.exchange(
            false, std::memory_order_relaxed)) {
      *error = QStringLiteral(
          "injected failure after CGL retirement service creation");
      return false;
    }
#endif
    if (program_ != 0) {
      return true;
    }
    originContext_ = cglContext;

    GLint major = 0;
    GLint minor = 0;
    GLint profile = 0;
    glGetIntegerv(GL_MAJOR_VERSION, &major);
    glGetIntegerv(GL_MINOR_VERSION, &minor);
    glGetIntegerv(GL_CONTEXT_PROFILE_MASK, &profile);
    if (major < 3 || (major == 3 && minor < 2)) {
      *error = QStringLiteral("Qt OpenGL item requires a 3.2 core context");
      return false;
    }
    if ((profile & GL_CONTEXT_CORE_PROFILE_BIT) == 0) {
      *error = QStringLiteral("Qt OpenGL item requires a core profile");
      return false;
    }
    GLint accelerated = 0;
    GLint virtualScreen = 0;
    const CGLError screenStatus =
        CGLGetVirtualScreen(cglContext, &virtualScreen);
    const CGLError acceleratedStatus =
        screenStatus == kCGLNoError
            ? CGLDescribePixelFormat(CGLGetPixelFormat(cglContext),
                                     virtualScreen, kCGLPFAAccelerated,
                                     &accelerated)
            : screenStatus;
    if (acceleratedStatus != kCGLNoError || accelerated == 0) {
      *error = QStringLiteral(
          "Qt OpenGL item requires an accelerated CGL pixel format");
      return false;
    }
    counters_->acceleratedContext.store(true, std::memory_order_relaxed);
    counters_->textureRectangleSupported.store(true,
                                                std::memory_order_relaxed);
    counters_->textureRgSupported.store(true, std::memory_order_relaxed);

    const GLuint vertex = compileShader(GL_VERTEX_SHADER, kVertexShader, error);
    if (vertex == 0) {
      return false;
    }
    const GLuint fragment =
        compileShader(GL_FRAGMENT_SHADER, kFragmentShader, error);
    if (fragment == 0) {
      glDeleteShader(vertex);
      return false;
    }
    program_ = glCreateProgram();
    glAttachShader(program_, vertex);
    glAttachShader(program_, fragment);
    glLinkProgram(program_);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = GL_FALSE;
    glGetProgramiv(program_, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
      GLint length = 0;
      glGetProgramiv(program_, GL_INFO_LOG_LENGTH, &length);
      std::string log(static_cast<std::size_t>(std::max(length, 1)), '\0');
      glGetProgramInfoLog(program_, length, nullptr, log.data());
      *error = QStringLiteral("OpenGL shader link failed: %1")
                   .arg(QString::fromStdString(log));
      deferredRetirement_ = true;
      return false;
    }
    glGenVertexArrays(1, &vertexArray_);
    if (vertexArray_ == 0) {
      *error = QStringLiteral("failed to allocate OpenGL vertex array");
      deferredRetirement_ = true;
      return false;
    }
    uniforms_.mvp = glGetUniformLocation(program_, "uMvp");
    uniforms_.rect = glGetUniformLocation(program_, "uRect");
    uniforms_.lumaSize = glGetUniformLocation(program_, "uLumaSize");
    uniforms_.luma = glGetUniformLocation(program_, "uLuma");
    uniforms_.chroma = glGetUniformLocation(program_, "uChroma");
    uniforms_.range = glGetUniformLocation(program_, "uRange");
    uniforms_.red = glGetUniformLocation(program_, "uRed");
    uniforms_.green = glGetUniformLocation(program_, "uGreen");
    uniforms_.blue = glGetUniformLocation(program_, "uBlue");
    uniforms_.chromaOffsetX =
        glGetUniformLocation(program_, "uChromaOffsetX");
    uniforms_.opacity = glGetUniformLocation(program_, "uOpacity");
    const std::array<GLint, 11> locations{
        uniforms_.mvp,     uniforms_.rect,  uniforms_.lumaSize,
        uniforms_.luma,    uniforms_.chroma, uniforms_.range,
        uniforms_.red,     uniforms_.green, uniforms_.blue,
        uniforms_.chromaOffsetX, uniforms_.opacity};
    if (std::any_of(locations.begin(), locations.end(),
                    [](GLint location) { return location < 0; })) {
      *error = QStringLiteral("OpenGL shader is missing required uniforms");
      deferredRetirement_ = true;
      return false;
    }
    return true;
  }

  void reclaimSignaledSlots() {
    for (std::size_t index = 0; index < slots_.size(); ++index) {
      Slot& slot = slots_[index];
      if (!slot.frame || !slot.fence || currentSlot_ == index) {
        continue;
      }
      const GLenum status = glClientWaitSync(slot.fence, 0, 0);
      if (status == GL_ALREADY_SIGNALED ||
          status == GL_CONDITION_SATISFIED) {
        glDeleteSync(slot.fence);
        slot.fence = nullptr;
        slot.frame.reset();
      } else if (status == GL_WAIT_FAILED) {
        counters_->retirementFailed.store(true, std::memory_order_relaxed);
        fatalFailure_ = true;
        counters_->latchFatalError(QStringLiteral(
            "Qt CGL frame fence failed; slot retained fail-closed"));
      }
    }
  }

  std::optional<std::size_t> availableSlot() const {
    for (std::size_t index = 0; index < slots_.size(); ++index) {
      if (!slots_[index].frame) {
        return index;
      }
    }
    return std::nullopt;
  }

  bool validatePlaneLayout(const FrameLease& frame, bool tenBit,
                           QString* error) const {
    CVPixelBufferRef pixelBuffer = frame.pixelBuffer();
    IOSurfaceRef surface = frame.ioSurface();
    if (!frame.isIOSurfaceBacked() || surface == nullptr ||
        !CVPixelBufferIsPlanar(pixelBuffer) ||
        CVPixelBufferGetPlaneCount(pixelBuffer) != 2 ||
        IOSurfaceGetPlaneCount(surface) != 2) {
      *error = QStringLiteral(
          "Qt OpenGL item requires an IOSurface with exactly two planes");
      return false;
    }
    const OSType surfaceFormat = IOSurfaceGetPixelFormat(surface);
    if (surfaceFormat != 0 && surfaceFormat != frame.pixelFormat()) {
      *error = QStringLiteral(
          "IOSurface pixel format contradicts its CVPixelBuffer");
      return false;
    }
    if (frame.width() == 0 || frame.height() == 0) {
      *error = QStringLiteral("IOSurface frame has empty dimensions");
      return false;
    }
    const std::array<std::size_t, 2> expectedWidths{
        frame.width(), frame.width() / 2U + frame.width() % 2U};
    const std::array<std::size_t, 2> expectedHeights{
        frame.height(), frame.height() / 2U + frame.height() % 2U};
    const std::array<std::size_t, 2> bytesPerElement{
        tenBit ? 2U : 1U, tenBit ? 4U : 2U};
    for (std::size_t plane = 0; plane < 2; ++plane) {
      const std::size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane);
      const std::size_t height =
          CVPixelBufferGetHeightOfPlane(pixelBuffer, plane);
      const std::size_t bytesPerRow =
          CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane);
      if (width != expectedWidths[plane] ||
          height != expectedHeights[plane] ||
          width > static_cast<std::size_t>(std::numeric_limits<GLsizei>::max()) ||
          height > static_cast<std::size_t>(std::numeric_limits<GLsizei>::max()) ||
          width > std::numeric_limits<std::size_t>::max() /
                      bytesPerElement[plane] ||
          bytesPerRow < width * bytesPerElement[plane] ||
          IOSurfaceGetWidthOfPlane(surface, plane) != width ||
          IOSurfaceGetHeightOfPlane(surface, plane) != height ||
          IOSurfaceGetBytesPerElementOfPlane(surface, plane) !=
              bytesPerElement[plane] ||
          IOSurfaceGetBytesPerRowOfPlane(surface, plane) !=
              bytesPerRow) {
        *error = QStringLiteral(
            "IOSurface plane layout does not match exact NV12/P010 CGL import");
        return false;
      }
    }
    return true;
  }

  ImportResult importLatest(const FrameLease& frame, QString* error) {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (state_->failNextImport.exchange(false, std::memory_order_relaxed)) {
      *error = QStringLiteral("injected Qt CGL import failure");
      return ImportResult::Rejected;
    }
#endif
    if (frame.timing().generation != synchronizedGeneration_) {
      *error = QStringLiteral("native frame generation changed during sync");
      return ImportResult::Rejected;
    }
    const OSType format = frame.pixelFormat();
    const bool tenBit =
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    auto color = colorParameters(frame.pixelBuffer(), error);
    if (!color || !validatePlaneLayout(frame, tenBit, error)) {
      return ImportResult::Rejected;
    }
    const auto available = availableSlot();
    if (!available) {
      return ImportResult::Backpressure;
    }
    Slot& slot = slots_[*available];
    if (!slot.initialized) {
      glGenTextures(static_cast<GLsizei>(slot.textures.size()),
                    slot.textures.data());
      if (slot.textures[0] == 0 || slot.textures[1] == 0) {
        glDeleteTextures(static_cast<GLsizei>(slot.textures.size()),
                         slot.textures.data());
        slot.textures = {};
        *error = QStringLiteral("failed to allocate CGL plane textures");
        return ImportResult::Rejected;
      }
      slot.initialized = true;
      const std::size_t active =
          counters_->activeResourceSets.fetch_add(1,
                                                  std::memory_order_relaxed) +
          1;
      updatePeak(counters_->peakActiveResourceSets, active);
    }

    // Retain before the first CGL bind. If a driver rejects the second plane,
    // the partially rebound texture set and its source IOSurface retire
    // together instead of returning memory to VideoToolbox early.
    slot.frame = frame;
    slot.color = *color;
    IOSurfaceRef surface = frame.ioSurface();
    const std::array<GLenum, 2> internalFormats{
        static_cast<GLenum>(tenBit ? GL_R16 : GL_R8),
        static_cast<GLenum>(tenBit ? GL_RG16 : GL_RG8)};
    const std::array<GLenum, 2> externalFormats{GL_RED, GL_RG};
    const GLenum type = tenBit ? GL_UNSIGNED_SHORT : GL_UNSIGNED_BYTE;
    drainGlErrors();
    for (std::size_t plane = 0; plane < slot.textures.size(); ++plane) {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
      if (plane == 1 && state_->failSecondPlaneImport.exchange(
                            false, std::memory_order_relaxed)) {
        *error = QStringLiteral("injected second-plane CGL import failure");
        currentSlot_.reset();
        deferredRetirement_ = true;
        return ImportResult::Rejected;
      }
#endif
      glActiveTexture(static_cast<GLenum>(GL_TEXTURE0 + plane));
      glBindTexture(GL_TEXTURE_RECTANGLE, slot.textures[plane]);
      glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      const CGLError importStatus = CGLTexImageIOSurface2D(
          CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE, internalFormats[plane],
          static_cast<GLsizei>(
              CVPixelBufferGetWidthOfPlane(frame.pixelBuffer(), plane)),
          static_cast<GLsizei>(
              CVPixelBufferGetHeightOfPlane(frame.pixelBuffer(), plane)),
          externalFormats[plane], type, surface, static_cast<GLuint>(plane));
      if (importStatus != kCGLNoError || glGetError() != GL_NO_ERROR) {
        *error = QStringLiteral("CGL IOSurface plane import failed: %1")
                     .arg(QString::fromLatin1(CGLErrorString(importStatus)));
        // RawGlState must first unbind/restore the source-context texture
        // bindings. The outer guard then transfers the partial names and
        // FrameLease to the shared retirement context.
        currentSlot_.reset();
        deferredRetirement_ = true;
        return ImportResult::Rejected;
      }
    }
    currentSlot_ = *available;
    counters_->lastPixelFormat.store(format, std::memory_order_relaxed);
    counters_->exactSourceIOSurface.store(true, std::memory_order_relaxed);
    counters_->importedFrames.fetch_add(1, std::memory_order_relaxed);
    return ImportResult::Imported;
  }

  void applyClip(const RenderState* state) {
    if (state->scissorEnabled()) {
      counters_->sawScissorClip.store(true, std::memory_order_relaxed);
      const QRect scissor = state->scissorRect();
      glEnable(GL_SCISSOR_TEST);
      glScissor(scissor.x(), scissor.y(), scissor.width(), scissor.height());
    } else {
      glDisable(GL_SCISSOR_TEST);
    }
    if (state->stencilEnabled()) {
      counters_->sawStencilClip.store(true, std::memory_order_relaxed);
      glEnable(GL_STENCIL_TEST);
      glStencilFunc(GL_EQUAL, state->stencilValue(), 0xFFU);
      glStencilMask(0xFFU);
      glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
    } else {
      glDisable(GL_STENCIL_TEST);
    }
  }

  void draw(std::size_t slotIndex, const RenderState* state, QString* error) {
    Slot& slot = slots_[slotIndex];
    if (!slot.frame || program_ == 0 || vertexArray_ == 0 ||
        state->projectionMatrix() == nullptr || matrix() == nullptr) {
      return;
    }
    const QRectF fitted = aspectFitRect(bounds_, slot.frame);
    if (fitted.isEmpty()) {
      return;
    }

    GLint framebuffer = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
    if (framebuffer != 0) {
      counters_->renderedIntoNonDefaultFramebuffer.store(
          true, std::memory_order_relaxed);
    }
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_RASTERIZER_DISCARD);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    applyClip(state);

    const GLfloat opacity =
        std::clamp(static_cast<GLfloat>(inheritedOpacity()), 0.0F, 1.0F);
    if (opacity < 1.0F) {
      glEnable(GL_BLEND);
      glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
      glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE,
                          GL_ONE_MINUS_SRC_ALPHA);
    } else {
      glDisable(GL_BLEND);
    }
    glUseProgram(program_);
    glBindVertexArray(vertexArray_);
    glActiveTexture(GL_TEXTURE0);
    glBindSampler(0, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE, slot.textures[0]);
    glActiveTexture(GL_TEXTURE1);
    glBindSampler(1, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE, slot.textures[1]);

    const QMatrix4x4 mvp = *state->projectionMatrix() * *matrix();
    glUniformMatrix4fv(uniforms_.mvp, 1, GL_FALSE, mvp.constData());
    glUniform4f(uniforms_.rect, static_cast<GLfloat>(fitted.x()),
                static_cast<GLfloat>(fitted.y()),
                static_cast<GLfloat>(fitted.width()),
                static_cast<GLfloat>(fitted.height()));
    glUniform2f(uniforms_.lumaSize,
                static_cast<GLfloat>(slot.frame.width()),
                static_cast<GLfloat>(slot.frame.height()));
    glUniform1i(uniforms_.luma, 0);
    glUniform1i(uniforms_.chroma, 1);
    glUniform4fv(uniforms_.range, 1, slot.color.range.data());
    glUniform3fv(uniforms_.red, 1, slot.color.red.data());
    glUniform3fv(uniforms_.green, 1, slot.color.green.data());
    glUniform3fv(uniforms_.blue, 1, slot.color.blue.data());
    glUniform1f(uniforms_.chromaOffsetX, slot.color.chromaOffsetX);
    glUniform1f(uniforms_.opacity, opacity);
    drainGlErrors();
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    if (glGetError() != GL_NO_ERROR) {
      *error = QStringLiteral("Qt CGL draw failed");
      return;
    }

    GLsync replacementFence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    // A wait in another shared context does not flush this originating
    // context. Publish every fence only after an explicit source-context
    // flush; no render or GUI thread ever waits for it.
    glFlush();
    if (replacementFence == nullptr) {
      counters_->retirementFailed.store(true, std::memory_order_relaxed);
      fatalFailure_ = true;
      *error = QStringLiteral(
          "failed to create CGL completion fence; resources retained "
          "fail-closed");
      return;
    }
    if (slot.fence != nullptr) {
      glDeleteSync(slot.fence);
    }
    slot.fence = replacementFence;
    updateRenderedGeneration(counters_->lastRenderedGeneration,
                             slot.frame.timing().generation);
    // Publishing the completed-frame count after the generation makes an
    // acquire snapshot that observes this draw observe its generation too.
    counters_->renderedFrames.fetch_add(1, std::memory_order_release);
  }

  void retireAll() {
    bool hasResources = program_ != 0 || vertexArray_ != 0;
    std::size_t initialized = 0;
    RetirementJob job;
    job.program = std::exchange(program_, 0);
    deleteVertexArrayInExactOrigin(&vertexArray_, originContext_,
                                   CGLGetCurrentContext());
    originContext_ = nullptr;
    job.counters = counters_;
    job.permanentlyUnsafe =
        counters_->retirementFailed.load(std::memory_order_relaxed);
    for (std::size_t index = 0; index < slots_.size(); ++index) {
      Slot& source = slots_[index];
      RetiredSlot& destination = job.retiredSlots[index];
      destination.textures = std::exchange(source.textures, {});
      destination.fence = std::exchange(source.fence, nullptr);
      destination.frame = std::move(source.frame);
      destination.initialized = std::exchange(source.initialized, false);
      if (destination.initialized) {
        ++initialized;
        hasResources = true;
      }
    }
    job.initializedSlotCount = initialized;
    currentSlot_.reset();
    uniforms_ = {};
    if (!hasResources) {
      service_.reset();
      return;
    }
    if (!service_) {
      // This cannot occur after successful initialization. Retain a failed
      // bundle rather than deleting borrowed views without a compatible GL
      // context.
      counters_->retirementFailed.store(true, std::memory_order_relaxed);
      counters_->latchFatalError(QStringLiteral(
          "CGL resources lost their shared retirement context; retained "
          "fail-closed"));
      quarantineRetirementJob(std::move(job));
      return;
    }
    service_->retire(std::move(job));
    service_.reset();
  }

  void requestAnotherFrame() {
    if (window_ != nullptr) {
      window_->requestUpdate();
    }
  }

  void recordBackpressure() {
    if (lastBackpressureSerial_ == synchronizedSerial_) {
      return;
    }
    lastBackpressureSerial_ = synchronizedSerial_;
    counters_->backpressuredImports.fetch_add(1,
                                              std::memory_order_relaxed);
  }

  std::shared_ptr<QtGlVideoItem::SharedState> state_;
  std::shared_ptr<GlCounters> counters_;
  QQuickWindow* window_{nullptr};
  QRectF bounds_;
  std::optional<FrameLease> synchronizedFrame_;
  std::uint64_t synchronizedSerial_{0};
  std::uint64_t synchronizedGeneration_{0};
  std::uint64_t processedTimelineSerial_{0};
  std::uint64_t lastBackpressureSerial_{0};
  std::uint64_t displayedGeneration_{0};
  std::shared_ptr<RetirementService> service_;
  std::array<Slot, kSlotCount> slots_;
  std::optional<std::size_t> currentSlot_;
  GLuint program_{0};
  GLuint vertexArray_{0};
  CGLContextObj originContext_{nullptr};
  Uniforms uniforms_;
  bool fatalFailure_{false};
  bool deferredRetirement_{false};
};

}  // namespace

QtGlVideoItem::QtGlVideoItem(QQuickItem* parent)
    : QQuickItem(parent), state_(std::make_shared<SharedState>()) {
  setFlag(ItemHasContents, true);
}

QtGlVideoItem::~QtGlVideoItem() = default;

void QtGlVideoItem::submitFrame(FrameLease frame) {
  if (!frame) {
    state_->counters->rejectedFrames.fetch_add(1, std::memory_order_relaxed);
    state_->counters->setError(QStringLiteral("empty native video frame"));
    return;
  }
  {
    QMutexLocker lock(&state_->mutex);
    if (!state_->generationOpen ||
        frame.timing().generation != state_->acceptedGeneration) {
      state_->counters->staleFrames.fetch_add(1,
                                              std::memory_order_relaxed);
      return;
    }
    state_->latestFrame = std::move(frame);
    ++state_->timelineSerial;
    if (state_->timelineSerial == 0) {
      ++state_->timelineSerial;
    }
  }
  state_->counters->submittedFrames.fetch_add(1, std::memory_order_relaxed);
  update();
}

void QtGlVideoItem::flush(std::uint64_t nextGeneration) noexcept {
  {
    QMutexLocker lock(&state_->mutex);
    if (nextGeneration > state_->acceptedGeneration) {
      state_->acceptedGeneration = nextGeneration;
    } else if (state_->acceptedGeneration <
               std::numeric_limits<std::uint64_t>::max()) {
      // Same/lower generations are a controller bug. Advance fail-closed so
      // no callback from the already-flushed timeline can be re-admitted.
      ++state_->acceptedGeneration;
    } else {
      state_->generationOpen = false;
    }
    state_->latestFrame.reset();
    ++state_->timelineSerial;
    if (state_->timelineSerial == 0) {
      ++state_->timelineSerial;
    }
  }
  update();
}

QtGlVideoItemStats QtGlVideoItem::stats() const {
  const auto& counters = *state_->counters;
  QtGlVideoItemStats result;
  {
    QMutexLocker lock(&state_->mutex);
    result.acceptedGeneration = state_->acceptedGeneration;
  }
  result.submittedFrames =
      counters.submittedFrames.load(std::memory_order_relaxed);
  result.importedFrames =
      counters.importedFrames.load(std::memory_order_relaxed);
  result.renderedFrames =
      counters.renderedFrames.load(std::memory_order_acquire);
  result.lastRenderedGeneration =
      counters.lastRenderedGeneration.load(std::memory_order_acquire);
  result.backpressuredImports =
      counters.backpressuredImports.load(std::memory_order_relaxed);
  result.rejectedFrames =
      counters.rejectedFrames.load(std::memory_order_relaxed);
  result.staleFrames = counters.staleFrames.load(std::memory_order_relaxed);
  result.destroyedResourceSets =
      counters.destroyedResourceSets.load(std::memory_order_relaxed);
  result.activeResourceSets =
      counters.activeResourceSets.load(std::memory_order_relaxed);
  result.peakActiveResourceSets =
      counters.peakActiveResourceSets.load(std::memory_order_relaxed);
  result.pendingRetirements =
      counters.pendingRetirements.load(std::memory_order_relaxed);
  result.lastPixelFormat =
      counters.lastPixelFormat.load(std::memory_order_relaxed);
  result.exactSourceIOSurface =
      counters.exactSourceIOSurface.load(std::memory_order_relaxed);
  result.textureRectangleSupported =
      counters.textureRectangleSupported.load(std::memory_order_relaxed);
  result.textureRgSupported =
      counters.textureRgSupported.load(std::memory_order_relaxed);
  result.acceleratedContext =
      counters.acceleratedContext.load(std::memory_order_relaxed);
  result.renderedIntoNonDefaultFramebuffer =
      counters.renderedIntoNonDefaultFramebuffer.load(
          std::memory_order_relaxed);
  result.sawScissorClip =
      counters.sawScissorClip.load(std::memory_order_relaxed);
  result.sawStencilClip =
      counters.sawStencilClip.load(std::memory_order_relaxed);
  result.retirementFailed =
      counters.retirementFailed.load(std::memory_order_relaxed);
  {
    QMutexLocker lock(&counters.errorMutex);
    result.lastError = counters.lastError;
    result.fatalErrorSerial =
        counters.fatalErrorSerial.load(std::memory_order_acquire);
  }
  return result;
}

std::optional<QString> QtGlVideoItem::takeFatalError() {
  return state_->counters->takeFatalError();
}

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
void QtGlVideoItem::failNextImportForTesting() {
  state_->failNextImport.store(true, std::memory_order_relaxed);
}

void QtGlVideoItem::failSecondPlaneImportForTesting() {
  state_->failSecondPlaneImport.store(true, std::memory_order_relaxed);
}

void QtGlVideoItem::failAfterRetirementServiceCreationForTesting() {
  state_->failAfterRetirementServiceCreation.store(true,
                                                    std::memory_order_relaxed);
}

void QtGlVideoItem::holdRetirementsForTesting(bool hold) {
  state_->counters->holdRetirements.store(hold, std::memory_order_relaxed);
  retirementRegistry().wakeAll();
  update();
}

void QtGlVideoItem::strandRetirementServiceForTesting() {
  state_->strandRetirementService.store(true, std::memory_order_relaxed);
  update();
}

std::size_t QtGlVideoItem::quarantinedJobsForTesting() noexcept {
  return gQuarantinedRetirementJobs.load(std::memory_order_relaxed);
}

bool QtGlVideoItem::verifyContextLocalVaoPolicyForTesting() {
  const CGLPixelFormatAttribute acceleratedAttributes[] = {
      kCGLPFAAccelerated,
      kCGLPFAOpenGLProfile,
      static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_3_2_Core),
      static_cast<CGLPixelFormatAttribute>(0)};
  const CGLPixelFormatAttribute coreAttributes[] = {
      kCGLPFAOpenGLProfile,
      static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_3_2_Core),
      static_cast<CGLPixelFormatAttribute>(0)};
  CGLPixelFormatObj pixelFormat = nullptr;
  GLint count = 0;
  if (CGLChoosePixelFormat(acceleratedAttributes, &pixelFormat, &count) !=
          kCGLNoError ||
      pixelFormat == nullptr || count <= 0) {
    if (pixelFormat != nullptr) {
      CGLDestroyPixelFormat(pixelFormat);
      pixelFormat = nullptr;
    }
    count = 0;
    if (CGLChoosePixelFormat(coreAttributes, &pixelFormat, &count) !=
            kCGLNoError ||
        pixelFormat == nullptr || count <= 0) {
      return false;
    }
  }
  CGLContextObj origin = nullptr;
  CGLContextObj sameShareGroup = nullptr;
  CGLContextObj differentShareGroup = nullptr;
  const bool created =
      CGLCreateContext(pixelFormat, nullptr, &origin) == kCGLNoError &&
      origin != nullptr &&
      CGLCreateContext(pixelFormat, origin, &sameShareGroup) == kCGLNoError &&
      sameShareGroup != nullptr &&
      CGLCreateContext(pixelFormat, nullptr, &differentShareGroup) ==
          kCGLNoError &&
      differentShareGroup != nullptr;
  bool passed = created;
  GLuint originVao = 0;
  GLuint sameShareVao = 0;
  if (passed) {
    passed = CGLGetShareGroup(origin) == CGLGetShareGroup(sameShareGroup) &&
             CGLGetShareGroup(origin) !=
                 CGLGetShareGroup(differentShareGroup);
  }
  if (passed) {
    passed = CGLSetCurrentContext(origin) == kCGLNoError;
    glGenVertexArrays(1, &originVao);
    glBindVertexArray(originVao);
    glBindVertexArray(0);
    passed = passed && originVao != 0 && glIsVertexArray(originVao);
  }
  if (passed) {
    passed = CGLSetCurrentContext(sameShareGroup) == kCGLNoError;
    glGenVertexArrays(1, &sameShareVao);
    glBindVertexArray(sameShareVao);
    glBindVertexArray(0);
    passed = passed && sameShareVao != 0 && glIsVertexArray(sameShareVao);
    GLuint foreignName = originVao;
    passed = passed &&
             !deleteVertexArrayInExactOrigin(&foreignName, origin,
                                             sameShareGroup) &&
             foreignName == 0;
  }
  if (passed) {
    passed = CGLSetCurrentContext(origin) == kCGLNoError &&
             glIsVertexArray(originVao);
  }
  if (passed) {
    passed = CGLSetCurrentContext(differentShareGroup) == kCGLNoError;
    GLuint foreignName = originVao;
    passed = !deleteVertexArrayInExactOrigin(
                 &foreignName, origin, differentShareGroup) &&
             foreignName == 0;
  }
  if (origin != nullptr && CGLSetCurrentContext(origin) == kCGLNoError &&
      originVao != 0) {
    const bool deleted =
        deleteVertexArrayInExactOrigin(&originVao, origin, origin);
    passed = passed && deleted && originVao == 0;
  }
  if (sameShareGroup != nullptr &&
      CGLSetCurrentContext(sameShareGroup) == kCGLNoError &&
      sameShareVao != 0) {
    glDeleteVertexArrays(1, &sameShareVao);
  }
  CGLSetCurrentContext(nullptr);
  if (differentShareGroup != nullptr) {
    CGLDestroyContext(differentShareGroup);
  }
  if (sameShareGroup != nullptr) {
    CGLDestroyContext(sameShareGroup);
  }
  if (origin != nullptr) {
    CGLDestroyContext(origin);
  }
  CGLDestroyPixelFormat(pixelFormat);
  return passed;
}
#endif

QSGNode* QtGlVideoItem::updatePaintNode(QSGNode* oldNode,
                                        UpdatePaintNodeData*) {
  auto* node = static_cast<QtGlVideoNode*>(oldNode);
  if (node == nullptr) {
    node = new QtGlVideoNode(state_);
  }
  std::optional<FrameLease> latest;
  std::uint64_t serial = 0;
  std::uint64_t generation = 0;
  {
    QMutexLocker lock(&state_->mutex);
    latest = state_->latestFrame;
    serial = state_->timelineSerial;
    generation = state_->acceptedGeneration;
  }
  node->synchronize(window(), boundingRect(), std::move(latest), serial,
                    generation);
  return node;
}

}  // namespace wam::macos
