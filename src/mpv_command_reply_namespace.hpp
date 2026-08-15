#pragma once

#include <cstdint>

namespace wam::mpv_reply {

// PlayerController's asynchronous command routes reserve the two most
// significant userdata bits as a disjoint namespace.  Keep this layout in a
// Qt-independent header so dormant native-video ports can validate a reply
// identity without depending on PlayerController.
constexpr std::uint64_t kNamespaceMask = 3ULL << 62;
constexpr std::uint64_t kNamespaceValueMask = (1ULL << 62) - 1ULL;

constexpr std::uint64_t kObservedPropertyNamespace = 0;
constexpr std::uint64_t kRenderRecoveryNamespace = 1ULL << 62;
constexpr std::uint64_t kOpenNamespace = 1ULL << 63;
constexpr std::uint64_t kNativeVideoAdapterNamespace = 3ULL << 62;

// Open and scrub replies share the top-bit namespace.  Scrub dedicates bit 61
// and both routes consequently use only the lower 61 bits for their IDs.
constexpr std::uint64_t kOpenFamilyTag = 1ULL << 61;
constexpr std::uint64_t kOpenFamilyValueMask = (1ULL << 61) - 1ULL;
constexpr std::uint64_t kScrubCommandTag =
    kOpenNamespace | kOpenFamilyTag;
constexpr std::uint64_t kScrubCommandMask =
    kNamespaceMask | kOpenFamilyTag;

enum class Namespace : std::uint8_t {
  ObservedProperty,
  RenderRecovery,
  Open,
  NativeVideoAdapter,
};

[[nodiscard]] constexpr Namespace classify(std::uint64_t userdata) noexcept {
  switch (userdata & kNamespaceMask) {
  case kRenderRecoveryNamespace:
    return Namespace::RenderRecovery;
  case kOpenNamespace:
    return Namespace::Open;
  case kNativeVideoAdapterNamespace:
    return Namespace::NativeVideoAdapter;
  default:
    return Namespace::ObservedProperty;
  }
}

[[nodiscard]] constexpr bool
isNativeVideoAdapter(std::uint64_t userdata) noexcept {
  return classify(userdata) == Namespace::NativeVideoAdapter &&
         (userdata & kNamespaceValueMask) != 0;
}

static_assert((kRenderRecoveryNamespace & kNamespaceMask) !=
              (kOpenNamespace & kNamespaceMask));
static_assert((kRenderRecoveryNamespace & kNamespaceMask) !=
              (kNativeVideoAdapterNamespace & kNamespaceMask));
static_assert((kOpenNamespace & kNamespaceMask) !=
              (kNativeVideoAdapterNamespace & kNamespaceMask));
static_assert((kScrubCommandTag & kNamespaceMask) == kOpenNamespace);
static_assert((kScrubCommandTag & kScrubCommandMask) == kScrubCommandTag);

} // namespace wam::mpv_reply
