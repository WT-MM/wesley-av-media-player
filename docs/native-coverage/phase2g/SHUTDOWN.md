# Deferred retirement during process exit

The earlier corpus run on candidate `05ccfb34…` drew native frames but three launches aborted during shutdown. Their isolated reruns passed; the original failures remain retained. Two PID-matched crash reports locate `mutex lock failed: Invalid argument` in audio `releaseClaim` and video `releaseConsumerClaim`, reached through deferred `NativeMediaDispatcher` retirement after ordinary global teardown. [Audio/video reports](WAM-2026-09-07-204802.ips), [second report](WAM-2026-09-07-205005.ips).

The audio and video mutexes and fixed quarantine arrays now use in-place, trivially destructible process-lifetime storage. Construction allocates nothing; slot counts, worker limits and media reservations are unchanged. Normal explicit retirement still releases entries. Deferred workers can safely reach the bounded registries during global teardown; the GUI thread does not wait for them.

Two regression tests register an exit callback before ordinary global constructors. The callback queries each production registry after ordinary global destruction. Both tests abort with the original production registries and pass with the fix. Both production files were restored byte-identically after the temporary revert, and both builds passed. [Revert receipts and logs](registry-revert-proofs/results.json).

Final corpus exit results are recorded in [CORPUS.md](CORPUS.md).
