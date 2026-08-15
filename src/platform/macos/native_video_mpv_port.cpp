#include "native_video_mpv_port.hpp"

#include "mpv_command_reply_namespace.hpp"
#include "playback/mpv/mpv_runtime.hpp"

#include <QThread>

#include <mpv/client.h>

#include <charconv>
#include <cmath>
#include <cstdio>
#include <locale.h>
#include <limits>
#include <new>
#include <string>
#include <system_error>
#include <utility>

namespace wam::macos {

struct NativeVideoMpvProductionContext final {
  std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime;
  mpv_handle *handle{nullptr};
};

namespace {

using native_activation::FallbackReason;
using native_activation::Transport;

class ActiveCall final {
public:
  explicit ActiveCall(bool &active) noexcept : active_(active) {
    active_ = true;
  }
  ActiveCall(const ActiveCall &) = delete;
  ActiveCall &operator=(const ActiveCall &) = delete;
  ~ActiveCall() { active_ = false; }

private:
  bool &active_;
};

class NumericLocaleScope final {
public:
  NumericLocaleScope() noexcept
      : numeric_(newlocale(LC_NUMERIC_MASK, "C", nullptr)) {
    if (numeric_ != nullptr) {
      previous_ = uselocale(numeric_);
    }
  }
  NumericLocaleScope(const NumericLocaleScope &) = delete;
  NumericLocaleScope &operator=(const NumericLocaleScope &) = delete;
  ~NumericLocaleScope() {
    if (previous_ != nullptr) {
      static_cast<void>(uselocale(previous_));
    }
    if (numeric_ != nullptr) {
      freelocale(numeric_);
    }
  }
  [[nodiscard]] bool active() const noexcept {
    return numeric_ != nullptr && previous_ != nullptr;
  }

private:
  locale_t numeric_{nullptr};
  locale_t previous_{nullptr};
};

[[nodiscard]] bool validTransport(const Transport &transport) noexcept {
  return std::isfinite(transport.position) && transport.position >= 0.0 &&
         std::isfinite(transport.rate) && transport.rate > 0.0;
}

[[nodiscard]] bool validFallbackReason(FallbackReason reason) noexcept {
  switch (reason) {
  case FallbackReason::Unsupported:
  case FallbackReason::NativeFailure:
  case FallbackReason::ContextFailure:
  case FallbackReason::SeekFailure:
  case FallbackReason::Caption:
  case FallbackReason::TrackContract:
  case FallbackReason::PlaylistChange:
  case FallbackReason::Mismatch:
  case FallbackReason::MpvFailure:
    return true;
  }
  return false;
}

[[nodiscard]] mpv_format
mpvFormat(NativeVideoMpvValueKind kind) noexcept {
  switch (kind) {
  case NativeVideoMpvValueKind::Double:
    return MPV_FORMAT_DOUBLE;
  case NativeVideoMpvValueKind::Flag:
    return MPV_FORMAT_FLAG;
  case NativeVideoMpvValueKind::Int64:
    return MPV_FORMAT_INT64;
  }
  return MPV_FORMAT_NONE;
}

int getMpvProperty(void *context, const char *name,
                   NativeVideoMpvValueKind kind, void *value) noexcept {
  if (context == nullptr || name == nullptr || value == nullptr) {
    return MPV_ERROR_INVALID_PARAMETER;
  }
  const mpv_format format = mpvFormat(kind);
  if (format == MPV_FORMAT_NONE) {
    return MPV_ERROR_INVALID_PARAMETER;
  }
  auto *production =
      static_cast<NativeVideoMpvProductionContext *>(context);
  if (!production->runtime || !production->handle) {
    return MPV_ERROR_INVALID_PARAMETER;
  }
  return production->runtime->api().mpv_get_property(
      production->handle, name, format, value);
}

int setMpvProperty(void *context, const char *name,
                   NativeVideoMpvValueKind kind, void *value) noexcept {
  if (context == nullptr || name == nullptr || value == nullptr) {
    return MPV_ERROR_INVALID_PARAMETER;
  }
  const mpv_format format = mpvFormat(kind);
  if (format == MPV_FORMAT_NONE) {
    return MPV_ERROR_INVALID_PARAMETER;
  }
  auto *production =
      static_cast<NativeVideoMpvProductionContext *>(context);
  if (!production->runtime || !production->handle) {
    return MPV_ERROR_INVALID_PARAMETER;
  }
  return production->runtime->api().mpv_set_property(
      production->handle, name, format, value);
}

int queueMpvCommand(void *context, std::uint64_t replyUserdata,
                    const char **arguments) noexcept {
  if (context == nullptr || arguments == nullptr || arguments[0] == nullptr) {
    return MPV_ERROR_INVALID_PARAMETER;
  }
  auto *production =
      static_cast<NativeVideoMpvProductionContext *>(context);
  if (!production->runtime || !production->handle) {
    return MPV_ERROR_INVALID_PARAMETER;
  }
  return production->runtime->api().mpv_command_async(
      production->handle, replyUserdata, arguments);
}

void setCreationError(std::string *error, const char *message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
    // Diagnostics are best-effort at this noexcept allocation boundary.
  }
}

[[nodiscard]] bool validCalls(const NativeVideoMpvCallSeam &calls) noexcept {
  return calls.getProperty != nullptr && calls.setProperty != nullptr &&
         calls.commandAsync != nullptr;
}

template <typename Number>
[[nodiscard]] bool formatInteger(Number value, char *begin,
                                 char *end) noexcept {
  const auto converted = std::to_chars(begin, end - 1, value);
  if (converted.ec != std::errc{} || converted.ptr >= end) {
    return false;
  }
  *converted.ptr = '\0';
  return true;
}

[[nodiscard]] bool formatDouble(double value, char *begin,
                                char *end) noexcept {
  if (!std::isfinite(value) || begin == nullptr || end == nullptr ||
      begin >= end) {
    return false;
  }
  if (value == 0.0) {
    value = 0.0;
  }
  const std::size_t capacity = static_cast<std::size_t>(end - begin);
  NumericLocaleScope numericLocale;
  if (!numericLocale.active()) {
    return false;
  }
  const int length = std::snprintf(begin, capacity, "%.*g",
                                   std::numeric_limits<double>::max_digits10,
                                   value);
  return length > 0 && static_cast<std::size_t>(length) < capacity;
}

} // namespace

std::unique_ptr<MacosNativeVideoMpvPort> MacosNativeVideoMpvPort::create(
    std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime,
    mpv_handle *handle, QThread *ownerThread,
    NativeVideoMpvCaptionResolver captions, NativeVideoMpvErrorSink errors,
    std::string *error) {
  if (!runtime || !runtime->api().complete() || handle == nullptr) {
    if (error != nullptr) {
      error->clear();
    }
    setCreationError(
        error, "native mpv port requires a validated runtime and live handle");
    return nullptr;
  }
  std::unique_ptr<NativeVideoMpvProductionContext> production;
  try {
    production = std::make_unique<NativeVideoMpvProductionContext>(
        NativeVideoMpvProductionContext{std::move(runtime), handle});
  } catch (...) {
    setCreationError(error, "native mpv port allocation failed");
    return nullptr;
  }
  NativeVideoMpvCallSeam calls;
  calls.context = production.get();
  calls.getProperty = &getMpvProperty;
  calls.setProperty = &setMpvProperty;
  calls.commandAsync = &queueMpvCommand;
  std::unique_ptr<MacosNativeVideoMpvPort> port =
      createInjected(calls, ownerThread, captions, errors, error);
  if (port) {
    port->production_ = std::move(production);
  }
  return port;
}

std::unique_ptr<MacosNativeVideoMpvPort>
MacosNativeVideoMpvPort::createInjected(
    NativeVideoMpvCallSeam calls, QThread *ownerThread,
    NativeVideoMpvCaptionResolver captions, NativeVideoMpvErrorSink errors,
    std::string *error) {
  if (error != nullptr) {
    error->clear();
  }
  if (!validCalls(calls) || ownerThread == nullptr ||
      QThread::currentThread() != ownerThread || captions.resolve == nullptr ||
      errors.surface == nullptr) {
    setCreationError(
        error,
        "native mpv port requires calls, callbacks, and its current owner thread");
    return nullptr;
  }
  try {
    return std::unique_ptr<MacosNativeVideoMpvPort>(
        new MacosNativeVideoMpvPort(calls, ownerThread, captions, errors));
  } catch (...) {
    setCreationError(error, "native mpv port allocation failed");
    return nullptr;
  }
}

MacosNativeVideoMpvPort::MacosNativeVideoMpvPort(
    NativeVideoMpvCallSeam calls, QThread *ownerThread,
    NativeVideoMpvCaptionResolver captions,
    NativeVideoMpvErrorSink errors) noexcept
    : calls_(calls), owner_thread_(ownerThread), captions_(captions),
      errors_(errors) {}

MacosNativeVideoMpvPort::~MacosNativeVideoMpvPort() = default;

bool MacosNativeVideoMpvPort::onOwnerThread() const noexcept {
  return owner_thread_ != nullptr && QThread::currentThread() == owner_thread_;
}

std::optional<Transport> MacosNativeVideoMpvPort::readTransport() noexcept {
  Transport result;
  int paused = -1;
  if (calls_.getProperty(calls_.context, "time-pos",
                         NativeVideoMpvValueKind::Double,
                         &result.position) < 0 ||
      calls_.getProperty(calls_.context, "speed",
                         NativeVideoMpvValueKind::Double, &result.rate) < 0 ||
      calls_.getProperty(calls_.context, "pause",
                         NativeVideoMpvValueKind::Flag, &paused) < 0 ||
      (paused != 0 && paused != 1)) {
    return std::nullopt;
  }
  result.paused = paused != 0;
  if (!validTransport(result)) {
    return std::nullopt;
  }
  return result;
}

bool MacosNativeVideoMpvPort::setDouble(const char *name,
                                        double value) noexcept {
  return name != nullptr && std::isfinite(value) &&
         calls_.setProperty(calls_.context, name,
                            NativeVideoMpvValueKind::Double, &value) >= 0;
}

bool MacosNativeVideoMpvPort::setFlag(const char *name, bool value) noexcept {
  int flag = value ? 1 : 0;
  return name != nullptr &&
         calls_.setProperty(calls_.context, name,
                            NativeVideoMpvValueKind::Flag, &flag) >= 0;
}

std::optional<Transport>
MacosNativeVideoMpvPort::forcePauseAndReadback() noexcept {
  if (!onOwnerThread() || call_active_) {
    return std::nullopt;
  }
  ActiveCall active(call_active_);
  const std::optional<Transport> before = readTransport();
  if (!before || !setFlag("pause", true)) {
    return std::nullopt;
  }
  std::optional<Transport> authoritative = readTransport();
  if (!authoritative || !authoritative->paused) {
    return std::nullopt;
  }
  return authoritative;
}

std::optional<Transport> MacosNativeVideoMpvPort::restoreAndReadback(
    Transport desired) noexcept {
  return restoreAndReadback(
      desired, NativeVideoMpvRestoreMode::PositionSpeedPause);
}

std::optional<Transport> MacosNativeVideoMpvPort::restoreAndReadback(
    Transport desired, NativeVideoMpvRestoreMode mode) noexcept {
  if (!onOwnerThread() || call_active_ || !validTransport(desired)) {
    return std::nullopt;
  }
  ActiveCall active(call_active_);
  const bool writePosition =
      mode == NativeVideoMpvRestoreMode::PositionSpeedPause;
  if ((writePosition && !setDouble("time-pos", desired.position)) ||
      !setDouble("speed", desired.rate) ||
      !setFlag("pause", desired.paused)) {
    return std::nullopt;
  }
  std::optional<Transport> authoritative = readTransport();
  return authoritative;
}

bool MacosNativeVideoMpvPort::queueLoadAudioOnly(
    std::uint64_t replyId, const std::filesystem::path &source) noexcept {
  if (!onOwnerThread() || call_active_ ||
      !mpv_reply::isNativeVideoAdapter(replyId) || source.empty()) {
    return false;
  }
  ActiveCall active(call_active_);
  try {
    const std::string encoded = source.string();
    if (encoded.empty() || encoded.find('\0') != std::string::npos) {
      return false;
    }
    const char *arguments[] = {"loadfile", encoded.c_str(), "replace", "-1",
                               "vid=no", nullptr};
    return calls_.commandAsync(calls_.context, replyId, arguments) >= 0;
  } catch (...) {
    return false;
  }
}

bool MacosNativeVideoMpvPort::queueSeekExact(std::uint64_t replyId,
                                             double target) noexcept {
  if (!onOwnerThread() || call_active_ ||
      !mpv_reply::isNativeVideoAdapter(replyId) || !std::isfinite(target) ||
      target < 0.0) {
    return false;
  }
  ActiveCall active(call_active_);
  // libmpv numeric command arguments use the C locale. Keep formatting local
  // to this owner-thread call; never mutate the process-wide locale.
  char encoded[64]{};
  if (!formatDouble(target, encoded, encoded + sizeof(encoded))) {
    return false;
  }
  const char *arguments[] = {"seek", encoded, "absolute+exact", nullptr};
  return calls_.commandAsync(calls_.context, replyId, arguments) >= 0;
}

bool MacosNativeVideoMpvPort::queueSelectVideo(std::uint64_t replyId,
                                               std::int64_t videoId) noexcept {
  if (!onOwnerThread() || call_active_ ||
      !mpv_reply::isNativeVideoAdapter(replyId) || videoId <= 0) {
    return false;
  }
  ActiveCall active(call_active_);
  char encoded[32]{};
  if (!formatInteger(videoId, encoded, encoded + sizeof(encoded))) {
    return false;
  }
  const char *arguments[] = {"set", "vid", encoded, nullptr};
  return calls_.commandAsync(calls_.context, replyId, arguments) >= 0;
}

bool MacosNativeVideoMpvPort::attachCaption(std::uint64_t captionId) noexcept {
  if (!onOwnerThread() || call_active_ || captionId == 0 ||
      captions_.resolve == nullptr) {
    return false;
  }
  ActiveCall active(call_active_);
  std::int64_t sid = -1;
  if (!captions_.resolve(captions_.context, captionId, &sid) || sid <= 0) {
    return false;
  }
  std::int64_t selected = -1;
  return calls_.setProperty(calls_.context, "sid",
                            NativeVideoMpvValueKind::Int64, &sid) >= 0 &&
         calls_.getProperty(calls_.context, "sid",
                            NativeVideoMpvValueKind::Int64, &selected) >= 0 &&
         selected == sid;
}

bool MacosNativeVideoMpvPort::surfaceError(FallbackReason reason) noexcept {
  if (!onOwnerThread() || call_active_ || !validFallbackReason(reason) ||
      errors_.surface == nullptr) {
    return false;
  }
  ActiveCall active(call_active_);
  return errors_.surface(errors_.context, reason);
}

} // namespace wam::macos
