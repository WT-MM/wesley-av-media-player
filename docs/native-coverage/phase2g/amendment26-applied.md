# Amendment 26 — scoped presentation qualification

Owner authorization: extend the seven corpus color descriptors and three hardware-decodable sample formats only after retained display qualification. No other frozen file is changed.

The applied scope is 8-bit H.264 4:4:4 on the direct display route, limited-range 709/709/709 or 601/709/601, and the exact ambient-viewing payload `002fe9a03d134042` on limited-range BT.2020 / HLG / BT.2020 NCL ten-bit 4:2:0. The appended range fact prevents full-range variants from inheriting these proofs. Dolby Vision is not qualified. The payload denotes illuminance 314 lux and chromaticity x=15635/50000, y=16450/50000. The ten-surface and 384 MiB ceilings are unchanged; 4:4:4 8-bit derives 30,629,888 bytes per padded surface.

Exact frozen-line before/after:

```diff
diff --git a/src/media/native_media_source.hpp b/src/media/native_media_source.hpp
index db35507..93b0000 100644
--- a/src/media/native_media_source.hpp
+++ b/src/media/native_media_source.hpp
@@ -249,6 +249,7 @@ enum class MediaVideoSampleFormat : std::uint8_t {
   Unsupported,
   Yuv422EightBit,
   Yuv422TenBit,
+  Yuv444EightBit,
 };
 
 // Exact bounded scalar used for container display geometry. Values are always
@@ -335,6 +336,8 @@ struct MediaVideoFormat {
   // Modelled separately from unsupportedColorMetadataPresent so that a later
   // session can admit it without re-deriving the whole opaque bit.
   bool ambientViewingEnvironmentPresent{false};
+  std::uint64_t ambientViewingEnvironmentPayload{0};
+  bool fullRangeVideo{false};
 
   friend bool operator==(const MediaVideoFormat&, const MediaVideoFormat&) =
       default;
```

Hardware display evidence: `hdr-hardware-projections.json`, `444-hardware-projections.json`; captures are retained under `/private/tmp/wam-phase2g/captures/`. Final build/test and corpus acceptance are recorded in [TESTS.md](TESTS.md) and [CORPUS.md](CORPUS.md).
