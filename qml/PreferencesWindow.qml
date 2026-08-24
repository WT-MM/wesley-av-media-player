pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window

// A small, QuickTime-Preferences-style panel. One column of sections, each a
// header, a plain-language description and its controls, so another
// preference is an append rather than a restructure.
Window {
    id: prefs

    // The controller these settings live on. Every setting here is app-level
    // and mirrored onto every open window, so ANY live controller is an
    // equally valid view of them -- but with no window open there is no
    // controller at all, and this panel outlives the last window (it belongs
    // to the application, not to a window). It is therefore legitimately null
    // sometimes, and every read below guards on that rather than assuming.
    required property var player
    readonly property bool hasPlayer: prefs.player !== null
        && prefs.player !== undefined
    property bool dark: false

    readonly property color foreground: dark ? "#f4f4f5" : "#17181b"
    readonly property color secondary: dark ? "#aeb0b7" : "#686a70"
    readonly property color quietSurface: dark ? "#20ffffff" : "#0c000000"
    readonly property color accentColor: dark ? "#f3f3f4" : "#232428"
    readonly property var stepPresets: [5, 10, 15, 30]
    // The maximum-volume choices, in percent. 100 is "no amplification at
    // all"; 400 is the native gain stage's own ceiling (kMaximumGain, +12 dB,
    // src/platform/macos/native_audio_render_core.hpp) and nothing above it
    // can be offered. The default is 200.
    readonly property var maxVolumePresets: [100, 125, 150, 200, 300, 400]

    title: "Preferences"
    width: 360
    // Sized to its content: the column is a fixed list of sections with no
    // wrapping surprises, so the window is exactly as tall as they are rather
    // than a number that has to be re-guessed every time a section is
    // appended (which is the whole point of the one-column shape).
    // The Math.max floor covers the one frame before the column's children
    // have been laid out, where implicitHeight is still 0 and a zero-height
    // window would be shown.
    height: Math.max(480, Math.round(settingsColumn.implicitHeight + 48))
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
        id: settingsColumn
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
                    enabled: prefs.hasPlayer
                    selected: prefs.hasPlayer
                        && prefs.player.seekStepSeconds === modelData
                    onClicked: {
                        if (prefs.hasPlayer)
                            prefs.player.setSeekStepSeconds(modelData);
                    }
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
                enabled: prefs.hasPlayer
                onValueModified: {
                    if (prefs.hasPlayer)
                        prefs.player.setSeekStepSeconds(value);
                }

                palette.text: prefs.foreground
                palette.windowText: prefs.foreground
                palette.buttonText: prefs.foreground
                palette.base: prefs.quietSurface
                palette.window: prefs.quietSurface

                Binding {
                    target: customSpin
                    property: "value"
                    value: prefs.hasPlayer
                        ? Math.round(prefs.player.seekStepSeconds)
                        : customSpin.value
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
            enabled: prefs.hasPlayer
            checked: prefs.hasPlayer ? prefs.player.windowHugsVideo : true
            onToggled: {
                if (prefs.hasPlayer)
                    prefs.player.setWindowHugsVideo(checked);
            }

            palette.text: prefs.foreground
            palette.windowText: prefs.foreground

            Connections {
                target: prefs.player
                function onWindowHugsVideoChanged() {
                    if (prefs.player)
                        hugsVideoCheck.checked = prefs.player.windowHugsVideo;
                }
            }
        }

        Item {
            width: 1
            height: 8
        }

        Text {
            text: "PLAYBACK SPEED"
            color: prefs.secondary
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.8
        }

        Text {
            width: parent.width
            text: "Keep voices and music at their natural pitch when you play faster or slower. Off sounds like classic varispeed, where the pitch rises and falls with the speed. Applies while you watch; exporting has its own setting."
            color: prefs.secondary
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        Item {
            width: 1
            height: 2
        }

        CheckBox {
            id: preservePitchCheck
            text: "Preserve pitch at other speeds"
            Accessible.name: "Preserve pitch at other speeds"
            // Same binding hazard, same guard as the box above: the first
            // click detaches the declarative binding, so the Connections
            // below re-writes `checked` from the controller's real value
            // whenever it changes for any other reason.
            enabled: prefs.hasPlayer
            checked: prefs.hasPlayer ? prefs.player.preservePitch : true
            onToggled: {
                if (prefs.hasPlayer)
                    prefs.player.setPreservePitch(checked);
            }

            palette.text: prefs.foreground
            palette.windowText: prefs.foreground

            Connections {
                target: prefs.player
                function onPreservePitchChanged() {
                    if (prefs.player)
                        preservePitchCheck.checked = prefs.player.preservePitch;
                }
            }
        }

        Item {
            width: 1
            height: 8
        }

        Text {
            text: "MAXIMUM VOLUME"
            color: prefs.secondary
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.8
        }

        Text {
            width: parent.width
            text: "How far above 100% any window's volume can be pushed. Above 100% this is amplification and loud material can distort. The volume sliders re-scale to match, so the track always spans the whole range with 100% marked on it."
            color: prefs.secondary
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        Item {
            width: 1
            height: 2
        }

        // Two rows of three rather than one row of six: at this panel's fixed
        // 360pt width, six pill buttons wide enough for "125%" do not fit on
        // one line and the labels elide. Three per row leaves every one of
        // them comfortably wider than its text.
        GridLayout {
            width: parent.width
            columns: 3
            rowSpacing: 6
            columnSpacing: 6

            Repeater {
                model: prefs.maxVolumePresets

                QuietButton {
                    required property int modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    text: modelData + "%"
                    accessibleName: "Set maximum volume to " + modelData + " percent"
                    foreground: prefs.foreground
                    selectedForeground: prefs.dark ? "#17181b" : "#ffffff"
                    selectedColor: prefs.accentColor
                    hoverColor: prefs.quietSurface
                    pressedColor: prefs.dark ? "#38ffffff" : "#18000000"
                    enabled: prefs.hasPlayer
                    // The controller stores a normalized multiplier (1.0 =
                    // 100%); these buttons speak percent. Rounding the
                    // comparison rather than testing equality on a double
                    // keeps 1.25 and 1.5 selectable without depending on
                    // exact binary representations surviving a round trip
                    // through the state file.
                    selected: prefs.hasPlayer
                        && Math.round(prefs.player.maximumVolume * 100) === modelData
                    onClicked: {
                        if (prefs.hasPlayer)
                            prefs.player.setMaximumVolume(modelData / 100);
                    }
                }
            }
        }

        Item {
            width: 1
            height: 8
        }

        Text {
            text: "SCROLLING"
            color: prefs.secondary
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.8
        }

        Text {
            width: parent.width
            text: "Scroll up and down over the picture to change that window's volume, and sideways to sweep through the timeline. Each window keeps its own level. The controls on the transport bar work the same either way."
            color: prefs.secondary
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        Item {
            width: 1
            height: 2
        }

        CheckBox {
            id: scrollGesturesCheck
            text: "Scroll over video adjusts volume and seeks"
            Accessible.name: "Scroll over video adjusts volume and seeks"
            // Same binding hazard, same guard as the boxes above.
            enabled: prefs.hasPlayer
            checked: prefs.hasPlayer ? prefs.player.scrollGesturesEnabled : true
            onToggled: {
                if (prefs.hasPlayer)
                    prefs.player.setScrollGesturesEnabled(checked);
            }

            palette.text: prefs.foreground
            palette.windowText: prefs.foreground

            Connections {
                target: prefs.player
                function onScrollGesturesEnabledChanged() {
                    if (prefs.player)
                        scrollGesturesCheck.checked =
                            prefs.player.scrollGesturesEnabled;
                }
            }
        }
    }
}
