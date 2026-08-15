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
  bits.bits(40U, 8U); // level 4.0
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
      0U,    40U,
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
  static_assert(kMaximumVideoCodecWidth == 1920U);
  static_assert(kMaximumVideoCodecHeight == 1080U);
  static_assert(kMaximumVideoCodecPixels == 1920ULL * 1080ULL);
  static_assert(kMaximumVideoCodecReorderFrames == 16U);
  static_assert(noexcept(inspectVideoCodecConfiguration(
      MediaCodec::H264, MediaCodecConfigurationKind::AvcC, {})));

  expectError(inspectVideoCodecConfiguration(
                  MediaCodec::Vp9, MediaCodecConfigurationKind::CodecPrivate,
                  std::array{std::byte{1U}}),
              VideoCodecConfigurationError::UnsupportedCodec,
              "unsupported codec is rejected before record parsing");
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

  const std::array oversized{H264SpsSpec{.width = 1936U, .height = 1080U}};
  expectError(inspectAvc(makeAvcC(oversized)),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "H.264 dimensions remain capped at 1920x1080");
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

  auto incompleteArray = valid;
  const auto spsArray = hevcArrayOffset(incompleteArray, 33U);
  expect(spsArray.has_value(), "test locates HEVC SPS array");
  if (spsArray) {
    incompleteArray[*spsArray] &= 0x7FU;
    expectError(inspectHevc(incompleteArray),
                VideoCodecConfigurationError::ParameterSetMismatch,
                "HEVC parameter-set arrays must be complete");
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

  const std::array oversized{HevcSpsSpec{.width = 1921U, .height = 1080U}};
  expectError(inspectHevc(makeHvcC(oversized)),
              VideoCodecConfigurationError::DimensionLimitExceeded,
              "HEVC dimensions remain capped at 1920x1080");

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

} // namespace

int main() {
  testApiAndHardBounds();
  testCompactH264();
  testH264Rejections();
  testCompactHevcMainAndMain10();
  testHevcRejections();
  if (failures != 0) {
    std::cerr << failures << " video codec configuration test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Framework-neutral AVC/HEVC configuration tests passed\n";
  return EXIT_SUCCESS;
}
