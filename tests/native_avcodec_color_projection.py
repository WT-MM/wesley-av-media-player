"""SD-lane projection statistics on actual display-route grabs and decoder references."""
import argparse,io,json,pathlib,subprocess
import numpy as np
from PIL import Image,ImageCms
p=argparse.ArgumentParser();p.add_argument('--captures',required=True);p.add_argument('--output',required=True);a=p.parse_args()
root=pathlib.Path(a.captures);rows=[]
for name in ['asp','hi10p','h264422']:
 run=root/name;grab=Image.open(run/'display.png').convert('RGB');width,height=grab.size
 image=Image.open(run/'display.png')
 profile=ImageCms.ImageCmsProfile(io.BytesIO(image.info['icc_profile']))
 converted=ImageCms.profileToProfile(image,profile,ImageCms.createProfile('sRGB'),outputMode='RGB')
 references={}
 for label,matrix,range_ in [('correct','bt601','tv'),('wrong_matrix','bt709','tv'),('wrong_range','bt601','pc')]:
  command=['ffmpeg','-v','error','-i',str(run/'bars.mkv'),'-frames:v','1','-vf',f'scale={width}:{height}:in_color_matrix={matrix}:in_range={range_}:out_range=pc','-pix_fmt','rgb24','-f','rawvideo','-']
  raw=subprocess.check_output(command);references[label]=np.frombuffer(raw,dtype=np.uint8).reshape(height,width,3).astype(float)
  Image.fromarray(references[label].astype(np.uint8)).save(run/(label+'.png'))
 correct=references['correct'];mask=np.ones((height,width),dtype=bool)
 mask[:12]=False;mask[-12:]=False;mask[:,:12]=False;mask[:,-12:]=False
 for shift in range(-3,4):
  for axis in [0,1]:mask &= np.max(np.abs(np.roll(correct,shift,axis=axis)-correct),axis=2)<1
 result=dict(name=name,icc_profile=ImageCms.getProfileName(profile).strip(),pixels=int(mask.sum()),tolerance=dict(max_abs_projection=0.15,max_rms_8bit=6.0))
 for label,observed in [('encoded',grab),('srgb',converted)]:
  delta=np.asarray(observed,dtype=float)[mask]-correct[mask]
  projections={}
  for error in ['wrong_matrix','wrong_range']:
   direction=references[error][mask]-correct[mask]
   projections[error]=float(np.sum(delta*direction)/np.sum(direction*direction))
  result[label]=dict(rms=float(np.sqrt(np.mean(delta**2))),projections=projections)
 result['matrix_range_projection_pass']=all(abs(v)<=0.15 for v in result['encoded']['projections'].values()) and result['encoded']['rms']<=6
 rows.append(result)
pathlib.Path(a.output).write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(rows,indent=2))
