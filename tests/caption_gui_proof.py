#!/usr/bin/env python3
"""Paired quiet-seam playback/caption proof. Controls only its own child PIDs."""
import argparse, hashlib, json, os, pathlib, re, subprocess, time, uuid
p=argparse.ArgumentParser()
p.add_argument('--app',type=pathlib.Path,required=True)
p.add_argument('--asset',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--engine',choices=('apple','whisper'),required=True)
a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
def sha(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
def quiet_gate():
    while True:
        processes=subprocess.check_output(['ps','-axo','pid=,comm='],text=True)
        compilers=[line.strip() for line in processes.splitlines()
                   if re.search(r'/(?:clang(?:\+\+)?|clang-\d+|cc|cc1|ld|ld64|lld|ld.lld|swift-frontend|swiftc|g\+\+|c\+\+)$',line)]
        load=os.getloadavg()[0]
        row=dict(time=time.time(),load_1m=load,compilers=compilers,passed=not compilers and load<8)
        with (a.output/'gate.jsonl').open('a') as f: f.write(json.dumps(row)+'\n')
        print('quiet gate:',json.dumps(row),flush=True)
        if row['passed']: return
        time.sleep(30)
rows=[]
for kind in ('baseline','captions'):
    root=a.output/kind; root.mkdir(exist_ok=True)
    home=root/('home-'+uuid.uuid4().hex); home.mkdir()
    for generated in ('metrics.jsonl','captions.srt'):
        (root/generated).unlink(missing_ok=True)
    env=os.environ.copy()
    env.update(HOME=str(home),WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',
        WAM_TEST_GEOMETRY='480x270+2400+1000',TMPDIR=str(a.output),WAM_TEST_CAPTION_ENGINE=a.engine, WAM_TEST_QUIT_AFTER_MS='8000',
        WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),
        WAM_NATIVE_BENCHMARK_CANDIDATE_ID=sha(a.app),WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(a.asset),
        WAM_PLAYBACK_METRICS_PATH=str(root/'metrics.jsonl'),WAM_TEST_CAPTION_METRICS='1')
    if kind=='captions': env['WAM_TEST_CAPTION_OUTPUT']=str(root/'captions.srt')
    quiet_gate()
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
    identities=[json.loads(line) for line in text.splitlines()
                if line.startswith('{') and '"record":"stream_header"' in line]
    assert identities and all(s.get('process_id')==child.pid and
               s.get('run_id')==env['WAM_NATIVE_BENCHMARK_RUN_ID'] and
               s.get('candidate_id')==env['WAM_NATIVE_BENCHMARK_CANDIDATE_ID'] and
               s.get('asset_sha256')==env['WAM_NATIVE_BENCHMARK_ASSET_SHA256']
               for s in identities), 'Telemetry identity mismatch'
    assert playback, 'No playback samples in exclusive per-child metrics file'
    measured=[s for s in playback if s.get('drawn_frames') is not None]
    assert measured and all(s['discarded_late_frames']==0 and s['audio_underrun_callbacks']==0 for s in measured)
    (root/'samples.json').write_text(json.dumps(samples,indent=2)+'\n')
    live=re.search(r'caption-screen: live_ms=\s*(\d+)',text)
    committed=re.search(r'caption-screen: committed_ms=\s*(\d+)',text)
    row=dict(identity=identities[0],engine=a.engine,first_live_ms=int(live[1]) if live else None,committed_ms=int(committed[1]) if committed else None,kind=kind,pid=child.pid,rc=rc,app_sha256=sha(a.app),asset_sha256=sha(a.asset),
        heartbeat_max_ms=int(heartbeat[1]) if heartbeat else None,
        heartbeat_samples=int(heartbeat[2]) if heartbeat else 0,last_sample=playback[-1] if playback else None,
        status=[s for s in text.splitlines() if 'caption-proof:' in s])
    row['screen_receipts']=[s for s in text.splitlines() if 'caption-screen:' in s or 'caption-track:' in s]
    if kind=='captions': row['srt_bytes']=(root/'captions.srt').stat().st_size if (root/'captions.srt').exists() else 0
    rows.append(row)
(a.output/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))
assert all(r['rc']==0 and r['heartbeat_samples']>400 and r['heartbeat_max_ms']<250 for r in rows)
assert rows[1]['srt_bytes']>0
engine_messages=('Apple Speech: transcribing','Apple Speech: generating','Apple Speech captions are ready.') if a.engine=='apple' else ('Whisper Metal:',)
assert any(marker in s for marker in engine_messages for s in rows[1]['status'])
assert not any('retrying on CPU' in s for s in rows[1]['status']), 'Metal proof fell back to CPU'
assert any('Captions generated and enabled.' in s for s in rows[1]['status'])
assert all(r['last_sample'] and r['last_sample']['discarded_late_frames']==0
           and r['last_sample']['audio_underrun_callbacks']==0 for r in rows)

assert rows[1]['first_live_ms'] is not None and rows[1]['committed_ms'] is not None
assert rows[1]['first_live_ms'] <= rows[1]['committed_ms']

assert any('request playing= true' in s for s in rows[1]['screen_receipts'])
