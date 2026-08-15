#include "qt/mpv_hwdec_interop_policy.hpp"

#include <cstdlib>
#include <string_view>

using wam::qt::kMpvHwdecInteropHostPlatform;
using wam::qt::mpvGpuHwdecInterop;
using wam::qt::MpvHwdecInteropPlatform;

static_assert(std::string_view(
                  mpvGpuHwdecInterop(MpvHwdecInteropPlatform::MacOS)) ==
              "videotoolbox");
static_assert(std::string_view(
                  mpvGpuHwdecInterop(MpvHwdecInteropPlatform::Other)) ==
              "auto");

#if defined(__APPLE__)
static_assert(kMpvHwdecInteropHostPlatform ==
              MpvHwdecInteropPlatform::MacOS);
#else
static_assert(kMpvHwdecInteropHostPlatform ==
              MpvHwdecInteropPlatform::Other);
#endif

int main() { return EXIT_SUCCESS; }
