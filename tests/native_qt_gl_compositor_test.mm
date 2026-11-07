#include "support/expect.hpp"
#include "support/process_wait.hpp"
#include "qt/macos/qt_gl_video_item.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>

#include <QColor>
#include <QEventLoop>
#include "accelerated_gl_gate.hpp"
#include <QGuiApplication>
#include <QImage>
#include <QProcess>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSurfaceFormat>
#include <QUrl>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <memory>
#include <set>
#include <thread>
#include <utility>
#include <vector>

namespace {

// Every frame carries a distinct output identity, as the native output
// adapter supplies one for each delivery.
void submitFrame(wam::macos::QtGlVideoItem* video,
                 wam::macos::FrameLease frame) {
  static std::uint64_t delivery = 1000;
  ++delivery;
  video->submitTrackedFrame(std::move(frame),
                            wam::macos::QtGlFrameIdentity{delivery, delivery});
}

struct PixelBufferCreation {
  CVPixelBufferRef buffer{nullptr};
  CVReturn status{kCVReturnError};
};

struct PixelCodes {
  std::uint16_t y{0};
  std::uint16_t cb{0};
  std::uint16_t cr{0};
};

struct ColorCase {
  const char* name{nullptr};
  OSType format{0};
  PixelCodes codes;
  CFStringRef matrix{nullptr};
  QColor expected;
  bool optionalFormat{false};
};

PixelBufferCreation tryCreateIOSurfacePixelBuffer(OSType format,
                                                  std::size_t width,
                                                  std::size_t height) {
  CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionaryRef empty = CFDictionaryCreate(
      kCFAllocatorDefault, nullptr, nullptr, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey,
                       empty);
  CFDictionarySetValue(
      attributes, kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey,
      kCFBooleanTrue);
  CFDictionarySetValue(attributes, kCVPixelBufferMetalCompatibilityKey,
                       kCFBooleanTrue);

  PixelBufferCreation creation;
  creation.status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                        format, attributes, &creation.buffer);
  CFRelease(empty);
  CFRelease(attributes);
  return creation;
}

bool isTenBit(OSType format) {
  return format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
         format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
}

void attachColorMetadata(CVPixelBufferRef buffer, CFStringRef matrix,
                         CFStringRef chromaLocation) {
  REQUIRE(buffer != nullptr);
  CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                        chromaLocation, kCVAttachmentMode_ShouldPropagate);
}

bool fillSolid(CVPixelBufferRef buffer, PixelCodes codes) {
  if (buffer == nullptr || !CVPixelBufferIsPlanar(buffer) ||
      CVPixelBufferGetPlaneCount(buffer) != 2 ||
      CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
    return false;
  }
  const bool tenBit = isTenBit(CVPixelBufferGetPixelFormatType(buffer));
  const std::uint16_t maximum = tenBit ? 1023U : 255U;
  if (codes.y > maximum || codes.cb > maximum || codes.cr > maximum) {
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return false;
  }
  const std::size_t lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0);
  const std::size_t lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0);
  const std::size_t chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1);
  const std::size_t chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1);
  const std::size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
  const std::size_t chromaStride =
      CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
  auto* luma = static_cast<std::byte*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
  auto* chroma = static_cast<std::byte*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
  REQUIRE(luma != nullptr && chroma != nullptr);
  if (tenBit) {
    const std::uint16_t yCode = static_cast<std::uint16_t>(codes.y << 6U);
    const std::uint16_t cbCode = static_cast<std::uint16_t>(codes.cb << 6U);
    const std::uint16_t crCode = static_cast<std::uint16_t>(codes.cr << 6U);
    for (std::size_t y = 0; y < lumaHeight; ++y) {
      auto* row = reinterpret_cast<std::uint16_t*>(luma + y * lumaStride);
      std::fill_n(row, lumaWidth, yCode);
    }
    for (std::size_t y = 0; y < chromaHeight; ++y) {
      auto* row = reinterpret_cast<std::uint16_t*>(chroma + y * chromaStride);
      for (std::size_t x = 0; x < chromaWidth; ++x) {
        row[x * 2] = cbCode;
        row[x * 2 + 1] = crCode;
      }
    }
  } else {
    const auto yCode = static_cast<std::uint8_t>(codes.y);
    const auto cbCode = static_cast<std::uint8_t>(codes.cb);
    const auto crCode = static_cast<std::uint8_t>(codes.cr);
    for (std::size_t y = 0; y < lumaHeight; ++y) {
      auto* row = reinterpret_cast<std::uint8_t*>(luma + y * lumaStride);
      std::fill_n(row, lumaWidth, yCode);
    }
    for (std::size_t y = 0; y < chromaHeight; ++y) {
      auto* row = reinterpret_cast<std::uint8_t*>(chroma + y * chromaStride);
      for (std::size_t x = 0; x < chromaWidth; ++x) {
        row[x * 2] = cbCode;
        row[x * 2 + 1] = crCode;
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  return true;
}

bool fillAlternatingChroma(CVPixelBufferRef buffer) {
  if (buffer == nullptr ||
      CVPixelBufferGetPixelFormatType(buffer) !=
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      !CVPixelBufferIsPlanar(buffer) ||
      CVPixelBufferGetPlaneCount(buffer) != 2 ||
      CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
    return false;
  }
  const std::size_t lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0);
  const std::size_t lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0);
  const std::size_t chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1);
  const std::size_t chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1);
  const std::size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
  const std::size_t chromaStride =
      CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
  auto* luma = static_cast<std::uint8_t*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
  auto* chroma = static_cast<std::uint8_t*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
  REQUIRE(luma != nullptr && chroma != nullptr);
  for (std::size_t y = 0; y < lumaHeight; ++y) {
    std::fill_n(luma + y * lumaStride, lumaWidth,
                static_cast<std::uint8_t>(126));
  }
  for (std::size_t y = 0; y < chromaHeight; ++y) {
    auto* row = chroma + y * chromaStride;
    for (std::size_t x = 0; x < chromaWidth; ++x) {
      row[x * 2] = static_cast<std::uint8_t>(x % 2 == 0 ? 16 : 240);
      row[x * 2 + 1] = 128;
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  return true;
}

bool spinUntil(const std::function<bool()>& predicate, int timeoutMs) {
  return waitUntil(predicate, std::chrono::milliseconds(timeoutMs), [] {
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  });
}

bool verifyRawGlSamplerStateOnRenderThread(QQuickWindow& window) {
  std::atomic<bool> complete{false};
  std::atomic<bool> passed{false};
  const QMetaObject::Connection connection = QObject::connect(
      &window, &QQuickWindow::beforeRendering, &window,
      [&] {
        if (!complete.load(std::memory_order_relaxed)) {
          passed.store(
              wam::macos::QtGlVideoItem::verifyRawGlSamplerStateForTesting() &&
                  wam::macos::QtGlVideoItem::
                      verifyRawGlSamplerStateForTesting(true),
              std::memory_order_relaxed);
          complete.store(true, std::memory_order_release);
        }
      },
      Qt::DirectConnection);
  window.requestUpdate();
  const bool invoked = spinUntil(
      [&] { return complete.load(std::memory_order_acquire); }, 5000);
  QObject::disconnect(connection);
  return invoked && passed.load(std::memory_order_relaxed);
}

QColor sampleLogicalPixel(const QImage& image, const QQuickWindow& window,
                          qreal logicalX, qreal logicalY) {
  const int x = static_cast<int>(std::floor(
      logicalX * static_cast<qreal>(image.width()) / window.width()));
  const int y = static_cast<int>(std::floor(
      logicalY * static_cast<qreal>(image.height()) / window.height()));
  return image.pixelColor(qBound(0, x, image.width() - 1),
                          qBound(0, y, image.height() - 1));
}

void checkColorNear(const QColor& actual, const QColor& expected, int tolerance,
                    const char* label) {
  if (std::abs(actual.red() - expected.red()) > tolerance ||
      std::abs(actual.green() - expected.green()) > tolerance ||
      std::abs(actual.blue() - expected.blue()) > tolerance) {
    std::cerr << label << " expected RGB(" << expected.red() << ','
              << expected.green() << ',' << expected.blue() << ") +/- "
              << tolerance << ", got RGB(" << actual.red() << ','
              << actual.green() << ',' << actual.blue() << ")\n";
    std::exit(EXIT_FAILURE);
  }
}

PixelBufferCreation solidBuffer(OSType format, PixelCodes codes,
                                CFStringRef matrix, std::size_t width = 320,
                                std::size_t height = 180) {
  PixelBufferCreation result =
      tryCreateIOSurfacePixelBuffer(format, width, height);
  if (result.status == kCVReturnSuccess && result.buffer != nullptr) {
    REQUIRE(fillSolid(result.buffer, codes));
    attachColorMetadata(result.buffer, matrix,
                        kCVImageBufferChromaLocation_Center);
  }
  return result;
}

QImage submitOwnedBufferAndGrab(wam::macos::QtGlVideoItem* video,
                                QQuickWindow* window,
                                CVPixelBufferRef ownedBuffer,
                                std::uint64_t generation = 0) {
  REQUIRE(video != nullptr && window != nullptr && ownedBuffer != nullptr);
  const auto before = video->stats();
  wam::macos::FrameTiming timing;
  timing.generation = generation;
  submitFrame(video, wam::macos::FrameLease(ownedBuffer, timing));
  CVPixelBufferRelease(ownedBuffer);
  window->requestUpdate();
  const bool presented = spinUntil(
      [&] {
        const auto current = video->stats();
        return current.importedFrames >= before.importedFrames + 1 &&
               current.renderedFrames >= before.renderedFrames + 1 &&
               current.lastError.isEmpty();
      },
      5000);
  if (!presented) {
    const auto current = video->stats();
    std::cerr << "presentation timeout: submitted=" << current.submittedFrames
              << " imported=" << current.importedFrames
              << " rendered=" << current.renderedFrames
              << " backpressure=" << current.backpressuredImports
              << " active=" << current.activeResourceSets
              << " pending=" << current.pendingRetirements << " error='"
              << current.lastError.toStdString() << "'\n";
    std::exit(EXIT_FAILURE);
  }
  QImage image = window->grabWindow();
  REQUIRE(!image.isNull());
  return image;
}

void submitOwnedBufferExpectRejected(wam::macos::QtGlVideoItem* video,
                                     QQuickWindow* window,
                                     CVPixelBufferRef ownedBuffer,
                                     const QString& expectedError) {
  const auto before = video->stats();
  submitFrame(video, wam::macos::FrameLease(ownedBuffer));
  CVPixelBufferRelease(ownedBuffer);
  window->requestUpdate();
  REQUIRE(spinUntil(
      [&] { return video->stats().lastError.contains(expectedError); }, 5000));
  REQUIRE(video->stats().importedFrames == before.importedFrames);
}

void setHostGeometry(QQuickItem* host, qreal x, qreal y, qreal width,
                     qreal height, bool clip, qreal rotation) {
  host->setX(x);
  host->setY(y);
  host->setWidth(width);
  host->setHeight(height);
  host->setClip(clip);
  host->setTransformOrigin(QQuickItem::Center);
  host->setRotation(rotation);
}

}  // namespace

int main(int argc, char** argv) {
  QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
  QSurfaceFormat format;
  format.setRenderableType(QSurfaceFormat::OpenGL);
  format.setProfile(QSurfaceFormat::CoreProfile);
  format.setVersion(3, 2);
  format.setDepthBufferSize(0);
  // Rotated Qt Quick clips use the RenderState stencil contract. The gate
  // requests it explicitly so a context with zero stencil bits cannot
  // produce a deceptively green clipping test.
  format.setStencilBufferSize(8);
  format.setAlphaBufferSize(8);
  format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
  QSurfaceFormat::setDefaultFormat(format);
  QGuiApplication application(argc, argv);
  if (const int skip = skipUnlessAcceleratedGl()) return skip;
  const QString faultPrefix = QStringLiteral("--retirement-fault=");
  const bool retirementAccountingOnly = application.arguments().contains(
      QStringLiteral("--retirement-accounting-only"));
  QString faultCase;
  for (const QString& argument : application.arguments()) {
    if (argument.startsWith(faultPrefix)) {
      faultCase = argument.mid(faultPrefix.size());
    }
  }
  if (faultCase.isEmpty() && !retirementAccountingOnly) {
    for (const QString& isolatedCase :
         {QStringLiteral("post-fence"), QStringLiteral("worker-poll"),
          QStringLiteral("synchronization"),
          QStringLiteral("update-callback")}) {
      QProcess child;
      child.setProcessChannelMode(QProcess::ForwardedChannels);
      child.start(QCoreApplication::applicationFilePath(),
                  {faultPrefix + isolatedCase});
      REQUIRE(child.waitForStarted(5000));
      REQUIRE(child.waitForFinished(30000));
      REQUIRE(child.exitStatus() == QProcess::NormalExit);
      REQUIRE(child.exitCode() == EXIT_SUCCESS);
    }
  }
  REQUIRE(
      wam::macos::QtGlVideoItem::verifyContextLocalVaoPolicyForTesting());

  QQuickWindow window;
  window.resize(400, 300);
  window.setColor(Qt::black);
  window.setPersistentSceneGraph(false);
  window.setPersistentGraphics(false);

  QQmlEngine engine;
  QQmlComponent component(&engine);
  component.setData(
      QByteArrayLiteral(R"QML(
import QtQuick
Item {
    width: 400
    height: 300
    property bool layerActive: false
    layer.enabled: layerActive
    Item {
        objectName: "host"
        width: 400
        height: 300
    }
    Rectangle {
        objectName: "overlay"
        x: 310
        y: 100
        width: 50
        height: 50
        z: 10
        color: "#80ff0000"
    }
}
)QML"),
      QUrl(QStringLiteral("qrc:/native-gl-compositor-test.qml")));
  std::unique_ptr<QObject> rootObject(component.create());
  if (!rootObject) {
    std::cerr << component.errorString().toStdString() << '\n';
    return EXIT_FAILURE;
  }
  auto* root = qobject_cast<QQuickItem*>(rootObject.get());
  auto* host = rootObject->findChild<QQuickItem*>(QStringLiteral("host"));
  REQUIRE(root != nullptr && host != nullptr);
  root->setParentItem(window.contentItem());

  auto videoOwner = std::make_unique<wam::macos::QtGlVideoItem>();
  auto* video = videoOwner.get();
  video->setParentItem(host);
  video->setSize(QSizeF(400, 300));

  if (!faultCase.isEmpty()) {
    REQUIRE(faultCase == QStringLiteral("post-fence") ||
              faultCase == QStringLiteral("worker-poll") ||
              faultCase == QStringLiteral("synchronization") ||
              faultCase == QStringLiteral("update-callback"));
    window.show();
    window.requestUpdate();
    REQUIRE(spinUntil([&] { return window.isSceneGraphInitialized(); },
                        5000));
    REQUIRE(window.rendererInterface()->graphicsApi() ==
              QSGRendererInterface::OpenGL);
    REQUIRE(verifyRawGlSamplerStateOnRenderThread(window));

    if (faultCase == QStringLiteral("post-fence")) {
      const std::size_t quarantineBefore =
          wam::macos::QtGlVideoItem::quarantinedJobsForTesting();
      const std::size_t quarantinedResourceSetsBefore =
          wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting();
      const std::size_t quarantinedFramesBefore =
          wam::macos::QtGlVideoItem::quarantinedFramesForTesting();
      const std::uint64_t transferredFencesBefore =
          video->transferredCoveringFencesForTesting();
      video->failAfterFenceCreationForTesting();
      PixelBufferCreation frame = solidBuffer(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
          kCVImageBufferYCbCrMatrix_ITU_R_709_2);
      submitFrame(video, wam::macos::FrameLease(frame.buffer));
      CVPixelBufferRelease(frame.buffer);
      window.requestUpdate();
      REQUIRE(spinUntil(
          [&] { return video->stats().fatalErrorSerial == 1; }, 5000));
      REQUIRE(spinUntil(
          [&] {
            const auto current = video->stats();
            return current.activeResourceSets == 0 &&
                   current.pendingRetirements == 0 &&
                   video->transferredCoveringFencesForTesting() ==
                       transferredFencesBefore + 1;
          },
          5000));
      const auto failed = video->stats();
      REQUIRE(failed.importedFrames == 1);
      REQUIRE(failed.renderedFrames == 0);
      REQUIRE(wam::macos::QtGlVideoItem::quarantinedJobsForTesting() ==
                quarantineBefore);
      REQUIRE(
          wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting() ==
          quarantinedResourceSetsBefore);
      REQUIRE(wam::macos::QtGlVideoItem::quarantinedFramesForTesting() ==
                quarantinedFramesBefore);
      REQUIRE(
          wam::macos::QtGlVideoItem::nativeGlSubsystemPoisonedForTesting());
      REQUIRE(video->takeFatalError().has_value());
      REQUIRE(!video->takeFatalError().has_value());
    } else if (faultCase == QStringLiteral("worker-poll")) {
      PixelBufferCreation frame = solidBuffer(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
          kCVImageBufferYCbCrMatrix_ITU_R_709_2);
      submitOwnedBufferAndGrab(video, &window, frame.buffer);
      const std::size_t quarantineBefore =
          wam::macos::QtGlVideoItem::quarantinedJobsForTesting();
      const std::size_t quarantinedResourceSetsBefore =
          wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting();
      const std::size_t quarantinedFramesBefore =
          wam::macos::QtGlVideoItem::quarantinedFramesForTesting();
      video->failNextRetirementWorkerPollForTesting();
      video->setParentItem(nullptr);
      window.requestUpdate();
      REQUIRE(spinUntil(
          [&] {
            const auto current = video->stats();
            return wam::macos::QtGlVideoItem::quarantinedJobsForTesting() ==
                       quarantineBefore + 1 &&
                   current.pendingRetirements == 0 &&
                   current.activeResourceSets > 0 &&
                   current.retirementFailed &&
                   current.fatalErrorSerial == 1 &&
                   wam::macos::QtGlVideoItem::
                       nativeGlSubsystemPoisonedForTesting();
          },
          5000));
      const auto failed = video->stats();
      REQUIRE(failed.pendingRetirements == 0);
      REQUIRE(failed.activeResourceSets > 0);
      REQUIRE(failed.retirementFailed);
      REQUIRE(failed.fatalErrorSerial == 1);
      REQUIRE(
          wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting() ==
          quarantinedResourceSetsBefore + 1);
      REQUIRE(wam::macos::QtGlVideoItem::quarantinedFramesForTesting() ==
                quarantinedFramesBefore + 1);
      REQUIRE(
          wam::macos::QtGlVideoItem::nativeGlSubsystemPoisonedForTesting());
      REQUIRE(video->takeFatalError().has_value());
      REQUIRE(!video->takeFatalError().has_value());
    } else if (faultCase == QStringLiteral("synchronization")) {
      PixelBufferCreation baseline = solidBuffer(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
          kCVImageBufferYCbCrMatrix_ITU_R_709_2);
      const QImage baselineImage =
          submitOwnedBufferAndGrab(video, &window, baseline.buffer);
      const QColor baselinePixel =
          sampleLogicalPixel(baselineImage, window, 200, 150);
      const auto before = video->stats();
      const std::uint64_t renderedBefore = before.renderedFrames;
      const auto budgetBefore = wam::macos::NativeSurfaceBudget::stats();
      video->failNextSynchronizationForTesting();
      PixelBufferCreation replacement = solidBuffer(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
          kCVImageBufferYCbCrMatrix_ITU_R_709_2);
      IOSurfaceRef replacementSurface =
          CVPixelBufferGetIOSurface(replacement.buffer);
      REQUIRE(replacementSurface != nullptr);
      const std::uint64_t replacementBytes = static_cast<std::uint64_t>(
          IOSurfaceGetAllocSize(replacementSurface));
      wam::macos::FrameLease replacementLease(replacement.buffer);
      REQUIRE(replacementLease);
      const auto budgetCharged = wam::macos::NativeSurfaceBudget::stats();
      REQUIRE(budgetCharged.currentSurfaces ==
                budgetBefore.currentSurfaces + 1);
      REQUIRE(budgetCharged.currentBytes ==
                budgetBefore.currentBytes + replacementBytes);
      CVPixelBufferRelease(replacement.buffer);
      submitFrame(video, std::move(replacementLease));
      window.requestUpdate();
      REQUIRE(spinUntil(
          [&] {
            const auto currentBudget =
                wam::macos::NativeSurfaceBudget::stats();
            const auto current = video->stats();
            return current.fatalErrorSerial == before.fatalErrorSerial &&
                   current.lastError.contains(
                       QStringLiteral("scene-graph synchronization")) &&
                   currentBudget.currentSurfaces ==
                       budgetBefore.currentSurfaces &&
                   currentBudget.currentBytes == budgetBefore.currentBytes;
          },
          5000));
      const auto failed = video->stats();
      REQUIRE(failed.importedFrames == before.importedFrames);
      REQUIRE(failed.activeResourceSets == before.activeResourceSets);
      REQUIRE(failed.peakActiveResourceSets ==
                before.peakActiveResourceSets);
      REQUIRE(failed.rejectedFrames == before.rejectedFrames + 1);
      REQUIRE(
          !wam::macos::QtGlVideoItem::nativeGlSubsystemPoisonedForTesting());
      REQUIRE(!video->takeFatalError().has_value());
      for (int retry = 0; retry < 3; ++retry) {
        window.requestUpdate();
        REQUIRE(!window.grabWindow().isNull());
      }
      const auto bounded = video->stats();
      REQUIRE(bounded.fatalErrorSerial == failed.fatalErrorSerial);
      REQUIRE(bounded.rejectedFrames == failed.rejectedFrames);
      REQUIRE(bounded.importedFrames == failed.importedFrames);
      REQUIRE(bounded.activeResourceSets == failed.activeResourceSets);
      REQUIRE(bounded.renderedFrames > renderedBefore);
      const QImage preservedImage = window.grabWindow();
      REQUIRE(!preservedImage.isNull());
      checkColorNear(sampleLogicalPixel(preservedImage, window, 200, 150),
                     baselinePixel, 2,
                     "frame after CGL synchronization token-copy failure");

      // A rejected handoff on a newer generation must never preserve or redraw
      // the stale old-generation slot. The same rejection remains nonfatal and
      // refunds the new surface exactly once while renderImpl retires the old
      // slot through its existing fence path.
      const auto beforeGenerationFailure = video->stats();
      const auto budgetBeforeGenerationFailure =
          wam::macos::NativeSurfaceBudget::stats();
      const std::uint64_t renderedBeforeGenerationFailure =
          beforeGenerationFailure.renderedFrames;
      video->flush(1);
      video->failNextSynchronizationForTesting();
      PixelBufferCreation nextGeneration = solidBuffer(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
          kCVImageBufferYCbCrMatrix_ITU_R_709_2);
      wam::macos::FrameTiming nextGenerationTiming;
      nextGenerationTiming.generation = 1;
      wam::macos::FrameLease nextGenerationLease(nextGeneration.buffer,
                                                 nextGenerationTiming);
      REQUIRE(nextGenerationLease);
      CVPixelBufferRelease(nextGeneration.buffer);
      submitFrame(video, std::move(nextGenerationLease));
      window.requestUpdate();
      REQUIRE(spinUntil(
          [&] {
            const auto current = video->stats();
            return current.acceptedGeneration == 1 &&
                   current.rejectedFrames ==
                       beforeGenerationFailure.rejectedFrames + 1 &&
                   current.activeResourceSets == 0 &&
                   current.pendingRetirements == 0 &&
                   wam::macos::NativeSurfaceBudget::stats().currentSurfaces ==
                       0 &&
                   wam::macos::NativeSurfaceBudget::stats().currentBytes == 0;
          },
          5000));
      const auto generationFailure = video->stats();
      REQUIRE(generationFailure.importedFrames ==
                beforeGenerationFailure.importedFrames);
      REQUIRE(generationFailure.acceptedRenderedFrames ==
                beforeGenerationFailure.acceptedRenderedFrames);
      REQUIRE(generationFailure.renderedFrames ==
                renderedBeforeGenerationFailure);
      REQUIRE(generationFailure.fatalErrorSerial ==
                beforeGenerationFailure.fatalErrorSerial);
      REQUIRE(budgetBeforeGenerationFailure.currentSurfaces > 0);
      REQUIRE(budgetBeforeGenerationFailure.currentBytes > 0);
      REQUIRE(!video->takeFatalError().has_value());
      video->setParentItem(nullptr);
      window.requestUpdate();
      REQUIRE(spinUntil(
          [&] {
            const auto current = video->stats();
            return current.activeResourceSets == 0 &&
                   current.pendingRetirements == 0;
          },
          5000));
    } else {
      // Throw at the Qt updatePaintNode callback boundary before any handoff or
      // GL allocation. The callback must return the old node, publish one
      // fixed fatal event without allocating, and leave no ambiguous
      // retirement owner behind.
      const std::size_t quarantineBefore =
          wam::macos::QtGlVideoItem::quarantinedJobsForTesting();
      const std::size_t quarantinedResourceSetsBefore =
          wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting();
      const std::size_t quarantinedFramesBefore =
          wam::macos::QtGlVideoItem::quarantinedFramesForTesting();
      video->failNextUpdatePaintNodeForTesting();
      PixelBufferCreation frame = solidBuffer(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
          kCVImageBufferYCbCrMatrix_ITU_R_709_2);
      submitFrame(video, wam::macos::FrameLease(frame.buffer));
      CVPixelBufferRelease(frame.buffer);
      window.requestUpdate();
      REQUIRE(spinUntil(
          [&] { return video->stats().fatalErrorSerial == 1; }, 5000));
      const auto failed = video->stats();
      REQUIRE(failed.importedFrames == 0);
      REQUIRE(failed.activeResourceSets == 0);
      REQUIRE(failed.pendingRetirements == 0);
      REQUIRE(failed.lastError.contains(
          QStringLiteral("scene-graph synchronization")));
      REQUIRE(wam::macos::QtGlVideoItem::quarantinedJobsForTesting() ==
                quarantineBefore);
      REQUIRE(
          wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting() ==
          quarantinedResourceSetsBefore);
      REQUIRE(wam::macos::QtGlVideoItem::quarantinedFramesForTesting() ==
                quarantinedFramesBefore);
      REQUIRE(
          wam::macos::QtGlVideoItem::nativeGlSubsystemPoisonedForTesting());
      REQUIRE(video->takeFatalError().has_value());
      REQUIRE(!video->takeFatalError().has_value());
    }

    videoOwner.reset();
    window.hide();
    window.releaseResources();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
    std::cout << "Qt OpenGL retirement fault case passed: "
              << faultCase.toStdString() << '\n';
    return EXIT_SUCCESS;
  }

  window.show();
  window.requestUpdate();
  REQUIRE(spinUntil([&] { return window.isSceneGraphInitialized(); }, 5000));
  REQUIRE(window.rendererInterface()->graphicsApi() ==
            QSGRendererInterface::OpenGL);
  REQUIRE(verifyRawGlSamplerStateOnRenderThread(window));
  REQUIRE(wam::macos::QtGlFatalErrorSerialToken{}.load() == 0);
  const auto blankStats = video->stats();
  const auto blankMemory = video->memoryFacts();
  const auto fatalSerialToken = video->fatalErrorSerialToken();
  REQUIRE(blankStats.submittedFrames == 0);
  REQUIRE(blankStats.renderedFrames == 0);
  REQUIRE(blankStats.lastRenderedGeneration == 0);
  REQUIRE(blankStats.acceptedGeneration == 0);
  REQUIRE(blankStats.acceptedRenderedFrames == 0);
  REQUIRE(blankStats.fatalErrorSerial == 0);
  REQUIRE(fatalSerialToken.load() == 0);
  REQUIRE(blankStats.textureParameterCalls == 0);
  REQUIRE(blankStats.drawFramebufferBindingQueries == 0);
  REQUIRE(blankStats.activeResourceSets == 0);
  REQUIRE(blankMemory.latestFrames == 0);
  REQUIRE(blankMemory.currentResourceSets == 0);
  REQUIRE(blankMemory.peakResourceSets == 0);
  REQUIRE(blankMemory.currentRetirementJobs == 0);
  REQUIRE(blankMemory.peakRetirementJobs == 0);
  REQUIRE(blankMemory.quarantinedFrames == 0);
  REQUIRE(blankMemory.quarantinedResourceSets == 0);
  REQUIRE(blankMemory.quarantinedJobs == 0);
  REQUIRE(blankMemory.poisonedSubsystems == 0);
  REQUIRE(!blankStats.textureRectangleSupported);
  REQUIRE(!blankStats.acceleratedContext);
  REQUIRE(!video->takeFatalError().has_value());
  REQUIRE(wam::macos::QtGlVideoItem::retirementServiceCountForTesting() <=
            wam::macos::QtGlVideoItem::retirementServiceCapacityForTesting());
  REQUIRE(
      wam::macos::QtGlVideoItem::retirementServiceCapacityForTesting() == 4);
  REQUIRE(!wam::macos::QtGlVideoItem::nativeGlSubsystemPoisonedForTesting());

  // Retirement-context startup is observed asynchronously. Mask readiness
  // after service creation and prove the render path returns without
  // allocating resources or importing the retained frame; unmasking resumes
  // on a later scene-graph pass without a render-thread wait.
  auto startingOwner = std::make_unique<wam::macos::QtGlVideoItem>();
  auto* startingItem = startingOwner.get();
  startingItem->setParentItem(host);
  startingItem->setSize(QSizeF(400, 300));
  startingItem->holdRetirementServiceStartingForTesting(true);
  PixelBufferCreation startingFrame = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitFrame(startingItem, wam::macos::FrameLease(startingFrame.buffer));
  CVPixelBufferRelease(startingFrame.buffer);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        return wam::macos::QtGlVideoItem::retirementServiceCountForTesting() >
               0;
      },
      5000));
  for (int retry = 0; retry < 3; ++retry) {
    window.requestUpdate();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
  }
  REQUIRE(startingItem->stats().importedFrames == 0);
  REQUIRE(startingItem->stats().activeResourceSets == 0);
  startingItem->holdRetirementServiceStartingForTesting(false);
  REQUIRE(spinUntil(
      [&] { return startingItem->stats().importedFrames == 1; }, 5000));
  startingItem->setParentItem(nullptr);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = startingItem->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  startingOwner.reset();

  // Fail after the shared retirement context exists but before shaders/VAO or
  // plane textures do. Removing the node must clear that empty attachment so
  // a recreated node can retry instead of spinning on stale context identity.
  const auto beforeEmptyInitFailure = video->stats();
  video->failAfterRetirementServiceCreationForTesting();
  PixelBufferCreation emptyInitFailure = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitFrame(video, wam::macos::FrameLease(emptyInitFailure.buffer));
  CVPixelBufferRelease(emptyInitFailure.buffer);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.fatalErrorSerial ==
                   beforeEmptyInitFailure.fatalErrorSerial + 1 &&
               current.lastError.contains(
                   QStringLiteral("retirement service creation"));
      },
      5000));
  const auto emptyInitFailureStats = video->stats();
  REQUIRE(fatalSerialToken.load() ==
            emptyInitFailureStats.fatalErrorSerial);
  REQUIRE(emptyInitFailureStats.activeResourceSets == 0);
  REQUIRE(emptyInitFailureStats.importedFrames == 0);
  REQUIRE(emptyInitFailureStats.renderedFrames ==
            beforeEmptyInitFailure.renderedFrames);
  REQUIRE(emptyInitFailureStats.lastRenderedGeneration ==
            beforeEmptyInitFailure.lastRenderedGeneration);
  auto fatalError = video->takeFatalError();
  REQUIRE(fatalError.has_value());
  REQUIRE(fatalError->contains(
      QStringLiteral("retirement service creation")));
  REQUIRE(!video->takeFatalError().has_value());
  REQUIRE(video->stats().fatalErrorSerial ==
            emptyInitFailureStats.fatalErrorSerial);
  REQUIRE(fatalSerialToken.load() ==
            emptyInitFailureStats.fatalErrorSerial);
  // Taking an event must not make the same terminal node failure look new on
  // subsequent render requests.
  for (int repeat = 0; repeat < 3; ++repeat) {
    window.requestUpdate();
    REQUIRE(!window.grabWindow().isNull());
  }
  REQUIRE(video->stats().fatalErrorSerial ==
            emptyInitFailureStats.fatalErrorSerial);
  REQUIRE(!video->takeFatalError().has_value());
  video->setParentItem(nullptr);
  window.requestUpdate();
  REQUIRE(!window.grabWindow().isNull());
  video->setParentItem(host);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.importedFrames == 1 && current.renderedFrames > 0 &&
               current.lastError.isEmpty();
      },
      5000));
  REQUIRE(video->stats().lastRenderedGeneration == 0);
  REQUIRE(video->stats().fatalErrorSerial ==
            emptyInitFailureStats.fatalErrorSerial);
  REQUIRE(!video->takeFatalError().has_value());

  // The retirement node for the next GL resource lifetime is allocated
  // before any shader, texture, fence, or FrameLease can exist. Failure to
  // reserve it rejects that attempt with zero active resources, and a fresh
  // scene-graph node can recover without quarantining an IOSurface.
  auto reservationOwner = std::make_unique<wam::macos::QtGlVideoItem>();
  auto* reservationItem = reservationOwner.get();
  reservationItem->setParentItem(host);
  reservationItem->setSize(QSizeF(400, 300));
  PixelBufferCreation reservationFrame = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(reservationItem, &window,
                           reservationFrame.buffer);
  reservationItem->flush(1);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = reservationItem->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  const std::size_t reservationQuarantineBefore =
      wam::macos::QtGlVideoItem::quarantinedJobsForTesting();
  const std::size_t reservationResourceSetsBefore =
      wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting();
  const std::size_t reservationFramesBefore =
      wam::macos::QtGlVideoItem::quarantinedFramesForTesting();
  reservationItem->failNextRetirementJobReservationForTesting();
  PixelBufferCreation reservationRetry = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming reservationRetryTiming;
  reservationRetryTiming.generation = 1;
  submitFrame(reservationItem, wam::macos::FrameLease(
      reservationRetry.buffer, reservationRetryTiming));
  CVPixelBufferRelease(reservationRetry.buffer);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = reservationItem->stats();
        return current.fatalErrorSerial == 1 &&
               current.activeResourceSets == 0 &&
               current.lastError.contains(
                   QStringLiteral("retirement ownership"));
      },
      5000));
  REQUIRE(reservationItem->takeFatalError().has_value());
  REQUIRE(wam::macos::QtGlVideoItem::quarantinedJobsForTesting() ==
            reservationQuarantineBefore);
  REQUIRE(
      wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting() ==
      reservationResourceSetsBefore);
  REQUIRE(wam::macos::QtGlVideoItem::quarantinedFramesForTesting() ==
            reservationFramesBefore);
  reservationItem->setParentItem(nullptr);
  window.requestUpdate();
  REQUIRE(!window.grabWindow().isNull());
  reservationItem->setParentItem(host);
  reservationItem->setSize(QSizeF(400, 300));
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] { return reservationItem->stats().lastRenderedGeneration == 1; },
      5000));
  reservationItem->setParentItem(nullptr);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = reservationItem->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  reservationOwner.reset();

  const std::array<ColorCase, 8> colorCases{{
      {"NV12 video BT.601",
       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
       {80, 112, 216}, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
       QColor(215, 9, 42), false},
      {"NV12 video BT.709",
       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
       {80, 112, 216}, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
       QColor(232, 31, 41), false},
      {"NV12 full BT.601", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
       {80, 112, 216}, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
       QColor(203, 23, 52), false},
      {"NV12 full BT.709", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
       {80, 112, 216}, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
       QColor(219, 42, 50), false},
      {"P010 video BT.601",
       kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
       {320, 448, 864}, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
       QColor(215, 9, 42), true},
      {"P010 video BT.709",
       kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
       {320, 448, 864}, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
       QColor(232, 31, 41), true},
      {"P010 full BT.601", kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
       {321, 449, 865}, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
       QColor(203, 23, 52), true},
      {"P010 full BT.709", kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
       {321, 449, 865}, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
       QColor(219, 42, 51), true},
  }};

  int p010VideoCases = 0;
  int p010FullCases = 0;
  for (const ColorCase& colorCase : colorCases) {
    PixelBufferCreation creation = solidBuffer(
        colorCase.format, colorCase.codes, colorCase.matrix);
    if (creation.status != kCVReturnSuccess || creation.buffer == nullptr) {
      if (!colorCase.optionalFormat) {
        std::cerr << colorCase.name << " allocation failed with CoreVideo "
                  << creation.status << '\n';
        return EXIT_FAILURE;
      }
      continue;
    }
    const QImage image =
        submitOwnedBufferAndGrab(video, &window, creation.buffer);
    checkColorNear(sampleLogicalPixel(image, window, 40, 100),
                   colorCase.expected, 5, colorCase.name);
    if (colorCase.format ==
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
      ++p010VideoCases;
    } else if (colorCase.format ==
               kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
      ++p010FullCases;
    }
  }
  REQUIRE(p010VideoCases == 2);
  REQUIRE(p010FullCases == 0 || p010FullCases == 2);

  PixelBufferCreation white = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  REQUIRE(white.buffer != nullptr);
  QImage image = submitOwnedBufferAndGrab(video, &window, white.buffer);
  checkColorNear(sampleLogicalPixel(image, window, 20, 15), QColor(0, 0, 0),
                 4, "letterbox");
  checkColorNear(sampleLogicalPixel(image, window, 40, 100),
                 QColor(255, 255, 255), 4, "white video");
  checkColorNear(sampleLogicalPixel(image, window, 335, 125),
                 QColor(255, 127, 127), 6, "translucent QML overlay");

  video->setOpacity(0.5);
  window.requestUpdate();
  image = window.grabWindow();
  REQUIRE(!image.isNull());
  checkColorNear(sampleLogicalPixel(image, window, 40, 100),
                 QColor(128, 128, 128), 6, "premultiplied item opacity");
  video->setOpacity(1.0);

  PixelBufferCreation centered = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, 4);
  REQUIRE(centered.buffer != nullptr && fillAlternatingChroma(centered.buffer));
  attachColorMetadata(centered.buffer,
                      kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Center);
  image = submitOwnedBufferAndGrab(video, &window, centered.buffer);
  checkColorNear(sampleLogicalPixel(image, window, 75, 125),
                 QColor(128, 140, 10), 7, "center-sited chroma");

  PixelBufferCreation left = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, 4);
  REQUIRE(left.buffer != nullptr && fillAlternatingChroma(left.buffer));
  attachColorMetadata(left.buffer, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Left);
  image = submitOwnedBufferAndGrab(video, &window, left.buffer);
  checkColorNear(sampleLogicalPixel(image, window, 75, 125),
                 QColor(128, 128, 128), 7, "left-sited chroma");

  // The BT.2020 non-constant-luminance matrix is admitted: the matrix
  // decision is stated once for every presentation route in
  // native_video_color.hpp, so this route cannot refuse what the layer route
  // plays. An unrecognized explicit matrix is still refused, which bounds the
  // admission.
  PixelBufferCreation bt2020 = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_2020);
  static_cast<void>(submitOwnedBufferAndGrab(video, &window, bt2020.buffer));
  PixelBufferCreation unknownMatrix = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_SMPTE_240M_1995);
  const auto beforeMetadataFailure = video->stats();
  submitOwnedBufferExpectRejected(video, &window, unknownMatrix.buffer,
                                  QStringLiteral("YCbCr matrix"));
  REQUIRE(video->stats().fatalErrorSerial ==
            beforeMetadataFailure.fatalErrorSerial);
  PixelBufferCreation topLeft = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  CVBufferSetAttachment(topLeft.buffer,
                        kCVImageBufferChromaLocationTopFieldKey,
                        kCVImageBufferChromaLocation_TopLeft,
                        kCVAttachmentMode_ShouldPropagate);
  submitOwnedBufferExpectRejected(video, &window, topLeft.buffer,
                                  QStringLiteral("chroma siting"));
  // Unsupported per-frame metadata is recoverable input rejection rather
  // than a terminal presenter failure.
  REQUIRE(video->stats().fatalErrorSerial ==
            beforeMetadataFailure.fatalErrorSerial);
  REQUIRE(!video->takeFatalError().has_value());

  // Restore a known good frame after the deliberate metadata failures.
  PixelBufferCreation restoredWhite = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(video, &window, restoredWhite.buffer);
  REQUIRE(video->stats().fatalErrorSerial ==
            beforeMetadataFailure.fatalErrorSerial);
  REQUIRE(!video->takeFatalError().has_value());

  // Parent translation proves projection * item transform rather than a draw
  // in window coordinates.
  setHostGeometry(host, 50, 40, 200, 150, false, 0);
  video->setX(0);
  video->setY(0);
  video->setSize(QSizeF(200, 150));
  window.requestUpdate();
  image = window.grabWindow();
  checkColorNear(sampleLogicalPixel(image, window, 120, 100),
                 QColor(255, 255, 255), 5, "transformed video interior");
  checkColorNear(sampleLogicalPixel(image, window, 20, 100), QColor(0, 0, 0),
                 5, "transformed video exterior");

  // Axis-aligned clips use Qt's scissor state.
  setHostGeometry(host, 100, 80, 120, 100, true, 0);
  video->setX(-100);
  video->setY(-80);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  image = window.grabWindow();
  checkColorNear(sampleLogicalPixel(image, window, 150, 130),
                 QColor(255, 255, 255), 5, "scissor clip interior");
  checkColorNear(sampleLogicalPixel(image, window, 60, 130), QColor(0, 0, 0),
                 5, "scissor clip exterior");
  REQUIRE(video->stats().sawScissorClip);

  // A rotated clipping ancestor forces Qt's stencil clip path.
  setHostGeometry(host, 140, 90, 120, 100, true, 25);
  video->setX(-80);
  video->setY(-80);
  video->setSize(QSizeF(280, 260));
  window.requestUpdate();
  image = window.grabWindow();
  checkColorNear(sampleLogicalPixel(image, window, 200, 140),
                 QColor(255, 255, 255), 7, "stencil clip interior");
  checkColorNear(sampleLogicalPixel(image, window, 110, 65), QColor(0, 0, 0),
                 7, "stencil clip exterior");
  REQUIRE(video->stats().sawStencilClip);

  setHostGeometry(host, 0, 0, 400, 300, false, 0);
  video->setX(0);
  video->setY(0);
  video->setSize(QSizeF(400, 300));
  REQUIRE(root->setProperty("layerActive", true));
  window.requestUpdate();
  image = window.grabWindow();
  REQUIRE(!image.isNull());
  auto stats = video->stats();
  REQUIRE(stats.textureRectangleSupported);
  REQUIRE(stats.textureRgSupported);
  REQUIRE(stats.acceleratedContext);
  REQUIRE(stats.exactSourceIOSurface);
  REQUIRE(stats.renderedIntoNonDefaultFramebuffer);
  REQUIRE(!stats.retirementFailed);
  REQUIRE(stats.peakActiveResourceSets <= 2);
  REQUIRE(root->setProperty("layerActive", false));
  window.requestUpdate();
  REQUIRE(!window.grabWindow().isNull());

  // Two simultaneous items must retain and sample distinct IOSurfaces.
  // Keep the layer active so the fresh item's first draw observes a known
  // non-default target. Its persistent texture parameters and framebuffer
  // proof must then remain latched across retained-frame redraws.
  REQUIRE(root->setProperty("layerActive", true));
  window.requestUpdate();
  REQUIRE(!window.grabWindow().isNull());
  video->setWidth(200);
  auto secondOwner = std::make_unique<wam::macos::QtGlVideoItem>();
  auto* second = secondOwner.get();
  second->setParentItem(host);
  second->setX(200);
  second->setSize(QSizeF(200, 300));
  PixelBufferCreation red = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  image = submitOwnedBufferAndGrab(second, &window, red.buffer);
  checkColorNear(sampleLogicalPixel(image, window, 100, 150),
                 QColor(255, 255, 255), 5, "first native GL item");
  checkColorNear(sampleLogicalPixel(image, window, 280, 150),
                 QColor(232, 31, 41), 5, "second native GL item");
  const auto secondInitialStats = second->stats();
  REQUIRE(secondInitialStats.textureParameterCalls == 8);
  REQUIRE(secondInitialStats.drawFramebufferBindingQueries == 1);
  REQUIRE(secondInitialStats.renderedIntoNonDefaultFramebuffer);
  PixelBufferCreation secondRefresh = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitFrame(second, wam::macos::FrameLease(secondRefresh.buffer));
  CVPixelBufferRelease(secondRefresh.buffer);
  REQUIRE(spinUntil(
      [&] {
        // A retained render node is otherwise clean; drive a real geometry
        // update until the newly submitted surface has been imported.
        second->setOpacity(second->opacity() == 1.0 ? 0.999 : 1.0);
        window.requestUpdate();
        static_cast<void>(window.grabWindow());
        return second->stats().importedFrames >
               secondInitialStats.importedFrames;
      },
      5000));
  const auto secondRedrawStats = second->stats();
  REQUIRE(secondRedrawStats.importedFrames ==
            secondInitialStats.importedFrames + 1);
  REQUIRE(secondRedrawStats.textureParameterCalls == 16);
  REQUIRE(secondRedrawStats.drawFramebufferBindingQueries == 1);

  // Wait for one of the two persistent slots to become reusable, then submit
  // another real surface. Import/draw must advance without configuring a
  // third texture pair or re-querying the latched framebuffer fact.
  PixelBufferCreation secondReuse = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitFrame(second, wam::macos::FrameLease(secondReuse.buffer));
  CVPixelBufferRelease(secondReuse.buffer);
  REQUIRE(spinUntil(
      [&] {
        second->setOpacity(second->opacity() == 1.0 ? 0.999 : 1.0);
        window.requestUpdate();
        static_cast<void>(window.grabWindow());
        return second->stats().importedFrames >
               secondRedrawStats.importedFrames;
      },
      5000));
  const auto secondReuseStats = second->stats();
  REQUIRE(secondReuseStats.importedFrames ==
            secondRedrawStats.importedFrames + 1);
  REQUIRE(secondReuseStats.textureParameterCalls == 16);
  REQUIRE(secondReuseStats.drawFramebufferBindingQueries == 1);

  second->setParentItem(nullptr);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = second->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  secondOwner.reset();
  video->setWidth(400);
  REQUIRE(root->setProperty("layerActive", false));
  window.requestUpdate();
  REQUIRE(!window.grabWindow().isNull());

  // Rapid distinct surfaces exercise the two persistent slots. A third frame
  // may backpressure briefly but no third imported texture set or lease is
  // allocated.
  std::set<IOSurfaceID> surfaceIds;
  std::vector<CVPixelBufferRef> retainedDistinctBuffers;
  for (int index = 0; index < 12; ++index) {
    PixelBufferCreation gray = solidBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        {static_cast<std::uint16_t>(32 + index * 12), 128, 128},
        kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    REQUIRE(gray.buffer != nullptr);
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(gray.buffer);
    REQUIRE(surface != nullptr);
    REQUIRE(surfaceIds.insert(IOSurfaceGetID(surface)).second);
    CVPixelBufferRetain(gray.buffer);
    retainedDistinctBuffers.push_back(gray.buffer);
    submitOwnedBufferAndGrab(video, &window, gray.buffer);
    const auto current = video->stats();
    const auto currentMemory = video->memoryFacts();
    REQUIRE(current.activeResourceSets <= 2);
    REQUIRE(current.pendingRetirements == 0);
    REQUIRE(currentMemory.latestFrames == 1);
    REQUIRE(currentMemory.currentResourceSets ==
              current.activeResourceSets);
    REQUIRE(currentMemory.peakResourceSets <= 2);
    REQUIRE(currentMemory.currentRetirementJobs == 0);
  }
  for (CVPixelBufferRef retained : retainedDistinctBuffers) {
    CVPixelBufferRelease(retained);
  }
  REQUIRE(video->stats().peakActiveResourceSets <= 2);

  // Deterministic frame rejection remains recoverable and does not replace
  // the current good frame, grow the resource ring, or publish a fatal event.
  const QImage beforeFailureImage = window.grabWindow();
  REQUIRE(!beforeFailureImage.isNull());
  const QColor beforeFailurePixel =
      sampleLogicalPixel(beforeFailureImage, window, 200, 150);
  const auto beforeFailure = video->stats();
  const auto budgetBeforeFailure =
      wam::macos::NativeSurfaceBudget::stats();
  video->failNextImportForTesting();
  PixelBufferCreation failed = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  IOSurfaceRef failedSurface = CVPixelBufferGetIOSurface(failed.buffer);
  REQUIRE(failedSurface != nullptr);
  const std::uint64_t failedSurfaceBytes =
      static_cast<std::uint64_t>(IOSurfaceGetAllocSize(failedSurface));
  wam::macos::FrameLease failedLease(failed.buffer);
  REQUIRE(failedLease);
  const auto chargedFailureBudget =
      wam::macos::NativeSurfaceBudget::stats();
  REQUIRE(chargedFailureBudget.currentSurfaces ==
            budgetBeforeFailure.currentSurfaces + 1);
  REQUIRE(chargedFailureBudget.currentBytes ==
            budgetBeforeFailure.currentBytes + failedSurfaceBytes);
  CVPixelBufferRelease(failed.buffer);
  submitFrame(video, std::move(failedLease));
  window.requestUpdate();
  const bool injectedImportObserved = spinUntil(
      [&] {
        video->setWidth(video->width() == 400.0 ? 399.0 : 400.0);
        window.requestUpdate();
        static_cast<void>(window.grabWindow());
        const auto current = video->stats();
        return current.fatalErrorSerial == beforeFailure.fatalErrorSerial &&
               current.lastError.contains(
                   QStringLiteral("injected Qt CGL import failure")) &&
               wam::macos::NativeSurfaceBudget::stats().currentSurfaces <=
                   budgetBeforeFailure.currentSurfaces &&
               wam::macos::NativeSurfaceBudget::stats().currentBytes <=
                   budgetBeforeFailure.currentBytes;
      },
      5000);
  if (!injectedImportObserved) {
    const auto current = video->stats();
    const auto budget = wam::macos::NativeSurfaceBudget::stats();
    std::cerr << "injected import timeout: imported="
              << current.importedFrames << " rejected="
              << current.rejectedFrames << " active="
              << current.activeResourceSets << " pending="
              << current.pendingRetirements << " surfaces="
              << budget.currentSurfaces << '/'
              << budgetBeforeFailure.currentSurfaces << " bytes="
              << budget.currentBytes << '/' << budgetBeforeFailure.currentBytes
              << " error='" << current.lastError.toStdString() << "'\n";
  }
  REQUIRE(injectedImportObserved);
  video->setWidth(400.0);
  const auto failedImportStats = video->stats();
  REQUIRE(failedImportStats.importedFrames ==
            beforeFailure.importedFrames);
  REQUIRE(failedImportStats.lastRenderedGeneration ==
            beforeFailure.lastRenderedGeneration);
  REQUIRE(failedImportStats.activeResourceSets ==
            beforeFailure.activeResourceSets);
  REQUIRE(failedImportStats.peakActiveResourceSets ==
            beforeFailure.peakActiveResourceSets);
  REQUIRE(failedImportStats.rejectedFrames ==
            beforeFailure.rejectedFrames + 1);
  REQUIRE(!video->takeFatalError().has_value());
  REQUIRE(video->stats().fatalErrorSerial ==
            beforeFailure.fatalErrorSerial);
  for (int retry = 0; retry < 3; ++retry) {
    window.requestUpdate();
    REQUIRE(!window.grabWindow().isNull());
  }
  const auto boundedImportStats = video->stats();
  REQUIRE(boundedImportStats.importedFrames ==
            failedImportStats.importedFrames);
  REQUIRE(boundedImportStats.rejectedFrames ==
            failedImportStats.rejectedFrames);
  REQUIRE(boundedImportStats.activeResourceSets ==
            failedImportStats.activeResourceSets);
  const QImage afterFailureImage = window.grabWindow();
  REQUIRE(!afterFailureImage.isNull());
  checkColorNear(sampleLogicalPixel(afterFailureImage, window, 200, 150),
                 beforeFailurePixel, 2,
                 "frame after CGL import token-copy failure");

  const auto beforePartialFailure = video->stats();
  const auto renderProgress = video->renderProgressToken();
  REQUIRE(!renderProgress.drawAfter(beforePartialFailure.lastDrawSequence)
                 .has_value());
  REQUIRE(!renderProgress
                 .rejectionAfter(beforePartialFailure.renderRejectionSequence)
                 .has_value());
  video->failSecondPlaneImportForTesting();
  PixelBufferCreation partialFailure = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  video->submitTrackedFrame(
      wam::macos::FrameLease(partialFailure.buffer),
      wam::macos::QtGlFrameIdentity{1, 101});
  CVPixelBufferRelease(partialFailure.buffer);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.fatalErrorSerial ==
                   beforePartialFailure.fatalErrorSerial &&
               current.lastError.contains(
                   QStringLiteral("second-plane CGL import failure"));
      },
      5000));
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  REQUIRE(video->stats().importedFrames ==
            beforePartialFailure.importedFrames);
  REQUIRE(video->stats().lastRenderedGeneration ==
            beforePartialFailure.lastRenderedGeneration);
  const auto rejected = renderProgress.rejectionAfter(
      beforePartialFailure.renderRejectionSequence);
  REQUIRE(rejected.has_value());
  REQUIRE(rejected->deliverySequence == 1);
  REQUIRE(rejected->frameSequence == 101);
  REQUIRE(rejected->generation == 0);
  REQUIRE(!renderProgress.drawAfter(beforePartialFailure.lastDrawSequence)
                 .has_value());
  REQUIRE(!video->takeFatalError().has_value());
  PixelBufferCreation afterPartialFailure = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(video, &window, afterPartialFailure.buffer);
  REQUIRE(!video->takeFatalError().has_value());

  // Hold teardown to make generation invalidation and recreated-node
  // backpressure deterministic. The stale callback is rejected before it can
  // enter the capacity-one latest-frame mailbox.
  video->holdRetirementsForTesting(true);
  const auto beforeFlush = video->stats();
  REQUIRE(beforeFlush.acceptedGeneration == 0);
  video->flush(1);
  REQUIRE(video->stats().acceptedGeneration == 1);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] { return video->stats().pendingRetirements == 1; }, 5000));
  const auto generationOneBaseline = video->stats();
  const auto generationOneMemory = video->memoryFacts();
  REQUIRE(generationOneBaseline.acceptedGeneration == 1);
  REQUIRE(generationOneMemory.latestFrames == 0);
  REQUIRE(generationOneMemory.currentResourceSets ==
            generationOneBaseline.activeResourceSets);
  REQUIRE(generationOneMemory.currentRetirementJobs == 1);
  REQUIRE(generationOneMemory.peakRetirementJobs >= 1);
  for (int redraw = 0; redraw < 3; ++redraw) {
    window.requestUpdate();
    REQUIRE(!window.grabWindow().isNull());
  }
  REQUIRE(video->stats().acceptedGeneration == 1);
  REQUIRE(video->stats().acceptedRenderedFrames ==
            generationOneBaseline.acceptedRenderedFrames);
  PixelBufferCreation stale = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming staleTiming;
  staleTiming.generation = 0;
  submitFrame(video, wam::macos::FrameLease(stale.buffer, staleTiming));
  CVPixelBufferRelease(stale.buffer);
  REQUIRE(video->stats().staleFrames == beforeFlush.staleFrames + 1);
  REQUIRE(video->stats().lastRenderedGeneration ==
            beforeFlush.lastRenderedGeneration);
  REQUIRE(video->stats().acceptedRenderedFrames ==
            generationOneBaseline.acceptedRenderedFrames);

  PixelBufferCreation currentRed = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming currentTiming;
  currentTiming.generation = 1;
  submitFrame(video, wam::macos::FrameLease(currentRed.buffer, currentTiming));
  CVPixelBufferRelease(currentRed.buffer);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] { return video->stats().backpressuredImports > 0; }, 5000));
  REQUIRE(video->stats().importedFrames == beforeFlush.importedFrames);
  REQUIRE(video->stats().lastRenderedGeneration ==
            beforeFlush.lastRenderedGeneration);
  REQUIRE(video->stats().acceptedRenderedFrames ==
            generationOneBaseline.acceptedRenderedFrames);

  // Explicitly destroy and recreate the QSG node while the old share-group
  // job is held. The new node must retain the latest generation-one lease but
  // may not import it until the retirement worker clears the old ring.
  video->setParentItem(nullptr);
  window.requestUpdate();
  REQUIRE(!window.grabWindow().isNull());
  video->setParentItem(host);
  video->setX(0);
  video->setY(0);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  REQUIRE(!window.grabWindow().isNull());
  REQUIRE(video->stats().importedFrames == beforeFlush.importedFrames);

  window.hide();
  window.releaseResources();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 100);
  video->holdRetirementCompletionForTesting(true);
  video->holdRetirementsForTesting(false);
  REQUIRE(spinUntil(
      [&] { return video->retirementCompletionHeldForTesting(); }, 5000));
  const auto completionHeldStats = video->stats();
  const auto completionHeldMemory = video->memoryFacts();
  REQUIRE(completionHeldStats.pendingRetirements == 1);
  REQUIRE(completionHeldMemory.currentRetirementJobs == 1);
  REQUIRE(completionHeldMemory.peakRetirementJobs >=
            completionHeldMemory.currentRetirementJobs);
  REQUIRE(completionHeldMemory.peakResourceSets >=
            completionHeldMemory.currentResourceSets);
  video->holdRetirementCompletionForTesting(false);
  REQUIRE(spinUntil(
      [&] { return !video->retirementCompletionHeldForTesting(); }, 5000));
  REQUIRE(spinUntil(
      [&] { return video->stats().pendingRetirements == 0; }, 5000));
  if (retirementAccountingOnly) {
    std::cout << "Qt OpenGL ordered retirement accounting passed\n";
    return EXIT_SUCCESS;
  }
  window.show();
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return window.isSceneGraphInitialized() &&
               current.importedFrames >= beforeFlush.importedFrames + 1 &&
               current.lastError.isEmpty();
      },
      5000));
  image = window.grabWindow();
  checkColorNear(sampleLogicalPixel(image, window, 40, 100),
                 QColor(232, 31, 41), 5,
                 "post-flush retained current-generation frame");
  REQUIRE(spinUntil(
      [&] { return video->stats().lastRenderedGeneration == 1; }, 5000));
  const auto generationOnePresented = video->stats();
  REQUIRE(generationOnePresented.acceptedGeneration == 1);
  REQUIRE(generationOnePresented.acceptedRenderedFrames >
            generationOneBaseline.acceptedRenderedFrames);

  // A regressed/same generation argument advances fail-closed instead of
  // reopening the just-flushed timeline to a delayed callback.
  const auto beforeRegressedFlush = video->stats();
  REQUIRE(beforeRegressedFlush.acceptedGeneration == 1);
  video->flush(1);
  REQUIRE(video->stats().acceptedGeneration == 2);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] { return video->stats().activeResourceSets == 0; }, 5000));
  const auto generationTwoBaseline = video->stats();
  REQUIRE(generationTwoBaseline.acceptedGeneration == 2);
  REQUIRE(generationTwoBaseline.acceptedRenderedFrames >=
            generationOnePresented.acceptedRenderedFrames);
  PixelBufferCreation regressedStale = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming regressedTiming;
  regressedTiming.generation = 1;
  submitFrame(video,
      wam::macos::FrameLease(regressedStale.buffer, regressedTiming));
  CVPixelBufferRelease(regressedStale.buffer);
  REQUIRE(video->stats().staleFrames ==
            beforeRegressedFlush.staleFrames + 1);
  REQUIRE(video->stats().lastRenderedGeneration == 1);
  REQUIRE(video->stats().acceptedRenderedFrames ==
            generationTwoBaseline.acceptedRenderedFrames);
  PixelBufferCreation generationTwo = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(video, &window, generationTwo.buffer, 2);
  REQUIRE(video->stats().lastRenderedGeneration == 2);
  const auto generationTwoPresented = video->stats();
  REQUIRE(generationTwoPresented.acceptedGeneration == 2);
  REQUIRE(generationTwoPresented.acceptedRenderedFrames >
            generationTwoBaseline.acceptedRenderedFrames);

  // The tracked seam publishes exactly the first accepted fence-created draw
  // for one delivery identity. Duplicate PTS and retained-frame redraws cannot
  // manufacture a second credit.
  const std::uint64_t drawBaseline =
      generationTwoPresented.lastDrawSequence;
  PixelBufferCreation tracked = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming trackedTiming;
  trackedTiming.generation = 2;
  trackedTiming.presentationTime = CMTimeMake(3003, 30000);
  trackedTiming.duration = CMTimeMake(1001, 30000);
  video->submitTrackedFrame(
      wam::macos::FrameLease(tracked.buffer, trackedTiming),
      wam::macos::QtGlFrameIdentity{2, 202});
  CVPixelBufferRelease(tracked.buffer);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] { return video->stats().lastDrawSequence > drawBaseline; }, 5000));
  const auto draw = renderProgress.drawAfter(drawBaseline);
  REQUIRE(draw.has_value());
  REQUIRE(draw->deliverySequence == 2);
  REQUIRE(draw->frameSequence == 202);
  REQUIRE(draw->generation == 2);
  REQUIRE(CMTimeCompare(draw->presentationTime,
                          trackedTiming.presentationTime) == 0);
  REQUIRE(CMTimeCompare(draw->duration, trackedTiming.duration) == 0);
  for (int redraw = 0; redraw < 3; ++redraw) {
    window.requestUpdate();
    REQUIRE(!window.grabWindow().isNull());
  }
  REQUIRE(video->stats().lastDrawSequence == draw->drawSequence);
  REQUIRE(!renderProgress.drawAfter(draw->drawSequence).has_value());

  // A taken fatal reason re-arms the latch. A terminal init failure on the
  // first frame of a new generation must not advertise that generation as
  // rendered. Recreating the node then proves the retained fatal survives a
  // later successful draw until explicitly consumed.
  const auto beforeReinvalidatedFailure = video->stats();
  video->flush(3);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  const auto invalidation = renderProgress.invalidationAfter(0);
  REQUIRE(invalidation.has_value());
  REQUIRE(invalidation->generation == 3);
  video->failAfterRetirementServiceCreationForTesting();
  PixelBufferCreation generationThree = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming generationThreeTiming;
  generationThreeTiming.generation = 3;
  submitFrame(video,
      wam::macos::FrameLease(generationThree.buffer, generationThreeTiming));
  CVPixelBufferRelease(generationThree.buffer);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.fatalErrorSerial ==
                   beforeReinvalidatedFailure.fatalErrorSerial + 1 &&
               current.lastError.contains(
                   QStringLiteral("retirement service creation"));
      },
      5000));
  const auto generationThreeFailureStats = video->stats();
  REQUIRE(generationThreeFailureStats.fatalErrorSerial ==
            emptyInitFailureStats.fatalErrorSerial + 1);
  REQUIRE(fatalSerialToken.load() ==
            generationThreeFailureStats.fatalErrorSerial);
  REQUIRE(generationThreeFailureStats.importedFrames ==
            beforeReinvalidatedFailure.importedFrames);
  REQUIRE(generationThreeFailureStats.lastRenderedGeneration == 2);
  const auto submittedBeforeGenerationThreeRecovery =
      generationThreeFailureStats.submittedFrames;
  video->setParentItem(nullptr);
  window.requestUpdate();
  REQUIRE(!window.grabWindow().isNull());
  video->setParentItem(host);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        video->setWidth(video->width() == 400.0 ? 399.0 : 400.0);
        window.requestUpdate();
        static_cast<void>(window.grabWindow());
        const auto current = video->stats();
        return current.importedFrames >=
                   beforeReinvalidatedFailure.importedFrames + 1 &&
               current.lastRenderedGeneration == 3 &&
               current.lastError.isEmpty();
      },
      5000));
  video->setWidth(400.0);
  REQUIRE(video->stats().submittedFrames ==
            submittedBeforeGenerationThreeRecovery);
  REQUIRE(video->stats().fatalErrorSerial ==
            generationThreeFailureStats.fatalErrorSerial);
  fatalError = video->takeFatalError();
  REQUIRE(fatalError.has_value());
  REQUIRE(fatalError->contains(
      QStringLiteral("retirement service creation")));
  REQUIRE(!video->takeFatalError().has_value());
  REQUIRE(fatalSerialToken.load() ==
            generationThreeFailureStats.fatalErrorSerial);

  // Moving the paused frame to another live window creates another node and
  // potentially another Qt context/share group. No decoder resubmit occurs.
  QQuickWindow migrationWindow;
  migrationWindow.resize(400, 300);
  migrationWindow.setColor(Qt::black);
  migrationWindow.setPersistentSceneGraph(false);
  migrationWindow.setPersistentGraphics(false);
  migrationWindow.show();
  migrationWindow.requestUpdate();
  REQUIRE(spinUntil(
      [&] { return migrationWindow.isSceneGraphInitialized(); }, 5000));
  const auto beforeMigration = video->stats();
  video->setParentItem(migrationWindow.contentItem());
  video->setX(0);
  video->setY(0);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  migrationWindow.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.importedFrames >= beforeMigration.importedFrames + 1 &&
               current.lastError.isEmpty();
      },
      5000));
  REQUIRE(video->stats().submittedFrames == beforeMigration.submittedFrames);
  image = migrationWindow.grabWindow();
  checkColorNear(sampleLogicalPixel(image, migrationWindow, 40, 100),
                 QColor(232, 31, 41), 5,
                 "paused frame after live-window migration");

  video->setParentItem(nullptr);
  migrationWindow.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  stats = video->stats();
  REQUIRE(stats.peakActiveResourceSets <= 2);
  REQUIRE(!stats.retirementFailed);
  const std::uint64_t fatalSerialBeforeItemDestruction =
      fatalSerialToken.load();
  videoOwner.reset();
  REQUIRE(fatalSerialToken.load() == fatalSerialBeforeItemDestruction);

  // A retirement-queue failure occurs after GL names and the IOSurface lease
  // have moved out of the node. The intrusive job must therefore enter the
  // allocation-free process quarantine without destroying that lease. The
  // first such failure permanently disables new native GL admission.
  const std::size_t quarantineBefore =
      wam::macos::QtGlVideoItem::quarantinedJobsForTesting();
  const std::size_t quarantinedResourceSetsBefore =
      wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting();
  const std::size_t quarantinedFramesBefore =
      wam::macos::QtGlVideoItem::quarantinedFramesForTesting();
  auto quarantineOwner = std::make_unique<wam::macos::QtGlVideoItem>();
  auto* quarantineItem = quarantineOwner.get();
  quarantineItem->setParentItem(host);
  quarantineItem->setSize(QSizeF(400, 300));
  PixelBufferCreation quarantineFrame = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(quarantineItem, &window,
                           quarantineFrame.buffer);
  quarantineItem->failNextRetirementEnqueueForTesting();
  quarantineItem->setParentItem(nullptr);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] {
        return quarantineItem->stats().retirementFailed &&
               wam::macos::QtGlVideoItem::quarantinedJobsForTesting() ==
                   quarantineBefore + 1;
      },
      5000));
  const auto quarantineStats = quarantineItem->stats();
  const auto quarantineMemory = quarantineItem->memoryFacts();
  REQUIRE(quarantineStats.fatalErrorSerial == 1);
  REQUIRE(quarantineStats.pendingRetirements == 0);
  fatalError = quarantineItem->takeFatalError();
  REQUIRE(fatalError.has_value());
  REQUIRE(!quarantineItem->takeFatalError().has_value());
  REQUIRE(quarantineItem->stats().activeResourceSets > 0);
  REQUIRE(
      wam::macos::QtGlVideoItem::quarantinedResourceSetsForTesting() ==
      quarantinedResourceSetsBefore + 1);
  REQUIRE(wam::macos::QtGlVideoItem::quarantinedFramesForTesting() ==
            quarantinedFramesBefore + 1);
  REQUIRE(quarantineMemory.currentResourceSets ==
            quarantineStats.activeResourceSets);
  REQUIRE(quarantineMemory.currentRetirementJobs == 0);
  REQUIRE(quarantineMemory.quarantinedJobs == quarantineBefore + 1);
  REQUIRE(quarantineMemory.quarantinedResourceSets ==
            quarantinedResourceSetsBefore + 1);
  REQUIRE(quarantineMemory.quarantinedFrames ==
            quarantinedFramesBefore + 1);
  REQUIRE(quarantineMemory.poisonedSubsystems == 1);
  REQUIRE(wam::macos::QtGlVideoItem::nativeGlSubsystemPoisonedForTesting());
  REQUIRE(wam::macos::QtGlVideoItem::retirementServiceCountForTesting() <=
            wam::macos::QtGlVideoItem::retirementServiceCapacityForTesting());
  quarantineOwner.reset();

  auto blockedOwner = std::make_unique<wam::macos::QtGlVideoItem>();
  auto* blockedItem = blockedOwner.get();
  blockedItem->setParentItem(host);
  blockedItem->setSize(QSizeF(400, 300));
  PixelBufferCreation blockedFrame = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitFrame(blockedItem, wam::macos::FrameLease(blockedFrame.buffer));
  CVPixelBufferRelease(blockedFrame.buffer);
  window.requestUpdate();
  REQUIRE(spinUntil(
      [&] { return blockedItem->stats().fatalErrorSerial == 1; }, 5000));
  REQUIRE(blockedItem->stats().activeResourceSets == 0);
  REQUIRE(blockedItem->stats().importedFrames == 0);
  blockedItem->setParentItem(nullptr);
  window.requestUpdate();
  blockedOwner.reset();

  migrationWindow.hide();
  migrationWindow.releaseResources();
  window.hide();
  window.releaseResources();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 50);

  std::cout
      << "Qt OpenGL IOSurface compositor gate passed: one-draw NV12/P010 "
         "BT.601/709 conversion, premultiplied opacity, projection/item "
         "transform, scissor+stencil clips, QML layer/nondefault FBO and "
         "overlay ordering, two persistent slots, injected failure, atomic "
         "generation flush/stale rejection, asynchronous shared-CGL fence "
         "retirement, paused scene-graph recreation, and live-window migration";
  if (p010VideoCases == 2) {
    std::cout << "; P010 video range passed";
  }
  if (p010FullCases == 2) {
    std::cout << "; P010 full range passed";
  }
  std::cout << " (peakSets=" << stats.peakActiveResourceSets
            << ", pending=" << stats.pendingRetirements << ")\n";
  return EXIT_SUCCESS;
}
