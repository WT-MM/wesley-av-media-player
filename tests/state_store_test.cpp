#include "state_store.hpp"

#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <string>

namespace {
int failures = 0;
void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

struct FakeCheckpointTimer {
  using Milliseconds = std::chrono::milliseconds;

  void mutate() {
    if (gate.request()) arm();
  }

  void advance(Milliseconds elapsed) {
    const Milliseconds target = now + elapsed;
    while (deadline && *deadline <= target) {
      now = *deadline;
      deadline.reset();
      ++wakeups;
      const bool rearm = gate.checkpoint([&] {
        ++save_calls;
        if (during_save) {
          const auto callback = std::move(during_save);
          during_save = {};
          callback();
        }
        return save_succeeds;
      });
      if (rearm) arm();
    }
    now = target;
  }

  void arm() {
    deadline = now + std::chrono::duration_cast<Milliseconds>(
                         wam::StateCheckpointGate::kInterval);
    ++arm_calls;
  }

  wam::StateCheckpointGate gate;
  Milliseconds now{0};
  std::optional<Milliseconds> deadline;
  std::function<void()> during_save;
  int arm_calls = 0;
  int wakeups = 0;
  int save_calls = 0;
  bool save_succeeds = true;
};
}  // namespace

int main() {
  {
    FakeCheckpointTimer idle;
    idle.advance(std::chrono::seconds(30));
    expect(idle.arm_calls == 0, "blank idle state never arms persistence");
    expect(idle.wakeups == 0, "blank idle 30 seconds has zero timer wakeups");
    expect(idle.save_calls == 0, "blank idle 30 seconds has zero save calls");
  }

  {
    FakeCheckpointTimer active;
    active.mutate();
    active.advance(std::chrono::seconds(5));
    for (int mutation = 0; mutation < 100; ++mutation) active.mutate();
    expect(active.arm_calls == 1,
           "active mutations coalesce without restarting the timer");
    active.advance(std::chrono::seconds(5));
    expect(active.wakeups == 1 && active.save_calls == 1,
           "coalesced mutations produce one checkpoint at ten seconds");
    expect(!active.deadline && !active.gate.timerArmed(),
           "successful checkpoint returns to a fully idle state");
  }

  {
    FakeCheckpointTimer during_save;
    during_save.mutate();
    during_save.during_save = [&] { during_save.mutate(); };
    during_save.advance(std::chrono::seconds(10));
    expect(during_save.save_calls == 1 && during_save.deadline,
           "mutation during save is retained and rearms one timer");
    during_save.advance(std::chrono::seconds(9));
    expect(during_save.save_calls == 1,
           "mutation during save cannot force an early second write");
    during_save.advance(std::chrono::seconds(1));
    expect(during_save.save_calls == 2,
           "mutation during save is persisted at the next checkpoint");
  }

  {
    FakeCheckpointTimer after_save;
    after_save.mutate();
    after_save.advance(std::chrono::seconds(10));
    after_save.mutate();
    expect(after_save.deadline && after_save.arm_calls == 2,
           "mutation immediately after save arms a fresh checkpoint");
    after_save.advance(std::chrono::seconds(10));
    expect(after_save.save_calls == 2,
           "post-save mutation is not lost");
  }

  {
    FakeCheckpointTimer failed;
    failed.save_succeeds = false;
    failed.mutate();
    failed.advance(std::chrono::seconds(10));
    expect(failed.save_calls == 1 && failed.deadline,
           "failed checkpoint remains dirty and retries after ten seconds");
    failed.save_succeeds = true;
    failed.advance(std::chrono::seconds(10));
    expect(failed.save_calls == 2 && !failed.deadline,
           "successful retry clears a failed checkpoint");
  }

  {
    wam::StateCheckpointGate quitting;
    expect(quitting.request(), "quit-time mutation initially arms a timer");
    int flush_calls = 0;
    expect(quitting.flushNow([&] {
             ++flush_calls;
             if (flush_calls == 1) (void)quitting.request();
             return true;
           }),
           "quit-time exact flush succeeds");
    expect(flush_calls == 2,
           "quit-time flush includes a mutation made during its first save");
    expect(!quitting.dirty() && !quitting.timerArmed(),
           "quit-time exact flush leaves no pending checkpoint");
  }

  {
    wam::StateCheckpointGate clean_quit;
    int captures = 0;
    expect(clean_quit.flushNow([&] {
             ++captures;
             return true;
           }),
           "clean quit-time capture succeeds without an armed timer");
    expect(captures == 1,
           "quit always captures live state exactly once when stable");

    wam::StateCheckpointGate failed_quit;
    expect(failed_quit.request(), "failed quit test starts dirty");
    expect(!failed_quit.flushNow([] { return false; }),
           "quit-time save failure is reported");
    expect(failed_quit.dirty() && !failed_quit.timerArmed(),
           "quit-time save failure remains explicitly dirty");
  }

  const auto path = std::filesystem::temp_directory_path() / "wam-state-test.tsv";
  std::error_code error;
  std::filesystem::remove(path, error);

  {
    wam::StateStore only_dirty(path);
    wam::StateCheckpointGate gate;
    int disk_writes = 0;
    const auto save_if_dirty = [&] {
      if (!only_dirty.dirty()) return true;
      ++disk_writes;
      return only_dirty.save();
    };

    expect(gate.request(), "clean logical mutation arms one checkpoint");
    expect(!gate.checkpoint(save_if_dirty),
           "clean checkpoint completes without a rearm");
    expect(disk_writes == 0 && !std::filesystem::exists(path),
           "checkpoint performs no disk write while state remains clean");

    only_dirty.state().volume = 91;
    expect(gate.request(), "actual state mutation arms one checkpoint");
    expect(!gate.checkpoint(save_if_dirty),
           "dirty checkpoint completes after its disk write");
    expect(disk_writes == 1 && std::filesystem::exists(path),
           "dirty state produces exactly one disk write");
    std::filesystem::remove(path, error);
  }

  wam::PersistentState matching_left;
  wam::PersistentState matching_right;
  expect(matching_left == matching_right, "identical persistent states compare equal");
  matching_right.volume = 99;
  expect(matching_left != matching_right,
         "persistent state equality detects preference changes");

  wam::StateStore first(path);
  expect(!first.dirty(), "new state starts clean");
  first.state().volume = 73;
  first.state().performance_profile = 0;
  first.state().appearance_theme = wam::AppearanceTheme::Dark;
  first.state().seek_step_seconds = 15;
  first.state().window_hugs_video = false;
  first.remember("/tmp/a file.mp4", 42.5);
  first.remember("https://example.com/live", 30.0);
  expect(first.dirty(), "state mutation becomes dirty");
  expect(first.save(), "state saves");
  expect(!first.dirty(), "successful save clears dirty state");

  wam::StateStore second(path);
  expect(second.load(), "state loads");
  expect(!second.dirty(), "successful load establishes clean state");
  expect(second.state().volume == 73, "volume round trips");
  expect(second.state().performance_profile == 0, "profile round trips");
  expect(second.state().appearance_theme == wam::AppearanceTheme::Dark,
         "theme round trips");
  expect(second.state().seek_step_seconds == 15, "seek step round trips");
  expect(second.state().window_hugs_video == false,
         "window hugs video round trips");
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
  expect(legacy.state().seek_step_seconds == 5,
         "legacy state without seek_step defaults to five seconds");
  expect(legacy.state().window_hugs_video == true,
         "legacy state without hugs_video defaults on");

  {
    std::ofstream out_of_range(path, std::ios::trunc);
    out_of_range << "volume 80\nseek_step 999\n";
  }
  wam::StateStore out_of_range(path);
  expect(out_of_range.load(), "out-of-range seek step still loads");
  expect(out_of_range.state().seek_step_seconds == 60,
         "seek step above the bound clamps to sixty seconds");

  {
    std::ofstream below_range(path, std::ios::trunc);
    below_range << "volume 81\nseek_step 0\n";
  }
  wam::StateStore below_range(path);
  expect(below_range.load(), "below-range seek step still loads");
  expect(below_range.state().seek_step_seconds == 1,
         "seek step below the bound clamps to one second");

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
  expect(!invalid.load(), "invalid theme reports a corrupt state file");
  expect(invalid.state().appearance_theme == wam::AppearanceTheme::Light,
         "invalid theme safely falls back to light");
  expect(invalid.state().volume == 61,
         "invalid theme does not prevent later settings from loading");
  expect(invalid.state().positions.empty(),
         "corrupt state discards expendable resume positions");
  expect(invalid.dirty(), "corrupt state is marked for canonical rewrite");

  {
    std::ofstream bounded(path, std::ios::trunc);
    bounded << "volume 64\nprofile 2\nrestore 0\ntheme dark\n";
    for (std::size_t index = 0; index < wam::StateStore::kMaxPositions;
         ++index)
      bounded << "position \"/tmp/" << index << ".mp4\" " << index << '\n';
  }
  wam::StateStore bounded(path);
  expect(bounded.load(), "maximum-size position cache loads");
  expect(bounded.state().positions.size() == wam::StateStore::kMaxPositions,
         "load accepts exactly the save position bound");

  {
    std::ofstream excessive(path, std::ios::trunc);
    excessive << "volume 65\nprofile 0\nrestore 0\ntheme system\n";
    for (std::size_t index = 0; index <= wam::StateStore::kMaxPositions;
         ++index)
      excessive << "position \"/tmp/" << index << ".mkv\" " << index
                << '\n';
  }
  wam::StateStore excessive(path);
  expect(!excessive.load(), "excess position records are rejected");
  expect(excessive.state().volume == 65,
         "position overflow preserves volume preference");
  expect(excessive.state().performance_profile == 0,
         "position overflow preserves performance preference");
  expect(!excessive.state().restore_positions,
         "position overflow preserves restore preference");
  expect(excessive.state().appearance_theme == wam::AppearanceTheme::System,
         "position overflow preserves appearance preference");
  expect(excessive.state().positions.empty(),
         "position overflow discards the entire resume cache");

  {
    std::ofstream corrupt(path, std::ios::trunc);
    corrupt << "volume 66\nposition \"unterminated 42\ntheme dark\nprofile 2\n";
  }
  wam::StateStore corrupt(path);
  expect(!corrupt.load(), "malformed position reports corrupt input");
  expect(corrupt.state().volume == 66,
         "malformed position preserves earlier core preferences");
  expect(corrupt.state().appearance_theme == wam::AppearanceTheme::Dark,
         "malformed position does not block later core preferences");
  expect(corrupt.state().performance_profile == 2,
         "parsing continues after a bounded malformed record");
  expect(corrupt.state().positions.empty(),
         "malformed cache does not retain partial positions");

  {
    std::ofstream oversized(path, std::ios::trunc | std::ios::binary);
    oversized << "volume 67\nprofile 0\nrestore 0\ntheme system\n";
    const std::string chunk(4096, 'x');
    std::uintmax_t written = 0;
    while (written <= wam::StateStore::kMaxFileBytes) {
      oversized.write(chunk.data(), static_cast<std::streamsize>(chunk.size()));
      written += chunk.size();
    }
  }
  wam::StateStore oversized(path);
  expect(!oversized.load(), "oversized state file is rejected");
  expect(oversized.state().volume == 67,
         "oversized cache preserves volume preference");
  expect(oversized.state().performance_profile == 0,
         "oversized cache preserves performance preference");
  expect(!oversized.state().restore_positions,
         "oversized cache preserves restore preference");
  expect(oversized.state().appearance_theme == wam::AppearanceTheme::System,
         "oversized cache preserves appearance preference");

  {
    std::ofstream first_load(path, std::ios::trunc);
    first_load << "volume 68\nprofile 2\ntheme dark\n"
                  "position \"/tmp/old.mp4\" 18\n";
  }
  wam::StateStore repeated(path);
  expect(repeated.load(), "first load for repeated-load reset succeeds");
  expect(repeated.positionFor("/tmp/old.mp4") == 18.0,
         "first repeated load installs its resume cache");
  {
    std::ofstream second_load(path, std::ios::trunc);
    second_load << "profile 0\n";
  }
  expect(repeated.load(), "second load on one store succeeds");
  expect(repeated.state().volume == 100,
         "second load resets an omitted volume to its default");
  expect(repeated.state().performance_profile == 0,
         "second load installs its replacement profile");
  expect(repeated.state().appearance_theme == wam::AppearanceTheme::Light,
         "second load resets an omitted theme to its default");
  expect(repeated.state().seek_step_seconds == 5,
         "second load resets an omitted seek step to its default");
  expect(repeated.state().window_hugs_video == true,
         "second load resets an omitted hugs_video to its default");
  expect(repeated.state().positions.empty(),
         "second load replaces rather than accumulates positions");
  expect(!repeated.dirty(),
         "successful replacement load establishes a clean baseline");

  {
    const std::string decoded_source(wam::StateStore::kMaxSourceBytes + 1U,
                                     '\\');
    std::ofstream decoded_oversize(path, std::ios::trunc);
    decoded_oversize << "position " << std::quoted(decoded_source)
                     << " 30\nvolume 69\n";
  }
  wam::StateStore decoded_oversize(path);
  expect(!decoded_oversize.load(),
         "4097-byte decoded source is rejected within the line budget");
  expect(decoded_oversize.state().positions.empty(),
         "oversize decoded source cannot enter the resume cache");
  expect(decoded_oversize.state().volume == 69,
         "oversize decoded source preserves later core preferences");

  {
    std::ofstream carriage_source(path, std::ios::trunc | std::ios::binary);
    carriage_source << "volume 70\nposition \"/tmp/movie\rprofile 0.mp4\" 30\n"
                       "theme dark\n";
  }
  wam::StateStore carriage_source(path);
  expect(!carriage_source.load(),
         "literal carriage return in a decoded source is rejected");
  expect(carriage_source.state().positions.empty(),
         "carriage-return source cannot enter the resume cache");
  expect(carriage_source.state().volume == 70 &&
             carriage_source.state().appearance_theme ==
                 wam::AppearanceTheme::Dark,
         "carriage-return rejection preserves core preference recovery");

  {
    std::ofstream nul_source(path, std::ios::trunc | std::ios::binary);
    constexpr char prefix[] = "volume 71\nposition \"/tmp/movie";
    constexpr char suffix[] = "theme dark.mp4\" 30\n";
    nul_source.write(prefix, static_cast<std::streamsize>(sizeof(prefix) - 1U));
    nul_source.put('\0');
    nul_source.write(suffix, static_cast<std::streamsize>(sizeof(suffix) - 1U));
  }
  wam::StateStore nul_source(path);
  expect(!nul_source.load(), "literal NUL in a source record is rejected");
  expect(nul_source.state().positions.empty(),
         "NUL source cannot enter the resume cache");
  expect(nul_source.state().volume == 71,
         "NUL rejection preserves core preferences parsed beforehand");

  {
    std::ofstream comma_decimal(path, std::ios::trunc);
    comma_decimal << "volume 72\nposition \"/tmp/comma.mp4\" 12,5\n"
                     "theme system\n";
  }
  wam::StateStore comma_decimal(path);
  expect(!comma_decimal.load(),
         "classic-locale parser rejects comma decimal syntax");
  expect(comma_decimal.state().positions.empty(),
         "comma decimal cannot enter the resume cache");
  expect(comma_decimal.state().volume == 72 &&
             comma_decimal.state().appearance_theme ==
                 wam::AppearanceTheme::System,
         "comma decimal rejection preserves core preference recovery");

  {
    std::ofstream numeric_suffix(path, std::ios::trunc);
    numeric_suffix << "volume 74\nposition \"/tmp/suffix.mp4\" 12seconds\n"
                      "profile 0\n";
  }
  wam::StateStore numeric_suffix(path);
  expect(!numeric_suffix.load(), "numeric suffix is rejected");
  expect(numeric_suffix.state().positions.empty(),
         "suffixed number cannot enter the resume cache");
  expect(numeric_suffix.state().volume == 74 &&
             numeric_suffix.state().performance_profile == 0,
         "numeric suffix rejection preserves core preference recovery");

  wam::StateStore non_finite(path);
  non_finite.remember("/tmp/not-a-position.mp4",
                      std::numeric_limits<double>::quiet_NaN());
  expect(non_finite.state().positions.empty(),
         "non-finite resume position is ignored");

  wam::StateStore injected(path);
  injected.remember("/tmp/movie\nvolume 0\n.mp4", 30.0);
  injected.remember("/tmp/movie\rprofile 0.mp4", 30.0);
  injected.remember(std::string("/tmp/movie\0theme dark.mp4", 25), 30.0);
  expect(injected.state().positions.empty(),
         "line delimiters and NUL cannot enter the resume cache");
  injected.state().positions["/tmp/direct\nrestore 0\n.mp4"] = 30.0;
  expect(!injected.save(),
         "direct LF mutation cannot serialize an injected record");
  expect(injected.dirty(), "failed LF serialization remains dirty");
  injected.state().positions.clear();
  injected.state().positions["/tmp/direct\rprofile 0.mp4"] = 30.0;
  expect(!injected.save(),
         "direct CR mutation cannot serialize an injected record");
  expect(injected.dirty(), "failed CR serialization remains dirty");
  injected.state().positions.clear();
  injected.state().positions[std::string("/tmp/direct\0theme dark.mp4", 26)] =
      30.0;
  expect(!injected.save(),
         "direct NUL mutation cannot serialize an injected record");
  expect(injected.dirty(), "failed NUL serialization remains dirty");

  std::filesystem::remove(path, error);
  std::cout << "state store tests passed\n";
  return failures == 0 ? 0 : 1;
}
