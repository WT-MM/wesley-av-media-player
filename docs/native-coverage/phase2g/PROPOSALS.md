# Unapplied proposals and deferred proofs

## Proposal 27 — rational display size (not applied)

The two anamorphic sources declare PAR 5127:4912. Their exact display size is (615240/307) × 1080 and their reduced aspect is 1709:921. The frozen public geometry currently returns integral dimensions. Rounding that width, or claiming a pixel capture exactly represents it, would violate the requested actual-size contract. Amendment 26 authorizes color/sample-format changes, not this geometry change.

Exact proposed frozen interface replacement in `src/media/native_media_source.hpp`:

```diff
 struct MediaDisplaySize {
-  std::uint32_t width{0};
-  std::uint32_t height{0};
+  MediaRational width{};
+  MediaRational height{};
 
   [[nodiscard]] constexpr bool empty() const noexcept {
-    return width == 0 || height == 0;
+    return width.numerator <= 0 || height.numerator <= 0;
   }
```

The frozen `PreparedDescriptor` in `src/media/native_playback_contract.hpp` also transports integer display dimensions to Qt. Its exact proposed field replacement is:

```diff
-  std::uint32_t displayWidth{0};
-  std::uint32_t displayHeight{0};
+  media::MediaRational displayWidth{};
+  media::MediaRational displayHeight{};
```

This proposal requires the rational type to be visible at that header and corresponding validity/consumer updates; none are applied. An internal alternative must still prove that it transports the exact size through the existing prepared-message boundary without misrepresenting these integer fields.

Implementation must then carry reduced rational dimensions through admission, rotation, CALayer contents geometry, Qt fit/actual-size/aspect-lock and only quantize at the final physical-pixel boundary. Required proof: exact rational geometry assertions and retained display captures reporting the physical-pixel quantization separately. No anamorphic admission or successful aspect capture is claimed in this phase.

## Deferred CoreMedia edit mapping

PXL's audio includes an empty prefix of 192/10000 seconds, a source head trim of 2112/48000, and retained CoreMedia duration 6815160/240000. Its buffers also carry discontinuity-fill instructions and varying output durations. A constant PTS subtraction does not implement that map. The existing rational audio window can represent start/end constraints; this is an unimplemented mapping/PCM proof, not a claim that a new frozen field is necessarily required.

FFmpeg returns 1,364,070 decoded samples, first PTS 922/48000. The CoreMedia retained interval corresponds to 1,363,032 samples. FFmpeg’s timestamp endpoint is 56881/2000 and its gap from the video endpoint is 541/15000 seconds. The CoreMedia target interval ends at 284157/10000. The video end is 854297/30000; matching neither count approximately nor inserting guessed samples is acceptable. Native refuses `CoreMediaAudioEditExactTimelineProofMissing`. Exact retained PCM, discontinuity placement, head/tail trims, endpoint equality and seek proofs remain outstanding.

## Deferred software preview scheduling

The three final fully started sixteen-window software storms reproduce 16, 17 and 17 preview failures. A temporary bounded-worker trace identifies `AvcodecWorkerBudgetExceeded`; all sixteen windows retire and the native images unload. The first storm also records one commit-seek drain failure; the other two record none. Playback creates sixteen software workers; previews create independent decoder workers. The process ceiling is sixteen and each worker also acquires a derived reservation. A fix must hand off/reuse bounded decode capacity during preview and prove cancellation retirement across three fully started storms. Raising the ceiling, hiding failures, or counting a storm with no drawn playback as a success is not acceptable. No scheduler fix or zero-failure acceptance is claimed.

## Deferred full-range and HDR metadata qualification

Full-range 8-bit ASP/VP9 still miss the retained range projection. Temporary normalization trials were removed. Known PQ/HLG software fixtures pass against the corrected hardware oracle, but those captures do not qualify every HDR metadata combination. Dolby Vision, alternate/full-range HDR and unmeasured software HDR tuples remain unqualified. The default codec stage stays OFF.
