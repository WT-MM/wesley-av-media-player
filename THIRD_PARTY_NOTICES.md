# Third-party notices

WAM packages software from independent projects. Their licenses and copyright
notices continue to apply; WAM does not relicense them.

- Qt 6 Core, Gui, Qml, Quick, Quick Controls, OpenGL, platform plugins, and QML
  imports — LGPL-3.0/GPL options: https://www.qt.io/licensing
- mpv / libmpv — GPL-2.0-or-later by default; LGPL configurations require a
  deliberately different build: https://github.com/mpv-player/mpv
- FFmpeg — LGPL-2.1-or-later, or GPL-2.0-or-later when GPL components are
  enabled. The package-manager builds used during development may enable GPL
  codecs: https://ffmpeg.org/legal.html
- whisper.cpp / ggml — MIT: https://github.com/ggml-org/whisper.cpp
- libplacebo and codec/font/network libraries included transitively by mpv and
  FFmpeg retain the licenses shipped by their projects.

Dear ImGui, SDL, and portable-file-dialogs remain in the non-shipping legacy
prototype source but are not linked into WAM 0.3.

Anyone distributing WAM must satisfy the source, notice, replacement/relinking,
and corresponding-source terms of the exact libraries in that artifact. Public
distribution also requires a deliberate WAM license decision: current default
mpv and GPL-enabled FFmpeg inputs are not compatible with treating the resulting
binary as closed proprietary software. The release process must archive exact
versions, build flags, source URLs/hashes, license texts, and an SBOM.
