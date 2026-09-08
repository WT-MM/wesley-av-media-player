#pragma once
#include "platform/macos/native_playback_owner.hpp"

namespace wam::macos {
class QtGlVideoItem;
NativeMediaSessionPresentationFactory qtNativePresentationFactory(QtGlVideoItem*) noexcept;
}
