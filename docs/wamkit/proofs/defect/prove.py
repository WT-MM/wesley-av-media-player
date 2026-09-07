import subprocess,pathlib,json,shutil
root=pathlib.Path('/private/tmp/wam-wamkit-scratch/defect/proof');root.mkdir(exist_ok=True)
repo=pathlib.Path('/private/tmp/wam-wamkit')
for i in range(30):
 for kind in ('mp4','mkv','refusal','api'):
  p=subprocess.run(['ctest','-R',f'^wamkit_host_{kind}$','--output-on-failure'],cwd=repo/'build',capture_output=True,text=True)
  out=root/f'{i:02}-{kind}';out.mkdir();(out/'ctest.log').write_text(p.stdout+p.stderr)
  receipt=max(pathlib.Path('/private/tmp/wam-wamkit-scratch/ctest-host-'+kind).glob('*/result.json'),key=lambda p:p.stat().st_mtime)
  for f in receipt.parent.iterdir():
   if f.is_file():shutil.copy2(f,out/f.name)
  r=json.loads(receipt.read_text());r.update(iteration=i+1,test='wamkit_host_'+kind,ctest_rc=p.returncode,output=str(out))
  with (root/'receipts.jsonl').open('a') as f:f.write(json.dumps(r)+'\n')
  shutil.rmtree(receipt.parent/'home',ignore_errors=True)
  print(i+1,kind,r['passed'],r['errors'],flush=True)
  if not r['passed'] or p.returncode:raise SystemExit(1)
for i in (1,2):
 with (root/f'full-{i}.log').open('w') as log:p=subprocess.run(['ctest','--output-on-failure'],cwd=repo/'build',stdout=log,stderr=subprocess.STDOUT)
 print('full',i,p.returncode,flush=True)
 if p.returncode:raise SystemExit(1)
relocated=repo/'build/wamkit-defect-relocated/WAMKitHost.app'
subprocess.run(['ditto',str(repo/'build/examples/WAMKitHost/WAMKitHost.app'),str(relocated)],check=True)
for i in range(10):
 out=root/f'relocated-{i+1:02}'
 p=subprocess.run(['python3',str(repo/'tests/wamkit_embedding_test.py'),'--host',str(relocated/'Contents/MacOS/WAMKitHost'),'--asset',str(repo/'test-media/wamkit/av.mkv'),'--output',str(out),'--seek'],capture_output=True,text=True)
 (out/'harness.log').write_text(p.stdout+p.stderr);r=json.loads((out/'result.json').read_text())
 with (root/'relocated-receipts.jsonl').open('a') as f:f.write(json.dumps(r)+'\n')
 shutil.rmtree(out/'home',ignore_errors=True)
 print('relocated',i+1,r['passed'],flush=True)
 if p.returncode:raise SystemExit(1)
p=subprocess.run(['python3',str(repo/'scripts/wamkit_replays.py'),'--output',str(root/'replays')]);raise SystemExit(p.returncode)
