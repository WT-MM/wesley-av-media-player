#pragma once

#include <QRect>
#include <QString>
#include <QUrl>

#include <optional>
#include <vector>

class QGuiApplication;

namespace wam::qt {

class PlayerWindow;
class WindowManager;

// Every WAM_TEST_* launch seam, parsed once. The seams exist only in the
// native app built with WAM_NATIVE_BENCHMARK_TELEMETRY, and only when
// NativeBenchmarkTelemetry::instance().enabled() (the opt-in plus a valid run
// identity, see docs/DEVELOPING.md). Everywhere else testSeams() is null, so a
// shipping launch can never observe one.
//
// Scripts share one grammar: comma-separated `text@number` (window, reopen) or
// `number@number` (seek) entries. The free-text side may itself contain '@',
// so an entry splits at the '@' next to its number. A malformed entry or an
// unknown window verb fails the launch instead of silently becoming a no-op.
struct TestSeams {
  struct TimedStep {
    QString text;
    int delayMilliseconds = 0;
  };
  struct SeekStep {
    double target = 0.0;
    double when = 0.0;
  };

  bool background = false;              // WAM_TEST_BACKGROUND
  bool muted = false;                   // WAM_TEST_MUTED
  bool noVideoHardware = false;         // WAM_TEST_NO_VIDEO_HARDWARE
  std::optional<QRect> geometry;        // WAM_TEST_GEOMETRY "WxH+X+Y"
  bool allWindowGeometry = false;       // WAM_TEST_ALL_WINDOW_GEOMETRY
  bool noticeTrace = false;             // WAM_TEST_NOTICE_TRACE
  bool captionMetrics = false;          // WAM_TEST_CAPTION_METRICS
  bool captionEngineWhisper = false;    // WAM_TEST_CAPTION_ENGINE=whisper
  QString captionOutput;                // WAM_TEST_CAPTION_OUTPUT
  bool capturePhysical = false;         // WAM_TEST_CAPTURE_PHYSICAL=1
  int openDelayMilliseconds = 0;        // WAM_TEST_OPEN_DELAY_MS
  int quitAfterMilliseconds = 0;        // WAM_TEST_QUIT_AFTER_MS
  bool quitThroughMenu = false;         // WAM_TEST_QUIT_MODE=menu
  std::vector<SeekStep> seekScript;     // WAM_TEST_SEEK_SCRIPT
  std::vector<TimedStep> reopenScript;  // WAM_TEST_REOPEN_SCRIPT
  std::vector<TimedStep> windowScript;  // WAM_TEST_WINDOW_SCRIPT
};

using UrlResolver = QUrl (*)(const QString &);

#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY) && defined(WAM_HAS_MACOS_NATIVE_PLAYBACK)
// Parses the seams. False, after printing the bad entry, when the launch
// must fail.
[[nodiscard]] bool loadTestSeams();
[[nodiscard]] const TestSeams *testSeams() noexcept;
// Before QGuiApplication exists: the Cocoa plugin activates the process
// inside its constructor, and audio/video sessions snapshot the mute and
// hardware seams when they are built.
void armTestSeamsBeforeApplication();
// Right after QGuiApplication, before any window is shown.
void armTestSeamsAfterApplication();
void armTestSeamsForWindows(WindowManager &windows);
// Starts the scripted drivers and reports against the first window.
void startTestSeams(QGuiApplication &app, WindowManager &windows,
                    PlayerWindow &first, UrlResolver resolve);
#else
[[nodiscard]] inline bool loadTestSeams() { return true; }
[[nodiscard]] inline const TestSeams *testSeams() noexcept { return nullptr; }
inline void armTestSeamsBeforeApplication() {}
inline void armTestSeamsAfterApplication() {}
inline void armTestSeamsForWindows(WindowManager &) {}
inline void startTestSeams(QGuiApplication &, WindowManager &, PlayerWindow &,
                           UrlResolver) {}
#endif

} // namespace wam::qt
