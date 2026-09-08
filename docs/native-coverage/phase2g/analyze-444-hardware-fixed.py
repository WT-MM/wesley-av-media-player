from pathlib import Path
import json,io
import numpy as np
from PIL import Image,ImageCms
r=Path('/private/tmp/wam-phase2g/captures/corrected-hardware')
def managed(name):
 im=Image.open((Path('/private/tmp/wam-phase2g/captures/sdr-fixed') if name.startswith('sdr-') else r)/name/'display.png');return np.asarray(ImageCms.profileToProfile(im,ImageCms.ImageCmsProfile(io.BytesIO(im.info['icc_profile'])),ImageCms.createProfile('sRGB'),outputMode='RGB'),dtype=float)
rows=[]
for family in ['601','709']:
 for unused in [0]:
  label=family; suffix=''
  names=['sdr-'+family+'-correct','444-'+family,'sdr-'+family+'-matrix','sdr-'+family+'-range']
  if any(not ((Path('/private/tmp/wam-phase2g/captures/sdr-fixed') if n.startswith('sdr-') else r)/n/'display.png').exists() for n in names):continue
  correct,observed,wm,wr=map(managed,names)
  mask=np.ones(correct.shape[:2],dtype=bool);mask[:12]=False;mask[-12:]=False;mask[:,:12]=False;mask[:,-12:]=False
  for shift in range(-3,4):
   for axis in [0,1]: mask&=np.max(np.abs(np.roll(correct,shift,axis=axis)-correct),axis=2)<2
  delta=observed[mask]-correct[mask];proj={}
  for k,wrong in [('matrix',wm),('range',wr)]:
   d=wrong[mask]-correct[mask];den=float(np.sum(d*d));proj[k]=float(np.sum(delta*d)/den) if den else None
  rms=float(np.sqrt(np.mean(delta*delta)));rows.append(dict(name=label+suffix,names=names,pixels=int(mask.sum()),rms=rms,projections=proj,pass_=rms<=6 and all(v is not None and abs(v)<=.15 for v in proj.values())))
Path('/private/tmp/wam-phase2g/444-hardware-projections.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
