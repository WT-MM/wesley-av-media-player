# Encoding validation — 2026-09-09

Test host: Apple M3 Max (16 CPU cores), 64 GB RAM, macOS 26.3.1 (25D771280a),
arm64, Xcode's AppleClang 21.0.0 / Swift 6.3.3 toolchain.
Base: `2640421` (WAM v0.4.33). Tests use synthetic media only.

## Build

```sh
cmake -S . -B build-encoding -G Ninja \
  -DWAM_BUILD_APP=OFF -DCMAKE_BUILD_TYPE=Release \
  -DWAM_FFMPEG_LGPL_ROOT=/path/to/provisioned/ffmpeg-lgpl \
  -DWAMKIT_BUILD_HOST=OFF -DBUILD_TESTING=ON \
  -DWAMKIT_REQUIRE_HARDWARE_ENCODING=ON
cmake --build build-encoding --target wamkit_encoding_test --parallel 8
ctest --test-dir build-encoding --output-on-failure
```

Result: **6/6 passed, 0 skipped**, final run 11.25 seconds.

| Check | Result |
| --- | --- |
| `wamkit_abi` | Exact export set, including nine additive encoding functions |
| `wamkit_headers` | C11, Objective-C, Swift module import; new types and create functions import into Swift |
| `wamkit_device_recovery` | Existing playback device-recovery regression passed |
| `wamkit_dogfooding` | Existing Qt/native ownership boundary audit passed |
| `wamkit_audio_encoding` | All four mono/stereo × 44.1/48 kHz files decode to exactly one second; channel-specific tones and RMS pass |
| `wamkit_video_encoding` | Hardware required and verified for H.264 and HEVC; 12 decoded frames each with exact PTS and expected luma |

Video checks also cover overlapping/invalid/overflowing times, unsupported
configuration, explicit HDR rejection, and successful use after validation
errors. Audio checks include software identity, strict hardware refusal without
creating a file, no overwrite, NaN/oversized input, successful finish twice,
write-after-finish rejection, four-handle admission, and capacity reclamation.

The same final encoding implementation and test source were compiled standalone
with `-fsanitize=address,undefined -O1 -g -fobjc-arc -std=c++20`, linked against
Foundation, AVFoundation, CoreMedia, CoreVideo, VideoToolbox and AudioToolbox.
Both `audio` and `video --require-hardware` runs passed without sanitizer reports.

A separate AudioFormatGetProperty installed-encoder probe returned exactly one
AAC encoder: `aenc` / `aac ` / `appl` (software). Hardware video evidence comes
from per-session VideoToolbox property verification and actual round trips, not
from the Mac model name or a compile-time flag.

## Limits of this evidence

This is correctness validation of the WAMKit-only configuration on one M3 Max.
It does not establish encoding throughput, energy savings, long-running capture,
A/V muxing, every resolution/bitrate, or support on other Macs. No microphone,
GUI recorder, notarization, or full Qt application campaign was run.

The existing locally provisioned Homebrew libvpx dependency was built for macOS
26.0; the linker warns that it exceeds the framework's 13.3 deployment floor.
This is a pre-existing decoder packaging limitation in this development setup,
not evidence of macOS 13.3 distribution compatibility. The new encoding code
adds only system-framework dependencies. WAMKit's packaging audit passed with
five Mach-O images and no Qt, mpv, or external non-system runtime paths.

Frozen playback source and audio-test files are unchanged. Context was obtained
from the session-stamped commits, checked-in WAMKit design/report, and local
SESSION_HANDOFF.md; the private Claude web transcript was not accessible.
