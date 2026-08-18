#include "native_layer_host_view.hpp"

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <utility>

namespace wam::macos {
namespace {

void assignError(std::string* error, const char* message) noexcept {
  if (error == nullptr || message == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
  }
}

}  // namespace

struct NativeLayerHostView::Impl {
  NSView* hostView{nil};
  AVSampleBufferDisplayLayer* layer{nil};
};

NativeLayerHostView::NativeLayerHostView(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

NativeLayerHostView::~NativeLayerHostView() { detach(); }

std::shared_ptr<NativeLayerHostView> NativeLayerHostView::create(
    void* qtViewHandle, std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  if (qtViewHandle == nullptr) {
    assignError(error, "layer host view requires a Qt view handle");
    return {};
  }
  if (![NSThread isMainThread]) {
    assignError(error, "layer host view must be installed on the main thread");
    return {};
  }
  @autoreleasepool {
    id candidate = (__bridge id)qtViewHandle;
    if (![candidate isKindOfClass:[NSView class]]) {
      assignError(error, "layer host view handle is not an NSView");
      return {};
    }
    NSView* qtView = static_cast<NSView*>(candidate);
    NSWindow* window = qtView.window;
    if (window == nil) {
      assignError(error, "layer host view requires a realized NSWindow");
      return {};
    }
    NSView* contentView = window.contentView;
    if (contentView == nil) {
      assignError(error, "layer host view requires a content view");
      return {};
    }
    // Qt's view is normally the content view itself or a direct child of it.
    // The sibling insertion below needs a common parent, so walk up until the
    // view whose superview is the content view.
    NSView* sibling = qtView;
    while (sibling != nil && sibling.superview != contentView &&
           sibling != contentView) {
      sibling = sibling.superview;
    }

    AVSampleBufferDisplayLayer* layer =
        [[AVSampleBufferDisplayLayer alloc] init];
    if (layer == nil) {
      assignError(error, "layer host view could not create a display layer");
      return {};
    }
    // resizeAspect letterboxes inside the layer, which is what keeps the
    // existing window-geometry code (snapToVideoAspectRatio, resizeToActualSize,
    // resizeToFitScreen) correct without any of it knowing the layer exists.
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.backgroundColor = NSColor.blackColor.CGColor;
    // Geometry must follow a live drag-resize exactly, with no implicit
    // animation lagging the window edge.
    layer.actions = @{
      @"bounds" : [NSNull null],
      @"position" : [NSNull null],
      @"contents" : [NSNull null],
      @"sublayers" : [NSNull null],
    };

    NSView* hostView = [[NSView alloc] initWithFrame:contentView.bounds];
    // Layer-HOSTED, not layer-backed: the layer must be assigned before
    // wantsLayer, or AppKit creates its own backing layer and ignores this one.
    hostView.layer = layer;
    hostView.wantsLayer = YES;
    hostView.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    hostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    if (sibling != nil && sibling != contentView) {
      [contentView addSubview:hostView
                   positioned:NSWindowBelow
                   relativeTo:sibling];
    } else {
      // Qt owns the content view itself; the video layer becomes its
      // bottom-most subview, which is the same z-order relationship.
      [contentView addSubview:hostView
                   positioned:NSWindowBelow
                   relativeTo:nil];
    }

    auto impl = std::make_unique<Impl>();
    impl->hostView = hostView;
    impl->layer = layer;
    return std::shared_ptr<NativeLayerHostView>(
        new NativeLayerHostView(std::move(impl)));
  }
}

void* NativeLayerHostView::displayLayer() const noexcept {
  if (impl_ == nullptr) {
    return nullptr;
  }
  return (__bridge void*)impl_->layer;
}

void NativeLayerHostView::detach() noexcept {
  if (impl_ == nullptr) {
    return;
  }
  @autoreleasepool {
    NSView* hostView = impl_->hostView;
    if (hostView != nil) {
      if ([NSThread isMainThread]) {
        [hostView removeFromSuperview];
      } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          [hostView removeFromSuperview];
        });
      }
    }
    impl_->hostView = nil;
    impl_->layer = nil;
  }
}

}  // namespace wam::macos
