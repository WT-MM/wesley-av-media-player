# WAM

**Wesley's Audiovisual Media Player** combines a minimal desktop player with
the lightweight editing tasks that usually require opening a separate editor.

WAM 0.3.1 uses a Qt Quick shell over libmpv. FFmpeg/libmpv provide broad codec,
container, subtitle, local-file, and network-stream support; supported platform
decoders are selected automatically. Playback frames render directly into Qt's
active OpenGL scene target without an application-owned CPU pixel copy or an
extra full-video UI framebuffer. FFmpeg handles background exports and
whisper.cpp creates private, on-device captions.

## Current product surface

- Edge-to-edge, borderless video with a compact translucent transport that
  fades while watching
- Light appearance by default, with Light, Dark, and System choices
- Local files, URLs, drag/drop, hardware decoding with safe software fallback,
  subtitles, audio-only media, and the formats supported by the packaged mpv/
  FFmpeg build
- Space play/pause, Left/Right five-second seek, timeline scrubbing, volume,
  mute, fullscreen, caption visibility, and 0.25–4× playback
- Pitch-preserved playback speed by default
- Closable Quick Edit sheet with IN/OUT trim, retimed MP4 export, caption
  generation, and appearance controls
- Cancellable local SRT generation; completed captions are verified, attached,
  and enabled
- Standalone macOS packaging and native Windows/Linux package workflows with
  Qt, mpv/FFmpeg, whisper.cpp, and the caption model included

The older ImGui prototype remains in `src/main.cpp` as migration reference but
is not part of the WAM 0.3.1 executable.

## Build on macOS

Requirements are CMake, Qt 6.9 or later, mpv, FFmpeg, and pkg-config. The release
workflow pins Qt 6.11.1.

```sh
brew install cmake ninja qt mpv ffmpeg pkg-config
cmake -S . -B build -G Ninja \
  -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

The development app is `build/WAM.app`. Build the local caption runtime, install
Qt into a staging app, then add WAM's media dependencies:

```sh
scripts/build_whisper.sh build/runtime/whisper-cli
scripts/fetch_whisper_model.sh build/runtime/models/ggml-base.en.bin
cmake --install build --prefix stage
scripts/bundle_macos.zsh \
  stage/WAM.app \
  build/runtime/whisper-cli \
  build/runtime/models/ggml-base.en.bin
```

## Controls

| Action | Control |
| --- | --- |
| Open media | Command/Ctrl+O, click the empty player, or drop a file |
| Play/pause | Space |
| Seek five seconds | Left/Right |
| Scrub | Timeline |
| Mute and volume | Transport controls |
| Cycle common speeds | `1×` transport control |
| Fullscreen | F or double-click video |
| Quick Edit | E or pencil control |
| Close Quick Edit | Escape or close control |

## Performance policy

1. Playback never round-trips frames through an application-owned CPU buffer.
2. The Qt shell is retained and event-driven; no UI polling loop runs while the
   player is paused or its fade is finished.
3. Video draws into the current scene target, avoiding a 7.9 MiB 1080p or
   31.6 MiB 4K RGBA intermediate before driver buffering.
4. Hardware decode is preferred only when libmpv considers the path safe.
5. Export and caption work run off the UI/render threads and support bounded
   process-tree cancellation.
6. Persistent blur, full-screen UI layers, and perpetual animation are excluded
   unless measurements justify them.
7. CPU, GPU, memory, power, startup, seek latency, and dropped frames are release
   gates—not assumptions derived from a toolkit choice.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/PRODUCT.md](docs/PRODUCT.md), and
[docs/QT_QUICK_MIGRATION.md](docs/QT_QUICK_MIGRATION.md). The current measured
smoke baseline is recorded in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).
