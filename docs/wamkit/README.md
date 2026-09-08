# WAMKit

WAMKit embeds WAM's native playback pipeline in a macOS AppKit host. The SDK exposes C and Objective-C, with a Clang module for `import WAMKit` in Swift. It owns one presentation view and one current media epoch per player. It never loads mpv or Qt.

The current SDK implements local-file open, play/pause, accurate rational seek, gain/mute, rate/pitch intent, state observation, optional metrics, and asynchronous stop/close. The [AppKit sample](../../examples/WAMKitHost/main.m) uses only AppKit and the public ABI.

## Build and install

Use the repository's locally provisioned native dependencies; configuration and packaging perform no downloads.

```sh
cmake -S . -B build-sdk -G Ninja \
  -DWAM_BUILD_APP=OFF -DWAM_BUILD_WAMKIT=ON \
  -DWAM_ENABLE_AVFORMAT_STAGE=ON -DWAM_ENABLE_AVCODEC_STAGE=OFF \
  -DWAMKIT_BUILD_HOST=ON -DWAMKIT_ENABLE_TEST_SUPPORT=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-sdk --parallel
cmake --install build-sdk --component WAMKit --prefix /path/to/sdk
```

`WAMKit.framework` installs under `Library/Frameworks`. The sample option defaults ON on macOS. `WAM_BUILD_APP=OFF` returns before Qt and mpv discovery. The normal WAM app remains enabled by default and uses the same extracted native owner through its Qt adapter.

For an external CMake consumer:

```cmake
project(PreviewHost LANGUAGES OBJC)
find_library(WAMKIT WAMKit REQUIRED
  PATHS "${WAMKIT_SDK}/Library/Frameworks" NO_DEFAULT_PATH)
add_executable(PreviewHost MACOSX_BUNDLE main.m)
target_compile_options(PreviewHost PRIVATE -fobjc-arc)
target_link_libraries(PreviewHost PRIVATE "${WAMKIT}" "-framework AppKit")
target_link_options(PreviewHost PRIVATE "LINKER:-rpath,@executable_path/../Frameworks")
```

Copy the complete framework into the host's `Contents/Frameworks` before signing. Do not copy only its main binary. In Xcode, add the framework to the target, select **Embed & Sign**, and include `@executable_path/../Frameworks` in Runpath Search Paths. Its module map supports `import WAMKit`; no bridging header is needed for Swift. The Objective-C `WAMPlayer` facade is imported as `@MainActor`.

The display route requires macOS 14+. This local arm64 package includes a libvpx binary whose load floor is macOS 26.0; its effective deployment floor is therefore 26.0. Rebuild that dependency at the intended floor and validate on that OS before advertising macOS 14 support. See the packaged `Resources/PackagingAudit.json` for every image's architecture and build-version commands.

## Swift Package and SwiftUI sample

The root [Package.swift](../../Package.swift) vends `WAMKit` as a local binary target. First build the framework, then assemble the arm64 XCFramework and build the sample:

```sh
cmake --build build --parallel
cmake --build build --target WAMKitSwiftHost --parallel
```

[build_wamkit_swift.py](../../scripts/build_wamkit_swift.py) invokes `xcodebuild -create-xcframework` on the CMake-built framework, writes `build/WAMKit.xcframework`, and invokes `swift build` with local caches and no remote dependencies. It packages the executable at `build/examples/WAMKitSwiftHost/WAMKitSwiftHost.app`, preserving and signing the embedded framework closure. This first package is arm64 only and declares the actual macOS 26 deployment floor of the supplied libvpx binary.

Add this checkout as a local Swift package after assembly:

```swift
// In your Package.swift:
dependencies: [.package(path: "/path/to/wam")],
// In your target:
dependencies: [.product(name: "WAMKit", package: "wam")]
```

The package identity in the product dependency is the checkout directory's lowercased basename; adjust `wam` to that name. An Xcode app can add the checkout with **Add Local Package** and select the WAMKit library product. Preserve the whole embedded framework and its notices when packaging your consumer.

[WAMKitSwiftHost.swift](../../examples/WAMKitSwiftHost/WAMKitSwiftHost.swift) is a SwiftUI consumer with an AppKit-owned window. `NSHostingView` hosts the controls; `NSViewRepresentable` embeds `WAMPresentationView`. Its `@MainActor` observable model uses the public C API for open/play/pause/rational seek/close, ordered state events and metrics. The presentation view remains retained through close. The host owns file panels and reports named refusals directly. A measured background launch constructs its window explicitly, avoiding SwiftUI's automatic scene-opening behavior for direct executable launches.

CTest registers `wamkit_swift_build` when Swift and a working full Xcode toolchain are present on arm64. With private test support enabled, MP4, Matroska and refusal tests depend on that build and run the same embedding checker as the Objective-C host. The generated XCFramework is local build output, not checked-in binary content.

## Offline signing preparation

[sign_release.sh](../../scripts/sign_release.sh) signs fresh copies of the framework, both sample hosts and WAM.app inside-out. It signs all nested Mach-O images, including the dynamically loaded FFmpeg closure, then nested bundles and their enclosing applications, with hardened runtime. It verifies each top-level input using `codesign --verify --deep --strict`, records `spctl --assess` results, and creates `WAM-notarization-input.zip` with a SHA-256 receipt.

```sh
# Local verification without a Developer ID identity:
sh scripts/sign_release.sh --ad-hoc --output build/signing-local

# Offline preparation with an installed identity and a fully bundled app:
sh scripts/sign_release.sh --identity YOUR_CERTIFICATE_SHA1 --app stage/WAM.app
```

Output must be a new directory under `build/` or the dedicated WAMKit scratch directory. Source bundles are not re-signed in place. `--app` should select the fully deployed Qt app for distribution; the default build app is suitable for local signature verification but may still reference development-machine Qt libraries.

The entitlement policy is unchanged: WAM, WAMKit and the sample hosts receive no hardened-runtime exceptions. Playback does not request microphone access. Quick Look extensions retain the existing `com.apple.security.app-sandbox=true` entitlement required by their sandboxed extension execution. Library validation remains enabled; distribution must include and sign the complete non-system closure with the host's team identity. No JIT, unsigned-executable-memory, debugging or library-validation exception is added.

The script performs no network operation and never submits notarization. It explicitly uses `--timestamp=none`; its archive is preparation material, **not a notarized distribution**. Gatekeeper rejection is retained in `signing-report.json`, and `distribution_ready` remains false. On this machine the hardened ad-hoc sample copies also fail before startup with dyld’s different-Team-IDs library-validation rejection. Their strict signatures are valid, but they are not runnable distribution proofs; no library-validation exception is used to bypass this. The owner must obtain Apple Developer Program membership and a **Developer ID Application certificate with its matching private key**, install them in an unlocked signing keychain, then arrange an authorized online release pass for trusted timestamps, notarization credentials/submission and stapling. Developer ID identity and Gatekeeper validation remain unproven on this machine, which has zero valid signing identities.

The macOS CI workflow invokes `--if-identity` after app deployment. It is a no-op without the `WAM_MACOS_CODESIGN_IDENTITY` secret. When supplied, that secret selects an identity whose certificate/private key must already be provisioned in the runner keychain; a certificate fingerprint alone cannot sign. The existing protected release workflow remains responsible for online notarization.

## Embed a player

```objc
#import <WAMKit/WAMKitObjC.h>

NSError *error = nil;
WAMPlayer *player = [[WAMPlayer alloc] initWithError:&error];
WAMPresentationView *video = player.presentationView;
video.frame = container.bounds;
video.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
[container addSubview:video];
player.eventHandler = ^(const wam_event_t *event) {
    if (event->kind == WAM_EVENT_REFUSAL)
        NSLog(@"Native refusal: %s", event->error.name);
};
[player openFileURL:url initialPosition:(wam_time_t){0, 1, 0}
             paused:YES error:&error];
```

Enable transport controls after the open request completes. A Play action calls `[player setPaused:NO error:&error]`; Pause passes `YES`. A seek action calls `[player seekToTime:(wam_time_t){1001, 30000, 0} error:&error]`. On teardown, call `[player closeWithError:&error]` and observe its terminal result. The BOOL return reports command acceptance, not completed playback or retirement.

Retain the player until its close result if the host needs confirmation. The host owns its window, constraints, activation policy and file authorization. Hold any security-scoped file access through retirement; the SDK does not acquire bookmarks or show file pickers. The player retains the view, and the view does not retain the player. Resize, hide, remove and reparent it on main. Removing it does not stop audio. Do not replace its internal layers or enqueue/flush renderer samples.

## C ABI version 1

The authoritative declarations are [WAMKit.h](../../src/wamkit/include/WAMKit/WAMKit.h) and [WAMKitObjC.h](../../src/wamkit/include/WAMKit/WAMKitObjC.h). The [export list](../../src/wamkit/exports.txt) admits exactly eighteen C functions and the class/metaclass symbols for `WAMPlayer` and `WAMPresentationView`.

| Functions | Contract |
|---|---|
| `wam_abi_version`, `wam_copy_capabilities`, `wam_refusal_name` | ABI version, compiled stages, fixed budgets/current charged admissions, symbolic code names. Thread-safe. |
| `wam_player_create`, `wam_player_retain`, `wam_player_release` | Main-thread handle ownership. Final release invalidates delivery and initiates asynchronous retirement. |
| `wam_player_observe` | Replace the callback/context; NULL cancels delivery. Registration never calls back synchronously. |
| `wam_player_open_file` | Copy an absolute UTF-8 path and exact initial position; asynchronous native admission. |
| `wam_player_set_paused`, `wam_player_seek` | Requested transport intent; accurate seek retains exact target/generation/frame coverage. |
| `wam_player_set_volume`, `wam_player_set_muted`, `wam_player_set_rate` | Gain 0–4, independent mute, rate 16–256 units per 64 and preserve-pitch flag. Configuration completion means intent was published; clock/state observations describe application. |
| `wam_player_stop`, `wam_player_close` | Stop returns to reusable Empty. Close permanently rejects new commands, then reports Completed or Quarantined. |
| `wam_player_copy_snapshot`, `wam_player_set_metrics_enabled` | Copy the latest observation cache; explicitly enable/disable the coalesced 250 ms sampler. |
| `wam_player_presentation_view` | Borrowed `NSView *` through `void *`; valid while its owning player is retained. |

Public types: `wam_player_t`, `wam_request_id_t`, `wam_status_t`, `wam_state_t`, `wam_result_t`, `wam_event_kind_t`, `wam_refusal_t`, `wam_time_t`, `wam_error_t`, `wam_snapshot_t`, `wam_event_t`, `wam_capabilities_t`, `wam_event_callback_t`, `WAMPlayer`, `WAMPresentationView`.

Initialize snapshot/capability `struct_size` to `sizeof` before copying. Initialize reserved fields to zero. All strings are UTF-8. Callback event/error strings are inline arrays; copying the complete event extends its lifetime. ABI v1 layouts and explicit numeric values are fixed; unknown future event kinds must be ignored. No public header imports Qt, C++ containers, native source contracts or decoder types.

## Ordering, threads and time

Every player operation, view access, observation change and handle retain/release requires AppKit main. Wrong-thread calls return `WAM_WRONG_THREAD`. The three global query functions are the exception. Source work runs on bounded native workers; graph destruction/join runs off main, with AppKit cleanup returned to main.

Public callbacks run asynchronously on main, after engine locks are released. A callback may issue commands, replace/cancel observation, or release the player. Commands issued in callbacks execute on the next dispatch turn. Delivery is per-player ordered; state/metrics are coalesced. Up to 32 accepted requests may await terminal delivery; excess returns `WAM_BACKPRESSURE`. Cancellation or final release prevents later client callbacks, including the remainder of a queued batch.

An accepted open or seek has one terminal result: Completed, Superseded, Cancelled or Failed. Replacement open/stop/close cancel outstanding seek intent. Play/pause completion follows its applied run-state observation. Requested pause intent is separate from applied player state. Close has a ten-second main-queue deadline: Quarantined explicitly leaves `retiring=1` and resource admission charged. A later Closed state with `retiring=0` reports actual destruction, without a second close result.

A `wam_time_t` is a signed 64-bit numerator and positive 32-bit timescale. Zero timescale means unknown in observations and is invalid as an input target. Inputs are reduced using integer arithmetic. Negative targets and nonzero reserved bits fail validation. Seek targets must be strictly below the exact presentable ceiling.

For `T=1001/30000` and decoded audio rate 48,000 Hz, `A=ceil(T*48000)/48000=267/8000`. Completion preserves `requested_target`, `audio_presentation_start`, `decode_start`, the half-open covering video interval and generation. Audio-only/video-only completion explicitly marks the absent lane. Existing app double entry points retain their compatibility semantics; rational requests use a separate private proof, never a fraction reconstructed from display seconds.

`display_seconds` is approximate. `clock_rate` is the native clock's requested rate, not a measured wall-clock advancement ratio. First PTS is retained from the first physically acknowledged renderer submission, before observation coalescing. Draw counters use WAM's existing renderer-acceptance semantics. Public compositor drop metrics are unavailable; the SDK build excludes the SPI metrics call. Counters are sampled only when metrics are enabled and retain their latest sampled values when disabled.

## Refusals

`wam_error_t.code` is a stable coarse code; `name` preserves the primary native symbolic reason and `detail` retains bounded backend context. `related_names[0..related_count)` preserves additional named refusal prefixes from the same native failure record. This transport reads the engine's failure fields; it never reconstructs causes from stderr. Hosts inspect names directly and need not parse diagnostic prose. Unlisted native names use `WAM_REASON_NATIVE_DETAIL` and remain available by their exact name.

The ABI names stable numeric codes for:

- `UnsupportedSourceScheme`, `SourceAccessDenied`, `UnsupportedContainer`
- `DecoderStageNotBuilt`, `DecoderUnavailable`
- `PresentationRequiresMacOS14`, `PresentationUnavailable`
- `InvalidTime`, `TimeOverflow`, `SeekOutOfRange`, `SeekStalled`
- `RateUnsupported`, `InvalidVolume`
- `SessionBudgetExceeded`, `RetirementCapacityUnavailable`
- `AudioOutputUnavailable`, `InternalProtocolViolation`
- `HeAacSbrDecoderDelayUnproven`

The refusal fixture proves primary `HeAacSbrDecoderDelayUnproven` and related `LibavformatAudioTimingUnproven`. Source/decode implementation refusals outside the coarse enumeration retain their own names. No fallback renderer or compatibility decoder is provided by WAMKit.

Admission limits remain 16 native graphs, 10 decoded surfaces / 384 MiB per session, and 160 surfaces / 6 GiB per engine image. These are ceilings, not performance promises. Charged admissions include preparation and retirement. Capability snapshots are advisory; actual admission is atomic. Do not co-load statically linked copies of the native engine alongside WAMKit in one process.

## Decoder closure and redistribution

`Versions/A/WAMKit` has install name `@rpath/WAMKit.framework/Versions/A/WAMKit`. Its private `Frameworks` directory contains libvpx and `libavformat-wamnative.63.dylib`, `libavcodec-wamnative.63.dylib`, `libavutil-wamnative.61.dylib`. FFmpeg remains lazily loaded from the framework image's own directory. No Homebrew search path is used at runtime. AVFormat ON / AVCodec stage OFF is the tested configuration; bundling avcodec as an avformat dependency does not enable its playback decoder adapters.

`Resources/ThirdPartyNotices` includes LGPL 2.1-or-later texts, native-stage notices, libvpx's license, configuration and build receipts. `Resources/CorrespondingSource` includes the pinned FFmpeg source archive, memory-reservation patch and scripts needed to reproduce it. Preserve and distribute these with the SDK/application. The native closure is separate from WAM's app-only export FFmpeg and mpv closures.

Keep the LGPL libraries dynamically replaceable. Rebuild ABI-compatible replacements from the included recipe, replace the `-wamnative` dylibs, and keep their dependency paths local to the framework's private directory. Runtime checks validate ABI/license/configuration compatibility, not the distributor's byte hashes. Sign nested dylibs first, the framework next, then the complete host with the host team's identity; notarize the resulting application. Local proof builds use ad-hoc signing. Do not disable library validation as an integration default. Preserve applicable user modification and debugging/reverse-engineering rights described by the included LGPL text.

WAM's own redistribution/license grant remains a maintainer decision. The FFmpeg notices do not license WAM's code. Clean-machine, macOS 14, additional architecture and Developer ID/notarization validation remain release work.

## Proofs and scope

[REPORT.md](REPORT.md) links the test, revert, replay and packaging receipts. `WAMKIT_ENABLE_TEST_SUPPORT=ON` enables private identity-gated quiet/stall seams for those tests; it defaults OFF and is not part of the public ABI. Normal events require no environment variables. The sample's measured harness streams `WAM_PLAYBACK_METRICS_PATH` on a bounded file-writing queue and uses the required benchmark identities, background geometry and output-copy mute. Fixtures are synthetic and reproducible with [generate_wamkit_fixtures.py](../../scripts/generate_wamkit_fixtures.py).

Deliberately absent: Qt types, STL types, source-contract headers, decoder handles, mpv fallback, external frame access, preview scrubbing, mirroring, live track switching, subtitle overlays, export/caption generation, network playback, file panels/bookmark persistence in the SDK, host activation/menu/preferences and power-activity policy, and a Swift concurrency convenience layer beyond the Objective-C MainActor facade. The app consumes the extracted native owner through static archives. The `wamkit_dogfooding` audit restricts Qt to that shared owner, preflight and host-policy interface; session ownership and observation-bridge storage are private. Qt-specific presentation construction remains in the platform adapter. Migration to a single dynamic WAMKit image remains separate work.
