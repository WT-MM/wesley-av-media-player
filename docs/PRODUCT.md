# Product direction

WAM's goal is to make playback, understanding, and lightweight editing feel
like one continuous action.

## Delivered in 0.3

- Qt Quick consumer shell with native platform integration and accessibility
- Edge-to-edge player, compact neutral transport, rapid fade/reveal, light
  default, Dark/System choices, and a closable Quick Edit surface
- Direct full-window libmpv scene rendering without a second video-sized FBO
- Hardware-decoded playback with safe fallback, speed/pitch control, drag/drop,
  fullscreen, five-second keyboard seeking, and throttled timeline scrubbing
- Non-destructive trim/retime export and verified, cancellable local captions
- Additive standalone Qt/media packaging definitions for macOS, Windows, Linux

## Feature-parity work

- Native menu/command palette for tracks, chapters, queue, repeat, A–B loop,
  frame stepping, subtitle/audio delay, devices, snapshots, and recording
- Mini-player, always-on-top, picture-in-picture, multiple windows, and history
- Video/color/aspect/rotation/deinterlace controls and shader/filter management
- Optical media, capture devices, AirPlay/Chromecast, and UPnP discovery
- User-remappable shortcuts and searchable settings

The legacy prototype contains several of these backend commands, but a feature
is not considered shipped until it is reconnected to the Qt shell, tested, and
included in standalone packages.

## Performance work

- Native Metal presentation on macOS, D3D on Windows, and Vulkan/dma-buf on Linux
- Representative 4K/HDR/AV1 benchmark corpus and automated regression dashboard
- Frame-indexed seeks, predictive cache warming, and background poster probing
- Process-isolated demux/decode for hostile files
- Per-codec power policies and renderer diagnostics based on measurements

## Editor and caption work

- Thumbnail/waveform timeline, frame snapping, lossless remux cuts, undo/redo
- HDR/10-bit/multi-track export, crop/rotate, fades, overlays, loudness, and GIF
- Multi-clip projects and background render queue
- Live captions, multilingual detection/translation, speaker labels, transcript
  navigation, word-level editing, and accessible subtitle styling
