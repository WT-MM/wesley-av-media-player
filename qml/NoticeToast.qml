import QtQuick

// A transient, non-modal notice for informational playback events (native
// playback degrading to compatibility playback, a seek that could not be
// served natively). Deliberately never a dialog: playback is continuing, so
// there is nothing to acknowledge and nothing worth interrupting the user
// for. The owner (Main.qml) drives `shown`/`text` and times the hold; this
// component only knows how to fade in, sit still, and fade out.
Item {
    id: root

    property string text: ""
    property bool shown: false

    signal dismissed

    width: card.width
    height: card.height
    opacity: root.shown && root.text.length > 0 ? 1 : 0
    visible: opacity > 0
    // Never a click target for anything under it beyond its own card -- see
    // the MouseArea below, scoped to `card` alone.
    enabled: visible

    Behavior on opacity {
        NumberAnimation {
            duration: root.shown ? 135 : 220
            easing.type: Easing.OutCubic
        }
    }

    Rectangle {
        id: card
        // Same glass treatment as the titlebar band and FloatingControls, so
        // the toast reads as part of the same chrome rather than a foreign
        // alert.
        radius: 12
        color: "#d51b1b1e"
        width: label.width + 32
        height: label.height + 20

        Text {
            id: label
            x: 16
            y: 10
            width: Math.min(360, implicitWidth)
            text: root.text
            color: "#ffffff"
            font.pixelSize: 12
            font.weight: Font.Medium
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            Accessible.role: Accessible.StaticText
            Accessible.name: root.text
        }

        MouseArea {
            anchors.fill: parent
            // Dismiss-on-click: a click acknowledges the toast early instead
            // of waiting out the hold. It never captures focus and never
            // blocks anything -- it is only reachable while already visible.
            onClicked: root.dismissed()
        }
    }
}
