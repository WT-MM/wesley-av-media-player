import QtQuick

// The application's ONE desktop menu bar.
//
// WAM is a multi-window player: every open gets its own window, and all of
// them play at once. A menu bar instantiated inside qml/Main.qml would
// therefore be instantiated N times, and -- worse -- would disappear entirely
// when the last window closed, which is precisely the state macOS expects an
// app to survive with its menus intact (Cmd-O or a Dock click then opens a
// fresh window).
//
// So the menu bar is created once, at app level, by WindowManager, with no
// owning window at all. Its Playback and View items follow the FOCUSED
// window through `appHost.focusedController` / `appHost.focusedWindow`, both
// of which are null when nothing is open -- AppMenuBar.qml guards every use.
// Preferences, About, Quit and Hide and Pause All are app-level actions and
// address `appHost` directly.
AppMenuBar {
    controller: appHost.focusedController
    appRoot: appHost.focusedWindow
    host: appHost
}
