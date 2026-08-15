#pragma once

namespace wam::qt {

enum class MpvHwdecInteropPlatform {
  MacOS,
  Other,
};

// libmpv cannot load hardware-decoder interop backends on demand. In mpv
// 0.41, "auto" therefore eagerly probes every backend when the render context
// is created. WAM's macOS renderer consumes VideoToolbox frames through the
// matching interop and has no reason to initialize the Vulkan interop too.
// Other platforms retain mpv's existing automatic backend selection.
[[nodiscard]] constexpr const char *
mpvGpuHwdecInterop(MpvHwdecInteropPlatform platform) noexcept {
  return platform == MpvHwdecInteropPlatform::MacOS ? "videotoolbox" : "auto";
}

#if defined(__APPLE__)
inline constexpr MpvHwdecInteropPlatform kMpvHwdecInteropHostPlatform =
    MpvHwdecInteropPlatform::MacOS;
#else
inline constexpr MpvHwdecInteropPlatform kMpvHwdecInteropHostPlatform =
    MpvHwdecInteropPlatform::Other;
#endif

} // namespace wam::qt
