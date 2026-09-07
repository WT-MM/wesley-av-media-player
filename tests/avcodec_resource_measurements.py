"""Instrumented worker/adapter counts; process CPU trials run separately."""
from pathlib import Path
import subprocess,json,argparse
parser=argparse.ArgumentParser();parser.add_argument('--output',required=True);args=parser.parse_args()
repo=Path(__file__).resolve().parents[1];root=Path(args.output);root.mkdir(parents=True,exist_ok=True);fixtures=repo/'test-media/native-coverage/phase2'
rows=[]
for name,kind,channels in [('asp','video',2),('hi10p','video',2),('h264422','video',2),('vp9','video',2),('vp9p2','video',2),('dts','audio',2),('truehd','audio',2),('dts51','audio',6),('truehd51','audio',6)]:
    if kind=='video':
        cmd=[str(repo/'build/wam_avcodec_video_allocation_test'),str(fixtures/(name+'.packets')),name]
    else:
        cmd=[str(repo/'build/wam_avcodec_audio_allocation_test'),str(fixtures/(name+'.audio-packets')),str(fixtures/(name+'.f32')),name]
        if channels>2:cmd.extend([str(channels),str(fixtures/(name+'.stereo.f32'))])
    r=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
    if r.returncode==-9:r=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
    rows.append(dict(name=name,command=cmd,rc=r.returncode,stdout=r.stdout,stderr=r.stderr,
                     measurements=[json.loads(x) for x in r.stdout.splitlines() if x.startswith('{')]))
    (root/'resources.json').write_text(json.dumps(rows,indent=2)+'\n')
    print(name,r.returncode,flush=True)
