#include "qt_gl_video_item.hpp"
#include "native_video_color.hpp"

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
#include <string_view>
#include <thread>
#include <utility>

namespace wam::macos {

struct QtGlFatalErrorSerialState {
  // One atomic publication couples the monotonic serial to its outstanding
  // fixed reason. The low byte is zero after consumption; the upper 56 bits
  // never reset and are the serial exposed by the read-only token.
  std::atomic<std::uint64_t> event{0};
};

namespace {

static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
static_assert(std::atomic<std::int64_t>::is_always_lock_free);
static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
static_assert(std::atomic<std::int32_t>::is_always_lock_free);

// Every payload field is atomic so the seqlock snapshot is data-race-free.
// There is one render-thread writer. version is odd while a write is active;
// sequence is published last. Exhaustion fails closed rather than wrapping.
struct AtomicCmTime {
  std::atomic<std::int64_t> value{0};
  std::atomic<std::int32_t> timescale{0};
  std::atomic<std::uint32_t> flags{0};
  std::atomic<std::int64_t> epoch{0};

  void store(CMTime time) noexcept {
    value.store(time.value, std::memory_order_relaxed);
    timescale.store(time.timescale, std::memory_order_relaxed);
    flags.store(time.flags, std::memory_order_relaxed);
    epoch.store(time.epoch, std::memory_order_relaxed);
  }

  [[nodiscard]] CMTime load() const noexcept {
    CMTime result;
    result.value = value.load(std::memory_order_relaxed);
    result.timescale = timescale.load(std::memory_order_relaxed);
    result.flags = flags.load(std::memory_order_relaxed);
    result.epoch = epoch.load(std::memory_order_relaxed);
    return result;
  }
};

}  // namespace

struct QtGlRenderProgressState {
  std::atomic<std::uint64_t> drawVersion{0};
  std::atomic<std::uint64_t> drawSequence{0};
  std::atomic<std::uint64_t> drawDeliverySequence{0};
  std::atomic<std::uint64_t> drawFrameSequence{0};
  std::atomic<std::uint64_t> drawGeneration{0};
  AtomicCmTime drawPresentationTime;
  AtomicCmTime drawDuration;

  // Generations are themselves nonzero, strictly monotonic invalidation
  // identities. Keeping the complete invalidation event in one atomic makes
  // publication safe when a GUI-side empty-node proof races the last render
  // node's retirement proof; no render callback takes a writer lock.
  std::atomic<std::uint64_t> invalidatedGeneration{0};

  std::atomic<std::uint64_t> rejectionVersion{0};
  std::atomic<std::uint64_t> rejectionSequence{0};
  std::atomic<std::uint64_t> rejectedDeliverySequence{0};
  std::atomic<std::uint64_t> rejectedFrameSequence{0};
  std::atomic<std::uint64_t> rejectedGeneration{0};

  [[nodiscard]] bool publishDraw(std::uint64_t deliverySequence,
                                 std::uint64_t frameSequence,
                                 std::uint64_t generation,
                                 CMTime presentationTime,
                                 CMTime duration) noexcept {
    const std::uint64_t prior = drawSequence.load(std::memory_order_relaxed);
    const std::uint64_t version =
        drawVersion.load(std::memory_order_relaxed);
    if (deliverySequence == 0 || frameSequence == 0 ||
        prior == std::numeric_limits<std::uint64_t>::max() ||
        version > std::numeric_limits<std::uint64_t>::max() - 2) {
      return false;
    }
    drawVersion.store(version + 1, std::memory_order_release);
    drawDeliverySequence.store(deliverySequence, std::memory_order_relaxed);
    drawFrameSequence.store(frameSequence, std::memory_order_relaxed);
    drawGeneration.store(generation, std::memory_order_relaxed);
    drawPresentationTime.store(presentationTime);
    drawDuration.store(duration);
    drawVersion.store(version + 2, std::memory_order_release);
    drawSequence.store(prior + 1, std::memory_order_release);
    return true;
  }

  [[nodiscard]] bool publishInvalidation(
      std::uint64_t generation) noexcept {
    if (generation == 0) {
      return false;
    }
    std::uint64_t observed =
        invalidatedGeneration.load(std::memory_order_acquire);
    while (observed < generation &&
           !invalidatedGeneration.compare_exchange_weak(
               observed, generation, std::memory_order_release,
               std::memory_order_acquire)) {
    }
    return true;
  }

  [[nodiscard]] bool publishRejection(
      QtGlFrameIdentity identity, std::uint64_t generation) noexcept {
    const std::uint64_t prior =
        rejectionSequence.load(std::memory_order_relaxed);
    const std::uint64_t version =
        rejectionVersion.load(std::memory_order_relaxed);
    if (identity.deliverySequence == 0 || identity.frameSequence == 0 ||
        prior == std::numeric_limits<std::uint64_t>::max() ||
        version > std::numeric_limits<std::uint64_t>::max() - 2) {
      return false;
    }
    rejectionVersion.store(version + 1, std::memory_order_release);
    rejectedDeliverySequence.store(identity.deliverySequence,
                                   std::memory_order_relaxed);
    rejectedFrameSequence.store(identity.frameSequence,
                                std::memory_order_relaxed);
    rejectedGeneration.store(generation, std::memory_order_relaxed);
    rejectionVersion.store(version + 2, std::memory_order_release);
    rejectionSequence.store(prior + 1, std::memory_order_release);
    return true;
  }
};

QtGlRenderProgressToken::QtGlRenderProgressToken(
    std::shared_ptr<const QtGlRenderProgressState> state) noexcept
    : state_(std::move(state)) {}

std::optional<QtGlDrawEvent> QtGlRenderProgressToken::drawAfter(
    std::uint64_t observedSequence) const noexcept {
  if (!state_) {
    return std::nullopt;
  }
  for (unsigned attempt = 0; attempt != 3; ++attempt) {
    const std::uint64_t sequence =
        state_->drawSequence.load(std::memory_order_acquire);
    if (sequence == 0 || sequence <= observedSequence) {
      return std::nullopt;
    }
    const std::uint64_t before =
        state_->drawVersion.load(std::memory_order_acquire);
    if ((before & 1U) != 0) {
      continue;
    }
    QtGlDrawEvent event;
    event.drawSequence = sequence;
    event.deliverySequence =
        state_->drawDeliverySequence.load(std::memory_order_relaxed);
    event.frameSequence =
        state_->drawFrameSequence.load(std::memory_order_relaxed);
    event.generation =
        state_->drawGeneration.load(std::memory_order_relaxed);
    event.presentationTime = state_->drawPresentationTime.load();
    event.duration = state_->drawDuration.load();
    const std::uint64_t after =
        state_->drawVersion.load(std::memory_order_acquire);
    if (before == after && (after & 1U) == 0 &&
        state_->drawSequence.load(std::memory_order_acquire) == sequence) {
      return event;
    }
  }
  return std::nullopt;
}

std::optional<QtGlGenerationInvalidatedEvent>
QtGlRenderProgressToken::invalidationAfter(
    std::uint64_t observedSequence) const noexcept {
  if (!state_) {
    return std::nullopt;
  }
  const std::uint64_t generation =
      state_->invalidatedGeneration.load(std::memory_order_acquire);
  if (generation == 0 || generation <= observedSequence) {
    return std::nullopt;
  }
  return QtGlGenerationInvalidatedEvent{generation, generation};
}

std::optional<QtGlFrameRejectedEvent>
QtGlRenderProgressToken::rejectionAfter(
    std::uint64_t observedSequence) const noexcept {
  if (!state_) {
    return std::nullopt;
  }
  for (unsigned attempt = 0; attempt != 3; ++attempt) {
    const std::uint64_t sequence =
        state_->rejectionSequence.load(std::memory_order_acquire);
    if (sequence == 0 || sequence <= observedSequence) {
      return std::nullopt;
    }
    const std::uint64_t before =
        state_->rejectionVersion.load(std::memory_order_acquire);
    if ((before & 1U) != 0) {
      continue;
    }
    QtGlFrameRejectedEvent event;
    event.eventSequence = sequence;
    event.deliverySequence =
        state_->rejectedDeliverySequence.load(std::memory_order_relaxed);
    event.frameSequence =
        state_->rejectedFrameSequence.load(std::memory_order_relaxed);
    event.generation =
        state_->rejectedGeneration.load(std::memory_order_relaxed);
    const std::uint64_t after =
        state_->rejectionVersion.load(std::memory_order_acquire);
    if (before == after && (after & 1U) == 0 &&
        state_->rejectionSequence.load(std::memory_order_acquire) ==
            sequence) {
      return event;
    }
  }
  return std::nullopt;
}

QtGlFatalErrorSerialToken::QtGlFatalErrorSerialToken(
    std::shared_ptr<const QtGlFatalErrorSerialState> state) noexcept
    : state_(std::move(state)) {}

std::uint64_t QtGlFatalErrorSerialToken::load() const noexcept {
  return state_ ? state_->event.load(std::memory_order_acquire) >> 8U : 0;
}

namespace {

constexpr std::size_t kSlotCount = 2;

enum class QtGlFatalReason : std::uint8_t {
  None = 0,
  UnsafeRetirement,
  RetirementFenceFailure,
  RetirementOwnershipReservation,
  RenderCallbackFailure,
  UnsupportedGraphicsApi,
  MissingCglContext,
  ResourceInitializationFailure,
  RetirementStartupTimeout,
  RetirementStartupFailure,
  InjectedServiceCreationFailure,
  DrawFailure,
  FenceCreationFailure,
  UpdateRequestFailure,
  FrameSubmissionFailure,
  GenerationFlushFailure,
  SynchronizationFailure,
  LostRetirementService,
  ProgressSequenceExhaustion,
};

constexpr std::uint64_t kFatalReasonMask = 0xFFU;
constexpr unsigned kFatalSerialShift = 8U;
constexpr std::uint64_t kMaximumFatalSerial =
    std::numeric_limits<std::uint64_t>::max() >> kFatalSerialShift;

QString fatalReasonText(QtGlFatalReason reason) {
  switch (reason) {
    case QtGlFatalReason::UnsafeRetirement:
      return QStringLiteral(
          "Qt OpenGL resources were retained after unsafe retirement");
    case QtGlFatalReason::RetirementFenceFailure:
      return QStringLiteral(
          "shared CGL retirement fence failed; resources retained "
          "fail-closed");
    case QtGlFatalReason::RetirementOwnershipReservation:
      return QStringLiteral(
          "failed to reserve fail-closed CGL retirement ownership");
    case QtGlFatalReason::RenderCallbackFailure:
      return QStringLiteral(
          "Qt OpenGL render callback failed; resources retained "
          "fail-closed");
    case QtGlFatalReason::UnsupportedGraphicsApi:
      return QStringLiteral("Qt Quick is not using a current OpenGL context");
    case QtGlFatalReason::MissingCglContext:
      return QStringLiteral("Qt did not make a CGL context current");
    case QtGlFatalReason::RetirementStartupTimeout:
      return QStringLiteral("shared CGL retirement context startup timed out");
    case QtGlFatalReason::RetirementStartupFailure:
      return QStringLiteral(
          "shared CGL retirement context could not become current");
    case QtGlFatalReason::InjectedServiceCreationFailure:
      return QStringLiteral(
          "injected failure after CGL retirement service creation");
    case QtGlFatalReason::DrawFailure:
      return QStringLiteral("Qt CGL draw failed");
    case QtGlFatalReason::FenceCreationFailure:
      return QStringLiteral(
          "failed to create CGL completion fence; resources retained "
          "fail-closed");
    case QtGlFatalReason::UpdateRequestFailure:
      return QStringLiteral("Qt OpenGL scene-graph update request failed");
    case QtGlFatalReason::FrameSubmissionFailure:
      return QStringLiteral("Qt OpenGL frame submission failed");
    case QtGlFatalReason::GenerationFlushFailure:
      return QStringLiteral("Qt OpenGL generation flush failed");
    case QtGlFatalReason::SynchronizationFailure:
      return QStringLiteral("Qt OpenGL scene-graph synchronization failed");
    case QtGlFatalReason::LostRetirementService:
      return QStringLiteral(
          "CGL resources lost their shared retirement context; retained "
          "fail-closed");
    case QtGlFatalReason::ProgressSequenceExhaustion:
      return QStringLiteral("Qt OpenGL render progress sequence exhausted");
    case QtGlFatalReason::ResourceInitializationFailure:
      return QStringLiteral("Qt OpenGL resource initialization failed");
    case QtGlFatalReason::None:
      break;
  }
  return QStringLiteral(
      "Qt OpenGL native video failed without an available diagnostic");
}

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
  std::atomic<std::size_t> latestFrames{0};
  std::atomic<std::size_t> activeResourceSets{0};
  std::atomic<std::size_t> peakActiveResourceSets{0};
  std::atomic<std::size_t> pendingRetirements{0};
  std::atomic<std::size_t> peakPendingRetirements{0};
  std::atomic<OSType> lastPixelFormat{0};
  std::atomic<bool> exactSourceIOSurface{false};
  std::atomic<bool> textureRectangleSupported{false};
  std::atomic<bool> textureRgSupported{false};
  std::atomic<bool> acceleratedContext{false};
  std::atomic<bool> renderedIntoNonDefaultFramebuffer{false};
  std::atomic<bool> sawScissorClip{false};
  std::atomic<bool> sawStencilClip{false};
  std::atomic<bool> retirementFailed{false};
  // Set when a fatal reason is latched and cleared by the next successful
  // import. While set, stats() reports the latched reason even if the
  // best-effort diagnostic string could not be stored; once a recreated
  // scene graph imports a frame again, lastError reads empty so a controller
  // can recognise the recovery and consume the still-latched event.
  std::atomic<bool> fatalDiagnosticPending{false};
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::atomic<bool> holdRetirements{false};
  std::atomic<bool> holdRetirementCompletion{false};
  std::atomic<bool> retirementCompletionHeld{false};
  std::atomic<bool> failNextRetirementEnqueue{false};
  std::atomic<bool> failNextWorkerPoll{false};
  std::atomic<std::uint64_t> transferredCoveringFences{0};
  std::atomic<std::uint64_t> textureParameterCalls{0};
  std::atomic<std::uint64_t> drawFramebufferBindingQueries{0};
#endif
  mutable QMutex errorMutex;
  QString lastError;

  void setError(QString error) noexcept {
    try {
      QMutexLocker lock(&errorMutex);
      lastError = std::move(error);
    } catch (...) {
      // Diagnostics are best-effort on Qt/driver callback paths.
    }
  }

  void latchFatalReason(QtGlFatalReason reason) noexcept {
    if (reason == QtGlFatalReason::None) {
      reason = QtGlFatalReason::ResourceInitializationFailure;
    }
    std::uint64_t observed =
        fatalErrorSerial->event.load(std::memory_order_acquire);
    while ((observed & kFatalReasonMask) == 0) {
      const std::uint64_t serial = observed >> kFatalSerialShift;
      const std::uint64_t nextSerial =
          serial == kMaximumFatalSerial ? serial : serial + 1;
      const std::uint64_t desired =
          (nextSerial << kFatalSerialShift) |
          static_cast<std::uint64_t>(reason);
      if (fatalErrorSerial->event.compare_exchange_weak(
              observed, desired, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        fatalDiagnosticPending.store(true, std::memory_order_release);
        return;
      }
    }
  }

  void latchUnsafeRetirement() noexcept {
    retirementFailed.store(true, std::memory_order_relaxed);
    latchFatalReason(QtGlFatalReason::UnsafeRetirement);
  }

  [[nodiscard]] std::optional<QString> takeFatalError() {
    std::uint64_t observed =
        fatalErrorSerial->event.load(std::memory_order_acquire);
    while ((observed & kFatalReasonMask) != 0) {
      const QtGlFatalReason reason =
          static_cast<QtGlFatalReason>(observed & kFatalReasonMask);
      // Materialize on the GUI/controller side before consuming the packed
      // event. If QString construction fails, the exact reason remains
      // outstanding and can be retried.
      QString materialized = fatalReasonText(reason);
      const std::uint64_t consumed = observed & ~kFatalReasonMask;
      if (fatalErrorSerial->event.compare_exchange_weak(
              observed, consumed, std::memory_order_acq_rel,
              std::memory_order_acquire)) {
        return std::optional<QString>(std::in_place,
                                      std::move(materialized));
      }
    }
    return std::nullopt;
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

  // The matrix decision lives in native_video_color.hpp, stated once for every
  // presentation route; see that header for why no route may carry a copy.
  YCbCrMatrixKind matrixKind = YCbCrMatrixKind::Bt709;
  if (!ycbcrMatrixForPixelBuffer(pixelBuffer, &matrixKind)) {
    *error = QStringLiteral(
        "Qt OpenGL item supports only absent, BT.601, BT.709, or BT.2020 "
        "YCbCr matrix metadata");
    return std::nullopt;
  }
  const YCbCrMatrixRows rows = ycbcrMatrixRows(matrixKind);
  result.red = rows.red;
  result.green = rows.green;
  result.blue = rows.blue;
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
  bool pendingCharge{false};
  RetirementJob* next{nullptr};
};

std::atomic<std::size_t> gQuarantinedRetirementJobs{0};
std::atomic<std::size_t> gQuarantinedResourceSets{0};
std::atomic<std::size_t> gQuarantinedFrames{0};
std::atomic<RetirementJob*> gQuarantinedRetirementHead{nullptr};
std::atomic<bool> gQtGlSubsystemPoisoned{false};

constexpr std::size_t kRetirementQueueCapacity = 32;
constexpr std::size_t kRetirementServiceCapacity = 4;

void chargeRetirementJob(RetirementJob& job) noexcept {
  if (!job.counters || job.pendingCharge) {
    return;
  }
  const std::size_t pending =
      job.counters->pendingRetirements.fetch_add(
          1, std::memory_order_relaxed) +
      1;
  updatePeak(job.counters->peakPendingRetirements, pending);
  job.pendingCharge = true;
}

void releaseRetirementJobCharge(RetirementJob& job) noexcept {
  if (!job.pendingCharge) {
    return;
  }
  job.pendingCharge = false;
  if (job.counters) {
    job.counters->pendingRetirements.fetch_sub(
        1, std::memory_order_release);
  }
}

void poisonQtGlSubsystem(const std::shared_ptr<GlCounters>& counters) noexcept {
  gQtGlSubsystemPoisoned.store(true, std::memory_order_release);
  if (counters) {
    counters->retirementFailed.store(true, std::memory_order_relaxed);
  }
}

// Takes ownership unconditionally. The never-popped intrusive stack is the
// process-lifetime fail-closed owner: this path cannot allocate, destroy a
// FrameLease, or invoke a driver/Qt diagnostic facility.
void quarantineRetirementJob(RetirementJob* job) noexcept {
  if (job == nullptr) {
    return;
  }
  poisonQtGlSubsystem(job->counters);
  if (job->counters) {
    job->counters->latchUnsafeRetirement();
  }
  std::size_t resourceSets = 0;
  std::size_t frames = 0;
  for (const RetiredSlot& slot : job->retiredSlots) {
    resourceSets += slot.initialized ? 1U : 0U;
    frames += slot.frame ? 1U : 0U;
  }
  RetirementJob* observed =
      gQuarantinedRetirementHead.load(std::memory_order_relaxed);
  do {
    job->next = observed;
  } while (!gQuarantinedRetirementHead.compare_exchange_weak(
      observed, job, std::memory_order_release, std::memory_order_relaxed));
  gQuarantinedResourceSets.fetch_add(resourceSets,
                                     std::memory_order_relaxed);
  gQuarantinedFrames.fetch_add(frames, std::memory_order_relaxed);
  gQuarantinedRetirementJobs.fetch_add(1, std::memory_order_release);
  // The job remains charged until the process-lifetime owner and all of its
  // population facts are visible. This prevents a fresh resource ring from
  // being admitted through an ownership-publication gap.
  releaseRetirementJobCharge(*job);
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

  // Takes ownership unconditionally. Every failure routes the same raw,
  // already-populated job to the allocation-free process quarantine.
  bool retire(RetirementJob* job) noexcept {
    if (job == nullptr) {
      return false;
    }
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (job->counters && job->counters->failNextRetirementEnqueue.exchange(
                             false, std::memory_order_relaxed)) {
      quarantineRetirementJob(job);
      return false;
    }
#endif
    if (job->permanentlyUnsafe ||
        state() != RetirementServiceState::Ready) {
      quarantineRetirementJob(job);
      return false;
    }
    try {
      std::lock_guard lock(mutex_);
      if (state() != RetirementServiceState::Ready || stopping_ ||
          queuedJobs_ >= kRetirementQueueCapacity) {
        quarantineRetirementJob(job);
        return false;
      }
      job->next = nullptr;
      if (jobsTail_ != nullptr) {
        jobsTail_->next = job;
      } else {
        jobsHead_ = job;
      }
      jobsTail_ = job;
      ++queuedJobs_;
      ++revision_;
    } catch (...) {
      quarantineRetirementJob(job);
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

  enum class PollResult : std::uint8_t {
    Waiting,
    Destroy,
    Quarantine,
  };

  PollResult poll(RetirementJob& job) noexcept {
    if (job.permanentlyUnsafe) {
      return PollResult::Quarantine;
    }
    if (jobHeldForTesting(job)) {
      return PollResult::Waiting;
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
          job.counters->latchFatalReason(
              QtGlFatalReason::RetirementFenceFailure);
        }
        return PollResult::Quarantine;
      }
      if (status != GL_ALREADY_SIGNALED &&
          status != GL_CONDITION_SATISFIED) {
        return PollResult::Waiting;
      }
    }
    return PollResult::Destroy;
  }

  // Takes ownership. The pending job population remains charged through the
  // RetirementJob allocation's destruction, then publishes availability.
  static void destroyJob(RetirementJob* job) noexcept {
    if (job == nullptr) {
      return;
    }
    const std::shared_ptr<GlCounters> counters = job->counters;
    const bool pendingCharge = std::exchange(job->pendingCharge, false);
    for (RetiredSlot& slot : job->retiredSlots) {
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
    if (job->program != 0) {
      glDeleteProgram(job->program);
      job->program = 0;
    }
    if (counters) {
      counters->activeResourceSets.fetch_sub(
          job->initializedSlotCount, std::memory_order_relaxed);
      counters->destroyedResourceSets.fetch_add(
          job->initializedSlotCount, std::memory_order_relaxed);
    }
    delete job;
    if (pendingCharge && counters) {
      counters->pendingRetirements.fetch_sub(
          1, std::memory_order_release);
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
      quarantineRetirementJob(jobs);
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
          const PollResult pollResult = poll(*current);
          if (pollResult != PollResult::Waiting) {
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
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
            if (current->counters &&
                current->counters->holdRetirementCompletion.load(
                    std::memory_order_acquire)) {
              current->counters->retirementCompletionHeld.store(
                  true, std::memory_order_release);
              while (current->counters->holdRetirementCompletion.load(
                  std::memory_order_acquire)) {
                std::this_thread::yield();
              }
              current->counters->retirementCompletionHeld.store(
                  false, std::memory_order_release);
            }
#endif
            if (pollResult == PollResult::Destroy) {
              destroyJob(current);
            } else {
              quarantineRetirementJob(current);
            }
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

[[nodiscard]] constexpr bool samplerObjectsSupportedByContract(
    GLint major, GLint minor, bool hasArbSamplerObjects) noexcept {
  return major > 3 || (major == 3 && minor >= 3) ||
         hasArbSamplerObjects;
}

// This does not call glGetError: the Qt render callback may inherit an ambient
// error owned by another participant, and capability discovery must not
// consume it. Every queried value starts fail-closed, and glGetStringi is used
// only after a valid 3.x version result makes it part of the core contract.
[[nodiscard]] bool currentContextSupportsSamplerObjects() noexcept {
  GLint major = 0;
  GLint minor = 0;
  glGetIntegerv(GL_MAJOR_VERSION, &major);
  glGetIntegerv(GL_MINOR_VERSION, &minor);
  if (samplerObjectsSupportedByContract(major, minor, false)) {
    return true;
  }
  if (major < 3) {
    return false;
  }

  GLint extensionCount = -1;
  glGetIntegerv(GL_NUM_EXTENSIONS, &extensionCount);
  if (extensionCount < 0) {
    return false;
  }
  constexpr std::string_view required{"GL_ARB_sampler_objects"};
  for (GLint index = 0; index < extensionCount; ++index) {
    const GLubyte* const value =
        glGetStringi(GL_EXTENSIONS, static_cast<GLuint>(index));
    if (value == nullptr) {
      return false;
    }
    if (std::string_view(reinterpret_cast<const char*>(value)) == required) {
      return true;
    }
  }
  return false;
}

void unbindTextureSamplers(bool samplerObjectsSupported) noexcept {
  if (!samplerObjectsSupported) {
    return;
  }
  glBindSampler(0, 0);
  glBindSampler(1, 0);
}

class RawGlState final {
 public:
  explicit RawGlState(bool samplerObjectsSupported)
      : samplerObjectsSupported_(samplerObjectsSupported) {
    glGetIntegerv(GL_CURRENT_PROGRAM, &program_);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertexArray_);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture_);
    for (std::size_t index = 0; index < textureBindings_.size(); ++index) {
      glActiveTexture(static_cast<GLenum>(GL_TEXTURE0 + index));
      glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &textureBindings_[index]);
      if (samplerObjectsSupported_) {
        glGetIntegerv(GL_SAMPLER_BINDING, &samplerBindings_[index]);
      }
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
      if (samplerObjectsSupported_) {
        glBindSampler(static_cast<GLuint>(index),
                      static_cast<GLuint>(samplerBindings_[index]));
      }
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
  bool samplerObjectsSupported_{false};
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
  static constexpr std::uint32_t kMaximumRenderNodes = 64;

  mutable QMutex mutex;
  std::optional<FrameLease> latestFrame;
  QtGlFrameIdentity latestIdentity{};
  std::uint64_t acceptedGeneration{0};
  std::atomic<std::uint64_t> acceptedRenderedFrames{0};
  // GUI writes the accepted generation under mutex, while a completed render
  // uses a same-value CAS on this seqlock as its nonblocking linearization
  // point against flush().
  std::atomic<std::uint64_t> renderGenerationVersion{0};
  std::atomic<std::uint64_t> renderAcceptedGeneration{0};
  std::atomic<bool> renderGenerationOpen{true};
  std::atomic<std::uint64_t> lastPublishedDrawTimelineSerial{0};
  std::atomic<std::uint64_t> lastRejectedTimelineSerial{0};
  bool generationOpen{true};
  std::uint64_t timelineSerial{0};
  // A GUI-to-render handoff copy can fail closed without becoming a timeline
  // flush. Keep that rejected mailbox serial separate so subsequent Qt sync
  // rounds preserve the render node's prior serial, frame, and GPU slot.
  std::uint64_t synchronizationRejectedSerial{0};
  // Render-thread token-copy rejection is acknowledged by the next Qt sync
  // round. The GUI-owned mailbox then refunds the failed surface without the
  // render callback ever waiting on SharedState::mutex.
  std::atomic<std::uint64_t> tokenCopyRejectedSerial{0};
  std::shared_ptr<GlCounters> counters{std::make_shared<GlCounters>()};
  std::shared_ptr<QtGlRenderProgressState> renderProgress{
      std::make_shared<QtGlRenderProgressState>()};
  std::atomic<std::uint64_t> activeRenderNodeMask{0};
  std::array<std::atomic<std::uint64_t>, kMaximumRenderNodes>
      renderNodeSafeGeneration{};
  // target+mask are one seqlock-protected invalidation operation. Replacing
  // an older target cannot let an older node acknowledgement mutate or
  // complete the newer proof: render nodes only scan immutable snapshots.
  std::atomic<std::uint64_t> renderInvalidationVersion{0};
  std::atomic<std::uint64_t> renderInvalidationTarget{0};
  std::atomic<std::uint64_t> renderInvalidationNodeMask{0};

  void publishRenderGenerationLocked() noexcept {
    const std::uint64_t version =
        renderGenerationVersion.load(std::memory_order_relaxed);
    if (version > std::numeric_limits<std::uint64_t>::max() - 2) {
      generationOpen = false;
      renderGenerationOpen.store(false, std::memory_order_release);
      counters->latchFatalReason(
          QtGlFatalReason::ProgressSequenceExhaustion);
      return;
    }
    renderGenerationVersion.store(version + 1, std::memory_order_release);
    renderAcceptedGeneration.store(acceptedGeneration,
                                   std::memory_order_relaxed);
    renderGenerationOpen.store(generationOpen, std::memory_order_relaxed);
    renderGenerationVersion.store(version + 2, std::memory_order_release);
  }

  [[nodiscard]] bool acceptsRenderedGenerationNoexcept(
      std::uint64_t generation) noexcept {
    std::uint64_t version =
        renderGenerationVersion.load(std::memory_order_acquire);
    if ((version & 1U) != 0 ||
        !renderGenerationOpen.load(std::memory_order_relaxed) ||
        renderAcceptedGeneration.load(std::memory_order_relaxed) !=
            generation) {
      return false;
    }
    return renderGenerationVersion.compare_exchange_strong(
        version, version, std::memory_order_acq_rel,
        std::memory_order_acquire);
  }

  [[nodiscard]] bool incrementAcceptedRenderedFramesNoexcept() noexcept {
    std::uint64_t observed =
        acceptedRenderedFrames.load(std::memory_order_relaxed);
    while (observed != std::numeric_limits<std::uint64_t>::max()) {
      if (acceptedRenderedFrames.compare_exchange_weak(
              observed, observed + 1, std::memory_order_relaxed,
              std::memory_order_relaxed)) {
        return true;
      }
    }
    counters->latchFatalReason(QtGlFatalReason::ProgressSequenceExhaustion);
    return false;
  }

  [[nodiscard]] std::uint32_t registerRenderNodeNoexcept() noexcept {
    std::uint64_t observed =
        activeRenderNodeMask.load(std::memory_order_acquire);
    for (;;) {
      for (std::uint32_t index = 0; index != kMaximumRenderNodes; ++index) {
        const std::uint64_t bit = std::uint64_t{1} << index;
        if ((observed & bit) != 0) {
          continue;
        }
        if (activeRenderNodeMask.compare_exchange_weak(
                observed, observed | bit, std::memory_order_acq_rel,
                std::memory_order_acquire)) {
          // A just-created node owns no old slot. If a GUI invalidation
          // snapshot includes it before this store, the prior occupant left
          // UINT64_MAX behind and was already safe; otherwise current
          // accepted generation is the exact empty-node proof.
          renderNodeSafeGeneration[index].store(
              renderAcceptedGeneration.load(std::memory_order_acquire),
              std::memory_order_release);
          return index;
        }
        break;
      }
      if (observed == std::numeric_limits<std::uint64_t>::max()) {
        counters->latchFatalReason(
            QtGlFatalReason::ProgressSequenceExhaustion);
        return kMaximumRenderNodes;
      }
    }
  }

  void tryPublishRenderInvalidationNoexcept() noexcept {
    for (unsigned attempt = 0; attempt != 3; ++attempt) {
      const std::uint64_t before =
          renderInvalidationVersion.load(std::memory_order_acquire);
      if ((before & 1U) != 0) {
        continue;
      }
      const std::uint64_t target =
          renderInvalidationTarget.load(std::memory_order_relaxed);
      const std::uint64_t mask =
          renderInvalidationNodeMask.load(std::memory_order_relaxed);
      if (target == 0) {
        return;
      }
      bool safe = true;
      for (std::uint32_t index = 0;
           index != kMaximumRenderNodes; ++index) {
        const std::uint64_t bit = std::uint64_t{1} << index;
        if ((mask & bit) != 0 &&
            renderNodeSafeGeneration[index].load(
                std::memory_order_acquire) < target) {
          safe = false;
          break;
        }
      }
      const std::uint64_t after =
          renderInvalidationVersion.load(std::memory_order_acquire);
      if (before != after || (after & 1U) != 0) {
        continue;
      }
      if (safe && !renderProgress->publishInvalidation(target)) {
        counters->latchFatalReason(
            QtGlFatalReason::ProgressSequenceExhaustion);
      }
      return;
    }
  }

  void beginRenderInvalidationLocked(std::uint64_t generation) noexcept {
    if (generation == 0) {
      counters->latchFatalReason(
          QtGlFatalReason::ProgressSequenceExhaustion);
      return;
    }
    const std::uint64_t version =
        renderInvalidationVersion.load(std::memory_order_relaxed);
    if (version > std::numeric_limits<std::uint64_t>::max() - 2) {
      counters->latchFatalReason(
          QtGlFatalReason::ProgressSequenceExhaustion);
      return;
    }
    renderInvalidationVersion.store(version + 1,
                                    std::memory_order_release);
    renderInvalidationTarget.store(generation, std::memory_order_relaxed);
    renderInvalidationNodeMask.store(
        activeRenderNodeMask.load(std::memory_order_acquire),
        std::memory_order_relaxed);
    renderInvalidationVersion.store(version + 2,
                                    std::memory_order_release);
    tryPublishRenderInvalidationNoexcept();
  }

  void acknowledgeRenderInvalidationNoexcept(std::uint32_t nodeIndex,
                                              std::uint64_t generation)
      noexcept {
    if (nodeIndex >= kMaximumRenderNodes) {
      return;
    }
    auto& safeGeneration = renderNodeSafeGeneration[nodeIndex];
    std::uint64_t observed =
        safeGeneration.load(std::memory_order_relaxed);
    while (observed < generation &&
           !safeGeneration.compare_exchange_weak(
               observed, generation, std::memory_order_release,
               std::memory_order_relaxed)) {
    }
    tryPublishRenderInvalidationNoexcept();
  }

  void publishTrackedRejectionNoexcept(QtGlFrameIdentity identity,
                                       std::uint64_t generation,
                                       std::uint64_t timelineSerial) noexcept {
    if (identity.deliverySequence == 0 || timelineSerial == 0) {
      return;
    }
    std::uint64_t observed =
        lastRejectedTimelineSerial.load(std::memory_order_acquire);
    while (observed < timelineSerial &&
           !lastRejectedTimelineSerial.compare_exchange_weak(
               observed, timelineSerial, std::memory_order_acq_rel,
               std::memory_order_acquire)) {
    }
    if (observed >= timelineSerial) {
      return;
    }
    if (!renderProgress->publishRejection(identity, generation)) {
      counters->latchFatalReason(
          QtGlFatalReason::ProgressSequenceExhaustion);
    }
  }
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  std::atomic<bool> failNextImport{false};
  std::atomic<bool> failSecondPlaneImport{false};
  std::atomic<bool> failAfterRetirementServiceCreation{false};
  std::atomic<bool> strandRetirementService{false};
  std::atomic<bool> failNextRetirementJobReservation{false};
  std::atomic<bool> holdRetirementServiceStarting{false};
  std::atomic<bool> failAfterFenceCreation{false};
  std::atomic<bool> failNextSynchronization{false};
  std::atomic<bool> failNextUpdatePaintNode{false};
#endif
};

namespace {

class QtGlVideoNode final : public QSGRenderNode {
 public:
  explicit QtGlVideoNode(std::shared_ptr<QtGlVideoItem::SharedState> state)
      : state_(std::move(state)), counters_(state_->counters),
        retirementJob_(new (std::nothrow) RetirementJob) {
    nodeIndex_ = state_->registerRenderNodeNoexcept();
    if (nodeIndex_ == QtGlVideoItem::SharedState::kMaximumRenderNodes) {
      fatalFailure_ = true;
    } else {
      registeredRenderNode_ = true;
      state_->tryPublishRenderInvalidationNoexcept();
    }
    if (!retirementJob_) {
      fatalFailure_ = true;
      counters_->latchFatalReason(
          QtGlFatalReason::RetirementOwnershipReservation);
    }
  }

  ~QtGlVideoNode() noexcept override {
    const bool retired = retireAll();
    if (registeredRenderNode_ && retired) {
      // A destroyed node can never redraw. UINT64_MAX is the permanent
      // resource-free proof for any GUI invalidation snapshot that raced its
      // deregistration.
      state_->acknowledgeRenderInvalidationNoexcept(
          nodeIndex_, std::numeric_limits<std::uint64_t>::max());
      state_->activeRenderNodeMask.fetch_and(
          ~(std::uint64_t{1} << nodeIndex_), std::memory_order_acq_rel);
      state_->tryPublishRenderInvalidationNoexcept();
    }
  }

  void synchronize(QQuickWindow* window, const QRectF& bounds,
                   std::optional<FrameLease> latestFrame,
                   QtGlFrameIdentity latestIdentity,
                   std::uint64_t timelineSerial,
                   std::uint64_t acceptedGeneration) noexcept {
    window_ = window;
    bounds_ = bounds;
    synchronizedFrame_ = std::move(latestFrame);
    synchronizedIdentity_ = latestIdentity;
    synchronizedSerial_ = timelineSerial;
    synchronizedGeneration_ = acceptedGeneration;
  }

  void preserveAfterRejectedSynchronization(QQuickWindow* window,
                                             const QRectF& bounds,
                                             std::uint64_t acceptedGeneration,
                                             std::uint64_t rejectedSerial)
      noexcept {
    // Geometry/window changes remain observable. On the same generation, mark
    // only the failed submission serial as processed while retaining the prior
    // synchronized frame and GPU slot. A generation change must still flow
    // through renderImpl, where it suppresses and retires the stale old slot.
    window_ = window;
    bounds_ = bounds;
    synchronizedSerial_ = rejectedSerial;
    if (acceptedGeneration != synchronizedGeneration_) {
      synchronizedFrame_.reset();
      synchronizedIdentity_ = {};
      synchronizedGeneration_ = acceptedGeneration;
      requestAnotherFrame();
    } else {
      processedTimelineSerial_ = rejectedSerial;
    }
  }

  QRectF rect() const override { return bounds_; }

  RenderingFlags flags() const override {
    return BoundedRectRendering;
  }

  StateFlags changedStates() const override {
    return DepthState | StencilState | ScissorState | ColorState |
           BlendState | CullState;
  }

  void releaseResources() noexcept override {
    if (retireAll()) {
      acknowledgeAcceptedGenerationAfterRetirement();
    }
    fatalFailure_ = false;
  }

  void render(const RenderState* renderState) override {
    try {
      renderImpl(renderState);
    } catch (...) {
      fatalFailure_ = true;
      poisonQtGlSubsystem(counters_);
      counters_->latchFatalReason(QtGlFatalReason::RenderCallbackFailure);
      if (retireAll()) {
        acknowledgeAcceptedGenerationAfterRetirement();
      }
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
      counters_->latchFatalReason(QtGlFatalReason::UnsupportedGraphicsApi);
      return;
    }

    CGLContextObj cglContext = CGLGetCurrentContext();
    if (cglContext == nullptr) {
      fatalFailure_ = true;
      counters_->latchFatalReason(QtGlFatalReason::MissingCglContext);
      return;
    }
    DeferredRetirementGuard retirementGuard(this);
    std::optional<RawGlState> savedState;

#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (state_->strandRetirementService.exchange(false,
                                                  std::memory_order_relaxed)) {
      savedState.emplace(samplerObjectsSupportedFor(cglContext));
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
        savedState.emplace(samplerObjectsSupportedFor(cglContext));
      }
      deferredRetirement_ = true;
      pendingInvalidatedGeneration_ = synchronizedGeneration_;
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
        savedState.emplace(samplerObjectsSupportedFor(cglContext));
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

    // Blank/idle callbacks returned above without any GL capability query.
    // Resolve lazily now, before the first RawGlState, and cache only for this
    // exact current CGL context.
    const bool samplerObjectsSupported =
        samplerObjectsSupportedFor(cglContext);
    savedState.emplace(samplerObjectsSupported);

    QString error;
    std::optional<FrameLease> retainedForImport;
    if (synchronizedFrame_ &&
        synchronizedSerial_ != processedTimelineSerial_) {
      retainedForImport = cloneForImport(*synchronizedFrame_, &error);
      if (!retainedForImport) {
        processedTimelineSerial_ = synchronizedSerial_;
        synchronizedFrame_.reset();
        state_->publishTrackedRejectionNoexcept(
            synchronizedIdentity_, synchronizedGeneration_,
            synchronizedSerial_);
        synchronizedIdentity_ = {};
        state_->tokenCopyRejectedSerial.store(
            synchronizedSerial_, std::memory_order_release);
        counters_->rejectedFrames.fetch_add(1, std::memory_order_relaxed);
        counters_->setError(std::move(error));
        error.clear();
        requestAnotherFrame();
        if (!currentSlot_) {
          return;
        }
      }
    }

    bool retry = false;
    QtGlFatalReason resourceFailure =
        QtGlFatalReason::ResourceInitializationFailure;
    // Even after rejecting a new token copy, validate that an existing slot's
    // context-local VAO and shared textures still belong to this exact CGL
    // context/share group before drawing it. currentSlot_ implies these
    // resources already exist, so the valid old-frame path allocates nothing.
    if (!ensureResources(cglContext, &error, &retry, &resourceFailure)) {
      if (!error.isEmpty()) {
        counters_->setError(std::move(error));
      }
      if (!retry) {
        counters_->latchFatalReason(resourceFailure);
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

    if (retainedForImport) {
      const ImportResult result =
          importLatest(std::move(*retainedForImport),
                       synchronizedIdentity_, &error);
      if (result == ImportResult::Backpressure) {
        recordBackpressure();
        requestAnotherFrame();
      } else {
        processedTimelineSerial_ = synchronizedSerial_;
        if (result == ImportResult::Rejected) {
          state_->publishTrackedRejectionNoexcept(
              synchronizedIdentity_, synchronizedGeneration_,
              synchronizedSerial_);
          synchronizedIdentity_ = {};
          counters_->rejectedFrames.fetch_add(1, std::memory_order_relaxed);
          counters_->setError(std::move(error));
        } else {
          counters_->setError({});
          counters_->fatalDiagnosticPending.store(false,
                                                  std::memory_order_release);
        }
      }
    }
    if (!currentSlot_) {
      return;
    }
    draw(*currentSlot_, renderState, samplerObjectsSupported, &error);
    if (!error.isEmpty()) {
      counters_->setError(std::move(error));
      counters_->latchFatalReason(QtGlFatalReason::DrawFailure);
      fatalFailure_ = true;
    }
  }

  enum class ImportResult {
    Imported,
    Backpressure,
    Rejected,
  };

  class DeferredRetirementGuard final {
   public:
    explicit DeferredRetirementGuard(QtGlVideoNode* node) : node_(node) {}
    ~DeferredRetirementGuard() noexcept {
      if (node_->deferredRetirement_) {
        node_->deferredRetirement_ = false;
        if (node_->retireAll()) {
          node_->publishPendingInvalidationAfterRetirement();
        }
      }
    }

   private:
    QtGlVideoNode* node_;
  };

  struct Slot {
    std::array<GLuint, 2> textures{};
    GLsync fence{nullptr};
    FrameLease frame;
    QtGlFrameIdentity identity{};
    std::uint64_t timelineSerial{0};
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

  [[nodiscard]] bool samplerObjectsSupportedFor(
      CGLContextObj cglContext) noexcept {
    if (cglContext == nullptr || CGLGetCurrentContext() != cglContext) {
      return false;
    }
    if (samplerCapabilityContext_ != cglContext) {
      samplerCapabilityContext_ = cglContext;
      samplerObjectsSupported_ = currentContextSupportsSamplerObjects();
    }
    return samplerObjectsSupported_;
  }

  void resetSamplerCapability() noexcept {
    samplerCapabilityContext_ = nullptr;
    samplerObjectsSupported_ = false;
  }

  bool ensureResources(CGLContextObj cglContext, QString* error,
                       bool* retry, QtGlFatalReason* fatalReason) {
    *retry = false;
    *fatalReason = QtGlFatalReason::ResourceInitializationFailure;
    if (gQtGlSubsystemPoisoned.load(std::memory_order_acquire)) {
      *fatalReason = QtGlFatalReason::UnsafeRetirement;
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
          *fatalReason = QtGlFatalReason::UnsafeRetirement;
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
        *fatalReason = QtGlFatalReason::RetirementStartupTimeout;
        *error = QStringLiteral(
            "shared CGL retirement context startup timed out");
        poisonQtGlSubsystem(counters_);
        return false;
      }
      *retry = true;
      return false;
    }
    if (service_->state() != RetirementServiceState::Ready) {
      *fatalReason = QtGlFatalReason::RetirementStartupFailure;
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
        *fatalReason = QtGlFatalReason::RetirementOwnershipReservation;
        *error = QStringLiteral(
            "failed to reserve fail-closed CGL retirement ownership");
        return false;
      }
    }
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (state_->failAfterRetirementServiceCreation.exchange(
            false, std::memory_order_relaxed)) {
      *fatalReason = QtGlFatalReason::InjectedServiceCreationFailure;
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
        slot.identity = {};
      } else if (status == GL_WAIT_FAILED) {
        poisonQtGlSubsystem(counters_);
        unsafeRetirement_ = true;
        fatalFailure_ = true;
        counters_->latchFatalReason(
            QtGlFatalReason::RetirementFenceFailure);
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

  std::optional<FrameLease> cloneForImport(const FrameLease& frame,
                                           QString* error) {
    const CVPixelBufferRef sourcePixelBuffer = frame.pixelBuffer();
    FrameLease retainedFrame;
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    const bool injectCopyFailure =
        state_->failNextImport.exchange(false, std::memory_order_relaxed);
#else
    constexpr bool injectCopyFailure = false;
#endif
    if (!injectCopyFailure) {
      retainedFrame = FrameLease(frame);
    }
    if (!retainedFrame || retainedFrame.pixelBuffer() != sourcePixelBuffer) {
      *error = injectCopyFailure
                   ? QStringLiteral(
                         "injected Qt CGL import failure: decoded-surface "
                         "accounting token copy failed")
                   : QStringLiteral(
                         "could not clone decoded-surface accounting token "
                         "for Qt CGL import");
      return std::nullopt;
    }
    return std::optional<FrameLease>(std::in_place,
                                     std::move(retainedFrame));
  }

  ImportResult importLatest(FrameLease retainedFrame,
                            QtGlFrameIdentity identity,
                            QString* error) {
    const FrameLease& frame = retainedFrame;
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
    const bool initializeTextureParameters = !slot.initialized;
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

    // The fresh clone was verified before texture allocation. Move it into the
    // empty slot before the first CGL bind so a second-plane or draw failure
    // keeps the exact accounting token with the borrowed IOSurface through its
    // fence and shared-context retirement.
    slot.frame = std::move(retainedFrame);
    slot.identity = identity;
    slot.timelineSerial = synchronizedSerial_;
    slot.color = *color;
    IOSurfaceRef surface = slot.frame.ioSurface();
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
      if (initializeTextureParameters) {
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER,
                        GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER,
                        GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S,
                        GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T,
                        GL_CLAMP_TO_EDGE);
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        counters_->textureParameterCalls.fetch_add(4,
                                                   std::memory_order_relaxed);
#endif
      }
      const CGLError importStatus = CGLTexImageIOSurface2D(
          CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE, internalFormats[plane],
          static_cast<GLsizei>(
              CVPixelBufferGetWidthOfPlane(slot.frame.pixelBuffer(), plane)),
          static_cast<GLsizei>(
              CVPixelBufferGetHeightOfPlane(slot.frame.pixelBuffer(), plane)),
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

  void draw(std::size_t slotIndex, const RenderState* state,
            bool samplerObjectsSupported, QString* error) {
    Slot& slot = slots_[slotIndex];
    if (!slot.frame || program_ == 0 || vertexArray_ == 0 ||
        state->projectionMatrix() == nullptr || matrix() == nullptr) {
      return;
    }
    const QRectF fitted = aspectFitRect(bounds_, slot.frame);
    if (fitted.isEmpty()) {
      return;
    }

    if (!counters_->renderedIntoNonDefaultFramebuffer.load(
            std::memory_order_relaxed)) {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
      counters_->drawFramebufferBindingQueries.fetch_add(
          1, std::memory_order_relaxed);
#endif
      GLint framebuffer = 0;
      glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
      if (framebuffer != 0) {
        counters_->renderedIntoNonDefaultFramebuffer.store(
            true, std::memory_order_relaxed);
      }
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
    glBindTexture(GL_TEXTURE_RECTANGLE, slot.textures[0]);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_RECTANGLE, slot.textures[1]);
    unbindTextureSamplers(samplerObjectsSupported);

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
      counters_->latchFatalReason(QtGlFatalReason::DrawFailure);
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
      counters_->latchFatalReason(QtGlFatalReason::FenceCreationFailure);
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
    // Linearize this completed draw against flush() with lock-free atomics.
    // If flush has begun (odd version) or won the version modification order,
    // an old draw remains diagnostic renderedFrames only and cannot publish a
    // tracked acknowledgement for the newly accepted playback attempt.
    if (state_->acceptsRenderedGenerationNoexcept(
            slot.frame.timing().generation)) {
      if (!state_->incrementAcceptedRenderedFramesNoexcept()) {
        fatalFailure_ = true;
      } else if (slot.identity.deliverySequence != 0 &&
                 slot.timelineSerial != 0) {
        std::uint64_t observed =
            state_->lastPublishedDrawTimelineSerial.load(
                std::memory_order_acquire);
        while (observed < slot.timelineSerial &&
               !state_->lastPublishedDrawTimelineSerial
                    .compare_exchange_weak(
                        observed, slot.timelineSerial,
                        std::memory_order_acq_rel,
                        std::memory_order_acquire)) {
        }
        if (observed < slot.timelineSerial &&
            !state_->renderProgress->publishDraw(
                slot.identity.deliverySequence,
                slot.identity.frameSequence,
                slot.frame.timing().generation,
                slot.frame.timing().presentationTime,
                slot.frame.timing().duration)) {
          fatalFailure_ = true;
          counters_->latchFatalReason(
              QtGlFatalReason::ProgressSequenceExhaustion);
        }
      }
    }
    // Publishing the completed-frame count after the generation makes an
    // acquire snapshot that observes this draw observe its generation too.
    counters_->renderedFrames.fetch_add(1, std::memory_order_release);
  }

  [[nodiscard]] bool retireAll() noexcept {
    bool hasResources = program_ != 0 || vertexArray_ != 0;
    for (const Slot& slot : slots_) {
      hasResources = hasResources || slot.initialized || slot.frame ||
                     slot.fence != nullptr || slot.textures[0] != 0 ||
                     slot.textures[1] != 0;
    }
    std::size_t initialized = 0;
    std::unique_ptr<RetirementJob> job = std::move(retirementJob_);
    if (hasResources && !job) {
      // Resource creation is gated on this reservation. If memory corruption
      // violates that invariant, poison admission before touching ownership.
      poisonQtGlSubsystem(counters_);
      counters_->latchUnsafeRetirement();
      return false;
    }
    if (!job) {
      service_.reset();
      resetSamplerCapability();
      return true;
    }
    job->counters = counters_;
    if (hasResources) {
      // Charge while the render node still owns every resource. The charge
      // then follows the same job through queueing, destruction, or
      // fail-closed quarantine without an unowned accounting interval.
      chargeRetirementJob(*job);
    }
    job->program = std::exchange(program_, 0);
    deleteVertexArrayInExactOrigin(&vertexArray_, originContext_,
                                   CGLGetCurrentContext());
    originContext_ = nullptr;
    resetSamplerCapability();
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
      source.identity = {};
      source.timelineSerial = 0;
      destination.initialized = std::exchange(source.initialized, false);
      if (destination.initialized) {
        ++initialized;
      }
    }
    job->initializedSlotCount = initialized;
    currentSlot_.reset();
    uniforms_ = {};
    if (!hasResources) {
      service_.reset();
      return true;
    }
    if (!service_) {
      // This cannot occur after successful initialization. Retain a failed
      // bundle rather than deleting borrowed views without a compatible GL
      // context.
      counters_->retirementFailed.store(true, std::memory_order_relaxed);
      counters_->latchFatalReason(QtGlFatalReason::LostRetirementService);
      quarantineRetirementJob(job.release());
      return true;
    }
    service_->retire(job.release());
    service_.reset();
    return true;
  }

  void publishPendingInvalidationAfterRetirement() noexcept {
    if (pendingInvalidatedGeneration_ == 0) {
      return;
    }
    const std::uint64_t generation =
        std::exchange(pendingInvalidatedGeneration_, 0);
    state_->acknowledgeRenderInvalidationNoexcept(
        nodeIndex_, generation);
  }

  void acknowledgeAcceptedGenerationAfterRetirement() noexcept {
    state_->acknowledgeRenderInvalidationNoexcept(
        nodeIndex_,
        state_->renderAcceptedGeneration.load(std::memory_order_acquire));
  }

  void requestAnotherFrame() noexcept {
    try {
      if (window_ != nullptr) {
        window_->requestUpdate();
      }
    } catch (...) {
      fatalFailure_ = true;
      poisonQtGlSubsystem(counters_);
      counters_->latchFatalReason(QtGlFatalReason::UpdateRequestFailure);
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
  QtGlFrameIdentity synchronizedIdentity_{};
  std::uint64_t synchronizedSerial_{0};
  std::uint64_t synchronizedGeneration_{0};
  std::uint64_t processedTimelineSerial_{0};
  std::uint64_t lastBackpressureSerial_{0};
  std::uint64_t displayedGeneration_{0};
  std::uint64_t pendingInvalidatedGeneration_{0};
  std::uint32_t nodeIndex_{
      QtGlVideoItem::SharedState::kMaximumRenderNodes};
  std::shared_ptr<RetirementService> service_;
  std::unique_ptr<RetirementJob> retirementJob_;
  std::array<Slot, kSlotCount> slots_;
  std::optional<std::size_t> currentSlot_;
  GLuint program_{0};
  GLuint vertexArray_{0};
  CGLContextObj originContext_{nullptr};
  CGLContextObj samplerCapabilityContext_{nullptr};
  Uniforms uniforms_;
  bool samplerObjectsSupported_{false};
  bool fatalFailure_{false};
  bool deferredRetirement_{false};
  bool unsafeRetirement_{false};
  bool registeredRenderNode_{false};
};

}  // namespace

QtGlVideoItem::QtGlVideoItem(QQuickItem* parent)
    : QQuickItem(parent), state_(std::make_shared<SharedState>()) {
  setFlag(ItemHasContents, true);
}

QtGlVideoItem::~QtGlVideoItem() = default;

void QtGlVideoItem::submitFrame(FrameLease frame) {
  submitTrackedFrame(std::move(frame), {});
}

void QtGlVideoItem::submitTrackedFrame(FrameLease frame,
                                       QtGlFrameIdentity identity) {
  try {
    if (!frame) {
      state_->counters->rejectedFrames.fetch_add(1,
                                                 std::memory_order_relaxed);
      state_->counters->setError(QStringLiteral("empty native video frame"));
      return;
    }
    if ((identity.deliverySequence == 0) !=
        (identity.frameSequence == 0)) {
      state_->counters->rejectedFrames.fetch_add(1,
                                                 std::memory_order_relaxed);
      state_->counters->setError(QStringLiteral(
          "incomplete native video frame delivery identity"));
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
      if (state_->timelineSerial ==
          std::numeric_limits<std::uint64_t>::max()) {
        state_->generationOpen = false;
        state_->publishRenderGenerationLocked();
        state_->counters->latchFatalReason(
            QtGlFatalReason::ProgressSequenceExhaustion);
        return;
      }
      state_->latestFrame = std::move(frame);
      state_->counters->latestFrames.store(1, std::memory_order_release);
      state_->latestIdentity = identity;
      ++state_->timelineSerial;
      state_->synchronizationRejectedSerial = 0;
    }
    state_->counters->submittedFrames.fetch_add(1,
                                                 std::memory_order_relaxed);
    update();
  } catch (...) {
    poisonQtGlSubsystem(state_->counters);
    state_->counters->latchFatalReason(
        QtGlFatalReason::FrameSubmissionFailure);
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
      state_->counters->latestFrames.store(0, std::memory_order_release);
      state_->latestIdentity = {};
      if (state_->timelineSerial ==
          std::numeric_limits<std::uint64_t>::max()) {
        state_->generationOpen = false;
        state_->counters->latchFatalReason(
            QtGlFatalReason::ProgressSequenceExhaustion);
      } else {
        ++state_->timelineSerial;
      }
      state_->synchronizationRejectedSerial = 0;
      state_->publishRenderGenerationLocked();
      // Every currently live render node must suppress/retire its old slot.
      // With no node, prior destructors have already transferred ownership,
      // so beginRenderInvalidationLocked publishes immediately.
      state_->beginRenderInvalidationLocked(
          state_->acceptedGeneration);
    }
    update();
  } catch (...) {
    poisonQtGlSubsystem(state_->counters);
    state_->counters->latchFatalReason(
        QtGlFatalReason::GenerationFlushFailure);
    try {
      QMutexLocker lock(&state_->mutex);
      state_->generationOpen = false;
      state_->latestFrame.reset();
      state_->counters->latestFrames.store(0, std::memory_order_release);
      state_->latestIdentity = {};
      state_->publishRenderGenerationLocked();
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
    result.acceptedRenderedFrames =
        state_->acceptedRenderedFrames.load(std::memory_order_relaxed);
  }
  result.submittedFrames =
      counters.submittedFrames.load(std::memory_order_relaxed);
  result.importedFrames =
      counters.importedFrames.load(std::memory_order_relaxed);
  result.renderedFrames =
      counters.renderedFrames.load(std::memory_order_acquire);
  result.lastRenderedGeneration =
      counters.lastRenderedGeneration.load(std::memory_order_acquire);
  if (const auto draw = QtGlRenderProgressToken(state_->renderProgress)
                            .drawAfter(0)) {
    result.lastDrawSequence = draw->drawSequence;
    result.lastDrawDeliverySequence = draw->deliverySequence;
  }
  if (const auto invalidation =
          QtGlRenderProgressToken(state_->renderProgress)
              .invalidationAfter(0)) {
    result.renderInvalidationSequence = invalidation->eventSequence;
    result.renderInvalidatedGeneration = invalidation->generation;
  }
  if (const auto rejection = QtGlRenderProgressToken(state_->renderProgress)
                                 .rejectionAfter(0)) {
    result.renderRejectionSequence = rejection->eventSequence;
  }
  result.backpressuredImports =
      counters.backpressuredImports.load(std::memory_order_relaxed);
  result.rejectedFrames =
      counters.rejectedFrames.load(std::memory_order_relaxed);
  result.staleFrames = counters.staleFrames.load(std::memory_order_relaxed);
  result.destroyedResourceSets =
      counters.destroyedResourceSets.load(std::memory_order_relaxed);
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
  result.textureParameterCalls =
      counters.textureParameterCalls.load(std::memory_order_relaxed);
  result.drawFramebufferBindingQueries =
      counters.drawFramebufferBindingQueries.load(std::memory_order_relaxed);
#endif
  result.activeResourceSets =
      counters.activeResourceSets.load(std::memory_order_relaxed);
  result.peakActiveResourceSets = std::max(
      result.activeResourceSets,
      counters.peakActiveResourceSets.load(std::memory_order_relaxed));
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
  const std::uint64_t fatalEvent =
      counters.fatalErrorSerial->event.load(std::memory_order_acquire);
  const QtGlFatalReason fatalReason =
      static_cast<QtGlFatalReason>(fatalEvent & kFatalReasonMask);
  {
    QMutexLocker lock(&counters.errorMutex);
    result.lastError =
        fatalReason != QtGlFatalReason::None &&
                counters.fatalDiagnosticPending.load(std::memory_order_acquire)
            ? fatalReasonText(fatalReason)
            : counters.lastError;
  }
  result.fatalErrorSerial = fatalEvent >> kFatalSerialShift;
  return result;
}

QtGlVideoItemMemoryFacts QtGlVideoItem::memoryFacts() const noexcept {
  QtGlVideoItemMemoryFacts result;
  const auto& counters = *state_->counters;
  result.latestFrames =
      counters.latestFrames.load(std::memory_order_acquire);
  // The release that removes the last job follows resource destruction or
  // complete quarantine publication. Acquire it before sampling either
  // population so a zero-job snapshot cannot see pre-retirement state.
  result.currentRetirementJobs =
      counters.pendingRetirements.load(std::memory_order_acquire);
  result.currentResourceSets =
      counters.activeResourceSets.load(std::memory_order_relaxed);
  result.peakResourceSets = std::max(
      result.currentResourceSets,
      counters.peakActiveResourceSets.load(std::memory_order_relaxed));
  result.peakRetirementJobs = std::max(
      result.currentRetirementJobs,
      counters.peakPendingRetirements.load(std::memory_order_relaxed));
  result.quarantinedJobs =
      gQuarantinedRetirementJobs.load(std::memory_order_acquire);
  result.quarantinedFrames =
      gQuarantinedFrames.load(std::memory_order_relaxed);
  result.quarantinedResourceSets =
      gQuarantinedResourceSets.load(std::memory_order_relaxed);
  result.poisonedSubsystems =
      gQtGlSubsystemPoisoned.load(std::memory_order_acquire) ? 1U : 0U;
  return result;
}

QtGlFatalErrorSerialToken QtGlVideoItem::fatalErrorSerialToken()
    const noexcept {
  return QtGlFatalErrorSerialToken(state_->counters->fatalErrorSerial);
}

QtGlRenderProgressToken QtGlVideoItem::renderProgressToken()
    const noexcept {
  return QtGlRenderProgressToken(state_->renderProgress);
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

void QtGlVideoItem::failNextUpdatePaintNodeForTesting() {
  state_->failNextUpdatePaintNode.store(true, std::memory_order_relaxed);
}

void QtGlVideoItem::publishTrackedRejectionForTesting(
    QtGlFrameIdentity identity, std::uint64_t generation,
    std::uint64_t timelineSerial) noexcept {
  state_->publishTrackedRejectionNoexcept(identity, generation,
                                           timelineSerial);
}

void QtGlVideoItem::publishRenderInvalidationForTesting(
    std::uint64_t generation) noexcept {
  if (!state_->renderProgress->publishInvalidation(generation)) {
    state_->counters->latchFatalReason(
        QtGlFatalReason::ProgressSequenceExhaustion);
  }
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

void QtGlVideoItem::holdRetirementCompletionForTesting(bool hold) noexcept {
  state_->counters->holdRetirementCompletion.store(
      hold, std::memory_order_release);
}

bool QtGlVideoItem::retirementCompletionHeldForTesting() const noexcept {
  return state_->counters->retirementCompletionHeld.load(
      std::memory_order_acquire);
}

void QtGlVideoItem::strandRetirementServiceForTesting() {
  state_->strandRetirementService.store(true, std::memory_order_relaxed);
  update();
}

std::size_t QtGlVideoItem::quarantinedJobsForTesting() noexcept {
  return gQuarantinedRetirementJobs.load(std::memory_order_acquire);
}

std::size_t QtGlVideoItem::quarantinedResourceSetsForTesting() noexcept {
  return gQuarantinedResourceSets.load(std::memory_order_acquire);
}

std::size_t QtGlVideoItem::quarantinedFramesForTesting() noexcept {
  return gQuarantinedFrames.load(std::memory_order_acquire);
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

bool QtGlVideoItem::verifyRawGlSamplerStateForTesting(
    bool forceSamplerObjectsUnsupported) {
  CGLContextObj context = CGLGetCurrentContext();
  if (context == nullptr) {
    return false;
  }
  if (samplerObjectsSupportedByContract(3, 2, false) ||
      !samplerObjectsSupportedByContract(3, 2, true) ||
      !samplerObjectsSupportedByContract(3, 3, false) ||
      !samplerObjectsSupportedByContract(4, 1, false) ||
      !samplerObjectsSupportedByContract(3, 0, true) ||
      samplerObjectsSupportedByContract(3, 1, false)) {
    return false;
  }
  bool samplerObjectsSupported = false;
  if (!forceSamplerObjectsUnsupported) {
    // Capability discovery must not consume an error already owned by Qt (or
    // manufacture a new one from its version/extension queries).
    drainGlErrors();
    glEnable(static_cast<GLenum>(0xFFFFFFFFU));
    samplerObjectsSupported = currentContextSupportsSamplerObjects();
    if (glGetError() != GL_INVALID_ENUM || glGetError() != GL_NO_ERROR) {
      return false;
    }
  }
  drainGlErrors();

  GLint ambientActiveTexture = GL_TEXTURE0;
  glGetIntegerv(GL_ACTIVE_TEXTURE, &ambientActiveTexture);
  if (glGetError() != GL_NO_ERROR) {
    return false;
  }
  if (!samplerObjectsSupported) {
    {
      RawGlState guard(false);
      glActiveTexture(ambientActiveTexture == GL_TEXTURE0 ? GL_TEXTURE1
                                                          : GL_TEXTURE0);
      // Exercise the exact draw helper branch. It must return without calling
      // glBindSampler when sampler objects are unavailable.
      unbindTextureSamplers(false);
      if (glGetError() != GL_NO_ERROR) {
        return false;
      }
    }
    GLint restoredActiveTexture = 0;
    glGetIntegerv(GL_ACTIVE_TEXTURE, &restoredActiveTexture);
    return glGetError() == GL_NO_ERROR &&
           restoredActiveTexture == ambientActiveTexture;
  }

  std::array<GLint, 2> ambientSamplers{};
  for (std::size_t index = 0; index < ambientSamplers.size(); ++index) {
    glActiveTexture(static_cast<GLenum>(GL_TEXTURE0 + index));
    glGetIntegerv(GL_SAMPLER_BINDING, &ambientSamplers[index]);
  }
  glActiveTexture(static_cast<GLenum>(ambientActiveTexture));
  if (glGetError() != GL_NO_ERROR) {
    return false;
  }

  std::array<GLuint, 2> originalSamplers{};
  std::array<GLuint, 2> guardSamplers{};
  glGenSamplers(static_cast<GLsizei>(originalSamplers.size()),
                originalSamplers.data());
  glGenSamplers(static_cast<GLsizei>(guardSamplers.size()),
                guardSamplers.data());
  bool passed = originalSamplers[0] != 0 && originalSamplers[1] != 0 &&
                guardSamplers[0] != 0 && guardSamplers[1] != 0 &&
                glGetError() == GL_NO_ERROR;
  if (passed) {
    glBindSampler(0, originalSamplers[0]);
    glBindSampler(1, originalSamplers[1]);
    glActiveTexture(GL_TEXTURE1);
    passed = glGetError() == GL_NO_ERROR;
  }
  if (passed) {
    {
      RawGlState guard(true);
      passed = glGetError() == GL_NO_ERROR;
      glBindSampler(0, guardSamplers[0]);
      glBindSampler(1, guardSamplers[1]);
      unbindTextureSamplers(true);
      glBindSampler(0, guardSamplers[0]);
      glBindSampler(1, guardSamplers[1]);
      glActiveTexture(GL_TEXTURE0);
      passed = passed && glGetError() == GL_NO_ERROR;
    }
    GLint activeTexture = 0;
    std::array<GLint, 2> restoredSamplers{};
    glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
    for (std::size_t index = 0; index < restoredSamplers.size(); ++index) {
      glActiveTexture(static_cast<GLenum>(GL_TEXTURE0 + index));
      glGetIntegerv(GL_SAMPLER_BINDING, &restoredSamplers[index]);
    }
    glActiveTexture(static_cast<GLenum>(activeTexture));
    passed = passed && glGetError() == GL_NO_ERROR &&
             activeTexture == GL_TEXTURE1 &&
             restoredSamplers[0] == static_cast<GLint>(originalSamplers[0]) &&
             restoredSamplers[1] == static_cast<GLint>(originalSamplers[1]);
  }

  for (std::size_t index = 0; index < ambientSamplers.size(); ++index) {
    glBindSampler(static_cast<GLuint>(index),
                  static_cast<GLuint>(ambientSamplers[index]));
  }
  glActiveTexture(static_cast<GLenum>(ambientActiveTexture));
  glDeleteSamplers(static_cast<GLsizei>(guardSamplers.size()),
                   guardSamplers.data());
  glDeleteSamplers(static_cast<GLsizei>(originalSamplers.size()),
                   originalSamplers.data());
  return passed && glGetError() == GL_NO_ERROR;
}
#endif

QSGNode* QtGlVideoItem::updatePaintNode(QSGNode* oldNode,
                                        UpdatePaintNodeData*) {
  try {
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
    if (state_->failNextUpdatePaintNode.exchange(
            false, std::memory_order_relaxed)) {
      throw std::bad_alloc{};
    }
#endif
    std::optional<FrameLease> latest;
    QtGlFrameIdentity identity{};
    std::uint64_t serial = 0;
    std::uint64_t generation = 0;
    bool handoffCopyFailed = false;
    bool handoffAlreadyRejected = false;
    {
      QMutexLocker lock(&state_->mutex);
      serial = state_->timelineSerial;
      generation = state_->acceptedGeneration;
      identity = state_->latestIdentity;
      std::uint64_t rejectedSerial =
          state_->tokenCopyRejectedSerial.load(std::memory_order_acquire);
      if (rejectedSerial != 0 && rejectedSerial != serial) {
        // A newer submission/flush already displaced the rejected mailbox
        // entry. Clear only the stale acknowledgment; never touch the newer
        // frame it no longer describes.
        if (state_->tokenCopyRejectedSerial.compare_exchange_strong(
                rejectedSerial, 0, std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
          rejectedSerial = 0;
        }
      }
      if (rejectedSerial != 0 && rejectedSerial == serial) {
        // The render node already bounded this failed import and kept its prior
        // slot current. Consume the mailbox copy here, where SharedState is
        // already synchronized with the GUI thread, then acknowledge once.
        state_->latestFrame.reset();
        state_->counters->latestFrames.store(0,
                                              std::memory_order_release);
        state_->latestIdentity = {};
        state_->tokenCopyRejectedSerial.compare_exchange_strong(
            rejectedSerial, 0, std::memory_order_acq_rel,
            std::memory_order_relaxed);
      } else if (state_->synchronizationRejectedSerial == serial) {
        handoffAlreadyRejected = true;
      } else if (state_->latestFrame) {
        const CVPixelBufferRef sourcePixelBuffer =
            state_->latestFrame->pixelBuffer();
#if defined(WAM_NATIVE_GL_VIDEO_TESTING)
        const bool injectCopyFailure =
            state_->failNextSynchronization.exchange(
                false, std::memory_order_relaxed);
#else
        constexpr bool injectCopyFailure = false;
#endif
        FrameLease handoff;
        if (!injectCopyFailure) {
          handoff = FrameLease(*state_->latestFrame);
        }
        if (!handoff || handoff.pixelBuffer() != sourcePixelBuffer) {
          handoffCopyFailed = true;
          // Drop only the failed newest mailbox entry. The render node keeps
          // its prior synchronized serial/frame and its GPU resources; the
          // failed surface charge is refunded exactly once here.
          state_->latestFrame.reset();
          state_->counters->latestFrames.store(0,
                                                std::memory_order_release);
          state_->latestIdentity = {};
          state_->synchronizationRejectedSerial = serial;
          state_->publishTrackedRejectionNoexcept(identity, generation,
                                                   serial);
        } else {
          latest.emplace(std::move(handoff));
        }
      }
    }
    auto* node = static_cast<QtGlVideoNode*>(oldNode);
    if (handoffCopyFailed || handoffAlreadyRejected) {
      if (node != nullptr) {
        node->preserveAfterRejectedSynchronization(
            window(), boundingRect(), generation, serial);
      }
      if (handoffAlreadyRejected) {
        return oldNode;
      }
      state_->counters->rejectedFrames.fetch_add(1,
                                                  std::memory_order_relaxed);
      state_->counters->setError(QStringLiteral(
          "Qt OpenGL scene-graph synchronization could not clone the "
          "decoded-surface accounting token"));
      return oldNode;
    }

    // A new node can own GPU resources only after a complete, identity-checked
    // handoff clone exists. Moving the clone below cannot fail empty.
    std::unique_ptr<QtGlVideoNode> created;
    if (node == nullptr) {
      created = std::make_unique<QtGlVideoNode>(state_);
      node = created.get();
    }
    node->synchronize(window(), boundingRect(), std::move(latest), identity,
                      serial, generation);
    if (created) {
      return created.release();
    }
    return node;
  } catch (...) {
    poisonQtGlSubsystem(state_->counters);
    state_->counters->latchFatalReason(
        QtGlFatalReason::SynchronizationFailure);
    return oldNode;
  }
}

}  // namespace wam::macos
