# Native encoding

WAMKit's additive [encoding API](../../src/wamkit/include/WAMKit/WAMKitEncoding.h)
encodes host-supplied video frames and PCM audio. It is independent of the player,
Qt, microphone capture, and the bundled FFmpeg decoder closure.

| Output | Backend | Hardware guarantee |
| --- | --- | --- |
| H.264 Main, 8-bit BT.709 SDR | VideoToolbox compression session | Required and verified on each created session |
| HEVC Main, 8-bit BT.709 SDR | VideoToolbox compression session | Required and verified on each created session |
| AAC-LC in M4A, mono/stereo, 44.1/48 kHz | AudioToolbox, explicitly selected `appl` codec | Software; `require_hardware=1` returns `HardwareAACEncoderUnavailableOnMacOS` |

`wam_video_encoder_copy_info` and `wam_audio_encoder_copy_info` expose the selected
implementation, hardware flag, and accepted input-frame count. A recorder can
show “AudioToolbox software AAC” directly. Do not label native AAC as hardware
accelerated just because it uses an Apple framework or runs on Apple silicon.

On the development M3 Max, AudioToolbox's installed AAC encoder enumeration
returned one entry: type `aenc`, codec `aac `, manufacturer `appl`. There was no
`aphw` encoder. The SDK's named hardware/software audio manufacturer constants
are iOS-only; the macOS implementation uses the documented `appl` FourCC
explicitly. This is a deliberately software-only macOS AAC backend, not a claim
that every future Apple platform has the same hardware capabilities.

Video creation sets
[`RequireHardwareAcceleratedVideoEncoder`](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder)
and verifies
[`UsingHardwareAcceleratedVideoEncoder`](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder)
after preparing the session. An unavailable, busy, or unsupported hardware
configuration is refused. No software VideoToolbox or FFmpeg fallback exists.
GPU/Neural Engine workloads are not introduced for audio encoding.

## Ownership and scheduling

Create and use each handle on a host-owned serial worker, including destruction.
Calls may block; never call from a Core Audio render/input callback or use the
same handle concurrently. Unlike playback handles, encoder handles do not require
AppKit main. The host owns capture permission, device selection, a bounded queue
between capture and encoding, security-scoped file access, and UI delivery.

Four encoder handles, combined across audio and video, are admitted per framework
image. A finished audio handle remains charged until released. This independent
budget does not consume or expand playback admission. Failed creation releases its
charge. No client callbacks, detached tasks, or growing SDK-owned queues exist.

Video accepts matching-size IOSurface-compatible NV12 video-range frames. It
passes the CVPixelBuffer directly to VideoToolbox without an application-side
pixel copy. Supply BT.709 SDR content; HDR, wide-gamut input, BGRA conversion,
10-bit, ProRes, and AV1 encoding are outside this first API. Width and height must
be even, 16–4096, with at most 4096×2160 pixels. Bitrate is 100 kb/s–100 Mb/s;
actual hardware admission can be narrower. The host retains source pixels through
the call and may reuse them after return.

Each encode call completes pending frames before returning a single retained
CMSampleBuffer. The host must CFRelease it, or retain it in a **bounded** muxer
queue. Frame reordering is disabled. This simple synchronous contract trades
throughput for bounded in-flight work; it is not a benchmarked high-throughput
transcoder. The host can feed compressed samples into AVAssetWriter inputs with
`outputSettings:nil` and the sample format description as the source-format hint.
File muxing, capture, and A/V synchronization remain host responsibilities.

PTS and duration use exact `wam_time_t` rationals. PTS must be nonnegative and
frames must not overlap; durations must be positive. Overflow/rounded additions
are refused rather than silently shifting timestamps. Validation errors are
retryable. A backend error makes the video encoder terminal until release.

Audio accepts 1–4096 contiguous interleaved Float32 PCM frames per write. Values
must be finite and within −1…1. Calls copy/consume input before return. The sample
rate and channel count are fixed at creation; capture resampling belongs to the
host. The AAC encoder chooses its default bitrate; no quality tuning API is
promised. `finish` flushes codec tail and closes the M4A container, reports errors,
and is idempotent after success. It must succeed before the host reports “Saved”.
`release` always frees resources but is not a success notification. Backend errors
are terminal. A failed create/write/finish may leave a partial new file; the host
owns recovery/removal. Existing files are never erased or overwritten.

## Audio example (C / Objective-C)

```c
wam_audio_encoder_config_t config = {sizeof(config), 48000, 1, 0, 0};
wam_audio_encoder_t encoder = NULL;
wam_error_t error = {0};
if (wam_audio_encoder_create(&config, "/absolute/new-recording.m4a",
                             &encoder, &error) != WAM_OK) {
    // Surface error.name and error.detail; do not announce recording started.
    return;
}
wam_encoder_info_t info = {0};
info.struct_size = sizeof(info);
wam_audio_encoder_copy_info(encoder, &info); // hardware_accelerated == 0
// On the same worker, for each bounded PCM block:
// status = wam_audio_encoder_write(encoder, samples, frame_count, &error);
// Stop feeding blocks on failure; retain the error before cleanup.
wam_status_t status = wam_audio_encoder_finish(encoder, &error);
wam_audio_encoder_release(encoder);
// Announce completion only when status == WAM_OK and all writes succeeded.
```

Swift consumers `import WAMKit`; the companion header is part of the framework
module. The C API imports directly, including `wam_encoder_info_t` and both
create functions. Keep synchronous work off MainActor and serialize access in
the host; the SDK does not supply a Swift concurrency wrapper.

## Build and verification

[Recorded M3 Max validation](ENCODING_VALIDATION.md): six WAMKit tests pass,
including strict hardware round trips; both encoding paths pass ASan/UBSan.

Use the existing WAMKit-only build documented in [README.md](README.md). Enable
`WAMKIT_REQUIRE_HARDWARE_ENCODING=ON` for hardware acceptance runs, then build
`wamkit_encoding_test` and run:

```sh
ctest --test-dir build -R 'wamkit_(audio_encoding|video_encoding|abi|headers)$' \
  --output-on-failure
```

The video test creates real hardware H.264 and HEVC sessions, encodes synthetic
NV12 frames, decodes the actual output with VideoToolbox, and checks codec,
frame count, exact PTS, and changing luma values. No microphone, camera, screen,
or speaker access is needed. The audio test writes non-packet-aligned blocks,
finishes M4A files, decodes via AVAudioFile, and checks duration, sample rate,
channel count, RMS, and channel-specific tones for all four supported audio
formats. It also covers explicit hardware refusal, duplicate-file protection,
invalid input, finish behavior, capacity, and admission recovery.

Without the require-hardware option, unavailable video encoding returns CTest
skip code 77. A skipped hardware test is not hardware proof. Run outside a
restricted sandbox that cannot contact macOS media services. The strict mode
turns an unavailable encoder into a failure.

Existing playback ABI layouts and version 1 remain unchanged. The new header and
nine exports are additive. The ABI test still requires exact export-list equality;
C11, Objective-C and Swift imports exercise the new surface. No frozen playback
source or audio-test contract is modified.

## Configurable audio files and the recorder

`wam_audio_encoder_create_file` adds `wam_audio_file_config_t` without changing
`wam_audio_encoder_config_t`. Choose `WAM_AUDIO_FLOAT32` or `WAM_AUDIO_PCM16` for
CAF output, `WAM_AUDIO_ALAC` for 16-bit Apple Lossless/M4A, or `WAM_AUDIO_AAC` for
AAC/M4A. AAC supports an explicit total bitrate (32–320 kb/s); zero keeps the
Apple default. All of these audio paths report `hardware_accelerated=0`.
Float32 CAF preserves finite peaks outside −1…1; other formats keep the bounded
input contract. PCM CAF avoids WAV's 4 GB limit. Lossless refers to the selected
16-bit representation for ALAC, not preservation of arbitrary Float32 samples.

The [menu bar recorder](../../examples/WAMRecorder/README.md) supplies capture,
per-source resampling, peak handling, source configuration, and checkpoints.
The [audio-energy benchmark](../../benchmarks/audio-energy/README.md) compares
identical mono microphone + stereo system lanes at 48 kHz. It records the kernel's
process-energy estimate separately from whole-system battery telemetry.
