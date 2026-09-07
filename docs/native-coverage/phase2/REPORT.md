# Phase 2d — incomplete; capture prerequisite blocked by locked display

**This is not phase-2d acceptance.** The ordered campaign is paused at item 1
awaiting an unlocked display. The only implementation change makes the
in-process compositor capture refuse `DisplayCaptureSessionLocked` instead of
saving a misleading black PNG. A known-color hardware capture has not passed.
The original [phase-2c report](../phase2d/PHASE2C_REPORT.md) and its measurements
remain historical evidence, not newly qualified results.

Both source defaults remain **OFF**. The local build has also been restored to
`WAM_ENABLE_AVFORMAT_STAGE=OFF`, `WAM_ENABLE_AVCODEC_STAGE=OFF`. The requested
demux-default change has not been implemented because item 1 has not cleared.
No claim is made that the current configuration meets the requested 84/97 gate.

## Ordered outcomes

| Item | Current outcome and proof |
| --- | --- |
| 1. Capture regression / software display color | **PARTIAL, BLOCKED.** Current hardware playback reaches first-frame presentation, but composited captures are black. Read-only observation confirms the display is locked despite capture permission. The new named refusal passes a hardware-backed negative test and fails with the change reverted. Known-color positive and all software/range color qualifications await unlock. |
| 2. Demux ON, proven single-stream shapes | **NOT STARTED.** Default remains OFF. The existing mixed-stream refusal remains intact. |
| 3. Software sixteen-window drain / cancellation storm | **NOT STARTED.** Phase 2c's five ASP failures remain unresolved; its hardware control had zero. |
| 4. Production DTS / TrueHD / MLP audio | **NOT STARTED.** Amendment 24 is ratified and recorded, but no production or frozen implementation change is applied. Existing isolated decoder proofs do not establish production retained counts, seeks, downmix or exact A/V. |
| 5. Libavformat mixed A/V | **NOT STARTED.** No mixed-stream shape newly admitted; exact audio timing remains unqualified. |
| 6. Native/mpv coexistence | **UNCHANGED.** Existing `PlaybackFfmpegClosureConflict` remains. Cached mpv can prevent later native FFmpeg sessions until restart; no new coordinator/UI qualification is claimed. |
| 7. Stage decisions / amendment-25 admission | **NO ENABLEMENT.** Both defaults OFF. Amendment 25 is ratified but unapplied; derived private-byte admission and combined audio/video worker reservations remain absent. |

## Capture investigation and test

The current session reports capture permission true and
`CGSSessionScreenIsLocked=1`. Only a 1512×982 built-in display is active; the
required `480x270+2400+1000` benchmark rectangle is entirely outside it.
[Session receipt](../phase2d/session-state.txt).

The hardware control selected VideoToolbox hardware and drew frames before
capture. Capturing before the Qt `grabWindow()` call and omitting that call
still yielded black. An experimental capture-only relocation into the display
with a 350 ms event-loop delay also remained black while locked; that change
was removed byte-identically. The retained change does not reposition windows.

The lock is a confirmed present qualification blocker, not a retrospective
proof of the precise environment during phase 2c. An unlocked A/B is still
needed to resolve placement and establish valid displayed pixels. `grab`
contains only Qt's scene; `videograb` reads the composited native layer.

The new [hardware capture test](../../../tests/native_display_capture_test.py)
generates red H.264 and requires hardware selection plus first-frame
presentation. Its positive mode then checks red pixels; its locked-session
mode requires the named refusal and no PNG. The latter passes on the
[fixed](../phase2d/locked-fixed/result.json) and
[restored](../phase2d/locked-restored/result.json) candidates.
With the original implementation temporarily restored, it fails exactly at
`locked compositor must refuse by name`; the original also writes a black PNG.
[Failure](../phase2d/capture-reverted.log),
[byte-identical restoration hashes](../phase2d/revert-proof.json).

## Amendments and frozen lines

The handoff ledger now records **AMENDMENT 24** and **AMENDMENT 25** as ratified
by the maintainer's phase-2d directive. The full appended
[ledger text](../phase2d/amendments-ratified.md) preserves the authorized scope.
For each amendment, the application entry states:

> Application status at ratification: no frozen line touched. Exact before/after patches will be appended here for each applied change; authorization alone is not acceptance.

Thus the exact set of frozen before/after changes in this run is empty.
All frozen source/test bytes checked against the starting snapshot are
[unchanged](../phase2d/frozen-hashes.json). SESSION_HANDOFF.md changed append-only
and remains gitignored. Existing Apple test expectations were not edited.

## Re-run measurements and verification

| Measurement | Phase-2d result |
| --- | --- |
| Known-red hardware capture | Locked-session refusal PASS; displayed-color positive pending |
| Software display matrix/range/RMS, limited and full range | Not qualified; unlocked hardware oracle required first |
| CPU / process energy / footprint hardware/software table | Not re-run; prior phase-2c table remains historical |
| Sixteen-window hardware/software soak and storm | Not re-run; prior ASP failure remains open |
| Full CTest, acceptance ON/ON build | **124/124**, 43.36 seconds |
| Full CTest, restored shipped OFF/OFF build | **82/82**, 39.68 seconds |
| Capture behavioral revert proof | Original FAIL, fixed/restored PASS, source restored byte-identically |
| Existing six-family capture launch-policy test | PASS |
| Final shipped corpus | **78/97**; zero losses vs the original shipped 78/97; six losses vs phase 2c/3 opt-in 84/97; required gate NOT MET |

[ON/ON CTest](../phase2d/ctest-on.log),
[OFF/OFF CTest](../phase2d/ctest-shipped.log),
[final build identity and options](../phase2d/build-receipt.json).
Builds used `cmake --build build --parallel`, with reconfiguration for option
changes. CTest never ran during a build. No Git staging/commit/reset/checkout/
stash operation, network access, installed-app launch, or name-based process
termination was used. Every GUI launch was identity-bound, background/muted,
used scratch HOME and the prescribed geometry, and launched only build/WAM.app.

The final corpus used the specified list and quiet six-second launches of one
unchanged OFF/OFF executable. All asset hashes match phase 2c. The six losses
against its opt-in 84/97 are the RustDesk recordings; restoring the original
shipped OFF defaults leaves their demux recovery disabled. Thus the requested
84/97 and zero-loss acceptance against phase 3 is **not met**.
[Corpus summary](../phase2d/corpus-summary.json),
[all identities and outcomes](../phase2d/corpus-results.json).

## Continuation

Unlock the macOS display, rerun the known-color hardware test, then establish
whether the required rectangle has an active display. Resume the owner's
ordered items only after display qualification passes. Production audio,
private admission, software resource stress, mixed A/V, coexistence improvement,
per-stage enablement and the hardware/software measurement table remain
explicit deferrals. [Reproduction and failed experiments](../phase2d/REPRODUCE.md).
