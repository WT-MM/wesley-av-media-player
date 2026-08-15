#include "native_video_production_ports.hpp"

#include "qt_gl_video_item.hpp"
#include "native_video_session.hpp"
#include "qt/mpv_video_item.hpp"
#include "qt/player_core_p.hpp"
#include "qt/render_lifecycle.hpp"

#include <QPointer>
#include <QThread>

#include <cstdint>
#include <filesystem>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>

namespace wam::macos {
namespace {

using native_activation::Action;
using native_activation::NativeSample;
using native_activation::NativeVideoDriverDispatch;
using native_activation::NativeVideoDriverStatus;
using native_activation::Token;
using native_activation::Transport;

bool validToken(Token token) noexcept {
  return token.request != 0 && token.attempt != 0;
}

NativeVideoDriverDispatch rejected(const Action &action) noexcept {
  NativeVideoDriverDispatch result;
  result.action = action;
  return result;
}

bool translateStatus(NativeVideoSessionDispatchStatus source,
                     NativeVideoDriverStatus *target) noexcept {
  if (target == nullptr) {
    return false;
  }
  switch (source) {
  case NativeVideoSessionDispatchStatus::Rejected:
    *target = NativeVideoDriverStatus::Rejected;
    return true;
  case NativeVideoSessionDispatchStatus::Completed:
    *target = NativeVideoDriverStatus::Completed;
    return true;
  case NativeVideoSessionDispatchStatus::Pending:
    *target = NativeVideoDriverStatus::Pending;
    return true;
  }
  return false;
}

NativeVideoDriverDispatch
translateDispatch(const Action &expected,
                  const NativeVideoSessionDispatch &source,
                  bool *exact) noexcept {
  if (exact != nullptr) {
    *exact = false;
  }
  if (source.action != expected) {
    return rejected(expected);
  }
  NativeVideoDriverDispatch result;
  if (!translateStatus(source.status, &result.status)) {
    return rejected(expected);
  }
  result.action = source.action;
  result.completion = source.completion;
  if (exact != nullptr) {
    *exact = true;
  }
  return result;
}

class RenderPort final : public AdapterRenderPort {
public:
  struct Operations final {
    std::function<bool()> onOwnerThread;
    std::function<std::optional<std::uint64_t>()> snapshotLifecycleGeneration;
    std::function<bool()> revokeRenderContext;
    std::function<bool()> allowRenderContext;
    std::function<bool()> requestVideoUpdate;
  };

  explicit RenderPort(Operations operations) noexcept
      : operations_(std::move(operations)) {}

  bool onOwnerThread() const noexcept override {
    if (!operations_.onOwnerThread) {
      return false;
    }
    try {
      return operations_.onOwnerThread();
    } catch (...) {
      return false;
    }
  }

  std::optional<std::uint64_t>
  revokeAndRequestRelease() noexcept override {
    if (!onOwnerThread() || !operations_.snapshotLifecycleGeneration ||
        !operations_.revokeRenderContext ||
        !operations_.requestVideoUpdate) {
      return std::nullopt;
    }

    std::optional<std::uint64_t> generation;
    try {
      generation = operations_.snapshotLifecycleGeneration();
    } catch (...) {
      return std::nullopt;
    }
    if (!generation || *generation == 0) {
      return std::nullopt;
    }
    try {
      if (!operations_.revokeRenderContext()) {
        return std::nullopt;
      }
      if (!operations_.requestVideoUpdate()) {
        return std::nullopt;
      }
    } catch (...) {
      return std::nullopt;
    }
    return generation;
  }

  bool allowAndRequestAcquire() noexcept override {
    if (!onOwnerThread() || !operations_.allowRenderContext ||
        !operations_.requestVideoUpdate) {
      return false;
    }
    try {
      if (!operations_.allowRenderContext()) {
        return false;
      }
      return operations_.requestVideoUpdate();
    } catch (...) {
      return false;
    }
  }

private:
  Operations operations_;
};

class SessionPort final : public AdapterSessionPort {
public:
  struct Operations final {
    std::function<bool()> onOwnerThread;
    std::function<bool()> outputAlive;
    std::function<NativeVideoSessionDispatch(const Action &)> execute;
    std::function<NativeVideoSessionDispatch(const Action &, Transport)>
        reanchor;
    std::function<std::optional<NativeVideoSessionEvent>()> poll;
    std::function<NativeSample(Token)> sample;
  };

  SessionPort(Token token, Operations operations) noexcept
      : token_(token), operations_(std::move(operations)) {}

  NativeVideoDriverDispatch execute(const Action &action) noexcept override {
    if (action.token != token_ || action.serial == 0 || !admit() || burned_ ||
        !operations_.execute) {
      return rejected(action);
    }

    NativeVideoSessionDispatch source;
    try {
      source = operations_.execute(action);
    } catch (...) {
      return burnAndReject(action);
    }
    bool exact = false;
    NativeVideoDriverDispatch result =
        translateDispatch(action, source, &exact);
    if (!exact) {
      burned_ = true;
    }
    if (action.kind == Action::Kind::StopNative) {
      if (result.status != NativeVideoDriverStatus::Rejected) {
        stopAction_ = action;
      }
      if (result.status == NativeVideoDriverStatus::Completed) {
        burned_ = true;
      }
    }
    return result;
  }

  NativeVideoDriverDispatch
  reanchor(const Action &action, Transport authoritative) noexcept override {
    if (action.token != token_ || action.serial == 0 || !admit() || burned_ ||
        !operations_.reanchor) {
      return rejected(action);
    }
    NativeVideoSessionDispatch source;
    try {
      source = operations_.reanchor(action, authoritative);
    } catch (...) {
      return burnAndReject(action);
    }
    bool exact = false;
    NativeVideoDriverDispatch result =
        translateDispatch(action, source, &exact);
    if (!exact) {
      burned_ = true;
    }
    return result;
  }

  std::optional<NativeVideoSessionEvent> poll() noexcept override {
    if (!admit() || burned_ || !operations_.poll) {
      return std::nullopt;
    }
    std::optional<NativeVideoSessionEvent> event;
    try {
      event = operations_.poll();
    } catch (...) {
      burned_ = true;
      return std::nullopt;
    }
    if (!event) {
      return std::nullopt;
    }
    if (event->token != token_) {
      burned_ = true;
      return std::nullopt;
    }
    switch (event->kind) {
    case NativeVideoSessionEventKind::Prepared:
      if (event->generation == 0) {
        burned_ = true;
        return std::nullopt;
      }
      break;
    case NativeVideoSessionEventKind::Unsupported:
    case NativeVideoSessionEventKind::Failed:
      break;
    case NativeVideoSessionEventKind::ActionCompleted:
      if (event->action.kind == Action::Kind::None ||
          event->action.serial == 0 || event->action.token != token_ ||
          (stopAction_ && event->action != *stopAction_)) {
        burned_ = true;
        return std::nullopt;
      }
      if (stopAction_ && event->action.kind == Action::Kind::StopNative) {
        burned_ = true;
      }
      break;
    default:
      burned_ = true;
      return std::nullopt;
    }
    return event;
  }

  NativeSample sample(Token token) noexcept override {
    if (token != token_ || !admit() || burned_ || !operations_.sample) {
      return {};
    }
    try {
      return operations_.sample(token);
    } catch (...) {
      burned_ = true;
      return {};
    }
  }

private:
  bool admit() noexcept {
    if (!operations_.onOwnerThread || !operations_.outputAlive) {
      burned_ = true;
      return false;
    }
    try {
      if (!operations_.onOwnerThread()) {
        return false;
      }
      if (!operations_.outputAlive()) {
        burned_ = true;
        return false;
      }
      return true;
    } catch (...) {
      burned_ = true;
      return false;
    }
  }

  NativeVideoDriverDispatch burnAndReject(const Action &action) noexcept {
    burned_ = true;
    return rejected(action);
  }

  Token token_;
  Operations operations_;
  std::optional<Action> stopAction_;
  bool burned_{false};
};

class SessionFactory final : public AdapterSessionFactory {
public:
  struct Operations final {
    std::function<bool()> onOwnerThread;
    std::function<bool()> outputAlive;
    std::function<std::optional<SessionPort::Operations>(
        Token, const std::filesystem::path &, std::string *)>
        create;
  };

  explicit SessionFactory(Operations operations) noexcept
      : operations_(std::move(operations)) {}

  std::unique_ptr<AdapterSessionPort>
  create(Token token, const std::filesystem::path &source,
         std::string *error) noexcept override {
    if (error != nullptr) {
      error->clear();
    }
    if (used_ || !validToken(token) || source.empty() ||
        !operations_.onOwnerThread || !operations_.outputAlive ||
        !operations_.create) {
      setError(error, "native session factory rejected invalid input");
      return nullptr;
    }
    used_ = true;

    try {
      if (!operations_.onOwnerThread()) {
        setError(error, "native session factory is off its GUI thread");
        return nullptr;
      }
      if (!operations_.outputAlive()) {
        setError(error, "native session factory output is unavailable");
        return nullptr;
      }
      std::optional<SessionPort::Operations> session =
          operations_.create(token, source, error);
      if (!session || !session->onOwnerThread || !session->outputAlive ||
          !session->execute || !session->reanchor || !session->poll ||
          !session->sample) {
        setError(error, "native session factory creation failed");
        return nullptr;
      }
      return std::make_unique<SessionPort>(token, std::move(*session));
    } catch (...) {
      setError(error, "native session factory creation threw");
      return nullptr;
    }
  }

private:
  static void setError(std::string *error, const char *message) noexcept {
    if (error == nullptr || !error->empty() || message == nullptr) {
      return;
    }
    try {
      *error = message;
    } catch (...) {
    }
  }

  Operations operations_;
  bool used_{false};
};

std::unique_ptr<AdapterRenderPort>
makeRenderPort(RenderPort::Operations operations,
               std::string *error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (!operations.onOwnerThread ||
      !operations.snapshotLifecycleGeneration ||
      !operations.revokeRenderContext || !operations.allowRenderContext ||
      !operations.requestVideoUpdate) {
    if (error != nullptr) {
      try {
        *error = "native render port requires every operation";
      } catch (...) {
      }
    }
    return nullptr;
  }
  try {
    return std::make_unique<RenderPort>(std::move(operations));
  } catch (...) {
    if (error != nullptr) {
      try {
        *error = "native render port allocation failed";
      } catch (...) {
      }
    }
    return nullptr;
  }
}

std::unique_ptr<AdapterSessionFactory>
makeSessionFactory(SessionFactory::Operations operations,
                   std::string *error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (!operations.onOwnerThread || !operations.outputAlive ||
      !operations.create) {
    if (error != nullptr) {
      try {
        *error = "native session factory requires every operation";
      } catch (...) {
      }
    }
    return nullptr;
  }
  try {
    return std::make_unique<SessionFactory>(std::move(operations));
  } catch (...) {
    if (error != nullptr) {
      try {
        *error = "native session factory allocation failed";
      } catch (...) {
      }
    }
    return nullptr;
  }
}

SessionPort::Operations
sessionOperations(std::shared_ptr<NativeVideoSession> session,
                  QPointer<QtGlVideoItem> output) {
  SessionPort::Operations operations;
  operations.onOwnerThread = [output] {
    return output && output->thread() == QThread::currentThread();
  };
  operations.outputAlive = [output] { return !output.isNull(); };
  operations.execute = [session](const Action &action) {
    return session->execute(action);
  };
  operations.reanchor = [session](const Action &action,
                                  Transport authoritative) {
    return session->reanchor(action, authoritative);
  };
  operations.poll = [session] { return session->poll(); };
  operations.sample = [session](Token token) { return session->sample(token); };
  return operations;
}

struct ProductionRenderBindings final {
  explicit ProductionRenderBindings(std::weak_ptr<qt::PlayerCore> value,
                                    qt::MpvVideoItem *videoItem) noexcept
      : core(std::move(value)), output(videoItem) {}

  std::optional<std::uint64_t> snapshot() noexcept {
    revokeCore.reset();
    revokeCore = core.lock();
    if (!revokeCore) {
      return std::nullopt;
    }
    const qt::RenderTicket ticket = revokeCore->renderLifecycleSnapshot();
    const std::uint64_t generation = qt::RenderLifecycle::generation(ticket);
    if (generation == 0) {
      revokeCore.reset();
      return std::nullopt;
    }
    return generation;
  }

  bool revoke() noexcept {
    std::shared_ptr<qt::PlayerCore> strong = std::move(revokeCore);
    if (!strong) {
      return false;
    }
    strong->revokeRenderContext();
    return true;
  }

  std::weak_ptr<qt::PlayerCore> core;
  QPointer<qt::MpvVideoItem> output;
  // Retain the exact core from the single lifecycle snapshot through revoke.
  std::shared_ptr<qt::PlayerCore> revokeCore;
};

} // namespace

std::unique_ptr<AdapterRenderPort>
createNativeVideoRenderPort(std::weak_ptr<qt::PlayerCore> core,
                            qt::MpvVideoItem *item,
                            std::string *error) noexcept {
  if (item == nullptr || core.expired()) {
    if (error != nullptr) {
      try {
        *error = "native render port requires a live core and video item";
      } catch (...) {
      }
    }
    return nullptr;
  }
  std::shared_ptr<ProductionRenderBindings> bindings;
  try {
    bindings =
        std::make_shared<ProductionRenderBindings>(std::move(core), item);
  } catch (...) {
    if (error != nullptr) {
      try {
        *error = "native render port allocation failed";
      } catch (...) {
      }
    }
    return nullptr;
  }
  RenderPort::Operations operations;
  operations.onOwnerThread = [bindings] {
    return bindings->output &&
           bindings->output->thread() == QThread::currentThread();
  };
  operations.snapshotLifecycleGeneration = [bindings] {
    return bindings->snapshot();
  };
  operations.revokeRenderContext = [bindings] { return bindings->revoke(); };
  operations.allowRenderContext = [bindings] {
    std::shared_ptr<qt::PlayerCore> strong = bindings->core.lock();
    if (!strong) {
      return false;
    }
    strong->allowRenderContext();
    return true;
  };
  operations.requestVideoUpdate = [bindings] {
    if (!bindings->output) {
      return false;
    }
    bindings->output->update();
    return true;
  };
  return makeRenderPort(std::move(operations), error);
}

std::unique_ptr<AdapterSessionFactory>
createNativeVideoSessionFactory(QtGlVideoItem *item,
                                std::string *error) noexcept {
  if (item == nullptr) {
    if (error != nullptr) {
      try {
        *error = "native session factory requires a video item";
      } catch (...) {
      }
    }
    return nullptr;
  }
  const QPointer<QtGlVideoItem> output(item);
  SessionFactory::Operations operations;
  operations.onOwnerThread = [output] {
    return output && output->thread() == QThread::currentThread();
  };
  operations.outputAlive = [output] { return !output.isNull(); };
  operations.create = [output](Token token, const std::filesystem::path &source,
                               std::string *creationError)
      -> std::optional<SessionPort::Operations> {
    if (!output || output->thread() != QThread::currentThread()) {
      return std::nullopt;
    }
    std::unique_ptr<NativeVideoSession> owned =
        NativeVideoSession::create(output.data(), token, source, creationError);
    if (!owned) {
      return std::nullopt;
    }
    std::shared_ptr<NativeVideoSession> session(std::move(owned));
    return sessionOperations(std::move(session), output);
  };
  return makeSessionFactory(std::move(operations), error);
}

#if defined(WAM_NATIVE_VIDEO_PRODUCTION_PORTS_TESTING)

std::unique_ptr<AdapterRenderPort> createNativeVideoRenderPortForTesting(
    NativeVideoRenderPortTestFunctions functions,
    std::string *error) noexcept {
  RenderPort::Operations operations;
  operations.onOwnerThread = std::move(functions.onOwnerThread);
  operations.snapshotLifecycleGeneration =
      std::move(functions.snapshotLifecycleGeneration);
  operations.revokeRenderContext =
      std::move(functions.revokeRenderContext);
  operations.allowRenderContext = std::move(functions.allowRenderContext);
  operations.requestVideoUpdate = std::move(functions.requestVideoUpdate);
  return makeRenderPort(std::move(operations), error);
}

std::unique_ptr<AdapterSessionFactory>
createNativeVideoSessionFactoryForTesting(
    NativeVideoSessionFactoryTestFunctions functions,
    std::string *error) noexcept {
  SessionFactory::Operations operations;
  operations.onOwnerThread = std::move(functions.onOwnerThread);
  operations.outputAlive = std::move(functions.outputAlive);
  operations.create =
      [create = std::move(functions.create)](
          Token token, const std::filesystem::path &source,
          std::string *creationError)
      -> std::optional<SessionPort::Operations> {
    if (!create) {
      return std::nullopt;
    }
    std::optional<NativeVideoSessionPortTestFunctions> test =
        create(token, source, creationError);
    if (!test) {
      return std::nullopt;
    }
    SessionPort::Operations session;
    session.onOwnerThread = std::move(test->onOwnerThread);
    session.outputAlive = std::move(test->outputAlive);
    session.execute = std::move(test->execute);
    session.reanchor = std::move(test->reanchor);
    session.poll = std::move(test->poll);
    session.sample = std::move(test->sample);
    return session;
  };
  return makeSessionFactory(std::move(operations), error);
}

#endif

} // namespace wam::macos
