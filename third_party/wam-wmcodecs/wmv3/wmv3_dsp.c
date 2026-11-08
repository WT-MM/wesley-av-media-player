/* SPDX-License-Identifier: LGPL-2.1-or-later
 * WMV3 (VC-1 Simple/Main) DSP: overlap smoothing, in-loop deblocking,
 * integer inverse transforms and bicubic motion compensation.
 * Derived from FFmpeg libavcodec/vc1dsp.c (LGPL-2.1-or-later). See ../NOTICE.
 */
#include "wmv3_dsp.h"
#include <stdlib.h>
#include <string.h>

#define av_always_inline inline __attribute__((always_inline))
#define FFABS(a) ((a) >= 0 ? (a) : -(a))
#define FFMIN(a, b) ((a) > (b) ? (b) : (a))
#define FFSIGN(a) ((a) > 0 ? 1 : -1)
static inline uint8_t av_clip_uint8(int a) { return (a & ~0xFF) ? (uint8_t)((~a) >> 31) : (uint8_t)a; }

void wmv3_v_overlap(uint8_t *src, ptrdiff_t stride)
{
    int i;
    int a, b, c, d;
    int d1, d2;
    int rnd = 1;
    for (i = 0; i < 8; i++) {
        a  = src[-2 * stride];
        b  = src[-stride];
        c  = src[0];
        d  = src[stride];
        d1 = (a - d + 3 + rnd) >> 3;
        d2 = (a - d + b - c + 4 - rnd) >> 3;

        src[-2 * stride] = a - d1;
        src[-stride]     = av_clip_uint8(b - d2);
        src[0]           = av_clip_uint8(c + d2);
        src[stride]      = d + d1;
        src++;
        rnd = !rnd;
    }
}

/* Apply overlap transform to vertical edge */
void wmv3_h_overlap(uint8_t *src, ptrdiff_t stride)
{
    int i;
    int a, b, c, d;
    int d1, d2;
    int rnd = 1;
    for (i = 0; i < 8; i++) {
        a  = src[-2];
        b  = src[-1];
        c  = src[0];
        d  = src[1];
        d1 = (a - d + 3 + rnd) >> 3;
        d2 = (a - d + b - c + 4 - rnd) >> 3;

        src[-2] = a - d1;
        src[-1] = av_clip_uint8(b - d2);
        src[0]  = av_clip_uint8(c + d2);
        src[1]  = d + d1;
        src    += stride;
        rnd     = !rnd;
    }
}

void wmv3_v_s_overlap(int16_t *top, int16_t *bottom)
{
    int i;
    int a, b, c, d;
    int d1, d2;
    int rnd1 = 4, rnd2 = 3;
    for (i = 0; i < 8; i++) {
        a  = top[48];
        b  = top[56];
        c  = bottom[0];
        d  = bottom[8];
        d1 = a - d;
        d2 = a - d + b - c;

        top[48]   = ((a * 8) - d1 + rnd1) >> 3;
        top[56]   = ((b * 8) - d2 + rnd2) >> 3;
        bottom[0] = ((c * 8) + d2 + rnd1) >> 3;
        bottom[8] = ((d * 8) + d1 + rnd2) >> 3;

        bottom++;
        top++;
        rnd2 = 7 - rnd2;
        rnd1 = 7 - rnd1;
    }
}

void wmv3_h_s_overlap(int16_t *left, int16_t *right, ptrdiff_t left_stride, ptrdiff_t right_stride, int flags)
{
    int i;
    int a, b, c, d;
    int d1, d2;
    int rnd1 = flags & 2 ? 3 : 4;
    int rnd2 = 7 - rnd1;
    for (i = 0; i < 8; i++) {
        a  = left[6];
        b  = left[7];
        c  = right[0];
        d  = right[1];
        d1 = a - d;
        d2 = a - d + b - c;

        left[6]  = ((a * 8) - d1 + rnd1) >> 3;
        left[7]  = ((b * 8) - d2 + rnd2) >> 3;
        right[0] = ((c * 8) + d2 + rnd1) >> 3;
        right[1] = ((d * 8) + d1 + rnd2) >> 3;

        right += right_stride;
        left  += left_stride;
        if (flags & 1) {
            rnd2   = 7 - rnd2;
            rnd1   = 7 - rnd1;
        }
    }
}

/**
 * VC-1 in-loop deblocking filter for one line
 * @param src source block type
 * @param stride block stride
 * @param pq block quantizer
 * @return whether other 3 pairs should be filtered or not
 * @see 8.6
 */
static av_always_inline int vc1_filter_line(uint8_t *src, ptrdiff_t stride, int pq)
{
    int a0 = (2 * (src[-2 * stride] - src[1 * stride]) -
              5 * (src[-1 * stride] - src[0 * stride]) + 4) >> 3;
    int a0_sign = a0 >> 31;        /* Store sign */

    a0 = (a0 ^ a0_sign) - a0_sign; /* a0 = FFABS(a0); */
    if (a0 < pq) {
        int a1 = FFABS((2 * (src[-4 * stride] - src[-1 * stride]) -
                        5 * (src[-3 * stride] - src[-2 * stride]) + 4) >> 3);
        int a2 = FFABS((2 * (src[ 0 * stride] - src[ 3 * stride]) -
                        5 * (src[ 1 * stride] - src[ 2 * stride]) + 4) >> 3);
        if (a1 < a0 || a2 < a0) {
            int clip      = src[-1 * stride] - src[0 * stride];
            int clip_sign = clip >> 31;

            clip = ((clip ^ clip_sign) - clip_sign) >> 1;
            if (clip) {
                int a3     = FFMIN(a1, a2);
                int d      = 5 * (a3 - a0);
                int d_sign = (d >> 31);

                d       = ((d ^ d_sign) - d_sign) >> 3;
                d_sign ^= a0_sign;

                if (d_sign ^ clip_sign)
                    d = 0;
                else {
                    d = FFMIN(d, clip);
                    d = (d ^ d_sign) - d_sign; /* Restore sign */
                    src[-1 * stride] = av_clip_uint8(src[-1 * stride] - d);
                    src[ 0 * stride] = av_clip_uint8(src[ 0 * stride] + d);
                }
                return 1;
            }
        }
    }
    return 0;
}

/**
 * VC-1 in-loop deblocking filter
 * @param src source block type
 * @param step distance between horizontally adjacent elements
 * @param stride distance between vertically adjacent elements
 * @param len edge length to filter (4 or 8 pixels)
 * @param pq block quantizer
 * @see 8.6
 */
static av_always_inline void vc1_loop_filter(uint8_t *src, ptrdiff_t step,
                                             ptrdiff_t stride, int len, int pq)
{
    int i;
    int filt3;

    for (i = 0; i < len; i += 4) {
        filt3 = vc1_filter_line(src + 2 * step, stride, pq);
        if (filt3) {
            vc1_filter_line(src + 0 * step, stride, pq);
            vc1_filter_line(src + 1 * step, stride, pq);
            vc1_filter_line(src + 3 * step, stride, pq);
        }
        src += step * 4;
    }
}

void wmv3_v_loop_filter4(uint8_t *src, ptrdiff_t stride, int pq)
{
    vc1_loop_filter(src, 1, stride, 4, pq);
}

void wmv3_h_loop_filter4(uint8_t *src, ptrdiff_t stride, int pq)
{
    vc1_loop_filter(src, stride, 1, 4, pq);
}

void wmv3_v_loop_filter8(uint8_t *src, ptrdiff_t stride, int pq)
{
    vc1_loop_filter(src, 1, stride, 8, pq);
}

void wmv3_h_loop_filter8(uint8_t *src, ptrdiff_t stride, int pq)
{
    vc1_loop_filter(src, stride, 1, 8, pq);
}

void wmv3_v_loop_filter16(uint8_t *src, ptrdiff_t stride, int pq)
{
    vc1_loop_filter(src, 1, stride, 16, pq);
}

void wmv3_h_loop_filter16(uint8_t *src, ptrdiff_t stride, int pq)
{
    vc1_loop_filter(src, stride, 1, 16, pq);
}

/* Do inverse transform on 8x8 block */
void wmv3_inv_trans_8x8_dc(uint8_t *dest, ptrdiff_t stride, int16_t *block)
{
    int i;
    int dc = block[0];

    dc = (3 * dc +  1) >> 1;
    dc = (3 * dc + 16) >> 5;

    for (i = 0; i < 8; i++) {
        dest[0] = av_clip_uint8(dest[0] + dc);
        dest[1] = av_clip_uint8(dest[1] + dc);
        dest[2] = av_clip_uint8(dest[2] + dc);
        dest[3] = av_clip_uint8(dest[3] + dc);
        dest[4] = av_clip_uint8(dest[4] + dc);
        dest[5] = av_clip_uint8(dest[5] + dc);
        dest[6] = av_clip_uint8(dest[6] + dc);
        dest[7] = av_clip_uint8(dest[7] + dc);
        dest += stride;
    }
}

void wmv3_inv_trans_8x8(int16_t block[64])
{
    int i;
    register int t1, t2, t3, t4, t5, t6, t7, t8;
    int16_t *src, *dst, temp[64];

    src = block;
    dst = temp;
    for (i = 0; i < 8; i++) {
        t1 = 12 * (src[ 0] + src[32]) + 4;
        t2 = 12 * (src[ 0] - src[32]) + 4;
        t3 = 16 * src[16] +  6 * src[48];
        t4 =  6 * src[16] - 16 * src[48];

        t5 = t1 + t3;
        t6 = t2 + t4;
        t7 = t2 - t4;
        t8 = t1 - t3;

        t1 = 16 * src[ 8] + 15 * src[24] +  9 * src[40] +  4 * src[56];
        t2 = 15 * src[ 8] -  4 * src[24] - 16 * src[40] -  9 * src[56];
        t3 =  9 * src[ 8] - 16 * src[24] +  4 * src[40] + 15 * src[56];
        t4 =  4 * src[ 8] -  9 * src[24] + 15 * src[40] - 16 * src[56];

        dst[0] = (t5 + t1) >> 3;
        dst[1] = (t6 + t2) >> 3;
        dst[2] = (t7 + t3) >> 3;
        dst[3] = (t8 + t4) >> 3;
        dst[4] = (t8 - t4) >> 3;
        dst[5] = (t7 - t3) >> 3;
        dst[6] = (t6 - t2) >> 3;
        dst[7] = (t5 - t1) >> 3;

        src += 1;
        dst += 8;
    }

    src = temp;
    dst = block;
    for (i = 0; i < 8; i++) {
        t1 = 12 * (src[ 0] + src[32]) + 64;
        t2 = 12 * (src[ 0] - src[32]) + 64;
        t3 = 16 * src[16] +  6 * src[48];
        t4 =  6 * src[16] - 16 * src[48];

        t5 = t1 + t3;
        t6 = t2 + t4;
        t7 = t2 - t4;
        t8 = t1 - t3;

        t1 = 16 * src[ 8] + 15 * src[24] +  9 * src[40] +  4 * src[56];
        t2 = 15 * src[ 8] -  4 * src[24] - 16 * src[40] -  9 * src[56];
        t3 =  9 * src[ 8] - 16 * src[24] +  4 * src[40] + 15 * src[56];
        t4 =  4 * src[ 8] -  9 * src[24] + 15 * src[40] - 16 * src[56];

        dst[ 0] = (t5 + t1) >> 7;
        dst[ 8] = (t6 + t2) >> 7;
        dst[16] = (t7 + t3) >> 7;
        dst[24] = (t8 + t4) >> 7;
        dst[32] = (t8 - t4 + 1) >> 7;
        dst[40] = (t7 - t3 + 1) >> 7;
        dst[48] = (t6 - t2 + 1) >> 7;
        dst[56] = (t5 - t1 + 1) >> 7;

        src++;
        dst++;
    }
}

/* Do inverse transform on 8x4 part of block */
void wmv3_inv_trans_8x4_dc(uint8_t *dest, ptrdiff_t stride, int16_t *block)
{
    int i;
    int dc = block[0];

    dc =  (3 * dc +  1) >> 1;
    dc = (17 * dc + 64) >> 7;

    for (i = 0; i < 4; i++) {
        dest[0] = av_clip_uint8(dest[0] + dc);
        dest[1] = av_clip_uint8(dest[1] + dc);
        dest[2] = av_clip_uint8(dest[2] + dc);
        dest[3] = av_clip_uint8(dest[3] + dc);
        dest[4] = av_clip_uint8(dest[4] + dc);
        dest[5] = av_clip_uint8(dest[5] + dc);
        dest[6] = av_clip_uint8(dest[6] + dc);
        dest[7] = av_clip_uint8(dest[7] + dc);
        dest += stride;
    }
}

void wmv3_inv_trans_8x4(uint8_t *dest, ptrdiff_t stride, int16_t *block)
{
    int i;
    register int t1, t2, t3, t4, t5, t6, t7, t8;
    int16_t *src, *dst;

    src = block;
    dst = block;

    for (i = 0; i < 4; i++) {
        t1 = 12 * (src[0] + src[4]) + 4;
        t2 = 12 * (src[0] - src[4]) + 4;
        t3 = 16 * src[2] +  6 * src[6];
        t4 =  6 * src[2] - 16 * src[6];

        t5 = t1 + t3;
        t6 = t2 + t4;
        t7 = t2 - t4;
        t8 = t1 - t3;

        t1 = 16 * src[1] + 15 * src[3] +  9 * src[5] +  4 * src[7];
        t2 = 15 * src[1] -  4 * src[3] - 16 * src[5] -  9 * src[7];
        t3 =  9 * src[1] - 16 * src[3] +  4 * src[5] + 15 * src[7];
        t4 =  4 * src[1] -  9 * src[3] + 15 * src[5] - 16 * src[7];

        dst[0] = (t5 + t1) >> 3;
        dst[1] = (t6 + t2) >> 3;
        dst[2] = (t7 + t3) >> 3;
        dst[3] = (t8 + t4) >> 3;
        dst[4] = (t8 - t4) >> 3;
        dst[5] = (t7 - t3) >> 3;
        dst[6] = (t6 - t2) >> 3;
        dst[7] = (t5 - t1) >> 3;

        src += 8;
        dst += 8;
    }

    src = block;
    for (i = 0; i < 8; i++) {
        t1 = 17 * (src[ 0] + src[16]) + 64;
        t2 = 17 * (src[ 0] - src[16]) + 64;
        t3 = 22 * src[ 8] + 10 * src[24];
        t4 = 22 * src[24] - 10 * src[ 8];

        dest[0 * stride] = av_clip_uint8(dest[0 * stride] + ((t1 + t3) >> 7));
        dest[1 * stride] = av_clip_uint8(dest[1 * stride] + ((t2 - t4) >> 7));
        dest[2 * stride] = av_clip_uint8(dest[2 * stride] + ((t2 + t4) >> 7));
        dest[3 * stride] = av_clip_uint8(dest[3 * stride] + ((t1 - t3) >> 7));

        src++;
        dest++;
    }
}

/* Do inverse transform on 4x8 parts of block */
void wmv3_inv_trans_4x8_dc(uint8_t *dest, ptrdiff_t stride, int16_t *block)
{
    int i;
    int dc = block[0];

    dc = (17 * dc +  4) >> 3;
    dc = (12 * dc + 64) >> 7;

    for (i = 0; i < 8; i++) {
        dest[0] = av_clip_uint8(dest[0] + dc);
        dest[1] = av_clip_uint8(dest[1] + dc);
        dest[2] = av_clip_uint8(dest[2] + dc);
        dest[3] = av_clip_uint8(dest[3] + dc);
        dest += stride;
    }
}

void wmv3_inv_trans_4x8(uint8_t *dest, ptrdiff_t stride, int16_t *block)
{
    int i;
    register int t1, t2, t3, t4, t5, t6, t7, t8;
    int16_t *src, *dst;

    src = block;
    dst = block;

    for (i = 0; i < 8; i++) {
        t1 = 17 * (src[0] + src[2]) + 4;
        t2 = 17 * (src[0] - src[2]) + 4;
        t3 = 22 * src[1] + 10 * src[3];
        t4 = 22 * src[3] - 10 * src[1];

        dst[0] = (t1 + t3) >> 3;
        dst[1] = (t2 - t4) >> 3;
        dst[2] = (t2 + t4) >> 3;
        dst[3] = (t1 - t3) >> 3;

        src += 8;
        dst += 8;
    }

    src = block;
    for (i = 0; i < 4; i++) {
        t1 = 12 * (src[ 0] + src[32]) + 64;
        t2 = 12 * (src[ 0] - src[32]) + 64;
        t3 = 16 * src[16] +  6 * src[48];
        t4 =  6 * src[16] - 16 * src[48];

        t5 = t1 + t3;
        t6 = t2 + t4;
        t7 = t2 - t4;
        t8 = t1 - t3;

        t1 = 16 * src[ 8] + 15 * src[24] +  9 * src[40] +  4 * src[56];
        t2 = 15 * src[ 8] -  4 * src[24] - 16 * src[40] -  9 * src[56];
        t3 =  9 * src[ 8] - 16 * src[24] +  4 * src[40] + 15 * src[56];
        t4 =  4 * src[ 8] -  9 * src[24] + 15 * src[40] - 16 * src[56];

        dest[0 * stride] = av_clip_uint8(dest[0 * stride] + ((t5 + t1)     >> 7));
        dest[1 * stride] = av_clip_uint8(dest[1 * stride] + ((t6 + t2)     >> 7));
        dest[2 * stride] = av_clip_uint8(dest[2 * stride] + ((t7 + t3)     >> 7));
        dest[3 * stride] = av_clip_uint8(dest[3 * stride] + ((t8 + t4)     >> 7));
        dest[4 * stride] = av_clip_uint8(dest[4 * stride] + ((t8 - t4 + 1) >> 7));
        dest[5 * stride] = av_clip_uint8(dest[5 * stride] + ((t7 - t3 + 1) >> 7));
        dest[6 * stride] = av_clip_uint8(dest[6 * stride] + ((t6 - t2 + 1) >> 7));
        dest[7 * stride] = av_clip_uint8(dest[7 * stride] + ((t5 - t1 + 1) >> 7));

        src++;
        dest++;
    }
}

/* Do inverse transform on 4x4 part of block */
void wmv3_inv_trans_4x4_dc(uint8_t *dest, ptrdiff_t stride, int16_t *block)
{
    int i;
    int dc = block[0];

    dc = (17 * dc +  4) >> 3;
    dc = (17 * dc + 64) >> 7;

    for (i = 0; i < 4; i++) {
        dest[0] = av_clip_uint8(dest[0] + dc);
        dest[1] = av_clip_uint8(dest[1] + dc);
        dest[2] = av_clip_uint8(dest[2] + dc);
        dest[3] = av_clip_uint8(dest[3] + dc);
        dest += stride;
    }
}

void wmv3_inv_trans_4x4(uint8_t *dest, ptrdiff_t stride, int16_t *block)
{
    int i;
    register int t1, t2, t3, t4;
    int16_t *src, *dst;

    src = block;
    dst = block;
    for (i = 0; i < 4; i++) {
        t1 = 17 * (src[0] + src[2]) + 4;
        t2 = 17 * (src[0] - src[2]) + 4;
        t3 = 22 * src[1] + 10 * src[3];
        t4 = 22 * src[3] - 10 * src[1];

        dst[0] = (t1 + t3) >> 3;
        dst[1] = (t2 - t4) >> 3;
        dst[2] = (t2 + t4) >> 3;
        dst[3] = (t1 - t3) >> 3;

        src += 8;
        dst += 8;
    }

    src = block;
    for (i = 0; i < 4; i++) {
        t1 = 17 * (src[0] + src[16]) + 64;
        t2 = 17 * (src[0] - src[16]) + 64;
        t3 = 22 * src[8] + 10 * src[24];
        t4 = 22 * src[24] - 10 * src[8];

        dest[0 * stride] = av_clip_uint8(dest[0 * stride] + ((t1 + t3) >> 7));
        dest[1 * stride] = av_clip_uint8(dest[1 * stride] + ((t2 - t4) >> 7));
        dest[2 * stride] = av_clip_uint8(dest[2 * stride] + ((t2 + t4) >> 7));
        dest[3 * stride] = av_clip_uint8(dest[3 * stride] + ((t1 - t3) >> 7));

        src++;
        dest++;
    }
}

/* motion compensation functions */

/* Filter in case of 2 filters */
#define VC1_MSPEL_FILTER_16B(DIR, TYPE)                                       \
static av_always_inline int vc1_mspel_ ## DIR ## _filter_16bits(const TYPE *src, \
                                                                ptrdiff_t stride, \
                                                                int mode)     \
{                                                                             \
    switch(mode) {                                                            \
    case 0: /* no shift - should not occur */                                 \
        return 0;                                                             \
    case 1: /* 1/4 shift */                                                   \
        return -4 * src[-stride] + 53 * src[0] +                              \
               18 * src[stride]  -  3 * src[stride * 2];                      \
    case 2: /* 1/2 shift */                                                   \
        return -1 * src[-stride] +  9 * src[0] +                              \
                9 * src[stride]  -  1 * src[stride * 2];                      \
    case 3: /* 3/4 shift */                                                   \
        return -3 * src[-stride] + 18 * src[0] +                              \
               53 * src[stride]  -  4 * src[stride * 2];                      \
    }                                                                         \
    return 0; /* should not occur */                                          \
}

VC1_MSPEL_FILTER_16B(ver, uint8_t)
VC1_MSPEL_FILTER_16B(hor, int16_t)

/* Filter used to interpolate fractional pel values */
static av_always_inline int vc1_mspel_filter(const uint8_t *src, ptrdiff_t stride,
                                             int mode, int r)
{
    switch (mode) {
    case 0: // no shift
        return src[0];
    case 1: // 1/4 shift
        return (-4 * src[-stride] + 53 * src[0] +
                18 * src[stride]  -  3 * src[stride * 2] + 32 - r) >> 6;
    case 2: // 1/2 shift
        return (-1 * src[-stride] +  9 * src[0] +
                 9 * src[stride]  -  1 * src[stride * 2] + 8 - r) >> 4;
    case 3: // 3/4 shift
        return (-3 * src[-stride] + 18 * src[0] +
                53 * src[stride]  -  4 * src[stride * 2] + 32 - r) >> 6;
    }
    return 0; // should not occur
}

/* Function used to do motion compensation with bicubic interpolation */
#define VC1_MSPEL_MC(OP, OP4, OPNAME)                                         \
static av_always_inline void OPNAME ## vc1_mspel_mc(uint8_t *dst,             \
                                                    const uint8_t *src,       \
                                                    ptrdiff_t stride,         \
                                                    int hmode,                \
                                                    int vmode,                \
                                                    int rnd)                  \
{                                                                             \
    int i, j;                                                                 \
                                                                              \
    if (vmode) { /* Horizontal filter to apply */                             \
        int r;                                                                \
                                                                              \
        if (hmode) { /* Vertical filter to apply, output to tmp */            \
            static const int shift_value[] = { 0, 5, 1, 5 };                  \
            int shift = (shift_value[hmode] + shift_value[vmode]) >> 1;       \
            int16_t tmp[11 * 8], *tptr = tmp;                                 \
                                                                              \
            r = (1 << (shift - 1)) + rnd - 1;                                 \
                                                                              \
            src -= 1;                                                         \
            for (j = 0; j < 8; j++) {                                         \
                for (i = 0; i < 11; i++)                                      \
                    tptr[i] = (vc1_mspel_ver_filter_16bits(src + i, stride, vmode) + r) >> shift; \
                src  += stride;                                               \
                tptr += 11;                                                   \
            }                                                                 \
                                                                              \
            r    = 64 - rnd;                                                  \
            tptr = tmp + 1;                                                   \
            for (j = 0; j < 8; j++) {                                         \
                for (i = 0; i < 8; i++)                                       \
                    OP(dst[i], (vc1_mspel_hor_filter_16bits(tptr + i, 1, hmode) + r) >> 7); \
                dst  += stride;                                               \
                tptr += 11;                                                   \
            }                                                                 \
                                                                              \
            return;                                                           \
        } else { /* No horizontal filter, output 8 lines to dst */            \
            r = 1 - rnd;                                                      \
                                                                              \
            for (j = 0; j < 8; j++) {                                         \
                for (i = 0; i < 8; i++)                                       \
                    OP(dst[i], vc1_mspel_filter(src + i, stride, vmode, r));  \
                src += stride;                                                \
                dst += stride;                                                \
            }                                                                 \
            return;                                                           \
        }                                                                     \
    }                                                                         \
                                                                              \
    /* Horizontal mode with no vertical mode */                               \
    for (j = 0; j < 8; j++) {                                                 \
        for (i = 0; i < 8; i++)                                               \
            OP(dst[i], vc1_mspel_filter(src + i, 1, hmode, rnd));             \
        dst += stride;                                                        \
        src += stride;                                                        \
    }                                                                         \
}\
static av_always_inline void OPNAME ## vc1_mspel_mc_16(uint8_t *dst,          \
                                                       const uint8_t *src,    \
                                                       ptrdiff_t stride,      \
                                                       int hmode,             \
                                                       int vmode,             \
                                                       int rnd)               \
{                                                                             \
    int i, j;                                                                 \
                                                                              \
    if (vmode) { /* Horizontal filter to apply */                             \
        int r;                                                                \
                                                                              \
        if (hmode) { /* Vertical filter to apply, output to tmp */            \
            static const int shift_value[] = { 0, 5, 1, 5 };                  \
            int shift = (shift_value[hmode] + shift_value[vmode]) >> 1;       \
            int16_t tmp[19 * 16], *tptr = tmp;                                \
                                                                              \
            r = (1 << (shift - 1)) + rnd - 1;                                 \
                                                                              \
            src -= 1;                                                         \
            for (j = 0; j < 16; j++) {                                        \
                for (i = 0; i < 19; i++)                                      \
                    tptr[i] = (vc1_mspel_ver_filter_16bits(src + i, stride, vmode) + r) >> shift; \
                src  += stride;                                               \
                tptr += 19;                                                   \
            }                                                                 \
                                                                              \
            r    = 64 - rnd;                                                  \
            tptr = tmp + 1;                                                   \
            for (j = 0; j < 16; j++) {                                        \
                for (i = 0; i < 16; i++)                                      \
                    OP(dst[i], (vc1_mspel_hor_filter_16bits(tptr + i, 1, hmode) + r) >> 7); \
                dst  += stride;                                               \
                tptr += 19;                                                   \
            }                                                                 \
                                                                              \
            return;                                                           \
        } else { /* No horizontal filter, output 8 lines to dst */            \
            r = 1 - rnd;                                                      \
                                                                              \
            for (j = 0; j < 16; j++) {                                        \
                for (i = 0; i < 16; i++)                                      \
                    OP(dst[i], vc1_mspel_filter(src + i, stride, vmode, r));  \
                src += stride;                                                \
                dst += stride;                                                \
            }                                                                 \
            return;                                                           \
        }                                                                     \
    }                                                                         \
                                                                              \
    /* Horizontal mode with no vertical mode */                               \
    for (j = 0; j < 16; j++) {                                                \
        for (i = 0; i < 16; i++)                                              \
            OP(dst[i], vc1_mspel_filter(src + i, 1, hmode, rnd));             \
        dst += stride;                                                        \
        src += stride;                                                        \
    }                                                                         \
}

#define op_put(a, b) (a) = av_clip_uint8(b)
#define op4_put(a, b) (a) = (b)
VC1_MSPEL_MC(op_put, op4_put, put_)

void wmv3_put_mspel16(uint8_t *dst, const uint8_t *src, ptrdiff_t stride, int hmode, int vmode, int rnd)
{
    put_vc1_mspel_mc_16(dst, src, stride, hmode, vmode, rnd);
}
void wmv3_put_mspel8(uint8_t *dst, const uint8_t *src, ptrdiff_t stride, int hmode, int vmode, int rnd)
{
    put_vc1_mspel_mc(dst, src, stride, hmode, vmode, rnd);
}
