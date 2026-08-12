#pragma once

#include "native_video_presenter.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace wam::macos {

struct MetalLayerPresenterStats {
  std::uint64_t submittedFrames{0};
  std::uint64_t completedFrames{0};
  std::uint64_t failedFrames{0};
  std::size_t inFlightFrames{0};
};

enum class MetalPresentResult : std::uint8_t {
  Presented,
  Backpressure,
  DrawableUnavailable,
  Failed,
};

#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
// Deterministic exception seams for the focused presenter test. The shipping
// native-video library is built without this definition, so neither the seam
// nor its state exists in production.
enum class MetalLayerPresenterFaultPoint : std::uint8_t {
  None,
  CompletionGroupAllocation,
  ErrorAssignment,
  TextureImport,
  FrameLeaseAllocation,
  CompletionTicketAllocation,
  FailureHandlerCopy,
  CompletionHandlerInstallation,
  CommandBufferCommit,
};

struct MetalLayerPresenterTestAccess;
#endif

// A compact CAMetalLayer presenter for IOSurface-backed VideoToolbox output.
// attachToView(), resize(), and detach() are main-thread operations. present()
// belongs on a dedicated serial presentation queue (never the real-time
// display-link callback) and performs no CPU pixel conversion.
class MetalLayerPresenter final {
 public:
  using FailureHandler = std::function<void(std::string)>;

  static std::unique_ptr<MetalLayerPresenter> create(
      std::string* error = nullptr);

  MetalLayerPresenter(const MetalLayerPresenter&) = delete;
  MetalLayerPresenter& operator=(const MetalLayerPresenter&) = delete;
  ~MetalLayerPresenter();

  // nativeView must be an NSView* encoded as void*.
  [[nodiscard]] bool attachToView(void* nativeView,
                                  std::string* error = nullptr);
  void detach() noexcept;
  void resize(double widthPoints, double heightPoints,
              double backingScale) noexcept;
  void setVisible(bool visible) noexcept;

  // Command-buffer failures are asynchronous. The handler runs only while its
  // weak lifetime token can be promoted and always after presenter locks are
  // released; callers must use a token that owns every handler capture.
  void setFailureHandler(std::weak_ptr<void> lifetime,
                         FailureHandler handler) noexcept;

  [[nodiscard]] MetalPresentResult present(
      const FrameLease& frame, std::string* error = nullptr) noexcept;
  [[nodiscard]] MetalLayerPresenterStats stats() const noexcept;

 private:
  struct Impl;
  explicit MetalLayerPresenter(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
  friend struct MetalLayerPresenterTestAccess;
#endif
};

#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
struct MetalLayerPresenterTestAccess {
  struct FaultOutcome {
    MetalLayerPresenterStats statistics;
    bool exceptionCaught{false};
    bool groupIdle{false};
  };

  static void failNext(MetalLayerPresenterFaultPoint point) noexcept;
  [[nodiscard]] static bool faultPending() noexcept;
  [[nodiscard]] static FaultOutcome exerciseAccountingFault(
      MetalLayerPresenterFaultPoint point) noexcept;
  [[nodiscard]] static bool completionGroupIdle(
      const MetalLayerPresenter& presenter) noexcept;
};
#endif

}  // namespace wam::macos
