# Phase 2c reproduction

All commands are offline, from the repository root. The source defaults remain
OFF. The local acceptance build explicitly enables both stages:

```sh
cmake -S . -B build -DWAM_ENABLE_AVCODEC_STAGE=ON -DWAM_ENABLE_AVFORMAT_STAGE=ON
cmake --build build --parallel
```

Run CTest only after the build finishes, with access to macOS media/window
services. The retained ten-pass sequence used `ctest --output-on-failure -j 8`
from `build/`. `avcodec_fixture_transaction`, `avcodec_packaging_audit` and
`avcodec_allocation_attribution` are the three added CTest entries.

The additional fixture-policy check consumes generated CTest metadata:

```sh
python3 tests/avcodec_fixture_policy_test.py build
```

The private heap probe measures beyond production admission. It does not use
presentation surfaces, does not change the production cap and does not prove a
worst-case reservation. Build it in a fresh scratch directory:

```sh
WAM_RUN_DIR=$(mktemp -d /private/tmp/wam-private-heap-XXXXXX)
clang++ -std=c++20 -O2 -DWAM_AVCODEC_ALLOCATION_PROBE=1 \
  -I src -I third_party/ffmpeg-lgpl/include \
  tests/avcodec_private_heap_probe.cpp build/libwam_avcodec_instrumented.a \
  build/libwam_avcodec_probe_hooks.dylib -Wl,-rpath,"$PWD/build" \
  -o "$WAM_RUN_DIR/private-heap-probe"
ln -s "$PWD/build/native-codecs" "$WAM_RUN_DIR/native-codecs"
python3 tests/native_avcodec_heap_campaign.py \
  --binary "$WAM_RUN_DIR/private-heap-probe" --output "$WAM_RUN_DIR/heap"
```

The fixture generator uses the installed ffmpeg/ffprobe solely for local
synthetic inputs and references. The native probe uses the pinned WAM closure.
The heap campaign retains generator argv, stream facts, asset/probe hashes,
frame counts, allocator peaks and teardown counts.

`native_avcodec_display_probe.py --output /private/tmp/<fresh-directory>`
launches only build/WAM.app with all required telemetry identities, isolated
HOME, background/mute and the prescribed geometry. `--full-range` requests
full-range encoding. Inspect the emitted stream facts before claiming the
requested range was actually signalled. The accompanying
`native_avcodec_color_projection.py --captures <directory> --output <json>`
rejects no-signal captures and evaluates the original projection/RMS thresholds
in a common sRGB color space. Use
`native_avcodec_color_projection_test.py --captures <valid-hardware-captures>`
to test the measurement against a hardware oracle. This run's fresh captures
were all black; only the retained phase-2b captures qualified the method.

`native_avcodec_multiwindow_probe.py --asset <local-video> --output
/private/tmp/<fresh-directory>` opens sixteen build-app windows, issues
seek/scroll requests and closes them. Run the same campaign on a hardware
control and a software specimen sequentially. Its JSON includes the exact
script, all identities, named failures, window reports and native-library
inventories before/after close. The ASP campaign in this run failed five times;
the harness intentionally records failures rather than calling a normal
process exit a playback pass.

The bundling audit is read-only:

```sh
python3 tests/native_avcodec_packaging_audit.py \
  --app <app-to-audit> --output /private/tmp/<audit-result>.json
```

It inspects bundled files only. `clean_machine_ready=false` is expected for
the examined artifacts. Static unresolved rpaths need runtime qualification;
this tool is not a substitute for relocated full-app playback. The current
hard rule permits GUI launch only from build/WAM.app, so a relocated GUI proof
also needs an explicit exception before execution.
