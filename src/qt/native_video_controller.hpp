#pragma once

#include "native_activation_coordinator.hpp"

#include <cstdint>
#include <memory>
#include <optional>

namespace wam::native_activation {

enum class NativeVideoDriverStatus : std::uint8_t {
  Rejected,
  Completed,
  Pending,
};

struct NativeVideoDriverDispatch {
  NativeVideoDriverStatus status{NativeVideoDriverStatus::Rejected};
  Action action;
  ActionCompletion completion;
};

// Platform and media-engine mutations stay behind this injected boundary. A
// production adapter may combine PlayerCore, libmpv, and NativeVideoSession;
// this runner itself remains independent of Qt and Apple frameworks.
class NativeVideoActionDriver {
public:
  virtual ~NativeVideoActionDriver() = default;
  [[nodiscard]] virtual NativeVideoDriverDispatch
  execute(const Action &action) noexcept = 0;
  [[nodiscard]] virtual std::optional<NativeVideoDriverDispatch>
  poll() noexcept = 0;
};

// Capacity-one coordinator action runner. It is inert unless explicitly
// enabled and begun; merely constructing it performs no driver work.
class NativeVideoController final {
public:
  struct DeadlinePolicy {
    std::uint64_t actionTicks{5000};
    std::uint64_t actionlessPhaseTicks{5000};
    std::uint8_t maximumSynchronousActions{16};
  };

  explicit NativeVideoController(
      std::unique_ptr<NativeVideoActionDriver> driver,
      bool enabled = false) noexcept;
  NativeVideoController(std::unique_ptr<NativeVideoActionDriver> driver,
                        bool enabled, DeadlinePolicy deadlines) noexcept;

  NativeVideoController(const NativeVideoController &) = delete;
  NativeVideoController &operator=(const NativeVideoController &) = delete;
  ~NativeVideoController() = default;

  [[nodiscard]] std::optional<Token> begin(std::uint64_t request,
                                           std::uint64_t sourceKey,
                                           Transport desired) noexcept;
  [[nodiscard]] Action cancel(CancelMode mode) noexcept;

  [[nodiscard]] bool pump() noexcept;
  [[nodiscard]] bool poll() noexcept;
  // `now` is an arbitrary caller-owned monotonic tick domain. A decreasing
  // value is ignored. An action timeout records terminal/fallback intent but
  // never fabricates completion or releases the exact issued serial.
  [[nodiscard]] bool tick(std::uint64_t now) noexcept;

  // Async facts are deliberately explicit. Each call first exact-matches the
  // current Token inside NativeActivationCoordinator, then pumps at most the
  // resulting capacity-one mutation chain.
  void nativePrepared(Token token, std::uint64_t generation) noexcept;
  void nativeUnsupported(Token token) noexcept;
  void nativeFailed(Token token) noexcept;
  void mpvLoadFailed(Token token) noexcept;
  void mpvEndFileError(Token token, std::int64_t entry) noexcept;
  void mpvReady(Token token, MpvReady ready) noexcept;
  void evaluateRelease(Token token, bool renderAllowed, bool renderBusy,
                       bool lifecycleEmpty,
                       std::uint64_t lifecycleGeneration) noexcept;
  void sampleNative(Token token, NativeSample sample) noexcept;
  void setDesiredPause(Token token, bool paused) noexcept;
  void setDesiredRate(Token token, double rate) noexcept;
  void observeLiveTransport(Token token, std::uint64_t epoch,
                            std::int64_t entry, Transport live) noexcept;
  void requestSeek(Token token, double target) noexcept;
  void playbackRestart(Token token, std::uint64_t epoch, std::int64_t entry,
                       double livePosition) noexcept;
  void requestCaption(Token token, std::uint64_t captionId) noexcept;
  void eof(Token token, std::int64_t entry, double finalPosition) noexcept;
  void beginFallback(Token token, FallbackReason reason) noexcept;
  void fail(Token token, FallbackReason reason) noexcept;
  void fallbackRenderReady(Token token, std::uint64_t renderStamp) noexcept;
  void fallbackRendererInvalidated(Token token,
                                   std::uint64_t retiredStamp) noexcept;
  void fallbackPlaybackRestart(Token token, std::uint64_t renderStamp,
                               std::int64_t entry,
                               double livePosition) noexcept;
  [[nodiscard]] bool
  consumeExpectedRevocationGeneration(std::uint64_t retiredGeneration) noexcept;

  [[nodiscard]] Snapshot snapshot() const noexcept;
  [[nodiscard]] std::optional<Action> issuedAction() const noexcept {
    return issued_action_;
  }
  [[nodiscard]] bool deadlineLatched() const noexcept {
    return deadline_latched_;
  }
  [[nodiscard]] bool drainLimitLatched() const noexcept {
    return drain_limit_latched_;
  }

private:
  void accept(Action action, const Snapshot &before) noexcept;
  void noteProgress() noexcept;
  [[nodiscard]] static bool progressChanged(const Snapshot &before,
                                            const Snapshot &after) noexcept;
  [[nodiscard]] static FallbackReason
  timeoutReason(const Snapshot &state,
                const std::optional<Action> &issued) noexcept;
  [[nodiscard]] bool
  applyDispatch(const NativeVideoDriverDispatch &dispatch) noexcept;

  std::unique_ptr<NativeVideoActionDriver> driver_;
  NativeActivationCoordinator coordinator_;
  std::optional<Action> issued_action_;
  DeadlinePolicy deadlines_;
  std::uint64_t last_tick_{0};
  std::uint64_t last_progress_tick_{0};
  std::uint64_t issued_tick_{0};
  std::uint64_t timed_out_action_serial_{0};
  bool enabled_{false};
  bool clock_initialized_{false};
  bool draining_{false};
  bool deadline_latched_{false};
  bool drain_limit_latched_{false};
};

} // namespace wam::native_activation
