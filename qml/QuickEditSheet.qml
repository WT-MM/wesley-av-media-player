pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

FocusScope {
    id: sheet

    required property var player
    property bool shown: false
    property bool cropMode: false
    property real cropAspect: 0
    signal cropModeRequested(bool enabled)
    signal cropAspectRequested(real aspect)
    property bool dark: false
    property int appearance: 0 // 0 Light, 1 Dark, 2 System
    property color accentColor: dark ? "#f3f3f4" : "#232428"
    signal closeRequested
    signal appearanceRequested(int appearance)

    // Export retiming range. Narrower than the 0.0625x-16x the export command
    // will accept, on purpose: the extremes are a debugging capability, not an
    // editorial one, and a slider that reaches them makes every useful value
    // hard to hit. The same log mapping and 1x detent as the transport's speed
    // popup, so "how far from normal" reads the same in both places.
    readonly property real minimumExportSpeed: 0.25
    readonly property real maximumExportSpeed: 4
    readonly property int exportSpeedGrid: 64

    function snapExportSpeed(speed) {
        const bounded = Math.min(maximumExportSpeed, Math.max(minimumExportSpeed, speed));
        return Math.round(bounded * exportSpeedGrid) / exportSpeedGrid;
    }

    function exportSpeedForTravel(travel) {
        return snapExportSpeed(Math.pow(2, travel * 4 - 2));
    }

    function travelForExportSpeed(speed) {
        const bounded = Math.min(maximumExportSpeed, Math.max(minimumExportSpeed, speed));
        return (Math.log(bounded) / Math.LN2 + 2) / 4;
    }

    // "2×" for the whole speeds, "1.36×" for a grid step in between -- the same
    // rule the transport's rate labels use.
    function formatSpeed(speed) {
        return Number(speed).toFixed(speed % 1 === 0 ? 0 : 2) + "×";
    }

    // Restated from src/jobs.hpp (kGifMaximumOutputSeconds, kGifFramesPerSecond,
    // kGifMaximumWidth) so the sheet names the caps the encoder will actually
    // apply. If those constants move, these move with them.
    readonly property int gifSecondsCap: 15
    readonly property int gifFpsCap: 15
    readonly property int gifWidthCap: 640

    // One live sentence about the selected preset. The MKV case is the reason
    // this is a function and not a string in the model: whether that preset is
    // a copy or a re-encode depends on the retime and the crop, and saying
    // "near-instant, loses nothing" while silently re-encoding would be the
    // one genuinely misleading thing this section could do.
    function formatNote() {
        switch (sheet.player.exportFormat) {
        case 1:
            return "About half the size of H.264 at the same quality. Plays on Apple devices and current browsers.";
        case 2:
            return "Open and web-native. VP9 has no hardware encoder here, so expect this to take several times longer than the MP4 presets.";
        case 3:
            if (sheet.player.exportStreamCopies)
                return "Copied, not re-encoded: near-instant and lossless. The trim start snaps back to the nearest keyframe before your In point; the Out point is exact.";
            return "A copy is not possible with a retime or a crop, because neither can be done without new pixels — this will re-encode to H.264 in an MKV. Set speed to 1× and clear the crop for the instant lossless copy.";
        case 4:
            return "Palette-optimised for far better colour than a default GIF. Capped at " + sheet.gifSecondsCap + " s, " + sheet.gifFpsCap + " fps and " + sheet.gifWidthCap + " px wide, and silent — GIF carries no audio.";
        default:
            return "The safe default: hardware-encoded H.264 that plays essentially everywhere.";
        }
    }

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

    // The panel is an opaque surface over the video, so a wheel on it must
    // not reach the window's scroll-gesture handler underneath. The Flickable
    // below already consumes the wheel over its own content, but only while
    // it can actually scroll -- when the content fits, and over the header
    // strip, the event would otherwise fall straight through to the picture.
    // The sheet is `enabled: shown`, so this is inert whenever it is closed
    // and video gestures work normally everywhere outside it.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: wheel => wheel.accepted = true
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
                text: "TRIM & EXPORT"
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
                height: 14
            }

            RowLayout {
                width: parent.width
                spacing: 10

                Text {
                    text: "Export speed"
                    color: sheet.foreground
                    font.pixelSize: 15
                    Layout.fillWidth: true
                }

                Text {
                    text: sheet.formatSpeed(sheet.player.exportSpeed)
                    color: sheet.foreground
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }
            }

            Slider {
                id: exportSpeedSlider
                width: parent.width
                height: 32
                from: 0
                to: 1
                live: true
                hoverEnabled: true
                focusPolicy: Qt.TabFocus
                Accessible.name: "Export speed"
                Accessible.role: Accessible.Slider
                onMoved: {
                    const speed = sheet.exportSpeedForTravel(value);
                    if (speed === 1)
                        value = 0.5; // magnetic detent at 1x
                    sheet.player.setExportSpeed(speed);
                }

                Binding {
                    target: exportSpeedSlider
                    property: "value"
                    value: sheet.travelForExportSpeed(sheet.player.exportSpeed)
                    when: !exportSpeedSlider.pressed
                    restoreMode: Binding.RestoreNone
                }

                background: Item {
                    x: exportSpeedSlider.leftPadding
                    y: exportSpeedSlider.topPadding + exportSpeedSlider.availableHeight / 2 - 1
                    width: exportSpeedSlider.availableWidth
                    height: 2
                    Rectangle {
                        anchors.fill: parent
                        radius: 2
                        color: sheet.quietSurface
                    }
                    // Filled from the 1x detent rather than from the left end,
                    // so the track reads as "how far from normal speed" and the
                    // midpoint needs no separate tick to be findable.
                    Rectangle {
                        x: Math.min(0.5, exportSpeedSlider.visualPosition) * parent.width
                        width: Math.abs(exportSpeedSlider.visualPosition - 0.5) * parent.width
                        height: parent.height
                        radius: 2
                        color: sheet.accentColor
                    }
                }

                handle: Rectangle {
                    x: exportSpeedSlider.leftPadding + exportSpeedSlider.visualPosition * (exportSpeedSlider.availableWidth - width)
                    y: exportSpeedSlider.topPadding + exportSpeedSlider.availableHeight / 2 - height / 2
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: 5
                    color: sheet.dark ? "white" : "#26282d"
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -3
                        radius: width / 2
                        color: "transparent"
                        border.width: exportSpeedSlider.activeFocus ? 2 : 0
                        border.color: "#8b8c91"
                    }
                }
            }

            Item {
                width: 1
                height: 4
            }

            // Laid out like the appearance row below rather than like the
            // transport popup's centred mini-chips: inside this sheet a row of
            // choices is a full-width band of equal segments.
            RowLayout {
                width: parent.width
                spacing: 3

                Repeater {
                    model: [0.5, 1, 1.5, 2, 4]

                    QuietButton {
                        required property real modelData

                        Layout.fillWidth: true
                        text: Number(modelData).toString()
                        accessibleName: "Export at " + sheet.formatSpeed(modelData)
                        compact: true
                        foreground: sheet.foreground
                        selectedForeground: sheet.foreground
                        selectedColor: sheet.quietSurface
                        hoverColor: sheet.quietSurface
                        pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                        selected: Math.abs(sheet.player.exportSpeed - modelData) < 1e-9
                        onClicked: sheet.player.setExportSpeed(modelData)
                    }
                }
            }

            Item {
                width: 1
                height: 6
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
                        text: "Keeps voices natural in the exported file"
                        color: sheet.secondary
                        font.pixelSize: 12
                    }
                }

                Switch {
                    id: pitchSwitch
                    text: ""
                    // A Switch normally learns its width from its contentItem,
                    // which the default style pads by the indicator's width.
                    // This one has an empty contentItem, so without an explicit
                    // size the control collapses to its padding and the
                    // indicator is drawn outside the only area that accepts
                    // clicks -- the switch looks right and does nothing. State
                    // the indicator's size here so the two coincide.
                    padding: 0
                    implicitWidth: 42
                    implicitHeight: 24
                    focusPolicy: Qt.TabFocus
                    Accessible.name: "Preserve audio pitch in the export"
                    onToggled: sheet.player.setExportPreservePitch(checked)

                    Binding {
                        target: pitchSwitch
                        property: "checked"
                        value: sheet.player.exportPreservePitch
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

            Item {
                width: 1
                height: 12
            }

            // Format presets. Deliberately five named destinations, not a
            // codec picker: the choice a user is actually making here is
            // "where is this file going" -- a phone, a web page, an archive,
            // a chat window -- and each row already implies its own codec
            // pair. Two columns of wide chips rather than the five-across
            // band the speed row uses, because these labels are words.
            Text {
                text: "Format"
                color: sheet.foreground
                font.pixelSize: 15
            }

            Item {
                width: 1
                height: 8
            }

            Grid {
                width: parent.width
                columns: 2
                spacing: 3

                Repeater {
                    // Labels and values only; every note is produced live by
                    // formatNote() below, because the MKV one has to change
                    // as soon as a retime or a crop makes a copy illegal.
                    model: [
                        {
                            label: "MP4 · H.264",
                            value: 0
                        },
                        {
                            label: "MP4 · HEVC",
                            value: 1
                        },
                        {
                            label: "WebM · VP9",
                            value: 2
                        },
                        {
                            label: "MKV · Copy",
                            value: 3
                        },
                        {
                            label: "GIF",
                            value: 4
                        }
                    ]

                    QuietButton {
                        required property var modelData

                        width: (parent.width - 3) / 2
                        text: modelData.label
                        accessibleName: "Export as " + modelData.label
                        compact: true
                        foreground: sheet.foreground
                        selectedForeground: sheet.foreground
                        selectedColor: sheet.quietSurface
                        hoverColor: sheet.quietSurface
                        pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                        selected: sheet.player.exportFormat === modelData.value
                        onClicked: sheet.player.setExportFormat(modelData.value)
                    }
                }
            }

            Item {
                width: 1
                height: 8
            }

            // The note for the SELECTED preset only. Showing five notes at
            // once would turn the section into a manual; showing the one that
            // applies turns it into an answer.
            Text {
                width: parent.width
                text: sheet.formatNote()
                color: sheet.secondary
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            Item {
                width: 1
                height: 9
            }

            QuietButton {
                width: parent.width
                // Name the retiming on the button itself: the speed control is
                // a few rows up and scrolls out of sight, so this is the last
                // place the consequence can still be seen before it happens.
                text: sheet.player.exporting ? "Cancel Export" : (sheet.player.exportSpeed === 1 ? "Export Selection" : "Export Selection at " + sheet.formatSpeed(sheet.player.exportSpeed))
                accessibleName: sheet.player.exporting ? "Cancel video export" : text
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
                text: "CROP"
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
                    text: sheet.cropMode ? "Done" : "Adjust Crop"
                    accessibleName: sheet.cropMode ? "Finish adjusting the crop rectangle" : "Draw a crop rectangle over the video"
                    foreground: sheet.cropMode ? (sheet.dark ? "#17181b" : "#ffffff") : sheet.foreground
                    selectedForeground: foreground
                    selectedColor: sheet.cropMode ? sheet.accentColor : sheet.quietSurface
                    hoverColor: sheet.cropMode ? sheet.accentColor : sheet.quietSurface
                    pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                    selected: sheet.cropMode
                    Layout.fillWidth: true
                    enabled: sheet.player.hasMedia
                    onClicked: sheet.cropModeRequested(!sheet.cropMode)
                }

                QuietButton {
                    text: "Reset"
                    accessibleName: "Reset the crop to the whole frame"
                    foreground: sheet.foreground
                    selectedColor: sheet.quietSurface
                    hoverColor: sheet.quietSurface
                    pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                    Layout.fillWidth: true
                    enabled: sheet.player.cropActive
                    onClicked: {
                        sheet.cropAspectRequested(0);
                        sheet.player.resetCrop();
                    }
                }
            }

            Item {
                width: 1
                height: 8
            }

            // Aspect presets constrain the rectangle as the viewer SEES it,
            // which is why they are ratios of displayed pixels rather than of
            // coded ones -- on an anamorphic source those differ, and the one
            // the user means is the one on screen.
            RowLayout {
                width: parent.width
                spacing: 3

                Repeater {
                    model: [
                        {
                            label: "Free",
                            value: 0
                        },
                        {
                            label: "16:9",
                            value: 16 / 9
                        },
                        {
                            label: "1:1",
                            value: 1
                        },
                        {
                            label: "9:16",
                            value: 9 / 16
                        }
                    ]

                    QuietButton {
                        required property var modelData

                        Layout.fillWidth: true
                        text: modelData.label
                        accessibleName: modelData.value === 0 ? "Crop freely" : "Constrain the crop to " + modelData.label
                        compact: true
                        foreground: sheet.foreground
                        selectedForeground: sheet.foreground
                        selectedColor: sheet.quietSurface
                        hoverColor: sheet.quietSurface
                        pressedColor: sheet.dark ? "#38ffffff" : "#18000000"
                        selected: Math.abs(sheet.cropAspect - modelData.value) < 1e-6
                        onClicked: sheet.cropAspectRequested(modelData.value)
                    }
                }
            }

            Item {
                width: 1
                height: 10
            }

            Text {
                width: parent.width
                // States the one thing about this feature a user could
                // otherwise get wrong: the picture keeps playing uncropped,
                // and the rectangle is what the exported file will contain.
                text: sheet.player.cropActive ? "The bright region is what the export will contain. Playback stays uncropped — the rectangle is the preview." : "Crop the exported file without re-framing playback. Drag the edges or corners of the rectangle over the video."
                color: sheet.secondary
                font.pixelSize: 12
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
