import QtQuick
import QtQuick.Controls

// The chrome's own tooltip.
//
// QQuickStyle is pinned to "Basic" (src/qt/main.cpp), whose ToolTip is a
// square-cornered filled rectangle with a 1px border -- next to the floating
// transport's rounded glass it reads as a foreign object pasted onto the
// window. This carries the panel's own material instead: the same
// "#d51b1b1e" glass, no border, soft-white label, and the same 135ms-family
// fade the transport and its volume flyout use.
//
// Placement: an attached ToolTip sits directly above its button, which for
// the transport's bottom row means landing on the scrubber and the
// timecodes. Set `clearItem` to the panel the button belongs to and the tip
// is lifted clear of that panel's top edge instead, and kept horizontally
// inside it, so it never collides with the chrome it describes.
ToolTip {
    id: control

    // The panel this tip must clear. Null keeps the ordinary
    // directly-above-the-button placement (Quick Edit, Preferences).
    property Item clearItem: null
    // Flips the tip to hang *below* its button instead of above it. The
    // titlebar band starts at the window's own top edge, so a tip placed
    // above a control in that band lands outside the window entirely. Not
    // combinable with clearItem -- nothing in the chrome needs both.
    property bool below: false
    // Breathing room between the tip and whatever it is clearing.
    readonly property real gap: 8

    leftPadding: 9
    rightPadding: 9
    topPadding: 5
    bottomPadding: 6
    delay: 500
    // No timeout: the tip belongs to the pointer, exactly like the chrome.
    timeout: -1

    // Placed imperatively rather than by binding. The offset from this tip
    // to `clearItem` depends on the button's position inside a Row inside
    // the panel, which no single property change announces; recomputing at
    // show time (and whenever the tip resizes while shown) is both simpler
    // and always right.
    function reposition() {
        if (!parent)
            return;
        const centred = (parent.width - width) / 2;
        if (below) {
            x = centred;
            y = parent.height + gap;
            return;
        }
        if (!clearItem) {
            x = centred;
            y = -height - gap;
            return;
        }
        const origin = parent.mapToItem(clearItem, 0, 0);
        const left = -origin.x;
        const right = left + clearItem.width;
        x = Math.max(left + 6, Math.min(right - width - 6, centred));
        y = -origin.y - height - gap;
    }

    onAboutToShow: reposition()
    onWidthChanged: if (visible) reposition()
    onHeightChanged: if (visible) reposition()

    background: Rectangle {
        radius: 8
        color: "#d51b1b1e"
    }

    contentItem: Text {
        text: control.text
        color: "#e6ffffff"
        font.pixelSize: 11
        font.weight: Font.Medium
    }

    enter: Transition {
        NumberAnimation {
            property: "opacity"
            from: 0
            to: 1
            duration: 110
            easing.type: Easing.OutCubic
        }
    }

    exit: Transition {
        NumberAnimation {
            property: "opacity"
            from: 1
            to: 0
            duration: 110
            easing.type: Easing.OutCubic
        }
    }
}
