#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <array>
#include <cstdio>
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>

// Offline Apple decoder evidence uses fixed slabs and reports process-local
// CPU/energy only; framework helper costs are outside this measurement.
int main(int argc, const char **argv) {
  if (argc != 3)
    return 2;
  @autoreleasepool {
    NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
    ExtAudioFileRef file = nullptr;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &file);
    if (status != noErr) {
      std::fprintf(stderr, "open=%d\n", status);
      return 1;
    }
    AudioStreamBasicDescription native{};
    UInt32 size = sizeof(native);
    status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat,
                                     &size, &native);
    if (status != noErr || native.mChannelsPerFrame == 0 ||
        native.mChannelsPerFrame > 8) {
      ExtAudioFileDispose(file);
      return 1;
    }
    SInt64 declared = 0;
    size = sizeof(declared);
    ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size,
                            &declared);
    AudioStreamBasicDescription client{};
    client.mSampleRate = native.mSampleRate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    client.mChannelsPerFrame = native.mChannelsPerFrame;
    client.mBitsPerChannel = 32;
    client.mFramesPerPacket = 1;
    client.mBytesPerFrame = client.mBytesPerPacket =
        4 * client.mChannelsPerFrame;
    status = ExtAudioFileSetProperty(
        file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
    FILE *output = std::fopen(argv[2], "wb");
    if (status != noErr || !output) {
      ExtAudioFileDispose(file);
      if (output)
        std::fclose(output);
      return 1;
    }
    std::array<float, 4096 * 8> slab{};
    std::uint64_t produced = 0;
    rusage before{}, after{};
    rusage_info_v6 eb{}, ea{};
    getrusage(RUSAGE_SELF, &before);
    int energyBefore =
        proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&eb);
    for (std::size_t reads = 0; reads < 1000000; ++reads) {
      AudioBufferList buffers{};
      buffers.mNumberBuffers = 1;
      buffers.mBuffers[0] = {client.mChannelsPerFrame,
                             4096 * client.mBytesPerFrame, slab.data()};
      UInt32 frames = 4096;
      status = ExtAudioFileRead(file, &frames, &buffers);
      if (status != noErr || frames == 0)
        break;
      if (std::fwrite(slab.data(), client.mBytesPerFrame, frames, output) !=
          frames) {
        status = -1;
        break;
      }
      produced += frames;
    }
    getrusage(RUSAGE_SELF, &after);
    int energyAfter =
        proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ea);
    auto us = [](timeval t) {
      return static_cast<long long>(t.tv_sec) * 1000000 + t.tv_usec;
    };
    std::fprintf(stderr,
                 "format=%08x rate=%.0f channels=%u declared=%lld frames=%llu "
                 "error=%d cpu_us=%lld energy_status=%d/%d energy_nj=%llu\n",
                 native.mFormatID, native.mSampleRate, native.mChannelsPerFrame,
                 declared, produced, status,
                 us(after.ru_utime) + us(after.ru_stime) - us(before.ru_utime) -
                     us(before.ru_stime),
                 energyBefore, energyAfter, ea.ri_energy_nj - eb.ri_energy_nj);
    std::fclose(output);
    ExtAudioFileDispose(file);
    return status == noErr && produced > 0 ? 0 : 1;
  }
}
