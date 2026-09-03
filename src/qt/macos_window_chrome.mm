#include "macos_window_chrome.hpp"

#include <QDebug>
#include <QFileInfo>
#include <QPointer>
#include <QString>
#include <QTimer>
#include <QUrl>
#include <QWindow>

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#include "platform/macos/native_concurrency_limits.hpp"
#include "platform/macos/native_layer_host_view.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
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

// The ratio each window wants its drag-resizes locked to.
//
// The LOCK above is legitimately singular -- macOS has one pointer, so at most
// one drag-resize is ever in flight -- but the RATIO is a per-window fact, and
// WAM is a multi-window player. With a single stored (window, ratio) pair the
// last window to open a video overwrote every other window's ratio, so
// dragging any other window's corner either used the wrong aspect or was not
// locked at all. A fixed-size table (never grown, never allocated) keyed by
// window keeps the lock singular and the ratios per window.
struct AspectRatioEntry {
  // Weak for the same reason the lock's reference is: this table outlives
  // nothing and owns nothing, and a closed window must nil itself out rather
  // than dangle into the next mouse-down.
  __weak NSWindow *window = nil;
  NSSize ratio = NSZeroSize;
};

std::array<AspectRatioEntry, wam::macos::kMaximumConcurrentPlayerWindows> &
aspectRatios() {
  static std::array<AspectRatioEntry,
                    wam::macos::kMaximumConcurrentPlayerWindows>
      ratios;
  return ratios;
}

// The stored ratio for `nsWindow`, or NSZeroSize when it has none.
NSSize aspectRatioFor(NSWindow *nsWindow) {
  if (nsWindow == nil)
    return NSZeroSize;
  for (const AspectRatioEntry &entry : aspectRatios()) {
    if (entry.window == nsWindow)
      return entry.ratio;
  }
  return NSZeroSize;
}

// Records (or, with a non-positive ratio, forgets) `nsWindow`'s lock ratio.
// Reuses the window's existing row, else the first row whose window has been
// released, else -- only past the window cap, which cannot happen while the
// table is sized from it -- drops the request rather than evicting a live one.
void setAspectRatioFor(NSWindow *nsWindow, NSSize ratio) {
  if (nsWindow == nil)
    return;
  const bool clearing = ratio.width <= 0 || ratio.height <= 0;
  AspectRatioEntry *free_row = nullptr;
  for (AspectRatioEntry &entry : aspectRatios()) {
    if (entry.window == nsWindow) {
      if (clearing) {
        entry.window = nil;
        entry.ratio = NSZeroSize;
      } else {
        entry.ratio = ratio;
      }
      return;
    }
    if (free_row == nullptr && entry.window == nil)
      free_row = &entry;
  }
  if (clearing || free_row == nullptr)
    return;
  free_row->window = nsWindow;
  free_row->ratio = ratio;
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

void armAspectLock(NSWindow *nsWindow, NSSize ratio) {
  InteractiveAspectLock &lock = aspectLock();
  if (lock.armed || nsWindow == nil || ratio.width <= 0 || ratio.height <= 0)
    return;
  lock.window = nsWindow;
  lock.ratio = ratio;
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
                                     if (event.type == NSEventTypeLeftMouseDown) {
                                       // Which window was pressed decides the
                                       // ratio: with N player windows open the
                                       // one under the pointer is the one whose
                                       // aspect the drag must hold.
                                       NSWindow *pressed = event.window;
                                       const NSSize ratio =
                                           aspectRatioFor(pressed);
                                       if (ratio.width > 0 &&
                                           ratio.height > 0 &&
                                           pointStartsResize(
                                               pressed,
                                               event.locationInWindow))
                                         armAspectLock(pressed, ratio);
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

// One row per window, for the same reason the aspect ratios are a table: the
// zoom toggle's "put it back where it was" memory belongs to the window that
// was zoomed. A single shared row meant fitting a second window silently threw
// away the first window's restore frame.
std::array<FitToScreenState, wam::macos::kMaximumConcurrentPlayerWindows> &
fitStates() {
  static std::array<FitToScreenState,
                    wam::macos::kMaximumConcurrentPlayerWindows>
      states;
  return states;
}

// The row for `nsWindow`, reusing its existing row, else the first row that is
// free (unused, released, or invalidated). Never null: past the cap -- which
// the table is sized to make unreachable -- the last row is reused.
FitToScreenState &fitState(NSWindow *nsWindow) {
  auto &states = fitStates();
  FitToScreenState *free_row = nullptr;
  for (FitToScreenState &state : states) {
    if (state.window == nsWindow)
      return state;
    if (free_row == nullptr && (state.window == nil || !state.valid))
      free_row = &state;
  }
  FitToScreenState &row = free_row != nullptr ? *free_row : states.back();
  row = FitToScreenState{};
  return row;
}

// "Fill Screen (Padded)" memory: the exact frame the window had before it was
// blown up to the screen's visible frame, so toggling back puts it there to
// the point. Deliberately a SEPARATE table from fitStates() above rather than
// a reuse of it: the double-click zoom toggle and the padded fill are two
// independent gestures a user can interleave, and sharing one row would let
// either one silently eat the other's restore frame.
struct PaddedFillState {
  // Weak for the same reason every other window reference in this file is:
  // identity comparison only, never messaged through, and a closed window
  // must nil itself out rather than dangle.
  __weak NSWindow *window = nil;
  NSRect restore = NSZeroRect;
  bool valid = false;
};

std::array<PaddedFillState, wam::macos::kMaximumConcurrentPlayerWindows> &
paddedFillStates() {
  static std::array<PaddedFillState,
                    wam::macos::kMaximumConcurrentPlayerWindows>
      states;
  return states;
}

// The row for `nsWindow`, reusing its existing row, else the first free one.
// Never null; see fitState() above, which this mirrors exactly.
PaddedFillState &paddedFillState(NSWindow *nsWindow) {
  auto &states = paddedFillStates();
  PaddedFillState *free_row = nullptr;
  for (PaddedFillState &state : states) {
    if (state.window == nsWindow)
      return state;
    if (free_row == nullptr && (state.window == nil || !state.valid))
      free_row = &state;
  }
  PaddedFillState &row = free_row != nullptr ? *free_row : states.back();
  row = PaddedFillState{};
  return row;
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

  // FULLSCREEN IS NOT OURS TO FADE, and this is the whole reason exiting
  // fullscreen was impossible.
  //
  // AppKit does not build a second set of window buttons for fullscreen; it
  // reparents THESE THREE NSButton INSTANCES into the auto-hiding fullscreen
  // titlebar accessory. Its top-edge-hover reveal then animates the
  // accessory's position -- it never touches each button's alphaValue. So a
  // windowed fade that left them at alpha 0 (and the idle fade below always
  // does, because pointerInTitlebarBand() is false in fullscreen by
  // construction and hideControlsIfIdle therefore always hides) made AppKit
  // slide three fully transparent traffic lights down under the menu bar:
  // the strip appeared, the buttons did not, and there was no way to click
  // out of fullscreen.
  //
  // In fullscreen the buttons are therefore pinned opaque and AppKit's own
  // auto-hide is left to decide when they are on screen -- which is exactly
  // the standard macOS behaviour, hover-to-reveal and stay-while-hovered
  // included. Nothing is lost: qml/Main.qml collapses its own titlebar band
  // to zero height in fullscreen, so the fade has nothing above the video to
  // own there anyway.
  if (nsWindow.styleMask & NSWindowStyleMaskFullScreen) {
    setTrafficLightAlpha(nsWindow, 1.0);
    return;
  }

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

bool nativeFullScreen(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  return nsWindow != nil &&
         (nsWindow.styleMask & NSWindowStyleMaskFullScreen) != 0;
}


qreal titlebarControlsAlpha(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return -1;
  NSButton *close = [nsWindow standardWindowButton:NSWindowCloseButton];
  if (close == nil)
    return -1;
  return static_cast<qreal>(close.alphaValue);
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

bool canRevealInFinder(const QUrl &source) {
  if (!source.isLocalFile())
    return false;
  const QString path = source.toLocalFile();
  if (path.isEmpty())
    return false;
  // QFileInfo rather than -[NSFileManager fileExistsAtPath:] only to keep the
  // NSString bridge on the one path that genuinely needs it, below.
  return QFileInfo::exists(path);
}

namespace {

// How long to let Finder finish activating and finish ordering the window
// forward before the reveal is re-asserted. Long enough that the window is
// settled (measured: the activation and window-ordering round trip is well
// under 150ms on this machine), short enough that it is still the same
// gesture from the user's point of view and that they cannot realistically
// have moved on to a third app in between.
constexpr double kRevealSettleSeconds = 0.25;

NSRunningApplication *finderApplication() {
  NSArray<NSRunningApplication *> *finders = [NSRunningApplication
      runningApplicationsWithBundleIdentifier:@"com.apple.finder"];
  return finders.count > 0 ? finders.firstObject : nil;
}

} // namespace

bool revealInFinder(const QUrl &source) {
  if (!canRevealInFinder(source))
    return false;
  NSURL *url = [NSURL fileURLWithPath:source.toLocalFile().toNSString()];
  if (!url)
    return false;
  // The one-URL form of the multi-selection API: Finder opens (or reuses) a
  // window on the file's parent directory and selects the file in it, which
  // is exactly the system "Show in Finder" behavior and is why this is not
  // done with -openURL: on the parent folder -- that would open the folder
  // without selecting anything.
  NSArray<NSURL *> *const urls = @[ url ];
  [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];

  // Second pass, and the whole point of it.
  //
  // When this call is what *activates* Finder and Finder answers it by
  // REUSING a window it already had on that folder, the selection lands but
  // the scroll-to-visible does not. Observed on the real case this feature
  // exists for: ~/Downloads, five windows already open on it, grouped icon
  // view. Finder came frontmost, `selection` read back as the right file, and
  // the file was not drawn anywhere in the window -- it sat past the end of a
  // truncated group row that never scrolled. Selected, and invisible, which
  // is indistinguishable from not selected at all.
  //
  // Issuing the identical reveal a second time, once Finder is up and the
  // window is already forward, is what performs the scroll. So do exactly
  // that. It is idempotent in every other case: for a window Finder had to
  // open, and for one that was already showing the item, the second pass
  // re-selects the same file in the same window and changes nothing.
  //
  // Guarded, because 250ms is not zero: if the user has already moved on to
  // some third application, taking activation back off them would be worse
  // than the defect. Frontmost being Finder is the expected case; frontmost
  // still being us means the first pass has not landed yet, and the second
  // pass (which activates Finder itself) is then the one that completes the
  // gesture.
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW,
                    static_cast<int64_t>(kRevealSettleSeconds * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        NSRunningApplication *const finder = finderApplication();
        NSRunningApplication *const front =
            NSWorkspace.sharedWorkspace.frontmostApplication;
        const bool ours =
            [front isEqual:NSRunningApplication.currentApplication];
        if (!ours && (finder == nil || ![front isEqual:finder]))
          return;
        if (finder != nil && !finder.active)
          [finder activateWithOptions:0];
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
      });
  return true;
}

void setContentAspectRatio(QWindow *window, qreal width, qreal height) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return;

  // A pending arm from a previous media file must not outlive it -- but only
  // this window's: another window's live drag is none of this call's business.
  if (aspectLock().window == nsWindow)
    disarmAspectLock();
  setAspectRatioFor(nsWindow, NSMakeSize(static_cast<CGFloat>(width),
                                         static_cast<CGFloat>(height)));
  if (width > 0 && height > 0)
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
    fitState(nsWindow).valid = false;
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

  FitToScreenState &state = fitState(nsWindow);
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

bool setFillScreenPadded(QWindow *window, bool filled) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return false;
  // Fullscreen owns the frame outright; a padded fill underneath it would be
  // both invisible and a frame AppKit would fight on the way out.
  if (nsWindow.styleMask & NSWindowStyleMaskFullScreen)
    return false;

  PaddedFillState &state = paddedFillState(nsWindow);

  if (!filled) {
    if (!state.valid || state.window != nsWindow)
      return false;
    const NSRect restore = state.restore;
    state.valid = false;
    state.window = nil;
    // The restore frame was captured straight out of nsWindow.frame, which
    // AppKit keeps on the whole-point grid, so normalizedFrame() inside the
    // applier is the identity here and the window lands on exactly the
    // rectangle it left.
    return applyWindowFrameAnimated(nsWindow, restore, kZoomAnimationDuration,
                                    nil);
  }

  NSScreen *screen = screenFor(nsWindow);
  if (!screen)
    return false;
  const NSRect visible = screen.visibleFrame;
  if (NSWidth(visible) <= 0 || NSHeight(visible) <= 0)
    return false;

  // A drag may still be holding the interactive aspect lock; this frame is
  // computed here, not by AppKit, and must land verbatim.
  disarmAspectLock();

  const NSRect current = nsWindow.frame;
  if (!applyWindowFrameAnimated(nsWindow, visible, kZoomAnimationDuration,
                                nil))
    return false;
  // Only remember the pre-fill frame the first time: a second fill request
  // while already filled (a re-fill after the screen changed, say) must not
  // overwrite the user's real window with the filled one.
  if (!state.valid || state.window != nsWindow) {
    state.window = nsWindow;
    state.restore = current;
    state.valid = true;
  }
  // The padded fill is a deliberate, exact frame; the zoom toggle's memory of
  // a *different* frame is stale from here on, exactly as it is after any
  // other explicit geometry command in this file.
  fitState(nsWindow).valid = false;
  return true;
}

void clearFillScreenPadded(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (!nsWindow)
    return;
  PaddedFillState &state = paddedFillState(nsWindow);
  if (state.window != nsWindow)
    return;
  state.valid = false;
  state.window = nil;
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
    fitState(nsWindow).valid = false;
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

// Whether the asset's first video track is tagged with an HDR transfer
// function. Shared by the asynchronous read below; expects loaded tracks.
//
// The transfer function is the whole question, and deliberately not the
// primaries: BT.2020 primaries with a BT.709 transfer is wide-gamut SDR, which
// wants the Vivid boost exactly as much as any other SDR source does. PQ and
// HLG are the two transfers that already carry above-SDR-white luminance, and
// they are the two the native colour envelope admits (see
// media::mediaVideoColorAdmitted).
bool assetHasHdrTransfer(AVURLAsset *asset) {
  NSArray<AVAssetTrack *> *tracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (tracks.count == 0)
    return false;
  for (id description in tracks.firstObject.formatDescriptions) {
    CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)description;
    if (format == nullptr)
      continue;
    CFStringRef transfer = static_cast<CFStringRef>(
        CMFormatDescriptionGetExtension(
            format, kCMFormatDescriptionExtension_TransferFunction));
    if (transfer == nullptr)
      continue;
    if (CFStringCompare(transfer,
                        kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                        0) == kCFCompareEqualTo ||
        CFStringCompare(transfer,
                        kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                        0) == kCFCompareEqualTo)
      return true;
  }
  return false;
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

void hideApplication() { [NSApp hide:nil]; }

namespace {

// Retained for the process's lifetime, like every other app-level hook here.
std::function<void()> &applicationReopenHandler() {
  static std::function<void()> handler;
  return handler;
}

std::function<void()> &applicationHideHandler() {
  static std::function<void()> handler;
  return handler;
}

// The delegate implementation this hook displaced, if there was one. Called
// after the handler so Qt (or any future delegate) keeps whatever behaviour it
// had; a null value means the selector was genuinely unimplemented and YES --
// AppKit's documented default, "perform the usual reopen behaviour" -- is the
// honest answer.
using ReopenImp = BOOL (*)(id, SEL, NSApplication *, BOOL);
ReopenImp &displacedReopenImp() {
  static ReopenImp imp = nullptr;
  return imp;
}

} // namespace

void installApplicationReopenHandler(std::function<void()> handler) {
  applicationReopenHandler() = std::move(handler);

  static bool installed = false;
  if (installed)
    return;
  id delegate = NSApp.delegate;
  if (delegate == nil)
    return;
  installed = true;

  Class delegate_class = object_getClass(delegate);
  const SEL selector = @selector(applicationShouldHandleReopen:
                                     hasVisibleWindows:);
  IMP replacement = imp_implementationWithBlock(
      ^BOOL(id self_object, NSApplication *sender, BOOL has_visible_windows) {
        if (!has_visible_windows) {
          if (const std::function<void()> &reopen = applicationReopenHandler())
            reopen();
        }
        if (ReopenImp displaced = displacedReopenImp()) {
          return displaced(self_object, selector, sender,
                           has_visible_windows);
        }
        return YES;
      });

  // class_addMethod only succeeds when the class itself does not already
  // implement the selector, which is exactly the discrimination needed: add it
  // outright when nobody owns it, and otherwise displace the existing
  // implementation while keeping a pointer to it to chain through.
  if (!class_addMethod(delegate_class, selector, replacement, "c@:@c")) {
    Method existing = class_getInstanceMethod(delegate_class, selector);
    if (existing == nullptr) {
      installed = false;
      return;
    }
    displacedReopenImp() =
        reinterpret_cast<ReopenImp>(method_getImplementation(existing));
    method_setImplementation(existing, replacement);
  }
}

void installApplicationHideObserver(std::function<void()> handler) {
  applicationHideHandler() = std::move(handler);

  // Registered once and deliberately never removed: the observer must outlive
  // every window, and it lives exactly as long as the application does.
  static id observer = nil;
  if (observer != nil)
    return;
  observer = [[NSNotificationCenter defaultCenter]
      addObserverForName:NSApplicationDidHideNotification
                  object:NSApp
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *) {
                if (const std::function<void()> &hidden =
                        applicationHideHandler())
                  hidden();
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

bool captureWindowToFile(QWindow *window, const QString &path) {
  if (window == nullptr || path.isEmpty())
    return false;
  NSWindow *nsWindow = nsWindowFor(window);
  if (nsWindow == nil)
    return false;
  const CGWindowID windowId = static_cast<CGWindowID>(nsWindow.windowNumber);
  if (windowId == 0)
    return false;

  // kCGWindowListOptionIncludingWindow plus a null rect is "this window and
  // nothing else, at its own bounds": no screen behind it, no window in front
  // of it. BoundsIgnoreFraming drops the shadow so the saved rect is the
  // window's own content and the picture's aspect can be measured off it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CGImageRef image = CGWindowListCreateImage(
      CGRectNull, kCGWindowListOptionIncludingWindow, windowId,
      static_cast<CGWindowImageOption>(kCGWindowImageBoundsIgnoreFraming |
                                       kCGWindowImageNominalResolution));
#pragma clang diagnostic pop
  if (image == nullptr)
    return false;
  const std::size_t width = CGImageGetWidth(image);
  const std::size_t height = CGImageGetHeight(image);
  if (width == 0 || height == 0) {
    CGImageRelease(image);
    return false;
  }

  NSBitmapImageRep *rep =
      [[NSBitmapImageRep alloc] initWithCGImage:image];
  CGImageRelease(image);
  if (rep == nil)
    return false;
  NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                  properties:@{}];
  if (png == nil)
    return false;
  NSString *destination = path.toNSString();
  return [png writeToFile:destination atomically:YES] == YES;
}

// --------------------------------------------------------------- Vivid boost

qreal screenEdrHeadroom(QWindow *window) {
  NSScreen *screen = nil;
  if (NSWindow *nsWindow = nsWindowFor(window))
    screen = screenFor(nsWindow);
  if (screen == nil)
    screen = NSScreen.mainScreen;
  if (screen == nil)
    return 1.0;
  const CGFloat headroom =
      screen.maximumExtendedDynamicRangeColorComponentValue;
  if (!std::isfinite(headroom) || headroom < 1.0)
    return 1.0;
  return headroom;
}

qreal setVividBoost(QWindow *window, qreal boost) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (nsWindow == nil)
    return 1.0;
  qreal applied = 1.0;
  if (std::isfinite(boost) && boost > 1.0) {
    // The clamp is not a safety rail, it is the correctness rule: everything
    // asked for above the display's current ceiling arrives on screen as the
    // same flat white, so an unclamped boost trades highlight detail for
    // nothing. The headroom moves, so this is re-evaluated rather than cached.
    applied = std::min<qreal>(boost, screenEdrHeadroom(window));
    if (!(applied > 1.0))
      applied = 1.0;
  }
  wam::macos::setNativeLayerVividBoost((__bridge void *)nsWindow,
                                       static_cast<double>(applied));
  return applied;
}

qreal vividBoost(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (nsWindow == nil)
    return 1.0;
  return static_cast<qreal>(
      wam::macos::nativeLayerVividBoost((__bridge void *)nsWindow));
}

qreal appliedVividBoost(QWindow *window) {
  NSWindow *nsWindow = nsWindowFor(window);
  if (nsWindow == nil)
    return 0.0;
  return static_cast<qreal>(
      wam::macos::nativeLayerAppliedVividBoost((__bridge void *)nsWindow));
}

} // namespace wam::macos_window_chrome

// ---------------------------------------------------------------------------
// Theater dim.
//
// One borderless, click-through black window per screen, ordered directly
// beneath its player window and above everything else. Not a QML overlay:
// the whole point is to darken what is OUTSIDE the player, which no window's
// own content can reach.
//
// The design decisions, stated rather than left to be inferred:
//
//   * EVERY SCREEN, not just the player's. A second monitor left at full
//     brightness beside a dimmed one defeats the gesture entirely.
//
//   * PER PLAYER WINDOW, like Fill Screen (Padded) -- it is a way of looking
//     at THIS window right now, not an application preference. Each dimmed
//     window carries its own overlay, ordered directly under itself, so with
//     two dimmed windows open the front one is bright and the one behind it
//     is seen through the front one's overlay. That is theater behaviour, not
//     a defect, but it does mean two overlays compound where they overlap
//     something below them both.
//
//   * NOT ON THE PLAYER'S OWN SCREEN IN NATIVE FULLSCREEN. macOS fullscreen
//     already isolates the window onto its own Space against black; a dim
//     there would be invisible at best. The other screens still dim, which is
//     exactly the case fullscreen does NOT already handle.
//
//   * CLICK-THROUGH, ALWAYS. ignoresMouseEvents means a click meant for
//     another app reaches it through the dim. When the mode is off the windows
//     are ordered out and released, so there is nothing to intercept at all.
@interface WAMDimWindow : NSWindow
@end

@implementation WAMDimWindow
// Belt and braces over the borderless style mask: this must never take key or
// main away from the player it is dimming for.
- (BOOL)canBecomeKeyWindow {
  return NO;
}
- (BOOL)canBecomeMainWindow {
  return NO;
}
@end

@interface WAMTheaterDimController : NSObject
- (instancetype)initWithPlayerWindow:(NSWindow *)window;
- (void)setEnabled:(BOOL)enabled opacity:(CGFloat)opacity;
- (BOOL)active;
- (void)invalidate;
@end

@implementation WAMTheaterDimController {
  // Weak for the reason every window reference in this file is weak: a closed
  // window must nil itself out rather than dangle.
  __weak NSWindow *_player;
  NSMutableArray<NSWindow *> *_dims;
  BOOL _enabled;
  CGFloat _opacity;
  BOOL _invalidated;
}

- (instancetype)initWithPlayerWindow:(NSWindow *)window {
  self = [super init];
  if (self == nil)
    return nil;
  _player = window;
  _dims = [NSMutableArray array];
  _enabled = NO;
  _opacity = 0.7;
  _invalidated = NO;

  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  // Everything that can change the answer to "should the overlay be up, and
  // where". Each one is a real observed failure mode rather than a guess:
  //   key/resign     -- another app's window came between the overlay and its
  //                     player, so the overlay has to be re-ordered under it
  //   app hide/unhide -- the "h" macro, Cmd-H, Hide Others, the Dock menu
  //   miniaturize    -- a dimmed screen with no player visible on it
  //   will close     -- the overlay must not outlive its window
  //   screen params  -- a display plugged in mid-session gets no dim otherwise
  //   did change screen / fullscreen -- moves which screen is the player's
  for (NSNotificationName name in @[
         NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
         NSWindowDidMiniaturizeNotification,
         NSWindowDidDeminiaturizeNotification,
         NSWindowDidChangeScreenNotification,
         NSWindowDidEnterFullScreenNotification,
         NSWindowDidExitFullScreenNotification
       ]) {
    [center addObserver:self
               selector:@selector(refresh)
                   name:name
                 object:window];
  }
  // Close is terminal, not a refresh: -[NSWindow isVisible] is still YES
  // inside willClose, so a refresh here would rebuild the overlay for a window
  // that is on its way out and leave it on screen with nothing under it.
  [center addObserver:self
             selector:@selector(invalidate)
                 name:NSWindowWillCloseNotification
               object:window];
  for (NSNotificationName name in @[
         NSApplicationDidChangeScreenParametersNotification,
         NSApplicationDidHideNotification,
         NSApplicationDidUnhideNotification
       ]) {
    [center addObserver:self selector:@selector(refresh) name:name object:nil];
  }
  return self;
}

- (void)dealloc {
  [self invalidate];
}

- (BOOL)active {
  return _enabled && _dims.count > 0;
}

- (void)setEnabled:(BOOL)enabled opacity:(CGFloat)opacity {
  _enabled = enabled;
  _opacity = std::clamp<CGFloat>(std::isfinite(opacity) ? opacity : 0.7, 0.0,
                                 0.95);
  [self refresh];
}

// True when an overlay belongs on screen at all right now.
//
// Deliberately NOT gated on this application being active or this window being
// key, and the reason is worth stating because the stricter rule was written
// first and then measured wrong. Activating another application orders that
// application's windows to the front of the normal band -- which is the band
// the overlay is in -- so the app you switch to is never dimmed by it anyway;
// the dim only ever covers the desktop and whatever was already behind it.
// Tying the overlay to activation therefore bought nothing, and it cost the
// mode its ability to be observed at all under the background launch seam,
// where the process is deliberately never active.
- (BOOL)shouldShow {
  if (_invalidated || !_enabled)
    return NO;
  NSWindow *player = _player;
  if (player == nil || !player.isVisible || player.isMiniaturized)
    return NO;
  // -[NSApplication hide:] orders every one of this app's windows out on its
  // own, overlays included, so this is not what takes them away -- it is what
  // stops a refresh arriving mid-hide from putting them back.
  return !NSApp.isHidden;
}

- (void)teardown {
  for (NSWindow *dim in _dims) {
    [dim orderOut:nil];
  }
  [_dims removeAllObjects];
}

- (void)refresh {
  if (![self shouldShow]) {
    [self teardown];
    return;
  }
  NSWindow *player = _player;
  NSScreen *playerScreen = player.screen;
  const BOOL playerFullScreen =
      (player.styleMask & NSWindowStyleMaskFullScreen) != 0;

  // Rebuilt from scratch rather than diffed. The set is at most a handful of
  // windows, it changes only on a user gesture or a display change, and a
  // rebuild cannot leave a stale overlay on a screen that went away.
  [self teardown];

  for (NSScreen *screen in NSScreen.screens) {
    if (playerFullScreen && screen == playerScreen)
      continue;
    WAMDimWindow *dim =
        [[WAMDimWindow alloc] initWithContentRect:screen.frame
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO
                                           screen:screen];
    dim.releasedWhenClosed = NO;
    dim.opaque = NO;
    dim.hasShadow = NO;
    dim.backgroundColor = [NSColor colorWithWhite:0.0 alpha:_opacity];
    dim.ignoresMouseEvents = YES;
    dim.animationBehavior = NSWindowAnimationBehaviorNone;
    // Same band as the player, so it sits under this window and over every
    // other application's -- not a floating level, which would put it over the
    // player itself and over things it has no business covering.
    dim.level = NSNormalWindowLevel;
    dim.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                             NSWindowCollectionBehaviorStationary |
                             NSWindowCollectionBehaviorIgnoresCycle |
                             NSWindowCollectionBehaviorFullScreenNone;
    [dim setFrame:screen.frame display:NO];
    if (screen == playerScreen) {
      [dim orderWindow:NSWindowBelow relativeTo:player.windowNumber];
    } else {
      // No player window on this screen to sit under, so the top of the normal
      // band is where it belongs.
      [dim orderFrontRegardless];
    }
    [_dims addObject:dim];
  }
}

- (void)invalidate {
  if (_invalidated)
    return;
  _invalidated = YES;
  _enabled = NO;
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self teardown];
}
@end

namespace wam::macos_window_chrome {

int theaterDimOverlayCount() {
  int count = 0;
  for (NSWindow *window in NSApp.windows) {
    if ([window isKindOfClass:[WAMDimWindow class]] && window.isVisible)
      ++count;
  }
  return count;
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
  // The window is going away, so the overlay must go with it -- this is the
  // close/quit half of the cleanup matrix. Explicit rather than left to the
  // controller's own dealloc, so the overlay is gone before the last frame of
  // the window is, not one autorelease pool later.
  if (theaterDim_ != nullptr) {
    WAMTheaterDimController *dim =
        (__bridge_transfer WAMTheaterDimController *)theaterDim_;
    [dim invalidate];
    theaterDim_ = nullptr;
  }
}

// ------------------------------------------------------------- Vivid boost

qreal MacWindowChrome::setVividBoost(qreal boost) {
  requestedVividBoost_ =
      (std::isfinite(boost) && boost > 1.0) ? boost : 1.0;
  const qreal applied =
      wam::macos_window_chrome::setVividBoost(window_, requestedVividBoost_);

  // The headroom watch exists because the ceiling moves with SDR brightness
  // and ambient light while the mode is on. It runs ONLY while the mode is on
  // and does nothing but read one NSScreen property and compare -- but it is
  // still a timer on the GUI thread during playback, so it is stopped rather
  // than merely idled the moment the boost goes back to 1.0.
  if (requestedVividBoost_ > 1.0) {
    if (headroomWatch_ == nullptr) {
      headroomWatch_ = new QTimer(this);
      headroomWatch_->setInterval(2000);
      connect(headroomWatch_, &QTimer::timeout, this,
              &MacWindowChrome::reclampVividBoost);
    }
    headroomWatch_->start();
  } else if (headroomWatch_ != nullptr) {
    headroomWatch_->stop();
  }
  return applied;
}

void MacWindowChrome::reclampVividBoost() {
  if (!(requestedVividBoost_ > 1.0))
    return;
  const qreal current = wam::macos_window_chrome::vividBoost(window_);
  const qreal wanted = std::min<qreal>(
      requestedVividBoost_, wam::macos_window_chrome::screenEdrHeadroom(window_));
  // A hysteresis band, not an exact compare: the headroom reading jitters by
  // small amounts and re-attaching the filter on every tick would be churn on
  // the compositor for a change nobody can see.
  if (std::fabs(current - std::max<qreal>(wanted, 1.0)) < 0.02)
    return;
  wam::macos_window_chrome::setVividBoost(window_, requestedVividBoost_);
}

qreal MacWindowChrome::vividBoost() const {
  return wam::macos_window_chrome::vividBoost(window_);
}

qreal MacWindowChrome::edrHeadroom() const {
  return wam::macos_window_chrome::screenEdrHeadroom(window_);
}

void MacWindowChrome::requestSourceIsHdr(const QUrl &source) {
  if (!source.isLocalFile()) {
    emit sourceIsHdrReady(source, false);
    return;
  }
  NSURL *url = source.toNSURL();
  if (!url) {
    emit sourceIsHdrReady(source, false);
    return;
  }
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  const QUrl requested = source;
  const QPointer<MacWindowChrome> guard(this);
  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                       completionHandler:^{
                         dispatch_async(dispatch_get_main_queue(), ^{
                           MacWindowChrome *self = guard.data();
                           if (self == nullptr)
                             return;
                           bool hdr = false;
                           NSError *error = nil;
                           if ([asset statusOfValueForKey:@"tracks"
                                                    error:&error] ==
                               AVKeyValueStatusLoaded) {
                             hdr = wam::macos_window_chrome::assetHasHdrTransfer(
                                 asset);
                           }
                           emit self->sourceIsHdrReady(requested, hdr);
                         });
                       }];
}

// ------------------------------------------------------------- theater dim

void MacWindowChrome::setTheaterDim(bool enabled, qreal opacity) {
  if (theaterDim_ == nullptr) {
    if (!enabled)
      return; // Nothing built, nothing to take down.
    NSWindow *nsWindow = wam::macos_window_chrome::nsWindowFor(window_);
    if (nsWindow == nil)
      return;
    WAMTheaterDimController *created = [[WAMTheaterDimController alloc]
        initWithPlayerWindow:nsWindow];
    if (created == nil)
      return;
    theaterDim_ = (__bridge_retained void *)created;
  }
  WAMTheaterDimController *dim =
      (__bridge WAMTheaterDimController *)theaterDim_;
  [dim setEnabled:(enabled ? YES : NO)
          opacity:static_cast<CGFloat>(opacity)];
}

bool MacWindowChrome::theaterDimActive() const {
  if (theaterDim_ == nullptr)
    return false;
  WAMTheaterDimController *dim =
      (__bridge WAMTheaterDimController *)theaterDim_;
  return [dim active] == YES;
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

void MacWindowChrome::hideCursorUntilMouseMoves() {
  [NSCursor setHiddenUntilMouseMoves:YES];
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

bool MacWindowChrome::setFillScreenPadded(bool filled) {
  return wam::macos_window_chrome::setFillScreenPadded(window_, filled);
}

void MacWindowChrome::clearFillScreenPadded() {
  wam::macos_window_chrome::clearFillScreenPadded(window_);
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

bool MacWindowChrome::revealInFinder(const QUrl &source) const {
  const bool revealed = wam::macos_window_chrome::revealInFinder(source);
  // One line per explicit user gesture, never per frame. It is also the
  // cheapest signal there is that the caret's URL plumbing reached AppKit
  // with the right file, which is otherwise only observable by watching a
  // Finder window appear.
  qInfo().noquote().nospace()
      << "WAM: reveal in Finder " << (revealed ? "requested for " : "declined ")
      << source.toString();
  return revealed;
}

} // namespace wam::qt
