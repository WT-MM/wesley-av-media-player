import pathlib,subprocess,os,json,uuid,hashlib,sys
repo=pathlib.Path('/Users/wesleymaa/Documents/WAM');root=pathlib.Path('/private/tmp/wam-phase2f'); mode=sys.argv[1];out=root/('paired-'+mode);out.mkdir(exist_ok=True)
app=repo/'build/WAM.app/Contents/MacOS/WAM'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
rows=[]
cases=[]
for range_ in ['limited','full']:
 for name in ['baseline','asp','hi10p','h264422','vp9','vp9p2']:
  cases.append((range_+'-'+name,root/('capture-hardware-'+range_)/name/'bars.mkv'))
for transfer in ['smpte2084','arib-std-b67']:
 for codec in ['h264','hevc']:
  asset=root/(codec+'-'+transfer+'.mkv')
  if mode=='hdr-hardware' or not asset.exists():
   opts=['-c:v','libx265','-x265-params','pools=1:frame-threads=1:log-level=error:colorprim=9:transfer='+('16' if transfer=='smpte2084' else '18')+':colormatrix=9'] if codec=='hevc' else ['-c:v','libx264','-profile:v','high10','-x264-params','colorprim=bt2020:transfer='+transfer+':colormatrix=bt2020nc']
   subprocess.run(['ffmpeg','-v','error','-y','-threads','1','-filter_threads','1','-f','lavfi','-i','smptebars=size=640x360:rate=25','-t','4','-vf','setparams=color_primaries=bt2020:color_trc='+transfer+':colorspace=bt2020nc',*opts,'-threads','1','-pix_fmt','yuv420p10le','-color_range','tv','-color_primaries','bt2020','-color_trc',transfer,'-colorspace','bt2020nc',str(asset)],check=True)
  cases.append((codec+'-'+transfer,asset))
if mode=='hdr-hardware':cases=cases[-4:]
for name,asset in cases:
 if not asset.exists():continue
 run=out/name;run.mkdir(exist_ok=True);(run/'home').mkdir(exist_ok=True)
 env=os.environ.copy();env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=sha(app),WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'),WAM_TEST_QUIT_AFTER_MS='4000',WAM_TEST_WINDOW_SCRIPT=f'pause:0@1300,report@200,grab:0:{run}/scene.png@300,videograb:0:{run}/display.png@300,report@400')
 if mode=='software':env['WAM_TEST_NO_VIDEO_HARDWARE']='1'
 else:env.pop('WAM_TEST_NO_VIDEO_HARDWARE',None)
 with (run/'log.txt').open('w') as log:
  p=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
  try:rc=p.wait(timeout=15)
  except subprocess.TimeoutExpired:p.terminate();rc=p.wait(timeout=5)
 text=(run/'log.txt').read_text();rows.append(dict(name=name,asset=str(asset),rc=rc,pid=p.pid,identities={k:v for k,v in env.items() if k.startswith('WAM_')},diagnostics=[l for l in text.splitlines() if l.startswith('WAM')]))
 (out/'results.json').write_text(json.dumps(rows,indent=2));print(name,rc,flush=True)
