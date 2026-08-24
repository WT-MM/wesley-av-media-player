import QtQuick

// A transient, VLC-style on-video readout: one short line of text on the
// chrome's own glass, shown for a moment after a value changed and then gone.
//
// Deliberately generic in what it displays (`text` is whatever the caller
// wants to say) and deliberately NOT generic in anything else -- it is one
// card in one place, not a layout system. Today the volume drives it; a
// future "1.5x" or "+10s" readout can drive the same component without it
// needing a single new knob.
//
// THREE PROPERTIES OF THIS COMPONENT ARE LOAD-BEARING, not incidental:
//
//   * It costs nothing once it has faded. There is no repeating timer here:
//     the hide timer is single-shot and stops itself, the opacity Behavior
//     runs once per appearance and then settles, and `visible` goes false the
//     instant opacity reaches zero, which takes the item out of the scene
//     graph entirely. A faded OSD schedules no frames.
//   * It never pins the chrome. It is not part of the transport and reports
//     nothing back into FloatingControls' interactionActive, so showing the
//     volume never keeps the transport and titlebar on screen. The two fade
//     on their own independent schedules, which is what makes a scroll over
//     bare video show only the number.
//   * It is not interactive: no HoverHandler, no MouseArea, and hit-testing
//     is off, so it can never swallow a click or a wheel event meant for the
//     video underneath it.
Item {
    id: osd

    // The line to display. Assigned imperatively by the caller on every
    // change worth showing, rather than bound to the underlying value: a
    // binding would re-lay-out this Text on every volume change even while
    // the card is invisible, which is exactly the cost this component
    // promises not to have.
    property string text: ""
    // Raised to show the card; it lowers itself again `holdMs` after the last
    // show() call.
    property bool shown: false
    // How long the card stays up after the last change. ~1s is the VLC feel:
    // long enough to read a two-digit number without thinking about it, short
    // enough that it is gone before it becomes furniture.
    property int holdMs: 1000
    // Scaled from the window rather than fixed, the same rule the subtitle
    // overlay uses, so the readout is VLC-class large on a full-screen window
    // and still proportionate in a small one. The `height * 1.6` term keeps a
    // very wide, very short window from producing absurd text.
    property real referenceWidth: 0
    property real referenceHeight: 0

    // Shows (or re-shows) the card with `line`. Every call restarts the hold,
    // so a continuous scroll or slider drag keeps one card up and updates the
    // number inside it instead of flickering a new one per delta.
    function show(line) {
        osd.text = line;
        osd.shown = true;
        hideTimer.restart();
    }

    implicitWidth: card.width
    implicitHeight: card.height
    opacity: osd.shown ? 1 : 0
    // Gone from the scene graph entirely once faded -- see the note above.
    visible: opacity > 0
    // Never a target: the video, and any chrome over it, own every event.
    enabled: false

    Behavior on opacity {
        NumberAnimation {
            // The chrome's own reveal/fade pair (FloatingControls, the
            // titlebar band): snappy 135ms in, smooth 250ms out, both
            // OutCubic, so the OSD reads as the same material.
            duration: osd.shown ? 135 : 250
            easing.type: Easing.OutCubic
        }
    }

    Timer {
        id: hideTimer
        interval: osd.holdMs
        repeat: false
        onTriggered: osd.shown = false
    }

    Rectangle {
        id: card
        // The chrome's glass token, exactly as FloatingControls and the
        // titlebar band use it: near-black at ~83%. A lighter scrim lets
        // bright content (colour bars, a white shot) wash the number out,
        // which is the one thing a legibility affordance may not do.
        color: "#d51b1b1e"
        radius: 12
        width: label.implicitWidth + 2 * horizontalPadding
        height: label.implicitHeight + 2 * verticalPadding

        readonly property real horizontalPadding: Math.round(label.font.pixelSize * 0.62)
        readonly property real verticalPadding: Math.round(label.font.pixelSize * 0.30)

        Text {
            id: label
            anchors.centerIn: parent
            text: osd.text
            // The chrome's soft white, at the full-strength end of it: this
            // is the one number the user asked to be able to read at a
            // glance, so it gets the same ink the boosted volume readout on
            // the transport already gets rather than the quieter grey.
            color: "#f7f7f8"
            font.family: ".AppleSystemUIFont"
            font.pixelSize: Math.max(
                28,
                Math.round(Math.min(osd.referenceWidth,
                                    osd.referenceHeight * 1.6) * 0.042))
            font.weight: Font.DemiBold
            // The card is a sighted-only restatement of a value the volume
            // slider already exposes to accessibility clients with its own
            // Accessible.name and role; announcing it twice would be noise.
            Accessible.ignored: true
        }
    }
}
