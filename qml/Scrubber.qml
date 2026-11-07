import QtQuick
import QtQuick.Controls

Slider {
    id: control

    property real mediaPosition: 0
    // The media the position belongs to; a change ends any wait for a seek
    // committed into the previous one.
    property url source
    property real previewPosition: 0
    //   "idle"      the handle shows mediaPosition
    //   "scrubbing" a pointer drag: previews are paced at frame cadence and
    //               the pacer fields below mean something only here
    //   "settling"  a seek was committed: the handle holds previewPosition
    //               until playback reaches it or seekSettleTimer gives up
    // Only setPhase changes it; it also owns seekSettleTimer.
    property string phase: "idle"
    // Pacer state, reset on entering "scrubbing"; -1 means no target.
    property real pendingSeek: -1
    property real lastPreviewSeek: -1
    property real previewCadenceElapsed: 0
    property color accentColor: "#f1f1f2"
    property string accessibleName: "Playback position"
    readonly property real previewCadenceSeconds: 0.016
    readonly property bool scrubbing: scrubArea.pressed
    readonly property real displayPosition: phase === "idle"
        ? boundedValue(mediaPosition)
        : boundedValue(previewPosition)
    signal previewSeekRequested(real seconds)
    signal seekRequested(real seconds)

    from: 0
    to: 1
    value: displayPosition
    // Match WAM's global/VLC-style transport shortcuts even while the
    // timeline owns keyboard focus. A duration-relative step would make the
    // same Right Arrow key seek by a different amount after clicking the
    // scrubber.
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
        // Interpolate directly instead of through Slider.valueAt(): valueAt()
        // rounds its result through stepSize, and stepSize is the five-second
        // keyboard step; routing pointer motion through it would quantize every
        // drag onto five-second stops and the handle would never sit where the
        // pointer is. Keyboard stepping uses stepSize; only pointer scrubbing
        // is continuous.
        return from + (to - from) * normalized;
    }

    function samePreviewTarget(left, right) {
        return left >= 0 && right >= 0 && left === right;
    }

    function setPhase(next) {
        phase = next;
        if (next === "settling")
            seekSettleTimer.restart();
        else
            seekSettleTimer.stop();
    }

    function beginPreviewPacing() {
        pendingSeek = -1;
        lastPreviewSeek = -1;
        previewCadenceElapsed = 0;
        setPhase("scrubbing");
    }

    function queuePreviewSeek(seconds) {
        if (samePreviewTarget(seconds, pendingSeek))
            return;
        if (samePreviewTarget(seconds, lastPreviewSeek)) {
            // Returning to the last submitted point cancels a newer queued
            // approximation instead of emitting the same target twice.
            pendingSeek = -1;
            return;
        }
        pendingSeek = seconds;
        if (lastPreviewSeek < 0)
            dispatchPendingSeek();
    }

    function dispatchPendingSeek() {
        if (pendingSeek < 0)
            return;
        const seconds = pendingSeek;
        pendingSeek = -1;
        if (samePreviewTarget(seconds, lastPreviewSeek))
            return;
        lastPreviewSeek = seconds;
        previewSeekRequested(seconds);
    }

    function advancePreviewPacer(frameSeconds) {
        if (phase !== "scrubbing" || !isFinite(frameSeconds) || frameSeconds <= 0)
            return;
        const elapsed = previewCadenceElapsed + frameSeconds;
        if (pendingSeek >= 0 && elapsed >= previewCadenceSeconds) {
            // Preserve the fractional frame remainder. This alternates two
            // and three display frames on 144 Hz panels instead of falling
            // permanently to 48 Hz, while still emitting at most once per
            // rendered frame.
            previewCadenceElapsed = Math.min(
                previewCadenceSeconds,
                Math.max(0, elapsed - previewCadenceSeconds));
            dispatchPendingSeek();
            return;
        }
        // Once a full cadence is available, keep that budget so the next
        // distinct pointer target is sampled on the very next rendered frame.
        previewCadenceElapsed = Math.min(previewCadenceSeconds, elapsed);
    }

    function previewAt(pointerX) {
        previewPosition = boundedValue(valueForPointer(pointerX));
        // Send the first preview immediately. Later pointer updates only
        // replace one pending target while the visual handle remains live.
        queuePreviewSeek(previewPosition);
    }

    function finishScrub(pointerX, updateFromPointer) {
        if (updateFromPointer)
            previewPosition = boundedValue(valueForPointer(pointerX));
        previewCadenceElapsed = 0;
        pendingSeek = -1;
        lastPreviewSeek = -1;
        setPhase("settling");

        // Always commit the release position. A coalesced update may otherwise
        // leave playback one pointer event behind the handle.
        seekRequested(previewPosition);
    }

    // A keyboard or accessibility seek. During a drag the drag keeps the
    // handle; its release commits and settles.
    function commitSeek(target) {
        previewPosition = boundedValue(target);
        if (phase !== "scrubbing")
            setPhase("settling");
        seekRequested(previewPosition);
    }

    function adjustBy(delta) {
        commitSeek(displayPosition + delta);
    }

    onMediaPositionChanged: {
        if (phase !== "settling")
            return;
        const tolerance = Math.max(0.08, Math.min(0.75, stepSize / 2));
        if (Math.abs(boundedValue(mediaPosition) - previewPosition) <= tolerance)
            setPhase("idle");
    }

    onSourceChanged: {
        if (phase === "settling")
            setPhase("idle");
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
            commitSeek(from);
            event.accepted = true;
        } else if (event.key === Qt.Key_End) {
            commitSeek(to);
            event.accepted = true;
        } else if (event.key === Qt.Key_PageDown) {
            adjustBy(-Math.max(stepSize * 10, (to - from) / 10));
            event.accepted = true;
        } else if (event.key === Qt.Key_PageUp) {
            adjustBy(Math.max(stepSize * 10, (to - from) / 10));
            event.accepted = true;
        }
    }

    FrameAnimation {
        id: previewFramePacer
        running: control.phase === "scrubbing"
        onTriggered: control.advancePreviewPacer(frameTime)
    }

    Timer {
        id: seekSettleTimer
        interval: 1500
        repeat: false
        onTriggered: control.setPhase("idle")
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
            control.beginPreviewPacing();
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
