#pragma once

#include "metal_layer_presenter.hpp"
#include "video_toolbox_decoder.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>

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

// Container names are conservative routing hints. Families known to need the
// not-yet-implemented external bridge fail closed before AVFoundation; an
// absent or unrecognized suffix remains an AVFoundation probe candidate. A
// familiar suffix never proves that compressed samples can be extracted.
enum class NativeVideoContainerFamily : std::uint8_t {
  Unknown,
  IsoBaseMedia,
  QuickTime,
  Matroska,
  WebM,
  Avi,
  MpegTransportStream,
  Ogg,
  FlashVideo,
};

enum class NativeVideoDemuxPreference : std::uint8_t {
  ProbeAvFoundation,
  AvFoundation,
  ExternalBridgeRequired,
};

struct NativeVideoContainerAdmissionHint {
  NativeVideoContainerFamily container{NativeVideoContainerFamily::Unknown};
  NativeVideoDemuxPreference preferredDemux{
      NativeVideoDemuxPreference::ProbeAvFoundation};
};

// VP9 and AV1 are machine-dependent: they are reported only when this host can
// actually hardware-decode them (see native_video_codec_capability.hpp).
enum class NativeVideoCodecAdmission : std::uint8_t {
  Unsupported,
  H264,
  Hevc,
  Vp9,
  Av1,
};

enum class NativeVideoSampleFormatAdmission : std::uint8_t {
  Unsupported,
  Yuv420EightBit,
  Yuv420TenBit,
};

// These allocation-free helpers describe two independent native gates. A
// container must first yield compressed samples through an implemented demux
// backend, and only then can its codec be considered for VideoToolbox. The
// current implementation has only AVFoundation; ExternalBridgeRequired is a
// future route and remains ineligible for native activation.
[[nodiscard]] NativeVideoContainerAdmissionHint
nativeVideoContainerAdmissionHint(std::string_view path) noexcept;
[[nodiscard]] NativeVideoCodecAdmission nativeVideoCodecAdmission(
    std::uint32_t mediaSubtype) noexcept;
[[nodiscard]] NativeVideoSampleFormatAdmission
nativeVideoSampleFormatAdmission(
    std::uint32_t mediaSubtype,
    std::span<const std::byte> codecConfiguration) noexcept;

enum class NativeVideoOutputMode : std::uint8_t {
  MetalLayer,
  QtOpenGL,
};

enum class NativeScheduledFrameDispatchResult : std::uint8_t {
  Dispatched,
  Backpressure,
  Rejected,
  Failed,
};

struct NativeScheduledFrameOutputStats {
  bool closed{false};
  bool deliveryQueued{false};
  std::uint64_t acceptedGeneration{0};
  std::uint64_t dispatchedFrames{0};
  std::uint64_t deliveredFrames{0};
  std::uint64_t coalescedFrames{0};
  std::uint64_t staleFrames{0};
  std::uint64_t rejectedFrames{0};
  // The three render-pass counters below are activity-sampled by the dormant
  // Qt adapter. They are refreshed by start/dispatch/flush/failure/retirement
  // observation, but can lag redraws of a retained frame while playback is
  // otherwise quiescent. A future runtime benchmark must request an explicit
  // GUI-linearized presenter snapshot instead of treating stats() as a
  // per-render notification.
  // Adapter-lifetime Qt render passes. Qt may redraw one retained lease more
  // than once, so this is deliberately not a unique-frame count and can
  // exceed dispatchedFrames.
  std::uint64_t actuallyRenderedFrames{0};
  // Presenter-lifetime successful draws that were still part of its accepted
  // generation when the completion fence was published. This counter and
  // acceptedGeneration are sampled coherently by the presenter.
  std::uint64_t acceptedRenderedFrames{0};
  // Exact accepted draws since the current output failure-handler epoch's
  // startup flush was applied on the GUI thread. Later seek flushes preserve
  // this attempt counter; installing the next handler resets it.
  std::uint64_t attemptAcceptedRenderedFrames{0};
  std::uint64_t lastRenderedGeneration{0};
  std::uint64_t fatalErrorSerial{0};
};

struct NativeScheduledFrameStartAck {
  std::uint64_t requestedGeneration{0};
  std::uint64_t acceptedGeneration{0};
  std::uint64_t acceptedRenderedFrames{0};
};

// Thread-safe boundary between the native scheduler and an externally owned
// GUI presenter. Implementations retain at most one scheduled FrameLease and
// must never call a GUI object from dispatch(), flush(), close(), or stats().
// A failure handler may run on the presenter's GUI thread and therefore must
// return promptly and must not call back into the output.
class NativeScheduledFrameOutput {
 public:
  using FailureHandler = std::function<void(std::string)>;
  using StartAppliedHandler =
      std::function<void(NativeScheduledFrameStartAck)>;

  virtual ~NativeScheduledFrameOutput() = default;
  [[nodiscard]] virtual NativeScheduledFrameDispatchResult dispatch(
      FrameLease frame, std::string* error = nullptr) noexcept = 0;
  // Applies the prepared generation on the GUI/presenter side and invokes the
  // callback only after that flush has linearized against completed draws.
  // Implementations must never invoke it while holding an output lock.
  [[nodiscard]] virtual bool startGeneration(
      std::uint64_t generation, StartAppliedHandler applied,
      std::string* error = nullptr) noexcept = 0;
  [[nodiscard]] virtual bool flush(std::uint64_t nextGeneration,
                                   std::string* error = nullptr) noexcept = 0;
  virtual void close(std::uint64_t finalGeneration) noexcept = 0;
  virtual void setFailureHandler(FailureHandler handler) noexcept = 0;
  [[nodiscard]] virtual NativeScheduledFrameOutputStats stats()
      const noexcept = 0;
};

struct NativeVideoPipelineStats {
  bool prepared{false};
  bool active{false};
  bool stopping{false};
  bool hardwareDecode{false};
  NativeVideoOutputMode outputMode{NativeVideoOutputMode::MetalLayer};
  std::uint64_t generation{0};
  std::uint64_t compressedSamplesRead{0};
  std::uint64_t compressedSamplesSubmitted{0};
  // A scheduled frame was selected as due by the audio-clock scheduler.
  std::uint64_t scheduledFrames{0};
  // The external capacity-one handoff accepted the frame. This is not a
  // presentation acknowledgement; actuallyRenderedFrames is sampled only
  // after Qt's scene graph reports that the frame was drawn.
  std::uint64_t dispatchedFrames{0};
  // Activity-sampled Qt render passes since this pipeline's current
  // preparation began. A retained frame may contribute more than one pass,
  // and quiescent retained-frame redraws can remain unobserved until the next
  // bridge activity. This is not yet a benchmark-grade live counter.
  std::uint64_t actuallyRenderedFrames{0};
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
  // Raw adapter-lifetime totals. Use the top-level counters for the current
  // pipeline preparation epoch.
  NativeScheduledFrameOutputStats scheduledOutput;
};

struct NativeVideoPrepareOutcome {
  // Ready publishes the exact nonzero decoded-frame/output timeline used by
  // startPrepared(). Unsupported and Failed publish zero; request sequencing
  // is internal and never shares this field.
  std::uint64_t generation{0};
  NativeVideoPrepareResult result{NativeVideoPrepareResult::Failed};
  std::string error;
};

// Dormant macOS video-path foundation:
//
//   implemented demux backend (currently AVAssetReader, retaining its ready
//     compressed CMSampleBuffers without an application payload copy)
//     -> VideoToolboxDecoder
//     -> bounded IOSurface queue
//     -> CAMetalLayer
//
// updateAudioClock() re-anchors a monotonic local clock to a future external
// audio/timeline authority so the display-link callback need not poll or wake
// the GUI thread for every frame. The path deliberately accepts only a narrow,
// bounded local SDR 4:2:0 H.264/HEVC subset. Today AVFoundation can route
// MP4/M4V/MOV and may probe additional system-supported containers, but Ready
// requires extraction of one bounded sample with the expected codec first.
// Start/first draw remain the authoritative full packet/decode proof. Formats
// needing a future external compressed-sample bridge remain Unsupported. No
// shipping WAM controller selects this class yet.
class NativeVideoPipeline final {
 public:
  static std::unique_ptr<NativeVideoPipeline> create(
      std::string* error = nullptr);

  // Dormant Qt/OpenGL foundation. This factory is not called or linked by a
  // shipping controller. Unlike create(), a successful preparation stops in
  // Prepared and performs zero decode/presentation work until startPrepared()
  // is called. The output requests CGL-compatible VideoToolbox IOSurfaces.
  static std::unique_ptr<NativeVideoPipeline> createForQtOpenGL(
      std::shared_ptr<NativeScheduledFrameOutput> output,
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
  // stops producing until a host is attached. Accepted work is always queued;
  // this call never reads an AVAsset/AVAssetTrack property and never waits for
  // AVFoundation. Exactly one terminal outcome is published for each accepted
  // request and can be consumed with takePrepareResult(). Only Ready carries
  // the exact nonzero decoded-frame generation; Unsupported and Failed carry
  // zero. A prior outcome must be consumed before another request is admitted.
  [[nodiscard]] bool prepareLocalFileAsync(
      const std::filesystem::path& path, double initialPositionSeconds = 0.0,
      std::string* error = nullptr);
  [[nodiscard]] std::optional<NativeVideoPrepareOutcome>
  takePrepareResult() noexcept;
  // Starts an externally presented pipeline after a Ready outcome has been
  // consumed. The returned value is the admitted decoded-frame generation.
  // Startup remains inert until the output asynchronously acknowledges that
  // this generation was applied to the GUI presenter; only then can the
  // worker/display link enter Running.
  [[nodiscard]] std::optional<std::uint64_t> startPrepared(
      std::string* error = nullptr) noexcept;
  // Revokes playback immediately and retires AVFoundation/VideoToolbox work on
  // a private serial queue. It never joins the worker or waits for Apple
  // callbacks on the calling thread. While stats().stopping is true, a new
  // prepareLocalFileAsync() fails fast instead of accumulating retired
  // sessions.
  // Admission is process-wide, so frontend recreation cannot bypass the bound.
  // Returns the exact invalidation generation applied to the external output.
  // Repeated calls during the same retirement return the existing generation.
  [[nodiscard]] std::uint64_t stop() noexcept;

  // Calls are cheap: they update a small clock snapshot and start/stop the
  // display link only on state transitions.
  void updateAudioClock(double positionSeconds, bool paused,
                        double rate) noexcept;
  // Returns the exact new generation after the output has rejected all older
  // scheduled deliveries, or nullopt when no active seek was accepted.
  [[nodiscard]] std::optional<std::uint64_t> seek(
      double positionSeconds) noexcept;

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
  // Deterministic lifetime/exception seams. They are compiled only into the
  // isolated test implementation; the shipping native library has no fault
  // flags or test entry points.
  static void failNextFactoryWrapperAllocation();
  static bool exercisePresentationExceptionBoundary(
      NativeVideoPipeline& pipeline) noexcept;
  static void failNextWorkerSampleSubmission(
      NativeVideoPipeline& pipeline) noexcept;
  static bool hasActiveReader(const NativeVideoPipeline& pipeline) noexcept;
  static void failNextDisplayLinkStart(
      NativeVideoPipeline& pipeline) noexcept;
  static void failNextDisplayLinkStop(
      NativeVideoPipeline& pipeline) noexcept;
  static bool setDisplayLinkRunning(
      NativeVideoPipeline& pipeline, bool running) noexcept;
  static bool displayLinkHealthy(
      const NativeVideoPipeline& pipeline) noexcept;
  static void setPreparationLoadBarrier(
      NativeVideoPipeline& pipeline, std::shared_future<void> release,
      std::shared_ptr<std::atomic<bool>> entered);
  static void setAssetLoadCallbackBarrier(
      NativeVideoPipeline& pipeline, std::shared_future<void> release,
      std::shared_ptr<std::atomic<bool>> entered);
  static void setTrackLoadCallbackBarrier(
      NativeVideoPipeline& pipeline, std::shared_future<void> release,
      std::shared_ptr<std::atomic<bool>> entered);
  static void setPreparationCancellationMarker(
      NativeVideoPipeline& pipeline,
      std::shared_ptr<std::atomic<bool>> entered);
  static void failNextPreparationAfterResourceTransfer(
      NativeVideoPipeline& pipeline);
  static void setPreparationCommitBarrier(
      NativeVideoPipeline& pipeline, std::shared_future<void> release,
      std::shared_ptr<std::atomic<bool>> entered);
  static void setRetirementBarrier(
      NativeVideoPipeline& pipeline, std::shared_future<void> release,
      std::shared_ptr<std::atomic<bool>> entered);
  static void setStartPreparedPostWorkerBarrier(
      NativeVideoPipeline& pipeline, std::shared_future<void> release,
      std::shared_ptr<std::atomic<bool>> entered);
};
#endif

}  // namespace wam::macos
