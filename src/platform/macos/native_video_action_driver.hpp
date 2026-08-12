#pragma once

#include "native_video_session.hpp"
#include "qt/native_video_controller.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

struct AdapterFact {
  enum class Kind : std::uint8_t { Prepared, Unsupported, Failed };

  Kind kind{Kind::Failed};
  native_activation::Token token{};
  std::uint64_t generation{0};
};

class AdapterRenderPort {
public:
  virtual ~AdapterRenderPort() = default;
  [[nodiscard]] virtual bool onOwnerThread() const noexcept = 0;
  [[nodiscard]] virtual std::optional<std::uint64_t>
  revokeAndRequestRelease() noexcept = 0;
  [[nodiscard]] virtual bool allowAndRequestAcquire() noexcept = 0;
};

class AdapterMpvPort {
public:
  virtual ~AdapterMpvPort() = default;
  [[nodiscard]] virtual std::optional<native_activation::Transport>
  forcePauseAndReadback() noexcept = 0;
  [[nodiscard]] virtual std::optional<native_activation::Transport>
  restoreAndReadback(native_activation::Transport desired) noexcept = 0;
  [[nodiscard]] virtual bool
  queueLoadAudioOnly(std::uint64_t replyId,
                     const std::filesystem::path &source) noexcept = 0;
  [[nodiscard]] virtual bool queueSeekExact(std::uint64_t replyId,
                                            double target) noexcept = 0;
  [[nodiscard]] virtual bool
  queueSelectVideo(std::uint64_t replyId, std::int64_t videoId) noexcept = 0;
  [[nodiscard]] virtual bool
  attachCaption(std::uint64_t captionId) noexcept = 0;
  [[nodiscard]] virtual bool
  surfaceError(native_activation::FallbackReason reason) noexcept = 0;
};

class AdapterSessionPort {
public:
  virtual ~AdapterSessionPort() = default;
  [[nodiscard]] virtual native_activation::NativeVideoDriverDispatch
  execute(const native_activation::Action &action) noexcept = 0;
  [[nodiscard]] virtual native_activation::NativeVideoDriverDispatch
  reanchor(const native_activation::Action &action,
           native_activation::Transport authoritative) noexcept = 0;
  [[nodiscard]] virtual std::optional<NativeVideoSessionEvent>
  poll() noexcept = 0;
  [[nodiscard]] virtual native_activation::NativeSample
  sample(native_activation::Token token) noexcept = 0;
};

class AdapterSessionFactory {
public:
  virtual ~AdapterSessionFactory() = default;
  [[nodiscard]] virtual std::unique_ptr<AdapterSessionPort>
  create(native_activation::Token token, const std::filesystem::path &source,
         std::string *error) noexcept = 0;
};

// Test-only macOS boundary adapter. It owns one activation token, one session,
// and at most one coordinator Action or mpv command reply at a time.
class MacosNativeVideoActionDriver final
    : public native_activation::NativeVideoActionDriver {
public:
  static std::unique_ptr<MacosNativeVideoActionDriver>
  create(std::filesystem::path source,
         std::unique_ptr<AdapterRenderPort> render,
         std::unique_ptr<AdapterMpvPort> mpv,
         std::unique_ptr<AdapterSessionFactory> sessions,
         std::string *error = nullptr);

  MacosNativeVideoActionDriver(const MacosNativeVideoActionDriver &) = delete;
  MacosNativeVideoActionDriver &
  operator=(const MacosNativeVideoActionDriver &) = delete;
  ~MacosNativeVideoActionDriver() override;

  [[nodiscard]] native_activation::NativeVideoDriverDispatch
  execute(const native_activation::Action &action) noexcept override;
  [[nodiscard]] std::optional<native_activation::NativeVideoDriverDispatch>
  poll() noexcept override;
  [[nodiscard]] bool acceptMpvCommandReply(std::uint64_t userdata,
                                           int error) noexcept;
  [[nodiscard]] static bool
  ownsMpvCommandReply(std::uint64_t userdata) noexcept;
  [[nodiscard]] std::optional<AdapterFact> takeFact() noexcept;
  [[nodiscard]] native_activation::NativeSample
  sample(native_activation::Token token) noexcept;
  [[nodiscard]] std::optional<std::string> takeLastError() noexcept;

private:
  struct Impl;
  explicit MacosNativeVideoActionDriver(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
};

} // namespace wam::macos
