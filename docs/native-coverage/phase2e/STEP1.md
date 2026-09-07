# Demux default qualification

The maintainer's phase-2e ruling removes the capture prerequisite. No visual capture was attempted. The locked display is an environmental condition, not a code regression.

The macOS source defaults are demux ON and codec OFF. The shared runtime and libavformat adapter build independently of software-codec admission. Existing video-only and qualified Opus-only routes are enabled; the final mixed shape whitelist is described in MIXED_AV.md.

The first ON/OFF build passed 104/104 CTests and the prescribed quiet six-second corpus reached 84/97, with zero regressions against 78/97. The final candidate is measured separately in the main report. The default test executes the real CMake option block and fails with the original defaults; byte-identical restoration passes.

Full six-file RustDesk hardware decode proves 49,832/49,832 exact PTS and durations with EOS. The full GUI campaign reports 49,827 drawn, five late and zero superseded frames. Every running video-only clock is 1.0000. The strict requirement that all 49,832 frames be drawn is therefore not met, even though all frames are accounted for and no native failure occurred. No decoder PTS/duration claim is inferred from the GUI counters.

A scratch copy of the packaged closure is audited separately from the development app. The native three-library closure is lazy, relocatable and built for 13.3. The complete locally supplied Qt/libvpx bundle has a 26.0 floor, so the clean-machine 13.3 release gate remains unpassed. No installed app was modified or launched.

See corpus-step1-summary.json, rustdesk-decode.json, rustdesk-playback.json and stage-revert-proof.json; final corpus and bundle receipts are linked from ../phase2/REPORT.md.
