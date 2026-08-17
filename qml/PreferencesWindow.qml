pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window

// A small, QuickTime-Preferences-style panel. Deliberately minimal today --
// one control -- but laid out (section header, description, a settings
// column) so a second preference can be added later without restructuring.
Window {
    id: prefs

    required property var player
    property bool dark: false

    readonly property color foreground: dark ? "#f4f4f5" : "#17181b"
    readonly property color secondary: dark ? "#aeb0b7" : "#686a70"
    readonly property color quietSurface: dark ? "#20ffffff" : "#0c000000"
    readonly property color accentColor: dark ? "#f3f3f4" : "#232428"
    readonly property var stepPresets: [5, 10, 15, 30]

    title: "Preferences"
    width: 360
    height: 400
    minimumWidth: width
    minimumHeight: height
    maximumWidth: width
    maximumHeight: height
    color: dark ? "#1d1e22" : "#f5f5f3"
    // A utility panel, not a resizable document window -- matches QuickTime
    // Player's own Preferences window chrome (title bar, close button, no
    // zoom/minimize).
    flags: Qt.Dialog

    Shortcut {
        sequence: "Escape"
        onActivated: prefs.close()
    }
    Shortcut {
        sequence: StandardKey.Close
        onActivated: prefs.close()
    }

    Column {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 14

        Text {
            text: "SEEK STEP"
            color: prefs.secondary
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.8
        }

        Text {
            width: parent.width
            text: "How far the Left/Right arrow keys and the transport's skip buttons move."
            color: prefs.secondary
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        Item {
            width: 1
            height: 2
        }

        RowLayout {
            width: parent.width
            spacing: 6

            Repeater {
                model: prefs.stepPresets

                QuietButton {
                    required property int modelData
                    Layout.fillWidth: true
                    text: modelData + "s"
                    accessibleName: "Set seek step to " + modelData + " seconds"
                    foreground: prefs.foreground
                    selectedForeground: prefs.dark ? "#17181b" : "#ffffff"
                    selectedColor: prefs.accentColor
                    hoverColor: prefs.quietSurface
                    pressedColor: prefs.dark ? "#38ffffff" : "#18000000"
                    selected: prefs.player.seekStepSeconds === modelData
                    onClicked: prefs.player.setSeekStepSeconds(modelData)
                }
            }
        }

        RowLayout {
            width: parent.width
            spacing: 10

            Text {
                text: "Custom"
                color: prefs.foreground
                font.pixelSize: 13
                Layout.fillWidth: true
            }

            SpinBox {
                id: customSpin
                from: 1
                to: 60
                stepSize: 1
                editable: true
                focusPolicy: Qt.StrongFocus
                Accessible.name: "Custom seek step in seconds"

                textFromValue: (value, locale) => value + "s"
                valueFromText: (text, locale) => {
                    const parsed = parseInt(text, 10);
                    return isNaN(parsed) ? customSpin.value : Math.max(1, Math.min(60, parsed));
                }
                onValueModified: prefs.player.setSeekStepSeconds(value)

                palette.text: prefs.foreground
                palette.windowText: prefs.foreground
                palette.buttonText: prefs.foreground
                palette.base: prefs.quietSurface
                palette.window: prefs.quietSurface

                Binding {
                    target: customSpin
                    property: "value"
                    value: Math.round(prefs.player.seekStepSeconds)
                    when: !customSpin.activeFocus
                    restoreMode: Binding.RestoreNone
                }
            }
        }

        Item {
            width: 1
            height: 8
        }

        Text {
            text: "WINDOW"
            color: prefs.secondary
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.8
        }

        Text {
            width: parent.width
            text: "Keep the window hugging the video with no letterbox bars, the way QuickTime Player does. Off allows free-form resizing that can show bars."
            color: prefs.secondary
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        Item {
            width: 1
            height: 2
        }

        CheckBox {
            id: hugsVideoCheck
            text: "Window hugs the video"
            Accessible.name: "Window hugs the video"
            // Initial declarative binding for the value at creation time.
            // AbstractButton's own click handling does a direct imperative
            // write to `checked` on every toggle, which -- per ordinary QML
            // property semantics -- detaches this binding the first time the
            // box is clicked (the same hazard qml/PreferencesWindow.qml's
            // seek-step SpinBox already guards against for its own `value`,
            // there via a `when` clause). A plain Binding element would stay
            // detached forever after that first click. The Connections below
            // is what keeps this box honest afterward: it does not depend on
            // any binding surviving, it just re-writes `checked` imperatively
            // every time the controller's real value changes, including
            // changes made from the View menu while this window is open.
            checked: prefs.player.windowHugsVideo
            onToggled: prefs.player.setWindowHugsVideo(checked)

            palette.text: prefs.foreground
            palette.windowText: prefs.foreground

            Connections {
                target: prefs.player
                function onWindowHugsVideoChanged() {
                    hugsVideoCheck.checked = prefs.player.windowHugsVideo;
                }
            }
        }
    }
}
