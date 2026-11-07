#pragma once

// A libvpx-encoded VP8 stream and the CoreMedia carriage the Matroska factory
// gives it, generated in the test rather than embedded as a binary fixture.

#include "platform/macos/software_vp8_decoder.hpp"

#include <CoreMedia/CoreMedia.h>

#include <vpx/vp8cx.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vpx_image.h>

#include <cstdint>
#include <vector>

namespace wam::test {

using wam::macos::kWamVideoCodecTypeVp8;

struct EncodedStream {
  std::vector<std::vector<std::uint8_t>> frames;
  std::vector<bool> keyFrames;
  int width{0};
  int height{0};
};

// Encodes `count` frames of a moving pattern. The first is a key frame.
inline EncodedStream encodeVp8(int width, int height, int count) {
  EncodedStream stream;
  stream.width = width;
  stream.height = height;

  vpx_codec_enc_cfg_t config{};
  if (vpx_codec_enc_config_default(vpx_codec_vp8_cx(), &config, 0) !=
      VPX_CODEC_OK) {
    return stream;
  }
  config.g_w = static_cast<unsigned int>(width);
  config.g_h = static_cast<unsigned int>(height);
  config.g_timebase.num = 1;
  config.g_timebase.den = 30;
  config.rc_target_bitrate = 500;
  config.g_lag_in_frames = 0;
  config.kf_max_dist = 30;
  config.g_threads = 1;

  vpx_codec_ctx_t encoder{};
  if (vpx_codec_enc_init(&encoder, vpx_codec_vp8_cx(), &config, 0) !=
      VPX_CODEC_OK) {
    return stream;
  }
  vpx_image_t image{};
  if (vpx_img_alloc(&image, VPX_IMG_FMT_I420,
                    static_cast<unsigned int>(width),
                    static_cast<unsigned int>(height), 32) == nullptr) {
    vpx_codec_destroy(&encoder);
    return stream;
  }

  for (int index = 0; index <= count; ++index) {
    const bool flush = index == count;
    if (!flush) {
      for (int row = 0; row < height; ++row) {
        for (int column = 0; column < width; ++column) {
          image.planes[VPX_PLANE_Y][row * image.stride[VPX_PLANE_Y] + column] =
              static_cast<unsigned char>(((row + column + index * 16) / 16) % 2
                                             ? 200
                                             : 40);
        }
      }
      for (int row = 0; row < height / 2; ++row) {
        for (int column = 0; column < width / 2; ++column) {
          image.planes[VPX_PLANE_U][row * image.stride[VPX_PLANE_U] + column] =
              static_cast<unsigned char>(90 + index);
          image.planes[VPX_PLANE_V][row * image.stride[VPX_PLANE_V] + column] =
              static_cast<unsigned char>(160 - index);
        }
      }
    }
    if (vpx_codec_encode(&encoder, flush ? nullptr : &image, index, 1, 0,
                         VPX_DL_GOOD_QUALITY) != VPX_CODEC_OK) {
      break;
    }
    vpx_codec_iter_t iterator = nullptr;
    const vpx_codec_cx_pkt_t *packet = nullptr;
    while ((packet = vpx_codec_get_cx_data(&encoder, &iterator)) != nullptr) {
      if (packet->kind != VPX_CODEC_CX_FRAME_PKT) {
        continue;
      }
      const auto *bytes =
          static_cast<const std::uint8_t *>(packet->data.frame.buf);
      stream.frames.emplace_back(bytes, bytes + packet->data.frame.sz);
      stream.keyFrames.push_back(
          (packet->data.frame.flags & VPX_FRAME_IS_KEY) != 0);
    }
  }
  vpx_img_free(&image);
  vpx_codec_destroy(&encoder);
  return stream;
}

inline CMVideoFormatDescriptionRef makeVp8FormatDescription(int width, int height) {
  CMVideoFormatDescriptionRef description = nullptr;
  if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                     kWamVideoCodecTypeVp8, width, height,
                                     nullptr, &description) != noErr) {
    return nullptr;
  }
  return description;
}

inline CMSampleBufferRef makeVp8Sample(const std::vector<std::uint8_t> &bytes,
                             CMVideoFormatDescriptionRef description,
                             std::int64_t frameIndex, bool keyFrame) {
  CMBlockBufferRef block = nullptr;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr,
                                         bytes.size(), kCFAllocatorDefault,
                                         nullptr, 0, bytes.size(), 0,
                                         &block) != kCMBlockBufferNoErr) {
    return nullptr;
  }
  if (CMBlockBufferReplaceDataBytes(bytes.data(), block, 0, bytes.size()) !=
      kCMBlockBufferNoErr) {
    CFRelease(block);
    return nullptr;
  }
  CMSampleTimingInfo timing{CMTimeMake(1, 30), CMTimeMake(frameIndex, 30),
                            kCMTimeInvalid};
  const std::size_t size = bytes.size();
  CMSampleBufferRef sample = nullptr;
  const OSStatus status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, description, 1, 1, &timing, 1, &size,
      &sample);
  CFRelease(block);
  if (status != noErr) {
    return nullptr;
  }
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
  if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
    auto entry = static_cast<CFMutableDictionaryRef>(
        const_cast<void *>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(entry, kCMSampleAttachmentKey_NotSync,
                         keyFrame ? kCFBooleanFalse : kCFBooleanTrue);
  }
  return sample;
}

}  // namespace wam::test
