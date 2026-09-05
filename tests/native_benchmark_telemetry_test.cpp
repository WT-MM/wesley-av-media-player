#include "qt/native_benchmark_telemetry.hpp"

#include <cstdlib>
#include <cerrno>
#include <iostream>
#include <iterator>
#include <limits>
#include <locale.h>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace wam::qt {

struct NativeBenchmarkTelemetryTestAccess {
  using Clock = NativeBenchmarkTelemetry::Clock;
  using Sink = NativeBenchmarkTelemetry::Sink;
  using Flusher = NativeBenchmarkTelemetry::Flusher;

  static std::unique_ptr<NativeBenchmarkTelemetry>
  create(bool enabled, Clock clock, Sink sink, Flusher flusher, void *context) {
    if (enabled) {
      setenv("WAM_NATIVE_BENCHMARK_RUN_ID",
             "12345678-1234-4abc-8def-1234567890ab", 1);
      setenv("WAM_NATIVE_BENCHMARK_ASSET_SHA256",
             "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
             1);
      setenv("WAM_NATIVE_BENCHMARK_CANDIDATE_ID",
             "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
             1);
    }
    return std::unique_ptr<NativeBenchmarkTelemetry>(
        new NativeBenchmarkTelemetry(enabled, clock, sink, flusher, context));
  }

  static std::unique_ptr<NativeBenchmarkTelemetry>
  createWithCurrentEnvironment(bool enabled, Clock clock, Sink sink,
                               Flusher flusher, void *context) {
    return std::unique_ptr<NativeBenchmarkTelemetry>(
        new NativeBenchmarkTelemetry(enabled, clock, sink, flusher, context));
  }

  static constexpr std::size_t capacity() noexcept {
    return NativeBenchmarkTelemetry::kMaximumBufferedPoints;
  }

  static bool failed(const NativeBenchmarkTelemetry &telemetry) noexcept {
    return telemetry.failed_;
  }

  static std::size_t
  buffered(const NativeBenchmarkTelemetry &telemetry) noexcept {
    return telemetry.pointCount_;
  }

  static bool
  hasEventBuffer(const NativeBenchmarkTelemetry &telemetry) noexcept {
    return telemetry.points_ != nullptr;
  }

  static bool
  hasOutputBuffer(const NativeBenchmarkTelemetry &telemetry) noexcept {
    return telemetry.serialized_ != nullptr;
  }
};

} // namespace wam::qt

namespace {

namespace native = wam::media::native_playback;
using wam::qt::NativeBenchmarkTelemetry;
using wam::qt::NativeBenchmarkTelemetryTestAccess;

std::uint64_t clockValue = 1000;
std::uint64_t clockCalls = 0;

std::uint64_t testClock() noexcept {
  ++clockCalls;
  clockValue += 10;
  return clockValue;
}

struct SinkProbe {
  std::string output;
  std::size_t writes{0};
  std::size_t flushes{0};
  std::uint64_t clockCallsAtFirstWrite{0};
  bool acceptWrites{true};
  bool acceptFlushes{true};
  std::size_t failWriteAt{0};
  std::size_t failFlushAt{0};
  std::size_t partialBytesOnFailedWrite{0};
  int failureErrno{0};
};

bool stringSink(const char *data, std::size_t size, void *context) noexcept {
  auto &probe = *static_cast<SinkProbe *>(context);
  ++probe.writes;
  if (probe.writes == 1) {
    probe.clockCallsAtFirstWrite = clockCalls;
  }
  if (!probe.acceptWrites ||
      (probe.failWriteAt != 0 && probe.writes == probe.failWriteAt)) {
    if (probe.partialBytesOnFailedWrite != 0 && data != nullptr) {
      try {
        probe.output.append(
            data, std::min(size, probe.partialBytesOnFailedWrite));
      } catch (...) {
        std::abort();
      }
    }
    errno = probe.failureErrno;
    return false;
  }
  try {
    probe.output.append(data, size);
  } catch (...) {
    std::abort();
  }
  return true;
}

bool stringFlush(void *context) noexcept {
  auto &probe = *static_cast<SinkProbe *>(context);
  ++probe.flushes;
  if (!probe.acceptFlushes ||
      (probe.failFlushAt != 0 && probe.flushes == probe.failFlushAt)) {
    errno = probe.failureErrno;
    return false;
  }
  return true;
}

void expect(bool condition, const char *message) {
  if (condition) {
    return;
  }
  std::cerr << "FAIL: " << message << '\n';
  std::exit(1);
}

std::vector<std::string_view> lines(const std::string &output) {
  std::vector<std::string_view> result;
  std::size_t begin = 0;
  while (begin < output.size()) {
    const std::size_t end = output.find('\n', begin);
    expect(end != std::string::npos, "every telemetry record ends in newline");
    const std::string_view line(output.data() + begin, end - begin);
    if (line.find("\"record\":\"event\"") != std::string_view::npos) {
      result.push_back(line);
    }
    begin = end + 1;
  }
  return result;
}

std::vector<std::string_view> rawLines(const std::string &output) {
  std::vector<std::string_view> result;
  std::size_t begin = 0;
  while (begin < output.size()) {
    const std::size_t end = output.find('\n', begin);
    expect(end != std::string::npos, "every telemetry record ends in newline");
    result.emplace_back(output.data() + begin, end - begin);
    begin = end + 1;
  }
  return result;
}

bool contains(std::string_view text, std::string_view fragment) {
  return text.find(fragment) != std::string_view::npos;
}

void disabledPathDoesNoWork() {
  static_assert(sizeof(NativeBenchmarkTelemetry) <= 384,
                "disabled telemetry must remain a small fixed object");
  SinkProbe probe;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      false, &testClock, &stringSink, &stringFlush, &probe);
  telemetry->openRequested(native::SourceKey{1}, false);
  expect(telemetry->checkpoint(),
         "disabled checkpoint remains a zero-work success");
  expect(telemetry->finish(), "disabled finish remains a zero-work success");
  expect(!telemetry->enabled(), "disabled telemetry remains disabled");
  expect(!NativeBenchmarkTelemetryTestAccess::hasEventBuffer(*telemetry),
         "disabled telemetry does not allocate its event buffer");
  expect(!NativeBenchmarkTelemetryTestAccess::hasOutputBuffer(*telemetry),
         "disabled telemetry does not allocate its output buffer");
  expect(clockCalls == 0, "disabled telemetry does not read the clock");
  expect(probe.output.empty() && probe.writes == 0 && probe.flushes == 0,
         "disabled telemetry does not invoke write or flush callbacks");
}

void enabledIdentityFailsClosedWithoutExactAssetToken() {
  SinkProbe probe;
  clockCalls = 0;
  setenv("WAM_NATIVE_BENCHMARK_RUN_ID",
         "12345678-1234-4abc-8def-1234567890ab", 1);
  setenv("WAM_NATIVE_BENCHMARK_CANDIDATE_ID",
         "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
         1);
  unsetenv("WAM_NATIVE_BENCHMARK_ASSET_SHA256");
  auto missing = NativeBenchmarkTelemetryTestAccess::createWithCurrentEnvironment(
      true, &testClock, &stringSink, &stringFlush, &probe);
  expect(!missing->enabled() &&
             !NativeBenchmarkTelemetryTestAccess::hasEventBuffer(*missing) &&
             !NativeBenchmarkTelemetryTestAccess::hasOutputBuffer(*missing) &&
             clockCalls == 0 && probe.writes == 0 && probe.flushes == 0,
         "enabled telemetry fails closed before allocation when asset identity is missing");

  setenv("WAM_NATIVE_BENCHMARK_ASSET_SHA256",
         "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789", 1);
  auto malformed =
      NativeBenchmarkTelemetryTestAccess::createWithCurrentEnvironment(
          true, &testClock, &stringSink, &stringFlush, &probe);
  expect(!malformed->enabled() &&
             !NativeBenchmarkTelemetryTestAccess::hasEventBuffer(*malformed) &&
             !NativeBenchmarkTelemetryTestAccess::hasOutputBuffer(*malformed) &&
             clockCalls == 0 && probe.writes == 0 && probe.flushes == 0,
         "enabled telemetry rejects a non-lowercase asset identity");

  setenv("WAM_NATIVE_BENCHMARK_ASSET_SHA256",
         "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
         1);

  unsetenv("WAM_NATIVE_BENCHMARK_CANDIDATE_ID");
  auto missingCandidate =
      NativeBenchmarkTelemetryTestAccess::createWithCurrentEnvironment(
          true, &testClock, &stringSink, &stringFlush, &probe);
  expect(!missingCandidate->enabled() &&
             !NativeBenchmarkTelemetryTestAccess::hasEventBuffer(
                 *missingCandidate) &&
             !NativeBenchmarkTelemetryTestAccess::hasOutputBuffer(
                 *missingCandidate) &&
             clockCalls == 0 && probe.writes == 0 && probe.flushes == 0,
         "enabled telemetry fails closed before allocation without candidate identity");
  setenv("WAM_NATIVE_BENCHMARK_CANDIDATE_ID",
         "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
         1);
  auto malformedCandidate =
      NativeBenchmarkTelemetryTestAccess::createWithCurrentEnvironment(
          true, &testClock, &stringSink, &stringFlush, &probe);
  expect(!malformedCandidate->enabled() &&
             !NativeBenchmarkTelemetryTestAccess::hasEventBuffer(
                 *malformedCandidate),
         "enabled telemetry rejects a non-lowercase candidate identity");
  setenv("WAM_NATIVE_BENCHMARK_CANDIDATE_ID",
         "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
         1);
}

void requiredFactsAreStableJsonLines() {
  SinkProbe probe;
  clockValue = 1000;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);

  const native::Stamp prepareStamp{native::AttemptId{7}, native::Serial{11}};
  const native::Prepare prepare{prepareStamp, native::SourceKey{3},
                                native::Generation{5}, 0.0};
  const native::Prepared prepared{prepareStamp,
                                  native::SourceKey{3},
                                  {90.0, true, true},
                                  native::Generation{5}};
  const native::Stamp startStamp{native::AttemptId{7}, native::Serial{12}};
  const native::Started started{startStamp, native::Generation{5}, 19};
  const native::Stamp drawStamp{native::AttemptId{7}, native::Serial{13}};
  const native::VideoDrawProof firstDraw{drawStamp, native::Generation{5}, 20,
                                         0.0, 1.0 / 30.0};

  const native::Stamp seekStamp{native::AttemptId{7}, native::Serial{14}};
  const native::CommitSeek seek{seekStamp,
                                native::Generation{5},
                                native::Generation{6},
                                native::GestureId{8},
                                native::RequestId{9},
                                12.5};
  const native::AudioClockProof clock{
      seekStamp, native::Generation{6}, native::AudioClockAnchorId{2}, 12.5,
      true,      native::kVersion1Rate};
  const native::VideoDrawProof seekDraw{seekStamp, native::Generation{6}, 21,
                                        12.49, 1.0 / 30.0};
  const native::CommitReady ready{seekStamp,
                                  native::Generation{6},
                                  native::GestureId{8},
                                  native::RequestId{9},
                                  12.5,
                                  clock,
                                  seekDraw};

  telemetry->openRequested(native::SourceKey{3}, false);
  telemetry->nativeSelected(prepare, false);
  telemetry->fallbackSelected(
      native::Stamp{native::AttemptId{8}, native::Serial{1}},
      native::SourceKey{3}, true);
  telemetry->prepared(prepared, false);
  telemetry->started(started, false);
  expect(probe.output.empty() && probe.writes == 0 && probe.flushes == 0,
         "startup facts remain memory-only before first-draw capture");
  expect(!telemetry->checkpoint() && probe.writes == 0 && probe.flushes == 0,
         "an explicit checkpoint cannot write while first draw is pending");
  telemetry->firstFrameDrawn(firstDraw, false);
  expect(probe.writes == 1 && probe.flushes == 1 &&
             probe.clockCallsAtFirstWrite == 6 && clockCalls == 6,
         "first draw samples time before one controlled write and flush");
  expect(lines(probe.output).size() == 6,
         "the first-draw checkpoint publishes the ordered startup batch");
  telemetry->commitSeekSubmitted(seek, false);
  telemetry->commitReady(ready, false);
  expect(lines(probe.output).size() == 6 && probe.writes == 1 &&
             probe.flushes == 1,
         "post-startup facts remain buffered until an explicit checkpoint");
  expect(telemetry->checkpoint(),
         "a post-first-draw GUI checkpoint flushes buffered seek proof");
  expect(probe.writes == 2 && probe.flushes == 2,
         "one checkpoint performs one aggregate write and one flush");
  expect(telemetry->finish(), "terminal finish succeeds after checkpoint");
  expect(probe.writes == 3 && probe.flushes == 3,
         "terminal finish publishes one durable stream commit");

  const auto records = lines(probe.output);
  const auto allRecords = rawLines(probe.output);
  expect(allRecords.size() == 15 &&
             contains(allRecords.front(), "\"record\":\"stream_header\"") &&
             contains(allRecords.front(), "\"format_version\":2") &&
             contains(allRecords[1], "\"record\":\"batch_begin\"") &&
             contains(allRecords[1], "\"first_sequence\":1") &&
             contains(allRecords[8], "\"record\":\"batch_commit\"") &&
             contains(allRecords[9], "\"record\":\"batch_begin\"") &&
             contains(allRecords[13], "\"record\":\"batch_commit\"") &&
             contains(allRecords.back(), "\"record\":\"stream_commit\"") &&
             contains(allRecords.back(), "\"batch_count\":2") &&
             contains(allRecords.back(), "\"event_count\":9") &&
             contains(allRecords.back(), "\"last_sequence\":9"),
         "framing commits the exact two-batch sequence and terminal totals");
  expect(records.size() == 9,
         "eight facts emit nine records including commit draw");
  expect(clockCalls == 8,
         "CommitReady and its exact draw share one monotonic clock sample");
  for (const std::string_view record : records) {
    expect(contains(record, "\"schema\":\"wam.native.benchmark.v2\""),
           "every record carries the stable schema");
    expect(!record.empty() && record.front() == '{' && record.back() == '}',
           "each record is one JSON object");
    expect(contains(record, "\"monotonic_ns\":"),
           "every record carries a monotonic timestamp");
    expect(
        contains(record, "\"run_id\":\"12345678-1234-4abc-8def-1234567890ab\""),
        "every record carries the exact benchmark run identity");
    expect(contains(record, "\"process_id\":") &&
               !contains(record, "\"process_id\":0") &&
               contains(record, "\"process_start_abstime\":") &&
               !contains(record, "\"process_start_abstime\":0"),
           "every record binds the process PID and exact start identity");
    expect(contains(record, "\"libmpv_initialized\":"),
           "every record reports the compatibility-engine flag");
  }

  expect(contains(records[0], "\"event\":\"open_requested\"") &&
             contains(records[0], "\"route\":\"undecided\"") &&
             contains(records[0], "\"source_key\":3"),
         "open request is source-correlated before route selection");
  expect(contains(records[1], "\"event\":\"native_selected\"") &&
             contains(records[1], "\"route_proof\":true") &&
             contains(records[1], "\"generation\":5"),
         "native selection is an explicit router proof");
  expect(contains(records[2], "\"event\":\"fallback_selected\"") &&
             contains(records[2], "\"route\":\"fallback\"") &&
             contains(records[2], "\"libmpv_initialized\":true"),
         "fallback selection reports route and libmpv state");
  expect(contains(records[3], "\"event\":\"prepared\"") &&
             contains(records[4], "\"event\":\"started\"") &&
             contains(records[4], "\"serial\":12") &&
             contains(records[5], "\"event\":\"first_frame_drawn\"") &&
             contains(records[5], "\"serial\":13") &&
             contains(records[5], "\"draw_sequence\":20"),
         "native startup facts retain advancing command and draw identities");
  expect(contains(records[6], "\"event\":\"commit_seek_submitted\"") &&
             contains(records[6], "\"target_seconds\":12.5"),
         "commit submission carries its exact target");
  expect(contains(records[7], "\"event\":\"commit_ready\"") &&
             contains(records[8], "\"event\":\"commit_frame_drawn\"") &&
             contains(records[7], "\"monotonic_ns\":1080") &&
             contains(records[8], "\"monotonic_ns\":1080") &&
             contains(records[7], "\"target_seconds\":12.5") &&
             contains(records[8], "\"target_seconds\":12.49") &&
             contains(records[8], "\"draw_sequence\":21"),
         "commit readiness and its exact covering draw share proof time but "
         "retain distinct requested and presented positions");
}

void finiteTargetsAreLocaleIndependentJsonNumbers() {
  SinkProbe probe;
  probe.output.reserve(4096);
  clockValue = 2000;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);

  locale_t commaLocale = newlocale(LC_NUMERIC_MASK, "fr_FR.UTF-8", nullptr);
  expect(commaLocale != nullptr, "test comma-decimal locale is available");
  locale_t previousLocale = uselocale(commaLocale);
  expect(previousLocale != nullptr, "test installs a thread-local locale");

  const double targets[] = {
      0.1,
      std::numeric_limits<double>::max(),
      std::numeric_limits<double>::min(),
      std::numeric_limits<double>::denorm_min(),
      -0.0,
      std::numeric_limits<double>::infinity(),
  };
  for (std::size_t index = 0; index < std::size(targets); ++index) {
    const native::Stamp stamp{native::AttemptId{1}, native::Serial{index + 1}};
    const native::Prepare prepare{stamp, native::SourceKey{1},
                                  native::Generation{1}, targets[index]};
    telemetry->nativeSelected(prepare, false);
  }

  expect(uselocale(previousLocale) == commaLocale,
         "test restores the prior thread-local locale");
  freelocale(commaLocale);
  expect(probe.output.empty() && probe.writes == 0 && probe.flushes == 0,
         "numeric formatting is deferred with the buffered batch");
  expect(telemetry->finish(),
         "terminal finish serializes locale-independent numeric facts");

  const auto records = lines(probe.output);
  expect(records.size() == std::size(targets),
         "all numeric edge cases emit one record");
  expect(contains(records[0], "\"target_seconds\":0.10000000000000001,"),
         "finite target retains max-digits round-trip precision");
  expect(contains(records[1], "\"target_seconds\":1.7976931348623157e+308,"),
         "largest finite target remains a valid JSON number");
  expect(contains(records[2], "\"target_seconds\":2.2250738585072014e-308,"),
         "smallest normal target remains a valid JSON number");
  expect(contains(records[3], "\"target_seconds\":4.9406564584124654e-324,"),
         "smallest subnormal target remains a valid JSON number");
  expect(contains(records[4], "\"target_seconds\":-0,"),
         "negative zero remains a valid JSON number");
  expect(contains(records[5], "\"target_seconds\":null,"),
         "non-finite targets remain null");
}

void terminalDestructionPublishesWithoutPerEventIo() {
  SinkProbe probe;
  clockValue = 3000;
  clockCalls = 0;
  {
    auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
        true, &testClock, &stringSink, &stringFlush, &probe);
    const native::Stamp stamp{native::AttemptId{2}, native::Serial{3}};
    const native::Prepare prepare{stamp, native::SourceKey{4},
                                  native::Generation{5}, 0.0};
    telemetry->openRequested(native::SourceKey{4}, false);
    telemetry->nativeSelected(prepare, false);
    expect(probe.writes == 0 && probe.flushes == 0,
           "orderly-shutdown proof remains buffered during event calls");
  }

  const auto records = lines(probe.output);
  expect(probe.writes == 2 && probe.flushes == 2 && records.size() == 2,
         "destruction publishes the terminal batch and durable stream commit");
  expect(contains(records[0], "\"event\":\"open_requested\"") &&
             contains(records[1], "\"event\":\"native_selected\""),
         "terminal drain preserves event order for post-quit harness parsing");
}

void previewFactsPreserveDemandAndTerminalIdentity() {
  SinkProbe probe;
  probe.output.reserve(8192);
  clockValue = 3500;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  expect(NativeBenchmarkTelemetryTestAccess::hasEventBuffer(*telemetry),
         "enabled telemetry allocates one event buffer before recording");
  expect(NativeBenchmarkTelemetryTestAccess::hasOutputBuffer(*telemetry),
         "enabled telemetry preallocates output away from event calls");

  const native::Stamp startupStamp{native::AttemptId{3}, native::Serial{4}};
  telemetry->openRequested(native::SourceKey{2}, false);
  telemetry->firstFrameDrawn(native::VideoDrawProof{startupStamp,
                                                    native::Generation{5}, 6,
                                                    0.0, 1.0 / 30.0},
                             false);
  expect(lines(probe.output).size() == 2,
         "startup facts are published before preview measurement begins");

  const native::GestureId gesture{8};
  const native::PreviewFrame admitted{{native::AttemptId{3}, native::Serial{7}},
                                      native::Generation{5},
                                      gesture,
                                      native::RequestId{10},
                                      12.25};
  const native::PreviewPresented drawn{admitted.stamp, admitted.generation,
                                       gesture, admitted.request,
                                       12.233333333333333};
  const native::PreviewFrame failedCommand{
      {native::AttemptId{3}, native::Serial{8}},
      native::Generation{5},
      gesture,
      native::RequestId{11},
      14.0};
  const native::PreviewFailed failed{
      failedCommand.stamp, failedCommand.generation, gesture,
      failedCommand.request, failedCommand.targetSeconds};

  telemetry->previewDemanded(gesture, admitted.request, admitted.targetSeconds,
                             false);
  telemetry->previewDispatched(gesture, admitted.request,
                               admitted.targetSeconds, false);
  telemetry->previewAdmitted(admitted, false);
  telemetry->previewFrameDrawn(drawn, false);
  telemetry->previewDemanded(gesture, failedCommand.request,
                             failedCommand.targetSeconds, false);
  telemetry->previewDispatched(gesture, failedCommand.request,
                               failedCommand.targetSeconds, false);
  telemetry->previewAdmitted(failedCommand, false);
  telemetry->previewFailed(failed, false);
  const std::uint64_t callsBeforeInvalid = clockCalls;
  telemetry->previewDemanded(native::GestureId{}, native::RequestId{12}, 15.0,
                             false);
  expect(clockCalls == callsBeforeInvalid,
         "invalid preview demand is rejected before reading the clock");
  expect(telemetry->checkpoint(),
         "one post-drag checkpoint publishes buffered preview proof");

  const auto records = lines(probe.output);
  expect(records.size() == 10,
         "two startup and eight preview facts are published exactly once");
  expect(contains(records.front(),
                  "\"asset_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"") &&
             contains(records.back(),
                      "\"asset_sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""),
         "every event carries the one exact precomputed asset identity");
  expect(contains(records[2], "\"event\":\"preview_demanded\"") &&
             contains(records[2], "\"gesture\":8") &&
             contains(records[2], "\"request\":10") &&
             contains(records[2], "\"target_seconds\":12.25"),
         "preview demand carries its exact public identity and target");
  expect(contains(records[3], "\"event\":\"preview_dispatched\"") &&
             contains(records[4], "\"event\":\"preview_admitted\"") &&
             contains(records[4], "\"attempt\":3") &&
             contains(records[4], "\"serial\":7") &&
             contains(records[4], "\"generation\":5"),
         "preview admission adds exact native command identity");
  expect(contains(records[5], "\"event\":\"preview_frame_drawn\"") &&
             contains(records[5], "\"target_seconds\":12.233333333333333"),
         "preview draw reports the real presentation timestamp");
  expect(contains(records[6], "\"event\":\"preview_demanded\"") &&
             contains(records[7], "\"event\":\"preview_dispatched\"") &&
             contains(records[8], "\"event\":\"preview_admitted\"") &&
             contains(records[9], "\"event\":\"preview_failed\"") &&
             contains(records[9], "\"request\":11") &&
             contains(records[9], "\"target_seconds\":14"),
         "failed preview retains the same identity and requested target");
  expect(probe.writes == 2 && probe.flushes == 2,
         "preview events perform no per-event output");
}

void bufferOverflowFailsClosedWithoutPartialProof() {
  SinkProbe probe;
  clockValue = 4000;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  const std::size_t capacity = NativeBenchmarkTelemetryTestAccess::capacity();
  for (std::size_t index = 0; index < capacity; ++index) {
    const native::Stamp stamp{native::AttemptId{1}, native::Serial{index + 1}};
    telemetry->nativeSelected(native::Prepare{stamp, native::SourceKey{1},
                                              native::Generation{1}, 0.0},
                              false);
  }
  expect(!NativeBenchmarkTelemetryTestAccess::failed(*telemetry) &&
             NativeBenchmarkTelemetryTestAccess::buffered(*telemetry) ==
                 capacity &&
             probe.writes == 0 && probe.flushes == 0,
         "the enabled-only fixed capacity remains event-allocation-free and "
         "memory-only");

  telemetry->nativeSelected(
      native::Prepare{{native::AttemptId{1}, native::Serial{capacity + 1}},
                      native::SourceKey{1},
                      native::Generation{1},
                      0.0},
      false);
  expect(NativeBenchmarkTelemetryTestAccess::failed(*telemetry) &&
             NativeBenchmarkTelemetryTestAccess::buffered(*telemetry) == 0 &&
             probe.output.empty() && probe.writes == 0 && probe.flushes == 0,
         "buffer overflow discards the whole batch without partial proof");
  const std::uint64_t callsAfterOverflow = clockCalls;
  telemetry->firstFrameDrawn(
      native::VideoDrawProof{
          {native::AttemptId{1}, native::Serial{capacity + 1}},
          native::Generation{1},
          1,
          0.0,
          1.0 / 30.0},
      false);
  expect(clockCalls == callsAfterOverflow && !telemetry->finish() &&
             probe.output.empty() && probe.writes == 0 && probe.flushes == 0,
         "failed telemetry performs no later clock, write, flush, or retry");
}

void partialWriteCannotCommitTelemetry() {
  SinkProbe probe;
  probe.failWriteAt = 2;
  probe.failureErrno = ENOSPC;
  clockValue = 4500;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  for (std::size_t index = 0; index < 400; ++index) {
    telemetry->nativeSelected(
        native::Prepare{{native::AttemptId{1}, native::Serial{index + 1}},
                        native::SourceKey{1}, native::Generation{1}, 0.0},
        false);
  }
  expect(!telemetry->finish() &&
             NativeBenchmarkTelemetryTestAccess::failed(*telemetry),
         "a later ENOSPC write fails the entire telemetry stream");
  const auto records = rawLines(probe.output);
  expect(!records.empty() &&
             !contains(probe.output, "\"record\":\"batch_commit\"") &&
             !contains(probe.output, "\"record\":\"stream_commit\""),
         "a durable multi-chunk prefix has neither a batch nor stream commit");
}

void shortWriteCannotCommitTelemetry() {
  SinkProbe probe;
  probe.failWriteAt = 2;
  probe.partialBytesOnFailedWrite = 17;
  probe.failureErrno = ENOSPC;
  clockValue = 4600;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  for (std::size_t index = 0; index < 400; ++index) {
    telemetry->nativeSelected(
        native::Prepare{{native::AttemptId{1}, native::Serial{index + 1}},
                        native::SourceKey{1}, native::Generation{1}, 0.0},
        false);
  }
  expect(!telemetry->finish() &&
             NativeBenchmarkTelemetryTestAccess::failed(*telemetry),
         "a short second write fails the entire telemetry stream");
  expect(!contains(probe.output, "\"record\":\"batch_commit\"") &&
             !contains(probe.output, "\"record\":\"stream_commit\"") &&
             !probe.output.empty() && probe.output.back() != '\n',
         "a persisted partial line cannot gain a batch or terminal commit");
}

void failedFlushCannotCommitTelemetryStream() {
  SinkProbe probe;
  probe.failFlushAt = 1;
  probe.failureErrno = EINTR;
  clockValue = 4700;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  telemetry->nativeSelected(
      native::Prepare{{native::AttemptId{1}, native::Serial{1}},
                      native::SourceKey{1}, native::Generation{1}, 0.0},
      false);
  expect(!telemetry->finish() &&
             NativeBenchmarkTelemetryTestAccess::failed(*telemetry),
         "an interrupted flush fails the telemetry stream");
  expect(contains(probe.output, "\"record\":\"batch_commit\"") &&
             !contains(probe.output, "\"record\":\"stream_commit\""),
         "a batch whose flush failed is never followed by a stream commit");
}

void terminalCommitFailureLeavesPriorBatchesIncomplete() {
  SinkProbe probe;
  clockValue = 4800;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  telemetry->openRequested(native::SourceKey{1}, false);
  telemetry->firstFrameDrawn(
      native::VideoDrawProof{{native::AttemptId{1}, native::Serial{1}},
                             native::Generation{1}, 1, 0.0, 1.0 / 30.0},
      false);
  expect(contains(probe.output, "\"record\":\"batch_commit\"") &&
             !contains(probe.output, "\"record\":\"stream_commit\""),
         "a live checkpoint commits a batch but not the complete stream");
  probe.failWriteAt = probe.writes + 1;
  probe.failureErrno = ENOSPC;
  expect(!telemetry->finish(), "terminal stream-commit write failure is fatal");
  expect(!contains(probe.output, "\"record\":\"stream_commit\""),
         "prior complete batches cannot masquerade as a complete output");
}

void controllerThreadConfinementIsFailClosed() {
  SinkProbe probe;
  clockValue = 5000;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  std::thread foreign(
      [&telemetry] { telemetry->openRequested(native::SourceKey{99}, false); });
  foreign.join();
  expect(clockCalls == 0 &&
             NativeBenchmarkTelemetryTestAccess::buffered(*telemetry) == 0 &&
             probe.writes == 0 && probe.flushes == 0,
         "a non-owner event is ignored before clock or buffer access");

  const native::Stamp stamp{native::AttemptId{6}, native::Serial{7}};
  telemetry->openRequested(native::SourceKey{8}, false);
  telemetry->firstFrameDrawn(
      native::VideoDrawProof{stamp, native::Generation{9}, 10, 0.0, 1.0 / 30.0},
      false);
  const auto records = lines(probe.output);
  expect(records.size() == 2 && contains(records[0], "\"source_key\":8") &&
             !contains(probe.output, "\"source_key\":99"),
         "owner-thread facts remain ordered after a rejected foreign call");
}

void fallbackPublicationTracksFirstDrawBoundary() {
  SinkProbe probe;
  clockValue = 6000;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  const native::Stamp nativeStamp{native::AttemptId{1}, native::Serial{1}};
  telemetry->openRequested(native::SourceKey{7}, false);
  telemetry->fallbackSelected(
      native::Stamp{native::AttemptId{2}, native::Serial{1}},
      native::SourceKey{7}, true);
  expect(probe.writes == 0 && probe.flushes == 0 && probe.output.empty(),
         "pre-first-draw fallback remains memory-only on the measured path");

  telemetry->firstFrameDrawn(native::VideoDrawProof{nativeStamp,
                                                    native::Generation{3}, 4,
                                                    0.0, 1.0 / 30.0},
                             false);
  expect(probe.writes == 1 && probe.flushes == 1,
         "first draw publishes its startup batch only after timestamp capture");

  telemetry->fallbackSelected(
      native::Stamp{native::AttemptId{5}, native::Serial{1}},
      native::SourceKey{8}, true);
  const auto records = lines(probe.output);
  expect(
      probe.writes == 2 && probe.flushes == 2 && records.size() == 4 &&
          contains(records.back(), "\"event\":\"fallback_selected\"") &&
          contains(records.back(), "\"source_key\":8") &&
          contains(records.back(), "\"libmpv_initialized\":true"),
      "post-first-draw fallback is durably written and flushed before return");
}

void laterOpenRestoresFirstDrawWriteBarrier() {
  SinkProbe probe;
  probe.output.reserve(8192);
  clockValue = 7000;
  clockCalls = 0;
  auto telemetry = NativeBenchmarkTelemetryTestAccess::create(
      true, &testClock, &stringSink, &stringFlush, &probe);
  const native::Stamp firstStamp{native::AttemptId{1}, native::Serial{1}};
  telemetry->openRequested(native::SourceKey{7}, false);
  telemetry->firstFrameDrawn(native::VideoDrawProof{firstStamp,
                                                    native::Generation{3}, 4,
                                                    0.0, 1.0 / 30.0},
                             false);
  expect(probe.writes == 1 && probe.flushes == 1,
         "the first open publishes only after its draw timestamp");

  telemetry->openRequested(native::SourceKey{8}, false);
  telemetry->fallbackSelected(
      native::Stamp{native::AttemptId{2}, native::Serial{1}},
      native::SourceKey{8}, true);
  expect(probe.writes == 1 && probe.flushes == 1 &&
             NativeBenchmarkTelemetryTestAccess::buffered(*telemetry) == 2,
         "a later open cannot inherit the prior open's write permission");
  expect(!telemetry->checkpoint() && probe.writes == 1 && probe.flushes == 1,
         "an explicit checkpoint also respects the later first-draw barrier");
  expect(telemetry->finish(),
         "terminal shutdown may publish a later open that never drew");
  const auto records = lines(probe.output);
  expect(records.size() == 4 &&
             contains(records[2], "\"event\":\"open_requested\"") &&
             contains(records[2], "\"source_key\":8") &&
             contains(records[3], "\"event\":\"fallback_selected\"") &&
             contains(records[3], "\"source_key\":8"),
         "the terminal batch preserves the later open and fallback evidence");
}

void environmentTruthVocabularyIsStatedOnce() {
  unsetenv("WAM_NATIVE_BENCHMARK_TELEMETRY");
  expect(!wam::qt::nativeBenchmarkTelemetryArmed(),
         "an unset opt-in leaves telemetry and every seam disarmed");
  static constexpr const char *kOff[] = {"0",  "",   "off", "false",
                                         "no", "On", "junk"};
  for (const char *value : kOff) {
    setenv("WAM_NATIVE_BENCHMARK_TELEMETRY", value, 1);
    expect(!wam::qt::nativeBenchmarkTelemetryArmed(),
           "anything outside the truth vocabulary disarms every seam");
  }
  static constexpr const char *kOn[] = {"1",   "true", "TRUE", "yes",
                                        "YES", "on",   "ON"};
  for (const char *value : kOn) {
    setenv("WAM_NATIVE_BENCHMARK_TELEMETRY", value, 1);
    expect(wam::qt::nativeBenchmarkTelemetryArmed(),
           "every truth spelling arms telemetry and every seam together");
  }
  unsetenv("WAM_NATIVE_BENCHMARK_TELEMETRY");
  setenv("WAM_TEST_TRUTH_VOCABULARY", "yes", 1);
  expect(wam::qt::wamEnvironmentTruth("WAM_TEST_TRUTH_VOCABULARY") &&
             !wam::qt::wamEnvironmentTruth("WAM_TEST_TRUTH_VOCABULARY_UNSET"),
         "the same vocabulary answers for every WAM_* opt-in");
  unsetenv("WAM_TEST_TRUTH_VOCABULARY");
}

} // namespace

int main() {
  environmentTruthVocabularyIsStatedOnce();
  disabledPathDoesNoWork();
  enabledIdentityFailsClosedWithoutExactAssetToken();
  requiredFactsAreStableJsonLines();
  finiteTargetsAreLocaleIndependentJsonNumbers();
  terminalDestructionPublishesWithoutPerEventIo();
  previewFactsPreserveDemandAndTerminalIdentity();
  bufferOverflowFailsClosedWithoutPartialProof();
  partialWriteCannotCommitTelemetry();
  shortWriteCannotCommitTelemetry();
  failedFlushCannotCommitTelemetryStream();
  terminalCommitFailureLeavesPriorBatchesIncomplete();
  controllerThreadConfinementIsFailClosed();
  fallbackPublicationTracksFirstDrawBoundary();
  laterOpenRestoresFirstDrawWriteBarrier();
  std::cout << "native benchmark telemetry tests passed\n";
  return 0;
}
