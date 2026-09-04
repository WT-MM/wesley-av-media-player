#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>
#include <vector>

// Neutral extraction of ATSC A/53 closed-caption data from H.264 SEI.
//
// US broadcast and DVR recordings carry CEA-608/708 captions INSIDE the video
// elementary stream, in an SEI message of type 4 (user_data_registered_itu_t_
// t35) whose payload is:
//
//   itu_t_t35_country_code   0xB5        (USA)
//   itu_t_t35_provider_code  0x0031      (ATSC)
//   user_identifier          'GA94'
//   user_data_type_code      0x03        (cc_data)
//   flags/cc_count           1 byte: process_cc_data_flag in bit 6, count in 0..4
//   em_data                  1 byte
//   cc_count x 3 bytes       marker bits, cc_valid, cc_type, then two data bytes
//   marker_bits              0xFF
//
// There is no track and no codec parameter set to hint that captions exist:
// the only way to know is to walk the NALs. Both the AVFoundation route and
// the MPEG-TS route do that here, so the two cannot drift.
//
// Free of Qt and of Apple frameworks, for the same reason subtitle_text.hpp is.
namespace wam::media::captions {

// cc_type values from A/53 Part 4.
enum class CcType : std::uint8_t {
  Ntsc608Field1 = 0,  // CEA-608 line 21 field 1
  Ntsc608Field2 = 1,  // CEA-608 line 21 field 2
  Dtvcc708Header = 2,
  Dtvcc708Data = 3,
};

struct CcTriplet {
  CcType type{CcType::Ntsc608Field1};
  bool valid{false};
  std::uint8_t data1{0};
  std::uint8_t data2{0};
};

// A single picture's worth of caption bytes. Real streams carry a fixed count
// per frame (10 triplets at 29.97, 20 at 59.94); a synthesized stream may
// carry fewer.
inline constexpr std::size_t kMaximumTripletsPerPicture{32};

// Appends the cc_data triplets carried by ONE SEI RBSP. `rbsp` must already
// have emulation-prevention bytes removed and must start at the NAL header
// byte. Returns the number of triplets appended.
//
// A single SEI NAL may hold several messages; every A/53 cc_data message in it
// contributes. Non-caption messages are skipped by their declared size, so an
// unrelated SEI (picture timing, buffering period) costs a few comparisons.
std::size_t appendCaptionTripletsFromSeiRbsp(std::string_view rbsp,
                                             std::vector<CcTriplet>* out);

// Same, for an Annex-B byte range that may contain several NALs of any type.
// Start codes may be 3 or 4 bytes. Non-SEI NALs are ignored.
std::size_t appendCaptionTripletsFromAnnexB(std::string_view annexB,
                                            std::vector<CcTriplet>* out);

// Same, for a length-prefixed (AVCC / "avc1") sample, as CoreMedia and the MP4
// container carry it. `lengthSize` is nalUnitLength+1 from the avcC record and
// must be 1, 2 or 4.
std::size_t appendCaptionTripletsFromAvcc(std::string_view sample,
                                          std::size_t lengthSize,
                                          std::vector<CcTriplet>* out);

// Removes H.264 emulation-prevention bytes (0x03 in a 0x00 0x00 0x03 run).
// Exposed because callers that already hold an SEI payload can reuse it.
[[nodiscard]] std::vector<char> removeEmulationPrevention(std::string_view nal);

// True when the NAL header byte names an SEI NAL (type 6).
[[nodiscard]] constexpr bool isSeiNalHeader(std::uint8_t header) noexcept {
  return (header & 0x1FU) == 6U;
}

// HEVC carries the same A/53 payload in a PREFIX_SEI_NUT (type 39). The
// payload parser is shared; only the NAL header differs (two bytes, type in
// bits 1..6 of the first). Wired for MPEG-TS HEVC; see the report's deferrals.
[[nodiscard]] constexpr bool isHevcPrefixSeiNalHeader(
    std::uint8_t byte0) noexcept {
  return ((byte0 >> 1) & 0x3FU) == 39U;
}

}  // namespace wam::media::captions
