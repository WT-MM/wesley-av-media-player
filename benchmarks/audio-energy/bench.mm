#import <Foundation/Foundation.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <WAMKit/WAMKitEncoding.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <libproc.h>
#include <pthread.h>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <unistd.h>
#include <vector>
using Clock = std::chrono::steady_clock;
static void check(wam_status_t status, const wam_error_t &error) {
  if (status != WAM_OK) {
    fprintf(stderr, "%s: %s\n", error.name, error.detail);
    exit(2);
  }
}
static rusage_info_v6 usage() {
  rusage_info_v6 r{};
  if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r))
    exit(3);
  return r;
}
static double cpu() {
  rusage r{};
  getrusage(RUSAGE_SELF, &r);
  return r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6 + r.ru_stime.tv_sec +
         r.ru_stime.tv_usec / 1e6;
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 5) {
      fprintf(stderr,
              "usage: bench scheme seconds realtime|fast output-directory\n");
      return 2;
    }
    std::string scheme = argv[1];
    double seconds = std::stod(argv[2]);
    bool realtime = std::string(argv[3]) == "realtime";
    if (seconds <= 0 || seconds > 21600)
      return 2;
    unsigned codec = 0, bitrate = 0;
    if (scheme == "float32")
      codec = WAM_AUDIO_FLOAT32;
    else if (scheme == "pcm16")
      codec = WAM_AUDIO_PCM16;
    else if (scheme == "alac")
      codec = WAM_AUDIO_ALAC;
    else if (scheme == "aac64") {
      codec = WAM_AUDIO_AAC;
      bitrate = 64000;
    } else if (scheme == "aac96") {
      codec = WAM_AUDIO_AAC;
      bitrate = 96000;
    } else if (scheme != "baseline")
      return 2;
    IOPMAssertionID assertion = 0;
    IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep,
                                kIOPMAssertionLevelOn,
                                CFSTR("WAM timed audio benchmark"), &assertion);
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    NSString *dir = [NSString stringWithUTF8String:argv[4]];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil])
      return 2;
    constexpr unsigned rate = 48000, chunk = 4096, sourceFrames = rate * 5;
    std::vector<float> signal[2];
    for (unsigned lane = 0; lane < 2; lane++) {
      unsigned channels = lane + 1;
      signal[lane].resize(sourceFrames * channels);
      uint32_t seed = 1234567 + lane;
      double low[2]{};
      for (unsigned i = 0; i < sourceFrames; i++)
        for (unsigned ch = 0; ch < channels; ch++) {
          seed = 1664525 * seed + 1013904223;
          double noise = double(seed) / 4294967296.0 * 2 - 1;
          low[ch] = 0.94 * low[ch] + 0.06 * noise;
          double t = double(i) / rate;
          double envelope = 0.4 + 0.3 * sin(t * 4.7);
          double voice = (sin(2 * M_PI * (137 + 31 * ch) * t) +
                          0.3 * sin(2 * M_PI * 293 * t)) *
                         0.15;
          signal[lane][i * channels + ch] =
              float(envelope * (voice + low[ch] * 0.3) + noise * 0.003);
        }
    }
    std::vector<float> blocks[2] = {std::vector<float>(chunk),
                                    std::vector<float>(chunk * 2)};
    wam_audio_encoder_t encoder[2]{};
    wam_error_t error{};
    NSMutableArray *paths = [NSMutableArray array];
    auto before = usage();
    double cpuBefore = cpu();
    auto start = Clock::now();
    auto wallStart = std::chrono::system_clock::now();
    if (codec)
      for (unsigned lane = 0; lane < 2; lane++) {
        NSString *path = [dir
            stringByAppendingPathComponent:
                [NSString
                    stringWithFormat:@"%s-%u.%s", scheme.c_str(), lane,
                                     codec <= WAM_AUDIO_ALAC ? "m4a" : "caf"]];
        [paths addObject:path];
        wam_audio_file_config_t c{
            sizeof(c), rate, lane + 1, codec, bitrate * (lane + 1), 0, 0};
        check(wam_audio_encoder_create_file(&c, path.UTF8String, &encoder[lane],
                                            &error),
              error);
      }
    uint64_t frames = uint64_t(seconds * rate);
    double maxWrite = 0;
    uint64_t late = 0;
    uint64_t peak = before.ri_phys_footprint;
    for (uint64_t offset = 0; offset < frames;) {
      unsigned count = unsigned(std::min<uint64_t>(chunk, frames - offset));
      for (unsigned lane = 0; lane < 2; lane++) {
        unsigned channels = lane + 1;
        for (unsigned i = 0; i < count; i++)
          for (unsigned ch = 0; ch < channels; ch++)
            blocks[lane][i * channels + ch] =
                signal[lane][((offset + i) % sourceFrames) * channels + ch];
      }
      auto a = Clock::now();
      if (codec)
        for (unsigned lane = 0; lane < 2; lane++)
          check(wam_audio_encoder_write(encoder[lane], blocks[lane].data(),
                                        count, &error),
                error);
      maxWrite = std::max(
          maxWrite, std::chrono::duration<double>(Clock::now() - a).count());
      offset += count;
      if (offset % (chunk * 100) == 0)
        peak = std::max(peak, usage().ri_phys_footprint);
      if (realtime) {
        auto deadline =
            start + std::chrono::duration_cast<Clock::duration>(
                        std::chrono::duration<double>(double(offset) / rate));
        if (Clock::now() > deadline + std::chrono::milliseconds(10))
          ++late;
        std::this_thread::sleep_until(deadline);
      }
    }
    for (auto e : encoder)
      if (e) {
        check(wam_audio_encoder_finish(e, &error), error);
        wam_audio_encoder_release(e);
      }
    double wall = std::chrono::duration<double>(Clock::now() - start).count(),
           cpuSeconds = cpu() - cpuBefore;
    auto after = usage();
    uint64_t bytes = 0;
    for (NSString *path in paths)
      bytes += [[[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                                 error:nil]
          fileSize];
    NSDictionary *result = @{
      @"scheme" : @(scheme.c_str()),
      @"audio_seconds" : @(seconds),
      @"wall_seconds" : @(wall),
      @"realtime" : @(realtime),
      @"start_unix" : @(
          std::chrono::duration<double>(wallStart.time_since_epoch()).count()),
      @"cpu_seconds" : @(cpuSeconds),
      @"energy_nj" : @(after.ri_energy_nj - before.ri_energy_nj),
      @"energy_mw" : @((after.ri_energy_nj - before.ri_energy_nj) / 1e6 / wall),
      @"cpu_percent_one_core" : @(cpuSeconds / wall * 100),
      @"interrupt_wakeups" :
          @(after.ri_interrupt_wkups - before.ri_interrupt_wkups),
      @"idle_wakeups" : @(after.ri_pkg_idle_wkups - before.ri_pkg_idle_wkups),
      @"peak_sampled_footprint_bytes" :
          @(std::max(peak, after.ri_phys_footprint)),
      @"output_bytes" : @(bytes),
      @"logical_writes" : @(after.ri_logical_writes - before.ri_logical_writes),
      @"max_write_ms" : @(maxWrite * 1000),
      @"deadline_misses_over_10ms" : @(late),
      @"frames_per_lane" : @(frames),
      @"paths" : paths
    };
    NSData *json =
        [NSJSONSerialization dataWithJSONObject:result
                                        options:NSJSONWritingSortedKeys
                                          error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    puts("");
    IOPMAssertionRelease(assertion);
    return 0;
  }
}
