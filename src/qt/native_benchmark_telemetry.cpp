#include "native_benchmark_telemetry.hpp"

#include <CommonCrypto/CommonDigest.h>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <libproc.h>
#include <limits>
#include <memory>
#include <new>
#include <string_view>
#include <sys/resource.h>
#include <type_traits>
#include <unistd.h>
#include <xlocale.h>

namespace wam::qt {
namespace {

constexpr std::string_view kSchema = "wam.native.benchmark.v2";

bool validRunId(std::string_view value) noexcept {
  if (value.size() != 36) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    const char character = value[index];
    const bool separator =
        index == 8 || index == 13 || index == 18 || index == 23;
    if (separator ? character != '-'
                  : !((character >= '0' && character <= '9') ||
                      (character >= 'a' && character <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool validSha256(std::string_view value) noexcept {
  if (value.size() != 64) {
    return false;
  }
  for (const char character : value) {
    if (!((character >= '0' && character <= '9') ||
          (character >= 'a' && character <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool processIdentity(char (&runId)[37], char (&assetSha256)[65],
                     char (&candidateId)[65],
                     std::uint64_t &processId,
                     std::uint64_t &processStartAbstime) noexcept {
  const char *runIdValue = std::getenv("WAM_NATIVE_BENCHMARK_RUN_ID");
  const char *assetSha256Value =
      std::getenv("WAM_NATIVE_BENCHMARK_ASSET_SHA256");
  const char *candidateIdValue =
      std::getenv("WAM_NATIVE_BENCHMARK_CANDIDATE_ID");
  if (runIdValue == nullptr || !validRunId(runIdValue) ||
      assetSha256Value == nullptr || !validSha256(assetSha256Value) ||
      candidateIdValue == nullptr || !validSha256(candidateIdValue)) {
    return false;
  }
  rusage_info_v4 usage{};
  const pid_t pid = ::getpid();
  if (pid <= 0 ||
      ::proc_pid_rusage(pid, RUSAGE_INFO_V4,
                        reinterpret_cast<rusage_info_t *>(&usage)) != 0 ||
      usage.ri_proc_start_abstime == 0) {
    return false;
  }
  std::memcpy(runId, runIdValue, 36);
  runId[36] = '\0';
  std::memcpy(assetSha256, assetSha256Value, 64);
  assetSha256[64] = '\0';
  std::memcpy(candidateId, candidateIdValue, 64);
  candidateId[64] = '\0';
  processId = static_cast<std::uint64_t>(pid);
  processStartAbstime = usage.ri_proc_start_abstime;
  return true;
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

bool stderrSink(const char *data, std::size_t size, void *) noexcept {
  if (data == nullptr || size == 0) {
    return false;
  }
  return std::fwrite(data, 1, size, stderr) == size;
}

bool stderrFlush(void *) noexcept { return std::fflush(stderr) == 0; }

class FixedJsonLine final {
public:
  void text(std::string_view value) noexcept {
    if (!valid_ || value.size() > capacity() - size_) {
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
        std::to_chars(data_ + size_, data_ + capacity(), value);
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
    const std::size_t remaining = capacity() - size_;
    // Darwin's fixed C locale keeps JSON's decimal point stable without
    // constructing a locale or changing process/thread locale state. This
    // overload writes directly into our fixed buffer and predates macOS 13;
    // libc++'s floating-point to_chars overload does not.
    const int converted =
        ::snprintf_l(data_ + size_, remaining, _c_locale, "%.*g",
                     std::numeric_limits<double>::max_digits10, value);
    if (converted < 0 || static_cast<std::size_t>(converted) >= remaining) {
      valid_ = false;
      return;
    }
    size_ += static_cast<std::size_t>(converted);
  }

  void jsonString(std::string_view value) noexcept {
    text("\"");
    text(value);
    text("\"");
  }

  [[nodiscard]] bool valid() const noexcept { return valid_; }
  [[nodiscard]] const char *data() const noexcept { return data_; }
  [[nodiscard]] std::size_t size() const noexcept { return size_; }

private:
  static constexpr std::size_t kCapacity = 768;

  [[nodiscard]] static constexpr std::size_t capacity() noexcept {
    return kCapacity;
  }

  char data_[kCapacity]{};
  std::size_t size_{0};
  bool valid_{true};
};

class Sha256 final {
public:
  Sha256() noexcept : valid_(CC_SHA256_Init(&context_) == 1) {}

  void update(const void *data, std::size_t size) noexcept {
    if (!valid_ || data == nullptr || size > std::numeric_limits<CC_LONG>::max() ||
        CC_SHA256_Update(&context_, data, static_cast<CC_LONG>(size)) != 1) {
      valid_ = false;
    }
  }

  [[nodiscard]] bool finish(unsigned char (&digest)[CC_SHA256_DIGEST_LENGTH])
      noexcept {
    if (!valid_ || CC_SHA256_Final(digest, &context_) != 1) {
      valid_ = false;
      return false;
    }
    return true;
  }

private:
  CC_SHA256_CTX context_{};
  bool valid_{false};
};

void hexSha256(const unsigned char (&digest)[CC_SHA256_DIGEST_LENGTH],
               char (&output)[65]) noexcept {
  constexpr char kHex[] = "0123456789abcdef";
  for (std::size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
    output[index * 2] = kHex[digest[index] >> 4U];
    output[(index * 2) + 1] = kHex[digest[index] & 0x0fU];
  }
  output[64] = '\0';
}

void unsignedBigEndian(std::uint64_t value, unsigned char (&output)[8]) noexcept {
  for (std::size_t index = 0; index < 8; ++index) {
    output[7 - index] = static_cast<unsigned char>(value & 0xffU);
    value >>= 8U;
  }
}

// Chain input layout -- previous digest, payload digest, then batch, count,
// first and last as big-endian uint64 in that order -- is re-derived by
// benchmarks/macos/run_suite.py (struct.pack(">QQQQ", ...)) when it verifies
// a stream; the two must agree byte for byte.
bool nextStreamChain(
    const unsigned char (&previous)[CC_SHA256_DIGEST_LENGTH],
    const unsigned char (&payload)[CC_SHA256_DIGEST_LENGTH],
    std::uint64_t batch, std::uint64_t count, std::uint64_t first,
    std::uint64_t last,
    unsigned char (&output)[CC_SHA256_DIGEST_LENGTH]) noexcept {
  Sha256 hash;
  hash.update(previous, CC_SHA256_DIGEST_LENGTH);
  hash.update(payload, CC_SHA256_DIGEST_LENGTH);
  for (const std::uint64_t value : {batch, count, first, last}) {
    unsigned char encoded[8]{};
    unsignedBigEndian(value, encoded);
    hash.update(encoded, sizeof(encoded));
  }
  return hash.finish(output);
}

} // namespace

NativeBenchmarkTelemetry &NativeBenchmarkTelemetry::instance() noexcept {
  static NativeBenchmarkTelemetry telemetry(nativeBenchmarkTelemetryArmed(),
                                            &monotonicNanoseconds, &stderrSink,
                                            &stderrFlush, nullptr);
  return telemetry;
}

NativeBenchmarkTelemetry::NativeBenchmarkTelemetry(bool enabled, Clock clock,
                                                   Sink sink, Flusher flusher,
                                                   void *sinkContext) noexcept
    : enabled_(enabled && clock != nullptr && sink != nullptr &&
               flusher != nullptr),
      clock_(clock), sink_(sink), flusher_(flusher), sinkContext_(sinkContext) {
  if (enabled_) {
    if (!processIdentity(runId_, assetSha256_, candidateId_, processId_,
                         processStartAbstime_)) {
      enabled_ = false;
      return;
    }
    static_assert(std::is_trivially_default_constructible_v<BufferedPoint>);
    points_.reset(new (std::nothrow) BufferedPoint[kMaximumBufferedPoints]);
    serialized_.reset(new (std::nothrow) char[kMaximumSerializedBytes]);
    if (points_ == nullptr || serialized_ == nullptr) {
      points_.reset();
      serialized_.reset();
      enabled_ = false;
      return;
    }
    ownerThread_ = std::this_thread::get_id();
  }
}

NativeBenchmarkTelemetry::~NativeBenchmarkTelemetry() noexcept {
  if (enabled_ && !finished_) {
    static_cast<void>(finishUnchecked());
  }
}

const char *NativeBenchmarkTelemetry::eventName(Event event) noexcept {
  switch (event) {
  case Event::OpenRequested:
    return "open_requested";
  case Event::NativeSelected:
    return "native_selected";
  case Event::FallbackSelected:
    return "fallback_selected";
  case Event::Prepared:
    return "prepared";
  case Event::Started:
    return "started";
  case Event::FirstFrameDrawn:
    return "first_frame_drawn";
  case Event::PreviewDemanded:
    return "preview_demanded";
  case Event::PreviewDispatched:
    return "preview_dispatched";
  case Event::PreviewAdmitted:
    return "preview_admitted";
  case Event::PreviewFrameDrawn:
    return "preview_frame_drawn";
  case Event::PreviewFailed:
    return "preview_failed";
  case Event::CommitSeekSubmitted:
    return "commit_seek_submitted";
  case Event::CommitReady:
    return "commit_ready";
  case Event::CommitFrameDrawn:
    return "commit_frame_drawn";
  }
  return "unknown";
}

const char *NativeBenchmarkTelemetry::routeName(Route route) noexcept {
  switch (route) {
  case Route::Undecided:
    return "undecided";
  case Route::Native:
    return "native";
  case Route::Fallback:
    return "fallback";
  }
  return "undecided";
}

bool NativeBenchmarkTelemetry::isRouteProof(Event event) noexcept {
  return event == Event::NativeSelected || event == Event::FallbackSelected;
}

bool NativeBenchmarkTelemetry::onOwnerThread() const noexcept {
  return std::this_thread::get_id() == ownerThread_;
}

void NativeBenchmarkTelemetry::failClosed() noexcept {
  pointCount_ = 0;
  failed_ = true;
}

bool NativeBenchmarkTelemetry::record(Point point) noexcept {
  if (!enabled_ || failed_ || finished_ || !onOwnerThread()) {
    return false;
  }
  return recordAt(point, clock_());
}

bool NativeBenchmarkTelemetry::recordAt(Point point,
                                        std::uint64_t monotonic) noexcept {
  if (!enabled_ || failed_ || finished_ || !onOwnerThread()) {
    return false;
  }
  if (pointCount_ == kMaximumBufferedPoints) {
    failClosed();
    return false;
  }
  if (nextEventSequence_ == 0) {
    failClosed();
    return false;
  }
  points_[pointCount_++] =
      BufferedPoint{point, monotonic, nextEventSequence_++};
  return true;
}

bool NativeBenchmarkTelemetry::recordPairAt(Point first, Point second,
                                            std::uint64_t monotonic) noexcept {
  if (!enabled_ || failed_ || finished_ || !onOwnerThread()) {
    return false;
  }
  if (pointCount_ > kMaximumBufferedPoints - 2) {
    failClosed();
    return false;
  }
  if (nextEventSequence_ == 0 ||
      nextEventSequence_ == std::numeric_limits<std::uint64_t>::max()) {
    failClosed();
    return false;
  }
  points_[pointCount_++] =
      BufferedPoint{first, monotonic, nextEventSequence_++};
  points_[pointCount_++] =
      BufferedPoint{second, monotonic, nextEventSequence_++};
  return true;
}

bool NativeBenchmarkTelemetry::flushBuffered() noexcept {
  if (failed_) {
    return false;
  }
  if (pointCount_ == 0) {
    return true;
  }

  if (nextBatchSequence_ == 0 ||
      committedEventCount_ >
          std::numeric_limits<std::uint64_t>::max() - pointCount_) {
    failClosed();
    return false;
  }

  std::size_t serializedSize = 0;
  const auto append = [this, &serializedSize](const FixedJsonLine &line) {
    if (!line.valid() || line.size() > kMaximumSerializedBytes) {
      return false;
    }
    if (line.size() > kMaximumSerializedBytes - serializedSize) {
      if (serializedSize == 0 ||
          !sink_(serialized_.get(), serializedSize, sinkContext_)) {
        return false;
      }
      serializedSize = 0;
    }
    std::memcpy(serialized_.get() + serializedSize, line.data(), line.size());
    serializedSize += line.size();
    return true;
  };
  const auto identity = [this](FixedJsonLine &line) {
    line.text(",\"run_id\":");
    line.jsonString(runId_);
    line.text(",\"process_id\":");
    line.unsignedInteger(processId_);
    line.text(",\"process_start_abstime\":");
    line.unsignedInteger(processStartAbstime_);
    line.text(",\"asset_sha256\":");
    line.jsonString(assetSha256_);
    line.text(",\"candidate_id\":");
    line.jsonString(candidateId_);
  };

  if (!headerWritten_) {
    FixedJsonLine header;
    header.text("{\"schema\":\"");
    header.text(kSchema);
    header.text("\",\"record\":\"stream_header\",\"format_version\":2");
    identity(header);
    header.text("}\n");
    if (!append(header)) {
      failClosed();
      return false;
    }
  }

  const std::uint64_t batch = nextBatchSequence_;
  const std::uint64_t eventCount = pointCount_;
  const std::uint64_t firstSequence = points_[0].eventSequence;
  const std::uint64_t lastSequence = points_[pointCount_ - 1].eventSequence;
  char previousChainHex[65]{};
  hexSha256(streamChainSha256_, previousChainHex);
  FixedJsonLine begin;
  begin.text("{\"schema\":\"");
  begin.text(kSchema);
  begin.text("\",\"record\":\"batch_begin\",\"batch\":");
  begin.unsignedInteger(batch);
  begin.text(",\"event_count\":");
  begin.unsignedInteger(eventCount);
  begin.text(",\"first_sequence\":");
  begin.unsignedInteger(firstSequence);
  begin.text(",\"last_sequence\":");
  begin.unsignedInteger(lastSequence);
  begin.text(",\"previous_chain_sha256\":");
  begin.jsonString(previousChainHex);
  identity(begin);
  begin.text("}\n");
  if (!append(begin)) {
    failClosed();
    return false;
  }

  Sha256 payloadHash;
  for (std::size_t index = 0; index < pointCount_; ++index) {
    const BufferedPoint &buffered = points_[index];
    const Point &point = buffered.point;
    FixedJsonLine line;
    line.text("{\"schema\":\"");
    line.text(kSchema);
    line.text("\",\"record\":\"event\",\"batch\":");
    line.unsignedInteger(batch);
    line.text(",\"event_sequence\":");
    line.unsignedInteger(buffered.eventSequence);
    line.text(",\"event\":\"");
    line.text(eventName(point.event));
    line.text("\",\"monotonic_ns\":");
    line.unsignedInteger(buffered.monotonicNanoseconds);
    identity(line);
    line.text(",\"route\":\"");
    line.text(routeName(point.route));
    line.text("\",\"route_proof\":");
    line.text(isRouteProof(point.event) ? "true" : "false");
    line.text(",\"source_key\":");
    line.unsignedInteger(point.sourceKey);
    line.text(",\"attempt\":");
    line.unsignedInteger(point.attempt);
    line.text(",\"serial\":");
    line.unsignedInteger(point.serial);
    line.text(",\"generation\":");
    line.unsignedInteger(point.generation);
    line.text(",\"gesture\":");
    line.unsignedInteger(point.gesture);
    line.text(",\"request\":");
    line.unsignedInteger(point.request);
    line.text(",\"draw_sequence\":");
    line.unsignedInteger(point.drawSequence);
    line.text(",\"target_seconds\":");
    line.numberOrNull(point.targetSeconds, point.hasTargetSeconds);
    line.text(",\"libmpv_initialized\":");
    line.text(point.libmpvInitialized ? "true" : "false");
    line.text("}\n");
    if (!line.valid()) {
      failClosed();
      return false;
    }
    payloadHash.update(line.data(), line.size());
    if (!append(line)) {
      failClosed();
      return false;
    }
  }

  unsigned char payloadDigest[CC_SHA256_DIGEST_LENGTH]{};
  unsigned char nextChain[CC_SHA256_DIGEST_LENGTH]{};
  if (!payloadHash.finish(payloadDigest) ||
      !nextStreamChain(streamChainSha256_, payloadDigest, batch, eventCount,
                       firstSequence, lastSequence, nextChain)) {
    failClosed();
    return false;
  }
  char payloadHex[65]{};
  char nextChainHex[65]{};
  hexSha256(payloadDigest, payloadHex);
  hexSha256(nextChain, nextChainHex);
  FixedJsonLine commit;
  commit.text("{\"schema\":\"");
  commit.text(kSchema);
  commit.text("\",\"record\":\"batch_commit\",\"batch\":");
  commit.unsignedInteger(batch);
  commit.text(",\"event_count\":");
  commit.unsignedInteger(eventCount);
  commit.text(",\"first_sequence\":");
  commit.unsignedInteger(firstSequence);
  commit.text(",\"last_sequence\":");
  commit.unsignedInteger(lastSequence);
  commit.text(",\"payload_sha256\":");
  commit.jsonString(payloadHex);
  commit.text(",\"chain_sha256\":");
  commit.jsonString(nextChainHex);
  identity(commit);
  commit.text("}\n");
  if (!append(commit)) {
    failClosed();
    return false;
  }
  if ((serializedSize != 0 &&
       !sink_(serialized_.get(), serializedSize, sinkContext_)) ||
      !flusher_(sinkContext_)) {
    failClosed();
    return false;
  }
  headerWritten_ = true;
  std::memcpy(streamChainSha256_, nextChain, sizeof(streamChainSha256_));
  ++nextBatchSequence_;
  committedEventCount_ += eventCount;
  pointCount_ = 0;
  return true;
}

bool NativeBenchmarkTelemetry::flushStreamCommit() noexcept {
  if (failed_) {
    return false;
  }
  std::size_t serializedSize = 0;
  const auto append = [this, &serializedSize](const FixedJsonLine &line) {
    if (!line.valid() || line.size() > kMaximumSerializedBytes - serializedSize) {
      return false;
    }
    std::memcpy(serialized_.get() + serializedSize, line.data(), line.size());
    serializedSize += line.size();
    return true;
  };
  const auto identity = [this](FixedJsonLine &line) {
    line.text(",\"run_id\":");
    line.jsonString(runId_);
    line.text(",\"process_id\":");
    line.unsignedInteger(processId_);
    line.text(",\"process_start_abstime\":");
    line.unsignedInteger(processStartAbstime_);
    line.text(",\"asset_sha256\":");
    line.jsonString(assetSha256_);
    line.text(",\"candidate_id\":");
    line.jsonString(candidateId_);
  };
  if (!headerWritten_) {
    FixedJsonLine header;
    header.text("{\"schema\":\"");
    header.text(kSchema);
    header.text("\",\"record\":\"stream_header\",\"format_version\":2");
    identity(header);
    header.text("}\n");
    if (!append(header)) {
      failClosed();
      return false;
    }
  }
  char chainHex[65]{};
  hexSha256(streamChainSha256_, chainHex);
  FixedJsonLine terminal;
  terminal.text("{\"schema\":\"");
  terminal.text(kSchema);
  terminal.text("\",\"record\":\"stream_commit\",\"batch_count\":");
  terminal.unsignedInteger(nextBatchSequence_ - 1);
  terminal.text(",\"event_count\":");
  terminal.unsignedInteger(committedEventCount_);
  terminal.text(",\"first_sequence\":");
  terminal.unsignedInteger(committedEventCount_ == 0 ? 0 : 1);
  terminal.text(",\"last_sequence\":");
  terminal.unsignedInteger(committedEventCount_);
  terminal.text(",\"chain_sha256\":");
  terminal.jsonString(chainHex);
  identity(terminal);
  terminal.text("}\n");
  if (!append(terminal) ||
      !sink_(serialized_.get(), serializedSize, sinkContext_) ||
      !flusher_(sinkContext_)) {
    failClosed();
    return false;
  }
  headerWritten_ = true;
  return true;
}

bool NativeBenchmarkTelemetry::checkpoint() noexcept {
  if (!enabled_) {
    return true;
  }
  if (failed_ || finished_ || !onOwnerThread() || awaitingFirstDraw_ ||
      !firstDrawCaptured_) {
    return false;
  }
  return flushBuffered();
}

bool NativeBenchmarkTelemetry::finishUnchecked() noexcept {
  if (finished_) {
    return !failed_;
  }
  finished_ = true;
  if (!flushBuffered()) {
    return false;
  }
  return flushStreamCommit();
}

bool NativeBenchmarkTelemetry::finish() noexcept {
  if (!enabled_) {
    return true;
  }
  if (!onOwnerThread()) {
    return false;
  }
  return finishUnchecked();
}

void NativeBenchmarkTelemetry::openRequested(
    media::native_playback::SourceKey sourceKey,
    bool libmpvInitialized) noexcept {
  Point point{};
  point.event = Event::OpenRequested;
  point.sourceKey = sourceKey.value;
  point.libmpvInitialized = libmpvInitialized;
  if (record(point)) {
    awaitingFirstDraw_ = true;
    firstDrawCaptured_ = false;
  }
}

void NativeBenchmarkTelemetry::nativeSelected(
    const media::native_playback::Prepare &command,
    bool libmpvInitialized) noexcept {
  Point point{};
  point.event = Event::NativeSelected;
  point.route = Route::Native;
  point.sourceKey = command.sourceKey.value;
  point.attempt = command.stamp.attempt.value;
  point.serial = command.stamp.serial.value;
  point.generation = command.reservedGeneration.value;
  point.hasTargetSeconds = true;
  point.targetSeconds = command.initialPositionSeconds;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::fallbackSelected(
    media::native_playback::Stamp stamp,
    media::native_playback::SourceKey sourceKey,
    bool libmpvInitialized) noexcept {
  Point point{};
  point.event = Event::FallbackSelected;
  point.route = Route::Fallback;
  point.sourceKey = sourceKey.value;
  point.attempt = stamp.attempt.value;
  point.serial = stamp.serial.value;
  point.libmpvInitialized = libmpvInitialized;
  if (!record(point)) {
    return;
  }
  // Before first draw this remains memory-only so startup timing cannot be
  // contaminated. After first draw, fallback already invalidates the trial;
  // publish it durably before returning so the live harness's final reread
  // cannot miss the route transition while WAM is still running.
  if (firstDrawCaptured_) {
    static_cast<void>(flushBuffered());
  }
}

void NativeBenchmarkTelemetry::prepared(
    const media::native_playback::Prepared &event,
    bool libmpvInitialized) noexcept {
  Point point{};
  point.event = Event::Prepared;
  point.route = Route::Native;
  point.sourceKey = event.sourceKey.value;
  point.attempt = event.stamp.attempt.value;
  point.serial = event.stamp.serial.value;
  point.generation = event.generation.value;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::started(
    const media::native_playback::Started &event,
    bool libmpvInitialized) noexcept {
  Point point{};
  point.event = Event::Started;
  point.route = Route::Native;
  point.attempt = event.stamp.attempt.value;
  point.serial = event.stamp.serial.value;
  point.generation = event.generation.value;
  point.drawSequence = event.drawBaseline;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::firstFrameDrawn(
    const media::native_playback::VideoDrawProof &proof,
    bool libmpvInitialized) noexcept {
  if (!enabled_ || failed_ || finished_ || !onOwnerThread()) {
    return;
  }
  Point point{};
  point.event = Event::FirstFrameDrawn;
  point.route = Route::Native;
  point.attempt = proof.stamp.attempt.value;
  point.serial = proof.stamp.serial.value;
  point.generation = proof.generation.value;
  point.drawSequence = proof.drawSequence;
  point.hasTargetSeconds = true;
  point.targetSeconds = proof.frameStartSeconds;
  point.libmpvInitialized = libmpvInitialized;
  // The only clock read for this fact happens before any serialization, write,
  // or flush. The checkpoint therefore cannot inflate its own timestamp.
  const std::uint64_t now = clock_();
  if (!recordAt(point, now)) {
    return;
  }
  awaitingFirstDraw_ = false;
  firstDrawCaptured_ = true;
  static_cast<void>(flushBuffered());
}

void NativeBenchmarkTelemetry::previewDemanded(
    media::native_playback::GestureId gesture,
    media::native_playback::RequestId request, double targetSeconds,
    bool libmpvInitialized) noexcept {
  if (!media::native_playback::valid(gesture) ||
      !media::native_playback::valid(request) ||
      !media::native_playback::validPosition(targetSeconds)) {
    return;
  }
  Point point{};
  point.event = Event::PreviewDemanded;
  point.route = Route::Native;
  point.gesture = gesture.value;
  point.request = request.value;
  point.hasTargetSeconds = true;
  point.targetSeconds = targetSeconds;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::previewDispatched(
    media::native_playback::GestureId gesture,
    media::native_playback::RequestId request, double targetSeconds,
    bool libmpvInitialized) noexcept {
  if (!media::native_playback::valid(gesture) ||
      !media::native_playback::valid(request) ||
      !media::native_playback::validPosition(targetSeconds)) {
    return;
  }
  Point point{};
  point.event = Event::PreviewDispatched;
  point.route = Route::Native;
  point.gesture = gesture.value;
  point.request = request.value;
  point.hasTargetSeconds = true;
  point.targetSeconds = targetSeconds;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::previewAdmitted(
    const media::native_playback::PreviewFrame &command,
    bool libmpvInitialized) noexcept {
  if (!media::native_playback::valid(command)) {
    return;
  }
  Point point{};
  point.event = Event::PreviewAdmitted;
  point.route = Route::Native;
  point.attempt = command.stamp.attempt.value;
  point.serial = command.stamp.serial.value;
  point.generation = command.generation.value;
  point.gesture = command.gesture.value;
  point.request = command.request.value;
  point.hasTargetSeconds = true;
  point.targetSeconds = command.targetSeconds;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::previewFrameDrawn(
    const media::native_playback::PreviewPresented &event,
    bool libmpvInitialized) noexcept {
  if (!media::native_playback::valid(event)) {
    return;
  }
  Point point{};
  point.event = Event::PreviewFrameDrawn;
  point.route = Route::Native;
  point.attempt = event.stamp.attempt.value;
  point.serial = event.stamp.serial.value;
  point.generation = event.generation.value;
  point.gesture = event.gesture.value;
  point.request = event.request.value;
  point.hasTargetSeconds = true;
  // For this terminal fact, target_seconds is the real frame presentation
  // timestamp reported by PreviewPresented, not the requested target.
  point.targetSeconds = event.actualPresentationTimeSeconds;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::previewFailed(
    const media::native_playback::PreviewFailed &event,
    bool libmpvInitialized) noexcept {
  if (!media::native_playback::valid(event)) {
    return;
  }
  Point point{};
  point.event = Event::PreviewFailed;
  point.route = Route::Native;
  point.attempt = event.stamp.attempt.value;
  point.serial = event.stamp.serial.value;
  point.generation = event.generation.value;
  point.gesture = event.gesture.value;
  point.request = event.request.value;
  point.hasTargetSeconds = true;
  point.targetSeconds = event.targetSeconds;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::commitSeekSubmitted(
    const media::native_playback::CommitSeek &command,
    bool libmpvInitialized) noexcept {
  Point point{};
  point.event = Event::CommitSeekSubmitted;
  point.route = Route::Native;
  point.attempt = command.stamp.attempt.value;
  point.serial = command.stamp.serial.value;
  point.generation = command.targetGeneration.value;
  point.gesture = command.gesture.value;
  point.request = command.request.value;
  point.hasTargetSeconds = true;
  point.targetSeconds = command.targetSeconds;
  point.libmpvInitialized = libmpvInitialized;
  static_cast<void>(record(point));
}

void NativeBenchmarkTelemetry::commitReady(
    const media::native_playback::CommitReady &event,
    bool libmpvInitialized) noexcept {
  if (!enabled_ || failed_ || finished_ || !onOwnerThread()) {
    return;
  }
  const std::uint64_t now = clock_();
  Point point{};
  point.event = Event::CommitReady;
  point.route = Route::Native;
  point.attempt = event.stamp.attempt.value;
  point.serial = event.stamp.serial.value;
  point.generation = event.generation.value;
  point.gesture = event.gesture.value;
  point.request = event.request.value;
  point.drawSequence = event.videoDraw.drawSequence;
  point.hasTargetSeconds = true;
  point.targetSeconds = event.targetSeconds;
  point.libmpvInitialized = libmpvInitialized;
  if (event.videoDraw.videoLaneAbsent) {
    // An audio-only generation commits on the audio clock alone. There is no
    // frame, so the paired commit_frame_drawn is genuinely absent rather than
    // reported at time zero: the evidence stream must not carry a draw that
    // never happened.
    static_cast<void>(recordAt(point, now));
    return;
  }
  Point draw{};
  draw.event = Event::CommitFrameDrawn;
  draw.route = Route::Native;
  draw.attempt = event.videoDraw.stamp.attempt.value;
  draw.serial = event.videoDraw.stamp.serial.value;
  draw.generation = event.videoDraw.generation.value;
  draw.gesture = event.gesture.value;
  draw.request = event.request.value;
  draw.drawSequence = event.videoDraw.drawSequence;
  draw.hasTargetSeconds = true;
  draw.targetSeconds = event.videoDraw.frameStartSeconds;
  draw.libmpvInitialized = libmpvInitialized;
  static_cast<void>(recordPairAt(point, draw, now));
}

} // namespace wam::qt
