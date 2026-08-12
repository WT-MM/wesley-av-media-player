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
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <thread>
#include <utility>

namespace wam::macos {

struct QtGlFatalErrorSerialState {
  std::atomic<std::uint64_t> serial{0};
};

QtGlFatalErrorSerialToken::QtGlFatalErrorSerialToken(
    std::shared_ptr<const QtGlFatalErrorSerialState> state) noexcept
    : state_(std::move(state)) {}

std::uint64_t QtGlFatalErrorSerialToken::load() const noexcept {
  return state_ ? state_->serial.load(std::memory_order_acquire) : 0;
}

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
  std::shared_ptr<QtGlFatalErrorSerialState> fatalErrorSerial{
      std::make_shared<QtGlFatalErrorSerialState>()};
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
  std::atomic<bool> fatalOutstanding{false};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::atomic<bool> holdRetirements{false};
  std::atomic<bool> failNextRetirementEnqueue{false};
  std::atomic<bool> failNextWorkerPoll{false};
  std::atomic<std::uint64_t> transferredCoveringFences{0};
#endif
  mutable QMutex errorMutex;
  QString lastError;
  std::optional<QString> fatalError;

  void setError(QString error) noexcept {
    try {
      QMutexLocker lock(&errorMutex);
      lastError = std::move(error);
    } catch (...) {
      // Diagnostics are best-effort on Qt/driver callback paths.
    }
  }

  void publishFatalSerial() noexcept {
    std::uint64_t observed =
        fatalErrorSerial->serial.load(std::memory_order_relaxed);
    while (observed != std::numeric_limits<std::uint64_t>::max() &&
           !fatalErrorSerial->serial.compare_exchange_weak(
               observed, observed + 1, std::memory_order_release,
               std::memory_order_relaxed)) {
    }
  }

  void latchFatalError(QString error) noexcept {
    if (fatalOutstanding.exchange(true, std::memory_order_acq_rel)) {
      setError(std::move(error));
      return;
    }
    try {
      QMutexLocker lock(&errorMutex);
      lastError = error;
      fatalError.emplace(std::move(error));
      publishFatalSerial();
    } catch (...) {
      // Even if a QString copy fails, publish a serial so the controller
      // retires this native attempt instead of continuing with lost failure.
      publishFatalSerial();
    }
  }

  void latchFatalFailureNoexcept() noexcept {
    retirementFailed.store(true, std::memory_order_relaxed);
    if (!fatalOutstanding.exchange(true, std::memory_order_acq_rel)) {
      publishFatalSerial();
    }
  }

  [[nodiscard]] std::optional<QString> takeFatalError() {
    QMutexLocker lock(&errorMutex);
    std::optional<QString> result = std::move(fatalError);
    fatalError.reset();
    if (!result && fatalOutstanding.load(std::memory_order_acquire)) {
      result.emplace(QStringLiteral(
          "Qt OpenGL native video failed without an available diagnostic"));
    }
    fatalOutstanding.store(false, std::memory_order_release);
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
  RetirementJob* next{nullptr};
};

std::atomic<std::size_t> gQuarantinedRetirementJobs{0};
std::atomic<RetirementJob*> gQuarantinedRetirementHead{nullptr};
std::atomic<bool> gQtGlSubsystemPoisoned{false};

constexpr std::size_t kRetirementQueueCapacity = 32;
constexpr std::size_t kRetirementServiceCapacity = 4;

void poisonQtGlSubsystem(const std::shared_ptr<GlCounters>& counters) noexcept {
  gQtGlSubsystemPoisoned.store(true, std::memory_order_release);
  if (counters) {
    counters->retirementFailed.store(true, std::memory_order_relaxed);
  }
}

void quarantineRetirementJob(
    std::unique_ptr<RetirementJob> job) noexcept {
  if (!job) {
    return;
  }
  poisonQtGlSubsystem(job->counters);
  if (job->counters) {
    job->counters->latchFatalFailureNoexcept();
  }
  RetirementJob* raw = job.release();
  RetirementJob* observed =
      gQuarantinedRetirementHead.load(std::memory_order_relaxed);
  do {
    raw->next = observed;
  } while (!gQuarantinedRetirementHead.compare_exchange_weak(
      observed, raw, std::memory_order_release, std::memory_order_relaxed));
  gQuarantinedRetirementJobs.fetch_add(1, std::memory_order_release);
}

class ScopedCglContext final {
 public:
  explicit ScopedCglContext(CGLContextObj context = nullptr) noexcept
      : context_(context) {}
  ScopedCglContext(const ScopedCglContext&) = delete;
  ScopedCglContext& operator=(const ScopedCglContext&) = delete;
  ~ScopedCglContext() noexcept {
    if (context_ != nullptr) {
      CGLDestroyContext(context_);
    }
  }

  [[nodiscard]] CGLContextObj release() noexcept {
    return std::exchange(context_, nullptr);
  }

 private:
  CGLContextObj context_{nullptr};
};

enum class RetirementServiceState : std::uint8_t {
  Starting,
  Ready,
  Failed,
};

class RetirementService final {
 public:
  static std::shared_ptr<RetirementService> create(CGLContextObj source,
                                                   QString* error) noexcept {
    try {
      if (source == nullptr || CGLGetPixelFormat(source) == nullptr) {
        *error = QStringLiteral("Qt did not expose a usable CGL context");
        return {};
      }
      CGLContextObj retirementContext = nullptr;
      const CGLError status = CGLCreateContext(CGLGetPixelFormat(source),
                                               source, &retirementContext);
      ScopedCglContext contextGuard(retirementContext);
      if (status != kCGLNoError || retirementContext == nullptr) {
        *error = QStringLiteral(
                     "failed to create a shared CGL retirement context: %1")
                     .arg(QString::fromLatin1(CGLErrorString(status)));
        return {};
      }
      auto service = std::shared_ptr<RetirementService>(new RetirementService(
          CGLGetShareGroup(source), contextGuard.release()));
      return service;
    } catch (...) {
      try {
        *error = QStringLiteral(
            "failed to allocate the shared CGL retirement service");
      } catch (...) {
      }
      return {};
    }
  }

  RetirementService(const RetirementService&) = delete;
  RetirementService& operator=(const RetirementService&) = delete;

  ~RetirementService() noexcept {
    bool joined = true;
    try {
      {
        std::lock_guard lock(mutex_);
        stopping_ = true;
        ++revision_;
      }
      condition_.notify_one();
      if (worker_.joinable()) {
        worker_.join();
      }
    } catch (...) {
      joined = false;
      if (worker_.joinable()) {
        try {
          worker_.detach();
        } catch (...) {
        }
      }
    }
    if (joined && context_ != nullptr) {
      CGLDestroyContext(context_);
    }
  }

  [[nodiscard]] CGLShareGroupObj shareGroup() const noexcept {
    return shareGroup_;
  }

  [[nodiscard]] RetirementServiceState state() const noexcept {
    return state_.load(std::memory_order_acquire);
  }

  [[nodiscard]] bool startupTimedOut() noexcept {
    if (state() != RetirementServiceState::Starting ||
        std::chrono::steady_clock::now() - startedAt_ <=
            std::chrono::milliseconds(500)) {
      return false;
    }
    RetirementServiceState expected = RetirementServiceState::Starting;
    if (state_.compare_exchange_strong(expected,
                                       RetirementServiceState::Failed,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
      return true;
    }
    return state() == RetirementServiceState::Failed;
  }

  bool start() noexcept {
    try {
      worker_ = std::thread([this] { run(); });
      return true;
    } catch (...) {
      state_.store(RetirementServiceState::Failed,
                   std::memory_order_release);
      return false;
    }
  }

  bool retire(std::unique_ptr<RetirementJob> job) noexcept {
    if (!job) {
      return false;
    }
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (job->counters && job->counters->failNextRetirementEnqueue.exchange(
                             false, std::memory_order_relaxed)) {
      quarantineRetirementJob(std::move(job));
      return false;
    }
#endif
    if (state() != RetirementServiceState::Ready) {
      quarantineRetirementJob(std::move(job));
      return false;
    }
    try {
      std::lock_guard lock(mutex_);
      if (state() != RetirementServiceState::Ready || stopping_ ||
          queuedJobs_ >= kRetirementQueueCapacity) {
        quarantineRetirementJob(std::move(job));
        return false;
      }
      RetirementJob* raw = job.release();
      raw->next = nullptr;
      if (jobsTail_ != nullptr) {
        jobsTail_->next = raw;
      } else {
        jobsHead_ = raw;
      }
      jobsTail_ = raw;
      ++queuedJobs_;
      if (raw->counters) {
        raw->counters->pendingRetirements.fetch_add(
            1, std::memory_order_relaxed);
      }
      ++revision_;
    } catch (...) {
      quarantineRetirementJob(std::move(job));
      return false;
    }
    condition_.notify_one();
    return true;
  }

  void wake() noexcept {
    try {
      {
        std::lock_guard lock(mutex_);
        ++revision_;
      }
      condition_.notify_one();
    } catch (...) {
      state_.store(RetirementServiceState::Failed,
                   std::memory_order_release);
    }
  }

 private:
  RetirementService(CGLShareGroupObj shareGroup,
                    CGLContextObj context) noexcept
      : shareGroup_(shareGroup), context_(context),
        startedAt_(std::chrono::steady_clock::now()) {}

  static bool jobHeldForTesting(const RetirementJob& job) noexcept {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    return job.counters &&
           job.counters->holdRetirements.load(std::memory_order_relaxed);
#else
    Q_UNUSED(job);
    return false;
#endif
  }

  bool readyToDestroy(RetirementJob& job) noexcept {
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
          poisonQtGlSubsystem(job.counters);
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

  static void destroyJob(RetirementJob& job) noexcept {
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

  void quarantineQueuedJobsNoexcept() noexcept {
    RetirementJob* jobs = nullptr;
    try {
      std::lock_guard lock(mutex_);
      jobs = std::exchange(jobsHead_, nullptr);
      jobsTail_ = nullptr;
      queuedJobs_ = 0;
    } catch (...) {
      // The process-retained service continues owning the intrusive list.
      return;
    }
    while (jobs != nullptr) {
      RetirementJob* next = jobs->next;
      jobs->next = nullptr;
      if (jobs->counters) {
        jobs->counters->pendingRetirements.fetch_sub(
            1, std::memory_order_relaxed);
      }
      quarantineRetirementJob(std::unique_ptr<RetirementJob>(jobs));
      jobs = next;
    }
  }

  void run() noexcept {
    bool contextCurrent = false;
    try {
      if (CGLSetCurrentContext(context_) != kCGLNoError) {
        state_.store(RetirementServiceState::Failed,
                     std::memory_order_release);
        return;
      }
      contextCurrent = true;
      RetirementServiceState expected = RetirementServiceState::Starting;
      if (!state_.compare_exchange_strong(expected,
                                          RetirementServiceState::Ready,
                                          std::memory_order_release,
                                          std::memory_order_acquire)) {
        CGLSetCurrentContext(nullptr);
        return;
      }

      std::unique_lock lock(mutex_);
      while (!stopping_) {
        condition_.wait(lock,
                        [this] { return stopping_ || jobsHead_ != nullptr; });
        if (stopping_) {
          break;
        }
        bool madeProgress = false;
        RetirementJob* previous = nullptr;
        RetirementJob* current = jobsHead_;
        while (current != nullptr) {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
          if (current->counters &&
              current->counters->failNextWorkerPoll.exchange(
                  false, std::memory_order_relaxed)) {
            throw std::bad_alloc{};
          }
#endif
          RetirementJob* next = current->next;
          if (readyToDestroy(*current)) {
            if (previous != nullptr) {
              previous->next = next;
            } else {
              jobsHead_ = next;
            }
            if (jobsTail_ == current) {
              jobsTail_ = previous;
            }
            --queuedJobs_;
            current->next = nullptr;
            destroyJob(*current);
            delete current;
            madeProgress = true;
          } else {
            previous = current;
          }
          current = next;
        }
        if (jobsHead_ != nullptr && !stopping_) {
          bool hasPollableJob = false;
          for (RetirementJob* job = jobsHead_; job != nullptr;
               job = job->next) {
            if (!job->permanentlyUnsafe && !jobHeldForTesting(*job)) {
              hasPollableJob = true;
              break;
            }
          }
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
    } catch (...) {
      state_.store(RetirementServiceState::Failed,
                   std::memory_order_release);
      quarantineQueuedJobsNoexcept();
    }
    if (contextCurrent) {
      CGLSetCurrentContext(nullptr);
    }
  }

  CGLShareGroupObj shareGroup_{nullptr};
  CGLContextObj context_{nullptr};
  std::atomic<RetirementServiceState> state_{
      RetirementServiceState::Starting};
  std::chrono::steady_clock::time_point startedAt_;
  std::mutex mutex_;
  std::condition_variable condition_;
  RetirementJob* jobsHead_{nullptr};
  RetirementJob* jobsTail_{nullptr};
  std::size_t queuedJobs_{0};
  std::uint64_t revision_{0};
  bool stopping_{false};
  std::thread worker_;
};

class RetirementRegistry final {
 public:
  std::shared_ptr<RetirementService> serviceFor(CGLContextObj source,
                                                QString* error) noexcept {
    if (gQtGlSubsystemPoisoned.load(std::memory_order_acquire)) {
      try {
        *error = QStringLiteral(
            "Qt OpenGL native video was disabled after unsafe retirement");
      } catch (...) {
      }
      return {};
    }
    try {
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
      std::shared_ptr<RetirementService>* empty = nullptr;
      for (auto& service : services_) {
        if (service && service->shareGroup() == shareGroup) {
          return service;
        }
        if (!service && empty == nullptr) {
          empty = &service;
        }
      }
      if (empty == nullptr) {
        gQtGlSubsystemPoisoned.store(true, std::memory_order_release);
        *error = QStringLiteral(
            "Qt OpenGL retirement service capacity was exhausted");
        return {};
      }
      auto service = RetirementService::create(source, error);
      if (!service) {
        return {};
      }
      *empty = service;
      if (!service->start()) {
        gQtGlSubsystemPoisoned.store(true, std::memory_order_release);
        *error = QStringLiteral(
            "shared CGL retirement worker could not start");
      }
      return service;
    } catch (...) {
      gQtGlSubsystemPoisoned.store(true, std::memory_order_release);
      return {};
    }
  }

  void wakeAll() noexcept {
    try {
      std::lock_guard lock(mutex_);
      for (const auto& service : services_) {
        if (service) {
          service->wake();
        }
      }
    } catch (...) {
      gQtGlSubsystemPoisoned.store(true, std::memory_order_release);
    }
  }

  [[nodiscard]] std::size_t serviceCount() const noexcept {
    try {
      std::lock_guard lock(mutex_);
      return static_cast<std::size_t>(std::count_if(
          services_.begin(), services_.end(),
          [](const auto& service) { return static_cast<bool>(service); }));
    } catch (...) {
      return kRetirementServiceCapacity;
    }
  }

 private:
  mutable std::mutex mutex_;
  std::array<std::shared_ptr<RetirementService>,
             kRetirementServiceCapacity>
      services_{};
};

RetirementRegistry& retirementRegistry() {
  // Fixed-capacity, process-retained services make dropping the last owner on
  // the scene-graph thread impossible. The OS retires these four maximum
  // worker/context pairs at process exit.
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

class ScopedShaderName final {
 public:
  explicit ScopedShaderName(GLuint shader = 0) noexcept : shader_(shader) {}
  ScopedShaderName(const ScopedShaderName&) = delete;
  ScopedShaderName& operator=(const ScopedShaderName&) = delete;
  ~ScopedShaderName() noexcept {
    if (shader_ != 0) {
      glDeleteShader(shader_);
    }
  }

  [[nodiscard]] GLuint get() const noexcept { return shader_; }
  [[nodiscard]] GLuint release() noexcept {
    return std::exchange(shader_, 0);
  }

 private:
  GLuint shader_{0};
};

class ScopedGlSync final {
 public:
  explicit ScopedGlSync(GLsync sync = nullptr) noexcept : sync_(sync) {}
  ScopedGlSync(const ScopedGlSync&) = delete;
  ScopedGlSync& operator=(const ScopedGlSync&) = delete;
  ~ScopedGlSync() noexcept {
    if (sync_ != nullptr) {
      glDeleteSync(sync_);
    }
  }

  [[nodiscard]] GLsync get() const noexcept { return sync_; }
  [[nodiscard]] GLsync release() noexcept {
    return std::exchange(sync_, nullptr);
  }

 private:
  GLsync sync_{nullptr};
};

GLuint compileShader(GLenum type, const char* source, QString* error) {
  ScopedShaderName shader(glCreateShader(type));
  if (shader.get() == 0) {
    *error = QStringLiteral("failed to allocate OpenGL shader");
    return 0;
  }
  const GLuint name = shader.get();
  glShaderSource(name, 1, &source, nullptr);
  glCompileShader(name);
  GLint compiled = GL_FALSE;
  glGetShaderiv(name, GL_COMPILE_STATUS, &compiled);
  if (compiled == GL_TRUE) {
    return shader.release();
  }
  GLint length = 0;
  glGetShaderiv(name, GL_INFO_LOG_LENGTH, &length);
  std::string log(static_cast<std::size_t>(std::max(length, 1)), '\0');
  glGetShaderInfoLog(name, length, nullptr, log.data());
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
  std::uint64_t acceptedRenderedFrames{0};
  bool generationOpen{true};
  std::uint64_t timelineSerial{0};
  std::shared_ptr<GlCounters> counters{std::make_shared<GlCounters>()};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::atomic<bool> failNextImport{false};
  std::atomic<bool> failSecondPlaneImport{false};
  std::atomic<bool> failAfterRetirementServiceCreation{false};
  std::atomic<bool> strandRetirementService{false};
  std::atomic<bool> failNextRetirementJobReservation{false};
  std::atomic<bool> holdRetirementServiceStarting{false};
  std::atomic<bool> failAfterFenceCreation{false};
  std::atomic<bool> failNextSynchronization{false};
#endif
};

namespace {

class QtGlVideoNode final : public QSGRenderNode {
 public:
  explicit QtGlVideoNode(std::shared_ptr<QtGlVideoItem::SharedState> state)
      : state_(std::move(state)), counters_(state_->counters),
        retirementJob_(new (std::nothrow) RetirementJob) {
    if (!retirementJob_) {
      fatalFailure_ = true;
      counters_->latchFatalError(QStringLiteral(
          "failed to reserve fail-closed CGL retirement ownership"));
    }
  }

  ~QtGlVideoNode() override { retireAll(); }

  void synchronize(QQuickWindow* window, const QRectF& bounds,
                   std::optional<FrameLease> latestFrame,
                   std::uint64_t timelineSerial,
                   std::uint64_t acceptedGeneration) noexcept {
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
    try {
      renderImpl(renderState);
    } catch (...) {
      fatalFailure_ = true;
      poisonQtGlSubsystem(counters_);
      counters_->latchFatalError(QStringLiteral(
          "Qt OpenGL render callback failed; resources retained "
          "fail-closed"));
      retireAll();
    }
  }

 private:
  void renderImpl(const RenderState* renderState) {
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

  enum class ImportResult { Imported, Backpressure, Rejected };

  class DeferredRetirementGuard final {
   public:
    explicit DeferredRetirementGuard(QtGlVideoNode* node) : node_(node) {}
    ~DeferredRetirementGuard() noexcept {
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
    if (gQtGlSubsystemPoisoned.load(std::memory_order_acquire)) {
      *error = QStringLiteral(
          "Qt OpenGL native video is disabled after retirement failure");
      return false;
    }
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
        if (error->isEmpty()) {
          counters_->latchFatalFailureNoexcept();
        }
        return false;
      }
    }
    if (service_->state() == RetirementServiceState::Starting
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        || state_->holdRetirementServiceStarting.load(
            std::memory_order_relaxed)
#endif
    ) {
      if (service_->startupTimedOut()) {
        *error = QStringLiteral(
            "shared CGL retirement context startup timed out");
        poisonQtGlSubsystem(counters_);
        return false;
      }
      *retry = true;
      return false;
    }
    if (service_->state() != RetirementServiceState::Ready) {
      *error = QStringLiteral(
          "shared CGL retirement context could not become current");
      poisonQtGlSubsystem(counters_);
      return false;
    }
    if (!retirementJob_) {
      bool failReservation = false;
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
      failReservation = state_->failNextRetirementJobReservation.exchange(
          false, std::memory_order_relaxed);
#endif
      if (!failReservation) {
        retirementJob_.reset(new (std::nothrow) RetirementJob);
      }
      if (!retirementJob_) {
        *error = QStringLiteral(
            "failed to reserve fail-closed CGL retirement ownership");
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

    ScopedShaderName vertex(
        compileShader(GL_VERTEX_SHADER, kVertexShader, error));
    if (vertex.get() == 0) {
      return false;
    }
    ScopedShaderName fragment(
        compileShader(GL_FRAGMENT_SHADER, kFragmentShader, error));
    if (fragment.get() == 0) {
      return false;
    }
    program_ = glCreateProgram();
    if (program_ == 0) {
      *error = QStringLiteral("failed to allocate OpenGL shader program");
      return false;
    }
    glAttachShader(program_, vertex.get());
    glAttachShader(program_, fragment.get());
    glLinkProgram(program_);
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
        poisonQtGlSubsystem(counters_);
        unsafeRetirement_ = true;
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
      // The submitted draw may still reference this slot even though GL
      // reported an error. Without a new covering fence, retire it only into
      // the permanent fail-closed path.
      poisonQtGlSubsystem(counters_);
      unsafeRetirement_ = true;
      fatalFailure_ = true;
      *error = QStringLiteral("Qt CGL draw failed");
      return;
    }

    ScopedGlSync replacementFence(
        glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0));
    // A wait in another shared context does not flush this originating
    // context. Publish every fence only after an explicit source-context
    // flush; no render or GUI thread ever waits for it.
    glFlush();
    if (replacementFence.get() == nullptr) {
      poisonQtGlSubsystem(counters_);
      unsafeRetirement_ = true;
      fatalFailure_ = true;
      *error = QStringLiteral(
          "failed to create CGL completion fence; resources retained "
          "fail-closed");
      return;
    }
    if (slot.fence != nullptr) {
      glDeleteSync(slot.fence);
    }
    slot.fence = replacementFence.release();
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (state_->failAfterFenceCreation.exchange(false,
                                                 std::memory_order_relaxed)) {
      throw std::bad_alloc{};
    }
#endif
    updateRenderedGeneration(counters_->lastRenderedGeneration,
                             slot.frame.timing().generation);
    {
      // Linearize a completed draw against flush(). A fence for the old
      // timeline may be installed after the GUI thread advances generation;
      // that draw remains part of renderedFrames but cannot acknowledge the
      // newly accepted playback attempt.
      QMutexLocker lock(&state_->mutex);
      if (state_->generationOpen &&
          slot.frame.timing().generation == state_->acceptedGeneration &&
          state_->acceptedRenderedFrames !=
              std::numeric_limits<std::uint64_t>::max()) {
        ++state_->acceptedRenderedFrames;
      }
    }
    // Publishing the completed-frame count after the generation makes an
    // acquire snapshot that observes this draw observe its generation too.
    counters_->renderedFrames.fetch_add(1, std::memory_order_release);
  }

  void retireAll() noexcept {
    bool hasResources = program_ != 0 || vertexArray_ != 0;
    std::size_t initialized = 0;
    std::unique_ptr<RetirementJob> job = std::move(retirementJob_);
    if (hasResources && !job) {
      // Resource creation is gated on this reservation. If memory corruption
      // violates that invariant, poison admission before touching ownership.
      poisonQtGlSubsystem(counters_);
      counters_->latchFatalFailureNoexcept();
      return;
    }
    if (!job) {
      service_.reset();
      return;
    }
    job->program = std::exchange(program_, 0);
    deleteVertexArrayInExactOrigin(&vertexArray_, originContext_,
                                   CGLGetCurrentContext());
    originContext_ = nullptr;
    job->counters = counters_;
    job->permanentlyUnsafe = std::exchange(unsafeRetirement_, false);
    for (std::size_t index = 0; index < slots_.size(); ++index) {
      Slot& source = slots_[index];
      RetiredSlot& destination = job->retiredSlots[index];
      destination.textures = std::exchange(source.textures, {});
      destination.fence = std::exchange(source.fence, nullptr);
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
      if (destination.fence != nullptr) {
        counters_->transferredCoveringFences.fetch_add(
            1, std::memory_order_relaxed);
      }
#endif
      destination.frame = std::move(source.frame);
      destination.initialized = std::exchange(source.initialized, false);
      if (destination.initialized) {
        ++initialized;
        hasResources = true;
      }
    }
    job->initializedSlotCount = initialized;
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

  void requestAnotherFrame() noexcept {
    try {
      if (window_ != nullptr) {
        window_->requestUpdate();
      }
    } catch (...) {
      fatalFailure_ = true;
      poisonQtGlSubsystem(counters_);
      counters_->latchFatalError(QStringLiteral(
          "Qt OpenGL scene-graph update request failed"));
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
  std::unique_ptr<RetirementJob> retirementJob_;
  std::array<Slot, kSlotCount> slots_;
  std::optional<std::size_t> currentSlot_;
  GLuint program_{0};
  GLuint vertexArray_{0};
  CGLContextObj originContext_{nullptr};
  Uniforms uniforms_;
  bool fatalFailure_{false};
  bool deferredRetirement_{false};
  bool unsafeRetirement_{false};
};

}  // namespace

QtGlVideoItem::QtGlVideoItem(QQuickItem* parent)
    : QQuickItem(parent), state_(std::make_shared<SharedState>()) {
  setFlag(ItemHasContents, true);
}

QtGlVideoItem::~QtGlVideoItem() = default;

void QtGlVideoItem::submitFrame(FrameLease frame) {
  try {
    if (!frame) {
      state_->counters->rejectedFrames.fetch_add(1,
                                                 std::memory_order_relaxed);
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
    state_->counters->submittedFrames.fetch_add(1,
                                                 std::memory_order_relaxed);
    update();
  } catch (...) {
    poisonQtGlSubsystem(state_->counters);
    state_->counters->latchFatalError(
        QStringLiteral("Qt OpenGL frame submission failed"));
  }
}

void QtGlVideoItem::flush(std::uint64_t nextGeneration) noexcept {
  try {
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
  } catch (...) {
    poisonQtGlSubsystem(state_->counters);
    state_->counters->latchFatalError(
        QStringLiteral("Qt OpenGL generation flush failed"));
    try {
      QMutexLocker lock(&state_->mutex);
      state_->generationOpen = false;
      state_->latestFrame.reset();
    } catch (...) {
    }
  }
}

QtGlVideoItemStats QtGlVideoItem::stats() const {
  const auto& counters = *state_->counters;
  QtGlVideoItemStats result;
  {
    QMutexLocker lock(&state_->mutex);
    result.acceptedGeneration = state_->acceptedGeneration;
    result.acceptedRenderedFrames = state_->acceptedRenderedFrames;
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
        counters.fatalErrorSerial->serial.load(std::memory_order_acquire);
  }
  return result;
}

QtGlFatalErrorSerialToken QtGlVideoItem::fatalErrorSerialToken()
    const noexcept {
  return QtGlFatalErrorSerialToken(state_->counters->fatalErrorSerial);
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

void QtGlVideoItem::failNextRetirementJobReservationForTesting() {
  state_->failNextRetirementJobReservation.store(true,
                                                  std::memory_order_relaxed);
}

void QtGlVideoItem::failNextRetirementEnqueueForTesting() {
  state_->counters->failNextRetirementEnqueue.store(
      true, std::memory_order_relaxed);
}

void QtGlVideoItem::failNextRetirementWorkerPollForTesting() {
  state_->counters->failNextWorkerPoll.store(true,
                                             std::memory_order_relaxed);
}

void QtGlVideoItem::failAfterFenceCreationForTesting() {
  state_->failAfterFenceCreation.store(true, std::memory_order_relaxed);
}

void QtGlVideoItem::failNextSynchronizationForTesting() {
  state_->failNextSynchronization.store(true, std::memory_order_relaxed);
}

void QtGlVideoItem::holdRetirementServiceStartingForTesting(bool hold) {
  state_->holdRetirementServiceStarting.store(hold,
                                               std::memory_order_relaxed);
  update();
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
  return gQuarantinedRetirementJobs.load(std::memory_order_acquire);
}

std::size_t QtGlVideoItem::retirementServiceCountForTesting() noexcept {
  return retirementRegistry().serviceCount();
}

std::size_t QtGlVideoItem::retirementServiceCapacityForTesting() noexcept {
  return kRetirementServiceCapacity;
}

bool QtGlVideoItem::nativeGlSubsystemPoisonedForTesting() noexcept {
  return gQtGlSubsystemPoisoned.load(std::memory_order_acquire);
}

std::uint64_t QtGlVideoItem::transferredCoveringFencesForTesting()
    const noexcept {
  return state_->counters->transferredCoveringFences.load(
      std::memory_order_relaxed);
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
  try {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (state_->failNextSynchronization.exchange(false,
                                                  std::memory_order_relaxed)) {
      throw std::bad_alloc{};
    }
#endif
    auto* node = static_cast<QtGlVideoNode*>(oldNode);
    std::unique_ptr<QtGlVideoNode> created;
    if (node == nullptr) {
      created = std::make_unique<QtGlVideoNode>(state_);
      node = created.get();
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
    if (created) {
      return created.release();
    }
    return node;
  } catch (...) {
    poisonQtGlSubsystem(state_->counters);
    state_->counters->latchFatalError(QStringLiteral(
        "Qt OpenGL scene-graph synchronization failed"));
    return oldNode;
  }
}

}  // namespace wam::macos
