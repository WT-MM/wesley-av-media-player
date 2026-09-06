#!/usr/bin/env python3
"""Versioned, bounded MPEG-TS integration corpus; all times are integer ticks."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

VERSION = 1

def run(ffmpeg, *args):
    subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error',
                    '-y', *map(str, args)], check=True)


def packets(data, stride=188):
    for base in range(0, len(data) - stride + 1, stride):
        start = base + stride - 188
        if data[start] != 0x47:
            raise ValueError('invalid fixture packet framing')
        pid = ((data[start + 1] & 31) << 8) | data[start + 2]
        payload = start + 4
        if data[start + 3] & 32:
            payload += 1 + data[payload]
        yield start, pid, payload, bool(data[start + 1] & 64)


def crc(data):
    value = 0xffffffff
    for byte in data:
        value ^= byte << 24
        for _ in range(8):
            value = ((value << 1) ^ (0x04c11db7 if value & 0x80000000 else 0)) & 0xffffffff
    return value.to_bytes(4, 'big')


def stamp(data, pos, shift):
    value = ((data[pos] >> 1 & 7) << 30) | (data[pos+1] << 22) | ((data[pos+2] >> 1) << 15) | (data[pos+3] << 7) | (data[pos+4] >> 1)
    value = (value + shift) % (1 << 33)
    data[pos:pos+5] = bytes([(data[pos] & 0xf0) | ((value >> 30) << 1) | 1,
                            value >> 22 & 255, (value >> 15 & 127) * 2 + 1,
                            value >> 7 & 255, (value & 127) * 2 + 1])


def derive(root):
    clean = bytearray((root / 'h264-aac.ts').read_bytes())
    dts, rejected, rollover = bytearray(clean), bytearray(clean), bytearray(clean)
    for start, pid, payload, first in packets(clean):
        if pid == 4096 and first:
            section = payload + 1 + clean[payload]
            end = section + 3 + (((clean[section+1] & 15) << 8) | clean[section+2])
            stream = section + 12 + (((clean[section+10] & 15) << 8) | clean[section+11])
            while stream < end - 4:
                if clean[stream] == 15:
                    dts[stream] = 0x82
                stream += 5 + (((clean[stream+3] & 15) << 8) | clean[stream+4])
            dts[end-4:end] = crc(dts[section:end-4])
        if first and clean[payload:payload+3] == b'\x00\x00\x01':
            flags = clean[payload+7]
            if flags & 128:
                stamp(rollover, payload+9, (1 << 33) - 270000)
            if flags & 64:
                stamp(rollover, payload+14, (1 << 33) - 270000)
            if pid == 257:
                header = payload + 9 + clean[payload+8]
                if clean[header:header+2] == b'\xff\xf1':
                    rejected[header+2] &= 0x3f  # AAC Main, outside AAC-LC.
        if clean[start+3] & 32 and clean[start+4] >= 7 and clean[start+5] & 16:
            pos = start+6
            value = (int.from_bytes(clean[pos:pos+4], 'big') << 1) | (clean[pos+4] >> 7)
            value = (value + (1 << 33) - 270000) % (1 << 33)
            rollover[pos:pos+4] = (value >> 1).to_bytes(4, 'big')
            rollover[pos+4] = (clean[pos+4] & 127) | ((value & 1) << 7)
    for name, data in [('dts-only.ts', dts), ('rejected-aac.ts', rejected), ('rollover.ts', rollover)]:
        (root / name).write_bytes(data)
    damaged = bytearray(clean)
    middle = (len(clean) // 2 // 188) * 188
    damaged[middle:middle+700] = bytes(700)
    (root / 'h264-aac-corrupt.ts').write_bytes(damaged)


def generate(root, ffmpeg):
    def mux(name, seconds=3, rate=25, gop=25, video='libx264', audio='aac', depth=8, pq=False, hlg=False, audio_rate=48000):
        args = ['-f', 'lavfi', '-i', f'testsrc2=size=128x72:rate={rate}:duration={seconds}']
        if audio:
            args += ['-f', 'lavfi', '-i', f'sine=frequency=440:sample_rate={audio_rate}:duration={seconds}']
        args += ['-c:v', video, '-threads:v', '1', '-pix_fmt', 'yuv420p10le' if depth == 10 else 'yuv420p', '-g', str(gop), '-bf', '2']
        if video == 'libx264':
            args += ['-preset', 'veryfast', '-x264-params', 'scenecut=0:threads=1']
        if video == 'libx265':
            color = f':colorprim=9:transfer={18 if hlg else 16}:colormatrix=9' if pq or hlg else ''
            args += ['-preset', 'ultrafast', '-x265-params', f'pools=none:frame-threads=1:log-level=error:scenecut=0:keyint={gop}:min-keyint={gop}{color}']
        if pq or hlg:
            args += ['-color_primaries', 'bt2020', '-color_trc', 'arib-std-b67' if hlg else 'smpte2084', '-colorspace', 'bt2020nc']
        if audio:
            args += ['-c:a', audio, '-ac', '2', '-threads:a', '1', '-b:a', '96k']
        args += ['-fflags', '+bitexact', '-f', 'mpegts']
        if name.endswith('.m2ts'):
            args += ['-mpegts_m2ts_mode', '1']
        run(ffmpeg, *args, root / name)
    for name, kwargs in {
        'h264-aac.ts': {}, 'h264-only.ts': {'audio': None},
        'h264-ac3.m2ts': {'audio': 'ac3'},
        'mpeg2-mp2.ts': {'video': 'mpeg2video', 'audio': 'mp2'},
        'mpeg2-mp3.ts': {'video': 'mpeg2video', 'audio': 'libmp3lame'},
        'video.ts': {'seconds': 6, 'rate': 30, 'gop': 180},
        'L_video.ts': {'seconds': 20, 'rate': 30, 'gop': 250},
        'seek.ts': {'seconds': 20},
        'hevc-aac.ts': {'seconds': 20, 'video': 'libx265', 'gop': 250},
        'hevc-main10.ts': {'seconds': 20, 'video': 'libx265', 'gop': 250, 'depth': 10},
        'hevc-main10-pq.ts': {'seconds': 3, 'video': 'libx265', 'depth': 10, 'pq': True},
        'hevc-main10-hlg.ts': {'seconds': 3, 'video': 'libx265', 'depth': 10, 'hlg': True},
        'hevc-ac3.m2ts': {'seconds': 20, 'video': 'libx265', 'gop': 250, 'audio': 'ac3'},
        'opus.ts': {'audio': 'libopus'},
        'av.ts': {'rate': 30, 'gop': 15},
        'odd.ts': {'rate': 30, 'gop': 15, 'audio_rate': 44100},
        'leadin.ts': {'rate': 30, 'gop': 15, 'audio': 'ac3'},
    }.items():
        mux(name, **kwargs)
    run(ffmpeg, '-i', root/'h264-aac.ts', '-i', root/'h264-aac.ts',
        '-map', '0:v', '-map', '0:a', '-map', '1:v', '-map', '1:a', '-c', 'copy',
        '-program', 'program_num=1:st=0:st=1', '-program', 'program_num=2:st=2:st=3',
        '-f', 'mpegts', root/'multiprogram.ts')
    incomplete = bytearray((root/'multiprogram.ts').read_bytes())
    for _, pid, payload, first in packets(incomplete):
        if pid != 4096 or not first:
            continue
        section = payload + 1 + incomplete[payload]
        end = section + 3 + (((incomplete[section+1] & 15) << 8) | incomplete[section+2])
        stream = section + 12 + (((incomplete[section+10] & 15) << 8) | incomplete[section+11])
        while stream < end - 4:
            if incomplete[stream] == 15:
                incomplete[stream] = 0x82
            stream += 5 + (((incomplete[stream+3] & 15) << 8) | incomplete[stream+4])
        incomplete[end-4:end] = crc(incomplete[section:end-4])
    (root/'multiprogram-dts-first.ts').write_bytes(incomplete)
    run(ffmpeg, '-i', root/'h264-aac.ts', '-vn', '-c:a', 'copy', '-f', 'mpegts', root/'audio.ts')
    derive(root)
    truths = []
    for name, frames, keys in [('h264-aac.ts',75,3), ('h264-only.ts',75,3),
                              ('h264-ac3.m2ts',75,3), ('video.ts',180,1),
                              ('seek.ts',500,20), ('L_video.ts',600,3)]:
        raw = root / (name + '.h264')
        run(ffmpeg, '-i', root/name, '-map', '0:v:0', '-c', 'copy', '-f', 'h264', raw)
        audio_units, audio_bytes = 0, 0
        if name not in ('h264-only.ts', 'h264-ac3.m2ts'):
            data = (root/name).read_bytes()
            audio_units = sum(1 for _, pid, _, first in packets(data) if pid == 257 and first)
            adts = root / (name + '.aac')
            run(ffmpeg, '-i', root/name, '-map', '0:a:0', '-c', 'copy', '-f', 'adts', adts)
            audio_bytes = adts.stat().st_size
            adts.unlink()
        truths.append(f'{name} {frames} {keys} {raw.stat().st_size} {audio_units} {audio_bytes}\n')
        raw.unlink()
    (root/'truth.txt').write_text(''.join(truths))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--ffmpeg', required=True)
    args = parser.parse_args()
    root = args.root
    identity = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    manifest = root / 'manifest.json'
    if manifest.exists():
        record = json.loads(manifest.read_text())
        if record['recipe'] == identity and record['version'] == VERSION:
            for name, digest in record['files'].items():
                path = root / name
                if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                    raise RuntimeError(f'required MPEG-TS fixture missing or changed: {path}')
            print(f'Verified {len(record["files"])} required MPEG-TS fixtures')
            return
    root.mkdir(parents=True, exist_ok=True)
    generate(root, args.ffmpeg)
    files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.iterdir()) if p.is_file() and p != manifest}
    manifest.write_text(json.dumps({'version': VERSION, 'recipe': identity, 'files': files}, sort_keys=True))
    print(f'Generated {len(files)} required MPEG-TS fixtures')

if __name__ == '__main__':
    main()
