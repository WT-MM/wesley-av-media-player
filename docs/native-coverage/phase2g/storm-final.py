"""Identity-bound sixteen-window seek/close observations in the build app."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--asset', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
repo = pathlib.Path('/private/tmp/wam-cov')
app = repo / 'build/WAM.app/Contents/MacOS/WAM'
asset = pathlib.Path(args.asset).resolve()
root = pathlib.Path(args.output)
root.mkdir(parents=True, exist_ok=True)
(root / 'home').mkdir(exist_ok=True)
def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
steps = []
for index in range(1, 16):
    steps.extend([f'new@300', f'load:{index}:{asset}@0'])
steps.append('report@8000')
for index in range(16):
    steps.extend([f'scroll:{index}:180:0:3@15', f'scroll:{index}:-180:0:3@15'])
steps.append('report@2000')
for index in reversed(range(16)):
    steps.append(f'close:{index}@15')
steps.append('report@1800')
run_id = str(uuid.uuid4())
candidate = sha(app)
env = os.environ.copy()
env.update(HOME=str(root / 'home'), WAM_NATIVE_BENCHMARK_TELEMETRY='1',
           WAM_NATIVE_BENCHMARK_RUN_ID=run_id, WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),
           WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate, WAM_TEST_BACKGROUND='1',
           WAM_TEST_MUTED='1', WAM_TEST_GEOMETRY='480x270+2400+1000',
           WAM_TEST_QUIT_AFTER_MS='30000', WAM_PLAYBACK_METRICS_PATH=str(root / 'metrics.jsonl'),
           WAM_TEST_WINDOW_SCRIPT=','.join(steps), WAM_TEST_SEEK_SCRIPT='7@2,1@8,11.390625@2')
inventories = []
with (root / 'log.txt').open('w') as log:
    process = subprocess.Popen([str(app), str(asset)], env=env, stdout=log, stderr=log)
    started = time.monotonic()
    for label, at in [('active', 12.0), ('closed', 24.0)]:
        time.sleep(max(0, started + at - time.monotonic()))
        observation = subprocess.run(['/usr/bin/vmmap', '-w', str(process.pid)], capture_output=True, text=True, timeout=10)
        (root / (label + '-vmmap.txt')).write_text(observation.stdout + observation.stderr)
        inventories.append(dict(phase=label, rc=observation.returncode,
                                native_images=sorted(set(line.split()[-1] for line in observation.stdout.splitlines() if 'libavcodec-wamnative' in line or 'libavutil-wamnative' in line))))
    try:
        rc = process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.terminate()
        rc = process.wait(timeout=5)
text = (root / 'log.txt').read_text()
result = dict(asset=str(asset), asset_sha256=sha(asset), candidate_sha256=candidate, run_id=run_id,
              pid=process.pid, rc=rc, inventories=inventories, window_script=steps,
              windows=[line for line in text.splitlines() if line.startswith('WAM_TEST_WINDOW')],
              failures=[line for line in text.splitlines() if 'WAM: native failure' in line],
              routes=[line for line in text.splitlines() if line.startswith('WAM: native decoder stage=')])
(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
