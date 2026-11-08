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
    return (unsigned)((rb64(b->buf + (b->idx >> 3)) << (b->idx & 7)) >> (64 - n));
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
static Vlc vlc_imode, vlc_norm2, vlc_norm6, vlc_cbpcy[4], vlc_mvdiff[4], vlc_ttmb[3], vlc_ttblk[3], vlc_subblk[3], vlc_4mvbp[4];

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
        vlc_4mvbp[i] = mkvlc(16, 6, vc1_4mv_block_pattern_codes[i], 1, 1, vc1_4mv_block_pattern_bits[i], 1, 1);
        vlc_cbpcy[i] = mkvlc(64, 9, vc1_cbpcy_p_codes[i], 2, 2, vc1_cbpcy_p_bits[i], 1, 1);
        vlc_mvdiff[i] = mkvlc(73, 9, vc1_mv_diff_codes[i], 2, 2, vc1_mv_diff_bits[i], 1, 1);
    }
}
static pthread_once_t vlc_once = PTHREAD_ONCE_INIT;

/* ------------------------------------------------------------- context */

enum { PT_I, PT_P };
enum { CS_HIGH_MOT_INTRA, CS_HIGH_MOT_INTER, CS_LOW_MOT_INTRA, CS_LOW_MOT_INTER,
       CS_MID_RATE_INTRA, CS_MID_RATE_INTER, CS_HIGH_RATE_INTRA, CS_HIGH_RATE_INTER };

#define LPAD 32
#define CPAD 16

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
    free(d->dc_y); free(d->dc_c[0]); free(d->dc_c[1]);
    free(d->ac_y); free(d->ac_c[0]); free(d->ac_c[1]);
    free(d->coded); free(d->rows); free(d->pkt);
    free(d);
}

Wmv3Decoder *wmv3_decoder_open(const uint8_t *ex, size_t exsize, int width, int height)
{
    if (!ex || exsize < 4 || width <= 0 || height <= 0 || width > 4096 || height > 4096) return NULL;
    pthread_once(&vlc_once, init_vlcs);
    Wmv3Decoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
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
    /* Advanced profile, sprites, X8 intra and the pre-release (non-FASTTX)
     * transform are out of scope. */
    if (d->profile > 1 || res_y411 || res_sprite || res_x8 || !res_fasttx || res_transtab ||
        (!d->profile && (!d->fastuvmc || d->extended_mv))) {
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
    if (!d->dc_y || !d->dc_c[0] || !d->dc_c[1] || !d->ac_y || !d->ac_c[0] || !d->ac_c[1] || !d->coded ||
        !d->rows || pic_alloc(d, &d->pics[0]) || pic_alloc(d, &d->pics[1])) {
        wmv3_decoder_close(d);
        return NULL;
    }
    return d;
}

/* ------------------------------------------------------- picture header */

static int parse_header(Wmv3Decoder *d)
{
    Bits *gb = &d->gb;
    if (d->finterpflag) skip(gb, 1);
    skip(gb, 2); /* frame count */
    d->rangeredfrm = d->rangered ? get1(gb) : 0;
    if (get1(gb)) d->pict_type = PT_P;
    else if (d->max_b_frames && !get1(gb)) return -2; /* B / BI: not supported */
    else d->pict_type = PT_I;
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
    if (d->pict_type == PT_P) return -2; /* TODO */
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
                if (d->pq < 8 /* || dquantfrm */) {
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
            if (d->rangeredfrm)
                for (int k = 0; k < 6; k++)
                    for (int j = 0; j < 64; j++)
                        row[x][k][j] = (int16_t)(ovl ? row[x][k][j] * 2 : (row[x][k][j] - 64) * 2);
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

/* -------------------------------------------------------------- frame */

int wmv3_decode(Wmv3Decoder *d, const uint8_t *data, size_t size, Wmv3Frame *out)
{
    if (size <= 1) {
        /* A 0/1-byte packet is a skipped (repeat) frame. */
        if (!d->have_ref) return -1;
        return 0;
    }
    if (size > (1u << 26)) return -1;
    if (d->pkt_cap < size + 16) {
        free(d->pkt);
        d->pkt_cap = size + 16;
        d->pkt = malloc(d->pkt_cap);
        if (!d->pkt) { d->pkt_cap = 0; return -1; }
    }
    memcpy(d->pkt, data, size);
    memset(d->pkt + size, 0, 16);
    d->gb.buf = d->pkt; d->gb.idx = 0; d->gb.size = (int)size * 8;
    int r = parse_header(d);
    if (r < 0) return r;
    d->esc3_level_length = 0;
    d->cur = d->have_ref ? !d->cur : d->cur;
    memset(d->coded, 0, (size_t)d->b8s * (2 * d->mb_h + 1));
    r = decode_i_frame(d);
    if (r < 0) return r;
    d->have_ref = 1;
    Pic *p = &d->pics[d->cur];
    for (int i = 0; i < 3; i++) { out->data[i] = p->p[i]; out->linesize[i] = i ? d->cs : d->ls; }
    out->width = d->width; out->height = d->height;
    out->keyframe = d->pict_type == PT_I;
    return 1;
}
