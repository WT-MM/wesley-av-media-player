#pragma once
#include "platform/macos/native_media_session_system.hpp"

namespace wam::macos {
class QtGlVideoItem;
NativeMediaSessionPresentationFactory qtNativePresentationFactory(QtGlVideoItem*) noexcept;
[[nodiscard]] std::unique_ptr<NativeMediaSession>
createQtNativeMediaSessionSystem(
    NativeMediaSessionSourceBinding binding,
    std::shared_ptr<void> externalLifetime,
    QtGlVideoItem* videoItem,
    std::string* error = nullptr,
    std::shared_ptr<media::captions::LiveCaptionFeed> captionFeed = nullptr) noexcept;
}
