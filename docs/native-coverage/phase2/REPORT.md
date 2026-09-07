# Phase 2 implementation checkpoint — not release-ready

This working tree contains an opt-in native libavcodec video stage and an
isolated audio backend. It does **not** complete phase 2 acceptance. Production
audio routing, software AV1, complete no-hardware VP9 admission, resource and
allocation qualification, display color comparison, and distribution parity
remain outstanding. `WAM_ENABLE_AVCODEC_STAGE` defaults OFF; the local acceptance
build uses ON. The release workflow prepares the SDK but does not enable it.

## Dependency

FFmpeg 9.0.1 was built offline from the supplied archive, verified before
extraction against SHA-256
`cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`.
The matching source is retained in `third_party/ffmpeg-source/`; the ignored
SDK prefix is `third_party/ffmpeg-lgpl/`. Temporary objects were removed after
installation. Build time was 36 seconds; SDK size approximately 6.2 MiB.

The full configure argv, compiler/SDK/OS versions, generated feature definitions,
license inventory, license text and output hashes are retained beside this
report. The reproducible entry point is `scripts/build_ffmpeg_lgpl.sh`.
The build disables GPL/nonfree/version3/autodetection, all programs, encoders,
muxers, devices, filters, networking, hardware adapters and libavformat. It
builds only shared libavcodec 63.1.101 and libavutil 61.1.101, arm64, macOS 13.3.
Plane/interleave conversion needs neither swscale nor swresample.

The library names carry `-wamnative` to prevent file-name collisions. This does
**not** prove the original plan's single playback FFmpeg closure requirement:
lazy mpv still has its own FFmpeg closure. Coexistence and license review are
release blockers, not resolved by the suffix. The opt-in app currently links the native libraries
eagerly; the dependency plan's lazy-stage requirement is also outstanding.
No libavformat is wired.

`bundle_macos_lib.zsh` copies native notices and checks the native libraries;
`fix_qt_qml_deploy_macos.zsh` supplies the pinned dylibs to the existing closure
repair/signing process. CI caches the offline SDK by source/build script hash,
architecture and deployment target. `--verify-runtime` checks ABI, license,
configuration and six required decoders; it explicitly reports audio routing
as disabled. Missing-library/replacement/known-answer matrices remain needed.

## Admission and measured platform correction

`src/media/native_decode_plan.hpp::kNativeDecodeLadder` states the ordering
once. `native_video_decode_plan.hpp` supplies stream predicates; VideoDecodeLane
records unsuccessful Apple configuration before selecting the next stage.
Successful stage selection emits a route diagnostic, not native failure.

The M3 Max hardware probe decoded all 50 frames of both Hi10P and 10-bit H.264
4:2:2. Those routes therefore remain VideoToolbox hardware. Apple software
created sessions but returned -8969 while decoding both; MPEG-4 ASP refused
hardware creation (-12906) and software creation (-8969). AV1 and VP9 hardware
capability queries both returned true after supplemental registration.

The H.264 parser separates valid profile facts from its old Apple envelope.
The stage accepts 8/10-bit 4:2:0 and the already-ratified 4:2:2 presentation
surface family. 4:4:4, alpha and higher depth remain named refusals. No new
frozen presentation formats were introduced. The H.264 VideoToolbox pixel
request now matches 4:2:2 output instead of treating it as 4:2:0.

## Adapter proofs and limitations

Video uses one worker, four owned/padded packet slots, 32 packet-provenance
records, one pending frame mailbox and six prewarmed presentation surfaces.
FFmpeg has one decoder thread; at most 16 workers exist process-wide. The
software picture tier is limited to 1920×1080 pixels. These caps do not yet
constitute a measured bound on every codec's private reference allocation.
Exact timestamp conversion uses checked integer reduction; no AV_TIME_BASE
floating conversion is used. Reordering, explicit drain, output backpressure,
caller packet reuse and generation retirement have deterministic tests.

The standalone audio backend copies decoded native-rate samples to float
interleaved slabs without resampling. Tests compare every output sample,
including reset/redecode, and drive an 8193-frame six-channel planar frame
through 4096/4096/1 pieces. DTS uses 2e-6 absolute float tolerance and zero-frame
alignment; TrueHD/MLP are bit-exact against the fixture decoder. DTS's 256-frame
container tail trim is intentionally absent from the elementary-stream
reference: this tests decoder output, **not** container publication trimming.

Production DTS/TrueHD/MLP carriage is not enabled. No codec enum appends were
made; IDs are not claimed as landed merely because an isolated decoder works.
DTS-HD MA requires a genuine retained specimen. Optional WMA/RealAudio/Theora
decoders are compiled but have no admitted mapping. FFmpeg 9.0.1's built-in AV1
decoder requires a hardware accelerator; software AV1 needs a separately pinned
software decoder such as dav1d. No such source was supplied, and no downloads
were attempted. Existing hardware-only VP9 source/consumer gates still need
unification with the plan before a no-hardware route can be claimed.

## Frozen proposals still required

1. **PROPOSAL 4, packet storage release:** replace the AudioToolbox-specific
   requirement that `finalInputReleased` means a second input-proc invocation
   with proof of actual end of borrowing. Owned packet copies satisfy the
   latter, not the current frozen wording. Preserve all Apple test behavior.
2. **PROPOSALS 2/4, audio admission:** allow neutral extradata without an Apple
   format tag, select timing adjustments by decoder implementation, and obtain
   actual layout from the first decoded frame before downmix publication.
   Libavcodec uses manual skip handling; WAM must assign every container/codec
   trim once. TrueHD's 40-sample units need exact ordinal timing despite coarse
   Matroska timestamps, plus major-sync seek/preroll proof.
3. **PROPOSAL 6:** ratify and measure private software-reference/thread budgets
   in addition to the existing presentation budget. Profile third-party
   allocations/synchronization and conversion cost; bounded queue counts alone
   are insufficient.

SESSION_HANDOFF amendment 18 records the maintainer-ratified PROPOSAL 7 policy
qualification. No frozen code or frozen tests were changed. Existing
ProRes4444 already follows AdpcmMs under amendment 15 and must keep its value
when future codec identities are appended.

## Acceptance receipts

Final build/test, mutation, live-playback, corpus and packaging results are
recorded below as they complete. Surface pixel comparisons validate decoded
sample layout; they do not substitute for display-route screen grabs. Short
or process-only measurements do not establish whole-system energy parity.

### Measured video trials

1280×720 at 25 fps, 12 s, video only; 14 s process sampling includes startup
and EOS idle time. Every row drew/submitted 300/300 frames, discarded 0 late frames,
reported clock rate 1.0000 and exited normally without native failure.

| Specimen | Stage | Process CPU, one core | Process energy | Peak footprint |
| --- | --- | ---: | ---: | ---: |
| H.264 8-bit baseline, before | VideoToolbox hardware | 5.75% | 1.019 J | 442.3 MiB |
| ASP AVI → MKV, B-frames | libavcodec | 13.37% | 1.581 J | 474.4 MiB |
| Hi10P MKV | VideoToolbox hardware | 6.77% | 1.279 J | 441.9 MiB |
| H.264 4:2:2 10-bit MKV | VideoToolbox hardware | 7.04% | 1.339 J | 442.1 MiB |
| H.264 baseline, after | VideoToolbox hardware | 6.61% | 1.317 J | 442.4 MiB |

ASP was approximately 2.16× the mean baseline process CPU and 1.35× its
process energy, with 32 MiB higher peak footprint. Single trials and baseline
variation prohibit a claim of steady-state or whole-system energy parity.
The original raw CPU field was Mach ticks mislabeled as nanoseconds; the
retained JSON preserves that raw value and applies the independently checked
125/3 timebase factor. The maintained sampler now performs that conversion.

Scripted forward/backward/near-EOF seeks on ASP/Hi10P/4:2:2 committed at
7 s, 1 s and 11.390625 s (the existing public target quantization of requested
11.4 s), each under new generations. All returned to clock 1.0000 with no
late frames or native failure. These are video-only proofs; sample-exact
audio seek acceptance remains unfulfilled.

### Tests

`cmake --build build --parallel` passed. The 92-test CTest campaign passed
after isolated retries of three environmental SIGKILLs (the existing
Matroska benchmark and two fixture integrations). All 10 new fixture/decoder
tests passed in the first full run. The existing bundle transaction test
passed in 53.53 s. The three retries passed in 7.93 s total.

Twelve temporary production mutations were detected: ladder ordering, owned
packet bytes, frame timestamp provenance, generation rejection, EOS send,
retained-frame backpressure, planar samples, packet release, audio slab offset,
production video-lane selection, P010 bit placement and software SPS admission.
Each source was restored byte-for-byte with SHA-256 receipts. These are
behavioral mutation proofs, not a whole-patch rollback campaign, and not a
claim that every new branch has a revert proof. Color metadata,
capability/session-refusal branches, invalid-input/resource edges, runtime and
packaging still need dedicated negative-path tests.

### Packaging checkpoint

The scratch bundle transaction succeeded and audited 223 Mach-O files;
`codesign --verify --deep --strict` passed. Native codec/util libraries are
inside Frameworks with bundle-relative loads, and native notices are in
Resources/native-ffmpeg. The original installed/build applications were not
repaired or replaced.

This required local Qt deployment repairs: remove a stale unmanifested mpv
copy from the scratch app, use Apple's tools instead of Anaconda's
install_name_tool, supply missing installed Qt frameworks, repair their load
commands, and make copied headers writable before xattr clearing/signing.
These manual scratch steps are recorded in the Qt repair receipts. They do
not prove the unchanged CI deployment will reproduce a complete package.
The bundle's minimum OS audit reports **macOS 26.0** because of existing
Homebrew dependencies. The two new FFmpeg libraries themselves target 13.3.

The built app's runtime verification passed. A relocated runtime attempt
using the offscreen platform failed before runtime verification because the
package carries only the cocoa platform plugin; no relocated GUI playback
was launched. Clean-machine replacement and relocated playback remain open.

### Corpus

The required quiet six-second 97-file campaign completed: **78/97 native,
zero regressions versus the 78/97 phase-0b baseline**. All launches used the
build app, unique run IDs, asset/candidate hashes, scratch HOME, background,
muted mode and the specified geometry. Results and chosen-stage diagnostics
are retained in corpus-results.json/tsv and corpus-routes.json. The three new
video specimens are reported separately above. Historical refusals remain
refusals; this campaign does not prove successful mpv fallback playback.

### Remaining acceptance

Phase 2 is incomplete. Do not interpret the opt-in flag or these passing
checks as permission to ship. Outstanding work includes production audio
carriage/routing and trim/seek contracts; software AV1 and no-hardware VP9;
DTS-HD MA and actual multichannel samples; decoder-private resource and
allocation measurement; full rollback proofs for each behavior; display-route
color/range grabs; exact audio/video seek alignment; multiwindow/cancellation
stress; lazy loading and a coherent playback FFmpeg closure; complete runtime
replacement checks; automated clean-machine packaging and minimum-OS proof;
and the remaining license/source-distribution presentation required by the
dependency plan.

The independent `release.yml` every-Mach-O external dependency scan also
passed on the signed scratch bundle; see release-gate.txt.
