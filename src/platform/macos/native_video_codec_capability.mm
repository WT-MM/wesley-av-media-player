#include "native_video_codec_capability.hpp"

#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

#include <mutex>

namespace wam::macos {
namespace {

struct SupplementalDecoderCapability {
  bool vp9{false};
  bool av1{false};
};

SupplementalDecoderCapability gCapability{};
std::once_flag gCapabilityOnce;

// VTRegisterSupplementalVideoDecoderIfAvailable must run before the first
// VTIsHardwareDecodeSupported query: on stock macOS the VP9 decoder is not
// reported as supported until it has been registered. Registration is
// idempotent but is kept to a single call so the probe order is provable.
// AV1 is registered for symmetry; on machines that ship an AV1 block the call
// is a no-op, and on machines that do not it leaves the answer false.
void resolveCapability() noexcept {
  VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
  VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1);
  gCapability.vp9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) != 0;
  gCapability.av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) != 0;
}

const SupplementalDecoderCapability& capability() noexcept {
  std::call_once(gCapabilityOnce, resolveCapability);
  return gCapability;
}

}  // namespace

bool nativeVideoToolboxSupportsVp9() noexcept { return capability().vp9; }

bool nativeVideoToolboxSupportsAv1() noexcept { return capability().av1; }

}  // namespace wam::macos
