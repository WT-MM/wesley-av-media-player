# Verification

Final shipped configuration: AVFORMAT ON, AVCODEC OFF. The final complete suite passed **122/124** in 399.06 seconds. The packaging fixture reached its 120-second timeout, and the Matroska test reached its 10-second timeout. Both unchanged isolated reruns passed (54.58 and 3.36 seconds). **All 124 tests pass across the full suite and isolated reruns.** No timeout or expectation was relaxed. [Final full suite](ctest-shipped-registry-final.log), [isolated reruns](ctest-registry-isolated.log). The preceding candidate before the shutdown lifetime fix also had a clean [122/122 full run](ctest-shipped-range-guard.log).

The initial codec-ON suite ran 149 tests. A missing excluded benchmark executable and missing WAMKit cancellation fixture were clone setup issues; the missing fallback bundle broke the wiring test. Those were repaired for shipped verification. The DTS 5.1 timeout passed unchanged in isolation. The fixture generator was copied into campaign scratch with its scratch root redirected away from the sibling campaign, then wrote only this clone's allowed `test-media/wamkit`. The benchmark target was explicitly built. No test expectation was weakened.

Every temporary source mutation in the following receipts was restored byte-identically. CTest uses rc=8 for an expected test failure; standalone source/probe checks use rc=1.

| Behavior | Reverted → restored | Receipt |
| --- | --- | --- |
| H.264 hardware format parser | parser and real 444 decode fail → pass | [initial](revert-proofs/results.json) |
| Exact ambient admission | source contract test fails → passes | [initial](revert-proofs/results.json) |
| CoreMedia payload/format publication and named DV refusal | source test + 444 source probe fail → pass | [initial](revert-proofs/results.json) |
| Pinned 444 output and decoded ambient retention | 444 and HLG production decoder fixtures fail → pass | [initial](revert-proofs/results.json) |
| Automatic display dynamic range | host property test fails → passes | [initial](revert-proofs/results.json) |
| Scene-graph 444 refusal | consumer test fails → passes | [initial](revert-proofs/results.json) |
| Narrow limited-range/SDR qualification tuples | source negative tests fail → pass | [extra](extra-revert-proofs/results.json) |
| Full-range fact from CoreMedia and Matroska | both source tests fail → pass | [extra](extra-revert-proofs/results.json) |
| Named CoreMedia edit refusal | bounded production-converter probe 1 → 0 | [extra](extra-revert-proofs/results.json) |
| Existing DTS core-plus-extension boundary | packet test fails → passes | [extra](extra-revert-proofs/results.json) |
| Matroska Hi10P / 422 with codec stage OFF | both source probes 1 → 0 | [shipped](shipped-revert-proofs/results.json) |
| Hardware-first 444 ladder and unavailable-hardware refusal | real fixture test fails → passes | [shipped](shipped-revert-proofs/results.json) |
| Unspecified Matroska range inheritance and coded-full 444 contradiction | Matroska test fails → passes | [range guard](range-inheritance-revert/results.json) |
| Audio/video registry lifetime through global teardown | both production-registry exit tests fail → pass | [registry](registry-revert-proofs/results.json) |

The first audio refusal probe used an unrepresentable exact ceiling and failed at configuration in both versions; it is retained as invalid evidence and superseded by the bounded probe that reaches the edited input/output timing. The provisional software HDR predicate also has a passing revert receipt, but that admission was subsequently removed because its metadata transport proof was incomplete. Neither superseded receipt is counted as a shipped behavior proof.

Two additional process-exit tests reproduce access after ordinary global destruction; see [SHUTDOWN.md](SHUTDOWN.md).

Three new retained fixture tests each submit and receive 100 frames through the production hardware decoder. The HLG test requires the exact ambient payload on all 100 output surfaces. The 444 cases also prove the decode plan selects Apple hardware and refuses when that hardware is unavailable. Parser tests reject unqualified 444 ten-bit/separate-plane cases; source tests reject nearby ambient payloads, Dolby Vision, full-range 444/ambient and HDR 444. Derived surface assertions preserve the ten-surface/384 MiB ceilings.

Only the scoped amendment-26 additions touch a frozen file. [Frozen SHA-256 inventory](frozen-invariants.json) and [exact applied diff](amendment26-applied.md). No commit, staging, stash, reset or checkout was performed.
