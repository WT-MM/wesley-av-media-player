"""Quiet, identity-bound native-deferred GUI proof; never launches other builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument('--asset', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--seconds', type=float, default=12)
p.add_argument('--prime-paused', action='store_true')
a = p.parse_args()
app = Path('/private/tmp/wam-native-scratch/build/WAM.app/Contents/MacOS/WAM')
a.output.mkdir(parents=True, exist_ok=False)

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

with (a.output / 'gate.jsonl').open('w') as gate:
    while True:
        processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
        compilers = []
        for line in processes.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and Path(fields[1]).name in {
                'clang', 'clang++', 'cc', 'c++', 'ld', 'ld64', 'gcc', 'g++',
                'swift-frontend', 'swiftc', 'metal', 'metallib'}:
                compilers.append(line.strip())
        load = os.getloadavg()[0]
        record = dict(time=time.time(), load1=load, compilers=compilers,
                      passed=not compilers and load < 8)
        gate.write(json.dumps(record) + '\n'); gate.flush()
        print(json.dumps(record), flush=True)
        if record['passed']:
            break
        time.sleep(30)

home = a.output / 'home'; home.mkdir()
asset = a.output / ('asset' + a.asset.suffix)
os.link(a.asset, asset)
env = {k: v for k, v in os.environ.items() if not k.startswith('WAM_')}
env.update(HOME=str(home), WAM_TEST_BACKGROUND='1', WAM_TEST_MUTED='1',
           WAM_TEST_CAPTURE_PHYSICAL='1',
           WAM_TEST_GEOMETRY='480x270+2400+1000',
           WAM_NATIVE_BENCHMARK_TELEMETRY='1',
           WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),
           WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),
           WAM_NATIVE_BENCHMARK_CANDIDATE_ID=sha(app),
           WAM_PLAYBACK_METRICS_PATH=str(a.output / 'metrics.jsonl'),
           WAM_TEST_QUIT_AFTER_MS=str(round(a.seconds * 1000)),
           WAM_TEST_WINDOW_SCRIPT=f'report@2500,videograb:0:{a.output}/display.png@500,report@1000')
if a.prime_paused:
    env['WAM_TEST_WINDOW_SCRIPT'] = 'pause:0@0,play:0@1500,' + env['WAM_TEST_WINDOW_SCRIPT']
(a.output / 'environment.json').write_text(json.dumps({k:v for k,v in env.items() if k.startswith('WAM_') or k == 'HOME'}, indent=2))
with (a.output / 'log.txt').open('w') as log:
    process = subprocess.Popen([str(app), str(asset)], env=env, stdout=log, stderr=log)
    try:
        rc = process.wait(timeout=a.seconds + 30)
    except subprocess.TimeoutExpired:
        process.terminate(); rc = process.wait(timeout=10)
rows = [json.loads(line) for line in (a.output / 'metrics.jsonl').read_text().splitlines()] if (a.output / 'metrics.jsonl').exists() else []
log = (a.output / 'log.txt').read_text()
result = dict(pid=process.pid, rc=rc, rows=len(rows),
              maxima={key:max((row[key] for row in rows if row.get(key) is not None), default=None) for key in
                      ['drawn_frames','discarded_late_frames','decoder_discarded_frames','audio_underrun_callbacks','audio_clock_advanced_underruns']},
              observations=[line for line in log.splitlines() if line.startswith('WAM_TEST_') or 'native decoder stage=' in line or 'native failure' in line])
result['zero_late_proof'] = rc == 0 and (result['maxima']['drawn_frames'] or 0) > 0 and result['maxima']['discarded_late_frames'] == 0
(a.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
raise SystemExit(0 if result['zero_late_proof'] else 1)
