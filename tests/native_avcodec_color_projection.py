"""SD-lane projection statistics on actual display-route grabs and decoder references."""
import argparse,io,json,pathlib,subprocess
import numpy as np
from PIL import Image,ImageCms
p=argparse.ArgumentParser();p.add_argument('--captures',required=True);p.add_argument('--output',required=True);a=p.parse_args()
root=pathlib.Path(a.captures);rows=[]
# FFmpeg scale emits nonlinear source-primary RGB, not sRGB. The display grab
# is device-ICC RGB. Both must meet in linear-light BT.709 primaries, then sRGB.
def source_rgb_to_srgb(rgb):
 def primary_matrix(points):
  xy=np.asarray(points,dtype=float)
  xyz=np.array([xy[:,0]/xy[:,1],np.ones(3),(1-xy[:,0]-xy[:,1])/xy[:,1]])
  white=np.array([.3127/.329,1,(1-.3127-.329)/.329])
  return xyz @ np.diag(np.linalg.solve(xyz,white))
 source=primary_matrix([[.630,.340],[.310,.595],[.155,.070]])
 destination=primary_matrix([[.640,.330],[.300,.600],[.150,.060]])
 nonlinear=rgb/255
 linear=np.where(nonlinear<.081,nonlinear/4.5,((nonlinear+.099)/1.099)**(1/.45))
 target=np.maximum(linear @ (np.linalg.inv(destination) @ source).T,0)
 return np.clip(255*np.where(target<=.0031308,12.92*target,1.055*target**(1/2.4)-.055),0,255)

for run in sorted(root.iterdir()):
 if not run.is_dir() or not (run/'display.png').exists():continue
 name=run.name
 grab=Image.open(run/'display.png').convert('RGB');width,height=grab.size
 if np.ptp(np.asarray(grab))<32:
  rows.append(dict(name=name,measurement_valid=False,refusal='DisplayCaptureNoSignal',matrix_range_projection_pass=False));continue
 image=Image.open(run/'display.png')
 profile=ImageCms.ImageCmsProfile(io.BytesIO(image.info['icc_profile']))
 converted=ImageCms.profileToProfile(image,profile,ImageCms.createProfile('sRGB'),outputMode='RGB')
 facts=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_streams','-of','json',str(run/'bars.mkv')]))['streams'][0]
 if facts.get('color_primaries', 'smpte170m' if facts['width']<=704 else '')!='smpte170m' or facts.get('color_transfer','bt709')!='bt709':
  raise SystemExit('DisplayReferenceColorContractUnqualified: '+name)
 input_range='pc' if facts.get('color_range')=='pc' else 'tv'
 wrong_range='tv' if input_range=='pc' else 'pc'
 references={}
 for label,matrix,range_ in [('correct','bt601',input_range),('wrong_matrix','bt709',input_range),('wrong_range','bt601',wrong_range)]:
  command=['ffmpeg','-v','error','-threads','1','-filter_threads','1','-i',str(run/'bars.mkv'),'-frames:v','1','-vf',f'scale={width}:{height}:in_color_matrix={matrix}:in_range={range_}:out_range=pc','-pix_fmt','rgb24','-f','rawvideo','-']
  raw=subprocess.check_output(command);references[label]=np.frombuffer(raw,dtype=np.uint8).reshape(height,width,3).astype(float)
  Image.fromarray(references[label].astype(np.uint8)).save(run/(label+'.png'))
 correct=references['correct'];mask=np.ones((height,width),dtype=bool)
 mask[:12]=False;mask[-12:]=False;mask[:,:12]=False;mask[:,-12:]=False
 for shift in range(-3,4):
  for axis in [0,1]:mask &= np.max(np.abs(np.roll(correct,shift,axis=axis)-correct),axis=2)<1
 result=dict(name=name,measurement_valid=True,source_range=input_range,icc_profile=ImageCms.getProfileName(profile).strip(),pixels=int(mask.sum()),tolerance=dict(max_abs_projection=0.15,max_rms_8bit=6.0))
 managed={key:source_rgb_to_srgb(value) for key,value in references.items()}
 for label,observed in [('encoded',grab),('srgb',converted)]:
  reference_set=managed if label=='srgb' else references
  correct=reference_set['correct']
  delta=np.asarray(observed,dtype=float)[mask]-correct[mask]
  projections={}
  for error in ['wrong_matrix','wrong_range']:
   direction=reference_set[error][mask]-correct[mask]
   denominator=float(np.sum(direction*direction))
   if denominator==0:raise SystemExit('DisplayReferenceControlsDegenerate: '+name+' '+error)
   projections[error]=float(np.sum(delta*direction)/denominator)
  result[label]=dict(rms=float(np.sqrt(np.mean(delta**2))),projections=projections)
 result['matrix_range_projection_pass']=all(abs(v)<=0.15 for v in result['srgb']['projections'].values()) and result['srgb']['rms']<=6
 rows.append(result)
pathlib.Path(a.output).write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(rows,indent=2))

if not rows or not all(row['matrix_range_projection_pass'] for row in rows):raise SystemExit(2)
