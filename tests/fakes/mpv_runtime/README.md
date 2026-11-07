# mpv runtime fake libraries

`fake_mpv.cpp` is one deterministic source used to build private test
libraries. It is never linked to WAM or to libmpv.

On macOS, `tests/CMakeLists.txt` builds it five times, each into its own
directory and each named as the bundled fallback (`WAM_MPV_FALLBACK_DYLIB` in
`packaging/pins.env`):

- `valid`: `WAM_FAKE_MPV_NEWER_MINOR=1`;
- `missing`: `WAM_FAKE_MPV_OMIT_WAIT_EVENT=1`;
- `wrong-major`: `WAM_FAKE_MPV_WRONG_MAJOR=1`;
- `old-minor`: `WAM_FAKE_MPV_OLD_MINOR=1`;
- `collision`: `WAM_FAKE_MPV_COLLISION=1`.

The `mpv_runtime` test runs `wam_mpv_runtime_test` (linked against
`wam_mpv_runtime` and Qt Core, never libmpv) with the five paths. It covers the
`/dev/fd` bootstrap, bundle path and permission refusals, version and missing
symbol refusals, a preloaded image with the same install name, and the
success cache. `mpv_runtime_no_libmpv_import` checks that the test binary
imports no `_mpv_` symbol, so the macOS runtime keeps no link-time libmpv
dependency. `ffmpeg_coexistence` reuses the `valid` variant.

`mpv_runtime_test_access.hpp` is the one definition of `MpvRuntime`'s test
friend. `injected_mpv_runtime.hpp` builds on it to inject a linked client's
API table for the PlayerCore and PlayerController tests, which link the
app's seam-enabled twin (`WAM_QT_TEST_SEAMS`) and never call the dynamic
loader.

The production source split is platform-explicit. `mpv_api.cpp` and
`mpv_runtime_common.cpp` are shared. macOS builds select only
`mpv_runtime.cpp`, whose secure loader has no direct libmpv imports. Other
platforms select `mpv_runtime_linked.cpp` and keep their normal strong libmpv
dependency; the `mpv_runtime_linked` test exercises that factory there.
