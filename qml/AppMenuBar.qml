import QtQuick
import QtQuick.Window
import Qt.labs.platform as Platform

// WAM's real desktop menu bar. Qt.labs.platform's MenuBar (unlike QtQuick
// Controls' in-window one) installs itself as the actual macOS top menu, the
// way every other native app does.
//
// Player commands come from the focused window's PlayerActions (labels, keys,
// enabled rules, check marks, handlers); only Cmd-modified sequences are set
// here as menu key equivalents -- see PlayerActions.qml for why bare keys are
// not.
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
    // The focused window's commands, or every command disabled with no window.
    readonly property PlayerActions commands: root.hasWindow ? root.appRoot.actions : idleCommands
    readonly property PlayerActions idleCommands: PlayerActions { window: null }

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
            objectName: "wamQuitMenuItem"
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
        ActionMenuItem {
            command: root.commands.closeWindow
            shortcut: StandardKey.Close
        }
    }

    Platform.Menu {
        title: "Playback"

        ActionMenuItem { command: root.commands.mute }
        ActionMenuItem { command: root.commands.playPause }
        ActionMenuItem { command: root.commands.skipForward }
        ActionMenuItem { command: root.commands.skipBack }
        Platform.MenuSeparator {}
        ActionMenuItem { command: root.commands.nextFrame }
        ActionMenuItem { command: root.commands.previousFrame }
        Platform.MenuSeparator {}
        ActionMenuItem { command: root.commands.seekToStart }
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
    // mutates the real NSMenu and writes a checkable item's `checked` itself
    // on a click (see ActionMenuItem.qml). A static pool keeps every item's
    // identity stable across focus changes and file changes, so the one
    // imperative re-sync below is the whole story; creating and destroying
    // native menu items on every open would add a second, harder failure
    // mode for no user-visible gain.
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
        // click on the other track adds a third check mark.
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

        ActionMenuItem { command: root.commands.loadSubtitles }
    }

    // Keeps the Subtitles menu's items following the focused controller: their
    // labels when a new file is opened or the route flips, their radio marks
    // when the selection changes from anywhere (the menu, the transport
    // button, a generated caption selecting itself). Imperative for the
    // reason ActionMenuItem's check mark is.
    function rebuildSubtitleItems() {
        // Reads root.controller DIRECTLY rather than the derived `tracks` and
        // `hasController` bindings. This runs from onControllerChanged, and a
        // handler on a property fires without any guarantee that the bindings
        // depending on that same property have been re-evaluated yet, so the
        // derived bindings can still hold the previous window's tracks and
        // check mark after focus moves. Reading the thing that actually
        // changed is the only ordering-independent fix.
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

        ActionMenuItem { command: root.commands.actualSize }
        ActionMenuItem { command: root.commands.fitToScreen }
        // Grows the window to the screen's visible frame and letterboxes the
        // video inside it, overriding Window Hugs Video for this window; a
        // second trigger restores the exact frame. Nothing else binds any
        // Cmd-Shift sequence.
        ActionMenuItem {
            command: root.commands.fillScreenPadded
            shortcut: "Ctrl+Shift+F"
        }
        Platform.MenuSeparator {}
        ActionMenuItem { command: root.commands.fullScreenToggle }
        Platform.MenuSeparator {}
        // QuickTime-style floating window: the windowed frame hugs the
        // video's aspect ratio (no letterbox bars).
        ActionMenuItem { command: root.commands.windowHugsVideo }
        Platform.MenuSeparator {}
        // Two independent viewing modes, useful apart: one is about the
        // picture, the other about everything that is not the picture.
        ActionMenuItem { command: root.commands.vivid }
        ActionMenuItem { command: root.commands.theater }
        Platform.MenuSeparator {}
        ActionMenuItem { command: root.commands.hideAndPauseAll }
    }

    onControllerChanged: {
        // The Subtitles menu is per focused window: moving focus between two
        // windows must show each one's own tracks and its own selection.
        root.rebuildSubtitleItems();
    }

    Platform.MessageDialog {
        id: aboutDialog
        title: "About " + Qt.application.name
        text: Qt.application.name + "\nVersion " + Qt.application.version
    }
}
