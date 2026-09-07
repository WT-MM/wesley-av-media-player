"""Identity-bound build-app measurements; only child PIDs are controlled."""
import argparse,hashlib,json,os,pathlib,subprocess,time,uuid
p=argparse.ArgumentParser();p.add_argument('--asset',required=True);p.add_argument('--output',required=True);p.add_argument('--seconds',type=float,default=8);p.add_argument('--seek');a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];app=repo/'build/WAM.app/Contents/MacOS/WAM';asset=pathlib.Path(a.asset).resolve()
root=pathlib.Path(a.output).resolve();root.mkdir(parents=True,exist_ok=True)
import tempfile
with tempfile.TemporaryDirectory(prefix='wam-phase3-home-',dir='/private/tmp') as home:
 def sha(path):
  with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
 candidate=sha(app);assetsha=sha(asset);runid=str(uuid.uuid4());env=os.environ.copy()
 env.update(HOME=home,WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,
 WAM_NATIVE_BENCHMARK_ASSET_SHA256=assetsha,WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
 WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',
 WAM_TEST_QUIT_AFTER_MS=str(int(a.seconds*1000)),WAM_PLAYBACK_METRICS_PATH=str(root/'metrics.jsonl'))
 if a.seek:env['WAM_TEST_SEEK_SCRIPT']=a.seek
 with (root/'log.txt').open('w') as log:
  start=time.monotonic();process=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
  try:rc=process.wait(timeout=a.seconds+20)
  except subprocess.TimeoutExpired:process.terminate();rc=process.wait(timeout=5)
 text=(root/'log.txt').read_text()
 metrics=[json.loads(line) for line in (root/'metrics.jsonl').read_text().splitlines()] if (root/'metrics.jsonl').exists() else []
 audio_frames=max((row.get('audio_rendered_frames') or 0 for row in metrics),default=0)
 failure_lines=[line for line in text.splitlines() if 'WAM: native failure' in line]
 result=dict(asset=str(asset),asset_sha256=assetsha,candidate_sha256=candidate,run_id=runid,pid=process.pid,rc=rc,
 seconds=time.monotonic()-start,seek=a.seek,diagnostics=[line for line in text.splitlines() if line.startswith('WAM:')],
 native_selected='native_selected' in text,native='native_selected' in text and not failure_lines and ('first_frame_drawn' in text or audio_frames>0),drawn='first_frame_drawn' in text,audio_frames=audio_frames,failures=failure_lines)
 assert sha(app)==candidate and sha(asset)==assetsha
 (root/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
