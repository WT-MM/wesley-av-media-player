Implemented D1–D14 and the M mute shortcut/menu item on branch `fix-ui`. Implementation commits: `db7f37a` (display metadata lifetime) and `3c13b33` (UI fixes and regression tests). No media sources, frozen contracts, or frozen audio tests changed. GUI checks used background-only, muted launches; no fullscreen, theater, or preferences activation checks were attempted.

The matched real-file baseline was rebuilt from `21a4fa3` in this clone. The executable supplied at task start was older: it switched u030 to fallback during a seek, while rebuilt HEAD correctly refuses it at open. That media-path difference belongs to the existing AAC admission commit, not these UI changes.

| Defect | Root cause and change | Own before → after evidence | Regression |
|---|---|---|---|
| D1 | Native refusal notifications treated Protocol as terminal despite recovery. Let the router recover quietly; only final playback failure is an error. | Injected Protocol: blocking error while mpv was playing → no error/notice, mpv playing. | `ui_refusal` |
| D2 | Pending requests had no visible ownership and permanently latched window claims. Publish loading/title immediately and reuse loading/empty windows; log backend switches quietly. | Pending `media=0`, two windows → `loading=true`, filename present, one window, then playing. | `ui_pending` |
| D3 | Failed playback retained its source; replacement inherited its paused state. Clear failed media and start a fresh playing intent; dismiss obsolete error dialogs. | Garbage: `media=1 dur=0`; valid replacement `paused=1 pos=0` → empty failed window, replacement playing at 2.87 s, dialog closed. | `ui_failed` |
| D4 | Replacement preparation temporarily pauses the previous session. New opens inherited that transient state. | Rapid loads left `paused=1 pos=0` → the distinct last filename wins and plays. | `ui_rapid` |
| D5 | Fallback used keyframe-relative seeks and unbounded end skips. Use `relative+exact` and clamp end targets. | Synthetic −0.5 s moved 11.6→10.8 s; end skip landed 19.6/20 s → 11.6→11.1 s and final-frame landing at 19.967/20 s. | `ui_skip` |
| D6 | Native replay required EOF even when already on the last frame. Recognize the final-frame interval on both routes. | Native Play stayed at 30 s paused → restarted at 0.93 s playing; both-route integration passes. | `ui_replay` |
| D7 | Volume setter left mute enabled. Volume adjustment now unmutes, including at a clamp. | `volume=0.7000 muted=1` → `muted=0`, level OSD. | `ui_volume`, controller test |
| D8 | Captions always reserved the transport height. Reserve only visible controls and scale the base inset with height. | At 480×270, hidden-controls cue y=124.15 → y=236.15; shown controls and OSD remain clear. | `ui_subtitles` |
| D9 | Fixed utility controls exceeded narrow bars. Hide speed/theater first, then Vivid at smaller widths. | At bar width 420, play ends x=274 and utilities start x=230 (44 overlap) → utilities start x=302 (28 gap). | `ui_transport` |
| D10 | Backend rate limits differed; stored native rate preceded quantization. Clamp both to 0.25–4 and snap to 1/64. | Native stored 1.37 and refused 5; mpv stored 5 → both store 1.375, 4, and 0.25 as appropriate. | `ui_rate`, controller test |
| D11 | Generic fallback errors overwrote useful native file diagnostics. Retain the incomplete-recording explanation through fallback failure. | Truncated file: “unrecognized file format” → “This recording is incomplete: information needed to open it is missing.” | `ui_truncated` |
| D12 | Menu suffix was always plural. | “1 Seconds” → “1 Second”; “5 Seconds” preserved. | `ui_menu` |
| D13 | Model search diagnostics were used directly as user text. Show a short recovery message and log configured/search paths. | Old message fails the new length assertion → short missing/damaged-model message passes. | `caption_service` |
| D14 | Native samples used stale cached clock/pause fields. Report the controller’s accepted transport rate and pause state. | EOF: sample `paused=false`, `clock_rate=1` → 4× samples report 4 and EOF reports paused. | `ui_metrics` |
| Mute | Add bare M on the video stage, respecting text-field focus, plus a checked Playback menu item. | New keyboard/menu behavior passes. | `ui_mute` |

The failed-open regression also exposed a real presentation-host use-after-free: worker-written non-atomic associated geometry could be released before the main-thread reader retained it. Atomic association ownership fixes it. The focused concurrent-reader/writer test crashed with exit 139 before the fix and passes afterward (`macos_native_layer_video_output`). This changes presentation metadata ownership only.

Exact `seekprobe.py` verdict lines, before (rebuilt `21a4fa3`):

```text
u004.mp4 native seeks=5/5 open_to_picture_ms=226 failure=
u005.mp4 native seeks=5/5 open_to_picture_ms=319 failure=
u030.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"
u040.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AVFoundation could not locate a bounded sync start; libavformat: LibavformatAacConfigurationUnqualified: aac"
u060.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"
```

After:

```text
u004.mp4 native seeks=5/5 open_to_picture_ms=178 failure=
u005.mp4 native seeks=5/5 open_to_picture_ms=185 failure=
u030.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"
u040.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AVFoundation could not locate a bounded sync start; libavformat: LibavformatAacConfigurationUnqualified: aac"
u060.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"
```

Fallback probe `seeks=0/0` and `open_to_picture_ms=-1` denote absent native proof events, not missing fallback pictures. Separate playback samples confirm mpv renders: maximum sampled drawn frames after the fixes were 324 for u030, 316 for u040, and 306 for u060. u030 remains fail-closed because its AAC packet residual exceeds 256 samples; no source admission rule was relaxed. u060 has the same AAC residual refusal. For u040, AVFoundation cannot establish a bounded sync start and the alternative demux cannot qualify its AAC configuration. These existing source refusals remain unchanged. u004/u005 retain native 5/5 seek coverage. The timing differences are observations, not a controlled performance claim.

Final build succeeded using the requested Homebrew Qt/native-video configuration, and the development fallback dylib was staged. Full validation completed in **173.62 seconds: 150 selected, 147 passed, 3 skipped, 0 failures**. All 14 new UI ctests passed, along with the added controller, caption-message, and metadata-concurrency checks.

```sh
QT_QPA_PLATFORM=offscreen QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1 \
HOME=/private/tmp/wam-uiqa-fix/ctest-home WAM_TEST_BACKGROUND=1 WAM_TEST_MUTED=1 \
ctest --test-dir build -LE benchmark --output-on-failure -j4
```

The three existing tests skipped because offscreen OpenGL is unavailable were `player_core_render_context_permission`, `macos_native_qt_gl_compositor`, and `macos_native_qt_gl_output`. They are not counted as passed; live foreground validation remains outside the requested scope. Final log: `/private/tmp/wam-uiqa-fix/ctest-final-verified.log`.

Earlier runs retained in the evidence directory include sandbox platform-access failures, the now-fixed geometry race, the old slow-seek text expectation, and the caption watchdog scheduling failure. No failed assertion was deleted or silently counted as a pass.

Existing slow-seek wiring assertions now require the plain “Seeking…” notice while retaining exact-target readiness assertions. Its harness explicitly uses Cocoa for native menus, with background launch enabled. The existing caption-service watchdog test runs serially to avoid starving its 150 ms child-start window; its timing, cancellation, descendant cleanup, and output assertions are unchanged.

Evidence is retained under `/private/tmp/wam-uiqa-fix/` (initial UI before/after, isolated pre-fix cases, build and ctest logs), `/private/tmp/wam-probe-uiqa/` (matched real-file probes), and `build/ui-evidence/` (final synthetic UI tests and PNGs). Notable comparisons: `before-isolated/subtitles/hidden.png` versus `build/ui-evidence/subtitles/hidden.png`, and `before-isolated/transport/narrow.png` versus `build/ui-evidence/transport/narrow.png`. The isolated before cases temporarily restored the old relevant logic while retaining the diagnostic seams; final source was restored afterward.

Reports are saved as `report.md` in this clone and `/private/tmp/wam-video-report.md`. No requested UI defect remains open. Environmental validation limits and final counts are recorded above. No push or PR was made.
