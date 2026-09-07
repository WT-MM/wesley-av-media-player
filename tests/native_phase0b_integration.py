"""Apple hardware, opaque pixel, profile-refusal and long-GOP source proofs."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile


def run(argv, expected=0):
    p = subprocess.run([str(x) for x in argv], capture_output=True, text=True)
    if p.returncode in (-9, 137):
        p = subprocess.run([str(x) for x in argv], capture_output=True, text=True)
    assert p.returncode == expected, (argv, p.returncode, p.stdout, p.stderr)
    return p.stdout


def main():
    parser = argparse.ArgumentParser()
    for name in ('source', 'video', 'ffmpeg'):
        parser.add_argument('--'+name, required=True)
    parser.add_argument('--artifacts')
    a = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='wam-phase0b-', dir='/private/tmp') as tmp:
        root = Path(a.artifacts or tmp)
        root.mkdir(parents=True, exist_ok=True)
        rows = []
        def generate(name, options, seconds=1):
            path = root/name
            argv = [a.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i',
                    'testsrc2=size=320x180:rate=30', '-t', str(seconds), *options, path]
            run(argv)
            rows.append(dict(file=name, argv=list(map(str, argv)),
                             sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
            return path
        for name, options, pixel, limit in (
            ('prores4444.mov', ['-c:v','prores_ks','-profile:v','4','-pix_fmt','yuva444p10le','-threads','2'], '77333072', 2),
            ('prores4444xq.mov', ['-c:v','prores_ks','-profile:v','5','-pix_fmt','yuva444p10le','-threads','2'], '77333072', 2),
            ('hevc422.mov', ['-c:v','libx265','-pix_fmt','yuv422p10le','-x265-params','pools=2:frame-threads=1:log-level=error','-tag:v','hvc1'], '78343232', 4)):
            path = generate(name, options)
            rows[-1]['source'] = run([a.source, path])
            grab = root/(name+'.bgra')
            rows[-1]['hardware'] = run([a.video, path, 1, pixel, grab])
            assert 'using_hw=1' in rows[-1]['hardware'] and 'frames=30 ' in rows[-1]['hardware']
            ref = root/(name+'.reference.bgra')
            run([a.ffmpeg,'-v','error','-y','-i',path,'-frames:v','1','-pix_fmt','bgra','-f','rawvideo',ref])
            lhs, rhs = grab.read_bytes(), ref.read_bytes()
            assert len(lhs) == len(rhs) == 320*180*4
            errors = [int(x)-int(y) for i,(x,y) in enumerate(zip(lhs,rhs)) if i%4 != 3]
            maximum = max(map(abs, errors))
            assert maximum <= limit, (name, maximum)
            rows[-1]['rgb'] = dict(maximum=maximum, rms=math.sqrt(sum(e*e for e in errors)/len(errors)))
        for name, options, refused in (
            ('vp9p2.mp4',['-c:v','libvpx-vp9','-pix_fmt','yuv420p10le','-profile:v','2','-threads','2','-deadline','realtime'],False),
            ('av1-10.mp4',['-c:v','libsvtav1','-pix_fmt','yuv420p10le','-preset','10','-svtav1-params','lp=2'],False),
            ('hevc444.mp4',['-c:v','libx265','-pix_fmt','yuv444p10le','-x265-params','pools=2:frame-threads=1:log-level=error','-tag:v','hvc1'],True)):
            path=generate(name,options)
            rows[-1]['source']=run([a.source,path],1 if refused else 0)
            if refused: assert 'Hevc444' in rows[-1]['source'], rows[-1]
            rows[-1]['hardware']=run([a.video,path,1,0])
            assert 'using_hw=1' in rows[-1]['hardware'] and 'frames=30 ' in rows[-1]['hardware']
        path=generate('single-gop.mp4',['-c:v','libx264','-preset','ultrafast','-g','99999','-keyint_min','99999','-sc_threshold','0'],40)
        rows[-1]['source']=run([a.source,path,30,'preview'])
        assert 'decode_start=0/' in rows[-1]['source'], rows[-1]
        (root/'manifest.json').write_text(json.dumps(rows,indent=2)+'\n')
        print(json.dumps(rows,indent=2))

if __name__ == '__main__':
    main()
