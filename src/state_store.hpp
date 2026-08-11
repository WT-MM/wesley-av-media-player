#pragma once

#include <filesystem>
#include <string>
#include <unordered_map>

namespace wam {

enum class AppearanceTheme {
  Light = 0,
  Dark = 1,
  System = 2,
};

struct PersistentState {
  int volume = 100;
  int performance_profile = 1;
  bool restore_positions = true;
  AppearanceTheme appearance_theme = AppearanceTheme::Light;
  std::unordered_map<std::string, double> positions;
};

class StateStore {
 public:
  explicit StateStore(std::filesystem::path path = defaultPath());

  static std::filesystem::path defaultPath();
  bool load();
  bool save() const;
  double positionFor(const std::string& source) const;
  void remember(const std::string& source, double seconds);
  void forget(const std::string& source);

  PersistentState& state() { return state_; }
  const PersistentState& state() const { return state_; }
  const std::filesystem::path& path() const { return path_; }

 private:
  std::filesystem::path path_;
  PersistentState state_;
};

}  // namespace wam
