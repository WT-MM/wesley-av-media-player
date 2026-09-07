# Software presentation-drain defect

The deterministic failure is surface-registry insertion contention.
NativeSurfaceBudget's fixed process table takes a single nonblocking insertion
reservation. A different worker holding that reservation can make FrameLease
construction return empty even when all count/byte ceilings have headroom.
The software adapter converted that transient refusal into
`AvcodecPresentationSurfaceBudgetExceeded`; the consumer reported the generic
`video decoder presentation drain failed`.

The adapter now returns Backpressure while retaining the decoder's AVFrame.
The existing owner wake retries output; no packet, PTS or duration is changed,
no queue is enlarged, and no lock, allocation or busy loop is added. The
presentation ceilings remain ten surfaces / 384 MiB per session.

The deterministic test holds the insertion reservation until the worker's
rejection counter advances, releases it, and requires exactly the original
frame at PTS 0 and duration 40/1000. A second trial cancels while the reservation
is held and requires zero retained surfaces/bytes after closing. The original
adapter fails by name; fixed and byte-identically restored adapters pass.
See contention-revert-proof.json.

The hardware control and two software sixteen-window runs passed with zero native presentation-drain failures and window counts 16 → 16 → 0. The software seek/close storm recorded 19 committed, 19 ready and 19 drawn previews. Eighteen preview-budget failures were separately reported; they are not presentation-drain failures and are not claimed fixed. The allocator-enabled rerun unloaded both native decoder images after close. See multiwindow-software.json, multiwindow-hardware.json and multiwindow-reservation.json.
