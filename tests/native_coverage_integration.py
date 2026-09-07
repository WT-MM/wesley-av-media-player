"""Offline production-source/converter regression and retained specimen receipts."""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import tempfile


def run(argv, expected=0):
    result = subprocess.run([str(x) for x in argv], capture_output=True, text=True)
    if result.returncode == 137 or result.returncode == -9:
        result = subprocess.run([str(x) for x in argv], capture_output=True, text=True)
    if result.returncode != expected:
        raise AssertionError(f'{argv}\nrc={result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def opus_output_rate(data, rate):
    import struct
    masters = {0x18538067, 0x1654AE6B, 0xAE, 0xE1}
    def rewrite(blob):
        out = bytearray()
        offset = 0
        while offset < len(blob):
            start = offset
            def width(first):
                for n in range(1, 9):
                    if first & (1 << (8-n)): return n
                raise AssertionError('invalid EBML integer')
            iw = width(blob[offset])
            identity = int.from_bytes(blob[offset:offset+iw], 'big')
            offset += iw
            sw = width(blob[offset])
            size = int.from_bytes(blob[offset:offset+sw], 'big') & ((1 << (7*sw))-1)
            unknown = size == (1 << (7*sw))-1
            offset += sw
            end = len(blob) if unknown else offset+size
            assert end <= len(blob)
            payload = blob[offset:end]
            if identity in (0x114D9B74, 0x1C53BB6B):
                offset = end
                continue
            if identity in masters:
                payload = rewrite(payload)
                if identity == 0xE1:
                    payload += bytes([0x78, 0xB5, 0x88]) + struct.pack('>d', rate)
            out += blob[start:start+iw]
            out += ((1 << (7*sw)) | len(payload)).to_bytes(sw, 'big')
            out += payload
            offset = end
        return bytes(out)
    return rewrite(data)


def main():
    args = argparse.ArgumentParser()
    args.add_argument('--audio', required=True)
    args.add_argument('--source', required=True)
    args.add_argument('--ffmpeg', required=True)
    args.add_argument('--artifacts')
    args.add_argument('--case', default='all')
    a = args.parse_args()
    temporary = tempfile.TemporaryDirectory(prefix='wam-native-coverage-', dir='/private/tmp')
    root = Path(a.artifacts or temporary.name)
    root.mkdir(parents=True, exist_ok=True)
    manifest = {'version': 1, 'ffmpeg': run([a.ffmpeg, '-version']).stdout,
                'specimens': [], 'proofs': []}

    def generate(name, rate=48000, codec='aac', extra=(), seconds=4):
        argv = [a.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i',
                f'aevalsrc=0.2*sin(2*PI*(200*t+100*t*t))|0.15*sin(2*PI*(300*t+130*t*t)):s={rate}',
                '-t', str(seconds), '-c:a', codec, *extra, root/name]
        run(argv)
        manifest['specimens'].append({'file': name, 'argv': [str(x) for x in argv],
            'sha256': hashlib.sha256((root/name).read_bytes()).hexdigest()})
        return root/name

    def decode(path, rate, frames, target=0, reference=None, bit_exact=False, origin=False):
        pcm = root/(path.name+f'-{target}.f32')
        result = run([a.audio, path, pcm, target, *(["origin"] if origin else [])])
        assert f'rate={rate}' in result.stderr and f'frames={frames-target*rate} ' in result.stderr, result.stderr
        assert 'exact=1 drained=1' in result.stderr, result.stderr
        assert pcm.stat().st_size == (frames-target*rate)*8
        ref = root/(path.name+'.reference.f32')
        run([a.ffmpeg, '-v', 'error', '-y', '-i', reference or path, '-map', '0:a:0',
             '-ac', '2', '-c:a', 'pcm_f32le', '-f', 'f32le', ref])
        output = array.array('f', pcm.read_bytes())
        expected = array.array('f', ref.read_bytes())[target*rate*2:frames*2]
        assert len(output) == len(expected), (path, len(output), len(expected))
        errors = [float(x)-float(y) for x,y in zip(output, expected)]
        rms = math.sqrt(sum(x*x for x in errors)/len(errors))
        maximum = max(abs(x) for x in errors)
        assert all(math.isfinite(x) for x in output)
        assert maximum < (1e-12 if bit_exact else 0.004), (path, maximum)
        # Both independent chirps must align at lag zero, including channel identity.
        lags = {}
        for lag in (-2,-1,0,1,2):
            lags[lag] = sum((output[i]-expected[i+lag*2])**2
                            for i in range(4096, len(output)-4096, 16))
        assert min(lags, key=lags.get) == 0, (path, lags)
        proof = dict(file=path.name, target=target, frames=len(output)//2,
                     rms=rms, maximum=maximum, best_lag=0, diagnostic=result.stderr.strip())
        manifest['proofs'].append(proof)
        print(json.dumps(proof), flush=True)

    if a.case in ('all','aac'):
        path = generate('aac.m4a')
        decode(path,48000,192000)
        decode(path,48000,192000,2)
    if a.case in ('all','mp3'):
        for rate in (8000,22050,24000,32000):
            path = generate(f'mp3-{rate}.mp3',rate,'libmp3lame')
            decode(path,rate,rate*4)
            if rate == 22050: decode(path,rate,rate*4,2)
    if a.case in ('all','opus'):
        for rate in (8000,24000,48000):
            path = generate(f'opus-{rate}.webm',rate,'libopus')
            decode(path,48000,192000)
        explicit = root/'opus-output-48000.webm'
        explicit.write_bytes(opus_output_rate(path.read_bytes(),48000.0))
        decode(explicit,48000,192000)
        invalid = root/'opus-output-24000.webm'
        invalid.write_bytes(opus_output_rate(path.read_bytes(),24000.0))
        run([a.source,invalid],expected=1)
    if a.case in ('all','selection'):
        bad=generate('bad.m4a',88200)
        good=generate('good.m4a')
        for ext in ('mov','mka'):
            path=root/('alternate.'+ext)
            run([a.ffmpeg,'-v','error','-y','-i',bad,'-i',good,'-map','0:a','-map','1:a',
                 '-c','copy','-disposition:a:0','default','-disposition:a:1','0',path])
            decode(path,48000,192000,reference=good)
    if a.case in ('all','mjpeg'):
        for chroma in ('420','422','444'):
            path=root/f'mjpeg{chroma}.mov'
            run([a.ffmpeg,'-v','error','-y','-f','lavfi','-i','testsrc2=size=320x180:rate=30',
                 '-t','1','-c:v','mjpeg','-pix_fmt',f'yuvj{chroma}p',path])
            result=run([a.source,path],expected=0 if chroma=='420' else 1)
            if chroma!='420': assert 'Motion JPEG chroma' in result.stdout, result.stdout
            manifest['proofs'].append(dict(file=path.name,diagnostic=result.stdout.strip()))
    if a.case in ('all','lossless'):
        for codec,ext in [('alac','m4a'),('pcm_s16le','wav'),('adpcm_ima_wav','wav'),('adpcm_ms','wav')]:
            path=generate(codec+'.'+ext,48000,codec)
            ref=root/(codec+'.count.f32')
            run([a.ffmpeg,'-v','error','-y','-i',path,'-ac','2','-c:a','pcm_f32le','-f','f32le',ref])
            decode(path,48000,ref.stat().st_size//8,bit_exact=True)
    if a.case in ('all','matroska-apple'):
        for codec in ('alac','pcm_s16le','pcm_f32le','adpcm_ima_wav','adpcm_ms'):
            path=generate(codec+'.mka',48000,codec)
            decode(path,48000,192000,bit_exact=True)
            decode(path,48000,192000,2,bit_exact=True)
    if a.case in ('all','slow-audio'):
        path=generate('slow-audio.wav',48000,'pcm_s16le',seconds=32)
        decode(path,48000,1536000,30,bit_exact=True,origin=True)
    if a.case in ('all','he-aac'):
        for profile in (4,28):
            path=generate(f'he-aac-{profile}.m4a',48000,'aac_at',('-profile:a',str(profile),'-b:a','48k'))
            matroska=root/(path.name+'.mka')
            run([a.ffmpeg,'-v','error','-y','-i',path,'-c','copy',matroska])
            for container in (path,matroska):
                result=run([a.source,container],expected=1)
                assert 'HeAacSbrDecoderDelayUnproven' in result.stdout, result.stdout
                manifest['proofs'].append(dict(file=container.name,diagnostic=result.stdout.strip()))
    (root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__=='__main__': main()
