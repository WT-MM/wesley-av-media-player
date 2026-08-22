#pragma once

#include <QObject>
#include <QSizeF>
#include <QUrl>

#include <functional>

class QWindow;

namespace wam::macos_window_chrome {

// Reads `source`'s first video track's natural (display) pixel size directly
// from the container via AVFoundation, independent of whichever playback
// backend (native AVFoundation/VideoToolbox route or the libmpv fallback) is
// actually rendering it. PlayerController does not expose decoded video
// dimensions on either backend, so this reads the file itself; an invalid
// QSizeF means `source` is not a local file, has no video track, or could
// not be inspected. Synchronous: intended for one call per newly opened
// local source, not a per-frame or polling query.
[[nodiscard]] QSizeF videoNaturalSizeForSource(const QUrl &source);

// Test-only background launch (the WAM_TEST_BACKGROUND launch seam).
//
// Drops this process to NSApplicationActivationPolicyAccessory, which is the
// one AppKit state that means "I own real, composited, on-screen windows but I
// am not a foreground application": the app leaves the Dock and the menu bar,
// stops being a candidate for activation, and -- if the launch already made it
// active -- resigns activation back to whoever held it. Its windows keep being
// ordered onto the screen and composited by WindowServer exactly as before,
// which is the property the whole measurement methodology depends on; an
// off-screen or occluded window would counterfeit starvation.
//
// Call once, immediately after QGuiApplication exists (NSApp must be there) and
// before any window is shown, so nothing ever gets the chance to activate.
// Pair it with QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM, which is what
// suppresses the Qt cocoa plugin's own launch-time
// -[NSApplication activateIgnoringOtherApps:] -- see main.cpp.
void adoptBackgroundLaunchPolicy();

// Test-only, and the other half of WAM_TEST_BACKGROUND: makes `window` visible
// and unoccluded WITHOUT activating this process.
//
// The accessory policy alone is not enough, and measuring proved it. A
// non-active app's -[NSWindow makeKeyAndOrderFront:] orders the window to the
// front of ITS OWN app's windows, not to the front of the screen, so the window
// lands wherever the active app's windows leave it -- measured at z-index 18 of
// 44 on-screen windows, fully covered. A fully covered window is exactly the
// occlusion counterfeit the benchmark discipline forbids: WindowServer stops
// updating a covered window's backing store, so every drawn-frame fact taken
// through one is unfalsifiable.
//
// Two AppKit facilities fix it and neither one activates:
//   * -orderFrontRegardless puts the window in front of every other
//     application's windows without making this app active or the window key.
//   * NSFloatingWindowLevel parks it in the band above normal windows, so a
//     later activation of some other app cannot bury it again mid-measurement.
// Call once per show. A null or not-yet-native window is a no-op.
void orderFrontWithoutActivating(QWindow *window);

// Hides the whole application, the way Cmd-H does: every window goes away at
// once and comes back exactly as it was when the app is unhidden. WAM pairs
// this with pausing every window (the "h" macro and the View menu's Hide and
// Pause All) so a hidden player is a silent player.
void hideApplication();

// Calls `handler` when macOS asks the application to "reopen" -- a Dock icon
// click, or opening the app while it is already running -- and reports that no
// windows are visible.
//
// WAM is a document-window app that deliberately stays alive with zero windows
// (see QGuiApplication::setQuitOnLastWindowClosed(false) in main.cpp), so
// AppKit's applicationShouldHandleReopen: contract is what turns a Dock click
// on a window-less WAM back into a usable player instead of a no-op. Qt
// installs its own NSApplicationDelegate and exposes no hook for this, so the
// selector is attached to that delegate's class at runtime; if the delegate
// already implements it, the original implementation is still called after the
// handler. Installs once; later calls only replace the handler.
void installApplicationReopenHandler(std::function<void()> handler);

// Calls `handler` whenever macOS hides the application for ANY reason -- WAM's
// own hideApplication(), Cmd-H, Hide Others, or the Dock menu -- so the
// pause-everything half of the Hide and Pause All gesture is identical no
// matter which of them the user reached for. Installs once; later calls only
// replace the handler.
void installApplicationHideObserver(std::function<void()> handler);

// Configures `window`'s NSWindow for QuickTime-Player-style chrome: a
// full-size content view with a transparent titlebar and permanently hidden
// title text, so QML content (the video) paints all the way to the top of
// the window instead of stopping below a solid titlebar strip. Call once,
// after the window's native handle exists. Safe to call more than once; a
// null or not-yet-native window is a no-op.
void installFullSizeContentView(QWindow *window);

// The height, in logical points, of `window`'s real AppKit titlebar band --
// the strip the traffic lights sit in. Read from the NSWindow itself (32pt
// on macOS 26, 28pt on earlier releases) rather than assumed, so the QML
// band in qml/Main.qml lines up with the native buttons on any macOS.
// Returns 0 for a null or not-yet-native window.
[[nodiscard]] qreal titlebarHeight(QWindow *window);

// True while the mouse pointer is inside `window`'s titlebar band. QML
// cannot answer this on its own: the traffic lights are AppKit views stacked
// above the QML scene, so Qt sees a hover *exit* the moment the pointer
// crosses onto one -- precisely when the chrome must stay up. This reads
// NSEvent.mouseLocation against the window's own frame, so it stays true
// across that boundary. False in fullscreen (where the band is inert) and
// for hidden or miniaturized windows.
[[nodiscard]] bool pointerInTitlebarBand(QWindow *window);

// True when `source` names a local file that still exists on disk -- i.e.
// when revealInFinder below would actually have something to show. Two
// conditions, and the QML caret deliberately gates on only the first of them
// (a `file:` scheme, see qml/Main.qml): the on-disk existence check is a
// filesystem hit, which is fine once per click but wrong to re-run on every
// binding evaluation, and nothing would notify a binding if the file were
// deleted mid-playback anyway. So the affordance shows for any local source
// and the reveal itself declines the vanished ones.
[[nodiscard]] bool canRevealInFinder(const QUrl &source);

// Opens a Finder window on `source`'s parent folder with `source` itself
// selected AND scrolled into view, the way "Show in Finder" does everywhere
// else on macOS. Activates Finder -- that is inherent to the gesture, not
// incidental. Returns false, having done nothing at all, for anything
// canRevealInFinder rejects.
//
// Asynchronous in its tail: the call returns as soon as the reveal has been
// handed to Finder, but a second, guarded pass runs ~250ms later on the main
// queue. That pass is not belt-and-braces, it is the fix for a real defect --
// see the comment on the implementation.
bool revealInFinder(const QUrl &source);

// Fades the three traffic-light window buttons in (revealed) or out, mirror-
// ing FloatingControls' own opacity fade (qml/FloatingControls.qml) so the
// titlebar reads as part of the same motion as the floating transport.
// `animated` false mirrors FloatingControls' `instantHide`: jump straight to
// the target alpha with no animation.
void setTitlebarControlsRevealed(QWindow *window, bool revealed,
                                 bool animated);

// Locks interactive (mouse-drag) window resizing to `width`:`height`, and
// *only* interactive resizing. NSWindow.contentAspectRatio is not the
// user-drag-only constraint it is often assumed to be: an accessibility
// resize (AppleScript's `set size of window 1`, which the benchmark harness
// depends on landing exactly) goes through the same constrained path and
// comes back snapped to the ratio -- asking for 1000x500 on a 16:9 video
// yields 889x500. So the ratio is held here and applied to the NSWindow only
// between a mouse-down on the window and the matching mouse-up, which is the
// entire lifetime of a drag-resize and never overlaps a programmatic one.
// A non-positive dimension clears the lock so the window resizes freely.
void setContentAspectRatio(QWindow *window, qreal width, qreal height);

// True for the exact span setContentAspectRatio's interactive-only lock is
// armed on `window` -- from a border mouse-down that starts a drag-resize
// until the matching mouse-up. QML's continuous aspect-hugging re-snap
// (window_hugs_video) reads this so it never fights a live drag, which is
// already aspect-locked on its own for that entire span.
[[nodiscard]] bool interactiveResizeActive(QWindow *window);

// Resizes `window` so a `videoPixelWidth` x `videoPixelHeight` video renders
// at 1:1 native pixels (dividing by the window's screen's backing scale
// factor), centered on that screen and clamped to its visible frame.
void resizeToActualSize(QWindow *window, qreal videoPixelWidth,
                        qreal videoPixelHeight);

// QuickTime's green-button zoom, as a double-click on the video: grows
// `window` to the largest `videoWidth`:`videoHeight` rectangle that fits the
// current screen's visible frame (so the menu bar and Dock stay clear) and
// centers it there. A non-positive video size fills the visible frame
// outright, which is what an audio-only source wants. Calling it again while
// `window` still sits at that fitted frame restores the frame it had before
// the fit, mirroring AppKit's zoom toggle.
void resizeToFitScreen(QWindow *window, qreal videoWidth, qreal videoHeight);

// Snaps `window` to a `videoWidth`:`videoHeight` aspect ratio so freshly
// opened media fills the window edge to edge with no letterbox bars, the way
// QuickTime Player resizes itself when a new video loads. Keeps `window`'s
// current width where possible (falling back to fitting within the screen's
// visible frame, aspect preserved, if that width would not fit) and keeps
// its current on-screen center. This is a one-time programmatic -setFrame:,
// not a persistent constraint -- unlike setContentAspectRatio, it does not
// affect subsequent user drags or programmatic/AppleScript resizes. A
// non-positive dimension is a no-op.
void snapToVideoAspectRatio(QWindow *window, qreal videoWidth,
                            qreal videoHeight);

} // namespace wam::macos_window_chrome

namespace wam::qt {

// Thin QML-invokable adapter over the free functions above. main.cpp installs
// one instance as the "windowChrome" context property once the root QML
// window exists; qml/Main.qml drives it from the same signals that already
// show/hide FloatingControls.
class MacWindowChrome final : public QObject {
  Q_OBJECT

  // True when the process was launched by the benchmark harness (the same
  // WAM_NATIVE_BENCHMARK_TELEMETRY opt-in the telemetry stream keys on). The
  // harness positions the window itself and its validity checks reject any
  // bounds change it did not make, so QML suppresses the QuickTime aspect
  // snap for these runs.
  Q_PROPERTY(bool benchmarkMode READ benchmarkMode CONSTANT)

public:
  explicit MacWindowChrome(QWindow *window, QObject *parent = nullptr);
  ~MacWindowChrome() override;

  [[nodiscard]] bool benchmarkMode() const { return benchmarkMode_; }

  Q_INVOKABLE void setTitlebarRevealed(bool revealed, bool animated = true);
  Q_INVOKABLE void setContentAspectRatio(qreal width, qreal height);
  Q_INVOKABLE bool interactiveResizeActive() const;
  Q_INVOKABLE void resizeToActualSize(qreal videoPixelWidth,
                                      qreal videoPixelHeight);
  Q_INVOKABLE void resizeToFitScreen(qreal videoWidth, qreal videoHeight);
  Q_INVOKABLE void snapToVideoAspectRatio(qreal videoWidth, qreal videoHeight);
  Q_INVOKABLE QSizeF videoNaturalSizeForSource(const QUrl &source) const;
  // Asynchronous variant of videoNaturalSizeForSource: the synchronous read
  // returns (0, 0) on a cold open because the asset's tracks have not loaded
  // yet, which silently skipped both the aspect lock and the aspect snap.
  // Loads the tracks off-thread and answers with videoNaturalSizeReady on the
  // GUI thread; a (0, 0) reply means the source has no readable video track.
  Q_INVOKABLE void requestVideoNaturalSize(const QUrl &source);
  Q_INVOKABLE qreal titlebarHeight() const;
  Q_INVOKABLE bool pointerInTitlebarBand() const;
  // Drives the title band's reveal caret (qml/Main.qml). Returns whether a
  // Finder window was actually asked for, so the caller -- and the log line
  // this leaves behind -- can tell a declined reveal from a completed one.
  Q_INVOKABLE bool revealInFinder(const QUrl &source) const;

signals:
  void videoNaturalSizeReady(const QUrl &source, qreal width, qreal height);
  // A real mouse double-click landed in the titlebar band (outside the
  // traffic lights). QML cannot observe this itself: AppKit's titlebar
  // drag region consumes the click before the QML scene sees it, so a
  // local event monitor detects it natively and swallows AppKit's own
  // titlebar double-click zoom in the same breath.
  void titlebarDoubleClicked();

private:
  QWindow *window_;
  bool benchmarkMode_{false};
  // Retained NSEvent local monitor (id, stored bridge-retained); removed and
  // released in the destructor.
  void *titlebarClickMonitor_{nullptr};
};

} // namespace wam::qt
