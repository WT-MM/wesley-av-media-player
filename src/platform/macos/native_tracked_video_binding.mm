#include "native_tracked_video_binding.hpp"
#include "native_layer_video_output.hpp"
#include "native_qt_gl_output.hpp"
#include <type_traits>

namespace wam::macos {
NativeTrackedVideoBinding::NativeTrackedVideoBinding(
    NativeTrackedVideoOutput* output) noexcept : route_(output) {
  if (auto* layer = dynamic_cast<NativeLayerVideoOutput*>(output)) {
    route_ = layer;
  } else if (auto* scenegraph = dynamic_cast<NativeQtGlOutput*>(output)) {
    route_ = scenegraph;
  } else if (auto* main = dynamic_cast<NativeTrackedVideoArbiter::MainOutput*>(output)) {
    route_ = main;
  }
}

NativeTrackedVideoBinding::Kind NativeTrackedVideoBinding::kind() const noexcept {
  return static_cast<Kind>(route_.index());
}

namespace {
template<class Route, class Call>
auto dispatch(const Route& route, Call call) noexcept {
  if (const auto* layer = std::get_if<NativeLayerVideoOutput*>(&route)) {
    return call(*layer);
  }
  if (const auto* scenegraph = std::get_if<NativeQtGlOutput*>(&route)) {
    return call(*scenegraph);
  }
  if (const auto* main = std::get_if<NativeTrackedVideoArbiter::MainOutput*>(&route)) {
    return call(*main);
  }
  return call(*std::get_if<NativeTrackedVideoOutput*>(&route));
}
}  // namespace

NativeTrackedVideoCapacity NativeTrackedVideoBinding::capacity(std::uint64_t generation) const noexcept {
  return dispatch(route_, [&](auto* output) noexcept {
    using Output = std::remove_pointer_t<decltype(output)>;
    if constexpr (std::is_same_v<Output, NativeTrackedVideoOutput>) {
      return output->capacity(generation);
    } else {
      return output->Output::capacity(generation);
    }
  });
}

NativeTrackedVideoSubmitStatus NativeTrackedVideoBinding::submit(const FrameLease& frame, NativeTrackedFrameSequence sequence, std::string* error) noexcept {
  return dispatch(route_, [&](auto* output) noexcept {
    using Output = std::remove_pointer_t<decltype(output)>;
    if constexpr (std::is_same_v<Output, NativeTrackedVideoOutput>) {
      return output->submit(frame, sequence, error);
    } else {
      return output->Output::submit(frame, sequence, error);
    }
  });
}

std::optional<NativeTrackedVideoEvent> NativeTrackedVideoBinding::takeEvent() noexcept {
  return dispatch(route_, [&](auto* output) noexcept {
    using Output = std::remove_pointer_t<decltype(output)>;
    if constexpr (std::is_same_v<Output, NativeTrackedVideoOutput>) {
      return output->takeEvent();
    } else {
      return output->Output::takeEvent();
    }
  });
}

NativeTrackedVideoOutputProgress NativeTrackedVideoBinding::flushProgress(std::uint64_t retiredGeneration, std::uint64_t nextGeneration) noexcept {
  return dispatch(route_, [&](auto* output) noexcept {
    using Output = std::remove_pointer_t<decltype(output)>;
    if constexpr (std::is_same_v<Output, NativeTrackedVideoOutput>) {
      return output->flushProgress(retiredGeneration, nextGeneration);
    } else {
      return output->Output::flushProgress(retiredGeneration, nextGeneration);
    }
  });
}

NativeTrackedVideoOutputProgress NativeTrackedVideoBinding::closeProgress(std::uint64_t finalGeneration) noexcept {
  return dispatch(route_, [&](auto* output) noexcept {
    using Output = std::remove_pointer_t<decltype(output)>;
    if constexpr (std::is_same_v<Output, NativeTrackedVideoOutput>) {
      return output->closeProgress(finalGeneration);
    } else {
      return output->Output::closeProgress(finalGeneration);
    }
  });
}

bool NativeTrackedVideoBinding::presentsDecodedSurfacesDirectly() const noexcept {
  return dispatch(route_, [&](auto* output) noexcept {
    using Output = std::remove_pointer_t<decltype(output)>;
    if constexpr (std::is_same_v<Output, NativeTrackedVideoOutput>) {
      return output->presentsDecodedSurfacesDirectly();
    } else {
      return output->Output::presentsDecodedSurfacesDirectly();
    }
  });
}

bool NativeTrackedVideoBinding::setPresentationRotation(int degrees) noexcept {
  return dispatch(route_, [&](auto* output) noexcept {
    using Output = std::remove_pointer_t<decltype(output)>;
    if constexpr (std::is_same_v<Output, NativeTrackedVideoOutput>) {
      return output->setPresentationRotation(degrees);
    } else {
      return output->Output::setPresentationRotation(degrees);
    }
  });
}

NativeTrackedVideoOutputFacts NativeTrackedVideoBinding::facts() const noexcept {
  return dispatch(route_, [&](auto* output) noexcept {
    using Output = std::remove_pointer_t<decltype(output)>;
    if constexpr (std::is_same_v<Output, NativeTrackedVideoOutput>) {
      return output->facts();
    } else {
      return output->Output::facts();
    }
  });
}

}  // namespace wam::macos
