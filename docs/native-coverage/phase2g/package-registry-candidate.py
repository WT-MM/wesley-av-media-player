from pathlib import Path
import subprocess,shutil,json,hashlib
build=Path('/private/tmp/wam-cov/build/WAM.app');stage=Path('/private/tmp/wam-phase2g/package/WAM.app')
for rel in ['Contents/MacOS/WAM','Contents/Info.plist']:
 shutil.copy2(build/rel,stage/rel)
for p in (build/'Contents/Frameworks').glob('*-wamnative.*.dylib'):shutil.copy2(p,stage/'Contents/Frameworks'/p.name)
exe=stage/'Contents/MacOS/WAM';loads=subprocess.check_output(['/usr/bin/otool','-L',str(exe)],text=True);changes=[]
for line in loads.splitlines()[1:]:
 dependency=line.strip().split(' (',1)[0]
 if not dependency.startswith('/opt/'):continue
 if '.framework/' in dependency:
  tail=dependency.split('/')
  index=next(i for i,x in enumerate(tail) if x.endswith('.framework'))
  relative='/'.join(tail[index:])
 else:relative=Path(dependency).name
 assert (stage/'Contents/Frameworks'/relative).exists(),dependency
 replacement='@loader_path/../Frameworks/'+relative
 subprocess.run(['/usr/bin/install_name_tool','-change',dependency,replacement,str(exe)],check=True);changes.append([dependency,replacement])
lines=subprocess.check_output(['/usr/bin/otool','-l',str(exe)],text=True).splitlines();rpaths=[]
for i,line in enumerate(lines):
 if line.strip()=='cmd LC_RPATH':rpaths.append(lines[i+2].strip().split('path ',1)[1].split(' (offset',1)[0])
for path in rpaths:
 if path.startswith('/opt/'):subprocess.run(['/usr/bin/install_name_tool','-delete_rpath',path,str(exe)],check=True)
if '@executable_path/../Frameworks' not in rpaths:subprocess.run(['/usr/bin/install_name_tool','-add_rpath','@executable_path/../Frameworks',str(exe)],check=True)
for lib in (stage/'Contents/Frameworks').glob('*-wamnative.*.dylib'):subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(lib)],check=True)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(stage)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(stage)],check=True)
shutil.rmtree(build);shutil.copytree(stage,build,symlinks=True)
receipt=dict(candidate_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),deep_strict_signature_verification=True,relocated_loads=changes,native_libraries={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (stage/'Contents/Frameworks').glob('*-wamnative.*.dylib')})
Path('/private/tmp/wam-phase2g/final-candidate-registry.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt),flush=True)
