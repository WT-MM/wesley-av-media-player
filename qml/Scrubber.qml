import QtQuick
import QtQuick.Controls

Slider {
    id: control

    property real mediaPosition: 0
    property real previewPosition: 0
    property real pendingSeek: -1
    property bool awaitingSeek: false
    property color accentColor: "#f1f1f2"
    property string accessibleName: "Playback position"
    readonly property bool scrubbing: scrubArea.pressed
    readonly property real displayPosition: scrubbing || awaitingSeek
        ? boundedValue(previewPosition)
        : boundedValue(mediaPosition)
    signal previewSeekRequested(real seconds)
    signal seekRequested(real seconds)

    from: 0
    to: 1
    value: displayPosition
    // Match WAM's global/VLC-style transport shortcuts even while the
    // timeline owns keyboard focus. A duration-relative step made the same
    // Right Arrow key seek by a different amount after clicking the scrubber.
    stepSize: 5
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    live: true

    Accessible.role: Accessible.Slider
    Accessible.name: accessibleName
    Accessible.description: "Use Left and Right Arrow to seek."
    Accessible.onIncreaseAction: adjustBy(stepSize)
    Accessible.onDecreaseAction: adjustBy(-stepSize)

    function boundedValue(candidate) {
        if (!isFinite(candidate))
            return from;
        return Math.max(from, Math.min(to, candidate));
    }

    function valueForPointer(pointerX) {
        if (availableWidth <= 0)
            return from;
        let normalized = Math.max(0, Math.min(1, (pointerX - leftPadding) / availableWidth));
        if (mirrored)
            normalized = 1 - normalized;
        return valueAt(normalized);
    }

    function dispatchPendingSeek() {
        if (pendingSeek < 0)
            return;
        const seconds = pendingSeek;
        pendingSeek = -1;
        previewSeekRequested(seconds);
        seekThrottle.restart();
    }

    function previewAt(pointerX) {
        previewPosition = boundedValue(valueForPointer(pointerX));
        awaitingSeek = true;
        seekSettleTimer.stop();
        pendingSeek = previewPosition;

        // Send the first preview immediately, then coalesce pointer updates
        // while the independent visual preview stays under the pointer.
        if (!seekThrottle.running) {
            dispatchPendingSeek();
            seekThrottle.start();
        }
    }

    function finishScrub(pointerX, updateFromPointer) {
        if (updateFromPointer)
            previewPosition = boundedValue(valueForPointer(pointerX));
        seekThrottle.stop();
        pendingSeek = -1;
        awaitingSeek = true;
        seekSettleTimer.restart();

        // Always commit the release position. A coalesced update may otherwise
        // leave playback one pointer event behind the handle.
        seekRequested(previewPosition);
    }

    function adjustBy(delta) {
        const target = boundedValue(displayPosition + delta);
        previewPosition = target;
        awaitingSeek = true;
        seekSettleTimer.restart();
        seekRequested(target);
    }

    function seekToFromKeyboard(target) {
        previewPosition = boundedValue(target);
        awaitingSeek = true;
        seekSettleTimer.restart();
        seekRequested(previewPosition);
    }

    onMediaPositionChanged: {
        if (!awaitingSeek || scrubbing)
            return;
        const tolerance = Math.max(0.08, Math.min(0.75, stepSize / 2));
        if (Math.abs(boundedValue(mediaPosition) - previewPosition) <= tolerance) {
            seekSettleTimer.stop();
            awaitingSeek = false;
        }
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Down) {
            adjustBy(-stepSize);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up) {
            adjustBy(stepSize);
            event.accepted = true;
        } else if (event.key === Qt.Key_Home) {
            seekToFromKeyboard(from);
            event.accepted = true;
        } else if (event.key === Qt.Key_End) {
            seekToFromKeyboard(to);
            event.accepted = true;
        } else if (event.key === Qt.Key_PageDown) {
            adjustBy(-Math.max(stepSize * 10, (to - from) / 10));
            event.accepted = true;
        } else if (event.key === Qt.Key_PageUp) {
            adjustBy(Math.max(stepSize * 10, (to - from) / 10));
            event.accepted = true;
        }
    }

    Timer {
        id: seekThrottle
        interval: 50
        repeat: false
        onTriggered: control.dispatchPendingSeek()
    }

    Timer {
        id: seekSettleTimer
        interval: 1500
        repeat: false
        onTriggered: control.awaitingSeek = false
    }

    background: Item {
        x: control.leftPadding
        y: control.topPadding + control.availableHeight / 2 - 1
        width: control.availableWidth
        height: 2

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: "#70ffffff"
        }

        Rectangle {
            width: control.visualPosition * parent.width
            height: parent.height
            radius: height / 2
            color: control.accentColor
        }
    }

    handle: Rectangle {
        x: control.leftPadding + control.visualPosition * (control.availableWidth - width)
        y: control.topPadding + control.availableHeight / 2 - height / 2
        implicitWidth: 9
        implicitHeight: 9
        radius: width / 2
        color: "#ffffff"
        opacity: scrubArea.containsMouse || control.scrubbing || control.activeFocus ? 1 : 0
        scale: control.scrubbing ? 1.15 : 1

        Behavior on opacity {
            NumberAnimation {
                duration: 120
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: 100
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: width / 2
            color: "transparent"
            border.width: control.activeFocus ? 2 : 0
            border.color: "#b7b7bc"
        }
    }

    // A full-width hit target makes the complete timeline directly draggable;
    // users do not have to acquire the tiny visual handle first.
    MouseArea {
        id: scrubArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        Accessible.ignored: true

        onPressed: mouse => {
            control.forceActiveFocus(Qt.MouseFocusReason);
            control.previewPosition = control.displayPosition;
            // `pressed` changes before this handler runs, so the parent's
            // scrubbingChanged handler establishes backend gesture ownership
            // before the first immediate preview is emitted below.
            control.previewAt(mouse.x);
        }
        onPositionChanged: mouse => {
            if (pressed)
                control.previewAt(mouse.x);
        }
        onReleased: mouse => control.finishScrub(mouse.x, true)
        // Cancellation commits the last frame the user could see, matching a
        // release that occurs after pointer capture is lost.
        onCanceled: control.finishScrub(0, false)
    }
}
