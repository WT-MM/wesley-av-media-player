"""Offline full-range ASP/VP9 proof using phase-2g's hardware control projection."""
import argparse, hashlib, io, json, os, subprocess, time, uuid
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--root',type=Path,required=True)
p.add_argument('--phase',choices=['generate','capture','analyze'],required=True)
a=p.parse_args(); root=a.root; root.mkdir(parents=True,exist_ok=True)
app=Path('/private/tmp/wam-native-scratch/build/WAM.app/Contents/MacOS/WAM')
ffmpeg='/opt/homebrew/bin/ffmpeg'
def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()
if a.phase=='generate':
    commands=[]
    def run(args):
        commands.append(args); (root/'commands.json').write_text(json.dumps(commands,indent=2))
        subprocess.run(args,check=True)
    base=[ffmpeg,'-hide_banner','-loglevel','error','-y','-threads','1','-filter_threads','1']
    tags=['-color_range','pc','-color_primaries','smpte170m','-color_trc','bt709','-colorspace','smpte170m']
    run(base+['-f','lavfi','-i','smptebars=size=640x360:rate=25','-t','4','-vf','scale=in_range=tv:out_range=pc,format=yuv420p','-c:v','mpeg4','-bf','2','-q:v','1','-threads','1']+tags+[str(root/'asp.mkv')])
    run(base+['-i',str(root/'asp.mkv'),'-frames:v','1','-pix_fmt','yuv420p','-f','rawvideo',str(root/'oracle.yuv')])
    for name,matrix,range_ in [('correct','smpte170m','pc'),('matrix','bt709','pc'),('range','smpte170m','tv')]:
        run(base+['-stream_loop','-1','-f','rawvideo','-pixel_format','yuv420p','-video_size','640x360','-framerate','25','-i',str(root/'oracle.yuv'),'-t','4','-vf',f'setparams=range={"full" if range_=="pc" else "limited"}:color_primaries=smpte170m:color_trc=bt709:colorspace={matrix}','-c:v','libvpx-vp9','-profile:v','0','-lossless','1','-threads','1','-pix_fmt','yuv420p','-color_range',range_,'-color_primaries','smpte170m','-color_trc','bt709','-colorspace',matrix,str(root/(name+'.mkv'))])
    facts={}
    for name in ['asp','correct','matrix','range']:
        asset=root/(name+'.mkv')
        probe=json.loads(subprocess.check_output(['/opt/homebrew/bin/ffprobe','-v','error','-show_streams','-of','json',str(asset)]))['streams'][0]
        args=base+['-i',str(asset),'-frames:v','1','-pix_fmt','yuv420p','-f','rawvideo','-']; commands.append(args)
        decoded=subprocess.check_output(args)
        facts[name]=dict(sha256=sha(asset),codec=probe['codec_name'],profile=probe['profile'],range=probe.get('color_range'),decoded_sha256=hashlib.sha256(decoded).hexdigest())
    assert len({r['decoded_sha256'] for r in facts.values()})==1, facts
    assert facts['asp']['range']=='pc' and facts['correct']['range']=='pc' and facts['correct']['profile']=='Profile 0'
    (root/'commands.json').write_text(json.dumps(commands,indent=2));(root/'specimens.json').write_text(json.dumps(facts,indent=2)); print(json.dumps(facts,indent=2))
elif a.phase=='capture':
    cases=[('hardware-correct','correct',False),('hardware-matrix','matrix',False),('hardware-range','range',False),('software-vp9','correct',True),('software-asp','asp',True)]
    for name,source,software in cases:
        run=root/name;run.mkdir(exist_ok=False);(run/'home').mkdir();asset=run/'bars.mkv';os.link(root/(source+'.mkv'),asset)
        with (run/'gate.jsonl').open('w') as gate:
            while True:
                rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
                compilers=[r.strip() for r in rows if len(r.strip().split(None,1))==2 and Path(r.strip().split(None,1)[1]).name in {'clang','clang++','cc','c++','ld','ld64','gcc','g++','swiftc','swift-frontend','metal','metallib'}]
                load=os.getloadavg()[0];record=dict(time=time.time(),load1=load,compilers=compilers,passed=not compilers and load<8)
                gate.write(json.dumps(record)+'\n');gate.flush();print(name,json.dumps(record),flush=True)
                if record['passed']:break
                time.sleep(30)
        env={k:v for k,v in os.environ.items() if not k.startswith('WAM_')}
        env.update(HOME=str(run/'home'),WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=sha(app),WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'),WAM_TEST_QUIT_AFTER_MS='6500',WAM_TEST_WINDOW_SCRIPT=f'pause:0@1000,report@2500,videograb:0:{run}/display.png@500,report@500')
        if software:env['WAM_TEST_NO_VIDEO_HARDWARE']='1'
        (run/'environment.json').write_text(json.dumps({k:v for k,v in env.items() if k.startswith('WAM_') or k=='HOME'},indent=2))
        with (run/'log.txt').open('w') as log:
            process=subprocess.Popen([str(app),str(asset)],env=env,stdout=log,stderr=log)
            try:rc=process.wait(timeout=25)
            except subprocess.TimeoutExpired:process.terminate();rc=process.wait(timeout=10)
        text=(run/'log.txt').read_text()
        events=[json.loads(line) for line in text.splitlines() if line.startswith('{') and '"event"' in line]
        assert all(e.get('run_id')==env['WAM_NATIVE_BENCHMARK_RUN_ID'] and e.get('asset_sha256')==sha(asset) and e.get('candidate_id')==sha(app) and e.get('process_id')==process.pid for e in events)
        stage='Libavcodec' if software else 'VideoToolboxHardware'
        passed=rc==0 and ('stage='+stage) in text and 'WAM: native failure' not in text and any(e.get('event')=='first_frame_drawn' for e in events) and not any(e.get('event')=='fallback_selected' for e in events) and (run/'display.png').exists()
        receipt=dict(rc=rc,pid=process.pid,expected_stage=stage,passed=passed)
        (run/'result.json').write_text(json.dumps(receipt,indent=2));print(name,receipt,flush=True)
        if not passed:raise SystemExit(1)
else:
    import numpy as np
    from PIL import Image,ImageCms
    def managed(name):
        im=Image.open(root/name/'display.png');assert im.size==(480,270) and np.ptp(np.asarray(im))>32
        return np.asarray(ImageCms.profileToProfile(im,ImageCms.ImageCmsProfile(io.BytesIO(im.info['icc_profile'])),ImageCms.createProfile('sRGB'),outputMode='RGB'),dtype=float)
    correct,wm,wr=map(managed,['hardware-correct','hardware-matrix','hardware-range'])
    mask=np.ones(correct.shape[:2],dtype=bool);mask[:12]=False;mask[-12:]=False;mask[:,:12]=False;mask[:,-12:]=False
    for shift in range(-3,4):
        for axis in [0,1]:mask &= np.max(np.abs(np.roll(correct,shift,axis=axis)-correct),axis=2)<2
    assert mask.sum()>1000
    results=[]
    for name in ['software-asp','software-vp9']:
        delta=managed(name)[mask]-correct[mask];projections={};denominators={}
        for label,wrong in [('wrong_matrix',wm),('wrong_range',wr)]:
            direction=wrong[mask]-correct[mask];den=float(np.sum(direction*direction));assert den>1000
            denominators[label]=den;projections[label]=float(np.sum(delta*direction)/den)
        rms=float(np.sqrt(np.mean(delta*delta)))
        results.append(dict(name=name,pixels=int(mask.sum()),rms=rms,projections=projections,control_energy=denominators,passed=rms<=6 and all(abs(v)<=.15 for v in projections.values())))
    (root/'projection.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
    raise SystemExit(0 if all(r['passed'] for r in results) else 1)
