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

    // The FOCUSED window's player controller, or null when no window is open.
    // This bar is app-level (see qml/AppMenu.qml), so both of these change as
    // the user moves between windows and both go null when the last window
    // closes -- every item below guards on that rather than assuming a
    // controller exists.
    required property var controller
    // The focused window's ApplicationWindow (qml/Main.qml's `root`), for the
    // handful of window-level actions (resizeToActualSize, resizeToFitScreen,
    // visibility) that live there rather than on the player controller. Null
    // with no window open.
    required property var appRoot
    // The app-level WindowManager (context property `appHost`). Preferences,
    // About, Quit and Hide and Pause All are application actions, not
    // window actions, so they address this and keep working with no window
    // open at all.
    required property var host
    readonly property bool hasController: root.controller !== null && root.controller !== undefined
    readonly property bool hasWindow: root.appRoot !== null && root.appRoot !== undefined
    readonly property bool mediaLoaded: root.hasController && root.controller.hasMedia
    // Exposed so qml/Main.qml can keep this item's `checked` state in sync
    // with the controller: Qt.labs.platform's MenuItem is not a QQuickItem,
    // so it has no default property and cannot hold a declarative Binding as
    // its own child (unlike, say, qml/PreferencesWindow.qml's CheckBox). A
    // property alias is not content, so it does not hit that restriction.
    readonly property alias hugsVideoMenuItem: hugsVideoMenuItem

    function stepLabel(action) {
        if (!root.hasController)
            return action;
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
            onTriggered: root.host.showPreferences()
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
            // Deliberately the app-level open, not the focused window's:
            // File > Open is one of the three gestures (with Finder-open and
            // argv) that must produce a NEW window unless an empty one is
            // already sitting there to claim it. Loading into the window you
            // are looking at is the drag-and-drop gesture, and the empty
            // player's own click.
            onTriggered: root.host.openMedia()
        }
    }

    Platform.Menu {
        title: "Playback"

        // No `shortcut:` here -- see the file header comment. The action
        // remains reachable by click; Space keeps working exactly as before
        // via Main.qml's own global Shortcut.
        Platform.MenuItem {
            text: root.hasController && root.controller.playing ? "Pause" : "Play"
            enabled: root.mediaLoaded
            onTriggered: root.controller.togglePlayPause()
        }
        Platform.MenuItem {
            text: root.stepLabel("Skip Forward")
            enabled: root.mediaLoaded
            onTriggered: root.controller.skipForward()
        }
        Platform.MenuItem {
            text: root.stepLabel("Skip Back")
            enabled: root.mediaLoaded
            onTriggered: root.controller.skipBackward()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: "Seek to Start"
            enabled: root.mediaLoaded
            onTriggered: root.controller.seekTo(0)
        }
    }

    Platform.Menu {
        title: "View"

        Platform.MenuItem {
            text: "Actual Size"
            enabled: root.mediaLoaded && root.hasWindow
            onTriggered: root.appRoot.resizeToActualSize()
        }
        Platform.MenuItem {
            text: "Fit to Screen"
            enabled: root.mediaLoaded && root.hasWindow
            onTriggered: root.appRoot.resizeToFitScreen()
        }
        Platform.MenuSeparator {}
        // No `shortcut:` (F is a bare key -- see file header); the existing
        // F key handling in Main.qml is untouched, this just adds a
        // clickable, discoverable path to the same action.
        Platform.MenuItem {
            text: root.hasWindow && root.appRoot.visibility === Window.FullScreen ? "Exit Full Screen" : "Enter Full Screen"
            enabled: root.mediaLoaded && root.hasWindow
            onTriggered: root.controller.toggleFullscreen()
        }
        Platform.MenuSeparator {}
        // QuickTime-style floating window: keep the windowed frame hugging
        // the video's aspect ratio (no letterbox bars). Bound both ways --
        // `checked` below is only this item's *initial* value; Qt.labs.
        // platform's own checkable toggle does a direct imperative write to
        // `checked` on every click, which detaches a plain binding for good
        // (ordinary QML property semantics). qml/Main.qml holds a Connections
        // block (see hugsVideoMenuItem's alias above) that re-syncs `checked`
        // imperatively every time the controller's real value changes, which
        // does not depend on any binding having survived.
        Platform.MenuItem {
            id: hugsVideoMenuItem
            text: "Window Hugs Video"
            checkable: true
            checked: root.hasController ? root.controller.windowHugsVideo : true
            enabled: root.hasController
            onTriggered: root.controller.setWindowHugsVideo(checked)
        }
        Platform.MenuSeparator {}
        // The "h" macro, made discoverable. Deliberately WITHOUT a `shortcut:`
        // -- see the file header: a native NSMenu key equivalent for a bare,
        // unmodified key intercepts that keystroke application-wide, text
        // fields included, which would eat every "h" typed into Quick Edit or
        // the Preferences panel. The bare-key gesture itself is bound where
        // every other bare key in this app is bound, in qml/Main.qml's
        // Keys.onPressed filter on the video stage, which only ever sees a
        // keystroke when no text field has focus.
        Platform.MenuItem {
            text: "Hide and Pause All"
            enabled: root.host.windowCount > 0
            onTriggered: root.host.hideAndPauseAll()
        }
    }

    // Keeps the View menu's "Window Hugs Video" checkbox following the focused
    // controller's actual value -- both for external changes (Preferences,
    // another window) and to undo Qt.labs.platform's own direct write to
    // `checked` on every click, which per ordinary QML property semantics
    // detaches any plain Binding on that property for good the first time the
    // item is clicked. Connections sidesteps that: it establishes no binding,
    // just an imperative re-write triggered by the real signal, so it keeps
    // working after any number of clicks. It re-targets as focus moves between
    // windows, which is what makes one app-level menu bar honest about N
    // windows' state.
    Connections {
        target: root.controller
        function onWindowHugsVideoChanged() {
            if (root.controller)
                hugsVideoMenuItem.checked = root.controller.windowHugsVideo;
        }
    }

    onControllerChanged: {
        // Reads `root.controller` directly rather than the `hasController`
        // convenience: on the way out the controller reference and the derived
        // binding are cleared in an unspecified order, and this handler runs
        // on the reference's change. Testing the thing actually about to be
        // dereferenced is the only ordering-independent guard.
        if (root.controller)
            hugsVideoMenuItem.checked = root.controller.windowHugsVideo;
    }

    Platform.MessageDialog {
        id: aboutDialog
        title: "About " + Qt.application.name
        text: Qt.application.name + "\nVersion " + Qt.application.version
    }
}
