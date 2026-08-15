import QtQuick
import QtQuick.Window
import Qt.labs.platform as Platform

// WAM's real desktop menu bar. Qt.labs.platform's MenuBar (unlike QtQuick
// Controls' in-window one) installs itself as the actual macOS top menu, the
// way every other native app does -- this is why it lives in its own file
// rather than QtQuick.Controls.MenuBar inline in Main.qml.
//
// Every action below calls an existing controller/root function; nothing
// here invents new player behavior. Deliberately not wired: Space, the
// arrow keys, and F. Main.qml already binds those as bare, unmodified
// shortcuts (global Shortcut items for Space/Left/Right, a Keys.onPressed
// filter for F) -- see the App/Playback/View menus' comments below. A
// native NSMenu key equivalent for a bare, unmodified key intercepts every
// matching keystroke application-wide, including inside text fields (Quick
// Edit's fields, the preferences window), which would silently eat normal
// typing. Only Cmd-modified standard shortcuts (Preferences, Open) are
// bound here, since those can never collide with typed text.
Platform.MenuBar {
    id: root

    required property var controller
    // The ApplicationWindow (qml/Main.qml's `root`), for the handful of
    // window-level actions (openMedia, showPreferences, resizeToActualSize,
    // resizeToFitScreen, visibility) that live there rather than on the
    // player controller.
    required property var appRoot

    function stepLabel(action) {
        const step = Number(root.controller.seekStepSeconds);
        const formatted = step.toFixed(step % 1 === 0 ? 0 : 1);
        return action + " " + formatted + " Seconds";
    }

    Platform.Menu {
        // macOS replaces this title with the application's real name in the
        // menu bar; Qt.labs.platform still requires a non-empty title to
        // recognize this as the app menu.
        title: "WAM"

        Platform.MenuItem {
            text: "Preferences…"
            shortcut: StandardKey.Preferences
            role: Platform.MenuItem.PreferencesRole
            onTriggered: root.appRoot.showPreferences()
        }
        Platform.MenuItem {
            text: "About WAM"
            role: Platform.MenuItem.AboutRole
            onTriggered: aboutDialog.open()
        }
        Platform.MenuItem {
            text: "Quit WAM"
            shortcut: StandardKey.Quit
            role: Platform.MenuItem.QuitRole
            onTriggered: Qt.quit()
        }
    }

    Platform.Menu {
        title: "File"

        Platform.MenuItem {
            text: "Open…"
            shortcut: StandardKey.Open
            onTriggered: root.appRoot.openMedia()
        }
    }

    Platform.Menu {
        title: "Playback"

        // No `shortcut:` here -- see the file header comment. The action
        // remains reachable by click; Space keeps working exactly as before
        // via Main.qml's own global Shortcut.
        Platform.MenuItem {
            text: root.controller.playing ? "Pause" : "Play"
            enabled: root.controller.hasMedia
            onTriggered: root.controller.togglePlayPause()
        }
        Platform.MenuItem {
            text: root.stepLabel("Skip Forward")
            enabled: root.controller.hasMedia
            onTriggered: root.controller.skipForward()
        }
        Platform.MenuItem {
            text: root.stepLabel("Skip Back")
            enabled: root.controller.hasMedia
            onTriggered: root.controller.skipBackward()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: "Seek to Start"
            enabled: root.controller.hasMedia
            onTriggered: root.controller.seekTo(0)
        }
    }

    Platform.Menu {
        title: "View"

        Platform.MenuItem {
            text: "Actual Size"
            enabled: root.controller.hasMedia
            onTriggered: root.appRoot.resizeToActualSize()
        }
        Platform.MenuItem {
            text: "Fit to Screen"
            enabled: root.controller.hasMedia
            onTriggered: root.appRoot.resizeToFitScreen()
        }
        Platform.MenuSeparator {}
        // No `shortcut:` (F is a bare key -- see file header); the existing
        // F key handling in Main.qml is untouched, this just adds a
        // clickable, discoverable path to the same action.
        Platform.MenuItem {
            text: root.appRoot.visibility === Window.FullScreen ? "Exit Full Screen" : "Enter Full Screen"
            enabled: root.controller.hasMedia
            onTriggered: root.controller.toggleFullscreen()
        }
    }

    Platform.MessageDialog {
        id: aboutDialog
        title: "About " + Qt.application.name
        text: Qt.application.name + "\nVersion " + Qt.application.version
    }
}
