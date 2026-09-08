import argparse,hashlib,json,os,pathlib,subprocess,time,uuid
p=argparse.ArgumentParser();p.add_argument('--corpus',default='/private/tmp/wam-phase2g/corpus.txt');p.add_argument('--output',required=True);a=p.parse_args()
app=pathlib.Path('/private/tmp/wam-cov/build/WAM.app/Contents/MacOS/WAM');root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
def sha(path):
 with open(path,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
candidate=sha(app);baseline={r.split('\t')[0]:r.split('\t')[1] for r in pathlib.Path('/private/tmp/wam-phase2g/corpus_baseline_84.tsv').read_text().splitlines()};rows=[]
for i,line in enumerate(pathlib.Path(a.corpus).read_text().splitlines()):
 if not line.strip():continue
 asset=pathlib.Path(line);run=root/f'{i:03}';run.mkdir();(run/'home').mkdir();assert sha(app)==candidate
 runid=str(uuid.uuid4());assetsha=sha(asset);env=os.environ.copy()
 for k in ['WAM_TEST_WINDOW_SCRIPT','WAM_TEST_SEEK_SCRIPT','WAM_TEST_NO_VIDEO_HARDWARE']:env.pop(k,None)
 env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,WAM_NATIVE_BENCHMARK_ASSET_SHA256=assetsha,WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_TEST_QUIT_AFTER_MS='6000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'))
 begin=time.monotonic()
 with (run/'log.txt').open('w') as f:
  proc=subprocess.Popen([str(app),str(asset)],env=env,stdout=f,stderr=f)
  try:rc=proc.wait(timeout=18)
  except subprocess.TimeoutExpired:proc.terminate();rc=proc.wait(timeout=5)
 text=(run/'log.txt').read_text();failures=[x for x in text.splitlines() if 'WAM: native failure' in x];samples=[json.loads(x) for x in (run/'metrics.jsonl').read_text().splitlines()] if (run/'metrics.jsonl').exists() else []
 samples=[x for x in samples if x.get('record')=='playback_sample'];drawn=max([(x.get('drawn_frames') or 0) for x in samples]+[0]);clock=[x.get('clock_rate') for x in samples if (x.get('drawn_frames') or 0)>0 and not x.get('paused')]
 status='NATIVE_OK' if rc==0 and 'native_selected' in text and 'first_frame_drawn' in text and drawn>0 and not failures else 'REFUSED'
 row=dict(path=str(asset),status=status,baseline=baseline.get(str(asset)),failures=failures,rc=rc,asset_sha256=assetsha,candidate_sha256=candidate,run_id=runid,pid=proc.pid,wall_seconds=time.monotonic()-begin,drawn_frames=drawn,clock_1_0000=bool(clock) and all(x==1 for x in clock),last_sample=samples[-1] if samples else None,metrics=str(run/'metrics.jsonl'),routes=[x for x in text.splitlines() if x.startswith('WAM: native decoder')])
 rows.append(row);(root/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(i+1,status,drawn,str(asset),flush=True)
summary=dict(total=len(rows),native=sum(x['status']=='NATIVE_OK' for x in rows),regressions=[x for x in rows if x['baseline']=='NATIVE_OK' and x['status']!='NATIVE_OK'],candidate_sha256=candidate)
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary),flush=True)
