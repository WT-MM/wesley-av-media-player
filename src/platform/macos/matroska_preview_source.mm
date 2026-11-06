#include "platform/macos/matroska_preview_source.hpp"

#include "platform/macos/matroska_media_source.hpp"
#include "platform/macos/matroska_sample_builder.hpp"
#include "platform/macos/native_preview_source_core.hpp"

namespace wam::macos {
namespace {

struct MatroskaPreviewTraits : MatroskaSourceTraits {
  struct PreviewWorkspace {};

  // One unlaced frame and no decode stamp: the demuxer never invents one.
  [[nodiscard]] static bool previewSampleBounded(
      const CompressedSample& raw,
      const media::MediaSourceLimits& limits) noexcept {
    return !raw.decodeTime.valid() && raw.aggregateBytes != 0 &&
           raw.frameCount == 1 &&
           raw.aggregateBytes <= limits.maximumVideoSampleBytes;
  }

  [[nodiscard]] static CompressedSampleBuildStatus buildPreviewSample(
      const PreparedAsset& asset, media::CancellationToken cancellation,
      CMFormatDescriptionRef format, const media::MediaTrackDescriptor&,
      const CompressedSample& raw, PreviewWorkspace&, ScopedSampleBuffer* out,
      std::string* error) {
    MatroskaSampleBuildInputs inputs;
    inputs.asset = &asset;
    inputs.cancellation = cancellation;
    inputs.format = format;
    inputs.video = true;
    return buildMatroskaCompressedSampleBuffer(inputs, raw, out, error);
  }
};

}  // namespace

std::unique_ptr<NativePreviewSource> createMatroskaPreviewSource(
    NativePreviewBinding binding) noexcept {
  return NativePreviewSourceCore<MatroskaPreviewTraits>::create(
      std::move(binding));
}

}  // namespace wam::macos
