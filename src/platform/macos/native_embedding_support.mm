#include "native_embedding_support.hpp"
#include "native_audio_test_mute.hpp"
#include "native_video_codec_capability.hpp"
#include "native_layer_presentation_state.hpp"
#include "native_layer_host_view.hpp"

#if defined(WAM_ENABLE_AVCODEC_STAGE)
#include "media/avcodec/decode_worker.hpp"
#endif
namespace wam::macos {
void NativeEmbeddingSupport::setTestNoVideoHardware(bool value) noexcept { setNativeVideoHardwareDisabledForTesting(value); }
NativeEmbeddingSupport::SoftwareWorkers NativeEmbeddingSupport::softwareWorkers() noexcept {
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  using media::avcodec::DecodeWorker;
  return {DecodeWorker::reservedWorkers(), DecodeWorker::pendingWorkers(),
          DecodeWorker::peakReservedWorkers(), DecodeWorker::reservedProcessBytes()};
#else
  return {};
#endif
}
media::MediaDisplayProjection NativeEmbeddingSupport::displayGeometry(void* window) noexcept { return nativeLayerDisplayGeometry(window); }
void NativeEmbeddingSupport::setTestMuted(bool value) noexcept { setNativeAudioOutputTestMuted(value); }
bool NativeEmbeddingSupport::testMuted() noexcept { return nativeAudioOutputTestMuted(); }
bool NativeEmbeddingSupport::supportsAv1() noexcept { return nativeVideoToolboxSupportsAv1(); }
bool NativeEmbeddingSupport::supportsVp9() noexcept { return nativeVideoToolboxSupportsVp9(); }
bool NativeEmbeddingSupport::layerRouteSelected() noexcept { return layerPresentationRouteSelected(); }
bool NativeEmbeddingSupport::layerActive() noexcept { return nativeLayerPresentationActive(); }
void NativeEmbeddingSupport::setVividBoost(void* window, double value) noexcept { setNativeLayerVividBoost(window, value); }
double NativeEmbeddingSupport::vividBoost(void* window) noexcept { return nativeLayerVividBoost(window); }
double NativeEmbeddingSupport::appliedVividBoost(void* window) noexcept { return nativeLayerAppliedVividBoost(window); }
}
