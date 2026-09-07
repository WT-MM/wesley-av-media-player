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

- Native playback of H.264 (through High 10 and 4:2:2), HEVC (8/10-bit,
  including 4:2:2), VP9 and AV1 (including 10-bit), MPEG-2, MPEG-4 SP,
  VP8, ProRes 422 and 4444/XQ (opaque; alpha is ignored), and Motion
  JPEG video, and AAC, AC-3/E-AC-3, ALAC, ADPCM, FLAC, MP3, Opus, and
  Vorbis audio, in MP4, MOV, MKV, WebM, and MPEG-TS containers, up to
  4K. Audio-only files work too, down to 8 kHz. Unsupported formats
  (MPEG-4 ASP, DTS, TrueHD, WMV/VC-1, RealMedia, Theora, and fragmented
  or unfinished MP4s) fall back to a bundled mpv/FFmpeg engine; native
  MPEG-4 ASP and DTS/TrueHD decoding is implemented but disabled by
  default pending more work (see [docs/DEVELOPING.md](docs/DEVELOPING.md)).
- HDR and Dolby Vision (profile 8 base layer) play in MKV; portrait and
  rotated video, including portrait 4K, display at the right orientation;
  BT.601/SD colorimetry reads correctly instead of defaulting to HD.
- Subtitle and caption tracks read natively from the container: PGS and
  VobSub bitmap subtitles, MP4 timed text (tx3g), and CEA-608 closed
  captions. Off by default like other subtitle tracks; turn them on in
  the Subtitles menu.
- CPU, energy, and GPU usage on par with QuickTime (zero GPU work during
  playback), measured in [docs/DEVELOPING.md](docs/DEVELOPING.md#measured-performance).
  Playback stays smooth under heavy system load.
- 0.25–4× playback speed with pitch preservation (toggleable in Settings),
  volume up to 400%, and scroll-gesture volume/seek over the video.
- Live scrub previews, aspect-locked resizing, double-click to fit screen,
  Vivid mode (EDR luminance boost on capable displays), Theater mode
  (dims everything but the player), multiple windows, and playback
  continues when a window is unfocused or covered.
- Trim and retimed MP4 export, plus on-device subtitle generation via
  whisper.cpp.

## Keys

| Action | Control |
| --- | --- |
| Open | ⌘O, click the empty player, or drop a file |
| Play/pause | Space |
| Seek | ←/→ (step configurable in Settings), or scroll horizontally over the video |
| Volume | Scroll vertically over the video |
| Speed | The `1×` control, presets or slider |
| Fit window to screen | Double-click the video or title bar |
| Fullscreen | F |
| Vivid mode | V |
| Theater mode | T |
| Quick Edit | E |
| Close window | ⌘W |

## Architecture

Demuxing is AVFoundation for MP4/MOV, plus custom Matroska and MPEG-TS
demuxers. Video decodes through VideoToolbox (libvpx for VP8). An
audio-driven clock using exact rational arithmetic schedules frames, and
decoded output goes to an `AVSampleBufferDisplayLayer` composited by
WindowServer, so video never enters the UI toolkit's render loop.

More detail: [docs/DEVELOPING.md](docs/DEVELOPING.md),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/PRODUCT.md](docs/PRODUCT.md)
