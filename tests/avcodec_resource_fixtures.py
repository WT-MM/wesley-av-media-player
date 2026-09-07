"""Small 1080p/4K decoder-memory specimens; no raw-video intermediates."""
import argparse, json, pathlib, struct, subprocess
p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--binary',required=True);a=p.parse_args()
root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
rows=[]
for name,codec,options in [('asp','mpeg4',['-c:v','mpeg4','-bf','2']),('hi10p','h264',['-c:v','libx264','-profile:v','high10','-pix_fmt','yuv420p10le','-bf','2'])]:
 for width,height in [(1920,1080),(3840,2160)]:
  stem=f'{name}-{height}';asset=root/(stem+'.mkv')
  command=['ffmpeg','-v','error','-y','-f','lavfi','-i',f'testsrc2=size={width}x{height}:rate=25','-frames:v','10',*options,str(asset)]
  subprocess.run(command,check=True)
  info=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_packets','-show_data','-of','json',str(asset)]))
  def data(text):return bytes.fromhex(''.join(line.split(':',1)[1].split('  ')[0].replace(' ','') for line in text.splitlines() if ':' in line))
  extra=data(info['streams'][0].get('extradata',''))
  archive=bytearray(struct.pack('<II',len(extra),len(info['packets'])))+extra
  for packet in info['packets']:
   payload=data(packet['data']);archive+=struct.pack('<Iqqq',len(payload),int(packet['pts']),int(packet.get('dts',-(2**63))),int(packet['duration']))+payload
  packets=root/(stem+'.packets');packets.write_bytes(archive)
  r=subprocess.run([a.binary,str(packets),codec,str(width),str(height)],capture_output=True,text=True,timeout=20)
  if r.returncode==-9:r=subprocess.run([a.binary,str(packets),codec,str(width),str(height)],capture_output=True,text=True,timeout=20)
  rows.append(dict(name=stem,argv=command,rc=r.returncode,stdout=r.stdout,stderr=r.stderr))
  (root/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
  assert r.returncode==0,rows[-1]
  print(stem,r.stdout,flush=True)
