# WAM

**Wesley's Audiovisual Media Player** — a minimal macOS player that's as
light as QuickTime and plays the files QuickTime can't.

![WAM playing a video with its transport visible](docs/media/wam-transport.png)

The chrome fades while you watch — what's left is just your video.

![WAM with chrome faded away](docs/media/wam-video.png)

## Install

Grab the latest build from
[**Releases**](https://github.com/WT-MM/wesley-av-media-player/releases) —
a self-contained `WAM-*.zip` for Apple silicon. Unzip, drag `WAM.app`
wherever you like, then **right-click → Open** the first time (the build is
ad-hoc signed, so macOS asks once). Or from a terminal:

```sh
xattr -d com.apple.quarantine WAM.app
```

Requires an Apple silicon Mac. To build from source instead, see
[docs/DEVELOPING.md](docs/DEVELOPING.md).

## Why WAM

- **QuickTime-light.** Matches QuickTime's CPU and energy on the measured
  baseline with exactly zero GPU work, so video stays smooth while a game or
  training run saturates the machine — and WAM doesn't fight them for it.
  ([Methodology and tables](docs/DEVELOPING.md#measured-performance).)
- **Plays nearly everything, natively.** H.264, HEVC, VP9, AV1, MPEG-2,
  MPEG-4 SP, and VP8 video; AAC, AC-3/E-AC-3, FLAC, MP3, Opus, and Vorbis
  audio; MP4, MOV, MKV, WebM, and MPEG-TS containers; up to 4K; music files
  too. Everything else falls back seamlessly to a bundled mpv/FFmpeg engine —
  no codec packs, ever.
- **Stays out of your way.** Fading chrome, aspect-exact resize, double-click
  to fit, keeps playing when unfocused or covered, live scrub previews,
  0.25–4× speed with pitch preserved.
- **Quick edits built in.** IN/OUT trim with retimed export, and on-device
  caption generation that never leaves your machine.

## Keys

| Action | Control |
| --- | --- |
| Open | ⌘O, click the empty player, or drop a file |
| Play/pause | Space |
| Seek | ←/→ (step configurable in Settings) |
| Speed | The `1×` control — presets or a continuous slider |
| Fit window to screen | Double-click the video or title bar |
| Fullscreen | F |
| Quick Edit | E |

## Under the hood

Demux (AVFoundation, plus custom Matroska and MPEG-TS demuxers) feeds
VideoToolbox hardware decode; an audio-authoritative clock built on exact
rational arithmetic schedules frames; and decoded output is composited by
WindowServer directly — video never touches the UI toolkit's render loop.
That's the same architectural property that makes QuickTime cheap, and it's
why the numbers match. Details, benchmarks, and build instructions:
[docs/DEVELOPING.md](docs/DEVELOPING.md) ·
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
[docs/PRODUCT.md](docs/PRODUCT.md)
