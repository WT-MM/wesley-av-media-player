/* SPDX-License-Identifier: LGPL-2.1-or-later
 * WMV3 (SMPTE 421M VC-1 Simple/Main profile, progressive) video decoder.
 * See ../NOTICE for credits.
 */
#ifndef WMV3DEC_H
#define WMV3DEC_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef WMV3_API
#define WMV3_API
#endif

typedef struct Wmv3Decoder Wmv3Decoder;

typedef struct Wmv3Frame {
    const uint8_t *data[3]; /* Y, Cb, Cr (4:2:0, 8-bit) */
    int linesize[3];
    int width, height;
    int keyframe;
} Wmv3Frame;

/* extradata: the 4+ byte STRUCT_C sequence header from the ASF/AVI
 * BITMAPINFOHEADER. Returns NULL on unsupported/invalid input. */
WMV3_API Wmv3Decoder *wmv3_decoder_open(const uint8_t *extradata, size_t extradata_size,
                               int width, int height);
WMV3_API void wmv3_decoder_close(Wmv3Decoder *dec);

/* 1 when wmv3_decoder_open() would accept this STRUCT_C, without allocating:
 * an admission probe. */
WMV3_API int wmv3_sequence_supported(const uint8_t *extradata, size_t extradata_size);

/* Decodes one packet. Returns 1 if *out holds a picture, 0 if the packet is a
 * skipped frame (the previous picture repeats), negative on error. The frame
 * stays valid until the next call. */
WMV3_API int wmv3_decode(Wmv3Decoder *dec, const uint8_t *packet, size_t size, Wmv3Frame *out);

#ifdef __cplusplus
}
#endif
#endif
