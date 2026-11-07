
## Command–Escape shortcut revision

Changed the global and local fallback binding to Command–Escape, exactly two keys. Old saved multi-modifier choices fall back to the new default; removed the obsolete choice picker. Native shortcut registration, conflicting registration, release and re-registration passed outside the sandbox. The sandbox returned eventInternalErr before registration. App build and deep strict signature verification passed; build 6 installed and opened after checking for active recording writes. Physical-key start/stop was not re-tested.

## AirPods clock mismatch fix

Reproduced AirPods microphone activation with a 24 kHz output clock and a 48 kHz process tap. A candidate using drift compensation and the virtual stream format failed timing validation and was discarded. Final implementation chooses a matching built-in output clock for the private aggregate, leaving playback routing and device rates unchanged.

Generated-audio writer/codec/checkpoint tests passed, including tap ownership and duration at 16/24/44.1/48 kHz. App build and strict signature verification passed. A 30-second measured AirPods microphone + own-process silent tap diagnostic (about 35 seconds including warm-up) completed with two tracks, zero capture events, and matching recorded duration; system capture used MacBook Pro Speakers as its 48 kHz clock. Diagnostic audio was deleted. This verifies callback timing, not audible system-signal fidelity. An earlier run concurrent with regression tests stopped on bounded writer backpressure with zero timestamp events; load tolerance remains a limitation. No new 90-minute or battery-life claim. Build 7 installed after checking no recording writes were active.

## Recording deletion

Added selected-session Delete and row context-menu Move to Trash actions, with a native confirmation describing whole-session scope and Finder recovery. Both entry points are disabled during capture; the model rechecks capture state at confirmation. Successful deletion cancels playback/waveforms for the affected session, invalidates stale scans, and removes the list entry. Failures retain the entry and show an error. Generated-fixture tests passed for capture protection, failure retention, playback cleanup and a recoverable directory move via an injected trash operation. User recordings were not deleted; actual Finder Trash interaction and visual confirmation were not exercised. Build and strict signature checks passed; build 8 installed after checking capture was idle.
