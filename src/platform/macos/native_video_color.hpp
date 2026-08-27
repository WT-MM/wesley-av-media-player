#pragma once

#include <CoreVideo/CoreVideo.h>

#include <array>
#include <cstddef>

namespace wam::macos {

// THE YCbCr -> RGB colour-matrix decision for every presenter in this tree.
//
// Before 2026-08-27 this decision existed in three independently drifting
// copies -- metal_layer_presenter.mm, qt_gl_video_item.mm and
// qt_metal_video_item.mm -- and they had already diverged in the way that
// matters: the Metal layer presenter carried a BT.2020 branch while the two Qt
// items HARD-REJECTED a BT.2020 buffer. Widening admission to BT.2020/PQ/HLG
// without collapsing them would have made WAM_PRESENTATION=scenegraph refuse
// every file the default layer path had just started playing. One definition,
// three callers.
//
// The coefficients are the exact inverse-matrix top rows for each standard's
// non-constant-luminance YCbCr:
//   R = Y                 + 2(1-Kr)      * Cr
//   G = Y - 2Kb(1-Kb)/Kg  * Cb - 2Kr(1-Kr)/Kg * Cr
//   B = Y + 2(1-Kb)       * Cb
// with (Kr, Kb) = (0.299, 0.114) for BT.601, (0.2126, 0.0722) for BT.709 and
// (0.2627, 0.0593) for BT.2020 non-constant luminance.
//
// NOTE ON SCOPE. This is the matrix only -- the YCbCr-to-RGB step. It is NOT
// tone mapping. On the default presentation path (AVSampleBufferDisplayLayer)
// none of this runs at all: the surface carries its own primaries, transfer
// and CGColorSpace from VideoToolbox and WindowServer does the whole
// conversion. These matrices exist for the scenegraph presenters, which
// convert in a shader. A PQ or HLG buffer put through them gets its matrix
// right and its transfer function left as-is, which is correct for a
// scenegraph path that has no tone mapper -- and is why the scenegraph route
// keeps its own named verdict rather than claiming HDR correctness.
enum class YCbCrMatrixKind : std::uint8_t {
  Bt601,
  Bt709,
  Bt2020Ncl,
};

struct YCbCrMatrixRows {
  std::array<float, 3> red{};
  std::array<float, 3> green{};
  std::array<float, 3> blue{};
};

[[nodiscard]] inline constexpr YCbCrMatrixRows ycbcrMatrixRows(
    YCbCrMatrixKind kind) noexcept {
  switch (kind) {
  case YCbCrMatrixKind::Bt601:
    return {{1.0F, 0.0F, 1.4020F},
            {1.0F, -0.344136F, -0.714136F},
            {1.0F, 1.7720F, 0.0F}};
  case YCbCrMatrixKind::Bt709:
    return {{1.0F, 0.0F, 1.5748F},
            {1.0F, -0.187324F, -0.468124F},
            {1.0F, 1.8556F, 0.0F}};
  case YCbCrMatrixKind::Bt2020Ncl:
    return {{1.0F, 0.0F, 1.4746F},
            {1.0F, -0.164553F, -0.571353F},
            {1.0F, 1.8814F, 0.0F}};
  }
  return {{1.0F, 0.0F, 1.5748F},
          {1.0F, -0.187324F, -0.468124F},
          {1.0F, 1.8556F, 0.0F}};
}

// Absent matrix metadata is inferred, never refused: SD-sized material
// conventionally uses BT.601 and HD-sized material BT.709. Explicit metadata
// always wins over the inference. An explicit value outside the three known
// standards yields no kind, and the caller names its own refusal -- this
// function never invents a matrix for metadata it does not recognize.
[[nodiscard]] inline bool ycbcrMatrixForPixelBuffer(
    CVPixelBufferRef pixelBuffer, YCbCrMatrixKind* kind) noexcept {
  if (pixelBuffer == nullptr || kind == nullptr) {
    return false;
  }
  CFTypeRef matrix =
      CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                             nullptr);
  if (matrix == nullptr) {
    // Conventional SD/HD inference for untagged material.
    *kind = (CVPixelBufferGetWidth(pixelBuffer) <= 1024 &&
             CVPixelBufferGetHeight(pixelBuffer) <= 576)
                ? YCbCrMatrixKind::Bt601
                : YCbCrMatrixKind::Bt709;
    return true;
  }
  bool recognized = true;
  if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
    *kind = YCbCrMatrixKind::Bt601;
  } else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
    *kind = YCbCrMatrixKind::Bt709;
  } else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
    *kind = YCbCrMatrixKind::Bt2020Ncl;
  } else {
    recognized = false;
  }
  CFRelease(matrix);
  return recognized;
}

} // namespace wam::macos
