"""Both fallback/native load orders must preserve native drawn-frame progress."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile,uuid,time
p=argparse.ArgumentParser();p.add_argument('--asset',required=True);p.add_argument('--fallback-asset',required=True);p.add_argument('--output',required=True);p.add_argument('--fallback-first',action='store_true');a=p.parse_args();root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True);repo=pathlib.Path(__file__).resolve().parents[1];app=repo/'build/WAM.app/Contents/MacOS/WAM';asset=pathlib.Path(a.asset);other=pathlib.Path(a.fallback_asset)
def sha(p):return hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
candidate=sha(app);runid=str(uuid.uuid4())
with tempfile.TemporaryDirectory(prefix='wam-coexist-home-',dir=str(root)) as home:
 env=os.environ.copy();env.update(HOME=home,WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(other if a.fallback_first else asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_TEST_QUIT_AFTER_MS='9000',WAM_PLAYBACK_METRICS_PATH=str(root/'metrics.jsonl'),WAM_TEST_WINDOW_SCRIPT=f'new@2000,load:1:{asset if a.fallback_first else other}@0,report@1500,close:{0 if a.fallback_first else 1}@1500,report@1000')
 with (root/'log.txt').open('w') as log:
  process=subprocess.Popen([str(app),str(other if a.fallback_first else asset)],env=env,stdout=log,stderr=log)
  for moment,delay in [(4,4),(7,3)]:
   time.sleep(delay)
   images=subprocess.run(['vmmap',str(process.pid)],capture_output=True,text=True,timeout=10)
   (root/f'images-{moment}.txt').write_text(images.stdout+images.stderr)
  try:rc=process.wait(timeout=20)
  except subprocess.TimeoutExpired:process.terminate();rc=process.wait(timeout=5)
 text=(root/'log.txt').read_text();samples=[json.loads(x) for x in (root/'metrics.jsonl').read_text().splitlines()];samples=[r for r in samples if r.get('drawn_frames') is not None]
 # The telemetry stream retains session identities across independent windows.
 epochs={r['session_epoch'] for r in samples};progress={str(e):[r['drawn_frames'] for r in samples if r['session_epoch']==e] for e in epochs}
 result=dict(rc=rc,pid=process.pid,run_id=runid,candidate_sha256=candidate,asset_sha256=sha(asset),fallback_asset_sha256=sha(other),closure_refusal='PlaybackFfmpegClosureConflict' in text,progress=progress,diagnostics=[x for x in text.splitlines() if x.startswith('WAM') or 'ClosureConflict' in x])
 (root/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
 assert rc==0 and not result['closure_refusal'] and any(len(v)>3 and v[-1]>v[1] for v in progress.values()),result
 assert 'native_selected' in text and 'first_frame_drawn' in text,result
 assert any('media=1' in line and 'playing=1' in line and f'source={other.name}' in line for line in text.splitlines()),result
 for moment in [4,7]:
  images=(root/f'images-{moment}.txt').read_text()
  assert 'WAMMpvFallback' in images and 'libavcodec-wamnative' in images,images
 assert sha(app)==candidate
