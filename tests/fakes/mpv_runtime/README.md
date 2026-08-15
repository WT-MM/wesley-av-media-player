# mpv runtime fake libraries

`fake_mpv.cpp` is one deterministic source used to build five private test
libraries. It is never linked to WAM or to libmpv.

`tests/run_mpv_runtime_test.sh` builds five dylibs serially in an isolated
temporary directory, all with the exact output filename
`WAMMpvFallback.dylib`:

- `valid`: compile with `WAM_FAKE_MPV_NEWER_MINOR=1`;
- `missing`: compile with `WAM_FAKE_MPV_OMIT_WAIT_EVENT=1`;
- `wrong-major`: compile with `WAM_FAKE_MPV_WRONG_MAJOR=1`;
- `old-minor`: compile with `WAM_FAKE_MPV_OLD_MINOR=1`;
- `collision`: compile with `WAM_FAKE_MPV_COLLISION=1`.

Each target needs only the mpv include directory. The script then links the
`mpv_runtime_test` executable against Qt Core plus
`src/playback/mpv/mpv_runtime.cpp`, deliberately omits libmpv, checks its
undefined symbols, and invokes it with the five target paths. This proves both
the `/dev/fd` bootstrap, exact post-load vnode identity (including a preloaded
same-install-name probe), and that the runtime itself has no link-time libmpv
dependency. CMake wiring can reuse the same targets later without weakening
this standalone gate.

`injected_mpv_runtime.hpp` is a separate, macro-gated table-injection seam for
the focused PlayerCore and PlayerController tests. Those tests do not call the
dynamic loader. The macro gates only inclusion of that test helper; it does not
change `MpvRuntime`'s class definition. `tests/compile_mpv_dispatch_tests.sh`
checks both logical targets with strict syntax-only compilation.

The production source split is platform-explicit. `mpv_api.cpp` and
`mpv_runtime_common.cpp` are shared. macOS builds select only
`mpv_runtime.cpp`, whose secure loader has no direct libmpv imports. Existing
non-Apple builds instead select `mpv_runtime_linked.cpp` and keep their normal
strong libmpv dependency. `tests/run_mpv_runtime_linked_test.sh` exercises that
linked factory without constructing a client handle and verifies its intended
`_mpv_create` import.
