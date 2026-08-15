#pragma once

#include <cstddef>
#include <cstdint>

namespace wam::qt {

struct NativePlaybackMetricsTestAccess;

// One periodic playback sample. Every counter is cumulative; a consumer is
// expected to difference two samples over its own window. The `has*` flags
// distinguish a genuine zero from an unavailable value, which is emitted as
// JSON null so no consumer can mistake "no session open" for "nothing was
// dropped".
struct NativePlaybackMetricsSample {
  std::uint64_t drawnFrames{0};
  std::uint64_t submittedFrames{0};
  std::uint64_t supersededFrames{0};
  std::uint64_t discardedLateFrames{0};
  std::uint64_t audioUnderrunCallbacks{0};
  std::uint64_t audioClockAdvancedUnderruns{0};
  std::uint64_t audioRetiredLateFrames{0};
  std::uint64_t audioCallbacks{0};
  std::uint64_t audioRenderedFrames{0};
  double mediaSeconds{0.0};
  // The clock's requested rate. The achieved rate is a consumer-side
  // derivation: delta(mediaSeconds) over delta(t_mono_ns).
  double clockRate{0.0};
  bool hasVideo{false};
  bool hasAudio{false};
  bool hasClock{false};
  bool paused{true};
};

// Opt-in JSONL playback metrics stream, wholly independent of
// NativeBenchmarkTelemetry's hash-chained proof stream. Nothing here shares a
// file, record vocabulary, sequence space, or shutdown dependency with that
// stream, so a stress harness may consume both at once.
//
// Enabled only by WAM_PLAYBACK_METRICS_PATH holding an absolute path. When it
// is unset or empty this object opens no file, starts no thread, arms no
// timer, and allocates nothing; callers pay one enabled() branch.
// WAM_PLAYBACK_METRICS_INTERVAL_MS optionally sets the sampling period and is
// clamped to [100, 10000], defaulting to 1000.
//
// Unlike the proof stream this one is crash-tolerant by construction: each
// line is formatted into a fixed enabled-only buffer, appended, and flushed
// before write() returns, so a process killed mid-run still leaves every
// already-emitted sample readable. There is no header, no batching, and no
// terminal record to wait for.
//
// write() is called from the Qt GUI thread by the owner's sampling timer. It
// is never called from an AudioUnit render callback, a VideoToolbox callback,
// or the Qt render thread.
class NativePlaybackMetrics final {
public:
  [[nodiscard]] static NativePlaybackMetrics &instance() noexcept;
  ~NativePlaybackMetrics() noexcept;

  NativePlaybackMetrics(const NativePlaybackMetrics &) = delete;
  NativePlaybackMetrics &operator=(const NativePlaybackMetrics &) = delete;

  [[nodiscard]] bool enabled() const noexcept { return enabled_; }
  [[nodiscard]] unsigned intervalMilliseconds() const noexcept {
    return intervalMilliseconds_;
  }

  // Emits one playback_sample line. Returns false if the stream is disabled or
  // has failed closed. A failed stream stays closed: a metrics stream must
  // never retry into a hot path or mask the failure by resuming mid-file.
  bool write(const NativePlaybackMetricsSample &sample) noexcept;

  static constexpr unsigned kDefaultIntervalMilliseconds = 1000;
  static constexpr unsigned kMinimumIntervalMilliseconds = 100;
  static constexpr unsigned kMaximumIntervalMilliseconds = 10000;

private:
  using Clock = std::uint64_t (*)() noexcept;
  using Sink = bool (*)(const char *, std::size_t, void *) noexcept;
  using Flusher = bool (*)(void *) noexcept;

  NativePlaybackMetrics(bool enabled, unsigned intervalMilliseconds,
                        Clock clock, Sink sink, Flusher flusher,
                        void *sinkContext) noexcept;

  // Every emitted line fits well inside this bound: fourteen fields whose
  // widest forms are a 20-digit u64 and a 24-character double.
  static constexpr std::size_t kMaximumJsonLineBytes = 512;

  bool enabled_{false};
  unsigned intervalMilliseconds_{kDefaultIntervalMilliseconds};
  Clock clock_{nullptr};
  Sink sink_{nullptr};
  Flusher flusher_{nullptr};
  void *sinkContext_{nullptr};
  bool failed_{false};
  // Allocated once, only when enabled, so formatting never allocates.
  char *line_{nullptr};

  friend struct NativePlaybackMetricsTestAccess;
};

} // namespace wam::qt
