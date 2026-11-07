import QtQuick
import Qt.labs.platform as Platform

// A menu item for one PlayerActions command.
//
// The check mark is written imperatively, never bound: Qt.labs.platform
// flips a checkable item's `checked` itself on a click, and the command may
// decline (or another path may change the state later). sync() runs after
// every click, on every change of the command's state, and when focus moves
// to another window's command, so the mark always shows the real state.
Platform.MenuItem {
    id: item

    required property var command

    text: command.menuText
    enabled: command.enabled
    checkable: command.checkable

    function sync() {
        if (checkable)
            checked = command.checked;
    }

    onTriggered: {
        command.trigger();
        sync();
    }
    onCommandChanged: sync()
    Component.onCompleted: sync()
    onCheckableChanged: sync()

    readonly property Connections watcher: Connections {
        target: item.command
        function onCheckedChanged() {
            item.sync();
        }
    }
}
