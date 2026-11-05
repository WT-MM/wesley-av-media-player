AAC timeline and seek report — branch `fix-audio`

Committed `91b7dcf` (AAC ordinal timeline, priming, configuration and tests) and `0403d8b` (audio-aware seek ceiling and tests). No push or PR. Video configuration, the Matroska cluster index, and all frozen files are unchanged.

Final result: **17 of 24 problem specimens are native; all eight native controls remain native. Every native file completes 5/5 seek actions. No specimen switches engines mid-playback.** Seven files refuse at open for the reasons below. The full requested non-benchmark CTest suite passes: **136/136 passed, zero failures, zero skips**, in 50.99 s.

What changed and why:

- u011, u035, u076, u024, u081, u087, u026, u031, u044, u073: replaced the one-tick AAC projection with one shared, exact-rational ordinal-grid proof. The inclusive bound is **256 samples**, one quarter of a 1024-sample AAC-LC access unit: at most 5.805 ms at 44.1 kHz or 5.333 ms at 48 kHz. This covers the measured maximum residual of 152 samples without accumulating drift. Every packet is checked against its original origin plus ordinal, not the previous timestamp or an independently rounded packet number. AVFoundation scans the entire audio sample table at open; libavformat uses its full packet scan. Encoded units retain their natural 1024-sample extent, including overstated stts durations at exact-grid timestamps. Final trim is retained separately in the exact publication ceiling. Edits and priming are applied separately from projection.
- u032, u054, u088: AVAssetReader can omit required priming packets even though its sample cursor exposes them. In the inspected u032 origin witness, the reader starts at media frame 4096 while CoreMedia reports a 2112-frame edit. A bounded reader-origin witness now rejects that representation inside source admission, including nonzero initial targets. The native ladder then uses libavformat's exact demux origin and skip-sample evidence, at the actual 44.1 kHz rate. This is native demux routing, not libmpv fallback.
- u012: the baseline's 85% seek to 65.328125 s succeeded. The later +10 s skip requested **76.859375 s**, beyond CoreMedia's audio end `55313608/720000` (about 76.824456 s). The public seek ceiling previously considered only video/source duration. It now bounds targets by both selected tracks and accounts for accurate seeks rounding upward to a whole audio frame. The dispatcher timeline proof remains strict.
- u060, u030: the measured cumulative residuals (-10331 and -1104 samples) exceed the bounded-jitter model. Both now refuse at **open** with `AacPacketTimelineDiscontinuity`. No synthetic silence or overlap trimming is guessed, and neither starts native only to switch engines on a seek.
- u002, u018: their five-byte ASC is AAC-LC with the backward-compatible sync extension explicitly stating **SBR absent**. The parser already accepted it; the custom Matroska source's zero-origin timing qualification rejected their 5 ms start, and libavformat excluded this audio/container pairing. The native libavformat stage now uses the shared full-grid proof with the exact 5 ms origin and declared leading silence. The custom Matroska cluster/index implementation is untouched. Matroska's quantized packet duration is not treated as a tail trim; explicit discard padding remains authoritative.
- u045: removed the libavformat AAC path's hard-coded 48 kHz restriction. The parsed ASC supplies the actual rate and channel arrangement; origins, durations, seek ordinals and generation windows use that rate. Qualified new AAC routes seek with measured preroll. Previously qualified 48 kHz fragmented AAC and FLV retain origin decoding and their existing bit-identical PCM proof. FLV's legacy rate/channel header fields are not substituted for its AAC ASC.
- u000: AAC-LC 48 kHz 5.1 now passes audio configuration admission, using the existing native channel-layout/downmix path. The next refusal is **`LibavformatPresentationMetadataUnsupported`**. Read-only inspection found square pixels, progressive `hev1` Main 10 video and **two chapters**; the unchanged presentation gate rejects chapter-bearing files. Full u000 audio packet/decode proof is not reached because that gate runs first. This report does not claim that `hev1` itself is the remaining failure.
- u040, u041 remain refused: ffprobe identifies **HE-AAC**, with a 24 kHz core ASC and 48 kHz output. Treating these as 1024-sample LC would be incorrect. The existing native ladder does not prove doubled-rate decoder delay/tail ownership. The app still reports its generic configuration refusal; the HE-AAC classification is independent ffprobe evidence.
- Stretch cases remain unchanged: u015's Vorbis header declares unequal 256/2048-sample blocks, outside the existing fixed-block timeline proof; u036's WMA v2 has no qualified audio timing/decoder path in the existing ladder. No dependencies or frozen contracts were added.

Regression coverage includes the ±256 boundary and ±257 refusal; long ordinal grids and true discontinuities; AVFoundation duration restatement and cross-buffer continuity; synthesized open-time rejection through both source routes; exact 2048- and 2113-sample edits; 44.1 kHz, six-channel AAC and 5 ms Matroska-origin seek PCM comparisons; retained Apple PCM-oracle and fragmented/FLV bit-exact checks; and the fractional audio seek-end regression. The media-session fixture was corrected to actually give audio the longer duration its existing test describes. All media fixtures are generated in tests; no private specimen data or excerpts are committed. The existing rate and seek/session tests were rerun, and the full suite includes the frozen converter/session tests unchanged.

Commands: the requested Release CMake/Ninja build, development fallback dylib copy, and `ctest --test-dir build -LE benchmark --output-on-failure -j4`. GUI probes used the supplied `seekprobe.py`, sequentially, muted/background with isolated HOME; no windows were activated. The final executable SHA-256 is `29cfafb1af8780e5842c240ed08040c295dd2941ff3fb528b7589c0bb8c9f572`.

Exact baseline and final verdict lines for all 24 problem specimens follow. These are the harness's labels: `fallback@open` can also mean failure during preroll before its first picture.

```text
before: u011.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="audio sample does not continue the exact generation timeline"
after:  u011.mp4 native seeks=5/5 open_to_picture_ms=214 failure=

before: u035.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="audio sample does not continue the exact generation timeline"
after:  u035.mp4 native seeks=5/5 open_to_picture_ms=207 failure=

before: u076.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="audio sample does not continue the exact generation timeline"
after:  u076.mp4 native seeks=5/5 open_to_picture_ms=330 failure=

before: u024.mp4 native->fallback seeks=3/3 open_to_picture_ms=314 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"
after:  u024.mp4 native seeks=5/5 open_to_picture_ms=320 failure=

before: u081.mp4 native->fallback seeks=0/1 open_to_picture_ms=209 failure=WAM: native failure stage=commit-seek/proof reason=CommitSeek class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"
after:  u081.mp4 native seeks=5/5 open_to_picture_ms=328 failure=

before: u087.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"
after:  u087.mp4 native seeks=5/5 open_to_picture_ms=241 failure=

before: u026.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="audio sample does not continue the exact generation timeline"
after:  u026.mp4 native seeks=5/5 open_to_picture_ms=235 failure=

before: u031.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"
after:  u031.mp4 native seeks=5/5 open_to_picture_ms=371 failure=

before: u044.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"
after:  u044.mp4 native seeks=5/5 open_to_picture_ms=242 failure=

before: u073.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"
after:  u073.mp4 native seeks=5/5 open_to_picture_ms=342 failure=

before: u032.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=InvalidTimeline error="generation timeline could not be derived: audio sample rate is not integral, or the window's decode/presentation start is invalid"
after:  u032.mp4 native seeks=5/5 open_to_picture_ms=539 failure=

before: u054.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=InvalidTimeline error="generation timeline could not be derived: audio sample rate is not integral, or the window's decode/presentation start is invalid"
after:  u054.mp4 native seeks=5/5 open_to_picture_ms=863 failure=

before: u088.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=InvalidTimeline error="generation timeline could not be derived: audio sample rate is not integral, or the window's decode/presentation start is invalid"
after:  u088.mp4 native seeks=5/5 open_to_picture_ms=1009 failure=

before: u012.mp4 native->fallback seeks=3/4 open_to_picture_ms=255 failure=WAM: native failure stage=commit-seek/dispatcher-seek reason=CommitSeek class=InvalidTimeline error="seek timeline could not be derived: audio presentation start is after the audio track duration"
after:  u012.mp4 native seeks=5/5 open_to_picture_ms=193 failure=

before: u060.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=steady reason=Decode class=Consumer error="CoreMediaAudioEditExactTimelineProofMissing: input/output timing contains an edit"
after:  u060.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"

before: u030.mp4 native->fallback seeks=0/1 open_to_picture_ms=290 failure=WAM: native failure stage=commit-seek/proof reason=CommitSeek class=Consumer error="CoreMedia audio packets are not contiguous"
after:  u030.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples; libavformat: AacPacketTimelineDiscontinuity: packet residual exceeds 256 samples"

before: u002.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AudioCodecConfigurationRefused; candidates: [track 2 (A_AAC): AudioCodecConfigurationRefused] (CodecConfiguration); libavformat: LibavformatAudioTimingUnproven: aac"
after:  u002.mkv native seeks=5/5 open_to_picture_ms=959 failure=

before: u018.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AudioCodecConfigurationRefused; candidates: [track 2 (A_AAC): AudioCodecConfigurationRefused] (CodecConfiguration); libavformat: LibavformatAudioTimingUnproven: aac"
after:  u018.mkv native seeks=5/5 open_to_picture_ms=536 failure=

before: u040.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AVFoundation could not locate a bounded sync start; libavformat: LibavformatAacConfigurationUnqualified: aac"
after:  u040.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AVFoundation could not locate a bounded sync start; libavformat: LibavformatAacConfigurationUnqualified: aac"

before: u041.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AVFoundation could not locate a bounded sync start; libavformat: LibavformatAacConfigurationUnqualified: aac"
after:  u041.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AVFoundation could not locate a bounded sync start; libavformat: LibavformatAacConfigurationUnqualified: aac"

before: u045.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="LibavformatAacConfigurationUnqualified: aac"
after:  u045.mp4 native seeks=5/5 open_to_picture_ms=1843 failure=

before: u000.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="protected or unplayable media is not native-admissible; libavformat: LibavformatAudioTimingUnproven: aac"
after:  u000.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="protected or unplayable media is not native-admissible; libavformat: LibavformatPresentationMetadataUnsupported"

before: u015.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AudioCodecConfigurationRefused; candidates: [track 2 (A_VORBIS): AudioCodecConfigurationRefused] (CodecConfiguration); libavformat: LibavformatAudioTimingUnproven: vorbis"
after:  u015.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AudioCodecConfigurationRefused; candidates: [track 2 (A_VORBIS): AudioCodecConfigurationRefused] (CodecConfiguration); libavformat: LibavformatAudioTimingUnproven: vorbis"

before: u036.wmv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="LibavformatAudioTimingUnproven: wmav2"
after:  u036.wmv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="LibavformatAudioTimingUnproven: wmav2"

```

The eight controls were requested after the change only; their final verdicts are:

```text
u001.mp4 native seeks=5/5 open_to_picture_ms=271 failure=
u005.mp4 native seeks=5/5 open_to_picture_ms=602 failure=
u006.mp4 native seeks=5/5 open_to_picture_ms=634 failure=
u019.mp4 native seeks=5/5 open_to_picture_ms=486 failure=
u021.mp4 native seeks=5/5 open_to_picture_ms=502 failure=
u037.mp4 native seeks=5/5 open_to_picture_ms=515 failure=
u071.mkv native seeks=5/5 open_to_picture_ms=1084 failure=
u079.mp4 native seeks=5/5 open_to_picture_ms=500 failure=
```

Evidence: `/private/tmp/wam-probe-audio/before.txt`, `/private/tmp/wam-probe-audio/after.txt`, their per-file `before/` and `after/` telemetry directories, `/private/tmp/wam-audio-full-ctest-final.log`, and `build/libavformat-aac-timing.json`. The earlier candidate sweep is retained in `after-v1/`; the verdicts above use the final sweep.
