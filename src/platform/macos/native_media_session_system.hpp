#pragma once

#include "native_media_session.hpp"

#include <memory>
#include <string>

namespace wam::macos {

struct NativeMediaSessionPresentation {
  std::shared_ptr<NativeTrackedVideoOutput> output;
  std::shared_ptr<void> lifetime;
};

// Called during construction on the presentation owner's thread. The returned
// lifetime must retain presentation dependencies until session destruction.
struct NativeMediaSessionPresentationFactory {
  void* context{nullptr};
  NativeMediaSessionPresentation (*create)(
      void*, NativeTrackedVideoOutputWakeSeam, std::string*) noexcept{nullptr};
};

// Resource creation remains lazy on the session worker after Prepare admission.
[[nodiscard]] std::unique_ptr<NativeMediaSession>
createNativeMediaSessionSystem(
    NativeMediaSessionSourceBinding binding,
    std::shared_ptr<void> externalLifetime,
    NativeMediaSessionPresentationFactory presentation,
    std::string* error = nullptr,
    std::shared_ptr<media::captions::LiveCaptionFeed> captionFeed =
        nullptr) noexcept;

}  // namespace wam::macos
