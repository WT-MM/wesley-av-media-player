// SPDX-License-Identifier: LGPL-2.1-or-later
//
// WMA v2 decoder. WMA has no public specification; the bitstream layout,
// tables and reconstruction follow FFmpeg's reverse-engineered decoder
// (libavcodec/wma.c, wmadec.c, copyright (c) 2002 The FFmpeg Project), whose
// arithmetic this file reproduces so output matches FFmpeg to float rounding.
// The IMDCT runs on Accelerate's DCT-IV.

#include "wam_wmcodecs.h"

#include "wma_tables.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace wam::wmcodecs {
namespace {

using namespace tables;

constexpr int kBlockMinBits = 7;
constexpr int kBlockMaxBits = 11;
constexpr int kBlockMaxSize = 1 << kBlockMaxBits;
constexpr int kBlockSizes = kBlockMaxBits - kBlockMinBits + 1;
constexpr int kHighBandMax = 16;
constexpr int kMaxChannels = 2;
constexpr int kNoiseTabSize = 8192;
constexpr int kLspPowBits = 7;
constexpr int kMaxSuperframe = 32768;
constexpr int kPadding = 64;

// MSB-first reader. Like FFmpeg's checked reader the position saturates at
// size + 8 bits, and buffers carry kPadding zero bytes so 8-byte loads past
// the end are safe.
struct BitReader {
  const uint8_t* buf = nullptr;
  uint32_t pos = 0;
  uint32_t size = 0;  // bits
  uint32_t limit = 0; // size + 8

  void init(const uint8_t* b, int bits) {
    buf = b;
    pos = 0;
    size = uint32_t(std::max(bits, 0));
    limit = size + 8;
  }
  uint32_t peek32() const {
    uint64_t v;
    std::memcpy(&v, buf + (pos >> 3), 8);
    v = __builtin_bswap64(v);
    return uint32_t((v << (pos & 7)) >> 32);
  }
  void skip(uint32_t n) { pos = std::min(pos + n, limit); }
  uint32_t get(int n) {
    if (n == 0) return 0;
    uint32_t r = peek32() >> (32 - n);
    skip(uint32_t(n));
    return r;
  }
  uint32_t get1() { return get(1); }
  int left() const { return int(size) - int(pos); }
};

// Multi-level Huffman lookup in the style of FFmpeg's VLC tables.
// len > 0: leaf of that many bits; len < 0: subtable of -len index bits
// starting at `sym`; len == 0: invalid code.
struct Vlc {
  struct Entry {
    int32_t sym;
    int8_t len;
  };
  std::vector<Entry> table;
  int bits = 9;

  struct Code {
    uint32_t code;
    int len;
    int sym;
  };

  void build(std::vector<Code> codes, int root_bits) {
    bits = root_bits;
    table.clear();
    build_level(codes, 0, root_bits);
  }

  // Builds a table for `codes` (code values with the already-consumed
  // prefix removed, lengths relative) and returns its offset.
  int build_level(const std::vector<Code>& codes, int, int nb) {
    int base = int(table.size());
    table.resize(size_t(base) + (size_t(1) << nb), Entry{-1, 0});
    for (const auto& c : codes) {
      if (c.len <= nb) {
        uint32_t first = c.code << (nb - c.len);
        uint32_t count = 1u << (nb - c.len);
        for (uint32_t i = 0; i < count; i++)
          table[size_t(base) + first + i] = Entry{c.sym, int8_t(c.len)};
      }
    }
    for (uint32_t idx = 0; idx < (1u << nb); idx++) {
      std::vector<Code> sub;
      int maxlen = 0;
      for (const auto& c : codes) {
        if (c.len > nb && (c.code >> (c.len - nb)) == idx) {
          int rl = c.len - nb;
          sub.push_back(Code{c.code & ((1u << rl) - 1), rl, c.sym});
          maxlen = std::max(maxlen, rl);
        }
      }
      if (sub.empty()) continue;
      int sub_bits = std::min(maxlen, bits);
      int off = build_level(sub, 0, sub_bits);
      table[size_t(base) + idx] = Entry{off, int8_t(-sub_bits)};
    }
    return base;
  }

  // Returns the symbol, or INT32_MIN for an invalid code.
  int decode(BitReader& br) const {
    int nb = bits;
    const Entry* e = &table[br.peek32() >> (32 - nb)];
    while (e->len < 0) {
      br.skip(uint32_t(nb));
      nb = -e->len;
      e = &table[size_t(e->sym) + (br.peek32() >> (32 - nb))];
    }
    if (e->len == 0) return INT32_MIN;
    br.skip(uint32_t(e->len));
    return e->sym;
  }
};

struct CoefTable {
  Vlc vlc;
  std::vector<uint16_t> run;
  std::vector<float> level;
};

int log2_floor(unsigned v) { return v ? 31 - __builtin_clz(v) : 0; }

double exp10_ff(double x) { return std::exp2(3.32192809488736234787 * x); }

}  // namespace

struct Decoder {
  int channels = 0;
  int sample_rate = 0;
  int block_align = 0;
  bool use_exp_vlc = false;
  bool use_bit_reservoir = false;
  bool use_variable_block_len = false;
  bool use_noise_coding = false;
  int byte_offset_bits = 0;

  Vlc exp_vlc;
  Vlc hgain_vlc;
  CoefTable coef[2];

  int exponent_sizes[kBlockSizes] = {};
  uint16_t exponent_bands[kBlockSizes][25] = {};
  int high_band_start[kBlockSizes] = {};
  int coefs_end[kBlockSizes] = {};
  int exponent_high_sizes[kBlockSizes] = {};
  int exponent_high_bands[kBlockSizes][kHighBandMax] = {};

  int high_band_coded[kMaxChannels][kHighBandMax] = {};
  int high_band_values[kMaxChannels][kHighBandMax] = {};

  int frame_len = 0;
  int frame_len_bits = 0;
  int nb_block_sizes = 0;

  bool reset_block_lengths = true;
  int block_len_bits = 0;
  int next_block_len_bits = 0;
  int prev_block_len_bits = 0;
  int block_len = 0;
  int block_pos = 0;
  bool ms_stereo = false;
  bool channel_coded[kMaxChannels] = {};
  int exponents_bsize[kMaxChannels] = {};
  bool exponents_initialized[kMaxChannels] = {};
  float max_exponent[kMaxChannels] = {1.0f, 1.0f};

  alignas(32) float exponents[kMaxChannels][kBlockMaxSize] = {};
  alignas(32) float coefs1[kMaxChannels][kBlockMaxSize] = {};
  alignas(32) float coefs[kMaxChannels][kBlockMaxSize] = {};
  alignas(32) float output[kBlockMaxSize * 2] = {};
  alignas(32) float dct_out[kBlockMaxSize] = {};
  alignas(32) float frame_out[kMaxChannels][kBlockMaxSize * 2] = {};

  vDSP_DFT_Setup dct[kBlockSizes] = {};
  std::vector<float> windows[kBlockSizes];

  uint8_t packet[kMaxSuperframe + kPadding] = {};
  uint8_t last_superframe[kMaxSuperframe + kPadding] = {};
  int last_bitoffset = 0;
  int last_superframe_len = 0;
  bool eof_done = false;
  // Decoder delay: the first two frames are priming and are dropped, as
  // FFmpeg does, so sample positions match the container's timestamps.
  int skip = 0;

  int trim(float* const* out, int n) {
    int drop = std::min(skip, n);
    if (drop <= 0) return n;
    skip -= drop;
    for (int ch = 0; ch < channels; ch++)
      std::memmove(out[ch], out[ch] + drop, size_t(n - drop) * sizeof(float));
    return n - drop;
  }

  float noise_table[kNoiseTabSize] = {};
  int noise_index = 0;
  float noise_mult = 0;

  float lsp_cos_table[kBlockMaxSize] = {};
  float lsp_pow_e_table[256] = {};
  float lsp_pow_m_table1[1 << kLspPowBits] = {};
  float lsp_pow_m_table2[1 << kLspPowBits] = {};

  BitReader gb;

  ~Decoder() {
    for (auto& d : dct)
      if (d) vDSP_DFT_DestroySetup(d);
  }

  bool init(const wam_wma_config& cfg);
  int decode_block();
  int decode_frame(float* const* out, int offset);
  int decode_superframe(const uint8_t* data, int size, float* const* out, int capacity);
  int decode_exp_vlc(int ch);
  void decode_exp_lsp(int ch);
  int run_level_decode(const CoefTable& t, float* ptr, int num_coefs, int coef_nb_bits);
  void window(float* out);
  void imdct(int bsize, const float* in);
};

bool Decoder::init(const wam_wma_config& cfg) {
  channels = cfg.channels;
  sample_rate = cfg.sample_rate;
  block_align = cfg.block_align;
  if (channels < 1 || channels > kMaxChannels || sample_rate <= 0 || sample_rate > 50000 ||
      cfg.bit_rate <= 0 || block_align <= 0 || block_align > kMaxSuperframe)
    return false;

  int flags2 = 0;
  if (cfg.extradata && cfg.extradata_size >= 6)
    flags2 = cfg.extradata[4] | (cfg.extradata[5] << 8);
  use_exp_vlc = flags2 & 1;
  use_bit_reservoir = flags2 & 2;
  use_variable_block_len = flags2 & 4;
  // Streams with flags 0x000d decode correctly only with fixed blocks
  // (FFmpeg issue 1503).
  if (cfg.extradata_size >= 8 && flags2 == 0xd && use_variable_block_len)
    use_variable_block_len = false;

  frame_len_bits = sample_rate <= 16000 ? 9 : sample_rate <= 22050 ? 10 : 11;
  frame_len = 1 << frame_len_bits;
  next_block_len_bits = prev_block_len_bits = block_len_bits = frame_len_bits;
  skip = 2 * frame_len;

  if (use_variable_block_len) {
    int nb = ((flags2 >> 3) & 3) + 1;
    if ((cfg.bit_rate / channels) >= 32000) nb += 2;
    nb = std::min(nb, frame_len_bits - kBlockMinBits);
    nb_block_sizes = nb + 1;
  } else {
    nb_block_sizes = 1;
  }

  use_noise_coding = true;
  float high_freq = float(sample_rate * 0.5);
  int sample_rate1 = sample_rate;
  if (sample_rate1 >= 44100) sample_rate1 = 44100;
  else if (sample_rate1 >= 22050) sample_rate1 = 22050;
  else if (sample_rate1 >= 16000) sample_rate1 = 16000;
  else if (sample_rate1 >= 11025) sample_rate1 = 11025;
  else if (sample_rate1 >= 8000) sample_rate1 = 8000;

  float bps = float(cfg.bit_rate) / float(channels * sample_rate);
  byte_offset_bits = log2_floor(unsigned(int(bps * frame_len / 8.0 + 0.5))) + 2;
  if (byte_offset_bits + 3 > 25) return false;

  float bps1 = bps;
  if (channels == 2) bps1 = float(bps * 1.6);
  if (sample_rate1 == 44100) {
    if (bps1 >= 0.61) use_noise_coding = false;
    else high_freq = float(high_freq * 0.4);
  } else if (sample_rate1 == 22050) {
    if (bps1 >= 1.16) use_noise_coding = false;
    else if (bps1 >= 0.72) high_freq = float(high_freq * 0.7);
    else high_freq = float(high_freq * 0.6);
  } else if (sample_rate1 == 16000) {
    high_freq = float(high_freq * (bps > 0.5 ? 0.5 : 0.3));
  } else if (sample_rate1 == 11025) {
    high_freq = float(high_freq * 0.7);
  } else if (sample_rate1 == 8000) {
    if (bps <= 0.625) high_freq = float(high_freq * 0.5);
    else if (bps > 0.75) use_noise_coding = false;
    else high_freq = float(high_freq * 0.65);
  } else {
    if (bps >= 0.8) high_freq = float(high_freq * 0.75);
    else if (bps >= 0.6) high_freq = float(high_freq * 0.6);
    else high_freq = float(high_freq * 0.5);
  }

  for (int k = 0; k < nb_block_sizes; k++) {
    int block = frame_len >> k;
    const uint8_t* table = nullptr;
    int a = frame_len_bits - kBlockMinBits - k;
    if (a < 3) {
      if (sample_rate >= 44100) table = exponent_band_44100[a];
      else if (sample_rate >= 32000) table = exponent_band_32000[a];
      else if (sample_rate >= 22050) table = exponent_band_22050[a];
    }
    if (table) {
      int n = *table++;
      for (int i = 0; i < n; i++) exponent_bands[k][i] = table[i];
      exponent_sizes[k] = n;
    } else {
      int j = 0, lpos = 0;
      for (int i = 0; i < 25; i++) {
        int f = ff_wma_critical_freqs[i];
        int pos = ((block * 2 * f) + (sample_rate << 1)) / (4 * sample_rate);
        pos <<= 2;
        pos = std::min(pos, block);
        if (pos > lpos) exponent_bands[k][j++] = uint16_t(pos - lpos);
        if (pos >= block) break;
        lpos = pos;
      }
      exponent_sizes[k] = j;
    }
    coefs_end[k] = (frame_len - ((frame_len * 9) / 100)) >> k;
    high_band_start[k] = int((block * 2 * high_freq) / sample_rate + 0.5);
    int j = 0, pos = 0;
    for (int i = 0; i < exponent_sizes[k]; i++) {
      int start = pos;
      pos += exponent_bands[k][i];
      int end = pos;
      start = std::max(start, high_band_start[k]);
      end = std::min(end, coefs_end[k]);
      if (end > start) {
        if (j >= kHighBandMax) return false;
        exponent_high_bands[k][j++] = end - start;
      }
    }
    exponent_high_sizes[k] = j;
  }

  for (int i = 0; i < nb_block_sizes; i++) {
    int n = 1 << (frame_len_bits - i);
    windows[i].resize(size_t(n));
    for (int j = 0; j < n; j++)
      windows[i][size_t(j)] = sinf(float((j + 0.5) * (M_PI / (2.0 * n))));
    dct[i] = vDSP_DCT_CreateSetup(nullptr, vDSP_Length(n), vDSP_DCT_IV);
    if (!dct[i]) return false;
  }

  if (use_noise_coding) {
    noise_mult = use_exp_vlc ? 0.02f : 0.04f;
    unsigned seed = 1;
    float norm = float((1.0 / float(1LL << 31)) * std::sqrt(3.0) * noise_mult);
    for (int i = 0; i < kNoiseTabSize; i++) {
      seed = seed * 314159 + 1;
      noise_table[i] = float(int(seed)) * norm;
    }
    // Canonical codes assigned in table order (FFmpeg vlc_init_from_lengths).
    std::vector<Vlc::Code> codes;
    uint32_t code = 0;
    for (const auto& e : ff_wma_hgain_hufftab) {
      int len = e[1];
      codes.push_back({code >> (32 - len), len, int(e[0]) - 18});
      code += 1u << (32 - len);
    }
    hgain_vlc.build(codes, 9);
  }

  int table = 2;
  if (sample_rate >= 32000) {
    if (bps1 < 0.72) table = 0;
    else if (bps1 < 1.16) table = 1;
  }
  for (int t = 0; t < 2; t++) {
    const CoefVlcTable& src = coef_vlcs[table * 2 + t];
    std::vector<Vlc::Code> codes;
    for (int i = 0; i < src.n; i++) codes.push_back({src.huffcodes[i], src.huffbits[i], i});
    coef[t].vlc.build(codes, 9);
    coef[t].run.assign(size_t(src.n), 0);
    coef[t].level.assign(size_t(src.n), 0);
    int i = 2, level = 1, k = 0;
    while (i < src.n && k < src.levels_n) {
      int l = src.levels[k++];
      for (int j = 0; j < l && i < src.n; j++, i++) {
        coef[t].run[size_t(i)] = uint16_t(j);
        coef[t].level[size_t(i)] = float(level);
      }
      level++;
    }
  }

  if (use_exp_vlc) {
    std::vector<Vlc::Code> codes;
    for (int i = 0; i < 121; i++)
      codes.push_back({ff_aac_scalefactor_code[i], ff_aac_scalefactor_bits[i], i});
    exp_vlc.build(codes, 8);
  } else {
    float wdel = float(M_PI / frame_len);
    for (int i = 0; i < frame_len; i++) lsp_cos_table[i] = 2.0f * float(std::cos(double(wdel) * i));
    for (int i = 0; i < 256; i++) lsp_pow_e_table[i] = exp2f(float((i - 126) * -0.25));
    float b = 1.0f;
    for (int i = (1 << kLspPowBits) - 1; i >= 0; i--) {
      int m = (1 << kLspPowBits) + i;
      float a = float(m * (0.5 / (1 << kLspPowBits)));
      a = float(1 / std::sqrt(std::sqrt(double(a))));
      lsp_pow_m_table1[i] = 2 * a - b;
      lsp_pow_m_table2[i] = b - a;
      b = a;
    }
  }
  return true;
}

void Decoder::decode_exp_lsp(int ch) {
  float lsp[kLspCoefs];
  for (int i = 0; i < kLspCoefs; i++) {
    int val = int(gb.get((i == 0 || i >= 8) ? 3 : 4));
    lsp[i] = ff_wma_lsp_codebook[i][val];
  }
  float val_max = 0;
  float* out = exponents[ch];
  for (int i = 0; i < block_len; i++) {
    float p = 0.5f, q = 0.5f, w = lsp_cos_table[i];
    for (int j = 1; j < kLspCoefs; j += 2) {
      q *= w - lsp[j - 1];
      p *= w - lsp[j];
    }
    p *= p * (2.0f - w);
    q *= q * (2.0f + w);
    float v = p + q;
    // v^-0.25 by exponent table and linear interpolation of the mantissa.
    uint32_t u;
    std::memcpy(&u, &v, 4);
    uint32_t e = u >> 23;
    uint32_t m = (u >> (23 - kLspPowBits)) & ((1 << kLspPowBits) - 1);
    uint32_t tv = ((u << kLspPowBits) & ((1 << 23) - 1)) | (127u << 23);
    float t;
    std::memcpy(&t, &tv, 4);
    v = lsp_pow_e_table[e] * (lsp_pow_m_table1[m] + lsp_pow_m_table2[m] * t);
    val_max = std::max(val_max, v);
    out[i] = v;
  }
  max_exponent[ch] = val_max;
}

int Decoder::decode_exp_vlc(int ch) {
  const uint16_t* ptr = exponent_bands[frame_len_bits - block_len_bits];
  float* q = exponents[ch];
  float* q_end = q + block_len;
  const float* ptab = pow_tab + 60;
  constexpr int kPowTabSize = int(sizeof(pow_tab) / sizeof(pow_tab[0]));
  float max_scale = 0;
  int last_exp = 36;
  while (q < q_end) {
    int code = exp_vlc.decode(gb);
    if (code == INT32_MIN) return -1;
    last_exp += code - 60;
    if (unsigned(last_exp + 60) >= unsigned(kPowTabSize)) return -1;
    float v = ptab[last_exp];
    max_scale = std::max(max_scale, v);
    int n = *ptr++;
    if (n <= 0 || n > q_end - q) return -1;
    std::fill(q, q + n, v);
    q += n;
  }
  max_exponent[ch] = max_scale;
  return 0;
}

int Decoder::run_level_decode(const CoefTable& t, float* ptr, int num_coefs, int coef_nb_bits) {
  const unsigned mask = unsigned(block_len - 1);
  int offset = 0;
  for (; offset < num_coefs; offset++) {
    int code = t.vlc.decode(gb);
    if (code > 1) {
      offset += t.run[size_t(code)];
      float l = t.level[size_t(code)];
      ptr[unsigned(offset) & mask] = gb.get1() ? l : -l;
    } else if (code == 1) {
      break;  // end of block
    } else if (code == 0) {
      int level = int(gb.get(coef_nb_bits));
      offset += int(gb.get(frame_len_bits));
      int sign = int(gb.get1()) - 1;
      ptr[unsigned(offset) & mask] = float((level ^ sign) - sign);
    } else {
      return -1;
    }
  }
  return offset > num_coefs ? -1 : 0;
}

// Full IMDCT of block_len coefficients into output[0 .. 2*block_len), equal
// to FFmpeg's av_tx full IMDCT with scale 1/32768 (whose sign is folded in
// below). DCT-IV u gives y[n] = u[n+N/2], -u[3N/2-1-n], -u[n-3N/2] over the
// three ranges of n.
void Decoder::imdct(int bsize, const float* in) {
  const int n = block_len, h = n / 2;
  vDSP_DCT_Execute(dct[bsize], in, dct_out);
  const float* u = dct_out;
  for (int i = 0; i < h; i++) output[i] = -u[i + h];
  for (int i = h; i < n + h; i++) output[i] = u[n + h - 1 - i];
  for (int i = n + h; i < 2 * n; i++) output[i] = u[i - n - h];
}

void Decoder::window(float* out) {
  const float* in = output;
  if (block_len_bits <= prev_block_len_bits) {
    const float* w = windows[frame_len_bits - block_len_bits].data();
    for (int i = 0; i < block_len; i++) out[i] = in[i] * w[i] + out[i];
  } else {
    int bl = 1 << prev_block_len_bits;
    int n = (block_len - bl) / 2;
    const float* w = windows[frame_len_bits - prev_block_len_bits].data();
    for (int i = 0; i < bl; i++) out[n + i] = in[n + i] * w[i] + out[n + i];
    std::memcpy(out + n + bl, in + n + bl, size_t(n) * sizeof(float));
  }
  out += block_len;
  in += block_len;
  if (block_len_bits <= next_block_len_bits) {
    const float* w = windows[frame_len_bits - block_len_bits].data();
    for (int i = 0; i < block_len; i++) out[i] = in[i] * w[block_len - 1 - i];
  } else {
    int bl = 1 << next_block_len_bits;
    int n = (block_len - bl) / 2;
    const float* w = windows[frame_len_bits - next_block_len_bits].data();
    std::memcpy(out, in, size_t(n) * sizeof(float));
    for (int i = 0; i < bl; i++) out[n + i] = in[n + i] * w[bl - 1 - i];
    std::memset(out + n + bl, 0, size_t(n) * sizeof(float));
  }
}

// Returns 1 when the frame is complete, 0 for more blocks, -1 on error.
int Decoder::decode_block() {
  if (use_variable_block_len) {
    int n = log2_floor(unsigned(nb_block_sizes - 1)) + 1;
    if (reset_block_lengths) {
      reset_block_lengths = false;
      int v = int(gb.get(n));
      if (v >= nb_block_sizes) return -1;
      prev_block_len_bits = frame_len_bits - v;
      v = int(gb.get(n));
      if (v >= nb_block_sizes) return -1;
      block_len_bits = frame_len_bits - v;
    } else {
      prev_block_len_bits = block_len_bits;
      block_len_bits = next_block_len_bits;
    }
    int v = int(gb.get(n));
    if (v >= nb_block_sizes) return -1;
    next_block_len_bits = frame_len_bits - v;
  } else {
    next_block_len_bits = prev_block_len_bits = block_len_bits = frame_len_bits;
  }
  if (frame_len_bits - block_len_bits >= nb_block_sizes) return -1;
  block_len = 1 << block_len_bits;
  if (block_pos + block_len > frame_len) return -1;

  if (channels == 2) ms_stereo = gb.get1();
  bool any = false;
  for (int ch = 0; ch < channels; ch++) {
    channel_coded[ch] = gb.get1();
    any |= channel_coded[ch];
  }
  const int bsize = frame_len_bits - block_len_bits;

  if (any) {
    int total_gain = 1;
    for (;;) {
      if (gb.left() < 7) return -1;
      int a = int(gb.get(7));
      total_gain += a;
      if (a != 127) break;
    }
    const int coef_nb_bits = total_gain < 15 ? 13 : total_gain < 32 ? 12 : total_gain < 40 ? 11
                             : total_gain < 45 ? 10 : 9;
    int nb_coefs[kMaxChannels];
    for (int ch = 0; ch < channels; ch++) nb_coefs[ch] = coefs_end[bsize];

    const int n_high = exponent_high_sizes[bsize];
    if (use_noise_coding) {
      for (int ch = 0; ch < channels; ch++) {
        if (!channel_coded[ch]) continue;
        for (int i = 0; i < n_high; i++) {
          int a = int(gb.get1());
          high_band_coded[ch][i] = a;
          if (a) nb_coefs[ch] -= exponent_high_bands[bsize][i];
        }
      }
      for (int ch = 0; ch < channels; ch++) {
        if (!channel_coded[ch]) continue;
        int val = INT32_MIN;
        for (int i = 0; i < n_high; i++) {
          if (!high_band_coded[ch][i]) continue;
          if (val == INT32_MIN) {
            val = int(gb.get(7)) - 19;
          } else {
            int d = hgain_vlc.decode(gb);
            if (d == INT32_MIN) return -1;
            val += d;
          }
          high_band_values[ch][i] = val;
        }
      }
    }

    if (block_len_bits == frame_len_bits || gb.get1()) {
      for (int ch = 0; ch < channels; ch++) {
        if (!channel_coded[ch]) continue;
        if (use_exp_vlc) {
          if (decode_exp_vlc(ch) < 0) return -1;
        } else {
          decode_exp_lsp(ch);
        }
        exponents_bsize[ch] = bsize;
        exponents_initialized[ch] = true;
      }
    }
    for (int ch = 0; ch < channels; ch++)
      if (channel_coded[ch] && !exponents_initialized[ch]) return -1;

    for (int ch = 0; ch < channels; ch++) {
      if (!channel_coded[ch]) continue;
      // Mid/side streams code the side channel with the second table.
      int tindex = (ch == 1 && ms_stereo);
      std::memset(coefs1[ch], 0, size_t(block_len) * sizeof(float));
      if (run_level_decode(coef[tindex], coefs1[ch], nb_coefs[ch], coef_nb_bits) < 0) return -1;
    }

    // 1/32768 is FFmpeg's IMDCT scale, folded in here (exact: a power of 2).
    const float mdct_norm = 1.0f / float(block_len / 2) * (1.0f / 32768.0f);
    for (int ch = 0; ch < channels; ch++) {
      if (!channel_coded[ch]) continue;
      const float* c1 = coefs1[ch];
      const float* exps = exponents[ch];
      const int esize = exponents_bsize[ch];
      float mult = float(exp10_ff(total_gain * 0.05) / max_exponent[ch]);
      mult *= mdct_norm;
      float* out = coefs[ch];
      if (use_noise_coding) {
        float exp_power[kHighBandMax];
        int last_high_band = 0;
        const float* e = exps + (high_band_start[bsize] << bsize >> esize);
        for (int j = 0; j < n_high; j++) {
          int n = exponent_high_bands[bsize][j];
          if (high_band_coded[ch][j]) {
            float e2 = 0;
            for (int i = 0; i < n; i++) {
              float v = e[i << bsize >> esize];
              e2 += v * v;
            }
            exp_power[j] = e2 / n;
            last_high_band = j;
          }
          e += n << bsize >> esize;
        }
        e = exps;
        for (int j = -1; j < n_high; j++) {
          int n = j < 0 ? high_band_start[bsize] : exponent_high_bands[bsize][j];
          if (j >= 0 && high_band_coded[ch][j]) {
            float mult1 = float(std::sqrt(exp_power[j] / exp_power[last_high_band]));
            mult1 = float(mult1 * exp10_ff(high_band_values[ch][j] * 0.05));
            mult1 = mult1 / (max_exponent[ch] * noise_mult);
            mult1 *= mdct_norm;
            for (int i = 0; i < n; i++) {
              float noise = noise_table[noise_index];
              noise_index = (noise_index + 1) & (kNoiseTabSize - 1);
              *out++ = noise * e[i << bsize >> esize] * mult1;
            }
          } else {
            for (int i = 0; i < n; i++) {
              float noise = noise_table[noise_index];
              noise_index = (noise_index + 1) & (kNoiseTabSize - 1);
              *out++ = ((*c1++) + noise) * e[i << bsize >> esize] * mult;
            }
          }
          e += n << bsize >> esize;
        }
        int n = block_len - coefs_end[bsize];
        float mult1 = mult * e[(-(1 << bsize)) >> esize];
        for (int i = 0; i < n; i++) {
          *out++ = noise_table[noise_index] * mult1;
          noise_index = (noise_index + 1) & (kNoiseTabSize - 1);
        }
      } else {
        const int n = nb_coefs[ch];
        if (bsize == esize) {
          for (int i = 0; i < n; i++) out[i] = c1[i] * exps[i] * mult;
        } else {
          for (int i = 0; i < n; i++) out[i] = c1[i] * exps[i << bsize >> esize] * mult;
        }
        std::memset(out + n, 0, size_t(block_len - n) * sizeof(float));
      }
    }

    if (ms_stereo && channel_coded[1]) {
      if (!channel_coded[0]) {
        std::memset(coefs[0], 0, size_t(block_len) * sizeof(float));
        channel_coded[0] = true;
      }
      float* a = coefs[0];
      float* b = coefs[1];
      for (int i = 0; i < block_len; i++) {
        float t = a[i] - b[i];
        a[i] += b[i];
        b[i] = t;
      }
    }
  }

  for (int ch = 0; ch < channels; ch++) {
    const int n4 = block_len / 2;
    if (channel_coded[ch]) {
      imdct(bsize, coefs[ch]);
    } else if (!(ms_stereo && ch == 1)) {
      std::memset(output, 0, sizeof(output));
    }
    window(&frame_out[ch][(frame_len / 2) + block_pos - n4]);
  }

  block_pos += block_len;
  return block_pos >= frame_len ? 1 : 0;
}

int Decoder::decode_frame(float* const* out, int offset) {
  block_pos = 0;
  for (;;) {
    int r = decode_block();
    if (r < 0) return -1;
    if (r) break;
  }
  for (int ch = 0; ch < channels; ch++) {
    std::memcpy(out[ch] + offset, frame_out[ch], size_t(frame_len) * sizeof(float));
    std::memmove(&frame_out[ch][0], &frame_out[ch][frame_len], size_t(frame_len) * sizeof(float));
  }
  return 0;
}

int Decoder::decode_superframe(const uint8_t* data, int size, float* const* out, int capacity) {
  if (size < block_align) return -1;
  const int buf_size = block_align;
  std::memcpy(packet, data, size_t(buf_size));
  std::memset(packet + buf_size, 0, kPadding);
  gb.init(packet, buf_size * 8);

  int nb_frames = 1;
  if (use_bit_reservoir) {
    gb.skip(4);  // superframe index
    nb_frames = int(gb.get(4)) - (last_superframe_len <= 0);
    if (nb_frames <= 0) {
      if (nb_frames < 0 || gb.left() <= 8) return -1;
      // The whole payload continues the previous superframe.
      if (last_superframe_len + buf_size - 1 > kMaxSuperframe) {
        last_superframe_len = 0;
        return -1;
      }
      std::memcpy(last_superframe + last_superframe_len, packet + 1, size_t(buf_size - 1));
      std::memset(last_superframe + last_superframe_len + buf_size - 1, 0, kPadding);
      // Bytes elsewhere, bits here: kept as FFmpeg has it so streams that
      // depend on it decode identically.
      last_superframe_len += 8 * buf_size - 8;
      return 0;
    }
  }
  if (nb_frames * frame_len > capacity) return -1;

  int offset = 0;
  if (!use_bit_reservoir) {
    if (decode_frame(out, 0) < 0) {
      last_superframe_len = 0;
      return -1;
    }
    return frame_len;
  }

  auto fail = [&] {
    last_superframe_len = 0;
    return -1;
  };
  const int header_bits = 4 + 4 + byte_offset_bits + 3;
  int bit_offset = int(gb.get(byte_offset_bits + 3));
  if (bit_offset > gb.left()) return fail();
  if (last_superframe_len > 0) {
    if (last_superframe_len + ((bit_offset + 7) >> 3) > kMaxSuperframe) return fail();
    uint8_t* q = last_superframe + last_superframe_len;
    int len = bit_offset;
    while (len > 7) {
      *q++ = uint8_t(gb.get(8));
      len -= 8;
    }
    if (len > 0) *q++ = uint8_t(gb.get(len) << (8 - len));
    std::memset(q, 0, kPadding);
    gb.init(last_superframe, last_superframe_len * 8 + bit_offset);
    if (last_bitoffset > 0) gb.skip(uint32_t(last_bitoffset));
    // This frame straddles the previous payload and this one.
    if (decode_frame(out, offset) < 0) return fail();
    offset += frame_len;
    nb_frames--;
  }

  int pos = bit_offset + header_bits;
  if (pos >= kMaxSuperframe * 8 || pos > buf_size * 8) return -1;
  gb.init(packet + (pos >> 3), (buf_size - (pos >> 3)) * 8);
  if (pos & 7) gb.skip(uint32_t(pos & 7));
  reset_block_lengths = true;
  for (int i = 0; i < nb_frames; i++) {
    if (decode_frame(out, offset) < 0) return fail();
    offset += frame_len;
  }

  pos = int(gb.pos) + ((bit_offset + header_bits) & ~7);
  last_bitoffset = pos & 7;
  pos >>= 3;
  int len = buf_size - pos;
  if (len > kMaxSuperframe || len < 0) return fail();
  last_superframe_len = len;
  std::memcpy(last_superframe, packet + pos, size_t(len));
  return offset;
}

}  // namespace wam::wmcodecs

using wam::wmcodecs::Decoder;

struct wam_wma_decoder {
  Decoder d;
};

extern "C" {

wam_wma_decoder* wam_wma_create(const wam_wma_config* config) {
  if (!config) return nullptr;
  std::unique_ptr<wam_wma_decoder> dec(new (std::nothrow) wam_wma_decoder());
  if (!dec || !dec->d.init(*config)) return nullptr;
  return dec.release();
}

void wam_wma_destroy(wam_wma_decoder* decoder) { delete decoder; }

int wam_wma_frame_length(const wam_wma_decoder* decoder) { return decoder->d.frame_len; }

int wam_wma_max_samples(const wam_wma_decoder* decoder) {
  return decoder->d.frame_len * (decoder->d.use_bit_reservoir ? 16 : 1);
}

int wam_wma_decode(wam_wma_decoder* decoder, const uint8_t* data, int size, float* const* out,
                   int capacity) {
  if (!decoder || !data || !out) return -1;
  decoder->d.eof_done = false;
  int n = decoder->d.decode_superframe(data, size, out, capacity);
  return n > 0 ? decoder->d.trim(out, n) : n;
}

int wam_wma_drain(wam_wma_decoder* decoder, float* const* out, int capacity) {
  Decoder& d = decoder->d;
  if (d.eof_done || capacity < d.frame_len) return 0;
  for (int ch = 0; ch < d.channels; ch++)
    std::memcpy(out[ch], d.frame_out[ch], size_t(d.frame_len) * sizeof(float));
  d.last_superframe_len = 0;
  d.eof_done = true;
  return d.trim(out, d.frame_len);
}

void wam_wma_flush(wam_wma_decoder* decoder) {
  decoder->d.last_bitoffset = 0;
  decoder->d.last_superframe_len = 0;
  decoder->d.eof_done = false;
  decoder->d.skip = 2 * decoder->d.frame_len;
}

}  // extern "C"
