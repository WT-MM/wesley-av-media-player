import QtQuick
import QtQuick.Controls

// A playback-rate slider over the native engine's rate window and grid
// (`playbackRates`, published from src/media/native_playback_contract.hpp).
// Logarithmic travel: 0 is the minimum, 1 the maximum, and every doubling
// costs the same travel, so 1x falls on the midpoint and is a magnetic detent.
// The track fills from that detent, so it reads as "how far from normal".
// The slider snaps onto the grid the engine admits, so a label never shows a
// rate the engine is not playing. Callers style the handle.
Slider {
    id: slider

    // The rate shown while the slider is not held.
    required property real rate
    property color trackColor
    property color fillColor
    signal rateMoved(real rate)

    function snap(value) {
        const bounded = Math.min(playbackRates.maximum, Math.max(playbackRates.minimum, value));
        return Math.round(bounded * playbackRates.grid) / playbackRates.grid;
    }

    function rateForTravel(travel) {
        return snap(Math.pow(2, travel * 4 - 2));
    }

    function travelForRate(value) {
        const bounded = Math.min(playbackRates.maximum, Math.max(playbackRates.minimum, value));
        return (Math.log(bounded) / Math.LN2 + 2) / 4;
    }

    from: 0
    to: 1
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    Accessible.role: Accessible.Slider

    onMoved: {
        const moved = rateForTravel(value);
        if (moved === 1)
            value = 0.5;
        rateMoved(moved);
    }

    Binding {
        target: slider
        property: "value"
        value: slider.travelForRate(slider.rate)
        when: !slider.pressed
        restoreMode: Binding.RestoreNone
    }

    background: Item {
        x: slider.leftPadding
        y: slider.topPadding + slider.availableHeight / 2 - 1
        width: slider.availableWidth
        height: 2

        Rectangle {
            anchors.fill: parent
            radius: 2
            color: slider.trackColor
        }
        Rectangle {
            x: Math.min(0.5, slider.visualPosition) * parent.width
            width: Math.abs(slider.visualPosition - 0.5) * parent.width
            height: parent.height
            radius: 2
            color: slider.fillColor
        }
    }
}
