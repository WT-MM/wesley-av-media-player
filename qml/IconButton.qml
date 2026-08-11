import QtQuick
import QtQuick.Controls

AbstractButton {
    id: control

    property string iconName: "play"
    property string accessibleName: ""
    property string toolTip: accessibleName
    property color iconColor: emphasized ? "#17191e" : "#f7f7f8"
    property color hoverColor: emphasized ? "#ffffff" : "#2dffffff"
    property color pressedColor: emphasized ? "#dddddf" : "#44ffffff"
    property bool emphasized: false
    property bool compact: false

    implicitWidth: emphasized ? (compact ? 42 : 48) : (compact ? 30 : 36)
    implicitHeight: implicitWidth
    hoverEnabled: true
    focusPolicy: Qt.TabFocus

    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.description: toolTip
    Accessible.onPressAction: control.clicked()

    ToolTip.visible: (hovered || activeFocus) && toolTip.length > 0
    ToolTip.text: toolTip
    ToolTip.delay: 650

    background: Rectangle {
        radius: width / 2
        color: control.down ? control.pressedColor : control.emphasized ? "#f5f5f6" : (control.hovered || control.activeFocus) ? control.hoverColor : "transparent"
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
        anchors.centerIn: parent
        width: control.emphasized ? (control.compact ? 18 : 22) : (control.compact ? 16 : 19)
        height: width

        onPaint: {
            const ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.strokeStyle = control.iconColor;
            ctx.fillStyle = control.iconColor;
            ctx.lineWidth = 1.45;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";

            if (control.iconName === "play") {
                ctx.beginPath();
                ctx.moveTo(width * 0.34, height * 0.22);
                ctx.lineTo(width * 0.77, height * 0.5);
                ctx.lineTo(width * 0.34, height * 0.78);
                ctx.closePath();
                ctx.fill();
            } else if (control.iconName === "pause") {
                ctx.fillRect(width * 0.31, height * 0.25, width * 0.13, height * 0.5);
                ctx.fillRect(width * 0.56, height * 0.25, width * 0.13, height * 0.5);
            } else if (control.iconName === "backward5" || control.iconName === "forward5") {
                const forward = control.iconName === "forward5";
                ctx.beginPath();
                ctx.arc(width * 0.5, height * 0.53, width * 0.3, forward ? Math.PI * 1.15 : Math.PI * -0.15, forward ? Math.PI * 0.05 : Math.PI * 0.95, !forward);
                ctx.stroke();
                ctx.beginPath();
                if (forward) {
                    ctx.moveTo(width * 0.76, height * 0.23);
                    ctx.lineTo(width * 0.78, height * 0.45);
                    ctx.lineTo(width * 0.58, height * 0.37);
                } else {
                    ctx.moveTo(width * 0.24, height * 0.23);
                    ctx.lineTo(width * 0.22, height * 0.45);
                    ctx.lineTo(width * 0.42, height * 0.37);
                }
                ctx.stroke();
                ctx.font = "600 " + Math.round(height * 0.43) + "px sans-serif";
                ctx.textAlign = "center";
                ctx.textBaseline = "middle";
                ctx.fillText("5", width * 0.5, height * 0.58);
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
                ctx.strokeRect(width * 0.13, height * 0.24, width * 0.74, height * 0.52);
                ctx.font = "700 " + Math.round(height * 0.35) + "px sans-serif";
                ctx.textAlign = "center";
                ctx.textBaseline = "middle";
                ctx.fillText("CC", width * 0.5, height * 0.52);
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
        }
    }
}
