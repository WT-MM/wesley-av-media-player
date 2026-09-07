from pathlib import Path
import json,subprocess,shlex,hashlib
repo=Path('/Users/wesleymaa/Documents/WAM');root=Path('/private/tmp/wam-phase2f');build=repo/'build';rows=[]
entries=json.loads((build/'compile_commands.json').read_text())
base=shlex.split((root/'coexistence-link-command.txt').read_text().strip().removeprefix(': && ').removesuffix(' && :'))
args=[str(build/'WAMMpvFallback.dylib')]
def run(label,binary,source):
 r=subprocess.run([str(binary)]+args,capture_output=True,text=True);rows.append(dict(phase=label,rc=r.returncode,stdout=r.stdout,stderr=r.stderr,source=str(source.relative_to(repo)),source_sha256=hashlib.sha256(source.read_bytes()).hexdigest()))
for relative,archive in [('src/media/avcodec/runtime.cpp','libwam_avcodec_worker.a'),('src/playback/mpv/mpv_runtime.cpp','libwam_mpv_runtime.a')]:
 source=repo/relative;saved=source.read_bytes();run('fixed',build/'wam_ffmpeg_coexistence_test',source)
 try:
  source.write_bytes(subprocess.check_output(['git','show','HEAD:'+relative],cwd=repo))
  entry=next(x for x in entries if x['file']==str(source));compile=shlex.split(entry['command'])
  if '-MD' in compile:compile.remove('-MD')
  for flag in ['-MT','-MF','-o']:
   if flag in compile:
    i=compile.index(flag);del compile[i:i+2]
  obj=root/(source.stem+'-mutant.o');compile+=['-o',str(obj)]
  subprocess.run(compile,cwd=build,check=True,capture_output=True)
  link=base.copy();i=link.index('-o');binary=root/(source.stem+'-mutant');link[i+1]=str(binary);link.insert(link.index(archive),str(obj))
  subprocess.run(link,cwd=build,check=True,capture_output=True);run('reverted',binary,source)
 finally:source.write_bytes(saved)
 run('restored',build/'wam_ffmpeg_coexistence_test',source)
(root/'coexistence-revert-proof.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
assert [x['rc'] for x in rows]==[0,1,0,0,1,0]
assert rows[0]['source_sha256']==rows[2]['source_sha256'] and rows[3]['source_sha256']==rows[5]['source_sha256']
