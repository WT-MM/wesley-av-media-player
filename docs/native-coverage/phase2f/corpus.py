"""Quiet six-second corpus campaign, bound to the unchanged candidate and assets."""
import argparse,hashlib,json,os,pathlib,subprocess,time,uuid
p=argparse.ArgumentParser();p.add_argument('--corpus',required=True);p.add_argument('--output',required=True);a=p.parse_args()
repo=pathlib.Path('/Users/wesleymaa/Documents/WAM');app=repo/'build/WAM.app/Contents/MacOS/WAM'
root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
def sha(path):
 with open(path,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
candidate=sha(app);baseline={r['path']:r['status'] for r in json.loads((repo/'docs/native-coverage/phase2e/corpus-final-results.json').read_text())}
rows=[]
for i,line in enumerate(pathlib.Path(a.corpus).read_text().splitlines()):
 if not line.strip():continue
 asset=pathlib.Path(line);run=root/f'{i:03}';run.mkdir(exist_ok=True);(run/'home').mkdir(exist_ok=True)
 assert sha(app)==candidate,'candidate changed'
 runid=str(uuid.uuid4());assetsha=sha(asset);env=os.environ.copy()
 env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,
 WAM_NATIVE_BENCHMARK_ASSET_SHA256=assetsha,WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
 WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',
 WAM_TEST_QUIT_AFTER_MS='6000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'))
 begin=time.monotonic()
 with (run/'log.txt').open('w') as log:
  process=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
  try:rc=process.wait(timeout=18)
  except subprocess.TimeoutExpired:process.terminate();rc=process.wait(timeout=5)
 text=(run/'log.txt').read_text();failures=[x for x in text.splitlines() if 'WAM: native failure' in x]
 metrics=[json.loads(x) for x in (run/'metrics.jsonl').read_text().splitlines()] if (run/'metrics.jsonl').exists() else []
 drawn=max(((x.get('drawn_frames') or 0) for x in metrics if x.get('record')=='playback_sample'),default=0)
 status='NATIVE_OK' if drawn>0 and rc==0 and 'native_selected' in text and 'first_frame_drawn' in text and not failures else 'REFUSED'
 rows.append(dict(path=str(asset),drawn_frames=drawn,status=status,baseline=baseline.get(str(asset)),failures=failures,rc=rc,
 asset_sha256=assetsha,candidate_sha256=candidate,run_id=runid,pid=process.pid,wall_seconds=time.monotonic()-begin,
 metrics=str(run/'metrics.jsonl'),routes=[x for x in text.splitlines() if x.startswith('WAM: native decoder')]))
 (root/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
 print(i+1,status,str(asset),flush=True)
regressions=[r for r in rows if r['baseline']=='NATIVE_OK' and r['status']!='NATIVE_OK']
summary=dict(total=len(rows),native=sum(r['status']=='NATIVE_OK' for r in rows),regressions=regressions,candidate_sha256=candidate)
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary),flush=True)
