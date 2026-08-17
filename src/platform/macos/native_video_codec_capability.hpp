#pragma once

namespace wam::macos {

// Single machine-capability authority for the two codecs VideoToolbox does not
// admit unconditionally.
//
// AV1 hardware decode exists only on Apple silicon from M3 onward, and VP9 is
// gated behind a supplemental decoder that VideoToolbox refuses to report as
// supported until the process has registered it. Both facts are process-wide
// and immutable, so they are probed exactly once (registering the supplemental
// decoders before the first query) and cached.
//
// Every VP9/AV1 admission site in the native lane consults these helpers, so a
// machine without the hardware refuses the track at admission time and falls
// back cleanly instead of failing later inside decompression-session creation.
[[nodiscard]] bool nativeVideoToolboxSupportsVp9() noexcept;
[[nodiscard]] bool nativeVideoToolboxSupportsAv1() noexcept;

}  // namespace wam::macos
