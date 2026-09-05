#pragma once

#include "media/native_playback_contract.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <thread>

namespace wam::qt {

struct NativeBenchmarkTelemetryTestAccess;

// The truth vocabulary for every WAM_* environment opt-in: "1", "true",
// "yes", "on" and their upper-case forms read as enabled; an unset variable
// and anything else -- including "0" and junk -- read as off.
[[nodiscard]] inline bool wamEnvironmentTruth(const char *name) noexcept {
  const char *const value = std::getenv(name);
  if (value == nullptr) {
    return false;
  }
  return std::strcmp(value, "1") == 0 || std::strcmp(value, "true") == 0 ||
         std::strcmp(value, "TRUE") == 0 || std::strcmp(value, "yes") == 0 ||
         std::strcmp(value, "YES") == 0 || std::strcmp(value, "on") == 0 ||
         std::strcmp(value, "ON") == 0;
}

// The single armed test: the telemetry stream, every WAM_TEST_* seam that may
// only exist for a measured run, and the window chrome's benchmark mode all
// key on this one answer, so no launch can arm one of them and not another.
[[nodiscard]] inline bool nativeBenchmarkTelemetryArmed() noexcept {
  return wamEnvironmentTruth("WAM_NATIVE_BENCHMARK_TELEMETRY");
}

// Opt-in JSONL proof stream for native playback benchmarks. Production owns
// one process-wide instance. When WAM_NATIVE_BENCHMARK_TELEMETRY is unset (or
// false), callers pay only an enabled() branch: no clock read, formatting,
// lock, write, or allocation occurs. The fixed-capacity event and output
// buffers are allocated once only when telemetry is enabled. Recording before
// a checkpoint appends fixed-size facts on the constructing controller/GUI
// thread. The initial batch is formatted and written only after first-frame
// time has been captured; later batches are written at an explicit checkpoint
// or terminal finish. Formatting may use enabled-only libc scratch storage.
// Call sites are never AudioUnit, VideoToolbox, or Qt render callbacks.
class NativeBenchmarkTelemetry final {
public:
  [[nodiscard]] static NativeBenchmarkTelemetry &instance() noexcept;
  ~NativeBenchmarkTelemetry() noexcept;

  NativeBenchmarkTelemetry(const NativeBenchmarkTelemetry &) = delete;
  NativeBenchmarkTelemetry &
  operator=(const NativeBenchmarkTelemetry &) = delete;

  [[nodiscard]] bool enabled() const noexcept { return enabled_; }

  void openRequested(media::native_playback::SourceKey sourceKey,
                     bool libmpvInitialized) noexcept;
  void nativeSelected(const media::native_playback::Prepare &command,
                      bool libmpvInitialized) noexcept;
  void fallbackSelected(media::native_playback::Stamp stamp,
                        media::native_playback::SourceKey sourceKey,
                        bool libmpvInitialized) noexcept;
  void prepared(const media::native_playback::Prepared &event,
                bool libmpvInitialized) noexcept;
  void started(const media::native_playback::Started &event,
               bool libmpvInitialized) noexcept;
  void firstFrameDrawn(const media::native_playback::VideoDrawProof &proof,
                       bool libmpvInitialized) noexcept;
  // previewDemanded is the public controller/QML boundary before the
  // capacity-one pacing decision. previewDispatched is the exact owner/backend
  // request after controller coalescing. Demand without dispatch is expected;
  // admitted and terminal facts retain the exact dispatched command identity.
  void previewDemanded(media::native_playback::GestureId gesture,
                       media::native_playback::RequestId request,
                       double targetSeconds, bool libmpvInitialized) noexcept;
  void previewDispatched(media::native_playback::GestureId gesture,
                         media::native_playback::RequestId request,
                         double targetSeconds,
                         bool libmpvInitialized) noexcept;
  void previewAdmitted(const media::native_playback::PreviewFrame &command,
                       bool libmpvInitialized) noexcept;
  void previewFrameDrawn(const media::native_playback::PreviewPresented &event,
                         bool libmpvInitialized) noexcept;
  void previewFailed(const media::native_playback::PreviewFailed &event,
                     bool libmpvInitialized) noexcept;
  void commitSeekSubmitted(const media::native_playback::CommitSeek &command,
                           bool libmpvInitialized) noexcept;
  // CommitReady contains the exact post-seek covering draw proof. This emits
  // commit_ready and commit_frame_drawn with one identical clock sample.
  void commitReady(const media::native_playback::CommitReady &event,
                   bool libmpvInitialized) noexcept;

  // A checkpoint never writes while an open is still awaiting its first-draw
  // timestamp. firstFrameDrawn() performs this checkpoint automatically only
  // after sampling that timestamp, which keeps the harness's startup metric
  // free of telemetry I/O. Later GUI checkpoints may call this explicitly.
  [[nodiscard]] bool checkpoint() noexcept;
  // The owner may call finish() only at a terminal boundary where no future
  // first draw can occur. The process-wide instance also performs this drain
  // during orderly shutdown so the harness can read post-draw facts at quit.
  [[nodiscard]] bool finish() noexcept;

private:
  enum class Event : std::uint8_t {
    OpenRequested,
    NativeSelected,
    FallbackSelected,
    Prepared,
    Started,
    FirstFrameDrawn,
    PreviewDemanded,
    PreviewDispatched,
    PreviewAdmitted,
    PreviewFrameDrawn,
    PreviewFailed,
    CommitSeekSubmitted,
    CommitReady,
    CommitFrameDrawn,
  };

  enum class Route : std::uint8_t { Undecided, Native, Fallback };

  struct Point {
    Event event;
    Route route;
    std::uint64_t sourceKey;
    std::uint64_t attempt;
    std::uint64_t serial;
    std::uint64_t generation;
    std::uint64_t gesture;
    std::uint64_t request;
    std::uint64_t drawSequence;
    double targetSeconds;
    bool hasTargetSeconds;
    bool libmpvInitialized;
  };

  struct BufferedPoint {
    Point point;
    std::uint64_t monotonicNanoseconds;
    std::uint64_t eventSequence;
  };

  using Clock = std::uint64_t (*)() noexcept;
  using Sink = bool (*)(const char *, std::size_t, void *) noexcept;
  using Flusher = bool (*)(void *) noexcept;

  NativeBenchmarkTelemetry(bool enabled, Clock clock, Sink sink,
                           Flusher flusher, void *sinkContext) noexcept;
  [[nodiscard]] static const char *eventName(Event event) noexcept;
  [[nodiscard]] static const char *routeName(Route route) noexcept;
  [[nodiscard]] static bool isRouteProof(Event event) noexcept;
  [[nodiscard]] bool record(Point point) noexcept;
  [[nodiscard]] bool recordAt(Point point,
                              std::uint64_t monotonicNanoseconds) noexcept;
  [[nodiscard]] bool recordPairAt(Point first, Point second,
                                  std::uint64_t monotonicNanoseconds) noexcept;
  [[nodiscard]] bool onOwnerThread() const noexcept;
  [[nodiscard]] bool flushBuffered() noexcept;
  [[nodiscard]] bool flushStreamCommit() noexcept;
  [[nodiscard]] bool finishUnchecked() noexcept;
  void failClosed() noexcept;

  // 8,192 facts cover more than twenty seconds of 120 Hz request/admission/
  // terminal preview telemetry without I/O on the measured drag path.
  static constexpr std::size_t kMaximumBufferedPoints = 8192;
  static constexpr std::size_t kMaximumJsonLineBytes = 768;
  // Checkpoint formatting drains through one reusable chunk.  Keeping an
  // event-count-sized JSON mirror used to reserve roughly 6 MiB solely for a
  // benchmark opt-in; a bounded chunk preserves allocation-free event calls
  // without making enabled telemetry itself distort the memory result.
  static constexpr std::size_t kMaximumSerializedBytes = 64 * 1024;

  bool enabled_{false};
  char runId_[37]{};
  char assetSha256_[65]{};
  char candidateId_[65]{};
  std::uint64_t processId_{0};
  std::uint64_t processStartAbstime_{0};
  Clock clock_{nullptr};
  Sink sink_{nullptr};
  Flusher flusher_{nullptr};
  void *sinkContext_{nullptr};
  std::thread::id ownerThread_{};
  // BufferedPoint is deliberately trivially default constructible. The
  // enabled-only array reservation therefore does not eagerly touch every
  // page on the startup path; recordAt initializes each occupied slot.
  std::unique_ptr<BufferedPoint[]> points_;
  std::unique_ptr<char[]> serialized_;
  std::size_t pointCount_{0};
  std::uint64_t nextEventSequence_{1};
  std::uint64_t nextBatchSequence_{1};
  std::uint64_t committedEventCount_{0};
  unsigned char streamChainSha256_[32]{};
  bool headerWritten_{false};
  bool awaitingFirstDraw_{false};
  bool firstDrawCaptured_{false};
  bool failed_{false};
  bool finished_{false};

  friend struct NativeBenchmarkTelemetryTestAccess;
};

} // namespace wam::qt
