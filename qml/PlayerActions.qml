import QtQuick
import QtQuick.Window

// Every command a player window offers, defined once: label, key, enabled
// rule, check state and handler. The menu bar (AppMenuBar.qml), the window's
// key bindings (Main.qml), the transport buttons (FloatingControls.qml) and
// the test seam's verbs (src/qt/test_seams.cpp) all call trigger(), so a
// command does the same thing however it is reached.
//
// Bare keys are never NSMenu key equivalents: AppKit would deliver those
// app-wide, including into text fields (Quick Edit, Preferences), and eat
// normal typing. `scope` says how Main.qml binds the key instead: "window"
// is a window-scoped Shortcut, answered whatever holds focus; "stage" is the
// video stage's key filter, which runs only while no text field or control
// holds focus. Cmd-modified sequences are menu key equivalents and are set on
// the menu items themselves (AppMenuBar.qml).
//
// With `window` null (no window open) every command is disabled and unchecked
// and keeps its label, which is what the app-level menu bar shows then.
QtObject {
    id: actions

    required property var window
    readonly property bool hasWindow: window !== null && window !== undefined
    readonly property var controller: hasWindow ? window.controller : null
    readonly property bool mediaLoaded: hasWindow && controller.hasMedia
    readonly property bool fullScreen: hasWindow && window.visibility === Window.FullScreen

    component Command: QtObject {
        property string text
        // The Shortcut sequence ("window") or the key's name ("stage").
        property string key
        // The key as people call it, for tooltips.
        property string keyName: key
        // Shown after the menu label, for keys only the menu can teach.
        property bool keyInMenu: false
        property string scope
        property int keyCode: 0
        property bool autoRepeat: true
        property bool enabled: true
        property bool checkable: false
        property bool checked: false
        readonly property string menuText: keyInMenu ? text + "  " + key : text
        signal activated

        function trigger() {
            if (!enabled)
                return false;
            activated();
            return true;
        }
    }

    function stepLabel(action) {
        if (!hasWindow)
            return action;
        const step = Number(controller.seekStepSeconds);
        return action + " " + step.toFixed(step % 1 === 0 ? 0 : 1) + (step === 1 ? " Second" : " Seconds");
    }

    readonly property Command playPause: Command {
        text: actions.mediaLoaded && actions.controller.playing ? "Pause" : "Play"
        key: "Space"
        scope: "window"
        autoRepeat: false
        enabled: actions.mediaLoaded
        onActivated: {
            actions.controller.togglePlayPause();
            actions.window.revealControls();
        }
    }
    readonly property Command skipForward: Command {
        text: actions.stepLabel("Skip Forward")
        key: "Right"
        keyName: "Right Arrow"
        scope: "window"
        enabled: actions.mediaLoaded
        onActivated: {
            actions.controller.skipForward();
            actions.window.revealControls();
        }
    }
    readonly property Command skipBack: Command {
        text: actions.stepLabel("Skip Back")
        key: "Left"
        keyName: "Left Arrow"
        scope: "window"
        enabled: actions.mediaLoaded
        onActivated: {
            actions.controller.skipBackward();
            actions.window.revealControls();
        }
    }
    // "." / "," -- the editor convention (Premiere, Resolve, Final Cut, mpv).
    // Auto-repeat stays on: holding the key crawls through a passage.
    readonly property Command nextFrame: Command {
        text: "Next Frame"
        key: "."
        keyInMenu: true
        scope: "window"
        enabled: actions.mediaLoaded
        onActivated: {
            actions.controller.stepFrame(1);
            actions.window.showPositionOsd();
            actions.window.revealControls();
        }
    }
    readonly property Command previousFrame: Command {
        text: "Previous Frame"
        key: ","
        keyInMenu: true
        scope: "window"
        enabled: actions.mediaLoaded
        onActivated: {
            actions.controller.stepFrame(-1);
            actions.window.showPositionOsd();
            actions.window.revealControls();
        }
    }
    // One wheel notch (5%), the keys and the wheel being one control.
    readonly property Command volumeUp: Command {
        text: "Volume Up"
        key: "Up"
        scope: "window"
        enabled: actions.mediaLoaded
        onActivated: actions.window.nudgeVolume(0.05)
    }
    readonly property Command volumeDown: Command {
        text: "Volume Down"
        key: "Down"
        scope: "window"
        enabled: actions.mediaLoaded
        onActivated: actions.window.nudgeVolume(-0.05)
    }
    readonly property Command seekToStart: Command {
        text: "Seek to Start"
        enabled: actions.mediaLoaded
        onActivated: actions.controller.seekTo(0)
    }
    readonly property Command mute: Command {
        text: "Mute"
        key: "M"
        keyCode: Qt.Key_M
        keyInMenu: true
        scope: "stage"
        enabled: actions.mediaLoaded
        checkable: true
        checked: actions.hasWindow && actions.controller.muted
        onActivated: {
            actions.controller.toggleMute();
            actions.window.showVolumeOsd();
        }
    }
    readonly property Command captions: Command {
        text: actions.hasWindow && actions.controller.captionsVisible ? "Hide captions" : "Show captions"
        enabled: actions.hasWindow
        onActivated: actions.controller.toggleCaptions()
    }
    readonly property Command loadSubtitles: Command {
        text: "Load Subtitle File…"
        enabled: actions.mediaLoaded
        onActivated: actions.window.showSubtitleDialog()
    }
    readonly property Command quickEdit: Command {
        text: "Quick Edit"
        key: "E"
        keyCode: Qt.Key_E
        scope: "stage"
        enabled: actions.hasWindow
        onActivated: actions.window.toggleQuickEdit()
    }
    // Escape unwinds one level at a time: crop adjustment, then the sheet.
    // A stage key, so it never fires from inside one of the sheet's fields.
    readonly property Command dismissEdit: Command {
        key: "Escape"
        keyCode: Qt.Key_Escape
        scope: "stage"
        enabled: actions.hasWindow && (actions.window.cropMode || actions.window.quickEditOpen)
        onActivated: {
            if (actions.window.cropMode)
                actions.window.setCropMode(false);
            else
                actions.window.closeQuickEdit();
        }
    }
    readonly property Command fullScreenToggle: Command {
        text: actions.fullScreen ? "Exit Full Screen" : "Enter Full Screen"
        key: "F"
        keyCode: Qt.Key_F
        scope: "stage"
        enabled: actions.mediaLoaded
        onActivated: {
            actions.window.visibility = actions.fullScreen ? Window.Windowed : Window.FullScreen;
            actions.window.revealControls();
        }
    }
    // Escape leaves full screen whatever holds focus: a focused button can
    // swallow a stage key, and being unable to leave full screen is not
    // cosmetic. It stands down while Quick Edit owns Escape.
    readonly property Command leaveFullScreen: Command {
        key: "Escape"
        scope: "window"
        enabled: actions.fullScreen && !actions.window.quickEditOpen
        onActivated: {
            actions.window.visibility = Window.Windowed;
            actions.window.revealControls();
        }
    }
    readonly property Command actualSize: Command {
        text: "Actual Size"
        enabled: actions.mediaLoaded
        onActivated: actions.window.resizeToActualSize()
    }
    readonly property Command fitToScreen: Command {
        text: "Fit to Screen"
        enabled: actions.mediaLoaded
        onActivated: actions.window.resizeToFitScreen()
    }
    // Full screen owns the frame outright; padding underneath it would be
    // invisible and a frame AppKit would fight on the way out.
    readonly property Command fillScreenPadded: Command {
        text: "Fill Screen (Padded)"
        enabled: actions.mediaLoaded && !actions.fullScreen
        checkable: true
        checked: actions.hasWindow && actions.window.fillScreenPadded
        onActivated: actions.window.toggleFillScreenPadded()
    }
    readonly property Command windowHugsVideo: Command {
        text: "Window Hugs Video"
        enabled: actions.hasWindow
        checkable: true
        checked: actions.hasWindow ? actions.controller.windowHugsVideo : true
        onActivated: actions.controller.setWindowHugsVideo(!actions.controller.windowHugsVideo)
    }
    // Disabled for an HDR source: it already uses the display's extended
    // range, and a boost on top would only clip its highlights.
    readonly property Command vivid: Command {
        text: "Vivid Boost"
        key: "V"
        keyCode: Qt.Key_V
        keyInMenu: true
        scope: "stage"
        enabled: actions.mediaLoaded && actions.window.vividAvailable
        checkable: true
        checked: actions.hasWindow && actions.window.vividActive
        onActivated: actions.window.toggleVividBoost()
    }
    readonly property Command theater: Command {
        text: "Theater Dim"
        key: "T"
        keyCode: Qt.Key_T
        keyInMenu: true
        scope: "stage"
        enabled: actions.mediaLoaded
        checkable: true
        checked: actions.hasWindow && actions.window.theaterDimEnabled
        onActivated: actions.window.toggleTheaterDim()
    }
    // Pause every window, then hide the app; unhiding leaves them paused.
    readonly property Command hideAndPauseAll: Command {
        text: "Hide and Pause All"
        key: "H"
        keyCode: Qt.Key_H
        scope: "stage"
        enabled: actions.hasWindow
        onActivated: appHost.hideAndPauseAll()
    }
    readonly property Command closeWindow: Command {
        text: "Close Window"
        enabled: actions.hasWindow
        onActivated: actions.window.close()
    }

    readonly property var all: [
        playPause, skipForward, skipBack, nextFrame, previousFrame, volumeUp, volumeDown,
        seekToStart, mute, captions, loadSubtitles, quickEdit, dismissEdit, fullScreenToggle,
        leaveFullScreen, actualSize, fitToScreen, fillScreenPadded, windowHugsVideo, vivid,
        theater, hideAndPauseAll, closeWindow
    ]
    readonly property var windowKeyed: all.filter(command => command.scope === "window")

    // The video stage's key filter. True when a stage command took the key.
    function triggerStageKey(keyCode) {
        for (const command of all) {
            if (command.scope === "stage" && command.keyCode === keyCode && command.trigger())
                return true;
        }
        return false;
    }
}
