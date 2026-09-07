import pathlib,subprocess,os,uuid,hashlib,json,time,argparse
parser=argparse.ArgumentParser()
parser.add_argument('--list',required=True)
parser.add_argument('--baseline',required=True)
parser.add_argument('--output',required=True)
args=parser.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1]
root=pathlib.Path(args.output);root.mkdir(parents=True,exist_ok=True)
paths=pathlib.Path(args.list).read_text().splitlines();baseline={x.split('\t')[0]:x.split('\t')[1] for x in pathlib.Path(args.baseline).read_text().splitlines()}
app=repo/'build/WAM.app/Contents/MacOS/WAM'
def sha(path):
 with open(path,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
candidate=sha(app);results=[]
for i,path in enumerate(paths):
 run=root/f'{i:03}';run.mkdir(exist_ok=True);(run/'home').mkdir(exist_ok=True)
 env={k:v for k,v in os.environ.items() if not k.startswith('WAM_')};runid=str(uuid.uuid4());asset=sha(path)
 env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,WAM_NATIVE_BENCHMARK_ASSET_SHA256=asset,WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'),WAM_TEST_QUIT_AFTER_MS='6000')
 (run/'launch.json').write_text(json.dumps(dict(argv=[str(app),path],executable_sha256=candidate,env={k:v for k,v in env.items() if k.startswith('WAM_') or k=='HOME'}),indent=2))
 with (run/'stderr.txt').open('w') as err,(run/'telemetry.jsonl').open('w') as out:
  p=subprocess.Popen([str(app),path],env=env,stderr=err,stdout=out);(run/'pid.txt').write_text(str(p.pid));started=time.monotonic()
  try:rc=p.wait(timeout=15)
  except subprocess.TimeoutExpired:
   p.terminate()
   try:rc=p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();rc=p.wait()
 assert sha(app)==candidate, 'executable changed during corpus campaign'
 stderr=(run/'stderr.txt').read_text();tele=stderr+(run/'telemetry.jsonl').read_text()
 failures=[line for line in stderr.splitlines() if 'WAM: native failure' in line]
 fallback='fallback_selected' in tele; status='NATIVE_OK' if not failures and not fallback and 'native_selected' in tele and 'first_frame_drawn' in tele and rc==0 else 'REFUSED'
 row=dict(path=path,status=status,baseline=baseline.get(path),failures=failures,rc=rc,asset_sha256=asset,candidate_sha256=candidate,run_id=runid,pid=p.pid,wall_seconds=time.monotonic()-started,metrics=str(run/'metrics.jsonl'))
 results.append(row);(root/'results.json').write_text(json.dumps(results,indent=2));print(i+1,status,path,failures,flush=True)
(root/'results.tsv').write_text(''.join(f"{r['path']}\t{r['status']}\n" for r in results))
regressed=[r for r in results if r['baseline']=='NATIVE_OK' and r['status']!='NATIVE_OK']
print('FINAL',sum(r['status']=='NATIVE_OK' for r in results),len(results),'REGRESSIONS',len(regressed),flush=True)
