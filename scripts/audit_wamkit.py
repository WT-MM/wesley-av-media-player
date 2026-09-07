#!/usr/bin/env python3
"""Read-only installed-framework closure, ABI, signing and SDK audit."""
import argparse,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--framework',type=pathlib.Path,required=True);p.add_argument('--exports',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--shipping',action='store_true');a=p.parse_args()
root=a.framework.resolve();binary=(root/'WAMKit').resolve();version=binary.parent
def run(*argv):return subprocess.check_output(argv,text=True,stderr=subprocess.STDOUT).strip()
expected=set(a.exports.read_text().splitlines());actual=set(run('nm','-gUj',str(binary)).splitlines());assert expected==actual,(expected-actual,actual-expected)
images=[]
for path in [binary,*sorted((version/'Frameworks').glob('*.dylib'))]:
 dependencies=[line.strip().split(' (')[0] for line in run('otool','-L',str(path)).splitlines()[1:]]
 for name in dependencies[1:]:
  assert 'Qt' not in name and 'mpv' not in name.lower(),name
  if name.startswith(('/System/Library/','/usr/lib/')):continue
  assert name.startswith('@loader_path/'),name
  target=(path.parent/name.removeprefix('@loader_path/')).resolve();assert target.is_file() and target.is_relative_to(root),name
 commands=run('otool','-l',str(path)).splitlines()
 rpaths=[commands[i+2].strip().split(' ')[1] for i,line in enumerate(commands) if line.strip()=='cmd LC_RPATH']
 assert all(not value.startswith('/') for value in rpaths),rpaths
 images.append(dict(image=str(path.relative_to(root)),dependencies=dependencies,rpaths=rpaths,architecture=run('lipo','-archs',str(path)),build_version=run('vtool','-show-build',str(path))))
strings=run('strings','-a',str(binary));assert 'loadVideoPerformanceMetricsWithCompletionHandler:' not in strings
if a.shipping:assert 'WAM_TEST_' not in strings,'shipping framework contains a test environment reader'
for path in ['Modules/module.modulemap','Resources/ThirdPartyNotices/COPYING.LGPLv2.1','Resources/ThirdPartyNotices/libvpx-LICENSE','Resources/CorrespondingSource/third_party/ffmpeg-source/ffmpeg-9.0.1.tar.xz','Resources/CorrespondingSource/third_party/ffmpeg-patches/wam_memory_reservation.inc','Resources/CorrespondingSource/scripts/apply_ffmpeg_memory_reservation.py','Resources/CorrespondingSource/scripts/build_ffmpeg_lgpl.sh']:
 assert (version/path).is_file(),path
for link in root.rglob('*'):
 if link.is_symlink():assert link.resolve().is_relative_to(root),link
signature=run('codesign','--verify','--deep','--strict','--verbose=2',str(root))
result=dict(framework=str(root),exported_symbols=sorted(actual),images=images,public_presentation_api=True,shipping_test_environment_excluded=a.shipping,signature=signature,passed=True)
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'passed':True,'images':len(images),'symbols':len(actual)}))
