#pragma once

#include <cstdlib>
#include <initializer_list>
#include <cstring>

namespace wam {

// The truth vocabulary for every WAM_* environment opt-in: "1", "true",
// "yes", "on" and their upper-case forms read as enabled; an unset variable
// and anything else -- including "0" and junk -- read as off.
[[nodiscard]] inline bool wamEnvironmentTruth(const char *name) noexcept {
  const char *const value = std::getenv(name);
  if (value == nullptr) {
    return false;
  }
  for (const char *truth : {"1", "true", "TRUE", "yes", "YES", "on", "ON"}) {
    if (std::strcmp(value, truth) == 0) {
      return true;
    }
  }
  return false;
}

} // namespace wam
