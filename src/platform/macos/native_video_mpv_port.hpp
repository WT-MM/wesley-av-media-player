#pragma once

#include "native_video_action_driver.hpp"

#include <cstdint>
#include <memory>
#include <string>

class QThread;
struct mpv_handle;

namespace wam::playback::mpv {
class MpvRuntime;
}

namespace wam::macos {

struct NativeVideoMpvProductionContext;

// Deliberately smaller than mpv_format: these are the only synchronous value
// kinds the native activation state machine is allowed to mutate.
enum class NativeVideoMpvValueKind : std::uint8_t {
  Double,
  Flag,
  Int64,
};

// Injectable, allocation-free call boundary. Production construction maps
// these three calls to libmpv; deterministic tests provide a fake context and
// never create an mpv client. A nonnegative result means the call was accepted.
struct NativeVideoMpvCallSeam {
  void *context{nullptr};
  int (*getProperty)(void *context, const char *name,
                     NativeVideoMpvValueKind kind, void *value) noexcept{
      nullptr};
  int (*setProperty)(void *context, const char *name,
                     NativeVideoMpvValueKind kind, void *value) noexcept{
      nullptr};
  int (*commandAsync)(void *context, std::uint64_t replyUserdata,
                      const char **arguments) noexcept{nullptr};
};

// captionId remains an opaque request-lineage identity. The future activation
// owner must first attach the subtitle, retain a bounded captionId -> mpv sid
// registry, and retire that entry with its open lineage. This callback only
// resolves an exact existing entry; the port never casts or reinterprets IDs.
struct NativeVideoMpvCaptionResolver {
  void *context{nullptr};
  bool (*resolve)(void *context, std::uint64_t captionId,
                  std::int64_t *sid) noexcept{nullptr};
};

// SurfaceError stays a controller-owned UI concern. The callback receives the
// exact bounded enum and reports whether it was accepted synchronously.
struct NativeVideoMpvErrorSink {
  void *context{nullptr};
  bool (*surface)(void *context,
                  native_activation::FallbackReason reason) noexcept{nullptr};
};

enum class NativeVideoMpvRestoreMode : std::uint8_t {
  // Startup, EOF, and fallback restore own the transport position write.
  PositionSpeedPause,
  // After an exact async seek has converged, position is authoritative and
  // must only be verified; issuing another time-pos write would start a second
  // seek and violate the capacity-one scrub/seek contract.
  SpeedPauseVerifyPosition,
};

// Default-off production AdapterMpvPort. Construction performs no libmpv
// mutation and does not activate native video. Every method is confined to
// ownerThread; its lifetime must outlast this port.
class MacosNativeVideoMpvPort final : public AdapterMpvPort {
public:
  static std::unique_ptr<MacosNativeVideoMpvPort>
  create(std::shared_ptr<const ::wam::playback::mpv::MpvRuntime> runtime,
         mpv_handle *handle, QThread *ownerThread,
         NativeVideoMpvCaptionResolver captions,
         NativeVideoMpvErrorSink errors, std::string *error = nullptr);

  static std::unique_ptr<MacosNativeVideoMpvPort>
  createInjected(NativeVideoMpvCallSeam calls, QThread *ownerThread,
                 NativeVideoMpvCaptionResolver captions,
                 NativeVideoMpvErrorSink errors,
                 std::string *error = nullptr);

  MacosNativeVideoMpvPort(const MacosNativeVideoMpvPort &) = delete;
  MacosNativeVideoMpvPort &
  operator=(const MacosNativeVideoMpvPort &) = delete;
  ~MacosNativeVideoMpvPort() override;

  [[nodiscard]] std::optional<native_activation::Transport>
  forcePauseAndReadback() noexcept override;
  [[nodiscard]] std::optional<native_activation::Transport>
  restoreAndReadback(native_activation::Transport desired) noexcept override;
  [[nodiscard]] std::optional<native_activation::Transport>
  restoreAndReadback(native_activation::Transport desired,
                     NativeVideoMpvRestoreMode mode) noexcept;
  [[nodiscard]] bool
  queueLoadAudioOnly(std::uint64_t replyId,
                     const std::filesystem::path &source) noexcept override;
  [[nodiscard]] bool queueSeekExact(std::uint64_t replyId,
                                    double target) noexcept override;
  [[nodiscard]] bool
  queueSelectVideo(std::uint64_t replyId,
                   std::int64_t videoId) noexcept override;
  [[nodiscard]] bool attachCaption(std::uint64_t captionId) noexcept override;
  [[nodiscard]] bool
  surfaceError(native_activation::FallbackReason reason) noexcept override;

private:
  MacosNativeVideoMpvPort(NativeVideoMpvCallSeam calls, QThread *ownerThread,
                         NativeVideoMpvCaptionResolver captions,
                         NativeVideoMpvErrorSink errors) noexcept;

  [[nodiscard]] bool onOwnerThread() const noexcept;
  [[nodiscard]] std::optional<native_activation::Transport>
  readTransport() noexcept;
  [[nodiscard]] bool setDouble(const char *name, double value) noexcept;
  [[nodiscard]] bool setFlag(const char *name, bool value) noexcept;

  NativeVideoMpvCallSeam calls_;
  QThread *owner_thread_{nullptr};
  NativeVideoMpvCaptionResolver captions_;
  NativeVideoMpvErrorSink errors_;
  std::unique_ptr<NativeVideoMpvProductionContext> production_;
  bool call_active_{false};
};

} // namespace wam::macos
