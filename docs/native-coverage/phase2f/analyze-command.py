from pathlib import Path
import json,subprocess,io
import numpy as np
from PIL import Image,ImageCms
r=Path('/private/tmp/wam-phase2f');out=r/'software-sdr';out.mkdir(exist_ok=True)
for row in json.loads((r/'paired-software/results.json').read_text()):
 name=row['name'];run=r/'paired-software'/name
 if not name.startswith(('limited-','full-')):continue
 text=(run/'log.txt').read_text()
 if 'stage=Libavcodec' not in text or 'WAM: native failure' in text or 'first_frame_drawn' not in text:continue
 d=out/name;d.mkdir(exist_ok=True)
 for filename,target in [('bars.mkv',Path(row['asset'])),('display.png',run/'display.png')]:
  p=d/filename
  if not p.exists():p.symlink_to(target)
subprocess.run(['python3','tests/native_avcodec_color_projection.py','--captures',str(out),'--output',str(r/'software-sdr-projections.json')])
rows=[]
for row in json.loads((r/'paired-software/results.json').read_text()):
 name=row['name'];soft=r/'paired-software'/name/'display.png'
 hard=r/'paired-hardware'/name/'display.png'
 if name.startswith('h264-'):hard=r/'paired-hdr-hardware'/name.replace('h264-','hevc-')/'display.png'
 if not soft.exists() or not hard.exists():continue
 def managed(p):
  im=Image.open(p);profile=ImageCms.ImageCmsProfile(io.BytesIO(im.info['icc_profile']));return np.asarray(ImageCms.profileToProfile(im,profile,ImageCms.createProfile('sRGB'),outputMode='RGB'),dtype=float)
 a,b=managed(soft),managed(hard)
 if a.shape!=b.shape:continue
 mask=np.ones(a.shape[:2],dtype=bool);mask[:12]=False;mask[-12:]=False;mask[:,:12]=False;mask[:,-12:]=False
 for axis in [0,1]:
  for shift in range(-3,4):mask &= np.max(np.abs(np.roll(b,shift,axis=axis)-b),axis=2)<2
 rows.append(dict(name=name,software=str(soft),hardware=str(hard),pixels=int(mask.sum()),rms=float(np.sqrt(np.mean((a[mask]-b[mask])**2))),software_route=[l for l in row['diagnostics'] if 'decoder stage=' in l],failures=[l for l in row['diagnostics'] if 'native failure' in l]))
(r/'paired-rms.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
