"""Small offline demux fixtures, with exact generation argv and asset hashes."""
import argparse,hashlib,json,pathlib,subprocess,struct
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--ffmpeg',required=True);a=p.parse_args()
root=pathlib.Path(a.root);root.mkdir(parents=True,exist_ok=True);rows=[]
def generate(name,args):
 path=root/name
 command=[a.ffmpeg,'-hide_banner','-loglevel','error','-y',*args,'-fflags','+bitexact',str(path)]
 subprocess.run(command,check=True,timeout=40)
 rows.append(dict(path=str(path),argv=command,sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
video=['-f','lavfi','-i','testsrc2=size=160x96:rate=25','-t','3']
h264=['-c:v','libx264','-g','25','-bf','0','-pix_fmt','yuv420p']
generate('fragmented.mp4',video+h264+['-an','-movflags','+frag_keyframe+empty_moov+default_base_moof'])
generate('asp.avi',video+['-c:v','mpeg4','-bf','0','-flags','+qpel','-q:v','4','-an'])
generate('reordered-asp.avi',video+['-c:v','mpeg4','-bf','2','-q:v','4','-an'])
generate('oracle.mkv',video+h264+['-an'])
generate('oracle.ts',video+h264+['-an','-muxdelay','0'])
audio=['-f','lavfi','-i','testsrc2=size=160x96:rate=25','-f','lavfi','-i','aevalsrc=0.2*sin(2*PI*(200*t+100*t*t)):s=48000','-t','3']
generate('h264-aac.flv',audio+h264+['-c:a','aac'])
generate('legacy.asf',audio+['-c:v','wmv2','-c:a','wmav2'])
generate('program.vob',audio+['-c:v','mpeg2video','-c:a','ac3','-f','vob'])
generate('vorbis.ogg',['-f','lavfi','-i','aevalsrc=0.2*sin(2*PI*(200*t+100*t*t)):s=48000','-t','3','-ac','2','-c:a','vorbis','-strict','-2'])
generate('opus.ogg',['-f','lavfi','-i','aevalsrc=0.2*sin(2*PI*(200*t+100*t*t)):s=48000','-t','3','-c:a','libopus'])
data=(root/'fragmented.mp4').read_bytes();boxes=[];offset=0
while offset<len(data):
 size,kind=struct.unpack_from('>I4s',data,offset)
 assert size>=8
 boxes.append((offset,size,kind));offset+=size
moofs=[box for box in boxes if box[2]==b'moof'];last=moofs[-1][0]
variants={'boundary.mp4':data[:last],'mid-moof.mp4':data[:last+12],
 'mid-mdat.mp4':data[:next(o+s//2 for o,s,k in boxes if o>last and k==b'mdat')],
 'missing-init.mp4':b''.join(data[o:o+s] for o,s,k in boxes if k!=b'moov')}
for name,content in variants.items():
 (root/name).write_bytes(content);rows.append(dict(path=str(root/name),source='fragmented.mp4',sha256=hashlib.sha256(content).hexdigest(),bytes=len(content)))
(root/'manifest.json').write_text(json.dumps(rows,indent=2)+'\n')

def vint(data,offset,keep_marker=False):
 first=data[offset];width=1
 while not first & (1 << (8-width)):width+=1
 value=int.from_bytes(data[offset:offset+width],'big')
 return (value if keep_marker else value & ((1 << (7*width))-1)),width

def element(identity,payload):
 raw=identity.to_bytes((identity.bit_length()+7)//8,'big')
 width=next(n for n in range(1,9) if len(payload)<(1 << (7*n))-1)
 return raw+((1 << (7*width))|len(payload)).to_bytes(width,'big')+payload

def strip_headers(data,parent=0):
 out=bytearray();offset=0
 while offset<len(data):
  identity,iw=vint(data,offset,True);size,sw=vint(data,offset+iw);start=offset+iw+sw
  if size==(1 << (7*sw))-1:size=len(data)-start
  payload=data[start:start+size];offset=start+size
  if identity in (0x114d9b74,0x1c53bb6b,0xbf):continue
  if identity in (0x18538067,0x1654ae6b,0xae,0x1f43b675,0xa0):payload=strip_headers(payload,identity)
  if identity==0xae:
   compression=element(0x5034,element(0x4254,b'\x03')+element(0x4255,b'\x00'))
   payload+=element(0x6d80,element(0x6240,compression))
  if identity in (0xa3,0xa1):
   track,tw=vint(payload,0)
   assert track==1 and payload[tw+3]==0
   payload=payload[:tw+3]+payload[tw+4:]
  out+=element(identity,payload)
 return bytes(out)
compressed=strip_headers((root/'oracle.mkv').read_bytes())
(root/'header-stripped.mkv').write_bytes(compressed)
rows.append(dict(path=str(root/'header-stripped.mkv'),source='oracle.mkv',transform='Matroska header stripping algorithm 3, one zero byte per block; remove stale indexes and CRCs',sha256=hashlib.sha256(compressed).hexdigest()))
(root/'manifest.json').write_text(json.dumps(rows,indent=2)+'\n')
