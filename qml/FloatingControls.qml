import QtQuick
import QtQuick.Controls

FocusScope {
    id: root

    required property var player
    property bool revealed: true
    property bool suppressed: false
    property bool instantHide: false
    property color accentColor: "#f1f1f2"
    property bool compact: width < 560
    // When the inline slider can't fit, the speaker icon stays in place and
    // a small glass flyout with a vertical slider takes over -- QuickTime-
    // like "always reachable" volume, matched to the transport's own fade
    // timing.
    property bool volumePopupOpen: false
    readonly property bool volumePopupWanted: compact
        && (muteButton.hovered || volumePopupHover.hovered || popupVolumeSlider.pressed)
    readonly property bool hovered: panelHover.hovered
    // A pointer merely resting on the transport (no button down) counts as
    // "active" too -- otherwise the idle timer in Main.qml can fade the
    // panel out from directly under a stationary cursor that is parked on
    // it, which is exactly the QuickTime-style pin the transport is meant
    // to honor (see Main.qml's hideControlsIfIdle/transportInteractionChanged).
    readonly property bool interactionActive: hovered
        || volumePopupOpen
        || panelDrag.pressed
        || timeline.scrubbing
        || volumeSlider.pressed
        || popupVolumeSlider.pressed
        || muteButton.down
        || backButton.down
        || playButton.down
        || forwardButton.down
        || rateButton.down
        || captionsButton.down
        || editButton.down
        || fullscreenButton.down
    readonly property int elapsedWholeSeconds: Math.floor(timeline.displayPosition)
    signal editRequested
    signal interaction
    signal moveRequested(real targetX, real targetY)

    function formatStepSeconds(seconds) {
        // seekStepSeconds is always a whole number in practice (the
        // Preferences window only ever writes integers), but it is stored as
        // a double to match seekRelative's signature -- drop a stray ".0".
        return Number(seconds).toFixed(seconds % 1 === 0 ? 0 : 1);
    }

    function formatTime(seconds) {
        if (!isFinite(seconds) || seconds < 0)
            seconds = 0;
        const total = Math.floor(seconds);
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor((total % 3600) / 60);
        const secs = total % 60;
        if (hours > 0)
            return hours + ":" + String(minutes).padStart(2, "0") + ":" + String(secs).padStart(2, "0");
        return minutes + ":" + String(secs).padStart(2, "0");
    }

    implicitWidth: 660
    implicitHeight: compact ? 98 : 90
    opacity: !player.hasMedia || suppressed ? 0 : (revealed ? 1 : 0)
    enabled: opacity > 0.05 || interactionActive
    visible: opacity > 0 || interactionActive

    Behavior on opacity {
        NumberAnimation {
            // Reveal: snappy 135ms. Idle fade-out: smooth but quick 250ms.
            // Pointer-left-window / suppressed stays instant. Matches the
            // titlebar band's own Behavior on opacity in Main.qml.
            duration: root.instantHide || root.suppressed ? 0 : (root.revealed ? 135 : 250)
            easing.type: Easing.OutCubic
        }
    }

    // A short close delay bridges the few unhovered pixels between the icon
    // and the popup above it, so moving the cursor up into the flyout
    // doesn't flicker the fade.
    onVolumePopupWantedChanged: {
        if (volumePopupWanted) {
            volumePopupCloseTimer.stop();
            volumePopupOpen = true;
        } else {
            volumePopupCloseTimer.restart();
        }
    }
    onCompactChanged: {
        if (!compact)
            volumePopupOpen = false;
    }

    Timer {
        id: volumePopupCloseTimer
        interval: 150
        onTriggered: root.volumePopupOpen = false
    }

    Rectangle {
        id: glass
        anchors.fill: parent
        radius: root.compact ? 14 : 15
        color: "#d51b1b1e"
    }

    // The blank chrome is a drag surface, like QuickTime's floating palette.
    // Interactive children are declared later and stay above this MouseArea, so
    // starting on a timeline, slider, or button never moves the panel.
    MouseArea {
        id: panelDrag
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        preventStealing: true
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

        property real originX: 0
        property real originY: 0
        property point pressInParent: Qt.point(0, 0)

        onPressed: mouse => {
            root.forceActiveFocus();
            originX = root.x;
            originY = root.y;
            pressInParent = root.mapToItem(root.parent, mouse.x, mouse.y);
            root.interaction();
        }
        onPositionChanged: mouse => {
            if (!pressed)
                return;
            const point = root.mapToItem(root.parent, mouse.x, mouse.y);
            root.moveRequested(originX + point.x - pressInParent.x,
                               originY + point.y - pressInParent.y);
            root.interaction();
        }
        onReleased: root.interaction()
        onCanceled: root.interaction()
    }

    HoverHandler {
        id: panelHover
        onHoveredChanged: {
            if (hovered)
                root.interaction();
        }
    }

    Scrubber {
        id: timeline
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: 8
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        height: 24
        to: Math.max(1, root.player.duration)
        // Once the palette has faded out, disconnect its geometry from
        // mpv's frame-rate time-pos notifications. Re-evaluating when it
        // becomes visible snaps directly to the current position.
        mediaPosition: root.visible ? root.player.position : 0
        accentColor: root.accentColor
        onPreviewSeekRequested: seconds => {
            root.player.previewSeekTo(seconds);
        }
        onSeekRequested: seconds => {
            root.player.endScrub(seconds);
            root.interaction();
        }
        onScrubbingChanged: {
            if (scrubbing)
                root.player.beginScrub();
            root.interaction();
        }
    }

    Text {
        anchors.left: timeline.left
        anchors.top: timeline.bottom
        anchors.topMargin: -2
        text: root.formatTime(root.elapsedWholeSeconds)
        color: "#c8ffffff"
        font.pixelSize: 10
        font.weight: Font.Medium
        Accessible.ignored: true
    }

    Text {
        anchors.right: timeline.right
        anchors.top: timeline.bottom
        anchors.topMargin: -2
        text: root.formatTime(root.player.duration)
        color: "#c8ffffff"
        font.pixelSize: 10
        font.weight: Font.Medium
        Accessible.ignored: true
    }

    Row {
        id: volumeCluster
        anchors.left: parent.left
        anchors.leftMargin: 11
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 7
        spacing: 0

        IconButton {
            id: muteButton
            compact: true
            iconName: root.player.muted || root.player.volume <= 0 ? "volumeMuted" : "volume"
            accessibleName: root.player.muted ? "Unmute" : "Mute"
            toolTip: accessibleName
            onClicked: {
                root.player.toggleMute();
                root.interaction();
            }
        }

        Slider {
            id: volumeSlider
            width: 72
            height: 30
            from: 0
            to: 1
            visible: !root.compact
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            Accessible.name: "Volume"
            Accessible.role: Accessible.Slider
            onMoved: {
                root.player.setVolume(value);
                root.interaction();
            }

            Binding {
                target: volumeSlider
                property: "value"
                value: root.player.volume
                when: !volumeSlider.pressed
                restoreMode: Binding.RestoreNone
            }

            background: Item {
                x: volumeSlider.leftPadding
                y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - 1
                width: volumeSlider.availableWidth
                height: 2
                Rectangle {
                    anchors.fill: parent
                    radius: 2
                    color: "#70ffffff"
                }
                Rectangle {
                    width: volumeSlider.visualPosition * parent.width
                    height: parent.height
                    radius: 2
                    color: "#d8ffffff"
                }
            }

            handle: Rectangle {
                x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                implicitWidth: 8
                implicitHeight: 8
                radius: width / 2
                color: "white"
            }
        }
    }

    // Collapsed-width flyout: same glass card, radius and ~135ms fade as the
    // transport itself, holding a vertical slider above the speaker icon.
    Rectangle {
        id: volumePopup
        radius: 14
        color: "#d51b1b1e"
        width: 34
        height: 104
        z: 5
        anchors.horizontalCenter: volumeCluster.horizontalCenter
        anchors.bottom: volumeCluster.top
        anchors.bottomMargin: 6
        opacity: root.volumePopupOpen ? 1 : 0
        visible: opacity > 0
        enabled: opacity > 0.05

        Behavior on opacity {
            NumberAnimation {
                duration: 135
                easing.type: Easing.OutCubic
            }
        }

        HoverHandler {
            id: volumePopupHover
        }

        Slider {
            id: popupVolumeSlider
            orientation: Qt.Vertical
            anchors.centerIn: parent
            width: 24
            height: 84
            from: 0
            to: 1
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            Accessible.name: "Volume"
            Accessible.role: Accessible.Slider
            onMoved: {
                root.player.setVolume(value);
                root.interaction();
            }

            Binding {
                target: popupVolumeSlider
                property: "value"
                value: root.player.volume
                when: !popupVolumeSlider.pressed
                restoreMode: Binding.RestoreNone
            }

            background: Item {
                x: popupVolumeSlider.leftPadding + popupVolumeSlider.availableWidth / 2 - 1
                y: popupVolumeSlider.topPadding
                width: 2
                height: popupVolumeSlider.availableHeight
                Rectangle {
                    anchors.fill: parent
                    radius: 2
                    color: "#70ffffff"
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: popupVolumeSlider.visualPosition * parent.height
                    radius: 2
                    color: "#d8ffffff"
                }
            }

            handle: Rectangle {
                x: popupVolumeSlider.leftPadding + popupVolumeSlider.availableWidth / 2 - width / 2
                y: popupVolumeSlider.topPadding + (1 - popupVolumeSlider.visualPosition) * (popupVolumeSlider.availableHeight - height)
                implicitWidth: 8
                implicitHeight: 8
                radius: width / 2
                color: "white"
            }
        }
    }

    Row {
        id: transport
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 4
        spacing: root.compact ? 1 : 3

        IconButton {
            id: backButton
            compact: true
            iconName: "backward5"
            accessibleName: "Back " + root.formatStepSeconds(root.player.seekStepSeconds) + " seconds"
            toolTip: accessibleName + " (Left Arrow)"
            onClicked: {
                root.player.skipBackward();
                root.interaction();
            }
        }

        IconButton {
            id: playButton
            iconName: root.player.playing ? "pause" : "play"
            emphasized: true
            compact: true
            accessibleName: root.player.playing ? "Pause" : "Play"
            toolTip: accessibleName + " (Space)"
            onClicked: {
                root.player.togglePlayPause();
                root.interaction();
            }
        }

        IconButton {
            id: forwardButton
            compact: true
            iconName: "forward5"
            accessibleName: "Forward " + root.formatStepSeconds(root.player.seekStepSeconds) + " seconds"
            toolTip: accessibleName + " (Right Arrow)"
            onClicked: {
                root.player.skipForward();
                root.interaction();
            }
        }
    }

    Row {
        id: utilityCluster
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 7
        spacing: 0

        QuietButton {
            id: rateButton
            text: Number(root.player.rate).toFixed(root.player.rate % 1 === 0 ? 0 : 2) + "×"
            accessibleName: "Playback speed"
            toolTip: "Playback speed"
            compact: true
            visible: !root.compact
            onClicked: {
                const choices = [0.5, 1, 1.25, 1.5, 2];
                let next = choices.find(value => value > root.player.rate + 0.01);
                if (next === undefined)
                    next = choices[0];
                root.player.setRate(next);
                root.interaction();
            }
        }

        IconButton {
            id: captionsButton
            compact: true
            iconName: "captions"
            accessibleName: root.player.captionsVisible ? "Hide captions" : "Show captions"
            toolTip: accessibleName
            onClicked: {
                root.player.toggleCaptions();
                root.interaction();
            }
        }

        IconButton {
            id: editButton
            compact: true
            iconName: "edit"
            accessibleName: "Quick Edit"
            toolTip: "Open Quick Edit (E)"
            onClicked: {
                root.editRequested();
                root.interaction();
            }
        }

        IconButton {
            id: fullscreenButton
            compact: true
            iconName: "fullscreen"
            accessibleName: "Enter full screen"
            toolTip: "Full screen (F)"
            onClicked: {
                root.player.toggleFullscreen();
                root.interaction();
            }
        }
    }
}
