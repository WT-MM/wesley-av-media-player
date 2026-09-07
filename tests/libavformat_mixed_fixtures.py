"""Bounded mixed-stream specimens and unqualified audio-mode controls."""
import argparse,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--ffmpeg',required=True);a=p.parse_args();root=pathlib.Path(a.root);root.mkdir(parents=True,exist_ok=True)
base=[a.ffmpeg,'-v','error','-y','-f','lavfi','-i','testsrc2=size=160x96:rate=25:duration=2','-f','lavfi','-i','sine=frequency=513:sample_rate=48000:duration=2']
for name,options in [('mixed-fragmented.mp4',['-c:v','libx264','-bf','0','-c:a','aac','-movflags','empty_moov+frag_keyframe']),('mixed.flv',['-c:v','libx264','-bf','0','-c:a','aac']),('positive-aac.flv',['-c:v','libx264','-bf','0','-c:a','aac','-af','asetpts=PTS+4096']),('mixed-opus.mkv',['-c:v','libx265','-x265-params','log-level=error:pools=1:frame-threads=1:bframes=0','-c:a','libopus','-application','lowdelay','-b:a','64k','-vbr','off']),('mixed-hybrid.mkv',['-c:v','libx265','-x265-params','log-level=error:pools=1:frame-threads=1:bframes=0','-c:a','libopus','-b:a','32k','-vbr','off'])]:
 command=base+options
 if name in ['mixed-fragmented.mp4','mixed.flv']:
  command=[x.replace('rate=25:duration=2','rate=25:duration=1.92') for x in command]
  command+=['-af','atrim=end_sample=91136,asetpts=PTS+1024']
  if name.endswith('.mp4'):command+=['-video_track_timescale','48000']
 subprocess.run(command+[str(root/name)],check=True)
