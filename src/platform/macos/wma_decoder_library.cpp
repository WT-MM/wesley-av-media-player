#include "platform/macos/wma_decoder_library.hpp"

#include "media/avcodec/library_directory.hpp"

#include <dlfcn.h>
#include <filesystem>
#include <optional>
#include <type_traits>

namespace wam::macos {
namespace {

std::optional<WmaDecoderLibrary> load() noexcept {
  try {
    const auto libraries = media::avcodec::libraryDirectory(
        reinterpret_cast<const void *>(&wmaDecoderLibrary));
    const auto path = libraries / kWmaDecoderLibraryName;
    if (!std::filesystem::is_regular_file(path) ||
        std::filesystem::canonical(path).parent_path() !=
            std::filesystem::canonical(libraries))
      return std::nullopt;
    // Never closed: decoders may live until the process exits.
    void *handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!handle) return std::nullopt;
    WmaDecoderLibrary api;
    bool bound = true;
    const auto bind = [&](auto &slot, const char *name) {
      slot = reinterpret_cast<std::remove_reference_t<decltype(slot)>>(dlsym(handle, name));
      bound = bound && slot != nullptr;
    };
    bind(api.create, "wam_wma_create");
    bind(api.destroy, "wam_wma_destroy");
    bind(api.frameLength, "wam_wma_frame_length");
    bind(api.maxSamples, "wam_wma_max_samples");
    bind(api.decode, "wam_wma_decode");
    bind(api.drain, "wam_wma_drain");
    bind(api.flush, "wam_wma_flush");
    bind(api.superframeFrames, "wam_wma_superframe_frames");
    bind(api.usesNoiseCoding, "wam_wma_uses_noise_coding");
    if (!bound) return std::nullopt;
    return api;
  } catch (...) {
    return std::nullopt;
  }
}

} // namespace

const WmaDecoderLibrary *wmaDecoderLibrary() noexcept {
  static const std::optional<WmaDecoderLibrary> library = load();
  return library ? &*library : nullptr;
}

} // namespace wam::macos
