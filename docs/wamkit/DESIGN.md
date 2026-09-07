**WAMKit should be a native macOS playback framework built around WAM’s session and playback-owner layer below Qt.** An IDE would create a player, place its presentation view inside its own window, and call play, pause, seek, rate, volume, and subtitle APIs. WAMKit would own decoding, audio output, scheduling, and presentation.

Today, those pieces exist internally, but there is no supported embedding API. Making one requires extracting ownership and presentation plumbing—not merely exporting the existing C++ classes.

This is a read-only design based on the inspected worktree and amendment ledger. No files were changed, staged, built, or tested. Another agent is editing this tree, so the cited lines describe the inspected versions.

**The framework boundary belongs above `NativeMediaSession`, with the native portion of `NativePlaybackOwner` moved below Qt.**

The existing layering provides a substantial starting point:

| Existing component | WAMKit disposition |
|---|---|
| `src/media` | Keep as the private neutral core: source contracts, demuxers, dispatcher, timing, codec facts, subtitle parsers. |
| `wam_macos_native_backend` | Reuse privately: native session, audio, consumers, preview, and tracked-output arbitration. |
| `wam_macos_native_video_core` | Reuse privately: VideoToolbox and admitted software decoder stages. |
| `wam_macos_native_session_system` | Split its production factory into toolkit-independent construction and presentation adapters. |
| `src/qt/native_playback_owner.*` | Extract native command sequencing, observation draining, generation checks, watchdogs, and retirement ownership. Keep Qt notifications and compatibility wiring in the app. |
| `PlayerController`, `WindowManager`, QML | Remain app-facing adapters and product UI. |
| mpv fallback | Remains app-only. WAMKit reports a named refusal. |

The archive boundary is already useful: [`CMakeLists.txt:584`](/Users/wesleymaa/Documents/WAM/CMakeLists.txt:584) builds the backend independently. However, [`CMakeLists.txt:619`](/Users/wesleymaa/Documents/WAM/CMakeLists.txt:619) links the session-system archive to `wam_macos_native_qt_tracked`, which currently combines the display-layer implementation with Qt/OpenGL presentation.

The proposed dependency direction is:

```text
Swift / Objective-C host                 WAM's Qt/QML app
          │                                    │
          │                              thin Qt adapter
          └───────────── WAMKit ────────────────┘
                    C ABI + ObjC facade
                   native playback owner
                  native session / arbiter
              sources, decoders, audio, clock
                             │
              WAMPresentationView / display layer
```

No Qt types, C++ STL types, decoder handles, or source-contract headers become public SDK types.

Several concrete changes are necessary:

- **Replace the Qt-dependent factory input.** The current factory requires `QtGlVideoItem*`, obtains its `QQuickWindow`, and derives the native view from `winId()` at [`native_media_session_system.mm:73`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_media_session_system.mm:73). Its display-layer failure path silently constructs a Qt GL output at line 171. WAMKit needs a factory accepting a framework-owned presentation binding; failure must return `PresentationUnavailable`.
- **Separate view construction from installation.** `NativeLayerHostView` installs a lower sibling of Qt’s view, relying on Qt’s window composition. That is an app integration strategy, not an embeddable view contract: [`native_layer_host_view.hpp:8`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_layer_host_view.hpp:8). Extract its container-layer layout and rotation implementation into a normal `NSView` subclass. Keep the Qt sibling installer in the app.
- **Extract the owner rather than copying it.** Session construction currently reaches through `PlayerController` for captions, gain, and mute at [`native_playback_owner.mm:1098`](/Users/wesleymaa/Documents/WAM/src/qt/native_playback_owner.mm:1098). Observation delivery uses `QPointer`, `QMetaObject`, and a controller context at line 1314; watchdogs use `QTimer` at line 327. Replace those dependencies with retained native state and main-queue delivery.
- **Move source preflight below Qt.** Preserve its bounded latest-request behavior, but replace `QUrl`/`QString` and Qt filesystem classification with native equivalents. Today only `FastLocal` sources qualify at [`native_open_preflight.mm:123`](/Users/wesleymaa/Documents/WAM/src/qt/native_open_preflight.mm:123). A `file:` URL alone does not prove that the native source policy admits it.
- **Separate engine state from process/UI policy.** No framework code should set application activation policy, numeric locale, menus, preferences, global shortcuts, or window geometry. WAM’s playback activity assertion is currently implemented in the Qt owner at [`native_playback_owner.mm:194`](/Users/wesleymaa/Documents/WAM/src/qt/native_playback_owner.mm:194). Move the mechanism into a reference-counted native service with explicit configuration for preventing App Nap and display sleep.
- **Fix configuration at the framework boundary.** Presentation selection and test mute currently use header-local process state. Their “one instance per binary” assumptions need auditing across the new dynamic-library boundary; see [`native_audio_test_mute.hpp:43`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_audio_test_mute.hpp:43). WAMKit must own its registries and settings in one loaded engine image.

Menus, recent files, resume persistence, preferences, full-screen commands, window creation, exports, whisper caption generation, and QuickLook registration stay app-only. Generated subtitle files can still be supplied to WAMKit as external subtitles.

**WAMKit should ship native playback only, including admitted software decoder stages.**

“Native” here describes WAM’s session, audio engine, clock, and display-layer pipeline. It does not mean every codec uses Apple hardware. The existing decode ladder already distinguishes VideoToolbox hardware/software, AudioToolbox, libvpx, and libavcodec: [`native_decode_plan.hpp:6`](/Users/wesleymaa/Documents/WAM/src/media/native_decode_plan.hpp:6).

WAMKit must not load libmpv, create a compatibility renderer, or search Homebrew when admission fails. Return a structured refusal containing:

```text
code: UnsupportedMedia
reason: DecoderStageNotBuilt
stage: videoDecode
compatibility: NotProvided
nativeRetirement: Complete
```

Keep the actual reason rather than replacing every failure with “fallback unavailable.” Hosts can show it, offer another player, or implement their own compatibility path.

This avoids importing the app’s mpv lifecycle, OpenGL dependencies, and separately configured licensing closure. It also gives embedders predictable renderer and resource behavior.

**The public model should be small and asynchronous.**

| Public object | Responsibility |
|---|---|
| `WAMPlayer` | Reusable transport owner; one current item and one native epoch at a time. |
| `WAMMediaItem` | Immutable source request, initial exact position, and requested track selection. Creating one performs no media I/O. |
| `WAMItemSnapshot` | Immutable prepared metadata: duration, display geometry, tracks, capabilities, and selected route. |
| `WAMTrack` | Item-scoped stable identifier, kind, language, label, codec, default/forced flags, selection/admission status. |
| `WAMPresentationView` | Framework-created `NSView` containing the display layer and optional subtitle overlay. |
| `WAMObservation` | Cancellable subscription to ordered events and optional metrics. |

Use a public player state model such as `empty`, `preparing`, `ready`, `playing`, `paused`, `seeking`, `ended`, `stopping`, `failed`, and `closed`. Expose requested transport intent separately from applied state. An accepted `play()` command does not immediately prove that audio has started.

A representative C surface would look like this; all names are proposed:

```c
typedef struct wam_player *wam_player_t;
typedef struct wam_item *wam_item_t;
typedef struct wam_presentation *wam_presentation_t;
typedef struct wam_observation *wam_observation_t;

typedef struct {
    int64_t value;
    int32_t timescale;       /* > 0; zero reserved for unknown in snapshots */
    uint32_t reserved;
} wam_time_t;

typedef uint64_t wam_request_id_t;

wam_status_t wam_player_create(
    const wam_player_config_t *, wam_player_t *, wam_error_t *);

wam_status_t wam_player_open(
    wam_player_t, wam_item_t, wam_request_id_t *, wam_error_t *);

wam_status_t wam_player_set_paused(
    wam_player_t, uint32_t paused, wam_request_id_t *, wam_error_t *);

wam_status_t wam_player_seek(
    wam_player_t, wam_time_t, const wam_seek_options_t *,
    wam_request_id_t *, wam_error_t *);

wam_status_t wam_player_set_volume(
    wam_player_t, float gain, wam_request_id_t *, wam_error_t *);

wam_status_t wam_player_close(
    wam_player_t, wam_request_id_t *, wam_error_t *);
```

Companion functions cover retain/release, stop, rate/pitch policy, mute, snapshots, observations, presentation creation, track selection, subtitles, and budgets. `stop` empties a reusable player; `close` permanently closes it.

The macOS bridge returns a documented borrowed `NSView*` as an opaque pointer through the C API. The Objective-C header supplies the typed `WAMPresentationView`. Other languages can control playback entirely through C, but embedding its view still requires AppKit interoperability.

For ABI stability:

- Use opaque handles, fixed-width fields, explicit enum values, and `struct_size` on extensible structures.
- Keep strings UTF-8 and copy input data before returning. Event payloads remain valid for the callback; retaining an event or copying a snapshot extends their lifetime.
- Never pass exceptions across C. Return synchronous validation errors through `wam_error_t`; report asynchronous failures as events.
- Export only documented C symbols and Objective-C classes. Keep C++ implementation symbols private.
- Provide ABI version and capability queries. Unknown appended event types must be safely ignorable.
- Keep the Swift overlay as a thin wrapper over the same ABI, with `@MainActor`, typed errors, observation tokens, and async conveniences.

**Main-thread ownership must be explicit, including teardown.**

Player commands, player/view creation, attachment, observer cancellation, and player release occur on the AppKit main thread. The Swift overlay enforces this through `@MainActor`; C/Objective-C document and validate it. Immutable snapshot/event retain-release operations can be thread-safe.

All public callbacks arrive asynchronously on the main queue, in per-player order. No host callback runs on the AudioUnit callback, decoder callback, session worker, or while an engine lock is held. Commands issued from an event callback enter the next dispatch turn, preventing recursive state transitions.

The session already offers a capacity-one queued observation edge with retained lifetime tickets and no synchronous owner invocation: [`native_media_session.hpp:166`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_media_session.hpp:166). Preserve that property.

The host owns its window and placement constraints. WAMKit owns the presentation view’s internal layers and their playback connection. The player retains its presentation; the view does not strongly retain the player. The host may resize, hide, remove, or reparent the view on the main thread. It must not replace its backing layer, attach a second timebase, flush the renderer, or enqueue samples.

Removing the view from a window does not implicitly close playback. Audio continues unless the host pauses it. Explicit presentation invalidation cancels presentation demands and prevents subsequent frames from reaching that binding. A replacement view requires an acknowledged binding transition. Initially support one presentation per player; mirroring is outside the first SDK.

Crucially, the current destructor is not sufficient for this contract. `NativeMediaSession::Impl::shutdown()` calls `worker.join()` at [`native_media_session.mm:706`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_media_session.mm:706), and the Qt owner resets the session directly during surface teardown at [`native_playback_owner.mm:1786`](/Users/wesleymaa/Documents/WAM/src/qt/native_playback_owner.mm:1786). Older architecture prose about background retirement cannot substitute for this inspected implementation.

WAMKit therefore needs:

1. Main-thread invalidation of client delivery and presentation identity.
2. Asynchronous stop and observation draining, retaining the session and presentation dependencies.
3. Worker joining/destruction off the main thread, with AppKit object cleanup marshalled back to main.
4. A terminal close result distinguishing completed retirement from bounded quarantine.

A quarantined graph continues consuming its resource admission. A timeout must not forge `Stopped`, release accounting for live surfaces, or enable another engine prematurely. Releasing a player without awaiting close initiates the same retirement path and suppresses later client callbacks.

**Seeking must preserve rational intent end to end.**

The public target is `WAMTime(value:timescale:)`, matching the neutral `MediaTime` domain: signed 64-bit numerator and positive 32-bit timescale. Validate and reduce with checked integer arithmetic. Negative playback targets, invalid denominators, overflow, and out-of-range targets return named errors.

For accurate seeking:

\[
T=\frac{n}{d},\qquad A=\frac{\lceil T R\rceil}{R}
\]

Here, `R` is the selected audio’s decoded media sample rate, not necessarily the device rate. Decode begins at the required earlier access point; PCM before `A` is discarded without changing its timestamps. The paused transport remains at `T`, and initial playout maps to `A` through the existing discontinuity rule.

This is the frozen behavior recorded at [`SESSION_HANDOFF.md:886`](/Users/wesleymaa/Documents/WAM/SESSION_HANDOFF.md:886). The core already supplies exact `audioFrameAtOrAfter()` at [`native_media_source.hpp:62`](/Users/wesleymaa/Documents/WAM/src/media/native_media_source.hpp:62).

The current public-to-session path is weaker than the proposed API:

- Initial and commit preflight accept only `double`: [`native_media_session.hpp:382`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_media_session.hpp:382).
- `CommitSeek`, clock proofs, and `CommitReady` carry seconds as doubles: [`native_playback_contract.hpp:347`](/Users/wesleymaa/Documents/WAM/src/media/native_playback_contract.hpp:347).
- Commit completion compares the clock’s double position with the command target: [`native_media_session.mm:2887`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_media_session.mm:2887).

Consequently, **an exact C argument followed by conversion to `double` is not an acceptable implementation**.

Add exact preflight entry points and an exact command/proof companion contract. Retain `T`, audio boundary `A`, generation, and covering-frame interval through completion. Existing double entry points remain compatibility adapters with their existing semantics. The worker and decoder path stay shared; the new proof must validate exact identities and intervals rather than infer success from approximate seconds equality.

For live position observations, expose an exact anchor/frame-domain description where available, a host timestamp, and explicitly approximate display seconds. Do not claim that converting the current double clock snapshot back into a fraction produces an exact observation.

Each accepted seek receives a request ID and one terminal outcome: completed, superseded, cancelled, or failed. New seeks supersede older intent; stop and replacement open cancel it. Preserve the session’s generation-bound draw baseline. Seeking while paused remains paused; seeking while playing resumes the latest requested transport state after readiness.

Completion reports `requestedTarget`, `audioPresentationStart`, actual decode start, covering video interval, and generation. Audio-only completion has no video proof. Video-only playback uses the existing host-driven silent timebase, explicitly identified as such: [`native_silent_timebase.hpp:11`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_silent_timebase.hpp:11).

Use accurate seeking for the MVP. A later keyframe mode must preserve the separate `A = D = RAP` contract. Targets must be below the exact presentable ceiling; offer an explicit end-position helper instead of silently rounding arbitrary requests.

Long preroll is a progress condition, not automatically a refusal. Amendment 17 already makes the 12-second constants fast-seek thresholds and preserves bounded streaming: [`SESSION_HANDOFF.md:1430`](/Users/wesleymaa/Documents/WAM/SESSION_HANDOFF.md:1430). Expose decoded-preroll progress and stall detection without promising a percentage when remaining work is unknown.

**Rate, volume, tracks, and subtitles need honest capability reporting.**

Rate supports the existing 0.25×–4× envelope and 1/64 grid, with preserved pitch or varispeed. Report both requested and applied rate. The C API can accept an exact admitted ratio; a Swift convenience accepting `Double` explicitly quantizes and returns the applied ratio. Invalid or out-of-envelope rates return `RateUnsupported`, preserving current playback. The existing policy is defined at [`native_playback_contract.hpp:179`](/Users/wesleymaa/Documents/WAM/src/media/native_playback_contract.hpp:179).

Volume is linear gain, default 1.0, with the existing engine ceiling of 4.0. Mute is independent. The framework stores no preferences; the host may impose a lower UI ceiling. The gain amendment distinguishes engine limits from UI policy at [`SESSION_HANDOFF.md:1071`](/Users/wesleymaa/Documents/WAM/SESSION_HANDOFF.md:1071).

Track identifiers must be stable within an item, rather than menu indices. The current subtitle IDs are positional and rebuilt: [`subtitle_sources.hpp:84`](/Users/wesleymaa/Documents/WAM/src/qt/subtitle_sources.hpp:84). Include item identity in selection requests so a stale ID cannot select a track in a replacement item.

The native source contract already has preferred track selection, but the production session binding currently contains only source key and local path. Plumb selection through preparation and publish the admitted descriptor. Do not advertise seamless live audio/video switching: implement it later as an explicit generation/reopen transaction at the current exact position. Until then return `TrackSwitchRequiresReopen`.

Subtitles require actual extraction work:

- Reuse neutral text, bitmap, Matroska, MP4, and live-caption parsing.
- Move native source discovery, selection, cancellation, and cue lookup out of `SubtitleSources`.
- Replace `QString`, `QImage`, `QVariantList`, and the QML bitmap provider with neutral cue data and AppKit/CoreGraphics presentation.
- Replace the current cancel-and-join loading behavior with bounded asynchronous cancellation.
- Add a framework subtitle overlay, positioned within the displayed video rectangle and updated on cue changes, seek, pause, rate, and geometry changes.

Today native subtitle ownership is in [`subtitle_sources.hpp:145`](/Users/wesleymaa/Documents/WAM/src/qt/subtitle_sources.hpp:145), while rendering remains in [`Main.qml:1188`](/Users/wesleymaa/Documents/WAM/qml/Main.qml:1188) and [`Main.qml:1716`](/Users/wesleymaa/Documents/WAM/qml/Main.qml:1716).

Expose subtitle off/selection, external-file attachment, and optional cue events for hosts that draw their own subtitles. Match existing plain-text/bitmap behavior before promising full ASS styling. Subtitle failure should normally disable that subtitle source and report an error while playback continues.

**Events are product API; benchmark telemetry remains a separate facility.**

Every event carries schema version, player identity, item/open identity, request identity when applicable, generation, sequence number, and monotonic host timestamp.

| Event or snapshot | Meaning |
|---|---|
| `routeSelected` | Actual demux backend, video/audio decoder implementations, presentation route, clock authority, and named reasons for rejected preceding candidates. |
| `prepared`, `stateChanged` | Admitted metadata and applied lifecycle state. |
| `firstFrameAccepted` | First tracked renderer-acceptance fact for this item/generation. |
| `seekProgress`, `seekCompleted` | Progress and exact completion facts. |
| `tracksChanged`, `subtitleChanged` | Item-scoped selections and cue changes. |
| `refused`, `failed` | Stable reason code, stage, details, recoverability, and retirement status. |
| `metrics` | Optional cumulative counters with epoch, timestamps, and validity flags. |
| `stopped`, `closed` | Explicit terminal lifecycle outcomes. |

Do not call first-frame acceptance “first visible frame.” The display-layer contract explicitly describes `FrameDrawn` as acceptance-class evidence, not photons: [`native_layer_video_output.hpp:58`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_layer_video_output.hpp:58). A hidden or detached view can accept frames.

Metrics should expose submitted/accepted frames, late discards, superseded frames, audio underrun callbacks, rendered audio frames, seek preroll, requested/applied clock rate, and resource usage. Keep categories separate rather than inventing one aggregate “dropped frames” total.

The current session metrics reset per session and use validity flags; `clockRate` is requested rate, not measured advancement: [`native_media_session.hpp:324`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_media_session.hpp:324). Preserve those distinctions. Derived observed advancement must exclude pauses, seeks, epoch changes, and discontinuities.

Compositor drop measurements need additional care: the current health interface identifies `AVVideoPerformanceMetrics` properties as SPI at [`native_layer_video_output.hpp:12`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_layer_video_output.hpp:12). The distributable SDK should use public API only. Expose compositor drops as unavailable unless a supported measurement exists; retain WAM-owned discard counts. Removing the current SPI-dependent drop audit requires explicit review of its proof implications.

Use bounded delivery: reserve terminal-result capacity when accepting commands, reject excess commands with `Backpressure`, and coalesce position, progress, and metrics. A slow observer must not produce an unbounded dispatch queue or block audio. Observer cancellation prevents subsequent delivery; there is no synchronous callback during registration.

Normal events require no telemetry environment variables. Metrics are explicitly enabled per player and create no periodic sampler when disabled. The current sampler is lazily armed, but lacks a corresponding public disarm contract; add that rather than assuming unsubscribe removes its worker cost.

Exclude `WAM_TEST_*`, `WAM_PRESENTATION`, and file-output telemetry configuration from shipping WAMKit behavior. WAM’s harness can translate its validated environment into a private test-support adapter. Preserve its existing identity gate and committed telemetry format; ordinary SDK events are not substitutes for benchmark evidence. The gate is documented at [`docs/DEVELOPING.md:206`](/Users/wesleymaa/Documents/WAM/docs/DEVELOPING.md:206).

**Errors should distinguish refusal, misuse, runtime failure, and cancellation.**

Use a stable domain such as `WAMKitErrorDomain`, stable numeric codes and symbolic names, optional backend detail, and request/generation identity. Hosts must never parse diagnostic prose.

Representative names:

- `UnsupportedSourceScheme`, `BufferedSourceUnsupported`, `SourceAccessDenied`, `SourceChanged`
- `UnsupportedContainer`, `UnsupportedTrack`, `DecoderStageNotBuilt`, `DecoderUnavailable`
- `PresentationRequiresMacOS14`, `PresentationUnavailable`, `PresentationFormatUnsupported`
- `InvalidTime`, `TimeOverflow`, `SeekOutOfRange`, `SparseRandomAccess`, `SeekStalled`
- `RateUnsupported`, `InvalidVolume`, `TrackSwitchRequiresReopen`
- `SessionBudgetExceeded`, `SurfaceBudgetExceeded`, `RetirementCapacityUnavailable`
- `AudioOutputUnavailable`, `DecodeFailed`, `InternalProtocolViolation`

Preserve existing named decoder refusals where applicable. Detailed failures currently disappear behind the deliberately small frozen `FailureReason` enum at [`native_playback_contract.hpp:448`](/Users/wesleymaa/Documents/WAM/src/media/native_playback_contract.hpp:448); add structured diagnostic transport rather than reconstructing causes from stderr.

**Multi-instance admission must expose the existing budgets.**

A player window becomes a playback admission in SDK terminology. Multiple players may share one host window.

| Budget | Current inspected ceiling |
|---|---:|
| Concurrent native player resource envelope | 16 |
| Distinct charged decoded surfaces per session | 10 |
| Decoded-surface bytes per session | 384 MiB |
| Process decoded-surface count | 160 |
| Process decoded-surface bytes | 6 GiB |
| Layer-presentation bookkeeping, including transition overlap | 32 |

Sources: [`native_concurrency_limits.hpp:35`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_concurrency_limits.hpp:35), [`native_surface_budget.hpp:27`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_surface_budget.hpp:27), [`native_surface_budget.hpp:88`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_surface_budget.hpp:88), and [`native_layer_presentation_state.hpp:75`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_layer_presentation_state.hpp:75).

These are ceilings, not preallocations, memory forecasts, or promises that sixteen 4K streams run in real time. The 32-layer allowance does not authorize 32 playback graphs. Surface accounting also does not bound the host’s total RSS or decoder-service memory.

Expose hard limits plus current active, preparing, retiring, and quarantined admissions. Availability snapshots are advisory; open performs atomic admission. Retiring and quarantined work stays charged. A replacement open cannot evade limits by abandoning its predecessor.

Allow hosts to choose a lower session-admission limit. Do not expose knobs that enlarge frozen surface, decoder, or audio budgets. Centralize accounting inside WAMKit; shipping both WAMKit and statically linked copies of its backend in one process is unsupported.

**Package one relocatable, versioned framework and its complete decoder closure.**

Proposed macOS layout:

```text
WAMKit.framework/
  Versions/A/
    WAMKit
    Headers/WAMKit.h
    Headers/WAMKitObjC.h
    Modules/module.modulemap
    Frameworks/libavcodec-wamnative.<major>.dylib
    Frameworks/libavutil-wamnative.<major>.dylib
    Frameworks/...other enabled decoder dependencies...
    Resources/Info.plist
    Resources/Capabilities.json
    Resources/ThirdPartyNotices/
  Versions/Current -> A
  WAMKit -> Versions/Current/WAMKit
  Headers -> Versions/Current/Headers
  Modules -> Versions/Current/Modules
  Resources -> Versions/Current/Resources
```

Supply a source Swift overlay through Swift Package Manager, initially avoiding a second binary ABI commitment. An XCFramework can become the distribution container when additional architecture slices are validated; it does not change the runtime API.

Use `@rpath/WAMKit.framework/Versions/A/WAMKit` for the framework and framework-relative paths for its private dylibs. No Homebrew, build-tree, external symlink, or executable-location assumption may remain.

The CMake work must also make app configuration optional: Qt is presently required globally at [`CMakeLists.txt:108`](/Users/wesleymaa/Documents/WAM/CMakeLists.txt:108). A WAMKit-only build must configure without Qt or mpv headers.

The current FFmpeg recipe deliberately builds shared LGPL stages and disables avformat, networking, programs, filters, and encoders: [`build_ffmpeg_lgpl.sh:24`](/Users/wesleymaa/Documents/WAM/scripts/build_ffmpeg_lgpl.sh:24). Therefore:

- Bundle every enabled stage and its transitive dependencies.
- Include libvpx when enabled.
- Include libavformat only after the in-progress demux stage is implemented and accepted.
- Publish build capabilities; do not advertise FFmpeg’s entire format catalog.
- Exclude the app’s export executable, whisper runtime/model, Qt closure, and mpv fallback.

Reuse the app’s self-containment audit, parameterized for framework roots and execution contexts. It already audits Mach-O architectures, deployment floors, dependencies, and escaping rpaths at [`bundle_macos_lib.zsh:1403`](/Users/wesleymaa/Documents/WAM/scripts/bundle_macos_lib.zsh:1403). Its app-specific dependency seeds and FFmpeg detection cannot simply be reused unchanged: current detection looks at the app executable’s direct linkage at [`bundle_macos_lib.zsh:857`](/Users/wesleymaa/Documents/WAM/scripts/bundle_macos_lib.zsh:857).

Require relocation and clean-machine playback in a small non-Qt host before distribution.

The existing display-layer implementation refuses below macOS 14 at [`native_layer_video_output.mm:487`](/Users/wesleymaa/Documents/WAM/src/platform/macos/native_layer_video_output.mm:487). Thus the first SDK supports display-layer playback on **macOS 14+**. It may retain a 13.3 binary load floor through availability guards, allowing WAM’s 13.3 app to load it and receive a named refusal. Providing display-layer playback on 13.3 would be a separate implementation project.

Ad-hoc signatures suit local integration. A Developer ID embedder should copy the framework closure, sign its nested code with the host’s team identity, sign the framework, then sign and notarize the complete app. A vendor signature alone does not satisfy a different host team’s library validation. Do not make disabling library validation the default integration recipe. Apple documents nested-code sealing and same-team library validation in its [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).

**LGPL obligations follow the distributed framework into the embedding application.**

Keep FFmpeg dynamically linked as replaceable dylibs. A C ABI or `.framework` wrapper does not remove its license obligations.

Distribute exact corresponding FFmpeg source, modifications if any, build instructions, configuration receipts, license texts, and notices with each SDK release. Provide embedders a redistribution package and explicit instructions for their application notices and download/source links. FFmpeg’s own [compliance checklist](https://www.ffmpeg.org/legal.html) recommends dynamic linking, matching source distribution, build instructions, attribution, and avoiding GPL/nonfree configurations.

Embedders distributing the combined app must preserve the applicable LGPL rights, including modification for the customer’s use and reverse engineering to debug those modifications. The bundled [LGPL 2.1 text:270](/Users/wesleymaa/Documents/WAM/docs/native-coverage/phase2/COPYING.LGPLv2.1:270) describes the linking conditions.

Document and verify a replacement procedure: rebuild ABI-compatible libraries, replace them, and re-sign the modified closure and app for local execution. Runtime checks may validate compatibility but must not require byte identity with WAM’s original library. The existing native-stage notice already describes compatible replacement at [`FFMPEG_NOTICES.md:15`](/Users/wesleymaa/Documents/WAM/docs/native-coverage/phase2/FFMPEG_NOTICES.md:15).

Statically absorbing FFmpeg into WAMKit would introduce additional relinking obligations; it is not the recommended package. Future decoder/demux additions require review of their actual build configuration and dependencies.

WAMKit also needs an explicit license for **WAM’s own code**. I did not find a top-level license grant in the inspected inventory; the native FFmpeg notice expressly does not select WAM’s license. Publishing source is not itself an SDK redistribution license. Choose an embedding-compatible license or commercial grant before external release, with legal review of the resulting distribution terms.

**WAM should consume WAMKit itself.**

Recommend dogfooding the dynamic framework, rather than retaining direct native-backend linkage.

`PlayerController` becomes a QML adapter over WAMKit commands and observations. `WindowManager` retains window creation, focus, menus, and app limits. The Qt presentation installer places WAMKit’s view beneath the transparent chrome using the app-specific sibling arrangement.

The app retains a compatibility coordinator for mpv. It reacts to WAMKit refusal or failure only after receiving the required native retirement result. It preserves source/request lineage and exclusive audio ownership. It must not independently recreate native Start/Seek/Stop sequencing.

The optional Qt scenegraph route requires an app-private, version-matched output adapter if retained. That adapter uses the same WAMKit session/owner implementation; it must not bring a second statically linked backend into the app. It is not part of the public embedding ABI.

This migration is complete only when the shipping native route has one owner, one set of process budgets, one subtitle service, and one teardown implementation. A temporary comparison build is useful during migration, but permanent direct linkage would leave the app testing a different integration from SDK customers.

**The following are PROPOSALS, not ratified amendments.** The inspected ledger ends at 17. Numbers 18–23 below are provisional and must be reconciled with concurrent additions before appending anything.

| Proposed amendment | Scope and preserved contracts |
|---|---|
| **18 — Embedding ownership and construction** | Add toolkit-independent session construction, native owner extraction, and asynchronous close/retirement. Preserve generation identities, Stop precedence, callback lifetime barriers, and quarantine accounting. |
| **19 — Exact external time** | Add exact preflight and exact command/proof companion types. Preserve existing double APIs and frozen `A = ceil(T×R)/R` / keyframe semantics. No epsilon checks or target relabeling. |
| **20 — Structured observations** | Add descriptor, route, refusal, exact seek result, and metrics subscription facts. Existing lifecycle reasons and observation-slot behavior retain their meanings. |
| **21 — Public presentation evidence** | Remove SPI dependence from the distributable configuration; explicitly distinguish renderer acceptance, WAM discards, and unavailable compositor measurements. Review existing drop-audit proof implications. |
| **22 — Shared resource/configuration ownership** | Move relevant cross-binary state into WAMKit-owned services and expose admission/budget snapshots. Preserve 16 sessions, 10 surfaces, 384 MiB, and all derived limits. |
| **23 — SDK packaging and app adoption** | Add framework-only configuration, relocatable decoder closure, signing/replacement instructions, explicit WAMKit licensing, and app dogfooding. No automatic widening of format or OS support. |

Append new declarations and explicit enum values; never reorder or repurpose existing ones. Prefer new companion headers and tests. If implementation requires changing a frozen declaration or proof, record the exact before/after and rationale in a separately ratified amendment.

The developing guide identifies frozen source/audio-test surfaces at [`docs/DEVELOPING.md:291`](/Users/wesleymaa/Documents/WAM/docs/DEVELOPING.md:291). Existing tests remain contract evidence, not material to weaken so the wrapper passes.

**A credible MVP is roughly five to seven engineer-weeks; the fuller SDK is roughly eight to twelve.**

These estimates assume one engineer familiar with the native pipeline, normal review turnaround, and a stable integration base. They exclude completing the separate codec/libavformat campaign, signing credentials, and legal turnaround.

| Phase | Estimate | Reviewable result |
|---|---:|---|
| Contract and dependency audit | 2–3 days | Final API draft, amendment scopes, dependency graph, lifecycle ownership table. |
| Native owner, factory, view, and retirement extraction | 7–10 days | Qt-free native host plays existing admitted media; bounded asynchronous close. |
| Exact seek boundary and proofs | 5–8 days | Rational open/seek targets, cancellation, exact completion, progress and endpoint behavior. |
| C/Objective-C facade and Swift overlay | 4–6 days | View plus play/pause/seek/volume/mute, lifecycle events, errors, budgets. |
| Packaging and initial app adoption | 5–8 days | Self-contained framework, relocated host validation, WAM default route consuming it. |
| Rate, subtitles, richer tracks/metrics, migration completion | 10–15 days | Broader SDK surface and one shipping native code path. |

The MVP includes local admitted media, a presentation view, play/pause, accurate rational seek, gain/mute, metadata, events, named refusals, budgets, and asynchronous close. Default track selection is sufficient initially. Preview scrubbing, live audio/video switching, network sources, mirroring, and frame export are later capabilities.

Future acceptance work should cover rapid open/seek/close replacement, stale callbacks, observer reentrancy, view reparenting, occlusion, paused/end behavior, audio-only/video-only media, exact off-grid seeks, budget exhaustion, retirement stalls, and a non-Qt Swift host. Packaging acceptance includes dependency audits, replacement-library checks, relocation, and signed-host validation. Visible playback and audio evidence remain necessary; the handoff explicitly says the latest real-time campaign was not accepted at [`SESSION_HANDOFF.md:1403`](/Users/wesleymaa/Documents/WAM/SESSION_HANDOFF.md:1403).

**A host integration should look approximately like this.** This is proposed API usage, not code supported by today’s worktree:

```swift
import AppKit
import WAMKit

@MainActor
final class PreviewPane: NSViewController {
    private var player: WAMPlayer!
    private var observation: WAMObservation?

    override func loadView() {
        view = NSView()
    }

    func open(_ url: URL) throws {
        if player == nil {
            player = try WAMPlayer(configuration: .default)
            let video = player.presentationView
            video.frame = view.bounds
            video.autoresizingMask = [.width, .height]
            view.addSubview(video)
            observation = player.observe { event in
                print(event) // Ordered, asynchronous main-thread delivery.
            }
        }
        try player.setVolume(0.8)
        try player.open(WAMMediaItem(url: url), paused: true)
    }

    func play() throws { try player.setPaused(false) }
    func pause() throws { try player.setPaused(true) }
    func seek() throws {
        try player.seek(to: WAMTime(value: 1001, timescale: 30))
    }

    func close() async {
        await player.close()
        observation?.cancel()
    }
}
```

For sandboxed files, the host supplies authorized access. The Objective-C/Swift item should retain balanced security-scoped access for the entire open/preview/subtitle/retirement lifetime when requested. WAMKit should never present its own file picker or persist the host’s bookmarks.

**An Electron IDE can embed this, but JavaScript control and native view composition are separate integrations.**

A macOS Electron host can use a native addon linked to WAMKit, marshal calls onto AppKit’s main thread, and install its presentation view in the native window. Electron documents its macOS native window handle as an `NSView*`: [Electron BaseWindow API](https://github.com/electron/electron/blob/main/docs/api/base-window.md).

That addon must manage geometry, clipping, scaling, input, z-order, and destruction. A WAMKit view is not a DOM element: arbitrary CSS transforms and overlap with Chromium content do not automatically apply. Treat this as a dedicated native viewport adapter.

An alternative is a versioned control protocol over IPC to a native companion: open, play, pause, exact seek, volume, events, and budgets. Encode 64-bit identities and rational numerators as decimal strings for JavaScript. That protocol controls playback; it does not place an out-of-process `NSView` inside a browser page.

A browser-only IDE cannot directly load WAMKit or host its AppKit view. It needs a native companion window, a native desktop shell, or a separate web-media delivery path. Shared-texture integration is possible as another project—Electron has [native shared-texture machinery](https://github.com/electron/electron/blob/main/shell/common/api/shared_texture/README.md)—but it requires a new frame-export/presentation contract and budget analysis. It is not the proposed display-layer embedding route.