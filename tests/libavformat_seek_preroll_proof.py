"""Late seeks on the libavformat route decode a bounded preroll, not the whole file."""
import argparse,pathlib,re,subprocess,tempfile
import numpy as np
p=argparse.ArgumentParser()
for name in ['routed-probe','direct-probe','ffmpeg','scratch']:p.add_argument('--'+name,required=True)
a=p.parse_args()
seconds,target=60,55
audio=['-f','lavfi','-t',str(seconds),'-i','aevalsrc=0.2*sin(2*PI*(200+100*mod(t\\,7))*t):s=48000:c=stereo']
video=['-f','lavfi','-t',str(seconds),'-i','color=c=gray:s=64x64:r=5']
opus=['-c:a','libopus','-application','lowdelay','-b:a','64k']
avc=['-c:v','libx264','-bf','0','-g','10']
specimens={'aac.flv':(video+audio+avc+['-c:a','aac'],'routed'),
  'aac-fragmented.m4a':(audio+['-c:a','aac','-movflags','empty_moov+frag_keyframe'],'routed'),
  'opus.ogg':(audio+opus,'routed'),'opus.mp4':(audio+opus,'routed'),
  'hevc-opus.mkv':(video+audio+['-c:v','libx265','-x265-params','log-level=error:bframes=0']+opus,'direct')}
def run(argv):
  r=subprocess.run(list(map(str,argv)),capture_output=True,text=True,timeout=120)
  assert r.returncode==0,(argv,r.stderr);return r
with tempfile.TemporaryDirectory(prefix='seek-preroll-',dir=a.scratch) as tmp:
  root=pathlib.Path(tmp)
  for name,(options,route) in specimens.items():
    media=root/name;run([a.ffmpeg,'-v','error','-y',*options,media])
    probe=a.routed_probe if route=='routed' else a.direct_probe
    whole=run([probe,media,root/'whole.f32','0']);seek=run([probe,media,root/'seek.f32',target])
    assert route=='direct' or 'stage=Libavformat' in seek.stderr,(name,seek.stderr)
    assert 'exact=1 drained=1' in seek.stderr,(name,seek.stderr)
    # A container seek may land up to one Ogg page (about a second) early.
    trim=int(re.search(r'\btrim=(\d+)',seek.stderr).group(1))
    assert trim<2*48000,(name,'seek decoded from too far back',seek.stderr)
    full=np.fromfile(root/'whole.f32',dtype='<f4').reshape(-1,2)
    part=np.fromfile(root/'seek.f32',dtype='<f4').reshape(-1,2)
    first=target*48000
    # Decoder state after a bounded preroll is not bit-identical to an origin
    # decode; the other routes' lossy seek proofs hold it to the same bound.
    assert len(part)==len(full)-first and np.max(np.abs(full[first:]-part))<.002,(name,seek.stderr)
    print(name,'trim',trim,'max',float(np.max(np.abs(full[first:]-part))))
