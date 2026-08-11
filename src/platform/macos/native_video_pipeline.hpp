#pragma once

#include "metal_layer_presenter.hpp"
#include "video_toolbox_decoder.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
#include <atomic>
#include <future>
#endif

namespace wam::macos {

#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
struct NativeVideoPipelineTestAccess;
#endif

enum class NativeVideoPrepareResult : std::uint8_t {
  Ready,
  Unsupported,
  Failed,
};

struct NativeVideoPipelineStats {
  bool prepared{false};
  bool active{false};
  bool stopping{false};
  bool hardwareDecode{false};
  std::uint64_t generation{0};
  std::uint64_t compressedSamplesRead{0};
  std::uint64_t compressedSamplesSubmitted{0};
  std::uint64_t presentedFrames{0};
  std::uint64_t lateFramesDropped{0};
  std::uint64_t staleFramesDropped{0};
  std::uint64_t presenterBackpressureEvents{0};
  std::uint64_t drawableUnavailableEvents{0};
  std::uint64_t displayLinkTicks{0};
  std::size_t queueDepth{0};
  std::size_t queueCapacity{0};
  VideoToolboxDecoderStats decoder;
  MetalLayerPresenterStats presenter;
};

// Dormant macOS video-path foundation:
//
//   AVAssetReader (compressed MP4/MOV samples)
//     -> VideoToolboxDecoder
//     -> bounded IOSurface queue
//     -> CAMetalLayer
//
// updateAudioClock() re-anchors a monotonic local clock to a future external
// audio/timeline authority so the display-link callback need not poll or wake
// the GUI thread for every frame. The path deliberately accepts only a narrow,
// bounded local SDR H.264/HEVC subset; every other source returns Unsupported.
// No shipping WAM controller selects this class yet.
class NativeVideoPipeline final {
 public:
  static std::unique_ptr<NativeVideoPipeline> create(
      std::string* error = nullptr);

  NativeVideoPipeline(const NativeVideoPipeline&) = delete;
  NativeVideoPipeline& operator=(const NativeVideoPipeline&) = delete;
  ~NativeVideoPipeline();

  // nativeView is an NSView* encoded as void*. These view/layer operations
  // must be called on the AppKit main thread.
  [[nodiscard]] bool attachToView(void* nativeView,
                                  std::string* error = nullptr);
  void detach() noexcept;
  void resize(double widthPoints, double heightPoints,
              double backingScale) noexcept;

  // Preparation may run before attachToView() for headless validation or
  // startup prebuffering. Drawable absence is non-fatal and the bounded queue
  // stops producing until a host is attached. This dormant probe still queries
  // AVAsset keys synchronously and must not run on an interactive UI thread;
  // production activation is blocked on cancellable asynchronous key loading.
  [[nodiscard]] NativeVideoPrepareResult prepareLocalFile(
      const std::filesystem::path& path, double initialPositionSeconds = 0.0,
      std::string* error = nullptr);
  // Revokes playback immediately and retires AVFoundation/VideoToolbox work on
  // a private serial queue. It never joins the worker or waits for Apple
  // callbacks on the calling thread. While stats().stopping is true, a new
  // prepareLocalFile() fails fast instead of accumulating retired sessions.
  // Admission is process-wide, so frontend recreation cannot bypass the bound.
  void stop() noexcept;

  // Calls are cheap: they update a small clock snapshot and start/stop the
  // display link only on state transitions.
  void updateAudioClock(double positionSeconds, bool paused,
                        double rate) noexcept;
  void seek(double positionSeconds) noexcept;

  [[nodiscard]] bool attached() const noexcept;
  [[nodiscard]] bool active() const noexcept;
  // Asynchronous decode/presentation failures are latched here instead of
  // invoking arbitrary client code from internal or post-destruction stacks.
  [[nodiscard]] std::optional<std::string> takeLastError() noexcept;
  [[nodiscard]] NativeVideoPipelineStats stats() const noexcept;

 private:
#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
  friend struct NativeVideoPipelineTestAccess;
#endif
  struct Impl;
  explicit NativeVideoPipeline(std::shared_ptr<Impl> impl) noexcept;
  std::shared_ptr<Impl> impl_;
};

#if defined(WAM_NATIVE_VIDEO_PIPELINE_TESTING)
// Private deterministic scheduling seams for the native pipeline integration
// test. Production builds do not compile or expose these methods.
struct NativeVideoPipelineTestAccess {
  static void setPreparationCommitBarrier(
      NativeVideoPipeline& pipeline, std::shared_future<void> release,
      std::shared_ptr<std::atomic<bool>> entered);
  static void setRetirementBarrier(
      NativeVideoPipeline& pipeline, std::shared_future<void> release,
      std::shared_ptr<std::atomic<bool>> entered);
};
#endif

}  // namespace wam::macos
