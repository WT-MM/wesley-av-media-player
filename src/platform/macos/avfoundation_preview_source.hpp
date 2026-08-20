#pragma once

#include "media/native_media_source.hpp"
#include "platform/macos/avfoundation_asset_context.hpp"
#include "platform/macos/native_preview_source.hpp"

#include <CoreMedia/CoreMedia.h>

#include <cstdint>
#include <memory>
#include <string>

namespace wam::macos {

#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
struct AVFoundationPreviewSourceTestAccess;
using AVFoundationPreviewCancelInterleaveHook = void (*)(
    std::uint64_t epoch, void* context) noexcept;
#endif

// The shared preview vocabulary -- binding, request, status, read result and
// facts -- lives in `native_preview_source.hpp`; only the AVFoundation-specific
// backend seams below are named here.

#if defined(WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING)
// Exact snapshots from the production shared-context branch. The probe models
// one failed reader initialization followed by one successfully started
// reader, while using the same accounting methods as ProductionPreviewGeneration.
struct AVFoundationPreviewSharedContextProbe {
  bool sharedLoadReady{false};
  NativePreviewBackendFacts backendBefore{};
  NativePreviewBackendFacts backendAfterSharedLoad{};
  NativePreviewBackendFacts backendAfterCreationFailure{};
  NativePreviewBackendFacts backendAfterStartedReader{};
  AVFoundationAssetContextFacts contextBefore{};
  AVFoundationAssetContextFacts contextAfterSharedLoad{};
  AVFoundationAssetContextFacts contextAfterCreationFailure{};
  AVFoundationAssetContextFacts contextAfterStartedReader{};
};
#endif

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

struct AVFoundationPreviewGenerationStart {
  NativePreviewStatus status{NativePreviewStatus::Failed};
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
  makeGeneration(const NativePreviewBinding& binding,
                 NativePreviewRequest request) = 0;
  [[nodiscard]] virtual NativePreviewBackendFacts facts() const noexcept = 0;
};

// AVFoundation implementation of the neutral preview pull source. One
// AVAssetReader per private epoch, preceded by a bounded full-sync back-walk
// because AVFoundation exposes no random-access index this source can consult.
class AVFoundationPreviewSource final : public NativePreviewSource {
 public:
  [[nodiscard]] static std::unique_ptr<AVFoundationPreviewSource>
  create(NativePreviewBinding binding) noexcept;
  [[nodiscard]] static std::unique_ptr<AVFoundationPreviewSource>
  create(NativePreviewBinding binding,
         std::shared_ptr<AVFoundationPreviewBackend> backend) noexcept;
  ~AVFoundationPreviewSource() override;

  [[nodiscard]] NativePreviewBeginOutcome
  begin(NativePreviewRequest request) noexcept override;
  [[nodiscard]] bool advanceTarget(std::uint64_t expectedEpoch,
                                   media::MediaTime target) noexcept override;
  [[nodiscard]] NativePreviewReadResult
  readNext(std::uint64_t expectedEpoch) noexcept override;
  void requestCancel(std::uint64_t epoch) noexcept override;
  void close() noexcept override;
  [[nodiscard]] NativePreviewSourceFacts facts() const noexcept override;
  [[nodiscard]] NativePreviewSourceMemoryFacts memoryFacts()
      const noexcept override;

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
  probeSharedContext(NativePreviewBinding binding) noexcept;
};
#endif

}  // namespace wam::macos
