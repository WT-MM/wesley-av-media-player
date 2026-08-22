# WAM

A minimal macOS video player. Lighter than VLC, plays more formats than
QuickTime, with basic trim/export and caption generation built in.

![WAM playing a video with its transport visible](docs/media/wam-transport.png)

The UI fades out during playback:

![WAM with chrome faded away](docs/media/wam-video.png)

## Install

Download the latest `WAM-*.zip` from
[Releases](https://github.com/WT-MM/wesley-av-media-player/releases) and
unzip. The build is ad-hoc signed, so the first launch needs right-click →
Open, or:

```sh
xattr -d com.apple.quarantine WAM.app
```

Apple silicon only. To build from source, see
[docs/DEVELOPING.md](docs/DEVELOPING.md).

## Features

- Native playback of H.264, HEVC, VP9, AV1, MPEG-2, MPEG-4 SP, and VP8
  video, and AAC, AC-3/E-AC-3, FLAC, MP3, Opus, and Vorbis audio, in MP4,
  MOV, MKV, WebM, and MPEG-TS containers, up to 4K. Audio-only files work
  too. Unsupported codecs fall back to a bundled mpv/FFmpeg engine.
- CPU, energy, and GPU usage on par with QuickTime (zero GPU work during
  playback), measured in [docs/DEVELOPING.md](docs/DEVELOPING.md#measured-performance).
  Playback stays smooth under heavy system load.
- 0.25–4× playback speed with pitch preservation (toggleable in Settings).
- Live scrub previews, aspect-locked resizing, double-click to fit screen,
  playback continues when the window is unfocused or covered.
- Trim and retimed MP4 export, plus on-device subtitle generation via
  whisper.cpp.

## Keys

| Action | Control |
| --- | --- |
| Open | ⌘O, click the empty player, or drop a file |
| Play/pause | Space |
| Seek | ←/→ (step configurable in Settings) |
| Speed | The `1×` control, presets or slider |
| Fit window to screen | Double-click the video or title bar |
| Fullscreen | F |
| Quick Edit | E |

## Architecture

Demuxing is AVFoundation for MP4/MOV, plus custom Matroska and MPEG-TS
demuxers. Video decodes through VideoToolbox (libvpx for VP8). An
audio-driven clock using exact rational arithmetic schedules frames, and
decoded output goes to an `AVSampleBufferDisplayLayer` composited by
WindowServer, so video never enters the UI toolkit's render loop.

More detail: [docs/DEVELOPING.md](docs/DEVELOPING.md),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/PRODUCT.md](docs/PRODUCT.md)
