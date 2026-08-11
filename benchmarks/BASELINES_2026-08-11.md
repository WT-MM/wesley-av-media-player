# macOS performance snapshots — 2026-08-11

These are scoped development snapshots from one Apple-silicon host. They do
not establish cross-platform leadership, explain which subsystem caused a
difference, or substitute for a longer release benchmark. The GUI matrix and
offscreen probe have different process boundaries and must not be combined or
ranked against each other.

## Full-player GUI matrix

Suite `current-h264-gui-20260811-v1` ran WAM, VLC, and QuickTime Player against
the same 180.083-second Tears of Steel H.264 4K24 bytes at 1× in an 1180×720
window. The media SHA-256 is
`a523926c93cbe8384ba5fc83c1737213cca1616b18a4d4f183c02066959d0179`.
The host was an arm64 Apple M3 Max Mac with 16 cores and 64 GiB of memory,
running macOS 26.3.1.
Each player had three fresh-launch repetitions with a 12-second warm-up and a
20-second requested measurement, a five-second cooldown, and one-second metric
sampling. Player order was counterbalanced by repetition. Every trial received
a distinct hard-link pathname; the manifest records matching inodes and removal
of all nine aliases afterward.

CPU, `top` POWER, and memory cells below are the median of the three
timestamp-weighted per-run means, followed by the run range. Footprints are
end-of-run kernel observations. The full-player process scope includes the
tracked application process set and its attributed VideoToolbox helper;
shared-adjusted footprint avoids double-counting shared regions. `top` POWER is
Apple's relative Energy Impact score—not watts, joules, or a portable energy
unit. AGX values are rates from an undocumented accumulated per-process
counter; their unit is unknown.

| Player | Architecture | CPU % | `top` POWER score | Memory MiB | Footprint MiB (current / peak / shared-adjusted) | Events/s (switches / faults / page-ins) | AGX counter units/s |
| --- | --- | ---: | ---: | ---: | --- | ---: | ---: |
| WAM | arm64 | 12.41 [10.95–12.80] | 12.20 [10.72–12.56] | 851.0 [847.6–860.9] | 852.2 [848.6–865.6] / 853.7 [853.3–866.3] / 851.6 [847.8–864.6] | 1,847.5 [1,819.0–1,881.5] / 169.5 [168.0–170.6] / 0.04 [0.00–0.04] | 43,961,757 [31,827,377–44,885,534] |
| VLC | x86_64 via Rosetta | 9.01 [8.46–9.30] | 8.86 [8.25–9.00] | 736.8 [662.1–737.5] | 738.4 [664.1–738.8] / 745.5 [673.3–747.9] / 733.5 [661.3–733.9] | 1,070.8 [1,069.0–1,076.5] / 217.4 [208.8–226.8] / 0.00 [0.00–0.00] | 15,265,968 [3,992,126–19,502,509] |
| QuickTime | arm64e | 7.05 [6.73–7.61] | 6.82 [6.58–7.40] | 213.9 [213.7–214.1] | 214.5 [214.2–215.1] / 228.3 [216.9–228.5] / 212.3 [212.0–212.9] | 849.6 [847.8–862.5] / 152.9 [144.9–162.6] / 0.00 [0.00–0.00] | N/A |

The installed VLC 3.0.21 binary was x86_64 and ran through Rosetta. That row is
representative of the installed application on this machine, but it is not an
architecture-neutral comparison with native WAM or QuickTime. A native-arm64
VLC run is required before attributing any difference to player design. The
QuickTime AGX value is unavailable, not zero.

All nine trials completed the suite's validity checks. Across 672 continuous
frontmost/window samples (73–76 per trial), there were no contamination
intervals; the largest same-phase sampling gap was 0.799 seconds against a
1.25-second limit. The exact process remained alive, frontmost, and at the
expected bounds, and the expected media file was open at measurement start and
end in every trial. Launch logs contained no matched fatal-video pattern. VLC
and QuickTime also exposed playing state and timeline advance within tolerance
for all six of their trials. The packaged WAM build did not expose comparable
out-of-process timeline telemetry, so its validity rests on process identity,
continuous window state, open-media checks, and clean launch logs rather than a
timeline assertion.

The launch-path executable hashes, captured with this record, are:

- WAM 0.3.0 arm64:
  `7fc4117debf3be42d5b6c77153cb7f4fb9bdd0ccca40c481255c462b53fb7764`
- VLC 3.0.21 x86_64:
  `fe875c0c594bab58a0901404f1f890c45e381553b2e5ce932681fcfedf079f3f`
- QuickTime Player 10.5 universal binary:
  `5f5b6e8778fb2a30445c4b2c83ac55a8c1aef1386b3acd7734385160d4e41fbf`

Exact ignored source artifacts and their SHA-256 hashes:

- `benchmarks/results/current-h264-gui-20260811-v1/manifest.json`:
  `04b8b41343a4cd3d76b9eef343375739b38f36eff964590356b28e8e72268dd2`
- `benchmarks/results/current-h264-gui-20260811-v1/report.csv`:
  `8549e304bb90d3f9c4998153ed246b2bd95c02bc6beea723c95257bc7ccdb635`
- `benchmarks/results/current-h264-gui-20260811-v1/report.md`:
  `87648cb254015cdc5d55baafea230f0430791a8f0bff8cbc3a5d6ae3e09b79d2`

## Offscreen libmpv engine baseline

Suite `libmpv-offscreen-20260811-v1` is an engine-lab baseline, not a
full-player comparison. It contains 15 independent 20-second runs: three runs
for each of five media cases. The probe renders WAM's libmpv/OpenGL path into an
offscreen RGBA8 1180×720 framebuffer and calls `glFinish()` after each frame.
It uses null audio and excludes Qt, a visible window, controls, compositing, and
application lifecycle. CPU and footprint cover only the probe process and
exclude the separate VideoToolbox XPC helper. Its sampled maximum footprint is
therefore not the same metric or scope as the GUI matrix's end-of-run aggregate
footprint.

| Case | CPU % | Max sampled footprint MiB | Context switches/s | Rendered frames |
| --- | ---: | ---: | ---: | ---: |
| Repository H.264 720p30 | 7.456 [6.177–7.465] | 312.892 [312.642–313.126] | 1,166.2 [1,102.4–1,192.6] | 594 [594–594] |
| Tears of Steel H.264 4K24 | 6.062 [5.885–7.049] | 392.251 [365.626–392.376] | 1,009.8 [987.0–1,052.3] | 479 [478–479] |
| Tears of Steel HEVC 4K24 | 9.171 [6.794–9.622] | 436.548 [435.829–436.892] | 1,112.9 [1,047.0–1,148.0] | 479 [479–479] |
| NOAA VP9 720p23.976 | 7.942 [6.835–8.373] | 300.548 [300.032–300.813] | 1,032.0 [972.0–1,108.7] | 480 [479–480] |
| NASA AV1 1080p30 | 7.192 [6.964–8.508] | 297.954 [297.798–299.485] | 1,047.6 [1,032.3–1,051.4] | 597 [597–598] |

Every run reported `hwdec_current=videotoolbox`, zero decoder drops, zero
video-output drops, and absolute A/V sync error below 0.000015 seconds. These
checks establish that the probe completed its intended decode/render workload;
they do not validate full application playback behavior.

Host and engine: Apple M3 Max MacBook Pro (`Mac15,8`), 16 CPU cores, 64 GiB,
arm64, macOS 26.3.1; mpv 0.41.0, libmpv pkg-config 2.5.0, FFmpeg 8.1.2, and
libplacebo 7.360.1. Probe source SHA-256:
`cb113d67682360cc24cdb6ef83426a575f858d19b53696673ac009d18f3f3a0c`.
Probe executable SHA-256:
`a3fa9449042b95cd151dd0adedf0c596374aaecc6334842e358e400c050479a3`.

Media SHA-256 values:

- `wam-test-h264-180s.mp4`:
  `c06122b214a3f7786b593c15b503437d2e6efeada4ce617a4caa1bb1bee6237a`
- `tos-h264-4k24-180s.mp4`:
  `a523926c93cbe8384ba5fc83c1737213cca1616b18a4d4f183c02066959d0179`
- `tos-hevc-hvc1-4k24-180s.mp4`:
  `7ab9b5238bad9548b1ea616c4d9374059b74b0b249bcaf46fb5da5bb7e669c68`
- `noaa-octopus-vp9.webm`:
  `0bd0eab901319e7e26532a2d98cee6191b7d10c52ff1af7b0003752da425b841`
- `nasa-minute-av1.webm`:
  `b582e0d7861100f984b3bc5d74d62d477015077337270db564837c79bd091ef8`

Exact ignored source artifacts and their SHA-256 hashes:

- `benchmarks/results/libmpv-offscreen-20260811-v1/metadata.json`:
  `0bcc913afd83de57bb406c14675f736ca97afecd7e8732f7ea5af9b303e80479`
- `benchmarks/results/libmpv-offscreen-20260811-v1/summary.csv`:
  `955db453ca63496cbbdb9ccbd39f20ad6d6d219a43c2d0e3fca72d25df5266ad`
- `benchmarks/results/libmpv-offscreen-20260811-v1/README.md`:
  `49e42485cc6c937eb0d5960615f1a6f1c31b9a586bd3346340ffdae93611aefd`

## Interpretation boundary

The GUI snapshot shows measurable CPU and memory optimization headroom for this
WAM build: its values were higher than both comparison applications in this
single H.264 4K24 case. It does not identify whether that gap originates in
libmpv, Qt Quick, renderer configuration, buffering, graphics allocation, or
another component.
The offscreen data narrows future investigations but cannot isolate those
causes by itself. Release claims require at least five repetitions, longer
measurement windows, native-architecture comparators, and the broader codec,
speed, subtitle, HDR, seek, idle, and platform matrix.
