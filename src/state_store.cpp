#include "state_store.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>
#include <string_view>
#include <system_error>

namespace wam {
namespace {

constexpr std::size_t kMaxLineBytes =
    2U * StateStore::kMaxSourceBytes + 128U;
constexpr std::size_t kMaxRecords = StateStore::kMaxPositions + 32U;

bool lineSafeSource(std::string_view source) noexcept {
  return std::none_of(source.begin(), source.end(), [](char character) {
    return character == '\n' || character == '\r' || character == '\0';
  });
}

void trimLeft(std::string_view& value) {
  const auto first = value.find_first_not_of(" \t\r");
  value.remove_prefix(first == std::string_view::npos ? value.size() : first);
}

void trim(std::string_view& value) {
  trimLeft(value);
  const auto last = value.find_last_not_of(" \t\r");
  if (last == std::string_view::npos) {
    value = {};
    return;
  }
  value.remove_suffix(value.size() - last - 1U);
}

std::string_view takeToken(std::string_view& input) {
  trimLeft(input);
  const auto end = input.find_first_of(" \t\r");
  if (end == std::string_view::npos) {
    const auto token = input;
    input = {};
    return token;
  }
  const auto token = input.substr(0, end);
  input.remove_prefix(end);
  return token;
}

template <typename Number>
bool parseNumber(std::string_view input, Number& result) {
  trim(input);
  if (input.empty()) return false;
  Number parsed{};
  const auto [end, error] =
      std::from_chars(input.data(), input.data() + input.size(), parsed);
  if (error != std::errc{} || end != input.data() + input.size()) return false;
  result = parsed;
  return true;
}

bool parseNumber(std::string_view input, double& result) {
  trim(input);
  if (input.empty()) return false;

  // Floating-point std::from_chars is unavailable at WAM's macOS 13
  // deployment target. The copied token is bounded by kMaxLineBytes, and a
  // fixed classic locale keeps state files independent of the user's decimal
  // separator.
  std::istringstream stream{std::string(input)};
  stream.imbue(std::locale::classic());
  double parsed = 0.0;
  stream >> parsed;
  if (!stream) return false;
  stream >> std::ws;
  if (!stream.eof()) return false;
  result = parsed;
  return true;
}

bool parseQuotedSource(std::string_view& input, std::string& source) {
  trimLeft(input);
  if (input.empty() || input.front() != '"') return false;
  input.remove_prefix(1);
  source.clear();
  source.reserve(std::min(input.size(), StateStore::kMaxSourceBytes));

  while (!input.empty()) {
    char character = input.front();
    input.remove_prefix(1);
    if (character == '"') return true;
    if (character == '\\') {
      if (input.empty()) return false;
      character = input.front();
      input.remove_prefix(1);
    }
    if (source.size() == StateStore::kMaxSourceBytes) return false;
    source.push_back(character);
  }
  return false;
}

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

bool parseRecord(std::string_view line, PersistentState& state,
                 std::size_t& position_records) {
  const std::string_view key = takeToken(line);
  if (key.empty()) return true;

  if (key == "volume") {
    int value = 0;
    if (!parseNumber(line, value)) return false;
    state.volume = std::clamp(value, 0, 200);
    return true;
  }
  if (key == "profile") {
    int value = 0;
    if (!parseNumber(line, value)) return false;
    state.performance_profile = std::clamp(value, 0, 2);
    return true;
  }
  if (key == "restore") {
    int value = 0;
    if (!parseNumber(line, value)) return false;
    state.restore_positions = value != 0;
    return true;
  }
  if (key == "seek_step") {
    int value = 0;
    if (!parseNumber(line, value)) return false;
    state.seek_step_seconds = std::clamp(value, 1, 60);
    return true;
  }
  if (key == "hugs_video") {
    int value = 0;
    if (!parseNumber(line, value)) return false;
    state.window_hugs_video = value != 0;
    return true;
  }
  if (key == "preserve_pitch") {
    int value = 0;
    if (!parseNumber(line, value)) return false;
    state.preserve_pitch = value != 0;
    return true;
  }
  if (key == "theme") {
    const std::string_view value = takeToken(line);
    trim(line);
    AppearanceTheme parsed = AppearanceTheme::Light;
    if (value.empty() || !line.empty() || !parseTheme(value, parsed))
      return false;
    state.appearance_theme = parsed;
    return true;
  }
  if (key != "position") {
    // Unknown records are ignored for forward compatibility, but still count
    // toward the bounded record and byte budgets enforced by load().
    return true;
  }

  if (position_records == StateStore::kMaxPositions) return false;
  ++position_records;
  std::string source;
  if (!parseQuotedSource(line, source) || source.empty() ||
      !lineSafeSource(source))
    return false;
  double seconds = 0.0;
  if (!parseNumber(line, seconds) || !std::isfinite(seconds) || seconds < 0.0)
    return false;
  state.positions.insert_or_assign(std::move(source), seconds);
  return true;
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
  std::ifstream input(path_, std::ios::binary);
  if (!input) return false;

  bool valid = true;
  std::error_code size_error;
  const auto file_bytes = std::filesystem::file_size(path_, size_error);
  if (!size_error && file_bytes > kMaxFileBytes) valid = false;

  PersistentState loaded;
  std::size_t position_records = 0;
  std::size_t record_count = 0;
  std::uintmax_t bytes_read = 0;
  std::array<char, kMaxLineBytes + 1U> line_buffer{};

  while (record_count < kMaxRecords && bytes_read <= kMaxFileBytes) {
    input.getline(line_buffer.data(),
                  static_cast<std::streamsize>(line_buffer.size()));
    const auto extracted = input.gcount();
    if (extracted <= 0) break;

    const auto extracted_bytes = static_cast<std::uintmax_t>(extracted);
    if (extracted_bytes > kMaxFileBytes - bytes_read) {
      valid = false;
      break;
    }
    bytes_read += extracted_bytes;

    if (input.fail() && !input.eof()) {
      // A record exceeded the fixed line buffer. Do not scan the remainder of
      // an attacker-controlled line looking for a delimiter.
      valid = false;
      break;
    }

    std::size_t line_size = static_cast<std::size_t>(extracted);
    if (!input.eof() && line_size > 0U) --line_size;  // getline consumed '\n'.
    if (std::memchr(line_buffer.data(), '\0', line_size) != nullptr) {
      valid = false;
      break;
    }
    ++record_count;
    if (!parseRecord(
            std::string_view(line_buffer.data(), line_size), loaded,
            position_records))
      valid = false;
  }

  if (input.bad()) valid = false;
  if (record_count == kMaxRecords && input.peek() != std::char_traits<char>::eof())
    valid = false;

  // Resume positions are expendable cache data. A partially parsed cache can
  // seek to the wrong place, so retain valid core preferences but discard all
  // positions if any record or size limit failed.
  if (!valid) loaded.positions.clear();
  state_ = std::move(loaded);
  rewrite_required_ = !valid;
  if (valid) persisted_state_ = state_;
  return valid;
}

bool StateStore::save() const {
  // Serialize a stable snapshot and mark only that snapshot as persisted. If
  // state changes while the filesystem operation is in progress, dirty()
  // therefore remains true and the checkpoint gate will schedule it again.
  const PersistentState snapshot = state_;
  if (snapshot.positions.size() > kMaxPositions) return false;
  for (const auto& [source, seconds] : snapshot.positions) {
    if (source.empty() || source.size() > kMaxSourceBytes ||
        !lineSafeSource(source) ||
        !std::isfinite(seconds) || seconds < 0.0)
      return false;
  }

  std::error_code error;
  std::filesystem::create_directories(path_.parent_path(), error);
  if (error) return false;
  const auto temporary = path_.string() + ".tmp";
  {
    std::ofstream output(temporary, std::ios::trunc);
    if (!output) return false;
    output.imbue(std::locale::classic());
    output << "volume " << snapshot.volume << '\n';
    output << "profile " << snapshot.performance_profile << '\n';
    output << "restore " << (snapshot.restore_positions ? 1 : 0) << '\n';
    output << "theme " << themeName(snapshot.appearance_theme) << '\n';
    output << "seek_step " << snapshot.seek_step_seconds << '\n';
    output << "hugs_video " << (snapshot.window_hugs_video ? 1 : 0) << '\n';
    output << "preserve_pitch " << (snapshot.preserve_pitch ? 1 : 0) << '\n';
    for (const auto& [source, seconds] : snapshot.positions)
      output << "position " << std::quoted(source) << ' ' << seconds << '\n';
    output.flush();
    if (!output) return false;
    output.close();
    if (!output) return false;
  }
  std::filesystem::rename(temporary, path_, error);
  if (error) {
    std::filesystem::remove(path_, error);
    error.clear();
    std::filesystem::rename(temporary, path_, error);
    if (error) return false;
  }
  persisted_state_ = snapshot;
  rewrite_required_ = false;
  return true;
}

bool StateStore::dirty() const {
  return rewrite_required_ || state_ != persisted_state_;
}

double StateStore::positionFor(const std::string& source) const {
  if (!state_.restore_positions) return 0;
  const auto found = state_.positions.find(source);
  return found == state_.positions.end() ? 0 : found->second;
}

void StateStore::remember(const std::string& source, double seconds) {
  if (source.empty() || source.size() > kMaxSourceBytes ||
      !lineSafeSource(source) || source.find("://") != std::string::npos ||
      !std::isfinite(seconds) || seconds < 5.0)
    return;
  state_.positions[source] = seconds;
  if (state_.positions.size() > kMaxPositions)
    state_.positions.erase(state_.positions.begin());
}

void StateStore::forget(const std::string& source) { state_.positions.erase(source); }

}  // namespace wam
