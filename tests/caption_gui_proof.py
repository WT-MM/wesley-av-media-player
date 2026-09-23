#!/usr/bin/env python3
"""Paired quiet-seam playback/caption proof. Controls only its own child PIDs."""
import argparse, hashlib, json, os, pathlib, re, subprocess, time, uuid
p=argparse.ArgumentParser()
p.add_argument('--app',type=pathlib.Path,required=True)
p.add_argument('--asset',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
def sha(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
rows=[]
for kind in ('baseline','captions'):
    root=a.output/kind; root.mkdir(exist_ok=True)
    home=root/('home-'+uuid.uuid4().hex); home.mkdir()
    for generated in ('metrics.jsonl','captions.srt'):
        (root/generated).unlink(missing_ok=True)
    env=os.environ.copy()
    env.update(HOME=str(home),WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',
        WAM_TEST_GEOMETRY='480x270+2400+1000', WAM_TEST_QUIT_AFTER_MS='8000',
        WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),
        WAM_NATIVE_BENCHMARK_CANDIDATE_ID=sha(a.app),WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(a.asset),
        WAM_PLAYBACK_METRICS_PATH=str(root/'metrics.jsonl'),WAM_TEST_CAPTION_METRICS='1')
    if kind=='captions': env['WAM_TEST_CAPTION_OUTPUT']=str(root/'captions.srt')
    with (root/'log.txt').open('w') as log:
        child=subprocess.Popen([str(a.app),str(a.asset)],env=env,stdout=log,stderr=log)
        try: rc=child.wait(timeout=25)
        except subprocess.TimeoutExpired:
            child.terminate()
            try: rc=child.wait(timeout=3)
            except subprocess.TimeoutExpired: child.kill(); rc=child.wait()
    text=(root/'log.txt').read_text()
    heartbeat=re.search(r'caption-heartbeat max_gap_ms=\s*(\d+) samples=\s*(\d+)',text)
    samples=[json.loads(s) for s in (root/'metrics.jsonl').read_text().splitlines()]
    playback=[s for s in samples if s.get('record')=='playback_sample']
    row=dict(kind=kind,pid=child.pid,rc=rc,app_sha256=sha(a.app),asset_sha256=sha(a.asset),
        heartbeat_max_ms=int(heartbeat[1]) if heartbeat else None,
        heartbeat_samples=int(heartbeat[2]) if heartbeat else 0,last_sample=playback[-1] if playback else None,
        status=[s for s in text.splitlines() if 'caption-proof:' in s])
    if kind=='captions': row['srt_bytes']=(root/'captions.srt').stat().st_size if (root/'captions.srt').exists() else 0
    rows.append(row)
(a.output/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))
assert all(r['rc']==0 and r['heartbeat_samples']>400 and r['heartbeat_max_ms']<250 for r in rows)
assert rows[1]['srt_bytes']>0 and any('Apple Speech' in s for s in rows[1]['status'])
assert any('Captions generated and enabled.' in s for s in rows[1]['status'])
assert all(r['last_sample'] and r['last_sample']['discarded_late_frames']==0
           and r['last_sample']['audio_underrun_callbacks']==0 for r in rows)
