"""Offline production-source/converter regression and retained specimen receipts."""
import argparse
import array
import hashlib
import json
import math
import platform
from pathlib import Path
import re
import subprocess
import tempfile
import os
from fractions import Fraction


def run(argv, expected=0):
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
            while len(payload) >= (1 << (7*sw))-1:
                sw += 1
                assert sw <= 8, 'EBML payload exceeds finite size envelope'
            out += ((1 << (7*sw)) | len(payload)).to_bytes(sw, 'big')
            out += payload
            offset = end
        return bytes(out)
    return rewrite(data)


def test_ebml_size_growth():
    # The added Audio child crosses the one-byte finite-size boundary in
    # Audio, TrackEntry and Tracks, and must not encode the unknown-size value.
    audio = b'\xe1\xfc' + b'\xec\xfa' + bytes(122)
    track = b'\xae\xfe' + audio
    tracks = b'\x16\x54\xae\x6b\x40\x80' + track
    rewritten = opus_output_rate(tracks,48000.0)
    assert rewritten[4:6] == b'\x40\x8d'
    assert rewritten[7:9] == b'\x40\x8a'
    assert rewritten[10:12] == b'\x40\x87'
    assert len(rewritten) == 147


def prepend_stray_video_sample(data):
    """Give the video track a leading non-sync access unit: the first
    sample's own SEI NAL, one frame earlier and in its own chunk (moov follows
    mdat, so no payload moves)."""
    import struct
    def boxes(blob):
        offset = 0
        while offset < len(blob):
            size, kind = struct.unpack_from('>I4s', blob, offset)
            yield kind, blob[offset+8:offset+size]
            offset += size
    def table(payload, width, head=b'', each=lambda e: e, skip=0):
        count = struct.unpack_from('>I', payload, 4+skip)[0]
        at = 8+skip
        rows = [each(payload[at+i*width:at+(i+1)*width]) for i in range(count)]
        return payload[:4+skip] + struct.pack('>I', count+(1 if head else 0)) + head + b''.join(rows)
    def bump(e):
        return struct.pack('>I', struct.unpack_from('>I', e)[0]+1) + e[4:]
    video_stbl = None
    def find(blob, video=False):
        nonlocal video_stbl
        for kind, payload in boxes(blob):
            if kind == b'trak':
                video = b'vide' in payload
            if kind == b'stbl' and video:
                video_stbl = dict(boxes(payload))
            elif kind in (b'moov', b'trak', b'mdia', b'minf'):
                find(payload, video)
    find(data)
    first = struct.unpack_from('>I', video_stbl[b'stco'], 8)[0]
    assert data[first+4] & 0x1f == 6, 'first NAL is not SEI'
    stray = 4 + struct.unpack_from('>I', data, first)[0]
    delta = struct.unpack_from('>I', video_stbl[b'stts'], 12)[0]
    edits = {b'stts': lambda p: table(p, 8, struct.pack('>II', 1, delta)),
             b'ctts': lambda p: table(p, 8, struct.pack('>I', 1) + p[12:16]),
             b'stss': lambda p: table(p, 4, each=bump),
             b'stsc': lambda p: table(p, 12, struct.pack('>III', 1, 1, 1), bump),
             b'stsz': lambda p: table(p, 4, struct.pack('>I', stray), skip=4),
             b'stco': lambda p: table(p, 4, struct.pack('>I', first))}
    def rewrite(blob, video=False):
        out = bytearray()
        for kind, payload in boxes(blob):
            if kind == b'trak':
                video = b'vide' in payload
            if kind in (b'moov', b'trak', b'mdia', b'minf', b'stbl'):
                payload = rewrite(payload, video)
            elif video and kind in edits:
                payload = edits[kind](payload)
            elif video and kind == b'mdhd':
                payload = bytearray(payload)
                assert payload[0] == 0
                struct.pack_into('>I', payload, 16, struct.unpack_from('>I', payload, 16)[0] + delta)
            out += struct.pack('>I4s', len(payload)+8, kind) + payload
        return bytes(out)
    return rewrite(data)

def main():
    test_ebml_size_growth()
    args = argparse.ArgumentParser()
    args.add_argument('--audio', required=True)
    args.add_argument('--source', required=True)
    args.add_argument('--ffmpeg', required=True)
    args.add_argument('--artifacts')
    args.add_argument('--case', default='all')
    a = args.parse_args()
    temporary = tempfile.TemporaryDirectory(prefix='wam-native-coverage-', dir=os.environ.get('WAM_TEST_SCRATCH', '/private/tmp'))
    root = Path(a.artifacts or temporary.name)
    root.mkdir(parents=True, exist_ok=True)
    manifest = {'version': 2,
                'audio_probe_sha256': hashlib.sha256(Path(a.audio).read_bytes()).hexdigest(),
                'source_probe_sha256': hashlib.sha256(Path(a.source).read_bytes()).hexdigest(),
                'ffmpeg': run([a.ffmpeg, '-version']).stdout,
                'specimens': [], 'proofs': []}

    def generate(name, rate=48000, codec='aac', extra=(), seconds=4, offset=False):
        argv = [a.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i',
                (f'aevalsrc=0.375+0.03*sin(2*PI*(200*t+100*t*t))|-0.25+0.02*sin(2*PI*(300*t+130*t*t)):s={rate}' if offset else
                 f'aevalsrc=0.2*sin(2*PI*(200*t+100*t*t))|0.15*sin(2*PI*(300*t+130*t*t)):s={rate}'),
                '-t', str(seconds), '-c:a', codec, *extra, root/name]
        run(argv)
        manifest['specimens'].append({'file': name, 'argv': [str(x) for x in argv],
            'sha256': hashlib.sha256((root/name).read_bytes()).hexdigest()})
        return root/name

    def decode(path, rate, frames, target=0, reference=None, bit_exact=False, origin=False, mono=False, seek=False):
        target_frame = math.ceil(Fraction(target)*rate)
        pcm = root/(path.name+f'-{str(target).replace(chr(47),chr(95))}.f32')
        result = run([a.audio, path, pcm, target, *(["origin"] if origin else ["seek"] if seek else [])])
        assert f'rate={rate}' in result.stderr and f'frames={frames-target_frame} ' in result.stderr, result.stderr
        assert 'exact=1 drained=1' in result.stderr, result.stderr
        assert f'first={target_frame} ' in result.stderr, result.stderr
        assert pcm.stat().st_size == (frames-target_frame)*8
        ref = root/(path.name+'.reference.f32')
        run([a.ffmpeg, '-v', 'error', '-y', '-i', reference or path, '-map', '0:a:0',
             *(['-af','pan=stereo|c0=c0|c1=c0'] if mono else []),
             '-ac', '2', '-c:a', 'pcm_f32le', '-f', 'f32le', ref])
        output = array.array('f', pcm.read_bytes())
        expected = array.array('f', ref.read_bytes())[target_frame*2:frames*2]
        assert len(output) == len(expected), (path, len(output), len(expected))
        errors = [float(x)-float(y) for x,y in zip(output, expected)]
        rms = math.sqrt(sum(x*x for x in errors)/len(errors))
        maximum = max(abs(x) for x in errors)
        assert all(math.isfinite(x) for x in output)
        limit = 1e-12 if bit_exact else 0.004
        first = next((i for i, x in enumerate(errors) if abs(x) >= limit), None)
        assert maximum < limit, (path, maximum, platform.mac_ver()[0], 'first divergent interleaved sample', first,
                                 output[first:first+4].tolist() if first is not None else None,
                                 expected[first:first+4].tolist() if first is not None else None)
        # Both independent chirps must align at lag zero, including channel identity.
        lags = {}
        for lag in (-2,-1,0,1,2):
            lags[lag] = sum((output[i]-expected[i+lag*2])**2
                            for i in range(4096, len(output)-4096, 16))
        assert min(lags, key=lags.get) == 0, (path, lags)
        proof = dict(file=path.name, asset_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                     target=target, frames=len(output)//2,
                     rms=rms, maximum=maximum, best_lag=0, diagnostic=result.stderr.strip())
        manifest['proofs'].append(proof)
        print(json.dumps(proof), flush=True)

    if a.case in ('all','aac'):
        path = generate('aac.m4a')
        decode(path,48000,192000)
        decode(path,48000,192000,2)
    if a.case in ('all','mp3'):
        # Bare MP3: MPEG-2 LSF (22050/24000, 576-frame packets, gapless from
        # the LAME tag) and MPEG-1 (32000/44100). A warm seek on the open
        # source must keep the same gapless trim as the cold open.
        for rate in (8000,22050,24000,32000,44100):
            path = generate(f'mp3-{rate}.mp3',rate,'libmp3lame')
            decode(path,rate,rate*4)
            if rate == 22050: decode(path,rate,rate*4,2)
            if rate in (22050,44100): decode(path,rate,rate*4,'5/2',seek=True)
    if a.case in ('all','opus'):
        for rate in (8000,24000,48000):
            path = generate(f'opus-{rate}.webm',rate,'libopus')
            decode(path,48000,192000)
        explicit = root/'opus-output-48000.webm'
        explicit.write_bytes(opus_output_rate(path.read_bytes(),48000.0))
        decode(explicit,48000,192000)
        for rate in (24000,96000):
            invalid = root/f'opus-output-{rate}.webm'
            invalid.write_bytes(opus_output_rate(path.read_bytes(),float(rate)))
            result=run([a.source,invalid],expected=1)
            assert 'OpusOutputSampleRateUnsupported' in result.stdout, result.stdout
            manifest['proofs'].append(dict(file=invalid.name,asset_sha256=hashlib.sha256(invalid.read_bytes()).hexdigest(),diagnostic=result.stdout.strip()))
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
    if a.case in ('all','lossless','matroska-apple'):
        for codec in ('adpcm_ima_wav','adpcm_ms'):
            for rate in (44100,48000):
                for channels in (1,2):
                    for ext in (('wav','mka') if a.case=='all' else ('wav',) if a.case=='lossless' else ('mka',)):
                        path=generate(f'{codec}-{rate}-{channels}.{ext}',rate,codec,extra=('-ac',str(channels)))
                        ref=root/(path.name+'.count.f32')
                        run([a.ffmpeg,'-v','error','-y','-i',path,'-ac','2','-c:a','pcm_f32le','-f','f32le',ref])
                        frames=ref.stat().st_size//8 if ext=='wav' else rate*4
                        for target in (0,2,'100001/100000'):
                            decode(path,rate,frames,target,bit_exact=True,mono=channels==1)
    if a.case in ('all','pcm-u8'):
        path=generate('pcm-u8-offset.mka',48000,'pcm_u8',seconds=2,offset=True)
        decode(path,48000,96000,bit_exact=True)
    if a.case in ('all','matroska-apple'):
        for codec in ('alac','pcm_s16le','pcm_f32le','adpcm_ima_wav','adpcm_ms'):
            path=generate(codec+'.mka',48000,codec)
            decode(path,48000,192000,bit_exact=True)
            decode(path,48000,192000,2,bit_exact=True)
    if a.case in ('all','matroska-apple'):
        for codec in ('adpcm_ima_wav','adpcm_ms'):
            for size in (64,8192):
                path=generate(f'{codec}-block-{size}.mka',48000,codec,extra=('-block_size',str(size)))
                decode(path,48000,192000,bit_exact=True)
    if a.case in ('all','lossless'):
        for codec,reason in (('adpcm_ima_wav','AdpcmImaHeaderInvalid'),('adpcm_ms','AdpcmMsHeaderInvalid')):
            original=root/(codec+'.wav')
            data=bytearray(original.read_bytes())
            offset=12
            while data[offset:offset+4]!=b'data':
                size=int.from_bytes(data[offset+4:offset+8],'little')
                offset+=8+size+(size&1)
            data[offset+8+(2 if codec=='adpcm_ima_wav' else 0)]=255
            path=root/(codec+'-bad-header.wav'); path.write_bytes(data)
            result=run([a.audio,path,root/'bad.f32',0],expected=1)
            assert reason in result.stderr, result.stderr
            manifest['proofs'].append(dict(file=path.name,refusal=reason,diagnostic=result.stderr))
        data=bytearray((root/'adpcm_ms.wav').read_bytes())
        offset=data.index(b'fmt ')+8
        data[offset+22:offset+24]=(255).to_bytes(2,'little')
        path=root/'adpcm-ms-custom-coefficients.wav'; path.write_bytes(data)
        result=run([a.source,path],expected=1)
        assert 'AdpcmWaveFormatMismatch' in result.stdout, result.stdout
        manifest['proofs'].append(dict(file=path.name,refusal='AdpcmWaveFormatMismatch',diagnostic=result.stdout))
    if a.case in ('all','matroska-rates'):
        for rate in (8000,11025,12000,16000,22050,24000,32000,44100,48000,96000,192000):
            for codec in ('pcm_s16le','alac'):
                path=generate(f'{codec}-{rate}.mka',rate,codec,seconds=2)
                decode(path,rate,rate*2,bit_exact=True)
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
        combined=root/'two-he.mka'
        run([a.ffmpeg,'-v','error','-y','-i',root/'he-aac-4.m4a.mka',
             '-i',root/'he-aac-28.m4a.mka','-map','0:a','-map','1:a','-c','copy',combined])
        result=run([a.source,combined],expected=1)
        assert 'error=HeAacSbrDecoderDelayUnproven' in result.stdout and '; candidates:' in result.stdout, result.stdout
        assert 'track 1 (A_AAC): HeAacSbrDecoderDelayUnproven' in result.stdout, result.stdout
        assert 'track 2 (A_AAC): HeAacSbrDecoderDelayUnproven' in result.stdout, result.stdout
        manifest['proofs'].append(dict(file=combined.name,asset_sha256=hashlib.sha256(combined.read_bytes()).hexdigest(),diagnostic=result.stdout.strip()))
    if a.case in ('all','implicit-sbr'):
        # Implicit SBR: the configuration names AAC-LC at the core rate and
        # only the access units carry SBR. Every route must refuse it rather
        # than decode the band-limited core; plain LC at the same rates plays.
        he=root/'implicit-source.m4a'
        run([a.ffmpeg,'-v','error','-y','-f','lavfi','-i','anoisesrc=d=2:r=96000:a=0.2','-ac','2',
             '-c:a','aac_at','-profile:a','4','-b:a','128k',he])
        adts=root/'implicit.aac'
        run([a.ffmpeg,'-v','error','-y','-i',he,'-c','copy','-f','adts',adts])
        video=['-f','lavfi','-i','testsrc2=size=160x90:rate=30:duration=2']
        implicit=[]
        for suffix in ('mp4','ts','mkv'):
            path=root/f'implicit-sbr.{suffix}'
            run([a.ffmpeg,'-v','error','-y',*video,'-i',adts,'-c:v','libx264','-preset','ultrafast','-c:a','copy',path])
            implicit.append(path)
        # ffmpeg states the decoded rate as OutputSamplingFrequency, which the
        # Matroska route already refuses; void it so the access units decide.
        mkv=bytearray(implicit[-1].read_bytes())
        at=mkv.find(bytes.fromhex('78b588'))
        assert at>0
        mkv[at:at+11]=bytes([0xEC,0x89])+bytes(9)
        implicit[-1].write_bytes(mkv)
        core=root/'implicit-sbr-core24.mp4'
        low=root/'implicit-24.m4a'
        run([a.ffmpeg,'-v','error','-y','-f','lavfi','-i','anoisesrc=d=2:r=48000:a=0.2','-ac','2',
             '-c:a','aac_at','-profile:a','4','-b:a','64k',low])
        run([a.ffmpeg,'-v','error','-y','-i',low,'-c','copy','-f','adts',root/'implicit-24.aac'])
        run([a.ffmpeg,'-v','error','-y',*video,'-i',root/'implicit-24.aac','-c:v','libx264','-preset','ultrafast','-c:a','copy',core])
        implicit.append(core)
        for path in implicit:
            result=run([a.audio,path,root/'refused.f32','0'],expected=1)
            assert 'open: HeAacSbrDecoderDelayUnproven' in result.stderr, (path.name,result.stderr)
            manifest['proofs'].append(dict(file=path.name,refusal='HeAacSbrDecoderDelayUnproven',diagnostic=result.stderr.strip()))
        for rate,suffix in ((24000,'mp4'),(48000,'ts'),(48000,'mkv')):
            path=root/f'lc-{rate}.{suffix}'
            run([a.ffmpeg,'-v','error','-y',*video,'-f','lavfi','-i',f'anoisesrc=d=2:r={rate}:a=0.2','-ac','2',
                 '-c:v','libx264','-preset','ultrafast','-c:a','aac',path])
            result=run([a.audio,path,root/'lc.f32','0'])
            assert 'exact=1 drained=1' in result.stderr, (path.name,result.stderr)
    if a.case in ('all','late-first-picture'):
        # Without a video edit list, B-frame composition offsets put the
        # first picture after time 0; some muxers also write a stray
        # non-sync access unit first. Both must open at 0, and preview there,
        # from the first sync sample.
        late=root/'late-first-picture.mp4'
        run([a.ffmpeg,'-v','error','-y','-f','lavfi','-i','testsrc2=size=160x90:rate=30:duration=2',
             '-f','lavfi','-i','sine=f=440:d=2:r=48000','-c:v','libx264','-bf','2','-c:a','aac',
             '-use_editlist','0',late])
        stray=root/'stray-first-sample.mp4'
        stray.write_bytes(prepend_stray_video_sample(late.read_bytes()))
        for path in (late,stray):
            result=run([a.source,path,0,'preview'])
            assert 'preview_status=' in result.stdout, result.stdout
            manifest['proofs'].append(dict(file=path.name,diagnostic=result.stdout.strip()))
    (root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__=='__main__': main()
