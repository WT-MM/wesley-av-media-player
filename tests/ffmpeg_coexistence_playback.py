"""A refused second-window fallback must leave the first native session drawing."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile,uuid
p=argparse.ArgumentParser();p.add_argument('--asset',required=True);p.add_argument('--fallback-asset',required=True);p.add_argument('--output',required=True);a=p.parse_args();root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True);repo=pathlib.Path(__file__).resolve().parents[1];app=repo/'build/WAM.app/Contents/MacOS/WAM';asset=pathlib.Path(a.asset);other=pathlib.Path(a.fallback_asset)
def sha(p):return hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
candidate=sha(app);runid=str(uuid.uuid4())
with tempfile.TemporaryDirectory(prefix='wam-coexist-home-',dir='/private/tmp') as home:
 env=os.environ.copy();env.update(HOME=home,WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_TEST_QUIT_AFTER_MS='9000',WAM_PLAYBACK_METRICS_PATH=str(root/'metrics.jsonl'),WAM_TEST_WINDOW_SCRIPT=f'new@2000,load:1:{other}@0,report@1500,close:1@1500,report@1000')
 with (root/'log.txt').open('w') as log:
  process=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
  try:rc=process.wait(timeout=20)
  except subprocess.TimeoutExpired:process.terminate();rc=process.wait(timeout=5)
 text=(root/'log.txt').read_text();samples=[json.loads(x) for x in (root/'metrics.jsonl').read_text().splitlines()];samples=[r for r in samples if r.get('drawn_frames') is not None]
 # The telemetry stream retains session identities across independent windows.
 epochs={r['session_epoch'] for r in samples};progress={str(e):[r['drawn_frames'] for r in samples if r['session_epoch']==e] for e in epochs}
 result=dict(rc=rc,pid=process.pid,run_id=runid,candidate_sha256=candidate,asset_sha256=sha(asset),fallback_asset_sha256=sha(other),closure_refusal='PlaybackFfmpegClosureConflict' in text,progress=progress,diagnostics=[x for x in text.splitlines() if x.startswith('WAM') or 'ClosureConflict' in x])
 (root/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
 assert result['closure_refusal'] and any(len(v)>5 and v[-1]>v[2] for v in progress.values()),result
 assert sha(app)==candidate
