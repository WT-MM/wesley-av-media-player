#pragma once

#include "media/native_media_source.hpp"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <array>
#include <cstddef>

namespace wam::macos {

// THE YCbCr -> RGB colour-matrix decision for every presenter in this tree.
//
// This decision is stated once because per-route copies of it had already
// diverged in the way that matters: one presenter carried a BT.2020 branch
// while the Qt item HARD-REJECTED a BT.2020 buffer. Widening admission to
// BT.2020/PQ/HLG in per-route copies would have made
// WAM_PRESENTATION=scenegraph refuse
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

// ITU-T H.273 gives matrix_coefficients 5 (BT.470BG, PAL) and 6 (SMPTE 170M,
// NTSC) the SAME non-constant-luminance coefficients -- Kr=0.299, Kb=0.114.
// CoreMedia maps 6 onto kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 but has no
// constant for 5, so it passes that value through in its unmapped spelling,
// "<key>#<value>". Reading it as BT.601 is therefore a RENAMING, not an
// approximation: the two enumerants denote one matrix.
//
// Matching a spelling rather than a published constant is deliberate, and the
// failure mode is why it is acceptable: if the platform ever stops producing
// this string the tag simply stops matching, the stream is refused, and it
// falls back -- it is never presented through the wrong matrix. Real files
// carry it, so refusing to read it costs native playback on content
// VideoToolbox decodes without complaint.
[[nodiscard]] inline CFStringRef bt470bgYCbCrMatrixSpelling() noexcept {
  return CFSTR("YCbCrMatrix#5");
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
  } else if (CFEqual(matrix, bt470bgYCbCrMatrixSpelling())) {
    // The decoder normalizes this spelling onto the surface before any frame
    // is leased; a presenter reaching it here means that path was bypassed.
    // Same matrix either way -- see bt470bgYCbCrMatrixSpelling().
    *kind = YCbCrMatrixKind::Bt601;
  } else {
    recognized = false;
  }
  CFRelease(matrix);
  return recognized;
}

// THE modelled-colour -> CoreMedia-extension mapping, for the routes that
// SYNTHESIZE a CMVideoFormatDescription instead of receiving one.
//
// AVFoundation hands its own description over with the colour already on it;
// Matroska and MPEG-TS build theirs from a codec configuration record, and a
// description built from the atom alone carries no colour at all. Handing
// VideoToolbox such a description makes the decoded surface untagged, and an
// untagged PQ surface is presented as SDR -- the washed-out render measured at
// 98/255 on the colour bars, which is the failure this mapping prevents.
//
// This is the exact inverse of avfoundation_media_source.mm's copy* readers,
// stated once so the two directions cannot drift apart.
//
// nullptr means "write no key". Absence is how an untagged stream is spelled
// to CoreMedia, and it is what the SDR corpus has always presented from, so an
// untagged track keeps a byte-identical description. OtherExplicit and Srgb
// return nullptr rather than an approximation: they are refused upstream by
// media::mediaVideoColorAdmitted(), and if that rule is ever widened an
// untagged surface is a safe degradation where a WRONG tag is not.
[[nodiscard]] inline CFStringRef
colorPrimariesExtension(media::MediaColorPrimaries value) noexcept {
  switch (value) {
  case media::MediaColorPrimaries::Bt709:
    return kCMFormatDescriptionColorPrimaries_ITU_R_709_2;
  case media::MediaColorPrimaries::Bt2020:
    return kCMFormatDescriptionColorPrimaries_ITU_R_2020;
  // Bt601 is bound to SMPTE-C (525). The binding is load-bearing, not a
  // preference: copyColorPrimaries() in avfoundation_media_source.mm admits
  // ONLY SMPTE-C into this enumerator and leaves EBU 3213 (625) refused, so on
  // that route writing SMPTE-C back is the exact inverse rather than a guess
  // between two different chromaticity sets.
  //
  // Writing NOTHING here would be the wrong kind of safe. An absent primaries
  // key does not mean "untagged" to VideoToolbox: it re-infers by CODED SIZE
  // and hands back BT.709 for anything above SD. A 1080p SMPTE-C stream would
  // then be admitted and presented through BT.709 primaries -- worse than the
  // fallback it replaced.
  //
  // The binding is enforced at every producer, not just this route:
  // mediaColorPrimariesFromIso() in matroska_demuxer.cpp and mpegts_demuxer.cpp
  // map ISO value 6 here and leave value 5 refused, exactly as the
  // AVFoundation reader does. Admitting BT.470BG anywhere requires splitting
  // the enumerator first -- see the amendment in the SD colour report.
  case media::MediaColorPrimaries::Bt601:
    return kCMFormatDescriptionColorPrimaries_SMPTE_C;
  default:
    return nullptr;
  }
}

[[nodiscard]] inline CFStringRef
transferFunctionExtension(media::MediaTransferFunction value) noexcept {
  switch (value) {
  case media::MediaTransferFunction::Bt709:
    return kCMFormatDescriptionTransferFunction_ITU_R_709_2;
  case media::MediaTransferFunction::Pq:
    return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ;
  case media::MediaTransferFunction::Hlg:
    return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG;
  default:
    return nullptr;
  }
}

[[nodiscard]] inline CFStringRef
ycbcrMatrixExtension(media::MediaMatrixCoefficients value) noexcept {
  switch (value) {
  case media::MediaMatrixCoefficients::Bt709:
    return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2;
  case media::MediaMatrixCoefficients::Bt601:
    return kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4;
  case media::MediaMatrixCoefficients::Bt2020Ncl:
    return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020;
  default:
    return nullptr;
  }
}

// Writes whichever of the three keys are modelled onto `extensions`.
inline void applyColorExtensions(CFMutableDictionaryRef extensions,
                                 media::MediaColorPrimaries primaries,
                                 media::MediaTransferFunction transfer,
                                 media::MediaMatrixCoefficients matrix) noexcept {
  if (extensions == nullptr) {
    return;
  }
  if (CFStringRef value = colorPrimariesExtension(primaries)) {
    CFDictionarySetValue(
        extensions, kCMFormatDescriptionExtension_ColorPrimaries, value);
  }
  if (CFStringRef value = transferFunctionExtension(transfer)) {
    CFDictionarySetValue(
        extensions, kCMFormatDescriptionExtension_TransferFunction, value);
  }
  if (CFStringRef value = ycbcrMatrixExtension(matrix)) {
    CFDictionarySetValue(extensions, kCMFormatDescriptionExtension_YCbCrMatrix,
                         value);
  }
}

} // namespace wam::macos
