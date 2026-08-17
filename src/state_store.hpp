#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
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
  // Left/Right arrow (and the transport's skip buttons) step by this many
  // seconds. Whole seconds only, clamped to [1, 60]; the Preferences window
  // offers 5/10/15/30 as one-click presets plus free entry across that range.
  int seek_step_seconds = 5;
  // QuickTime-style floating window: when true, the windowed (non-fullscreen)
  // frame is continuously kept at the current video's aspect ratio so
  // playback never shows letterbox bars, re-snapping after any resize that
  // would otherwise leave one. Default on, since that is the behavior the
  // Preferences window frames as the norm; off restores free-form resizing
  // where bars can appear. Fullscreen is unaffected either way.
  bool window_hugs_video = true;
  std::unordered_map<std::string, double> positions;

  bool operator==(const PersistentState&) const = default;
};

// Coalesces persistence work without owning a clock or event loop. The first
// mutation asks the caller to arm one timer. Mutations while that timer is
// armed do not restart it, so a continuously changing playhead still produces
// at most one checkpoint per interval. A mutation made re-entrantly by the
// save operation remains pending and asks for a fresh timer after the save.
class StateCheckpointGate {
 public:
  static constexpr auto kInterval = std::chrono::seconds(10);

  [[nodiscard]] bool request() noexcept {
    dirty_ = true;
    if (timer_armed_ || saving_) return false;
    timer_armed_ = true;
    return true;
  }

  template <typename Save>
  [[nodiscard]] bool checkpoint(Save&& save) {
    timer_armed_ = false;
    dirty_ = false;
    saving_ = true;

    bool succeeded = false;
    try {
      succeeded = static_cast<bool>(save());
    } catch (...) {
      saving_ = false;
      dirty_ = true;
      timer_armed_ = true;
      throw;
    }

    saving_ = false;
    if (!succeeded) dirty_ = true;
    if (!dirty_) return false;
    timer_armed_ = true;
    return true;
  }

  // Shutdown cannot wait for another timer. Run at least once so the caller
  // can capture live state, then repeat synchronously only when that capture
  // itself caused another mutation. This makes the final successful save an
  // exact snapshot of everything observed before event-loop shutdown.
  template <typename Save>
  [[nodiscard]] bool flushNow(Save&& save) {
    timer_armed_ = false;
    auto&& operation = save;
    do {
      dirty_ = false;
      saving_ = true;

      bool succeeded = false;
      try {
        succeeded = static_cast<bool>(operation());
      } catch (...) {
        saving_ = false;
        dirty_ = true;
        throw;
      }

      saving_ = false;
      if (!succeeded) {
        dirty_ = true;
        return false;
      }
    } while (dirty_);
    return true;
  }

  [[nodiscard]] bool timerArmed() const noexcept { return timer_armed_; }
  [[nodiscard]] bool dirty() const noexcept { return dirty_; }
  [[nodiscard]] bool saving() const noexcept { return saving_; }

 private:
  bool dirty_ = false;
  bool timer_armed_ = false;
  bool saving_ = false;
};

class StateStore {
 public:
  static constexpr std::size_t kMaxPositions = 200;
  static constexpr std::size_t kMaxSourceBytes = 4096;
  static constexpr std::uintmax_t kMaxFileBytes = 2U * 1024U * 1024U;

  explicit StateStore(std::filesystem::path path = defaultPath());

  static std::filesystem::path defaultPath();
  bool load();
  bool save() const;
  bool dirty() const;
  double positionFor(const std::string& source) const;
  void remember(const std::string& source, double seconds);
  void forget(const std::string& source);

  PersistentState& state() { return state_; }
  const PersistentState& state() const { return state_; }
  const std::filesystem::path& path() const { return path_; }

 private:
  std::filesystem::path path_;
  PersistentState state_;
  mutable PersistentState persisted_state_;
  mutable bool rewrite_required_ = false;
};

}  // namespace wam
