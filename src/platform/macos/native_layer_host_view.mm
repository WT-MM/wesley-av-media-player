#include "native_layer_host_view.hpp"

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include <cmath>
#include <dlfcn.h>
#include <utility>

// The host view exists as a subclass for exactly one reason: something has to
// re-place the video layer inside its container when the window resizes, and a
// layer-hosted view gets no layout callback of its own. Everything else about
// it is a plain NSView.
//
// Declared here rather than with its implementation because an Objective-C
// class cannot be defined inside a C++ namespace; the implementation is at the
// foot of this file, where the layout helper it calls is already in scope.
@interface WAMNativeVideoHostView : NSView
@end

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

// Where a window's presentation rotation lives, by the same reasoning as the
// vivid boost above: it belongs to the video layer, is set once when a track
// is configured, and has to be readable again on every resize without the
// resize path knowing who set it.
const void* videoRotationAssociationKey() {
  static const char key = 0;
  return &key;
}

int videoRotationForLayer(CALayer* layer) noexcept {
  if (layer == nil) {
    return 0;
  }
  id value = objc_getAssociatedObject(layer, videoRotationAssociationKey());
  if (![value isKindOfClass:[NSNumber class]]) {
    return 0;
  }
  const int degrees = [(NSNumber*)value intValue];
  const int normalized = ((degrees % 360) + 360) % 360;
  return (normalized == 90 || normalized == 180 || normalized == 270)
             ? normalized
             : 0;
}

// Place the video layer inside its container for the current rotation.
//
// The rotated case is why the display layer is a SUBLAYER rather than the host
// view's own hosted layer: AppKit drives a hosted layer's frame from the
// view's bounds on every resize, and setting a frame on a transformed layer
// makes CoreAnimation solve for bounds instead -- the transform and the
// autoresize fight, and the picture creeps. With a container in between,
// AppKit manages only the container and this function owns the video layer's
// geometry outright.
//
// For a quarter turn the layer's BOUNDS are transposed and then the whole
// layer is turned about its centre. That order matters: videoGravity does its
// letterboxing inside the bounds, so the bounds must be the rectangle the
// video is being fitted into *in the video's own orientation*. Transposing
// them means a portrait window presents a portrait-shaped fitting rectangle to
// a landscape-coded frame, which is exactly right once the turn is applied.
// Rotating a layer whose bounds were left landscape would letterbox first and
// rotate the letterbox, which is the classic sideways-with-bars result.
void layoutVideoLayer(CALayer* videoLayer) noexcept {
  if (videoLayer == nil) {
    return;
  }
  CALayer* container = videoLayer.superlayer;
  if (container == nil) {
    return;
  }
  const CGRect bounds = container.bounds;
  if (!std::isfinite(bounds.size.width) ||
      !std::isfinite(bounds.size.height)) {
    return;
  }
  const int rotation = videoRotationForLayer(videoLayer);
  const bool quarterTurn = rotation == 90 || rotation == 270;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  videoLayer.bounds =
      quarterTurn
          ? CGRectMake(0.0, 0.0, bounds.size.height, bounds.size.width)
          : CGRectMake(0.0, 0.0, bounds.size.width, bounds.size.height);
  videoLayer.position =
      CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
  // CoreAnimation's rotation is counterclockwise in the layer's y-up geometry;
  // rotationDegrees is clockwise as a viewer sees it, which is the same
  // convention mediaVideoDisplaySize uses when it transposes the rectangle.
  // Hence the negation -- and 0 is written as the exact identity rather than a
  // rotation by zero, so an unrotated layer carries no transform at all.
  videoLayer.affineTransform =
      rotation == 0 ? CGAffineTransformIdentity
                    : CGAffineTransformMakeRotation(
                          -static_cast<CGFloat>(rotation) * M_PI / 180.0);
  [CATransaction commit];
}

// The display layer installed in this window, wherever it landed. Searched for
// rather than handed over, so this stays independent of who owns the
// NativeLayerHostView and works the same whether the layer was installed
// before or after the boost was asked for.
//
// It searches SUBLAYERS as well as each view's own layer: since the rotation
// work the display layer is a sublayer of a plain container, so stopping at
// view.layer would quietly stop finding it -- and the only symptom would have
// been Vivid boost silently doing nothing.
AVSampleBufferDisplayLayer* findDisplayLayerInTree(CALayer* layer) {
  if (layer == nil) {
    return nil;
  }
  if ([layer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
    return static_cast<AVSampleBufferDisplayLayer*>(layer);
  }
  for (CALayer* child in layer.sublayers) {
    if (AVSampleBufferDisplayLayer* found = findDisplayLayerInTree(child)) {
      return found;
    }
  }
  return nil;
}

AVSampleBufferDisplayLayer* findDisplayLayer(NSView* view) {
  if (view == nil) {
    return nil;
  }
  if (AVSampleBufferDisplayLayer* found = findDisplayLayerInTree(view.layer)) {
    return found;
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

bool setNativeLayerPresentationRotation(void* displayLayer,
                                        int degrees) noexcept {
  if (displayLayer == nullptr) {
    return false;
  }
  const int normalized = ((degrees % 360) + 360) % 360;
  if (normalized != 0 && normalized != 90 && normalized != 180 &&
      normalized != 270) {
    return false;
  }
  @autoreleasepool {
    id candidate = (__bridge id)displayLayer;
    if (![candidate isKindOfClass:[CALayer class]]) {
      return false;
    }
    CALayer* layer = static_cast<CALayer*>(candidate);
    objc_setAssociatedObject(layer, videoRotationAssociationKey(),
                             @(normalized), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // This is called from the SESSION WORKER thread -- the consumer settles
    // rotation while configuring a generation, which is nowhere near the GUI
    // thread -- so the CoreAnimation half hops rather than refusing.
    //
    // Refusing off-main was a real defect, not a hypothetical one: it made
    // this function answer "no" for every file including unrotated ones, and
    // since the consumer treats that answer as "this route cannot present
    // this track", every file in the app fell back to the compatibility
    // renderer. The capability answer must not depend on which thread asks.
    //
    // The retained NSNumber above is the source of truth and is already set,
    // so a resize racing this hop reads the new rotation either way.
    if ([NSThread isMainThread]) {
      layoutVideoLayer(layer);
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        layoutVideoLayer(layer);
      });
    }
    return true;
  }
}

int nativeLayerPresentationRotation(void* displayLayer) noexcept {
  if (displayLayer == nullptr) {
    return 0;
  }
  @autoreleasepool {
    id candidate = (__bridge id)displayLayer;
    if (![candidate isKindOfClass:[CALayer class]]) {
      return 0;
    }
    return videoRotationForLayer(static_cast<CALayer*>(candidate));
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
    // The video layer is placed by layoutVideoLayer, never by autoresizing,
    // so it must not also try to follow its container on its own.
    layer.anchorPoint = CGPointMake(0.5, 0.5);
    layer.autoresizingMask = kCALayerNotSizable;
    // Geometry must follow a live drag-resize exactly, with no implicit
    // animation lagging the window edge.
    layer.actions = @{
      @"bounds" : [NSNull null],
      @"position" : [NSNull null],
      @"contents" : [NSNull null],
      @"sublayers" : [NSNull null],
    };

    // A plain container between the view and the video, so that a quarter turn
    // has somewhere to live. AppKit resizes the container (it is the view's
    // hosted layer); layoutVideoLayer places the video inside it. Without the
    // container there is no way to both autoresize with the window and carry a
    // rotation transform -- see layoutVideoLayer.
    CALayer* container = [CALayer layer];
    // The container is what shows through wherever the rotated video does not
    // reach, so it owns the letterbox colour.
    container.backgroundColor = NSColor.blackColor.CGColor;
    container.actions = @{
      @"bounds" : [NSNull null],
      @"position" : [NSNull null],
      @"contents" : [NSNull null],
      @"sublayers" : [NSNull null],
    };
    [container addSublayer:layer];

    // sibling.frame is already in siblingParent's coordinates, so this covers
    // exactly the area Qt covers whichever level the insertion landed on.
    NSView* hostView =
        [[WAMNativeVideoHostView alloc] initWithFrame:sibling.frame];
    // Layer-HOSTED, not layer-backed: the layer must be assigned before
    // wantsLayer, or AppKit creates its own backing layer and ignores this one.
    hostView.layer = container;
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

    // Unrotated until a track says otherwise, but placed now: the container
    // has just been sized and the video layer is still at its default zero
    // bounds, so without this first call nothing would be drawn until the
    // first resize.
    layoutVideoLayer(layer);

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

@implementation WAMNativeVideoHostView

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  wam::macos::layoutVideoLayer(self.layer.sublayers.firstObject);
}

// A live drag-resize and a display/backing-scale change both land here, and a
// window moved between a Retina and a non-Retina display changes the layer's
// backing store without changing the view's frame.
- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  wam::macos::layoutVideoLayer(self.layer.sublayers.firstObject);
}

@end
