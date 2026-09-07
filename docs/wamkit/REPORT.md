# WAMKit implementation report

The working tree adds a Qt-free native embedding path, a versioned framework, and an Objective-C AppKit host. The shipped decode configuration remains AVFormat ON / AVCodec stage OFF. No changes are staged or committed. The accepted [DESIGN.md](DESIGN.md) is unchanged.

## Outcomes and evidence

1. **Layering:** native command sequencing, generation checks, observation draining, watchdogs and retirement now live in `src/platform/macos/native_playback_owner.*`. The Qt owner derives from this implementation and supplies app policy and notifications. Session construction accepts a presentation factory; the Qt sibling installer and SDK detached view share the existing CALayer implementation. Destruction and worker joins run through charged, bounded asynchronous retirement. The layering checkpoint passed 113/113 tests and all seven native replays: [receipts](proofs/layering/).
2. **Framework:** `WAMKit.framework` exposes only the documented C ABI and two Objective-C classes. The Clang module imports in Swift. A framework-only configuration returns before Qt/mpv discovery. The SDK display build excludes the compositor SPI; the app retains its existing audit route. Installation preserves the complete framework closure.
3. **Sample host:** [WAMKitHost](../../examples/WAMKitHost/main.m) embeds `WAMPresentationView`, with native Open, Play, Pause, exact Seek and Close controls. It links AppKit and WAMKit without Qt. Its CMake option defaults ON on macOS.
4. **Proofs:** synthetic Matroska and MP4 playback exercise the public C API in the AppKit host, including exact off-grid seeking and clean retirement. A real native HE-AAC refusal crosses the same ABI. Tests additionally cover bounded commands, callback reentrancy/cancellation, wrong-thread access, replacement open, and close quarantine. See final receipts below.
5. **Integration documentation:** [README.md](README.md) documents CMake/Xcode use, public types and functions, main-thread ownership, callback behavior, exact versus approximate time, refusal names, packaging and redistribution.

## Public ABI

The exact Mach-O allowlist is [exports.txt](../../src/wamkit/exports.txt): 22 symbols, comprising the following 18 C functions and the class/metaclass symbols for `WAMPlayer` and `WAMPresentationView`.

| Group | Every exported C function |
|---|---|
| Global queries | `wam_abi_version`, `wam_copy_capabilities`, `wam_refusal_name` |
| Ownership | `wam_player_create`, `wam_player_retain`, `wam_player_release` |
| Observation | `wam_player_observe`, `wam_player_copy_snapshot`, `wam_player_set_metrics_enabled` |
| Transport | `wam_player_open_file`, `wam_player_set_paused`, `wam_player_seek`, `wam_player_stop`, `wam_player_close` |
| Configuration | `wam_player_set_volume`, `wam_player_set_muted`, `wam_player_set_rate` |
| Presentation | `wam_player_presentation_view` |

Every public type: `wam_player_t`, `wam_request_id_t`, `wam_status_t`, `wam_state_t`, `wam_result_t`, `wam_event_kind_t`, `wam_refusal_t`, `wam_time_t`, `wam_error_t`, `wam_snapshot_t`, `wam_event_t`, `wam_capabilities_t`, `wam_event_callback_t`, `WAMPlayer`, `WAMPresentationView`. Definitions and numeric constants are in [WAMKit.h](../../src/wamkit/include/WAMKit/WAMKit.h) and [WAMKitObjC.h](../../src/wamkit/include/WAMKit/WAMKitObjC.h).

## Behavioral negative controls

[Seventeen runtime revert receipts](proofs/final/revert-results.json) record passing baselines, successful builds of deliberately regressed implementations, failing runtime tests, byte-identical restoration and passing restored tests. The [individual logs](proofs/final/reverts/) cover:

- Off-main retirement and presentation dependency lifetime.
- Exact host-clock rounding, audio boundary identity, session completion proof, router completion proof, and retained exact seek target.
- First physical draw PTS, paused rational frame coverage and replacement-item PTS/generation.
- Named native refusal, 32-request backpressure, detached presentation and framework-relative decoder loading.
- Quarantine retaining admission until actual destruction, exact host input parsing, and preservation of framework symlinks when embedding the sample.

The original structural detached-view negative control is superseded by the runtime presentation control. No frozen test was weakened. [Frozen-file hashes](proofs/final/frozen.json) match both the starting receipt and HEAD bytes.

## Final validation

The final full CTest run passed **123/123**, with zero failures in **193.34 seconds**: [log](proofs/final/ctest-final.log). This includes all original tests and the native extraction, exact-time, C ABI, C11/Objective-C/Swift header, AppKit playback/refusal/lifecycle and embedded-package tests.

The normal SDK was separately configured and built with `WAM_BUILD_APP=OFF`, `CMAKE_DISABLE_FIND_PACKAGE_Qt6=TRUE` and `WAMKIT_ENABLE_TEST_SUPPORT=OFF`: [configuration](proofs/final/sdk-only-configure-final.log), [build](proofs/final/sdk-only-build-final.log), [shipping audit](proofs/final/shipping-audit.json), [header imports](proofs/final/shipping-headers.log). The shipping audit confirms test-environment readers and compositor SPI are absent. [Installed](proofs/final/installed-audit.json) and [relocated](proofs/final/relocated-audit.json) framework audits also pass.

All six RustDesk recordings and `appleads.mp4` passed the final eight-second native campaign: [identities and results](proofs/final/replays/results.json). Every run drew frames, selected native without fallback, exited cleanly and reported clock rate `1.0000` to four decimals. Draw counts in sorted RustDesk order were **19, 208, 216, 189, 183, 195**; the appleads control drew **227** frames.

The relocated bundle passed [MP4](proofs/final/relocated-mp4/result.json), [Matroska](proofs/final/relocated-mkv/result.json) and [named refusal](proofs/final/relocated-refusal/result.json). Playback retained exact first PTS zero, `T=1001/30000`, audio start `267/8000`, drawn frames and clean close. A [second Matroska run](proofs/final/relocated-mkv-repeat/result.json) also passed unchanged. **An earlier relocated Matroska run failed clean-close acceptance:** the native session published `Stop`, and close returned charged quarantine; [failed receipt and metrics](proofs/final/relocated-mkv-timeout/result.json). This failure is resolved by the cancellation/retirement work documented below; the original failed receipt remains part of the evidence. The final full CTest host checks and all seven required app replays passed.

Playback counters retain WAM's renderer-acceptance meaning; `clock_rate` is the native requested rate, not an independent measurement of wall-clock advancement. Quiet runs prove native rendering and transport without an audible-output claim.

The local test configuration enables `WAMKIT_ENABLE_TEST_SUPPORT`; normal SDK builds default it OFF. Measured launches use build-tree executables, fresh scratch HOME directories, all four benchmark identities, background geometry, output-copy mute and streamed metrics. Scripts manage only their own child PIDs.

The existing app packaging test required an app-only mpv fallback seed from the local pre-existing bundle. Its unavailable dependency produces the expected named load refusal in that test. The SDK does not contain that seed, and the seven native media replays do not select fallback. Native media-service tests and AudioToolbox fixture encoding required execution outside the filesystem sandbox. An intermediate strict compilation failure in a frozen audio test was resolved by correcting signedness in the new implementation, without modifying the test. One full run timed out waiting for an injected failure in the unchanged Qt GL output test; its isolated retry and the subsequent 122-test full run passed. The relocation audit caught CMake flattening framework symlinks in the host bundle; the copy now uses `ditto`, and an additional packaging regression test checks the embedded closure and strict signature. Sandbox metadata restrictions required the bundle copy to run outside the sandbox.

## Intermittent host defect follow-up

### Reproduction and root causes

The original AVFormat ON / AVCodec OFF implementation was exercised in **196 measured baseline launches**, plus two sandboxed launches that aborted before playback. The [receipt manifest](proofs/defect/reproduction-receipts.jsonl) records **57 clock-acceptance failures, one SIGTRAP, and 14 non-trapping unclean closes** (categories can overlap). Full host streams and stderr are retained in the adjacent run directories. **The requested three SIGTRAP reproductions were not obtained.** The first fresh reproduction and the maintainer's earlier crash nevertheless have matching Apple crash stacks; this count shortfall remains an explicit validation deferral, not a claim of three reproductions.

**A — shared metrics semantic defect, not test acceptance.** `NativeMediaClock::sample()` replaces its scheduling `rate` with the slope of the selected audio interval. `NativeMediaSession::publishMetrics()` exported that slope as `clockRate`, despite the private metrics contract and public SDK documentation specifying the requested transport rate. Audio-device interval timing therefore leaked into the requested-rate metric. This also affected the Qt app, which copies the same `NativeMediaSessionMetrics::clockRate` in `src/qt/native_playback_owner.mm`. Neither host nor app acceptance has been relaxed.

The timestamped baseline contains **39 deviating metrics rows**: 12 in Playing before seek, 26 in Playing after seek, and one delivered after Close submission while the snapshot still said Playing. Every row had drawn frames; none was a pre-first-draw or Seeking-state sample. [Every timestamped deviation](proofs/defect/deviating-samples.json) records the exact JSON value, one-based stream ordinal, generation, draw count, and elapsed seconds from measured-open initiation. For example, `baseline-8-mp4` row 19 reports `0.9998017971046799` at 2.5001859999611042 seconds, generation 2, 55 drawn frames, after seek and before Close. Values range from `0.9997432300102602` to `1.0001709276487674`. The original-timing runs retain their complete untimestamped streams separately.

Three timestamped failure receipts provide these concrete samples (seconds from measured-open initiation):

| Receipt | Row | `clock_rate` | Seconds | Draws | Phase |
|---|---:|---:|---:|---:|---|
| [baseline-0-mkv](proofs/defect/baseline-0-mkv/metrics.jsonl) | 20 | 0.9999404332359099 | 2.7528518332983367 | 60 | Playing, seek completed |
| [baseline-1-mkv](proofs/defect/baseline-1-mkv/metrics.jsonl) | 19 | 1.0000644572794721 | 2.5190393749508075 | 56 | Playing, seek completed |
| [baseline-5-mp4](proofs/defect/baseline-5-mp4/metrics.jsonl) | 9 | 0.9999472684057668 | 0.7619093333487399 | 15 | Playing, before seek |
| Same MP4 receipt | 20 | 0.9998047256395227 | 2.7579208749812096 | 61 | Playing, seek completed |

The fix carries `requestedRate` alongside the scheduling slope in the private clock snapshot and exports that field through the shared metrics sampler. The exact media/host interval, segment slope, interpolation, presentation deadlines and rational seek proofs are unchanged. A drifted interval at requested rate 2 now independently proves both a requested-rate observation of 2 and the original interpolated media position.

**B — two cancellation ownership defects.** The [fresh SIGTRAP report](proofs/defect/first-reproduction/WAMKitHost-2026-09-07-152543.ips), PID 19200, identifies `CFRelease(NULL)` in `-[AVAssetReaderOutput _setFigAssetReader:]` beneath `AVAssetReader cancelReading`. Main was simultaneously inside another `cancelReading` invocation reached through `NativeMediaSession::stop`; the session worker reached the trapping invocation through `readNext → stage → publishCancellation → ProductionGeneration::cancel`. The [maintainer crash](proofs/defect/maintainer-crash/WAMKitHost-2026-09-07-152249.ips), PID 17635, shows the same overlap, including Apple's teardown/join on main. This is neither a presentation-view lifetime fault nor a test problem.

Production generations now preallocate a serial dispatch data source on the source worker. Cancellation callers publish the flag and merge a notification; the handler alone performs Apple cancellation, claiming each reader once. Its completion is drained on the source/retirement owner. Cancellation-reader pins keep the final generation reference on that owner even if a caller overlaps publication withdrawal. No new allocation, Apple teardown or wait is placed on the cancelling GUI caller, audio callback or presentation deadline path.

The non-trapping `Stop`/quarantine failure has a second, independently tested ordering fault: Stop interrupts a source read; its `MediaSourceCancelled` result can enter ordinary dispatcher Cancel and invalidate the video consumer before the owner issues exact retirement. The consumer then rejects the competing retirement. Stop now publishes terminal cancellation intent before interrupting source I/O. The returned source event remains owned until `retire()` consumes the exact invalidation; it cannot start an independent consumer Cancel. Charged quarantine and its deadline remain intact.

### Regression and runtime proof

[Six temporary-revert controls](proofs/defect/reverts/results.json) pass with the fix, build successfully with the relevant implementation regressed, fail their runtime assertions, then pass after byte-identical restoration. They separately cover requested-rate capture, metrics export, Stop's cancellation call, dispatcher retirement authority, destruction-thread ownership, and off-main single-reader cancellation. The real-reader test holds the Apple cancellation boundary while concurrent requests return; the lifetime test overlaps a retained cancelling caller with source close. No frozen file changed; [hashes](proofs/defect/frozen.json) match HEAD.

The host campaign passed **30/30 consecutively for each of MP4, Matroska, refusal and API**, with [all 120 receipts](proofs/defect/proof/receipts.jsonl) and adjacent streams/stderr retained. Full suites [1](proofs/defect/proof/full-1.log) and [3](proofs/defect/proof/full-3.log) passed **124/124** in **164.74 s** and **191.33 s**. [Full suite 2](proofs/defect/proof/full-2.log) failed only the unchanged Qt GL compositor test on a presentation timeout (`submitted=17 imported=14 rendered=52`); its [isolated retry](proofs/defect/proof/gl-retry.log) passed in **4.48 s**. The timeout remains visible rather than being counted as a green run. The new real-reader cancellation CTest increases the suite from 123 to 124 tests.

The independently relocated build-tree host passed Matroska **10/10 consecutively**, including exact off-grid seek and clean uncharged close: [receipts](proofs/defect/proof/relocated-receipts.jsonl). All six RustDesk recordings and `appleads.mp4` passed native replay through `build/WAM.app`, with drawn frames and every accepted clock sample formatting to `1.0000`: [seven receipts](proofs/defect/proof/replays/results.json). Draw counts in sorted RustDesk order were **19, 207, 212, 188, 208, 198**; appleads drew **202** frames. Logs and complete metrics are adjacent to each receipt.

[Validation summary](proofs/defect/validation-summary.json) and [final source/binary identities](proofs/defect/final-identities.json) bind these results to the restored implementation. The required parallel build succeeded. All changes remain unstaged and uncommitted.

One additional baseline run (`original-6-mkv`) logged an audio-device format republication/recovery followed by a seek Flush refusal. It is retained as a separate observation and is not represented as a SIGTRAP or a clock-only failure.

## Packaging and release limits

The framework contains five Mach-O images: WAMKit, libvpx, and the three lazily loaded `-wamnative` FFmpeg libraries. FFmpeg keeps its `-wamnative` install names. Dependencies and symlinks stay inside the framework except Apple system libraries/frameworks. No Qt, mpv, eager FFmpeg dependency, Homebrew rpath or external private dependency belongs in this closure. Notices, build receipts, the pinned FFmpeg source archive, memory-reservation modification and build scripts accompany it.

Local signing is ad hoc. The available arm64 libvpx binary has a macOS 26.0 load floor, making this package's effective minimum 26.0 despite the SDK display guard at 14 and main image load floor at 13.3. macOS 14, additional architectures, clean-machine execution, rebuilt LGPL replacement libraries, Developer ID signing and notarization remain release validation. WAM's own embedding/redistribution license remains a maintainer decision.

## Proposals and deferrals

**Frozen-contract proposals: none required.** Exact time and completion use a new private companion contract; detailed refusal transport uses a new session diagnostic slot. Both frozen headers and frozen audio tests remain byte-identical.

The requested local-file embedding path is implemented. Broader design work remains explicit: dynamic-framework dogfooding by the Qt app (it currently uses the shared extracted implementation through static archives), a configurable native power-activity service, richer item/track/route metadata, exact live anchor observations, lower host-selected admission limits, subtitle extraction/overlay, Swift async conveniences and expanded multi-instance/occlusion campaigns. Preview, live track switching, mirroring, frame export and network playback are not exposed. These omissions do not widen any frozen decode or resource contract.
