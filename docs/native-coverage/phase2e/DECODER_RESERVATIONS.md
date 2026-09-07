# Decoder-private admission (amendment 25)

Presentation remains ten IOSurfaces / 384 MiB per session, byte-identical to the frozen prefix. Decoder-private memory has a separate admission and enforcement domain.

For a video, round each coded dimension upward to 128 pixels. Round each planar byte stride to 64 bytes. With `b=1` for 8-bit and `b=2` for 10-bit, aligned width `W` and height `H`, reserve:

`P = align64(W*b)*H + 2*align64(W/2*b)*(H/2 for 420; H for 422) + 3*64`.

The final term allows the allocator's three aligned plane headers. Reservations use H.264 `38*P`, MPEG-4 ASP `8*P`, and VP9 `28*P`, plus an **enforced** 8 MiB ancillary capacity. Audio receives an enforced 16 MiB private capacity. These ancillary capacities are admission policies, not observed peaks or claims that every stream fits. A stream exceeding them refuses as `AvcodecDecoderPrivateBudgetExceeded`.

Source facts from the pinned local FFmpeg 9.0.1 source:

- `libavcodec/h264dec.h:47`: `H264_MAX_PICTURE_COUNT` is 36; the reservation adds two picture capacities for codec output/current work.
- `libavcodec/mpegvideo.h:120`: last, next and current work pictures; eight picture capacities provide a bounded pool/output allowance. Pool/side-allocation growth is constrained by the allocator domain, rather than assumed to stop at that allowance.
- `libavcodec/vp9shared.h:171`: eight refs, four frames and eight ref frames; `vp9dec.h:129` adds eight next refs. Counting all 28 is conservative because some are aliases.
- A source search of enabled `libavcodec`/`libavutil` C files finds direct malloc/realloc/posix_memalign calls only in `libavutil/mem.c` (excluding library test programs). The local patch replaces that allocation boundary. Codec-internal thread creation remains disabled.

Each allocation includes a 64-byte header and rounded payload in the charge. Realloc reserves the simultaneous old and replacement blocks until copying and freeing finish. Arena reference ownership permits cross-thread frees. A pthread key associates worker allocations without Mach-O TLS pinning; its destructor deletes the key at library unload. Private allocation counters must reach zero at worker retirement. An incomplete retirement keeps the process reservation charged and reports `AvcodecDecoderPrivateRetirementIncomplete`.

Separate charges per worker are four `(4 MiB + 64)` packet slots; two copies of extradata plus padding; 4 MiB video conversion storage or 131,072 bytes audio conversion storage; the derived private capacity; and one worker slot. Conversion storage belongs to the worker and is freed on close. The aggregate reservation ceiling is 2 GiB, the private capacity ceiling is 384 MiB, and the worker limit is sixteen. A software audio+video session consumes two workers: eight such sessions leave no worker for previews. System/framework memory and thread-stack overhead are not represented as decoder heap payload.

The 1920×1088 MPEG-4 specimen decoded 32/32 reordered frames with exact PTS, EOS and backpressure checks. The allocator test checks cap enforcement, realloc peak storage, alignment and late/cross-thread frees. The worker test checks sixteen admissions, named refusal of worker seventeen, cancellation to zero reserved bytes/workers, and admission above the old area limit. Full codec-ON CTest: 131/131. The repeated sixteen-window software soak has zero presentation-drain failures and unloads both native images after close.

[Allocator and unload revert proof](allocator-revert-proof.json), [worker admission/retirement revert proof](reservation-revert-proof.json), [soak](multiwindow-reservation.json), [CTest](ctest-reservation.txt).
