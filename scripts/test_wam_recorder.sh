#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${1:-"$repo_dir/build-encoding"}
build_dir=$(CDPATH= cd -- "$build_dir" && pwd)
major=$(sw_vers -productVersion | cut -d . -f 1)
if [ "$major" -lt 15 ]; then echo 'Recorder tests require macOS 15+'; exit 77; fi
cmake --build "$build_dir" --target WAMKit --parallel 8
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -module-cache-path "$build_dir/recorder-modules" \
  -F "$build_dir/src/wamkit" -framework WAMKit -framework AVFoundation -framework Accelerate \
  -Xlinker -rpath -Xlinker "$build_dir/src/wamkit" \
  "$repo_dir/examples/WAMRecorder/RecordingWriter.swift" \
  "$repo_dir/tests/wam_recorder_writer_test.swift" -o "$build_dir/wam-recorder-writer-test"
for scheme in float32 pcm16 alac aac64 aac96; do
  "$build_dir/wam-recorder-writer-test" 12 1 "$scheme"
done
python3 - "$build_dir/wam-recorder-writer-test" <<'PY'
import json,pathlib,subprocess,sys,shutil
r=subprocess.run([sys.argv[1],'301','1','float32','--crash-proof'],text=True,capture_output=True)
assert r.returncode==86,(r.returncode,r.stdout,r.stderr)
folder=pathlib.Path(r.stdout.strip().splitlines()[-1]);root=folder.parent
assert root.name.startswith('wam-writer-test-')
try:
 receipt=json.loads((folder/'session.json').read_text())
 complete=[s for s in receipt['segments'] if s['completed']]
 assert receipt['status']=='recording' and len(complete)==2
 for segment in complete:
  assert segment['frames']==300*48000
  probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','json',str(folder/segment['file'])],text=True))
  assert abs(float(probe['format']['duration'])-300)<1e-6
 print('PASS abrupt process exit: both completed five-minute source checkpoints remain playable')
finally:shutil.rmtree(root)
PY
if [ "${2:-}" = '--long' ]; then "$build_dir/wam-recorder-writer-test" 5400 3 float32; fi
