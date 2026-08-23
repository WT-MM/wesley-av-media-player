# WAM QuickLook Thumbnail Extension — design skeleton

> **NOT WIRED INTO THE BUILD.** Every file in `packaging/quicklook/` is inert.
> Nothing here is referenced by `CMakeLists.txt`, by `packaging/Info.plist.in`,
> or by any workflow under `.github/workflows/`. There is no target, no
> `install()` rule, and no codesign step for this appex. Deleting this whole
> directory changes nothing about what WAM builds or ships. It is a design
> record plus templates, written after a standalone de-risking experiment
> (2026-08-23) that proved the QuickLook plumbing works on this machine.

## Why

macOS ships no Matroska demuxer, so Finder shows a generic document icon for
`.mkv` / `.webm`. WAM already owns a complete, Qt-free Matroska read path, so it
can supply the frame the system cannot produce.

Note the policy tension: `packaging/Info.plist.in:42-63` deliberately declines
to set `CFBundleTypeIconFile` on any document type, precisely so WAM does *not*
replace Finder's per-file video thumbnail with a static icon. A thumbnail
extension is the same goal reached from the other side — it *supplies* the
per-file frame rather than suppressing it — but that comment block should be
updated alongside any decision to ship this.

## What the experiment proved (2026-08-23, macOS 26.3.1, Xcode 26.6)

A minimal standalone appex (solid-colour draw, no decoding) embedded in a host
`.app`, ad-hoc signed:

| Fact | Result |
| --- | --- |
| Baseline `.mkv` via `QLThumbnailGenerator` | `type=0 (icon)` — generic |
| With the extension registered | `type=2 (thumbnail)` — our drawing |
| Ad-hoc signature (`codesign -s -`) | **Sufficient.** No Developer ID needed to run locally. |
| `com.apple.security.app-sandbox` | **REQUIRED.** Without it `pluginkit` refuses to register the appex at all. |
| `com.apple.security.files.user-selected.read-only` | **NOT required.** |
| Reading the file being thumbnailed | `open(O_RDONLY)` + `pread` at offset 0 **and** at `size-1024` on a 90 MB `.mkv` all succeeded with `app-sandbox` alone. |
| `.webm` (`org.webmproject.webm`) | Works, same path. |
| Time budget | No kill observed at a 40 s stall on the `QLThumbnailGenerator` path. |
| `qlmanage -t` | **Hangs on `.mkv` even with a working extension.** Not a valid test tool. |

The sandbox point is the important one: QuickLook hands the extension a
read-only sandbox extension for the specific `QLFileThumbnailRequest.fileURL`,
covering the *whole* file, not just its head. Random access to the Cues at EOF
— which is exactly what the demuxer needs — works without any file-access
entitlement. `app-sandbox` on its own is the complete entitlement set.

**Untested combination:** the experiment signed ad-hoc *without* hardened
runtime. Release mode signs with `--options runtime`
(`scripts/bundle_macos_lib.zsh:1692`). Sandbox + hardened runtime + Developer ID
was not exercised and must be re-verified before shipping.

### Registration steps that were actually required

1. Host `.app` with `Contents/PlugIns/<name>.appex`.
2. Sign **inner first**: the appex (with entitlements), then the outer app.
3. Host app must live somewhere LaunchServices will keep — `~/Applications`
   worked; `/private/tmp` did not survive.
4. `lsregister -f <host.app>` — **required**. Without it `pluginkit -a`
   registers the appex and `pkd` silently prunes it within seconds.
5. `pluginkit -a <path/to/.appex>` then `pluginkit -e use -i <appex-bundle-id>`.
6. `qlmanage -r cache` before testing — **required**. The thumbnail cache
   returns stale `type=0` results indefinitely and will make a working
   extension look broken.

`pluginkit -m -p com.apple.quicklook.thumbnail` reported *no matches* even when
the extension was registered and working; query by `-i <bundle-id>` instead
(`+` prefix means enabled).

## Decode design

The appex must **not link Qt**. It does not need to: the whole read path is
already Qt-free, and `CMakeLists.txt:1362-1397` already builds
`wam_matroska_preview_source_test` from this exact source set linking only
`wam_native_core`, `wam_macos_native_video_core`, and system frameworks.

Verified Qt-free (no `Qt*` include, no `Q`-prefixed type in any public
interface): `src/media/matroska_demuxer.{hpp,cpp}`,
`src/media/matroska_ebml.{hpp,cpp}`, `src/media/native_media_source.hpp`,
`src/platform/macos/matroska_sample_builder.{hpp,mm}`,
`src/platform/macos/video_toolbox_decoder.{hpp,mm}`,
`src/platform/macos/native_video_presenter.hpp`.

### Pipeline

1. **Prepare.** `prepareMatroskaLocalFile(path, options, cancellation)`
   (`src/media/matroska_demuxer.hpp:270`) → `MatroskaPrepareOutcome` carrying a
   `std::shared_ptr<const MatroskaPreparedAsset>`. It opens once with
   `O_RDONLY|O_CLOEXEC` and retains that descriptor — the exact syscall pattern
   the experiment proved works inside the sandbox.

2. **Pick a target.** *Do not use frame 0* — the first frame of a real encode is
   very often black or a fade-in. Aim a few seconds in, clamped to the
   container's duration (short clips must fall back toward 0 rather than past
   the end). `MatroskaPreparedAsset::cues()` (`:224`) exposes the Cue index; a
   Cue is a random access point by construction.

3. **Plan.** `planGeneration(target, MediaSeekMode::Accurate)` (`:226`) is
   `const` and cursor-free, and returns a `MatroskaGenerationPlan` whose
   `actualDecodeStart` (`:164`) is already a keyframe. There is no back-walk to
   write. For a thumbnail, seek *mode* matters less than landing on a RAP — the
   plan's `actualDecodeStart` is the frame we will render, and being a second or
   two off the request is invisible in a thumbnail.

4. **Read one sample.** `makeVideoCursor(plan)` (`:230`) →
   `MatroskaCursor::readNext()` → `MatroskaCompressedSample` with
   `keyFrame == true` (`:156`). Samples are payload-free frame *ranges*.

5. **Build a CMSampleBuffer.**
   `createMatroskaVideoFormatDescription(track)`
   (`src/platform/macos/matroska_sample_builder.hpp:148`) then
   `buildMatroskaCompressedSampleBuffer(inputs, sample, &out, &error)` (`:159`).
   `MatroskaSampleBuildInputs` (`:132`) wants the prepared asset, a cancellation
   token, the format description, and `video = true`.

6. **Decode.** `VideoToolboxDecoder`
   (`src/platform/macos/video_toolbox_decoder.hpp:212`): `configure(...)` (`:222`)
   then `submitCMSampleBuffer(sample, generation, ...)` (`:237`). Request
   `VideoToolboxOutputInterop::Metal` — **not** `DisplayLayer`, because we must
   read the pixels back in-process, and the header (`:54-63`) notes the
   DisplayLayer contract stops pinning an uncompressed pixel format. A lossless
   compressed surface cannot be sampled by CPU.

7. **CVPixelBuffer → CGImage.** `VTCreateCGImageFromCVPixelBuffer` is the direct
   route; a `CIContext`-backed render is the fallback for odd pixel formats.
   Return via `[QLThumbnailReply replyWithContextSize:drawingBlock:]` and draw
   the `CGImage` into the supplied `CGContextRef`, letter/pillar-boxed to
   preserve aspect ratio, honouring the track's display aspect if it differs
   from coded dimensions.

### What NOT to reuse

`src/platform/macos/matroska_preview_source.{hpp,mm}` looks like the obvious
candidate and is not. `MatroskaPreviewSource::create()` requires a binding whose
`assetContext` is an already-live `MatroskaAssetContext` — its header states
there is deliberately *no cold-load path*, because admitting a file is the main
source's job. The appex has no main source. Go through the demuxer directly.

`.ts` is a different demuxer: `prepareMpegTsLocalFile`
(`src/media/mpegts_demuxer.hpp:349`), UTI `public.mpeg-2-transport-stream`
(already a system UTI). Same shape, separate branch — and worth confirming
macOS genuinely fails on `.ts` before claiming it, since AVFoundation has
partial MPEG-TS support.

### Time budget

No hard kill was observed up to 40 s, but that is the API path, not Finder's
patience — Finder shows the generic icon until the reply lands, so a slow
provider reads as a broken one. Target **< 500 ms** typical, hard-stop at ~3 s
via the `CancellationToken` that every demuxer entry point already accepts, and
on timeout call the handler with an error so the system falls back to the
generic icon rather than blocking. Prepare + plan is cheap (the Cue index is
read, not scanned, when Cues are present); a single keyframe decode dominates.
Files with no usable Cues fall back to the scanned synthetic index, which is
the case most at risk of blowing the budget.

## Packaging consequences

Full detail lives in the de-risking report; the load-bearing facts:

- **`scripts/bundle_macos_lib.zsh`**, `wam_bundle_mutate_staged_app()` (`:813`).
  Its Mach-O inventory (`:1224-1235`) is a bare recursive
  `find "$APP_PATH/Contents" -type f`, selecting by `file -b` magic. **A nested
  appex binary IS walked** by the self-containment audit.
- But the *repair* walk is seeded from only four roots (`:1001-1013`): the WAM
  executable, the mpv fallback dylib, `ffmpeg`, `whisper-cli`. **An appex is
  never enqueued, so nothing rewrites its install names.** It must arrive
  already self-contained or the audit hard-fails at `:1444-1459`.
- Correct rpath from `Contents/PlugIns/X.appex/Contents/MacOS/` is
  `@loader_path/../../../../Frameworks` (four levels). **Verified empirically** —
  a test binary at that depth resolved an `@rpath` dylib in
  `Contents/Frameworks` and ran.
- Nested-bundle signing already handles this: `.appex` is *already* in the
  container pattern list at `:1708`, and the `(@Oa)` reversal at `:1713` yields
  inner-to-outer order. Verified against a synthetic nested tree.
- The signing loop uses one flat `signing_arguments` array for all leaves
  (`:1690-1695`) with **no per-target entitlements hook**. Giving the appex
  `app-sandbox` requires a per-target branch there.
- `verify_release_signature_facts()` (`:1641-1669`) currently expects no
  entitlements beyond prohibiting `get-task-allow`; it must learn to accept the
  appex's sandbox entitlement.
- **libvpx risk:** `release.yml:66-67` builds `-DWAM_ENABLE_SOFTWARE_VP8=ON`, so
  `wam_macos_native_video_core` carries a Homebrew `PkgConfig::WAM_LIBVPX`
  edge (`CMakeLists.txt:399`). Linking that library into the appex acquires a
  dependency nothing rewrites for it. Either link a VP8-free subset, or add the
  appex as a closure-walk seed.
