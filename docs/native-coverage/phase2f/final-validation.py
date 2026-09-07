from pathlib import Path
import subprocess,re,json,hashlib,shutil
repo=Path('/Users/wesleymaa/Documents/WAM');root=Path('/private/tmp/wam-phase2f')
def run(args,name,cwd=repo):
 print(name,flush=True)
 with (root/name).open('w') as log:r=subprocess.run(args,cwd=cwd,stdout=log,stderr=subprocess.STDOUT)
 return r.returncode
assert run(['cmake','-S','.','-B','build','-DWAM_ENABLE_AVFORMAT_STAGE=ON','-DWAM_ENABLE_AVCODEC_STAGE=OFF'],'configure-shipped-final.txt')==0
removed=[]
for i in range(30):
 name=f'build-shipped-final-{i}.txt';rc=run(['cmake','--build','build','--parallel'],name)
 if rc==0:break
 match=re.search(r"ninja: error: loading '([^']+\.d)': Operation timed out",(root/name).read_text())
 assert match,(root/name).read_text()[-2000:]
 p=Path(match[1]);assert str(p).startswith(str(repo/'build/CMakeFiles/d/'));p.unlink(missing_ok=True);removed.append(str(p))
assert rc==0
app=repo/'build/WAM.app/Contents/MacOS/WAM';candidate=hashlib.sha256(app.read_bytes()).hexdigest()
(root/'shipped-final-build.json').write_text(json.dumps(dict(candidate_sha256=candidate,AVFORMAT='ON',AVCODEC='OFF',removed_dependency_files=removed,build_log=name),indent=2))
rc=run(['ctest','--output-on-failure'],'ctest-shipped-final.txt',repo/'build')
if rc:rc=run(['ctest','--output-on-failure','--rerun-failed'],'ctest-shipped-final-rerun.txt',repo/'build')
assert rc==0,'CTest still fails; stop before sampling'
(root/'package/WAM.app/Contents/MacOS/symbol-probe').unlink(missing_ok=True)
assert run(['python3',str(root/'refresh-package.py')],'packaging-final.txt')==0
assert run(['python3',str(root/'run-measurements-final.py')],'measurements-final.txt')==0
assert run(['python3',str(root/'corpus.py'),'--corpus','/private/tmp/claude-501/-Users-wesleymaa/1ac13550-c663-43bd-83a6-6c57feb52da1/scratchpad/mp4_corpus.txt','--output',str(root/'corpus-final')],'corpus-final.txt')==0
assert hashlib.sha256(app.read_bytes()).hexdigest()==candidate
print('Final validation complete',flush=True)
