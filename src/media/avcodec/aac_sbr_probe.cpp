#include "aac_sbr_probe.hpp"
#include "api.hpp"
#include "runtime.hpp"
#include "media/codec/aac.hpp"
#include <cstring>

namespace wam::media::avcodec {
namespace {

using codec::AacSbrDetection;

// Decodes the access units with libavcodec's AAC decoder, which follows an
// SBR extension payload in an LC stream by doubling its output rate and
// reporting the HE profiles. A decoder that cannot be loaded, or that refuses
// the configuration or a unit, leaves the question Unavailable.
AacSbrDetection detect(std::span<const std::byte> config,
                       std::span<const std::span<const std::byte>> units) noexcept {
  if (config.size() < 2 || units.empty()) return AacSbrDetection::Unavailable;
  const auto index = static_cast<std::uint8_t>(
      ((std::to_integer<unsigned>(config[0]) & 7U) << 1U) |
      (std::to_integer<unsigned>(config[1]) >> 7U));
  const std::uint32_t core = codec::aacSampleRateForIndex(index);
  if (core == 0) return AacSbrDetection::Unavailable;
  RuntimeLease lease;
  if (lease.acquire()) return AacSbrDetection::Unavailable;
  const Api& av = api();
  const AVCodec* decoder = av.avcodec_find_decoder(AV_CODEC_ID_AAC);
  AVCodecContext* context = decoder ? av.avcodec_alloc_context3(decoder) : nullptr;
  AVPacket* packet = av.av_packet_alloc();
  AVFrame* frame = av.av_frame_alloc();
  std::uint8_t* data = nullptr;
  AacSbrDetection verdict = AacSbrDetection::Unavailable;
  if (context && packet && frame) {
    context->thread_count = 1;
    context->extradata = static_cast<std::uint8_t*>(
        av.av_mallocz(config.size() + AV_INPUT_BUFFER_PADDING_SIZE));
    if (context->extradata) {
      std::memcpy(context->extradata, config.data(), config.size());
      context->extradata_size = static_cast<int>(config.size());
    }
    if (context->extradata && av.avcodec_open2(context, decoder, nullptr) >= 0) {
      verdict = AacSbrDetection::Absent;
      for (const auto unit : units) {
        av.av_free(data);
        data = static_cast<std::uint8_t*>(
            av.av_mallocz(unit.size() + AV_INPUT_BUFFER_PADDING_SIZE));
        if (!data || unit.empty()) { verdict = AacSbrDetection::Unavailable; break; }
        std::memcpy(data, unit.data(), unit.size());
        packet->data = data;
        packet->size = static_cast<int>(unit.size());
        if (av.avcodec_send_packet(context, packet) < 0) {
          verdict = AacSbrDetection::Unavailable;
          break;
        }
        while (av.avcodec_receive_frame(context, frame) >= 0) {
          if (frame->sample_rate == static_cast<int>(2 * core) ||
              context->profile == AV_PROFILE_AAC_HE ||
              context->profile == AV_PROFILE_AAC_HE_V2) {
            verdict = AacSbrDetection::Present;
          }
          av.av_frame_unref(frame);
        }
        if (verdict == AacSbrDetection::Present) break;
      }
      packet->data = nullptr;
      packet->size = 0;
    }
  }
  av.av_free(data);
  av.av_frame_free(&frame);
  av.av_packet_free(&packet);
  av.avcodec_free_context(&context);
  return verdict;
}

} // namespace

void installAacSbrDetector() noexcept { codec::installAacSbrDetector(&detect); }

} // namespace wam::media::avcodec
