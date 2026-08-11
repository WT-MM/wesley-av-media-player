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
    readonly property bool hovered: panelHover.hovered
    readonly property bool interactionActive: panelDrag.pressed
        || timeline.scrubbing
        || volumeSlider.pressed
        || muteButton.down
        || backButton.down
        || playButton.down
        || forwardButton.down
        || rateButton.down
        || captionsButton.down
        || editButton.down
        || fullscreenButton.down
    signal editRequested
    signal interaction
    signal moveRequested(real targetX, real targetY)

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
            duration: root.instantHide || root.suppressed ? 0 : (root.revealed ? 135 : 85)
            easing.type: Easing.OutCubic
        }
    }

    Rectangle {
        id: glass
        anchors.fill: parent
        radius: root.compact ? 14 : 15
        color: "#d91b1b1e"
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
        onPointChanged: root.interaction()
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
        mediaPosition: root.player.position
        accentColor: root.accentColor
        onPreviewSeekRequested: seconds => {
            root.player.previewSeekTo(seconds);
            root.interaction();
        }
        onSeekRequested: seconds => {
            root.player.seekTo(seconds);
            root.interaction();
        }
        onScrubbingChanged: root.interaction()
    }

    Text {
        anchors.left: timeline.left
        anchors.top: timeline.bottom
        anchors.topMargin: -2
        text: root.formatTime(timeline.displayPosition)
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
        visible: !root.compact

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
                    color: "#45ffffff"
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
            accessibleName: "Back 5 seconds"
            toolTip: "Back 5 seconds (Left Arrow)"
            onClicked: {
                root.player.seekRelative(-5);
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
            accessibleName: "Forward 5 seconds"
            toolTip: "Forward 5 seconds (Right Arrow)"
            onClicked: {
                root.player.seekRelative(5);
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
