"""Audit native-stage load commands and the actual dependency deployment floors."""
import argparse,json,pathlib,plistlib,re,subprocess
p=argparse.ArgumentParser();p.add_argument('--app',required=True);p.add_argument('--output',required=True);a=p.parse_args()
app=pathlib.Path(a.app);exe=app/'Contents/MacOS/WAM';frameworks=app/'Contents/Frameworks'
def output(*cmd):return subprocess.check_output(cmd,text=True)
def inspect(path):
    loads=output('/usr/bin/otool','-L',str(path))
    commands=output('/usr/bin/otool','-l',str(path))
    versions=re.findall(r'\bminos\s+(\d+(?:\.\d+)+)',commands)
    if not versions:versions=re.findall(r'\bversion\s+(\d+(?:\.\d+)+)',commands)
    return dict(path=str(path),loads=loads,minos=versions,at_or_below_13_3=bool(versions) and all(tuple(map(int,v.split('.'))) <= (13,3,0) for v in versions))
native_names=['libavcodec-wamnative.63.dylib','libavutil-wamnative.61.dylib']
if (app/'Contents/Resources/native-ffmpeg/demux-stage-built').exists():native_names.append('libavformat-wamnative.63.dylib')
native=[inspect(frameworks/name) for name in native_names]
main=inspect(exe)
direct=[]
for line in main['loads'].splitlines()[1:]:
    dep=line.strip().split(' (compatibility')[0]
    if dep.startswith('/opt/') and pathlib.Path(dep).is_file():direct.append(inspect(pathlib.Path(dep)))
notices=app/'Contents/Resources/native-ffmpeg'
required=['FFMPEG_NOTICES.md','COPYING.LGPLv2.1','LICENSE.md','configure-command.txt','build-receipt.txt','SOURCE_DISTRIBUTION.md']
result=dict(native=native,main=main,direct_external_dependencies=direct,
    eager_native_ffmpeg=any(x in main['loads'] for x in ['libavcodec','libavutil']),
    notices={name:(notices/name).is_file() for name in required},
    clean_machine_ready=not direct and all(x['at_or_below_13_3'] for x in native))
pathlib.Path(a.output).write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(dict(eager_native_ffmpeg=result['eager_native_ffmpeg'],new_libraries_floor_pass=all(x['at_or_below_13_3'] for x in native),notices=result['notices'],clean_machine_ready=result['clean_machine_ready']),indent=2))

if not result['clean_machine_ready']:
    print('NativeBundleNotRelocatable: external dependencies or deployment-floor mismatch')
    raise SystemExit(2)
