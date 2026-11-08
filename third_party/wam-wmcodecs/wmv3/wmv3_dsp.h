/* SPDX-License-Identifier: LGPL-2.1-or-later
 * WMV3 DSP primitives. Derived from FFmpeg libavcodec/vc1dsp.c. See ../NOTICE.
 */
#ifndef WMV3_DSP_H
#define WMV3_DSP_H
#include <stddef.h>
#include <stdint.h>

void wmv3_v_overlap(uint8_t *src, ptrdiff_t stride);
void wmv3_h_overlap(uint8_t *src, ptrdiff_t stride);
void wmv3_v_s_overlap(int16_t *top, int16_t *bottom);
void wmv3_h_s_overlap(int16_t *left, int16_t *right, ptrdiff_t left_stride, ptrdiff_t right_stride, int flags);
void wmv3_v_loop_filter4(uint8_t *src, ptrdiff_t stride, int pq);
void wmv3_h_loop_filter4(uint8_t *src, ptrdiff_t stride, int pq);
void wmv3_v_loop_filter8(uint8_t *src, ptrdiff_t stride, int pq);
void wmv3_h_loop_filter8(uint8_t *src, ptrdiff_t stride, int pq);
void wmv3_v_loop_filter16(uint8_t *src, ptrdiff_t stride, int pq);
void wmv3_h_loop_filter16(uint8_t *src, ptrdiff_t stride, int pq);
void wmv3_inv_trans_8x8(int16_t block[64]);
void wmv3_inv_trans_8x8_dc(uint8_t *dest, ptrdiff_t stride, int16_t *block);
void wmv3_inv_trans_8x4(uint8_t *dest, ptrdiff_t stride, int16_t *block);
void wmv3_inv_trans_8x4_dc(uint8_t *dest, ptrdiff_t stride, int16_t *block);
void wmv3_inv_trans_4x8(uint8_t *dest, ptrdiff_t stride, int16_t *block);
void wmv3_inv_trans_4x8_dc(uint8_t *dest, ptrdiff_t stride, int16_t *block);
void wmv3_inv_trans_4x4(uint8_t *dest, ptrdiff_t stride, int16_t *block);
void wmv3_inv_trans_4x4_dc(uint8_t *dest, ptrdiff_t stride, int16_t *block);
void wmv3_put_mspel16(uint8_t *dst, const uint8_t *src, ptrdiff_t stride, int hmode, int vmode, int rnd);
void wmv3_put_mspel8(uint8_t *dst, const uint8_t *src, ptrdiff_t stride, int hmode, int vmode, int rnd);

#endif
