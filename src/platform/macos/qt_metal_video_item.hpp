#pragma once

#include "native_video_presenter.hpp"

#include <QQuickItem>
#include <QString>

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

namespace wam::macos {

struct QtMetalVideoItemStats {
  std::uint64_t submittedFrames{0};
  std::uint64_t importedFrames{0};
  std::uint64_t destroyedResourceSets{0};
  std::size_t activeResourceSets{0};
  int framesInFlight{0};
  OSType lastPixelFormat{0};
  bool exactQtMetalDevice{false};
  bool exactSourceIOSurface{false};
  QString lastError;
};

// A small, backend-independent lifetime primitive used by the Metal scene-
// graph node. Every render round retains the resource sampled by that round in
// Qt's current frame slot. Replacing a slot is safe because Qt has completed
// the GPU work associated with that slot before reusing it.
class QtFrameSlotRetainer final {
 public:
  static constexpr int kMaximumSlots = 4;

  [[nodiscard]] bool retain(int currentSlot, int framesInFlight,
                            std::shared_ptr<void> resource) noexcept;
  void clear() noexcept;
  [[nodiscard]] std::size_t retainedSlotCount() const noexcept;
  [[nodiscard]] bool safeToDraw() const noexcept;

 private:
  std::array<std::shared_ptr<void>, kMaximumSlots> slots_{};
  int framesInFlight_{0};
  bool safeToDraw_{false};
};

// Test-gated Qt Quick integration for IOSurface-backed VideoToolbox output.
// The item is not registered by, linked into, or selected by shipping WAM.
// submitFrame() belongs on the GUI thread; all Metal and QSG resources are
// created and destroyed by the scene-graph render thread.
class QtMetalVideoItem final : public QQuickItem {
  Q_OBJECT

 public:
  // Opaque to callers, but named by render-thread implementation types in the
  // Objective-C++ translation unit.
  struct SharedState;

  explicit QtMetalVideoItem(QQuickItem* parent = nullptr);
  ~QtMetalVideoItem() override;

  void submitFrame(FrameLease frame);
  [[nodiscard]] QtMetalVideoItemStats stats() const;

 protected:
  QSGNode* updatePaintNode(QSGNode* oldNode,
                           UpdatePaintNodeData* data) override;

 private:
  std::shared_ptr<SharedState> state_;
};

}  // namespace wam::macos
