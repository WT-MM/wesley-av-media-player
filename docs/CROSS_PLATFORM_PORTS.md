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
