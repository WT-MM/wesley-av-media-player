#include "media/native_display_geometry.hpp"
#include "media/native_playback_contract.hpp"
#include "platform/macos/native_layer_host_view.hpp"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include <cassert>
#include <cstdio>

int main() {
  @autoreleasepool {
    using namespace wam::media;
    MediaVideoFormat video;
    video.codedWidth = video.displayWidth = 1920;
    video.codedHeight = video.displayHeight = 1080;
    video.pixelAspectNumerator = 5127;
    video.pixelAspectDenominator = 4912;
    const MediaDisplaySize expected{{615240,307},{1080,1}};
    assert(mediaVideoDisplaySize(video) == expected);
    assert((displayAspect(expected) == MediaRational{1709,921}));
    MediaSourceDescriptor source;
    MediaTrackDescriptor track;
    track.id = 1; track.kind = MediaTrackKind::Video; track.video = video;
    source.tracks.push_back(track); source.selectedVideo = 1;
    assert(mediaSourceDisplaySize(source) == expected);
    native_playback::PreparedDescriptor prepared{10, false, true, expected.width, expected.height};
    assert((MediaDisplaySize{prepared.displayWidth, prepared.displayHeight} == expected));
    CALayer* container = [CALayer layer];
    container.bounds = CGRectMake(0,0,480,270);
    container.contentsScale = 2;
    AVSampleBufferDisplayLayer* layer = [AVSampleBufferDisplayLayer layer];
    [container addSublayer:layer];
    assert(wam::macos::setNativeLayerPresentationDisplaySize((__bridge void*)layer, expected));
    assert(wam::macos::nativeLayerPresentationDisplaySize((__bridge void*)layer) == expected);
    // CALayer and Qt fit use this same exact rectangle, then independently
    // quantize once at their physical-pixel output boundary.
    const auto fit = displayFit(expected, 960, 540);
    assert((fit == MediaDisplaySize{{960,1},{884160,1709}}));
    assert(displayPhysicalPixels(fit.height) == 517);
    assert(layer.bounds.size.width == 480 && layer.bounds.size.height == 258.5);
    assert(layer.position.y == 134.75);
    assert(layer.contentsScale == 2);
    assert([layer.videoGravity isEqualToString:AVLayerVideoGravityResize]);
    assert(displayPhysicalPixels(expected.width) == 2004);
    assert(displayPhysicalPixels(expected.height) == 1080);
    for (const int rotation : {90, 270, -90}) {
      video.rotationDegrees = rotation;
      const auto rotated = mediaVideoDisplaySize(video);
      assert((rotated == MediaDisplaySize{{1080,1},{615240,307}}));
      assert((displayAspect(rotated) == MediaRational{921,1709}));
      assert(wam::macos::setNativeLayerPresentationRotation((__bridge void*)layer, rotation));
      assert(wam::macos::setNativeLayerPresentationDisplaySize((__bridge void*)layer, rotated));
      assert(wam::macos::nativeLayerPresentationDisplaySize((__bridge void*)layer) == rotated);
    }
    assert((MediaDisplaySize{{-1,1},{1080,1}}.empty()));
    std::puts("exact display=615240/307 x 1080 aspect=1709/921; fit=960 x 884160/1709; physical fit=960x517 actual=2004x1080");
  }
}
