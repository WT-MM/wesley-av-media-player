#ifndef WAMKIT_ENCODING_H
#define WAMKIT_ENCODING_H
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <WAMKit/WAMKit.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Additive encoding API, version 1. Existing playback ABI is unchanged.
   All operations are synchronous and must run on a host-owned serial worker,
   never a real-time audio callback. A handle must not be used concurrently.
   No microphone access, capture, UI, or implicit software video fallback.
   At most four encoders (audio and video combined) per framework image. */
typedef struct wam_video_encoder *wam_video_encoder_t;
typedef struct wam_audio_encoder *wam_audio_encoder_t;
typedef struct {
  uint32_t struct_size;
  uint32_t hardware_accelerated;
  uint64_t input_frames;
  char implementation[64];
} wam_encoder_info_t;
/* Initialize struct_size before copying. Identity is the selected backend,
   not an inference from the chip model. Same worker/ownership rules apply. */
WAM_EXPORT wam_status_t wam_video_encoder_copy_info(wam_video_encoder_t encoder,
                                                    wam_encoder_info_t *info);
WAM_EXPORT wam_status_t wam_audio_encoder_copy_info(wam_audio_encoder_t encoder,
                                                    wam_encoder_info_t *info);
enum { WAM_ENCODE_H264 = 1, WAM_ENCODE_HEVC = 2 };
typedef struct {
  uint32_t struct_size;
  uint32_t codec;         /* WAM_ENCODE_H264 / HEVC; 8-bit SDR only */
  uint32_t width, height; /* even, 16..4096; at most 4096*2160 pixels */
  uint32_t bitrate;       /* 100,000..100,000,000 bits/sec */
  uint32_t reserved;
} wam_video_encoder_config_t;

/* Creation requires VideoToolbox hardware and verifies the selected session.
   Success is proof of hardware selection for this exact configuration. */
WAM_EXPORT wam_status_t
wam_video_encoder_create(const wam_video_encoder_config_t *config,
                         wam_video_encoder_t *out_encoder, wam_error_t *error);
/* NV12 video-range input, dimensions matching config, BT.709 SDR content.
   Strictly increasing nonnegative PTS, positive duration, no overlapping
   frames. Input is borrowed through return. Output is +1 retained and owned by
   caller. Each call drains VideoToolbox; no frame reordering or unbounded
   output queue. A backend failure is terminal; release the handle. Validation
   errors are retryable. */
WAM_EXPORT wam_status_t wam_video_encoder_encode(
    wam_video_encoder_t encoder, CVPixelBufferRef pixels, wam_time_t pts,
    wam_time_t duration, CMSampleBufferRef *out_sample, wam_error_t *error);
WAM_EXPORT void wam_video_encoder_release(wam_video_encoder_t encoder);

typedef struct {
  uint32_t struct_size;
  uint32_t sample_rate; /* 44100 or 48000 */
  uint32_t channels;    /* 1 or 2 */
  uint32_t
      require_hardware; /* 0 or 1; macOS AAC hardware requests are refused */
  uint32_t reserved;
} wam_audio_encoder_config_t;
/* Native AudioToolbox AAC-LC to a new M4A file. This macOS backend explicitly
   selects Apple's SOFTWARE AAC codec, never advertises media-engine use.
   Existing files are never overwritten. Host supplies file authorization. */
WAM_EXPORT wam_status_t wam_audio_encoder_create(
    const wam_audio_encoder_config_t *config, const char *absolute_utf8_path,
    wam_audio_encoder_t *out_encoder, wam_error_t *error);
/* Contiguous interleaved Float32 PCM at the configured rate, -1..1, finite.
   1..4096 frames per call; samples borrowed through return. */
WAM_EXPORT wam_status_t wam_audio_encoder_write(wam_audio_encoder_t encoder,
                                                const float *samples,
                                                uint32_t frames,
                                                wam_error_t *error);
/* Flushes AAC tail and closes the container. Idempotent after successful
   finish. Release without finish closes but does not promise a completed
   recording. On any backend failure the file may be partial; the host owns
   recovery/removal. */
WAM_EXPORT wam_status_t wam_audio_encoder_finish(wam_audio_encoder_t encoder,
                                                 wam_error_t *error);
WAM_EXPORT void wam_audio_encoder_release(wam_audio_encoder_t encoder);
#ifdef __cplusplus
}
#endif
#endif
