import pathlib,subprocess,json
r=pathlib.Path('/private/tmp/wam-phase2g/sdr-fixed-fixtures');r.mkdir(exist_ok=True);rows=[]
for family,prim,matrix in [('601','smpte170m','smpte170m'),('709','bt709','bt709')]:
 for c in ['correct','matrix','range']:
  m=('bt709' if matrix=='smpte170m' else 'smpte170m') if c=='matrix' else matrix;ran='pc' if c=='range' else 'tv';p=r/('sdr-'+family+'-'+c+'.mp4')
  cmd=['ffmpeg','-v','error','-y','-threads','1','-filter_threads','1','-f','lavfi','-i','smptebars=size=640x360:rate=25','-t','4','-vf',f'setparams=color_primaries={prim}:color_trc=bt709:colorspace={m}:range={"full" if ran=="pc" else "limited"}','-c:v','libx264','-crf','10','-threads','1','-pix_fmt','yuv420p','-color_range',ran,'-color_primaries',prim,'-color_trc','bt709','-colorspace',m,str(p)]
  subprocess.run(cmd,check=True);rows.append(cmd)
(r/'sdr-control-commands.json').write_text(json.dumps(rows,indent=2))
