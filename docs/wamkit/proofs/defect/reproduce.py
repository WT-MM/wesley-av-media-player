import subprocess,pathlib,json,shutil,time
root=pathlib.Path('/private/tmp/wam-wamkit-scratch/defect');counts={'A':0,'B':0}
for i in range(150):
 for kind in ('mp4','mkv'):
  out=root/f'baseline-{i}-{kind}'
  p=subprocess.run(['python3','/private/tmp/wam-wamkit/tests/wamkit_embedding_test.py','--host','/private/tmp/wam-wamkit/build/examples/WAMKitHost/WAMKitHost.app/Contents/MacOS/WAMKitHost','--asset',f'/private/tmp/wam-wamkit/test-media/wamkit/av.{kind}','--output',str(out),'--seek'],capture_output=True,text=True)
  (out/'harness.txt').write_text(p.stdout+p.stderr)
  r=json.loads((out/'result.json').read_text());r['output']=str(out)
  mode='B' if r['rc']==-5 else 'A' if r['rc']==0 and 'clock is not 1.0000' in r['errors'] else None
  if mode:counts[mode]+=1
  with (root/'baseline-receipts.jsonl').open('a') as f:f.write(json.dumps(r)+'\n')
  for crash in pathlib.Path('/Users/wesleymaa/Library/Logs/DiagnosticReports').glob('WAMKitHost*.ips'):
   try:d=json.loads(crash.read_text().split('\n',1)[1])
   except Exception:continue
   if d.get('pid')==r['pid']:shutil.copy2(crash,out/crash.name)
  shutil.rmtree(out/'home')
  print(i,kind,r['errors'],counts,flush=True)
 if min(counts.values())>=3:break
