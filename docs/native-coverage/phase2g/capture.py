import pathlib,subprocess,os,json,uuid,hashlib,sys
root=pathlib.Path('/private/tmp/wam-phase2g');app=pathlib.Path('/private/tmp/wam-cov/build/WAM.app/Contents/MacOS/WAM')
def sha(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
run=root/sys.argv[1];run.mkdir(parents=True,exist_ok=True);(run/'home').mkdir(exist_ok=True);asset=pathlib.Path(sys.argv[2])
env=os.environ.copy();env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=sha(app),WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'),WAM_TEST_QUIT_AFTER_MS='6500',WAM_TEST_WINDOW_SCRIPT=f'pause:0@1,report@4500,grab:0:{run}/scene.png@300,videograb:0:{run}/display.png@300,report@400')
with (run/'log.txt').open('w') as log:
 p=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
 try:rc=p.wait(timeout=18)
 except subprocess.TimeoutExpired:p.terminate();rc=p.wait(timeout=5)
row=dict(asset=str(asset),rc=rc,pid=p.pid,env={k:v for k,v in env.items() if k.startswith('WAM_') or k=='HOME'})
(run/'receipt.json').write_text(json.dumps(row,indent=2));print(json.dumps(row));print((run/'log.txt').read_text())
