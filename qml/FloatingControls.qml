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
    // True for a moment after a scroll gesture changed the volume. It opens
    // the compact flyout, shows the percentage readout beside the wide
    // slider, and counts as transport interaction so the chrome does not fade
    // out from under the feedback it was asked to show.
    property bool volumeFeedback: false
    readonly property bool volumePopupWanted: compact
        && (muteButton.hovered || volumePopupHover.hovered
            || popupVolumeSlider.pressed || root.volumeFeedback)
    // Volume runs to the window's configured "Maximum volume" (Preferences;
    // 100/125/150/200/300/400%, default 200%). Both sliders take this as
    // their `to`, so the track ALWAYS spans 0..maximum whatever it is set to
    // -- the range is re-scaled, never clipped.
    //
    // Unity therefore moves: it sits at travel 1/maximum along the track and
    // is marked there with a tick plus the magnetic snap, the same shape the
    // speed slider gives 1x. 200% puts it at the midpoint (where it has
    // always been), 400% at the quarter point, and 100% at the very right
    // edge -- at which point there is no boost region left at all and the
    // tick is redundant with the end of the track, so it is dropped.
    //
    // Guarded for the moment before `player` has published the property (and
    // for any non-player stand-in): the default matches the setting's own.
    readonly property real maximumVolume: root.player && root.player.maximumVolume > 0
        ? root.player.maximumVolume
        : 2
    readonly property real volumeDetentTravel: 1 / maximumVolume
    readonly property bool volumeBoostAvailable: maximumVolume > 1.0001
    // The readout is deliberately not always on: below unity the track says
    // everything and the chrome stays as quiet as the rest of it. It appears
    // when the level is boosted -- where the number is the difference between
    // "loud" and "clipping" -- and while the level is actively being changed.
    readonly property bool volumeReadoutVisible: root.player.volume > 1.0001
        || volumeSlider.pressed || popupVolumeSlider.pressed
        || root.volumeFeedback

    function formatVolume(volume) {
        return Math.round(volume * 100) + "%";
    }

    // Called by the window when a scroll gesture over the video changed this
    // window's volume.
    function flashVolume() {
        volumeFeedback = true;
        volumeFeedbackTimer.restart();
    }
    // The speed panel's window, and the exact grid the native engine admits.
    // src/media/native_playback_contract.hpp snaps every requested rate onto
    // a multiple of 1/64 inside [0.25, 4] before it reaches the clock, so the
    // slider snaps to the same grid here -- otherwise the label would show a
    // number the engine is not actually playing.
    readonly property real minimumRate: 0.25
    readonly property real maximumRate: 4
    readonly property int rateGrid: 64
    readonly property bool hovered: panelHover.hovered
    // A pointer merely resting on the transport (no button down) counts as
    // "active" too -- otherwise the idle timer in Main.qml can fade the
    // panel out from directly under a stationary cursor that is parked on
    // it, which is exactly the QuickTime-style pin the transport is meant
    // to honor (see Main.qml's hideControlsIfIdle/transportInteractionChanged).
    readonly property bool interactionActive: hovered
        || volumePopupOpen
        || volumeFeedback
        // The speed panel lives in the window overlay, so the pointer can be
        // inside it without ever hovering the transport. Counting it as
        // activity is what stops Main.qml's idle timer fading the chrome out
        // from under an open panel.
        || speedPopup.visible
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
    // A control on this bar changed the level (either slider, or the mute
    // button). The window puts the value on screen in its volume OSD -- the
    // same readout a scroll over the picture produces, so a drag and a scroll
    // give identical feedback. Emitted per move, so a drag updates the card
    // that is already up rather than flickering a new one.
    signal volumeOsdRequested

    function formatStepSeconds(seconds) {
        // seekStepSeconds is always a whole number in practice (the
        // Preferences window only ever writes integers), but it is stored as
        // a double to match seekRelative's signature -- drop a stray ".0".
        return Number(seconds).toFixed(seconds % 1 === 0 ? 0 : 1);
    }

    // Rate <-> slider travel. Logarithmic: t = 0 is 0.25x, t = 1 is 4x, and
    // every doubling costs the same travel, so 0.25-1 and 1-4 get exactly
    // half the track each and 1.0 falls on the midpoint.
    function rateForTravel(travel) {
        return snapRate(Math.pow(2, travel * 4 - 2));
    }

    function travelForRate(rate) {
        const bounded = Math.min(maximumRate, Math.max(minimumRate, rate));
        return (Math.log(bounded) / Math.LN2 + 2) / 4;
    }

    function snapRate(rate) {
        const bounded = Math.min(maximumRate, Math.max(minimumRate, rate));
        return Math.round(bounded * rateGrid) / rateGrid;
    }

    function applyRate(rate) {
        root.player.setRate(snapRate(rate));
    }

    // "2x" for the whole rates the presets use, "1.36x" for a grid step in
    // between -- the same rule the speed button has always used.
    function formatRate(rate) {
        return Number(rate).toFixed(rate % 1 === 0 ? 0 : 2) + "×";
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
    implicitHeight: compact ? 104 : 96
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
    // `suppressed` drives opacity straight to 0 regardless of
    // interactionActive (window deactivated, Quick Edit taking the width),
    // and the panel lives in the window overlay rather than inside the
    // faded item -- so it has to be dismissed rather than left floating over
    // a chrome that is no longer there.
    onSuppressedChanged: {
        if (suppressed)
            speedPopup.close();
    }

    Timer {
        id: volumePopupCloseTimer
        interval: 150
        onTriggered: root.volumePopupOpen = false
    }

    // How long the scroll-gesture feedback stays up after the last delta.
    // Slightly longer than PlayerController's 200 ms gesture settle so the
    // readout survives the pause between a swipe and its momentum tail.
    Timer {
        id: volumeFeedbackTimer
        interval: 900
        onTriggered: root.volumeFeedback = false
    }

    Rectangle {
        id: glass
        anchors.fill: parent
        radius: root.compact ? 14 : 15
        color: "#d51b1b1e"
    }

    // The transport is not the video surface: a wheel over the bar must never
    // reach the window's scroll-gesture handler underneath it. QtQuick
    // Controls' Slider defaults wheelEnabled to false, so without this the
    // wheel would fall straight through the volume slider onto the video's
    // handler and the bar would behave like the picture behind it.
    // acceptedButtons: Qt.NoButton leaves every press, drag and hover to the
    // real controls stacked above and below this.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        // ...but it stands down while a video gesture is already live. The
        // chrome reveals itself in response to the very first scroll, and
        // with the transport parked at the bottom it can appear directly
        // under a cursor that is mid-sweep. Blocking then would kill the
        // gesture the reveal was feedback for. A gesture that STARTS over the
        // bar still finds this armed, which is the case that matters.
        enabled: !root.player.scrollGestureActive
        onWheel: wheel => wheel.accepted = true
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
        // Every cluster shares the transport's centre line -- see the note on
        // the transport Row below.
        anchors.verticalCenter: transport.verticalCenter
        spacing: 0

        IconButton {
            id: muteButton
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            toolTipClearItem: glass
            iconName: root.player.muted || root.player.volume <= 0 ? "volumeMuted" : "volume"
            accessibleName: root.player.muted ? "Unmute" : "Mute"
            // The flyout occupies the space the tip would be lifted into, and
            // says as much as the tip does once it is up.
            toolTip: root.volumePopupOpen ? "" : accessibleName
            onClicked: {
                root.player.toggleMute();
                root.volumeOsdRequested();
                root.interaction();
            }
        }

        Slider {
            id: volumeSlider
            anchors.verticalCenter: parent.verticalCenter
            width: 72
            height: 30
            from: 0
            to: root.maximumVolume
            visible: !root.compact
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            Accessible.name: "Volume"
            Accessible.role: Accessible.Slider
            onMoved: {
                // Magnetic 100% detent, on exactly the arithmetic the scroll
                // gesture uses (PlayerController::snapVolumeToDetent ->
                // ScrollGestureModel), so a drag and a scroll cannot disagree
                // about where unity is.
                const snapped = root.player.snapVolumeToDetent(value);
                if (snapped !== value)
                    value = snapped;
                root.player.setVolume(snapped);
                root.volumeOsdRequested();
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

                // The 100% notch, at 1/maximum along the track: the midpoint
                // of a 0-200% track, the quarter point of a 0-400% one.
                // Enough ink to find unity by eye, quiet enough not to read
                // as a second handle. At a 100% maximum it would land on the
                // track's own right end and say nothing, so it is dropped
                // there along with the boost region it marks.
                Rectangle {
                    visible: root.volumeBoostAvailable
                    x: root.volumeDetentTravel * parent.width - width / 2
                    y: -2
                    width: 1
                    height: 6
                    radius: 0
                    color: "#8cffffff"
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

        // Percentage readout. A Row skips invisible children outright, so it
        // costs no width when hidden and the rest of the bar never moves; it
        // simply appears off the end of the slider the way the elapsed and
        // duration labels sit off the timeline. (Do NOT bind its width to
        // implicitWidth to reserve space -- that is a binding loop.)
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.compact && root.volumeReadoutVisible
            leftPadding: 6
            text: root.formatVolume(root.player.volume)
            // Boost is the one state worth flagging: above unity the stage can
            // clip, so the number goes from quiet grey to the chrome's own
            // full white.
            color: root.player.volume > 1.0001 ? "#f7f7f8" : "#c8ffffff"
            font.pixelSize: 10
            font.weight: Font.Medium
            Accessible.ignored: true
        }
    }

    // Collapsed-width flyout: same glass card, radius and ~135ms fade as the
    // transport itself, holding a vertical slider above the speaker icon.
    Rectangle {
        id: volumePopup
        radius: 14
        color: "#d51b1b1e"
        width: 38
        height: 120
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

        // Same wheel block as the bar: the flyout hangs above the transport,
        // outside its bounds, so it needs its own.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            enabled: !root.player.scrollGestureActive
            onWheel: wheel => wheel.accepted = true
        }

        // The flyout is transient by construction -- it only exists while the
        // user is on the volume control or a scroll gesture is live -- so the
        // number is always shown here rather than gated the way the wide
        // bar's readout is.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 7
            text: root.formatVolume(root.player.volume)
            color: root.player.volume > 1.0001 ? "#f7f7f8" : "#c8ffffff"
            font.pixelSize: 9
            font.weight: Font.Medium
            Accessible.ignored: true
        }

        Slider {
            id: popupVolumeSlider
            orientation: Qt.Vertical
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 8
            width: 24
            height: 84
            from: 0
            to: root.maximumVolume
            hoverEnabled: true
            focusPolicy: Qt.TabFocus
            Accessible.name: "Volume"
            Accessible.role: Accessible.Slider
            onMoved: {
                const snapped = root.player.snapVolumeToDetent(value);
                if (snapped !== value)
                    value = snapped;
                root.player.setVolume(snapped);
                root.volumeOsdRequested();
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

                // The 100% notch, mirrored for the vertical track.
                Rectangle {
                    visible: root.volumeBoostAvailable
                    x: -2
                    y: (1 - root.volumeDetentTravel) * parent.height - height / 2
                    width: 6
                    height: 1
                    color: "#8cffffff"
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

    // The transport trio owns the bar's centre line. A Row only positions its
    // children horizontally, so without the verticalCenter anchors below the
    // two 30pt arrow buttons hung from the top of a 42pt-tall row and sat a
    // full 6pt above the round button's centre -- which is what made the
    // round button read as "not centred between the arrows" even though the
    // horizontal spacing was already exact. The volume and utility clusters
    // anchor to this row's centre for the same reason.
    Row {
        id: transport
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 10
        spacing: root.compact ? 1 : 3

        IconButton {
            id: backButton
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            toolTipClearItem: glass
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
            anchors.verticalCenter: parent.verticalCenter
            iconName: root.player.playing ? "pause" : "play"
            emphasized: true
            compact: true
            toolTipClearItem: glass
            accessibleName: root.player.playing ? "Pause" : "Play"
            toolTip: accessibleName + " (Space)"
            onClicked: {
                root.player.togglePlayPause();
                root.interaction();
            }
        }

        IconButton {
            id: forwardButton
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            toolTipClearItem: glass
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
        anchors.verticalCenter: transport.verticalCenter
        spacing: 0

        QuietButton {
            id: rateButton
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatRate(root.player.rate)
            accessibleName: "Playback speed"
            // The panel answers the question the tip would; leaving the tip
            // up would only stack a second floating card under it.
            toolTip: speedPopup.visible ? "" : "Playback speed"
            toolTipClearItem: glass
            compact: true
            selected: speedPopup.opened
            onClicked: {
                // CloseOnPressOutsideParent deliberately excludes this
                // button, so the press that reaches onClicked while the
                // panel is up is a genuine toggle rather than the
                // close-then-reopen flicker a plain CloseOnPressOutside
                // would produce.
                if (speedPopup.opened)
                    speedPopup.close();
                else
                    speedPopup.open();
                root.interaction();
            }

            // Speed panel. A real Popup rather than a plain Rectangle like
            // the volume flyout, because this one has to answer Escape and a
            // click anywhere outside itself; closePolicy gives both for free.
            // It is parented to the button but lifted clear of the whole
            // panel, so it never covers the scrubber, and it is closed
            // explicitly whenever the chrome is taken away underneath it.
            Popup {
                id: speedPopup

                readonly property real anchorLeft: utilityCluster.x + rateButton.x

                // Narrow windows keep the panel inside the glass; the clamped
                // x expression below assumes width fits with 10px margins.
                width: Math.min(268, root.width - 20)
                padding: 14
                focus: true
                modal: false
                dim: false
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                // Centred on the speed button, then kept inside the panel's
                // own width so it never hangs off the glass.
                x: Math.max(10 - anchorLeft,
                            Math.min(root.width - width - 10 - anchorLeft,
                                     (rateButton.width - width) / 2))
                y: -(utilityCluster.y + rateButton.y) - height - 10

                background: Rectangle {
                    radius: 14
                    color: "#d51b1b1e"

                    // The speed panel floats in the window overlay, above
                    // the transport's own wheel block, so it needs its own or
                    // a wheel over the speed slider would change the volume.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: wheel => wheel.accepted = true
                    }
                }

                enter: Transition {
                    NumberAnimation {
                        property: "opacity"
                        from: 0
                        to: 1
                        duration: 135
                        easing.type: Easing.OutCubic
                    }
                }

                exit: Transition {
                    NumberAnimation {
                        property: "opacity"
                        from: 1
                        to: 0
                        duration: 135
                        easing.type: Easing.OutCubic
                    }
                }

                contentItem: Column {
                    spacing: 9

                    Item {
                        width: parent.width
                        height: 14

                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Speed"
                            color: "#c8ffffff"
                            font.pixelSize: 10
                            font.weight: Font.Medium
                            Accessible.ignored: true
                        }

                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatRate(root.player.rate)
                            color: "#f7f7f8"
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            Accessible.ignored: true
                        }
                    }

                    Slider {
                        id: speedSlider
                        width: parent.width
                        height: 26
                        from: 0
                        to: 1
                        hoverEnabled: true
                        focusPolicy: Qt.TabFocus
                        Accessible.name: "Playback speed"
                        Accessible.role: Accessible.Slider
                        // Live-apply. PlayerController::setRate is a
                        // pitch-preserved, glitch-free change on the native
                        // route and already expects a slider emitting on
                        // every motion event, so the picture and the label
                        // follow the thumb instead of waiting for release.
                        onMoved: {
                            const rate = root.rateForTravel(value);
                            if (rate === 1)
                                value = 0.5; // magnetic detent at 1x
                            root.applyRate(rate);
                            root.interaction();
                        }

                        Binding {
                            target: speedSlider
                            property: "value"
                            value: root.travelForRate(root.player.rate)
                            when: !speedSlider.pressed
                            restoreMode: Binding.RestoreNone
                        }

                        background: Item {
                            x: speedSlider.leftPadding
                            y: speedSlider.topPadding + speedSlider.availableHeight / 2 - 1
                            width: speedSlider.availableWidth
                            height: 2

                            Rectangle {
                                anchors.fill: parent
                                radius: 2
                                color: "#70ffffff"
                            }

                            // Filled from the 1x detent rather than from the
                            // left end: the track then reads as "how far from
                            // normal speed", and the midpoint needs no
                            // separate tick mark to be findable.
                            Rectangle {
                                x: Math.min(0.5, speedSlider.visualPosition) * parent.width
                                width: Math.abs(speedSlider.visualPosition - 0.5) * parent.width
                                height: parent.height
                                radius: 2
                                color: "#d8ffffff"
                            }
                        }

                        handle: Rectangle {
                            x: speedSlider.leftPadding + speedSlider.visualPosition * (speedSlider.availableWidth - width)
                            y: speedSlider.topPadding + speedSlider.availableHeight / 2 - height / 2
                            implicitWidth: 8
                            implicitHeight: 8
                            radius: width / 2
                            color: "white"
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 4

                        Repeater {
                            model: [0.25, 0.5, 1, 1.5, 2, 4]

                            QuietButton {
                                required property real modelData

                                text: Number(modelData).toString()
                                accessibleName: "Speed " + root.formatRate(modelData)
                                compact: true
                                fontSize: 12
                                implicitWidth: Math.max(implicitContentWidth + 14, 34)
                                implicitHeight: 24
                                selected: Math.abs(root.player.rate - modelData) < 1e-9
                                selectedColor: "#f5f5f6"
                                selectedForeground: "#17191e"
                                onClicked: {
                                    root.applyRate(modelData);
                                    root.interaction();
                                }
                            }
                        }
                    }
                }
            }
        }

        IconButton {
            id: captionsButton
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            toolTipClearItem: glass
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
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            toolTipClearItem: glass
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
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            toolTipClearItem: glass
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
