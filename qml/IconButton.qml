import QtQuick
import QtQuick.Controls

AbstractButton {
    id: control

    property string iconName: "play"
    property string accessibleName: ""
    property string toolTip: accessibleName
    property color iconColor: emphasized ? "#17191e" : selected ? selectedForeground : "#f7f7f8"
    property color hoverColor: emphasized ? "#ffffff" : "#2dffffff"
    property color pressedColor: emphasized ? "#dddddf" : "#44ffffff"
    property bool emphasized: false
    // A sticky ON state for the buttons that are toggles rather than actions
    // (Vivid, Theater). The treatment is the speed panel's selected preset
    // chip, inverted from the row around it -- a light pill with a dark glyph
    // -- because a mode that is on has to be readable at a glance from across
    // the room, which the ~2% background tint a hover uses is not.
    property bool selected: false
    property color selectedColor: "#f2f2f4"
    property color selectedForeground: "#17191e"
    property bool compact: false
    // The panel the tooltip has to stay clear of -- see ChromeToolTip.qml.
    property Item toolTipClearItem: null

    implicitWidth: emphasized ? (compact ? 42 : 48) : (compact ? 30 : 36)
    implicitHeight: implicitWidth
    hoverEnabled: true
    focusPolicy: Qt.TabFocus

    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.description: toolTip
    Accessible.onPressAction: control.clicked()

    ChromeToolTip {
        text: control.toolTip
        clearItem: control.toolTipClearItem
        visible: (control.hovered || control.activeFocus) && control.toolTip.length > 0
    }

    background: Rectangle {
        radius: width / 2
        color: control.down ? control.pressedColor : control.emphasized ? "#f5f5f6" : control.selected ? control.selectedColor : (control.hovered || control.activeFocus) ? control.hoverColor : "transparent"
        scale: control.down ? 0.94 : 1

        Behavior on color {
            ColorAnimation {
                duration: 100
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: 90
                easing.type: Easing.OutCubic
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: width / 2
            color: "transparent"
            border.width: control.activeFocus ? 2 : 0
            border.color: "#b7b7bc"
        }
    }

    contentItem: Canvas {
        id: glyph
        // Deliberately unsized and unanchored. A Control lays its own
        // contentItem out over the padding box (padding is 0 here), so
        // declaring a smaller width/height here does nothing -- Control's
        // resizeContent() overwrites it, and every path below is therefore
        // authored in normalised coordinates across the whole button box.
        // The sizes that used to be declared here were inert, which is why
        // the play triangle's 0.055-of-a-box offset rendered ~2x larger
        // than it was drawn to be. Keep every glyph's ink box centred on
        // (0.5, 0.5) unless there is a stated optical reason not to.

        onPaint: {
            const ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.strokeStyle = control.iconColor;
            ctx.fillStyle = control.iconColor;
            ctx.lineWidth = 1.45;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";

            if (control.iconName === "play") {
                // Mechanically the triangle is 0.43 wide and centred, i.e.
                // ink box [0.285, 0.715] -- exactly the pause glyph's box.
                // A right-pointing triangle carries its area on the base
                // side, though, so a mechanically centred one reads as
                // sitting left; the whole box is nudged right by 6% of the
                // glyph's own width (0.43 * 0.06 = 0.026) to land it
                // optically centred in the circle. That is a deliberate
                // ~1pt bias, not the ~2.5pt the old [0.34, 0.77] box gave.
                const playInk = 0.43;
                const playLeft = 0.5 - playInk / 2 + playInk * 0.06;
                ctx.beginPath();
                ctx.moveTo(width * playLeft, height * 0.22);
                ctx.lineTo(width * (playLeft + playInk), height * 0.5);
                ctx.lineTo(width * playLeft, height * 0.78);
                ctx.closePath();
                ctx.fill();
            } else if (control.iconName === "pause") {
                ctx.fillRect(width * 0.31, height * 0.25, width * 0.13, height * 0.5);
                ctx.fillRect(width * 0.56, height * 0.25, width * 0.13, height * 0.5);
            } else if (control.iconName === "backward5" || control.iconName === "forward5") {
                const forward = control.iconName === "forward5";
                const tipX = width * (forward ? 0.74 : 0.26);
                const tailX = width * (forward ? 0.24 : 0.76);
                const shoulderX = width * (forward ? 0.54 : 0.46);
                ctx.lineWidth = 1.5;
                ctx.beginPath();
                ctx.moveTo(tailX, height * 0.5);
                ctx.lineTo(tipX, height * 0.5);
                ctx.moveTo(shoulderX, height * 0.3);
                ctx.lineTo(tipX, height * 0.5);
                ctx.lineTo(shoulderX, height * 0.7);
                ctx.stroke();
            } else if (control.iconName === "volume" || control.iconName === "volumeMuted") {
                ctx.beginPath();
                ctx.moveTo(width * 0.18, height * 0.43);
                ctx.lineTo(width * 0.34, height * 0.43);
                ctx.lineTo(width * 0.5, height * 0.28);
                ctx.lineTo(width * 0.5, height * 0.72);
                ctx.lineTo(width * 0.34, height * 0.57);
                ctx.lineTo(width * 0.18, height * 0.57);
                ctx.closePath();
                ctx.fill();
                if (control.iconName === "volumeMuted") {
                    ctx.beginPath();
                    ctx.moveTo(width * 0.64, height * 0.39);
                    ctx.lineTo(width * 0.84, height * 0.61);
                    ctx.moveTo(width * 0.84, height * 0.39);
                    ctx.lineTo(width * 0.64, height * 0.61);
                    ctx.stroke();
                } else {
                    ctx.beginPath();
                    ctx.arc(width * 0.5, height * 0.5, width * 0.2, -0.8, 0.8);
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.arc(width * 0.5, height * 0.5, width * 0.34, -0.72, 0.72);
                    ctx.stroke();
                }
            } else if (control.iconName === "captions") {
                const left = width * 0.13;
                const right = width * 0.87;
                const top = height * 0.24;
                const bottom = height * 0.76;
                const radius = width * 0.11;
                ctx.lineWidth = 1.3;
                ctx.beginPath();
                ctx.moveTo(left + radius, top);
                ctx.lineTo(right - radius, top);
                ctx.quadraticCurveTo(right, top, right, top + radius);
                ctx.lineTo(right, bottom - radius);
                ctx.quadraticCurveTo(right, bottom, right - radius, bottom);
                ctx.lineTo(left + radius, bottom);
                ctx.quadraticCurveTo(left, bottom, left, bottom - radius);
                ctx.lineTo(left, top + radius);
                ctx.quadraticCurveTo(left, top, left + radius, top);
                ctx.stroke();

                // Two quiet caption rows read more clearly at toolbar scale
                // than font-rendered initials and stay in the same line family
                // as the surrounding transport icons.
                ctx.lineWidth = 1.45;
                ctx.beginPath();
                ctx.moveTo(width * 0.28, height * 0.45);
                ctx.lineTo(width * 0.46, height * 0.45);
                ctx.moveTo(width * 0.56, height * 0.45);
                ctx.lineTo(width * 0.72, height * 0.45);
                ctx.moveTo(width * 0.28, height * 0.61);
                ctx.lineTo(width * 0.52, height * 0.61);
                ctx.moveTo(width * 0.62, height * 0.61);
                ctx.lineTo(width * 0.72, height * 0.61);
                ctx.stroke();
            } else if (control.iconName === "edit") {
                ctx.beginPath();
                ctx.moveTo(width * 0.24, height * 0.74);
                ctx.lineTo(width * 0.3, height * 0.55);
                ctx.lineTo(width * 0.68, height * 0.2);
                ctx.lineTo(width * 0.82, height * 0.35);
                ctx.lineTo(width * 0.44, height * 0.7);
                ctx.closePath();
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(width * 0.25, height * 0.77);
                ctx.lineTo(width * 0.47, height * 0.7);
                ctx.stroke();
            } else if (control.iconName === "fullscreen") {
                ctx.beginPath();
                ctx.moveTo(width * 0.42, height * 0.2);
                ctx.lineTo(width * 0.2, height * 0.2);
                ctx.lineTo(width * 0.2, height * 0.42);
                ctx.moveTo(width * 0.58, height * 0.2);
                ctx.lineTo(width * 0.8, height * 0.2);
                ctx.lineTo(width * 0.8, height * 0.42);
                ctx.moveTo(width * 0.42, height * 0.8);
                ctx.lineTo(width * 0.2, height * 0.8);
                ctx.lineTo(width * 0.2, height * 0.58);
                ctx.moveTo(width * 0.58, height * 0.8);
                ctx.lineTo(width * 0.8, height * 0.8);
                ctx.lineTo(width * 0.8, height * 0.58);
                ctx.stroke();
            } else if (control.iconName === "close") {
                ctx.beginPath();
                ctx.moveTo(width * 0.27, height * 0.27);
                ctx.lineTo(width * 0.73, height * 0.73);
                ctx.moveTo(width * 0.73, height * 0.27);
                ctx.lineTo(width * 0.27, height * 0.73);
                ctx.stroke();
            } else if (control.iconName === "vivid") {
                // A luminance burst: a solid core with eight rays. The whole
                // ink box is centred on (0.5, 0.5) in the normalised
                // coordinates every glyph here is authored in -- Control's
                // resizeContent() lays the Canvas out over the entire button
                // box, so anything sized here would be overwritten.
                ctx.beginPath();
                ctx.arc(width * 0.5, height * 0.5, width * 0.155, 0, Math.PI * 2);
                ctx.fill();
                ctx.lineWidth = 1.45;
                const inner = 0.245;
                const outer = 0.37;
                ctx.beginPath();
                for (let i = 0; i < 8; ++i) {
                    const a = i * Math.PI / 4;
                    const cx = Math.cos(a);
                    const cy = Math.sin(a);
                    ctx.moveTo(width * (0.5 + cx * inner), height * (0.5 + cy * inner));
                    ctx.lineTo(width * (0.5 + cx * outer), height * (0.5 + cy * outer));
                }
                ctx.stroke();
            } else if (control.iconName === "theater") {
                // A lit screen inside a dimmed surround: stroked outer frame,
                // filled inner panel. Same 0.13/0.87 horizontal ink box the
                // captions glyph uses, so the two sit on one optical grid.
                const left = width * 0.13;
                const right = width * 0.87;
                const top = height * 0.235;
                const bottom = height * 0.765;
                const radius = width * 0.075;
                ctx.lineWidth = 1.3;
                ctx.beginPath();
                ctx.moveTo(left + radius, top);
                ctx.lineTo(right - radius, top);
                ctx.quadraticCurveTo(right, top, right, top + radius);
                ctx.lineTo(right, bottom - radius);
                ctx.quadraticCurveTo(right, bottom, right - radius, bottom);
                ctx.lineTo(left + radius, bottom);
                ctx.quadraticCurveTo(left, bottom, left, bottom - radius);
                ctx.lineTo(left, top + radius);
                ctx.quadraticCurveTo(left, top, left + radius, top);
                ctx.stroke();
                ctx.fillRect(width * 0.28, height * 0.36, width * 0.44,
                             height * 0.28);
            } else if (control.iconName === "open") {
                ctx.beginPath();
                ctx.moveTo(width * 0.13, height * 0.37);
                ctx.lineTo(width * 0.35, height * 0.37);
                ctx.lineTo(width * 0.43, height * 0.26);
                ctx.lineTo(width * 0.78, height * 0.26);
                ctx.lineTo(width * 0.86, height * 0.74);
                ctx.lineTo(width * 0.13, height * 0.74);
                ctx.closePath();
                ctx.stroke();
            }
        }

        Connections {
            target: control
            function onIconNameChanged() {
                glyph.requestPaint();
            }
            function onIconColorChanged() {
                glyph.requestPaint();
            }
            function onSelectedChanged() {
                glyph.requestPaint();
            }
        }
    }
}
