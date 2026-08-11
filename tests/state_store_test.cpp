#include "state_store.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>

namespace {
int failures = 0;
void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}
}  // namespace

int main() {
  const auto path = std::filesystem::temp_directory_path() / "wam-state-test.tsv";
  std::error_code error;
  std::filesystem::remove(path, error);
  wam::StateStore first(path);
  first.state().volume = 73;
  first.state().performance_profile = 0;
  first.state().appearance_theme = wam::AppearanceTheme::Dark;
  first.remember("/tmp/a file.mp4", 42.5);
  first.remember("https://example.com/live", 30.0);
  expect(first.save(), "state saves");

  wam::StateStore second(path);
  expect(second.load(), "state loads");
  expect(second.state().volume == 73, "volume round trips");
  expect(second.state().performance_profile == 0, "profile round trips");
  expect(second.state().appearance_theme == wam::AppearanceTheme::Dark,
         "theme round trips");
  expect(second.positionFor("/tmp/a file.mp4") == 42.5, "position round trips");
  expect(second.positionFor("https://example.com/live") == 0.0,
         "network positions are not persisted");

  {
    std::ofstream legacy(path, std::ios::trunc);
    legacy << "volume 55\nprofile 2\nrestore 1\n";
  }
  wam::StateStore legacy(path);
  expect(legacy.load(), "legacy state loads");
  expect(legacy.state().appearance_theme == wam::AppearanceTheme::Light,
         "legacy state defaults to light theme");

  {
    std::ofstream numeric(path, std::ios::trunc);
    numeric << "theme 2\n";
  }
  wam::StateStore numeric(path);
  expect(numeric.load(), "numeric theme state loads");
  expect(numeric.state().appearance_theme == wam::AppearanceTheme::System,
         "numeric system theme remains compatible");

  {
    std::ofstream invalid(path, std::ios::trunc);
    invalid << "theme ultraviolet\nvolume 61\n";
  }
  wam::StateStore invalid(path);
  expect(invalid.load(), "state with invalid theme loads");
  expect(invalid.state().appearance_theme == wam::AppearanceTheme::Light,
         "invalid theme safely falls back to light");
  expect(invalid.state().volume == 61,
         "invalid theme does not prevent later settings from loading");
  std::filesystem::remove(path, error);
  std::cout << "state store tests passed\n";
  return failures == 0 ? 0 : 1;
}
