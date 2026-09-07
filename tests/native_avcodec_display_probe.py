"""Capture only identity-bound build-app windows through the in-process seams."""
import argparse,hashlib,json,os,pathlib,subprocess,uuid
p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--hardware',action='store_true');a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
app=repo/'build/WAM.app/Contents/MacOS/WAM'
def sha(p):
 with open(p,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
rows=[]
for name,options in [('baseline',['-c:v','libx264','-pix_fmt','yuv420p']),('asp',['-c:v','mpeg4','-bf','2']),('hi10p',['-c:v','libx264','-profile:v','high10','-pix_fmt','yuv420p10le']),('h264422',['-c:v','libx264','-profile:v','high422','-pix_fmt','yuv422p10le'])]:
 run=root/name;run.mkdir(exist_ok=True);(run/'home').mkdir(exist_ok=True)
 asset=run/'bars.mkv';command=['ffmpeg','-v','error','-y','-f','lavfi','-i','smptebars=size=640x360:rate=25','-t','4',*options,'-color_primaries','smpte170m','-color_trc','bt709','-colorspace','smpte170m',str(asset)]
 subprocess.run(command,check=True)
 env=os.environ.copy();runid=str(uuid.uuid4());candidate=sha(app)
 env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=runid,
 WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
 WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_TEST_NO_VIDEO_HARDWARE='1',
 WAM_TEST_QUIT_AFTER_MS='4000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'),
 WAM_TEST_WINDOW_SCRIPT=f'pause:0@1300,report@200,grab:0:{run}/scene.png@300,videograb:0:{run}/display.png@300,report@400')
 if a.hardware:env.pop('WAM_TEST_NO_VIDEO_HARDWARE',None)
 with (run/'log.txt').open('w') as log:
  process=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
  try:rc=process.wait(timeout=15)
  except subprocess.TimeoutExpired:process.terminate();rc=process.wait(timeout=5)
 text=(run/'log.txt').read_text()
 rows.append(dict(name=name,argv=command,rc=rc,pid=process.pid,run_id=runid,candidate_sha256=candidate,asset_sha256=sha(asset),
 routes=[x for x in text.splitlines() if x.startswith('WAM: native decoder')],
 failures=[x for x in text.splitlines() if 'WAM: native failure' in x],
 captures=[x for x in text.splitlines() if 'WAM_TEST_GRAB' in x or 'WAM_TEST_VIDEOGRAB' in x],
 display_file=(run/'display.png').exists()))
 (root/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(rows[-1],flush=True)
