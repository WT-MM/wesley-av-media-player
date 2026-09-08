# Diagnostic trace interpretation

Build with `-DWAM_NATIVE_BENCHMARK_TELEMETRY=ON`; runtime collection additionally requires the exact environment value `WAM_NATIVE_BENCHMARK_TELEMETRY=1`. The CMake option defaults OFF. `scripts/measure_late_frames.py` supplies the required launch identities, geometry, muted/background settings, scratch HOME and metrics path. It launches only this clone's build app. A GUI-clear preflight does not prove an idle host; process-load snapshots must also be reviewed.

`video_frame_trace` records are emitted for a late retirement and its immediately preceding successful submission in the same generation. Successful frames otherwise remain in one worker-owned context record. `consumer`, `generation` and `ordinal` identify an observation; ordinal counts frames taken by that consumer, including preroll, and is not an asset-global seek index. The unseeked requested assets have the matching presentation-order packet ordinals in the offline maps.

PTS and duration are integer value/scale pairs. Host ticks use `mach_absolute_time` and `ticks_per_second`; compare them using exact integer/rational arithmetic. Do not compare raw ticks with the ordinary playback sample's `t_mono_ns` or the benchmark event stream's `monotonic_ns`: those clocks must not be assumed to have the same epoch. The harness `ps` snapshots use Python's macOS monotonic clock; ledger comparisons convert Mach ticks to nanoseconds and retain the nearest-snapshot distance.

| Field | Meaning / limitation |
| --- | --- |
| `deadline_ticks` | Last deadline actually assigned while holding this frame; null when it retired without receiving one. |
| `decode_complete_ticks` | VideoToolbox delivery implementation entry, not a hardware-internal completion timestamp. Zero means unavailable. |
| `surface_lease_ticks` | Successful `FrameLease` acquisition timestamp; zero means unavailable. |
| `observed_ticks` | Worker trace observation at retirement/submission. |
| `enqueue_return_ticks` | Successful output submit return; null for late retirements. It is not physical scanout. |
| `draw_ticks` | Null: a discarded frame was never drawn, and the layer API does not provide per-frame physical scanout timing here. |
| `display_refresh_phase` | Display ID, CVDisplayLink reference host tick and rational period. Null if no stable snapshot is available. Compute phase as `((observed-reference)/ticks_per_second) mod (period_value/period_scale)`. |
| `fragment_boundary` | Null pending live packet provenance. Offline maps are separate evidence. |
| `since_open_request_ticks` | Age since `NativeMediaDispatcher::openLocalFile`, not the earlier GUI open-request event. |
| `since_consumer_open_ticks` | Age since consumer construction. |
| `since_seek_flush_ticks` | Legacy diagnostic age since a nonzero-target generation flush; not a landing proof. |
| `since_seek_landing_ticks`, `seek_landed_within_2s` | Age since successful commit-ready publication; zero/false before any such landing. The two-second comparison uses integer arithmetic. |
| `pool_surfaces`, `pool_rejections` | Process-wide `NativeSurfaceBudget` lease accounting and cumulative rejections, not VideoToolbox's private allocation pool. |
| `decoded_queue_depth` | Worker-owned capacity-one decoded sink depth. |
| `video_queue_depth_at_step`, `audio_queue_depth_at_step` | Compressed dispatcher lane depths at worker-step entry. They do not expose private VideoToolbox queues. |
| `worker_wait_*` | Most recently completed semaphore wait, its selected due tick and whether it timed out. A queued notification may return immediately even when the due tick is already stale. |
| `slow_wait_since_submission` | Largest observed `wait_end-due` since the preceding successful submission. This is lateness relative to due, not necessarily time blocked inside a wait; inspect begin/end and timed-out status. |

`output_path_ticks` indexes are: 0 capacity entry, 1 capacity return, 2 submit entry, 3 layer-mutex request, 4 mutex acquired, 5 sample-buffer preparation entry, 6 renderer enqueue entry, 7 enqueue return, 8 renderer metrics-load entry, 9 submit return. Zero entries are unavailable. These are elapsed intervals; they do not distinguish API blocking, page faults, or thread descheduling by themselves.

Display registration is bounded to sixteen displays and thirty-two hosts, with process-lifetime callback storage. It records the host's display at attachment and backing-property changes; same-DPI screen moves are not independently observed. The benchmark windows used fixed geometry. Snapshot validation is bounded and may return unavailable rather than retry. Final verification adds an explicit ordering fence and a concurrent coherence test; earlier candidate identities remain distinct in launch receipts.

`video_trace_health.lost_or_unavailable` reports ring rejection or producer-slot exhaustion. Any nonzero value invalidates complete attribution. Zero does not prove that an abruptly terminated process drained observations created after its last retained sample. The retained streams' aggregate late counts and recorded late retirements both total 541.

The full busy-host soak used candidate `c4eec65a9316888ccc7cc0afd04eee58edc2d5e71e57ffc5ac536c28ef26c06c`. The final snapshot-ordering candidate is `2f3d90ac75ba4e7e4f5a7a39743cead542bd1e93ca746de45248b35d9ecf8cae`. Final seven-file replays apply to the latter. No playback-policy change separates them.
