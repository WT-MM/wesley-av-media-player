// Compares the wam-wmcodecs WMA v2 decoder with FFmpeg's wmav2 decoder on
// the same ASF packets, sample for sample, and times both single-threaded.
//
//   wam_wma2_decoder_test --ffmpeg <ffmpeg> --scratch <dir>   generate + compare
//   wam_wma2_decoder_test <file.wma> [--bench N]               one file

#include "wam_wmcodecs.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

struct Result {
  bool ok = false;
  long long samples_ours = 0;
  long long samples_ffmpeg = 0;
  double max_err = 0;
  double seconds_ours = 0;
  double seconds_ffmpeg = 0;
  double duration = 0;
};

using Clock = std::chrono::steady_clock;

bool read_packets(const char* path, AVCodecParameters** par_out,
                  std::vector<std::vector<uint8_t>>& packets) {
  AVFormatContext* fmt = nullptr;
  if (avformat_open_input(&fmt, path, nullptr, nullptr) < 0) return false;
  if (avformat_find_stream_info(fmt, nullptr) < 0) return false;
  int idx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
  if (idx < 0 || fmt->streams[idx]->codecpar->codec_id != AV_CODEC_ID_WMAV2) {
    avformat_close_input(&fmt);
    return false;
  }
  *par_out = avcodec_parameters_alloc();
  avcodec_parameters_copy(*par_out, fmt->streams[idx]->codecpar);
  AVPacket* pkt = av_packet_alloc();
  while (av_read_frame(fmt, pkt) >= 0) {
    if (pkt->stream_index == idx) packets.emplace_back(pkt->data, pkt->data + pkt->size);
    av_packet_unref(pkt);
  }
  av_packet_free(&pkt);
  avformat_close_input(&fmt);
  return true;
}

// Planar output, one vector per channel.
using Pcm = std::vector<std::vector<float>>;

bool decode_ffmpeg(const AVCodecParameters* par, const std::vector<std::vector<uint8_t>>& packets,
                   Pcm* pcm, double* seconds) {
  const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_WMAV2);
  AVCodecContext* ctx = avcodec_alloc_context3(codec);
  avcodec_parameters_to_context(ctx, par);
  ctx->thread_count = 1;
  if (avcodec_open2(ctx, codec, nullptr) < 0) return false;
  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  int channels = ctx->ch_layout.nb_channels;
  if (pcm) pcm->assign(size_t(channels), {});
  auto receive = [&] {
    while (avcodec_receive_frame(ctx, frame) >= 0) {
      if (pcm)
        for (int ch = 0; ch < channels; ch++) {
          const float* p = reinterpret_cast<const float*>(frame->extended_data[ch]);
          (*pcm)[size_t(ch)].insert((*pcm)[size_t(ch)].end(), p, p + frame->nb_samples);
        }
      av_frame_unref(frame);
    }
  };
  auto t0 = Clock::now();
  for (const auto& p : packets) {
    av_new_packet(pkt, int(p.size()));
    std::copy(p.begin(), p.end(), pkt->data);
    avcodec_send_packet(ctx, pkt);
    av_packet_unref(pkt);
    receive();
  }
  avcodec_send_packet(ctx, nullptr);
  receive();
  *seconds = std::chrono::duration<double>(Clock::now() - t0).count();
  av_frame_free(&frame);
  av_packet_free(&pkt);
  avcodec_free_context(&ctx);
  return true;
}

bool decode_ours(const AVCodecParameters* par, const std::vector<std::vector<uint8_t>>& packets,
                 Pcm* pcm, double* seconds) {
  wam_wma_config cfg{par->ch_layout.nb_channels, par->sample_rate, par->bit_rate,
                     par->block_align, par->extradata, par->extradata_size};
  wam_wma_decoder* dec = wam_wma_create(&cfg);
  if (!dec) return false;
  int cap = wam_wma_max_samples(dec);
  std::vector<std::vector<float>> buf(size_t(cfg.channels), std::vector<float>(size_t(cap)));
  float* out[2] = {buf[0].data(), cfg.channels > 1 ? buf[1].data() : nullptr};
  if (pcm) pcm->assign(size_t(cfg.channels), {});
  auto append = [&](int n) {
    if (pcm && n > 0)
      for (int ch = 0; ch < cfg.channels; ch++)
        (*pcm)[size_t(ch)].insert((*pcm)[size_t(ch)].end(), out[ch], out[ch] + n);
  };
  auto t0 = Clock::now();
  for (const auto& p : packets) append(wam_wma_decode(dec, p.data(), int(p.size()), out, cap));
  append(wam_wma_drain(dec, out, cap));
  *seconds = std::chrono::duration<double>(Clock::now() - t0).count();
  wam_wma_destroy(dec);
  return true;
}

Result run(const char* path, int bench_runs) {
  Result r;
  AVCodecParameters* par = nullptr;
  std::vector<std::vector<uint8_t>> packets;
  if (!read_packets(path, &par, packets)) return r;
  Pcm ours, ref;
  double t;
  if (!decode_ffmpeg(par, packets, &ref, &t) || !decode_ours(par, packets, &ours, &t)) return r;
  r.samples_ffmpeg = (long long)ref[0].size();
  r.samples_ours = (long long)ours[0].size();
  r.duration = double(r.samples_ffmpeg) / par->sample_rate;
  if (const char* lags = std::getenv("WMA_LAG")) {
    for (int lag = 0; lag <= 8192; lag += 1024) {
      double e = 0;
      for (size_t i = 0; i + size_t(lag) < ours[0].size() && i < ref[0].size(); i++)
        e = std::max(e, double(std::fabs(ref[0][i] - ours[0][i + size_t(lag)])));
      std::printf("lag %d err %g\n", lag, e);
    }
    (void)lags;
  }
  for (size_t ch = 0; ch < ref.size(); ch++) {
    size_t n = std::min(ref[ch].size(), ours[ch].size());
    for (size_t i = 0; i < n; i++)
      r.max_err = std::max(r.max_err, double(std::fabs(ref[ch][i] - ours[ch][i])));
  }
  r.seconds_ours = r.seconds_ffmpeg = 1e30;
  for (int i = 0; i < bench_runs; i++) {
    double a, b;
    decode_ffmpeg(par, packets, nullptr, &a);
    decode_ours(par, packets, nullptr, &b);
    r.seconds_ffmpeg = std::min(r.seconds_ffmpeg, a);
    r.seconds_ours = std::min(r.seconds_ours, b);
  }
  avcodec_parameters_free(&par);
  r.ok = r.samples_ours == r.samples_ffmpeg && r.max_err <= 1e-4;
  return r;
}

void print(const std::string& name, const Result& r, int bench_runs) {
  std::printf("%-28s samples %lld/%lld max_err %.3g", name.c_str(), r.samples_ours,
              r.samples_ffmpeg, r.max_err);
  if (bench_runs > 0)
    std::printf("  ours %.0fx ffmpeg %.0fx realtime", r.duration / r.seconds_ours,
                r.duration / r.seconds_ffmpeg);
  std::printf("  %s\n", r.ok ? "OK" : "FAIL");
}

}  // namespace

int main(int argc, char** argv) {
  std::string ffmpeg, scratch;
  std::vector<std::string> files;
  int bench = 0;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--ffmpeg" && i + 1 < argc) ffmpeg = argv[++i];
    else if (a == "--scratch" && i + 1 < argc) scratch = argv[++i];
    else if (a == "--bench" && i + 1 < argc) bench = std::atoi(argv[++i]);
    else files.push_back(a);
  }
  if (!ffmpeg.empty() && !scratch.empty()) {
    struct Case {
      const char* name;
      const char* source;
      int channels, rate;
      const char* bitrate;
    };
    const Case cases[] = {
        {"sine-mono-44k-64k", "sine=frequency=440:sample_rate=44100", 1, 44100, "64k"},
        {"sine-stereo-44k-128k", "sine=frequency=1000:sample_rate=44100", 2, 44100, "128k"},
        {"noise-stereo-44k-128k", "anoisesrc=color=pink:sample_rate=44100:seed=7", 2, 44100, "128k"},
        {"noise-stereo-44k-32k", "anoisesrc=color=white:sample_rate=44100:seed=3", 2, 44100, "32k"},
        {"noise-stereo-44k-192k", "anoisesrc=color=brown:sample_rate=44100:seed=5", 2, 44100, "192k"},
        {"noise-mono-22k-32k", "anoisesrc=color=pink:sample_rate=22050:seed=9", 1, 22050, "32k"},
        {"sine-stereo-22k-64k", "sine=frequency=300:sample_rate=22050", 2, 22050, "64k"},
        {"noise-stereo-48k-128k", "anoisesrc=color=pink:sample_rate=48000:seed=11", 2, 48000, "128k"},
        {"chirp-stereo-48k-96k", "aevalsrc=sin(2*PI*(200+2000*t)*t)|0.5*sin(2*PI*700*t):s=48000", 2, 48000, "96k"},
    };
    int failures = 0;
    for (const Case& c : cases) {
      std::string out = scratch + "/" + c.name + ".wma";
      std::string cmd = "\"" + ffmpeg + "\" -nostdin -hide_banner -loglevel error -y -f lavfi -i \"" +
                        c.source + "\" -t 8 -ac " + std::to_string(c.channels) + " -c:a wmav2 -b:a " +
                        c.bitrate + " \"" + out + "\"";
      if (std::system(cmd.c_str()) != 0) {
        std::printf("%s: ffmpeg failed\n", c.name);
        failures++;
        continue;
      }
      Result r = run(out.c_str(), bench);
      print(c.name, r, bench);
      failures += !r.ok;
    }
    return failures ? 1 : 0;
  }
  int failures = 0;
  for (const auto& f : files) {
    Result r = run(f.c_str(), bench);
    print("file", r, bench);
    failures += !r.ok;
  }
  return failures ? 1 : 0;
}
