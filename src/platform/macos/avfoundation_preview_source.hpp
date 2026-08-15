#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/avfoundation_asset_context.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <type_traits>
#include <variant>

namespace wam::macos {

#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
struct AVFoundationPreviewSourceTestAccess;
using AVFoundationPreviewCancelInterleaveHook = void (*)(
    std::uint64_t epoch, void* context) noexcept;
#endif

// Immutable input shared by every short-lived preview reader. The descriptor
// is the one already admitted by the main native source. Preview never selects
// tracks, opens audio, or publishes its private epochs as playback generations.
struct AVFoundationPreviewBinding {
  std::filesystem::path localPath;
  std::shared_ptr<const media::MediaSourceDescriptor> descriptor;
  media::MediaSourceLimits limits{};
  // Production sessions provide the immutable context admitted by the main
  // source. Null keeps the standalone cold-load path available for isolated
  // preview use and injected tests.
  std::shared_ptr<const AVFoundationAssetContext> assetContext{};
};

struct AVFoundationPreviewRequest {
  // Private, strictly increasing cancellation identity. This value is used in
  // returned MediaSample::generation only inside the preview graph; it must
  // never be passed to NativeMediaDispatcher or NativeAudioSession.
  std::uint64_t epoch{0};
  media::MediaTime target{};
};

enum class AVFoundationPreviewStatus : std::uint8_t {
  Rejected,
  Ready,
  Unsupported,
  Cancelled,
  Failed,
};

struct AVFoundationPreviewBeginOutcome {
  AVFoundationPreviewStatus status{AVFoundationPreviewStatus::Rejected};
  std::uint64_t epoch{0};
  media::MediaTime actualDecodeStart{};
  std::string error;
};

enum class AVFoundationPreviewSampleStatus : std::uint8_t {
  Sample,
  EndOfStream,
  Cancelled,
  Failed,
};

struct AVFoundationPreviewCopiedSample {
  // Sample carries Create/Copy ownership. The caller must release it or move
  // the +1 reference into a MediaPayloadLease.
  CMSampleBufferRef sample{nullptr};
  AVFoundationPreviewSampleStatus status{
      AVFoundationPreviewSampleStatus::Failed};
  std::string error;
};

struct AVFoundationPreviewEndOfStream {
  std::uint64_t epoch{0};
};

struct AVFoundationPreviewCancelled {
  std::uint64_t epoch{0};
};

struct AVFoundationPreviewFailure {
  std::uint64_t epoch{0};
  std::string error;
};

using AVFoundationPreviewReadResult =
    std::variant<media::MediaSample, media::MediaDiscontinuity,
                 AVFoundationPreviewEndOfStream, AVFoundationPreviewCancelled,
                 AVFoundationPreviewFailure>;

// Production facts are cumulative across reader replacement. assetLoad* is
// the cold immutable-asset/track admission cost; later preview requests reuse
// that cache and create only a video AVAssetReader.
struct AVFoundationPreviewBackendFacts {
  std::uint64_t assetLoadAttempts{0};
  std::uint64_t assetLoadsCompleted{0};
  std::uint64_t assetLoadNanoseconds{0};
  std::uint64_t readersCreated{0};
  std::uint64_t readersStarted{0};
};

#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
// Exact snapshots from the production shared-context branch. The probe models
// one failed reader initialization followed by one successfully started
// reader, while using the same accounting methods as ProductionPreviewGeneration.
struct AVFoundationPreviewSharedContextProbe {
  bool sharedLoadReady{false};
  AVFoundationPreviewBackendFacts backendBefore{};
  AVFoundationPreviewBackendFacts backendAfterSharedLoad{};
  AVFoundationPreviewBackendFacts backendAfterCreationFailure{};
  AVFoundationPreviewBackendFacts backendAfterStartedReader{};
  AVFoundationAssetContextFacts contextBefore{};
  AVFoundationAssetContextFacts contextAfterSharedLoad{};
  AVFoundationAssetContextFacts contextAfterCreationFailure{};
  AVFoundationAssetContextFacts contextAfterStartedReader{};
};
#endif

struct AVFoundationPreviewGenerationStart {
  AVFoundationPreviewStatus status{AVFoundationPreviewStatus::Failed};
  media::MediaTime actualDecodeStart{};
  std::string error;
};

// One video-only reader generation. start() and copyNextVideoSample() are
// confined to the preview owner. cancel() is prompt, noexcept, and may run on
// another thread while either operation is blocked in AVFoundation.
class AVFoundationPreviewGeneration {
 public:
  virtual ~AVFoundationPreviewGeneration() = default;

  [[nodiscard]] virtual std::uint64_t epoch() const noexcept = 0;
  [[nodiscard]] virtual AVFoundationPreviewGenerationStart start() = 0;
  [[nodiscard]] virtual AVFoundationPreviewCopiedSample
  copyNextVideoSample() = 0;
  virtual void cancel() noexcept = 0;
};

class AVFoundationPreviewBackend {
 public:
  virtual ~AVFoundationPreviewBackend() = default;

  // Construction must be bounded and nonblocking. Asset loading, sync lookup,
  // and reader creation stay in Generation::start().
  [[nodiscard]] virtual std::shared_ptr<AVFoundationPreviewGeneration>
  makeGeneration(const AVFoundationPreviewBinding& binding,
                 AVFoundationPreviewRequest request) = 0;
  [[nodiscard]] virtual AVFoundationPreviewBackendFacts facts()
      const noexcept = 0;
};

struct AVFoundationPreviewSourceFacts {
  // Exact public cancellation slot. It can remain nonzero while an older
  // reader is being retired before the matching new reader is constructed.
  std::uint64_t operationEpoch{0};
  std::uint64_t activeEpoch{0};
  std::uint64_t epochHighWater{0};
  media::MediaTime target{};
  media::MediaTime actualDecodeStart{};
  std::size_t stagedSampleBuffers{0};
  std::size_t peakStagedSampleBuffers{0};
  std::uint64_t samplesRead{0};
  std::uint64_t discontinuitiesRead{0};
  // Accepted nondecreasing retargets served by the already-open reader. This
  // is the exact complement to backend.readersCreated for forward scrub
  // coalescing: no AVAssetReader is constructed or restarted for these.
  std::uint64_t forwardRetargets{0};
  bool open{false};
  bool cancelled{false};
  AVFoundationPreviewBackendFacts backend{};
};

// Allocation-free owner-thread snapshot of the one copied CoreMedia sample
// temporarily owned inside readNext(). A zero-byte discontinuity may set
// stagedSamples without charging compressed bytes.
struct AVFoundationPreviewSourceMemoryFacts {
  std::size_t stagedSamples{0};
  std::uint64_t currentStagedCompressedBytes{0};
  std::uint64_t peakStagedCompressedBytes{0};
};
static_assert(
    std::is_trivially_copyable_v<AVFoundationPreviewSourceMemoryFacts>);

// Bounded video-only preview pull source. A newer valid epoch cancels and
// replaces the active reader before it creates the next one. At most one
// copied CMSampleBuffer is staged while readNext() validates and transfers its
// +1 reference; after return the source itself retains no sample buffer.
class AVFoundationPreviewSource final {
 public:
  [[nodiscard]] static std::unique_ptr<AVFoundationPreviewSource>
  create(AVFoundationPreviewBinding binding) noexcept;
  [[nodiscard]] static std::unique_ptr<AVFoundationPreviewSource>
  create(AVFoundationPreviewBinding binding,
         std::shared_ptr<AVFoundationPreviewBackend> backend) noexcept;
  ~AVFoundationPreviewSource();

  AVFoundationPreviewSource(const AVFoundationPreviewSource&) = delete;
  AVFoundationPreviewSource& operator=(const AVFoundationPreviewSource&) =
      delete;

  [[nodiscard]] AVFoundationPreviewBeginOutcome
  begin(AVFoundationPreviewRequest request) noexcept;
  // Advances the exact target of the currently open private epoch without
  // replacing its AVAssetReader. This owner-confined operation is valid only
  // for a nondecreasing in-duration target. It never changes the epoch,
  // constructs a reader, or makes a cancelled/end-of-stream reader pullable.
  [[nodiscard]] bool advanceTarget(std::uint64_t expectedEpoch,
                                   media::MediaTime target) noexcept;
  [[nodiscard]] AVFoundationPreviewReadResult
  readNext(std::uint64_t expectedEpoch) noexcept;
  void requestCancel(std::uint64_t epoch) noexcept;
  void close() noexcept;
  [[nodiscard]] AVFoundationPreviewSourceFacts facts() const noexcept;
  // Owner-thread only. requestCancel() never samples or mutates these facts.
  [[nodiscard]] AVFoundationPreviewSourceMemoryFacts memoryFacts()
      const noexcept;

 private:
  struct Impl;
  explicit AVFoundationPreviewSource(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
  friend struct AVFoundationPreviewSourceTestAccess;
#endif
};

#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
// Deterministic proof seam absent from shipping class layout. The hook runs
// after requestCancel() first observes its matching operation epoch but before
// it publishes cancellation. Callers install it before starting concurrent
// work and remove it only after every hooked request has returned.
struct AVFoundationPreviewSourceTestAccess {
  static void setCancelInterleaveHook(
      AVFoundationPreviewSource& source,
      AVFoundationPreviewCancelInterleaveHook hook,
      void* context) noexcept;
  [[nodiscard]] static AVFoundationPreviewSharedContextProbe
  probeSharedContext(AVFoundationPreviewBinding binding) noexcept;
};
#endif

}  // namespace wam::macos
