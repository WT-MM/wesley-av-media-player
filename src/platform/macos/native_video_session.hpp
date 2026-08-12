#pragma once

#include "native_video_pipeline.hpp"
#include "qt/native_activation_coordinator.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

class QThread;

namespace wam::macos {

class QtGlVideoItem;

// Narrow dependency boundary used by the dormant session executor. The real
// implementation forwards to NativeVideoPipeline; deterministic tests inject
// a bounded fake without starting AVFoundation or VideoToolbox.
class NativeVideoSessionPipeline {
public:
  virtual ~NativeVideoSessionPipeline() = default;

  [[nodiscard]] virtual bool
  prepareLocalFileAsync(const std::filesystem::path &path,
                        double initialPositionSeconds, std::string *error) = 0;
  [[nodiscard]] virtual std::optional<NativeVideoPrepareOutcome>
  takePrepareResult() noexcept = 0;
  [[nodiscard]] virtual std::optional<std::uint64_t>
  startPrepared(std::string *error) noexcept = 0;
  [[nodiscard]] virtual std::uint64_t stop() noexcept = 0;
  virtual void updateAudioClock(double positionSeconds, bool paused,
                                double rate) noexcept = 0;
  [[nodiscard]] virtual std::optional<std::uint64_t>
  seek(double positionSeconds) noexcept = 0;
  [[nodiscard]] virtual std::optional<std::string> takeLastError() noexcept = 0;
  [[nodiscard]] virtual NativeVideoPipelineStats stats() const noexcept = 0;
};

enum class NativeVideoSessionDispatchStatus : std::uint8_t {
  Rejected,
  Completed,
  Pending,
};

struct NativeVideoSessionDispatch {
  NativeVideoSessionDispatchStatus status{
      NativeVideoSessionDispatchStatus::Rejected};
  native_activation::Action action;
  native_activation::ActionCompletion completion;
};

enum class NativeVideoSessionEventKind : std::uint8_t {
  Prepared,
  Unsupported,
  Failed,
  ActionCompleted,
};

struct NativeVideoSessionEvent {
  NativeVideoSessionEventKind kind{NativeVideoSessionEventKind::Failed};
  native_activation::Token token;
  std::uint64_t generation{0};
  native_activation::Action action;
  native_activation::ActionCompletion completion;
};

// One-shot, GUI-owner-thread executor for the dormant native-video path. It is
// absent from default builds and can be production-compiled only by the
// separate activation option. A future controller must create a new session
// for each activation attempt; StopNative burns the session after applying a
// fresh output generation.
class NativeVideoSession final {
public:
  static std::unique_ptr<NativeVideoSession>
  create(QtGlVideoItem *item, native_activation::Token token,
         std::filesystem::path source, std::string *error = nullptr);

#if defined(WAM_NATIVE_VIDEO_SESSION_TESTING)
  static std::unique_ptr<NativeVideoSession>
  createForTesting(native_activation::Token token, std::filesystem::path source,
                   std::shared_ptr<NativeScheduledFrameOutput> output,
                   std::unique_ptr<NativeVideoSessionPipeline> pipeline,
                   QThread *ownerThread, std::string *error = nullptr);
#endif

  NativeVideoSession(const NativeVideoSession &) = delete;
  NativeVideoSession &operator=(const NativeVideoSession &) = delete;
  ~NativeVideoSession();

  // These methods are GUI-owner-thread confined and never wait for decode,
  // preparation, presentation, or retirement work. Repeating the exact same
  // pending/completed action is idempotent; stale token/serial input is inert.
  [[nodiscard]] NativeVideoSessionDispatch
  execute(const native_activation::Action &action) noexcept;
  // The controller still owns the synchronous mpv mutation. Once it has an
  // authoritative live readback, this exact-token/serial companion mutation
  // re-anchors the native scheduler before the coordinator action completes.
  [[nodiscard]] NativeVideoSessionDispatch
  reanchor(const native_activation::Action &action,
           native_activation::Transport authoritative) noexcept;
  [[nodiscard]] std::optional<NativeVideoSessionEvent> poll() noexcept;
  [[nodiscard]] native_activation::NativeSample
  sample(native_activation::Token token) noexcept;
  [[nodiscard]] std::optional<std::string> takeLastError() noexcept;

private:
  struct PendingAction {
    native_activation::Action action;
    std::uint64_t generation{0};
    std::uint64_t stopGeneration{0};
  };

  NativeVideoSession(native_activation::Token token,
                     std::filesystem::path source,
                     std::shared_ptr<NativeScheduledFrameOutput> output,
                     std::unique_ptr<NativeVideoSessionPipeline> pipeline,
                     QThread *ownerThread) noexcept;

  [[nodiscard]] bool onOwnerThread() const noexcept;
  [[nodiscard]] bool
  matches(const native_activation::Action &action) const noexcept;
  [[nodiscard]] NativeVideoSessionDispatch
  inertRejected(const native_activation::Action &action) const noexcept;
  [[nodiscard]] NativeVideoSessionDispatch
  rejected(const native_activation::Action &action, const char *error) noexcept;
  [[nodiscard]] NativeVideoSessionDispatch
  completed(const native_activation::Action &action,
            native_activation::ActionCompletion completion) noexcept;
  [[nodiscard]] NativeVideoSessionDispatch
  pending(const native_activation::Action &action) noexcept;
  [[nodiscard]] std::optional<NativeVideoSessionEvent>
  pollPreparation() noexcept;
  [[nodiscard]] std::optional<NativeVideoSessionEvent> pollStart() noexcept;
  [[nodiscard]] std::optional<NativeVideoSessionEvent> pollStop() noexcept;
  [[nodiscard]] bool
  outputHealthy(const NativeScheduledFrameOutputStats &stats) const noexcept;
  void latchError(const char *error) noexcept;
  void latchError(std::string error) noexcept;

  native_activation::Token token_;
  std::filesystem::path source_;
  std::shared_ptr<NativeScheduledFrameOutput> output_;
  std::unique_ptr<NativeVideoSessionPipeline> pipeline_;
  QThread *owner_thread_{nullptr};
  std::uint64_t output_fatal_serial_{0};
  std::uint64_t generation_high_water_{0};
  std::uint64_t last_action_serial_{0};
  std::uint64_t prepared_generation_{0};
  bool preparation_pending_{false};
  bool preparation_outcome_delivered_{false};
  bool stopped_{false};
  bool pipeline_failed_{false};
  bool failure_event_delivered_{false};
  std::optional<PendingAction> pending_action_;
  std::optional<native_activation::Action> last_action_;
  std::optional<NativeVideoSessionDispatch> last_dispatch_;
  std::optional<std::string> error_;
};

} // namespace wam::macos
