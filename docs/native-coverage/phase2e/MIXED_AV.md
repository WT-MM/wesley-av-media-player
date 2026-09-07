# Mixed libavformat qualification

The source publishes both selected tracks, uses separate bounded cursors with one raw packet lookahead each, orders delivery by exact decode time, and publishes each track's EOS once. Seek resets both cursors; video starts at its preceding RAP and audio replays from its origin. Audio preroll has bounded storage but O(target) work. Container ticks are checked against exact codec sample ordinals; timing is never reconstructed from floating-point seconds.

Admitted shapes are H.264 + 48 kHz mono/stereo AAC-LC with zero AAC packet origin in MOV/fragmented MP4 or FLV, and HEVC + 48 kHz mono/stereo constant-duration CELT Opus in Matroska. Existing Opus-only demux is retained with the same exact grid checks and the CELT qualification guard. Mixed shapes outside this set refuse before descriptor publication. Fragmented MP4 routes through libavformat because the AVFoundation probe retained 94,912 AAC frames where ffmpeg retained 97,280. Ordinary Apple decoding remains VideoToolbox / AudioToolbox.

The equal-endpoint AAC specimens have 48 video frames and 92,160 retained audio frames each: both end at 48/25 seconds, so |V−A| = 0. All video PTS/durations match independent ffprobe decode; the PCM comparison has zero-frame alignment. Seeks at 0, 1, 1/7 and endpoint−1/1000 retain exactly the baseline slice beginning at ceil(T×48000). Quiet app runs draw 48/48 with zero late/superseded frames, render 92,160 frames, and have zero clock-advanced underruns. Earlier 2-second encoder specimens retain 97,280 audio frames and have intentionally unequal stream endpoints; those tests prove original timing preservation, not endpoint equality.

The six RustDesk videos, copied without video re-encoding beside synthesized CELT Opus, prove 49,832 video PTS/durations and 95,290,656 retained samples. Each audio endpoint equals its original video endpoint exactly; every full decode and forward/backward/near-EOF PCM seek has zero alignment offset and exact retained counts. The direct libavformat probes establish these results. The first full GUI run used the ordinary Matroska route after remuxing: 973 drawn + 14 late = 987 video frames, 1,995,408 rendered samples, zero superseded and zero clock-advanced underruns. It is not represented as a full libavformat GUI proof or a zero-late result.

Still refused:

- Opus SILK/hybrid: the 32 kbit/s control has deterministic initial PCM disagreement (full-file RMS 0.0513; first-second RMS 0.3309), despite exact counts. CELT-only low-delay encoding passes. `LibavformatOpusModeUnqualified` is checked on every packet during admission and reading.
- Ogg Vorbis: variable-block geometry remains unsupported; the synthesized uniform-block stereo control has exact counts but right-channel RMS 0.08057 and maximum error 0.26386 through both libavformat and existing Matroska/Apple decoding. It remains `LibavformatAudioTimingUnproven: vorbis`.
- AVI ASP+MP3: Apple MP3's 529-frame lead/tail semantics lack an AVI-declared retained-window proof; the frozen Apple contract was not changed. `LibavformatAudioTimingUnproven: mp3`.
- FLV AAC with a positive audio origin: `LibavformatAudioTimingUnproven: aac`; only the zero-origin shape passed.
- ASF WMA: no authorized production codec identity/retained-window proof; `LibavformatAudioTimingUnproven: wmav2`.
- MPEG-PS audio: exact origin/trim is unqualified; the existing named timing refusal remains.

See mixed-proof.json, rustdesk-mixed-proof.json, rustdesk-audio-manifest.json, mixed-playback.json, ctest-mixed.txt and mixed-revert-proof.json. The regression tests fail with the original single-track source, with the fragmented-routing change reverted, and with the Opus-mode guard removed; each restoration is byte-identical.
