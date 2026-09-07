#pragma once
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
}
#include <cstddef>
namespace wam::media::avcodec {
struct Api {
  void* (*av_wam_reservation_begin)(std::size_t){};
  std::size_t (*av_wam_reservation_used)(void*){};
  int (*av_wam_reservation_exhausted)(void*){};
  std::size_t (*av_wam_reservation_end)(void*){};
  decltype(&::avcodec_version) avcodec_version{};
  decltype(&::avutil_version) avutil_version{};
  decltype(&::avcodec_license) avcodec_license{};
  decltype(&::avutil_license) avutil_license{};
  decltype(&::avcodec_configuration) avcodec_configuration{};
  decltype(&::avutil_configuration) avutil_configuration{};
  decltype(&::avcodec_find_decoder) avcodec_find_decoder{};
  decltype(&::avcodec_alloc_context3) avcodec_alloc_context3{};
  decltype(&::av_packet_alloc) av_packet_alloc{};
  decltype(&::av_frame_alloc) av_frame_alloc{};
  decltype(&::av_channel_layout_default) av_channel_layout_default{};
  decltype(&::av_mallocz) av_mallocz{};
  decltype(&::av_free) av_free{};
  decltype(&::av_buffer_create) av_buffer_create{};
  decltype(&::avcodec_open2) avcodec_open2{};
  decltype(&::av_frame_unref) av_frame_unref{};
  decltype(&::avcodec_receive_frame) avcodec_receive_frame{};
  decltype(&::av_buffer_get_ref_count) av_buffer_get_ref_count{};
  decltype(&::av_buffer_ref) av_buffer_ref{};
  decltype(&::avcodec_send_packet) avcodec_send_packet{};
  decltype(&::av_packet_unref) av_packet_unref{};
  decltype(&::av_frame_free) av_frame_free{};
  decltype(&::av_packet_free) av_packet_free{};
  decltype(&::avcodec_free_context) avcodec_free_context{};
  decltype(&::av_buffer_unref) av_buffer_unref{};
  decltype(&::av_channel_layout_channel_from_index) av_channel_layout_channel_from_index{};
  decltype(&::av_get_packed_sample_fmt) av_get_packed_sample_fmt{};
  decltype(&::av_get_bytes_per_sample) av_get_bytes_per_sample{};
  decltype(&::av_sample_fmt_is_planar) av_sample_fmt_is_planar{};
  decltype(&::av_frame_get_buffer) av_frame_get_buffer{};
};
// The calling worker's RuntimeLease must outlive every API call and AV object.
[[nodiscard]] const Api& api() noexcept;
}
