# WAM macOS player benchmark

This suite compares WAM, VLC, and QuickTime using the same local bytes and a
repeatable macOS measurement protocol. It separates codec compatibility from
performance so an unsupported format is reported as `N/A`, never as zero cost.

## Comparison set

- WAM 0.3.1 (libmpv backend): native arm64 standalone bundle
- VLC 3.0.21: the installed x86_64 build running through Rosetta
- QuickTime Player 10.5: native arm64e system application

The installed VLC row represents the user's real VLC experience, but its Intel
architecture is an explicit confounder. A native VLC build should be added as a
separate row before making architecture-neutral claims.

## Corpus

`corpus.json` records every URL, SHA-256, media property, and license. The
headline H.264 and HEVC clips are Microsoft's matching 60-second 4K encodes of
the same Tears of Steel frames. The HEVC performance derivative is remuxed
without re-encoding from Microsoft's `hev1` MP4 to an `hvc1` sample entry so
QuickTime, VLC, and WAM all exercise the same encoded packets; the original
`hev1` file remains available as a compatibility probe. NOAA VP9 and NASA AV1
clips probe modern-codec and container compatibility. Downloaded media and raw
results are ignored by Git.

Prepare or reproduce the local corpus with:

```sh
benchmarks/prepare_corpus.zsh
```

## Run the controlled matrix

Preview the exact schedule without creating files or launching an application:

```sh
python3 benchmarks/macos/run_matrix.py --plan
```

Run the primary development matrix (H.264 1x, HEVC 1x, and H.264 2x; three
replicates per player):

```sh
python3 benchmarks/macos/run_matrix.py \
  --wam-app /path/to/standalone/WAM.app \
  --suite-id development-2026-08-10
```

Add the repository fixture and the real NOAA VP9 and NASA AV1 compatibility
probes with either `--all-cases` or the two narrower flags:

```sh
python3 benchmarks/macos/run_matrix.py \
  --wam-app /path/to/standalone/WAM.app \
  --all-cases
```

The default primary timings are a 12-second warm-up and a 20-second
measurement. The local fixture uses 10+15 seconds and compatibility probes use
8+12 seconds. `--warmup`, `--duration`, and `--repetitions` deliberately
override those values, and the launcher refuses timing that would reach the end
of a clip at the requested playback speed.

Player order is counterbalanced by replicate:

1. WAM, VLC, QuickTime
2. VLC, QuickTime, WAM
3. QuickTime, WAM, VLC

Every trial opens a distinct hard-link pathname in a newly created directory
under `/private/tmp`. This preserves identical media bytes while preventing
WAM or another player from restoring a position saved for an earlier trial.
Aliases are removed after the suite. The matrix never changes system or
application volume, so audio may be audible during a run.

Each invocation reserves a new result directory and refuses to reuse an
existing `--suite-id`. Its `manifest.json` is updated atomically before and
after every trial. A successful trial is `completed`; an unsupported or failed
trial is `n/a` with an explicit `unsupported`, `failure`, or `interrupted`
reason. It is never represented as zero CPU, memory, GPU, or energy. By default
the runner attempts declared compatibility failures so a newly supported format
can be discovered. Use `--skip-expected-unsupported` to record those declared
pairs as N/A without launching them, or `--fail-fast` to stop after the first
non-completion.

## Report the matrix

Create human-readable Markdown and machine-readable CSV from a completed or
still-running manifest:

```sh
python3 benchmarks/macos/report_matrix.py \
  benchmarks/results/development-2026-08-10/manifest.json \
  --markdown benchmarks/results/development-2026-08-10/report.md \
  --csv benchmarks/results/development-2026-08-10/report.csv
```

The reporter groups trials by case and player. It reports measured versus
planned repetitions and the median of per-run means with a min–max range for
CPU, `top` POWER (Energy Impact), and memory. Those means are timestamp-weighted:
CPU uses each preceding sample interval and instantaneous gauges use trapezoidal
integration. Context switches, faults, page-ins, and the optional AGX
per-process accumulated counter are reported as rates per second, using each
run's actual first-to-last sampling span rather than its requested duration.
Raw interval summaries and raw counter totals remain in the result JSON and the
flat `summarize.py` CSV for auditability. Kernel footprint current, lifetime
peak, and shared-adjusted values are aggregated from each run's
end-of-measurement observation. A legitimate measured zero remains zero;
missing data, an unreadable artifact, a failed run, and an unsupported format
remain explicit N/A states.

Current result files add these normalization fields without changing the v1
schema identifier: `summary.top.measurement.elapsed_s`, top counter
`*_rate_per_s` values, `summary.gpu.measurement.elapsed_s`, and
`summary.gpu.aggregate.accumulated_gpu_time_rate_per_s`. If complete timestamps
are unavailable, means fall back to arithmetic sample means. When reporting an
older v1 artifact, the tools first derive spans from raw sample timestamps and
use whole-collection elapsed time only as a labeled compatibility fallback;
requested duration is never a rate denominator. Older artifacts retain their
already-stored arithmetic CPU/gauge means so a report does not silently rewrite
historical result content.

Because `manifest.json` is updated atomically, the same command can safely take
a live progress snapshot. Pending and running rows remain visible, and the
report reads result files only for trials already marked completed.

Architecture and bundle size are deliberately never inferred. Add them only
when the exact compared artifacts have been measured, using repeatable direct
arguments:

```sh
python3 benchmarks/macos/report_matrix.py manifest.json \
  --architecture wam=arm64 \
  --architecture vlc=x86_64 \
  --architecture quicktime=arm64 \
  --bundle-size-bytes wam=367001600 \
  --bundle-size-bytes vlc=156237824 \
  --markdown report.md
```

Omit those options and the corresponding report columns are omitted too.

## Steady-state protocol

1. Use AC power, normal power mode, a fixed full-screen presentation, unchanged
   display mode, identical volume, subtitles off, and controls fully faded.
2. Quit every other test player. Record an idle WindowServer/system baseline.
3. Fresh-launch the player, open a unique copy of the local file, and verify
   visible playback plus the expected hardware-decoder helper.
4. Warm for 15 seconds, then measure for 30 seconds. The repository's 180-second
   stream-copy derivatives avoid application-level looping.
5. Quit the player and wait for CPU/GPU activity to settle. Rotate player order.
6. Use at least three runs for the development snapshot and five runs for a
   release decision. Report median run means plus variability.

## Non-windowed libmpv probe

`macos/libmpv_offscreen_probe.cpp` isolates WAM's current libmpv/OpenGL render
path from Qt Quick and window-server animation. It is useful for rejecting
engine-option experiments before they reach the full player benchmark; its
numbers are not a substitute for the LaunchServices suite above.

Build it on macOS with the same Homebrew libmpv used by the development app:

```sh
clang++ -std=c++20 -O2 -DGL_SILENCE_DEPRECATION \
  benchmarks/macos/libmpv_offscreen_probe.cpp \
  -o build/wam_libmpv_offscreen_probe \
  $(pkg-config --cflags --libs mpv) \
  -framework OpenGL -framework Foundation
```

Then run a 20-second sample against a local corpus derivative:

```sh
build/wam_libmpv_offscreen_probe /path/to/tos-h264-4k24-180s.mp4
```

Optional positional arguments select `hwdec-extra-frames`, `swapchain-depth`,
render-API advanced control (`0` or `1`), `gpu-dumb-mode`, `fbo-format`, and
`hwdec`, in that order. The probe verifies the active hardware decoder, A/V
sync, and dropped-frame counters and reports process CPU, sampled physical
footprint, context switches, render callbacks, and frames rendered.

The offscreen target deliberately uses the shipping OpenGL renderer but a null
audio output and no Qt scene graph. Its footprint excludes the separate
VideoToolbox XPC helper, and its `glFinish()` makes GPU completion deterministic
instead of modelling Qt's window swapchain. Compare only identical probe runs;
use the full suite for any product or competitor claim.

The shorter development window is intentionally practical. A release-grade
energy run should use a 60-second warm-up and 300-second measurement window.

## Metrics and interpretation

- `top`: per-process CPU, physical footprint, macOS `POWER` energy-impact score,
  threads, ports, context-switch/page-fault/page-in raw deltas and per-second
  rates, purgeable memory, and whole-system CPU. Means use actual top timestamps
  when a complete strictly increasing series is available.
- `footprint`: kernel-ledger current and process-lifetime peak physical
  footprint for the player and its helpers, plus Apple's shared-adjusted current
  total. The aggregate peak is the sum of per-process peaks, which may have
  occurred at different times.
- AGX I/O Registry counters: per-process accumulated GPU time, its raw delta
  total and actual-span-normalized rate, plus system device/renderer/tiler
  utilization. This includes OpenGL translated by Apple's graphics driver,
  unlike a Metal-only trace.
- Instruments Activity Monitor: an independent diagnostic pass for CPU,
  memory, disk activity, and wakeups.
- Compatibility, architecture, bundle size, startup behavior, seek response,
  and observed VideoToolbox helper use are reported alongside telemetry.

`POWER` is a relative same-machine energy score, not watts or joules. Apple's
`powermetrics` can provide richer coalition and estimated rail-power data, but
it requires an administrator authorization. Hardware video-decode power is not
fully represented by CPU or GPU counters, so results must not call low CPU/GPU
usage equivalent to zero decoder energy.

## Additional controls

- Network/HLS tests are separate from local rankings because CDN variation and
  adaptive rendition choice can dominate player differences.
- The main player PID, newly spawned VideoToolbox decoder helper, and
  WindowServer delta should all be retained. A main-PID-only comparison favors
  applications that delegate more work to shared services.
- Screen capture and Instruments tracing run in separate passes because they
  perturb the workload.
- Background playback, paused idle, 2x/4x pitch-preserved playback, subtitles,
  HDR, and hour-long stability are separate suites rather than blended into one
  score.
