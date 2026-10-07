"""CoreMedia edited PCM versus production libavformat/AudioToolbox, no GUI."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile
from fractions import Fraction
import numpy as np

p = argparse.ArgumentParser()
for name in ['probe', 'oracle', 'ffmpeg', 'output', 'scratch']:
    p.add_argument('--' + name, required=True)
p.add_argument('--asset')
a = p.parse_args()

def run(argv, success=True):
    r = subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=180)
    assert (r.returncode == 0) == success, (argv, r.returncode, r.stderr)
    return r

with tempfile.TemporaryDirectory(prefix='aac-proof-', dir=a.scratch) as tmp:
    root = pathlib.Path(tmp)
    apple = root/'apple.mov'
    generation = [a.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i',
        'testsrc2=size=160x90:rate=30:duration=4', '-f', 'lavfi', '-i',
        'aevalsrc=0.2*sin(2*PI*(200*t+100*t*t))|0.15*sin(2*PI*(300*t+130*t*t)):s=48000:d=4',
        '-c:v', 'libx264', '-threads', '4', '-preset', 'ultrafast', '-c:a', 'aac_at', apple]
    run(generation)
    assets = [apple] + ([pathlib.Path(a.asset)] if a.asset else [])
    rows = []
    for asset in assets:
        reference = root/'reference.f32'
        oracle = run([a.oracle, asset, reference])
        expected = np.memmap(reference, dtype='<f4', mode='r').reshape(-1,2)
        cases = []
        for target in ['0', '1/7', '1', str(Fraction(len(expected)-48,48000))]:
            actual = root/'actual.f32'
            result = run([a.probe, asset, actual, target])
            value = Fraction(target)*48000
            first = -(-value.numerator//value.denominator)
            x = np.memmap(actual, dtype='<f4', mode='r').reshape(-1,2)
            assert len(x) == len(expected)-first, (asset,target,len(x),len(expected)-first)
            assert f'first={first} ' in result.stderr and 'exact=1 drained=1' in result.stderr
            maximum = squared = count = 0
            for begin in range(0,len(x),48000):
                d = x[begin:begin+48000].astype('float64') - expected[first+begin:first+begin+len(x[begin:begin+48000])]
                maximum = max(maximum,float(abs(d).max()))
                squared += float(np.sum(d*d)); count += d.size
            rms = (squared/count)**.5
            # Preserve the existing mixed AAC proof tolerances, without fitting a lag.
            assert maximum < .002 and rms < .0001, (asset,target,maximum,rms)
            cases.append(dict(target=target,first_frame=first,frames=len(x),max_error=maximum,rms=rms,log=result.stderr))
            del x
        rows.append(dict(asset=str(asset),sha256=hashlib.sha256(asset.read_bytes()).hexdigest(),oracle=oracle.stderr,cases=cases))
        del expected
    # Mutate only our small synthetic fixture. An unqualified priming value
    # must retain the named refusal, not silently use a nearby sample offset.
    data = bytearray(apple.read_bytes())
    edits = []; pos = 0
    while True:
        pos = data.find(b'elst',pos)
        if pos < 0: break
        if int.from_bytes(data[pos+16:pos+20],'big',signed=True)==2112: edits.append(pos)
        pos += 4
    assert len(edits)==1
    data[edits[0]+16:edits[0]+20]=(2113).to_bytes(4,'big')
    refused = root/'unproved.mov'; refused.write_bytes(data)
    refusal = run([a.probe,refused,root/'refused.f32','0'],False)
    assert 'LibavformatAudioTimingUnproven: aac' in refusal.stderr, refusal.stderr
    # Retimed edits and a leading empty edit are deliberately unqualified.
    retimed_data = bytearray(apple.read_bytes())
    retimed_data[edits[0]+20:edits[0]+24] = (2 << 16).to_bytes(4,'big')
    retimed = root/'retimed.mov'; retimed.write_bytes(retimed_data)
    rate_refusal = run([a.probe,retimed,root/'refused.f32','0'],False)
    assert 'LibavformatAudioTimingUnproven: aac' in rate_refusal.stderr, rate_refusal.stderr
    leading = root/'leading.mov'
    leading_command = generation.copy()
    leading_command[8:8] = ['-itsoffset','0.25']
    leading_command[-1] = leading
    run(leading_command)
    leading_refusal = run([a.probe,leading,root/'refused.f32','0'],False)
    assert 'LibavformatAudioTimingUnproven: aac' in leading_refusal.stderr, leading_refusal.stderr
    extended_data = bytearray(apple.read_bytes())
    at = edits[0]+12
    extended_data[at:at+4] = (int.from_bytes(extended_data[at:at+4],'big')+48000).to_bytes(4,'big')
    extended = root/'long-edit.mov'; extended.write_bytes(extended_data)
    end_refusal = run([a.probe,extended,root/'refused.f32','0'],False)
    assert 'LibavformatAudioTimingUnproven: aac' in end_refusal.stderr, end_refusal.stderr
    receipt = dict(probe_sha256=hashlib.sha256(pathlib.Path(a.probe).read_bytes()).hexdigest(),
                   oracle_sha256=hashlib.sha256(pathlib.Path(a.oracle).read_bytes()).hexdigest(),
                   generation=list(map(str,generation)),assets=rows,refusal=refusal.stderr,
                   end_refusal=end_refusal.stderr,
                   rate_refusal=rate_refusal.stderr,leading_refusal=leading_refusal.stderr)
    pathlib.Path(a.output).write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
