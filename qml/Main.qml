pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Window

ApplicationWindow {
    id: root

    // `player` is supplied as a QML context property by the application host.
    readonly property var controller: player
    property int appearance: 0 // Light by default; 1 Dark; 2 Follow system.
    readonly property bool darkAppearance: appearance === 1 || (appearance === 2 && systemPalette.window.hslLightness < 0.5)
    property bool quickEditOpen: false
    // How the next media dialog result is delivered: into this window, or
    // through the app-level opener that may create a new one. See openMedia()
    // and openMediaInNewWindow() below.
    property bool mediaDialogOpensNewWindow: false
    property bool quickEditInstantiated: false
    readonly property real quickEditWidth: Math.min(340, root.width - 24)
    readonly property real quickEditRightMargin: Math.max(16, SafeArea.margins.right + 16)
    property bool controlsRevealed: true
    // True while the pointer is anywhere in the titlebar band (see
    // titlebarBand below). Pins the chrome revealed the same way
    // transport.interactionActive does, so nothing fades out from under a
    // cursor that is on its way to the close button.
    property bool titlebarPinned: false
    // The chrome appears and disappears with no animation when the pointer
    // is not on the window at all (a window that has just gone inactive, or
    // one the pointer left) -- fading in chrome nobody is pointing at reads
    // as a glitch. FloatingControls takes the same flag as `instantHide`, so
    // the band, the floating transport and the native traffic lights all
    // move on one schedule.
    readonly property bool chromeInstantHide: !root.active
        || (!stageHover.hovered && !root.titlebarPinned)
    // "Fill Screen (Padded)" (View menu, Cmd-Shift-F): this window has been
    // blown up to its screen's whole visible frame and the video is
    // letterboxed/pillarboxed inside it with black bars. Per window, and
    // deliberately not persisted -- it is a way of looking at THIS window
    // right now, not a preference.
    //
    // The bars themselves are free: on the layer-presentation route the
    // AVSampleBufferDisplayLayer is already AVLayerVideoGravityResizeAspect
    // over a black layer background (see
    // src/platform/macos/native_layer_host_view.mm), and on the other route
    // videoBackdrop below is already "#000000" whenever media is open. So
    // nothing is drawn for this mode that was not already being drawn, and a
    // padded window with its chrome hidden costs exactly what an unpadded one
    // does.
    property bool fillScreenPadded: false
    property bool transportUserPositioned: false
    property point transportPosition: Qt.point(0, 0)
    property Item dialogFocusReturnItem: null
    // Transient toast state for informational playback notices (fallback
    // continuation, native seeking unavailable). Deliberately not a native
    // or modal surface -- see NoticeToast.qml and showNotice() below.
    property string noticeText: ""
    property bool noticeVisible: false
    // The window's real AppKit titlebar height, read from the NSWindow once
    // (32pt on macOS 26, 28pt before it) instead of assumed. 0 until the
    // native window exists; Qt's own safe-area inset stands in until then.
    property real nativeTitlebarHeight: 0
    readonly property real titlebarInteractionHeight: visibility === Window.FullScreen
        ? 0
        : (nativeTitlebarHeight > 0 ? nativeTitlebarHeight : SafeArea.margins.top)
    // The current video's displayed size, read from the file when the source
    // changes, or (0, 0) for audio-only media or before "windowChrome" exists.
    // Drives the native window's aspect-ratio lock, its aspect snap, its
    // double-click "Actual Size" and its fit-to-screen zoom.
    //
    // Two answers feed it, and the order matters.
    //
    // `assetNaturalSize` is MacWindowChrome's asynchronous AVURLAsset probe --
    // the original and, for MP4/MOV, still the authoritative one: it is what
    // shipped, it applies the track's preferredTransform, and letting anything
    // else win for those containers would change behaviour that is correct.
    //
    // `controller.videoDisplaySize` is the engine that ACTUALLY demuxed the
    // container speaking for itself -- the native backends' Prepared event and
    // mpv's dwidth/dheight. It exists because AVFoundation cannot demux
    // Matroska, WebM or MPEG-TS at all, so the probe above answers (0, 0) for
    // every one of them and every behaviour listed above silently died. Both
    // routes (native and the mpv compatibility fallback) publish it, so a
    // container is fixed wherever it ends up playing.
    //
    // Precedence, not merge: a probe answer for THIS source wins outright, so
    // no MP4 changes its geometry by a single pixel; the backend answer is the
    // fallback that makes the other three containers work; and the last clause
    // -- a probe answer left over from the previous source -- is there only to
    // reproduce the pre-existing behaviour exactly. Before this property
    // existed the old size simply stayed put between a source change and the
    // new probe answer, and it has to keep doing so: dropping to (0, 0) for
    // those few milliseconds would take effectiveMinimumHeight back to 360 and
    // visibly grow a short cinemascope window before the new size snapped it
    // back.
    readonly property size videoNaturalSize:
        (root.assetNaturalSizeCurrent && root.assetNaturalSize.width > 0
            && root.assetNaturalSize.height > 0) ? root.assetNaturalSize
        : (root.backendNaturalSize.width > 0 && root.backendNaturalSize.height > 0)
            ? root.backendNaturalSize
        : root.assetNaturalSize
    // The most recent AVURLAsset answer, and the source it was an answer to.
    // (0, 0) is a real answer and is recorded as one -- it is precisely what
    // AVFoundation says about a Matroska, WebM or MPEG-TS file.
    property size assetNaturalSize: Qt.size(0, 0)
    property url assetNaturalSizeSource: ""
    // Whether the probe has spoken about the media now open. The probe always
    // answers -- MacWindowChrome::requestVideoNaturalSize emits on every path,
    // including the failure ones -- so this always becomes true shortly after
    // a source change, and the aspect snap below can safely wait for it.
    readonly property bool assetNaturalSizeCurrent: root.controller
        && root.controller.hasMedia
        && root.assetNaturalSizeSource.toString() === root.controller.source.toString()
    // PlayerController's answer, mirrored so the binding above re-evaluates on
    // videoDisplaySizeChanged. Guarded for the window before `controller`
    // exists, which QML does reach during component construction.
    readonly property size backendNaturalSize: root.controller
        ? Qt.size(root.controller.videoDisplaySize.width, root.controller.videoDisplaySize.height)
        : Qt.size(0, 0)
    // Whether the title band shows its reveal-in-Finder caret: only for media
    // Finder could actually show, which means a local file. `controller.source`
    // is always a fully-formed URL by the time QML sees it (PlayerController's
    // displayUrlForSource resolves bare paths to file: URLs before committing
    // them), so the scheme is the whole test -- a stream, and no media at all,
    // have no folder to reveal. The matching "and it is still on disk" half of
    // the test lives in MacWindowChrome::revealInFinder, deliberately not here:
    // it is a filesystem hit, and no binding would be re-evaluated if the file
    // were deleted mid-playback anyway.
    readonly property bool titleRevealable: (typeof revealInFinderSupported !== "undefined" && revealInFinderSupported)
        && controller.hasMedia
        && String(controller.source).startsWith("file:")
    // The source whose aspect ratio the window has already been snapped to,
    // so a re-open of the same file cannot resize the window a second time
    // (see onVideoNaturalSizeChanged).
    property url snappedSource: ""
    // True when the process was launched by the benchmark harness -- the
    // window chrome bridge is not guaranteed to exist yet at binding-eval
    // time (see the "typeof windowChrome" guards throughout this file), so
    // this mirrors windowChrome.benchmarkMode defensively.
    readonly property bool benchmarkModeActive: (typeof windowChrome !== "undefined" && windowChrome) ? windowChrome.benchmarkMode : false
    // "window hugs the video" (QuickTime-style floating, no letterbox bars)
    // is only actually in effect windowed, with media loaded whose aspect is
    // known, and never under the benchmark harness -- which owns window
    // geometry outright and rejects any bounds change it did not make
    // itself. onWindowHugsVideoActiveChanged (below) is what schedules the
    // continuous re-snap, so every one of those gates has to live in this
    // single computed property rather than be re-checked ad hoc.
    readonly property bool windowHugsVideoActive: root.controller.windowHugsVideo
        && !root.benchmarkModeActive
        && root.controller.hasMedia
        && root.visibility !== Window.FullScreen
        // Padded fill is the explicit opposite of hugging: the user asked for
        // a screen-sized window with bars. It therefore overrides the setting
        // for as long as it is on, for THIS window only, and unticking is not
        // required (nor is the setting touched -- turning padding off hands
        // the window straight back to whatever hugging was already doing).
        && !root.fillScreenPadded
        && root.videoNaturalSize.width > 0
        && root.videoNaturalSize.height > 0
    // The default 360pt minimum height letterboxes a wide (e.g. cinemascope)
    // video pinned at minimumWidth: the window cannot shrink its height
    // below 360 even though the video itself needs less at that width. While
    // hugging is active, relax the floor to whatever height keeps the
    // minimum-width corner on-aspect, but never raise it above 360 -- a
    // portrait video's derived height is already well above 360, so the
    // ordinary floor stays put and does no harm there.
    readonly property real effectiveMinimumHeight: {
        if (!root.windowHugsVideoActive)
            return 360;
        const derived = root.minimumWidth / (root.videoNaturalSize.width / root.videoNaturalSize.height);
        return derived < 360 ? derived : 360;
    }
    readonly property bool nativeDialogVisible:
        (mediaDialogLoader.item && mediaDialogLoader.item.visible)
        || (exportDialogLoader.item && exportDialogLoader.item.visible)
        || (captionDialogLoader.item && captionDialogLoader.item.visible)
        || (subtitleDialogLoader.item && subtitleDialogLoader.item.visible)
        || (errorDialogLoader.item && errorDialogLoader.item.visible)

    visible: true
    width: 1180
    height: 720
    minimumWidth: 560
    minimumHeight: root.effectiveMinimumHeight
    title: controller.hasMedia && controller.mediaTitle.length > 0 ? controller.mediaTitle + " — WAM" : "WAM"
    color: "transparent"

    // Native titlebar and window controls remain native. Content paints beneath them.
    // Qt ignores these hints on platforms that do not implement an expanded client area.
    flags: Qt.Window | Qt.WindowTitleHint | Qt.WindowSystemMenuHint | Qt.WindowMinMaxButtonsHint | Qt.WindowCloseButtonHint | Qt.ExpandedClientAreaHint | Qt.NoTitleBarBackgroundHint

    SystemPalette {
        id: systemPalette
    }

    function clampTransportX(candidate) {
        const left = Math.max(12, SafeArea.margins.left + 10);
        const right = Math.max(left, stage.width - SafeArea.margins.right - transport.width - 12);
        return Math.max(left, Math.min(right, candidate));
    }

    function clampTransportY(candidate) {
        const top = Math.max(12, SafeArea.margins.top + 10);
        const bottom = Math.max(top, stage.height - SafeArea.margins.bottom - transport.height - 12);
        return Math.max(top, Math.min(bottom, candidate));
    }

    function defaultTransportX() {
        const editorOffset = quickEditOpen && !transport.suppressed
            ? -(quickEditWidth + quickEditRightMargin) / 2
            : 0;
        return clampTransportX((stage.width - transport.width) / 2 + editorOffset);
    }

    function defaultTransportY() {
        return clampTransportY(stage.height - Math.max(12, SafeArea.margins.bottom + 10) - transport.height);
    }

    function moveTransportTo(candidateX, candidateY) {
        transportUserPositioned = true;
        transportPosition = Qt.point(clampTransportX(candidateX), clampTransportY(candidateY));
    }

    // Where the pointer physically is, which is not something the QML scene
    // can answer for the titlebar band on its own: the traffic lights are
    // AppKit views stacked above the scene, so Qt reports a hover *exit* the
    // instant the cursor touches one -- exactly when the chrome has to stay
    // up. MacWindowChrome::pointerInTitlebarBand reads the real pointer
    // position from AppKit instead (src/qt/macos_window_chrome.mm).
    function pointerInTitlebar() {
        if (visibility === Window.FullScreen)
            return false;
        if (typeof windowChrome === "undefined" || !windowChrome)
            return titlebarHover.hovered;
        return windowChrome.pointerInTitlebarBand();
    }

    function revealControls() {
        fadeTimer.stop();

        // With media loaded, the chrome belongs to the pointer: it shows
        // while the pointer is on this window (video surface or titlebar
        // band) and stays hidden otherwise, so background playback and
        // property changes cannot flash it onto an idle screen.
        if (controller.hasMedia && !transport.interactionActive) {
            // Window activation comes through here, and the pointer can
            // already be resting in the band with no hover event to
            // announce it -- ask AppKit rather than assume it is not.
            if (root.active && !stageHover.hovered)
                titlebarPinned = pointerInTitlebar();
            if (!root.active || (!stageHover.hovered && !root.titlebarPinned)) {
                controlsRevealed = false;
                return;
            }
        }

        controlsRevealed = true;
        if (controller.hasMedia && !transport.interactionActive)
            fadeTimer.restart();
    }

    // revealControls() for a gesture that IS the pointer being on this window.
    // The ordinary path asks "is the pointer actually here?" and refuses
    // otherwise, because property changes and background playback must not
    // flash chrome onto an idle screen. A wheel event answers that question by
    // existing -- it is delivered to the window under the cursor -- so this
    // variant skips the gate and still re-arms the idle fade rather than
    // pinning the chrome up.
    function revealControlsForPointerGesture() {
        fadeTimer.stop();
        controlsRevealed = true;
        if (controller.hasMedia && !transport.interactionActive)
            fadeTimer.restart();
    }

    function hideControlsIfIdle() {
        if (!controller.hasMedia)
            return;

        if (transport.interactionActive) {
            controlsRevealed = true;
            return;
        }

        // The idle timeout is the one moment the pointer's real position
        // decides something, so ask for it rather than trusting the last
        // hover event: a cursor parked in the band (over the close button,
        // say) must keep the whole chrome up, and re-arming the timer makes
        // this a re-check rather than a permanent pin.
        if (root.active && pointerInTitlebar()) {
            titlebarPinned = true;
            controlsRevealed = true;
            fadeTimer.restart();
            return;
        }

        titlebarPinned = false;
        controlsRevealed = false;
    }

    function hideControlsImmediately() {
        fadeTimer.stop();
        if (transport.interactionActive)
            return;

        // A hover exit that lands in the titlebar band is not an exit at
        // all: the pointer merely crossed from the QML scene onto the native
        // strip above it. Hiding here is what made the chrome vanish while
        // the user was reaching for the traffic lights.
        if (root.active && pointerInTitlebar()) {
            titlebarPinned = true;
            controlsRevealed = true;
            fadeTimer.restart();
            return;
        }

        titlebarPinned = false;
        controlsRevealed = false;
    }

    function transportInteractionChanged() {
        if (transport.interactionActive) {
            fadeTimer.stop();
            controlsRevealed = true;
        } else {
            revealControls();
        }
    }

    // The empty player's own click, and the drag-and-drop-equivalent gesture:
    // whatever is chosen loads into THIS window.
    function openMedia() {
        mediaDialogOpensNewWindow = false;
        if (controller.openFileDialog)
            controller.openFileDialog();
    }

    // File > Open and Cmd-O, routed here by WindowManager::openMedia(): the
    // chosen file goes back through appHost.openUrl(), which claims an empty
    // window if there is one and otherwise creates a new one. The dialog is
    // hosted by this (already existing) window on purpose -- opening a window
    // up front to receive the result would leave a blank player behind every
    // time the dialog was cancelled.
    function openMediaInNewWindow() {
        mediaDialogOpensNewWindow = true;
        if (controller.openFileDialog)
            controller.openFileDialog();
    }

    function showMediaDialog() {
        rememberDialogFocus();
        if (mediaDialogLoader.item)
            mediaDialogLoader.item.open();
        else
            mediaDialogLoader.active = true;
    }

    function showExportDialog() {
        exportDialogLoader.suggestedFile = suggestedOutputUrl("-wam.mp4");
        rememberDialogFocus();
        if (exportDialogLoader.item) {
            if (exportDialogLoader.suggestedFile.toString().length > 0)
                exportDialogLoader.item.currentFile = exportDialogLoader.suggestedFile;
            exportDialogLoader.item.open();
        } else {
            exportDialogLoader.active = true;
        }
    }

    function showSubtitleDialog() {
        if (subtitleDialogLoader.item)
            subtitleDialogLoader.item.open();
        else
            subtitleDialogLoader.active = true;
    }

    function showCaptionDialog() {
        captionDialogLoader.suggestedFile = suggestedOutputUrl(".srt");
        rememberDialogFocus();
        if (captionDialogLoader.item) {
            if (captionDialogLoader.suggestedFile.toString().length > 0)
                captionDialogLoader.item.currentFile = captionDialogLoader.suggestedFile;
            captionDialogLoader.item.open();
        } else {
            captionDialogLoader.active = true;
        }
    }

    function showErrorDialog(message) {
        errorDialogLoader.pendingText = message;
        rememberDialogFocus();
        if (errorDialogLoader.item) {
            errorDialogLoader.item.text = message;
            errorDialogLoader.item.open();
        } else {
            errorDialogLoader.active = true;
        }
    }

    // Fallback-continuation and seek-unavailable notices: playback kept
    // going, so this never steals focus, never blocks, and needs no
    // acknowledgement -- just a brief toast that fades on its own.
    function showNotice(message) {
        noticeText = message;
        noticeVisible = true;
        noticeHideTimer.restart();
    }

    function dismissNotice() {
        noticeVisible = false;
        noticeHideTimer.stop();
    }

    // ---------------------------------------------------------------------
    // Volume OSD (qml/ValueOsd.qml).
    //
    // Driven IMPERATIVELY from the gestures that change the level -- the
    // scroll handler below, both of the transport's sliders and its mute
    // button, and the maximum-volume clamp -- rather than bound to
    // controller.volume. Two reasons, both real:
    //
    //   * A binding would fire for the seed value WindowManager pushes into
    //     every new controller (seedController), flashing a volume card onto
    //     a window the instant it opens.
    //   * A binding would keep re-laying-out the card's Text on every level
    //     change even while it is invisible, which is exactly the cost the
    //     component promises not to have once faded.
    //
    // Live updating is not lost by doing it this way: every one of those
    // gestures calls in on EVERY delta, so a continuous scroll or slider drag
    // updates the number in the card that is already up.
    function volumeOsdLine() {
        if (root.controller.muted)
            return "Muted";
        return Math.round(root.controller.volume * 100) + "%";
    }

    function showVolumeOsd() {
        if (!root.controller.hasMedia)
            return;
        volumeOsd.show(root.volumeOsdLine());
    }

    // ---------------------------------------------------------------------
    // "Fill Screen (Padded)" -- View menu, Cmd-Shift-F.
    //
    // Grows the window to its screen's whole visible frame and lets the video
    // letterbox inside it; toggling again puts the window back on the exact
    // frame it left (macos_window_chrome remembers the rectangle, per window).
    // Returns false when it could not act, so the caller knows the state did
    // not change.
    function toggleFillScreenPadded() {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return false;
        // Fullscreen owns the frame outright; padding underneath it would be
        // invisible now and a frame AppKit would fight on the way out.
        if (root.visibility === Window.FullScreen)
            return false;
        if (!windowChrome.setFillScreenPadded(!root.fillScreenPadded))
            return false;
        root.fillScreenPadded = !root.fillScreenPadded;
        root.revealControls();
        return true;
    }

    // The remembered pre-fill frame is stale the moment the user issues a
    // different, deliberate geometry command (Actual Size, Fit to Screen):
    // after one of those, "put it back" no longer means anything they asked
    // for. Drop the memory and the mode together rather than leaving a toggle
    // armed on a rectangle that is no longer the answer to any question.
    function forgetFillScreenPadded() {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return;
        windowChrome.clearFillScreenPadded();
        root.fillScreenPadded = false;
    }

    function showQuickEdit() {
        quickEditOpen = true;
        revealControls();
    }

    function openQuickEdit() {
        if (!quickEditInstantiated) {
            // Loader.onLoaded completes the first open after the sheet has
            // been constructed in its hidden state, preserving its entrance.
            quickEditInstantiated = true;
            return;
        }
        showQuickEdit();
    }

    function closeQuickEdit() {
        quickEditOpen = false;
        stage.forceActiveFocus();
        revealControls();
    }

    function toggleQuickEdit() {
        if (quickEditOpen)
            closeQuickEdit();
        else
            openQuickEdit();
    }

    // Preferences is app-level -- ONE window for the whole application, whose
    // changes are mirrored live onto every open player (see
    // WindowManager::showPreferences and qml/AppPreferences.qml). A per-window
    // panel would mean N panels disagreeing about one persisted setting.
    function showPreferences() {
        appHost.showPreferences();
    }

    // The app-level "h" macro: pause every window, then hide the whole
    // application. Unhiding restores the windows exactly as they were, still
    // paused -- nothing resumes on its own.
    function hideAndPauseAll() {
        appHost.hideAndPauseAll();
    }

    // Called by WindowManager the moment this window's chrome bridge exists.
    //
    // The bridge cannot be constructed before the QQuickWindow it wraps, so it
    // is necessarily published into this window's QML context AFTER
    // Component.onCompleted has already run with the name undefined -- and
    // `typeof windowChrome` is deliberately not a binding dependency, so
    // nothing re-evaluates on its own. This is the hook that lets the window
    // adopt the bridge at the first instant it exists: read the real AppKit
    // titlebar height instead of falling back to Qt's safe-area inset, and arm
    // the interactive aspect lock.
    function adoptWindowChrome() {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return;
        nativeTitlebarHeight = windowChrome.titlebarHeight();
        applyWindowAspectLock();
        revealControls();
    }

    function toggleMaximized() {
        if (visibility === Window.FullScreen)
            return;
        visibility = visibility === Window.Maximized
            ? Window.Windowed
            : Window.Maximized;
    }

    // QuickTime's View > Actual Size, reachable by double-clicking the
    // titlebar band. Returns false (a no-op) until the video's native pixel
    // size has been probed, so callers can fall back to the ordinary
    // titlebar double-click behavior.
    function resizeToActualSize() {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return false;
        if (root.videoNaturalSize.width <= 0 || root.videoNaturalSize.height <= 0)
            return false;
        root.forgetFillScreenPadded();
        windowChrome.resizeToActualSize(root.videoNaturalSize.width, root.videoNaturalSize.height);
        return true;
    }

    // QuickTime's zoom, reachable by double-clicking the video: fill the
    // screen's visible frame as far as the video's aspect ratio allows,
    // centered, and toggle back to the previous frame on a second
    // double-click. Deliberately not fullscreen -- that stays on F and the
    // transport's own button. Returns false when the native window bridge is
    // unavailable so the caller can fall back.
    function resizeToFitScreen() {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return false;
        if (visibility === Window.FullScreen)
            return false;
        root.forgetFillScreenPadded();
        windowChrome.resizeToFitScreen(root.videoNaturalSize.width, root.videoNaturalSize.height);
        return true;
    }

    // "window hugs the video": re-snap the windowed frame to the current
    // video's aspect ratio whenever something has left it off-aspect --
    // a programmatic/AX resize (the benchmark harness's own resizes are
    // excluded via windowHugsVideoActive's benchmarkModeActive gate), the
    // minimumHeight clamp engaging, or a media change to a different aspect.
    // Always called off hugsVideoResnapTimer's debounce, never directly from
    // a width/height change, so it only ever observes settled geometry.
    // The other half of "window hugs the video", and the half that acts during
    // an interactive drag: macos_window_chrome's InteractiveAspectLock is what
    // keeps a mouse resize on-aspect between mouse-down and mouse-up, where a
    // programmatic re-snap must never interfere. It therefore has to follow
    // the setting live -- (0, 0) releases it, which is exactly what restores
    // the free-form resizing (bars allowed) the Preferences copy promises when
    // the box is unticked. Called from both the media-size change and the
    // setting change, so unticking takes effect on the very next drag rather
    // than at the next launch.
    function applyWindowAspectLock() {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return;
        if (root.windowHugsVideoActive)
            windowChrome.setContentAspectRatio(root.videoNaturalSize.width, root.videoNaturalSize.height);
        else
            windowChrome.setContentAspectRatio(0, 0);
    }

    function maybeResnapToHugVideo() {
        if (!root.windowHugsVideoActive)
            return;
        if (typeof windowChrome === "undefined" || !windowChrome)
            return;
        // The interactive drag itself is already aspect-locked by AppKit
        // (see macos_window_chrome.mm's InteractiveAspectLock), but a
        // programmatic snap issued mid-drag is exactly the kind of fight
        // this feature must never start.
        if (windowChrome.interactiveResizeActive())
            return;
        const aspect = root.videoNaturalSize.width / root.videoNaturalSize.height;
        if (!(aspect > 0))
            return;
        const expectedHeight = root.width / aspect;
        if (Math.abs(expectedHeight - root.height) <= 1)
            return;
        windowChrome.snapToVideoAspectRatio(root.videoNaturalSize.width, root.videoNaturalSize.height);
    }

    function rememberDialogFocus() {
        dialogFocusReturnItem = root.activeFocusItem || stage;
    }

    function restoreDialogFocus() {
        const target = dialogFocusReturnItem;
        dialogFocusReturnItem = null;
        if (target && target.visible !== false && target.enabled !== false)
            target.forceActiveFocus(Qt.PopupFocusReason);
        else
            stage.forceActiveFocus(Qt.PopupFocusReason);
    }

    function restoreDialogFocusAfterClose() {
        dialogFocusRestoreTimer.restart();
    }

    function suggestedOutputUrl(suffix) {
        if (!controller.source)
            return "";
        const sourceUrl = controller.source.toString();
        if (!sourceUrl.startsWith("file:"))
            return "";
        const slash = Math.max(sourceUrl.lastIndexOf("/"), sourceUrl.lastIndexOf("\\"));
        const dot = sourceUrl.lastIndexOf(".");
        const stemEnd = dot > slash ? dot : sourceUrl.length;
        return sourceUrl.slice(0, stemEnd) + suffix;
    }

    Component.onCompleted: {
        stage.forceActiveFocus();
        if (controller.appearance !== undefined)
            appearance = controller.appearance;
        if (typeof windowChrome !== "undefined" && windowChrome)
            nativeTitlebarHeight = windowChrome.titlebarHeight();
        revealControls();
    }

    Timer {
        id: fadeTimer
        // QuickTime-feel idle timeout: 3s of no genuine pointer movement
        // fades the chrome (revealControls/hideControlsIfIdle above still
        // pin it while the pointer is on the transport or titlebar band).
        interval: 3000
        repeat: false
        onTriggered: root.hideControlsIfIdle()
    }

    Timer {
        id: hugsVideoResnapTimer
        // Debounced, not immediate: restarted from every width/height change
        // below, so a live drag (already aspect-locked by
        // windowChrome.setContentAspectRatio's interactive lock, and further
        // guarded by interactiveResizeActive() in maybeResnapToHugVideo) or
        // an in-flight zoom animation (resizeToFitScreen/resizeToActualSize,
        // ~240ms) keeps pushing this out instead of racing either one -- it
        // only actually runs once the frame has been still for 200ms.
        interval: 200
        repeat: false
        onTriggered: root.maybeResnapToHugVideo()
    }

    Timer {
        id: dialogFocusRestoreTimer
        // Native macOS sheets report hidden before their close animation has
        // returned key focus. Reapply after that handoff so it is not
        // overwritten by AppKit a moment later.
        interval: 250
        repeat: false
        onTriggered: {
            if (!root.nativeDialogVisible) {
                root.restoreDialogFocus();
                // Native dialogs are uncommon and can retain AppKit objects.
                // Release each closed instance after its sheet animation so
                // blank launch and settled playback pay no permanent cost.
                mediaDialogLoader.active = false;
                exportDialogLoader.active = false;
                captionDialogLoader.active = false;
                subtitleDialogLoader.active = false;
                errorDialogLoader.active = false;
            }
        }
    }

    // Window-scoped, NOT application-scoped. With N player windows open an
    // application-scoped Shortcut is registered N times over, and Qt refuses
    // the whole ambiguous set ("Ambiguous shortcut overload") rather than
    // picking one -- Space would stop working the moment a second window
    // opened. Window scope is also the correct semantics: the transport keys
    // act on the window you are looking at.
    Shortcut {
        sequence: "Space"
        context: Qt.WindowShortcut
        autoRepeat: false
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.togglePlayPause();
            root.revealControls();
        }
    }

    Shortcut {
        sequence: "Left"
        context: Qt.WindowShortcut
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.skipBackward();
            root.revealControls();
        }
    }

    Shortcut {
        sequence: "Right"
        context: Qt.WindowShortcut
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.skipForward();
            root.revealControls();
        }
    }

    // Up/Down step this window's volume by a wheel notch (5%), clamped to the
    // configured maximum, with the same OSD + flash feedback the scroll
    // gesture gives -- the keys and the wheel are one control at two speeds.
    Shortcut {
        sequence: "Up"
        context: Qt.WindowShortcut
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.setVolume(Math.min(root.controller.maximumVolume,
                                               root.controller.volume + 0.05));
            transport.flashVolume();
            root.showVolumeOsd();
            root.revealControls();
        }
    }

    Shortcut {
        sequence: "Down"
        context: Qt.WindowShortcut
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.setVolume(Math.max(0,
                                               root.controller.volume - 0.05));
            transport.flashVolume();
            root.showVolumeOsd();
            root.revealControls();
        }
    }

    Component {
        id: mediaDialogComponent

        FileDialog {
            title: "Open Media"
            fileMode: FileDialog.OpenFile
            nameFilters: ["Media files (*.mp4 *.mkv *.mov *.avi *.webm *.m4v *.mk3d *.mka *.mpg *.mpeg *.3gp *.3g2 *.vob *.ogv *.qt *.mp3 *.m4a *.m4b *.wav *.aiff *.aif *.flac *.ogg *.oga *.opus *.aac *.ac3 *.eac3 *.dts *.caf *.amr *.w64 *.wma *.ts *.m2ts *.mts *.wmv *.asf *.flv *.m3u *.m3u8 *.pls *.cue)", "All files (*)"]
            onAccepted: {
                if (root.mediaDialogOpensNewWindow)
                    appHost.openUrl(selectedFile);
                else
                    root.controller.open(selectedFile);
                root.revealControls();
                root.restoreDialogFocusAfterClose();
            }
            onRejected: root.restoreDialogFocusAfterClose()
            onVisibleChanged: {
                if (!visible)
                    root.restoreDialogFocusAfterClose();
            }
        }
    }

    Loader {
        id: mediaDialogLoader
        active: false
        sourceComponent: mediaDialogComponent
        onLoaded: item.open()
    }

    Component {
        id: exportDialogComponent

        FileDialog {
            title: "Export Selection"
            fileMode: FileDialog.SaveFile
            defaultSuffix: "mp4"
            nameFilters: ["MP4 video (*.mp4)"]
            onAccepted: {
                root.controller.exportSelectionTo(selectedFile);
                root.restoreDialogFocusAfterClose();
            }
            onRejected: root.restoreDialogFocusAfterClose()
            onVisibleChanged: {
                if (!visible)
                    root.restoreDialogFocusAfterClose();
            }
        }
    }

    Loader {
        id: exportDialogLoader
        property url suggestedFile: ""
        active: false
        sourceComponent: exportDialogComponent
        onLoaded: {
            if (suggestedFile.toString().length > 0)
                item.currentFile = suggestedFile;
            item.open();
        }
    }

    Component {
        id: captionDialogComponent

        FileDialog {
            title: "Save Captions"
            fileMode: FileDialog.SaveFile
            defaultSuffix: "srt"
            nameFilters: ["SubRip captions (*.srt)"]
            onAccepted: {
                root.controller.generateCaptionsTo(selectedFile);
                root.restoreDialogFocusAfterClose();
            }
            onRejected: root.restoreDialogFocusAfterClose()
            onVisibleChanged: {
                if (!visible)
                    root.restoreDialogFocusAfterClose();
            }
        }
    }

    Loader {
        id: captionDialogLoader
        property url suggestedFile: ""
        active: false
        sourceComponent: captionDialogComponent
        onLoaded: {
            if (suggestedFile.toString().length > 0)
                item.currentFile = suggestedFile;
            item.open();
        }
    }

    Component {
        id: subtitleDialogComponent

        FileDialog {
            title: "Load Subtitle File"
            fileMode: FileDialog.OpenFile
            nameFilters: [
                "Subtitle files (*.srt *.vtt *.ass *.ssa)",
                "SubRip (*.srt)",
                "WebVTT (*.vtt)",
                "SubStation Alpha (*.ass *.ssa)",
                "All files (*)"
            ]
            onAccepted: {
                root.controller.loadSubtitleFile(selectedFile);
                root.restoreDialogFocusAfterClose();
            }
            onRejected: root.restoreDialogFocusAfterClose()
            onVisibleChanged: {
                if (!visible)
                    root.restoreDialogFocusAfterClose();
            }
        }
    }

    Loader {
        id: subtitleDialogLoader
        active: false
        sourceComponent: subtitleDialogComponent
        onLoaded: item.open()
    }

    Component {
        id: errorDialogComponent

        // Deliberately a QML Dialog (QtQuick.Controls), not the native
        // QtQuick.Dialogs MessageDialog: on macOS that backs onto NSAlert,
        // whose modal session blocks QCoreApplication::quit() from ever
        // completing while it is open (aboutToQuit never fires). This stays
        // for genuine errors -- cases where playback did not continue -- so
        // it keeps the blocking, must-acknowledge presentation, but as an
        // ordinary Qt Quick popup that the app's own event loop owns, quit
        // closes it along with everything else instead of being vetoed by it.
        Dialog {
            id: errorDialog
            property alias text: errorMessage.text
            title: "WAM"
            modal: true
            focus: true
            standardButtons: Dialog.Ok
            // Not `parent`: this Dialog is instantiated under a plain,
            // zero-sized Loader (errorDialogLoader), so centering on its
            // literal QML parent pins it to the Loader's origin instead of
            // the window. Overlay.overlay is the documented target for
            // centering a Popup/Dialog on the window it's shown in.
            anchors.centerIn: Overlay.overlay
            closePolicy: Popup.CloseOnEscape
            // Fixes the dialog's width instead of letting it derive from the
            // content Label's implicitWidth: with wrapMode active, that
            // default derivation is circular (Dialog.qml's own implicitWidth
            // binding depends on contentItem.implicitWidth, which here would
            // depend back on the width the Dialog just handed it) and Qt
            // reports it as a binding loop every time the dialog opens.
            implicitWidth: 360

            contentItem: Label {
                id: errorMessage
                width: errorDialog.availableWidth
                wrapMode: Text.WordWrap
                // The Basic style's default Label color can end up too close
                // to the dialog's own background to read; the dialog's own
                // palette (which already tracks light/dark) is the
                // authoritative contrasting color here.
                color: errorDialog.palette.text
            }

            onAccepted: root.restoreDialogFocusAfterClose()
            onRejected: root.restoreDialogFocusAfterClose()
            onVisibleChanged: {
                if (!visible)
                    root.restoreDialogFocusAfterClose();
            }
        }
    }

    Loader {
        id: errorDialogLoader
        property string pendingText: ""
        active: false
        sourceComponent: errorDialogComponent
        onLoaded: {
            item.text = pendingText;
            item.open();
        }
    }

    // Belt and suspenders alongside the non-native Dialog above: an orderly
    // quit closes the error dialog itself rather than leaving it as the last
    // thing left standing when the window tears down.
    Connections {
        target: Qt.application
        function onAboutToQuit() {
            if (errorDialogLoader.item)
                errorDialogLoader.item.close();
        }
    }

    // The desktop menu bar is NOT instantiated here. It is app-level and
    // created once by WindowManager (qml/AppMenu.qml), because it has to
    // survive the last window closing and must not be installed N times over.
    // It follows the focused window through appHost.focusedController.

    // ApplicationWindow automatically extends `background` to cover the whole
    // window -- including the transparent titlebar strip -- while ordinary
    // content children (the `stage` Item below) stay confined to the safe
    // area. The video has to live here, not under `stage`, or it stops at
    // the safe area's top edge and the titlebar reads as a solid strip
    // instead of video bleeding underneath it.
    background: Rectangle {
        id: videoBackdrop
        // On the layer presentation route the video is composited by
        // WindowServer from an AVSampleBufferDisplayLayer underneath Qt's view,
        // so this backdrop has to become a transparent hole once media is open
        // or it paints opaque black straight over the video. The no-media
        // colours are unchanged: with nothing playing there is no layer content
        // to reveal.
        color: controller.hasMedia
               ? (layerPresentation ? "transparent" : "#000000")
               : root.darkAppearance ? "#111215" : "#f5f5f3"

        Behavior on color {
            ColorAnimation {
                duration: 160
            }
        }

        MpvVideo {
            id: video
            anchors.fill: parent
            controller: root.controller
            Accessible.name: "Video"
        }

        // The QuickTime titlebar: one band across the top of the window
        // frame carrying the native traffic lights (AppKit draws those over
        // this rectangle) and the media's filename, revealed and faded on
        // exactly the schedule the floating transport and the traffic lights
        // use (setTitlebarControlsRevealed, src/qt/macos_window_chrome.mm)
        // so all three read as one motion.
        //
        // It lives here in `background`, not under `stage`, for the same
        // reason `video` does (see the comment on `background` above):
        // ordinary content children are confined to the safe area below the
        // titlebar, so a band anchored inside `stage` starts *below* the
        // traffic lights. `videoBackdrop` is the one layer Qt Quick Controls
        // extends to the window's true top edge, which is where the band has
        // to start for its top row of pixels to be the window's own.
        Rectangle {
            id: titlebarBand
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: root.titlebarInteractionHeight
            // Near-black at ~83% -- the same glass alpha FloatingControls
            // uses. The video underneath registers as a faint tint rather
            // than a picture: a lighter scrim lets bright content (colour
            // bars, a white shot) wash the band out and swallow both the
            // filename and the traffic lights.
            color: "#d5121215"
            // Deliberately never `visible: false`: a hidden item takes no
            // hover or clicks, and this band still has to notice the pointer
            // arriving while the chrome is faded out -- that is what brings
            // the chrome back when the pointer enters over the titlebar.
            opacity: root.controller.hasMedia
                && root.controlsRevealed
                && root.visibility !== Window.FullScreen ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    // Reveal stays a snappy 135ms; the idle fade-out is a
                    // smooth but quick 250ms -- both OutCubic, matching the
                    // floating transport's own Behavior on opacity so the
                    // band, the transport and the traffic lights (native,
                    // src/qt/macos_window_chrome.mm) read as one motion.
                    // The pointer-left-window path stays instant (0ms).
                    duration: root.chromeInstantHide ? 0 : (root.controlsRevealed ? 135 : 250)
                    easing.type: Easing.OutCubic
                }
            }

            Text {
                id: titleLabel
                anchors.centerIn: parent
                // The traffic lights occupy the leftmost ~71pt of the band;
                // reserving that much on both sides keeps the title centred
                // in the window (as macOS centres it) instead of centred in
                // the leftover space, and keeps long names off the buttons.
                width: Math.min(implicitWidth, Math.max(0, parent.width - 2 * 84))
                text: root.controller.hasMedia ? root.controller.mediaTitle : ""
                color: "#ffffff"
                // macOS draws window titles in the system UI font at 13pt,
                // semibold (NSFont.titleBarFont).
                font.family: ".AppleSystemUIFont"
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideMiddle
                horizontalAlignment: Text.AlignHCenter
                // The window's native `title` already carries this text to
                // accessibility clients even with titleVisibility hidden;
                // this label is a sighted-only restatement of it, not a
                // second source of truth.
                Accessible.ignored: true
            }

            // Reveal in Finder: a small chevron sitting just off the end of
            // the filename, the same gesture macOS puts behind a document
            // window's proxy title.
            //
            // Anchored to the title's right edge rather than laid out with it
            // inside a centred Row, which was the other candidate. Two things
            // decided it: the filename keeps the exact position macOS centres
            // a window title at -- the existing centring and elide-width maths
            // are untouched -- and, because the caret comes and goes with the
            // source (local file yes, stream no), a Row would slide the
            // filename sideways on every such change. The group therefore
            // reads as "title, centred, with a caret hung off it" rather than
            // as a centred pair, which is also how it looks. Measured off a
            // 480pt-wide window: the filename's own centre lands 0.2pt from
            // the window centre (i.e. exactly where it was before), and the
            // filename-plus-caret pair centres 7pt right of it -- under 1.5%
            // of the window's width, well below the offset at which a title
            // stops reading as centred.
            //
            // It inherits the band's opacity, so it fades in and out with the
            // filename and the traffic lights on one schedule; it adds no
            // timer and no animation that runs while the chrome is hidden.
            Item {
                id: revealCaret
                anchors.left: titleLabel.right
                // Negative because the margin is measured to the edge of the
                // hit box, not to the ink: the chevron is 9pt of ink centred
                // in a 22pt box, so it already starts 6.5pt inside. At +2 the
                // measured gap from the filename's last glyph to the caret's
                // first stroke was 10pt, which read as detached; -2 puts it
                // at 6pt, where it reads as belonging to the name.
                anchors.leftMargin: -2
                anchors.verticalCenter: titleLabel.verticalCenter
                // The hit target, not the glyph: a comfortable 22pt box
                // around ~9x4pt of ink.
                width: 22
                height: 22
                visible: root.titleRevealable
                // The band is deliberately never `visible: false` (see the
                // note on its opacity above) so it can still catch the
                // pointer arriving while the chrome is faded out. Without
                // this the caret would inherit that and take clicks while
                // invisible. Entering the band reveals the chrome first, so
                // this costs the user nothing.
                enabled: root.controlsRevealed

                Accessible.role: Accessible.Button
                Accessible.name: "Show in Finder"
                Accessible.description: "Show in Finder"
                Accessible.onPressAction: revealCaret.reveal()

                function reveal() {
                    if (typeof windowChrome !== "undefined" && windowChrome)
                        windowChrome.revealInFinder(root.controller.source);
                    // Finder takes activation from here, which fades this
                    // window's chrome out. Re-arming the idle timer keeps the
                    // band up for the moment the pointer is still on it.
                    root.revealControls();
                }

                // The same hover and pressed washes IconButton uses for the
                // floating transport's controls, at the same radius, so the
                // one control in the titlebar reacts exactly like the ones
                // below it.
                Rectangle {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    radius: width / 2
                    color: revealTap.pressed
                        ? "#44ffffff"
                        : caretHover.hovered ? "#2dffffff" : "transparent"

                    Behavior on color {
                        ColorAnimation {
                            duration: 100
                        }
                    }
                }

                Canvas {
                    anchors.fill: parent
                    // Ink box [0.31, 0.69] x [0.415, 0.585] of the 22pt hit
                    // box: ~8.4pt wide, ~3.7pt tall, centred on (0.5, 0.5).
                    // Deliberately smaller and quieter than a transport icon
                    // -- it has to sit beside 13pt text without competing
                    // with it for the eye.
                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        // Soft white at ~65%: present next to the title's
                        // solid white, never louder than it.
                        ctx.strokeStyle = "#a6ffffff";
                        ctx.lineWidth = 1.5;
                        ctx.lineCap = "round";
                        ctx.lineJoin = "round";
                        ctx.beginPath();
                        ctx.moveTo(width * 0.31, height * 0.415);
                        ctx.lineTo(width * 0.5, height * 0.585);
                        ctx.lineTo(width * 0.69, height * 0.415);
                        ctx.stroke();
                    }
                }

                HoverHandler {
                    id: caretHover
                    cursorShape: Qt.PointingHandCursor
                }

                TapHandler {
                    id: revealTap
                    acceptedButtons: Qt.LeftButton
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: revealCaret.reveal()
                }

                ChromeToolTip {
                    text: "Show in Finder"
                    // The band starts at the window's own top edge, so the
                    // ordinary above-the-button placement would put this
                    // outside the window entirely.
                    below: true
                    visible: caretHover.hovered && revealCaret.enabled
                }
            }

            // Hovering the band pins the whole chrome revealed. This handler
            // covers the band except where the traffic lights are: those are
            // AppKit views above the QML scene, so crossing onto one reads
            // here as a hover exit. titlebarPinProbe, not this exit, decides
            // when the pointer has really left -- see pointerInTitlebar().
            HoverHandler {
                id: titlebarHover
                onHoveredChanged: {
                    if (hovered) {
                        root.titlebarPinned = true;
                        root.revealControls();
                    }
                }
            }

            Timer {
                id: titlebarPinProbe
                interval: 180
                repeat: true
                // Runs only in the gap QML hover cannot see: pinned, but with
                // no QML hover to confirm it -- i.e. the pointer is on a
                // traffic light, or has just left the band entirely. Either
                // way it stops within one tick of the pointer leaving.
                running: root.titlebarPinned && !titlebarHover.hovered
                    && root.visibility !== Window.FullScreen
                onTriggered: {
                    if (root.pointerInTitlebar())
                        return;
                    root.titlebarPinned = false;
                    root.revealControls();
                }
            }

            // Fallback for synthetic taps that do reach the QML band (real
            // mouse double-clicks arrive via the native monitor above).
            // Header double-click zooms to the largest screen fit, same as
            // the video area.
            TapHandler {
                acceptedButtons: Qt.LeftButton
                gesturePolicy: TapHandler.DragThreshold
                onDoubleTapped: {
                    if (!root.resizeToFitScreen())
                        root.toggleMaximized();
                    root.revealControls();
                }
            }
        }
    }

    Item {
        id: stage
        anchors.fill: parent
        focus: true

        Item {
            id: emptyState
            anchors.fill: parent
            visible: !root.controller.hasMedia

            Canvas {
                id: emptyMark
                anchors.centerIn: parent
                anchors.verticalCenterOffset: Math.max(0, SafeArea.margins.top / 2)
                width: 64
                height: 54
                opacity: emptyHover.hovered
                    ? (root.darkAppearance ? 0.28 : 0.18)
                    : (root.darkAppearance ? 0.18 : 0.11)
                Accessible.ignored: true

                Behavior on opacity {
                    NumberAnimation {
                        duration: 110
                        easing.type: Easing.OutCubic
                    }
                }

                onPaint: {
                    const ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);

                    // An audiovisual frame: open corners suggest a visual canvas while
                    // the quiet waveform distinguishes it from a photo or play control.
                    ctx.strokeStyle = root.darkAppearance ? "#ffffff" : "#1b1c20";
                    ctx.lineCap = "round";
                    ctx.lineJoin = "round";
                    ctx.lineWidth = 1.6;

                    const left = 9.5;
                    const right = width - 9.5;
                    const top = 8.5;
                    const bottom = height - 8.5;
                    const arm = 8;

                    ctx.beginPath();
                    ctx.moveTo(left + arm, top);
                    ctx.lineTo(left + 2, top);
                    ctx.quadraticCurveTo(left, top, left, top + 2);
                    ctx.lineTo(left, top + arm);

                    ctx.moveTo(right - arm, top);
                    ctx.lineTo(right - 2, top);
                    ctx.quadraticCurveTo(right, top, right, top + 2);
                    ctx.lineTo(right, top + arm);

                    ctx.moveTo(left, bottom - arm);
                    ctx.lineTo(left, bottom - 2);
                    ctx.quadraticCurveTo(left, bottom, left + 2, bottom);
                    ctx.lineTo(left + arm, bottom);

                    ctx.moveTo(right, bottom - arm);
                    ctx.lineTo(right, bottom - 2);
                    ctx.quadraticCurveTo(right, bottom, right - 2, bottom);
                    ctx.lineTo(right - arm, bottom);
                    ctx.stroke();

                    ctx.lineWidth = 2;
                    const centerY = height / 2;
                    const bars = [5, 11, 17, 10, 6];
                    const startX = width / 2 - 10;
                    for (let index = 0; index < bars.length; ++index) {
                        const x = startX + index * 5;
                        const halfHeight = bars[index] / 2;
                        ctx.beginPath();
                        ctx.moveTo(x, centerY - halfHeight);
                        ctx.lineTo(x, centerY + halfHeight);
                        ctx.stroke();
                    }
                }

                Connections {
                    target: root
                    function onDarkAppearanceChanged() {
                        emptyMark.requestPaint();
                    }
                }
            }

            Item {
                // Keep expanded native chrome available for window gestures;
                // the empty-player action starts below the titlebar inset.
                anchors.fill: parent
                anchors.topMargin: root.titlebarInteractionHeight

                Accessible.role: Accessible.Button
                Accessible.name: "Open media"
                Accessible.onPressAction: root.openMedia()

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onTapped: root.openMedia()
                }

                HoverHandler {
                    id: emptyHover
                    cursorShape: Qt.PointingHandCursor
                }
            }
        }

        DropArea {
            anchors.fill: parent
            keys: ["text/uri-list"]
            onEntered: drag => drag.acceptProposedAction()
            onDropped: drop => {
                if (drop.urls.length > 0)
                    root.controller.open(drop.urls[0]);
                root.revealControls();
            }
        }

        HoverHandler {
            id: stageHover
            // The cursor fades with the chrome, the way QuickTime hides it
            // over playing video: blank while the chrome is hidden, ordinary
            // arrow the moment any movement reveals the chrome again.
            cursorShape: (root.controller.hasMedia && !root.controlsRevealed)
                ? Qt.BlankCursor : Qt.ArrowCursor
            // Qt re-delivers a synthetic hover whenever the content under a
            // stationary cursor repaints -- which, over playing video, is
            // every frame. Only genuine pointer travel counts as activity,
            // or the idle fade can never fire while the video plays.
            property point lastActivityPos: Qt.point(-1e6, -1e6)
            onPointChanged: {
                const p = point.scenePosition;
                if (Math.abs(p.x - lastActivityPos.x) <= 2
                        && Math.abs(p.y - lastActivityPos.y) <= 2)
                    return;
                lastActivityPos = Qt.point(p.x, p.y);
                root.revealControls();
            }
            onHoveredChanged: {
                if (hovered)
                    root.revealControls();
                else
                    root.hideControlsImmediately();
            }
        }

        TapHandler {
            acceptedButtons: Qt.LeftButton
            gesturePolicy: TapHandler.DragThreshold
            onTapped: root.revealControls()
            onDoubleTapped: {
                // The titlebar band is above this: `stage` (like all
                // ordinary content children of ApplicationWindow.background)
                // is confined to the safe area below it, so a double-click
                // reaching this handler is always over the video, never the
                // band -- titlebarBand's own TapHandler (background, above)
                // owns QuickTime's View > Actual Size double-click.
                //
                // Double-clicking the video zooms the window to fit the
                // screen (and back), the way QuickTime's green button does.
                // It deliberately does not enter fullscreen; F, Escape and
                // the transport's fullscreen button own that.
                if (root.visibility === Window.FullScreen)
                    root.visibility = Window.Windowed;
                else if (!root.resizeToFitScreen())
                    root.toggleMaximized();
                root.revealControls();
            }
        }

        // Scroll gestures over the video, VLC/IINA style: vertical modulates
        // this window's volume, horizontal sweeps its timeline.
        //
        // A MouseArea rather than a WheelHandler on purpose. WheelHandler is
        // single-axis (its `orientation` property filters events), so two
        // handlers would be needed and the dominant-axis lock would have to
        // be coordinated across them; MouseArea delivers both axes in one
        // callback with the same QQuickWheelEvent payload, `inverted`
        // included. acceptedButtons: Qt.NoButton means it takes no press, no
        // drag and no hover -- stageHover and the TapHandlers above keep
        // every gesture they already own.
        //
        // It is declared BEFORE the transport, the notice toast and the Quick
        // Edit loader, so all of those sit above it and their own wheel
        // blockers get first refusal. Only a wheel genuinely over the picture
        // reaches here.
        //
        // Every field is forwarded untouched to PlayerController::
        // scrollGesture; the normalization lives in C++ (ScrollGestureModel)
        // where it is unit-tested, not in this file.
        MouseArea {
            id: videoScrollArea
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            enabled: root.controller.hasMedia
                && root.controller.scrollGesturesEnabled
            onWheel: wheel => {
                const outcome = root.controller.scrollGesture(
                    wheel.pixelDelta.x, wheel.pixelDelta.y,
                    wheel.angleDelta.x, wheel.angleDelta.y,
                    wheel.inverted, wheel.phase);
                if (outcome === 0) {
                    // Nothing was spent: the gesture is still deciding its
                    // axis, or gestures are off. Do not accept -- something
                    // else may still want it.
                    wheel.accepted = false;
                    return;
                }
                wheel.accepted = true;
                // Both outcomes are chrome interaction: the volume readout
                // and the timeline handle are the feedback, and the reveal
                // has to re-arm the idle fade rather than pin the chrome up.
                if (outcome === 1) {
                    transport.flashVolume();
                    // The reason this exists: the user asked to see the
                    // number, VLC-style, while scrolling over the picture.
                    // Called per admitted delta, so the card that is already
                    // up simply updates.
                    root.showVolumeOsd();
                }
                root.revealControlsForPointerGesture();
            }
        }

        // ------------------------------------------------------------------
        // Subtitles.
        //
        // ONE surface for every source: an embedded text track read by the
        // native route, a track mpv is timing on the compatibility route, the
        // captions whisper generated, or a file the user loaded. The
        // controller decides which of those is speaking; this only draws it,
        // so a line looks identical whichever engine is playing.
        //
        // Deliberately NOT chrome. It does not appear in interactionActive, it
        // never re-arms the idle fade, and it does not move when the transport
        // fades in or out -- subtitles belong to the picture, not to the
        // controls, and a caption that pinned the toolbar up would be a bug.
        // It sits low enough to clear the transport's default slot so the two
        // never fight for the same pixels.
        Item {
            id: subtitleLayer
            objectName: "subtitleLayer"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 24 + SafeArea.margins.left
            anchors.rightMargin: 24 + SafeArea.margins.right
            anchors.bottomMargin: Math.round(Math.max(16, SafeArea.margins.bottom + 10) + transport.height + 10)
            height: subtitleText.implicitHeight
            // No animation and no opacity binding on chrome state: the item is
            // simply present exactly while there is a line to show, so between
            // cue boundaries nothing in this subtree changes and the scene
            // graph is never dirtied by the overlay.
            visible: root.controller.hasMedia && subtitleText.text.length > 0
            z: 1

            Text {
                id: subtitleText
                objectName: "subtitleText"
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(implicitWidth, parent.width)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                // Line breaks inside a cue are the author's, so they are kept;
                // everything else about the payload is plain text by the time
                // it reaches here (ASS override tags stripped, WebVTT inline
                // tags stripped), which is why this is Text.PlainText and not
                // a rich-text surface that a subtitle file could inject into.
                textFormat: Text.PlainText
                text: root.controller.subtitleText
                color: "#ffffff"
                font.pixelSize: Math.max(16, Math.round(Math.min(stage.width, stage.height * 1.6) * 0.032))
                font.weight: Font.DemiBold
                font.family: subtitleFontMetrics.font.family
                // A soft dark shadow rather than a box: readable over both a
                // bright and a dark frame without covering the picture.
                style: Text.Outline
                styleColor: "#c0000000"
                lineHeight: 1.15
                Accessible.role: Accessible.StaticText
                Accessible.name: "Subtitles"
            }

            FontMetrics {
                id: subtitleFontMetrics
            }
        }

        FloatingControls {
            id: transport
            // Read by the WAM_TEST_WINDOW_SCRIPT `report` verb so a scripted
            // round can prove the scroll gesture actually revealed the volume
            // feedback rather than infer it.
            objectName: "transport"
            x: root.transportUserPositioned ? root.clampTransportX(root.transportPosition.x) : root.defaultTransportX()
            y: root.transportUserPositioned ? root.clampTransportY(root.transportPosition.y) : root.defaultTransportY()
            width: root.quickEditOpen && !transport.suppressed ? Math.min(540, parent.width - root.quickEditWidth - root.quickEditRightMargin - SafeArea.margins.left - 24) : Math.min(680, parent.width - SafeArea.margins.left - SafeArea.margins.right - 24)
            height: width < 560 ? 98 : 90
            player: root.controller
            revealed: root.controlsRevealed
            instantHide: root.chromeInstantHide
            suppressed: (!root.active && root.controller.hasMedia) || (root.quickEditOpen && root.width < 760)
            onInteraction: root.revealControls()
            onVolumeOsdRequested: root.showVolumeOsd()
            onInteractionActiveChanged: root.transportInteractionChanged()
            onMoveRequested: (targetX, targetY) => root.moveTransportTo(targetX, targetY)
            onEditRequested: root.openQuickEdit()
        }

        Timer {
            id: noticeHideTimer
            interval: 4000
            onTriggered: root.noticeVisible = false
        }

        // The volume OSD. Top-centre, one titlebar-band's height clear of the
        // top edge.
        //
        // Position justified against the two things it must not fight. The
        // transport lives at the bottom centre (defaultTransportY) and Quick
        // Edit takes the right-hand column (quickEditWidth + its margin), so
        // the top-centre strip is the one large region neither can occupy at
        // any window size -- top-RIGHT would sit under the Quick Edit sheet
        // the moment it opens. Dropping a full band height below the top edge
        // clears the titlebar band's own filename, so a scroll while the
        // chrome is up does not stack two pieces of text.
        //
        // Not inside the faded chrome and not reported into
        // transport.interactionActive: showing the volume must not pin the
        // transport and titlebar on screen. See qml/ValueOsd.qml.
        ValueOsd {
            id: volumeOsd
            objectName: "volumeOsd"
            anchors.horizontalCenter: stage.horizontalCenter
            anchors.top: stage.top
            anchors.topMargin: Math.round(Math.max(20, root.titlebarInteractionHeight + 20))
            referenceWidth: stage.width
            referenceHeight: stage.height
            z: 2
        }

        NoticeToast {
            id: noticeToast
            anchors.horizontalCenter: stage.horizontalCenter
            anchors.bottom: stage.bottom
            // Above the transport's default resting place regardless of
            // where the user has dragged it -- see defaultTransportY().
            anchors.bottomMargin: stage.height - root.defaultTransportY() + 14
            text: root.noticeText
            shown: root.noticeVisible
            onDismissed: root.dismissNotice()
        }

        Component {
            id: quickEditComponent

            QuickEditSheet {
                anchors.fill: parent
                player: root.controller
                shown: root.quickEditOpen
                dark: root.darkAppearance
                appearance: root.appearance
                onShownChanged: {
                    if (shown)
                        forceActiveFocus();
                }
                onCloseRequested: root.closeQuickEdit()
                onAppearanceRequested: nextAppearance => {
                    root.appearance = nextAppearance;
                    if (root.controller.setAppearance)
                        root.controller.setAppearance(nextAppearance);
                }
                Component.onCompleted: root.showQuickEdit()
            }
        }

        Loader {
            id: editorLoader
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.topMargin: Math.max(16, SafeArea.margins.top + 10)
            anchors.rightMargin: root.quickEditRightMargin
            anchors.bottomMargin: Math.max(16, SafeArea.margins.bottom + 16)
            width: root.quickEditWidth
            active: root.quickEditInstantiated
            sourceComponent: quickEditComponent
        }

        Keys.onPressed: event => {
            if (event.matches(StandardKey.Open)) {
                // Cmd-O is one of the three gestures that must produce a NEW
                // window (with Finder-open and argv), unless an empty window
                // is already there to claim it. Loading into the window you
                // are looking at is drag-and-drop, and the empty player's own
                // click -- both of which call root.openMedia() instead.
                appHost.openMedia();
                event.accepted = true;
                return;
            }

            if (event.key === Qt.Key_H) {
                // Pause every window and hide the app. A bare key, bound here
                // rather than as a native menu key equivalent, for the same
                // reason F and E are: an NSMenu key equivalent for an
                // unmodified key intercepts that keystroke application-wide,
                // text fields included. Keys.onPressed on the video stage only
                // ever fires when no text field holds focus, so typing "h"
                // into Quick Edit or Preferences is unaffected.
                root.hideAndPauseAll();
                event.accepted = true;
            } else if (event.key === Qt.Key_E) {
                root.toggleQuickEdit();
                event.accepted = true;
            } else if (event.key === Qt.Key_F) {
                root.controller.toggleFullscreen();
                root.revealControls();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape && root.quickEditOpen) {
                root.closeQuickEdit();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape && root.visibility === Window.FullScreen) {
                root.visibility = Window.Windowed;
                root.revealControls();
                event.accepted = true;
            }
        }
    }

    Connections {
        target: root.controller

        function onOpenFileDialogRequested() {
            root.showMediaDialog();
        }

        function onFullscreenToggleRequested() {
            root.visibility = root.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen;
            root.revealControls();
        }

        function onExportSelectionRequested() {
            root.showExportDialog();
        }

        function onGenerateCaptionsRequested() {
            root.showCaptionDialog();
        }

        function onOpenSubtitleFileDialogRequested() {
            root.showSubtitleDialog();
        }

        function onLastErrorChanged() {
            if (root.controller.lastError.length === 0)
                return;
            root.showErrorDialog(root.controller.lastError);
        }

        function onLastNoticeChanged() {
            if (root.controller.lastNotice.length === 0)
                return;
            root.showNotice(root.controller.lastNotice);
        }

        // A boost that vanished because the maximum-volume preference was
        // lowered under it has a visible cause: the new level appears in the
        // OSD, in this window, at the instant it is applied.
        function onVolumeClamped() {
            root.showVolumeOsd();
        }

        // Keeps the number honest for the whole time the card is up, without
        // paying for a binding when it is not. Every gesture that opens the
        // card already sets the text, so this only catches a level that moved
        // underneath an open card -- and it early-returns (no property write,
        // no layout, no frame) whenever the card is down, which is almost
        // always.
        function onVolumeChanged() {
            if (volumeOsd.shown)
                volumeOsd.text = root.volumeOsdLine();
        }

        function onMutedChanged() {
            if (volumeOsd.shown)
                volumeOsd.text = root.volumeOsdLine();
        }

        function onPlayingChanged() {
            root.revealControls();
        }

        function onHasMediaChanged() {
            root.revealControls();
        }

        function onSourceChanged() {
            // Fires on every successful open, including a direct file-to-file
            // replacement where hasMedia never toggles false. This runs on the
            // GUI thread inside the open, so it must never block: reading a
            // size synchronously here called -[AVURLAsset tracks] with the
            // tracks key unloaded, which does not report (0, 0) as once
            // assumed -- it parses the asset on the calling thread. Measured,
            // that stalled the GUI thread for the whole parse on a cold open,
            // and on a file-to-file replacement it wedged the event loop
            // outright against the session's own in-flight load of the same
            // asset. The asynchronous request delivers identical numbers off
            // the GUI thread and is now the only path.
            // Only the probe's bookkeeping is touched here. The backend half
            // is the controller's own property, cleared by
            // PlayerController::resetTimeline on every media transition, and
            // clearing it from here would race the Prepared event that has
            // very likely already filled it -- on the native route the source
            // change and the display size come out of the same event, in that
            // order.
            //
            // Neither the recorded answer nor the source it belongs to is
            // touched. The recorded source is now, by definition, the previous
            // file's, so assetNaturalSizeCurrent is already false and the
            // recorded size falls through to videoNaturalSize's last-resort
            // clause -- which is precisely the "the old size stays put until
            // the new answer arrives" behaviour this property had before it
            // gained a second feeder, and the reason a file-to-file
            // replacement does not flash the window through a size no video
            // ever had.
            if (typeof windowChrome === "undefined" || !windowChrome || !root.controller.hasMedia)
                return;
            windowChrome.requestVideoNaturalSize(root.controller.source);
        }
    }

    Connections {
        target: (typeof windowChrome !== "undefined" && windowChrome) ? windowChrome : null

        // A (0, 0) answer is now recorded rather than dropped. It used to be
        // dropped because it was the only answer there was and dropping it at
        // least preserved the previous file's size; it is now the load-bearing
        // fact that AVFoundation cannot describe this container -- every
        // Matroska, WebM and MPEG-TS file produces exactly it -- and recording
        // it is what hands the question over to the backend that can.
        function onVideoNaturalSizeReady(source, width, height) {
            if (!root.controller.hasMedia)
                return;
            if (source.toString() !== root.controller.source.toString())
                return;
            root.assetNaturalSize = (width > 0 && height > 0)
                ? Qt.size(width, height)
                : Qt.size(0, 0);
            root.assetNaturalSizeSource = source;
        }

        // Real titlebar double-clicks arrive here, not through the band's
        // TapHandler: AppKit's titlebar drag region consumes them before the
        // QML scene sees them, so the native monitor forwards them (and
        // swallows AppKit's own titlebar-zoom default). Header double-click
        // zooms to the largest screen fit (and back), same as the video --
        // the user expects macOS's titlebar-zoom feel everywhere. Actual
        // Size remains available through resizeToActualSize() for a future
        // menu item.
        function onTitlebarDoubleClicked() {
            if (!root.resizeToFitScreen())
                root.toggleMaximized();
            root.revealControls();
        }
    }

    // QuickTime snaps its window to a newly opened video's aspect ratio so
    // playback fills it edge to edge with no letterbox bars. Do the same here,
    // but strictly once per source: playback can re-open the same file
    // underneath us (the native decoder falling back to compatibility playback
    // does exactly that), and a second snap would yank the window out from
    // under a size the user -- or the benchmark harness -- had just chosen.
    // (0, 0) means no video track, so the window is left alone instead of
    // being resized.
    //
    // A function rather than the body of onVideoNaturalSizeChanged because it
    // now has two triggers. The size itself is one. The other is the AVURLAsset
    // probe finishing: the snap deliberately waits for it (see the
    // assetNaturalSizeCurrent gate below), and when the probe confirms a size
    // the backend had already published, the value does not change and no
    // size-changed signal is emitted -- so waiting on that signal alone would
    // wait forever.
    function snapToSourceAspectOnce() {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return;
        root.applyWindowAspectLock();
        // Let the probe speak first, always. For MP4 and MOV its answer is the
        // authoritative one and it is what shipped; the backend's answer is
        // separately derived and, for a container with a pixel-aspect or
        // clean-aperture atom, need not agree to the pixel. Since the snap
        // happens exactly once per source, whichever answer is in hand at that
        // instant is the one the window keeps -- so the instant is chosen to be
        // after the probe has committed, not before. The wait is bounded: the
        // probe answers unconditionally, including for the containers it cannot
        // read at all, which is precisely how those hand off to the backend.
        if (!root.assetNaturalSizeCurrent)
            return;
        if (root.videoNaturalSize.width <= 0 || root.videoNaturalSize.height <= 0)
            return;
        if (root.snappedSource.toString() === root.controller.source.toString())
            return;
        // POLICY: padded fill SURVIVES a media replacement. The window is a
        // screen-sized frame the user chose to look through, and the next
        // video simply letterboxes to its own shape inside it -- exactly what
        // "fill screen, padded" means. So the QuickTime aspect snap is
        // suppressed here rather than allowed to yank the frame back onto the
        // new video's ratio.
        //
        // The source is still recorded as snapped, on purpose: the snap is a
        // one-shot that belongs to the moment the media opened, and replaying
        // it later -- when padding is eventually switched off, whose whole
        // contract is "put the window back exactly where it was" -- would
        // resize the window to a video the user opened minutes ago.
        if (root.fillScreenPadded) {
            root.snappedSource = root.controller.source;
            return;
        }
        // The benchmark harness owns the window geometry for its runs and its
        // validity checks reject any bounds change it did not make itself.
        if (windowChrome.benchmarkMode)
            return;
        root.snappedSource = root.controller.source;
        windowChrome.snapToVideoAspectRatio(root.videoNaturalSize.width, root.videoNaturalSize.height);
    }

    onVideoNaturalSizeChanged: root.snapToSourceAspectOnce()
    onAssetNaturalSizeCurrentChanged: root.snapToSourceAspectOnce()

    // Continuous "window hugs the video" upkeep. Every one of these can leave
    // the frame off-aspect while hugging is active: a resize (drag, AX/
    // AppleScript, or this very re-snap settling), the setting being flipped
    // on with bars already showing, media changing to a different aspect, or
    // fullscreen exiting back into a stale windowed frame. All three route
    // through the same debounced check; see hugsVideoResnapTimer and
    // maybeResnapToHugVideo above.
    onWidthChanged: hugsVideoResnapTimer.restart()
    onHeightChanged: hugsVideoResnapTimer.restart()
    onWindowHugsVideoActiveChanged: {
        // Arm or release AppKit's interactive aspect lock first: unticking the
        // box has to loosen the very next drag, not only the debounced snap.
        root.applyWindowAspectLock();
        hugsVideoResnapTimer.restart();
    }

    onControlsRevealedChanged: {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return;
        // Same duration and curve as the band's and the transport's own
        // fades, so the traffic lights travel with them.
        windowChrome.setTitlebarRevealed(controlsRevealed, !root.chromeInstantHide);
    }

    onActiveChanged: {
        if (active)
            revealControls();
        else
            hideControlsImmediately();
    }

    // FULLSCREEN TRANSITIONS. Both halves of this are fixes, not upkeep.
    //
    // The traffic lights. macOS does not build a second set of window buttons
    // for fullscreen; it reparents the very NSButton instances the chrome
    // fade has been writing alphaValue onto into the auto-hiding fullscreen
    // titlebar accessory. AppKit's hover-reveal then animates that
    // accessory's POSITION and never touches their alpha -- so a window that
    // entered fullscreen with the chrome faded out (alpha 0) slid three
    // invisible buttons down under the menu bar, and there was no way to
    // click out of fullscreen at all. setTitlebarRevealed now pins them
    // opaque whenever the window is in fullscreen
    // (src/qt/macos_window_chrome.mm); re-asserting it here is what clears
    // the latch left by the last windowed fade on the way IN, and what
    // restores this window's real revealed state on the way OUT.
    //
    // Focus. F and Escape are bare keys handled by stage's Keys.onPressed
    // filter (see the note there), so they only work while `stage` actually
    // holds focus -- and a fullscreen transition is precisely the kind of
    // window-level event that can leave focus on whatever was last clicked.
    // Taking it back here is what makes "press F again to leave" reliable.
    onVisibilityChanged: {
        stage.forceActiveFocus();
        root.reassertTitlebarControls();
        // AppKit's own fullscreen transition animation outlives this signal.
        // One deferred re-assert after it has settled, so the final word on
        // the buttons' alpha is ours and not a state observed mid-transition.
        fullscreenSettleTimer.restart();
    }

    // Always the window's REAL revealed state, never a fullscreen special
    // case. Whether fullscreen overrides it is AppKit's question, not QML's,
    // and only the native side can answer it honestly: Qt's `visibility`
    // flips the instant something asks for fullscreen, while AppKit's own
    // NSWindowStyleMaskFullScreen flips when the transition actually
    // completes -- and measured, the two can disagree for a long time (or
    // forever, if AppKit declines the transition, which it does for a window
    // whose application is not active). setTitlebarControlsRevealed reads the
    // style mask and pins the buttons opaque exactly while it is set, so a
    // window Qt merely *thinks* is fullscreen still fades its chrome
    // correctly.
    function reassertTitlebarControls() {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return;
        windowChrome.setTitlebarRevealed(root.controlsRevealed, false);
    }

    Timer {
        id: fullscreenSettleTimer
        // Comfortably past AppKit's ~0.5s fullscreen transition. Single-shot
        // and armed only by a visibility change, so nothing ticks in steady
        // state.
        interval: 700
        repeat: false
        onTriggered: root.reassertTitlebarControls()
    }

    // Escape leaves fullscreen no matter what holds focus.
    //
    // The bare-key filter on `stage` (Keys.onPressed) cannot promise that: a
    // focused transport button, or anything else that took focus during the
    // transition, swallows the key before the filter ever runs -- and being
    // unable to leave fullscreen is not a cosmetic failure. A window-scoped
    // Shortcut is answered by the window itself regardless of the focus item.
    //
    // It stands down for the two surfaces that legitimately own Escape while
    // they are up (Quick Edit closes on it, a native dialog cancels on it),
    // so this never steals the key from them; the filter on `stage` keeps
    // handling Escape for Quick Edit exactly as before.
    Shortcut {
        sequence: "Escape"
        context: Qt.WindowShortcut
        enabled: root.visibility === Window.FullScreen
            && !root.quickEditOpen
            && !root.nativeDialogVisible
        onActivated: {
            root.visibility = Window.Windowed;
            root.revealControls();
        }
    }

    // Cmd-Shift-F ("Fill Screen (Padded)") is deliberately NOT bound here.
    // It lives only on the View menu item (qml/AppMenuBar.qml), which is a
    // real NSMenu key equivalent -- AppKit dispatches those from
    // -[NSApplication sendEvent:] before the event ever reaches the key
    // window, so a QML Shortcut on the same sequence would be dead code in
    // the normal case and a double-toggle (i.e. a visible no-op) in any case
    // where it was not. One binding, in the place that also makes the gesture
    // discoverable.
}
