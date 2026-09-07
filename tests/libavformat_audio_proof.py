"""Opus exact retained counts and zero-lag PCM comparisons at rational targets."""
import argparse,hashlib,json,pathlib,subprocess,tempfile
from fractions import Fraction
import numpy as np
p=argparse.ArgumentParser();p.add_argument('--probe',required=True);p.add_argument('--asset',required=True);p.add_argument('--ffmpeg',required=True);p.add_argument('--output',required=True);a=p.parse_args()
rows=[]
with tempfile.TemporaryDirectory(prefix='wam-avformat-audio-',dir='/private/tmp') as scratch:
 root=pathlib.Path(scratch);reference=root/'reference.f32'
 subprocess.run([a.ffmpeg,'-v','error','-y','-i',a.asset,'-af','pan=stereo|c0=c0|c1=c0','-f','f32le',str(reference)],check=True)
 expected=np.fromfile(reference,dtype='<f4').reshape(-1,2)
 for target in ['0','1/7','1','2999/1000']:
  path=root/'actual.f32';run=subprocess.run([a.probe,a.asset,str(path),target],capture_output=True,text=True,timeout=30)
  if run.returncode==-9:run=subprocess.run([a.probe,a.asset,str(path),target],capture_output=True,text=True,timeout=30)
  assert run.returncode==0,run.stderr
  frame=-(-(Fraction(target)*48000).numerator//(Fraction(target)*48000).denominator)
  actual=np.fromfile(path,dtype='<f4').reshape(-1,2);want=expected[frame:]
  assert actual.shape==want.shape,(target,actual.shape,want.shape)
  error=actual.astype('float64')-want;maximum=float(np.max(abs(error)));rms=float(np.sqrt(np.mean(error**2)))
  assert maximum<2e-6 and rms<2e-7,(target,maximum,rms)
  errors={str(lag):float(np.mean((actual[max(lag,0):len(actual)+min(lag,0),0]-want[max(-lag,0):len(want)-max(lag,0),0])**2)) for lag in [-2,-1,0,1,2]}
  assert min(errors,key=errors.get)=='0'
  rows.append(dict(target=target,first_frame=frame,frames=len(actual),max_error=maximum,rms=rms,best_lag=0,lag_errors=errors,log=run.stderr))
result=dict(asset=a.asset,asset_sha256=hashlib.sha256(pathlib.Path(a.asset).read_bytes()).hexdigest(),probe_sha256=hashlib.sha256(pathlib.Path(a.probe).read_bytes()).hexdigest(),cases=rows)
pathlib.Path(a.output).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
