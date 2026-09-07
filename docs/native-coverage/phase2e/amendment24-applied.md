

## Phase 2e — amendment 24 application (production wiring)

AMENDMENT 24 APPLIED within the ratified scope. Existing Apple test files remain byte-identical. Acceptance is pending the new production software tests. Exact frozen-line before/after follows; later corrections will be appended separately.

```diff
--- src/media/native_media_source.hpp BEFORE
+++ src/media/native_media_source.hpp AFTER
@@ -197,0 +198,3 @@
+  Dts,
+  TrueHd,
+  Mlp,
```

```diff
--- src/platform/macos/native_audio_converter.hpp BEFORE
+++ src/platform/macos/native_audio_converter.hpp AFTER
@@ -20,0 +21,5 @@
+};
+
+struct NativeAudioBackendWake {
+  void (*signal)(void*) noexcept{};
+  void* context{};
@@ -32,0 +38 @@
+  NativeAudioBackendWake wake{};
@@ -281,0 +288 @@
+  void setBackendWake(NativeAudioBackendWake wake) noexcept;
```

```diff
--- src/platform/macos/native_audio_converter.mm BEFORE
+++ src/platform/macos/native_audio_converter.mm AFTER
@@ -1,0 +2,3 @@
+#if defined(WAM_ENABLE_AVCODEC_STAGE)
+#include "software_avcodec_audio_backend.hpp"
+#endif
@@ -818,0 +822 @@
+        injected_backend(bool(injected)),
@@ -1400,0 +1405,3 @@
+  const bool injected_backend;
+  bool software_backend{};
+  NativeAudioBackendWake backend_wake{};
@@ -1483,0 +1491,3 @@
+void NativeAudioConverter::setBackendWake(NativeAudioBackendWake wake) noexcept {
+  impl_->backend_wake = wake;
+}
@@ -1522,0 +1533,4 @@
+  const bool software = media::softwareAudioCodec(track.codec);
+#if !defined(WAM_ENABLE_AVCODEC_STAGE)
+  if (software) return state.fail(error, "SoftwareAudioStageNotBuilt");
+#endif
@@ -1529 +1543,2 @@
-      !track.audio || !supportedCodec(track.codec, track.audio->formatTag) ||
+      !track.audio || (!software && !supportedCodec(track.codec, track.audio->formatTag)) ||
+      (software && track.audio->formatTag != 0) ||
@@ -1540,6 +1555,5 @@
-      (!track.codecConfiguration.empty() &&
-       track.codecConfigurationKind !=
-           media::MediaCodecConfigurationKind::AudioMagicCookie) ||
-      (track.codecConfiguration.empty() &&
-       track.codecConfigurationKind !=
-           media::MediaCodecConfigurationKind::None)) {
+      (software ? track.codecConfigurationKind != media::MediaCodecConfigurationKind::CodecPrivate
+       : ((!track.codecConfiguration.empty() &&
+           track.codecConfigurationKind != media::MediaCodecConfigurationKind::AudioMagicCookie) ||
+          (track.codecConfiguration.empty() &&
+           track.codecConfigurationKind != media::MediaCodecConfigurationKind::None)))) {
@@ -1548,0 +1563,10 @@
+#if defined(WAM_ENABLE_AVCODEC_STAGE)
+  if (!state.injected_backend) {
+    if (software) {
+      const auto codec = track.codec == media::MediaCodec::Dts ? media::avcodec::Codec::Dts
+          : track.codec == media::MediaCodec::TrueHd ? media::avcodec::Codec::TrueHd : media::avcodec::Codec::Mlp;
+      state.backend = std::make_unique<SoftwareAvcodecAudioBackend>(codec);
+    } else state.backend = std::make_unique<CoreAudioConverterBackend>();
+  }
+#endif
+  state.software_backend = software;
@@ -1558,3 +1582,12 @@
-  NativeAudioBackendConfiguration configuration{
-      *track.audio, track.codecConfiguration, track.audio->channels,
-      candidateSampleRate};
+  NativeAudioBackendConfiguration configuration;
+  configuration.input = *track.audio;
+  configuration.outputChannels = track.audio->channels;
+  configuration.outputSampleRate = candidateSampleRate;
+  configuration.wake = state.backend_wake;
+  if (software) {
+    using R = media::DecodeRefusal;
+    configuration.decodePlan = media::chooseDecodePlan({R::NotApplicable, R::NotApplicable,
+        R::AppleCodecUnavailable, R::NotApplicable, R::None});
+    configuration.decodePlan.configurationRepresentation = media::DecodeConfigurationRepresentation::RawExtradata;
+    configuration.rawExtradata = track.codecConfiguration;
+  } else configuration.magicCookie = track.codecConfiguration;
@@ -1580 +1613 @@
-  if (track.audio->channels > NativePcmRing::kChannels) {
+  if (!software && track.audio->channels > NativePcmRing::kChannels) {
@@ -1614 +1647 @@
-  state.cookie_size = track.codecConfiguration.size();
+  state.cookie_size = software ? 0 : track.codecConfiguration.size();
@@ -1628 +1661 @@
-      decoderLeadInFrames(track.codec, state.audio.framesPerPacket);
+      software ? 0 : decoderLeadInFrames(track.codec, state.audio.framesPerPacket);
@@ -1630 +1663 @@
-      decoderFrameDeficitFrames(track.codec, state.audio.framesPerPacket);
+      software ? 0 : decoderFrameDeficitFrames(track.codec, state.audio.framesPerPacket);
@@ -1632 +1665 @@
-      decoderTailShortfallBoundFrames(track.codec, state.audio.framesPerPacket);
+      software ? 0 : decoderTailShortfallBoundFrames(track.codec, state.audio.framesPerPacket);
@@ -1950,0 +1984,11 @@
+    if (state.software_backend && state.audio.channels > NativePcmRing::kChannels && !state.downmix.admitted()) {
+      std::array<media::AudioChannelRole, media::kMaximumDownmixSourceChannels> roles{};
+      std::size_t count{};
+      if (state.backend->outputChannelRoles(roles, &count))
+        state.downmix = media::buildStereoDownmixMatrix({roles.data(), count});
+      if (!state.downmix.admitted() || state.downmix.sourceChannels != state.audio.channels) {
+        state.failPump(error, "SoftwareAudioDecodedChannelLayoutUnqualified");
+        return NativeAudioPumpResult::Failed;
+      }
+      state.statistics.downmixApplied = true;
+    }
@@ -2025,0 +2070 @@
+  if (state.software_backend) return NativeAudioPumpResult::Backpressure;
@@ -2060 +2105,2 @@
-    if (!state.backend->reset(nullptr)) {
+    if (state.software_backend) state.backend->close();
+    else if (!state.backend->reset(nullptr)) {
```

```diff
--- src/platform/macos/native_audio_session.mm BEFORE
+++ src/platform/macos/native_audio_session.mm AFTER
@@ -194,2 +194,9 @@
-  return track.audio &&
-         audioCodecFormatTagAdmitted(track.codec, track.audio->formatTag);
+  if (track.audio && media::softwareAudioCodec(track.codec)) {
+#if defined(WAM_ENABLE_AVCODEC_STAGE)
+    return track.audio->formatTag == 0 &&
+        track.codecConfigurationKind == media::MediaCodecConfigurationKind::CodecPrivate;
+#else
+    return false;
+#endif
+  }
+  return track.audio && audioCodecFormatTagAdmitted(track.codec, track.audio->formatTag);
@@ -565 +572,9 @@
-        generation(initialGeneration) {}
+        generation(initialGeneration) {
+    converter.setBackendWake({[](void* context) noexcept {
+      auto& control = *static_cast<NativeAudioSessionControl*>(context);
+      bool expected = false;
+      if (control.outputWake.pending->compare_exchange_strong(expected, true,
+          std::memory_order_acq_rel, std::memory_order_acquire))
+        control.outputWake.signal(control.outputWake.context);
+    }, this});
+  }
```


### Amendment 24 — session preflight correction

Applied raw-extradata admission and exact decoded-duration semantics for the three new software audio identities. Frozen Apple test files remain byte-identical.

```diff
--- a/src/platform/macos/native_audio_session.mm
+++ b/src/platform/macos/native_audio_session.mm
@@ -234,7 +234,7 @@
 [[nodiscard]] bool codecStatesExactDecodedDuration(
     const media::MediaTrackDescriptor& track, std::uint32_t sampleRate) noexcept {
   if (!media::audioCodecStatesExactDecodedDuration(track.codec)) {
-    if (track.codec != media::MediaCodec::Aac) {
+    if (track.codec != media::MediaCodec::Aac && !media::softwareAudioCodec(track.codec)) {
       return false;
     }
   }
@@ -491,12 +491,12 @@
       !supportedRate(track.audio->sampleRate, &sampleRate) ||
       track.codecConfiguration.size() >
           media::MediaSourceLimits::kHardMaximumCodecConfigurationBytes ||
-      (!track.codecConfiguration.empty() &&
-       track.codecConfigurationKind !=
-           media::MediaCodecConfigurationKind::AudioMagicCookie) ||
-      (track.codecConfiguration.empty() &&
-       track.codecConfigurationKind !=
-           media::MediaCodecConfigurationKind::None)) {
+      (media::softwareAudioCodec(track.codec)
+           ? track.codecConfigurationKind != media::MediaCodecConfigurationKind::CodecPrivate
+           : ((!track.codecConfiguration.empty() &&
+               track.codecConfigurationKind != media::MediaCodecConfigurationKind::AudioMagicCookie) ||
+              (track.codecConfiguration.empty() &&
+               track.codecConfigurationKind != media::MediaCodecConfigurationKind::None)))) {
     return std::nullopt;
   }
   return timelinePlanFor(generation, timeline, sampleRate,
```

Application verification: the scoped changes pass the 24 production PCM cases, three full audio/video app runs, exact seek/retained-window checks and the production revert proof. Existing Apple test expectations remain byte-identical. DTS-HD MA is not newly qualified. See PRODUCTION_AUDIO.md and the final phase-2 report.
