"""The unqualified uniform-block Vorbis control must refuse before PCM publication."""
import argparse,hashlib,json,pathlib,subprocess,tempfile
p=argparse.ArgumentParser();p.add_argument('--probe',required=True);p.add_argument('--ffmpeg',required=True);p.add_argument('--output',required=True);a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='wam-vorbis-refusal-',dir='/private/tmp') as tmp:
 root=pathlib.Path(tmp);asset=root/'uniform.ogg';pcm=root/'actual.f32'
 command=[a.ffmpeg,'-v','error','-y','-f','lavfi','-i','aevalsrc=0.2*sin(2*PI*(200*t+100*t*t))|0.1*sin(2*PI*700*t):s=48000:d=2','-c:a','vorbis','-strict','-2',str(asset)]
 subprocess.run(command,check=True)
 result=subprocess.run([a.probe,str(asset),str(pcm),'0'],capture_output=True,text=True,timeout=30)
 if result.returncode==-9:result=subprocess.run([a.probe,str(asset),str(pcm),'0'],capture_output=True,text=True,timeout=30)
 assert result.returncode!=0 and 'LibavformatAudioTimingUnproven: vorbis' in result.stderr,result
 assert not pcm.exists() or pcm.stat().st_size==0
 row=dict(command=command,asset_sha256=hashlib.sha256(asset.read_bytes()).hexdigest(),rc=result.returncode,stderr=result.stderr,pcm_bytes=0)
 pathlib.Path(a.output).write_text(json.dumps(row,indent=2)+'\n');print(json.dumps(row,indent=2))
