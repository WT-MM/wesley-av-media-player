#include "platform/macos/native_layer_host_view.hpp"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <cstdlib>
#include <iostream>

namespace {
void expect(bool value, const char* message) {
  if (!value) { std::cerr << message << '\n'; std::exit(1); }
}
}
int main() {
  @autoreleasepool {
    std::string error;
    auto binding = wam::macos::NativeLayerHostView::createDetached(480, 270, &error);
    expect(bool(binding) && error.empty(), "a host view can be created without a Qt window");
    NSView* view = (__bridge NSView*)binding->view();
    expect(view && !view.window && !view.superview, "standalone view does not install itself");
    AVSampleBufferDisplayLayer* display = (__bridge AVSampleBufferDisplayLayer*)binding->displayLayer();
    expect(display.superlayer == view.layer && display != view.layer,
        "rotation container owns the existing display route");
    NSView* first = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270)];
    NSView* second = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 960, 540)];
    [first addSubview:view];
    [view setFrameSize:NSMakeSize(640, 360)];
    expect(wam::macos::setNativeLayerPresentationRotation(binding->displayLayer(), 90),
        "embedding uses the existing rotation capability");
    [second addSubview:view];
    expect(view.superview == second && first.subviews.count == 0,
        "host may reparent the view without replacing its binding");
    expect(wam::macos::nativeLayerPresentationRotation(binding->displayLayer()) == 90,
        "reparenting preserves presentation orientation");
    binding.reset();
    expect(!view.superview, "binding destruction detaches its view");
  }
}
