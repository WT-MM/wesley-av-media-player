#include "media/native_late_frame_trace.hpp"
#include "qt/native_playback_metrics.hpp"
#include <cstdint>
#include <limits>

int main() {
  using namespace wam::media::late_trace;
  Record r;
  const auto maximum = std::numeric_limits<std::uint64_t>::max();
  for (auto* field : {&r.consumer, &r.generation, &r.ordinal, &r.deadline,
      &r.decodeComplete, &r.lease, &r.observed, &r.commit, &r.previousCommit,
      &r.sinceOpen, &r.sinceSeek, &r.ticksPerSecond, &r.surfaces,
      &r.surfaceRejections, &r.decodedDepth, &r.videoDepth, &r.audioDepth,
      &r.workerStep, &r.previousWorkerStep, &r.clockSample, &r.clockAnchor,
      &r.sinceOpenRequest, &r.sinceSeekLanding, &r.waitBegin, &r.waitEnd, &r.waitDue,
      &r.display, &r.refreshHost, &r.refreshPeriod, &r.refreshScale,
      &r.slowWaitBegin, &r.slowWaitEnd, &r.slowWaitDue})
    *field = maximum;
  r.pts = std::numeric_limits<std::int64_t>::min();
  r.duration = std::numeric_limits<std::int64_t>::max();
  r.ptsScale = r.durationScale = std::numeric_limits<std::int32_t>::max();
  r.clockMedia = r.clockAnchorMedia = -std::numeric_limits<double>::max();
  r.late = r.awaitingOutput = r.seekKnown = r.seekWithinTwoSeconds = true;
  r.waitTimedOut = r.waitHostPaced = true;
  r.outputTicks.fill(maximum);
  if (!enabled || !traceSlots[0].ring.push(r)) return 1;
  wam::qt::NativePlaybackMetricsSample sample;
  sample.hasVideo = sample.hasAudio = sample.hasClock = true;
  sample.sessionEpoch = sample.drawnFrames = sample.submittedFrames = maximum;
  sample.supersededFrames = sample.discardedLateFrames = maximum;
  sample.audioUnderrunCallbacks = sample.audioClockAdvancedUnderruns = maximum;
  sample.audioRetiredLateFrames = sample.audioCallbacks = sample.audioRenderedFrames = maximum;
  sample.mediaSeconds = sample.clockRate = std::numeric_limits<double>::max();
  return wam::qt::NativePlaybackMetrics::instance().write(sample) ? 0 : 2;
}
