"""Quiet app proof of production software audio beside hardware video."""
import argparse,hashlib,json,os,pathlib,subprocess,uuid
p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--assets',required=True);a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];app=repo/'build/WAM.app/Contents/MacOS/WAM';root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
rows=[]
for name in ['dts','truehd','mlp']:
 asset=pathlib.Path(a.assets)/(name+'-video.mkv');run=root/name;run.mkdir(exist_ok=True);home=run/'home';home.mkdir(exist_ok=True)
 env=os.environ.copy();runid=str(uuid.uuid4());candidate=sha(app)
 env.update(HOME=str(home),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_TEST_QUIT_AFTER_MS='6000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'))
 with (run/'log.txt').open('w') as log:
  child=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
  try:rc=child.wait(timeout=20)
  except subprocess.TimeoutExpired:child.terminate();rc=child.wait(timeout=5)
 logs=(run/'log.txt').read_text();metrics=[json.loads(x) for x in (run/'metrics.jsonl').read_text().splitlines()] if (run/'metrics.jsonl').exists() else []
 samples=[x for x in metrics if x.get('record')=='playback_sample' and x.get('media_seconds') is not None]
 row=dict(family=name,rc=rc,run_id=runid,candidate_sha256=candidate,asset_sha256=sha(asset),last=samples[-1] if samples else None,failures=[x for x in logs.splitlines() if 'native failure' in x]);rows.append(row)
 (root/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
 assert rc==0 and not row['failures'] and samples and samples[-1]['drawn_frames']==50 and samples[-1]['audio_rendered_frames']==96000 and samples[-1]['discarded_late_frames']==0 and samples[-1]['superseded_frames']==0,row
print(json.dumps(rows,indent=2))
