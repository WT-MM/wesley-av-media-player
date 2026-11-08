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


def pes_list(data, pid):
    """(pts, dts, payload) of every PES on `pid`; times are raw 33-bit ticks."""
    units = []
    for start, packet_pid, payload, first in packets(data):
        if packet_pid != pid:
            continue
        body = data[payload:start + 188]
        if first:
            flags, header = body[7], 9 + body[8]
            read = lambda at: (((body[at] >> 1) & 7) << 30) | (body[at+1] << 22) | ((body[at+2] >> 1) << 15) | (body[at+3] << 7) | (body[at+4] >> 1)
            pts = read(9) if flags & 128 else None
            dts = read(14) if flags & 64 else pts
            units.append([pts, dts, bytearray(body[header:])])
        elif units:
            units[-1][2] += body
    return units


def resplit(source, target, skip=0, jump=0):
    """Re-cut a one-unit-per-PES mux so access units straddle PES packets.

    Video: every PES boundary falls a few bytes INTO an access unit (some of
    them inside its start code), so each PES holds one unit's tail and the
    next unit's head. Audio: ADTS frames are re-cut into odd-sized PES packets
    after dropping `skip` bytes, so the first PES opens mid-frame. Each PES
    carries the timestamps of the first unit commencing in it (13818-1
    2.4.3.7), and none when no unit commences in it; `jump` ticks are added
    to the audio timestamps of the later PES packets, a discontinuity the
    source must refuse."""
    data = source.read_bytes()
    video, audio = pes_list(data, 256), pes_list(data, 257)
    stream, starts = bytearray(), []
    for _, _, body in video:
        starts.append(len(stream))
        stream += body
    cuts = [0] + [start + (2, 3, 9, 17, 40)[k % 5] for k, start in enumerate(starts)] + [len(stream)]
    assert all(starts[k] < cuts[k + 1] < starts[k] + len(video[k][2]) for k in range(len(starts)))
    units = [(video[k][0], video[k][1], stream[cuts[k]:cuts[k + 1]]) if k < len(video)
             else (None, None, stream[cuts[k]:cuts[k + 1]]) for k in range(len(cuts) - 1)]
    elementary, frame_starts = bytearray(), []
    for _, _, body in audio:
        at = 0
        while at < len(body):
            frame_starts.append(len(elementary) + at - skip)
            at += ((body[at+3] & 3) << 11) | (body[at+4] << 3) | (body[at+5] >> 5)
        elementary += body
    elementary = elementary[skip:]
    audio_units, at = [], 0
    while at < len(elementary):
        end = min(at + 600 + (len(audio_units) * 97) % 400, len(elementary))
        commencing = [i for i, f in enumerate(frame_starts) if at <= f < end]
        pts = audio[0][0] + 1920 * commencing[0] if commencing else None  # 1024 frames at 48 kHz
        if pts is not None and len(audio_units) >= 40:
            pts += jump
        audio_units.append((pts, pts, elementary[at:end]))
        at = end
    tables = []
    for start, pid, _, first in packets(data):
        if pid in (0, 4096) and first and len(tables) < 2:
            tables.append(bytes(data[start:start + 188]))
    counters, out = {256: 0, 257: 0}, bytearray()

    def stamp(marker, value):
        return bytes([(marker << 4) | ((value >> 29) & 14) | 1, (value >> 22) & 255,
                      ((value >> 14) & 254) | 1, (value >> 7) & 255, ((value << 1) & 254) | 1])

    def emit(pid, pts, dts, body):
        is_video = pid == 256
        if pts is None:
            header = bytes([0x80, 0, 0])
        elif is_video and dts != pts:
            header = bytes([0x80, 0xC0, 10]) + stamp(3, pts) + stamp(1, dts)
        else:
            header = bytes([0x80, 0x80, 5]) + stamp(2, pts)
        length = 0 if is_video else len(header) + len(body)
        pes = bytes([0, 0, 1, 0xE0 if is_video else 0xC0, length >> 8, length & 255]) + header + bytes(body)
        first = True
        while pes:
            fields = b''
            if first and is_video and dts is not None:
                pcr = max(dts - 9000, 0)
                fields = bytes([0x10, (pcr >> 25) & 255, (pcr >> 17) & 255, (pcr >> 9) & 255,
                                (pcr >> 1) & 255, ((pcr & 1) << 7) | 0x7E, 0])
            room = 184 - (1 + len(fields) if fields else 0)
            if len(pes) < room:
                size = 183 - len(pes)  # adaptation_field_length
                fields = fields or (bytes([0]) if size else b'')
                adaptation = bytes([size]) + fields + b'\xff' * (size - len(fields))
                chunk, pes = pes, b''
            else:
                adaptation = bytes([len(fields)]) + fields if fields else b''
                chunk, pes = pes[:room], pes[room:]
            control = 0x30 if adaptation else 0x10
            out.extend(bytes([0x47, (0x40 if first else 0) | (pid >> 8), pid & 255,
                              control | counters[pid]]) + adaptation + chunk)
            counters[pid] = (counters[pid] + 1) & 15
            first = False

    order = []
    for rank, (pid, entries) in enumerate([(256, units), (257, audio_units)]):
        last = 0
        for pts, dts, body in entries:
            last = dts if dts is not None else last
            order.append((last, rank, len(order), pid, pts, dts, body))
    for index, (_, _, _, pid, pts, dts, body) in enumerate(sorted(order)):
        if index % 40 == 0:
            for table in tables:
                out.extend(table)
        emit(pid, pts, dts, body)
    target.write_bytes(out)


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
    resplit(root/'h264-aac.ts', root/'split.ts', skip=100)
    resplit(root/'h264-aac.ts', root/'split-jump.ts', jump=9000)
    resplit(root/'hevc-aac.ts', root/'split-hevc.ts')
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
