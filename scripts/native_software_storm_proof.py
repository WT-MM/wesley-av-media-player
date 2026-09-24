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
app = pathlib.Path('/private/tmp/wam-native-scratch/build/WAM.app/Contents/MacOS/WAM')
asset = pathlib.Path(args.asset).resolve()
root = pathlib.Path(args.output)
root.mkdir(parents=True, exist_ok=False)
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
env = {k:v for k,v in os.environ.items() if not k.startswith('WAM_')}
env.update(HOME=str(root / 'home'), WAM_NATIVE_BENCHMARK_TELEMETRY='1',
           WAM_NATIVE_BENCHMARK_RUN_ID=run_id, WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),
           WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate, WAM_TEST_BACKGROUND='1',
           WAM_TEST_MUTED='1', WAM_TEST_ALL_WINDOW_GEOMETRY='1', WAM_TEST_GEOMETRY='480x270+2400+1000',
           WAM_TEST_QUIT_AFTER_MS='30000', WAM_PLAYBACK_METRICS_PATH=str(root / 'metrics.jsonl'),
           WAM_TEST_WINDOW_SCRIPT=','.join(steps), WAM_TEST_SEEK_SCRIPT='7@2,1@8,11.390625@2')
(root / 'environment.json').write_text(json.dumps({k:v for k,v in env.items() if k.startswith('WAM_') or k=='HOME'}, indent=2))
with (root / 'gate.jsonl').open('w') as gate:
    while True:
        processes = subprocess.check_output(['ps','-axo','pid=,comm='], text=True).splitlines()
        compilers = [line.strip() for line in processes if len(line.strip().split(None,1))==2 and pathlib.Path(line.strip().split(None,1)[1]).name in {'clang','clang++','cc','c++','ld','ld64','gcc','g++','swiftc','swift-frontend','metal','metallib'}]
        load = os.getloadavg()[0]
        record = dict(time=time.time(),load1=load,compilers=compilers,passed=not compilers and load<8)
        gate.write(json.dumps(record)+'\n');gate.flush();print(json.dumps(record),flush=True)
        if record['passed']: break
        time.sleep(30)
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


from collections import Counter
import re
events = [json.loads(line) for line in text.splitlines() if line.startswith('{') and '"event"' in line]
assert all(event.get('run_id')==run_id and event.get('asset_sha256')==sha(asset) and event.get('candidate_id')==candidate and event.get('process_id')==process.pid for event in events)
counts = Counter(event.get('event') for event in events)
metrics = [json.loads(line) for line in (root/'metrics.jsonl').read_text().splitlines()]
drawn_epochs = {row['session_epoch'] for row in metrics if row.get('backend')=='native' and (row.get('drawn_frames') or 0)>0}
workers = [dict(zip(['active','pending','peak','bytes'],map(int,match))) for match in re.findall(r'WAM_TEST_SOFTWARE_WORKERS active=(\d+) pending=(\d+) peak=(\d+) bytes=(\d+)',text)]
geometries = re.findall(r'WAM_TEST_WINDOW idx=\d+ .*?geom=([^ ]+)',text)
result['quiet_geometry_pass'] = len(geometries)==32 and all(g=='480x270+2400+1000' for g in geometries)
result.update(events=dict(counts),drawn_sessions=len(drawn_epochs),software_workers=workers)
result['passed'] = (rc==0 and result['quiet_geometry_pass'] and len(drawn_epochs)==16 and counts['first_frame_drawn']==16 and
    counts['preview_frame_drawn']>=16 and counts['preview_admitted']==counts['preview_frame_drawn'] and counts['preview_failed']==0 and counts['fallback_selected']==0 and
    not result['failures'] and result['windows'][-1]=='WAM_TEST_WINDOWS count=0' and workers and
    workers[-1]['active']==0 and workers[-1]['pending']==0 and workers[-1]['bytes']==0 and
    max(w['peak'] for w in workers)<=16 and inventories[-1]['rc']==0 and not inventories[-1]['native_images'])
(root/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({key:result[key] for key in ['passed','events','drawn_sessions','software_workers','inventories','failures']},indent=2))
raise SystemExit(0 if result['passed'] else 1)
