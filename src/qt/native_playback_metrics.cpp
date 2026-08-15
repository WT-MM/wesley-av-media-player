#include "native_playback_metrics.hpp"

#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <string_view>
#include <xlocale.h>

namespace wam::qt {
namespace {

// Opened lazily and exactly once, only when the stream is enabled. The stream
// is deliberately owned by a function-local static rather than the metrics
// object so a disabled process constructs no FILE at all.
struct FileStream final {
  std::FILE *file{nullptr};
};

FileStream &fileStream() noexcept {
  static FileStream stream;
  return stream;
}

// An absolute path is required so a harness reading the file cannot be
// confused by whatever working directory the app bundle was launched with.
const char *pathFromEnvironment() noexcept {
  const char *value = std::getenv("WAM_PLAYBACK_METRICS_PATH");
  if (value == nullptr || value[0] != '/') {
    return nullptr;
  }
  return value;
}

unsigned intervalFromEnvironment() noexcept {
  const char *value = std::getenv("WAM_PLAYBACK_METRICS_INTERVAL_MS");
  if (value == nullptr) {
    return NativePlaybackMetrics::kDefaultIntervalMilliseconds;
  }
  const std::string_view text(value);
  unsigned long long parsed = 0;
  const auto converted = std::from_chars(
      text.data(), text.data() + text.size(), parsed);
  if (converted.ec != std::errc{} ||
      converted.ptr != text.data() + text.size()) {
    return NativePlaybackMetrics::kDefaultIntervalMilliseconds;
  }
  if (parsed < NativePlaybackMetrics::kMinimumIntervalMilliseconds) {
    return NativePlaybackMetrics::kMinimumIntervalMilliseconds;
  }
  if (parsed > NativePlaybackMetrics::kMaximumIntervalMilliseconds) {
    return NativePlaybackMetrics::kMaximumIntervalMilliseconds;
  }
  return static_cast<unsigned>(parsed);
}

std::uint64_t monotonicNanoseconds() noexcept {
  try {
    const auto elapsed = std::chrono::steady_clock::now().time_since_epoch();
    const auto nanoseconds =
        std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count();
    return nanoseconds > 0 ? static_cast<std::uint64_t>(nanoseconds) : 0;
  } catch (...) {
    return 0;
  }
}

bool fileSink(const char *data, std::size_t size, void *context) noexcept {
  auto *stream = static_cast<FileStream *>(context);
  if (data == nullptr || size == 0 || stream == nullptr ||
      stream->file == nullptr) {
    return false;
  }
  return std::fwrite(data, 1, size, stream->file) == size;
}

// Flushed per line on purpose. This stream must remain usable after a killed
// or crashed process, so it may not defer any completed sample to an orderly
// quit the way the hash-chained proof stream does.
bool fileFlush(void *context) noexcept {
  auto *stream = static_cast<FileStream *>(context);
  if (stream == nullptr || stream->file == nullptr) {
    return false;
  }
  return std::fflush(stream->file) == 0;
}

// Fixed-capacity formatter over a caller-owned buffer. Overflow fails the line
// rather than truncating it, so a consumer never sees a half-written object.
class JsonLine final {
public:
  JsonLine(char *data, std::size_t capacity) noexcept
      : data_(data), capacity_(capacity) {}

  void text(std::string_view value) noexcept {
    if (!valid_ || value.size() > capacity_ - size_) {
      valid_ = false;
      return;
    }
    std::memcpy(data_ + size_, value.data(), value.size());
    size_ += value.size();
  }

  void unsignedInteger(std::uint64_t value) noexcept {
    if (!valid_) {
      return;
    }
    const auto converted =
        std::to_chars(data_ + size_, data_ + capacity_, value);
    if (converted.ec != std::errc{}) {
      valid_ = false;
      return;
    }
    size_ = static_cast<std::size_t>(converted.ptr - data_);
  }

  void numberOrNull(double value, bool present) noexcept {
    if (!present || !std::isfinite(value)) {
      text("null");
      return;
    }
    if (!valid_) {
      return;
    }
    const std::size_t remaining = capacity_ - size_;
    // Same fixed C locale the proof stream uses: it keeps JSON's decimal point
    // stable without touching process or thread locale state, and it predates
    // the libc++ floating-point to_chars overload on this deployment target.
    const int converted =
        ::snprintf_l(data_ + size_, remaining, _c_locale, "%.*g",
                     std::numeric_limits<double>::max_digits10, value);
    if (converted < 0 || static_cast<std::size_t>(converted) >= remaining) {
      valid_ = false;
      return;
    }
    size_ += static_cast<std::size_t>(converted);
  }

  void boolean(bool value) noexcept { text(value ? "true" : "false"); }

  void unsignedField(std::string_view name, std::uint64_t value) noexcept {
    text(",\"");
    text(name);
    text("\":");
    unsignedInteger(value);
  }

  [[nodiscard]] bool valid() const noexcept { return valid_; }
  [[nodiscard]] const char *data() const noexcept { return data_; }
  [[nodiscard]] std::size_t size() const noexcept { return size_; }

private:
  char *data_{nullptr};
  std::size_t capacity_{0};
  std::size_t size_{0};
  bool valid_{true};
};

} // namespace

NativePlaybackMetrics &NativePlaybackMetrics::instance() noexcept {
  static NativePlaybackMetrics metrics(pathFromEnvironment() != nullptr,
                                       intervalFromEnvironment(),
                                       &monotonicNanoseconds, &fileSink,
                                       &fileFlush, &fileStream());
  return metrics;
}

NativePlaybackMetrics::NativePlaybackMetrics(bool enabled,
                                             unsigned intervalMilliseconds,
                                             Clock clock, Sink sink,
                                             Flusher flusher,
                                             void *sinkContext) noexcept
    : enabled_(enabled && clock != nullptr && sink != nullptr &&
               flusher != nullptr && sinkContext != nullptr),
      intervalMilliseconds_(intervalMilliseconds), clock_(clock), sink_(sink),
      flusher_(flusher), sinkContext_(sinkContext) {
  if (!enabled_) {
    return;
  }
  const char *path = pathFromEnvironment();
  auto *stream = static_cast<FileStream *>(sinkContext_);
  // Append rather than truncate: a harness may deliberately point several runs
  // at one file, and losing an earlier run's samples to a relaunch would be a
  // silent data loss.
  if (path == nullptr || stream == nullptr ||
      (stream->file = std::fopen(path, "ae")) == nullptr) {
    enabled_ = false;
    return;
  }
  line_ = new (std::nothrow) char[kMaximumJsonLineBytes];
  if (line_ == nullptr) {
    static_cast<void>(std::fclose(stream->file));
    stream->file = nullptr;
    enabled_ = false;
  }
}

NativePlaybackMetrics::~NativePlaybackMetrics() noexcept {
  delete[] line_;
  line_ = nullptr;
  auto *stream = static_cast<FileStream *>(sinkContext_);
  if (enabled_ && stream != nullptr && stream->file != nullptr) {
    // Every line was already flushed; this only releases the descriptor.
    static_cast<void>(std::fclose(stream->file));
    stream->file = nullptr;
  }
}

bool NativePlaybackMetrics::write(
    const NativePlaybackMetricsSample &sample) noexcept {
  if (!enabled_ || failed_ || line_ == nullptr) {
    return false;
  }
  JsonLine line(line_, kMaximumJsonLineBytes);
  line.text("{\"record\":\"playback_sample\",\"t_mono_ns\":");
  line.unsignedInteger(clock_());
  line.text(",\"media_seconds\":");
  line.numberOrNull(sample.mediaSeconds, sample.hasClock);
  // Video and audio counters are reported as null as one group each, because a
  // group is unavailable exactly when its owner has published nothing yet.
  line.text(",\"drawn_frames\":");
  if (sample.hasVideo) {
    line.unsignedInteger(sample.drawnFrames);
    line.unsignedField("submitted_frames", sample.submittedFrames);
    line.unsignedField("superseded_frames", sample.supersededFrames);
    line.unsignedField("discarded_late_frames", sample.discardedLateFrames);
  } else {
    line.text("null,\"submitted_frames\":null,\"superseded_frames\":null,"
              "\"discarded_late_frames\":null");
  }
  line.text(",\"audio_underrun_callbacks\":");
  if (sample.hasAudio) {
    line.unsignedInteger(sample.audioUnderrunCallbacks);
    line.unsignedField("audio_clock_advanced_underruns",
                       sample.audioClockAdvancedUnderruns);
    line.unsignedField("audio_retired_late_frames",
                       sample.audioRetiredLateFrames);
    line.unsignedField("audio_callbacks", sample.audioCallbacks);
    line.unsignedField("audio_rendered_frames", sample.audioRenderedFrames);
  } else {
    line.text("null,\"audio_clock_advanced_underruns\":null,"
              "\"audio_retired_late_frames\":null,\"audio_callbacks\":null,"
              "\"audio_rendered_frames\":null");
  }
  line.text(",\"clock_rate\":");
  line.numberOrNull(sample.clockRate, sample.hasClock);
  line.text(",\"paused\":");
  line.boolean(sample.paused);
  line.text("}\n");
  if (!line.valid()) {
    failed_ = true;
    return false;
  }
  if (!sink_(line.data(), line.size(), sinkContext_) ||
      !flusher_(sinkContext_)) {
    failed_ = true;
    return false;
  }
  return true;
}

} // namespace wam::qt
