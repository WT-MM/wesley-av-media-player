# WAM QuickLook Thumbnail Extension

`WAMThumbnail.appex` supplies Finder thumbnails for the video containers macOS
cannot demux. It is built by `CMakeLists.txt` (target
`wam_quicklook_thumbnail`, `option(WAM_BUILD_QUICKLOOK_APPEX)`), embedded at
`WAM.app/Contents/PlugIns/WAMThumbnail.appex`, and signed with its own
entitlements by `scripts/bundle_macos_lib.zsh`.

## Why

macOS ships no Matroska demuxer, so Finder shows a generic document icon for
`.mkv`. WAM already owns a complete, Qt-free Matroska read path, so it can
supply the frame the system cannot produce.

**Scope check, measured 2026-08-23 on macOS 26.3.1:** this OS *already*
thumbnails `.webm` and `.ts` natively — with the extension disabled,
`vp9.webm` and an H.264 transport stream both return `type=2`. The extension's
unique value on this OS is therefore **`.mkv`**. Those other types remain
claimed because the same code serves them at no extra cost and older supported
systems (deployment target 13.3) do not have that native support; where the
system already answers, the system wins and nothing regresses.

Note the policy tension: `packaging/Info.plist.in` deliberately declines to set
`CFBundleTypeIconFile` on any document type, precisely so WAM does *not*
replace Finder's per-file video thumbnail with a static icon. This extension is
the same goal reached from the other side — it *supplies* the per-file frame
rather than suppressing it.

## Layout

| File | Role |
| --- | --- |
| `wam_thumbnail_frame.hpp` / `.mm` | the decode pipeline: prepare → plan → one keyframe → `CMSampleBuffer` → VideoToolbox → `CGImage` |
| `WAMThumbnailProvider.mm` | Objective-C shim: URL plumbing, aspect fit, `CGImage` ownership, `os_log` |
| `Info.plist` | appex bundle plist template (`@VAR@`, configured by CMake) |
| `WAMThumbnail.entitlements` | signing input — **must contain no XML comments** (see below) |
| `../../tests/quicklook_thumbnail_frame_test.mm` | CLI harness over the same sources; ctest `macos_quicklook_thumbnail_frame` |

The decode pipeline is split out of the provider on purpose. A QuickLook
extension is close to untestable in place: it runs in a system-launched
sandboxed process, its stderr goes nowhere a test can read, and the only
observable is whether Finder eventually shows a picture. Everything that can
actually be wrong therefore lives behind a plain C++ entry point that a command
line can drive:

```
build/wam_quicklook_thumbnail_frame_test -o /tmp/out some.mkv some.ts
```

## Self-containment: the load-bearing constraint

`scripts/bundle_macos_lib.zsh` audits every Mach-O under `Contents/` — the
`find` is unfiltered, so a nested appex binary **is** walked, and
`.github/workflows/release.yml`'s own gate walks it too. But the install-name
**repair** walk is seeded from only four roots (the WAM executable, the mpv
fallback, `ffmpeg`, `whisper-cli`) and never enqueues an appex. Anything the
appex needed rewritten would hard-fail the release.

So the appex is built to need no repair at all. `otool -L` shows **only**
system frameworks plus `libc++`/`libSystem`/`libobjc`, and `LC_RPATH` is
**empty**. Total bundle: **420 KB**.

It links:

* `wam_native_core` — Qt-free, and declares no link dependencies of its own.
* `matroska_sample_builder.mm`, `mpegts_sample_builder.mm`,
  `native_video_codec_capability.mm` — compiled directly in, exactly as
  `wam_matroska_preview_source_test` does.

It deliberately does **not** link `wam_macos_native_video_core`: that archive
carries `software_vp8_decoder` and therefore a Homebrew `PkgConfig::WAM_LIBVPX`
edge whenever `WAM_ENABLE_SOFTWARE_VP8` is on — which `release.yml` sets. That
single edge is the one thing that would fail the gate.

### The VP8 symbol

`matroska_sample_builder.mm` gates its VP8 branch on a *runtime*
`SoftwareVp8Decoder::available()` call, not on `#if WAM_ENABLE_SOFTWARE_VP8`, so
the symbol is referenced whatever the flags say. Two approaches were tried and
rejected, both with evidence:

* `-UWAM_ENABLE_SOFTWARE_VP8` on the target — useless, the guard is not in that
  translation unit; the link still failed.
* compiling the real `software_vp8_decoder.mm` with the define off — it drags
  `FrameLease` and the whole presenter closure in behind it.

`wam_thumbnail_frame.mm` therefore defines that one function to return `false`,
which is byte-for-byte the behaviour the production source has when
`WAM_ENABLE_SOFTWARE_VP8` is undefined. **Consequence: VP8-in-WebM gets no
thumbnail** and falls back to the generic icon. Every codec VideoToolbox decodes
itself — H.264, HEVC, VP9, AV1, MPEG-4 Part 2, MPEG-2 — is served.

### Why not `VideoToolboxDecoder`

`wam::macos::VideoToolboxDecoder` is an owner-driven, generation-scoped,
sink-backed streaming state machine (reorder depth, in-flight credit,
drain/retire lifecycle) built for continuous playback. A thumbnail needs one
frame with no ordering obligations, so the extractor drives a bare
`VTDecompressionSession`: no sink, no surface budget, no libvpx, and a bound
that is trivially auditable.

Output is pinned to `32BGRA`. That is exactly the per-frame pixel-transfer cost
`video_toolbox_decoder.hpp:54-63` documents and avoids for playback — paid once
here, in exchange for a CPU-readable surface rather than an AGX
lossless-compressed one a `CGImage` cannot be built from.

## Bounds

* One 3 s wall-clock `Deadline` backs the `CancellationToken` every demuxer
  entry point already accepts, so the bound is enforced *inside* the read
  loops, not only between them.
* A decode is refused outright with under 250 ms of budget left.
* Target is 10 % in, capped at 120 s, clamped to `duration - 1` tick. Never
  frame 0 — first frames are routinely black or a fade-in.
* Keyframe search is a fixed small bound (4 reads for Matroska, 16 for
  transport stream, whose index is coarser). Never a scan.
* Frames above 4096 in either dimension are refused **before** any allocation:
  an 8K frame is ~130 MB of BGRA in a process the system may run several of.
* Exactly one access unit is decoded; the session is invalidated immediately.
* The provider reads `O_RDONLY` through the demuxer and **writes nothing,
  anywhere**.
* Failure replies with an `NSError`, never a blank drawing — a blank reply
  caches a blank thumbnail, and the cache is sticky.

## UTIs

```
org.matroska.mkv
org.webmproject.webm
public.mpeg-2-transport-stream
public.avchd-mpeg-2-transport-stream
```

Aligned with the host app's imported types in `packaging/Info.plist.in`.

**Deliberately absent:** `public.mpeg-4`, `com.apple.quicktime-movie` and every
other type Apple already thumbnails — claiming those would replace a working
system thumbnail with ours for no gain. Also absent: `org.matroska.mka` and all
audio types, which have no frame to show.

The appex carries its own `UTImportedTypeDeclarations` for `org.matroska.mkv`.
No Apple bundle declares that identifier, and the host app's import does not
carry over to the extension. Imported, never exported — so WAM still does not
claim ownership and merges with VLC's identical declaration rather than
conflicting.

## Signing

`wam_appex_entitlements_for()` in `scripts/bundle_macos_lib.zsh` gives the
appex — and only the appex — `WAMThumbnail.entitlements` at signing time, in
both the per-leaf and the nested-container pass. The main app keeps its own
(empty) entitlement set.

Two things this required changing:

1. **The ad-hoc path no longer uses `codesign --deep` on the outer app.**
   `--deep` re-signs nested bundles with the *outer* invocation's arguments, so
   it stripped the appex's sandbox entitlement moments after the leaf loop
   applied it. Apple warns against `--deep` for exactly this reason. Both
   signing modes now seal nested containers explicitly, inner-to-outer, then
   the outer app without `--deep`. Every Mach-O leaf was already signed
   individually, so `--deep` was only ever a catch-all.
2. **A positive gate.** After signing, any `*.appex` container must still
   report `com.apple.security.app-sandbox`, in both modes. Without the sandbox
   entitlement `pluginkit` refuses to register the extension at all — a
   registration failure, not a runtime one, which nothing else in the build
   would notice.

### `WAMThumbnail.entitlements` must contain no XML comments

`codesign`'s AMFI parser rejects them outright:

```
Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 10
```

and the message does not name the file. `wam_appex_entitlements_for()`
`plutil -lint`s it first so the failure is at least attributable.

`verify_release_signature_facts()` needed **no** change: it only prohibits
`com.apple.security.get-task-allow` and otherwise accepts any valid
entitlements plist, so it already tolerates `app-sandbox`.

## Verified

Bundle pipeline, full staged app (`cmake --install` → `fix_qt_qml_deploy_macos`
→ `bundle_macos.zsh`): **green**, 169 Mach-O files audited including the appex
binary, appex signed as a nested container with its entitlement intact
afterwards. `release.yml`'s self-containment gate run verbatim against the
staged app: **PASS**, and confirmed to walk
`WAM.app/Contents/PlugIns/WAMThumbnail.appex/Contents/MacOS/WAMThumbnail`.

Decode, via `wam_quicklook_thumbnail_frame_test` (frames written to PNG and
visually confirmed to be real video):

| fixture | container / codec | time |
| --- | --- | --- |
| `h264.mkv` 2.1 MB | Matroska / H.264 | 135 ms |
| `hevc.mkv` 0.8 MB | Matroska / HEVC | 12 ms |
| `vp9.webm` 19.5 MB | WebM / VP9 | 111 ms |
| `av1.mkv` 47.2 MB | Matroska / AV1 | 147 ms |
| `h264.ts` 2.2 MB | MPEG-TS / H.264 | 9 ms |

Live, inside the sandboxed extension, from its own `os_log`:

```
WAMThumbnail[97919] [com.wesleymaa.wam.quicklook:thumbnail]
    thumbnail for .../vp9.webm: 1920x1080 into 256x256
```

— the extension launched by `com.apple.quicklook.ThumbnailsAgent`, running
under `app-sandbox` with an ad-hoc signature, reading a 19.5 MB file and
returning a rendered reply.

## Known gap

`.mkv` does not currently reach **any** QuickLook thumbnail extension on the
development machine. The control: the standalone experiment appex that
`movie_file_report.md` records as reaching `type=2` earlier the same day fails
identically when re-registered. `ThumbnailsAgent` logs `No extension found` for
every `.mkv` request; claiming `public.movie` as a diagnostic also failed to
route; and the agent (which caches its discovered extension set) cannot be
restarted — `launchctl kickstart` returns `150: Operation not permitted while
System Integrity Protection is engaged`. A logout/login or reboot is the
remedy. Re-verify `.mkv` end-to-end after one.

## Registration, for local testing

1. Host `.app` in a location LaunchServices keeps — `~/Applications` works,
   `/private/tmp` does not.
2. Sign inner first (appex, with entitlements), then the outer app.
3. `lsregister -f <host.app>` — **required**; without it `pkd` prunes the
   appex within seconds.
4. `pluginkit -a <path/to/.appex>` then `pluginkit -e use -i <appex-id>`.
5. `qlmanage -r cache` before every test — the cache serves stale `type=0`
   indefinitely and makes a working extension look broken.

An appex's bundle identifier must be prefixed by its containing app's
(`com.wesleymaa.wam` + `.quicklook.thumbnail`); a throwaway test host must
preserve that relationship.

### Tooling that lies

* **`qlmanage -t` hangs on `.mkv`** even with a fully working extension — it
  drives the *preview* path, not the thumbnail-extension path. Use a
  `QLThumbnailGenerator` harness.
* **`pluginkit -m -p com.apple.quicklook.thumbnail`** reports no matches even
  when the extension is registered and working. Query `-i <bundle-id>` instead
  (`+` prefix means enabled).
* A `type=2` result is **not** proof the extension ran — this OS answers for
  `.webm` and `.ts` itself. A/B against `pluginkit -e ignore`, or read the
  `os_log` subsystem `com.wesleymaa.wam.quicklook`.

## Still unverified

Sandbox + **hardened runtime** + Developer ID. Release mode signs with
`--options runtime`; the ad-hoc local path does not, and this machine has no
signing identity. Must be re-verified on the first tagged run.
