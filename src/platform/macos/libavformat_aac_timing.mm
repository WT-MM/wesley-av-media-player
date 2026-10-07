#include "platform/macos/libavformat_aac_timing.hpp"
#import <AVFoundation/AVFoundation.h>
#include <vector>
#include <algorithm>

namespace wam::macos {

// Open-worker-only proof. Do not infer AAC priming from a negative demux PTS:
// CoreMedia may add encoder priming to the container edit (fragmented MOV),
// whereas ordinary MOV already includes it. Empty edits, multiple edits,
// retiming and packet origins not witnessed here keep the named refusal.
std::optional<LibavformatAacTiming> proveLibavformatAacTiming(
    const std::filesystem::path& path, int trackId,
    const media::LibavformatCursor::Packet& packet) {
  @autoreleasepool {
    const auto frame = media::exactAudioFrameIndex(packet.pts,48000);
    if (!frame || (*frame != -64 && *frame != -2112) ||
        packet.skipStart != -*frame || packet.skipEnd ||
        packet.bytes.empty() || packet.bytes.size() > 65536)
      return {};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:
        [NSURL fileURLWithPath:@(path.c_str())] options:nil];
    AVAssetTrack* track = [asset trackWithTrackID:trackId];
    NSArray<AVAssetTrackSegment*>* segments = track.segments;
#pragma clang diagnostic pop
    if (!track || ![track.mediaType isEqualToString:AVMediaTypeAudio] ||
        segments.count != 1 || segments.firstObject.empty)
      return {};
    const auto mapping = segments.firstObject.timeMapping;
    const auto exact = [](CMTime t) {
      return CMTIME_IS_NUMERIC(t) && t.epoch == 0 &&
             !(t.flags & kCMTimeFlags_HasBeenRounded);
    };
    if (!exact(mapping.source.start) || !exact(mapping.target.start) ||
        !exact(mapping.source.duration) || !exact(mapping.target.duration) ||
        CMTimeCompare(mapping.source.start, CMTimeMake(2112,48000)) != 0 ||
        CMTimeCompare(mapping.target.start, kCMTimeZero) != 0 ||
        CMTimeCompare(mapping.source.duration, kCMTimeZero) <= 0 ||
        CMTimeCompare(mapping.source.duration, mapping.target.duration) != 0)
      return {};
    NSError* error = nil;
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    AVAssetReaderTrackOutput* output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track outputSettings:nil];
    if (!reader || ![reader canAddOutput:output]) return {};
    [reader addOutput:output];
    if (![reader startReading]) return {};
    CMSampleBufferRef first = [output copyNextSampleBuffer];
    std::optional<LibavformatAacTiming> result;
    if (first) {
      const auto pts = CMSampleBufferGetPresentationTimeStamp(first);
      const auto trimValue = CMGetAttachment(first,
          kCMSampleBufferAttachmentKey_TrimDurationAtStart, nullptr);
      const auto trim = trimValue && CFGetTypeID(trimValue)==CFDictionaryGetTypeID()
          ? CMTimeMakeFromDictionary(static_cast<CFDictionaryRef>(trimValue))
          : kCMTimeInvalid;
      const auto trimFrames = CMTimeConvertScale(trim,48000,kCMTimeRoundingMethod_Default);
      const auto expectedTrim = *frame == -64 ? 2176 : 2112;
      const auto duration = media::exactAudioFrameIndex(
          {mapping.target.duration.value,mapping.target.duration.timescale},48000);
      // CoreMedia's extra trim beyond the segment's 2112-frame media start
      // shortens its output interval by the same amount (64 for this fMOV).
      const auto extraTrim = expectedTrim - 2112;
      const auto block = CMSampleBufferGetDataBuffer(first);
      const auto size = CMSampleBufferGetSampleSize(first,0);
      std::vector<std::byte> bytes(packet.bytes.size());
      if (exact(pts) && CMTimeCompare(pts,kCMTimeZero)==0 &&
          exact(trimFrames) && trimFrames.value==expectedTrim &&
          duration && *duration > extraTrim &&
          size==bytes.size() && block &&
          CMBlockBufferCopyDataBytes(block,0,size,bytes.data())==noErr &&
          std::equal(bytes.begin(),bytes.end(),packet.bytes.begin())) {
        // A later batch must state the same displacement in output timing;
        // the first batch's output stamp is clamped to zero by its trim.
        CMSampleBufferRef next = [output copyNextSampleBuffer];
        if (next) {
          const auto input = CMSampleBufferGetPresentationTimeStamp(next);
          const auto presented = CMSampleBufferGetOutputPresentationTimeStamp(next);
          if (exact(input) && exact(presented) &&
              CMTimeCompare(CMTimeSubtract(input,presented),trimFrames)==0)
            result = LibavformatAacTiming{{-expectedTrim,48000},{*frame,48000},
                {*duration-extraTrim,48000}};
          CFRelease(next);
        }
      }
      CFRelease(first);
    }
    [reader cancelReading];
    return result;
  }
}
} // namespace wam::macos
