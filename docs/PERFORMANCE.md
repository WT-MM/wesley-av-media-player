# Performance baseline

WAM treats performance as a measured release property, not a toolkit claim.
This baseline was captured on the development Apple-silicon Mac on 2026-08-10
with a 1280×720, 30 fps H.264 High/AAC test movie.

| State | CPU | Resident memory (`ps` RSS) |
| --- | ---: | ---: |
| Playing | 13.75% average (12.8–15.5%) | 213.7 MiB average |
| Paused/settled | 0.18% average, settling to 0.0% | 214.1 MiB |

macOS `top` reported a larger accounting view (roughly 526 MiB while decoding
and 250–260 MiB after settling), so both measures should be retained when
tracking regressions. VideoToolbox and IOSurface were loaded, and a matching
`VTDecoderXPCService` process was observed during playback. The player requests
libmpv's safe hardware-decode path; a later diagnostics surface should record
`hwdec-current` directly for deterministic automated assertions.

After the transport faded, it left the accessibility tree and sampling showed
Qt's event loop and mpv's video-output thread blocked waiting, with no active
render call. Left/Right five-second seeking was also exercised in the running
app.

This is a smoke baseline, not a broad performance claim. Release qualification
still needs the architecture matrix in `docs/ARCHITECTURE.md`: 4K60 H.264,
HEVC, VP9, AV1, HDR, multiple subtitle formats, 1×/2×/4× playback, random seek,
energy impact, dropped frames, and clean-machine tests on macOS, Windows, and
Linux.

### Blank-launch lazy-engine result

A counterbalanced five-versus-five blank-launch A/B on the same Mac measured
the effect of keeping the libmpv client dormant until the first valid open. The
median physical footprint fell from 138,445,904 to 133,727,384 bytes, a
4,718,520-byte (about 4.5 MiB) reduction. Median `ps` RSS fell by 9,632 KiB
(about 9.4 MiB), and peak physical footprint fell by about 4.65 MB. The blank
window also avoids libmpv's dormant worker threads.

This is an idle-only result. Once media is opened, WAM initializes the same
shipping libmpv path, so no active-playback CPU or memory improvement is claimed
from lazy initialization. First-open/first-frame latency remains a separate
release measurement.

### Controlled playback snapshots (2026-08-11)

A newly validity-gated nine-trial GUI matrix measured three fresh-launch runs
each of WAM, VLC, and QuickTime Player on the same H.264 4K24 clip. Median CPU /
`top` POWER score / memory were 12.41% / 12.20 / 851.0 MiB for WAM, 9.01% /
8.86 / 736.8 MiB for VLC, and 7.05% / 6.82 / 213.9 MiB for QuickTime. These are
timestamp-weighted run means summarized by median; the tracked record includes
the ranges, footprint and counter data, validity gates, and artifact hashes.
The installed VLC was x86_64 under Rosetta, so this is not an
architecture-neutral comparison. `top` POWER is a relative Energy Impact score,
not watts or joules.

A separate 15-run offscreen libmpv baseline covers H.264, HEVC, VP9, and AV1.
It excludes Qt, the visible window, audio output, application lifecycle, and the
VideoToolbox helper's process footprint. It is engine-lab data and must not be
compared directly with the full-player rows. See
`benchmarks/BASELINES_2026-08-11.md` for the complete scoped record.

## Production efficiency policy

Normal playback now uses mpv's audio-clock sync and direct bilinear sampler
path. `correct-downscaling`, `linear-downscaling`, debanding, interpolation,
and sigmoid upscaling are disabled. The renderer remains in `gpu-dumb-mode=auto`
rather than forcing it, so HDR and other required color conversions can still
engage the advanced pipeline. The previous spline36/Mitchell linear-light path
is available through `WAM_RENDER_PROFILE=quality`.

Buffering is selected per source. Local files use one second of readahead with
a 16 MiB packet ceiling and no backward cache. Network and other potentially
slow sources use an eight-second cache with a 32 MiB forward and 8 MiB backward
ceiling. Cache hysteresis batches demuxer work instead of continuously waking to
top up the buffer. Before this policy, every source could retain 64 MiB forward
plus 16 MiB backward and local media requested ten seconds of readahead.

WAM also disables standalone-mpv configuration, user scripts, built-in mpv
overlays, input handling, file autoloading, cover-art directory scans, and mpv
resume lookup. QML and WAM's state store own those responsibilities.

## Opt-in renderer controls

WAM has three environment-variable controls for isolated renderer A/B tests.
They are disabled unless explicitly set. A normal launch retains the efficient
policy above and `fbo-format=auto`. Accepted values are case-insensitive. An
unknown or empty value is rejected with a warning and leaves the corresponding
defaults active. Every accepted selection is also written to the application
log.

Run only one experiment at a time when attributing a CPU, GPU, energy, or memory
change. On macOS and Linux, launch the executable directly, for example:

```sh
WAM_RENDER_PROFILE=quality /path/to/WAM /path/to/video.mp4
WAM_VIDEO_SYNC=display-resample /path/to/WAM /path/to/video.mp4
WAM_SDR_FBO_FORMAT=rgb10_a2 /path/to/WAM /path/to/known-sdr-video.mp4
```

For a macOS application bundle, the executable path is typically
`/path/to/WAM.app/Contents/MacOS/WAM`. In PowerShell, set a variable for one
launch and remove it afterward:

```powershell
$env:WAM_RENDER_PROFILE = "quality"
& "C:\path\to\WAM.exe" "C:\path\to\video.mp4"
Remove-Item Env:WAM_RENDER_PROFILE
```

The controls are:

- `WAM_RENDER_PROFILE=quality` restores `scale=spline36`, `dscale=mitchell`,
  `correct-downscaling=yes`, `linear-downscaling=yes`, and
  `sigmoid-upscaling=yes`. `efficient` and `fast` explicitly select the
  production direct-sampler settings.
- `WAM_VIDEO_SYNC=display-resample` opts into display-clock cadence correction.
  `audio` explicitly selects the production policy. Compare CPU, A/V drift,
  and dropped/repeated-frame counts when qualifying either mode.
- `WAM_SDR_FBO_FORMAT=rgb10_a2` or `rgba8` changes only mpv's intermediate FBO
  format. Both use four bytes per pixel instead of the eight-byte `rgba16f`
  format normally selected first by `fbo-format=auto`. This override is set
  before media metadata is available and therefore cannot enforce an SDR check;
  use it only in a process that will open known SDR media. These lower-precision
  formats are not approved for HDR or production output. Treat this strictly as
  a memory/GPU-bandwidth experiment and perform visual-difference checks.

Use `default` for any variable to log the selection without applying an
override, or unset the variable to return to a normal silent launch. Do not
combine the efficient/fast profile with the FBO experiment: the direct sampler
is intended to avoid the advanced intermediate-FBO pipeline, making that
comparison uninformative.
