// The argv-to-URL rule and the resume tracker's ordering rules.
#include "qt/media_url.hpp"
#include "qt/window_manager.hpp"

#include <iostream>

namespace {

int failures = 0;

void expect(bool condition, const char *message) {
  if (condition)
    return;
  std::cerr << "FAIL: " << message << '\n';
  ++failures;
}

void mediaUrlResolution() {
  using wam::qt::mediaUrlFromArgument;
  expect(mediaUrlFromArgument(QStringLiteral("videos/definitely-missing.mp4"))
             .isLocalFile(),
         "a missing relative path stays local");
  expect(mediaUrlFromArgument(QStringLiteral("definitely-missing.mp4"))
             .isLocalFile(),
         "a missing bare filename stays local");
  // Every extension the app offers keeps a bare name local; webm and mka
  // probe the list beyond mp4.
  expect(mediaUrlFromArgument(QStringLiteral("definitely-missing.webm"))
             .isLocalFile(),
         "a missing .webm filename stays local");
  expect(mediaUrlFromArgument(QStringLiteral("definitely-missing.mka"))
             .isLocalFile(),
         "a missing .mka filename stays local");
  const QUrl explicit_remote =
      mediaUrlFromArgument(QStringLiteral("https://example.invalid/video.mp4"));
  expect(!explicit_remote.isLocalFile() &&
             explicit_remote.scheme() == QStringLiteral("https"),
         "an explicit URL stays remote");
  const QUrl inferred_remote =
      mediaUrlFromArgument(QStringLiteral("www.example.invalid/video.mp4"));
  expect(!inferred_remote.isLocalFile() &&
             inferred_remote.scheme() == QStringLiteral("http"),
         "an unmistakable web host becomes an http URL");
}

void resumeTracking() {
  wam::qt::ResumeTracker tracker;

  // Merely opening a source is not evidence that playback reached zero. A
  // second open (or quit/load failure) before a position is reported must
  // leave any previously persisted resume point untouched.
  tracker.transitionTo(QStringLiteral("/media/unobserved.mp4"));
  expect(!tracker.transitionTo(QStringLiteral("/media/first.mp4"))
              .position_observed,
         "an unobserved source records no position");

  tracker.observeDuration(120.0);
  tracker.observePosition(42.0);

  // PlayerController::open resets the old timeline before sourceChanged.
  tracker.observePosition(0.0);
  tracker.observeDuration(0.0);
  const wam::qt::ResumeSnapshot open_snapshot =
      tracker.transitionTo(QStringLiteral("/media/second.mp4"));
  expect(open_snapshot.local_source == QStringLiteral("/media/first.mp4") &&
             open_snapshot.position == 42.0 &&
             open_snapshot.duration == 120.0 &&
             open_snapshot.position_observed,
         "an open keeps the previous source's last position");

  tracker.observeDuration(90.0);
  tracker.observePosition(27.0);

  // PlayerController::stop changes source before resetting the timeline.
  const wam::qt::ResumeSnapshot stop_snapshot = tracker.transitionTo({});
  tracker.observePosition(0.0);
  tracker.observeDuration(0.0);
  expect(stop_snapshot.local_source == QStringLiteral("/media/second.mp4") &&
             stop_snapshot.position == 27.0 &&
             stop_snapshot.duration == 90.0 &&
             stop_snapshot.position_observed &&
             tracker.snapshot().local_source.isEmpty(),
         "a stop keeps the stopped source's last position");

  // A deliberate seek to the beginning still clears the stable position.
  tracker.transitionTo(QStringLiteral("/media/third.mp4"));
  tracker.observePosition(18.0);
  tracker.commitZeroPosition(tracker.generation());
  expect(tracker.snapshot().position == 0.0 &&
             tracker.snapshot().position_observed,
         "a committed zero clears the position");
}

} // namespace

int main() {
  mediaUrlResolution();
  resumeTracking();
  return failures == 0 ? 0 : 1;
}
