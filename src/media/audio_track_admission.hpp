#pragma once

#include "media/native_media_source.hpp"

#include <optional>
#include <span>

namespace wam::media {

struct AudioTrackCandidate {
  MediaTrackId id{0};
  bool enabled{false};
  bool isDefault{false};
};

// Explicit track requests are exact. Automatic selection tries defaults in
// container order, then other enabled tracks, accepting only complete proofs.
template <class Admit>
[[nodiscard]] std::optional<std::size_t>
selectAdmittedAudioTrack(std::span<const AudioTrackCandidate> candidates,
                         std::optional<MediaTrackId> preferred, Admit &&admit) {
  if (candidates.size() > MediaSourceLimits::kHardMaximumTracks)
    return {};
  for (unsigned pass = 0; pass < 2; ++pass) {
    for (std::size_t i = 0; i < candidates.size(); ++i) {
      const auto &candidate = candidates[i];
      if (!candidate.enabled || candidate.id == 0)
        continue;
      if (preferred) {
        if (pass != 0 || candidate.id != *preferred)
          continue;
      } else if (candidate.isDefault != (pass == 0)) {
        continue;
      }
      if (admit(i))
        return i;
      if (preferred)
        return {};
    }
  }
  return {};
}

} // namespace wam::media
