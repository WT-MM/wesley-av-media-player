#include "native_embedding_support.hpp"
#include "native_audio_test_mute.hpp"
#include "native_video_codec_capability.hpp"
#include "native_layer_presentation_state.hpp"
#include "native_layer_host_view.hpp"

namespace wam::macos {
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
