#pragma once

#include "native_video_action_driver.hpp"

#include <functional>
#include <memory>
#include <optional>
#include <string>

namespace wam::qt {

class MpvVideoItem;
class PlayerCore;

} // namespace wam::qt

namespace wam::macos {

class QtGlVideoItem;

// Explicitly constructed production boundaries for the dormant macOS native
// path. Merely compiling or linking these factories performs no Qt, libmpv,
// VideoToolbox, or OpenGL work.
[[nodiscard]] std::unique_ptr<AdapterRenderPort>
createNativeVideoRenderPort(std::weak_ptr<qt::PlayerCore> core,
                            qt::MpvVideoItem *item,
                            std::string *error = nullptr) noexcept;

[[nodiscard]] std::unique_ptr<AdapterSessionFactory>
createNativeVideoSessionFactory(QtGlVideoItem *item,
                                std::string *error = nullptr) noexcept;

#if defined(WAM_NATIVE_VIDEO_PRODUCTION_PORTS_TESTING)

// Narrow deterministic seams for the boundary logic. They deliberately
// describe whole production operations rather than exposing PlayerCore,
// NativeVideoSession, VideoToolbox, or a Qt scene graph to the unit test.
struct NativeVideoRenderPortTestFunctions final {
  std::function<bool()> onOwnerThread;
  std::function<std::optional<std::uint64_t>()> snapshotLifecycleGeneration;
  std::function<bool()> revokeRenderContext;
  std::function<bool()> allowRenderContext;
  std::function<bool()> requestVideoUpdate;
};

struct NativeVideoSessionPortTestFunctions final {
  std::function<bool()> onOwnerThread;
  std::function<bool()> outputAlive;
  std::function<NativeVideoSessionDispatch(
      const native_activation::Action &)>
      execute;
  std::function<NativeVideoSessionDispatch(
      const native_activation::Action &, native_activation::Transport)>
      reanchor;
  std::function<std::optional<NativeVideoSessionEvent>()> poll;
  std::function<native_activation::NativeSample(native_activation::Token)>
      sample;
};

struct NativeVideoSessionFactoryTestFunctions final {
  std::function<bool()> onOwnerThread;
  std::function<bool()> outputAlive;
  std::function<std::optional<NativeVideoSessionPortTestFunctions>(
      native_activation::Token, const std::filesystem::path &, std::string *)>
      create;
};

[[nodiscard]] std::unique_ptr<AdapterRenderPort>
createNativeVideoRenderPortForTesting(
    NativeVideoRenderPortTestFunctions functions,
    std::string *error = nullptr) noexcept;

[[nodiscard]] std::unique_ptr<AdapterSessionFactory>
createNativeVideoSessionFactoryForTesting(
    NativeVideoSessionFactoryTestFunctions functions,
    std::string *error = nullptr) noexcept;

#endif

} // namespace wam::macos
