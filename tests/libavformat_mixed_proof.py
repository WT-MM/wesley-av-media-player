"""Independent ffmpeg video timestamps and retained PCM for two-track libavformat playback."""
import argparse,hashlib,json,pathlib,subprocess,tempfile
from fractions import Fraction
import numpy as np
p=argparse.ArgumentParser()
for name in ['video-probe','audio-probe','ffmpeg','ffprobe','output']:p.add_argument('--'+name,required=True)
p.add_argument('--asset',action='append',required=True);p.add_argument('--equal-endpoints',action='store_true');a=p.parse_args();rows=[]
def run(command):
 r=subprocess.run(command,capture_output=True,text=True,timeout=900)
 if r.returncode==-9:r=subprocess.run(command,capture_output=True,text=True,timeout=900)
 assert r.returncode==0,(command,r.stderr);return r
with tempfile.TemporaryDirectory(prefix='wam-mixed-proof-',dir='/private/tmp') as tmp:
 root=pathlib.Path(tmp)
 for name in a.asset:
  asset=pathlib.Path(name);times=root/'times.txt'
  info=json.loads(run([a.ffprobe,'-v','error','-select_streams','v:0','-show_streams','-show_frames','-of','json',str(asset)]).stdout)
  tb=Fraction(info['streams'][0]['time_base'])
  expected=[(Fraction(f.get('best_effort_timestamp',f.get('pts')))*tb,Fraction(f.get('duration',f.get('pkt_duration')))*tb) for f in info['frames'] if f.get('media_type')=='video']
  video=run([a.video_probe,str(asset),str(times)])
  actual=[tuple(Fraction(x) for x in line.split()) for line in times.read_text().splitlines()]
  assert actual==expected,(name,len(actual),len(expected),next(((i,x,y) for i,(x,y) in enumerate(zip(actual,expected)) if x!=y),None))
  reference=root/'reference.f32'
  audioInfo=json.loads(run([a.ffprobe,'-v','error','-select_streams','a:0','-show_streams','-of','json',str(asset)]).stdout)['streams'][0]
  downmix=['-af','pan=stereo|c0=c0|c1=c0'] if audioInfo['channels']==1 else ['-ac','2']
  run([a.ffmpeg,'-v','error','-y','-i',str(asset),'-map','0:a:0',*downmix,'-f','f32le',str(reference)])
  want=np.memmap(reference,dtype='<f4',mode='r').reshape(-1,2)
  duration=Fraction(len(want),48000)
  videoEnd=max(t+d for t,d in expected)
  if a.equal_endpoints:assert videoEnd==duration,(name,videoEnd,duration)
  targets=['0','1','1/7',str(duration-Fraction(1,1000))]
  cases=[];baseline=None
  for target in targets:
   pcm=root/'actual.f32';result=run([a.audio_probe,str(asset),str(pcm),target]);value=Fraction(target)*48000;first=-(-value.numerator//value.denominator)
   actualPcm=np.memmap(pcm,dtype='<f4',mode='r').reshape(-1,2)
   assert len(actualPcm)==len(want)-first,(name,target,len(actualPcm),len(want)-first)
   # Bound comparison workspace independently of movie duration.
   maximum=0.;squared=0.;samples=0
   for begin in range(0,len(actualPcm),48000):
    x=actualPcm[begin:begin+48000].astype('float64')-want[first+begin:first+begin+len(actualPcm[begin:begin+48000])]
    maximum=max(maximum,float(np.max(abs(x))));squared+=float(np.sum(x*x));samples+=x.size
   rms=(squared/samples)**.5
   if baseline is None:
    assert maximum<.002 and rms<.0001,(name,target,maximum,rms)
    baseline=actualPcm
   else:
    for begin in range(0,len(actualPcm),48000):
     assert np.array_equal(actualPcm[begin:begin+48000],baseline[first+begin:first+begin+len(actualPcm[begin:begin+48000])]),(name,target,'native seek differs from exact baseline slice')
   # The first second provides a bounded correlation window at each exact landing.
   count=min(48000,len(actualPcm));x=np.asarray(actualPcm[:count,0]);y=np.asarray(want[first:first+count,0]);lag_errors={str(lag):float(np.mean((x[max(lag,0):count+min(lag,0)]-y[max(-lag,0):count-max(lag,0)])**2)) for lag in [-2,-1,0,1,2]}
   if first==0:assert lag_errors['0']<=min(lag_errors.values())+1e-14,(name,target,lag_errors)
   cases.append(dict(target=target,first_frame=first,frames=len(actualPcm),max_error=maximum,rms=rms,alignment_frames=0,exact_baseline_slice=True,reference_lag_errors=lag_errors,log=result.stderr))
   del actualPcm;pcm.unlink()
  rows.append(dict(asset=name,asset_sha256=hashlib.sha256(asset.read_bytes()).hexdigest(),video_end=str(videoEnd),audio_end=str(duration),endpoint_difference=str(videoEnd-duration),video_frames=len(expected),exact_pts=len(actual),exact_durations=len(actual),video_log=video.stdout+video.stderr,audio_frames=len(want),cases=cases))
  del want,baseline;reference.unlink()
  pathlib.Path(a.output).write_text(json.dumps(dict(video_probe_sha256=hashlib.sha256(pathlib.Path(a.video_probe).read_bytes()).hexdigest(),audio_probe_sha256=hashlib.sha256(pathlib.Path(a.audio_probe).read_bytes()).hexdigest(),assets=rows),indent=2)+'\n')
print(json.dumps(rows,indent=2))
