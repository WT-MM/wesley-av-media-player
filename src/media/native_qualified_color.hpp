#pragma once
#include <cstdint>
namespace wam::media {
// Only the retained HLG display qualification's exact ambient payload is admitted.
inline constexpr std::uint64_t kQualifiedHlgAmbientViewingEnvironment = 0x002fe9a03d134042ULL;
}
