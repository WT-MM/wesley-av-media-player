# Phase 2d capture prerequisite

The ordered campaign is paused at item 1 pending an unlocked macOS display.
No later acceptance item is completed. The original phase-2c report is retained
as [PHASE2C_REPORT.md](PHASE2C_REPORT.md).

The only retained implementation change is the locked-session refusal in
`src/qt/macos_window_chrome.mm`. It runs only through the existing telemetry-
gated `videograb` test seam. It does not change production playback, decoding,
color conversion, geometry, presentation, or either stage default.

## Hardware capture test

For decoder-implementation logging, use the acceptance build:

```sh
cmake -S . -B build -DWAM_ENABLE_AVCODEC_STAGE=ON -DWAM_ENABLE_AVFORMAT_STAGE=ON
cmake --build build --parallel
python3 tests/native_display_capture_test.py \
  --output /private/tmp/<fresh-known-red-run>
```

The test generates four seconds of red H.264, selects the real hardware route,
requires first-frame presentation, and checks the central captured pixels for
red. It launches only build/WAM.app with all four telemetry identity variables,
isolated HOME, background/mute, and `480x270+2400+1000`. It does not move the
window or activate the application. An unlocked display is necessary; the
prescribed rectangle may also need an attached display containing it.
A current known-red PASS has **not** been obtained.

While the session is locked, the negative acceptance is:

```sh
python3 tests/native_display_capture_test.py --expect-session-locked \
  --output /private/tmp/<fresh-locked-run>
```

This separately requires real hardware selection and first-frame presentation,
then requires `DisplayCaptureSessionLocked` and no published PNG. It is an
explicit GUI proof, not part of unattended CTest. The retained fixed and
restored receipts pass; the temporary original implementation fails its named-
refusal assertion and writes a black image. Source restoration was byte-identical.

The display campaign's existing `grab` verb reads only the Qt scene. Its
`videograb` verb reads the actual window composition, including the native
video layer. Reordering these did not remove the black result while locked.
Neither a decoder frame nor a successful PNG write establishes display color.

After a known-color hardware PASS, rerun both ranges with
`tests/native_avcodec_display_probe.py` and evaluate using
`tests/native_avcodec_color_projection.py`. Keep the existing RMS and
matrix/range tolerances. The twelve-family/range qualification and software
measurements remain pending. Do not interpret the failed locked-session
captures as decoder-color failures.

## Session observation

The retained read-only receipt reports capture permission true and
`CGSSessionScreenIsLocked=1`. It was produced using AppKit/CoreGraphics:

```swift
import AppKit
import CoreGraphics
print("capturePermission", CGPreflightScreenCaptureAccess())
if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
  print("CGSSessionScreenIsLocked", session["CGSSessionScreenIsLocked"] ?? "missing")
}
```

Only a 1512×982 built-in display was active. The benchmark launch rectangle is
entirely outside it. An experimental capture-only move into that display,
followed by a 350 ms event-loop delay, still produced black while locked. That
experiment was removed byte-identically; it is not a retained fix or a proof
that placement is irrelevant after unlocking. Historical phase-2c captures
lack this session-state observation, so their precise environmental cause is
not retroactively asserted.

## Verification and remaining sequence

Both-stage acceptance CTest: 124/124. Restored shipped OFF/OFF CTest: 82/82.
Both builds completed before their test runs. No expectations in frozen tests
were changed. The final corpus uses the restored OFF/OFF executable and the
specified 97-file list, with quiet six-second launches.

Once display qualification passes, resume the owner's order: demux default for
proven single-stream shapes; software sixteen-window drain defect and storm;
amendment-24 production audio; mixed A/V qualification; bounded coexistence;
amendment-25 admission and per-stage decision. The append-only handoff records
24 and 25 as ratified, with no frozen implementation line yet changed.
