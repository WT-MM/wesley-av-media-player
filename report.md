# WAM VideoToolbox helper lifetime report

The leak is reproducible without WAM or Qt: on this Mac, attaching an accelerated
`NSOpenGLContext` to an `NSView` before VideoToolbox decoding leaves the client's
decoder helper alive after exit. Headless decoding and a Qt Quick Metal window
do not. Explicit delayed/asynchronous frame completion, session invalidation and
release, GL context deallocation, and autorelease-pool drainage do not prevent
it. The committed Apple-only diagnostic decoded 288 frames in each mode: zero
survivors headlessly, one with the OpenGL window.

Both u004's native path and u040's libmpv path share this window trigger. The
internal Apple object retaining the client domain remains unidentified. This is
an OS workaround, not a claim that an extra decoder invalidate fixes macOS.

## Changes

- Drain background native retirement after all window/controller owners are gone.
- Translate SIGTERM through a self-pipe into ordinary GUI-thread Qt shutdown.
- After application/render teardown, on macOS 26+, inspect only WAM's own
  `launchctl` PID domain and explicitly SIGTERM its idle decoder helper. Validate
  the domain, exact executable, UID, PID and start identity first; never enumerate
  and kill helpers by name. Unknown identities fail closed.
- Add generated-media lifetime coverage, ownership-parser tests, retirement-barrier
  coverage, and a separate Apple-only OS diagnostic.

## Specimen results

Exact `seekprobe.py` verdicts before:

```text
u004.mp4 native seeks=5/5 open_to_picture_ms=139 failure=
u040.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AVFoundation could not locate a bounded sync start; libavformat: LibavformatAacConfigurationUnqualified: aac"
```

After:

```text
u004.mp4 native seeks=5/5 open_to_picture_ms=155 failure=
u040.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AVFoundation could not locate a bounded sync start; libavformat: LibavformatAacConfigurationUnqualified: aac"
```

Both previously left one owned helper; both now leave none. u040's existing
fail-closed open refusal is unchanged. Neither specimen switches engines during
native playback. The small picture-time difference is a single-run observation,
not a performance conclusion.

## Validation

Release telemetry build completed with the requested Homebrew Qt configuration
and staged libmpv fallback. The generated H.264 integration test passes blank,
Qt quit, real menu handler, last-window close then quit, SIGTERM, scrub/preview,
fallback quit, and fallback SIGTERM. A separate FFmpeg hardware decoder survives
every case. The preserved pre-workaround binary fails the same test with an
owned orphan; failure cleanup removes only that verified helper.

Final full suite: **152/152 passed**, using
`ctest --test-dir build -LE benchmark --output-on-failure -j4`.

An earlier run caught a direct native-retirement include across the existing
host boundary; it was corrected through `NativeEmbeddingSupport`, leaving the
architecture proof intact. Another run hit the unchanged caption-service test's
fake GPU descendant startup assertion (150 ms watchdog). That test passed
unchanged in isolation before the final full rerun; no timing limit was loosened.

Run the focused regression with:

```sh
ctest --test-dir build -R '^(macos_video_service_lifetime|macos_video_service_identity|native_retirement)$' --output-on-failure
```

Investigation logs, ownership receipts and before/after probes are retained in
`/private/tmp/wam-probe-vtleak`. Only verified helpers from this investigation
were cleaned up. Frozen files and private specimen contents were not changed or
committed. No push or PR was made.

## Remaining limits

The Apple defect remains open. The workaround depends on `launchctl print`'s
diagnostic format and fails closed if it changes. Verification covers this
Apple-silicon Mac; crashes/SIGKILL bypass orderly shutdown. A stuck native
destructor can hold the exit barrier. Detailed controls, unsuccessful ordering
experiments and diagnostic instructions are in
`docs/VT_DECODER_SERVICE_LIFETIME_2026_11.md`.
