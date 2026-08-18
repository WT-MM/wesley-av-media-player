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
    // The host view must become Qt's SIBLING, never its child: a subview always
    // composites above its superview's own content, so parenting the display
    // layer under Qt's view puts the video over every pixel Qt draws -- the
    // chrome disappears while the AppKit traffic lights, which live outside the
    // content view entirely, survive.
    //
    // On Qt 6 the QNSView *is* the window's content view (verified at runtime:
    // the handle behind QWindow::winId() compares equal to window.contentView),
    // so the common parent is the window's frame view and the DESIGN.md S1
    // sandwich is:
    //
    //   frameView
    //   |__ hostView                (AVSampleBufferDisplayLayer)      BELOW
    //   |__ QNSView == contentView  (Qt Quick, transparent)           ABOVE
    //   |__ NSTitlebarContainerView (traffic lights)                  ABOVE
    //
    // Walking up from Qt's view to whichever ancestor is a direct child of the
    // content view keeps the older arrangement (Qt hosted inside the content
    // view) working unchanged; the loop simply stops one level higher when Qt
    // owns the content view itself.
    NSView* sibling = qtView;
    while (sibling != contentView && sibling.superview != nil &&
           sibling.superview != contentView) {
      sibling = sibling.superview;
    }
    NSView* siblingParent = sibling.superview;
    if (siblingParent == nil) {
      assignError(error,
                  "layer host view found no view to install the layer beneath");
      return {};
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

    // sibling.frame is already in siblingParent's coordinates, so this covers
    // exactly the area Qt covers whichever level the insertion landed on.
    NSView* hostView = [[NSView alloc] initWithFrame:sibling.frame];
    // Layer-HOSTED, not layer-backed: the layer must be assigned before
    // wantsLayer, or AppKit creates its own backing layer and ignores this one.
    hostView.layer = layer;
    hostView.wantsLayer = YES;
    hostView.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    hostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [siblingParent addSubview:hostView
                   positioned:NSWindowBelow
                   relativeTo:sibling];

    // The whole route depends on this one ordering fact, and AppKit is free to
    // decline a requested position (NSThemeFrame manages its own children), so
    // it is asserted rather than assumed. Failing here falls back to the GL
    // route, which is correct-but-slower -- strictly better than shipping a
    // window whose chrome is invisible.
    const NSUInteger hostIndex = [siblingParent.subviews indexOfObject:hostView];
    const NSUInteger qtIndex = [siblingParent.subviews indexOfObject:sibling];
    if (hostIndex == NSNotFound || qtIndex == NSNotFound ||
        hostIndex >= qtIndex) {
      [hostView removeFromSuperview];
      assignError(error,
                  "layer host view could not be ordered beneath Qt's view");
      return {};
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
