#pragma once

#include "media/native_media_source.hpp"

#include <cstdint>

namespace wam::media {

// ISO/IEC 23091-2 colour codes -> the contract's colour enumerations.
//
// One definition for every container that reads these codes out of a bitstream
// rather than out of a container element: a transport stream's sequence
// extension and a Matroska Colour element state the same integers and must
// produce the same verdict, so the same stream gets the same answer whether it
// arrives as .ts, .mkv or .mp4.
//
// Value 2 is "unspecified", which carries exactly as much information as an
// absent description and is therefore Unknown, NOT OtherExplicit: OtherExplicit
// means "an explicit value this renderer does not support" and is a fallback
// proof, and mapping unspecified onto it made every stream with a partial VUI
// fail consumer configuration.
//
// Anything not named here stays OtherExplicit and is refused by name
// downstream, in mediaVideoColorAdmitted(). The named set is EXACTLY the set the
// AVFoundation route models in copyColorPrimaries / copyTransferFunction /
// copyMatrixCoefficients. Deliberately NOT widened past it: the two BT.2020
// transfers (14, 15) are arguably the BT.709 curve, but the MP4 route does not
// model them and no fixture proves how they present, so inventing a mapping
// here would make these containers MORE permissive than MP4 -- the same
// asymmetry these mappings exist to prevent, pointed the other way.
[[nodiscard]] constexpr MediaColorPrimaries
mediaColorPrimariesFromIso(std::uint64_t value) noexcept {
  switch (value) {
  case 1:
    return MediaColorPrimaries::Bt709;
  case 2:
    return MediaColorPrimaries::Unknown;
  case 6:
    // SMPTE 170M (525) only. BT.470BG (625, value 5) is a DIFFERENT set of
    // chromaticities, and the contract has one BT.601 primaries enumerator --
    // which is bound to SMPTE-C so colorPrimariesExtension() can spell it back
    // exactly. Folding 5 in here would let a 625-line stream be admitted and
    // then presented as 525. It keeps its named refusal until the enumerator
    // is split.
    return MediaColorPrimaries::Bt601;
  case 9:
    return MediaColorPrimaries::Bt2020;
  default:
    return MediaColorPrimaries::OtherExplicit;
  }
}

[[nodiscard]] constexpr MediaTransferFunction
mediaTransferFunctionFromIso(std::uint64_t value) noexcept {
  switch (value) {
  case 1:
  // SMPTE 170M (6) is the BT.709 transfer function under its SD name.
  case 6:
    return MediaTransferFunction::Bt709;
  case 2:
    return MediaTransferFunction::Unknown;
  case 13:
    return MediaTransferFunction::Srgb;
  case 16:
    return MediaTransferFunction::Pq;
  case 18:
    return MediaTransferFunction::Hlg;
  default:
    return MediaTransferFunction::OtherExplicit;
  }
}

[[nodiscard]] constexpr MediaMatrixCoefficients
mediaMatrixCoefficientsFromIso(std::uint64_t value) noexcept {
  switch (value) {
  case 1:
    return MediaMatrixCoefficients::Bt709;
  case 2:
    return MediaMatrixCoefficients::Unknown;
  case 5:
  case 6:
    return MediaMatrixCoefficients::Bt601;
  case 9:
    return MediaMatrixCoefficients::Bt2020Ncl;
  default:
    return MediaMatrixCoefficients::OtherExplicit;
  }
}

} // namespace wam::media
