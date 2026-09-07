import subprocess,pathlib,json,shutil
repo=pathlib.Path('/private/tmp/wam-wamkit');root=pathlib.Path('/private/tmp/wam-wamkit-scratch/defect/proof')
with (root/'full-3.log').open('w') as log:
 p=subprocess.run(['ctest','--output-on-failure'],cwd=repo/'build',stdout=log,stderr=subprocess.STDOUT)
print('full 3',p.returncode,flush=True)
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
