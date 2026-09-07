# Verification and revert proofs

No test or production edit touches the frozen files. `frozen-invariants.json` retains before/after SHA-256 values for all four frozen paths. The session deadline change is in `native_media_session`, not the frozen `native_audio_session` tests or public media source/playback contract.

| Behavior | Fixed / reverted / restored | Receipt |
| --- | --- | --- |
| Software color admission | 0 / 1 / 0 | `color-revert-proof.json` |
| Matroska container full-range refusal | 0 / 1 / 0 | `matroska-color-revert-proof.json` |
| Libavformat container full-range refusal | 0 / 1 / 0 | `libavformat-color-revert-proof.json` |
| Mixed video deadline independent of audio callback | 0 / 1 / 0 | `deadline-revert-proof.json` |
| Native loader permits cached fallback | 0 / 1 / 0 | `coexistence-revert-proof.json` |
| Fallback loader preserves active native leases | 0 / 1 / 0 | `coexistence-revert-proof.json` |
| Existing DTS core guard rejects trailing HD extension | 0 / 7 / 0 | `dts-extension-revert-proof.json` |

Every temporary production mutation was restored byte-identically. The DTS row tests an existing safety boundary; it does not qualify HD-MA. A duplicate comment was removed after the deadline receipt without changing behavior. VP9 production adapter tests now traverse the production software lane, including packet output, EOS, flush and backpressure, with the qualified color predicate enabled.

Final codec-ON suite: 137/139 on the first complete run (305.10 s). The new full-range test initially returned `LibavformatProbeFailed` before color admission; independent ffprobe found the intact MPEG-4 full-range fixture and its unchanged rerun passed. The unrelated GL-output test failed two different render-wait assertions on separate runs, then passed unchanged (3.24 s). All 139 tests passed across the retained suite and reruns; this is not represented as a clean 139/139 first run. See `ctest-on-final*.txt` and `ctest-on-gl-second-rerun.txt`.

Final shipped OFF suite: 111/112 on the complete run (207.36 s); the unchanged GL-output rerun passes 1/1 (3.24 s), so all 112 tests pass across the suite and rerun. Both logs are retained as `ctest-shipped-final.txt` and `ctest-shipped-final-rerun.txt`. Generated Ninja dependency-file timeouts were handled by deleting only reported `.d` files and rerunning `cmake --build build --parallel`; recovery logs are retained. No CTest ran while this campaign was linking.
