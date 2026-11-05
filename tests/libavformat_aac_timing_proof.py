"""CoreMedia edited PCM versus production libavformat/AudioToolbox, no GUI."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import struct
import tempfile
from fractions import Fraction
import numpy as np

p = argparse.ArgumentParser()
for name in ['probe', 'oracle', 'ffmpeg', 'output', 'scratch']:
    p.add_argument('--' + name, required=True)
p.add_argument('--asset')
p.add_argument('--routed-probe')
a = p.parse_args()

def run(argv, success=True):
    r = subprocess.run(list(map(str, argv)), capture_output=True, text=True, timeout=180)
    assert (r.returncode == 0) == success, (argv, r.returncode, r.stderr)
    return r

def jitter_audio_stts(data, residual):
    """Restate audio stts as a zero-drift three-unit pattern, retaining its tail."""
    # This generated MOV has its moov after mdat, so growing stts cannot move
    # any media payload or invalidate the existing chunk offsets.
    def boxes(blob):
        offset = 0
        while offset < len(blob):
            size, kind = struct.unpack_from('>I4s', blob, offset)
            assert 8 <= size <= len(blob) - offset
            yield kind, blob[offset + 8:offset + size]
            offset += size
    top = list(boxes(data))
    assert [kind for kind, _ in top].index(b'mdat') < [kind for kind, _ in top].index(b'moov')
    changed = 0
    def rewrite(blob, audio=False):
        nonlocal changed
        out = bytearray()
        for kind, payload in boxes(blob):
            if kind == b'trak':
                audio = b'soun' in payload
            if kind in (b'moov', b'trak', b'mdia', b'minf', b'stbl'):
                payload = rewrite(payload, audio)
            elif kind == b'stts' and audio:
                count = struct.unpack_from('>I', payload, 4)[0]
                durations = []
                for i in range(count):
                    n, duration = struct.unpack_from('>II', payload, 8 + i * 8)
                    durations.extend([duration] * n)
                original_total = sum(durations)
                for i in range(0, len(durations) - 3, 3):
                    assert durations[i:i + 3] == [1024] * 3
                    durations[i:i + 3] = [1024 + residual, 1024 - residual, 1024]
                assert sum(durations) == original_total
                payload = payload[:4] + struct.pack('>I', len(durations))
                payload += b''.join(struct.pack('>II', 1, d) for d in durations)
                changed += 1
            out += struct.pack('>I4s', len(payload) + 8, kind) + payload
        return bytes(out)
    result = rewrite(data)
    assert changed == 1
    return result

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
    # Rate, layout, nonzero Matroska origin and seek preroll are independent
    # from the Apple-specific priming witness above. Generate all bytes here.
    for rate, channels, suffix in [(44100,2,'mp4'),(48000,6,'mp4'),(48000,2,'mkv')]:
        media = root/f'rate-{rate}-{channels}.{suffix}'
        command = generation.copy()
        command[command.index('aac_at')] = 'aac'
        command[-1:] = ['-ar',str(rate),'-ac',str(channels)] + (['-output_ts_offset','0.005'] if suffix=='mkv' else []) + [media]
        run(command)
        if suffix=='mkv':
            # ADTS has no container priming side data: this models a copied
            # LC stream with a positive start, independently of CodecDelay.
            raw=root/'audio.aac'; remuxed=root/'copied.mkv'
            run([a.ffmpeg,'-v','error','-y','-i',media,'-map','0:a:0','-c','copy','-f','adts',raw])
            run([a.ffmpeg,'-v','error','-y','-i',media,'-i',raw,'-map','0:v:0','-map','1:a:0',
                 '-c','copy','-output_ts_offset','0.005',remuxed])
            remuxed.replace(media)
        whole = run([a.probe,media,root/'whole.f32','0'])
        assert f'rate={rate} ' in whole.stderr and 'exact=1 drained=1' in whole.stderr, whole.stderr
        full = np.fromfile(root/'whole.f32',dtype='<f4').reshape(-1,2)
        if rate==44100:
            # FDK-style two-unit priming. Change the exact media edit and
            # shorten its movie interval by the same sample count.
            data=bytearray(media.read_bytes())
            locations=[]; at=0
            while True:
                at=data.find(b'elst',at)
                if at<0: break
                if int.from_bytes(data[at+16:at+20],'big',signed=True)==1024: locations.append(at)
                at+=4
            assert len(locations)==1
            at=locations[0]
            data[at+16:at+20]=(2048).to_bytes(4,'big')
            mvhd=data.index(b'mvhd'); assert data[mvhd+4]==0
            movie_rate=int.from_bytes(data[mvhd+16:mvhd+20],'big')
            delta=round(1024*movie_rate/44100)
            data[at+12:at+16]=(int.from_bytes(data[at+12:at+16],'big')-delta).to_bytes(4,'big')
            primed=root/'primed2048.mp4';primed.write_bytes(data)
            for probe in [a.probe]+([a.routed_probe] if a.routed_probe else []):
                proof=run([probe,primed,root/'primed.f32','0'])
                assert 'frames=175376 first=0' in proof.stderr and 'exact=1 drained=1' in proof.stderr, proof.stderr
        for target in ['1/7','3']:
            result = run([a.probe,media,root/'seek.f32',target])
            first = -(-(Fraction(target)*rate).numerator//(Fraction(target)*rate).denominator)
            assert f'first={first} ' in result.stderr and 'exact=1 drained=1' in result.stderr, result.stderr
            part = np.fromfile(root/'seek.f32',dtype='<f4').reshape(-1,2)
            # For MP4, compare every retained frame to the cold decode. The
            # Matroska first frame is its explicitly declared 5 ms origin.
            origin = round(.005*rate) if suffix=='mkv' else 0
            reference = full[first-origin:first-origin+len(part)]
            assert len(part)==len(full)-(first-origin), (rate,channels,suffix,len(part),len(full),first)
            assert np.max(np.abs(reference-part)) < .002, (rate,channels,suffix,target)

    grid_cases = []
    for residual in [-256, -22, -1, 1, 38, 152, 256, -257, 257]:
        jittered = root/f'jitter-{residual}.mov'
        jittered.write_bytes(jitter_audio_stts(apple.read_bytes(), residual))
        admitted = abs(residual) <= 256
        result = run([a.probe, jittered, root/'jitter.f32', '0'], admitted)
        if admitted:
            assert 'exact=1 drained=1' in result.stderr, result.stderr
        else:
            assert 'AacPacketTimelineDiscontinuity' in result.stderr, result.stderr
        if a.routed_probe:
            routed = run([a.routed_probe,jittered,root/'routed.f32','0'],admitted)
            if not admitted:
                assert routed.stderr.startswith('open:') and 'AacPacketTimelineDiscontinuity' in routed.stderr, routed.stderr
        grid_cases.append(dict(residual=residual, admitted=admitted, log=result.stderr))
    # An exact container skip is not restricted to an encoder-specific list.
    # Changing the edit by one sample must change the retained count by one.
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
    refusal = run([a.probe,refused,root/'refused.f32','0'])
    assert 'frames=192511 first=0' in refusal.stderr and 'exact=1 drained=1' in refusal.stderr, refusal.stderr
    # Retimed edits remain refused; a leading empty edit declares silence.
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
    leading_refusal = run([a.probe,leading,root/'refused.f32','0'])
    assert 'first=9888 ' in leading_refusal.stderr and 'exact=1 drained=1' in leading_refusal.stderr, leading_refusal.stderr
    extended_data = bytearray(apple.read_bytes())
    at = edits[0]+12
    extended_data[at:at+4] = (int.from_bytes(extended_data[at:at+4],'big')+48000).to_bytes(4,'big')
    extended = root/'long-edit.mov'; extended.write_bytes(extended_data)
    end_refusal = run([a.probe,extended,root/'refused.f32','0'],False)
    assert 'LibavformatAudioTimingUnproven: aac' in end_refusal.stderr, end_refusal.stderr
    receipt = dict(probe_sha256=hashlib.sha256(pathlib.Path(a.probe).read_bytes()).hexdigest(),
                   oracle_sha256=hashlib.sha256(pathlib.Path(a.oracle).read_bytes()).hexdigest(),
                   generation=list(map(str,generation)),assets=rows,refusal=refusal.stderr,
                   grid_cases=grid_cases,
                   end_refusal=end_refusal.stderr,
                   rate_refusal=rate_refusal.stderr,leading_refusal=leading_refusal.stderr)
    pathlib.Path(a.output).write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
