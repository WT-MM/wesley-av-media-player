#include "platform/macos/mpegts_preview_source.hpp"

#include "platform/macos/mpegts_media_source.hpp"
#include "platform/macos/mpegts_sample_builder.hpp"
#include "platform/macos/native_preview_source_core.hpp"

#include <vector>

namespace wam::macos {
namespace {

struct MpegTsPreviewTraits : MpegTsSourceTraits {
  // Reset-not-freed Annex-B gather workspace, one per preview source.
  using PreviewWorkspace = std::vector<std::byte>;

  [[nodiscard]] static bool previewSampleBounded(
      const CompressedSample& raw,
      const media::MediaSourceLimits& limits) noexcept {
    return raw.payloadBytes != 0 &&
           raw.payloadBytes <= limits.maximumVideoSampleBytes;
  }

  [[nodiscard]] static CompressedSampleBuildStatus buildPreviewSample(
      const PreparedAsset& asset, media::CancellationToken cancellation,
      CMFormatDescriptionRef format, const media::MediaTrackDescriptor& track,
      const CompressedSample& raw, PreviewWorkspace& workspace,
      ScopedSampleBuffer* out, std::string* error) {
    MpegTsSampleBuildInputs inputs;
    inputs.asset = &asset;
    inputs.cancellation = cancellation;
    inputs.format = format;
    inputs.codec = track.codec;
    inputs.video = true;
    inputs.workspace = &workspace;
    return buildMpegTsCompressedSampleBuffer(inputs, raw, out, error);
  }
};

}  // namespace

std::unique_ptr<NativePreviewSource> createMpegTsPreviewSource(
    NativePreviewBinding binding) noexcept {
  return NativePreviewSourceCore<MpegTsPreviewTraits>::create(
      std::move(binding));
}

}  // namespace wam::macos
