# VideoToolbox helper lifetime — 2026-11-04

The macOS 26.3.1 (25D2128), Apple-silicon failure is reproducible with Apple
frameworks alone. Attaching an `NSOpenGLContext` to an `NSView`, then creating
and correctly destroying a VT decompression session, leaves that client's
`VTDecoderXPCService` alive after the client exits. An unattached CGL or
NSOpenGL context does not reproduce it. A Qt Quick Metal window does not
reproduce it. Both WAM playback engines share the affected OpenGL window.

This establishes the trigger and excludes WAM's decoder ownership as the sole
cause. It does **not** identify the private Apple object retaining the launchd
domain. The mitigation below is an explicit owned-helper shutdown workaround,
not a claim that an extra VT invalidate call fixes macOS.

## Evidence

Artifacts from this investigation are under `/private/tmp/wam-probe-vtleak`.
The original `u004` launch had client PID 98589 and service PID 98595. The
service's unified log names its client; after exit it reports cancelled client
connections and remains alive. `lsof` shows the system helper and Apple decoder
libraries. Sampling another reproduced helper (755, client 740) shows only its
idle `NSRunLoop`, with `Idle exit: clean`. `launchctl print
pid/740/com.apple.coremedia.videodecoder` still identifies that exited client's
running service. Timestamp checks distinguish these helpers from concurrent
unrelated WAM probes on the same machine.

Temporary WAM tracing observed all of the following before exit:

- `VTDecompressionSessionWaitForAsynchronousFrames` returned and
  `VTDecompressionSessionInvalidate` completed.
- The retiring graph had one remaining shared owner, its native session
  destructor ran, its worker joined, and graph destruction completed.
- Waiting for background retirement, or closing the last window six seconds
  before quitting, still left the helper alive.

Those temporary prints were removed. Native playback already invalidates and
releases its decoder. The scrub lane uses the same decoder teardown; the new
integration test requires actual preview and commit frames before quitting.
There is no WAM worker calling `_exit` or `quick_exit` to bypass this teardown.
The `_exit` calls in export/caption subprocess launch failures are unrelated.

Measured controls (each service attributed to its client's launchd domain or
XPC peer log, with a five-second post-exit check):

| Control | Surviving owned helpers |
|---|---:|
| Blank WAM | 0 |
| `ffmpeg -hwaccel videotoolbox` | 0 |
| WAM's headless direct-sample decoder test | 0 |
| Minimal VT client, including AppKit/Qt initialization | 0 |
| Minimal client with a worker thread or playback activity assertion | 0 |
| Minimal client with an unattached accelerated CGL/NSOpenGL context | 0 |
| Minimal Qt Quick Metal window + VT | 0 |
| Minimal Qt Quick OpenGL window + VT | 1 |
| Minimal Cocoa `NSOpenGLContext setView:` + VT, without Qt | 1 |
| WAM `u004`, native | 1 |
| WAM `u040`, libmpv fallback | 1 |

The Cocoa reproducer logs actual decoded frames, explicit delayed-frame
completion, asynchronous-frame completion, invalidation/release, OpenGL
context deallocation, and autorelease-pool drainage. The helper still survives.
The issue also reproduced with an onscreen nonactivating window and with
LaunchServices `open -n -g -W`, rather than only the offscreen test geometry.

Additional failed avoidance experiments included initializing VT before the GL
window; early hide/resource release; a main autorelease pool; a post-destruction
run-loop drain; `glFinish`; explicit drawable/view/window detachment; single
buffering; volatile surfaces; disabling retained renderers; and normal AppKit
termination. Scratch-only private WindowServer cleanup experiments did not fix
it and are **not** included in production. No framework security setting or
VideoToolbox private decoder option was changed.

Apple documents framework XPC services as per-client processes tied to client
lifetime: <https://developer.apple.com/documentation/xpc>. The observed retained
service/domain violates that expected lifetime on this machine.

## Application workaround and ordering

1. A SIGTERM handler writes one byte to a nonblocking self-pipe. A Qt socket
   notifier calls ordinary `QCoreApplication::quit` on the GUI thread. No Qt,
   Apple, allocation, or teardown operation occurs in the signal handler.
2. The existing about-to-quit handler destroys all window/controller owners.
   Normal window closure still retires native graphs asynchronously.
3. After those owners are gone, a process-exit barrier waits for actual graph
   destruction, including worker joins, decoder invalidation and the retirement
   autorelease pool. It does not depend on delivery of main-queue completion
   callbacks after the event loop has stopped.
4. `runApplication` returns, destroying the QGuiApplication and render owners.
5. On macOS 26+, WAM queries **only**
   `launchctl print pid/<its-own-pid>/com.apple.coremedia.videodecoder`.
   It validates the returned domain, exact system executable, service PID,
   owning UID, and a start timestamp no earlier than WAM's. It rechecks process
   identity before sending **SIGTERM to this one idle helper** and briefly
   waiting for its disappearance. It does not enumerate or kill helpers by
   name, touch other applications' domains, or kill a helper at ordinary file
   close/replacement time. A blank launch creates no helper.

The external inspection is bounded to two seconds and 64 KiB; an unresponsive
query child is reaped. The decoder-service wait is also bounded to two seconds.
Unknown/malformed output or an identity mismatch fails closed without sending a
signal. Parser coverage includes mismatched domains, invalid PIDs, substituted
executables, and fake fields embedded in inherited environment values.

This deliberately preserves OpenGL rendering and libmpv hardware decoding.
Moving all rendering to Metal would also avoid the reproduced trigger, but
would require a new libmpv offscreen GL-to-Metal presentation path.

## Runnable checks

The telemetry build registers:

```sh
ctest --test-dir build -R '^(macos_video_service_lifetime|macos_video_service_identity|native_retirement)$' --output-on-failure
python3 tests/video_service_lifetime_test.py build/WAM.app --output /private/tmp/wam-vt-check
```

The integration test generates H.264 with FFmpeg and a local M3U wrapper for
real libmpv fallback. It checks blank launch; Qt quit; the real menu item's
`triggered` handler; last-window close then quit; SIGTERM; scrub/preview; and
fallback quit/SIGTERM. A separate continuously decoding FFmpeg client remains
alive throughout: its exact helper must survive every WAM quit. Polling records
only services from the tested client's domain whose start time follows launch,
then compares PID/start identities against the baseline through a settle loop.
Other apps may start or stop services without causing a false failure. If a
regression leaks, the test records the failure and cleans up only that verified
owned helper. It never kills baseline or unrelated helpers.

The preserved pre-workaround binary fails this test at `native-quit`, with one
owned orphan after the settle deadline; the candidate passes all eight cases.
The native-retirement test independently proves that the exit barrier waits for
a blocked graph destructor and needs no main-queue completion delivery.

An Apple-only diagnostic is also available; **window mode intentionally leaks
on the affected OS** and is therefore not registered as a passing CTest:

```sh
ninja -C build wam_video_service_os_probe
ffmpeg -v error -f lavfi -i testsrc2=size=160x90:rate=24:duration=4 \
  -c:v libx264 -threads 1 -pix_fmt yuv420p /private/tmp/wam-vt-fixture.mp4
build/wam_video_service_os_probe /private/tmp/wam-vt-fixture.mp4
build/wam_video_service_os_probe /private/tmp/wam-vt-fixture.mp4 window
```

Its printed `client_pid` identifies the exact launchd domain for inspection and
cleanup. Do not use a global `pkill` to clean up the diagnostic.

## Limits

The Apple lifetime defect itself remains open. This workaround depends on
`launchctl print`'s diagnostic format; a format or permission change fails
closed and will be caught by the lifetime integration test. It uses public
process-inspection/signalling APIs and the system CLI, not private framework
entry points. It has been measured on the reported Mac, not across every macOS
26 release or Intel hardware. Forced SIGKILL and crashes bypass orderly app
shutdown and are outside this fix's guarantee. A permanently stuck native
teardown can hold the process-exit barrier; it is not falsely declared drained.

No frozen media/playback contract or frozen audio-session/converter test was
changed. No private specimen media was copied into the repository.
