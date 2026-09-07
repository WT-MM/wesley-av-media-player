#!/usr/bin/env python3
"""Stage and audit a framework's local native decoder closure without network access."""
import argparse,json,pathlib,shutil,subprocess
p=argparse.ArgumentParser();p.add_argument('--framework',type=pathlib.Path,required=True);p.add_argument('--source',type=pathlib.Path,required=True);p.add_argument('--ffmpeg',type=pathlib.Path,required=True);a=p.parse_args()
root=a.framework.resolve();version=root/'Versions/A';binary=version/'WAMKit';closure=version/'Frameworks';closure.mkdir(exist_ok=True)
def run(*args):return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT)
def deps(path):return [s.strip().split(' (')[0] for s in run('otool','-L',str(path)).splitlines()[1:]]
def system(path):return path.startswith(('/usr/lib/','/System/Library/'))
queue=[binary];seen=set()
while queue:
 path=queue.pop(0)
 if path in seen:continue
 seen.add(path)
 for dep in deps(path)[1:]:
  if system(dep):continue
  if dep.startswith('@loader_path/'):
   target=(path.parent/dep.removeprefix('@loader_path/')).resolve()
   assert target.is_file() and target.is_relative_to(root),(path,dep)
   queue.append(target);continue
  if dep.startswith('@'):raise RuntimeError(('unresolved dependency',path,dep))
  origin=pathlib.Path(dep).resolve();target=closure/origin.name
  if not target.exists():shutil.copy2(origin,target)
  target.chmod(0o755)
  run('install_name_tool','-change',dep,'@loader_path/'+('Frameworks/' if path==binary else '')+target.name,str(path))
  run('install_name_tool','-id','@loader_path/'+target.name,str(target));queue.append(target)
for name in ('libavutil-wamnative.61.dylib','libavcodec-wamnative.63.dylib','libavformat-wamnative.63.dylib'):
 origin=a.ffmpeg/'lib'/name
 if origin.is_file():
  target=closure/name;shutil.copy2(origin.resolve(),target);target.chmod(0o755)
  for dep in deps(target)[1:]:
   if dep.startswith('@rpath/') and '-wamnative.' in dep:
    run('install_name_tool','-change',dep,'@loader_path/'+pathlib.Path(dep).name,str(target))
notices=version/'Resources/ThirdPartyNotices';notices.mkdir(parents=True,exist_ok=True)
for rel in ('docs/native-coverage/phase2/COPYING.LGPLv2.1','docs/native-coverage/phase2/FFMPEG_NOTICES.md','scripts/build_ffmpeg_lgpl.sh'):
 shutil.copy2(a.source/rel,notices/pathlib.Path(rel).name)
for origin in (a.ffmpeg/'share/wam-ffmpeg').rglob('*'):
 if origin.is_file() and origin.stat().st_size<2_000_000:shutil.copy2(origin,notices/origin.name)
corresponding=version/'Resources/CorrespondingSource';corresponding.mkdir(parents=True,exist_ok=True)
for rel in ('third_party/ffmpeg-source/ffmpeg-9.0.1.tar.xz','third_party/ffmpeg-patches/wam_memory_reservation.inc','scripts/apply_ffmpeg_memory_reservation.py','scripts/build_ffmpeg_lgpl.sh'):
 origin=a.source/rel
 if not origin.is_file():raise RuntimeError('Missing corresponding source: '+rel)
 target=corresponding/rel;target.parent.mkdir(parents=True,exist_ok=True)
 if not target.exists() or target.stat().st_mtime_ns!=origin.stat().st_mtime_ns:shutil.copy2(origin,target)
vpx_notice=pathlib.Path('/opt/homebrew/opt/libvpx/LICENSE')
if vpx_notice.is_file():shutil.copy2(vpx_notice,notices/'libvpx-LICENSE')
for name in ('Modules','Frameworks'):
 link=root/name
 if not link.exists():link.symlink_to('Versions/Current/'+name)
report=[]
for path in [binary,*sorted(closure.glob('*.dylib'))]:
 dependencies=deps(path)
 for dep in dependencies[1:]:
  assert system(dep) or dep.startswith('@loader_path/'),(path,dep)
  if dep.startswith('@loader_path/'):
   target=(path.parent/dep.removeprefix('@loader_path/')).resolve()
   assert target.is_file() and target.is_relative_to(root),(path,dep)
 load=run('otool','-l',str(path));lines=load.splitlines()
 rpaths=[lines[i+2].strip().split(' ')[1] for i,line in enumerate(lines) if line.strip()=='cmd LC_RPATH']
 for rpath in rpaths:
  if rpath.startswith('/'):
   run('install_name_tool','-delete_rpath',rpath,str(path))
 report.append({'image':str(path.relative_to(root)),'dependencies':dependencies,'architectures':run('lipo','-archs',str(path)).strip(),'build_version':run('vtool','-show-build',str(path))})
for path in sorted(closure.glob('*.dylib')):run('codesign','--force','--sign','-',str(path))
(version/'Resources/PackagingAudit.json').write_text(json.dumps(report,indent=2)+'\n')
run('codesign','--force','--sign','-',str(root))
print('WAMKit packaged:',len(report),'Mach-O images; no Qt, mpv, or external non-system dependencies')
