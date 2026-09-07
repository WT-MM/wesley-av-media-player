#pragma once
#include <CoreVideo/CoreVideo.h>
#include <cstddef>
#include <cstdint>
#include <span>

namespace wam::macos {
class SoftwarePresentationPool final {
public:
  static constexpr std::size_t kDepth=6;
  ~SoftwarePresentationPool();
  bool configure(std::int32_t width,std::int32_t height,OSType format);
  CVPixelBufferRef acquire() noexcept;
  void close() noexcept;
private:
  CVPixelBufferPoolRef pool_{};
  CFDictionaryRef attributes_{};
};
// Plane samples remain at their coded depth; 10-bit output uses the high bits.
bool copySoftwarePlanes(CVPixelBufferRef destination,
    const std::uint8_t* const planes[3],const int strides[3],
    unsigned width,unsigned height,unsigned depth,bool chroma422) noexcept;
}
