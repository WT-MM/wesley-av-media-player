#include "native_video_action_driver.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace wam::macos {
namespace {

using native_activation::Action;
using native_activation::ActionCompletion;
using native_activation::NativeSample;
using native_activation::NativeVideoDriverDispatch;
using native_activation::NativeVideoDriverStatus;
using native_activation::Token;
using native_activation::Transport;

constexpr std::uint64_t kMpvReplyNamespace = 3ULL << 62;
constexpr std::uint64_t kMpvReplyValueMask = (1ULL << 62) - 1ULL;

bool validToken(Token token) noexcept {
  return token.request != 0 && token.attempt != 0;
}

bool validTransport(const Transport &transport) noexcept {
  return std::isfinite(transport.position) && transport.position >= 0.0 &&
         std::isfinite(transport.rate) && transport.rate > 0.0;
}

bool restoredTransportMatches(const Transport &desired,
                              const Transport &actual) noexcept {
  return validTransport(desired) && validTransport(actual) &&
         desired.paused == actual.paused &&
         std::abs(desired.position - actual.position) <= 0.050 &&
         std::abs(desired.rate - actual.rate) <= 1.0e-6;
}

bool validFallbackReason(std::uint64_t value) noexcept {
  switch (value) {
  case static_cast<std::uint64_t>(
      native_activation::FallbackReason::Unsupported):
  case static_cast<std::uint64_t>(
      native_activation::FallbackReason::NativeFailure):
  case static_cast<std::uint64_t>(
      native_activation::FallbackReason::ContextFailure):
  case static_cast<std::uint64_t>(
      native_activation::FallbackReason::SeekFailure):
  case static_cast<std::uint64_t>(native_activation::FallbackReason::Caption):
  case static_cast<std::uint64_t>(
      native_activation::FallbackReason::TrackContract):
  case static_cast<std::uint64_t>(
      native_activation::FallbackReason::PlaylistChange):
  case static_cast<std::uint64_t>(native_activation::FallbackReason::Mismatch):
  case static_cast<std::uint64_t>(
      native_activation::FallbackReason::MpvFailure):
    return true;
  }
  return false;
}

bool nativeSessionAction(Action::Kind kind) noexcept {
  switch (kind) {
  case Action::Kind::PrepareNative:
  case Action::Kind::StartNative:
  case Action::Kind::SeekNative:
  case Action::Kind::UpdateNativeClock:
  case Action::Kind::StopNative:
    return true;
  default:
    return false;
  }
}

NativeVideoDriverDispatch rejected(const Action &action) noexcept {
  NativeVideoDriverDispatch result;
  result.action = action;
  return result;
}

NativeVideoDriverDispatch completed(const Action &action,
                                    ActionCompletion completion = {}) noexcept {
  NativeVideoDriverDispatch result;
  result.status = NativeVideoDriverStatus::Completed;
  result.action = action;
  result.completion = std::move(completion);
  return result;
}

NativeVideoDriverDispatch failed(const Action &action) noexcept {
  ActionCompletion completion;
  completion.succeeded = false;
  return completed(action, std::move(completion));
}

NativeVideoDriverDispatch pending(const Action &action) noexcept {
  NativeVideoDriverDispatch result;
  result.status = NativeVideoDriverStatus::Pending;
  result.action = action;
  return result;
}

bool mpvCommandAction(Action::Kind kind) noexcept {
  switch (kind) {
  case Action::Kind::LoadMpvAudioOnly:
  case Action::Kind::SeekMpvExact:
  case Action::Kind::SelectMpvVideo:
    return true;
  default:
    return false;
  }
}

class BoundaryGuard final {
public:
  explicit BoundaryGuard(bool &active) noexcept : active_(active) {
    active_ = true;
  }
  BoundaryGuard(const BoundaryGuard &) = delete;
  BoundaryGuard &operator=(const BoundaryGuard &) = delete;
  ~BoundaryGuard() { active_ = false; }

private:
  bool &active_;
};

} // namespace

struct MacosNativeVideoActionDriver::Impl {
  std::filesystem::path source;
  std::unique_ptr<AdapterRenderPort> render;
  std::unique_ptr<AdapterMpvPort> mpv;
  std::unique_ptr<AdapterSessionFactory> sessions;
  std::unique_ptr<AdapterSessionPort> session;
  std::optional<Token> token;
  std::optional<Action> flight;
  std::optional<Action> lastAction;
  std::optional<NativeVideoDriverDispatch> lastDispatch;
  std::optional<NativeVideoDriverDispatch> readyDispatch;
  std::optional<AdapterFact> fact;
  std::optional<std::string> error;
  std::uint64_t lastSerial{0};
  std::uint64_t nextReplyValue{1};
  std::uint64_t replyId{0};
  bool rendererDenied{false};
  bool sessionBurned{false};
  bool failedSessionTombstone{false};
  bool stopProofValid{false};
  bool boundaryActive{false};
  bool synchronousReplyWindow{false};
  bool acceptingReply{false};
  bool sampling{false};
  std::uint64_t tombstoneGeneration{0};
  std::uint64_t stopProofGeneration{0};

  void latchError(const char *message) noexcept {
    if (error || message == nullptr) {
      return;
    }
    try {
      error = std::string(message);
    } catch (...) {
    }
  }

  [[nodiscard]] bool onOwnerThread() const noexcept {
    return render != nullptr && render->onOwnerThread();
  }

  [[nodiscard]] bool matches(const Action &action) const noexcept {
    return action.kind != Action::Kind::None && action.serial != 0 &&
           validToken(action.token) && (!token || *token == action.token);
  }

  void bind(const Action &action) noexcept {
    if (!token) {
      token = action.token;
    }
  }

  void cache(const Action &action,
             const NativeVideoDriverDispatch &dispatch) noexcept {
    lastSerial = std::max(lastSerial, action.serial);
    try {
      lastAction = action;
      lastDispatch = dispatch;
    } catch (...) {
      latchError("native action driver could not retain dispatch identity");
    }
  }

  [[nodiscard]] NativeVideoDriverDispatch
  normalize(const Action &action, NativeVideoDriverDispatch dispatch) noexcept {
    if (dispatch.action != action) {
      latchError("native action driver received a mismatched action reply");
      return failed(action);
    }
    switch (dispatch.status) {
    case NativeVideoDriverStatus::Rejected:
    case NativeVideoDriverStatus::Completed:
    case NativeVideoDriverStatus::Pending:
      return dispatch;
    }
    latchError("native action driver received an invalid dispatch status");
    return failed(action);
  }

  [[nodiscard]] NativeVideoDriverDispatch
  finish(const Action &action, NativeVideoDriverDispatch dispatch) noexcept {
    dispatch = normalize(action, std::move(dispatch));
    if (dispatch.status == NativeVideoDriverStatus::Pending) {
      // Session and mpv completions are admitted only against this exact
      // whole-Action owner. Publish it before returning Pending.
      flight = action;
    } else {
      flight.reset();
      replyId = 0;
    }
    cache(action, dispatch);
    return dispatch;
  }

  [[nodiscard]] std::uint64_t allocateReplyId() noexcept {
    if (nextReplyValue == 0 || nextReplyValue > kMpvReplyValueMask) {
      return 0;
    }
    return kMpvReplyNamespace | nextReplyValue++;
  }

  [[nodiscard]] NativeVideoDriverDispatch
  executeMpvCommand(const Action &action) noexcept {
    const std::uint64_t candidateReply = allocateReplyId();
    if (candidateReply == 0) {
      latchError("native action driver exhausted mpv reply identifiers");
      return finish(action, failed(action));
    }

    // Publish the whole Action identity before queueing. mpv may synchronously
    // invoke a deterministic test broker, and a future event drainer may route
    // the reply as soon as mpv_command_async returns.
    flight = action;
    replyId = candidateReply;
    NativeVideoDriverDispatch pendingDispatch = pending(action);
    cache(action, pendingDispatch);

    bool queued = false;
    synchronousReplyWindow = true;
    switch (action.kind) {
    case Action::Kind::LoadMpvAudioOnly:
      queued = mpv->queueLoadAudioOnly(candidateReply, source);
      break;
    case Action::Kind::SeekMpvExact:
      queued = validTransport(action.transport) &&
               mpv->queueSeekExact(candidateReply, action.transport.position);
      break;
    case Action::Kind::SelectMpvVideo:
      queued = action.videoId > 0 &&
               mpv->queueSelectVideo(candidateReply, action.videoId);
      break;
    default:
      break;
    }
    synchronousReplyWindow = false;

    if (!queued) {
      flight.reset();
      replyId = 0;
      readyDispatch.reset();
      latchError("native action driver could not queue an mpv command");
      return finish(action, failed(action));
    }
    if (readyDispatch && readyDispatch->action == action) {
      NativeVideoDriverDispatch result = *readyDispatch;
      readyDispatch.reset();
      return finish(action, std::move(result));
    }
    return pendingDispatch;
  }
};

std::unique_ptr<MacosNativeVideoActionDriver>
MacosNativeVideoActionDriver::create(
    std::filesystem::path source, std::unique_ptr<AdapterRenderPort> render,
    std::unique_ptr<AdapterMpvPort> mpv,
    std::unique_ptr<AdapterSessionFactory> sessions, std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (source.empty() || render == nullptr || mpv == nullptr ||
      sessions == nullptr) {
    if (error != nullptr) {
      *error = "native action driver requires source and all dependency ports";
    }
    return nullptr;
  }
  try {
    auto impl = std::make_unique<Impl>();
    impl->source = std::move(source);
    impl->render = std::move(render);
    impl->mpv = std::move(mpv);
    impl->sessions = std::move(sessions);
    return std::unique_ptr<MacosNativeVideoActionDriver>(
        new MacosNativeVideoActionDriver(std::move(impl)));
  } catch (...) {
    if (error != nullptr) {
      *error = "native action driver allocation failed";
    }
    return nullptr;
  }
}

MacosNativeVideoActionDriver::MacosNativeVideoActionDriver(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MacosNativeVideoActionDriver::~MacosNativeVideoActionDriver() {
  // NativeVideoSession's destructor owns fail-closed stop/output close. Never
  // re-allow libmpv here: only the coordinator's ordered Allow action may do
  // that after an observed Stop completion.
  // NativeVideoSession deliberately owns a thread-independent emergency
  // stop/close destructor even though execute/poll are GUI-thread confined.
  // This also covers an abnormal final adapter release off the owner thread.
  if (impl_) {
    impl_->session.reset();
  }
}

NativeVideoDriverDispatch
MacosNativeVideoActionDriver::execute(const Action &action) noexcept {
  if (!impl_) {
    return rejected(action);
  }
  if (impl_->boundaryActive) {
    impl_->latchError("native action driver suppressed a reentrant mutation");
    return rejected(action);
  }
  BoundaryGuard boundary(impl_->boundaryActive);
  if (!impl_->onOwnerThread()) {
    impl_->latchError("native action driver mutation is off its owner thread");
    return rejected(action);
  }
  if (!impl_->matches(action)) {
    return rejected(action);
  }
  if (impl_->lastAction && action.serial == impl_->lastAction->serial) {
    if (action == *impl_->lastAction && impl_->lastDispatch) {
      return *impl_->lastDispatch;
    }
    return rejected(action);
  }
  if (action.serial <= impl_->lastSerial || impl_->flight) {
    return rejected(action);
  }
  if (impl_->sessionBurned && action.kind != Action::Kind::StopNative &&
      nativeSessionAction(action.kind)) {
    return rejected(action);
  }
  if (impl_->sessionBurned && action.kind == Action::Kind::StopNative &&
      !impl_->session && !impl_->failedSessionTombstone) {
    return rejected(action);
  }
  impl_->bind(action);

  if (nativeSessionAction(action.kind) && !impl_->rendererDenied) {
    impl_->latchError(
        "native session mutation requires prior renderer revocation");
    return impl_->finish(action, failed(action));
  }

  ActionCompletion completion;
  switch (action.kind) {
  case Action::Kind::ForcePauseMpv: {
    const std::optional<Transport> authoritative =
        impl_->mpv->forcePauseAndReadback();
    if (!authoritative || !validTransport(*authoritative) ||
        !authoritative->paused) {
      impl_->latchError("mpv did not confirm an authoritative paused clock");
      return impl_->finish(action, failed(action));
    }
    if (impl_->session) {
      NativeVideoDriverDispatch dispatch = impl_->normalize(
          action, impl_->session->reanchor(action, *authoritative));
      if (dispatch.status != NativeVideoDriverStatus::Completed ||
          !dispatch.completion.succeeded) {
        impl_->latchError(
            "native session did not synchronously accept mpv reanchor");
        return impl_->finish(action, failed(action));
      }
    }
    completion.liveTransport = *authoritative;
    return impl_->finish(action, completed(action, std::move(completion)));
  }

  case Action::Kind::RevokeMpvRenderer: {
    const std::optional<std::uint64_t> generation =
        impl_->render->revokeAndRequestRelease();
    if (!generation || *generation == 0) {
      impl_->latchError(
          "renderer revocation did not provide a lifecycle generation");
      return impl_->finish(action, failed(action));
    }
    impl_->rendererDenied = true;
    impl_->stopProofValid = false;
    impl_->stopProofGeneration = 0;
    completion.preRevokeGeneration = *generation;
    return impl_->finish(action, completed(action, std::move(completion)));
  }

  case Action::Kind::LoadMpvAudioOnly:
  case Action::Kind::SeekMpvExact:
  case Action::Kind::SelectMpvVideo:
    return impl_->executeMpvCommand(action);

  case Action::Kind::PrepareNative: {
    if (!impl_->session) {
      std::string error;
      impl_->session =
          impl_->sessions->create(action.token, impl_->source, &error);
      if (!impl_->session) {
        // No pipeline/output escaped the rejected factory. Keep a quiescent
        // tombstone so the coordinator's mandatory Stop still receives a
        // fresh nonzero invalidation proof before renderer permission returns.
        impl_->failedSessionTombstone = true;
        impl_->sessionBurned = true;
        impl_->stopProofValid = false;
        impl_->latchError(error.empty() ? "native session creation failed"
                                        : error.c_str());
        return impl_->finish(action, failed(action));
      }
    }
    NativeVideoDriverDispatch dispatch = impl_->session->execute(action);
    return impl_->finish(action, std::move(dispatch));
  }

  case Action::Kind::StartNative:
  case Action::Kind::SeekNative:
  case Action::Kind::UpdateNativeClock:
  case Action::Kind::StopNative: {
    if (!impl_->session) {
      if (action.kind == Action::Kind::StopNative &&
          impl_->failedSessionTombstone) {
        impl_->fact.reset();
        impl_->sessionBurned = true;
        impl_->failedSessionTombstone = false;
        impl_->stopProofValid = false;
        if (impl_->tombstoneGeneration ==
            std::numeric_limits<std::uint64_t>::max()) {
          return impl_->finish(action, failed(action));
        }
        completion.invalidationGeneration = ++impl_->tombstoneGeneration;
        impl_->stopProofValid = true;
        impl_->stopProofGeneration = completion.invalidationGeneration;
        return impl_->finish(action, completed(action, std::move(completion)));
      }
      impl_->latchError("native action requires an owned session");
      return impl_->finish(action, failed(action));
    }
    if (action.kind == Action::Kind::StopNative) {
      impl_->fact.reset();
      impl_->sessionBurned = true;
      impl_->stopProofValid = false;
    }
    NativeVideoDriverDispatch dispatch =
        impl_->normalize(action, impl_->session->execute(action));
    if (action.kind == Action::Kind::StopNative) {
      if (dispatch.status == NativeVideoDriverStatus::Pending) {
        return impl_->finish(action, std::move(dispatch));
      }
      impl_->session.reset();
      if (dispatch.status == NativeVideoDriverStatus::Completed &&
          dispatch.completion.succeeded &&
          dispatch.completion.invalidationGeneration != 0) {
        impl_->stopProofValid = true;
        impl_->stopProofGeneration = dispatch.completion.invalidationGeneration;
      } else if (dispatch.status == NativeVideoDriverStatus::Completed &&
                 dispatch.completion.succeeded) {
        impl_->latchError(
            "native Stop completed without a nonzero invalidation proof");
        dispatch = failed(action);
      }
    }
    return impl_->finish(action, std::move(dispatch));
  }

  case Action::Kind::AllowMpvRenderer:
    if (impl_->session || !impl_->rendererDenied || !impl_->stopProofValid ||
        action.value == 0 || action.value != impl_->stopProofGeneration ||
        !impl_->render->allowAndRequestAcquire()) {
      impl_->latchError(
          "renderer allow was attempted without proven native teardown");
      return impl_->finish(action, failed(action));
    }
    impl_->rendererDenied = false;
    impl_->stopProofValid = false;
    impl_->stopProofGeneration = 0;
    return impl_->finish(action, completed(action));

  case Action::Kind::RestoreTransport: {
    const std::optional<Transport> authoritative =
        validTransport(action.transport)
            ? impl_->mpv->restoreAndReadback(action.transport)
            : std::nullopt;
    if (!authoritative ||
        !restoredTransportMatches(action.transport, *authoritative)) {
      impl_->latchError("mpv transport restore readback failed");
      return impl_->finish(action, failed(action));
    }
    if (impl_->session) {
      NativeVideoDriverDispatch dispatch = impl_->normalize(
          action, impl_->session->reanchor(action, *authoritative));
      if (dispatch.status != NativeVideoDriverStatus::Completed ||
          !dispatch.completion.succeeded) {
        impl_->latchError(
            "native session did not synchronously accept mpv restore");
        return impl_->finish(action, failed(action));
      }
    }
    return impl_->finish(action, completed(action));
  }

  case Action::Kind::AttachCaption:
    completion.succeeded =
        action.captionId != 0 && impl_->mpv->attachCaption(action.captionId);
    return impl_->finish(action, completed(action, std::move(completion)));

  case Action::Kind::SurfaceError:
    if (!validFallbackReason(action.value)) {
      impl_->latchError(
          "native action driver rejected an invalid fallback reason");
      return impl_->finish(action, failed(action));
    }
    completion.succeeded = impl_->mpv->surfaceError(
        static_cast<native_activation::FallbackReason>(action.value));
    return impl_->finish(action, completed(action, std::move(completion)));

  case Action::Kind::None:
    break;
  }
  return rejected(action);
}

std::optional<NativeVideoDriverDispatch>
MacosNativeVideoActionDriver::poll() noexcept {
  if (!impl_ || impl_->boundaryActive) {
    return std::nullopt;
  }
  BoundaryGuard boundary(impl_->boundaryActive);
  if (!impl_->onOwnerThread()) {
    return std::nullopt;
  }
  if (impl_->readyDispatch) {
    NativeVideoDriverDispatch result = *impl_->readyDispatch;
    impl_->readyDispatch.reset();
    return impl_->finish(result.action, std::move(result));
  }
  if (!impl_->session) {
    return std::nullopt;
  }

  const bool stopping =
      impl_->flight && impl_->flight->kind == Action::Kind::StopNative;
  if (stopping) {
    // Stop owns the only remaining channel. A retained or newly arriving fact
    // cannot delay teardown acknowledgement.
    impl_->fact.reset();
  } else if (impl_->fact) {
    return std::nullopt;
  }

  constexpr std::uint8_t kMaximumEventsPerPoll = 64;
  for (std::uint8_t drained = 0; drained < kMaximumEventsPerPoll; ++drained) {
    const std::optional<NativeVideoSessionEvent> event = impl_->session->poll();
    if (!event) {
      return std::nullopt;
    }

    if (stopping) {
      switch (event->kind) {
      case NativeVideoSessionEventKind::Prepared:
      case NativeVideoSessionEventKind::Unsupported:
      case NativeVideoSessionEventKind::Failed:
        continue;
      case NativeVideoSessionEventKind::ActionCompleted: {
        const Action stop = *impl_->flight;
        NativeVideoDriverDispatch dispatch = completed(stop, event->completion);
        if (!impl_->token || event->token != *impl_->token ||
            event->action != stop || !dispatch.completion.succeeded ||
            dispatch.completion.invalidationGeneration == 0) {
          impl_->latchError(
              "native Stop returned a malformed terminal completion");
          dispatch = failed(stop);
        } else {
          impl_->stopProofValid = true;
          impl_->stopProofGeneration =
              dispatch.completion.invalidationGeneration;
        }
        impl_->session.reset();
        return impl_->finish(stop, std::move(dispatch));
      }
      }
      const Action stop = *impl_->flight;
      impl_->latchError("native Stop returned an invalid session event kind");
      impl_->session.reset();
      return impl_->finish(stop, failed(stop));
    }

    if (!impl_->token || event->token != *impl_->token) {
      continue;
    }

    switch (event->kind) {
    case NativeVideoSessionEventKind::Prepared:
      if (event->generation == 0) {
        impl_->latchError("native session returned a zero Prepared generation");
        impl_->fact = AdapterFact{AdapterFact::Kind::Failed, event->token, 0};
        return std::nullopt;
      }
      impl_->fact = AdapterFact{AdapterFact::Kind::Prepared, event->token,
                                event->generation};
      return std::nullopt;
    case NativeVideoSessionEventKind::Unsupported:
      impl_->fact =
          AdapterFact{AdapterFact::Kind::Unsupported, event->token, 0};
      return std::nullopt;
    case NativeVideoSessionEventKind::Failed:
      impl_->fact = AdapterFact{AdapterFact::Kind::Failed, event->token, 0};
      return std::nullopt;
    case NativeVideoSessionEventKind::ActionCompleted:
      if (!impl_->flight || event->action != *impl_->flight) {
        continue;
      }
      return impl_->finish(event->action,
                           completed(event->action, event->completion));
    }
    impl_->latchError("native session returned an invalid event kind");
  }
  return std::nullopt;
}

bool MacosNativeVideoActionDriver::acceptMpvCommandReply(std::uint64_t userdata,
                                                         int error) noexcept {
  if (!impl_ || impl_->acceptingReply ||
      (impl_->boundaryActive && !impl_->synchronousReplyWindow) ||
      !ownsMpvCommandReply(userdata) || !impl_->flight ||
      !mpvCommandAction(impl_->flight->kind) || userdata != impl_->replyId ||
      impl_->readyDispatch) {
    return false;
  }
  const bool acquiredBoundary = !impl_->boundaryActive;
  if (acquiredBoundary) {
    impl_->boundaryActive = true;
  }
  impl_->acceptingReply = true;
  const bool previousWindow = impl_->synchronousReplyWindow;
  impl_->synchronousReplyWindow = false;
  if (!impl_->onOwnerThread()) {
    impl_->synchronousReplyWindow = previousWindow;
    impl_->acceptingReply = false;
    if (acquiredBoundary) {
      impl_->boundaryActive = false;
    }
    return false;
  }
  ActionCompletion completion;
  completion.succeeded = error >= 0;
  impl_->readyDispatch = completed(*impl_->flight, std::move(completion));
  impl_->synchronousReplyWindow = previousWindow;
  impl_->acceptingReply = false;
  if (acquiredBoundary) {
    impl_->boundaryActive = false;
  }
  return true;
}

bool MacosNativeVideoActionDriver::ownsMpvCommandReply(
    std::uint64_t userdata) noexcept {
  return (userdata & ~kMpvReplyValueMask) == kMpvReplyNamespace &&
         (userdata & kMpvReplyValueMask) != 0;
}

std::optional<AdapterFact> MacosNativeVideoActionDriver::takeFact() noexcept {
  if (!impl_ || impl_->boundaryActive) {
    return std::nullopt;
  }
  BoundaryGuard boundary(impl_->boundaryActive);
  if (!impl_->onOwnerThread() || !impl_->fact) {
    return std::nullopt;
  }
  std::optional<AdapterFact> result = impl_->fact;
  impl_->fact.reset();
  return result;
}

NativeSample MacosNativeVideoActionDriver::sample(Token token) noexcept {
  if (!impl_ || impl_->boundaryActive || impl_->sampling || !impl_->token ||
      token != *impl_->token || !impl_->session) {
    return {};
  }
  BoundaryGuard boundary(impl_->boundaryActive);
  impl_->sampling = true;
  if (!impl_->onOwnerThread()) {
    impl_->sampling = false;
    return {};
  }
  NativeSample result = impl_->session->sample(token);
  impl_->sampling = false;
  return result;
}

std::optional<std::string>
MacosNativeVideoActionDriver::takeLastError() noexcept {
  if (!impl_ || impl_->boundaryActive) {
    return std::nullopt;
  }
  BoundaryGuard boundary(impl_->boundaryActive);
  if (!impl_->onOwnerThread()) {
    return std::nullopt;
  }
  std::optional<std::string> result = std::move(impl_->error);
  impl_->error.reset();
  return result;
}

} // namespace wam::macos
