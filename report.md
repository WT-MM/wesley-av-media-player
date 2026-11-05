Video/container admission report — fix-video

Result: six previously refused specimens now play natively, each with 5/5 seeks. All eight controls remain native with 5/5 seeks. No native->fallback verdicts. Three video/container fixes expose audio blockers; six contradictory video configurations remain refused at open.

Changes committed on this branch: 52b4829 (shared AVC records and reorder bounds), 52cfe11 (Matroska display aspect and video Cue indexing). No push, PR, other-checkout changes, frozen-file changes, or AAC/audio timing changes. Baseline source was b257dff146e971bf708756fc4e880a94fcdb3681. Probed candidate binary SHA-256: 759b5dab3c08ea847aed2fd802206ebb78faf15ea365d47316ea64c554225a63.

The initial absent-VUI diagnosis did not match these files. The shared parser already implements E.2.1 and Table A-1, including level 1b and the constraint_set3 intra-profile arm. FFmpeg trace_headers and direct calls to the shared inspector located different failures. Added synthesized table cases for Baseline/Main/Extended level 1b, level 1.1, level 4.0 1080p, level 5.1 UHD and small pictures (16-frame ceiling), and High intra. HEVC already reads the mandatory sub-layer ordering fields, including the highest-layer inference for omitted lower-layer values. No HEVC parser change was needed. Removed decoder clamping of inferred depths: both inferred and declared bounds must fit the configured surface budget at open.

Root causes and disposition:
- u007/u014/u043/u058/u083: avcC reserved padding was zero, while the defined four-byte NAL-length field and SPS count were valid. The shared inspector now masks the defined fields and proves the same SPS/PPS facts regardless of padding. These SPSs explicitly declare reorder depth 1.
- u082: byte-identical SPS/PPS IDs were repeated. Accept only byte-identical repeated definitions; changed bytes under the same ID still fail, even if the summarized geometry agrees. Explicit reorder depth 2.
- u078: ffprobe identifies MPEG-TS despite its .mp4 suffix. Its synthesized avcC repeats parameter-set IDs. The shared repeated-definition rule fixes that video refusal. The file then fails at open because its audio PES does not divide into whole access units; the alternate libavformat path reports LibavformatAudioTimingUnproven: aac. Left for the parallel AAC/audio work.
- u033/u048/u075: level_idc 30 (MaxDpbMbs 8100), but picture sizes are 2560x1440 (14400 macroblocks), 1920x1080 and 1920x1080 (8160 macroblocks each). MaxDpbFrames is zero, yet each SPS requires one reference/buffering frame. They explicitly declare reorder zero; absent VUI is not the issue. Keep fail-closed rather than invent a higher level or delete the DPB consistency proof. u075 fails in libavformat's shared codec inspection.
- u062/u066/u085: optional avcC extension says chroma_format 0, but each SPS says 1 (4:2:0). The shared inspector rejects that contradiction. Keep fail-closed; the native decoder's generic reorder error obscures this cause. These SPSs explicitly declare reorder zero.
- u092: Cluster 4340 (zero-based) has timestamp 7537572 ms after 7537620 ms: a 48 ms regression. Encoded offsets are ordered. Cluster bases are not the video seek index; signed Block offsets retain exact packet times. For video, retain the validated strictly ordered Cue index and encoded-offset checks, permitting unordered Cluster bases. Audio-only Cluster binary search retains its monotonicity requirement. After this fix, direct demux preparation succeeds in 799 ms with 2284 Cues. Initial generation planning fails after 11504 ms with “audio access unit for seek target was not found”: 48 kHz AAC starts at 20 ms (nearest grid ordinal 1), while the existing zero-based planner requests ordinal 0. The GUI hits its startup timeout first (about 10.4 seconds), so seekprobe prints fallback@open with an empty failure field; stderr says “Native playback did not start in time; using compatibility playback.” This remaining audio-origin issue is left for the parallel run.
- u003: selected video track 1 was initially refused: coded 1920x1040 versus pixel display size 1924x1040. Its AVC record is valid (reorder 2). Derive exact SAR 481:480 from container dimensions, carry it in the existing descriptor, and attach it to CoreMedia; the existing native layer presenter consumes exact rational geometry. Physical-unit/aspect-ratio-only display metadata remains refused. Afterward, track 2 A_EAC3 is refused by the audio timing gate: first syncframe parses successfully as 48000 Hz, 6 channels, 1536 samples; CodecPrivate and SeekPreRoll are absent, and CodecDelay is absent/zero rather than the required 256 frames. Matroska already maps E-AC-3. Adding a libavformat codec mapping alone cannot prove its timing; left for the parallel audio work.

Regression coverage: synthesized AVC inference table; zero reserved padding preserves every fact; identical SPS/PPS repetition and conflicting-ID negatives; under-level DPB and contradictory extension negatives; inferred bounds refused above decoder budget and accepted within it; Matroska pixel display size derives reduced SAR; CoreMedia receives SAR exactly; regressing video Cluster bases still produce strictly ordered Cues. No specimen bytes or excerpts are committed.

Validation: requested Release/Ninja native build completed; dev fallback dylib staged with mode 644. Final ctest --test-dir build -LE benchmark --output-on-failure -j4: 136 passed, zero failed, zero skipped, 49.94 seconds. WAM_TEST_BACKGROUND=1, WAM_TEST_MUTED=1 and QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM=1 were set. An earlier offscreen run had a transient caption_service failure, a production wiring crash caused by the offscreen backend, and three GL skips; the unchanged suite passed completely with the normal macOS backend. Logs are /private/tmp/wam-video-ctest.log and /private/tmp/wam-video-ctest-final.log. Initial sandbox AudioToolbox fixture encoding failed; the authorized unsandboxed build succeeded.

All real-file probes use the supplied seekprobe.py, sequentially, muted/background, with output under /private/tmp/wam-probe-video. ffprobe -v trace records, trace_headers diagnostics and private inspector tools are retained there. The eight controls were requested after-only. No full-length playback or acoustic-output claim is made from this 15-second-per-file harness.

Before — exact seekprobe verdicts:

```text
u003.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="selected AVC/HEVC/AV1/VP9/VP8/MPEG-4 Part 2 track was not admitted (CodecConfiguration); libavformat: LibavformatAudioTimingUnproven: unmapped codec"
u007.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u014.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u033.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u043.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u048.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u058.m4v fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u062.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u066.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u075.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="LibavformatVideoConfigurationNotAdmitted"
u078.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="synthesized avcC was refused by the shared codec inspector: ParameterSetMismatch (CodecConfiguration); libavformat: LibavformatAudioTimingUnproven: aac"
u082.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u083.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u085.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u092.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=SourceOpen error="Cluster directory is not finite and monotonic (InvalidTimeline)"
```

After — exact seekprobe verdicts for the same specimens:

```text
u003.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="AudioCodecConfigurationRefused; candidates: [track 2 (A_EAC3): AudioCodecConfigurationRefused] (CodecConfiguration); libavformat: LibavformatAudioTimingUnproven: unmapped codec"
u007.mp4 native seeks=5/5 open_to_picture_ms=371 failure=
u014.mp4 native seeks=5/5 open_to_picture_ms=343 failure=
u033.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u043.mp4 native seeks=5/5 open_to_picture_ms=344 failure=
u048.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u058.m4v native seeks=5/5 open_to_picture_ms=351 failure=
u062.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u066.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u075.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="LibavformatVideoConfigurationNotAdmitted"
u078.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Startup class=UnsupportedSource error="mpeg-ts audio PES does not divide into whole access units; libavformat: LibavformatAudioTimingUnproven: aac"
u082.mp4 native seeks=5/5 open_to_picture_ms=351 failure=
u083.mp4 native seeks=5/5 open_to_picture_ms=313 failure=
u085.mp4 fallback@open seeks=0/0 open_to_picture_ms=-1 failure=WAM: native failure stage=open reason=Protocol class=ConsumerConfiguration error="video configure refused: could not derive a bounded presentation-reorder depth from the codec SPS"
u092.mkv fallback@open seeks=0/0 open_to_picture_ms=-1 failure=
```

Controls — exact after-only seekprobe verdicts:

```text
u004.mp4 native seeks=5/5 open_to_picture_ms=204 failure=
u005.mp4 native seeks=5/5 open_to_picture_ms=345 failure=
u009.mp4 native seeks=5/5 open_to_picture_ms=248 failure=
u013.mp4 native seeks=5/5 open_to_picture_ms=255 failure=
u037.mp4 native seeks=5/5 open_to_picture_ms=281 failure=
u071.mkv native seeks=5/5 open_to_picture_ms=993 failure=
u079.mp4 native seeks=5/5 open_to_picture_ms=348 failure=
u006.mp4 native seeks=5/5 open_to_picture_ms=348 failure=
```

Remaining work: audio timing/configuration for u003, u078 and u092 belongs to the parallel run. u033/u048/u075 and u062/u066/u085 require a separately justified policy for contradictory codec metadata; this run does not guess corrected levels/chroma or remove those checks. The native surface budget is unchanged, so absent-VUI streams whose inferred bound exceeds it now refuse at open instead of being clamped.
