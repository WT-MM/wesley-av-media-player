#pragma once
#include <array>
#include <climits>
#include <cstdint>
#include <dlfcn.h>
#include <filesystem>
#include <mach-o/dyld.h>
#include <stdexcept>
namespace wam::media::avcodec {
// Lazy codec discovery is confined to the image's packaged private closure.
inline std::filesystem::path libraryDirectory(const void* imageSymbol) {
  Dl_info image{};
  if (dladdr(imageSymbol, &image) && image.dli_fname) {
    const auto path = std::filesystem::canonical(image.dli_fname);
    if (path.filename() == "WAMKit") return path.parent_path() / "Frameworks";
  }
  std::array<char,PATH_MAX> executable{};
  std::uint32_t size=executable.size();
  if (_NSGetExecutablePath(executable.data(),&size)) throw std::runtime_error("ExecutablePath");
  const auto directory=std::filesystem::canonical(executable.data()).parent_path();
  return directory.filename()=="MacOS" ? directory.parent_path()/"Frameworks" : directory/"native-codecs";
}
}
