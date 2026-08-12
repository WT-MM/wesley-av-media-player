#include "native_video_session.hpp"

#include "native_qt_gl_output.hpp"

#include <QThread>

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace wam::macos {
namespace {

using native_activation::Action;
using native_activation::ActionCompletion;
using native_activation::NativeSample;
using native_activation::Token;

class PipelineAdapter final : public NativeVideoSessionPipeline {
public:
  explicit PipelineAdapter(std::unique_ptr<NativeVideoPipeline> pipeline)
      : pipeline_(std::move(pipeline)) {}

  bool prepareLocalFileAsync(const std::filesystem::path &path,
                             double initialPositionSeconds,
                             std::string *error) override {
    return pipeline_->prepareLocalFileAsync(path, initialPositionSeconds,
                                            error);
  }

  std::optional<NativeVideoPrepareOutcome>
  takePrepareResult() noexcept override {
    return pipeline_->takePrepareResult();
  }

  std::optional<std::uint64_t>
  startPrepared(std::string *error) noexcept override {
    return pipeline_->startPrepared(error);
  }

  std::uint64_t stop() noexcept override { return pipeline_->stop(); }

  void updateAudioClock(double positionSeconds, bool paused,
                        double rate) noexcept override {
    pipeline_->updateAudioClock(positionSeconds, paused, rate);
  }

  std::optional<std::uint64_t> seek(double positionSeconds) noexcept override {
    return pipeline_->seek(positionSeconds);
  }

  std::optional<std::string> takeLastError() noexcept override {
    return pipeline_->takeLastError();
  }

  NativeVideoPipelineStats stats() const noexcept override {
    return pipeline_->stats();
  }

private:
  std::unique_ptr<NativeVideoPipeline> pipeline_;
};

bool validToken(Token token) noexcept {
  return token.request != 0 && token.attempt != 0;
}

bool validTransport(const native_activation::Transport &value) noexcept {
  return std::isfinite(value.position) && value.position >= 0.0 &&
         std::isfinite(value.rate) && value.rate > 0.0;
}

bool nativeAction(Action::Kind kind) noexcept {
  switch (kind) {
  case Action::Kind::PrepareNative:
  case Action::Kind::StartNative:
  case Action::Kind::SeekNative:
  case Action::Kind::StopNative:
  case Action::Kind::UpdateNativeClock:
    return true;
  default:
    return false;
  }
}

} // namespace

NativeVideoSession::NativeVideoSession(
    Token token, std::filesystem::path source,
    std::shared_ptr<NativeScheduledFrameOutput> output,
    std::unique_ptr<NativeVideoSessionPipeline> pipeline,
    QThread *ownerThread) noexcept
    : token_(token), source_(std::move(source)), output_(std::move(output)),
      pipeline_(std::move(pipeline)), owner_thread_(ownerThread) {
  const NativeScheduledFrameOutputStats outputStats = output_->stats();
  const NativeVideoPipelineStats pipelineStats = pipeline_->stats();
  output_fatal_serial_ = outputStats.fatalErrorSerial;
  generation_high_water_ =
      std::max(outputStats.acceptedGeneration, pipelineStats.generation);
}

std::unique_ptr<NativeVideoSession>
NativeVideoSession::create(QtGlVideoItem *item, Token token,
                           std::filesystem::path source, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (!validToken(token) || source.empty()) {
    if (error != nullptr) {
      *error = "native video session requires a token and source";
    }
    return nullptr;
  }
  auto output = NativeQtGlOutput::create(item, error);
  if (output == nullptr) {
    return nullptr;
  }
  auto pipeline = NativeVideoPipeline::createForQtOpenGL(output, error);
  if (pipeline == nullptr) {
    const NativeScheduledFrameOutputStats outputStats = output->stats();
    const std::uint64_t closeGeneration =
        outputStats.acceptedGeneration ==
                std::numeric_limits<std::uint64_t>::max()
            ? outputStats.acceptedGeneration
            : outputStats.acceptedGeneration + 1;
    output->close(closeGeneration);
    return nullptr;
  }
  return std::unique_ptr<NativeVideoSession>(new NativeVideoSession(
      token, std::move(source), output,
      std::make_unique<PipelineAdapter>(std::move(pipeline)), item->thread()));
}

#if defined(WAM_NATIVE_VIDEO_SESSION_TESTING)
std::unique_ptr<NativeVideoSession> NativeVideoSession::createForTesting(
    Token token, std::filesystem::path source,
    std::shared_ptr<NativeScheduledFrameOutput> output,
    std::unique_ptr<NativeVideoSessionPipeline> pipeline, QThread *ownerThread,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (!validToken(token) || source.empty() || output == nullptr ||
      pipeline == nullptr || ownerThread == nullptr) {
    if (error != nullptr) {
      *error = "invalid native video session test dependency";
    }
    return nullptr;
  }
  const NativeScheduledFrameOutputStats stats = output->stats();
  if (stats.closed) {
    if (error != nullptr) {
      *error = "native video session output is closed";
    }
    return nullptr;
  }
  return std::unique_ptr<NativeVideoSession>(
      new NativeVideoSession(token, std::move(source), std::move(output),
                             std::move(pipeline), ownerThread));
}
#endif

NativeVideoSession::~NativeVideoSession() {
  if (pipeline_ == nullptr || output_ == nullptr) {
    return;
  }
  const std::uint64_t stoppedGeneration = pipeline_->stop();
  const NativeVideoPipelineStats pipelineStats = pipeline_->stats();
  const NativeScheduledFrameOutputStats outputStats = output_->stats();
  const std::uint64_t high =
      std::max({stoppedGeneration, pipelineStats.generation,
                outputStats.acceptedGeneration, generation_high_water_});
  const std::uint64_t finalGeneration =
      high == std::numeric_limits<std::uint64_t>::max() ? high : high + 1;
  output_->close(finalGeneration);
}

bool NativeVideoSession::onOwnerThread() const noexcept {
  return owner_thread_ != nullptr && QThread::currentThread() == owner_thread_;
}

bool NativeVideoSession::matches(const Action &action) const noexcept {
  return action.token == token_ && action.serial != 0 &&
         nativeAction(action.kind);
}

NativeVideoSessionDispatch
NativeVideoSession::inertRejected(const Action &action) const noexcept {
  NativeVideoSessionDispatch result;
  result.action = action;
  return result;
}

void NativeVideoSession::latchError(const char *error) noexcept {
  if (error_ || error == nullptr) {
    return;
  }
  try {
    error_ = std::string(error);
  } catch (...) {
  }
}

void NativeVideoSession::latchError(std::string error) noexcept {
  if (error_) {
    return;
  }
  try {
    error_ = std::move(error);
  } catch (...) {
    latchError("native video session failed");
  }
}

NativeVideoSessionDispatch
NativeVideoSession::rejected(const Action &action, const char *error) noexcept {
  latchError(error);
  NativeVideoSessionDispatch result;
  result.action = action;
  return result;
}

NativeVideoSessionDispatch
NativeVideoSession::completed(const Action &action,
                              ActionCompletion completion) noexcept {
  NativeVideoSessionDispatch result;
  result.status = NativeVideoSessionDispatchStatus::Completed;
  result.action = action;
  result.completion = completion;
  last_action_serial_ = std::max(last_action_serial_, action.serial);
  try {
    last_action_ = action;
    last_dispatch_ = result;
  } catch (...) {
    latchError("native video session could not retain action completion");
  }
  return result;
}

NativeVideoSessionDispatch
NativeVideoSession::pending(const Action &action) noexcept {
  NativeVideoSessionDispatch result;
  result.status = NativeVideoSessionDispatchStatus::Pending;
  result.action = action;
  last_action_serial_ = std::max(last_action_serial_, action.serial);
  try {
    last_action_ = action;
    last_dispatch_ = result;
  } catch (...) {
    latchError("native video session could not retain pending action");
  }
  return result;
}

bool NativeVideoSession::outputHealthy(
    const NativeScheduledFrameOutputStats &stats) const noexcept {
  return !stats.closed && stats.fatalErrorSerial == output_fatal_serial_;
}

NativeVideoSessionDispatch
NativeVideoSession::execute(const Action &action) noexcept {
  if (!onOwnerThread()) {
    return rejected(action,
                    "native video session action is off its GUI thread");
  }
  if (!matches(action)) {
    return inertRejected(action);
  }
  if (last_action_ && action.serial == last_action_->serial) {
    if (action == *last_action_ && last_dispatch_) {
      return *last_dispatch_;
    }
    return inertRejected(action);
  }
  if (action.serial <= last_action_serial_) {
    return inertRejected(action);
  }
  if (stopped_) {
    return rejected(action, "native video session is already stopped");
  }
  if (pending_action_ &&
      (action.kind != Action::Kind::StopNative ||
       pending_action_->action.kind == Action::Kind::StopNative)) {
    return inertRejected(action);
  }

  ActionCompletion completion;
  switch (action.kind) {
  case Action::Kind::PrepareNative: {
    if (preparation_pending_ || preparation_outcome_delivered_ ||
        prepared_generation_ != 0) {
      return rejected(action,
                      "native video session preparation is already owned");
    }
    std::string error;
    bool admitted = false;
    try {
      admitted = pipeline_->prepareLocalFileAsync(source_, 0.0, &error);
    } catch (...) {
      error = "native video session preparation threw";
    }
    completion.succeeded = admitted;
    if (!admitted) {
      latchError(error.empty() ? "native video preparation was rejected"
                               : std::move(error));
    } else {
      preparation_pending_ = true;
    }
    return completed(action, completion);
  }

  case Action::Kind::StartNative: {
    if (prepared_generation_ == 0 || action.value != prepared_generation_ ||
        preparation_pending_) {
      completion.succeeded = false;
      return completed(action, completion);
    }
    std::string error;
    const std::optional<std::uint64_t> generation =
        pipeline_->startPrepared(&error);
    if (!generation || *generation == 0 ||
        *generation != prepared_generation_) {
      completion.succeeded = false;
      latchError(error.empty() ? "native video startup was rejected"
                               : std::move(error));
      return completed(action, completion);
    }
    pending_action_ = PendingAction{action, *generation, 0};
    return pending(action);
  }

  case Action::Kind::SeekNative: {
    if (!validTransport(action.transport)) {
      completion.succeeded = false;
      return completed(action, completion);
    }
    const std::optional<std::uint64_t> generation =
        pipeline_->seek(action.transport.position);
    const NativeVideoPipelineStats stats = pipeline_->stats();
    const NativeScheduledFrameOutputStats outputStats = output_->stats();
    if (!generation || *generation == 0 || stats.generation != *generation ||
        outputStats.acceptedGeneration != *generation ||
        !outputHealthy(outputStats)) {
      completion.succeeded = false;
      return completed(action, completion);
    }
    generation_high_water_ = std::max(generation_high_water_, *generation);
    completion.generation = *generation;
    completion.drawBaseline = outputStats.acceptedRenderedFrames;
    // Seeking is always a paused transaction. User intent is restored only
    // after both native and mpv seek convergence are proven.
    pipeline_->updateAudioClock(action.transport.position, true,
                                action.transport.rate);
    return completed(action, completion);
  }

  case Action::Kind::StopNative: {
    preparation_pending_ = false;
    pending_action_.reset();
    const std::uint64_t stoppedGeneration = pipeline_->stop();
    pending_action_ = PendingAction{action, 0, stoppedGeneration};
    return pending(action);
  }

  case Action::Kind::UpdateNativeClock:
    if (!validTransport(action.transport)) {
      completion.succeeded = false;
    } else {
      pipeline_->updateAudioClock(action.transport.position,
                                  action.transport.paused,
                                  action.transport.rate);
    }
    return completed(action, completion);

  default:
    return rejected(action, "native video session action is not native");
  }
}

NativeVideoSessionDispatch NativeVideoSession::reanchor(
    const Action &action, native_activation::Transport authoritative) noexcept {
  if (!onOwnerThread()) {
    return rejected(action,
                    "native video session reanchor is off its GUI thread");
  }
  const bool supported = action.kind == Action::Kind::ForcePauseMpv ||
                         action.kind == Action::Kind::RestoreTransport;
  if (action.token != token_ || action.serial == 0 || !supported) {
    return inertRejected(action);
  }
  if (last_action_ && action.serial == last_action_->serial) {
    if (action == *last_action_ && last_dispatch_) {
      return *last_dispatch_;
    }
    return inertRejected(action);
  }
  if (action.serial <= last_action_serial_) {
    return inertRejected(action);
  }
  if (pending_action_ || stopped_ || !validTransport(authoritative) ||
      (action.kind == Action::Kind::ForcePauseMpv && !authoritative.paused)) {
    ActionCompletion failure;
    failure.succeeded = false;
    return completed(action, failure);
  }
  pipeline_->updateAudioClock(authoritative.position, authoritative.paused,
                              authoritative.rate);
  ActionCompletion completion;
  if (action.kind == Action::Kind::ForcePauseMpv) {
    completion.liveTransport = authoritative;
  }
  return completed(action, std::move(completion));
}

std::optional<NativeVideoSessionEvent>
NativeVideoSession::pollPreparation() noexcept {
  std::optional<NativeVideoPrepareOutcome> outcome =
      pipeline_->takePrepareResult();
  if (!outcome) {
    return std::nullopt;
  }
  if (!preparation_pending_ || stopped_) {
    return std::nullopt;
  }
  preparation_pending_ = false;
  preparation_outcome_delivered_ = true;

  NativeVideoSessionEvent event;
  event.token = token_;
  event.generation = outcome->generation;
  switch (outcome->result) {
  case NativeVideoPrepareResult::Ready:
    if (outcome->generation == 0) {
      event.kind = NativeVideoSessionEventKind::Failed;
      pipeline_failed_ = true;
      latchError("native video preparation returned generation zero");
    } else {
      event.kind = NativeVideoSessionEventKind::Prepared;
      prepared_generation_ = outcome->generation;
      const NativeVideoPipelineStats stats = pipeline_->stats();
      const NativeScheduledFrameOutputStats outputStats = output_->stats();
      generation_high_water_ =
          std::max({generation_high_water_, outcome->generation,
                    stats.generation, outputStats.acceptedGeneration});
    }
    break;
  case NativeVideoPrepareResult::Unsupported:
    event.kind = NativeVideoSessionEventKind::Unsupported;
    latchError(std::move(outcome->error));
    break;
  case NativeVideoPrepareResult::Failed:
    event.kind = NativeVideoSessionEventKind::Failed;
    pipeline_failed_ = true;
    failure_event_delivered_ = true;
    latchError(std::move(outcome->error));
    break;
  }
  return event;
}

std::optional<NativeVideoSessionEvent>
NativeVideoSession::pollStart() noexcept {
  if (!pending_action_ ||
      pending_action_->action.kind != Action::Kind::StartNative) {
    return std::nullopt;
  }
  if (auto error = pipeline_->takeLastError()) {
    pipeline_failed_ = true;
    latchError(std::move(*error));
  }
  const NativeVideoPipelineStats stats = pipeline_->stats();
  const NativeScheduledFrameOutputStats outputStats = output_->stats();
  const bool generationCompatible =
      stats.generation == 0 || stats.generation == pending_action_->generation;
  if (!stats.active && !stats.stopping && stats.prepared && !pipeline_failed_ &&
      generationCompatible && outputHealthy(outputStats) &&
      outputStats.acceptedGeneration == pending_action_->generation) {
    return std::nullopt;
  }

  ActionCompletion completion;
  const bool baselineValid = outputStats.acceptedRenderedFrames >=
                             outputStats.attemptAcceptedRenderedFrames;
  const bool exact =
      stats.active && !stats.stopping &&
      stats.generation == pending_action_->generation &&
      outputStats.acceptedGeneration == pending_action_->generation &&
      outputHealthy(outputStats) && baselineValid && !pipeline_failed_;
  if (exact) {
    completion.generation = pending_action_->generation;
    completion.drawBaseline = outputStats.acceptedRenderedFrames -
                              outputStats.attemptAcceptedRenderedFrames;
    generation_high_water_ =
        std::max(generation_high_water_, completion.generation);
  } else {
    completion.succeeded = false;
    if (!baselineValid) {
      latchError("native video startup render baseline is inconsistent");
    } else if (!outputHealthy(outputStats)) {
      latchError("native video output failed during startup");
    } else if (!pipeline_failed_) {
      latchError("native video startup retired before becoming active");
    }
  }

  const Action action = pending_action_->action;
  pending_action_.reset();
  const NativeVideoSessionDispatch dispatch = completed(action, completion);
  NativeVideoSessionEvent event;
  event.kind = NativeVideoSessionEventKind::ActionCompleted;
  event.token = token_;
  event.action = action;
  event.completion = dispatch.completion;
  return event;
}

std::optional<NativeVideoSessionEvent> NativeVideoSession::pollStop() noexcept {
  if (!pending_action_ ||
      pending_action_->action.kind != Action::Kind::StopNative) {
    return std::nullopt;
  }
  const NativeVideoPipelineStats before = pipeline_->stats();
  if (before.stopping) {
    return std::nullopt;
  }

  ActionCompletion completion;
  const NativeScheduledFrameOutputStats outputBefore = output_->stats();
  const std::uint64_t high =
      std::max({pending_action_->stopGeneration, before.generation,
                outputBefore.acceptedGeneration, generation_high_water_});
  bool valid = !before.active && !before.prepared && before.queueDepth == 0 &&
               outputHealthy(outputBefore) &&
               high != std::numeric_limits<std::uint64_t>::max();
  std::uint64_t fresh = 0;
  if (valid) {
    fresh = high + 1;
    std::string error;
    valid = output_->flush(fresh, &error);
    if (!valid) {
      latchError(error.empty() ? "native video stop invalidation failed"
                               : std::move(error));
    }
  }

  const NativeVideoPipelineStats after = pipeline_->stats();
  const NativeScheduledFrameOutputStats outputAfter = output_->stats();
  valid = valid && !after.stopping && !after.active && !after.prepared &&
          after.queueDepth == 0 && outputHealthy(outputAfter) &&
          outputAfter.acceptedGeneration == fresh;
  if (valid) {
    completion.invalidationGeneration = fresh;
    generation_high_water_ = fresh;
  } else {
    completion.succeeded = false;
    if (high == std::numeric_limits<std::uint64_t>::max()) {
      latchError("native video stop generation is exhausted");
    } else if (!outputHealthy(outputAfter)) {
      latchError("native video output failed during stop");
    } else if (before.active || after.active || before.prepared ||
               after.prepared || before.queueDepth != 0 ||
               after.queueDepth != 0) {
      latchError("native video pipeline did not retire before stop completion");
    } else {
      latchError("native video stop invalidation was not exact");
    }
  }

  const Action action = pending_action_->action;
  pending_action_.reset();
  stopped_ = true;
  const NativeVideoSessionDispatch dispatch = completed(action, completion);
  NativeVideoSessionEvent event;
  event.kind = NativeVideoSessionEventKind::ActionCompleted;
  event.token = token_;
  event.action = action;
  event.completion = dispatch.completion;
  return event;
}

std::optional<NativeVideoSessionEvent> NativeVideoSession::poll() noexcept {
  if (!onOwnerThread()) {
    latchError("native video session poll is off its GUI thread");
    return std::nullopt;
  }
  if (pending_action_ &&
      pending_action_->action.kind == Action::Kind::StopNative) {
    return pollStop();
  }
  if (pending_action_ &&
      pending_action_->action.kind == Action::Kind::StartNative) {
    return pollStart();
  }
  if (std::optional<NativeVideoSessionEvent> event = pollPreparation()) {
    return event;
  }
  if (stopped_) {
    (void)pipeline_->takePrepareResult();
    (void)pipeline_->takeLastError();
    return std::nullopt;
  }
  if (auto error = pipeline_->takeLastError()) {
    pipeline_failed_ = true;
    latchError(std::move(*error));
  }
  const NativeScheduledFrameOutputStats outputStats = output_->stats();
  if (!outputHealthy(outputStats)) {
    pipeline_failed_ = true;
    latchError("native video output became terminal");
  }
  if (!pipeline_failed_ || failure_event_delivered_) {
    return std::nullopt;
  }
  failure_event_delivered_ = true;
  NativeVideoSessionEvent event;
  event.kind = NativeVideoSessionEventKind::Failed;
  event.token = token_;
  event.generation = pipeline_->stats().generation;
  return event;
}

NativeSample NativeVideoSession::sample(Token token) noexcept {
  NativeSample result;
  if (!onOwnerThread() || token != token_) {
    return result;
  }
  if (auto error = pipeline_->takeLastError()) {
    pipeline_failed_ = true;
    latchError(std::move(*error));
  }
  const NativeVideoPipelineStats stats = pipeline_->stats();
  const NativeScheduledFrameOutputStats outputStats = output_->stats();
  result.active = stats.active;
  result.stopping = stats.stopping;
  result.failed = pipeline_failed_ || !outputHealthy(outputStats);
  result.generation = stats.generation;
  result.acceptedGeneration = outputStats.acceptedGeneration;
  result.lastRenderedGeneration = outputStats.lastRenderedGeneration;
  result.acceptedRenderedFrames = outputStats.acceptedRenderedFrames;
  result.attemptAcceptedRenderedFrames =
      outputStats.attemptAcceptedRenderedFrames;
  return result;
}

std::optional<std::string> NativeVideoSession::takeLastError() noexcept {
  std::optional<std::string> result;
  try {
    result = std::move(error_);
    error_.reset();
  } catch (...) {
  }
  return result;
}

} // namespace wam::macos
