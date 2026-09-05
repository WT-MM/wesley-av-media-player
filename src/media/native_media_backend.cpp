#include "media/native_media_backend.hpp"

#include "media/media_codec_facts.hpp"

#include <utility>

namespace wam::media {
namespace {

void assignError(std::string* error, const char* message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    *error = message;
  } catch (...) {
    // Error reporting is best-effort at this noexcept validation boundary.
  }
}

const MediaTrackDescriptor* selectedVideo(
    const MediaPreviewBinding& binding) noexcept {
  if (binding.preparedContext == nullptr) {
    return nullptr;
  }
  const auto& descriptor = binding.preparedContext->descriptor();
  if (descriptor == nullptr || !descriptor->selectedVideo) {
    return nullptr;
  }
  return findMediaTrack(*descriptor, *descriptor->selectedVideo);
}

bool targetWithinDuration(MediaTime target, MediaTime duration) noexcept {
  if (!target.valid() || target.value < 0 || !duration.valid() ||
      duration.value < 0) {
    return false;
  }
  const auto order = compareMediaTime(target, duration);
  return order.has_value() && *order != MediaTimeOrder::Greater;
}

}  // namespace

bool validateMediaPreviewBinding(const MediaPreviewBinding& binding,
                                 std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  try {
    if (binding.preparedContext == nullptr ||
        binding.preparedContext->localPath().empty() ||
        binding.preparedContext->descriptor() == nullptr ||
        !binding.preparedContext->matchesPreviewBinding(
            binding.preparedContext->localPath(),
            binding.preparedContext->descriptor()) ||
        !validateMediaSourceDescriptor(
            *binding.preparedContext->descriptor(),
            binding.preparedContext->limits(), nullptr)) {
      assignError(error, "preview binding has no exact prepared identity");
      return false;
    }
    const MediaTrackDescriptor* track = selectedVideo(binding);
    // The nonempty-record requirement is INVERTED for the codecs that carry no
    // out-of-band configuration record: an empty record is their only correct
    // descriptor, so demanding one refuses every ProRes, Motion JPEG and MPEG-2
    // track a preview lane can decode perfectly well.
    if (track == nullptr || track->kind != MediaTrackKind::Video ||
        !track->video || track->codec == MediaCodec::Unknown ||
        (mediaCodecFacts(track->codec).carriesConfigurationRecord
             ? track->codecConfiguration.empty()
             : !track->codecConfiguration.empty())) {
      assignError(error,
                  "preview binding has no selected encoded video track");
      return false;
    }
    return true;
  } catch (...) {
    assignError(error, "preview binding validation raised an exception");
    return false;
  }
}

bool mediaPreviewBindingMatchesBackend(
    const MediaPreviewBinding& binding,
    MediaSourceBackendKind backendKind) noexcept {
  return validateMediaPreviewBinding(binding, nullptr) &&
         binding.preparedContext->backendKind() == backendKind;
}

bool validateMediaPreviewRequest(const MediaPreviewBinding& binding,
                                 MediaPreviewRequest request,
                                 std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (!validateMediaPreviewBinding(binding, error) ||
      !request.epoch.valid() ||
      !targetWithinDuration(
          request.target,
          binding.preparedContext->descriptor()->duration)) {
    assignError(error, "preview request has invalid identity or target");
    return false;
  }
  return true;
}

bool validateMediaPreviewSample(const MediaSample& sample,
                                const MediaPreviewBinding& binding,
                                MediaPreviewEpoch expectedEpoch,
                                std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (!validateMediaPreviewBinding(binding, nullptr)) {
    assignError(error, "preview sample has no valid prepared binding");
    return false;
  }
  const MediaTrackDescriptor* track = selectedVideo(binding);
  if (!expectedEpoch.valid() || track == nullptr ||
      sample.generation != expectedEpoch.value || sample.track != track->id ||
      sample.kind != MediaSampleKind::EncodedVideo ||
      !validateMediaSample(sample, *binding.preparedContext->descriptor(),
                           binding.preparedContext->limits(), nullptr)) {
    assignError(error,
                "preview sample does not match its exact epoch/video track");
    return false;
  }
  return true;
}

bool validateMediaPreviewDiscontinuity(
    const MediaDiscontinuity& discontinuity,
    const MediaPreviewBinding& binding, MediaPreviewEpoch expectedEpoch,
    std::string* error) noexcept {
  if (error != nullptr) {
    error->clear();
  }
  if (!validateMediaPreviewBinding(binding, nullptr)) {
    assignError(error,
                "preview discontinuity has no valid prepared binding");
    return false;
  }
  const MediaTrackDescriptor* track = selectedVideo(binding);
  if (!expectedEpoch.valid() || track == nullptr ||
      discontinuity.generation != expectedEpoch.value ||
      discontinuity.track != track->id ||
      !validateMediaDiscontinuity(
          discontinuity, *binding.preparedContext->descriptor(), nullptr)) {
    assignError(error,
                "preview discontinuity does not match its exact epoch/video "
                "track");
    return false;
  }
  return true;
}

}  // namespace wam::media
