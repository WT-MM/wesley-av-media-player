"""App-level lazy image inventory and named-refusal observations."""
import argparse,hashlib,json,os,pathlib,subprocess,time,uuid
p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--baseline',required=True);p.add_argument('--asp',required=True);a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];app=repo/'build/WAM.app/Contents/MacOS/WAM'
root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
def sha(p):
 with open(p,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
rows=[]
assets=[('verify',pathlib.Path(a.baseline)),('hardware',pathlib.Path(a.baseline)),('software',pathlib.Path(a.asp))]
for name in ['dts','truehd','mlp']:
 asset=root/(name+'-video.mkv')
 subprocess.run(['ffmpeg','-v','error','-y','-i',a.baseline,'-i',str(repo/'test-media/native-coverage/phase2'/(name+'.mka')),'-map','0:v:0','-map','1:a:0','-c','copy','-t','2',str(asset)],check=True)
 assets.append((name,asset))
for name,asset in assets:
 run=root/name;run.mkdir(exist_ok=True);(run/'home').mkdir(exist_ok=True)
 env=os.environ.copy();runid=str(uuid.uuid4());candidate=sha(app)
 env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,
 WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
 WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',
 WAM_TEST_QUIT_AFTER_MS='6000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'))
 command=[str(app),'--verify-runtime' if name=='verify' else str(asset)]
 inventory=None
 with (run/'log.txt').open('w') as log:
  process=subprocess.Popen(command,env=env,stdout=log,stderr=log)
  if name in ['hardware','software']:
   time.sleep(2)
   r=subprocess.run(['/usr/bin/vmmap','-w',str(process.pid)],capture_output=True,text=True,timeout=10)
   (run/'vmmap.txt').write_text(r.stdout+r.stderr)
   inventory=dict(rc=r.returncode,ffmpeg_images=sorted(set(line for line in r.stdout.splitlines() if 'libavcodec' in line or 'libavutil' in line or 'WAMMpvFallback' in line)))
  try:rc=process.wait(timeout=18)
  except subprocess.TimeoutExpired:process.terminate();rc=process.wait(timeout=5)
 text=(run/'log.txt').read_text()
 rows.append(dict(name=name,rc=rc,pid=process.pid,run_id=runid,asset_sha256=sha(asset),candidate_sha256=candidate,inventory=inventory,
 diagnostics=[line for line in text.splitlines() if line.startswith('WAM:') or 'native_codec_stages' in line or 'native_hardware_capabilities' in line]))
 (root/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(name,rc,flush=True)
