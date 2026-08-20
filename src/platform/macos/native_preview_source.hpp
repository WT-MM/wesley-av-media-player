#pragma once

#include "media/native_media_source.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <type_traits>
#include <variant>

namespace wam::macos {

// Backend-neutral scrub preview vocabulary.
//
// The preview graph above this interface -- NativePreviewFrameLane, the
// VideoToolbox decoder, the capacity-one sink, the tracked preview port and the
// PreviewFrame/PreviewPresented/PreviewFailed protocol -- never names a
// container backend. Only the pull source does, and only inside its own
// implementation. Everything a lane needs to drive a preview is stated here:
// one private epoch at a time, a bounded read that stages at most one copied
// CoreMedia sample buffer, a prompt cancel that may run on another thread, and
// facts a caller can compare against its own accounting.
//
// The two implementations are `AVFoundationPreviewSource` (an AVAssetReader per
// epoch, preceded by a full-sync back-walk) and `MatroskaPreviewSource` (a
// cue-aligned demuxer cursor per epoch, which needs no back-walk because a
// planned generation already begins on a random-access point).

// Immutable input shared by every short-lived preview reader. The descriptor
// is the one already admitted by the main native source. Preview never selects
// tracks, opens audio, or publishes its private epochs as playback generations.
struct NativePreviewBinding {
  std::filesystem::path localPath;
  std::shared_ptr<const media::MediaSourceDescriptor> descriptor;
  media::MediaSourceLimits limits{};
  // Production sessions provide the immutable context admitted by the main
  // source; its backendKind() is what selects the concrete preview source.
  // Null keeps the standalone cold-load path available for isolated preview
  // use and injected tests, and only the AVFoundation backend offers one.
  std::shared_ptr<const media::MediaSourcePreparedContext> assetContext{};
};

struct NativePreviewRequest {
  // Private, strictly increasing cancellation identity. This value is used in
  // returned MediaSample::generation only inside the preview graph; it must
  // never be passed to NativeMediaDispatcher or NativeAudioSession.
  std::uint64_t epoch{0};
  media::MediaTime target{};
};

enum class NativePreviewStatus : std::uint8_t {
  Rejected,
  Ready,
  Unsupported,
  Cancelled,
  Failed,
};

struct NativePreviewBeginOutcome {
  NativePreviewStatus status{NativePreviewStatus::Rejected};
  std::uint64_t epoch{0};
  media::MediaTime actualDecodeStart{};
  std::string error;
};

struct NativePreviewEndOfStream {
  std::uint64_t epoch{0};
};

struct NativePreviewCancelled {
  std::uint64_t epoch{0};
};

struct NativePreviewFailure {
  std::uint64_t epoch{0};
  std::string error;
};

using NativePreviewReadResult =
    std::variant<media::MediaSample, media::MediaDiscontinuity,
                 NativePreviewEndOfStream, NativePreviewCancelled,
                 NativePreviewFailure>;

// Production facts are cumulative across reader replacement. assetLoad* is
// the cold immutable-asset/track admission cost; later preview requests reuse
// that cache and create only the per-epoch streaming object.
//
// "Reader" is the backend's unit of streaming state: one AVAssetReader on the
// AVFoundation route, one MatroskaCursor on the Matroska route. The Matroska
// asset context already counts exactly that pair of facts against cursors
// (`matroska_asset_context.hpp`), so the two backends answer the same question.
struct NativePreviewBackendFacts {
  std::uint64_t assetLoadAttempts{0};
  std::uint64_t assetLoadsCompleted{0};
  std::uint64_t assetLoadNanoseconds{0};
  std::uint64_t readersCreated{0};
  std::uint64_t readersStarted{0};
};

struct NativePreviewSourceFacts {
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
  // coalescing: no reader is constructed or restarted for these.
  std::uint64_t forwardRetargets{0};
  bool open{false};
  bool cancelled{false};
  NativePreviewBackendFacts backend{};
};

// Allocation-free owner-thread snapshot of the one copied CoreMedia sample
// temporarily owned inside readNext(). A zero-byte discontinuity may set
// stagedSamples without charging compressed bytes.
struct NativePreviewSourceMemoryFacts {
  std::size_t stagedSamples{0};
  std::uint64_t currentStagedCompressedBytes{0};
  std::uint64_t peakStagedCompressedBytes{0};
};
static_assert(std::is_trivially_copyable_v<NativePreviewSourceMemoryFacts>);

// Bounded video-only preview pull source. A newer valid epoch cancels and
// replaces the active reader before it creates the next one. At most one
// copied CMSampleBuffer is staged while readNext() validates and transfers its
// +1 reference; after return the source itself retains no sample buffer.
//
// begin(), advanceTarget(), readNext(), close(), facts() and memoryFacts() are
// confined to the one owner. requestCancel() alone is safe to call from another
// thread while the owner is blocked inside begin() or readNext().
class NativePreviewSource {
 public:
  virtual ~NativePreviewSource() = default;

  NativePreviewSource(const NativePreviewSource&) = delete;
  NativePreviewSource& operator=(const NativePreviewSource&) = delete;

  [[nodiscard]] virtual NativePreviewBeginOutcome
  begin(NativePreviewRequest request) noexcept = 0;
  // Advances the exact target of the currently open private epoch without
  // replacing its reader. This owner-confined operation is valid only for a
  // nondecreasing in-duration target. It never changes the epoch, constructs a
  // reader, or makes a cancelled/end-of-stream reader pullable.
  [[nodiscard]] virtual bool advanceTarget(std::uint64_t expectedEpoch,
                                           media::MediaTime target) noexcept = 0;
  [[nodiscard]] virtual NativePreviewReadResult
  readNext(std::uint64_t expectedEpoch) noexcept = 0;
  virtual void requestCancel(std::uint64_t epoch) noexcept = 0;
  virtual void close() noexcept = 0;
  [[nodiscard]] virtual NativePreviewSourceFacts facts() const noexcept = 0;
  // Owner-thread only. requestCancel() never samples or mutates these facts.
  [[nodiscard]] virtual NativePreviewSourceMemoryFacts memoryFacts()
      const noexcept = 0;

 protected:
  NativePreviewSource() = default;
};

// Selects the concrete preview source from the admitted context's
// backendKind(). This is the single site that knows which containers can be
// previewed; a binding whose context is null falls back to the AVFoundation
// cold-load path, and an unrecognized backend returns null so the caller
// leaves the scrub lane inactive rather than guessing.
[[nodiscard]] std::unique_ptr<NativePreviewSource> createNativePreviewSource(
    NativePreviewBinding binding) noexcept;

}  // namespace wam::macos
