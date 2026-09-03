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
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: "Close Window"
            shortcut: StandardKey.Close
            enabled: root.hasWindow
            // The focused window's close(), the same path as its red button:
            // it runs the window's onClosing sequence, and closing never
            // quits the app.
            onTriggered: root.appRoot.close()
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
        // Same no-`shortcut:` rule as the rest of this menu; "." and "," are
        // window-scoped Shortcuts in Main.qml. The labels name the keys anyway
        // so the pair is discoverable from the menu, which is the only place a
        // user would go looking for them.
        Platform.MenuItem {
            text: "Next Frame  ."
            enabled: root.mediaLoaded
            onTriggered: root.controller.stepFrame(1)
        }
        Platform.MenuItem {
            text: "Previous Frame  ,"
            enabled: root.mediaLoaded
            onTriggered: root.controller.stepFrame(-1)
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: "Seek to Start"
            enabled: root.mediaLoaded
            onTriggered: root.controller.seekTo(0)
        }
    }

    // ---------------------------------------------------------------------
    // Subtitles.
    //
    // VLC-shaped: Off, then one radio item per subtitle SOURCE the focused
    // window has for the file it is playing -- embedded text tracks first,
    // then generated captions, then anything the user loaded -- then a way to
    // add a file. The list is rebuilt from the engine that is actually
    // playing (the container on the native route, mpv's track-list on the
    // compatibility route), so the same menu works either way.
    //
    // A FIXED POOL of items rather than an Instantiator. Qt.labs.platform
    // mutates the real NSMenu, and this file already documents (see
    // hugsVideoMenuItem below) that its checkable items imperatively overwrite
    // `checked` and detach any binding on it. A static pool keeps every item's
    // identity stable across focus changes and file changes, so the one
    // imperative re-sync at the bottom of this file is the whole story;
    // creating and destroying native menu items on every open would add a
    // second, harder failure mode for no user-visible gain.
    Platform.Menu {
        id: subtitlesMenu
        title: "Subtitles"

        // Number of track slots. Files carry a handful; Matroska's own track
        // budget is 64. Sources past this are not listed -- see the label on
        // the overflow item, which says so rather than silently hiding them.
        readonly property int slotCount: 16
        // Bindings, used only for `visible` on the overflow row. Everything
        // that has to be CORRECT at the instant it is written -- the item
        // labels and the radio marks -- reads the controller directly instead;
        // see rebuildSubtitleItems below for why.
        readonly property var tracks: root.hasController ? root.controller.subtitleTracks : []

        // Re-writes every item's `checked` from the controller's real
        // selection. Called on any change and after every click, because
        // Qt.labs.platform writes `checked` itself on a click and a plain
        // binding would not survive it.
        function syncChecks() {
            const active = root.controller ? root.controller.activeSubtitleTrack : -1;
            const list = root.controller ? root.controller.subtitleTracks : [];
            offMenuItem.checked = active === -1;
            for (let i = 0; i < subtitleSlots.length; ++i) {
                const entry = i < list.length ? list[i] : null;
                subtitleSlots[i].checked = entry !== null && entry.id === active;
            }
        }

        readonly property var subtitleSlots: [
            slot0, slot1, slot2, slot3, slot4, slot5, slot6, slot7,
            slot8, slot9, slot10, slot11, slot12, slot13, slot14, slot15
        ]

        // What a click on track slot `index` does.
        //
        // Every slot MUST have this. A checkable Qt.labs.platform item flips
        // its own `checked` when it is activated, so a slot with no handler
        // does not merely fail to select the track -- it puts a check mark
        // next to it and leaves the real selection alone. Nothing then fires
        // activeSubtitleTrackChanged, so the imperative re-sync that carries
        // the radio semantics never runs, `Off` stays checked, and a second
        // click on the other track adds a third check mark. That was the
        // reported defect: Off and both "English" rows checked at once, with
        // no subtitles actually playing.
        //
        // syncChecks() runs on EVERY path out of here, including the ones
        // that change nothing (a click on the already-selected row, a slot
        // whose track vanished in a rebuild between the menu opening and the
        // click). Those paths emit no signal, so without this call the item's
        // self-toggled `checked` would survive as a phantom mark.
        function selectSlot(index) {
            const controller = root.controller;
            const list = controller ? controller.subtitleTracks : [];
            if (controller && index >= 0 && index < list.length) {
                controller.selectSubtitleTrack(list[index].id);
            }
            subtitlesMenu.syncChecks();
        }

        Platform.MenuItem {
            id: offMenuItem
            text: "Off"
            checkable: true
            checked: true
            enabled: root.mediaLoaded
            onTriggered: {
                root.controller.selectSubtitleTrack(-1);
                subtitlesMenu.syncChecks();
            }
        }

        Platform.MenuItem { id: slot0; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(0) }
        Platform.MenuItem { id: slot1; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(1) }
        Platform.MenuItem { id: slot2; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(2) }
        Platform.MenuItem { id: slot3; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(3) }
        Platform.MenuItem { id: slot4; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(4) }
        Platform.MenuItem { id: slot5; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(5) }
        Platform.MenuItem { id: slot6; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(6) }
        Platform.MenuItem { id: slot7; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(7) }
        Platform.MenuItem { id: slot8; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(8) }
        Platform.MenuItem { id: slot9; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(9) }
        Platform.MenuItem { id: slot10; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(10) }
        Platform.MenuItem { id: slot11; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(11) }
        Platform.MenuItem { id: slot12; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(12) }
        Platform.MenuItem { id: slot13; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(13) }
        Platform.MenuItem { id: slot14; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(14) }
        Platform.MenuItem { id: slot15; checkable: true; visible: false; onTriggered: subtitlesMenu.selectSlot(15) }

        Platform.MenuItem {
            id: subtitleOverflowItem
            enabled: false
            visible: subtitlesMenu.tracks.length > subtitlesMenu.slotCount
            text: visible
                ? (subtitlesMenu.tracks.length - subtitlesMenu.slotCount) + " more tracks are not listed"
                : ""
        }

        Platform.MenuSeparator {}

        Platform.MenuItem {
            text: "Load Subtitle File…"
            enabled: root.mediaLoaded
            onTriggered: root.controller.openSubtitleFileDialog()
        }
    }

    // Keeps the Subtitles menu's items following the focused controller: their
    // labels when a new file is opened or the route flips, their radio marks
    // when the selection changes from anywhere (the menu, the transport
    // button, a generated caption selecting itself). Imperative for exactly
    // the reason the View menu's checkbox is -- see the note there.
    function rebuildSubtitleItems() {
        // Reads root.controller DIRECTLY rather than the derived `tracks` and
        // `hasController` bindings. This runs from onControllerChanged, and a
        // handler on a property fires without any guarantee that the bindings
        // depending on that same property have been re-evaluated yet -- which
        // showed up as the menu being exactly one update stale after focus
        // moved between windows: it listed the previous window's tracks with
        // the previous window's check mark. Reading the thing that actually
        // changed is the only ordering-independent fix, and it is the same
        // rule the View menu's checkbox handler follows below.
        const controller = root.controller;
        const list = controller ? controller.subtitleTracks : [];
        const active = controller ? controller.activeSubtitleTrack : -1;
        const loaded = controller ? controller.hasMedia : false;
        for (let i = 0; i < subtitlesMenu.subtitleSlots.length; ++i) {
            const item = subtitlesMenu.subtitleSlots[i];
            const entry = i < list.length ? list[i] : null;
            if (entry === null) {
                item.visible = false;
                item.text = "";
                item.enabled = false;
                item.checked = false;
                continue;
            }
            item.visible = true;
            item.enabled = loaded;
            item.text = entry.label;
            item.checked = entry.id === active;
        }
        offMenuItem.checked = active === -1;
    }

    Connections {
        target: root.controller

        function onSubtitleTracksChanged() {
            root.rebuildSubtitleItems();
        }

        function onActiveSubtitleTrackChanged() {
            root.rebuildSubtitleItems();
        }

        function onHasMediaChanged() {
            root.rebuildSubtitleItems();
        }
    }

    Component.onCompleted: root.rebuildSubtitleItems()

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
        // "Fill Screen (Padded)": grow the window to the screen's whole
        // visible frame and letterbox/pillarbox the video inside it with
        // black bars, overriding "Window Hugs Video" for this window while it
        // is on. A second trigger restores the exact frame the window had.
        //
        // Cmd-Shift-F, and this one DOES carry a `shortcut:` -- the file
        // header's prohibition is on BARE keys, which a native NSMenu key
        // equivalent would intercept application-wide including inside text
        // fields. A Cmd-modified sequence can never collide with typed text.
        // Nothing else in the app binds any Cmd-Shift sequence.
        Platform.MenuItem {
            id: fillPaddedMenuItem
            text: "Fill Screen (Padded)"
            shortcut: "Ctrl+Shift+F"
            checkable: true
            // Qt.labs.platform writes `checked` imperatively on every click,
            // which detaches a plain binding for good -- the same hazard the
            // hugs-video item documents below. The Connections block at the
            // end of this file re-syncs it from the focused window's real
            // state instead, so it survives any number of clicks and follows
            // focus between windows.
            checked: root.hasWindow ? root.appRoot.fillScreenPadded : false
            // Fullscreen owns the window frame outright; padding underneath
            // it would be invisible and a frame AppKit would fight on the way
            // out.
            enabled: root.mediaLoaded && root.hasWindow
                && root.appRoot.visibility !== Window.FullScreen
            onTriggered: {
                // Ask the window, then take its answer: the toggle can
                // legitimately decline (no native bridge, a frame change
                // already in flight), and this item must not then claim a
                // state the window is not in.
                root.appRoot.toggleFillScreenPadded();
                checked = root.appRoot.fillScreenPadded;
            }
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
        // Vivid boost and Theater dim: two independent viewing modes, kept as
        // two items rather than one combined "Theater Mode" because they are
        // useful apart -- one is about the picture, the other about
        // everything that is not the picture. Both are per window, both carry
        // their bare key in the label rather than a `shortcut:` (see the file
        // header), and both re-sync their check mark through the Connections
        // block at the end of this file for the reason documented there.
        Platform.MenuItem {
            id: vividMenuItem
            text: "Vivid Boost  V"
            checkable: true
            checked: root.hasWindow ? root.appRoot.vividActive : false
            // Disabled, not merely unchecked, for an HDR source: that content
            // already occupies the display's extended range and a boost on
            // top of it would only clip its highlights.
            enabled: root.mediaLoaded && root.hasWindow && root.appRoot.vividAvailable
            onTriggered: {
                root.appRoot.toggleVividBoost();
                checked = root.appRoot.vividActive;
            }
        }
        Platform.MenuItem {
            id: theaterMenuItem
            text: "Theater Dim  T"
            checkable: true
            checked: root.hasWindow ? root.appRoot.theaterDimEnabled : false
            enabled: root.mediaLoaded && root.hasWindow
            onTriggered: {
                root.appRoot.toggleTheaterDim();
                checked = root.appRoot.theaterDimEnabled;
            }
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

    // The same imperative re-sync for the padded-fill item, against the
    // focused WINDOW rather than its controller -- padded fill is per window
    // and deliberately not a controller-level (mirrored, persisted) setting.
    Connections {
        target: root.appRoot
        function onFillScreenPaddedChanged() {
            if (root.appRoot)
                fillPaddedMenuItem.checked = root.appRoot.fillScreenPadded;
        }
        // Both directions, which is the whole point: these two modes have a
        // chrome toggle, a bare key and a menu item, and the check mark has to
        // follow whichever one the user reached for. `vividActive` rather than
        // `vividEnabled` so opening an HDR file clears the mark instead of
        // leaving it standing over a boost that is no longer applied.
        function onVividActiveChanged() {
            if (root.appRoot)
                vividMenuItem.checked = root.appRoot.vividActive;
        }
        function onTheaterDimEnabledChanged() {
            if (root.appRoot)
                theaterMenuItem.checked = root.appRoot.theaterDimEnabled;
        }
    }

    onAppRootChanged: {
        // Reads root.appRoot directly rather than the `hasWindow` derived
        // binding, for the same ordering reason onControllerChanged does.
        fillPaddedMenuItem.checked = root.appRoot
            ? root.appRoot.fillScreenPadded
            : false;
        vividMenuItem.checked = root.appRoot ? root.appRoot.vividActive : false;
        theaterMenuItem.checked = root.appRoot
            ? root.appRoot.theaterDimEnabled
            : false;
    }

    onControllerChanged: {
        // The Subtitles menu is per focused window: moving focus between two
        // windows must show each one's own tracks and its own selection.
        root.rebuildSubtitleItems();
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
