#import <AVFoundation/AVFoundation.h>
#include <array>
#include <cstdio>

// Independent AVAssetReader PCM oracle, on Apple's edited output timeline.
// The production proof reads only compressed metadata; it never calls this.
int main(int argc, char** argv) {
  if (argc != 3) return 2;
  @autoreleasepool {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:
        [NSURL fileURLWithPath:@(argv[1])] options:nil];
    AVAssetTrack* track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
#pragma clang diagnostic pop
    if (!track) return 1;
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetReaderTrackOutput* output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track outputSettings:@{
          AVFormatIDKey:@(kAudioFormatLinearPCM), AVLinearPCMIsFloatKey:@YES,
          AVLinearPCMBitDepthKey:@32, AVLinearPCMIsNonInterleaved:@NO}];
    if (!reader || ![reader canAddOutput:output]) return 1;
    [reader addOutput:output];
    if (![reader startReading]) return 1;
    FILE* file = std::fopen(argv[2],"wb");
    if (!file) return 1;
    std::array<std::byte,65536> bytes;
    std::int64_t frames = 0;
    bool valid = true;
    while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
      const auto pts = CMSampleBufferGetOutputPresentationTimeStamp(sample);
      const auto count = CMSampleBufferGetNumSamples(sample);
      const auto format = CMAudioFormatDescriptionGetStreamBasicDescription(
          CMSampleBufferGetFormatDescription(sample));
      const auto block = CMSampleBufferGetDataBuffer(sample);
      const auto size = block ? CMBlockBufferGetDataLength(block) : 0;
      valid = format && format->mSampleRate == 48000 &&
          format->mChannelsPerFrame == 2 && count > 0 &&
          CMTimeCompare(pts,CMTimeMake(frames,48000))==0 &&
          size==std::size_t(count)*8;
      for (std::size_t offset=0;valid && offset<size;) {
        const auto n = std::min(bytes.size(),size-offset);
        valid = CMBlockBufferCopyDataBytes(block,offset,n,bytes.data())==noErr &&
            std::fwrite(bytes.data(),1,n,file)==n;
        offset += n;
      }
      frames += count;
      CFRelease(sample);
      if (!valid) break;
    }
    std::fclose(file);
    valid = valid && frames > 0 && reader.status==AVAssetReaderStatusCompleted;
    std::fprintf(stderr,"oracle_frames=%lld first=0 exact=%d error=%s\n",
        frames,valid,[[reader.error description] UTF8String]);
    [reader cancelReading];
    return valid ? 0 : 1;
  }
}
