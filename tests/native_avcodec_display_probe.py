"""Capture only identity-bound build-app windows through the in-process seams."""
import argparse,hashlib,json,pathlib,subprocess,sys,uuid
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent/'support'))
import wam_launch  # noqa: E402
p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--hardware',action='store_true');p.add_argument('--full-range',action='store_true');a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
app=repo/'build/WAM.app/Contents/MacOS/WAM'
def sha(p):
 with open(p,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
rows=[]
for name,options in [('baseline',['-c:v','libx264','-pix_fmt','yuv420p']),('asp',['-c:v','mpeg4','-bf','2']),('hi10p',['-c:v','libx264','-profile:v','high10','-pix_fmt','yuv420p10le']),('h264422',['-c:v','libx264','-profile:v','high422','-pix_fmt','yuv422p10le']),('vp9',['-c:v','libvpx-vp9','-pix_fmt','yuv420p','-threads','1']),('vp9p2',['-c:v','libvpx-vp9','-pix_fmt','yuv420p10le','-profile:v','2','-threads','1'])]:
 run=root/name;run.mkdir(exist_ok=True);(run/'home').mkdir(exist_ok=True)
 asset=run/'bars.mkv';command=['ffmpeg','-v','error','-y','-threads','1','-filter_threads','1','-f','lavfi','-i','smptebars=size=640x360:rate=25','-t','4',*(['-vf','scale=in_range=tv:out_range=pc'] if a.full_range else []),*options,'-threads','1','-color_range','pc' if a.full_range else 'tv','-color_primaries','smpte170m','-color_trc','bt709','-colorspace','smpte170m',str(asset)]
 subprocess.run(command,check=True)
 runid=str(uuid.uuid4());candidate=sha(app)
 env=wam_launch.seam_env(run/'home',run_id=runid,
 asset_sha256=sha(asset),candidate_id=candidate,
 WAM_TEST_NO_VIDEO_HARDWARE='1',
 WAM_TEST_QUIT_AFTER_MS='4000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'),
 WAM_TEST_WINDOW_SCRIPT=f'pause:0@1300,report@200,grab:0:{run}/scene.png@300,videograb:0:{run}/display.png@300,report@400')
 if a.hardware or name=='baseline':env.pop('WAM_TEST_NO_VIDEO_HARDWARE',None)
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
