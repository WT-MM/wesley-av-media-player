/* SPDX-License-Identifier: LGPL-2.1-or-later
 * WMV3 (SMPTE 421M VC-1 Simple/Main profile, progressive) video decoder.
 * The decoding process follows FFmpeg's libavcodec/vc1*.c so the output is
 * bit-identical to it; see ../NOTICE.
 */
#include "wmv3dec.h"
#include "wmv3_dsp.h"
#include "wmv3_tables.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- bits */

typedef struct {
    const uint8_t *buf; /* padded with >= 8 zero bytes */
    int idx, size;      /* in bits */
} Bits;

static inline uint64_t rb64(const uint8_t *p)
{
    uint64_t v;
    memcpy(&v, p, 8);
    return __builtin_bswap64(v);
}
static inline unsigned show(const Bits *b, int n)
{
    /* Reads past the end return zeros from the padding; callers check left(). */
    int i = b->idx < b->size ? b->idx : b->size;
    return (unsigned)((rb64(b->buf + (i >> 3)) << (i & 7)) >> (64 - n));
}
static inline void skip(Bits *b, int n) { b->idx += n; }
static inline unsigned get(Bits *b, int n)
{
    if (!n) return 0;
    unsigned v = show(b, n);
    b->idx += n;
    return v;
}
static inline int get1(Bits *b) { return (int)get(b, 1); }
static inline int left(const Bits *b) { return b->size - b->idx; }
static inline int decode012(Bits *b) { return get1(b) ? get1(b) + 1 : 0; }
static inline int decode210(Bits *b) { return get1(b) ? 0 : 2 - get1(b); }
static inline int unary(Bits *b, int stop, int len)
{
    int i = 0;
    while (i < len && get1(b) != stop) i++;
    return i;
}

/* ----------------------------------------------------------------- VLC */

typedef struct { int32_t sym; int8_t len; } VE; /* len < 0: subtable of -len bits at sym */
typedef struct { const VE *t; int bits; } Vlc;

#define POOL_SIZE 65536
static VE pool[POOL_SIZE];
static int pool_pos;

typedef struct { uint32_t code; int len, sym; } Code;

static int build_level(Code *c, int n, int nb)
{
    int base = pool_pos;
    pool_pos += 1 << nb;
    for (int i = 0; i < (1 << nb); i++) { pool[base + i].sym = -1; pool[base + i].len = 0; }
    for (int i = 0; i < n; i++) {
        if (c[i].len > nb) continue;
        int sh = nb - c[i].len, start = (int)(c[i].code << sh);
        for (int j = 0; j < (1 << sh); j++) { pool[base + start + j].sym = c[i].sym; pool[base + start + j].len = (int8_t)c[i].len; }
    }
    for (int i = 0; i < n; i++) {
        if (c[i].len <= nb) continue;
        int prefix = (int)(c[i].code >> (c[i].len - nb));
        if (pool[base + prefix].len < 0) continue; /* already built */
        Code *sub = malloc(sizeof(Code) * (size_t)n);
        int m = 0, maxl = 0;
        for (int j = i; j < n; j++) {
            if (c[j].len <= nb || (int)(c[j].code >> (c[j].len - nb)) != prefix) continue;
            sub[m].len = c[j].len - nb;
            sub[m].code = c[j].code & ((1u << sub[m].len) - 1);
            sub[m].sym = c[j].sym;
            if (sub[m].len > maxl) maxl = sub[m].len;
            m++;
        }
        int sb = maxl < nb ? maxl : nb;
        int at = build_level(sub, m, sb);
        free(sub);
        pool[base + prefix].sym = at;
        pool[base + prefix].len = (int8_t)-sb;
    }
    return base;
}

static Vlc mkvlc(int n, int nb, const void *codes, int csz, int cstride, const void *lens, int lsz, int lstride)
{
    Code *c = malloc(sizeof(Code) * (size_t)n);
    int m = 0;
    for (int i = 0; i < n; i++) {
        const uint8_t *cp = (const uint8_t *)codes + (size_t)i * (size_t)cstride;
        const uint8_t *lp = (const uint8_t *)lens + (size_t)i * (size_t)lstride;
        uint32_t code = csz == 1 ? *cp : csz == 2 ? *(const uint16_t *)cp : *(const uint32_t *)cp;
        int len = lsz == 1 ? *lp : lsz == 2 ? *(const uint16_t *)lp : (int)*(const uint32_t *)lp;
        if (!len) continue;
        c[m].code = code; c[m].len = len; c[m].sym = i; m++;
    }
    Vlc v = { pool + build_level(c, m, nb), nb };
    free(c);
    return v;
}

static inline int getvlc(Bits *b, Vlc v)
{
    const VE *e = &v.t[show(b, v.bits)];
    if (e->len >= 0) { skip(b, e->len); return e->sym; }
    skip(b, v.bits);
    for (;;) {
        int nb = -e->len;
        e = &pool[e->sym + (int)show(b, nb)];
        if (e->len >= 0) { skip(b, e->len); return e->sym; }
        skip(b, nb);
    }
}

static Vlc vlc_mb_i, vlc_dc[2][2], vlc_ac[AC_MODES];
static Vlc vlc_imode, vlc_norm2, vlc_norm6, vlc_cbpcy[4], vlc_mvdiff[4], vlc_ttmb[3], vlc_ttblk[3], vlc_subblk[3];

static void init_vlcs(void)
{
    vlc_mb_i = mkvlc(64, 9, &msmp4_mb_i_table[0][0], 2, 4, &msmp4_mb_i_table[0][1], 2, 4);
    for (int i = 0; i < 2; i++)
        for (int j = 0; j < 2; j++)
            vlc_dc[i][j] = mkvlc(120, 9, &msmp4_dc_tables[i][j][0][0], 4, 8, &msmp4_dc_tables[i][j][0][1], 4, 8);
    for (int i = 0; i < AC_MODES; i++)
        vlc_ac[i] = mkvlc(vc1_ac_sizes[i], 9, &vc1_ac_tables[i][0][0], 4, 8, &vc1_ac_tables[i][0][1], 4, 8);
    vlc_imode = mkvlc(7, 4, vc1_imode_codes, 1, 1, vc1_imode_bits, 1, 1);
    vlc_norm2 = mkvlc(4, 3, vc1_norm2_codes, 1, 1, vc1_norm2_bits, 1, 1);
    vlc_norm6 = mkvlc(64, 9, vc1_norm6_codes, 2, 2, vc1_norm6_bits, 1, 1);
    for (int i = 0; i < 3; i++) {
        vlc_ttmb[i] = mkvlc(16, 9, vc1_ttmb_codes[i], 2, 2, vc1_ttmb_bits[i], 1, 1);
        vlc_ttblk[i] = mkvlc(8, 5, vc1_ttblk_codes[i], 1, 1, vc1_ttblk_bits[i], 1, 1);
        vlc_subblk[i] = mkvlc(15, 6, vc1_subblkpat_codes[i], 1, 1, vc1_subblkpat_bits[i], 1, 1);
    }
    for (int i = 0; i < 4; i++) {
        vlc_cbpcy[i] = mkvlc(64, 9, vc1_cbpcy_p_codes[i], 2, 2, vc1_cbpcy_p_bits[i], 1, 1);
        vlc_mvdiff[i] = mkvlc(73, 9, vc1_mv_diff_codes[i], 2, 2, vc1_mv_diff_bits[i], 1, 1);
    }
}
static pthread_once_t vlc_once = PTHREAD_ONCE_INIT;

/* ------------------------------------------------------------- context */

enum { PT_I, PT_P };
enum { DQPROFILE_FOUR_EDGES, DQPROFILE_DOUBLE_EDGES, DQPROFILE_SINGLE_EDGE, DQPROFILE_ALL_MBS };
enum { CS_HIGH_MOT_INTRA, CS_HIGH_MOT_INTER, CS_LOW_MOT_INTRA, CS_LOW_MOT_INTER,
       CS_MID_RATE_INTRA, CS_MID_RATE_INTER, CS_HIGH_RATE_INTRA, CS_HIGH_RATE_INTER };

#define LPAD 48 /* >= MV clip (16) + bicubic taps + MB rounding */
#define CPAD 32

typedef struct { uint8_t *buf[3], *p[3]; } Pic;

struct Wmv3Decoder {
    /* sequence */
    int profile, loop_filter, multires, fastuvmc, extended_mv, dquant, vstransform;
    int overlap, resync_marker, rangered, max_b_frames, quantizer_mode, finterpflag;
    int width, height, mb_w, mb_h, ls, cs; /* luma/chroma linesize */
    uint8_t zz_8x8[4][64], zz_8x4[64], zz_4x8[64];
    /* picture */
    int pict_type, pq, pqindex, halfpq, pquantizer, rnd, mvrange, k_x, k_y, range_x, range_y;
    int rangeredfrm, respic, c_ac_table_index, y_ac_table_index, dc_table_index;
    int codingset, codingset2, esc3_level_length, esc3_run_length;
    int dc_scale, ac_pred;
    int res_rtm_flag, tt_index, mv_mode, mv_mode2, use_ic, quarter_sample, mspel, mixed_mv;
    int mv_type_is_raw, skip_is_raw, mv_table_index, cbptab, ttmbf, ttfrm;
    int dquantfrm, dqprofile, dqsbedge, dqbilevel, altpq;
    uint8_t luty[256], lutuv[256];
    uint8_t *mv_type_plane, *skip_plane;  /* mb_w x mb_h */
    int16_t (*mv)[2];                     /* luma b8 grid (padded like dc_y) */
    uint8_t *intra_y, *intra_c;           /* is-intra per block grid */
    int8_t *qscale;                       /* per MB, padded (cbs stride) */
    int16_t bmv[4][2];                    /* current MB block MVs */
    Pic icpic;                            /* intensity-compensated reference */
    /* per-frame state */
    int16_t *dc_y, *dc_c[2];     /* padded predictor grids */
    int16_t *ac_y, *ac_c[2];     /* 16 per block */
    uint8_t *coded;              /* luma coded-block grid */
    int16_t (*rows)[6][64];      /* two MB rows of reconstructed blocks for overlap */
    int b8s, cbs;                /* grid strides: 2*mb_w+1, mb_w+1 */
    Pic pics[2];
    int cur, have_ref;
    uint8_t *pkt;
    size_t pkt_cap;
    Bits gb;
};

static void pic_free(Pic *p)
{
    for (int i = 0; i < 3; i++) free(p->buf[i]);
}

static int pic_alloc(Wmv3Decoder *d, Pic *p)
{
    int lh = d->mb_h * 16 + 2 * LPAD, ch = d->mb_h * 8 + 2 * CPAD;
    p->buf[0] = calloc((size_t)d->ls * lh, 1);
    p->buf[1] = calloc((size_t)d->cs * ch, 1);
    p->buf[2] = calloc((size_t)d->cs * ch, 1);
    if (!p->buf[0] || !p->buf[1] || !p->buf[2]) return -1;
    p->p[0] = p->buf[0] + LPAD * d->ls + LPAD;
    p->p[1] = p->buf[1] + CPAD * d->cs + CPAD;
    p->p[2] = p->buf[2] + CPAD * d->cs + CPAD;
    return 0;
}

void wmv3_decoder_close(Wmv3Decoder *d)
{
    if (!d) return;
    pic_free(&d->pics[0]);
    pic_free(&d->pics[1]);
    pic_free(&d->icpic);
    free(d->mv_type_plane); free(d->skip_plane); free(d->mv); free(d->intra_y); free(d->intra_c); free(d->qscale);
    free(d->dc_y); free(d->dc_c[0]); free(d->dc_c[1]);
    free(d->ac_y); free(d->ac_c[0]); free(d->ac_c[1]);
    free(d->coded); free(d->rows); free(d->pkt);
    free(d);
}

/* Parses STRUCT_C (SMPTE 421M Annex J) into d. Returns 0 when this decoder
 * implements every tool the sequence header enables. */
static int parse_sequence(Wmv3Decoder *d, const uint8_t *ex, size_t exsize)
{
    if (!ex || exsize < 4) return -1;
    uint8_t hdr[16] = {0};
    memcpy(hdr, ex, exsize < 8 ? exsize : 8);
    Bits b = { hdr, 0, 64 };
    d->profile = (int)get(&b, 2);
    int res_y411 = get1(&b), res_sprite = get1(&b);
    skip(&b, 3 + 5);        /* frmrtq_postproc, bitrtq_postproc */
    d->loop_filter = get1(&b);
    int res_x8 = get1(&b);
    d->multires = get1(&b);
    int res_fasttx = get1(&b);
    d->fastuvmc = get1(&b);
    d->extended_mv = get1(&b);
    d->dquant = (int)get(&b, 2);
    d->vstransform = get1(&b);
    int res_transtab = get1(&b);
    d->overlap = get1(&b);
    d->resync_marker = get1(&b);
    d->rangered = get1(&b);
    d->max_b_frames = (int)get(&b, 3);
    d->quantizer_mode = (int)get(&b, 2);
    d->finterpflag = get1(&b);
    d->res_rtm_flag = get1(&b);
    /* Advanced profile (the only one with interlace), sprites, X8 intra and
     * the pre-release (non-FASTTX) transform are out of scope. Not implemented
     * yet: in-loop deblocking, range reduction, multires and B/BI pictures. */
    if (d->profile > 1 || res_y411 || res_sprite || res_x8 || !res_fasttx || res_transtab ||
        (!d->profile && (!d->fastuvmc || d->extended_mv)) ||
        d->loop_filter || d->rangered || d->multires || d->max_b_frames)
        return -1;
    return 0;
}

int wmv3_sequence_supported(const uint8_t *ex, size_t exsize)
{
    Wmv3Decoder d;
    memset(&d, 0, sizeof(d));
    return parse_sequence(&d, ex, exsize) == 0;
}

Wmv3Decoder *wmv3_decoder_open(const uint8_t *ex, size_t exsize, int width, int height)
{
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return NULL;
    pthread_once(&vlc_once, init_vlcs);
    Wmv3Decoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    if (parse_sequence(d, ex, exsize) < 0) {
        free(d);
        return NULL;
    }
    d->width = width; d->height = height;
    d->mb_w = (width + 15) >> 4; d->mb_h = (height + 15) >> 4;
    d->ls = (d->mb_w * 16 + 2 * LPAD + 63) & ~63;
    d->cs = (d->mb_w * 8 + 2 * CPAD + 63) & ~63;
    /* FASTTX streams use the transposed WMV1 scans (see vc1dec.c). */
#define TRANSPOSE(x) (((x) >> 3) | (((x) & 7) << 3))
    for (int t = 0; t < 4; t++)
        for (int i = 0; i < 64; i++) d->zz_8x8[t][i] = (uint8_t)TRANSPOSE(wmv1_scantable[t][i]);
    memcpy(d->zz_8x4, wmv2_scantableA, 64);
    memcpy(d->zz_4x8, wmv2_scantableB, 64);
    d->b8s = 2 * d->mb_w + 1;
    d->cbs = d->mb_w + 1;
    size_t n8 = (size_t)d->b8s * (2 * d->mb_h + 1), nc = (size_t)d->cbs * (d->mb_h + 1);
    d->dc_y = calloc(n8, 2); d->dc_c[0] = calloc(nc, 2); d->dc_c[1] = calloc(nc, 2);
    d->ac_y = calloc(n8 * 16, 2); d->ac_c[0] = calloc(nc * 16, 2); d->ac_c[1] = calloc(nc * 16, 2);
    d->coded = calloc(n8, 1);
    d->rows = calloc((size_t)d->mb_w * 2, sizeof(*d->rows));
    d->mv_type_plane = calloc((size_t)d->mb_w * d->mb_h, 1);
    d->skip_plane = calloc((size_t)d->mb_w * d->mb_h, 1);
    d->mv = calloc(n8, sizeof(*d->mv));
    d->intra_y = calloc(n8, 1);
    d->intra_c = calloc(nc, 1);
    d->qscale = calloc(nc, 1);
    if (!d->dc_y || !d->dc_c[0] || !d->dc_c[1] || !d->ac_y || !d->ac_c[0] || !d->ac_c[1] || !d->coded ||
        !d->rows || !d->mv_type_plane || !d->skip_plane || !d->mv || !d->intra_y || !d->intra_c ||
        !d->qscale || pic_alloc(d, &d->pics[0]) || pic_alloc(d, &d->pics[1]) || pic_alloc(d, &d->icpic)) {
        wmv3_decoder_close(d);
        return NULL;
    }
    return d;
}

/* ------------------------------------------------------- picture header */

static void decode_rowskip(uint8_t *plane, int width, int height, int stride, Bits *gb)
{
    for (int y = 0; y < height; y++, plane += stride) {
        if (!get1(gb)) memset(plane, 0, (size_t)width);
        else for (int x = 0; x < width; x++) plane[x] = (uint8_t)get1(gb);
    }
}

static void decode_colskip(uint8_t *plane, int width, int height, int stride, Bits *gb)
{
    for (int x = 0; x < width; x++, plane++) {
        if (!get1(gb)) for (int y = 0; y < height; y++) plane[y * stride] = 0;
        else for (int y = 0; y < height; y++) plane[y * stride] = (uint8_t)get1(gb);
    }
}

/* Bitplane (8.7). Returns <0 on error; *raw set when bits come per MB. */
static int bitplane(Wmv3Decoder *d, uint8_t *data, int *raw)
{
    Bits *gb = &d->gb;
    int width = d->mb_w, height = d->mb_h, stride = d->mb_w;
    uint8_t *planep = data;
    int invert = get1(gb);
    int imode = getvlc(gb, vlc_imode);
    *raw = 0;
    switch (imode) {
    case 0: /* raw */
        *raw = 1;
        return 0;
    case 1: case 2: { /* norm2, diff2 */
        int y = 0, offset = 0;
        if ((height * width) & 1) {
            *planep++ = (uint8_t)get1(gb);
            y = offset = 1;
            if (offset == width) { offset = 0; planep += stride - width; }
        }
        for (; y < height * width; y += 2) {
            int code = getvlc(gb, vlc_norm2);
            *planep++ = code & 1;
            if (++offset == width) { offset = 0; planep += stride - width; }
            *planep++ = (uint8_t)(code >> 1);
            if (++offset == width) { offset = 0; planep += stride - width; }
        }
        break;
    }
    case 3: case 4: /* norm6, diff6 */
        if (!(height % 3) && (width % 3)) {
            for (int y = 0; y < height; y += 3) {
                for (int x = width & 1; x < width; x += 2) {
                    int code = getvlc(gb, vlc_norm6);
                    if (code < 0) return -1;
                    planep[x + 0] = code & 1;
                    planep[x + 1] = (code >> 1) & 1;
                    planep[x + 0 + stride] = (code >> 2) & 1;
                    planep[x + 1 + stride] = (code >> 3) & 1;
                    planep[x + 0 + stride * 2] = (code >> 4) & 1;
                    planep[x + 1 + stride * 2] = (code >> 5) & 1;
                }
                planep += stride * 3;
            }
            if (width & 1) decode_colskip(data, 1, height, stride, gb);
        } else {
            planep += (height & 1) * stride;
            for (int y = height & 1; y < height; y += 2) {
                for (int x = width % 3; x < width; x += 3) {
                    int code = getvlc(gb, vlc_norm6);
                    if (code < 0) return -1;
                    planep[x + 0] = code & 1;
                    planep[x + 1] = (code >> 1) & 1;
                    planep[x + 2] = (code >> 2) & 1;
                    planep[x + 0 + stride] = (code >> 3) & 1;
                    planep[x + 1 + stride] = (code >> 4) & 1;
                    planep[x + 2 + stride] = (code >> 5) & 1;
                }
                planep += stride * 2;
            }
            int x = width % 3;
            if (x) decode_colskip(data, x, height, stride, gb);
            if (height & 1) decode_rowskip(data + x, width - x, 1, stride, gb);
        }
        break;
    case 5: decode_rowskip(data, width, height, stride, gb); break;
    case 6: decode_colskip(data, width, height, stride, gb); break;
    default: return -1;
    }
    if (imode == 2 || imode == 4) { /* DIFF2, DIFF6 */
        planep = data;
        planep[0] ^= invert;
        for (int x = 1; x < width; x++) planep[x] ^= planep[x - 1];
        for (int y = 1; y < height; y++) {
            planep += stride;
            planep[0] ^= planep[-stride];
            for (int x = 1; x < width; x++) {
                if (planep[x - 1] != planep[x - stride]) planep[x] ^= invert;
                else planep[x] ^= planep[x - 1];
            }
        }
    } else if (invert) {
        for (int x = 0; x < stride * height; x++) data[x] = !data[x];
    }
    return 0;
}

static void init_lut(uint8_t *luty, uint8_t *lutuv, int lumscale, int lumshift)
{
    int scale, shift;
    if (!lumscale) {
        scale = -64;
        shift = (255 - lumshift * 2) * 64;
        if (lumshift > 31) shift += 128 << 6;
    } else {
        scale = lumscale + 32;
        shift = lumshift > 31 ? (lumshift - 64) * 64 : lumshift << 6;
    }
    for (int i = 0; i < 256; i++) {
        int y = (scale * i + shift + 32) >> 6, u = (scale * (i - 128) + 128 * 64 + 32) >> 6;
        luty[i] = (uint8_t)(y < 0 ? 0 : y > 255 ? 255 : y);
        lutuv[i] = (uint8_t)(u < 0 ? 0 : u > 255 ? 255 : u);
    }
}

static int parse_p_header(Wmv3Decoder *d)
{
    Bits *gb = &d->gb;
    d->tt_index = (d->pq > 4) + (d->pq > 12);
    int lowquant = d->pq > 12 ? 0 : 1;
    d->mv_mode = vc1_mv_pmode_table[lowquant][unary(gb, 1, 4)];
    d->use_ic = 0;
    int mode = d->mv_mode;
    if (d->mv_mode == MV_PMODE_INTENSITY_COMP) {
        mode = d->mv_mode2 = vc1_mv_pmode_table2[lowquant][unary(gb, 1, 3)];
        int lumscale = (int)get(gb, 6), lumshift = (int)get(gb, 6);
        d->use_ic = 1;
        init_lut(d->luty, d->lutuv, lumscale, lumshift);
    }
    d->quarter_sample = mode != MV_PMODE_1MV_HPEL && mode != MV_PMODE_1MV_HPEL_BILIN;
    d->mspel = mode != MV_PMODE_1MV_HPEL_BILIN;
    d->mixed_mv = mode == MV_PMODE_MIXED_MV;
    if (d->mixed_mv) {
        if (bitplane(d, d->mv_type_plane, &d->mv_type_is_raw) < 0) return -1;
    } else {
        d->mv_type_is_raw = 0;
        memset(d->mv_type_plane, 0, (size_t)d->mb_w * d->mb_h);
    }
    if (bitplane(d, d->skip_plane, &d->skip_is_raw) < 0) return -1;
    if (left(gb) < 4) return -1;
    d->mv_table_index = (int)get(gb, 2);
    d->cbptab = (int)get(gb, 2);
    if (d->dquant) {
        if (d->dquant != 2) {
            d->dquantfrm = get1(gb);
            if (!d->dquantfrm) goto dq_done;
            d->dqprofile = (int)get(gb, 2);
            if (d->dqprofile == DQPROFILE_SINGLE_EDGE || d->dqprofile == DQPROFILE_DOUBLE_EDGES)
                d->dqsbedge = (int)get(gb, 2);
            else if (d->dqprofile == DQPROFILE_ALL_MBS) {
                d->dqbilevel = get1(gb);
                if (!d->dqbilevel) { d->halfpq = 0; goto dq_done; }
            }
        }
        int pqdiff = (int)get(gb, 3);
        d->altpq = pqdiff == 7 ? (int)get(gb, 5) : d->pq + pqdiff + 1;
    }
dq_done:
    if (d->vstransform) {
        d->ttmbf = get1(gb);
        d->ttfrm = d->ttmbf ? vc1_ttfrm_to_tt[get(gb, 2)] : 0;
    } else {
        d->ttmbf = 1;
        d->ttfrm = TT_8X8;
    }
    return 0;
}

static int parse_header(Wmv3Decoder *d)
{
    Bits *gb = &d->gb;
    if (d->finterpflag) skip(gb, 1);
    skip(gb, 2); /* frame count */
    d->rangeredfrm = d->rangered ? get1(gb) : 0;
    /* MAXBFRAMES is 0 (see parse_sequence), so PTYPE is one bit: P or I. */
    d->pict_type = get1(gb) ? PT_P : PT_I;
    if (d->pict_type == PT_I) { skip(gb, 7); d->rnd = 1; } /* buffer fullness */
    else d->rnd ^= 1;
    if (left(gb) < 5) return -1;
    d->pqindex = (int)get(gb, 5);
    if (!d->pqindex) return -1;
    d->pq = vc1_pquant_table[d->quantizer_mode == 0 ? 0 : 1][d->pqindex];
    d->halfpq = d->pqindex < 9 ? get1(gb) : 0;
    switch (d->quantizer_mode) {
    case 0: d->pquantizer = d->pqindex < 9; break;
    case 2: d->pquantizer = 0; break;
    case 1: d->pquantizer = get1(gb); break;
    default: d->pquantizer = 1; break;
    }
    if (d->extended_mv) d->mvrange = unary(gb, 0, 3);
    d->k_x = d->mvrange + 9 + (d->mvrange >> 1);
    d->k_y = d->mvrange + 8;
    d->range_x = 1 << (d->k_x - 1);
    d->range_y = 1 << (d->k_y - 1);
    if (d->multires) d->respic = (int)get(gb, 2);
    d->dquantfrm = 0;
    if (d->pict_type == PT_P && parse_p_header(d) < 0) return -1;
    d->c_ac_table_index = decode012(gb);
    if (d->pict_type == PT_I) d->y_ac_table_index = decode012(gb);
    d->dc_table_index = get1(gb);
    return 0;
}

/* ------------------------------------------------------- intra blocks */

static int decode_ac_coeff(Wmv3Decoder *d, int *last, int *skp, int *value, int cs)
{
    Bits *gb = &d->gb;
    int run, level, lst, sign;
    int index = getvlc(gb, vlc_ac[cs]);
    if (index < 0) return -1;
    if (index != vc1_ac_sizes[cs] - 1) {
        run = vc1_index_decode_table[cs][index][0];
        level = vc1_index_decode_table[cs][index][1];
        lst = index >= vc1_last_decode_table[cs] || left(gb) < 0;
        sign = get1(gb);
    } else {
        int escape = decode210(gb);
        if (escape != 2) {
            index = getvlc(gb, vlc_ac[cs]);
            if (index < 0 || index >= vc1_ac_sizes[cs] - 1) return -1;
            run = vc1_index_decode_table[cs][index][0];
            level = vc1_index_decode_table[cs][index][1];
            lst = index >= vc1_last_decode_table[cs];
            if (escape == 0)
                level += lst ? vc1_last_delta_level_table[cs][run] : vc1_delta_level_table[cs][run];
            else
                run += (lst ? vc1_last_delta_run_table[cs][level] : vc1_delta_run_table[cs][level]) + 1;
            sign = get1(gb);
        } else {
            lst = get1(gb);
            if (!d->esc3_level_length) {
                if (d->pq < 8 || d->dquantfrm) {
                    d->esc3_level_length = (int)get(gb, 3);
                    if (!d->esc3_level_length) d->esc3_level_length = (int)get(gb, 2) + 8;
                } else {
                    d->esc3_level_length = unary(gb, 1, 6) + 2;
                }
                d->esc3_run_length = 3 + (int)get(gb, 2);
            }
            run = (int)get(gb, d->esc3_run_length);
            sign = get1(gb);
            level = (int)get(gb, d->esc3_level_length);
        }
    }
    *last = lst;
    *skp = run;
    *value = (level ^ -sign) + sign;
    return 0;
}

static const uint16_t dcpred[32] = {
    0, 1024, 512, 341, 256, 205, 171, 146, 128, 114, 102, 93, 85, 79, 73, 68, 64,
    60, 57, 54, 51, 49, 47, 45, 43, 41, 39, 38, 37, 35, 34, 33
};

/* Grid addressing for block n of MB (x, y): returns predictor slot and the
 * slot stride (left neighbour = -1, top = -stride). */
static inline int blk_slot(const Wmv3Decoder *d, int x, int y, int n, int *stride)
{
    if (n < 4) { *stride = d->b8s; return (2 * y + (n >> 1) + 1) * d->b8s + 2 * x + (n & 1) + 1; }
    *stride = d->cbs;
    return (y + 1) * d->cbs + x + 1;
}

static int decode_i_block(Wmv3Decoder *d, int16_t block[64], int x, int y, int n, int coded, int cs)
{
    Bits *gb = &d->gb;
    int wrap, slot = blk_slot(d, x, y, n, &wrap);
    int16_t *dcv = n < 4 ? d->dc_y : d->dc_c[n - 4];
    int16_t *acv = n < 4 ? d->ac_y : d->ac_c[n - 4];

    int dcdiff = getvlc(gb, vlc_dc[d->dc_table_index][n >= 4]);
    if (dcdiff < 0) return -1;
    if (dcdiff) {
        const int m = (d->pq == 1 || d->pq == 2) ? 3 - d->pq : 0;
        if (dcdiff == 119) dcdiff = (int)get(gb, 8 + m);
        else if (m) dcdiff = (dcdiff << m) + (int)get(gb, m) - ((1 << m) - 1);
        if (get1(gb)) dcdiff = -dcdiff;
    }
    /* DC prediction: B A / C X */
    int c = dcv[slot - 1], b = dcv[slot - 1 - wrap], a = dcv[slot - wrap];
    int outer = (d->pq < 9 || !d->overlap) ? dcpred[d->dc_scale] : 0;
    if (y == 0 && n != 2 && n != 3) b = a = outer;
    if (x == 0 && n != 1 && n != 3) b = c = outer;
    int dir_left = abs(a - b) <= abs(b - c);
    dcdiff += dir_left ? c : a;
    dcv[slot] = (int16_t)dcdiff;
    block[0] = (int16_t)(dcdiff * d->dc_scale);

    int16_t *ac2 = acv + (size_t)slot * 16;
    int16_t *ac = ac2 - (dir_left ? 16 : 16 * wrap);
    int scale = d->pq * 2 + d->halfpq;
    /* FASTTX: left_blk_sh = 0, top_blk_sh = 3 */
    if (coded) {
        int last = 0, skp, value;
        const uint8_t *zz = d->ac_pred ? (dir_left ? d->zz_8x8[3] : d->zz_8x8[2]) : d->zz_8x8[1];
        for (int i = 1; !last; ++i) {
            if (decode_ac_coeff(d, &last, &skp, &value, cs) < 0) return -1;
            i += skp;
            if (i > 63) break;
            block[zz[i]] = (int16_t)value;
        }
        if (d->ac_pred) {
            if (dir_left) for (int k = 1; k < 8; k++) block[k] += ac[k];
            else for (int k = 1; k < 8; k++) block[k << 3] += ac[k + 8];
        }
        for (int k = 1; k < 8; k++) { ac2[k] = block[k]; ac2[k + 8] = block[k << 3]; }
        for (int k = 1; k < 64; k++)
            if (block[k]) {
                block[k] = (int16_t)(block[k] * scale);
                if (!d->pquantizer) block[k] += block[k] < 0 ? -d->pq : d->pq;
            }
    } else {
        memset(ac2, 0, 16 * 2);
        if (d->ac_pred) {
            int sh = dir_left ? 0 : 3;
            if (!dir_left) { ac += 8; ac2 += 8; }
            memcpy(ac2, ac, 8 * 2);
            for (int k = 1; k < 8; k++) {
                int v = ac[k] * scale;
                if (!d->pquantizer && v) v += v < 0 ? -d->pq : d->pq;
                block[k << sh] = (int16_t)v;
            }
        }
    }
    return 0;
}

static inline int coded_block_pred(Wmv3Decoder *d, int x, int y, int n, int diff)
{
    int w, xy = blk_slot(d, x, y, n, &w);
    int a = d->coded[xy - 1], b = d->coded[xy - 1 - w], c = d->coded[xy - w];
    int pred = (b == c ? a : c) ^ diff;
    d->coded[xy] = (uint8_t)pred;
    return pred;
}

static void put_block(const int16_t *blk, uint8_t *dst, int stride, int bias)
{
    for (int i = 0; i < 8; i++, dst += stride, blk += 8)
        for (int j = 0; j < 8; j++) {
            int v = blk[j] + bias;
            dst[j] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        }
}

static void put_mb_row(Wmv3Decoder *d, int16_t (*row)[6][64], int y, int bias)
{
    Pic *p = &d->pics[d->cur];
    for (int x = 0; x < d->mb_w; x++) {
        uint8_t *dy = p->p[0] + (size_t)(y * 16) * d->ls + x * 16;
        put_block(row[x][0], dy, d->ls, bias);
        put_block(row[x][1], dy + 8, d->ls, bias);
        put_block(row[x][2], dy + 8 * d->ls, d->ls, bias);
        put_block(row[x][3], dy + 8 * d->ls + 8, d->ls, bias);
        put_block(row[x][4], p->p[1] + (size_t)(y * 8) * d->cs + x * 8, d->cs, bias);
        put_block(row[x][5], p->p[2] + (size_t)(y * 8) * d->cs + x * 8, d->cs, bias);
    }
}

/* Overlap smoothing (8.5): all vertical block edges of a row first, then
 * horizontal edges. Edges never share pixels within one direction, so this
 * order reproduces the reference result. */
static void overlap_h_row(Wmv3Decoder *d, int16_t (*row)[6][64])
{
    for (int x = 0; x < d->mb_w; x++) {
        if (x) {
            wmv3_h_s_overlap(row[x - 1][1], row[x][0], 8, 8, 1);
            wmv3_h_s_overlap(row[x - 1][3], row[x][2], 8, 8, 1);
            wmv3_h_s_overlap(row[x - 1][4], row[x][4], 8, 8, 1);
            wmv3_h_s_overlap(row[x - 1][5], row[x][5], 8, 8, 1);
        }
        wmv3_h_s_overlap(row[x][0], row[x][1], 8, 8, 1);
        wmv3_h_s_overlap(row[x][2], row[x][3], 8, 8, 1);
    }
}

static void overlap_v_rows(Wmv3Decoder *d, int16_t (*top)[6][64], int16_t (*cur)[6][64])
{
    for (int x = 0; x < d->mb_w; x++) {
        if (top) {
            wmv3_v_s_overlap(top[x][2], cur[x][0]);
            wmv3_v_s_overlap(top[x][3], cur[x][1]);
            wmv3_v_s_overlap(top[x][4], cur[x][4]);
            wmv3_v_s_overlap(top[x][5], cur[x][5]);
        }
        wmv3_v_s_overlap(cur[x][0], cur[x][2]);
        wmv3_v_s_overlap(cur[x][1], cur[x][3]);
    }
}

static int decode_i_frame(Wmv3Decoder *d)
{
    switch (d->y_ac_table_index) {
    case 0: d->codingset = d->pqindex <= 8 ? CS_HIGH_RATE_INTRA : CS_LOW_MOT_INTRA; break;
    case 1: d->codingset = CS_HIGH_MOT_INTRA; break;
    default: d->codingset = CS_MID_RATE_INTRA; break;
    }
    switch (d->c_ac_table_index) {
    case 0: d->codingset2 = d->pqindex <= 8 ? CS_HIGH_RATE_INTER : CS_LOW_MOT_INTER; break;
    case 1: d->codingset2 = CS_HIGH_MOT_INTER; break;
    default: d->codingset2 = CS_MID_RATE_INTER; break;
    }
    d->dc_scale = wmv3_dc_scale_table[d->pq];
    int ovl = d->overlap && d->pq >= 9;
    int bias = ovl ? 128 : 0;
    for (int y = 0; y < d->mb_h; y++) {
        int16_t (*row)[6][64] = d->rows + (y & 1) * d->mb_w;
        int16_t (*prev)[6][64] = y ? d->rows + ((y - 1) & 1) * d->mb_w : NULL;
        memset(row, 0, sizeof(*row) * (size_t)d->mb_w);
        for (int x = 0; x < d->mb_w; x++) {
            int cbp = getvlc(&d->gb, vlc_mb_i);
            if (cbp < 0) return -1;
            d->ac_pred = get1(&d->gb);
            for (int k = 0; k < 6; k++) {
                int val = (cbp >> (5 - k)) & 1;
                if (k < 4) val = coded_block_pred(d, x, y, k, val);
                if (decode_i_block(d, row[x][k], x, y, k, val, k < 4 ? d->codingset : d->codingset2) < 0)
                    return -1;
                wmv3_inv_trans_8x8(row[x][k]);
            }
            if (left(&d->gb) < 0) return -1;
        }
        if (ovl) {
            overlap_h_row(d, row);
            overlap_v_rows(d, prev, row);
        }
        if (prev) put_mb_row(d, prev, y - 1, bias);
    }
    put_mb_row(d, d->rows + ((d->mb_h - 1) & 1) * d->mb_w, d->mb_h - 1, bias);
    return 0;
}

/* ------------------------------------------------------------ P frames */

static inline int mid3(int a, int b, int c)
{
    int mn = a < b ? a : b, mx = a < b ? b : a;
    return c < mn ? mn : c > mx ? mx : c;
}
static inline int median4(int a, int b, int c, int e)
{
#define MIN(x, y) ((x) < (y) ? (x) : (y))
#define MAX(x, y) ((x) > (y) ? (x) : (y))
    if (a < b) return c < e ? (MIN(b, e) + MAX(a, c)) / 2 : (MIN(b, c) + MAX(a, e)) / 2;
    return c < e ? (MIN(a, e) + MAX(b, c)) / 2 : (MIN(a, c) + MAX(b, e)) / 2;
}
static inline int clip(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

static const uint8_t size_table[6] = { 0, 2, 3, 4, 5, 8 };
static const uint8_t offset_table1[9] = { 0, 1, 3, 7, 15, 31, 63, 127, 255 };

/* MVDATA (8.3.5.2). Returns has_coeffs; *intra set for the intra escape. */
static int get_mvdata(Wmv3Decoder *d, int *dx, int *dy, int *intra)
{
    Bits *gb = &d->gb;
    int has_coeffs = 0, index = 1 + getvlc(gb, vlc_mvdiff[d->mv_table_index]);
    if (index > 36) { has_coeffs = 1; index -= 37; }
    *intra = 0;
    if (!index) {
        *dx = *dy = 0;
    } else if (index == 35) {
        *dx = (int)get(gb, d->k_x - 1 + d->quarter_sample);
        *dy = (int)get(gb, d->k_y - 1 + d->quarter_sample);
    } else if (index == 36) {
        *dx = *dy = 0;
        *intra = 1;
    } else {
        int i1 = index % 6, val;
        *dx = offset_table1[i1];
        val = size_table[i1] - (!d->quarter_sample && i1 == 5);
        if (val > 0) { val = (int)get(gb, val); int sign = -(val & 1); *dx = (sign ^ ((val >> 1) + *dx)) - sign; }
        i1 = index / 6;
        *dy = offset_table1[i1];
        val = size_table[i1] - (!d->quarter_sample && i1 == 5);
        if (val > 0) { val = (int)get(gb, val); int sign = -(val & 1); *dy = (sign ^ ((val >> 1) + *dy)) - sign; }
    }
    return has_coeffs;
}

/* MV prediction (8.3.5.3), progressive pictures only. */
static void pred_mv(Wmv3Decoder *d, int x, int y, int n, int dmv_x, int dmv_y, int mv1, int intra)
{
    int wrap, xy = blk_slot(d, x, y, n, &wrap);
    if (!d->quarter_sample) { dmv_x *= 2; dmv_y *= 2; }
    if (intra) {
        d->bmv[n][0] = d->bmv[n][1] = 0;
        d->mv[xy][0] = d->mv[xy][1] = 0;
        if (mv1) {
            memset(d->mv[xy + 1], 0, 4); memset(d->mv[xy + wrap], 0, 4); memset(d->mv[xy + wrap + 1], 0, 4);
        }
        return;
    }
    int a_valid = y || n == 2 || n == 3, b_valid = a_valid, c_valid = x || n == 1 || n == 3, off;
    if (mv1) {
        off = x == d->mb_w - 1 ? -1 : 2;
        b_valid = b_valid && d->mb_w > 1;
    } else {
        switch (n) {
        case 0: off = d->res_rtm_flag ? (x ? -1 : 1) : (x ? -1 : 2 * d->mb_w - wrap - 1); break;
        case 1: off = x == d->mb_w - 1 ? -1 : 1; break;
        case 2: off = 1; break;
        default: off = -1; break;
        }
    }
    int A[2] = {0, 0}, B[2] = {0, 0}, C[2] = {0, 0}, cnt = 0;
    if (a_valid) { A[0] = d->mv[xy - wrap][0]; A[1] = d->mv[xy - wrap][1]; cnt++; }
    if (b_valid) { B[0] = d->mv[xy - wrap + off][0]; B[1] = d->mv[xy - wrap + off][1]; cnt++; }
    if (c_valid) { C[0] = d->mv[xy - 1][0]; C[1] = d->mv[xy - 1][1]; cnt++; }
    int px, py;
    if (a_valid) { px = A[0]; py = A[1]; }
    else if (c_valid) { px = C[0]; py = C[1]; }
    else if (b_valid) { px = B[0]; py = B[1]; }
    else px = py = 0;
    if (cnt > 1) { px = mid3(A[0], B[0], C[0]); py = mid3(A[1], B[1], C[1]); }
    /* pullback (8.3.5.3.4) */
    {
        int MV = mv1 ? -60 : -28;
        int qx = (x << 6) + ((n == 1 || n == 3) ? 32 : 0), qy = (y << 6) + ((n == 2 || n == 3) ? 32 : 0);
        int X = (d->mb_w << 6) - 4, Y = (d->mb_h << 6) - 4;
        if (qx + px < MV) px = MV - qx;
        if (qy + py < MV) py = MV - qy;
        if (qx + px > X) px = X - qx;
        if (qy + py > Y) py = Y - qy;
    }
    /* hybrid prediction (8.3.5.3.5) */
    if (a_valid && c_valid) {
        int sum = d->intra_y[xy - wrap] ? abs(px) + abs(py) : abs(px - A[0]) + abs(py - A[1]);
        if (sum > 32) {
            if (get1(&d->gb)) { px = A[0]; py = A[1]; } else { px = C[0]; py = C[1]; }
        } else {
            sum = d->intra_y[xy - 1] ? abs(px) + abs(py) : abs(px - C[0]) + abs(py - C[1]);
            if (sum > 32) {
                if (get1(&d->gb)) { px = A[0]; py = A[1]; } else { px = C[0]; py = C[1]; }
            }
        }
    }
    int r_x = d->range_x, r_y = d->range_y;
    int mx = ((px + dmv_x + r_x) & ((r_x << 1) - 1)) - r_x;
    int my = ((py + dmv_y + r_y) & ((r_y << 1) - 1)) - r_y;
    d->bmv[n][0] = (int16_t)mx; d->bmv[n][1] = (int16_t)my;
    d->mv[xy][0] = (int16_t)mx; d->mv[xy][1] = (int16_t)my;
    if (mv1) {
        memcpy(d->mv[xy + 1], d->mv[xy], 4); memcpy(d->mv[xy + wrap], d->mv[xy], 4); memcpy(d->mv[xy + wrap + 1], d->mv[xy], 4);
    }
}

static void hpel_mc(uint8_t *dst, const uint8_t *src, int stride, int size, int dxy, int no_rnd)
{
    for (int i = 0; i < size; i++, dst += stride, src += stride)
        for (int j = 0; j < size; j++) {
            switch (dxy) {
            case 0: dst[j] = src[j]; break;
            case 1: dst[j] = (uint8_t)((src[j] + src[j + 1] + 1 - no_rnd) >> 1); break;
            case 2: dst[j] = (uint8_t)((src[j] + src[j + stride] + 1 - no_rnd) >> 1); break;
            default: dst[j] = (uint8_t)((src[j] + src[j + 1] + src[j + stride] + src[j + stride + 1] + 2 - no_rnd) >> 2); break;
            }
        }
}

static void chroma_mc8(uint8_t *restrict dst, const uint8_t *restrict src, int stride, int x, int y, int no_rnd)
{
    if (!(x | y)) {
        for (int i = 0; i < 8; i++, dst += stride, src += stride) memcpy(dst, src, 8);
        return;
    }
    /* 16-bit lanes: the weighted sum is at most 64 * 255. */
    const uint16_t A = (uint16_t)((8 - x) * (8 - y)), B = (uint16_t)(x * (8 - y)), C = (uint16_t)((8 - x) * y),
                   D = (uint16_t)(x * y), r = (uint16_t)(32 - 4 * no_rnd);
    for (int i = 0; i < 8; i++, dst += stride, src += stride)
        for (int j = 0; j < 8; j++)
            dst[j] = (uint8_t)((uint16_t)(A * src[j] + B * src[j + 1] + C * src[j + stride] + D * src[j + stride + 1] + r) >> 6);
}

static void mc_luma(Wmv3Decoder *d, const Pic *ref, int bx, int by, int mx, int my, int size)
{
    int sx = clip(bx + (mx >> 2), -16, d->mb_w * 16), sy = clip(by + (my >> 2), -16, d->mb_h * 16);
    const uint8_t *src = ref->p[0] + (ptrdiff_t)sy * d->ls + sx;
    uint8_t *dst = d->pics[d->cur].p[0] + (ptrdiff_t)by * d->ls + bx;
    if (!((mx | my) & 3)) {
        for (int i = 0; i < size; i++) memcpy(dst + (ptrdiff_t)i * d->ls, src + (ptrdiff_t)i * d->ls, (size_t)size);
    } else if (d->mspel) {
        if (size == 16) wmv3_put_mspel16(dst, src, d->ls, mx & 3, my & 3, d->rnd);
        else wmv3_put_mspel8(dst, src, d->ls, mx & 3, my & 3, d->rnd);
    } else {
        hpel_mc(dst, src, d->ls, size, (my & 2) | ((mx & 2) >> 1), d->rnd);
    }
}

static void mc_chroma(Wmv3Decoder *d, const Pic *ref, int x, int y, int tx, int ty)
{
    int uvmx = (tx + ((tx & 3) == 3)) >> 1, uvmy = (ty + ((ty & 3) == 3)) >> 1;
    if (d->fastuvmc) {
        uvmx = uvmx + (uvmx < 0 ? (uvmx & 1) : -(uvmx & 1));
        uvmy = uvmy + (uvmy < 0 ? (uvmy & 1) : -(uvmy & 1));
    }
    int sx = clip(x * 8 + (uvmx >> 2), -8, d->mb_w * 8), sy = clip(y * 8 + (uvmy >> 2), -8, d->mb_h * 8);
    for (int p = 1; p < 3; p++)
        chroma_mc8(d->pics[d->cur].p[p] + (ptrdiff_t)(y * 8) * d->cs + x * 8,
                   ref->p[p] + (ptrdiff_t)sy * d->cs + sx, d->cs, (uvmx & 3) << 1, (uvmy & 3) << 1, d->rnd);
}

static void mc_4mv_chroma(Wmv3Decoder *d, const Pic *ref, int x, int y)
{
    int wrap, xy = blk_slot(d, x, y, 0, &wrap);
    int idx = !d->intra_y[xy] | (!d->intra_y[xy + 1] << 1) | (!d->intra_y[xy + wrap] << 2) | (!d->intra_y[xy + wrap + 1] << 3);
    static const uint8_t popcount4[16] = { 0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4 };
    static const uint8_t index2[16] = { 0, 0, 0, 0x01, 0, 0x02, 0x12, 0, 0, 0x03, 0x13, 0, 0x23, 0, 0, 0 };
    int16_t (*m)[2] = d->bmv;
    int tx, ty;
    switch (popcount4[idx]) {
    case 4:
        tx = median4(m[0][0], m[1][0], m[2][0], m[3][0]);
        ty = median4(m[0][1], m[1][1], m[2][1], m[3][1]);
        break;
    case 3:
        tx = mid3(m[idx > 0xd][0], m[1 + (idx > 0xb)][0], m[2 + (idx > 0x7)][0]);
        ty = mid3(m[idx > 0xd][1], m[1 + (idx > 0xb)][1], m[2 + (idx > 0x7)][1]);
        break;
    case 2:
        tx = (m[index2[idx] >> 4][0] + m[index2[idx] & 0xf][0]) / 2;
        ty = (m[index2[idx] >> 4][1] + m[index2[idx] & 0xf][1]) / 2;
        break;
    default:
        return; /* chroma is intra */
    }
    mc_chroma(d, ref, x, y, tx, ty);
}

static int pred_dc_p(Wmv3Decoder *d, int x, int y, int n, int a_avail, int c_avail, int *dir_left)
{
    int wrap, slot = blk_slot(d, x, y, n, &wrap);
    int16_t *dcv = n < 4 ? d->dc_y : d->dc_c[n - 4];
    int mb = (y + 1) * d->cbs + x + 1, ms = d->cbs;
    int q1 = abs(d->qscale[mb]), q2;
    int dqi = wmv3_dc_scale_table[q1] - 1;
    *dir_left = 0;
    if (dqi < 0) return 0;
    int c = dcv[slot - 1], b = dcv[slot - 1 - wrap], a = dcv[slot - wrap];
#define DQ(v, q) ((int)((unsigned)(v) * wmv3_dc_scale_table[q] * (unsigned)vc1_dqscale[dqi] + 0x20000) >> 18)
    if (c_avail && n != 1 && n != 3) { q2 = abs(d->qscale[mb - 1]); if (q2 && q2 != q1) c = DQ(c, q2); }
    if (a_avail && n != 2 && n != 3) { q2 = abs(d->qscale[mb - ms]); if (q2 && q2 != q1) a = DQ(a, q2); }
    if (a_avail && c_avail && n != 3) {
        int off = mb;
        if (n != 1) off--;
        if (n != 2) off -= ms;
        q2 = abs(d->qscale[off]);
        if (q2 && q2 != q1) b = DQ(b, q2);
    }
    if (c_avail && (!a_avail || abs(a - b) <= abs(b - c))) { *dir_left = 1; return c; }
    if (a_avail) return a;
    *dir_left = 1;
    return 0;
}

static int decode_intra_block_p(Wmv3Decoder *d, int16_t block[64], int x, int y, int n, int coded,
                                int mquant, int cs, int a_avail, int c_avail)
{
    Bits *gb = &d->gb;
    int wrap, slot = blk_slot(d, x, y, n, &wrap);
    int16_t *dcv = n < 4 ? d->dc_y : d->dc_c[n - 4];
    int16_t *acv = n < 4 ? d->ac_y : d->ac_c[n - 4];
    int use_pred = d->ac_pred, quant = abs(mquant), dir_left;
    memset(block, 0, 64 * 2);
    if (quant > 31) quant = 31;
    int dc_scale = wmv3_dc_scale_table[quant];
    int dcdiff = getvlc(gb, vlc_dc[d->dc_table_index][n >= 4]);
    if (dcdiff < 0) return -1;
    if (dcdiff) {
        const int m = (quant == 1 || quant == 2) ? 3 - quant : 0;
        if (dcdiff == 119) dcdiff = (int)get(gb, 8 + m);
        else if (m) dcdiff = (dcdiff << m) + (int)get(gb, m) - ((1 << m) - 1);
        if (get1(gb)) dcdiff = -dcdiff;
    }
    dcdiff += pred_dc_p(d, x, y, n, a_avail, c_avail, &dir_left);
    dcv[slot] = (int16_t)dcdiff;
    block[0] = (int16_t)(dcdiff * dc_scale);
    if (!a_avail) dir_left = 1;
    if (!c_avail) dir_left = 0;
    if (!a_avail && !c_avail) use_pred = 0;
    int16_t *ac2 = acv + (size_t)slot * 16;
    int16_t *ac = ac2 - (dir_left ? 16 : 16 * wrap);
    int scale = quant * 2 + (mquant < 0 ? 0 : d->halfpq);
    int mb = (y + 1) * d->cbs + x + 1;
    int q1 = d->qscale[mb], q2 = 0;
    if (dir_left && c_avail) q2 = d->qscale[mb - 1];
    if (!dir_left && a_avail) q2 = d->qscale[mb - d->cbs];
    if (dir_left && n == 1) q2 = q1;
    if (!dir_left && n == 2) q2 = q1;
    if (n == 3) q2 = q1;
    if (use_pred) {
        q1 = abs(q1) * 2 + (q1 < 0 ? 0 : d->halfpq) - 1;
        if (q1 < 1) return -1;
        if (q2) q2 = abs(q2) * 2 + (q2 < 0 ? 0 : d->halfpq) - 1;
    }
#define ACQ(v) ((int)((v) * (unsigned)q2 * (unsigned)vc1_dqscale[q1 - 1] + 0x20000) >> 18)
    if (coded) {
        int last = 0, skp, value;
        for (int i = 1; !last; ++i) {
            if (decode_ac_coeff(d, &last, &skp, &value, cs) < 0) return -1;
            i += skp;
            if (i > 63) break;
            block[d->zz_8x8[0][i]] = (int16_t)value;
        }
        if (use_pred) {
            if (q2 && q1 != q2) {
                if (dir_left) for (int k = 1; k < 8; k++) block[k] += (int16_t)ACQ(ac[k]);
                else for (int k = 1; k < 8; k++) block[k << 3] += (int16_t)ACQ(ac[k + 8]);
            } else {
                if (dir_left) for (int k = 1; k < 8; k++) block[k] += ac[k];
                else for (int k = 1; k < 8; k++) block[k << 3] += ac[k + 8];
            }
        }
        for (int k = 1; k < 8; k++) { ac2[k] = block[k]; ac2[k + 8] = block[k << 3]; }
        for (int k = 1; k < 64; k++)
            if (block[k]) {
                block[k] = (int16_t)(block[k] * scale);
                if (!d->pquantizer) block[k] += block[k] < 0 ? -quant : quant;
            }
    } else {
        memset(ac2, 0, 16 * 2);
        if (use_pred) {
            int o = dir_left ? 0 : 8, sh = dir_left ? 0 : 3;
            memcpy(ac2 + o, ac + o, 8 * 2);
            if (q2 && q1 != q2)
                for (int k = 1; k < 8; k++) ac2[k + o] = (int16_t)ACQ(ac2[k + o]);
            for (int k = 1; k < 8; k++) {
                int v = ac2[k + o] * scale;
                if (!d->pquantizer && v) v += v < 0 ? -quant : quant;
                block[k << sh] = (int16_t)v;
            }
        }
    }
    return 0;
}

static void add_pixels_clamped(const int16_t *blk, uint8_t *dst, int stride)
{
    for (int i = 0; i < 8; i++, dst += stride, blk += 8)
        for (int j = 0; j < 8; j++) {
            int v = dst[j] + blk[j];
            dst[j] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        }
}

static int decode_p_block(Wmv3Decoder *d, int16_t block[64], int mquant, int ttmb, int first_block,
                          uint8_t *dst, int linesize)
{
    Bits *gb = &d->gb;
    int subblkpat = 0, last, skp, value, i, idx, pat = 0;
    int ttblk = ttmb & 7, quant = abs(mquant);
    memset(block, 0, 64 * 2);
    if (ttmb == -1) {
        int t = getvlc(gb, vlc_ttblk[d->tt_index]);
        if (t < 0) return -1;
        ttblk = vc1_ttblk_to_tt[d->tt_index][t];
    }
    if (ttblk == TT_4X4) subblkpat = ~(getvlc(gb, vlc_subblk[d->tt_index]) + 1);
    if ((ttblk != TT_8X8 && ttblk != TT_4X4) &&
        ((d->ttmbf || (ttmb != -1 && (ttmb & 8) && !first_block)) || (!d->res_rtm_flag && !first_block))) {
        subblkpat = decode012(gb);
        if (subblkpat) subblkpat ^= 3;
        if (ttblk == TT_8X4_TOP || ttblk == TT_8X4_BOTTOM) ttblk = TT_8X4;
        if (ttblk == TT_4X8_RIGHT || ttblk == TT_4X8_LEFT) ttblk = TT_4X8;
    }
    int scale = quant * 2 + (mquant < 0 ? 0 : d->halfpq);
    if (ttblk == TT_8X4_TOP || ttblk == TT_8X4_BOTTOM) { subblkpat = 2 - (ttblk == TT_8X4_TOP); ttblk = TT_8X4; }
    if (ttblk == TT_4X8_RIGHT || ttblk == TT_4X8_LEFT) { subblkpat = 2 - (ttblk == TT_4X8_LEFT); ttblk = TT_4X8; }
#define PUTCOEF(pos) do { block[pos] = (int16_t)(value * scale); \
        if (!d->pquantizer) block[pos] += block[pos] < 0 ? -quant : quant; } while (0)
    switch (ttblk) {
    case TT_8X8:
        pat = 0xF; i = 0; last = 0;
        while (!last) {
            if (decode_ac_coeff(d, &last, &skp, &value, d->codingset2) < 0) return -1;
            i += skp;
            if (i > 63) break;
            idx = d->zz_8x8[0][i++];
            PUTCOEF(idx);
        }
        if (i == 1) wmv3_inv_trans_8x8_dc(dst, linesize, block);
        else { wmv3_inv_trans_8x8(block); add_pixels_clamped(block, dst, linesize); }
        break;
    case TT_4X4:
        pat = ~subblkpat & 0xF;
        for (int j = 0; j < 4; j++) {
            last = subblkpat & (1 << (3 - j));
            i = 0;
            int off = (j & 1) * 4 + (j & 2) * 16;
            while (!last) {
                if (decode_ac_coeff(d, &last, &skp, &value, d->codingset2) < 0) return -1;
                i += skp;
                if (i > 15) break;
                idx = vc1_simple_progressive_4x4_zz[i++] + off;
                PUTCOEF(idx);
            }
            if (!(subblkpat & (1 << (3 - j)))) {
                uint8_t *p = dst + (j & 1) * 4 + (j & 2) * 2 * linesize;
                if (i == 1) wmv3_inv_trans_4x4_dc(p, linesize, block + off);
                else wmv3_inv_trans_4x4(p, linesize, block + off);
            }
        }
        break;
    case TT_8X4:
        pat = ~((subblkpat & 2) * 6 + (subblkpat & 1) * 3) & 0xF;
        for (int j = 0; j < 2; j++) {
            last = subblkpat & (1 << (1 - j));
            i = 0;
            int off = j * 32;
            while (!last) {
                if (decode_ac_coeff(d, &last, &skp, &value, d->codingset2) < 0) return -1;
                i += skp;
                if (i > 31) break;
                idx = d->zz_8x4[i++] + off;
                PUTCOEF(idx);
            }
            if (!(subblkpat & (1 << (1 - j)))) {
                if (i == 1) wmv3_inv_trans_8x4_dc(dst + j * 4 * linesize, linesize, block + off);
                else wmv3_inv_trans_8x4(dst + j * 4 * linesize, linesize, block + off);
            }
        }
        break;
    case TT_4X8:
        pat = ~(subblkpat * 5) & 0xF;
        for (int j = 0; j < 2; j++) {
            last = subblkpat & (1 << (1 - j));
            i = 0;
            int off = j * 4;
            while (!last) {
                if (decode_ac_coeff(d, &last, &skp, &value, d->codingset2) < 0) return -1;
                i += skp;
                if (i > 31) break;
                idx = d->zz_4x8[i++] + off;
                PUTCOEF(idx);
            }
            if (!(subblkpat & (1 << (1 - j)))) {
                if (i == 1) wmv3_inv_trans_4x8_dc(dst + j * 4, linesize, block + off);
                else wmv3_inv_trans_4x8(dst + j * 4, linesize, block + off);
            }
        }
        break;
    }
    return pat;
}

static int get_mquant(Wmv3Decoder *d, int x, int y)
{
    int mquant = d->pq;
    if (!d->dquantfrm) return mquant;
    int edges = 0;
    if (d->dqprofile == DQPROFILE_ALL_MBS) {
        if (d->dqbilevel) mquant = get1(&d->gb) ? -d->altpq : d->pq;
        else {
            int mqdiff = (int)get(&d->gb, 3);
            mquant = mqdiff != 7 ? -d->pq - mqdiff : -(int)get(&d->gb, 5);
        }
    }
    if (d->dqprofile == DQPROFILE_SINGLE_EDGE) edges = 1 << d->dqsbedge;
    else if (d->dqprofile == DQPROFILE_DOUBLE_EDGES) edges = (3 << d->dqsbedge) % 15;
    else if (d->dqprofile == DQPROFILE_FOUR_EDGES) edges = 15;
    if ((edges & 1) && !x) mquant = -d->altpq;
    if ((edges & 2) && !y) mquant = -d->altpq;
    if ((edges & 4) && x == d->mb_w - 1) mquant = -d->altpq;
    if ((edges & 8) && y == d->mb_h - 1) mquant = -d->altpq;
    if (!mquant || mquant > 31 || mquant < -31) mquant = 1;
    return mquant;
}

static int decode_p_mb(Wmv3Decoder *d, const Pic *ref, int16_t (*blk)[64], int x, int y)
{
    Bits *gb = &d->gb;
    int mbpos = y * d->mb_w + x, mb = (y + 1) * d->cbs + x + 1;
    int fourmv = d->mv_type_is_raw ? get1(gb) : d->mv_type_plane[mbpos];
    int skipped = d->skip_is_raw ? get1(gb) : d->skip_plane[mbpos];
    int mquant = d->pq, ttmb = d->ttfrm, first_block = 1, cbp, dmv_x, dmv_y, intra;
    int w8, xy = blk_slot(d, x, y, 0, &w8);
    int cslot = mb;
    uint8_t *dsty = d->pics[d->cur].p[0] + (ptrdiff_t)(y * 16) * d->ls + x * 16;
    uint8_t *dstc[2] = { d->pics[d->cur].p[1] + (ptrdiff_t)(y * 8) * d->cs + x * 8,
                         d->pics[d->cur].p[2] + (ptrdiff_t)(y * 8) * d->cs + x * 8 };
    const int bxy[4] = { xy, xy + 1, xy + w8, xy + w8 + 1 };
#define IS_INTRA(i) ((i) < 4 ? d->intra_y[bxy[i]] : d->intra_c[cslot])
#define SET_INTRA(i, v) do { if ((i) < 4) d->intra_y[bxy[i]] = (uint8_t)(v); else d->intra_c[cslot] = (uint8_t)(v); } while (0)
#define DCV(i) ((i) < 4 ? &d->dc_y[bxy[i]] : &d->dc_c[(i) - 4][cslot])
#define A_AVAIL(i) (((i) == 2 || (i) == 3 || y) ? ((i) < 4 ? d->intra_y[bxy[i] - w8] : d->intra_c[cslot - d->cbs]) : 0)
#define C_AVAIL(i) (((i) == 1 || (i) == 3 || x) ? ((i) < 4 ? d->intra_y[bxy[i] - 1] : d->intra_c[cslot - 1]) : 0)
#define DST(i) ((i) < 4 ? dsty + ((i) & 1) * 8 + ((i) & 2) * 4 * d->ls : dstc[(i) - 4])
#define LS(i) ((i) < 4 ? d->ls : d->cs)
    if (!fourmv) {
        if (!skipped) {
            int has_coeffs = get_mvdata(d, &dmv_x, &dmv_y, &intra);
            pred_mv(d, x, y, 0, dmv_x, dmv_y, 1, intra);
            if (intra && !has_coeffs) {
                mquant = get_mquant(d, x, y);
                d->ac_pred = get1(gb);
                cbp = 0;
            } else if (has_coeffs) {
                if (intra) d->ac_pred = get1(gb);
                cbp = getvlc(gb, vlc_cbpcy[d->cbptab]);
                if (cbp < 0) return -1;
                mquant = get_mquant(d, x, y);
            } else {
                mquant = d->pq;
                cbp = 0;
            }
            d->qscale[mb] = (int8_t)mquant;
            if (!d->ttmbf && !intra && has_coeffs) ttmb = getvlc(gb, vlc_ttmb[d->tt_index]);
            if (!intra) {
                mc_luma(d, ref, x * 16, y * 16, d->bmv[0][0], d->bmv[0][1], 16);
                mc_chroma(d, ref, x, y, d->bmv[0][0], d->bmv[0][1]);
            }
            for (int i = 0; i < 6; i++) {
                *DCV(i) = 0;
                int val = (cbp >> (5 - i)) & 1;
                SET_INTRA(i, intra);
                if (intra) {
                    if (decode_intra_block_p(d, blk[i], x, y, i, val, mquant, i & 4 ? d->codingset2 : d->codingset,
                                             A_AVAIL(i), C_AVAIL(i)) < 0)
                        return -1;
                    wmv3_inv_trans_8x8(blk[i]);
                } else if (val) {
                    if (decode_p_block(d, blk[i], mquant, ttmb, first_block, DST(i), LS(i)) < 0) return -1;
                    if (!d->ttmbf && ttmb < 8) ttmb = -1;
                    first_block = 0;
                }
            }
        } else {
            for (int i = 0; i < 6; i++) { SET_INTRA(i, 0); *DCV(i) = 0; }
            d->qscale[mb] = 0;
            pred_mv(d, x, y, 0, 0, 0, 1, 0);
            mc_luma(d, ref, x * 16, y * 16, d->bmv[0][0], d->bmv[0][1], 16);
            mc_chroma(d, ref, x, y, d->bmv[0][0], d->bmv[0][1]);
        }
    } else {
        if (!skipped) {
            int intra_count = 0, coded_inter = 0, is_intra[6], is_coded[6];
            cbp = getvlc(gb, vlc_cbpcy[d->cbptab]);
            if (cbp < 0) return -1;
            for (int i = 0; i < 6; i++) {
                int val = (cbp >> (5 - i)) & 1;
                *DCV(i) = 0;
                if (i < 4) {
                    int has_coeffs = 0;
                    dmv_x = dmv_y = 0;
                    intra = 0;
                    if (val) has_coeffs = get_mvdata(d, &dmv_x, &dmv_y, &intra);
                    pred_mv(d, x, y, i, dmv_x, dmv_y, 0, intra);
                    if (!intra) mc_luma(d, ref, x * 16 + (i & 1) * 8, y * 16 + (i & 2) * 4, d->bmv[i][0], d->bmv[i][1], 8);
                    intra_count += intra;
                    is_intra[i] = intra;
                    is_coded[i] = has_coeffs;
                } else {
                    is_intra[i] = intra_count >= 3;
                    is_coded[i] = val;
                }
                if (i == 4) mc_4mv_chroma(d, ref, x, y);
                SET_INTRA(i, is_intra[i]);
                if (!coded_inter) coded_inter = (!is_intra[i]) & is_coded[i];
            }
            if (!intra_count && !coded_inter) return 0;
            mquant = get_mquant(d, x, y);
            d->qscale[mb] = (int8_t)mquant;
            int intrapred = 0;
            for (int i = 0; i < 6; i++)
                if (is_intra[i] && (((y || i == 2 || i == 3) && (i < 4 ? d->intra_y[bxy[i] - w8] : d->intra_c[cslot - d->cbs])) ||
                                    ((x || i == 1 || i == 3) && (i < 4 ? d->intra_y[bxy[i] - 1] : d->intra_c[cslot - 1])))) {
                    intrapred = 1;
                    break;
                }
            d->ac_pred = intrapred ? get1(gb) : 0;
            if (!d->ttmbf && coded_inter) ttmb = getvlc(gb, vlc_ttmb[d->tt_index]);
            for (int i = 0; i < 6; i++) {
                if (is_intra[i]) {
                    if (decode_intra_block_p(d, blk[i], x, y, i, is_coded[i], mquant, i & 4 ? d->codingset2 : d->codingset,
                                             A_AVAIL(i), C_AVAIL(i)) < 0)
                        return -1;
                    wmv3_inv_trans_8x8(blk[i]);
                } else if (is_coded[i]) {
                    if (decode_p_block(d, blk[i], mquant, ttmb, first_block, DST(i), LS(i)) < 0) return -1;
                    if (!d->ttmbf && ttmb < 8) ttmb = -1;
                    first_block = 0;
                }
            }
        } else {
            d->qscale[mb] = 0;
            for (int i = 0; i < 6; i++) { SET_INTRA(i, 0); *DCV(i) = 0; }
            for (int i = 0; i < 4; i++) {
                pred_mv(d, x, y, i, 0, 0, 0, 0);
                mc_luma(d, ref, x * 16 + (i & 1) * 8, y * 16 + (i & 2) * 4, d->bmv[i][0], d->bmv[i][1], 8);
            }
            mc_4mv_chroma(d, ref, x, y);
        }
    }
    return 0;
}

/* Puts the intra blocks of one MB row (inter blocks are reconstructed in
 * place), after overlap smoothing between intra neighbours. */
static void put_intra_row(Wmv3Decoder *d, int16_t (*row)[6][64], int y)
{
    Pic *p = &d->pics[d->cur];
    for (int x = 0; x < d->mb_w; x++) {
        int w, xy = blk_slot(d, x, y, 0, &w);
        uint8_t *dy = p->p[0] + (size_t)(y * 16) * d->ls + x * 16;
        if (d->intra_y[xy]) put_block(row[x][0], dy, d->ls, 128);
        if (d->intra_y[xy + 1]) put_block(row[x][1], dy + 8, d->ls, 128);
        if (d->intra_y[xy + w]) put_block(row[x][2], dy + 8 * d->ls, d->ls, 128);
        if (d->intra_y[xy + w + 1]) put_block(row[x][3], dy + 8 * d->ls + 8, d->ls, 128);
        if (d->intra_c[(y + 1) * d->cbs + x + 1]) {
            put_block(row[x][4], p->p[1] + (size_t)(y * 8) * d->cs + x * 8, d->cs, 128);
            put_block(row[x][5], p->p[2] + (size_t)(y * 8) * d->cs + x * 8, d->cs, 128);
        }
    }
}

static void overlap_p_rows(Wmv3Decoder *d, int16_t (*top)[6][64], int16_t (*row)[6][64], int y)
{
    const uint8_t *iy = d->intra_y, *ic = d->intra_c;
    int w = d->b8s;
    for (int x = 0; x < d->mb_w; x++) {
        int xy = (2 * y + 1) * w + 2 * x + 1, c = (y + 1) * d->cbs + x + 1;
        if (x) {
            if (iy[xy] && iy[xy - 1]) wmv3_h_s_overlap(row[x - 1][1], row[x][0], 8, 8, 1);
            if (iy[xy + w] && iy[xy + w - 1]) wmv3_h_s_overlap(row[x - 1][3], row[x][2], 8, 8, 1);
            if (ic[c] && ic[c - 1]) {
                wmv3_h_s_overlap(row[x - 1][4], row[x][4], 8, 8, 1);
                wmv3_h_s_overlap(row[x - 1][5], row[x][5], 8, 8, 1);
            }
        }
        if (iy[xy] && iy[xy + 1]) wmv3_h_s_overlap(row[x][0], row[x][1], 8, 8, 1);
        if (iy[xy + w] && iy[xy + w + 1]) wmv3_h_s_overlap(row[x][2], row[x][3], 8, 8, 1);
    }
    for (int x = 0; x < d->mb_w; x++) {
        int xy = (2 * y + 1) * w + 2 * x + 1, c = (y + 1) * d->cbs + x + 1;
        if (top) {
            if (iy[xy] && iy[xy - w]) wmv3_v_s_overlap(top[x][2], row[x][0]);
            if (iy[xy + 1] && iy[xy + 1 - w]) wmv3_v_s_overlap(top[x][3], row[x][1]);
            if (ic[c] && ic[c - d->cbs]) {
                wmv3_v_s_overlap(top[x][4], row[x][4]);
                wmv3_v_s_overlap(top[x][5], row[x][5]);
            }
        }
        if (iy[xy] && iy[xy + w]) wmv3_v_s_overlap(row[x][0], row[x][2]);
        if (iy[xy + 1] && iy[xy + w + 1]) wmv3_v_s_overlap(row[x][1], row[x][3]);
    }
}

static int decode_p_frame(Wmv3Decoder *d, const Pic *ref)
{
    switch (d->c_ac_table_index) {
    case 0:
        d->codingset = d->pqindex <= 8 ? CS_HIGH_RATE_INTRA : CS_LOW_MOT_INTRA;
        d->codingset2 = d->pqindex <= 8 ? CS_HIGH_RATE_INTER : CS_LOW_MOT_INTER;
        break;
    case 1: d->codingset = CS_HIGH_MOT_INTRA; d->codingset2 = CS_HIGH_MOT_INTER; break;
    default: d->codingset = CS_MID_RATE_INTRA; d->codingset2 = CS_MID_RATE_INTER; break;
    }
    int ovl = d->overlap && d->pq >= 9;
    for (int y = 0; y < d->mb_h; y++) {
        int16_t (*row)[6][64] = d->rows + (y & 1) * d->mb_w;
        int16_t (*prev)[6][64] = y ? d->rows + ((y - 1) & 1) * d->mb_w : NULL;
        for (int x = 0; x < d->mb_w; x++) {
            /* A Simple/Main frame is the whole packet, zero-padded to a byte
             * (421M has no stuffing syntax for these profiles), so a final
             * raw SKIPMBBIT can be the packet's last bit. FFmpeg stops and
             * conceals when <= 1 bit is left before a raw-plane MB; checked on
             * a 150k-frame WMV3 stream, all 1005 such frames end with that
             * bit = 1 and exactly 0 bits left, while the padding of every
             * other frame is zero, so the bit is data and is decoded. */
            if (decode_p_mb(d, ref, row[x], x, y) < 0 || left(&d->gb) < 0) return -1;
        }
        if (ovl) overlap_p_rows(d, prev, row, y);
        if (prev) put_intra_row(d, prev, y - 1);
    }
    put_intra_row(d, d->rows + ((d->mb_h - 1) & 1) * d->mb_w, d->mb_h - 1);
    return 0;
}

/* Replicates the picture edges into the padding so motion vectors pointing
 * outside read the same samples as FFmpeg's emulated_edge_mc. */
static void extend_edges(Wmv3Decoder *d, Pic *p)
{
    for (int pl = 0; pl < 3; pl++) {
        int w = pl ? (d->width + 1) >> 1 : d->width, h = pl ? (d->height + 1) >> 1 : d->height;
        int pad = pl ? CPAD : LPAD, ls = pl ? d->cs : d->ls;
        int rows_below = (pl ? d->mb_h * 8 : d->mb_h * 16) + pad - h;
        uint8_t *base = p->p[pl];
        for (int y = 0; y < h; y++) {
            uint8_t *r = base + (ptrdiff_t)y * ls;
            memset(r - pad, r[0], (size_t)pad);
            memset(r + w, r[w - 1], (size_t)(ls - pad - w));
        }
        for (int y = 1; y <= pad; y++) memcpy(base - pad - (ptrdiff_t)y * ls, base - pad, (size_t)ls);
        uint8_t *last = base - pad + (ptrdiff_t)(h - 1) * ls;
        for (int y = 1; y <= rows_below; y++) memcpy(last + (ptrdiff_t)y * ls, last, (size_t)ls);
    }
}

/* Intensity compensation (8.3.8): a LUT-mapped copy of the reference.
 * Ceiling: one full-frame pass per IC picture; per-block LUT is the upgrade. */
static const Pic *apply_ic(Wmv3Decoder *d, const Pic *ref)
{
    int lh = d->mb_h * 16 + 2 * LPAD, ch = d->mb_h * 8 + 2 * CPAD;
    size_t n = (size_t)d->ls * lh;
    for (size_t i = 0; i < n; i++) d->icpic.buf[0][i] = d->luty[ref->buf[0][i]];
    n = (size_t)d->cs * ch;
    for (int p = 1; p < 3; p++)
        for (size_t i = 0; i < n; i++) d->icpic.buf[p][i] = d->lutuv[ref->buf[p][i]];
    return &d->icpic;
}

/* -------------------------------------------------------------- frame */

int wmv3_decode(Wmv3Decoder *d, const uint8_t *data, size_t size, Wmv3Frame *out)
{
    if (size > (1u << 26)) return -1;
    if (d->pkt_cap < size + 16) {
        free(d->pkt);
        d->pkt_cap = size + 16;
        d->pkt = malloc(d->pkt_cap);
        if (!d->pkt) { d->pkt_cap = 0; return -1; }
    }
    if (size) memcpy(d->pkt, data, size);
    memset(d->pkt + size, 0, 16);
    d->gb.buf = d->pkt; d->gb.idx = 0; d->gb.size = (int)size * 8;
    int r = parse_header(d);
    /* A 1-byte packet is a skipped frame: the previous picture repeats. The
     * header parse above still runs because it updates the rounding state. */
    if (size <= 1) return d->have_ref ? 0 : -1;
    if (r < 0) return r;
    if (d->pict_type == PT_P && !d->have_ref) return -1;
    d->esc3_level_length = 0;
    const Pic *ref = &d->pics[d->cur];
    if (d->have_ref) d->cur = !d->cur;
    if (d->pict_type == PT_I) {
        memset(d->coded, 0, (size_t)d->b8s * (2 * d->mb_h + 1));
        r = decode_i_frame(d);
    } else {
        r = decode_p_frame(d, d->use_ic ? apply_ic(d, ref) : ref);
    }
    if (r < 0) return r; /* the partially decoded picture is kept as reference */
    d->have_ref = 1;
    Pic *p = &d->pics[d->cur];
    extend_edges(d, p);
    for (int i = 0; i < 3; i++) { out->data[i] = p->p[i]; out->linesize[i] = i ? d->cs : d->ls; }
    out->width = d->width; out->height = d->height;
    out->keyframe = d->pict_type == PT_I;
    return 1;
}
