#include "state_store.hpp"

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <string_view>

namespace wam {
namespace {

std::string_view themeName(AppearanceTheme theme) {
  switch (theme) {
    case AppearanceTheme::Dark:
      return "dark";
    case AppearanceTheme::System:
      return "system";
    case AppearanceTheme::Light:
    default:
      return "light";
  }
}

bool parseTheme(std::string_view value, AppearanceTheme& theme) {
  if (value == "light" || value == "0") {
    theme = AppearanceTheme::Light;
    return true;
  }
  if (value == "dark" || value == "1") {
    theme = AppearanceTheme::Dark;
    return true;
  }
  if (value == "system" || value == "2") {
    theme = AppearanceTheme::System;
    return true;
  }
  return false;
}

}  // namespace

StateStore::StateStore(std::filesystem::path path) : path_(std::move(path)) {}

std::filesystem::path StateStore::defaultPath() {
#ifdef _WIN32
  if (const char* appdata = std::getenv("APPDATA")) return std::filesystem::path(appdata) / "WAM" / "state.tsv";
#elif defined(__APPLE__)
  if (const char* user_home = std::getenv("HOME"))
    return std::filesystem::path(user_home) / "Library/Application Support/WAM/state.tsv";
#else
  if (const char* xdg = std::getenv("XDG_STATE_HOME")) return std::filesystem::path(xdg) / "wam/state.tsv";
  if (const char* user_home = std::getenv("HOME")) return std::filesystem::path(user_home) / ".local/state/wam/state.tsv";
#endif
  return std::filesystem::temp_directory_path() / "wam-state.tsv";
}

bool StateStore::load() {
  std::ifstream input(path_);
  if (!input) return false;
  std::string key;
  while (input >> key) {
    if (key == "volume") {
      input >> state_.volume;
      state_.volume = std::clamp(state_.volume, 0, 200);
    } else if (key == "profile") {
      input >> state_.performance_profile;
      state_.performance_profile = std::clamp(state_.performance_profile, 0, 2);
    } else if (key == "restore") {
      int value = 1;
      input >> value;
      state_.restore_positions = value != 0;
    } else if (key == "theme") {
      std::string value;
      input >> value;
      AppearanceTheme parsed = AppearanceTheme::Light;
      if (parseTheme(value, parsed)) state_.appearance_theme = parsed;
    } else if (key == "position") {
      std::string source;
      double seconds = 0;
      input >> std::quoted(source) >> seconds;
      if (!source.empty() && seconds >= 0) state_.positions[source] = seconds;
    } else {
      std::string ignored;
      std::getline(input, ignored);
    }
  }
  return true;
}

bool StateStore::save() const {
  std::error_code error;
  std::filesystem::create_directories(path_.parent_path(), error);
  if (error) return false;
  const auto temporary = path_.string() + ".tmp";
  {
    std::ofstream output(temporary, std::ios::trunc);
    if (!output) return false;
    output << "volume " << state_.volume << '\n';
    output << "profile " << state_.performance_profile << '\n';
    output << "restore " << (state_.restore_positions ? 1 : 0) << '\n';
    output << "theme " << themeName(state_.appearance_theme) << '\n';
    for (const auto& [source, seconds] : state_.positions)
      output << "position " << std::quoted(source) << ' ' << seconds << '\n';
  }
  std::filesystem::rename(temporary, path_, error);
  if (!error) return true;
  std::filesystem::remove(path_, error);
  error.clear();
  std::filesystem::rename(temporary, path_, error);
  return !error;
}

double StateStore::positionFor(const std::string& source) const {
  if (!state_.restore_positions) return 0;
  const auto found = state_.positions.find(source);
  return found == state_.positions.end() ? 0 : found->second;
}

void StateStore::remember(const std::string& source, double seconds) {
  if (source.empty() || source.find("://") != std::string::npos || seconds < 5.0) return;
  state_.positions[source] = seconds;
  if (state_.positions.size() > 200) state_.positions.erase(state_.positions.begin());
}

void StateStore::forget(const std::string& source) { state_.positions.erase(source); }

}  // namespace wam
