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
    property bool controlsRevealed: true
    property bool transportUserPositioned: false
    property point transportPosition: Qt.point(0, 0)
    property Item dialogFocusReturnItem: null
    readonly property real titlebarInteractionHeight: visibility === Window.FullScreen
        ? 0
        : SafeArea.margins.top
    readonly property bool nativeDialogVisible: mediaDialog.visible
        || exportDialog.visible || captionDialog.visible || errorDialog.visible

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
            ? -(editor.width + editor.anchors.rightMargin) / 2
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

    function revealControls() {
        fadeTimer.stop();

        if (controller.hasMedia && (!root.active || !stageHover.hovered) && !transport.interactionActive) {
            controlsRevealed = false;
            return;
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

        controlsRevealed = false;
    }

    function hideControlsImmediately() {
        fadeTimer.stop();
        if (!transport.interactionActive)
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

    function toggleMaximized() {
        if (visibility === Window.FullScreen)
            return;
        visibility = visibility === Window.Maximized
            ? Window.Windowed
            : Window.Maximized;
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
            if (!mediaDialog.visible && !exportDialog.visible
                    && !captionDialog.visible && !errorDialog.visible)
                root.restoreDialogFocus();
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
            root.controller.seekRelative(-5);
            root.revealControls();
        }
    }

    Shortcut {
        sequence: "Right"
        context: Qt.ApplicationShortcut
        enabled: root.controller.hasMedia && !root.nativeDialogVisible
        onActivated: {
            root.controller.seekRelative(5);
            root.revealControls();
        }
    }

    FileDialog {
        id: mediaDialog
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

    FileDialog {
        id: exportDialog
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

    FileDialog {
        id: captionDialog
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

    MessageDialog {
        id: errorDialog
        title: "WAM"
        buttons: MessageDialog.Ok
        onAccepted: root.restoreDialogFocusAfterClose()
        onRejected: root.restoreDialogFocusAfterClose()
        onVisibleChanged: {
            if (!visible)
                root.restoreDialogFocusAfterClose();
        }
    }

    Rectangle {
        id: stage
        anchors.fill: parent
        focus: true
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
            onPointChanged: root.revealControls()
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
            onDoubleTapped: eventPoint => {
                const titlebarDoubleClick = root.visibility !== Window.FullScreen
                    && eventPoint.position.y < root.titlebarInteractionHeight;
                if (titlebarDoubleClick)
                    root.toggleMaximized();
                else
                    root.controller.toggleFullscreen();
                root.revealControls();
            }
        }

        FloatingControls {
            id: transport
            x: root.transportUserPositioned ? root.clampTransportX(root.transportPosition.x) : root.defaultTransportX()
            y: root.transportUserPositioned ? root.clampTransportY(root.transportPosition.y) : root.defaultTransportY()
            width: root.quickEditOpen && !transport.suppressed ? Math.min(540, parent.width - editor.width - editor.anchors.rightMargin - SafeArea.margins.left - 24) : Math.min(680, parent.width - SafeArea.margins.left - SafeArea.margins.right - 24)
            height: width < 560 ? 98 : 90
            player: root.controller
            revealed: root.controlsRevealed
            instantHide: !root.active || !stageHover.hovered
            suppressed: (!root.active && root.controller.hasMedia) || (root.quickEditOpen && root.width < 760)
            onInteraction: root.revealControls()
            onInteractionActiveChanged: root.transportInteractionChanged()
            onMoveRequested: (targetX, targetY) => root.moveTransportTo(targetX, targetY)
            onEditRequested: {
                root.quickEditOpen = true;
                root.revealControls();
                editor.forceActiveFocus();
            }
        }

        QuickEditSheet {
            id: editor
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.topMargin: Math.max(16, SafeArea.margins.top + 10)
            anchors.rightMargin: Math.max(16, SafeArea.margins.right + 16)
            anchors.bottomMargin: Math.max(16, SafeArea.margins.bottom + 16)
            player: root.controller
            shown: root.quickEditOpen
            dark: root.darkAppearance
            appearance: root.appearance
            onCloseRequested: {
                root.quickEditOpen = false;
                stage.forceActiveFocus();
                root.revealControls();
            }
            onAppearanceRequested: nextAppearance => {
                root.appearance = nextAppearance;
                if (root.controller.setAppearance)
                    root.controller.setAppearance(nextAppearance);
            }
        }

        Keys.onPressed: event => {
            if (event.matches(StandardKey.Open)) {
                root.openMedia();
                event.accepted = true;
                return;
            }

            if (event.key === Qt.Key_E) {
                root.quickEditOpen = !root.quickEditOpen;
                if (root.quickEditOpen)
                    editor.forceActiveFocus();
                root.revealControls();
                event.accepted = true;
            } else if (event.key === Qt.Key_F) {
                root.controller.toggleFullscreen();
                root.revealControls();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape && root.quickEditOpen) {
                root.quickEditOpen = false;
                stage.forceActiveFocus();
                root.revealControls();
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
            root.rememberDialogFocus();
            mediaDialog.open();
        }

        function onFullscreenToggleRequested() {
            root.visibility = root.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen;
            root.revealControls();
        }

        function onExportSelectionRequested() {
            const suggested = root.suggestedOutputUrl("-wam.mp4");
            if (suggested.length > 0)
                exportDialog.currentFile = suggested;
            root.rememberDialogFocus();
            exportDialog.open();
        }

        function onGenerateCaptionsRequested() {
            const suggested = root.suggestedOutputUrl(".srt");
            if (suggested.length > 0)
                captionDialog.currentFile = suggested;
            root.rememberDialogFocus();
            captionDialog.open();
        }

        function onLastErrorChanged() {
            if (root.controller.lastError.length === 0)
                return;
            errorDialog.text = root.controller.lastError;
            root.rememberDialogFocus();
            errorDialog.open();
        }

        function onPlayingChanged() {
            root.revealControls();
        }

        function onHasMediaChanged() {
            root.revealControls();
        }
    }

    onActiveChanged: {
        if (active)
            revealControls();
        else
            hideControlsImmediately();
    }
}
