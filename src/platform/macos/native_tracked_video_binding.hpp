#pragma once

#include "native_tracked_video_arbiter.hpp"
#include <variant>

namespace wam::macos {
class NativeLayerVideoOutput;
class NativeQtGlOutput;

// The caller retains a non-null output through every bound call; the route is immutable.
class NativeTrackedVideoBinding final {
 public:
  enum class Kind { Layer, SceneGraph, Main, Injected };
  explicit NativeTrackedVideoBinding(NativeTrackedVideoOutput* output) noexcept;
  [[nodiscard]] Kind kind() const noexcept;
  [[nodiscard]] NativeTrackedVideoCapacity capacity(std::uint64_t generation) const noexcept;
  [[nodiscard]] NativeTrackedVideoSubmitStatus submit(const FrameLease& frame, NativeTrackedFrameSequence sequence, std::string* error) noexcept;
  [[nodiscard]] std::optional<NativeTrackedVideoEvent> takeEvent() noexcept;
  [[nodiscard]] NativeTrackedVideoOutputProgress flushProgress(std::uint64_t retiredGeneration, std::uint64_t nextGeneration) noexcept;
  [[nodiscard]] NativeTrackedVideoOutputProgress closeProgress(std::uint64_t finalGeneration) noexcept;
  [[nodiscard]] bool presentsDecodedSurfacesDirectly() const noexcept;
  [[nodiscard]] bool setPresentationRotation(int degrees) noexcept;
  [[nodiscard]] NativeTrackedVideoOutputFacts facts() const noexcept;
 private:
  using Route = std::variant<NativeLayerVideoOutput*, NativeQtGlOutput*,
      NativeTrackedVideoArbiter::MainOutput*, NativeTrackedVideoOutput*>;
  Route route_;
};
}  // namespace wam::macos
