// SPDX-License-Identifier: LGPL-2.1-or-later
//
// WMA v2 (codec tag 0x0161) audio decoder. C ABI so the MIT-licensed
// application only ever links this LGPL library dynamically.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define WAM_WMCODECS_API __attribute__((visibility("default")))
#else
#define WAM_WMCODECS_API
#endif

typedef struct wam_wma_decoder wam_wma_decoder;

// WAVEFORMATEX fields of the stream. `extradata` is the cbSize bytes that
// follow WAVEFORMATEX (wmav2: 4 bytes samples-per-block, 2 bytes flags).
typedef struct wam_wma_config {
  int channels;     // 1 or 2
  int sample_rate;  // <= 50000
  int64_t bit_rate; // nAvgBytesPerSec * 8
  int block_align;  // bytes per ASF payload
  const uint8_t* extradata;
  int extradata_size;
} wam_wma_config;

// Returns NULL when the configuration is unsupported.
WAM_WMCODECS_API wam_wma_decoder* wam_wma_create(const wam_wma_config* config);
WAM_WMCODECS_API void wam_wma_destroy(wam_wma_decoder* decoder);

// Samples per channel of one frame (2048 at 44.1/48 kHz, 1024 at 22.05 kHz).
WAM_WMCODECS_API int wam_wma_frame_length(const wam_wma_decoder* decoder);
// Upper bound on samples per channel one wam_wma_decode call produces.
WAM_WMCODECS_API int wam_wma_max_samples(const wam_wma_decoder* decoder);

// Decodes one payload (the first block_align bytes of `data` are used).
// Writes planar float PCM to out[channel][0..), at most `capacity` samples
// per channel. Returns samples per channel written (0 when the payload only
// fills the bit reservoir) or a negative value on corrupt input; after an
// error the next payload decodes normally.
WAM_WMCODECS_API int wam_wma_decode(wam_wma_decoder* decoder, const uint8_t* data,
                                    int size, float* const* out, int capacity);

// At end of stream: writes the final overlap tail (one frame) once and then
// returns 0.
WAM_WMCODECS_API int wam_wma_drain(wam_wma_decoder* decoder, float* const* out,
                                   int capacity);

// Discards the bit reservoir (call after a seek).
WAM_WMCODECS_API void wam_wma_flush(wam_wma_decoder* decoder);

// Frames the payload's superframe header states: the 4-bit count for a
// bit-reservoir stream, which includes the frame begun in the previous
// payload, and 1 otherwise. -1 when `size` is shorter than block_align.
WAM_WMCODECS_API int wam_wma_superframe_frames(const wam_wma_decoder* decoder,
                                               const uint8_t* data, int size);

// Nonzero when the stream codes high bands as noise. The noise generator
// runs across the whole stream, so a decode begun after the first payload
// never reproduces the continuous decode.
WAM_WMCODECS_API int wam_wma_uses_noise_coding(const wam_wma_decoder* decoder);

#ifdef __cplusplus
}
#endif
