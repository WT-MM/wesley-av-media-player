"""Retain exact decoder timelines and complete build-app playback metrics."""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import subprocess
import time

repo = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--output', required=True)
a = p.parse_args()
root = pathlib.Path(a.output).resolve()
root.mkdir(parents=True, exist_ok=True)
assets = json.loads((repo / 'docs/native-coverage/phase3/rustdesk-full-decode.json').read_text())
probe = repo / 'build/wam_libavformat_decode_test'
def sha(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def trial(index, row):
    path = row['path']
    duration = float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
        'format=duration', '-of', 'default=nw=1:nk=1', path], text=True))
    run = root / str(index)
    with (root / f'{index}-playback.log').open('w') as log:
        result = subprocess.run(['python3', str(repo / 'tests/libavformat_playback_proof.py'),
            '--asset', path, '--output', str(run), '--seconds', str(duration + 5)], stdout=log, stderr=log)
    receipt = json.loads((run / 'result.json').read_text())
    samples = [json.loads(line) for line in (run / 'metrics.jsonl').read_text().splitlines()]
    samples = [r for r in samples if r.get('record') == 'playback_sample']
    receipt['last_sample'] = samples[-1] if samples else None
    receipt['expected_frames'] = int(row['stdout'].split('frames=')[1].split()[0])
    last = receipt['last_sample'] or {}
    receipt['all_drawn'] = last.get('drawn_frames') == receipt['expected_frames']
    receipt['clock_exact'] = bool(samples) and all(r['clock_rate'] == 1 for r in samples if not r['paused'] and r['media_seconds'] is not None)
    receipt['pass'] = receipt['native'] and receipt['all_drawn'] and receipt['clock_exact'] and result.returncode == 0
    (run / 'complete.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(index, receipt['pass'], last, flush=True)
    return receipt

# Each process uses the prescribed quiet geometry and its own scratch HOME.
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
    pending = [executor.submit(trial, i, row) for i, row in enumerate(assets)]
    rows = [job.result() for job in pending]
(root / 'playback.json').write_text(json.dumps(rows, indent=2) + '\n')
exact = []
for row in assets:
    start = time.monotonic()
    result = subprocess.run([str(probe), row['path']], capture_output=True, text=True, timeout=300)
    exact.append(dict(path=row['path'], asset_sha256=sha(row['path']), probe_sha256=sha(probe),
        rc=result.returncode, stdout=result.stdout, stderr=result.stderr, elapsed_seconds=time.monotonic()-start))
    (root / 'decode.json').write_text(json.dumps(exact, indent=2) + '\n')
    print(result.stdout, flush=True)
