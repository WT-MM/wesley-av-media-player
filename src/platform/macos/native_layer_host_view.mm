#include "native_layer_host_view.hpp"

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <cmath>
#include <dlfcn.h>
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

// ------------------------------------------------------------- vivid boost

// Below this the boost is off outright rather than a filter with a near-zero
// exposure: an identity filter still forces the layer down the filtered
// compositing path, which is exactly the cost the mode is supposed to give
// back when it is switched off.
constexpr double kVividBoostOffThreshold = 1.001;

// CALayer.preferredDynamicRange and the CADynamicRange* constants are macOS 26
// SDK declarations; the release builders compile against an older SDK, so both
// are reached dynamically -- dlsym for the exported NSString constants, key-value
// coding for the property -- and simply resolve to nil below macOS 26.
NSString* dynamicRangeConstant(const char* name) noexcept {
  void* symbol = dlsym(RTLD_DEFAULT, name);
  if (symbol == nullptr) {
    return nil;
  }
  return (__bridge NSString*)*static_cast<void**>(symbol);
}

void setLayerPreferredDynamicRange(CALayer* layer,
                                   const char* constantName) noexcept {
  NSString* value = dynamicRangeConstant(constantName);
  if (layer == nil || value == nil ||
      ![layer respondsToSelector:NSSelectorFromString(
                                     @"setPreferredDynamicRange:")]) {
    return;
  }
  [layer setValue:value forKey:@"preferredDynamicRange"];
}

NSString* layerPreferredDynamicRange(CALayer* layer) noexcept {
  if (layer == nil ||
      ![layer
          respondsToSelector:NSSelectorFromString(@"preferredDynamicRange")]) {
    return nil;
  }
  id value = [layer valueForKey:@"preferredDynamicRange"];
  return [value isKindOfClass:[NSString class]] ? (NSString*)value : nil;
}

// Where the per-window desired boost lives. An associated object on the
// NSWindow rather than a table keyed by it: the boost belongs to the window,
// has to outlive any number of display layers built and torn down inside it as
// files are opened, and has to disappear with the window without anyone
// remembering to clear a row.
const void* vividBoostAssociationKey() {
  static const char key = 0;
  return &key;
}

double vividBoostForWindow(NSWindow* window) noexcept {
  if (window == nil) {
    return 1.0;
  }
  id value = objc_getAssociatedObject(window, vividBoostAssociationKey());
  if (![value isKindOfClass:[NSNumber class]]) {
    return 1.0;
  }
  const double boost = [(NSNumber*)value doubleValue];
  return std::isfinite(boost) && boost > 1.0 ? boost : 1.0;
}

// The whole mechanism, in one place.
void applyVividBoostToLayer(CALayer* layer, double boost) noexcept {
  if (layer == nil) {
    return;
  }
  // Deterministic rather than animated. CoreAnimation would otherwise pick an
  // implicit action for the filter change, and the host view's own `actions`
  // dictionary only silences bounds/position/contents/sublayers.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (!(std::isfinite(boost)) || boost < kVividBoostOffThreshold) {
    layer.filters = nil;
    setLayerPreferredDynamicRange(layer, "CADynamicRangeStandard");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (@available(macOS 14.0, *)) {
      layer.wantsExtendedDynamicRangeContent = NO;
    }
#pragma clang diagnostic pop
    [CATransaction commit];
    return;
  }
  CIFilter* exposure = [CIFilter filterWithName:@"CIExposureAdjust"];
  if (exposure != nil) {
    // CIExposureAdjust is a multiply in LINEAR light -- inputEV is a power of
    // two of the luminance -- which is why this is a transfer-function-correct
    // brightness change and not a gamma shift.
    [exposure setValue:@(std::log2(boost)) forKey:@"inputEV"];
    layer.filters = @[ exposure ];
  }
  // Both opt-ins, each behind its own availability check. The macOS 14 one is
  // deprecated as of macOS 26 and the macOS 26 one does not exist below it;
  // measured on macOS 26.3, either alone produces identical output, so setting
  // both is redundancy rather than a dependency on the deprecated property.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (@available(macOS 14.0, *)) {
    layer.wantsExtendedDynamicRangeContent = YES;
  }
#pragma clang diagnostic pop
  setLayerPreferredDynamicRange(layer, "CADynamicRangeHigh");
  [CATransaction commit];
}

// The display layer installed in this window, wherever it landed. Searched for
// rather than handed over, so this stays independent of who owns the
// NativeLayerHostView and works the same whether the layer was installed
// before or after the boost was asked for.
AVSampleBufferDisplayLayer* findDisplayLayer(NSView* view) {
  if (view == nil) {
    return nil;
  }
  if ([view.layer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
    return static_cast<AVSampleBufferDisplayLayer*>(view.layer);
  }
  for (NSView* child in view.subviews) {
    if (AVSampleBufferDisplayLayer* found = findDisplayLayer(child)) {
      return found;
    }
  }
  return nil;
}

}  // namespace

void setNativeLayerVividBoost(void* nsWindow, double boost) noexcept {
  if (nsWindow == nullptr || ![NSThread isMainThread]) {
    return;
  }
  @autoreleasepool {
    id candidate = (__bridge id)nsWindow;
    if (![candidate isKindOfClass:[NSWindow class]]) {
      return;
    }
    NSWindow* window = static_cast<NSWindow*>(candidate);
    const double clean =
        (std::isfinite(boost) && boost > 1.0) ? boost : 1.0;
    objc_setAssociatedObject(window, vividBoostAssociationKey(), @(clean),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The host view is Qt's SIBLING under the frame view, so the search starts
    // one level above the content view where it can see both.
    NSView* contentView = window.contentView;
    NSView* root = contentView.superview != nil ? contentView.superview
                                                : contentView;
    applyVividBoostToLayer(findDisplayLayer(root), clean);
  }
}

double nativeLayerAppliedVividBoost(void* nsWindow) noexcept {
  if (nsWindow == nullptr || ![NSThread isMainThread]) {
    return 0.0;
  }
  @autoreleasepool {
    id candidate = (__bridge id)nsWindow;
    if (![candidate isKindOfClass:[NSWindow class]]) {
      return 0.0;
    }
    NSWindow* window = static_cast<NSWindow*>(candidate);
    NSView* contentView = window.contentView;
    NSView* root =
        contentView.superview != nil ? contentView.superview : contentView;
    CALayer* layer = findDisplayLayer(root);
    if (layer == nil) {
      return 0.0;
    }
    // Both halves have to be true for the mechanism to be engaged: the filter
    // supplies the above-white values and the opt-in is what stops the
    // compositor clamping them back to SDR white. Measured -- with the opt-in
    // off, an extended-range surface reads back clamped at exactly 1.000.
    bool edrRequested = false;
    NSString* preferredRange = layerPreferredDynamicRange(layer);
    NSString* standardRange = dynamicRangeConstant("CADynamicRangeStandard");
    if (preferredRange != nil && standardRange != nil) {
      edrRequested = ![preferredRange isEqualToString:standardRange];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!edrRequested) {
      if (@available(macOS 14.0, *)) {
        edrRequested = layer.wantsExtendedDynamicRangeContent == YES;
      }
    }
#pragma clang diagnostic pop
    if (!edrRequested) {
      return 1.0;
    }
    for (id filter in layer.filters) {
      if (![filter isKindOfClass:[CIFilter class]]) {
        continue;
      }
      id ev = [(CIFilter*)filter valueForKey:@"inputEV"];
      if (![ev isKindOfClass:[NSNumber class]]) {
        continue;
      }
      const double boost = std::pow(2.0, [(NSNumber*)ev doubleValue]);
      return std::isfinite(boost) && boost > 0.0 ? boost : 1.0;
    }
    return 1.0;
  }
}

double nativeLayerVividBoost(void* nsWindow) noexcept {
  if (nsWindow == nullptr) {
    return 1.0;
  }
  @autoreleasepool {
    id candidate = (__bridge id)nsWindow;
    if (![candidate isKindOfClass:[NSWindow class]]) {
      return 1.0;
    }
    return vividBoostForWindow(static_cast<NSWindow*>(candidate));
  }
}

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

    // A new file rebuilds this layer from scratch, so the window's Vivid boost
    // has to be re-applied here or the mode would silently switch itself off
    // on every open while its toggle still read as on.
    applyVividBoostToLayer(layer, vividBoostForWindow(window));

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
