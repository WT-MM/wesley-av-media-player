pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

FocusScope {
    id: sheet

    required property var player
    property bool shown: false
    property bool dark: false
    property int appearance: 0 // 0 Light, 1 Dark, 2 System
    property color accentColor: dark ? "#f3f3f4" : "#232428"
    signal closeRequested
    signal appearanceRequested(int appearance)

    function formatTime(seconds) {
        if (!isFinite(seconds) || seconds < 0)
            seconds = 0;
        const total = Math.floor(seconds);
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor((total % 3600) / 60);
        const secs = total % 60;
        return hours > 0 ? hours + ":" + String(minutes).padStart(2, "0") + ":" + String(secs).padStart(2, "0") : minutes + ":" + String(secs).padStart(2, "0");
    }

    readonly property color foreground: dark ? "#f4f4f5" : "#17181b"
    readonly property color secondary: dark ? "#aeb0b7" : "#686a70"
    readonly property color separator: dark ? "#1effffff" : "#12000000"
    readonly property color quietSurface: dark ? "#20ffffff" : "#0c000000"

    width: Math.min(340, parent ? parent.width - 24 : 340)
    opacity: shown ? 1 : 0
    enabled: shown
    visible: opacity > 0
    activeFocusOnTab: shown
    Accessible.role: Accessible.Grouping
    Accessible.name: "Quick Edit"

    transform: Translate {
        x: sheet.shown ? 0 : sheet.width + 28
        Behavior on x {
            NumberAnimation {
                duration: 220
                easing.type: Easing.OutCubic
            }
        }
    }
    Behavior on opacity {
        NumberAnimation {
            duration: 150
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 15
        color: sheet.dark ? "#f21d1e22" : "#fbfbfa"
    }

    Text {
        id: title
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: 20
        anchors.leftMargin: 22
        text: "Quick Edit"
        color: sheet.foreground
        font.pixelSize: 18
        font.weight: Font.DemiBold
    }

    IconButton {
        id: closeButton
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: 14
        anchors.topMargin: 13
        iconName: "close"
        iconColor: sheet.foreground
        hoverColor: sheet.dark ? "#22ffffff" : "#10000000"
        pressedColor: sheet.dark ? "#38ffffff" : "#1c000000"
        accessibleName: "Close Quick Edit"
        toolTip: "Close (Escape)"
        onClicked: sheet.closeRequested()
    }

    Flickable {
        id: scroller
        anchors.top: title.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 17
        anchors.leftMargin: 22
        anchors.rightMargin: 22
        anchors.bottomMargin: 17
        contentWidth: width
        contentHeight: editColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        Column {
            id: editColumn
            width: scroller.width
            spacing: 0

            Text {
                text: "PLAYBACK"
                color: sheet.secondary
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
            }

            Item {
                width: 1
                height: 16
            }

            RowLayout {
                width: parent.width
                spacing: 10

                Text {
                    text: "Speed"
                    color: sheet.foreground
                    font.pixelSize: 15
                    Layout.fillWidth: true
                }

                Text {
                    text: Number(sheet.player.rate).toFixed(2).replace(/\.00$/, "") + "×"
                    color: sheet.foreground
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }
            }

            Slider {
                id: speedSlider
                width: parent.width
                height: 32
                from: 0.25
                to: 4
                stepSize: 0.05
                live: true
                hoverEnabled: true
                focusPolicy: Qt.TabFocus
                Accessible.name: "Playback speed"
                onMoved: sheet.player.setRate(value)

                Binding {
                    target: speedSlider
                    property: "value"
                    value: sheet.player.rate
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
                        color: sheet.quietSurface
                    }
                    Rectangle {
                        width: speedSlider.visualPosition * parent.width
                        height: parent.height
                        radius: 2
                        color: sheet.accentColor
                    }
                }

                handle: Rectangle {
                    x: speedSlider.leftPadding + speedSlider.visualPosition * (speedSlider.availableWidth - width)
                    y: speedSlider.topPadding + speedSlider.availableHeight / 2 - height / 2
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: 5
                    color: sheet.dark ? "white" : "#26282d"
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -3
                        radius: width / 2
                        color: "transparent"
                        border.width: speedSlider.activeFocus ? 2 : 0
                        border.color: "#8b8c91"
                    }
                }
            }

            RowLayout {
                width: parent.width
                height: 44

                Column {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: "Preserve pitch"
                        color: sheet.foreground
                        font.pixelSize: 15
                    }
                    Text {
                        text: "Keep voices natural at other speeds"
                        color: sheet.secondary
                        font.pixelSize: 12
                    }
                }

                Switch {
                    id: pitchSwitch
                    text: ""
                    focusPolicy: Qt.TabFocus
                    Accessible.name: "Preserve audio pitch"
                    onToggled: sheet.player.setPreservePitch(checked)

                    Binding {
                        target: pitchSwitch
                        property: "checked"
                        value: sheet.player.preservePitch
                        when: !pitchSwitch.down
                        restoreMode: Binding.RestoreNone
                    }

                    indicator: Rectangle {
                        implicitWidth: 42
                        implicitHeight: 24
                        x: pitchSwitch.width - width
                        y: (pitchSwitch.height - height) / 2
                        radius: height / 2
                        color: pitchSwitch.checked ? sheet.accentColor : sheet.quietSurface

                        Rectangle {
                            width: 18
                            height: 18
                            y: 3
                            x: pitchSwitch.checked ? parent.width - width - 3 : 3
                            radius: 9
                            color: pitchSwitch.checked ? "white" : sheet.secondary
                            Behavior on x {
                                NumberAnimation {
                                    duration: 130
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                    }

                    contentItem: Item {}
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: sheet.separator
            }
            Item {
                width: 1
                height: 23
            }

            Text {
                text: "TRIM"
                color: sheet.secondary
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
            }

            Item {
                width: 1
                height: 13
            }

            RowLayout {
                width: parent.width
                spacing: 8

                QuietButton {
                    text: "Set In  " + sheet.formatTime(sheet.player.trimIn)
                    accessibleName: "Set trim start to current position"
                    foreground: sheet.foreground
                    selectedColor: sheet.quietSurface
                    hoverColor: sheet.quietSurface
                    pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                    Layout.fillWidth: true
                    onClicked: sheet.player.setTrimIn(sheet.player.position)
                }

                QuietButton {
                    text: "Set Out  " + sheet.formatTime(sheet.player.trimOut)
                    accessibleName: "Set trim end to current position"
                    foreground: sheet.foreground
                    selectedColor: sheet.quietSurface
                    hoverColor: sheet.quietSurface
                    pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                    Layout.fillWidth: true
                    onClicked: sheet.player.setTrimOut(sheet.player.position)
                }
            }

            Item {
                width: 1
                height: 9
            }

            QuietButton {
                width: parent.width
                text: sheet.player.exporting ? "Cancel Export" : "Export Selection"
                accessibleName: sheet.player.exporting ? "Cancel video export" : "Export trimmed selection"
                foreground: sheet.dark ? "#17181b" : "#ffffff"
                selectedForeground: foreground
                selectedColor: sheet.accentColor
                hoverColor: sheet.accentColor
                selected: true
                enabled: sheet.player.exporting || (sheet.player.hasMedia && !sheet.player.captioning)
                onClicked: {
                    if (sheet.player.exporting)
                        sheet.player.cancelExport();
                    else
                        sheet.player.exportSelection();
                }
            }

            Item {
                width: 1
                height: exportFeedback.visible ? 8 : 0
            }

            Text {
                id: exportFeedback
                width: parent.width
                text: sheet.player.exportStatus
                visible: text.length > 0
                height: visible ? implicitHeight : 0
                color: sheet.secondary
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            Item {
                width: 1
                height: 22
            }
            Rectangle {
                width: parent.width
                height: 1
                color: sheet.separator
            }
            Item {
                width: 1
                height: 22
            }

            Text {
                text: "CAPTIONS"
                color: sheet.secondary
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
            }

            Item {
                width: 1
                height: 13
            }

            Text {
                width: parent.width
                text: sheet.player.captionStatus.length > 0 ? sheet.player.captionStatus : "Create private, on-device subtitles."
                color: sheet.secondary
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            Item {
                width: 1
                height: 10
            }

            QuietButton {
                width: parent.width
                text: sheet.player.captioning ? "Cancel" : "Generate Captions"
                accessibleName: text
                foreground: sheet.foreground
                selectedColor: sheet.quietSurface
                hoverColor: sheet.quietSurface
                pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                enabled: sheet.player.captioning || (sheet.player.hasMedia && !sheet.player.exporting)
                onClicked: {
                    if (sheet.player.captioning)
                        sheet.player.cancelCaptioning();
                    else
                        sheet.player.generateCaptions();
                }
            }

            Item {
                width: 1
                height: 22
            }
            Rectangle {
                width: parent.width
                height: 1
                color: sheet.separator
            }
            Item {
                width: 1
                height: 22
            }

            Text {
                text: "APPEARANCE"
                color: sheet.secondary
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
            }

            Item {
                width: 1
                height: 10
            }

            RowLayout {
                width: parent.width
                spacing: 3

                Repeater {
                    model: ["Light", "Dark", "System"]

                    QuietButton {
                        required property int index
                        required property string modelData
                        Layout.fillWidth: true
                        text: modelData
                        accessibleName: "Use " + modelData.toLowerCase() + " appearance"
                        foreground: sheet.foreground
                        selectedForeground: sheet.foreground
                        selectedColor: sheet.quietSurface
                        hoverColor: sheet.quietSurface
                        pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                        selected: sheet.appearance === index
                        compact: true
                        onClicked: sheet.appearanceRequested(index)
                    }
                }
            }

            Item {
                width: 1
                height: 8
            }
        }
    }
}
