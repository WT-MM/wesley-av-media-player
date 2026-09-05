#include "media/video_codec_configuration.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <new>
#include <optional>
#include <span>
#include <utility>
#include <vector>

namespace allocation_probe {
bool active = false;
std::size_t calls = 0;
} // namespace allocation_probe

void *operator new(std::size_t size) {
  if (allocation_probe::active) {
    ++allocation_probe::calls;
  }
  if (void *memory = std::malloc(size == 0U ? 1U : size)) {
    return memory;
  }
  throw std::bad_alloc{};
}

void *operator new[](std::size_t size) { return ::operator new(size); }

void operator delete(void *memory) noexcept { std::free(memory); }
void operator delete(void *memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void *memory) noexcept { std::free(memory); }
void operator delete[](void *memory, std::size_t) noexcept {
  std::free(memory);
}

namespace {

using namespace wam::media;

int failures = 0;

// High-profile avcC extracted from the repository's deterministic 1280x720
// H.264 sample. Unlike the generated edge fixtures below, it exercises an
// encoder-produced SPS, a complete extended PPS, and the optional high-profile
// avcC tail.
constexpr std::array<std::uint8_t, 45> kRepositorySampleAvcC{
    0x01, 0x64, 0x00, 0x1f, 0xff, 0xe1, 0x00, 0x1a, 0x67, 0x64, 0x00, 0x1f,
    0xac, 0xd9, 0x40, 0x50, 0x05, 0xbb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
    0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x83, 0x19, 0x60, 0x01, 0x00,
    0x04, 0x68, 0xef, 0x8f, 0xcb, 0xfd, 0xf8, 0xf8, 0x00};

void expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

class BitWriter final {
public:
  void bit(bool value) {
    const std::size_t bitInByte = bitCount_ % 8U;
    if (bitInByte == 0U) {
      bytes_.push_back(0U);
    }
    if (value) {
      bytes_.back() = static_cast<std::uint8_t>(
          bytes_.back() | static_cast<std::uint8_t>(1U << (7U - bitInByte)));
    }
    ++bitCount_;
  }

  void bits(std::uint32_t value, std::size_t count) {
    for (std::size_t remaining = count; remaining != 0U; --remaining) {
      bit(((value >> (remaining - 1U)) & 1U) != 0U);
    }
  }

  void unsignedExpGolomb(std::uint32_t value) {
    const std::uint64_t code = static_cast<std::uint64_t>(value) + 1U;
    std::size_t significantBits = 0;
    for (std::uint64_t remaining = code; remaining != 0U; remaining >>= 1U) {
      ++significantBits;
    }
    for (std::size_t index = 1U; index < significantBits; ++index) {
      bit(false);
    }
    bits(static_cast<std::uint32_t>(code), significantBits);
  }

  void signedExpGolomb(std::int32_t value) {
    const std::int64_t wide = value;
    const std::uint32_t encoded =
        value <= 0 ? static_cast<std::uint32_t>(-2 * wide)
                   : static_cast<std::uint32_t>(2 * wide - 1);
    unsignedExpGolomb(encoded);
  }

  [[nodiscard]] std::vector<std::uint8_t> finishRbsp() {
    bit(true);
    while (bitCount_ % 8U != 0U) {
      bit(false);
    }
    std::vector<std::uint8_t> escaped;
    escaped.reserve(bytes_.size());
    std::size_t zeroCount = 0;
    for (const std::uint8_t value : bytes_) {
      if (zeroCount >= 2U && value <= 3U) {
        escaped.push_back(3U);
        zeroCount = 0;
      }
      escaped.push_back(value);
      zeroCount = value == 0U ? zeroCount + 1U : 0U;
    }
    return escaped;
  }

private:
  std::vector<std::uint8_t> bytes_;
  std::size_t bitCount_{0};
};

void appendLength(std::vector<std::uint8_t> &bytes, std::size_t length) {
  bytes.push_back(static_cast<std::uint8_t>((length >> 8U) & 0xFFU));
  bytes.push_back(static_cast<std::uint8_t>(length & 0xFFU));
}

struct ColorSpec {
  bool videoSignalTypePresent{true};
  bool fullRange{false};
  bool descriptionPresent{true};
  std::uint8_t primaries{1};
  std::uint8_t transfer{1};
  std::uint8_t matrix{1};
};

void writeVuiColorPrefix(BitWriter &bits, const ColorSpec &color) {
  bits.bit(false); // aspect_ratio_info_present_flag
  bits.bit(false); // overscan_info_present_flag
  bits.bit(color.videoSignalTypePresent);
  if (color.videoSignalTypePresent) {
    bits.bits(5U, 3U);
    bits.bit(color.fullRange);
    bits.bit(color.descriptionPresent);
    if (color.descriptionPresent) {
      bits.bits(color.primaries, 8U);
      bits.bits(color.transfer, 8U);
      bits.bits(color.matrix, 8U);
    }
  }
}

struct H264SpsSpec {
  std::uint32_t id{0};
  std::uint32_t width{16};
  std::uint32_t height{16};
  std::uint32_t reorderFrames{2};
  std::uint8_t profile{66};
  // AVCLevelIndication, restated in both the SPS and the avcC (the parser
  // cross-checks them). Level 4.0 caps MaxDpbMbs at 32,768, which is under one
  // frame at UHD, so a case above 1080p has to state a level that admits it.
  std::uint8_t level{40};
  std::uint32_t chromaFormat{1};
  std::uint32_t lumaDepthMinusEight{0};
  std::uint32_t chromaDepthMinusEight{0};
  ColorSpec color{};
};

[[nodiscard]] std::vector<std::uint8_t> makeH264Sps(const H264SpsSpec &spec) {
  const std::uint32_t storageWidth = (spec.width + 15U) & ~15U;
  const std::uint32_t storageHeight = (spec.height + 15U) & ~15U;
  const std::uint32_t cropRight = (storageWidth - spec.width) / 2U;
  const std::uint32_t cropBottom = (storageHeight - spec.height) / 2U;

  BitWriter bits;
  bits.bits(spec.profile, 8U);
  bits.bits(0U, 8U);  // constraint flags
  bits.bits(spec.level, 8U);
  bits.unsignedExpGolomb(spec.id);
  if (spec.profile == 100U) {
    bits.unsignedExpGolomb(spec.chromaFormat);
    bits.unsignedExpGolomb(spec.lumaDepthMinusEight);
    bits.unsignedExpGolomb(spec.chromaDepthMinusEight);
    bits.bit(false); // qpprime_y_zero_transform_bypass_flag
    bits.bit(false); // seq_scaling_matrix_present_flag
  }
  bits.unsignedExpGolomb(0U); // log2_max_frame_num_minus4
  bits.unsignedExpGolomb(0U); // pic_order_cnt_type
  bits.unsignedExpGolomb(0U); // log2_max_pic_order_cnt_lsb_minus4
  bits.unsignedExpGolomb(1U); // max_num_ref_frames
  bits.bit(false);            // gaps_in_frame_num_value_allowed_flag
  bits.unsignedExpGolomb(storageWidth / 16U - 1U);
  bits.unsignedExpGolomb(storageHeight / 16U - 1U);
  bits.bit(true); // frame_mbs_only_flag
  bits.bit(true); // direct_8x8_inference_flag
  const bool cropped = cropRight != 0U || cropBottom != 0U;
  bits.bit(cropped);
  if (cropped) {
    bits.unsignedExpGolomb(0U);
    bits.unsignedExpGolomb(cropRight);
    bits.unsignedExpGolomb(0U);
    bits.unsignedExpGolomb(cropBottom);
  }
  bits.bit(true); // vui_parameters_present_flag
  writeVuiColorPrefix(bits, spec.color);
  bits.bit(false); // chroma_loc_info_present_flag
  bits.bit(false); // timing_info_present_flag
  bits.bit(false); // nal_hrd_parameters_present_flag
  bits.bit(false); // vcl_hrd_parameters_present_flag
  bits.bit(false); // pic_struct_present_flag
  bits.bit(true);  // bitstream_restriction_flag
  bits.bit(true);  // motion_vectors_over_pic_boundaries_flag
  bits.unsignedExpGolomb(0U);
  bits.unsignedExpGolomb(0U);
  bits.unsignedExpGolomb(0U);
  bits.unsignedExpGolomb(0U);
  bits.unsignedExpGolomb(spec.reorderFrames);
  bits.unsignedExpGolomb(std::max(1U, spec.reorderFrames));

  std::vector<std::uint8_t> nal{0x67U};
  auto rbsp = bits.finishRbsp();
  nal.insert(nal.end(), rbsp.begin(), rbsp.end());
  return nal;
}

[[nodiscard]] std::vector<std::uint8_t> makeH264Pps(std::uint32_t spsId) {
  BitWriter bits;
  bits.unsignedExpGolomb(0U);
  bits.unsignedExpGolomb(spsId);
  bits.bit(false);            // entropy_coding_mode_flag
  bits.bit(false);            // bottom_field_pic_order_in_frame_present_flag
  bits.unsignedExpGolomb(0U); // num_slice_groups_minus1
  bits.unsignedExpGolomb(0U); // num_ref_idx_l0_default_active_minus1
  bits.unsignedExpGolomb(0U); // num_ref_idx_l1_default_active_minus1
  bits.bit(false);            // weighted_pred_flag
  bits.bits(0U, 2U);          // weighted_bipred_idc
  bits.signedExpGolomb(0);    // pic_init_qp_minus26
  bits.signedExpGolomb(0);    // pic_init_qs_minus26
  bits.signedExpGolomb(0);    // chroma_qp_index_offset
  bits.bit(true);             // deblocking_filter_control_present_flag
  bits.bit(false);            // constrained_intra_pred_flag
  bits.bit(false);            // redundant_pic_cnt_present_flag
  std::vector<std::uint8_t> nal{0x68U};
  auto rbsp = bits.finishRbsp();
  nal.insert(nal.end(), rbsp.begin(), rbsp.end());
  return nal;
}

[[nodiscard]] std::vector<std::uint8_t>
makeAvcC(std::span<const H264SpsSpec> specifications, bool includePps = true) {
  std::vector<std::uint8_t> result{
      1U,    specifications.front().profile,
      0U,    specifications.front().level,
      0xFFU, static_cast<std::uint8_t>(0xE0U | specifications.size())};
  for (const H264SpsSpec &spec : specifications) {
    const auto sps = makeH264Sps(spec);
    appendLength(result, sps.size());
    result.insert(result.end(), sps.begin(), sps.end());
  }
  result.push_back(includePps ? 1U : 0U);
  if (includePps) {
    const auto pps = makeH264Pps(specifications.front().id);
    appendLength(result, pps.size());
    result.insert(result.end(), pps.begin(), pps.end());
  }
  return result;
}

void writeHevcProfileTierLevel(BitWriter &bits, std::uint8_t profile,
                               std::uint8_t level = 120U) {
  bits.bits(profile, 8U);
  bits.bits(0U, 32U);
  bits.bits(0U, 32U);
  bits.bits(0U, 16U);
  bits.bits(level, 8U);
}

[[nodiscard]] std::vector<std::uint8_t> makeHevcVps(std::uint8_t profile) {
  BitWriter bits;
  bits.bits(0U, 4U); // vps_video_parameter_set_id
  bits.bit(true);
  bits.bit(true);
  bits.bits(0U, 6U); // vps_max_layers_minus1
  bits.bits(0U, 3U); // vps_max_sub_layers_minus1
  bits.bit(true);
  bits.bits(0xFFFFU, 16U);
  writeHevcProfileTierLevel(bits, profile);
  bits.bit(false);            // vps_sub_layer_ordering_info_present_flag
  bits.unsignedExpGolomb(1U); // vps_max_dec_pic_buffering_minus1
  bits.unsignedExpGolomb(0U); // vps_max_num_reorder_pics
  bits.unsignedExpGolomb(0U); // vps_max_latency_increase_plus1
  bits.bits(0U, 6U);          // vps_max_layer_id
  bits.unsignedExpGolomb(0U); // vps_num_layer_sets_minus1
  bits.bit(false);            // vps_timing_info_present_flag
  bits.bit(false);            // vps_extension_flag
  std::vector<std::uint8_t> nal{0x40U, 0x01U};
  auto rbsp = bits.finishRbsp();
  nal.insert(nal.end(), rbsp.begin(), rbsp.end());
  return nal;
}

struct HevcSpsSpec {
  std::uint32_t id{0};
  std::uint32_t width{16};
  std::uint32_t height{16};
  std::uint32_t reorderFrames{2};
  std::uint32_t chromaFormat{1};
  std::uint8_t depthMinusEight{0};
  std::int32_t initQpMinus26{0};
  ColorSpec color{};
};

[[nodiscard]] std::vector<std::uint8_t> makeHevcSps(const HevcSpsSpec &spec) {
  const std::uint8_t profile = spec.depthMinusEight == 2U ? 2U : 1U;
  BitWriter bits;
  bits.bits(0U, 4U); // sps_video_parameter_set_id
  bits.bits(0U, 3U); // sps_max_sub_layers_minus1
  bits.bit(true);
  writeHevcProfileTierLevel(bits, profile);
  bits.unsignedExpGolomb(spec.id);
  bits.unsignedExpGolomb(spec.chromaFormat);
  bits.unsignedExpGolomb(spec.width);
  bits.unsignedExpGolomb(spec.height);
  bits.bit(false); // conformance_window_flag
  bits.unsignedExpGolomb(spec.depthMinusEight);
  bits.unsignedExpGolomb(spec.depthMinusEight);
  bits.unsignedExpGolomb(0U); // log2_max_pic_order_cnt_lsb_minus4
  bits.bit(false);            // sps_sub_layer_ordering_info_present_flag
  bits.unsignedExpGolomb(std::max(1U, spec.reorderFrames));
  bits.unsignedExpGolomb(spec.reorderFrames);
  bits.unsignedExpGolomb(0U); // sps_max_latency_increase_plus1
  for (std::size_t index = 0; index < 6U; ++index) {
    bits.unsignedExpGolomb(0U);
  }
  bits.bit(false);            // scaling_list_enabled_flag
  bits.bit(false);            // amp_enabled_flag
  bits.bit(false);            // sample_adaptive_offset_enabled_flag
  bits.bit(false);            // pcm_enabled_flag
  bits.unsignedExpGolomb(0U); // num_short_term_ref_pic_sets
  bits.bit(false);            // long_term_ref_pics_present_flag
  bits.bit(false);            // sps_temporal_mvp_enabled_flag
  bits.bit(false);            // strong_intra_smoothing_enabled_flag
  bits.bit(true);             // vui_parameters_present_flag
  writeVuiColorPrefix(bits, spec.color);
  bits.bit(false); // chroma_loc_info_present_flag
  bits.bit(false); // neutral_chroma_indication_flag
  bits.bit(false); // field_seq_flag
  bits.bit(false); // frame_field_info_present_flag
  bits.bit(false); // default_display_window_flag
  bits.bit(false); // vui_timing_info_present_flag
  bits.bit(false); // bitstream_restriction_flag
  bits.bit(false); // sps_extension_present_flag

  std::vector<std::uint8_t> nal{0x42U, 0x01U};
  auto rbsp = bits.finishRbsp();
  nal.insert(nal.end(), rbsp.begin(), rbsp.end());
  return nal;
}

[[nodiscard]] std::vector<std::uint8_t>
makeHevcPps(std::uint32_t spsId, std::int32_t initQpMinus26) {
  BitWriter bits;
  bits.unsignedExpGolomb(0U);
  bits.unsignedExpGolomb(spsId);
  bits.bit(false);            // dependent_slice_segments_enabled_flag
  bits.bit(false);            // output_flag_present_flag
  bits.bits(0U, 3U);          // num_extra_slice_header_bits
  bits.bit(false);            // sign_data_hiding_enabled_flag
  bits.bit(false);            // cabac_init_present_flag
  bits.unsignedExpGolomb(0U); // num_ref_idx_l0_default_active_minus1
  bits.unsignedExpGolomb(0U); // num_ref_idx_l1_default_active_minus1
  bits.signedExpGolomb(initQpMinus26);
  bits.bit(false);            // constrained_intra_pred_flag
  bits.bit(false);            // transform_skip_enabled_flag
  bits.bit(false);            // cu_qp_delta_enabled_flag
  bits.signedExpGolomb(0);    // pps_cb_qp_offset
  bits.signedExpGolomb(0);    // pps_cr_qp_offset
  bits.bit(false);            // pps_slice_chroma_qp_offsets_present_flag
  bits.bit(false);            // weighted_pred_flag
  bits.bit(false);            // weighted_bipred_flag
  bits.bit(false);            // transquant_bypass_enabled_flag
  bits.bit(false);            // tiles_enabled_flag
  bits.bit(false);            // entropy_coding_sync_enabled_flag
  bits.bit(true);             // pps_loop_filter_across_slices_enabled_flag
  bits.bit(false);            // deblocking_filter_control_present_flag
  bits.bit(false);            // pps_scaling_list_data_present_flag
  bits.bit(false);            // lists_modification_present_flag
  bits.unsignedExpGolomb(0U); // log2_parallel_merge_level_minus2
  bits.bit(false);            // slice_segment_header_extension_present_flag
  bits.bit(false);            // pps_extension_present_flag
  std::vector<std::uint8_t> nal{0x44U, 0x01U};
  auto rbsp = bits.finishRbsp();
  nal.insert(nal.end(), rbsp.begin(), rbsp.end());
  return nal;
}

void appendHevcArray(std::vector<std::uint8_t> &record, std::uint8_t nalType,
                     std::span<const std::vector<std::uint8_t>> nals) {
  record.push_back(static_cast<std::uint8_t>(0x80U | nalType));
  appendLength(record, nals.size());
  for (const auto &nal : nals) {
    appendLength(record, nal.size());
    record.insert(record.end(), nal.begin(), nal.end());
  }
}

[[nodiscard]] std::vector<std::uint8_t>
makeHvcC(std::span<const HevcSpsSpec> specifications, bool includeVps = true,
         bool includeSps = true, bool includePps = true) {
  const std::uint8_t depth = specifications.front().depthMinusEight;
  const std::uint8_t profile = depth == 2U ? 2U : 1U;
  std::vector<std::uint8_t> result(23U, 0U);
  result[0] = 1U;
  result[1] = profile;
  result[12] = 120U;
  result[13] = 0xF0U;
  result[15] = 0xFCU;
  result[16] = 0xFDU;
  result[17] = static_cast<std::uint8_t>(0xF8U | depth);
  result[18] = static_cast<std::uint8_t>(0xF8U | depth);
  result[21] = 0x0FU; // one temporal layer, nested, four-byte lengths
  result[22] = static_cast<std::uint8_t>(static_cast<unsigned>(includeVps) +
                                         static_cast<unsigned>(includeSps) +
                                         static_cast<unsigned>(includePps));

  if (includeVps) {
    const std::array vps{makeHevcVps(profile)};
    appendHevcArray(result, 32U, vps);
  }
  if (includeSps) {
    std::vector<std::vector<std::uint8_t>> sps;
    sps.reserve(specifications.size());
    for (const HevcSpsSpec &spec : specifications) {
      sps.push_back(makeHevcSps(spec));
    }
    appendHevcArray(result, 33U, sps);
  }
  if (includePps) {
    const std::array pps{makeHevcPps(specifications.front().id,
                                     specifications.front().initQpMinus26)};
    appendHevcArray(result, 34U, pps);
  }
  return result;
}

[[nodiscard]] std::span<const std::byte>
byteView(const std::vector<std::uint8_t> &bytes) noexcept {
  return {reinterpret_cast<const std::byte *>(bytes.data()), bytes.size()};
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectAvc(const std::vector<std::uint8_t> &bytes,
           VideoCodecConfigurationLimits limits = {}) noexcept {
  return inspectVideoCodecConfiguration(MediaCodec::H264,
                                        MediaCodecConfigurationKind::AvcC,
                                        byteView(bytes), limits);
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectHevc(const std::vector<std::uint8_t> &bytes,
            VideoCodecConfigurationLimits limits = {}) noexcept {
  return inspectVideoCodecConfiguration(MediaCodec::Hevc,
                                        MediaCodecConfigurationKind::HvcC,
                                        byteView(bytes), limits);
}

void expectError(const VideoCodecConfigurationInspection &inspection,
                 VideoCodecConfigurationError error, const char *message) {
  expect(!inspection.admitted() && !inspection.facts &&
             inspection.error == error,
         message);
}

[[nodiscard]] std::optional<std::size_t>
hevcArrayOffset(const std::vector<std::uint8_t> &record,
                std::uint8_t wantedType) {
  if (record.size() < 23U) {
    return std::nullopt;
  }
  std::size_t offset = 23U;
  for (std::uint32_t array = 0; array < record[22]; ++array) {
    if (record.size() - offset < 3U) {
      return std::nullopt;
    }
    const std::uint8_t type = record[offset] & 0x3FU;
    if (type == wantedType) {
      return offset;
    }
    const std::uint32_t count =
        (static_cast<std::uint32_t>(record[offset + 1U]) << 8U) |
        record[offset + 2U];
    offset += 3U;
    for (std::uint32_t index = 0; index < count; ++index) {
      if (record.size() - offset < 2U) {
        return std::nullopt;
      }
      const std::size_t length =
          (static_cast<std::size_t>(record[offset]) << 8U) |
          record[offset + 1U];
      offset += 2U;
      if (length > record.size() - offset) {
        return std::nullopt;
      }
      offset += length;
    }
  }
  return std::nullopt;
}

[[nodiscard]] std::optional<std::pair<std::size_t, std::size_t>>
hevcFirstNalRange(const std::vector<std::uint8_t> &record,
                  std::uint8_t wantedType) {
  const auto arrayOffset = hevcArrayOffset(record, wantedType);
  if (!arrayOffset || record.size() - *arrayOffset < 5U) {
    return std::nullopt;
  }
  const std::size_t lengthOffset = *arrayOffset + 3U;
  const std::size_t length =
      (static_cast<std::size_t>(record[lengthOffset]) << 8U) |
      record[lengthOffset + 1U];
  const std::size_t nalOffset = lengthOffset + 2U;
  if (length > record.size() - nalOffset) {
    return std::nullopt;
  }
  return std::pair{nalOffset, length};
}

void appendByteToHevcNal(std::vector<std::uint8_t> &record,
                         std::uint8_t nalType, std::uint8_t value) {
  const auto arrayOffset = hevcArrayOffset(record, nalType);
  const auto range = hevcFirstNalRange(record, nalType);
  expect(arrayOffset.has_value() && range.has_value(),
         "test locates HEVC NAL for tail mutation");
  if (!arrayOffset || !range) {
    return;
  }
  const std::size_t lengthOffset = *arrayOffset + 3U;
  const std::size_t newLength = range->second + 1U;
  record[lengthOffset] = static_cast<std::uint8_t>((newLength >> 8U) & 0xFFU);
  record[lengthOffset + 1U] = static_cast<std::uint8_t>(newLength & 0xFFU);
  record.insert(record.begin() +
                    static_cast<std::ptrdiff_t>(range->first + range->second),
                value);
}

void removeLastByteFromHevcNal(std::vector<std::uint8_t> &record,
                               std::uint8_t nalType) {
  const auto arrayOffset = hevcArrayOffset(record, nalType);
  const auto range = hevcFirstNalRange(record, nalType);
  expect(arrayOffset.has_value() && range.has_value() && range->second > 2U,
         "test locates nonempty HEVC NAL for truncation");
  if (!arrayOffset || !range || range->second <= 2U) {
    return;
  }
  const std::size_t lengthOffset = *arrayOffset + 3U;
  const std::size_t newLength = range->second - 1U;
  record[lengthOffset] = static_cast<std::uint8_t>((newLength >> 8U) & 0xFFU);
  record[lengthOffset + 1U] = static_cast<std::uint8_t>(newLength & 0xFFU);
  record.erase(record.begin() +
               static_cast<std::ptrdiff_t>(range->first + range->second - 1U));
}

[[nodiscard]] std::optional<std::pair<std::size_t, std::size_t>>
avcFirstPpsRange(const std::vector<std::uint8_t> &record) {
  if (record.size() < 8U) {
    return std::nullopt;
  }
  std::size_t offset = 6U;
  const std::uint32_t spsCount = record[5] & 0x1FU;
  for (std::uint32_t index = 0; index < spsCount; ++index) {
    if (record.size() - offset < 2U) {
      return std::nullopt;
    }
    const std::size_t length =
        (static_cast<std::size_t>(record[offset]) << 8U) | record[offset + 1U];
    offset += 2U;
    if (length > record.size() - offset) {
      return std::nullopt;
    }
    offset += length;
  }
  if (offset >= record.size() || record[offset++] == 0U ||
      record.size() - offset < 2U) {
    return std::nullopt;
  }
  const std::size_t length =
      (static_cast<std::size_t>(record[offset]) << 8U) | record[offset + 1U];
  const std::size_t nalOffset = offset + 2U;
  if (length > record.size() - nalOffset) {
    return std::nullopt;
  }
  return std::pair{nalOffset, length};
}

void appendByteToAvcPps(std::vector<std::uint8_t> &record, std::uint8_t value) {
  const auto range = avcFirstPpsRange(record);
  expect(range.has_value(), "test locates H.264 PPS for tail mutation");
  if (!range) {
    return;
  }
  const std::size_t lengthOffset = range->first - 2U;
  const std::size_t newLength = range->second + 1U;
  record[lengthOffset] = static_cast<std::uint8_t>((newLength >> 8U) & 0xFFU);
  record[lengthOffset + 1U] = static_cast<std::uint8_t>(newLength & 0xFFU);
  record.insert(record.begin() +
                    static_cast<std::ptrdiff_t>(range->first + range->second),
                value);
}

void removeLastByteFromAvcPps(std::vector<std::uint8_t> &record) {
  const auto range = avcFirstPpsRange(record);
  expect(range.has_value() && range->second > 1U,
         "test locates nonempty H.264 PPS for truncation");
  if (!range || range->second <= 1U) {
    return;
  }
  const std::size_t lengthOffset = range->first - 2U;
  const std::size_t newLength = range->second - 1U;
  record[lengthOffset] = static_cast<std::uint8_t>((newLength >> 8U) & 0xFFU);
  record[lengthOffset + 1U] = static_cast<std::uint8_t>(newLength & 0xFFU);
  record.erase(record.begin() +
               static_cast<std::ptrdiff_t>(range->first + range->second - 1U));
}

void testApiAndHardBounds() {
  static_assert(kMaximumVideoCodecConfigurationBytes == 256U * 1024U);
  // The 4K-class v1 envelope (revised 2026-08-21 from 1920x1080/2,073,600).
  static_assert(kMaximumVideoCodecWidth == 4096U);
  static_assert(kMaximumVideoCodecHeight == 2320U);
  static_assert(kMaximumVideoCodecPixels == 4096ULL * 2320ULL);
  static_assert(kMaximumVideoCodecPixels == 9'502'720ULL);
  static_assert(kMaximumVideoCodecReorderFrames == 16U);
  static_assert(noexcept(inspectVideoCodecConfiguration(
      MediaCodec::H264, MediaCodecConfigurationKind::AvcC, {})));

  // VP9 is an admitted codec now, so this case proves the kind gate rather
  // than the codec gate: VP9 facts may only be read out of a vpcC.
  expectError(inspectVideoCodecConfiguration(
                  MediaCodec::Vp9, MediaCodecConfigurationKind::CodecPrivate,
                  std::array{std::byte{1U}}),
              VideoCodecConfigurationError::ConfigurationKindMismatch,
              "VP9 facts are only read from a vpcC record");
  expectError(inspectVideoCodecConfiguration(
                  MediaCodec::Av1, MediaCodecConfigurationKind::VpcC,
                  std::array{std::byte{1U}}),
              VideoCodecConfigurationError::ConfigurationKindMismatch,
              "AV1 facts are only read from an av1C record");
  expectError(inspectVideoCodecConfiguration(
                  MediaCodec::Aac, MediaCodecConfigurationKind::CodecPrivate,
                  std::array{std::byte{1U}}),
              VideoCodecConfigurationError::UnsupportedCodec,
              "unsupported codec is rejected before record parsing");
  expectError(inspectVideoCodecConfiguration(
                  MediaCodec::Av1, MediaCodecConfigurationKind::Av1C, {}),
              VideoCodecConfigurationError::EmptyConfiguration,
              "empty AV1 configuration is rejected exactly");
  static_assert(noexcept(inspectVp9BitstreamKeyframe({})));
  expectError(inspectVp9BitstreamKeyframe({}),
              VideoCodecConfigurationError::EmptyConfiguration,
              "empty VP9 keyframe is rejected exactly");
  expectError(inspectVideoCodecConfiguration(MediaCodec::H264,
                                             MediaCodecConfigurationKind::HvcC,
                                             std::array{std::byte{1U}}),
              VideoCodecConfigurationError::ConfigurationKindMismatch,
              "codec and configuration-record kind must agree");
  expectError(inspectVideoCodecConfiguration(
                  MediaCodec::H264, MediaCodecConfigurationKind::AvcC, {}),
              VideoCodecConfigurationError::EmptyConfiguration,
              "empty configuration is rejected exactly");
}

void testCompactH264() {
  const std::array specification{
      H264SpsSpec{.width = 1920U, .height = 1080U, .reorderFrames = 2U}};
  const auto avcc = makeAvcC(specification);
  const auto admitted = inspectAvc(avcc);
  expect(admitted.admitted(), "compact complete H.264 avcC is admitted");
  if (admitted.facts) {
    const auto &facts = *admitted.facts;
    expect(
        facts.codec == MediaCodec::H264 &&
            facts.kind == MediaCodecConfigurationKind::AvcC &&
            facts.sampleFormat == MediaVideoSampleFormat::Yuv420EightBit &&
            facts.width == 1920U && facts.height == 1080U &&
            facts.bitDepth == 8U && facts.nalLengthBytes == 4U &&
            facts.maximumReorderFrames == 2U && facts.vpsCount == 0U &&
            facts.spsCount == 1U && facts.ppsCount == 1U,
        "H.264 codec, cropped dimensions, format, and reorder facts are exact");
    expect(facts.color.videoSignalTypePresent && !facts.color.fullRange &&
               facts.color.colorDescriptionPresent &&
               facts.color.colorPrimaries == 1U &&
               facts.color.transferCharacteristics == 1U &&
               facts.color.matrixCoefficients == 1U,
           "H.264 explicit narrow-range BT.709 SDR VUI facts are exact");
  }

  allocation_probe::calls = 0U;
  allocation_probe::active = true;
  const auto allocationFree = inspectAvc(avcc);
  allocation_probe::active = false;
  expect(allocationFree.admitted() && allocation_probe::calls == 0U,
         "H.264 configuration inspection performs no heap allocation");

  VideoCodecConfigurationLimits oneReorder;
  oneReorder.maximumReorderFrames = 1U;
  expectError(inspectAvc(avcc, oneReorder),
              VideoCodecConfigurationError::ReorderLimitExceeded,
              "H.264 SPS reorder depth honors a tightened bound");
  VideoCodecConfigurationLimits shortConfig;
  shortConfig.maximumConfigurationBytes = avcc.size() - 1U;
  expectError(inspectAvc(avcc, shortConfig),
              VideoCodecConfigurationError::ConfigurationTooLarge,
              "H.264 avcC honors the exact configuration-byte bound");

  const std::array highSpecification{H264SpsSpec{.profile = 100U}};
  const auto high = inspectAvc(makeAvcC(highSpecification));
  expect(high.admitted() && high.facts && high.facts->bitDepth == 8U &&
             high.facts->sampleFormat == MediaVideoSampleFormat::Yuv420EightBit,
         "H.264 High profile explicitly proves 4:2:0 8-bit format");

  const auto repositorySample = inspectVideoCodecConfiguration(
      MediaCodec::H264, MediaCodecConfigurationKind::AvcC,
      {reinterpret_cast<const std::byte *>(kRepositorySampleAvcC.data()),
       kRepositorySampleAvcC.size()});
  expect(repositorySample.admitted() && repositorySample.facts &&
             repositorySample.facts->width == 1280U &&
             repositorySample.facts->height == 720U &&
             repositorySample.facts->maximumReorderFrames == 2U,
         "encoder-produced High avcC with complete PPS syntax is admitted");
}

void testH264Rejections() {
  const std::array validSpec{H264SpsSpec{}};
  const auto valid = makeAvcC(validSpec);

  auto reserved = valid;
  reserved[4] &= 0x7FU;
  expectError(inspectAvc(reserved),
              VideoCodecConfigurationError::MalformedRecord,
              "H.264 avcC reserved bits are enforced");

  auto trailing = valid;
  trailing.push_back(0U);
  expectError(inspectAvc(trailing),
              VideoCodecConfigurationError::MalformedRecord,
              "H.264 avcC trailing bytes are rejected");

  auto ptlMismatch = valid;
  ptlMismatch[3] = 41U;
  expectError(inspectAvc(ptlMismatch),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "H.264 avcC summary and SPS PTL must match");

  auto reservedCompatibility = valid;
  reservedCompatibility[2] = 0x03U;
  // Keep the record/SPS summary match so this isolates reserved_zero_2bits.
  reservedCompatibility[10] = 0x03U;
  expectError(inspectAvc(reservedCompatibility),
              VideoCodecConfigurationError::MalformedRecord,
              "H.264 profile_compatibility reserved_zero_2bits must be zero");

  expectError(inspectAvc(makeAvcC(validSpec, false)),
              VideoCodecConfigurationError::MissingParameterSet,
              "H.264 requires PPS as well as SPS");

  auto truncated = valid;
  truncated.pop_back();
  expectError(inspectAvc(truncated),
              VideoCodecConfigurationError::MalformedRecord,
              "truncated H.264 parameter-set payload is rejected");

  auto ppsTail = valid;
  appendByteToAvcPps(ppsTail, 0xC0U);
  expectError(inspectAvc(ppsTail),
              VideoCodecConfigurationError::MalformedRecord,
              "H.264 PPS garbage after rbsp_trailing_bits is rejected");

  auto ppsZeroTail = valid;
  appendByteToAvcPps(ppsZeroTail, 0x00U);
  expectError(inspectAvc(ppsZeroTail),
              VideoCodecConfigurationError::MalformedRecord,
              "H.264 PPS zero tail after rbsp_trailing_bits is rejected");

  auto truncatedPpsSyntax = valid;
  removeLastByteFromAvcPps(truncatedPpsSyntax);
  expectError(inspectAvc(truncatedPpsSyntax),
              VideoCodecConfigurationError::MalformedRecord,
              "H.264 PPS truncated before rbsp_trailing_bits is rejected");

  const std::array disagreeing{
      H264SpsSpec{.id = 0U, .width = 16U, .height = 16U},
      H264SpsSpec{.id = 1U, .width = 32U, .height = 16U}};
  expectError(inspectAvc(makeAvcC(disagreeing)),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "multiple H.264 SPS dimensions must agree");

  const std::array reorderDisagreement{
      H264SpsSpec{.id = 0U, .reorderFrames = 0U},
      H264SpsSpec{.id = 1U, .reorderFrames = 5U}};
  expectError(inspectAvc(makeAvcC(reorderDisagreement)),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "multiple H.264 SPS reorder facts must agree");

  const std::array hdr{H264SpsSpec{.color = ColorSpec{.transfer = 16U}}};
  expectError(inspectAvc(makeAvcC(hdr)),
              VideoCodecConfigurationError::UnsupportedColorDescription,
              "explicit H.264 PQ color description is rejected");

  const std::array wrongChroma{
      H264SpsSpec{.profile = 100U, .chromaFormat = 2U}};
  expectError(inspectAvc(makeAvcC(wrongChroma)),
              VideoCodecConfigurationError::UnsupportedChromaFormat,
              "H.264 High SPS must prove 4:2:0 chroma");

  const std::array wrongDepth{H264SpsSpec{
      .profile = 100U, .lumaDepthMinusEight = 2U, .chromaDepthMinusEight = 2U}};
  expectError(inspectAvc(makeAvcC(wrongDepth)),
              VideoCodecConfigurationError::UnsupportedBitDepth,
              "H.264 remains restricted to its current 8-bit contract");

  const std::array uhd{
      H264SpsSpec{.width = 3840U, .height = 2160U, .level = 51U}};
  expect(inspectAvc(makeAvcC(uhd)).admitted(),
         "H.264 UHD is inside the 4096x2320 v1 envelope");

  const std::array oversized{
      H264SpsSpec{.width = 7680U, .height = 4320U, .level = 62U}};
  expectError(inspectAvc(makeAvcC(oversized)),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "H.264 dimensions remain capped at 4096x2320");
}

void testCompactHevcMainAndMain10() {
  const std::array mainSpec{
      HevcSpsSpec{.width = 1920U, .height = 1080U, .reorderFrames = 2U}};
  const auto main = inspectHevc(makeHvcC(mainSpec));
  expect(main.admitted(), "compact complete HEVC Main hvcC is admitted");
  if (main.facts) {
    const auto &facts = *main.facts;
    expect(facts.codec == MediaCodec::Hevc &&
               facts.kind == MediaCodecConfigurationKind::HvcC &&
               facts.sampleFormat == MediaVideoSampleFormat::Yuv420EightBit &&
               facts.width == 1920U && facts.height == 1080U &&
               facts.bitDepth == 8U && facts.nalLengthBytes == 4U &&
               facts.maximumReorderFrames == 2U && facts.vpsCount == 1U &&
               facts.spsCount == 1U && facts.ppsCount == 1U,
           "HEVC Main facts include exact dimensions, parameter sets, and "
           "reorder depth");
  }

  const std::array main10Spec{
      HevcSpsSpec{.width = 1280U,
                  .height = 720U,
                  .reorderFrames = 3U,
                  .depthMinusEight = 2U,
                  .color = ColorSpec{.fullRange = true, .matrix = 6U}}};
  const auto main10 = inspectHevc(makeHvcC(main10Spec));
  expect(main10.admitted(), "compact complete HEVC Main10 hvcC is admitted");
  if (main10.facts) {
    expect(main10.facts->sampleFormat == MediaVideoSampleFormat::Yuv420TenBit &&
               main10.facts->bitDepth == 10U && main10.facts->width == 1280U &&
               main10.facts->height == 720U &&
               main10.facts->maximumReorderFrames == 3U &&
               main10.facts->color.fullRange &&
               main10.facts->color.matrixCoefficients == 6U,
           "HEVC Main10 retains exact 10-bit and explicit SDR VUI facts");
  }

  const auto main10Record = makeHvcC(main10Spec);
  allocation_probe::calls = 0U;
  allocation_probe::active = true;
  const auto allocationFree = inspectHevc(main10Record);
  allocation_probe::active = false;
  expect(allocationFree.admitted() && allocation_probe::calls == 0U,
         "HEVC configuration inspection performs no heap allocation");

  const std::array unspecifiedColor{
      HevcSpsSpec{.depthMinusEight = 2U,
                  .color = ColorSpec{.videoSignalTypePresent = false}}};
  const auto unspecified = inspectHevc(makeHvcC(unspecifiedColor));
  expect(unspecified.admitted() && unspecified.facts &&
             !unspecified.facts->color.videoSignalTypePresent &&
             !unspecified.facts->color.colorDescriptionPresent,
         "absent HEVC VUI color remains absent rather than inferred SDR");

  const std::array mainMinimumQp{HevcSpsSpec{.initQpMinus26 = -26}};
  expect(inspectHevc(makeHvcC(mainMinimumQp)).admitted(),
         "HEVC Main PPS admits its exact minimum init_qp_minus26");
  const std::array main10MinimumQp{
      HevcSpsSpec{.depthMinusEight = 2U, .initQpMinus26 = -38}};
  expect(
      inspectHevc(makeHvcC(main10MinimumQp)).admitted(),
      "HEVC Main10 PPS admits its bit-depth-derived minimum init_qp_minus26");
}

void testHevcRejections() {
  const std::array validSpec{HevcSpsSpec{}};
  const auto valid = makeHvcC(validSpec);

  expectError(inspectHevc(makeHvcC(validSpec, false, true, true)),
              VideoCodecConfigurationError::MissingParameterSet,
              "HEVC requires VPS");
  expectError(inspectHevc(makeHvcC(validSpec, true, false, true)),
              VideoCodecConfigurationError::MissingParameterSet,
              "HEVC requires SPS");
  expectError(inspectHevc(makeHvcC(validSpec, true, true, false)),
              VideoCodecConfigurationError::MissingParameterSet,
              "HEVC requires PPS");

  auto reserved = valid;
  reserved[13] &= 0x0FU;
  expectError(inspectHevc(reserved),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC hvcC reserved bits are enforced");

  auto trailing = valid;
  trailing.push_back(0U);
  expectError(inspectHevc(trailing),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC hvcC trailing bytes are rejected");

  auto vpsTail = valid;
  appendByteToHevcNal(vpsTail, 32U, 0xC0U);
  expectError(inspectHevc(vpsTail),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC VPS garbage after rbsp_trailing_bits is rejected");

  auto vpsZeroTail = valid;
  appendByteToHevcNal(vpsZeroTail, 32U, 0x00U);
  expectError(inspectHevc(vpsZeroTail),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC VPS zero tail after rbsp_trailing_bits is rejected");

  auto truncatedVpsSyntax = valid;
  removeLastByteFromHevcNal(truncatedVpsSyntax, 32U);
  expectError(inspectHevc(truncatedVpsSyntax),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC VPS truncated before rbsp_trailing_bits is rejected");

  auto ppsTail = valid;
  appendByteToHevcNal(ppsTail, 34U, 0xC0U);
  expectError(inspectHevc(ppsTail),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC PPS garbage after rbsp_trailing_bits is rejected");

  auto ppsZeroTail = valid;
  appendByteToHevcNal(ppsZeroTail, 34U, 0x00U);
  expectError(inspectHevc(ppsZeroTail),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC PPS zero tail after rbsp_trailing_bits is rejected");

  auto truncatedPpsSyntax = valid;
  removeLastByteFromHevcNal(truncatedPpsSyntax, 34U);
  expectError(inspectHevc(truncatedPpsSyntax),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC PPS truncated before rbsp_trailing_bits is rejected");

  auto arrayReserved = valid;
  const auto vpsArray = hevcArrayOffset(arrayReserved, 32U);
  expect(vpsArray.has_value(), "test locates HEVC VPS array");
  if (vpsArray) {
    arrayReserved[*vpsArray] |= 0x40U;
    expectError(inspectHevc(arrayReserved),
                VideoCodecConfigurationError::MalformedRecord,
                "HEVC array reserved bit is rejected");
  }

  // array_completeness is a muxer convention, not a decodability property.
  // ISO/IEC 14496-15 permits zero to mean the elementary stream may also carry
  // parameter sets in band. One stream-copied HEVC stream produces hvcC
  // records that are byte-identical in MP4 and Matroska apart from exactly
  // this bit, so a cleared bit is admitted rather than rejected.
  auto incompleteArray = valid;
  const auto spsArray = hevcArrayOffset(incompleteArray, 33U);
  expect(spsArray.has_value(), "test locates HEVC SPS array");
  if (spsArray) {
    incompleteArray[*spsArray] &= 0x7FU;
    const auto inspection = inspectHevc(incompleteArray);
    expect(inspection.admitted() && inspection.facts,
           "HEVC parameter-set arrays may clear array_completeness");
  }

  auto ptlMismatch = valid;
  ptlMismatch[12] = 121U;
  expectError(inspectHevc(ptlMismatch),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "HEVC hvcC, VPS, and SPS PTL must match");

  auto temporalMismatch = valid;
  temporalMismatch[21] &= 0xFBU;
  expectError(inspectHevc(temporalMismatch),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "HEVC hvcC temporal nesting must match VPS and SPS");

  auto wrongNal = valid;
  if (spsArray) {
    const std::size_t nalOffset = *spsArray + 5U;
    wrongNal[nalOffset] = 0x40U;
    expectError(inspectHevc(wrongNal),
                VideoCodecConfigurationError::MalformedRecord,
                "HEVC NAL header must match its array type");
  }

  auto truncated = valid;
  truncated.pop_back();
  expectError(inspectHevc(truncated),
              VideoCodecConfigurationError::MalformedRecord,
              "truncated HEVC parameter-set payload is rejected");

  const std::array disagreeing{
      HevcSpsSpec{.id = 0U, .width = 16U, .height = 16U},
      HevcSpsSpec{.id = 1U, .width = 32U, .height = 16U}};
  expectError(inspectHevc(makeHvcC(disagreeing)),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "multiple HEVC SPS dimensions must agree");

  const std::array reorderDisagreement{
      HevcSpsSpec{.id = 0U, .reorderFrames = 0U},
      HevcSpsSpec{.id = 1U, .reorderFrames = 5U}};
  expectError(inspectHevc(makeHvcC(reorderDisagreement)),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "multiple HEVC SPS reorder facts must agree");

  const std::array hdr{HevcSpsSpec{
      .color = ColorSpec{.primaries = 9U, .transfer = 16U, .matrix = 9U}}};
  expectError(inspectHevc(makeHvcC(hdr)),
              VideoCodecConfigurationError::UnsupportedColorDescription,
              "explicit HEVC BT.2020/PQ color description is rejected");

  // SMPTE 170M primaries and transfer (6/6) with the BT.601 matrix are the
  // ordinary SD description and are admitted through the bitstream gate;
  // BT.470BG primaries (5) stay refused because one BT.601 primaries
  // enumerator cannot carry 625-line chromaticities.
  const std::array sd{HevcSpsSpec{
      .color = ColorSpec{.primaries = 6U, .transfer = 6U, .matrix = 6U}}};
  expect(inspectHevc(makeHvcC(sd)).admitted(),
         "SMPTE 170M primaries and transfer are admitted");
  const std::array pal{HevcSpsSpec{
      .color = ColorSpec{.primaries = 5U, .transfer = 6U, .matrix = 5U}}};
  expectError(inspectHevc(makeHvcC(pal)),
              VideoCodecConfigurationError::UnsupportedColorDescription,
              "BT.470BG primaries stay refused");

  const std::array uhdHevc{HevcSpsSpec{.width = 3840U, .height = 2160U}};
  expect(inspectHevc(makeHvcC(uhdHevc)).admitted(),
         "HEVC UHD is inside the 4096x2320 v1 envelope");

  const std::array oversized{HevcSpsSpec{.width = 4097U, .height = 2160U}};
  expectError(inspectHevc(makeHvcC(oversized)),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "HEVC dimensions remain capped at 4096x2320");

  const std::array wrongChroma{HevcSpsSpec{.chromaFormat = 2U}};
  expectError(inspectHevc(makeHvcC(wrongChroma)),
              VideoCodecConfigurationError::UnsupportedChromaFormat,
              "HEVC SPS must prove 4:2:0 chroma");

  const std::array wrongDepth{HevcSpsSpec{.depthMinusEight = 4U}};
  expectError(inspectHevc(makeHvcC(wrongDepth)),
              VideoCodecConfigurationError::UnsupportedBitDepth,
              "HEVC remains restricted to 8-bit Main or 10-bit Main10");

  const std::array mainBelowMinimumQp{HevcSpsSpec{.initQpMinus26 = -27}};
  expectError(inspectHevc(makeHvcC(mainBelowMinimumQp)),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC Main PPS rejects init_qp_minus26 below -26");
  const std::array main10BelowMinimumQp{
      HevcSpsSpec{.depthMinusEight = 2U, .initQpMinus26 = -39}};
  expectError(inspectHevc(makeHvcC(main10BelowMinimumQp)),
              VideoCodecConfigurationError::MalformedRecord,
              "HEVC Main10 PPS rejects init_qp_minus26 below -38");

  VideoCodecConfigurationLimits tightPixels;
  tightPixels.maximumPixels = 15U * 16U;
  expectError(inspectHevc(valid, tightPixels),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "HEVC SPS dimensions honor a tightened pixel-count bound");

  const std::array reordered{HevcSpsSpec{.reorderFrames = 3U}};
  const auto reorderedRecord = makeHvcC(reordered);
  VideoCodecConfigurationLimits twoReorder;
  twoReorder.maximumReorderFrames = 2U;
  expectError(inspectHevc(reorderedRecord, twoReorder),
              VideoCodecConfigurationError::ReorderLimitExceeded,
              "HEVC SPS reorder depth honors a tightened bound");

  auto summaryDepthMismatch = makeHvcC(validSpec);
  summaryDepthMismatch[1] = 2U;
  summaryDepthMismatch[17] = 0xFAU;
  summaryDepthMismatch[18] = 0xFAU;
  expectError(inspectHevc(summaryDepthMismatch),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "HEVC summary profile/depth cannot contradict its VPS/SPS");
}


// ---------------------------------------------------------------------------
// AV1 and VP9.
// ---------------------------------------------------------------------------

struct PlainBitWriter {
  std::vector<std::uint8_t> bytes;
  std::size_t bitCount{0};

  void put(std::uint32_t value, std::size_t count) {
    for (std::size_t index = count; index-- > 0;) {
      if (bitCount % 8U == 0U) {
        bytes.push_back(0U);
      }
      const std::uint32_t bit = (value >> index) & 1U;
      bytes.back() = static_cast<std::uint8_t>(
          bytes.back() | (bit << (7U - (bitCount % 8U))));
      ++bitCount;
    }
  }

  void putTrailingBits() {
    put(1U, 1U);
    while (bitCount % 8U != 0U) {
      put(0U, 1U);
    }
  }
};

struct Av1SequenceHeaderSpec {
  std::uint32_t seqProfile{0};
  std::uint32_t seqLevelIdx{8};
  bool highBitdepth{false};
  bool twelveBit{false};
  bool monochrome{false};
  bool colorDescriptionPresent{false};
  std::uint32_t colorPrimaries{2};
  std::uint32_t transferCharacteristics{2};
  std::uint32_t matrixCoefficients{2};
  bool fullRange{false};
  std::uint32_t width{1920};
  std::uint32_t height{1080};
};

// sequence_header_obu() payload with no timing info, no decoder model, no
// initial display delay, and exactly one operating point: the shape every
// consumer AV1 encoder writes.
std::vector<std::uint8_t>
makeAv1SequenceHeaderPayload(const Av1SequenceHeaderSpec &spec) {
  PlainBitWriter writer;
  writer.put(spec.seqProfile, 3U);
  writer.put(0U, 1U); // still_picture
  writer.put(0U, 1U); // reduced_still_picture_header
  writer.put(0U, 1U); // timing_info_present_flag
  writer.put(0U, 1U); // initial_display_delay_present_flag
  writer.put(0U, 5U); // operating_points_cnt_minus_1
  writer.put(0U, 12U); // operating_point_idc[0]
  writer.put(spec.seqLevelIdx, 5U);
  if (spec.seqLevelIdx > 7U) {
    writer.put(0U, 1U); // seq_tier[0]
  }
  writer.put(15U, 4U); // frame_width_bits_minus_1
  writer.put(15U, 4U); // frame_height_bits_minus_1
  writer.put(spec.width - 1U, 16U);
  writer.put(spec.height - 1U, 16U);
  writer.put(0U, 1U); // frame_id_numbers_present_flag
  writer.put(0U, 3U); // 128x128 superblock, filter intra, intra edge filter
  writer.put(0U, 4U); // interintra, masked compound, warped motion, dual filter
  writer.put(0U, 1U); // enable_order_hint
  writer.put(1U, 1U); // seq_choose_screen_content_tools
  writer.put(1U, 1U); // seq_choose_integer_mv
  writer.put(0U, 3U); // enable_superres, enable_cdef, enable_restoration
  writer.put(spec.highBitdepth ? 1U : 0U, 1U);
  if (spec.seqProfile == 2U && spec.highBitdepth) {
    writer.put(spec.twelveBit ? 1U : 0U, 1U);
  }
  if (spec.seqProfile != 1U) {
    writer.put(spec.monochrome ? 1U : 0U, 1U);
  }
  writer.put(spec.colorDescriptionPresent ? 1U : 0U, 1U);
  if (spec.colorDescriptionPresent) {
    writer.put(spec.colorPrimaries, 8U);
    writer.put(spec.transferCharacteristics, 8U);
    writer.put(spec.matrixCoefficients, 8U);
  }
  const bool srgbShortcut =
      spec.colorDescriptionPresent && spec.colorPrimaries == 1U &&
      spec.transferCharacteristics == 13U && spec.matrixCoefficients == 0U;
  if (spec.monochrome) {
    writer.put(spec.fullRange ? 1U : 0U, 1U);
    writer.putTrailingBits();
    return writer.bytes;
  }
  if (!srgbShortcut) {
    writer.put(spec.fullRange ? 1U : 0U, 1U);
    const bool twelveBit = spec.seqProfile == 2U && spec.highBitdepth &&
                           spec.twelveBit;
    bool subsamplingX = spec.seqProfile != 1U;
    bool subsamplingY = spec.seqProfile == 0U;
    if (spec.seqProfile == 2U && twelveBit) {
      writer.put(1U, 1U); // subsampling_x
      writer.put(1U, 1U); // subsampling_y
      subsamplingX = true;
      subsamplingY = true;
    }
    if (subsamplingX && subsamplingY) {
      writer.put(0U, 2U); // chroma_sample_position
    }
  }
  writer.put(0U, 1U); // separate_uv_delta_q
  writer.put(0U, 1U); // film_grain_params_present
  writer.putTrailingBits();
  return writer.bytes;
}

void appendLeb128(std::vector<std::uint8_t> &bytes, std::uint64_t value) {
  do {
    std::uint8_t chunk = static_cast<std::uint8_t>(value & 0x7FU);
    value >>= 7U;
    if (value != 0U) {
      chunk = static_cast<std::uint8_t>(chunk | 0x80U);
    }
    bytes.push_back(chunk);
  } while (value != 0U);
}

struct Av1cSpec {
  Av1SequenceHeaderSpec sequence{};
  std::uint8_t marker{0x81U};
  bool declaredHighBitdepth{false};
  bool declaredTwelveBit{false};
  bool declaredMonochrome{false};
  bool declaredSubsamplingX{true};
  bool declaredSubsamplingY{true};
  std::uint32_t declaredProfile{0};
  bool presentationDelayPresent{false};
  std::uint8_t presentationDelayMinusOne{0};
  bool includeSequenceHeader{true};
};

std::vector<std::uint8_t> makeAv1C(const Av1cSpec &spec) {
  std::vector<std::uint8_t> record;
  record.push_back(spec.marker);
  record.push_back(static_cast<std::uint8_t>((spec.declaredProfile << 5U) |
                                             spec.sequence.seqLevelIdx));
  record.push_back(static_cast<std::uint8_t>(
      (spec.declaredHighBitdepth ? 0x40U : 0U) |
      (spec.declaredTwelveBit ? 0x20U : 0U) |
      (spec.declaredMonochrome ? 0x10U : 0U) |
      (spec.declaredSubsamplingX ? 0x08U : 0U) |
      (spec.declaredSubsamplingY ? 0x04U : 0U)));
  record.push_back(static_cast<std::uint8_t>(
      (spec.presentationDelayPresent ? 0x10U : 0U) |
      (spec.presentationDelayMinusOne & 0x0FU)));
  if (spec.includeSequenceHeader) {
    const auto payload = makeAv1SequenceHeaderPayload(spec.sequence);
    record.push_back(0x0AU); // type 1, obu_has_size_field
    appendLeb128(record, payload.size());
    record.insert(record.end(), payload.begin(), payload.end());
  }
  return record;
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectAv1(const std::vector<std::uint8_t> &bytes,
           VideoCodecConfigurationLimits limits = {}) noexcept {
  return inspectVideoCodecConfiguration(MediaCodec::Av1,
                                        MediaCodecConfigurationKind::Av1C,
                                        byteView(bytes), limits);
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectVpcc(const std::vector<std::uint8_t> &bytes,
            VideoCodecConfigurationLimits limits = {}) noexcept {
  return inspectVideoCodecConfiguration(MediaCodec::Vp9,
                                        MediaCodecConfigurationKind::VpcC,
                                        byteView(bytes), limits);
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectVp9Keyframe(const std::vector<std::uint8_t> &bytes,
                   VideoCodecConfigurationLimits limits = {}) noexcept {
  return inspectVp9BitstreamKeyframe(byteView(bytes), limits);
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectVp8Keyframe(const std::vector<std::uint8_t> &bytes,
                   VideoCodecConfigurationLimits limits = {}) noexcept {
  return inspectVp8BitstreamKeyframe(byteView(bytes), limits);
}

// The av1C from test-media/codec-envelope/av1-aac.mkv: 1920x1080, seq_profile
// 0, 8-bit 4:2:0, level 8, no color description. Its 12-byte configOBU is a
// real libaom sequence header, complete with an initial_display_delay operating
// point, so it also exercises the parts of the walk a synthesized header omits.
const std::vector<std::uint8_t> kRepositorySampleAv1C{
    0x81, 0x08, 0x0c, 0x00, 0x0a, 0x0c, 0x02, 0x00, 0x00,
    0x42, 0x95, 0x5d, 0xfe, 0x1b, 0x80, 0x5f, 0x00, 0x08};

// The first 12 bytes of the first coded frame of
// test-media/codec-envelope/vp9.webm, which is a keyframe. The Matroska Block
// payload is byte-identical to the elementary-stream frame, so this is exactly
// what the demuxer hands the bitstream parser.
const std::vector<std::uint8_t> kRepositorySampleVp9Keyframe{
    0x82, 0x49, 0x83, 0x42, 0x00, 0x77, 0xf0, 0x43, 0x76, 0x06, 0x38, 0x24};

void testAv1() {
  const auto repositorySample = inspectAv1(kRepositorySampleAv1C);
  expect(repositorySample.admitted(),
         "the repository's real 18-byte av1C is admitted");
  if (repositorySample.facts) {
    const auto &facts = *repositorySample.facts;
    expect(facts.codec == MediaCodec::Av1 &&
               facts.kind == MediaCodecConfigurationKind::Av1C &&
               facts.sampleFormat == MediaVideoSampleFormat::Yuv420EightBit &&
               facts.width == 1920U && facts.height == 1080U &&
               facts.bitDepth == 8U && facts.profile == 0U &&
               facts.nalLengthBytes == 0U && facts.maximumReorderFrames == 0U,
           "real av1C yields 1920x1080 8-bit 4:2:0 Main with no reordering");
    expect(!facts.color.colorDescriptionPresent,
           "real av1C sequence header carries no color description");
  }

  allocation_probe::calls = 0U;
  allocation_probe::active = true;
  const auto allocationFree = inspectAv1(kRepositorySampleAv1C);
  allocation_probe::active = false;
  expect(allocationFree.admitted() && allocation_probe::calls == 0U,
         "AV1 configuration inspection performs no heap allocation");

  Av1cSpec bt709;
  bt709.sequence.colorDescriptionPresent = true;
  bt709.sequence.colorPrimaries = 1U;
  bt709.sequence.transferCharacteristics = 1U;
  bt709.sequence.matrixCoefficients = 1U;
  const auto bt709Admitted = inspectAv1(makeAv1C(bt709));
  expect(bt709Admitted.admitted(), "explicit BT.709 AV1 is admitted");
  if (bt709Admitted.facts) {
    const auto &color = bt709Admitted.facts->color;
    expect(color.colorDescriptionPresent && color.colorPrimaries == 1U &&
               color.transferCharacteristics == 1U &&
               color.matrixCoefficients == 1U && !color.fullRange,
           "AV1 explicit narrow-range BT.709 color facts are exact");
  }

  Av1cSpec tenBit;
  tenBit.declaredHighBitdepth = true;
  tenBit.sequence.highBitdepth = true;
  const auto tenBitAdmitted = inspectAv1(makeAv1C(tenBit));
  expect(tenBitAdmitted.admitted() && tenBitAdmitted.facts &&
             tenBitAdmitted.facts->bitDepth == 10U &&
             tenBitAdmitted.facts->sampleFormat ==
                 MediaVideoSampleFormat::Yuv420TenBit,
         "10-bit AV1 Main is admitted as 4:2:0 10-bit");

  Av1cSpec delayed;
  delayed.presentationDelayPresent = true;
  delayed.presentationDelayMinusOne = 2U;
  expect(inspectAv1(makeAv1C(delayed)).facts &&
             inspectAv1(makeAv1C(delayed)).facts->maximumReorderFrames == 3U,
         "av1C initial_presentation_delay becomes the reorder depth");

  auto badMarker = kRepositorySampleAv1C;
  badMarker[0] = 0x01U;
  expectError(inspectAv1(badMarker),
              VideoCodecConfigurationError::MalformedRecord,
              "av1C marker bit must be set");
  auto badVersion = kRepositorySampleAv1C;
  badVersion[0] = 0x82U;
  expectError(inspectAv1(badVersion),
              VideoCodecConfigurationError::MalformedRecord,
              "av1C version must be exactly 1");
  auto reservedSet = kRepositorySampleAv1C;
  reservedSet[3] = 0x20U;
  expectError(inspectAv1(reservedSet),
              VideoCodecConfigurationError::MalformedRecord,
              "av1C reserved bits must be zero");
  expectError(inspectAv1({0x81U, 0x08U, 0x0cU}),
              VideoCodecConfigurationError::MalformedRecord,
              "av1C shorter than its fixed bytes is rejected");

  Av1cSpec professional;
  professional.declaredProfile = 1U;
  professional.sequence.seqProfile = 1U;
  professional.declaredSubsamplingX = false;
  professional.declaredSubsamplingY = false;
  expectError(inspectAv1(makeAv1C(professional)),
              VideoCodecConfigurationError::UnsupportedProfile,
              "AV1 seq_profile other than 0 is not admitted");

  Av1cSpec monochrome;
  monochrome.declaredMonochrome = true;
  monochrome.sequence.monochrome = true;
  expectError(inspectAv1(makeAv1C(monochrome)),
              VideoCodecConfigurationError::UnsupportedChromaFormat,
              "monochrome AV1 is not admitted");

  Av1cSpec notFourTwoZero;
  notFourTwoZero.declaredSubsamplingY = false;
  expectError(inspectAv1(makeAv1C(notFourTwoZero)),
              VideoCodecConfigurationError::UnsupportedChromaFormat,
              "AV1 that is not 4:2:0 is not admitted");

  Av1cSpec twelveBit;
  twelveBit.declaredHighBitdepth = true;
  twelveBit.declaredTwelveBit = true;
  expectError(inspectAv1(makeAv1C(twelveBit)),
              VideoCodecConfigurationError::UnsupportedBitDepth,
              "12-bit AV1 is not admitted");

  Av1cSpec bt2020;
  bt2020.sequence.colorDescriptionPresent = true;
  bt2020.sequence.colorPrimaries = 9U;
  bt2020.sequence.transferCharacteristics = 16U; // PQ
  bt2020.sequence.matrixCoefficients = 9U;
  expectError(inspectAv1(makeAv1C(bt2020)),
              VideoCodecConfigurationError::UnsupportedColorDescription,
              "BT.2020 PQ AV1 stays outside the SDR envelope");

  Av1cSpec depthDisagreement;
  depthDisagreement.declaredHighBitdepth = true;
  expectError(inspectAv1(makeAv1C(depthDisagreement)),
              VideoCodecConfigurationError::ParameterSetMismatch,
              "av1C fixed bytes cannot contradict the sequence header");

  Av1cSpec noSequenceHeader;
  noSequenceHeader.includeSequenceHeader = false;
  expectError(inspectAv1(makeAv1C(noSequenceHeader)),
              VideoCodecConfigurationError::MissingParameterSet,
              "av1C without a sequence header OBU proves nothing");

  Av1cSpec uhdAv1;
  uhdAv1.sequence.width = 3840U;
  uhdAv1.sequence.height = 2160U;
  expect(inspectAv1(makeAv1C(uhdAv1)).admitted(),
         "AV1 UHD is inside the 4096x2320 v1 envelope");

  Av1cSpec oversized;
  oversized.sequence.width = 7680U;
  oversized.sequence.height = 4320U;
  expectError(inspectAv1(makeAv1C(oversized)),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "AV1 dimensions remain capped at 4096x2320");

  auto truncatedObu = makeAv1C({});
  truncatedObu.pop_back();
  expectError(inspectAv1(truncatedObu),
              VideoCodecConfigurationError::MalformedRecord,
              "an av1C OBU shorter than its declared size is rejected");

  auto frameObu = makeAv1C({});
  frameObu[4] = 0x32U; // obu_type 6 (OBU_FRAME) with obu_has_size_field
  expectError(inspectAv1(frameObu),
              VideoCodecConfigurationError::MalformedRecord,
              "a frame OBU inside configOBUs is a malformed record");

  VideoCodecConfigurationLimits noReorder;
  noReorder.maximumReorderFrames = 0U;
  expectError(inspectAv1(makeAv1C(delayed), noReorder),
              VideoCodecConfigurationError::ReorderLimitExceeded,
              "AV1 presentation delay honors a tightened reorder bound");
}

struct Vp9KeyframeSpec {
  std::uint32_t frameMarker{2};
  std::uint32_t profile{0};
  std::uint32_t profile3Reserved{0};
  std::uint32_t showExistingFrame{0};
  std::uint32_t frameType{0};
  std::uint32_t tenOrTwelveBit{0};
  std::uint32_t colorSpace{2};
  std::uint32_t colorRange{0};
  std::uint32_t subsamplingX{1};
  std::uint32_t subsamplingY{1};
  std::uint32_t syncCode{0x498342U};
  std::uint32_t width{1920};
  std::uint32_t height{1080};
};

std::vector<std::uint8_t> makeVp9Keyframe(const Vp9KeyframeSpec &spec) {
  PlainBitWriter writer;
  writer.put(spec.frameMarker, 2U);
  writer.put(spec.profile & 1U, 1U);        // profile_low_bit
  writer.put((spec.profile >> 1U) & 1U, 1U); // profile_high_bit
  if (spec.profile == 3U) {
    writer.put(spec.profile3Reserved, 1U);
  }
  writer.put(spec.showExistingFrame, 1U);
  writer.put(spec.frameType, 1U);
  writer.put(1U, 1U); // show_frame
  writer.put(0U, 1U); // error_resilient_mode
  writer.put(spec.syncCode, 24U);
  if (spec.profile >= 2U) {
    writer.put(spec.tenOrTwelveBit, 1U);
  }
  writer.put(spec.colorSpace, 3U);
  if (spec.colorSpace != 7U) {
    writer.put(spec.colorRange, 1U);
    if (spec.profile == 1U || spec.profile == 3U) {
      writer.put(spec.subsamplingX, 1U);
      writer.put(spec.subsamplingY, 1U);
      writer.put(0U, 1U); // reserved_zero
    }
  } else if (spec.profile == 1U || spec.profile == 3U) {
    writer.put(0U, 1U); // reserved_zero
  }
  writer.put(spec.width - 1U, 16U);
  writer.put(spec.height - 1U, 16U);
  // The parser stops here; the remaining uncompressed-header syntax is left as
  // zero padding to a byte boundary, which is what a prefix read looks like.
  while (writer.bitCount % 8U != 0U) {
    writer.put(0U, 1U);
  }
  return writer.bytes;
}

std::vector<std::uint8_t>
synthesizedVpcC(const VideoCodecConfigurationFacts &facts) {
  std::array<std::byte, kVideoCodecVpcCBytes> record{};
  if (!buildVp9CodecConfiguration(facts, record)) {
    return {};
  }
  std::vector<std::uint8_t> bytes(record.size());
  for (std::size_t index = 0; index < record.size(); ++index) {
    bytes[index] = static_cast<std::uint8_t>(record[index]);
  }
  return bytes;
}

// The first ten bytes of the first coded frame of
// scratchpad/fixtures/vp8_vorbis60.webm (1920x1080) and of
// scratchpad/fixtures/vp8_vorbis.webm (640x360), both key frames. A Matroska
// Block payload is byte-identical to the elementary-stream frame, so this is
// exactly what the demuxer hands the bitstream parser.
const std::vector<std::uint8_t> kRealVp8Keyframe1080p{
    0x10, 0xb1, 0x03, 0x9d, 0x01, 0x2a, 0x80, 0x07, 0x38, 0x04};
const std::vector<std::uint8_t> kRealVp8Keyframe360p{
    0xf0, 0xd0, 0x00, 0x9d, 0x01, 0x2a, 0x80, 0x02, 0x68, 0x01};

// Builds a VP8 key frame header from its fields so each gate can be tripped
// one at a time. RFC 6386 section 9.1: a three-byte little-endian frame tag,
// the three-byte start code, then two little-endian 16-bit fields carrying a
// 14-bit dimension and a 2-bit scale.
struct Vp8KeyframeSpec {
  std::uint32_t frameType{0};
  std::uint32_t version{0};
  std::uint32_t showFrame{1};
  std::uint32_t firstPartitionSize{7560};
  std::uint32_t width{1920};
  std::uint32_t height{1080};
  std::uint32_t horizontalScale{0};
  std::uint32_t verticalScale{0};
  std::uint8_t startCode0{0x9d};
  std::uint8_t startCode1{0x01};
  std::uint8_t startCode2{0x2a};
};

std::vector<std::uint8_t> makeVp8Keyframe(const Vp8KeyframeSpec &spec) {
  const std::uint32_t tag = (spec.frameType & 0x1U) |
                            ((spec.version & 0x7U) << 1U) |
                            ((spec.showFrame & 0x1U) << 4U) |
                            ((spec.firstPartitionSize & 0x7FFFFU) << 5U);
  const std::uint32_t widthField =
      (spec.width & 0x3FFFU) | ((spec.horizontalScale & 0x3U) << 14U);
  const std::uint32_t heightField =
      (spec.height & 0x3FFFU) | ((spec.verticalScale & 0x3U) << 14U);
  return {static_cast<std::uint8_t>(tag & 0xFFU),
          static_cast<std::uint8_t>((tag >> 8U) & 0xFFU),
          static_cast<std::uint8_t>((tag >> 16U) & 0xFFU),
          spec.startCode0,
          spec.startCode1,
          spec.startCode2,
          static_cast<std::uint8_t>(widthField & 0xFFU),
          static_cast<std::uint8_t>((widthField >> 8U) & 0xFFU),
          static_cast<std::uint8_t>(heightField & 0xFFU),
          static_cast<std::uint8_t>((heightField >> 8U) & 0xFFU)};
}

void testVp8() {
  // The exact header size is both necessary and sufficient, and is asserted so
  // a change to the constant has to restate why.
  static_assert(kVp8KeyframeHeaderMaximumBytes == 10U);
  static_assert(noexcept(inspectVp8BitstreamKeyframe({})));

  const auto real1080p = inspectVp8Keyframe(kRealVp8Keyframe1080p);
  expect(real1080p.admitted(),
         "a real 1080p VP8 key frame header is admitted");
  if (real1080p.facts) {
    const auto &facts = *real1080p.facts;
    expect(facts.codec == MediaCodec::Vp8 &&
               facts.kind == MediaCodecConfigurationKind::VpcC &&
               facts.sampleFormat == MediaVideoSampleFormat::Yuv420EightBit &&
               facts.width == 1920U && facts.height == 1080U &&
               facts.bitDepth == 8U && facts.profile == 0U &&
               facts.nalLengthBytes == 0U,
           "real VP8 key frame yields 1920x1080 8-bit 4:2:0");
    // VP8 has no B-frames and never displays an alternate-reference frame, so
    // decode order is presentation order. This is the fact the consumer's
    // reorder machinery collapses onto.
    expect(facts.maximumReorderFrames == 0U,
           "VP8 states a zero reorder depth");
    // RFC 6386 has one colour space and no primaries or transfer syntax, so
    // the bitstream states no colour description at all.
    expect(!facts.color.colorDescriptionPresent && !facts.color.fullRange,
           "VP8 reports no colour description");
  }

  const auto real360p = inspectVp8Keyframe(kRealVp8Keyframe360p);
  expect(real360p.admitted() && real360p.facts &&
             real360p.facts->width == 640U && real360p.facts->height == 360U,
         "a real 640x360 VP8 key frame header is admitted");

  allocation_probe::calls = 0U;
  allocation_probe::active = true;
  const auto allocationFree = inspectVp8Keyframe(kRealVp8Keyframe1080p);
  allocation_probe::active = false;
  expect(allocationFree.admitted() && allocation_probe::calls == 0U,
         "VP8 key frame inspection performs no heap allocation");

  // A real coded key frame is tens of kilobytes; the parser reads a bounded
  // ten-byte prefix and never depends on record exhaustion.
  auto longFrame = kRealVp8Keyframe1080p;
  longFrame.resize(4096U, 0xA5U);
  expect(inspectVp8Keyframe(longFrame).admitted() &&
             inspectVp8Keyframe(longFrame).facts->width == 1920U,
         "VP8 key frame facts come from a bounded header prefix");

  expectError(inspectVp8BitstreamKeyframe({}),
              VideoCodecConfigurationError::EmptyConfiguration,
              "an empty VP8 key frame is refused");
  for (std::size_t truncated = 1; truncated < 10U; ++truncated) {
    auto shortFrame = kRealVp8Keyframe1080p;
    shortFrame.resize(truncated);
    expectError(inspectVp8Keyframe(shortFrame),
                VideoCodecConfigurationError::MalformedRecord,
                "a VP8 header shorter than ten bytes is refused");
  }

  Vp8KeyframeSpec interFrame;
  interFrame.frameType = 1U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(interFrame)),
              VideoCodecConfigurationError::MalformedRecord,
              "an inter frame is refused where a key frame was located");
  Vp8KeyframeSpec hidden;
  hidden.showFrame = 0U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(hidden)),
              VideoCodecConfigurationError::MalformedRecord,
              "a key frame that is not shown is refused");
  Vp8KeyframeSpec emptyPartition;
  emptyPartition.firstPartitionSize = 0U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(emptyPartition)),
              VideoCodecConfigurationError::MalformedRecord,
              "a zero first-partition size is refused");
  for (std::uint32_t version = 4U; version <= 7U; ++version) {
    Vp8KeyframeSpec reserved;
    reserved.version = version;
    expectError(inspectVp8Keyframe(makeVp8Keyframe(reserved)),
                VideoCodecConfigurationError::UnsupportedProfile,
                "a reserved VP8 version is refused");
  }
  for (std::uint32_t version = 0U; version <= 3U; ++version) {
    Vp8KeyframeSpec defined;
    defined.version = version;
    const auto inspection = inspectVp8Keyframe(makeVp8Keyframe(defined));
    expect(inspection.admitted() && inspection.facts->profile == 0U,
           "every defined VP8 version is admitted and reports vpcC profile 0");
  }
  Vp8KeyframeSpec badStart0;
  badStart0.startCode0 = 0x9eU;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(badStart0)),
              VideoCodecConfigurationError::MalformedRecord,
              "a corrupt VP8 start code byte 0 is refused");
  Vp8KeyframeSpec badStart1;
  badStart1.startCode1 = 0x00U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(badStart1)),
              VideoCodecConfigurationError::MalformedRecord,
              "a corrupt VP8 start code byte 1 is refused");
  Vp8KeyframeSpec badStart2;
  badStart2.startCode2 = 0x2bU;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(badStart2)),
              VideoCodecConfigurationError::MalformedRecord,
              "a corrupt VP8 start code byte 2 is refused");
  Vp8KeyframeSpec horizontalScale;
  horizontalScale.horizontalScale = 1U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(horizontalScale)),
              VideoCodecConfigurationError::UnsupportedProfile,
              "a horizontally upscaled VP8 stream is refused");
  Vp8KeyframeSpec verticalScale;
  verticalScale.verticalScale = 3U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(verticalScale)),
              VideoCodecConfigurationError::UnsupportedProfile,
              "a vertically upscaled VP8 stream is refused");
  Vp8KeyframeSpec zeroWidth;
  zeroWidth.width = 0U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(zeroWidth)),
              VideoCodecConfigurationError::MalformedRecord,
              "a zero-width VP8 key frame is refused");
  Vp8KeyframeSpec zeroHeight;
  zeroHeight.height = 0U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(zeroHeight)),
              VideoCodecConfigurationError::MalformedRecord,
              "a zero-height VP8 key frame is refused");

  // The 14-bit dimension ceiling is 16383, which is above the renderer's own
  // envelope, so the limit gate rather than the field width decides.
  VideoCodecConfigurationLimits narrow;
  narrow.maximumWidth = 1280U;
  narrow.maximumHeight = 720U;
  narrow.maximumPixels = 1280U * 720U;
  expectError(inspectVp8Keyframe(kRealVp8Keyframe1080p, narrow),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "a VP8 key frame above the dimension limit is refused");
  Vp8KeyframeSpec maximumField;
  maximumField.width = 16383U;
  maximumField.height = 16383U;
  expectError(inspectVp8Keyframe(makeVp8Keyframe(maximumField)),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "the widest expressible VP8 frame exceeds the default limits");

  // Round trip: proven bitstream facts -> synthesized vpcC. Nothing parses the
  // record back, so the assertion is on its exact bytes.
  if (real1080p.facts) {
    std::array<std::byte, kVideoCodecVpcCBytes> record{};
    expect(buildVp8CodecConfiguration(*real1080p.facts, record),
           "VP8 vpcC synthesis accepts proven VP8 facts");
    const auto at = [&record](std::size_t index) {
      return static_cast<std::uint8_t>(record[index]);
    };
    expect(at(0) == 1U && at(1) == 0U && at(2) == 0U && at(3) == 0U &&
               at(4) == 0U && at(6) == 0x82U && at(7) == 2U && at(8) == 2U &&
               at(9) == 2U && at(10) == 0U && at(11) == 0U,
           "a synthesized VP8 vpcC is version 1, profile 0, 8-bit 4:2:0 "
           "colocated, narrow range, unspecified colour, no initialisation "
           "data");
    expect(at(5) != 0U, "a synthesized VP8 vpcC states a nonzero level");
  }

  VideoCodecConfigurationFacts notVp8;
  notVp8.codec = MediaCodec::Vp9;
  notVp8.kind = MediaCodecConfigurationKind::VpcC;
  notVp8.bitDepth = 8U;
  notVp8.sampleFormat = MediaVideoSampleFormat::Yuv420EightBit;
  notVp8.width = 1920U;
  notVp8.height = 1080U;
  std::array<std::byte, kVideoCodecVpcCBytes> unusedVp8{};
  expect(!buildVp8CodecConfiguration(notVp8, unusedVp8),
         "VP8 vpcC synthesis refuses facts that are not admitted VP8 facts");
  if (real1080p.facts) {
    expect(!buildVp9CodecConfiguration(*real1080p.facts, unusedVp8),
           "VP9 vpcC synthesis refuses VP8 facts");
  }

  // inspectVideoCodecConfiguration() is the record-parsing entry point and has
  // no VP8 record to parse, so it must refuse the codec rather than fall
  // through to the vpcC parser.
  expectError(inspectVideoCodecConfiguration(
                  MediaCodec::Vp8, MediaCodecConfigurationKind::VpcC,
                  byteView(kRealVp8Keyframe1080p)),
              VideoCodecConfigurationError::UnsupportedCodec,
              "VP8 has no decoder configuration record to inspect");
}

void testVp9() {
  const auto repositorySample =
      inspectVp9Keyframe(kRepositorySampleVp9Keyframe);
  expect(repositorySample.admitted(),
         "the repository's real VP9 keyframe header is admitted");
  if (repositorySample.facts) {
    const auto &facts = *repositorySample.facts;
    expect(facts.codec == MediaCodec::Vp9 &&
               facts.kind == MediaCodecConfigurationKind::VpcC &&
               facts.sampleFormat == MediaVideoSampleFormat::Yuv420EightBit &&
               facts.width == 1920U && facts.height == 1080U &&
               facts.bitDepth == 8U && facts.profile == 0U &&
               facts.nalLengthBytes == 0U && facts.maximumReorderFrames == 0U,
           "real VP9 keyframe yields 1920x1080 profile 0 8-bit 4:2:0");
    expect(!facts.color.colorDescriptionPresent && !facts.color.fullRange,
           "real VP9 keyframe reports CS_UNKNOWN narrow range");
  }

  allocation_probe::calls = 0U;
  allocation_probe::active = true;
  const auto allocationFree =
      inspectVp9Keyframe(kRepositorySampleVp9Keyframe);
  allocation_probe::active = false;
  expect(allocationFree.admitted() && allocation_probe::calls == 0U,
         "VP9 keyframe inspection performs no heap allocation");

  // A real coded keyframe is tens of kilobytes; the parser must read a bounded
  // prefix of it and never depend on record exhaustion.
  auto longFrame = kRepositorySampleVp9Keyframe;
  longFrame.resize(4096U, 0xA5U);
  expect(inspectVp9Keyframe(longFrame).admitted() &&
             inspectVp9Keyframe(longFrame).facts->width == 1920U,
         "VP9 keyframe facts come from a bounded header prefix");

  // Round trip: proven bitstream facts -> synthesized vpcC -> the same facts.
  if (repositorySample.facts) {
    const auto synthesized = synthesizedVpcC(*repositorySample.facts);
    expect(synthesized.size() == kVideoCodecVpcCBytes &&
               synthesized[0] == 1U && synthesized[1] == 0U &&
               synthesized[2] == 0U && synthesized[3] == 0U &&
               synthesized[4] == 0U && synthesized[6] == 0x82U &&
               synthesized[7] == 2U && synthesized[8] == 2U &&
               synthesized[9] == 2U && synthesized[10] == 0U &&
               synthesized[11] == 0U,
           "a synthesized vpcC is version 1, profile 0, 8-bit 4:2:0 "
           "narrow-range, unspecified color, no initialization data");
    const auto roundTrip = inspectVpcc(synthesized);
    expect(roundTrip.admitted() && roundTrip.facts &&
               roundTrip.facts->profile == 0U &&
               roundTrip.facts->bitDepth == 8U &&
               roundTrip.facts->sampleFormat ==
                   MediaVideoSampleFormat::Yuv420EightBit &&
               !roundTrip.facts->color.colorDescriptionPresent &&
               roundTrip.facts->width == 0U && roundTrip.facts->height == 0U,
           "a synthesized vpcC round-trips and carries no dimensions");
  }

  const Vp9KeyframeSpec bt709Spec;
  const auto bt709 = inspectVp9Keyframe(makeVp9Keyframe(bt709Spec));
  expect(bt709.admitted() && bt709.facts &&
             bt709.facts->color.colorDescriptionPresent &&
             bt709.facts->color.colorPrimaries == 1U &&
             bt709.facts->color.transferCharacteristics == 1U &&
             bt709.facts->color.matrixCoefficients == 1U,
         "VP9 CS_BT_709 yields the complete BT.709 description");
  if (bt709.facts) {
    const auto synthesized = synthesizedVpcC(*bt709.facts);
    expect(synthesized.size() == kVideoCodecVpcCBytes &&
               synthesized[7] == 1U && synthesized[8] == 1U &&
               synthesized[9] == 1U,
           "a synthesized vpcC carries the proven BT.709 color bytes");
  }

  Vp9KeyframeSpec bt601Spec;
  bt601Spec.colorSpace = 1U;
  const auto bt601 = inspectVp9Keyframe(makeVp9Keyframe(bt601Spec));
  expect(bt601.admitted() && bt601.facts &&
             bt601.facts->color.colorPrimaries == 2U &&
             bt601.facts->color.transferCharacteristics == 2U &&
             bt601.facts->color.matrixCoefficients == 5U,
         "VP9 CS_BT_601 names only a matrix; primaries and transfer stay "
         "unspecified rather than being invented");

  Vp9KeyframeSpec fullRangeSpec;
  fullRangeSpec.colorRange = 1U;
  const auto fullRange = inspectVp9Keyframe(makeVp9Keyframe(fullRangeSpec));
  expect(fullRange.admitted() && fullRange.facts &&
             fullRange.facts->color.fullRange &&
             synthesizedVpcC(*fullRange.facts)[6] == 0x83U,
         "VP9 color_range reaches the synthesized vpcC full-range flag");

  Vp9KeyframeSpec tenBitSpec;
  tenBitSpec.profile = 2U;
  const auto tenBit = inspectVp9Keyframe(makeVp9Keyframe(tenBitSpec));
  expect(tenBit.admitted() && tenBit.facts && tenBit.facts->bitDepth == 10U &&
             tenBit.facts->profile == 2U &&
             tenBit.facts->sampleFormat ==
                 MediaVideoSampleFormat::Yuv420TenBit,
         "VP9 profile 2 10-bit 4:2:0 is admitted");
  if (tenBit.facts) {
    expect(synthesizedVpcC(*tenBit.facts)[6] == 0xA2U,
           "a synthesized 10-bit vpcC encodes bit depth 10 and 4:2:0");
  }

  Vp9KeyframeSpec badMarker;
  badMarker.frameMarker = 1U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(badMarker)),
              VideoCodecConfigurationError::MalformedRecord,
              "VP9 frame_marker must be 2");

  Vp9KeyframeSpec showExisting;
  showExisting.showExistingFrame = 1U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(showExisting)),
              VideoCodecConfigurationError::MalformedRecord,
              "a VP9 show_existing_frame is not a keyframe");

  Vp9KeyframeSpec interFrame;
  interFrame.frameType = 1U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(interFrame)),
              VideoCodecConfigurationError::MalformedRecord,
              "a VP9 inter frame proves no configuration facts");

  Vp9KeyframeSpec badSync;
  badSync.syncCode = 0x498343U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(badSync)),
              VideoCodecConfigurationError::MalformedRecord,
              "the VP9 frame_sync_code must be 49 83 42 exactly");

  Vp9KeyframeSpec profileOne;
  profileOne.profile = 1U;
  profileOne.subsamplingX = 0U;
  profileOne.subsamplingY = 0U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(profileOne)),
              VideoCodecConfigurationError::UnsupportedProfile,
              "VP9 profile 1 is outside the 4:2:0 envelope");

  Vp9KeyframeSpec twelveBit;
  twelveBit.profile = 2U;
  twelveBit.tenOrTwelveBit = 1U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(twelveBit)),
              VideoCodecConfigurationError::UnsupportedBitDepth,
              "12-bit VP9 is not admitted");

  Vp9KeyframeSpec bt2020;
  bt2020.colorSpace = 5U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(bt2020)),
              VideoCodecConfigurationError::UnsupportedColorDescription,
              "BT.2020 VP9 stays outside the SDR envelope");

  Vp9KeyframeSpec smpte240;
  smpte240.colorSpace = 4U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(smpte240)),
              VideoCodecConfigurationError::UnsupportedColorDescription,
              "SMPTE 240M VP9 stays outside the SDR envelope");

  Vp9KeyframeSpec reserved;
  reserved.colorSpace = 6U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(reserved)),
              VideoCodecConfigurationError::MalformedRecord,
              "the reserved VP9 color space is a malformed header");

  Vp9KeyframeSpec srgb;
  srgb.colorSpace = 7U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(srgb)),
              VideoCodecConfigurationError::UnsupportedChromaFormat,
              "sRGB VP9 is 4:4:4 and is not admitted");

  Vp9KeyframeSpec uhdVp9;
  uhdVp9.width = 3840U;
  uhdVp9.height = 2160U;
  expect(inspectVp9Keyframe(makeVp9Keyframe(uhdVp9)).admitted(),
         "VP9 UHD is inside the 4096x2320 v1 envelope");

  Vp9KeyframeSpec oversized;
  oversized.width = 7680U;
  oversized.height = 4320U;
  expectError(inspectVp9Keyframe(makeVp9Keyframe(oversized)),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "VP9 dimensions remain capped at 4096x2320");

  auto truncated = makeVp9Keyframe(bt709Spec);
  truncated.resize(6U);
  expectError(inspectVp9Keyframe(truncated),
              VideoCodecConfigurationError::MalformedRecord,
              "a VP9 header prefix too short to carry frame_size is rejected");

  // vpcC record structure.
  const std::vector<std::uint8_t> validVpcC{1U, 0U, 0U, 0U,    0U, 40U,
                                            0x82U, 1U, 1U, 1U, 0U, 0U};
  expect(inspectVpcc(validVpcC).admitted(),
         "a well-formed BT.709 vpcC is admitted");
  auto badVersion = validVpcC;
  badVersion[0] = 0U;
  expectError(inspectVpcc(badVersion),
              VideoCodecConfigurationError::MalformedRecord,
              "vpcC version must be exactly 1");
  auto badFlags = validVpcC;
  badFlags[2] = 1U;
  expectError(inspectVpcc(badFlags),
              VideoCodecConfigurationError::MalformedRecord,
              "vpcC flags must be zero");
  auto initializationData = validVpcC;
  initializationData[11] = 4U;
  expectError(inspectVpcc(initializationData),
              VideoCodecConfigurationError::MalformedRecord,
              "vpcC codec initialization data is not admitted");
  auto shortRecord = validVpcC;
  shortRecord.pop_back();
  expectError(inspectVpcc(shortRecord),
              VideoCodecConfigurationError::MalformedRecord,
              "a vpcC is exactly twelve bytes");
  auto profileOneRecord = validVpcC;
  profileOneRecord[4] = 1U;
  expectError(inspectVpcc(profileOneRecord),
              VideoCodecConfigurationError::UnsupportedProfile,
              "vpcC profile 1 is outside the 4:2:0 envelope");
  auto fourFourFour = validVpcC;
  fourFourFour[6] = 0x86U;
  expectError(inspectVpcc(fourFourFour),
              VideoCodecConfigurationError::UnsupportedChromaFormat,
              "vpcC 4:4:4 chroma subsampling is not admitted");
  auto twelveBitRecord = validVpcC;
  twelveBitRecord[4] = 2U;
  twelveBitRecord[6] = 0xC2U;
  expectError(inspectVpcc(twelveBitRecord),
              VideoCodecConfigurationError::UnsupportedBitDepth,
              "vpcC 12-bit is not admitted");
  auto profileDepthMismatch = validVpcC;
  profileDepthMismatch[6] = 0xA2U;
  expectError(inspectVpcc(profileDepthMismatch),
              VideoCodecConfigurationError::UnsupportedProfile,
              "vpcC profile 0 cannot claim 10-bit");
  auto hdrRecord = validVpcC;
  hdrRecord[7] = 9U;
  hdrRecord[8] = 16U;
  hdrRecord[9] = 9U;
  expectError(inspectVpcc(hdrRecord),
              VideoCodecConfigurationError::UnsupportedColorDescription,
              "a BT.2020 PQ vpcC stays outside the SDR envelope");

  VideoCodecConfigurationFacts notVp9;
  notVp9.codec = MediaCodec::H264;
  std::array<std::byte, kVideoCodecVpcCBytes> unused{};
  expect(!buildVp9CodecConfiguration(notVp9, unused),
         "vpcC synthesis refuses facts that are not admitted VP9 facts");
}

// ---------------------------------------------------------------------------
// MPEG-4 Part 2 (ISO/IEC 14496-2)
// ---------------------------------------------------------------------------
//
// Both records below are real ffmpeg output, taken verbatim from the
// CodecPrivate of a 1920x1080 Matroska file. They differ only in the fields
// that decide the verdict, which is exactly why they are the right pair:
//
//   Simple:  ... 01 ... b5 89 13 ... 20 00 c4 8d 88 ...   VOT 1,  verid 1
//   Advanced ... f1 ... b5 a9 13 ... 20 08 d4 8d 08 ...   VOT 17, verid 5
//
// The second one is what Xvid and DivX produce and what VideoToolbox refuses.
constexpr std::array<std::uint8_t, 47> kRealMpeg4SimpleProfileHeaders{
    0x00, 0x00, 0x01, 0xb0, 0x01, 0x00, 0x00, 0x01, 0xb5, 0x89, 0x13, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x20, 0x00, 0xc4, 0x8d, 0x88, 0x00,
    0xf5, 0x3c, 0x04, 0x87, 0x14, 0x43, 0x00, 0x00, 0x01, 0xb2, 0x4c, 0x61,
    0x76, 0x63, 0x36, 0x32, 0x2e, 0x32, 0x38, 0x2e, 0x31, 0x30, 0x32};

constexpr std::array<std::uint8_t, 48> kRealMpeg4AdvancedSimpleHeaders{
    0x00, 0x00, 0x01, 0xb0, 0xf1, 0x00, 0x00, 0x01, 0xb5, 0xa9, 0x13, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x20, 0x08, 0xd4, 0x8d, 0x08, 0x00,
    0xf5, 0x3c, 0x04, 0x87, 0x14, 0x10, 0x3f, 0x00, 0x00, 0x01, 0xb2, 0x4c,
    0x61, 0x76, 0x63, 0x36, 0x32, 0x2e, 0x32, 0x38, 0x2e, 0x31, 0x30, 0x32};

// Byte offsets into both records: profile_and_level_indication, and the first
// byte of the VideoObjectLayer payload.
constexpr std::size_t kMpeg4ProfileByteOffset{4};
constexpr std::size_t kMpeg4VolPayloadOffset{19};

[[nodiscard]] std::vector<std::uint8_t>
mpeg4Headers(const std::array<std::uint8_t, 47> &source) {
  return {source.begin(), source.end()};
}

[[nodiscard]] std::vector<std::uint8_t>
mpeg4Headers(const std::array<std::uint8_t, 48> &source) {
  return {source.begin(), source.end()};
}

[[nodiscard]] VideoCodecConfigurationInspection
inspectMpeg4(const std::vector<std::uint8_t> &bytes,
             VideoCodecConfigurationLimits limits = {}) noexcept {
  return inspectMpeg4VisualHeaders(byteView(bytes), limits);
}

void testMpeg4Visual() {
  static_assert(kMpeg4VisualEsdsOverheadBytes == 41U);
  static_assert(noexcept(inspectMpeg4VisualHeaders({})));

  const auto simple = inspectMpeg4(mpeg4Headers(kRealMpeg4SimpleProfileHeaders));
  expect(simple.admitted(),
         "real Simple Profile MPEG-4 Part 2 headers are admitted");
  if (simple.facts) {
    const auto &facts = *simple.facts;
    expect(facts.codec == MediaCodec::Mpeg4Visual &&
               facts.kind == MediaCodecConfigurationKind::CodecPrivate &&
               facts.sampleFormat == MediaVideoSampleFormat::Yuv420EightBit &&
               facts.width == 1920U && facts.height == 1080U &&
               facts.bitDepth == 8U && facts.nalLengthBytes == 0U,
           "MPEG-4 Simple Profile yields 1920x1080 8-bit 4:2:0");
    expect(facts.profile == 0x01U,
           "the reported profile is profile_and_level_indication verbatim");
    // Simple Profile forbids B-VOPs, so decode order IS presentation order.
    // Everything downstream -- the Matroska merge lead, the decoder's ordered
    // drain, the preview lane -- rests on this being zero.
    expect(facts.maximumReorderFrames == 0U,
           "MPEG-4 Simple Profile states a zero reorder depth");
    // ffmpeg writes video_signal_type = 0, so the headers describe no colour
    // at all and the container's Colour element stays the only source.
    expect(!facts.color.colorDescriptionPresent &&
               !facts.color.videoSignalTypePresent && !facts.color.fullRange,
           "these headers report no colour description");
  }

  // THE REFUSAL. Advanced Simple Profile is every Xvid/DivX-era file, and
  // Apple's VideoToolbox decoder rejects it at session creation with
  // codecBadDataErr (-8969) -- measured 2026-08-20, reproduced by AVFoundation
  // itself on a plain mp4v MP4. Admitting it would decode to drifting garbage,
  // so it is refused here, before any decoder exists.
  expectError(inspectMpeg4(mpeg4Headers(kRealMpeg4AdvancedSimpleHeaders)),
              VideoCodecConfigurationError::UnsupportedProfile,
              "Advanced Simple Profile MPEG-4 Part 2 headers are refused");

  // Neither half of the identity is sufficient on its own, and the two must
  // agree. A stream that patches only profile_and_level_indication still
  // carries Advanced Simple tools -- and VideoToolbox still refuses it, which
  // is the measurement that put the gate on the VideoObjectLayer rather than
  // on the profile byte.
  {
    auto lyingProfileByte = mpeg4Headers(kRealMpeg4AdvancedSimpleHeaders);
    lyingProfileByte[kMpeg4ProfileByteOffset] = 0x01U;
    expectError(inspectMpeg4(lyingProfileByte),
                VideoCodecConfigurationError::UnsupportedProfile,
                "an Advanced Simple layer claiming a Simple profile byte is "
                "refused");
  }
  {
    // The inverse: a Simple layer under an Advanced Simple profile byte. The
    // stream contradicts itself, so it is refused rather than guessed at.
    auto lyingLayer = mpeg4Headers(kRealMpeg4AdvancedSimpleHeaders);
    lyingLayer[kMpeg4VolPayloadOffset] = 0x00U;
    lyingLayer[kMpeg4VolPayloadOffset + 1U] = 0xc4U;
    expectError(inspectMpeg4(lyingLayer),
                VideoCodecConfigurationError::UnsupportedProfile,
                "a Simple layer under an Advanced Simple profile byte is "
                "refused");
  }
  {
    // And the pair that made the real decoder work in the probe: both fields
    // flipped. This is admitted, which proves the gate is the two fields and
    // nothing else about these bytes.
    auto bothFlipped = mpeg4Headers(kRealMpeg4AdvancedSimpleHeaders);
    bothFlipped[kMpeg4ProfileByteOffset] = 0x01U;
    bothFlipped[kMpeg4VolPayloadOffset] = 0x00U;
    bothFlipped[kMpeg4VolPayloadOffset + 1U] = 0xc4U;
    // The VisualObject's own verid must agree too; it reads 5 here.
    bothFlipped[9] = 0x89U;
    const auto flipped = inspectMpeg4(bothFlipped);
    expect(flipped.admitted() && flipped.facts &&
               flipped.facts->width == 1920U && flipped.facts->height == 1080U,
           "flipping exactly the gated fields admits the same bytes");
  }

  // A configuration record holds headers. Coded frame data hiding inside one
  // is malformed, not something to skip past -- and a VOP start code is how a
  // packed-bitstream stream would try to smuggle a B-VOP in.
  {
    auto withVop = mpeg4Headers(kRealMpeg4SimpleProfileHeaders);
    withVop.push_back(0x00U);
    withVop.push_back(0x00U);
    withVop.push_back(0x01U);
    withVop.push_back(0xb6U);
    withVop.push_back(0x10U);
    expectError(inspectMpeg4(withVop),
                VideoCodecConfigurationError::MalformedRecord,
                "a VOP start code inside the configuration record is refused");
  }

  // No VisualObjectSequence means no profile_and_level_indication, and this
  // admission will not invent one.
  {
    auto noSequence = mpeg4Headers(kRealMpeg4SimpleProfileHeaders);
    noSequence.erase(noSequence.begin(), noSequence.begin() + 5);
    expectError(inspectMpeg4(noSequence),
                VideoCodecConfigurationError::MalformedRecord,
                "headers without a VisualObjectSequence are refused");
  }

  expectError(inspectMpeg4VisualHeaders({}),
              VideoCodecConfigurationError::EmptyConfiguration,
              "empty MPEG-4 Part 2 headers are refused");
  {
    std::vector<std::uint8_t> notStartCode{0x01U, 0x02U, 0x03U, 0x04U, 0x05U};
    expectError(inspectMpeg4(notStartCode),
                VideoCodecConfigurationError::MalformedRecord,
                "a record that does not begin with a start code is refused");
  }
  {
    VideoCodecConfigurationLimits tiny;
    tiny.maximumConfigurationBytes = 8U;
    expectError(inspectMpeg4(mpeg4Headers(kRealMpeg4SimpleProfileHeaders), tiny),
                VideoCodecConfigurationError::ConfigurationTooLarge,
                "an over-long MPEG-4 Part 2 record is refused");
  }
  {
    VideoCodecConfigurationLimits narrow;
    narrow.maximumWidth = 1280U;
    expectError(
        inspectMpeg4(mpeg4Headers(kRealMpeg4SimpleProfileHeaders), narrow),
        VideoCodecConfigurationError::DimensionLimitExceeded,
        "an MPEG-4 Part 2 layer above the width limit is refused");
  }

  // Every truncation must be refused OR report the same dimensions as the
  // whole record; nothing may be read past the end and no truncation may
  // change a fact. The parser walks a bit string whose field widths depend on
  // earlier fields, so this sweep is the real bounds proof. Truncations that
  // only drop the trailing user_data element are legitimately admitted --
  // user_data carries the encoder name and nothing this admission consults.
  for (std::size_t truncated = 1U;
       truncated < kRealMpeg4SimpleProfileHeaders.size(); ++truncated) {
    auto shortRecord = mpeg4Headers(kRealMpeg4SimpleProfileHeaders);
    shortRecord.resize(truncated);
    const auto inspection = inspectMpeg4(shortRecord);
    expect(!inspection.admitted() || (inspection.facts->width == 1920U &&
                                      inspection.facts->height == 1080U),
           "a truncated MPEG-4 Part 2 record is refused or reports the same "
           "dimensions");
  }
  // Every VideoObjectLayer bit this admission reads is load bearing: cut
  // before the last of them and the record must be refused. The layer's
  // syntax ends 79 bits (ten bytes) into its payload at offset 19 -- these
  // headers set fixed_vop_rate to zero, so no fixed_vop_time_increment field
  // follows vop_time_increment_resolution -- and the eleventh byte is the
  // element's trailing padding, which carries nothing.
  constexpr std::size_t kMpeg4VolSyntaxEnd{kMpeg4VolPayloadOffset + 10U};
  for (std::size_t truncated = 1U; truncated < kMpeg4VolSyntaxEnd;
       ++truncated) {
    auto shortRecord = mpeg4Headers(kRealMpeg4SimpleProfileHeaders);
    shortRecord.resize(truncated);
    expect(!inspectMpeg4(shortRecord).admitted(),
           "a record cut inside the VideoObjectLayer is refused");
  }
  {
    // Dropping the optional user_data is not a defect.
    auto noUserData = mpeg4Headers(kRealMpeg4SimpleProfileHeaders);
    noUserData.resize(kMpeg4VolSyntaxEnd);
    expect(inspectMpeg4(noUserData).admitted(),
           "headers without the trailing user_data element are admitted");
  }
  // And every single-byte corruption must either be refused or produce facts
  // that are still internally consistent; nothing may crash or read out of
  // bounds. (Run under the strict/ASan aggregates, this is the fuzz floor.)
  for (std::size_t index = 0; index < kRealMpeg4SimpleProfileHeaders.size();
       ++index) {
    for (const std::uint8_t flip : {0x01U, 0x80U, 0xffU}) {
      auto mutated = mpeg4Headers(kRealMpeg4SimpleProfileHeaders);
      mutated[index] = static_cast<std::uint8_t>(mutated[index] ^ flip);
      const auto inspection = inspectMpeg4(mutated);
      expect(!inspection.admitted() ||
                 (inspection.facts->width != 0U &&
                  inspection.facts->height != 0U &&
                  inspection.facts->maximumReorderFrames == 0U),
             "a mutated MPEG-4 Part 2 record is refused or stays consistent");
    }
  }

  const auto probeInput = mpeg4Headers(kRealMpeg4SimpleProfileHeaders);
  allocation_probe::calls = 0U;
  allocation_probe::active = true;
  const auto allocationFree = inspectMpeg4(probeInput);
  allocation_probe::active = false;
  expect(allocationFree.admitted() && allocation_probe::calls == 0U,
         "MPEG-4 Part 2 header inspection performs no heap allocation");

  // ---- the esds the demuxer stores -------------------------------------
  const auto headers = mpeg4Headers(kRealMpeg4SimpleProfileHeaders);
  std::vector<std::byte> esds(kMpeg4VisualEsdsOverheadBytes + headers.size());
  std::size_t written = 0;
  expect(buildMpeg4VisualEsds(byteView(headers), esds, &written) &&
             written == esds.size(),
         "an esds is built at exactly the documented size");
  // Shape the measurement fixed: version/flags, then ES_Descr, and the
  // headers must survive byte for byte as the DecoderSpecificInfo.
  expect(esds.size() > 9U && esds[0] == std::byte{0} &&
             esds[1] == std::byte{0} && esds[2] == std::byte{0} &&
             esds[3] == std::byte{0} && esds[4] == std::byte{0x03},
         "the esds opens with four zero version/flags bytes and ES_DescrTag");
  // Every declared descriptor length must be exactly right. A length that is
  // merely large enough still parses in a permissive reader and still decodes
  // in VideoToolbox, so only an exact check catches it -- which is how the
  // DecoderConfigDescriptor's length was found to be four bytes too long.
  {
    const auto declaredLength = [&](std::size_t at) {
      return (static_cast<std::size_t>(esds[at] & std::byte{0x7f}) << 21U) |
             (static_cast<std::size_t>(esds[at + 1U] & std::byte{0x7f}) << 14U) |
             (static_cast<std::size_t>(esds[at + 2U] & std::byte{0x7f}) << 7U) |
             static_cast<std::size_t>(esds[at + 3U] & std::byte{0x7f});
    };
    const std::size_t n = headers.size();
    expect(esds[4] == std::byte{0x03} && declaredLength(5) == n + 32U,
           "the ES_Descriptor declares its exact payload length");
    expect(esds[12] == std::byte{0x04} && declaredLength(13) == n + 18U,
           "the DecoderConfigDescriptor declares its exact payload length");
    expect(esds[17] == std::byte{0x20} &&
               esds[18] == std::byte{(0x04U << 2U) | 0x01U},
           "the DecoderConfigDescriptor names MPEG-4 Visual and streamType "
           "visual");
    expect(esds[30] == std::byte{0x05} && declaredLength(31) == n,
           "the DecSpecificInfo declares the header length exactly");
    expect(esds[35U + n] == std::byte{0x06} &&
               esds[esds.size() - 1U] == std::byte{0x02},
           "the esds closes with an SLConfigDescriptor of predefined 2");
  }
  expect(std::equal(headers.begin(), headers.end(),
                    esds.end() - static_cast<std::ptrdiff_t>(headers.size()) - 6,
                    esds.end() - 6,
                    [](std::uint8_t lhs, std::byte rhs) {
                      return static_cast<std::byte>(lhs) == rhs;
                    }),
         "the esds carries the headers byte for byte");

  // Round trip: the stored record inspects back to the same facts, through the
  // common entry point every other codec uses.
  const auto roundTrip = inspectVideoCodecConfiguration(
      MediaCodec::Mpeg4Visual, MediaCodecConfigurationKind::CodecPrivate, esds);
  expect(roundTrip.admitted() && simple.facts && roundTrip.facts &&
             *roundTrip.facts == *simple.facts,
         "the synthesized esds inspects back to identical facts");

  expectError(
      inspectVideoCodecConfiguration(MediaCodec::Mpeg4Visual,
                                     MediaCodecConfigurationKind::AvcC, esds),
      VideoCodecConfigurationError::ConfigurationKindMismatch,
      "an MPEG-4 Part 2 record must present the CodecPrivate kind");

  // An esds is never built around bytes this player would refuse to decode.
  {
    const auto advanced = mpeg4Headers(kRealMpeg4AdvancedSimpleHeaders);
    std::vector<std::byte> refused(kMpeg4VisualEsdsOverheadBytes +
                                   advanced.size());
    std::size_t ignored = 0;
    expect(!buildMpeg4VisualEsds(byteView(advanced), refused, &ignored),
           "no esds is built around Advanced Simple Profile headers");
  }
  {
    std::vector<std::byte> tooSmall(headers.size());
    std::size_t ignored = 0;
    expect(!buildMpeg4VisualEsds(byteView(headers), tooSmall, &ignored),
           "an undersized esds buffer is refused");
    expect(!buildMpeg4VisualEsds(byteView(headers), esds, nullptr),
           "a null written pointer is refused");
  }
  // Every truncation of the stored esds must be refused by the round trip.
  for (std::size_t truncated = 1U; truncated < esds.size(); ++truncated) {
    std::vector<std::byte> shortEsds(esds.begin(),
                                     esds.begin() +
                                         static_cast<std::ptrdiff_t>(truncated));
    expect(!inspectVideoCodecConfiguration(
                MediaCodec::Mpeg4Visual,
                MediaCodecConfigurationKind::CodecPrivate, shortEsds)
                .admitted(),
           "a truncated esds is never admitted");
  }
}

} // namespace

int main() {
  testApiAndHardBounds();
  testCompactH264();
  testH264Rejections();
  testCompactHevcMainAndMain10();
  testHevcRejections();
  testAv1();
  testVp9();
  testVp8();
  testMpeg4Visual();
  if (failures != 0) {
    std::cerr << failures << " video codec configuration test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Framework-neutral AVC/HEVC/AV1/VP9/VP8/MPEG-4 Part 2 "
               "configuration tests passed\n";
  return EXIT_SUCCESS;
}
