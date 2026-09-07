#!/usr/bin/env python3
"""Generate the small synthetic WAMKit proof assets using a local FFmpeg."""
import argparse,hashlib,json,pathlib,subprocess,shutil,tempfile
p=argparse.ArgumentParser();p.add_argument('--ffmpeg',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
output=a.output; scratch=pathlib.Path("/private/tmp/wam-wamkit-scratch");scratch.mkdir(exist_ok=True)
workspace=tempfile.TemporaryDirectory(dir=scratch,prefix="fixtures-");a.output=pathlib.Path(workspace.name)
commands=[['-f','lavfi','-i','testsrc2=size=320x180:rate=25:duration=6','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=6','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-g','25','-bf','2','-c:a','aac','-b:a','96k',str(a.output/'av.mp4')],['-i',str(a.output/'av.mp4'),'-c:v','copy','-c:a','pcm_s16le',str(a.output/'av.mkv')],['-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=2','-ac','2','-c:a','aac_at','-profile:a','4','-b:a','48k',str(a.output/'refused.m4a')]]
for command in commands:subprocess.run([a.ffmpeg,'-v','error','-y',*command],check=True)
for asset in a.output.iterdir():shutil.copy2(asset,output/asset.name)
(output/'manifest.json').write_text(json.dumps({'commands':commands,'assets':{path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in a.output.iterdir() if path.suffix in ('.mp4','.mkv','.m4a')}},indent=2)+'\n')

workspace.cleanup()
