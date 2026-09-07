# Phase 2c proposals — not ratified or applied

The local handoff already contains amendments 22–23 from phase 3. The next
numbers are therefore 24–25, rather than reusing either of those numbers.
The current directive explicitly grants no new frozen-file amendments.
SESSION_HANDOFF.md and the frozen code/test files remain byte-identical.

## Proposal 24 — production software-audio identity and converter contract

Append `Dts`, `TrueHd`, and `Mlp` immediately after `ProRes4444` in
`src/media/native_media_source.hpp`'s `MediaCodec`. Preserve every existing
ordinal and signature. DTS core and DTS-HD MA share the decoder family;
profile-specific admission must still require its own retained specimen.
No arbitrary AVCodecID or invented AudioToolbox format tag substitutes for
these neutral identities.

The frozen converter/session implementation also needs these scoped changes:

- Select the backend and DecodePlan at configuration. Apple audio rows retain
  their existing format-tag and magic-cookie checks; libavcodec rows use raw
  extradata and a real implementation identity.
- Replace the converter's unconditional AudioMagicCookie-only configuration
  check and four-field backend aggregate with representation-aware ingress.
- Establish the multichannel downmix from the first decoded frame before
  publication. The current converter asks for roles during configure; the
  software backend cannot truthfully report the decoded layout that early.
- Select lead-in, reset, deficit and tail semantics by implementation and
  stream facts. Keep SKIP_MANUAL; the source owns the exact retained window
  and the converter owns only clipping to that window. Never apply an
  automatic decoder trim and a second WAM trim.
- Preserve exact first-sample and ceiling checks. TrueHD/MLP packet ordinals
  use 40-sample units at 48 kHz; seek planning must identify and decode from
  a preceding major sync and prove the first published frame is ceil(T*R).

This is an unapplied scope proposal, not a completed patch awaiting a rubber
stamp. Approval would permit implementation and its positive/negative proof
campaign; it would not make the currently absent A/V acceptance pass. Existing
frozen Apple converter/session test expectations must remain unchanged; new
software integration tests should live in separate files.

## Proposal 25 — decoder-private admission, separate from presentation

Amend the software budget block in
`src/platform/macos/native_surface_budget.hpp`, leaving the presentation
10-surface/384-MiB limits unchanged. Replace the blanket 1920x1080 software
area refusal with admission based on a derived byte reservation for each
codec, bit depth, chroma format, coded alignment, and maximum reference count.
Packet storage, conversion scratch, decoder-private references/scratch and
worker reservations must be accounted separately and retired on cancellation.

The new 32-frame measurements are evidence, not the reservation formula:
4K H.264 Hi10P/4:2:2 with 16 references reaches 511,116,416/653,182,080
tracked bytes, while 4K ASP/VP9/VP9 profile 2 reaches
52,366,688/56,291,776/106,523,072. There is no defensible single area-to-byte
multiplier in the existing rule. Reference storage and data-dependent decoder
scratch still need a source-derived upper bound or enforceable allocator
reservation; no ceiling is proposed by rounding these observed peaks.

Neither this proposal nor amendment 21 authorizes calling an observed peak a
worst-case bound. A combined software audio+video session also needs a stated
worker reservation: the current process limit is 16 decoder workers, not
16 two-worker sessions.
