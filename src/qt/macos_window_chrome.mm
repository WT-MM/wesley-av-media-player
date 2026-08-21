#include "macos_window_chrome.hpp"

#include <QPointer>
#include <QUrl>
#include <QWindow>

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <optional>

namespace wam::macos_window_chrome {
namespace {

NSWindow *nsWindowFor(QWindow *window) {
  if (!window)
    return nil;
  // QWindow::winId() forces the platform window to exist and returns it as
  // an opaque handle that is, on macOS, the NSView pointer value itself. It
  // is not a transferred (+1) reference -- Qt keeps the real owning
  // reference -- so this is an unretained __bridge, not __bridge_transfer.
  NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window->winId());
  return view.window;
}

// Robert Penner's easeOutCubic Bezier approximation, matching the
// Easing.OutCubic curve qml/FloatingControls.qml already uses for its own
// opacity Behavior. Using the same curve keeps the native titlebar fade
// reading as one motion with the floating transport.
CAMediaTimingFunction *outCubicTimingFunction() {
  return [CAMediaTimingFunction functionWithControlPoints:0.215:0.61:0.355:1.0];
}

// QuickTime's own zoom/actual-size transitions ease in, then out, rather than
// arriving fast and coasting -- the standard ease-in-ease-out curve, used only
// for the two user-facing zoom paths below (resizeToFitScreen,
// resizeToActualSize). Never applied to applyWindowFrame's instant path,
// which every other caller -- including accessibility/AppleScript resizes the
// benchmark harness depends on -- still goes through unanimated.
CAMediaTimingFunction *easeInEaseOutTimingFunction() {
  return [CAMediaTimingFunction
      functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
}

// QuickTime's own double-click zoom settles in well under a third of a
// second; 240ms sits in the middle of the 200-280ms band that reads as
// smooth without feeling sluggish.
constexpr NSTimeInterval kZoomAnimationDuration = 0.24;

constexpr NSWindowButton kTrafficLightButtons[] = {
    NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};

void setTrafficLightAlpha(NSWindow *nsWindow, CGFloat alpha) {
  for (NSWindowButton type : kTrafficLightButtons) {
    if (NSButton *button = [nsWindow standardWindowButton:type])
      button.alphaValue = alpha;
  }
}

CGFloat titlebarHeightFor(NSWindow *nsWindow) {
  if (!nsWindow)
    return 0;
  // The traffic lights live in the titlebar view, which spans exactly the
  // band: its height is the truth, whatever the current macOS decides that
  // is (32pt on macOS 26, 28pt before it).
  if (NSButton *close = [nsWindow standardWindowButton:NSWindowCloseButton]) {
    if (NSView *titlebar = close.superview) {
      const CGFloat height = NSHeight(titlebar.frame);
      if (height > 0)
        return height;
    }
  }
  // Fallback for a window whose buttons are gone (fullscreen moves them out).
  // The full-size-content-view bit has to come off first: with it set, the
  // content rect *is* the frame rect and this difference is always zero.
  NSWindowStyleMask mask =
      (nsWindow.styleMask & ~NSWindowStyleMaskFullSizeContentView) |
      NSWindowStyleMaskTitled;
  return NSHeight([NSWindow frameRectForContentRect:NSZeroRect
                                          styleMask:mask]);
}

NSRect titlebarBandFor(NSWindow *nsWindow) {
  const CGFloat height = titlebarHeightFor(nsWindow);
  const NSRect frame = nsWindow.frame;
  return NSMakeRect(NSMinX(frame), NSMaxY(frame) - height, NSWidth(frame),
                    height);
}

// Interactive-only aspect lock. NSWindow.contentAspectRatio also constrains
// accessibility/AppleScript resizes (verified: 1000x500 requested on a 16:9
// video lands as 889x500), so the ratio is parked here and pushed onto the
// NSWindow only while a mouse button is down over the window -- the whole
// span of a drag-resize, and never a moment a programmatic -setFrame: can
// occur.
struct InteractiveAspectLock {
  // Weak: this outlives nothing and owns nothing. If the window goes away
  // the reference nils itself out rather than dangling into the next
  // mouse-down.
  __weak NSWindow *window = nil;
  NSSize ratio = NSZeroSize;
  id monitor = nil;
  NSTimer *release_guard = nil;
  bool armed = false;
};

InteractiveAspectLock &aspectLock() {
  static InteractiveAspectLock lock;
  return lock;
}

void disarmAspectLock() {
  InteractiveAspectLock &lock = aspectLock();
  [lock.release_guard invalidate];
  lock.release_guard = nil;
  if (!lock.armed)
    return;
  lock.armed = false;
  if (!lock.window)
    return;
  // The documented way to drop an aspect-ratio constraint is to set the
  // mutually exclusive resize increments back to their (1, 1) default, not
  // to write a zero aspect ratio: a stored NSZeroSize ratio leaves AppKit's
  // resize math holding a degenerate value, and the next accessibility
  // -setFrame: (an AppleScript `set size of window 1`, say) traps inside
  // -[NSWindow _adjustNeedsDisplayRegionForNewFrame:] and kills the process.
  lock.window.contentResizeIncrements = NSMakeSize(1.0, 1.0);
}

void armAspectLock() {
  InteractiveAspectLock &lock = aspectLock();
  if (lock.armed || !lock.window || lock.ratio.width <= 0 ||
      lock.ratio.height <= 0)
    return;
  lock.window.contentAspectRatio = lock.ratio;
  lock.armed = true;
  // AppKit runs its live-resize tracking in a nested event loop, so the
  // mouse-up that ends a drag can be consumed before the monitor below sees
  // it. This guard (scheduled in common modes so it also fires inside that
  // nested loop) makes "no button is down" the real disarm condition, and
  // stops as soon as it has done so.
  lock.release_guard = [NSTimer timerWithTimeInterval:0.15
                                              repeats:YES
                                                block:^(NSTimer *) {
                                                  if (NSEvent.pressedMouseButtons == 0)
                                                    disarmAspectLock();
                                                }];
  [NSRunLoop.mainRunLoop addTimer:lock.release_guard
                          forMode:NSRunLoopCommonModes];
}

// True for a press that could begin a drag-resize: anywhere along the window
// border, where AppKit puts its resize handles. Presses in the middle of the
// window (the video, the transport, the titlebar band) are left alone so an
// ordinary click can never apply the ratio to a window whose current size
// does not match it.
bool pointStartsResize(NSWindow *nsWindow, NSPoint point_in_window) {
  constexpr CGFloat kResizeBorder = 12.0;
  const NSSize size = nsWindow.frame.size;
  if (size.width <= 2 * kResizeBorder || size.height <= 2 * kResizeBorder)
    return true;
  return point_in_window.x <= kResizeBorder ||
         point_in_window.y <= kResizeBorder ||
         point_in_window.x >= size.width - kResizeBorder ||
         point_in_window.y >= size.height - kResizeBorder;
}

void ensureAspectLockMonitor() {
  InteractiveAspectLock &lock = aspectLock();
  if (lock.monitor)
    return;
  lock.monitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown |
                                            NSEventMaskLeftMouseUp)
                                   handler:^NSEvent *(NSEvent *event) {
                                     InteractiveAspectLock &state = aspectLock();
                                     if (event.type == NSEventTypeLeftMouseDown) {
                                       if (state.window &&
                                           event.window == state.window &&
                                           pointStartsResize(
                                               state.window,
                                               event.locationInWindow))
                                         armAspectLock();
                                     } else {
                                       disarmAspectLock();
                                     }
                                     return event;
                                   }];
}

// Zoom-toggle memory for resizeToFitScreen: the frame the window had before
// it was fitted to the screen, so a second double-click can put it back.
struct FitToScreenState {
  // Weak for the same reason as InteractiveAspectLock's: it is only ever
  // compared for identity, never messaged through.
  __weak NSWindow *window = nil;
  NSRect fitted = NSZeroRect;
  NSRect restore = NSZeroRect;
  bool valid = false;
};

FitToScreenState &fitState() {
  static FitToScreenState state;
  return state;
}

bool framesMatch(NSRect lhs, NSRect rhs) {
  // AppKit rounds frames to whole points on some paths; a 1pt tolerance
  // keeps the toggle from missing its own fitted frame.
  constexpr CGFloat kEpsilon = 1.0;
  return std::fabs(NSMinX(lhs) - NSMinX(rhs)) <= kEpsilon &&
         std::fabs(NSMinY(lhs) - NSMinY(rhs)) <= kEpsilon &&
         std::fabs(NSWidth(lhs) - NSWidth(rhs)) <= kEpsilon &&
         std::fabs(NSHeight(lhs) - NSHeight(rhs)) <= kEpsilon;
}

NSScreen *screenFor(NSWindow *nsWindow) {
  if (NSScreen *screen = nsWindow.screen)
    return screen;
  return NSScreen.mainScreen;
}

// Shared by both appliers below (instant and animated) so an animation in
// flight blocks a nested instant -setFrame: exactly as an instant one already
// blocked a nested instant one -- see the re-entrancy note above
// applyWindowFrame. Cleared from the animated path's completion handler, so
// the guard spans the animation's full ~200-280ms, not just the call that
// starts it.
bool frame_change_in_flight = false;

// Validates and rounds a caller's proposed frame the same way for both
// appliers below. AppKit lays windows out in whole points, and a non-finite
// or sub-point frame is not merely rounded -- it can trap inside
// -[NSWindow _setFrameCommon:display:fromServer:]. Anything degenerate is
// dropped instead of forwarded, and everything else is rounded to the grid
// AppKit would have snapped it to anyway -- which is also why callers that
// need to remember the settled frame (resizeToFitScreen's zoom-toggle memory)
// can use this return value directly instead of reading the frame back out of
// nsWindow, see the animated applier's own comment below.
std::optional<NSRect> normalizedFrame(NSRect frame) {
  if (!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y) ||
      !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height))
    return std::nullopt;
  if (frame.size.width < 1.0 || frame.size.height < 1.0)
    return std::nullopt;

  frame.origin.x = std::round(frame.origin.x);
  frame.origin.y = std::round(frame.origin.y);
  frame.size.width = std::round(frame.size.width);
  frame.size.height = std::round(frame.size.height);
  return frame;
}

// Every *instant* frame change this file hands to AppKit goes through here.
//
// Re-entrancy: -setFrame: makes Qt re-lay-out the QML scene synchronously,
// and that scene is what calls into this file. A nested -setFrame: issued
// from inside an in-flight one -- particularly inside an accessibility
// resize transaction, where AppKit is midway through its own frame
// bookkeeping -- is exactly the shape of thing that crashes AppKit, so
// anything arriving while a frame change is in flight is dropped.
//
// This is the only path accessibility/AppleScript resizes and
// snapToVideoAspectRatio use, and it is what the benchmark harness's exact,
// immediate `set size of window 1` depends on -- never route those through
// the animated applier below.
bool applyWindowFrame(NSWindow *nsWindow, NSRect frame) {
  if (!nsWindow || frame_change_in_flight)
    return false;
  const std::optional<NSRect> normalized = normalizedFrame(frame);
  if (!normalized)
    return false;

  frame_change_in_flight = true;
  [nsWindow setFrame:*normalized display:YES animate:NO];
  frame_change_in_flight = false;
  return true;
}

// Animated counterpart, used only by the two user-facing zoom paths below
// (resizeToFitScreen, resizeToActualSize) -- never by applyWindowFrame's
// callers, and never by the double-click handler's own aspect-lock upkeep.
//
// A first attempt at this feature called the plain convenience method
// (-[NSWindow setFrame:display:animate:] with animate:YES) where
// applyWindowFrame's animate:NO call is today. It silently did nothing: on a
// full-size-content-view window (this
// one -- see installFullSizeContentView), that convenience method computes
// its animation through -[NSWindow animationResizeTime:], and Qt's own
// QCocoaWindow reacts to the *content view's* frame changing during -setFrame
// display:YES's synchronous layout pass and re-syncs its cached geometry
// inline, which collapses the animator's implicit CA transaction before it
// has ever been committed -- the resize duration AppKit measures at that
// point is effectively zero, so the frame simply snaps (or, as observed,
// appears to not move at all if the snap and the read-back race). Driving the
// change explicitly through -[NSWindow animator] inside a caller-owned
// NSAnimationContext group sidesteps this: the transaction (and its duration)
// is established *before* any layout pass can run inside it, and the
// animator proxy -- unlike the raw convenience method -- keeps driving the
// interpolation across each of Qt's synchronous per-frame layout passes
// instead of letting the first one collapse it. This was verified empirically
// (screen-captured mid-transition frames showing intermediate window sizes)
// rather than by inspecting AppKit's private implementation.
//
// completion runs after the animation's final frame commits, on the main
// thread; it may be nil.
bool applyWindowFrameAnimated(NSWindow *nsWindow, NSRect frame,
                              NSTimeInterval duration,
                              void (^completion)(void)) {
  if (!nsWindow || frame_change_in_flight)
    return false;
  const std::optional<NSRect> normalized = normalizedFrame(frame);
  if (!normalized)
    return false;

  frame_change_in_flight = true;
  const NSRect target = *normalized;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = duration;
        context.timingFunction = easeInEaseOutTimingFunction();
        context.allowsImplicitAnimation = YES;
        [nsWindow.animator setFrame:target display:YES];
      }
      completionHandler:^{
        frame_change_in_flight = false;
        if (completion != nil)
          completion();
      }];
  return true;
}

} // namespace

void installFullSizeContentView(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return;
  // Main.qml's Qt.ExpandedClientAreaHint | Qt.NoTitleBarBackgroundHint flags
  // already make QCocoaWindow apply NSWindowStyleMaskFullSizeContentView and
  // give the content view the full window frame, so that part needs no
  // native styleMask change here (re-asserting an already-set style mask bit
  // would just make AppKit redo window layout for no reason). What those
  // flags do not do is hide the title text or make the titlebar's own
  // background layer see-through, so QML content painted there (Main.qml
  // puts the video in ApplicationWindow's `background`, which Qt Quick
  // Controls extends under the titlebar for exactly this flag combination)
  // would otherwise still be covered by an opaque native titlebar.
  nsWindow.titlebarAppearsTransparent = YES;
  // The filename over the video is drawn by Main.qml's titlebar band, which
  // fades in and out with the rest of the chrome; AppKit's own title text
  // cannot fade with it, so it stays hidden and the band owns that text.
  // The window's `title` is still set, so accessibility clients and the
  // Window menu keep reading the real name.
  nsWindow.titleVisibility = NSWindowTitleHidden;
}

void setTitlebarControlsRevealed(QWindow *window, bool revealed,
                                 bool animated) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return;

  const CGFloat target_alpha = revealed ? 1.0 : 0.0;
  if (!animated) {
    setTrafficLightAlpha(nsWindow, target_alpha);
    return;
  }

  // Matches FloatingControls' opacity Behavior: 135ms revealing, 85ms
  // hiding, both Easing.OutCubic (qml/FloatingControls.qml).
  const NSTimeInterval duration = revealed ? 0.135 : 0.085;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = duration;
        context.timingFunction = outCubicTimingFunction();
        for (NSWindowButton type : kTrafficLightButtons) {
          if (NSButton *button = [nsWindow standardWindowButton:type])
            button.animator.alphaValue = target_alpha;
        }
      }
      completionHandler:nil];
}

qreal titlebarHeight(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return 0;
  return static_cast<qreal>(titlebarHeightFor(nsWindow));
}

bool pointerInTitlebarBand(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow || !nsWindow.isVisible || nsWindow.isMiniaturized)
    return false;
  // Fullscreen has no band: AppKit owns that strip, and Main.qml collapses
  // its overlay to zero height there.
  if (nsWindow.styleMask & NSWindowStyleMaskFullScreen)
    return false;
  const NSRect band = titlebarBandFor(nsWindow);
  if (NSHeight(band) <= 0)
    return false;
  // mouseLocation is the live pointer position, independent of the event
  // stream -- which is the point: no Qt hover event is coming while the
  // pointer sits on a traffic light.
  return NSMouseInRect(NSEvent.mouseLocation, band, NO);
}

void setContentAspectRatio(QWindow *window, qreal width, qreal height) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return;

  InteractiveAspectLock &lock = aspectLock();
  // A pending arm from a previous media file must not outlive it.
  disarmAspectLock();
  if (width <= 0 || height <= 0) {
    lock.window = nil;
    lock.ratio = NSZeroSize;
    return;
  }
  lock.window = nsWindow;
  lock.ratio =
      NSMakeSize(static_cast<CGFloat>(width), static_cast<CGFloat>(height));
  ensureAspectLockMonitor();
}

bool interactiveResizeActive(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return false;
  InteractiveAspectLock &lock = aspectLock();
  return lock.armed && lock.window == nsWindow;
}

void resizeToActualSize(QWindow *window, qreal videoPixelWidth,
                        qreal videoPixelHeight) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow || videoPixelWidth <= 0 || videoPixelHeight <= 0)
    return;
  // This runs from a double-click, so the button may still be down and the
  // interactive aspect lock armed; drop it so this frame lands verbatim.
  disarmAspectLock();

  NSScreen *screen = screenFor(nsWindow);
  if (!screen)
    return;

  CGFloat scale = screen.backingScaleFactor;
  if (scale <= 0)
    scale = 1.0;

  // Full-size content view means the content rect equals the frame rect, so
  // the logical window size is simply the video's pixel size divided by the
  // screen's backing scale factor -- no titlebar-height offset to add back.
  const NSRect visible = screen.visibleFrame;
  const CGFloat target_width = std::min(
      static_cast<CGFloat>(videoPixelWidth / scale), visible.size.width);
  const CGFloat target_height = std::min(
      static_cast<CGFloat>(videoPixelHeight / scale), visible.size.height);

  NSRect target;
  target.size = NSMakeSize(target_width, target_height);
  target.origin.x = NSMidX(visible) - target_width / 2.0;
  target.origin.y = NSMidY(visible) - target_height / 2.0;

  if (applyWindowFrameAnimated(nsWindow, target, kZoomAnimationDuration, nil))
    fitState().valid = false;
}

void resizeToFitScreen(QWindow *window, qreal videoWidth, qreal videoHeight) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return;
  NSScreen *screen = screenFor(nsWindow);
  if (!screen)
    return;
  // Same reason as resizeToActualSize: a double-click can still be holding
  // the mouse button, and this frame is computed here, not by AppKit.
  disarmAspectLock();

  const NSRect visible = screen.visibleFrame;
  if (NSWidth(visible) <= 0 || NSHeight(visible) <= 0)
    return;

  FitToScreenState &state = fitState();
  const NSRect current = nsWindow.frame;
  // Second double-click on an already-fitted window: AppKit's zoom toggle,
  // back to whatever the window was before the fit.
  if (state.valid && state.window == nsWindow &&
      framesMatch(current, state.fitted)) {
    const NSRect restore = state.restore;
    state.valid = false;
    applyWindowFrameAnimated(nsWindow, restore, kZoomAnimationDuration, nil);
    return;
  }

  CGFloat target_width = NSWidth(visible);
  CGFloat target_height = NSHeight(visible);
  if (videoWidth > 0 && videoHeight > 0) {
    const CGFloat aspect = static_cast<CGFloat>(videoWidth / videoHeight);
    target_height = target_width / aspect;
    if (target_height > NSHeight(visible)) {
      target_height = NSHeight(visible);
      target_width = target_height * aspect;
    }
  }

  NSRect target;
  target.size = NSMakeSize(target_width, target_height);
  target.origin.x = NSMidX(visible) - target_width / 2.0;
  target.origin.y = NSMidY(visible) - target_height / 2.0;

  if (!applyWindowFrameAnimated(nsWindow, target, kZoomAnimationDuration, nil))
    return;
  // Remember where the window came from so a second double-click can put it
  // back. state.fitted has to be the frame that was *requested*, not a
  // read-back of nsWindow.frame: with the animated applier that read would
  // land mid-transition (animator.frame does not reach `target` until the
  // animation's last frame commits), which would make framesMatch() above
  // miss the very frame this call is fitting to. normalizedFrame() rounds
  // `target` exactly the way applyWindowFrameAnimated will, and framesMatch's
  // 1pt tolerance absorbs anything short of that.
  state.window = nsWindow;
  state.restore = current;
  state.fitted = normalizedFrame(target).value_or(target);
  state.valid = true;
}

void snapToVideoAspectRatio(QWindow *window, qreal videoWidth,
                            qreal videoHeight) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow || videoWidth <= 0 || videoHeight <= 0)
    return;

  NSScreen *screen = screenFor(nsWindow);
  if (!screen)
    return;

  const CGFloat aspect = static_cast<CGFloat>(videoWidth / videoHeight);
  if (aspect <= 0)
    return;

  const NSRect visible = screen.visibleFrame;
  const NSRect current = nsWindow.frame;

  // QuickTime's own snap-to-aspect: keep the window's current width and
  // derive the height that removes letterboxing, then fall back to fitting
  // within the screen's visible frame (aspect preserved) if that would run
  // off screen -- the same clamp-to-visibleFrame contract resizeToActualSize
  // above uses, just sized from the current window instead of native pixels.
  CGFloat target_width = current.size.width;
  CGFloat target_height = target_width / aspect;

  if (target_height > visible.size.height) {
    target_height = visible.size.height;
    target_width = target_height * aspect;
  }
  if (target_width > visible.size.width) {
    target_width = visible.size.width;
    target_height = target_width / aspect;
  }

  NSRect target;
  target.size = NSMakeSize(target_width, target_height);
  // Preserve the window's current center (QuickTime does not recenter on
  // the screen for this), then clamp so the resized frame stays fully
  // within the visible frame.
  target.origin.x = NSMidX(current) - target_width / 2.0;
  target.origin.y = NSMidY(current) - target_height / 2.0;
  target.origin.x = std::max(
      visible.origin.x, std::min(target.origin.x, NSMaxX(visible) - target_width));
  target.origin.y = std::max(
      visible.origin.y, std::min(target.origin.y, NSMaxY(visible) - target_height));

  if (applyWindowFrame(nsWindow, target))
    fitState().valid = false;
}

namespace {

// Shared by the synchronous and asynchronous natural-size reads; expects the
// asset's tracks to be available (loaded, or loadable synchronously).
QSizeF naturalSizeFromAsset(AVURLAsset *asset) {
  NSArray<AVAssetTrack *> *tracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (tracks.count == 0)
    return {};

  AVAssetTrack *track = tracks.firstObject;
  // naturalSize is the track's coded pixel size; preferredTransform can carry
  // a 90/270 degree rotation for video shot in portrait orientation. Applying
  // it gives the actual displayed (width, height), matching what mpv reports
  // via "dwidth"/"dheight" and what the player visibly renders.
  const CGSize transformed =
      CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
  const qreal width = std::fabs(transformed.width);
  const qreal height = std::fabs(transformed.height);
  if (width <= 0 || height <= 0)
    return {};
  return QSizeF(width, height);
}

} // namespace

void adoptBackgroundLaunchPolicy() {
  NSApplication *application = NSApp;
  if (application == nil)
    return;
  // Accessory, not Prohibited: Prohibited forbids windows outright, which
  // would take the drawn frames the measurement is made of away with the
  // focus steal.
  [application setActivationPolicy:NSApplicationActivationPolicyAccessory];

  // Self-correcting guard, and it is not belt-and-braces: measured, the policy
  // change alone let roughly one launch in two through. Qt's cocoa plugin
  // activates the process from more than one place and not all of them run
  // before this function does, so a launch that wins the race steals exactly
  // the focus this seam exists to protect. Chasing each call site would leave
  // the seam hostage to the next Qt release; resigning activation the moment
  // it is observed cannot be raced. Worst case is one runloop turn of blip
  // before the user's application is frontmost again.
  //
  // Registered once per process (the seam is decided at launch and never
  // toggles), and deliberately never removed: the guard must outlive every
  // window, and the process is a test instance whose whole life it covers.
  static id observer = nil;
  if (observer != nil)
    return;
  observer = [[NSNotificationCenter defaultCenter]
      addObserverForName:NSApplicationDidBecomeActiveNotification
                  object:application
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *) {
                [NSApp setActivationPolicy:
                           NSApplicationActivationPolicyAccessory];
                [NSApp deactivate];
              }];
}

void orderFrontWithoutActivating(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (nsWindow == nil)
    return;
  nsWindow.level = NSFloatingWindowLevel;
  [nsWindow orderFrontRegardless];
}

QSizeF videoNaturalSizeForSource(const QUrl &source) {
  if (!source.isLocalFile())
    return {};
  NSURL *url = source.toNSURL();
  if (!url)
    return {};

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  return naturalSizeFromAsset(asset);
}

} // namespace wam::macos_window_chrome

namespace wam::qt {

MacWindowChrome::MacWindowChrome(QWindow *window, QObject *parent)
    : QObject(parent), window_(window),
      benchmarkMode_(
          qEnvironmentVariableIsSet("WAM_NATIVE_BENCHMARK_TELEMETRY")) {
  wam::macos_window_chrome::installFullSizeContentView(window_);

  // Blocks capture reference-typed variables by reference; copy what the
  // handler needs into non-reference locals. The monitor runs on the main
  // thread, so the QPointer check is race-free.
  const QPointer<MacWindowChrome> guard(this);
  QWindow *const qtWindow = window;
  id monitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                   handler:^NSEvent *(NSEvent *event) {
                                     MacWindowChrome *self = guard.data();
                                     if (self == nullptr ||
                                         event.clickCount != 2) {
                                       return event;
                                     }
                                     NSView *view = (__bridge NSView *)
                                         reinterpret_cast<void *>(
                                             qtWindow->winId());
                                     NSWindow *nsWindow = view.window;
                                     if (nsWindow == nil ||
                                         event.window != nsWindow ||
                                         (nsWindow.styleMask &
                                          NSWindowStyleMaskFullScreen) != 0) {
                                       return event;
                                     }
                                     const CGFloat bandHeight =
                                         wam::macos_window_chrome::
                                             titlebarHeight(qtWindow);
                                     if (bandHeight <= 0) {
                                       return event;
                                     }
                                     const NSPoint point =
                                         event.locationInWindow;
                                     const CGFloat contentHeight =
                                         NSHeight(nsWindow.contentView.frame);
                                     if (point.y < contentHeight - bandHeight) {
                                       return event;
                                     }
                                     // Leave the traffic lights their own
                                     // clicks; they sit in the leftmost strip.
                                     if (point.x <= 80.0) {
                                       return event;
                                     }
                                     emit self->titlebarDoubleClicked();
                                     // Swallow the event so AppKit's default
                                     // titlebar double-click (zoom/minimize)
                                     // does not also fire.
                                     return static_cast<NSEvent *>(nil);
                                   }];
  titlebarClickMonitor_ = (__bridge_retained void *)monitor;
}

MacWindowChrome::~MacWindowChrome() {
  if (titlebarClickMonitor_ != nullptr) {
    id monitor = (__bridge_transfer id)titlebarClickMonitor_;
    [NSEvent removeMonitor:monitor];
    titlebarClickMonitor_ = nullptr;
  }
}

void MacWindowChrome::requestVideoNaturalSize(const QUrl &source) {
  if (!source.isLocalFile()) {
    emit videoNaturalSizeReady(source, 0, 0);
    return;
  }
  NSURL *url = source.toNSURL();
  if (!url) {
    emit videoNaturalSizeReady(source, 0, 0);
    return;
  }
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  // Blocks capture reference-typed variables by reference; everything the
  // completion needs is first copied into non-reference locals.
  const QUrl requested = source;
  const QPointer<MacWindowChrome> guard(this);
  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                       completionHandler:^{
                         dispatch_async(dispatch_get_main_queue(), ^{
                           MacWindowChrome *self = guard.data();
                           if (self == nullptr)
                             return;
                           QSizeF size;
                           NSError *error = nil;
                           if ([asset statusOfValueForKey:@"tracks"
                                                    error:&error] ==
                               AVKeyValueStatusLoaded) {
                             size = wam::macos_window_chrome::
                                 naturalSizeFromAsset(asset);
                           }
                           emit self->videoNaturalSizeReady(
                               requested, size.width(), size.height());
                         });
                       }];
}

void MacWindowChrome::setTitlebarRevealed(bool revealed, bool animated) {
  wam::macos_window_chrome::setTitlebarControlsRevealed(window_, revealed,
                                                        animated);
}

void MacWindowChrome::setContentAspectRatio(qreal width, qreal height) {
  wam::macos_window_chrome::setContentAspectRatio(window_, width, height);
}

bool MacWindowChrome::interactiveResizeActive() const {
  return wam::macos_window_chrome::interactiveResizeActive(window_);
}

void MacWindowChrome::resizeToActualSize(qreal videoPixelWidth,
                                         qreal videoPixelHeight) {
  wam::macos_window_chrome::resizeToActualSize(window_, videoPixelWidth,
                                               videoPixelHeight);
}

void MacWindowChrome::resizeToFitScreen(qreal videoWidth, qreal videoHeight) {
  wam::macos_window_chrome::resizeToFitScreen(window_, videoWidth, videoHeight);
}

void MacWindowChrome::snapToVideoAspectRatio(qreal videoWidth,
                                             qreal videoHeight) {
  wam::macos_window_chrome::snapToVideoAspectRatio(window_, videoWidth,
                                                    videoHeight);
}

QSizeF MacWindowChrome::videoNaturalSizeForSource(const QUrl &source) const {
  return wam::macos_window_chrome::videoNaturalSizeForSource(source);
}

qreal MacWindowChrome::titlebarHeight() const {
  return wam::macos_window_chrome::titlebarHeight(window_);
}

bool MacWindowChrome::pointerInTitlebarBand() const {
  return wam::macos_window_chrome::pointerInTitlebarBand(window_);
}

} // namespace wam::qt
