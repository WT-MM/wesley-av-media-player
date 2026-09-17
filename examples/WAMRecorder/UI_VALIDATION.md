# Window and recording library validation — September 17, 2026

WAM Recorder 0.2.0 was built, its signature verified, and installed in the user's
Applications folder. Its native control window was inspected through Accessibility
and a screenshot. The Record/Recordings selector, sources, start button, recording
list, filter, source-specific Play buttons and Finder button were visible.
An existing saved session was discovered from its manifest; user audio was not
played during inspection.

Closing the window and reopening the installed app through Launch Services restored
the selected session. A deliberate `open -n` of the build-directory copy forwarded
to the installed app; only the original installed process remained. Spotlight
metadata contains the expected display name and bundle identifier. A direct Spotlight
UI attachment timed out, so no completed Spotlight keyboard-search test is claimed.
The Dock/Spotlight reopen handler uses the same native application reopen event.

The SVG-derived ICNS was visually inspected at 256 px and bundled as CFBundleIconFile.
The app opens as a regular Dock application; benchmark mode remains an accessory
unless its inspection-window flag is supplied. No capture starts when opening a
window. Existing idle copies were quit gracefully before installation.

All eight CTests passed (27.85 seconds), including generated-silence playback for
Float32, PCM16, ALAC and both AAC presets. Playback checks cover pause/resume, seek,
automatic checkpoint continuation, previous/stop, manifest discovery, corrupt
manifests, invalid paths and missing audio. Synthetic test folders are removed.
No new microphone recording, battery comparison, or 90-minute endurance test was
performed for this UI/playback change. Closing/minimizing while actively recording
has not been exercised in this pass; capture lifecycle is independent of the window.
