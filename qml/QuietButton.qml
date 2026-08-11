import QtQuick
import QtQuick.Controls

AbstractButton {
    id: control

    property string accessibleName: text
    property string toolTip: ""
    property color foreground: "#f7f7f8"
    property color selectedForeground: foreground
    property color selectedColor: "#22ffffff"
    property color hoverColor: "#22ffffff"
    property color pressedColor: "#38ffffff"
    property bool selected: false
    property bool compact: false

    implicitWidth: Math.max(implicitContentWidth + (compact ? 18 : 26), compact ? 42 : 56)
    implicitHeight: compact ? 34 : 40
    hoverEnabled: true
    focusPolicy: Qt.TabFocus

    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.description: toolTip
    Accessible.onPressAction: control.clicked()

    ToolTip.visible: toolTip.length > 0 && (hovered || activeFocus)
    ToolTip.text: toolTip
    ToolTip.delay: 650

    background: Rectangle {
        radius: height / 2
        color: control.down ? control.pressedColor : control.selected ? control.selectedColor : (control.hovered || control.activeFocus) ? control.hoverColor : "transparent"
        scale: control.down ? 0.97 : 1

        Behavior on color {
            ColorAnimation {
                duration: 100
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: 90
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: height / 2
            color: "transparent"
            border.width: control.activeFocus ? 2 : 0
            border.color: "#b7b7bc"
        }
    }

    contentItem: Text {
        text: control.text
        color: control.selected ? control.selectedForeground : control.foreground
        font.pixelSize: control.compact ? 13 : 14
        font.weight: control.selected ? Font.DemiBold : Font.Medium
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
