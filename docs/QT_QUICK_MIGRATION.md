# Qt Quick migration assessment

Date: 2026-08-10
Target Qt release: 6.11.1 (pin the patch version in release CI)

## Decision

Replace SDL2 + Dear ImGui + portable-file-dialogs with Qt 6 Quick/QML for the
consumer interface. Keep the existing C++ playback, export, caption, and state
services. Do not rewrite FFmpeg, codecs, or whisper.cpp as part of the UI
migration.

Dear ImGui is efficient at drawing immediate-mode interfaces, but it is the
wrong default abstraction for a polished desktop media application. WAM is
currently hand-implementing controls, focus behavior, scaling, dialogs,
menus, animation, theme propagation, and accessibility semantics. Qt Quick
has a retained GPU scene graph, native platform integration, declarative
transitions, accessible controls, high-DPI behavior, and native macOS menu
bars. Qt 6.8 and newer implement the QML `MenuBar` natively on macOS.

Qt Quick is not free in binary size or memory. It is nevertheless the better
product trade because video decode, cache, GPU surfaces, and the caption model
already dominate WAM's resources. The UI should be benchmarked and budgeted,
not treated as automatically fast merely because it is Qt.

The alternatives were considered rather than assuming that Qt is the answer:

| UI path | Result |
| --- | --- |
| Keep/customize Dear ImGui | Lowest incremental runtime cost, but WAM would continue owning basic desktop behavior and accessibility; reject for the shipping consumer UI |
| Qt Widgets | Mature and accessible, but awkward for a floating translucent overlay and fluid responsive composition; reasonable for utilities, not the player surface |
| Qt Quick/QML | Best balance of cross-platform reach, GPU composition, native integration, accessibility, and design control; select |
| AppKit + WinUI + GTK/libadwaita | Potentially best per-platform integration, but creates three UI implementations and three video-hosting paths; revisit only if Qt fails measured platform UX gates |
| SDL plus a UI written from scratch | Maximum control but recreates text shaping, input methods, accessibility, menus, dialogs, scaling, and automation; unjustified product/security burden |
| Electron/web UI | Easy styling but materially worse baseline package/RSS and an additional browser compositor; reject for WAM's performance goal |
| Flutter/other custom cross-platform renderer | Attractive visuals, but a second runtime and less direct desktop/native/libmpv integration than Qt; no demonstrated advantage for this project |

## Rendering constraint that controls the migration

The public libmpv render API in the version currently installed exposes an
OpenGL backend and a slow software backend. It does not expose Metal, D3D11,
or Vulkan render targets. Qt Quick normally uses Metal on macOS, D3D11/12 on
Windows, and Vulkan/OpenGL on Linux through its Rendering Hardware Interface.
Therefore Qt Quick cannot simply keep its native backend while libmpv writes
directly into the same target.

For the first production Qt release:

1. Call `QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL)` before
   creating/loading the first QML window.
2. Implement the video surface as a `QQuickItem` backed by a direct
   `QSGRenderNode`, or use the documented underlay hook, so libmpv renders into
   the scene graph's current framebuffer and QML draws controls afterward.
3. Do not use `QQuickFramebufferObject` for the final path. Qt documents it as
   a legacy, OpenGL-only API, and it adds a video-sized offscreen target plus a
   composite pass. It is acceptable only as a short-lived integration spike.
4. Create and destroy `mpv_render_context` on the Qt scene-graph render thread
   while a `QOpenGLContext` is current. The current `MediaEngine` constructor
   creates it too early and must be split into client initialization and render
   initialization.
5. Replace `SDL_GL_GetProcAddress()` with
   `QOpenGLContext::currentContext()->getProcAddress()`.
6. Replace the SDL wake event with a queued Qt call that requests an item/window
   update. Only request a frame when `mpv_render_context_update()` reports one.
   Paused and empty windows must remain event-driven.
7. If `MPV_RENDER_PARAM_ADVANCED_CONTROL` is enabled for direct rendering,
   move synchronous mpv commands to a controller thread or use the async mpv
   APIs as required by libmpv's threading contract.

The direct node/underlay matters. An RGBA8 intermediate costs about 7.9 MiB at
1920x1080 and 31.6 MiB at 3840x2160, before double buffering or driver
allocations. Avoiding that target also avoids one full-screen texture sample
per frame.

This OpenGL choice is no worse than WAM 0.2's existing renderer, but it prevents
the UI migration by itself from delivering a native Metal/D3D/Vulkan path.
That must be a separate, measured renderer project:

- Keep Qt Quick for the interface.
- Build per-platform video presentation that exposes Metal textures on macOS,
  D3D11 textures on Windows, and dma-buf/Vulkan images on Linux.
- Import those resources into Qt's scene graph through `QQuickRhiItem` or a
  custom render node. `QQuickRhiItem` is public, but the QRhi classes needed by
  an implementation have limited compatibility guarantees and require
  `Qt::GuiPrivate`; pinning the Qt minor version and running GPU tests on each
  OS is mandatory.
- This path requires replacing libmpv's presentation boundary (for example,
  FFmpeg decode plus libplacebo/custom presentation). It is not a UI refactor.
  Do it only after benchmark data demonstrates that the OpenGL interop is a
  material power, HDR, or latency bottleneck.

## Source layout and ownership

Keep QML visual and interaction logic thin. C++ remains the source of truth.

```text
src/
  main.cpp                  QGuiApplication and QQmlApplicationEngine only
  player_controller.*       Q_PROPERTY/Q_INVOKABLE facade over MediaEngine
  video_item.*              QQuickItem and render-thread object
  playlist_model.*          QAbstractListModel
  media_engine.*            libmpv client/render split
  jobs.*                    unchanged backend
  caption_service.*         unchanged backend
  state_store.*             unchanged persistence format
qml/
  Main.qml
  PlayerView.qml
  ControlOverlay.qml
  Timeline.qml
  EditorDrawer.qml
  QueueDrawer.qml
  InspectorDrawer.qml
  controls/IconButton.qml
  controls/PillButton.qml
  controls/Theme.qml
assets/icons/
```

Use `QtQuick.Controls` for application windows, menus, actions, text inputs,
accessibility, and native behavior. Custom-draw the small player control set
from `QtQuick.Templates`/basic QML primitives so it has a deliberate WAM visual
language instead of a stock desktop-widget appearance. Keep native menus and
native `QtQuick.Dialogs.FileDialog`; do not recreate them.

Light is the WAM default. The persisted `AppearanceTheme` values remain
`Light`, `Dark`, and `System`. Qt 6.8 can apply/follow these through
`QGuiApplication::styleHints()->setColorScheme()` and `colorSchemeChanged`, so
the CoreFoundation/registry/GTK theme polling in `main.cpp` can be removed.

The overlay should use one translucent fill and no live backdrop blur by
default. A true blur generally adds an offscreen pass. Fade opacity for roughly
140-180 ms, then set the overlay `visible: false`. No animation, timer, busy
indicator, shader, or binding may keep the scene graph rendering after the
fade finishes.

## CMake change

The target should converge on the following shape. Release CI pins 6.11.1;
`find_package()` accepts later 6.11 patch releases for local development.

```cmake
cmake_minimum_required(VERSION 3.24)
project(WAM VERSION 0.3.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(GNUInstallDirs)
find_package(Qt6 6.11 REQUIRED COMPONENTS
  Core Gui Qml Quick QuickControls2 OpenGL)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(wam MACOSX_BUNDLE WIN32
  src/main.cpp
  src/player_controller.cpp src/player_controller.hpp
  src/playlist_model.cpp src/playlist_model.hpp
  src/video_item.cpp src/video_item.hpp
  src/media_engine.cpp src/media_engine.hpp
  src/jobs.cpp src/jobs.hpp
  src/caption_service.cpp src/caption_service.hpp
  src/state_store.cpp src/state_store.hpp)

qt_add_qml_module(wam
  URI WAM
  VERSION 1.0
  QML_FILES
    qml/Main.qml
    qml/PlayerView.qml
    qml/ControlOverlay.qml
    qml/Timeline.qml
    qml/EditorDrawer.qml
    qml/QueueDrawer.qml
    qml/InspectorDrawer.qml
    qml/controls/IconButton.qml
    qml/controls/PillButton.qml
    qml/controls/Theme.qml
  RESOURCES
    assets/icons/play.svg
    assets/icons/pause.svg)

target_link_libraries(wam PRIVATE
  Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick
  Qt6::QuickControls2 Qt6::OpenGL PkgConfig::MPV)

set_target_properties(wam PROPERTIES
  OUTPUT_NAME "WAM"
  MACOSX_BUNDLE TRUE
  WIN32_EXECUTABLE TRUE
  MACOSX_BUNDLE_BUNDLE_NAME "Wesley's Audiovisual Media Player"
  MACOSX_BUNDLE_GUI_IDENTIFIER "com.wesleymaa.wam"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}")

install(TARGETS wam
  BUNDLE DESTINATION .
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

qt_generate_deploy_qml_app_script(
  TARGET wam
  OUTPUT_SCRIPT wam_qt_deploy
  MACOS_BUNDLE_POST_BUILD
  NO_TRANSLATIONS
  NO_UNSUPPORTED_PLATFORM_ERROR
  DEPLOY_USER_QML_MODULES_ON_UNSUPPORTED_PLATFORM)
install(SCRIPT ${wam_qt_deploy})
```

If SVG files are loaded through `Image`, also add `Svg` to `find_package()` and
`Qt6::Svg`, and verify the `qsvg` image plugin is deployed. If icons are drawn
with `Shape` paths or an icon font, QtSvg is unnecessary.

Remove all of the following from CMake once the Qt UI is complete:

- SDL2 discovery/FetchContent and `WAM_SDL_TARGET`
- Dear ImGui FetchContent, static target, sources, includes, and link entry
- portable-file-dialogs FetchContent and include path
- direct `OpenGL::GL` linkage if the final Qt OpenGL integration no longer
  needs it independently of `Qt6::OpenGL`

Do not keep SDL just to detect battery state. Implement the small platform power
probe using IOKit on macOS, `GetSystemPowerStatus()` on Windows, and sysfs/UPower
on Linux. This also eliminates the current hidden SDL2-compat-to-SDL3 runtime
dependency.

## macOS build and package

### Build dependencies

Keep CMake, Ninja, pkg-config, mpv, FFmpeg, and the pinned whisper build. Add a
shared Qt 6.11.1 installation containing Qt Base and Qt Declarative. Remove
SDL2. If the platform power probe uses IOKit, link the system IOKit framework.

For release automation, install the official open-source Qt 6.11.1 shared
binaries with `aqtinstall`/`install-qt-action`, pin both the tool/action commit
and Qt patch version, and archive the resolved package manifest. Homebrew's
`qt` formula is useful locally but is not release-reproducible unless its exact
formula revision and bottles are archived.

### Package order

1. Configure/build/test WAM.
2. Build the pinned whisper CLI and fetch/verify the pinned model.
3. Run `cmake --install build --prefix stage`. The generated Qt deployment
   script invokes the supported QML/macOS deployment machinery and creates
   `stage/WAM.app` with Qt frameworks, QML modules, and platform plugins.
4. Add FFmpeg, whisper-cli, the model, README, and notices to that installed
   app, and recursively bundle their non-system dependencies.
5. Sign nested code inside-out, sign WAM last, verify, then zip/notarize.

`scripts/bundle_macos.zsh` currently starts by deleting
`Contents/Frameworks`. That would erase every deployed Qt framework. Before a
Qt build can ship, make it additive: remove only files owned by WAM's prior
media manifest, preserve `*.framework`, `PlugIns`, and `Resources/qml`, then
copy/rewrite only mpv/FFmpeg/whisper dependencies. Keep the executable basename
`WAM`; a long display name belongs in `Info.plist`.

Required package checks:

```sh
test -x stage/WAM.app/Contents/MacOS/WAM
test -d stage/WAM.app/Contents/Frameworks/QtQuick.framework
test -d stage/WAM.app/Contents/Resources/qml/QtQuick
test -d stage/WAM.app/Contents/PlugIns/platforms
test -x stage/WAM.app/Contents/Resources/tools/ffmpeg
test -x stage/WAM.app/Contents/Resources/tools/whisper-cli
test -s stage/WAM.app/Contents/Resources/models/ggml-base.en.bin
codesign --verify --deep --strict stage/WAM.app
```

Also inspect every Mach-O dependency and rpath and fail if `/opt/homebrew`, the
Qt build directory, or the CI workspace remains. Launch the installed app, not
the build-tree app, on a clean macOS account.

## Windows build and package

### MSYS2 dependency delta

The least disruptive route retains the existing UCRT64 toolchain and adds the
matching MSYS2 Qt packages:

```text
mingw-w64-ucrt-x86_64-qt6-base
mingw-w64-ucrt-x86_64-qt6-declarative
mingw-w64-ucrt-x86_64-qt6-shadertools   (only if QML shaders are added)
mingw-w64-ucrt-x86_64-qt6-svg           (only for SVG Image loading)
```

Remove `mingw-w64-ucrt-x86_64-SDL2`. Keep mpv, FFmpeg, CMake, Ninja, pkgconf,
GCC, curl, and make. All MSYS2 dependencies and Qt must come from the same
UCRT64 snapshot; mixing an official MinGW Qt build with a different MSYS2 GCC
runtime is an avoidable C++ ABI risk. Record `pacman -Q` in every artifact.

### Package order

1. Build/tests as today.
2. `cmake --install build --prefix package-root` so the generated deployment
   script runs `windeployqt`/QML import scanning.
3. Add FFmpeg, whisper-cli, model, README, notices, and their dependency graphs.
4. Keep the existing recursive `ldd` copy as a check for mpv/tool dependencies;
   do not let it replace Qt DLLs with files from another toolchain.
5. Zip the installed tree or feed it to WiX/MSIX. Dynamic Qt DLLs must remain
   replaceable; a single statically linked EXE is not the recommended LGPL
   distribution.

The exact installed paths depend on the chosen CMake install layout, but CI
must assert at least:

```text
WAM.exe (or bin/WAM.exe)
Qt6Core.dll
Qt6Gui.dll
Qt6Qml.dll
Qt6Quick.dll
platforms/qwindows.dll
qml/QtQuick/...
tools/ffmpeg.exe
tools/whisper-cli.exe
models/ggml-base.en.bin
```

Add a `--verify-runtime` application mode that initializes `QGuiApplication`,
loads the compiled QML module with the offscreen platform, verifies libmpv can
be created, prints resolved tool/model paths, and exits. Run it from the final
package in CI; file-existence checks alone do not detect a missing QML plugin.

## Linux build and package

### Dependencies

For local distro builds, replace `libsdl2-dev` with Qt Base/Declarative
development and runtime QML packages. Ubuntu names include:

```text
qt6-base-dev
qt6-declarative-dev
qt6-declarative-dev-tools
qt6-tools-dev-tools
qml6-module-qtquick
qml6-module-qtquick-controls
qml6-module-qtquick-dialogs
qml6-module-qtquick-layouts
```

Keep `libmpv-dev`, `libgl-dev`, FFmpeg, CMake, Ninja, pkg-config, and the
AppImage/FUSE requirements. Ubuntu 24.04's distro Qt is older than the selected
6.11 UI baseline, so release CI should install pinned official Qt 6.11.1
binaries or build the shared Qt subset from the pinned source archive. Do not
silently compile release artifacts against whichever distro Qt happens to be
current.

### AppImage

Install into `AppDir/usr` with CMake first. Ensure the Qt deployment step or the
Qt linuxdeploy plugin copies:

- Qt Core/Gui/Qml/Quick/QuickControls runtime libraries;
- recursively imported QML modules;
- `platforms/libqxcb.so` and all xcb/xkb dependencies;
- the Wayland client plugin and dependencies if native Wayland is a supported
  release target;
- image format plugins actually used by WAM;
- `qt.conf` with bundle-relative plugin and QML paths.

Then run linuxdeploy over WAM, FFmpeg, and whisper-cli as separate executables,
as the current workflow does. Pin linuxdeploy/plugin release URLs and hashes;
`continuous` without a checksum is not a reproducible or supply-chain-safe
input.

After extracting the AppImage, run `ldd` over WAM, every Qt QML/platform
plugin, FFmpeg, and whisper-cli, and fail on `not found` or dependencies that
should have been bundled. Smoke-test both X11/XWayland and native Wayland on a
clean VM. An Ubuntu-built AppImage is not automatically compatible with every
Linux distribution; publish the glibc baseline and tested distros.

## CI workflow delta

For all three jobs:

- define one `QT_VERSION=6.11.1` release variable;
- cache Qt by version, OS, architecture, and toolchain;
- print/archive `qmake6 -query`, `qtpaths6 --query`, compiler versions, package
  manager manifests, and hashes of every shipped executable/library;
- build QML with `qt_add_qml_module` so qmlcache/AOT generation runs;
- run `qmllint` and formatting checks in addition to C++ tests;
- run backend unit/integration tests without a display;
- run the final package's `--verify-runtime` mode;
- launch the final GUI artifact on a real OS runner and exercise open, play,
  pause, seek, fade/reveal controls, light/dark, export, and captions;
- upload license texts, SBOM, and source/build manifest beside each artifact.

Do not claim Windows/Linux standalone validation until those final artifacts
have launched on their native runners.

## Licensing and notices

This is a release blocker, not optional documentation.

The recommended Qt modules (Core, Gui, Qml, Quick, Quick Controls, and OpenGL)
are available under LGPL-3.0/GPL options. Use dynamically linked shared Qt
libraries. Do not statically link open-source Qt for a proprietary-style
distribution unless the complete LGPL relinking requirements are deliberately
implemented; a commercial Qt license is the other route. The GPL-only Qt
modules listed by Qt are not needed for this migration. Qt's build tools are
GPLv3 with the Qt GPL exception; running them to produce WAM does not by itself
change WAM's license.

Every platform artifact should include:

- the full LGPL-3.0 and GPL-3.0 license texts (LGPLv3 incorporates GPLv3);
- a prominent Qt 6.11.1 notice naming every shipped module/plugin;
- Qt copyright notices and the third-party attributions for the files actually
  shipped;
- the Qt 6.11.1 SPDX SBOM subset (Qt installations provide SBOM files from
  6.8 onward), plus a WAM SBOM for mpv, FFmpeg, whisper.cpp, model, codecs,
  fonts, icons, and platform libraries;
- exact source URLs, archive hashes, build options, patches, and instructions
  for replacing/relinking the shared Qt libraries;
- corresponding source or a durable, valid source offer for every copyleft
  dependency that requires it.

The current `THIRD_PARTY_NOTICES.md` is a useful index but links alone are not a
complete binary-distribution compliance package. Remove SDL2, Dear ImGui, and
portable-file-dialogs after the migration and add Qt plus any icon library.

There is also a pre-existing product-level choice to resolve. The current
Homebrew/MSYS2 mpv/FFmpeg inputs appear to include GPL-enabled components such
as x264/x265, and the notice describes libmpv as GPL-2.0-or-later by default.
For public distribution, either:

1. license WAM compatibly (the straightforward choice for these current inputs
   is GPL-3.0-or-later), publish complete corresponding source/build material,
   and satisfy each packaged component; or
2. deliberately build LGPL-mode mpv and an LGPL-only FFmpeg dependency graph,
   then satisfy LGPL dynamic-link/replacement/source requirements.

Adding Qt does not create this issue, but it must not be hidden by a UI
migration. WAM currently has no committed top-level license file or public
source remote, so a public binary release should wait until that choice is
implemented and reviewed. This document is engineering guidance, not legal
advice.

## Expected resource tradeoffs

Current measured package composition on the development Mac:

| Item | Size |
| --- | ---: |
| WAM 0.2 app | 210 MiB |
| Caption model | 141 MiB |
| Existing bundled frameworks/libraries | 64 MiB |
| Existing tools | 3.5 MiB |

A local minimal Qt 6.11.1 Quick Controls deployment using the Homebrew shared
Qt build occupied about 86 MiB before WAM/media integration. Roughly 32 MiB of
that probe was ICU data and the rest was Qt frameworks, plugins, and their
dependencies. WAM already ships some overlapping libraries, and SDL/ImGui will
be removed, so the figures are not directly additive. A realistic initial
expectation is a net package increase of 45-80 MiB, yielding roughly 255-290
MiB with the current unquantized caption model. Measure the real artifact.

Likely runtime effects, to be verified rather than promised:

| Metric | Expected Qt Quick change |
| --- | --- |
| Idle CPU | Can remain approximately zero if all animations/timers stop and updates are event-driven |
| Playback CPU | Small UI-thread/scene-graph overhead; decode/render should still dominate |
| Idle memory | Approximately +25-60 MiB for Qt/QML/scene graph and plugins |
| Active memory | Approximately +30-80 MiB; direct rendering avoids an additional video-sized FBO |
| GPU work | One cheap translucent overlay during playback; fade draws only for its short transition |
| Power | Similar to current OpenGL composition initially; blur, always-running animations, and Retina-sized intermediates would regress it |
| Startup | More dynamic libraries and QML runtime; compiled QML and plugin pruning should constrain the regression |

Controls should not use `ShaderEffectSource`, persistent blur, `layer.enabled`,
unnecessary clipping, complex JavaScript inside animation frames, or dynamic
QML role types. Use C++ list models, batch backend signals, lazy-create editor
panels, and compile QML. Qt's own performance guidance specifically recommends
event-driven work, simple delegates/bindings, avoiding clipping/overdraw, and
precompiling QML.

## Acceptance gates before switching the shipping UI

- Pixel/interaction review at 1x and 2x scaling on all three platforms.
- VoiceOver, Narrator, and Orca keyboard/accessibility pass.
- Native menu, file dialog, drag/drop, shortcuts, fullscreen, always-on-top,
  and multi-monitor pass.
- Paused/end-of-file CPU remains within 0.2% on the current Mac benchmark.
- No more than 60 MiB idle and 80 MiB active memory regression without a
  documented reason.
- No additional full-video FBO in the direct rendering path.
- 4K60 H.264/HEVC/AV1 frame-drop and A/V-sync results no worse than WAM 0.2.
- Caption and export integration tests unchanged and passing.
- Final packages launch without Qt installed on clean macOS, Windows, and
  Linux machines.
- All dependency, rpath/DLL/SO, signature, SBOM, license, and source-offer
  checks pass.

## Primary references

- Qt Quick performance: https://doc.qt.io/qt-6/qtquick-performance.html
- Qt Quick Controls styles: https://doc.qt.io/qt-6/qtquickcontrols-styles.html
- Native QML macOS menu bar: https://doc.qt.io/qt-6/qml-qtquick-controls-menubar.html
- QML deployment script: https://doc.qt.io/qt-6/qt-generate-deploy-qml-app-script.html
- macOS deployment: https://doc.qt.io/qt-6/macos-deployment.html
- Windows deployment: https://doc.qt.io/qt-6/windows-deployment.html
- Linux deployment: https://doc.qt.io/qt-6/linux-deployment.html
- Legacy FBO warning: https://doc.qt.io/qt-6/qquickframebufferobject.html
- RHI item and compatibility limits: https://doc.qt.io/qt-6/qquickrhiitem.html
- Qt licensing: https://doc.qt.io/qt-6/licensing.html
- Qt SBOM: https://doc.qt.io/qt-6/sbom.html
- libmpv integration approaches: https://github.com/mpv-player/mpv-examples/tree/master/libmpv
