#pragma once

// Zero-copy Metal texture views of IOSurface-backed decoded frames. No shipping
// presentation route samples through Metal; the presenter and VideoToolbox
// decoder tests use this to prove decoded surfaces import without a CPU copy.

#include "platform/macos/native_video_presenter.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace wam::macos {

struct MetalPlane {
  std::size_t width{0};
  std::size_t height{0};
  std::size_t sourcePlane{0};
  std::uint64_t metalPixelFormat{0};
};

// Owns the CVMetalTexture views for one frame and keeps the source frame alive.
// nativeTexture() is a borrowed id<MTLTexture> encoded as void*. It remains
// valid only while this MetalFrameLease is alive.
class MetalFrameLease final {
public:
  MetalFrameLease() noexcept;
  MetalFrameLease(MetalFrameLease &&other) noexcept;
  MetalFrameLease &operator=(MetalFrameLease &&other) noexcept;
  ~MetalFrameLease();

  MetalFrameLease(const MetalFrameLease &) = delete;
  MetalFrameLease &operator=(const MetalFrameLease &) = delete;

  [[nodiscard]] explicit operator bool() const noexcept;
  [[nodiscard]] const FrameLease &frame() const noexcept;
  [[nodiscard]] std::size_t planeCount() const noexcept;
  [[nodiscard]] const MetalPlane &plane(std::size_t index) const;
  [[nodiscard]] void *nativeTexture(std::size_t index) const noexcept;

private:
  struct Storage;
  explicit MetalFrameLease(std::unique_ptr<Storage> storage) noexcept;

  std::unique_ptr<Storage> storage_;
  friend class MetalTextureCache;
};

// Owns one CVMetalTextureCache tied to a Metal device. Importing an
// IOSurface-backed FrameLease creates Metal texture views without a CPU copy.
class MetalTextureCache final {
public:
  // nativeMetalDevice may be null to use MTLCreateSystemDefaultDevice(). When
  // supplied it must be an id<MTLDevice> encoded as void*.
  static std::unique_ptr<MetalTextureCache>
  create(void *nativeMetalDevice = nullptr, std::string *error = nullptr);

  MetalTextureCache(const MetalTextureCache &) = delete;
  MetalTextureCache &operator=(const MetalTextureCache &) = delete;
  MetalTextureCache(MetalTextureCache &&) = delete;
  MetalTextureCache &operator=(MetalTextureCache &&) = delete;
  ~MetalTextureCache();

  [[nodiscard]] void *nativeDevice() const noexcept;
  [[nodiscard]] std::optional<MetalFrameLease>
  importFrame(const FrameLease &frame, std::string *error = nullptr);

  // Flushes cached texture metadata. Existing MetalFrameLeases remain valid.
  void flush() noexcept;

private:
  struct Impl;
  explicit MetalTextureCache(std::unique_ptr<Impl> impl) noexcept;
  std::unique_ptr<Impl> impl_;
};

}  // namespace wam::macos
