#include "playback/mpv/mpv_runtime.hpp"

#include <QLibrary>

#include <utility>

namespace wam::playback::mpv {

MpvRuntime::MpvRuntime(std::unique_ptr<QLibrary> library, MpvApi api,
                       unsigned long clientApiVersion, QString loadedPath)
    : library_(std::move(library)),
      api_(api),
      client_api_version_(clientApiVersion),
      loaded_path_(std::move(loadedPath)) {}

MpvRuntime::MpvRuntime(MpvApi api, unsigned long clientApiVersion,
                       QString loadedPath)
    : api_(api),
      client_api_version_(clientApiVersion),
      loaded_path_(std::move(loadedPath)) {}

MpvRuntime::~MpvRuntime() = default;

}  // namespace wam::playback::mpv
