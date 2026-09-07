import subprocess,pathlib,json,shutil
root=pathlib.Path('/private/tmp/wam-wamkit-scratch/defect');counts=0
for i in range(100):
 p=subprocess.run(['ctest','-R','wamkit_host_(mp4|mkv)$','--output-on-failure'],cwd='/private/tmp/wam-wamkit/build',capture_output=True,text=True)
 (root/f'ctest-baseline-{i}.log').write_text(p.stdout+p.stderr)
 for kind in ('mp4','mkv'):
  candidates=list(pathlib.Path('/private/tmp/wam-wamkit-scratch/ctest-host-'+kind).glob('*/result.json'))
  f=max(candidates,key=lambda f:f.stat().st_mtime)
  r=json.loads(f.read_text());out=root/f'original-{i}-{kind}';out.mkdir()
  for src in f.parent.iterdir():
   if src.is_file():shutil.copy2(src,out/src.name)
  r['output']=str(out)
  with (root/'original-receipts.jsonl').open('a') as stream:stream.write(json.dumps(r)+'\n')
  if r['rc']==-5:counts+=1
  for crash in pathlib.Path('/Users/wesleymaa/Library/Logs/DiagnosticReports').glob('WAMKitHost*.ips'):
   try:d=json.loads(crash.read_text().split('\n',1)[1])
   except Exception:continue
   if d.get('pid')==r['pid']:shutil.copy2(crash,out/crash.name)
  print(i,kind,r['errors'],'SIGTRAPs',counts,flush=True)
 if counts>=3:break
