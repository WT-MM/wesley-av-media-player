"""Production Matroska software audio: retained samples, exact seeks and channel roles."""
import argparse, hashlib, json, pathlib, subprocess, tempfile
from fractions import Fraction
import numpy as np
p=argparse.ArgumentParser()
for name in ['probe','fixtures','ffmpeg','output']:
 p.add_argument('--'+name,required=True)
a=p.parse_args();rows=[]
with tempfile.TemporaryDirectory(prefix='wam-software-audio-',dir='/private/tmp') as scratch:
 root=pathlib.Path(scratch)
 for family,codec in [('dts','dca'),('truehd','truehd'),('mlp','mlp')]:
  for channels in [2,6]:
   audio=pathlib.Path(a.fixtures)/(family+'.mka')
   if channels==6:
    audio=root/(family+'51.mka')
    impulses='|'.join('0.5*eq(n,'+str(1000+c*6000)+')' for c in range(6))
    subprocess.run([a.ffmpeg,'-v','error','-y','-f','lavfi','-i',"aevalsrc='"+impulses+"':s=48000:c=5.1(side)",'-t','2','-c:a',codec,'-strict','-2',str(audio)],check=True)
   asset=root/(family+str(channels)+'.mkv')
   subprocess.run([a.ffmpeg,'-v','error','-y','-f','lavfi','-i','testsrc2=s=160x90:r=25:d=2','-i',str(audio),'-map','0:v','-map','1:a','-c:v','libx264','-threads','1','-pix_fmt','yuv420p','-c:a','copy',str(asset)],check=True)
   reference=root/'reference.f32'
   subprocess.run([a.ffmpeg,'-v','error','-y','-i',str(asset),'-map','0:a:0','-ac','2','-f','f32le',str(reference)],check=True)
   expected=np.fromfile(reference,dtype='<f4').reshape(-1,2)
   assert len(expected)==96000,(family,channels,len(expected))
   for target in ['0','1','1/7','1999/1000']:
    path=root/'actual.f32'
    command=[a.probe,str(asset),str(path),target]
    run=subprocess.run(command,capture_output=True,text=True,timeout=30)
    if run.returncode==-9:run=subprocess.run(command,capture_output=True,text=True,timeout=30)
    assert run.returncode==0,(family,channels,target,run.stderr)
    value=Fraction(target)*48000;frame=-(-value.numerator//value.denominator)
    actual=np.fromfile(path,dtype='<f4').reshape(-1,2);want=expected[frame:]
    assert actual.shape==want.shape,(family,channels,target,actual.shape,want.shape)
    error=actual.astype('float64')-want
    maximum=float(np.max(abs(error)));rms=float(np.sqrt(np.mean(error**2)))
    assert maximum<2e-6 and rms<2e-7,(family,channels,target,maximum,rms)
    errors={str(lag):float(np.mean((actual[max(lag,0):len(actual)+min(lag,0)]-want[max(-lag,0):len(want)-max(lag,0)])**2)) for lag in [-2,-1,0,1,2]}
    # Silent tails have no unique correlation peak; equality at lag zero still holds.
    best=min(errors,key=errors.get)
    assert errors['0']<=errors[best]+1e-15
    rows.append(dict(family=family,channels=channels,target=target,first_frame=frame,frames=len(actual),maximum_error=maximum,rms=rms,zero_lag_error=errors['0'],lag_errors=errors,log=run.stderr))
result=dict(probe_sha256=hashlib.sha256(pathlib.Path(a.probe).read_bytes()).hexdigest(),cases=rows)
pathlib.Path(a.output).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
