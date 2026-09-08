exec(open('/private/tmp/wam-phase2g/generate-color.py').read().split('for name,codec,pix')[0])
for trc,label in [('arib-std-b67','hlg'),('smpte2084','pq')]:
 for control in ['matrix','range']:
  matrix='bt709' if control=='matrix' else 'bt2020nc';ran='pc' if control=='range' else 'tv'
  p=r/(label+'-hevc-wrong-'+control+'.mp4')
  cmd=['ffmpeg','-v','error','-y','-threads','1','-filter_threads','1','-f','lavfi','-i','smptebars=size=640x360:rate=25','-t','4','-vf',f'setparams=color_primaries=bt2020:color_trc={trc}:colorspace={matrix}:range={"full" if ran=="pc" else "limited"}','-c:v','libx265','-x265-params','pools=1:frame-threads=1:log-level=error','-tag:v','hvc1','-crf','10','-threads','1','-pix_fmt','yuv420p10le','-color_range',ran,'-color_primaries','bt2020','-color_trc',trc,'-colorspace',matrix,str(p)]
  subprocess.run(cmd,check=True);commands.append(cmd)
  if label=='hlg':(r/(p.stem+'-ambient.mp4')).write_bytes(ambient(p.read_bytes()))
(r/'control-commands.json').write_text(json.dumps(commands,indent=2))
