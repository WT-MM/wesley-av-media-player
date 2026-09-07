#include "runtime.hpp"
#include "api.hpp"
#include "closure.hpp"
#include <array>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <filesystem>
#include <mach-o/dyld.h>
#include <unistd.h>
namespace wam::media::avcodec {
namespace {
Api table;
void* codecHandle{};
void* utilHandle{};
unsigned leases{};
void unload() noexcept {
  table = {};
  if (codecHandle) dlclose(codecHandle);
  if (utilHandle) dlclose(utilHandle);
  codecHandle = nullptr; utilHandle = nullptr;
}
const char* validate() noexcept {
  if(table.avcodec_version()!=AV_VERSION_INT(63,1,101) || table.avutil_version()!=AV_VERSION_INT(61,1,101))return "DecoderUnavailable: AvcodecRuntimeAbiMismatch";
  for(const char* license:{table.avcodec_license(),table.avutil_license()})
    if(std::strcmp(license,"LGPL version 2.1 or later"))return "DecoderUnavailable: AvcodecRuntimeLicenseMismatch";
  for(const char* config:{table.avcodec_configuration(),table.avutil_configuration()})
    if(!std::strstr(config,"--disable-gpl") || !std::strstr(config,"--disable-nonfree") ||
       !std::strstr(config,"--disable-version3") || !std::strstr(config,"--disable-autodetect") ||
       std::strstr(config,"--enable-gpl") || std::strstr(config,"--enable-nonfree") ||
       std::strstr(config,"--enable-version3"))return "DecoderUnavailable: AvcodecRuntimeConfigurationMismatch";
  for(const auto codec:{AV_CODEC_ID_H264,AV_CODEC_ID_MPEG4,AV_CODEC_ID_VP9,
      AV_CODEC_ID_DTS,AV_CODEC_ID_TRUEHD,AV_CODEC_ID_MLP})
    if(!table.avcodec_find_decoder(codec))return "DecoderUnavailable: AvcodecRuntimeDecoderMissing";
  return nullptr;
}
const char* load() {
  if (foreignClosurePresent()) return "DecoderUnavailable: PlaybackFfmpegClosureConflict";
  std::array<char, PATH_MAX> executable{};
  std::uint32_t size = executable.size();
  if (_NSGetExecutablePath(executable.data(), &size)) return "DecoderUnavailable: ExecutablePath";
  const auto directory = std::filesystem::canonical(executable.data()).parent_path();
  const auto libraries = directory.filename() == "MacOS"
      ? directory.parent_path() / "Frameworks" : directory / "native-codecs";
  const auto util = libraries / "libavutil-wamnative.61.dylib";
  const auto codec = libraries / "libavcodec-wamnative.63.dylib";
  if (!std::filesystem::is_regular_file(util) || !std::filesystem::is_regular_file(codec))
    return "DecoderStageNotBuilt: native FFmpeg libraries missing";
  if (std::filesystem::canonical(util).parent_path()!=std::filesystem::canonical(libraries) ||
      std::filesystem::canonical(codec).parent_path()!=std::filesystem::canonical(libraries))
    return "DecoderUnavailable: native FFmpeg library outside bundle";
  utilHandle = dlopen(util.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!utilHandle) return "DecoderUnavailable: libavutil-wamnative.61.dylib";
  codecHandle = dlopen(codec.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!codecHandle) return "DecoderUnavailable: libavcodec-wamnative.63.dylib";
  table.avcodec_version = reinterpret_cast<decltype(table.avcodec_version)>(dlsym(codecHandle, "avcodec_version"));
  if (!table.avcodec_version) return "DecoderUnavailable: missing avcodec_version";
  table.avutil_version = reinterpret_cast<decltype(table.avutil_version)>(dlsym(utilHandle, "avutil_version"));
  if (!table.avutil_version) return "DecoderUnavailable: missing avutil_version";
  table.avcodec_license = reinterpret_cast<decltype(table.avcodec_license)>(dlsym(codecHandle, "avcodec_license"));
  if (!table.avcodec_license) return "DecoderUnavailable: missing avcodec_license";
  table.avutil_license = reinterpret_cast<decltype(table.avutil_license)>(dlsym(utilHandle, "avutil_license"));
  if (!table.avutil_license) return "DecoderUnavailable: missing avutil_license";
  table.avcodec_configuration = reinterpret_cast<decltype(table.avcodec_configuration)>(dlsym(codecHandle, "avcodec_configuration"));
  if (!table.avcodec_configuration) return "DecoderUnavailable: missing avcodec_configuration";
  table.avutil_configuration = reinterpret_cast<decltype(table.avutil_configuration)>(dlsym(utilHandle, "avutil_configuration"));
  if (!table.avutil_configuration) return "DecoderUnavailable: missing avutil_configuration";
  table.avcodec_find_decoder = reinterpret_cast<decltype(table.avcodec_find_decoder)>(dlsym(codecHandle, "avcodec_find_decoder"));
  if (!table.avcodec_find_decoder) return "DecoderUnavailable: missing avcodec_find_decoder";
  table.avcodec_alloc_context3 = reinterpret_cast<decltype(table.avcodec_alloc_context3)>(dlsym(codecHandle, "avcodec_alloc_context3"));
  if (!table.avcodec_alloc_context3) return "DecoderUnavailable: missing avcodec_alloc_context3";
  table.av_packet_alloc = reinterpret_cast<decltype(table.av_packet_alloc)>(dlsym(codecHandle, "av_packet_alloc"));
  if (!table.av_packet_alloc) return "DecoderUnavailable: missing av_packet_alloc";
  table.av_frame_alloc = reinterpret_cast<decltype(table.av_frame_alloc)>(dlsym(utilHandle, "av_frame_alloc"));
  if (!table.av_frame_alloc) return "DecoderUnavailable: missing av_frame_alloc";
  table.av_channel_layout_default = reinterpret_cast<decltype(table.av_channel_layout_default)>(dlsym(utilHandle, "av_channel_layout_default"));
  if (!table.av_channel_layout_default) return "DecoderUnavailable: missing av_channel_layout_default";
  table.av_mallocz = reinterpret_cast<decltype(table.av_mallocz)>(dlsym(utilHandle, "av_mallocz"));
  if (!table.av_mallocz) return "DecoderUnavailable: missing av_mallocz";
  table.av_buffer_create = reinterpret_cast<decltype(table.av_buffer_create)>(dlsym(utilHandle, "av_buffer_create"));
  if (!table.av_buffer_create) return "DecoderUnavailable: missing av_buffer_create";
  table.avcodec_open2 = reinterpret_cast<decltype(table.avcodec_open2)>(dlsym(codecHandle, "avcodec_open2"));
  if (!table.avcodec_open2) return "DecoderUnavailable: missing avcodec_open2";
  table.av_frame_unref = reinterpret_cast<decltype(table.av_frame_unref)>(dlsym(utilHandle, "av_frame_unref"));
  if (!table.av_frame_unref) return "DecoderUnavailable: missing av_frame_unref";
  table.avcodec_receive_frame = reinterpret_cast<decltype(table.avcodec_receive_frame)>(dlsym(codecHandle, "avcodec_receive_frame"));
  if (!table.avcodec_receive_frame) return "DecoderUnavailable: missing avcodec_receive_frame";
  table.av_buffer_get_ref_count = reinterpret_cast<decltype(table.av_buffer_get_ref_count)>(dlsym(utilHandle, "av_buffer_get_ref_count"));
  if (!table.av_buffer_get_ref_count) return "DecoderUnavailable: missing av_buffer_get_ref_count";
  table.av_buffer_ref = reinterpret_cast<decltype(table.av_buffer_ref)>(dlsym(utilHandle, "av_buffer_ref"));
  if (!table.av_buffer_ref) return "DecoderUnavailable: missing av_buffer_ref";
  table.avcodec_send_packet = reinterpret_cast<decltype(table.avcodec_send_packet)>(dlsym(codecHandle, "avcodec_send_packet"));
  if (!table.avcodec_send_packet) return "DecoderUnavailable: missing avcodec_send_packet";
  table.av_packet_unref = reinterpret_cast<decltype(table.av_packet_unref)>(dlsym(codecHandle, "av_packet_unref"));
  if (!table.av_packet_unref) return "DecoderUnavailable: missing av_packet_unref";
  table.av_frame_free = reinterpret_cast<decltype(table.av_frame_free)>(dlsym(utilHandle, "av_frame_free"));
  if (!table.av_frame_free) return "DecoderUnavailable: missing av_frame_free";
  table.av_packet_free = reinterpret_cast<decltype(table.av_packet_free)>(dlsym(codecHandle, "av_packet_free"));
  if (!table.av_packet_free) return "DecoderUnavailable: missing av_packet_free";
  table.avcodec_free_context = reinterpret_cast<decltype(table.avcodec_free_context)>(dlsym(codecHandle, "avcodec_free_context"));
  if (!table.avcodec_free_context) return "DecoderUnavailable: missing avcodec_free_context";
  table.av_buffer_unref = reinterpret_cast<decltype(table.av_buffer_unref)>(dlsym(utilHandle, "av_buffer_unref"));
  if (!table.av_buffer_unref) return "DecoderUnavailable: missing av_buffer_unref";
  table.av_channel_layout_channel_from_index = reinterpret_cast<decltype(table.av_channel_layout_channel_from_index)>(dlsym(utilHandle, "av_channel_layout_channel_from_index"));
  if (!table.av_channel_layout_channel_from_index) return "DecoderUnavailable: missing av_channel_layout_channel_from_index";
  table.av_get_packed_sample_fmt = reinterpret_cast<decltype(table.av_get_packed_sample_fmt)>(dlsym(utilHandle, "av_get_packed_sample_fmt"));
  if (!table.av_get_packed_sample_fmt) return "DecoderUnavailable: missing av_get_packed_sample_fmt";
  table.av_get_bytes_per_sample = reinterpret_cast<decltype(table.av_get_bytes_per_sample)>(dlsym(utilHandle, "av_get_bytes_per_sample"));
  if (!table.av_get_bytes_per_sample) return "DecoderUnavailable: missing av_get_bytes_per_sample";
  table.av_sample_fmt_is_planar = reinterpret_cast<decltype(table.av_sample_fmt_is_planar)>(dlsym(utilHandle, "av_sample_fmt_is_planar"));
  if (!table.av_sample_fmt_is_planar) return "DecoderUnavailable: missing av_sample_fmt_is_planar";
  table.av_frame_get_buffer = reinterpret_cast<decltype(table.av_frame_get_buffer)>(dlsym(utilHandle, "av_frame_get_buffer"));
  if (!table.av_frame_get_buffer) return "DecoderUnavailable: missing av_frame_get_buffer";
  if (foreignClosurePresent()) return "DecoderUnavailable: PlaybackFfmpegClosureConflict";
  return validate();
}
}
const Api& api() noexcept { return table; }
RuntimeLease::~RuntimeLease() { release(); }
const char* RuntimeLease::acquire() noexcept {
  if (held_) return nullptr;
  std::lock_guard lock(playbackClosureMutex());
  if (!leases) {
    const char* failure{};
    try { failure = load(); } catch (...) { failure = "DecoderUnavailable: native FFmpeg load exception"; }
    if (failure) { unload(); return failure; }
  }
  ++leases; held_ = true; return nullptr;
}
void RuntimeLease::release() noexcept {
  if (!held_) return;
  std::lock_guard lock(playbackClosureMutex());
  held_ = false;
  if (!--leases) unload();
}
const char* runtimeFailure() noexcept { RuntimeLease lease; return lease.acquire(); }
}
