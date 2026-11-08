/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Synthetic checks for the WMV3 decoder: VLC tables round-trip through the
 * table builder, the 8x8 inverse transform matches SMPTE 421M's matrix, and
 * sequence headers enabling unimplemented tools are refused.
 */
#include "wmv3dec.c"

#include <stdio.h>

static int fails;

static void put_bits(uint8_t *buf, int *pos, uint32_t code, int len)
{
    for (int i = len - 1; i >= 0; i--, (*pos)++)
        if ((code >> i) & 1) buf[*pos >> 3] |= (uint8_t)(0x80 >> (*pos & 7));
}

/* Writes every code of the table and checks it decodes to its index. */
static void check_vlc(const char *name, Vlc v, int n, const void *codes, int csz, int cstride,
                      const void *lens, int lsz, int lstride)
{
    for (int i = 0; i < n; i++) {
        const uint8_t *cp = (const uint8_t *)codes + (size_t)i * (size_t)cstride;
        const uint8_t *lp = (const uint8_t *)lens + (size_t)i * (size_t)lstride;
        uint32_t code = csz == 1 ? *cp : csz == 2 ? *(const uint16_t *)cp : *(const uint32_t *)cp;
        int len = lsz == 1 ? *lp : lsz == 2 ? *(const uint16_t *)lp : (int)*(const uint32_t *)lp;
        if (!len) continue;
        uint8_t buf[16] = {0};
        int pos = 0;
        put_bits(buf, &pos, code, len);
        Bits b = { buf, 0, 64 };
        int sym = getvlc(&b, v);
        if (sym != i || b.idx != len) {
            printf("FAIL %s[%d]: got %d after %d bits (want %d bits)\n", name, i, sym, b.idx, len);
            fails++;
            return;
        }
    }
}

static const int T8[8][8] = {
    { 12, 12, 12, 12, 12, 12, 12, 12 }, { 16, 15, 9, 4, -4, -9, -15, -16 },
    { 16, 6, -6, -16, -16, -6, 6, 16 }, { 15, -4, -16, -9, 9, 16, 4, -15 },
    { 12, -12, -12, 12, 12, -12, -12, 12 }, { 9, -16, 4, 15, -15, -4, 16, -9 },
    { 6, -16, 16, -6, -6, 16, -16, 6 }, { 4, -9, 15, -16, 16, -15, 9, -4 },
};

static void check_transform(void)
{
    uint32_t seed = 1;
    for (int iter = 0; iter < 2000; iter++) {
        int16_t blk[64], ref[64], tmp[64];
        for (int i = 0; i < 64; i++) {
            seed = seed * 1103515245u + 12345u;
            blk[i] = (int16_t)(((seed >> 16) % 601) - 300) * ((seed >> 8) % 3 == 0);
        }
        for (int c = 0; c < 8; c++)
            for (int i = 0; i < 8; i++) {
                int s = 0;
                for (int k = 0; k < 8; k++) s += T8[k][i] * blk[8 * k + c];
                tmp[c * 8 + i] = (int16_t)((s + 4) >> 3);
            }
        for (int c = 0; c < 8; c++)
            for (int i = 0; i < 8; i++) {
                int s = 0;
                for (int k = 0; k < 8; k++) s += T8[k][i] * tmp[8 * k + c];
                ref[8 * i + c] = (int16_t)((s + 64 + (i >= 4)) >> 7);
            }
        wmv3_inv_trans_8x8(blk);
        if (memcmp(blk, ref, sizeof(ref))) {
            printf("FAIL inverse 8x8 transform, iteration %d\n", iter);
            fails++;
            return;
        }
    }
}

int main(void)
{
    pthread_once(&vlc_once, init_vlcs);
    check_vlc("mb_i", vlc_mb_i, 64, &msmp4_mb_i_table[0][0], 2, 4, &msmp4_mb_i_table[0][1], 2, 4);
    for (int i = 0; i < 2; i++)
        for (int j = 0; j < 2; j++)
            check_vlc("dc", vlc_dc[i][j], 120, &msmp4_dc_tables[i][j][0][0], 4, 8, &msmp4_dc_tables[i][j][0][1], 4, 8);
    for (int i = 0; i < AC_MODES; i++)
        check_vlc("ac", vlc_ac[i], vc1_ac_sizes[i], &vc1_ac_tables[i][0][0], 4, 8, &vc1_ac_tables[i][0][1], 4, 8);
    check_vlc("norm6", vlc_norm6, 64, vc1_norm6_codes, 2, 2, vc1_norm6_bits, 1, 1);
    for (int i = 0; i < 4; i++) {
        check_vlc("cbpcy", vlc_cbpcy[i], 64, vc1_cbpcy_p_codes[i], 2, 2, vc1_cbpcy_p_bits[i], 1, 1);
        check_vlc("mvdiff", vlc_mvdiff[i], 73, vc1_mv_diff_codes[i], 2, 2, vc1_mv_diff_bits[i], 1, 1);
    }
    check_transform();
    /* Simple profile with every tool off is admitted; MAXBFRAMES = 1 is not. */
    static const uint8_t simple[4] = { 0x00, 0x01, 0x80, 0x01 }, bframes[4] = { 0x00, 0x01, 0x80, 0x11 };
    if (!wmv3_sequence_supported(simple, 4) || wmv3_sequence_supported(bframes, 4) ||
        wmv3_decoder_open(bframes, 4, 16, 16)) {
        printf("FAIL sequence header admission\n");
        fails++;
    }
    if (pool_pos > POOL_SIZE) { printf("FAIL VLC pool overflow %d\n", pool_pos); fails++; }
    printf("%s (VLC pool %d entries)\n", fails ? "FAILED" : "ok", pool_pos);
    return fails != 0;
}
