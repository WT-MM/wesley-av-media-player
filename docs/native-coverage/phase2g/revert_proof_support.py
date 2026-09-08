import subprocess,json,hashlib,pathlib


def create_runner(output):
 repo=pathlib.Path('/private/tmp/wam-cov')
 root=pathlib.Path(output);root.mkdir(exist_ok=True)
 results=[]
 def run(name,cmd):
  with (root/(name+'.log')).open('w') as f:r=subprocess.run(cmd,cwd=repo,stdout=f,stderr=subprocess.STDOUT)
  return r.returncode
 def proof(name,files,tests,mutate=None):
  saved={p:(repo/p).read_bytes() for p in files};row={'name':name,'before':{p:hashlib.sha256(b).hexdigest() for p,b in saved.items()}}
  try:
   if mutate:mutate()
   else:
    for p in files:(repo/p).write_bytes(subprocess.check_output(['git','show','HEAD:'+p],cwd=repo))
   row['reverted_build']=run(name+'-build',['cmake','--build','build','--parallel'])
   row['reverted_tests']={label:run(name+'-'+label,cmd) for label,cmd in tests} if row['reverted_build']==0 else {}
  finally:
   for p,b in saved.items():(repo/p).write_bytes(b)
   row['restored_identically']=all((repo/p).read_bytes()==b for p,b in saved.items())
   row['restored_build']=run(name+'-restore-build',['cmake','--build','build','--parallel'])
   row['restored_tests']={label:run(name+'-restored-'+label,cmd) for label,cmd in tests}
   results.append(row);(root/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(row),flush=True)
 def ct(pattern):return ['ctest','--test-dir','build','--output-on-failure','-R',pattern]
 return proof,ct
