# macOS packaging audit

Snapshot: 2026-08-10, WAM 0.3.0.

## Definitive cause of the launch crash

The affected executable had UUID
`39A6EFA4-33AA-300B-BAA5-FEF4B0E92D37`. Four crash reports for that image
ended with `CODESIGNING`, code 2, `Invalid Page` while `QQmlThread` was in
`QMachOParser` / `QPluginLoader`.

This was not a decoder or libmpv failure. An explicit leaf audit found 31
unsigned Mach-O QML plugins under `Contents/Resources/qml`. In three reports,
the parser's file-length argument was 93,872 bytes, exactly the length of the
unsigned file:

```text
Contents/Resources/qml/QtQuick/Controls/libqtquickcontrols2plugin.dylib
```

The outer bundle nevertheless passed `codesign --verify --deep --strict`.
Executable QML plugins live below `Resources`, which `codesign --deep` does not
reliably discover as nested code. It can therefore validate the bundle seal
while missing an invalid executable page that macOS later maps and kills.

The packaging regression gate in `scripts/bundle_macos.zsh` now inventories
every Mach-O below `Contents`, signs every leaf before the outer app, verifies
every leaf independently, and finally performs deep bundle verification. Do
not replace those leaf loops with `codesign --deep` alone.

## Current fixed bundle

The audited fixed bundle had executable UUID
`B4839199-9CC6-30F1-819F-84467CD05289` and produced these static results:

- 193 of 193 Mach-O leaves passed strict signature verification.
- All 1,056 non-system dependency edges resolved within the app.
- No external absolute dependency or package-manager/build rpath remained.
- All 193 Mach-O images were thin `arm64`.
- The outer bundle passed deep strict verification.

The ordinary local bundler mode remains intentionally ad hoc. Public builds use
the separate release policy described below: explicit inside-out Developer ID
signing (including QML leaves), hardened runtime, secure timestamps,
notarization, stapling, Gatekeeper assessment, and a post-staple artifact.

## Reproducible verification

Run these from the repository root. Set `APP` to the final staged artifact,
never an earlier build directory.

```zsh
APP="${APP:-dist/WAM.app}"

codesign -dv --verbose=4 "$APP" 2>&1
codesign --verify --deep --strict --verbose=2 "$APP"

count=0
failures=0
while IFS= read -r -d '' candidate; do
  file "$candidate" | grep -q 'Mach-O' || continue
  (( count += 1 ))
  if ! codesign --verify --strict "$candidate"; then
    print -u2 -- "Invalid leaf: ${candidate#$APP/}"
    (( failures += 1 ))
  fi
done < <(find "$APP/Contents" -type f -print0)
print -- "Mach-O leaves: $count; signature failures: $failures"
(( failures == 0 ))
```

Inventory architectures and deployment floors:

```zsh
find "$APP/Contents" -type f -print0 |
  while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue
    print -- "$(lipo -archs "$candidate")\t${candidate#$APP/}"
  done | awk -F '\t' '{ count[$1]++ } END {
    for (value in count) print value, count[value]
  }' | sort

find "$APP/Contents" -type f -print0 |
  while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue
    minos="$(otool -l "$candidate" | awk \
      '/LC_BUILD_VERSION/{ seen=1; next }
       seen && /minos/{ print $2; exit }')"
    print -- "${minos:-unknown}\t${candidate#$APP/}"
  done | awk -F '\t' '{ count[$1]++ } END {
    for (value in count) print value, count[value]
  }' | sort -n
```

`scripts/bundle_macos.zsh` performs the stricter dependency-resolution audit:
every non-system `@loader_path`, `@executable_path`, and `@rpath` reference must
resolve to a real file inside the app, and every runtime search path must stay
inside it. A successful bundler run is required in addition to the commands
above.

## Deployment-floor defect

The fixed artifact truthfully declares `LSMinimumSystemVersion=26.3`; it is not
currently a macOS 13-compatible package. Its 193 images were distributed as:

| Mach-O minimum | Images |
| --- | ---: |
| 11.0 | 1 |
| 13.0 | 1 |
| 14.0 | 22 |
| 26.0 | 168 |
| 26.3 | 1 |

The main WAM executable targets 13.0, but package-manager Qt/media binaries
were built for the current host, and `whisper-cli` alone required 26.3.
`scripts/build_whisper.sh` now gives Darwin builds an explicit 13.3 floor, the
earliest honest default for its enabled Accelerate path. A real source build
was checked with `otool` and reported 13.3.

That helper fix is only one part of the release correction. Qt, mpv, FFmpeg,
and their closure must also come from a pinned clean build targeting the chosen
release floor. Development packaging still records the maximum actual
`LC_BUILD_VERSION` in `Info.plist`. When `WAM_MACOS_RELEASE_FLOOR=13.3` is set,
the bundler instead inspects every architecture of every Mach-O, rejects a
missing, malformed, non-macOS, duplicate, or above-floor `LC_BUILD_VERSION`,
and requires `LSMinimumSystemVersion` to be exactly 13.3. Release mode never
raises the declaration to accommodate an unsuitable dependency.

## Developer ID and notarization release policy

The release bundler accepts signing only as one complete fail-closed policy:

```text
WAM_MACOS_RELEASE_FLOOR=13.3
WAM_MACOS_CODESIGN_IDENTITY=<SHA-1 identity in the ephemeral keychain>
WAM_MACOS_EXPECTED_SIGNING_AUTHORITY=Developer ID Application: ... (TEAMID)
WAM_MACOS_EXPECTED_TEAM_ID=TEAMID
```

It signs every Mach-O leaf, then nested code containers deepest-first, and the
outer app last with hardened runtime and Apple's secure timestamp service. It
does not use recursive `--deep` signing in this mode. Verification still uses
deep bundle validation in addition to explicit leaf checks, and requires the
Developer ID certificate chain, exact authority and team, runtime flag, secure
timestamp, and absence of `com.apple.security.get-task-allow` on every
architecture.

`scripts/release_macos_notarize.zsh` never signs. It re-verifies the signed app,
submits a private temporary ZIP with `notarytool --wait`, requires an Accepted
result, staples and validates the ticket, repeats signature verification, runs
Gatekeeper assessment, and only then creates the publishable ZIP and SHA-256
sidecar. Its deterministic fixture replaces every Apple service/tool; repository
tests never contact the notary service or use a real certificate.

`.github/workflows/release-macos.yml` is limited to version tags and manual
dispatch through the protected `macos-release` environment. Configure that
environment with required reviewers, prevent self-review, and restrict allowed
refs. It needs these environment values:

- Variables: `MACOS_DEVELOPER_ID_APPLICATION`, `MACOS_TEAM_ID`,
  `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID`,
  `WAM_MACOS_QT_ARCHIVE_ARM64_URL`,
  `WAM_MACOS_QT_ARCHIVE_ARM64_SHA256`,
  `WAM_MACOS_QT_ARCHIVE_X86_64_URL`,
  `WAM_MACOS_QT_ARCHIVE_X86_64_SHA256`,
  `WAM_MACOS_MEDIA_ARCHIVE_ARM64_URL`,
  `WAM_MACOS_MEDIA_ARCHIVE_ARM64_SHA256`,
  `WAM_MACOS_MEDIA_ARCHIVE_X86_64_URL`, and
  `WAM_MACOS_MEDIA_ARCHIVE_X86_64_SHA256`.
- Secrets: `MACOS_DEVELOPER_ID_P12_BASE64`,
  `MACOS_DEVELOPER_ID_P12_PASSWORD`, and `MACOS_NOTARY_KEY_BASE64`.

Those credentials and the protected-environment policy are external release
prerequisites. The other external blocker is an audited Qt/mpv/FFmpeg closure
built at macOS 13.3 for each published architecture. Homebrew host binaries are
valid development inputs but are not accepted as release provenance. A final
quarantined clean-machine playback test remains a human release prerequisite.

## Exact size breakdown

The fixed app occupies 357,948 KiB (349.6 MiB) on disk.

| Payload | KiB | MiB | Share |
| --- | ---: | ---: | ---: |
| Caption model | 144,500 | 141.1 | 40.4% |
| Flat dependency dylibs | 101,056 | 98.7 | 28.2% |
| Qt frameworks | 76,696 | 74.9 | 21.4% |
| QML runtime tree | 13,452 | 13.1 | 3.8% |
| Duplicate root QML plugins | 13,160 | 12.9 | 3.7% |
| Bundled tools | 3,564 | 3.5 | 1.0% |

The bundle contains 38 Qt frameworks, 68 flat dylibs, 53 plugin dylibs, and 31
QML-plugin dylibs. Every root-level QML plugin inspected in `Contents/PlugIns`
was byte-identical to its module copy in `Contents/Resources/qml`.

WAM 0.2 occupied 214,584 KiB (209.6 MiB). WAM 0.3 is about 140 MiB larger;
the Qt/QML deployment is the dominant visible change, although upgraded
third-party dependencies prevent attributing the whole delta to the UI shell.

Reproduce the top-level size accounting with:

```zsh
du -sk "$APP"
du -sk "$APP/Contents"/* | sort -nr
find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0 |
  xargs -0 du -sk | sort -nr | head -40
find "$APP/Contents/Resources" -mindepth 1 -maxdepth 2 -print0 |
  xargs -0 du -sk 2>/dev/null | sort -nr | head -30
```

## Prioritized lean-package plan

1. **Quantize captions, after an accuracy gate.** The official
   `ggml-base.en-q5_1.bin` is 59,721,011 bytes versus 147,964,211 bytes for the
   current model. It would save 84.2 MiB and project the bundle near 265.4 MiB.
   Switch only after measuring caption word error rate and latency on WAM's
   speech corpus.
2. **Remove duplicate QML plugin copies.** The 31 byte-identical root copies
   cost 12.85 MiB. Prove that `Resources/qml` remains the only loaded module
   path with launch, dialog, caption, editor, and clean-machine tests before
   pruning.
3. **Deploy one intentional Qt Quick Controls style.** WAM customizes its
   controls but currently ships Basic, Fusion, Imagine, Material, Universal,
   Fluent, macOS, and iOS style payloads. Excluding unused styles and unused
   QtPdf/image, VirtualKeyboard, FolderListModel, Effects, and Shapes modules
   has a gross opportunity of roughly 35 MiB including duplicates. Re-run QML
   import, accessibility, native-dialog, and packaging tests after each cut.
4. **Build a purpose-specific FFmpeg/libmpv closure.** The current development
   FFmpeg enables GPL, SVT-AV1 encoding, x264, x265, VMAF, vpx, and broad device
   support. Keep the measured software decode fallbacks needed for format
   parity, use VideoToolbox for common macOS paths, and omit encode-only,
   device, filter, and protocol code WAM does not expose. Configuring proven
   decoders is a safer size/performance win than rewriting FFmpeg.
5. **Use pinned release dependencies and architecture-specific artifacts.**
   Build Qt/media dependencies at the declared macOS floor. Separate `arm64`
   and `x86_64` downloads stay leaner than universal binaries; publish a
   universal app only if one Mac artifact is a product requirement.
6. **Apply release-only dead stripping and LTO.** Measure startup and active
   playback before accepting compiler size optimizations; this is a modest win
   behind the model and dependency work.

If the smallest possible native package and platform-perfect UX outweigh one
shared frontend, a longer-term architecture with AppKit, WinUI, and a native
Linux shell over a shared C++/Rust media core can remove most of Qt's payload.
That is a product/maintenance trade, not a prerequisite for playback
performance.

Finally, the current FFmpeg configuration is GPL-enabled and includes x264 and
x265. Public distribution needs an explicit WAM license decision, exact source
and build archives, license texts, relinking/source obligations where
applicable, and an SBOM.
