"""Whole-app VP9 ingress rollback proofs with exact source restoration."""
import argparse,hashlib,json,os,pathlib,subprocess,uuid
p=argparse.ArgumentParser();p.add_argument('--asset',required=True);p.add_argument('--output',required=True);a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
app=repo/'build/WAM.app/Contents/MacOS/WAM';asset=pathlib.Path(a.asset).resolve()
def sha(path):
 with open(path,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def build(label):
 with (root/(label+'-build.txt')).open('w') as log:
  r=subprocess.run(['cmake','--build','build','--parallel'],cwd=repo,stdout=log,stderr=log)
 assert r.returncode==0,label

def playback(label):
 run=root/label;run.mkdir();(run/'home').mkdir();runid=str(uuid.uuid4());candidate=sha(app);env=os.environ.copy()
 env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,
 WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
 WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_TEST_NO_VIDEO_HARDWARE='1',
 WAM_TEST_QUIT_AFTER_MS='6000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'))
 with (run/'log.txt').open('w') as log:
  process=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
  try:rc=process.wait(timeout=18)
  except subprocess.TimeoutExpired:process.terminate();rc=process.wait(timeout=5)
 text=(run/'log.txt').read_text()
 passed=rc==0 and 'native_selected' in text and 'first_frame_drawn' in text and 'stage=Libavcodec' in text and 'WAM: native failure' not in text
 return dict(label=label,passed=passed,rc=rc,pid=process.pid,run_id=runid,candidate_sha256=candidate,asset_sha256=sha(asset),diagnostics=[x for x in text.splitlines() if x.startswith('WAM:')])
rows=[]
for name,file in [('consumer','src/platform/macos/native_video_consumer.mm'),('sample_builder','src/platform/macos/matroska_sample_builder.mm')]:
 path=repo/file;original=path.read_bytes();text=original.decode();before='nativeVp9StageAdmitted()';assert text.count(before)==1
 build(name+'-baseline');baseline=playback(name+'-baseline');assert baseline['passed'],baseline
 try:
  path.write_text(text.replace(before,'nativeVideoToolboxSupportsVp9()'))
  build(name+'-reverted');reverted=playback(name+'-reverted');assert not reverted['passed'],reverted
 finally:path.write_bytes(original)
 assert path.read_bytes()==original
 build(name+'-restored');restored=playback(name+'-restored');assert restored['passed'],restored
 rows.append(dict(name=name,path=file,before_sha256=hashlib.sha256(original).hexdigest(),restored_sha256=sha(path),baseline=baseline,reverted=reverted,restored=restored))
 (root/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(name,'revert fails; restored passes',flush=True)
