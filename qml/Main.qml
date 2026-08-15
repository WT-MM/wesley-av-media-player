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
    property bool quickEditInstantiated: false
    property bool preferencesInstantiated: false
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
    property bool transportUserPositioned: false
    property point transportPosition: Qt.point(0, 0)
    property Item dialogFocusReturnItem: null
    // The window's real AppKit titlebar height, read from the NSWindow once
    // (32pt on macOS 26, 28pt before it) instead of assumed. 0 until the
    // native window exists; Qt's own safe-area inset stands in until then.
    property real nativeTitlebarHeight: 0
    readonly property real titlebarInteractionHeight: visibility === Window.FullScreen
        ? 0
        : (nativeTitlebarHeight > 0 ? nativeTitlebarHeight : SafeArea.margins.top)
    // The current video's native pixel size, read directly from the file via
    // MacWindowChrome::videoNaturalSizeForSource when the source changes, or
    // (0, 0) for audio-only media or before "windowChrome" exists. Drives the
    // native window's aspect-ratio lock and its double-click "Actual Size".
    property size videoNaturalSize: Qt.size(0, 0)
    // The source whose aspect ratio the window has already been snapped to,
    // so a re-open of the same file cannot resize the window a second time
    // (see onVideoNaturalSizeChanged).
    property url snappedSource: ""
    readonly property bool nativeDialogVisible:
        (mediaDialogLoader.item && mediaDialogLoader.item.visible)
        || (exportDialogLoader.item && exportDialogLoader.item.visible)
        || (captionDialogLoader.item && captionDialogLoader.item.visible)
        || (errorDialogLoader.item && errorDialogLoader.item.visible)

    visible: true
    width: 1180
    height: 720
    minimumWidth: 560
    minimumHeight: 360
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

    function openMedia() {
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

    // Cmd+, (StandardKey.Preferences below), the same convention every other
    // macOS app uses. First call instantiates the window (its own
    // Component.onCompleted calls back in to actually show it, mirroring
    // openQuickEdit's lazy-load handshake above); later calls just raise it.
    function showPreferences() {
        if (!preferencesInstantiated) {
            preferencesInstantiated = true;
            return;
        }
        const window = preferencesLoader.item;
        if (!window)
            return;
        window.show();
        window.raise();
        window.requestActivate();
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
        windowChrome.resizeToFitScreen(root.videoNaturalSize.width, root.videoNaturalSize.height);
        return true;
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
        interval: 5000
        repeat: false
        onTriggered: root.hideControlsIfIdle()
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
                errorDialogLoader.active = false;
            }
        }
    }

    Shortcut {
        sequence: "Space"
        context: Qt.ApplicationShortcut
        autoRepeat: false
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.togglePlayPause();
            root.revealControls();
        }
    }

    Shortcut {
        sequence: "Left"
        context: Qt.ApplicationShortcut
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.skipBackward();
            root.revealControls();
        }
    }

    Shortcut {
        sequence: "Right"
        context: Qt.ApplicationShortcut
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.skipForward();
            root.revealControls();
        }
    }

    Shortcut {
        sequence: StandardKey.Preferences
        context: Qt.ApplicationShortcut
        onActivated: root.showPreferences()
    }

    Component {
        id: mediaDialogComponent

        FileDialog {
            title: "Open Media"
            fileMode: FileDialog.OpenFile
            nameFilters: ["Media files (*.mp4 *.mkv *.mov *.avi *.webm *.m4v *.mp3 *.m4a *.wav *.flac *.ogg *.opus *.aac *.ts *.m2ts *.wmv *.flv *.m3u *.m3u8 *.pls *.cue)", "All files (*)"]
            onAccepted: {
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
        id: errorDialogComponent

        MessageDialog {
            title: "WAM"
            buttons: MessageDialog.Ok
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

    Component {
        id: preferencesComponent

        PreferencesWindow {
            player: root.controller
            dark: root.darkAppearance
            Component.onCompleted: root.showPreferences()
        }
    }

    Loader {
        id: preferencesLoader
        active: root.preferencesInstantiated
        sourceComponent: preferencesComponent
    }

    // ApplicationWindow automatically extends `background` to cover the whole
    // window -- including the transparent titlebar strip -- while ordinary
    // content children (the `stage` Item below) stay confined to the safe
    // area. The video has to live here, not under `stage`, or it stops at
    // the safe area's top edge and the titlebar reads as a solid strip
    // instead of video bleeding underneath it.
    background: Rectangle {
        id: videoBackdrop
        color: controller.hasMedia ? "#000000" : root.darkAppearance ? "#111215" : "#f5f5f3"

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
                    duration: root.chromeInstantHide ? 0 : (root.controlsRevealed ? 135 : 85)
                    easing.type: Easing.OutCubic
                }
            }

            Text {
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

        FloatingControls {
            id: transport
            x: root.transportUserPositioned ? root.clampTransportX(root.transportPosition.x) : root.defaultTransportX()
            y: root.transportUserPositioned ? root.clampTransportY(root.transportPosition.y) : root.defaultTransportY()
            width: root.quickEditOpen && !transport.suppressed ? Math.min(540, parent.width - root.quickEditWidth - root.quickEditRightMargin - SafeArea.margins.left - 24) : Math.min(680, parent.width - SafeArea.margins.left - SafeArea.margins.right - 24)
            height: width < 560 ? 98 : 90
            player: root.controller
            revealed: root.controlsRevealed
            instantHide: root.chromeInstantHide
            suppressed: (!root.active && root.controller.hasMedia) || (root.quickEditOpen && root.width < 760)
            onInteraction: root.revealControls()
            onInteractionActiveChanged: root.transportInteractionChanged()
            onMoveRequested: (targetX, targetY) => root.moveTransportTo(targetX, targetY)
            onEditRequested: root.openQuickEdit()
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
                root.openMedia();
                event.accepted = true;
                return;
            }

            if (event.key === Qt.Key_E) {
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

        function onLastErrorChanged() {
            if (root.controller.lastError.length === 0)
                return;
            root.showErrorDialog(root.controller.lastError);
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
            if (typeof windowChrome === "undefined" || !windowChrome || !root.controller.hasMedia) {
                root.videoNaturalSize = Qt.size(0, 0);
                return;
            }
            windowChrome.requestVideoNaturalSize(root.controller.source);
        }
    }

    Connections {
        target: (typeof windowChrome !== "undefined" && windowChrome) ? windowChrome : null

        function onVideoNaturalSizeReady(source, width, height) {
            if (!root.controller.hasMedia || width <= 0 || height <= 0)
                return;
            if (source.toString() !== root.controller.source.toString())
                return;
            root.videoNaturalSize = Qt.size(width, height);
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

    onVideoNaturalSizeChanged: {
        if (typeof windowChrome === "undefined" || !windowChrome)
            return;
        windowChrome.setContentAspectRatio(root.videoNaturalSize.width, root.videoNaturalSize.height);
        // QuickTime snaps its window to a newly opened video's aspect ratio
        // so playback fills it edge to edge with no letterbox bars. Do the
        // same here, but strictly once per source: playback can re-open the
        // same file underneath us (the native decoder falling back to
        // compatibility playback does exactly that), and a second snap would
        // yank the window out from under a size the user -- or the benchmark
        // harness -- had just chosen. (0, 0) means no video track, so the
        // window is left alone instead of being resized.
        if (root.videoNaturalSize.width <= 0 || root.videoNaturalSize.height <= 0)
            return;
        if (root.snappedSource.toString() === root.controller.source.toString())
            return;
        // The benchmark harness owns the window geometry for its runs and its
        // validity checks reject any bounds change it did not make itself.
        if (windowChrome.benchmarkMode)
            return;
        root.snappedSource = root.controller.source;
        windowChrome.snapToVideoAspectRatio(root.videoNaturalSize.width, root.videoNaturalSize.height);
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
}
