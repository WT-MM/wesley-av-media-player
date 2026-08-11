# WAM Qt Quick playback bridge

This bridge keeps the interface and media engine deliberately separate:

- `PlayerController` is the QML-facing playback model. Normal libmpv client
  calls and property/event delivery happen on the GUI thread.
- `MpvVideoItem` inserts a `QSGRenderNode` into Qt Quick's render thread. It
  uses libmpv's current render API (`mpv/render.h` + `mpv/render_gl.h`), not the
  removed `opengl-cb` API.
- `PlayerCore` is a private shared-lifetime boundary. It prevents the mpv core
  from being destroyed while the scene graph still owns a render node.

## Host requirements

The target needs Qt 6.9 or newer components `Core`, `Gui`, `Qml`, `Quick`,
`QuickControls2`, and `OpenGL`, plus libmpv and C++20. Enable Qt AUTOMOC (or use
`qt_add_executable`) and compile these sources:

```text
src/qt/player_controller.cpp
src/qt/player_core.cpp
src/qt/mpv_video_item.cpp
```

Before constructing the first `QQuickWindow`, select the OpenGL scene-graph
backend and register the item:

```cpp
QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
// Construct QGuiApplication, then restore LC_NUMERIC for libmpv:
std::setlocale(LC_NUMERIC, "C");
wam::qt::registerWamQtTypes();
```

Expose one long-lived `PlayerController` as `player` (or another QML context
property), then use:

```qml
import Wam 1.0

MpvVideo {
    anchors.fill: parent
    controller: player
}
```

`MpvVideo` must fill the render surface and be declared before overlay
controls. This is the condition that permits direct rendering into Qt's active
target. It avoids a full-window intermediate framebuffer, its video-sized GPU
allocation, and the additional texture-composition pass imposed by
`QQuickFramebufferObject`. If WAM later needs independently transformed or
clipped video tiles, add a separate FBO-backed item for that specialized mode
instead of slowing the primary player path.

The QML window owns dialogs and fullscreen state. Connect
`openFileDialogRequested` to a `QtQuick.Dialogs.FileDialog` and
`fullscreenToggleRequested` to the root window. For macOS's borderless native
chrome, the root can use `Qt.ExpandedClientAreaHint` and
`Qt.NoTitleBarBackgroundHint`; keep controls inside `SafeArea.margins` while
letting the video extend edge-to-edge.
