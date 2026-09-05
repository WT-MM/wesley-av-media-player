#pragma once

#include "native_media_session.hpp"

#include <memory>
#include <string>

namespace wam::macos {

class QtGlVideoItem;

// Constructs one production native media epoch with one tracked Qt presenter
// shared by the main and preview lanes, without exposing raw host-clock,
// AudioUnit, presenter, or wake contexts to the Qt controller. This must be
// called on videoItem's GUI thread. externalLifetime must keep every
// caller-owned GUI dependency alive until the returned session has published
// its terminal Stop proof and is destroyed.
//
// Construction enters no AVFoundation, AudioConverter, or AudioUnit resource;
// those remain lazy on NativeMediaSession's worker after Prepare admission.
// A null result is a synchronous construction failure described by error when
// supplied. Runtime/admission failures are reported later as session facts.
[[nodiscard]] std::unique_ptr<NativeMediaSession>
createNativeMediaSessionSystem(
    NativeMediaSessionSourceBinding binding,
    std::shared_ptr<void> externalLifetime,
    QtGlVideoItem* videoItem,
    std::string* error = nullptr,
    std::shared_ptr<media::captions::LiveCaptionFeed> captionFeed =
        nullptr) noexcept;

}  // namespace wam::macos
