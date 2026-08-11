#include "platform/macos/qt_gl_video_item.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>

#include <QColor>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QGuiApplication>
#include <QImage>
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
#include <vector>

namespace {

void check(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression
              << '\n';
    std::exit(EXIT_FAILURE);
  }
}

#define WAM_CHECK(expression)                                                  \
  check(static_cast<bool>(expression), #expression, __LINE__)

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
  WAM_CHECK(buffer != nullptr);
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
  WAM_CHECK(luma != nullptr && chroma != nullptr);
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
  WAM_CHECK(luma != nullptr && chroma != nullptr);
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
  QElapsedTimer timer;
  timer.start();
  while (!predicate() && timer.elapsed() < timeoutMs) {
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return predicate();
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
    WAM_CHECK(fillSolid(result.buffer, codes));
    attachColorMetadata(result.buffer, matrix,
                        kCVImageBufferChromaLocation_Center);
  }
  return result;
}

QImage submitOwnedBufferAndGrab(wam::macos::QtGlVideoItem* video,
                                QQuickWindow* window,
                                CVPixelBufferRef ownedBuffer,
                                std::uint64_t generation = 0) {
  WAM_CHECK(video != nullptr && window != nullptr && ownedBuffer != nullptr);
  const auto before = video->stats();
  wam::macos::FrameTiming timing;
  timing.generation = generation;
  video->submitFrame(wam::macos::FrameLease(ownedBuffer, timing));
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
  WAM_CHECK(!image.isNull());
  return image;
}

void submitOwnedBufferExpectRejected(wam::macos::QtGlVideoItem* video,
                                     QQuickWindow* window,
                                     CVPixelBufferRef ownedBuffer,
                                     const QString& expectedError) {
  const auto before = video->stats();
  video->submitFrame(wam::macos::FrameLease(ownedBuffer));
  CVPixelBufferRelease(ownedBuffer);
  window->requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return video->stats().lastError.contains(expectedError); }, 5000));
  WAM_CHECK(video->stats().importedFrames == before.importedFrames);
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
  // Rotated Qt Quick clips use the RenderState stencil contract. The dormant
  // gate requests it explicitly so a context with zero stencil bits cannot
  // produce a deceptively green clipping test.
  format.setStencilBufferSize(8);
  format.setAlphaBufferSize(8);
  format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
  QSurfaceFormat::setDefaultFormat(format);
  QGuiApplication application(argc, argv);
  WAM_CHECK(
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
  WAM_CHECK(root != nullptr && host != nullptr);
  root->setParentItem(window.contentItem());

  auto videoOwner = std::make_unique<wam::macos::QtGlVideoItem>();
  auto* video = videoOwner.get();
  video->setParentItem(host);
  video->setSize(QSizeF(400, 300));

  window.show();
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] { return window.isSceneGraphInitialized(); }, 5000));
  WAM_CHECK(window.rendererInterface()->graphicsApi() ==
            QSGRendererInterface::OpenGL);
  WAM_CHECK(wam::macos::QtGlFatalErrorSerialToken{}.load() == 0);
  const auto blankStats = video->stats();
  const auto fatalSerialToken = video->fatalErrorSerialToken();
  WAM_CHECK(blankStats.submittedFrames == 0);
  WAM_CHECK(blankStats.renderedFrames == 0);
  WAM_CHECK(blankStats.lastRenderedGeneration == 0);
  WAM_CHECK(blankStats.acceptedGeneration == 0);
  WAM_CHECK(blankStats.acceptedRenderedFrames == 0);
  WAM_CHECK(blankStats.fatalErrorSerial == 0);
  WAM_CHECK(fatalSerialToken.load() == 0);
  WAM_CHECK(blankStats.activeResourceSets == 0);
  WAM_CHECK(!blankStats.textureRectangleSupported);
  WAM_CHECK(!blankStats.acceleratedContext);
  WAM_CHECK(!video->takeFatalError().has_value());

  // Fail after the shared retirement context exists but before shaders/VAO or
  // plane textures do. Removing the node must clear that empty attachment so
  // a recreated node can retry instead of spinning on stale context identity.
  const auto beforeEmptyInitFailure = video->stats();
  video->failAfterRetirementServiceCreationForTesting();
  PixelBufferCreation emptyInitFailure = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  video->submitFrame(wam::macos::FrameLease(emptyInitFailure.buffer));
  CVPixelBufferRelease(emptyInitFailure.buffer);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.fatalErrorSerial ==
                   beforeEmptyInitFailure.fatalErrorSerial + 1 &&
               current.lastError.contains(
                   QStringLiteral("retirement service creation"));
      },
      5000));
  const auto emptyInitFailureStats = video->stats();
  WAM_CHECK(fatalSerialToken.load() ==
            emptyInitFailureStats.fatalErrorSerial);
  WAM_CHECK(emptyInitFailureStats.activeResourceSets == 0);
  WAM_CHECK(emptyInitFailureStats.importedFrames == 0);
  WAM_CHECK(emptyInitFailureStats.renderedFrames ==
            beforeEmptyInitFailure.renderedFrames);
  WAM_CHECK(emptyInitFailureStats.lastRenderedGeneration ==
            beforeEmptyInitFailure.lastRenderedGeneration);
  auto fatalError = video->takeFatalError();
  WAM_CHECK(fatalError.has_value());
  WAM_CHECK(fatalError->contains(
      QStringLiteral("retirement service creation")));
  WAM_CHECK(!video->takeFatalError().has_value());
  WAM_CHECK(video->stats().fatalErrorSerial ==
            emptyInitFailureStats.fatalErrorSerial);
  WAM_CHECK(fatalSerialToken.load() ==
            emptyInitFailureStats.fatalErrorSerial);
  // Taking an event must not make the same terminal node failure look new on
  // subsequent render requests.
  for (int repeat = 0; repeat < 3; ++repeat) {
    window.requestUpdate();
    WAM_CHECK(!window.grabWindow().isNull());
  }
  WAM_CHECK(video->stats().fatalErrorSerial ==
            emptyInitFailureStats.fatalErrorSerial);
  WAM_CHECK(!video->takeFatalError().has_value());
  video->setParentItem(nullptr);
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());
  video->setParentItem(host);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.importedFrames == 1 && current.renderedFrames > 0 &&
               current.lastError.isEmpty();
      },
      5000));
  WAM_CHECK(video->stats().lastRenderedGeneration == 0);
  WAM_CHECK(video->stats().fatalErrorSerial ==
            emptyInitFailureStats.fatalErrorSerial);
  WAM_CHECK(!video->takeFatalError().has_value());

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
  WAM_CHECK(p010VideoCases == 2);
  WAM_CHECK(p010FullCases == 0 || p010FullCases == 2);

  PixelBufferCreation white = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  WAM_CHECK(white.buffer != nullptr);
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
  WAM_CHECK(!image.isNull());
  checkColorNear(sampleLogicalPixel(image, window, 40, 100),
                 QColor(128, 128, 128), 6, "premultiplied item opacity");
  video->setOpacity(1.0);

  PixelBufferCreation centered = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, 4);
  WAM_CHECK(centered.buffer != nullptr && fillAlternatingChroma(centered.buffer));
  attachColorMetadata(centered.buffer,
                      kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Center);
  image = submitOwnedBufferAndGrab(video, &window, centered.buffer);
  checkColorNear(sampleLogicalPixel(image, window, 75, 125),
                 QColor(128, 140, 10), 7, "center-sited chroma");

  PixelBufferCreation left = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, 4);
  WAM_CHECK(left.buffer != nullptr && fillAlternatingChroma(left.buffer));
  attachColorMetadata(left.buffer, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Left);
  image = submitOwnedBufferAndGrab(video, &window, left.buffer);
  checkColorNear(sampleLogicalPixel(image, window, 75, 125),
                 QColor(128, 128, 128), 7, "left-sited chroma");

  PixelBufferCreation bt2020 = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_2020);
  const auto beforeMetadataFailure = video->stats();
  submitOwnedBufferExpectRejected(video, &window, bt2020.buffer,
                                  QStringLiteral("YCbCr matrix"));
  WAM_CHECK(video->stats().fatalErrorSerial ==
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
  WAM_CHECK(video->stats().fatalErrorSerial ==
            beforeMetadataFailure.fatalErrorSerial);
  WAM_CHECK(!video->takeFatalError().has_value());

  // Restore a known good frame after the deliberate metadata failures.
  PixelBufferCreation restoredWhite = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(video, &window, restoredWhite.buffer);
  WAM_CHECK(video->stats().fatalErrorSerial ==
            beforeMetadataFailure.fatalErrorSerial);
  WAM_CHECK(!video->takeFatalError().has_value());

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
  WAM_CHECK(video->stats().sawScissorClip);

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
  WAM_CHECK(video->stats().sawStencilClip);

  setHostGeometry(host, 0, 0, 400, 300, false, 0);
  video->setX(0);
  video->setY(0);
  video->setSize(QSizeF(400, 300));
  WAM_CHECK(root->setProperty("layerActive", true));
  window.requestUpdate();
  image = window.grabWindow();
  WAM_CHECK(!image.isNull());
  auto stats = video->stats();
  WAM_CHECK(stats.textureRectangleSupported);
  WAM_CHECK(stats.textureRgSupported);
  WAM_CHECK(stats.acceleratedContext);
  WAM_CHECK(stats.exactSourceIOSurface);
  WAM_CHECK(stats.renderedIntoNonDefaultFramebuffer);
  WAM_CHECK(!stats.retirementFailed);
  WAM_CHECK(stats.peakActiveResourceSets <= 2);
  WAM_CHECK(root->setProperty("layerActive", false));
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());

  // Two simultaneous items must retain and sample distinct IOSurfaces.
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

  second->setParentItem(nullptr);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = second->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  secondOwner.reset();
  video->setWidth(400);

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
    WAM_CHECK(gray.buffer != nullptr);
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(gray.buffer);
    WAM_CHECK(surface != nullptr);
    WAM_CHECK(surfaceIds.insert(IOSurfaceGetID(surface)).second);
    CVPixelBufferRetain(gray.buffer);
    retainedDistinctBuffers.push_back(gray.buffer);
    submitOwnedBufferAndGrab(video, &window, gray.buffer);
    const auto current = video->stats();
    WAM_CHECK(current.activeResourceSets <= 2);
    WAM_CHECK(current.pendingRetirements == 0);
  }
  for (CVPixelBufferRef retained : retainedDistinctBuffers) {
    CVPixelBufferRelease(retained);
  }
  WAM_CHECK(video->stats().peakActiveResourceSets <= 2);

  // Deterministic frame rejection remains recoverable and does not replace
  // the current good frame, grow the resource ring, or publish a fatal event.
  const auto beforeFailure = video->stats();
  video->failNextImportForTesting();
  PixelBufferCreation failed = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  video->submitFrame(wam::macos::FrameLease(failed.buffer));
  CVPixelBufferRelease(failed.buffer);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.fatalErrorSerial == beforeFailure.fatalErrorSerial &&
               current.lastError.contains(
                   QStringLiteral("injected Qt CGL import failure"));
      },
      5000));
  WAM_CHECK(video->stats().importedFrames == beforeFailure.importedFrames);
  WAM_CHECK(video->stats().lastRenderedGeneration ==
            beforeFailure.lastRenderedGeneration);
  WAM_CHECK(video->stats().activeResourceSets <= 2);
  WAM_CHECK(!video->takeFatalError().has_value());
  WAM_CHECK(video->stats().fatalErrorSerial ==
            beforeFailure.fatalErrorSerial);

  const auto beforePartialFailure = video->stats();
  video->failSecondPlaneImportForTesting();
  PixelBufferCreation partialFailure = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  video->submitFrame(wam::macos::FrameLease(partialFailure.buffer));
  CVPixelBufferRelease(partialFailure.buffer);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.fatalErrorSerial ==
                   beforePartialFailure.fatalErrorSerial &&
               current.lastError.contains(
                   QStringLiteral("second-plane CGL import failure"));
      },
      5000));
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  WAM_CHECK(video->stats().importedFrames ==
            beforePartialFailure.importedFrames);
  WAM_CHECK(video->stats().lastRenderedGeneration ==
            beforePartialFailure.lastRenderedGeneration);
  WAM_CHECK(!video->takeFatalError().has_value());
  PixelBufferCreation afterPartialFailure = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(video, &window, afterPartialFailure.buffer);
  WAM_CHECK(!video->takeFatalError().has_value());

  // Hold teardown to make generation invalidation and recreated-node
  // backpressure deterministic. The stale callback is rejected before it can
  // enter the capacity-one latest-frame mailbox.
  video->holdRetirementsForTesting(true);
  const auto beforeFlush = video->stats();
  WAM_CHECK(beforeFlush.acceptedGeneration == 0);
  video->flush(1);
  WAM_CHECK(video->stats().acceptedGeneration == 1);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return video->stats().pendingRetirements == 1; }, 5000));
  const auto generationOneBaseline = video->stats();
  WAM_CHECK(generationOneBaseline.acceptedGeneration == 1);
  for (int redraw = 0; redraw < 3; ++redraw) {
    window.requestUpdate();
    WAM_CHECK(!window.grabWindow().isNull());
  }
  WAM_CHECK(video->stats().acceptedGeneration == 1);
  WAM_CHECK(video->stats().acceptedRenderedFrames ==
            generationOneBaseline.acceptedRenderedFrames);
  PixelBufferCreation stale = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming staleTiming;
  staleTiming.generation = 0;
  video->submitFrame(wam::macos::FrameLease(stale.buffer, staleTiming));
  CVPixelBufferRelease(stale.buffer);
  WAM_CHECK(video->stats().staleFrames == beforeFlush.staleFrames + 1);
  WAM_CHECK(video->stats().lastRenderedGeneration ==
            beforeFlush.lastRenderedGeneration);
  WAM_CHECK(video->stats().acceptedRenderedFrames ==
            generationOneBaseline.acceptedRenderedFrames);

  PixelBufferCreation currentRed = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming currentTiming;
  currentTiming.generation = 1;
  video->submitFrame(wam::macos::FrameLease(currentRed.buffer, currentTiming));
  CVPixelBufferRelease(currentRed.buffer);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return video->stats().backpressuredImports > 0; }, 5000));
  WAM_CHECK(video->stats().importedFrames == beforeFlush.importedFrames);
  WAM_CHECK(video->stats().lastRenderedGeneration ==
            beforeFlush.lastRenderedGeneration);
  WAM_CHECK(video->stats().acceptedRenderedFrames ==
            generationOneBaseline.acceptedRenderedFrames);

  // Explicitly destroy and recreate the QSG node while the old share-group
  // job is held. The new node must retain the latest generation-one lease but
  // may not import it until the retirement worker clears the old ring.
  video->setParentItem(nullptr);
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());
  video->setParentItem(host);
  video->setX(0);
  video->setY(0);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());
  WAM_CHECK(video->stats().importedFrames == beforeFlush.importedFrames);

  window.hide();
  window.releaseResources();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 100);
  video->holdRetirementsForTesting(false);
  WAM_CHECK(spinUntil(
      [&] { return video->stats().pendingRetirements == 0; }, 5000));
  window.show();
  window.requestUpdate();
  WAM_CHECK(spinUntil(
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
  WAM_CHECK(spinUntil(
      [&] { return video->stats().lastRenderedGeneration == 1; }, 5000));
  const auto generationOnePresented = video->stats();
  WAM_CHECK(generationOnePresented.acceptedGeneration == 1);
  WAM_CHECK(generationOnePresented.acceptedRenderedFrames >
            generationOneBaseline.acceptedRenderedFrames);

  // A regressed/same generation argument advances fail-closed instead of
  // reopening the just-flushed timeline to a delayed callback.
  const auto beforeRegressedFlush = video->stats();
  WAM_CHECK(beforeRegressedFlush.acceptedGeneration == 1);
  video->flush(1);
  WAM_CHECK(video->stats().acceptedGeneration == 2);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return video->stats().activeResourceSets == 0; }, 5000));
  const auto generationTwoBaseline = video->stats();
  WAM_CHECK(generationTwoBaseline.acceptedGeneration == 2);
  WAM_CHECK(generationTwoBaseline.acceptedRenderedFrames >=
            generationOnePresented.acceptedRenderedFrames);
  PixelBufferCreation regressedStale = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming regressedTiming;
  regressedTiming.generation = 1;
  video->submitFrame(
      wam::macos::FrameLease(regressedStale.buffer, regressedTiming));
  CVPixelBufferRelease(regressedStale.buffer);
  WAM_CHECK(video->stats().staleFrames ==
            beforeRegressedFlush.staleFrames + 1);
  WAM_CHECK(video->stats().lastRenderedGeneration == 1);
  WAM_CHECK(video->stats().acceptedRenderedFrames ==
            generationTwoBaseline.acceptedRenderedFrames);
  PixelBufferCreation generationTwo = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(video, &window, generationTwo.buffer, 2);
  WAM_CHECK(video->stats().lastRenderedGeneration == 2);
  const auto generationTwoPresented = video->stats();
  WAM_CHECK(generationTwoPresented.acceptedGeneration == 2);
  WAM_CHECK(generationTwoPresented.acceptedRenderedFrames >
            generationTwoBaseline.acceptedRenderedFrames);

  // A taken fatal reason re-arms the latch. A terminal init failure on the
  // first frame of a new generation must not advertise that generation as
  // rendered. Recreating the node then proves the retained fatal survives a
  // later successful draw until explicitly consumed.
  const auto beforeReinvalidatedFailure = video->stats();
  video->flush(3);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  video->failAfterRetirementServiceCreationForTesting();
  PixelBufferCreation generationThree = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {80, 112, 216},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  wam::macos::FrameTiming generationThreeTiming;
  generationThreeTiming.generation = 3;
  video->submitFrame(
      wam::macos::FrameLease(generationThree.buffer, generationThreeTiming));
  CVPixelBufferRelease(generationThree.buffer);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.fatalErrorSerial ==
                   beforeReinvalidatedFailure.fatalErrorSerial + 1 &&
               current.lastError.contains(
                   QStringLiteral("retirement service creation"));
      },
      5000));
  const auto generationThreeFailureStats = video->stats();
  WAM_CHECK(generationThreeFailureStats.fatalErrorSerial ==
            emptyInitFailureStats.fatalErrorSerial + 1);
  WAM_CHECK(fatalSerialToken.load() ==
            generationThreeFailureStats.fatalErrorSerial);
  WAM_CHECK(generationThreeFailureStats.importedFrames ==
            beforeReinvalidatedFailure.importedFrames);
  WAM_CHECK(generationThreeFailureStats.lastRenderedGeneration == 2);
  const auto submittedBeforeGenerationThreeRecovery =
      generationThreeFailureStats.submittedFrames;
  video->setParentItem(nullptr);
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());
  video->setParentItem(host);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.importedFrames >=
                   beforeReinvalidatedFailure.importedFrames + 1 &&
               current.lastRenderedGeneration == 3 &&
               current.lastError.isEmpty();
      },
      5000));
  WAM_CHECK(video->stats().submittedFrames ==
            submittedBeforeGenerationThreeRecovery);
  WAM_CHECK(video->stats().fatalErrorSerial ==
            generationThreeFailureStats.fatalErrorSerial);
  fatalError = video->takeFatalError();
  WAM_CHECK(fatalError.has_value());
  WAM_CHECK(fatalError->contains(
      QStringLiteral("retirement service creation")));
  WAM_CHECK(!video->takeFatalError().has_value());
  WAM_CHECK(fatalSerialToken.load() ==
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
  WAM_CHECK(spinUntil(
      [&] { return migrationWindow.isSceneGraphInitialized(); }, 5000));
  const auto beforeMigration = video->stats();
  video->setParentItem(migrationWindow.contentItem());
  video->setX(0);
  video->setY(0);
  video->setSize(QSizeF(400, 300));
  window.requestUpdate();
  migrationWindow.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.importedFrames >= beforeMigration.importedFrames + 1 &&
               current.lastError.isEmpty();
      },
      5000));
  WAM_CHECK(video->stats().submittedFrames == beforeMigration.submittedFrames);
  image = migrationWindow.grabWindow();
  checkColorNear(sampleLogicalPixel(image, migrationWindow, 40, 100),
                 QColor(232, 31, 41), 5,
                 "paused frame after live-window migration");

  video->setParentItem(nullptr);
  migrationWindow.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.activeResourceSets == 0 &&
               current.pendingRetirements == 0;
      },
      5000));
  stats = video->stats();
  WAM_CHECK(stats.peakActiveResourceSets <= 2);
  WAM_CHECK(!stats.retirementFailed);
  const std::uint64_t fatalSerialBeforeItemDestruction =
      fatalSerialToken.load();
  videoOwner.reset();
  WAM_CHECK(fatalSerialToken.load() == fatalSerialBeforeItemDestruction);

  // The impossible lost-service branch must truly quarantine ownership. A
  // misleading fail-closed message is insufficient if the local FrameLease
  // destructs and returns its IOSurface to the decoder pool.
  const std::size_t quarantineBefore =
      wam::macos::QtGlVideoItem::quarantinedJobsForTesting();
  auto quarantineOwner = std::make_unique<wam::macos::QtGlVideoItem>();
  auto* quarantineItem = quarantineOwner.get();
  quarantineItem->setParentItem(host);
  quarantineItem->setSize(QSizeF(400, 300));
  PixelBufferCreation quarantineFrame = solidBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, {235, 128, 128},
      kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  submitOwnedBufferAndGrab(quarantineItem, &window,
                           quarantineFrame.buffer);
  quarantineItem->strandRetirementServiceForTesting();
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        return quarantineItem->stats().retirementFailed &&
               wam::macos::QtGlVideoItem::quarantinedJobsForTesting() ==
                   quarantineBefore + 1;
      },
      5000));
  const auto quarantineStats = quarantineItem->stats();
  WAM_CHECK(quarantineStats.fatalErrorSerial == 1);
  fatalError = quarantineItem->takeFatalError();
  WAM_CHECK(fatalError.has_value());
  WAM_CHECK(fatalError->contains(
      QStringLiteral("lost their shared retirement context")));
  WAM_CHECK(!quarantineItem->takeFatalError().has_value());
  WAM_CHECK(quarantineItem->stats().activeResourceSets > 0);
  quarantineItem->setParentItem(nullptr);
  window.requestUpdate();
  WAM_CHECK(!window.grabWindow().isNull());
  quarantineOwner.reset();

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
