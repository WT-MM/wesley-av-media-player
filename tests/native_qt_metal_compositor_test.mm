#include "platform/macos/qt_metal_video_item.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>

#import <Metal/Metal.h>

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
#include <QUrl>

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

#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
namespace wam::macos {
void failNextQtMetalSynchronizationTokenCopyForTesting() noexcept;
void failNextQtMetalImportTokenCopyForTesting() noexcept;
[[nodiscard]] std::uint64_t
qtMetalSynchronizationTokenCopyFailuresForTesting() noexcept;
[[nodiscard]] std::uint64_t
qtMetalImportTokenCopyFailuresForTesting() noexcept;
[[nodiscard]] std::uint64_t qtMetalNextResourceSerialForTesting() noexcept;
}  // namespace wam::macos
#endif

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
      kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionaryRef empty = CFDictionaryCreate(
      kCFAllocatorDefault, nullptr, nullptr, 0,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey,
                       empty);
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
  WAM_CHECK(matrix != nullptr);
  WAM_CHECK(chromaLocation != nullptr);
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

  const OSType format = CVPixelBufferGetPixelFormatType(buffer);
  const bool tenBit = isTenBit(format);
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
  auto* lumaBase = static_cast<std::byte*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
  auto* chromaBase = static_cast<std::byte*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
  if (lumaBase == nullptr || chromaBase == nullptr) {
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return false;
  }

  if (tenBit) {
    const auto yCode = static_cast<std::uint16_t>(codes.y << 6U);
    const auto cbCode = static_cast<std::uint16_t>(codes.cb << 6U);
    const auto crCode = static_cast<std::uint16_t>(codes.cr << 6U);
    for (std::size_t y = 0; y < lumaHeight; ++y) {
      auto* row = reinterpret_cast<std::uint16_t*>(lumaBase + y * lumaStride);
      for (std::size_t x = 0; x < lumaWidth; ++x) {
        row[x] = yCode;
      }
    }
    for (std::size_t y = 0; y < chromaHeight; ++y) {
      auto* row =
          reinterpret_cast<std::uint16_t*>(chromaBase + y * chromaStride);
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
      auto* row = reinterpret_cast<std::uint8_t*>(lumaBase + y * lumaStride);
      for (std::size_t x = 0; x < lumaWidth; ++x) {
        row[x] = yCode;
      }
    }
    for (std::size_t y = 0; y < chromaHeight; ++y) {
      auto* row =
          reinterpret_cast<std::uint8_t*>(chromaBase + y * chromaStride);
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
  auto* lumaBase = static_cast<std::byte*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
  auto* chromaBase = static_cast<std::byte*>(
      CVPixelBufferGetBaseAddressOfPlane(buffer, 1));
  if (lumaBase == nullptr || chromaBase == nullptr) {
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return false;
  }

  for (std::size_t y = 0; y < lumaHeight; ++y) {
    auto* row = reinterpret_cast<std::uint8_t*>(lumaBase + y * lumaStride);
    for (std::size_t x = 0; x < lumaWidth; ++x) {
      row[x] = 126U;
    }
  }
  for (std::size_t y = 0; y < chromaHeight; ++y) {
    auto* row = reinterpret_cast<std::uint8_t*>(chromaBase + y * chromaStride);
    for (std::size_t x = 0; x < chromaWidth; ++x) {
      row[x * 2] = (x % 2 == 0) ? 16U : 240U;
      row[x * 2 + 1] = 128U;
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
  const bool matches = std::abs(actual.red() - expected.red()) <= tolerance &&
                       std::abs(actual.green() - expected.green()) <= tolerance &&
                       std::abs(actual.blue() - expected.blue()) <= tolerance;
  if (!matches) {
    std::cerr << label << " expected RGB(" << expected.red() << ','
              << expected.green() << ',' << expected.blue() << ") +/- "
              << tolerance << ", got RGB(" << actual.red() << ','
              << actual.green() << ',' << actual.blue() << ")\n";
    std::exit(EXIT_FAILURE);
  }
}

QImage submitOwnedBufferAndGrab(wam::macos::QtMetalVideoItem* video,
                                QQuickWindow* window,
                                CVPixelBufferRef ownedBuffer) {
  WAM_CHECK(video != nullptr);
  WAM_CHECK(window != nullptr);
  WAM_CHECK(ownedBuffer != nullptr);
  const std::uint64_t before = video->stats().importedFrames;
  wam::macos::FrameLease frame(ownedBuffer);
  CVPixelBufferRelease(ownedBuffer);
  video->submitFrame(std::move(frame));
  window->requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto stats = video->stats();
        return stats.importedFrames >= before + 1 && stats.lastError.isEmpty();
      },
      5000));
  QImage image = window->grabWindow();
  WAM_CHECK(!image.isNull());
  return image;
}

void submitOwnedBufferExpectRejected(wam::macos::QtMetalVideoItem* video,
                                     QQuickWindow* window,
                                     CVPixelBufferRef ownedBuffer,
                                     const QString& expectedError) {
  WAM_CHECK(video != nullptr);
  WAM_CHECK(window != nullptr);
  WAM_CHECK(ownedBuffer != nullptr);
  const std::uint64_t before = video->stats().importedFrames;
  wam::macos::FrameLease frame(ownedBuffer);
  CVPixelBufferRelease(ownedBuffer);
  video->submitFrame(std::move(frame));
  window->requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return video->stats().lastError.contains(expectedError); }, 5000));
  WAM_CHECK(video->stats().importedFrames == before);
}

void verifyFrameSlotRetainer() {
  wam::macos::QtFrameSlotRetainer retainer;
  WAM_CHECK(!retainer.safeToDraw());
  auto first = std::make_shared<int>(1);
  std::weak_ptr<int> firstWeak = first;
  WAM_CHECK(retainer.retain(0, 3, first));
  WAM_CHECK(retainer.retain(1, 3, first));
  WAM_CHECK(retainer.retain(2, 3, first));
  WAM_CHECK(retainer.retainedSlotCount() == 3);
  WAM_CHECK(retainer.safeToDraw());
  first.reset();

  auto replacement = std::make_shared<int>(2);
  WAM_CHECK(retainer.retain(0, 3, replacement));
  WAM_CHECK(!firstWeak.expired());
  WAM_CHECK(retainer.retain(1, 3, replacement));
  WAM_CHECK(!firstWeak.expired());
  WAM_CHECK(retainer.retain(2, 3, replacement));
  WAM_CHECK(firstWeak.expired());
  WAM_CHECK(!retainer.retain(-1, 3, replacement));
  WAM_CHECK(!retainer.safeToDraw());
  WAM_CHECK(retainer.retainedSlotCount() == 3);
  WAM_CHECK(!retainer.retain(3, 3, replacement));
  WAM_CHECK(!retainer.retain(0, 0, replacement));
  WAM_CHECK(!retainer.retain(0, 5, replacement));
  WAM_CHECK(!retainer.retain(0, 3, {}));
  WAM_CHECK(!retainer.safeToDraw());
  WAM_CHECK(retainer.retain(0, 3, replacement));
  WAM_CHECK(retainer.safeToDraw());
  retainer.clear();
  WAM_CHECK(retainer.retainedSlotCount() == 0);
  WAM_CHECK(!retainer.safeToDraw());
}

}  // namespace

int main(int argc, char** argv) {
  verifyFrameSlotRetainer();

  if (MTLCreateSystemDefaultDevice() == nil) {
    std::cerr << "Metal is required for the Qt compositor activation gate\n";
    return EXIT_FAILURE;
  }

  // This is process-global and must be selected before QGuiApplication or the
  // first QQuickWindow. Shipping WAM still selects OpenGL in src/qt/main.cpp.
  QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
  QGuiApplication application(argc, argv);

  QQuickWindow window;
  window.resize(320, 240);
  window.setColor(Qt::black);
  window.setPersistentSceneGraph(false);
  window.setPersistentGraphics(false);
  std::atomic<int> sceneGraphInvalidations{0};
  QObject::connect(
      &window, &QQuickWindow::sceneGraphInvalidated, &window,
      [&sceneGraphInvalidations] {
        sceneGraphInvalidations.fetch_add(1, std::memory_order_relaxed);
      },
      Qt::DirectConnection);

  QQmlEngine engine;
  QQmlComponent component(&engine);
  component.setData(
      QByteArrayLiteral(R"QML(
import QtQuick

Item {
    width: 320
    height: 240

    Rectangle {
        objectName: "overlay"
        x: 120
        y: 80
        width: 80
        height: 80
        z: 1
        color: "#80ff0000"
    }
}
)QML"),
      QUrl(QStringLiteral("qrc:/native-metal-compositor-test.qml")));
  std::unique_ptr<QObject> rootObject(component.create());
  if (!rootObject) {
    std::cerr << component.errorString().toStdString() << '\n';
    return EXIT_FAILURE;
  }
  auto* rootItem = qobject_cast<QQuickItem*>(rootObject.get());
  WAM_CHECK(rootItem != nullptr);
  rootItem->setParentItem(window.contentItem());

  auto videoOwner = std::make_unique<wam::macos::QtMetalVideoItem>();
  auto* video = videoOwner.get();
  video->setParentItem(rootItem);
  video->setSize(QSizeF(320, 240));
  video->setZ(0);

  window.show();
  window.requestUpdate();
  WAM_CHECK(spinUntil([&] { return window.isSceneGraphInitialized(); }, 5000));
  WAM_CHECK(window.rendererInterface()->graphicsApi() ==
            QSGRendererInterface::Metal);

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
    PixelBufferCreation creation = tryCreateIOSurfacePixelBuffer(
        colorCase.format, 320, 180);
    if (creation.status != kCVReturnSuccess || creation.buffer == nullptr) {
      if (creation.buffer != nullptr) {
        CVPixelBufferRelease(creation.buffer);
      }
      if (!colorCase.optionalFormat) {
        std::cerr << colorCase.name << " allocation failed with CoreVideo "
                  << creation.status << '\n';
        return EXIT_FAILURE;
      }
      std::cout << "P010 color case unavailable: " << colorCase.name
                << " (CoreVideo status " << creation.status << ")\n";
      continue;
    }
    WAM_CHECK(fillSolid(creation.buffer, colorCase.codes));
    attachColorMetadata(creation.buffer, colorCase.matrix,
                        kCVImageBufferChromaLocation_Center);
    const QImage image =
        submitOwnedBufferAndGrab(video, &window, creation.buffer);
    const QColor pixel = sampleLogicalPixel(image, window, 20, 60);
    checkColorNear(pixel, colorCase.expected, 4, colorCase.name);
    WAM_CHECK(video->stats().lastPixelFormat == colorCase.format);
    if (colorCase.format ==
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
      ++p010VideoCases;
    } else if (colorCase.format ==
               kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
      ++p010FullCases;
    }
  }
  WAM_CHECK(p010VideoCases == 0 || p010VideoCases == 2);
  WAM_CHECK(p010FullCases == 0 || p010FullCases == 2);

  wam::macos::QtMetalVideoItemStats stats = video->stats();
  WAM_CHECK(stats.lastError.isEmpty());
  WAM_CHECK(stats.exactQtMetalDevice);
  WAM_CHECK(stats.exactSourceIOSurface);
  WAM_CHECK(stats.framesInFlight >= 1);
  WAM_CHECK(stats.framesInFlight <=
            wam::macos::QtFrameSlotRetainer::kMaximumSlots);

  PixelBufferCreation white = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 180);
  WAM_CHECK(white.status == kCVReturnSuccess && white.buffer != nullptr);
  WAM_CHECK(fillSolid(white.buffer, {235, 128, 128}));
  attachColorMetadata(white.buffer, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Center);
  const QImage whiteImage = submitOwnedBufferAndGrab(video, &window, white.buffer);
  checkColorNear(sampleLogicalPixel(whiteImage, window, 20, 15),
                 QColor(0, 0, 0), 4, "letterbox");
  checkColorNear(sampleLogicalPixel(whiteImage, window, 20, 60),
                 QColor(255, 255, 255), 4, "white video");
  checkColorNear(sampleLogicalPixel(whiteImage, window, 160, 120),
                 QColor(255, 127, 127), 5, "translucent QML overlay");

  video->setOpacity(0.5);
  window.requestUpdate();
  const QImage opacityImage = window.grabWindow();
  WAM_CHECK(!opacityImage.isNull());
  checkColorNear(sampleLogicalPixel(opacityImage, window, 20, 60),
                 QColor(128, 128, 128), 5,
                 "premultiplied half-opacity video");
  video->setOpacity(1.0);
  window.requestUpdate();

  PixelBufferCreation centered = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, 4);
  WAM_CHECK(centered.status == kCVReturnSuccess && centered.buffer != nullptr);
  WAM_CHECK(fillAlternatingChroma(centered.buffer));
  attachColorMetadata(centered.buffer, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Center);
  const QImage centeredImage =
      submitOwnedBufferAndGrab(video, &window, centered.buffer);
  checkColorNear(sampleLogicalPixel(centeredImage, window, 60, 100),
                 QColor(128, 140, 10), 6, "center-sited chroma");

  PixelBufferCreation left = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, 4);
  WAM_CHECK(left.status == kCVReturnSuccess && left.buffer != nullptr);
  WAM_CHECK(fillAlternatingChroma(left.buffer));
  attachColorMetadata(left.buffer, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Left);
  const QImage leftImage = submitOwnedBufferAndGrab(video, &window, left.buffer);
  checkColorNear(sampleLogicalPixel(leftImage, window, 60, 100),
                 QColor(128, 128, 128), 6, "left-sited chroma");

  PixelBufferCreation bt2020 = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 180);
  WAM_CHECK(bt2020.status == kCVReturnSuccess && bt2020.buffer != nullptr);
  WAM_CHECK(fillSolid(bt2020.buffer, {80, 112, 216}));
  attachColorMetadata(bt2020.buffer, kCVImageBufferYCbCrMatrix_ITU_R_2020,
                      kCVImageBufferChromaLocation_Center);
  submitOwnedBufferExpectRejected(video, &window, bt2020.buffer,
                                  QStringLiteral("YCbCr matrix"));

  PixelBufferCreation topLeft = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 180);
  WAM_CHECK(topLeft.status == kCVReturnSuccess && topLeft.buffer != nullptr);
  WAM_CHECK(fillSolid(topLeft.buffer, {80, 112, 216}));
  attachColorMetadata(topLeft.buffer, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_TopLeft);
  submitOwnedBufferExpectRejected(video, &window, topLeft.buffer,
                                  QStringLiteral("chroma siting"));

  stats = video->stats();
  const std::uint64_t beforeCycling = stats.importedFrames;
  const std::uint64_t destroyedBeforeCycling = stats.destroyedResourceSets;
  std::set<IOSurfaceID> surfaceIds;
  for (int index = 0; index < stats.framesInFlight + 2; ++index) {
    PixelBufferCreation distinct = tryCreateIOSurfacePixelBuffer(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 180);
    WAM_CHECK(distinct.status == kCVReturnSuccess && distinct.buffer != nullptr);
    WAM_CHECK(fillSolid(
        distinct.buffer,
        {static_cast<std::uint16_t>(32 + index * 16), 128, 128}));
    attachColorMetadata(distinct.buffer,
                        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        kCVImageBufferChromaLocation_Center);
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(distinct.buffer);
    WAM_CHECK(surface != nullptr);
    const IOSurfaceID surfaceId = IOSurfaceGetID(surface);
    WAM_CHECK(surfaceId != 0);
    WAM_CHECK(surfaceIds.insert(surfaceId).second);

    wam::macos::FrameLease frame(distinct.buffer);
    CVPixelBufferRelease(distinct.buffer);
    video->submitFrame(std::move(frame));
    window.requestUpdate();
    const std::uint64_t expected =
        beforeCycling + static_cast<std::uint64_t>(index + 1);
    WAM_CHECK(spinUntil(
        [&] {
          const auto current = video->stats();
          return current.importedFrames >= expected &&
                 current.lastError.isEmpty();
        },
        5000));
  }
  const QImage cycledImage = window.grabWindow();
  WAM_CHECK(!cycledImage.isNull());
  stats = video->stats();
  WAM_CHECK(stats.activeResourceSets <=
            static_cast<std::size_t>(
                wam::macos::QtFrameSlotRetainer::kMaximumSlots + 1));
  WAM_CHECK(stats.destroyedResourceSets > destroyedBeforeCycling);

  // Two simultaneously visible items must never compare as the same material.
  // A per-node resource serial renders both halves with the first item's
  // textures even though the material has NoBatching set.
  video->setSize(QSizeF(160, 240));
  auto secondVideoOwner = std::make_unique<wam::macos::QtMetalVideoItem>();
  auto* secondVideo = secondVideoOwner.get();
  secondVideo->setParentItem(rootItem);
  secondVideo->setX(160);
  secondVideo->setSize(QSizeF(160, 240));
  secondVideo->setZ(0);

  PixelBufferCreation firstItemWhite = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 180);
  WAM_CHECK(firstItemWhite.status == kCVReturnSuccess &&
            firstItemWhite.buffer != nullptr);
  WAM_CHECK(fillSolid(firstItemWhite.buffer, {235, 128, 128}));
  attachColorMetadata(firstItemWhite.buffer,
                      kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Center);
  submitOwnedBufferAndGrab(video, &window, firstItemWhite.buffer);

  PixelBufferCreation secondItemRed = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 180);
  WAM_CHECK(secondItemRed.status == kCVReturnSuccess &&
            secondItemRed.buffer != nullptr);
  WAM_CHECK(fillSolid(secondItemRed.buffer, {80, 112, 216}));
  attachColorMetadata(secondItemRed.buffer,
                      kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Center);
  const QImage twoItemImage =
      submitOwnedBufferAndGrab(secondVideo, &window, secondItemRed.buffer);
  checkColorNear(sampleLogicalPixel(twoItemImage, window, 80, 120),
                 QColor(255, 255, 255), 4, "first distinct video item");
  checkColorNear(sampleLogicalPixel(twoItemImage, window, 240, 120),
                 QColor(232, 31, 41), 4, "second distinct video item");
  WAM_CHECK(video->stats().activeResourceSets > 0);
  WAM_CHECK(secondVideo->stats().activeResourceSets > 0);

  // Removing an item must synchronously retire its render-node resources on a
  // subsequent scene-graph round. The latest plain FrameLease may remain in
  // SharedState, but QSG/Metal imported resource sets must reach zero.
  secondVideo->setParentItem(nullptr);
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return secondVideo->stats().activeResourceSets == 0; }, 5000));
  secondVideoOwner.reset();

  video->setX(0);
  video->setSize(QSizeF(320, 240));
  window.requestUpdate();
  const QImage beforeInvalidationImage = window.grabWindow();
  WAM_CHECK(!beforeInvalidationImage.isNull());
  checkColorNear(sampleLogicalPixel(beforeInvalidationImage, window, 20, 60),
                 QColor(255, 255, 255), 4,
                 "retained frame before scene-graph invalidation");

  // Force the same lifecycle Qt uses for minimized/non-persistent windows.
  // No decoder submission occurs between hide and show: the recreated node
  // must import SharedState's retained latest frame itself.
  const auto beforeInvalidationStats = video->stats();
  const int invalidationsBefore =
      sceneGraphInvalidations.load(std::memory_order_relaxed);
  window.hide();
  window.releaseResources();
  WAM_CHECK(spinUntil(
      [&] {
        return sceneGraphInvalidations.load(std::memory_order_relaxed) >
                   invalidationsBefore &&
               video->stats().activeResourceSets == 0;
      },
      5000));
  WAM_CHECK(video->stats().submittedFrames ==
            beforeInvalidationStats.submittedFrames);

  window.show();
  window.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return window.isSceneGraphInitialized() &&
               current.importedFrames >=
                   beforeInvalidationStats.importedFrames + 1 &&
               current.activeResourceSets > 0 && current.lastError.isEmpty();
      },
      5000));
  WAM_CHECK(video->stats().submittedFrames ==
            beforeInvalidationStats.submittedFrames);
  const QImage afterInvalidationImage = window.grabWindow();
  WAM_CHECK(!afterInvalidationImage.isNull());
  checkColorNear(sampleLogicalPixel(afterInvalidationImage, window, 20, 60),
                 QColor(255, 255, 255), 4,
                 "retained frame after scene-graph recreation");

  // Reparenting between live QQuickWindows creates another render node. This
  // exercises window migration (the common device remains Qt-owned) without a
  // decoder resubmit and catches node-local pending-frame implementations.
  QQuickWindow migrationWindow;
  migrationWindow.resize(320, 240);
  migrationWindow.setColor(Qt::black);
  migrationWindow.setPersistentSceneGraph(false);
  migrationWindow.setPersistentGraphics(false);
  migrationWindow.show();
  migrationWindow.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return migrationWindow.isSceneGraphInitialized(); }, 5000));
  const auto beforeMigrationStats = video->stats();
  video->setParentItem(migrationWindow.contentItem());
  video->setX(0);
  video->setSize(QSizeF(320, 240));
  window.requestUpdate();
  migrationWindow.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto current = video->stats();
        return current.importedFrames >= beforeMigrationStats.importedFrames + 1 &&
               current.lastError.isEmpty();
      },
      5000));
  WAM_CHECK(video->stats().submittedFrames ==
            beforeMigrationStats.submittedFrames);
  const QImage migratedImage = migrationWindow.grabWindow();
  WAM_CHECK(!migratedImage.isNull());
  checkColorNear(
      sampleLogicalPixel(migratedImage, migrationWindow, 20, 60),
      QColor(255, 255, 255), 4, "retained frame after window migration");

#if defined(WAM_NATIVE_METAL_VIDEO_TESTING)
  // Settle every Qt frame slot onto the current white resource before taking
  // exact lifetime/accounting baselines for rejected handoffs.
  window.requestUpdate();
  for (int settle = 0;
       settle < wam::macos::QtFrameSlotRetainer::kMaximumSlots + 1; ++settle) {
    migrationWindow.requestUpdate();
    WAM_CHECK(!migrationWindow.grabWindow().isNull());
  }
  WAM_CHECK(spinUntil(
      [&] { return video->stats().activeResourceSets == 1; }, 5000));

  const auto beforeSynchronizationFailure = video->stats();
  const auto budgetBeforeSynchronizationFailure =
      wam::macos::NativeSurfaceBudget::stats();
  const std::uint64_t synchronizationFailuresBefore =
      wam::macos::qtMetalSynchronizationTokenCopyFailuresForTesting();
  const std::uint64_t serialBeforeSynchronizationFailure =
      wam::macos::qtMetalNextResourceSerialForTesting();
  PixelBufferCreation synchronizationFailure = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 180);
  WAM_CHECK(synchronizationFailure.status == kCVReturnSuccess &&
            synchronizationFailure.buffer != nullptr);
  WAM_CHECK(fillSolid(synchronizationFailure.buffer, {80, 112, 216}));
  attachColorMetadata(synchronizationFailure.buffer,
                      kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Center);
  IOSurfaceRef synchronizationFailureSurface =
      CVPixelBufferGetIOSurface(synchronizationFailure.buffer);
  WAM_CHECK(synchronizationFailureSurface != nullptr);
  const std::uint64_t synchronizationFailureBytes =
      static_cast<std::uint64_t>(
          IOSurfaceGetAllocSize(synchronizationFailureSurface));
  wam::macos::FrameLease synchronizationFailureLease(
      synchronizationFailure.buffer);
  WAM_CHECK(synchronizationFailureLease);
  const auto synchronizationBudgetCharged =
      wam::macos::NativeSurfaceBudget::stats();
  WAM_CHECK(synchronizationBudgetCharged.currentSurfaces ==
            budgetBeforeSynchronizationFailure.currentSurfaces + 1);
  WAM_CHECK(synchronizationBudgetCharged.currentBytes ==
            budgetBeforeSynchronizationFailure.currentBytes +
                synchronizationFailureBytes);
  CVPixelBufferRelease(synchronizationFailure.buffer);
  wam::macos::failNextQtMetalSynchronizationTokenCopyForTesting();
  video->submitFrame(std::move(synchronizationFailureLease));
  migrationWindow.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto currentBudget = wam::macos::NativeSurfaceBudget::stats();
        const std::uint64_t failureCount =
            wam::macos::
                qtMetalSynchronizationTokenCopyFailuresForTesting();
        return video->stats().lastError.contains(
                   QStringLiteral("scene-graph synchronization")) &&
               failureCount == synchronizationFailuresBefore + 1 &&
               currentBudget.currentSurfaces ==
                   budgetBeforeSynchronizationFailure.currentSurfaces &&
               currentBudget.currentBytes ==
                   budgetBeforeSynchronizationFailure.currentBytes;
      },
      5000));
  const auto afterSynchronizationFailure = video->stats();
  WAM_CHECK(afterSynchronizationFailure.importedFrames ==
            beforeSynchronizationFailure.importedFrames);
  WAM_CHECK(afterSynchronizationFailure.activeResourceSets ==
            beforeSynchronizationFailure.activeResourceSets);
  WAM_CHECK(wam::macos::qtMetalNextResourceSerialForTesting() ==
            serialBeforeSynchronizationFailure);
  for (int retry = 0; retry < 3; ++retry) {
    migrationWindow.requestUpdate();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  }
  WAM_CHECK(
      wam::macos::qtMetalSynchronizationTokenCopyFailuresForTesting() ==
      synchronizationFailuresBefore + 1);
  WAM_CHECK(video->stats().importedFrames ==
            beforeSynchronizationFailure.importedFrames);
  WAM_CHECK(wam::macos::qtMetalNextResourceSerialForTesting() ==
            serialBeforeSynchronizationFailure);
  checkColorNear(sampleLogicalPixel(migrationWindow.grabWindow(),
                                    migrationWindow, 20, 60),
                 QColor(255, 255, 255), 4,
                 "frame after Metal synchronization token-copy failure");

  const auto beforeImportFailure = video->stats();
  const auto budgetBeforeImportFailure =
      wam::macos::NativeSurfaceBudget::stats();
  const std::uint64_t importFailuresBefore =
      wam::macos::qtMetalImportTokenCopyFailuresForTesting();
  const std::uint64_t serialBeforeImportFailure =
      wam::macos::qtMetalNextResourceSerialForTesting();
  PixelBufferCreation importFailure = tryCreateIOSurfacePixelBuffer(
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 320, 180);
  WAM_CHECK(importFailure.status == kCVReturnSuccess &&
            importFailure.buffer != nullptr);
  WAM_CHECK(fillSolid(importFailure.buffer, {80, 112, 216}));
  attachColorMetadata(importFailure.buffer,
                      kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                      kCVImageBufferChromaLocation_Center);
  IOSurfaceRef importFailureSurface =
      CVPixelBufferGetIOSurface(importFailure.buffer);
  WAM_CHECK(importFailureSurface != nullptr);
  const std::uint64_t importFailureBytes = static_cast<std::uint64_t>(
      IOSurfaceGetAllocSize(importFailureSurface));
  wam::macos::FrameLease importFailureLease(importFailure.buffer);
  WAM_CHECK(importFailureLease);
  const auto importBudgetCharged =
      wam::macos::NativeSurfaceBudget::stats();
  WAM_CHECK(importBudgetCharged.currentSurfaces ==
            budgetBeforeImportFailure.currentSurfaces + 1);
  WAM_CHECK(importBudgetCharged.currentBytes ==
            budgetBeforeImportFailure.currentBytes + importFailureBytes);
  CVPixelBufferRelease(importFailure.buffer);
  wam::macos::failNextQtMetalImportTokenCopyForTesting();
  video->submitFrame(std::move(importFailureLease));
  migrationWindow.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] {
        const auto currentBudget = wam::macos::NativeSurfaceBudget::stats();
        return video->stats().lastError.contains(
                   QStringLiteral("import accounting-token copy")) &&
               wam::macos::qtMetalImportTokenCopyFailuresForTesting() ==
                   importFailuresBefore + 1 &&
               currentBudget.currentSurfaces ==
                   budgetBeforeImportFailure.currentSurfaces &&
               currentBudget.currentBytes ==
                   budgetBeforeImportFailure.currentBytes;
      },
      5000));
  const auto afterImportFailure = video->stats();
  WAM_CHECK(afterImportFailure.importedFrames ==
            beforeImportFailure.importedFrames);
  WAM_CHECK(afterImportFailure.activeResourceSets ==
            beforeImportFailure.activeResourceSets);
  WAM_CHECK(wam::macos::qtMetalNextResourceSerialForTesting() ==
            serialBeforeImportFailure);
  for (int retry = 0; retry < 3; ++retry) {
    migrationWindow.requestUpdate();
    QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
  }
  WAM_CHECK(wam::macos::qtMetalImportTokenCopyFailuresForTesting() ==
            importFailuresBefore + 1);
  WAM_CHECK(video->stats().importedFrames ==
            beforeImportFailure.importedFrames);
  WAM_CHECK(wam::macos::qtMetalNextResourceSerialForTesting() ==
            serialBeforeImportFailure);
  checkColorNear(sampleLogicalPixel(migrationWindow.grabWindow(),
                                    migrationWindow, 20, 60),
                 QColor(255, 255, 255), 4,
                 "frame after Metal import token-copy failure");
#endif

  video->setParentItem(nullptr);
  migrationWindow.requestUpdate();
  WAM_CHECK(spinUntil(
      [&] { return video->stats().activeResourceSets == 0; }, 5000));
  stats = video->stats();
  videoOwner.reset();
  migrationWindow.hide();
  migrationWindow.releaseResources();
  window.hide();
  window.releaseResources();
  QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
  std::cout << "Qt Metal IOSurface compositor gate passed: NV12 full/video "
               "BT.601/709 pixels, center/left siting, premultiplied opacity, "
               "strict metadata rejection, translucent QML z-order, exact Qt "
               "MTLDevice/source IOSurface, distinct frame-slot lifetimes, "
               "two-item resource identity, fail-closed frame slots, paused "
               "scene-graph recreation, and live-window migration";
  if (p010VideoCases == 2) {
    std::cout << "; P010 video-range pixels passed";
  }
  if (p010FullCases == 2) {
    std::cout << "; P010 full-range pixels passed";
  }
  std::cout << " (framesInFlight=" << stats.framesInFlight
            << ", activeSets=" << stats.activeResourceSets << ")\n";
  return EXIT_SUCCESS;
}
