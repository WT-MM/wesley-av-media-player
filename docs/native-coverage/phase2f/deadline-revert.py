from pathlib import Path
import json,subprocess,shlex,hashlib
repo=Path('/Users/wesleymaa/Documents/WAM');root=Path('/private/tmp/wam-phase2f');build=repo/'build';source=repo/'src/platform/macos/native_media_session.mm';saved=source.read_bytes();rows=[]
entry=next(x for x in json.loads((build/'compile_commands.json').read_text()) if x['file']==str(source) and 'wam_native_media_session_test.dir' in x['command'])
compile=shlex.split(entry['command'])
for flag in ['-MD']:
 if flag in compile:compile.remove(flag)
for flag in ['-MT','-MF','-o']:
 if flag in compile:
  i=compile.index(flag);del compile[i:i+2]
compile+=['-o',str(root/'deadline-mutant.o')]
link=shlex.split((root/'deadline-link-command.txt').read_text().strip().removeprefix(': && ').removesuffix(' && :'));i=link.index('-o');link[i+1]=str(root/'deadline-mutant')
i=next(i for i,x in enumerate(link) if x.endswith('/native_media_session.mm.o'));link[i]=str(root/'deadline-mutant.o')
def run(label,binary):
 r=subprocess.run([str(binary)],capture_output=True,text=True);rows.append(dict(phase=label,rc=r.returncode,stdout=r.stdout,stderr=r.stderr,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest()))
run('fixed',build/'wam_native_media_session_test')
try:
 text=saved.decode().replace('  void syncHostPacedDeadlines() noexcept {','  void syncHostPacedDeadlines() noexcept {\n    if (silentTimebase == nullptr) return;',1);source.write_text(text)
 subprocess.run(compile,cwd=build,check=True,capture_output=True)
 subprocess.run(link,cwd=build,check=True,capture_output=True)
 run('reverted',root/'deadline-mutant')
finally:source.write_bytes(saved)
run('restored',build/'wam_native_media_session_test')
(root/'deadline-revert-proof.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
assert rows[0]['rc']==0 and rows[1]['rc']!=0 and rows[2]['rc']==0 and rows[0]['source_sha256']==rows[2]['source_sha256']
