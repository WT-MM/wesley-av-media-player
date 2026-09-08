import pathlib,subprocess,struct,json
r=pathlib.Path('/private/tmp/wam-phase2g/color-fixtures');r.mkdir(exist_ok=True)
commands=[]
def atom(t,b):return struct.pack('>I4s',len(b)+8,t)+b
def ambient(data):
 out=b'';i=0
 while i<len(data):
  n,t=struct.unpack_from('>I4s',data,i);b=data[i+8:i+n]
  if t in (b'moov',b'trak',b'mdia',b'minf',b'stbl'):b=ambient(b)
  elif t==b'stsd':b=b[:8]+ambient(b[8:])
  elif t in (b'avc1',b'hvc1',b'hev1'):b+=atom(b'amve',bytes.fromhex('002fe9a03d134042'))
  out+=atom(t,b);i+=n
 return out
for name,codec,pix,prim,trc,matrix in [('444-601','libx264','yuv444p','smpte170m','bt709','smpte170m'),('444-709','libx264','yuv444p','bt709','bt709','bt709'),('hlg-h264','libx264','yuv420p10le','bt2020','arib-std-b67','bt2020nc'),('hlg-hevc','libx265','yuv420p10le','bt2020','arib-std-b67','bt2020nc'),('pq-h264','libx264','yuv420p10le','bt2020','smpte2084','bt2020nc'),('pq-hevc','libx265','yuv420p10le','bt2020','smpte2084','bt2020nc')]:
 p=r/(name+'.mp4')
 opts=['-x265-params','pools=1:frame-threads=1:log-level=error','-tag:v','hvc1'] if codec=='libx265' else []
 cmd=['ffmpeg','-v','error','-y','-threads','1','-filter_threads','1','-f','lavfi','-i','smptebars=size=640x360:rate=25','-t','4','-vf',f'setparams=color_primaries={prim}:color_trc={trc}:colorspace={matrix}','-c:v',codec,*opts,'-crf','10','-threads','1','-pix_fmt',pix,'-color_range','tv','-color_primaries',prim,'-color_trc',trc,'-colorspace',matrix,str(p)]
 subprocess.run(cmd,check=True);commands.append(cmd)
 if name.startswith('hlg'):(r/(name+'-ambient.mp4')).write_bytes(ambient(p.read_bytes()))
 print(name,flush=True)
(r/'commands.json').write_text(json.dumps(commands,indent=2))
