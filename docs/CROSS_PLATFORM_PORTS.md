# Windows runtime follow-up — reported CI run 2026-09-23

Starting revision: `f39207d`, branch `cross-platform-ports`, PR #3. The
maintainer reports Linux and macOS green and Windows building/linking with
MSYS2 UCRT64 GCC 16.2 / MSYS2 Qt, with 41/45 tests passing. The older report
below predates that CI evidence (including its now-obsolete downloaded-Qt
Windows description). This follow-up was performed offline on macOS; no
Windows execution or successful Windows lane is claimed.

## Fixes and measured evidence

- **`native_pcm_ring`: confirmed stack exhaustion in the local reproducer.**
  `sizeof(NativePcmRing)` is **525,440 bytes** on this arm64 build, including
  524,288 bytes of inline PCM. The first validation function declares two
  rings (1,050,880 bytes before other locals), and the preflight test has four.
  The unchanged Release executable relinked with
  `-Wl,-stack_size,0x100000` died with SIGSEGV (subprocess return -11).
  `otool -l` confirmed `LC_MAIN stacksize 1048576`. Every test-local ring now
  uses `std::make_unique` during setup, with a reference preserving existing
  assertions. The changed executable passes at the same 1 MiB stack limit.
- **`native_audio_render_core`: confirmed stack exhaustion in the local
  reproducer.** The render core itself is only **1,024 bytes**; the large
  objects are the rings embedded in `Fixture` / `RateFixture` and standalone
  test rings. Several functions keep multiple fixtures alive. This unchanged
  test also died with SIGSEGV at 1 MiB. Only those test rings now live on the
  heap, allocated before rendering. The changed test passes at 1 MiB,
  including its existing callback allocation assertions. Production ring,
  render core, callback code and executable stack reserves are unchanged.
- **`mpegts_demuxer_integration`: confirmed open-reader cleanup defect;
  reported fail-fast still needs Windows verification.** The unchanged
  integration executable passes all **464 assertions** with a 1 MiB stack
  on macOS. This is evidence against assuming the same stack explanation,
  not a Windows ABI/compiler proof. `testFileIdentityAndCancellation` kept
  `outcome.asset` alive while deleting `identity-working.ts`; that asset
  retains `StableFileReader` and its open descriptor until destruction.
  The test now resets the asset before removal. A weak-owner expiration
  assertion checks the ordering portably, and removal must return true.
  A scratch negative-control build omitting only the reset exits 1 with
  `FAIL: the retained file reader is released before removal`; the corrected
  integration test passes **466 assertions**, also at 1 MiB.
- **`player_core_render_context_permission`: diagnostic only, not a claimed
  fix.** This test has no file removal or rename, and the linked project
  sources have no throwing filesystem removal on its exercised path.
  The supplied `filesystem error: cannot remove` description fits the
  MPEG-TS cleanup above, but the supplied labels cannot be reconciled from
  source alone. No speculative renderer or production filesystem change was
  made. Windows-only, flushed `[render_context_permission]` stage markers
  identify application creation, callback/notification completion, OpenGL
  context creation, linked-mpv initialization and ownership-test completion.
  A top-level exception handler prints the executable-specific label and
  `what()` while retaining a failing exit status. MPEG-TS prints its own
  start label and exact identity-fixture path on Windows. The existing
  `ctest --output-on-failure` will expose these diagnostics on the next lane.
  Native fail-fast/foreign-thread exceptions cannot be caught by the main
  handler; the last flushed stage remains useful in that case. Raw Windows
  failure blocks are needed if either of these two tests still fails.

## Local validation for this follow-up

The existing native-enabled Release configuration and fixture locations were
retained. Commands:

```sh
cmake --build build --parallel
cd build
TMPDIR=/private/tmp/wam-ports-scratch ctest --output-on-failure
```

The full build succeeded. Sandbox `ditto` metadata-copy errors in the WAMKit
host bundle required an unsandboxed build retry; the full suite likewise runs
outside the sandbox for the existing native/Qt tests. These are existing
harness requirements, not changes to product behavior.

**Full-suite result: 131/131 passed, zero failures and zero skips, in 147.85
seconds.** All four named tests passed locally. `git diff --check` passed;
the four frozen files matched HEAD byte-for-byte and the index is unchanged.

Evidence lives under `/private/tmp/wam-ports-scratch`: `windows-stack-commands.txt`,
`sizeof.cpp`, `wam_*-1m-before` / `wam_*-1m-after` executables and `.log` files,
`mpegts-old-cleanup-order.cpp` / `.log`, `windows-fixes-build-complete.log`, and
`windows-fixes-ctest.log`. The 1 MiB executables were relinked from the existing
Ninja Release link commands with only the output path and stack-size flag
changed; no CMake platform policy was altered for this experiment.

Only the four test sources and this report were edited. Frozen files and all
production sources remain unchanged. No network or git index/commit/branch
operations were performed. Changes are intentionally uncommitted for the
maintainer. Windows qualification, especially the unexplained Qt failure,
remains outstanding; this is not yet a verified four-test Windows fix.

---

# Linux and Windows restoration — 2026-09-22

The Linux and Windows build/package jobs are restored. They have **not been run
on their target operating systems**: this work was performed offline on macOS.
The local builds and tests below are evidence for the shared code and macOS
regression safety, not a substitute for the first two CI runs.

## Changes by file

| File | Change |
| --- | --- |
| `.github/workflows/build.yml` | Restores the saved Linux and Windows jobs and their package verification/upload steps. The entire original prefix, including `on:` and the macOS job, is byte-identical to HEAD. |
| `CMakeLists.txt` | Exposes the neutral core tests on non-Apple platforms; links the non-Apple app to the shared parser/subtitle core; gates WAMKit entry points on APPLE; stages `ffmpeg.exe` on Windows; accepts `python` as well as `python3`; applies the Linux headless Qt environment to both controller tests. Moves neutral exact-time, color and audio-packet tests out of platform/decoder feature gates. Keeps the optional POSIX benchmark Apple-only as before. Adds overridable native fixture locations without changing their defaults. |
| `src/wamkit/NativeTargets.cmake` | Builds the existing Qt-free parser/timing core for the portable app. All Apple framework/native-pipeline targets retain their APPLE gate. |
| `src/wamkit/CMakeLists.txt` | Makes the generated WAMKit fixture directory configurable; its default is unchanged. |
| `src/qt/main.cpp` | Guards the Apple window-report/script helpers, supplies `background_launch=false` without the native feature, and limits the macOS document-app last-window policy to Apple. |
| `src/media/matroska_subtitles.cpp` | Keeps `st_mtimespec` on Apple, uses `st_mtim` on Linux, and adds Windows wide-path/binary/non-inheritable open, 64-bit stat, explicit-offset ReadFile and FILETIME comparison. |
| `src/media/matroska_demuxer.cpp` | Same file-I/O/timestamp platform seams in its existing retained reader. No decode/admission logic changes. |
| `src/media/mpegts_demuxer.cpp` | Same file-I/O/timestamp platform seams in its existing retained reader. No packet/timing logic changes. |
| `src/media/matroska_ebml.cpp` | Windows wide-path binary open, 64-bit stat and explicit-offset reads in the existing descriptor adapter. |
| `tests/matroska_ebml_test.cpp` | Uses the system temporary directory and a dynamically sized filename buffer; Windows creates the fixture exclusively in binary mode. |
| `tests/matroska_demuxer_test.cpp` | Same temporary-file fixes; closes the retained reader before deleting the fixture on Windows. In-memory synthetic path labels need no real directory. |
| `tests/matroska_subtitles_test.cpp` | Adds exclusive binary temporary-file creation on Windows. |
| `tests/jobs_test.cpp` | Makes the shared expectation helper available on Windows, where its include was accidentally inside a POSIX guard. |
| `tests/native_late_frame_json_test.py` | Reads JSON from a temporary output file instead of reopening `/dev/stdout` through a captured pipe. Assertions are unchanged. |
| `scripts/package_windows.sh` | Deploys the UCRT64 compiler runtime before walking DLL dependencies, preventing an older compiler runtime shipped with the Qt SDK from shadowing WAM's runtime. |
| `scripts/generate_wamkit_fixtures.py`, `scripts/build_wamkit_swift.py` | Honor TMPDIR for local proof scratch files. |
| `docs/CROSS_PLATFORM_PORTS.md` | This report. |

All frozen files were compared byte-for-byte with HEAD and are unchanged.
The supplied, initially untracked CI-reference documents were not edited.
No git index, commit, branch, stash or reset operations were performed.

## Restored lanes

- **Linux:** ubuntu-24.04, Qt 6.11.1 from install-qt-action@v4 with
  qtshadertools, apt libmpv-dev/FFmpeg, configure/build, full portable ctest
  under Xvfb, Qt deployment, whisper/model payload, linuxdeploy AppImage,
  extracted-payload/runtime/ELF closure checks, `WAM-Linux` artifact.
- **Windows:** windows-latest, the same pinned Qt version/action with the
  `win64_mingw` SDK, MSYS2 UCRT64 GCC/CMake/Ninja/pkgconf/Python,
  **libmpv development package** and FFmpeg. Explicit Qt prefix/pkg-config
  selection and UCRT64-first runtime PATH avoid accidentally finding another
  Qt/toolchain. The lane checks mpv.pc discovery and the client header before
  configuring, runs portable ctest, packages Qt/QML/media/captions, verifies
  the DLL payload, and uploads `WAM-Windows.zip`.

Checkout and artifact actions remain @v4, matching the current macOS job;
MSYS2 setup remains @v2 from the saved Windows lane. The preserved Windows
lane used MSYS2, not vcpkg. The restored lane deliberately uses MinGW because
the shared exact-time arithmetic uses `__int128`; MSVC is not qualified here.
The macOS job was not rewritten or reformatted.

## Local evidence

Host: AppleClang 21, Homebrew Qt **6.11.1**, installed mpv/FFmpeg and the existing
native LGPL SDK. The unrelated `qmake` first on shell PATH reports Qt 5;
CMake actually selected `/opt/homebrew/lib/cmake/Qt6`, and
`/opt/homebrew/opt/qt/bin/qmake -query QT_VERSION` reports 6.11.1.

The initial configuration and complete default build succeeded:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=ON -DWAM_ENABLE_MACOS_NATIVE_VIDEO=OFF \
  -DWAM_ENABLE_AVFORMAT_STAGE=OFF -DWAMKIT_BUILD_HOST=OFF
cmake --build build --parallel
```

All portable tests registered in that configuration passed, including the
fixture-backed MPEG-TS integration, parsers, subtitles, timing, codec facts,
jobs, state, captions, controller laziness and FFmpeg export duration. The
initial unfiltered 55-test run also tried macOS integration tests: two Qt tests
could not access a screen inside the sandbox, and the JSON pipe-output test
failed. The latter was repaired as described above. The real OpenGL test passed
outside the sandbox; its macOS offscreen-plugin retry cannot supply OpenGL.
No assertion was weakened or test disabled to obtain a green result.

The native-disabled option does **not** turn a Mac into Linux: WAMKit, Quick Look
and the tracked native surface still build on Apple by design. Inspection
confirmed that their target definitions, Objective-C++ language, frameworks,
window chrome and native integration tests remain behind Apple gates. The
portable core itself contains no Apple SDK includes; its clock/ring/render
math files happen to live under `platform/macos` but are ordinary C++.

For the final native-enabled proof, the build was reconfigured with:

```sh
cmake -S . -B build -DBUILD_TESTING=ON \
  -DWAM_ENABLE_MACOS_NATIVE_VIDEO=ON -DWAM_ENABLE_AVFORMAT_STAGE=ON \
  -DWAMKIT_BUILD_HOST=ON \
  -DWAMKIT_TEST_FIXTURE_DIR=/private/tmp/wam-ports-scratch/wamkit \
  -DWAM_NATIVE_READER_TEST_FIXTURE=/private/tmp/wam-ports-scratch/wamkit/av.mp4 \
  -DWAM_NATIVE_VIDEO_TEST_FIXTURE=/private/tmp/wam-ports-scratch/wamkit/av.mp4 \
  -DWAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE=/private/tmp/wam-ports-scratch/main10.mp4 \
  -DWAM_AVFORMAT_FIXTURES=/private/tmp/wam-ports-scratch/avformat \
  -DWAM_MIXED_FIXTURES=/private/tmp/wam-ports-scratch/mixed
cmake --build build --parallel
cmake --build build --target wam_matroska_demuxer_bench --parallel
TMPDIR=/private/tmp/wam-ports-scratch ctest --test-dir build --output-on-failure
```

The benchmark is EXCLUDE_FROM_ALL, hence the explicit extra build. WAMKit's
AudioToolbox fixture generation and bundle copying, and the hardware/Qt tests,
needed execution outside the filesystem/process sandbox. The ordinary sandbox
errors were AudioToolbox encoder initialization, inaccessible WindowServer,
and ditto permission errors; the corresponding unsandboxed work succeeded.
The app was only exercised by the existing quiet, process-scoped ctest harness.

**Final result: 131/131 tests passed, zero failures and zero skips, in 152.28 seconds.**
This includes the default WAMKit host packaging and Swift consumer build, native
H.264/Main 10 decode tests, Quick Look, portable tests and the benchmark.

Additional checks passed: Windows QML scanner shell regression, shell syntax,
YAML parsing, `git diff --check`, frozen-file comparisons and exact workflow
prefix comparison. The four edited media readers were also preprocessed with
their actual Apple build commands before and after the edits: their output
was identical after whitespace normalization and ignoring redundant global
qualification of `struct stat`. This directly checks that the Mac file-reader
paths retain their prior compiled code.

Logs and the token-comparison script are in `/private/tmp/wam-ports-scratch`:
`configure-off.log`, `build-off.log`, `ctest-off.log`,
`configure-complete.log`, `build-complete.log`, `ctest-complete.log`, and
`apple-token-proof.log`. Earlier complete native runs passed 128/128 and then
129/129 before enabling the default WAMKit host/Swift checks.

## Remaining target-platform risks and deferrals

1. **Neither target OS was executed.** Windows preprocessing/linking and Linux
   system-header branches were inspected, not compiled on this host. Start with
   the first compiler error, not later dependent target failures. Windows file
   seams depend on MinGW `_wopen`, `_fstati64`, `_get_osfhandle`, ReadFile and
   FILETIME. CI exercises real small-file parsing, growth invalidation and
   subtitles; concurrent reads, Unicode filenames and offsets above 2 GiB
   still need Windows runtime qualification.
2. **Windows package discovery:** if `pkg-config --modversion mpv` fails, inspect
   `/ucrt64/lib/pkgconfig/mpv.pc`, the installed libmpv package and
   PKG_CONFIG_PATH. If configure reports Unix-form imported paths, inspect
   `Normalized PkgConfig::MPV paths` from the existing MSYS2 normalization
   helper. Package availability could not be checked offline.
3. **Windows SDK/compiler compatibility:** the downloaded Qt MinGW SDK and
   rolling UCRT64 compiler/media packages need a real link/run proof. Missing
   DLL entry points should be diagnosed against the three deployed compiler
   DLLs and `ldd package/WAM.exe`, including dynamic Qt/QML plugins. The package
   copies UCRT64's runtime explicitly; MSVC/vcpkg compatibility was not added.
4. **Qt private-module warning:** the old Qt6QmlAssetDownloaderPrivate warning
   was not reproduced with the installed macOS SDK. Both new lanes install
   qtshadertools like macOS, but that is not proof that the private-module
   warning is resolved. If it returns, retain the nested Qt package diagnostic
   identifying the missing dependency and inspect the downloaded SDK's
   `lib/cmake/Qt6QmlAssetDownloaderPrivate` directory. No warning was suppressed.
5. **Linux graphics:** CI runs ctest under Xvfb; the controller tests use Qt's
   offscreen platform. If context creation fails, inspect DISPLAY, the SDK's
   offscreen/GLX support and Mesa/GL packages. This was not a Linux GPU proof.
6. **Packaging/downloads:** AppImage and Windows ZIP creation, Qt deployment,
   external whisper/model downloads, linuxdeploy's continuous release and
   clean-machine loader closure remain unverified locally because of the
   no-network/host-platform constraints. Existing payload and runtime checks
   are retained in each lane so missing QML plugins, FFmpeg/whisper tools,
   model files or unresolved libraries fail before artifact upload.
7. **Scope:** the optional libavcodec stage stays at its existing OFF default;
   this change does not qualify it, change the native decode ladder, or alter
   release signing. Local Homebrew libraries warn about deployment floors
   newer than 13.3; release-SDK deployment compatibility is not established by
   this local test run.
