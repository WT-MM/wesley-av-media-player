# Third-party notices

WAM packages software from independent projects. Their licenses and copyright
notices continue to apply; WAM does not relicense them.

- Qt 6 Core, Gui, Qml, Quick, Quick Controls, OpenGL, DBus, Widgets, platform
  plugins, and QML imports — LGPL-3.0/GPL options:
  https://www.qt.io/licensing
- mpv / libmpv — GPL-2.0-or-later by default; LGPL configurations require a
  deliberately different build: https://github.com/mpv-player/mpv
- FFmpeg — LGPL-2.1-or-later, or GPL-2.0-or-later when GPL components are
  enabled. The package-manager builds used during development may enable GPL
  codecs: https://ffmpeg.org/legal.html
- libvpx — BSD-3-Clause, with the accompanying patent grant. WAM links it
  directly for the software VP8 decode stage:
  https://github.com/webmproject/libvpx
- whisper.cpp / ggml — MIT: https://github.com/ggml-org/whisper.cpp
- The bundled `ggml-base.en` speech model is a GGML conversion of OpenAI's
  Whisper `base.en`, distributed under MIT:
  https://huggingface.co/ggerganov/whisper.cpp
- Qt's own bundled and transitively linked libraries — including ICU, HarfBuzz,
  FreeType, PCRE2, libpng, libjpeg-turbo, libtiff, libwebp, Brotli, zstd, xz,
  OpenSSL, GLib, and double-conversion — retain the licenses shipped by their
  projects.
- libplacebo and the codec/font/network libraries included transitively by mpv
  and FFmpeg retain the licenses shipped by their projects.

Dear ImGui, SDL, and portable-file-dialogs remain in the non-shipping legacy
prototype source but are not linked into WAM.

Anyone distributing WAM must satisfy the source, notice, replacement/relinking,
and corresponding-source terms of the exact libraries in that artifact. The
current default mpv and GPL-enabled FFmpeg inputs are not compatible with
treating the resulting binary as closed proprietary software. WAM's own source
is published in full at https://github.com/WT-MM/wesley-av-media-player, and
every third-party input is an unmodified package-manager or checksum-pinned
upstream build, obtainable from the URLs above; the release process should
additionally archive exact versions, build flags, source URLs/hashes, license
texts, and an SBOM.
