# WAM startup report — 2026-11-04

Implemented and committed on `fix-startup`; no push or PR. Starting commit: `b257dff146e971bf708756fc4e880a94fcdb3681`.

## Changes

- `196b382`, `0d97447`: launch, window, route-worker/delivery, native session, AVFoundation key loading, video/audio configuration, and libmpv load/initialize timestamps. Worker/render timestamps use the existing bounded atomic mailbox; only the GUI owner serializes. Calls compile away without telemetry; a disabled runtime gate performs no clock read, allocation, or I/O. First scene frame is captured on the emitting thread, not a delayed GUI callback. Blank launch drains its events at orderly quit.
- `8a4ad43`: start argv opens before entering the main event loop; process initial LaunchServices events while the relay can buffer them, then drain launch files directly once the first window/controller is ready. Ordinary live Finder opens remain queued. Deliver Qt preflight completions through Qt's event queue instead of the Cocoa main dispatch queue. Preserve request identities, cancellation, teardown, initial rate/resume settings, and route admission.

No media proof, frozen contract, frozen audio test, decoder policy, native retirement handshake, or fallback engine initialization policy changed. No speculative libmpv load was added.

## Measurement method

Seven baseline/candidate pairs **per case**, always alternating A then B, sequential quiet launches, same session and machine. Direct launches use the supplied `run.zsh`, isolated HOME, muted/background/parked windows, and `WAM_TEST_QUIT_AFTER_MS=3500`. LaunchServices uses `open -n -g -W -a <exact bundle> <file>` with the same environment passed via `--env`; the file is an Apple Event, never argv. `-n` isolates our process from any installed/running WAM, and `-W` serializes trials. Times start at the process start, not the invocation of `open`.

Baseline is the starting behavior plus **the identical telemetry-only commits** in `build-baseline`; candidate scheduling changes were explicitly stashed while rebuilding it. This supplies comparable blank-window and subphase timestamps without attributing instrumentation differences to the optimization. Candidate is `build/WAM.app`. Both use the requested Release/Homebrew Qt/native/telemetry configuration and the same bundled development fallback dylib. The binary hashes and commit provenance are in `/private/tmp/wam-probe-startup/ab-final/provenance.json`.

Process start uses `process_start_abstime * 125 / 3`, translated by `CLOCK_MONOTONIC_RAW - CLOCK_UPTIME_RAW` sampled after each trial. All reported event times use `monotonic_ns`; serialization order is irrelevant. No trial or outlier was removed. Other agents were active on the machine; the first part also overlapped this task's final test suite. These are warm-cache session measurements, not cold boot claims. Sampling and one-pair exploratory pilots are excluded from the final table.

## Before / after

Milliseconds: **median [minimum–maximum]**, N=7 in every populated cell. “Picture” is `first_frame_drawn` for native and the **engine restart proxy** `fallback_playback_restart` for fallback. “Window” is first `frameSwapped`, not a compositor/display scanout timestamp.

| Case | Build | Open requested | Native selected | Prepared | Picture / restart | Window frame |
|---|---|---:|---:|---:|---:|---:|
| u004 native | baseline | 274.9 [266.6–305.5] | 286.1 [268.3–423.1] | 405.3 [384.0–495.1] | 439.9 [409.1–526.4] | 391.1 [372.4–409.2] |
| u004 native | candidate | 271.6 [250.4–296.9] | 272.1 [253.1–297.5] | 382.7 [368.2–405.8] | 421.5 [397.0–450.5] | 375.2 [359.1–400.9] |
| u005 native | baseline | 303.9 [268.0–333.1] | 413.2 [272.1–445.9] | 521.2 [396.0–552.1] | 646.2 [531.9–665.5] | 404.6 [390.0–441.2] |
| u005 native | candidate | 268.5 [262.7–281.9] | 269.1 [263.1–282.4] | 408.0 [388.6–421.1] | 537.9 [427.5–551.7] | 377.9 [372.8–394.4] |
| u007 fallback | baseline | 269.3 [259.8–309.9] | 375.1 [263.4–411.0] | — | 691.8 [600.0–718.4] | 371.0 [361.4–406.5] |
| u007 fallback | candidate | 275.1 [261.4–296.0] | 275.6 [261.9–296.5] | — | 627.3 [614.6–649.6] | 385.8 [368.2–407.7] |
| LaunchServices u004 | baseline | 450.4 [425.8–526.8] | 461.9 [450.4–552.9] | 543.7 [522.8–700.2] | 561.0 [543.8–735.9] | 441.8 [401.8–513.7] |
| LaunchServices u004 | candidate | 320.4 [296.7–352.6] | 410.1 [320.9–462.0] | 498.6 [428.9–532.5] | 521.7 [464.4–563.9] | 422.0 [401.8–454.0] |
| Blank | baseline | — | — | — | — | 375.8 [357.3–391.3] |
| Blank | candidate | — | — | — | — | 378.9 [360.2–424.4] |

Blank launch did **not** improve: 375.8 → 378.9 ms median, with overlapping ranges. The shipping changes improve picture startup, not the remaining blank-window construction cost.

## Where the time goes and what the changes bought

The old “route selection” span is mostly event-loop scheduling, not media probing. URL resolution, mount classification and exact initial-position conversion finish in a fraction of a millisecond. Delivery can then wait behind first-window exposure and Qt's initial OpenGL scene. Early launch requests and Qt delivery overlap native asset loading and port configuration with that scene work. The following interval measurements show the changes' contribution; overlapping intervals are **not additive**, and this is not an isolated end-to-end ablation of each edit.

| Case | Interval | Baseline | Candidate |
|---|---|---:|---:|
| u004 native | QML root → open | 21.9 [19.5–24.2] | 5.0 [4.3–16.7] |
| u004 native | preflight worker | 0.1 [0.1–0.1] | 0.0 [0.0–0.0] |
| u004 native | worker done → delivered | 1.7 [1.5–118.1] | 0.5 [0.4–2.6] |
| u004 native | session creation | 5.5 [3.4–9.0] | 4.0 [3.8–4.8] |
| u004 native | first asset-key batch | 8.8 [8.1–9.8] | 9.2 [8.5–9.7] |
| u004 native | video configure | 52.8 [51.3–54.2] | 53.5 [52.0–61.6] |
| u004 native | prepared → picture | 31.2 [5.0–44.4] | 30.2 [28.2–67.9] |
| u005 native | QML root → open | 20.5 [18.5–27.8] | 5.0 [4.4–9.4] |
| u005 native | preflight worker | 0.0 [0.0–0.1] | 0.0 [0.0–0.1] |
| u005 native | worker done → delivered | 108.3 [4.1–112.8] | 0.4 [0.4–1.0] |
| u005 native | session creation | 4.0 [3.2–4.9] | 4.3 [3.9–7.5] |
| u005 native | first asset-key batch | 15.0 [14.3–15.7] | 14.6 [13.8–15.1] |
| u005 native | video configure | 57.1 [55.3–59.2] | 55.6 [53.3–65.7] |
| u005 native | audio configure | 84.9 [79.0–94.8] | 81.4 [80.5–83.5] |
| u005 native | prepared → picture | 119.4 [51.0–135.9] | 137.1 [19.5–159.8] |
| u007 fallback | QML root → open | 18.9 [17.2–24.9] | 5.7 [4.7–11.2] |
| u007 fallback | preflight worker | 0.0 [0.0–0.1] | 0.0 [0.0–0.1] |
| u007 fallback | worker done → delivered | 105.8 [1.5–122.1] | 0.5 [0.4–3.6] |
| u007 fallback | session creation | 3.9 [3.2–7.5] | 3.9 [3.7–4.1] |
| u007 fallback | first asset-key batch | 14.1 [13.3–15.3] | 14.1 [13.2–14.8] |
| u007 fallback | video configure | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] |
| u007 fallback | audio configure | 77.7 [72.2–80.8] | 80.4 [72.2–112.7] |
| u007 fallback | libmpv load | 43.2 [40.8–44.5] | 40.5 [39.0–42.3] |
| u007 fallback | libmpv initialize | 7.3 [7.0–7.8] | 7.3 [7.0–7.9] |
| u007 fallback | fallback initialized → restart | 155.7 [144.7–164.2] | 143.2 [140.9–145.7] |
| LaunchServices u004 | QML root → open | 138.3 [126.3–177.2] | 5.8 [4.0–15.1] |
| LaunchServices u004 | preflight worker | 0.0 [0.0–0.1] | 0.1 [0.0–0.1] |
| LaunchServices u004 | worker done → delivered | 26.0 [9.9–40.2] | 106.4 [0.4–112.5] |
| LaunchServices u004 | session creation | 3.3 [3.2–5.9] | 3.7 [3.4–8.1] |
| LaunchServices u004 | first asset-key batch | 9.0 [8.2–12.5] | 8.5 [8.2–9.1] |
| LaunchServices u004 | video configure | 53.3 [50.2–80.9] | 52.8 [49.0–54.8] |
| LaunchServices u004 | prepared → picture | 21.0 [5.0–38.0] | 34.9 [21.0–49.4] |

Qt posting does not guarantee priority over the first scene: LaunchServices still has a 106.4 ms median completion wait in the candidate. Its net gain comes from receiving and requesting the file much earlier. No hard scheduling bound is claimed.

LaunchServices delivery itself moved earlier:

| Milestone, process-relative | Baseline | Candidate |
|---|---:|---:|
| file_open_received | 448.7 [423.7–524.2] | 180.2 [159.0–203.1] |
| qml_root_loaded | 308.1 [281.4–349.6] | 315.1 [292.6–346.4] |
| open_requested | 450.4 [425.8–526.8] | 320.4 [296.7–352.6] |
| native_selected | 461.9 [450.4–552.9] | 410.1 [320.9–462.0] |

Blank launch phase milestones isolate the shell and expose any window regression:

| Milestone, process-relative | Baseline | Candidate |
|---|---:|---:|
| main_entered | 33.2 [32.1–38.1] | 33.4 [30.9–42.0] |
| gui_application_constructed | 105.7 [96.6–107.4] | 108.5 [96.2–135.9] |
| state_store_loaded | 106.5 [97.4–108.4] | 126.1 [115.1–153.9] |
| qml_component_loaded | 122.2 [113.3–124.3] | 143.6 [131.4–170.8] |
| menu_loaded | 132.9 [123.5–140.3] | 158.0 [142.9–185.5] |
| qml_root_loaded | 248.1 [241.3–260.3] | 274.5 [249.9–304.3] |
| first_window_exposed | 277.9 [264.9–288.0] | 281.2 [262.8–313.4] |
| first_scene_frame | 375.8 [357.3–391.3] | 378.9 [360.2–424.4] |

`state_store_loaded` in the candidate follows the early event pass as well as state loading; the additional interval is not evidence of slow disk-state parsing. `main_entered` includes loader/framework work before main and the enabled telemetry setup. Sampling (`/private/tmp/wam-probe-startup/sample/sample.txt`) places much of root creation inside AppKit's first NSWindow construction; it also sees font-database initialization. Sampling perturbs timing and is used only for attribution. First exposure-to-scene time includes initial GL/context/scene setup.

QML compilation is already configured for **all 14 QML files**, verified in Ninja commands and `.rcc/qmlcache`. AOT statistics contain 588 successfully compiled entries and 626 fallbacks (untyped context properties/functions and other unsupported code generation). Thus every file has a generated cache, but not every binding/function has native AOT code. Preferences, Quick Edit, crop UI and file dialogs are already lazy. No additional QML/font/icon deferral or style change was justified by these measurements. Native asset keys and audio/video port configuration already run on workers, with concurrent key batches and concurrent audio/video configuration where permitted.

### Specimen causes

- **u004**: native H.264 video-only. The avoidable delay is launch/event delivery before native preparation. Remaining cost includes VideoToolbox configuration and first presentation. It remains native with all five seeks drawn.
- **u005**: native H.264/AAC. Same scheduling delay, plus audio configuration/start/render-clock readiness after admission. Moving preparation earlier overlaps configuration with scene startup; audio-clock and presentation proofs are unchanged. It remains native with all five seeks drawn.
- **u007**: native video configuration cannot prove a bounded presentation-reorder depth from the SPS. The existing fail-closed refusal is retained at open. Concurrent audio configuration and exact native retirement still complete before fallback creation; no native picture is presented. Earlier admission advances the fallback path, but does not bypass retirement or pre-load libmpv on successful native/blank launches.

## Real-file seekprobe verdicts

The supplied `seekprobe.py` was run sequentially for every listed specimen. Its fallback open-to-picture value is `-1` because that script reports native draw timing only; the fallback restart timing is measured separately above.

Before:

```text
u004.mp4 native seeks=5/5 open_to_picture_ms=196 failure=
u005.mp4 native seeks=5/5 open_to_picture_ms=354 failure=
u007.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
```

After:

```text
u004.mp4 native seeks=5/5 open_to_picture_ms=181 failure=
u005.mp4 native seeks=5/5 open_to_picture_ms=264 failure=
u007.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
```

## Blank-launch memory

Seven additional alternating blank pairs, measured at two seconds via `proc_pid_rusage`; MiB, median [min–max]. Both retained dormant libmpv, verified by the synthesized blank test and absence of fallback-load/initialize events.

| Metric | Baseline | Candidate |
|---|---:|---:|
| resident | 121.52 [115.47–121.94] | 119.14 [113.14–119.30] |
| footprint | 287.39 [53.08–289.14] | 280.99 [59.19–289.05] |

## Validation and remaining scope

- Final full command: `ctest --test-dir build -LE benchmark --output-on-failure -j4`: **136/136 passed**. Log: `/private/tmp/wam-startup-ctest-final.log`.
- Added Qt-default-completion test: pumps only Qt posted events, verifies delivery on the owner thread with retained request identity; a return to main-dispatch delivery fails it. Existing tests retain latest-request, cancellation, exception and destruction coverage.
- Added `tests/startup_launch_test.py`: generates its own small H.264 fixture, checks argv and Apple Event opens occur once before exposure, confirms early Apple Event buffering and native picture, and checks blank startup has no media/fallback initialization. All three modes pass on the candidate; running the same test on the baseline fails specifically because its Apple Event open waits until after window exposure.
- Extended telemetry tests: runtime-disabled startup stamps claim no mailbox slots; a render-thread stamp performs no sink I/O; blank-launch finish emits an undecided-route phase fact.
- Frozen-file diff is empty. No private media or excerpts were committed. Build warnings reflect Homebrew framework deployment floors newer than the requested 13.3 target; this is not a release portability certification.

Remaining: first AppKit window/font/GL initialization, incomplete native QML AOT coverage, and u007's failed video admission overlapping audio configuration. No speculative fallback loading was retained: it would impose library/engine work on successful native launches, while early route scheduling already improves fallback latency. This patch does not claim a new codec proof, a cold-launch result, or a physical-display timestamp for fallback.

Artifacts and reproducibility: `/private/tmp/wam-probe-startup/ab-final/` contains all 70 launch logs, `results.json`, `summary.json`, and provenance; `seek-before/`, `seek-after/`, `memory/`, and `sample/` retain the other evidence. Run `scripts/performance/startup_ab.py <baseline.app> <candidate.app> <outdir> <specimens-dir> 7` and `scripts/performance/startup_memory.py <baseline.app> <candidate.app> <outdir>`. No other checkout was modified; no process outside this task was signaled.
