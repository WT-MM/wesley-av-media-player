#pragma once
#include "media/native_media_source.hpp"
namespace wam::macos {
std::unique_ptr<media::MediaSource> createRoutedMediaSource();
}
