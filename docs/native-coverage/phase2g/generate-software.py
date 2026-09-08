import pathlib,subprocess,json
r=pathlib.Path('/private/tmp/wam-phase2g/software-fixtures');r.mkdir(exist_ok=True);rows=[]
for ran in ['limited','full']:
 for name,opts in [('baseline',['-c:v','libx264','-pix_fmt','yuv420p']),('asp',['-c:v','mpeg4','-bf','2']),('hi10p',['-c:v','libx264','-profile:v','high10','-pix_fmt','yuv420p10le']),('h264422',['-c:v','libx264','-profile:v','high422','-pix_fmt','yuv422p10le']),('vp9',['-c:v','libvpx-vp9','-pix_fmt','yuv420p']),('vp9p2',['-c:v','libvpx-vp9','-profile:v','2','-pix_fmt','yuv420p10le'])]:
  p=r/(ran+'-'+name+'.mkv')
  cmd=['ffmpeg','-v','error','-y','-threads','1','-filter_threads','1','-f','lavfi','-i','smptebars=size=640x360:rate=25','-t','4',*(['-vf','scale=in_range=tv:out_range=pc'] if ran=='full' else []),*opts,'-threads','1','-color_range','pc' if ran=='full' else 'tv','-color_primaries','smpte170m','-color_trc','bt709','-colorspace','smpte170m',str(p)]
  subprocess.run(cmd,check=True);rows.append(cmd)
(r/'commands.json').write_text(json.dumps(rows,indent=2))
