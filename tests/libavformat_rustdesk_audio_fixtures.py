"""Mux exact-duration 48 kHz Opus beside each retained RustDesk video without re-encoding video."""
import argparse,hashlib,json,pathlib,subprocess
from fractions import Fraction
p=argparse.ArgumentParser();p.add_argument('--manifest',required=True);p.add_argument('--output',required=True);a=p.parse_args();root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True);rows=[]
for index,item in enumerate(json.loads(pathlib.Path(a.manifest).read_text())):
 source=pathlib.Path(item['path']);info=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_streams','-show_packets','-of','json',str(source)]))
 tb=Fraction(info['streams'][0]['time_base']);end=max((Fraction(x['pts']+x['duration'])*tb for x in info['packets']))
 frames=end*48000;assert frames.denominator==1
 duration=f'{end.numerator//end.denominator}.{(end*1000000).numerator//(end*1000000).denominator%1000000:06d}'
 assert Fraction(duration)==end
 asset=root/(str(index)+'-opus.mkv')
 command=['ffmpeg','-v','error','-y','-i',str(source),'-f','lavfi','-i','sine=frequency=513:sample_rate=48000','-map','0:v:0','-map','1:a:0','-c:v','copy','-c:a','libopus','-b:a','64k','-application','lowdelay','-vbr','off','-t',duration,str(asset)]
 subprocess.run(command,check=True)
 rows.append(dict(source=str(source),source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),asset=str(asset),asset_sha256=hashlib.sha256(asset.read_bytes()).hexdigest(),video_packets=len(info['packets']),duration=str(end),audio_frames=int(frames),command=command))
 (root/'manifest.json').write_text(json.dumps(rows,indent=2)+'\n');print(index,len(info['packets']),int(frames),flush=True)
